//! Watched marks and paused positions from Simkl (tracking::simkl_changes) into the profile, by its rules: the
//! newer `updated_at` wins, nothing local is deleted (a removal at Simkl isn't mirrored), and a mark or position
//! older than the local one changes nothing.
//!
//! Matching: TMDB's id when the tmdb cache knows the item; else the cleaned title (tracking::clean_title, accents
//! folded) and, for movies, the year when both sides have one. Xtream Codes episodes exist only once their series
//! was opened: a mark for one that isn't there waits in `waiting_watched` and is applied when the series' episodes
//! arrive (Library::episodes). A paused position needs the item's length, which only a local `resume` row knows:
//! Simkl's playbacks give a percentage. Others are left out.
//! Debug hints: an imported film without its mark: compare `clean_title` of both names; the counts returned per call
//! say what matched.

use crate::db::fold;
use crate::tracking::{Changes, Watching, clean_title};
use rusqlite::{Connection, Result, params};
use std::collections::HashMap;

/// How many marks and positions an import took (new or newer), and how many wait for their series.
#[derive(Debug, Default, Clone, PartialEq)]
pub struct Imported {
    pub watched: usize,
    pub positions: usize,
    pub waiting: usize,
}

/// (folded title, year) → key, and TMDB id → key, for one kind.
struct Index {
    by_name: HashMap<String, Vec<(Option<u32>, String)>>,
    by_tmdb: HashMap<u64, String>,
}

impl Index {
    fn load(conn: &Connection, kind: i64) -> Result<Index> {
        let mut by_name: HashMap<String, Vec<(Option<u32>, String)>> = HashMap::new();
        let mut by_tmdb = HashMap::new();
        let mut st = conn.prepare(
            "SELECT i.key, i.name, i.year, (SELECT json_extract(t.data, '$.id') FROM tmdb t WHERE t.key = i.key)
             FROM items i WHERE i.kind = ?1 ORDER BY i.position",
        )?;
        let mut rows = st.query([kind])?;
        while let Some(r) = rows.next()? {
            let (key, name): (String, String) = (r.get(0)?, r.get(1)?);
            let (title, year) = clean_title(&name);
            let year = r.get::<_, Option<u32>>(2)?.or(year);
            if let Some(id) = r.get::<_, Option<i64>>(3)? {
                by_tmdb.entry(id as u64).or_insert_with(|| key.clone());
            }
            by_name.entry(fold(&title)).or_default().push((year, key));
        }
        Ok(Index { by_name, by_tmdb })
    }

    /// The item for a title, its year (when both know one) and TMDB id; the first in provider order.
    fn find(&self, title: &str, year: Option<u32>, tmdb: Option<u64>) -> Option<&str> {
        if let Some(k) = tmdb.and_then(|id| self.by_tmdb.get(&id)) {
            return Some(k);
        }
        let (title, _) = clean_title(title);
        let candidates = self.by_name.get(&fold(&title))?;
        candidates
            .iter()
            .find(|(y, _)| year.is_none() || y.is_none() || *y == year)
            .map(|(_, k)| k.as_str())
    }
}

fn mark(conn: &Connection, key: &str, at: i64) -> Result<usize> {
    conn.execute(
        "INSERT INTO watched (key, watched, updated_at) VALUES (?1, 1, ?2)
         ON CONFLICT (key) DO UPDATE SET watched = 1, updated_at = ?2 WHERE ?2 > updated_at",
        params![key, at],
    )
}

/// An episode's key in a series, if its row exists.
fn episode(conn: &Connection, series: &str, season: u32, number: u32) -> Result<Option<String>> {
    use rusqlite::OptionalExtension;
    conn.query_row(
        "SELECT key FROM items WHERE kind = 2 AND category = ?1 AND season = ?2 AND episode = ?3 ORDER BY position",
        params![series, season, number],
        |r| r.get(0),
    )
    .optional()
}

/// Where a mark goes: an item's row, or the waiting list (series key, season, episode).
enum Target {
    Item(String),
    Waiting(String, u32, u32),
}

/// Applies Simkl's changes in one transaction.
pub fn apply(conn: &mut Connection, changes: &Changes) -> Result<Imported> {
    let tx = conn.transaction()?;
    let movies = Index::load(&tx, 1)?;
    let series = Index::load(&tx, 3)?;
    let mut n = Imported::default();
    // An episode: its row, or (an Xtream Codes series not opened yet) its place in the waiting list.
    let target = |w: &Watching| -> Result<Option<Target>> {
        Ok(match w {
            Watching::Movie { title, year, tmdb } => movies
                .find(title, *year, *tmdb)
                .map(|k| Target::Item(k.to_string())),
            Watching::Episode {
                show,
                season,
                number,
                tmdb,
            } => match series.find(show, None, *tmdb) {
                None => None,
                Some(s) => Some(match episode(&tx, s, *season, *number)? {
                    Some(k) => Target::Item(k),
                    None => Target::Waiting(s.to_string(), *season, *number),
                }),
            },
        })
    };
    for seen in &changes.seen {
        match target(&seen.watching)? {
            Some(Target::Item(key)) => n.watched += mark(&tx, &key, seen.at)?,
            Some(Target::Waiting(s, season, number)) => {
                n.waiting += tx.execute(
                    "INSERT INTO waiting_watched (series, season, episode, updated_at) VALUES (?1, ?2, ?3, ?4)
                     ON CONFLICT DO UPDATE SET updated_at = ?4 WHERE ?4 > updated_at",
                    params![s, season, number, seen.at],
                )?
            }
            None => {}
        }
    }
    for p in &changes.paused {
        if let Some(Target::Item(key)) = target(&p.watching)? {
            // Only where the length is known; never past the 95 % that counts as finished.
            n.positions += tx.execute(
                "UPDATE resume SET position = CAST(duration * min(?2, 94.0) / 100 AS INTEGER), updated_at = ?3
                 WHERE key = ?1 AND duration > 0 AND ?3 > updated_at",
                params![key, p.percent, p.at],
            )?;
        }
    }
    tx.commit()?;
    Ok(n)
}

/// The marks waiting for `series`, now that its episodes are there.
pub fn apply_waiting(conn: &Connection, series: &str) -> Result<()> {
    let waiting: Vec<(u32, u32, i64)> = conn
        .prepare("SELECT season, episode, updated_at FROM waiting_watched WHERE series = ?1")?
        .query_map([series], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?
        .collect::<Result<_>>()?;
    for (season, number, at) in waiting {
        if let Some(key) = episode(conn, series, season, number)? {
            mark(conn, &key, at)?;
            conn.execute(
                "DELETE FROM waiting_watched WHERE series = ?1 AND season = ?2 AND episode = ?3",
                params![series, season, number],
            )?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use crate::library::{Library, SourceKind, save_profile};
    use crate::tracking::{Client, Service, Watching, simkl_history};
    use gerdtv_testkit::mock_tracking::{CLIENT_ID, MockTracking, SECRET};
    use gerdtv_testkit::mock_xc::{MockXc, PASS, USER};
    use serde_json::json;

    /// New, because nothing owns importing from Simkl: a film and an episode match by title, the episode of a series
    /// not opened yet waits for it, an unchanged activity time fetches nothing more, and the next import asks only for
    /// what is newer.
    #[tokio::test]
    async fn simkl_marks_reach_the_profile() {
        let xc = MockXc::start(600, 3).await;
        let dir = std::env::temp_dir().join(format!("gerdtv-simkl-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let profile = crate::library::Profile {
            id: String::new(),
            name: "Test".into(),
            source: SourceKind::Xtream,
            server: xc.base(),
            user_agent: String::new(),
            max_connections: None,
            updated_at: 0,
        };
        let p = save_profile(&dir, profile).unwrap();
        let lib = Library::open(&dir, &p.id, vec![USER.into(), PASS.into()]).unwrap();
        lib.sync().await.unwrap();
        let first = |kind: i64| -> (String, String) {
            let conn = lib.conn.lock().unwrap();
            conn.query_row(
                "SELECT key, name FROM items WHERE kind = ?1 ORDER BY position LIMIT 1",
                [kind],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .unwrap()
        };
        let (movie, movie_name) = first(1);
        let (series, series_name) = first(3);
        let (title, year) = crate::tracking::clean_title(&movie_name);
        // One episode the series really has (asked straight from the panel: the profile stores none yet).
        let id: u64 = series.trim_start_matches("series:").parse().unwrap();
        let panel = crate::xtream::Xtream::new(&xc.base(), USER, PASS, None);
        let ep = panel.episodes(id).await.unwrap().remove(0);
        let (season, number) = (ep.season.unwrap(), ep.episode.unwrap());

        let mock = MockTracking::start().await;
        let c = Client {
            service: Service::Simkl,
            base: mock.base(),
            client_id: CLIENT_ID.into(),
            client_secret: SECRET.into(),
        };
        // A token the mock issued.
        mock.confirm();
        let code = crate::tracking::device_start(&c).await.unwrap();
        let crate::tracking::Poll::Token(t) = crate::tracking::device_poll(&c, &code.device_code)
            .await
            .unwrap()
        else {
            panic!("no token")
        };
        mock.set_sync(
            "2026-05-08T10:00:00Z",
            json!([{ "status": "completed", "last_watched_at": "2026-05-08T09:00:00Z",
                     "movie": { "title": title, "year": year, "ids": { "simkl": 1 } } }]),
            json!([{ "status": "watching", "show": { "title": crate::tracking::clean_title(&series_name).0, "ids": {} },
                     "seasons": [{ "number": season, "episodes": [{ "number": number, "watched_at": "2026-05-08T08:00:00Z" },
                                                                  { "number": number + 1 }] }] }]),
            json!([]),
        );
        let n = lib.simkl_import(&c, &t, true).await.unwrap().unwrap();
        assert_eq!((n.watched, n.waiting), (1, 1));
        assert!(lib.watched_keys().unwrap().contains(&movie));
        // Opening the series brings its episodes, and the waiting mark onto that one.
        let episodes = lib.episodes(&series).await.unwrap();
        let marked = {
            let conn = lib.conn.lock().unwrap();
            conn.query_row(
                "SELECT key FROM items WHERE category = ?1 AND season = ?2 AND episode = ?3",
                rusqlite::params![&series, season, number],
                |r| r.get::<_, String>(0),
            )
            .unwrap()
        };
        assert!(episodes.iter().any(|e| e.key == marked));
        assert!(lib.watched_keys().unwrap().contains(&marked));
        // Not due again within 30 minutes; forced, the unchanged activity time fetches nothing more.
        assert_eq!(lib.simkl_import(&c, &t, false).await.unwrap(), None);
        assert_eq!(lib.simkl_import(&c, &t, true).await.unwrap(), None);
        let calls = mock.calls();
        assert_eq!(
            calls
                .iter()
                .filter(|c| c.starts_with("/sync/all-items/movies"))
                .count(),
            1,
            "{calls:?}"
        );
        // A newer activity asks only for what changed since the last one.
        mock.set_sync("2026-05-09T10:00:00Z", json!([]), json!([]), json!([]));
        lib.simkl_import(&c, &t, true).await.unwrap();
        assert!(
            mock.calls()
                .contains(&"/sync/all-items/movies/completed?2026-05-08T10:00:00Z".to_string())
        );
        // A mark by hand goes to the history; an unmark to its removal.
        let w = Watching::Movie {
            title,
            year,
            tmdb: Some(5),
        };
        simkl_history(&c, &t, &w, true).await.unwrap();
        simkl_history(&c, &t, &w, false).await.unwrap();
        let history: Vec<_> = mock
            .calls()
            .into_iter()
            .filter(|c| c.contains("/sync/history"))
            .collect();
        assert!(
            history[0].starts_with("/sync/history {")
                && history[1].starts_with("/sync/history/remove")
        );
        assert!(history[0].contains("\"tmdb\":5"));
        drop(lib);
        std::fs::remove_dir_all(&dir).unwrap();
    }

    /// A paused position counts only where the length is known, and never as finished.
    #[test]
    fn paused_positions_need_a_known_length() {
        use crate::tracking::{Changes, Paused};
        let mut c = crate::db::open(std::path::Path::new(":memory:")).unwrap();
        c.execute_batch(
            "INSERT INTO items (key, kind, name, category, position, seen) VALUES
                ('movie:1', 1, 'Alpha (2001)', 'm', 0, 1), ('movie:2', 1, 'Beta', 'm', 1, 1);
             INSERT INTO resume VALUES ('movie:1', 600, 6000, 5);",
        )
        .unwrap();
        let paused = |title: &str, percent| Paused {
            watching: Watching::Movie {
                title: title.into(),
                year: None,
                tmdb: None,
            },
            percent,
            at: 10,
        };
        let changes = Changes {
            paused: vec![paused("Alpha", 99.0), paused("Beta", 50.0)],
            ..Default::default()
        };
        assert_eq!(super::apply(&mut c, &changes).unwrap().positions, 1);
        let pos: i64 = c
            .query_row(
                "SELECT position FROM resume WHERE key = 'movie:1'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(pos, 5640, "94 % of 6000 s");
    }
}
