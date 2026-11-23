// New, because nothing owned the export's file name: it must be a safe file name on every platform whatever the
// profile is called (the merge rules themselves are the core's, gerdtv_core::userdata).
import 'package:flutter_test/flutter_test.dart';
import 'package:gerdtv/screens/user_data_settings.dart';

void main() {
  test('export file name', () {
    final day = DateTime(2026, 11, 23, 23, 59);
    for (final (profile, want) in [
      ('Home', 'gerdtv-home-2026-11-23.json'),
      ('Wohnzimmer / Ü-TV ', 'gerdtv-wohnzimmer-tv-2026-11-23.json'),
      ('***', 'gerdtv-profile-2026-11-23.json'),
    ]) {
      expect(userDataFileName(profile, day), want, reason: profile);
    }
  });
}
