// Where "live" is while pausing and rewinding live TV (docs/SPEC.md, "Pause and rewind live"). mpv reports how far
// its cache reaches (`demuxer-cache-time`, stream seconds); at the live edge that is live. After the user pauses or
// seeks back, mpv reports the end of the cached range around the new position instead, so the edge is frozen at the
// last value seen live and moves on in real time (the stream keeps coming). Going back to live attaches it again.
// The same rule as the core's `behind_live`, checked there with real libmpv (gerdtv-testkit libmpv_watchdog.rs).
//
// Debugging a wrong "behind live" label: print cacheEnd and position per second; a cacheEnd that jumps back after a
// seek is normal, a frozen one while attached means mpv stopped reading (network).

/// Closer than this to live counts as live (mpv's cache end runs a little ahead of the position).
const liveSlack = 3.0;

class LiveEdge {
  double? _edge;
  DateTime _edgeAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _detached = false;

  /// The first position seen: the back buffer can't reach before the stream's start.
  double? start;

  /// mpv's cache end (seconds) at [now]; taken as live unless the user paused or seeked back.
  void cache(double cacheEnd, DateTime now) {
    if (_detached) return;
    _edge = cacheEnd;
    _edgeAt = now;
  }

  void position(double secs) => start ??= secs;

  /// The user paused or seeked back: from now on live moves on in real time.
  void detach() => _detached = true;

  /// Back at live (Go live, or played up to it).
  void attach() => _detached = false;

  bool get detached => _detached;

  /// Live in stream seconds at [now] (null until mpv reported its cache).
  double? live(DateTime now) {
    final e = _edge;
    if (e == null) return null;
    return _detached ? e + now.difference(_edgeAt).inMilliseconds / 1000 : e;
  }

  /// Whole seconds behind live at [position] (0 at the edge).
  int behind(double position, DateTime now) {
    final l = live(now);
    if (l == null) return 0;
    final b = l - position;
    return b < liveSlack ? 0 : b.round();
  }

  /// The earliest seekable moment: [windowSecs] back from live, not before the stream's start, never after live
  /// (a start recorded from the previous channel can lie after this stream's live).
  double earliest(int windowSecs, DateTime now) {
    final l = live(now) ?? 0;
    final from = l - windowSecs;
    final s = start ?? from;
    final e = from < s ? s : from;
    return e > l ? l : e;
  }
}

/// "−5:12" or "−1:02:03": how far behind live, for the player.
String behindLabel(int secs) {
  final h = secs ~/ 3600, m = secs % 3600 ~/ 60, s = secs % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  return h > 0 ? '−$h:${two(m)}:${two(s)}' : '−$m:${two(s)}';
}
