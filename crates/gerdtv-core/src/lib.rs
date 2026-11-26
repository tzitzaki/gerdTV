//! gerdTV core: every piece of app logic lives here (parsers, sync, search, playback watchdog, recorder, cast …),
//! with no Flutter dependency, so all of it is unit-tested headless on Linux. The Flutter app reaches it only through
//! the thin `gerdtv-api` crate (flutter_rust_bridge). Bootstrap state: just the version and a greeting that proves the
//! Dart → Rust call path works end to end.

pub mod db;
pub mod epg;
pub mod groups;
pub mod hls;
pub mod library;
pub mod logos;
pub mod m3u;
pub mod opensubtitles;
pub mod playback;
pub mod premiumize;
pub mod recorder;
pub mod tmdb;
pub mod tracking;
pub mod update;
pub mod userdata;
pub mod watch_import;
pub mod xtream;

/// The core's version, the same as the workspace version (set by each wrap-up release).
pub fn version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}

/// The bootstrap's round-trip call: Dart calls `gerdtv-api`, which calls this.
/// Debug hint: if the app shows no greeting, the native library didn't load (see docs/ARCHITECTURE.md, "The seam").
pub fn greet(name: &str) -> String {
    format!("Hello, {name}! This is gerdTV core {}.", version())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn greet_names_the_caller_and_the_version() {
        let s = greet("Tom");
        assert!(s.starts_with("Hello, Tom!"));
        assert!(s.contains(version()));
    }
}
