// Owns: the platform channel switches picture mode when the system's Picture-in-Picture starts and ends, and setLogo
// hands the native side the logo's name plus, on desktop, its PNG.
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gerdtv/platform/platform_bridge.dart';
import 'package:gerdtv/screens/app_logo.dart';

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
    await PlatformBridge(pictureMode: ValueNotifier(false))
        .setLogo(AppLogo.signal);
    expect(calls.single.method, 'setLogo');
    final args = calls.single.arguments as Map;
    expect(args['name'], 'signal');
    // Tests run on Linux: the window icon arrives as PNG bytes (the PNG signature starts with 0x89 'P' 'N' 'G').
    expect((args['png'] as Uint8List).sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
  });
}
