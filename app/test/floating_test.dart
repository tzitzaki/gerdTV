// New, because nothing owned when leaving the app floats the picture (owner decision: only while something plays).
import 'package:flutter_test/flutter_test.dart';
import 'package:gerdtv/player/floating.dart';

void main() {
  test('only a stream that really plays floats', () {
    bool floats({
      bool selected = true,
      bool playing = true,
      bool completed = false,
      int secs = 5,
      bool failed = false,
    }) => floatsOnLeave(
      selected: selected,
      playing: playing,
      completed: completed,
      position: Duration(seconds: secs),
      failed: failed,
    );
    expect(floats(), isTrue);
    expect(floats(selected: false), isFalse, reason: 'stopped');
    expect(floats(playing: false), isFalse, reason: 'paused');
    expect(floats(completed: true), isFalse, reason: 'ended');
    expect(floats(secs: 0), isFalse, reason: 'requested, not started');
    expect(floats(failed: true), isFalse, reason: 'the watchdog gave up');
  });
}
