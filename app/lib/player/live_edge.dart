// Where "live" is while pausing and rewinding live TV (docs/SPEC.md, "Pause and rewind live"). mpv reports how far
// its cache reaches (`demuxer-cache-time`, stream seconds); at the live edge that is live. After the user pauses or
// seeks back, mpv reports the end of the cached range around the new position instead, so the edge is frozen at the
// last value seen live and moves on in real time (the stream keeps coming). Going back to live attaches it again.
// The same rule as the core's `behind_live`, checked there with real libmpv (gerdtv-testkit libmpv_watchdog.rs).
//
// Debugging a wrong "behind live" label: print cacheEnd and position per second; a cacheEnd that jumps back after a
// seek is normal, a frozen one while attached means mpv stopped reading (network).

import 'dart:math' as math;

/// Closer than this to live always counts as live (mpv's cache end runs a little ahead of the position).
const liveSlack = 3.0;

/// How far behind the cache's end "Live" lands with a buffer whose `cache-pause-wait` is [pauseWait] seconds: twice
/// that and a second. Right after the seek mpv may pause for cache until it holds [pauseWait] seconds more; the live
/// stream only arrives in real time, so landing closer froze the picture for about [pauseWait] seconds (the
/// journey's flaky "keeps playing" step: mpv paused for cache at 2.5 s behind the edge with Fast zap's 2 s).
double goLiveMargin(int pauseWait) => pauseWait * 2 + 1.0;

/// Up to this far behind still counts as live: always [liveSlack], and beyond where Live lands for the buffer.
double liveSlackFor(int pauseWait) =>
    math.max(liveSlack, goLiveMargin(pauseWait) + 1);

class LiveEdge {
  /// [seekableEndIsLive]: AVPlayer's buffer end is its playlist's seekable end, the live edge even while paused or
  /// rewound (and a segment or two behind the clock, so extrapolating from a frozen value would run ahead of it).
  LiveEdge({this.seekableEndIsLive = false});

  final bool seekableEndIsLive;
  double? _edge;
  DateTime _edgeAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _detached = false;

  /// The smallest position seen: the back buffer can't reach before the stream's start. Not simply the first: right
  /// after zapping that can be a late event of the previous channel.
  double? start;

  /// mpv's cache end (seconds) at [now]; taken as live unless the user paused or seeked back.
  void cache(double cacheEnd, DateTime now) {
    if (_detached && !seekableEndIsLive) return;
    _edge = cacheEnd;
    _edgeAt = now;
  }

  void position(double secs) => start = math.min(start ?? secs, secs);

  /// The user paused or seeked back: from now on live moves on in real time.
  void detach() => _detached = true;

  /// Back at live (Go live, or played up to it).
  void attach() => _detached = false;

  /// Where a seek to [target] goes (inside the last [windowSecs], never past live); null until live is known.
  /// Off live when that is [slack] or more behind it, except for Live itself ([toLive]): it lands short of what is
  /// cached, and on a slow connection that lags the projected edge by more than the slack, so it would stay "behind
  /// live" for good. Attached, the next cache end mpv reports is live again.
  double? seek(
    double target,
    DateTime now, {
    required int windowSecs,
    required double slack,
    bool toLive = false,
  }) {
    final l = live(now);
    if (l == null) return null;
    final to = target.clamp(earliest(windowSecs, now), l);
    toLive || l - to < slack ? attach() : detach();
    return to;
  }

  bool get detached => _detached;

  /// Live in stream seconds at [now] (null until mpv reported its cache).
  double? live(DateTime now) {
    final e = _edge;
    if (e == null) return null;
    return _detached && !seekableEndIsLive
        ? e + now.difference(_edgeAt).inMilliseconds / 1000
        : e;
  }

  /// Whole seconds behind live at [position] (0 within [slack] of the edge, liveSlackFor the buffer).
  int behind(double position, DateTime now, {double slack = liveSlack}) {
    final l = live(now);
    if (l == null) return 0;
    final b = l - position;
    return b < slack ? 0 : b.round();
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
