// The shared screen check (CLAUDE.md "Tests"): every screen, once per form factor (phone, desktop, TV), against
// the mock panel. Per screen: no exception (overflows are exceptions), no text below the readable size, no two
// texts drawn over each other (only what clipping leaves visible counts), and Tab moves focus only to controls
// inside the window. A screenshot of each screen goes to GERDTV_SCREENS_DIR (`just test-integration` sets
// ~/gerdTV-screens/<branch>/) for a look by eye.
// Debugging: a failure names the form factor and the screen; the screenshot shows the state it saw.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gerdtv/main.dart';
import 'package:gerdtv/screens/guide_settings.dart';
import 'package:gerdtv/screens/list_modes.dart';
import 'package:gerdtv/theme.dart';
import 'package:gerdtv/services/session.dart';
import 'package:gerdtv/src/rust/frb_generated.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';

import 'support.dart';

const screensDir = String.fromEnvironment('GERDTV_SCREENS_DIR');

/// Logical sizes: a phone, a desktop window, and a 1080p TV at density 2 (the Shield).
const formFactors = {
  'phone': Size(390, 844),
  'desktop': Size(1280, 800),
  'tv': Size(960, 540),
};

/// Smallest readable text in logical pixels (Material's smallest style is 11; captions below that are a bug).
const minFontSize = 11.0;

final _boundary = GlobalKey();

/// Lets animations and async loads settle for a moment in real time (pumpAndSettle can't: progress indicators spin).
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// The visible texts: their window rects and smallest font size.
/// A render box's rect in window coordinates, cut to what its scrolling and clipping ancestors actually show (a
/// guide title that starts under the channel column is clipped there, not drawn over it).
Rect drawnRect(RenderBox box) {
  Rect global(RenderBox b) =>
      MatrixUtils.transformRect(b.getTransformTo(null), Offset.zero & b.size);
  var rect = global(box);
  for (RenderObject? p = box.parent; p != null; p = p.parent) {
    if (p is RenderBox &&
        p.hasSize &&
        (p is RenderAbstractViewport ||
            p is RenderClipRect ||
            p is RenderClipRRect)) {
      rect = rect.intersect(global(p));
    }
  }
  return rect;
}

List<(Rect, double, String)> visibleTexts(WidgetTester tester, Size window) {
  final out = <(Rect, double, String)>[];
  for (final e in find.byType(RichText).hitTestable().evaluate()) {
    final rp = e.renderObject! as RenderParagraph;
    if (!rp.attached || !rp.hasSize || rp.size.isEmpty) continue;
    final text = rp.text.toPlainText().trim();
    if (text.isEmpty) continue; // icons are glyphs in RichText too, but carry no plain text worth checking
    final rect = drawnRect(rp);
    if (rect.isEmpty || !(Offset.zero & window).overlaps(rect)) continue;
    var size = double.infinity;
    rp.text.visitChildren((span) {
      final f = span.style?.fontSize;
      if (f != null && f < size) size = f;
      return true;
    });
    // Icons (MaterialIcons font) are single private-use glyphs: not text.
    if (text.runes.length == 1 && text.runes.first >= 0xE000) continue;
    out.add((rect, rp.textScaler.scale(size), text));
  }
  return out;
}

Future<void> checkScreen(
  WidgetTester tester,
  String form,
  String screen,
  Size window,
) async {
  await settle(tester);
  final where = '$form / $screen';
  // First, so a failing check leaves the picture it failed on.
  await screenshot(tester, '$form-$screen');
  expect(
    tester.takeException(),
    isNull,
    reason: '$where: an exception (overflow?)',
  );
  final texts = visibleTexts(tester, window);
  expect(texts, isNotEmpty, reason: '$where: nothing readable on screen');
  for (final (_, size, text) in texts) {
    expect(
      size,
      greaterThanOrEqualTo(minFontSize),
      reason: '$where: "$text" is ${size}px',
    );
  }
  // Two texts drawn over each other: a layout that doesn't fit (rects shrunk by 1 px against touching neighbours).
  for (var i = 0; i < texts.length; i++) {
    for (var j = i + 1; j < texts.length; j++) {
      final a = texts[i].$1.deflate(1), b = texts[j].$1.deflate(1);
      expect(
        a.overlaps(b),
        isFalse,
        reason: '$where: "${texts[i].$3}" overlaps "${texts[j].$3}"',
      );
    }
  }
  // Keyboard / D-pad: every Tab lands on a control inside the window (scrolled into view if needed).
  final seen = <FocusNode>{};
  // From a clean start: focus left by the previous screen may sit in a text field the test scrolled away, and on
  // macOS a Tab inside a text field goes to the system's text input instead of moving focus.
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pump();
  for (var i = 0; i < 25; i++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump(const Duration(milliseconds: 50));
    final node = FocusManager.instance.primaryFocus;
    if (node == null || node.context == null || !seen.add(node)) continue;
    final box = node.context!.findRenderObject();
    if (box is! RenderBox || !box.hasSize) continue;
    final rect = MatrixUtils.transformRect(
      box.getTransformTo(null),
      Offset.zero & box.size,
    );
    if (!(Offset.zero & window).inflate(1).contains(rect.center)) {
      await screenshot(tester, '$form-$screen-focus');
      final owner =
          node.context!.findAncestorWidgetOfExactType<ListTile>() ??
          node.context!.findAncestorWidgetOfExactType<Card>() ??
          node.context!.widget;
      fail('$where: Tab ${i + 1} focused $owner at $rect, outside $window');
    }
  }
  expect(seen, isNotEmpty, reason: '$where: Tab reaches no control');
}

Future<void> screenshot(WidgetTester tester, String name) async {
  if (screensDir.isEmpty) return;
  final boundary =
      _boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    final f = File('$screensDir/$name.png');
    await f.parent.create(recursive: true);
    await f.writeAsBytes(png!.buffer.asUint8List());
  });
}

void main() {
  // A hang fails the test after 5 minutes instead of running into CI's job limit (the binding has no timeout).
  IntegrationTestWidgetsFlutterBinding.ensureInitialized().defaultTestTimeout =
      const Timeout(Duration(minutes: 5));
  // One session (and so one media_kit Player) for all three sizes, like the app: a second Player in one process
  // misbehaves (docs/HANDOVER.md), and with one per size the desktop run hung in CI. The account is removed
  // between sizes, so each starts at the setup screen.
  late Directory dir;
  late Session session;
  setUpAll(() async {
    await RustLib.init();
    MediaKit.ensureInitialized();
    dir = await Directory.systemTemp.createTemp('gerdtv-screens');
    session = Session(secrets: MemorySecrets(), appDir: dir.path);
  });
  tearDownAll(() => dir.delete(recursive: true));

  for (final MapEntry(key: form, value: size) in formFactors.entries) {
    testWidgets('every screen on $form', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      // English texts, whatever the machine's language (the finders below use them).
      tester.platformDispatcher.localesTestValue = [const Locale('en')];
      addTearDown(tester.platformDispatcher.clearLocalesTestValue);
      await tester.runAsync(() async {
        if (session.state == SessionState.ready) await session.removeProfile();
        await session.start();
      });
      final guideBefore =
          session.guideGeneration; // this size's account imports its own guide
      await tester.pumpWidget(
        RepaintBoundary(
          key: _boundary,
          child: GerdTvApp(session: session),
        ),
      );
      await waitFor(tester, find.text('Add your provider'));
      await checkScreen(tester, form, 'setup', size);

      // Sign in to the mock panel; the guide loads in the background.
      await tester.enterText(find.byKey(const Key('setup.server')), mockXc);
      await tester.enterText(
        find.byKey(const Key('setup.username')),
        'testuser',
      );
      await tester.enterText(
        find.byKey(const Key('setup.password')),
        'testpass',
      );
      await tester.ensureVisible(find.byKey(const Key('setup.connect')));
      await tapReady(tester, find.byKey(const Key('setup.connect')));
      final rail = size.width >= 720;
      await waitFor(tester, find.byType(rail ? NavigationRail : NavigationBar));
      await waitFor(tester, find.byType(ListTile));
      await checkScreen(tester, form, 'live', size);

      // A group in each list mode (the guide's now/next shows in the list mode once imported).
      await tapReady(tester, find.byType(ListTile));
      await waitFor(tester, find.byType(ItemRow).hitTestable());
      for (final mode in ['list', 'tiles', 'largeTiles', 'compact']) {
        await checkScreen(tester, form, 'group-$mode', size);
        await tapReady(tester, find.byKey(const Key('list.mode')));
      }
      // The player over the picture: the now/next banner, then the channel list (OK).
      await tapReady(tester, find.byType(ItemRow));
      await waitFor(tester, find.byKey(const Key('player.banner')));
      await checkScreen(tester, form, 'player', size);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await waitFor(tester, find.byKey(const Key('player.panel')));
      await checkScreen(tester, form, 'player-channels', size);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tapReady(tester, find.byKey(const Key('player.stop')));
      await waitFor(tester, find.byType(ItemRow).hitTestable());
      await settle(
        tester,
      ); // the player is still closing (two Back buttons until then)
      await tester.pageBack();
      await settle(tester);

      Future<void> section(String label) async {
        await tapReady(tester, find.text(label));
        await settle(tester);
      }

      for (final (label, name) in [
        ('Movies', 'movies'),
        ('Series', 'series'),
      ]) {
        await section(label);
        await checkScreen(tester, form, name, size);
      }

      // Search in Live TV: channels from every group, matching groups, programmes below (searched when the query
      // changes: wait for the background guide import first). Movies: tiles with each one's group.
      final end = DateTime.now().add(const Duration(seconds: 30));
      while (session.guideGeneration == guideBefore) {
        if (DateTime.now().isAfter(end)) {
          fail('$form: the guide never imported');
        }
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 200)),
        );
      }
      await section('Live TV');
      await tester.enterText(find.byKey(const Key('search.live')), 'sport');
      await waitFor(tester, find.byType(ItemRow).hitTestable());
      await checkScreen(tester, form, 'search', size);
      await tester.tap(find.byKey(const Key('search.clear')));
      await section('Movies');
      await tester.enterText(find.byKey(const Key('search.movies')), 'sport');
      await waitFor(tester, find.byType(ItemCard).hitTestable());
      await checkScreen(tester, form, 'search-movies', size);
      // A movie's page: its details from the panel, Play and Trailer (the trailer itself plays in a web view, which
      // the Linux build doesn't have: a device check).
      await tapReady(tester, find.byType(ItemCard));
      await waitFor(tester, find.byKey(const Key('details.trailer')));
      await checkScreen(tester, form, 'movie-page', size);
      await tester.pageBack();
      await settle(tester);
      await tester.tap(find.byKey(const Key('search.clear')));

      // The guide grid (the guide imported above) and a programme's sheet.
      await section('Guide');
      final cell = find.byWidgetPredicate(
        (w) =>
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith('guide.cell.'),
      );
      await waitFor(tester, cell.hitTestable());
      // Before anything is focused the header shows the first row's running programme, never nothing.
      await waitFor(tester, find.textContaining('Now ·'));
      await checkScreen(tester, form, 'guide', size);
      await tapReady(tester, cell);
      await waitFor(tester, find.byKey(const Key('guide.sheet.watch')));
      await checkScreen(tester, form, 'guide-sheet', size);
      await tester.tapAt(const Offset(10, 10)); // the sheet's barrier closes it
      await settle(tester);
      // The guide's search: programmes instead of the grid.
      await tester.enterText(find.byKey(const Key('search.guide')), 'sport');
      await waitFor(
        tester,
        find
            .byWidgetPredicate(
              (w) =>
                  w.key is ValueKey<String> &&
                  (w.key! as ValueKey<String>).value.startsWith(
                    'search.programme.',
                  ),
            )
            .hitTestable(),
      );
      await checkScreen(tester, form, 'search-guide', size);
      await tester.tap(find.byKey(const Key('search.clear')));
      await settle(tester);

      await section('Settings');
      await checkScreen(tester, form, 'settings', size);
      // Each category (wide: beside the list; phone: its own page), then a search across all of them.
      final wide = size.width >= Tokens.wideLayout;
      for (final cat in [
        'account',
        'playback',
        'guide',
        'appearance',
        'about',
      ]) {
        await tapReady(tester, find.byKey(Key('settings.cat.$cat')));
        await settle(tester);
        await checkScreen(tester, form, 'settings-$cat', size);
        if (!wide) {
          await tester.pageBack();
          await settle(tester);
        }
      }
      await tester.enterText(find.byKey(const Key('settings.search')), 'guide');
      await settle(tester);
      await checkScreen(tester, form, 'settings-search', size);
      await tapReady(tester, find.byTooltip('Clear'));
      await settle(tester);
      await tapReady(tester, find.byKey(const Key('settings.cat.guide')));
      await settle(tester);
      final list = find
          .descendant(
            of: find.byKey(const Key('settings.content')),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        find.byKey(const Key('guide.unmatched')),
        300,
        scrollable: list,
      );
      await checkScreen(tester, form, 'settings-guide-end', size);
      await tapReady(tester, find.byKey(const Key('guide.unmatched')));
      await waitFor(tester, find.byType(UnmatchedChannelsScreen));
      await checkScreen(tester, form, 'guide-unmatched', size);
      await tapReady(
        tester,
        find.byWidgetPredicate(
          (w) =>
              w.key is ValueKey<String> &&
              (w.key! as ValueKey<String>).value.startsWith('guide.unmatched.'),
        ),
      );
      await waitFor(tester, find.byType(PickGuideChannelScreen));
      await checkScreen(tester, form, 'guide-pick', size);

      // The light theme (Settings → Appearance → Theme), once at phone size: the same rules on a few screens.
      if (form == 'phone') {
        await tester.runAsync(
          () => session.setTheme(const ThemePrefs(mode: ThemeMode.light)),
        );
        session.navigatorKey.currentState!.popUntil((r) => r.isFirst);
        await settle(tester);
        await section('Live TV');
        await checkScreen(tester, form, 'light-live', size);
        await tapReady(tester, find.byType(ListTile));
        await waitFor(tester, find.byType(ItemRow).hitTestable());
        await checkScreen(tester, form, 'light-group', size);
        await tester.pageBack();
        await settle(tester);
        await section('Settings');
        await tapReady(
          tester,
          find.byKey(const Key('settings.cat.appearance')),
        );
        await settle(tester);
        await checkScreen(tester, form, 'light-settings-appearance', size);
        await tester.runAsync(() => session.setTheme(const ThemePrefs()));
      }
    });
  }
}
