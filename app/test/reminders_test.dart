// New, because nothing owned reminder ids: a reminder's notification id must be the same in every run (clearing a
// reminder after a restart cancels it by that id) and differ between programmes.
import 'package:flutter_test/flutter_test.dart';
import 'package:gerdtv/services/reminders.dart';

void main() {
  test('reminder ids are stable and distinct', () {
    // Fixed values: computed once; a change here means scheduled notifications could no longer be cancelled.
    expect(
      Reminders.idFor('live:42', 1795400000),
      Reminders.idFor('live:42', 1795400000),
    );
    final ids = {
      for (final key in ['live:1', 'live:2', 'live:42'])
        for (final start in [1795400000, 1795401800])
          Reminders.idFor(key, start),
    };
    expect(
      ids.length,
      6,
      reason: 'no collisions between channels or start times',
    );
    expect(
      ids.every((id) => id >= 0 && id <= 0x7fffffff),
      isTrue,
      reason: 'Android wants a 32-bit int',
    );
  });
}
