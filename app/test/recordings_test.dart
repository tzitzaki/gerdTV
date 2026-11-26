// New, because nothing owns the recordings' rules on the app side: file names every file system takes, and when a
// start needs the connection something else holds.
import 'package:flutter_test/flutter_test.dart';
import 'package:gerdtv/screens/recordings_screen.dart' show sizeLabel;
import 'package:gerdtv/services/recordings.dart';

void main() {
  test('file names lose what file systems refuse', () {
    final at = DateTime(2026, 11, 26, 20, 5);
    for (final (title, want) in [
      ('Tagesschau', 'Tagesschau 2026-11-26 20.05.ts'),
      ('AC/DC: Live?', 'AC DC  Live 2026-11-26 20.05.ts'),
      ('  ', 'gerdTV 2026-11-26 20.05.ts'),
    ]) {
      expect(recordingFileName(title, at), want, reason: title);
    }
  });

  test('a start needs the connection only when the account is full', () {
    for (final (limit, running, playing, want) in [
      (1, 0, true, true), // watching takes the one connection
      (1, 0, false, false),
      (2, 0, true, false),
      (2, 1, true, true),
      (null, 3, true, false), // M3U without a known limit: no check
    ]) {
      expect(
        needsConnection(limit: limit, running: running, playing: playing),
        want,
        reason: '$limit $running $playing',
      );
    }
    expect((sizeLabel(350000000), sizeLabel(1400000000)), ('350 MB', '1.4 GB'));
  });
}
