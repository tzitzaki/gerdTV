//! A mock of the OpenSubtitles REST API (v1) as gerdTV uses it, shaped like its published API definition:
//!   POST /api/v1/login {username, password} → {token, base_url, user}
//!   GET  /api/v1/subtitles?tmdb_id=|parent_tmdb_id=&season_number=&episode_number=|query=&languages=
//!   POST /api/v1/download {file_id} → {link, remaining}; GET /file/<id>.srt serves the subtitle
//! Every call needs the `Api-Key` header ([KEY]); a download without a login token is allowed [FREE] times (the
//! real limit: 5 per IP and day), with one per [QUOTA] (OpenSubtitles answers 406 when it's spent).
//! Search results come from a small fixed table; downloads are counted for the tests.

use crate::http::{self, Handler, Request, Server};
use serde_json::{Value, json};
use std::sync::{Arc, Mutex};

pub const KEY: &str = "oskey";
pub const USER: &str = "osuser";
pub const PASS: &str = "ospass";
const TOKEN: &str = "ostoken";
pub const FREE: u32 = 2;
pub const QUOTA: u32 = 20;

/// (file id, TMDB id of the movie or show, season, episode, language, release)
pub const FILES: &[(u64, u64, u32, u32, &str, &str)] = &[
    (11, 1001, 0, 0, "de", "Die.Reise.nach.Muenchen.2019.German"),
    (12, 1001, 0, 0, "en", "The.Journey.to.Munich.2019"),
    (21, 2001, 1, 2, "de", "Planet.Wissen.S01E02.German"),
];

pub struct MockOpenSubtitles {
    server: Server,
    downloads: Arc<Mutex<(u32, u32)>>, // (without login, with login)
}

impl MockOpenSubtitles {
    pub async fn start() -> MockOpenSubtitles {
        let downloads = Arc::new(Mutex::new((0u32, 0u32)));
        let d = downloads.clone();
        let base = Arc::new(Mutex::new(String::new()));
        let b = base.clone();
        let handler: Handler = Arc::new(move |req, stream| {
            let (status, ct, body) = answer(&req, &mut d.lock().unwrap(), &b.lock().unwrap());
            Box::pin(async move { http::respond(stream, status, ct, body.as_bytes()).await })
        });
        let server = Server::start(handler).await;
        *base.lock().unwrap() = server.url("");
        MockOpenSubtitles { server, downloads }
    }

    pub fn base(&self) -> String {
        self.server.url("")
    }

    /// Downloads counted so far: (without a login, with one).
    pub fn downloads(&self) -> (u32, u32) {
        *self.downloads.lock().unwrap()
    }
}

fn json(status: u16, v: Value) -> (u16, &'static str, String) {
    (status, "application/json", v.to_string())
}

fn answer(req: &Request, d: &mut (u32, u32), base: &str) -> (u16, &'static str, String) {
    if let Some(id) = req.path.strip_prefix("/file/") {
        return (
            200,
            "application/x-subrip",
            format!("1\n00:00:01,000 --> 00:00:03,000\nSynthetic subtitle {id}\n"),
        );
    }
    if req.header("api-key") != Some(KEY) {
        return json(403, json!({ "message": "You cannot consume this service" }));
    }
    let body: Value = serde_json::from_str(&req.body).unwrap_or(Value::Null);
    let num = |k: &str| req.param(k).and_then(|v| v.parse::<u64>().ok());
    match (req.method.as_str(), req.path.as_str()) {
        ("POST", "/api/v1/login") => {
            if body["username"] == USER && body["password"] == PASS {
                json(
                    200,
                    json!({ "token": TOKEN, "base_url": "api.opensubtitles.com", "status": 200,
                                   "user": { "allowed_downloads": QUOTA, "level": "Sub leecher" } }),
                )
            } else {
                json(
                    401,
                    json!({ "message": "Error, invalid username/password", "status": 401 }),
                )
            }
        }
        ("GET", "/api/v1/subtitles") => {
            let tmdb = num("tmdb_id").or(num("parent_tmdb_id"));
            let languages = req.param("languages").unwrap_or("");
            let data: Vec<Value> = FILES
                .iter()
                .filter(|f| tmdb == Some(f.1))
                .filter(|f| num("season_number").is_none_or(|s| s == f.2 as u64))
                .filter(|f| num("episode_number").is_none_or(|e| e == f.3 as u64))
                .filter(|f| languages.is_empty() || languages.split(',').any(|l| l == f.4))
                .map(|f| json!({ "id": f.0.to_string(), "type": "subtitle", "attributes": {
                    "language": f.4, "release": f.5, "download_count": 100, "hearing_impaired": false,
                    "machine_translated": false, "ai_translated": false,
                    "files": [{ "file_id": f.0, "cd_number": 1, "file_name": format!("{}.srt", f.5) }] } }))
                .collect();
            let n = data.len();
            json(
                200,
                json!({ "total_pages": 1, "total_count": n, "per_page": 50, "page": 1, "data": data }),
            )
        }
        ("POST", "/api/v1/download") => {
            let signed = req.header("authorization") == Some(&format!("Bearer {TOKEN}"));
            let (used, limit) = if signed {
                (&mut d.1, QUOTA)
            } else {
                (&mut d.0, FREE)
            };
            if *used >= limit {
                return json(
                    406,
                    json!({ "message": "You have downloaded your allowed 5 subtitles for 24h",
                                          "remaining": 0 }),
                );
            }
            *used += 1;
            let id = body["file_id"].as_u64().unwrap_or(0);
            json(
                200,
                json!({ "link": format!("{base}/file/{id}.srt"), "file_name": format!("{id}.srt"),
                               "requests": *used, "remaining": limit - *used }),
            )
        }
        _ => json(404, json!({ "message": "not found" })),
    }
}
