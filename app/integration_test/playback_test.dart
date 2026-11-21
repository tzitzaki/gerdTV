// Spike A journey: media_kit (libmpv) plays the testkit's live stream with the Balanced preset applied, and the
// Rust watchdog brings it back after the stream is cut and the server refuses reconnects for a while.
// Needs the fault server: `just test-integration` starts it and passes its URL as GERDTV_FAULT_SERVER.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gerdtv/player/watchdog_adapter.dart';
import 'package:gerdtv/src/rust/frb_generated.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';

const faultServer = String.fromEnvironment('GERDTV_FAULT_SERVER');

Future<void> control(String path) async {
  final client = HttpClient();
  final res = await (await client.getUrl(Uri.parse('$faultServer$path')))
      .close();
  expect(res.statusCode, 200, reason: path);
  client.close();
}

/// Polls [check] every 100 ms until it holds or [timeout] passes.
Future<void> waitFor(
  bool Function() check,
  Duration timeout,
  String what,
) async {
  final end = DateTime.now().add(timeout);
  while (!check()) {
    if (DateTime.now().isAfter(end)) fail('timed out waiting for $what');
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await RustLib.init();
    MediaKit.ensureInitialized();
  });

  testWidgets(
    'live TS plays with the Balanced preset and recovers after a drop',
    (tester) async {
      expect(
        faultServer,
        isNotEmpty,
        reason: 'run through `just test-integration`',
      );
      final player = Player();
      addTearDown(player.dispose);
      final adapter = WatchdogAdapter(player);
      var maxAttempt = 0;
      adapter.reconnecting.addListener(() {
        if (adapter.reconnecting.value > maxAttempt) {
          maxAttempt = adapter.reconnecting.value;
        }
      });

      await tester.runAsync(() async {
        // Headless runners have no audio device, and no video controller is attached here: with neither output,
        // mpv ends the file at once. A null audio output keeps a decodable stream "playing".
        await (player.platform as NativePlayer).setProperty('ao', 'null');
        await adapter.play('$faultServer/live/ch1.ts', live: true);
        // Balanced: mpv waits for 8 s of cache before starting.
        final wait = await (player.platform as NativePlayer).getProperty(
          'cache-pause-wait',
        );
        expect(double.parse(wait), 8.0);
        await waitFor(
          () => player.state.position > const Duration(seconds: 1),
          const Duration(seconds: 30),
          'first playback',
        );

        // The stream is cut and the server answers 503 for a while: FFmpeg's own reconnect fails, the watchdog
        // takes over (Reconnecting 1, 2 …) and plays again once the server is healthy.
        await control('/_fault/set?kind=status&n=503');
        await control('/_fault/cut');
        await waitFor(
          () => adapter.reconnecting.value > 0,
          const Duration(seconds: 40),
          'the watchdog to step in',
        );
        await Future<void>.delayed(const Duration(seconds: 3));
        await control('/_fault/set?kind=none');
        final before = player.state.position;
        await waitFor(
          () =>
              adapter.reconnecting.value == 0 &&
              player.state.position != before,
          const Duration(seconds: 60),
          'recovery',
        );
        expect(maxAttempt, greaterThanOrEqualTo(1));
      });
      await adapter.stop();
    },
  );
}
