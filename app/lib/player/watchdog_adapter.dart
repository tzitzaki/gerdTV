// The Dart half of the playback watchdog (docs/ARCHITECTURE.md, "Playback pipeline"). It owns no policy: it sets
// the buffer preset's mpv options on media_kit's player, translates media_kit's streams into watchdog events, and
// runs the commands the Rust watchdog returns. All decisions live in crates/gerdtv-core/src/playback.rs.
//
// Debug hints: `reconnecting` > 0 means the watchdog is between reloads; set PlayerConfiguration.logLevel to
// MPVLogLevel.debug to see mpv's own reconnect attempts (FFmpeg's stream-lavf-o reconnect runs before ours).

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

import '../src/rust/api/playback.dart';

class WatchdogAdapter {
  WatchdogAdapter(this.player);

  final Player player;

  /// The current reconnect attempt, or 0 while playback is healthy (the overlay shows "Reconnecting (n)…").
  final ValueNotifier<int> reconnecting = ValueNotifier(0);

  Watchdog? _watchdog;
  String? _url;
  final List<StreamSubscription<Object?>> _subs = [];
  Timer? _ticker;
  Duration _lastPosition = Duration.zero;

  /// Opens [url] with [preset]'s buffer options and starts watching it.
  Future<void> play(
    String url, {
    required bool live,
    BufferPreset preset = BufferPreset.balanced,
  }) async {
    await stop();
    _url = url;
    _watchdog = Watchdog(live: live);
    final native = player.platform as NativePlayer;
    for (final o in bufferOptions(preset: preset, customSeconds: 0)) {
      await native.setProperty(o.name, o.value);
    }
    _subs.addAll([
      // Position moving forward is the only reliable sign that playback really advances.
      player.stream.position.listen((p) {
        if (p > _lastPosition) _run(_watchdog?.onPlaying());
        _lastPosition = p;
      }),
      player.stream.buffering.listen(
        (b) => _run(_watchdog?.onBuffering(active: b)),
      ),
      player.stream.completed.listen((done) {
        if (done) _run(_watchdog?.onEndOfFile());
      }),
      player.stream.error.listen((e) => _run(_watchdog?.onError(message: e))),
    ]);
    _ticker = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _run(_watchdog?.onTick()),
    );
    await player.open(Media(url));
  }

  Future<void> stop() async {
    _ticker?.cancel();
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    _watchdog = null;
    reconnecting.value = 0;
  }

  void _run(List<WatchdogCommand>? commands) {
    for (final c in commands ?? const <WatchdogCommand>[]) {
      switch (c.kind) {
        case CommandKind.reload:
          _lastPosition = Duration.zero;
          // Reopening a live URL joins at the live edge.
          unawaited(player.open(Media(_url!)));
        case CommandKind.showReconnecting:
          reconnecting.value = c.attempt;
        case CommandKind.hideReconnecting:
          reconnecting.value = 0;
      }
    }
  }
}
