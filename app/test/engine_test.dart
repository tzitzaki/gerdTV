// New, because nothing owned the engine choice: the marker the Linux runner reads before Flutter starts, and where
// the own build is looked for.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gerdtv/platform/engine.dart';

void main() {
  test('the choice is the marker file', () {
    final dir = Directory.systemTemp.createTempSync('engine').path;
    expect(readEngine(dir), PlayerEngine.standard);
    writeEngine(dir, PlayerEngine.gerdtv);
    expect(
      File('$dir/$engineMarker').existsSync(),
      isTrue,
      reason: 'linux/runner/main.cc looks for this name',
    );
    expect(readEngine(dir), PlayerEngine.gerdtv);
    writeEngine(dir, PlayerEngine.standard);
    expect(readEngine(dir), PlayerEngine.standard);
    writeEngine(dir, PlayerEngine.standard); // no marker to delete: no error
  });

  test('own build is looked for next to the executable', () {
    // (os, executable, the path that must exist, what is offered)
    for (final (os, exe, path, want) in [
      (
        'linux',
        '/opt/gerdTV/gerdtv',
        '/opt/gerdTV/lib/libgerdmpv.so',
        '/opt/gerdTV/lib/libgerdmpv.so',
      ),
      (
        'macos',
        '/Applications/gerdTV.app/Contents/MacOS/gerdTV',
        '/Applications/gerdTV.app/Contents/MacOS/../Frameworks/GerdMpv.framework',
        'GerdMpv.framework/GerdMpv',
      ),
      (
        'ios',
        '/x/Runner.app/Runner',
        '/x/Runner.app/Frameworks/GerdMpv.framework',
        'GerdMpv.framework/GerdMpv',
      ),
      ('android', '/x', '', null), // only builds made with GERDTV_OWN_LIBMPV
      ('windows', 'C:/gerdTV/gerdtv.exe', '', null),
    ]) {
      expect(
        ownLibmpv(executable: exe, exists: (p) => p == path, os: os),
        want,
        reason: os,
      );
      expect(
        ownLibmpv(executable: exe, exists: (p) => false, os: os),
        os == 'android' ? want : isNull,
        reason: '$os without the library',
      );
    }
  });
}
