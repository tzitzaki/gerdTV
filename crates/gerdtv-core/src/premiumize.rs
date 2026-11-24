//! Premiumize (owner request: a debrid account as a source): the user's own cloud, browsed folder by folder, with
//! its transfers; files play from their direct `link`. API: https://www.premiumize.me/api (v1, JSON).
//!
//! Sign-in: the account's API key (premiumize.me/account), or the OAuth device flow (premiumize.me/device, a code
//! typed on another device) once gerdTV has a registered client id (`--dart-define=GERDTV_PREMIUMIZE_CLIENT_ID`).
//! Both give a token sent as `Authorization: Bearer`; it is a secret: kept in the app's secure storage, held only
//! in memory here, never logged.
//!
//! Debug hints: Premiumize answers business errors with HTTP 200 and `{"status":"error","message":…}`, which
//! becomes `PmError::Api(message)`; `authentication_failed` means the key or token is no longer valid.

use serde_json::Value;
use std::time::Duration;

/// The service's address (tests pass the mock's).
pub const BASE: &str = "https://www.premiumize.me";

#[derive(Debug, thiserror::Error)]
pub enum PmError {
    #[error("Premiumize: {0}")]
    Api(String),
    #[error("Premiumize answered HTTP {0}")]
    Http(u16),
    #[error("network error: {0}")]
    Network(String),
    #[error("unexpected answer from Premiumize")]
    Parse,
}

pub type Result<T> = std::result::Result<T, PmError>;

/// A folder or file of the cloud.
#[derive(Debug, Clone, PartialEq)]
pub struct Entry {
    pub id: String,
    pub name: String,
    pub folder: bool,
    pub size: u64,
    pub mime: String,
    /// The file's direct link (playable by mpv); "" for folders.
    pub link: String,
}

/// A transfer (a download into the cloud).
#[derive(Debug, Clone, PartialEq)]
pub struct Transfer {
    pub id: String,
    pub name: String,
    /// queued, running, finished, seeding or error.
    pub status: String,
    /// 0–1.
    pub progress: f64,
    pub message: String,
    /// Where it landed once finished: a folder, or a single file.
    pub folder_id: String,
    pub file_id: String,
}

/// The device flow's first answer: show `user_code` and `verification_uri`, then poll with `device_code`.
#[derive(Debug, Clone, PartialEq)]
pub struct DeviceCode {
    pub device_code: String,
    pub user_code: String,
    pub verification_uri: String,
    pub interval: u32,
    pub expires_in: u32,
}

/// One poll of the device flow.
#[derive(Debug, Clone, PartialEq)]
pub enum DevicePoll {
    /// Not confirmed yet: ask again after the interval.
    Pending,
    /// Asked too often: wait 5 s longer.
    SlowDown,
    /// Confirmed: the token.
    Token(String),
    /// Refused, or the code expired: start again.
    Failed(String),
}

fn text(v: &Value) -> String {
    match v {
        Value::String(s) => s.clone(),
        Value::Number(n) => n.to_string(),
        _ => String::new(),
    }
}

fn client() -> reqwest::Client {
    crate::xtream::ensure_tls_provider();
    reqwest::Client::builder()
        .connect_timeout(Duration::from_secs(10))
        .timeout(Duration::from_secs(60))
        .build()
        .expect("HTTP client")
}

fn network(e: reqwest::Error) -> PmError {
    PmError::Network(e.without_url().to_string())
}

/// A form body (reqwest's `form` needs a feature the workspace doesn't enable for two calls); everything but
/// letters, digits and `-._~` is percent-encoded.
pub(crate) fn form(pairs: &[(&str, &str)]) -> String {
    let enc = |s: &str| {
        s.bytes()
            .map(|b| match b {
                b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => {
                    (b as char).to_string()
                }
                _ => format!("%{b:02X}"),
            })
            .collect::<String>()
    };
    pairs
        .iter()
        .map(|(k, v)| format!("{}={}", enc(k), enc(v)))
        .collect::<Vec<_>>()
        .join("&")
}

async fn post_token(base: &str, pairs: &[(&str, &str)]) -> Result<(u16, Value)> {
    let res = client()
        .post(format!("{base}/token"))
        .header("Content-Type", "application/x-www-form-urlencoded")
        .body(form(pairs))
        .send()
        .await
        .map_err(network)?;
    let status = res.status().as_u16();
    let bytes = res.bytes().await.map_err(network)?;
    Ok((
        status,
        serde_json::from_slice(&bytes).map_err(|_| PmError::Parse)?,
    ))
}

/// The device flow, step 1 (`client_id` is gerdTV's registered one).
pub async fn device_start(base: &str, client_id: &str) -> Result<DeviceCode> {
    let (status, v) = post_token(
        base,
        &[("response_type", "device_code"), ("client_id", client_id)],
    )
    .await?;
    if status != 200 {
        return Err(PmError::Http(status));
    }
    let num = |k: &str, default| v[k].as_u64().map_or(default, |n| n as u32);
    let code = DeviceCode {
        device_code: text(&v["device_code"]),
        user_code: text(&v["user_code"]),
        verification_uri: text(&v["verification_uri"]),
        interval: num("interval", 5).max(5),
        expires_in: num("expires_in", 600),
    };
    if code.device_code.is_empty() || code.user_code.is_empty() {
        return Err(PmError::Parse);
    }
    Ok(code)
}

/// The device flow, step 2: one poll (the caller waits `interval` seconds between them).
pub async fn device_poll(base: &str, client_id: &str, device_code: &str) -> Result<DevicePoll> {
    // Pending and refusals come as HTTP 400 with an OAuth error name.
    let (_, v) = post_token(
        base,
        &[
            ("grant_type", "device_code"),
            ("code", device_code),
            ("client_id", client_id),
        ],
    )
    .await?;
    let token = text(&v["access_token"]);
    if !token.is_empty() {
        return Ok(DevicePoll::Token(token));
    }
    Ok(match v["error"].as_str().unwrap_or_default() {
        "authorization_pending" => DevicePoll::Pending,
        "slow_down" => DevicePoll::SlowDown,
        other => DevicePoll::Failed(other.to_string()),
    })
}

/// The signed-in account.
pub struct Premiumize {
    http: reqwest::Client,
    base: String,
    token: String,
}

impl Premiumize {
    pub fn new(base: &str, token: &str) -> Premiumize {
        Premiumize {
            http: client(),
            base: base.trim_end_matches('/').to_string(),
            token: token.trim().to_string(),
        }
    }

    async fn get(&self, path: &str, query: &[(&str, &str)]) -> Result<Value> {
        let res = self
            .http
            .get(format!("{}/api/{path}", self.base))
            .bearer_auth(&self.token)
            .query(query)
            .send()
            .await
            .map_err(network)?;
        if !res.status().is_success() {
            return Err(PmError::Http(res.status().as_u16()));
        }
        let bytes = res.bytes().await.map_err(network)?;
        let v: Value = serde_json::from_slice(&bytes).map_err(|_| PmError::Parse)?;
        if v["status"] == "error" {
            return Err(PmError::Api(text(&v["message"])));
        }
        Ok(v)
    }

    /// Checks the key or token: premium until (UTC seconds), or None for a free account.
    pub async fn account(&self) -> Result<Option<i64>> {
        let v = self.get("account/info", &[]).await?;
        Ok(v["premium_until"].as_i64())
    }

    /// A folder's content (None: the cloud's root), folders first, then by name as Premiumize sorts them.
    pub async fn folder(&self, id: Option<&str>) -> Result<Vec<Entry>> {
        let query: Vec<(&str, &str)> = id.map(|i| ("id", i)).into_iter().collect();
        let v = self.get("folder/list", &query).await?;
        let mut out: Vec<Entry> = v["content"]
            .as_array()
            .ok_or(PmError::Parse)?
            .iter()
            .map(|e| Entry {
                id: text(&e["id"]),
                name: text(&e["name"]),
                folder: e["type"] == "folder",
                size: e["size"].as_u64().unwrap_or(0),
                mime: text(&e["mime_type"]),
                link: text(&e["link"]),
            })
            .collect();
        out.sort_by_key(|e| !e.folder); // stable: Premiumize's order within each
        Ok(out)
    }

    /// The transfers, newest first.
    pub async fn transfers(&self) -> Result<Vec<Transfer>> {
        let v = self.get("transfer/list", &[]).await?;
        Ok(v["transfers"]
            .as_array()
            .ok_or(PmError::Parse)?
            .iter()
            .map(|t| Transfer {
                id: text(&t["id"]),
                name: text(&t["name"]),
                status: text(&t["status"]),
                progress: t["progress"].as_f64().unwrap_or(0.0).clamp(0.0, 1.0),
                message: text(&t["message"]),
                folder_id: text(&t["folder_id"]),
                file_id: text(&t["file_id"]),
            })
            .collect())
    }
}

/// Whether a cloud file is something to play (video or audio by MIME type, or by extension when that's missing).
pub fn playable(e: &Entry) -> bool {
    if e.folder || e.link.is_empty() {
        return false;
    }
    if e.mime.starts_with("video/") || e.mime.starts_with("audio/") {
        return true;
    }
    let ext = e.name.rsplit('.').next().unwrap_or("").to_ascii_lowercase();
    [
        "mkv", "mp4", "avi", "mov", "m4v", "ts", "webm", "mp3", "flac", "m4a",
    ]
    .contains(&ext.as_str())
}

#[cfg(test)]
mod tests {
    use super::*;
    use gerdtv_testkit::mock_premiumize::{CLIENT_ID, KEY, MockPremiumize};

    #[tokio::test]
    async fn browses_the_cloud_and_its_transfers() {
        let mock = MockPremiumize::start().await;
        let pm = Premiumize::new(&mock.base(), KEY);
        assert!(pm.account().await.unwrap().is_some());
        let root = pm.folder(None).await.unwrap();
        assert_eq!(
            root.iter()
                .map(|e| (e.name.as_str(), e.folder))
                .collect::<Vec<_>>(),
            [
                ("Films", true),
                ("Notes.txt", false),
                ("Show.S01E01.mkv", false)
            ],
            "folders first"
        );
        assert!(playable(&root[2]) && !playable(&root[1]) && !playable(&root[0]));
        let films = pm.folder(Some(&root[0].id)).await.unwrap();
        assert_eq!(films[0].name, "A Film (2019).mp4");
        assert!(films[0].link.starts_with("https://"));
        let t = pm.transfers().await.unwrap();
        assert_eq!((t[0].status.as_str(), t[0].progress), ("running", 0.42));
        // A wrong key is Premiumize's error, by its message.
        let bad = Premiumize::new(&mock.base(), "wrong");
        assert!(matches!(bad.folder(None).await, Err(PmError::Api(m)) if m.contains("auth")));
    }

    #[tokio::test]
    async fn device_flow_pending_then_token() {
        let mock = MockPremiumize::start().await;
        let code = device_start(&mock.base(), CLIENT_ID).await.unwrap();
        assert_eq!(code.verification_uri, "https://www.premiumize.me/device");
        assert!(code.interval >= 5);
        let base = mock.base();
        let poll = || device_poll(&base, CLIENT_ID, &code.device_code);
        assert_eq!(poll().await.unwrap(), DevicePoll::Pending);
        mock.confirm();
        assert_eq!(poll().await.unwrap(), DevicePoll::Token(KEY.to_string()));
        assert_eq!(form(&[("a b", "x/y&z")]), "a%20b=x%2Fy%26z");
        assert!(matches!(
            device_poll(&mock.base(), CLIENT_ID, "unknown").await.unwrap(),
            DevicePoll::Failed(e) if e == "invalid_grant"
        ));
    }
}
