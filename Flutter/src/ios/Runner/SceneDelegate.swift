import Flutter
import UIKit

func incomingMaterialFileURLs(from urls: [URL]) -> [URL] {
  urls.filter(\.isFileURL)
}

func isIncomingMaterialShareSignal(_ url: URL) -> Bool {
  url.scheme?.lowercased() == "huahuoai" &&
    url.host?.lowercased() == "incoming-materials" &&
    (url.path.isEmpty || url.path == "/")
}

class SceneDelegate: FlutterSceneDelegate {
  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    let urls = connectionOptions.urlContexts.map(\.url)
    if urls.contains(where: isIncomingMaterialShareSignal) {
      NativeFilePickerBridge.enqueueSharedIncomingMaterials()
    }
    NativeFilePickerBridge.enqueueIncomingURLs(
      incomingMaterialFileURLs(from: urls)
    )
    super.scene(scene, willConnectTo: session, options: connectionOptions)
  }

  override func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    let externalFiles = incomingMaterialFileURLs(from: URLContexts.map(\.url))
    NativeFilePickerBridge.enqueueIncomingURLs(externalFiles)
    let shareSignalContexts = URLContexts.filter {
      isIncomingMaterialShareSignal($0.url)
    }
    if !shareSignalContexts.isEmpty {
      NativeFilePickerBridge.enqueueSharedIncomingMaterials()
    }
    let nonFileContexts = Set(URLContexts.filter {
      !$0.url.isFileURL && !isIncomingMaterialShareSignal($0.url)
    })
    if !nonFileContexts.isEmpty {
      super.scene(scene, openURLContexts: nonFileContexts)
    }
  }

  override func sceneDidBecomeActive(_ scene: UIScene) {
    NativeFilePickerBridge.enqueueSharedIncomingMaterials()
    super.sceneDidBecomeActive(scene)
  }
}
