// gerdTV's AVPlayer engine for live channels on iOS and macOS (owner decision; docs/ARCHITECTURE.md, "AVPlayer
// engine"). Live channels play the core's local HLS (gerdtv_core::hls) here instead of in mpv, so Picture-in-Picture,
// background sound and AirPlay are Apple's own, and nothing reconnects when the app switches between full player,
// mini bar, floating window and background: it is the same AVPlayer throughout.
//
// - Picture: AVPlayerItemVideoOutput hands BGRA pixel buffers to a Flutter texture (pulled 60 times a second while
//   the app is in the foreground), so the player, the now-playing bar and the Mac's mini window show it like mpv's.
// - Picture-in-Picture: an AVPlayerLayer on the same AVPlayer. iOS: behind the Flutter view at window size, with
//   canStartPictureInPictureAutomaticallyFromInline, so swiping to Home floats the channel by itself. macOS: below
//   the Flutter view at its size too, started from the player's PiP button.
// - Background (iOS): with PiP not active, the layer lets go of the player, or iOS would pause it (QA1668); sound
//   plays on. Closing the PiP window keeps the sound too (owner rule: playback ends only by Stop).
//
// Channel "gerdtv/avplayer": open(url, bufferSecs) → texture id, play, pause, seek(secs), setVolume(volume 0…1),
// setRate(rate), setBuffer(secs), selectTrack(kind "audio"/"subtitle", index, -1 = off), startPip → Bool, stopPip,
// stop. → "state" every 0.25 s (position, duration, seekStart, seekEnd, playing, buffering, width, height, pip,
// audio, audioIndex, subtitles, subtitleIndex, error).
// Debugging: "GerdtvAvPlayer:" lines in the device log; item errors arrive in Dart as the player's error.

#if os(iOS)
  import Flutter
  import UIKit
#else
  import FlutterMacOS
  import AppKit
#endif
import AVFoundation
import AVKit

public final class GerdtvAvPlayerPlugin: NSObject, FlutterPlugin, FlutterTexture,
  AVPictureInPictureControllerDelegate
{
  private let channel: FlutterMethodChannel
  private let textures: FlutterTextureRegistry
  private var player: AVPlayer?
  private var output: AVPlayerItemVideoOutput?
  private var textureId: Int64 = -1
  private let lock = NSLock()
  private var latest: CVPixelBuffer?
  private var frameTimer: Timer?
  private var stateTimer: Timer?
  private var layer: AVPlayerLayer?
  private var pip: AVPictureInPictureController?
  private var audio: AVMediaSelectionGroup?
  private var subtitles: AVMediaSelectionGroup?
  private var groupsLoading = false
  private var inBackground = false
  private var observers: [NSObjectProtocol] = []

  public static func register(with registrar: FlutterPluginRegistrar) {
    #if os(iOS)
      let messenger = registrar.messenger()
      let textures = registrar.textures()
    #else
      let messenger = registrar.messenger
      let textures = registrar.textures
    #endif
    let channel = FlutterMethodChannel(name: "gerdtv/avplayer", binaryMessenger: messenger)
    let plugin = GerdtvAvPlayerPlugin(channel: channel, textures: textures)
    registrar.addMethodCallDelegate(plugin, channel: channel)
  }

  init(channel: FlutterMethodChannel, textures: FlutterTextureRegistry) {
    self.channel = channel
    self.textures = textures
    super.init()
    #if os(iOS)
      let center = NotificationCenter.default
      observers.append(
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) {
          [weak self] _ in self?.enteredBackground()
        })
      observers.append(
        center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) {
          [weak self] _ in self?.enteringForeground()
        })
    #endif
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "open":
      guard let s = args["url"] as? String, let url = URL(string: s) else {
        result(FlutterError(code: "url", message: "not a URL", details: nil))
        return
      }
      result(open(url, buffer: args["bufferSecs"] as? Double ?? 0))
    case "play":
      player?.play()
      result(nil)
    case "pause":
      player?.pause()
      result(nil)
    case "seek":
      guard let player else {
        result(nil)
        return
      }
      let to = CMTime(seconds: args["secs"] as? Double ?? 0, preferredTimescale: 1000)
      // Channel replies belong on the main thread; the seek's completion may come on another.
      player.seek(to: to, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
        DispatchQueue.main.async { result(nil) }
      }
    case "setVolume":
      player?.volume = Float(args["volume"] as? Double ?? 1)
      result(nil)
    case "setRate":
      let rate = Float(args["rate"] as? Double ?? 1)
      player?.defaultRate = rate
      if player?.timeControlStatus != .paused { player?.rate = rate }
      result(nil)
    case "setBuffer":
      player?.currentItem?.preferredForwardBufferDuration = args["secs"] as? Double ?? 0
      result(nil)
    case "selectTrack":
      selectTrack(kind: args["kind"] as? String ?? "", index: args["index"] as? Int ?? -1)
      result(nil)
    case "startPip":
      guard let pip, pip.isPictureInPicturePossible else {
        result(false)
        return
      }
      pip.startPictureInPicture()
      result(true)
    case "stopPip":
      pip?.stopPictureInPicture()
      result(nil)
    case "stop":
      stop()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: playback

  private func open(_ url: URL, buffer: Double) -> Int64 {
    stop()
    let item = AVPlayerItem(url: url)
    item.preferredForwardBufferDuration = buffer
    let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
      kCVPixelBufferMetalCompatibilityKey as String: true,
    ])
    item.add(output)
    let player = AVPlayer(playerItem: item)
    self.player = player
    self.output = output
    if textureId < 0 {
      textureId = textures.register(self)
    }
    attachLayer(player)
    #if os(iOS)
      // Only while AVPlayer plays: mpv's picture has a PiP of its own (app/ios/Runner/AppDelegate.swift).
      pip?.canStartPictureInPictureAutomaticallyFromInline = true
    #endif
    frameTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
      self?.pullFrame()
    }
    stateTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
      self?.sendState()
    }
    player.play()
    NSLog("GerdtvAvPlayer: open (buffer \(buffer) s)")
    return textureId
  }

  private func stop() {
    frameTimer?.invalidate()
    stateTimer?.invalidate()
    frameTimer = nil
    stateTimer = nil
    if pip?.isPictureInPictureActive == true {
      pip?.stopPictureInPicture()
    }
    #if os(iOS)
      pip?.canStartPictureInPictureAutomaticallyFromInline = false
    #endif
    player?.pause()
    player?.replaceCurrentItem(with: nil)
    player = nil
    output = nil
    layer?.player = nil
    audio = nil
    subtitles = nil
    groupsLoading = false
    lock.lock()
    latest = nil
    lock.unlock()
  }

  private func selectTrack(kind: String, index: Int) {
    guard let item = player?.currentItem, let group = kind == "audio" ? audio : subtitles else { return }
    let option = index >= 0 && index < group.options.count ? group.options[index] : nil
    item.select(option, in: group)
  }

  // MARK: picture

  private func pullFrame() {
    guard !inBackground, let output else { return }
    let time = output.itemTime(forHostTime: CACurrentMediaTime())
    guard output.hasNewPixelBuffer(forItemTime: time),
      let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil)
    else { return }
    lock.lock()
    latest = buffer
    lock.unlock()
    textures.textureFrameAvailable(textureId)
  }

  public func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    lock.lock()
    defer { lock.unlock() }
    guard let latest else { return nil }
    return Unmanaged.passRetained(latest)
  }

  // MARK: state

  private func sendState() {
    guard let player, let item = player.currentItem else { return }
    func finite(_ v: Double) -> Double { v.isFinite ? v : 0 }
    let range = item.seekableTimeRanges.last?.timeRangeValue
    var state: [String: Any] = [
      "position": finite(player.currentTime().seconds),
      "duration": item.duration.isIndefinite ? 0.0 : finite(item.duration.seconds),
      "seekStart": finite(range?.start.seconds ?? 0),
      "seekEnd": finite(range.map { CMTimeRangeGetEnd($0).seconds } ?? 0),
      // media_kit's "playing" means not paused (mpv stays playing while it buffers); buffering is separate.
      "playing": player.timeControlStatus != .paused,
      "buffering": player.timeControlStatus == .waitingToPlayAtSpecifiedRate,
      "width": Double(item.presentationSize.width),
      "height": Double(item.presentationSize.height),
      "pip": pip?.isPictureInPictureActive ?? false,
    ]
    if item.status == .failed {
      state["error"] = item.error?.localizedDescription ?? "AVPlayer could not play the stream."
    }
    if item.status == .readyToPlay && audio == nil && subtitles == nil && !groupsLoading {
      loadGroups(item)
    }
    if let audio {
      state["audio"] = audio.options.map(\.displayName)
      state["audioIndex"] = item.currentMediaSelection.selectedMediaOption(in: audio).flatMap {
        audio.options.firstIndex(of: $0)
      } ?? -1
    }
    if let subtitles {
      state["subtitles"] = subtitles.options.map(\.displayName)
      state["subtitleIndex"] = item.currentMediaSelection.selectedMediaOption(in: subtitles).flatMap {
        subtitles.options.firstIndex(of: $0)
      } ?? -1
    }
    channel.invokeMethod("state", arguments: state)
  }

  /// The audio and subtitle choices of the stream (loaded once it is ready).
  private func loadGroups(_ item: AVPlayerItem) {
    groupsLoading = true
    let asset = item.asset
    Task { @MainActor [weak self] in
      let audio = try? await asset.loadMediaSelectionGroup(for: .audible)
      let subtitles = try? await asset.loadMediaSelectionGroup(for: .legible)
      guard let self, self.player?.currentItem === item else { return }
      self.audio = audio
      self.subtitles = subtitles
    }
  }

  // MARK: Picture-in-Picture

  private func attachLayer(_ player: AVPlayer) {
    if let layer {
      layer.player = player
      return
    }
    let layer = AVPlayerLayer(player: player)
    #if os(iOS)
      guard
        let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first
      else { return }
      // Behind the Flutter view, at window size: iOS starts PiP on its own only from a layer that counts as shown.
      let host = UIView(frame: window.bounds)
      host.isUserInteractionEnabled = false
      host.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      window.insertSubview(host, at: 0)
      layer.frame = host.bounds
      host.layer.addSublayer(layer)
    #else
      // Beside the Flutter view, below it, at its size (a subview of it would draw over Flutter; a 2×2 layer never
      // made PiP possible).
      guard let view = NSApp.windows.first?.contentView, let frame = view.superview else { return }
      let host = NSView(frame: view.frame)
      host.wantsLayer = true
      host.autoresizingMask = [.width, .height]
      frame.addSubview(host, positioned: .below, relativeTo: view)
      layer.frame = host.bounds
      host.layer?.addSublayer(layer)
    #endif
    self.layer = layer
    guard AVPictureInPictureController.isPictureInPictureSupported(),
      let pip = AVPictureInPictureController(playerLayer: layer)
    else {
      NSLog("GerdtvAvPlayer: Picture-in-Picture not supported")
      return
    }
    pip.delegate = self
    self.pip = pip
  }

  public func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
    sendState()
  }

  public func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
    #if os(iOS)
      // Closed while gerdTV is in the background: the sound goes on (AVKit paused it).
      if inBackground, let player {
        layer?.player = nil
        player.play()
      }
    #endif
    sendState()
  }

  public func pictureInPictureController(
    _ controller: AVPictureInPictureController,
    failedToStartPictureInPictureWithError error: Error
  ) {
    NSLog("GerdtvAvPlayer: PiP failed: \(error.localizedDescription)")
  }

  public func pictureInPictureController(
    _ controller: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
  ) {
    completionHandler(true)
  }

  // MARK: background (iOS)

  private func enteredBackground() {
    inBackground = true
    // Without PiP, a player still shown by a layer is paused by iOS in the background: let go of it.
    if pip?.isPictureInPictureActive != true {
      layer?.player = nil
    }
  }

  private func enteringForeground() {
    inBackground = false
    if let player {
      layer?.player = player
    }
  }
}
