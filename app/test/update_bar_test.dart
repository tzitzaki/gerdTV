// New, because nothing owned it: gerdTV tells about a new version by itself. A version found by the update check
// shows the bar under the app with this platform's step; closing it hides it for that version, and a newer one
// shows it again. The checks themselves (signature, version, platform) are the core's tests (update.rs).
import 'package:flutter_test/flutter_test.dart';
import 'package:gerdtv/l10n/gen/app_localizations.dart';
import 'package:gerdtv/screens/update_bar.dart';
import 'package:gerdtv/services/session.dart';
import 'package:gerdtv/src/rust/api/update.dart';
import 'package:material_ui/material_ui.dart';

import 'support/fake_core.dart';
import 'support/memory_secrets.dart';

class _UpdateCore extends FakeCore {
  String version = '0.991231.1';

  @override
  Future<UpdateInfo?> crateApiUpdateCheckUpdate({
    required String platform,
  }) async => UpdateInfo(
    version: version,
    notes: 'Notes',
    asset: 'gerdTV-linux-x64-$version.tar.gz',
    size: BigInt.one,
    sha256: '00',
    minOs: '',
    url: 'https://example.invalid/$version',
  );
}

void main() {
  late _UpdateCore core;
  setUpAll(() => core = useFakeCore(_UpdateCore()) as _UpdateCore);

  testWidgets(
    'a new version shows the bar; closed it stays away until a newer one',
    (tester) async {
      final session = Session(secrets: MemorySecrets(), appDir: '/nonexistent');
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: Scaffold(bottomNavigationBar: UpdateBar(session: session)),
        ),
      );
      expect(find.byKey(const Key('update.bar')), findsNothing);
      await session.updater.check();
      await tester.pump();
      expect(find.text('Version 0.991231.1 is available'), findsOneWidget);
      // Not fetched yet (the test runs as Linux): the step fetches first.
      expect(find.text('Download'), findsOneWidget);
      await tester.tap(find.byKey(const Key('update.bar.close')));
      await tester.pump();
      expect(find.byKey(const Key('update.bar')), findsNothing);
      await session.updater.check(); // the same version again: stays closed
      await tester.pump();
      expect(find.byKey(const Key('update.bar')), findsNothing);
      core.version = '0.991231.2';
      await session.updater.check();
      await tester.pump();
      expect(find.text('Version 0.991231.2 is available'), findsOneWidget);
    },
  );
}
