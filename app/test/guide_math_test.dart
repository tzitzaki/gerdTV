// New, because nothing owned the guide grid's geometry: cells clipped to the window, half-hour floors, day list.
import 'package:flutter_test/flutter_test.dart';
import 'package:gerdtv/screens/guide_math.dart';

void main() {
  test('programme cells are placed and clipped to the loaded window', () {
    const from = 36000, to = 36000 + 3 * 3600; // a 3 h window
    // (start, stop, expected left/width at 4 px per minute, or null)
    final cases = <(int, int, ({double left, double width})?)>[
      (from, from + 1800, (left: 0, width: 120)), // first half hour
      (from + 3600, from + 5400, (left: 240, width: 120)),
      (
        from - 1800,
        from + 900,
        (left: 0, width: 60),
      ), // started before the window: clipped left
      (
        to - 900,
        to + 3600,
        (left: 660, width: 60),
      ), // runs past the window: clipped right
      (from - 3600, from, null), // ended exactly at the window start
      (to, to + 600, null), // starts at the window end
    ];
    for (final (start, stop, want) in cases) {
      expect(
        cellGeometry(start, stop, from, to, 4),
        want,
        reason: '$start–$stop',
      );
    }
  });

  test('half-hour floor and the day picker', () {
    final t = DateTime.utc(2026, 11, 22, 20, 47, 13);
    expect(
      floorToHalfHour(t),
      DateTime.utc(2026, 11, 22, 20, 30).millisecondsSinceEpoch ~/ 1000,
    );
    final days = guideDays(DateTime(2026, 11, 22, 1, 5), ahead: 3);
    expect(days.length, 6, reason: '2 back, today, 3 ahead');
    expect(days.first, DateTime(2026, 11, 20));
    expect(days.last, DateTime(2026, 11, 25));
  });
}
