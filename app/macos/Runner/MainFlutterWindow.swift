import Cocoa
import FlutterMacOS

// The "gerdtv/platform" channel on macOS: setLogo(name, png) sets the Dock icon for this run (Dart sends it again at
// every start). The Finder icon stays the bundled one: changing the app bundle would break its code signature.
// setMenuBar(enabled, labels) turns the menu bar mode on or off (Settings → Playback, app/lib/platform/menu_bar.dart);
// its menu calls back "menuBar" with "toggle" or "stop".
class MainFlutterWindow: NSWindow {
  private var channel: FlutterMethodChannel?

  /// Closing (title bar, Cmd-W) only hides the window while the menu bar mode is on: playback goes on.
  override func close() {
    if MenuBar.shared.enabled {
      MenuBar.shared.hide()
    } else {
      super.close()
    }
  }

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    MenuBar.shared.window = self
    channel = FlutterMethodChannel(
      name: "gerdtv/platform", binaryMessenger: flutterViewController.engine.binaryMessenger)
    MenuBar.shared.channel = channel
    channel?.setMethodCallHandler { call, result in
      if call.method == "setMenuBar", let args = call.arguments as? [String: Any] {
        MenuBar.shared.configure(
          enabled: args["enabled"] as? Bool ?? false, labels: args["labels"] as? [String: String] ?? [:])
        result(nil)
      } else if call.method == "setLogo",
        let png = (call.arguments as? [String: Any])?["png"] as? FlutterStandardTypedData
      {
        NSApp.applicationIconImage = NSImage(data: png.data)
        result(nil)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }

    super.awakeFromNib()
  }
}

/// The menu bar mode (owner request): with it on, closing the window or quitting from the Dock or with Cmd-Q hides
/// gerdTV into the menu bar (no Dock icon) and playback goes on; the menu bar item opens it again, pauses, stops or
/// really quits. Logging out, restarting and shutting down still quit at once.
/// Debugging: no item in the menu bar means Dart never sent setMenuBar(enabled: true) (the setting is off, or the
/// call failed before the first frame).
final class MenuBar: NSObject {
  static let shared = MenuBar()
  private(set) var enabled = false
  weak var window: NSWindow?
  var channel: FlutterMethodChannel?
  private var item: NSStatusItem?
  private var quitting = false

  func configure(enabled: Bool, labels: [String: String]) {
    self.enabled = enabled
    guard enabled else {
      if let item { NSStatusBar.system.removeStatusItem(item) }
      item = nil
      open()
      return
    }
    let item = self.item ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    item.button?.image = NSImage(systemSymbolName: "tv", accessibilityDescription: "gerdTV")
    item.button?.image?.isTemplate = true
    let menu = NSMenu()
    for (key, action) in [("open", #selector(open)), ("toggle", #selector(toggle)), ("stop", #selector(stop))] {
      let entry = NSMenuItem(title: labels[key] ?? key, action: action, keyEquivalent: "")
      entry.target = self
      menu.addItem(entry)
    }
    menu.addItem(.separator())
    let quit = NSMenuItem(title: labels["quit"] ?? "Quit", action: #selector(quit), keyEquivalent: "q")
    quit.target = self
    menu.addItem(quit)
    item.menu = menu
    self.item = item
  }

  /// Into the menu bar: no window, no Dock icon.
  func hide() {
    window?.orderOut(nil)
    NSApp.setActivationPolicy(.accessory)
  }

  @objc func open() {
    NSApp.setActivationPolicy(.regular)
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  @objc private func toggle() { channel?.invokeMethod("menuBar", arguments: "toggle") }
  @objc private func stop() { channel?.invokeMethod("menuBar", arguments: "stop") }

  @objc private func quit() {
    quitting = true
    NSApp.terminate(nil)
  }

  /// The Dock's Quit and Cmd-Q hide while the mode is on; the menu's Quit and the system's logout really quit.
  func shouldTerminate() -> NSApplication.TerminateReply {
    if !enabled || quitting || systemQuits() { return .terminateNow }
    hide()
    return .terminateCancel
  }

  /// Logout, restart and shutdown send the quit event with a reason; the Dock and Cmd-Q send none.
  private func systemQuits() -> Bool {
    guard let event = NSAppleEventManager.shared().currentAppleEvent,
      let reason = event.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))?.enumCodeValue
    else { return false }
    return [kAELogOut, kAEReallyLogOut, kAERestart, kAEShutDown, kAEShowRestartDialog, kAEShowShutdownDialog]
      .map { OSType($0) }.contains(reason)
  }
}
