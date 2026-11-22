// The MVP journey on the Linux desktop build, against the testkit's mock Xtream Codes panel: first-run setup →
// sync → browse a group → play a channel → global search (narrows per keystroke, Enter plays the top result) →
// remove the account. Needs the mock panel: `just test-integration` starts it (GERDTV_MOCK_XC).
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gerdtv/main.dart';
import 'package:gerdtv/screens/item_tile.dart';
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

    // First run: the Xtream Codes login.
    expect(find.text('Add your provider'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('setup.server')), mockXc);
    await tester.enterText(find.byKey(const Key('setup.username')), 'testuser');
    await tester.enterText(find.byKey(const Key('setup.password')), 'testpass');
    await tester.tap(find.byKey(const Key('setup.connect')));
    await waitFor(tester, find.byType(NavigationRail));
    expect(session.lastSync!.entries, greaterThan(1000));

    // Browse: the first live group, then its first channel plays.
    await waitFor(tester, find.byType(ListTile));
    await tester.tap(find.byType(ListTile).first);
    await waitFor(tester, find.byType(ItemTile));
    await tester.tap(find.byType(ItemTile).first);
    await waitFor(tester, find.byKey(const Key('player.back')));
    final end = DateTime.now().add(const Duration(seconds: 30));
    while (session.player.state.position < const Duration(seconds: 1)) {
      if (DateTime.now().isAfter(end)) fail('no playback');
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pump();
    }
    await tester.tap(find.byKey(const Key('player.back')));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();

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
    await tester.pumpAndSettle();

    // Settings: remove the account → back to setup.
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings.remove')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove'));
    await waitFor(tester, find.text('Add your provider'));
    await tester.runAsync(() => dir.delete(recursive: true));
  });
}
