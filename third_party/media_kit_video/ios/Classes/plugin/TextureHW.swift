import Flutter
import OpenGLES

public class TextureHW: NSObject, FlutterTexture, ResizableTextureProtocol {
  public typealias UpdateCallback = () -> Void

  private let handle: OpaquePointer
  private let updateCallback: UpdateCallback
  private let context: EAGLContext
  private let textureCache: CVOpenGLESTextureCache
  private var renderContext: OpaquePointer?
  private var textureContexts = SwappableObjectManager<TextureGLESContext>(
    objects: [],
    skipCheckArgs: true
  )

  init(
    handle: OpaquePointer,
    updateCallback: @escaping UpdateCallback
  ) {
    self.handle = handle
    self.updateCallback = updateCallback
    self.context = OpenGLESHelpers.createContext()
    self.textureCache = OpenGLESHelpers.createTextureCache(context)

    super.init()

    self.initMPV()
  }

  deinit {
    disposePixelBuffer()
    disposeMPV()
    OpenGLESHelpers.deleteTextureCache(textureCache)

    // Deleting the context may cause potential RAM or VRAM memory leaks, as it
    // is used in the `deinit` method of the `TextureGLESContext`.
    // Potential fix: use a counter, and delete it only when the counter reaches
    // zero
    OpenGLESHelpers.deleteContext(context)
  }

  public func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    let textureContext = textureContexts.current
    if textureContext == nil {
      return nil
    }

    return Unmanaged.passRetained(textureContext!.pixelBuffer)
  }

  private func initMPV() {
    EAGLContext.setCurrent(context)
    defer {
      OpenGLESHelpers.checkError("initMPV")
      EAGLContext.setCurrent(nil)
    }

    let api = UnsafeMutableRawPointer(
      mutating: (MPV_RENDER_API_TYPE_OPENGL as NSString).utf8String
    )
    var procAddress = mpv_opengl_init_params(
      get_proc_address: {
        (ctx, name) in
        return TextureHW.getProcAddress(ctx, name)
      },
      get_proc_address_ctx: nil
    )

    var params: [mpv_render_param] = withUnsafeMutableBytes(of: &procAddress) {
      procAddress in
      return [
        mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: api),
        mpv_render_param(
          type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS,
          data: procAddress.baseAddress.map {
            UnsafeMutableRawPointer($0)
          }
        ),
        mpv_render_param(),
      ]
    }

    MPVHelpers.checkError(
      MPV.renderContextCreate(&renderContext, handle, &params)
    )
    setUpdateCallback()
  }

  private func setUpdateCallback() {
    MPV.renderContextSetUpdateCallback(
      renderContext,
      { (ctx) in
        // gerdTV patch: straight to VideoOutput's worker (it only enqueues), not through the main thread first:
        // a busy UI thread no longer delays every video frame.
        let that = unsafeBitCast(ctx, to: TextureHW.self)
        that.updateCallback()
      },
      UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
    )
  }

  private func disposeMPV() {
    EAGLContext.setCurrent(context)
    defer {
      OpenGLESHelpers.checkError("disposeMPV")
      EAGLContext.setCurrent(nil)
    }

    MPV.renderContextSetUpdateCallback(renderContext, nil, nil)
    MPV.renderContextFree(renderContext)
  }

  public func resize(_ size: CGSize) {
    if size.width == 0 || size.height == 0 {
      return
    }

    NSLog("TextureGL: resize: \(size.width)x\(size.height)")
    createPixelBuffer(size)
    // gerdTV patch: frees the old buffers' cached textures now, not when the cache goes.
    CVOpenGLESTextureCacheFlush(textureCache, 0)
    needsDraw = true  // the new buffers are empty: draw even without a new frame (e.g. paused, rotated)
  }

  private func createPixelBuffer(_ size: CGSize) {
    disposePixelBuffer()

    textureContexts.reinit(
      objects: [
        TextureGLESContext(
          context: context,
          textureCache: textureCache,
          size: size
        ),
        TextureGLESContext(
          context: context,
          textureCache: textureCache,
          size: size
        ),
        TextureGLESContext(
          context: context,
          textureCache: textureCache,
          size: size
        ),
      ],
      skipCheckArgs: true
    )
  }

  private func disposePixelBuffer() {
    textureContexts.reinit(objects: [], skipCheckArgs: true)
  }

  /// gerdTV patch: see ResizableTextureProtocol.
  public var skipRendering = false
  private var needsDraw = false

  // gerdTV patch: iOS Picture-in-Picture of mpv's picture (app/ios/Runner/AppDelegate.swift). Every drawn frame also
  // goes to [pipSink]. In the background with PiP showing ([pipActive]) GL is not allowed, so mpv renders in software
  // at PiP size instead ([useSoftware]); switching renderers rebuilds mpv's video output from its cache (a short
  // picture hiccup, no network work). Debugging: "TextureHW: software" in the log on each switch.
  public static var pipSink: ((CVPixelBuffer) -> Void)?
  public static var pipActive = false
  private var software = false
  private var pool: CVPixelBufferPool?
  private var poolSize = CGSize.zero
  private static let bgr0 = strdup("bgr0")

  public func useSoftware(_ on: Bool) {
    guard on != software else { return }
    NSLog("TextureHW: software \(on)")
    // Freeing a render context ends mpv's video chain; selecting the track again rebuilds it on the new renderer.
    let vid = MPV.getPropertyString(handle, "vid")
    disposeMPV()
    software = on
    if on {
      var params: [mpv_render_param] = [
        mpv_render_param(
          type: MPV_RENDER_PARAM_API_TYPE,
          data: UnsafeMutableRawPointer(mutating: (MPV_RENDER_API_TYPE_SW as NSString).utf8String)
        ),
        mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
      ]
      MPVHelpers.checkError(MPV.renderContextCreate(&renderContext, handle, &params))
      setUpdateCallback()
    } else {
      initMPV()
    }
    if let vid, vid != "no" {
      MPV.setPropertyString(handle, "vid", "no")
      MPV.setPropertyString(handle, "vid", vid)
    }
    needsDraw = true
  }

  /// One software frame for PiP: the picture's aspect within 640×360 (CPU work for every frame).
  private func renderSoftware(_ size: CGSize) -> Bool {
    guard TextureHW.pipActive, let sink = TextureHW.pipSink,
      MPV.renderContextUpdate(renderContext) & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue) != 0
    else { return false }
    let scale = min(1, 640 / max(size.width, 1), 360 / max(size.height, 1))
    let w = Int((size.width * scale / 2).rounded() * 2)
    let h = Int((size.height * scale / 2).rounded() * 2)
    if pool == nil || poolSize != CGSize(width: w, height: h) {
      let attrs: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: w,
        kCVPixelBufferHeightKey as String: h,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
      ]
      pool = nil
      CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
      poolSize = CGSize(width: w, height: h)
    }
    var out: CVPixelBuffer?
    guard let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let buffer = out
    else { return false }
    CVPixelBufferLockBaseAddress(buffer, [])
    guard let base = CVPixelBufferGetBaseAddress(buffer) else {
      CVPixelBufferUnlockBaseAddress(buffer, [])
      return false
    }
    var stride = CVPixelBufferGetBytesPerRow(buffer)
    var dims: [Int32] = [Int32(w), Int32(h)]
    dims.withUnsafeMutableBufferPointer { dimsPtr in
      withUnsafeMutablePointer(to: &stride) { stridePtr in
        var params: [mpv_render_param] = [
          mpv_render_param(type: MPV_RENDER_PARAM_SW_SIZE, data: UnsafeMutableRawPointer(dimsPtr.baseAddress)),
          mpv_render_param(type: MPV_RENDER_PARAM_SW_FORMAT, data: UnsafeMutableRawPointer(TextureHW.bgr0)),
          mpv_render_param(type: MPV_RENDER_PARAM_SW_STRIDE, data: UnsafeMutableRawPointer(stridePtr)),
          mpv_render_param(type: MPV_RENDER_PARAM_SW_POINTER, data: base),
          mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
        ]
        _ = MPV.renderContextRender(renderContext, &params)
      }
    }
    // "bgr0" leaves the alpha byte at 0, which a video layer would show as transparent.
    let bytes = base.assumingMemoryBound(to: UInt8.self)
    for y in 0..<h {
      let row = bytes + y * stride
      for x in 0..<w {
        row[x * 4 + 3] = 255
      }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    sink(buffer)
    return false  // Flutter's texture is not shown in the background
  }

  /// gerdTV patch: returns whether a new picture was drawn. mpv's update callback also fires for work that has no
  /// new frame; drawing then repeated the last frame for nothing. While [skipRendering] is set nothing is called at
  /// all: even mpv's skip-rendering mode reconfigures its GL renderer on a new stream. mpv then drops each frame after
  /// 200 ms (log: "mpv_render_context_render() not being called"); sound plays on, decoding continues.
  public func render(_ size: CGSize) -> Bool {
    if skipRendering {
      return false
    }
    if software {
      return renderSoftware(size)
    }

    EAGLContext.setCurrent(context)
    defer {
      OpenGLESHelpers.checkError("render")
      EAGLContext.setCurrent(nil)
    }

    // mpv_render_context_update runs mpv's pending render-thread work (which may use GL, hence after making the
    // context current) and says whether a new frame waits.
    if MPV.renderContextUpdate(renderContext) & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue) == 0 && !needsDraw {
      return false
    }

    let textureContext = textureContexts.nextAvailable()
    if textureContext == nil {
      return false
    }
    needsDraw = false

    glBindFramebuffer(GLenum(GL_FRAMEBUFFER), textureContext!.frameBuffer)
    defer {
      glBindFramebuffer(GLenum(GL_FRAMEBUFFER), 0)
    }

    var fbo = mpv_opengl_fbo(
      fbo: Int32(textureContext!.frameBuffer),
      w: Int32(size.width),
      h: Int32(size.height),
      internal_format: 0
    )
    // gerdTV patch: the pointer is used inside the closure only (it escaped it before: undefined behaviour).
    withUnsafeMutablePointer(to: &fbo) { fboPtr in
      var params: [mpv_render_param] = [
        mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: fboPtr),
        mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
      ]
      _ = MPV.renderContextRender(renderContext, &params)
    }

    glFlush()

    textureContexts.pushAsReady(textureContext!)
    TextureHW.pipSink?(textureContext!.pixelBuffer)
    return true
  }

  static private func getProcAddress(
    _ ctx: UnsafeMutableRawPointer?,
    _ name: UnsafePointer<Int8>?
  ) -> UnsafeMutableRawPointer? {
    let symbol: CFString = CFStringCreateWithCString(
      kCFAllocatorDefault,
      name,
      kCFStringEncodingASCII
    )
    let indentifier = CFBundleGetBundleWithIdentifier(
      "com.apple.opengles" as CFString
    )
    let addr = CFBundleGetFunctionPointerForName(indentifier, symbol)

    if addr == nil {
      NSLog("Cannot get OpenGLES function pointer!")
    }
    return addr
  }
}
