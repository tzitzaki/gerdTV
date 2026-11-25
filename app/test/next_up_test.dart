// New, because nothing owns what follows an episode: only a file that got to its end counts, the countdown plays the
// next one once, Cancel keeps it away, and Play now doesn't play it a second time when the countdown would have ended.
import 'package:flutter_test/flutter_test.dart';
import 'package:gerdtv/player/next_up.dart';
import 'package:gerdtv/src/rust/api/library.dart';

const next = ItemInfo(
  key: 'episode:2',
  kind: ItemKind.episode,
  name: 'Show S01E02',
  category: 'series:1',
  logo: '',
  archiveDays: 0,
  group: '',
);

void main() {
  test('a file ran to its end from 95 %, by the millisecond', () {
    const ms = Duration.new;
    for (final (pos, dur, want) in [
      (ms(milliseconds: 9991), ms(milliseconds: 10005), true),
      (ms(minutes: 43), ms(minutes: 45), true),
      (ms(minutes: 40), ms(minutes: 45), false), // the connection was lost
      (ms(seconds: 5), Duration.zero, false), // no length known
    ]) {
      expect(ranToTheEnd(pos, dur), want, reason: '$pos of $dur');
    }
  });

  for (final (name, act, want) in [
    ('left alone, it plays', (NextUp n) {}, 1),
    ('Cancel', (NextUp n) => n.cancel(), 0),
    ('Play now', (NextUp n) => n.playNow(), 1),
  ]) {
    testWidgets(name, (tester) async {
      var played = 0;
      final n = NextUp((_) => played++)..start(next);
      await tester.pump(const Duration(seconds: 9));
      expect((played, n.value?.seconds), (0, 1));
      act(n);
      await tester.pump(const Duration(seconds: 5));
      expect((played, n.value), (want, null));
      n.dispose();
    });
  }
}
