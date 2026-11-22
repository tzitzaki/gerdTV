// The Dart end of the "gerdtv/platform" channel (Android: MainActivity.kt, iOS: AppDelegate.swift). Tells the platform
// whether something plays (background playback, Android Picture-in-Picture) and hears back when PiP starts or ends.
// iOS PiP is a hand-over to AVPlayer (startApplePip); when it ends, `onApplePipEnded` resumes mpv.
// Platforms without a native side ignore the calls.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

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
    if (kIsWeb || !(Platform.isAndroid || Platform.isIOS)) return;
    try {
      await channel.invokeMethod('setPlaying', {
        'playing': title != null,
        'title': title ?? '',
      });
    } on MissingPluginException {
      // Tests and builds without the native side.
    }
  }

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
