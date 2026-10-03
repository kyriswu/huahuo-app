import AVFoundation
import AudioToolbox
import CryptoKit
import Flutter
import Foundation

enum VoiceRecorderM4AValidationError: Error, Equatable {
  case invalidContainer
  case unreadableAudio
}

enum VoiceprintWAVValidationError: Error, Equatable {
  case invalidContainer
  case invalidFormat
  case invalidDuration
  case fileTooLarge
}

enum SharedPcmWAVValidationError: Error, Equatable {
  case invalidContainer
  case invalidFormat
  case invalidDuration
}

let voiceprintWAVSampleRate: Double = 16_000
let voiceprintWAVBitDepth: UInt32 = 16
let voiceprintWAVChannelCount: UInt32 = 1
let voiceprintWAVMinimumDurationMilliseconds: Int64 = 10_000
let voiceprintWAVMaximumAcceptedDurationMilliseconds: Int64 = 10_500
let voiceprintWAVCaptureDurationSeconds: TimeInterval = 10
let voiceprintWAVMaximumBytes = 2 * 1024 * 1024
let voiceRecorderPCM16FrameBytes = 1_280

func voiceRecorderPartFileName(recordingID: String, scene: String = "monologue") -> String {
  let fileExtension = voiceRecorderUsesPcmWAV(scene: scene) ? "wav" : "m4a"
  return "\(recordingID).part.\(fileExtension)"
}

func voiceRecorderUsesPcmWAV(scene: String) -> Bool {
  scene == "voiceprint" || scene == "monologue" || scene == "meeting"
}

struct VoiceRecorderPCM16FrameChunker {
  private var pending = Data()

  var pendingByteCount: Int { pending.count }

  mutating func append(_ bytes: Data) -> [Data] {
    guard !bytes.isEmpty else { return [] }
    pending.append(bytes)
    var frames: [Data] = []
    while pending.count >= voiceRecorderPCM16FrameBytes {
      frames.append(Data(pending.prefix(voiceRecorderPCM16FrameBytes)))
      pending.removeFirst(voiceRecorderPCM16FrameBytes)
    }
    return frames
  }

  mutating func reset() {
    pending.removeAll(keepingCapacity: true)
  }
}

struct VoiceRecorderPCM16EarlyFrameQueue {
  let capacityFrames: Int
  private var frames: [Data] = []
  private var readIndex = 0
  private(set) var overflowed = false
  private(set) var droppedFrameCount = 0

  init(capacityFrames: Int) {
    precondition(capacityFrames > 0)
    self.capacityFrames = capacityFrames
  }

  var count: Int { frames.count - readIndex }
  var isEmpty: Bool { count == 0 }

  mutating func append(_ frame: Data) -> Bool {
    if overflowed {
      droppedFrameCount += 1
      return false
    }
    if count >= capacityFrames {
      overflowed = true
      droppedFrameCount = count + 1
      frames.removeAll(keepingCapacity: true)
      readIndex = 0
      return false
    }
    frames.append(frame)
    return true
  }

  mutating func removeFirst() -> Data? {
    guard !isEmpty else { return nil }
    let frame = frames[readIndex]
    readIndex += 1
    if readIndex == frames.count {
      frames.removeAll(keepingCapacity: true)
      readIndex = 0
    } else if readIndex >= 128 && readIndex * 2 >= frames.count {
      frames.removeFirst(readIndex)
      readIndex = 0
    }
    return frame
  }

  mutating func reset() {
    frames.removeAll(keepingCapacity: true)
    readIndex = 0
    overflowed = false
    droppedFrameCount = 0
  }
}

final class VoiceRecorderPCM16NativeHub {
  static let shared = VoiceRecorderPCM16NativeHub()

  private static let maximumBufferedBytes = 1_125 * voiceRecorderPCM16FrameBytes
  private static let readWaitSeconds: TimeInterval = 0.5
  private let condition = NSCondition()
  private var bytes = Data()
  private var readOffset = 0
  private var captureActive = false
  private var consumerActive = false
  private var overflowed = false
  private var producedPCM = false

  private init() {}

  var isCaptureActive: Bool {
    condition.lock()
    defer { condition.unlock() }
    return captureActive
  }

  var hasProducedPCM: Bool {
    condition.lock()
    defer { condition.unlock() }
    return producedPCM
  }

  func beginCapture() {
    condition.lock()
    bytes.removeAll(keepingCapacity: true)
    readOffset = 0
    captureActive = true
    consumerActive = false
    overflowed = false
    producedPCM = false
    condition.broadcast()
    condition.unlock()
  }

  func append(_ frame: Data) {
    guard frame.count == voiceRecorderPCM16FrameBytes else { return }
    condition.lock()
    defer { condition.unlock() }
    guard captureActive, !overflowed else { return }
    producedPCM = true
    compactIfNeededLocked()
    if unreadByteCountLocked + frame.count > Self.maximumBufferedBytes {
      overflowed = true
      bytes.removeAll(keepingCapacity: true)
      readOffset = 0
      condition.broadcast()
      return
    }
    bytes.append(frame)
    condition.broadcast()
  }

  func startConsumer() -> Bool {
    condition.lock()
    defer { condition.unlock() }
    guard captureActive, !consumerActive, !overflowed else { return false }
    consumerActive = true
    return true
  }

  func stopConsumer() {
    condition.lock()
    consumerActive = false
    bytes.removeAll(keepingCapacity: true)
    readOffset = 0
    overflowed = false
    producedPCM = false
    condition.broadcast()
    condition.unlock()
  }

  func endCapture(clearBufferedFrames: Bool) {
    condition.lock()
    captureActive = false
    if clearBufferedFrames {
      bytes.removeAll(keepingCapacity: true)
      readOffset = 0
      overflowed = false
    }
    condition.broadcast()
    condition.unlock()
  }

  func read(exactLength: Int) -> Data? {
    guard exactLength > 0, exactLength <= Self.maximumBufferedBytes else {
      return nil
    }
    condition.lock()
    defer { condition.unlock() }
    while consumerActive,
          captureActive,
          !overflowed,
          unreadByteCountLocked < exactLength {
      let deadline = Date(timeIntervalSinceNow: Self.readWaitSeconds)
      _ = condition.wait(until: deadline)
    }
    guard consumerActive, !overflowed, unreadByteCountLocked >= exactLength else {
      return nil
    }
    guard let result = copyUnreadBytesLocked(exactLength: exactLength) else {
      return nil
    }
    readOffset += exactLength
    compactIfNeededLocked()
    return result
  }

  private var unreadByteCountLocked: Int { bytes.count - readOffset }

  // The condition lock protects the mutable Data backing store and its cursor.
  private func copyUnreadBytesLocked(exactLength: Int) -> Data? {
    return bytes.withUnsafeBytes { rawBuffer in
      guard let baseAddress = rawBuffer.baseAddress else { return nil }
      return Data(
        bytes: baseAddress.advanced(by: readOffset),
        count: exactLength
      )
    }
  }

  private func compactIfNeededLocked() {
    guard readOffset > 0 else { return }
    if readOffset == bytes.count {
      bytes.removeAll(keepingCapacity: true)
      readOffset = 0
    } else if readOffset >= 128 * voiceRecorderPCM16FrameBytes,
              readOffset * 2 >= bytes.count {
      bytes.removeFirst(readOffset)
      readOffset = 0
    }
  }
}

struct VoiceRecorderPCM16DrainPacer {
  static let intervalMilliseconds = 20
  private(set) var generation: UInt64 = 0
  private(set) var scheduled = false

  mutating func request(
    hasListener: Bool,
    hasFrames: Bool,
    overflowed: Bool
  ) -> UInt64? {
    guard hasListener, hasFrames, !overflowed, !scheduled else { return nil }
    scheduled = true
    return generation
  }

  mutating func beginDelivery(token: UInt64) -> Bool {
    guard scheduled, token == generation else { return false }
    scheduled = false
    return true
  }

  mutating func cancel() {
    generation &+= 1
    scheduled = false
  }
}

func validatedVoiceRecorderM4ADurationSeconds(at url: URL) throws -> Int {
  guard url.isFileURL, url.pathExtension.lowercased() == "m4a" else {
    throw VoiceRecorderM4AValidationError.invalidContainer
  }

  var audioFileID: AudioFileID?
  let openStatus = AudioFileOpenURL(
    url as CFURL,
    .readPermission,
    0,
    &audioFileID
  )
  guard openStatus == noErr, let audioFileID else {
    throw VoiceRecorderM4AValidationError.invalidContainer
  }
  defer { AudioFileClose(audioFileID) }

  var fileType: AudioFileTypeID = 0
  var propertySize = UInt32(MemoryLayout<AudioFileTypeID>.size)
  let typeStatus = AudioFileGetProperty(
    audioFileID,
    kAudioFilePropertyFileFormat,
    &propertySize,
    &fileType
  )
  guard typeStatus == noErr, fileType == kAudioFileM4AType else {
    throw VoiceRecorderM4AValidationError.invalidContainer
  }

  do {
    let file = try AVAudioFile(forReading: url)
    let frameCount = file.length
    let sampleRate = file.processingFormat.sampleRate
    let channelCount = file.processingFormat.channelCount
    let durationSeconds = ceil(Double(frameCount) / sampleRate)
    guard frameCount > 0,
          sampleRate.isFinite,
          sampleRate > 0,
          channelCount > 0,
          durationSeconds.isFinite,
          durationSeconds > 0,
          durationSeconds <= Double(Int.max) else {
      throw VoiceRecorderM4AValidationError.unreadableAudio
    }
    return Int(durationSeconds)
  } catch let error as VoiceRecorderM4AValidationError {
    throw error
  } catch {
    throw VoiceRecorderM4AValidationError.unreadableAudio
  }
}

func validatedVoiceprintWAVDurationSeconds(at url: URL) throws -> Int {
  try validatedPCM16WAVDurationSeconds(
    at: url,
    minimumDurationMilliseconds: voiceprintWAVMinimumDurationMilliseconds,
    maximumDurationMilliseconds: voiceprintWAVMaximumAcceptedDurationMilliseconds,
    maximumBytes: voiceprintWAVMaximumBytes,
    voiceprintErrors: true
  )
}

func validatedSharedPcmWAVDurationSeconds(at url: URL) throws -> Int {
  try validatedPCM16WAVDurationSeconds(
    at: url,
    minimumDurationMilliseconds: nil,
    maximumDurationMilliseconds: nil,
    maximumBytes: nil,
    voiceprintErrors: false
  )
}

private func validatedPCM16WAVDurationSeconds(
  at url: URL,
  minimumDurationMilliseconds: Int64?,
  maximumDurationMilliseconds: Int64?,
  maximumBytes: Int?,
  voiceprintErrors: Bool
) throws -> Int {
  func fail(_ voiceprint: VoiceprintWAVValidationError, _ shared: SharedPcmWAVValidationError) throws -> Never {
    if voiceprintErrors { throw voiceprint }
    throw shared
  }
  guard url.isFileURL, url.pathExtension.lowercased() == "wav" else {
    try fail(.invalidContainer, .invalidContainer)
  }
  let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
  guard fileSize > 44 else {
    try fail(.invalidContainer, .invalidContainer)
  }
  if let maximumBytes, fileSize > maximumBytes {
    try fail(.fileTooLarge, .invalidContainer)
  }

  var audioFileID: AudioFileID?
  let openStatus = AudioFileOpenURL(url as CFURL, .readPermission, 0, &audioFileID)
  guard openStatus == noErr, let audioFileID else {
    try fail(.invalidContainer, .invalidContainer)
  }
  defer { AudioFileClose(audioFileID) }

  var fileType: AudioFileTypeID = 0
  var fileTypeSize = UInt32(MemoryLayout<AudioFileTypeID>.size)
  guard AudioFileGetProperty(
    audioFileID,
    kAudioFilePropertyFileFormat,
    &fileTypeSize,
    &fileType
  ) == noErr, fileType == kAudioFileWAVEType else {
    try fail(.invalidContainer, .invalidContainer)
  }

  var format = AudioStreamBasicDescription()
  var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
  guard AudioFileGetProperty(
    audioFileID,
    kAudioFilePropertyDataFormat,
    &formatSize,
    &format
  ) == noErr,
        format.mFormatID == kAudioFormatLinearPCM,
        format.mSampleRate == voiceprintWAVSampleRate,
        format.mChannelsPerFrame == voiceprintWAVChannelCount,
        format.mBitsPerChannel == voiceprintWAVBitDepth,
        format.mFormatFlags & kAudioFormatFlagIsFloat == 0,
        format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0 else {
    try fail(.invalidFormat, .invalidFormat)
  }

  let file = try AVAudioFile(forReading: url)
  let duration = Double(file.length) / format.mSampleRate
  guard duration.isFinite,
        duration > 0 else {
    try fail(.invalidDuration, .invalidDuration)
  }
  let durationMilliseconds = file.length * 1_000 / Int64(voiceprintWAVSampleRate)
  if let minimumDurationMilliseconds,
     durationMilliseconds < minimumDurationMilliseconds {
    try fail(.invalidDuration, .invalidDuration)
  }
  if let maximumDurationMilliseconds,
     durationMilliseconds > maximumDurationMilliseconds {
    try fail(.invalidDuration, .invalidDuration)
  }
  return Int(ceil(duration))
}

/// Owns iOS microphone authorization and private AVAudioRecorder recordings.
/// Flutter receives only opaque app-private references, never sandbox paths.
private struct VoiceRecorderLevelSnapshot {
  let capturedAt: Date
  let average: Double
  let peak: Double
}

private enum VoiceRecorderLevelSource {
  case recorder(AVAudioRecorder)
  case sharedPCM
}

final class VoiceRecorderBridge: NSObject, AVAudioRecorderDelegate, FlutterStreamHandler {
  private final class PCMStreamHandler: NSObject, FlutterStreamHandler {
    weak var owner: VoiceRecorderBridge?

    init(owner: VoiceRecorderBridge) {
      self.owner = owner
    }

    func onListen(
      withArguments arguments: Any?,
      eventSink events: @escaping FlutterEventSink
    ) -> FlutterError? {
      owner?.attachPCMEventSink(events)
      return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
      owner?.detachPCMEventSink()
      return nil
    }
  }

  private static var activeBridges: [VoiceRecorderBridge] = []
  private static let channelName = "huahuoai/voice_recorder"
  private static let levelChannelName = "huahuoai/voice_recorder_levels"
  private static let pcmChannelName = "huahuoai/voice_recorder_pcm16"
  private static let stateIdle = "idle"
  private static let stateRecording = "recording"
  private static let statePaused = "paused"
  private static let maximumBufferedPCMFrames = 1_125
  private static let sharedPCMFormat = AVAudioFormat(
    commonFormat: .pcmFormatInt16,
    sampleRate: voiceprintWAVSampleRate,
    channels: AVAudioChannelCount(voiceprintWAVChannelCount),
    interleaved: true
  )!

  private let methodChannel: FlutterMethodChannel
  private let levelChannel: FlutterEventChannel
  private let pcmChannel: FlutterEventChannel
  private var pcmStreamHandler: PCMStreamHandler?
  private var recorder: AVAudioRecorder?
  private var sharedPCMEngine: AVAudioEngine?
  private var sharedPCMFile: AVAudioFile?
  private var sharedPCMConverter: AVAudioConverter?
  private let sharedPCMLock = NSLock()
  private var sharedPCMChunker = VoiceRecorderPCM16FrameChunker()
  private var acceptingSharedPCMInput = false
  private var sharedPCMCaptureFailed = false
  private var sharedPCMAverage = 0.0
  private var sharedPCMPeak = 0.0
  private var levelEventSink: FlutterEventSink?
  private let levelMeteringQueue = DispatchQueue(
    label: "com.hangzhouchuda.huahuoai.voice-level-metering",
    qos: .utility
  )
  private let levelGenerationLock = NSLock()
  private let recorderMeteringLock = NSLock()
  private var levelGeneration: UInt64 = 0
  private var levelTimer: DispatchSourceTimer?
  private let pcmFrameLock = NSLock()
  private var pcmEventSink: FlutterEventSink?
  private var earlyPCMFrames = VoiceRecorderPCM16EarlyFrameQueue(
    capacityFrames: maximumBufferedPCMFrames
  )
  private var pcmDrainPacer = VoiceRecorderPCM16DrainPacer()
  private var pcmOverflowErrorScheduled = false
  private var pcmOverflowErrorDeliveredToSink = false
  private var recordingID: String?
  private var recordingScene: String?
  private var recordingStartedAt: Date?
  private var pausedAt: Date?
  private var pausedDuration: TimeInterval = 0
  private var partURL: URL?
  private var recordingAccountDirectory: String?
  private var state = stateIdle
  private var audioInterruptionObserver: NSObjectProtocol?
  private var audioRouteChangeObserver: NSObjectProtocol?

  static func register(with messenger: FlutterBinaryMessenger) {
    activeBridges.append(VoiceRecorderBridge(messenger: messenger))
  }

  private init(messenger: FlutterBinaryMessenger) {
    methodChannel = FlutterMethodChannel(name: Self.channelName, binaryMessenger: messenger)
    levelChannel = FlutterEventChannel(name: Self.levelChannelName, binaryMessenger: messenger)
    pcmChannel = FlutterEventChannel(name: Self.pcmChannelName, binaryMessenger: messenger)
    super.init()
    levelChannel.setStreamHandler(self)
    let streamHandler = PCMStreamHandler(owner: self)
    pcmStreamHandler = streamHandler
    pcmChannel.setStreamHandler(streamHandler)
    audioInterruptionObserver = NotificationCenter.default.addObserver(
      forName: AVAudioSession.interruptionNotification,
      object: AVAudioSession.sharedInstance(),
      queue: .main
    ) { [weak self] notification in
      self?.handleAudioInterruption(notification)
    }
    audioRouteChangeObserver = NotificationCenter.default.addObserver(
      forName: AVAudioSession.routeChangeNotification,
      object: AVAudioSession.sharedInstance(),
      queue: .main
    ) { [weak self] notification in
      self?.handleAudioRouteChange(notification)
    }
    methodChannel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterError(
          code: "NATIVE_VOICE_RECORDER_DRIVER_UNAVAILABLE",
          message: "Voice recorder bridge is unavailable.",
          details: nil
        ))
        return
      }
      self.handle(call, result: result)
    }
  }

  deinit {
    stopLevelMetering(emitBaseline: false)
    if let audioInterruptionObserver {
      NotificationCenter.default.removeObserver(audioInterruptionObserver)
    }
    if let audioRouteChangeObserver {
      NotificationCenter.default.removeObserver(audioRouteChangeObserver)
    }
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    levelEventSink = events
    if state == Self.stateRecording {
      startLevelMetering()
    } else {
      emitLevel(average: 0, peak: 0)
    }
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    stopLevelMetering(emitBaseline: false)
    levelEventSink = nil
    return nil
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getMicrophonePermission":
      result(microphonePermissionMap())
    case "requestMicrophonePermission":
      requestMicrophonePermission(result)
    case "getRecordingState":
      result(recordingStateMap())
    case "startRecording":
      startRecording(call.arguments, result: result)
    case "pauseRecording":
      pauseRecording(call.arguments, result: result)
    case "resumeRecording":
      resumeRecording(call.arguments, result: result)
    case "stopRecording":
      stopRecording(call.arguments, result: result)
    case "cancelRecording":
      cancelRecording(call.arguments, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func requestMicrophonePermission(_ result: @escaping FlutterResult) {
    let session = AVAudioSession.sharedInstance()
    switch session.recordPermission {
    case .granted, .denied:
      result(microphonePermissionMap())
    case .undetermined:
      session.requestRecordPermission { granted in
        DispatchQueue.main.async {
          result(self.permissionMap(state: granted ? "granted" : "denied", canAskAgain: false))
        }
      }
    @unknown default:
      result(permissionMap(state: "unavailable", canAskAgain: false))
    }
  }

  private func startRecording(_ rawArguments: Any?, result: @escaping FlutterResult) {
    guard recorder == nil, sharedPCMEngine == nil else {
      result(error("VOICE_RECORDER_BUSY", "A voice recording is already active."))
      return
    }
    guard let arguments = rawArguments as? [String: Any],
          let scene = arguments["scene"] as? String,
          scene == "work_ai" || scene == "feed_ai" || scene == "monologue" || scene == "internal" || scene == "meeting" || scene == "voiceprint" else {
      result(error("VOICE_RECORDER_SCENE_INVALID", "Voice recording scene is invalid."))
      return
    }
    let accountDirectory: String?
    if arguments.keys.contains("accountDirectory") {
      guard let directory = validatedAccountDirectory(arguments["accountDirectory"]) else {
        result(error("VOICE_RECORDER_ACCOUNT_DIRECTORY_INVALID", "Private voice storage scope is invalid."))
        return
      }
      accountDirectory = directory
    } else {
      accountDirectory = nil
    }

    switch AVAudioSession.sharedInstance().recordPermission {
    case .granted:
      startGrantedRecording(scene: scene, accountDirectory: accountDirectory, result: result)
    case .denied:
      result(error("VOICE_RECORDER_PERMISSION_DENIED", "Microphone permission has not been granted."))
    case .undetermined:
      AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
        DispatchQueue.main.async {
          guard let self else {
            result(FlutterError(
              code: "NATIVE_VOICE_RECORDER_DRIVER_UNAVAILABLE",
              message: "Voice recorder bridge is unavailable.",
              details: nil
            ))
            return
          }
          guard granted else {
            result(self.error("VOICE_RECORDER_PERMISSION_DENIED", "Microphone permission has not been granted."))
            return
          }
          self.startGrantedRecording(scene: scene, accountDirectory: accountDirectory, result: result)
        }
      }
    @unknown default:
      result(error("VOICE_RECORDER_PERMISSION_UNAVAILABLE", "Microphone permission is unavailable."))
    }
  }

  private func startGrantedRecording(
    scene: String,
    accountDirectory: String?,
    result: @escaping FlutterResult
  ) {
    let id = "voice-\(UUID().uuidString.lowercased())"
    if isSharedPCMScene(scene) {
      startGrantedSharedPCMRecording(
        id: id,
        scene: scene,
        accountDirectory: accountDirectory,
        result: result
      )
      return
    }
    do {
      let outputURL = try partURLForRecording(
        id: id,
        scene: scene,
        accountDirectory: accountDirectory
      )
      try? FileManager.default.removeItem(at: outputURL)
      partURL = outputURL
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker])
      try session.setActive(true)
      let settings = recordingSettings(scene: scene)
      let activeRecorder = try AVAudioRecorder(url: outputURL, settings: settings)
      activeRecorder.delegate = self
      activeRecorder.isMeteringEnabled = true
      activeRecorder.prepareToRecord()
      let didStart = scene == "voiceprint"
        ? activeRecorder.record(forDuration: voiceprintWAVCaptureDurationSeconds)
        : activeRecorder.record()
      guard didStart else {
        try? FileManager.default.removeItem(at: outputURL)
        partURL = nil
        deactivateAudioSession()
        result(error("VOICE_RECORDER_START_FAILED", "Voice recording did not start."))
        return
      }
      let startedAt = Date()
      recorder = activeRecorder
      recordingID = id
      recordingScene = scene
      recordingStartedAt = startedAt
      pausedAt = nil
      pausedDuration = 0
      recordingAccountDirectory = accountDirectory
      state = Self.stateRecording
      startLevelMetering()
      result(recordingStateMap())
    } catch {
      clearRecordingState(deletePart: true)
      deactivateAudioSession()
      result(self.error("VOICE_RECORDER_START_FAILED", "Voice recording did not start."))
    }
  }

  private func startGrantedSharedPCMRecording(
    id: String,
    scene: String,
    accountDirectory: String?,
    result: @escaping FlutterResult
  ) {
    do {
      let outputURL = try partURLForRecording(
        id: id,
        scene: scene,
        accountDirectory: accountDirectory
      )
      try? FileManager.default.removeItem(at: outputURL)
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker])
      try? session.setPreferredSampleRate(voiceprintWAVSampleRate)
      try? session.setPreferredInputNumberOfChannels(Int(voiceprintWAVChannelCount))
      try session.setActive(true)

      let engine = AVAudioEngine()
      let input = engine.inputNode
      let inputFormat = input.outputFormat(forBus: 0)
      guard inputFormat.sampleRate > 0,
            inputFormat.channelCount > 0,
            let converter = AVAudioConverter(from: inputFormat, to: Self.sharedPCMFormat) else {
        throw VoiceRecorderError.invalidPCMFormat
      }
      let file = try AVAudioFile(
        forWriting: outputURL,
        settings: Self.sharedPCMFormat.settings,
        commonFormat: .pcmFormatInt16,
        interleaved: true
      )
      resetPCMFrameBuffer()
      VoiceRecorderPCM16NativeHub.shared.beginCapture()
      sharedPCMLock.lock()
      sharedPCMChunker.reset()
      acceptingSharedPCMInput = true
      sharedPCMCaptureFailed = false
      sharedPCMAverage = 0
      sharedPCMPeak = 0
      sharedPCMEngine = engine
      sharedPCMFile = file
      sharedPCMConverter = converter
      sharedPCMLock.unlock()
      let startedAt = Date()
      partURL = outputURL
      recordingID = id
      recordingScene = scene
      recordingStartedAt = startedAt
      pausedAt = nil
      pausedDuration = 0
      recordingAccountDirectory = accountDirectory
      state = Self.stateRecording
      input.installTap(
        onBus: 0,
        bufferSize: 1_024,
        format: inputFormat
      ) { [weak self] buffer, _ in
        self?.consumeSharedPCMInput(buffer)
      }
      engine.prepare()
      try engine.start()
      startLevelMetering()
      result(recordingStateMap())
    } catch {
      VoiceRecorderPCM16NativeHub.shared.endCapture(clearBufferedFrames: true)
      stopSharedPCMEngine(clearBufferedFrames: true)
      clearRecordingState(deletePart: true)
      deactivateAudioSession()
      result(self.error("VOICE_RECORDER_START_FAILED", "Voice recording did not start."))
    }
  }

  private func consumeSharedPCMInput(_ input: AVAudioPCMBuffer) {
    sharedPCMLock.lock()
    defer { sharedPCMLock.unlock() }
    guard acceptingSharedPCMInput,
          let converter = sharedPCMConverter,
          let file = sharedPCMFile else { return }

    let capacity = AVAudioFrameCount(
      ceil(Double(input.frameLength) * Self.sharedPCMFormat.sampleRate / input.format.sampleRate)
    ) + 32
    guard capacity > 0,
          let output = AVAudioPCMBuffer(
            pcmFormat: Self.sharedPCMFormat,
            frameCapacity: capacity
          ) else {
      sharedPCMCaptureFailed = true
      return
    }
    var suppliedInput = false
    var conversionError: NSError?
    let status = converter.convert(to: output, error: &conversionError) {
      _, inputStatus in
      guard !suppliedInput else {
        inputStatus.pointee = .noDataNow
        return nil
      }
      suppliedInput = true
      inputStatus.pointee = .haveData
      return input
    }
    guard conversionError == nil,
          status != .error,
          output.frameLength > 0 else {
      sharedPCMCaptureFailed = true
      return
    }

    do {
      try file.write(from: output)
    } catch {
      sharedPCMCaptureFailed = true
      return
    }

    let audioBuffer = output.audioBufferList.pointee.mBuffers
    let byteCount = Int(audioBuffer.mDataByteSize)
    guard byteCount > 0,
          byteCount.isMultiple(of: MemoryLayout<Int16>.size),
          let rawBytes = audioBuffer.mData else {
      sharedPCMCaptureFailed = true
      return
    }
    let bytes = Data(bytes: rawBytes, count: byteCount)
    updateSharedPCMLevel(bytes)
    for frame in sharedPCMChunker.append(bytes) {
      enqueuePCMFrame(frame)
    }
  }

  private func updateSharedPCMLevel(_ bytes: Data) {
    var sum = 0.0
    var peak = 0
    var sampleCount = 0
    bytes.withUnsafeBytes { rawBuffer in
      for sample in rawBuffer.bindMemory(to: Int16.self) {
        let magnitude = abs(Int(sample))
        sum += Double(magnitude)
        peak = max(peak, magnitude)
        sampleCount += 1
      }
    }
    guard sampleCount > 0 else { return }
    sharedPCMAverage = min(1, max(0, sum / Double(sampleCount) / Double(Int16.max)))
    sharedPCMPeak = min(1, max(0, Double(peak) / Double(Int16.max)))
  }

  private func pauseRecording(_ rawArguments: Any?, result: @escaping FlutterResult) {
    guard validateExpectedSession(rawArguments, result: result) else { return }
    if let engine = sharedPCMEngine,
       let scene = recordingScene,
       isSharedPCMScene(scene),
       state == Self.stateRecording {
      stopLevelMetering(emitBaseline: true)
      engine.pause()
      suspendSharedPCMInput(resetPartialFrame: true)
      pausedAt = Date()
      state = Self.statePaused
      result(recordingStateMap())
      return
    }
    guard let activeRecorder = recorder, state == Self.stateRecording else {
      result(error("VOICE_RECORDER_NOT_RECORDING", "No recording is active."))
      return
    }
    stopLevelMetering(emitBaseline: true)
    activeRecorder.pause()
    pausedAt = Date()
    state = Self.statePaused
    result(recordingStateMap())
  }

  private func handleAudioInterruption(_ notification: Notification) {
    guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber,
          let interruption = AVAudioSession.InterruptionType(rawValue: rawType.uintValue),
          interruption == .began,
          state == Self.stateRecording else { return }
    pauseForSystemAudioChange()
  }

  private func handleAudioRouteChange(_ notification: Notification) {
    guard state == Self.stateRecording else { return }
    guard
      let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey]
        as? NSNumber,
      let reason = AVAudioSession.RouteChangeReason(
        rawValue: rawReason.uintValue
      ),
      reason == .oldDeviceUnavailable ||
        reason == .noSuitableRouteForCategory,
      AVAudioSession.sharedInstance().currentRoute.inputs.isEmpty
    else { return }
    NSLog(
      "[VoiceRecorder] stage=input_route_unavailable reason=%@",
      String(rawReason.uintValue)
    )
    pauseForSystemAudioChange()
  }

  private func pauseForSystemAudioChange() {
    stopLevelMetering(emitBaseline: true)
    if let engine = sharedPCMEngine,
       let scene = recordingScene,
       isSharedPCMScene(scene) {
      engine.pause()
      suspendSharedPCMInput(resetPartialFrame: true)
    } else {
      recorder?.pause()
    }
    pausedAt = Date()
    state = Self.statePaused
  }

  private func resumeRecording(_ rawArguments: Any?, result: @escaping FlutterResult) {
    guard validateExpectedSession(rawArguments, result: result) else { return }
    if let engine = sharedPCMEngine,
       let scene = recordingScene,
       isSharedPCMScene(scene),
       state == Self.statePaused {
      do {
        try AVAudioSession.sharedInstance().setActive(true)
        resumeSharedPCMInput()
        try engine.start()
        if let pausedAt {
          pausedDuration += Date().timeIntervalSince(pausedAt)
        }
        self.pausedAt = nil
        state = Self.stateRecording
        startLevelMetering()
        result(recordingStateMap())
      } catch {
        suspendSharedPCMInput(resetPartialFrame: true)
        result(self.error("VOICE_RECORDER_RESUME_FAILED", "Voice recording could not resume."))
      }
      return
    }
    guard let activeRecorder = recorder, state == Self.statePaused else {
      result(error("VOICE_RECORDER_NOT_PAUSED", "Voice recording is not paused."))
      return
    }
    do {
      try AVAudioSession.sharedInstance().setActive(true)
      guard activeRecorder.record() else {
        result(error("VOICE_RECORDER_RESUME_FAILED", "Voice recording could not resume."))
        return
      }
      if let pausedAt {
        pausedDuration += Date().timeIntervalSince(pausedAt)
      }
      self.pausedAt = nil
      state = Self.stateRecording
      startLevelMetering()
      result(recordingStateMap())
    } catch {
      result(self.error("VOICE_RECORDER_RESUME_FAILED", "Voice recording could not resume."))
    }
  }

  private func stopRecording(_ rawArguments: Any?, result: @escaping FlutterResult) {
    guard validateExpectedSession(rawArguments, result: result) else { return }
    if let scene = recordingScene, isSharedPCMScene(scene) {
      stopSharedPCMRecording(result)
      return
    }
    guard let activeRecorder = recorder,
          let id = recordingID,
          let scene = recordingScene,
          let sourceURL = partURL else {
      result(error("VOICE_RECORDER_NOT_ACTIVE", "No active voice recording exists."))
      return
    }

    let recordedAt = recordingStartedAt.map { Self.isoFormatter.string(from: $0) }
    stopLevelMetering(emitBaseline: true)
    activeRecorder.stop()
    recorder = nil
    deactivateAudioSession()

    do {
      let fileSize = try sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
      guard fileSize > 0 else {
        throw VoiceRecorderError.emptyFile
      }
      let finalURL = try finalURLForRecording(id: id, scene: scene)
      if FileManager.default.fileExists(atPath: finalURL.path) {
        try FileManager.default.removeItem(at: finalURL)
      }
      try FileManager.default.moveItem(at: sourceURL, to: finalURL)
      let finalSize = try finalURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
      guard finalSize > 0 else {
        throw VoiceRecorderError.emptyFile
      }
      let durationSeconds = scene == "voiceprint"
        ? try validatedVoiceprintWAVDurationSeconds(at: finalURL)
        : try validatedVoiceRecorderM4ADurationSeconds(at: finalURL)
      let sha256 = try sha256Hex(for: finalURL)
      guard Self.isSHA256(sha256) else {
        throw VoiceRecorderError.invalidChecksum
      }
      var payload: [String: Any] = [
        "recordingId": id,
        "scene": scene,
        "appPrivateUri": appPrivateURI(recordingID: id, scene: scene),
        "fileName": finalFileName(recordingID: id, scene: scene),
        "mimeType": scene == "voiceprint" ? "audio/wav" : "audio/mp4",
        "sizeBytes": finalSize,
        "durationSeconds": durationSeconds,
        "sha256": sha256,
      ]
      if scene == "voiceprint" {
        payload["sampleRateHz"] = Int(voiceprintWAVSampleRate)
        payload["bitDepth"] = Int(voiceprintWAVBitDepth)
        payload["channelCount"] = Int(voiceprintWAVChannelCount)
      }
      if let recordedAt {
        payload["recordedAt"] = recordedAt
      }
      clearRecordingState(deletePart: false)
      result(payload)
    } catch VoiceRecorderError.emptyFile {
      try? FileManager.default.removeItem(at: sourceURL)
      if let finalURL = try? finalURLForRecording(id: id, scene: scene) {
        try? FileManager.default.removeItem(at: finalURL)
      }
      clearRecordingState(deletePart: false)
      result(error("VOICE_RECORDER_EMPTY_FILE", "Voice recording file is empty."))
    } catch {
      try? FileManager.default.removeItem(at: sourceURL)
      if let finalURL = try? finalURLForRecording(id: id, scene: scene) {
        try? FileManager.default.removeItem(at: finalURL)
      }
      clearRecordingState(deletePart: false)
      result(self.error("VOICE_RECORDER_FILE_UNAVAILABLE", "Voice recording file is unavailable."))
    }
  }

  private func stopSharedPCMRecording(_ result: @escaping FlutterResult) {
    guard sharedPCMEngine != nil,
          let id = recordingID,
          let scene = recordingScene,
          isSharedPCMScene(scene),
          let sourceURL = partURL else {
      result(error("VOICE_RECORDER_NOT_ACTIVE", "No active voice recording exists."))
      return
    }
    let recordedAt = recordingStartedAt.map { Self.isoFormatter.string(from: $0) }
    stopLevelMetering(emitBaseline: true)
    stopSharedPCMEngine(clearBufferedFrames: false)
    deactivateAudioSession()

    do {
      guard !sharedPCMCaptureFailed else {
        throw VoiceRecorderError.invalidPCMFormat
      }
      let fileSize = try sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
      guard fileSize > 44 else { throw VoiceRecorderError.emptyFile }
      let durationSeconds = try validatedSharedPcmWAVDurationSeconds(at: sourceURL)
      let finalURL = try finalURLForRecording(id: id, scene: scene)
      if FileManager.default.fileExists(atPath: finalURL.path) {
        try FileManager.default.removeItem(at: finalURL)
      }
      try FileManager.default.moveItem(at: sourceURL, to: finalURL)
      let finalSize = try finalURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
      guard finalSize > 44 else { throw VoiceRecorderError.emptyFile }
      let sha256 = try sha256Hex(for: finalURL)
      guard Self.isSHA256(sha256) else { throw VoiceRecorderError.invalidChecksum }
      var payload: [String: Any] = [
        "recordingId": id,
        "scene": scene,
        "appPrivateUri": appPrivateURI(recordingID: id, scene: scene),
        "fileName": finalFileName(recordingID: id, scene: scene),
        "mimeType": "audio/wav",
        "sizeBytes": finalSize,
        "durationSeconds": durationSeconds,
        "sha256": sha256,
        "sampleRateHz": Int(voiceprintWAVSampleRate),
        "bitDepth": Int(voiceprintWAVBitDepth),
        "channelCount": Int(voiceprintWAVChannelCount),
      ]
      if let recordedAt { payload["recordedAt"] = recordedAt }
      clearRecordingState(deletePart: false)
      result(payload)
    } catch {
      try? FileManager.default.removeItem(at: sourceURL)
      if let finalURL = try? finalURLForRecording(id: id, scene: scene) {
        try? FileManager.default.removeItem(at: finalURL)
      }
      clearRecordingState(deletePart: false)
      result(self.error("VOICE_RECORDER_FILE_UNAVAILABLE", "Voice recording file is unavailable."))
    }
  }

  private func cancelRecording(_ rawArguments: Any?, result: @escaping FlutterResult) {
    guard validateExpectedSession(rawArguments, result: result) else { return }
    stopLevelMetering(emitBaseline: true)
    recorder?.stop()
    recorder = nil
    stopSharedPCMEngine(clearBufferedFrames: true)
    deactivateAudioSession()
    clearRecordingState(deletePart: true)
    result(recordingStateMap())
  }

  private func validateExpectedSession(
    _ rawArguments: Any?,
    result: @escaping FlutterResult
  ) -> Bool {
    guard let rawArguments else { return true }
    guard let arguments = rawArguments as? [String: Any] else {
      result(error(
        "VOICE_RECORDER_SESSION_MISMATCH",
        "The active voice recording does not match the expected session."
      ))
      return false
    }
    let hasExpectedScene = arguments.keys.contains("expectedScene")
    let hasExpectedRecordingID = arguments.keys.contains("expectedRecordingId")
    if !hasExpectedScene && !hasExpectedRecordingID { return true }
    guard hasExpectedScene,
          hasExpectedRecordingID,
          let expectedScene = arguments["expectedScene"] as? String,
          let expectedRecordingID = arguments["expectedRecordingId"] as? String,
          expectedScene == recordingScene,
          expectedRecordingID == recordingID else {
      result(error(
        "VOICE_RECORDER_SESSION_MISMATCH",
        "The active voice recording does not match the expected session."
      ))
      return false
    }
    return true
  }

  private func microphonePermissionMap() -> [String: Any] {
    switch AVAudioSession.sharedInstance().recordPermission {
    case .granted:
      return permissionMap(state: "granted", canAskAgain: false)
    case .denied:
      return permissionMap(state: "denied", canAskAgain: false)
    case .undetermined:
      return permissionMap(state: "not_determined", canAskAgain: true)
    @unknown default:
      return permissionMap(state: "unavailable", canAskAgain: false)
    }
  }

  private func permissionMap(state: String, canAskAgain: Bool) -> [String: Any] {
    ["state": state, "canAskAgain": canAskAgain]
  }

  private func recordingStateMap() -> [String: Any] {
    var payload: [String: Any] = ["state": state]
    if let id = recordingID,
       let scene = recordingScene,
       let startedAt = recordingStartedAt,
       state != Self.stateIdle {
      payload["recordingId"] = id
      payload["scene"] = scene
      payload["startedAt"] = Self.isoFormatter.string(from: startedAt)
      let elapsed = elapsedSeconds()
      let reportedElapsed = scene == "voiceprint"
        ? Int(floor(elapsed))
        : Int(ceil(elapsed))
      payload["elapsedSeconds"] = max(0, reportedElapsed)
    }
    return payload
  }

  private func elapsedSeconds(now: Date = Date()) -> TimeInterval {
    guard let startedAt = recordingStartedAt else { return 0 }
    let activePause = pausedAt.map { now.timeIntervalSince($0) } ?? 0
    return max(0, now.timeIntervalSince(startedAt) - pausedDuration - activePause)
  }

  private func startLevelMetering() {
    stopLevelMetering(emitBaseline: false)
    guard levelEventSink != nil,
          state == Self.stateRecording,
          recorder != nil || sharedPCMEngine != nil else { return }
    let source: VoiceRecorderLevelSource
    if let scene = recordingScene, isSharedPCMScene(scene), sharedPCMEngine != nil {
      source = .sharedPCM
    } else if let recorder {
      source = .recorder(recorder)
    } else {
      return
    }
    levelGenerationLock.lock()
    levelGeneration &+= 1
    let generation = levelGeneration
    levelGenerationLock.unlock()
    let timer = DispatchSource.makeTimerSource(queue: levelMeteringQueue)
    timer.schedule(
      deadline: .now() + .milliseconds(50),
      repeating: .milliseconds(50),
      leeway: .milliseconds(5)
    )
    timer.setEventHandler { [weak self] in
      self?.sampleCurrentLevel(source: source, generation: generation)
    }
    levelTimer = timer
    timer.resume()
  }

  private func stopLevelMetering(emitBaseline: Bool) {
    levelGenerationLock.lock()
    levelGeneration &+= 1
    let generation = levelGeneration
    levelGenerationLock.unlock()
    levelTimer?.cancel()
    levelTimer = nil
    recorderMeteringLock.lock()
    recorderMeteringLock.unlock()
    if emitBaseline {
      postLevelSnapshot(
        VoiceRecorderLevelSnapshot(capturedAt: Date(), average: 0, peak: 0),
        generation: generation,
        requiresRecording: false
      )
    }
  }

  private func sampleCurrentLevel(
    source: VoiceRecorderLevelSource,
    generation: UInt64
  ) {
    dispatchPrecondition(condition: .onQueue(levelMeteringQueue))
    let snapshot: VoiceRecorderLevelSnapshot
    switch source {
    case .sharedPCM:
      guard isLevelGenerationCurrent(generation) else { return }
      sharedPCMLock.lock()
      let average = sharedPCMAverage
      let peak = max(average, sharedPCMPeak)
      sharedPCMLock.unlock()
      guard isLevelGenerationCurrent(generation) else { return }
      snapshot = VoiceRecorderLevelSnapshot(
        capturedAt: Date(),
        average: average,
        peak: peak
      )
    case let .recorder(activeRecorder):
      guard isLevelGenerationCurrent(generation) else { return }
      recorderMeteringLock.lock()
      guard isLevelGenerationCurrent(generation) else {
        recorderMeteringLock.unlock()
        return
      }
      activeRecorder.updateMeters()
      let average = normalizedPower(activeRecorder.averagePower(forChannel: 0))
      snapshot = VoiceRecorderLevelSnapshot(
        capturedAt: Date(),
        average: average,
        peak: max(average, normalizedPower(activeRecorder.peakPower(forChannel: 0)))
      )
      recorderMeteringLock.unlock()
    }
    postLevelSnapshot(snapshot, generation: generation, requiresRecording: true)
  }

  private func normalizedPower(_ decibels: Float) -> Double {
    guard decibels.isFinite, decibels > -80 else { return 0 }
    if decibels >= 0 { return 1 }
    return min(1, max(0, pow(10, Double(decibels) / 20)))
  }

  private func emitLevel(average: Double, peak: Double) {
    emitLevel(VoiceRecorderLevelSnapshot(capturedAt: Date(), average: average, peak: peak))
  }

  private func postLevelSnapshot(
    _ snapshot: VoiceRecorderLevelSnapshot,
    generation: UInt64,
    requiresRecording: Bool
  ) {
    let publish = { [weak self] in
      guard let self,
            self.isLevelGenerationCurrent(generation),
            self.levelEventSink != nil,
            !requiresRecording || self.state == Self.stateRecording else { return }
      self.emitLevel(snapshot)
    }
    if Thread.isMainThread {
      publish()
    } else {
      DispatchQueue.main.async(execute: publish)
    }
  }

  private func isLevelGenerationCurrent(_ generation: UInt64) -> Bool {
    levelGenerationLock.lock()
    defer { levelGenerationLock.unlock() }
    return levelGeneration == generation
  }

  private func emitLevel(_ snapshot: VoiceRecorderLevelSnapshot) {
    dispatchPrecondition(condition: .onQueue(.main))
    guard let levelEventSink else { return }
    levelEventSink([
      "capturedAt": Self.isoFormatter.string(from: snapshot.capturedAt),
      "average": min(1, max(0, snapshot.average)),
      "peak": min(1, max(snapshot.average, snapshot.peak)),
    ])
  }

  private func attachPCMEventSink(_ sink: @escaping FlutterEventSink) {
    pcmFrameLock.lock()
    pcmEventSink = sink
    pcmOverflowErrorDeliveredToSink = false
    let shouldScheduleOverflow = earlyPCMFrames.overflowed && !pcmOverflowErrorScheduled
    if shouldScheduleOverflow { pcmOverflowErrorScheduled = true }
    let drainToken = pcmDrainPacer.request(
      hasListener: true,
      hasFrames: !earlyPCMFrames.isEmpty,
      overflowed: earlyPCMFrames.overflowed
    )
    pcmFrameLock.unlock()
    if shouldScheduleOverflow {
      DispatchQueue.main.async { [weak self] in self?.emitPCMOverflowError() }
    }
    if let drainToken { schedulePCMDrain(token: drainToken) }
  }

  private func detachPCMEventSink() {
    pcmFrameLock.lock()
    pcmEventSink = nil
    pcmDrainPacer.cancel()
    pcmOverflowErrorScheduled = false
    pcmOverflowErrorDeliveredToSink = false
    pcmFrameLock.unlock()
  }

  private func enqueuePCMFrame(_ frame: Data) {
    guard frame.count == voiceRecorderPCM16FrameBytes else {
      sharedPCMCaptureFailed = true
      return
    }
    VoiceRecorderPCM16NativeHub.shared.append(frame)
    pcmFrameLock.lock()
    let accepted = earlyPCMFrames.append(frame)
    if !accepted && earlyPCMFrames.overflowed {
      pcmDrainPacer.cancel()
    }
    let shouldScheduleOverflow = !accepted &&
      earlyPCMFrames.overflowed &&
      pcmEventSink != nil &&
      !pcmOverflowErrorScheduled &&
      !pcmOverflowErrorDeliveredToSink
    if shouldScheduleOverflow { pcmOverflowErrorScheduled = true }
    let drainToken = pcmDrainPacer.request(
      hasListener: accepted && pcmEventSink != nil,
      hasFrames: !earlyPCMFrames.isEmpty,
      overflowed: earlyPCMFrames.overflowed
    )
    pcmFrameLock.unlock()
    if shouldScheduleOverflow {
      DispatchQueue.main.async { [weak self] in self?.emitPCMOverflowError() }
    }
    if let drainToken { schedulePCMDrain(token: drainToken) }
  }

  private func emitPCMOverflowError() {
    dispatchPrecondition(condition: .onQueue(.main))
    pcmFrameLock.lock()
    guard let sink = pcmEventSink, earlyPCMFrames.overflowed else {
      pcmOverflowErrorScheduled = false
      pcmFrameLock.unlock()
      return
    }
    let droppedFrames = earlyPCMFrames.droppedFrameCount
    let capacityFrames = earlyPCMFrames.capacityFrames
    pcmOverflowErrorScheduled = false
    pcmOverflowErrorDeliveredToSink = true
    pcmFrameLock.unlock()
    sink(FlutterError(
      code: "LIVE_ASR_PCM_EARLY_BUFFER_OVERFLOW",
      message: "Realtime audio could not start before the early buffer filled.",
      details: [
        "droppedFrames": droppedFrames,
        "capacityFrames": capacityFrames,
      ]
    ))
  }

  private func schedulePCMDrain(token: UInt64) {
    DispatchQueue.main.asyncAfter(
      deadline: .now() + .milliseconds(VoiceRecorderPCM16DrainPacer.intervalMilliseconds)
    ) { [weak self] in
      self?.deliverNextPCMFrame(token: token)
    }
  }

  private func deliverNextPCMFrame(token: UInt64) {
    dispatchPrecondition(condition: .onQueue(.main))
    pcmFrameLock.lock()
    guard pcmDrainPacer.beginDelivery(token: token),
          let sink = pcmEventSink,
          !earlyPCMFrames.overflowed,
          let frame = earlyPCMFrames.removeFirst() else {
      pcmFrameLock.unlock()
      return
    }
    pcmFrameLock.unlock()
    sink(FlutterStandardTypedData(bytes: frame))

    pcmFrameLock.lock()
    let nextToken = pcmDrainPacer.request(
      hasListener: pcmEventSink != nil,
      hasFrames: !earlyPCMFrames.isEmpty,
      overflowed: earlyPCMFrames.overflowed
    )
    pcmFrameLock.unlock()
    if let nextToken { schedulePCMDrain(token: nextToken) }
  }

  private func resetPCMFrameBuffer() {
    pcmFrameLock.lock()
    earlyPCMFrames.reset()
    pcmDrainPacer.cancel()
    pcmOverflowErrorScheduled = false
    pcmOverflowErrorDeliveredToSink = false
    pcmFrameLock.unlock()
  }

  private func finishPCMFrameDelivery(clearBufferedFrames: Bool) {
    if clearBufferedFrames {
      resetPCMFrameBuffer()
      return
    }
    pcmFrameLock.lock()
    if pcmEventSink == nil {
      earlyPCMFrames.reset()
      pcmDrainPacer.cancel()
    }
    let drainToken = pcmDrainPacer.request(
      hasListener: pcmEventSink != nil,
      hasFrames: !earlyPCMFrames.isEmpty,
      overflowed: earlyPCMFrames.overflowed
    )
    pcmFrameLock.unlock()
    if let drainToken { schedulePCMDrain(token: drainToken) }
  }

  private func stopSharedPCMEngine(clearBufferedFrames: Bool) {
    if let engine = sharedPCMEngine {
      engine.pause()
      suspendSharedPCMInput(resetPartialFrame: false)
      engine.inputNode.removeTap(onBus: 0)
      engine.stop()
    } else {
      suspendSharedPCMInput(resetPartialFrame: false)
    }
    sharedPCMLock.lock()
    acceptingSharedPCMInput = false
    sharedPCMEngine = nil
    sharedPCMFile = nil
    sharedPCMConverter = nil
    sharedPCMChunker.reset()
    sharedPCMLock.unlock()
    VoiceRecorderPCM16NativeHub.shared.endCapture(
      clearBufferedFrames: clearBufferedFrames
    )
    finishPCMFrameDelivery(clearBufferedFrames: clearBufferedFrames)
  }

  private func suspendSharedPCMInput(resetPartialFrame: Bool) {
    sharedPCMLock.lock()
    acceptingSharedPCMInput = false
    if resetPartialFrame { sharedPCMChunker.reset() }
    sharedPCMLock.unlock()
  }

  private func resumeSharedPCMInput() {
    sharedPCMLock.lock()
    sharedPCMChunker.reset()
    acceptingSharedPCMInput = true
    sharedPCMLock.unlock()
  }

  private func isSharedPCMScene(_ scene: String) -> Bool {
    scene == "monologue" || scene == "meeting"
  }

  private func partURLForRecording(
    id: String,
    scene: String,
    accountDirectory: String?
  ) throws -> URL {
    let directory = try recordingStagingDirectory(accountDirectory: accountDirectory)
    return directory.appendingPathComponent(
      voiceRecorderPartFileName(recordingID: id, scene: scene)
    )
  }

  private func finalURLForRecording(id: String, scene: String) throws -> URL {
    let directory = try recordingDirectory(accountDirectory: recordingAccountDirectory)
    return directory.appendingPathComponent(finalFileName(recordingID: id, scene: scene))
  }

  private func recordingDirectory(accountDirectory: String? = nil) throws -> URL {
    let base = try FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    var directory = base
      .appendingPathComponent("HuahuoAI", isDirectory: true)
    if let accountDirectory {
      directory = directory
        .appendingPathComponent("Users", isDirectory: true)
        .appendingPathComponent(accountDirectory, isDirectory: true)
    }
    directory = directory.appendingPathComponent("Recordings", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func recordingStagingDirectory(accountDirectory: String?) throws -> URL {
    let directory = try recordingDirectory(accountDirectory: accountDirectory)
      .appendingPathComponent(".staging", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func validatedAccountDirectory(_ value: Any?) -> String? {
    guard let candidate = value as? String else { return nil }
    let normalized = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let match = normalized.range(
      of: "^u-[a-f0-9]{32}$",
      options: .regularExpression
    ), match.lowerBound == normalized.startIndex,
      match.upperBound == normalized.endIndex else {
      return nil
    }
    return normalized
  }

  private func appPrivateURI(recordingID: String, scene: String) -> String {
    "app-private://\(finalFileName(recordingID: recordingID, scene: scene))"
  }

  private func finalFileName(recordingID: String, scene: String) -> String {
    "\(recordingID).\(voiceRecorderUsesPcmWAV(scene: scene) ? "wav" : "m4a")"
  }

  private func recordingSettings(scene: String) -> [String: Any] {
    if scene == "voiceprint" {
      return [
        AVFormatIDKey: Int(kAudioFormatLinearPCM),
        AVSampleRateKey: voiceprintWAVSampleRate,
        AVNumberOfChannelsKey: Int(voiceprintWAVChannelCount),
        AVLinearPCMBitDepthKey: Int(voiceprintWAVBitDepth),
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsFloatKey: false,
      ]
    }
    return [
      AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
      AVSampleRateKey: 44_100,
      AVNumberOfChannelsKey: 1,
      AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
    ]
  }

  private func sha256Hex(for url: URL) throws -> String {
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

  private func clearRecordingState(deletePart: Bool) {
    stopLevelMetering(emitBaseline: false)
    if deletePart, let partURL {
      try? FileManager.default.removeItem(at: partURL)
    }
    recordingID = nil
    recordingScene = nil
    recordingStartedAt = nil
    pausedAt = nil
    pausedDuration = 0
    partURL = nil
    recordingAccountDirectory = nil
    sharedPCMLock.lock()
    sharedPCMCaptureFailed = false
    acceptingSharedPCMInput = false
    sharedPCMChunker.reset()
    sharedPCMLock.unlock()
    sharedPCMAverage = 0
    sharedPCMPeak = 0
    state = Self.stateIdle
  }

  private func deactivateAudioSession() {
    try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
  }

  private func error(_ code: String, _ message: String) -> FlutterError {
    FlutterError(code: code, message: message, details: nil)
  }

  func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
    guard !flag else { return }
    stopLevelMetering(emitBaseline: true)
    self.recorder = nil
    deactivateAudioSession()
    clearRecordingState(deletePart: true)
  }

  private enum VoiceRecorderError: Error {
    case emptyFile
    case invalidChecksum
    case invalidPCMFormat
  }

  private static func isSHA256(_ value: String) -> Bool {
    value.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
  }

  private static let isoFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()
}
