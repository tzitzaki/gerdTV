// New, because nothing owns how the list modes render: every mode at phone and desktop width lays out without
// overflow, shows the name, and shows what's on now where the mode has room for it (list and tiles, not compact).
import 'package:flutter_test/flutter_test.dart';
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
            home: Scaffold(
              body: ItemsView(
                mode: mode,
                items: items,
                nowNext: nowNext,
                now: now,
                onTap: (_) {},
              ),
            ),
          ),
        );
        expect(tester.takeException(), isNull, reason: 'no overflow');
        expect(find.textContaining('Channel 1 with'), findsOneWidget);
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
}
