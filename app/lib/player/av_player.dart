// The AVPlayer engine for live channels on iOS and macOS (owner decision; docs/ARCHITECTURE.md, "AVPlayer engine"),
// dressed as a media_kit player: [AvPlatformPlayer] is a media_kit PlatformPlayer over the native plugin
// (app/packages/gerdtv_avplayer), so `Player(platformPlayer: …)` drives media_kit's controls, the timeshift bar and
// the now-playing bar exactly like mpv; [avVideoController] gives media_kit's Video widget its texture.
// The stream is the core's local HLS (gerdtv_core::hls): its timeline is AVPlayer's, position and seekable end map
// onto media_kit's position and buffer (the live edge, as mpv's cache end does).
// Debugging: the native side logs "GerdtvAvPlayer:"; `state` events arrive every 0.25 s while something plays.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:gerdtv_avplayer/gerdtv_avplayer.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

class AvPlatformPlayer extends PlatformPlayer {
  AvPlatformPlayer() : super(configuration: const PlayerConfiguration()) {
    _channel.setMethodCallHandler(_onCall);
  }

  static const _channel = MethodChannel(avPlayerChannel);

  /// The Flutter texture with the picture (set by the first open).
  final ValueNotifier<int?> textureId = ValueNotifier(null);

  /// Set while Apple's Picture-in-Picture window shows the stream.
  final ValueNotifier<bool> pip = ValueNotifier(false);

  /// Opens [url] with [bufferSecs] of forward buffer (the channel's preset).
  Future<void> openUrl(String url, {required int bufferSecs}) async {
    _update(
      const PlayerState().copyWith(volume: state.volume, rate: state.rate),
    );
    textureId.value = await _channel.invokeMethod<int>('open', {
      'url': url,
      'bufferSecs': bufferSecs.toDouble(),
    });
  }

  Future<void> setBuffer(int secs) =>
      _channel.invokeMethod('setBuffer', {'secs': secs.toDouble()});

  /// Starts Picture-in-Picture (false when it isn't possible right now).
  Future<bool> startPip() async =>
      await _channel.invokeMethod<bool>('startPip') ?? false;

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    if (playable is Media) await openUrl(playable.uri, bufferSecs: 8);
  }

  @override
  Future<void> stop() async {
    await _channel.invokeMethod('stop');
    pip.value = false;
    _update(const PlayerState());
  }

  @override
  Future<void> play() => _channel.invokeMethod('play');

  @override
  Future<void> pause() => _channel.invokeMethod('pause');

  @override
  Future<void> playOrPause() => state.playing ? pause() : play();

  @override
  Future<void> seek(Duration duration) =>
      _channel.invokeMethod('seek', {'secs': duration.inMilliseconds / 1000});

  /// media_kit's volume is 0…100, AVPlayer's 0…1.
  @override
  Future<void> setVolume(double volume) async {
    await _channel.invokeMethod('setVolume', {'volume': volume / 100});
    _update(state.copyWith(volume: volume));
  }

  @override
  Future<void> setRate(double rate) async {
    await _channel.invokeMethod('setRate', {'rate': rate});
    _update(state.copyWith(rate: rate));
  }

  /// Tracks are "av:`index`" (the stream's option), "no" (off) or "auto" (AVPlayer's choice, left as it is).
  @override
  Future<void> setAudioTrack(AudioTrack track) => _select('audio', track.id);

  @override
  Future<void> setSubtitleTrack(SubtitleTrack track) =>
      _select('subtitle', track.id);

  @override
  Future<void> setVideoTrack(VideoTrack track) async {}

  Future<void> _select(String kind, String id) async {
    if (id == 'auto') return;
    final index = id.startsWith('av:') ? int.parse(id.substring(3)) : -1;
    await _channel.invokeMethod('selectTrack', {'kind': kind, 'index': index});
  }

  Future<void> _onCall(MethodCall call) async {
    if (call.method != 'state') return;
    final m = Map<String, Object?>.from(call.arguments as Map);
    Duration secs(String k) =>
        Duration(milliseconds: (((m[k] as num?) ?? 0) * 1000).round());
    final audio = [...?(m['audio'] as List?)?.cast<String>()];
    final subs = [...?(m['subtitles'] as List?)?.cast<String>()];
    final audioIndex = (m['audioIndex'] as int?) ?? -1;
    final subIndex = (m['subtitleIndex'] as int?) ?? -1;
    final audioTracks = [
      for (final (i, name) in audio.indexed) AudioTrack('av:$i', name, null),
    ];
    final subTracks = [
      for (final (i, name) in subs.indexed) SubtitleTrack('av:$i', name, null),
    ];
    pip.value = m['pip'] == true;
    _update(
      state.copyWith(
        playing: m['playing'] == true,
        buffering: m['buffering'] == true,
        position: secs('position'),
        duration: secs('duration'),
        buffer: secs('seekEnd'),
        width: ((m['width'] as num?) ?? 0).round(),
        height: ((m['height'] as num?) ?? 0).round(),
        tracks: Tracks(
          audio: [AudioTrack.auto(), AudioTrack.no(), ...audioTracks],
          subtitle: [SubtitleTrack.auto(), SubtitleTrack.no(), ...subTracks],
        ),
        track: Track(
          audio: audioIndex >= 0 && audioIndex < audioTracks.length
              ? audioTracks[audioIndex]
              : AudioTrack.auto(),
          subtitle: subIndex >= 0 && subIndex < subTracks.length
              ? subTracks[subIndex]
              : SubtitleTrack.no(),
        ),
      ),
    );
    if (m['error'] case final String e) errorController.add(e);
  }

  /// Sets [next] as the state and tells every stream that changed.
  void _update(PlayerState next) {
    final prev = state;
    state = next;
    void tell<T>(StreamController<T> c, T a, T b) {
      if (a != b && !c.isClosed) c.add(b);
    }

    tell(playingController, prev.playing, next.playing);
    tell(completedController, prev.completed, next.completed);
    tell(positionController, prev.position, next.position);
    tell(durationController, prev.duration, next.duration);
    tell(volumeController, prev.volume, next.volume);
    tell(rateController, prev.rate, next.rate);
    tell(bufferingController, prev.buffering, next.buffering);
    tell(bufferController, prev.buffer, next.buffer);
    tell(widthController, prev.width, next.width);
    tell(heightController, prev.height, next.height);
    tell(tracksController, prev.tracks, next.tracks);
    tell(trackController, prev.track, next.track);
  }
}

/// media_kit's video output for [AvPlatformPlayer]: its texture, sized like the video.
Future<PlatformVideoController> avVideoController(Player player) async =>
    _AvVideoController(player);

class _AvVideoController extends PlatformVideoController {
  _AvVideoController(Player player)
    : super(player, const VideoControllerConfiguration()) {
    final av = player.platform as AvPlatformPlayer;
    void sync() {
      id.value = av.textureId.value;
      final (w, h) = (av.state.width ?? 0, av.state.height ?? 0);
      rect.value = w > 0 && h > 0
          ? Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble())
          : null;
      if (w > 0 && !waitUntilFirstFrameRenderedCompleter.isCompleted) {
        waitUntilFirstFrameRenderedCompleter.complete();
      }
    }

    av.textureId.addListener(sync);
    _sizes = av.stream.width.listen((_) => sync());
    sync();
  }

  StreamSubscription<int?>? _sizes;

  @override
  Future<void> setSize({int? width, int? height}) async {}

  @override
  void dispose() {
    _sizes?.cancel();
    super.dispose();
  }
}
