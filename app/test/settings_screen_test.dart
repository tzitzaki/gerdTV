// New, because nothing owns the shape of Settings: the search filter (every word must match an entry's title,
// keywords, subcategory or category, accents folded) and the two layouts (categories beside the content on wide windows, a list
// that opens a page on phones), with the search narrowing the visible entries as you type; picking a logo stores it
// app-wide; the player choices are stored for the next start, and say so only for a real
// change.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gerdtv/platform/engine.dart';
import 'package:gerdtv/theme.dart';
import 'package:gerdtv/l10n/gen/app_localizations.dart';
import 'package:gerdtv/screens/app_logo.dart';
import 'package:gerdtv/screens/player_settings.dart';
import 'package:gerdtv/screens/settings_model.dart';
import 'package:gerdtv/screens/settings_screen.dart';
import 'package:gerdtv/services/session.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:material_ui/material_ui.dart';

import 'support/fake_core.dart';

SettingsEntry entry(
  String id,
  String title, [
  String keywords = '',
  String? section,
]) => SettingsEntry(
  id: id,
  title: title,
  keywords: keywords,
  section: section,
  build: (_) => Text('entry $id'),
);

void main() {
  final categories = [
    SettingsCategory(
      id: 'playback',
      icon: Icons.abc,
      title: 'Wiedergabe',
      entries: [
        entry('buffer', 'Puffer', 'Cache Verzögerung'),
        entry('timeshift', 'Timeshift', 'Pause zurückspulen'),
      ],
    ),
    SettingsCategory(
      id: 'about',
      icon: Icons.abc,
      title: 'Über',
      entries: [entry('licences', 'Lizenzen')],
    ),
    SettingsCategory(
      id: 'account',
      icon: Icons.abc,
      title: 'Konto',
      entries: [
        entry('sync', 'Jetzt aktualisieren', '', 'Mein Anbieter'),
        entry('remove', 'Entfernen', '', 'Mein Anbieter'),
        entry('trakt', 'Verbinden', '', 'Trakt'),
      ],
    ),
  ];

  test(
    'the account line shows what the provider tells, in the app language',
    () async {
      final en = await AppLocalizations.delegate.load(const Locale('en'));
      final de = await AppLocalizations.delegate.load(const Locale('de'));
      await initializeDateFormatting();
      // Noon UTC, so the date is the same in every time zone the tests run in.
      const end = '1804852800'; // 2027-03-12
      for (final (l10n, expires, limit, want) in [
        (en, end, '2', 'Expires Mar 12, 2027 · 2 streams at once'),
        (de, end, '1', 'Läuft ab am 12. März 2027 · 1 Stream gleichzeitig'),
        (en, '', '1', 'No expiry date · 1 stream at once'),
        (en, null, null, ''), // M3U, or never synced
      ]) {
        expect(accountLine(l10n, expires: expires, limit: limit), want);
      }
    },
  );

  test('filterSettings keeps matching entries under their category', () {
    String ids(String q) => [
      for (final c in filterSettings(categories, q))
        '${c.id}:${c.entries.map((e) => e.id).join(',')}',
    ].join(' ');
    for (final (query, want) in [
      (
        '',
        'playback:buffer,timeshift about:licences account:sync,remove,trakt',
      ), // nothing typed: all
      (
        '  ',
        'playback:buffer,timeshift about:licences account:sync,remove,trakt',
      ),
      ('trakt', 'account:trakt'), // the subcategory's heading
      ('puff', 'playback:buffer'), // title, any case
      ('CACHE', 'playback:buffer'), // keyword
      ('verzogerung', 'playback:buffer'), // umlaut folded
      ('uber', 'about:licences'), // category title, folded
      ('wiedergabe pause', 'playback:timeshift'), // every word must match
      ('pause lizenz', ''), // words from two entries match none
      ('xyz', ''),
    ]) {
      expect(ids(query), want, reason: 'query "$query"');
    }
  });

  group('SettingsScreen', () {
    setUpAll(useFakeCore);

    // Without an open library only Account, Stream health and About exist; enough to see layout and search.
    // [beside]: a rail of that width left of Settings, as in the shell.
    Future<Session> pump(
      WidgetTester tester,
      Size size, {
      double beside = 0,
      String appDir = 'unused-by-the-fake',
    }) async {
      final session = Session(appDir: appDir);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Row(
              children: [
                SizedBox(width: beside),
                Expanded(child: SettingsScreen(session: session)),
              ],
            ),
          ),
        ),
      );
      return session;
    }

    testWidgets('wide: categories beside the content, search narrows it', (
      tester,
    ) async {
      await pump(tester, const Size(1280, 800));
      // Five categories (owner decision): Your data sits in Account, Stream health in Playback, Updates in About.
      for (final id in ['account', 'playback', 'about']) {
        expect(find.byKey(Key('settings.cat.$id')), findsOneWidget);
      }
      // The guide needs an open library (none here); the merged categories are gone.
      for (final id in ['guide', 'data', 'updates', 'health']) {
        expect(find.byKey(Key('settings.cat.$id')), findsNothing);
      }
      // The first category shows; another one replaces it. Account's entries sit under their subcategory: the
      // provider's (its name, "Provider" without one) once, however many entries it has.
      expect(find.byKey(const Key('settings.remove')), findsOneWidget);
      expect(
        find.byKey(const Key('settings.section.Provider')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('settings.cat.about')));
      await tester.pump();
      expect(find.byKey(const Key('settings.remove')), findsNothing);
      expect(find.text('Licences'), findsOneWidget);
      expect(find.text('Check for updates'), findsOneWidget);

      // Search across categories: only the matching entry, under its category.
      await tester.enterText(
        find.byKey(const Key('settings.search')),
        'logout',
      );
      await tester.pump();
      expect(find.byKey(const Key('settings.remove')), findsOneWidget);
      expect(find.text('Licences'), findsNothing);
      expect(find.byKey(const Key('settings.sync')), findsNothing);

      await tester.enterText(find.byKey(const Key('settings.search')), 'zzz');
      await tester.pump();
      expect(find.text('No settings match.'), findsOneWidget);

      await tester.tap(find.byTooltip('Clear'));
      await tester.pump();
      expect(find.text('No settings match.'), findsNothing);
      expect(
        find.text('Licences'),
        findsOneWidget,
      ); // back to the chosen category
    });

    // Regression (macOS CI, 800 px window): the shell shows its rail, so Settings must be wide too, though it gets
    // less than 720 px beside the rail; it opened full pages over the rail instead.
    testWidgets('wide window with the rail: categories beside the content', (
      tester,
    ) async {
      await pump(tester, const Size(800, 600), beside: 81);
      expect(find.byKey(const Key('settings.remove')), findsOneWidget);
    });

    testWidgets('phone: a category list that opens a page', (tester) async {
      await pump(tester, const Size(390, 844));
      expect(find.byKey(const Key('settings.remove')), findsNothing);
      await tester.tap(find.byKey(const Key('settings.cat.account')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('settings.remove')), findsOneWidget);
      expect(find.widgetWithText(AppBar, 'Account'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const Key('settings.search')), 'licen');
      await tester.pump();
      expect(find.text('Licences'), findsOneWidget);
      expect(find.byKey(const Key('settings.cat.account')), findsNothing);
    });

    testWidgets('Appearance: picking a logo stores it app-wide', (
      tester,
    ) async {
      final core = useFakeCore();
      final session = await pump(tester, const Size(1280, 800));
      await tester.tap(find.byKey(const Key('settings.cat.appearance')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('settings.logo.signal')));
      await tester.pump();
      expect(session.logo, AppLogo.signal);
      expect(core.appSettings[Session.settingAppLogo], 'signal');
    });

    // [own]: gerdTV's own libmpv is installed (a 320 px phone: nothing may overflow).
    Future<String> pumpPlayers(WidgetTester tester, {bool own = true}) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final dir = Directory.systemTemp.createTempSync('gerdtv-settings');
      addTearDown(() => dir.deleteSync(recursive: true));
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('de'),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: PlayerSettings(
              session: Session(appDir: dir.path),
              hasOwnEngine: own,
            ),
          ),
        ),
      );
      return dir.path;
    }

    Future<void> pick(WidgetTester tester, String key) async {
      await tester.tap(find.byKey(Key(key)));
      await tester.pumpAndSettle();
    }

    final newer = find.byKey(const Key('settings.engine.gerdtv'));
    final notice = find.byKey(const Key('settings.restartNotice'));

    testWidgets(
      'Player: the version shows only with gerdTV\'s player and stays stored',
      (tester) async {
        final dir = await pumpPlayers(tester);
        expect(readLivePlayer(dir), LivePlayer.gerdtv, reason: 'the default');
        await pick(tester, 'settings.engine.gerdtv');
        await pick(tester, 'settings.live.apple');
        expect(newer, findsNothing);
        expect(readLivePlayer(dir), LivePlayer.apple);
        expect(
          readEngine(dir),
          PlayerEngine.gerdtv,
          reason: 'movies still use it',
        );
        await pick(tester, 'settings.live.gerdtv');
        expect(newer, findsOneWidget);
        debugDefaultTargetPlatformOverride = null;
      },
    );

    testWidgets('Player: the restart notice shows only for a real change', (
      tester,
    ) async {
      await pumpPlayers(tester);
      await pick(tester, 'settings.live.gerdtv'); // what it is already
      expect(notice, findsNothing);
      await pick(tester, 'settings.live.apple');
      expect(notice, findsOneWidget);
      await pick(tester, 'settings.live.gerdtv'); // back to what runs
      expect(notice, findsNothing);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets(
      'Appearance: the theme applies at once and is stored app-wide',
      (tester) async {
        final core = useFakeCore();
        final session = await pump(tester, const Size(1280, 800));
        await tester.tap(find.byKey(const Key('settings.cat.appearance')));
        await tester.pump();
        await tester.tap(find.byKey(const Key('settings.accent.4')));
        await tester.pump();
        await tester.tap(find.text('Light'));
        await tester.pump();
        expect(session.theme.value.accent, 4);
        expect(session.theme.value.mode, ThemeMode.light);
        expect(core.appSettings[Session.settingThemeAccent], '4');
        expect(core.appSettings[Session.settingThemeMode], 'light');
        // Pure black is for the dark theme only.
        final black = tester.widget<SwitchListTile>(
          find.byKey(const Key('settings.black')),
        );
        expect(black.onChanged, isNull);
        // The player banner's translucency: stored at once; unknown values keep the default, others stay readable.
        final overlay = tester.widget<Slider>(
          find.byKey(const Key('settings.overlay')),
        );
        overlay.onChanged!(60);
        await tester.pump();
        expect(session.overlayTranslucency.value, 60);
        expect(core.appSettings[Session.settingOverlayTranslucency], '60');
        expect(find.text('60 %'), findsOneWidget);
        expect(Session.parseOverlayTranslucency('?'), 40);
        expect(Session.parseOverlayTranslucency('100'), 80);
        // Stored values come back; unknown ones keep the defaults.
        expect(
          ThemePrefs.parse(mode: 'light', accent: '4', tinted: 'true').tinted,
          isTrue,
        );
        final odd = ThemePrefs.parse(mode: 'neon', accent: '99');
        expect(
          (odd.mode, odd.accent),
          (ThemeMode.dark, Tokens.accents.length - 1),
        );
      },
    );
  });
}
