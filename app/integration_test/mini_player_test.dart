// Spike B journey: switching the desktop window into mini-player mode and back keeps the stream running: the
// position keeps advancing and the fault server never sees a second request for the stream. Also the player window's
// sizes (VideoWindow): it takes the picture's ratio and returns to the browsing size.
// Needs the fault server: `just test-integration` starts it and passes its URL as GERDTV_FAULT_SERVER.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gerdtv/main.dart';
import 'package:gerdtv/services/session.dart';
import 'package:gerdtv/platform/mini_window.dart';
import 'package:gerdtv/platform/video_window.dart';
import 'package:gerdtv/player/watchdog_adapter.dart';
import 'package:gerdtv/src/rust/frb_generated.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart' as wm;

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

/// The window's content size once it stopped changing (macOS animates the player window's resize).
Future<({double width, double height})> settledContent() async {
  final w = wm.WindowManager.instance.getCurrent()!;
  var last = w.contentSize.toSize();
  for (var i = 0; i < 30; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final now = w.contentSize.toSize();
    if (now == last) break;
    last = now;
  }
  return (width: last.width, height: last.height);
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

  testWidgets('mini mode and back keep the stream running', (tester) async {
    expect(
      faultServer,
      isNotEmpty,
      reason: 'run through `just test-integration`',
    );
    await tester.pumpWidget(
      GerdTvApp(session: Session()..state = SessionState.needsSetup),
    );
    await tester.pumpAndSettle();
    final player = Player(configuration: WatchdogAdapter.playerConfiguration);
    addTearDown(player.dispose);
    final adapter = WatchdogAdapter(player);
    final mini = MiniWindow();

    await tester.runAsync(() async {
      // Headless: no audio device and no video controller; a null audio output keeps the stream playing.
      await (player.platform as NativePlayer).setProperty('ao', 'null');
      await adapter.play(
        ({required hls}) => '$faultServer/live/mini.ts',
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
      final normalContent = await settledContent();

      // The player window: the picture's ratio at the remembered player width, then back to the browsing size.
      final settings = <String, String>{
        VideoWindow.playerKey: '640x480', // the remembered player size
      };
      final window = VideoWindow(
        read: (k) async => settings[k],
        write: (k, v) async => settings[k] = v,
      );
      // Content sizes: macOS's frame adds the title bar.
      await window.follow(4 / 3);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final inPlayer = await settledContent();
      expect(inPlayer.width, closeTo(640, 1));
      expect(inPlayer.height, closeTo(480, 1));
      await window.leave();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final back = await settledContent();
      expect(back.width, closeTo(normalContent.width, 1));
      expect(back.height, closeTo(normalContent.height, 1));

      // The mini window takes the picture's ratio too (4:3 here, so no black bars).
      mini.enter(4 / 3);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(mini.size.width, closeTo(MiniWindow.miniWidth, 1));
      expect(mini.size.height, closeTo(MiniWindow.miniWidth * 3 / 4, 1));
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
