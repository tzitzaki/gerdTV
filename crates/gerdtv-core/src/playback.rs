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

/// What the player reports (translated from media_kit's streams by the Dart adapter).
#[derive(Debug, Clone, PartialEq)]
pub enum PlayerEvent {
    /// Playback is advancing.
    Playing,
    /// mpv paused for cache (true) or resumed (false).
    Buffering(bool),
    /// The stream ended.
    EndOfFile,
    /// mpv reported an error (message already redacted by the adapter's caller).
    Error(String),
    /// A second passed; drives timeouts and backoff.
    Tick,
}

/// What the adapter should do.
#[derive(Debug, Clone, PartialEq)]
pub enum Command {
    /// Reopen the stream (live: at the live edge).
    Reload,
    /// Tell the user we're reconnecting (attempt n).
    ShowReconnecting(u32),
    /// Playback is healthy again; hide any reconnect notice.
    HideReconnecting,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum State {
    Starting,
    Playing,
    Buffering,
    Reconnecting,
}

/// Reload backoff: 1, 2, 4, 8, 15, 30 s, then 30 s for every further attempt.
pub fn backoff(attempt: u32) -> Duration {
    const STEPS: [u64; 6] = [1, 2, 4, 8, 15, 30];
    Duration::from_secs(STEPS[(attempt as usize).min(STEPS.len() - 1)])
}

/// The watchdog for one playing stream. Feed it every event; run every command it returns.
#[derive(Debug)]
pub struct Watchdog {
    live: bool,
    state: State,
    /// Reload attempts since the last healthy playback.
    attempts: u32,
    /// Seconds left until the next reload while reconnecting.
    wait: u64,
}

impl Watchdog {
    pub fn new(live: bool) -> Watchdog {
        Watchdog {
            live,
            state: State::Starting,
            attempts: 0,
            wait: 0,
        }
    }

    pub fn state(&self) -> State {
        self.state
    }

    pub fn on_event(&mut self, event: PlayerEvent) -> Vec<Command> {
        match (self.state, event) {
            (_, PlayerEvent::Playing) => {
                let was_reconnecting = self.attempts > 0;
                self.state = State::Playing;
                self.attempts = 0;
                if was_reconnecting {
                    vec![Command::HideReconnecting]
                } else {
                    vec![]
                }
            }
            (State::Playing, PlayerEvent::Buffering(true)) => {
                self.state = State::Buffering;
                vec![]
            }
            (State::Buffering, PlayerEvent::Buffering(false)) => {
                self.state = State::Playing;
                vec![]
            }
            // A live stream never ends on its own: an end of file is a failure. VOD ends normally.
            (_, PlayerEvent::EndOfFile) if !self.live => vec![],
            (State::Reconnecting, PlayerEvent::EndOfFile | PlayerEvent::Error(_)) => vec![],
            (_, PlayerEvent::EndOfFile | PlayerEvent::Error(_)) => self.schedule_reload(),
            (State::Reconnecting, PlayerEvent::Tick) => {
                self.wait = self.wait.saturating_sub(1);
                if self.wait == 0 {
                    // Wait in Starting for the reload to play; a new failure schedules the next attempt.
                    self.state = State::Starting;
                    vec![Command::Reload]
                } else {
                    vec![]
                }
            }
            _ => vec![],
        }
    }

    fn schedule_reload(&mut self) -> Vec<Command> {
        self.wait = backoff(self.attempts).as_secs();
        self.attempts += 1;
        self.state = State::Reconnecting;
        vec![Command::ShowReconnecting(self.attempts)]
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
                vec![Command::Reload],
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
                vec![Command::HideReconnecting],
                State::Playing,
            ),
        ];
        for (live, events, expected, state) in cases {
            let mut w = Watchdog::new(live);
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

    #[test]
    fn backoff_caps_at_30_seconds() {
        let secs: Vec<u64> = (0..8).map(|a| backoff(a).as_secs()).collect();
        assert_eq!(secs, [1, 2, 4, 8, 15, 30, 30, 30]);
    }
}
