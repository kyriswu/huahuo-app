import AVFoundation
import CoreImage
import ReplayKit

final class SampleHandler: RPBroadcastSampleHandler {
  private let stateQueue = DispatchQueue(label: "com.huahuoai.screen-capture.extension")
  private let context = CIContext(options: [.cacheIntermediates: false])
  private let pendingVideoFrames = DispatchSemaphore(value: 2)
  private let videoFrameBudget = ScreenCaptureVideoFrameBudget()
  private var lastVideoBudgetSample: TimeInterval?
  private var monitor: DispatchSourceTimer?
  private var heartbeat: DispatchSourceTimer?
  private var request: CaptureRequest?
  private var writer: AVAssetWriter?
  private var videoInput: AVAssetWriterInput?
  private var videoAdaptor: AVAssetWriterInputPixelBufferAdaptor?
  private var audioInput: AVAssetWriterInput?
  private var outputURL: URL?
  private var sessionStartedAt: Date?
  private var firstVideoTime: CMTime?
  private var wroteVideo = false
  private var wroteAudio = false
  private var hasAudioSignal = false
  private var finishing = false

  override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
    stateQueue.async { [weak self] in
      self?.beginCapture()
    }
  }

  override func broadcastPaused() {
    stateQueue.async { [weak self] in
      self?.finalizeCapture(shouldCloseBroadcast: true)
    }
  }

  override func broadcastResumed() {}

  override func broadcastFinished() {
    stateQueue.async { [weak self] in
      self?.finalizeCapture(shouldCloseBroadcast: false)
    }
  }

  override func processSampleBuffer(
    _ sampleBuffer: CMSampleBuffer,
    with sampleBufferType: RPSampleBufferType
  ) {
    if sampleBufferType == .audioMic { return }
    let videoFrame = sampleBufferType == .video
    if videoFrame && !videoFrameBudget.admit(
      presentationSeconds: CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
    ) { return }
    if videoFrame && pendingVideoFrames.wait(timeout: .now()) != .success { return }
    let videoBudget = pendingVideoFrames
    stateQueue.async { [weak self] in
      defer { if videoFrame { videoBudget.signal() } }
      guard let self, !self.finishing else { return }
      switch sampleBufferType {
      case .video:
        self.appendVideo(sampleBuffer)
      case .audioApp:
        self.appendApplicationAudio(sampleBuffer)
      case .audioMic:
        break
      @unknown default:
        break
      }
    }
  }

  private func beginCapture() {
    guard !finishing else { return }
    refreshVideoBudget()
    do {
      let paths = try SharedPaths.resolve()
      let captureRequest = try paths.readRequest()
      request = captureRequest
      if paths.stopRequested(for: captureRequest.sessionID) {
        publishFailure("SCREEN_CAPTURE_CONSENT_CANCELLED")
        closeBroadcast(code: "SCREEN_CAPTURE_CONSENT_CANCELLED")
        return
      }
      let heartbeatURL = paths.root.appendingPathComponent("heartbeat-\(captureRequest.sessionID)")
      let beat = {
        try? Data(String(ProcessInfo.processInfo.systemUptime).utf8).write(to: heartbeatURL, options: .atomic)
      }
      beat()
      let pulse = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.huahuoai.capture.heartbeat"))
      pulse.schedule(deadline: .now() + 2, repeating: 2)
      pulse.setEventHandler { beat() }
      heartbeat = pulse
      pulse.resume()
      try FileManager.default.createDirectory(
        at: paths.stagingDirectory,
        withIntermediateDirectories: true
      )
      let safeID = captureRequest.sessionID.replacingOccurrences(
        of: "[^A-Za-z0-9]",
        with: "",
        options: .regularExpression
      )
      guard !safeID.isEmpty else { throw CaptureError.invalidRequest }
      let fileName = "screen-\(Int(Date().timeIntervalSince1970 * 1000))-\(safeID).mp4"
      let destination = paths.stagingDirectory.appendingPathComponent(fileName)
      try? FileManager.default.removeItem(at: destination)

      let assetWriter = try AVAssetWriter(outputURL: destination, fileType: .mp4)
      let width = even(captureRequest.targetWidth, fallback: 1280)
      let height = even(captureRequest.targetHeight, fallback: 720)
      let videoSettings: [String: Any] = [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
        AVVideoCompressionPropertiesKey: [
          AVVideoAverageBitRateKey: 2_000_000,
          AVVideoExpectedSourceFrameRateKey: 15,
          AVVideoMaxKeyFrameIntervalKey: 30,
          AVVideoMaxKeyFrameIntervalDurationKey: 2,
          AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
        ],
      ]
      let activeVideoInput = AVAssetWriterInput(
        mediaType: .video,
        outputSettings: videoSettings
      )
      activeVideoInput.expectsMediaDataInRealTime = true
      guard assetWriter.canAdd(activeVideoInput) else { throw CaptureError.videoUnavailable }
      assetWriter.add(activeVideoInput)
      let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: activeVideoInput,
        sourcePixelBufferAttributes: [
          kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
          kCVPixelBufferWidthKey as String: width,
          kCVPixelBufferHeightKey as String: height,
          kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
      )

      let audioSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 44_100,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 128_000,
      ]
      let activeAudioInput = AVAssetWriterInput(
        mediaType: .audio,
        outputSettings: audioSettings
      )
      activeAudioInput.expectsMediaDataInRealTime = true
      guard assetWriter.canAdd(activeAudioInput) else { throw CaptureError.writerFailed }
      assetWriter.add(activeAudioInput)
      audioInput = activeAudioInput
      guard assetWriter.startWriting() else { throw CaptureError.writerFailed }

      outputURL = destination
      writer = assetWriter
      videoInput = activeVideoInput
      videoAdaptor = adaptor
      sessionStartedAt = Date()
      firstVideoTime = nil
      wroteVideo = false
      wroteAudio = false
      hasAudioSignal = false
      try paths.writeManifest(
        CaptureManifest(
          state: "recording",
          sessionID: captureRequest.sessionID,
          fileName: fileName,
          startedAt: Self.isoString(sessionStartedAt!),
          recordedAt: nil,
          durationSeconds: nil,
          errorCode: nil
        )
      )
      startMonitor(paths: paths)
    } catch {
      publishFailure("SCREEN_CAPTURE_EXTENSION_START_FAILED")
      closeBroadcast(code: "SCREEN_CAPTURE_EXTENSION_START_FAILED")
    }
  }

  private func appendVideo(_ sampleBuffer: CMSampleBuffer) {
    guard let writer, writer.status == .writing,
      let videoInput, videoInput.isReadyForMoreMediaData,
      let adaptor = videoAdaptor,
      let source = CMSampleBufferGetImageBuffer(sampleBuffer),
      let pool = adaptor.pixelBufferPool
    else { return }

    let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    if firstVideoTime == nil {
      firstVideoTime = presentationTime
      writer.startSession(atSourceTime: presentationTime)
    }
    var target: CVPixelBuffer?
    guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &target) == kCVReturnSuccess,
      let target
    else { return }
    render(source: source, into: target)
    if adaptor.append(target, withPresentationTime: presentationTime) {
      wroteVideo = true
    }
  }

  private func appendApplicationAudio(_ sampleBuffer: CMSampleBuffer) {
    guard firstVideoTime != nil,
      let writer, writer.status == .writing,
      let audioInput, audioInput.isReadyForMoreMediaData
    else { return }
    if audioInput.append(sampleBuffer) {
      wroteAudio = true
      if !hasAudioSignal { hasAudioSignal = Self.containsAudioSignal(sampleBuffer) }
    }
  }

  private static func containsAudioSignal(_ sample: CMSampleBuffer) -> Bool {
    guard let description = CMSampleBufferGetFormatDescription(sample),
      let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
      let block = CMSampleBufferGetDataBuffer(sample) else { return false }
    let count = min(CMBlockBufferGetDataLength(block), 16384)
    guard count > 0 else { return false }
    var bytes = [UInt8](repeating: 0, count: count)
    guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count, destination: &bytes) == kCMBlockBufferNoErr else { return false }
    if format.mBitsPerChannel == 32, format.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
      for offset in stride(from: 0, to: count - 3, by: 4) {
        let bits = UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 |
          UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
        let value = Float(bitPattern: bits)
        if value.isFinite && abs(value) > 0.00025 { return true }
      }
      return false
    }
    if format.mBitsPerChannel == 16 {
      for offset in stride(from: 0, to: count - 1, by: 2) {
        let value = Int16(bitPattern: UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8)
        if abs(Int(value)) > 8 { return true }
      }
      return false
    }
    return bytes.contains { $0 != 0 }
  }

  private func render(source: CVPixelBuffer, into target: CVPixelBuffer) {
    let sourceImage = CIImage(cvPixelBuffer: source)
    let destination = CGRect(
      x: 0,
      y: 0,
      width: CVPixelBufferGetWidth(target),
      height: CVPixelBufferGetHeight(target)
    )
    let sourceExtent = sourceImage.extent
    let scale = min(
      destination.width / max(1, sourceExtent.width),
      destination.height / max(1, sourceExtent.height)
    )
    let dx = (destination.width - sourceExtent.width * scale) / 2
    let dy = (destination.height - sourceExtent.height * scale) / 2
    let transform = CGAffineTransform(translationX: dx, y: dy)
      .scaledBy(x: scale, y: scale)
    let foreground = sourceImage.transformed(by: transform)
    let background = CIImage(color: .black).cropped(to: destination)
    context.render(
      foreground.composited(over: background),
      to: target,
      bounds: destination,
      colorSpace: CGColorSpaceCreateDeviceRGB()
    )
  }

  private func refreshVideoBudget() {
    let process = ProcessInfo.processInfo
    let now = process.systemUptime
    if let lastVideoBudgetSample, now - lastVideoBudgetSample < 1 { return }
    lastVideoBudgetSample = now
    let frameRate: Int
    switch process.thermalState {
    case .nominal:
      frameRate = process.isLowPowerModeEnabled ? 10 : 15
    case .fair:
      frameRate = 10
    case .serious:
      frameRate = 5
    case .critical:
      frameRate = 2
    @unknown default:
      frameRate = 5
    }
    videoFrameBudget.update(frameRate: frameRate, now: now)
  }

  private func startMonitor(paths: SharedPaths) {
    monitor?.cancel()
    let timer = DispatchSource.makeTimerSource(queue: stateQueue)
    timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
    timer.setEventHandler { [weak self] in
      guard let self, !self.finishing,
        let request = self.request,
        let started = self.sessionStartedAt
      else { return }
      self.refreshVideoBudget()
      if self.writer?.status == .failed {
        self.finalizeCapture(shouldCloseBroadcast: true)
        return
      }
      if paths.stopRequested(for: request.sessionID) {
        self.finalizeCapture(shouldCloseBroadcast: true)
        return
      }
      if Date().timeIntervalSince(started) >= Double(request.maxDurationSeconds) {
        self.finalizeCapture(shouldCloseBroadcast: true)
        return
      }
      let size = self.outputURL.flatMap {
        try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize
      } ?? 0
      let margin = min(2 * 1024 * 1024, request.maxSizeBytes / 10)
      if size >= max(1, request.maxSizeBytes - margin) {
        self.finalizeCapture(shouldCloseBroadcast: true)
      }
    }
    monitor = timer
    timer.resume()
  }

  private func finalizeCapture(shouldCloseBroadcast: Bool) {
    guard !finishing else { return }
    finishing = true
    monitor?.cancel()
    monitor = nil
    if let request, let paths = try? SharedPaths.resolve() {
      try? paths.writeManifest(CaptureManifest(
        state: "stopping", sessionID: request.sessionID, fileName: outputURL?.lastPathComponent,
        startedAt: sessionStartedAt.map(Self.isoString), recordedAt: nil,
        durationSeconds: nil, errorCode: nil
      ))
    }
    videoInput?.markAsFinished()
    audioInput?.markAsFinished()
    guard let writer, firstVideoTime != nil, writer.status == .writing else {
      writer?.cancelWriting()
      publishFailure("SCREEN_CAPTURE_EMPTY_FILE")
      if shouldCloseBroadcast { closeBroadcast(code: "SCREEN_CAPTURE_EMPTY_FILE") }
      return
    }
    writer.finishWriting { [weak self] in
      self?.stateQueue.async {
        self?.completeFinalization(shouldCloseBroadcast: shouldCloseBroadcast)
      }
    }
    stateQueue.asyncAfter(deadline: .now() + 30) { [weak self] in
      guard let self, let pendingWriter = self.writer,
        pendingWriter.status != .completed else { return }
      pendingWriter.cancelWriting()
      self.publishFailure("SCREEN_CAPTURE_FINALIZE_TIMEOUT")
      self.closeBroadcast(code: "SCREEN_CAPTURE_FINALIZE_TIMEOUT")
    }
  }

  private func completeFinalization(shouldCloseBroadcast: Bool) {
    defer {
      heartbeat?.cancel()
      heartbeat = nil
      writer = nil
      videoInput = nil
      videoAdaptor = nil
      audioInput = nil
      if shouldCloseBroadcast { closeBroadcast(code: "SCREEN_CAPTURE_FINISHED") }
    }
    guard let request, let outputURL, let started = sessionStartedAt,
      writer?.status == .completed, wroteVideo,
      let size = try? outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
      size > 0, size <= request.maxSizeBytes, size <= 500 * 1024 * 1024
    else {
      if let outputURL { try? FileManager.default.removeItem(at: outputURL) }
      publishFailure("SCREEN_CAPTURE_EMPTY_OR_INVALID_FILE")
      return
    }
    guard wroteAudio, hasAudioSignal else {
      try? FileManager.default.removeItem(at: outputURL)
      publishFailure(wroteAudio ? "SCREEN_CAPTURE_AUDIO_SILENT" : "SCREEN_CAPTURE_AUDIO_UNAVAILABLE")
      return
    }
    let duration = min(
      1800,
      max(1, Int(ceil(Date().timeIntervalSince(started))))
    )
    do {
      let paths = try SharedPaths.resolve()
      try paths.writeManifest(
        CaptureManifest(
          state: "completed",
          sessionID: request.sessionID,
          fileName: outputURL.lastPathComponent,
          startedAt: Self.isoString(started),
          recordedAt: Self.isoString(started),
          durationSeconds: duration,
          errorCode: nil
        )
      )
    } catch {
      try? FileManager.default.removeItem(at: outputURL)
      publishFailure("SCREEN_CAPTURE_STATE_WRITE_FAILED")
    }
  }

  private func publishFailure(_ code: String) {
    heartbeat?.cancel()
    heartbeat = nil
    guard let sessionID = request?.sessionID else { return }
    if let outputURL { try? FileManager.default.removeItem(at: outputURL) }
    guard let paths = try? SharedPaths.resolve() else { return }
    try? paths.writeManifest(
      CaptureManifest(
        state: "failed",
        sessionID: sessionID,
        fileName: nil,
        startedAt: sessionStartedAt.map(Self.isoString),
        recordedAt: nil,
        durationSeconds: nil,
        errorCode: code
      )
    )
  }

  private func closeBroadcast(code: String) {
    DispatchQueue.main.async { [weak self] in
      self?.finishBroadcastWithError(
        NSError(
          domain: "com.huahuoai.screen-capture",
          code: 1,
          userInfo: [NSLocalizedDescriptionKey: code]
        )
      )
    }
  }

  private func even(_ value: Int, fallback: Int) -> Int {
    guard value >= 320, value <= 1920 else { return fallback }
    return value - value % 2
  }

  private static func isoString(_ date: Date) -> String {
    isoFormatter.string(from: date)
  }

  private static let isoFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()
}

private final class ScreenCaptureVideoFrameBudget {
  private let lock = NSLock()
  private var frameRate = 15
  private var lastPresentationSeconds: Double?
  private var recoveryFrameRate: Int?
  private var recoveryStartedAt: TimeInterval?

  func update(frameRate requested: Int, now: TimeInterval) {
    lock.lock()
    defer { lock.unlock() }
    let target = max(2, min(15, requested))
    if target <= frameRate {
      frameRate = target
      recoveryFrameRate = nil
      recoveryStartedAt = nil
      return
    }
    if recoveryFrameRate != target {
      recoveryFrameRate = target
      recoveryStartedAt = now
    }
    if let recoveryStartedAt, now - recoveryStartedAt >= 30 {
      frameRate = target
      recoveryFrameRate = nil
      self.recoveryStartedAt = nil
    }
  }

  func admit(presentationSeconds: Double) -> Bool {
    guard presentationSeconds.isFinite else { return false }
    lock.lock()
    defer { lock.unlock() }
    if let lastPresentationSeconds,
      presentationSeconds - lastPresentationSeconds + 0.000001 < 1.0 / Double(frameRate)
    { return false }
    lastPresentationSeconds = presentationSeconds
    return true
  }
}

private struct CaptureRequest: Codable {
  let sessionID: String
  let maxDurationSeconds: Int
  let maxSizeBytes: Int
  let targetWidth: Int
  let targetHeight: Int
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
    ) else { throw CaptureError.appGroupUnavailable }
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

  func readRequest() throws -> CaptureRequest {
    let value = try JSONDecoder().decode(CaptureRequest.self, from: Data(contentsOf: requestURL))
    guard value.sessionID.range(of: "^[A-Za-z0-9_-]{1,100}$", options: .regularExpression) != nil,
      value.maxDurationSeconds > 0, value.maxDurationSeconds <= 1800,
      value.maxSizeBytes >= 1024 * 1024, value.maxSizeBytes <= 500 * 1024 * 1024,
      value.targetWidth >= 320, value.targetWidth <= 1920,
      value.targetHeight >= 320, value.targetHeight <= 1920
    else { throw CaptureError.invalidRequest }
    return value
  }

  func writeManifest(_ manifest: CaptureManifest) throws {
    try JSONEncoder().encode(manifest).write(to: manifestURL, options: .atomic)
  }

  func stopRequested(for sessionID: String) -> Bool {
    guard let data = try? Data(contentsOf: stopURL),
      let value = try? JSONDecoder().decode(StopRequest.self, from: data),
      value.sessionID == sessionID
    else { return false }
    try? FileManager.default.removeItem(at: stopURL)
    return true
  }
}

private enum CaptureError: Error {
  case appGroupUnavailable
  case invalidRequest
  case videoUnavailable
  case writerFailed
}
