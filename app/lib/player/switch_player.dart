// One player for the app whatever engine plays (docs/ARCHITECTURE.md, "AVPlayer engine"): on Apple platforms live
// channels play in AVPlayer and everything else in mpv, but screens subscribe to `session.player` once (before they
// know what they will play). [SwitchPlatformPlayer] is that stable player: it forwards the active engine's state and
// streams and sends every command to it. Switching engines is the session's job (Session._start).
// Debugging: a screen that shows the previous engine's position subscribed to an engine's Player directly instead.

import 'dart:async';

import 'package:media_kit/media_kit.dart';

class SwitchPlatformPlayer extends PlatformPlayer {
  SwitchPlatformPlayer(PlatformPlayer first)
    : _active = first,
      super(configuration: first.configuration) {
    _follow(first);
  }

  PlatformPlayer _active;
  final List<StreamSubscription<Object?>> _subs = [];

  /// The engine commands go to.
  PlatformPlayer get active => _active;

  /// Follows [engine] from now on (the previous one should be stopped by the caller).
  void switchTo(PlatformPlayer engine) {
    if (identical(engine, _active)) return;
    // Muted (or turned down) stays so when the other engine takes over.
    final volume = state.volume;
    if (engine.state.volume != volume) engine.setVolume(volume);
    _active = engine;
    _follow(engine);
  }

  void _follow(PlatformPlayer e) {
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    state = e.state;
    void pipe<T>(Stream<T> from, StreamController<T> to) => _subs.add(
      from.listen((v) {
        state = e.state;
        if (!to.isClosed) to.add(v);
      }),
    );
    pipe(e.stream.playing, playingController);
    pipe(e.stream.completed, completedController);
    pipe(e.stream.position, positionController);
    pipe(e.stream.duration, durationController);
    pipe(e.stream.volume, volumeController);
    pipe(e.stream.rate, rateController);
    pipe(e.stream.buffering, bufferingController);
    pipe(e.stream.buffer, bufferController);
    pipe(e.stream.width, widthController);
    pipe(e.stream.height, heightController);
    pipe(e.stream.tracks, tracksController);
    pipe(e.stream.track, trackController);
    pipe(e.stream.error, errorController);
    pipe(e.stream.log, logController);
  }

  @override
  Future<void> open(Playable playable, {bool play = true}) =>
      _active.open(playable, play: play);
  @override
  Future<void> stop() => _active.stop();
  @override
  Future<void> play() => _active.play();
  @override
  Future<void> pause() => _active.pause();
  @override
  Future<void> playOrPause() => _active.playOrPause();
  @override
  Future<void> seek(Duration duration) => _active.seek(duration);
  @override
  Future<void> setVolume(double volume) => _active.setVolume(volume);
  @override
  Future<void> setRate(double rate) => _active.setRate(rate);
  @override
  Future<void> setAudioTrack(AudioTrack track) => _active.setAudioTrack(track);
  @override
  Future<void> setSubtitleTrack(SubtitleTrack track) =>
      _active.setSubtitleTrack(track);
  @override
  Future<void> setVideoTrack(VideoTrack track) => _active.setVideoTrack(track);

  @override
  Future<void> dispose() async {
    for (final s in _subs) {
      await s.cancel();
    }
    await super.dispose();
  }
}
