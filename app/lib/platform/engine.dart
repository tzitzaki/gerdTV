// Settings → Player engine (owner decision): the libmpv media_kit loads by default (bundled on Android and Apple,
// the system's libmpv.so.2 on Linux) or gerdTV's own build (scripts/build-libmpv.sh: libgerdmpv.so). Chosen
// app-wide and applied at the next start: media_kit's Linux video plugin links libmpv itself, so the whole process
// has to load the own build. linux/runner/main.cc does that before Flutter starts: it restarts gerdTV once with
// lib/gerdmpv/ in LD_LIBRARY_PATH when the marker file below exists. The marker is the setting itself, so the
// C++ side can read it without parsing app.json.
// Debugging: GERDTV_ENGINE_SET=1 in the process environment means the own engine is loaded.

import 'dart:io';

enum PlayerEngine { standard, gerdtv }

/// The marker in the app's support folder (getApplicationSupportDirectory) that selects the own engine.
const engineMarker = 'player-engine-gerdtv';

/// gerdTV's own libmpv in this installation, or null where there is none (not built for this platform yet).
String? ownLibmpv({String? executable, bool Function(String path)? exists}) {
  if (!Platform.isLinux) return null;
  final path =
      '${File(executable ?? Platform.resolvedExecutable).parent.path}/lib/libgerdmpv.so';
  return (exists ?? (p) => File(p).existsSync())(path) ? path : null;
}

/// The chosen engine (the marker's presence in [supportDir]).
PlayerEngine readEngine(String supportDir) =>
    File('$supportDir/$engineMarker').existsSync()
    ? PlayerEngine.gerdtv
    : PlayerEngine.standard;

/// Stores the choice; it applies at the next start.
void writeEngine(String supportDir, PlayerEngine engine) {
  final marker = File('$supportDir/$engineMarker');
  if (engine == PlayerEngine.gerdtv) {
    marker.writeAsStringSync('');
  } else if (marker.existsSync()) {
    marker.deleteSync();
  }
}
