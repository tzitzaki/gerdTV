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
    pub epg_urls: Vec<String>,
    #[serde(default)]
    pub user_agent: String,
    /// Hours added to guide times from this provider (some send local time as UTC).
    #[serde(default)]
    pub epg_offset_hours: i32,
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

/// One page of hits plus per-kind totals (totals only on the first page).
pub type SearchResult = (Vec<Hit>, Vec<(Kind, usize)>);

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

    /// Downloads and writes the catalogue. The database is only locked for the final write.
    pub async fn sync(&self) -> Result<SyncResult> {
        match self.profile.source {
            SourceKind::Xtream => {
                let f = xtream::fetch(self.xc.as_ref().unwrap()).await?;
                let stats = xtream::write(&mut self.conn.lock().unwrap(), &f)?;
                Ok(SyncResult {
                    stats,
                    account: Some(f.account),
                })
            }
            SourceKind::M3uUrl => {
                // Download to a temp file first (streamed), then parse: the old catalogue stays usable meanwhile.
                xtream::ensure_tls_provider();
                let client = reqwest::Client::builder()
                    .user_agent(if self.profile.user_agent.is_empty() {
                        "gerdTV"
                    } else {
                        &self.profile.user_agent
                    })
                    .build()
                    .map_err(|e| XcError::Network(e.without_url().to_string()))?;
                let mut res = client
                    .get(&self.secrets[0])
                    .send()
                    .await
                    .map_err(|e| XcError::Network(e.without_url().to_string()))?;
                if !res.status().is_success() {
                    return Err(XcError::Http(res.status().as_u16()).into());
                }
                let tmp = db_path(
                    Path::new(&std::env::temp_dir()),
                    &format!("{}-download", self.profile.id),
                )
                .with_extension("m3u");
                std::fs::create_dir_all(tmp.parent().unwrap())?;
                {
                    use std::io::Write;
                    let mut f = std::io::BufWriter::new(std::fs::File::create(&tmp)?);
                    while let Some(chunk) = res
                        .chunk()
                        .await
                        .map_err(|e| XcError::Network(e.without_url().to_string()))?
                    {
                        f.write_all(&chunk)?;
                    }
                    f.flush()?;
                }
                let r = std::io::BufReader::new(std::fs::File::open(&tmp)?);
                let stats = db::import_m3u(&mut self.conn.lock().unwrap(), r, &self.secret_refs());
                let _ = std::fs::remove_file(&tmp);
                Ok(SyncResult {
                    stats: stats?,
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

    /// Categories of a kind in provider order, with their item counts (empty ones hidden).
    pub fn categories(&self, kind: Kind) -> Result<Vec<Category>> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn.prepare_cached(
            "SELECT c.id, c.name, count(i.key) FROM categories c
             JOIN items i ON i.kind = c.kind AND i.category = c.id
             WHERE c.kind = ?1 GROUP BY c.id ORDER BY c.position",
        )?;
        let rows = stmt.query_map([kind as i64], |r| {
            Ok(Category {
                id: r.get(0)?,
                name: r.get(1)?,
                count: r.get::<_, i64>(2)? as usize,
            })
        })?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
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
            "SELECT key, kind, name, category, logo, number FROM items
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
                })
            },
        )?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    pub fn search(
        &self,
        query: &str,
        kind: Option<Kind>,
        limit: usize,
        offset: usize,
    ) -> Result<SearchResult> {
        let conn = self.conn.lock().unwrap();
        let hits = db::search(&conn, query, kind, limit, offset)?;
        let counts = if offset == 0 {
            db::search_counts(&conn, query)?
        } else {
            vec![]
        };
        Ok((hits, counts))
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
            "SELECT key, kind, name, category, logo, number FROM items
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
            })
        })?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    /// The URL to play an item (live: `.ts` by default, `m3u8` when the watchdog asks; VOD: its container).
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
            epg_urls: vec![],
            user_agent: String::new(),
            epg_offset_hours: 0,
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
        let (hits, counts) = lib.search("munchen", None, 10, 0).unwrap();
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
        let (hits, _) = lib.search("s", Some(Kind::Movie), 1, 0).unwrap();
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
