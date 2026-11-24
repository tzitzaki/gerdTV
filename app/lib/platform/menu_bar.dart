// macOS menu bar mode (owner request): with it on, closing the window or quitting from the Dock hides gerdTV into
// the menu bar and playback goes on; the menu bar item opens it again, pauses or plays, stops, or quits for real.
// The native side is MenuBar in macos/Runner/MainFlutterWindow.swift; this file holds the setting (app-wide, on by
// default) and the labels, which Dart translates.
// Debugging: no menu bar item on macOS means setMenuBar never arrived; MissingPluginException is swallowed only in
// tests and on other platforms.

import 'dart:ui' show Locale, PlatformDispatcher;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../l10n/gen/app_localizations.dart';
import 'platform_bridge.dart';

/// The app-wide setting: "off" turns the mode off; anything else (or nothing) is on.
const settingMenuBar = 'menu_bar';

/// Whether the mode is on for this stored value.
bool menuBarOn(String? stored) => stored != 'off';

/// The labels of the menu bar's menu, in the system's language (English when gerdTV doesn't have it).
Map<String, String> menuBarLabels(AppLocalizations l10n) => {
  'open': l10n.menuBarOpen,
  'toggle': l10n.menuBarPlayPause,
  'stop': l10n.stop,
  'quit': l10n.menuBarQuit,
};

AppLocalizations _systemL10n() {
  for (final locale in PlatformDispatcher.instance.locales) {
    if (AppLocalizations.supportedLocales.any(
      (s) => s.languageCode == locale.languageCode,
    )) {
      return lookupAppLocalizations(Locale(locale.languageCode));
    }
  }
  return lookupAppLocalizations(const Locale('en'));
}

/// Tells macOS whether the mode is on (call at start and when the setting changes); elsewhere nothing happens.
Future<void> applyMenuBar(bool on) async {
  if (defaultTargetPlatform != TargetPlatform.macOS) return;
  try {
    await PlatformBridge.channel.invokeMethod('setMenuBar', {
      'enabled': on,
      'labels': menuBarLabels(_systemL10n()),
    });
  } on MissingPluginException {
    // Tests.
  }
}
