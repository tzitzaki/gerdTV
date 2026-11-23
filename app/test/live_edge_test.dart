// Owns: where live is while pausing and rewinding (the "behind live" label, the seek bar's range, Go live).
import 'package:flutter_test/flutter_test.dart';
import 'package:gerdtv/player/live_edge.dart';

void main() {
  final t0 = DateTime(2026, 11, 23, 20);
  DateTime at(int secs) => t0.add(Duration(seconds: secs));

  test(
    'attached, live is the cache end; after a pause it moves on in real time',
    () {
      final e = LiveEdge()..position(100);
      e.cache(130, at(0));
      expect(e.behind(129, at(0)), 0, reason: 'a second behind counts as live');
      e.detach(); // paused at 129
      e.cache(
        131,
        at(1),
      ); // after a seek mpv reports the range around the position: ignored
      expect(e.behind(129, at(60)), 61);
      expect(behindLabel(e.behind(129, at(60))), '−1:01');
      e.attach(); // Go live
      e.cache(200, at(70));
      expect(e.behind(199, at(70)), 0);
    },
  );

  test(
    'the seek range is the window back from live, never before the start',
    () {
      final e = LiveEdge()..position(100);
      e.cache(400, at(0));
      expect(e.earliest(120, at(0)), 280);
      expect(e.earliest(3600, at(0)), 100);
    },
  );

  test('labels', () {
    for (final (secs, label) in [
      (0, '−0:00'),
      (312, '−5:12'),
      (3723, '−1:02:03'),
    ]) {
      expect(behindLabel(secs), label);
    }
  });
}
