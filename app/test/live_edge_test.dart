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

  test('AVPlayer: its seekable end is live even while paused or rewound (it lags the clock by a segment or two)', () {
    final e = LiveEdge(seekableEndIsLive: true)..position(100);
    e.cache(130, at(0));
    e.detach(); // paused at 129
    e.cache(
      150,
      at(30),
    ); // the playlist grew in steps, a little behind the clock
    expect(e.live(at(30)), 150, reason: 'not 130 + 30 s');
    expect(e.behind(145, at(30)), 5);
  });

  test(
    'the seek range is the window back from live, never before the start',
    () {
      final e = LiveEdge()..position(100);
      e.cache(400, at(0));
      expect(e.earliest(120, at(0)), 280);
      expect(e.earliest(3600, at(0)), 100);
      // A start from the previous channel (a position event after a switch) is later than this stream's live: the
      // range never ends before it starts (seen: Live threw on clamp).
      final z = LiveEdge()..position(7.3);
      z.cache(2, at(0));
      expect(z.earliest(3600, at(0)), 2);
      // That late event of the previous channel is forgotten once this stream's own, smaller positions arrive: it
      // pushed Live past the cache's end (mpv dropped its cache and froze for 2 s) and blocked rewinding.
      final late = LiveEdge()
        ..position(6.3) // the previous channel's
        ..position(0.02);
      late.cache(5.94, at(0));
      expect(late.earliest(3600, at(0)), 0.02);
    },
  );

  test('Live lands where mpv neither waits nor counts as behind', () {
    // (cache-pause-wait of the buffer, where Live lands, up to where it's live): closer than twice the wait,
    // mpv ran dry and froze right after Live (the journey's flaky "keeps playing" step); Live itself never shows
    // "behind live".
    for (final (wait, margin, slack) in [
      (2, 5.0, 6.0),
      (0, 1.0, 3.0),
      (30, 61.0, 62.0),
    ]) {
      expect(goLiveMargin(wait), margin);
      expect(liveSlackFor(wait), slack);
      expect(goLiveMargin(wait), lessThan(liveSlackFor(wait)));
    }
    final e = LiveEdge()..cache(100, DateTime(2026));
    expect(e.behind(100 - 61, DateTime(2026), slack: liveSlackFor(30)), 0);
    expect(
      e.behind(100 - 61, DateTime(2026)),
      61,
      reason: 'the plain slack is 3 s',
    );
  });

  test(
    'Live is live also when the cache lags the projected edge (slow network)',
    () {
      final e = LiveEdge()..position(0);
      e.cache(10, at(0));
      e.detach(); // paused; 6 s later live is projected at 16, but only 13 arrived
      final to = e.seek(
        13 - goLiveMargin(2),
        at(6),
        windowSecs: 3600,
        slack: liveSlackFor(2),
        toLive: true,
      );
      expect(to, 8);
      e.cache(
        13,
        at(6),
      ); // mpv's next report: the cache around the new position
      expect(e.behind(8, at(6), slack: liveSlackFor(2)), 0);
      e.cache(17, at(10)); // the label doesn't come back while it plays on
      expect(e.behind(12, at(10), slack: liveSlackFor(2)), 0);
      // A plain seek to the same place is still off live.
      e.seek(8, at(10), windowSecs: 3600, slack: liveSlackFor(2));
      expect(e.detached, isTrue);
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
