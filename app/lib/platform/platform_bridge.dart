// The Dart end of the "gerdtv/platform" channel (Android: MainActivity.kt, iOS: AppDelegate.swift). Tells the platform
// whether something plays (background playback, Android Picture-in-Picture) and hears back when PiP starts or ends.
// iOS PiP is a hand-over to AVPlayer (startApplePip); when it ends, `onApplePipEnded` resumes mpv. setLogo switches
// the app icon (macOS: MainFlutterWindow.swift, Linux: my_application.cc). Android only: voice search through the
// system's speech recognizer (voiceAvailable, listen); iOS and macOS have dictation on their keyboards.
// openUrl opens a web page (Android, iOS; desktop runs the system's opener). Platforms without a native side ignore
// the calls.

import 'dart:io';

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

  /// Opens [url] in the browser (or the app registered for it); false when nothing can open it (e.g. a TV without a
  /// browser), so the caller can show the address instead. Desktop asks the system's opener, phones and TVs the
  /// platform channel (no url_launcher: one call isn't worth a dependency).
  static Future<bool> openUrl(String url) async {
    if (kIsWeb) return false;
    if (defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.linux) {
      final r = await Process.run(
        defaultTargetPlatform == TargetPlatform.macOS ? 'open' : 'xdg-open',
        [url],
      );
      return r.exitCode == 0;
    }
    try {
      return await channel.invokeMethod<bool>('openUrl', {'url': url}) ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Android: opens the system's package installer for the downloaded [apk] (the user confirms there).
  static Future<void> installApk(String apk) =>
      channel.invokeMethod('installApk', {'path': apk});

  /// Android: writes [text] as [name] into Downloads; returns where it went.
  static Future<String> saveToDownloads(String name, String text) async =>
      (await channel.invokeMethod<String>('saveToDownloads', {
        'name': name,
        'text': text,
      }))!;

  /// iOS: hands the stream to AVPlayer and starts Picture-in-Picture. False when PiP isn't available.
  Future<bool> startApplePip(String url) async {
    try {
      return await channel.invokeMethod<bool>('startPip', {'url': url}) ??
          false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Android: whether a speech recognizer is installed (the search field shows its mic only then). Asked once.
  late final Future<bool> voiceAvailable = _voiceAvailable();

  Future<bool> _voiceAvailable() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return false;
    try {
      return await channel.invokeMethod<bool>('voiceAvailable') ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Android: the system's speech recognizer with [prompt]; the words heard, or null (cancelled, nothing heard).
  Future<String?> listen(String prompt) async {
    try {
      final text = await channel.invokeMethod<String>('listen', {
        'prompt': prompt,
      });
      return text == null || text.trim().isEmpty ? null : text.trim();
    } on MissingPluginException {
      return null;
    }
  }
}
