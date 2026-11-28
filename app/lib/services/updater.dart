// Updates (owner decision: check and tell by itself, fetch in the background, macOS installs on quit). One service
// for the update bar under the app (screens/update_bar.dart) and Settings → About → Updates (update_settings.dart),
// so both show the same state. The checks are the core's (gerdtv_core::update): a correctly signed manifest, a newer
// version, a build for this platform; a download is kept only when its size and SHA-256 match.
//
// Flow: [startAuto] checks 30 s after the start (not to compete with the start's own work) and every 12 h. Where gerdTV
// can install (macOS, Android) or at least keep the file (Linux), the file is fetched and verified right away, so
// Update is one tap. On macOS the verified bundle is armed (platform/mac_install.dart): a swap that waits for gerdTV
// to quit, however it quits, and installs then; "Install and restart" only tells that swap to start gerdTV again.
// iPhone/iPad can't install a downloaded app (the IPA is re-signed first): there the bar opens the IPA itself.
// Debugging: a failure is kept in [error] (Settings → Updates shows it); release builds only check by themselves.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../platform/mac_install.dart';
import '../platform/platform_bridge.dart';
import '../src/rust/api/update.dart';
import 'session.dart' show isDesktop;

/// The manifest's platform names.
String get updatePlatform => Platform.isMacOS
    ? 'macos'
    : Platform.isIOS
    ? 'ios'
    : Platform.isAndroid
    ? 'android'
    : 'linux';

class Updater {
  /// The newer release, once a check found one.
  final available = ValueNotifier<UpdateInfo?>(null);

  /// Its downloaded, verified file.
  final file = ValueNotifier<String?>(null);

  /// A check, download or install is running.
  final busy = ValueNotifier<bool>(false);

  /// The last failure (the core's reason), or null.
  final error = ValueNotifier<String?>(null);

  /// Whether a check finished (Settings says "up to date" only then).
  bool checked = false;

  /// macOS: the verified bundle waits for the quit to be installed.
  bool _armed = false;

  /// The version whose bar the user closed (this run; a newer one shows again).
  final dismissed = ValueNotifier<String?>(null);

  Timer? _timer;

  /// Where the file can be kept and used by gerdTV itself (not iPhone/iPad).
  static bool get canDownload => updatePlatform != 'ios';

  /// Release builds only: tests and development runs never reach the network by themselves.
  void startAuto() {
    if (!kReleaseMode || _timer != null) return;
    _timer = Timer.periodic(
      const Duration(hours: 12),
      (_) => unawaited(auto()),
    );
    Timer(const Duration(seconds: 30), () => unawaited(auto()));
  }

  /// One automatic round: check, and fetch (and on macOS arm) what was found. Failures stay in [error].
  Future<void> auto() async {
    await check();
    if (available.value != null && canDownload && file.value == null) {
      await download();
    }
    if (Platform.isMacOS && file.value != null && !_armed) {
      await _run(() async {
        final refused = await armMacUpdate(file.value!);
        if (refused != null) throw refused;
        _armed = true;
      });
    }
  }

  Future<void> _run(Future<void> Function() step) async {
    busy.value = true;
    error.value = null;
    try {
      await step();
    } catch (e) {
      error.value = '$e';
    } finally {
      busy.value = false;
    }
  }

  Future<void> check() => _run(() async {
    final u = await checkUpdate(platform: updatePlatform);
    // A newer release than the one already fetched: fetch again.
    if (u?.version != available.value?.version) {
      file.value = null;
      _armed = false;
    }
    available.value = u;
    checked = true;
  });

  Future<void> download() => _run(() async {
    final dir =
        (isDesktop ? await getDownloadsDirectory() : null) ??
        await getTemporaryDirectory();
    file.value = await downloadUpdate(update: available.value!, dir: dir.path);
  });

  /// macOS: install and restart (returns only on a refusal). Android: the system's installer asks to confirm.
  Future<void> install() => _run(() async {
    if (Platform.isMacOS) {
      final refused = await installMacUpdate(file.value!, armed: _armed);
      if (refused != null) throw refused;
    } else {
      await PlatformBridge.installApk(file.value!);
    }
  });

  /// Desktop: the folder with the download, in the system's file manager.
  void showFolder() {
    final folder = File(file.value!).parent.path;
    Process.run(Platform.isMacOS ? 'open' : 'xdg-open', [folder]);
  }
}
