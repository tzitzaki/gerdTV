// Settings → Player engine (owner decision): the libmpv media_kit loads by default (bundled on Android and Apple,
// the system's libmpv.so.2 on Linux) or gerdTV's own build (libgerdmpv: scripts/build-libmpv.sh for Linux,
// scripts/build-libmpv-android.sh for Android). Chosen app-wide and applied at the next start.
// - Linux: media_kit's video plugin links libmpv itself, so the whole process has to load the own build.
//   linux/runner/main.cc does that before Flutter starts: it restarts gerdTV once with lib/gerdmpv/ in
//   LD_LIBRARY_PATH when the marker file below exists. The marker is the setting itself, so the C++ side can read it
//   without parsing app.json. GERDTV_ENGINE_SET=1 in the process environment means the own engine is loaded.
// - Android: the video plugin only hands media_kit a surface, so the app picks the library itself ([startEngine]):
//   media_kit opens libgerdmpv.so instead of its libmpv.so, and FFmpeg inside it gets the JavaVM for MediaCodec.
//   Builds that bundle it are made with --dart-define=GERDTV_OWN_LIBMPV=true (CI and release.yml).
// - macOS, iOS: gerdTV's GerdMpv.framework sits in the app's Frameworks folder, copied in but not linked
//   (scripts/embed-libmpv-apple.sh); media_kit is told to open it, and GERDTV_LIBMPV tells the vendored video plugin
//   which library to call (third_party/README.md).
// Debugging (Android): "mpv: … mediacodec … no JavaVM" in logcat means av_jni_set_java_vm wasn't reached.
// Debugging (Apple): "MPV: …" lines in the system log come from the video plugin's lookup.

import 'dart:ffi';
import 'dart:io';

import 'package:media_kit/media_kit.dart';

enum PlayerEngine { standard, gerdtv }

/// The marker in the app's support folder (getApplicationSupportDirectory) that selects the own engine.
const engineMarker = 'player-engine-gerdtv';

/// Whether this build bundles gerdTV's own libmpv where the app can't look for the file (Android: libraries load by
/// name from the APK).
const bundledOwnLibmpv = bool.fromEnvironment('GERDTV_OWN_LIBMPV');

/// gerdTV's own libmpv in this installation (a path, or on Android the library's name), or null where there is none.
String? ownLibmpv({
  String? executable,
  bool Function(String path)? exists,
  String? os,
}) {
  os ??= Platform.operatingSystem;
  if (os == 'android') return bundledOwnLibmpv ? 'libgerdmpv.so' : null;
  if (os == 'macos' || os == 'ios') {
    // The executable is in gerdTV.app/Contents/MacOS (macOS) or Runner.app (iOS); frameworks beside it.
    final dir = File(executable ?? Platform.resolvedExecutable).parent.path;
    final frameworks = os == 'macos' ? '$dir/../Frameworks' : '$dir/Frameworks';
    final found = (exists ?? (p) => Directory(p).existsSync())(
      '$frameworks/GerdMpv.framework',
    );
    return found ? 'GerdMpv.framework/GerdMpv' : null;
  }
  if (os != 'linux') return null;
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

/// Settings → Playback → Live channels play in (iPhone, iPad, Mac; owner decision): gerdTV's player (mpv, the
/// default: every format, the PiP from its own frames, no hand-over) or Apple's AVPlayer over the core's local HLS.
/// App-wide like the engine, a marker file in the support folder, read once at start (Session), so a change applies
/// after closing and reopening gerdTV.
enum LivePlayer { gerdtv, apple }

const livePlayerMarker = 'live-player-apple';

LivePlayer readLivePlayer(String supportDir) =>
    File('$supportDir/$livePlayerMarker').existsSync()
    ? LivePlayer.apple
    : LivePlayer.gerdtv;

void writeLivePlayer(String supportDir, LivePlayer player) {
  final marker = File('$supportDir/$livePlayerMarker');
  if (player == LivePlayer.apple) {
    marker.writeAsStringSync('');
  } else if (marker.existsSync()) {
    marker.deleteSync();
  }
}

/// Starts media_kit with the chosen engine. On Linux the runner already chose (see above); on Android and Apple
/// media_kit is told which library to open. Android: FFmpeg inside the own build gets the JavaVM that media_kit's
/// helper holds (media_kit only hands it to its own libmpv). Apple: the video plugin learns the library from
/// GERDTV_LIBMPV.
void startEngine(String supportDir) {
  final own = ownLibmpv();
  if (Platform.isLinux ||
      own == null ||
      readEngine(supportDir) != PlayerEngine.gerdtv) {
    MediaKit.ensureInitialized();
    return;
  }
  if (Platform.isMacOS || Platform.isIOS) {
    final setenv = DynamicLibrary.process()
        .lookupFunction<
          Int32 Function(Pointer<Uint8>, Pointer<Uint8>, Int32),
          int Function(Pointer<Uint8>, Pointer<Uint8>, int)
        >('setenv');
    setenv(_cString('GERDTV_LIBMPV'), _cString(own), 1);
    MediaKit.ensureInitialized(libmpv: own);
    return;
  }
  MediaKit.ensureInitialized(libmpv: own);
  final helper = DynamicLibrary.open('libmediakitandroidhelper.so');
  final vm = helper
      .lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>(
        'MediaKitAndroidHelperGetJavaVM',
      )();
  DynamicLibrary.open(own).lookupFunction<
    Int32 Function(Pointer<Void>, Pointer<Void>),
    int Function(Pointer<Void>, Pointer<Void>)
  >('av_jni_set_java_vm')(vm, nullptr);
}

/// [s] as a NUL-terminated C string from libc's malloc (ASCII only; never freed: setenv copies it, and it is two small
/// strings once per process).
Pointer<Uint8> _cString(String s) {
  final malloc = DynamicLibrary.process()
      .lookupFunction<
        Pointer<Uint8> Function(IntPtr),
        Pointer<Uint8> Function(int)
      >('malloc');
  final p = malloc(s.length + 1);
  for (var i = 0; i < s.length; i++) {
    p[i] = s.codeUnitAt(i);
  }
  p[s.length] = 0;
  return p;
}
