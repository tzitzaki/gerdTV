// Desktop player window (macOS, Linux): while the player shows, the window's content takes the picture's aspect ratio,
// so media_kit's `BoxFit.contain` has no black bars to draw, and the system keeps that ratio while the user resizes
// (nativeapi's Window.aspectRatio: NSWindow.contentAspectRatio on macOS, GDK_HINT_ASPECT on Linux; 0 clears it).
//
// Two sizes are remembered across restarts (app-wide settings): the browsing size (the window outside the player) and
// the player's width (its height follows each picture's ratio). Opening the player animates to the player size,
// leaving it animates back. Fullscreen and the mini player have their own sizes: [unlock] while they show.
//
// Debug hints: bars despite the lock usually mean the ratio came from a stream whose width/height mpv reported before
// the first frame (zapping re-fits on the next report); a window that doesn't move at all means getCurrent() returned
// null (no window yet) or the platform isn't macOS/Linux.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:window_manager/window_manager.dart' as wm;

/// The content size for [width] at [ratio], shrunk to fit [screen] (both sides keep the ratio).
ui.Size fitToRatio(double width, double ratio, ui.Size screen) {
  var w = width;
  var h = w / ratio;
  if (w > screen.width) (w, h) = (screen.width, screen.width / ratio);
  if (h > screen.height) (w, h) = (screen.height * ratio, screen.height);
  return ui.Size(w.roundToDouble(), h.roundToDouble());
}

/// "1280x720" ↔ Size; null for anything else (a value from an older version, hand edits).
ui.Size? parseWindowSize(String? s) {
  final p = s?.split('x');
  final w = double.tryParse(p?.first ?? '');
  final h = double.tryParse(p?.last ?? '');
  return p?.length == 2 && w != null && h != null && w > 0 && h > 0
      ? ui.Size(w, h)
      : null;
}

String formatWindowSize(ui.Size s) => '${s.width.round()}x${s.height.round()}';

class VideoWindow {
  VideoWindow({required this.read, required this.write});

  /// App-wide settings (Session's appSetting/setAppSetting).
  final Future<String?> Function(String key) read;
  final Future<void> Function(String key, String value) write;

  static const browseKey = 'window_browse';
  static const playerKey = 'window_player';

  /// The picture's ratio while the player follows it, null otherwise.
  double? _ratio;

  /// Why the lock is off for now ('fullscreen', 'mini'); the ratio applies again once this is empty.
  final Set<String> _unlockedFor = {};

  static bool get supported => Platform.isMacOS || Platform.isLinux;

  wm.Window? get _window =>
      supported ? wm.WindowManager.instance.getCurrent() : null;

  /// At start: the browsing size of the last run.
  Future<void> restoreBrowse() async {
    final size = parseWindowSize(await read(browseKey));
    final w = _window;
    if (size != null && w != null) w.setSize(size.toNative(), false);
  }

  /// The player shows a picture of [ratio] (width / height): the first call remembers the browsing size and moves to
  /// the player size, later ones (zapping to another ratio) keep the width.
  Future<void> follow(double ratio) async {
    final w = _window;
    if (w == null || !ratio.isFinite || ratio <= 0 || ratio == _ratio) return;
    final first = _ratio == null;
    _ratio = ratio; // set before the awaits: a second report meanwhile is the same ratio
    var width = w.contentSize.toSize().width;
    if (first) {
      await write(browseKey, formatWindowSize(w.size.toSize()));
      width = parseWindowSize(await read(playerKey))?.width ?? width;
    }
    if (_unlockedFor.isEmpty && _ratio == ratio) {
      _apply(w, width, animate: true);
    }
  }

  /// Fullscreen or the mini player take over with their own size and no lock (a ratio lock keeps macOS fullscreen
  /// from filling a screen of another ratio). [lock] with the same reason puts it back.
  void unlock(String why) {
    _unlockedFor.add(why);
    _window?.aspectRatio = 0;
  }

  void lock(String why) {
    _unlockedFor.remove(why);
    final w = _window;
    if (w == null || _ratio == null || _unlockedFor.isNotEmpty) return;
    _apply(w, w.contentSize.toSize().width, animate: false);
  }

  /// The player closed: remember its size (the user's resizes included), drop the lock, back to the browsing size.
  Future<void> leave() async {
    final w = _window;
    if (w == null || _ratio == null) return;
    _ratio = null;
    _unlockedFor.clear();
    w.aspectRatio = 0;
    await write(playerKey, formatWindowSize(w.contentSize.toSize()));
    final browse = parseWindowSize(await read(browseKey));
    if (browse != null) w.setSize(browse.toNative(), true);
  }

  /// Locks the ratio and sizes the content to [width] at it, within the screen.
  void _apply(wm.Window w, double width, {required bool animate}) {
    final ratio = _ratio!;
    // The title bar (and Linux's decorations) are outside the content: the frame is larger by them.
    final frame = w.size.toSize();
    final content = w.contentSize.toSize();
    final extra = ui.Size(
      frame.width - content.width,
      frame.height - content.height,
    );
    final display = ui.PlatformDispatcher.instance.displays.first;
    final screen = display.size / display.devicePixelRatio;
    // 90 %: room for the menu bar, the Dock or a panel (Flutter knows the screen, not its work area).
    final target = fitToRatio(
      width,
      ratio,
      ui.Size(
        screen.width * 0.9 - extra.width,
        screen.height * 0.9 - extra.height,
      ),
    );
    w.aspectRatio = ratio;
    w.setSize(
      ui.Size(
        target.width + extra.width,
        target.height + extra.height,
      ).toNative(),
      animate,
    );
  }
}
