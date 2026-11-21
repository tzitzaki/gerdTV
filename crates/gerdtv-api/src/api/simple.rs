//! Bootstrap calls: app start-up and the Dart → Rust round trip. Only forwards to gerdtv-core.

/// Synchronous on purpose: it's cheap, and a sync call proves the library loaded before the first frame.
#[flutter_rust_bridge::frb(sync)]
pub fn greet(name: String) -> String {
    gerdtv_core::greet(&name)
}

/// The core's version, shown in About (and in diagnostics later).
#[flutter_rust_bridge::frb(sync)]
pub fn core_version() -> String {
    gerdtv_core::version().to_string()
}

/// Runs once when Dart calls `RustLib.init()`: installs flutter_rust_bridge's default panic and log hooks.
#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}
