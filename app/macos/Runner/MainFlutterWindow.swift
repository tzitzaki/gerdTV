import AVFoundation
import Cocoa
import FlutterMacOS
import MediaPlayer
import Vision

// The "gerdtv/platform" channel on macOS: setLogo(name, png) sets the Dock icon for this run (Dart sends it again at
// every start). The Finder icon stays the bundled one: changing the app bundle would break its code signature.
// setMenuBar(enabled, labels) turns the menu bar mode on or off (Settings → Playback, app/lib/platform/menu_bar.dart);
// its menu calls back "menuBar" with "toggle" or "stop". nowPlaying(…) and clearNowPlaying drive the media keys and
// Control Center (NowPlaying below), which call back "mediaCommand" with "play" or "pause". scanQr(title) opens the
// webcam and answers with the first QR code's text, or nil (QrScanner below; Devices & sync on the Mac).
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
    // Hover also while another app is in front: the mini player floats above it and shows its buttons on hover.
    flutterViewController.mouseTrackingMode = .always

    RegisterGeneratedPlugins(registry: flutterViewController)
    MenuBar.shared.window = self
    channel = FlutterMethodChannel(
      name: "gerdtv/platform", binaryMessenger: flutterViewController.engine.binaryMessenger)
    MenuBar.shared.channel = channel
    NowPlaying.shared.channel = channel
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
      } else if call.method == "nowPlaying", let args = call.arguments as? [String: Any] {
        NowPlaying.shared.show(args)
        result(nil)
      } else if call.method == "clearNowPlaying" {
        NowPlaying.shared.clear()
        result(nil)
      } else if call.method == "scanQr" {
        let title = (call.arguments as? [String: Any])?["title"] as? String ?? ""
        QrScanner.scan(title: title) { text in result(text) }
      } else {
        result(FlutterMethodNotImplemented)
      }
    }

    super.awakeFromNib()
  }
}

/// The media keys and Control Center's Now Playing: what plays, with play/pause only (owner decision), as on iOS
/// (app/ios/Runner/AppDelegate.swift; Dart: app/lib/services/media_card.dart).
/// Debugging: keys that reach another app mean macOS thinks that one plays; unlike iOS, macOS goes by playbackState.
final class NowPlaying {
  static let shared = NowPlaying()
  var channel: FlutterMethodChannel?
  private var playing = false
  private var registered = false

  func show(_ args: [String: Any]) {
    register()
    playing = args["playing"] as? Bool ?? false
    let live = args["live"] as? Bool ?? false
    var info: [String: Any] = [
      MPMediaItemPropertyTitle: args["title"] as? String ?? "",
      MPMediaItemPropertyArtist: args["subtitle"] as? String ?? "",
      MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
      MPNowPlayingInfoPropertyIsLiveStream: live,
      MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0,
    ]
    if !live, let duration = args["duration"] as? Double, duration > 0 {
      info[MPMediaItemPropertyPlaybackDuration] = duration
      info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = args["position"] as? Double ?? 0
    }
    if let path = args["artwork"] as? String, let image = NSImage(contentsOfFile: path) {
      info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    MPNowPlayingInfoCenter.default().playbackState = playing ? .playing : .paused
  }

  func clear() {
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    MPNowPlayingInfoCenter.default().playbackState = .stopped
  }

  /// With the first stream, so gerdTV doesn't take the keys before it plays anything.
  private func register() {
    guard !registered else { return }
    registered = true
    let commands = MPRemoteCommandCenter.shared()
    commands.playCommand.addTarget { [weak self] _ in self?.send("play") ?? .commandFailed }
    commands.pauseCommand.addTarget { [weak self] _ in self?.send("pause") ?? .commandFailed }
    commands.togglePlayPauseCommand.addTarget { [weak self] _ in
      guard let self else { return .commandFailed }
      return self.send(self.playing ? "pause" : "play")
    }
  }

  private func send(_ action: String) -> MPRemoteCommandHandlerStatus {
    DispatchQueue.main.async { self.channel?.invokeMethod("mediaCommand", arguments: action) }
    return .success
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

/// Pairing by the webcam (Devices & sync → Scan with the camera): a small window shows the camera, Vision looks for a QR
/// code in every frame, and the first one's text goes back to Dart; nil when the window is closed, there's no camera or
/// the camera is refused. Only one scan at a time.
/// Debugging: no picture or nil at once = camera access refused (System Settings → Privacy & Security → Camera), or
/// NSCameraUsageDescription missing in Info.plist (then macOS ends the app on the first access).
final class QrScanner: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, NSWindowDelegate {
  private static var current: QrScanner?
  private let session = AVCaptureSession()
  private let queue = DispatchQueue(label: "gerdtv.qr")
  private var panel: NSPanel?
  private var done: ((String?) -> Void)?

  static func scan(title: String, completion: @escaping (String?) -> Void) {
    guard current == nil else { return completion(nil) }
    let scanner = QrScanner()
    current = scanner
    scanner.done = completion
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
      scanner.start(title: title)
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .video) { granted in
        DispatchQueue.main.async { granted ? scanner.start(title: title) : scanner.finish(nil) }
      }
    default:
      scanner.finish(nil)
    }
  }

  private func start(title: String) {
    guard let camera = AVCaptureDevice.default(for: .video),
      let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input)
    else { return finish(nil) }
    session.addInput(input)
    let output = AVCaptureVideoDataOutput()
    output.alwaysDiscardsLateVideoFrames = true
    output.setSampleBufferDelegate(self, queue: queue)
    guard session.canAddOutput(output) else { return finish(nil) }
    session.addOutput(output)
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 480, height: 360), styleMask: [.titled, .closable],
      backing: .buffered, defer: false)
    panel.title = title
    panel.isReleasedWhenClosed = false
    panel.delegate = self
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 360))
    view.wantsLayer = true
    let preview = AVCaptureVideoPreviewLayer(session: session)
    preview.videoGravity = .resizeAspectFill
    preview.frame = view.bounds
    preview.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
    view.layer?.addSublayer(preview)
    panel.contentView = view
    panel.center()
    panel.makeKeyAndOrderFront(nil)
    self.panel = panel
    queue.async { self.session.startRunning() }
  }

  func captureOutput(
    _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection
  ) {
    guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
    let request = VNDetectBarcodesRequest()
    request.symbologies = [.qr]
    try? VNImageRequestHandler(cvPixelBuffer: pixels, options: [:]).perform([request])
    guard let text = request.results?.first?.payloadStringValue else { return }
    DispatchQueue.main.async { self.finish(text) }
  }

  func windowWillClose(_ notification: Notification) { finish(nil) }

  /// Answers once: the first QR code, a closed window and a refusal all end here.
  private func finish(_ text: String?) {
    guard let done else { return }
    self.done = nil
    queue.async { self.session.stopRunning() }
    panel?.delegate = nil
    panel?.close()
    QrScanner.current = nil
    done(text)
  }
}
