// The Dart end of the "gerdtv/platform" channel (Android: MainActivity.kt, iOS: AppDelegate.swift). Tells the platform
// whether something plays (background playback, Android Picture-in-Picture) and hears back when PiP starts or ends.
// iOS PiP is a hand-over to AVPlayer (startApplePip); when it ends, `onApplePipEnded` resumes mpv. setLogo switches
// the app icon (macOS: MainFlutterWindow.swift, Linux: my_application.cc).
// Platforms without a native side ignore the calls.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../screens/app_logo.dart';

class PlatformBridge {
  PlatformBridge({required this.pictureMode});

  /// iOS: Apple's Picture-in-Picture ended (or AVPlayer couldn't play the stream: failed = true).
  void Function(bool failed)? onApplePipEnded;

  static const channel = MethodChannel('gerdtv/platform');

  /// Set while the system's Picture-in-Picture window shows the app.
  final ValueNotifier<bool> pictureMode;

  /// Starts listening for native calls (call once at start-up).
  void attach() {
    channel.setMethodCallHandler((call) async {
      if (call.method == 'pictureMode') {
        pictureMode.value = call.arguments == true;
      } else if (call.method == 'pipEnded') {
        onApplePipEnded?.call((call.arguments as Map?)?['failed'] == true);
      }
    });
  }

  /// Something started (title) or stopped (null). Android keeps a foreground service alive while playing.
  Future<void> setPlaying(String? title) async {
    // The target platform (not dart:io's): tests can stand in for Android.
    if (kIsWeb ||
        !(defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS)) {
      return;
    }
    try {
      await channel.invokeMethod('setPlaying', {
        'playing': title != null,
        'title': title ?? '',
      });
    } on MissingPluginException {
      // Tests and builds without the native side.
    }
  }

  /// Switches the app icon to [logo]. Android enables the logo's launcher activity alias, iOS sets the alternate
  /// icon (the system says so in an alert); both last. macOS (Dock) and Linux (window) get a PNG for this run only.
  Future<void> setLogo(AppLogo logo) async {
    if (kIsWeb) return;
    final args = <String, Object>{'name': logo.name};
    if (defaultTargetPlatform == TargetPlatform.macOS) {
      // The margin macOS icons keep.
      args['png'] = await renderLogoPng(logo, 512, inset: 0.1);
    } else if (defaultTargetPlatform == TargetPlatform.linux) {
      args['png'] = await renderLogoPng(logo, 256);
    }
    try {
      await channel.invokeMethod('setLogo', args);
    } on MissingPluginException {
      // Tests and builds without the native side.
    }
  }

  /// Android: opens the system's package installer for the downloaded [apk] (the user confirms there).
  static Future<void> installApk(String apk) =>
      channel.invokeMethod('installApk', {'path': apk});

  /// iOS: hands the stream to AVPlayer and starts Picture-in-Picture. False when PiP isn't available.
  Future<bool> startApplePip(String url) async {
    try {
      return await channel.invokeMethod<bool>('startPip', {'url': url}) ??
          false;
    } on MissingPluginException {
      return false;
    }
  }
}
