// New, because nothing owns the shape of Settings: the search filter (every word must match an entry's title,
// keywords or category, accents folded) and the two layouts (categories beside the content on wide windows, a list
// that opens a page on phones), with the search narrowing the visible entries as you type; picking a logo stores it
// app-wide.
import 'package:flutter_test/flutter_test.dart';
import 'package:gerdtv/l10n/gen/app_localizations.dart';
import 'package:gerdtv/screens/app_logo.dart';
import 'package:gerdtv/screens/settings_model.dart';
import 'package:gerdtv/screens/settings_screen.dart';
import 'package:gerdtv/services/session.dart';
import 'package:material_ui/material_ui.dart';

import 'support/fake_core.dart';

SettingsEntry entry(String id, String title, [String keywords = '']) =>
    SettingsEntry(
      id: id,
      title: title,
      keywords: keywords,
      build: (_) => const SizedBox(),
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
  ];

  test('filterSettings keeps matching entries under their category', () {
    String ids(String q) => [
      for (final c in filterSettings(categories, q))
        '${c.id}:${c.entries.map((e) => e.id).join(',')}',
    ].join(' ');
    for (final (query, want) in [
      ('', 'playback:buffer,timeshift about:licences'), // nothing typed: all
      ('  ', 'playback:buffer,timeshift about:licences'),
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
    }) async {
      final session = Session(appDir: 'unused-by-the-fake');
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
      for (final id in ['account', 'health', 'about']) {
        expect(find.byKey(Key('settings.cat.$id')), findsOneWidget);
      }
      // Profile categories need an open library (none here).
      for (final id in ['playback', 'data']) {
        expect(find.byKey(Key('settings.cat.$id')), findsNothing);
      }
      // The first category shows; another one replaces it.
      expect(find.byKey(const Key('settings.remove')), findsOneWidget);
      await tester.tap(find.byKey(const Key('settings.cat.about')));
      await tester.pump();
      expect(find.byKey(const Key('settings.remove')), findsNothing);
      expect(find.text('Licences'), findsOneWidget);

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
  });
}
