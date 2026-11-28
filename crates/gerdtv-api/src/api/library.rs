//! Bridge surface for profiles and the library (logic: gerdtv_core::library). Errors cross as messages that are
//! already free of credentials (gerdtv_core redacts at the source).

use gerdtv_core::db::{Kind as CoreKind, Sort};
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

/// Which programmes a search lists (core `epg::When`): running, still to come, or ended.
pub enum ProgrammeWhen {
    Live,
    Upcoming,
    Earlier,
}

pub enum SourceKind {
    Xtream,
    M3uUrl,
    M3uFile,
    /// No provider yet (setup skipped).
    None,
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
                core::SourceKind::None => SourceKind::None,
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

/// An app-wide setting (`<dir>/app.json`, not per profile), or None when never set.
#[flutter_rust_bridge::frb(sync)]
pub fn app_setting(dir: String, key: String) -> Result<Option<String>, String> {
    core::app_setting(&PathBuf::from(dir), &key).map_err(err)
}

#[flutter_rust_bridge::frb(sync)]
pub fn set_app_setting(dir: String, key: String, value: String) -> Result<(), String> {
    core::set_app_setting(&PathBuf::from(dir), &key, &value).map_err(err)
}

impl From<ProfileInfo> for core::Profile {
    fn from(profile: ProfileInfo) -> Self {
        core::Profile {
            id: profile.id,
            name: profile.name,
            source: match profile.source {
                SourceKind::Xtream => core::SourceKind::Xtream,
                SourceKind::M3uUrl => core::SourceKind::M3uUrl,
                SourceKind::M3uFile => core::SourceKind::M3uFile,
                SourceKind::None => core::SourceKind::None,
            },
            server: profile.server,
            user_agent: profile.user_agent,
            max_connections: profile.max_connections,
            updated_at: 0,
        }
    }
}

/// Adds (empty id) or replaces a profile; returns it with its id.
pub fn save_profile(dir: String, profile: ProfileInfo) -> Result<ProfileInfo, String> {
    Ok(core::save_profile(&PathBuf::from(dir), profile.into())
        .map_err(err)?
        .into())
}

/// Tests a login without storing anything (Settings → Streaming → Edit saves only a working one).
pub async fn check_login(profile: ProfileInfo, secrets: Vec<String>) -> Result<(), String> {
    core::check_login(&profile.into(), &secrets)
        .await
        .map_err(err)
}

pub fn delete_profile(dir: String, id: String) -> Result<(), String> {
    core::delete_profile(&PathBuf::from(dir), &id).map_err(err)
}

pub struct CategoryInfo {
    pub id: String,
    pub name: String,
    pub count: u32,
}

/// A movie's or series' page details (gerdtv_core::xtream::Details); empty strings and None where the panel has
/// nothing.
pub struct ItemDetails {
    pub plot: String,
    pub genre: String,
    pub cast: String,
    pub director: String,
    pub release: String,
    pub duration_secs: Option<u32>,
    pub rating: Option<f64>,
    pub backdrop: String,
    /// The trailer's YouTube video id, "" when there is none.
    pub trailer: String,
}

/// One recording; `state`: scheduled, recording, done, refused, failed or skipped.
pub struct RecordingInfo {
    pub id: i64,
    pub item_key: String,
    pub title: String,
    /// UTC seconds, lead and lag included.
    pub start: i64,
    pub stop: i64,
    pub state: String,
    /// A path, or (Android) the document's content URI.
    pub file: String,
    pub message: String,
    pub bytes: u64,
}

/// What a Simkl import took; `token` is set when it had to be refreshed (store it).
pub struct SimklImport {
    pub watched: u32,
    pub positions: u32,
    pub waiting: u32,
    pub token: Option<String>,
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
    /// The group's name; filled by search only.
    pub group: String,
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
            group: h.group,
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
    /// Per-kind totals over every section; only on the first page (offset 0).
    pub counts: Vec<KindCount>,
    /// Groups whose name matches; only on the first page of a whole-section search.
    pub groups: Vec<GroupHit>,
}

/// A group and whether the user hid it.
pub struct GroupVisibility {
    pub group: CategoryInfo,
    pub hidden: bool,
}

/// A started movie or episode with where it was left (seconds).
pub struct ResumeItem {
    pub item: ItemInfo,
    pub position: u32,
    pub duration: u32,
}

/// A group whose name matches a search (opens like a group in the browse list).
pub struct GroupHit {
    pub kind: ItemKind,
    pub id: String,
    pub name: String,
    pub count: u32,
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
    /// How many of the profile's channels show this source's programmes.
    pub matched: u32,
    pub offset_hours: i32,
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
            matched: g.matched,
            offset_hours: g.offset_hours as i32,
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

/// A live channel mapped to a guide channel by hand.
pub struct MappedChannel {
    pub id: String,
    pub name: String,
    pub guide: String,
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

    /// `sort`: the list's sort setting ("name_asc", "name_desc"; anything else is provider order).
    pub fn categories(&self, kind: ItemKind, sort: String) -> Result<Vec<CategoryInfo>, String> {
        Ok(self
            .0
            .categories(to_core(kind), Sort::parse(&sort))
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
        sort: String,
        limit: u32,
        offset: u32,
    ) -> Result<Vec<ItemInfo>, String> {
        Ok(self
            .0
            .items(
                to_core(kind),
                &category,
                Sort::parse(&sort),
                limit as usize,
                offset as usize,
            )
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

    /// Simkl's watched marks and paused positions since the last import (at most every 30 min unless `force`).
    /// `token`: the stored JSON. None: not due or nothing changed.
    pub async fn simkl_import(
        &self,
        client_id: String,
        token: String,
        force: bool,
    ) -> Result<Option<SimklImport>, String> {
        let c = gerdtv_core::tracking::Client {
            service: gerdtv_core::tracking::Service::Simkl,
            base: gerdtv_core::tracking::Service::Simkl.base().to_string(),
            client_id,
            client_secret: String::new(),
        };
        let mut t = gerdtv_core::tracking::Token::from_json(&token)
            .ok_or("the stored token can't be read: link again")?;
        let fresh = gerdtv_core::tracking::refresh(&c, &t).await.map_err(err)?;
        if let Some(n) = &fresh {
            t = n.clone();
        }
        Ok(self
            .0
            .simkl_import(&c, &t, force)
            .await
            .map_err(err)?
            .map(|n| SimklImport {
                watched: n.watched as u32,
                positions: n.positions as u32,
                waiting: n.waiting as u32,
                token: fresh.map(|f| f.to_json()),
            }))
    }

    /// OpenSubtitles' search for an item (not for the app: api::subtitles calls it).
    #[flutter_rust_bridge::frb(ignore)]
    pub(crate) fn search_for_subtitles(
        &self,
        key: &str,
        languages: &str,
    ) -> Result<Option<gerdtv_core::opensubtitles::Search>, String> {
        self.0.subtitle_search(key, languages).map_err(err)
    }

    /// Plans a recording of a channel (UTC seconds, lead and lag included); its id.
    #[flutter_rust_bridge::frb(sync)]
    pub fn schedule_recording(
        &self,
        item_key: String,
        title: String,
        start: i64,
        stop: i64,
    ) -> Result<i64, String> {
        self.0
            .schedule_recording(&item_key, &title, start, stop)
            .map_err(err)
    }

    /// Every recording, newest first, a running one with its size so far.
    #[flutter_rust_bridge::frb(sync)]
    pub fn recordings(&self) -> Result<Vec<RecordingInfo>, String> {
        Ok(self
            .0
            .recordings()
            .map_err(err)?
            .into_iter()
            .map(|r| RecordingInfo {
                id: r.id,
                item_key: r.item_key,
                title: r.title,
                start: r.start,
                stop: r.stop,
                state: r.state,
                file: r.file,
                message: r.message,
                bytes: r.bytes,
            })
            .collect())
    }

    /// Starts a recording into a new file at `path` (desktop). Async: the recording's task needs the bridge's tokio
    /// runtime (a sync call has none, and spawning there aborted the app).
    pub async fn start_recording_path(&self, id: i64, path: String) -> Result<(), String> {
        let file = std::fs::File::create(&path).map_err(err)?;
        self.0.start_recording(id, file, &path).map_err(err)
    }

    /// Starts a recording into an open file descriptor from the system's folder picker (Android); this takes it over.
    /// `place`: the document's content URI, to play and delete it later.
    #[cfg(unix)]
    pub async fn start_recording_fd(&self, id: i64, fd: i32, place: String) -> Result<(), String> {
        use std::os::fd::FromRawFd;
        // SAFETY: Android's ParcelFileDescriptor.detachFd hands the descriptor over; nothing else closes it.
        let file = unsafe { std::fs::File::from_raw_fd(fd) };
        self.0.start_recording(id, file, &place).map_err(err)
    }

    /// Notes recordings that ended by themselves; how many still run.
    #[flutter_rust_bridge::frb(sync)]
    pub fn check_recordings(&self) -> Result<u32, String> {
        self.0.check_recordings().map(|n| n as u32).map_err(err)
    }

    /// Stops a running recording, or skips a planned one.
    pub async fn stop_recording(&self, id: i64) -> Result<(), String> {
        self.0.stop_recording(id).await.map_err(err)
    }

    /// Forgets a recording (the app deletes its file).
    pub async fn delete_recording(&self, id: i64) -> Result<(), String> {
        self.0.delete_recording(id).await.map_err(err)
    }

    /// What Trakt and Simkl get told for a movie or episode (None: nothing to track).
    pub fn track_item(&self, key: String) -> Result<Option<super::tracking::TrackItem>, String> {
        Ok(self
            .0
            .track_info(&key)
            .map_err(err)?
            .map(|t| super::tracking::TrackItem {
                movie: t.movie,
                name: t.name,
                year: t.year,
                show: t.show,
                season: t.season,
                number: t.number,
                tmdb: t.tmdb,
            }))
    }

    /// A movie's or series' details, from the panel when the page opens; with the user's TMDB key also from TMDB,
    /// for what the panel leaves empty.
    pub async fn details(
        &self,
        key: String,
        tmdb_key: Option<String>,
    ) -> Result<ItemDetails, String> {
        let tmdb = tmdb_key
            .filter(|k| !k.trim().is_empty())
            .map(|k| gerdtv_core::tmdb::Tmdb::new(gerdtv_core::tmdb::BASE, &k));
        let d = self.0.details(&key, tmdb.as_ref()).await.map_err(err)?;
        Ok(ItemDetails {
            plot: d.plot,
            genre: d.genre,
            cast: d.cast,
            director: d.director,
            release: d.release,
            duration_secs: d.duration_secs,
            rating: d.rating,
            backdrop: d.backdrop,
            trailer: d.trailer,
        })
    }

    /// Search as the user types: a section (`kinds`; empty = all kinds), or one group of it (`category`).
    pub fn search(
        &self,
        seq: u64,
        query: String,
        kinds: Vec<ItemKind>,
        category: Option<String>,
        limit: u32,
        offset: u32,
    ) -> Result<SearchPage, String> {
        let kinds: Vec<_> = kinds.into_iter().map(to_core).collect();
        let (hits, counts, groups) = self
            .0
            .search(
                &query,
                &kinds,
                category.as_deref(),
                limit as usize,
                offset as usize,
            )
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
            groups: groups
                .into_iter()
                .map(|g| GroupHit {
                    kind: from_core(g.kind),
                    id: g.id,
                    name: g.name,
                    count: g.count as u32,
                })
                .collect(),
        })
    }

    /// Remembers a search whose result the user opened; `section` is "live", "movies", "series" or "guide".
    #[flutter_rust_bridge::frb(sync)]
    pub fn record_search(&self, section: String, query: String) -> Result<(), String> {
        self.0.record_search(&section, &query).map_err(err)
    }

    /// Marks or unmarks a favourite (the star, a long press, a long OK).
    #[flutter_rust_bridge::frb(sync)]
    pub fn set_favourite(&self, key: String, favourite: bool) -> Result<(), String> {
        self.0.set_favourite(&key, favourite).map_err(err)
    }

    /// A section's favourites (`kinds`; empty = all) in the section's item `sort`: the Favourites group.
    pub fn favourites(&self, kinds: Vec<ItemKind>, sort: String) -> Result<Vec<ItemInfo>, String> {
        let kinds: Vec<_> = kinds.into_iter().map(to_core).collect();
        Ok(self
            .0
            .favourites(&kinds, Sort::parse(&sort))
            .map_err(err)?
            .into_iter()
            .map(Into::into)
            .collect())
    }

    /// How far a movie or episode played (seconds); kept from 2 min, dropped from 95 % (continue watching).
    #[flutter_rust_bridge::frb(sync)]
    pub fn save_progress(&self, key: String, position: u32, duration: u32) -> Result<(), String> {
        self.0.save_progress(&key, position, duration).map_err(err)
    }

    /// A new group of the user's own; its category id.
    pub fn create_group(&self, kind: ItemKind, name: String) -> Result<String, String> {
        self.0.create_group(to_core(kind), &name).map_err(err)
    }

    pub fn delete_group(&self, category: String) -> Result<(), String> {
        self.0.delete_group(&category).map_err(err)
    }

    /// Names a group; empty: the provider's name again, from the next sync.
    pub fn rename_group(
        &self,
        kind: ItemKind,
        category: String,
        name: String,
    ) -> Result<(), String> {
        self.0
            .rename_group(to_core(kind), &category, &name)
            .map_err(err)
    }

    /// Names an item; empty: the provider's name again.
    pub fn rename_item(&self, key: String, name: String) -> Result<(), String> {
        self.0.rename_item(&key, &name).map_err(err)
    }

    /// The groups' order, top to bottom.
    pub fn set_group_order(&self, kind: ItemKind, ids: Vec<String>) -> Result<(), String> {
        self.0.set_group_order(to_core(kind), &ids).map_err(err)
    }

    /// Adds an item to a group of the user's own, or removes it.
    pub fn set_group_member(
        &self,
        category: String,
        key: String,
        member: bool,
    ) -> Result<(), String> {
        self.0
            .set_group_member(&category, &key, member)
            .map_err(err)
    }

    /// The order of an own group's items.
    pub fn set_item_order(&self, category: String, keys: Vec<String>) -> Result<(), String> {
        self.0.set_item_order(&category, &keys).map_err(err)
    }

    /// Marks a movie or episode as watched or not.
    #[flutter_rust_bridge::frb(sync)]
    pub fn set_watched(&self, key: String, watched: bool) -> Result<(), String> {
        self.0.set_watched(&key, watched).map_err(err)
    }

    /// Every watched movie's and episode's key, for the lists' check marks.
    #[flutter_rust_bridge::frb(sync)]
    pub fn watched_keys(&self) -> Result<Vec<String>, String> {
        self.0.watched_keys().map_err(err)
    }

    /// The episode after this one in its series; None after the last.
    pub async fn next_episode(&self, key: String) -> Result<Option<ItemInfo>, String> {
        Ok(self
            .0
            .next_episode(&key)
            .await
            .map_err(err)?
            .map(Into::into))
    }

    /// Where to resume an item (seconds), if it was left part-way.
    #[flutter_rust_bridge::frb(sync)]
    pub fn resume_position(&self, key: String) -> Result<Option<u32>, String> {
        self.0.resume_position(&key).map_err(err)
    }

    /// The continue-watching row of a section: started, unfinished items, last watched first.
    pub fn continue_watching(
        &self,
        kinds: Vec<ItemKind>,
        limit: u32,
    ) -> Result<Vec<ResumeItem>, String> {
        let kinds: Vec<_> = kinds.into_iter().map(to_core).collect();
        Ok(self
            .0
            .continue_watching(&kinds, limit as usize)
            .map_err(err)?
            .into_iter()
            .map(|(h, position, duration)| ResumeItem {
                item: h.into(),
                position,
                duration,
            })
            .collect())
    }

    /// The live channels played last, newest first (the Android TV home screen).
    pub fn recent_channels(&self, limit: u32) -> Result<Vec<ItemInfo>, String> {
        Ok(self
            .0
            .recent_channels(limit as usize)
            .map_err(err)?
            .into_iter()
            .map(Into::into)
            .collect())
    }

    /// Something started playing: search ranks recently watched items first.
    #[flutter_rust_bridge::frb(sync)]
    pub fn touch_recent(&self, key: String) -> Result<(), String> {
        self.0.touch_recent(&key).map_err(err)
    }

    /// Every non-empty group of a kind with whether the user hid it (Settings → Hidden groups).
    pub fn all_groups(&self, kind: ItemKind) -> Result<Vec<GroupVisibility>, String> {
        Ok(self
            .0
            .all_categories(to_core(kind), Sort::Provider)
            .map_err(err)?
            .into_iter()
            .map(|(c, hidden)| GroupVisibility {
                group: CategoryInfo {
                    id: c.id,
                    name: c.name,
                    count: c.count as u32,
                },
                hidden,
            })
            .collect())
    }

    /// Hides a group everywhere (lists, search, the guide, favourites, continue watching) or shows it again.
    #[flutter_rust_bridge::frb(sync)]
    pub fn set_group_hidden(
        &self,
        kind: ItemKind,
        category: String,
        hidden: bool,
    ) -> Result<(), String> {
        self.0
            .set_group_hidden(to_core(kind), &category, hidden)
            .map_err(err)
    }

    /// Every favourite's key, for the stars in the lists.
    #[flutter_rust_bridge::frb(sync)]
    pub fn favourite_keys(&self) -> Result<Vec<String>, String> {
        self.0.favourite_keys().map_err(err)
    }

    /// The section's newest searches, newest first (the field's suggestions while empty).
    #[flutter_rust_bridge::frb(sync)]
    pub fn recent_searches(&self, section: String, limit: u32) -> Result<Vec<String>, String> {
        self.0
            .recent_searches(&section, limit as usize)
            .map_err(err)
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

    /// The newest stream_health rows (Settings → Playback → Stream health).
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

    /// Apple platforms, live channels: reads the channel's TS into a local HLS for AVPlayer (gerdtv_core::hls) with
    /// `window_secs` of timeshift, at most `max_bytes` on disk under `cache_dir`; returns once the playlist has its
    /// first segments. Fails (with the message to show) when the provider sends HLS already, refuses the stream,
    /// sends nothing for 20 s, or the cache folder can't be written.
    pub async fn start_local_hls(
        &self,
        key: String,
        cache_dir: String,
        window_secs: u32,
        max_bytes: u64,
    ) -> Result<crate::api::hls::LocalHlsStream, String> {
        use gerdtv_core::hls;
        use std::sync::atomic::{AtomicU64, Ordering};
        static STARTS: AtomicU64 = AtomicU64::new(0);
        let url = self.0.stream_url(&key, "ts").map_err(err)?;
        if url.split('?').next().unwrap_or("").ends_with(".m3u8") {
            return Err("The provider sends this channel as HLS already.".into());
        }
        let cache = PathBuf::from(cache_dir);
        let n = STARTS.fetch_add(1, Ordering::SeqCst);
        if n == 0 {
            hls::sweep(&cache); // segments a crash or kill left behind
        }
        let stream = hls::LocalHls::start(
            url,
            &self.0.profile().user_agent,
            hls::stream_dir(&cache, n),
            window_secs as f64,
            max_bytes,
        )
        .await
        .map_err(|e| e.to_string())?;
        // Only a playlist with segments: AVPlayer gives up on an empty one ("Playback Stopped").
        stream.ready().await.map_err(|e| e.to_string())?;
        Ok(crate::api::hls::LocalHlsStream(std::sync::Mutex::new(
            stream,
        )))
    }

    /// Casts a channel, movie or episode to `device` (gerdtv_core::cast): the provider's address first; live TV that
    /// the device doesn't play then goes through gerdTV's own HLS on this device's network address.
    pub async fn cast_start(
        &self,
        device: crate::api::cast::CastDeviceInfo,
        key: String,
        title: String,
        cache_dir: String,
    ) -> Result<crate::api::cast::CastHandle, String> {
        let casting = self
            .0
            .cast_start(&device.device()?, &key, &title, &PathBuf::from(cache_dir))
            .await
            .map_err(err)?;
        Ok(crate::api::cast::CastHandle(casting))
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

    /// An extra source's own time offset in hours (applied by the next refresh).
    pub fn set_guide_offset(&self, id: i64, hours: i32) -> Result<(), String> {
        self.0.set_guide_offset(id, hours as i64).map_err(err)
    }

    pub fn remove_guide_source(&self, id: i64) -> Result<(), String> {
        self.0.remove_guide_source(id).map_err(err)
    }

    /// Downloads and imports every source, keeping `days_ahead` days (7 desktop, 3 phone and TV) and 2 back.
    pub async fn refresh_guide(
        &self,
        days_ahead: u32,
        force: bool,
    ) -> Result<Vec<GuideSourceInfo>, String> {
        Ok(self
            .0
            .refresh_guide(days_ahead as i64, force)
            .await
            .map_err(err)?
            .into_iter()
            .map(Into::into)
            .collect())
    }

    /// Seconds since the oldest successful import (None: never); the app refreshes when it is over 12 h.
    pub fn guide_due(&self) -> Result<bool, String> {
        self.0.guide_due().map_err(err)
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

    /// Programmes whose title, sub-title, description or channel name match, title hits first: running or upcoming
    /// soonest first, or the ended ones most recent first; `category` limits them to one group's channels.
    pub fn search_programmes(
        &self,
        query: String,
        limit: u32,
        when: ProgrammeWhen,
        category: Option<String>,
    ) -> Result<Vec<ProgrammeHit>, String> {
        let when = match when {
            ProgrammeWhen::Live => gerdtv_core::epg::When::Live,
            ProgrammeWhen::Upcoming => gerdtv_core::epg::When::Upcoming,
            ProgrammeWhen::Earlier => gerdtv_core::epg::When::Earlier,
        };
        Ok(self
            .0
            .search_programmes(&query, limit as usize, when, category.as_deref())
            .map_err(err)?
            .into_iter()
            .map(|(p, hit)| ProgrammeHit {
                programme: p.into(),
                item: hit.into(),
            })
            .collect())
    }

    /// Live channels without a guide match, in provider order (the mapping screen); an empty query lists all,
    /// otherwise those whose name contains it.
    pub fn unmatched_channels(
        &self,
        limit: u32,
        offset: u32,
        query: String,
    ) -> Result<Vec<ChannelRef>, String> {
        Ok(refs(
            self.0
                .unmatched_channels(limit as usize, offset as usize, &query)
                .map_err(err)?,
        ))
    }

    /// Guide channels an unmatched channel may be, best first.
    pub fn suggest_guide_channels(
        &self,
        item_key: String,
        limit: u32,
    ) -> Result<Vec<ChannelRef>, String> {
        Ok(refs(
            self.0
                .suggest_guide_channels(&item_key, limit as usize)
                .map_err(err)?,
        ))
    }

    /// The channels mapped by hand, with their guide channel's name.
    pub fn mapped_channels(&self) -> Result<Vec<MappedChannel>, String> {
        let rows = self.0.mapped_channels().map_err(err)?;
        Ok(rows
            .into_iter()
            .map(|(id, name, guide)| MappedChannel { id, name, guide })
            .collect())
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

    /// One item by its key (a reminder's channel); None when it is gone from the catalogue.
    pub fn item(&self, key: String) -> Result<Option<ItemInfo>, String> {
        Ok(self.0.item(&key).map_err(err)?.map(Into::into))
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
    /// The profile's user data as JSON, for a file the user keeps (no secrets).
    pub fn export_user_data(&self) -> Result<String, String> {
        self.0.export_user_data().map_err(err)
    }

    /// Merges an exported file; returns how many entries were new or newer. The error says why a file is refused.
    pub fn import_user_data(&self, json: String) -> Result<usize, String> {
        let n = self.0.import_user_data(&json).map_err(|e| e.to_string())?;
        Ok(n.favourites
            + n.recents
            + n.guide_map
            + n.reminders
            + n.settings
            + n.channel_buffers
            + n.guide_urls
            + n.resume
            + n.hidden_groups
            + n.search_history
            + n.watched
            + n.own_groups
            + n.own_names)
    }

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
