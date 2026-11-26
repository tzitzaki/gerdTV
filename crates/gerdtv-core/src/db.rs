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
use std::path::{Path, PathBuf};

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

/// The order of a list (groups, a group's items, favourites), chosen per section in the list's top bar and stored as
/// a profile setting. Each maps to a fixed ORDER BY (never built from input); provider order breaks every tie, so
/// paging stays stable. NULLs (no number, year, date or rating) go last in every order.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Sort {
    #[default]
    Provider,
    NameAsc,
    NameDesc,
    Number,
    YearDesc,
    YearAsc,
    Added,
    Rating,
}

impl Sort {
    /// The setting's value; anything unknown (an older or newer app wrote it) is provider order.
    pub fn parse(s: &str) -> Sort {
        match s {
            "name_asc" => Sort::NameAsc,
            "name_desc" => Sort::NameDesc,
            "number" => Sort::Number,
            "year_desc" => Sort::YearDesc,
            "year_asc" => Sort::YearAsc,
            "added" => Sort::Added,
            "rating" => Sort::Rating,
            _ => Sort::Provider,
        }
    }

    /// ORDER BY terms for items under the table alias `a` (`folded` starts with the cleaned, accent-free name, so
    /// "DE | ARD HD" sorts under A).
    pub fn items_sql(self, a: &str) -> String {
        let terms = match self {
            Sort::Provider => "",
            Sort::NameAsc => "{a}folded, ",
            Sort::NameDesc => "{a}folded DESC, ",
            Sort::Number => "{a}number IS NULL, {a}number, ",
            Sort::YearDesc => "{a}year IS NULL, {a}year DESC, ",
            Sort::YearAsc => "{a}year IS NULL, {a}year, ",
            Sort::Added => "{a}added IS NULL, {a}added DESC, ",
            Sort::Rating => "{a}rating IS NULL, {a}rating DESC, ",
        };
        format!("{terms}{{a}}position").replace("{a}", a)
    }

    /// ORDER BY for groups (categories, alias `c`): only provider order and by name; the others keep provider order.
    pub fn groups_sql(self) -> &'static str {
        match self {
            Sort::NameAsc => "c.name COLLATE NOCASE, c.position",
            Sort::NameDesc => "c.name COLLATE NOCASE DESC, c.position",
            _ => "c.position",
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
    // 5 → 6: search in every section. `folded`: the cleaned names (plus tvg-name) lower-case and without accents, for
    // mid-word matches ("sport" → "Eurosport") by a plain scan when word matches don't fill a page; a vocabulary
    // view of the name index feeds typo matching; the last searches per section (user data). No extra full-text
    // index: each one cost about a second per 150k entries at every sync (import budget, bench gate). `reindex` fills
    // `folded` right after this step; the next sync adds the tvg-names.
    "ALTER TABLE items ADD COLUMN folded TEXT NOT NULL DEFAULT '';
     CREATE VIRTUAL TABLE items_vocab USING fts5vocab(items_fts, 'row');
     CREATE TABLE search_history (section TEXT NOT NULL, query TEXT NOT NULL, updated_at INTEGER NOT NULL,
        PRIMARY KEY (section, query));",
    // 6 → 7: continue watching: where a movie or episode was left (user data, seconds).
    "CREATE TABLE resume (key TEXT PRIMARY KEY, position INTEGER NOT NULL, duration INTEGER NOT NULL,
        updated_at INTEGER NOT NULL);",
    // 7 → 8: groups the user hid (user data): left out of the lists, search, the guide and every row.
    "CREATE TABLE hidden_groups (kind INTEGER NOT NULL, category TEXT NOT NULL, updated_at INTEGER NOT NULL,
        PRIMARY KEY (kind, category));",
    // 8 → 9: sort by "recently added" and "rating" (Xtream Codes `added` / `last_modified` and `rating`; M3U has
    // neither, so both stay NULL there). Catalogue data: the next sync fills them. And a display name may name a
    // channel in several guide sources (the match picks the one with programmes, the provider's first), so
    // `epg_names` is keyed by name and channel (derived data: copied over, rebuilt by every import).
    "ALTER TABLE items ADD COLUMN added INTEGER;
     ALTER TABLE items ADD COLUMN rating REAL;
     CREATE TABLE epg_names_new (norm TEXT NOT NULL, channel TEXT NOT NULL, PRIMARY KEY (norm, channel));
     INSERT INTO epg_names_new SELECT norm, channel FROM epg_names;
     DROP TABLE epg_names;
     ALTER TABLE epg_names_new RENAME TO epg_names;",
    // 9 → 10: guide sources: an offset of their own (the profile's stays the provider's; extra sources take it over,
    // so nothing shifts on update), what the server said about the last download (to ask for changes only) and what
    // it was imported with. Channels: whether the file has programmes for them, for the mapping suggestions.
    "ALTER TABLE epg_sources ADD COLUMN offset_hours INTEGER NOT NULL DEFAULT 0;
     ALTER TABLE epg_sources ADD COLUMN etag TEXT NOT NULL DEFAULT '';
     ALTER TABLE epg_sources ADD COLUMN last_modified TEXT NOT NULL DEFAULT '';
     ALTER TABLE epg_sources ADD COLUMN imported_with TEXT NOT NULL DEFAULT '';
     ALTER TABLE epg_channels ADD COLUMN filled INTEGER NOT NULL DEFAULT 0;
     UPDATE epg_sources SET offset_hours = coalesce((SELECT CAST(value AS INTEGER) FROM settings
        WHERE key = 'guide_offset_hours'), 0) WHERE builtin = 0;",
    // 10 → 11: movies and episodes seen to the end (user data). An unmark is stored too (watched = 0), so it wins
    // over an older mark from an import or from Simkl.
    // The user's own groups, names and group order (groups.rs, user data); removed ones stay as deleted = 1. And
    // TMDB's answers per item (tmdb.rs, a cache: kept 30 days, not exported), and episodes Simkl knows as watched
    // whose series hasn't been opened yet (watch_import.rs; applied when it is), and the recordings of this device
    // (recorder.rs; not exported: their files are here).
    "CREATE TABLE watched (key TEXT PRIMARY KEY, watched INTEGER NOT NULL, updated_at INTEGER NOT NULL);
     CREATE TABLE custom_groups (id TEXT PRIMARY KEY, kind INTEGER NOT NULL, name TEXT NOT NULL,
        position INTEGER NOT NULL, deleted INTEGER NOT NULL, updated_at INTEGER NOT NULL);
     CREATE TABLE custom_group_items (group_id TEXT NOT NULL, item_key TEXT NOT NULL, position INTEGER NOT NULL,
        deleted INTEGER NOT NULL, updated_at INTEGER NOT NULL, PRIMARY KEY (group_id, item_key));
     CREATE TABLE group_prefs (kind INTEGER NOT NULL, category TEXT NOT NULL, name TEXT NOT NULL DEFAULT '',
        position INTEGER, updated_at INTEGER NOT NULL, PRIMARY KEY (kind, category));
     CREATE TABLE item_prefs (key TEXT PRIMARY KEY, name TEXT NOT NULL, provider_name TEXT NOT NULL DEFAULT '',
        updated_at INTEGER NOT NULL);
     CREATE TABLE tmdb (key TEXT PRIMARY KEY, data TEXT NOT NULL, fetched_at INTEGER NOT NULL);
     CREATE TABLE waiting_watched (series TEXT NOT NULL, season INTEGER NOT NULL, episode INTEGER NOT NULL,
        updated_at INTEGER NOT NULL, PRIMARY KEY (series, season, episode));
     CREATE TABLE recordings (id INTEGER PRIMARY KEY, item_key TEXT NOT NULL, title TEXT NOT NULL,
        start INTEGER NOT NULL, stop INTEGER NOT NULL, state TEXT NOT NULL DEFAULT 'scheduled',
        file TEXT NOT NULL DEFAULT '', message TEXT NOT NULL DEFAULT '', bytes INTEGER NOT NULL DEFAULT 0,
        updated_at INTEGER NOT NULL);",
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
-- Every recovery the watchdog made or gave up on (Settings → Playback → Stream health, diagnostics export).
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
        migrate_step(&conn, current, MIGRATIONS[(current - 1) as usize])?;
        current += 1;
    }
    if path != Path::new(":memory:") {
        prune_backups(&conn, path);
    }
    Ok(conn)
}

/// One migration step with its version number, all or nothing: after a crash or an error halfway the next start finds
/// the version it left, not a half-changed schema whose ALTERs would fail a second time.
fn migrate_step(conn: &Connection, from: i64, sql: &str) -> Result<()> {
    let tx = conn.unchecked_transaction()?;
    tx.execute_batch(sql)?;
    if from == 5 {
        reindex(&tx)?; // step 5 → 6 added empty search indexes
    }
    tx.execute(
        "INSERT INTO meta (key, value) VALUES ('schema', ?1) ON CONFLICT (key) DO UPDATE SET value = ?1",
        [(from + 1).to_string()],
    )?;
    tx.commit()
}

/// The backups of the database at `path` (`<name>.db.bak-<unix seconds>`, nothing else), oldest first.
pub fn backups(path: &Path) -> Vec<PathBuf> {
    let Some(prefix) = path
        .file_name()
        .map(|n| format!("{}.bak-", n.to_string_lossy()))
    else {
        return Vec::new();
    };
    let mut found: Vec<(u64, PathBuf)> = path
        .parent()
        .and_then(|dir| std::fs::read_dir(dir).ok())
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|e| {
            let name = e.file_name().to_string_lossy().into_owned();
            let at = name.strip_prefix(&prefix)?;
            // Digits only: parse() alone would also take "+5".
            let digits = at.bytes().all(|b| b.is_ascii_digit());
            Some((at.parse().ok().filter(|_| digits)?, e.path()))
        })
        .collect();
    found.sort();
    found.into_iter().map(|(_, p)| p).collect()
}

/// Deletes all but the newest backup (owner decision), and only while the opened database is sound: a damaged one may
/// need an older copy. Nothing to prune costs one directory listing; the check runs only before a deletion.
fn prune_backups(conn: &Connection, path: &Path) {
    let all = backups(path);
    let Some((_newest, old)) = all.split_last().filter(|(_, old)| !old.is_empty()) else {
        return;
    };
    let sound = conn
        .query_row("PRAGMA quick_check(1)", [], |r| r.get::<_, String>(0))
        .is_ok_and(|r| r == "ok");
    if !sound {
        tracing::warn!("database check failed, all backups kept");
        return;
    }
    for p in old {
        if let Err(e) = std::fs::remove_file(p) {
            tracing::warn!("old database backup not deleted: {e}"); // tried again at the next start
        }
    }
}

/// Fills `folded` from the stored names (after migration 6); the tvg-names follow with the next sync.
fn reindex(conn: &Connection) -> Result<()> {
    let rows: Vec<(i64, String)> = conn
        .prepare("SELECT rowid, name FROM items")?
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?
        .collect::<Result<_>>()?;
    let mut set = conn.prepare("UPDATE items SET folded = ?2 WHERE rowid = ?1")?;
    for (rowid, name) in rows {
        set.execute(params![rowid, fold(&clean_name(&name))])?;
    }
    Ok(())
}

/// Writes one item into the name index, replacing what was there unless the row is `fresh` (just inserted: nothing
/// to delete; the delete was a fifth of a 150k import).
fn index_item(conn: &Connection, rowid: i64, fresh: bool, name: &str, alt: &str) -> Result<()> {
    if !fresh {
        conn.prepare_cached("DELETE FROM items_fts WHERE rowid = ?1")?
            .execute([rowid])?;
    }
    conn.prepare_cached("INSERT INTO items_fts (rowid, name, alt) VALUES (?1, ?2, ?3)")?
        .execute(params![rowid, name, alt])?;
    Ok(())
}

/// Changes an item's name with its search index (the user's own name, groups.rs).
pub fn rename_item(conn: &Connection, key: &str, name: &str) -> Result<()> {
    let alt = clean_name(name);
    let rowid: i64 = conn.query_row(
        "UPDATE items SET name = ?2, folded = ?3 WHERE key = ?1 RETURNING rowid",
        params![key, name, fold(&alt)],
        |r| r.get(0),
    )?;
    index_item(conn, rowid, false, name, &alt)
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
    // "|DE| Name" is "DE| Name" below.
    let mut s = name.trim().trim_start_matches('|');
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
    /// Xtream Codes movies and series: when the provider added it (unix seconds), for "recently added".
    pub added: Option<i64>,
    /// Xtream Codes movies and series: the provider's rating (0–10; a 0 counts as "no rating").
    pub rating: Option<f64>,
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
        // An upsert that inserts moves last_insert_rowid to the new row; one that updates leaves it alone.
        let before = self.tx.last_insert_rowid();
        let alt = format!("{} {}", clean_name(&it.name), clean_name(&it.alt));
        let rowid: i64 = self.tx.prepare_cached(
            "INSERT INTO items (key, kind, name, category, logo, epg_id, number, url, season, episode, year, position, seen, ext,
               archive_days, folded, added, rating)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18)
             ON CONFLICT (key) DO UPDATE SET kind = ?2, name = ?3, category = ?4, logo = ?5, epg_id = ?6,
               number = ?7, url = ?8, season = ?9, episode = ?10, year = ?11, position = ?12, seen = ?13, ext = ?14,
               archive_days = ?15, folded = ?16, added = ?17, rating = ?18
             RETURNING rowid",
        )?.query_row(
            params![it.key, kind as i64, it.name, it.category, it.logo, it.epg_id, it.number, it.url, it.season,
                    it.episode, it.year, self.position, self.generation, it.ext, it.archive_days, fold(&alt),
                    it.added, it.rating],
            |r| r.get(0),
        )?;
        let fresh = self.tx.last_insert_rowid() != before && self.tx.last_insert_rowid() == rowid;
        index_item(&self.tx, rowid, fresh, &it.name, &alt)?;
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
        crate::groups::apply(&self.tx)?;
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
            added: None, // M3U has no date added and no rating
            rating: None,
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
    /// The group's name, where a list shows it (favourites, continue watching); search leaves it to the app.
    pub group: String,
}

/// The words of user input: lower-case runs of letters and digits. Quotes, `-` or `AND` typed by the user are never
/// FTS syntax, because every word is quoted again by the query builders below.
fn words(input: &str) -> Vec<String> {
    input
        .split(|c: char| !c.is_alphanumeric())
        .filter(|w| !w.is_empty())
        .map(str::to_lowercase)
        .collect()
}

/// The FTS5 query for user input: every word a quoted prefix (`ard sport` → `"ard"* "sport"*`). Diacritics are folded
/// by the tokenizer. Programme search uses it as is.
pub fn fts_query(input: &str) -> Option<String> {
    let w = words(input);
    (!w.is_empty()).then(|| {
        w.iter()
            .map(|w| format!("\"{w}\"*"))
            .collect::<Vec<_>>()
            .join(" ")
    })
}

/// Lower-case and without diacritics, the way the search tokenizers fold text (`unicode61 remove_diacritics 2`), for
/// comparing a query word with index terms (typos) and with group names. Covers Latin letters; others stay as they are.
pub fn fold(s: &str) -> String {
    s.chars()
        .flat_map(char::to_lowercase)
        .map(|c| match c {
            'à'..='å' | 'ā' | 'ă' | 'ą' => 'a',
            'ç' | 'ć' | 'č' => 'c',
            'ď' | 'đ' => 'd',
            'è'..='ë' | 'ē' | 'ė' | 'ę' | 'ě' => 'e',
            'ğ' => 'g',
            'ì'..='ï' | 'ī' | 'į' | 'ı' => 'i',
            'ł' | 'ľ' => 'l',
            'ñ' | 'ń' | 'ň' => 'n',
            'ò'..='ö' | 'ø' | 'ō' | 'ő' => 'o',
            'ř' => 'r',
            'ś' | 'š' | 'ş' => 's',
            'ť' | 'ţ' => 't',
            'ù'..='ü' | 'ū' | 'ů' | 'ű' => 'u',
            'ý' | 'ÿ' => 'y',
            'ź' | 'ż' | 'ž' => 'z',
            c => c,
        })
        .collect()
}

/// Edit distance with swapped neighbours counting once (optimal string alignment): "dzan" → "dazn" is 1.
fn osa(a: &[char], b: &[char]) -> usize {
    let mut d = vec![vec![0usize; b.len() + 1]; a.len() + 1];
    for (i, row) in d.iter_mut().enumerate() {
        row[0] = i;
    }
    for (j, cell) in d[0].iter_mut().enumerate() {
        *cell = j;
    }
    for i in 1..=a.len() {
        for j in 1..=b.len() {
            let cost = usize::from(a[i - 1] != b[j - 1]);
            d[i][j] = (d[i - 1][j] + 1)
                .min(d[i][j - 1] + 1)
                .min(d[i - 1][j - 1] + cost);
            if i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1] {
                d[i][j] = d[i][j].min(d[i - 2][j - 2] + 1);
            }
        }
    }
    d[a.len()][b.len()]
}

/// How many typos a query word may have (owner decision): none below 4 letters (too many short words look alike),
/// 1 from 4 letters, 2 from 7.
fn typo_budget(len: usize) -> usize {
    match len {
        0..=3 => 0,
        4..=6 => 1,
        _ => 2,
    }
}

/// Whether two words are the same but for a typo (within the budget of the shorter one).
pub fn is_typo(a: &str, b: &str) -> bool {
    let (a, b): (Vec<char>, Vec<char>) = (a.chars().collect(), b.chars().collect());
    a == b || osa(&a, &b) <= typo_budget(a.len().min(b.len()))
}

/// The index terms a word could be a typo of: within its budget of the word, compared with the term's start too (the
/// user may still be typing: "bundesliag" → "bundesliga…", "dazm" → "dazn1"). Terms the word already prefixes are left out (those match
/// anyway). The first letter must be right, or the first two swapped: that keeps the vocabulary lookup to two short
/// ranges instead of a full scan. At most 20 terms, closest and most common first.
fn typo_terms(conn: &Connection, word: &str) -> Result<Vec<String>> {
    let w: Vec<char> = fold(word).chars().collect();
    let max = typo_budget(w.len());
    if max == 0 {
        return Ok(vec![]);
    }
    let mut starts = vec![w[0].to_string()];
    if w[1] != w[0] {
        starts.push(w[1].to_string());
    }
    let mut found: Vec<(usize, i64, String)> = Vec::new();
    let mut st = conn.prepare_cached(
        "SELECT term, doc FROM items_vocab WHERE term >= ?1 AND term < ?1 || char(1114111)",
    )?;
    for start in starts {
        let rows = st.query_map([start], |r| {
            Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?))
        })?;
        for row in rows {
            let (term, docs) = row?;
            let t: Vec<char> = term.chars().collect();
            if t.starts_with(&w) {
                continue;
            }
            // Term starts at least as long as the word: a shorter one would let "plain" match "plan(et)".
            let best = (w.len()..=w.len() + max)
                .filter(|&k| k <= t.len())
                .map(|k| osa(&w, &t[..k]))
                .min();
            if let Some(d) = best.filter(|&d| d <= max) {
                found.push((d, -docs, term));
            }
        }
    }
    found.sort();
    found.dedup_by(|a, b| a.2 == b.2);
    Ok(found.into_iter().take(20).map(|f| f.2).collect())
}

/// One match tier of a query: a set of item rowids as SQL, its parameters numbered from `?1`.
struct Arm {
    set: String,
    params: Vec<rusqlite::types::Value>,
}

/// The match tiers of a query, best first, each built only when reached (the typo tier reads the vocabulary):
/// 0 every word starts a word of the name (or the input is a channel number), 1 the words found in name and group
/// together (a channel of the "DE | DAZN" group; needs a word of 3+ letters, "s" would add every channel of every
/// group with an s-word), 2 mid-word in the name (trigram over the cleaned names, words of 3+ letters; shorter words
/// must still start a word), 3 with typos.
fn arm(conn: &Connection, input: &str, k: usize) -> Result<Option<Arm>> {
    use rusqlite::types::Value::{Integer, Null, Text};
    let w = words(input);
    if w.is_empty() {
        return Ok(None);
    }
    let join = |f: &dyn Fn(&String) -> String, ws: &[&String]| {
        ws.iter().map(|w| f(w)).collect::<Vec<_>>().join(" ")
    };
    let all: Vec<&String> = w.iter().collect();
    let long: Vec<&String> = w.iter().filter(|w| w.chars().count() >= 3).collect();
    let short: Vec<&String> = w.iter().filter(|w| w.chars().count() < 3).collect();
    let prefix = |ws: &[&String]| join(&|w| format!("\"{w}\"*"), ws);
    const FTS: &str = "SELECT rowid FROM items_fts WHERE items_fts MATCH";
    Ok(match k {
        0 => Some(Arm {
            set: format!("{FTS} ?1 UNION SELECT rowid FROM items WHERE kind = 0 AND number = ?2"),
            params: vec![
                Text(prefix(&all)),
                input.trim().parse::<i64>().map_or(Null, Integer),
            ],
        }),
        // Each word in the name or in the group's name. The groups are few: matched here, their items fetched
        // by the category index. Nothing to add when no group name has any of the words.
        1 if !long.is_empty() => {
            let groups: Vec<(i64, String)> = conn
                .prepare_cached("SELECT rowid, name FROM categories")?
                .query_map([], |r| Ok((r.get(0)?, fold(&r.get::<_, String>(1)?))))?
                .collect::<Result<_>>()?;
            let per_word: Vec<Vec<i64>> = all
                .iter()
                .map(|w| {
                    let w = fold(w);
                    groups
                        .iter()
                        .filter(|(_, name)| {
                            name.split(|c: char| !c.is_alphanumeric())
                                .any(|t| t.starts_with(&w))
                        })
                        .map(|(id, _)| *id)
                        .collect()
                })
                .collect();
            if per_word.iter().all(Vec::is_empty) {
                None
            } else {
                // Each word's UNION in its own subquery: compound operators bind left to right.
                let set = (0..all.len())
                    .map(|i| {
                        format!(
                            "SELECT rowid FROM ({FTS} ?{a} UNION SELECT i.rowid FROM categories c
                               JOIN items i ON i.kind = c.kind AND i.category = c.id
                               WHERE c.rowid IN (SELECT value FROM json_each(?{b})))",
                            a = 2 * i + 1,
                            b = 2 * i + 2
                        )
                    })
                    .collect::<Vec<_>>()
                    .join(" INTERSECT ");
                let mut params = Vec::new();
                for (w, ids) in all.iter().zip(&per_word) {
                    params.push(Text(format!("\"{w}\"*")));
                    params.push(Text(format!("{ids:?}")));
                }
                Some(Arm { set, params })
            }
        }
        // Mid-word: each long word inside the folded names (a scan, run only when better tiers don't fill a page);
        // short words must still start a word.
        2 if !long.is_empty() => {
            let mut set = format!(
                "SELECT rowid FROM items WHERE {}",
                (1..=long.len())
                    .map(|i| format!("instr(folded, ?{i}) > 0"))
                    .collect::<Vec<_>>()
                    .join(" AND ")
            );
            let mut params: Vec<_> = long.iter().map(|w| Text(fold(w))).collect();
            if !short.is_empty() {
                params.push(Text(prefix(&short)));
                set += &format!(" INTERSECT {FTS} ?{}", params.len());
            }
            Some(Arm { set, params })
        }
        3 => {
            let mut any = false;
            let mut groups = Vec::new();
            for word in &w {
                let terms = typo_terms(conn, word)?;
                any |= !terms.is_empty();
                // A single word needs only its typo terms (its prefix matches are tier 0 already).
                let own = (w.len() > 1).then(|| format!("\"{word}\"*"));
                let alts: Vec<String> = own
                    .into_iter()
                    .chain(terms.iter().map(|t| format!("\"{t}\"")))
                    .collect();
                if !alts.is_empty() {
                    groups.push(format!("({})", alts.join(" OR ")));
                }
            }
            (any && groups.len() == w.len()).then(|| Arm {
                set: format!("{FTS} ?1"),
                params: vec![Text(groups.join(" AND "))],
            })
        }
        _ => None,
    })
}

/// The tiers of a query: 4, some of them empty (None) for this input.
const ARMS: usize = 4;

/// `AND NOT <hidden>` for a WHERE clause, or nothing when no group is hidden.
pub fn visible_and(conn: &Connection, i: &str) -> Result<String> {
    Ok(if any_hidden(conn)? {
        format!("AND NOT {}", hidden_sql(i))
    } else {
        String::new()
    })
}

/// A bit per kind for `kinds` (empty = every kind), for `(mask >> kind) & 1` in SQL.
fn kind_mask(kinds: &[Kind]) -> i64 {
    if kinds.is_empty() {
        return 0b1111;
    }
    kinds.iter().fold(0, |m, k| m | 1 << *k as i64)
}

/// Renumbers an arm's `?n` parameters to start after `base` (arms are combined into one statement).
fn shift(sql: &str, base: usize) -> String {
    let mut out = String::new();
    let mut chars = sql.chars().peekable();
    while let Some(c) = chars.next() {
        out.push(c);
        if c == '?' {
            let mut n = String::new();
            while let Some(d) = chars.peek().filter(|d| d.is_ascii_digit()) {
                n.push(*d);
                chars.next();
            }
            out.push_str(&(n.parse::<usize>().unwrap() + base).to_string());
        }
    }
    out
}

/// Searches the catalogue, tier by tier (`arm`): each tier's rows that no better tier has, ordered like this:
/// favourites, then recently watched, then an exact channel number, then names starting with the query, then
/// provider order. A tier is only queried once the better ones can't fill the page: most searches are answered by
/// word starts alone, as fast as a plain word search (bench gate: within 20 % of the search before the tiers).
/// `kinds` narrows to a section (empty = all), `category` to one group of it.
pub fn search(
    conn: &Connection,
    input: &str,
    kinds: &[Kind],
    category: Option<&str>,
    limit: usize,
    offset: usize,
) -> Result<Vec<Hit>> {
    let visible = visible_and(conn, "i")?;
    let mut out: Vec<Hit> = Vec::new();
    let mut skip = offset;
    let mut better: Vec<Arm> = Vec::new();
    for k in 0..ARMS {
        let Some(a) = arm(conn, input, k)? else {
            continue;
        };
        // Rows of this tier that no better tier has, inside the filters.
        let mut params = a.params.clone();
        let mut excl = String::new();
        for b in &better {
            excl += &format!(" AND i.rowid NOT IN ({})", shift(&b.set, params.len()));
            params.extend(b.params.iter().cloned());
        }
        let n = params.len();
        params.extend([
            rusqlite::types::Value::Integer(kind_mask(kinds)),
            category.map_or(rusqlite::types::Value::Null, |c| {
                rusqlite::types::Value::Text(c.into())
            }),
            rusqlite::types::Value::Text(format!("{}%", input.trim())),
            input.trim().parse::<i64>().map_or(
                rusqlite::types::Value::Null,
                rusqlite::types::Value::Integer,
            ),
        ]);
        let from = format!(
            "FROM items i LEFT JOIN favourites f ON f.key = i.key LEFT JOIN recents r ON r.key = i.key
             WHERE i.rowid IN ({}){excl} AND (?{m} >> i.kind) & 1 AND (?{g} IS NULL OR i.category = ?{g}) {visible}",
            a.set,
            m = n + 1,
            g = n + 2,
        );
        let need = limit - out.len();
        // No group name here: even a lookup for the 50 rows shown cost a sixth of a short search (bench gate); the
        // app knows the section's groups already (section_search.dart).
        let sql = format!(
            "SELECT i.key, i.kind, i.name, i.category, i.logo, i.number, i.archive_days {from}
             ORDER BY f.key IS NULL, r.updated_at IS NULL, r.updated_at DESC,
                      CASE WHEN ?{num} IS NOT NULL AND i.number = ?{num} THEN 0 ELSE 1 END,
                      i.name NOT LIKE ?{p}, i.position
             LIMIT {need} OFFSET {skip}",
            num = n + 4,
            p = n + 3,
        );
        let rows: Vec<Hit> = conn
            .prepare_cached(&sql)?
            .query_map(rusqlite::params_from_iter(params.iter()), |r| {
                Ok(Hit {
                    key: r.get(0)?,
                    kind: Kind::from_i64(r.get(1)?),
                    name: r.get(2)?,
                    category: r.get(3)?,
                    logo: r.get(4)?,
                    number: r.get(5)?,
                    archive_days: r.get(6)?,
                    group: String::new(),
                })
            })?
            .collect::<Result<_>>()?;
        // How many rows the tier has, as far as it matters: it lay wholly before the page (skip by its size), it
        // reached into the page, or it is empty (then later tiers needn't exclude it: the mid-word scan twice
        // doubled a typo search).
        let mut empty = rows.is_empty();
        if rows.is_empty() && skip > 0 {
            let c: i64 = conn.query_row(
                &format!("SELECT count(*) {from}"),
                rusqlite::params_from_iter(params[..n + 2].iter()),
                |r| r.get(0),
            )?;
            skip -= (c as usize).min(skip);
            empty = c == 0;
        } else {
            skip = 0;
        }
        out.extend(rows);
        if out.len() == limit {
            break;
        }
        if !empty {
            better.push(a);
        }
    }
    Ok(out)
}

/// Result counts per kind over the whole catalogue (word starts and channel number, tier 0): the "All groups" chip
/// and the "Also in" hint line. Group-name, mid-word and typo hits aren't counted, to keep this as fast as before.
pub fn search_counts(conn: &Connection, input: &str) -> Result<Vec<(Kind, usize)>> {
    let Some(a) = arm(conn, input, 0)? else {
        return Ok(vec![]);
    };
    let sql = format!(
        "SELECT i.kind, count(*) FROM items i WHERE i.rowid IN ({}) {} GROUP BY i.kind ORDER BY i.kind",
        a.set,
        visible_and(conn, "i")?
    );
    let mut st = conn.prepare_cached(&sql)?;
    let rows = st.query_map(rusqlite::params_from_iter(a.params.iter()), |r| {
        Ok((Kind::from_i64(r.get(0)?), r.get::<_, i64>(1)? as usize))
    })?;
    rows.collect()
}

/// A group whose name matches a search, shown above the items (one tap opens it).
#[derive(Debug, Clone, PartialEq)]
pub struct GroupHit {
    pub kind: Kind,
    pub id: String,
    pub name: String,
    pub count: usize,
}

/// Groups of `kinds` whose name contains every query word (anywhere, diacritics folded), in provider order, at most
/// `limit`. Empty groups are left out, as in the browse lists. Categories are few, so they are compared in Rust.
pub fn search_groups(
    conn: &Connection,
    input: &str,
    kinds: &[Kind],
    limit: usize,
) -> Result<Vec<GroupHit>> {
    let w: Vec<String> = words(input).iter().map(|w| fold(w)).collect();
    if w.is_empty() {
        return Ok(vec![]);
    }
    // Names first, counts only for the matches: counting every group's items on each keystroke cost 16 ms on 150k
    // entries (the count is one indexed lookup per matching group, items_by_category).
    let mut st = conn.prepare_cached(
        "SELECT kind, id, name FROM categories c WHERE (?1 >> kind) & 1
           AND NOT EXISTS (SELECT 1 FROM hidden_groups h WHERE h.kind = c.kind AND h.category = c.id)
         ORDER BY position",
    )?;
    let rows = st.query_map([kind_mask(kinds)], |r| {
        Ok((
            Kind::from_i64(r.get(0)?),
            r.get::<_, String>(1)?,
            r.get::<_, String>(2)?,
        ))
    })?;
    let mut count =
        conn.prepare_cached("SELECT count(*) FROM items WHERE kind = ?1 AND category = ?2")?;
    let mut out = Vec::new();
    for row in rows {
        let (kind, id, name) = row?;
        let folded = fold(&name);
        if !w.iter().all(|w| folded.contains(w.as_str())) {
            continue;
        }
        let n: i64 = count.query_row(params![kind as i64, id], |r| r.get(0))?;
        if n == 0 {
            continue; // empty groups are hidden, as in the browse lists
        }
        out.push(GroupHit {
            kind,
            id,
            name,
            count: n as usize,
        });
        if out.len() == limit {
            break;
        }
    }
    Ok(out)
}

/// Remembers a search the user acted on (opened a result) for a section ("live", "movies", "series", "guide").
/// User data with `updated_at`; only the newest 20 per section are kept.
pub fn record_search(conn: &Connection, section: &str, query: &str) -> Result<()> {
    let query = query.trim();
    if query.is_empty() {
        return Ok(());
    }
    // Delete + insert rather than an upsert: the new rowid orders searches made within the same second.
    conn.execute(
        "DELETE FROM search_history WHERE section = ?1 AND query = ?2",
        params![section, query],
    )?;
    conn.execute(
        "INSERT INTO search_history (section, query, updated_at) VALUES (?1, ?2, ?3)",
        params![section, query, unix_now()],
    )?;
    conn.execute(
        "DELETE FROM search_history WHERE section = ?1 AND query NOT IN
           (SELECT query FROM search_history WHERE section = ?1 ORDER BY updated_at DESC LIMIT 20)",
        [section],
    )?;
    Ok(())
}

/// Marks (`on`) or unmarks an item as a favourite. User data by stable key with `updated_at`: a favourite the provider
/// drops for a while comes back with the item.
pub fn set_favourite(conn: &Connection, key: &str, on: bool) -> Result<()> {
    if on {
        conn.execute(
            "INSERT INTO favourites (key, updated_at) VALUES (?1, ?2)
             ON CONFLICT (key) DO UPDATE SET updated_at = ?2",
            params![key, unix_now()],
        )?;
    } else {
        conn.execute("DELETE FROM favourites WHERE key = ?1", [key])?;
    }
    Ok(())
}

/// The favourites of `kinds` (empty = all) in the section's item order (provider order by default, so channel numbers
/// stay in order; zapping follows the list), with their group's name; ones the catalogue doesn't have right now are
/// left out.
pub fn favourites(conn: &Connection, kinds: &[Kind], sort: Sort) -> Result<Vec<Hit>> {
    let mut st = conn.prepare_cached(&format!(
        "SELECT i.key, i.kind, i.name, i.category, i.logo, i.number, i.archive_days, coalesce(c.name, '')
         FROM favourites f JOIN items i ON i.key = f.key
         LEFT JOIN categories c ON c.kind = i.kind AND c.id = i.category
         WHERE (?1 >> i.kind) & 1 {} ORDER BY i.kind, {}",
        visible_and(conn, "i")?,
        sort.items_sql("i.")
    ))?;
    let rows = st.query_map([kind_mask(kinds)], |r| {
        Ok(Hit {
            key: r.get(0)?,
            kind: Kind::from_i64(r.get(1)?),
            name: r.get(2)?,
            category: r.get(3)?,
            logo: r.get(4)?,
            number: r.get(5)?,
            archive_days: r.get(6)?,
            group: r.get(7)?,
        })
    })?;
    rows.collect()
}

/// SQL: true when the item `i` sits in a hidden group. Xtream Codes episodes name their series as category, so an
/// episode is also hidden with its series' group. Callers add it only when something is hidden (`any_hidden`): the
/// probe runs per row, and search sorts tens of thousands.
pub fn hidden_sql(i: &str) -> String {
    format!(
        "EXISTS (SELECT 1 FROM hidden_groups h WHERE (h.kind = {i}.kind AND h.category = {i}.category)
            OR ({i}.kind = 2 AND (h.kind, h.category) = (SELECT s.kind, s.category FROM items s WHERE s.key = {i}.category)))"
    )
}

/// Whether the user hid any group (most never do: the queries skip the probe then).
pub fn any_hidden(conn: &Connection) -> Result<bool> {
    conn.query_row("SELECT EXISTS (SELECT 1 FROM hidden_groups)", [], |r| {
        r.get(0)
    })
}

/// Hides or shows a group (Settings → Hidden groups).
pub fn set_group_hidden(conn: &Connection, kind: Kind, category: &str, hidden: bool) -> Result<()> {
    if hidden {
        conn.execute(
            "INSERT INTO hidden_groups (kind, category, updated_at) VALUES (?1, ?2, ?3)
             ON CONFLICT (kind, category) DO UPDATE SET updated_at = ?3",
            params![kind as i64, category, unix_now()],
        )?;
    } else {
        conn.execute(
            "DELETE FROM hidden_groups WHERE kind = ?1 AND category = ?2",
            params![kind as i64, category],
        )?;
    }
    Ok(())
}

/// Counts as started after this many seconds (owner decision: 2 min), as finished from this share of the duration.
pub const RESUME_FROM_SECS: u32 = 120;
pub const FINISHED_AT: f64 = 0.95;

/// Remembers how far a movie or episode played. Under 2 min nothing is kept (zapping through isn't "started"), from
/// 95 % it counts as finished: it leaves continue watching and is marked as watched.
pub fn save_progress(conn: &Connection, key: &str, position: u32, duration: u32) -> Result<()> {
    if duration > 0 && position as f64 >= duration as f64 * FINISHED_AT {
        conn.execute("DELETE FROM resume WHERE key = ?1", [key])?;
        set_watched(conn, key, true)?;
    } else if position >= RESUME_FROM_SECS {
        conn.execute(
            "INSERT INTO resume (key, position, duration, updated_at) VALUES (?1, ?2, ?3, ?4)
             ON CONFLICT (key) DO UPDATE SET position = ?2, duration = ?3, updated_at = ?4",
            params![key, position, duration, unix_now()],
        )?;
    }
    Ok(())
}

/// Marks a movie or episode as watched or not (by hand, or at 95 %).
pub fn set_watched(conn: &Connection, key: &str, watched: bool) -> Result<()> {
    conn.execute(
        "INSERT INTO watched (key, watched, updated_at) VALUES (?1, ?2, ?3)
         ON CONFLICT (key) DO UPDATE SET watched = ?2, updated_at = ?3",
        params![key, watched, unix_now()],
    )?;
    Ok(())
}

/// Every watched item's key (the lists' check marks).
pub fn watched_keys(conn: &Connection) -> Result<Vec<String>> {
    let mut st = conn.prepare_cached("SELECT key FROM watched WHERE watched = 1")?;
    let rows = st.query_map([], |r| r.get(0))?;
    rows.collect()
}

/// The episode after `key`: the next season and episode number of its series, skipping the same episode in another
/// quality. Xtream Codes episodes share their series' key as category; an M3U group may hold several shows, so there
/// the name before "S01E02" has to match too. None: the last one, or not a numbered episode.
pub fn next_episode(conn: &Connection, key: &str) -> Result<Option<Hit>> {
    let mut st = conn.prepare_cached(
        "SELECT e.key, e.kind, e.name, e.category, e.logo, e.number, e.archive_days, cur.name
         FROM items cur JOIN items e ON e.kind = 2 AND e.category = cur.category
         WHERE cur.key = ?1 AND cur.kind = 2 AND (e.season, e.episode) > (cur.season, cur.episode)
         ORDER BY e.season, e.episode, e.position",
    )?;
    let mut rows = st.query([key])?;
    while let Some(r) = rows.next()? {
        let hit = Hit {
            key: r.get(0)?,
            kind: Kind::from_i64(r.get(1)?),
            name: r.get(2)?,
            category: r.get(3)?,
            logo: r.get(4)?,
            number: r.get(5)?,
            archive_days: r.get(6)?,
            group: String::new(),
        };
        let current: String = r.get(7)?;
        if hit.category.starts_with("series:") || show_of(&hit.name) == show_of(&current) {
            return Ok(Some(hit));
        }
    }
    Ok(None)
}

/// "DE | Dark S01E02 HD" → "dark": what two episodes of one show share in an M3U group.
fn show_of(name: &str) -> String {
    fold(&clean_name(m3u::before_episode(name)))
}

/// Where to resume an item (seconds), if it was left part-way.
pub fn resume_position(conn: &Connection, key: &str) -> Result<Option<u32>> {
    conn.query_row("SELECT position FROM resume WHERE key = ?1", [key], |r| {
        r.get(0)
    })
    .optional()
}

/// Started, unfinished items of `kinds`, last watched first, with (position, duration) in seconds; at most `limit`.
pub fn continue_watching(
    conn: &Connection,
    kinds: &[Kind],
    limit: usize,
) -> Result<Vec<(Hit, u32, u32)>> {
    let mut st = conn.prepare_cached(&format!(
        "SELECT i.key, i.kind, i.name, i.category, i.logo, i.number, i.archive_days, coalesce(c.name, ''),
                p.position, p.duration
         FROM resume p JOIN items i ON i.key = p.key
         LEFT JOIN categories c ON c.kind = i.kind AND c.id = i.category
         WHERE (?1 >> i.kind) & 1 {} ORDER BY p.updated_at DESC, p.rowid DESC LIMIT ?2",
        visible_and(conn, "i")?
    ))?;
    let rows = st.query_map(params![kind_mask(kinds), limit as i64], |r| {
        Ok((
            Hit {
                key: r.get(0)?,
                kind: Kind::from_i64(r.get(1)?),
                name: r.get(2)?,
                category: r.get(3)?,
                logo: r.get(4)?,
                number: r.get(5)?,
                archive_days: r.get(6)?,
                group: r.get(7)?,
            },
            r.get(8)?,
            r.get(9)?,
        ))
    })?;
    rows.collect()
}

/// Marks an item as watched just now (search ranks recently watched items first).
pub fn touch_recent(conn: &Connection, key: &str) -> Result<()> {
    conn.execute(
        "INSERT INTO recents (key, updated_at) VALUES (?1, ?2) ON CONFLICT (key) DO UPDATE SET updated_at = ?2",
        params![key, unix_now()],
    )?;
    Ok(())
}

/// The live channels played last, newest first (hidden groups left out), for the Android TV home screen.
pub fn recent_channels(conn: &Connection, limit: usize) -> Result<Vec<Hit>> {
    let mut st = conn.prepare_cached(&format!(
        "SELECT i.key, i.kind, i.name, i.category, i.logo, i.number, i.archive_days
         FROM recents r JOIN items i ON i.key = r.key
         WHERE i.kind = 0 {} ORDER BY r.updated_at DESC, r.rowid DESC LIMIT ?1",
        visible_and(conn, "i")?
    ))?;
    let rows = st.query_map([limit as i64], |r| {
        Ok(Hit {
            key: r.get(0)?,
            kind: Kind::from_i64(r.get(1)?),
            name: r.get(2)?,
            category: r.get(3)?,
            logo: r.get(4)?,
            number: r.get(5)?,
            archive_days: r.get(6)?,
            group: String::new(),
        })
    })?;
    rows.collect()
}

/// Every favourite's key (the lists' stars).
pub fn favourite_keys(conn: &Connection) -> Result<Vec<String>> {
    let mut st = conn.prepare_cached("SELECT key FROM favourites")?;
    let rows = st.query_map([], |r| r.get(0))?;
    rows.collect()
}

/// The newest searches of a section, newest first.
pub fn recent_searches(conn: &Connection, section: &str, limit: usize) -> Result<Vec<String>> {
    let mut st = conn.prepare_cached(
        "SELECT query FROM search_history WHERE section = ?1 ORDER BY updated_at DESC, rowid DESC LIMIT ?2",
    )?;
    let rows = st.query_map(params![section, limit as i64], |r| r.get(0))?;
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
            names(&search(&c, "br munchen", &[], None, 10, 0).unwrap()),
            ["BR München HD"]
        );
        assert!(search(&c, "plain", &[], None, 10, 0).unwrap().is_empty());
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
    fn search_matches_prefixes_diacritics_numbers_groups_mid_words_and_typos() {
        let mut c = open(Path::new(":memory:")).unwrap();
        let extra = "#EXTINF:-1 group-title=\"DE | DAZN\",DAZN 1 HD
http://h.example.invalid/live/alice/s3cret/401.ts
#EXTINF:-1 group-title=\"DE | DAZN\",Bundesliga Konferenz
http://h.example.invalid/live/alice/s3cret/402.ts
#EXTINF:-1 group-title=\"DE | Sport\",Eurosport 1
http://h.example.invalid/live/alice/s3cret/403.ts
";
        import_m3u(
            &mut c,
            format!("{PLAYLIST}{extra}").as_bytes(),
            &["alice", "s3cret"],
        )
        .unwrap();
        // (query, expected names in order)
        let table: &[(&str, &[&str])] = &[
            ("ard sport", &["DE | ARD Sportschau HD"]),
            ("sportsch", &["DE | ARD Sportschau HD"]),
            ("munchen", &["BR München FHD"]),
            ("MÜNCHEN", &["BR München FHD"]),
            ("7", &["BR München FHD"]),
            ("reise 2019", &["Die Reise (2019)"]),
            ("planet", &["Planet Wissen S01E02"]),
            // The group counts, after the name hits: every channel of "DE | DAZN".
            ("dazn", &["DAZN 1 HD", "Bundesliga Konferenz"]),
            // Word start first, then via the group "DE | Sport" (Eurosport's own match is only mid-word).
            ("sport", &["DE | ARD Sportschau HD", "Eurosport 1"]),
            ("port", &["DE | ARD Sportschau HD", "Eurosport 1"]), // mid-word only
            ("dazm", &["DAZN 1 HD"]),                             // 1 typo in 4 letters
            ("munchne", &["BR München FHD"]),                     // swapped letters
            ("dzn", &[]),                                         // 3 letters: no typos
            ("\"ard\" OR -x", &[]), // user-typed FTS syntax is just words: "ard" "or" "x" → no match
            ("", &[]),
            ("zzz", &[]),
        ];
        for (q, expected) in table {
            assert_eq!(
                names(&search(&c, q, &[], None, 10, 0).unwrap()),
                *expected,
                "query {q:?}"
            );
        }
        assert_eq!(
            search_counts(&c, "e").unwrap(),
            [(Kind::Live, 1)],
            "a single letter only prefixes words starting with it (Eurosport)"
        );
        assert_eq!(
            search(&c, "planet", &[Kind::Live], None, 10, 0)
                .unwrap()
                .len(),
            0
        );
        assert_eq!(
            search(&c, "planet", &[Kind::Episode], None, 10, 0)
                .unwrap()
                .len(),
            1
        );
        let in_group = search(&c, "1", &[Kind::Live], Some("DE | DAZN"), 10, 0).unwrap();
        assert_eq!(names(&in_group), ["DAZN 1 HD"], "one group only");
        let groups: Vec<String> = search_groups(&c, "DAZN", &[Kind::Live], 5)
            .unwrap()
            .into_iter()
            .map(|g| format!("{} {}", g.name, g.count))
            .collect();
        assert_eq!(groups, ["DE | DAZN 2"]);
        assert!(
            search_groups(&c, "dazn", &[Kind::Movie], 5)
                .unwrap()
                .is_empty()
        );
    }

    #[test]
    fn ranking_match_tiers_with_favourites_then_recents_first_in_each() {
        let mut c = open(Path::new(":memory:")).unwrap();
        let pl = "#EXTINF:-1,Kino Welt\nhttp://h/live/u/p/1.ts\n#EXTINF:-1,Das Kino\nhttp://h/live/u/p/2.ts\n#EXTINF:-1,Kino Plus\nhttp://h/live/u/p/3.ts\n#EXTINF:-1,Mein Kino\nhttp://h/live/u/p/4.ts\n\
            #EXTINF:-1,Kimo TV\nhttp://h/live/u/p/5.ts\n#EXTINF:-1,Superkino\nhttp://h/live/u/p/6.ts\n\
            #EXTINF:-1 group-title=\"Kino Sender\",Film Eins\nhttp://h/live/u/p/7.ts\n#EXTINF:-1,Kinowelt Extra\nhttp://h/live/u/p/8.ts\n";
        import_m3u(&mut c, pl.as_bytes(), &[]).unwrap();
        // Word starts (names starting with the query first, then provider order), via the group, mid-word, typo.
        let tiers = ["Film Eins", "Superkino", "Kimo TV"];
        let words = [
            "Kino Welt",
            "Kino Plus",
            "Kinowelt Extra",
            "Das Kino",
            "Mein Kino",
        ];
        assert_eq!(
            names(&search(&c, "kino", &[], None, 10, 0).unwrap()),
            [&words[..], &tiers].concat()
        );
        assert_eq!(
            names(&search(&c, "kino", &[], None, 3, 4).unwrap()),
            ["Mein Kino", "Film Eins", "Superkino"],
            "a page across tiers"
        );
        assert_eq!(
            names(&search(&c, "kino", &[], None, 5, 6).unwrap()),
            ["Superkino", "Kimo TV"],
            "a page that starts in a later tier skips the earlier ones by their size"
        );
        // Favourites and recently watched first within their tier.
        c.execute("INSERT INTO favourites VALUES ('live:4', 1)", [])
            .unwrap();
        c.execute("INSERT INTO recents VALUES ('live:2', 5)", [])
            .unwrap();
        assert_eq!(
            names(&search(&c, "kino", &[], None, 10, 0).unwrap()),
            [
                &[
                    "Mein Kino",
                    "Das Kino",
                    "Kino Welt",
                    "Kino Plus",
                    "Kinowelt Extra"
                ][..],
                &tiers
            ]
            .concat()
        );
        assert_eq!(
            names(&search(&c, "kino", &[], None, 2, 2).unwrap()),
            ["Kino Welt", "Kino Plus"],
            "paging"
        );
    }

    #[test]
    fn every_sort_orders_with_missing_values_last_and_provider_order_on_ties() {
        let mut c = open(Path::new(":memory:")).unwrap();
        let mut s = Sync::begin(&mut c).unwrap();
        s.category(Kind::Movie, "b", "beta");
        s.category(Kind::Movie, "a", "Alpha");
        // (name, year, added, rating) in provider order.
        let rows = [
            ("Zorro (1998)", Some(1998), Some(300), Some(6.0)),
            ("Ärger (2020)", Some(2020), None, Some(8.5)),
            ("DE | Bambi", None, Some(500), None),
            ("Casablanca (1942)", Some(1942), Some(100), Some(8.5)),
        ];
        for (i, (name, year, added, rating)) in rows.into_iter().enumerate() {
            let it = NewItem {
                key: format!("movie:{i}"),
                name: name.into(),
                category: "a".into(),
                year,
                added,
                rating,
                ..NewItem::default()
            };
            s.item(Kind::Movie, &it).unwrap();
        }
        let b = NewItem {
            key: "movie:9".into(),
            name: "Other".into(),
            category: "b".into(),
            ..NewItem::default()
        };
        s.item(Kind::Movie, &b).unwrap();
        s.finish().unwrap();
        let order = |sort: Sort| -> Vec<String> {
            c.prepare(&format!(
                "SELECT name FROM items WHERE category = 'a' ORDER BY {}",
                sort.items_sql("")
            ))
            .unwrap()
            .query_map([], |r| r.get(0))
            .unwrap()
            .map(|r| r.unwrap())
            .collect()
        };
        let (z, a, b, cb) = (
            "Zorro (1998)",
            "Ärger (2020)",
            "DE | Bambi",
            "Casablanca (1942)",
        );
        for (sort, want) in [
            (Sort::Provider, [z, a, b, cb]),
            (Sort::NameAsc, [a, b, cb, z]), // accents folded, "DE |" prefix ignored
            (Sort::NameDesc, [z, cb, b, a]),
            (Sort::YearDesc, [a, z, cb, b]), // no year last
            (Sort::YearAsc, [cb, z, a, b]),
            (Sort::Added, [b, z, cb, a]),
            (Sort::Rating, [a, cb, z, b]), // the tie at 8.5 keeps provider order
            (Sort::Number, [z, a, b, cb]), // no numbers at all: provider order
        ] {
            assert_eq!(order(sort), want, "{sort:?}");
        }
        // Groups sort by name or keep provider order; favourites follow the items' sort.
        let groups = |sort: Sort| -> Vec<String> {
            c.prepare(&format!(
                "SELECT c.name FROM categories c WHERE kind = 1 ORDER BY {}",
                sort.groups_sql()
            ))
            .unwrap()
            .query_map([], |r| r.get(0))
            .unwrap()
            .map(|r| r.unwrap())
            .collect()
        };
        assert_eq!(groups(Sort::Provider), ["beta", "Alpha"]);
        assert_eq!(groups(Sort::NameAsc), ["Alpha", "beta"]);
        assert_eq!(groups(Sort::NameDesc), ["beta", "Alpha"]);
        assert_eq!(
            groups(Sort::Rating),
            ["beta", "Alpha"],
            "items-only orders keep provider order"
        );
        set_favourite(&c, "movie:0", true).unwrap();
        set_favourite(&c, "movie:3", true).unwrap();
        assert_eq!(
            names(&favourites(&c, &[Kind::Movie], Sort::NameAsc).unwrap()),
            [cb, z]
        );
        assert_eq!(
            names(&favourites(&c, &[Kind::Movie], Sort::Provider).unwrap()),
            [z, cb]
        );
        for (raw, sort) in [
            ("name_desc", Sort::NameDesc),
            ("rating", Sort::Rating),
            ("", Sort::Provider),
            ("bogus", Sort::Provider),
        ] {
            assert_eq!(Sort::parse(raw), sort, "{raw}");
        }
    }

    #[test]
    fn favourites_survive_a_resync_and_list_in_provider_order() {
        let mut c = db();
        set_favourite(&c, "live:102", true).unwrap();
        set_favourite(&c, "live:101", true).unwrap();
        set_favourite(&c, "movie:201", true).unwrap();
        assert_eq!(
            names(&favourites(&c, &[Kind::Live], Sort::Provider).unwrap()),
            ["DE | ARD Sportschau HD", "BR München FHD"]
        );
        assert_eq!(
            favourites(&c, &[Kind::Live], Sort::Provider).unwrap()[0].group,
            "DE | Vollprogramm"
        );
        // The provider drops a channel for one sync: it is not listed, but comes back with it.
        let without = PLAYLIST.replace("#EXTINF:-1 tvg-chno=\"7\" group-title=\"DE | Regional\",BR München FHD\nhttp://h.example.invalid/live/alice/s3cret/102.ts\n", "");
        import_m3u(&mut c, without.as_bytes(), &["alice", "s3cret"]).unwrap();
        assert_eq!(
            favourites(&c, &[Kind::Live], Sort::Provider).unwrap().len(),
            1
        );
        import_m3u(&mut c, PLAYLIST.as_bytes(), &["alice", "s3cret"]).unwrap();
        assert_eq!(
            favourites(&c, &[Kind::Live], Sort::Provider).unwrap().len(),
            2
        );
        set_favourite(&c, "live:101", false).unwrap();
        let mut keys = favourite_keys(&c).unwrap();
        keys.sort();
        assert_eq!(keys, ["live:102", "movie:201"]);
    }

    #[test]
    fn progress_counts_from_two_minutes_until_95_percent() {
        let c = db();
        // (position, duration, kept afterwards)
        for (pos, dur, kept) in [
            (60, 6000, None),         // under 2 min: not started
            (600, 6000, Some(600)),   // started
            (1200, 6000, Some(1200)), // moved on
            (5800, 6000, None),       // 96 %: finished, leaves the row
            (300, 0, Some(300)),      // unknown duration (a stream without one): kept
        ] {
            save_progress(&c, "movie:201", pos, dur).unwrap();
            assert_eq!(
                resume_position(&c, "movie:201").unwrap(),
                kept,
                "{pos}/{dur}"
            );
        }
        assert_eq!(watched_keys(&c).unwrap(), ["movie:201"], "95 % marks it");
        set_watched(&c, "movie:201", false).unwrap();
        assert!(watched_keys(&c).unwrap().is_empty());
        save_progress(&c, "episode:301", 900, 2700).unwrap();
        let row = continue_watching(&c, &[Kind::Movie, Kind::Episode], 10).unwrap();
        assert_eq!(
            names(&row.iter().map(|r| r.0.clone()).collect::<Vec<_>>()),
            ["Planet Wissen S01E02", "Die Reise (2019)"]
        );
        assert_eq!((row[0].1, row[0].2), (900, 2700));
        assert!(continue_watching(&c, &[Kind::Live], 10).unwrap().is_empty());
    }

    /// The next episode stays in its show, and the same episode in another quality is not the next one.
    #[test]
    fn next_episode_follows_the_numbers_of_its_show() {
        let mut c = db();
        let list = "#EXTM3U
#EXTINF:-1 group-title=\"S\",DE | Dark S01E01 HD\nhttp://h.example.invalid/series/a/b/1.mkv
#EXTINF:-1 group-title=\"S\",DE | Dark S01E01 4K\nhttp://h.example.invalid/series/a/b/2.mkv
#EXTINF:-1 group-title=\"S\",Other S01E02\nhttp://h.example.invalid/series/a/b/3.mkv
#EXTINF:-1 group-title=\"S\",DE | Dark S01E02 HD\nhttp://h.example.invalid/series/a/b/4.mkv
#EXTINF:-1 group-title=\"S\",DE | Dark S02E01 HD\nhttp://h.example.invalid/series/a/b/5.mkv
";
        import_m3u(&mut c, list.as_bytes(), &["a", "b"]).unwrap();
        for (from, want) in [
            (1, Some(4)),
            (2, Some(4)),
            (4, Some(5)),
            (5, None), // the last one
            (3, None), // another show's episodes follow it in the group
        ] {
            assert_eq!(
                next_episode(&c, &format!("episode:{from}"))
                    .unwrap()
                    .map(|h| h.key),
                want.map(|n| format!("episode:{n}")),
                "after {from}"
            );
        }
        assert!(next_episode(&c, "movie:201").unwrap().is_none());
    }

    #[test]
    fn hidden_groups_leave_search_favourites_and_their_episodes() {
        let mut c = db();
        // An Xtream Codes-style series in group "Kids" with an episode whose category is the series' key.
        // (Added outside a full sync, like opened episodes: a full sync here would drop the playlist's rows.)
        let series = NewItem {
            key: "series:9".into(),
            name: "Maus Show".into(),
            category: "k".into(),
            ..Default::default()
        };
        Sync::add_items(&mut c, Kind::Series, &[series]).unwrap();
        let ep = NewItem {
            key: "episode:91".into(),
            name: "Maus Show S01E01".into(),
            category: "series:9".into(),
            ..Default::default()
        };
        Sync::add_items(&mut c, Kind::Episode, &[ep]).unwrap();
        set_favourite(&c, "live:102", true).unwrap();
        assert_eq!(search(&c, "maus", &[], None, 10, 0).unwrap().len(), 2);
        for key in ["live:101", "live:102", "movie:201"] {
            touch_recent(&c, key).unwrap();
        }
        let recent = |c: &Connection| -> Vec<String> {
            let hits = recent_channels(c, 10).unwrap();
            hits.into_iter().map(|h| h.key).collect()
        };
        assert_eq!(recent(&c), ["live:102", "live:101"], "channels only");
        set_group_hidden(&c, Kind::Live, "DE | Regional", true).unwrap();
        assert_eq!(recent(&c), ["live:101"]);
        set_group_hidden(&c, Kind::Series, "k", true).unwrap();
        assert!(
            search(&c, "munchen", &[], None, 10, 0).unwrap().is_empty(),
            "the channel is hidden"
        );
        assert!(
            search(&c, "maus", &[], None, 10, 0).unwrap().is_empty(),
            "the series and its episode"
        );
        assert!(search_counts(&c, "maus").unwrap().is_empty());
        assert!(favourites(&c, &[], Sort::Provider).unwrap().is_empty());
        assert!(search_groups(&c, "regional", &[], 5).unwrap().is_empty());
        set_group_hidden(&c, Kind::Live, "DE | Regional", false).unwrap();
        assert_eq!(
            names(&search(&c, "munchen", &[], None, 10, 0).unwrap()),
            ["BR München FHD"]
        );
    }

    #[test]
    fn search_history_keeps_the_newest_per_section() {
        let c = open(Path::new(":memory:")).unwrap();
        for i in 0..25 {
            record_search(&c, "live", &format!("q{i}")).unwrap();
        }
        record_search(&c, "live", " q3 ").unwrap(); // again: moves to the top, trimmed
        record_search(&c, "movies", "film").unwrap();
        record_search(&c, "live", "  ").unwrap(); // blank: ignored
        assert_eq!(
            recent_searches(&c, "live", 3).unwrap(),
            ["q3", "q24", "q23"]
        );
        assert_eq!(recent_searches(&c, "movies", 5).unwrap(), ["film"]);
        let kept: i64 = c
            .query_row(
                "SELECT count(*) FROM search_history WHERE section = 'live'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(kept, 20);
    }

    /// 9 → 10: extra guide sources take over the profile's offset (the provider's stays in the setting), mappings stay.
    #[test]
    fn guide_offsets_move_to_the_sources() {
        let dir = std::env::temp_dir().join(format!("gerdtv-migrate10-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("p.db");
        {
            let c = Connection::open(&path).unwrap();
            c.execute_batch(SCHEMA).unwrap();
            for m in &MIGRATIONS[..8] {
                c.execute_batch(m).unwrap();
            }
            c.execute_batch(
                "INSERT INTO meta VALUES ('schema', '9');
                 INSERT INTO settings VALUES ('guide_offset_hours', '-2', 0);
                 INSERT INTO epg_map VALUES ('live:1', 'x', 0);
                 INSERT INTO epg_sources (url, builtin, updated_at) VALUES ('builtin', 1, 0), ('http://example.invalid/g', 0, 0);",
            )
            .unwrap();
        }
        let c = open(&path).unwrap();
        let offsets: Vec<i64> = c
            .prepare("SELECT offset_hours FROM epg_sources ORDER BY id")
            .unwrap()
            .query_map([], |r| r.get(0))
            .unwrap()
            .collect::<Result<_>>()
            .unwrap();
        assert_eq!(offsets, [0, -2]);
        let kept: (i64, String) = c
            .query_row(
                "SELECT (SELECT count(*) FROM epg_map), (SELECT value FROM settings)",
                [],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .unwrap();
        assert_eq!(kept, (1, "-2".to_string()));
        let backup = std::fs::read_dir(&dir)
            .unwrap()
            .any(|e| e.unwrap().file_name().to_string_lossy().contains(".bak-"));
        assert!(backup);
        std::fs::remove_dir_all(&dir).unwrap();
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
            c.execute("INSERT INTO categories VALUES (0, 'g', 'Kultur', 0)", [])
                .unwrap();
        }
        let c = open(&path).unwrap();
        // Version 6 rebuilt the search indexes from the stored rows: by name, mid-word and by group name.
        for q in ["arte", "rte", "kultur"] {
            assert_eq!(
                names(&search(&c, q, &[], None, 5, 0).unwrap()),
                ["Arte"],
                "{q}"
            );
        }
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
        // Opening again migrates nothing, makes no new backup, and clears the profile's older ones (earlier
        // migrations'), but nothing that isn't exactly one of its backups.
        for other in [
            "p.db.bak-100",
            "p.db.bak-99",
            "q.db.bak-100",
            "p.db.bak-mine",
        ] {
            std::fs::write(dir.join(other), "x").unwrap();
        }
        drop(open(&path).unwrap());
        assert!(!dir.join("p.db.bak-100").exists() && !dir.join("p.db.bak-99").exists());
        assert!(dir.join("q.db.bak-100").exists() && dir.join("p.db.bak-mine").exists());
        std::fs::remove_file(dir.join("q.db.bak-100")).unwrap();
        std::fs::remove_file(dir.join("p.db.bak-mine")).unwrap();
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

    /// A migration that fails halfway leaves the version and tables as they were, so the next start runs it again.
    #[test]
    fn a_failed_migration_changes_nothing() {
        let c = Connection::open_in_memory().unwrap();
        c.execute_batch(SCHEMA).unwrap();
        c.execute("INSERT INTO meta VALUES ('schema', '1')", [])
            .unwrap();
        assert!(
            migrate_step(
                &c,
                1,
                "CREATE TABLE half (a); ALTER TABLE missing ADD COLUMN b;"
            )
            .is_err()
        );
        let (tables, version): (i64, String) = c
            .query_row(
                "SELECT (SELECT count(*) FROM sqlite_master WHERE name = 'half'),
                    (SELECT value FROM meta WHERE key = 'schema')",
                [],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .unwrap();
        assert_eq!((tables, version.as_str()), (0, "1"));
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
            ("|DE| 3sat HD", "3sat"),
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
