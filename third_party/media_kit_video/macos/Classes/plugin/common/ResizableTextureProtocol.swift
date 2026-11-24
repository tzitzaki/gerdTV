#if canImport(Flutter)
  import Flutter
#elseif canImport(FlutterMacOS)
  import FlutterMacOS
#endif

public protocol ResizableTextureProtocol: NSObject, FlutterTexture {
  func resize(_ size: CGSize)
  /// gerdTV patch: draws mpv's next frame; false when nothing new was drawn (no frame, or skipped).
  func render(_ size: CGSize) -> Bool
  /// gerdTV patch: set while iOS has the app in the background, where GL calls get the app killed.
  var skipRendering: Bool { get set }
  /// gerdTV patch: iOS background Picture-in-Picture: mpv's software renderer instead of GL (see TextureHW).
  func useSoftware(_ on: Bool)
}
