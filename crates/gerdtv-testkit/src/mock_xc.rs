//! A mock Xtream Codes panel serving the synthetic library (generate.rs) the way real panels do:
//!   /player_api.php?username=&password=[&action=…]   account info, categories, stream lists, VOD/series info
//!   /get.php?username=&password=&type=m3u_plus        the same library as M3U
//!   /xmltv.php?username=&password=                    the guide (2 days by default, every live channel's id)
//!   /timeshift/<user>/<pass>/<min>/<time>/<id>.ts       catch-up (every 13th live channel has a 3-day archive)
//!   /live|movie|series/<user>/<pass>/<id>.<ext>       streams: the fault server's clip (live endless, VOD as file)
//! Credentials are `testuser` / `testpass`; anything else gets `{"user_info":{"auth":0}}` like a real panel.
//! Quirks copied from real panels: numbers often sent as strings, empty strings for missing values, `tmdb` ids on
//! some entries only, `epg_channel_id` sometimes null.
//!
//! Switches for tests: `set_expired` (account expired), `set_max_connections`, and the shared `Fault` for streams.

use crate::fault::{Fault, FaultServer};
use crate::generate::{Entry, Kind, library, write_m3u, write_xmltv};
use crate::http::{self, Handler, Request, Server};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};

pub const USER: &str = "testuser";
pub const PASS: &str = "testpass";

#[derive(Default)]
struct Switches {
    expired: bool,
    max_connections: u32,
    /// The next answer to this action is `[]` (real panels do this now and then under load).
    empty_once: Option<String>,
}

pub struct MockXc {
    server: Server,
    /// Streams are proxied (by redirect) to this fault server, so stream faults work the same here.
    pub streams: FaultServer,
    switches: Arc<Mutex<Switches>>,
}

struct Data {
    entries: Vec<Entry>,
    /// series name → (series id, category id)
    series: BTreeMap<String, (u64, u32)>,
    seed: u64,
}

impl MockXc {
    /// Starts a panel with `n` library entries.
    pub async fn start(n: usize, seed: u64) -> MockXc {
        let entries: Vec<Entry> = library(n, seed).collect();
        let mut series = BTreeMap::new();
        for e in &entries {
            if let Some((show, _, _)) = &e.series {
                let next = 500_000 + series.len() as u64;
                series.entry(show.clone()).or_insert((next, e.category_id));
            }
        }
        let data = Arc::new(Data {
            entries,
            series,
            seed,
        });
        let switches = Arc::new(Mutex::new(Switches {
            expired: false,
            max_connections: 2,
            empty_once: None,
        }));
        let streams = FaultServer::start().await;
        let stream_base = streams.url("");
        let sw = switches.clone();
        let handler: Handler = Arc::new(move |req, stream| {
            let (data, sw, stream_base) = (data.clone(), sw.clone(), stream_base.clone());
            Box::pin(async move { serve(req, stream, &data, &sw, &stream_base).await })
        });
        MockXc {
            server: Server::start(handler).await,
            streams,
            switches,
        }
    }

    /// The panel's base URL (what a user types as "server").
    pub fn base(&self) -> String {
        self.server.url("")
    }

    pub fn set_expired(&self, expired: bool) {
        self.switches.lock().unwrap().expired = expired;
    }

    /// The next request for `action` (e.g. "get_vod_streams") answers `[]`.
    pub fn empty_once(&self, action: &str) {
        self.switches.lock().unwrap().empty_once = Some(action.to_string());
    }

    pub fn set_max_connections(&self, n: u32) {
        self.switches.lock().unwrap().max_connections = n;
    }

    /// Faults for the streams (see fault.rs).
    pub fn set_stream_fault(&self, fault: Fault) {
        self.streams.set(fault);
    }
}

async fn serve(
    req: Request,
    stream: tokio::net::TcpStream,
    data: &Data,
    sw: &Mutex<Switches>,
    stream_base: &str,
) {
    let authed = req.param("username") == Some(USER) && req.param("password") == Some(PASS);
    match req.path.as_str() {
        "/player_api.php" => {
            let body = if !authed {
                json!({"user_info": {"auth": 0}})
            } else {
                player_api(&req, data, sw)
            };
            http::respond(stream, 200, "application/json", body.to_string().as_bytes()).await
        }
        "/get.php" if authed => {
            let mut out = Vec::new();
            let _ = write_m3u(&mut out, data.entries.len(), data.seed);
            http::respond(stream, 200, "audio/x-mpegurl", &out).await
        }
        "/xmltv.php" if authed => {
            let channels = data
                .entries
                .iter()
                .filter(|e| e.kind == Kind::Live)
                .count()
                .div_ceil(3);
            let mut out = Vec::new();
            // Around the current time (yesterday 00:00 UTC, 3 days), so clients see "now" in the guide.
            let today = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_secs() as i64
                / 86_400
                * 86_400;
            let _ = write_xmltv(&mut out, channels, 3, today - 86_400, data.seed);
            http::respond(stream, 200, "application/xml", &out).await
        }
        "/get.php" | "/xmltv.php" => http::respond(stream, 401, "text/plain", b"").await,
        p if p.starts_with("/live/") || p.starts_with("/movie/") || p.starts_with("/series/") => {
            let parts: Vec<&str> = p.split('/').collect(); // ["", kind, user, pass, file]
            if parts.len() != 5 || parts[2] != USER || parts[3] != PASS {
                return http::respond(stream, 403, "text/plain", b"").await;
            }
            if sw.lock().unwrap().expired {
                return http::respond(stream, 403, "text/plain", b"").await;
            }
            // Real panels redirect to a streaming node; so does this one.
            let (id, ext) = parts[4].rsplit_once('.').unwrap_or((parts[4], "ts"));
            let target = match (parts[1], ext) {
                ("live", "m3u8") => format!("{stream_base}/live/{id}.m3u8"),
                ("live", _) => format!("{stream_base}/live/{id}.ts"),
                _ => format!("{stream_base}/vod/{id}.ts"),
            };
            redirect(stream, &target).await
        }
        // Catch-up: /timeshift/<user>/<pass>/<minutes>/<YYYY-MM-DD:HH-MM>/<id>.ts → the recording-like VOD stream.
        p if p.starts_with("/timeshift/") => {
            let parts: Vec<&str> = p.split('/').collect(); // ["", "timeshift", user, pass, min, time, file]
            if parts.len() != 7 || parts[2] != USER || parts[3] != PASS {
                return http::respond(stream, 403, "text/plain", b"").await;
            }
            let id = parts[6].trim_end_matches(".ts");
            redirect(stream, &format!("{stream_base}/vod/{id}.ts")).await
        }
        _ => http::respond(stream, 404, "text/plain", b"").await,
    }
}

async fn redirect(mut stream: tokio::net::TcpStream, to: &str) {
    use tokio::io::AsyncWriteExt;
    let head = format!(
        "HTTP/1.1 302 Found\r\nLocation: {to}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    );
    let _ = stream.write_all(head.as_bytes()).await;
    let _ = stream.shutdown().await;
}

fn player_api(req: &Request, data: &Data, sw: &Mutex<Switches>) -> Value {
    let mut sw = sw.lock().unwrap();
    if sw.empty_once.is_some() && sw.empty_once.as_deref() == req.param("action") {
        sw.empty_once = None;
        return json!([]);
    }
    let category = req.param("category_id").and_then(|c| c.parse::<u32>().ok());
    let of_kind = |k: Kind| data.entries.iter().filter(move |e| e.kind == k);
    let in_category = |e: &&Entry| category.is_none_or(|c| e.category_id == c);
    match req.param("action") {
        None => json!({
            "user_info": {
                "username": USER, "password": PASS, "auth": 1,
                "status": if sw.expired { "Expired" } else { "Active" },
                "exp_date": if sw.expired { "1600000000" } else { "4102444800" },
                "is_trial": "0", "active_cons": "0", "created_at": "1600000000",
                "max_connections": sw.max_connections.to_string(),
                "allowed_output_formats": ["m3u8", "ts"]
            },
            "server_info": { "url": "xc.example.invalid", "port": "8080", "server_protocol": "http",
                             "timezone": "Europe/Berlin", "timestamp_now": 1_763_683_200 }
        }),
        Some(a @ ("get_live_categories" | "get_vod_categories" | "get_series_categories")) => {
            let kind = match a {
                "get_live_categories" => Kind::Live,
                "get_vod_categories" => Kind::Movie,
                _ => Kind::Episode,
            };
            // Provider order = order of first appearance.
            let mut seen = Vec::<(u32, String)>::new();
            for e in of_kind(kind) {
                if !seen.iter().any(|(id, _)| *id == e.category_id) {
                    seen.push((e.category_id, e.group.clone()));
                }
            }
            Value::Array(
                seen.into_iter()
                    .map(|(id, name)| json!({"category_id": id.to_string(), "category_name": name, "parent_id": 0}))
                    .collect(),
            )
        }
        Some("get_live_streams") => Value::Array(
            of_kind(Kind::Live)
                .filter(in_category)
                .map(|e| {
                    json!({
                        "num": e.number, "name": e.name, "stream_type": "live", "stream_id": e.id,
                        "stream_icon": e.logo,
                        "epg_channel_id": if e.epg_id.is_empty() { Value::Null } else { json!(e.epg_id) },
                        "added": "1700000000", "category_id": e.category_id.to_string(),
                        "tv_archive": if e.id % 13 == 0 { 1 } else { 0 }, "tv_archive_duration": "3"
                    })
                })
                .collect(),
        ),
        Some("get_vod_streams") => Value::Array(
            of_kind(Kind::Movie)
                .filter(in_category)
                .map(|e| {
                    json!({
                        "num": e.id - 100_000, "name": e.name, "stream_type": "movie", "stream_id": e.id,
                        "stream_icon": e.logo, "rating": if e.id % 3 == 0 { json!("") } else { json!("7.1") },
                        "added": (1_700_000_000 + e.id).to_string(), "category_id": e.category_id.to_string(),
                        "container_extension": "mkv",
                        "tmdb": if e.id % 4 == 0 { json!((e.id % 900_000).to_string()) } else { json!("") }
                    })
                })
                .collect(),
        ),
        Some("get_series") => Value::Array(
            data.series
                .iter()
                .filter(|(_, (_, c))| category.is_none_or(|cat| *c == cat))
                .map(|(name, (id, cat))| {
                    json!({
                        "num": id - 500_000, "name": name, "series_id": id, "cover": "", "plot": "",
                        "cast": "", "genre": "", "releaseDate": "", "rating": "0",
                        "last_modified": (1_700_000_000 + id).to_string(),
                        "category_id": cat.to_string(), "tmdb": ""
                    })
                })
                .collect(),
        ),
        Some("get_vod_info") => {
            let id: u64 = req.param("vod_id").and_then(|v| v.parse().ok()).unwrap_or(0);
            match of_kind(Kind::Movie).find(|e| e.id == id) {
                Some(e) => json!({
                    "info": { "name": e.name, "plot": "A synthetic film.", "duration_secs": 5400,
                              "releasedate": e.year.map(|y| format!("{y}-01-01")).unwrap_or_default(),
                              "tmdb_id": if e.id % 4 == 0 { json!((e.id % 900_000).to_string()) } else { json!("") } },
                    "movie_data": { "stream_id": e.id, "name": e.name, "container_extension": "mkv" }
                }),
                None => json!([]), // real panels answer an unknown id with an empty list
            }
        }
        Some("get_series_info") => {
            let id: u64 = req.param("series_id").and_then(|v| v.parse().ok()).unwrap_or(0);
            let Some((name, _)) = data.series.iter().find(|(_, (sid, _))| *sid == id) else {
                return json!([]);
            };
            let mut seasons: BTreeMap<String, Vec<Value>> = BTreeMap::new();
            for e in of_kind(Kind::Episode) {
                if let Some((show, s, ep)) = &e.series
                    && show == name
                {
                    seasons.entry(s.to_string()).or_default().push(json!({
                        "id": e.id.to_string(), "episode_num": ep, "season": s,
                        "title": e.name, "container_extension": "mp4", "info": {}
                    }));
                }
            }
            json!({ "info": { "name": name }, "episodes": seasons })
        }
        Some(_) => json!([]),
    }
}
