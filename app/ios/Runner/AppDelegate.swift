import AVFoundation
import AVKit
import Flutter
import UIKit
import UserNotifications
import media_kit_video

// iPhone/iPad side of "playback keeps going" (docs/ARCHITECTURE.md, "Platform channels"):
// - Background sound: the audio session's category is .playback and UIBackgroundModes has "audio", so mpv keeps
//   playing sound with the screen locked or in another app.
// - Picture-in-Picture of mpv's picture (movies, episodes, and channels AVPlayer can't play; live channels normally
//   play in AVPlayer, app/packages/gerdtv_avplayer, with its own PiP): media_kit hands every frame mpv draws to an
//   AVSampleBufferDisplayLayer behind the Flutter view (TextureHW.pipSink), so PiP shows mpv's own picture: no
//   hand-over, nothing reconnects. Swiping to Home floats it by itself; in the background mpv renders it in software
//   at PiP size (TextureHW.useSoftware). The PiP window's play/pause and skip come back to Dart as "pipCommand".
// - The app icon: setLogo(name) picks the alternate icon "AppIcon-<name>" (asset catalog sets rendered by
//   `just logos`, listed in ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES); the default logo is the primary icon.
// Code lives in this file because new Swift files would have to be added to the Xcode project by hand.
// Debug hints: PiP needs the layer in the window hierarchy and a real device (the simulator renders mpv in
// software, which media_kit doesn't feed to PiP); "GerdtvPlatform:" lines in the device log.

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

/// The "gerdtv/platform" channel on iOS: setPlaying (audio session), preparePip(on), setFloating(on), pipState(playing, position,
/// duration, live), startPip → Bool, stopPip, setLogo(name), openUrl(url) → Bool, brightness → Double,
/// setBrightness(value), resetBrightness; → pipCommand(action "play"/"pause"/"skip", secs).
final class GerdtvPlatform: NSObject, AVPictureInPictureControllerDelegate,
  AVPictureInPictureSampleBufferPlaybackDelegate
{
  private let channel: FlutterMethodChannel
  private var host: UIView?
  private let display = AVSampleBufferDisplayLayer()
  private var pip: AVPictureInPictureController?
  private var format: CMVideoFormatDescription?
  // What the PiP window shows, from Dart's pipState (once a second).
  private var playing = false
  private var duration = 0.0
  private var live = false
  /// Leaving the app floats the picture (Dart decides: lib/player/floating.dart).
  private var floating = false
  /// The screen's brightness before the player's swipe changed it (nil: unchanged).
  private var ownBrightness: CGFloat?

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "gerdtv/platform", binaryMessenger: messenger)
    super.init()
    // Leaving the app gives the screen its own brightness back (the swipe's is for watching in gerdTV).
    NotificationCenter.default.addObserver(
      forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.restoreBrightness() }
    // Back in the app the player shows the picture: the window would show it a second time.
    NotificationCenter.default.addObserver(
      forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.pip?.stopPictureInPicture() }
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return }
      let args = call.arguments as? [String: Any] ?? [:]
      switch call.method {
      case "setPlaying":
        let playing = args["playing"] as? Bool ?? false
        try? AVAudioSession.sharedInstance().setActive(playing)
        result(nil)
      case "preparePip":
        self.prepare(args["on"] as? Bool ?? false)
        result(nil)
      case "setFloating":
        self.floating = args["on"] as? Bool ?? false
        self.pip?.canStartPictureInPictureAutomaticallyFromInline = self.floating
        result(nil)
      case "pipState":
        let wasPlaying = self.playing
        self.playing = args["playing"] as? Bool ?? false
        self.duration = args["duration"] as? Double ?? 0
        self.live = args["live"] as? Bool ?? false
        if wasPlaying != self.playing { self.pip?.invalidatePlaybackState() }
        result(nil)
      case "startPip":
        guard let pip = self.pip, pip.isPictureInPicturePossible else {
          result(false)
          return
        }
        pip.startPictureInPicture()
        result(true)
      case "setLogo":
        // iOS shows its own "You have changed the icon" alert; that can't be turned off.
        let name = args["name"] as? String ?? "gtv"
        guard UIApplication.shared.supportsAlternateIcons else {
          result(nil)
          return
        }
        UIApplication.shared.setAlternateIconName(name == "gtv" ? nil : "AppIcon-\(name)") { _ in result(nil) }
      case "brightness":
        result(Double(UIScreen.main.brightness))
      case "setBrightness":
        // iOS's brightness is the screen's and stays after the app: remember the user's own to put it back.
        if let value = args["value"] as? Double {
          if self.ownBrightness == nil { self.ownBrightness = UIScreen.main.brightness }
          UIScreen.main.brightness = CGFloat(min(max(value, 0), 1))
        }
        result(nil)
      case "resetBrightness":
        self.restoreBrightness()
        result(nil)
      case "openUrl":
        guard let url = args["url"] as? String, let u = URL(string: url) else {
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

  /// mpv's stream is open (on): its frames go to the PiP layer; Home floats it while [floating]. Off (Stop, or
  /// AVPlayer takes over): the window closes and nothing of it stays, or iOS may still offer the last picture.
  private func prepare(_ on: Bool) {
    if on && host == nil {
      guard
        let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first
      else { return }
      // Behind the Flutter view, at window size: PiP never became possible from a 2×2 layer, and iOS starts it on
      // its own only from a layer that counts as shown.
      let host = UIView(frame: window.bounds)
      host.isUserInteractionEnabled = false
      host.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      display.frame = host.bounds
      display.videoGravity = .resizeAspect
      host.layer.addSublayer(display)
      window.insertSubview(host, at: 0)
      self.host = host
      let pip = AVPictureInPictureController(
        contentSource: .init(sampleBufferDisplayLayer: display, playbackDelegate: self))
      pip.delegate = self
      self.pip = pip
    }
    pip?.canStartPictureInPictureAutomaticallyFromInline = on && floating
    TextureHW.pipSink = on ? { [weak self] buffer in self?.enqueue(buffer) } : nil
    if !on {
      pip?.stopPictureInPicture()
      pip = nil
      playing = false
      TextureHW.pipActive = false  // the released controller no longer reports the end
      display.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
      display.removeFromSuperlayer()
      host?.removeFromSuperview()
      host = nil
    }
  }

  /// One of mpv's frames into the PiP layer, shown at once (called on media_kit's render thread).
  private func enqueue(_ buffer: CVPixelBuffer) {
    if format == nil || !CMVideoFormatDescriptionMatchesImageBuffer(format!, imageBuffer: buffer) {
      format = nil
      CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: nil, imageBuffer: buffer, formatDescriptionOut: &format)
    }
    guard let format else { return }
    var timing = CMSampleTimingInfo(
      duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    CMSampleBufferCreateReadyWithImageBuffer(
      allocator: nil, imageBuffer: buffer, formatDescription: format, sampleTiming: &timing,
      sampleBufferOut: &sample)
    guard let sample else { return }
    if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
      CFArrayGetCount(attachments) > 0
    {
      let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
      CFDictionarySetValue(
        dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
        Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
    }
    let renderer = display.sampleBufferRenderer
    if renderer.status == .failed {
      renderer.flush()
    }
    renderer.enqueue(sample)
  }

  // MARK: AVPictureInPictureSampleBufferPlaybackDelegate: the PiP window's buttons and seek range.

  func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {
    self.playing = playing
    channel.invokeMethod("pipCommand", arguments: ["action": playing ? "play" : "pause"])
  }

  func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
    live || duration <= 0
      ? CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
      : CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 1000))
  }

  func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool {
    !playing
  }

  func pictureInPictureController(
    _ controller: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions
  ) {}

  func pictureInPictureController(
    _ controller: AVPictureInPictureController, skipByInterval skipInterval: CMTime,
    completion completionHandler: @escaping () -> Void
  ) {
    channel.invokeMethod("pipCommand", arguments: ["action": "skip", "secs": skipInterval.seconds])
    completionHandler()
  }

  // MARK: AVPictureInPictureControllerDelegate

  func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
    TextureHW.pipActive = true
  }

  func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
    TextureHW.pipActive = false
  }

  func pictureInPictureController(
    _ controller: AVPictureInPictureController,
    failedToStartPictureInPictureWithError error: Error
  ) {
    NSLog("GerdtvPlatform: PiP failed: \(error.localizedDescription)")
  }

  func pictureInPictureController(
    _ controller: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
  ) {
    completionHandler(true)
  }
}
