//! Profiles and the per-profile library the app talks to (through gerdtv-api).
//!
//! - A profile's non-secret settings live in `<app-support>/profiles.json`; its catalogue in
//!   `<app-support>/profiles/<id>.db`. Secrets (Xtream Codes username/password, an M3U URL with credentials) never
//!   touch disk here: the app keeps them in the platform's secure storage and hands them to `Library::open`.
//! - `Library::sync` downloads without holding the database (the UI keeps browsing the cache), then writes in one
//!   short transaction. Opening a library is instant: it reads the cached catalogue (cache-first start).
//!
//! Debug hints: a profile that "has no channels" after a sync: check `last_sync` in the returned stats and the
//! log for "list came back empty"; a profile missing from the list: profiles.json is rewritten atomically
//! (write to .tmp, rename), so a crash mid-save leaves the previous file.

use crate::db::{self, Hit, ImportStats, Kind};
use crate::epg;
use crate::xtream::{self, Account, XcError, Xtream};
use rusqlite::{Connection, OptionalExtension, params};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SourceKind {
    /// Xtream Codes: `server` is the panel URL; the secrets are [username, password].
    Xtream,
    /// M3U by URL: the secrets are [playlist URL] (it usually carries the credentials).
    M3uUrl,
    /// M3U from a local file: `server` is the file path; no secrets.
    M3uFile,
}

/// A profile's non-secret settings (one provider).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Profile {
    pub id: String,
    pub name: String,
    pub source: SourceKind,
    #[serde(default)]
    pub server: String,
    #[serde(default)]
    pub user_agent: String,
    /// M3U only: the provider's connection limit (Xtream Codes reports it itself).
    #[serde(default)]
    pub max_connections: Option<u32>,
    #[serde(default)]
    pub updated_at: i64,
}

#[derive(Debug, thiserror::Error)]
pub enum LibraryError {
    #[error(transparent)]
    Xtream(#[from] XcError),
    #[error("database error: {0}")]
    Db(#[from] rusqlite::Error),
    #[error("file error: {0}")]
    Io(#[from] std::io::Error),
    #[error("no profile {0}")]
    NoProfile(String),
    #[error("this profile needs {0} secret(s)")]
    Secrets(usize),
}

pub type Result<T> = std::result::Result<T, LibraryError>;

fn now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

// ---- profile store ----

pub fn load_profiles(dir: &Path) -> Result<Vec<Profile>> {
    match std::fs::read(dir.join("profiles.json")) {
        Ok(bytes) => Ok(serde_json::from_slice(&bytes).map_err(std::io::Error::other)?),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(vec![]),
        Err(e) => Err(e.into()),
    }
}

fn store_profiles(dir: &Path, profiles: &[Profile]) -> Result<()> {
    std::fs::create_dir_all(dir)?;
    let tmp = dir.join("profiles.json.tmp");
    std::fs::write(
        &tmp,
        serde_json::to_vec_pretty(profiles).map_err(std::io::Error::other)?,
    )?;
    std::fs::rename(tmp, dir.join("profiles.json"))?; // atomic on the same filesystem
    Ok(())
}

// ---- app settings ----
// App-wide (not per-profile) settings, e.g. `app_logo`: a flat string map in `<app-support>/app.json`, rewritten
// atomically like profiles.json. They exist before any profile does (the logo shows on the setup screen).

fn load_app_settings(dir: &Path) -> Result<std::collections::BTreeMap<String, String>> {
    match std::fs::read(dir.join("app.json")) {
        Ok(bytes) => Ok(serde_json::from_slice(&bytes).map_err(std::io::Error::other)?),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Default::default()),
        Err(e) => Err(e.into()),
    }
}

/// An app-wide setting, or None when never set.
pub fn app_setting(dir: &Path, key: &str) -> Result<Option<String>> {
    Ok(load_app_settings(dir)?.remove(key))
}

pub fn set_app_setting(dir: &Path, key: &str, value: &str) -> Result<()> {
    let mut all = load_app_settings(dir)?;
    all.insert(key.to_string(), value.to_string());
    std::fs::create_dir_all(dir)?;
    let tmp = dir.join("app.json.tmp");
    std::fs::write(
        &tmp,
        serde_json::to_vec_pretty(&all).map_err(std::io::Error::other)?,
    )?;
    std::fs::rename(tmp, dir.join("app.json"))?; // atomic on the same filesystem
    Ok(())
}

/// Adds or replaces a profile (by id); an empty id gets a new one. Returns the stored profile.
pub fn save_profile(dir: &Path, mut p: Profile) -> Result<Profile> {
    let mut all = load_profiles(dir)?;
    if p.id.is_empty() {
        p.id = format!(
            "p{:x}",
            db::fnv1a(&format!("{}{}{}", p.name, p.server, now())) & 0xffff_ffff
        );
    }
    p.updated_at = now();
    match all.iter_mut().find(|x| x.id == p.id) {
        Some(x) => *x = p.clone(),
        None => all.push(p.clone()),
    }
    store_profiles(dir, &all)?;
    Ok(p)
}

/// Removes a profile and its database (inside the app's own folder; the app confirms first).
pub fn delete_profile(dir: &Path, id: &str) -> Result<()> {
    let mut all = load_profiles(dir)?;
    all.retain(|p| p.id != id);
    store_profiles(dir, &all)?;
    for suffix in ["", "-wal", "-shm"] {
        let _ = std::fs::remove_file(db_path(dir, id).with_extension(format!("db{suffix}")));
    }
    Ok(())
}

fn db_path(dir: &Path, id: &str) -> PathBuf {
    dir.join("profiles").join(format!("{id}.db"))
}

// ---- the library ----

#[derive(Debug, Clone, PartialEq)]
pub struct Category {
    pub id: String,
    pub name: String,
    pub count: usize,
}

#[derive(Debug, Clone, Default)]
pub struct SyncResult {
    pub stats: ImportStats,
    /// Xtream Codes only.
    pub account: Option<Account>,
}

/// One page of hits plus per-kind totals and matching groups (both only on the first page).
pub type SearchResult = (Vec<Hit>, Vec<(Kind, usize)>, Vec<db::GroupHit>);

/// Groups shown above a section's search results: enough for "DE | DAZN", "UK | DAZN" …, few enough not to push the
/// channels out of view.
pub const GROUP_HITS: usize = 5;

/// One open profile: its database and, for Xtream Codes, its client.
pub struct Library {
    profile: Profile,
    conn: Mutex<Connection>,
    secrets: Vec<String>,
    xc: Option<Xtream>,
}

impl Library {
    pub fn open(dir: &Path, profile_id: &str, secrets: Vec<String>) -> Result<Library> {
        let profile = load_profiles(dir)?
            .into_iter()
            .find(|p| p.id == profile_id)
            .ok_or_else(|| LibraryError::NoProfile(profile_id.to_string()))?;
        let need = match profile.source {
            SourceKind::Xtream => 2,
            SourceKind::M3uUrl => 1,
            SourceKind::M3uFile => 0,
        };
        if secrets.len() < need {
            return Err(LibraryError::Secrets(need));
        }
        let path = db_path(dir, profile_id);
        std::fs::create_dir_all(path.parent().unwrap())?;
        let conn = db::open(&path)?;
        let ua = Some(profile.user_agent.as_str());
        let xc = (profile.source == SourceKind::Xtream)
            .then(|| Xtream::new(&profile.server, &secrets[0], &secrets[1], ua));
        Ok(Library {
            profile,
            conn: Mutex::new(conn),
            secrets,
            xc,
        })
    }

    pub fn profile(&self) -> &Profile {
        &self.profile
    }

    fn secret_refs(&self) -> Vec<&str> {
        // For M3U-by-URL, template the URL's own credentials: the username/password query values.
        let mut v: Vec<&str> = self.secrets.iter().map(String::as_str).collect();
        if self.profile.source == SourceKind::M3uUrl {
            for (k, val) in self.secrets[0]
                .split('?')
                .nth(1)
                .unwrap_or("")
                .split('&')
                .filter_map(|kv| kv.split_once('='))
            {
                if k == "username" || k == "password" {
                    v.push(val);
                }
            }
            v.remove(0); // the whole URL itself never appears inside stream URLs
        }
        v
    }

    /// Downloads `url` to a temp file (streamed), so a big playlist or guide never sits in memory and the current data
    /// stays usable until the download is complete. The caller removes the file.
    async fn download(&self, url: &str, name: &str) -> Result<PathBuf> {
        xtream::ensure_tls_provider();
        let net = |e: reqwest::Error| XcError::Network(e.without_url().to_string());
        let ua = if self.profile.user_agent.is_empty() {
            "gerdTV"
        } else {
            &self.profile.user_agent
        };
        let client = reqwest::Client::builder()
            .user_agent(ua)
            .build()
            .map_err(net)?;
        let mut res = client.get(url).send().await.map_err(net)?;
        if !res.status().is_success() {
            return Err(XcError::Http(res.status().as_u16()).into());
        }
        let tmp = std::env::temp_dir()
            .join("gerdtv")
            .join(format!("{}-{name}", self.profile.id));
        std::fs::create_dir_all(tmp.parent().unwrap())?;
        use std::io::Write;
        let mut f = std::io::BufWriter::new(std::fs::File::create(&tmp)?);
        while let Some(chunk) = res.chunk().await.map_err(net)? {
            f.write_all(&chunk)?;
        }
        f.flush()?;
        Ok(tmp)
    }

    /// Downloads and writes the catalogue (the database is only locked for the final write), then re-matches the
    /// channels to the guide, since items may have changed.
    pub async fn sync(&self) -> Result<SyncResult> {
        let r = self.sync_catalogue().await?;
        epg::rebuild_matches(&mut self.conn.lock().unwrap())?;
        Ok(r)
    }

    async fn sync_catalogue(&self) -> Result<SyncResult> {
        match self.profile.source {
            SourceKind::Xtream => {
                let f = xtream::fetch(self.xc.as_ref().unwrap()).await?;
                let stats = xtream::write(&mut self.conn.lock().unwrap(), &f)?;
                // Catch-up URLs name the start in the server's local time.
                self.set_setting(SETTING_XC_OFFSET, &f.account.time_offset.to_string())?;
                Ok(SyncResult {
                    stats,
                    account: Some(f.account),
                })
            }
            SourceKind::M3uUrl => {
                // Download first (the old catalogue stays usable meanwhile), then parse.
                let tmp = self
                    .download(&self.secrets[0].clone(), "playlist.m3u")
                    .await?;
                let r = std::io::BufReader::new(std::fs::File::open(&tmp)?);
                let stats = db::import_m3u(&mut self.conn.lock().unwrap(), r, &self.secret_refs());
                let _ = std::fs::remove_file(&tmp);
                let stats = stats?;
                // Remember the playlist's own guide URL (credentials templated out) for the guide refresh.
                if let Some(u) = &stats.tvg_url {
                    self.set_setting(
                        SETTING_M3U_TVG,
                        &db::template_secrets(u, &self.secret_refs()),
                    )?;
                }
                Ok(SyncResult {
                    stats,
                    account: None,
                })
            }
            SourceKind::M3uFile => {
                let r = std::io::BufReader::new(std::fs::File::open(&self.profile.server)?);
                Ok(SyncResult {
                    stats: db::import_m3u(&mut self.conn.lock().unwrap(), r, &[])?,
                    account: None,
                })
            }
        }
    }

    /// Categories of a kind in provider order, with their item counts (empty ones and the ones the user hid left out).
    pub fn categories(&self, kind: Kind) -> Result<Vec<Category>> {
        Ok(self
            .all_categories(kind)?
            .into_iter()
            .filter(|(_, hidden)| !hidden)
            .map(|(c, _)| c)
            .collect())
    }

    /// Every non-empty category of a kind with whether the user hid it (Settings → Hidden groups).
    pub fn all_categories(&self, kind: Kind) -> Result<Vec<(Category, bool)>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare_cached(
            "SELECT c.id, c.name, count(i.key),
                    EXISTS (SELECT 1 FROM hidden_groups h WHERE h.kind = c.kind AND h.category = c.id)
             FROM categories c
             JOIN items i ON i.kind = c.kind AND i.category = c.id
             WHERE c.kind = ?1 GROUP BY c.id ORDER BY c.position",
        )?;
        let rows = stmt.query_map([kind as i64], |r| {
            Ok((
                Category {
                    id: r.get(0)?,
                    name: r.get(1)?,
                    count: r.get::<_, i64>(2)? as usize,
                },
                r.get(3)?,
            ))
        })?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    pub fn set_group_hidden(&self, kind: Kind, category: &str, hidden: bool) -> Result<()> {
        Ok(db::set_group_hidden(
            &self.conn.lock().unwrap(),
            kind,
            category,
            hidden,
        )?)
    }

    /// One item by its key (a reminder names its channel by key); None when it is gone from the catalogue.
    pub fn item(&self, key: &str) -> Result<Option<Hit>> {
        Ok(self
            .conn
            .lock()
            .unwrap()
            .query_row(
                "SELECT key, kind, name, category, logo, number, archive_days FROM items WHERE key = ?1",
                [key],
                |r| {
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
                },
            )
            .optional()?)
    }

    /// One page of a category's items in provider order.
    pub fn items(
        &self,
        kind: Kind,
        category: &str,
        limit: usize,
        offset: usize,
    ) -> Result<Vec<Hit>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare_cached(
            "SELECT key, kind, name, category, logo, number, archive_days FROM items
             WHERE kind = ?1 AND category = ?2 ORDER BY position LIMIT ?3 OFFSET ?4",
        )?;
        let rows = stmt.query_map(
            params![kind as i64, category, limit as i64, offset as i64],
            |r| {
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
            },
        )?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    /// One page of a section's search (`kinds`), or of one group's (`category`). The first page also carries the
    /// per-kind totals and, for a whole section, the matching groups (at most [`GROUP_HITS`]).
    pub fn search(
        &self,
        query: &str,
        kinds: &[Kind],
        category: Option<&str>,
        limit: usize,
        offset: usize,
    ) -> Result<SearchResult> {
        let conn = self.conn.lock().unwrap();
        let hits = db::search(&conn, query, kinds, category, limit, offset)?;
        if offset > 0 {
            return Ok((hits, vec![], vec![]));
        }
        let counts = db::search_counts(&conn, query)?;
        let groups = if category.is_none() {
            db::search_groups(&conn, query, kinds, GROUP_HITS)?
        } else {
            vec![]
        };
        Ok((hits, counts, groups))
    }

    /// Remembers a search the user opened a result of (the field's recent searches).
    pub fn record_search(&self, section: &str, query: &str) -> Result<()> {
        Ok(db::record_search(
            &self.conn.lock().unwrap(),
            section,
            query,
        )?)
    }

    pub fn set_favourite(&self, key: &str, on: bool) -> Result<()> {
        Ok(db::set_favourite(&self.conn.lock().unwrap(), key, on)?)
    }

    pub fn favourites(&self, kinds: &[Kind]) -> Result<Vec<Hit>> {
        Ok(db::favourites(&self.conn.lock().unwrap(), kinds)?)
    }

    pub fn save_progress(&self, key: &str, position: u32, duration: u32) -> Result<()> {
        Ok(db::save_progress(
            &self.conn.lock().unwrap(),
            key,
            position,
            duration,
        )?)
    }

    pub fn resume_position(&self, key: &str) -> Result<Option<u32>> {
        Ok(db::resume_position(&self.conn.lock().unwrap(), key)?)
    }

    pub fn continue_watching(&self, kinds: &[Kind], limit: usize) -> Result<Vec<(Hit, u32, u32)>> {
        Ok(db::continue_watching(
            &self.conn.lock().unwrap(),
            kinds,
            limit,
        )?)
    }

    pub fn touch_recent(&self, key: &str) -> Result<()> {
        Ok(db::touch_recent(&self.conn.lock().unwrap(), key)?)
    }

    pub fn favourite_keys(&self) -> Result<Vec<String>> {
        Ok(db::favourite_keys(&self.conn.lock().unwrap())?)
    }

    pub fn recent_searches(&self, section: &str, limit: usize) -> Result<Vec<String>> {
        Ok(db::recent_searches(
            &self.conn.lock().unwrap(),
            section,
            limit,
        )?)
    }

    /// A series' episodes in season/episode order. Xtream Codes fetches them now (and caches them until the next
    /// sync); for M3U the episodes are already in the catalogue under their group.
    pub async fn episodes(&self, series_key: &str) -> Result<Vec<Hit>> {
        if let (Some(xc), Some(id)) = (
            &self.xc,
            series_key
                .strip_prefix("series:")
                .and_then(|i| i.parse().ok()),
        ) {
            let items = xc.episodes(id).await?;
            db::Sync::add_items(&mut self.conn.lock().unwrap(), Kind::Episode, &items)?;
        }
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare_cached(
            "SELECT key, kind, name, category, logo, number, archive_days FROM items
             WHERE kind = 2 AND category = ?1 ORDER BY season, episode, position",
        )?;
        let rows = stmt.query_map([series_key], |r| {
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
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    /// The URL to play an item (live: `.ts` by default, `m3u8` when the watchdog asks; VOD: its container).
    /// The catch-up URL for a programme of a live channel (from `start` to `stop`, UTC seconds), or None: no
    /// archive on this channel, the programme lies beyond its reach or hasn't started, or the provider isn't Xtream
    /// Codes (M3U catch-up templates are not supported yet). Holds credentials: straight to the player, never logged.
    pub fn catchup_url(&self, key: &str, start: i64, stop: i64) -> Result<Option<String>> {
        let Some(xc) = &self.xc else { return Ok(None) };
        let Some(id) = key
            .strip_prefix("live:")
            .and_then(|i| i.parse::<u64>().ok())
        else {
            return Ok(None);
        };
        let days: u32 = self
            .conn
            .lock()
            .unwrap()
            .query_row(
                "SELECT archive_days FROM items WHERE key = ?1",
                [key],
                |r| r.get(0),
            )
            .optional()?
            .unwrap_or(0);
        let t = now();
        if days == 0 || start >= t || start < t - days as i64 * 86_400 {
            return Ok(None);
        }
        let offset = self
            .setting(SETTING_XC_OFFSET)?
            .and_then(|v| v.parse().ok())
            .unwrap_or(0);
        // Whole minutes, at least one; a programme still running is asked for up to now.
        let minutes = ((stop.min(t) - start + 59) / 60).max(1) as u32;
        Ok(Some(xc.catchup_url(id, start, minutes, offset)))
    }

    /// Reminders still to come (with the channel), soonest first; past ones are dropped on the way.
    pub fn reminders(&self) -> Result<Vec<Reminder>> {
        let conn = self.conn.lock().unwrap();
        conn.execute("DELETE FROM reminders WHERE start < ?1", [now() - 3600])?;
        let mut st = conn.prepare_cached(
            "SELECT item_key, start, stop, title FROM reminders WHERE start >= ?1 ORDER BY start",
        )?;
        let rows = st.query_map([now() - 3600], |r| {
            Ok(Reminder {
                item_key: r.get(0)?,
                start: r.get(1)?,
                stop: r.get(2)?,
                title: r.get(3)?,
            })
        })?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    /// Sets (or with `on` false, clears) a reminder for a programme of a live channel.
    pub fn set_reminder(&self, r: &Reminder, on: bool) -> Result<()> {
        let conn = self.conn.lock().unwrap();
        if on {
            conn.execute(
                "INSERT INTO reminders (item_key, start, stop, title, updated_at) VALUES (?1, ?2, ?3, ?4, ?5)
                 ON CONFLICT (item_key, start) DO UPDATE SET stop = ?3, title = ?4, updated_at = ?5",
                params![r.item_key, r.start, r.stop, r.title, now()],
            )?;
        } else {
            conn.execute(
                "DELETE FROM reminders WHERE item_key = ?1 AND start = ?2",
                params![r.item_key, r.start],
            )?;
        }
        Ok(())
    }

    pub fn stream_url(&self, key: &str, live_ext: &str) -> Result<String> {
        if let Some(xc) = &self.xc {
            let (prefix, id) = key.split_once(':').unwrap_or(("", ""));
            let id: u64 = id
                .parse()
                .map_err(|_| LibraryError::NoProfile(key.to_string()))?;
            if prefix == "live" {
                return Ok(xc.stream_url(Kind::Live, id, live_ext));
            }
            // Movies and episodes use their own container (mp4, mkv …); fall back to the panel's usual default.
            let ext: String = self
                .conn
                .lock()
                .unwrap()
                .query_row("SELECT ext FROM items WHERE key = ?1", [key], |r| r.get(0))
                .optional()?
                .filter(|e: &String| !e.is_empty())
                .unwrap_or_else(|| {
                    if prefix == "movie" {
                        "mkv".into()
                    } else {
                        "mp4".into()
                    }
                });
            let kind = if prefix == "movie" {
                Kind::Movie
            } else {
                Kind::Episode
            };
            return Ok(xc.stream_url(kind, id, &ext));
        }
        let conn = self.conn.lock().unwrap();
        let url: String =
            conn.query_row("SELECT url FROM items WHERE key = ?1", [key], |r| r.get(0))?;
        Ok(db::fill_secrets(&url, &self.secret_refs()))
    }
}

/// Profile settings keys (values are strings).
pub const SETTING_BUFFER: &str = "buffer_preset";
pub const SETTING_ADAPTIVE: &str = "adaptive_buffer";
pub const SETTING_TIMESHIFT: &str = "timeshift_secs";
/// Hours added to every guide time of this profile (some providers send local time as UTC); Settings → Guide.
pub const SETTING_GUIDE_OFFSET: &str = "guide_offset_hours";
/// M3U profiles: the playlist header's guide URL (templated).
pub const SETTING_M3U_TVG: &str = "m3u_tvg_url";
/// Xtream Codes: the server's clock against UTC in seconds (from the last sync), for catch-up URLs.
pub const SETTING_XC_OFFSET: &str = "xc_time_offset";

/// One guide source as Settings → Guide shows it.
#[derive(Debug, Clone, PartialEq)]
pub struct GuideSource {
    pub id: i64,
    /// The URL for extra sources (credentials templated out); empty for the provider's built-in guide.
    pub url: String,
    pub builtin: bool,
    pub last_fetch: i64,
    /// Empty when the last import worked, else what went wrong.
    pub status: String,
    pub channels: u32,
    pub programmes: u32,
}

/// The built-in guide's row in epg_sources (its real URL holds the login and is built when needed).
const BUILTIN: &str = "builtin";

/// A reminder for a guide programme (user data): the channel, start and stop (UTC seconds) and the title.
#[derive(Debug, Clone, PartialEq)]
pub struct Reminder {
    pub item_key: String,
    pub start: i64,
    pub stop: i64,
    pub title: String,
}

/// One stream_health row.
#[derive(Debug, Clone, PartialEq)]
pub struct HealthEntry {
    pub at: i64,
    pub key: String,
    pub name: String,
    pub trigger: String,
    pub attempts: u32,
    pub recovered: bool,
    pub secs: u32,
}

/// How many stream_health rows are kept (older ones are pruned on insert).
const HEALTH_KEEP: i64 = 2000;

impl Library {
    /// The provider's own guide URL: Xtream Codes xmltv.php, or the M3U header's url-tvg; None for M3U files without.
    fn builtin_guide_url(&self) -> Result<Option<String>> {
        if let Some(xc) = &self.xc {
            return Ok(Some(xc.xmltv_url()));
        }
        Ok(self
            .setting(SETTING_M3U_TVG)?
            .map(|u| db::fill_secrets(&u, &self.secret_refs())))
    }

    /// The guide sources, the provider's first (its row is created as soon as the provider offers a guide).
    pub fn guide_sources(&self) -> Result<Vec<GuideSource>> {
        if self.builtin_guide_url()?.is_some() {
            self.conn.lock().unwrap().execute(
                "INSERT OR IGNORE INTO epg_sources (url, builtin, updated_at) VALUES (?1, 1, ?2)",
                params![BUILTIN, now()],
            )?;
        }
        let conn = self.conn.lock().unwrap();
        let mut st = conn.prepare_cached(
            "SELECT id, url, builtin, last_fetch, status, channels, programmes FROM epg_sources
             ORDER BY builtin DESC, id",
        )?;
        let rows = st.query_map([], |r| {
            let builtin: bool = r.get(2)?;
            Ok(GuideSource {
                id: r.get(0)?,
                url: if builtin { String::new() } else { r.get(1)? },
                builtin,
                last_fetch: r.get(3)?,
                status: r.get(4)?,
                channels: r.get(5)?,
                programmes: r.get(6)?,
            })
        })?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    /// Adds an extra XMLTV URL (imported on the next refresh). Credentials in it are templated out on disk.
    pub fn add_guide_url(&self, url: &str) -> Result<()> {
        self.conn.lock().unwrap().execute(
            "INSERT OR IGNORE INTO epg_sources (url, builtin, updated_at) VALUES (?1, 0, ?2)",
            params![db::template_secrets(url.trim(), &self.secret_refs()), now()],
        )?;
        Ok(())
    }

    /// Removes an extra source and its programmes (the provider's built-in guide can't be removed).
    pub fn remove_guide_source(&self, id: i64) -> Result<()> {
        let mut conn = self.conn.lock().unwrap();
        conn.execute("DELETE FROM programmes_fts WHERE rowid IN (SELECT id FROM programmes WHERE source = ?1)", [id])?;
        conn.execute("DELETE FROM programmes WHERE source = ?1", [id])?;
        conn.execute("DELETE FROM epg_names WHERE channel IN (SELECT id FROM epg_channels WHERE source = ?1)", [id])?;
        conn.execute("DELETE FROM epg_channels WHERE source = ?1", [id])?;
        conn.execute(
            "DELETE FROM epg_sources WHERE id = ?1 AND builtin = 0",
            [id],
        )?;
        epg::rebuild_matches(&mut conn)?;
        Ok(())
    }

    /// Downloads and imports every guide source (the provider's first), keeps `days_ahead` days (and 2 back), prunes,
    /// and rebuilds the channel matches. A failing source keeps its previous data and records the error.
    pub async fn refresh_guide(&self, days_ahead: i64) -> Result<Vec<GuideSource>> {
        let sources = self.guide_sources()?;
        let offset = self
            .setting(SETTING_GUIDE_OFFSET)?
            .and_then(|h| h.parse::<i64>().ok())
            .unwrap_or(0)
            * 3600;
        for src in &sources {
            let url = if src.builtin {
                self.builtin_guide_url()?.unwrap_or_default()
            } else {
                db::fill_secrets(&src.url, &self.secret_refs())
            };
            let outcome = match self.download(&url, &format!("guide-{}.xml", src.id)).await {
                Ok(tmp) => {
                    let r = std::fs::File::open(&tmp)
                        .map_err(LibraryError::from)
                        .and_then(|f| {
                            epg::import(
                                &mut self.conn.lock().unwrap(),
                                src.id,
                                f,
                                now(),
                                2,
                                days_ahead,
                                offset,
                            )
                            .map_err(LibraryError::from)
                        });
                    let _ = std::fs::remove_file(&tmp);
                    r
                }
                Err(e) => Err(e),
            };
            let conn = self.conn.lock().unwrap();
            match outcome {
                Ok(st) => conn.execute(
                    "UPDATE epg_sources SET last_fetch = ?2, status = '', channels = ?3, programmes = ?4, updated_at = ?2
                     WHERE id = ?1",
                    params![src.id, now(), st.channels as i64, st.programmes as i64],
                )?,
                Err(e) => conn.execute(
                    "UPDATE epg_sources SET status = ?2, updated_at = ?3 WHERE id = ?1",
                    params![src.id, e.to_string(), now()],
                )?,
            };
        }
        {
            let mut conn = self.conn.lock().unwrap();
            epg::prune(&conn, now(), 2)?;
            epg::rebuild_matches(&mut conn)?;
        }
        self.guide_sources()
    }

    /// Seconds since the oldest successful guide import (None: never imported) — drives the 12 h refresh.
    pub fn guide_age(&self) -> Result<Option<i64>> {
        let oldest: Option<i64> = self.conn.lock().unwrap().query_row(
            "SELECT min(last_fetch) FROM epg_sources WHERE last_fetch > 0",
            [],
            |r| r.get(0),
        )?;
        Ok(oldest.map(|t| now() - t))
    }

    pub fn now_next(
        &self,
        keys: &[String],
    ) -> Result<Vec<(Option<epg::Programme>, Option<epg::Programme>)>> {
        Ok(epg::now_next(&self.conn.lock().unwrap(), keys, now())?)
    }

    pub fn guide_window(
        &self,
        keys: &[String],
        from: i64,
        to: i64,
    ) -> Result<Vec<Vec<epg::Programme>>> {
        Ok(epg::window(&self.conn.lock().unwrap(), keys, from, to)?)
    }

    pub fn programme(&self, id: i64) -> Result<Option<epg::Programme>> {
        Ok(epg::programme(&self.conn.lock().unwrap(), id)?)
    }

    pub fn search_programmes(
        &self,
        query: &str,
        limit: usize,
        earlier: bool,
    ) -> Result<Vec<(epg::Programme, Hit)>> {
        Ok(epg::search(
            &self.conn.lock().unwrap(),
            query,
            now(),
            limit,
            earlier,
        )?)
    }

    pub fn unmatched_channels(&self, limit: usize, offset: usize) -> Result<Vec<(String, String)>> {
        Ok(epg::unmatched(&self.conn.lock().unwrap(), limit, offset)?)
    }

    pub fn find_guide_channels(&self, query: &str, limit: usize) -> Result<Vec<(String, String)>> {
        Ok(epg::find_channels(
            &self.conn.lock().unwrap(),
            query,
            limit,
        )?)
    }

    pub fn map_channel(&self, item_key: &str, channel: Option<&str>) -> Result<()> {
        Ok(epg::map_channel(
            &mut self.conn.lock().unwrap(),
            item_key,
            channel,
            now(),
        )?)
    }

    /// Logs one recovery episode (from the watchdog's Health command).
    pub fn record_health(
        &self,
        key: &str,
        trigger: &str,
        attempts: u32,
        recovered: bool,
        secs: u32,
    ) -> Result<()> {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "INSERT INTO stream_health (at, key, trigger, attempts, recovered, secs) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![now(), key, trigger, attempts, recovered, secs],
        )?;
        conn.execute(
            "DELETE FROM stream_health WHERE id <= (SELECT max(id) FROM stream_health) - ?1",
            [HEALTH_KEEP],
        )?;
        Ok(())
    }

    /// The newest stream_health rows first, with the item's current name.
    pub fn health(&self, limit: usize) -> Result<Vec<HealthEntry>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare_cached(
            "SELECT h.at, h.key, coalesce(i.name, h.key), h.trigger, h.attempts, h.recovered, h.secs
             FROM stream_health h LEFT JOIN items i ON i.key = h.key ORDER BY h.id DESC LIMIT ?1",
        )?;
        let rows = stmt.query_map([limit as i64], |r| {
            Ok(HealthEntry {
                at: r.get(0)?,
                key: r.get(1)?,
                name: r.get(2)?,
                trigger: r.get(3)?,
                attempts: r.get(4)?,
                recovered: r.get(5)?,
                secs: r.get(6)?,
            })
        })?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    /// A profile setting, or None when never set.
    pub fn setting(&self, key: &str) -> Result<Option<String>> {
        let conn = self.conn.lock().unwrap();
        Ok(conn
            .query_row("SELECT value FROM settings WHERE key = ?1", [key], |r| {
                r.get(0)
            })
            .optional()?)
    }

    pub fn set_setting(&self, key: &str, value: &str) -> Result<()> {
        self.conn.lock().unwrap().execute(
            "INSERT INTO settings (key, value, updated_at) VALUES (?1, ?2, ?3)
             ON CONFLICT (key) DO UPDATE SET value = ?2, updated_at = ?3",
            params![key, value, now()],
        )?;
        Ok(())
    }

    /// The buffer preset for an item: its own override, else the profile's preset, else Balanced.
    pub fn buffer_for(&self, key: &str) -> Result<crate::playback::BufferPreset> {
        let own: Option<String> = self
            .conn
            .lock()
            .unwrap()
            .query_row(
                "SELECT buffer FROM stream_prefs WHERE key = ?1 AND buffer != ''",
                [key],
                |r| r.get(0),
            )
            .optional()?;
        let preset = own.or(self.setting(SETTING_BUFFER)?).unwrap_or_default();
        Ok(crate::playback::BufferPreset::parse(&preset))
    }

    /// The item's own buffer override, if it has one.
    pub fn channel_buffer(&self, key: &str) -> Result<Option<crate::playback::BufferPreset>> {
        let own: Option<String> = self
            .conn
            .lock()
            .unwrap()
            .query_row(
                "SELECT buffer FROM stream_prefs WHERE key = ?1 AND buffer != ''",
                [key],
                |r| r.get(0),
            )
            .optional()?;
        Ok(own.map(|k| crate::playback::BufferPreset::parse(&k)))
    }

    /// Sets (Some) or clears (None: use the profile's preset) an item's buffer override.
    pub fn set_channel_buffer(
        &self,
        key: &str,
        preset: Option<crate::playback::BufferPreset>,
    ) -> Result<()> {
        self.conn.lock().unwrap().execute(
            "INSERT INTO stream_prefs (key, prefer_hls, updated_at, buffer) VALUES (?1, 0, ?2, ?3)
             ON CONFLICT (key) DO UPDATE SET buffer = ?3, updated_at = ?2",
            params![key, now(), preset.map(|p| p.key()).unwrap_or_default()],
        )?;
        Ok(())
    }

    /// Adaptive mode: raises this item's buffer one step (stored as its override) and returns the new preset.
    pub fn raise_buffer(&self, key: &str) -> Result<crate::playback::BufferPreset> {
        let next = self.buffer_for(key)?.step_up();
        self.set_channel_buffer(key, Some(next))?;
        Ok(next)
    }

    /// The channel's last measured video bitrate in bit/s (0 = unknown).
    pub fn bitrate(&self, key: &str) -> Result<u64> {
        let v: Option<i64> = self
            .conn
            .lock()
            .unwrap()
            .query_row(
                "SELECT bitrate FROM stream_prefs WHERE key = ?1",
                [key],
                |r| r.get(0),
            )
            .optional()?;
        Ok(v.unwrap_or(0).max(0) as u64)
    }

    pub fn set_bitrate(&self, key: &str, bps: u64) -> Result<()> {
        self.conn.lock().unwrap().execute(
            "INSERT INTO stream_prefs (key, prefer_hls, updated_at, bitrate) VALUES (?1, 0, ?2, ?3)
             ON CONFLICT (key) DO UPDATE SET bitrate = ?3, updated_at = ?2",
            params![key, now(), bps as i64],
        )?;
        Ok(())
    }

    /// Whether this channel last worked as HLS (false = TS, the default).
    pub fn prefer_hls(&self, key: &str) -> Result<bool> {
        let conn = self.conn.lock().unwrap();
        let v: Option<bool> = conn
            .query_row(
                "SELECT prefer_hls FROM stream_prefs WHERE key = ?1",
                [key],
                |r| r.get(0),
            )
            .optional()?;
        Ok(v.unwrap_or(false))
    }

    pub fn set_prefer_hls(&self, key: &str, hls: bool) -> Result<()> {
        self.conn.lock().unwrap().execute(
            "INSERT INTO stream_prefs (key, prefer_hls, updated_at) VALUES (?1, ?2, ?3)
             ON CONFLICT (key) DO UPDATE SET prefer_hls = ?2, updated_at = ?3",
            params![key, hls, now()],
        )?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use gerdtv_testkit::mock_xc::{MockXc, PASS, USER};

    fn tempdir(name: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("gerdtv-lib-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        d
    }

    fn profile(source: SourceKind, server: &str) -> Profile {
        Profile {
            id: String::new(),
            name: "Test".into(),
            source,
            server: server.into(),
            user_agent: String::new(),
            max_connections: None,
            updated_at: 0,
        }
    }

    #[test]
    fn profiles_round_trip_without_secrets() {
        let dir = tempdir("profiles");
        assert!(load_profiles(&dir).unwrap().is_empty());
        let a = save_profile(
            &dir,
            profile(SourceKind::Xtream, "http://xc.example.invalid"),
        )
        .unwrap();
        let b = save_profile(&dir, profile(SourceKind::M3uFile, "/tmp/x.m3u")).unwrap();
        assert_ne!(a.id, b.id);
        let mut renamed = a.clone();
        renamed.name = "Renamed".into();
        save_profile(&dir, renamed).unwrap();
        let all = load_profiles(&dir).unwrap();
        assert_eq!(
            all.iter().map(|p| p.name.as_str()).collect::<Vec<_>>(),
            ["Renamed", "Test"]
        );
        delete_profile(&dir, &b.id).unwrap();
        assert_eq!(load_profiles(&dir).unwrap().len(), 1);
        assert!(
            !std::fs::read_to_string(dir.join("profiles.json"))
                .unwrap()
                .contains(PASS)
        );
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn app_settings_round_trip() {
        let dir = tempdir("app-settings");
        assert_eq!(app_setting(&dir, "app_logo").unwrap(), None); // no app.json yet
        set_app_setting(&dir, "app_logo", "signal").unwrap();
        set_app_setting(&dir, "other", "1").unwrap();
        set_app_setting(&dir, "app_logo", "frame").unwrap();
        assert_eq!(
            app_setting(&dir, "app_logo").unwrap().as_deref(),
            Some("frame")
        );
        assert_eq!(app_setting(&dir, "other").unwrap().as_deref(), Some("1"));
        assert!(!dir.join("app.json.tmp").exists());
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[tokio::test]
    async fn xtream_profile_syncs_browses_searches_and_plays() {
        let mock = MockXc::start(2000, 9).await;
        let dir = tempdir("xc");
        let p = save_profile(&dir, profile(SourceKind::Xtream, &mock.base())).unwrap();
        assert!(matches!(
            Library::open(&dir, &p.id, vec![]),
            Err(LibraryError::Secrets(2))
        ));
        let lib = Library::open(&dir, &p.id, vec![USER.into(), PASS.into()]).unwrap();
        let r = lib.sync().await.unwrap();
        assert_eq!(r.account.unwrap().max_connections, 2);

        let cats = lib.categories(Kind::Live).unwrap();
        assert!(!cats.is_empty() && cats.iter().all(|c| c.count > 0));
        let page = lib.items(Kind::Live, &cats[0].id, 5, 0).unwrap();
        assert_eq!(page.len(), 5.min(cats[0].count));
        let (hits, counts, _) = lib.search("munchen", &[], None, 10, 0).unwrap();
        assert!(!hits.is_empty() && !counts.is_empty());
        assert!(
            lib.stream_url(&page[0].key, "m3u8")
                .unwrap()
                .ends_with(".m3u8")
        );

        // Stream health and the per-channel URL form.
        let key = page[0].key.clone();
        assert!(!lib.prefer_hls(&key).unwrap());
        lib.set_prefer_hls(&key, true).unwrap();
        assert!(lib.prefer_hls(&key).unwrap());
        lib.record_health(&key, "live_end", 4, true, 15).unwrap();
        lib.record_health("live:gone", "error", 6, false, 90)
            .unwrap();
        let h = lib.health(10).unwrap();
        assert_eq!(
            (
                h.len(),
                h[0].name.as_str(),
                h[1].name.as_str(),
                h[1].recovered
            ),
            (2, "live:gone", page[0].name.as_str(), true)
        );

        // Buffer: profile preset, per-channel override (cleared again), measured bitrate.
        use crate::playback::BufferPreset;
        assert_eq!(lib.buffer_for(&key).unwrap(), BufferPreset::Balanced);
        lib.set_setting(SETTING_BUFFER, "smooth").unwrap();
        assert_eq!(lib.buffer_for(&key).unwrap(), BufferPreset::Smooth);
        assert_eq!(lib.channel_buffer(&key).unwrap(), None);
        lib.set_channel_buffer(&key, Some(BufferPreset::Custom(45)))
            .unwrap();
        assert_eq!(lib.buffer_for(&key).unwrap(), BufferPreset::Custom(45));
        assert_eq!(
            lib.channel_buffer(&key).unwrap(),
            Some(BufferPreset::Custom(45))
        );
        assert_eq!(
            lib.raise_buffer(&key).unwrap(),
            BufferPreset::MaxSmooth,
            "45 s steps up past Smooth (30 s)"
        );
        assert!(
            lib.prefer_hls(&key).unwrap(),
            "the override keeps the remembered URL form"
        );
        lib.set_channel_buffer(&key, None).unwrap();
        assert_eq!(lib.buffer_for(&key).unwrap(), BufferPreset::Smooth);
        assert_eq!(lib.bitrate(&key).unwrap(), 0);
        lib.set_bitrate(&key, 6_500_000).unwrap();
        assert_eq!(lib.bitrate(&key).unwrap(), 6_500_000);

        // The guide: the panel's xmltv.php is the built-in source; after a refresh, matched channels have now/next.
        let sources = lib.refresh_guide(7).await.unwrap();
        assert_eq!(sources.len(), 1);
        assert!(
            sources[0].builtin && sources[0].status.is_empty() && sources[0].programmes > 1000,
            "{sources:?}"
        );
        assert!(lib.guide_age().unwrap().unwrap() < 60);
        let live: Vec<String> = lib
            .items(Kind::Live, &cats[0].id, 50, 0)
            .unwrap()
            .into_iter()
            .map(|h| h.key)
            .collect();
        let nn = lib.now_next(&live).unwrap();
        assert!(
            nn.iter().any(|(now, next)| now.is_some() && next.is_some()),
            "some channels show now/next"
        );
        assert!(
            !lib.unmatched_channels(100, 0).unwrap().is_empty(),
            "channels without epg id stay unmatched"
        );
        let hits = lib.search_programmes("sport", 5, false).unwrap();
        assert!(!hits.is_empty());
        // The profile's guide offset shifts every imported time.
        let w = lib.guide_window(&live, 0, i64::MAX).unwrap();
        let (i, first) = w
            .iter()
            .enumerate()
            .find_map(|(i, v)| v.first().map(|p| (i, p.clone())))
            .unwrap();
        lib.set_setting(SETTING_GUIDE_OFFSET, "1").unwrap();
        lib.refresh_guide(7).await.unwrap();
        let shifted = &lib.guide_window(&live[i..=i], 0, i64::MAX).unwrap()[0][0];
        assert_eq!(
            (shifted.title.as_str(), shifted.start),
            (first.title.as_str(), first.start + 3600)
        );
        lib.add_guide_url("http://127.0.0.1:9/extra.xml").unwrap();
        let sources = lib.refresh_guide(7).await.unwrap();
        assert_eq!(sources.len(), 2);
        assert!(
            sources[1].status.starts_with("network error"),
            "a failing extra source records its error"
        );
        lib.remove_guide_source(sources[1].id).unwrap();

        // Catch-up: the mock panel gives every 13th live channel a 3-day archive.
        let t = now();
        let all_live: Vec<Hit> = cats
            .iter()
            .flat_map(|c| lib.items(Kind::Live, &c.id, 500, 0).unwrap())
            .collect();
        let archive = all_live
            .iter()
            .find(|h| h.archive_days == 3)
            .expect("an archive channel");
        let plain = all_live.iter().find(|h| h.archive_days == 0).unwrap();
        // (channel, start, stop, catch-up URL expected)
        let cases = [
            (&archive.key, t - 7200, t - 3600, true),
            (&archive.key, t - 1800, t + 1800, true), // running: from its start up to now
            (&archive.key, t - 4 * 86_400, t - 4 * 86_400 + 3600, false), // beyond the 3 days
            (&archive.key, t + 600, t + 4200, false), // not started
            (&plain.key, t - 7200, t - 3600, false),  // no archive
        ];
        for (key, start, stop, want) in cases {
            let url = lib.catchup_url(key, start, stop).unwrap();
            assert_eq!(url.is_some(), want, "{key} {start}");
            if let Some(u) = url {
                assert!(
                    u.contains("/timeshift/") && u.ends_with(".ts"),
                    "the timeshift form"
                );
            }
        }
        // Reminders: set, listed soonest first, cleared.
        let r = |start: i64| Reminder {
            item_key: archive.key.clone(),
            start,
            stop: start + 1800,
            title: "Film".into(),
        };
        lib.set_reminder(&r(t + 7200), true).unwrap();
        lib.set_reminder(&r(t + 3600), true).unwrap();
        assert_eq!(
            lib.reminders()
                .unwrap()
                .iter()
                .map(|x| x.start)
                .collect::<Vec<_>>(),
            [t + 3600, t + 7200]
        );
        lib.set_reminder(&r(t + 3600), false).unwrap();
        assert_eq!(lib.reminders().unwrap().len(), 1);
        // A reminder's channel comes back by key; a key that's gone gives None.
        assert_eq!(lib.item(&archive.key).unwrap().unwrap().name, archive.name);
        assert!(lib.item("live:0").unwrap().is_none());
        assert_eq!(lib.guide_sources().unwrap().len(), 1);

        // Cache-first: reopening without network shows the catalogue at once.
        drop(lib);
        let lib = Library::open(&dir, &p.id, vec![USER.into(), PASS.into()]).unwrap();
        assert_eq!(lib.categories(Kind::Live).unwrap(), cats);
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[tokio::test]
    async fn m3u_url_profile_keeps_credentials_out_of_the_database() {
        let mock = MockXc::start(500, 2).await;
        let dir = tempdir("m3u");
        let p = save_profile(&dir, profile(SourceKind::M3uUrl, "")).unwrap();
        let url = format!(
            "{}/get.php?username={USER}&password={PASS}&type=m3u_plus&output=m3u8",
            mock.base()
        );
        let lib = Library::open(&dir, &p.id, vec![url]).unwrap();
        let r = lib.sync().await.unwrap();
        assert_eq!(r.stats.entries, 500);
        let (hits, _, _) = lib.search("s", &[Kind::Movie], None, 1, 0).unwrap();
        // The generated playlist uses the testkit's fixed example credentials, which equal the mock's.
        assert!(
            lib.stream_url(&hits[0].key, "ts")
                .unwrap()
                .contains(&format!("/{USER}/{PASS}/"))
        );
        drop(lib);
        let raw = std::fs::read(db_path(&dir, &p.id)).unwrap();
        assert!(
            !String::from_utf8_lossy(&raw).contains(PASS),
            "no password in the database file"
        );
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
