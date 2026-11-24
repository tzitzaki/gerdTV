// New, because nothing owned what the Licences screen lists beyond Flutter's own packages: the native libmpv/FFmpeg
// builds, gerdTV's own licence with its source, and every bundled Rust crate (the crate list itself is kept current by scripts/licences.sh).
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gerdtv/licences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'the Licences screen lists the native libraries and the Rust crates',
    () async {
      registerBundledLicences();
      final entries = await LicenseRegistry.licenses.toList();
      final packages = {for (final e in entries) ...e.packages};
      for (final want in [
        'gerdTV',
        'libmpv, FFmpeg (Android)',
        'libmpv, FFmpeg (macOS, iPhone, iPad)',
        'libmpv (Linux)',
        'tokio',
        'rusqlite',
      ]) {
        expect(packages, contains(want));
      }
      final tokio = entries.firstWhere((e) => e.packages.contains('tokio'));
      expect(tokio.paragraphs.map((p) => p.text).join(' '), contains('MIT'));
      // gerdTV's own licence and where its source is (GPL-3.0 asks for that).
      final own = entries.firstWhere((e) => e.packages.contains('gerdTV'));
      final text = own.paragraphs.map((p) => p.text).join(' ');
      expect(text, contains('GPL-3.0-only'));
      expect(text, contains('https://github.com/tzitzaki/gerdTV'));
    },
  );
}
