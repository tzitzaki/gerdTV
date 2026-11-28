// Owns: the app follows the system language (English template + German: the first run's welcome screen) and the
// provider form validates its fields before anything reaches the core.
import 'package:flutter_test/flutter_test.dart';
import 'package:gerdtv/main.dart';
import 'package:gerdtv/screens/setup_screen.dart';
import 'package:gerdtv/services/session.dart';
import 'package:material_ui/material_ui.dart';

import 'support/fake_core.dart';
import 'support/memory_secrets.dart';

Session setupSession() =>
    Session(secrets: MemorySecrets(), appDir: '/nonexistent')
      ..state = SessionState.needsSetup;

void main() {
  setUpAll(useFakeCore);

  for (final (locale, welcome, title, required) in [
    (const Locale('en'), 'Welcome to gerdTV', 'Add your provider', 'Required'),
    (
      const Locale('de'),
      'Willkommen bei gerdTV',
      'Anbieter hinzufügen',
      'Pflichtfeld',
    ),
  ]) {
    testWidgets(
      'setup screen in ${locale.languageCode} validates before connecting',
      (tester) async {
        tester.platformDispatcher.localesTestValue = [locale];
        addTearDown(tester.platformDispatcher.clearLocalesTestValue);
        final session = setupSession();
        await tester.pumpWidget(GerdTvApp(session: session));
        await tester.pumpAndSettle();
        expect(find.text(welcome), findsOneWidget);
        // The form as Settings → Account opens it.
        session.navigatorKey.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => SetupScreen(session: session),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text(title), findsOneWidget);
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
