//! Xtream Codes client and sync (the main source). Talks to `player_api.php` like every XC panel:
//! account info first (auth, status, expiry, max_connections), then the three category lists (shown at once), then
//! the three stream lists, written into the profile database in one transaction (db::Sync).
//!
//! Credentials never leave this struct: error messages drop the request URL (reqwest's `without_url`), stream URLs
//! are built on demand (`stream_url`) and never stored. Panel quirks handled: numbers sent as strings, empty strings
//! for missing values, `null` EPG ids, unknown ids answered with `[]`.
//!
//! Debug hints: `XcError::Auth` = the panel said auth 0 (wrong login); `Expired` = status/expiry; a `Parse` error
//! names the action whose JSON didn't match (log the body length, never the body: it can hold the login).

use crate::db::{self, Kind, NewItem};
use rusqlite::Connection;
use serde_json::Value;
use std::time::Duration;

#[derive(Debug, thiserror::Error)]
pub enum XcError {
    #[error("the server rejected the login")]
    Auth,
    #[error("the account has expired or is disabled ({0})")]
    Expired(String),
    #[error("the server answered HTTP {0}")]
    Http(u16),
    #[error("network error: {0}")]
    Network(String),
    #[error("unexpected answer to {0}")]
    Parse(&'static str),
    #[error("database error: {0}")]
    Db(#[from] rusqlite::Error),
}

pub type Result<T> = std::result::Result<T, XcError>;

/// What the panel says about the account.
#[derive(Debug, Clone, PartialEq)]
pub struct Account {
    pub status: String,
    /// Unix seconds; None = no expiry.
    pub expires: Option<i64>,
    pub max_connections: u32,
    pub active_connections: u32,
    /// The server's clock against UTC in seconds (its local time − UTC, in 15-minute steps; 0 when it doesn't say):
    /// catch-up URLs name the start in the server's local time.
    pub time_offset: i64,
}

pub struct Xtream {
    http: reqwest::Client,
    base: String,
    user: String,
    pass: String,
}

/// reqwest is built without a TLS provider; install rustls' ring provider once per process.
pub(crate) fn ensure_tls_provider() {
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| {
        let _ = rustls::crypto::ring::default_provider().install_default(); // Err = another one is installed: fine
    });
}

/// A number the panel may send as a number, a numeric string, or "".
fn num(v: &Value) -> Option<u64> {
    match v {
        Value::Number(n) => n.as_u64().or_else(|| n.as_f64().map(|f| f as u64)),
        Value::String(s) => s.trim().parse().ok(),
        _ => None,
    }
}

fn text(v: &Value) -> String {
    match v {
        Value::String(s) => s.clone(),
        Value::Number(n) => n.to_string(),
        _ => String::new(),
    }
}

impl Xtream {
    /// `base` as the user typed it ("http://host:port", trailing slash and path tolerated).
    pub fn new(base: &str, user: &str, pass: &str, user_agent: Option<&str>) -> Xtream {
        ensure_tls_provider();
        let base = base
            .trim()
            .trim_end_matches('/')
            .trim_end_matches("/player_api.php")
            .to_string();
        let mut b = reqwest::Client::builder()
            .connect_timeout(Duration::from_secs(10))
            .timeout(Duration::from_secs(120));
        if let Some(ua) = user_agent.filter(|u| !u.is_empty()) {
            b = b.user_agent(ua.to_string());
        }
        Xtream {
            http: b.build().expect("HTTP client"),
            base,
            user: user.to_string(),
            pass: pass.to_string(),
        }
    }

    async fn api(&self, action: Option<&'static str>, extra: &[(&str, String)]) -> Result<Value> {
        let mut query: Vec<(&str, String)> = vec![
            ("username", self.user.clone()),
            ("password", self.pass.clone()),
        ];
        if let Some(a) = action {
            query.push(("action", a.to_string()));
        }
        query.extend(extra.iter().map(|(k, v)| (*k, v.clone())));
        let res = self
            .http
            .get(format!("{}/player_api.php", self.base))
            .query(&query)
            .send()
            .await
            .map_err(|e| XcError::Network(e.without_url().to_string()))?;
        if !res.status().is_success() {
            return Err(XcError::Http(res.status().as_u16()));
        }
        let bytes = res
            .bytes()
            .await
            .map_err(|e| XcError::Network(e.without_url().to_string()))?;
        serde_json::from_slice(&bytes).map_err(|_| XcError::Parse(action.unwrap_or("account info")))
    }

    /// Account info; `Auth` or `Expired` errors are hard errors (no retry loops, the user must act).
    pub async fn account(&self) -> Result<Account> {
        let v = self.api(None, &[]).await?;
        let u = &v["user_info"];
        if num(&u["auth"]) != Some(1) {
            return Err(XcError::Auth);
        }
        let status = text(&u["status"]);
        let expires = num(&u["exp_date"]).map(|e| e as i64);
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs() as i64)
            .unwrap_or(0);
        if status != "Active" || expires.is_some_and(|e| e < now) {
            return Err(XcError::Expired(status));
        }
        Ok(Account {
            status,
            expires,
            max_connections: num(&u["max_connections"]).unwrap_or(1) as u32,
            active_connections: num(&u["active_cons"]).unwrap_or(0) as u32,
            time_offset: server_offset(&v["server_info"]),
        })
    }

    /// The category lists for live, movies and series, in provider order: (kind, id, name).
    pub async fn categories(&self) -> Result<Vec<(Kind, String, String)>> {
        let mut out = Vec::new();
        for (kind, action) in [
            (Kind::Live, "get_live_categories"),
            (Kind::Movie, "get_vod_categories"),
            (Kind::Series, "get_series_categories"),
        ] {
            let v = self.api(Some(action), &[]).await?;
            for c in v.as_array().ok_or(XcError::Parse(action))? {
                out.push((kind, text(&c["category_id"]), text(&c["category_name"])));
            }
        }
        Ok(out)
    }

    /// All streams of one kind (Live, Movie or Series) as catalogue rows.
    pub async fn streams(&self, kind: Kind) -> Result<Vec<NewItem>> {
        let action = match kind {
            Kind::Live => "get_live_streams",
            Kind::Movie => "get_vod_streams",
            _ => "get_series",
        };
        let v = self.api(Some(action), &[]).await?;
        let list = v.as_array().ok_or(XcError::Parse(action))?;
        Ok(list
            .iter()
            .filter_map(|s| {
                let (prefix, id) = match kind {
                    Kind::Live => ("live", num(&s["stream_id"])?),
                    Kind::Movie => ("movie", num(&s["stream_id"])?),
                    _ => ("series", num(&s["series_id"])?),
                };
                let name = text(&s["name"]);
                let year = name
                    .rfind('(')
                    .and_then(|i| name[i + 1..].get(..4))
                    .and_then(|y| y.parse().ok())
                    .filter(|y| (1900..2100).contains(y));
                Some(NewItem {
                    key: format!("{prefix}:{id}"),
                    category: text(&s["category_id"]),
                    logo: text(if kind == Kind::Series {
                        &s["cover"]
                    } else {
                        &s["stream_icon"]
                    }),
                    epg_id: text(&s["epg_channel_id"]),
                    archive_days: if kind == Kind::Live && num(&s["tv_archive"]) == Some(1) {
                        num(&s["tv_archive_duration"]).unwrap_or(0) as u32
                    } else {
                        0
                    },
                    number: if kind == Kind::Live {
                        num(&s["num"]).map(|n| n as u32)
                    } else {
                        None
                    },
                    year,
                    name,
                    ..NewItem::default()
                })
            })
            .collect())
    }

    /// A series' episodes (get_series_info), as catalogue rows with `category` = the series key, in season and
    /// episode order. Fetched lazily when a series opens.
    pub async fn episodes(&self, series_id: u64) -> Result<Vec<NewItem>> {
        let v = self
            .api(
                Some("get_series_info"),
                &[("series_id", series_id.to_string())],
            )
            .await?;
        let mut out = Vec::new();
        if let Some(seasons) = v["episodes"].as_object() {
            for list in seasons.values() {
                for e in list.as_array().into_iter().flatten() {
                    let Some(id) = num(&e["id"]) else { continue };
                    out.push(NewItem {
                        key: format!("episode:{id}"),
                        name: text(&e["title"]),
                        category: format!("series:{series_id}"),
                        logo: text(&e["info"]["movie_image"]),
                        season: num(&e["season"]).map(|n| n as u32),
                        episode: num(&e["episode_num"]).map(|n| n as u32),
                        ext: text(&e["container_extension"]),
                        ..NewItem::default()
                    });
                }
            }
        }
        out.sort_by_key(|e| (e.season, e.episode));
        Ok(out)
    }

    /// The panel's own guide (XMLTV), built when needed and never stored (it holds the login).
    pub fn xmltv_url(&self) -> String {
        format!(
            "{}/xmltv.php?username={}&password={}",
            self.base, self.user, self.pass
        )
    }

    /// The catch-up URL of a live channel's archive: `duration` minutes from `start` (UTC seconds), the start named
    /// in the server's local time (`time_offset` from the account): /timeshift/<user>/<pass>/<minutes>/
    /// <YYYY-MM-DD:HH-MM>/<id>.ts. `just test-live` checks a real panel answers it with MPEG-TS (it may start
    /// mid-packet); that the start minute is right shows only by watching (docs/DEVICE_CHECKS.md).
    pub fn catchup_url(
        &self,
        stream_id: u64,
        start: i64,
        minutes: u32,
        time_offset: i64,
    ) -> String {
        format!(
            "{}/timeshift/{}/{}/{minutes}/{}/{stream_id}.ts",
            self.base,
            self.user,
            self.pass,
            server_time(start + time_offset)
        )
    }

    /// The play URL of a stream (built at play time, never stored). Live defaults to `.ts`; the watchdog may ask
    /// for `m3u8` instead. Movies/episodes use their container extension.
    pub fn stream_url(&self, kind: Kind, id: u64, ext: &str) -> String {
        let dir = match kind {
            Kind::Live => "live",
            Kind::Movie => "movie",
            _ => "series",
        };
        format!("{}/{dir}/{}/{}/{id}.{ext}", self.base, self.user, self.pass)
    }
}

/// Everything a sync downloads, before anything is written (network first, then one short write).
pub struct Fetched {
    pub account: Account,
    pub categories: Vec<(Kind, String, String)>,
    pub lists: Vec<(Kind, Vec<NewItem>)>,
}

/// Downloads account, categories and every stream list. No database access, so it can run without holding the
/// profile's connection (the UI keeps browsing the cached catalogue meanwhile).
pub async fn fetch(xc: &Xtream) -> Result<Fetched> {
    let account = xc.account().await?;
    let categories = xc.categories().await?;
    let mut lists = Vec::new();
    for kind in [Kind::Live, Kind::Movie, Kind::Series] {
        lists.push((kind, xc.streams(kind).await?));
    }
    Ok(Fetched {
        account,
        categories,
        lists,
    })
}

/// Writes a fetch into the catalogue in one transaction (db::Sync).
pub fn write(conn: &mut Connection, f: &Fetched) -> Result<db::ImportStats> {
    let mut s = db::Sync::begin(conn)?;
    for (kind, id, name) in &f.categories {
        s.category(*kind, id, name);
    }
    let mut stats = db::ImportStats {
        categories: f.categories.len(),
        ..Default::default()
    };
    for (kind, items) in &f.lists {
        if items.is_empty() {
            let kept = s.keep_kind(*kind)?;
            if kept > 0 {
                tracing::warn!("{kind:?} list came back empty; keeping the {kept} known entries");
            }
        }
        for it in items {
            s.item(*kind, it)?;
            stats.entries += 1;
        }
    }
    stats.removed = s.finish()?;
    Ok(stats)
}

/// A full sync: fetch, then write.
pub async fn sync(conn: &mut Connection, xc: &Xtream) -> Result<(Account, db::ImportStats)> {
    let f = fetch(xc).await?;
    let stats = write(conn, &f)?;
    Ok((f.account, stats))
}

/// The server's offset from UTC: its `time_now` (local, "YYYY-MM-DD HH:MM:SS") against `timestamp_now` (UTC),
/// rounded to 15 minutes; 0 when either is missing.
fn server_offset(info: &Value) -> i64 {
    let digits: String = text(&info["time_now"])
        .chars()
        .filter(char::is_ascii_digit)
        .collect();
    match (crate::epg::parse_time(&digits), num(&info["timestamp_now"])) {
        (Some(local), Some(utc)) => ((local - utc as i64) as f64 / 900.0).round() as i64 * 900,
        _ => 0,
    }
}

/// "YYYY-MM-DD:HH-MM" for seconds since the epoch, as the timeshift URL wants it (civil_from_days, H. Hinnant).
fn server_time(secs: i64) -> String {
    let days = secs.div_euclid(86_400);
    let rem = secs.rem_euclid(86_400);
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + i64::from(m <= 2);
    format!(
        "{y:04}-{m:02}-{d:02}:{:02}-{:02}",
        rem / 3600,
        rem % 3600 / 60
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use gerdtv_testkit::mock_xc::{MockXc, PASS, USER};
    use std::path::Path;

    #[test]
    fn catch_up_times_follow_the_server_clock() {
        // (UTC seconds, the server's local time as the timeshift URL names it) for an offset of +1 h.
        let table = [
            (1_763_830_800, "2025-11-22:18-00"), // 17:00 UTC
            (1_767_222_000, "2026-01-01:00-00"), // the year changes in local time only
            (951_825_600, "2000-02-29:13-00"),   // leap day
        ];
        for (utc, want) in table {
            assert_eq!(server_time(utc + 3600), want, "{utc}");
        }
        // The offset: local time_now against UTC timestamp_now, in 15-minute steps, 0 without both.
        let info = |now: &str, ts: i64| serde_json::json!({"time_now": now, "timestamp_now": ts});
        assert_eq!(
            server_offset(&info("2025-11-22 18:00:07", 1_763_830_800)),
            3600
        );
        assert_eq!(
            server_offset(&info("2025-11-22 22:29:50", 1_763_830_800)),
            5 * 3600 + 1800
        );
        assert_eq!(server_offset(&serde_json::json!({})), 0);
        let xc = Xtream::new("http://xc.example.invalid:8080", "u", "p", None);
        assert_eq!(
            xc.catchup_url(42, 1_763_830_800, 90, 3600),
            "http://xc.example.invalid:8080/timeshift/u/p/90/2025-11-22:18-00/42.ts"
        );
    }

    #[tokio::test]
    async fn syncs_from_a_panel_and_reports_hard_errors() {
        let mock = MockXc::start(2000, 5).await;
        let xc = Xtream::new(&format!("{}/", mock.base()), USER, PASS, None);
        let mut conn = db::open(Path::new(":memory:")).unwrap();
        let (account, stats) = sync(&mut conn, &xc).await.unwrap();
        assert_eq!(
            (account.max_connections, account.status.as_str()),
            (2, "Active")
        );
        // 600 live + 1000 movies + the series (episodes are fetched lazily per series).
        let live: i64 = conn
            .query_row("SELECT count(*) FROM items WHERE kind = 0", [], |r| {
                r.get(0)
            })
            .unwrap();
        let movies: i64 = conn
            .query_row("SELECT count(*) FROM items WHERE kind = 1", [], |r| {
                r.get(0)
            })
            .unwrap();
        assert_eq!((live, movies), (600, 1000));
        assert!(stats.categories > 3 && stats.entries > 1600);
        let year: Option<u32> = conn
            .query_row("SELECT year FROM items WHERE kind = 1 LIMIT 1", [], |r| {
                r.get(0)
            })
            .unwrap();
        assert!(year.is_some_and(|y| (1960..2030).contains(&y)));
        assert!(!db::search(&conn, "munchen", None, 5, 0).unwrap().is_empty());

        // Stream URLs are built, not stored.
        let url: String = conn
            .query_row("SELECT url FROM items WHERE key = 'live:100000'", [], |r| {
                r.get(0)
            })
            .unwrap();
        assert_eq!(url, "");
        assert_eq!(
            xc.stream_url(Kind::Live, 100000, "ts"),
            format!("{}/live/{USER}/{PASS}/100000.ts", mock.base())
        );

        // A panel hiccup that answers [] for a whole list must not wipe that part of the catalogue.
        mock.empty_once("get_vod_streams");
        let (_, again) = sync(&mut conn, &xc).await.unwrap();
        let movies_after: i64 = conn
            .query_row("SELECT count(*) FROM items WHERE kind = 1", [], |r| {
                r.get(0)
            })
            .unwrap();
        assert_eq!((movies_after, again.removed), (1000, 0));

        // Hard errors: wrong login, expired account. The message never carries the credentials.
        let bad = Xtream::new(&mock.base(), USER, "wrong", None);
        assert!(matches!(bad.account().await, Err(XcError::Auth)));
        mock.set_expired(true);
        let e = xc.account().await.unwrap_err();
        assert!(matches!(e, XcError::Expired(ref s) if s == "Expired"));
        let down = Xtream::new("http://127.0.0.1:9", USER, PASS, None);
        let e = down.account().await.unwrap_err().to_string();
        assert!(
            e.starts_with("network error") && !e.contains(PASS) && !e.contains(USER),
            "{e}"
        );
    }
}
