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
    pub user_agent: String,
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
            user_agent: p.user_agent,
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
        user_agent: profile.user_agent,
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
    /// Live channels: catch-up days (0 = none).
    pub archive_days: u32,
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
            archive_days: h.archive_days,
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

/// One guide source as Settings → Guide shows it (the provider's built-in guide first, its URL left empty).
pub struct GuideSourceInfo {
    pub id: i64,
    pub url: String,
    pub builtin: bool,
    /// UTC seconds of the last successful import; 0 = never.
    pub last_fetch: i64,
    /// Empty when the last import worked, else what went wrong (free of credentials).
    pub status: String,
    pub channels: u32,
    pub programmes: u32,
}

impl From<core::GuideSource> for GuideSourceInfo {
    fn from(g: core::GuideSource) -> Self {
        GuideSourceInfo {
            id: g.id,
            url: g.url,
            builtin: g.builtin,
            last_fetch: g.last_fetch,
            status: g.status,
            channels: g.channels,
            programmes: g.programmes,
        }
    }
}

/// A guide programme; times are UTC seconds.
pub struct ProgrammeInfo {
    pub id: i64,
    pub channel: String,
    pub start: i64,
    pub stop: i64,
    pub title: String,
    pub sub_title: String,
    pub desc: String,
    pub category: String,
    pub episode: String,
}

impl From<gerdtv_core::epg::Programme> for ProgrammeInfo {
    fn from(p: gerdtv_core::epg::Programme) -> Self {
        ProgrammeInfo {
            id: p.id,
            channel: p.channel,
            start: p.start,
            stop: p.stop,
            title: p.title,
            sub_title: p.sub_title,
            desc: p.desc,
            category: p.category,
            episode: p.episode,
        }
    }
}

/// What is on a channel now and next (either may be missing).
pub struct NowNext {
    pub now: Option<ProgrammeInfo>,
    pub next: Option<ProgrammeInfo>,
}

/// One channel's programmes in a time window (the guide grid's row).
pub struct GuideRow {
    pub programmes: Vec<ProgrammeInfo>,
}

/// A programme search hit with the live channel that shows it (ready to play).
pub struct ProgrammeHit {
    pub programme: ProgrammeInfo,
    pub item: ItemInfo,
}

/// A reminder for a guide programme: the channel, start and stop (UTC seconds) and the title.
pub struct ReminderInfo {
    pub item_key: String,
    pub start: i64,
    pub stop: i64,
    pub title: String,
}

/// A channel by id and name: a live item without a guide, or a guide channel to map it to.
pub struct ChannelRef {
    pub id: String,
    pub name: String,
}

fn refs(v: Vec<(String, String)>) -> Vec<ChannelRef> {
    v.into_iter()
        .map(|(id, name)| ChannelRef { id, name })
        .collect()
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

    /// A series' episodes in order (Xtream Codes fetches them now; M3U has them already).
    pub async fn episodes(&self, series_key: String) -> Result<Vec<ItemInfo>, String> {
        Ok(self
            .0
            .episodes(&series_key)
            .await
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

    /// A profile setting (None = never set). Keys: "buffer_preset", "adaptive_buffer", "timeshift_secs".
    #[flutter_rust_bridge::frb(sync)]
    pub fn setting(&self, key: String) -> Result<Option<String>, String> {
        self.0.setting(&key).map_err(err)
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_setting(&self, key: String, value: String) -> Result<(), String> {
        self.0.set_setting(&key, &value).map_err(err)
    }

    /// The buffer for an item: its override, else the profile's preset, else Balanced.
    #[flutter_rust_bridge::frb(sync)]
    pub fn buffer_for(&self, key: String) -> Result<super::playback::BufferChoice, String> {
        self.0
            .buffer_for(&key)
            .map(super::playback::choice)
            .map_err(err)
    }

    /// Whether the item has its own buffer (else it follows the profile's preset).
    #[flutter_rust_bridge::frb(sync)]
    pub fn has_channel_buffer(&self, key: String) -> Result<bool, String> {
        Ok(self.0.channel_buffer(&key).map_err(err)?.is_some())
    }

    /// Sets the item's own buffer; `preset` None clears it (back to the profile's preset).
    #[flutter_rust_bridge::frb(sync)]
    pub fn set_channel_buffer(
        &self,
        key: String,
        preset: Option<super::playback::BufferPreset>,
        custom_seconds: u32,
    ) -> Result<(), String> {
        self.0
            .set_channel_buffer(
                &key,
                preset.map(|p| super::playback::from_choice(p, custom_seconds)),
            )
            .map_err(err)
    }

    /// Adaptive mode: one step more buffer for this item; returns the new choice.
    #[flutter_rust_bridge::frb(sync)]
    pub fn raise_buffer(&self, key: String) -> Result<super::playback::BufferChoice, String> {
        self.0
            .raise_buffer(&key)
            .map(super::playback::choice)
            .map_err(err)
    }

    /// The item's last measured video bitrate (bit/s, 0 = unknown).
    #[flutter_rust_bridge::frb(sync)]
    pub fn bitrate(&self, key: String) -> Result<u64, String> {
        self.0.bitrate(&key).map_err(err)
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_bitrate(&self, key: String, bps: u64) -> Result<(), String> {
        self.0.set_bitrate(&key, bps).map_err(err)
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

    // The guide (logic: gerdtv_core::epg). Settings → Guide, now/next in lists, the grid and programme search.

    /// The guide sources, the provider's first.
    pub fn guide_sources(&self) -> Result<Vec<GuideSourceInfo>, String> {
        Ok(self
            .0
            .guide_sources()
            .map_err(err)?
            .into_iter()
            .map(Into::into)
            .collect())
    }

    pub fn add_guide_url(&self, url: String) -> Result<(), String> {
        self.0.add_guide_url(&url).map_err(err)
    }

    pub fn remove_guide_source(&self, id: i64) -> Result<(), String> {
        self.0.remove_guide_source(id).map_err(err)
    }

    /// Downloads and imports every source, keeping `days_ahead` days (7 desktop, 3 phone and TV) and 2 back.
    pub async fn refresh_guide(&self, days_ahead: u32) -> Result<Vec<GuideSourceInfo>, String> {
        Ok(self
            .0
            .refresh_guide(days_ahead as i64)
            .await
            .map_err(err)?
            .into_iter()
            .map(Into::into)
            .collect())
    }

    /// Seconds since the oldest successful import (None: never); the app refreshes when it is over 12 h.
    pub fn guide_age(&self) -> Result<Option<i64>, String> {
        self.0.guide_age().map_err(err)
    }

    /// Now and next for each item key, in the same order.
    pub fn now_next(&self, keys: Vec<String>) -> Result<Vec<NowNext>, String> {
        Ok(self
            .0
            .now_next(&keys)
            .map_err(err)?
            .into_iter()
            .map(|(now, next)| NowNext {
                now: now.map(Into::into),
                next: next.map(Into::into),
            })
            .collect())
    }

    /// Each item key's programmes overlapping `from`..`to` (UTC seconds), in the same order.
    pub fn guide_window(
        &self,
        keys: Vec<String>,
        from: i64,
        to: i64,
    ) -> Result<Vec<GuideRow>, String> {
        Ok(self
            .0
            .guide_window(&keys, from, to)
            .map_err(err)?
            .into_iter()
            .map(|v| GuideRow {
                programmes: v.into_iter().map(Into::into).collect(),
            })
            .collect())
    }

    pub fn programme(&self, id: i64) -> Result<Option<ProgrammeInfo>, String> {
        Ok(self.0.programme(id).map_err(err)?.map(Into::into))
    }

    /// Programmes whose title, sub-title or description match, ongoing and upcoming first.
    pub fn search_programmes(
        &self,
        query: String,
        limit: u32,
    ) -> Result<Vec<ProgrammeHit>, String> {
        Ok(self
            .0
            .search_programmes(&query, limit as usize)
            .map_err(err)?
            .into_iter()
            .map(|(p, hit)| ProgrammeHit {
                programme: p.into(),
                item: hit.into(),
            })
            .collect())
    }

    /// Live channels without a guide match, in provider order (the mapping screen).
    pub fn unmatched_channels(&self, limit: u32, offset: u32) -> Result<Vec<ChannelRef>, String> {
        Ok(refs(
            self.0
                .unmatched_channels(limit as usize, offset as usize)
                .map_err(err)?,
        ))
    }

    /// Guide channels whose name or id contains the query.
    pub fn find_guide_channels(
        &self,
        query: String,
        limit: u32,
    ) -> Result<Vec<ChannelRef>, String> {
        Ok(refs(
            self.0
                .find_guide_channels(&query, limit as usize)
                .map_err(err)?,
        ))
    }

    /// The catch-up URL of a programme on a live channel, or None (no archive, out of reach, not started, not
    /// Xtream Codes). Holds credentials: pass it straight to the player, never log or show it.
    #[flutter_rust_bridge::frb(sync)]
    pub fn catchup_url(
        &self,
        key: String,
        start: i64,
        stop: i64,
    ) -> Result<Option<String>, String> {
        self.0.catchup_url(&key, start, stop).map_err(err)
    }

    /// Reminders still to come, soonest first.
    pub fn reminders(&self) -> Result<Vec<ReminderInfo>, String> {
        Ok(self
            .0
            .reminders()
            .map_err(err)?
            .into_iter()
            .map(|r| ReminderInfo {
                item_key: r.item_key,
                start: r.start,
                stop: r.stop,
                title: r.title,
            })
            .collect())
    }

    /// Sets or clears a reminder.
    pub fn set_reminder(&self, reminder: ReminderInfo, on: bool) -> Result<(), String> {
        let r = core::Reminder {
            item_key: reminder.item_key,
            start: reminder.start,
            stop: reminder.stop,
            title: reminder.title,
        };
        self.0.set_reminder(&r, on).map_err(err)
    }

    /// Maps a live item to a guide channel by hand (None: back to automatic matching).
    pub fn map_channel(&self, item_key: String, channel: Option<String>) -> Result<(), String> {
        self.0
            .map_channel(&item_key, channel.as_deref())
            .map_err(err)
    }
}
