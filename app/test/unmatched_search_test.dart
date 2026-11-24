// New, because nothing owned the search on "Channels without a guide": it asks the core with the typed text
// (so it covers every page, not just the loaded ones).
import 'package:flutter_test/flutter_test.dart';
import 'package:gerdtv/l10n/gen/app_localizations.dart';
import 'package:gerdtv/screens/guide_settings.dart';
import 'package:gerdtv/src/rust/api/library.dart';
import 'package:material_ui/material_ui.dart';

class _Library implements Library {
  final asked = <String>[];
  static const _all = ['Arte', 'Das Erste', 'Erste Sport'];

  @override
  Future<List<ChannelRef>> unmatchedChannels({
    required int limit,
    required int offset,
    required String query,
  }) async {
    asked.add(query);
    return [
      for (final n in _all)
        if (n.toLowerCase().contains(query.toLowerCase()))
          ChannelRef(id: 'live:$n', name: n),
    ];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('typing narrows the list in the core', (tester) async {
    final lib = _Library();
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: UnmatchedChannelsScreen(library: lib),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Arte'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('guide.unmatched.search')),
      'erste',
    );
    await tester.pumpAndSettle();
    expect(lib.asked.last, 'erste');
    expect(find.text('Arte'), findsNothing);
    expect(find.text('Das Erste'), findsOneWidget);
    expect(find.text('Erste Sport'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('guide.unmatched.search')),
      'zdf',
    );
    await tester.pumpAndSettle();
    expect(find.text('Nothing found for “zdf”.'), findsOneWidget);
  });
}
