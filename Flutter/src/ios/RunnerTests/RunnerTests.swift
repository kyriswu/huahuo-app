import AVFoundation
import CoreBluetooth
import Flutter
import UIKit
import XCTest
@testable import Runner

class RunnerTests: XCTestCase {

  private let requested = Array(0..<16).map(UInt8.init)
  private let legacy = Array(16..<32).map(UInt8.init)

  func testConnectionReuseRequiresRequestedFingerprintAndSerial() {
    XCTAssertTrue(recordingCardCanReuseConnection(
      requestedFingerprint: "card-a", activeFingerprint: "card-a",
      expectedSerial: "SP63A03003", actualSerial: "SP63A03003"
    ))
    XCTAssertFalse(recordingCardCanReuseConnection(
      requestedFingerprint: "card-b", activeFingerprint: "card-a",
      expectedSerial: "SP63A03003", actualSerial: "SP63A03003"
    ))
    XCTAssertFalse(recordingCardCanReuseConnection(
      requestedFingerprint: "card-a", activeFingerprint: "card-a",
      expectedSerial: "SP63A03004", actualSerial: "SP63A03003"
    ))
  }

  func testConnectionDeadlineCannotOutliveItsAttempt() {
    var attempt = RecordingCardConnectionAttempt()
    let first = attempt.begin()
    XCTAssertTrue(attempt.owns(first))
    attempt.finish()
    XCTAssertFalse(attempt.owns(first))
    let retry = attempt.begin()
    XCTAssertFalse(attempt.owns(first))
    XCTAssertTrue(attempt.owns(retry))
    attempt.finish()
    XCTAssertFalse(attempt.owns(retry))
  }

  func testRetiredTransportDrainsLateCallbackAfterObservedDisconnect() {
    XCTAssertEqual(
      recordingCardRestoredTransportResetAction(
        isDisconnected: true,
        bluetoothReady: true,
        awaitingDisconnectCallback: true
      ),
      .drainLateCallback
    )
    XCTAssertEqual(
      recordingCardRestoredTransportResetAction(
        isDisconnected: false,
        bluetoothReady: false,
        awaitingDisconnectCallback: true
      ),
      .awaitDisconnect
    )
  }

  func testRetiredTransportCallbacksStayBoundToTheirConnectionEpoch() {
    XCTAssertFalse(recordingCardDisconnectPredatesActiveConnection(
      disconnectTimestamp: nil,
      activeConnectStartedAt: 100
    ))
    XCTAssertTrue(recordingCardDisconnectPredatesActiveConnection(
      disconnectTimestamp: 99,
      activeConnectStartedAt: 100
    ))
    XCTAssertFalse(recordingCardDisconnectPredatesActiveConnection(
      disconnectTimestamp: 100,
      activeConnectStartedAt: 100
    ))

    XCTAssertTrue(recordingCardRestoredTransportDrainOwnsEntry(
      capturedTicket: 7,
      currentTicket: 7,
      matchesPeripheralObject: true
    ))
    XCTAssertFalse(recordingCardRestoredTransportDrainOwnsEntry(
      capturedTicket: 7,
      currentTicket: 8,
      matchesPeripheralObject: true
    ))
    XCTAssertFalse(recordingCardRestoredTransportDrainOwnsEntry(
      capturedTicket: 7,
      currentTicket: 7,
      matchesPeripheralObject: false
    ))
  }

  func testConnectionDeadlineDistinguishesDiscoveryAndSetup() {
    XCTAssertEqual(recordingCardConnectionDeadlineErrorCode(stage: "searching"), "RECORDING_CARD_NOT_FOUND")
    XCTAssertEqual(recordingCardConnectionDeadlineErrorCode(stage: "connecting"), "RECORDING_CARD_SETUP_TIMEOUT")
  }

  func testBindingAcknowledgementDistinguishesRejectionFromMalformedReply() {
    XCTAssertNil(recordingCardBindingAcknowledgementFailure([0x00]))
    XCTAssertEqual(recordingCardBindingAcknowledgementFailure([0x01]), .bindingRejected)
    for payload: [UInt8] in [[], [0x02], [0xff], [0x00, 0x00], [0x01, 0x00]] {
      XCTAssertEqual(recordingCardBindingAcknowledgementFailure(payload), .bindingAckMalformed)
    }
    XCTAssertEqual(
      RecordingCardHandshakeFailure.bindingInfoMalformed.code,
      "RECORDING_CARD_BINDING_INFO_MALFORMED"
    )
  }

  func testSensitiveControlPayloadStatusesStayRedacted() {
    for command: UInt8 in [0x01, 0x02, 0x03, 0x1F] {
      XCTAssertEqual(
        recordingCardControlStatusForDiagnostic(command: command, payload: [0xAB]),
        "masked"
      )
    }
    XCTAssertEqual(
      recordingCardControlStatusForDiagnostic(command: 0x05, payload: [0x01]),
      "0x01"
    )
    XCTAssertEqual(
      recordingCardControlStatusForDiagnostic(command: 0x05, payload: []),
      "none"
    )
  }

  func testHandshakeGuardAllowsOnlyOneSerialWindowAndClosesItAtDispatch() {
    var handshake = RecordingCardHandshakeGuard()
    XCTAssertFalse(handshake.dispatchedBinding(at: 99))
    XCTAssertTrue(handshake.begin())
    XCTAssertFalse(handshake.begin())
    XCTAssertNil(handshake.bindingDeadline)
    handshake.receivedSerial(at: 100)
    handshake.receivedSerial(at: 101)
    XCTAssertEqual(handshake.bindingDeadline, 105)
    XCTAssertFalse(handshake.bindingWindowExpired(at: 104.999))
    XCTAssertTrue(handshake.dispatchedBinding(at: 104.999))
    XCTAssertEqual(handshake.bindingDispatchMetDeadline, true)
    XCTAssertNil(handshake.bindingDeadline)
    handshake.receivedSerial(at: 106)
    XCTAssertNil(handshake.bindingDeadline)
    XCTAssertFalse(handshake.bindingWindowExpired(at: 200))
    XCTAssertFalse(handshake.dispatchedBinding(at: 200))
    XCTAssertFalse(handshake.begin())
  }

  func testHandshakeGuardClassifiesLateLiveTransportDispatchAndResetsForReconnect() {
    var handshake = RecordingCardHandshakeGuard()
    XCTAssertTrue(handshake.begin())
    handshake.receivedSerial(at: 100)
    XCTAssertTrue(handshake.bindingWindowExpired(at: 105))
    XCTAssertTrue(handshake.dispatchedBinding(at: 105))
    XCTAssertEqual(handshake.bindingDispatchMetDeadline, false)
    handshake.reset()
    XCTAssertFalse(handshake.inProgress)
    XCTAssertNil(handshake.bindingDeadline)
    XCTAssertNil(handshake.bindingDispatchMetDeadline)
    handshake.receivedSerial(at: 110)
    XCTAssertNil(handshake.bindingDeadline)
    XCTAssertTrue(handshake.begin())
    handshake.receivedSerial(at: 120)
    XCTAssertEqual(handshake.bindingDeadline, 125)
    XCTAssertTrue(handshake.dispatchedBinding(at: 121))
    XCTAssertEqual(handshake.bindingDispatchMetDeadline, true)
  }

  func testCommandOwnershipAndDispatchStateDoNotCrossRequestsOrTransports() {
    let first = RecordingCardCommandOwnership(requestID: 7, transportGeneration: 3)
    let replacement = RecordingCardCommandOwnership(requestID: 8, transportGeneration: 3)
    XCTAssertTrue(first.isCurrent(requestID: 7, transportGeneration: 3))
    XCTAssertFalse(first.isCurrent(requestID: 8, transportGeneration: 3))
    XCTAssertFalse(first.isCurrent(requestID: 7, transportGeneration: 4))
    XCTAssertNotEqual(first, replacement)

    var dispatch = RecordingCardCommandDispatchState()
    XCTAssertEqual(dispatch.count, 0)
    XCTAssertNil(dispatch.firstDispatchedAt)
    dispatch.record(at: 10)
    dispatch.record(at: 11)
    XCTAssertEqual(dispatch.count, 2)
    XCTAssertEqual(dispatch.firstDispatchedAt, 10)
  }

  func testBindingInfoRetryIsLimitedToOneNormalHandshakeRedispatch() {
    XCTAssertFalse(recordingCardCanRetryBindingInfo(
      handshakeInProgress: true,
      unbindInProgress: false,
      dispatchCount: 0
    ))
    XCTAssertTrue(recordingCardCanRetryBindingInfo(
      handshakeInProgress: true,
      unbindInProgress: false,
      dispatchCount: 1
    ))
    XCTAssertFalse(recordingCardCanRetryBindingInfo(
      handshakeInProgress: true,
      unbindInProgress: false,
      dispatchCount: 2
    ))
    XCTAssertFalse(recordingCardCanRetryBindingInfo(
      handshakeInProgress: true,
      unbindInProgress: true,
      dispatchCount: 1
    ))
    XCTAssertFalse(recordingCardCanRetryBindingInfo(
      handshakeInProgress: false,
      unbindInProgress: false,
      dispatchCount: 1
    ))
  }

  func testNormalHandshakeTimeoutStartsOnlyAfterPhysicalDispatch() {
    XCTAssertTrue(recordingCardCommandTimeoutStartsOnDispatch(
      handshakeInProgress: true,
      unbindInProgress: false
    ))
    XCTAssertFalse(recordingCardCommandTimeoutStartsOnDispatch(
      handshakeInProgress: false,
      unbindInProgress: false
    ))
    XCTAssertFalse(recordingCardCommandTimeoutStartsOnDispatch(
      handshakeInProgress: true,
      unbindInProgress: true
    ))
  }

  func testBindingInfoRetryKeepsEarliestDueTime() {
    let firstDispatchDue = recordingCardBindingInfoRetryDueUptime(
      existingDueUptime: nil,
      now: 4.9,
      delay: 1
    )
    XCTAssertEqual(firstDispatchDue, 5.9, accuracy: 0.0001)
    let faultAcceleratedDue = recordingCardBindingInfoRetryDueUptime(
      existingDueUptime: firstDispatchDue,
      now: 5,
      delay: 0.05
    )
    XCTAssertEqual(faultAcceleratedDue, 5.05, accuracy: 0.0001)
    XCTAssertEqual(
      recordingCardBindingInfoRetryDueUptime(
        existingDueUptime: faultAcceleratedDue,
        now: 5.03,
        delay: 0.05
      ),
      5.05,
      accuracy: 0.0001
    )
  }

  func testControlDecoderReassemblesBindingInfoAtEverySplitBoundary() {
    let payload = Array(0..<16).map(UInt8.init)
    let frame = RecordingCardFrameCodec.encode(command: 0x02, payload: payload)
    for split in 1..<frame.count {
      let decoder = RecordingCardFrameDecoder()
      let first = decoder.push(Data(frame.prefix(split)))
      XCTAssertTrue(first.packets.isEmpty, "split=\(split)")
      let second = decoder.push(Data(frame.dropFirst(split)))
      XCTAssertEqual(
        second.packets,
        [RecordingCardPacket(command: 0x02, payload: payload)],
        "split=\(split)"
      )
      XCTAssertNil(second.awaitingBytes, "split=\(split)")
    }
  }

  func testControlDecoderReassemblesBindingInfoByteByByte() {
    let payload = Array(16..<32).map(UInt8.init)
    let frame = RecordingCardFrameCodec.encode(command: 0x02, payload: payload)
    let decoder = RecordingCardFrameDecoder()
    var packets: [RecordingCardPacket] = []
    for byte in frame {
      packets.append(contentsOf: decoder.push(Data([byte])).packets)
    }
    XCTAssertEqual(packets, [RecordingCardPacket(command: 0x02, payload: payload)])
  }

  func testControlDecoderPreservesSplitHeaderAfterLeadingNoise() {
    let frame = RecordingCardFrameCodec.encode(command: 0x02, payload: [0x00])
    let decoder = RecordingCardFrameDecoder()
    let first = decoder.push(Data([0xAA, 0xD2]))
    XCTAssertTrue(first.packets.isEmpty)
    XCTAssertEqual(first.awaitingBytes, 1)
    let second = decoder.push(Data(frame.dropFirst()))
    XCTAssertEqual(second.packets, [RecordingCardPacket(command: 0x02, payload: [0x00])])
  }

  func testControlDecoderEmitsCoalescedFramesInOrder() {
    let first = RecordingCardFrameCodec.encode(command: 0x01, payload: [0x10])
    let second = RecordingCardFrameCodec.encode(command: 0x02, payload: [0x20, 0x21])
    var coalesced = first
    coalesced.append(second)
    let batch = RecordingCardFrameDecoder().push(coalesced)
    XCTAssertEqual(batch.packets, [
      RecordingCardPacket(command: 0x01, payload: [0x10]),
      RecordingCardPacket(command: 0x02, payload: [0x20, 0x21]),
    ])
  }

  func testControlDecoderResynchronizesAfterBadCrc() {
    var corrupt = [UInt8](RecordingCardFrameCodec.encode(command: 0x02, payload: [0x01]))
    corrupt[corrupt.count - 1] ^= 0xFF
    let payload = Array(0..<16).map(UInt8.init)
    let valid = RecordingCardFrameCodec.encode(command: 0x02, payload: payload)
    var bytes = Data(corrupt)
    bytes.append(valid)
    let batch = RecordingCardFrameDecoder().push(bytes)
    XCTAssertTrue(batch.issues.contains(.crcMismatch))
    XCTAssertEqual(batch.packets, [RecordingCardPacket(command: 0x02, payload: payload)])
  }

  func testControlDecoderRequiresRetryBoundaryAfterCorruptDeclaredLength() {
    var corrupt = [UInt8](RecordingCardFrameCodec.encode(command: 0x02, payload: [0x00]))
    corrupt[4] = 0xF0
    let payload = Array(32..<48).map(UInt8.init)
    let valid = RecordingCardFrameCodec.encode(command: 0x02, payload: payload)
    let decoder = RecordingCardFrameDecoder()
    let first = decoder.push(Data(corrupt))
    XCTAssertTrue(first.packets.isEmpty)
    XCTAssertNotNil(first.awaitingBytes)
    XCTAssertTrue(decoder.push(valid).packets.isEmpty)
    decoder.reset()
    XCTAssertEqual(
      decoder.push(valid).packets,
      [RecordingCardPacket(command: 0x02, payload: payload)]
    )
  }

  func testControlDecoderKeepsHeaderLikeBytesInsideValidPayload() {
    let nested = RecordingCardFrameCodec.encode(command: 0x05, payload: [0x01])
    let payload = [0xAA] + [UInt8](nested) + [UInt8](repeating: 0xBB, count: 32)
    let outer = RecordingCardFrameCodec.encode(command: 0x02, payload: payload)
    let decoder = RecordingCardFrameDecoder()
    let split = 5 + 1 + nested.count
    let first = decoder.push(Data(outer.prefix(split)))
    XCTAssertTrue(first.packets.isEmpty)
    XCTAssertNotNil(first.awaitingBytes)
    let second = decoder.push(Data(outer.dropFirst(split)))
    XCTAssertEqual(second.packets, [RecordingCardPacket(command: 0x02, payload: payload)])
  }

  func testControlDecoderAcceptsCapturedVersionOneBindingInfoAcrossAttSplit() {
    let captured: [UInt8] = [
      0xD2, 0x2D, 0x01, 0x02, 0x10, 0x48, 0x48, 0x46,
      0x57, 0x39, 0x32, 0x30, 0x54, 0x45, 0x53, 0x54,
      0x30, 0x30, 0x30, 0x31, 0x30, 0xBF, 0x9D,
    ]
    let decoder = RecordingCardFrameDecoder()
    let first = decoder.push(Data(captured.prefix(20)))
    XCTAssertTrue(first.packets.isEmpty)
    XCTAssertEqual(first.awaitingBytes, 3)
    let second = decoder.push(Data(captured.dropFirst(20)))
    XCTAssertTrue(second.issues.isEmpty)
    XCTAssertEqual(second.packets, [
      RecordingCardPacket(command: 0x02, payload: Array("HHFW920TEST00010".utf8))
    ])
  }

  func testControlDecoderRejectsInvalidVersionThenFindsValidFrame() {
    var invalid = [UInt8](RecordingCardFrameCodec.encode(command: 0x02, payload: [0x00]))
    invalid[2] = 0x7F
    let valid = RecordingCardFrameCodec.encode(command: 0x02, payload: [0x00])
    var bytes = Data(invalid)
    bytes.append(valid)
    let batch = RecordingCardFrameDecoder().push(bytes)
    XCTAssertTrue(batch.issues.contains(.unsupportedVersion))
    XCTAssertEqual(batch.packets, [RecordingCardPacket(command: 0x02, payload: [0x00])])
  }

  func testControlDecoderResetDiscardsPartialFrame() {
    let frame = RecordingCardFrameCodec.encode(command: 0x02, payload: [0x00])
    let decoder = RecordingCardFrameDecoder()
    XCTAssertNotNil(decoder.push(Data(frame.prefix(4))).awaitingBytes)
    decoder.reset()
    XCTAssertTrue(decoder.push(Data(frame.dropFirst(4))).packets.isEmpty)
    XCTAssertEqual(
      decoder.push(frame).packets,
      [RecordingCardPacket(command: 0x02, payload: [0x00])]
    )
  }

  func testIncomingMaterialFileURLsExcludeDeepLinks() {
    let sharedDocument = URL(fileURLWithPath: "/tmp/shared-note.md")
    let deepLink = URL(string: "huahuoai:///v3/feed")!
    let universalLink = URL(string: "https://example.com/shared-note")!

    XCTAssertEqual(
      incomingMaterialFileURLs(
        from: [deepLink, sharedDocument, universalLink]
      ),
      [sharedDocument]
    )
  }

  func testAudioImportDisplayNameUsesOriginalUnicodeNameInsteadOfCacheUUID() throws {
    let root = temporaryVoiceRecordingRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appendingPathComponent("手机录音 会议.m4a")
    let destination = root.appendingPathComponent("C467BEF8-16F6-4FEC-B68A-3BB14717682A.m4a")
    try Data([0x01]).write(to: source)
    try Data([0x01]).write(to: destination)

    XCTAssertEqual(
      preferredNativeAudioImportDisplayName(
        sourceURL: source,
        destinationURL: destination
      ),
      "手机录音 会议.m4a"
    )
  }

  func testAudioImportDurationFallsBackToAudioFrames() {
    XCTAssertEqual(
      nativeAudioImportDurationSeconds(
        assetDurationSeconds: 0,
        audioFrameCount: 40_851_456,
        sampleRate: 48_000
      ),
      852
    )
  }

  func testAudioImportDurationPrefersValidAssetDuration() {
    XCTAssertEqual(
      nativeAudioImportDurationSeconds(
        assetDurationSeconds: 12,
        audioFrameCount: 40_851_456,
        sampleRate: 48_000
      ),
      12
    )
  }

  func testBoundedNativeFileCopyPreservesExactBytesBelowLimit() throws {
    let root = temporaryVoiceRecordingRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appendingPathComponent("source.bin")
    let destination = root.appendingPathComponent("destination.bin")
    let bytes = Data([0x01, 0x02, 0x03, 0x04])
    try bytes.write(to: source)

    let copied = try copyNativeFileBounded(
      sourceURL: source,
      destinationURL: destination,
      maximumBytes: bytes.count
    )

    XCTAssertEqual(copied, bytes.count)
    XCTAssertEqual(try Data(contentsOf: destination), bytes)
  }

  func testBoundedNativeFileCopyDeletesDestinationWhenLimitIsExceeded() throws {
    let root = temporaryVoiceRecordingRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appendingPathComponent("oversize.bin")
    let destination = root.appendingPathComponent("destination.bin")
    try Data(repeating: 0x7f, count: 9).write(to: source)

    XCTAssertThrowsError(
      try copyNativeFileBounded(
        sourceURL: source,
        destinationURL: destination,
        maximumBytes: 8
      )
    )
    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
  }

  func testWorkVoiceRecorderPartFileNameKeepsM4AAsFinalExtension() {
    let fileName = voiceRecorderPartFileName(
      recordingID: "voice-test",
      scene: "work_ai"
    )
    let url = URL(fileURLWithPath: fileName)

    XCTAssertEqual(fileName, "voice-test.part.m4a")
    XCTAssertEqual(url.pathExtension, "m4a")
    XCTAssertEqual(url.deletingPathExtension().pathExtension, "part")
  }

  func testMonologueAndMeetingPartFileNamesUseWAV() {
    for scene in ["monologue", "meeting"] {
      let fileName = voiceRecorderPartFileName(
        recordingID: "voice-\(scene)",
        scene: scene
      )
      let url = URL(fileURLWithPath: fileName)

      XCTAssertEqual(fileName, "voice-\(scene).part.wav")
      XCTAssertEqual(url.pathExtension, "wav")
      XCTAssertEqual(url.deletingPathExtension().pathExtension, "part")
    }
  }

  func testVoiceprintPartFileNameKeepsWAVAsFinalExtension() {
    let fileName = voiceRecorderPartFileName(
      recordingID: "voiceprint-test",
      scene: "voiceprint"
    )
    let url = URL(fileURLWithPath: fileName)

    XCTAssertEqual(fileName, "voiceprint-test.part.wav")
    XCTAssertEqual(url.pathExtension, "wav")
    XCTAssertEqual(url.deletingPathExtension().pathExtension, "part")
  }

  func testVoiceRecorderValidatorAcceptsNonemptyAACM4A() throws {
    let root = temporaryVoiceRecordingRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent(
      voiceRecorderPartFileName(recordingID: "voice-valid", scene: "work_ai")
    )

    try writeSilentM4A(to: file)

    XCTAssertEqual(
      try validatedVoiceRecorderM4ADurationSeconds(at: file),
      1
    )
  }

  func testVoiceRecorderValidatorRejectsCAFDisguisedAsM4AAndGarbage() throws {
    let root = temporaryVoiceRecordingRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let caf = root.appendingPathComponent("voice-invalid.caf")
    let disguised = root.appendingPathComponent("voice-invalid.m4a")
    try writeSilentCAF(to: caf)
    try FileManager.default.moveItem(at: caf, to: disguised)

    XCTAssertThrowsError(
      try validatedVoiceRecorderM4ADurationSeconds(at: disguised)
    ) { error in
      XCTAssertEqual(
        error as? VoiceRecorderM4AValidationError,
        .invalidContainer
      )
    }

    let garbage = root.appendingPathComponent("voice-garbage.m4a")
    try Data([0x00, 0x01, 0x02, 0x03]).write(to: garbage)
    XCTAssertThrowsError(
      try validatedVoiceRecorderM4ADurationSeconds(at: garbage)
    ) { error in
      XCTAssertEqual(
        error as? VoiceRecorderM4AValidationError,
        .invalidContainer
      )
    }
  }

  func testVoiceprintWAVValidatorAccepts16kHzInt16Mono() throws {
    let root = temporaryVoiceRecordingRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("voiceprint-valid.wav")

    try writeSilentVoiceprintWAV(to: file, sampleRate: 16_000, seconds: 10)

    XCTAssertEqual(try validatedVoiceprintWAVDurationSeconds(at: file), 10)
    XCTAssertEqual(voiceprintWAVCaptureDurationSeconds, 10)
  }

  func testVoiceprintWAVValidatorRejectsWrongRateDurationAndSize() throws {
    let root = temporaryVoiceRecordingRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let wrongRate = root.appendingPathComponent("voiceprint-wrong-rate.wav")
    try writeSilentVoiceprintWAV(to: wrongRate, sampleRate: 8_000, seconds: 1)
    XCTAssertThrowsError(try validatedVoiceprintWAVDurationSeconds(at: wrongRate))

    let tooLong = root.appendingPathComponent("voiceprint-too-long.wav")
    let tooShort = root.appendingPathComponent("voiceprint-too-short.wav")
    try writeSilentVoiceprintWAV(to: tooShort, sampleRate: 16_000, seconds: 9)
    XCTAssertThrowsError(try validatedVoiceprintWAVDurationSeconds(at: tooShort))
    try writeSilentVoiceprintWAV(to: tooLong, sampleRate: 16_000, seconds: 11)
    XCTAssertThrowsError(try validatedVoiceprintWAVDurationSeconds(at: tooLong))

    let tooLarge = root.appendingPathComponent("voiceprint-too-large.wav")
    try Data(count: voiceprintWAVMaximumBytes + 1).write(to: tooLarge)
    XCTAssertThrowsError(try validatedVoiceprintWAVDurationSeconds(at: tooLarge))
  }

  func testSharedPcmWAVValidatorAcceptsBeyondVoiceprintDuration() throws {
    let root = temporaryVoiceRecordingRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("monologue-valid.wav")
    try writeSilentVoiceprintWAV(to: file, sampleRate: 16_000, seconds: 31)

    XCTAssertEqual(try validatedSharedPcmWAVDurationSeconds(at: file), 31)
  }

  func testPCM16FrameChunkerEmitsOnlyCompleteOrderedFrames() {
    var chunker = VoiceRecorderPCM16FrameChunker()
    let first = Data((0..<1_000).map { UInt8($0 & 0xff) })
    let second = Data((1_000..<3_000).map { UInt8($0 & 0xff) })

    XCTAssertTrue(chunker.append(first).isEmpty)
    let frames = chunker.append(second)

    XCTAssertEqual(frames.count, 2)
    XCTAssertTrue(frames.allSatisfy { $0.count == voiceRecorderPCM16FrameBytes })
    XCTAssertEqual(frames[0], Data((0..<1_280).map { UInt8($0 & 0xff) }))
    XCTAssertEqual(frames[1], Data((1_280..<2_560).map { UInt8($0 & 0xff) }))
    XCTAssertEqual(chunker.pendingByteCount, 440)
  }

  func testPCM16EarlyFrameQueueFailsExplicitlyWithoutEviction() {
    var queue = VoiceRecorderPCM16EarlyFrameQueue(capacityFrames: 2)
    let first = Data([0x01])
    let second = Data([0x02])

    XCTAssertTrue(queue.append(first))
    XCTAssertTrue(queue.append(second))
    XCTAssertEqual(queue.count, 2)
    XCTAssertFalse(queue.append(Data([0x03])))
    XCTAssertTrue(queue.overflowed)
    XCTAssertEqual(queue.count, 0)
    XCTAssertEqual(queue.droppedFrameCount, 3)
    XCTAssertFalse(queue.append(Data([0x04])))
    XCTAssertEqual(queue.droppedFrameCount, 4)

    queue.reset()
    XCTAssertFalse(queue.overflowed)
    XCTAssertEqual(queue.droppedFrameCount, 0)
    XCTAssertTrue(queue.append(first))
    XCTAssertEqual(queue.removeFirst(), first)
  }

  func testPCM16NativeHubPreservesEarlyFramesAndExactReads() {
    let hub = VoiceRecorderPCM16NativeHub.shared
    hub.endCapture(clearBufferedFrames: true)
    hub.beginCapture()
    defer {
      hub.stopConsumer()
      hub.endCapture(clearBufferedFrames: true)
    }
    let first = Data(repeating: 0x11, count: voiceRecorderPCM16FrameBytes)
    let second = Data(repeating: 0x22, count: voiceRecorderPCM16FrameBytes)
    hub.append(first)
    hub.append(second)

    XCTAssertTrue(hub.startConsumer())
    XCTAssertFalse(hub.startConsumer())
    let combined = first + second
    XCTAssertEqual(hub.read(exactLength: 1_920), combined.prefix(1_920))
    XCTAssertEqual(hub.read(exactLength: 640), combined.suffix(640))

    let blockedReadFinished = expectation(description: "consumer stop wakes blocked read")
    DispatchQueue.global(qos: .userInitiated).async {
      XCTAssertNil(hub.read(exactLength: 1))
      blockedReadFinished.fulfill()
    }
    Thread.sleep(forTimeInterval: 0.05)
    hub.stopConsumer()
    wait(for: [blockedReadFinished], timeout: 1)
  }

  func testPCM16NativeHubWaitsAcrossTemporarySilence() {
    let hub = VoiceRecorderPCM16NativeHub.shared
    hub.endCapture(clearBufferedFrames: true)
    hub.beginCapture()
    defer {
      hub.stopConsumer()
      hub.endCapture(clearBufferedFrames: true)
    }
    XCTAssertTrue(hub.startConsumer())
    let frame = Data(repeating: 0x36, count: voiceRecorderPCM16FrameBytes)
    let delayedReadFinished = expectation(description: "delayed producer wakes read")
    DispatchQueue.global(qos: .userInitiated).async {
      XCTAssertEqual(
        hub.read(exactLength: voiceRecorderPCM16FrameBytes),
        frame
      )
      delayedReadFinished.fulfill()
    }
    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.65) {
      hub.append(frame)
    }
    wait(for: [delayedReadFinished], timeout: 2)
  }

  func testPCM16NativeHubReturnsOwnedFramesWhileProducerAppends() {
    let hub = VoiceRecorderPCM16NativeHub.shared
    hub.endCapture(clearBufferedFrames: true)
    hub.beginCapture()
    defer {
      hub.stopConsumer()
      hub.endCapture(clearBufferedFrames: true)
    }

    let first = Data(repeating: 0x11, count: voiceRecorderPCM16FrameBytes)
    hub.append(first)
    XCTAssertTrue(hub.startConsumer())
    let retainedFrame = hub.read(exactLength: voiceRecorderPCM16FrameBytes)
    XCTAssertEqual(retainedFrame, first)

    let frameCount = 32
    let producerStarted = DispatchSemaphore(value: 0)
    let producerFinished = expectation(description: "PCM producer finished")
    DispatchQueue.global(qos: .userInitiated).async {
      for index in 0..<frameCount {
        let frame = Data(
          repeating: UInt8(index & 0xff),
          count: voiceRecorderPCM16FrameBytes
        )
        hub.append(frame)
        if index == 0 { producerStarted.signal() }
        Thread.sleep(forTimeInterval: 0.001)
      }
      producerFinished.fulfill()
    }

    XCTAssertEqual(producerStarted.wait(timeout: .now() + 1), .success)
    for index in 0..<frameCount {
      XCTAssertEqual(
        hub.read(exactLength: voiceRecorderPCM16FrameBytes),
        Data(repeating: UInt8(index & 0xff), count: voiceRecorderPCM16FrameBytes)
      )
    }
    wait(for: [producerFinished], timeout: 1)
    XCTAssertEqual(retainedFrame, first)
  }

  func testPCM16NativeHubFailsClosedAfterEarlyBufferOverflow() {
    let hub = VoiceRecorderPCM16NativeHub.shared
    hub.endCapture(clearBufferedFrames: true)
    hub.beginCapture()
    let frame = Data(repeating: 0x33, count: voiceRecorderPCM16FrameBytes)
    for _ in 0...1_125 {
      hub.append(frame)
    }

    XCTAssertFalse(hub.startConsumer())
    XCTAssertNil(hub.read(exactLength: voiceRecorderPCM16FrameBytes))

    hub.endCapture(clearBufferedFrames: true)
    hub.beginCapture()
    defer {
      hub.stopConsumer()
      hub.endCapture(clearBufferedFrames: true)
    }
    hub.append(frame)
    XCTAssertTrue(hub.startConsumer())
    XCTAssertEqual(hub.read(exactLength: frame.count), frame)
  }

  func testPCM16DrainPacerHandles375And1125FramesWithoutBursting() {
    for frameCount in [375, 1_125] {
      var queue = VoiceRecorderPCM16EarlyFrameQueue(capacityFrames: frameCount)
      var pacer = VoiceRecorderPCM16DrainPacer()
      for index in 0..<frameCount {
        XCTAssertTrue(queue.append(Data([UInt8(index & 0xff)])))
      }

      var tick = 0
      var delivered = 0
      var dartQueuedFrames = 0
      var maximumDartQueuedFrames = 0
      while !queue.isEmpty {
        let token = pacer.request(
          hasListener: true,
          hasFrames: !queue.isEmpty,
          overflowed: queue.overflowed
        )
        XCTAssertNotNil(token)
        XCTAssertNil(pacer.request(
          hasListener: true,
          hasFrames: true,
          overflowed: false
        ))
        XCTAssertTrue(pacer.beginDelivery(token: token!))
        XCTAssertNotNil(queue.removeFirst())
        delivered += 1
        dartQueuedFrames += 1
        maximumDartQueuedFrames = max(maximumDartQueuedFrames, dartQueuedFrames)

        let dartIsCatchingUp = dartQueuedFrames > 25
        let regularOutboundTick = tick % 2 == 1
        if dartIsCatchingUp || regularOutboundTick {
          dartQueuedFrames -= 1
        }
        if tick % 2 == 1 {
          XCTAssertTrue(queue.append(Data([0x7f])))
        }
        tick += 1
        XCTAssertLessThan(tick, frameCount * 3)
      }

      XCTAssertGreaterThan(delivered, frameCount)
      XCTAssertLessThan(maximumDartQueuedFrames, 160)
      XCTAssertEqual(VoiceRecorderPCM16DrainPacer.intervalMilliseconds, 20)
    }
  }

  func testPCM16DrainPacerCancellationInvalidatesPendingTick() {
    var pacer = VoiceRecorderPCM16DrainPacer()
    let token = pacer.request(
      hasListener: true,
      hasFrames: true,
      overflowed: false
    )
    XCTAssertNotNil(token)
    pacer.cancel()
    XCTAssertFalse(pacer.beginDelivery(token: token!))
    XCTAssertFalse(pacer.scheduled)
  }

  func testPreparedAudioExportReferenceResolvesSupportedNonemptyFiles() throws {
    let root = temporaryExportRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    for fileExtension in ["mp3", "m4a", "mp4", "wav", "opus"] {
      let fileName = "recording_01.\(fileExtension)"
      let file = try createPreparedAudioExport(
        root: root,
        exportId: "export-abc123",
        fileName: fileName,
        contents: Data([0x01, 0x02, 0x03])
      )
      XCTAssertEqual(
        try resolveNativePreparedAudioExportReference(
          "app-private-export://recordings/cache/export-abc123/\(fileName)",
          applicationSupportRoot: root
        ),
        file.standardizedFileURL
      )
    }
  }

  func testPreparedAudioExportReferenceResolvesAccountScopedFile() throws {
    let root = temporaryExportRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let scope = "u-0123456789abcdef0123456789abcdef"
    let file = try createPreparedAudioExport(
      root: root,
      exportId: "export-scoped123",
      fileName: "recording.m4a",
      contents: Data([0x01, 0x02]),
      accountScope: scope
    )

    XCTAssertEqual(
      try resolveNativePreparedAudioExportReference(
        "app-private-export://recordings/users/\(scope)/cache/export-scoped123/recording.m4a",
        applicationSupportRoot: root
      ),
      file.standardizedFileURL
    )
    assertPreparedAudioExportError(
      .unsafeReference,
      reference: "app-private-export://recordings/users/user@example.com/cache/export-scoped123/recording.m4a",
      root: root
    )
    assertPreparedAudioExportError(
      .unsafeReference,
      reference: "app-private-export://recordings/users/u-٠١٢٣٤٥٦٧٨٩abcdef0123456789abcdef/cache/export-scoped123/recording.m4a",
      root: root
    )
  }

  func testPreparedAudioExportReferenceRejectsForgedAndUnsupportedReferences() throws {
    let root = temporaryExportRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try createPreparedAudioExport(
      root: root,
      exportId: "export-abc123",
      fileName: "recording.m4a",
      contents: Data([0x01])
    )

    assertPreparedAudioExportError(
      .unsafeReference,
      reference: "file:///tmp/recording.m4a",
      root: root
    )
    assertPreparedAudioExportError(
      .unsafeReference,
      reference: "app-private-export://other/cache/export-abc123/recording.m4a",
      root: root
    )
    assertPreparedAudioExportError(
      .unsafeReference,
      reference: "app-private-export://recordings/cache/%2e%2e/recording.m4a",
      root: root
    )
    assertPreparedAudioExportError(
      .unsafeReference,
      reference: "app-private-export://recordings/cache/not-an-export/recording.m4a",
      root: root
    )
    assertPreparedAudioExportError(
      .unsupportedType,
      reference: "app-private-export://recordings/cache/export-abc123/recording.txt",
      root: root
    )
  }

  func testPreparedAudioExportReferenceRejectsMissingEmptyAndSymbolicLinkFiles() throws {
    let root = temporaryExportRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = preparedAudioExportDirectory(root: root, exportId: "export-abc123")
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )

    assertPreparedAudioExportError(
      .missing,
      reference: "app-private-export://recordings/cache/export-abc123/missing.m4a",
      root: root
    )

    let empty = directory.appendingPathComponent("empty.m4a")
    XCTAssertTrue(FileManager.default.createFile(atPath: empty.path, contents: Data()))
    assertPreparedAudioExportError(
      .empty,
      reference: "app-private-export://recordings/cache/export-abc123/empty.m4a",
      root: root
    )

    let outside = root.appendingPathComponent("outside.m4a")
    try Data([0x01]).write(to: outside)
    let link = directory.appendingPathComponent("linked.m4a")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
    assertPreparedAudioExportError(
      .symbolicLink,
      reference: "app-private-export://recordings/cache/export-abc123/linked.m4a",
      root: root
    )
  }

  func testPreparedKnowledgeExportReferenceResolvesMarkdownPdfAndZip() throws {
    let root = temporaryExportRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    for fileExtension in ["md", "pdf", "zip"] {
      let fileName = "knowledge_01.\(fileExtension)"
      let file = try createPreparedKnowledgeExport(
        root: root,
        exportId: "export-abc123",
        fileName: fileName,
        contents: Data([0x01, 0x02, 0x03])
      )
      XCTAssertEqual(
        try resolveNativePreparedKnowledgeExportReference(
          "app-private-export://knowledge/cache/export-abc123/\(fileName)",
          applicationSupportRoot: root
        ),
        file.standardizedFileURL
      )
    }
  }

  func testPreparedKnowledgeExportRejectsForgedAndUnavailableFiles() throws {
    let root = temporaryExportRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = preparedKnowledgeExportDirectory(
      root: root,
      exportId: "export-abc123"
    )
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )

    assertPreparedKnowledgeExportError(
      .unsafeReference,
      reference: "file:///tmp/knowledge.pdf",
      root: root
    )
    assertPreparedKnowledgeExportError(
      .unsafeReference,
      reference: "app-private-export://recordings/cache/export-abc123/knowledge.pdf",
      root: root
    )
    assertPreparedKnowledgeExportError(
      .unsafeReference,
      reference: "app-private-export://knowledge/cache/%2e%2e/knowledge.pdf",
      root: root
    )
    assertPreparedKnowledgeExportError(
      .unsupportedType,
      reference: "app-private-export://knowledge/cache/export-abc123/audio.m4a",
      root: root
    )
    assertPreparedKnowledgeExportError(
      .missing,
      reference: "app-private-export://knowledge/cache/export-abc123/missing.pdf",
      root: root
    )

    let empty = directory.appendingPathComponent("empty.md")
    XCTAssertTrue(FileManager.default.createFile(atPath: empty.path, contents: Data()))
    assertPreparedKnowledgeExportError(
      .empty,
      reference: "app-private-export://knowledge/cache/export-abc123/empty.md",
      root: root
    )

    let outside = root.appendingPathComponent("outside.pdf")
    try Data([0x01]).write(to: outside)
    let link = directory.appendingPathComponent("linked.pdf")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
    assertPreparedKnowledgeExportError(
      .symbolicLink,
      reference: "app-private-export://knowledge/cache/export-abc123/linked.pdf",
      root: root
    )
  }

  func testKnowledgeShareTextRejectsPrivateLocators() {
    XCTAssertTrue(isSafeNativeKnowledgeShareText("标题\n\n来源：链接笔记"))
    XCTAssertFalse(isSafeNativeKnowledgeShareText("file:///private/note.md"))
    XCTAssertFalse(isSafeNativeKnowledgeShareText("/Users/run/private.md"))
    XCTAssertFalse(isSafeNativeKnowledgeShareText("app-private://knowledge/1"))
    XCTAssertFalse(isSafeNativeKnowledgeShareText("C:\\private\\note.md"))
  }

  func testKnowledgePresentationCopyUsesDisplayNameAndCleansOnlyCopy() throws {
    let root = temporaryExportRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = try createPreparedKnowledgeExport(
      root: root,
      exportId: "export-abc123",
      fileName: "knowledge.pdf",
      contents: Data([0x25, 0x50, 0x44, 0x46])
    )

    let presentation = try prepareNativeKnowledgePresentationCopy(
      sourceURL: source,
      displayName: "中文标题.pdf"
    )

    XCTAssertEqual(presentation.lastPathComponent, "中文标题.pdf")
    XCTAssertEqual(try Data(contentsOf: presentation), try Data(contentsOf: source))
    XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    removeNativeKnowledgePresentationCopy(presentation)
    XCTAssertFalse(FileManager.default.fileExists(atPath: presentation.path))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: presentation.deletingLastPathComponent().path
      )
    )
    XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
  }

  private func temporaryExportRoot() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("native-audio-export-tests-\(UUID().uuidString)", isDirectory: true)
  }

  private func temporaryVoiceRecordingRoot() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("voice-recorder-tests-\(UUID().uuidString)", isDirectory: true)
  }

  private func writeSilentM4A(to url: URL) throws {
    try writeSilentAudio(
      to: url,
      settings: [
        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
        AVSampleRateKey: 44_100.0,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 96_000,
      ]
    )
  }

  private func writeSilentCAF(to url: URL) throws {
    let format = AVAudioFormat(
      standardFormatWithSampleRate: 44_100,
      channels: 1
    )!
    try writeSilentAudio(to: url, settings: format.settings)
  }

  private func writeSilentVoiceprintWAV(
    to url: URL,
    sampleRate: Double,
    seconds: Int
  ) throws {
    let format = AVAudioFormat(
      commonFormat: .pcmFormatInt16,
      sampleRate: sampleRate,
      channels: 1,
      interleaved: true
    )!
    let output = try AVAudioFile(
      forWriting: url,
      settings: format.settings,
      commonFormat: .pcmFormatInt16,
      interleaved: true
    )
    let frameCount = AVAudioFrameCount(Int(sampleRate) * seconds)
    let buffer = AVAudioPCMBuffer(
      pcmFormat: format,
      frameCapacity: frameCount
    )!
    buffer.frameLength = frameCount
    buffer.int16ChannelData?[0].initialize(repeating: 0, count: Int(frameCount))
    try output.write(from: buffer)
  }

  private func writeSilentAudio(
    to url: URL,
    settings: [String: Any]
  ) throws {
    let format = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: 44_100,
      channels: 1,
      interleaved: false
    )!
    let frameCount: AVAudioFrameCount = 4_096
    do {
      let output = try AVAudioFile(
        forWriting: url,
        settings: settings,
        commonFormat: .pcmFormatFloat32,
        interleaved: false
      )
      let buffer = AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: frameCount
      )!
      buffer.frameLength = frameCount
      buffer.floatChannelData?[0].initialize(
        repeating: 0,
        count: Int(frameCount)
      )
      try output.write(from: buffer)
    }
  }

  private func preparedAudioExportDirectory(root: URL, exportId: String) -> URL {
    root
      .appendingPathComponent("HuahuoAI", isDirectory: true)
      .appendingPathComponent("TemporaryTransfers", isDirectory: true)
      .appendingPathComponent("export", isDirectory: true)
      .appendingPathComponent("cache", isDirectory: true)
      .appendingPathComponent(exportId, isDirectory: true)
  }

  private func preparedAudioExportDirectory(
    root: URL,
    exportId: String,
    accountScope: String
  ) -> URL {
    root
      .appendingPathComponent("HuahuoAI", isDirectory: true)
      .appendingPathComponent("Users", isDirectory: true)
      .appendingPathComponent(accountScope, isDirectory: true)
      .appendingPathComponent("TemporaryTransfers", isDirectory: true)
      .appendingPathComponent("export", isDirectory: true)
      .appendingPathComponent("cache", isDirectory: true)
      .appendingPathComponent(exportId, isDirectory: true)
  }

  private func createPreparedAudioExport(
    root: URL,
    exportId: String,
    fileName: String,
    contents: Data,
    accountScope: String? = nil
  ) throws -> URL {
    let directory = accountScope.map {
      preparedAudioExportDirectory(
        root: root,
        exportId: exportId,
        accountScope: $0
      )
    } ?? preparedAudioExportDirectory(root: root, exportId: exportId)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    let file = directory.appendingPathComponent(fileName)
    try contents.write(to: file, options: .atomic)
    return file
  }

  private func preparedKnowledgeExportDirectory(root: URL, exportId: String) -> URL {
    root
      .appendingPathComponent("HuahuoAI", isDirectory: true)
      .appendingPathComponent("TemporaryTransfers", isDirectory: true)
      .appendingPathComponent("knowledge", isDirectory: true)
      .appendingPathComponent("cache", isDirectory: true)
      .appendingPathComponent(exportId, isDirectory: true)
  }

  private func createPreparedKnowledgeExport(
    root: URL,
    exportId: String,
    fileName: String,
    contents: Data
  ) throws -> URL {
    let directory = preparedKnowledgeExportDirectory(root: root, exportId: exportId)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    let file = directory.appendingPathComponent(fileName)
    try contents.write(to: file, options: .atomic)
    return file
  }

  private func assertPreparedAudioExportError(
    _ expected: NativePreparedAudioExportError,
    reference: String,
    root: URL,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertThrowsError(
      try resolveNativePreparedAudioExportReference(
        reference,
        applicationSupportRoot: root
      ),
      file: file,
      line: line
    ) { error in
      XCTAssertEqual(
        error as? NativePreparedAudioExportError,
        expected,
        file: file,
        line: line
      )
    }
  }

  private func assertPreparedKnowledgeExportError(
    _ expected: NativePreparedKnowledgeExportError,
    reference: String,
    root: URL,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertThrowsError(
      try resolveNativePreparedKnowledgeExportReference(
        reference,
        applicationSupportRoot: root
      ),
      file: file,
      line: line
    ) { error in
      XCTAssertEqual(
        error as? NativePreparedKnowledgeExportError,
        expected,
        file: file,
        line: line
      )
    }
  }

  func testBindingInfoAcceptsVariableLengthAllZeroPayload() {
    XCTAssertEqual(
      compatibleRecordingCardBindingToken(
        existingPayload: [0],
        requested: requested,
        legacy: legacy
      ),
      requested
    )
    XCTAssertEqual(
      compatibleRecordingCardBindingToken(
        existingPayload: Array(repeating: 0, count: 16),
        requested: requested,
        legacy: legacy
      ),
      requested
    )
  }

  func testBindingInfoKeepsExistingTokensAcrossInstallations() {
    XCTAssertEqual(
      compatibleRecordingCardBindingToken(
        existingPayload: requested,
        requested: requested,
        legacy: legacy
      ),
      requested
    )
    XCTAssertEqual(
      compatibleRecordingCardBindingToken(
        existingPayload: legacy,
        requested: requested,
        legacy: legacy
      ),
      legacy
    )
    let previousInstallation = Array(repeating: UInt8(0xFF), count: 16)
    XCTAssertEqual(
      compatibleRecordingCardBindingToken(
        existingPayload: previousInstallation,
        requested: requested,
        legacy: legacy
      ),
      previousInstallation
    )
  }

  func testBindingInfoRejectsEmptyAndShortPayloads() {
    XCTAssertNil(
      compatibleRecordingCardBindingToken(
        existingPayload: [],
        requested: requested,
        legacy: legacy
      )
    )
    XCTAssertNil(
      compatibleRecordingCardBindingToken(
        existingPayload: [1],
        requested: requested,
        legacy: legacy
      )
    )
  }

  func testUnbindResolvesCurrentAndLegacyDeviceTokens() {
    XCTAssertEqual(
      resolveRecordingCardUnbindToken(
        existingPayload: requested,
        requested: requested,
        legacy: legacy
      ),
      .token(requested)
    )
    XCTAssertEqual(
      resolveRecordingCardUnbindToken(
        existingPayload: legacy + [0xAA],
        requested: requested,
        legacy: legacy
      ),
      .token(legacy)
    )
  }

  func testUnbindClassifiesAlreadyUnboundMalformedAndConflictingBindings() {
    XCTAssertEqual(
      resolveRecordingCardUnbindToken(
        existingPayload: [0x00],
        requested: requested,
        legacy: legacy
      ),
      .alreadyUnbound
    )
    XCTAssertEqual(
      resolveRecordingCardUnbindToken(
        existingPayload: [],
        requested: requested,
        legacy: legacy
      ),
      .malformed
    )
    XCTAssertEqual(
      resolveRecordingCardUnbindToken(
        existingPayload: [0x01],
        requested: requested,
        legacy: legacy
      ),
      .malformed
    )
    XCTAssertEqual(
      resolveRecordingCardUnbindToken(
        existingPayload: Array(repeating: 0xFF, count: 16),
        requested: requested,
        legacy: legacy
      ),
      .conflict
    )
  }

  func testUnbindPayloadAndAcknowledgementAreStrict() {
    XCTAssertEqual(
      recordingCardUnbindPayload(deleteDeviceFiles: false),
      Array(repeating: 0x00, count: 17)
    )
    XCTAssertEqual(
      recordingCardUnbindPayload(deleteDeviceFiles: true),
      Array(repeating: 0x00, count: 16) + [0x01]
    )
    XCTAssertTrue(recordingCardUnbindAckAccepted([0x00]))
    XCTAssertTrue(recordingCardUnbindAckAccepted([0x00, 0x02]))
    XCTAssertFalse(recordingCardUnbindAckAccepted([]))
    XCTAssertFalse(recordingCardUnbindAckAccepted([0x01]))
  }

  func testUnbindDisconnectCompletesOnlyAfterCommandDispatch() {
    XCTAssertTrue(
      recordingCardUnbindDisconnectCompletesOperation(
        unbindInProgress: true,
        commandDispatched: true
      )
    )
    XCTAssertFalse(
      recordingCardUnbindDisconnectCompletesOperation(
        unbindInProgress: true,
        commandDispatched: false
      )
    )
    XCTAssertFalse(
      recordingCardUnbindDisconnectCompletesOperation(
        unbindInProgress: false,
        commandDispatched: true
      )
    )
  }

  func testForceScanAlwaysBypassesCachedPeripheral() {
    XCTAssertTrue(recordingCardShouldReuseCachedPeripheral(
      forceScan: false,
      hasCachedPeripheral: true
    ))
    XCTAssertFalse(recordingCardShouldReuseCachedPeripheral(
      forceScan: true,
      hasCachedPeripheral: true
    ))
    XCTAssertFalse(recordingCardShouldReuseCachedPeripheral(
      forceScan: false,
      hasCachedPeripheral: false
    ))
  }

  func testWifiHandoffVerificationRequiresJoinedSSIDAndWifiPath() {
    XCTAssertEqual(recordingCardWifiHandoffVerificationStatus(
      handoffExpected: true,
      expectedSSID: "synthetic-card-network",
      joinedSSID: "synthetic-card-network",
      wifiPathSatisfied: true
    ), "ready")
    XCTAssertEqual(recordingCardWifiHandoffVerificationStatus(
      handoffExpected: true,
      expectedSSID: "synthetic-card-network",
      joinedSSID: "other-network",
      wifiPathSatisfied: true
    ), "networkUnavailable")
    XCTAssertEqual(recordingCardWifiHandoffVerificationStatus(
      handoffExpected: true,
      expectedSSID: "synthetic-card-network",
      joinedSSID: "synthetic-card-network",
      wifiPathSatisfied: false
    ), "networkUnavailable")
  }

  func testRecordingCardConnectionPreflightRejectsUnavailableBluetooth() {
    XCTAssertEqual(
      recordingCardBluetoothConnectionPreflight(.poweredOn),
      .proceed
    )
    XCTAssertEqual(
      recordingCardBluetoothConnectionPreflight(.unknown),
      .waitForState
    )
    XCTAssertEqual(
      recordingCardBluetoothConnectionPreflight(.resetting),
      .waitForState
    )
    XCTAssertEqual(
      recordingCardBluetoothConnectionPreflight(.poweredOff),
      .reject
    )
    XCTAssertEqual(
      recordingCardBluetoothConnectionPreflight(.unauthorized),
      .reject
    )
    XCTAssertEqual(
      recordingCardBluetoothConnectionPreflight(.unsupported),
      .reject
    )
  }

  func testRecordingCardTransientHandshakeIdentityCapturesAndClearsValidatedSerial() {
    let identity = RecordingCardTransientHandshakeIdentity()

    XCTAssertTrue(identity.capture(serialPayload: Array("SNABC1234".utf8) + [0x00, 0x20]))
    XCTAssertEqual(identity.serialNumber, "SNABC1234")

    XCTAssertFalse(identity.capture(serialPayload: [0x00, 0x01, 0x02]))
    XCTAssertNil(identity.serialNumber)

    XCTAssertTrue(identity.capture(serialPayload: Array("SNXYZ9876".utf8)))
    identity.clear()
    XCTAssertNil(identity.serialNumber)
  }

  func testRecordingCardExpectedSerialUsesAccountNormalization() {
    XCTAssertTrue(
      recordingCardSerialMatchesExpected("sp63-a03003", actual: "SP63A03003")
    )
    XCTAssertTrue(recordingCardSerialMatchesExpected(nil, actual: "SP63A03003"))
    XCTAssertFalse(
      recordingCardSerialMatchesExpected("SP63A03003", actual: "SP63A03004")
    )
    XCTAssertFalse(recordingCardSerialMatchesExpected("bad_sn", actual: "bad_sn"))
  }

  func testCachedPeripheralDisplayNamePrefersLatestEligibleAdvertisement() {
    XCTAssertEqual(
      recordingCardCachedPeripheralDisplayName(
        scannedDisplayName: "会议室录音卡",
        peripheralName: "FW920"
      ),
      "会议室录音卡"
    )
    XCTAssertEqual(
      recordingCardCachedPeripheralDisplayName(
        scannedDisplayName: nil,
        peripheralName: "FW920"
      ),
      "FW920"
    )
    XCTAssertEqual(
      recordingCardCachedPeripheralDisplayName(
        scannedDisplayName: "   ",
        peripheralName: "FW920"
      ),
      "FW920"
    )
    XCTAssertEqual(
      recordingCardCachedPeripheralDisplayName(
        scannedDisplayName: nil,
        peripheralName: nil
      ),
      ""
    )
  }

  func testRecordingCardManufacturerAdvertisementRequiresObservedCompanyPrefixAndMinimumStructure() {
    let observedLength18 = Data([
      0x5C, 0x37,
      0x10, 0x11, 0x12, 0x13, 0x14, 0x15,
      0x53, 0x4E, 0x2D, 0x30, 0x30, 0x30, 0x31, 0x32, 0x33, 0x34,
    ])
    let reversedLength18 = Data([
      0x37, 0x5C,
      0x10, 0x11, 0x12, 0x13, 0x14, 0x15,
      0x53, 0x4E, 0x2D, 0x30, 0x30, 0x30, 0x31, 0x32, 0x33, 0x34,
    ])

    XCTAssertEqual(observedLength18.count, 18)
    XCTAssertEqual(reversedLength18.count, 18)
    XCTAssertTrue(
      recordingCardManufacturerAdvertisementIsEligible(observedLength18)
    )
    XCTAssertFalse(
      recordingCardManufacturerAdvertisementIsEligible(reversedLength18)
    )
    XCTAssertFalse(
      recordingCardManufacturerAdvertisementIsEligible(
        Data([0x5C, 0x37, 0x10, 0x11, 0x12, 0x13, 0x14, 0x53])
      )
    )
    XCTAssertTrue(
      recordingCardManufacturerAdvertisementIsEligible(
        Data([0x5C, 0x37, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x00])
      )
    )
    XCTAssertTrue(
      recordingCardManufacturerAdvertisementIsEligible(
        Data([0x5C, 0x37, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x53])
      )
    )
    XCTAssertFalse(recordingCardManufacturerAdvertisementIsEligible(nil))
  }

  func testRecordingCardManufacturerEligibilityAndDiagnosticStayRedacted() {
    let eligible = Data([
      0x5C, 0x37,
      0xD1, 0xE2, 0xF3, 0xA4, 0xB5, 0xC6,
      0x52, 0x4B, 0x99, 0xA8, 0xB7, 0xC5, 0xD4, 0xE3, 0xF2, 0xA1,
    ])

    XCTAssertEqual(recordingCardManufacturerAdvertisementEligibility(nil), .missing)
    XCTAssertEqual(
      recordingCardManufacturerAdvertisementEligibility(Data([0x5C, 0x37])),
      .tooShort
    )
    XCTAssertEqual(
      recordingCardManufacturerAdvertisementEligibility(
        Data([0x37, 0x5C, 0xD1, 0xE2, 0xF3, 0xA4, 0xB5, 0xC6, 0x52])
      ),
      .companyPrefixMismatch
    )
    XCTAssertEqual(
      recordingCardManufacturerAdvertisementEligibility(
        Data([0x5C, 0x37, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x52])
      ),
      .eligible
    )
    XCTAssertEqual(
      recordingCardManufacturerAdvertisementEligibility(
        Data([0x5C, 0x37] + Array(repeating: 0x00, count: 16))
      ),
      .eligible
    )
    XCTAssertEqual(recordingCardManufacturerAdvertisementEligibility(eligible), .eligible)

    let observed = Data([
      0x5C, 0x37, 0x50, 0xC0, 0xF0, 0x4C, 0x4E, 0x30,
      0x53, 0x50, 0x36, 0x33, 0x41, 0x30, 0x33, 0x30, 0x30, 0x33,
    ])
    XCTAssertEqual(
      recordingCardManufacturerAdvertisementSerialNumber(observed),
      "SP63A03003"
    )
    XCTAssertEqual(
      recordingCardManufacturerAdvertisementSerialNumber(
        Data([0x5C, 0x37] + Array(repeating: 0x00, count: 6) +
          Array("SN1234".utf8) + Array(repeating: 0x00, count: 4))
      ),
      "SN1234"
    )
    XCTAssertEqual(
      recordingCardManufacturerAdvertisementSerialNumber(
        Data([0x5C, 0x37] + Array(repeating: 0x00, count: 6) +
          Array("SP63A030043".utf8))
      ),
      "SP63A030043"
    )
    XCTAssertEqual(
      recordingCardManufacturerAdvertisementSerialNumber(
        Data([0x5C, 0x37] + Array(repeating: 0x00, count: 6) +
          Array(String(repeating: "A", count: 64).utf8))
      ),
      String(repeating: "A", count: 64)
    )
    XCTAssertNil(
      recordingCardManufacturerAdvertisementSerialNumber(
        Data([0x5C, 0x37] + Array(repeating: 0x00, count: 6) + [0x53])
      )
    )
    XCTAssertNil(
      recordingCardManufacturerAdvertisementSerialNumber(
        Data([0x5C, 0x37] + Array(repeating: 0x00, count: 6) +
          Array("SN123".utf8))
      )
    )
    XCTAssertNil(
      recordingCardManufacturerAdvertisementSerialNumber(
        Data([0x5C, 0x37] + Array(repeating: 0x00, count: 6) +
          Array(String(repeating: "A", count: 65).utf8))
      )
    )
    XCTAssertNil(
      recordingCardManufacturerAdvertisementSerialNumber(
        Data([0x5C, 0x37] + Array(repeating: 0x00, count: 16))
      )
    )
    XCTAssertNil(
      recordingCardManufacturerAdvertisementSerialNumber(
        Data([0x5C, 0x37] + Array(repeating: 0x00, count: 6) +
          [0x53, 0x4E, 0x0A] + Array(repeating: 0x00, count: 7))
      )
    )
    XCTAssertNil(
      recordingCardManufacturerAdvertisementSerialNumber(
        Data([0x5C, 0x37] + Array(repeating: 0x00, count: 6) +
          Array("SN_123".utf8))
      )
    )

    let diagnostic = recordingCardManufacturerAdvertisementDiagnostic(eligible)
    XCTAssertEqual(
      diagnostic,
      "manufacturer eligibility=eligible identity=provisional dataLength=18 companyPrefix=5C 37"
    )
    for hiddenByte in ["D1", "E2", "F3", "A4", "B5", "C6", "52", "4B", "99", "A8", "B7", "C5", "D4", "E3", "F2", "A1"] {
      XCTAssertFalse(diagnostic.contains(hiddenByte))
    }
  }

  func testRecordingCardDiscoveryMergesIdentityWithoutLosingValidSignal() {
    let initial = recordingCardMergedDiscoveredDeviceMap(
      current: nil,
      advertisedName: nil,
      peripheralName: "FW920",
      defaultName: "花火录音卡",
      fingerprint: "ios-card-test",
      rssi: -70,
      isConnectable: false,
      serialNumber: nil,
      lastSeenAt: "first"
    )
    XCTAssertTrue(
      recordingCardDiscoveryRowHasMeaningfulChange(current: nil, next: initial)
    )
    XCTAssertEqual(initial["displayName"] as? String, "FW920")
    XCTAssertNil(initial["serialNumber"])
    XCTAssertEqual(initial["isConnectable"] as? Bool, false)

    let enriched = recordingCardMergedDiscoveredDeviceMap(
      current: initial,
      advertisedName: "会议录音卡",
      peripheralName: "FW920",
      defaultName: "花火录音卡",
      fingerprint: "ios-card-test",
      rssi: -58,
      isConnectable: true,
      serialNumber: "SP63A03003",
      lastSeenAt: "second"
    )
    XCTAssertTrue(
      recordingCardDiscoveryRowHasMeaningfulChange(current: initial, next: enriched)
    )
    XCTAssertEqual(enriched["displayName"] as? String, "会议录音卡")
    XCTAssertEqual(enriched["serialNumber"] as? String, "SP63A03003")
    XCTAssertEqual(enriched["isConnectable"] as? Bool, true)

    let sparse = recordingCardMergedDiscoveredDeviceMap(
      current: enriched,
      advertisedName: nil,
      peripheralName: "stale-system-name",
      defaultName: "花火录音卡",
      fingerprint: "ios-card-test",
      rssi: 127,
      isConnectable: false,
      serialNumber: nil,
      lastSeenAt: "third"
    )
    XCTAssertTrue(
      recordingCardDiscoveryRowHasMeaningfulChange(current: enriched, next: sparse)
    )
    XCTAssertEqual(sparse["displayName"] as? String, "会议录音卡")
    XCTAssertEqual(sparse["serialNumber"] as? String, "SP63A03003")
    XCTAssertEqual(sparse["isConnectable"] as? Bool, false)
    XCTAssertEqual(sparse["rssi"] as? Int, -58)
    XCTAssertEqual(sparse["lastSeenAt"] as? String, "third")

    let recovered = recordingCardMergedDiscoveredDeviceMap(
      current: sparse,
      advertisedName: nil,
      peripheralName: nil,
      defaultName: "花火录音卡",
      fingerprint: "ios-card-test",
      rssi: 127,
      isConnectable: true,
      serialNumber: nil,
      lastSeenAt: "fourth"
    )
    XCTAssertTrue(
      recordingCardDiscoveryRowHasMeaningfulChange(current: sparse, next: recovered)
    )
    XCTAssertEqual(recovered["isConnectable"] as? Bool, true)

    let signalOnly = recordingCardMergedDiscoveredDeviceMap(
      current: recovered,
      advertisedName: nil,
      peripheralName: nil,
      defaultName: "花火录音卡",
      fingerprint: "ios-card-test",
      rssi: -49,
      isConnectable: nil,
      serialNumber: nil,
      lastSeenAt: "fifth"
    )
    XCTAssertFalse(
      recordingCardDiscoveryRowHasMeaningfulChange(current: recovered, next: signalOnly)
    )
    XCTAssertEqual(signalOnly["rssi"] as? Int, -49)
    XCTAssertEqual(signalOnly["lastSeenAt"] as? String, "fifth")
  }

  func testRecordingCardCommittedDownloadRequiresMatchingDirectorySize() {
    XCTAssertFalse(
      recordingCardCommittedDownloadMatchesDirectorySize(
        actualSize: 4_096,
        directorySizeBytes: nil
      )
    )
    XCTAssertTrue(
      recordingCardCommittedDownloadMatchesDirectorySize(
        actualSize: 4_096,
        directorySizeBytes: 4_096
      )
    )
    XCTAssertFalse(
      recordingCardCommittedDownloadMatchesDirectorySize(
        actualSize: 0,
        directorySizeBytes: 0
      )
    )
    XCTAssertFalse(
      recordingCardCommittedDownloadMatchesDirectorySize(
        actualSize: 4_095,
        directorySizeBytes: 4_096
      )
    )
    XCTAssertEqual(
      recordingCardCommittedDownloadRecoveryAction(
        actualSize: 4_096,
        directorySizeBytes: 4_096
      ),
      .reuse
    )
    XCTAssertEqual(
      recordingCardCommittedDownloadRecoveryAction(
        actualSize: 4_095,
        directorySizeBytes: 4_096
      ),
      .reset
    )
    XCTAssertEqual(
      recordingCardCommittedDownloadRecoveryAction(
        actualSize: 4_096,
        directorySizeBytes: nil
      ),
      .reset
    )
  }

  func testRecordingCardAtomicCommitReplacesFinalAfterVerification() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "recording-card-atomic-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let part = root.appendingPathComponent("target.m4a.part")
    let final = root.appendingPathComponent("target.m4a")
    let payload = Data("verified payload".utf8)
    try payload.write(to: part)
    try Data("old final".utf8).write(to: final)
    let hash = try recordingCardSHA256File(at: part)
    let output = try FileHandle(forWritingTo: part)
    defer { try? output.close() }

    let committed = try recordingCardCommitDownloadedPart(
      output: output,
      partURL: part,
      finalURL: final,
      expectedSize: payload.count,
      streamedContentHash: hash
    )

    XCTAssertEqual(committed.sizeBytes, payload.count)
    XCTAssertEqual(committed.contentHash, hash)
    XCTAssertEqual(try Data(contentsOf: final), payload)
    XCTAssertFalse(FileManager.default.fileExists(atPath: part.path))
  }

  func testRecordingCardAtomicCommitPreservesFinalOnInvalidMetadata() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "recording-card-invalid-commit-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let final = root.appendingPathComponent("target.m4a")
    let oldFinal = Data("old final".utf8)
    try oldFinal.write(to: final)

    for invalidHash in [false, true] {
      let part = root.appendingPathComponent("target-\(invalidHash).m4a.part")
      let payload = Data("uncommitted payload".utf8)
      try payload.write(to: part)
      let output = try FileHandle(forWritingTo: part)
      defer { try? output.close() }
      let hash = invalidHash
        ? String(repeating: "0", count: 64)
        : try recordingCardSHA256File(at: part)
      XCTAssertThrowsError(try recordingCardCommitDownloadedPart(
        output: output,
        partURL: part,
        finalURL: final,
        expectedSize: invalidHash ? payload.count : payload.count + 1,
        streamedContentHash: hash
      ))
      XCTAssertEqual(try Data(contentsOf: final), oldFinal)
      XCTAssertTrue(FileManager.default.fileExists(atPath: part.path))
    }
  }

  func testRecordingCardScanOwnerRejectsCallbacksAfterStop() {
    XCTAssertFalse(recordingCardScanOwnerAcceptsDiscovery(.none))
    XCTAssertTrue(recordingCardScanOwnerAcceptsDiscovery(.manual))
    XCTAssertTrue(recordingCardScanOwnerAcceptsDiscovery(.connection))
  }

  func testRecordingCardRestoredTransportResetActionWaitsForRealDisconnect() {
    XCTAssertEqual(
      recordingCardRestoredTransportResetAction(
        isDisconnected: true,
        bluetoothReady: false
      ),
      .clear
    )
    XCTAssertEqual(
      recordingCardRestoredTransportResetAction(
        isDisconnected: false,
        bluetoothReady: false
      ),
      .waitForBluetooth
    )
    XCTAssertEqual(
      recordingCardRestoredTransportResetAction(
        isDisconnected: false,
        bluetoothReady: true
      ),
      .cancelAndAwaitDisconnect
    )
  }

  func testRecordingCardFailedTransportCancelsOnlyLivePeripheralStates() {
    XCTAssertFalse(
      recordingCardFailedPeripheralNeedsCancellation(.disconnected)
    )
    XCTAssertTrue(
      recordingCardFailedPeripheralNeedsCancellation(.connecting)
    )
    XCTAssertTrue(
      recordingCardFailedPeripheralNeedsCancellation(.connected)
    )
    XCTAssertFalse(
      recordingCardFailedPeripheralNeedsCancellation(.disconnecting)
    )
  }

  func testRecordingCardRestoredTransportResumeGuardsCancellationTimerAndActiveState() {
    // Explicit disconnect clears both pending results, so a later stale
    // `didDisconnect` has no work to resume.
    XCTAssertEqual(
      recordingCardRestoredTransportResumeAction(
        hasPendingConnect: false,
        hasPendingManualScan: false
      ),
      .none
    )
    XCTAssertEqual(
      recordingCardRestoredTransportResumeAction(
        hasPendingConnect: true,
        hasPendingManualScan: false
      ),
      .startConnectScan
    )
    XCTAssertEqual(
      recordingCardRestoredTransportResumeAction(
        hasPendingConnect: false,
        hasPendingManualScan: true
      ),
      .startManualScan
    )
    XCTAssertEqual(
      recordingCardRestoredTransportResumeAction(
        hasPendingConnect: true,
        hasPendingManualScan: false,
        hasSelectedPeripheral: true
      ),
      .none
    )
    XCTAssertEqual(
      recordingCardRestoredTransportResumeAction(
        hasPendingConnect: true,
        hasPendingManualScan: false,
        hasActiveScan: true
      ),
      .none
    )

    XCTAssertFalse(
      recordingCardShouldPublishDisconnectedForRestoredState(
        hasVerifiedActiveBleTransport: true
      )
    )
    XCTAssertTrue(
      recordingCardShouldPublishDisconnectedForRestoredState(
        hasVerifiedActiveBleTransport: false
      )
    )
  }

  func testRecordingCardBluetoothNamePayloadUsesUtf8AndExactZeroPaddedLength() {
    let bluetoothName = "花火Card"
    let nameBytes = Array(bluetoothName.utf8)

    guard let payload = recordingCardBluetoothNamePayload(bluetoothName) else {
      return XCTFail("Expected a valid Bluetooth-name payload.")
    }

    XCTAssertEqual(payload.count, 32)
    XCTAssertEqual(Array(payload.prefix(nameBytes.count)), nameBytes)
    XCTAssertTrue(payload.dropFirst(nameBytes.count).allSatisfy { $0 == 0x00 })
    XCTAssertEqual(recordingCardBluetoothNamePayload(String(repeating: "a", count: 32))?.count, 32)
  }

  func testRecordingCardBluetoothNamePayloadRejectsEmptyControlAndOversizedNames() {
    XCTAssertNil(recordingCardBluetoothNamePayload(""))
    XCTAssertNil(recordingCardBluetoothNamePayload(" \n\t "))
    XCTAssertNil(recordingCardBluetoothNamePayload("card\u{0000}name"))
    XCTAssertNil(recordingCardBluetoothNamePayload("card\u{0085}name"))
    XCTAssertNil(recordingCardBluetoothNamePayload(String(repeating: "a", count: 33)))
    XCTAssertNil(recordingCardBluetoothNamePayload(String(repeating: "花", count: 11)))
  }

  func testRecordingCardBluetoothNameAcknowledgementIsStrict() {
    XCTAssertEqual(recordingCardBluetoothNameAck([0x00]), .accepted)
    XCTAssertEqual(recordingCardBluetoothNameAck([0x01]), .rejected)
    XCTAssertEqual(recordingCardBluetoothNameAck([]), .invalid)
    XCTAssertEqual(recordingCardBluetoothNameAck([0x00, 0x00]), .invalid)
    XCTAssertEqual(recordingCardBluetoothNameAck([0x02]), .invalid)
  }

  func testFileRequestAckRejectsAByteSwappedDirectoryConflict() {
    XCTAssertNil(
      recordingCardAcknowledgedFileSize(
        payload: [0x00, 0x00, 0x60, 0x02, 0x00],
        directorySizeBytes: 155_648
      )
    )
    XCTAssertEqual(
      recordingCardAcknowledgedFileSize(
        payload: [0x00, 0x00, 0x60, 0x02, 0x00],
        directorySizeBytes: nil
      ),
      6_291_968
    )
  }

  func testFileRequestAckAcceptsObservedBigEndianSize() {
    XCTAssertEqual(
      recordingCardAcknowledgedFileSize(
        payload: [0x00, 0x00, 0x00, 0x26, 0x5C],
        directorySizeBytes: 9_820
      ),
      9_820
    )
  }

  func testDirectoryAndAckSizesPreferProtocolBigEndian() {
    XCTAssertEqual(
      recordingCardDirectoryFileSize(
        littleEndian: 155_648,
        bigEndian: 6_291_968
      ),
      RecordingCardDirectoryFileSize(
        sizeBytes: 6_291_968,
        confidence: "trusted"
      )
    )
    XCTAssertEqual(
      recordingCardDirectoryFileSize(
        littleEndian: 482_152_960,
        bigEndian: 1_228_060
      ),
      RecordingCardDirectoryFileSize(
        sizeBytes: 1_228_060,
        confidence: "trusted"
      )
    )
    XCTAssertEqual(
      recordingCardAcknowledgedFileSize(
        payload: [0x00, 0x00, 0x12, 0xBD, 0x1C],
        directorySizeBytes: nil
      ),
      1_228_060
    )
    XCTAssertNil(
      recordingCardDirectoryFileSize(
        littleEndian: 9_820,
        bigEndian: 0
      )
    )
  }

  func testFileSizeByteOrderIsStableAcrossNumericBoundaries() {
    let expectedSizes = [
      1,
      4_040,
      12_120,
      65_535,
      65_536,
      155_648,
      1_228_060,
      6_291_968,
      1_024 * 1_024 * 1_024,
    ]

    for expected in expectedSizes {
      XCTAssertEqual(
        recordingCardDirectoryFileSize(
          littleEndian: Int(UInt32(expected).byteSwapped),
          bigEndian: expected
        ),
        RecordingCardDirectoryFileSize(
          sizeBytes: expected,
          confidence: "trusted"
        ),
        "protocol byte order changed for \(expected) bytes"
      )
    }
  }

  func testFileRequestAckRejectsMalformedOrFailedPayloads() {
    XCTAssertNil(
      recordingCardAcknowledgedFileSize(
        payload: [0x00, 0x00, 0x26],
        directorySizeBytes: 9_820
      )
    )
    XCTAssertNil(
      recordingCardAcknowledgedFileSize(
        payload: [0x01, 0x00, 0x00, 0x26, 0x5C],
        directorySizeBytes: 9_820
      )
    )
  }

  func testRecordingClockPreservesEventAnchorsAcrossReadsAndPauses() {
    var clock = RecordingCardRecordingClock()
    let start = Date(timeIntervalSince1970: 1_000)
    clock.observe("recording", fileName: "first.m4a", at: start)
    clock.observe("recording", fileName: "first.m4a", at: start.addingTimeInterval(10))
    XCTAssertEqual(clock.startedAt, start)
    clock.observe("paused", fileName: "first.m4a", at: start.addingTimeInterval(15))
    XCTAssertEqual(clock.durationSeconds, 15)
    XCTAssertNil(clock.startedAt)
    clock.observe("recording", fileName: "first.m4a", at: start.addingTimeInterval(40))
    XCTAssertEqual(clock.durationSeconds, 15)
    XCTAssertEqual(clock.startedAt, start.addingTimeInterval(40))
    clock.observe("paused", fileName: "first.m4a", at: start.addingTimeInterval(47))
    XCTAssertEqual(clock.durationSeconds, 22)
    clock.observe("recording", fileName: "second.m4a", at: start.addingTimeInterval(60))
    XCTAssertEqual(clock.durationSeconds, 0)
    XCTAssertEqual(clock.startedAt, start.addingTimeInterval(60))
    clock.observe("idle", fileName: nil, at: start.addingTimeInterval(80))
    XCTAssertEqual(clock.durationSeconds, 0)
    XCTAssertNil(clock.startedAt)
  }

  func testRecordingStateResponseAppliesOnlyAtCapturedRevision() {
    XCTAssertTrue(
      shouldApplyRecordingCardStateResponse(
        requestRevision: 7,
        currentRevision: 7
      )
    )
    XCTAssertFalse(
      shouldApplyRecordingCardStateResponse(
        requestRevision: 7,
        currentRevision: 8
      )
    )
  }

  func testUnsolicitedRecordingCommandsMapPhysicalDeviceState() {
    XCTAssertEqual(
      recordingCardStateFromUnsolicitedCommand(
        command: 0x06,
        payload: [0x00] + Array(repeating: 0x31, count: 15),
        hasPendingCommand: false
      ),
      "recording"
    )
    XCTAssertEqual(
      recordingCardStateFromUnsolicitedCommand(
        command: 0x08,
        payload: [0x00],
        hasPendingCommand: false
      ),
      "paused"
    )
    XCTAssertEqual(
      recordingCardStateFromUnsolicitedCommand(
        command: 0x09,
        payload: [0x00],
        hasPendingCommand: false
      ),
      "recording"
    )
    XCTAssertEqual(
      recordingCardStateFromUnsolicitedCommand(
        command: 0x07,
        payload: [0x00] + Array(repeating: 0x32, count: 20),
        hasPendingCommand: false
      ),
      "idle"
    )
  }

  func testRecordingInfoKeepsFilenameSizeAndTypeInSeparateFixedFields() {
    let filename = Array("25090512000001".utf8)
    let payload = [UInt8(0x00)] + filename + [0x00, 0x00, 0x10, 0x00, 0x01]

    let parsed = recordingCardRecordingInfoPayload(payload)

    XCTAssertEqual(parsed?.state, "recording")
    XCTAssertEqual(parsed?.fileName, "25090512000001")
    XCTAssertEqual(parsed?.sizeBytes, 4_096)
    XCTAssertEqual(parsed?.recordingType, 1)
    XCTAssertNil(parsed?.needsSync)
  }

  func testRecordingCommandPayloadSeparatesStopMetadataAndAllowsCompactAck() {
    let filename = Array("REC001.WAV".utf8) + Array(repeating: UInt8(0), count: 4)
    let stopPayload = [UInt8(0x00)] + filename + [0x00, 0x01, 0x00, 0x00, 0x02, 0x01]

    let stopped = recordingCardRecordingCommandPayload(command: 0x07, payload: stopPayload)
    let compactStart = recordingCardRecordingCommandPayload(command: 0x06, payload: [0x00])

    XCTAssertEqual(stopped?.state, "idle")
    XCTAssertEqual(stopped?.fileName, "REC001.WAV")
    XCTAssertEqual(stopped?.sizeBytes, 65_536)
    XCTAssertEqual(stopped?.recordingType, 2)
    XCTAssertEqual(stopped?.needsSync, true)
    XCTAssertEqual(compactStart?.state, "recording")
    XCTAssertNil(compactStart?.fileName)
    XCTAssertNil(compactStart?.sizeBytes)
    XCTAssertNil(recordingCardRecordingCommandPayload(command: 0x06, payload: [0x01]))
  }

  func testPendingRejectedAndGenericStatusPacketsPreserveRecordingState() {
    XCTAssertNil(
      recordingCardStateFromUnsolicitedCommand(
        command: 0x06,
        payload: [0x00],
        hasPendingCommand: true
      )
    )
    XCTAssertNil(
      recordingCardStateFromUnsolicitedCommand(
        command: 0x07,
        payload: [0x01],
        hasPendingCommand: false
      )
    )
    XCTAssertNil(
      recordingCardStateFromUnsolicitedCommand(
        command: 0x0F,
        payload: Array(repeating: 0x00, count: 20),
        hasPendingCommand: false
      )
    )
    XCTAssertNil(
      recordingCardStateFromUnsolicitedCommand(
        command: 0x15,
        payload: [0x00],
        hasPendingCommand: false
      )
    )
  }

  func testWifiCredentialsPreferObservedFw920TenPlusEightLayout() {
    let payload = Array("TestWifi01Pass9201".utf8) + Array(repeating: UInt8(0), count: 10)
    let credentials = recordingCardWifiCredentialParts(payload: payload)

    XCTAssertEqual(credentials?.ssid, "TestWifi01")
    XCTAssertEqual(credentials?.password, "Pass9201")
  }

  func testWifiJoinCallbackRequiresCurrentExpectedHandoff() {
    XCTAssertEqual(
      recordingCardWifiJoinCallbackAction(
        capturedGeneration: 4,
        currentGeneration: 4,
        handoffReady: true
      ),
      .accept
    )
    XCTAssertEqual(
      recordingCardWifiJoinCallbackAction(
        capturedGeneration: 4,
        currentGeneration: 5,
        handoffReady: true
      ),
      .cancelAndRemoveConfiguration
    )
    XCTAssertEqual(
      recordingCardWifiJoinCallbackAction(
        capturedGeneration: 4,
        currentGeneration: 4,
        handoffReady: false
      ),
      .cancelAndRemoveConfiguration
    )
    XCTAssertTrue(
      recordingCardWifiJoinCallbackShouldRemoveConfiguration(
        capturedGeneration: 4,
        currentGeneration: 5,
        callbackSSID: "card-old",
        currentJoiningSSID: nil,
        currentJoinedSSID: nil
      )
    )
    XCTAssertFalse(
      recordingCardWifiJoinCallbackShouldRemoveConfiguration(
        capturedGeneration: 4,
        currentGeneration: 5,
        callbackSSID: "card-shared",
        currentJoiningSSID: "card-shared",
        currentJoinedSSID: nil
      )
    )
  }

  func testWifiCredentialLeaseBelongsToCurrentBleTransportAndCard() {
    XCTAssertTrue(
      recordingCardWifiCredentialLeaseIsReusable(
        observedTransportGeneration: 7,
        currentTransportGeneration: 7,
        observedFingerprint: "card-a",
        currentFingerprint: "card-a"
      )
    )
    XCTAssertFalse(
      recordingCardWifiCredentialLeaseIsReusable(
        observedTransportGeneration: 6,
        currentTransportGeneration: 7,
        observedFingerprint: "card-a",
        currentFingerprint: "card-a"
      )
    )
    XCTAssertFalse(
      recordingCardWifiCredentialLeaseIsReusable(
        observedTransportGeneration: 7,
        currentTransportGeneration: 7,
        observedFingerprint: "card-b",
        currentFingerprint: "card-a"
      )
    )
  }

  func testWifiBleDisconnectBecomesExpectedBeforeHandoffIsReady() {
    XCTAssertTrue(
      recordingCardWifiBleDisconnectIsExpected(
        hotspotEnableAcknowledged: true,
        handoffReady: false,
        wifiSessionActive: false
      )
    )
    XCTAssertFalse(
      recordingCardWifiBleDisconnectIsExpected(
        hotspotEnableAcknowledged: false,
        handoffReady: false,
        wifiSessionActive: false
      )
    )
  }

  func testWifiHandoffInvalidatesLogicalBleReadinessBeforePhysicalDisconnect() {
    XCTAssertTrue(recordingCardBleTransportIsReady(
      connectionState: "connected",
      hasWriteCharacteristic: true,
      peripheralState: .connected
    ))
    XCTAssertFalse(recordingCardBleTransportIsReady(
      connectionState: "disconnected",
      hasWriteCharacteristic: true,
      peripheralState: .connected
    ))
    XCTAssertFalse(recordingCardBleTransportIsReady(
      connectionState: "connected",
      hasWriteCharacteristic: true,
      peripheralState: .disconnecting
    ))
  }

  func testWifiPreparationFailureDisablesAcknowledgedWritableHotspot() {
    XCTAssertTrue(
      recordingCardWifiPreparationFailureShouldDisableHotspot(
        hotspotEnableAcknowledged: true,
        handoffReady: false,
        bleWritable: true
      )
    )
    XCTAssertFalse(
      recordingCardWifiPreparationFailureShouldDisableHotspot(
        hotspotEnableAcknowledged: true,
        handoffReady: false,
        bleWritable: false
      )
    )
    XCTAssertFalse(
      recordingCardWifiPreparationFailureShouldDisableHotspot(
        hotspotEnableAcknowledged: false,
        handoffReady: false,
        bleWritable: true
      )
    )
    XCTAssertTrue(
      recordingCardWifiPreparationFailureShouldDisableHotspot(
        hotspotEnableAcknowledged: false,
        hotspotEnableMayHaveBeenDispatched: true,
        handoffReady: false,
        bleWritable: true
      )
    )
    XCTAssertTrue(
      recordingCardWifiPreparationFailureShouldDisableHotspot(
        hotspotEnableAcknowledged: false,
        handoffReady: true,
        bleWritable: true,
        disableReadyHandoff: true
      )
    )
    XCTAssertFalse(
      recordingCardWifiPreparationFailureShouldDisableHotspot(
        hotspotEnableAcknowledged: false,
        handoffReady: true,
        bleWritable: true
      )
    )
  }

  func testWifiHotspotDisableSettlementCoalescesConcurrentCancellation() {
    XCTAssertEqual(
      recordingCardWifiHotspotDisableSettlementAction(
        disableInFlight: true,
        shouldDisable: true
      ),
      .awaitInFlight
    )
    XCTAssertEqual(
      recordingCardWifiHotspotDisableSettlementAction(
        disableInFlight: false,
        shouldDisable: true
      ),
      .beginDisable
    )
    XCTAssertEqual(
      recordingCardWifiHotspotDisableSettlementAction(
        disableInFlight: false,
        shouldDisable: false
      ),
      .completeImmediately
    )
    XCTAssertTrue(
      recordingCardWifiTerminalDisableTimerIsCurrent(
        capturedGeneration: 4,
        currentGeneration: 4,
        disableInFlight: true
      )
    )
    XCTAssertFalse(
      recordingCardWifiTerminalDisableTimerIsCurrent(
        capturedGeneration: 4,
        currentGeneration: 5,
        disableInFlight: true
      )
    )
  }

  func testWifiHotspotMayHaveBeenEnabledTracksAmbiguousDispatch() {
    XCTAssertTrue(
      recordingCardWifiHotspotMayBeEnabled(
        current: false,
        event: .enableDispatched
      )
    )
    XCTAssertFalse(
      recordingCardWifiHotspotMayBeEnabled(
        current: true,
        event: .enableRejected
      )
    )
    XCTAssertFalse(
      recordingCardWifiHotspotMayBeEnabled(
        current: true,
        event: .resetAccepted
      )
    )
    XCTAssertFalse(
      recordingCardWifiHotspotMayBeEnabled(
        current: true,
        event: .terminalSettled
      )
    )
  }

  func testWifiAttemptOwnershipKeepsSetupActiveUntilTerminalCleanup() {
    XCTAssertFalse(
      recordingCardWifiAttemptCanBegin(
        sessionActive: false,
        attemptOwned: true,
        joinInProgress: false,
        preparationInFlight: false,
        disableInFlight: false,
        handoffReady: false,
        bleDisconnectExpected: false,
        joiningSSID: nil,
        joinedSSID: nil
      )
    )
    XCTAssertFalse(
      recordingCardWifiAttemptCanBegin(
        sessionActive: false,
        attemptOwned: false,
        joinInProgress: false,
        preparationInFlight: false,
        disableInFlight: false,
        handoffReady: true,
        bleDisconnectExpected: true,
        joiningSSID: nil,
        joinedSSID: "card-a"
      )
    )
    XCTAssertTrue(
      recordingCardWifiHandoffOwnershipIsActive(
        sessionActive: false,
        attemptOwned: true,
        joinInProgress: false,
        preparationInFlight: false,
        disableInFlight: false,
        handoffReady: false,
        bleDisconnectExpected: false,
        joiningSSID: nil,
        joinedSSID: nil
      )
    )
    XCTAssertTrue(
      recordingCardWifiHandoffOwnershipIsActive(
        sessionActive: true,
        attemptOwned: false,
        joinInProgress: false,
        preparationInFlight: false,
        disableInFlight: false,
        handoffReady: false,
        bleDisconnectExpected: false,
        joiningSSID: nil,
        joinedSSID: nil
      )
    )
    XCTAssertTrue(
      recordingCardWifiAttemptCanBegin(
        sessionActive: false,
        attemptOwned: false,
        joinInProgress: false,
        preparationInFlight: false,
        disableInFlight: false,
        handoffReady: false,
        bleDisconnectExpected: false,
        joiningSSID: nil,
        joinedSSID: nil
      )
    )
  }

  func testWifiCredentialGateAndVerificationRejectLateAttemptCallbacks() {
    XCTAssertFalse(
      recordingCardShouldAcceptWifiCredentials(
        preparationInFlight: false,
        unsolicitedGateOpen: false
      )
    )
    XCTAssertTrue(
      recordingCardShouldAcceptWifiCredentials(
        preparationInFlight: true,
        unsolicitedGateOpen: false
      )
    )
    XCTAssertEqual(
      recordingCardWifiHandoffCallbackStatus(
        capturedGeneration: 8,
        currentGeneration: 9,
        capturedBatchId: "batch-a",
        currentBatchId: "batch-a",
        capturedAttemptId: "attempt-a",
        currentAttemptId: "attempt-a",
        handoffReady: true,
        expectedSSID: "card-a",
        joinedSSID: "card-a",
        wifiPathSatisfied: true
      ),
      "networkUnavailable"
    )
    XCTAssertEqual(
      recordingCardWifiHandoffCallbackStatus(
        capturedGeneration: 9,
        currentGeneration: 9,
        capturedBatchId: "batch-a",
        currentBatchId: "batch-a",
        capturedAttemptId: "attempt-a",
        currentAttemptId: "attempt-a",
        handoffReady: true,
        expectedSSID: "card-a",
        joinedSSID: "card-a",
        wifiPathSatisfied: true
      ),
      "ready"
    )
    XCTAssertEqual(
      recordingCardWifiHandoffCallbackStatus(
        capturedGeneration: 9,
        currentGeneration: 9,
        capturedBatchId: "batch-a",
        currentBatchId: "batch-a",
        capturedAttemptId: "attempt-a",
        currentAttemptId: "attempt-b",
        handoffReady: true,
        expectedSSID: "card-a",
        joinedSSID: "card-a",
        wifiPathSatisfied: true
      ),
      "networkUnavailable"
    )
  }

  func testWifiAttemptAndBleRecoveryRequireExactOwnership() {
    XCTAssertFalse(recordingCardLegacyWifiOperationCanBegin(scopedAttemptOwned: true))
    XCTAssertTrue(recordingCardLegacyWifiOperationCanBegin(scopedAttemptOwned: false))
    XCTAssertTrue(
      recordingCardWifiAttemptMatches(
        identityProvided: true,
        capturedBatchId: "batch-a",
        capturedAttemptId: "attempt-a",
        currentBatchId: "batch-a",
        currentAttemptId: "attempt-a",
        currentAttemptOwned: true
      )
    )
    XCTAssertFalse(
      recordingCardWifiAttemptMatches(
        identityProvided: true,
        capturedBatchId: "batch-a",
        capturedAttemptId: "attempt-a",
        currentBatchId: "batch-a",
        currentAttemptId: "attempt-b",
        currentAttemptOwned: true
      )
    )
    XCTAssertFalse(
      recordingCardWifiAttemptMatches(
        identityProvided: true,
        capturedBatchId: "batch-a",
        capturedAttemptId: "attempt-a",
        currentBatchId: "batch-a",
        currentAttemptId: "attempt-a",
        currentAttemptOwned: false
      )
    )
    XCTAssertFalse(
      recordingCardWifiAttemptMatches(
        identityProvided: true,
        capturedBatchId: "batch-a",
        capturedAttemptId: nil,
        currentBatchId: "batch-a",
        currentAttemptId: "attempt-a",
        currentAttemptOwned: true
      )
    )
    XCTAssertTrue(
      recordingCardWifiAttemptMatches(
        identityProvided: false,
        capturedBatchId: nil,
        capturedAttemptId: nil,
        currentBatchId: "batch-a",
        currentAttemptId: "attempt-a",
        currentAttemptOwned: false
      )
    )
    XCTAssertTrue(
      recordingCardWifiBackgroundRecoveryOwnsTarget(
        awaitingRecovery: true,
        ownerFingerprint: "card-a",
        requestedFingerprint: "card-a"
      )
    )
    XCTAssertFalse(
      recordingCardWifiBackgroundRecoveryOwnsTarget(
        awaitingRecovery: true,
        ownerFingerprint: "card-a",
        requestedFingerprint: "card-b"
      )
    )
    XCTAssertTrue(
      recordingCardWifiBackgroundLeaseMatchesOwner(
        capturedBatchId: "batch-a",
        capturedAttemptId: "attempt-a",
        capturedOwnerFingerprint: "card-a",
        requestedBatchId: "batch-a",
        requestedAttemptId: "attempt-a",
        requestedOwnerFingerprint: "card-a"
      )
    )
    XCTAssertFalse(
      recordingCardWifiBackgroundLeaseMatchesOwner(
        capturedBatchId: "batch-a",
        capturedAttemptId: "attempt-a",
        capturedOwnerFingerprint: "card-a",
        requestedBatchId: "batch-a",
        requestedAttemptId: "attempt-b",
        requestedOwnerFingerprint: "card-a"
      )
    )
    XCTAssertTrue(
      recordingCardWifiBackgroundSettlementOwnsLease(
        awaitingRecovery: true,
        leaseBatchId: "batch-a",
        leaseAttemptId: "attempt-a",
        leaseOwnerFingerprint: "card-a",
        requestedBatchId: "batch-a",
        requestedAttemptId: "attempt-a",
        requestedOwnerFingerprint: "card-a"
      )
    )
    XCTAssertFalse(
      recordingCardWifiBackgroundSettlementOwnsLease(
        awaitingRecovery: false,
        leaseBatchId: "batch-a",
        leaseAttemptId: "attempt-a",
        leaseOwnerFingerprint: "card-a",
        requestedBatchId: "batch-a",
        requestedAttemptId: "attempt-a",
        requestedOwnerFingerprint: "card-a"
      )
    )
    XCTAssertFalse(
      recordingCardWifiBackgroundSettlementOwnsLease(
        awaitingRecovery: true,
        leaseBatchId: "batch-a",
        leaseAttemptId: "attempt-a",
        leaseOwnerFingerprint: "card-a",
        requestedBatchId: "batch-b",
        requestedAttemptId: "attempt-a",
        requestedOwnerFingerprint: "card-a"
      )
    )
    XCTAssertTrue(
      recordingCardWifiBackgroundLeaseShouldRetainForSettlement(
        retentionRequested: true,
        scopedAttemptOwned: true,
        bleConnected: true
      )
    )
    XCTAssertTrue(
      recordingCardWifiBackgroundLeaseShouldRetainForSettlement(
        retentionRequested: true,
        scopedAttemptOwned: true,
        bleConnected: false
      )
    )
    XCTAssertTrue(
      recordingCardWifiBackgroundLeaseShouldRetainForSettlement(
        retentionRequested: true,
        scopedAttemptOwned: false,
        bleConnected: false
      )
    )
    XCTAssertFalse(
      recordingCardWifiBackgroundLeaseShouldRetainForSettlement(
        retentionRequested: true,
        scopedAttemptOwned: false,
        bleConnected: true
      )
    )
    XCTAssertTrue(
      recordingCardWifiBackgroundLeaseCallbackIsCurrent(
        capturedGeneration: 7,
        currentGeneration: 7,
        capturedIdentifier: 42,
        currentIdentifier: 42,
        sameLease: true
      )
    )
    XCTAssertFalse(
      recordingCardWifiBackgroundLeaseCallbackIsCurrent(
        capturedGeneration: 7,
        currentGeneration: 8,
        capturedIdentifier: 42,
        currentIdentifier: 42,
        sameLease: false
      )
    )
    XCTAssertFalse(
      recordingCardWifiBackgroundLeaseShouldEnd(
        retainForBleRecovery: false,
        forceEnd: false,
        awaitingBleRecovery: true
      )
    )
    XCTAssertTrue(
      recordingCardWifiBackgroundLeaseShouldEnd(
        retainForBleRecovery: false,
        forceEnd: true,
        awaitingBleRecovery: true
      )
    )
    XCTAssertEqual(
      recordingCardWifiSessionCloseIngressAction(operationInFlight: true),
      .rejectBusy
    )
    XCTAssertEqual(
      recordingCardWifiSessionCloseIngressAction(operationInFlight: false),
      .beginTerminalCleanup
    )
    XCTAssertTrue(
      recordingCardWifiFailurePreservesAttemptOwnership(
        .awaitScopedTerminalCleanup,
        transferBatchId: "batch-a",
        transferAttemptId: "attempt-a",
        currentBatchId: "batch-a",
        currentAttemptId: "attempt-a",
        currentAttemptOwned: true
      )
    )
    XCTAssertFalse(
      recordingCardWifiFailurePreservesAttemptOwnership(
        .awaitScopedTerminalCleanup,
        transferBatchId: nil,
        transferAttemptId: nil,
        currentBatchId: "batch-a",
        currentAttemptId: "attempt-a",
        currentAttemptOwned: true
      )
    )
    XCTAssertFalse(
      recordingCardWifiFailurePreservesAttemptOwnership(
        .awaitScopedTerminalCleanup,
        transferBatchId: "batch-a",
        transferAttemptId: "attempt-a",
        currentBatchId: "batch-a",
        currentAttemptId: "attempt-a",
        currentAttemptOwned: false
      )
    )
    XCTAssertFalse(
      recordingCardWifiFailurePreservesAttemptOwnership(
        .selfContained(settleHotspot: true),
        transferBatchId: "batch-a",
        transferAttemptId: "attempt-a",
        currentBatchId: "batch-a",
        currentAttemptId: "attempt-a",
        currentAttemptOwned: true
      )
    )
    XCTAssertEqual(
      recordingCardEffectiveWifiFailureCleanupMode(
        .awaitScopedTerminalCleanup,
        transferBatchId: "batch-a",
        transferAttemptId: "attempt-a",
        currentBatchId: "batch-a",
        currentAttemptId: "attempt-a",
        currentAttemptOwned: true
      ),
      .awaitScopedTerminalCleanup
    )
    XCTAssertEqual(
      recordingCardEffectiveWifiFailureCleanupMode(
        .awaitScopedTerminalCleanup,
        transferBatchId: nil,
        transferAttemptId: nil,
        currentBatchId: "batch-a",
        currentAttemptId: "attempt-a",
        currentAttemptOwned: true
      ),
      .selfContained(settleHotspot: true)
    )
    XCTAssertEqual(
      recordingCardEffectiveWifiFailureCleanupMode(
        .awaitScopedTerminalCleanup,
        transferBatchId: "batch-a",
        transferAttemptId: "attempt-a",
        currentBatchId: "batch-a",
        currentAttemptId: "attempt-a",
        currentAttemptOwned: false
      ),
      .selfContained(settleHotspot: true)
    )
    XCTAssertTrue(
      recordingCardWifiFailureSessionIsCurrent(
        capturedSessionId: "session-a",
        currentSessionId: "session-a"
      )
    )
    XCTAssertFalse(
      recordingCardWifiFailureSessionIsCurrent(
        capturedSessionId: "session-a",
        currentSessionId: "session-b"
      )
    )
    XCTAssertFalse(
      recordingCardWifiFailureSessionIsCurrent(
        capturedSessionId: "session-a",
        currentSessionId: nil
      )
    )
  }

  func testWifiEnvelopeMatchesObservedFw920LayoutAndRoundTrips() {
    let frame = encodeRecordingCardWifiFrame(
      command: 0x20,
      sequence: 0,
      payload: [0x00]
    )
    let bytes = [UInt8](frame)

    XCTAssertEqual(frame.count, 41)
    XCTAssertEqual(Array(bytes[0..<15]), Array("XnoteWifiHead  ".utf8))
    XCTAssertEqual(bytes[15], 0x20)
    XCTAssertEqual(Array(bytes[16..<20]), [0x00, 0x00, 0x00, 0x00])
    XCTAssertEqual(Array(bytes[20..<24]), [0x00, 0x00, 0x00, 0x01])
    XCTAssertEqual(bytes[24], 0x00)
    XCTAssertEqual(Array(bytes[25..<41]), Array("XnoteWifiTail   ".utf8))

    guard case let .frame(packet, frameLength) =
      parseRecordingCardWifiFrame(frame)
    else {
      return XCTFail("Expected a complete Wi-Fi frame")
    }
    XCTAssertEqual(frameLength, 41)
    XCTAssertEqual(packet.command, 0x20)
    XCTAssertEqual(packet.sequence, 0)
    XCTAssertEqual(packet.payload, [0x00])
  }

  func testWifiEnvelopeSupportsSplitInputAndRejectsCorruption() {
    let frame = encodeRecordingCardWifiFrame(
      command: 0x0B,
      sequence: 7,
      payload: Array("synthetic-file".utf8) + [0, 0, 0, 0]
    )
    if case .pending = parseRecordingCardWifiFrame(frame.prefix(20)) {
      // Expected until the complete header, payload, and tail arrive.
    } else {
      XCTFail("Expected split Wi-Fi frame to remain pending")
    }

    var corrupted = [UInt8](frame)
    corrupted[18] ^= 0x01
    if case .invalid = parseRecordingCardWifiFrame(Data(corrupted)) {
      // Expected CRC rejection.
    } else {
      XCTFail("Expected corrupted Wi-Fi frame to be rejected")
    }
  }

  func testWifiEnvelopeAllowsOmittedCrcOnlyForExplicitCompatibilityProfile() {
    var omittedCrc = [UInt8](encodeRecordingCardWifiFrame(
      command: 0x0A,
      sequence: 0,
      payload: [0x00] + Array("SYNTHETIC00001".utf8) + [0x00, 0x00, 0x00, 0x20, 0x00]
    ))
    omittedCrc[18] = 0x00
    omittedCrc[19] = 0x00

    if case .invalid = parseRecordingCardWifiFrame(Data(omittedCrc)) {
      // Strict mode must reject a missing checksum for a non-zero payload CRC.
    } else {
      XCTFail("Expected strict Wi-Fi parsing to reject an omitted checksum")
    }
    guard case let .frame(packet, _) = parseRecordingCardWifiFrame(
      Data(omittedCrc),
      allowOmittedDataCrc: true
    ) else {
      return XCTFail("Expected the explicit firmware profile to accept an omitted checksum")
    }
    XCTAssertEqual(packet.command, 0x0A)
    XCTAssertEqual(packet.payload.count, 20)

    omittedCrc[18] = 0x12
    omittedCrc[19] = 0x34
    if case .invalid = parseRecordingCardWifiFrame(
      Data(omittedCrc),
      allowOmittedDataCrc: true
    ) {
      // A non-zero mismatched checksum remains invalid in compatibility mode.
    } else {
      XCTFail("Expected a non-zero corrupt checksum to remain invalid")
    }
  }

  func testWifiSequenceEstablishesBaselineRejectsGapsAndWraps() {
    XCTAssertEqual(
      recordingCardWifiNextSequence(expected: nil, received: 7),
      8
    )
    XCTAssertEqual(
      recordingCardWifiNextSequence(expected: 8, received: 8),
      9
    )
    XCTAssertNil(
      recordingCardWifiNextSequence(expected: 9, received: 8)
    )
    XCTAssertNil(
      recordingCardWifiNextSequence(expected: 9, received: 10)
    )
    XCTAssertEqual(
      recordingCardWifiNextSequence(expected: UInt16.max, received: UInt16.max),
      0
    )
  }

  func testWifiPayloadRejectsEmptyAndOverrunData() {
    XCTAssertTrue(
      recordingCardWifiPayloadFits(remainingBytes: 4_040, payloadBytes: 4_040)
    )
    XCTAssertFalse(
      recordingCardWifiPayloadFits(remainingBytes: 4_039, payloadBytes: 4_040)
    )
    XCTAssertFalse(
      recordingCardWifiPayloadFits(remainingBytes: 4_040, payloadBytes: 0)
    )
  }

  func testWifiStatusOnlyResponsesAreDistinct() {
    XCTAssertEqual(recordingCardWifiStatusOnlyResponse([0x00]), .accepted)
    XCTAssertEqual(recordingCardWifiStatusOnlyResponse([0x01]), .rejected)
    XCTAssertEqual(recordingCardWifiStatusOnlyResponse([0x02]), .incomplete)
    XCTAssertEqual(recordingCardWifiStatusOnlyResponse([0x03]), .notStatus)
    XCTAssertEqual(recordingCardWifiStatusOnlyResponse([0x00, 0x01]), .notStatus)
  }

  func testWifiPrematureEndWaitsForTrailingDataAndFailsOnlyAfterGrace() {
    XCTAssertEqual(
      recordingCardWifiEndDecision(
        receivedBytes: 72_360,
        targetBytes: 72_614,
        graceExpired: false
      ),
      .awaitTrailingData
    )
    XCTAssertEqual(
      recordingCardWifiEndDecision(
        receivedBytes: 72_360,
        targetBytes: 72_614,
        graceExpired: true
      ),
      .failIncomplete
    )
    XCTAssertEqual(
      recordingCardWifiEndDecision(
        receivedBytes: 72_614,
        targetBytes: 72_614,
        graceExpired: false
      ),
      .complete
    )
    XCTAssertEqual(
      recordingCardWifiEndDecision(
        receivedBytes: 72_614,
        targetBytes: 72_614,
        graceExpired: true
      ),
      .complete
    )
    XCTAssertEqual(
      recordingCardWifiEndDecision(
        receivedBytes: 72_615,
        targetBytes: 72_614,
        graceExpired: false
      ),
      .failIncomplete
    )
  }

  func testWifiTailSeekRequestUsesFourByteBigEndianOffset() {
    guard let payload = recordingCardFileRequestPayload(
      "20260101010101",
      seekOffset: 4_040
    ) else {
      return XCTFail("Expected a valid synthetic tail-seek request")
    }
    XCTAssertEqual(payload.count, 18)
    XCTAssertEqual(Array(payload.suffix(4)), [0x00, 0x00, 0x0F, 0xC8])

    let frame = encodeRecordingCardWifiFrame(
      command: 0x0B,
      sequence: 0,
      payload: payload
    )
    XCTAssertEqual(frame.count, 58)
    XCTAssertEqual(Array(frame[20..<24]), [0x00, 0x00, 0x00, 0x12])
    guard case let .frame(packet, frameLength) = parseRecordingCardWifiFrame(frame) else {
      return XCTFail("Expected the synthetic tail-seek frame to round trip")
    }
    XCTAssertEqual(frameLength, 58)
    XCTAssertEqual(packet.payload, payload)

    guard let deepPayload = recordingCardFileRequestPayload(
      "20260101010101",
      seekOffset: 72_360
    ) else {
      return XCTFail("Expected a valid synthetic deep tail-seek request")
    }
    XCTAssertEqual(Array(deepPayload.suffix(4)), [0x00, 0x01, 0x1A, 0xA8])

    XCTAssertNil(recordingCardFileRequestPayload("20260101010101", seekOffset: -1))
    XCTAssertNil(recordingCardFileRequestPayload(
      "20260101010101",
      seekOffset: Int(UInt32.max) + 1
    ))
    XCTAssertNil(recordingCardFileRequestPayload("filename-is-too-long", seekOffset: 0))
  }

  func testWifiTailSeekRecoveryIsOneShotAndFirmwareScoped() {
    let profileAllowed = recordingCardWifiAllowsQuietBoundary(
      firmwareVersion: "1.0.6",
      wifiFirmwareVersion: "1.0.2"
    )
    XCTAssertEqual(recordingCardWifiTailResumeOffset(
      verifiedProfile: profileAllowed,
      receivedBytes: 4_040,
      targetBytes: 4_204,
      alreadyAttempted: false
    ), 4_040)
    XCTAssertEqual(recordingCardWifiTailResumeOffset(
      verifiedProfile: profileAllowed,
      receivedBytes: 12_120,
      targetBytes: 13_566,
      alreadyAttempted: false
    ), 12_120)
    XCTAssertEqual(recordingCardWifiTailResumeOffset(
      verifiedProfile: profileAllowed,
      receivedBytes: 72_360,
      targetBytes: 72_614,
      alreadyAttempted: false
    ), 72_360)
    XCTAssertEqual(recordingCardWifiTailResumeOffset(
      verifiedProfile: profileAllowed,
      receivedBytes: 6_333_280,
      targetBytes: 6_333_578,
      alreadyAttempted: false
    ), 6_333_280)
    XCTAssertNil(recordingCardWifiTailResumeOffset(
      verifiedProfile: profileAllowed,
      receivedBytes: 3_920,
      targetBytes: 4_924,
      alreadyAttempted: false
    ))
    XCTAssertNil(recordingCardWifiTailResumeOffset(
      verifiedProfile: profileAllowed,
      receivedBytes: 4_040,
      targetBytes: 4_924,
      alreadyAttempted: true
    ))
    XCTAssertNil(recordingCardWifiTailResumeOffset(
      verifiedProfile: false,
      receivedBytes: 4_040,
      targetBytes: 4_924,
      alreadyAttempted: false
    ))
    XCTAssertNil(recordingCardWifiTailResumeOffset(
      verifiedProfile: profileAllowed,
      receivedBytes: 4_040,
      targetBytes: 8_081,
      alreadyAttempted: false
    ))
    XCTAssertEqual(recordingCardWifiTailResumeOffset(
      verifiedProfile: profileAllowed,
      receivedBytes: 4_040,
      targetBytes: 8_080,
      alreadyAttempted: false
    ), 4_040)
    XCTAssertNil(recordingCardWifiTailResumeOffset(
      verifiedProfile: profileAllowed,
      receivedBytes: 0,
      targetBytes: 4_924,
      alreadyAttempted: false
    ))
    XCTAssertNil(recordingCardWifiTailResumeOffset(
      verifiedProfile: profileAllowed,
      receivedBytes: 4_040,
      targetBytes: 4_040,
      alreadyAttempted: false
    ))
    let beyondUInt32 = Int(UInt32.max) + 1
    XCTAssertNil(recordingCardWifiTailResumeOffset(
      verifiedProfile: profileAllowed,
      receivedBytes: beyondUInt32,
      targetBytes: beyondUInt32 + 254,
      alreadyAttempted: false
    ))
    XCTAssertTrue(recordingCardWifiTailPayloadMatches(
      remainingBytes: 254,
      payloadBytes: 254
    ))
    XCTAssertFalse(recordingCardWifiTailPayloadMatches(
      remainingBytes: 254,
      payloadBytes: 4_040
    ))
    XCTAssertTrue(recordingCardWifiTailPayloadMatches(
      remainingBytes: 4_040,
      payloadBytes: 4_040
    ))
  }

  func testWifiQuietBoundaryIsRestrictedToObservedFirmwareProfile() {
    XCTAssertTrue(recordingCardWifiAllowsQuietBoundary(
      firmwareVersion: "1.0.6",
      wifiFirmwareVersion: "1.0.2"
    ))
    XCTAssertFalse(recordingCardWifiAllowsQuietBoundary(
      firmwareVersion: "1.1.0",
      wifiFirmwareVersion: "1.0.2"
    ))
    XCTAssertFalse(recordingCardWifiAllowsQuietBoundary(
      firmwareVersion: "1.0.6",
      wifiFirmwareVersion: nil
    ))
  }

  func testWifiBoundaryModeUsesQuietOnlyForIntermediateObservedProfile() {
    XCTAssertEqual(
      recordingCardWifiBoundaryMode(
        allowQuietBoundary: true,
        requestedFileCount: 3,
        completedFileCount: 0
      ),
      .interFileQuiet
    )
    XCTAssertEqual(
      recordingCardWifiBoundaryMode(
        allowQuietBoundary: true,
        requestedFileCount: 3,
        completedFileCount: 2
      ),
      .requestStop
    )
    XCTAssertEqual(
      recordingCardWifiBoundaryMode(
        allowQuietBoundary: false,
        requestedFileCount: 3,
        completedFileCount: 0
      ),
      .requestStop
    )
    XCTAssertEqual(
      recordingCardWifiBoundaryMode(
        allowQuietBoundary: true,
        requestedFileCount: 1,
        completedFileCount: 0
      ),
      .requestStop
    )
    XCTAssertEqual(
      recordingCardWifiBoundaryMode(
        allowQuietBoundary: true,
        requestedFileCount: 3,
        completedFileCount: 1
      ),
      .interFileQuiet
    )
    XCTAssertEqual(
      recordingCardWifiBoundaryMode(
        allowQuietBoundary: true,
        requestedFileCount: 2,
        completedFileCount: 0
      ),
      .interFileQuiet,
      "A resumed session's first remaining file uses session-local ordinal zero"
    )
    XCTAssertEqual(
      recordingCardWifiBoundaryMode(
        allowQuietBoundary: true,
        requestedFileCount: 5,
        completedFileCount: 0
      ),
      .interFileQuiet
    )
    XCTAssertEqual(
      recordingCardWifiBoundaryMode(
        allowQuietBoundary: true,
        requestedFileCount: 5,
        completedFileCount: 4
      ),
      .requestStop
    )
  }

  func testWifiDataSequenceContinuesAcrossFileBoundaries() {
    let afterTail = recordingCardWifiNextSequence(
      expected: nil,
      received: 2
    )
    XCTAssertEqual(afterTail, 3)
    XCTAssertEqual(
      recordingCardWifiNextSequence(
        expected: afterTail,
        received: 3
      ),
      4
    )
    XCTAssertNil(
      recordingCardWifiNextSequence(
        expected: afterTail,
        received: 0
      )
    )
    XCTAssertNil(
      recordingCardWifiNextSequence(
        expected: afterTail,
        received: 4
      )
    )
  }

  func testMethodChannelIntegersDoNotConfuseZeroAndOneWithBooleans() {
    XCTAssertEqual(
      recordingCardChannelInteger(NSNumber(value: 0), minimum: 0),
      0
    )
    XCTAssertEqual(
      recordingCardChannelInteger(NSNumber(value: 1), minimum: 1),
      1
    )
    XCTAssertNil(recordingCardChannelInteger(NSNumber(value: 0), minimum: 1))
    XCTAssertNil(recordingCardChannelInteger(NSNumber(value: true), minimum: 0))
    XCTAssertNil(recordingCardChannelInteger(true, minimum: 0))
  }
}
