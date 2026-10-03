import Flutter
import Foundation

final class RuntimePerformanceBridge: NSObject, FlutterStreamHandler {
  private let methodChannel: FlutterMethodChannel
  private let eventChannel: FlutterEventChannel
  private var eventSink: FlutterEventSink?
  private var observers: [NSObjectProtocol] = []

  init(messenger: FlutterBinaryMessenger) {
    methodChannel = FlutterMethodChannel(
      name: "huahuoai/runtime_performance",
      binaryMessenger: messenger
    )
    eventChannel = FlutterEventChannel(
      name: "huahuoai/runtime_performance/events",
      binaryMessenger: messenger
    )
    super.init()
    methodChannel.setMethodCallHandler { call, result in
      guard call.method == "getState" else {
        result(FlutterMethodNotImplemented)
        return
      }
      result(Self.snapshot())
    }
    eventChannel.setStreamHandler(self)
  }

  deinit {
    stopObserving()
    methodChannel.setMethodCallHandler(nil)
    eventChannel.setStreamHandler(nil)
  }

  func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    eventSink = events
    startObserving()
    events(Self.snapshot())
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    stopObserving()
    return nil
  }

  private func startObserving() {
    guard observers.isEmpty else { return }
    let center = NotificationCenter.default
    for name in [
      ProcessInfo.thermalStateDidChangeNotification,
      Notification.Name.NSProcessInfoPowerStateDidChange,
    ] {
      observers.append(
        center.addObserver(forName: name, object: nil, queue: .main) {
          [weak self] _ in self?.emit()
        }
      )
    }
  }

  private func stopObserving() {
    let center = NotificationCenter.default
    observers.forEach(center.removeObserver)
    observers.removeAll()
  }

  private func emit() {
    guard let eventSink else { return }
    if Thread.isMainThread {
      eventSink(Self.snapshot())
    } else {
      DispatchQueue.main.async { [weak self] in
        self?.eventSink?(Self.snapshot())
      }
    }
  }

  private static func snapshot() -> [String: Any] {
    let thermal: String
    switch ProcessInfo.processInfo.thermalState {
    case .nominal: thermal = "nominal"
    case .fair: thermal = "fair"
    case .serious: thermal = "serious"
    case .critical: thermal = "critical"
    @unknown default: thermal = "unknown"
    }
    return [
      "thermal": thermal,
      "lowPower": ProcessInfo.processInfo.isLowPowerModeEnabled,
    ]
  }
}
