import Cocoa
import FlutterMacOS

// The "gerdtv/platform" channel on macOS: setLogo(name, png) sets the Dock icon for this run (Dart sends it again at
// every start). The Finder icon stays the bundled one: changing the app bundle would break its code signature.
class MainFlutterWindow: NSWindow {
  private var channel: FlutterMethodChannel?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    channel = FlutterMethodChannel(
      name: "gerdtv/platform", binaryMessenger: flutterViewController.engine.binaryMessenger)
    channel?.setMethodCallHandler { call, result in
      if call.method == "setLogo",
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
