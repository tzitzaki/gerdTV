// New, because nothing owned the engine choice: which libmpv media_kit is asked to load at start.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gerdtv/platform/engine.dart';

void main() {
  test('engine choice → library', () {
    expect(parsePlayerEngine(null), PlayerEngine.standard);
    expect(parsePlayerEngine('junk'), PlayerEngine.standard);
    expect(parsePlayerEngine('gerdtv'), PlayerEngine.gerdtv);
    const own = '/opt/gerdTV/lib/libgerdmpv.so';
    expect(libmpvFor(PlayerEngine.gerdtv, own), own);
    expect(libmpvFor(PlayerEngine.standard, own), isNull);
    // Chosen but not installed (e.g. a build without it): media_kit's default instead of a failed start.
    expect(libmpvFor(PlayerEngine.gerdtv, null), isNull);
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
