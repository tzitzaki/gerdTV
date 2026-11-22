// The Licences screen lists more than the Dart packages Flutter registers itself: every Rust crate bundled in the
// core (assets/licences/rust.txt, written and checked by scripts/licences.sh) and the native libmpv/FFmpeg builds
// per platform (assets/licences/native.txt, by hand from docs/ARCHITECTURE.md "Native libraries").

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Adds the crates and native libraries to Flutter's LicenseRegistry (call once at start).
void registerBundledLicences() {
  LicenseRegistry.addLicense(() async* {
    // "## names" starts a native library's block; the lines after it are its notice.
    final native = await rootBundle.loadString('assets/licences/native.txt');
    for (final block
        in native.split('\n## ').where((b) => b.trim().isNotEmpty)) {
      final lines = block.replaceFirst('## ', '').trim().split('\n');
      yield LicenseEntryWithLineBreaks([
        lines.first,
      ], lines.skip(1).join('\n').trim());
    }
    // One "name version licence" line per crate (the licence is an SPDX expression and may have spaces).
    final rust = await rootBundle.loadString('assets/licences/rust.txt');
    for (final line in rust.split('\n').where((l) => l.trim().isNotEmpty)) {
      final parts = line.split(' ');
      yield LicenseEntryWithLineBreaks(
        [parts[0]],
        'Rust crate ${parts[0]} ${parts[1]}, bundled in the gerdTV core.\nLicence: ${parts.skip(2).join(' ')}',
      );
    }
  });
}
