// A refused stream (HTTP 403: account expired, blocked, too many connections) stops with a message instead of
// retrying forever. In its own file (own process): a second media_kit Player created in the same process after
// the first was disposed delivered no events (watch item in docs/HANDOVER.md).
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

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await RustLib.init();
    MediaKit.ensureInitialized();
  });

  testWidgets(
    'a refused stream (403) stops with a message instead of retrying',
    (tester) async {
      expect(
        faultServer,
        isNotEmpty,
        reason: 'run through `just test-integration`',
      );
      await tester.runAsync(() async {
        final player = Player(
          configuration: WatchdogAdapter.playerConfiguration,
        );
        // Headless: no audio device and no video controller; a null audio output keeps mpv from ending the file.
        await (player.platform as NativePlayer).setProperty('ao', 'null');
        final adapter = WatchdogAdapter(player);
        await control('/_fault/set?kind=status&n=403');
        await adapter.play(
          ({required hls}) => '$faultServer/live/blocked.ts',
          live: true,
        );
        final end = DateTime.now().add(const Duration(seconds: 30));
        while (adapter.failure.value == null) {
          if (DateTime.now().isAfter(end)) fail('no failure message');
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(adapter.failure.value, contains('refused'));
        // No retry loop: nothing more happens over the next seconds.
        await Future<void>.delayed(const Duration(seconds: 4));
        expect(adapter.reconnecting.value, 0);
        await control('/_fault/set?kind=none');
        await adapter.stop();
        await player.dispose();
      });
    },
  );
}
