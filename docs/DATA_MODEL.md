# Data model

App-wide settings (`app_logo`, `theme_mode`, `theme_accent`, `theme_tinted`, `theme_black`) in `app.json` in the app-support folder, a flat string map rewritten atomically (`app_setting` in `crates/gerdtv-core/src/library.rs`).

Profiles: their non-secret settings (name, source kind, server or file, user agent, connection limit, `updated_at`) in `profiles.json` in the app-support folder, rewritten atomically. Secrets (Xtream Codes login, an M3U URL with credentials) stay in the platform's secure storage.

One SQLite database per profile (`profiles/<id>.db`) (FTS5, WAL mode) in the platform's app-support folder; logos and posters in the cache folder (`logos/`, one file per URL named by its FNV-1a hash, `crates/gerdtv-core/src/logos.rs`). Schema and queries: `crates/gerdtv-core/src/db.rs`.

## Tables
| Table | What | Key |
|---|---|---|
| `meta` | schema version and similar settings | `key` |
| `categories` | provider groups in provider order (`kind`, provider id or M3U group name, name, position) | `kind, id` |
| `items` | the catalogue: live channels, movies, episodes, series; name, category (for Xtream Codes episodes: their series key), logo, EPG id, channel number, credential-free URL (M3U only), season/episode/year, date added and rating (Xtream Codes movies and series; NULL otherwise), container extension (Xtream Codes movies/episodes), catch-up days (live channels; 0 = none), provider position, sync generation | `key` |
| `items_fts`, `items_vocab` | search: contentless FTS5 index over `name` and `alt` (the cleaned name plus tvg-name), `unicode61 remove_diacritics 2`, rowids match `items`; its vocabulary for typo matching. `items.folded` holds `alt` lower-case without accents for mid-word matches (a scan, no extra index: every index costs at each sync) | rowid |
| `search_history` | user data: a section's searches whose result was opened (section, query, `updated_at`); the newest 20 per section are kept | `section, query` |
| `favourites`, `recents` | user data: item key + `updated_at` (recents: written whenever something starts playing) | `key` |
| `hidden_groups` | user data: groups the user hid (kind, provider category id, `updated_at`); an Xtream Codes episode is hidden with its series' group | `kind, category` |
| `resume` | user data: where a movie or episode was left (position and duration in seconds, `updated_at`); kept from 2 min, removed from 95 % | `key` |
| `watched` | user data: movies and episodes marked as watched (from 95 %, or by hand) or unmarked again, `updated_at` | `key` |
| `custom_groups`, `custom_group_items` | user data: the user's own groups (category id `custom:<id>`) and their items in order; removed ones stay as `deleted`, `updated_at` | `id` / `group_id, item_key` |
| `group_prefs`, `item_prefs` | user data: own names of groups and items and the groups' order, written over `categories` and `items` after each sync; `item_prefs` keeps the provider's name for the guide, `updated_at` | `kind, category` / `key` |
| `waiting_watched` | episodes Simkl knows as watched whose Xtream Codes series hasn't been opened yet (series key, season, episode, `updated_at`); applied and removed when its episodes arrive | `series, season, episode` |
| `tmdb` | cache: TMDB's answer per movie or series key (`{}` = no match), fetched time; kept 30 days, not exported | `key` |
| `stream_prefs` | per channel: whether the HLS form worked last (the watchdog's TS ↔ HLS switch), its own buffer preset (empty = the profile's), the last measured video bitrate, `updated_at` | `key` |
| `epg_channels`, `epg_names` | guide channels (id, first display name, icon, the highest-ranked source listing it, whether a file has programmes for it) and every display name normalised for matching, per channel | `id` / `norm, channel` |
| `programmes`, `programmes_fts` | guide programmes (channel, start/stop UTC, title, sub-title, description, category, episode, icon, source) with an FTS index over title, sub-title and description; kept 2 days back to 7 ahead | `id` |
| `epg_sources` | the provider's built-in guide (its URL is built when needed) and extra XMLTV URLs (credentials templated out), each with last import, status, counts, own time offset, the server's change markers and what the import depended on | `id` |
| `epg_map` | user data: an item mapped to a guide channel by hand, `updated_at` | `item_key` |
| `item_epg` | the resolved match per live item (rebuilt after every import and sync) | `item_key` |
| `reminders` | user data: a reminder for a guide programme (channel, start, stop, title), `updated_at` | `item_key, start` |
| `settings` | profile settings: `buffer_preset`, `adaptive_buffer`, `timeshift_secs`, `guide_offset_hours`, `xc_time_offset` (the Xtream Codes server's clock against UTC, from the last sync), `list_mode_live`, `list_mode_movie`, `list_mode_series`, `account_expires` and `account_limit` (Xtream Codes, from the last sync), `simkl_since` and `simkl_checked` (the last Simkl import), `picture:<item key>` (an item's picture format), `deinterlace`, `match_frame_rate`, `autoplay_next`, `audio_language`, `subtitle_language`, `subtitle_size`, `subtitle_background`, `m3u_tvg_url` (the playlist header's guide URL) (values as text), `updated_at` | `key` |
| `stream_health` | every recovery the watchdog made or gave up on: time, item key, trigger, attempts, recovered, seconds; the newest 2,000 kept | `id` |

Item kinds are stored as numbers: 0 live, 1 movie, 2 episode, 3 series (never renumbered).

## Keys
- Xtream Codes: `live:<stream_id>`, `movie:<stream_id>`, `series:<series_id>`.
- M3U: the same forms when the URL has the Xtream Codes path (`…/live/<user>/<pass>/<id>.ts`), otherwise `url:<FNV-1a 64 of the credential-free URL>`.
- User data refers to items only by key, so a re-sync never orphans favourites or recents (sync-ready for a later hub).

## Export and import
Settings → Account → Your data writes the open profile's user data as one JSON file (`crates/gerdtv-core/src/userdata.rs`, format `gerdtv-user-data`, version 1): favourites, recents, `resume`, `watched`, own groups, own names and order, `hidden_groups`, `search_history` (kept at the newest 20 per section after an import), `epg_map`, reminders, settings (without the derived `xc_time_offset`, `m3u_tvg_url`, `account_expires`, `account_limit`, `simkl_since` and `simkl_checked`), per-channel buffer choices and the extra guide URLs (with their `{secretN}` placeholders). Import merges row by row in one transaction: a row is taken when it is new or its `updated_at` is newer, nothing is deleted; a foreign file or a newer format is refused unchanged.

## No credentials on disk
M3U stream URLs are stored with the profile's secrets replaced by `{secret0}`, `{secret1}` …; the player gets the real URL at play time. Xtream Codes URLs are not stored at all; they are built from the profile's credentials when playing.

## Sync
- One transaction per sync (diff + upsert by key; WAL readers see the old catalogue until it commits; any error rolls back).
- Rows not seen in a sync are removed, except: when a source list comes back empty while the catalogue has rows of that kind, those rows are kept (panels answer `[]` now and then under load).

## Migrations
Forward-only (`MIGRATIONS` in `crates/gerdtv-core/src/db.rs`), tested on a fixture database, and preceded by a copy of the database to `*.db.bak-<timestamp>`. Each step and its version number are one transaction. Only a profile's newest copy is kept: older ones are deleted at the next start once the open database passes SQLite's `quick_check`; removing a profile deletes its copies too. Version 2 added `items.ext`; version 3 added `settings` and the buffer and bitrate columns of `stream_prefs`; version 4 added the guide tables; version 5 added `items.archive_days` and `reminders`; version 6 added `items.folded` (filled from the stored names; the next sync adds the tvg-names), the vocabulary view and `search_history`; version 7 added `resume`; version 8 added `hidden_groups`; version 9 added `items.added` and `items.rating` (the next sync fills them) and keyed `epg_names` by name and channel; version 10 gave guide sources their own offset and change markers; version 11 added `watched`, the user's own groups, the own names and order, the `tmdb` cache and `waiting_watched`.
- Xtream Codes episodes are fetched when a series opens and kept until the next full sync.
