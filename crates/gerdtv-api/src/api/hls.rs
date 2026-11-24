//! Bridge surface for the local HLS that feeds AVPlayer on Apple platforms (logic: gerdtv_core::hls). Started from
//! the library (`Library::start_local_hls`), so the provider URL with its login never crosses into Dart.

use gerdtv_core::hls as core;
use std::sync::Mutex;

/// A running local HLS; stops when Dart calls [LocalHlsStream::stop] or drops it.
pub struct LocalHlsStream(pub(crate) Mutex<core::LocalHls>);

/// What the player shows about it (polled once a second).
pub struct LocalHlsStatus {
    /// Seconds AVPlayer can rewind.
    pub window_secs: f64,
    pub reconnects: u32,
    /// The provider connection is being re-established right now.
    pub reconnecting: bool,
    /// The provider refused the stream (the message to show); it was not retried.
    pub failure: Option<String>,
}

impl LocalHlsStream {
    /// The playlist URL for AVPlayer (127.0.0.1 with a random port and path token).
    #[flutter_rust_bridge::frb(sync)]
    pub fn url(&self) -> String {
        self.0.lock().unwrap().url().to_string()
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn status(&self) -> LocalHlsStatus {
        let s = self.0.lock().unwrap().status();
        LocalHlsStatus {
            window_secs: s.window_secs,
            reconnects: s.reconnects,
            reconnecting: s.reconnecting,
            failure: s.refused.map(core::refusal_message),
        }
    }

    /// Closes the provider connection and the server, and deletes the segments.
    #[flutter_rust_bridge::frb(sync)]
    pub fn stop(&self) {
        self.0.lock().unwrap().stop();
    }
}
