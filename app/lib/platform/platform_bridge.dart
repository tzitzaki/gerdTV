// The Dart end of the "gerdtv/platform" channel (Android: MainActivity.kt). Tells the platform whether something plays
// (so it can keep playing in the background and offer Picture-in-Picture) and hears back when PiP starts or ends
// (the player then shows only the picture). Platforms without a native side ignore the calls.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class PlatformBridge {
  PlatformBridge({required this.pictureMode});

  static const channel = MethodChannel('gerdtv/platform');

  /// Set while the system's Picture-in-Picture window shows the app.
  final ValueNotifier<bool> pictureMode;

  /// Starts listening for native calls (call once at start-up).
  void attach() {
    channel.setMethodCallHandler((call) async {
      if (call.method == 'pictureMode') {
        pictureMode.value = call.arguments == true;
      }
    });
  }

  /// Something started (title) or stopped (null). Android keeps a foreground service alive while playing.
  Future<void> setPlaying(String? title) async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      await channel.invokeMethod('setPlaying', {
        'playing': title != null,
        'title': title ?? '',
      });
    } on MissingPluginException {
      // Tests and builds without the native side.
    }
  }
}
