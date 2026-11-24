//! Bridge surface for the in-app updater (logic: gerdtv_core::update). The app passes its platform; the version is
//! the core's own (one version for the whole app, set by the wrap-up).

use gerdtv_core::update as core;
use std::path::PathBuf;

/// A newer release for this platform.
pub struct UpdateInfo {
    pub version: String,
    pub notes: String,
    pub asset: String,
    pub size: u64,
    pub sha256: String,
    pub min_os: String,
    pub url: String,
}

impl From<core::Release> for UpdateInfo {
    fn from(r: core::Release) -> Self {
        UpdateInfo {
            version: r.version,
            notes: r.notes,
            asset: r.asset,
            size: r.size,
            sha256: r.sha256,
            min_os: r.min_os,
            url: r.url,
        }
    }
}

/// The newest release's page on GitHub.
#[flutter_rust_bridge::frb(sync)]
pub fn release_page() -> String {
    core::RELEASE_PAGE.to_string()
}

/// A newer, correctly signed release with a build for `platform` ("macos", "ios", "android", "linux"), or None.
pub async fn check_update(platform: String) -> Result<Option<UpdateInfo>, String> {
    core::check(
        core::RELEASES,
        gerdtv_core::version(),
        &platform,
        core::PUBLIC_KEY_HEX,
    )
    .await
    .map(|r| r.map(Into::into))
    .map_err(|e| e.to_string())
}

/// Downloads the release's file into `dir`; returns its path, kept only when size and SHA-256 match.
pub async fn download_update(update: UpdateInfo, dir: String) -> Result<String, String> {
    let r = core::Release {
        version: update.version,
        notes: update.notes,
        asset: update.asset,
        size: update.size,
        sha256: update.sha256,
        min_os: update.min_os,
        url: update.url,
    };
    core::download(&r, &PathBuf::from(dir))
        .await
        .map(|p| p.to_string_lossy().into_owned())
        .map_err(|e| e.to_string())
}
