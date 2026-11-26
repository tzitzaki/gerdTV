// New, because nothing owns Cast on the app side: what can be cast, and the bar that shows a running cast with Stop.
import 'package:flutter_test/flutter_test.dart';
import 'package:gerdtv/l10n/gen/app_localizations.dart';
import 'package:gerdtv/screens/cast_ui.dart';
import 'package:gerdtv/services/casting.dart';
import 'package:gerdtv/services/session.dart';
import 'package:gerdtv/src/rust/api/library.dart';
import 'package:material_ui/material_ui.dart';

ItemInfo item(String key) => ItemInfo(
  key: key,
  kind: ItemKind.live,
  name: 'Channel One',
  category: 'g',
  logo: '',
  archiveDays: 0,
  group: '',
);

void main() {
  test('the library\'s items can be cast, archives and files can\'t', () {
    for (final (key, want) in [
      ('live:1', true),
      ('movie:2', true),
      ('catchup:live:1:100', false),
      ('premiumize:abc', false),
      ('recording:3', false),
    ]) {
      expect(castable(item(key)), want, reason: key);
    }
  });

  testWidgets('the bar shows the cast and Stop ends it', (tester) async {
    final session = Session(appDir: '/nonexistent');
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Scaffold(body: CastBar(session: session)),
      ),
    );
    expect(find.byKey(const Key('cast.bar')), findsNothing);
    session.casting.active.value = (
      device: 'Living room',
      item: item('live:1'),
      paused: false,
    );
    await tester.pump();
    expect(find.text('On Living room'), findsOneWidget);
    await tester.tap(find.byKey(const Key('cast.stop')));
    await tester.pump();
    expect(find.byKey(const Key('cast.bar')), findsNothing);
  });
}
