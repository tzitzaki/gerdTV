// When leaving the app floats the picture (owner decision: only while something really plays; docs/SPEC.md). Session
// evaluates this on every player event and tells the native side about changes (setFloating), which arms or disarms
// the system's automatic Picture-in-Picture. Disarming never closes a window that is already open: pausing inside it
// leaves it there, to play on.
// Debugging a window that appears with nothing playing: log the five inputs in Session._updateFloating.

/// [selected]: a stream is now playing as far as the app is concerned (Stop clears it). [playing]: not paused.
/// [completed]: it ran to its end. [position]: past 0 once it has really started. [failed]: the watchdog gave up.
bool floatsOnLeave({
  required bool selected,
  required bool playing,
  required bool completed,
  required Duration position,
  required bool failed,
}) => selected && playing && !completed && !failed && position > Duration.zero;
