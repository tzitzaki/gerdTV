// Settings → Player engine (owner decision): the libmpv media_kit loads by default (bundled on Android and Apple,
// the system's libmpv.so.2 on Linux) or gerdTV's own build (scripts/build-libmpv.sh: libgerdmpv.so). Chosen
// app-wide (app.json) and applied at the next start: libmpv is loaded once per process.
// Debugging: the log line "player engine: …" at start says which library was asked for; media_kit also honours
// LIBMPV_LIBRARY_PATH when the default engine is chosen (the integration tests run the own build that way).

import 'dart:io';

enum PlayerEngine { standard, gerdtv }

/// The app-wide setting that stores the engine.
const settingPlayerEngine = 'player_engine';

PlayerEngine parsePlayerEngine(String? value) =>
    value == PlayerEngine.gerdtv.name
    ? PlayerEngine.gerdtv
    : PlayerEngine.standard;

/// gerdTV's own libmpv in this installation, or null where there is none (not built for this platform yet).
String? ownLibmpv({String? executable, bool Function(String path)? exists}) {
  if (!Platform.isLinux) return null;
  final path =
      '${File(executable ?? Platform.resolvedExecutable).parent.path}/lib/libgerdmpv.so';
  return (exists ?? (p) => File(p).existsSync())(path) ? path : null;
}

/// What MediaKit.ensureInitialized gets: the own build when chosen and present, else null (media_kit's default).
String? libmpvFor(PlayerEngine engine, String? own) =>
    engine == PlayerEngine.gerdtv ? own : null;
