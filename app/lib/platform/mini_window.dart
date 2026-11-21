// Desktop mini player (Spike B): the main window itself shrinks into a small, borderless, always-on-top window and
// grows back. The same window means the same Flutter engine and the same media_kit Player, so playback never
// restarts. (A second window would be a second engine that can't share the player: the stream would reopen.)
//
// Uses window_manager's native API (package:window_manager re-exports nativeapi's Window). Desktop only.
// Debug hints: if the window doesn't move to the front on macOS, check isVisibleOnAllWorkspaces; if nothing
// happens at all, WindowManager.instance.getCurrent() returned null (called before the first frame).

import 'dart:ui' as ui;

import 'package:window_manager/window_manager.dart' as wm;

class MiniWindow {
  /// The mini window's size in logical pixels (16:9).
  static const miniWidth = 480.0;
  static const miniHeight = 270.0;

  // Flutter geometry here; window_manager's extensions convert to and from nativeapi's (toNative/toRect).
  ui.Rect? _restore;

  bool get isMini => _restore != null;

  wm.Window get _window {
    final w = wm.WindowManager.instance.getCurrent();
    if (w == null) throw StateError('MiniWindow: no current window yet');
    return w;
  }

  /// Shrinks into mini mode, remembering the current bounds.
  void enter() {
    if (isMini) return;
    final w = _window;
    _restore = w.bounds.toRect();
    w.titleBarStyle = wm.TitleBarStyle.hidden;
    w.isAlwaysOnTop = true;
    w.isVisibleOnAllWorkspaces = true; // macOS: follows the user across Spaces
    w.minimumSize = const ui.Size(240, 135).toNative();
    w.setSize(const ui.Size(miniWidth, miniHeight).toNative(), false);
  }

  /// Grows back to the remembered bounds.
  void exit() {
    final restore = _restore;
    if (restore == null) return;
    final w = _window;
    w.isAlwaysOnTop = false;
    w.isVisibleOnAllWorkspaces = false;
    w.titleBarStyle = wm.TitleBarStyle.normal;
    w.bounds = restore.toNative();
    _restore = null;
  }

  /// The current window size (for tests and layout decisions).
  ({double width, double height}) get size {
    final s = _window.size;
    return (width: s.width, height: s.height);
  }
}
