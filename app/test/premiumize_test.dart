// New, because nothing owned linking a service: Settings → Account links Premiumize with a key only once
// Premiumize accepted it (a refused one shows the reason and stores nothing), keeps the token per profile in the
// secure storage, and unlinks; sizes read in metric units.
import 'package:flutter_test/flutter_test.dart';
import 'package:gerdtv/l10n/gen/app_localizations.dart';
import 'package:gerdtv/screens/premiumize_screen.dart';
import 'package:gerdtv/screens/shell.dart';
import 'package:gerdtv/services/session.dart';
import 'package:gerdtv/src/rust/api/library.dart';
import 'package:material_ui/material_ui.dart';

import 'support/fake_core.dart';
import 'support/memory_secrets.dart';

void main() {
  setUpAll(useFakeCore);

  test('sizes are metric', () {
    expect(sizeLabel(820000000), '820 MB');
    expect(sizeLabel(1400000000), '1.4 GB');
  });

  testWidgets('link with a key, refused key, unlink', (tester) async {
    final secrets = MemorySecrets();
    final session = Session(secrets: secrets, appDir: '/nonexistent')
      ..profile = const ProfileInfo(
        id: 'p1',
        name: 'P',
        source: SourceKind.xtream,
        server: 'http://p.example.invalid',
        userAgent: '',
      );
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Scaffold(body: PremiumizeSettings(session: session)),
      ),
    );
    // The code login needs the user's own client id (none ships with gerdTV): it shows once one is typed.
    final code = find.byKey(const Key('premiumize.code'));
    expect(code, findsNothing);
    await tester.enterText(find.byKey(const Key('premiumize.clientId')), 'id');
    await tester.pump();
    expect(code, findsOneWidget);
    await tester.runAsync(() => session.setPremiumizeApp(' my-id '));
    expect(secrets.services, {'premiumize-app.p1': 'my-id'});
    await tester.runAsync(() => session.setPremiumizeApp(''));
    expect(secrets.services, isEmpty);

    final key = find.byKey(const Key('premiumize.key'));
    await tester.enterText(key, 'bad');
    await tester.tap(find.byKey(const Key('premiumize.link')));
    await tester.pumpAndSettle();
    expect(find.textContaining('authentication_failed'), findsOneWidget);
    expect(secrets.services, isEmpty, reason: 'a refused key is not stored');

    await tester.enterText(key, ' good-key ');
    await tester.tap(find.byKey(const Key('premiumize.link')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('premiumize.linked')), findsOneWidget);
    expect(secrets.services, {'premiumize.p1': 'good-key'});
    expect(session.premiumizeToken, 'good-key');
    // Linked, it is a section of its own after Series.
    expect(shellPages(provider: true, premiumize: true).map((p) => p.name), [
      'tv',
      'movies',
      'series',
      'premiumize',
      'settings',
    ]);
    expect(
      shellPages(provider: true, premiumize: false),
      isNot(contains(ShellPage.premiumize)),
    );
    await tester.tap(find.byKey(const Key('premiumize.unlink')));
    await tester.pumpAndSettle();
    expect(secrets.services, isEmpty);
    expect(find.byKey(const Key('premiumize.key')), findsOneWidget);
  });
}
