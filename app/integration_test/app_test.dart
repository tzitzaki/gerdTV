// The MVP journey on the Linux desktop build, against the testkit's mock Xtream Codes panel: first-run setup →
// sync → browse a group → play a channel → global search (narrows per keystroke, Enter plays the top result) →
// remove the account. Needs the mock panel: `just test-integration` starts it (GERDTV_MOCK_XC).
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gerdtv/main.dart';
import 'package:gerdtv/platform/mini_window.dart';
import 'package:gerdtv/screens/guide_settings.dart';
import 'package:gerdtv/screens/item_tile.dart';
import 'package:gerdtv/screens/settings_screen.dart';
import 'package:gerdtv/services/secrets.dart';
import 'package:gerdtv/services/session.dart';
import 'package:gerdtv/src/rust/frb_generated.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';

const mockXc = String.fromEnvironment('GERDTV_MOCK_XC');

/// Headless runners have no keyring for libsecret; the journey keeps secrets in memory instead.
class MemorySecrets extends Secrets {
  final _m = <String, List<String>>{};
  @override
  Future<void> write(String profileId, List<String> secrets) async =>
      _m[profileId] = secrets;
  @override
  Future<List<String>?> read(String profileId) async => _m[profileId];
  @override
  Future<void> delete(String profileId) async => _m.remove(profileId);
}

/// Pumps frames in real time until [found] appears.
Future<void> waitFor(
  WidgetTester tester,
  Finder found, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final end = DateTime.now().add(timeout);
  while (found.evaluate().isEmpty) {
    if (DateTime.now().isAfter(end)) fail('timed out waiting for $found');
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
  }
}

/// Waits until [found] can take a tap at its centre, then taps the first such match. Routes and sheets slide in (macOS from the right,
/// sheets from below): a widget that merely exists may still be outside the window, and the tap would miss.
Future<void> tapReady(WidgetTester tester, Finder found) async {
  await waitFor(tester, found.hitTestable());
  await tester.tap(found.hitTestable().first);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await RustLib.init();
    MediaKit.ensureInitialized();
  });

  testWidgets('set up an account, browse, play, search, remove', (
    tester,
  ) async {
    expect(mockXc, isNotEmpty, reason: 'run through `just test-integration`');
    tester.platformDispatcher.localesTestValue = [const Locale('en')];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    final dir = await Directory.systemTemp.createTemp('gerdtv-journey');
    final session = Session(secrets: MemorySecrets(), appDir: dir.path);
    await tester.runAsync(() async {
      await session.start();
      // Headless: no audio device; a null audio output keeps mpv from ending the file.
      await (session.player.platform as NativePlayer).setProperty('ao', 'null');
    });
    await tester.pumpWidget(GerdTvApp(session: session));
    await tester.pumpAndSettle();

    debugPrint('JOURNEY: setup screen');
    // First run: the Xtream Codes login.
    expect(find.text('Add your provider'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('setup.server')), mockXc);
    await tester.enterText(find.byKey(const Key('setup.username')), 'testuser');
    await tester.enterText(find.byKey(const Key('setup.password')), 'testpass');
    await tester.tap(find.byKey(const Key('setup.connect')));
    await waitFor(tester, find.byType(NavigationRail));
    expect(session.lastSync!.entries, greaterThan(1000));

    debugPrint('JOURNEY: synced, shell shown');
    // Settings → Playback: Fast zap for the whole profile.
    await tester.tap(find.text('Settings'));
    await waitFor(tester, find.byKey(const Key('buffer.fastZap')));
    await tester.tap(find.byKey(const Key('buffer.fastZap')));
    await tester.pump();
    await tester.tap(find.text('Live TV'));
    await tester.pump(const Duration(milliseconds: 300));
    // Browse: the first live group, then its first channel plays.
    await waitFor(tester, find.byType(ListTile));
    await tester.tap(find.byType(ListTile).first);
    await tapReady(tester, find.byType(ItemTile));
    await waitFor(tester, find.byKey(const Key('player.back')));
    debugPrint('JOURNEY: player opened');
    final end = DateTime.now().add(const Duration(seconds: 30));
    while (session.player.state.position < const Duration(seconds: 1)) {
      if (DateTime.now().isAfter(end)) fail('no playback');
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pump();
    }
    // The profile's Fast zap reached mpv; the channel's own buffer applies at once and shows in the readout.
    Future<double> pauseWait() async => double.parse(
      await tester.runAsync(
            () => (session.player.platform as NativePlayer).getProperty(
              'cache-pause-wait',
            ),
          ) ??
          '0',
    );
    expect(await pauseWait(), 2);
    await tester.tap(find.byKey(const Key('player.buffer')));
    await tapReady(tester, find.byKey(const Key('buffer.smooth')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 500)),
    );
    await tester.pump();
    expect(await pauseWait(), 30);
    await waitFor(
      tester,
      find.byKey(const Key('buffer.default'), skipOffstage: false),
    );
    await tester.ensureVisible(find.byKey(const Key('buffer.default')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('buffer.default')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 500)),
    );
    await tester.pump();
    expect(await pauseWait(), 2);
    await tester.tapAt(const Offset(10, 10)); // close the sheet
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.textContaining('/ 2 s'), findsOneWidget);

    // Desktop mini player: the window shrinks to the floating player, playback continues, Restore brings it back.
    final mini = MiniWindow();
    final fullWidth = mini.size.width;
    await tester.tap(find.byKey(const Key('player.mini')));
    await waitFor(tester, find.byKey(const Key('player.restore')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 800)),
    );
    expect(mini.size.width, closeTo(MiniWindow.miniWidth, 1));
    final inMini = session.player.state.position;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 2)),
    );
    await tester.pump();
    expect(
      session.player.state.position,
      greaterThan(inMini),
      reason: 'plays on in the mini player',
    );
    await tester.tap(find.byKey(const Key('player.restore')));
    await waitFor(tester, find.byKey(const Key('player.back')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 800)),
    );
    expect(mini.size.width, closeTo(fullWidth, 1));

    // Leaving the player keeps the stream playing in the now-playing bar; tapping the bar reopens it, no restart.
    await tester.tap(find.byKey(const Key('player.back')));
    await waitFor(tester, find.byKey(const Key('nowPlaying.bar')));
    final atLeave = session.player.state.position;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 2)),
    );
    await tester.pump();
    expect(
      session.player.state.position,
      greaterThan(atLeave),
      reason: 'keeps playing after leaving the player',
    );
    await tester.tap(find.byKey(const Key('nowPlaying.bar')));
    await waitFor(tester, find.byKey(const Key('player.back')));
    expect(
      session.player.state.position,
      greaterThanOrEqualTo(atLeave),
      reason: 'reopening does not restart',
    );
    await tester.tap(find.byKey(const Key('player.back')));
    await waitFor(tester, find.byKey(const Key('nowPlaying.bar')));
    await tester.pageBack();
    await tester.pump(const Duration(milliseconds: 500));

    debugPrint('JOURNEY: played, back in browse');
    // Search: each keystroke narrows, Enter plays the top result.
    await tester.tap(find.text('Search'));
    await tester.pumpAndSettle();
    final field = find.byKey(const Key('search.field'));
    var previous = 1 << 30;
    for (final q in ['s', 'sp', 'spo', 'sport']) {
      await tester.enterText(field, q);
      await waitFor(tester, find.byType(ListTile));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pump();
      final n = find.byType(ListTile).evaluate().length;
      expect(
        n,
        lessThanOrEqualTo(previous),
        reason: '"$q" must not widen the list',
      );
      previous = n;
    }
    // The Live TV chip narrows to channels; Enter then plays the top one (for a series it would open its episodes).
    await tester.tap(find.byKey(const Key('search.chip.live')));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump();
    await tester.tap(
      field,
    ); // keyboard focus in the field (enterText only feeds the text input)
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await waitFor(tester, find.byKey(const Key('player.back')));
    await tester.tap(find.byKey(const Key('player.back')));
    await waitFor(tester, find.byKey(const Key('nowPlaying.bar')));
    // Stop is the way playback ends: the bar goes away.
    await tester.tap(find.byKey(const Key('nowPlaying.stop')));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byKey(const Key('nowPlaying.bar')), findsNothing);
    expect(session.nowPlaying.value, isNull);

    debugPrint('JOURNEY: search played top result');
    // Programmes: the guide loaded in the background after setup; its hits play their channel.
    await tapReady(tester, find.byKey(const Key('search.chip.programmes')));
    await tester.pump();
    await tapReady(
      tester,
      find.byWidgetPredicate(
        (w) =>
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith('search.programme.'),
      ),
    );
    await waitFor(tester, find.byKey(const Key('player.back')));
    await tester.tap(find.byKey(const Key('player.stop')));
    await waitFor(tester, find.byKey(const Key('search.field')));
    expect(session.nowPlaying.value, isNull);

    debugPrint('JOURNEY: programme search played its channel');
    // Settings → Guide: the provider's guide imported; an extra XMLTV URL imports too and can be removed again.
    // (The stopped player is still closing: wait until the rail can take the tap.)
    await tapReady(tester, find.text('Settings'));
    await tester.pumpAndSettle();
    final settingsList = find
        .descendant(
          of: find.byType(SettingsScreen),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.byKey(const Key('guide.unmatched')),
      200,
      scrollable: settingsList,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('guide.source.builtin')),
        matching: find.textContaining('programmes'),
      ),
      findsOneWidget,
    );
    await tester.ensureVisible(find.byKey(const Key('guide.add')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const Key('guide.url')),
      '$mockXc/xmltv.php?username=testuser&password=testpass',
    );
    await tester.pumpAndSettle(); // the focused field scrolls itself into view
    await tapReady(tester, find.byKey(const Key('guide.add')));
    await waitFor(
      tester,
      find.byWidgetPredicate(
        (w) =>
            w is ListTile &&
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith('guide.source.') &&
            w.key != const ValueKey('guide.source.builtin') &&
            w.subtitle is Text &&
            ((w.subtitle! as Text).data ?? '').contains('programmes'),
      ),
    );
    final sources = await tester.runAsync(session.library!.guideSources);
    expect(sources!.length, 2);
    await tester.ensureVisible(find.byTooltip('Remove'));
    await tester.pump();
    await tester.tap(find.byTooltip('Remove'));
    await tester.pump(const Duration(milliseconds: 300));
    // Mapping by hand: a channel without a guide id gets a guide channel and leaves the list.
    await tester.scrollUntilVisible(
      find.byKey(const Key('guide.unmatched')),
      200,
      scrollable: settingsList,
    );
    await tester.tap(find.byKey(const Key('guide.unmatched')));
    final unmatched = find.byWidgetPredicate(
      (w) =>
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith('guide.unmatched.'),
    );
    await waitFor(tester, unmatched.hitTestable());
    final first = tester.widget(unmatched.first).key!;
    await tester.tap(find.byKey(first));
    final guideChannel = find.descendant(
      of: find.byType(PickGuideChannelScreen),
      matching: find.byType(ListTile),
    );
    await tapReady(tester, guideChannel);
    await waitFor(tester, unmatched.hitTestable());
    expect(find.byKey(first), findsNothing);
    await tester.pageBack();
    await tester.pumpAndSettle();

    debugPrint('JOURNEY: guide settings');
    // Settings: remove the account → back to setup.
    await tester.scrollUntilVisible(
      find.byKey(const Key('settings.remove')),
      -200,
      scrollable: settingsList,
    );
    await tester.tap(find.byKey(const Key('settings.remove')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove'));
    await waitFor(tester, find.text('Add your provider'));
    debugPrint('JOURNEY: account removed');
    await tester.runAsync(() => dir.delete(recursive: true));
    debugPrint('JOURNEY: done');
  });
}
