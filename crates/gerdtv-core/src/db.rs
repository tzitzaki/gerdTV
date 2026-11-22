//! The per-profile SQLite database (docs/DATA_MODEL.md): provider catalogue (categories, items) with an FTS5
//! index for the global search, plus the user tables search ranking reads (favourites, recents).
//!
//! Rules this file keeps:
//! - Stable content keys: `live:<id>`, `movie:<id>`, `episode:<id>` for Xtream Codes-style URLs, else `url:<hash>`
//!   of the credential-free URL. User data refers to items only by key, so a re-sync never orphans favourites.
//! - No credentials on disk: stream URLs are stored with the profile's secrets replaced by `{secret0}`, `{secret1}`…
//!   (`template_secrets`); the player gets the real URL from `fill_secrets` at play time.
//! - Sync is diff + upsert inside one transaction: readers (WAL mode) see the old catalogue until it commits, rows
//!   not seen in this sync are deleted afterwards.
//!
//! Debug hints: `sqlite3 <profile>.db "select kind, count(*) from items group by kind"`; FTS problems show up as
//! "fts5: syntax error" — the query builder quotes every token, so that means a bug in `fts_query`.

use crate::m3u;
use rusqlite::{Connection, OptionalExtension, params};
use std::io::BufRead;
use std::path::Path;

pub type Result<T> = rusqlite::Result<T>;

/// Item kinds as stored (the numbers are part of the schema; never renumber).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Kind {
    Live = 0,
    Movie = 1,
    Episode = 2,
    Series = 3,
}

impl Kind {
    pub fn from_i64(v: i64) -> Kind {
        match v {
            1 => Kind::Movie,
            2 => Kind::Episode,
            3 => Kind::Series,
            _ => Kind::Live,
        }
    }
}

impl From<m3u::Kind> for Kind {
    fn from(k: m3u::Kind) -> Kind {
        match k {
            m3u::Kind::Live => Kind::Live,
            m3u::Kind::Movie => Kind::Movie,
            m3u::Kind::Episode => Kind::Episode,
        }
    }
}

/// Forward-only migrations: entry i takes the schema from version i + 1 to i + 2. The base SCHEMA is version 1.
/// Never edit a released entry; append a new one (docs/DATA_MODEL.md, "Migrations").
const MIGRATIONS: &[&str] = &[
    // 1 → 2: the container extension of Xtream Codes movies and episodes (play URLs need it: mp4, mkv …).
    "ALTER TABLE items ADD COLUMN ext TEXT NOT NULL DEFAULT ''",
    // 2 → 3: profile settings (buffer preset, adaptive mode, timeshift window …) and, per channel, a buffer override
    // and the last measured video bitrate (sizes the demuxer cache). User data: updated_at for a later hub sync.
    "CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL, updated_at INTEGER NOT NULL);
     ALTER TABLE stream_prefs ADD COLUMN buffer TEXT NOT NULL DEFAULT '';
     ALTER TABLE stream_prefs ADD COLUMN bitrate INTEGER NOT NULL DEFAULT 0;",
    // 3 → 4: the TV guide (epg.rs): XMLTV channels and their display names (normalised, for matching), programmes
    // with a contentless FTS index, the sources (built-in + extra URLs), the user's manual mapping (user data) and the
    // resolved item → guide channel matches.
    "CREATE TABLE epg_channels (id TEXT PRIMARY KEY, name TEXT NOT NULL, icon TEXT NOT NULL DEFAULT '',
        source INTEGER NOT NULL);
     CREATE INDEX epg_channels_lower ON epg_channels (lower(id));
     CREATE TABLE epg_names (norm TEXT PRIMARY KEY, channel TEXT NOT NULL);
     CREATE TABLE programmes (id INTEGER PRIMARY KEY, channel TEXT NOT NULL, start INTEGER NOT NULL,
        stop INTEGER NOT NULL, title TEXT NOT NULL, sub_title TEXT NOT NULL DEFAULT '', descr TEXT NOT NULL DEFAULT '',
        category TEXT NOT NULL DEFAULT '', episode TEXT NOT NULL DEFAULT '', icon TEXT NOT NULL DEFAULT '',
        source INTEGER NOT NULL);
     CREATE INDEX programmes_by_channel ON programmes (channel, start);
     CREATE INDEX programmes_by_stop ON programmes (stop);
     CREATE VIRTUAL TABLE programmes_fts USING fts5(title, sub_title, descr, content='', contentless_delete=1,
        tokenize='unicode61 remove_diacritics 2');
     CREATE TABLE epg_sources (id INTEGER PRIMARY KEY, url TEXT NOT NULL UNIQUE, builtin INTEGER NOT NULL,
        last_fetch INTEGER NOT NULL DEFAULT 0, status TEXT NOT NULL DEFAULT '', channels INTEGER NOT NULL DEFAULT 0,
        programmes INTEGER NOT NULL DEFAULT 0, updated_at INTEGER NOT NULL);
     CREATE TABLE epg_map (item_key TEXT PRIMARY KEY, channel TEXT NOT NULL, updated_at INTEGER NOT NULL);
     CREATE TABLE item_epg (item_key TEXT PRIMARY KEY, channel TEXT NOT NULL);
     CREATE INDEX item_epg_by_channel ON item_epg (channel);",
    // 4 → 5: catch-up: how many days back a live channel's archive reaches (0 = none); reminders for guide programmes
    // (user data), by channel and start time, since programme ids change with every guide import.
    "ALTER TABLE items ADD COLUMN archive_days INTEGER NOT NULL DEFAULT 0;
     CREATE TABLE reminders (item_key TEXT NOT NULL, start INTEGER NOT NULL, stop INTEGER NOT NULL,
        title TEXT NOT NULL, updated_at INTEGER NOT NULL, PRIMARY KEY (item_key, start));",
];
const SCHEMA_VERSION: i64 = 1 + MIGRATIONS.len() as i64;

const SCHEMA: &str = "
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS categories (
    kind INTEGER NOT NULL, id TEXT NOT NULL, name TEXT NOT NULL, position INTEGER NOT NULL,
    PRIMARY KEY (kind, id));
CREATE TABLE IF NOT EXISTS items (
    key TEXT PRIMARY KEY,
    kind INTEGER NOT NULL,
    name TEXT NOT NULL,
    category TEXT NOT NULL,
    logo TEXT NOT NULL DEFAULT '',
    epg_id TEXT NOT NULL DEFAULT '',
    number INTEGER,
    url TEXT NOT NULL DEFAULT '',
    season INTEGER, episode INTEGER, year INTEGER,
    position INTEGER NOT NULL,
    seen INTEGER NOT NULL);
CREATE INDEX IF NOT EXISTS items_by_category ON items (kind, category, position);
CREATE INDEX IF NOT EXISTS items_by_number ON items (kind, number);
-- Contentless FTS: the text lives in items; rowids match. remove_diacritics 2 folds ü→u, é→e … for search.
CREATE VIRTUAL TABLE IF NOT EXISTS items_fts USING fts5(
    name, alt, content='', contentless_delete=1, tokenize='unicode61 remove_diacritics 2');
-- User data: stable keys + updated_at, so a later home hub can sync it (docs/DATA_MODEL.md).
CREATE TABLE IF NOT EXISTS favourites (key TEXT PRIMARY KEY, updated_at INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS recents (key TEXT PRIMARY KEY, updated_at INTEGER NOT NULL);
-- Per channel: the URL form that last worked (the watchdog's TS ↔ HLS switch).
CREATE TABLE IF NOT EXISTS stream_prefs (key TEXT PRIMARY KEY, prefer_hls INTEGER NOT NULL, updated_at INTEGER NOT NULL);
-- Every recovery the watchdog made or gave up on (Settings → Stream health, diagnostics export).
CREATE TABLE IF NOT EXISTS stream_health (
    id INTEGER PRIMARY KEY, at INTEGER NOT NULL, key TEXT NOT NULL, trigger TEXT NOT NULL,
    attempts INTEGER NOT NULL, recovered INTEGER NOT NULL, secs INTEGER NOT NULL);
";

/// Opens (creating if needed) a profile database at `path` (":memory:" for tests).
pub fn open(path: &Path) -> Result<Connection> {
    let conn = Connection::open(path)?;
    conn.pragma_update(None, "journal_mode", "WAL")?; // readers keep browsing while a sync writes
    conn.pragma_update(None, "synchronous", "NORMAL")?;
    conn.execute_batch(SCHEMA)?;
    let version: Option<String> = conn
        .query_row("SELECT value FROM meta WHERE key = 'schema'", [], |r| {
            r.get(0)
        })
        .optional()?;
    let fresh = version.is_none();
    let mut current: i64 = version.and_then(|v| v.parse().ok()).unwrap_or(1);
    if current < SCHEMA_VERSION && !fresh && path != Path::new(":memory:") {
        // Hard to undo: copy the database first (data safety rule). The WAL is checkpointed into it beforehand.
        conn.pragma_update(None, "wal_checkpoint", "TRUNCATE")?;
        let backup = path.with_extension(format!("db.bak-{}", unix_now()));
        std::fs::copy(path, &backup)
            .map_err(|e| rusqlite::Error::ToSqlConversionFailure(Box::new(e)))?;
    }
    while current < SCHEMA_VERSION {
        conn.execute_batch(MIGRATIONS[(current - 1) as usize])?;
        current += 1;
    }
    conn.execute(
        "INSERT INTO meta (key, value) VALUES ('schema', ?1) ON CONFLICT (key) DO UPDATE SET value = ?1",
        [current.to_string()],
    )?;
    Ok(conn)
}

fn unix_now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// FNV-1a 64: a stable hash for keys (std's hasher may change between Rust versions; keys must not).
pub fn fnv1a(s: &str) -> u64 {
    s.bytes().fold(0xcbf2_9ce4_8422_2325, |h, b| {
        (h ^ b as u64).wrapping_mul(0x0000_0100_0000_01b3)
    })
}

/// Replaces each non-empty secret with `{secretN}` (longest first, so a password containing the username stays whole).
pub fn template_secrets(url: &str, secrets: &[&str]) -> String {
    let mut order: Vec<(usize, &str)> = secrets
        .iter()
        .copied()
        .enumerate()
        .filter(|(_, s)| !s.is_empty())
        .collect();
    order.sort_by_key(|(_, s)| std::cmp::Reverse(s.len()));
    let mut out = url.to_string();
    for (i, s) in order {
        out = out.replace(s, &format!("{{secret{i}}}"));
    }
    out
}

/// The reverse of `template_secrets`, at play time only.
pub fn fill_secrets(url: &str, secrets: &[&str]) -> String {
    let mut out = url.to_string();
    for (i, s) in secrets.iter().enumerate() {
        out = out.replace(&format!("{{secret{i}}}"), s);
    }
    out
}

/// The stable key of an M3U entry: the Xtream Codes stream id when the URL has the XC path form, else a URL hash.
pub fn m3u_key(kind: Kind, templated_url: &str) -> String {
    let path = templated_url.split('?').next().unwrap_or("");
    let segs: Vec<&str> = path.split('/').collect();
    // …/<live|movie|series>/<user>/<pass>/<id>.<ext>
    if segs.len() >= 4 {
        let n = segs.len();
        if matches!(segs[n - 4], "live" | "movie" | "series") {
            let id = segs[n - 1].split('.').next().unwrap_or("");
            if !id.is_empty() && id.bytes().all(|b| b.is_ascii_digit()) {
                let prefix = match kind {
                    Kind::Live => "live",
                    Kind::Movie => "movie",
                    _ => "episode",
                };
                return format!("{prefix}:{id}");
            }
        }
    }
    format!("url:{:016x}", fnv1a(templated_url))
}

/// The searchable alternative name: without country prefixes (`DE |`, `[DE]`, `DE:`) and quality tags.
pub fn clean_name(name: &str) -> String {
    let mut s = name.trim();
    // "DE | Name", "DE: Name", "[DE] Name", "DE - Name"
    if let Some(rest) = s
        .strip_prefix('[')
        .and_then(|r| r.split_once(']'))
        .map(|(_, r)| r)
    {
        s = rest.trim();
    } else if let Some((head, rest)) = s.split_once(['|', ':'])
        && head.trim().len() <= 4
    {
        s = rest.trim();
    }
    const TAGS: &[&str] = &[
        "HD", "FHD", "UHD", "4K", "8K", "SD", "HEVC", "H265", "HDR", "MULTI", "RAW",
    ];
    s.split_whitespace()
        .filter(|w| {
            !TAGS.contains(
                &w.trim_matches(['(', ')', '[', ']'])
                    .to_ascii_uppercase()
                    .as_str(),
            )
        })
        .collect::<Vec<_>>()
        .join(" ")
}

#[derive(Debug, Default, Clone, PartialEq)]
pub struct ImportStats {
    pub entries: usize,
    pub skipped: usize,
    pub removed: usize,
    pub categories: usize,
    /// M3U: the playlist's guide URL (header `url-tvg`), if any.
    pub tvg_url: Option<String>,
}

/// One catalogue row as a source delivers it (M3U entry or Xtream Codes stream).
#[derive(Debug, Clone, Default)]
pub struct NewItem {
    pub key: String,
    pub name: String,
    /// Extra searchable text (e.g. tvg-name); the cleaned name is added automatically.
    pub alt: String,
    pub category: String,
    pub logo: String,
    pub epg_id: String,
    pub number: Option<u32>,
    /// Credential-free (templated) URL; empty for Xtream Codes, whose URLs are built at play time.
    pub url: String,
    pub season: Option<u32>,
    pub episode: Option<u32>,
    pub year: Option<u32>,
    /// Xtream Codes movies/episodes: the container extension for the play URL.
    pub ext: String,
    /// Live channels: days the provider keeps for catch-up (0 = none).
    pub archive_days: u32,
}

/// One sync of a profile's catalogue: everything inside one transaction (diff + upsert by key), so readers see the
/// old catalogue until `finish` commits and an error anywhere leaves it untouched (the transaction rolls back).
pub struct Sync<'c> {
    tx: rusqlite::Transaction<'c>,
    generation: i64,
    position: i64,
    categories: Vec<(Kind, String, String)>,
}

impl<'c> Sync<'c> {
    pub fn begin(conn: &'c mut Connection) -> Result<Sync<'c>> {
        let tx = conn.transaction()?;
        let generation = tx.query_row("SELECT coalesce(max(seen), 0) + 1 FROM items", [], |r| {
            r.get(0)
        })?;
        Ok(Sync {
            tx,
            generation,
            position: 0,
            categories: Vec::new(),
        })
    }

    /// A category in provider order (`id` = provider category id, or the group name for M3U).
    pub fn category(&mut self, kind: Kind, id: &str, name: &str) {
        if !self
            .categories
            .iter()
            .any(|(k, i, _)| *k == kind && i == id)
        {
            self.categories
                .push((kind, id.to_string(), name.to_string()));
        }
    }

    pub fn item(&mut self, kind: Kind, it: &NewItem) -> Result<()> {
        let rowid: i64 = self.tx.prepare_cached(
            "INSERT INTO items (key, kind, name, category, logo, epg_id, number, url, season, episode, year, position, seen, ext,
               archive_days)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15)
             ON CONFLICT (key) DO UPDATE SET kind = ?2, name = ?3, category = ?4, logo = ?5, epg_id = ?6,
               number = ?7, url = ?8, season = ?9, episode = ?10, year = ?11, position = ?12, seen = ?13, ext = ?14,
               archive_days = ?15
             RETURNING rowid",
        )?.query_row(
            params![it.key, kind as i64, it.name, it.category, it.logo, it.epg_id, it.number, it.url, it.season,
                    it.episode, it.year, self.position, self.generation, it.ext, it.archive_days],
            |r| r.get(0),
        )?;
        self.tx
            .prepare_cached("DELETE FROM items_fts WHERE rowid = ?1")?
            .execute([rowid])?;
        let alt = format!("{} {}", clean_name(&it.name), clean_name(&it.alt));
        self.tx
            .prepare_cached("INSERT INTO items_fts (rowid, name, alt) VALUES (?1, ?2, ?3)")?
            .execute(params![rowid, it.name, alt])?;
        self.position += 1;
        Ok(())
    }

    /// Keeps every existing row of `kind` as if the source had sent it again. For a list that came back empty
    /// while the catalogue has rows of that kind: real panels answer `[]` now and then under load, and treating
    /// that as "everything was removed" would wipe the user's movies until the next sync.
    pub fn keep_kind(&mut self, kind: Kind) -> Result<usize> {
        self.tx.execute(
            "UPDATE items SET seen = ?1 WHERE kind = ?2",
            params![self.generation, kind as i64],
        )
    }

    /// Adds rows outside a full sync (a series' episodes, fetched when the series opens). They carry the current
    /// generation, so the next full sync removes them again and they are fetched afresh.
    pub fn add_items(conn: &mut Connection, kind: Kind, items: &[NewItem]) -> Result<()> {
        let mut s = Sync::begin(conn)?;
        s.generation -= 1; // = the last full sync's generation: these rows count as part of it
        for it in items {
            s.item(kind, it)?;
        }
        s.tx.commit()
    }

    /// Removes rows the provider no longer has, replaces the categories, commits. Returns rows removed.
    pub fn finish(self) -> Result<usize> {
        let g = self.generation;
        self.tx.execute(
            "DELETE FROM items_fts WHERE rowid IN (SELECT rowid FROM items WHERE seen < ?1)",
            [g],
        )?;
        let removed = self.tx.execute("DELETE FROM items WHERE seen < ?1", [g])?;
        self.tx.execute("DELETE FROM categories", [])?;
        for (i, (kind, id, name)) in self.categories.iter().enumerate() {
            self.tx.execute(
                "INSERT OR IGNORE INTO categories (kind, id, name, position) VALUES (?1, ?2, ?3, ?4)",
                params![*kind as i64, id, name, i as i64],
            )?;
        }
        self.tx.commit()?;
        Ok(removed)
    }
}

/// Imports an M3U playlist as the profile's whole catalogue.
pub fn import_m3u(
    conn: &mut Connection,
    input: impl BufRead,
    secrets: &[&str],
) -> std::io::Result<ImportStats> {
    let io = |e: rusqlite::Error| std::io::Error::other(e);
    let mut sync = Sync::begin(conn).map_err(io)?;
    let mut stats = ImportStats::default();
    let mut failed: Option<rusqlite::Error> = None;
    let parsed = m3u::parse(input, |e| {
        if failed.is_some() {
            return;
        }
        let kind = Kind::from(e.kind.unwrap_or(m3u::Kind::Live));
        let url = template_secrets(&e.url, secrets);
        sync.category(kind, &e.group, &e.group);
        let item = NewItem {
            key: m3u_key(kind, &url),
            alt: if e.tvg_name != e.name {
                e.tvg_name.clone()
            } else {
                String::new()
            },
            category: e.group.clone(),
            logo: e.logo.clone(),
            epg_id: e.tvg_id.clone(),
            number: e.number,
            season: e.episode.map(|x| x.0),
            episode: e.episode.map(|x| x.1),
            name: e.name,
            url,
            year: None,
            ext: String::new(),
            // A catchup attribute without catchup-days says nothing about the reach: no catch-up then.
            archive_days: if e.catchup.is_empty() {
                0
            } else {
                e.catchup_days.unwrap_or(0)
            },
        };
        match sync.item(kind, &item) {
            Ok(()) => stats.entries += 1,
            Err(err) => failed = Some(err),
        }
    })?;
    if let Some(e) = failed {
        return Err(io(e));
    }
    stats.skipped = parsed.skipped;
    stats.tvg_url = parsed.tvg_url;
    stats.categories = sync.categories.len();
    stats.removed = sync.finish().map_err(io)?;
    Ok(stats)
}

/// One search result row.
#[derive(Debug, Clone, PartialEq)]
pub struct Hit {
    pub key: String,
    pub kind: Kind,
    pub name: String,
    pub category: String,
    pub logo: String,
    pub number: Option<u32>,
    /// Live channels: catch-up days (0 = none).
    pub archive_days: u32,
}

/// The FTS5 query for user input: every word a quoted prefix (`ard sport` → `"ard"* "sport"*`), so quotes, `-`
/// or `AND` typed by the user are never FTS syntax. Diacritics are folded by the tokenizer.
pub fn fts_query(input: &str) -> Option<String> {
    let words: Vec<String> = input
        .split(|c: char| !c.is_alphanumeric())
        .filter(|w| !w.is_empty())
        .map(|w| format!("\"{}\"*", w.to_lowercase()))
        .collect();
    (!words.is_empty()).then(|| words.join(" "))
}

/// Searches the catalogue. Ranking: favourites, then recently watched, then an exact channel number, then names starting
/// with the query, then provider order; `kind` narrows to one section. A number alone also finds that channel number.
pub fn search(
    conn: &Connection,
    input: &str,
    kind: Option<Kind>,
    limit: usize,
    offset: usize,
) -> Result<Vec<Hit>> {
    let Some(q) = fts_query(input) else {
        return Ok(vec![]);
    };
    let number: Option<i64> = input.trim().parse().ok();
    let prefix = format!("{}%", input.trim());
    let mut stmt = conn.prepare_cached(
        "SELECT i.key, i.kind, i.name, i.category, i.logo, i.number, i.archive_days
         FROM items i
         LEFT JOIN favourites f ON f.key = i.key
         LEFT JOIN recents r ON r.key = i.key
         -- One indexed set of rowids (FTS hits ∪ the channel with that number): an OR here made SQLite scan items.
         WHERE i.rowid IN (SELECT rowid FROM items_fts WHERE items_fts MATCH ?1
                           UNION SELECT rowid FROM items WHERE kind = 0 AND number = ?2)
           AND (?3 IS NULL OR i.kind = ?3)
         ORDER BY f.key IS NULL, r.updated_at IS NULL, r.updated_at DESC,
                  CASE WHEN ?2 IS NOT NULL AND i.number = ?2 THEN 0 ELSE 1 END, i.name NOT LIKE ?4, i.position
         LIMIT ?5 OFFSET ?6",
    )?;
    let rows = stmt.query_map(
        params![
            q,
            number,
            kind.map(|k| k as i64),
            prefix,
            limit as i64,
            offset as i64
        ],
        |r| {
            Ok(Hit {
                key: r.get(0)?,
                kind: Kind::from_i64(r.get(1)?),
                name: r.get(2)?,
                category: r.get(3)?,
                logo: r.get(4)?,
                number: r.get(5)?,
                archive_days: r.get(6)?,
            })
        },
    )?;
    rows.collect()
}

/// Result counts per kind for the section headers and type chips.
pub fn search_counts(conn: &Connection, input: &str) -> Result<Vec<(Kind, usize)>> {
    let Some(q) = fts_query(input) else {
        return Ok(vec![]);
    };
    let number: Option<i64> = input.trim().parse().ok();
    let mut stmt = conn.prepare_cached(
        "SELECT kind, count(*) FROM items
         WHERE rowid IN (SELECT rowid FROM items_fts WHERE items_fts MATCH ?1
                         UNION SELECT rowid FROM items WHERE kind = 0 AND number = ?2)
         GROUP BY kind ORDER BY kind",
    )?;
    let rows = stmt.query_map(params![q, number], |r| {
        Ok((Kind::from_i64(r.get(0)?), r.get::<_, i64>(1)? as usize))
    })?;
    rows.collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    const PLAYLIST: &str = "#EXTM3U
#EXTINF:-1 tvg-id=\"ard\" tvg-chno=\"1\" group-title=\"DE | Vollprogramm\",DE | ARD Sportschau HD
http://h.example.invalid/live/alice/s3cret/101.ts
#EXTINF:-1 tvg-chno=\"7\" group-title=\"DE | Regional\",BR München FHD
http://h.example.invalid/live/alice/s3cret/102.ts
#EXTINF:-1 group-title=\"VOD DE\",Die Reise (2019)
http://h.example.invalid/movie/alice/s3cret/201.mkv
#EXTINF:-1 group-title=\"Serien\",Planet Wissen S01E02
http://h.example.invalid/series/alice/s3cret/301.mp4
#EXTINF:-1 group-title=\"Other\",Plain Stream
http://other.example.invalid/stream?token=s3cret
";

    fn db() -> Connection {
        let mut c = open(Path::new(":memory:")).unwrap();
        import_m3u(&mut c, PLAYLIST.as_bytes(), &["alice", "s3cret"]).unwrap();
        c
    }

    fn names(hits: &[Hit]) -> Vec<&str> {
        hits.iter().map(|h| h.name.as_str()).collect()
    }

    #[test]
    fn import_keys_and_no_credentials_on_disk() {
        let c = db();
        let keys: Vec<String> = c
            .prepare("SELECT key FROM items ORDER BY position")
            .unwrap()
            .query_map([], |r| r.get(0))
            .unwrap()
            .map(|r| r.unwrap())
            .collect();
        assert_eq!(
            &keys[..4],
            ["live:101", "live:102", "movie:201", "episode:301"]
        );
        assert!(keys[4].starts_with("url:"));
        let leaked: i64 = c
            .query_row(
                "SELECT count(*) FROM items WHERE url LIKE '%alice%' OR url LIKE '%s3cret%'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(leaked, 0, "credentials must be templated before storing");
        let url: String = c
            .query_row("SELECT url FROM items WHERE key = 'live:101'", [], |r| {
                r.get(0)
            })
            .unwrap();
        assert_eq!(
            fill_secrets(&url, &["alice", "s3cret"]),
            "http://h.example.invalid/live/alice/s3cret/101.ts"
        );
    }

    #[test]
    fn resync_upserts_by_key_and_removes_stale_rows() {
        let mut c = db();
        c.execute("INSERT INTO favourites VALUES ('live:102', 1)", [])
            .unwrap();
        let changed = PLAYLIST
            .replace("BR München FHD", "BR München HD")
            .replace("Plain Stream", "Gone");
        let changed = changed.replace("#EXTINF:-1 group-title=\"Other\",Gone\nhttp://other.example.invalid/stream?token=s3cret\n", "");
        let stats = import_m3u(&mut c, changed.as_bytes(), &["alice", "s3cret"]).unwrap();
        assert_eq!((stats.entries, stats.removed), (4, 1));
        // The favourite survives the re-sync and the renamed channel is found by its new name only.
        assert_eq!(
            names(&search(&c, "br munchen", None, 10, 0).unwrap()),
            ["BR München HD"]
        );
        assert!(search(&c, "plain", None, 10, 0).unwrap().is_empty());
        let fav: i64 = c
            .query_row(
                "SELECT count(*) FROM favourites f JOIN items i USING (key)",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(fav, 1);
    }

    #[test]
    fn search_matches_prefixes_diacritics_and_numbers() {
        let c = db();
        // (query, expected names in order)
        let table: &[(&str, &[&str])] = &[
            ("ard sport", &["DE | ARD Sportschau HD"]),
            ("sportsch", &["DE | ARD Sportschau HD"]),
            ("munchen", &["BR München FHD"]),
            ("MÜNCHEN", &["BR München FHD"]),
            ("7", &["BR München FHD"]),
            ("reise 2019", &["Die Reise (2019)"]),
            ("planet", &["Planet Wissen S01E02"]),
            ("\"ard\" OR -x", &[]), // user-typed FTS syntax is just words: "ard" "or" "x" → no match
            ("", &[]),
            ("zzz", &[]),
        ];
        for (q, expected) in table {
            assert_eq!(
                names(&search(&c, q, None, 10, 0).unwrap()),
                *expected,
                "query {q:?}"
            );
        }
        assert_eq!(
            search_counts(&c, "e").unwrap().len(),
            0,
            "a single letter only prefixes words starting with it"
        );
        assert_eq!(
            search(&c, "planet", Some(Kind::Live), 10, 0).unwrap().len(),
            0
        );
    }

    #[test]
    fn ranking_favourites_then_recents_then_prefix() {
        let mut c = open(Path::new(":memory:")).unwrap();
        let pl = "#EXTINF:-1,Kino Welt\nhttp://h/live/u/p/1.ts\n#EXTINF:-1,Das Kino\nhttp://h/live/u/p/2.ts\n#EXTINF:-1,Kino Plus\nhttp://h/live/u/p/3.ts\n#EXTINF:-1,Mein Kino\nhttp://h/live/u/p/4.ts\n";
        import_m3u(&mut c, pl.as_bytes(), &[]).unwrap();
        assert_eq!(
            names(&search(&c, "kino", None, 10, 0).unwrap()),
            ["Kino Welt", "Kino Plus", "Das Kino", "Mein Kino"]
        );
        c.execute("INSERT INTO favourites VALUES ('live:4', 1)", [])
            .unwrap();
        c.execute("INSERT INTO recents VALUES ('live:2', 5)", [])
            .unwrap();
        assert_eq!(
            names(&search(&c, "kino", None, 10, 0).unwrap()),
            ["Mein Kino", "Das Kino", "Kino Welt", "Kino Plus"]
        );
        assert_eq!(
            names(&search(&c, "kino", None, 2, 2).unwrap()),
            ["Kino Welt", "Kino Plus"],
            "paging"
        );
    }

    /// A version-1 database on disk gets the new column, a backup copy, and keeps its rows.
    #[test]
    fn migrates_forward_with_a_backup() {
        let dir = std::env::temp_dir().join(format!("gerdtv-migrate-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("p.db");
        {
            // A schema-1 fixture: the base schema and one row, as release 0.261121.9 wrote it.
            let c = Connection::open(&path).unwrap();
            c.execute_batch(SCHEMA).unwrap();
            c.execute("INSERT INTO meta VALUES ('schema', '1')", [])
                .unwrap();
            c.execute("INSERT INTO items (key, kind, name, category, position, seen) VALUES ('live:1', 0, 'Arte', 'g', 0, 1)", []).unwrap();
        }
        let c = open(&path).unwrap();
        let settings: i64 = c
            .query_row("SELECT count(*) FROM settings", [], |r| r.get(0))
            .unwrap();
        assert_eq!(settings, 0, "version 3 adds the settings table");
        let (name, ext): (String, String) = c
            .query_row("SELECT name, ext FROM items", [], |r| {
                Ok((r.get(0)?, r.get(1)?))
            })
            .unwrap();
        assert_eq!((name.as_str(), ext.as_str()), ("Arte", ""));
        let v: String = c
            .query_row("SELECT value FROM meta WHERE key = 'schema'", [], |r| {
                r.get(0)
            })
            .unwrap();
        assert_eq!(v, SCHEMA_VERSION.to_string());
        let backups = std::fs::read_dir(&dir)
            .unwrap()
            .filter(|e| {
                e.as_ref()
                    .unwrap()
                    .file_name()
                    .to_string_lossy()
                    .contains(".bak-")
            })
            .count();
        assert_eq!(backups, 1);
        drop(c);
        // Opening again migrates nothing and makes no new backup.
        drop(open(&path).unwrap());
        let backups = std::fs::read_dir(&dir)
            .unwrap()
            .filter(|e| {
                e.as_ref()
                    .unwrap()
                    .file_name()
                    .to_string_lossy()
                    .contains(".bak-")
            })
            .count();
        assert_eq!(backups, 1);
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn clean_names() {
        for (raw, clean) in [
            ("DE | ARD HD", "ARD"),
            ("[DE] ZDF FHD", "ZDF"),
            ("UK: BBC One 4K", "BBC One"),
            ("Sky Cinema (HEVC)", "Sky Cinema"),
            ("Arte", "Arte"),
            ("Disney Channel: Kids", "Disney Channel: Kids"),
        ] {
            assert_eq!(clean_name(raw), clean, "{raw}");
        }
    }

    #[test]
    fn secrets_template_longest_first() {
        assert_eq!(
            template_secrets("http://h/live/bob/bobby/1.ts", &["bob", "bobby"]),
            "http://h/live/{secret0}/{secret1}/1.ts"
        );
        assert_eq!(
            fill_secrets("http://h/live/{secret0}/{secret1}/1.ts", &["bob", "bobby"]),
            "http://h/live/bob/bobby/1.ts"
        );
    }
}
