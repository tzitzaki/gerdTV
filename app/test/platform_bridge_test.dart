// Owns: the platform channel: picture mode follows the system's Picture-in-Picture, every start and stop of
// playback reaches the native side (Android's foreground service and auto-PiP depend on it), and setLogo hands it the
// logo's name plus, on desktop, its PNG.
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
      );
      session.nowPlaying.value = null;
      await Future<void>.delayed(Duration.zero);
      expect(calls, [
        {'playing': true, 'title': 'Channel One'},
        {'playing': false, 'title': ''},
      ]);
    },
  );

  test(
    'iOS pipEnded reaches the resume callback with the failure flag',
    () async {
      final bridge = PlatformBridge(pictureMode: ValueNotifier(false))
        ..attach();
      bool? failed;
      bridge.onApplePipEnded = (f) => failed = f;
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            PlatformBridge.channel.name,
            PlatformBridge.channel.codec.encodeMethodCall(
              const MethodCall('pipEnded', {'failed': true}),
            ),
            (_) {},
          );
      expect(failed, isTrue);
    },
  );

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
}
