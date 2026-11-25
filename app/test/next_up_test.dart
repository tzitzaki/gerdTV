// New, because nothing owns what follows an episode: the countdown plays the next one once, Cancel keeps it away, and
// Play now doesn't play it a second time when the countdown would have ended.
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
