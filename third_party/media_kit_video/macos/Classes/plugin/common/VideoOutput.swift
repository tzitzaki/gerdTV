#if canImport(Flutter)
  import Flutter
#elseif canImport(FlutterMacOS)
  import FlutterMacOS
#endif
#if canImport(UIKit)
  import UIKit
#else
  import AppKit
#endif

// This class creates and manipulates the different types of FlutterTexture,
// handles resizing, rendering calls, and notify Flutter when a new frame is
// available to render.
//
// To improve the user experience, a worker is used to execute heavy tasks on a
// dedicated thread.
public class VideoOutput: NSObject {
  // Will be called on the main thread
  public typealias TextureUpdateCallback = (Int64, CGSize) -> Void

  private static let isSimulator: Bool = {
    let isSim: Bool
    #if targetEnvironment(simulator)
      isSim = true
    #else
      isSim = false
    #endif
    return isSim
  }()

  private let handle: OpaquePointer
  private let enableHardwareAcceleration: Bool
  private let registry: FlutterTextureRegistry
  private let textureUpdateCallback: TextureUpdateCallback
  private let worker: Worker = .init()
  private var width: Int64?
  private var height: Int64?
  private var texture: ResizableTextureProtocol!
  private var textureId: Int64 = -1
  private var currentSize: CGSize = CGSize.zero
  private var disposed: Bool = false
  /// gerdTV patch: the largest picture worth rendering, the screen's own pixels (long side, short side). A 4K
  /// stream on a phone was rendered and colour-converted at 4K every frame, then scaled down again by Flutter.
  private let maxPixels: CGSize = VideoOutput.screenPixels()

  init(
    handle: Int64,
    configuration: VideoOutputConfiguration,
    registry: FlutterTextureRegistry,
    textureUpdateCallback: @escaping TextureUpdateCallback
  ) {
    let handle = OpaquePointer(bitPattern: Int(handle))
    assert(handle != nil, "handle casting")

    self.handle = handle!
    width = configuration.width
    height = configuration.height
    enableHardwareAcceleration = configuration.enableHardwareAcceleration
    self.registry = registry
    self.textureUpdateCallback = textureUpdateCallback

    super.init()

    worker.enqueue {
      self._init()
    }
    #if canImport(UIKit)
      // gerdTV patch: no GL work while iOS has the app in the background (it kills apps that do it). Without PiP,
      // mpv's frames are dropped meanwhile (TextureHW.render), so sound plays on and the picture is back at once on
      // return. With mpv's picture in PiP, mpv switches to its software renderer at PiP size; that switch still
      // frees the GL renderer, which iOS allows during this notification, hence the wait (Worker.sync).
      // Debugging: "VideoOutput: background" in the log on each change.
      for (name, background) in [
        (UIApplication.didEnterBackgroundNotification, true),
        (UIApplication.willEnterForegroundNotification, false),
      ] {
        observers.append(
          NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            NSLog("VideoOutput: background \(background), PiP \(TextureHW.pipActive)")
            if background && TextureHW.pipActive {
              self.worker.sync { self.texture?.useSoftware(true) }
            } else if background {
              self.worker.enqueue { self.texture?.skipRendering = true }
            } else {
              self.worker.enqueue {
                self.texture?.useSoftware(false)
                self.texture?.skipRendering = false
              }
            }
          })
      }
    #endif
  }

  private var observers: [NSObjectProtocol] = []

  /// The screen's size in pixels as (long side, short side); read once on the main thread (the plugin creates
  /// VideoOutput there).
  private static func screenPixels() -> CGSize {
    #if canImport(UIKit)
      let screen = UIScreen.main.nativeBounds.size
    #else
      let frame = NSScreen.main?.frame.size ?? CGSize(width: 3840, height: 2160)
      let scale = NSScreen.main?.backingScaleFactor ?? 1
      let screen = CGSize(width: frame.width * scale, height: frame.height * scale)
    #endif
    return CGSize(width: max(screen.width, screen.height), height: min(screen.width, screen.height))
  }

  deinit {
    observers.forEach { NotificationCenter.default.removeObserver($0) }
    worker.cancel()

    disposed = true
    disposeTextureId()
  }

  public func setSize(width: Int64?, height: Int64?) {
    worker.enqueue {
      self.width = width
      self.height = height
    }
  }

  private func _init() {
    let enableHardwareAcceleration =
      VideoOutput.isSimulator ? false : enableHardwareAcceleration

    NSLog(
      "VideoOutput: enableHardwareAcceleration: \(enableHardwareAcceleration)"
    )

    if VideoOutput.isSimulator {
      NSLog(
        "VideoOutput: warning: hardware rendering is disabled in the iOS simulator, due to an incompatibility with OpenGL ES"
      )
    }

    if enableHardwareAcceleration {
      texture = SafeResizableTexture(
        TextureHW(
          handle: handle,
          // Use `weak self` to prevent memory leaks
          updateCallback: { [weak self]() in
            guard let that = self else {
              return
            }
            that.updateCallback()
          }
        )
      )
    } else {
      texture = SafeResizableTexture(
        TextureSW(
          handle: handle,
          // Use `weak self` to prevent memory leaks
          updateCallback: { [weak self]() in
            guard let that = self else {
              return
            }
            that.updateCallback()
          }
        )
      )
    }

    DispatchQueue.main.sync { [weak self]() in
      guard let that = self else {
        return
      }
      that.registerTextureId()
    }
  }

  // Must be run on the main thread
  private func registerTextureId() {
    // Textures must be registered on the platform thread.
    textureId = registry.register(texture)
    // textureUpdateCallback must run on the main thread
    textureUpdateCallback(textureId, CGSize(width: 0, height: 0))
  }

  private func disposeTextureId() {
    let registry_ = self.registry
    let textureId_ = self.textureId
    textureId = -1
    DispatchQueue.main.async {
      // Textures must be unregistered on the platform thread
      registry_.unregisterTexture(textureId_)
    }
  }

  public func updateCallback() {
    worker.enqueue {
      self._updateCallback()
    }
  }

  private func _updateCallback() {
    let size = videoSize

    if size.width == 0 || size.height == 0 {
      return
    }

    if currentSize != size {
      currentSize = size

      texture.resize(size)
      // gerdTV patch: async (sync blocked the worker on the main thread on every resize).
      DispatchQueue.main.async { [weak self] in
        guard let that = self else { return }
        // textureUpdateCallback must run on the main thread
        that.textureUpdateCallback(that.textureId, size)
      }
    }

    if disposed {
      return
    }

    // gerdTV patch: Flutter hears only about frames that were drawn, and asynchronously: the worker blocked on the
    // main thread for every frame before.
    if !texture.render(size) {
      return
    }
    let textureId = self.textureId
    DispatchQueue.main.async { [weak self] in
      guard let that = self, textureId >= 0 else { return }
      // Textures must be marked as available from the main thread
      that.registry.textureFrameAvailable(textureId)
    }
  }

    private var videoSize: CGSize {
        // fixed size
        if width != nil && height != nil {
            return CGSize(
                width: Double(width!),
                height: Double(height!)
            )
        }
        
        let params = MPVHelpers.getVideoOutParams(handle)
        return capped(CGSize(
            width: Double(width ?? (params.rotate == 0 || params.rotate == 180
                                    ? params.dw
                                    : params.dh)),
            height: Double(height ?? (params.rotate == 0 || params.rotate == 180
                                      ? params.dh
                                      : params.dw))
        ))
  }

  /// gerdTV patch: [size] scaled down, aspect kept, so it fits [maxPixels] in either orientation.
  private func capped(_ size: CGSize) -> CGSize {
    let long = max(size.width, size.height), short = min(size.width, size.height)
    let scale = min(1, maxPixels.width / max(long, 1), maxPixels.height / max(short, 1))
    if scale >= 1 { return size }
    // Even sizes: video surfaces dislike odd ones.
    return CGSize(width: (size.width * scale / 2).rounded() * 2, height: (size.height * scale / 2).rounded() * 2)
  }
}
