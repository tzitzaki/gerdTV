// New, because nothing owned "two engines behind one player": on Apple platforms live channels play in AVPlayer
// and the rest in mpv, while every screen listens to one Player (lib/player/switch_player.dart). Owns: the switching
// player follows only the active engine and sends commands to it; AVPlayer's native state becomes media_kit's state
// (position, the live edge as the buffer end, tracks, errors) and its commands reach the channel in AVPlayer's units.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gerdtv/player/av_player.dart';
import 'package:gerdtv/player/switch_player.dart';
import 'package:gerdtv_avplayer/gerdtv_avplayer.dart';
import 'package:media_kit/media_kit.dart';

/// An engine that records commands and emits positions on demand.
class _Engine extends PlatformPlayer {
  _Engine() : super(configuration: const PlayerConfiguration());
  final calls = <String>[];

  void at(int secs) {
    state = state.copyWith(position: Duration(seconds: secs));
    positionController.add(state.position);
  }

  @override
  Future<void> seek(Duration d) async => calls.add('seek ${d.inSeconds}');
  @override
  Future<void> pause() async => calls.add('pause');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the switching player follows only the active engine', () async {
    final mpv = _Engine(), av = _Engine();
    final front = SwitchPlatformPlayer(mpv);
    final seen = <int>[];
    front.stream.position.listen((p) => seen.add(p.inSeconds));
    mpv.at(5);
    await pumpEventQueue();
    front.switchTo(av);
    mpv.at(6); // the old engine is no longer heard
    av.at(100);
    await pumpEventQueue();
    expect(seen, [5, 100]);
    expect(front.state.position, const Duration(seconds: 100));
    await front.seek(const Duration(seconds: 90));
    await front.pause();
    expect(av.calls, ['seek 90', 'pause']);
    expect(mpv.calls, isEmpty);
  });

  test('AVPlayer state and commands map onto media_kit', () async {
    final calls = <MethodCall>[];
    const channel = MethodChannel(avPlayerChannel);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return call.method == 'open' ? 7 : null;
        });
    final av = AvPlatformPlayer();
    final errors = <String>[];
    av.stream.error.listen(errors.add);
    await av.openUrl('http://127.0.0.1:1/t/index.m3u8', bufferSecs: 8);
    expect(av.textureId.value, 7);
    expect(calls.single.arguments, {
      'url': 'http://127.0.0.1:1/t/index.m3u8',
      'bufferSecs': 8.0,
    });

    Future<void> native(Map<String, Object?> state) =>
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .handlePlatformMessage(
              avPlayerChannel,
              const StandardMethodCodec().encodeMethodCall(
                MethodCall('state', state),
              ),
              (_) {},
            );
    await native({
      'position': 1200.5,
      'duration': 0.0,
      'seekStart': 0.0,
      'seekEnd': 1210.0,
      'playing': true,
      'buffering': false,
      'width': 1920.0,
      'height': 1080.0,
      'pip': true,
      'audio': ['Deutsch', 'English'],
      'audioIndex': 1,
      'subtitles': ['Deutsch'],
      'subtitleIndex': -1,
    });
    final s = av.state;
    expect(s.position, const Duration(milliseconds: 1200500));
    expect(s.buffer, const Duration(seconds: 1210), reason: 'the live edge');
    expect((s.playing, s.width, s.height), (true, 1920, 1080));
    expect(av.pip.value, isTrue);
    expect(s.tracks.audio.map((t) => t.id), ['auto', 'no', 'av:0', 'av:1']);
    expect(s.track.audio.title, 'English');
    expect(s.track.subtitle.id, 'no');

    calls.clear();
    await av.seek(const Duration(milliseconds: 1195500));
    await av.setVolume(50);
    await av.setSubtitleTrack(const SubtitleTrack('av:0', 'Deutsch', null));
    await av.setAudioTrack(AudioTrack.auto()); // AVPlayer's own choice stays
    expect(calls.map((c) => [c.method, c.arguments]), [
      [
        'seek',
        {'secs': 1195.5},
      ],
      [
        'setVolume',
        {'volume': 0.5},
      ],
      [
        'selectTrack',
        {'kind': 'subtitle', 'index': 0},
      ],
    ]);

    await native({'position': 0.0, 'error': 'Cannot decode'});
    await pumpEventQueue();
    expect(errors, ['Cannot decode']);
  });
}
