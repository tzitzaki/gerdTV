import FlutterMacOS
import OpenGL.GL
import OpenGL.GL3

public class TextureHW: NSObject, FlutterTexture, ResizableTextureProtocol {
  public typealias UpdateCallback = () -> Void

  private let handle: OpaquePointer
  private let updateCallback: UpdateCallback
  private let pixelFormat: CGLPixelFormatObj
  private let context: CGLContextObj
  private let textureCache: CVOpenGLTextureCache
  private var renderContext: OpaquePointer?
  private var textureContexts = SwappableObjectManager<TextureGLContext>(
    objects: [],
    skipCheckArgs: true
  )

  init(
    handle: OpaquePointer,
    updateCallback: @escaping UpdateCallback
  ) {
    self.handle = handle
    self.updateCallback = updateCallback
    self.pixelFormat = OpenGLHelpers.createPixelFormat()
    self.context = OpenGLHelpers.createContext(pixelFormat)
    self.textureCache = OpenGLHelpers.createTextureCache(context, pixelFormat)

    super.init()

    self.initMPV()
  }

  deinit {
    disposePixelBuffer()
    disposeMPV()
    OpenGLHelpers.deleteTextureCache(textureCache)
    OpenGLHelpers.deletePixelFormat(pixelFormat)

    // Deleting the context may cause potential RAM or VRAM memory leaks, as it
    // is used in the `deinit` method of the `TextureGLContext`.
    // Potential fix: use a counter, and delete it only when the counter reaches
    // zero
    OpenGLHelpers.deleteContext(context)
  }

  public func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    let textureContext = textureContexts.current
    if textureContext == nil {
      return nil
    }

    return Unmanaged.passRetained(textureContext!.pixelBuffer)
  }

  private func initMPV() {
    CGLSetCurrentContext(context)
    defer {
      OpenGLHelpers.checkError("initMPV")
      CGLSetCurrentContext(nil)
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
    CGLSetCurrentContext(context)
    defer {
      OpenGLHelpers.checkError("disposeMPV")
      CGLSetCurrentContext(nil)
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
    CVOpenGLTextureCacheFlush(textureCache, 0)
    needsDraw = true  // the new buffers are empty: draw even without a new frame (e.g. paused, rotated)
  }

  private func createPixelBuffer(_ size: CGSize) {
    disposePixelBuffer()

    textureContexts.reinit(
      objects: [
        TextureGLContext(
          context: context,
          textureCache: textureCache,
          size: size
        ),
        TextureGLContext(
          context: context,
          textureCache: textureCache,
          size: size
        ),
        TextureGLContext(
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

  /// gerdTV patch: see ResizableTextureProtocol (iOS only; macOS renders with GL in the background too).
  public var skipRendering = false

  public func useSoftware(_ on: Bool) {}
  private var needsDraw = false

  /// gerdTV patch: returns whether a new picture was drawn. mpv's update callback also fires for work that has no
  /// new frame; drawing then repeated the last frame for nothing. While [skipRendering] is set nothing is called at
  /// all: even mpv's skip-rendering mode reconfigures its GL renderer on a new stream. mpv then drops each frame after
  /// 200 ms (log: "mpv_render_context_render() not being called"); sound plays on, decoding continues.
  public func render(_ size: CGSize) -> Bool {
    if skipRendering {
      return false
    }

    CGLSetCurrentContext(context)
    defer {
      OpenGLHelpers.checkError("render")
      CGLSetCurrentContext(nil)
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
      "com.apple.opengl" as CFString
    )
    let addr = CFBundleGetFunctionPointerForName(indentifier, symbol)

    if addr == nil {
      NSLog("Cannot get OpenGL function pointer!")
    }
    return addr
  }
}
