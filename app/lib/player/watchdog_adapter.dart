// The Dart half of the playback watchdog (docs/ARCHITECTURE.md, "Playback pipeline"). It owns no policy: it sets
// the buffer preset's mpv options on media_kit's player, translates media_kit's streams (and app resume) into
// watchdog events, and runs the commands the Rust watchdog returns. All decisions live in
// crates/gerdtv-core/src/playback.rs.
//
// Debug hints: `reconnecting` > 0 means the watchdog is between reloads; `failure` set means it stopped on a hard
// error (login refused, blocked). Set PlayerConfiguration.logLevel to MPVLogLevel.debug to see mpv's own reconnect
// attempts (FFmpeg's stream-lavf-o reconnect runs before ours).

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';

import '../src/rust/api/playback.dart';

/// Builds the play URL: `hls` asks for the `.m3u8` form of a live channel (it holds credentials: never log it).
typedef UrlFor = String Function({required bool hls});

/// One finished recovery episode, for stream_health.
typedef OnHealth = void Function(
  String trigger,
  int attempts,
  bool recovered,
  int secs,
);

class WatchdogAdapter {
  WatchdogAdapter(
    this.player, {
    this.onHealth,
    this.onRememberHls,
    this.onRaiseBuffer,
    this.onBitrate,
  });

  /// Adaptive mode asked for more buffer on this channel; returns the new target seconds (applied at once).
  final int Function()? onRaiseBuffer;

  /// mpv measured the stream's video bitrate (bit/s): stored per channel to size the cache next time.
  final void Function(int bps)? onBitrate;

  /// The current buffer target in seconds (the overlay shows buffered vs. this).
  final ValueNotifier<int> target = ValueNotifier(8);

  /// Create every player with this: the watchdog needs mpv's warnings, because FFmpeg reports HTTP status
  /// errors ("HTTP error 403 Forbidden") at warn level, and media_kit only asks for errors by default.
  static const playerConfiguration = PlayerConfiguration(
    logLevel: MPVLogLevel.warn,
  );

  final Player player;
  final OnHealth? onHealth;

  /// The other URL form worked after a switch: store it for this channel (Library.setPreferHls).
  final void Function(bool hls)? onRememberHls;

  /// The current reconnect attempt, or 0 while playback is healthy (the overlay shows "Reconnecting (n)…").
  final ValueNotifier<int> reconnecting = ValueNotifier(0);

  /// Set when the watchdog gave up (a message for the user); null while playing or retrying.
  final ValueNotifier<String?> failure = ValueNotifier(null);

  Watchdog? _watchdog;
  BufferPreset _preset = BufferPreset.balanced;
  int _customSeconds = 0;
  bool _bitrateReported = false;

  /// Sets a preset's mpv options (sized for [bitrate] when known) and the target the overlay compares with.
  Future<void> _applyBuffer(
    NativePlayer native,
    BufferPreset preset,
    int customSeconds,
    int? bitrate,
  ) async {
    final options = bufferOptions(
      preset: preset,
      customSeconds: customSeconds,
      bitrateBps: bitrate == null || bitrate <= 0 ? null : BigInt.from(bitrate),
    );
    for (final o in options) {
      await native.setProperty(o.name, o.value);
      if (o.name == 'cache-pause-wait') target.value = int.parse(o.value);
    }
  }

  UrlFor? _urlFor;
  final List<StreamSubscription<Object?>> _subs = [];
  Timer? _ticker;

  /// When the last tick ran: a frozen app (sleep, suspended) misses ticks, one playing in the background doesn't.
  DateTime _lastTick = DateTime.now();
  AppLifecycleListener? _lifecycle;
  Duration _lastPosition = Duration.zero;

  /// Opens a stream with [preset]'s buffer options and starts watching it.
  Future<void> play(
    UrlFor urlFor, {
    required bool live,
    BufferPreset preset = BufferPreset.balanced,
    int customSeconds = 0,
    int? bitrate,
    bool adaptive = false,
    bool preferHls = false,
    List<MpvOption> extraOptions = const [],
    String userAgent = '',
    Duration? start,
  }) async {
    await stop();
    _urlFor = urlFor;
    _preset = preset;
    _customSeconds = customSeconds;
    final native = player.platform as NativePlayer;
    await _applyBuffer(native, preset, customSeconds, bitrate);
    for (final o in extraOptions) {
      await native.setProperty(o.name, o.value);
    }
    // One mpv plays everything and keeps its properties, so the profile's own User-Agent is set or put back to mpv's
    // default ("libmpv") at every start.
    await native.setProperty(
      'user-agent',
      userAgent.isEmpty ? 'libmpv' : userAgent,
    );
    _watchdog = Watchdog(
      live: live,
      targetSeconds: target.value,
      preferHls: preferHls,
      adaptive: adaptive,
    );
    _bitrateReported = false;
    // mpv's measured video bitrate (bit/s): reported once per stream; the cache is resized for it right away.
    await native.observeProperty('video-bitrate', (v) async {
      final bps = double.tryParse(v)?.round() ?? 0;
      if (bps > 0 && !_bitrateReported) {
        _bitrateReported = true;
        onBitrate?.call(bps);
        await _applyBuffer(
          native,
          _preset,
          _customSeconds,
          bps,
        ); // demuxer-max-bytes can change while playing
      }
    });
    _subs.addAll([
      // Position moving forward is the only reliable sign that playback really advances.
      player.stream.position.listen((p) {
        if (p > _lastPosition) {
          _run(
            _watchdog?.onPosition(positionMs: BigInt.from(p.inMilliseconds)),
          );
        }
        _lastPosition = p;
      }),
      player.stream.buffering.listen(
        (b) => _run(_watchdog?.onBuffering(active: b)),
      ),
      player.stream.completed.listen((done) {
        if (done) _run(_watchdog?.onEndOfFile());
      }),
      player.stream.error.listen((e) => _run(_watchdog?.onError(message: e))),
      // FFmpeg reports HTTP status errors ("http: HTTP error 403 Forbidden") as warnings, which media_kit
      // never puts on `error`; read them from mpv's log (needs [playerConfiguration]).
      player.stream.log.listen((l) {
        if (l.prefix == 'ffmpeg' && l.text.startsWith('http: HTTP error')) {
          _run(_watchdog?.onError(message: l.text));
        }
      }),
    ]);
    _lastTick = DateTime.now();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      _lastTick = DateTime.now();
      _run(_watchdog?.onTick());
    });
    // Back from sleep or the background: the core reloads live only if the app was frozen (seconds since the
    // last tick), since a stream that kept playing in the background is fine.
    _lifecycle = AppLifecycleListener(onResume: wake);
    await player.open(
      Media(urlFor(hls: preferHls), start: start),
    ); // start: continue watching
  }

  /// A new buffer for the running stream (the player's "Buffer for this channel"); mpv applies it at once.
  Future<void> applyBuffer(BufferPreset preset, int customSeconds) async {
    _preset = preset;
    _customSeconds = customSeconds;
    await _applyBuffer(
      player.platform as NativePlayer,
      preset,
      customSeconds,
      null,
    );
  }

  /// User pause/resume: a paused stream is never treated as stalled.
  Future<void> pause() async {
    _run(_watchdog?.onUserPause(paused: true));
    await player.pause();
  }

  Future<void> resume() async {
    _run(_watchdog?.onUserPause(paused: false));
    await player.play();
  }

  /// Platform code calls these on resume and on connectivity changes.
  void wake() => _run(
    _watchdog?.onWake(
      frozenSecs: BigInt.from(DateTime.now().difference(_lastTick).inSeconds),
    ),
  );
  void networkChanged() => _run(_watchdog?.onNetworkChanged());

  Future<void> stop() async {
    _ticker?.cancel();
    try {
      await (player.platform as NativePlayer).unobserveProperty(
        'video-bitrate',
      );
    } catch (_) {
      // Not observed yet.
    }
    _lifecycle?.dispose();
    _lifecycle = null;
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    _watchdog = null;
    reconnecting.value = 0;
    failure.value = null;
  }

  void _run(List<WatchdogCommand>? commands) {
    for (final c in commands ?? const <WatchdogCommand>[]) {
      switch (c.kind) {
        case CommandKind.reload:
          _lastPosition = Duration.zero;
          // Live: reopening joins at the live edge. VOD: continue where it stopped.
          final ms = c.resumeMs;
          unawaited(
            player.open(
              Media(
                _urlFor!(hls: c.hls),
                start: ms == null ? null : Duration(milliseconds: ms.toInt()),
              ),
            ),
          );
        case CommandKind.showReconnecting:
          reconnecting.value = c.attempt;
        case CommandKind.raiseBuffer:
          final secs = onRaiseBuffer?.call();
          if (secs != null) {
            _preset = BufferPreset.custom;
            _customSeconds = secs;
            unawaited(
              _applyBuffer(
                player.platform as NativePlayer,
                _preset,
                secs,
                null,
              ),
            );
          }
        case CommandKind.hideReconnecting:
          reconnecting.value = 0;
        case CommandKind.fail:
          failure.value = c.message;
          unawaited(player.stop());
        case CommandKind.rememberHls:
          onRememberHls?.call(c.hls);
        case CommandKind.health:
          onHealth?.call(c.trigger, c.attempt, c.recovered, c.secs.toInt());
      }
    }
  }
}
