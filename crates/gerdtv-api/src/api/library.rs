//! Bridge surface for profiles and the library (logic: gerdtv_core::library). Errors cross as messages that are
//! already free of credentials (gerdtv_core redacts at the source).

use gerdtv_core::db::Kind as CoreKind;
use gerdtv_core::library as core;
use std::path::PathBuf;

pub enum ItemKind {
    Live,
    Movie,
    Episode,
    Series,
}

fn to_core(k: ItemKind) -> CoreKind {
    match k {
        ItemKind::Live => CoreKind::Live,
        ItemKind::Movie => CoreKind::Movie,
        ItemKind::Episode => CoreKind::Episode,
        ItemKind::Series => CoreKind::Series,
    }
}

fn from_core(k: CoreKind) -> ItemKind {
    match k {
        CoreKind::Live => ItemKind::Live,
        CoreKind::Movie => ItemKind::Movie,
        CoreKind::Episode => ItemKind::Episode,
        CoreKind::Series => ItemKind::Series,
    }
}

pub enum SourceKind {
    Xtream,
    M3uUrl,
    M3uFile,
}

/// A profile's non-secret settings (secrets stay in the app's secure storage).
pub struct ProfileInfo {
    pub id: String,
    pub name: String,
    pub source: SourceKind,
    pub server: String,
    pub epg_urls: Vec<String>,
    pub user_agent: String,
    pub epg_offset_hours: i32,
    pub max_connections: Option<u32>,
}

impl From<core::Profile> for ProfileInfo {
    fn from(p: core::Profile) -> Self {
        ProfileInfo {
            id: p.id,
            name: p.name,
            source: match p.source {
                core::SourceKind::Xtream => SourceKind::Xtream,
                core::SourceKind::M3uUrl => SourceKind::M3uUrl,
                core::SourceKind::M3uFile => SourceKind::M3uFile,
            },
            server: p.server,
            epg_urls: p.epg_urls,
            user_agent: p.user_agent,
            epg_offset_hours: p.epg_offset_hours,
            max_connections: p.max_connections,
        }
    }
}

fn err(e: impl std::fmt::Display) -> String {
    e.to_string()
}

pub fn list_profiles(dir: String) -> Result<Vec<ProfileInfo>, String> {
    Ok(core::load_profiles(&PathBuf::from(dir))
        .map_err(err)?
        .into_iter()
        .map(Into::into)
        .collect())
}

/// Adds (empty id) or replaces a profile; returns it with its id.
pub fn save_profile(dir: String, profile: ProfileInfo) -> Result<ProfileInfo, String> {
    let p = core::Profile {
        id: profile.id,
        name: profile.name,
        source: match profile.source {
            SourceKind::Xtream => core::SourceKind::Xtream,
            SourceKind::M3uUrl => core::SourceKind::M3uUrl,
            SourceKind::M3uFile => core::SourceKind::M3uFile,
        },
        server: profile.server,
        epg_urls: profile.epg_urls,
        user_agent: profile.user_agent,
        epg_offset_hours: profile.epg_offset_hours,
        max_connections: profile.max_connections,
        updated_at: 0,
    };
    Ok(core::save_profile(&PathBuf::from(dir), p)
        .map_err(err)?
        .into())
}

pub fn delete_profile(dir: String, id: String) -> Result<(), String> {
    core::delete_profile(&PathBuf::from(dir), &id).map_err(err)
}

pub struct CategoryInfo {
    pub id: String,
    pub name: String,
    pub count: u32,
}

pub struct ItemInfo {
    pub key: String,
    pub kind: ItemKind,
    pub name: String,
    pub category: String,
    pub logo: String,
    pub number: Option<u32>,
}

impl From<gerdtv_core::db::Hit> for ItemInfo {
    fn from(h: gerdtv_core::db::Hit) -> Self {
        ItemInfo {
            key: h.key,
            kind: from_core(h.kind),
            name: h.name,
            category: h.category,
            logo: h.logo,
            number: h.number,
        }
    }
}

pub struct KindCount {
    pub kind: ItemKind,
    pub count: u32,
}

/// One page of search results. `seq` echoes the caller's sequence number, so the UI drops answers to keystrokes
/// that are no longer current (the list never flickers back).
pub struct SearchPage {
    pub seq: u64,
    pub hits: Vec<ItemInfo>,
    /// Per-kind totals; only on the first page (offset 0).
    pub counts: Vec<KindCount>,
}

pub struct SyncSummary {
    pub entries: u32,
    pub removed: u32,
    pub categories: u32,
    pub max_connections: Option<u32>,
    pub active_connections: Option<u32>,
}

/// One stream_health row.
pub struct HealthInfo {
    pub at: i64,
    pub key: String,
    pub name: String,
    pub trigger: String,
    pub attempts: u32,
    pub recovered: bool,
    pub secs: u32,
}

/// An open profile.
#[flutter_rust_bridge::frb(opaque)]
pub struct Library(core::Library);

impl Library {
    /// Opens a profile's cached catalogue at once; `secrets` from secure storage (see gerdtv_core::library).
    pub fn open(dir: String, profile_id: String, secrets: Vec<String>) -> Result<Library, String> {
        core::Library::open(&PathBuf::from(dir), &profile_id, secrets)
            .map(Library)
            .map_err(err)
    }

    pub async fn sync(&self) -> Result<SyncSummary, String> {
        let r = self.0.sync().await.map_err(err)?;
        Ok(SyncSummary {
            entries: r.stats.entries as u32,
            removed: r.stats.removed as u32,
            categories: r.stats.categories as u32,
            max_connections: r.account.as_ref().map(|a| a.max_connections),
            active_connections: r.account.as_ref().map(|a| a.active_connections),
        })
    }

    pub fn categories(&self, kind: ItemKind) -> Result<Vec<CategoryInfo>, String> {
        Ok(self
            .0
            .categories(to_core(kind))
            .map_err(err)?
            .into_iter()
            .map(|c| CategoryInfo {
                id: c.id,
                name: c.name,
                count: c.count as u32,
            })
            .collect())
    }

    pub fn items(
        &self,
        kind: ItemKind,
        category: String,
        limit: u32,
        offset: u32,
    ) -> Result<Vec<ItemInfo>, String> {
        Ok(self
            .0
            .items(to_core(kind), &category, limit as usize, offset as usize)
            .map_err(err)?
            .into_iter()
            .map(Into::into)
            .collect())
    }

    /// Search as the user types; `kind` None = all kinds.
    pub fn search(
        &self,
        seq: u64,
        query: String,
        kind: Option<ItemKind>,
        limit: u32,
        offset: u32,
    ) -> Result<SearchPage, String> {
        let (hits, counts) = self
            .0
            .search(&query, kind.map(to_core), limit as usize, offset as usize)
            .map_err(err)?;
        Ok(SearchPage {
            seq,
            hits: hits.into_iter().map(Into::into).collect(),
            counts: counts
                .into_iter()
                .map(|(k, n)| KindCount {
                    kind: from_core(k),
                    count: n as u32,
                })
                .collect(),
        })
    }

    /// Logs a recovery episode (the watchdog's Health command).
    pub fn record_health(
        &self,
        key: String,
        trigger: String,
        attempts: u32,
        recovered: bool,
        secs: u32,
    ) -> Result<(), String> {
        self.0
            .record_health(&key, &trigger, attempts, recovered, secs)
            .map_err(err)
    }

    /// The newest stream_health rows (Settings → Stream health).
    pub fn health(&self, limit: u32) -> Result<Vec<HealthInfo>, String> {
        Ok(self
            .0
            .health(limit as usize)
            .map_err(err)?
            .into_iter()
            .map(|h| HealthInfo {
                at: h.at,
                key: h.key,
                name: h.name,
                trigger: h.trigger,
                attempts: h.attempts,
                recovered: h.recovered,
                secs: h.secs,
            })
            .collect())
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn prefer_hls(&self, key: String) -> Result<bool, String> {
        self.0.prefer_hls(&key).map_err(err)
    }

    pub fn set_prefer_hls(&self, key: String, hls: bool) -> Result<(), String> {
        self.0.set_prefer_hls(&key, hls).map_err(err)
    }

    /// The play URL (holds credentials: pass it straight to the player, never log or show it).
    #[flutter_rust_bridge::frb(sync)]
    pub fn stream_url(&self, key: String, prefer_hls: bool) -> Result<String, String> {
        self.0
            .stream_url(&key, if prefer_hls { "m3u8" } else { "ts" })
            .map_err(err)
    }
}
