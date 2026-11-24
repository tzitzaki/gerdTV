import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  // With the menu bar mode on the window only hides (MainFlutterWindow.close), so this never fires then.
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    return MenuBar.shared.shouldTerminate()
  }

  // A click on the Dock icon (while it shows) brings the hidden window back.
  override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if !flag { MenuBar.shared.open() }
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
