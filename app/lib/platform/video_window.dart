// Desktop player window (macOS, Linux): while the player shows, the window's content takes the picture's aspect ratio,
// so media_kit's `BoxFit.contain` has no black bars to draw, and the system keeps that ratio while the user resizes
// (nativeapi's Window.aspectRatio: NSWindow.contentAspectRatio on macOS, GDK_HINT_ASPECT on Linux; 0 clears it).
//
// Two sizes are remembered across restarts (app-wide settings): the browsing size (the window outside the player) and
// the player's width (its height follows each picture's ratio). Opening the player animates to the player size,
// leaving it animates back (stepped in Dart on Linux, instant on macOS, see _resizeTo). Fullscreen and the mini player have their own sizes: [unlock] while they show.
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

/// The ratio the window follows: a [forced] aspect (the item's picture format 16:9 or 4:3), else the stream's
/// [width] / [height]; null until both sides are known.
double? windowRatio(double? forced, int? width, int? height) =>
    forced ??
    (width != null && height != null && width > 0 && height > 0
        ? width / height
        : null);

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
      await _apply(w, width, animate: true);
    }
  }

  /// Fullscreen or the mini player take over with their own size and no lock (a ratio lock keeps macOS fullscreen
  /// from filling a screen of another ratio). [lock] with the same reason puts it back.
  void unlock(String why) {
    final w = _window;
    if (_unlockedFor.isEmpty && w != null) {
      _widthAtUnlock = w.contentSize.toSize().width;
      _ratioAtUnlock = _ratio;
    }
    _unlockedFor.add(why);
    w?.aspectRatio = 0;
  }

  /// The content width and the ratio when the lock was lifted: what the window comes back to.
  double? _widthAtUnlock;
  double? _ratioAtUnlock;

  /// Fullscreen or the mini player ended. Their restore of the old bounds is still pending then (GTK applies it later,
  /// and the window still reports the small size: reading it shrank the restored player to 555 px), so this waits a
  /// moment and reads no size. The restored window has the player's ratio already; only a ratio that changed meanwhile
  /// (zapping in the mini player) re-fits, at the width from before.
  Future<void> lock(String why) async {
    _unlockedFor.remove(why);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final w = _window;
    final ratio = _ratio;
    final width = _widthAtUnlock;
    if (w == null || ratio == null || _unlockedFor.isNotEmpty) return;
    if (ratio != _ratioAtUnlock && width != null) {
      await _apply(w, width, animate: false);
    } else {
      w.aspectRatio = ratio;
    }
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
    if (browse != null) await _resizeTo(w, browse, animate: true);
  }

  /// Locks the ratio and sizes the content to [width] at it, within the screen.
  Future<void> _apply(
    wm.Window w,
    double width, {
    required bool animate,
  }) async {
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
    // Lock after the resize: GTK applies the aspect hint to programmatic resizes too, so a lock from the old ratio
    // would bend the new size.
    w.aspectRatio = 0;
    await _resizeTo(
      w,
      ui.Size(target.width + extra.width, target.height + extra.height),
      animate: animate,
    );
    w.aspectRatio = ratio;
  }

  /// Resizes the frame to [size]; on Linux animated in 8 steps of 20 ms, on macOS in one step. Not nativeapi's own
  /// animation: on macOS it goes through NSWindow's animator proxy, and called this way the window didn't move at all
  /// (CI: 780 px stayed 780). Debugging a window that ends between sizes: something else resized it during the 160 ms.
  Future<void> _resizeTo(
    wm.Window w,
    ui.Size size, {
    required bool animate,
  }) async {
    final from = w.size.toSize();
    // Not stepped on macOS: quick successive resizes there kept mpv's pause from applying while the player opened
    // (CI: userPaused true, playback ran on). One resize keeps it working; the switch is instant instead of animated.
    if (animate && !Platform.isMacOS) {
      for (var i = 1; i < 8; i++) {
        w.setSize(ui.Size.lerp(from, size, i / 8)!.toNative(), false);
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }
    w.setSize(size.toNative(), false);
  }
}
