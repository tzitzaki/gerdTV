//! Playback policy: the buffer presets (which mpv options a preset means) and the watchdog (what to do when a
//! stream misbehaves). Both are pure logic: the Dart adapter (app/lib/player/) sets the options on media_kit's
//! player, feeds player events in, and executes the commands that come out. So the behaviour is identical on every
//! platform and fully unit-tested here.
//!
//! Spike A state: presets and transport options are complete; the watchdog handles start, buffering, live end of
//! file and errors with the backoff schedule. Phase 2 adds stall detection by cache time, the .ts ↔ .m3u8 switch,
//! hard errors and the stream_health log.
//!
//! Option names are checked against mpv 0.40 / FFmpeg 7.1 (Linux) and limited to ones mpv 0.36 / FFmpeg 6.0 (the
//! media_kit builds for Android, iOS, macOS) also have; the mapping is in docs/ARCHITECTURE.md.

use std::time::Duration;

/// How much the player buffers before (re)starting. More delay, fewer stutters on a slow line.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum BufferPreset {
    FastZap,
    Balanced,
    Smooth,
    MaxSmooth,
    /// 1–300 s.
    Custom(u32),
}

impl BufferPreset {
    /// The target buffer in seconds.
    pub fn seconds(self) -> u32 {
        match self {
            BufferPreset::FastZap => 2,
            BufferPreset::Balanced => 8,
            BufferPreset::Smooth => 30,
            BufferPreset::MaxSmooth => 90,
            BufferPreset::Custom(s) => s.clamp(1, 300),
        }
    }
}

impl BufferPreset {
    /// The stored form: "fast_zap", "balanced", "smooth", "max_smooth", "custom:<seconds>". Unknown → Balanced.
    pub fn parse(s: &str) -> BufferPreset {
        match s {
            "fast_zap" => BufferPreset::FastZap,
            "smooth" => BufferPreset::Smooth,
            "max_smooth" => BufferPreset::MaxSmooth,
            c if c.starts_with("custom:") => c[7..]
                .parse()
                .map(BufferPreset::Custom)
                .unwrap_or(BufferPreset::Balanced),
            _ => BufferPreset::Balanced,
        }
    }

    pub fn key(self) -> String {
        match self {
            BufferPreset::FastZap => "fast_zap".into(),
            BufferPreset::Balanced => "balanced".into(),
            BufferPreset::Smooth => "smooth".into(),
            BufferPreset::MaxSmooth => "max_smooth".into(),
            BufferPreset::Custom(s) => format!("custom:{}", s.clamp(1, 300)),
        }
    }

    /// One step more buffer (adaptive mode): the next named preset above this one's seconds; Max smooth stays.
    pub fn step_up(self) -> BufferPreset {
        let secs = self.seconds();
        [
            BufferPreset::Balanced,
            BufferPreset::Smooth,
            BufferPreset::MaxSmooth,
        ]
        .into_iter()
        .find(|p| p.seconds() > secs)
        .unwrap_or(BufferPreset::MaxSmooth)
    }
}

/// Assumed bitrate when nothing better is known (an HD IPTV channel is typically 4–8 Mbit/s).
pub const DEFAULT_BITRATE_BPS: u64 = 8_000_000;
/// The demuxer never gets less than this, so short presets still hold a few seconds of a high-bitrate stream.
const MIN_DEMUXER_BYTES: u64 = 32 * 1024 * 1024;

/// The mpv options for a preset, as (name, value) pairs to set before `open()`.
/// `bitrate_bps`: the stream's estimated bitrate, used to size the demuxer cache (target × bitrate × 1.5 headroom).
pub fn mpv_options(preset: BufferPreset, bitrate_bps: u64) -> Vec<(String, String)> {
    let secs = preset.seconds();
    let bytes = (secs as u64 * bitrate_bps / 8 * 3 / 2).max(MIN_DEMUXER_BYTES);
    let mut opts = vec![
        ("cache", "yes".to_string()),
        // Read ahead as far as the target; mpv waits for `cache-pause-wait` seconds before resuming.
        ("cache-secs", secs.to_string()),
        ("demuxer-readahead-secs", secs.to_string()),
        ("cache-pause", "yes".to_string()),
        ("cache-pause-initial", "yes".to_string()),
        ("cache-pause-wait", secs.to_string()),
        ("demuxer-max-bytes", bytes.to_string()),
        // Transport layer: FFmpeg reconnects inside one HTTP stream before the watchdog has to step in.
        // (reconnect_max_retries / reconnect_delay_total_max are FFmpeg 7+, absent from the 6.0 builds.)
        (
            "stream-lavf-o",
            "reconnect=1,reconnect_streamed=1,reconnect_on_network_error=1,reconnect_delay_max=5"
                .to_string(),
        ),
        ("network-timeout", "10".to_string()),
    ];
    // Large buffers go to disk instead of RAM (media_kit enables cache-on-disk by default; set it explicitly so the
    // behaviour doesn't depend on that default).
    opts.push((
        "cache-on-disk",
        if secs >= 30 { "yes" } else { "no" }.to_string(),
    ));
    opts.into_iter().map(|(k, v)| (k.to_string(), v)).collect()
}

/// Default timeshift windows (pause/rewind live): desktop 60 min, phone/tablet/TV 30 min.
pub const TIMESHIFT_DESKTOP_SECS: u32 = 60 * 60;
pub const TIMESHIFT_MOBILE_SECS: u32 = 30 * 60;

/// The mpv options for pausing and rewinding live TV: a back buffer of `window_secs` at `bitrate_bps`, kept on disk
/// in `cache_dir` (empty = in RAM; the app passes its cache folder), never more than a quarter of `free_disk_bytes` (a recording
/// or the system needs the rest). `force-seekable` lets mpv seek inside a live stream's cache.
/// Window 0 turns timeshift off (back buffer 0, live streams not seekable).
pub fn timeshift_options(
    window_secs: u32,
    bitrate_bps: u64,
    free_disk_bytes: u64,
    cache_dir: &str,
) -> Vec<(String, String)> {
    let wanted = window_secs as u64 * bitrate_bps / 8;
    let back = wanted.min(free_disk_bytes / 4);
    let mut opts = vec![
        ("demuxer-max-back-bytes".to_string(), back.to_string()),
        (
            "force-seekable".to_string(),
            if back > 0 { "yes" } else { "no" }.to_string(),
        ),
    ];
    if back > 0 {
        // Seek inside the cached range, never at the server: a live HTTP stream can't seek. (mpv's default "auto"
        // usually does the same; explicit so it doesn't depend on that default.)
        opts.push(("demuxer-seekable-cache".to_string(), "yes".to_string()));
        // On disk only with a folder: embedded libmpv has no default cache location ("Failed to create file
        // cache"), and then the back buffer silently disappears. Without a folder it stays in RAM.
        if !cache_dir.is_empty() {
            opts.push(("cache-on-disk".to_string(), "yes".to_string()));
            opts.push(("demuxer-cache-dir".to_string(), cache_dir.to_string()));
        }
    }
    opts
}

/// Seconds behind live for the overlay ("−12:34 behind live"): the live edge minus the position. The live edge is
/// the newest `demuxer-cache-time` seen before the user paused or rewound, plus the time since: after a seek mpv
/// reports the end of the cached range around the new position instead.
pub fn behind_live(cache_end_secs: f64, position_secs: f64) -> u32 {
    (cache_end_secs - position_secs).max(0.0).round() as u32
}

/// What the player reports (translated from media_kit's streams and the platform by the Dart adapter).
/// A wake after at least this many seconds without ticks reloads a live stream (ticks come every second).
pub const WAKE_FROZEN_SECS: u64 = 5;

#[derive(Debug, Clone, PartialEq)]
pub enum PlayerEvent {
    /// Playback advanced (no position known).
    Playing,
    /// Playback advanced to this position (VOD resumes from the last one).
    Position(u64),
    /// mpv paused for cache (true) or resumed (false).
    Buffering(bool),
    /// The user paused (true) or resumed (false): a paused stream is never "stalled".
    UserPause(bool),
    /// The stream ended.
    EndOfFile,
    /// mpv reported an error (message already redacted).
    Error(String),
    /// The app came back from sleep or the background, after this many seconds without ticks (the app was frozen).
    /// A short gap means it kept running (background sound on iOS and Android) and the stream is fine.
    Wake(u64),
    /// The device's network changed (Wi-Fi ↔ Ethernet, new address).
    NetworkChanged,
    /// A second passed; drives timeouts and backoff.
    Tick,
}

/// Why the watchdog stepped in (stored in stream_health).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Trigger {
    Error,
    LiveEnd,
    Stall,
    Wake,
    Network,
}

impl Trigger {
    pub fn as_str(self) -> &'static str {
        match self {
            Trigger::Error => "error",
            Trigger::LiveEnd => "live_end",
            Trigger::Stall => "stall",
            Trigger::Wake => "wake",
            Trigger::Network => "network",
        }
    }
}

/// What the adapter should do.
#[derive(Debug, Clone, PartialEq)]
pub enum Command {
    /// Reopen the stream: live as HLS (`.m3u8`) or TS, at the live edge; VOD at `resume_ms`.
    Reload { hls: bool, resume_ms: Option<u64> },
    /// Tell the user we're reconnecting (attempt n).
    ShowReconnecting(u32),
    /// Playback is healthy again; hide any reconnect notice.
    HideReconnecting,
    /// Stop retrying and show this message (login refused, account blocked, too many connections …).
    Fail(String),
    /// The other URL form worked after a switch: remember it for this channel.
    RememberHls(bool),
    /// Adaptive mode: this channel rebuffered too often; raise its buffer one step (and tell the user).
    RaiseBuffer,
    /// One recovery episode ended: log it (stream_health).
    Health {
        trigger: Trigger,
        attempts: u32,
        recovered: bool,
        secs: u64,
    },
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum State {
    Starting,
    Playing,
    Buffering,
    Reconnecting,
    Failed,
}

/// mpv's messages when it can't open an audio output (ao/…). Matched loosely on purpose: the wording differs per
/// driver, and a false negative only costs a needless reload, a false positive a missed one for an audio-only error.
fn is_audio_output_error(message: &str) -> bool {
    let m = message.to_ascii_lowercase();
    m.contains("audio device") || m.contains("audio driver") || m.contains("audio output")
}

/// Errors retrying can't fix: the provider refused the login or the stream. Matches FFmpeg's wording only
/// ("http: HTTP error 403 Forbidden"): mpv's other messages carry the URL, which may contain any digits.
/// 5xx and network errors are not here: those are worth retrying.
pub fn hard_error(message: &str) -> Option<&'static str> {
    let m = message.to_ascii_lowercase();
    if m.contains("http error 401") {
        Some("The provider refused the login.")
    } else if m.contains("http error 403") {
        Some(
            "The provider refused this stream (account expired, blocked, or too many connections).",
        )
    } else {
        None
    }
}

/// Reload backoff: 1, 2, 4, 8, 15, 30 s, then 30 s for every further attempt.
pub fn backoff(attempt: u32) -> Duration {
    const STEPS: [u64; 6] = [1, 2, 4, 8, 15, 30];
    Duration::from_secs(STEPS[(attempt as usize).min(STEPS.len() - 1)])
}

/// After this many failed reloads in a row, live switches between `.ts` and `.m3u8`.
const SWITCH_AFTER: u32 = 3;
/// VOD gives up after this many reloads (live retries as long as the player is visible).
const VOD_MAX_ATTEMPTS: u32 = 6;

/// The watchdog for one playing stream. Feed it every event; run every command it returns.
#[derive(Debug)]
pub struct Watchdog {
    live: bool,
    state: State,
    /// Seconds without progress (or stuck buffering) after which a stream counts as stalled.
    stall_secs: u64,
    /// The URL form currently in use (live).
    hls: bool,
    /// The form the stream started with, to know whether a switch happened.
    started_hls: bool,
    user_paused: bool,
    /// Seconds since the last progress while playing, or since buffering began.
    idle: u64,
    /// Reload attempts since the last healthy playback.
    attempts: u32,
    /// Seconds left until the next reload while reconnecting.
    wait: u64,
    /// The current recovery episode: (first trigger, seconds so far).
    episode: Option<(Trigger, u64)>,
    last_position: Option<u64>,
    /// Adaptive mode (opt-in): more than ADAPTIVE_REBUFFERS rebuffers within ADAPTIVE_WINDOW_SECS → RaiseBuffer.
    adaptive: bool,
    /// Seconds since the watchdog started (counted in ticks), and when recent rebuffers began.
    clock: u64,
    rebuffers: std::collections::VecDeque<u64>,
}

const ADAPTIVE_REBUFFERS: usize = 3;
const ADAPTIVE_WINDOW_SECS: u64 = 600;

impl Watchdog {
    /// `target_secs`: the buffer preset's target; `prefer_hls`: what worked last time for this channel.
    pub fn new(live: bool, target_secs: u32, prefer_hls: bool) -> Watchdog {
        Watchdog {
            live,
            state: State::Starting,
            stall_secs: (target_secs as u64 + 10).max(15),
            hls: prefer_hls,
            started_hls: prefer_hls,
            user_paused: false,
            idle: 0,
            attempts: 0,
            wait: 0,
            episode: None,
            last_position: None,
            adaptive: false,
            clock: 0,
            rebuffers: Default::default(),
        }
    }

    /// Turns on adaptive mode (more than 3 rebuffers in 10 min → RaiseBuffer, at most once per 10 min).
    pub fn with_adaptive(mut self, on: bool) -> Watchdog {
        self.adaptive = on;
        self
    }

    pub fn state(&self) -> State {
        self.state
    }

    pub fn on_event(&mut self, event: PlayerEvent) -> Vec<Command> {
        if self.state == State::Failed {
            return vec![]; // stopped on a hard error; a new stream gets a new watchdog
        }
        if event == PlayerEvent::Tick {
            self.clock += 1;
        }
        match (self.state, event) {
            (_, PlayerEvent::Position(ms)) => {
                self.last_position = Some(ms);
                self.on_event(PlayerEvent::Playing)
            }
            // While waiting to reload, mpv may still play out what it buffered; only playback after the reload
            // counts as recovered.
            (State::Reconnecting, PlayerEvent::Playing) => vec![],
            (_, PlayerEvent::Playing) => self.healthy(),
            (State::Playing, PlayerEvent::Buffering(true)) => {
                self.state = State::Buffering;
                self.idle = 0;
                self.note_rebuffer()
            }
            (State::Buffering, PlayerEvent::Buffering(false)) => {
                self.state = State::Playing;
                self.idle = 0;
                vec![]
            }
            (_, PlayerEvent::UserPause(p)) => {
                self.user_paused = p;
                self.idle = 0;
                vec![]
            }
            // Audio output problems (no device, driver missing) leave the stream itself fine; mpv plays on silently.
            (_, PlayerEvent::Error(m)) if is_audio_output_error(&m) => vec![],
            (_, PlayerEvent::Error(m)) if hard_error(&m).is_some() => {
                self.fail(hard_error(&m).unwrap(), Trigger::Error)
            }
            // A live stream never ends on its own: an end of file is a failure. VOD ends normally.
            (_, PlayerEvent::EndOfFile) if !self.live => vec![],
            (State::Reconnecting, PlayerEvent::EndOfFile | PlayerEvent::Error(_)) => vec![],
            (_, PlayerEvent::EndOfFile) => self.schedule_reload(Trigger::LiveEnd),
            (_, PlayerEvent::Error(_)) => self.schedule_reload(Trigger::Error),
            // Back from sleep or on a new network a live connection is almost surely dead: reload at once.
            // Only a frozen app's live connection is presumed dead; one that kept playing is left alone (reloading it
            // rebuffered every return from the background). Debugging: stream_health rows with trigger "wake".
            (_, PlayerEvent::Wake(frozen)) if self.live && frozen >= WAKE_FROZEN_SECS => {
                self.reload_now(Trigger::Wake)
            }
            (_, PlayerEvent::NetworkChanged) if self.live => self.reload_now(Trigger::Network),
            (_, PlayerEvent::Wake(_) | PlayerEvent::NetworkChanged) => vec![],
            (state, PlayerEvent::Tick) => {
                if let Some((_, secs)) = &mut self.episode {
                    *secs += 1;
                }
                match state {
                    State::Reconnecting => {
                        self.wait = self.wait.saturating_sub(1);
                        if self.wait > 0 {
                            return vec![];
                        }
                        // Wait in Starting for the reload to play; a new failure schedules the next attempt.
                        self.state = State::Starting;
                        self.idle = 0;
                        vec![self.reload()]
                    }
                    State::Playing | State::Buffering | State::Starting if !self.user_paused => {
                        self.idle += 1;
                        if self.idle >= self.stall_secs {
                            self.schedule_reload(Trigger::Stall)
                        } else {
                            vec![]
                        }
                    }
                    _ => vec![],
                }
            }
            _ => vec![],
        }
    }

    /// Counts a rebuffer during playback; in adaptive mode, too many in the window ask for a bigger buffer.
    fn note_rebuffer(&mut self) -> Vec<Command> {
        let now = self.clock;
        self.rebuffers.push_back(now);
        while self
            .rebuffers
            .front()
            .is_some_and(|&t| now - t >= ADAPTIVE_WINDOW_SECS)
        {
            self.rebuffers.pop_front();
        }
        if self.adaptive && self.rebuffers.len() > ADAPTIVE_REBUFFERS {
            self.rebuffers.clear(); // raise once; the count starts again with the bigger buffer
            vec![Command::RaiseBuffer]
        } else {
            vec![]
        }
    }

    fn reload(&self) -> Command {
        Command::Reload {
            hls: self.hls,
            resume_ms: if self.live { None } else { self.last_position },
        }
    }

    fn healthy(&mut self) -> Vec<Command> {
        self.state = State::Playing;
        self.idle = 0;
        let mut out = vec![];
        if let Some((trigger, secs)) = self.episode.take() {
            out.push(Command::HideReconnecting);
            out.push(Command::Health {
                trigger,
                attempts: self.attempts,
                recovered: true,
                secs,
            });
            if self.live && self.hls != self.started_hls {
                out.push(Command::RememberHls(self.hls));
                self.started_hls = self.hls;
            }
        }
        self.attempts = 0;
        out
    }

    fn fail(&mut self, message: &str, trigger: Trigger) -> Vec<Command> {
        let (trigger, secs) = self.episode.take().unwrap_or((trigger, 0));
        self.state = State::Failed;
        vec![
            Command::HideReconnecting,
            Command::Fail(message.to_string()),
            Command::Health {
                trigger,
                attempts: self.attempts,
                recovered: false,
                secs,
            },
        ]
    }

    fn begin(&mut self, trigger: Trigger) {
        if self.episode.is_none() {
            self.episode = Some((trigger, 0));
        }
    }

    fn schedule_reload(&mut self, trigger: Trigger) -> Vec<Command> {
        self.begin(trigger);
        if !self.live && self.attempts >= VOD_MAX_ATTEMPTS {
            return self.fail("The video keeps failing to load.", trigger);
        }
        self.wait = backoff(self.attempts).as_secs();
        self.attempts += 1;
        // Every SWITCH_AFTER failed reloads, live tries the other URL form (TS ↔ HLS).
        if self.live && self.attempts > 1 && (self.attempts - 1).is_multiple_of(SWITCH_AFTER) {
            self.hls = !self.hls;
        }
        self.state = State::Reconnecting;
        vec![Command::ShowReconnecting(self.attempts)]
    }

    fn reload_now(&mut self, trigger: Trigger) -> Vec<Command> {
        self.begin(trigger);
        self.attempts += 1;
        self.state = State::Starting;
        self.idle = 0;
        vec![Command::ShowReconnecting(self.attempts), self.reload()]
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use PlayerEvent::*;

    fn opt(opts: &[(String, String)], name: &str) -> String {
        opts.iter()
            .find(|(k, _)| k == name)
            .map(|(_, v)| v.clone())
            .unwrap_or_else(|| panic!("no option {name}"))
    }

    #[test]
    fn presets_map_to_mpv_options() {
        // (preset, target seconds, demuxer bytes at 8 Mbit/s, on disk)
        let table = [
            (BufferPreset::FastZap, 2, MIN_DEMUXER_BYTES, "no"),
            (BufferPreset::Balanced, 8, MIN_DEMUXER_BYTES, "no"),
            (BufferPreset::Smooth, 30, 30 * 1_000_000 * 3 / 2, "yes"),
            (BufferPreset::MaxSmooth, 90, 90 * 1_000_000 * 3 / 2, "yes"),
            (
                BufferPreset::Custom(500),
                300,
                300 * 1_000_000 * 3 / 2,
                "yes",
            ),
            (BufferPreset::Custom(0), 1, MIN_DEMUXER_BYTES, "no"),
        ];
        for (preset, secs, bytes, disk) in table {
            let o = mpv_options(preset, DEFAULT_BITRATE_BPS);
            assert_eq!(opt(&o, "cache-pause-wait"), secs.to_string(), "{preset:?}");
            assert_eq!(opt(&o, "cache-secs"), secs.to_string(), "{preset:?}");
            assert_eq!(
                opt(&o, "demuxer-max-bytes"),
                bytes.to_string(),
                "{preset:?}"
            );
            assert_eq!(opt(&o, "cache-on-disk"), disk, "{preset:?}");
            assert_eq!(opt(&o, "cache-pause-initial"), "yes");
            assert!(opt(&o, "stream-lavf-o").contains("reconnect_streamed=1"));
        }
    }

    const TS: Command = Command::Reload {
        hls: false,
        resume_ms: None,
    };

    fn ticks(n: usize) -> Vec<PlayerEvent> {
        vec![Tick; n]
    }

    /// Feeds `events` to a fresh watchdog; returns the last commands and the state.
    fn run(live: bool, events: &[PlayerEvent]) -> (Vec<Command>, State) {
        let mut w = Watchdog::new(live, 8, false);
        let mut last = vec![];
        for e in events.iter().cloned() {
            last = w.on_event(e);
        }
        (last, w.state())
    }

    /// (live, events fed in order, commands expected from the last event, state after)
    #[test]
    fn watchdog_turns_events_into_commands() {
        let five_ticks = || vec![Tick; 5];
        let cases: Vec<(bool, Vec<PlayerEvent>, Vec<Command>, State)> = vec![
            (true, vec![Playing], vec![], State::Playing),
            (
                true,
                vec![Playing, Buffering(true)],
                vec![],
                State::Buffering,
            ),
            (
                true,
                vec![Playing, Buffering(true), Buffering(false)],
                vec![],
                State::Playing,
            ),
            (
                true,
                vec![Playing, EndOfFile],
                vec![Command::ShowReconnecting(1)],
                State::Reconnecting,
            ),
            (false, vec![Playing, EndOfFile], vec![], State::Playing),
            (
                true,
                vec![Error("x".into())],
                vec![Command::ShowReconnecting(1)],
                State::Reconnecting,
            ),
            // First retry after 1 s.
            (
                true,
                vec![Playing, EndOfFile, Tick],
                vec![TS],
                State::Starting,
            ),
            // Failing again waits 2 s; a duplicate failure while waiting changes nothing.
            (
                true,
                vec![EndOfFile, Tick, Error("x".into()), Error("y".into())],
                vec![],
                State::Reconnecting,
            ),
            (
                true,
                [vec![EndOfFile, Tick, EndOfFile], five_ticks()].concat(),
                vec![],
                State::Starting,
            ),
            (
                true,
                vec![EndOfFile, Tick, Playing],
                vec![
                    Command::HideReconnecting,
                    Command::Health {
                        trigger: Trigger::LiveEnd,
                        attempts: 1,
                        recovered: true,
                        secs: 1,
                    },
                ],
                State::Playing,
            ),
            // After a live EOF mpv still plays out its buffer: that isn't recovery, the reload still happens.
            (
                true,
                vec![Playing, EndOfFile, Playing],
                vec![],
                State::Reconnecting,
            ),
            (
                true,
                vec![Playing, EndOfFile, Playing, Tick],
                vec![TS],
                State::Starting,
            ),
            // No audio device (headless box, unplugged HDMI) is not a stream failure: never reload for it.
            (
                true,
                vec![Error(
                    "Could not open/initialize audio device -> no sound.".into(),
                )],
                vec![],
                State::Starting,
            ),
            (
                true,
                vec![
                    Playing,
                    Error("Failed to initialize audio driver 'sndio'".into()),
                ],
                vec![],
                State::Playing,
            ),
        ];
        for (live, events, expected, state) in cases {
            let mut w = Watchdog::new(live, 8, false);
            let mut last = vec![];
            for e in events.iter().cloned() {
                last = w.on_event(e);
            }
            assert_eq!(
                (last, w.state()),
                (expected, state),
                "live={live} events={events:?}"
            );
        }
    }

    /// Phase 2 rules: stalls, user pause, hard errors, wake/network, URL switch, VOD resume and give-up.
    #[test]
    fn watchdog_recovery_rules() {
        let forbidden =
            "The provider refused this stream (account expired, blocked, or too many connections).";
        // Stall timeout for an 8 s target: max(15, 8 + 10) = 18 s without progress.
        let cases: Vec<(bool, Vec<PlayerEvent>, Vec<Command>, State)> = vec![
            (
                true,
                [vec![Playing], ticks(17)].concat(),
                vec![],
                State::Playing,
            ),
            (
                true,
                [vec![Playing], ticks(18)].concat(),
                vec![Command::ShowReconnecting(1)],
                State::Reconnecting,
            ),
            (
                true,
                [vec![Playing, Buffering(true)], ticks(18)].concat(),
                vec![Command::ShowReconnecting(1)],
                State::Reconnecting,
            ),
            (
                true,
                [vec![Playing, UserPause(true)], ticks(60)].concat(),
                vec![],
                State::Playing,
            ),
            (
                true,
                ticks(18),
                vec![Command::ShowReconnecting(1)],
                State::Reconnecting,
            ), // never started
            (
                true,
                vec![Playing, Error("http: HTTP error 403 Forbidden".into())],
                vec![
                    Command::HideReconnecting,
                    Command::Fail(forbidden.into()),
                    Command::Health {
                        trigger: Trigger::Error,
                        attempts: 0,
                        recovered: false,
                        secs: 0,
                    },
                ],
                State::Failed,
            ),
            (
                true,
                vec![Error("HTTP error 403 Forbidden".into()), Tick, Playing],
                vec![],
                State::Failed,
            ),
            (
                true,
                vec![Playing, Error("HTTP error 503 Service Unavailable".into())],
                vec![Command::ShowReconnecting(1)],
                State::Reconnecting,
            ),
            // A URL that happens to contain 403 is not a refusal (mpv's "Failed to open <url>" carries the URL).
            (
                true,
                vec![
                    Playing,
                    Error("Failed to open http://h.example.invalid/live/u/p/403.ts.".into()),
                ],
                vec![Command::ShowReconnecting(1)],
                State::Reconnecting,
            ),
            // Back after the app was frozen (sleep, suspended): the connection is almost surely dead.
            (
                true,
                vec![Playing, Wake(60)],
                vec![Command::ShowReconnecting(1), TS],
                State::Starting,
            ),
            // Back from the background where it kept playing (iOS/Android background sound): no reload.
            (true, vec![Playing, Wake(1)], vec![], State::Playing),
            (
                true,
                vec![Playing, NetworkChanged],
                vec![Command::ShowReconnecting(1), TS],
                State::Starting,
            ),
            (false, vec![Playing, Wake(60)], vec![], State::Playing),
            (
                false,
                vec![Position(5000), Error("x".into()), Tick],
                vec![Command::Reload {
                    hls: false,
                    resume_ms: Some(5000),
                }],
                State::Starting,
            ),
        ];
        for (live, events, expected, state) in cases {
            assert_eq!(
                run(live, &events),
                (expected, state),
                "live={live} events={events:?}"
            );
        }
    }

    /// Three failed reloads on TS → the fourth uses HLS; when that plays, it's remembered and logged.
    #[test]
    fn live_switches_url_form_after_three_failures() {
        let mut w = Watchdog::new(true, 8, false);
        let mut reloads = vec![];
        let mut secs = 0;
        w.on_event(Playing);
        for _attempt in 1..=4 {
            w.on_event(EndOfFile);
            loop {
                secs += 1;
                let out = w.on_event(Tick);
                if let Some(Command::Reload { hls, .. }) = out.first() {
                    reloads.push(*hls);
                    break;
                }
            }
        }
        assert_eq!(reloads, [false, false, false, true]);
        assert_eq!(secs, 1 + 2 + 4 + 8);
        assert_eq!(
            w.on_event(Playing),
            vec![
                Command::HideReconnecting,
                Command::Health {
                    trigger: Trigger::LiveEnd,
                    attempts: 4,
                    recovered: true,
                    secs
                },
                Command::RememberHls(true),
            ]
        );
    }

    #[test]
    fn vod_gives_up_after_six_reloads() {
        let mut w = Watchdog::new(false, 8, false);
        let mut last = vec![];
        for _ in 0..7 {
            last = w.on_event(Error("x".into()));
            while w.state() == State::Reconnecting {
                w.on_event(Tick);
            }
        }
        assert!(matches!(last.get(1), Some(Command::Fail(_))), "{last:?}");
        assert_eq!(w.state(), State::Failed);
    }

    #[test]
    fn timeshift_window_and_disk_cap() {
        let opt = |o: &[(String, String)], k: &str| {
            o.iter().find(|(n, _)| n == k).map(|(_, v)| v.clone())
        };
        // 60 min at 8 Mbit/s = 3.6 GB when the disk has room …
        let o = timeshift_options(TIMESHIFT_DESKTOP_SECS, 8_000_000, 100_000_000_000, "/cache");
        assert_eq!(
            opt(&o, "demuxer-max-back-bytes").as_deref(),
            Some("3600000000")
        );
        assert_eq!(opt(&o, "force-seekable").as_deref(), Some("yes"));
        assert_eq!(opt(&o, "demuxer-cache-dir").as_deref(), Some("/cache"));
        assert_eq!(opt(&o, "demuxer-seekable-cache").as_deref(), Some("yes"));
        // … a quarter of the free space when it hasn't …
        let o = timeshift_options(TIMESHIFT_DESKTOP_SECS, 8_000_000, 4_000_000_000, "");
        assert_eq!(
            opt(&o, "demuxer-max-back-bytes").as_deref(),
            Some("1000000000")
        );
        assert_eq!(
            (opt(&o, "demuxer-cache-dir"), opt(&o, "cache-on-disk")),
            (None, None)
        );
        // … and off when the window is 0.
        let o = timeshift_options(0, 8_000_000, 100_000_000_000, "/cache");
        assert_eq!(
            (
                opt(&o, "demuxer-max-back-bytes").as_deref(),
                opt(&o, "force-seekable").as_deref()
            ),
            (Some("0"), Some("no"))
        );
        assert_eq!((behind_live(754.4, 0.0), behind_live(10.0, 12.0)), (754, 0));
    }

    #[test]
    fn presets_parse_store_and_step_up() {
        for (key, preset) in [
            ("fast_zap", BufferPreset::FastZap),
            ("balanced", BufferPreset::Balanced),
            ("smooth", BufferPreset::Smooth),
            ("max_smooth", BufferPreset::MaxSmooth),
            ("custom:45", BufferPreset::Custom(45)),
        ] {
            assert_eq!(BufferPreset::parse(key), preset);
            assert_eq!(preset.key(), key);
        }
        assert_eq!(BufferPreset::parse("nonsense"), BufferPreset::Balanced);
        assert_eq!(BufferPreset::parse("custom:x"), BufferPreset::Balanced);
        let steps: Vec<BufferPreset> = [
            BufferPreset::FastZap,
            BufferPreset::Balanced,
            BufferPreset::Custom(20),
            BufferPreset::MaxSmooth,
            BufferPreset::Custom(200),
        ]
        .into_iter()
        .map(BufferPreset::step_up)
        .collect();
        assert_eq!(
            steps,
            [
                BufferPreset::Balanced,
                BufferPreset::Smooth,
                BufferPreset::Smooth,
                BufferPreset::MaxSmooth,
                BufferPreset::MaxSmooth
            ]
        );
    }

    /// Adaptive mode: the 4th rebuffer within 10 minutes asks for more buffer, once; outside the window it doesn't.
    #[test]
    fn adaptive_mode_raises_after_too_many_rebuffers() {
        let rebuffer = |w: &mut Watchdog| {
            w.on_event(Playing);
            let out = w.on_event(Buffering(true));
            w.on_event(Buffering(false));
            out
        };
        let mut w = Watchdog::new(true, 8, false).with_adaptive(true);
        assert!((0..3).all(|_| rebuffer(&mut w).is_empty()));
        assert_eq!(rebuffer(&mut w), vec![Command::RaiseBuffer]);
        assert!(
            rebuffer(&mut w).is_empty(),
            "the count starts again after raising"
        );

        let mut slow = Watchdog::new(true, 8, false).with_adaptive(true);
        for _ in 0..6 {
            assert!(rebuffer(&mut slow).is_empty());
            for _ in 0..200 {
                slow.on_event(Playing);
                slow.on_event(Tick);
            }
        }
        let mut off = Watchdog::new(true, 8, false);
        assert!(
            (0..6).all(|_| rebuffer(&mut off).is_empty()),
            "only in adaptive mode"
        );
    }

    #[test]
    fn backoff_caps_at_30_seconds() {
        let secs: Vec<u64> = (0..8).map(|a| backoff(a).as_secs()).collect();
        assert_eq!(secs, [1, 2, 4, 8, 15, 30, 30, 30]);
    }
}
