// Playback journeys against the testkit's fault server, through real libmpv (media_kit) and the Rust watchdog:
// the Balanced preset is applied and a cut live stream comes back by itself (and the recovery is logged).
// The refused-stream case is hard_error_test.dart (own process).
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

/// A player as the app makes it, plus the headless-runner setting: no audio device and no video controller here,
/// and with neither output mpv ends the file at once, so a null audio output keeps a decodable stream "playing".
Future<Player> headlessPlayer() async {
  final player = Player(configuration: WatchdogAdapter.playerConfiguration);
  await (player.platform as NativePlayer).setProperty('ao', 'null');
  return player;
}

void main() {
  // A hang fails the test after 5 minutes, with its name and output, instead of running into CI's job limit
  // (the integration binding's default is no timeout at all; the CLI's --timeout doesn't reach it).
  IntegrationTestWidgetsFlutterBinding.ensureInitialized().defaultTestTimeout =
      const Timeout(Duration(minutes: 5));
  setUpAll(() async {
    await RustLib.init();
    MediaKit.ensureInitialized();
  });

  // Each test creates and disposes its player inside runAsync: real time, real platform callbacks.
  testWidgets(
    'live TS plays with the Balanced preset and recovers after a drop',
    (tester) async {
      expect(
        faultServer,
        isNotEmpty,
        reason: 'run through `just test-integration`',
      );
      await tester.runAsync(() async {
        final player = await headlessPlayer();
        final health = <(String, bool)>[];
        final adapter = WatchdogAdapter(
          player,
          onHealth: (trigger, attempts, recovered, secs) {
            health.add((trigger, recovered));
          },
        );
        var maxAttempt = 0;
        adapter.reconnecting.addListener(() {
          if (adapter.reconnecting.value > maxAttempt) {
            maxAttempt = adapter.reconnecting.value;
          }
        });

        // A profile's own User-Agent lasts until the next start, which puts mpv's default back.
        final native = player.platform as NativePlayer;
        final mpvDefault = await native.getProperty('user-agent');
        await adapter.play(
          ({required hls}) => '$faultServer/live/ch1.${hls ? 'm3u8' : 'ts'}',
          live: true,
          userAgent: 'Player/1.0',
        );
        expect(await native.getProperty('user-agent'), 'Player/1.0');
        await adapter.play(
          ({required hls}) => '$faultServer/live/ch1.${hls ? 'm3u8' : 'ts'}',
          live: true,
        );
        expect(await native.getProperty('user-agent'), mpvDefault);
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
        expect(
          health,
          isNotEmpty,
          reason: 'the recovery is logged for stream_health',
        );
        expect(health.last.$2, isTrue);
        await adapter.stop();
        await player.dispose();
      });
    },
  );
}
