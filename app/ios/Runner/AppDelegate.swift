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
//   "pipEnded" and resumes mpv.
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

/// The "gerdtv/platform" channel on iOS: setPlaying (audio session), startPip(url) → Bool, stopPip, setLogo(name);
/// → pipEnded.
final class GerdtvPlatform: NSObject, AVPictureInPictureControllerDelegate {
  private let channel: FlutterMethodChannel
  private var player: AVPlayer?
  private var host: UIView?
  private var pip: AVPictureInPictureController?
  private var observations: [NSKeyValueObservation] = []

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "gerdtv/platform", binaryMessenger: messenger)
    super.init()
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
      case "stopPip":
        self.pip?.stopPictureInPicture()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func startPip(_ url: URL) -> Bool {
    guard AVPictureInPictureController.isPictureInPictureSupported(),
      let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first
    else { return false }
    cleanUp()
    // A tiny host view: the player layer has to be in the window hierarchy for PiP to start.
    let host = UIView(frame: CGRect(x: 0, y: 0, width: 2, height: 2))
    window.addSubview(host)
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
      if player.currentItem?.status == .failed { DispatchQueue.main.async { self?.finish(failed: true) } }
    })
    player.play()
    return true
  }

  func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
    finish(failed: false)
  }

  func pictureInPictureController(
    _ controller: AVPictureInPictureController,
    failedToStartPictureInPictureWithError error: Error
  ) {
    finish(failed: true)
  }

  func pictureInPictureController(
    _ controller: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
  ) {
    completionHandler(true)
  }

  private func finish(failed: Bool) {
    cleanUp()
    channel.invokeMethod("pipEnded", arguments: ["failed": failed])
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
