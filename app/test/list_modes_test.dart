// New, because nothing owns how the list modes render: every mode at phone and desktop width lays out without
// overflow (stars included), shows the name (without the channel number), and shows what's on now where the mode has room for it (list and tiles,
// not compact). Favourites: the star, a long press and a long OK toggle one; a short OK opens.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gerdtv/l10n/gen/app_localizations.dart';
import 'package:gerdtv/screens/list_modes.dart';
import 'package:gerdtv/src/rust/api/library.dart';
import 'package:material_ui/material_ui.dart';

ItemInfo channel(int i) => ItemInfo(
  key: 'live:$i',
  kind: ItemKind.live,
  name: 'Channel $i with a rather long name HD',
  category: 'g',
  logo: '', // no URL: the icon shows, no core call
  number: i,
  archiveDays: 0,
  group: '',
);

ProgrammeInfo prog(String title, DateTime start, Duration length) =>
    ProgrammeInfo(
      id: title.hashCode,
      channel: 'c',
      start: start.millisecondsSinceEpoch ~/ 1000,
      stop: start.add(length).millisecondsSinceEpoch ~/ 1000,
      title: title,
      subTitle: '',
      desc: '',
      category: '',
      episode: '',
    );

void main() {
  final now = DateTime(2026, 11, 22, 20, 30);
  final items = [for (var i = 1; i <= 30; i++) channel(i)];
  final nowNext = {
    'live:1': NowNext(
      now: prog(
        'News at eight',
        DateTime(2026, 11, 22, 20),
        const Duration(hours: 1),
      ),
      next: prog(
        'Late film',
        DateTime(2026, 11, 22, 21),
        const Duration(hours: 2),
      ),
    ),
  };
  // (mode, shows the now title)
  const cases = [
    (ListMode.compact, false),
    (ListMode.list, true),
    (ListMode.tiles, true),
    (ListMode.largeTiles, true),
  ];
  for (final size in const [Size(360, 740), Size(1280, 800)]) {
    for (final (mode, showsNow) in cases) {
      testWidgets('${mode.name} at ${size.width.toInt()} px', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            home: Scaffold(
              body: ItemsView(
                mode: mode,
                items: items,
                nowNext: nowNext,
                now: now,
                onTap: (_) {},
                favourites: const {'live:1'},
                onFavourite: (_) {},
              ),
            ),
          ),
        );
        expect(tester.takeException(), isNull, reason: 'no overflow');
        // The name alone: no channel number in front (owner decision), though channel(1) has number 1.
        expect(
          find.text('Channel 1 with a rather long name HD'),
          findsOneWidget,
        );
        expect(
          find.text('News at eight'),
          showsNow ? findsOneWidget : findsNothing,
        );
        if (mode == ListMode.list) {
          final bar = tester.widget<LinearProgressIndicator>(
            find.byType(LinearProgressIndicator),
          );
          expect(bar.value, closeTo(0.5, 0.01));
          expect(find.text('Late film'), findsOneWidget);
        }
      });
    }
  }

  testWidgets(
    'star, long press and long OK toggle a favourite; short OK opens',
    (tester) async {
      final opened = <String>[], starred = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: Scaffold(
            body: ItemsView(
              mode: ListMode.list,
              items: [channel(1), channel(2)],
              nowNext: const {},
              now: now,
              onTap: (it) => opened.add(it.key),
              onFavourite: (it) => starred.add(it.key),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('item.star.live:1')));
      await tester.longPress(find.byKey(const Key('item.live:2')));
      expect(starred, ['live:1', 'live:2']);
      expect(opened, isEmpty);
      // The remote: Tab focuses the first row, then OK briefly (opens) and held (toggles).
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
      expect(opened, ['live:1']);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
      expect(opened, ['live:1'], reason: 'held OK does not open');
      expect(starred.last, 'live:1');
    },
  );

  // Sort: each list offers only the orders that make sense for it, and the menu reports the pick.
  test('sort options per list', () {
    const p = ListSort.provider, a = ListSort.nameAsc, z = ListSort.nameDesc;
    for (final (kind, groups, xtream, want) in [
      (ItemKind.live, true, true, [p, a, z]),
      (ItemKind.live, false, true, [p, a, z, ListSort.number]),
      (ItemKind.movie, true, true, [p, a, z]),
      (
        ItemKind.movie,
        false,
        true,
        [
          p,
          a,
          z,
          ListSort.yearDesc,
          ListSort.yearAsc,
          ListSort.added,
          ListSort.rating,
        ],
      ),
      (
        ItemKind.series,
        false,
        false,
        [p, a, z, ListSort.yearDesc, ListSort.yearAsc],
      ),
    ]) {
      expect(
        sortOptions(kind, groups: groups, xtream: xtream),
        want,
        reason: '$kind groups=$groups xtream=$xtream',
      );
    }
    expect(parseSort('rating'), ListSort.rating);
    expect(parseSort(null), ListSort.provider);
    expect(parseSort('gone'), ListSort.provider);
  });

  testWidgets('the sort menu checks the current order and reports the pick', (
    tester,
  ) async {
    final picked = <ListSort>[];
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Scaffold(
          appBar: AppBar(
            actions: [
              SortButton(
                value: ListSort.provider,
                options: sortOptions(
                  ItemKind.live,
                  groups: false,
                  xtream: false,
                ),
                onSelected: picked.add,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('list.sort')));
    await tester.pumpAndSettle();
    expect(find.text('Channel number'), findsOneWidget);
    expect(find.text('Rating'), findsNothing);
    await tester.tap(find.byKey(const Key('sort.number')));
    await tester.pumpAndSettle();
    expect(picked, [ListSort.number]);
  });

  // The cinematic tiles: a focused or hovered tile lifts (5 % larger), never with reduced motion; a poster's name sits
  // on the picture in white, a channel's below its logo.
  for (final still in [false, true]) {
    testWidgets(
      'a focused tile lifts${still ? ', not with reduced motion' : ''}',
      (tester) async {
        final movie = ItemInfo(
          key: 'movie:1',
          kind: ItemKind.movie,
          name: 'A film',
          category: 'g',
          logo: '',
          number: null,
          archiveDays: 0,
          group: '',
        );
        await tester.pumpWidget(
          MediaQuery(
            data: MediaQueryData(disableAnimations: still),
            child: MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              home: Scaffold(
                body: ItemsView(
                  mode: ListMode.tiles,
                  items: [movie, channel(2)],
                  nowNext: const {},
                  now: now,
                  onTap: (_) {},
                ),
              ),
            ),
          ),
        );
        double scaleOf(String key) => tester
            .widget<AnimatedScale>(
              find.ancestor(
                of: find.byKey(Key(key)),
                matching: find.byType(AnimatedScale),
              ),
            )
            .scale;
        expect(scaleOf('item.movie:1'), 1.0);
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pumpAndSettle();
        expect(scaleOf('item.movie:1'), still ? 1.0 : 1.05);
        expect(scaleOf('item.live:2'), 1.0);
        final name = tester.widget<RichText>(
          find
              .descendant(
                of: find.byKey(const Key('item.movie:1')),
                matching: find.byType(RichText),
              )
              .last,
        );
        expect(name.text.style?.color, Colors.white, reason: 'on the poster');
      },
    );
  }
}
