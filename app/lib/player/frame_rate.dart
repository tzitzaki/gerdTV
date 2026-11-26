// Android TV: switches the display to a refresh rate that fits the stream (25 or 50 fps at 50 Hz, 24 at 24 Hz), or
// every few frames show longer than the others (judder). Off by default: the screen goes black for a moment per switch.
// By the window's preferredDisplayModeId: Surface.setFrameRate has no effect here, since Flutter, not the system's
// compositor, shows mpv's surface (Android's reference, "consumed by something other than the system compositor").
// Debugging a switch that doesn't come: `adb shell dumpsys display` lists the modes; only ones of the current
// resolution count.

typedef DisplayMode = ({int id, int width, int height, double rate});

const settingMatchFrameRate = 'match_frame_rate';

/// How far [rate] is from a whole multiple of [fps], relative to it; more than 1 % is judder.
double _off(double rate, double fps) {
  final times = (rate / fps).round();
  return times == 0 ? 1 : (rate / (times * fps) - 1).abs();
}

/// The mode to switch to for [fps], or null to stay: the closest multiple (59.94 rather than 60 for 29.97), and of
/// equally close ones the fastest, which keeps the interface smooth (50 Hz rather than 25 for 25 fps).
DisplayMode? displayModeFor(
  double fps,
  List<DisplayMode> modes,
  DisplayMode current,
) {
  if (fps < 10 || fps > 120) return null;
  final fitting = [
    for (final m in modes)
      if (m.width == current.width &&
          m.height == current.height &&
          _off(m.rate, fps) < 0.01)
        m,
  ];
  if (fitting.isEmpty) return null;
  fitting.sort((a, b) {
    final (x, y) = (_off(a.rate, fps), _off(b.rate, fps));
    // 0.05 % apart counts as equal: modes and streams are rounded (23.976, 59.94).
    return (x - y).abs() < 0.0005 ? b.rate.compareTo(a.rate) : x.compareTo(y);
  });
  final best = fitting.first;
  // Already as close: no black screen for nothing.
  final stays =
      _off(current.rate, fps) < 0.01 &&
      _off(current.rate, fps) - _off(best.rate, fps) < 0.0005;
  return stays ? null : best;
}
