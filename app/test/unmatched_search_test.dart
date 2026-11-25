// New, because nothing owned the search on "Channels without a guide": it asks the core with the typed text
// (so it covers every page, not just the loaded ones). Also its way out: a suggestion maps with one tap, and a mapping
// can be undone.
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

  /// Item key → guide channel, as the core stores it.
  final map = <String, String>{};

  @override
  Future<List<ChannelRef>> suggestGuideChannels({
    required String itemKey,
    required int limit,
  }) async => const [ChannelRef(id: 'arte.de', name: 'ARTE')];

  @override
  Future<List<ChannelRef>> findGuideChannels({
    required String query,
    required int limit,
  }) async => const [ChannelRef(id: 'zoo.de', name: 'Zoo')];

  @override
  Future<void> mapChannel({required String itemKey, String? channel}) async {
    if (channel == null) {
      map.remove(itemKey);
    } else {
      map[itemKey] = channel;
    }
  }

  @override
  Future<List<MappedChannel>> mappedChannels() async => [
    for (final e in map.entries)
      MappedChannel(id: e.key, name: e.key, guide: e.value),
  ];

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
      find.byKey(const Key('guide.unmatchedSearch')),
      'erste',
    );
    await tester.pumpAndSettle();
    expect(lib.asked.last, 'erste');
    expect(find.text('Arte'), findsNothing);
    expect(find.text('Das Erste'), findsOneWidget);
    expect(find.text('Erste Sport'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('guide.unmatchedSearch')),
      'zdf',
    );
    await tester.pumpAndSettle();
    expect(find.text('Nothing found for “zdf”.'), findsOneWidget);
  });

  testWidgets('a suggestion maps with one tap, and Undo takes it back', (
    tester,
  ) async {
    final lib = _Library();
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: UnmatchedChannelsScreen(library: lib),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('guide.unmatched.live:Arte')));
    await tester.pumpAndSettle();
    expect(lib.map, isEmpty, reason: 'nothing is mapped without a tap');
    // Above the guide's channels; a search of one's own replaces it.
    expect(
      tester.getTopLeft(find.text('ARTE')).dy,
      lessThan(tester.getTopLeft(find.text('Zoo')).dy),
    );
    await tester.enterText(find.byKey(const Key('guide.find')), 'z');
    await tester.pumpAndSettle();
    expect(find.text('ARTE'), findsNothing);
    await tester.enterText(find.byKey(const Key('guide.find')), '');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('guide.suggested.arte.de')));
    await tester.pumpAndSettle();
    expect(lib.map, {'live:Arte': 'arte.de'});
    await tester.tap(find.byKey(const Key('guide.mapped')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('guide.unmap.live:Arte')));
    await tester.pumpAndSettle();
    expect(lib.map, isEmpty);
    expect(find.text('No channel is mapped by hand.'), findsOneWidget);
  });
}
