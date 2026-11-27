//! Bridge surface for OpenSubtitles (logic: gerdtv_core::opensubtitles). The app passes the user's API key (and a
//! login (token and host), when the user gave one) with every call.

use gerdtv_core::opensubtitles as core;
use std::path::PathBuf;

use crate::api::library::Library;

/// One subtitle to choose in the player.
pub struct SubtitleInfo {
    pub file_id: u64,
    /// ISO 639-1.
    pub language: String,
    pub release: String,
    pub hearing_impaired: bool,
    /// Machine- or AI-translated.
    pub translated: bool,
}

fn client(key: &str) -> core::OpenSubtitles {
    core::OpenSubtitles::new(core::BASE, key)
}

/// A token for the user's own download quota (wrong login: the error says so; don't retry, it's rate-limited).
/// A login: its token and the host its calls must use (VIP accounts: vip-api.opensubtitles.com).
pub struct SubsLogin {
    pub token: String,
    pub host: String,
}

impl SubsLogin {
    fn core(&self) -> core::Login {
        core::Login {
            token: self.token.clone(),
            host: self.host.clone(),
        }
    }
}

pub async fn subs_login(
    key: String,
    username: String,
    password: String,
) -> Result<SubsLogin, String> {
    let l = client(&key)
        .login(&username, &password)
        .await
        .map_err(|e| e.to_string())?;
    Ok(SubsLogin {
        token: l.token,
        host: l.host,
    })
}

/// Subtitles for a movie or episode of the open profile in `languages` ("de,en"; empty: all).
pub async fn subs_search(
    library: &Library,
    key: String,
    login: Option<SubsLogin>,
    item_key: String,
    languages: String,
) -> Result<Vec<SubtitleInfo>, String> {
    let Some(search) = library.search_for_subtitles(&item_key, &languages)? else {
        return Ok(vec![]);
    };
    Ok(client(&key)
        .search(&search, login.map(|l| l.core()).as_ref())
        .await
        .map_err(|e| e.to_string())?
        .into_iter()
        .map(|f| SubtitleInfo {
            file_id: f.file_id,
            language: f.language,
            release: f.release,
            hearing_impaired: f.hearing_impaired,
            translated: f.translated,
        })
        .collect())
}

/// Downloads a subtitle into `dir` (the cache folder); its path, for mpv's sub-add.
pub async fn subs_download(
    key: String,
    login: Option<SubsLogin>,
    file_id: u64,
    dir: String,
) -> Result<String, String> {
    let path = client(&key)
        .download(
            file_id,
            login.map(|l| l.core()).as_ref(),
            &PathBuf::from(dir),
        )
        .await
        .map_err(|e| e.to_string())?;
    Ok(path.to_string_lossy().into_owned())
}
