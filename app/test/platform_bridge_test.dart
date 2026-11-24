// Owns: the platform channel: picture mode follows the system's Picture-in-Picture, every start and stop of
// playback reaches the native side (Android's foreground service and auto-PiP depend on it), setLogo hands it the
// logo's name plus, on desktop, its PNG, and voice search exists only on Android and returns what was heard.
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gerdtv/platform/platform_bridge.dart';
import 'package:gerdtv/screens/app_logo.dart';
import 'package:gerdtv/services/session.dart';
import 'package:gerdtv/src/rust/api/library.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('native pictureMode calls drive Session.pictureMode', () async {
    final mode = ValueNotifier(false);
    PlatformBridge(pictureMode: mode).attach();
    Future<void> send(bool on) => TestDefaultBinaryMessengerBinding
        .instance
        .defaultBinaryMessenger
        .handlePlatformMessage(
          PlatformBridge.channel.name,
          PlatformBridge.channel.codec.encodeMethodCall(
            MethodCall('pictureMode', on),
          ),
          (_) {},
        );
    await send(true);
    expect(mode.value, isTrue);
    await send(false);
    expect(mode.value, isFalse);
  });

  test(
    'every start and stop of playback is announced to the platform',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final calls = <Object?>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(PlatformBridge.channel, (call) async {
            if (call.method == 'setPlaying') calls.add(call.arguments);
            return null;
          });
      final session = Session(appDir: '/nonexistent');
      session.nowPlaying.value = ItemInfo(
        key: 'live:1',
        kind: ItemKind.live,
        name: 'Channel One',
        category: 'g',
        logo: '',
        archiveDays: 0,
        group: '',
      );
      session.nowPlaying.value = null;
      await Future<void>.delayed(Duration.zero);
      expect(calls, [
        {'playing': true, 'title': 'Channel One'},
        {'playing': false, 'title': ''},
      ]);
    },
  );

  test('iOS PiP: the floating window\'s buttons arrive as commands, and mpv\'s PiP calls carry no stream URL', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(PlatformBridge.channel, (call) async {
          calls.add(call);
          return call.method == 'startPip' ? true : null;
        });
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final bridge = PlatformBridge(pictureMode: ValueNotifier(false))..attach();
    final got = <(String, double)>[];
    bridge.onPipCommand = (a, s) => got.add((a, s));
    for (final c in [
      {'action': 'pause'},
      {'action': 'skip', 'secs': -15.0},
    ]) {
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            PlatformBridge.channel.name,
            PlatformBridge.channel.codec.encodeMethodCall(
              MethodCall('pipCommand', c),
            ),
            (_) {},
          );
    }
    expect(got, [('pause', 0.0), ('skip', -15.0)]);
    await bridge.preparePip(true);
    await bridge.pipState(
      playing: true,
      position: 12,
      duration: 3600,
      live: false,
    );
    expect(await bridge.startApplePip(), isTrue);
    expect(calls.map((c) => c.method), ['preparePip', 'pipState', 'startPip']);
    expect(calls.last.arguments, isNull, reason: 'no hand-over URL');
    // Other platforms send nothing.
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await bridge.preparePip(false);
    expect(calls, hasLength(3));
  });

  test('setLogo sends the name and, on Linux, a PNG of the logo', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(PlatformBridge.channel, (call) async {
          calls.add(call);
          return null;
        });
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await PlatformBridge(pictureMode: ValueNotifier(false))
        .setLogo(AppLogo.signal);
    expect(calls.single.method, 'setLogo');
    final args = calls.single.arguments as Map;
    expect(args['name'], 'signal');
    // Linux: the window icon arrives as PNG bytes (the PNG signature starts with 0x89 'P' 'N' 'G').
    expect((args['png'] as Uint8List).sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
  });

  test('voice search: Android only, the words heard or null', () async {
    final asked = <String>[];
    String? answer = '  ARD Sport ';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(PlatformBridge.channel, (call) async {
          asked.add(call.method);
          return call.method == 'voiceAvailable' ? true : answer;
        });
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    expect(
      await PlatformBridge(pictureMode: ValueNotifier(false)).voiceAvailable,
      isFalse,
      reason: 'no mic on desktop (dictation elsewhere)',
    );
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final bridge = PlatformBridge(pictureMode: ValueNotifier(false));
    expect(await bridge.voiceAvailable, isTrue);
    expect(await bridge.listen('Search'), 'ARD Sport');
    answer = null; // cancelled
    expect(await bridge.listen('Search'), isNull);
    expect(asked, ['voiceAvailable', 'listen', 'listen']);
  });
}
