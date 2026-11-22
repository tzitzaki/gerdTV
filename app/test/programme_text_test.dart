// New, because nothing owns how programme times read: running, later today, another day (24 h clock).
import 'package:flutter_test/flutter_test.dart';
import 'package:gerdtv/l10n/gen/app_localizations_en.dart';
import 'package:gerdtv/screens/programme_text.dart';
import 'package:gerdtv/src/rust/api/library.dart';
import 'package:intl/date_symbol_data_local.dart';

ProgrammeInfo at(DateTime start, Duration length) => ProgrammeInfo(
  id: 1,
  channel: 'c',
  start: start.millisecondsSinceEpoch ~/ 1000,
  stop: start.add(length).millisecondsSinceEpoch ~/ 1000,
  title: 't',
  subTitle: '',
  desc: '',
  category: '',
  episode: '',
);

void main() {
  setUpAll(() => initializeDateFormatting('en'));

  test('programme times read as now, today or with the weekday', () {
    final l10n = AppLocalizationsEn();
    // A Saturday evening in local time.
    final now = DateTime(2026, 11, 21, 20, 30);
    final cases = {
      at(DateTime(2026, 11, 21, 20, 15), const Duration(minutes: 45)):
          'Now · 20:15–21:00',
      at(DateTime(2026, 11, 21, 22, 0), const Duration(hours: 1)):
          '22:00–23:00',
      at(DateTime(2026, 11, 22, 9, 5), const Duration(minutes: 25)):
          'Sun 09:05–09:30',
      at(DateTime(2026, 11, 20, 20, 15), const Duration(minutes: 15)):
          'Fri 20:15–20:30',
    };
    cases.forEach((p, want) {
      expect(programmeWhen(l10n, 'en', p, now: now), want);
    });
  });
}
