//! Export and import of a profile's user data (Settings → Your data): favourites, recents, manual guide mapping,
//! reminders, profile settings, per-channel buffer choices and extra guide URLs, as one JSON file. No secrets (guide
//! URLs keep their `{secret0}` placeholders) and no catalogue or guide: a sync brings those back.
//! Import merges row by row: a row is taken when it is new or its `updated_at` is newer than ours, nothing is
//! deleted. That is the rule a later home hub would sync by (docs/DATA_MODEL.md).
//! Debugging: a refused file says why ("not a gerdTV user data file", "made by a newer gerdTV"); the counts tell
//! how many rows were taken per table.

use rusqlite::{Connection, params};
use serde::{Deserialize, Serialize};

/// The file's marker and format version (raise `VERSION` only for changes an older gerdTV can't read).
const FORMAT: &str = "gerdtv-user-data";
const VERSION: u32 = 1;

/// Settings the app derives from the provider on every sync; not user choices, so not exported.
const DERIVED_SETTINGS: &[&str] = &["xc_time_offset", "m3u_tvg_url"];

#[derive(Debug, Serialize, Deserialize)]
struct File {
    format: String,
    version: u32,
    #[serde(default)]
    favourites: Vec<Keyed>,
    #[serde(default)]
    recents: Vec<Keyed>,
    #[serde(default)]
    guide_map: Vec<GuideMap>,
    #[serde(default)]
    reminders: Vec<Reminder>,
    #[serde(default)]
    settings: Vec<Setting>,
    #[serde(default)]
    channel_buffers: Vec<ChannelBuffer>,
    #[serde(default)]
    guide_urls: Vec<GuideUrl>,
}

#[derive(Debug, Serialize, Deserialize)]
struct Keyed {
    key: String,
    updated_at: i64,
}

#[derive(Debug, Serialize, Deserialize)]
struct GuideMap {
    item_key: String,
    channel: String,
    updated_at: i64,
}

#[derive(Debug, Serialize, Deserialize)]
struct Reminder {
    item_key: String,
    start: i64,
    stop: i64,
    title: String,
    updated_at: i64,
}

#[derive(Debug, Serialize, Deserialize)]
struct Setting {
    key: String,
    value: String,
    updated_at: i64,
}

#[derive(Debug, Serialize, Deserialize)]
struct ChannelBuffer {
    key: String,
    buffer: String,
    updated_at: i64,
}

#[derive(Debug, Serialize, Deserialize)]
struct GuideUrl {
    url: String,
    updated_at: i64,
}

/// How many rows an import took (new or newer), in file order.
#[derive(Debug, Default, Clone, PartialEq)]
pub struct ImportCounts {
    pub favourites: usize,
    pub recents: usize,
    pub guide_map: usize,
    pub reminders: usize,
    pub settings: usize,
    pub channel_buffers: usize,
    pub guide_urls: usize,
}

#[derive(Debug, thiserror::Error)]
pub enum UserDataError {
    #[error("not a gerdTV user data file")]
    NotOurs,
    #[error("made by a newer gerdTV (format {0}); update this app first")]
    Newer(u32),
    #[error(transparent)]
    Db(#[from] rusqlite::Error),
}

fn rows<T>(
    conn: &Connection,
    sql: &str,
    map: impl FnMut(&rusqlite::Row) -> rusqlite::Result<T>,
) -> rusqlite::Result<Vec<T>> {
    conn.prepare(sql)?.query_map([], map)?.collect()
}

/// The profile's user data as pretty-printed JSON.
pub fn export(conn: &Connection) -> rusqlite::Result<String> {
    let keyed = |r: &rusqlite::Row| {
        Ok(Keyed {
            key: r.get(0)?,
            updated_at: r.get(1)?,
        })
    };
    let file = File {
        format: FORMAT.into(),
        version: VERSION,
        favourites: rows(
            conn,
            "SELECT key, updated_at FROM favourites ORDER BY key",
            keyed,
        )?,
        recents: rows(
            conn,
            "SELECT key, updated_at FROM recents ORDER BY key",
            keyed,
        )?,
        guide_map: rows(
            conn,
            "SELECT item_key, channel, updated_at FROM epg_map ORDER BY item_key",
            |r| {
                Ok(GuideMap {
                    item_key: r.get(0)?,
                    channel: r.get(1)?,
                    updated_at: r.get(2)?,
                })
            },
        )?,
        reminders: rows(
            conn,
            "SELECT item_key, start, stop, title, updated_at FROM reminders ORDER BY start, item_key",
            |r| {
                Ok(Reminder {
                    item_key: r.get(0)?,
                    start: r.get(1)?,
                    stop: r.get(2)?,
                    title: r.get(3)?,
                    updated_at: r.get(4)?,
                })
            },
        )?,
        settings: rows(
            conn,
            "SELECT key, value, updated_at FROM settings ORDER BY key",
            |r| {
                Ok(Setting {
                    key: r.get(0)?,
                    value: r.get(1)?,
                    updated_at: r.get(2)?,
                })
            },
        )?
        .into_iter()
        .filter(|s| !DERIVED_SETTINGS.contains(&s.key.as_str()))
        .collect(),
        channel_buffers: rows(
            conn,
            "SELECT key, buffer, updated_at FROM stream_prefs WHERE buffer != '' ORDER BY key",
            |r| {
                Ok(ChannelBuffer {
                    key: r.get(0)?,
                    buffer: r.get(1)?,
                    updated_at: r.get(2)?,
                })
            },
        )?,
        guide_urls: rows(
            conn,
            "SELECT url, updated_at FROM epg_sources WHERE builtin = 0 ORDER BY url",
            |r| {
                Ok(GuideUrl {
                    url: r.get(0)?,
                    updated_at: r.get(1)?,
                })
            },
        )?,
    };
    Ok(serde_json::to_string_pretty(&file).expect("plain data serialises"))
}

/// Merges `json` into the profile (one transaction: a broken file changes nothing).
pub fn import(conn: &mut Connection, json: &str) -> Result<ImportCounts, UserDataError> {
    let file: File = serde_json::from_str(json).map_err(|_| UserDataError::NotOurs)?;
    if file.format != FORMAT {
        return Err(UserDataError::NotOurs);
    }
    if file.version > VERSION {
        return Err(UserDataError::Newer(file.version));
    }
    let tx = conn.transaction()?;
    let mut n = ImportCounts::default();
    // Each upsert only overwrites an older row (the WHERE on DO UPDATE); `execute` returns 0 when nothing changed.
    for f in &file.favourites {
        n.favourites += tx.execute(
            "INSERT INTO favourites (key, updated_at) VALUES (?1, ?2)
             ON CONFLICT (key) DO UPDATE SET updated_at = ?2 WHERE ?2 > updated_at",
            params![f.key, f.updated_at],
        )?;
    }
    for r in &file.recents {
        n.recents += tx.execute(
            "INSERT INTO recents (key, updated_at) VALUES (?1, ?2)
             ON CONFLICT (key) DO UPDATE SET updated_at = ?2 WHERE ?2 > updated_at",
            params![r.key, r.updated_at],
        )?;
    }
    for m in &file.guide_map {
        n.guide_map += tx.execute(
            "INSERT INTO epg_map (item_key, channel, updated_at) VALUES (?1, ?2, ?3)
             ON CONFLICT (item_key) DO UPDATE SET channel = ?2, updated_at = ?3 WHERE ?3 > updated_at",
            params![m.item_key, m.channel, m.updated_at],
        )?;
    }
    for r in &file.reminders {
        n.reminders += tx.execute(
            "INSERT INTO reminders (item_key, start, stop, title, updated_at) VALUES (?1, ?2, ?3, ?4, ?5)
             ON CONFLICT (item_key, start) DO UPDATE SET stop = ?3, title = ?4, updated_at = ?5
             WHERE ?5 > updated_at",
            params![r.item_key, r.start, r.stop, r.title, r.updated_at],
        )?;
    }
    for s in file
        .settings
        .iter()
        .filter(|s| !DERIVED_SETTINGS.contains(&s.key.as_str()))
    {
        n.settings += tx.execute(
            "INSERT INTO settings (key, value, updated_at) VALUES (?1, ?2, ?3)
             ON CONFLICT (key) DO UPDATE SET value = ?2, updated_at = ?3 WHERE ?3 > updated_at",
            params![s.key, s.value, s.updated_at],
        )?;
    }
    for b in &file.channel_buffers {
        // A new row starts on the TS form (the watchdog learns HLS again if needed).
        n.channel_buffers += tx.execute(
            "INSERT INTO stream_prefs (key, prefer_hls, buffer, updated_at) VALUES (?1, 0, ?2, ?3)
             ON CONFLICT (key) DO UPDATE SET buffer = ?2, updated_at = ?3 WHERE ?3 > updated_at",
            params![b.key, b.buffer, b.updated_at],
        )?;
    }
    for g in &file.guide_urls {
        // Same URL = same source; the next guide refresh imports a new one.
        n.guide_urls += tx.execute(
            "INSERT INTO epg_sources (url, builtin, updated_at) VALUES (?1, 0, ?2) ON CONFLICT (url) DO NOTHING",
            params![g.url, g.updated_at],
        )?;
    }
    tx.commit()?;
    Ok(n)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn db() -> Connection {
        crate::db::open(std::path::Path::new(":memory:")).unwrap()
    }

    fn seed(c: &Connection) {
        c.execute_batch(
            "INSERT INTO favourites VALUES ('live:1', 100), ('movie:7', 100);
             INSERT INTO recents VALUES ('live:1', 150);
             INSERT INTO epg_map VALUES ('live:2', 'Das Erste.de', 120);
             INSERT INTO reminders VALUES ('live:1', 5000, 8600, 'News', 130);
             INSERT INTO settings VALUES ('buffer_preset', 'smooth', 140), ('xc_time_offset', '3600', 140);
             INSERT INTO stream_prefs (key, prefer_hls, buffer, updated_at) VALUES ('live:1', 1, 'max', 160),
                ('live:3', 1, '', 160);
             INSERT INTO epg_sources (url, builtin, updated_at) VALUES ('http://example.invalid/a.xml', 0, 110),
                ('builtin', 1, 110);",
        )
        .unwrap();
    }

    /// Everything user-chosen goes out; derived settings, the built-in guide and channels without own buffer don't.
    #[test]
    fn export_then_import_into_an_empty_profile_restores_it() {
        let a = db();
        seed(&a);
        let json = export(&a).unwrap();
        assert!(
            !json.contains("xc_time_offset")
                && !json.contains("builtin")
                && !json.contains("live:3")
        );
        let mut b = db();
        let n = import(&mut b, &json).unwrap();
        let want = ImportCounts {
            favourites: 2,
            recents: 1,
            guide_map: 1,
            reminders: 1,
            settings: 1,
            channel_buffers: 1,
            guide_urls: 1,
        };
        assert_eq!(n, want);
        assert_eq!(export(&b).unwrap(), json, "a round trip is lossless");
        // Importing the same file again takes nothing.
        assert_eq!(import(&mut b, &json).unwrap(), ImportCounts::default());
    }

    /// Row by row the newer `updated_at` wins; rows only one side has are kept (nothing is deleted).
    #[test]
    fn import_merges_by_updated_at() {
        let mut ours = db();
        ours.execute_batch(
            "INSERT INTO settings VALUES ('buffer_preset', 'fast', 200), ('timeshift_secs', '600', 50);
             INSERT INTO favourites VALUES ('live:9', 10);",
        )
        .unwrap();
        let theirs = db();
        seed(&theirs);
        theirs
            .execute(
                "INSERT INTO settings VALUES ('timeshift_secs', '1800', 60)",
                [],
            )
            .unwrap();
        let n = import(&mut ours, &export(&theirs).unwrap()).unwrap();
        assert_eq!(n.settings, 1, "only timeshift_secs is newer there");
        let get = |k: &str| -> String {
            ours.query_row("SELECT value FROM settings WHERE key = ?1", [k], |r| {
                r.get(0)
            })
            .unwrap()
        };
        assert_eq!(get("buffer_preset"), "fast", "ours is newer");
        assert_eq!(get("timeshift_secs"), "1800", "theirs is newer");
        let favs: i64 = ours
            .query_row("SELECT count(*) FROM favourites", [], |r| r.get(0))
            .unwrap();
        assert_eq!(favs, 3, "ours stays, theirs added");
    }

    /// Foreign or future files are refused before anything is written.
    #[test]
    fn refuses_foreign_and_newer_files() {
        let mut c = db();
        for (json, want) in [
            ("not json", "not a gerdTV user data file"),
            (
                r#"{"format":"other","version":1}"#,
                "not a gerdTV user data file",
            ),
            (
                r#"{"format":"gerdtv-user-data","version":2}"#,
                "made by a newer gerdTV (format 2)",
            ),
        ] {
            let err = import(&mut c, json).unwrap_err().to_string();
            assert!(err.starts_with(want), "{json}: {err}");
        }
    }
}
