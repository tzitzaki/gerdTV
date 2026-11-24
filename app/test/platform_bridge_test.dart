// Owns: the platform channel: picture mode follows the system's Picture-in-Picture, every start and stop of
// playback reaches the native side (Android's foreground service and auto-PiP depend on it), setLogo hands it the
// logo's name plus, on desktop, its PNG, openUrl reaches the phone side, the macOS menu bar
// gets its setting and calls back, and voice search exists only on Android and returns what was heard.
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gerdtv/platform/menu_bar.dart';
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

  test(
    'openUrl hands the address to the phone side, false without one',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final urls = <Object?>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(PlatformBridge.channel, (call) async {
        if (call.method == 'openUrl') urls.add(call.arguments);
        return true;
      });
      expect(await PlatformBridge.openUrl('https://example.invalid/r'), isTrue);
      expect(urls, [
        {'url': 'https://example.invalid/r'},
      ]);
      messenger.setMockMethodCallHandler(PlatformBridge.channel, null);
      expect(
        await PlatformBridge.openUrl('https://example.invalid/r'),
        isFalse,
        reason: 'no native side: the caller shows the address',
      );
    },
  );

  test(
    'macOS menu bar: the setting goes native with labels, its menu calls back',
    () async {
      expect(
        [menuBarOn(null), menuBarOn('on'), menuBarOn('off')],
        [true, true, false],
      );
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final sent = <Object?>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(PlatformBridge.channel, (call) async {
        if (call.method == 'setMenuBar') sent.add(call.arguments);
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(PlatformBridge.channel, null),
      );
      await applyMenuBar(true);
      final args = sent.single as Map;
      expect(args['enabled'], isTrue);
      expect(
        (args['labels'] as Map).keys,
        containsAll(['open', 'toggle', 'stop', 'quit']),
      );
      final actions = <String>[];
      PlatformBridge(pictureMode: ValueNotifier(false))
        ..onMenuBar = actions.add
        ..attach();
      await messenger.handlePlatformMessage(
        PlatformBridge.channel.name,
        PlatformBridge.channel.codec.encodeMethodCall(
          const MethodCall('menuBar', 'stop'),
        ),
        (_) {},
      );
      expect(actions, ['stop']);
    },
  );

  test(
    'iOS pipEnded reaches the resume callback with the failure reason',
    () async {
      final bridge = PlatformBridge(pictureMode: ValueNotifier(false))
        ..attach();
      String? failure;
      bridge.onApplePipEnded = (f) => failure = f;
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            PlatformBridge.channel.name,
            PlatformBridge.channel.codec.encodeMethodCall(
              const MethodCall('pipEnded', {'failure': 'AVPlayer: x'}),
            ),
            (_) {},
          );
      expect(failure, 'AVPlayer: x');
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
