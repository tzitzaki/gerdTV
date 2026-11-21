// Spike B journey: switching the desktop window into mini-player mode and back keeps the stream running: the
// position keeps advancing and the fault server never sees a second request for the stream.
// Needs the fault server: `just test-integration` starts it and passes its URL as GERDTV_FAULT_SERVER.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gerdtv/main.dart';
import 'package:gerdtv/platform/mini_window.dart';
import 'package:gerdtv/player/watchdog_adapter.dart';
import 'package:gerdtv/src/rust/frb_generated.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';

import 'package:gerdtv/src/rust/api/playback.dart';

const faultServer = String.fromEnvironment('GERDTV_FAULT_SERVER');

/// How many times the live TS stream was requested (from the fault server's /_stats).
Future<int> liveRequests() async {
  final client = HttpClient();
  final res = await (await client.getUrl(Uri.parse('$faultServer/_stats')))
      .close();
  final body = await res.transform(const SystemEncoding().decoder).join();
  client.close();
  return int.parse(RegExp(r'live_ts=(\d+)').firstMatch(body)!.group(1)!);
}

/// Playback advances for 3 s. Adds up only forward steps: the test clip loops every 10 s and restarts its
/// timestamps, which older mpv builds (macOS/iOS) report as the position jumping back.
Future<void> playsOn(Player player, String phase) async {
  var advanced = Duration.zero;
  var last = player.state.position;
  for (var i = 0; i < 30; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final now = player.state.position;
    if (now > last) advanced += now - last;
    last = now;
  }
  expect(
    advanced,
    greaterThan(const Duration(seconds: 2)),
    reason: 'still playing $phase',
  );
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await RustLib.init();
    MediaKit.ensureInitialized();
  });

  testWidgets('mini mode and back keep the stream running', (tester) async {
    expect(
      faultServer,
      isNotEmpty,
      reason: 'run through `just test-integration`',
    );
    await tester.pumpWidget(const GerdTvApp());
    await tester.pumpAndSettle();
    final player = Player();
    addTearDown(player.dispose);
    final adapter = WatchdogAdapter(player);
    final mini = MiniWindow();

    await tester.runAsync(() async {
      // Headless: no audio device and no video controller; a null audio output keeps the stream playing.
      await (player.platform as NativePlayer).setProperty('ao', 'null');
      await adapter.play(
        '$faultServer/live/mini.ts',
        live: true,
        preset: BufferPreset.fastZap,
      );
      final end = DateTime.now().add(const Duration(seconds: 30));
      while (player.state.position < const Duration(seconds: 1)) {
        if (DateTime.now().isAfter(end)) fail('no playback');
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      final requests = await liveRequests();
      final normal = mini.size;

      mini.enter();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(mini.size.width, closeTo(MiniWindow.miniWidth, 1));
      expect(mini.size.height, closeTo(MiniWindow.miniHeight, 1));
      await playsOn(player, 'in mini mode');

      mini.exit();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(mini.size.width, closeTo(normal.width, 1));
      await playsOn(player, 'after leaving mini mode');

      expect(
        await liveRequests(),
        requests,
        reason: 'the stream must not be reopened',
      );
      expect(adapter.reconnecting.value, 0);
    });
    await adapter.stop();
  });
}
