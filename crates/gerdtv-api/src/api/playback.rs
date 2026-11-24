//! Bridge surface for playback policy (logic: gerdtv_core::playback). Mirror types only, converted 1:1.

use gerdtv_core::playback as core;
use std::sync::Mutex;

/// A buffer preset as the UI names it. Data-free enums only on this surface: flutter_rust_bridge needs the
/// `freezed` package for enums with fields, which isn't worth a dependency (CLAUDE.md, "Dependencies").
pub enum BufferPreset {
    FastZap,
    Balanced,
    Smooth,
    MaxSmooth,
    Custom,
}

fn preset(p: BufferPreset, custom_seconds: u32) -> core::BufferPreset {
    match p {
        BufferPreset::FastZap => core::BufferPreset::FastZap,
        BufferPreset::Balanced => core::BufferPreset::Balanced,
        BufferPreset::Smooth => core::BufferPreset::Smooth,
        BufferPreset::MaxSmooth => core::BufferPreset::MaxSmooth,
        BufferPreset::Custom => core::BufferPreset::Custom(custom_seconds),
    }
}

/// A preset as the UI shows it: the kind plus its seconds (for Custom, the chosen value).
pub struct BufferChoice {
    pub preset: BufferPreset,
    pub seconds: u32,
}

pub(crate) fn choice(p: core::BufferPreset) -> BufferChoice {
    let preset = match p {
        core::BufferPreset::FastZap => BufferPreset::FastZap,
        core::BufferPreset::Balanced => BufferPreset::Balanced,
        core::BufferPreset::Smooth => BufferPreset::Smooth,
        core::BufferPreset::MaxSmooth => BufferPreset::MaxSmooth,
        core::BufferPreset::Custom(_) => BufferPreset::Custom,
    };
    BufferChoice {
        preset,
        seconds: p.seconds(),
    }
}

pub(crate) fn from_choice(preset: BufferPreset, seconds: u32) -> core::BufferPreset {
    self::preset(preset, seconds)
}

/// The stored form of a preset ("smooth", "custom:45" …), for profile settings.
#[flutter_rust_bridge::frb(sync)]
pub fn buffer_key(preset: BufferPreset, custom_seconds: u32) -> String {
    self::preset(preset, custom_seconds).key()
}

/// Parses a stored preset (unknown → Balanced).
#[flutter_rust_bridge::frb(sync)]
pub fn parse_buffer(key: String) -> BufferChoice {
    choice(core::BufferPreset::parse(&key))
}

pub struct MpvOption {
    pub name: String,
    pub value: String,
}

/// The mpv options to set before opening a stream (bitrate unknown → the core's default estimate).
#[flutter_rust_bridge::frb(sync)]
pub fn buffer_options(
    preset: BufferPreset,
    custom_seconds: u32,
    bitrate_bps: Option<u64>,
) -> Vec<MpvOption> {
    core::mpv_options(
        self::preset(preset, custom_seconds),
        bitrate_bps.unwrap_or(core::DEFAULT_BITRATE_BPS),
    )
    .into_iter()
    .map(|(name, value)| MpvOption { name, value })
    .collect()
}

/// Options for pausing/rewinding live TV (window 0 = off; the window comes from settings, default below).
#[flutter_rust_bridge::frb(sync)]
pub fn timeshift_options(
    window_seconds: u32,
    bitrate_bps: Option<u64>,
    free_disk_bytes: u64,
    cache_dir: String,
) -> Vec<MpvOption> {
    core::timeshift_options(
        window_seconds,
        bitrate_bps.unwrap_or(core::DEFAULT_BITRATE_BPS),
        free_disk_bytes,
        &cache_dir,
    )
    .into_iter()
    .map(|(name, value)| MpvOption { name, value })
    .collect()
}

/// The default timeshift window for this form factor, in seconds.
#[flutter_rust_bridge::frb(sync)]
pub fn default_timeshift_seconds(desktop: bool) -> u32 {
    if desktop {
        core::TIMESHIFT_DESKTOP_SECS
    } else {
        core::TIMESHIFT_MOBILE_SECS
    }
}

/// Seconds behind live, for the overlay.
#[flutter_rust_bridge::frb(sync)]
pub fn behind_live(cache_end_seconds: f64, position_seconds: f64) -> u32 {
    core::behind_live(cache_end_seconds, position_seconds)
}

pub enum CommandKind {
    RaiseBuffer,
    Reload,
    ShowReconnecting,
    HideReconnecting,
    Fail,
    RememberHls,
    Health,
}

/// A watchdog command; which fields matter depends on `kind`:
/// Reload: `hls`, `resume_ms` · ShowReconnecting: `attempt` · Fail: `message` · RememberHls: `hls` ·
/// Health: `trigger`, `attempt` (attempts), `recovered`, `secs`.
pub struct WatchdogCommand {
    pub kind: CommandKind,
    pub attempt: u32,
    pub hls: bool,
    pub resume_ms: Option<u64>,
    pub message: String,
    pub trigger: String,
    pub recovered: bool,
    pub secs: u64,
}

impl WatchdogCommand {
    fn of(kind: CommandKind) -> Self {
        WatchdogCommand {
            kind,
            attempt: 0,
            hls: false,
            resume_ms: None,
            message: String::new(),
            trigger: String::new(),
            recovered: false,
            secs: 0,
        }
    }
}

/// One watchdog per playing stream, owned by the Dart adapter.
#[flutter_rust_bridge::frb(opaque)]
pub struct Watchdog(Mutex<core::Watchdog>);

impl Watchdog {
    /// `target_seconds`: the buffer preset's target; `prefer_hls`: what worked last time for this channel.
    #[flutter_rust_bridge::frb(sync)]
    pub fn new(live: bool, target_seconds: u32, prefer_hls: bool, adaptive: bool) -> Watchdog {
        Watchdog(Mutex::new(
            core::Watchdog::new(live, target_seconds, prefer_hls).with_adaptive(adaptive),
        ))
    }

    // One method per player event (see BufferPreset for why not one enum with fields).
    #[flutter_rust_bridge::frb(sync)]
    pub fn on_position(&self, position_ms: u64) -> Vec<WatchdogCommand> {
        self.feed(core::PlayerEvent::Position(position_ms))
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn on_buffering(&self, active: bool) -> Vec<WatchdogCommand> {
        self.feed(core::PlayerEvent::Buffering(active))
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn on_user_pause(&self, paused: bool) -> Vec<WatchdogCommand> {
        self.feed(core::PlayerEvent::UserPause(paused))
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn on_end_of_file(&self) -> Vec<WatchdogCommand> {
        self.feed(core::PlayerEvent::EndOfFile)
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn on_error(&self, message: String) -> Vec<WatchdogCommand> {
        self.feed(core::PlayerEvent::Error(message))
    }

    /// The app came back from sleep or the background; `frozen_secs`: seconds since the last tick.
    #[flutter_rust_bridge::frb(sync)]
    pub fn on_wake(&self, frozen_secs: u64) -> Vec<WatchdogCommand> {
        self.feed(core::PlayerEvent::Wake(frozen_secs))
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn on_network_changed(&self) -> Vec<WatchdogCommand> {
        self.feed(core::PlayerEvent::NetworkChanged)
    }

    /// Call once a second while a stream is open.
    #[flutter_rust_bridge::frb(sync)]
    pub fn on_tick(&self) -> Vec<WatchdogCommand> {
        self.feed(core::PlayerEvent::Tick)
    }

    fn feed(&self, event: core::PlayerEvent) -> Vec<WatchdogCommand> {
        self.0
            .lock()
            .unwrap()
            .on_event(event)
            .into_iter()
            .map(|c| match c {
                core::Command::Reload { hls, resume_ms } => WatchdogCommand {
                    hls,
                    resume_ms,
                    ..WatchdogCommand::of(CommandKind::Reload)
                },
                core::Command::ShowReconnecting(attempt) => WatchdogCommand {
                    attempt,
                    ..WatchdogCommand::of(CommandKind::ShowReconnecting)
                },
                core::Command::RaiseBuffer => WatchdogCommand::of(CommandKind::RaiseBuffer),
                core::Command::HideReconnecting => {
                    WatchdogCommand::of(CommandKind::HideReconnecting)
                }
                core::Command::Fail(message) => WatchdogCommand {
                    message,
                    ..WatchdogCommand::of(CommandKind::Fail)
                },
                core::Command::RememberHls(hls) => WatchdogCommand {
                    hls,
                    ..WatchdogCommand::of(CommandKind::RememberHls)
                },
                core::Command::Health {
                    trigger,
                    attempts,
                    recovered,
                    secs,
                } => WatchdogCommand {
                    trigger: trigger.as_str().to_string(),
                    attempt: attempts,
                    recovered,
                    secs,
                    ..WatchdogCommand::of(CommandKind::Health)
                },
            })
            .collect()
    }
}
