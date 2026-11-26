// New, because nothing owns the user's order in the menus: where a move leads, and when there is none.
import 'package:flutter_test/flutter_test.dart';
import 'package:gerdtv/screens/group_menus.dart';

void main() {
  test('moving keeps the others in order and stops at the ends', () {
    const ids = ['a', 'b', 'c'];
    for (final (from, by, want) in [
      (1, -1, ['b', 'a', 'c']),
      (1, 1, ['a', 'c', 'b']),
      (2, -2, ['c', 'a', 'b']),
      (0, -1, null),
      (2, 1, null),
      (-1, 1, null), // not in the list
    ]) {
      expect(moved(ids, from, by), want, reason: '$from by $by');
    }
    expect(isOwnGroup('custom:1') && !isOwnGroup('12'), isTrue);
  });
}
