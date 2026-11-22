//! Bridge surface for the logo disk cache (logic: gerdtv_core::logos). One cache for the whole app, set up once with
//! the platform's cache folder.

use gerdtv_core::logos::LogoCache;
use std::path::PathBuf;
use std::sync::OnceLock;

static CACHE: OnceLock<LogoCache> = OnceLock::new();

/// Sets the cache folder (the app's cache directory + "logos"); later calls keep the first folder.
#[flutter_rust_bridge::frb(sync)]
pub fn init_logo_cache(dir: String) {
    let _ = CACHE.set(LogoCache::new(PathBuf::from(dir)));
}

/// The logo's local file (downloaded on first use), or None when the URL fails or the cache isn't set up.
pub async fn logo_file(url: String) -> Option<String> {
    let path = CACHE.get()?.get(&url).await?;
    Some(path.to_string_lossy().into_owned())
}
