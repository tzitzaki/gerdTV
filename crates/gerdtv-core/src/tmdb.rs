//! TMDB enrichment (opt-in, the user's own API key): a movie's or series' page gets what its panel leaves empty
//! (plot, genre, cast, director, release, length, rating, backdrop, trailer). Asked when a page opens, never in bulk,
//! and kept in the `tmdb` table for 30 days (TMDB's terms allow up to 6 months).
//!
//! Matching: the panel's own TMDB id when it sends one; else a search by the cleaned title (tracking::clean_title)
//! and year. Only an unambiguous hit counts: the one result, or the one whose title or original title is the
//! cleaned title. No match is cached too, so a title TMDB doesn't know isn't searched at every page open.
//!
//! Terms (themoviedb.org/api-terms-of-use): non-commercial use, attribution with TMDB's logo and notice in About,
//! respect 429. No key ships with gerdTV (owner decision: no secret in the repository or the app).
//! Debug hints: a 401 is a wrong key (nothing cached then); a page without TMDB facts after a match: look at the
//! `tmdb` row's `data`, `{}` means no match.

use crate::xtream::Details;
use rusqlite::{Connection, OptionalExtension, params};
use serde_json::Value;
use std::time::Duration;

pub const BASE: &str = "https://api.themoviedb.org";
const IMAGES: &str = "https://image.tmdb.org/t/p/w1280";
/// How long a lookup (hit or miss) is kept.
pub const KEEP_SECS: i64 = 30 * 24 * 3600;

#[derive(Debug, thiserror::Error)]
pub enum TmdbError {
    #[error("TMDB refused the API key")]
    Key,
    #[error("TMDB: HTTP {0}")]
    Http(u16),
    #[error("TMDB: network error: {0}")]
    Network(String),
    #[error(transparent)]
    Db(#[from] rusqlite::Error),
}

pub type Result<T> = std::result::Result<T, TmdbError>;

pub struct Tmdb {
    http: reqwest::Client,
    base: String,
    key: String,
}

/// What a page shows about one item; `series` picks TMDB's tv endpoints.
pub struct Wanted<'a> {
    pub key: &'a str,
    pub name: &'a str,
    pub series: bool,
    /// The panel's TMDB id, when it sends one.
    pub id: Option<u64>,
}

impl Tmdb {
    pub fn new(base: &str, key: &str) -> Tmdb {
        crate::xtream::ensure_tls_provider();
        Tmdb {
            http: reqwest::Client::builder()
                .connect_timeout(Duration::from_secs(10))
                .timeout(Duration::from_secs(20))
                .user_agent(concat!("gerdTV/", env!("CARGO_PKG_VERSION")))
                .build()
                .expect("HTTP client"),
            base: base.trim_end_matches('/').to_string(),
            key: key.trim().to_string(),
        }
    }

    /// A GET with the key; one wait on 429 (TMDB's Retry-After, at most 5 s), then the error.
    async fn get(&self, path: &str, query: &[(&str, String)]) -> Result<Value> {
        for attempt in 0..2 {
            let req = self.http.get(format!("{}/3/{path}", self.base));
            // TMDB hands out two kinds: the v4 read access token (a JWT, with dots) goes as a bearer token, the
            // shorter v3 API key as a query parameter.
            let req = if self.key.contains('.') {
                req.bearer_auth(&self.key)
            } else {
                req.query(&[("api_key", &self.key)])
            };
            let res = req
                .query(query)
                .send()
                .await
                .map_err(|e| TmdbError::Network(e.without_url().to_string()))?;
            match res.status().as_u16() {
                200 => {
                    let body = res
                        .bytes()
                        .await
                        .map_err(|e| TmdbError::Network(e.without_url().to_string()))?;
                    // Garbage is a server error, not a reason to stop: the page keeps the panel's facts.
                    return serde_json::from_slice(&body).map_err(|_| TmdbError::Http(200));
                }
                401 => return Err(TmdbError::Key),
                429 if attempt == 0 => {
                    let wait = res
                        .headers()
                        .get("retry-after")
                        .and_then(|v| v.to_str().ok()?.parse::<u64>().ok())
                        .unwrap_or(1)
                        .min(5);
                    tokio::time::sleep(Duration::from_secs(wait)).await;
                }
                s => return Err(TmdbError::Http(s)),
            }
        }
        Err(TmdbError::Http(429))
    }

    /// The TMDB id for `w`, or None when TMDB has no unambiguous match.
    async fn find(&self, w: &Wanted<'_>) -> Result<Option<u64>> {
        if w.id.is_some() {
            return Ok(w.id);
        }
        let (title, year) = crate::tracking::clean_title(w.name);
        if title.is_empty() {
            return Ok(None);
        }
        let (kind, year_param) = if w.series {
            ("tv", "first_air_date_year")
        } else {
            ("movie", "year")
        };
        let mut query = vec![("query", title.clone())];
        if let Some(y) = year {
            query.push((year_param, y.to_string()));
        }
        let found = self.get(&format!("search/{kind}"), &query).await?;
        let results = found["results"].as_array().cloned().unwrap_or_default();
        let fold = |s: &str| crate::db::fold(s);
        let same = |r: &&Value| {
            ["title", "name", "original_title", "original_name"]
                .iter()
                .any(|k| r[*k].as_str().is_some_and(|t| fold(t) == fold(&title)))
        };
        let pick = match results.as_slice() {
            [one] => Some(one),
            many => {
                let exact: Vec<&Value> = many.iter().filter(same).collect();
                if exact.len() == 1 {
                    Some(exact[0])
                } else {
                    None
                }
            }
        };
        Ok(pick.and_then(|r| r["id"].as_u64()))
    }

    /// The page's facts from TMDB, from the cache when it is fresh. A miss is an empty [Details].
    pub async fn details(
        &self,
        conn: &std::sync::Mutex<Connection>,
        w: &Wanted<'_>,
    ) -> Result<Details> {
        let now = now();
        let cached: Option<String> = conn
            .lock()
            .unwrap()
            .query_row(
                "SELECT data FROM tmdb WHERE key = ?1 AND fetched_at > ?2",
                params![w.key, now - KEEP_SECS],
                |r| r.get(0),
            )
            .optional()?;
        let data = match cached {
            Some(d) => serde_json::from_str(&d).unwrap_or(Value::Null),
            None => {
                let data = match self.find(w).await? {
                    Some(id) => {
                        let kind = if w.series { "tv" } else { "movie" };
                        self.get(
                            &format!("{kind}/{id}"),
                            &[("append_to_response", "credits,videos".into())],
                        )
                        .await?
                    }
                    None => Value::Object(Default::default()),
                };
                conn.lock().unwrap().execute(
                    "INSERT INTO tmdb (key, data, fetched_at) VALUES (?1, ?2, ?3)
                     ON CONFLICT (key) DO UPDATE SET data = ?2, fetched_at = ?3",
                    params![w.key, data.to_string(), now],
                )?;
                data
            }
        };
        Ok(details(&data))
    }
}

/// TMDB's answer as the page's facts.
fn details(v: &Value) -> Details {
    let text = |k: &str| v[k].as_str().unwrap_or_default().to_string();
    let names = |list: &Value, take: usize| {
        list.as_array()
            .into_iter()
            .flatten()
            .filter_map(|x| x["name"].as_str())
            .take(take)
            .collect::<Vec<_>>()
            .join(", ")
    };
    let crew = v["credits"]["crew"].as_array().cloned().unwrap_or_default();
    let director = crew
        .iter()
        .filter(|c| c["job"] == "Director")
        .filter_map(|c| c["name"].as_str())
        .collect::<Vec<_>>()
        .join(", ");
    let trailer = v["videos"]["results"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|t| t["site"] == "YouTube" && t["type"] == "Trailer")
        .and_then(|t| t["key"].as_str())
        .map(crate::xtream::trailer_id)
        .unwrap_or_default();
    let minutes = v["runtime"]
        .as_u64()
        .or_else(|| v["episode_run_time"][0].as_u64());
    Details {
        plot: text("overview"),
        genre: names(&v["genres"], 3),
        cast: names(&v["credits"]["cast"], 6),
        director,
        release: [text("release_date"), text("first_air_date")].concat(),
        duration_secs: minutes.filter(|m| *m > 0).map(|m| m as u32 * 60),
        rating: v["vote_average"].as_f64().filter(|r| *r > 0.0),
        backdrop: v["backdrop_path"]
            .as_str()
            .map(|p| format!("{IMAGES}{p}"))
            .unwrap_or_default(),
        trailer,
        tmdb_id: v["id"].as_u64(),
    }
}

/// The panel's facts first; TMDB fills what the panel left empty.
pub fn merge(panel: Details, tmdb: Details) -> Details {
    let or = |a: String, b: String| if a.trim().is_empty() { b } else { a };
    Details {
        plot: or(panel.plot, tmdb.plot),
        genre: or(panel.genre, tmdb.genre),
        cast: or(panel.cast, tmdb.cast),
        director: or(panel.director, tmdb.director),
        release: or(panel.release, tmdb.release),
        duration_secs: panel.duration_secs.or(tmdb.duration_secs),
        rating: panel.rating.or(tmdb.rating),
        backdrop: or(panel.backdrop, tmdb.backdrop),
        trailer: or(panel.trailer, tmdb.trailer),
        tmdb_id: panel.tmdb_id.or(tmdb.tmdb_id),
    }
}

fn now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs() as i64)
}

#[cfg(test)]
mod tests {
    use super::*;
    use gerdtv_testkit::mock_tmdb::{KEY, MockTmdb};
    use std::sync::Mutex;

    fn cache() -> Mutex<Connection> {
        Mutex::new(crate::db::open(std::path::Path::new(":memory:")).unwrap())
    }

    fn wanted<'a>(key: &'a str, name: &'a str, series: bool) -> Wanted<'a> {
        Wanted {
            key,
            name,
            series,
            id: None,
        }
    }

    /// New, because nothing owns TMDB matching: only an unambiguous hit counts, the panel's id wins, a series isn't
    /// a film, and the cleaned title is searched.
    #[tokio::test]
    async fn matches_only_what_is_unambiguous() {
        let mock = MockTmdb::start().await;
        let t = Tmdb::new(&mock.base(), KEY);
        let db = cache();
        for (name, series, id, want) in [
            (
                "DE - Die Reise nach München (2019) 4K",
                false,
                None,
                Some(1001),
            ),
            ("Die Reise nach München (1972)", false, None, Some(1002)),
            ("Die Reise nach München", false, None, None), // two films of that name
            ("Planet Wissen", true, None, Some(2001)),
            ("Planet Wissen", false, None, Some(1004)),
            ("Grösse und Strasse", false, Some(1003), Some(1003)), // the panel knows it
            ("Nothing like this", false, None, None),
        ] {
            let key = format!("{name}{series}");
            let w = Wanted {
                id,
                ..wanted(&key, name, series)
            };
            let d = t.details(&db, &w).await.unwrap();
            assert_eq!(d.tmdb_id, want, "{name}");
            if want.is_some() {
                assert!(
                    !d.plot.is_empty() && d.backdrop.starts_with(IMAGES) && d.trailer.is_empty()
                );
                assert_eq!(
                    (d.duration_secs, d.cast.split(", ").count()),
                    (Some(97 * 60), 6)
                );
            }
        }
    }

    /// A lookup is kept (also a miss); a refused key keeps nothing; one 429 is waited out.
    #[tokio::test]
    async fn caches_and_respects_the_limits() {
        let mock = MockTmdb::start().await;
        let db = cache();
        let bad = Tmdb::new(&mock.base(), "wrong");
        assert!(matches!(
            bad.details(&db, &wanted("movie:1", "Planet Wissen", false))
                .await,
            Err(TmdbError::Key)
        ));
        let t = Tmdb::new(&mock.base(), KEY);
        mock.rate_limit(1);
        for _ in 0..2 {
            let d = t
                .details(&db, &wanted("movie:1", "Planet Wissen", false))
                .await
                .unwrap();
            assert_eq!(d.tmdb_id, Some(1004));
            t.details(&db, &wanted("movie:2", "Nothing like this", false))
                .await
                .unwrap();
        }
        // 1 refused + 1 throttled + search and details for the hit + one search for the miss; the second round: none.
        assert_eq!(mock.requests(), 5);
    }

    #[test]
    fn the_panel_wins_where_it_has_something() {
        let panel = Details {
            plot: "Panel".into(),
            ..Default::default()
        };
        let tmdb = Details {
            plot: "TMDB".into(),
            genre: "Drama".into(),
            rating: Some(7.0),
            ..Default::default()
        };
        let d = merge(panel, tmdb);
        assert_eq!(
            (d.plot.as_str(), d.genre.as_str(), d.rating),
            ("Panel", "Drama", Some(7.0))
        );
    }
}
