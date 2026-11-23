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
    // 5 → 6: search in every section. The word index gains the group name (`cat`, so "dazn" finds the channels of a
    // DAZN group); a trigram index over the names finds mid-word matches ("sport" → "Eurosport"); a vocabulary view
    // of the word index feeds typo matching; the last searches per section (user data). Both indexes are refilled
    // by `reindex` right after this step and completed by the next sync (tvg-names aren't stored in `items`).
    "DROP TABLE items_fts;
     CREATE VIRTUAL TABLE items_fts USING fts5(name, alt, cat, content='', contentless_delete=1,
        tokenize='unicode61 remove_diacritics 2');
     CREATE VIRTUAL TABLE items_tri USING fts5(text, content='', contentless_delete=1,
        tokenize='trigram remove_diacritics 1');
     CREATE VIRTUAL TABLE items_vocab USING fts5vocab(items_fts, 'row');
     CREATE TABLE search_history (section TEXT NOT NULL, query TEXT NOT NULL, updated_at INTEGER NOT NULL,
        PRIMARY KEY (section, query));",
    // 6 → 7: continue watching: where a movie or episode was left (user data, seconds).
    "CREATE TABLE resume (key TEXT PRIMARY KEY, position INTEGER NOT NULL, duration INTEGER NOT NULL,
        updated_at INTEGER NOT NULL);",
    // 7 → 8: groups the user hid (user data): left out of the lists, search, the guide and every row.
    "CREATE TABLE hidden_groups (kind INTEGER NOT NULL, category TEXT NOT NULL, updated_at INTEGER NOT NULL,
        PRIMARY KEY (kind, category));",
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
    let from = current;
    while current < SCHEMA_VERSION {
        conn.execute_batch(MIGRATIONS[(current - 1) as usize])?;
        current += 1;
    }
    if from < 6 {
        reindex(&conn)?; // migration 6 left the search indexes empty
    }
    conn.execute(
        "INSERT INTO meta (key, value) VALUES ('schema', ?1) ON CONFLICT (key) DO UPDATE SET value = ?1",
        [current.to_string()],
    )?;
    Ok(conn)
}

/// Fills both search indexes from the stored catalogue (after migration 6): name, cleaned name, group name. The
/// tvg-names come back with the next sync, which rewrites every row it sees.
fn reindex(conn: &Connection) -> Result<()> {
    let mut st = conn.prepare(
        "SELECT i.rowid, i.name, coalesce(c.name, '') FROM items i
         LEFT JOIN categories c ON c.kind = i.kind AND c.id = i.category",
    )?;
    let rows = st.query_map([], |r| {
        Ok((
            r.get::<_, i64>(0)?,
            r.get::<_, String>(1)?,
            r.get::<_, String>(2)?,
        ))
    })?;
    for row in rows {
        let (rowid, name, cat) = row?;
        index_item(conn, rowid, true, &name, &clean_name(&name), &cat)?;
    }
    Ok(())
}

/// Writes one item into both search indexes, replacing what was there unless the row is `fresh` (just inserted:
/// nothing to delete, and the two deletes were a fifth of a 150k import). The trigram index holds only the cleaned
/// names (`alt`): mid-word matches need no country prefixes or quality tags, and the raw name doubled its size
/// (import budget: 150k entries in < 5 s).
fn index_item(
    conn: &Connection,
    rowid: i64,
    fresh: bool,
    name: &str,
    alt: &str,
    cat: &str,
) -> Result<()> {
    if !fresh {
        conn.prepare_cached("DELETE FROM items_fts WHERE rowid = ?1")?
            .execute([rowid])?;
        conn.prepare_cached("DELETE FROM items_tri WHERE rowid = ?1")?
            .execute([rowid])?;
    }
    conn.prepare_cached("INSERT INTO items_fts (rowid, name, alt, cat) VALUES (?1, ?2, ?3, ?4)")?
        .execute(params![rowid, name, alt, cat])?;
    conn.prepare_cached("INSERT INTO items_tri (rowid, text) VALUES (?1, ?2)")?
        .execute(params![rowid, alt])?;
    Ok(())
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
    /// (kind, category id) → group name, for the search index's `cat` column. Sources send the categories before
    /// their items (Xtream Codes: the category lists first; M3U: each entry's group just before the entry).
    group_names: std::collections::HashMap<(Kind, String), String>,
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
            group_names: Default::default(),
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
            self.group_names
                .insert((kind, id.to_string()), name.to_string());
        }
    }

    pub fn item(&mut self, kind: Kind, it: &NewItem) -> Result<()> {
        // An upsert that inserts moves last_insert_rowid to the new row; one that updates leaves it alone.
        let before = self.tx.last_insert_rowid();
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
        let alt = format!("{} {}", clean_name(&it.name), clean_name(&it.alt));
        let cat = self
            .group_names
            .get(&(kind, it.category.clone()))
            .map_or("", String::as_str);
        let fresh = self.tx.last_insert_rowid() != before && self.tx.last_insert_rowid() == rowid;
        index_item(&self.tx, rowid, fresh, &it.name, &alt, cat)?;
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
        for index in ["items_fts", "items_tri"] {
            self.tx.execute(
                &format!(
                    "DELETE FROM {index} WHERE rowid IN (SELECT rowid FROM items WHERE seen < ?1)"
                ),
                [g],
            )?;
        }
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
    /// The group's name. Search fills it, so results can show where they live; other lists leave it empty.
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

/// A query's candidates as SQL: `cte` defines `cand(rowid)` (deduplicated), `tier` ranks a row of it (in terms of
/// `i.rowid`), `params` are bound from ?2 on (?1 is the channel number).
struct Candidates {
    cte: String,
    tier: String,
    params: Vec<String>,
    number: Option<i64>,
}

/// Builds the candidates of a query. Tiers, best first: 0 the channel with that number, 1 every word a whole word of
/// the name, 2 every word starts a word of the name, 3 the words found in name and group together (a channel of the
/// "DE | DAZN" group), 4 mid-word in the name (trigram, words of 3+ letters; shorter words must still start a word),
/// 5 with typos.
/// Speed (budget: search < 50 ms p95 on 150k entries): the candidate set is one UNION of the widest arms, and the tier
/// is an `IN` probe per narrower arm (SQLite builds each set once). The group arm needs a word of 3+ letters: for
/// "s" it would only add every channel of every group with an s-word, and its probe set doubled the time.
fn candidates(conn: &Connection, input: &str) -> Result<Option<Candidates>> {
    let w = words(input);
    if w.is_empty() {
        return Ok(None);
    }
    let mut params: Vec<String> = Vec::new();
    let mut bind = |v: String| {
        params.push(v);
        format!("?{}", params.len() + 1)
    };
    let join = |f: &dyn Fn(&String) -> String, ws: &[&String]| {
        ws.iter().map(|w| f(w)).collect::<Vec<_>>().join(" ")
    };
    let all_w: Vec<&String> = w.iter().collect();
    let long: Vec<&String> = w.iter().filter(|w| w.chars().count() >= 3).collect();
    let short: Vec<&String> = w.iter().filter(|w| w.chars().count() < 3).collect();
    let fts = |m: String| format!("SELECT rowid FROM items_fts WHERE items_fts MATCH {m}");
    // (tier, the arm's rowid set); each arm's set contains the ones before it, except trigram and typos.
    let mut arms: Vec<(u8, String)> = vec![
        (
            1,
            fts(bind(format!(
                "{{name alt}} : ({})",
                join(&|w| format!("\"{w}\""), &all_w)
            ))),
        ),
        (
            2,
            fts(bind(format!(
                "{{name alt}} : ({})",
                join(&|w| format!("\"{w}\"*"), &all_w)
            ))),
        ),
    ];
    if !long.is_empty() {
        arms.push((3, fts(bind(join(&|w| format!("\"{w}\"*"), &all_w)))));
        let mut tri = format!(
            "SELECT rowid FROM items_tri WHERE items_tri MATCH {}",
            bind(join(&|w| format!("\"{w}\""), &long))
        );
        if !short.is_empty() {
            // INTERSECT, not `rowid IN`: FTS5 answers a rowid constraint with one lookup per row (seen: 1 s).
            tri += &format!(
                " INTERSECT {}",
                fts(bind(format!(
                    "{{name alt}} : ({})",
                    join(&|w| format!("\"{w}\"*"), &short)
                )))
            );
        }
        arms.push((4, tri));
    }
    let mut any_typo = false;
    let mut typo = Vec::new();
    for word in &w {
        let terms = typo_terms(conn, word)?;
        any_typo |= !terms.is_empty();
        // A single word needs only its typo terms (its prefix matches are in tier 2 already).
        let own = (w.len() > 1).then(|| format!("\"{word}\"*"));
        let alts: Vec<String> = own
            .into_iter()
            .chain(terms.iter().map(|t| format!("\"{t}\"")))
            .collect();
        if !alts.is_empty() {
            typo.push(format!("({})", alts.join(" OR ")));
        }
    }
    if any_typo && typo.len() == w.len() {
        arms.push((
            5,
            fts(bind(format!("{{name alt}} : ({})", typo.join(" AND ")))),
        ));
    }
    // The union: the widest of tiers 1–3 (the last of them present), then trigram and typos.
    let widest = arms.iter().filter(|(t, _)| *t <= 3).count() - 1;
    let union: Vec<&str> = arms[widest..].iter().map(|(_, a)| a.as_str()).collect();
    let cte = format!(
        "cand AS (SELECT rowid FROM items WHERE kind = 0 AND number = ?1 UNION {})",
        union.join(" UNION ")
    );
    let (last, probes) = arms.split_last().unwrap();
    let tier = format!(
        "CASE WHEN ?1 IS NOT NULL AND i.kind = 0 AND i.number = ?1 THEN 0 {} ELSE {} END",
        probes
            .iter()
            .map(|(t, a)| format!("WHEN i.rowid IN ({a}) THEN {t}"))
            .collect::<Vec<_>>()
            .join(" "),
        last.0
    );
    let number: Option<i64> = input.trim().parse().ok();
    Ok(Some(Candidates {
        cte,
        tier,
        params,
        number,
    }))
}

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

/// Searches the catalogue. Ranking: favourites, then recently watched, then the match tiers (`candidates`), then
/// names starting with the query, then provider order. `kinds` narrows to a section (empty = all), `category` to
/// one group of it. A number alone also finds that channel number.
pub fn search(
    conn: &Connection,
    input: &str,
    kinds: &[Kind],
    category: Option<&str>,
    limit: usize,
    offset: usize,
) -> Result<Vec<Hit>> {
    let Some(c) = candidates(conn, input)? else {
        return Ok(vec![]);
    };
    let n = c.params.len();
    let sql = format!(
        "WITH {cte}
         SELECT i.key, i.kind, i.name, i.category, i.logo, i.number, i.archive_days, coalesce(c.name, ''),
                {tier} AS tier
         FROM cand JOIN items i ON i.rowid = cand.rowid
         LEFT JOIN favourites f ON f.key = i.key
         LEFT JOIN recents r ON r.key = i.key
         LEFT JOIN categories c ON c.kind = i.kind AND c.id = i.category
         WHERE (?{m} >> i.kind) & 1 AND (?{g} IS NULL OR i.category = ?{g}) {visible}
         ORDER BY f.key IS NULL, r.updated_at IS NULL, r.updated_at DESC, tier, i.name NOT LIKE ?{p}, i.position
         LIMIT ?{l} OFFSET ?{o}",
        cte = c.cte,
        tier = c.tier,
        visible = visible_and(conn, "i")?,
        m = n + 2,
        g = n + 3,
        p = n + 4,
        l = n + 5,
        o = n + 6,
    );
    let mut st = conn.prepare_cached(&sql)?;
    let mut values: Vec<Box<dyn rusqlite::ToSql>> = vec![Box::new(c.number)];
    values.extend(
        c.params
            .into_iter()
            .map(|w| Box::new(w) as Box<dyn rusqlite::ToSql>),
    );
    values.push(Box::new(kind_mask(kinds)));
    values.push(Box::new(category.map(str::to_string)));
    values.push(Box::new(format!("{}%", input.trim())));
    values.push(Box::new(limit as i64));
    values.push(Box::new(offset as i64));
    let rows = st.query_map(rusqlite::params_from_iter(values), |r| {
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

/// Result counts per kind over the whole catalogue: the "All groups" chip and the "Also in" hint line.
pub fn search_counts(conn: &Connection, input: &str) -> Result<Vec<(Kind, usize)>> {
    let Some(c) = candidates(conn, input)? else {
        return Ok(vec![]);
    };
    let sql = format!(
        "WITH {} SELECT i.kind, count(*) FROM cand JOIN items i ON i.rowid = cand.rowid WHERE 1 {}
         GROUP BY i.kind ORDER BY i.kind",
        c.cte,
        visible_and(conn, "i")?
    );
    let mut st = conn.prepare_cached(&sql)?;
    // The tier probes aren't part of the CTE, but their parameters are numbered with it: bind them all.
    let mut values: Vec<Box<dyn rusqlite::ToSql>> = vec![Box::new(c.number)];
    values.extend(
        c.params
            .into_iter()
            .map(|w| Box::new(w) as Box<dyn rusqlite::ToSql>),
    );
    let rows = st.query_map(rusqlite::params_from_iter(values), |r| {
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

/// The favourites of `kinds` (empty = all) in provider order (channel numbers stay in order, zapping follows the
/// list), with their group's name; ones the catalogue doesn't have right now are left out.
pub fn favourites(conn: &Connection, kinds: &[Kind]) -> Result<Vec<Hit>> {
    let mut st = conn.prepare_cached(&format!(
        "SELECT i.key, i.kind, i.name, i.category, i.logo, i.number, i.archive_days, coalesce(c.name, '')
         FROM favourites f JOIN items i ON i.key = f.key
         LEFT JOIN categories c ON c.kind = i.kind AND c.id = i.category
         WHERE (?1 >> i.kind) & 1 {} ORDER BY i.kind, i.position",
        visible_and(conn, "i")?
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
/// 95 % it counts as finished and leaves continue watching.
pub fn save_progress(conn: &Connection, key: &str, position: u32, duration: u32) -> Result<()> {
    if duration > 0 && position as f64 >= duration as f64 * FINISHED_AT {
        conn.execute("DELETE FROM resume WHERE key = ?1", [key])?;
    } else if position >= RESUME_FROM_SECS {
        conn.execute(
            "INSERT INTO resume (key, position, duration, updated_at) VALUES (?1, ?2, ?3, ?4)
             ON CONFLICT (key) DO UPDATE SET position = ?2, duration = ?3, updated_at = ?4",
            params![key, position, duration, unix_now()],
        )?;
    }
    Ok(())
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
        assert_eq!(
            in_group[0].group, "DE | DAZN",
            "hits carry their group's name"
        );
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
    fn ranking_favourites_then_recents_then_match_tiers() {
        let mut c = open(Path::new(":memory:")).unwrap();
        let pl = "#EXTINF:-1,Kino Welt\nhttp://h/live/u/p/1.ts\n#EXTINF:-1,Das Kino\nhttp://h/live/u/p/2.ts\n#EXTINF:-1,Kino Plus\nhttp://h/live/u/p/3.ts\n#EXTINF:-1,Mein Kino\nhttp://h/live/u/p/4.ts\n\
            #EXTINF:-1,Kimo TV\nhttp://h/live/u/p/5.ts\n#EXTINF:-1,Superkino\nhttp://h/live/u/p/6.ts\n\
            #EXTINF:-1 group-title=\"Kino Sender\",Film Eins\nhttp://h/live/u/p/7.ts\n#EXTINF:-1,Kinowelt Extra\nhttp://h/live/u/p/8.ts\n";
        import_m3u(&mut c, pl.as_bytes(), &[]).unwrap();
        // Whole word (name starts first), word start, via the group, mid-word, typo.
        let tiers = ["Kinowelt Extra", "Film Eins", "Superkino", "Kimo TV"];
        assert_eq!(
            names(&search(&c, "kino", &[], None, 10, 0).unwrap()),
            [
                &["Kino Welt", "Kino Plus", "Das Kino", "Mein Kino"][..],
                &tiers
            ]
            .concat()
        );
        c.execute("INSERT INTO favourites VALUES ('live:4', 1)", [])
            .unwrap();
        c.execute("INSERT INTO recents VALUES ('live:2', 5)", [])
            .unwrap();
        assert_eq!(
            names(&search(&c, "kino", &[], None, 10, 0).unwrap()),
            [
                &["Mein Kino", "Das Kino", "Kino Welt", "Kino Plus"][..],
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
    fn favourites_survive_a_resync_and_list_in_provider_order() {
        let mut c = db();
        set_favourite(&c, "live:102", true).unwrap();
        set_favourite(&c, "live:101", true).unwrap();
        set_favourite(&c, "movie:201", true).unwrap();
        assert_eq!(
            names(&favourites(&c, &[Kind::Live]).unwrap()),
            ["DE | ARD Sportschau HD", "BR München FHD"]
        );
        assert_eq!(
            favourites(&c, &[Kind::Live]).unwrap()[0].group,
            "DE | Vollprogramm"
        );
        // The provider drops a channel for one sync: it is not listed, but comes back with it.
        let without = PLAYLIST.replace("#EXTINF:-1 tvg-chno=\"7\" group-title=\"DE | Regional\",BR München FHD\nhttp://h.example.invalid/live/alice/s3cret/102.ts\n", "");
        import_m3u(&mut c, without.as_bytes(), &["alice", "s3cret"]).unwrap();
        assert_eq!(favourites(&c, &[Kind::Live]).unwrap().len(), 1);
        import_m3u(&mut c, PLAYLIST.as_bytes(), &["alice", "s3cret"]).unwrap();
        assert_eq!(favourites(&c, &[Kind::Live]).unwrap().len(), 2);
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
        save_progress(&c, "episode:301", 900, 2700).unwrap();
        let row = continue_watching(&c, &[Kind::Movie, Kind::Episode], 10).unwrap();
        assert_eq!(
            names(&row.iter().map(|r| r.0.clone()).collect::<Vec<_>>()),
            ["Planet Wissen S01E02", "Die Reise (2019)"]
        );
        assert_eq!((row[0].1, row[0].2), (900, 2700));
        assert!(continue_watching(&c, &[Kind::Live], 10).unwrap().is_empty());
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
        set_group_hidden(&c, Kind::Live, "DE | Regional", true).unwrap();
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
        assert!(favourites(&c, &[]).unwrap().is_empty());
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
