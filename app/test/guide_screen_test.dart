// New, because nothing owned the guide grid's order (shared with Live TV) or a guide refresh asked for while one runs.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gerdtv/l10n/gen/app_localizations.dart';
import 'package:gerdtv/screens/guide_screen.dart';
import 'package:gerdtv/screens/list_modes.dart';
import 'package:gerdtv/services/session.dart';
import 'package:gerdtv/src/rust/api/library.dart';
import 'package:material_ui/material_ui.dart';

class _Library implements Library {
  final settings = <String, String>{};
  final sorts = <String>[];
  final refreshes = <Completer<List<GuideSourceInfo>>>[];

  @override
  String? setting({required String key}) => settings[key];

  @override
  void setSetting({required String key, required String value}) =>
      settings[key] = value;

  @override
  Future<List<CategoryInfo>> categories({
    required ItemKind kind,
    required String sort,
  }) async => const [CategoryInfo(id: 'g', name: 'Group', count: 1)];

  @override
  Future<List<ItemInfo>> items({
    required ItemKind kind,
    required String category,
    required String sort,
    required int limit,
    required int offset,
  }) async {
    sorts.add(sort);
    return const [];
  }

  @override
  Future<int?> guideAge() async => null;

  @override
  Future<List<GuideSourceInfo>> refreshGuide({required int daysAhead}) {
    refreshes.add(Completer());
    return refreshes.last.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('the sort button reorders the guide and Live TV', (tester) async {
    final lib = _Library();
    final session = Session(appDir: 'unused')..library = lib;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Scaffold(body: GuideScreen(session: session)),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(const Key('list.sort')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('sort.name_desc')));
    await tester.pumpAndSettle();
    expect(lib.sorts, ['provider', 'name_desc']);
    // The setting Live TV reads.
    expect(
      lib.settings[sortSetting(ItemKind.live, groups: false)],
      'name_desc',
    );
    await tester.pumpWidget(const SizedBox());
  });

  // Not a widget test: the session's hourly timer outlives it.
  test('a refresh asked for during a refresh runs afterwards, once', () async {
    final lib = _Library();
    final session = Session(appDir: 'unused')..library = lib;
    unawaited(session.refreshGuide());
    await Future<void>.delayed(Duration.zero);
    unawaited(session.refreshGuide(force: true)); // a source was just added
    unawaited(session.refreshGuide(force: true));
    await Future<void>.delayed(Duration.zero);
    expect(lib.refreshes.length, 1);
    lib.refreshes[0].complete(const []);
    await Future<void>.delayed(Duration.zero);
    expect(lib.refreshes.length, 2);
    lib.refreshes[1].complete(const []);
    await Future<void>.delayed(Duration.zero);
    expect((lib.refreshes.length, session.guideRefreshing), (2, false));
  });
}
