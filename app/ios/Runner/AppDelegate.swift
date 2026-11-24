import AVFoundation
import AVKit
import Flutter
import UIKit
import UserNotifications

// iPhone/iPad side of "playback keeps going" (docs/ARCHITECTURE.md, "Platform channels"):
// - Background sound: the audio session's category is .playback and UIBackgroundModes has "audio", so mpv keeps
//   playing sound with the screen locked or in another app.
// - Picture-in-Picture: Apple's PiP only works with AVPlayer, not with mpv. On the player's PiP button Dart stops mpv
//   (the provider allows few connections) and calls startPip(url); AVPlayer takes the same stream (live as .m3u8) and
//   PiP starts as soon as it is possible. When PiP ends (or AVPlayer can't play the stream, e.g. .mkv), Dart is told
//   "pipEnded" (with the failure's reason, shown in the player) and resumes mpv.
// - The app icon: setLogo(name) picks the alternate icon "AppIcon-<name>" (asset catalog sets rendered by
//   `just logos`, listed in ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES); the default logo is the primary icon.
// Code lives in this file because new Swift files would have to be added to the Xcode project by hand.
// Debug hints: PiP needs the player layer in the window hierarchy (a tiny host view here) and a real device;
// the simulator supports PiP on recent Xcode versions.

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var platform: GerdtvPlatform?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Sound continues in the background (needs UIBackgroundModes/audio in Info.plist).
    try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    // Reminders (flutter_local_notifications): show while the app is open and report taps (its README's setup).
    UNUserNotificationCenter.current().delegate = self as? UNUserNotificationCenterDelegate
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "GerdtvPlatform") {
      platform = GerdtvPlatform(messenger: registrar.messenger())
    }
  }
}

/// The "gerdtv/platform" channel on iOS: setPlaying (audio session), startPip(url) → Bool, stopPip, setLogo(name),
/// openUrl(url) → Bool, brightness → Double, setBrightness(value), resetBrightness;
/// → pipEnded.
final class GerdtvPlatform: NSObject, AVPictureInPictureControllerDelegate {
  private let channel: FlutterMethodChannel
  private var player: AVPlayer?
  private var host: UIView?
  private var pip: AVPictureInPictureController?
  private var observations: [NSKeyValueObservation] = []
  /// The screen's brightness before the player's swipe changed it (nil: unchanged).
  private var ownBrightness: CGFloat?

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "gerdtv/platform", binaryMessenger: messenger)
    super.init()
    // Leaving the app gives the screen its own brightness back (the swipe's is for watching in gerdTV).
    NotificationCenter.default.addObserver(
      forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.restoreBrightness() }
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return }
      switch call.method {
      case "setPlaying":
        let playing = (call.arguments as? [String: Any])?["playing"] as? Bool ?? false
        try? AVAudioSession.sharedInstance().setActive(playing)
        result(nil)
      case "startPip":
        guard let url = (call.arguments as? [String: Any])?["url"] as? String, let u = URL(string: url) else {
          result(false)
          return
        }
        result(self.startPip(u))
      case "setLogo":
        // iOS shows its own "You have changed the icon" alert; that can't be turned off.
        let name = (call.arguments as? [String: Any])?["name"] as? String ?? "gtv"
        guard UIApplication.shared.supportsAlternateIcons else {
          result(nil)
          return
        }
        UIApplication.shared.setAlternateIconName(name == "gtv" ? nil : "AppIcon-\(name)") { _ in result(nil) }
      case "brightness":
        result(Double(UIScreen.main.brightness))
      case "setBrightness":
        // iOS's brightness is the screen's and stays after the app: remember the user's own to put it back.
        if let value = (call.arguments as? [String: Any])?["value"] as? Double {
          if self.ownBrightness == nil { self.ownBrightness = UIScreen.main.brightness }
          UIScreen.main.brightness = CGFloat(min(max(value, 0), 1))
        }
        result(nil)
      case "resetBrightness":
        self.restoreBrightness()
        result(nil)
      case "openUrl":
        guard let url = (call.arguments as? [String: Any])?["url"] as? String, let u = URL(string: url) else {
          result(false)
          return
        }
        UIApplication.shared.open(u) { opened in result(opened) }
      case "stopPip":
        self.pip?.stopPictureInPicture()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func restoreBrightness() {
    if let own = ownBrightness { UIScreen.main.brightness = own }
    ownBrightness = nil
  }

  private func startPip(_ url: URL) -> Bool {
    guard AVPictureInPictureController.isPictureInPictureSupported(),
      let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first
    else { return false }
    cleanUp()
    // The player layer has to be in the window hierarchy, at a real size, for PiP to become possible (a 2×2 layer
    // never did): full size, under Flutter's view, so nothing of it shows.
    let host = UIView(frame: window.bounds)
    host.isUserInteractionEnabled = false
    window.insertSubview(host, at: 0)
    let player = AVPlayer(url: url)
    let layer = AVPlayerLayer(player: player)
    layer.frame = host.bounds
    host.layer.addSublayer(layer)
    guard let pip = AVPictureInPictureController(playerLayer: layer) else {
      host.removeFromSuperview()
      return false
    }
    pip.delegate = self
    self.host = host
    self.player = player
    self.pip = pip
    // Start PiP as soon as it is possible; give up (back to mpv) if AVPlayer can't play this stream.
    observations.append(pip.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { pip, _ in
      if pip.isPictureInPicturePossible && !pip.isPictureInPictureActive { pip.startPictureInPicture() }
    })
    observations.append(player.observe(\.currentItem?.status, options: [.new]) { [weak self] player, _ in
      if player.currentItem?.status == .failed {
        let reason = player.currentItem?.error?.localizedDescription ?? "unknown"
        DispatchQueue.main.async { self?.finish(failure: "AVPlayer: \(reason)") }
      }
    })
    player.play()
    return true
  }

  func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
    finish(failure: nil)
  }

  func pictureInPictureController(
    _ controller: AVPictureInPictureController,
    failedToStartPictureInPictureWithError error: Error
  ) {
    finish(failure: "PiP: \(error.localizedDescription)")
  }

  func pictureInPictureController(
    _ controller: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
  ) {
    completionHandler(true)
  }

  /// [failure] is shown in the player (nil: PiP ended normally), so a device report can name the reason.
  private func finish(failure: String?) {
    NSLog("gerdTV PiP ended: \(failure ?? "ok")")
    cleanUp()
    channel.invokeMethod("pipEnded", arguments: ["failure": failure as Any])
  }

  private func cleanUp() {
    observations.removeAll()
    player?.pause()
    player = nil
    pip = nil
    host?.removeFromSuperview()
    host = nil
  }
}
