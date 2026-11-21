# Data model

Profiles: their non-secret settings (name, source kind, server or file, EPG URLs, user agent, EPG offset, connection limit, `updated_at`) in `profiles.json` in the app-support folder, rewritten atomically. Secrets (Xtream Codes login, an M3U URL with credentials) stay in the platform's secure storage.

One SQLite database per profile (`profiles/<id>.db`) (FTS5, WAL mode) in the platform's app-support folder; images in the cache folder. Schema and queries: `crates/gerdtv-core/src/db.rs`.

## Tables
| Table | What | Key |
|---|---|---|
| `meta` | schema version and similar settings | `key` |
| `categories` | provider groups in provider order (`kind`, provider id or M3U group name, name, position) | `kind, id` |
| `items` | the catalogue: live channels, movies, episodes (M3U), series (Xtream Codes); name, category, logo, EPG id, channel number, credential-free URL (M3U only), season/episode/year, provider position, sync generation | `key` |
| `items_fts` | contentless FTS5 index over `name` and `alt` (the cleaned name plus tvg-name), `unicode61 remove_diacritics 2`; rowids match `items` | rowid |
| `favourites`, `recents` | user data: item key + `updated_at` | `key` |

Item kinds are stored as numbers: 0 live, 1 movie, 2 episode, 3 series (never renumbered).

## Keys
- Xtream Codes: `live:<stream_id>`, `movie:<stream_id>`, `series:<series_id>`.
- M3U: the same forms when the URL has the Xtream Codes path (`…/live/<user>/<pass>/<id>.ts`), otherwise `url:<FNV-1a 64 of the credential-free URL>`.
- User data refers to items only by key, so a re-sync never orphans favourites or recents (sync-ready for a later hub).

## No credentials on disk
M3U stream URLs are stored with the profile's secrets replaced by `{secret0}`, `{secret1}` …; the player gets the real URL at play time. Xtream Codes URLs are not stored at all; they are built from the profile's credentials when playing.

## Sync
- One transaction per sync (diff + upsert by key; WAL readers see the old catalogue until it commits; any error rolls back).
- Rows not seen in a sync are removed, except: when a source list comes back empty while the catalogue has rows of that kind, those rows are kept (panels answer `[]` now and then under load).

## Migrations
Forward-only, tested on a fixture database, and preceded by a copy of the database to `*.bak-<timestamp>`. Schema version 1 has none yet.
