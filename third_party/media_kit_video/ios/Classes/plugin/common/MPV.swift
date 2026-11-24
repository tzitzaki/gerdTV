// gerdTV patch (third_party/README.md): the plugin calls libmpv through these functions, looked up at run time in
// the libmpv the app chose (Settings → Player engine, app/lib/platform/engine.dart), instead of linking
// Mpv.framework: media_kit's Mpv.framework, or gerdTV's GerdMpv.framework when the app set GERDTV_LIBMPV to it before
// starting media_kit. Both may be loaded in the process; each mpv handle must only meet its own library's functions.
// Debugging: "MPV: no <name> in <library>" in the log means that library isn't in the app or lacks the function.
import Foundation

enum MPV {
  /// The chosen library's name. getenv, not ProcessInfo's environment: Dart sets GERDTV_LIBMPV with setenv after the
  /// process started, and Foundation may hand out an earlier copy of the environment.
  private static let name: String = getenv("GERDTV_LIBMPV").map { String(cString: $0) } ?? "Mpv.framework/Mpv"

  /// The chosen library, as the Dart side opened it (it is loaded already; this just gets its handle).
  private static let library: UnsafeMutableRawPointer? = {
    guard let handle = dlopen(name, RTLD_NOW) else {
      NSLog("MPV: cannot open \(name)")
      exit(1)
    }
    return handle
  }()

  /// The function [symbolName] in the chosen library.
  private static func symbol<T>(_ symbolName: String, _: T.Type) -> T {
    guard let address = dlsym(library, symbolName) else {
      NSLog("MPV: no \(symbolName) in \(MPV.name)")
      exit(1)
    }
    return unsafeBitCast(address, to: T.self)
  }

  private typealias RenderContextCreate = @convention(c) (
    UnsafeMutablePointer<OpaquePointer?>?, OpaquePointer?, UnsafeMutablePointer<mpv_render_param>?
  ) -> CInt
  private typealias RenderContextSetUpdateCallback = @convention(c) (
    OpaquePointer?, mpv_render_update_fn?, UnsafeMutableRawPointer?
  ) -> Void
  private typealias RenderContextFree = @convention(c) (OpaquePointer?) -> Void
  private typealias RenderContextRender = @convention(c) (
    OpaquePointer?, UnsafeMutablePointer<mpv_render_param>?
  ) -> CInt
  private typealias FreeNodeContents = @convention(c) (UnsafeMutablePointer<mpv_node>?) -> Void
  private typealias ErrorString = @convention(c) (CInt) -> UnsafePointer<CChar>?
  private typealias GetProperty = @convention(c) (
    OpaquePointer?, UnsafePointer<CChar>?, mpv_format, UnsafeMutableRawPointer?
  ) -> CInt

  private static let renderContextCreateFn = symbol("mpv_render_context_create", RenderContextCreate.self)
  private static let renderContextSetUpdateCallbackFn = symbol(
    "mpv_render_context_set_update_callback", RenderContextSetUpdateCallback.self)
  private static let renderContextFreeFn = symbol("mpv_render_context_free", RenderContextFree.self)
  private static let renderContextRenderFn = symbol("mpv_render_context_render", RenderContextRender.self)
  private static let freeNodeContentsFn = symbol("mpv_free_node_contents", FreeNodeContents.self)
  private static let errorStringFn = symbol("mpv_error_string", ErrorString.self)
  private static let getPropertyFn = symbol("mpv_get_property", GetProperty.self)

  static func renderContextCreate(
    _ res: UnsafeMutablePointer<OpaquePointer?>?, _ mpv: OpaquePointer?,
    _ params: UnsafeMutablePointer<mpv_render_param>?
  ) -> CInt { renderContextCreateFn(res, mpv, params) }

  static func renderContextSetUpdateCallback(
    _ ctx: OpaquePointer?, _ callback: mpv_render_update_fn?, _ data: UnsafeMutableRawPointer?
  ) { renderContextSetUpdateCallbackFn(ctx, callback, data) }

  static func renderContextFree(_ ctx: OpaquePointer?) { renderContextFreeFn(ctx) }

  static func renderContextRender(
    _ ctx: OpaquePointer?, _ params: UnsafeMutablePointer<mpv_render_param>?
  ) -> CInt { renderContextRenderFn(ctx, params) }

  static func freeNodeContents(_ node: UnsafeMutablePointer<mpv_node>?) { freeNodeContentsFn(node) }

  static func errorString(_ error: CInt) -> UnsafePointer<CChar> { errorStringFn(error)! }

  static func getProperty(
    _ mpv: OpaquePointer?, _ name: UnsafePointer<CChar>?, _ format: mpv_format, _ data: UnsafeMutableRawPointer?
  ) -> CInt { getPropertyFn(mpv, name, format, data) }
}
