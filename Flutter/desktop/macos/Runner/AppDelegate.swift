import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func application(_ application: NSApplication, open urls: [URL]) {
    DesktopIncomingDocumentBridge.enqueue(urls)
  }

  override func application(_ sender: NSApplication, openFiles filenames: [String]) {
    DesktopIncomingDocumentBridge.enqueue(
      filenames.map { URL(fileURLWithPath: $0) }
    )
    sender.reply(toOpenOrPrint: .success)
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}

final class DesktopIncomingDocumentBridge: NSObject, FlutterStreamHandler {
  private static let channelName = "huahuo_desktop/incoming_documents"
  private static var shared: DesktopIncomingDocumentBridge?
  private static var pendingPaths: [String] = []
  private static var activeSecurityScopedURLs: [URL] = []

  private let eventChannel: FlutterEventChannel
  private var eventSink: FlutterEventSink?

  static func register(with messenger: FlutterBinaryMessenger) {
    guard shared == nil else { return }
    shared = DesktopIncomingDocumentBridge(messenger: messenger)
  }

  static func enqueue(_ urls: [URL]) {
    let paths = urls.compactMap { url -> String? in
      guard url.isFileURL else { return nil }
      if url.startAccessingSecurityScopedResource() {
        activeSecurityScopedURLs.append(url)
      }
      return url.standardizedFileURL.path
    }
    guard !paths.isEmpty else { return }
    if let shared, shared.eventSink != nil {
      shared.emit(paths)
      return
    }
    appendPending(paths)
  }

  private init(messenger: FlutterBinaryMessenger) {
    eventChannel = FlutterEventChannel(
      name: Self.channelName,
      binaryMessenger: messenger
    )
    super.init()
    eventChannel.setStreamHandler(self)
  }

  func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    eventSink = events
    let paths = Self.pendingPaths
    Self.pendingPaths.removeAll()
    emit(paths)
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  private func emit(_ paths: [String]) {
    guard let eventSink else {
      Self.appendPending(paths)
      return
    }
    for path in paths {
      eventSink(path)
    }
  }

  private static func appendPending(_ paths: [String]) {
    for path in paths where !pendingPaths.contains(path) {
      pendingPaths.append(path)
    }
  }
}
