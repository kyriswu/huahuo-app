import Flutter
import Foundation

#if canImport(QCloudRealTime)
import QCloudRealTime
#endif

final class TencentLiveAsrBridge: NSObject, FlutterStreamHandler {
  private static let providerRequestTimeoutSeconds = 20
  private static let readyWatchdogSeconds: TimeInterval = 25

  private let methodChannel: FlutterMethodChannel
  private let eventChannel: FlutterEventChannel
  private var eventSink: FlutterEventSink?
  private var active = false
  private var generation = 0
  private var pendingStart: TencentLiveAsrPendingStart?
  private var captureReadyGeneration: Int?
  private var transportPollGeneration: Int?

  #if canImport(QCloudRealTime)
  private var recognizer: QCloudRealTimeRecognizer?
  private var audioDataSource: TencentLiveAsrPCMDataSource?
  #endif

  init(messenger: FlutterBinaryMessenger) {
    methodChannel = FlutterMethodChannel(
      name: "huahuoai/tencent_live_asr",
      binaryMessenger: messenger
    )
    eventChannel = FlutterEventChannel(
      name: "huahuoai/tencent_live_asr/events",
      binaryMessenger: messenger
    )
    super.init()
    methodChannel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call: call, result: result)
    }
    eventChannel.setStreamHandler(self)
  }

  func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "start":
      start(call.arguments as? [String: Any], result: result)
    case "stop":
      stop(result: result)
    case "release":
      release(result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func start(_ raw: [String: Any]?, result: @escaping FlutterResult) {
    NSLog("[TencentLiveAsr] stage=start_requested")
    guard !active else {
      result(tencentLiveAsrError("TENCENT_LIVE_ASR_SESSION_BUSY"))
      return
    }
    guard let command = TencentLiveAsrStartCommand(raw) else {
      result(tencentLiveAsrError("TENCENT_LIVE_ASR_REQUEST_INVALID"))
      return
    }

    #if canImport(QCloudRealTime)
    let config = QCloudConfig(
      appId: command.appID,
      secretId: command.tmpSecretID,
      secretKey: command.tmpSecretKey,
      token: command.token,
      projectId: command.projectID
    )
    config.engineType = "16k_zh"
    config.endRecognizeWhenDetectSilence = false
    config.shouldSaveAsFile = false
    config.requestTimeout = Self.providerRequestTimeoutSeconds
    let source = TencentLiveAsrPCMDataSource { [weak self] stage in
      self?.emitDiagnostic(stage)
    }
    let realtimeRecognizer = QCloudRealTimeRecognizer(
      config: config,
      dataSource: source
    )
    realtimeRecognizer.delegate = self
    audioDataSource = source
    recognizer = realtimeRecognizer
    active = true
    generation += 1
    let sessionGeneration = generation
    captureReadyGeneration = nil
    transportPollGeneration = nil
    let timeout = DispatchWorkItem { [weak self] in
      guard let self else { return }
      if self.failPendingStart(
        generation: sessionGeneration,
        code: self.startTimeoutFailureCode()
      ) {
        NSLog("[TencentLiveAsr] stage=ready_timeout")
      }
    }
    pendingStart = TencentLiveAsrPendingStart(
      generation: sessionGeneration,
      result: result,
      timeout: timeout
    )
    NSLog("[TencentLiveAsr] stage=recognizer_start_invoked")
    emitDiagnostic("recognizer_start_invoked")
    realtimeRecognizer.start()
    scheduleRecognizerStateDiagnostic(after: 2, checkpoint: "early")
    scheduleRecognizerStateDiagnostic(
      after: TimeInterval(Self.providerRequestTimeoutSeconds),
      checkpoint: "provider_timeout"
    )
    DispatchQueue.main.asyncAfter(
      deadline: .now() + Self.readyWatchdogSeconds,
      execute: timeout
    )
    #else
    result(tencentLiveAsrError("TENCENT_LIVE_ASR_SDK_UNAVAILABLE"))
    #endif
  }

  private func stop(result: @escaping FlutterResult) {
    NSLog("[TencentLiveAsr] stage=stop_requested active=%@", active.description)
    if let pendingStart {
      _ = failPendingStart(
        generation: pendingStart.generation,
        code: "TENCENT_LIVE_ASR_SESSION_SUPERSEDED"
      )
      result(nil)
      return
    }
    guard active else {
      result(nil)
      return
    }
    #if canImport(QCloudRealTime)
    audioDataSource?.stop()
    recognizer?.stop()
    result(nil)
    #else
    result(tencentLiveAsrError("TENCENT_LIVE_ASR_SDK_UNAVAILABLE"))
    #endif
  }

  private func release(result: @escaping FlutterResult) {
    NSLog("[TencentLiveAsr] stage=release_requested active=%@", active.description)
    if let pendingStart {
      _ = failPendingStart(
        generation: pendingStart.generation,
        code: "TENCENT_LIVE_ASR_SESSION_SUPERSEDED"
      )
    } else {
      tearDownActiveSession()
    }
    result(nil)
  }

  @discardableResult
  private func completePendingStart(generation expectedGeneration: Int) -> Bool {
    guard
      active,
      generation == expectedGeneration,
      let pending = pendingStart,
      pending.generation == expectedGeneration
    else { return false }
    pending.timeout.cancel()
    pendingStart = nil
    captureReadyGeneration = nil
    transportPollGeneration = nil
    pending.result(nil)
    return true
  }

  @discardableResult
  private func failPendingStart(
    generation expectedGeneration: Int,
    code: String
  ) -> Bool {
    guard
      let pending = pendingStart,
      pending.generation == expectedGeneration
    else { return false }
    pending.timeout.cancel()
    pendingStart = nil
    tearDownActiveSession()
    pending.result(tencentLiveAsrError(code))
    return true
  }

  private func tearDownActiveSession() {
    active = false
    generation += 1
    captureReadyGeneration = nil
    transportPollGeneration = nil
    #if canImport(QCloudRealTime)
    let activeRecognizer = recognizer
    activeRecognizer?.delegate = nil
    recognizer = nil
    audioDataSource?.stop()
    audioDataSource = nil
    activeRecognizer?.stop()
    #endif
  }

  private func emit(_ value: [String: Any]) {
    DispatchQueue.main.async { [weak self] in
      guard let self, self.active else { return }
      self.eventSink?(value)
    }
  }

  private func emitFailure(_ code: String) {
    NSLog("[TencentLiveAsr] failure=%@", code)
    let expectedGeneration = generation
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      if self.failPendingStart(
        generation: expectedGeneration,
        code: code
      ) {
        return
      }
      self.emit(["type": "error", "code": code])
    }
  }

  private func emitDiagnostic(_ stage: String) {
    guard
      stage.range(
        of: "^[a-z][a-z0-9_]{2,63}$",
        options: .regularExpression
      ) != nil
    else { return }
    emit(["type": "diagnostic", "stage": stage])
  }

  #if canImport(QCloudRealTime)
  private func markCaptureReadyAndCompleteWhenTransportReady(
    generation expectedGeneration: Int
  ) -> Bool {
    guard
      active,
      generation == expectedGeneration,
      pendingStart?.generation == expectedGeneration
    else { return false }
    captureReadyGeneration = expectedGeneration
    completeWhenTransportReady(generation: expectedGeneration)
    return true
  }

  private func completeWhenTransportReady(generation expectedGeneration: Int) {
    guard
      active,
      generation == expectedGeneration,
      pendingStart?.generation == expectedGeneration,
      captureReadyGeneration == expectedGeneration
    else { return }
    guard recognizer?.getAudioRecognizeState().rawValue == 3 else {
      scheduleTransportReadyPoll(generation: expectedGeneration)
      return
    }
    transportPollGeneration = nil
    _ = completePendingStart(generation: expectedGeneration)
  }

  private func scheduleTransportReadyPoll(generation expectedGeneration: Int) {
    guard transportPollGeneration != expectedGeneration else { return }
    transportPollGeneration = expectedGeneration
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
      guard let self,
            self.transportPollGeneration == expectedGeneration else { return }
      self.transportPollGeneration = nil
      self.completeWhenTransportReady(generation: expectedGeneration)
    }
  }

  private func startTimeoutFailureCode() -> String {
    let captureReady = VoiceRecorderPCM16NativeHub.shared.hasProducedPCM
    let transportReady = recognizer?.getAudioRecognizeState().rawValue == 3
    switch (captureReady, transportReady) {
    case (false, false):
      return "TENCENT_LIVE_ASR_START_PREREQUISITES_TIMEOUT"
    case (false, true):
      return "TENCENT_LIVE_ASR_AUDIO_SOURCE_NOT_READY"
    case (true, false):
      return "TENCENT_LIVE_ASR_TRANSPORT_TIMEOUT"
    case (true, true):
      return "TENCENT_LIVE_ASR_FLOW_START_TIMEOUT"
    }
  }

  private func scheduleRecognizerStateDiagnostic(
    after seconds: TimeInterval,
    checkpoint: String
  ) {
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
      guard let self, self.active, let recognizer = self.recognizer else {
        return
      }
      let state = switch recognizer.getAudioRecognizeState().rawValue {
      case 0: "none"
      case 1: "start"
      case 2: "stop"
      case 3: "recognizing"
      default: "unknown"
      }
      self.emitDiagnostic("recognizer_state_\(state)_\(checkpoint)")
    }
  }
  #endif
}

private struct TencentLiveAsrPendingStart {
  let generation: Int
  let result: FlutterResult
  let timeout: DispatchWorkItem
}

private struct TencentLiveAsrStartCommand {
  let appID: String
  let projectID: Int
  let tmpSecretID: String
  let tmpSecretKey: String
  let token: String

  init?(_ raw: [String: Any]?) {
    guard let raw,
      let sessionID = raw["sessionId"] as? String,
      let appID = raw["appId"] as? Int,
      let projectID = raw["projectId"] as? Int,
      let tmpSecretID = raw["tmpSecretId"] as? String,
      let tmpSecretKey = raw["tmpSecretKey"] as? String,
      let token = raw["token"] as? String,
      Self.safeOpaqueID(sessionID),
      appID > 0,
      projectID >= 0,
      Self.safeCredentialPart(tmpSecretID),
      Self.safeCredentialPart(tmpSecretKey),
      Self.safeCredentialPart(token)
    else {
      return nil
    }
    self.appID = String(appID)
    self.projectID = projectID
    self.tmpSecretID = tmpSecretID
    self.tmpSecretKey = tmpSecretKey
    self.token = token
  }

  private static func safeOpaqueID(_ value: String) -> Bool {
    value.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]{2,127}$", options: .regularExpression) != nil
  }

  private static func safeCredentialPart(_ value: String) -> Bool {
    guard !value.isEmpty, value.count <= 8192 else { return false }
    return !value.unicodeScalars.contains { $0.value < 0x21 || $0.value == 0x7f }
  }
}

private func tencentLiveAsrError(_ code: String) -> FlutterError {
  FlutterError(
    code: code,
    message: "Tencent realtime ASR operation failed.",
    details: nil
  )
}

#if canImport(QCloudRealTime)
private final class TencentLiveAsrPCMDataSource: NSObject, QCloudAudioDataSource {
  private let diagnostic: (String) -> Void
  var running = false
  private var successfulReadCount = 0
  private var emptyReadCount = 0

  init(diagnostic: @escaping (String) -> Void) {
    self.diagnostic = diagnostic
  }

  var audioFilePath: String { "" }

  var recording: Bool {
    running && VoiceRecorderPCM16NativeHub.shared.isCaptureActive
  }

  func start(_ completion: @escaping @Sendable (Bool, Error?) -> Void) {
    NSLog("[TencentLiveAsr] stage=audio_source_start_requested capture_active=%@", VoiceRecorderPCM16NativeHub.shared.isCaptureActive.description)
    diagnostic("audio_source_start_requested")
    guard VoiceRecorderPCM16NativeHub.shared.startConsumer() else {
      NSLog("[TencentLiveAsr] stage=audio_source_start_failed")
      diagnostic("audio_source_start_failed")
      completion(
        false,
        NSError(
          domain: "TencentLiveAsrPCMDataSource",
          code: QCloudRealTimeClientErrCode.audioInitError.rawValue
        )
      )
      return
    }
    running = true
    successfulReadCount = 0
    emptyReadCount = 0
    NSLog("[TencentLiveAsr] stage=audio_source_ready")
    diagnostic("audio_source_ready")
    completion(true, nil)
  }

  func stop() {
    NSLog("[TencentLiveAsr] stage=audio_source_stopped reads=%d", successfulReadCount)
    diagnostic("audio_source_stopped")
    VoiceRecorderPCM16NativeHub.shared.stopConsumer()
    running = false
  }

  func readData(_ expectLength: Int) -> Data? {
    guard running else { return nil }
    let data = VoiceRecorderPCM16NativeHub.shared.read(exactLength: expectLength)
    if data != nil {
      successfulReadCount += 1
      if successfulReadCount == 1 {
        NSLog("[TencentLiveAsr] stage=audio_first_frame bytes=%d", expectLength)
        diagnostic("audio_first_frame")
      }
    } else {
      emptyReadCount += 1
      if emptyReadCount == 1 {
        diagnostic("audio_first_empty_read")
      }
    }
    return data
  }
}

extension TencentLiveAsrBridge: QCloudRealTimeRecognizerDelegate {
  func realTimeRecognizer(
    onFlowRecognizeStart recognizer: QCloudRealTimeRecognizer,
    voiceId: String,
    seq: Int
  ) {
    let expectedGeneration = generation
    DispatchQueue.main.async { [weak self] in
      guard
        let self,
        self.markCaptureReadyAndCompleteWhenTransportReady(
          generation: expectedGeneration
        )
      else { return }
      self.emitDiagnostic("flow_recognize_started")
    }
  }

  func realTimeRecognizer(
    onFlowRecognizeEnd recognizer: QCloudRealTimeRecognizer,
    voiceId: String,
    seq: Int
  ) {
    emitDiagnostic("flow_recognize_ended")
  }

  func realTimeRecognizer(
    onSliceRecognize recognizer: QCloudRealTimeRecognizer,
    result: QCloudRealTimeResult
  ) {
    emitResult(result, type: "partial")
  }

  func realTimeRecognizer(
    onSegmentSuccessRecognize recognizer: QCloudRealTimeRecognizer,
    result: QCloudRealTimeResult
  ) {
    emitResult(result, type: "segment")
  }

  func realTimeRecognizerDidFinish(
    _ recognizer: QCloudRealTimeRecognizer,
    result: String
  ) {
    let expectedGeneration = generation
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      if self.failPendingStart(
        generation: expectedGeneration,
        code: "TENCENT_LIVE_ASR_NOT_RUNNING"
      ) {
        return
      }
      NSLog("[TencentLiveAsr] stage=recognizer_finished")
      self.emitDiagnostic("recognizer_finished")
      self.emit(["type": "completed"])
    }
  }

  func realTimeRecognizerDidError(
    _ recognizer: QCloudRealTimeRecognizer,
    result: QCloudRealTimeResult
  ) {
    NSLog(
      "[TencentLiveAsr] stage=recognizer_error client_code=%@ provider_code=%@",
      String(result.clientErrCode),
      String(result.code)
    )
    emitFailure(tencentLiveAsrFailureCode(result))
  }

  func realTimeRecognizerDidStartRecord(
    _ recognizer: QCloudRealTimeRecognizer,
    error: Error?
  ) {
    if let error, (error as NSError).code != 0 {
      NSLog(
        "[TencentLiveAsr] stage=recognizer_record_start_failed code=%d",
        (error as NSError).code
      )
      emitFailure("TENCENT_LIVE_ASR_AUDIO_SOURCE_START_FAILED")
      return
    }
    NSLog("[TencentLiveAsr] stage=recognizer_record_started")
    emitDiagnostic("recognizer_record_started")
  }

  private func emitResult(_ result: QCloudRealTimeResult, type: String) {
    let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      !text.isEmpty,
      text.count <= 100_000,
      result.seq >= 0
    else {
      emitFailure("TENCENT_LIVE_ASR_EVENT_INVALID")
      return
    }
    let event: [String: Any] = [
      "type": type,
      "sequence": result.seq,
      "text": text,
    ]
    NSLog("[TencentLiveAsr] stage=result type=%@ sequence=%d", type, result.seq)
    emit(event)
  }
}

private func tencentLiveAsrFailureCode(
  _ result: QCloudRealTimeResult?
) -> String {
  guard let result else {
    return "TENCENT_LIVE_ASR_RECOGNITION_FAILED"
  }
  if result.clientErrCode == QCloudRealTimeClientErrCode.success.rawValue,
    result.code != 0
  {
    return "TENCENT_LIVE_ASR_PROVIDER_REJECTED"
  }
  switch result.clientErrCode {
  case QCloudRealTimeClientErrCode.networkError.rawValue:
    return "TENCENT_LIVE_ASR_NETWORK_FAILED"
  case QCloudRealTimeClientErrCode.timeout.rawValue:
    return "TENCENT_LIVE_ASR_TIMEOUT"
  case QCloudRealTimeClientErrCode.micError.rawValue:
    return "TENCENT_LIVE_ASR_MICROPHONE_BUSY"
  case QCloudRealTimeClientErrCode.audioInitError.rawValue:
    return "TENCENT_LIVE_ASR_AUDIO_SOURCE_START_FAILED"
  case QCloudRealTimeClientErrCode.notRunning.rawValue:
    return "TENCENT_LIVE_ASR_NOT_RUNNING"
  case QCloudRealTimeClientErrCode.invalidParam.rawValue:
    return "TENCENT_LIVE_ASR_REQUEST_INVALID"
  case QCloudRealTimeClientErrCode.writeContentFailed.rawValue:
    return "TENCENT_LIVE_ASR_WRITE_FAILED"
  default:
    return "TENCENT_LIVE_ASR_RECOGNITION_FAILED"
  }
}
#endif
