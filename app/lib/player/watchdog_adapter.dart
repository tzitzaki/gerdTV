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
  WatchdogAdapter(this.player, {this.onHealth, this.onRememberHls});

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
  UrlFor? _urlFor;
  final List<StreamSubscription<Object?>> _subs = [];
  Timer? _ticker;
  AppLifecycleListener? _lifecycle;
  Duration _lastPosition = Duration.zero;

  /// Opens a stream with [preset]'s buffer options and starts watching it.
  Future<void> play(
    UrlFor urlFor, {
    required bool live,
    BufferPreset preset = BufferPreset.balanced,
    bool preferHls = false,
  }) async {
    await stop();
    _urlFor = urlFor;
    final native = player.platform as NativePlayer;
    var target = 8;
    for (final o in bufferOptions(preset: preset, customSeconds: 0)) {
      await native.setProperty(o.name, o.value);
      if (o.name == 'cache-pause-wait') target = int.parse(o.value);
    }
    _watchdog = Watchdog(
      live: live,
      targetSeconds: target,
      preferHls: preferHls,
    );
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
    _ticker = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _run(_watchdog?.onTick()),
    );
    // Back from sleep or the background: a live connection is almost surely dead.
    _lifecycle = AppLifecycleListener(onResume: wake);
    await player.open(Media(urlFor(hls: preferHls)));
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
  void wake() => _run(_watchdog?.onWake());
  void networkChanged() => _run(_watchdog?.onNetworkChanged());

  Future<void> stop() async {
    _ticker?.cancel();
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
