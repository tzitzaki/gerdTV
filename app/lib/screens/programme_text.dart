// How a programme's time reads everywhere (search, lists, grid, mini-guide): "Now · 20:15–21:00" while it runs,
// "20:15–21:00" later today, "Sat 20:15–21:00" on other days. 24 h clock in the device's time zone.

import 'package:intl/intl.dart';

import '../l10n/gen/app_localizations.dart';
import '../src/rust/api/library.dart';

String programmeWhen(
  AppLocalizations l10n,
  String locale,
  ProgrammeInfo p, {
  DateTime? now,
}) {
  final at = now ?? DateTime.now();
  DateTime local(int secs) =>
      DateTime.fromMillisecondsSinceEpoch(secs * 1000).toLocal();
  final start = local(p.start);
  final hm = DateFormat.Hm(locale);
  final span = '${hm.format(start)}–${hm.format(local(p.stop))}';
  final nowSecs = at.millisecondsSinceEpoch ~/ 1000;
  if (p.start <= nowSecs && nowSecs < p.stop) {
    return '${l10n.programmeNow} · $span';
  }
  final sameDay =
      start.year == at.year && start.month == at.month && start.day == at.day;
  return sameDay ? span : '${DateFormat.E(locale).format(start)} $span';
}
