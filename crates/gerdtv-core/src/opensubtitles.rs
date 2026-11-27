//! OpenSubtitles (REST API v1, api.opensubtitles.com), opt-in with the user's own API key: the player's subtitle
//! sheet finds subtitles for the running movie or episode and loads the chosen one into mpv (`sub-add`).
//!
//! The rules, from its published API definition: every call carries the `Api-Key` header; a download counts against
//! the key's free allowance (5 per IP and day) unless an `Authorization: Bearer` token from POST /login names the
//! user whose quota applies. Login is "expensive" and rate-limited (1 per second, 30 per hour): the app logs in once
//! per run and keeps the token in memory. Search by TMDB id when gerdTV knows it (`tmdb_id`; for an episode the
//! show's `parent_tmdb_id` with season and episode), else by the cleaned title. Download links last 3 hours: the
//! file is fetched at once into the cache folder. No key ships with gerdTV (owner decision).
//! Debug hints: 403 = the key is refused; 406 = the day's downloads are used up (the answer says when they renew);
//! 401 on login = wrong username or password: stop, don't retry.

use std::path::{Path, PathBuf};
use std::time::Duration;

use serde_json::{Value, json};

pub const BASE: &str = "https://api.opensubtitles.com";

#[derive(Debug, thiserror::Error)]
pub enum SubsError {
    #[error("OpenSubtitles refused the API key")]
    Key,
    #[error("OpenSubtitles: wrong username or password")]
    Login,
    #[error("OpenSubtitles: today's downloads are used up ({0})")]
    Quota(String),
    #[error("OpenSubtitles: HTTP {0}")]
    Http(u16),
    #[error("OpenSubtitles: network error: {0}")]
    Network(String),
    #[error("file error: {0}")]
    Io(#[from] std::io::Error),
}

pub type Result<T> = std::result::Result<T, SubsError>;

/// What is searched: by TMDB id when known (an episode: its show's id with season and number), else by title.
#[derive(Debug, Clone, PartialEq)]
pub struct Search {
    pub tmdb: Option<u64>,
    pub title: String,
    pub year: Option<u32>,
    /// Episodes: (season, number).
    pub episode: Option<(u32, u32)>,
    /// ISO 639-1 codes, comma-separated ("de,en"); empty = all.
    pub languages: String,
}

/// One subtitle file to choose.
#[derive(Debug, Clone, PartialEq)]
pub struct Found {
    pub file_id: u64,
    pub language: String,
    pub release: String,
    pub hearing_impaired: bool,
    /// Machine- or AI-translated.
    pub translated: bool,
    pub downloads: u64,
}

/// A login: its token, and the host its calls go to (from `base_url`; empty: the default).
#[derive(Debug, Clone, PartialEq)]
pub struct Login {
    pub token: String,
    pub host: String,
}

pub struct OpenSubtitles {
    http: reqwest::Client,
    base: String,
    key: String,
}

impl OpenSubtitles {
    pub fn new(base: &str, key: &str) -> OpenSubtitles {
        crate::xtream::ensure_tls_provider();
        OpenSubtitles {
            http: reqwest::Client::builder()
                .connect_timeout(Duration::from_secs(10))
                .timeout(Duration::from_secs(30))
                // Its API asks for "<app name> v<version>".
                .user_agent(concat!("gerdTV v", env!("CARGO_PKG_VERSION")))
                .build()
                .expect("HTTP client"),
            base: base.trim_end_matches('/').to_string(),
            key: key.trim().to_string(),
        }
    }

    async fn call(&self, req: reqwest::RequestBuilder) -> Result<Value> {
        let res = req
            .header("Api-Key", &self.key)
            .header("Accept", "application/json")
            .send()
            .await
            .map_err(|e| SubsError::Network(e.without_url().to_string()))?;
        let status = res.status().as_u16();
        let bytes = res
            .bytes()
            .await
            .map_err(|e| SubsError::Network(e.without_url().to_string()))?;
        let v: Value = serde_json::from_slice(&bytes).unwrap_or(Value::Null);
        match status {
            200 => Ok(v),
            403 => Err(SubsError::Key),
            406 => Err(SubsError::Quota(
                v["message"].as_str().unwrap_or_default().to_string(),
            )),
            s => Err(SubsError::Http(s)),
        }
    }

    /// Where a call goes: the login's host (VIP accounts get vip-api.opensubtitles.com, whose calls fail without
    /// the token) with this client's scheme, else this client's base.
    fn url(&self, login: Option<&Login>, path: &str) -> String {
        match login.filter(|l| !l.host.is_empty()) {
            Some(l) => {
                let scheme = self.base.split("://").next().unwrap_or("https");
                format!("{scheme}://{}{path}", l.host)
            }
            None => format!("{}{path}", self.base),
        }
    }

    /// A call with the login's token, when there is a login.
    fn signed(req: reqwest::RequestBuilder, login: Option<&Login>) -> reqwest::RequestBuilder {
        match login {
            Some(l) => req.bearer_auth(&l.token),
            None => req,
        }
    }

    /// A token for the user's own download quota, and the host its later calls must use ("Further API requests
    /// must continue on returned base_url host", its API definition).
    pub async fn login(&self, username: &str, password: &str) -> Result<Login> {
        let req = self
            .http
            .post(format!("{}/api/v1/login", self.base))
            .header("Content-Type", "application/json")
            .body(json!({ "username": username, "password": password }).to_string());
        match self.call(req).await {
            Ok(v) => Ok(Login {
                token: v["token"].as_str().ok_or(SubsError::Http(200))?.to_string(),
                host: v["base_url"].as_str().unwrap_or_default().to_string(),
            }),
            Err(SubsError::Http(401)) => Err(SubsError::Login),
            Err(e) => Err(e),
        }
    }

    /// Subtitles for `s`, the most downloaded first (as OpenSubtitles orders them by default).
    /// Logged in, it goes to the login's host with the token (its API: send the token with every call there).
    pub async fn search(&self, s: &Search, login: Option<&Login>) -> Result<Vec<Found>> {
        // Its advice: parameters sorted, lowercase, no defaults, so answers come from its cache.
        let mut q: Vec<(&str, String)> = Vec::new();
        match (s.tmdb, s.episode) {
            (Some(id), Some((season, number))) => {
                q.push(("episode_number", number.to_string()));
                q.push(("parent_tmdb_id", id.to_string()));
                q.push(("season_number", season.to_string()));
            }
            (Some(id), None) => q.push(("tmdb_id", id.to_string())),
            (None, episode) => {
                if let Some((season, number)) = episode {
                    q.push(("episode_number", number.to_string()));
                    q.push(("season_number", season.to_string()));
                }
                q.push(("query", s.title.to_lowercase()));
                if let (Some(y), None) = (s.year, episode) {
                    q.push(("year", y.to_string()));
                }
            }
        }
        if !s.languages.is_empty() {
            q.push(("languages", s.languages.to_lowercase()));
        }
        q.sort();
        let v = self
            .call(Self::signed(
                self.http
                    .get(self.url(login, "/api/v1/subtitles"))
                    .query(&q),
                login,
            ))
            .await?;
        Ok(v["data"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|d| {
                let a = &d["attributes"];
                Some(Found {
                    file_id: a["files"][0]["file_id"].as_u64()?,
                    language: a["language"].as_str().unwrap_or_default().to_string(),
                    release: a["release"].as_str().unwrap_or_default().to_string(),
                    hearing_impaired: a["hearing_impaired"].as_bool().unwrap_or(false),
                    translated: a["machine_translated"].as_bool().unwrap_or(false)
                        || a["ai_translated"].as_bool().unwrap_or(false),
                    downloads: a["download_count"].as_u64().unwrap_or(0),
                })
            })
            .collect())
    }

    /// Downloads a file into `dir` (the cache folder) and returns its path; a login uses the user's quota.
    pub async fn download(
        &self,
        file_id: u64,
        login: Option<&Login>,
        dir: &Path,
    ) -> Result<PathBuf> {
        let req = Self::signed(
            self.http
                .post(self.url(login, "/api/v1/download"))
                .header("Content-Type", "application/json")
                .body(json!({ "file_id": file_id }).to_string()),
            login,
        );
        let v = self.call(req).await?;
        let link = v["link"].as_str().ok_or(SubsError::Http(200))?;
        let res = self
            .http
            .get(link)
            .send()
            .await
            .map_err(|e| SubsError::Network(e.without_url().to_string()))?;
        if !res.status().is_success() {
            return Err(SubsError::Http(res.status().as_u16()));
        }
        let bytes = res
            .bytes()
            .await
            .map_err(|e| SubsError::Network(e.without_url().to_string()))?;
        std::fs::create_dir_all(dir)?;
        // Always UTF-8 SubRip from the API; named by its id, so a second download replaces the first.
        let path = dir.join(format!("opensubtitles-{file_id}.srt"));
        std::fs::write(&path, bytes)?;
        Ok(path)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use gerdtv_testkit::mock_opensubtitles::{FREE, KEY, MockOpenSubtitles, PASS, USER};

    fn search(tmdb: Option<u64>, episode: Option<(u32, u32)>, languages: &str) -> Search {
        Search {
            tmdb,
            title: String::new(),
            year: None,
            episode,
            languages: languages.into(),
        }
    }

    /// New, because nothing owns OpenSubtitles: the search by id (an episode by its show's), languages narrow it,
    /// the free allowance ends with its own error, a login's quota goes on, and wrong keys or passwords say so.
    #[tokio::test]
    async fn finds_and_downloads_within_the_quota() {
        let mock = MockOpenSubtitles::start().await;
        let os = OpenSubtitles::new(&mock.base(), KEY);
        let ids = |found: Vec<Found>| found.into_iter().map(|f| f.file_id).collect::<Vec<_>>();
        assert_eq!(
            ids(os
                .search(&search(Some(1001), None, ""), None)
                .await
                .unwrap()),
            [11, 12]
        );
        assert_eq!(
            ids(os
                .search(&search(Some(1001), None, "en"), None)
                .await
                .unwrap()),
            [12]
        );
        assert_eq!(
            ids(os
                .search(&search(Some(2001), Some((1, 2)), ""), None)
                .await
                .unwrap()),
            [21]
        );
        assert!(
            os.search(&search(Some(2001), Some((1, 3)), ""), None)
                .await
                .unwrap()
                .is_empty()
        );

        let dir = std::env::temp_dir().join(format!("gerdtv-subs-{}", std::process::id()));
        for _ in 0..FREE {
            let path = os.download(12, None, &dir).await.unwrap();
            assert!(
                std::fs::read_to_string(path)
                    .unwrap()
                    .contains("Synthetic subtitle 12")
            );
        }
        assert!(matches!(
            os.download(12, None, &dir).await,
            Err(SubsError::Quota(_))
        ));
        assert!(matches!(
            os.login(USER, "wrong").await,
            Err(SubsError::Login)
        ));
        // Logged in, every call goes to the host the login named (VIP accounts: vip-api), with the token.
        let login = os.login(USER, PASS).await.unwrap();
        assert!(login.host.starts_with("localhost:"), "{login:?}");
        let episode = search(Some(2001), Some((1, 2)), "");
        let found = os.search(&episode, Some(&login));
        assert_eq!(ids(found.await.unwrap()), [21]);
        os.download(21, Some(&login), &dir).await.unwrap();
        assert_eq!(mock.downloads(), (FREE, 1));

        let bad = OpenSubtitles::new(&mock.base(), "nope");
        assert!(matches!(
            bad.search(&search(Some(1001), None, ""), None).await,
            Err(SubsError::Key)
        ));
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
