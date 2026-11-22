// The guide grid's geometry, kept apart from the widgets so it is tested on its own: where a programme's cell starts
// and how wide it is inside the loaded window, the half-hour marks of the time ruler, and the days to pick from.
// Times are UTC seconds (as the core gives them); the ruler shows local time.

/// A programme cell inside the window [from, to): left edge and width in pixels at [pxPerMin], clipped to the
/// window; null when the programme lies outside it.
({double left, double width})? cellGeometry(
  int start,
  int stop,
  int from,
  int to,
  double pxPerMin,
) {
  final s = start < from ? from : start;
  final e = stop > to ? to : stop;
  if (e <= s) return null;
  return (left: (s - from) / 60 * pxPerMin, width: (e - s) / 60 * pxPerMin);
}

/// UTC seconds of the half hour at or before [t] (the ruler and "Now" start there).
int floorToHalfHour(DateTime t) {
  final secs = t.millisecondsSinceEpoch ~/ 1000;
  return secs - secs % 1800;
}

/// Local midnights from [back] days ago to [ahead] days ahead (the day picker; the guide keeps 2 back).
List<DateTime> guideDays(DateTime now, {int back = 2, required int ahead}) {
  final today = DateTime(now.year, now.month, now.day);
  return [
    for (var d = -back; d <= ahead; d++)
      DateTime(today.year, today.month, today.day + d),
  ];
}
