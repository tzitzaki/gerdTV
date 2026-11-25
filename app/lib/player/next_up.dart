// After an episode: a countdown to the next one, which the player shows with Play now and Cancel (docs/SPEC.md).
// Only the countdown lives here; the session decides when an episode has ended and what comes next.
// Debugging a next episode that doesn't come: the core finds it by season and episode number (db::next_episode), and
// the session asks only when the player ran to the end (Session._onCompleted).

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../src/rust/api/library.dart';

/// Whether a file that ended got to the share the core calls finished (95 %). In milliseconds: whole seconds said
/// 9 of 10 for a file that stopped 14 ms short of 10.005 s, and nothing followed (seen in the journey test).
bool ranToTheEnd(Duration position, Duration duration) =>
    duration > Duration.zero &&
    position.inMilliseconds >= duration.inMilliseconds * 0.95;

typedef NextUpState = ({ItemInfo item, int seconds});

class NextUp extends ValueNotifier<NextUpState?> {
  NextUp(this._play) : super(null);
  final void Function(ItemInfo) _play;
  Timer? _timer;

  static const countdown = 10;

  void start(ItemInfo item) {
    _timer?.cancel();
    value = (item: item, seconds: countdown);
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      final s = value!;
      if (s.seconds <= 1) {
        playNow();
      } else {
        value = (item: s.item, seconds: s.seconds - 1);
      }
    });
  }

  void playNow() {
    final item = value?.item;
    cancel();
    if (item != null) _play(item);
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
    value = null;
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
