# Data model

No database yet (Phase 1 adds it). The fixed rules it will follow:
- One SQLite database (FTS5) per profile in the platform's app-support folder; images in the cache folder.
- User data (favourites, resume positions, watched marks, hidden groups, settings, recording rules) is keyed by stable content keys (provider + stream id, or TMDB id) and carries `updated_at`, so a later hub can sync it.
- Migrations are forward-only, tested on a fixture database, and preceded by a copy of the database to `*.bak-<timestamp>`.
