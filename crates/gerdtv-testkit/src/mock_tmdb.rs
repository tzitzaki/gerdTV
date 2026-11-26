//! A mock of the TMDB v3 API, enough for matching and enrichment tests:
//!   /3/search/movie?query=&year=&language=   /3/search/tv?query=&first_air_date_year=
//!   /3/movie/<id>?append_to_response=credits,videos   /3/tv/<id>   /3/tv/<id>/season/<n>
//! The key is `testkey` (as `api_key=` or `Authorization: Bearer testkey`); others get TMDB's 401 body.
//! `rate_limit(n)` makes the next n requests answer 429 with `Retry-After: 1`, as TMDB does when hammered.
//! The catalogue is a small fixed table, written to exercise matching: umlauts, the same title in two years,
//! a film and a series with the same name, and an original title that differs from the German one.

use crate::http::{self, Handler, Request, Server};
use serde_json::{Value, json};
use std::sync::{Arc, Mutex};

pub const KEY: &str = "testkey";

/// (id, German title, original title, year, is_series)
pub const CATALOGUE: &[(u64, &str, &str, u32, bool)] = &[
    (
        1001,
        "Die Reise nach München",
        "The Journey to Munich",
        2019,
        false,
    ),
    (
        1002,
        "Die Reise nach München",
        "The Journey to Munich",
        1972,
        false,
    ),
    (1003, "Größe und Straße", "Size and Street", 2005, false),
    (1004, "Planet Wissen", "Planet Knowledge", 2011, false),
    (2001, "Planet Wissen", "Planet Knowledge", 2008, true),
    (2002, "Küche der Welt", "World Kitchen", 2015, true),
];

pub struct MockTmdb {
    server: Server,
    limit: Arc<Mutex<(u32, usize)>>, // (429s still to send, requests seen)
}

impl MockTmdb {
    pub async fn start() -> MockTmdb {
        let limit = Arc::new(Mutex::new((0u32, 0usize)));
        let l = limit.clone();
        let handler: Handler = Arc::new(move |req, stream| {
            let l = l.clone();
            Box::pin(async move {
                let throttled = {
                    let mut l = l.lock().unwrap();
                    l.1 += 1;
                    let t = l.0 > 0;
                    l.0 = l.0.saturating_sub(1);
                    t
                };
                if throttled {
                    let mut stream = stream;
                    use tokio::io::AsyncWriteExt;
                    let body = br#"{"status_code":25,"status_message":"Your request count is over the allowed limit."}"#;
                    let head = format!(
                        "HTTP/1.1 429 Too Many Requests\r\nRetry-After: 1\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                        body.len()
                    );
                    let _ = stream.write_all(head.as_bytes()).await;
                    let _ = stream.write_all(body).await;
                    return;
                }
                let (status, body) = answer(&req);
                http::respond(
                    stream,
                    status,
                    "application/json",
                    body.to_string().as_bytes(),
                )
                .await
            })
        });
        MockTmdb {
            server: Server::start(handler).await,
            limit,
        }
    }

    /// The API base (what the client uses instead of https://api.themoviedb.org).
    pub fn base(&self) -> String {
        self.server.url("")
    }

    /// The next `n` requests get 429.
    pub fn rate_limit(&self, n: u32) {
        self.limit.lock().unwrap().0 = n;
    }

    /// Requests seen so far (to assert a client backs off instead of hammering).
    pub fn requests(&self) -> usize {
        self.limit.lock().unwrap().1
    }
}

/// Lowercase and fold the German special letters, like TMDB's search does.
fn fold(s: &str) -> String {
    s.to_lowercase()
        .replace('ä', "a")
        .replace('ö', "o")
        .replace('ü', "u")
        .replace('ß', "ss")
}

/// A query value as TMDB reads it: `+` and percent escapes (UTF-8, as clients send umlauts) decoded.
fn decode(raw: &str) -> String {
    let b = raw.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        match b[i] {
            b'+' => out.push(b' '),
            b'%' if i + 2 < b.len() => match u8::from_str_radix(&raw[i + 1..i + 3], 16) {
                Ok(v) => {
                    out.push(v);
                    i += 2;
                }
                Err(_) => out.push(b'%'),
            },
            c => out.push(c),
        }
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn answer(req: &Request) -> (u16, Value) {
    let bearer = req.header("authorization") == Some(&format!("Bearer {KEY}"));
    if req.param("api_key") != Some(KEY) && !bearer {
        return (
            401,
            json!({"status_code": 7, "status_message": "Invalid API key: You must be granted a valid key."}),
        );
    }
    let query = fold(&decode(req.param("query").unwrap_or("")));
    let year: Option<u32> = req
        .param("year")
        .or(req.param("first_air_date_year"))
        .and_then(|y| y.parse().ok());
    let path: Vec<&str> = req.path.trim_start_matches("/3/").split('/').collect();
    let item = |&(id, title, original, y, series): &(u64, &str, &str, u32, bool)| {
        if series {
            json!({"id": id, "name": title, "original_name": original, "first_air_date": format!("{y}-03-01"),
                   "overview": format!("Synthetic series {id}."), "poster_path": format!("/p{id}.jpg"),
                   "backdrop_path": format!("/b{id}.jpg"), "vote_average": 7.5, "genre_ids": [18]})
        } else {
            json!({"id": id, "title": title, "original_title": original, "release_date": format!("{y}-05-01"),
                   "overview": format!("Synthetic film {id}."), "poster_path": format!("/p{id}.jpg"),
                   "backdrop_path": format!("/b{id}.jpg"), "vote_average": 6.8, "genre_ids": [12]})
        }
    };
    match path.as_slice() {
        ["search", kind @ ("movie" | "tv")] => {
            let series = *kind == "tv";
            let results: Vec<Value> = CATALOGUE
                .iter()
                .filter(|c| {
                    c.4 == series && (fold(c.1).contains(&query) || fold(c.2).contains(&query))
                })
                .filter(|c| year.is_none_or(|y| c.3 == y))
                .map(item)
                .collect();
            let n = results.len();
            (
                200,
                json!({"page": 1, "results": results, "total_pages": 1, "total_results": n}),
            )
        }
        [kind @ ("movie" | "tv"), id, rest @ ..] => {
            let series = *kind == "tv";
            let Some(c) = CATALOGUE
                .iter()
                .find(|c| c.4 == series && id.parse() == Ok(c.0))
            else {
                return (
                    404,
                    json!({"status_code": 34, "status_message": "The resource you requested could not be found."}),
                );
            };
            if let ["season", n] = rest {
                let episodes: Vec<Value> = (1..=6)
                    .map(|e| {
                        json!({"episode_number": e, "name": format!("Folge {e}"), "overview": "",
                                    "still_path": format!("/s{}{n}{e}.jpg", c.0)})
                    })
                    .collect();
                return (
                    200,
                    json!({"season_number": n.parse::<u32>().unwrap_or(1), "episodes": episodes}),
                );
            }
            let mut v = item(c);
            v["runtime"] = json!(97);
            v["genres"] = json!([{"id": 12, "name": "Abenteuer"}]);
            v["credits"] = json!({"cast": (0..12).map(|i| json!({"name": format!("Actor {i}"), "character": format!("Role {i}"), "profile_path": format!("/a{i}.jpg")})).collect::<Vec<_>>()});
            v["videos"] = json!({"results": [{"site": "YouTube", "type": "Trailer", "key": format!("yt{}", c.0)}]});
            if series {
                v["number_of_seasons"] = json!(2);
            }
            (200, v)
        }
        _ => (
            404,
            json!({"status_code": 34, "status_message": "The resource you requested could not be found."}),
        ),
    }
}
