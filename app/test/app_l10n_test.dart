// Owns: the app follows the system language (English template + German), with the core reached through the bridge.
import 'package:flutter_test/flutter_test.dart';
import 'package:gerdtv/main.dart';
import 'package:material_ui/material_ui.dart';

import 'support/fake_core.dart';

void main() {
  setUpAll(useFakeCore);

  for (final (locale, expected) in [
    (const Locale('en'), 'The core says: fake greeting for gerdTV'),
    (const Locale('de'), 'Der Kern sagt: fake greeting for gerdTV'),
  ]) {
    testWidgets(
      'shows the ${locale.languageCode} strings and the name gerdTV',
      (tester) async {
        tester.platformDispatcher.localesTestValue = [locale];
        addTearDown(tester.platformDispatcher.clearLocalesTestValue);
        await tester.pumpWidget(const GerdTvApp());
        await tester.pumpAndSettle();
        expect(find.text('gerdTV'), findsOneWidget);
        expect(find.text(expected), findsOneWidget);
      },
    );
  }
}
