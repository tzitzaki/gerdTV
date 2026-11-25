// New, because nothing owns the display's refresh rate: which mode fits a stream, and when not to switch.
import 'package:flutter_test/flutter_test.dart';
import 'package:gerdtv/player/frame_rate.dart';

void main() {
  DisplayMode mode(int id, double rate, [int w = 1920]) =>
      (id: id, width: w, height: w * 9 ~/ 16, rate: rate);
  final modes = [
    mode(1, 60),
    mode(2, 59.94),
    mode(3, 50),
    mode(4, 25),
    mode(5, 24),
    mode(6, 23.976),
    mode(7, 50, 3840),
  ];
  for (final (fps, current, want) in [
    (25.0, 1, 3), // fastest multiple, in the current resolution only
    (50.0, 1, 3),
    (24.0, 1, 5),
    (23.976, 1, 6),
    (29.97, 1, 2),
    (30.0, 2, 1),
    (60.0, 1, null), // already right
    (25.0, 4, null), // 25 Hz fits too: no switch for nothing
    (0.0, 1, null), // not known
    (17.0, 1, null), // nothing fits
  ]) {
    test('$fps fps at mode $current', () {
      final c = modes.firstWhere((m) => m.id == current);
      expect(displayModeFor(fps, modes, c)?.id, want);
    });
  }
}
