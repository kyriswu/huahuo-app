import AVFoundation
import CoreBluetooth
import Flutter
import Photos
import UIKit
import UserNotifications

final class PlatformPermissionsBridge: NSObject, CBCentralManagerDelegate {
  private static let channelName = "huahuoai/platform_permissions"
  private var bluetoothManager: CBCentralManager?
  private var bluetoothPermissionResult: FlutterResult?
  private var bluetoothPermissionTimeout: DispatchWorkItem?

  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: messenger
    )
    let bridge = PlatformPermissionsBridge()
    channel.setMethodCallHandler { call, result in
      bridge.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getPermissionStatuses":
      getPermissionStatuses(result)
    case "requestPermissions":
      requestPermissions(call.arguments, result: result)
    case "openAppSettings":
      openAppSettings(result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func requestPermissions(
    _ arguments: Any?,
    result: @escaping FlutterResult
  ) {
    guard let args = arguments as? [String: Any],
          let kinds = args["kinds"] as? [String],
          kinds.count == 1,
          let kind = kinds.first
    else {
      result(
        FlutterError(
          code: "PLATFORM_PERMISSION_REQUEST_INVALID",
          message: "Exactly one permission must be requested on iOS.",
          details: nil
        )
      )
      return
    }

    switch kind {
    case "notification":
      requestNotificationPermission(result)
    case "microphone":
      requestMicrophonePermission(result)
    case "camera":
      requestCameraPermission(result)
    case "media_library":
      requestMediaLibraryPermission(result)
    case "bluetooth":
      requestBluetoothPermission(result)
    default:
      result(
        FlutterError(
          code: "PLATFORM_PERMISSION_REQUEST_INVALID",
          message: "The requested permission is not independently requestable on iOS.",
          details: nil
        )
      )
    }
  }

  private func requestNotificationPermission(_ result: @escaping FlutterResult) {
    UNUserNotificationCenter.current().requestAuthorization(
      options: [.alert, .sound, .badge]
    ) { granted, error in
      if error != nil {
        DispatchQueue.main.async {
          result(
            FlutterError(
              code: "NOTIFICATION_PERMISSION_REQUEST_FAILED",
              message: "Notification permission could not be requested.",
              details: nil
            )
          )
        }
        return
      }
      DispatchQueue.main.async {
        if granted {
          UIApplication.shared.registerForRemoteNotifications()
        }
        self.getPermissionStatuses(result)
      }
    }
  }

  private func requestMicrophonePermission(_ result: @escaping FlutterResult) {
    AVAudioSession.sharedInstance().requestRecordPermission { _ in
      DispatchQueue.main.async {
        self.getPermissionStatuses(result)
      }
    }
  }

  private func requestCameraPermission(_ result: @escaping FlutterResult) {
    AVCaptureDevice.requestAccess(for: .video) { _ in
      DispatchQueue.main.async {
        self.getPermissionStatuses(result)
      }
    }
  }

  private func requestMediaLibraryPermission(_ result: @escaping FlutterResult) {
    PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in
      DispatchQueue.main.async {
        self.getPermissionStatuses(result)
      }
    }
  }

  private func requestBluetoothPermission(_ result: @escaping FlutterResult) {
    guard bluetoothPermissionResult == nil else {
      result(
        FlutterError(
          code: "PLATFORM_PERMISSION_REQUEST_IN_PROGRESS",
          message: "A Bluetooth permission request is already active.",
          details: nil
        )
      )
      return
    }
    guard bluetoothStatus() == "not_determined" else {
      getPermissionStatuses(result)
      return
    }

    bluetoothPermissionResult = result
    bluetoothManager = CBCentralManager(
      delegate: self,
      queue: .main,
      options: [CBCentralManagerOptionShowPowerAlertKey: false]
    )
    let timeout = DispatchWorkItem { [weak self] in
      guard let self, let pending = self.bluetoothPermissionResult else { return }
      self.clearBluetoothPermissionRequest()
      pending(
        FlutterError(
          code: "PLATFORM_PERMISSION_REQUEST_TIMEOUT",
          message: "Bluetooth permission did not return in time.",
          details: nil
        )
      )
    }
    bluetoothPermissionTimeout = timeout
    DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: timeout)
  }

  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    guard bluetoothPermissionResult != nil,
          bluetoothStatus() != "not_determined"
    else { return }
    let pending = bluetoothPermissionResult
    clearBluetoothPermissionRequest()
    if let pending {
      getPermissionStatuses(pending)
    }
  }

  private func clearBluetoothPermissionRequest() {
    bluetoothPermissionTimeout?.cancel()
    bluetoothPermissionTimeout = nil
    bluetoothPermissionResult = nil
    bluetoothManager = nil
  }

  private func getPermissionStatuses(_ result: @escaping FlutterResult) {
    var statuses: [String: String] = [
      "bluetooth": bluetoothStatus(),
      "nearby_devices": "unavailable",
      "microphone": microphoneStatus(),
      "camera": cameraStatus(),
      "media_library": mediaLibraryStatus(),
      // iOS has no public general local-network authorization query.
      "local_network": "system_managed",
    ]

    UNUserNotificationCenter.current().getNotificationSettings { settings in
      statuses["notification"] = Self.notificationStatus(settings.authorizationStatus)
      DispatchQueue.main.async {
        result(statuses)
      }
    }
  }

  private func openAppSettings(_ result: @escaping FlutterResult) {
    guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else {
      result(false)
      return
    }
    DispatchQueue.main.async {
      UIApplication.shared.open(settingsURL, options: [:]) { opened in
        result(opened)
      }
    }
  }

  private func bluetoothStatus() -> String {
    guard #available(iOS 13.1, *) else {
      return "unavailable"
    }
    switch CBManager.authorization {
    case .allowedAlways:
      return "granted"
    case .notDetermined:
      return "not_determined"
    case .denied:
      return "blocked"
    case .restricted:
      return "blocked"
    @unknown default:
      return "unavailable"
    }
  }

  private func microphoneStatus() -> String {
    switch AVAudioSession.sharedInstance().recordPermission {
    case .granted:
      return "granted"
    case .undetermined:
      return "not_determined"
    case .denied:
      return "blocked"
    @unknown default:
      return "unavailable"
    }
  }

  private func cameraStatus() -> String {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
      return "granted"
    case .notDetermined:
      return "not_determined"
    case .denied, .restricted:
      return "blocked"
    @unknown default:
      return "unavailable"
    }
  }

  private func mediaLibraryStatus() -> String {
    switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
    case .authorized, .limited:
      return "granted"
    case .notDetermined:
      return "not_determined"
    case .denied, .restricted:
      return "blocked"
    @unknown default:
      return "unavailable"
    }
  }

  private static func notificationStatus(_ status: UNAuthorizationStatus) -> String {
    switch status {
    case .authorized, .provisional, .ephemeral:
      return "granted"
    case .notDetermined:
      return "not_determined"
    case .denied:
      return "blocked"
    @unknown default:
      return "unavailable"
    }
  }
}
