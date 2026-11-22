//! The libmpv harness: real libmpv (headless, `vo=null ao=null`) driven by the real watchdog
//! (gerdtv_core::playback) against the fault server, one test per fault, each asserting that playback recovers
//! (or stops, for a refused stream) within a time limit. This is the same loop the Dart adapter runs on top of
//! media_kit, minus Flutter, so a watchdog regression shows up here first.
//!
//! Each test prints its measured recovery time. Debug: set GERDTV_HARNESS_LOG=1 to print mpv's warnings.
//!
//! The tests run one at a time (SERIAL) and only via `just test-harness` (ignored otherwise): FFmpeg's log
//! callback is process-wide, so with several mpv instances in one process the "HTTP error 403" warnings reach only
//! one of them. The app has one player, so this only concerns tests.

use gerdtv_core::playback::{BufferPreset, Command, PlayerEvent, State, Watchdog, mpv_options};
use gerdtv_testkit::fault::{Fault, FaultServer};
use libmpv2::events::{Event, PropertyData};
use libmpv2::{Format, Mpv};
use std::time::{Duration, Instant};

/// One player under test: libmpv + watchdog + the URL to (re)open.
struct Harness {
    mpv: Mpv,
    watchdog: Watchdog,
    base: String,
    last_progress: Instant,
    position: f64,
    failed: Option<String>,
    reloads: u32,
    health: Vec<(String, bool)>,
}

impl Harness {
    fn new(base: String, live: bool, preset: BufferPreset) -> Harness {
        let mpv = Mpv::with_initializer(|init| {
            init.set_property("vo", "null")?;
            init.set_property("ao", "null")?;
            init.set_property("ytdl", "no")?;
            Ok(())
        })
        .expect("libmpv");
        for (k, v) in mpv_options(preset, 1_000_000) {
            mpv.set_property(&k, v.as_str())
                .unwrap_or_else(|e| panic!("mpv option {k}={v}: {e:?}"));
        }
        mpv.disable_deprecated_events().unwrap();
        mpv.observe_property("paused-for-cache", Format::Flag, 2)
            .unwrap();
        // FFmpeg's HTTP status errors arrive as warnings (the same reason the app's players log at warn).
        // SAFETY: a valid handle and a NUL-terminated level string, as mpv_request_log_messages expects.
        unsafe { mpv_request_log_messages(mpv.ctx.as_ptr().cast(), c"warn".as_ptr()) };
        Harness {
            mpv,
            watchdog: Watchdog::new(live, preset.seconds(), false),
            base,
            last_progress: Instant::now(),
            position: 0.0,
            failed: None,
            reloads: 0,
            health: vec![],
        }
    }

    fn open(&mut self, hls: bool) {
        let url = format!("{}.{}", self.base, if hls { "m3u8" } else { "ts" });
        self.mpv.command("loadfile", &[&url, "replace"]).unwrap();
    }

    fn feed(&mut self, event: PlayerEvent) {
        for c in self.watchdog.on_event(event) {
            match c {
                Command::Reload { hls, .. } => {
                    self.reloads += 1;
                    self.open(hls);
                }
                Command::Fail(m) => self.failed = Some(m),
                Command::Health {
                    trigger, recovered, ..
                } => self.health.push((trigger.as_str().to_string(), recovered)),
                _ => {}
            }
        }
    }

    /// Runs the event loop for exactly `d` (no condition).
    fn run_for(&mut self, d: Duration) {
        self.step_until(d, |_| false);
    }

    /// Runs the event loop for up to `limit`, stopping early when `done` holds. Returns the time taken.
    fn run_until(&mut self, limit: Duration, done: impl FnMut(&Harness) -> bool) -> Duration {
        match self.step_until(limit, done) {
            Some(t) => t,
            None => panic!(
                "not done within {limit:?} (state {:?}, reloads {})",
                self.watchdog.state(),
                self.reloads
            ),
        }
    }

    /// The loop itself: Some(elapsed) when `done` held, None when `limit` passed.
    fn step_until(
        &mut self,
        limit: Duration,
        mut done: impl FnMut(&Harness) -> bool,
    ) -> Option<Duration> {
        let start = Instant::now();
        let mut next_tick = Instant::now() + Duration::from_secs(1);
        while start.elapsed() < limit {
            if done(self) {
                return Some(start.elapsed());
            }
            let mut events = vec![];
            while let Some(ev) = self.mpv.wait_event(0.05) {
                match ev {
                    Ok(Event::PropertyChange {
                        name: "time-pos",
                        change: PropertyData::Double(t),
                        ..
                    }) => {
                        if t > self.position {
                            events.push(PlayerEvent::Position((t * 1000.0) as u64));
                            self.last_progress = Instant::now();
                        }
                        self.position = t;
                    }
                    Ok(Event::PropertyChange {
                        name: "paused-for-cache",
                        change: PropertyData::Flag(b),
                        ..
                    }) => {
                        events.push(PlayerEvent::Buffering(b));
                    }
                    // Only a real end counts: a reload replacing the old file reports Stop for it (media_kit's
                    // `completed` makes the same distinction for the app).
                    Ok(Event::EndFile(r)) if r == libmpv2::mpv_end_file_reason::Eof => {
                        events.push(PlayerEvent::EndOfFile)
                    }
                    // wait_event reports END_FILE with an error (e.g. failed to open) as Err.
                    Err(e) => events.push(PlayerEvent::Error(format!("{e:?}"))),
                    Ok(Event::LogMessage {
                        prefix: "ffmpeg",
                        text,
                        ..
                    }) if text.starts_with("http: HTTP error") => {
                        events.push(PlayerEvent::Error(text.trim().to_string()));
                    }
                    Ok(Event::LogMessage { prefix, text, .. })
                        if std::env::var("GERDTV_HARNESS_LOG").is_ok() =>
                    {
                        eprint!("mpv {prefix}: {text}");
                    }
                    _ => {}
                }
            }
            // The position is read directly each round: time-pos change events stopped arriving after a seek.
            if let Ok(t) = self.mpv.get_property::<f64>("time-pos") {
                if t > self.position {
                    events.push(PlayerEvent::Position((t * 1000.0) as u64));
                    self.last_progress = Instant::now();
                }
                self.position = t;
            }
            for e in events {
                // Each loaded file restarts mpv's clock at 0; reset our "last position" with it.
                if matches!(e, PlayerEvent::EndOfFile) {
                    self.position = 0.0;
                }
                self.feed(e);
            }
            if Instant::now() >= next_tick {
                next_tick += Duration::from_secs(1);
                self.feed(PlayerEvent::Tick);
            }
        }
        None
    }

    fn playing_for(&mut self, secs: f64, limit: Duration) -> Duration {
        let mut from: Option<f64> = None;
        self.run_until(limit, |h| {
            let since = *from.get_or_insert(h.position);
            h.watchdog.state() == State::Playing && h.position - since >= secs
        })
    }
}

// libmpv2 doesn't wrap mpv_request_log_messages (libmpv is linked through it already): declare it here.
unsafe extern "C" {
    fn mpv_request_log_messages(
        ctx: *mut std::ffi::c_void,
        min_level: *const std::ffi::c_char,
    ) -> std::ffi::c_int;
}

static SERIAL: std::sync::Mutex<()> = std::sync::Mutex::new(());

/// Holds the lock for one test (a failed test poisons it; the next test takes it anyway).
fn serial() -> std::sync::MutexGuard<'static, ()> {
    SERIAL.lock().unwrap_or_else(|e| e.into_inner())
}

fn runtime() -> tokio::runtime::Runtime {
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
        .unwrap()
}

/// Starts playback of `name` (live TS by default), waits for 2 s of real playback, applies `fault`, and returns the
/// harness plus the time until 2 more seconds have played after the fault.
fn recover_from(
    name: &str,
    preset: BufferPreset,
    fault: impl FnOnce(&FaultServer),
) -> (Harness, Duration) {
    let rt = runtime();
    let srv = rt.block_on(FaultServer::start());
    let mut h = Harness::new(srv.url(&format!("/live/{name}")), true, preset);
    h.open(false);
    h.playing_for(2.0, Duration::from_secs(40));
    fault(&srv);
    let t = h.playing_for(2.0, Duration::from_secs(90));
    println!(
        "{name}: recovered and played 2 s within {:.1} s, {} reload(s)",
        t.as_secs_f64(),
        h.reloads
    );
    drop(srv);
    drop(rt);
    (h, t)
}

#[test]
#[ignore = "libmpv harness: just test-harness"]
fn recovers_from_a_dropped_connection() {
    let _serial = serial();
    // The stream is cut and the next connection works: FFmpeg's reconnect or one watchdog reload.
    let (_h, t) = recover_from("drop", BufferPreset::FastZap, |s| s.cut());
    assert!(t < Duration::from_secs(30), "{t:?}");
}

#[test]
#[ignore = "libmpv harness: just test-harness"]
fn recovers_from_server_errors() {
    let _serial = serial();
    // Cut, then 503 for every request for 5 s: the watchdog backs off and plays once the server is back.
    let rt = runtime();
    let srv = rt.block_on(FaultServer::start());
    let mut h = Harness::new(srv.url("/live/http5xx"), true, BufferPreset::FastZap);
    h.open(false);
    h.playing_for(2.0, Duration::from_secs(40));
    srv.set(Fault::Status { code: 503 });
    srv.cut();
    let start = Instant::now();
    h.run_for(Duration::from_secs(5));
    srv.set(Fault::None);
    h.playing_for(2.0, Duration::from_secs(60));
    let t = start.elapsed();
    println!(
        "http5xx: recovered and played 2 s within {:.1} s, {} reload(s)",
        t.as_secs_f64(),
        h.reloads
    );
    assert!(
        h.reloads >= 1 && t < Duration::from_secs(45),
        "{t:?}, reloads {}",
        h.reloads
    );
    assert!(
        h.health.iter().any(|(_, ok)| *ok),
        "the recovery was logged: {:?}",
        h.health
    );
}

#[test]
#[ignore = "libmpv harness: just test-harness"]
fn recovers_from_a_stalled_server() {
    let _serial = serial();
    // The next request stalls for 60 s with the connection open: no bytes, no error. Either FFmpeg's transport
    // reconnect (network-timeout 10 s) or the watchdog's stall timeout (15 s for Fast zap) gets a healthy stream;
    // on libmpv 0.40 the transport layer is usually first.
    let (h, t) = recover_from("stall", BufferPreset::FastZap, |s| {
        s.once(Fault::Stall {
            after_bytes: 0,
            duration: Duration::from_secs(60),
        });
        s.cut();
    });
    let _ = h;
    assert!(t < Duration::from_secs(40), "{t:?}");
}

#[test]
#[ignore = "libmpv harness: just test-harness"]
fn recovers_from_a_live_end_of_file() {
    let _serial = serial();
    // The server ends the "live" stream cleanly: a live EOF is a failure, reloaded at once (1 s backoff).
    let (_h, t) = recover_from("eof", BufferPreset::FastZap, |s| {
        s.once(Fault::LiveEof { after_bytes: 0 });
        s.cut();
    });
    assert!(t < Duration::from_secs(30), "{t:?}");
}

#[test]
#[ignore = "libmpv harness: just test-harness"]
fn plays_through_a_throttled_line_with_a_bigger_buffer() {
    let _serial = serial();
    // 25 kB/s is below the clip's ~33 kB/s: playback stutters but must not fail or loop reloads.
    let rt = runtime();
    let srv = rt.block_on(FaultServer::start());
    srv.set(Fault::Throttle {
        bytes_per_sec: 25_000,
    });
    let mut h = Harness::new(srv.url("/live/slow"), true, BufferPreset::FastZap);
    h.open(false);
    let t = h.playing_for(3.0, Duration::from_secs(60));
    println!(
        "throttled: 3 s played within {:.1} s, {} reload(s)",
        t.as_secs_f64(),
        h.reloads
    );
    assert!(h.failed.is_none());
}

#[test]
#[ignore = "libmpv harness: just test-harness"]
fn live_hls_with_rotating_segment_urls_plays() {
    let _serial = serial();
    let rt = runtime();
    let srv = rt.block_on(FaultServer::start());
    let mut h = Harness::new(srv.url("/live/hls"), true, BufferPreset::FastZap);
    let url = srv.url("/live/hls.m3u8?rotate=1");
    h.mpv.command("loadfile", &[&url, "replace"]).unwrap();
    let t = h.playing_for(6.0, Duration::from_secs(60));
    println!("hls rotate: 6 s played within {:.1} s", t.as_secs_f64());
    assert_eq!(h.reloads, 0);
}

#[test]
#[ignore = "libmpv harness: just test-harness"]
fn a_refused_stream_stops_without_looping() {
    let _serial = serial();
    let rt = runtime();
    let srv = rt.block_on(FaultServer::start());
    srv.set(Fault::Status { code: 403 });
    let mut h = Harness::new(srv.url("/live/blocked"), true, BufferPreset::FastZap);
    h.open(false);
    let t = h.run_until(Duration::from_secs(30), |h| h.failed.is_some());
    println!("403: stopped within {:.1} s", t.as_secs_f64());
    // Nothing more happens afterwards: no reload loop.
    let before = srv.stats().live_ts;
    h.run_for(Duration::from_secs(5));
    assert_eq!(srv.stats().live_ts, before);
    assert_eq!(h.reloads, 0);
}

#[test]
#[ignore = "libmpv harness: just test-harness"]
fn live_can_be_rewound_with_timeshift() {
    let _serial = serial();
    use gerdtv_core::playback::{TIMESHIFT_MOBILE_SECS, behind_live, timeshift_options};
    let rt = runtime();
    let srv = rt.block_on(FaultServer::start());
    let mut h = Harness::new(srv.url("/live/timeshift"), true, BufferPreset::FastZap);
    let cache = std::env::temp_dir().join(format!("gerdtv-timeshift-{}", std::process::id()));
    std::fs::create_dir_all(&cache).unwrap();
    for (k, v) in timeshift_options(
        TIMESHIFT_MOBILE_SECS,
        1_000_000,
        100_000_000_000,
        cache.to_str().unwrap(),
    ) {
        h.mpv.set_property(&k, v.as_str()).unwrap();
    }
    h.open(false);
    // Past the clip's first loop point on purpose: the live stream's timestamps keep counting across loops.
    h.run_until(Duration::from_secs(40), |h| h.position >= 13.0);
    let before = h.position;
    // The live edge: the newest cached moment *before* rewinding, moving on in real time afterwards (after a seek,
    // demuxer-cache-time is the end of the range around the new position, not the live edge).
    let edge: f64 = h.mpv.get_property("demuxer-cache-time").unwrap();
    let edge_at = Instant::now();
    h.mpv.command("seek", &["-8", "relative"]).unwrap();
    h.run_until(Duration::from_secs(10), |h| {
        h.position > 0.5 && h.position < before - 6.0
    });
    let rewound = h.position;
    h.run_for(Duration::from_secs(2));
    assert!(
        h.position > rewound + 1.0,
        "plays on after rewinding ({rewound} → {})",
        h.position
    );
    let behind = behind_live(edge + edge_at.elapsed().as_secs_f64(), h.position);
    println!("timeshift: rewound {before:.1} → {rewound:.1} s, {behind} s behind live");
    assert!(
        (6..=20).contains(&behind),
        "behind live after rewinding 8 s: {behind}"
    );
    assert_eq!(h.reloads, 0);
    drop(h);
    let _ = std::fs::remove_dir_all(&cache);
}

/// The soak (nightly, `just soak`): GERDTV_SOAK_MINUTES (default 30) of live playback with a random fault every
/// 45–120 s (seeded, so a failure is reproducible with GERDTV_SOAK_SEED). Every fault must be recovered from:
/// 2 s of real playback within 90 s.
#[test]
#[ignore = "soak: just soak"]
fn soak_random_faults() {
    let _serial = serial();
    use gerdtv_testkit::generate::Rng;
    let minutes: u64 = std::env::var("GERDTV_SOAK_MINUTES")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(30);
    let seed: u64 = std::env::var("GERDTV_SOAK_SEED")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(42);
    let mut rng = Rng::new(seed);
    let rt = runtime();
    let srv = rt.block_on(FaultServer::start());
    let mut h = Harness::new(srv.url("/live/soak"), true, BufferPreset::Balanced);
    h.open(false);
    h.playing_for(2.0, Duration::from_secs(60));
    let end = Instant::now() + Duration::from_secs(minutes * 60);
    let (mut faults, mut worst) = (0, Duration::ZERO);
    while Instant::now() < end {
        h.run_for(Duration::from_secs(45 + rng.below(76) as u64));
        let kind = rng.below(4);
        match kind {
            0 => srv.cut(),
            1 => {
                srv.once(Fault::LiveEof { after_bytes: 0 });
                srv.cut();
            }
            2 => {
                srv.once(Fault::Stall {
                    after_bytes: 0,
                    duration: Duration::from_secs(40),
                });
                srv.cut();
            }
            _ => {
                srv.set(Fault::Status { code: 502 });
                srv.cut();
                h.run_for(Duration::from_secs(3));
                srv.set(Fault::None);
            }
        }
        faults += 1;
        let t = h.playing_for(2.0, Duration::from_secs(90));
        worst = worst.max(t);
        println!(
            "soak fault {faults} (kind {kind}): recovered in {:.1} s",
            t.as_secs_f64()
        );
    }
    println!(
        "soak: {minutes} min, {faults} faults, all recovered, worst {:.1} s, {} watchdog reloads",
        worst.as_secs_f64(),
        h.reloads
    );
    assert!(h.failed.is_none());
}
