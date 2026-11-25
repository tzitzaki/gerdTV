// The MVP journey on the Linux desktop build, against the testkit's mock Xtream Codes panel: first-run setup →
// sync → browse a group → play a channel → search in the sections (typing starts it, across groups, Enter plays the
// top result, programmes, Also in, typos, recent searches, a group with All groups, the guide) → remove the account. Needs the mock panel: `just test-integration` starts it (GERDTV_MOCK_XC).
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gerdtv/main.dart';
import 'package:gerdtv/platform/mac_keychain.dart';
import 'package:gerdtv/platform/mini_window.dart';
import 'package:gerdtv/screens/app_logo.dart';
import 'package:gerdtv/screens/guide_settings.dart';
import 'package:gerdtv/screens/programme_sheet.dart';
import 'package:gerdtv/screens/section_search.dart';
import 'package:gerdtv/screens/list_modes.dart';
import 'package:gerdtv/services/session.dart';
import 'package:gerdtv/src/rust/api/library.dart';
import 'package:gerdtv/src/rust/frb_generated.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';

import 'support.dart';

void main() {
  // A hang fails the test after 5 minutes, with its name and output, instead of running into CI's job limit
  // (the integration binding's default is no timeout at all; the CLI's --timeout doesn't reach it).
  IntegrationTestWidgetsFlutterBinding.ensureInitialized().defaultTestTimeout =
      const Timeout(Duration(minutes: 5));
  setUpAll(() async {
    await RustLib.init();
    MediaKit.ensureInitialized();
  });

  // The real security tool against a keychain of its own, never the user's (test/secrets_test.dart has the rules,
  // against a fake one): the command line, the exit code for "not found" and the base64 round trip.
  test('macOS: a secret round-trips through the security tool', () async {
    final dir = await Directory.systemTemp.createTemp('gerdtv-keychain');
    final file = '${dir.path}/test.keychain-db';
    Future<void> security(List<String> args) async {
      final r = await Process.run('/usr/bin/security', args);
      expect(r.exitCode, 0, reason: '${args.first}: ${r.stderr}');
    }

    await security(['create-keychain', '-p', 'test', file]);
    addTearDown(() async {
      await security(['delete-keychain', file]);
      await dir.delete(recursive: true);
    });
    final keychain = MacKeychain(keychain: file);
    expect(await keychain.read('k'), isNull);
    await keychain.delete('k'); // a missing item is fine
    await keychain.write('k', 'p"ä\\ss');
    expect(await keychain.read('k'), 'p"ä\\ss');
    // Replaces, close to the tool's line limit.
    await keychain.write('k', 'x' * 2900);
    expect(await keychain.read('k'), 'x' * 2900);
    await keychain.delete('k');
    expect(await keychain.read('k'), isNull);
  }, skip: !Platform.isMacOS);

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
      await (session.mpvPlayer.platform as NativePlayer).setProperty(
        'ao',
        'null',
      );
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
    await waitFor(tester, find.byKey(const Key('settings.cat.playback')));
    await tester.tap(find.byKey(const Key('settings.cat.playback')));
    await waitFor(tester, find.byKey(const Key('buffer.fastZap')));
    await tester.tap(find.byKey(const Key('buffer.fastZap')));
    await tester.pump();
    // Settings → Appearance: another logo, stored app-wide and sent to the Linux window as its icon.
    await tapReady(tester, find.byKey(const Key('settings.cat.appearance')));
    // The theme comes first in Appearance: the logos may be below the window (built only when scrolled to).
    await waitFor(tester, find.byKey(const Key('settings.themeMode')));
    await tester.scrollUntilVisible(
      find.byKey(const Key('settings.logo.signal')),
      200,
      scrollable: find
          .descendant(
            of: find.byKey(const Key('settings.content')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tapReady(tester, find.byKey(const Key('settings.logo.signal')));
    await tester.pump();
    expect(session.logo, AppLogo.signal);
    expect(appSetting(dir: dir.path, key: Session.settingAppLogo), 'signal');
    // The rail's TV (Appearance lists the sections by name too).
    await tester.tap(
      find.descendant(
        of: find.byType(NavigationRail),
        matching: find.text('TV'),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    // Browse: the first live group, then its first channel plays.
    await waitFor(tester, find.byType(ListTile));
    await tester.tap(find.byType(ListTile).first);
    // Live TV opens as a list with what's on now (the mock guide covers most channels) and its progress.
    await waitFor(
      tester,
      find.descendant(
        of: find.byType(ItemRow),
        matching: find.byType(LinearProgressIndicator),
      ),
    );
    // The list bar's toggle cycles list → tiles → large tiles → compact → list, remembered per section.
    for (final want in [ItemCard, ItemCard, ItemRow, ItemRow]) {
      await tapReady(tester, find.byKey(const Key('list.mode')));
      await tester.pump();
      expect(find.byType(want), findsWidgets);
    }
    expect(session.library!.setting(key: 'list_mode_live'), 'list');
    await tapReady(tester, find.byType(ItemRow));
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
    // The profile's Fast zap reached the engine (mpv's cache-pause-wait; for a live channel in AVPlayer on the Mac,
    // its forward buffer, which the readout's target follows); the channel's own buffer applies at once.
    Future<double> pauseWait() async => session.onAvPlayer.value
        ? session.adapter.target.value.toDouble()
        : double.parse(
            await tester.runAsync(
                  () => (session.mpvPlayer.platform as NativePlayer)
                      .getProperty('cache-pause-wait'),
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
    expect(session.adapter.target.value, 2);

    // Desktop mini player: the window shrinks to the floating player, playback continues, Restore brings it back.
    final mini = MiniWindow();
    final fullWidth = mini.size.width;
    await tester.tap(find.byKey(const Key('player.mini')));
    await waitFor(tester, find.byKey(const Key('player.picture')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 800)),
    );
    expect(mini.size.width, closeTo(MiniWindow.miniWidth, 1));
    // Its buttons are hidden until a tap; Mute, and M, switch the sound.
    expect(find.byKey(const Key('player.mute')).hitTestable(), findsNothing);
    await tester.tap(find.byKey(const Key('player.picture')));
    await tapReady(tester, find.byKey(const Key('player.mute')));
    for (var i = 0; i < 50 && session.player.state.volume != 0; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
    }
    expect(session.player.state.volume, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
    for (var i = 0; i < 50 && session.player.state.volume != 100; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
    }
    expect(session.player.state.volume, 100);
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
    // (The 3 s may be over: shown again if so.)
    if (find
        .byKey(const Key('player.restore'))
        .hitTestable()
        .evaluate()
        .isEmpty) {
      await tester.tap(find.byKey(const Key('player.picture')));
      await tester.pump();
    }
    await tester.tap(find.byKey(const Key('player.restore')));
    await waitFor(tester, find.byKey(const Key('player.back')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 800)),
    );
    expect(mini.size.width, closeTo(fullWidth, 1));

    // Zapping: Down plays the next channel of the group and shows what's on; OK opens the channel list, Esc closes
    // it and stays in the player.
    final before = session.nowPlaying.value!.key;
    final i = session.zapList.indexWhere((c) => c.key == before);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await waitFor(tester, find.byKey(const Key('player.banner')));
    // The buffer readout is off unless switched on (on: the guide's Watch below).
    expect(find.byKey(const Key('player.bufferReadout')), findsNothing);
    expect(session.nowPlaying.value!.key, session.zapList[i + 1].key);
    // A remote's keys: last channel goes back and forth, CH- and CH+ step through the list.
    for (final (key, at) in [
      (LogicalKeyboardKey.backspace, i),
      (LogicalKeyboardKey.backspace, i + 1),
      (LogicalKeyboardKey.channelDown, i),
      (LogicalKeyboardKey.channelUp, i + 1),
    ]) {
      // As an Android remote sends them (Linux has no channel keys to simulate).
      await tester.sendKeyEvent(key, platform: 'android');
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 500)),
      );
      await tester.pump();
      expect(session.nowPlaying.value!.key, session.zapList[at].key);
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await waitFor(tester, find.byKey(const Key('player.panel')));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byKey(const Key('player.panel')), findsNothing);
    expect(find.byKey(const Key('player.back')), findsOneWidget);

    // Pause live TV (timeshift: 60 min on desktop by default): after a few seconds the player says how far behind live
    // it is and offers Live, which plays from the live edge again.
    expect(session.timeshiftWindow.value, greaterThan(0));
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await waitFor(tester, find.byKey(const Key('player.behind')));
    await tapReady(tester, find.byKey(const Key('player.live')));
    final liveBy = DateTime.now().add(const Duration(seconds: 10));
    while (find.byKey(const Key('player.behind')).evaluate().isNotEmpty) {
      if (DateTime.now().isAfter(liveBy)) fail('still behind live after Live');
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pump();
    }
    expect(session.player.state.playing, isTrue);

    // Leaving the player keeps the stream playing in the now-playing bar; tapping the bar reopens it, no restart.
    await tester.tap(find.byKey(const Key('player.back')));
    await waitFor(tester, find.byKey(const Key('nowPlaying.bar')));
    // While Apple's window floats the stream, the bar shows the logo, not a second picture.
    session.floating.value = true;
    await waitFor(tester, find.byKey(const Key('nowPlaying.floating')));
    session.floating.value = false;
    await tester.pump();
    expect(find.byKey(const Key('nowPlaying.floating')), findsNothing);
    final atLeave = session.player.state.position;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 2)),
    );
    await tester.pump();
    final st = session.player.state;
    final mpv = session.mpvPlayer.platform as NativePlayer;
    final props = <String>[];
    for (final p in [
      'time-pos',
      'demuxer-cache-time',
      'paused-for-cache',
      'cache-buffering-state',
      'demuxer-cache-idle',
    ]) {
      props.add('$p ${await tester.runAsync(() => mpv.getProperty(p))}');
    }
    debugPrint('JOURNEY: after leaving: ${props.join(', ')}');
    expect(
      st.position,
      greaterThan(atLeave),
      // The state names the kind of stall when this fails (it was flaky: open work in docs/HANDOVER.md).
      reason:
          'keeps playing after leaving the player (playing ${st.playing}, '
          'buffering ${st.buffering}, cache to ${st.buffer}, completed ${st.completed})',
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
    // Search in Live TV: typing a letter anywhere starts it (no tap on the field), and the field takes the focus;
    // each further keystroke narrows (a test's key events don't reach a text field's input, so enterText types on).
    // The hits come from every group (not just one); Enter plays the top result.
    await tester.pumpAndSettle();
    final liveField = find.byKey(const Key('search.live'));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyS, character: 's');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyS);
    await tester.pump();
    expect(tester.widget<TextField>(liveField).controller!.text, 's');
    expect(tester.widget<TextField>(liveField).focusNode!.hasFocus, isTrue);
    var previous = 1 << 30;
    for (final q in ['s', 'sp', 'spo', 'sport']) {
      if (q != 's') await tester.enterText(liveField, q);
      await waitFor(tester, find.byType(ItemRow));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pump();
      final n = find.byType(ItemRow).evaluate().length;
      expect(n, lessThanOrEqualTo(previous), reason: '"$q" must not widen');
      previous = n;
    }
    final liveGroups = {
      for (final r in tester.widgetList<ItemRow>(find.byType(ItemRow)))
        r.item.category,
    };
    expect(liveGroups.length, greaterThan(1), reason: 'hits from every group');
    expect(
      find.byWidgetPredicate(
        (w) =>
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith('search.group.'),
      ),
      findsWidgets,
      reason: 'groups named "… Sport …" are results too',
    );
    await tester.sendKeyEvent(
      LogicalKeyboardKey.enter,
    ); // the field has the focus since typing started
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
    // Programmes under the channels (the guide loaded in the background after setup); a hit plays its channel.
    final programmeHit = find.byWidgetPredicate(
      (w) =>
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith('search.programme.'),
    );
    // (Scrolled to the programmes' header, the one unique widget there: a programme row isn't built until it is
    // near the screen, and a finder for "the first of none" throws.)
    await waitFor(tester, find.byType(ItemRow));
    final results = find
        .ancestor(
          of: find.byType(ItemRow).first,
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.byKey(const Key('search.programmes.all')),
      400,
      scrollable: results,
      maxScrolls: 60,
    );
    await tester.drag(results, const Offset(0, -200));
    await tester.pump();
    await tapReady(tester, programmeHit);
    // The programme's sheet: the top hit is running, Watch plays its channel live.
    await tapReady(tester, find.byKey(const Key('guide.sheet.watch')));
    // macOS slides the player in from the right: Stop (right edge) is outside the window until it settles.
    await tapStop(tester);
    // Back in search for real (the field also exists underneath an open player).
    await waitFor(tester, liveField.hitTestable());
    expect(session.nowPlaying.value, isNull);

    debugPrint('JOURNEY: programme search played its channel');
    // Catch-up: a programme that ended on a channel with an archive (every 13th mock channel) plays from the archive.
    final lib = session.library!;
    // An episode that plays to its end is marked as watched and counts down to the next one; Cancel keeps it away.
    final episodes = await tester.runAsync(() async {
      for (final g in await lib.categories(
        kind: ItemKind.series,
        sort: 'provider',
      )) {
        for (final s in await lib.items(
          kind: ItemKind.series,
          category: g.id,
          sort: 'provider',
          limit: 20,
          offset: 0,
        )) {
          final eps = await lib.episodes(seriesKey: s.key);
          if (eps.length > 1) return eps;
        }
      }
      return null;
    });
    await tester.runAsync(() => session.play(episodes!.first));
    await waitFor(tester, find.byKey(const Key('nowPlaying.bar')));
    await tester.tap(find.byKey(const Key('nowPlaying.bar')));
    await waitFor(tester, find.byKey(const Key('player.nextUp')));
    expect(session.nextUp.value!.item.key, episodes![1].key);
    expect(session.watched, contains(episodes.first.key));
    await tapReady(tester, find.byKey(const Key('player.nextUp.cancel')));
    await tester.pump();
    expect(find.byKey(const Key('player.nextUp')), findsNothing);
    expect(session.nowPlaying.value!.key, episodes.first.key);
    await tapStop(tester);
    await waitFor(tester, liveField.hitTestable());
    debugPrint('JOURNEY: an episode ended, the next one was cancelled');

    final groups = await tester.runAsync(
      () => lib.categories(kind: ItemKind.live, sort: 'provider'),
    );
    // (The first such channel may have no guide: the mock panel, like real ones, leaves some epg ids empty.)
    final nowSecs = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    ProgrammeInfo? found;
    ItemInfo? onChannel;
    for (final g in groups!) {
      final items = await tester.runAsync(
        () => lib.items(
          kind: ItemKind.live,
          category: g.id,
          sort: 'provider',
          limit: 500,
          offset: 0,
        ),
      );
      final keys = [
        for (final i in items!)
          if (i.archiveDays > 0) i.key,
      ];
      if (keys.isEmpty) continue;
      final rows = await tester.runAsync(
        () => lib.guideWindow(
          keys: keys,
          from: nowSecs - 6 * 3600,
          to: nowSecs - 3600,
        ),
      );
      for (var r = 0; r < rows!.length && found == null; r++) {
        found = rows[r].programmes
            .where((p) => p.stop < nowSecs - 600)
            .firstOrNull;
        if (found != null) {
          onChannel = items.firstWhere((i) => i.key == keys[r]);
        }
      }
      if (found != null) break;
    }
    if (found == null) fail('no past programme on a channel with an archive');
    final past = found;
    // Its sheet (the guide grid and search open the same one; each is covered above): Watch plays the archive.
    unawaited(
      showProgrammeSheet(
        session.navigatorKey.currentContext!,
        session,
        past,
        onChannel!,
      ),
    );
    await tapReady(tester, find.byKey(const Key('programme.catchup')));
    await waitFor(tester, find.byKey(const Key('player.back')));
    expect(session.nowPlaying.value!.key, startsWith('catchup:'));
    final archiveEnd = DateTime.now().add(const Duration(seconds: 30));
    while (session.player.state.position < const Duration(seconds: 1)) {
      if (DateTime.now().isAfter(archiveEnd)) fail('no catch-up playback');
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pump();
    }
    await tapStop(tester);
    // Back in search for real (the field also exists underneath the closing player).
    await waitFor(tester, liveField.hitTestable());

    debugPrint('JOURNEY: catch-up played a past programme');
    // "Show all" lists every programme hit: ended ones under "Earlier", after the running and upcoming ones (missed
    // shows aren't pushed out by what's still to come). The field still holds "sport", whose ended programmes exist
    // in the mock guide; the group is built only once scrolled to.
    await waitFor(
      tester,
      find.byType(ItemRow),
    ); // the results load after the player closed
    final showAll = find.byKey(const Key('search.programmes.all'));
    await tester.scrollUntilVisible(
      showAll,
      400,
      scrollable: find
          .ancestor(
            of: find.byType(ItemRow).first,
            matching: find.byType(Scrollable),
          )
          .first,
      maxScrolls: 60,
    );
    await tapReady(tester, showAll);
    await waitFor(tester, find.byType(ProgrammeResultsScreen));
    final programmeList = find
        .descendant(
          of: find.byType(ProgrammeResultsScreen),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.byKey(const Key('search.earlier')),
      400,
      scrollable: programmeList,
      maxScrolls: 60,
    );
    expect(
      find.descendant(
        of: programmeList,
        matching: find.textContaining(
          RegExp(r'^(Mon|Tue|Wed|Thu|Fri|Sat|Sun) |\d\d:\d\d–'),
        ),
      ),
      findsWidgets,
    );
    await tester.pageBack();
    await tester.pumpAndSettle();

    debugPrint('JOURNEY: search lists ended programmes under Earlier');
    // "Also in": Movies with the same query; a typo still finds movies; each section keeps its own query.
    await waitFor(
      tester,
      find.byType(ItemRow),
    ); // the results load after the player closed
    final also = find.byKey(const Key('search.also.movies'));
    await tester.scrollUntilVisible(
      also,
      400,
      scrollable: find
          .ancestor(
            of: find.byType(ItemRow).first,
            matching: find.byType(Scrollable),
          )
          .first,
      maxScrolls: 60,
    );
    await tapReady(tester, also);
    final moviesField = find.byKey(const Key('search.movies'));
    await waitFor(tester, moviesField);
    expect(tester.widget<TextField>(moviesField).controller!.text, 'sport');
    await waitFor(tester, find.byType(ItemCard)); // movies show as tiles
    await tester.enterText(moviesField, 'sprot'); // two letters swapped
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 500)),
    );
    await tester.pump();
    expect(find.byType(ItemCard), findsWidgets, reason: 'typo matches');
    await tester.tap(
      find.descendant(
        of: find.byType(NavigationRail),
        matching: find.text('TV'),
      ),
    );
    await waitFor(tester, liveField);
    expect(tester.widget<TextField>(liveField).controller!.text, 'sport');
    // Cleared and focused, the field lists the recent searches (opened results above recorded "sport").
    await tester.tap(find.byKey(const Key('search.clear')));
    await tester.pump();
    await tester.tap(liveField);
    await waitFor(tester, find.byKey(const Key('search.recent.0')));
    expect(
      find.descendant(
        of: find.byKey(const Key('search.recent.0')),
        matching: find.text('sport'),
      ),
      findsOneWidget,
    );
    // Inside a group: the search covers that group only, "All groups" widens it to the whole section.
    await tester.tap(find.byKey(const Key('search.recent.0')));
    await waitFor(tester, find.byType(ItemRow));
    await tester.tap(find.byKey(const Key('search.clear')));
    await tester.pump();
    final groupTile = find.byWidgetPredicate(
      (w) => w is ListTile && w.trailing is Text && w.onTap != null,
    );
    await tapReady(tester, groupTile);
    await waitFor(tester, find.byType(ItemRow));
    final groupId = tester
        .widget<ItemRow>(find.byType(ItemRow).first)
        .item
        .category;
    final inGroup = liveField.hitTestable();
    await tester.enterText(inGroup, 'sport');
    await waitFor(tester, find.byKey(const Key('search.allGroups')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump();
    final groupHits = tester.widgetList<ItemRow>(find.byType(ItemRow));
    expect(groupHits.map((r) => r.item.category).toSet(), {groupId});
    await tester.tap(find.byKey(const Key('search.allGroups')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump();
    expect(
      tester
          .widgetList<ItemRow>(find.byType(ItemRow))
          .map((r) => r.item.category)
          .toSet()
          .length,
      greaterThan(1),
      reason: 'All groups widens to the section',
    );
    await tester.pageBack();
    await tester.pumpAndSettle();
    // The guide's field lists programmes instead of the grid.
    await tapReady(tester, find.byKey(const Key('tv.guide')));
    final guideField = find.byKey(const Key('search.guide'));
    await waitFor(tester, guideField.hitTestable());
    await tester.enterText(guideField, 'sport');
    await waitFor(tester, programmeHit);
    await tester.tap(find.byKey(const Key('search.clear')));
    await tester.pump();
    expect(lib.setting(key: 'tv_view'), 'guide', reason: 'remembered');
    await tapReady(tester, find.byKey(const Key('tv.list')));
    await tester.pumpAndSettle();

    debugPrint('JOURNEY: search in sections, groups and the guide');
    // Favourites: the star on a channel puts it into a Favourites group on top of Live TV.
    await tapReady(
      tester,
      find.byWidgetPredicate(
        (w) => w is ListTile && w.trailing is Text && w.onTap != null,
      ),
    );
    final star = find.byWidgetPredicate(
      (w) =>
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith('item.star.'),
    );
    await tapReady(tester, star);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await waitFor(tester, find.byKey(const Key('browse.favourites')));
    debugPrint('JOURNEY: a favourite shows in its group');

    // Reminders: a programme that hasn't started gets Remind me; the reminder is stored, and a second tap clears it.
    final soon = await tester.runAsync(
      () => lib.guideWindow(
        keys: [onChannel!.key],
        from: nowSecs + 3600,
        to: nowSecs + 6 * 3600,
      ),
    );
    final upcoming = soon!.first.programmes.firstWhere(
      (p) => p.start > nowSecs + 3600,
    );
    unawaited(
      showProgrammeSheet(
        session.navigatorKey.currentContext!,
        session,
        upcoming,
        onChannel,
      ),
    );
    await tapReady(tester, find.byKey(const Key('programme.remind')));
    await waitFor(tester, find.text('Reminder set'));
    final set = await tester.runAsync(lib.reminders);
    expect(
      set!.map((r) => (r.itemKey, r.start)),
      contains((onChannel.key, upcoming.start)),
    );
    await tapReady(tester, find.byKey(const Key('programme.remind')));
    await waitFor(tester, find.text('Remind me'));
    expect(await tester.runAsync(lib.reminders), isEmpty);
    await tester.tapAt(const Offset(10, 10)); // close the sheet
    await tester.pumpAndSettle();

    debugPrint('JOURNEY: a reminder was set and cleared');
    // The guide grid: Now, a running programme's sheet, Watch plays its channel.
    await tapReady(tester, find.byKey(const Key('tv.guide')));
    await tapReady(tester, find.byKey(const Key('guide.now')));
    // The sort button: the order is Live TV's too; back to the provider's.
    for (final order in ['name_desc', 'provider']) {
      await tapReady(tester, find.byKey(const Key('list.sort')));
      await tapReady(tester, find.byKey(Key('sort.$order')));
      await tester.pumpAndSettle();
      expect(lib.setting(key: 'sort_live_items'), order);
    }
    final running = find.byWidgetPredicate(
      (w) =>
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith('guide.cell.'),
    );
    await waitFor(tester, running.hitTestable());
    await tapReady(tester, running);
    lib.setSetting(key: 'player_buffer_readout', value: 'on');
    await tapReady(tester, find.byKey(const Key('guide.sheet.watch')));
    await waitFor(tester, find.byKey(const Key('player.back')));
    await waitFor(tester, find.byKey(const Key('player.bufferReadout')));
    lib.setSetting(key: 'player_buffer_readout', value: 'off');
    expect(session.nowPlaying.value, isNotNull);
    await tapStop(tester);
    await waitFor(tester, find.byKey(const Key('guide.now')).hitTestable());
    expect(session.nowPlaying.value, isNull);

    debugPrint('JOURNEY: guide played a channel');
    // Settings → Guide: the provider's guide imported; an extra XMLTV URL imports too and can be removed again.
    // (The stopped player is still closing: wait until the rail can take the tap.)
    await tapReady(tester, find.text('Settings'));
    await tester.pumpAndSettle();
    await tapReady(tester, find.byKey(const Key('settings.cat.guide')));
    await tester.pumpAndSettle();
    // The category's entries (the categories beside them scroll separately).
    final settingsList = find
        .descendant(
          of: find.byKey(const Key('settings.content')),
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
    await tester.pumpAndSettle(); // the picker is still sliding out (two Back buttons until then)
    await tester.pageBack();
    await tester.pumpAndSettle();

    debugPrint('JOURNEY: guide settings');
    // Settings: found by search, remove the account → back to setup.
    await tester.enterText(find.byKey(const Key('settings.search')), 'remove');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('guide.unmatched')), findsNothing);
    await tapReady(tester, find.byKey(const Key('settings.remove')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove'));
    await waitFor(tester, find.text('Add your provider'));
    debugPrint('JOURNEY: account removed');
    await tester.runAsync(() => dir.delete(recursive: true));
    debugPrint('JOURNEY: done');
  });
}
