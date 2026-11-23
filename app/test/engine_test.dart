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
    final found = ownLibmpv(
      executable: '/opt/gerdTV/gerdtv',
      exists: (p) => true,
    );
    expect(found, Platform.isLinux ? '/opt/gerdTV/lib/libgerdmpv.so' : isNull);
    expect(
      ownLibmpv(executable: '/opt/gerdTV/gerdtv', exists: (p) => false),
      isNull,
    );
  });
}
