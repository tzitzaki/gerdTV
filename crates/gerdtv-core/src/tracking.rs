//! Watch tracking (owner request: "a service that tracks my viewing progress"): Trakt and Simkl, both linked by a
//! device code (the user types it on trakt.tv/activate or simkl.com/pin) and both told what plays by scrobbling:
//! start when a movie or episode starts, pause on a pause, stop with the progress when it ends or another starts
//! (both mark it watched from 80 %).
//!
//! What is sent: the title and year of a movie, or the show's title with season and episode number; provider names
//! are cleaned first ("DE - Inception (2010) 4K" → "Inception", 2010), since IPTV panels rarely carry ids. Nothing is
//! sent for live TV, catch-up or Premiumize files.
//!
//! Tokens: an access token with a refresh token and its expiry, kept by the app in its secure storage as JSON
//! ([Token::to_json]); refreshed here a minute before it runs out. No secret ships with gerdTV (owner decision: the
//! repository is public and a secret inside an app can be extracted): Simkl needs only gerdTV's client id, a public
//! identifier the release build gets as a define; Trakt needs a secret too, so each user links their own Trakt app,
//! whose id and secret the app passes in from the device's secure storage.
//!
//! APIs: Trakt v2 (https://api.trakt.tv, headers trakt-api-version 2 and trakt-api-key), Simkl's OAuth 2 device flow
//! (https://api.simkl.com/oauth2/device, every call with client_id, app-name, app-version and a User-Agent).
//! Debug hints: Trakt answers a pending code with HTTP 400 and a refused or expired one with 404/409/410/418; Simkl
//! with OAuth error names (`authorization_pending`, `slow_down`, `expired_token`). A scrobble that fails is logged
//! and dropped: tracking never interrupts playback.

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::time::Duration;

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Service {
    Trakt,
    Simkl,
}

impl Service {
    pub const fn base(self) -> &'static str {
        match self {
            Service::Trakt => "https://api.trakt.tv",
            Service::Simkl => "https://api.simkl.com",
        }
    }
}

/// gerdTV's registration at the service (and the address, so tests can pass a mock's).
#[derive(Debug, Clone)]
pub struct Client {
    pub service: Service,
    pub base: String,
    pub client_id: String,
    /// Trakt only.
    pub client_secret: String,
}

#[derive(Debug, thiserror::Error)]
pub enum TrackError {
    #[error("{0}: HTTP {1}")]
    Http(&'static str, u16),
    #[error("network error: {0}")]
    Network(String),
    #[error("unexpected answer from {0}")]
    Parse(&'static str),
}

pub type Result<T> = std::result::Result<T, TrackError>;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Token {
    pub access: String,
    pub refresh: String,
    /// UTC seconds.
    pub expires_at: i64,
}

impl Token {
    pub fn to_json(&self) -> String {
        serde_json::to_string(self).expect("a token serialises")
    }
    pub fn from_json(s: &str) -> Option<Token> {
        serde_json::from_str(s).ok()
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct DeviceCode {
    pub device_code: String,
    pub user_code: String,
    pub verification_uri: String,
    pub interval: u32,
    pub expires_in: u32,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Poll {
    Pending,
    SlowDown,
    Token(Token),
    Failed(String),
}

/// What plays, as the services want it.
#[derive(Debug, Clone, PartialEq)]
pub enum Watching {
    Movie {
        title: String,
        year: Option<u32>,
        /// TMDB's id when gerdTV knows it (tmdb.rs): both services match by id before the title.
        tmdb: Option<u64>,
    },
    Episode {
        show: String,
        season: u32,
        number: u32,
        /// The show's TMDB id.
        tmdb: Option<u64>,
    },
}

/// An item's row as tracking needs it (Library::track_info); `show`, `season` and `number` only for episodes.
#[derive(Debug, Clone, PartialEq)]
pub struct TrackInfo {
    pub movie: bool,
    pub name: String,
    pub year: Option<u32>,
    pub show: String,
    pub season: u32,
    pub number: u32,
    /// TMDB's id of the movie, or of an episode's series, when the tmdb cache has it.
    pub tmdb: Option<u64>,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Action {
    Start,
    Pause,
    Stop,
}

/// "DE - Inception (2010) 4K" → ("Inception", Some(2010)): a country or language prefix ("DE - ", "EN: ", "|DE| "),
/// the year in brackets and quality tags are the panel's, not the title's.
pub fn clean_title(name: &str) -> (String, Option<u32>) {
    let mut s = name.trim().to_string();
    // A prefix of 2–4 capitals or digits before " - ", ": " or between bars.
    for sep in [" - ", ": ", "| "] {
        if let Some((head, rest)) = s.split_once(sep) {
            let head = head.trim_matches('|').trim();
            if (2..=4).contains(&head.len())
                && head
                    .chars()
                    .all(|c| c.is_ascii_uppercase() || c.is_ascii_digit())
            {
                s = rest.trim().to_string();
                break;
            }
        }
    }
    let mut year = None;
    if let Some(open) = s.rfind('(')
        && let Some(close) = s[open..].find(')')
    {
        let inner = &s[open + 1..open + close];
        if inner.len() == 4
            && let Ok(y) = inner.parse::<u32>()
            && (1900..2100).contains(&y)
        {
            year = Some(y);
            s = format!("{}{}", &s[..open], &s[open + close + 1..]);
        }
    }
    const TAGS: [&str; 10] = [
        "4K", "UHD", "FHD", "HD", "SD", "HEVC", "H265", "HDR", "MULTI", "MULTISUB",
    ];
    let words: Vec<&str> = s
        .split_whitespace()
        .filter(|w| {
            !TAGS.contains(
                &w.trim_matches(|c| c == '[' || c == ']')
                    .to_ascii_uppercase()
                    .as_str(),
            )
        })
        .collect();
    (words.join(" "), year)
}

fn http() -> reqwest::Client {
    crate::xtream::ensure_tls_provider();
    reqwest::Client::builder()
        .connect_timeout(Duration::from_secs(10))
        .timeout(Duration::from_secs(30))
        .user_agent(concat!("gerdTV/", env!("CARGO_PKG_VERSION")))
        .build()
        .expect("HTTP client")
}

fn name(s: Service) -> &'static str {
    match s {
        Service::Trakt => "Trakt",
        Service::Simkl => "Simkl",
    }
}

fn now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// Every Simkl call carries these in the query.
fn simkl_query(c: &Client) -> Vec<(&'static str, String)> {
    vec![
        ("client_id", c.client_id.clone()),
        ("app-name", "gerdtv".to_string()),
        ("app-version", env!("CARGO_PKG_VERSION").to_string()),
    ]
}

/// POSTs a JSON (Trakt) or form (Simkl) body; the status and the JSON answer (Null when there is none).
async fn post(c: &Client, path: &str, body: Value, bearer: Option<&str>) -> Result<(u16, Value)> {
    let mut req = http().post(format!("{}{path}", c.base));
    req = match c.service {
        Service::Trakt => req
            .header("Content-Type", "application/json")
            .header("trakt-api-version", "2")
            .header("trakt-api-key", &c.client_id)
            .body(body.to_string()),
        Service::Simkl if path.starts_with("/oauth2/") => {
            let pairs: Vec<(String, String)> = body
                .as_object()
                .into_iter()
                .flatten()
                .map(|(k, v)| (k.clone(), v.as_str().unwrap_or_default().to_string()))
                .collect();
            let refs: Vec<(&str, &str)> = pairs
                .iter()
                .map(|(k, v)| (k.as_str(), v.as_str()))
                .collect();
            req.query(&simkl_query(c))
                .header("Content-Type", "application/x-www-form-urlencoded")
                .body(crate::premiumize::form(&refs))
        }
        Service::Simkl => req
            .query(&simkl_query(c))
            .header("Content-Type", "application/json")
            .body(body.to_string()),
    };
    if let Some(t) = bearer {
        req = req.bearer_auth(t);
    }
    let res = req
        .send()
        .await
        .map_err(|e| TrackError::Network(e.without_url().to_string()))?;
    let status = res.status().as_u16();
    let bytes = res
        .bytes()
        .await
        .map_err(|e| TrackError::Network(e.without_url().to_string()))?;
    Ok((
        status,
        serde_json::from_slice(&bytes).unwrap_or(Value::Null),
    ))
}

fn token(v: &Value) -> Option<Token> {
    let access = v["access_token"].as_str()?.to_string();
    Some(Token {
        access,
        refresh: v["refresh_token"].as_str().unwrap_or_default().to_string(),
        expires_at: now() + v["expires_in"].as_i64().unwrap_or(86_400),
    })
}

/// The device flow, step 1: the code to show and where to type it.
pub async fn device_start(c: &Client) -> Result<DeviceCode> {
    let (status, v) = match c.service {
        Service::Trakt => {
            post(
                c,
                "/oauth/device/code",
                json!({ "client_id": c.client_id }),
                None,
            )
            .await?
        }
        Service::Simkl => {
            let body = json!({ "client_id": c.client_id, "scope": "media:read media:write" });
            post(c, "/oauth2/device", body, None).await?
        }
    };
    if status != 200 {
        return Err(TrackError::Http(name(c.service), status));
    }
    let text = |k: &str| v[k].as_str().unwrap_or_default().to_string();
    let code = DeviceCode {
        device_code: text("device_code"),
        user_code: text("user_code"),
        // Trakt calls it verification_url.
        verification_uri: [text("verification_uri"), text("verification_url")]
            .into_iter()
            .find(|s| !s.is_empty())
            .unwrap_or_default(),
        interval: v["interval"].as_u64().unwrap_or(5).max(1) as u32,
        expires_in: v["expires_in"].as_u64().unwrap_or(600) as u32,
    };
    if code.device_code.is_empty() || code.user_code.is_empty() {
        return Err(TrackError::Parse(name(c.service)));
    }
    Ok(code)
}

/// The device flow, step 2: one poll.
pub async fn device_poll(c: &Client, device_code: &str) -> Result<Poll> {
    let (status, v) = match c.service {
        Service::Trakt => {
            let body = json!({ "code": device_code, "client_id": c.client_id, "client_secret": c.client_secret });
            post(c, "/oauth/device/token", body, None).await?
        }
        Service::Simkl => {
            let body = json!({ "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                               "client_id": c.client_id, "device_code": device_code });
            post(c, "/oauth2/token", body, None).await?
        }
    };
    if status == 200 {
        return token(&v)
            .map(Poll::Token)
            .ok_or(TrackError::Parse(name(c.service)));
    }
    Ok(
        match (c.service, status, v["error"].as_str().unwrap_or_default()) {
            (Service::Trakt, 400, _) | (Service::Simkl, _, "authorization_pending") => {
                Poll::Pending
            }
            (Service::Trakt, 429, _) | (Service::Simkl, _, "slow_down") => Poll::SlowDown,
            (Service::Trakt, 404 | 409 | 410 | 418, _) => Poll::Failed(format!("HTTP {status}")),
            (_, _, e) => Poll::Failed(if e.is_empty() {
                format!("HTTP {status}")
            } else {
                e.to_string()
            }),
        },
    )
}

/// A fresh token before this one runs out (None: still good for more than a minute).
pub async fn refresh(c: &Client, t: &Token) -> Result<Option<Token>> {
    if t.expires_at > now() + 60 || t.refresh.is_empty() {
        return Ok(None);
    }
    let (status, v) = match c.service {
        Service::Trakt => {
            let body = json!({ "refresh_token": t.refresh, "client_id": c.client_id,
                               "client_secret": c.client_secret,
                               "redirect_uri": "urn:ietf:wg:oauth:2.0:oob", "grant_type": "refresh_token" });
            post(c, "/oauth/token", body, None).await?
        }
        Service::Simkl => {
            let body = json!({ "grant_type": "refresh_token", "refresh_token": t.refresh, "client_id": c.client_id });
            post(c, "/oauth2/token", body, None).await?
        }
    };
    if status != 200 {
        return Err(TrackError::Http(name(c.service), status));
    }
    token(&v)
        .map(Some)
        .ok_or(TrackError::Parse(name(c.service)))
}

/// The scrobble body both services read (Simkl's follows Trakt's).
pub fn scrobble_body(w: &Watching, progress: f64) -> Value {
    let progress = (progress.clamp(0.0, 100.0) * 100.0).round() / 100.0;
    let mut body = match w {
        Watching::Movie { title, year, .. } => {
            json!({ "progress": progress, "movie": { "title": title, "year": year } })
        }
        Watching::Episode {
            show,
            season,
            number,
            ..
        } => json!({
            "progress": progress, "show": { "title": show },
            "episode": { "season": season, "number": number }
        }),
    };
    let (what, tmdb) = match w {
        Watching::Movie { tmdb, .. } => ("movie", tmdb),
        Watching::Episode { tmdb, .. } => ("show", tmdb),
    };
    if let Some(id) = tmdb {
        body[what]["ids"] = json!({ "tmdb": id });
    }
    body
}

/// Simkl's GET with its query and the token; the JSON answer.
async fn simkl_get(c: &Client, t: &Token, path: &str, query: &[(&str, String)]) -> Result<Value> {
    let res = http()
        .get(format!("{}{path}", c.base))
        .query(&simkl_query(c))
        .query(query)
        .bearer_auth(&t.access)
        .send()
        .await
        .map_err(|e| TrackError::Network(e.without_url().to_string()))?;
    let status = res.status().as_u16();
    if status != 200 {
        return Err(TrackError::Http("Simkl", status));
    }
    let bytes = res
        .bytes()
        .await
        .map_err(|e| TrackError::Network(e.without_url().to_string()))?;
    serde_json::from_slice(&bytes).map_err(|_| TrackError::Parse("Simkl"))
}

/// One movie, or one episode of a show, as Simkl tells it; `at` in UTC seconds.
#[derive(Debug, Clone, PartialEq)]
pub struct Seen {
    pub watching: Watching,
    pub at: i64,
}

/// A movie or episode paused part-way: `percent` 0–100.
#[derive(Debug, Clone, PartialEq)]
pub struct Paused {
    pub watching: Watching,
    pub percent: f64,
    pub at: i64,
}

/// What changed at Simkl since `since` (its activity time, as it sent it; empty: everything).
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Changes {
    pub seen: Vec<Seen>,
    pub paused: Vec<Paused>,
    /// The activity time to pass as `since` next time.
    pub all: String,
}

/// "2026-05-08T14:23:11Z" (Simkl's times are UTC, Z-suffixed, fractions possible) as UTC seconds; 0 otherwise.
fn utc(s: &str) -> i64 {
    let n = |r: std::ops::Range<usize>| s.get(r)?.parse::<i64>().ok();
    let (Some(y), Some(m), Some(d), Some(h), Some(mi), Some(se)) =
        (n(0..4), n(5..7), n(8..10), n(11..13), n(14..16), n(17..19))
    else {
        return 0;
    };
    if !s.ends_with('Z') || !(1..=12).contains(&m) {
        return 0;
    }
    // Days since 1970-01-01 of the civil date (Howard Hinnant's days_from_civil).
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let doy = (153 * ((m + 9) % 12) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146_097 + doe - 719_468;
    days * 86_400 + h * 3600 + mi * 60 + se
}

fn tmdb_of(v: &Value) -> Option<u64> {
    let id = &v["ids"]["tmdb"];
    id.as_u64().or_else(|| id.as_str()?.parse().ok())
}

fn movie_of(v: &Value) -> Watching {
    Watching::Movie {
        title: v["title"].as_str().unwrap_or_default().to_string(),
        year: v["year"].as_u64().map(|y| y as u32),
        tmdb: tmdb_of(v),
    }
}

/// Simkl's watched movies and episodes and paused playbacks since `since`, by its rules: activities first, and
/// nothing more when they haven't moved (api.simkl.org, "Sync"). None: nothing changed.
pub async fn simkl_changes(c: &Client, t: &Token, since: &str) -> Result<Option<Changes>> {
    let activities = simkl_get(c, t, "/sync/activities", &[]).await?;
    let all = activities["all"].as_str().unwrap_or_default().to_string();
    if all == since && !since.is_empty() {
        return Ok(None);
    }
    let from: Vec<(&str, String)> = if since.is_empty() {
        vec![]
    } else {
        vec![("date_from", since.to_string())]
    };
    let mut out = Changes {
        all,
        ..Default::default()
    };
    let movies = simkl_get(c, t, "/sync/all-items/movies/completed", &from).await?;
    for m in movies["movies"].as_array().into_iter().flatten() {
        out.seen.push(Seen {
            watching: movie_of(&m["movie"]),
            at: utc(m["last_watched_at"].as_str().unwrap_or_default()),
        });
    }
    // Episodes: only with these three modifiers, also of completed shows (Simkl's guide, "Useful query params").
    let mut query = from.clone();
    query.extend([
        ("extended", "full".to_string()),
        ("episode_watched_at", "yes".to_string()),
        ("include_all_episodes", "original".to_string()),
    ]);
    let shows = simkl_get(c, t, "/sync/all-items/shows", &query).await?;
    for s in shows["shows"].as_array().into_iter().flatten() {
        let show = &s["show"];
        for season in s["seasons"].as_array().into_iter().flatten() {
            for e in season["episodes"].as_array().into_iter().flatten() {
                let at = e["watched_at"].as_str().map_or(0, utc);
                if at == 0 {
                    continue; // not watched
                }
                out.seen.push(Seen {
                    watching: Watching::Episode {
                        show: show["title"].as_str().unwrap_or_default().to_string(),
                        season: season["number"].as_u64().unwrap_or(0) as u32,
                        number: e["number"].as_u64().unwrap_or(0) as u32,
                        tmdb: tmdb_of(show),
                    },
                    at,
                });
            }
        }
    }
    let playback = simkl_get(c, t, "/sync/playback", &[]).await?;
    for p in playback.as_array().into_iter().flatten() {
        let at = ["paused_at", "watched_at"]
            .iter()
            .find_map(|k| p[*k].as_str())
            .map_or(0, utc);
        let watching = if p["movie"].is_object() {
            movie_of(&p["movie"])
        } else {
            let e = &p["episode"];
            Watching::Episode {
                show: p["show"]["title"].as_str().unwrap_or_default().to_string(),
                season: e["season"].as_u64().unwrap_or(0) as u32,
                number: e["number"].as_u64().or(e["episode"].as_u64()).unwrap_or(0) as u32,
                tmdb: tmdb_of(&p["show"]),
            }
        };
        if let Some(percent) = p["progress"].as_f64() {
            out.paused.push(Paused {
                watching,
                percent,
                at,
            });
        }
    }
    Ok(Some(out))
}

/// A movie or episode marked as watched by hand (or unmarked) goes to Simkl's history too.
pub async fn simkl_history(c: &Client, t: &Token, w: &Watching, watched: bool) -> Result<()> {
    let ids = |title: &str, tmdb: &Option<u64>| match tmdb {
        Some(id) => json!({ "title": title, "ids": { "tmdb": id } }),
        None => json!({ "title": title }),
    };
    let body = match w {
        Watching::Movie { title, year, tmdb } => {
            let mut m = ids(title, tmdb);
            m["year"] = json!(year);
            json!({ "movies": [m] })
        }
        Watching::Episode {
            show,
            season,
            number,
            tmdb,
        } => {
            let mut s = ids(show, tmdb);
            s["seasons"] = json!([{ "number": season, "episodes": [{ "number": number }] }]);
            json!({ "shows": [s] })
        }
    };
    let path = if watched {
        "/sync/history"
    } else {
        "/sync/history/remove"
    };
    let (status, _) = post(c, path, body, Some(&t.access)).await?;
    match status {
        200..=299 => Ok(()),
        s => Err(TrackError::Http("Simkl", s)),
    }
}

/// Tells the service what plays; Ok also for Trakt's and Simkl's 409 (that one was scrobbled a moment ago).
pub async fn scrobble(
    c: &Client,
    t: &Token,
    action: Action,
    w: &Watching,
    progress: f64,
) -> Result<()> {
    let path = match action {
        Action::Start => "/scrobble/start",
        Action::Pause => "/scrobble/pause",
        Action::Stop => "/scrobble/stop",
    };
    let (status, _) = post(c, path, scrobble_body(w, progress), Some(&t.access)).await?;
    match status {
        200..=299 | 409 => Ok(()),
        s => Err(TrackError::Http(name(c.service), s)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use gerdtv_testkit::mock_tracking::{CLIENT_ID, MockTracking, SECRET};

    #[test]
    fn titles_lose_the_panels_decorations() {
        for (raw, want) in [
            ("DE - Inception (2010) 4K", ("Inception", Some(2010))),
            ("EN: The Matrix (1999)", ("The Matrix", Some(1999))),
            ("|DE| Das Boot [HD]", ("Das Boot", None)),
            (
                "Blade Runner 2049 (2017)",
                ("Blade Runner 2049", Some(2017)),
            ),
            (
                "M - Eine Stadt sucht einen Mörder",
                ("M - Eine Stadt sucht einen Mörder", None),
            ),
            ("Alien (Director's Cut)", ("Alien (Director's Cut)", None)),
        ] {
            let (t, y) = clean_title(raw);
            assert_eq!((t.as_str(), y), want, "{raw}");
        }
    }

    #[test]
    fn scrobble_bodies() {
        let m = Watching::Movie {
            title: "Inception".into(),
            year: Some(2010),
            tmdb: None,
        };
        assert_eq!(
            scrobble_body(&m, 12.3456),
            json!({ "progress": 12.35, "movie": { "title": "Inception", "year": 2010 } })
        );
        let e = Watching::Episode {
            show: "Dark".into(),
            season: 1,
            number: 3,
            tmdb: Some(70523),
        };
        assert_eq!(
            scrobble_body(&e, 120.0)["episode"],
            json!({ "season": 1, "number": 3 })
        );
        assert_eq!(scrobble_body(&e, 120.0)["progress"], 100.0);
        assert_eq!(
            scrobble_body(&e, 1.0)["show"]["ids"],
            json!({ "tmdb": 70523 })
        );
        assert_eq!(utc("1970-01-02T00:00:01Z"), 86_401);
        assert_eq!(utc("2026-05-08T14:23:11.512Z"), 1_778_250_191);
        assert_eq!(utc("yesterday"), 0);
    }

    #[tokio::test]
    async fn link_refresh_and_scrobble_with_both() {
        let mock = MockTracking::start().await;
        for service in [Service::Trakt, Service::Simkl] {
            let c = Client {
                service,
                base: mock.base(),
                client_id: CLIENT_ID.into(),
                client_secret: SECRET.into(),
            };
            let code = device_start(&c).await.unwrap();
            assert!(
                !code.user_code.is_empty() && !code.verification_uri.is_empty(),
                "{service:?}"
            );
            assert_eq!(
                device_poll(&c, &code.device_code).await.unwrap(),
                Poll::Pending,
                "{service:?}"
            );
            mock.confirm();
            let Poll::Token(t) = device_poll(&c, &code.device_code).await.unwrap() else {
                panic!("{service:?}: no token")
            };
            assert_eq!(refresh(&c, &t).await.unwrap(), None, "fresh: kept");
            let old = Token {
                expires_at: 0,
                ..t.clone()
            };
            let new = refresh(&c, &old)
                .await
                .unwrap()
                .expect("expired: refreshed");
            assert_ne!(new.access, t.access);
            let w = Watching::Movie {
                title: "Inception".into(),
                year: Some(2010),
                tmdb: None,
            };
            scrobble(&c, &new, Action::Start, &w, 0.0).await.unwrap();
            scrobble(&c, &new, Action::Stop, &w, 91.0).await.unwrap();
            let bad = Token {
                access: "wrong".into(),
                ..new
            };
            assert!(scrobble(&c, &bad, Action::Pause, &w, 5.0).await.is_err());
            mock.reset();
        }
        let seen = mock.scrobbles();
        assert_eq!(seen.len(), 4, "start and stop per service: {seen:?}");
        assert_eq!(seen[1]["progress"], 91.0);
    }
}
