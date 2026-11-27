// The Dart end of the "gerdtv/platform" channel (Android: MainActivity.kt, iOS: AppDelegate.swift). Tells the platform
// whether something plays (background playback, Android Picture-in-Picture) and hears back when PiP starts or ends.
// iOS PiP of mpv shows mpv's own frames (preparePip, pipState, startApplePip); the floating window's buttons come back
// as `onPipCommand`. Live channels in AVPlayer have their own PiP (lib/player/av_player.dart). setLogo switches
// the app icon (macOS: MainFlutterWindow.swift, Linux: my_application.cc). Android only: voice search through the
// system's speech recognizer (voiceAvailable, listen); iOS and macOS have dictation on their keyboards.
// brightness/setBrightness/resetBrightness serve the player's left-half swipe; openUrl opens a web page (Android, iOS; desktop runs the system's opener). Platforms without a native side ignore
// the calls.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../player/frame_rate.dart';
import '../screens/app_logo.dart';

class PlatformBridge {
  PlatformBridge({required this.pictureMode});

  /// iOS: a button in the PiP window of mpv's picture: "play", "pause" or "skip" by [secs] (negative: back).
  void Function(String action, double secs)? onPipCommand;

  static const channel = MethodChannel('gerdtv/platform');

  /// macOS menu bar: its menu's "toggle" (play/pause) or "stop" (platform/menu_bar.dart).
  void Function(String action)? onMenuBar;

  /// iOS: set while the PiP window shows mpv's picture; [onPipRestore]: its restore button.
  final ValueNotifier<bool> pip = ValueNotifier(false);
  void Function()? onPipRestore;

  /// Android and iOS: play/pause on the Now Playing card or a headset ("play" or "pause").
  void Function(String action)? onMediaCommand;

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
      } else if (call.method == 'pip') {
        pip.value = call.arguments == true;
      } else if (call.method == 'pipRestore') {
        onPipRestore?.call();
      } else if (call.method == 'openItem') {
        final m = call.arguments as Map;
        onOpenItem?.call(m['profile'] as String, m['key'] as String);
      } else if (call.method == 'pairLink') {
        onPairLink?.call(call.arguments as String);
      } else if (call.method == 'mediaCommand') {
        onMediaCommand?.call(call.arguments as String);
      } else if (call.method == 'menuBar') {
        onMenuBar?.call(call.arguments as String);
      }
    });
  }

  /// Android, iOS and macOS: the Now Playing card (lib/services/media_card.dart). [artwork] is a local file; seconds.
  Future<void> nowPlaying({
    required String title,
    required String subtitle,
    required String? artwork,
    required bool playing,
    required double position,
    required double duration,
    required bool live,
  }) => _mobile('nowPlaying', {
    'title': title,
    'subtitle': subtitle,
    'artwork': artwork,
    'playing': playing,
    'position': position,
    'duration': duration,
    'live': live,
  }, mac: true);

  /// An entry of the Android TV home screen was picked while gerdTV runs (services/tv_home.dart).
  static void Function(String profile, String key)? onOpenItem;

  /// A gerdtv://pair link arrived while gerdTV runs (Android, iOS: the camera scanned a pairing QR).
  static void Function(String link)? onPairLink;

  /// The gerdtv://pair link that started gerdTV, once (Android, iOS); null without one.
  static Future<String?> takePairLink() async {
    if (kIsWeb ||
        !(defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS)) {
      return null;
    }
    try {
      return await channel.invokeMethod<String>('takePairLink');
    } on MissingPluginException {
      return null;
    }
  }

  static Future<T?> _android<T>(String method, [Object? args]) async {
    if (defaultTargetPlatform != TargetPlatform.android) return null;
    try {
      return await channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      return null;
    }
  }

  /// Android: keeps the background service while a recording runs ([title]; null: none runs).
  static Future<void> setRecording(String? title) =>
      _android<void>('setRecording', {'title': title});

  /// Android: the system's folder picker; the folder's tree URI, "" when cancelled, null without a picker.
  static Future<String?> pickFolder() => _android<String>('pickFolder');

  /// Android: a new file in a picked folder: its descriptor (handed to the core) and content URI.
  static Future<({int fd, String uri})> createDocument(
    String tree,
    String name,
  ) async {
    final m = await channel.invokeMapMethod<String, Object?>('createDocument', {
      'tree': tree,
      'name': name,
    });
    return (fd: m!['fd']! as int, uri: m['uri']! as String);
  }

  static Future<bool> deleteDocument(String uri) async =>
      await _android<bool>('deleteDocument', {'uri': uri}) ?? false;

  /// Android: the app's own folder on each mounted drive (for TVs without a folder picker).
  static Future<List<String>> appFolders() async =>
      (await _android<List<Object?>>('appFolders'))?.cast<String>() ?? const [];

  static Future<bool> isTv() async => await _android<bool>('isTv') ?? false;

  /// The home screen entry that started gerdTV, once.
  static Future<({String profile, String key})?> takeOpenItem() async {
    final m = await _android<Map<Object?, Object?>>('takeOpenItem');
    return m == null
        ? null
        : (profile: m['profile']! as String, key: m['key']! as String);
  }

  static Future<void> updateTvHome({
    required String profile,
    required List<Map<String, Object?>> resume,
    required List<Map<String, Object?>> channels,
  }) => _android<void>('tvHome', {
    'profile': profile,
    'resume': resume,
    'channels': channels,
  });

  /// Android TV: the display's modes, the current one first; empty elsewhere.
  static Future<List<DisplayMode>> displayModes() async {
    if (defaultTargetPlatform != TargetPlatform.android) return const [];
    try {
      final modes = await channel.invokeListMethod<Map<Object?, Object?>>(
        'displayModes',
      );
      return [
        for (final m in modes ?? const <Map<Object?, Object?>>[])
          (
            id: m['id']! as int,
            width: m['width']! as int,
            height: m['height']! as int,
            rate: m['rate']! as double,
          ),
      ];
    } on MissingPluginException {
      return const [];
    }
  }

  /// Android TV: asks for a display mode; 0 is the system's own choice.
  Future<void> setDisplayMode(int id) => _mobile('setDisplayMode', {'id': id});

  /// Stop: the card goes.
  Future<void> clearNowPlaying() =>
      _mobile('clearNowPlaying', const {}, mac: true);

  Future<void> _mobile(
    String method,
    Map<String, Object?> args, {
    bool mac = false,
  }) async {
    if (kIsWeb ||
        !(defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS ||
            (mac && defaultTargetPlatform == TargetPlatform.macOS))) {
      return;
    }
    try {
      await channel.invokeMethod(method, args);
    } on MissingPluginException {
      // Tests and builds without the native side.
    }
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

  /// Phones and tablets: the screen's brightness for the player's swipe (0–1), null where there is none.
  /// Android sets only gerdTV's window (the system setting stays); iOS sets the screen's and puts the old value back on
  /// [resetBrightness] and when the app leaves the foreground, since iOS keeps it otherwise.
  static Future<double?> brightness() => _brightness('brightness');
  static Future<void> setBrightness(double value) =>
      _brightness('setBrightness', value);
  static Future<void> resetBrightness() => _brightness('resetBrightness');

  static Future<double?> _brightness(String method, [double? value]) async {
    if (kIsWeb ||
        !(defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS)) {
      return null;
    }
    try {
      return await channel.invokeMethod<double>(method, {'value': ?value});
    } on MissingPluginException {
      return null;
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

  /// iOS: closes the PiP window of mpv's picture.
  Future<void> stopApplePip() => _ios('stopPip', const {});

  /// iOS: mpv plays (true) or stopped or handed over to AVPlayer (false). While true, mpv's frames feed the PiP
  /// layer and swiping to Home floats the picture by itself.
  Future<void> preparePip(bool on) => _ios('preparePip', {'on': on});

  /// Android and iOS: leaving the app floats the picture (lib/player/floating.dart). Off never closes an open window.
  Future<void> setFloating(bool on) async {
    if (kIsWeb ||
        !(defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS)) {
      return;
    }
    try {
      await channel.invokeMethod('setFloating', {'on': on});
    } on MissingPluginException {
      // Tests and builds without the native side.
    }
  }

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
