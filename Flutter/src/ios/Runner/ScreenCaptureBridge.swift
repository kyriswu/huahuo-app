import AVFoundation
import CryptoKit
import Flutter
import ReplayKit
import UIKit
import UniformTypeIdentifiers

final class ScreenCaptureBridge: NSObject, FlutterStreamHandler, UIDocumentPickerDelegate {
  private let methodChannel: FlutterMethodChannel
  private let eventChannel: FlutterEventChannel
  private var eventSink: FlutterEventSink?
  private var pollTimer: Timer?
  private var broadcastPicker: RPSystemBroadcastPickerView?
  private var processingCompletion = false
  private var state = "idle"
  private var activeSessionID: String?
  private var startedAt: Date?
  private var requestedAt: Date?
  private var stoppingAt: Date?
  private var audioExports = Set<String>()
  private var fixedElapsedSeconds = 0
  private var completedMedia: [String: Any]?
  private var errorCode: String?
  private var pendingImport: (sessionID: String, result: FlutterResult)?

  init(messenger: FlutterBinaryMessenger) {
    methodChannel = FlutterMethodChannel(
      name: "huahuoai/screen_capture",
      binaryMessenger: messenger
    )
    eventChannel = FlutterEventChannel(
      name: "huahuoai/screen_capture/events",
      binaryMessenger: messenger
    )
    super.init()
    methodChannel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call: call, result: result)
    }
    eventChannel.setStreamHandler(self)
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(applicationDidBecomeActive),
      name: UIApplication.didBecomeActiveNotification,
      object: nil
    )
  }

  deinit {
    pollTimer?.invalidate()
    NotificationCenter.default.removeObserver(self)
  }

  func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    eventSink = events
    events(snapshot())
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getCapability":
      result(capability())
    case "getState":
      pollManifest()
      result(pendingImport.map { importingSnapshot($0.sessionID) } ?? snapshot())
    case "getSession":
      guard let sessionID = Self.sessionID(call.arguments) else {
        result(error("SCREEN_CAPTURE_REQUEST_INVALID", "Invalid session.")); return
      }
      pollManifest()
      if pendingImport?.sessionID == sessionID { result(importingSnapshot(sessionID)) }
      else if activeSessionID == sessionID { result(snapshot()) }
      else {
        do { result(try Self.readSession(sessionID) ?? ["state": "idle", "elapsedSeconds": 0, "sessionId": sessionID]) }
        catch { result(self.error("SCREEN_CAPTURE_STATE_UNAVAILABLE", "Session could not be read.")) }
      }
    case "importVideo":
      importVideo(call.arguments, result: result)
    case "releaseSession":
      releaseSession(call.arguments, result: result)
    case "startCapture":
      startCapture(call.arguments as? [String: Any], result: result)
    case "stopCapture":
      stopCapture(call.arguments as? [String: Any], result: result)
    case "extractAudio":
      extractAudio(call.arguments as? [String: Any], result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private static func sessionID(_ arguments: Any?) -> String? {
    guard let value = (arguments as? [String: Any])?["sessionId"] as? String,
      value.range(of: "^[A-Za-z0-9_-]{1,100}$", options: .regularExpression) != nil else { return nil }
    return value
  }

  private func importingSnapshot(_ sessionID: String) -> [String: Any] {
    ["state": "importing", "sessionId": sessionID, "elapsedSeconds": 0]
  }

  private static func sessionURL(_ sessionID: String) throws -> URL {
    guard sessionID.range(of: "^[A-Za-z0-9_-]{1,100}$", options: .regularExpression) != nil else {
      throw CapturePreparationError.invalidMedia
    }
    let directory = try screenCapturesDirectory().appendingPathComponent("Sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("\(sessionID).json")
  }

  private static func readSession(_ sessionID: String) throws -> [String: Any]? {
    let url = try sessionURL(sessionID)
    if !FileManager.default.fileExists(atPath: url.path) { return nil }
    let payload = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    guard payload?["sessionId"] as? String == sessionID else { throw CapturePreparationError.invalidMedia }
    return payload
  }

  private static func saveSession(_ payload: [String: Any]) throws {
    guard let sessionID = payload["sessionId"] as? String else { throw CapturePreparationError.invalidMedia }
    try JSONSerialization.data(withJSONObject: payload).write(to: sessionURL(sessionID), options: .atomic)
  }

  private func importVideo(_ arguments: Any?, result: @escaping FlutterResult) {
    guard let sessionID = Self.sessionID(arguments) else {
      result(error("SCREEN_CAPTURE_REQUEST_INVALID", "Invalid session.")); return
    }
    pollManifest()
    guard pendingImport == nil, !["starting", "recording", "stopping"].contains(state),
      let presenter = Self.topViewController(), presenter.presentedViewController == nil else {
      result(error("SCREEN_CAPTURE_ALREADY_ACTIVE", "Another capture or picker is active.")); return
    }
    do {
      guard try Self.readSession(sessionID) == nil else { throw CapturePreparationError.invalidMedia }
      try Self.saveSession(["state": "failed", "sessionId": sessionID, "elapsedSeconds": 0,
        "errorCode": "SCREEN_CAPTURE_IMPORT_INTERRUPTED"])
    } catch {
      result(self.error("SCREEN_CAPTURE_IMPORT_FAILED", "Session is not available.")); return
    }
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.mpeg4Movie], asCopy: false)
    picker.delegate = self
    picker.allowsMultipleSelection = false
    pendingImport = (sessionID, result)
    presenter.present(picker, animated: true)
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    guard let pending = pendingImport else { return }
    pendingImport = nil
    let payload: [String: Any] = ["state": "failed", "elapsedSeconds": 0, "sessionId": pending.sessionID,
      "errorCode": "SCREEN_CAPTURE_CONSENT_CANCELLED"]
    try? Self.saveSession(payload)
    pending.result(payload)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard let pending = pendingImport else { return }
    guard let source = urls.first else { documentPickerWasCancelled(controller); return }
    DispatchQueue.global(qos: .utility).async {
      let accessed = source.startAccessingSecurityScopedResource()
      defer { if accessed { source.stopAccessingSecurityScopedResource() } }
      do {
        var coordinated: Result<[String: Any], Error>?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { url in
          coordinated = Result { try Self.copyImportedVideo(url, sessionID: pending.sessionID) }
        }
        if let coordinationError { throw coordinationError }
        guard let coordinated else { throw CapturePreparationError.storage }
        let payload = try coordinated.get()
        try Self.saveSession(payload)
        DispatchQueue.main.async {
          self.pendingImport = nil
          pending.result(payload)
        }
      } catch {
        if let directory = try? Self.screenCapturesDirectory() {
          try? FileManager.default.removeItem(at: directory.appendingPathComponent("import-\(pending.sessionID).mp4"))
        }
        DispatchQueue.main.async {
          self.pendingImport = nil
          pending.result(self.error("SCREEN_CAPTURE_IMPORT_FAILED", "Could not import this MP4 video."))
        }
      }
    }
  }

  private static func copyImportedVideo(_ source: URL, sessionID: String) throws -> [String: Any] {
    let directory = try screenCapturesDirectory()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let name = "import-\(sessionID).mp4"
    let destination = directory.appendingPathComponent(name)
    let part = directory.appendingPathComponent("\(name).part")
    defer { try? FileManager.default.removeItem(at: part) }
    FileManager.default.createFile(atPath: part.path, contents: nil)
    let input = try FileHandle(forReadingFrom: source)
    defer { try? input.close() }
    let output = try FileHandle(forWritingTo: part)
    defer { try? output.close() }
    var size = 0
    while let bytes = try input.read(upToCount: 1024 * 1024), !bytes.isEmpty {
      size += bytes.count
      guard size <= 500 * 1024 * 1024 else { throw CapturePreparationError.invalidMedia }
      try output.write(contentsOf: bytes)
    }
    try output.synchronize()
    let asset = AVURLAsset(url: part)
    let seconds = CMTimeGetSeconds(asset.duration)
    guard size > 0, seconds.isFinite, seconds >= 3, seconds <= 1800,
      !asset.tracks(withMediaType: .video).isEmpty, !asset.tracks(withMediaType: .audio).isEmpty else {
      throw CapturePreparationError.invalidMedia
    }
    let checksum = try sha256Hex(part)
    try FileManager.default.moveItem(at: part, to: destination)
    return ["state": "completed", "sessionId": sessionID, "elapsedSeconds": Int(seconds), "media": [
      "appPrivateUri": "app-private-media://screen-capture/\(name)", "fileName": name,
      "mimeType": "video/mp4", "durationSeconds": Int(seconds), "sizeBytes": size,
      "sha256": checksum, "recordedAt": isoFormatter.string(from: Date())
    ]]
  }

  private func releaseSession(_ arguments: Any?, result: @escaping FlutterResult) {
    guard let sessionID = Self.sessionID(arguments) else {
      result(error("SCREEN_CAPTURE_REQUEST_INVALID", "Invalid session.")); return
    }
    guard pendingImport?.sessionID != sessionID,
      !(activeSessionID == sessionID && (["starting", "recording", "stopping"].contains(state) || processingCompletion)) else {
      result(error("SCREEN_CAPTURE_CLEANUP_BUSY", "Session is still active.")); return
    }
    do {
      let saved = try Self.readSession(sessionID) ?? (activeSessionID == sessionID ? snapshot() : [:])
      if let media = saved["media"] as? [String: Any], let uri = media["appPrivateUri"] as? String {
        guard let name = Self.screenCaptureFileName(uri), !audioExports.contains(name) else {
          result(error("SCREEN_CAPTURE_CLEANUP_BUSY", "Media is still in use.")); return
        }
        let directory = try Self.screenCapturesDirectory()
        let stem = String(name.dropLast(4))
        for file in [name, "\(name).part", "\(stem).m4a", "\(stem).m4a.part", "\(stem).part.m4a"] {
          let url = directory.appendingPathComponent(file)
          if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
      }
      if let paths = try? SharedPaths.resolve(), paths.readPrepared()?["sessionId"] as? String == sessionID {
        try FileManager.default.removeItem(at: paths.root.appendingPathComponent("prepared.json"))
      }
      if let paths = try? SharedPaths.resolve() {
        let heartbeatURL = paths.root.appendingPathComponent("heartbeat-\(sessionID)")
        if FileManager.default.fileExists(atPath: heartbeatURL.path) { try FileManager.default.removeItem(at: heartbeatURL) }
      }
      let url = try Self.sessionURL(sessionID)
      if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
      if activeSessionID == sessionID {
        state = "idle"; completedMedia = nil; activeSessionID = nil; errorCode = nil
      }
      result(true)
    } catch { result(self.error("SCREEN_CAPTURE_CLEANUP_FAILED", "Session media could not be removed.")) }
  }

  private func capability() -> [String: Any] {
    #if targetEnvironment(simulator)
      return [
        "supported": false,
        "canCaptureSystemAudio": false,
        "requiresSystemPicker": true,
        "reasonCode": "SCREEN_CAPTURE_IOS_SIMULATOR_UNSUPPORTED",
      ]
    #else
      guard #available(iOS 15.0, *) else {
        return [
          "supported": false,
          "canCaptureSystemAudio": false,
          "requiresSystemPicker": true,
          "reasonCode": "SCREEN_CAPTURE_IOS_VERSION_UNSUPPORTED",
        ]
      }
      guard FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: Self.appGroupID
      ) != nil else {
        return [
          "supported": false,
          "canCaptureSystemAudio": false,
          "requiresSystemPicker": true,
          "reasonCode": "SCREEN_CAPTURE_APP_GROUP_UNAVAILABLE",
        ]
      }
      guard extensionInstalled() else {
        return [
          "supported": false,
          "canCaptureSystemAudio": false,
          "requiresSystemPicker": true,
          "reasonCode": "SCREEN_CAPTURE_EXTENSION_UNAVAILABLE",
        ]
      }
      return [
        "supported": true,
        "canCaptureSystemAudio": true,
        "requiresSystemPicker": true,
      ]
    #endif
  }

  private func startCapture(
    _ arguments: [String: Any]?,
    result: @escaping FlutterResult
  ) {
    pollManifest()
    let supported = capability()
    guard supported["supported"] as? Bool == true else {
      result(
        error(
          supported["reasonCode"] as? String ?? "SCREEN_CAPTURE_UNSUPPORTED",
          "Cross-application screen capture is unavailable on this device."
        )
      )
      return
    }
    guard pendingImport == nil, !processingCompletion, state != "starting", state != "recording", state != "stopping" else {
      result(error("SCREEN_CAPTURE_ALREADY_ACTIVE", "A screen capture is already active."))
      return
    }
    guard let parsedRequest = CaptureRequest.parse(arguments) else {
      result(error("SCREEN_CAPTURE_REQUEST_INVALID", "Screen capture options are invalid."))
      return
    }
    let request = parsedRequest.oriented(isLandscape: Self.isLandscapeInterface)
    do {
      let paths = try SharedPaths.resolve()
      try paths.prepareForNewCapture()
      try paths.writeRequest(request)
      activeSessionID = request.sessionID
      requestedAt = Date()
      stoppingAt = nil
      startedAt = nil
      fixedElapsedSeconds = 0
      completedMedia = nil
      errorCode = nil
      state = "starting"
      emit()
      startPolling()
      try presentBroadcastPicker()
      result(snapshot())
    } catch {
      fail("SCREEN_CAPTURE_PICKER_UNAVAILABLE")
      result(
        self.error(
          "SCREEN_CAPTURE_PICKER_UNAVAILABLE",
          "The system broadcast picker could not be opened."
        )
      )
    }
  }

  private func stopCapture(_ arguments: [String: Any]?, result: @escaping FlutterResult) {
    pollManifest()
    if let expected = arguments?["expectedSessionId"] as? String,
      expected != activeSessionID {
      result(error("SCREEN_CAPTURE_SESSION_MISMATCH", "Another screen capture owns this session."))
      return
    }
    guard state == "starting" || state == "recording" || state == "stopping",
      let sessionID = activeSessionID
    else {
      result(error("SCREEN_CAPTURE_NOT_ACTIVE", "No screen capture is active."))
      return
    }
    do {
      try SharedPaths.resolve().writeStopRequest(sessionID: sessionID)
      if state == "starting", startedAt == nil {
        try? FileManager.default.removeItem(at: SharedPaths.resolve().requestURL)
        fail("SCREEN_CAPTURE_CONSENT_CANCELLED")
        result(snapshot())
        return
      }
      state = "stopping"
      stoppingAt = stoppingAt ?? Date()
      emit()
      result(snapshot())
    } catch {
      fail("SCREEN_CAPTURE_STOP_REQUEST_FAILED")
      result(
        self.error(
          "SCREEN_CAPTURE_STOP_REQUEST_FAILED",
          "The screen-capture extension could not be asked to stop."
        )
      )
    }
  }

  private func extractAudio(_ arguments: [String: Any]?, result: @escaping FlutterResult) {
    guard let uri = arguments?["appPrivateUri"] as? String,
      let fileName = Self.screenCaptureFileName(uri),
      let directory = try? Self.screenCapturesDirectory()
    else {
      result(error("SCREEN_CAPTURE_AUDIO_REQUEST_INVALID", "Screen-capture media reference is invalid."))
      return
    }
    guard audioExports.insert(fileName).inserted else {
      result(error("SCREEN_CAPTURE_AUDIO_EXPORT_BUSY", "Audio extraction is already running."))
      return
    }
    let source = directory.appendingPathComponent(fileName)
    let outputName = String(fileName.dropLast(4)) + ".m4a"
    let output = directory.appendingPathComponent(outputName)
    let part = directory.appendingPathComponent(String(fileName.dropLast(4)) + ".part.m4a")
    let finish: ([String: Any]?, String?) -> Void = { payload, code in
      DispatchQueue.main.async {
        self.audioExports.remove(fileName)
        if let payload { result(payload) }
        else {
          try? FileManager.default.removeItem(at: part)
          result(self.error(code ?? "SCREEN_CAPTURE_AUDIO_EXPORT_FAILED", "Audio could not be extracted."))
        }
      }
    }
    DispatchQueue.global(qos: .utility).async {
      guard FileManager.default.fileExists(atPath: source.path) else {
        finish(nil, "SCREEN_CAPTURE_AUDIO_SOURCE_MISSING")
        return
      }
      let asset = AVURLAsset(url: source)
      guard !asset.tracks(withMediaType: .audio).isEmpty else {
        finish(nil, "SCREEN_CAPTURE_AUDIO_UNAVAILABLE")
        return
      }
      if let cached = Self.audioPayload(output: output, source: source) {
        finish(cached, nil)
        return
      }
      try? FileManager.default.removeItem(at: part)
      guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A),
        exporter.supportedFileTypes.contains(.m4a) else {
        finish(nil, "SCREEN_CAPTURE_AUDIO_EXPORT_UNAVAILABLE")
        return
      }
      exporter.outputURL = part
      exporter.outputFileType = .m4a
      exporter.exportAsynchronously {
        guard exporter.status == .completed,
          let payload = Self.audioPayload(output: part, source: source, finalName: outputName) else {
          finish(nil, "SCREEN_CAPTURE_AUDIO_EXPORT_FAILED")
          return
        }
        do {
          if FileManager.default.fileExists(atPath: output.path) {
            _ = try FileManager.default.replaceItemAt(output, withItemAt: part)
          } else {
            try FileManager.default.moveItem(at: part, to: output)
          }
          finish(payload, nil)
        } catch {
          finish(nil, "SCREEN_CAPTURE_STORAGE_FAILED")
        }
      }
    }
  }

  private static func audioPayload(output: URL, source: URL, finalName: String? = nil) -> [String: Any]? {
    let audio = AVURLAsset(url: output)
    let seconds = CMTimeGetSeconds(audio.duration)
    guard !audio.tracks(withMediaType: .audio).isEmpty,
      seconds.isFinite, seconds > 0, seconds <= 1801,
      let size = try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize,
      size > 0, size <= 500 * 1024 * 1024,
      let checksum = try? sha256Hex(output) else { return nil }
    let name = finalName ?? output.lastPathComponent
    let recordedAt = (try? source.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date()
    return [
      "appPrivateUri": "app-private-media://screen-capture/\(name)",
      "fileName": name,
      "mimeType": "audio/mp4",
      "sizeBytes": size,
      "durationSeconds": max(1, min(1800, Int(seconds.rounded(.down)))),
      "sha256": checksum,
      "recordedAt": isoFormatter.string(from: recordedAt),
    ]
  }

  private func presentBroadcastPicker() throws {
    guard let presenter = Self.topViewController() else {
      throw CaptureBridgeError.pickerUnavailable
    }
    let picker = RPSystemBroadcastPickerView(frame: CGRect(x: -80, y: -80, width: 44, height: 44))
    picker.preferredExtension = Self.extensionBundleID
    picker.showsMicrophoneButton = false
    presenter.view.addSubview(picker)
    broadcastPicker = picker
    guard let button = picker.subviews.compactMap({ $0 as? UIButton }).first else {
      picker.removeFromSuperview()
      broadcastPicker = nil
      throw CaptureBridgeError.pickerUnavailable
    }
    button.sendActions(for: .touchUpInside)
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self, weak picker] in
      picker?.removeFromSuperview()
      if self?.broadcastPicker === picker { self?.broadcastPicker = nil }
    }
  }

  private func startPolling() {
    pollTimer?.invalidate()
    let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
      self?.pollManifest()
    }
    pollTimer = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  private func pollManifest() {
    guard !processingCompletion,
      let paths = try? SharedPaths.resolve()
    else { return }
    guard let manifest = paths.readManifest() else {
      if activeSessionID == nil {
        if let request = paths.readRequest() {
          activeSessionID = request.sessionID
          requestedAt = (try? paths.requestURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
          state = "starting"
          startPolling()
        } else if let saved = paths.readPrepared(),
          let sessionID = saved["sessionId"] as? String,
          let media = saved["media"] as? [String: Any],
          let elapsed = media["durationSeconds"] as? Int {
          activeSessionID = sessionID
          completedMedia = media
          fixedElapsedSeconds = elapsed
          state = "completed"
          emit()
        }
      }
      if state == "starting", let requestedAt,
        Date().timeIntervalSince(requestedAt) >= Self.consentTimeout {
        if let sessionID = activeSessionID { try? paths.writeStopRequest(sessionID: sessionID) }
        try? FileManager.default.removeItem(at: paths.requestURL)
        fail("SCREEN_CAPTURE_CONSENT_CANCELLED")
      } else if state == "stopping", let stoppingAt,
        Date().timeIntervalSince(stoppingAt) > 30 {
        fail("SCREEN_CAPTURE_STOP_TIMEOUT")
      }
      return
    }
    if let activeSessionID, manifest.sessionID != activeSessionID { return }
    if activeSessionID == nil { activeSessionID = manifest.sessionID }
    if ["recording", "stopping"].contains(manifest.state) {
      if let saved = try? Self.readSession(manifest.sessionID),
        let terminal = saved["state"] as? String, terminal == "failed" {
        state = "failed"; errorCode = saved["errorCode"] as? String
        return
      }
      let heartbeatURL = paths.root.appendingPathComponent("heartbeat-\(manifest.sessionID)")
      let pulse = (try? String(contentsOf: heartbeatURL, encoding: .utf8)).flatMap(Double.init)
      let age = pulse.map { ProcessInfo.processInfo.systemUptime - $0 }
      guard let age, age >= 0, age <= 30 else {
        try? paths.writeStopRequest(sessionID: manifest.sessionID)
        fail("SCREEN_CAPTURE_SESSION_INTERRUPTED")
        return
      }
    }
    switch manifest.state {
    case "recording", "stopping":
      guard let value = manifest.startedAt.flatMap(Self.parseDate) else {
        fail("SCREEN_CAPTURE_STATE_INVALID")
        return
      }
      startedAt = value
      requestedAt = nil
      if manifest.state == "stopping" {
        state = "stopping"
        stoppingAt = stoppingAt ?? Date()
      } else if state != "stopping" { state = "recording" }
      if let stoppingAt, Date().timeIntervalSince(stoppingAt) > 30 {
        fail("SCREEN_CAPTURE_STOP_TIMEOUT")
        return
      }
      errorCode = nil
      if pollTimer == nil { startPolling() }
      emit()
    case "failed":
      fail(Self.safeCode(manifest.errorCode) ?? "SCREEN_CAPTURE_EXTENSION_FAILED")
    case "completed":
      if state == "completed", completedMedia != nil { return }
      prepareCompleted(manifest: manifest, paths: paths)
    default:
      break
    }
  }

  private func prepareCompleted(manifest: CaptureManifest, paths: SharedPaths) {
    guard !processingCompletion else { return }
    processingCompletion = true
    state = "stopping"
    fixedElapsedSeconds = manifest.durationSeconds ?? fixedElapsedSeconds
    emit()
    let expectedSession = activeSessionID
    DispatchQueue.global(qos: .utility).async { [weak self] in
      let prepared: Result<PreparedMedia, CapturePreparationError> = Result {
        try Self.prepareMedia(manifest: manifest, paths: paths)
      }.mapError { error in
        (error as? CapturePreparationError) ?? .storage
      }
      DispatchQueue.main.async {
        guard let self else { return }
        self.processingCompletion = false
        guard self.activeSessionID == expectedSession else { return }
        switch prepared {
        case .success(let media):
          self.fixedElapsedSeconds = media.durationSeconds
          self.completedMedia = media.payload
          self.errorCode = nil
          self.state = "completed"
          self.startedAt = nil
          self.requestedAt = nil
          self.stoppingAt = nil
          do {
            try Self.saveSession(self.snapshot())
            try? paths.writePrepared(self.snapshot())
          } catch {
            self.fail("SCREEN_CAPTURE_STORAGE_FAILED")
            return
          }
          try? paths.cleanAfterCompletion()
          self.pollTimer?.invalidate()
          self.pollTimer = nil
          self.emit()
        case .failure(let failure):
          self.fail(failure.code)
        }
      }
    }
  }

  private static func prepareMedia(
    manifest: CaptureManifest,
    paths: SharedPaths
  ) throws -> PreparedMedia {
    guard let fileName = manifest.fileName,
      isSafeFileName(fileName),
      let duration = manifest.durationSeconds,
      duration > 0, duration <= 1800,
      let recordedAt = manifest.recordedAt,
      parseDate(recordedAt) != nil
    else { throw CapturePreparationError.invalidMedia }
    let source = paths.stagingDirectory.appendingPathComponent(fileName)
    let applicationSupport = try FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    let directory = applicationSupport
      .appendingPathComponent("HuahuoAI", isDirectory: true)
      .appendingPathComponent("ScreenCaptures", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let destination = directory.appendingPathComponent(fileName)
    let existing = FileManager.default.fileExists(atPath: destination.path)
    let size = try (existing ? destination : source).resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard size > 0, size <= 500 * 1024 * 1024 else {
      throw CapturePreparationError.invalidMedia
    }
    let part = directory.appendingPathComponent("\(fileName).part")
    try? FileManager.default.removeItem(at: part)
    if !existing {
      try FileManager.default.copyItem(at: source, to: part)
      let copiedSize = try part.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
      guard copiedSize == size else {
        try? FileManager.default.removeItem(at: part)
        throw CapturePreparationError.storage
      }
      try FileManager.default.moveItem(at: part, to: destination)
    }
    let checksum: String
    do {
      checksum = try sha256Hex(destination)
    } catch {
      try? FileManager.default.removeItem(at: destination)
      throw CapturePreparationError.storage
    }
    let payload: [String: Any] = [
      "appPrivateUri": "app-private-media://screen-capture/\(fileName)",
      "fileName": fileName,
      "mimeType": "video/mp4",
      "sizeBytes": size,
      "durationSeconds": duration,
      "sha256": checksum,
      "recordedAt": recordedAt,
    ]
    return PreparedMedia(payload: payload, durationSeconds: duration)
  }

  private func fail(_ code: String) {
    state = "failed"
    errorCode = Self.safeCode(code) ?? "SCREEN_CAPTURE_PLATFORM_FAILED"
    fixedElapsedSeconds = 0
    completedMedia = nil
    requestedAt = nil
    startedAt = nil
    stoppingAt = nil
    if activeSessionID != nil { try? Self.saveSession(snapshot()) }
    pollTimer?.invalidate()
    pollTimer = nil
    emit()
  }

  private func snapshot() -> [String: Any] {
    var payload: [String: Any] = [
      "state": state,
      "elapsedSeconds": elapsedSeconds(),
    ]
    if let activeSessionID { payload["sessionId"] = activeSessionID }
    if let startedAt, state == "recording" || state == "stopping" {
      payload["startedAt"] = Self.isoFormatter.string(from: startedAt)
    }
    if state == "completed", let completedMedia {
      payload["media"] = completedMedia
    }
    if state == "failed", let errorCode {
      payload["errorCode"] = errorCode
    }
    return payload
  }

  private func elapsedSeconds() -> Int {
    guard (state == "recording" || state == "stopping"), let startedAt else {
      return fixedElapsedSeconds
    }
    return min(1800, max(0, Int(Date().timeIntervalSince(startedAt))))
  }

  private func emit() {
    eventSink?(snapshot())
  }

  @objc private func applicationDidBecomeActive() {
    pollManifest()
    if state == "starting" || state == "recording" || state == "stopping" {
      startPolling()
    }
  }

  private func extensionInstalled() -> Bool {
    guard let plugins = Bundle.main.builtInPlugInsURL else { return false }
    return FileManager.default.fileExists(
      atPath: plugins.appendingPathComponent("ScreenCaptureExtension.appex").path
    )
  }

  private func error(_ code: String, _ message: String) -> FlutterError {
    FlutterError(code: code, message: message, details: nil)
  }

  private static func safeCode(_ value: String?) -> String? {
    guard let value, value.count <= 80,
      value.range(of: "^[A-Z0-9_]+$", options: .regularExpression) != nil
    else { return nil }
    return value
  }

  private static func isSafeFileName(_ value: String) -> Bool {
    value.count >= 5 && value.count <= 160 &&
      value.range(
        of: "^[A-Za-z0-9][A-Za-z0-9._-]*\\.mp4$",
        options: .regularExpression
      ) != nil
  }

  private static func screenCaptureFileName(_ value: String) -> String? {
    guard let uri = URL(string: value),
      uri.scheme == "app-private-media",
      uri.host == "screen-capture",
      uri.pathComponents.count == 2
    else { return nil }
    let fileName = uri.lastPathComponent
    return isSafeFileName(fileName) ? fileName : nil
  }

  private static func screenCapturesDirectory() throws -> URL {
    let root = try FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    return root
      .appendingPathComponent("HuahuoAI", isDirectory: true)
      .appendingPathComponent("ScreenCaptures", isDirectory: true)
  }

  private static func parseDate(_ value: String) -> Date? {
    isoFormatter.date(from: value)
  }

  private static func sha256Hex(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while true {
      let data = handle.readData(ofLength: 64 * 1024)
      if data.isEmpty { break }
      hasher.update(data: data)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private static func topViewController() -> UIViewController? {
    let root = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap(\.windows)
      .first(where: { $0.isKeyWindow })?.rootViewController
    var current = root
    while let presented = current?.presentedViewController { current = presented }
    if let navigation = current as? UINavigationController { return navigation.visibleViewController }
    if let tab = current as? UITabBarController { return tab.selectedViewController }
    return current
  }

  private static var isLandscapeInterface: Bool {
    UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .first(where: { $0.activationState == .foregroundActive })?
      .interfaceOrientation.isLandscape == true
  }

  private static let appGroupID = "group.com.hangzhouchuda.huahuoai.capture"
  private static let extensionBundleID = "com.hangzhouchuda.huahuoai.ScreenCaptureExtension"
  private static let consentTimeout: TimeInterval = 60
  private static let isoFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()
}

private struct CaptureRequest: Codable {
  let sessionID: String
  let maxDurationSeconds: Int
  let maxSizeBytes: Int
  let targetWidth: Int
  let targetHeight: Int

  static func parse(_ arguments: [String: Any]?) -> CaptureRequest? {
    let duration = (arguments?["maxDurationSeconds"] as? NSNumber)?.intValue ?? 1800
    let size = (arguments?["maxSizeBytes"] as? NSNumber)?.intValue ?? 500 * 1024 * 1024
    let width = (arguments?["targetWidth"] as? NSNumber)?.intValue ?? 720
    let height = (arguments?["targetHeight"] as? NSNumber)?.intValue ?? 1280
    let sessionID = arguments?["sessionId"] as? String ?? UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    guard sessionID.range(of: "^[A-Za-z0-9_-]{1,100}$", options: .regularExpression) != nil else { return nil }
    guard duration > 0, duration <= 1800,
      size >= 1024 * 1024, size <= 500 * 1024 * 1024,
      width >= 320, width <= 1920, height >= 320, height <= 1920
    else { return nil }
    return CaptureRequest(
      sessionID: sessionID,
      maxDurationSeconds: duration,
      maxSizeBytes: size,
      targetWidth: width,
      targetHeight: height
    )
  }

  func oriented(isLandscape: Bool) -> CaptureRequest {
    let shortEdge = min(targetWidth, targetHeight)
    let longEdge = max(targetWidth, targetHeight)
    return CaptureRequest(
      sessionID: sessionID,
      maxDurationSeconds: maxDurationSeconds,
      maxSizeBytes: maxSizeBytes,
      targetWidth: isLandscape ? longEdge : shortEdge,
      targetHeight: isLandscape ? shortEdge : longEdge
    )
  }
}

private struct StopRequest: Codable {
  let sessionID: String
}

private struct CaptureManifest: Codable {
  let state: String
  let sessionID: String
  let fileName: String?
  let startedAt: String?
  let recordedAt: String?
  let durationSeconds: Int?
  let errorCode: String?
}

private struct SharedPaths {
  let root: URL
  let stagingDirectory: URL
  let requestURL: URL
  let manifestURL: URL
  let stopURL: URL

  static func resolve() throws -> SharedPaths {
    guard let container = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: "group.com.hangzhouchuda.huahuoai.capture"
    ) else { throw CapturePreparationError.appGroup }
    let root = container.appendingPathComponent("ScreenCapture", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return SharedPaths(
      root: root,
      stagingDirectory: root.appendingPathComponent("Staging", isDirectory: true),
      requestURL: root.appendingPathComponent("request.json"),
      manifestURL: root.appendingPathComponent("manifest.json"),
      stopURL: root.appendingPathComponent("stop.json")
    )
  }

  func prepareForNewCapture() throws {
    try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
    try? FileManager.default.removeItem(at: manifestURL)
    try? FileManager.default.removeItem(at: stopURL)
    let staged = try FileManager.default.contentsOfDirectory(
      at: stagingDirectory,
      includingPropertiesForKeys: nil
    )
    for url in staged { try? FileManager.default.removeItem(at: url) }
  }

  func writeRequest(_ request: CaptureRequest) throws {
    try JSONEncoder().encode(request).write(to: requestURL, options: .atomic)
  }

  func readRequest() -> CaptureRequest? {
    guard let data = try? Data(contentsOf: requestURL) else { return nil }
    return try? JSONDecoder().decode(CaptureRequest.self, from: data)
  }

  func readPrepared() -> [String: Any]? {
    guard let data = try? Data(contentsOf: root.appendingPathComponent("prepared.json")) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
  }

  func writePrepared(_ payload: [String: Any]) throws {
    try JSONSerialization.data(withJSONObject: payload)
      .write(to: root.appendingPathComponent("prepared.json"), options: .atomic)
  }

  func writeStopRequest(sessionID: String) throws {
    try JSONEncoder().encode(StopRequest(sessionID: sessionID))
      .write(to: stopURL, options: .atomic)
  }

  func readManifest() -> CaptureManifest? {
    guard let data = try? Data(contentsOf: manifestURL) else { return nil }
    return try? JSONDecoder().decode(CaptureManifest.self, from: data)
  }

  func cleanAfterCompletion() throws {
    try? FileManager.default.removeItem(at: requestURL)
    try? FileManager.default.removeItem(at: manifestURL)
    try? FileManager.default.removeItem(at: stopURL)
    let staged = try FileManager.default.contentsOfDirectory(
      at: stagingDirectory,
      includingPropertiesForKeys: nil
    )
    for url in staged { try? FileManager.default.removeItem(at: url) }
  }
}

private struct PreparedMedia {
  let payload: [String: Any]
  let durationSeconds: Int
}

private enum CapturePreparationError: Error {
  case appGroup
  case invalidMedia
  case storage

  var code: String {
    switch self {
    case .appGroup: return "SCREEN_CAPTURE_APP_GROUP_UNAVAILABLE"
    case .invalidMedia: return "SCREEN_CAPTURE_MEDIA_INVALID"
    case .storage: return "SCREEN_CAPTURE_STORAGE_FAILED"
    }
  }
}

private enum CaptureBridgeError: Error {
  case pickerUnavailable
}
