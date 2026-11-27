import Flutter
import UIKit

// Device pairing: the system camera scanned another device's QR, a gerdtv://pair?a=…&c=… link (CFBundleURLTypes in
// Info.plist). It arrives here, at a cold start in the connection options, otherwise as an open-URL call; both go to
// Dart through the platform channel (GerdtvPlatform.pairLink). super is called first, so plugins still get theirs.
class SceneDelegate: FlutterSceneDelegate {
  override func scene(
    _ scene: UIScene, willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    super.scene(scene, willConnectTo: session, options: connectionOptions)
    if let url = connectionOptions.urlContexts.first?.url { GerdtvPlatform.pairLink(url) }
  }

  override func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    super.scene(scene, openURLContexts: URLContexts)
    if let url = URLContexts.first?.url { GerdtvPlatform.pairLink(url) }
  }
}
