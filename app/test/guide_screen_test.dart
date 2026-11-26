// New, because nothing owned the guide grid's order (shared with Live TV) or a guide refresh asked for while one runs;
// extended: a running programme's title stays visible when it began left of the view (sticky titles).
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

  /// The group's channels and each one's programmes (the sticky-title test).
  List<ItemInfo> channels = const [];
  List<GuideRow> rows = const [];

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
    return channels;
  }

  @override
  Future<List<GuideRow>> guideWindow({
    required List<String> keys,
    required int from,
    required int to,
  }) async => rows;

  @override
  Future<bool> guideDue() async => true;

  @override
  Future<List<GuideSourceInfo>> refreshGuide({
    required int daysAhead,
    required bool force,
  }) {
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

  testWidgets('a running title sticks to the left edge of the view', (
    tester,
  ) async {
    // Begun 3 h ago and scrolled further right than where the grid opens: the programme's start is left of the view
    // at any hour (just after midnight the grid opens at its start).
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final lib = _Library()
      ..channels = const [
        ItemInfo(
          key: 'live:1',
          kind: ItemKind.live,
          name: 'Channel',
          category: 'g',
          logo: '',
          archiveDays: 0,
          group: '',
        ),
      ]
      ..rows = [
        GuideRow(
          programmes: [
            ProgrammeInfo(
              id: 1,
              channel: 'c',
              start: now - 3 * 3600,
              stop: now + 3 * 3600,
              title: 'Long running show',
              subTitle: '',
              desc: '',
              category: '',
              episode: '',
            ),
          ],
        ),
      ];
    final session = Session(appDir: 'unused')..library = lib;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Scaffold(body: GuideScreen(session: session)),
      ),
    );
    await tester.pumpAndSettle();
    final cell = find.byKey(const Key('guide.cell.1'));
    final title = find.descendant(
      of: cell,
      matching: find.text('Long running show'),
    );
    final view = find
        .ancestor(
          of: cell,
          matching: find.byWidgetPredicate(
            (w) => w is Scrollable && w.axisDirection == AxisDirection.right,
          ),
        )
        .first;
    await tester.drag(view, const Offset(-300, 0));
    await tester.pumpAndSettle();
    final viewLeft = tester.getRect(view).left;
    expect(
      tester.getRect(cell).left,
      lessThan(viewLeft),
      reason: 'the programme begins left of the view',
    );
    expect(tester.getRect(title).left, greaterThanOrEqualTo(viewLeft));
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
