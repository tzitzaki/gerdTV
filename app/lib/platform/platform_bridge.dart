// The Dart end of the "gerdtv/platform" channel (Android: MainActivity.kt, iOS: AppDelegate.swift). Tells the platform
// whether something plays (background playback, Android Picture-in-Picture) and hears back when PiP starts or ends.
// iOS PiP of mpv shows mpv's own frames (preparePip, pipState, startApplePip); the floating window's buttons come back
// as `onPipCommand`. Live channels in AVPlayer have their own PiP (lib/player/av_player.dart). setLogo switches
// the app icon (macOS: MainFlutterWindow.swift, Linux: my_application.cc). Android only: voice search through the
// system's speech recognizer (voiceAvailable, listen); iOS and macOS have dictation on their keyboards.
// Platforms without a native side ignore the calls.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../screens/app_logo.dart';

class PlatformBridge {
  PlatformBridge({required this.pictureMode});

  /// iOS: a button in the PiP window of mpv's picture: "play", "pause" or "skip" by [secs] (negative: back).
  void Function(String action, double secs)? onPipCommand;

  static const channel = MethodChannel('gerdtv/platform');

  /// Set while the system's Picture-in-Picture window shows the app.
  final ValueNotifier<bool> pictureMode;

  /// Starts listening for native calls (call once at start-up).
  void attach() {
    channel.setMethodCallHandler((call) async {
      if (call.method == 'pictureMode') {
        pictureMode.value = call.arguments == true;
      } else if (call.method == 'pipCommand') {
        final m = call.arguments as Map;
        onPipCommand?.call(
          m['action'] as String,
          (m['secs'] as num?)?.toDouble() ?? 0,
        );
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

  /// Android: writes [text] as [name] into Downloads; returns where it went.
  static Future<String> saveToDownloads(String name, String text) async =>
      (await channel.invokeMethod<String>('saveToDownloads', {
        'name': name,
        'text': text,
      }))!;

  /// iOS: starts Picture-in-Picture of mpv's picture. False when PiP isn't possible right now.
  Future<bool> startApplePip() async {
    try {
      return await channel.invokeMethod<bool>('startPip') ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  /// iOS: mpv plays (true) or stopped or handed over to AVPlayer (false). While true, mpv's frames feed the PiP
  /// layer and swiping to Home floats the picture by itself.
  Future<void> preparePip(bool on) => _ios('preparePip', {'on': on});

  /// iOS: what the PiP window shows (play/pause button, the seek range; live has none).
  Future<void> pipState({
    required bool playing,
    required double position,
    required double duration,
    required bool live,
  }) => _ios('pipState', {
    'playing': playing,
    'position': position,
    'duration': duration,
    'live': live,
  });

  Future<void> _ios(String method, Map<String, Object> args) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return;
    try {
      await channel.invokeMethod(method, args);
    } on MissingPluginException {
      // Tests and builds without the native side.
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
