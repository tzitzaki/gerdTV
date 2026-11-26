// Owns: the app follows the system language (English template + German) and the first-run form validates its
// fields before anything reaches the core.
import 'package:flutter_test/flutter_test.dart';
import 'package:gerdtv/main.dart';
import 'package:gerdtv/services/session.dart';
import 'package:material_ui/material_ui.dart';

import 'support/fake_core.dart';

Session setupSession() =>
    Session(appDir: '/nonexistent')..state = SessionState.needsSetup;

void main() {
  setUpAll(useFakeCore);

  for (final (locale, title, required) in [
    (const Locale('en'), 'Add your provider', 'Required'),
    (const Locale('de'), 'Anbieter hinzufügen', 'Pflichtfeld'),
  ]) {
    testWidgets(
      'setup screen in ${locale.languageCode} validates before connecting',
      (tester) async {
        tester.platformDispatcher.localesTestValue = [locale];
        addTearDown(tester.platformDispatcher.clearLocalesTestValue);
        await tester.pumpWidget(GerdTvApp(session: setupSession()));
        await tester.pumpAndSettle();
        expect(find.text(title), findsOneWidget);
        // The form scrolls (logo on top): bring Connect into the 800×600 test window first.
        // Connect shows without scrolling in the Mac's default window (800 × 600, the tests' size too). English only:
        // the wider test font wraps the longer German texts, so there the form scrolls.
        if (locale.languageCode == 'en') {
          expect(
            find.byKey(const Key('setup.connect')).hitTestable(),
            findsOneWidget,
          );
        }
        await tester.ensureVisible(find.byKey(const Key('setup.connect')));
        await tester.tap(find.byKey(const Key('setup.connect')));
        await tester.pumpAndSettle();
        expect(
          find.text(required),
          findsNWidgets(3),
        ); // server, username, password
        await tester.enterText(
          find.byKey(const Key('setup.server')),
          'not a url',
        );
        await tester.tap(find.byKey(const Key('setup.connect')));
        await tester.pumpAndSettle();
        expect(find.textContaining('http://'), findsWidgets);
      },
    );
  }
}
