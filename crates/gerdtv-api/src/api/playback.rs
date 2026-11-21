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

pub enum CommandKind {
    Reload,
    ShowReconnecting,
    HideReconnecting,
}

/// A watchdog command; `attempt` is set for ShowReconnecting.
pub struct WatchdogCommand {
    pub kind: CommandKind,
    pub attempt: u32,
}

/// One watchdog per playing stream, owned by the Dart adapter.
#[flutter_rust_bridge::frb(opaque)]
pub struct Watchdog(Mutex<core::Watchdog>);

impl Watchdog {
    #[flutter_rust_bridge::frb(sync)]
    pub fn new(live: bool) -> Watchdog {
        Watchdog(Mutex::new(core::Watchdog::new(live)))
    }

    // One method per player event (see BufferPreset for why not one enum with fields).
    #[flutter_rust_bridge::frb(sync)]
    pub fn on_playing(&self) -> Vec<WatchdogCommand> {
        self.feed(core::PlayerEvent::Playing)
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn on_buffering(&self, active: bool) -> Vec<WatchdogCommand> {
        self.feed(core::PlayerEvent::Buffering(active))
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn on_end_of_file(&self) -> Vec<WatchdogCommand> {
        self.feed(core::PlayerEvent::EndOfFile)
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn on_error(&self, message: String) -> Vec<WatchdogCommand> {
        self.feed(core::PlayerEvent::Error(message))
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
                core::Command::Reload => WatchdogCommand {
                    kind: CommandKind::Reload,
                    attempt: 0,
                },
                core::Command::ShowReconnecting(attempt) => WatchdogCommand {
                    kind: CommandKind::ShowReconnecting,
                    attempt,
                },
                core::Command::HideReconnecting => WatchdogCommand {
                    kind: CommandKind::HideReconnecting,
                    attempt: 0,
                },
            })
            .collect()
    }
}
