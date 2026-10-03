import CoreBluetooth
import CryptoKit
import Darwin
import Flutter
import Foundation
import Network
import NetworkExtension
import UIKit

struct RecordingCardHandshakeGuard {
  private(set) var inProgress = false
  private(set) var bindingDeadline: TimeInterval?
  private(set) var bindingDispatchMetDeadline: Bool?
  private var serialReceived = false

  mutating func begin() -> Bool {
    guard !inProgress else { return false }
    inProgress = true
    bindingDeadline = nil
    bindingDispatchMetDeadline = nil
    return true
  }

  mutating func receivedSerial(at uptime: TimeInterval) {
    guard inProgress, !serialReceived else { return }
    serialReceived = true
    bindingDeadline = uptime + 5
  }

  func bindingWindowExpired(at uptime: TimeInterval) -> Bool {
    guard let bindingDeadline else { return false }
    return uptime >= bindingDeadline
  }

  mutating func dispatchedBinding(at uptime: TimeInterval) -> Bool {
    guard inProgress, let deadline = bindingDeadline else { return false }
    bindingDispatchMetDeadline = uptime < deadline
    bindingDeadline = nil
    return true
  }

  mutating func reset() {
    inProgress = false
    bindingDeadline = nil
    bindingDispatchMetDeadline = nil
    serialReceived = false
  }
}

enum RecordingCardHandshakeFailure: Error, Equatable {
  case bindingInfoMalformed
  case bindingAckMalformed
  case bindingRejected

  var code: String {
    switch self {
    case .bindingInfoMalformed: return "RECORDING_CARD_BINDING_INFO_MALFORMED"
    case .bindingAckMalformed: return "RECORDING_CARD_BINDING_ACK_MALFORMED"
    case .bindingRejected: return "RECORDING_CARD_BINDING_REJECTED"
    }
  }

  var safeMessage: String {
    switch self {
    case .bindingInfoMalformed: return "Recording-card binding information was malformed."
    case .bindingAckMalformed: return "Recording-card binding acknowledgement was malformed."
    case .bindingRejected: return "Recording-card rejected this pairing request."
    }
  }
}

func recordingCardBindingAcknowledgementFailure(
  _ payload: [UInt8]
) -> RecordingCardHandshakeFailure? {
  guard payload.count == 1 else { return .bindingAckMalformed }
  switch payload[0] {
  case 0x00: return nil
  case 0x01: return .bindingRejected
  default: return .bindingAckMalformed
  }
}

func recordingCardControlStatusForDiagnostic(
  command: UInt8,
  payload: [UInt8]
) -> String {
  switch command {
  case 0x01, 0x02, 0x03, 0x1F:
    return "masked"
  default:
    return payload.first.map { String(format: "0x%02X", $0) } ?? "none"
  }
}

func compatibleRecordingCardBindingToken(
  existingPayload: [UInt8],
  requested: [UInt8],
  legacy: [UInt8]
) -> [UInt8]? {
  guard requested.count == 16, legacy.count == 16,
    !existingPayload.isEmpty
  else { return nil }
  if existingPayload.allSatisfy({ $0 == 0 }) { return requested }
  guard existingPayload.count >= 16 else { return nil }
  return Array(existingPayload.prefix(16))
}

enum RecordingCardUnbindTokenResolution: Equatable {
  case token([UInt8])
  case alreadyUnbound
  case malformed
  case conflict
}

func resolveRecordingCardUnbindToken(
  existingPayload: [UInt8],
  requested: [UInt8],
  legacy: [UInt8]
) -> RecordingCardUnbindTokenResolution {
  guard requested.count == 16, legacy.count == 16, !existingPayload.isEmpty else {
    return .malformed
  }
  if existingPayload.allSatisfy({ $0 == 0 }) { return .alreadyUnbound }
  guard existingPayload.count >= 16 else { return .malformed }
  let existing = Array(existingPayload.prefix(16))
  if existing == requested || existing == legacy { return .token(existing) }
  return .conflict
}

func recordingCardUnbindPayload(deleteDeviceFiles: Bool) -> [UInt8] {
  Array(repeating: 0x00, count: 16) + [deleteDeviceFiles ? 0x01 : 0x00]
}

func recordingCardUnbindAckAccepted(_ payload: [UInt8]) -> Bool {
  payload.first == 0x00
}

func recordingCardUnbindDisconnectCompletesOperation(
  unbindInProgress: Bool,
  commandDispatched: Bool
) -> Bool {
  unbindInProgress && commandDispatched
}

enum RecordingCardManufacturerAdvertisementEligibility: String, Equatable {
  case missing
  case tooShort
  case companyPrefixMismatch
  case eligible
}

private let recordingCardManufacturerCandidateMinimumBytes = 9
private let recordingCardManufacturerSerialOffset = 8
private let recordingCardManufacturerSerialMinimumBytes = 6
private let recordingCardManufacturerSerialMaximumBytes = 64

/// Classifies the FW920 advertisement shape without retaining raw identity bytes.
/// The recording card emits its `0x5C37` vendor identifier as raw manufacturer
/// bytes `5C 37`; this is the prefix observed from the physical card.
func recordingCardManufacturerAdvertisementEligibility(
  _ manufacturerData: Data?
) -> RecordingCardManufacturerAdvertisementEligibility {
  guard let manufacturerData else { return .missing }
  let bytes = [UInt8](manufacturerData)
  guard bytes.count >= 2 else { return .tooShort }
  guard bytes[0] == 0x5C, bytes[1] == 0x37 else {
    return .companyPrefixMismatch
  }
  guard bytes.count >= recordingCardManufacturerCandidateMinimumBytes else {
    return .tooShort
  }

  // Candidate discovery uses the documented prefix and six address bytes plus
  // the smallest app-inferred evidence of a non-empty trailing identity field.
  // The complete tail is validated independently before selection is enabled.
  return .eligible
}

func recordingCardManufacturerAdvertisementSerialNumber(_ manufacturerData: Data?) -> String? {
  guard recordingCardManufacturerAdvertisementIsEligible(manufacturerData),
        let manufacturerData else {
    return nil
  }
  let bytes = [UInt8](manufacturerData)
  var serial = Array(bytes.dropFirst(recordingCardManufacturerSerialOffset))
  while let last = serial.last, last == 0x00 || last == 0x20 {
    serial.removeLast()
  }
  func isAlphaNumeric(_ byte: UInt8) -> Bool {
    (byte >= 0x30 && byte <= 0x39) ||
      (byte >= 0x41 && byte <= 0x5A) ||
      (byte >= 0x61 && byte <= 0x7A)
  }
  guard serial.count >= recordingCardManufacturerSerialMinimumBytes,
        serial.count <= recordingCardManufacturerSerialMaximumBytes,
        let first = serial.first,
        isAlphaNumeric(first),
        serial.allSatisfy({ byte in
          isAlphaNumeric(byte) || byte == 0x3A || byte == 0x2D
        }),
        let value = String(bytes: serial, encoding: .ascii),
        recordingCardNormalizedOwnershipSerial(value) != nil else {
    return nil
  }
  return value
}

func recordingCardManufacturerAdvertisementIsEligible(_ manufacturerData: Data?) -> Bool {
  recordingCardManufacturerAdvertisementEligibility(manufacturerData) == .eligible
}

/// Produces a diagnostic which intentionally excludes MAC/SN and all identity data.
func recordingCardManufacturerAdvertisementDiagnostic(_ manufacturerData: Data?) -> String {
  let bytes = manufacturerData.map { [UInt8]($0) } ?? []
  let companyPrefix = bytes.prefix(2)
    .map { String(format: "%02X", $0) }
    .joined(separator: " ")
  let renderedPrefix = companyPrefix.isEmpty ? "none" : companyPrefix
  let eligibility = recordingCardManufacturerAdvertisementEligibility(manufacturerData)
  let identity = recordingCardManufacturerAdvertisementSerialNumber(manufacturerData) == nil
    ? "provisional" : "selectable"
  return "manufacturer eligibility=\(eligibility.rawValue) identity=\(identity) dataLength=\(bytes.count) companyPrefix=\(renderedPrefix)"
}

func recordingCardMergedDiscoveredDeviceMap(
  current: [String: Any]?,
  advertisedName: String?,
  peripheralName: String?,
  defaultName: String,
  fingerprint: String,
  rssi: Int,
  isConnectable: Bool?,
  serialNumber: String?,
  lastSeenAt: String
) -> [String: Any] {
  func nonBlank(_ value: String?) -> String? {
    guard let value,
      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      return nil
    }
    return value
  }

  var row = current ?? [:]
  row["displayName"] = nonBlank(advertisedName)
    ?? nonBlank(current?["displayName"] as? String)
    ?? nonBlank(peripheralName)
    ?? defaultName
  row["safeDeviceFingerprint"] = fingerprint
  if rssi >= -127 && rssi <= 40 {
    row["rssi"] = rssi
  }
  row["lastSeenAt"] = lastSeenAt
  if let isConnectable {
    row["isConnectable"] = isConnectable
  }
  if row["serialNumber"] as? String == nil, let serialNumber {
    row["serialNumber"] = serialNumber
  }
  return row
}

func recordingCardDiscoveryRowHasMeaningfulChange(
  current: [String: Any]?,
  next: [String: Any]
) -> Bool {
  guard let current else { return true }
  return (current["displayName"] as? String) != (next["displayName"] as? String)
    || (current["safeDeviceFingerprint"] as? String)
      != (next["safeDeviceFingerprint"] as? String)
    || (current["isConnectable"] as? Bool) != (next["isConnectable"] as? Bool)
    || (current["serialNumber"] as? String) != (next["serialNumber"] as? String)
}

func recordingCardCommittedDownloadMatchesDirectorySize(
  actualSize: Int,
  directorySizeBytes: Int?
) -> Bool {
  guard actualSize > 0,
    let directorySizeBytes,
    isValidDeviceFileSize(directorySizeBytes)
  else { return false }
  return actualSize == directorySizeBytes
}

enum RecordingCardCommittedDownloadRecoveryAction: Equatable {
  case reuse
  case reset
}

func recordingCardCommittedDownloadRecoveryAction(
  actualSize: Int,
  directorySizeBytes: Int?
) -> RecordingCardCommittedDownloadRecoveryAction {
  recordingCardCommittedDownloadMatchesDirectorySize(
    actualSize: actualSize,
    directorySizeBytes: directorySizeBytes
  ) ? .reuse : .reset
}

struct RecordingCardCommittedFileMetadata: Equatable {
  let sizeBytes: Int
  let contentHash: String
}

enum RecordingCardDownloadedFileCommitError: Error, Equatable {
  case invalidLocation
  case invalidExpectedSize
  case synchronizeFailed(Int32)
  case sizeMismatch(expected: Int, actual: Int)
  case hashMismatch
  case renameFailed(Int32)

  var code: String {
    switch self {
    case .invalidExpectedSize, .sizeMismatch:
      return "RECORDING_CARD_DOWNLOAD_SIZE_MISMATCH"
    case .invalidLocation, .synchronizeFailed, .hashMismatch, .renameFailed:
      return "RECORDING_CARD_LOCAL_STORAGE_FAILED"
    }
  }
}

func recordingCardSHA256File(at fileURL: URL) throws -> String {
  let input = try FileHandle(forReadingFrom: fileURL)
  defer { try? input.close() }
  var digest = SHA256()
  while let data = try input.read(upToCount: 65_536), !data.isEmpty {
    digest.update(data: data)
  }
  return digest.finalize().map { String(format: "%02x", $0) }.joined()
}

func recordingCardCommitDownloadedPart(
  output: FileHandle,
  partURL: URL,
  finalURL: URL,
  expectedSize: Int,
  streamedContentHash: String
) throws -> RecordingCardCommittedFileMetadata {
  let source = partURL.standardizedFileURL
  let destination = finalURL.standardizedFileURL
  guard source.deletingLastPathComponent() == destination.deletingLastPathComponent(),
    source != destination
  else {
    throw RecordingCardDownloadedFileCommitError.invalidLocation
  }
  guard isValidDeviceFileSize(expectedSize) else {
    throw RecordingCardDownloadedFileCommitError.invalidExpectedSize
  }
  var synchronizeResult: Int32
  repeat {
    synchronizeResult = Darwin.fsync(output.fileDescriptor)
  } while synchronizeResult != 0 && errno == EINTR
  guard synchronizeResult == 0 else {
    throw RecordingCardDownloadedFileCommitError.synchronizeFailed(errno)
  }
  let actualSize = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
  guard actualSize == expectedSize else {
    throw RecordingCardDownloadedFileCommitError.sizeMismatch(
      expected: expectedSize,
      actual: actualSize
    )
  }
  let expectedHash = streamedContentHash.trimmingCharacters(
    in: .whitespacesAndNewlines
  ).lowercased()
  guard expectedHash.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
    try recordingCardSHA256File(at: source) == expectedHash
  else {
    throw RecordingCardDownloadedFileCommitError.hashMismatch
  }
  try output.close()
  let renameResult = source.path.withCString { sourcePath in
    destination.path.withCString { destinationPath in
      Darwin.rename(sourcePath, destinationPath)
    }
  }
  guard renameResult == 0 else {
    throw RecordingCardDownloadedFileCommitError.renameFailed(errno)
  }
  return RecordingCardCommittedFileMetadata(
    sizeBytes: actualSize,
    contentHash: expectedHash
  )
}

enum RecordingCardRestoredTransportResetAction: Equatable {
  case clear
  case drainLateCallback
  case waitForBluetooth
  case awaitDisconnect
  case cancelAndAwaitDisconnect
}

func recordingCardRestoredTransportResetAction(
  isDisconnected: Bool,
  bluetoothReady: Bool,
  awaitingDisconnectCallback: Bool = false
) -> RecordingCardRestoredTransportResetAction {
  if isDisconnected {
    return awaitingDisconnectCallback ? .drainLateCallback : .clear
  }
  if awaitingDisconnectCallback { return .awaitDisconnect }
  return bluetoothReady ? .cancelAndAwaitDisconnect : .waitForBluetooth
}

func recordingCardDisconnectPredatesActiveConnection(
  disconnectTimestamp: CFAbsoluteTime?,
  activeConnectStartedAt: CFAbsoluteTime?
) -> Bool {
  guard let disconnectTimestamp, let activeConnectStartedAt else { return false }
  return disconnectTimestamp < activeConnectStartedAt
}

func recordingCardRestoredTransportDrainOwnsEntry(
  capturedTicket: UInt64,
  currentTicket: UInt64?,
  matchesPeripheralObject: Bool
) -> Bool {
  currentTicket == capturedTicket && matchesPeripheralObject
}

struct RecordingCardConnectionAttempt {
  private(set) var generation = 0
  private(set) var inProgress = false

  mutating func begin() -> Int {
    generation += 1
    inProgress = true
    return generation
  }

  func owns(_ generation: Int) -> Bool {
    inProgress && self.generation == generation
  }

  mutating func finish() {
    inProgress = false
  }
}

struct RecordingCardCommandOwnership: Equatable {
  let requestID: UInt64
  let transportGeneration: UInt64

  func isCurrent(requestID: UInt64, transportGeneration: UInt64) -> Bool {
    self.requestID == requestID && self.transportGeneration == transportGeneration
  }
}

struct RecordingCardCommandDispatchState: Equatable {
  private(set) var count = 0
  private(set) var firstDispatchedAt: TimeInterval?

  mutating func record(at uptime: TimeInterval) {
    if firstDispatchedAt == nil { firstDispatchedAt = uptime }
    count += 1
  }
}

func recordingCardCanRetryBindingInfo(
  handshakeInProgress: Bool,
  unbindInProgress: Bool,
  dispatchCount: Int
) -> Bool {
  handshakeInProgress && !unbindInProgress && dispatchCount == 1
}

func recordingCardCommandTimeoutStartsOnDispatch(
  handshakeInProgress: Bool,
  unbindInProgress: Bool
) -> Bool {
  handshakeInProgress && !unbindInProgress
}

func recordingCardBindingInfoRetryDueUptime(
  existingDueUptime: TimeInterval?,
  now: TimeInterval,
  delay: TimeInterval
) -> TimeInterval {
  let requestedDueUptime = now + max(0, delay)
  return min(existingDueUptime ?? requestedDueUptime, requestedDueUptime)
}

func recordingCardConnectionDeadlineErrorCode(stage: String) -> String {
  stage == "searching" ? "RECORDING_CARD_NOT_FOUND" : "RECORDING_CARD_SETUP_TIMEOUT"
}

enum RecordingCardRestoredTransportResumeAction: Equatable {
  case none
  case startConnectScan
  case startManualScan
}

func recordingCardRestoredTransportResumeAction(
  hasPendingConnect: Bool,
  hasPendingManualScan: Bool,
  hasSelectedPeripheral: Bool = false,
  hasActiveScan: Bool = false
) -> RecordingCardRestoredTransportResumeAction {
  if hasSelectedPeripheral || hasActiveScan { return .none }
  if hasPendingConnect { return .startConnectScan }
  if hasPendingManualScan { return .startManualScan }
  return .none
}

enum RecordingCardBleScanOwner: Equatable {
  case none
  case manual
  case connection
}

func recordingCardScanOwnerAcceptsDiscovery(_ owner: RecordingCardBleScanOwner) -> Bool {
  owner != .none
}

func recordingCardShouldPublishDisconnectedForRestoredState(
  hasVerifiedActiveBleTransport: Bool
) -> Bool {
  !hasVerifiedActiveBleTransport
}

func recordingCardFailedPeripheralNeedsCancellation(
  _ state: CBPeripheralState
) -> Bool {
  state == .connecting || state == .connected
}

enum RecordingCardBluetoothConnectionPreflight: Equatable {
  case proceed
  case waitForState
  case reject
}

func recordingCardBluetoothConnectionPreflight(
  _ state: CBManagerState
) -> RecordingCardBluetoothConnectionPreflight {
  switch state {
  case .poweredOn:
    return .proceed
  case .unknown, .resetting:
    return .waitForState
  case .poweredOff, .unauthorized, .unsupported:
    return .reject
  @unknown default:
    return .waitForState
  }
}

enum RecordingCardBluetoothNameAck: Equatable {
  case accepted
  case rejected
  case invalid
}

func recordingCardBluetoothNamePayload(_ bluetoothName: String) -> [UInt8]? {
  guard !bluetoothName.isEmpty,
    !bluetoothName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
    !bluetoothName.unicodeScalars.contains(where: {
      CharacterSet.controlCharacters.contains($0)
    })
  else {
    return nil
  }

  let nameBytes = Array(bluetoothName.utf8)
  guard nameBytes.count <= 32 else { return nil }
  return nameBytes + Array(repeating: 0x00, count: 32 - nameBytes.count)
}

func recordingCardBluetoothNameAck(_ payload: [UInt8]) -> RecordingCardBluetoothNameAck {
  guard payload.count == 1 else { return .invalid }
  switch payload[0] {
  case 0x00:
    return .accepted
  case 0x01:
    return .rejected
  default:
    return .invalid
  }
}

func recordingCardSerialNumber(serialPayload: [UInt8]) -> String? {
  var serial = serialPayload
  if serial.first == 0x00, serial.count > 1 {
    serial.removeFirst()
  }
  while serial.last == 0x00 || serial.last == 0x20 {
    serial.removeLast()
  }
  let allowed = Set(
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._:-".utf8
  )
  guard (6...64).contains(serial.count), serial.allSatisfy(allowed.contains) else {
    return nil
  }
  return String(bytes: serial, encoding: .utf8)
}

func recordingCardNormalizedOwnershipSerial(_ value: String) -> String? {
  var normalized = ""
  for byte in value.trimmingCharacters(in: .whitespacesAndNewlines).utf8 {
    switch byte {
    case 0x61...0x7A:
      normalized.append(Character(UnicodeScalar(byte - 0x20)))
    case 0x41...0x5A, 0x30...0x39:
      normalized.append(Character(UnicodeScalar(byte)))
    case 0x2D, 0x3A, 0x20, 0x09:
      continue
    default:
      return nil
    }
  }
  return (6...64).contains(normalized.utf8.count) ? normalized : nil
}

func recordingCardSerialMatchesExpected(_ expected: String?, actual: String?) -> Bool {
  guard let expected else { return true }
  guard let expectedNormalized = recordingCardNormalizedOwnershipSerial(expected),
        let actual,
        let actualNormalized = recordingCardNormalizedOwnershipSerial(actual) else {
    return false
  }
  return expectedNormalized == actualNormalized
}

func recordingCardCanReuseConnection(
  requestedFingerprint: String?,
  activeFingerprint: String?,
  expectedSerial: String?,
  actualSerial: String?
) -> Bool {
  (requestedFingerprint == nil || requestedFingerprint == activeFingerprint)
    && recordingCardSerialMatchesExpected(expectedSerial, actual: actualSerial)
}

final class RecordingCardTransientHandshakeIdentity {
  private(set) var serialNumber: String?

  @discardableResult
  func capture(serialPayload: [UInt8]) -> Bool {
    guard let serialNumber = recordingCardSerialNumber(serialPayload: serialPayload) else {
      self.serialNumber = nil
      return false
    }
    self.serialNumber = serialNumber
    return true
  }

  func clear() {
    serialNumber = nil
  }
}

func recordingCardOpaqueAccountClaim(serialPayload: [UInt8]) -> String? {
  guard let serial = recordingCardSerialNumber(serialPayload: serialPayload) else {
    return nil
  }
  var input = Data("huahuo-fw920-account-binding-v1:".utf8)
  input.append(contentsOf: serial.utf8)
  return SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
}

func recordingCardShouldReuseCachedPeripheral(
  forceScan: Bool,
  hasCachedPeripheral: Bool
) -> Bool {
  !forceScan && hasCachedPeripheral
}

func recordingCardWifiHandoffVerificationStatus(
  handoffExpected: Bool,
  expectedSSID: String?,
  joinedSSID: String?,
  wifiPathSatisfied: Bool
) -> String {
  guard handoffExpected,
    let expectedSSID,
    !expectedSSID.isEmpty,
    joinedSSID == expectedSSID,
    wifiPathSatisfied
  else {
    return "networkUnavailable"
  }
  return "ready"
}

func recordingCardCachedPeripheralDisplayName(
  scannedDisplayName: String?,
  peripheralName: String?
) -> String {
  if let scannedDisplayName,
    !scannedDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  {
    return scannedDisplayName
  }
  return peripheralName ?? ""
}

func recordingCardAcknowledgedFileSize(
  payload: [UInt8],
  directorySizeBytes: Int?
) -> Int? {
  guard payload.count >= 5, payload.first == 0x00 else { return nil }
  let littleEndian = readUInt32(payload, offset: 1, littleEndian: true)
  let bigEndian = readUInt32(payload, offset: 1)
  guard let resolved = recordingCardDirectoryFileSize(
    littleEndian: littleEndian,
    bigEndian: bigEndian
  ) else { return nil }
  if let directorySizeBytes,
    isValidDeviceFileSize(directorySizeBytes),
    directorySizeBytes != resolved.sizeBytes
  {
    return nil
  }
  return resolved.sizeBytes
}

struct RecordingCardDirectoryFileSize: Equatable {
  let sizeBytes: Int
  let confidence: String
}

func recordingCardDirectoryFileSize(
  littleEndian: Int,
  bigEndian: Int
) -> RecordingCardDirectoryFileSize? {
  let bigEndianIsValid = isValidDeviceFileSize(bigEndian)
  if bigEndianIsValid {
    return RecordingCardDirectoryFileSize(sizeBytes: bigEndian, confidence: "trusted")
  }
  return nil
}

func shouldApplyRecordingCardStateResponse(
  requestRevision: Int,
  currentRevision: Int
) -> Bool {
  requestRevision == currentRevision
}

struct RecordingCardRecordingClock {
  private(set) var state = "idle"
  private(set) var fileName: String?
  private(set) var startedAt: Date?
  private(set) var accumulatedSeconds: TimeInterval = 0

  var durationSeconds: Int { Int(max(0, accumulatedSeconds)) }

  mutating func observe(_ next: String, fileName nextFileName: String?, at: Date) {
    let changedFile = nextFileName != nil && fileName != nil && nextFileName != fileName
    switch next {
    case "idle":
      accumulatedSeconds = 0
      startedAt = nil
      fileName = nil
    case "recording":
      if state != "recording" || changedFile {
        if state != "paused" || changedFile { accumulatedSeconds = 0 }
        startedAt = at
      }
      fileName = nextFileName ?? fileName
    case "paused":
      if changedFile || state == "idle" {
        accumulatedSeconds = 0
      } else if state == "recording", let startedAt {
        accumulatedSeconds += max(0, at.timeIntervalSince(startedAt))
      }
      startedAt = nil
      fileName = nextFileName ?? fileName
    default:
      return
    }
    state = next
  }
}

private func recordingCardClockTimestamp(_ date: Date) -> String {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  return formatter.string(from: date)
}

struct RecordingCardRecordingPayload: Equatable {
  let state: String
  let fileName: String?
  let sizeBytes: Int?
  let recordingType: Int?
  let needsSync: Bool?
}

private func recordingCardProtocolFilename(_ payload: [UInt8], offset: Int) -> String? {
  let fieldEnd = offset + 14
  guard offset >= 0, payload.count >= fieldEnd else { return nil }
  var field = Array(payload[offset..<fieldEnd])
  while field.first == 0x00 || field.first == 0x20 { field.removeFirst() }
  while field.last == 0x00 || field.last == 0x20 { field.removeLast() }
  guard !field.isEmpty,
    field.allSatisfy({ byte in
      (byte >= 0x30 && byte <= 0x39) ||
        (byte >= 0x41 && byte <= 0x5A) ||
        (byte >= 0x61 && byte <= 0x7A) ||
        byte == 0x2E || byte == 0x5F || byte == 0x2D
    }),
    let filename = String(bytes: field, encoding: .ascii),
    !filename.lowercased().hasSuffix(".part")
  else { return nil }
  return filename
}

func recordingCardRecordingInfoPayload(_ payload: [UInt8]) -> RecordingCardRecordingPayload? {
  guard let value = payload.first,
    let state = recordingStateFromRecordingInfo(value)
  else { return nil }
  if state == "idle" {
    return RecordingCardRecordingPayload(
      state: state,
      fileName: nil,
      sizeBytes: nil,
      recordingType: nil,
      needsSync: nil
    )
  }
  return RecordingCardRecordingPayload(
    state: state,
    fileName: recordingCardProtocolFilename(payload, offset: 1),
    sizeBytes: payload.count >= 19 ? readUInt32(payload, offset: 15) : nil,
    recordingType: payload.count > 19 ? Int(payload[19]) : nil,
    needsSync: nil
  )
}

func recordingCardRecordingCommandPayload(
  command: UInt8,
  payload: [UInt8]
) -> RecordingCardRecordingPayload? {
  guard payload.first == 0x00 else { return nil }
  let state: String
  switch command {
  case 0x06, 0x09:
    state = "recording"
  case 0x08:
    state = "paused"
  case 0x07:
    state = "idle"
  default:
    return nil
  }
  let isStop = command == 0x07
  let typeOffset = isStop ? 19 : 15
  return RecordingCardRecordingPayload(
    state: state,
    fileName: recordingCardProtocolFilename(payload, offset: 1),
    sizeBytes: isStop && payload.count >= 19 ? readUInt32(payload, offset: 15) : nil,
    recordingType: payload.count > typeOffset ? Int(payload[typeOffset]) : nil,
    needsSync: isStop && payload.count > 20 ? payload[20] != 0x00 : nil
  )
}

func recordingCardStateFromUnsolicitedCommand(
  command: UInt8,
  payload: [UInt8],
  hasPendingCommand: Bool
) -> String? {
  guard !hasPendingCommand else { return nil }
  return recordingCardRecordingCommandPayload(command: command, payload: payload)?.state
}

struct RecordingCardWifiCredentialParts: Equatable {
  let ssid: String
  let password: String
}

enum RecordingCardWifiJoinCallbackAction: Equatable {
  case accept
  case cancelAndRemoveConfiguration
}

enum RecordingCardWifiHotspotDisableSettlementAction: Equatable {
  case awaitInFlight
  case beginDisable
  case completeImmediately
}

enum RecordingCardWifiHotspotPossibilityEvent: Equatable {
  case enableDispatched
  case enableRejected
  case resetAccepted
  case terminalSettled
}

enum RecordingCardWifiSessionCloseIngressAction: Equatable {
  case beginTerminalCleanup
  case rejectBusy
}

enum RecordingCardWifiFailureCleanupMode: Equatable {
  case awaitScopedTerminalCleanup
  case selfContained(settleHotspot: Bool)
}

func recordingCardWifiJoinCallbackAction(
  capturedGeneration: Int,
  currentGeneration: Int,
  handoffReady: Bool
) -> RecordingCardWifiJoinCallbackAction {
  capturedGeneration == currentGeneration && handoffReady
    ? .accept
    : .cancelAndRemoveConfiguration
}

func recordingCardWifiCredentialLeaseIsReusable(
  observedTransportGeneration: UInt64?,
  currentTransportGeneration: UInt64,
  observedFingerprint: String?,
  currentFingerprint: String?
) -> Bool {
  guard observedTransportGeneration == currentTransportGeneration,
    let observedFingerprint, !observedFingerprint.isEmpty,
    let currentFingerprint, !currentFingerprint.isEmpty
  else { return false }
  return observedFingerprint == currentFingerprint
}

func recordingCardWifiBleDisconnectIsExpected(
  hotspotEnableAcknowledged: Bool,
  handoffReady: Bool,
  wifiSessionActive: Bool
) -> Bool {
  hotspotEnableAcknowledged || handoffReady || wifiSessionActive
}

func recordingCardBleTransportIsReady(
  connectionState: String,
  hasWriteCharacteristic: Bool,
  peripheralState: CBPeripheralState?
) -> Bool {
  connectionState == "connected"
    && hasWriteCharacteristic
    && peripheralState == .connected
}

func recordingCardWifiPreparationFailureShouldDisableHotspot(
  hotspotEnableAcknowledged: Bool,
  hotspotEnableMayHaveBeenDispatched: Bool = false,
  handoffReady: Bool,
  bleWritable: Bool,
  disableReadyHandoff: Bool = false
) -> Bool {
  guard bleWritable else { return false }
  if handoffReady { return disableReadyHandoff }
  return hotspotEnableAcknowledged || hotspotEnableMayHaveBeenDispatched
}

func recordingCardWifiHotspotDisableSettlementAction(
  disableInFlight: Bool,
  shouldDisable: Bool
) -> RecordingCardWifiHotspotDisableSettlementAction {
  if disableInFlight { return .awaitInFlight }
  return shouldDisable ? .beginDisable : .completeImmediately
}

func recordingCardWifiHotspotMayBeEnabled(
  current: Bool,
  event: RecordingCardWifiHotspotPossibilityEvent
) -> Bool {
  switch event {
  case .enableDispatched:
    return true
  case .enableRejected, .resetAccepted, .terminalSettled:
    return false
  }
}

func recordingCardWifiTerminalDisableTimerIsCurrent(
  capturedGeneration: UInt64,
  currentGeneration: UInt64,
  disableInFlight: Bool
) -> Bool {
  disableInFlight && capturedGeneration == currentGeneration
}

func recordingCardWifiAttemptCanBegin(
  sessionActive: Bool,
  attemptOwned: Bool,
  joinInProgress: Bool,
  preparationInFlight: Bool,
  disableInFlight: Bool,
  handoffReady: Bool,
  bleDisconnectExpected: Bool,
  joiningSSID: String?,
  joinedSSID: String?
) -> Bool {
  !sessionActive && !attemptOwned && !joinInProgress && !preparationInFlight && !disableInFlight
    && !handoffReady && !bleDisconnectExpected
    && joiningSSID == nil && joinedSSID == nil
}

func recordingCardWifiHandoffOwnershipIsActive(
  sessionActive: Bool,
  attemptOwned: Bool,
  joinInProgress: Bool,
  preparationInFlight: Bool,
  disableInFlight: Bool,
  handoffReady: Bool,
  bleDisconnectExpected: Bool,
  joiningSSID: String?,
  joinedSSID: String?
) -> Bool {
  !recordingCardWifiAttemptCanBegin(
    sessionActive: sessionActive,
    attemptOwned: attemptOwned,
    joinInProgress: joinInProgress,
    preparationInFlight: preparationInFlight,
    disableInFlight: disableInFlight,
    handoffReady: handoffReady,
    bleDisconnectExpected: bleDisconnectExpected,
    joiningSSID: joiningSSID,
    joinedSSID: joinedSSID
  )
}

func recordingCardWifiBackgroundRecoveryOwnsTarget(
  awaitingRecovery: Bool,
  ownerFingerprint: String?,
  requestedFingerprint: String?
) -> Bool {
  guard awaitingRecovery,
    let ownerFingerprint, !ownerFingerprint.isEmpty,
    let requestedFingerprint, !requestedFingerprint.isEmpty
  else { return false }
  return ownerFingerprint == requestedFingerprint
}

func recordingCardWifiBackgroundLeaseMatchesOwner(
  capturedBatchId: String?,
  capturedAttemptId: String?,
  capturedOwnerFingerprint: String?,
  requestedBatchId: String?,
  requestedAttemptId: String?,
  requestedOwnerFingerprint: String?
) -> Bool {
  guard let capturedOwnerFingerprint, !capturedOwnerFingerprint.isEmpty,
    let requestedOwnerFingerprint, !requestedOwnerFingerprint.isEmpty
  else { return false }
  return capturedBatchId == requestedBatchId
    && capturedAttemptId == requestedAttemptId
    && capturedOwnerFingerprint == requestedOwnerFingerprint
}

func recordingCardWifiBackgroundSettlementOwnsLease(
  awaitingRecovery: Bool,
  leaseBatchId: String?,
  leaseAttemptId: String?,
  leaseOwnerFingerprint: String?,
  requestedBatchId: String,
  requestedAttemptId: String,
  requestedOwnerFingerprint: String
) -> Bool {
  awaitingRecovery
    && recordingCardWifiBackgroundLeaseMatchesOwner(
      capturedBatchId: leaseBatchId,
      capturedAttemptId: leaseAttemptId,
      capturedOwnerFingerprint: leaseOwnerFingerprint,
      requestedBatchId: requestedBatchId,
      requestedAttemptId: requestedAttemptId,
      requestedOwnerFingerprint: requestedOwnerFingerprint
    )
}

func recordingCardWifiBackgroundLeaseShouldRetainForSettlement(
  retentionRequested: Bool,
  scopedAttemptOwned: Bool,
  bleConnected: Bool
) -> Bool {
  retentionRequested && (scopedAttemptOwned || !bleConnected)
}

func recordingCardWifiBackgroundLeaseShouldEnd(
  retainForBleRecovery: Bool,
  forceEnd: Bool,
  awaitingBleRecovery: Bool
) -> Bool {
  !retainForBleRecovery && (forceEnd || !awaitingBleRecovery)
}

func recordingCardWifiBackgroundLeaseCallbackIsCurrent(
  capturedGeneration: UInt64,
  currentGeneration: UInt64,
  capturedIdentifier: Int,
  currentIdentifier: Int,
  sameLease: Bool
) -> Bool {
  sameLease
    && capturedGeneration == currentGeneration
    && capturedIdentifier == currentIdentifier
}

func recordingCardWifiAttemptMatches(
  identityProvided: Bool,
  capturedBatchId: String?,
  capturedAttemptId: String?,
  currentBatchId: String?,
  currentAttemptId: String?,
  currentAttemptOwned: Bool
) -> Bool {
  if !identityProvided { return true }
  guard currentAttemptOwned,
    capturedBatchId != nil,
    capturedAttemptId != nil
  else { return false }
  return capturedBatchId == currentBatchId && capturedAttemptId == currentAttemptId
}

func recordingCardLegacyWifiOperationCanBegin(
  scopedAttemptOwned: Bool
) -> Bool {
  !scopedAttemptOwned
}

func recordingCardWifiSessionCloseIngressAction(
  operationInFlight: Bool
) -> RecordingCardWifiSessionCloseIngressAction {
  operationInFlight ? .rejectBusy : .beginTerminalCleanup
}

func recordingCardWifiFailurePreservesAttemptOwnership(
  _ mode: RecordingCardWifiFailureCleanupMode,
  transferBatchId: String?,
  transferAttemptId: String?,
  currentBatchId: String?,
  currentAttemptId: String?,
  currentAttemptOwned: Bool
) -> Bool {
  guard mode == .awaitScopedTerminalCleanup else { return false }
  return recordingCardWifiAttemptMatches(
    identityProvided: true,
    capturedBatchId: transferBatchId,
    capturedAttemptId: transferAttemptId,
    currentBatchId: currentBatchId,
    currentAttemptId: currentAttemptId,
    currentAttemptOwned: currentAttemptOwned
  )
}

func recordingCardEffectiveWifiFailureCleanupMode(
  _ requestedMode: RecordingCardWifiFailureCleanupMode,
  transferBatchId: String?,
  transferAttemptId: String?,
  currentBatchId: String?,
  currentAttemptId: String?,
  currentAttemptOwned: Bool
) -> RecordingCardWifiFailureCleanupMode {
  guard recordingCardWifiFailurePreservesAttemptOwnership(
    requestedMode,
    transferBatchId: transferBatchId,
    transferAttemptId: transferAttemptId,
    currentBatchId: currentBatchId,
    currentAttemptId: currentAttemptId,
    currentAttemptOwned: currentAttemptOwned
  ) else {
    if requestedMode == .awaitScopedTerminalCleanup {
      return .selfContained(settleHotspot: true)
    }
    return requestedMode
  }
  return .awaitScopedTerminalCleanup
}

func recordingCardWifiFailureSessionIsCurrent(
  capturedSessionId: String,
  currentSessionId: String?
) -> Bool {
  capturedSessionId == currentSessionId
}

func recordingCardShouldAcceptWifiCredentials(
  preparationInFlight: Bool,
  unsolicitedGateOpen: Bool
) -> Bool {
  preparationInFlight || unsolicitedGateOpen
}

func recordingCardWifiJoinCallbackShouldRemoveConfiguration(
  capturedGeneration: Int,
  currentGeneration: Int,
  callbackSSID: String,
  currentJoiningSSID: String?,
  currentJoinedSSID: String?
) -> Bool {
  capturedGeneration == currentGeneration
    || (currentJoiningSSID != callbackSSID && currentJoinedSSID != callbackSSID)
}

func recordingCardWifiHandoffCallbackStatus(
  capturedGeneration: Int,
  currentGeneration: Int,
  capturedBatchId: String?,
  currentBatchId: String?,
  capturedAttemptId: String?,
  currentAttemptId: String?,
  handoffReady: Bool,
  expectedSSID: String?,
  joinedSSID: String?,
  wifiPathSatisfied: Bool
) -> String {
  guard capturedGeneration == currentGeneration,
    capturedBatchId == currentBatchId,
    capturedAttemptId == currentAttemptId
  else {
    return "networkUnavailable"
  }
  return recordingCardWifiHandoffVerificationStatus(
    handoffExpected: handoffReady,
    expectedSSID: expectedSSID,
    joinedSSID: joinedSSID,
    wifiPathSatisfied: wifiPathSatisfied
  )
}

func recordingCardWifiCredentialParts(
  payload: [UInt8]
) -> RecordingCardWifiCredentialParts? {
  let bytes = payload.first == 0x00 ? Array(payload.dropFirst()) : payload
  guard !bytes.isEmpty else { return nil }

  func printable(_ value: [UInt8], maximumLength: Int) -> String? {
    var trimmed = Array(value.prefix { $0 != 0x00 })
    while trimmed.last == 0x20 { trimmed.removeLast() }
    guard !trimmed.isEmpty, trimmed.count <= maximumLength,
      trimmed.allSatisfy({ $0 >= 0x20 && $0 <= 0x7E })
    else { return nil }
    return String(bytes: trimmed, encoding: .ascii)
  }

  // FW920 publishes 10-byte SSID + 8-byte password + zero padding. Check the
  // padding so a real legacy 16-byte SSID cannot be mis-split at byte ten.
  if bytes.count >= 18, bytes.dropFirst(18).allSatisfy({ $0 == 0x00 }),
    let ssid = printable(Array(bytes.prefix(10)), maximumLength: 64),
    let password = printable(Array(bytes[10..<18]), maximumLength: 128)
  {
    return RecordingCardWifiCredentialParts(ssid: ssid, password: password)
  }
  if bytes.count >= 24, bytes.dropFirst(24).allSatisfy({ $0 == 0x00 }),
    let ssid = printable(Array(bytes.prefix(16)), maximumLength: 64),
    let password = printable(Array(bytes[16..<24]), maximumLength: 128)
  {
    return RecordingCardWifiCredentialParts(ssid: ssid, password: password)
  }
  if let split = bytes.firstIndex(of: 0x00), split > bytes.startIndex,
    split < bytes.index(before: bytes.endIndex)
  {
    let ssid = printable(Array(bytes[..<split]), maximumLength: 64)
    let password = printable(Array(bytes[bytes.index(after: split)...]), maximumLength: 128)
    if let ssid, let password {
      return RecordingCardWifiCredentialParts(ssid: ssid, password: password)
    }
  }
  return nil
}

private func recordingCardDebugLog(_ message: @autoclosure () -> String) {
  #if DEBUG
    let rendered = message()
    let line = "[FW920] \(rendered)"
    NSLog("%@", line)
    if let data = "\(line)\n".data(using: .utf8) {
      RecordingCardDebugDiagnostics.append(data)
    }
  #endif
}

#if DEBUG
  private enum RecordingCardDebugDiagnostics {
    private static let lock = NSLock()
    private static let fileURL = FileManager.default.urls(
      for: .cachesDirectory,
      in: .userDomainMask
    ).first?.appendingPathComponent("fw920-debug.log", isDirectory: false)

    static func reset() {
      lock.lock()
      defer { lock.unlock() }
      guard let fileURL else { return }
      try? Data().write(to: fileURL, options: .atomic)
    }

    static func append(_ data: Data) {
      lock.lock()
      defer { lock.unlock() }
      guard let fileURL else { return }
      if !FileManager.default.fileExists(atPath: fileURL.path) {
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
      }
      let descriptor = Darwin.open(
        fileURL.path,
        O_WRONLY | O_CREAT | O_APPEND,
        S_IRUSR | S_IWUSR
      )
      guard descriptor >= 0 else { return }
      defer { Darwin.close(descriptor) }
      data.withUnsafeBytes { bytes in
        guard let baseAddress = bytes.baseAddress else { return }
        var offset = 0
        while offset < bytes.count {
          let written = Darwin.write(
            descriptor,
            baseAddress.advanced(by: offset),
            bytes.count - offset
          )
          if written > 0 {
            offset += written
          } else if written < 0, errno == EINTR {
            continue
          } else {
            return
          }
        }
      }
    }
  }
#endif

final class RecordingCardBridge: NSObject, FlutterStreamHandler {
  private static var activeBridges: [RecordingCardBridge] = []

  private let methodChannel: FlutterMethodChannel
  private let eventChannel: FlutterEventChannel
  private let driver = RecordingCardBleDriver()
  private var eventSink: FlutterEventSink?

  static func register(with messenger: FlutterBinaryMessenger) {
    activeBridges.append(RecordingCardBridge(messenger: messenger))
  }

  private init(messenger: FlutterBinaryMessenger) {
    #if DEBUG
      RecordingCardDebugDiagnostics.reset()
      if let legacyProbeURL = recordingCardWifiLegacyDeepTailSeekProbeURL() {
        try? FileManager.default.removeItem(at: legacyProbeURL)
      }
    #endif
    methodChannel = FlutterMethodChannel(
      name: "huahuoai/recording_card",
      binaryMessenger: messenger
    )
    eventChannel = FlutterEventChannel(
      name: "huahuoai/recording_card/events",
      binaryMessenger: messenger
    )
    super.init()
    eventChannel.setStreamHandler(self)
    driver.onEvent = { [weak self] event in
      DispatchQueue.main.async {
        self?.eventSink?(event)
      }
    }
    methodChannel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call: call, result: result)
    }
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    eventSink = events
    events(driver.runtimeSnapshotEvent())
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    #if DEBUG && targetEnvironment(simulator)
    if ["prepareWifiTransfer", "prepareWifiSession", "beginWifiAttempt", "downloadFileOverWifi"].contains(call.method) {
      result(FlutterError(code: "RECORDING_CARD_SIMULATOR_WIFI_UNSUPPORTED",
        message: "Wi-Fi handoff requires a physical iPhone; BLE relay remains available.", details: nil))
      return
    }
    #endif
    let scopedMethods: Set<String> = ["prepareWifiSession", "verifyWifiHandoff",
      "joinWifiNetwork", "openWifiSession", "downloadFileInWifiSession",
      "closeWifiSession", "cancelWifiSession"]
    if scopedMethods.contains(call.method), !driver.acceptsWifiAttempt(call.arguments as? [String: Any]) {
      result(FlutterError(code: "RECORDING_CARD_WIFI_ATTEMPT_SUPERSEDED",
        message: "Wi-Fi attempt no longer owns the session.", details: nil))
      return
    }
    switch call.method {
    case "scanDevices":
      driver.scanDevices(result: result)
    case "cancelDiscovery":
      driver.cancelDiscovery(result: result)
    case "connect":
      let args = call.arguments as? [String: Any]
      let timeoutMs = args?["overallTimeoutMs"] as? Int
      let fingerprint = args?["safeDeviceFingerprint"] as? String
      let expectedSerialNumber = args?["expectedSerialNumber"] as? String
      let bindingToken = args?["bindingToken"] as? String
      let forceScan = args?["forceScan"] as? Bool ?? false
      driver.connect(
        safeDeviceFingerprint: fingerprint,
        expectedSerialNumber: expectedSerialNumber,
        bindingTokenHex: bindingToken,
        forceScan: forceScan,
        timeoutMs: timeoutMs,
        result: result
      )
    case "getConnectionState":
      result(driver.deviceStateMap())
    case "setBluetoothName":
      let args = call.arguments as? [String: Any]
      driver.setBluetoothName(
        bluetoothName: args?["bluetoothName"] as? String,
        result: result
      )
    case "refreshDeviceInfo":
      driver.refreshDeviceInfo(result: result)
    case "readRecordingState":
      driver.readRecordingState(result: result)
    case "readAccountBindingClaim":
      driver.readAccountBindingClaim(result: result)
    case "readAccountBindingIdentity":
      driver.readAccountBindingIdentity(result: result)
    case "signAccountBindingChallenge":
      driver.signAccountBindingChallenge(result: result)
    case "startRecording":
      driver.recordingCommand(.startRecording, result: result)
    case "pauseRecording":
      driver.recordingCommand(.pauseRecording, result: result)
    case "resumeRecording":
      driver.recordingCommand(.resumeRecording, result: result)
    case "stopRecording":
      driver.recordingCommand(.stopRecording, result: result)
    case "scanFiles":
      driver.scanFiles(result: result)
    case "downloadFileToLocalCache", "syncFileToLocalCache", "downloadRecoverableBluetoothFile":
      driver.downloadFile(call.arguments as? [String: Any], result: result)
    case "recoverBluetoothDownload":
      driver.recoverBluetoothDownload(call.arguments as? [String: Any], result: result)
    case "cancelFileTransfer":
      driver.cancelFileTransfer(result: result)
    case "deleteFileFromDevice":
      driver.deleteFile(call.arguments as? [String: Any], result: result)
    case "prepareWifiTransfer":
      driver.prepareWifiTransfer(call.arguments as? [String: Any], result: result)
    case "beginWifiAttempt":
      driver.beginWifiAttempt(call.arguments as? [String: Any], result: result)
    case "queryWifiSession":
      driver.queryWifiSession(result: result)
    case "settleWifiRecovery":
      driver.settleWifiRecovery(call.arguments as? [String: Any], result: result)
    case "recoverWifiDownload":
      driver.recoverWifiDownload(call.arguments as? [String: Any], result: result)
    case "prepareWifiSession":
      driver.prepareWifiSession(call.arguments as? [String: Any], result: result)
    case "verifyWifiHandoff":
      driver.verifyWifiHandoff(call.arguments as? [String: Any], result: result)
    case "joinWifiNetwork":
      driver.joinWifiNetwork(call.arguments as? [String: Any], result: result)
    case "openWifiSession":
      driver.openWifiSession(call.arguments as? [String: Any], result: result)
    case "downloadFileInWifiSession":
      driver.downloadFileInWifiSession(call.arguments as? [String: Any], result: result)
    case "closeWifiSession":
      driver.closeWifiSession(call.arguments as? [String: Any], result: result)
    case "cancelWifiSession":
      driver.cancelWifiSession(call.arguments as? [String: Any], result: result)
    case "downloadFileOverWifi":
      driver.downloadFileOverWifi(call.arguments as? [String: Any], result: result)
    case "unbindDevice":
      let args = call.arguments as? [String: Any]
      driver.unbindDevice(
        bindingTokenHex: args?["bindingToken"] as? String,
        deleteDeviceFiles: args?["deleteDeviceFiles"] as? Bool ?? false,
        result: result
      )
    case "disconnect":
      driver.disconnect(result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

private enum RecordingCardBleCommand: Int {
  case getSerial = 0x01
  case getBindingInfo = 0x02
  case bindDevice = 0x03
  case setTime = 0x04
  case getDeviceInfo = 0x05
  case startRecording = 0x06
  case stopRecording = 0x07
  case pauseRecording = 0x08
  case resumeRecording = 0x09
  case listFiles = 0x0A
  case requestFile = 0x0B
  case stopFileTransfer = 0x0C
  case deleteFile = 0x0D
  case deviceStatusChanged = 0x0F
  case getRecordingInfo = 0x15
  case setPhoneType = 0x18
  case enableWifi = 0x1B
  case wifiCredentials = 0x1F
  case setBluetoothName = 0x3A
}

private final class RecordingCardBleDriver: NSObject, RecordingCardCentralDelegate,
  RecordingCardPeripheralDelegate
{
  private static let serviceUuid = CBUUID(string: "E5E0")
  private static let writeUuid = CBUUID(string: "E5E1")
  private static let controlNotifyUuid = CBUUID(string: "E5E2")
  private static let realtimeNotifyUuid = CBUUID(string: "E5E3")
  private static let offlineNotifyUuid = CBUUID(string: "E5E4")
  private static let maxPreAckBytes = 512 * 1024
  private static let downloadInactivityTimeout: TimeInterval = 30
  private static let downloadOverallMinimum: TimeInterval = 5 * 60
  private static let downloadOverallMaximum: TimeInterval = 30 * 60
  private static let wifiProgressPublishInterval: TimeInterval = 0.25
  private static let wifiBleRecoveryBackgroundTimeout: TimeInterval = 20
  private static let wifiTerminalDisableWindow: TimeInterval = 0.4
  private static let wifiTerminalDisableDispatchPoll: TimeInterval = 0.05
  private static let handshakeWriteDrainInterval: TimeInterval = 0.05
  private static let bindingInfoRetryDelay: TimeInterval = 1
  private static let restoredTransportResetPollInterval: TimeInterval = 0.1
  private static let restoredTransportResetPollWindow: TimeInterval = 1
  private static let restoredTransportLateCallbackDrain: TimeInterval = 0.25
  private static let legacyBindingToken = Array("HHFW920TEST00010".utf8)

  var onEvent: (([String: Any]) -> Void)?

  private lazy var central = RecordingCardCentral(
    delegate: self,
    queue: .main,
    options: [
      CBCentralManagerOptionRestoreIdentifierKey:
        "com.hangzhouchuda.huahuoai.recording-card-central"
    ]
  )
  private var peripheral: RecordingCardPeripheral?
  private var activeBleConnectStartedAt: CFAbsoluteTime?
  private var activeBleNativeConnectionConfirmed = false
  private var writeCharacteristic: RecordingCardCharacteristic?
  private var controlNotifyCharacteristic: RecordingCardCharacteristic?
  private var realtimeNotifyCharacteristic: RecordingCardCharacteristic?
  private var offlineNotifyCharacteristic: RecordingCardCharacteristic?
  private var connectResult: FlutterResult?
  private var scanResult: FlutterResult?
  private var connectTimer: Timer?
  private var connectionAttempt = RecordingCardConnectionAttempt()
  private var handshake = RecordingCardHandshakeGuard()
  private var bindingSendTimer: Timer?
  private var bindingInfoRetryTimer: Timer?
  private var bindingInfoRetryDueUptime: TimeInterval?
  private var bindingInfoRetryGeneration = 0
  private var handshakeWriteDrainTimer: Timer?
  private var handshakeWriteDrainGeneration = 0
  private var handshakeCommand: RecordingCardBleCommand?
  private var scanTimer: Timer?
  private var scanOwner = RecordingCardBleScanOwner.none
  private var requestedFingerprint: String?
  private var requestedBindingToken: [UInt8]?
  private var requestedExpectedSerialNumber: String?
  private var commandTimers: [Int: Timer] = [:]
  private var pendingCommands: [Int: PendingCommand] = [:]
  private var queuedWritesWithoutResponse: [QueuedWriteWithoutResponse] = []
  private var commandRequestCounter: UInt64 = 0
  private var transportGeneration: UInt64 = 0
  private var discoveredPeripherals: [String: RecordingCardPeripheral] = [:]
  private var discoveredDevices: [String: [String: Any]] = [:]
  private var manufacturerScanDiagnosticShapes = Set<String>()
  private var pendingNotificationUUIDs = Set<CBUUID>()
  private var readyNotificationUUIDs = Set<CBUUID>()
  private var decoder = RecordingCardFrameDecoder()

  private var deviceName: String?
  private var safeFingerprint: String?
  private var connectionState = "disconnected"
  private var connectionStage = "idle"
  private var statusMessage: String?
  private var permissionProblem: String?
  private var batteryPercent: Int?
  private var storageTotalBytes: Int?
  private var storageFreeBytes: Int?
  private var storageUsedBytes: Int?
  private var firmwareVersion: String?
  private var deviceModel: String?
  private var recordingFormat = "unknown"
  private var recordingState = "idle"
  private var recordingClock = RecordingCardRecordingClock()
  private var currentFileName: String?
  private var currentFileSizeBytes: Int?
  private var currentRecordingType: Int?
  private var lastCompletedFileName: String?
  private var lastCompletedFileSizeBytes: Int?
  private var lastCompletedRecordingType: Int?
  private var lastCompletedFileNeedsSync: Bool?
  private var recordingRevision = 0
  private var recordingObservationSource = "runtimeSnapshot"
  private var recordingObservedAt = isoNow()
  private var files: [[String: Any]] = []
  private var fileRows: [[String: Any]] = []
  private var offlineCapture: OfflineCapture?
  private var offlineInactivityTimer: Timer?
  private var wifiSupported: Bool?
  private var wifiFirmwareVersion: String?
  private var pendingWifiCredentials: WifiCredentials?
  private var pendingWifiCredentialTransportGeneration: UInt64?
  private var pendingWifiCredentialFingerprint: String?
  private var acceptsUnsolicitedWifiCredentials = false
  private var wifiPrepareResult: FlutterResult?
  private var wifiPreparationAcknowledged = false
  private var wifiHotspotEnableMayHaveBeenDispatched = false
  private var wifiHotspotDisableInFlight = false
  private var wifiHotspotDisableSettlements: [() -> Void] = []
  private var wifiHotspotDisableGeneration: UInt64 = 0
  private var wifiHotspotDisableDispatchTimer: Timer?
  private var wifiHotspotDisableSettlementTimer: Timer?
  private var wifiHotspotDisableDispatchDeadlineUptime: TimeInterval?
  private var wifiHotspotDisableDidDispatch = false
  private var wifiHotspotDisableControlFrameObserved = false
  private var wifiPreparationGeneration = 0
  private var wifiCredentialTimer: Timer?
  private let wifiTransferQueue = DispatchQueue(label: "huahuoai.recording-card.wifi-transfer")
  private var wifiRecoveryBatchId: String?
  private var wifiAttemptId: String?
  private var wifiAttemptOwnershipActive = false
  private var wifiInterruptionCode: String?
  private var wifiBackgroundGeneration: UInt64 = 0
  private var wifiBackgroundLease: RecordingCardWifiBackgroundLease?
  private var wifiDownload: WifiTcpDownload?
  private var wifiSessionActiveOnMain = false
  private var wifiSessionIdOnMain: String?
  private var wifiSessionOperationInFlightOnMain = false
  private var wifiTransferProgressOnMain: [String: Any]?
  private var wifiBleDisconnectExpected = false
  private var wifiHandoffReady = false
  private var wifiJoinInProgress = false
  private var wifiJoinGeneration = 0
  private var wifiJoiningSSID: String?
  private var joinedWifiSSID: String?
  private var unbindInProgress = false
  private var unbindDisconnectExpectedID: UUID?
  private var forceScanDisconnectExpectedID: UUID?
  // CoreBluetooth may restore an OS-level connection before this bridge has
  // verified its service, CCCDs, and handshake. Keep it separate from the
  // active transport until it is explicitly disconnected.
  private var restoredStalePeripherals: [UUID: RecordingCardPeripheral] = [:]
  private var restoredTransportDisconnectExpectedIDs = Set<UUID>()
  private var restoredTransportResetPollTimer: Timer?
  private var restoredTransportResetPollGeneration: UInt64 = 0
  private var restoredTransportResetPollDeadlineUptime: TimeInterval?
  private var restoredTransportDrainTimers: [UUID: Timer] = [:]
  private var restoredTransportDrainTickets: [UUID: UInt64] = [:]
  private var restoredTransportDrainTicketCounter: UInt64 = 0
  private var restoredTransportLateCallbackPeripherals: [UUID: RecordingCardPeripheral] = [:]
  private var lastInfoRefreshedAt: String?
  private let transientHandshakeIdentity = RecordingCardTransientHandshakeIdentity()

  func scanDevices(result: @escaping FlutterResult) {
    guard !unbindInProgress else {
      result(error("RECORDING_CARD_UNBIND_IN_PROGRESS", "Recording-card unbind is in progress."))
      return
    }
    if scanResult != nil {
      result(error("RECORDING_CARD_SCAN_IN_PROGRESS", "Recording-card scan is already running."))
      return
    }
    if connectResult != nil {
      result(error("RECORDING_CARD_CONNECT_IN_PROGRESS", "Recording-card connect is already running."))
      return
    }
    scanResult = result
    discoveredDevices.removeAll()
    discoveredPeripherals.removeAll()
    publishSnapshot()
    switch central.state {
    case .poweredOn:
      if resetRestoredBleTransportsForFreshConnection() {
        recordingCardDebugLog("manual scan proceeding while restored BLE transport resets")
      }
      beginManualScan()
    case .unknown, .resetting:
      _ = central
      scanTimer?.invalidate()
      scanTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { [weak self] _ in
        self?.finishScanWithError(
          self?.bluetoothStateError()
            ?? FlutterError(
              code: "RECORDING_CARD_BLUETOOTH_UNAVAILABLE",
              message: "Bluetooth is not ready.",
              details: nil
            )
        )
      }
    default:
      handleBluetoothUnavailableState()
    }
  }

  func cancelDiscovery(result: @escaping FlutterResult) {
    guard scanResult != nil else {
      result(false)
      return
    }
    scanTimer?.invalidate()
    scanTimer = nil
    stopActiveScan()
    cancelPendingScanForExplicitDisconnect()
    publishSnapshot()
    result(true)
  }

  func connect(
    safeDeviceFingerprint: String?,
    expectedSerialNumber: String?,
    bindingTokenHex: String?,
    forceScan: Bool,
    timeoutMs: Int?,
    result: @escaping FlutterResult
  ) {
    recordingCardDebugLog(
      "connect requested selected=\(safeDeviceFingerprint != nil) forceScan=\(forceScan) timeoutMs=\(timeoutMs ?? 15000)"
    )
    guard !unbindInProgress else {
      endWifiBackgroundRecoveryIfOwned(by: safeDeviceFingerprint)
      result(error("RECORDING_CARD_UNBIND_IN_PROGRESS", "Recording-card unbind is in progress."))
      return
    }
    if connectResult != nil {
      result(error("RECORDING_CARD_CONNECT_IN_PROGRESS", "Recording-card connect is already running."))
      return
    }
    guard let token = bindingTokenBytes(bindingTokenHex) else {
      endWifiBackgroundRecoveryIfOwned(by: safeDeviceFingerprint)
      result(error("RECORDING_CARD_BINDING_TOKEN_INVALID", "Recording-card binding token is invalid."))
      return
    }
    let normalizedExpectedSerial: String?
    if let expectedSerialNumber {
      guard let normalized = recordingCardNormalizedOwnershipSerial(expectedSerialNumber) else {
        endWifiBackgroundRecoveryIfOwned(by: safeDeviceFingerprint)
        result(error("RECORDING_CARD_ADVERTISEMENT_SN_INVALID", "Recording-card advertisement serial number is invalid."))
        return
      }
      normalizedExpectedSerial = normalized
    } else {
      normalizedExpectedSerial = nil
    }
    if isReady, !forceScan {
      if recordingCardCanReuseConnection(
        requestedFingerprint: safeDeviceFingerprint,
        activeFingerprint: safeFingerprint,
        expectedSerial: normalizedExpectedSerial,
        actualSerial: transientHandshakeIdentity.serialNumber
      ) {
        result(baseDeviceMap())
      } else {
        endWifiBackgroundRecoveryIfOwned(by: safeDeviceFingerprint)
        result(error("RECORDING_CARD_CONNECT_BUSY", "Disconnect the current recording card before selecting another."))
      }
      return
    }
    if let scanResult {
      scanTimer?.invalidate()
      scanTimer = nil
      self.scanResult = nil
      stopActiveScan()
      scanResult(["devices": Array(discoveredDevices.values)])
    }
    if forceScan,
      recordingState != "idle" || !pendingCommands.isEmpty || !commandTimers.isEmpty
        || !queuedWritesWithoutResponse.isEmpty || offlineCapture != nil
        || wifiSessionActiveOnMain || wifiPrepareResult != nil
    {
      endWifiBackgroundRecoveryIfOwned(by: safeDeviceFingerprint)
      result(error("RECORDING_CARD_FORCE_SCAN_BUSY", "Finish the active recording-card operation before reconnecting."))
      return
    }
    if recordingCardBluetoothConnectionPreflight(central.state) == .reject {
      updateBluetoothPermissionProblem()
      let bluetoothError = bluetoothStateError()
      publishBluetoothUnavailableState()
      endWifiBackgroundRecoveryIfOwned(by: safeDeviceFingerprint)
      result(bluetoothError)
      return
    }
    resetHandshake()
    connectResult = result
    transientHandshakeIdentity.clear()
    clearWifiCredentialLease()
    acceptsUnsolicitedWifiCredentials = false
    wifiBleDisconnectExpected = false
    wifiHandoffReady = false
    requestedFingerprint = safeDeviceFingerprint
    requestedBindingToken = token
    requestedExpectedSerialNumber = normalizedExpectedSerial
    let restoredTransportResetPending = resetRestoredBleTransportsForFreshConnection()
    var awaitingActiveTransportReset = false
    if forceScan {
      awaitingActiveTransportReset = resetBleTransportForForceScan()
      discoveredPeripherals.removeAll()
      discoveredDevices.removeAll()
      publishSnapshot()
    }
    awaitingActiveTransportReset = awaitingActiveTransportReset
      || forceScanDisconnectExpectedID != nil
    publishConnection(state: "connecting", stage: "searching", message: "正在搜索录音卡")
    let timeout = TimeInterval(max(3000, min(timeoutMs ?? 15000, 60000))) / 1000.0
    scheduleConnectionDeadline(timeout: timeout)
    if central.state == .poweredOn {
      if awaitingActiveTransportReset {
        publishConnection(state: "connecting", stage: "connecting", message: "正在重置旧录音卡连接")
        recordingCardDebugLog("fresh connect awaiting BLE transport reset")
        return
      }
      if restoredTransportResetPending {
        recordingCardDebugLog("fresh connect scan proceeding while restored BLE transport resets")
      }
      let cached = safeDeviceFingerprint.flatMap { discoveredPeripherals[$0] }
      if recordingCardShouldReuseCachedPeripheral(
        forceScan: forceScan,
        hasCachedPeripheral: cached != nil
      ), let safeDeviceFingerprint, let cached,
        !isRestoredStaleTransport(cached)
      {
        let name = recordingCardCachedPeripheralDisplayName(
          scannedDisplayName: discoveredDevices[safeDeviceFingerprint]?["displayName"] as? String,
          peripheralName: cached.name
        )
        connectPeripheral(cached, name: name, fingerprint: safeDeviceFingerprint)
      } else {
        startScan()
      }
    }
  }

  func deviceStateMap() -> [String: Any] {
    baseDeviceMap()
  }

  func refreshDeviceInfo(result: @escaping FlutterResult) {
    guard isReady else {
      result(error("RECORDING_CARD_NOT_CONNECTED", "Recording card is not connected."))
      return
    }
    let requestRevision = recordingRevision
    sendCommand(.getDeviceInfo, result: result) { [weak self] payload in
      guard let self else { return [:] }
      let applyRecordingState = shouldApplyRecordingCardStateResponse(
        requestRevision: requestRevision,
        currentRevision: self.recordingRevision
      )
      self.applyDeviceInfo(payload, applyRecordingState: applyRecordingState)
      if !applyRecordingState {
        recordingCardDebugLog("ignored stale device-info recording state")
      }
      return self.runtimeSnapshotMap()
    }
  }

  func readAccountBindingClaim(result: @escaping FlutterResult) {
    guard isReady else {
      result(error("RECORDING_CARD_NOT_CONNECTED", "Recording card is not connected."))
      return
    }
    if let serialNumber = transientHandshakeIdentity.serialNumber,
      let opaqueClaim = recordingCardOpaqueAccountClaim(
        serialPayload: Array(serialNumber.utf8)
      )
    {
      recordingCardDebugLog("account binding claim reused handshake identity")
      result(["opaqueClaim": opaqueClaim])
      return
    }
    _ = sendCommand(.getSerial, result: result) { payload in
      guard let claim = recordingCardOpaqueAccountClaim(serialPayload: payload) else {
        throw RecordingCardCommandError.failedAck
      }
      return ["opaqueClaim": claim]
    }
  }

  func readAccountBindingIdentity(result: @escaping FlutterResult) {
    guard isReady else {
      result(error("RECORDING_CARD_NOT_CONNECTED", "Recording card is not connected."))
      return
    }
    if let serialNumber = transientHandshakeIdentity.serialNumber {
      recordingCardDebugLog("account binding identity reused from handshake")
      result(["serialNumber": serialNumber])
      return
    }
    _ = sendCommand(.getSerial, result: result) { [weak self] payload in
      guard let serialNumber = recordingCardSerialNumber(serialPayload: payload) else {
        throw RecordingCardCommandError.failedAck
      }
      _ = self?.transientHandshakeIdentity.capture(serialPayload: payload)
      return ["serialNumber": serialNumber]
    }
  }

  func signAccountBindingChallenge(result: @escaping FlutterResult) {
    guard isReady else {
      result(error("RECORDING_CARD_NOT_CONNECTED", "Recording card is not connected."))
      return
    }
    result(
      error(
        "RECORDING_CARD_ATTESTATION_UNSUPPORTED",
        "The connected recording-card firmware does not expose a challenge-signing command."
      )
    )
  }

  func setBluetoothName(
    bluetoothName: String?,
    result: @escaping FlutterResult
  ) {
    guard isReady else {
      result(error("RECORDING_CARD_NOT_CONNECTED", "Recording card is not connected."))
      return
    }
    guard let bluetoothName,
      let payload = recordingCardBluetoothNamePayload(bluetoothName)
    else {
      result(
        error(
          "RECORDING_CARD_BLUETOOTH_NAME_INVALID",
          "Bluetooth name must contain 1 to 32 UTF-8 bytes, non-whitespace text, and no control characters."
        )
      )
      return
    }

    _ = sendCommand(
      .setBluetoothName,
      payload: payload,
      result: { [weak self] response in
        guard let self else {
          result(
            FlutterError(
              code: "RECORDING_CARD_BLUETOOTH_NAME_RESPONSE_INVALID",
              message: "Recording-card Bluetooth-name response was invalid.",
              details: nil
            )
          )
          return
        }
        if let failure = response as? FlutterError {
          result(failure)
          return
        }
        guard response as? Bool == true else {
          result(
            self.error(
              "RECORDING_CARD_BLUETOOTH_NAME_RESPONSE_INVALID",
              "Recording-card Bluetooth-name response was invalid."
            )
          )
          return
        }
        self.deviceName = bluetoothName
        self.publishSnapshot()
        result(self.baseDeviceMap())
      }
    ) { payload in
      switch recordingCardBluetoothNameAck(payload) {
      case .accepted:
        return true
      case .rejected:
        return FlutterError(
          code: "RECORDING_CARD_BLUETOOTH_NAME_REJECTED",
          message: "Recording card rejected the Bluetooth-name change.",
          details: nil
        )
      case .invalid:
        return FlutterError(
          code: "RECORDING_CARD_BLUETOOTH_NAME_RESPONSE_INVALID",
          message: "Recording-card Bluetooth-name response was invalid.",
          details: nil
        )
      }
    }
  }

  func readRecordingState(result: @escaping FlutterResult) {
    guard isReady else {
      result(error("RECORDING_CARD_NOT_CONNECTED", "Recording card is not connected."))
      return
    }
    let requestRevision = recordingRevision
    sendCommand(.getRecordingInfo, result: result) { [weak self] payload in
      guard let self else { return ["state": "idle"] }
      let applyRecordingState = shouldApplyRecordingCardStateResponse(
        requestRevision: requestRevision,
        currentRevision: self.recordingRevision
      )
      if applyRecordingState {
        self.applyRecordingInfo(payload)
      } else {
        recordingCardDebugLog("ignored stale recording-info response")
      }
      return self.recordingInfoMap()
    }
  }

  func recordingCommand(_ command: RecordingCardBleCommand, result: @escaping FlutterResult) {
    guard isReady else {
      result(error("RECORDING_CARD_NOT_CONNECTED", "Recording card is not connected."))
      return
    }
    sendCommand(command, result: result) { [weak self] payload in
      guard let parsed = recordingCardRecordingCommandPayload(
        command: UInt8(command.rawValue),
        payload: payload
      ) else {
        throw RecordingCardCommandError.failedAck
      }
      self?.applyRecordingPayload(parsed, source: "command")
      self?.publishRecording()
      return self?.recordingInfoMap() ?? ["state": "idle"]
    }
  }

  func scanFiles(result: @escaping FlutterResult) {
    guard isReady else {
      result(error("RECORDING_CARD_NOT_CONNECTED", "Recording card is not connected."))
      return
    }
    fileRows = []
    publishSnapshot()
    sendCommand(.listFiles, result: result, timeoutSeconds: 12) { [weak self] payload in
      guard let self else { return ["files": []] }
      if payload.first == 0x02 {
        self.files = self.fileRows
        self.publishSnapshot()
        return ["files": self.files]
      }
      if let row = self.parseFileRow(payload) {
        self.fileRows.append(row)
      }
      return ["files": self.fileRows]
    }
  }

  func downloadFile(_ args: [String: Any]?, result: @escaping FlutterResult) {
    guard isReady else {
      result(error("RECORDING_CARD_NOT_CONNECTED", "Recording card is not connected."))
      return
    }
    guard offlineNotifyCharacteristic?.isNotifying == true else {
      result(
        error(
          "RECORDING_CARD_OFFLINE_TRANSFER_UNAVAILABLE",
          "Recording-card offline transfer notifications are unavailable."
        )
      )
      return
    }
    guard offlineCapture == nil, !wifiSessionActiveOnMain else {
      result(
        error(
          "RECORDING_CARD_DOWNLOAD_IN_PROGRESS",
          "A recording-card file download is already running."
        )
      )
      return
    }
    guard let request = parseDownloadRequest(args) else {
      result(
        error(
          "RECORDING_CARD_INVALID_FILE",
          "Recording-card file payload is invalid."
        )
      )
      return
    }
    guard let requestPayload = recordingCardFileRequestPayload(
      request.deviceFilename,
      seekOffset: 0
    ) else {
      result(error("RECORDING_CARD_INVALID_FILE", "Recording-card file payload is invalid."))
      return
    }

    let plannedNativeFileId = args?["plannedNativeFileId"] as? String
    guard let capture = createOfflineCapture(
      request,
      plannedNativeFileId: plannedNativeFileId
    ) else {
      result(error("RECORDING_CARD_LOCAL_STORAGE_FAILED", "Recording-card download could not prepare private storage."))
      return
    }
    offlineCapture = capture
    let queued = sendCommand(
      .requestFile,
      payload: requestPayload,
      result: result
    ) { [weak self] payload in
      guard let self else {
        throw FileRequestFailure(
          code: "RECORDING_CARD_FILE_REQUEST_STATE_LOST",
          safeMessage: "Recording-card file capture state was lost."
        )
      }
      let acknowledgedSize = try self.resolveAcknowledgedSize(payload, request: request)
      guard let capture = self.offlineCapture else {
        throw FileRequestFailure(
          code: "RECORDING_CARD_FILE_REQUEST_STATE_LOST",
          safeMessage: "Recording-card file capture state was lost."
        )
      }
      capture.request = request.withTargetBytes(acknowledgedSize)
      capture.directorySizeMismatch = request.directorySizeBytes != nil
        && request.directorySizeBytes != acknowledgedSize
      capture.acknowledged = true
      recordingCardDebugLog(
        "ble file acknowledgement resolved id=\(capture.correlationID) targetBytes=\(capture.request.targetBytes) acceptedBytes=\(capture.receivedBytes) errorCode=none"
      )
      self.scheduleDownloadTimeouts(sizeBytes: capture.request.targetBytes)
      self.publishTransferProgress(capture, force: true)
      let earlyChunks = capture.preAckChunks
      capture.preAckChunks.removeAll()
      capture.preAckBytes = 0
      for chunk in earlyChunks {
        self.appendOfflineData(chunk)
      }
      return [:]
    }
    if !queued { cleanupOfflineCapture(deletePart: true) }
  }

  private func resolveAcknowledgedSize(
    _ payload: [UInt8],
    request: DownloadRequest
  ) throws -> Int {
    guard let status = payload.first else {
      throw FileRequestFailure(
        code: "RECORDING_CARD_FILE_REQUEST_ACK_MALFORMED",
        safeMessage: "Recording-card file request acknowledgement was malformed."
      )
    }
    guard status == 0x00 else {
      throw FileRequestFailure(
        code: "RECORDING_CARD_FILE_REQUEST_REJECTED",
        safeMessage: "Recording-card file request was rejected."
      )
    }
    if payload.count == 1 {
      guard let directorySize = request.directorySizeBytes,
        isValidDeviceFileSize(directorySize)
      else {
        throw FileRequestFailure(
          code: "RECORDING_CARD_FILE_REQUEST_LENGTH_UNAVAILABLE",
          safeMessage: "Recording-card file length is unavailable."
        )
      }
      return directorySize
    }
    guard payload.count >= 5 else {
      throw FileRequestFailure(
        code: "RECORDING_CARD_FILE_REQUEST_ACK_MALFORMED",
        safeMessage: "Recording-card file request acknowledgement was malformed."
      )
    }
    guard let acknowledgedSize = recordingCardAcknowledgedFileSize(
      payload: payload,
      directorySizeBytes: nil
    ) else {
      throw FileRequestFailure(
        code: "RECORDING_CARD_FILE_REQUEST_LENGTH_UNAVAILABLE",
        safeMessage: "Recording-card file length is unavailable."
      )
    }
    if request.sizeConfidence == "trusted",
      let directorySizeBytes = request.directorySizeBytes,
      directorySizeBytes != acknowledgedSize
    {
      throw FileRequestFailure(
        code: "RECORDING_CARD_FILE_REQUEST_LENGTH_MISMATCH",
        safeMessage: "Recording-card file length did not match the fresh directory."
      )
    }
    return acknowledgedSize
  }

  func cancelFileTransfer(result: @escaping FlutterResult) {
    if offlineCapture != nil,
      pendingCommands[RecordingCardBleCommand.requestFile.rawValue] != nil
    {
      failOfflineCapture(
        code: "RECORDING_CARD_TRANSFER_CANCELLED",
        message: "Recording-card file transfer was cancelled."
      )
      result(["cancelled": true])
      return
    }
    if wifiSessionActiveOnMain || wifiPrepareResult != nil || wifiHotspotDisableInFlight {
      cancelWifiSession(nil, result: result)
      return
    }
    result(error("RECORDING_CARD_TRANSFER_NOT_ACTIVE", "No recording-card transfer is active."))
  }

  func prepareWifiTransfer(_ args: [String: Any]?, result: @escaping FlutterResult) {
    guard recordingCardLegacyWifiOperationCanBegin(
      scopedAttemptOwned: wifiAttemptOwnershipActive
    ) else {
      result(error(
        "RECORDING_CARD_WIFI_SESSION_BUSY",
        "A recovery-owned recording-card Wi-Fi session is active."
      ))
      return
    }
    prepareWifiTransferForCurrentOwner(args, result: result)
  }

  private func prepareWifiTransferForCurrentOwner(
    _ args: [String: Any]?,
    result: @escaping FlutterResult
  ) {
    guard !unbindInProgress else {
      result(error("RECORDING_CARD_UNBIND_IN_PROGRESS", "Recording-card unbind is in progress."))
      return
    }
    guard isReady else {
      result(error("RECORDING_CARD_NOT_CONNECTED", "Recording card is not connected."))
      return
    }
    guard wifiSupported != false else {
      result(error("RECORDING_CARD_WIFI_UNAVAILABLE", "Recording-card firmware does not advertise Wi-Fi transfer."))
      return
    }
    guard wifiPrepareResult == nil, !wifiHotspotDisableInFlight else {
      result(error("RECORDING_CARD_WIFI_PREPARE_IN_PROGRESS", "Recording-card Wi-Fi preparation is already running."))
      return
    }
    guard let filename = args?["deviceFilename"] as? String, isSafeFilename(filename) else {
      result(error("RECORDING_CARD_INVALID_FILE", "Recording-card file payload is invalid."))
      return
    }
    ensureWifiBackgroundExecution(
      batchId: wifiAttemptOwnershipActive ? wifiRecoveryBatchId : nil,
      attemptId: wifiAttemptOwnershipActive ? wifiAttemptId : nil,
      ownerFingerprint: safeFingerprint
    )
    recordingCardDebugLog(
      "wifi prepare requested cachedCredentials=\(pendingWifiCredentials != nil)"
    )
    discardWifiCredentialLeaseUnlessCurrent()
    wifiPreparationAcknowledged = false
    wifiHotspotEnableMayHaveBeenDispatched = false
    wifiBleDisconnectExpected = false
    wifiHandoffReady = false
    wifiPreparationGeneration &+= 1
    let preparationGeneration = wifiPreparationGeneration
    wifiPrepareResult = result
    sendWifiEnable(
      allowResetRecovery: true,
      preparationGeneration: preparationGeneration
    )
  }

  func prepareWifiSession(_ args: [String: Any]?, result: @escaping FlutterResult) {
    guard acceptsWifiAttempt(args) else {
      result(error(
        "RECORDING_CARD_WIFI_ATTEMPT_SUPERSEDED",
        "Wi-Fi attempt no longer owns preparation."
      ))
      return
    }
    guard let rows = args?["files"] as? [[String: Any]],
      !rows.isEmpty,
      rows.allSatisfy({ parseDownloadRequest($0) != nil })
    else {
      result(error("RECORDING_CARD_INVALID_FILE", "Recording-card Wi-Fi batch payload is invalid."))
      return
    }
    prepareWifiTransferForCurrentOwner(rows[0], result: result)
  }

  func joinWifiNetwork(_ args: [String: Any]?, result: @escaping FlutterResult) {
    guard acceptsWifiAttempt(args) else {
      result(error(
        "RECORDING_CARD_WIFI_ATTEMPT_SUPERSEDED",
        "Wi-Fi attempt no longer owns network joining."
      ))
      return
    }
    guard !wifiJoinInProgress else {
      result(error("RECORDING_CARD_WIFI_JOIN_IN_PROGRESS", "A recording-card Wi-Fi join is already active."))
      return
    }
    guard wifiHandoffReady,
      let credentials = pendingWifiCredentials,
      let ssid = args?["ssid"] as? String,
      let password = args?["password"] as? String,
      ssid == credentials.ssid,
      password == credentials.password
    else {
      result(error("RECORDING_CARD_WIFI_CREDENTIALS_INVALID", "Recording-card Wi-Fi credentials are invalid."))
      return
    }
    if joinedWifiSSID == ssid {
      result(true)
      return
    }
    wifiJoinInProgress = true
    wifiJoiningSSID = ssid
    let joinGeneration = wifiJoinGeneration
    let configuration = NEHotspotConfiguration(
      ssid: ssid,
      passphrase: password,
      isWEP: false
    )
    configuration.joinOnce = true
    NEHotspotConfigurationManager.shared.apply(configuration) { [weak self] joinError in
      DispatchQueue.main.async {
        guard let self else {
          result(FlutterError(
            code: "RECORDING_CARD_WIFI_JOIN_FAILED",
            message: "Recording-card Wi-Fi join could not complete.",
            details: nil
          ))
          return
        }
        guard recordingCardWifiJoinCallbackAction(
          capturedGeneration: joinGeneration,
          currentGeneration: self.wifiJoinGeneration,
          handoffReady: self.wifiHandoffReady
        ) == .accept else {
          let ownsCurrentJoin = joinGeneration == self.wifiJoinGeneration
          if ownsCurrentJoin {
            self.wifiJoinInProgress = false
            self.wifiJoiningSSID = nil
          }
          if recordingCardWifiJoinCallbackShouldRemoveConfiguration(
            capturedGeneration: joinGeneration,
            currentGeneration: self.wifiJoinGeneration,
            callbackSSID: ssid,
            currentJoiningSSID: self.wifiJoiningSSID,
            currentJoinedSSID: self.joinedWifiSSID
          ) {
            NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
          }
          result(self.error(
            "RECORDING_CARD_WIFI_JOIN_CANCELLED",
            "Recording-card Wi-Fi join was cancelled."
          ))
          return
        }
        self.wifiJoinInProgress = false
        self.wifiJoiningSSID = nil
        if let joinError {
          let nativeError = joinError as NSError
          if nativeError.domain == NEHotspotConfigurationErrorDomain,
            nativeError.code == NEHotspotConfigurationError.alreadyAssociated.rawValue
          {
            self.joinedWifiSSID = ssid
            result(true)
            return
          }
          let code = nativeError.domain == NEHotspotConfigurationErrorDomain &&
            nativeError.code == NEHotspotConfigurationError.userDenied.rawValue
            ? "RECORDING_CARD_WIFI_JOIN_DENIED"
            : "RECORDING_CARD_WIFI_JOIN_FAILED"
          result(self.error(code, "Recording-card Wi-Fi join was not allowed."))
          return
        }
        self.joinedWifiSSID = ssid
        result(true)
      }
    }
  }

  private func sendWifiEnable(
    allowResetRecovery: Bool,
    preparationGeneration: Int
  ) {
    guard ownsWifiPreparation(preparationGeneration) else { return }
    recordingCardDebugLog(
      "wifi enable attempt resetRecoveryAllowed=\(allowResetRecovery)"
    )
    sendCommand(
      .enableWifi,
      payload: [0x01],
      result: { [weak self] response in
      guard let self, self.ownsWifiPreparation(preparationGeneration) else { return }
      if let failure = response as? FlutterError {
        if failure.code == "RECORDING_CARD_COMMAND_REJECTED" {
          self.wifiHotspotEnableMayHaveBeenDispatched =
            recordingCardWifiHotspotMayBeEnabled(
              current: self.wifiHotspotEnableMayHaveBeenDispatched,
              event: .enableRejected
            )
        }
        if allowResetRecovery {
          self.beginWifiResetRecovery(preparationGeneration: preparationGeneration)
        } else {
          self.finishWifiPreparation(
            errorCode: "RECORDING_CARD_WIFI_FIRMWARE_INCOMPATIBLE",
            expectedGeneration: preparationGeneration
          )
        }
        return
      }
      self.wifiPreparationAcknowledged = true
      self.wifiBleDisconnectExpected = true
      recordingCardDebugLog("wifi enable acknowledged")
      self.scheduleWifiCredentialTimeout(preparationGeneration: preparationGeneration)
      self.finishWifiPreparationIfPossible(expectedGeneration: preparationGeneration)
      },
      timeoutSeconds: 8,
      onFirstDispatch: { [weak self] ownership, _ in
        guard let self, self.ownsWifiPreparation(preparationGeneration),
          ownership.transportGeneration == self.transportGeneration
        else { return }
        self.wifiHotspotEnableMayHaveBeenDispatched =
          recordingCardWifiHotspotMayBeEnabled(
            current: self.wifiHotspotEnableMayHaveBeenDispatched,
            event: .enableDispatched
          )
      }
    ) { payload in
        guard payload.first == 0x00 else { throw RecordingCardCommandError.failedAck }
        return true
      }
  }

  private func beginWifiResetRecovery(preparationGeneration: Int) {
    guard ownsWifiPreparation(preparationGeneration), isReady else {
      finishWifiPreparation(
        errorCode: "RECORDING_CARD_WIFI_DISCONNECTED",
        expectedGeneration: preparationGeneration
      )
      return
    }
    recordingCardDebugLog(
      "wifi reset recovery started firmware=\(firmwareVersion ?? "unknown")"
    )
    sendCommand(
      .enableWifi,
      payload: [0x00],
      result: { [weak self] response in
        guard let self, self.ownsWifiPreparation(preparationGeneration) else { return }
        guard !(response is FlutterError) else {
          self.finishWifiPreparation(
            errorCode: "RECORDING_CARD_WIFI_FIRMWARE_INCOMPATIBLE",
            expectedGeneration: preparationGeneration
          )
          return
        }
        self.wifiHotspotEnableMayHaveBeenDispatched =
          recordingCardWifiHotspotMayBeEnabled(
            current: self.wifiHotspotEnableMayHaveBeenDispatched,
            event: .resetAccepted
          )
        recordingCardDebugLog("wifi reset acknowledged")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
          self?.sendWifiEnable(
            allowResetRecovery: false,
            preparationGeneration: preparationGeneration
          )
        }
      },
      timeoutSeconds: 4
    ) { payload in
      guard payload.first == 0x00 else { throw RecordingCardCommandError.failedAck }
      return true
    }
  }

  func verifyWifiHandoff(
    _ args: [String: Any]?,
    result: @escaping FlutterResult
  ) {
    let expectedSSID = pendingWifiCredentials?.ssid
    let verificationGeneration = wifiJoinGeneration
    let verificationBatchId = wifiRecoveryBatchId
    let verificationAttemptId = wifiAttemptId
    guard acceptsWifiAttempt(args) else {
      result(error(
        "RECORDING_CARD_WIFI_ATTEMPT_SUPERSEDED",
        "Wi-Fi attempt no longer owns the session."
      ))
      return
    }
    guard recordingCardWifiHandoffVerificationStatus(
      handoffExpected: wifiHandoffReady,
      expectedSSID: expectedSSID,
      joinedSSID: joinedWifiSSID,
      wifiPathSatisfied: true
    ) == "ready"
    else {
      result(["status": "networkUnavailable"])
      return
    }
    let queue = DispatchQueue(label: "huahuoai.recording-card.wifi-path-check")
    let correlationID = "wifi-check-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    recordingCardDebugLog("wifi handoff check started id=\(correlationID)")
    var completed = false
    let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
    let finish: (String) -> Void = { [weak self] proposedStatus in
      guard !completed else { return }
      completed = true
      monitor.pathUpdateHandler = nil
      monitor.cancel()
      DispatchQueue.main.async {
        guard let self else {
          result(["status": "networkUnavailable"])
          return
        }
        let status = proposedStatus == "ready"
          ? recordingCardWifiHandoffCallbackStatus(
              capturedGeneration: verificationGeneration,
              currentGeneration: self.wifiJoinGeneration,
              capturedBatchId: verificationBatchId,
              currentBatchId: self.wifiRecoveryBatchId,
              capturedAttemptId: verificationAttemptId,
              currentAttemptId: self.wifiAttemptId,
              handoffReady: self.wifiHandoffReady,
              expectedSSID: expectedSSID,
              joinedSSID: self.joinedWifiSSID,
              wifiPathSatisfied: true
            )
          : "networkUnavailable"
        recordingCardDebugLog(
          "wifi handoff check completed id=\(correlationID) status=\(status)"
        )
        result(["status": status])
      }
    }
    monitor.pathUpdateHandler = { path in
      let wifiPathSatisfied = path.status == .satisfied
        && path.usesInterfaceType(.wifi)
      recordingCardDebugLog(
        "wifi handoff path id=\(correlationID) satisfied=\(wifiPathSatisfied)"
      )
      if recordingCardWifiHandoffCallbackStatus(
        capturedGeneration: verificationGeneration,
        currentGeneration: verificationGeneration,
        capturedBatchId: verificationBatchId,
        currentBatchId: verificationBatchId,
        capturedAttemptId: verificationAttemptId,
        currentAttemptId: verificationAttemptId,
        handoffReady: true,
        expectedSSID: expectedSSID,
        joinedSSID: expectedSSID,
        wifiPathSatisfied: wifiPathSatisfied
      ) == "ready" {
        finish("ready")
      }
    }
    monitor.start(queue: queue)
    queue.asyncAfter(deadline: .now() + 3) {
      finish("networkUnavailable")
    }
  }

  func downloadFileOverWifi(_ args: [String: Any]?, result: @escaping FlutterResult) {
    guard recordingCardLegacyWifiOperationCanBegin(
      scopedAttemptOwned: wifiAttemptOwnershipActive
    ) else {
      result(error(
        "RECORDING_CARD_WIFI_SESSION_BUSY",
        "A recovery-owned recording-card Wi-Fi session is active."
      ))
      return
    }
    guard let args else {
      result(error("RECORDING_CARD_INVALID_FILE", "Recording-card file payload is invalid."))
      return
    }
    openWifiSession(["files": [args]], result: { [weak self] opened in
      guard let self else { return }
      if let failure = opened as? FlutterError {
        result(failure)
        return
      }
      self.downloadFileInWifiSession(args, result: { [weak self] downloaded in
        guard let self else { return }
        self.closeWifiSession(nil, result: { _ in result(downloaded) })
      })
    })
  }

  func downloadFileInWifiSession(
    _ args: [String: Any]?,
    result: @escaping FlutterResult
  ) {
    guard acceptsWifiAttempt(args) else {
      result(error(
        "RECORDING_CARD_WIFI_ATTEMPT_SUPERSEDED",
        "Wi-Fi attempt no longer owns the session."
      ))
      return
    }
    guard wifiSessionActiveOnMain, let projectedSessionID = wifiSessionIdOnMain else {
      result(error("RECORDING_CARD_WIFI_SESSION_NOT_OPEN", "Recording-card Wi-Fi session is not open."))
      return
    }
    guard !wifiSessionOperationInFlightOnMain else {
      result(error("RECORDING_CARD_WIFI_DOWNLOAD_IN_PROGRESS", "A recording-card Wi-Fi file download is already running."))
      return
    }
    let attemptScope = wifiAttemptScope(from: args)
    wifiSessionOperationInFlightOnMain = true
    wifiTransferQueue.async { [weak self] in
      guard let self else {
        DispatchQueue.main.async {
          result(FlutterError(
            code: "RECORDING_CARD_WIFI_SESSION_NOT_OPEN",
            message: "Recording-card Wi-Fi session is not open.",
            details: nil
          ))
        }
        return
      }
      guard let transfer = self.wifiDownload,
        transfer.sessionID == projectedSessionID
      else {
        let failure = self.error(
          "RECORDING_CARD_WIFI_SESSION_NOT_OPEN",
          "Recording-card Wi-Fi session is not open."
        )
        self.settleWifiSessionOperationOnMain(sessionID: projectedSessionID) {
          result(failure)
        }
        return
      }
      guard self.wifiAttemptScopeOwnsTransfer(attemptScope, transfer: transfer) else {
        let failure = self.error(
          "RECORDING_CARD_WIFI_ATTEMPT_SUPERSEDED",
          "Wi-Fi attempt no longer owns the session."
        )
        self.settleWifiSessionOperationOnMain(sessionID: projectedSessionID) {
          result(failure)
        }
        return
      }
      guard transfer.readyForFile, !transfer.fileActive, transfer.result == nil else {
        let failure = self.error(
          "RECORDING_CARD_WIFI_DOWNLOAD_IN_PROGRESS",
          "A recording-card Wi-Fi file download is already running."
        )
        self.settleWifiSessionOperationOnMain(sessionID: projectedSessionID) {
          result(failure)
        }
        return
      }
      guard var request = self.parseDownloadRequest(args),
        let directoryRow = transfer.catalogByFilename[request.deviceFilename]
      else {
        let failure = self.error(
          "RECORDING_CARD_WIFI_FILE_NOT_FOUND",
          "The selected recording no longer exists on the recording card."
        )
        self.settleWifiSessionOperationOnMain(sessionID: projectedSessionID) {
          result(failure)
        }
        return
      }
      if args?["sessionId"] != nil,
        safeWifiIdentifier(args?["sessionId"]) != transfer.sessionID
      {
        let failure = self.error(
          "RECORDING_CARD_WIFI_SESSION_MISMATCH",
          "Recording-card Wi-Fi session does not match the active session."
        )
        self.settleWifiSessionOperationOnMain(sessionID: projectedSessionID) {
          result(failure)
        }
        return
      }
      guard let progressContext = self.parseWifiProgressContext(args) else {
        let failure = self.error(
          "RECORDING_CARD_INVALID_FILE",
          "Recording-card Wi-Fi batch context is invalid."
        )
        self.settleWifiSessionOperationOnMain(sessionID: projectedSessionID) {
          result(failure)
        }
        return
      }
      request = request.withDirectorySize(
        directoryRow["sizeBytes"] as? Int,
        confidence: directoryRow["sizeConfidence"] as? String
      )
      try? transfer.capture.output.close()
      try? FileManager.default.removeItem(at: transfer.capture.partURL)
      guard let capture = self.createOfflineCapture(request, plannedNativeFileId: args?["plannedNativeFileId"] as? String) else {
        let failure = self.error(
          "RECORDING_CARD_LOCAL_STORAGE_FAILED",
          "Recording-card download could not prepare private storage."
        )
        self.settleWifiSessionOperationOnMain(sessionID: projectedSessionID) {
          result(failure)
        }
        return
      }
      transfer.capture = capture
      transfer.result = result
      transfer.fileActive = true
      transfer.requestSent = false
      transfer.awaitingStopBoundary = false
      transfer.boundaryFrameObserved = false
      transfer.boundaryWorkItem?.cancel()
      transfer.boundaryWorkItem = nil
      self.cancelWifiPrematureEndGrace(transfer)
      transfer.networkBytesReceived = 0
      transfer.nextNetworkLogBytes = 256 * 1024
      transfer.nextAcceptedLogBytes = 256 * 1024
      transfer.lastProgressPublishUptime = 0
      transfer.rateSampleUptime = ProcessInfo.processInfo.systemUptime
      transfer.rateSampleBytes = 0
      transfer.bytesPerSecond = nil
      transfer.batchID = progressContext.batchID
      transfer.batchFileIndex = progressContext.fileIndex
      transfer.batchFileCount = progressContext.fileCount
      transfer.aggregateReceivedBase = progressContext.aggregateReceivedBase
      transfer.aggregateTotalBytes = progressContext.aggregateTotalBytes
      transfer.tailSeekAttempted = false
      transfer.tailSeekOffset = nil
      transfer.tailSeekAwaitingData = false
      recordingCardDebugLog(
        "wifi session file started id=\(transfer.sessionID) directoryBytes=\(request.directorySizeBytes ?? 0)"
      )
      self.scheduleWifiDownloadTimeout(transfer, seconds: 30)
      self.publishWifiTransferProgress(transfer, force: true)
      self.sendWifiFileRequest(transfer)
    }
  }

  func closeWifiSession(
    _ args: [String: Any]?,
    result: @escaping FlutterResult
  ) {
    guard recordingCardWifiSessionCloseIngressAction(
      operationInFlight: wifiSessionOperationInFlightOnMain
    ) == .beginTerminalCleanup else {
      result(error(
        "RECORDING_CARD_WIFI_SESSION_BUSY",
        "Recording-card Wi-Fi session is processing an operation."
      ))
      return
    }
    guard acceptsWifiAttempt(args) else {
      result(error(
        "RECORDING_CARD_WIFI_ATTEMPT_SUPERSEDED",
        "Wi-Fi attempt no longer owns the session."
      ))
      return
    }
    finishWifiPreparation(
      errorCode: "RECORDING_CARD_WIFI_TRANSFER_CANCELLED",
      disableReadyHotspotIfWritable: true
    ) { [weak self] in
      guard let self else {
        result(true)
        return
      }
      guard self.acceptsWifiAttempt(args) else {
        result(self.error(
          "RECORDING_CARD_WIFI_ATTEMPT_SUPERSEDED",
          "Wi-Fi attempt no longer owns the session."
        ))
        return
      }
      self.continueWifiSessionClose(args, result: result)
    }
  }

  private func continueWifiSessionClose(
    _ args: [String: Any]?,
    result: @escaping FlutterResult
  ) {
    let attemptScope = wifiAttemptScope(from: args)
    wifiTransferQueue.async { [weak self] in
      guard let self else {
        DispatchQueue.main.async { result(true) }
        return
      }
      guard let transfer = self.wifiDownload else {
        DispatchQueue.main.async {
          guard recordingCardWifiAttemptMatches(
            identityProvided: attemptScope.identityProvided,
            capturedBatchId: attemptScope.batchId,
            capturedAttemptId: attemptScope.attemptId,
            currentBatchId: self.wifiRecoveryBatchId,
            currentAttemptId: self.wifiAttemptId,
            currentAttemptOwned: self.wifiAttemptOwnershipActive
          ) else {
            result(self.error(
              "RECORDING_CARD_WIFI_ATTEMPT_SUPERSEDED",
              "Wi-Fi attempt no longer owns the session."
            ))
            return
          }
          self.clearWifiHandoffRuntime(retainBackgroundForBleRecovery: true)
          result(true)
        }
        return
      }
      guard self.wifiAttemptScopeOwnsTransfer(attemptScope, transfer: transfer) else {
        DispatchQueue.main.async {
          result(self.error(
            "RECORDING_CARD_WIFI_ATTEMPT_SUPERSEDED",
            "Wi-Fi attempt no longer owns the session."
          ))
        }
        return
      }
      guard !transfer.fileActive else {
        DispatchQueue.main.async {
          result(self.error("RECORDING_CARD_WIFI_DOWNLOAD_IN_PROGRESS", "Stop the active Wi-Fi transfer before closing its session."))
        }
        return
      }
      let openResult = transfer.openResult
      transfer.openResult = nil
      self.finishWifiSession(transfer, deletePart: true)
      DispatchQueue.main.async {
        openResult?(self.error("RECORDING_CARD_TRANSFER_CANCELLED", "Recording-card Wi-Fi session opening was cancelled."))
        result(true)
      }
    }
  }

  func cancelWifiSession(
    _ args: [String: Any]?,
    result: @escaping FlutterResult
  ) {
    guard acceptsWifiAttempt(args) else {
      result(error(
        "RECORDING_CARD_WIFI_ATTEMPT_SUPERSEDED",
        "Wi-Fi attempt no longer owns the session."
      ))
      return
    }
    finishWifiPreparation(
      errorCode: "RECORDING_CARD_WIFI_TRANSFER_CANCELLED",
      disableReadyHotspotIfWritable: true
    ) { [weak self] in
      guard let self else {
        result(true)
        return
      }
      guard self.acceptsWifiAttempt(args) else {
        result(self.error(
          "RECORDING_CARD_WIFI_ATTEMPT_SUPERSEDED",
          "Wi-Fi attempt no longer owns the session."
        ))
        return
      }
      self.continueWifiSessionCancellation(args, result: result)
    }
  }

  private func continueWifiSessionCancellation(
    _ args: [String: Any]?,
    result: @escaping FlutterResult
  ) {
    let attemptScope = wifiAttemptScope(from: args)
    wifiTransferQueue.async { [weak self] in
      guard let self else {
        DispatchQueue.main.async { result(true) }
        return
      }
      guard let transfer = self.wifiDownload else {
        DispatchQueue.main.async {
          guard recordingCardWifiAttemptMatches(
            identityProvided: attemptScope.identityProvided,
            capturedBatchId: attemptScope.batchId,
            capturedAttemptId: attemptScope.attemptId,
            currentBatchId: self.wifiRecoveryBatchId,
            currentAttemptId: self.wifiAttemptId,
            currentAttemptOwned: self.wifiAttemptOwnershipActive
          ) else {
            result(self.error(
              "RECORDING_CARD_WIFI_ATTEMPT_SUPERSEDED",
              "Wi-Fi attempt no longer owns the session."
            ))
            return
          }
          self.clearWifiHandoffRuntime(retainBackgroundForBleRecovery: true)
          result(true)
        }
        return
      }
      guard self.wifiAttemptScopeOwnsTransfer(attemptScope, transfer: transfer) else {
        DispatchQueue.main.async {
          result(self.error(
            "RECORDING_CARD_WIFI_ATTEMPT_SUPERSEDED",
            "Wi-Fi attempt no longer owns the session."
          ))
        }
        return
      }
      transfer.cancellationResults.append(result)
      guard !transfer.cancelling else { return }
      transfer.cancelling = true
      self.cancelWifiPrematureEndGrace(transfer)
      guard transfer.fileActive, transfer.connectionAccepted else {
        self.finishWifiCancellation(transfer)
        return
      }
      let stopFrame = encodeRecordingCardWifiFrame(
        command: UInt8(RecordingCardBleCommand.stopFileTransfer.rawValue),
        sequence: 0,
        payload: []
      )
      let safety = DispatchWorkItem { [weak self, weak transfer] in
        guard let self, let transfer else { return }
        self.finishWifiCancellation(transfer)
      }
      transfer.cancellationWorkItem = safety
      self.wifiTransferQueue.asyncAfter(deadline: .now() + 1, execute: safety)
      transfer.connection.send(content: stopFrame, completion: .contentProcessed { [weak self, weak transfer] sendError in
        guard let self, let transfer, self.wifiDownload === transfer,
          transfer.cancelling
        else { return }
        transfer.cancellationWorkItem?.cancel()
        if sendError != nil {
          self.finishWifiCancellation(transfer)
          return
        }
        let quiet = DispatchWorkItem { [weak self, weak transfer] in
          guard let self, let transfer else { return }
          self.finishWifiCancellation(transfer)
        }
        transfer.cancellationWorkItem = quiet
        self.wifiTransferQueue.asyncAfter(deadline: .now() + 0.25, execute: quiet)
      })
    }
  }

  private func finishWifiCancellation(_ transfer: WifiTcpDownload) {
    guard wifiDownload === transfer, transfer.cancelling else { return }
    let openResult = transfer.openResult
    transfer.openResult = nil
    let fileResult = transfer.result
    transfer.result = nil
    let cancellationResults = drainWifiCancellationResults(transfer)
    transfer.cancellationWorkItem?.cancel()
    transfer.cancellationWorkItem = nil
    transfer.cancelling = false
    if transfer.fileActive {
      publishWifiTransferProgress(transfer, force: true, phase: "cancelled")
    }
    finishWifiSession(transfer, deletePart: true)
    DispatchQueue.main.async {
      let failure = self.error(
        "RECORDING_CARD_TRANSFER_CANCELLED",
        "Recording-card Wi-Fi transfer was cancelled."
      )
      openResult?(failure)
      fileResult?(failure)
      cancellationResults.forEach { $0(true) }
    }
  }

  private func drainWifiCancellationResults(
    _ transfer: WifiTcpDownload
  ) -> [FlutterResult] {
    let results = transfer.cancellationResults
    transfer.cancellationResults.removeAll(keepingCapacity: false)
    return results
  }

  private func wifiAttemptScope(
    from args: [String: Any]?
  ) -> RecordingCardWifiAttemptScope {
    let identityProvided = args?.keys.contains("recoveryBatchId") == true
      || args?.keys.contains("attemptId") == true
    return RecordingCardWifiAttemptScope(
      identityProvided: identityProvided,
      batchId: args?["recoveryBatchId"] as? String,
      attemptId: args?["attemptId"] as? String
    )
  }

  private func wifiAttemptOwnershipSnapshot() -> RecordingCardWifiAttemptOwnershipSnapshot {
    if Thread.isMainThread {
      return RecordingCardWifiAttemptOwnershipSnapshot(
        owned: wifiAttemptOwnershipActive,
        batchId: wifiRecoveryBatchId,
        attemptId: wifiAttemptId
      )
    }
    return DispatchQueue.main.sync {
      RecordingCardWifiAttemptOwnershipSnapshot(
        owned: self.wifiAttemptOwnershipActive,
        batchId: self.wifiRecoveryBatchId,
        attemptId: self.wifiAttemptId
      )
    }
  }

  private func wifiAttemptScopeOwnsTransfer(
    _ scope: RecordingCardWifiAttemptScope,
    transfer: WifiTcpDownload
  ) -> Bool {
    let current = wifiAttemptOwnershipSnapshot()
    guard recordingCardWifiAttemptMatches(
      identityProvided: scope.identityProvided,
      capturedBatchId: scope.batchId,
      capturedAttemptId: scope.attemptId,
      currentBatchId: current.batchId,
      currentAttemptId: current.attemptId,
      currentAttemptOwned: current.owned
    ) else { return false }
    return recordingCardWifiAttemptMatches(
      identityProvided: transfer.recoveryBatchId != nil || transfer.attemptId != nil,
      capturedBatchId: transfer.recoveryBatchId,
      capturedAttemptId: transfer.attemptId,
      currentBatchId: current.batchId,
      currentAttemptId: current.attemptId,
      currentAttemptOwned: current.owned
    )
  }

  func acceptsWifiAttempt(_ args: [String: Any]?) -> Bool {
    let scope = wifiAttemptScope(from: args)
    return recordingCardWifiAttemptMatches(
      identityProvided: scope.identityProvided,
      capturedBatchId: scope.batchId,
      capturedAttemptId: scope.attemptId,
      currentBatchId: wifiRecoveryBatchId,
      currentAttemptId: wifiAttemptId,
      currentAttemptOwned: wifiAttemptOwnershipActive
    )
  }

  func beginWifiAttempt(_ args: [String: Any]?, result: @escaping FlutterResult) {
    guard let batchId = args?["recoveryBatchId"] as? String, !batchId.isEmpty, batchId.count <= 160,
      let attemptId = args?["attemptId"] as? String,
      attemptId.range(of: "^[a-zA-Z0-9_-]{1,128}$", options: .regularExpression) != nil
    else {
      result(error("RECORDING_CARD_WIFI_ATTEMPT_INVALID", "Invalid Wi-Fi attempt identity."))
      return
    }
    guard recordingCardWifiAttemptCanBegin(
      sessionActive: wifiSessionActiveOnMain,
      attemptOwned: wifiAttemptOwnershipActive,
      joinInProgress: wifiJoinInProgress,
      preparationInFlight: wifiPrepareResult != nil,
      disableInFlight: wifiHotspotDisableInFlight,
      handoffReady: wifiHandoffReady,
      bleDisconnectExpected: wifiBleDisconnectExpected,
      joiningSSID: wifiJoiningSSID,
      joinedSSID: joinedWifiSSID
    ), wifiBackgroundLease?.awaitingBleRecovery != true else {
      result(error("RECORDING_CARD_WIFI_SESSION_BUSY", "Previous Wi-Fi session is still active."))
      return
    }
    wifiRecoveryBatchId = batchId
    wifiAttemptId = attemptId
    wifiAttemptOwnershipActive = true
    wifiInterruptionCode = nil
    ensureWifiBackgroundExecution(
      batchId: batchId,
      attemptId: attemptId,
      ownerFingerprint: safeFingerprint
    )
    result(true)
  }

  func queryWifiSession(result: @escaping FlutterResult) {
    let pendingSetup = recordingCardWifiHandoffOwnershipIsActive(
      sessionActive: wifiSessionActiveOnMain,
      attemptOwned: wifiAttemptOwnershipActive,
      joinInProgress: wifiJoinInProgress,
      preparationInFlight: wifiPrepareResult != nil,
      disableInFlight: wifiHotspotDisableInFlight,
      handoffReady: wifiHandoffReady,
      bleDisconnectExpected: wifiBleDisconnectExpected,
      joiningSSID: wifiJoiningSSID,
      joinedSSID: joinedWifiSSID
    )
    let batchId = wifiRecoveryBatchId ?? ""
    let attemptId = wifiAttemptId ?? ""
    let interruptionCode = wifiInterruptionCode
    var observation: [String: Any] = [
      "batchId": batchId,
      "attemptId": attemptId,
      "active": pendingSetup,
    ]
    if let interruptionCode { observation["failureCode"] = interruptionCode }
    result(observation)
  }

  func settleWifiRecovery(_ args: [String: Any]?, result: @escaping FlutterResult) {
    guard let batchId = args?["recoveryBatchId"] as? String,
      !batchId.isEmpty, batchId.count <= 160,
      let attemptId = args?["attemptId"] as? String,
      attemptId.range(of: "^[a-zA-Z0-9_-]{1,128}$", options: .regularExpression) != nil,
      let ownerFingerprint = args?["safeDeviceFingerprint"] as? String,
      !ownerFingerprint.isEmpty, ownerFingerprint.count <= 160
    else {
      result(error("RECORDING_CARD_WIFI_ATTEMPT_INVALID", "Invalid Wi-Fi recovery settlement identity."))
      return
    }
    guard let lease = wifiBackgroundLease else {
      result(true)
      return
    }
    guard recordingCardWifiBackgroundSettlementOwnsLease(
      awaitingRecovery: lease.awaitingBleRecovery,
      leaseBatchId: lease.batchId,
      leaseAttemptId: lease.attemptId,
      leaseOwnerFingerprint: lease.ownerFingerprint,
      requestedBatchId: batchId,
      requestedAttemptId: attemptId,
      requestedOwnerFingerprint: ownerFingerprint
    ) else {
      result(error(
        "RECORDING_CARD_WIFI_ATTEMPT_SUPERSEDED",
        "Wi-Fi recovery settlement no longer owns the native background lease."
      ))
      return
    }
    endWifiBackgroundExecution(lease)
    result(true)
  }

  private func settleWifiSessionOperationOnMain(
    sessionID: String,
    completion: @escaping () -> Void
  ) {
    let settle = { [weak self] in
      if self?.wifiSessionIdOnMain == sessionID {
        self?.wifiSessionOperationInFlightOnMain = false
      }
      completion()
    }
    if Thread.isMainThread {
      settle()
    } else {
      DispatchQueue.main.async(execute: settle)
    }
  }

  private func emitWifiInterruption(_ code: String, transfer: WifiTcpDownload) {
    let event: [String: Any] = [
      "type": "wifi_session", "batchId": transfer.recoveryBatchId ?? "",
      "attemptId": transfer.attemptId ?? "", "active": false, "failureCode": code,
    ]
    DispatchQueue.main.async { [weak self] in
      self?.wifiInterruptionCode = code
      self?.onEvent?(event)
    }
  }

  private func ensureWifiBackgroundExecution(
    batchId: String?,
    attemptId: String?,
    ownerFingerprint: String?
  ) {
    dispatchPrecondition(condition: .onQueue(.main))
    if let existing = wifiBackgroundLease {
      if existing.identifier != .invalid,
        recordingCardWifiBackgroundLeaseMatchesOwner(
          capturedBatchId: existing.batchId,
          capturedAttemptId: existing.attemptId,
          capturedOwnerFingerprint: existing.ownerFingerprint,
          requestedBatchId: batchId,
          requestedAttemptId: attemptId,
          requestedOwnerFingerprint: ownerFingerprint
        )
      {
        return
      }
      endWifiBackgroundExecution(existing)
    }
    wifiBackgroundGeneration &+= 1
    if wifiBackgroundGeneration == 0 { wifiBackgroundGeneration &+= 1 }
    let lease = RecordingCardWifiBackgroundLease(
      generation: wifiBackgroundGeneration,
      batchId: batchId,
      attemptId: attemptId,
      ownerFingerprint: ownerFingerprint
    )
    wifiBackgroundLease = lease
    let identifier = UIApplication.shared.beginBackgroundTask(
      withName: "RecordingCardWifiTransfer"
    ) { [weak self, weak lease] in
      guard let self, let lease else { return }
      self.wifiTransferQueue.async { [weak self, weak lease] in
        guard let self, let lease else { return }
        let ownsBackgroundLease = DispatchQueue.main.sync {
          self.wifiBackgroundLeaseIsCurrent(lease)
        }
        guard ownsBackgroundLease else { return }
        guard let transfer = self.wifiDownload else {
          DispatchQueue.main.async { [weak self, weak lease] in
            guard let self, let lease,
              self.wifiBackgroundLeaseIsCurrent(lease)
            else { return }
            self.finishWifiRuntimeAfterBackgroundExpiration(lease: lease)
          }
          return
        }
        self.failWifiDownload(
          transfer,
          code: "RECORDING_CARD_WIFI_BACKGROUND_EXPIRED",
          message: "Background Wi-Fi execution expired; return to continue.",
          cleanupMode: .selfContained(settleHotspot: true)
        )
      }
    }
    lease.identifier = identifier
    if identifier == .invalid {
      wifiBackgroundLease = nil
    }
  }

  private func finishWifiRuntimeAfterBackgroundExpiration(
    lease: RecordingCardWifiBackgroundLease
  ) {
    dispatchPrecondition(condition: .onQueue(.main))
    guard wifiBackgroundLeaseIsCurrent(lease) else { return }
    if lease.awaitingBleRecovery {
      endWifiBackgroundExecution(lease)
      return
    }
    let code = "RECORDING_CARD_WIFI_BACKGROUND_EXPIRED"
    wifiInterruptionCode = code
    onEvent?([
      "type": "wifi_session",
      "batchId": wifiRecoveryBatchId ?? "",
      "attemptId": wifiAttemptId ?? "",
      "active": false,
      "failureCode": code,
    ])
    finishWifiPreparation(
      errorCode: code,
      disableReadyHotspotIfWritable: true
    ) { [weak self, weak lease] in
      guard let self, let lease,
        self.wifiBackgroundLeaseIsCurrent(lease)
      else { return }
      _ = self.clearWifiHandoffRuntime(
        retainBackgroundForBleRecovery: false,
        forceEndBackgroundExecution: true
      )
      self.publishSnapshot()
    }
  }

  private func retainWifiBackgroundExecutionForBleRecovery() {
    let retain = { [weak self] in
      guard let self, let lease = self.wifiBackgroundLease,
        lease.identifier != .invalid,
        let ownerFingerprint = lease.ownerFingerprint,
        !ownerFingerprint.isEmpty
      else {
        self?.endWifiBackgroundExecution()
        return
      }
      lease.awaitingBleRecovery = true
      lease.recoveryTimer?.invalidate()
      let timer = Timer(timeInterval: Self.wifiBleRecoveryBackgroundTimeout, repeats: false) {
        [weak self, weak lease] _ in
        guard let self, let lease else { return }
        recordingCardDebugLog("wifi BLE recovery background lease expired")
        self.endWifiBackgroundExecution(lease)
      }
      lease.recoveryTimer = timer
      RunLoop.main.add(timer, forMode: .common)
      recordingCardDebugLog(
        "wifi background lease retained for BLE recovery generation=\(lease.generation)"
      )
    }
    if Thread.isMainThread { retain() } else { DispatchQueue.main.async(execute: retain) }
  }

  private func endWifiBackgroundExecution(
    _ expectedLease: RecordingCardWifiBackgroundLease? = nil
  ) {
    let finish = { [weak self, expectedLease] in
      guard let self, let lease = self.wifiBackgroundLease else { return }
      if let expectedLease, lease !== expectedLease { return }
      guard lease.generation == self.wifiBackgroundGeneration,
        lease.identifier != .invalid
      else {
        if lease.identifier == .invalid { self.wifiBackgroundLease = nil }
        return
      }
      let identifier = lease.identifier
      lease.identifier = .invalid
      lease.recoveryTimer?.invalidate()
      lease.recoveryTimer = nil
      self.wifiBackgroundLease = nil
      UIApplication.shared.endBackgroundTask(identifier)
    }
    if Thread.isMainThread { finish() } else { DispatchQueue.main.async(execute: finish) }
  }

  private func wifiBackgroundLeaseIsCurrent(
    _ lease: RecordingCardWifiBackgroundLease
  ) -> Bool {
    dispatchPrecondition(condition: .onQueue(.main))
    guard let current = wifiBackgroundLease else { return false }
    return current.identifier != .invalid
      && recordingCardWifiBackgroundLeaseCallbackIsCurrent(
        capturedGeneration: lease.generation,
        currentGeneration: wifiBackgroundGeneration,
        capturedIdentifier: lease.identifier.rawValue,
        currentIdentifier: current.identifier.rawValue,
        sameLease: current === lease
      )
  }

  private func endWifiBackgroundRecoveryIfOwned(
    by requestedFingerprint: String?
  ) {
    dispatchPrecondition(condition: .onQueue(.main))
    guard let lease = wifiBackgroundLease,
      recordingCardWifiBackgroundRecoveryOwnsTarget(
        awaitingRecovery: lease.awaitingBleRecovery,
        ownerFingerprint: lease.ownerFingerprint,
        requestedFingerprint: requestedFingerprint
      )
    else { return }
    endWifiBackgroundExecution(lease)
  }

  func recoverWifiDownload(_ args: [String: Any]?, result: @escaping FlutterResult) {
    recoverCommittedDownload(
      args,
      invalidTargetCode: "RECORDING_CARD_WIFI_TARGET_INVALID",
      invalidTargetMessage: "Invalid private Wi-Fi target.",
      recoveryFailureCode: "RECORDING_CARD_WIFI_LOCAL_RECOVERY_FAILED",
      recoveryFailureMessage: "Private Wi-Fi file could not be verified.",
      result: result
    )
  }

  func recoverBluetoothDownload(_ args: [String: Any]?, result: @escaping FlutterResult) {
    recoverCommittedDownload(
      args,
      invalidTargetCode: "RECORDING_CARD_BLUETOOTH_TARGET_INVALID",
      invalidTargetMessage: "Invalid private Bluetooth target.",
      recoveryFailureCode: "RECORDING_CARD_BLUETOOTH_LOCAL_RECOVERY_FAILED",
      recoveryFailureMessage: "Private Bluetooth file could not be verified.",
      result: result
    )
  }

  private func recoverCommittedDownload(
    _ args: [String: Any]?,
    invalidTargetCode: String,
    invalidTargetMessage: String,
    recoveryFailureCode: String,
    recoveryFailureMessage: String,
    result: @escaping FlutterResult
  ) {
    guard let request = parseDownloadRequest(args), let fileId = args?["plannedNativeFileId"] as? String,
      fileId.range(of: "^card-[a-f0-9]{32}$", options: .regularExpression) != nil
    else {
      result(error(invalidTargetCode, invalidTargetMessage))
      return
    }
    let protectedDataAvailable = UIApplication.shared.isProtectedDataAvailable
    guard protectedDataAvailable else {
      result(error("RECORDING_CARD_WIFI_UNLOCK_REQUIRED", "Unlock the device to verify private recordings."))
      return
    }
    DispatchQueue.global(qos: .utility).async { [weak self] in
      guard let self else { return }
      do {
        let root = try FileManager.default.url(for: .applicationSupportDirectory,
          in: .userDomainMask, appropriateFor: nil, create: false)
        let file = root.appendingPathComponent(
          "HuahuoAI/Recordings/RecordingCard/\(fileId).\(request.format)"
        )
        let part = file.appendingPathExtension("part")
        guard FileManager.default.fileExists(atPath: file.path) else {
          if FileManager.default.fileExists(atPath: part.path) {
            try FileManager.default.removeItem(at: part)
          }
          DispatchQueue.main.async { result(["exists": false]) }
          return
        }
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let recoveryAction = recordingCardCommittedDownloadRecoveryAction(
          actualSize: size,
          directorySizeBytes: request.directorySizeBytes
        )
        if recoveryAction == .reset {
          try FileManager.default.removeItem(at: file)
          if FileManager.default.fileExists(atPath: part.path) {
            try FileManager.default.removeItem(at: part)
          }
          DispatchQueue.main.async { result(["exists": false]) }
          return
        }
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        var digest = SHA256()
        while let data = try input.read(upToCount: 65536), !data.isEmpty { digest.update(data: data) }
        let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
        let response: [String: Any] = [
          "exists": true,
          "localFileKey": request.localFileKey, "localFileId": fileId,
          "appPrivateUri": "app-private://recording-card/\(fileId).\(request.format)",
          "displayName": self.displayNameFor(request.deviceFilename, format: request.format),
          "sizeBytes": size, "contentHash": hash, "format": request.format,
          "mimeType": self.mimeTypeFor(request.format),
        ]
        DispatchQueue.main.async { result(response) }
      } catch {
        let code = protectedDataAvailable ? recoveryFailureCode : "RECORDING_CARD_WIFI_UNLOCK_REQUIRED"
        DispatchQueue.main.async { result(self.error(code, recoveryFailureMessage)) }
      }
    }
  }

  func openWifiSession(_ args: [String: Any]?, result: @escaping FlutterResult) {
    guard acceptsWifiAttempt(args) else {
      result(error(
        "RECORDING_CARD_WIFI_ATTEMPT_SUPERSEDED",
        "Wi-Fi attempt no longer owns the session."
      ))
      return
    }
    guard !unbindInProgress else {
      result(error("RECORDING_CARD_UNBIND_IN_PROGRESS", "Recording-card unbind is in progress."))
      return
    }
    guard !wifiSessionActiveOnMain, offlineCapture == nil else {
      result(error("RECORDING_CARD_WIFI_DOWNLOAD_IN_PROGRESS", "A Wi-Fi file download is already running."))
      return
    }
    guard let rows = args?["files"] as? [[String: Any]], !rows.isEmpty else {
      result(error("RECORDING_CARD_INVALID_FILE", "Recording-card Wi-Fi session payload is invalid."))
      return
    }
    let requests = rows.compactMap(parseDownloadRequest)
    guard requests.count == rows.count, let request = requests.first else {
      result(error("RECORDING_CARD_INVALID_FILE", "Recording-card Wi-Fi session payload is invalid."))
      return
    }
    guard let capture = createOfflineCapture(request) else {
      result(error("RECORDING_CARD_LOCAL_STORAGE_FAILED", "Recording-card download could not prepare private storage."))
      return
    }
    let connection = NWConnection(
      host: NWEndpoint.Host("192.168.200.1"),
      port: NWEndpoint.Port(rawValue: 8475)!,
      using: .tcp
    )
    let compatibilityProfile = recordingCardWifiAllowsQuietBoundary(
      firmwareVersion: firmwareVersion,
      wifiFirmwareVersion: wifiFirmwareVersion
    )
    let ownedRecoveryBatchId = wifiAttemptOwnershipActive ? wifiRecoveryBatchId : nil
    let ownedAttemptId = wifiAttemptOwnershipActive ? wifiAttemptId : nil
    let transfer = WifiTcpDownload(
      capture: capture,
      connection: connection,
      allowOmittedDataCrc: compatibilityProfile,
      allowQuietStopBoundary: compatibilityProfile,
      openResult: result,
      requestedFiles: requests,
      recoveryBatchId: ownedRecoveryBatchId,
      attemptId: ownedAttemptId
    )
    wifiSessionActiveOnMain = true
    wifiSessionIdOnMain = transfer.sessionID
    wifiSessionOperationInFlightOnMain = true
    wifiTransferProgressOnMain = nil
    ensureWifiBackgroundExecution(
      batchId: transfer.recoveryBatchId,
      attemptId: transfer.attemptId,
      ownerFingerprint: safeFingerprint
    )
    recordingCardDebugLog(
      "wifi session opening id=\(transfer.sessionID) requestedFiles=\(requests.count)"
    )
    wifiTransferQueue.async { [weak self, transfer] in
      guard let self else { return }
      self.wifiDownload = transfer
      self.scheduleWifiDownloadTimeout(transfer, seconds: 10)
      connection.stateUpdateHandler = { [weak self, weak transfer] state in
        guard let self, let transfer, self.wifiDownload === transfer else { return }
        recordingCardDebugLog(
          "wifi download state id=\(transfer.capture.correlationID) state=\(recordingCardWifiNetworkStateLabel(state))"
        )
        if transfer.cancelling { return }
        switch state {
        case .ready:
          transfer.connectionHealthy = true
          if !transfer.receiveStarted {
            transfer.receiveStarted = true
            self.beginWifiDownload(transfer)
          }
        case .waiting:
          transfer.connectionHealthy = false
        case .failed:
          transfer.connectionHealthy = false
          self.failWifiDownload(
            transfer,
            code: "RECORDING_CARD_WIFI_NETWORK_UNAVAILABLE",
            message: "Recording-card Wi-Fi endpoint is unavailable."
          )
        case .cancelled:
          transfer.connectionHealthy = false
          if self.wifiDownload === transfer {
            self.failWifiDownload(
              transfer,
              code: "RECORDING_CARD_WIFI_TRANSFER_CANCELLED",
              message: "Recording-card Wi-Fi transfer was cancelled."
            )
          }
        default:
          break
        }
      }
      connection.start(queue: self.wifiTransferQueue)
    }
    publishSnapshot()
  }

  private func beginWifiDownload(_ transfer: WifiTcpDownload) {
    recordingCardDebugLog(
      "wifi connection ready id=\(transfer.capture.correlationID) awaiting=0x20"
    )
    receiveWifiDownload(transfer)
  }

  private func sendWifiFileRequest(_ transfer: WifiTcpDownload) {
    guard wifiDownload === transfer, transfer.connectionAccepted,
      transfer.directoryComplete,
      transfer.fileActive,
      !transfer.requestSent
    else { return }
    let seekOffset = transfer.tailSeekOffset ?? 0
    guard let requestPayload = recordingCardFileRequestPayload(
      transfer.capture.request.deviceFilename,
      seekOffset: seekOffset
    ) else {
      failWifiDownload(
        transfer,
        code: "RECORDING_CARD_INVALID_FILE",
        message: "Recording-card Wi-Fi file seek was invalid."
      )
      return
    }
    let frame = encodeRecordingCardWifiFrame(
      command: UInt8(RecordingCardBleCommand.requestFile.rawValue),
      sequence: 0,
      payload: requestPayload
    )
    transfer.requestSent = true
    recordingCardDebugLog(
      "wifi request sending id=\(transfer.capture.correlationID) cmd=0x0B frame=wifi bytes=\(frame.count) seekBytes=\(seekOffset)"
    )
    transfer.connection.send(content: frame, completion: .contentProcessed { [weak self, weak transfer] sendError in
      guard let self, let transfer, self.wifiDownload === transfer else { return }
      if sendError != nil {
        self.failWifiDownload(
          transfer,
          code: "RECORDING_CARD_WIFI_WRITE_FAILED",
          message: "Recording-card Wi-Fi file request could not be sent."
        )
        return
      }
      recordingCardDebugLog("wifi request sent id=\(transfer.capture.correlationID)")
    })
  }

  private func sendWifiDirectoryRequest(_ transfer: WifiTcpDownload) {
    guard wifiDownload === transfer, transfer.connectionAccepted,
      !transfer.directoryRequestSent
    else { return }
    let frame = encodeRecordingCardWifiFrame(
      command: UInt8(RecordingCardBleCommand.listFiles.rawValue),
      sequence: 0,
      payload: []
    )
    transfer.directoryRequestSent = true
    scheduleWifiDownloadTimeout(transfer, seconds: 30)
    recordingCardDebugLog(
      "wifi directory request sending id=\(transfer.capture.correlationID) frame=wifi bytes=\(frame.count)"
    )
    transfer.connection.send(content: frame, completion: .contentProcessed { [weak self, weak transfer] sendError in
      guard let self, let transfer, self.wifiDownload === transfer else { return }
      if sendError != nil {
        self.failWifiDownload(
          transfer,
          code: "RECORDING_CARD_WIFI_WRITE_FAILED",
          message: "Recording-card Wi-Fi directory request could not be sent."
        )
        return
      }
      recordingCardDebugLog(
        "wifi directory request sent id=\(transfer.capture.correlationID)"
      )
    })
  }

  private func receiveWifiDownload(_ transfer: WifiTcpDownload) {
    transfer.connection.receive(
      minimumIncompleteLength: 1,
      maximumLength: 64 * 1024
    ) { [weak self, weak transfer] data, _, complete, receiveError in
      guard let self, let transfer, self.wifiDownload === transfer else { return }
      if transfer.cancelling { return }
      if let data, !data.isEmpty {
        transfer.lastActivityUptime = ProcessInfo.processInfo.systemUptime
        let firstChunk = transfer.networkBytesReceived == 0
        transfer.networkBytesReceived += data.count
        if firstChunk || transfer.networkBytesReceived >= transfer.nextNetworkLogBytes {
          recordingCardDebugLog(
            "wifi receive id=\(transfer.capture.correlationID) chunkBytes=\(data.count) networkBytes=\(transfer.networkBytesReceived) signature=\(recordingCardWifiWireSignature(data)) envelope=\(recordingCardWifiEnvelopeDiagnostic(data)) acknowledged=\(transfer.capture.acknowledged)"
          )
          while transfer.networkBytesReceived >= transfer.nextNetworkLogBytes {
            transfer.nextNetworkLogBytes += 256 * 1024
          }
        }
        if transfer.fileActive, transfer.capture.acknowledged {
          self.scheduleWifiInactivityTimeout(transfer, seconds: 30)
        }
        if !self.consumeWifiDownload(data, transfer: transfer) { return }
      }
      if receiveError != nil {
        self.failWifiDownload(
          transfer,
          code: "RECORDING_CARD_WIFI_READ_FAILED",
          message: "Recording-card Wi-Fi file data could not be read."
        )
        return
      }
      if complete {
        self.failWifiDownload(
          transfer,
          code: "RECORDING_CARD_WIFI_DOWNLOAD_INCOMPLETE",
          message: "Recording-card Wi-Fi file ended before its advertised size."
        )
        return
      }
      if self.wifiDownload === transfer {
        self.receiveWifiDownload(transfer)
      }
    }
  }

  private func consumeWifiDownload(_ data: Data, transfer: WifiTcpDownload) -> Bool {
    transfer.buffer.append(data)
    while true {
      switch parseRecordingCardWifiFrame(
        transfer.buffer,
        allowOmittedDataCrc: transfer.allowOmittedDataCrc
      ) {
      case .pending:
        return true
      case .invalid:
        recordingCardDebugLog(
          "wifi frame invalid id=\(transfer.capture.correlationID) bufferedBytes=\(transfer.buffer.count) signature=\(recordingCardWifiWireSignature(transfer.buffer)) envelope=\(recordingCardWifiEnvelopeDiagnostic(transfer.buffer))"
        )
        failWifiDownload(
          transfer,
          code: "RECORDING_CARD_WIFI_PROTOCOL_INVALID",
          message: "Recording-card Wi-Fi response frame was invalid."
        )
        return false
      case let .frame(packet, frameLength):
        transfer.buffer.removeSubrange(0..<frameLength)
        if transfer.awaitingStopBoundary {
          transfer.boundaryFrameObserved = true
        }
        let status = packet.payload.count == 1
          ? String(format: "%02x", packet.payload[0])
          : "none"
        recordingCardDebugLog(
          "wifi frame accepted id=\(transfer.capture.correlationID) cmd=0x\(String(format: "%02x", packet.command)) seq=\(packet.sequence) payloadBytes=\(packet.payload.count) status=\(status)"
        )
        if !transfer.connectionAccepted {
          guard packet.command == 0x20,
            packet.payload.count == 1,
            packet.payload[0] == 0x00
          else {
            failWifiDownload(
              transfer,
              code: "RECORDING_CARD_WIFI_HANDOFF_REJECTED",
              message: "Recording-card Wi-Fi connection status was rejected."
            )
            return false
          }
          transfer.connectionAccepted = true
          recordingCardDebugLog(
            "wifi handoff accepted id=\(transfer.capture.correlationID)"
          )
          sendWifiDirectoryRequest(transfer)
          continue
        }
        if packet.command == UInt8(RecordingCardBleCommand.listFiles.rawValue) {
          if !consumeWifiDirectoryPacket(packet, transfer: transfer) { return false }
          continue
        }
        if packet.command == UInt8(RecordingCardBleCommand.stopFileTransfer.rawValue) {
          if !consumeWifiStopBoundary(packet, transfer: transfer) { return false }
          continue
        }
        guard transfer.requestSent,
          packet.command == UInt8(RecordingCardBleCommand.requestFile.rawValue)
        else {
          failWifiDownload(
            transfer,
            code: "RECORDING_CARD_WIFI_UNEXPECTED_COMMAND",
            message: "Recording-card Wi-Fi returned an unexpected command."
          )
          return false
        }
        if !consumeWifiFilePacket(packet, transfer: transfer) { return false }
      }
    }
  }

  private func consumeWifiDirectoryPacket(
    _ packet: RecordingCardWifiPacket,
    transfer: WifiTcpDownload
  ) -> Bool {
    guard transfer.directoryRequestSent else {
      failWifiDownload(
        transfer,
        code: "RECORDING_CARD_WIFI_UNEXPECTED_COMMAND",
        message: "Recording-card Wi-Fi returned a directory row before it was requested."
      )
      return false
    }
    if transfer.directoryComplete {
      transfer.lateDirectoryRows += 1
      if transfer.lateDirectoryRows == 1 {
        recordingCardDebugLog(
          "wifi late directory frame ignored id=\(transfer.capture.correlationID)"
        )
      }
      return true
    }

    let payload = packet.payload
    if payload.count == 1 {
      if payload[0] == 0x01 {
        failWifiDownload(
          transfer,
          code: "RECORDING_CARD_WIFI_DIRECTORY_REJECTED",
          message: "Recording-card Wi-Fi directory refresh was rejected."
        )
        return false
      }
      guard payload[0] == 0x02 else {
        failWifiDownload(
          transfer,
          code: "RECORDING_CARD_WIFI_DIRECTORY_MALFORMED",
          message: "Recording-card Wi-Fi directory response was malformed."
        )
        return false
      }
      transfer.directoryComplete = true
      transfer.readyForFile = true
      recordingCardDebugLog(
        "wifi directory completed id=\(transfer.sessionID) rows=\(transfer.directoryRowsReceived)"
      )
      transfer.overallTimeoutWorkItem?.cancel()
      let openResult = transfer.openResult
      transfer.openResult = nil
      let response: [String: Any] = [
        "sessionId": transfer.sessionID,
        "files": transfer.catalogRows,
        "openedAt": isoNow(),
      ]
      settleWifiSessionOperationOnMain(sessionID: transfer.sessionID) {
        openResult?(response)
      }
      return true
    }

    guard payload.count >= 19, payload.first == 0x00,
      let filename = asciiString(Array(payload[1...14]))
    else {
      failWifiDownload(
        transfer,
        code: "RECORDING_CARD_WIFI_DIRECTORY_MALFORMED",
        message: "Recording-card Wi-Fi directory response was malformed."
      )
      return false
    }
    transfer.directoryRowsReceived += 1
    if let row = parseFileRow(payload) {
      if let existing = transfer.catalogByFilename[filename],
        (existing["sizeBytes"] as? Int) != (row["sizeBytes"] as? Int)
      {
        failWifiDownload(
          transfer,
          code: "RECORDING_CARD_WIFI_DIRECTORY_CONFLICT",
          message: "Recording-card Wi-Fi directory contained conflicting duplicate rows."
        )
        return false
      }
      if transfer.catalogByFilename[filename] == nil {
        transfer.catalogByFilename[filename] = row
        transfer.catalogRows.append(row)
      }
    }
    guard filename == transfer.capture.request.deviceFilename else { return true }
    transfer.selectedDirectoryRowObserved = true
    let littleEndianSize = readUInt32(payload, offset: 15, littleEndian: true)
    let bigEndianSize = readUInt32(payload, offset: 15, littleEndian: false)
    if let resolved = recordingCardDirectoryFileSize(
      littleEndian: littleEndianSize,
      bigEndian: bigEndianSize
    ) {
      transfer.capture.request = transfer.capture.request.withDirectorySize(
        resolved.sizeBytes,
        confidence: resolved.confidence
      )
    }
    return true
  }

  private func consumeWifiFilePacket(
    _ packet: RecordingCardWifiPacket,
    transfer: WifiTcpDownload
  ) -> Bool {
    let payload = packet.payload
    let capture = transfer.capture
    if payload.count == 1, payload[0] == 0x02 {
      if !capture.acknowledged {
        guard let directorySize = capture.request.directorySizeBytes,
          isValidDeviceFileSize(directorySize)
        else {
          failWifiDownload(
            transfer,
            code: "RECORDING_CARD_DOWNLOAD_LENGTH_UNAVAILABLE",
            message: "Recording-card Wi-Fi file length was unavailable."
          )
          return false
        }
        capture.request = capture.request.withTargetBytes(directorySize)
        capture.acknowledged = true
        scheduleWifiDownloadTimeout(
          transfer,
          seconds: downloadOverallTimeout(directorySize)
        )
        scheduleWifiInactivityTimeout(transfer, seconds: 30)
      }
      switch recordingCardWifiEndDecision(
        receivedBytes: capture.receivedBytes,
        targetBytes: capture.request.targetBytes,
        graceExpired: false
      ) {
      case .complete:
        cancelWifiPrematureEndGrace(transfer)
        capture.dataComplete = true
        completeWifiDownload(transfer)
      case .awaitTrailingData:
        scheduleWifiPrematureEndGrace(transfer)
      case .failIncomplete:
        failWifiCurrentFile(
          transfer,
          code: "RECORDING_CARD_WIFI_DOWNLOAD_INCOMPLETE",
          message: "Recording-card Wi-Fi file ended before its advertised size.",
          closeSession: false
        )
      }
      return true
    }
    if transfer.tailSeekAwaitingData, payload.count == 1 {
      if payload[0] == 0x00 {
        recordingCardDebugLog(
          "wifi tail seek acknowledgement accepted id=\(capture.correlationID) seekBytes=\(transfer.tailSeekOffset ?? 0)"
        )
        return true
      }
      if payload[0] == 0x01 {
        failWifiCurrentFile(
          transfer,
          code: "RECORDING_CARD_WIFI_TAIL_SEEK_REJECTED",
          message: "Recording-card Wi-Fi tail seek was rejected.",
          closeSession: false
        )
        return true
      }
      failWifiCurrentFile(
        transfer,
        code: "RECORDING_CARD_WIFI_TAIL_SEEK_STATUS_INVALID",
        message: "Recording-card Wi-Fi tail seek returned an unknown status.",
        closeSession: false
      )
      return true
    }
    if transfer.tailSeekAwaitingData, payload.count == 5, payload[0] == 0x00 {
      let remainingBytes = capture.request.targetBytes - capture.receivedBytes
      guard let acknowledgedSize = recordingCardAcknowledgedFileSize(
        payload: payload,
        directorySizeBytes: nil
      ), acknowledgedSize == remainingBytes || acknowledgedSize == capture.request.targetBytes
      else {
        failWifiCurrentFile(
          transfer,
          code: "RECORDING_CARD_WIFI_TAIL_SEEK_LENGTH_MISMATCH",
          message: "Recording-card Wi-Fi tail seek length was invalid.",
          closeSession: false
        )
        return true
      }
      recordingCardDebugLog(
        "wifi tail seek length acknowledged id=\(capture.correlationID) acknowledgedBytes=\(acknowledgedSize) remainingBytes=\(remainingBytes)"
      )
      return true
    }
    if !capture.acknowledged {
      if payload.count == 5, payload[0] == 0x00,
        let targetBytes = recordingCardAcknowledgedFileSize(
          payload: payload,
          directorySizeBytes: nil
        )
      {
        let request = capture.request
        guard isValidDeviceFileSize(targetBytes),
          request.sizeConfidence != "trusted" || request.directorySizeBytes == targetBytes
        else {
          failWifiDownload(
            transfer,
            code: "RECORDING_CARD_DOWNLOAD_SIZE_MISMATCH",
            message: "Recording-card Wi-Fi size did not match the device listing."
          )
          return false
        }
        capture.request = request.withTargetBytes(targetBytes)
        capture.acknowledged = true
        recordingCardDebugLog(
          "wifi acknowledgement accepted id=\(capture.correlationID) targetBytes=\(targetBytes)"
        )
        scheduleWifiDownloadTimeout(
          transfer,
          seconds: downloadOverallTimeout(targetBytes)
        )
        scheduleWifiInactivityTimeout(transfer, seconds: 30)
        return true
      }
      switch recordingCardWifiStatusOnlyResponse(payload) {
      case .accepted:
        guard let directorySize = capture.request.directorySizeBytes,
          isValidDeviceFileSize(directorySize)
        else {
          failWifiDownload(
            transfer,
            code: "RECORDING_CARD_DOWNLOAD_LENGTH_UNAVAILABLE",
            message: "Recording-card Wi-Fi file length was unavailable."
          )
          return false
        }
        capture.request = capture.request.withTargetBytes(directorySize)
        capture.acknowledged = true
        recordingCardDebugLog(
          "wifi status acknowledgement accepted id=\(capture.correlationID) targetBytes=\(directorySize)"
        )
        scheduleWifiDownloadTimeout(
          transfer,
          seconds: downloadOverallTimeout(directorySize)
        )
        scheduleWifiInactivityTimeout(transfer, seconds: 30)
        return true
      case .rejected:
        failWifiCurrentFile(
          transfer,
          code: "RECORDING_CARD_WIFI_REQUEST_REJECTED",
          message: "Recording-card Wi-Fi file request was rejected.",
          closeSession: false
        )
        return true
      case .incomplete:
        scheduleWifiPrematureEndGrace(transfer)
        return true
      case .notStatus:
        break
      }
      guard let directorySize = capture.request.directorySizeBytes,
        isValidDeviceFileSize(directorySize)
      else {
        failWifiDownload(
          transfer,
          code: "RECORDING_CARD_DOWNLOAD_LENGTH_UNAVAILABLE",
          message: "Recording-card Wi-Fi file length was unavailable."
        )
        return false
      }
      capture.request = capture.request.withTargetBytes(directorySize)
      capture.acknowledged = true
      recordingCardDebugLog(
        "wifi data started without size ack id=\(capture.correlationID) targetBytes=\(directorySize)"
      )
      scheduleWifiDownloadTimeout(
        transfer,
        seconds: downloadOverallTimeout(directorySize)
      )
      scheduleWifiInactivityTimeout(transfer, seconds: 30)
    }

    if capture.dataComplete {
      failWifiDownload(
        transfer,
        code: "RECORDING_CARD_WIFI_DATA_OVERRUN",
        message: "Recording-card Wi-Fi sent data after the advertised file boundary."
      )
      return false
    }
    if transfer.tailSeekAwaitingData {
      let expectedTailBytes = capture.request.targetBytes - capture.receivedBytes
      guard recordingCardWifiTailPayloadMatches(
        remainingBytes: expectedTailBytes,
        payloadBytes: payload.count
      ) else {
        failWifiDownload(
          transfer,
          code: "RECORDING_CARD_WIFI_TAIL_SEEK_LENGTH_MISMATCH",
          message: "Recording-card Wi-Fi tail seek returned an ambiguous payload length."
        )
        return false
      }
      transfer.tailSeekAwaitingData = false
      recordingCardDebugLog(
        "wifi tail seek data started id=\(capture.correlationID) seekBytes=\(transfer.tailSeekOffset ?? 0) payloadBytes=\(payload.count)"
      )
    }
    guard let nextSequence = recordingCardWifiNextSequence(
      expected: transfer.expectedDataSequence,
      received: packet.sequence
    ) else {
      failWifiDownload(
        transfer,
        code: "RECORDING_CARD_WIFI_SEQUENCE_INVALID",
        message: "Recording-card Wi-Fi file sequence was not continuous."
      )
      return false
    }
    transfer.expectedDataSequence = nextSequence
    let remaining = capture.request.targetBytes - capture.receivedBytes
    guard recordingCardWifiPayloadFits(
      remainingBytes: remaining,
      payloadBytes: payload.count
    ) else {
      failWifiDownload(
        transfer,
        code: "RECORDING_CARD_WIFI_DATA_OVERRUN",
        message: "Recording-card Wi-Fi file exceeded its advertised size."
      )
      return false
    }
    let acceptedCount = payload.count
    guard acceptedCount > 0 else { return true }
    let accepted = Data(payload)
    do {
      try writeAll(accepted, to: capture.output)
      capture.digest.update(data: accepted)
      capture.receivedBytes += acceptedCount
      if transfer.prematureEndObserved,
        capture.receivedBytes < capture.request.targetBytes
      {
        recordingCardDebugLog(
          "wifi trailing data accepted id=\(capture.correlationID) acceptedBytes=\(capture.receivedBytes) targetBytes=\(capture.request.targetBytes)"
        )
        scheduleWifiPrematureEndGrace(transfer)
      }
      if capture.receivedBytes >= transfer.nextAcceptedLogBytes {
        recordingCardDebugLog(
          "wifi progress id=\(capture.correlationID) acceptedBytes=\(capture.receivedBytes) targetBytes=\(capture.request.targetBytes)"
        )
        while capture.receivedBytes >= transfer.nextAcceptedLogBytes {
          transfer.nextAcceptedLogBytes += 256 * 1024
        }
      }
      let now = ProcessInfo.processInfo.systemUptime
      let rateElapsed = now - transfer.rateSampleUptime
      if rateElapsed >= Self.wifiProgressPublishInterval {
        let instant = Double(capture.receivedBytes - transfer.rateSampleBytes) / rateElapsed
        transfer.bytesPerSecond = transfer.bytesPerSecond.map {
          ($0 * 0.65) + (instant * 0.35)
        } ?? instant
        transfer.rateSampleUptime = now
        transfer.rateSampleBytes = capture.receivedBytes
      }
      if capture.receivedBytes < capture.request.targetBytes {
        publishWifiTransferProgress(transfer, force: false, now: now)
      }
    } catch {
      failWifiDownload(
        transfer,
        code: "RECORDING_CARD_LOCAL_STORAGE_FAILED",
        message: "Recording-card Wi-Fi download could not write private storage."
      )
      return false
    }
    if capture.receivedBytes == capture.request.targetBytes {
      cancelWifiPrematureEndGrace(transfer)
      capture.dataComplete = true
      publishWifiTransferProgress(
        transfer,
        force: true,
        phase: "verifying"
      )
      scheduleWifiFileBoundary(transfer)
    }
    return true
  }

  private func scheduleWifiPrematureEndGrace(_ transfer: WifiTcpDownload) {
    guard wifiDownload === transfer, transfer.fileActive,
      transfer.capture.receivedBytes < transfer.capture.request.targetBytes
    else { return }
    let capture = transfer.capture
    transfer.prematureEndObserved = true
    transfer.prematureEndWorkItem?.cancel()
    recordingCardDebugLog(
      "wifi premature end observed id=\(capture.correlationID) acceptedBytes=\(capture.receivedBytes) targetBytes=\(capture.request.targetBytes) graceMs=1000"
    )
    let timeout = DispatchWorkItem { [weak self, weak transfer, weak capture] in
      guard let self, let transfer, let capture,
        self.wifiDownload === transfer,
        transfer.capture === capture,
        transfer.fileActive,
        transfer.prematureEndObserved
      else { return }
      guard recordingCardWifiEndDecision(
        receivedBytes: capture.receivedBytes,
        targetBytes: capture.request.targetBytes,
        graceExpired: true
      ) == .failIncomplete else { return }
      transfer.prematureEndWorkItem = nil
      if transfer.connectionHealthy, transfer.buffer.isEmpty,
        let seekOffset = recordingCardWifiTailResumeOffset(
          verifiedProfile: transfer.allowQuietStopBoundary,
          receivedBytes: capture.receivedBytes,
          targetBytes: capture.request.targetBytes,
          alreadyAttempted: transfer.tailSeekAttempted
        )
      {
        self.startWifiTailResume(transfer, seekOffset: seekOffset)
        return
      }
      recordingCardDebugLog(
        "wifi premature end grace expired id=\(capture.correlationID) acceptedBytes=\(capture.receivedBytes) targetBytes=\(capture.request.targetBytes)"
      )
      self.failWifiCurrentFile(
        transfer,
        code: "RECORDING_CARD_WIFI_DOWNLOAD_INCOMPLETE",
        message: "Recording-card Wi-Fi file ended before its advertised size.",
        closeSession: false
      )
    }
    transfer.prematureEndWorkItem = timeout
    wifiTransferQueue.asyncAfter(deadline: .now() + 1, execute: timeout)
  }

  private func cancelWifiPrematureEndGrace(_ transfer: WifiTcpDownload) {
    transfer.prematureEndWorkItem?.cancel()
    transfer.prematureEndWorkItem = nil
    transfer.prematureEndObserved = false
  }

  private func startWifiTailResume(
    _ transfer: WifiTcpDownload,
    seekOffset: Int
  ) {
    guard wifiDownload === transfer, transfer.fileActive,
      transfer.capture.receivedBytes == seekOffset,
      seekOffset < transfer.capture.request.targetBytes
    else { return }
    cancelWifiPrematureEndGrace(transfer)
    transfer.tailSeekAttempted = true
    transfer.tailSeekOffset = seekOffset
    transfer.tailSeekAwaitingData = true
    transfer.requestSent = false
    transfer.expectedDataSequence = nil
    recordingCardDebugLog(
      "wifi tail seek recovery starting id=\(transfer.capture.correlationID) seekBytes=\(seekOffset) remainingBytes=\(transfer.capture.request.targetBytes - seekOffset)"
    )
    scheduleWifiDownloadTimeout(
      transfer,
      seconds: downloadOverallTimeout(transfer.capture.request.targetBytes - seekOffset)
    )
    scheduleWifiInactivityTimeout(transfer, seconds: 30)
    sendWifiFileRequest(transfer)
  }

  private func scheduleWifiFileBoundary(_ transfer: WifiTcpDownload) {
    transfer.boundaryWorkItem?.cancel()
    let boundaryMode = recordingCardWifiBoundaryMode(
      allowQuietBoundary: transfer.allowQuietStopBoundary,
      requestedFileCount: transfer.requestedFiles.count,
      completedFileCount: transfer.completedFileCount
    )
    let grace = DispatchWorkItem { [weak self, weak transfer] in
      guard let self, let transfer, self.wifiDownload === transfer,
        transfer.fileActive, transfer.capture.dataComplete
      else { return }
      transfer.awaitingStopBoundary = true
      transfer.boundaryFrameObserved = false
      if boundaryMode == .interFileQuiet {
        recordingCardDebugLog(
          "wifi inter-file quiet boundary waiting id=\(transfer.capture.correlationID) completedFiles=\(transfer.completedFileCount) requestedFiles=\(transfer.requestedFiles.count)"
        )
        let timeout = DispatchWorkItem { [weak self, weak transfer] in
          guard let self, let transfer, self.wifiDownload === transfer,
            transfer.awaitingStopBoundary
          else { return }
          if transfer.allowQuietStopBoundary,
            transfer.connectionHealthy,
            !transfer.boundaryFrameObserved,
            transfer.buffer.isEmpty
          {
            recordingCardDebugLog(
              "wifi inter-file quiet boundary accepted id=\(transfer.capture.correlationID) profile=fw-1.0.6-wifi-1.0.2"
            )
            self.completeWifiDownload(transfer)
            return
          }
          self.failWifiDownload(
            transfer,
            code: "RECORDING_CARD_WIFI_BOUNDARY_TIMEOUT",
            message: "Recording-card Wi-Fi inter-file boundary timed out."
          )
        }
        transfer.boundaryWorkItem = timeout
        self.wifiTransferQueue.asyncAfter(deadline: .now() + 2, execute: timeout)
        return
      }
      let frame = encodeRecordingCardWifiFrame(
        command: UInt8(RecordingCardBleCommand.stopFileTransfer.rawValue),
        sequence: 0,
        payload: []
      )
      recordingCardDebugLog(
        "wifi file boundary requesting id=\(transfer.capture.correlationID)"
      )
      transfer.connection.send(content: frame, completion: .contentProcessed { [weak self, weak transfer] sendError in
        guard let self, let transfer, self.wifiDownload === transfer else { return }
        if sendError != nil {
          self.failWifiDownload(
            transfer,
            code: "RECORDING_CARD_WIFI_BOUNDARY_FAILED",
            message: "Recording-card Wi-Fi file boundary could not be requested."
          )
          return
        }
        let timeout = DispatchWorkItem { [weak self, weak transfer] in
          guard let self, let transfer, self.wifiDownload === transfer,
            transfer.awaitingStopBoundary
          else { return }
          if transfer.allowQuietStopBoundary,
            transfer.connectionHealthy,
            !transfer.boundaryFrameObserved,
            transfer.buffer.isEmpty
          {
            recordingCardDebugLog(
              "wifi quiet boundary accepted id=\(transfer.capture.correlationID) profile=fw-1.0.6-wifi-1.0.2"
            )
            self.completeWifiDownload(transfer)
            return
          }
          self.failWifiDownload(
            transfer,
            code: "RECORDING_CARD_WIFI_BOUNDARY_TIMEOUT",
            message: "Recording-card Wi-Fi file boundary timed out."
          )
        }
        transfer.boundaryWorkItem = timeout
        self.wifiTransferQueue.asyncAfter(deadline: .now() + 2, execute: timeout)
      })
    }
    transfer.boundaryWorkItem = grace
    wifiTransferQueue.asyncAfter(deadline: .now() + 0.25, execute: grace)
  }

  private func consumeWifiStopBoundary(
    _ packet: RecordingCardWifiPacket,
    transfer: WifiTcpDownload
  ) -> Bool {
    guard transfer.fileActive, transfer.awaitingStopBoundary else { return true }
    guard packet.payload.count == 1,
      packet.payload[0] == 0x00 || packet.payload[0] == 0x02,
      transfer.capture.dataComplete,
      transfer.capture.receivedBytes == transfer.capture.request.targetBytes
    else {
      failWifiDownload(
        transfer,
        code: "RECORDING_CARD_WIFI_BOUNDARY_FAILED",
        message: "Recording-card Wi-Fi file boundary was rejected."
      )
      return false
    }
    completeWifiDownload(transfer)
    return true
  }

  private func failWifiCurrentFile(
    _ transfer: WifiTcpDownload,
    code: String,
    message: String,
    closeSession: Bool
  ) {
    guard wifiDownload === transfer, transfer.fileActive else { return }
    if transfer.cancelling {
      finishWifiCancellation(transfer)
      return
    }
    if closeSession {
      failWifiDownload(transfer, code: code, message: message)
      return
    }
    transfer.overallTimeoutWorkItem?.cancel()
    transfer.inactivityTimeoutWorkItem?.cancel()
    transfer.boundaryWorkItem?.cancel()
    transfer.cancellationWorkItem?.cancel()
    cancelWifiPrematureEndGrace(transfer)
    try? transfer.capture.output.close()
    try? FileManager.default.removeItem(at: transfer.capture.partURL)
    let fileResult = transfer.result
    transfer.result = nil
    publishWifiTransferProgress(transfer, force: true, phase: "failed")
    transfer.fileActive = false
    transfer.requestSent = false
    transfer.awaitingStopBoundary = false
    transfer.boundaryFrameObserved = false
    recordingCardDebugLog(
      "wifi file failed id=\(transfer.capture.correlationID) code=\(code) acceptedBytes=\(transfer.capture.receivedBytes)"
    )
    settleWifiSessionOperationOnMain(sessionID: transfer.sessionID) { [weak self] in
      guard let self else { return }
      fileResult?(self.error(code, message))
      self.publishSnapshot()
    }
  }

  private func finishWifiSession(
    _ transfer: WifiTcpDownload,
    deletePart: Bool
  ) {
    guard wifiDownload === transfer else { return }
    let cancellationResults = drainWifiCancellationResults(transfer)
    transfer.cancelling = false
    wifiDownload = nil
    transfer.overallTimeoutWorkItem?.cancel()
    transfer.inactivityTimeoutWorkItem?.cancel()
    transfer.boundaryWorkItem?.cancel()
    transfer.cancellationWorkItem?.cancel()
    cancelWifiPrematureEndGrace(transfer)
    transfer.connection.cancel()
    if deletePart {
      try? transfer.capture.output.close()
      try? FileManager.default.removeItem(at: transfer.capture.partURL)
    }
    let shouldPublishDisconnected = clearWifiHandoffRuntime(
      retainBackgroundForBleRecovery: true
    )
    recordingCardDebugLog("wifi session closed id=\(transfer.sessionID)")
    DispatchQueue.main.async { [weak self] in
      cancellationResults.forEach { $0(true) }
      guard let self else { return }
      if shouldPublishDisconnected {
        self.publishConnection(
          state: "disconnected",
          stage: "idle",
          message: "Wi-Fi 传输已结束，正在恢复蓝牙连接"
        )
      } else {
        self.publishSnapshot()
      }
    }
  }

  private func completeWifiDownload(_ transfer: WifiTcpDownload) {
    guard wifiDownload === transfer, transfer.fileActive else { return }
    let capture = transfer.capture
    transfer.boundaryWorkItem?.cancel()
    transfer.boundaryWorkItem = nil
    cancelWifiPrematureEndGrace(transfer)
    transfer.awaitingStopBoundary = false
    transfer.boundaryFrameObserved = false
    do {
      let digest = capture.digest
      let streamedContentHash = digest.finalize()
        .map { String(format: "%02x", $0) }
        .joined()
      let committed = try recordingCardCommitDownloadedPart(
        output: capture.output,
        partURL: capture.partURL,
        finalURL: capture.finalURL,
        expectedSize: capture.request.targetBytes,
        streamedContentHash: streamedContentHash
      )
      let actualSize = committed.sizeBytes
      let contentHash = committed.contentHash
      if transfer.tailSeekAttempted {
        recordingCardDebugLog(
          "wifi tail seek recovery completed id=\(capture.correlationID) bytes=\(actualSize)"
        )
      }
      var response: [String: Any] = [
        "localFileKey": capture.request.localFileKey,
        "localFileId": capture.fileID,
        "appPrivateUri": capture.appPrivateURI,
        "displayName": capture.displayName,
        "sizeBytes": capture.request.targetBytes,
        "contentHash": contentHash,
        "format": capture.request.format,
        "mimeType": mimeTypeFor(capture.request.format),
      ]
      if let durationSeconds = capture.request.durationSeconds {
        response["durationSeconds"] = durationSeconds
      }
      transfer.overallTimeoutWorkItem?.cancel()
      transfer.inactivityTimeoutWorkItem?.cancel()
      publishWifiTransferProgress(transfer, force: true, phase: "completed")
      transfer.fileActive = false
      transfer.requestSent = false
      transfer.completedFileCount += 1
      let fileResult = transfer.result
      transfer.result = nil
      recordingCardDebugLog(
        "wifi download committed id=\(capture.correlationID) bytes=\(actualSize) elapsedMs=\(transfer.elapsedMilliseconds)"
      )
      settleWifiSessionOperationOnMain(sessionID: transfer.sessionID) { [weak self] in
        fileResult?(response)
        self?.publishSnapshot()
      }
    } catch let failure as RecordingCardDownloadedFileCommitError {
      failWifiDownload(
        transfer,
        code: failure.code,
        message: "Recording-card Wi-Fi download could not durably commit private storage."
      )
    } catch {
      failWifiDownload(
        transfer,
        code: "RECORDING_CARD_LOCAL_STORAGE_FAILED",
        message: "Recording-card Wi-Fi download could not commit private storage."
      )
    }
  }

  private func failWifiDownload(
    _ transfer: WifiTcpDownload,
    code: String,
    message: String,
    cleanupMode: RecordingCardWifiFailureCleanupMode = .awaitScopedTerminalCleanup
  ) {
    guard wifiDownload === transfer else { return }
    emitWifiInterruption(code, transfer: transfer)
    let openResult = transfer.openResult
    transfer.openResult = nil
    let fileResult = transfer.result
    transfer.result = nil
    let cancellationResults = drainWifiCancellationResults(transfer)
    transfer.cancelling = false
    transfer.overallTimeoutWorkItem?.cancel()
    transfer.inactivityTimeoutWorkItem?.cancel()
    transfer.boundaryWorkItem?.cancel()
    transfer.cancellationWorkItem?.cancel()
    cancelWifiPrematureEndGrace(transfer)
    transfer.connection.cancel()
    try? transfer.capture.output.close()
    try? FileManager.default.removeItem(at: transfer.capture.partURL)
    if transfer.fileActive {
      let terminalPhase = code == "RECORDING_CARD_WIFI_TRANSFER_CANCELLED"
        ? "cancelled"
        : "failed"
      publishWifiTransferProgress(transfer, force: true, phase: terminalPhase)
    }
    recordingCardDebugLog(
      "wifi download failed id=\(transfer.capture.correlationID) code=\(code) acceptedBytes=\(transfer.capture.receivedBytes) targetBytes=\(transfer.capture.request.targetBytes) elapsedMs=\(transfer.elapsedMilliseconds) cleanup=\(cleanupMode)"
    )
    wifiDownload = nil

    let deliverFailure: (Bool) -> Void = { [weak self] shouldPublishDisconnected in
      let deliver = { [weak self] in
        cancellationResults.forEach { $0(true) }
        guard let self else { return }
        let failure = self.error(code, message)
        openResult?(failure)
        fileResult?(failure)
        if shouldPublishDisconnected {
          self.publishConnection(
            state: "disconnected",
            stage: "failed",
            message: "Wi-Fi 传输失败，正在恢复蓝牙连接"
          )
        } else {
          self.publishSnapshot()
        }
      }
      if Thread.isMainThread { deliver() } else { DispatchQueue.main.async(execute: deliver) }
    }

    let failureProjection = projectWifiFailureCleanup(
      transfer: transfer,
      cleanupMode: cleanupMode
    )
    if failureProjection.preservesAttemptOwnership {
      deliverFailure(failureProjection.shouldPublishDisconnected)
      return
    }

    guard failureProjection.ownsProjectedSession else {
      deliverFailure(failureProjection.shouldPublishDisconnected)
      return
    }
    let settleHotspot: Bool
    switch failureProjection.cleanupMode {
    case .awaitScopedTerminalCleanup:
      return
    case let .selfContained(requestedSettlement):
      settleHotspot = requestedSettlement
    }
    let finishNativeCleanup = { [weak self] in
      let finish = { [weak self] in
        guard let self else { return }
        guard recordingCardWifiFailureSessionIsCurrent(
          capturedSessionId: transfer.sessionID,
          currentSessionId: self.wifiSessionIdOnMain
        ) else {
          deliverFailure(self.peripheral == nil)
          return
        }
        let shouldPublishDisconnected = self.clearWifiHandoffRuntime(
          retainBackgroundForBleRecovery: false,
          forceEndBackgroundExecution: true
        )
        deliverFailure(shouldPublishDisconnected)
      }
      if Thread.isMainThread { finish() } else { DispatchQueue.main.async(execute: finish) }
    }
    guard settleHotspot else {
      finishNativeCleanup()
      return
    }
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      guard recordingCardWifiFailureSessionIsCurrent(
        capturedSessionId: transfer.sessionID,
        currentSessionId: self.wifiSessionIdOnMain
      ) else {
        deliverFailure(self.peripheral == nil)
        return
      }
      self.finishWifiPreparation(
        errorCode: code,
        disableReadyHotspotIfWritable: true,
        afterHotspotSettled: finishNativeCleanup
      )
    }
  }

  private func projectWifiFailureCleanup(
    transfer: WifiTcpDownload,
    cleanupMode: RecordingCardWifiFailureCleanupMode
  ) -> RecordingCardWifiFailureProjection {
    var projection = RecordingCardWifiFailureProjection(
      ownsProjectedSession: false,
      preservesAttemptOwnership: false,
      cleanupMode: .selfContained(settleHotspot: true),
      shouldPublishDisconnected: false
    )
    let project = {
      let ownsProjectedSession = recordingCardWifiFailureSessionIsCurrent(
        capturedSessionId: transfer.sessionID,
        currentSessionId: self.wifiSessionIdOnMain
      )
      let effectiveCleanupMode = recordingCardEffectiveWifiFailureCleanupMode(
        cleanupMode,
        transferBatchId: transfer.recoveryBatchId,
        transferAttemptId: transfer.attemptId,
        currentBatchId: self.wifiRecoveryBatchId,
        currentAttemptId: self.wifiAttemptId,
        currentAttemptOwned: self.wifiAttemptOwnershipActive
      )
      let preservesAttemptOwnership = ownsProjectedSession
        && effectiveCleanupMode == .awaitScopedTerminalCleanup
      if preservesAttemptOwnership {
        self.wifiSessionOperationInFlightOnMain = false
        self.wifiTransferProgressOnMain = nil
      }
      projection = RecordingCardWifiFailureProjection(
        ownsProjectedSession: ownsProjectedSession,
        preservesAttemptOwnership: preservesAttemptOwnership,
        cleanupMode: effectiveCleanupMode,
        shouldPublishDisconnected: self.peripheral == nil
      )
    }
    if Thread.isMainThread {
      project()
    } else {
      DispatchQueue.main.sync(execute: project)
    }
    return projection
  }

  private func scheduleWifiDownloadTimeout(
    _ transfer: WifiTcpDownload,
    seconds: TimeInterval
  ) {
    transfer.overallTimeoutWorkItem?.cancel()
    let timeout = DispatchWorkItem { [weak self, weak transfer] in
      guard let self, let transfer else { return }
      self.failWifiDownload(
        transfer,
        code: "RECORDING_CARD_WIFI_DOWNLOAD_TIMEOUT",
        message: "Recording-card Wi-Fi download timed out."
      )
    }
    transfer.overallTimeoutWorkItem = timeout
    recordingCardDebugLog(
      "wifi overall timeout scheduled id=\(transfer.capture.correlationID) seconds=\(Int(seconds))"
    )
    wifiTransferQueue.asyncAfter(deadline: .now() + seconds, execute: timeout)
  }

  private func cacheWifiCredentialLease(_ credentials: WifiCredentials) {
    pendingWifiCredentials = credentials
    pendingWifiCredentialTransportGeneration = transportGeneration
    pendingWifiCredentialFingerprint = safeFingerprint
  }

  private func clearWifiCredentialLease() {
    pendingWifiCredentials = nil
    pendingWifiCredentialTransportGeneration = nil
    pendingWifiCredentialFingerprint = nil
  }

  private func discardWifiCredentialLeaseUnlessCurrent() {
    guard recordingCardWifiCredentialLeaseIsReusable(
      observedTransportGeneration: pendingWifiCredentialTransportGeneration,
      currentTransportGeneration: transportGeneration,
      observedFingerprint: pendingWifiCredentialFingerprint,
      currentFingerprint: safeFingerprint
    ) else {
      clearWifiCredentialLease()
      return
    }
  }

  @discardableResult
  private func clearWifiHandoffRuntime(
    retainBackgroundForBleRecovery: Bool = false,
    forceEndBackgroundExecution: Bool = false
  ) -> Bool {
    var shouldPublishDisconnected = false
    let clear = {
      let shouldRetainForRecoverySettlement =
        recordingCardWifiBackgroundLeaseShouldRetainForSettlement(
          retentionRequested: retainBackgroundForBleRecovery,
          scopedAttemptOwned: self.wifiAttemptOwnershipActive,
          bleConnected: self.peripheral != nil
        )
      self.wifiCredentialTimer?.invalidate()
      self.wifiCredentialTimer = nil
      self.clearWifiCredentialLease()
      self.acceptsUnsolicitedWifiCredentials = false
      self.wifiPreparationAcknowledged = false
      self.wifiHotspotEnableMayHaveBeenDispatched = false
      self.wifiBleDisconnectExpected = false
      self.wifiHandoffReady = false
      self.wifiJoinInProgress = false
      self.wifiAttemptOwnershipActive = false
      self.removeJoinedWifiConfiguration()
      self.wifiSessionActiveOnMain = false
      self.wifiSessionIdOnMain = nil
      self.wifiSessionOperationInFlightOnMain = false
      self.wifiTransferProgressOnMain = nil
      if shouldRetainForRecoverySettlement {
        self.retainWifiBackgroundExecutionForBleRecovery()
      } else if recordingCardWifiBackgroundLeaseShouldEnd(
        retainForBleRecovery: shouldRetainForRecoverySettlement,
        forceEnd: forceEndBackgroundExecution || retainBackgroundForBleRecovery,
        awaitingBleRecovery: self.wifiBackgroundLease?.awaitingBleRecovery == true
      ) {
        self.endWifiBackgroundExecution()
      }
      shouldPublishDisconnected = self.peripheral == nil
    }
    if Thread.isMainThread {
      clear()
    } else {
      DispatchQueue.main.sync(execute: clear)
    }
    return shouldPublishDisconnected
  }

  private func scheduleWifiInactivityTimeout(
    _ transfer: WifiTcpDownload,
    seconds: TimeInterval
  ) {
    transfer.inactivityTimeoutWorkItem?.cancel()
    let timeout = DispatchWorkItem { [weak self, weak transfer] in
      guard let self, let transfer else { return }
      self.failWifiDownload(
        transfer,
        code: "RECORDING_CARD_WIFI_NO_PROGRESS_TIMEOUT",
        message: "Recording-card Wi-Fi download stopped making progress."
      )
    }
    transfer.inactivityTimeoutWorkItem = timeout
    wifiTransferQueue.asyncAfter(deadline: .now() + seconds, execute: timeout)
  }

  func deleteFile(_ args: [String: Any]?, result: @escaping FlutterResult) {
    guard isReady else {
      result(error("RECORDING_CARD_NOT_CONNECTED", "Recording card is not connected."))
      return
    }
    guard let filename = args?["deviceFilename"] as? String,
      isSafeFileRequestName(filename),
      let requestPayload = recordingCardFileRequestPayload(filename, seekOffset: 0),
      let deviceFileId = args?["deviceFileId"] as? String
    else {
      result(error("RECORDING_CARD_INVALID_FILE", "Recording-card file payload is invalid."))
      return
    }
    sendCommand(.deleteFile, payload: requestPayload, result: result) { [weak self] payload in
      guard payload.first == 0x00 else {
        throw RecordingCardCommandError.failedAck
      }
      self?.files.removeAll { ($0["deviceFileId"] as? String) == deviceFileId }
      self?.publishSnapshot()
      return ["deleted": true, "deviceFileId": deviceFileId, "deviceFilename": filename]
    }
  }

  func unbindDevice(
    bindingTokenHex: String?,
    deleteDeviceFiles: Bool,
    result: @escaping FlutterResult
  ) {
    guard isReady else {
      result(error("RECORDING_CARD_NOT_CONNECTED", "Recording card is not connected."))
      return
    }
    guard !unbindInProgress else {
      result(error("RECORDING_CARD_UNBIND_IN_PROGRESS", "Recording-card unbind is already in progress."))
      return
    }
    guard recordingState == "idle" else {
      result(error("RECORDING_CARD_UNBIND_RECORDING_ACTIVE", "Stop recording before unbinding the recording card."))
      return
    }
    guard pendingCommands.isEmpty, queuedWritesWithoutResponse.isEmpty,
      offlineCapture == nil, !wifiSessionActiveOnMain, wifiPrepareResult == nil,
      scanResult == nil, connectResult == nil,
      !wifiAttemptOwnershipActive, !wifiBleDisconnectExpected, !wifiHandoffReady
    else {
      result(error("RECORDING_CARD_UNBIND_BUSY", "Finish the active recording-card operation before unbinding."))
      return
    }
    guard let requestedToken = bindingTokenBytes(bindingTokenHex) else {
      result(error("RECORDING_CARD_BINDING_TOKEN_INVALID", "Recording-card binding token is invalid."))
      return
    }

    unbindInProgress = true
    recordingCardDebugLog("unbind started")
    _ = sendCommand(
      .getBindingInfo,
      result: { [weak self] response in
        guard let self else { return }
        if let failure = response as? FlutterError {
          self.finishUnbindFailure(failure, result: result)
          return
        }
        guard let existingPayload = response as? [UInt8] else {
          self.finishUnbindFailure(
            self.error(
              "RECORDING_CARD_UNBIND_BINDING_INFO_INVALID",
              "Recording-card binding information was malformed."
            ),
            result: result
          )
          return
        }
        switch resolveRecordingCardUnbindToken(
          existingPayload: existingPayload,
          requested: requestedToken,
          legacy: Self.legacyBindingToken
        ) {
        case .token:
          self.sendUnbindCommand(
            deleteDeviceFiles: deleteDeviceFiles,
            result: result
          )
        case .alreadyUnbound:
          self.finishUnbindFailure(
            self.error("RECORDING_CARD_ALREADY_UNBOUND", "Recording card is already unbound."),
            result: result
          )
        case .malformed:
          self.finishUnbindFailure(
            self.error(
              "RECORDING_CARD_UNBIND_BINDING_INFO_INVALID",
              "Recording-card binding information was malformed."
            ),
            result: result
          )
        case .conflict:
          self.finishUnbindFailure(
            self.error(
              "RECORDING_CARD_UNBIND_BINDING_CONFLICT",
              "Recording card is bound to a different phone."
            ),
            result: result
          )
        }
      }
    ) { payload in
      payload
    }
  }

  private func sendUnbindCommand(
    deleteDeviceFiles: Bool,
    result: @escaping FlutterResult
  ) {
    guard let activePeripheral = peripheral else {
      finishUnbindFailure(
        error("RECORDING_CARD_NOT_CONNECTED", "Recording card is not connected."),
        result: result
      )
      return
    }
    let payload = recordingCardUnbindPayload(
      deleteDeviceFiles: deleteDeviceFiles
    )
    recordingCardDebugLog(
      "unbind ownership verified; delete files=\(deleteDeviceFiles)"
    )
    unbindDisconnectExpectedID = activePeripheral.identifier
    let dispatched = sendCommand(
      .bindDevice,
      payload: payload,
      result: { [weak self] response in
        guard let self else { return }
        if let failure = response as? FlutterError {
          self.finishUnbindFailure(failure, result: result)
          return
        }
        guard response as? Bool == true else {
          self.finishUnbindFailure(
            self.error(
              "RECORDING_CARD_UNBIND_REJECTED",
              "Recording card rejected the unbind request."
            ),
            result: result
          )
          return
        }
        self.completeSuccessfulUnbind(result: result)
      }
    ) { payload in
      recordingCardUnbindAckAccepted(payload)
    }
    if !dispatched {
      unbindDisconnectExpectedID = nil
    }
  }

  private func finishUnbindFailure(
    _ failure: FlutterError,
    result: @escaping FlutterResult
  ) {
    unbindDisconnectExpectedID = nil
    unbindInProgress = false
    recordingCardDebugLog("unbind failed code=\(failure.code)")
    result(failure)
  }

  private func completeSuccessfulUnbind(result: @escaping FlutterResult) {
    let connectedPeripheral = peripheral
    if let connectedPeripheral, connectedPeripheral.state != .disconnected {
      unbindDisconnectExpectedID = connectedPeripheral.identifier
      central.cancelPeripheralConnection(connectedPeripheral)
    } else {
      unbindDisconnectExpectedID = nil
    }
    clearDeviceRuntimeAfterUnbind()
    unbindInProgress = false
    recordingCardDebugLog("unbind completed")
    publishConnection(state: "disconnected", stage: "idle", message: "录音卡已取消绑定")
    result(baseDeviceMap())
  }

  func disconnect(result: @escaping FlutterResult) {
    finishWifiPreparation(
      errorCode: "RECORDING_CARD_WIFI_DISCONNECTED",
      disableReadyHotspotIfWritable: true
    ) { [weak self] in
      guard let self else {
        result(true)
        return
      }
      self.performExplicitDisconnect(result: result)
    }
  }

  private func performExplicitDisconnect(result: @escaping FlutterResult) {
    resetHandshake()
    connectionAttempt.finish()
    connectTimer?.invalidate()
    connectTimer = nil
    scanTimer?.invalidate()
    scanTimer = nil
    stopActiveScan()
    cancelPendingScanForExplicitDisconnect()
    requestedFingerprint = nil
    requestedBindingToken = nil
    requestedExpectedSerialNumber = nil
    cancelPendingConnectForExplicitDisconnect()
    let hadActiveWifiSession = wifiSessionActiveOnMain
    for timer in commandTimers.values {
      timer.invalidate()
    }
    commandTimers.removeAll()
    queuedWritesWithoutResponse.removeAll()
    if offlineCapture != nil { stopOfflineTransfer() }
    failAllPendingCommands(
      code: "RECORDING_CARD_DISCONNECTED",
      message: "Recording-card disconnected."
    )
    cleanupOfflineCapture(deletePart: true)
    if let peripheral { retireBleTransport(peripheral) }
    peripheral = nil
    clearActiveBleConnectionEpoch()
    transientHandshakeIdentity.clear()
    writeCharacteristic = nil
    controlNotifyCharacteristic = nil
    realtimeNotifyCharacteristic = nil
    offlineNotifyCharacteristic = nil
    pendingNotificationUUIDs.removeAll()
    readyNotificationUUIDs.removeAll()
    safeFingerprint = nil
    deviceName = nil
    decoder.reset()
    resetRecordingRuntime(source: "transportDisconnected")
    publishConnection(state: "disconnected", stage: "idle", message: "录音卡已断开")
    if hadActiveWifiSession {
      wifiTransferQueue.async { [weak self] in
        guard let self else {
          DispatchQueue.main.async { result(true) }
          return
        }
        if let transfer = self.wifiDownload {
          self.failWifiDownload(
            transfer,
            code: "RECORDING_CARD_WIFI_TRANSFER_CANCELLED",
            message: "Recording-card disconnected during Wi-Fi transfer.",
            cleanupMode: .selfContained(settleHotspot: false)
          )
        } else {
          self.clearWifiHandoffRuntime(
            retainBackgroundForBleRecovery: false,
            forceEndBackgroundExecution: true
          )
        }
        DispatchQueue.main.async { result(self.baseDeviceMap()) }
      }
    } else {
      clearWifiHandoffRuntime(
        retainBackgroundForBleRecovery: false,
        forceEndBackgroundExecution: true
      )
      result(baseDeviceMap())
    }
  }

  private func clearDeviceRuntimeAfterUnbind() {
    connectionAttempt.finish()
    connectTimer?.invalidate()
    connectTimer = nil
    scanTimer?.invalidate()
    scanTimer = nil
    stopActiveScan()
    scanResult = nil
    connectResult = nil
    requestedFingerprint = nil
    requestedBindingToken = nil
    requestedExpectedSerialNumber = nil
    clearWifiCredentialLease()
    acceptsUnsolicitedWifiCredentials = false
    wifiPreparationAcknowledged = false
    wifiAttemptOwnershipActive = false
    wifiBleDisconnectExpected = false
    wifiHandoffReady = false
    removeJoinedWifiConfiguration()
    peripheral = nil
    clearActiveBleConnectionEpoch()
    transientHandshakeIdentity.clear()
    writeCharacteristic = nil
    controlNotifyCharacteristic = nil
    realtimeNotifyCharacteristic = nil
    offlineNotifyCharacteristic = nil
    pendingNotificationUUIDs.removeAll()
    readyNotificationUUIDs.removeAll()
    queuedWritesWithoutResponse.removeAll()
    discoveredPeripherals.removeAll()
    discoveredDevices.removeAll()
    safeFingerprint = nil
    deviceName = nil
    batteryPercent = nil
    storageTotalBytes = nil
    storageFreeBytes = nil
    storageUsedBytes = nil
    firmwareVersion = nil
    deviceModel = nil
    recordingFormat = "unknown"
    resetRecordingRuntime(source: "runtimeSnapshot")
    files.removeAll()
    fileRows.removeAll()
    wifiSupported = nil
    wifiFirmwareVersion = nil
    lastInfoRefreshedAt = nil
    decoder.reset()
  }

  func runtimeSnapshotEvent() -> [String: Any] {
    ["type": "runtime_snapshot", "snapshot": runtimeSnapshotMap()]
  }

  func centralManagerDidUpdateState(_ central: RecordingCardCentral) {
    switch central.state {
    case .poweredOn:
      permissionProblem = nil
      publishSnapshot()
      _ = resetRestoredBleTransportsForFreshConnection()
      resumePendingBleWorkAfterRestoredTransportReset()
    case .unauthorized, .poweredOff, .unsupported:
      handleBluetoothUnavailableState()
    default:
      break
    }
  }

  func centralManager(
    _ central: RecordingCardCentral,
    willRestoreState dict: [String: Any]
  ) {
    guard let restored = dict[CBCentralManagerRestoredStatePeripheralsKey]
      as? [RecordingCardPeripheral]
    else { return }
    let verifiedActiveTransport = hasVerifiedActiveBleTransport
    for restoredPeripheral in restored where restoredPeripheral.state != .disconnected {
      if let activePeripheral = peripheral,
        verifiedActiveTransport,
        restoredPeripheral.identifier == activePeripheral.identifier
      {
        continue
      }
      restoredPeripheral.delegate = self
      restoredStalePeripherals[restoredPeripheral.identifier] = restoredPeripheral
    }
    guard !restoredStalePeripherals.isEmpty else {
      if verifiedActiveTransport { publishSnapshot() }
      return
    }
    let awaitingReset = resetRestoredBleTransportsForFreshConnection()
    recordingCardDebugLog("BLE central restored stale transport pendingReset=\(awaitingReset)")
    if connectResult != nil {
      if scanOwner == .connection {
        publishSnapshot()
      } else {
        publishConnection(
          state: "connecting",
          stage: "connecting",
          message: "正在清理已恢复的录音卡连接"
        )
      }
    } else if recordingCardShouldPublishDisconnectedForRestoredState(
      hasVerifiedActiveBleTransport: verifiedActiveTransport
    ) {
      publishConnection(
        state: "disconnected",
        stage: "idle",
        message: "正在清理已恢复的录音卡连接"
      )
    } else {
      publishSnapshot()
    }
    resumePendingBleWorkAfterRestoredTransportReset()
  }

  func centralManager(
    _ central: RecordingCardCentral,
    didDiscover peripheral: RecordingCardPeripheral,
    advertisementData: [String: Any],
    rssi RSSI: NSNumber
  ) {
    guard recordingCardScanOwnerAcceptsDiscovery(scanOwner) else {
      return
    }
    let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
    logManufacturerScanDiagnostic(manufacturerData)
    guard recordingCardManufacturerAdvertisementIsEligible(manufacturerData) else {
      return
    }
    let fingerprint = safeFingerprintFor(peripheral)
    let serialNumber = recordingCardManufacturerAdvertisementSerialNumber(manufacturerData)
    discoveredPeripherals[fingerprint] = peripheral
    let currentRow = discoveredDevices[fingerprint]
    let row = discoveredDeviceMap(
      peripheral: peripheral,
      rssi: RSSI,
      advertisementData: advertisementData,
      fingerprint: fingerprint,
      serialNumber: serialNumber,
      current: currentRow
    )
    discoveredDevices[fingerprint] = row
    if recordingCardDiscoveryRowHasMeaningfulChange(current: currentRow, next: row) {
      publishSnapshot()
    }
    guard scanOwner == .connection, connectResult != nil, self.peripheral == nil else {
      return
    }
    if let requestedFingerprint, requestedFingerprint != fingerprint {
      return
    }
    let explicitlyConnectable = advertisementData[CBAdvertisementDataIsConnectable] as? Bool
    guard explicitlyConnectable != false else { return }
    guard serialNumber != nil
      || (requestedFingerprint != nil && requestedExpectedSerialNumber != nil)
    else { return }
    let name = row["displayName"] as? String
      ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
      ?? peripheral.name
      ?? "花火录音卡"
    connectPeripheral(peripheral, name: name, fingerprint: fingerprint)
  }

  func centralManager(_ central: RecordingCardCentral, didConnect peripheral: RecordingCardPeripheral) {
    if isRestoredStaleTransport(peripheral) {
      recordingCardDebugLog("ignored stale BLE didConnect; cancelling transport")
      central.cancelPeripheralConnection(peripheral)
      return
    }
    if unbindDisconnectExpectedID == peripheral.identifier {
      unbindDisconnectExpectedID = nil
    }
    if self.peripheral === peripheral, connectionState == "connected" { return }
    guard self.peripheral === peripheral, connectResult != nil else {
      recordingCardDebugLog("ignored unexpected BLE didConnect; cancelling transport")
      central.cancelPeripheralConnection(peripheral)
      return
    }
    if restoredTransportLateCallbackPeripherals[peripheral.identifier] === peripheral {
      restoredTransportLateCallbackPeripherals.removeValue(forKey: peripheral.identifier)
      recordingCardDebugLog("retired BLE callback fence cleared by new didConnect")
    }
    activeBleNativeConnectionConfirmed = true
    recordingCardDebugLog("ble connected; discovering service")
    publishConnection(state: "connecting", stage: "connecting", message: "正在发现录音卡服务")
    peripheral.discoverServices([Self.serviceUuid])
  }

  func centralManager(
    _ central: RecordingCardCentral,
    didFailToConnect peripheral: RecordingCardPeripheral,
    error: Error?
  ) {
    if completeRestoredBleTransportReset(for: peripheral, callback: "didFailToConnect") {
      if self.peripheral === peripheral, connectResult != nil,
        !activeBleNativeConnectionConfirmed
      {
        retryActiveConnectionAfterRetiredCallback(
          peripheral,
          callback: "didFailToConnect"
        )
      } else {
        resumePendingBleWorkAfterRestoredTransportReset()
      }
      return
    }
    if forceScanDisconnectExpectedID == peripheral.identifier {
      forceScanDisconnectExpectedID = nil
      recordingCardDebugLog("old BLE transport cancelled before force-scan")
      resumePendingBleWorkAfterRestoredTransportReset()
      return
    }
    guard self.peripheral === peripheral, connectResult != nil else {
      recordingCardDebugLog("ignored inactive BLE didFailToConnect")
      return
    }
    recordingCardDebugLog("ble connect failed nativeError=\(error != nil)")
    finishConnectWithError(
      code: "RECORDING_CARD_CONNECT_FAILED",
      message: "Recording-card BLE connection failed."
    )
  }

  func centralManager(
    _ central: RecordingCardCentral,
    didDisconnectPeripheral peripheral: RecordingCardPeripheral,
    error: Error?
  ) {
    handleBleDisconnect(
      central,
      peripheral: peripheral,
      timestamp: nil,
      error: error
    )
  }

  func centralManager(
    _ central: RecordingCardCentral,
    didDisconnectPeripheral peripheral: RecordingCardPeripheral,
    timestamp: CFAbsoluteTime,
    isReconnecting: Bool,
    error: Error?
  ) {
    handleBleDisconnect(
      central,
      peripheral: peripheral,
      timestamp: timestamp,
      error: error
    )
  }

  private func handleBleDisconnect(
    _ central: RecordingCardCentral,
    peripheral: RecordingCardPeripheral,
    timestamp: CFAbsoluteTime?,
    error: Error?
  ) {
    if self.peripheral === peripheral,
      recordingCardDisconnectPredatesActiveConnection(
        disconnectTimestamp: timestamp,
        activeConnectStartedAt: activeBleConnectStartedAt
      )
    {
      _ = completeRestoredBleTransportReset(
        for: peripheral,
        callback: "staleTimestampedDidDisconnect"
      )
      recordingCardDebugLog("ignored BLE disconnect from an older connection epoch")
      return
    }
    if completeRestoredBleTransportReset(for: peripheral, callback: "didDisconnect") {
      if self.peripheral === peripheral, connectResult != nil,
        !activeBleNativeConnectionConfirmed
      {
        retryActiveConnectionAfterRetiredCallback(
          peripheral,
          callback: "didDisconnect"
        )
      } else {
        resumePendingBleWorkAfterRestoredTransportReset()
      }
      return
    }
    let expectedWifiSwitch = recordingCardWifiBleDisconnectIsExpected(
      hotspotEnableAcknowledged: wifiBleDisconnectExpected,
      handoffReady: wifiHandoffReady,
      wifiSessionActive: wifiSessionActiveOnMain || wifiJoinInProgress
    )
    recordingCardDebugLog(
      "ble disconnected duringSetup=\(connectResult != nil) expectedWifi=\(expectedWifiSwitch) handoffReady=\(wifiHandoffReady) nativeError=\(error != nil)"
    )
    if unbindDisconnectExpectedID == peripheral.identifier {
      let unbindCommand = RecordingCardBleCommand.bindDevice.rawValue
      let commandDispatched = (pendingCommands[unbindCommand]?.dispatchState.count ?? 0) > 0
      let completesUnbind = recordingCardUnbindDisconnectCompletesOperation(
        unbindInProgress: unbindInProgress,
        commandDispatched: commandDispatched
      )
      unbindDisconnectExpectedID = nil
      if completesUnbind, let pending = clearPendingCommand(.bindDevice) {
        recordingCardDebugLog("ble disconnect completed dispatched unbind without ACK")
        pending.result(true)
      } else {
        recordingCardDebugLog("ble disconnected after acknowledged unbind")
      }
      return
    }
    if forceScanDisconnectExpectedID == peripheral.identifier {
      forceScanDisconnectExpectedID = nil
      recordingCardDebugLog("old BLE transport disconnected before force-scan")
      resumePendingBleWorkAfterRestoredTransportReset()
      return
    }
    guard self.peripheral === peripheral else {
      recordingCardDebugLog("ignored inactive BLE didDisconnect")
      return
    }
    forceSettleWifiHotspotDisableAfterPhysicalDisconnect()
    if !expectedWifiSwitch {
      finishWifiPreparation(errorCode: "RECORDING_CARD_WIFI_DISCONNECTED")
      clearWifiCredentialLease()
      acceptsUnsolicitedWifiCredentials = false
    } else if wifiPrepareResult != nil && !wifiHandoffReady {
      finishWifiPreparation(errorCode: "RECORDING_CARD_WIFI_DISCONNECTED")
    }
    if self.peripheral === peripheral {
      self.peripheral = nil
      clearActiveBleConnectionEpoch()
      transientHandshakeIdentity.clear()
      writeCharacteristic = nil
      controlNotifyCharacteristic = nil
      realtimeNotifyCharacteristic = nil
      offlineNotifyCharacteristic = nil
      pendingNotificationUUIDs.removeAll()
      readyNotificationUUIDs.removeAll()
      queuedWritesWithoutResponse.removeAll()
      decoder.reset()
    }
    if expectedWifiSwitch {
      resetRecordingRuntime(source: "transportDisconnected")
      failAllPendingCommands(
        code: "RECORDING_CARD_DISCONNECTED",
        message: "Recording-card switched to Wi-Fi transfer mode."
      )
      cleanupOfflineCapture(deletePart: true)
      publishConnection(
        state: "disconnected",
        stage: "idle",
        message: "录音卡已切换到 Wi-Fi 传输"
      )
    } else if connectResult != nil {
      finishConnectWithError(
        code: "RECORDING_CARD_DISCONNECTED",
        message: "Recording card disconnected during setup."
      )
    } else {
      failAllPendingCommands(
        code: "RECORDING_CARD_DISCONNECTED",
        message: "Recording-card disconnected."
      )
      cleanupOfflineCapture(deletePart: true)
      resetRecordingRuntime(source: "transportDisconnected")
      publishConnection(state: "disconnected", stage: "idle", message: "录音卡已断开")
    }
  }

  func peripheral(_ peripheral: RecordingCardPeripheral, didDiscoverServices error: Error?) {
    guard !shouldIgnoreInactivePeripheralCallback(peripheral, callback: "didDiscoverServices") else {
      return
    }
    guard connectResult != nil, !handshake.inProgress, writeCharacteristic == nil else { return }
    recordingCardDebugLog("services discovered nativeError=\(error != nil)")
    if error != nil {
      finishConnectWithError(
        code: "RECORDING_CARD_SERVICE_DISCOVERY_FAILED",
        message: "Recording-card BLE service discovery failed."
      )
      return
    }
    guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUuid }) else {
      finishConnectWithError(
        code: "RECORDING_CARD_SERVICE_MISSING",
        message: "Recording-card control service is missing."
      )
      return
    }
    peripheral.discoverCharacteristics(
      [
        Self.writeUuid,
        Self.controlNotifyUuid,
        Self.realtimeNotifyUuid,
        Self.offlineNotifyUuid,
      ],
      for: service
    )
  }

  func peripheral(
    _ peripheral: RecordingCardPeripheral,
    didDiscoverCharacteristicsFor service: RecordingCardService,
    error: Error?
  ) {
    guard !shouldIgnoreInactivePeripheralCallback(
      peripheral,
      callback: "didDiscoverCharacteristics"
    ) else {
      return
    }
    guard service.uuid == Self.serviceUuid, connectResult != nil,
      !handshake.inProgress, writeCharacteristic == nil
    else { return }
    recordingCardDebugLog("characteristics discovered nativeError=\(error != nil)")
    if error != nil {
      finishConnectWithError(
        code: "RECORDING_CARD_CHARACTERISTIC_DISCOVERY_FAILED",
        message: "Recording-card characteristics discovery failed."
      )
      return
    }
    for characteristic in service.characteristics ?? [] {
      switch characteristic.uuid {
      case Self.writeUuid:
        writeCharacteristic = characteristic
      case Self.controlNotifyUuid:
        controlNotifyCharacteristic = characteristic
      case Self.realtimeNotifyUuid:
        realtimeNotifyCharacteristic = characteristic
      case Self.offlineNotifyUuid:
        offlineNotifyCharacteristic = characteristic
      default:
        break
      }
    }
    guard let writeCharacteristic,
      let controlNotifyCharacteristic,
      let realtimeNotifyCharacteristic,
      let offlineNotifyCharacteristic
    else {
      finishConnectWithError(
        code: "RECORDING_CARD_PROFILE_INCOMPLETE",
        message: "Recording-card BLE profile is incomplete."
      )
      return
    }
    recordingCardDebugLog(
      "write profile withoutResponse=\(writeCharacteristic.properties.contains(.writeWithoutResponse)) withResponse=\(writeCharacteristic.properties.contains(.write)) maxBytes=\(peripheral.maximumWriteValueLength(for: .withoutResponse)) ready=\(peripheral.canSendWriteWithoutResponse)"
    )
    publishConnection(state: "connecting", stage: "connecting", message: "正在订阅录音卡通知")
    pendingNotificationUUIDs.removeAll()
    readyNotificationUUIDs.removeAll()
    pendingNotificationUUIDs.insert(controlNotifyCharacteristic.uuid)
    pendingNotificationUUIDs.insert(realtimeNotifyCharacteristic.uuid)
    pendingNotificationUUIDs.insert(offlineNotifyCharacteristic.uuid)
    peripheral.setNotifyValue(true, for: controlNotifyCharacteristic)
    peripheral.setNotifyValue(true, for: realtimeNotifyCharacteristic)
    peripheral.setNotifyValue(true, for: offlineNotifyCharacteristic)
  }

  func peripheral(
    _ peripheral: RecordingCardPeripheral,
    didUpdateNotificationStateFor characteristic: RecordingCardCharacteristic,
    error: Error?
  ) {
    guard !shouldIgnoreInactivePeripheralCallback(
      peripheral,
      callback: "didUpdateNotificationState"
    ) else {
      return
    }
    guard ownsCurrentNotificationCharacteristic(characteristic) else {
      recordingCardDebugLog(
        "ignored stale notify-state callback uuid=\(characteristic.uuid.uuidString)"
      )
      return
    }
    guard pendingNotificationUUIDs.contains(characteristic.uuid) else {
      return
    }
    pendingNotificationUUIDs.remove(characteristic.uuid)
    if error != nil || !characteristic.isNotifying {
      recordingCardDebugLog("notify failed uuid=\(characteristic.uuid.uuidString)")
      finishConnectWithError(
        code: "RECORDING_CARD_NOTIFICATION_FAILED",
        message: "Recording-card notification subscription failed."
      )
      return
    }
    readyNotificationUUIDs.insert(characteristic.uuid)
    recordingCardDebugLog(
      "notify ready uuid=\(characteristic.uuid.uuidString) count=\(readyNotificationUUIDs.count)/3"
    )
    finishNotificationSetupIfReady()
  }

  func peripheral(
    _ peripheral: RecordingCardPeripheral,
    didUpdateValueFor characteristic: RecordingCardCharacteristic,
    error: Error?
  ) {
    guard !shouldIgnoreInactivePeripheralCallback(peripheral, callback: "didUpdateValue") else {
      return
    }
    let currentControl = controlNotifyCharacteristic.map { $0 === characteristic } ?? false
    let currentRealtime = realtimeNotifyCharacteristic.map { $0 === characteristic } ?? false
    let currentOffline = offlineNotifyCharacteristic.map { $0 === characteristic } ?? false
    guard currentControl || currentRealtime || currentOffline else {
      recordingCardDebugLog(
        "ignored stale value callback uuid=\(characteristic.uuid.uuidString)"
      )
      return
    }
    guard error == nil else {
      recordingCardDebugLog(
        "notify value failed uuid=\(characteristic.uuid.uuidString) nativeError=true"
      )
      if currentControl { recoverBindingInfoAfterControlFault(reason: "notificationError") }
      return
    }
    guard let data = characteristic.value else {
      recordingCardDebugLog(
        "notify value empty uuid=\(characteristic.uuid.uuidString)"
      )
      if currentControl { recoverBindingInfoAfterControlFault(reason: "notificationEmpty") }
      return
    }
    if currentControl {
      let batch = decoder.push(data)
      if !batch.issues.isEmpty || batch.awaitingBytes != nil {
        recordingCardDebugLog(
          "control decode bytes=\(data.count) packets=\(batch.packets.count) issues=\(batch.issues.count) awaiting=\(batch.awaitingBytes ?? 0) buffered=\(batch.bufferedByteCount)"
        )
      }
      for packet in batch.packets {
        handleControlPacket(packet)
      }
      if batch.issues.contains(where: { $0.requestsBindingInfoRetry }) {
        recoverBindingInfoAfterControlFault(reason: "decodeRejected")
      }
    } else if currentOffline {
      appendOfflineData(data)
    }
  }

  private func ownsCurrentNotificationCharacteristic(
    _ characteristic: RecordingCardCharacteristic
  ) -> Bool {
    if characteristic.uuid == Self.controlNotifyUuid {
      return controlNotifyCharacteristic.map { $0 === characteristic } ?? false
    }
    if characteristic.uuid == Self.realtimeNotifyUuid {
      return realtimeNotifyCharacteristic.map { $0 === characteristic } ?? false
    }
    if characteristic.uuid == Self.offlineNotifyUuid {
      return offlineNotifyCharacteristic.map { $0 === characteristic } ?? false
    }
    return false
  }

  private func recoverBindingInfoAfterControlFault(reason: String) {
    let key = RecordingCardBleCommand.getBindingInfo.rawValue
    guard handshakeCommand == .getBindingInfo, let pending = pendingCommands[key],
      pending.ownership.transportGeneration == transportGeneration,
      recordingCardCanRetryBindingInfo(
        handshakeInProgress: handshake.inProgress,
        unbindInProgress: unbindInProgress,
        dispatchCount: pending.dispatchState.count
      )
    else { return }
    recordingCardDebugLog("binding info recovery requested reason=\(reason)")
    scheduleBindingInfoRetry(for: pending.ownership, after: 0.05)
  }

  func peripheralIsReady(toSendWriteWithoutResponse peripheral: RecordingCardPeripheral) {
    guard !shouldIgnoreInactivePeripheralCallback(
      peripheral,
      callback: "peripheralIsReady"
    ) else {
      return
    }
    recordingCardDebugLog(
      "write without response ready queued=\(queuedWritesWithoutResponse.count)"
    )
    flushQueuedWritesWithoutResponse(for: peripheral)
    if wifiHotspotDisableInFlight {
      attemptTerminalWifiHotspotDisableDispatch(
        generation: wifiHotspotDisableGeneration
      )
    }
  }

  func peripheral(
    _ peripheral: RecordingCardPeripheral,
    didWriteValueFor characteristic: RecordingCardCharacteristic,
    error: Error?
  ) {
    guard self.peripheral === peripheral,
      writeCharacteristic.map({ $0 === characteristic }) == true,
      wifiHotspotDisableInFlight
    else { return }
    wifiHotspotDisableControlFrameObserved = true
    recordingCardDebugLog(
      "wifi terminal hotspot disable write callback error=\(error != nil) without early settlement"
    )
  }

  private var isReady: Bool {
    recordingCardBleTransportIsReady(
      connectionState: connectionState,
      hasWriteCharacteristic: writeCharacteristic != nil,
      peripheralState: peripheral?.state
    )
  }

  private var hasVerifiedActiveBleTransport: Bool {
    isReady
  }

  private func startScan() {
    publishConnection(state: "connecting", stage: "searching", message: "正在搜索录音卡")
    beginManufacturerScanDiagnosticEpoch()
    scanOwner = .connection
    central.scanForPeripherals(withServices: nil, options: [
      CBCentralManagerScanOptionAllowDuplicatesKey: true
    ])
    recordingCardDebugLog("BLE scan started owner=connection duplicates=true")
  }

  private func beginManualScan() {
    beginManufacturerScanDiagnosticEpoch()
    scanOwner = .manual
    central.scanForPeripherals(withServices: nil, options: [
      CBCentralManagerScanOptionAllowDuplicatesKey: true
    ])
    recordingCardDebugLog("BLE scan started owner=manual duplicates=true")
    scanTimer?.invalidate()
    scanTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
      guard let self, self.scanOwner == .manual, let scanResult = self.scanResult else {
        return
      }
      self.stopActiveScan()
      self.scanResult = nil
      scanResult(["devices": Array(self.discoveredDevices.values)])
      self.publishSnapshot()
    }
  }

  private func stopActiveScan() {
    let previousOwner = scanOwner
    scanOwner = .none
    if central.isScanning {
      central.stopScan()
    }
    if previousOwner != .none {
      recordingCardDebugLog("BLE scan stopped")
    }
  }

  private func beginManufacturerScanDiagnosticEpoch() {
    manufacturerScanDiagnosticShapes.removeAll()
  }

  private func logManufacturerScanDiagnostic(_ manufacturerData: Data?) {
    let diagnostic = recordingCardManufacturerAdvertisementDiagnostic(manufacturerData)
    guard manufacturerScanDiagnosticShapes.insert(diagnostic).inserted else { return }
    recordingCardDebugLog(diagnostic)
  }

  private func finishNotificationSetupIfReady() {
    guard pendingNotificationUUIDs.isEmpty else { return }
    let requiredNotifications: Set<CBUUID> = [
      Self.controlNotifyUuid,
      Self.realtimeNotifyUuid,
      Self.offlineNotifyUuid,
    ]
    guard requiredNotifications.isSubset(of: readyNotificationUUIDs) else {
      finishConnectWithError(
        code: "RECORDING_CARD_NOTIFICATION_FAILED",
        message: "Recording-card notification subscription failed."
      )
      return
    }
    guard connectionState != "connected" else { return }
    beginSecureHandshake()
  }

  private func beginSecureHandshake() {
    guard connectResult != nil, handshake.begin() else { return }
    guard let bindingToken = requestedBindingToken, bindingToken.count == 16 else {
      finishConnectWithError(
        code: "RECORDING_CARD_BINDING_TOKEN_INVALID",
        message: "Recording-card binding token is invalid."
      )
      return
    }
    decoder.reset()
    transientHandshakeIdentity.clear()
    recordingCardDebugLog("handshake started")
    publishConnection(state: "connecting", stage: "connecting", message: "正在完成安全连接")
    runHandshakeStep(.getSerial) { [weak self] in
      guard let self else { return }
      guard recordingCardSerialMatchesExpected(
        self.requestedExpectedSerialNumber,
        actual: self.transientHandshakeIdentity.serialNumber
      ) else {
        self.finishConnectWithError(
          code: "RECORDING_CARD_ADVERTISEMENT_SN_MISMATCH",
          message: "Recording-card identity does not match its advertisement."
        )
        return
      }
      self.beginBindingSendWindow()
      self.resolveBindingToken(bindingToken) { [weak self] compatibleToken in
        guard let self else { return }
        self.runHandshakeStep(.bindDevice, payload: compatibleToken + [0x00]) { [weak self] in
          guard let self else { return }
          self.runHandshakeStep(.setTime, payload: self.currentTimePayload()) { [weak self] in
            guard let self else { return }
            self.runHandshakeStep(.setPhoneType, payload: [0x01]) { [weak self] in
              guard let self else { return }
              self.runHandshakeStep(.getDeviceInfo) { [weak self] in
                self?.completeSecureHandshake()
              }
            }
          }
        }
      }
    }
  }

  private func resolveBindingToken(
    _ requestedToken: [UInt8],
    onSuccess: @escaping ([UInt8]) -> Void
  ) {
    guard handshake.inProgress, connectResult != nil else { return }
    handshakeCommand = .getBindingInfo
    sendCommand(.getBindingInfo, result: { [weak self] response in
      guard let self, self.handshake.inProgress, self.connectResult != nil else { return }
      if let failure = response as? FlutterError {
        self.finishConnectWithError(
          code: failure.code,
          message: failure.message ?? "Recording-card binding information could not be read."
        )
        return
      }
      guard let existing = response as? [UInt8],
        let compatible = self.compatibleBindingToken(existing, requested: requestedToken)
      else {
        let failure = RecordingCardHandshakeFailure.bindingInfoMalformed
        self.finishConnectWithError(
          code: failure.code,
          message: failure.safeMessage
        )
        return
      }
      onSuccess(compatible)
    }) { payload in
      guard !payload.isEmpty else { throw RecordingCardHandshakeFailure.bindingInfoMalformed }
      recordingCardDebugLog(
        "binding info bytes=\(payload.count) allZero=\(payload.allSatisfy { $0 == 0 })"
      )
      return payload
    }
  }

  private func beginBindingSendWindow() {
    handshake.receivedSerial(at: ProcessInfo.processInfo.systemUptime)
    let deadline = handshake.bindingDeadline
    bindingSendTimer?.invalidate()
    let timer = Timer(timeInterval: 5, repeats: false) { [weak self] _ in
      guard let self, self.handshake.inProgress,
        self.handshake.bindingDeadline == deadline
      else { return }
      self.bindingSendTimer = nil
      self.recordingCardBindingSendSlaElapsed()
    }
    bindingSendTimer = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  private func recordingCardBindingSendSlaElapsed() {
    recordingCardDebugLog(
      "binding send SLA elapsed command=\(handshakeCommand?.rawValue ?? -1); keeping live transport"
    )
    if let peripheral { flushQueuedWritesWithoutResponse(for: peripheral) }
  }

  private func recordBindingDispatch(at uptime: TimeInterval) {
    guard handshake.dispatchedBinding(at: uptime) else { return }
    bindingSendTimer?.invalidate()
    bindingSendTimer = nil
    recordingCardDebugLog(
      handshake.bindingDispatchMetDeadline == true
        ? "binding command dispatched within SLA"
        : "binding command dispatched after SLA on live transport"
    )
  }

  private func resetHandshake() {
    bindingSendTimer?.invalidate()
    bindingSendTimer = nil
    cancelBindingInfoRetry()
    cancelHandshakeWriteDrain()
    handshake.reset()
    handshakeCommand = nil
  }

  private func compatibleBindingToken(
    _ existingPayload: [UInt8],
    requested: [UInt8]
  ) -> [UInt8]? {
    compatibleRecordingCardBindingToken(
      existingPayload: existingPayload,
      requested: requested,
      legacy: Self.legacyBindingToken
    )
  }

  private func runHandshakeStep(
    _ command: RecordingCardBleCommand,
    payload: [UInt8] = [],
    onSuccess: @escaping () -> Void
  ) {
    guard handshake.inProgress, connectResult != nil else { return }
    handshakeCommand = command
    sendCommand(command, payload: payload, result: { [weak self] response in
      guard let self, self.handshake.inProgress, self.connectResult != nil else { return }
      if let failure = response as? FlutterError {
        self.finishConnectWithError(
          code: failure.code,
          message: failure.message ?? "Recording-card secure handshake failed."
        )
        return
      }
      onSuccess()
    }) { [weak self] payload in
      guard let self else { throw RecordingCardCommandError.failedAck }
      if command == .getSerial {
        guard self.transientHandshakeIdentity.capture(serialPayload: payload) else {
          throw RecordingCardCommandError.failedAck
        }
      }
      if command == .bindDevice,
        let failure = recordingCardBindingAcknowledgementFailure(payload)
      {
        throw failure
      }
      if command == .getDeviceInfo {
        self.applyDeviceInfo(payload)
      }
      return true
    }
  }

  private func completeSecureHandshake() {
    guard connectResult != nil else { return }
    connectionAttempt.finish()
    connectTimer?.invalidate()
    connectTimer = nil
    resetHandshake()
    lastInfoRefreshedAt = isoNow()
    recordingCardDebugLog("handshake completed")
    publishConnection(state: "connected", stage: "connected", message: "录音卡已连接")
    connectResult?(baseDeviceMap())
    connectResult = nil
    requestedBindingToken = nil
    requestedExpectedSerialNumber = nil
    readRecordingState { _ in }
  }

  private func currentTimePayload() -> [UInt8] {
    let values = Calendar.current.dateComponents(
      [.year, .month, .day, .hour, .minute, .second],
      from: Date()
    )
    return [
      UInt8(max(0, min(255, (values.year ?? 2000) - 2000))),
      UInt8(values.month ?? 1),
      UInt8(values.day ?? 1),
      UInt8(values.hour ?? 0),
      UInt8(values.minute ?? 0),
      UInt8(values.second ?? 0),
    ]
  }

  @discardableResult
  private func sendCommand(
    _ command: RecordingCardBleCommand,
    payload: [UInt8] = [],
    result: @escaping FlutterResult,
    timeoutSeconds: TimeInterval = 8,
    onFirstDispatch: ((RecordingCardCommandOwnership, TimeInterval) -> Void)? = nil,
    transform: @escaping ([UInt8]) throws -> Any
  ) -> Bool {
    if unbindInProgress,
      command != .getBindingInfo,
      command != .bindDevice
    {
      result(error("RECORDING_CARD_UNBIND_IN_PROGRESS", "Recording-card unbind is in progress."))
      return false
    }
    guard let peripheral, let writeCharacteristic else {
      result(error("RECORDING_CARD_NOT_CONNECTED", "Recording card is not connected."))
      return false
    }
    let key = command.rawValue
    if pendingCommands[key] != nil {
      result(error("RECORDING_CARD_COMMAND_IN_PROGRESS", "A recording-card command is already running."))
      return false
    }
    guard let writeType = writeType(for: writeCharacteristic) else {
      result(error("RECORDING_CARD_WRITE_UNSUPPORTED", "Recording-card write characteristic is not writable."))
      return false
    }
    let frame = RecordingCardFrameCodec.encode(command: UInt8(key), payload: payload)
    let ownership = nextCommandOwnership()
    let timeoutStartsOnDispatch = recordingCardCommandTimeoutStartsOnDispatch(
      handshakeInProgress: handshake.inProgress,
      unbindInProgress: unbindInProgress
    )
    pendingCommands[key] = PendingCommand(
      ownership: ownership,
      frame: frame,
      timeoutSeconds: timeoutSeconds,
      timeoutStartsOnDispatch: timeoutStartsOnDispatch,
      onFirstDispatch: onFirstDispatch,
      result: result,
      transform: transform
    )
    if !timeoutStartsOnDispatch {
      scheduleCommandTimeout(command, ownership: ownership, after: timeoutSeconds)
    }
    if writeType == .withoutResponse {
      queuedWritesWithoutResponse.append(
        QueuedWriteWithoutResponse(command: key, ownership: ownership, frame: frame)
      )
      recordingCardDebugLog(
        "tx scheduled cmd=\(String(format: "0x%02X", key)) payloadBytes=\(payload.count) ready=\(peripheral.canSendWriteWithoutResponse) queued=\(queuedWritesWithoutResponse.count)"
      )
      flushQueuedWritesWithoutResponse(for: peripheral)
    } else {
      recordingCardDebugLog(
        "tx cmd=\(String(format: "0x%02X", key)) payloadBytes=\(payload.count) write=withResponse"
      )
      let dispatchUptime = ProcessInfo.processInfo.systemUptime
      resetControlDecoderBeforeBindingInfoRetryDispatch(
        command: key,
        ownership: ownership
      )
      peripheral.writeValue(frame, for: writeCharacteristic, type: writeType)
      recordCommandDispatch(command: key, ownership: ownership, at: dispatchUptime)
      if command == .bindDevice, handshake.inProgress {
        recordBindingDispatch(at: dispatchUptime)
      }
    }
    return true
  }

  private func flushQueuedWritesWithoutResponse(for peripheral: RecordingCardPeripheral) {
    guard self.peripheral === peripheral, let writeCharacteristic else {
      queuedWritesWithoutResponse.removeAll()
      cancelHandshakeWriteDrain()
      return
    }
    while peripheral.canSendWriteWithoutResponse, !queuedWritesWithoutResponse.isEmpty {
      let queued = queuedWritesWithoutResponse.removeFirst()
      guard let pending = pendingCommands[queued.command],
        pending.ownership == queued.ownership,
        queued.ownership.transportGeneration == transportGeneration
      else {
        recordingCardDebugLog(
          "tx dropped cmd=\(String(format: "0x%02X", queued.command)) reason=staleRequest"
        )
        continue
      }
      recordingCardDebugLog(
        "tx cmd=\(String(format: "0x%02X", queued.command)) frameBytes=\(queued.frame.count) write=withoutResponse queued=\(queuedWritesWithoutResponse.count)"
      )
      let dispatchUptime = ProcessInfo.processInfo.systemUptime
      resetControlDecoderBeforeBindingInfoRetryDispatch(
        command: queued.command,
        ownership: queued.ownership
      )
      peripheral.writeValue(
        queued.frame,
        for: writeCharacteristic,
        type: .withoutResponse
      )
      recordCommandDispatch(
        command: queued.command,
        ownership: queued.ownership,
        at: dispatchUptime
      )
      if queued.command == RecordingCardBleCommand.bindDevice.rawValue,
        handshake.inProgress
      {
        recordBindingDispatch(at: dispatchUptime)
      }
    }
    if hasOwnedQueuedHandshakeWrite {
      scheduleHandshakeWriteDrain()
    } else {
      cancelHandshakeWriteDrain()
    }
  }

  private func nextCommandOwnership() -> RecordingCardCommandOwnership {
    commandRequestCounter &+= 1
    if commandRequestCounter == 0 { commandRequestCounter &+= 1 }
    return RecordingCardCommandOwnership(
      requestID: commandRequestCounter,
      transportGeneration: transportGeneration
    )
  }

  private func scheduleCommandTimeout(
    _ command: RecordingCardBleCommand,
    ownership: RecordingCardCommandOwnership,
    after timeoutSeconds: TimeInterval
  ) {
    let key = command.rawValue
    commandTimers[key]?.invalidate()
    let timer = Timer(timeInterval: timeoutSeconds, repeats: false) { [weak self] _ in
      DispatchQueue.main.async { [weak self] in
        self?.expireCommand(command, ownership: ownership)
      }
    }
    commandTimers[key] = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  private func expireCommand(
    _ command: RecordingCardBleCommand,
    ownership: RecordingCardCommandOwnership
  ) {
    let key = command.rawValue
    guard let pending = pendingCommands[key], pending.ownership == ownership,
      ownership.transportGeneration == transportGeneration
    else { return }
    pendingCommands.removeValue(forKey: key)
    queuedWritesWithoutResponse.removeAll { $0.ownership == ownership }
    commandTimers[key]?.invalidate()
    commandTimers.removeValue(forKey: key)
    if command == .getBindingInfo { cancelBindingInfoRetry() }
    if command == .requestFile {
      cleanupOfflineCapture(deletePart: true)
      stopOfflineTransfer()
      pending.result(
        error("RECORDING_CARD_DOWNLOAD_TIMEOUT", "Recording-card download timed out.")
      )
      publishSnapshot()
      return
    }
    let code: String
    if handshake.inProgress && command == .bindDevice {
      code = pending.dispatchState.count > 0
        ? "RECORDING_CARD_BINDING_ACK_TIMEOUT"
        : "RECORDING_CARD_WRITE_FAILED"
    } else if handshake.inProgress && command == .getBindingInfo {
      code = pending.dispatchState.count > 0
        ? "RECORDING_CARD_BINDING_INFO_TIMEOUT"
        : "RECORDING_CARD_WRITE_FAILED"
    } else {
      code = "RECORDING_CARD_COMMAND_TIMEOUT"
    }
    pending.result(error(code, "Recording-card command timed out."))
  }

  private func recordCommandDispatch(
    command: Int,
    ownership: RecordingCardCommandOwnership,
    at uptime: TimeInterval
  ) {
    guard var pending = pendingCommands[command], pending.ownership == ownership,
      ownership.transportGeneration == transportGeneration
    else { return }
    let firstDispatch = pending.dispatchState.count == 0
    pending.dispatchState.record(at: uptime)
    pendingCommands[command] = pending
    guard firstDispatch else { return }
    pending.onFirstDispatch?(ownership, uptime)
    if pending.timeoutStartsOnDispatch,
      let typedCommand = RecordingCardBleCommand(rawValue: command)
    {
      scheduleCommandTimeout(
        typedCommand,
        ownership: ownership,
        after: pending.timeoutSeconds
      )
    }
    if command == RecordingCardBleCommand.getBindingInfo.rawValue,
      recordingCardCanRetryBindingInfo(
        handshakeInProgress: handshake.inProgress,
        unbindInProgress: unbindInProgress,
        dispatchCount: pending.dispatchState.count
      )
    {
      scheduleBindingInfoRetry(
        for: ownership,
        after: Self.bindingInfoRetryDelay
      )
    }
  }

  private func scheduleBindingInfoRetry(
    for ownership: RecordingCardCommandOwnership,
    after delay: TimeInterval
  ) {
    let key = RecordingCardBleCommand.getBindingInfo.rawValue
    guard let pending = pendingCommands[key], pending.ownership == ownership,
      ownership.transportGeneration == transportGeneration,
      recordingCardCanRetryBindingInfo(
        handshakeInProgress: handshake.inProgress,
        unbindInProgress: unbindInProgress,
        dispatchCount: pending.dispatchState.count
      )
    else { return }
    let now = ProcessInfo.processInfo.systemUptime
    let requestedDueUptime = now + max(0, delay)
    if bindingInfoRetryTimer != nil,
      let existingDueUptime = bindingInfoRetryDueUptime,
      existingDueUptime <= requestedDueUptime
    {
      return
    }
    let dueUptime = recordingCardBindingInfoRetryDueUptime(
      existingDueUptime: bindingInfoRetryDueUptime,
      now: now,
      delay: delay
    )
    bindingInfoRetryTimer?.invalidate()
    bindingInfoRetryGeneration += 1
    let generation = bindingInfoRetryGeneration
    let timer = Timer(timeInterval: max(0, dueUptime - now), repeats: false) { [weak self] _ in
      DispatchQueue.main.async { [weak self] in
        guard let self, self.bindingInfoRetryGeneration == generation else { return }
        self.bindingInfoRetryTimer = nil
        self.bindingInfoRetryDueUptime = nil
        self.retryBindingInfoQueryIfNeeded(ownership: ownership)
      }
    }
    bindingInfoRetryTimer = timer
    bindingInfoRetryDueUptime = dueUptime
    RunLoop.main.add(timer, forMode: .common)
  }

  private func retryBindingInfoQueryIfNeeded(
    ownership: RecordingCardCommandOwnership
  ) {
    let key = RecordingCardBleCommand.getBindingInfo.rawValue
    guard let pending = pendingCommands[key], pending.ownership == ownership,
      ownership.transportGeneration == transportGeneration,
      recordingCardCanRetryBindingInfo(
        handshakeInProgress: handshake.inProgress,
        unbindInProgress: unbindInProgress,
        dispatchCount: pending.dispatchState.count
      ),
      let peripheral, let writeCharacteristic,
      let controlNotifyCharacteristic, controlNotifyCharacteristic.isNotifying,
      let writeType = writeType(for: writeCharacteristic)
    else { return }
    if writeType == .withoutResponse {
      if !queuedWritesWithoutResponse.contains(where: { $0.ownership == ownership }) {
        queuedWritesWithoutResponse.append(
          QueuedWriteWithoutResponse(
            command: key,
            ownership: ownership,
            frame: pending.frame
          )
        )
        recordingCardDebugLog("binding info retry scheduled")
      }
      flushQueuedWritesWithoutResponse(for: peripheral)
      return
    }
    let dispatchUptime = ProcessInfo.processInfo.systemUptime
    recordingCardDebugLog("binding info retry tx write=withResponse")
    resetControlDecoderBeforeBindingInfoRetryDispatch(
      command: key,
      ownership: ownership
    )
    peripheral.writeValue(pending.frame, for: writeCharacteristic, type: writeType)
    recordCommandDispatch(command: key, ownership: ownership, at: dispatchUptime)
  }

  private func resetControlDecoderBeforeBindingInfoRetryDispatch(
    command: Int,
    ownership: RecordingCardCommandOwnership
  ) {
    guard command == RecordingCardBleCommand.getBindingInfo.rawValue,
      let pending = pendingCommands[command], pending.ownership == ownership,
      ownership.transportGeneration == transportGeneration,
      recordingCardCanRetryBindingInfo(
        handshakeInProgress: handshake.inProgress,
        unbindInProgress: unbindInProgress,
        dispatchCount: pending.dispatchState.count
      )
    else { return }
    decoder.reset()
    recordingCardDebugLog("binding info retry reset partial control frame")
  }

  private func cancelBindingInfoRetry() {
    bindingInfoRetryGeneration += 1
    bindingInfoRetryTimer?.invalidate()
    bindingInfoRetryTimer = nil
    bindingInfoRetryDueUptime = nil
  }

  private var hasOwnedQueuedHandshakeWrite: Bool {
    queuedWritesWithoutResponse.contains { queued in
      guard queued.ownership.transportGeneration == transportGeneration,
        let pending = pendingCommands[queued.command],
        pending.timeoutStartsOnDispatch
      else { return false }
      return pending.ownership == queued.ownership
    }
  }

  private func scheduleHandshakeWriteDrain() {
    guard handshake.inProgress, hasOwnedQueuedHandshakeWrite,
      handshakeWriteDrainTimer == nil
    else { return }
    handshakeWriteDrainGeneration += 1
    let generation = handshakeWriteDrainGeneration
    let transport = transportGeneration
    let timer = Timer(
      timeInterval: Self.handshakeWriteDrainInterval,
      repeats: false
    ) { [weak self] _ in
      guard let self, self.handshakeWriteDrainGeneration == generation,
        self.transportGeneration == transport
      else { return }
      self.handshakeWriteDrainTimer = nil
      guard let peripheral = self.peripheral else { return }
      self.flushQueuedWritesWithoutResponse(for: peripheral)
    }
    handshakeWriteDrainTimer = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  private func cancelHandshakeWriteDrain() {
    handshakeWriteDrainGeneration += 1
    handshakeWriteDrainTimer?.invalidate()
    handshakeWriteDrainTimer = nil
  }

  private func writeType(for characteristic: RecordingCardCharacteristic) -> CBCharacteristicWriteType? {
    if characteristic.properties.contains(.writeWithoutResponse) {
      return .withoutResponse
    }
    if characteristic.properties.contains(.write) {
      return .withResponse
    }
    return nil
  }

  private func handleControlPacket(_ packet: RecordingCardPacket) {
    let command = Int(packet.command)
    let status = recordingCardControlStatusForDiagnostic(
      command: packet.command,
      payload: packet.payload
    )
    recordingCardDebugLog(
      "rx cmd=\(String(format: "0x%02X", command)) payloadBytes=\(packet.payload.count) status=\(status) pending=\(pendingCommands[command] != nil)"
    )
    if packet.command == RecordingCardBleCommand.enableWifi.rawValue,
      wifiHotspotDisableInFlight
    {
      wifiHotspotDisableControlFrameObserved = true
      recordingCardDebugLog(
        "wifi terminal hotspot disable control frame observed without early settlement"
      )
      return
    }
    if packet.command == RecordingCardBleCommand.wifiCredentials.rawValue {
      guard recordingCardShouldAcceptWifiCredentials(
        preparationInFlight: wifiPrepareResult != nil,
        unsolicitedGateOpen: acceptsUnsolicitedWifiCredentials
      ) else {
        recordingCardDebugLog("ignored stale Wi-Fi credentials outside preparation")
        return
      }
      if let credentials = parseWifiCredentials(packet.payload) {
        cacheWifiCredentialLease(credentials)
        recordingCardDebugLog(
          "wifi credentials cached for current transport activePreparation=\(wifiPrepareResult != nil) ssidBytes=\(credentials.ssid.utf8.count) passwordBytes=\(credentials.password.utf8.count)"
        )
        if wifiPrepareResult != nil {
          finishWifiPreparationIfPossible()
        }
      } else {
        recordingCardDebugLog("wifi credentials rejected payloadBytes=\(packet.payload.count)")
      }
      return
    }
    if packet.command == RecordingCardBleCommand.getDeviceInfo.rawValue,
      pendingCommands[command] == nil
    {
      applyDeviceInfo(packet.payload)
    } else if packet.command == RecordingCardBleCommand.getRecordingInfo.rawValue,
      pendingCommands[command] == nil
    {
      applyRecordingInfo(packet.payload)
    } else if packet.command == RecordingCardBleCommand.deviceStatusChanged.rawValue {
      if packet.payload.count > 1 {
        batteryPercent = sanitizeBattery(Int(packet.payload[1]))
      }
      recordingCardDebugLog(
        "status notification metadata-only payloadBytes=\(packet.payload.count)"
      )
      publishSnapshot()
      publishRecordingStateInvalidated()
    } else if pendingCommands[command] == nil,
      let parsed = recordingCardRecordingCommandPayload(
        command: packet.command,
        payload: packet.payload
      )
    {
      applyRecordingPayload(parsed, source: "statusNotification")
      publishRecording()
    }

    if packet.command == RecordingCardBleCommand.requestFile.rawValue,
      let pending = pendingCommands[command],
      pending.ownership.transportGeneration == transportGeneration
    {
      if packet.payload.first == 0x02 {
        guard let capture = offlineCapture, capture.acknowledged else {
          failOfflineCapture(
            code: "RECORDING_CARD_FILE_REQUEST_REJECTED",
            message: "Recording-card file request ended before acknowledgement."
          )
          return
        }
        guard capture.request.targetBytes > 0,
          capture.receivedBytes == capture.request.targetBytes
        else {
          failOfflineCapture(
            code: "RECORDING_CARD_DOWNLOAD_INCOMPLETE",
            message: "Recording-card file ended before its resolved size."
          )
          return
        }
        completeOfflineCapture(capture)
        return
      }
      do {
        _ = try pending.transform(packet.payload)
      } catch let failure as FileRequestFailure {
        failOfflineCapture(
          code: failure.code,
          message: failure.safeMessage
        )
      } catch {
        failOfflineCapture(
          code: "RECORDING_CARD_FILE_REQUEST_ACK_MALFORMED",
          message: "Recording-card file request acknowledgement was malformed."
        )
      }
      return
    }

    // File lists are streamed as one or more 0x00 rows followed by a 0x02
    // terminator. Keep the pending command alive until that terminator arrives.
    if packet.command == RecordingCardBleCommand.listFiles.rawValue,
      let pending = pendingCommands[command],
      pending.ownership.transportGeneration == transportGeneration
    {
      do {
        let response = try pending.transform(packet.payload)
        guard packet.payload.first == 0x02 else { return }
        takePendingCommand(key: command)?.result(response)
      } catch {
        takePendingCommand(key: command)?.result(
          self.error("RECORDING_CARD_COMMAND_REJECTED", "Recording-card command was rejected.")
        )
      }
      return
    }

    guard let pending = takePendingCommand(key: command) else { return }
    do {
      pending.result(try pending.transform(packet.payload))
    } catch {
      if let failure = error as? RecordingCardHandshakeFailure {
        pending.result(self.error(failure.code, failure.safeMessage))
      } else {
        pending.result(self.error("RECORDING_CARD_COMMAND_REJECTED", "Recording-card command was rejected."))
      }
    }
  }

  private func ownsWifiPreparation(_ generation: Int) -> Bool {
    generation == wifiPreparationGeneration && wifiPrepareResult != nil
  }

  private func finishWifiPreparationIfPossible(
    expectedGeneration: Int? = nil
  ) {
    let generation = expectedGeneration ?? wifiPreparationGeneration
    guard ownsWifiPreparation(generation) else { return }
    guard wifiPreparationAcknowledged, let credentials = pendingWifiCredentials,
      let result = wifiPrepareResult
    else { return }
    wifiCredentialTimer?.invalidate()
    wifiCredentialTimer = nil
    wifiPrepareResult = nil
    wifiPreparationAcknowledged = false
    acceptsUnsolicitedWifiCredentials = false
    wifiPreparationGeneration &+= 1
    wifiBleDisconnectExpected = true
    wifiHandoffReady = true
    publishConnection(
      state: "disconnected",
      stage: "idle",
      message: "录音卡已切换到 Wi-Fi 传输"
    )
    recordingCardDebugLog("wifi preparation completed")
    result(["ssid": credentials.ssid, "password": credentials.password])
  }

  private func finishWifiPreparation(
    errorCode: String,
    expectedGeneration: Int? = nil,
    disableReadyHotspotIfWritable: Bool = false,
    afterHotspotSettled: (() -> Void)? = nil
  ) {
    if let expectedGeneration, expectedGeneration != wifiPreparationGeneration {
      afterHotspotSettled?()
      return
    }
    if wifiHotspotDisableInFlight {
      if let afterHotspotSettled {
        wifiHotspotDisableSettlements.append(afterHotspotSettled)
      }
      return
    }
    wifiCredentialTimer?.invalidate()
    wifiCredentialTimer = nil
    let result = wifiPrepareResult
    let shouldDisableHotspot = recordingCardWifiPreparationFailureShouldDisableHotspot(
      hotspotEnableAcknowledged: wifiPreparationAcknowledged,
      hotspotEnableMayHaveBeenDispatched: wifiHotspotEnableMayHaveBeenDispatched,
      handoffReady: wifiHandoffReady,
      bleWritable: peripheral?.state == .connected && writeCharacteristic != nil,
      disableReadyHandoff: disableReadyHotspotIfWritable
    )
    if result != nil { _ = clearPendingCommand(.enableWifi) }
    wifiPrepareResult = nil
    wifiPreparationAcknowledged = false
    clearWifiCredentialLease()
    acceptsUnsolicitedWifiCredentials = false
    wifiHandoffReady = false
    wifiPreparationGeneration &+= 1
    if result != nil {
      recordingCardDebugLog("wifi preparation failed code=\(errorCode)")
    }
    var settlements: [() -> Void] = []
    if let result {
      settlements.append { [weak self] in
        guard let self else {
          result(FlutterError(
            code: errorCode,
            message: "Recording-card Wi-Fi preparation failed.",
            details: nil
          ))
          return
        }
        result(self.error(errorCode, "Recording-card Wi-Fi preparation failed."))
      }
    }
    if let afterHotspotSettled { settlements.append(afterHotspotSettled) }
    switch recordingCardWifiHotspotDisableSettlementAction(
      disableInFlight: wifiHotspotDisableInFlight,
      shouldDisable: shouldDisableHotspot
    ) {
    case .awaitInFlight:
      wifiHotspotDisableSettlements.append(contentsOf: settlements)
    case .completeImmediately:
      wifiBleDisconnectExpected = false
      wifiHotspotEnableMayHaveBeenDispatched =
        recordingCardWifiHotspotMayBeEnabled(
          current: wifiHotspotEnableMayHaveBeenDispatched,
          event: .terminalSettled
        )
      settlements.forEach { $0() }
    case .beginDisable:
      wifiHotspotDisableSettlements.append(contentsOf: settlements)
      beginTerminalWifiHotspotDisable()
    }
  }

  private func beginTerminalWifiHotspotDisable() {
    wifiHotspotDisableInFlight = true
    wifiBleDisconnectExpected = true
    wifiHotspotDisableGeneration &+= 1
    if wifiHotspotDisableGeneration == 0 { wifiHotspotDisableGeneration &+= 1 }
    let generation = wifiHotspotDisableGeneration
    wifiHotspotDisableDispatchTimer?.invalidate()
    wifiHotspotDisableSettlementTimer?.invalidate()
    wifiHotspotDisableDidDispatch = false
    wifiHotspotDisableControlFrameObserved = false
    wifiHotspotDisableDispatchDeadlineUptime =
      ProcessInfo.processInfo.systemUptime + Self.wifiTerminalDisableWindow
    recordingCardDebugLog(
      "wifi terminal hotspot disable awaiting dispatch generation=\(generation)"
    )
    attemptTerminalWifiHotspotDisableDispatch(generation: generation)
  }

  private func attemptTerminalWifiHotspotDisableDispatch(generation: UInt64) {
    guard recordingCardWifiTerminalDisableTimerIsCurrent(
      capturedGeneration: generation,
      currentGeneration: wifiHotspotDisableGeneration,
      disableInFlight: wifiHotspotDisableInFlight
    ) else { return }
    guard !wifiHotspotDisableDidDispatch else { return }
    guard let peripheral, peripheral.state == .connected,
      let writeCharacteristic,
      let writeType = writeType(for: writeCharacteristic)
    else {
      completeWifiHotspotDisableSettlement(expectedGeneration: generation)
      return
    }
    if writeType == .withoutResponse && !peripheral.canSendWriteWithoutResponse {
      let now = ProcessInfo.processInfo.systemUptime
      guard now < (wifiHotspotDisableDispatchDeadlineUptime ?? now) else {
        recordingCardDebugLog(
          "wifi terminal hotspot disable dispatch deadline reached generation=\(generation)"
        )
        completeWifiHotspotDisableSettlement(expectedGeneration: generation)
        return
      }
      let timer = Timer(
        timeInterval: Self.wifiTerminalDisableDispatchPoll,
        repeats: false
      ) { [weak self] _ in
        self?.attemptTerminalWifiHotspotDisableDispatch(generation: generation)
      }
      wifiHotspotDisableDispatchTimer?.invalidate()
      wifiHotspotDisableDispatchTimer = timer
      RunLoop.main.add(timer, forMode: .common)
      return
    }
    wifiHotspotDisableDispatchTimer?.invalidate()
    wifiHotspotDisableDispatchTimer = nil
    wifiHotspotDisableDispatchDeadlineUptime = nil
    wifiHotspotDisableDidDispatch = true
    let frame = RecordingCardFrameCodec.encode(
      command: UInt8(RecordingCardBleCommand.enableWifi.rawValue),
      payload: [0x00]
    )
    peripheral.writeValue(frame, for: writeCharacteristic, type: writeType)
    recordingCardDebugLog(
      "wifi terminal hotspot disable dispatched generation=\(generation)"
    )
    let timer = Timer(
      timeInterval: Self.wifiTerminalDisableWindow,
      repeats: false
    ) { [weak self] _ in
      self?.completeWifiHotspotDisableSettlement(expectedGeneration: generation)
    }
    wifiHotspotDisableSettlementTimer?.invalidate()
    wifiHotspotDisableSettlementTimer = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  private func forceSettleWifiHotspotDisableAfterPhysicalDisconnect() {
    guard wifiHotspotDisableInFlight else { return }
    recordingCardDebugLog(
      "wifi terminal hotspot disable force-settled by BLE disconnect generation=\(wifiHotspotDisableGeneration)"
    )
    completeWifiHotspotDisableSettlement(
      expectedGeneration: wifiHotspotDisableGeneration,
      deferCallbacks: true
    )
  }

  private func completeWifiHotspotDisableSettlement(
    expectedGeneration: UInt64,
    deferCallbacks: Bool = false
  ) {
    guard recordingCardWifiTerminalDisableTimerIsCurrent(
      capturedGeneration: expectedGeneration,
      currentGeneration: wifiHotspotDisableGeneration,
      disableInFlight: wifiHotspotDisableInFlight
    ) else { return }
    wifiHotspotDisableDispatchTimer?.invalidate()
    wifiHotspotDisableDispatchTimer = nil
    wifiHotspotDisableSettlementTimer?.invalidate()
    wifiHotspotDisableSettlementTimer = nil
    wifiHotspotDisableDispatchDeadlineUptime = nil
    wifiHotspotDisableDidDispatch = false
    wifiHotspotDisableInFlight = false
    wifiBleDisconnectExpected = false
    wifiHotspotEnableMayHaveBeenDispatched =
      recordingCardWifiHotspotMayBeEnabled(
        current: wifiHotspotEnableMayHaveBeenDispatched,
        event: .terminalSettled
      )
    wifiHotspotDisableGeneration &+= 1
    let settlements = wifiHotspotDisableSettlements
    wifiHotspotDisableSettlements.removeAll(keepingCapacity: false)
    recordingCardDebugLog(
      "wifi terminal hotspot disable settled observedControl=\(wifiHotspotDisableControlFrameObserved)"
    )
    wifiHotspotDisableControlFrameObserved = false
    if deferCallbacks {
      DispatchQueue.main.async { settlements.forEach { $0() } }
    } else {
      settlements.forEach { $0() }
    }
  }

  private func scheduleWifiCredentialTimeout(preparationGeneration: Int) {
    wifiCredentialTimer?.invalidate()
    wifiCredentialTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { [weak self] _ in
      self?.finishWifiPreparation(
        errorCode: "RECORDING_CARD_WIFI_CREDENTIALS_TIMEOUT",
        expectedGeneration: preparationGeneration
      )
    }
  }

  private func parseWifiCredentials(_ payload: [UInt8]) -> WifiCredentials? {
    guard let parts = recordingCardWifiCredentialParts(payload: payload) else { return nil }
    return WifiCredentials(ssid: parts.ssid, password: parts.password)
  }

  private func parseDownloadRequest(_ args: [String: Any]?) -> DownloadRequest? {
    guard let args,
      let deviceFilename = args["deviceFilename"] as? String,
      let localFileKey = args["localFileKey"] as? String,
      isSafeFileRequestName(deviceFilename),
      isSafeFilename(localFileKey),
      let format = recordingFormatFor(
        filename: deviceFilename,
        requestedFormat: args["format"] as? String
      )
    else {
      return nil
    }
    let sizeConfidence = args["sizeConfidence"] as? String
    guard sizeConfidence == nil || sizeConfidence == "trusted" || sizeConfidence == "suspect" else {
      return nil
    }
    return DownloadRequest(
      deviceFilename: deviceFilename,
      localFileKey: localFileKey,
      directorySizeBytes: positiveInteger(args["sizeBytes"]),
      sizeConfidence: sizeConfidence,
      targetBytes: 0,
      durationSeconds: nonNegativeInteger(args["durationSeconds"]),
      format: format
    )
  }

  private func parseWifiProgressContext(
    _ args: [String: Any]?
  ) -> WifiProgressContext? {
    guard let args else { return WifiProgressContext() }
    let batchID: String?
    if args["batchId"] == nil {
      batchID = nil
    } else {
      guard let parsed = safeWifiIdentifier(args["batchId"]) else { return nil }
      batchID = parsed
    }
    let fileIndex = nonNegativeInteger(args["fileIndex"])
    let fileCount = positiveInteger(args["fileCount"])
    guard (args["fileIndex"] == nil) == (args["fileCount"] == nil),
      fileIndex == nil || fileIndex! < fileCount!
    else { return nil }
    let aggregateReceivedBase = nonNegativeInteger(args["aggregateReceivedBytes"])
    let aggregateTotalBytes = positiveInteger(args["aggregateTotalBytes"])
    guard args["aggregateReceivedBytes"] == nil || aggregateReceivedBase != nil,
      args["aggregateTotalBytes"] == nil || aggregateTotalBytes != nil,
      aggregateReceivedBase == nil || aggregateTotalBytes == nil
        || aggregateReceivedBase! <= aggregateTotalBytes!
    else { return nil }
    return WifiProgressContext(
      batchID: batchID,
      fileIndex: fileIndex,
      fileCount: fileCount,
      aggregateReceivedBase: aggregateReceivedBase,
      aggregateTotalBytes: aggregateTotalBytes
    )
  }

  private func createOfflineCapture(_ request: DownloadRequest, plannedNativeFileId: String? = nil) -> OfflineCapture? {
    do {
      if let plannedNativeFileId,
        plannedNativeFileId.range(of: "^card-[a-f0-9]{32}$", options: .regularExpression) == nil { return nil }
      let fileID = plannedNativeFileId ?? ("card-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())
      let applicationSupport = try FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
      )
      let directory = applicationSupport
        .appendingPathComponent("HuahuoAI", isDirectory: true)
        .appendingPathComponent("Recordings", isDirectory: true)
        .appendingPathComponent("RecordingCard", isDirectory: true)
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
      )
      let sourceName = "\(fileID).\(request.format)"
      let partURL = directory.appendingPathComponent("\(sourceName).part")
      let finalURL = directory.appendingPathComponent(sourceName)
      if plannedNativeFileId != nil && FileManager.default.fileExists(atPath: finalURL.path) { return nil }
      try? FileManager.default.removeItem(at: partURL)
      try? FileManager.default.removeItem(at: finalURL)
      guard FileManager.default.createFile(atPath: partURL.path, contents: nil) else {
        return nil
      }
      return OfflineCapture(
        request: request,
        fileID: fileID,
        appPrivateURI: "app-private://recording-card/\(sourceName)",
        displayName: displayNameFor(request.deviceFilename, format: request.format),
        partURL: partURL,
        finalURL: finalURL,
        output: try FileHandle(forWritingTo: partURL)
      )
    } catch {
      return nil
    }
  }

  private func appendOfflineData(_ value: Data) {
    guard let capture = offlineCapture, !value.isEmpty else { return }
    scheduleDownloadInactivityTimeout()
    guard capture.acknowledged else {
      let nextCount = capture.preAckBytes + value.count
      guard nextCount <= Self.maxPreAckBytes else {
        failOfflineCapture(
          code: "RECORDING_CARD_DOWNLOAD_PROTOCOL_ORDER",
          message: "Recording-card file data arrived before a usable acknowledgement."
        )
        return
      }
      capture.preAckChunks.append(value)
      capture.preAckBytes = nextCount
      return
    }
    guard capture.receivedBytes < capture.request.targetBytes else { return }
    let remaining = capture.request.targetBytes - capture.receivedBytes
    let acceptedCount = min(value.count, remaining)
    guard acceptedCount > 0 else { return }
    let acceptedData = Data(value.prefix(acceptedCount))
    do {
      try writeAll(acceptedData, to: capture.output)
      capture.digest.update(data: acceptedData)
      capture.receivedBytes += acceptedCount
      publishTransferProgress(
        capture,
        force: capture.receivedBytes == capture.request.targetBytes
      )
    } catch {
      failOfflineCapture(
        code: "RECORDING_CARD_LOCAL_STORAGE_FAILED",
        message: "Recording-card download could not write private storage."
      )
      return
    }
    guard capture.receivedBytes == capture.request.targetBytes else { return }
    capture.dataComplete = true
    stopOfflineTransfer()
    if capture.acknowledged {
      completeOfflineCapture(capture)
    }
  }

  private func writeAll(_ data: Data, to output: FileHandle) throws {
    try data.withUnsafeBytes { rawBuffer in
      guard let baseAddress = rawBuffer.baseAddress else { return }
      var writtenBytes = 0
      while writtenBytes < data.count {
        let written = Darwin.write(
          output.fileDescriptor,
          baseAddress.advanced(by: writtenBytes),
          data.count - writtenBytes
        )
        guard written > 0 else {
          throw RecordingCardLocalFileError.writeFailed
        }
        writtenBytes += written
      }
    }
  }

  private func completeOfflineCapture(_ capture: OfflineCapture) {
    guard offlineCapture === capture else { return }
    guard let pending = pendingCommands[RecordingCardBleCommand.requestFile.rawValue] else {
      cleanupOfflineCapture(deletePart: true)
      return
    }
    do {
      let digest = capture.digest
      let streamedContentHash = digest.finalize()
        .map { String(format: "%02x", $0) }
        .joined()
      let committed = try recordingCardCommitDownloadedPart(
        output: capture.output,
        partURL: capture.partURL,
        finalURL: capture.finalURL,
        expectedSize: capture.request.targetBytes,
        streamedContentHash: streamedContentHash
      )
      let contentHash = committed.contentHash
      offlineCapture = nil
      _ = clearPendingCommand(.requestFile)
      stopOfflineTransfer()
      recordingCardDebugLog(
        "ble file completed id=\(capture.correlationID) targetBytes=\(capture.request.targetBytes) acceptedBytes=\(capture.receivedBytes) errorCode=none"
      )
      var response: [String: Any] = [
        "localFileKey": capture.request.localFileKey,
        "localFileId": capture.fileID,
        "appPrivateUri": capture.appPrivateURI,
        "displayName": capture.displayName,
        "sizeBytes": capture.request.targetBytes,
        "contentHash": contentHash,
        "format": capture.request.format,
        "mimeType": mimeTypeFor(capture.request.format),
      ]
      if let durationSeconds = capture.request.durationSeconds {
        response["durationSeconds"] = durationSeconds
      }
      pending.result(response)
      publishSnapshot()
    } catch let failure as RecordingCardDownloadedFileCommitError {
      failOfflineCapture(
        code: failure.code,
        message: "Recording-card download could not durably commit private storage."
      )
    } catch {
      failOfflineCapture(
        code: "RECORDING_CARD_LOCAL_STORAGE_FAILED",
        message: "Recording-card download could not commit private storage."
      )
    }
  }

  private func failOfflineCapture(code: String, message: String) {
    if let capture = offlineCapture {
      recordingCardDebugLog(
        "ble file failed id=\(capture.correlationID) targetBytes=\(capture.request.targetBytes) acceptedBytes=\(capture.receivedBytes) errorCode=\(code)"
      )
    }
    cleanupOfflineCapture(deletePart: true)
    stopOfflineTransfer()
    completeCommandWithError(.requestFile, code: code, message: message)
    publishSnapshot()
  }

  private func cleanupOfflineCapture(deletePart: Bool) {
    offlineInactivityTimer?.invalidate()
    offlineInactivityTimer = nil
    guard let capture = offlineCapture else { return }
    offlineCapture = nil
    try? capture.output.close()
    if deletePart {
      try? FileManager.default.removeItem(at: capture.partURL)
    }
  }

  private func scheduleDownloadTimeouts(sizeBytes: Int) {
    let key = RecordingCardBleCommand.requestFile.rawValue
    guard let ownership = pendingCommands[key]?.ownership else { return }
    commandTimers[key]?.invalidate()
    let timer = Timer(timeInterval: downloadOverallTimeout(sizeBytes), repeats: false) {
      [weak self] _ in
      DispatchQueue.main.async { [weak self] in
        guard let self, self.pendingCommands[key]?.ownership == ownership,
          ownership.transportGeneration == self.transportGeneration
        else { return }
        self.failOfflineCapture(
          code: "RECORDING_CARD_DOWNLOAD_TIMEOUT",
          message: "Recording-card download timed out."
        )
      }
    }
    commandTimers[key] = timer
    RunLoop.main.add(timer, forMode: .common)
    scheduleDownloadInactivityTimeout()
  }

  private func scheduleDownloadInactivityTimeout() {
    let key = RecordingCardBleCommand.requestFile.rawValue
    guard let ownership = pendingCommands[key]?.ownership else { return }
    offlineInactivityTimer?.invalidate()
    let timer = Timer(timeInterval: Self.downloadInactivityTimeout, repeats: false) {
      [weak self] _ in
      DispatchQueue.main.async { [weak self] in
        guard let self, self.pendingCommands[key]?.ownership == ownership,
          ownership.transportGeneration == self.transportGeneration
        else { return }
        self.failOfflineCapture(
          code: "RECORDING_CARD_DOWNLOAD_INACTIVITY_TIMEOUT",
          message: "Recording-card download stopped making progress."
        )
      }
    }
    offlineInactivityTimer = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  private func publishTransferProgress(
    _ capture: OfflineCapture,
    force: Bool = false,
    now: TimeInterval = ProcessInfo.processInfo.systemUptime
  ) {
    if !force,
      now - capture.lastProgressPublishUptime < Self.wifiProgressPublishInterval
    {
      return
    }
    capture.lastProgressPublishUptime = now
    onEvent?([
      "type": "transfer_progress",
      "progress": transferProgressMap(capture, now: now),
    ])
  }

  private func stopOfflineTransfer() {
    guard let peripheral, let writeCharacteristic,
      let writeType = writeType(for: writeCharacteristic)
    else {
      return
    }
    let frame = RecordingCardFrameCodec.encode(
      command: UInt8(RecordingCardBleCommand.stopFileTransfer.rawValue),
      payload: []
    )
    peripheral.writeValue(frame, for: writeCharacteristic, type: writeType)
  }

  private func clearPendingCommand(_ command: RecordingCardBleCommand) -> PendingCommand? {
    let key = command.rawValue
    let pending = takePendingCommand(key: key)
    if command == .requestFile {
      offlineInactivityTimer?.invalidate()
      offlineInactivityTimer = nil
    }
    return pending
  }

  private func takePendingCommand(key: Int) -> PendingCommand? {
    guard let pending = pendingCommands[key],
      pending.ownership.transportGeneration == transportGeneration
    else { return nil }
    pendingCommands.removeValue(forKey: key)
    queuedWritesWithoutResponse.removeAll { $0.ownership == pending.ownership }
    commandTimers[key]?.invalidate()
    commandTimers.removeValue(forKey: key)
    if key == RecordingCardBleCommand.getBindingInfo.rawValue {
      cancelBindingInfoRetry()
    }
    return pending
  }

  private func completeCommandWithError(
    _ command: RecordingCardBleCommand,
    code: String,
    message: String
  ) {
    clearPendingCommand(command)?.result(error(code, message))
  }

  private func failAllPendingCommands(code: String, message: String) {
    let pending = Array(pendingCommands.values)
    pendingCommands.removeAll()
    queuedWritesWithoutResponse.removeAll()
    cancelBindingInfoRetry()
    cancelHandshakeWriteDrain()
    for timer in commandTimers.values {
      timer.invalidate()
    }
    commandTimers.removeAll()
    for command in pending {
      command.result(error(code, message))
    }
  }

  private func recordingFormatFor(filename: String, requestedFormat: String?) -> String? {
    let lower = filename.lowercased()
    if lower.hasSuffix(".mp3") { return "mp3" }
    if lower.hasSuffix(".opus") { return "opus" }
    if lower.hasSuffix(".m4a") || lower.hasSuffix(".mp4") { return "m4a" }
    if lower.hasSuffix(".wav") { return "wav" }
    let allowed = Set(["mp3", "opus", "m4a", "wav"])
    if let requested = requestedFormat?.lowercased(), allowed.contains(requested) {
      return requested
    }
    let deviceFormat = recordingFormat.lowercased()
    return allowed.contains(deviceFormat) ? deviceFormat : nil
  }

  private func displayNameFor(_ filename: String, format: String) -> String {
    let lower = filename.lowercased()
    if lower.hasSuffix(".mp3") || lower.hasSuffix(".opus") || lower.hasSuffix(".m4a") ||
      lower.hasSuffix(".mp4") || lower.hasSuffix(".wav")
    {
      return filename
    }
    return "\(filename).\(format)"
  }

  private func mimeTypeFor(_ format: String) -> String {
    switch format {
    case "mp3":
      return "audio/mpeg"
    case "opus":
      return "audio/opus"
    case "m4a":
      return "audio/mp4"
    case "wav":
      return "audio/wav"
    default:
      return "application/octet-stream"
    }
  }

  private func downloadOverallTimeout(_ sizeBytes: Int) -> TimeInterval {
    let estimatedSeconds = ((sizeBytes + 59_999) / 60_000) + 15
    return max(
      Self.downloadOverallMinimum,
      min(TimeInterval(estimatedSeconds), Self.downloadOverallMaximum)
    )
  }

  private func applyDeviceInfo(
    _ payload: [UInt8],
    applyRecordingState: Bool = true
  ) {
    if payload.count >= 4 {
      let totalMb = readUInt32(payload, offset: 0)
      if totalMb > 0 && totalMb < 1024 * 1024 {
        storageTotalBytes = totalMb * 1024 * 1024
      }
    }
    if payload.count >= 8 {
      let freeMb = readUInt32(payload, offset: 4)
      if freeMb >= 0 && freeMb < 1024 * 1024 {
        storageFreeBytes = freeMb * 1024 * 1024
      }
    }
    if let total = storageTotalBytes, let free = storageFreeBytes {
      storageUsedBytes = max(0, total - free)
    }
    if payload.count > 9 {
      batteryPercent = sanitizeBattery(Int(payload[9]))
    }
    if applyRecordingState, payload.count > 10 {
      updateRecordingState(
        recordingStateFromDeviceInfo(payload[10]),
        source: "deviceInfo"
      )
    }
    if payload.count > 13 {
      firmwareVersion = "\(payload[11]).\(payload[12]).\(payload[13])"
    }
    if payload.count > 37 {
      deviceModel = asciiString(Array(payload[17...37]))
    }
    if payload.count > 49 {
      recordingFormat = payload[49] == 0x00 ? "mp3" : payload[49] == 0x01 ? "opus" : "unknown"
    }
    if payload.count > 44 {
      wifiSupported = payload[44] != 0x00
    }
    if payload.count > 47 {
      wifiFirmwareVersion = "\(payload[45]).\(payload[46]).\(payload[47])"
    }
    let wifiCapability = wifiSupported == true
      ? "true"
      : wifiSupported == false ? "false" : "unknown"
    recordingCardDebugLog(
      "device info firmware=\(firmwareVersion ?? "unknown") wifiSupported=\(wifiCapability) wifiVersion=\(wifiFirmwareVersion ?? "unknown") payloadBytes=\(payload.count)"
    )
    lastInfoRefreshedAt = isoNow()
    publishSnapshot()
  }

  private func applyRecordingInfo(_ payload: [UInt8]) {
    if let parsed = recordingCardRecordingInfoPayload(payload) {
      applyRecordingPayload(parsed, source: "recordingInfo")
    }
    publishRecording()
  }

  private func applyRecordingPayload(
    _ parsed: RecordingCardRecordingPayload,
    source: String
  ) {
    if parsed.state == "idle" {
      lastCompletedFileName = parsed.fileName ?? currentFileName ?? lastCompletedFileName
      lastCompletedFileSizeBytes =
        parsed.sizeBytes ?? currentFileSizeBytes ?? lastCompletedFileSizeBytes
      lastCompletedRecordingType =
        parsed.recordingType ?? currentRecordingType ?? lastCompletedRecordingType
      lastCompletedFileNeedsSync = parsed.needsSync ?? lastCompletedFileNeedsSync
      updateRecordingState(parsed.state, source: source)
      return
    }
    if recordingState == "idle" {
      currentFileName = nil
      currentFileSizeBytes = nil
      currentRecordingType = nil
    }
    updateRecordingState(parsed.state, source: source, fileName: parsed.fileName)
    if let fileName = parsed.fileName { currentFileName = fileName }
    if let sizeBytes = parsed.sizeBytes { currentFileSizeBytes = sizeBytes }
    if let recordingType = parsed.recordingType { currentRecordingType = recordingType }
  }

  private func parseFileRow(_ payload: [UInt8]) -> [String: Any]? {
    guard payload.count >= 19, payload.first == 0x00 else { return nil }
    let name = asciiString(Array(payload[1...14])) ?? "recording-\(fileRows.count + 1)"
    guard isSafeFilename(name) else { return nil }
    let littleEndianSize = readUInt32(payload, offset: 15, littleEndian: true)
    let bigEndianSize = readUInt32(payload, offset: 15, littleEndian: false)
    let key = "card-\(name.lowercased())"
    var row: [String: Any] = [
      "deviceFileId": key,
      "localFileKey": key,
      "deviceFilename": name,
      "format": "unknown",
      "syncState": "deviceOnly",
    ]
    if let resolvedSize = recordingCardDirectoryFileSize(
      littleEndian: littleEndianSize,
      bigEndian: bigEndianSize
    ) {
      row["sizeBytes"] = resolvedSize.sizeBytes
      row["sizeConfidence"] = resolvedSize.confidence
    }
    return row
  }

  private func baseDeviceMap() -> [String: Any] {
    var map: [String: Any] = [
      "connectionState": connectionState,
      "connectionStage": connectionStage,
      "recordingFormat": recordingFormat,
    ]
    if let deviceName { map["displayName"] = deviceName }
    if let safeFingerprint { map["safeDeviceFingerprint"] = safeFingerprint }
    if connectionState == "connected",
      let serialNumber = transientHandshakeIdentity.serialNumber
    {
      map["serialNumber"] = serialNumber
    }
    if let batteryPercent { map["batteryPercent"] = batteryPercent }
    if let storageTotalBytes { map["storageTotalBytes"] = storageTotalBytes }
    if let storageFreeBytes { map["storageFreeBytes"] = storageFreeBytes }
    if let storageUsedBytes { map["storageUsedBytes"] = storageUsedBytes }
    if let firmwareVersion { map["firmwareVersion"] = firmwareVersion }
    if let deviceModel { map["deviceModel"] = deviceModel }
    if let wifiSupported { map["wifiSupported"] = wifiSupported }
    if let wifiFirmwareVersion { map["wifiFirmwareVersion"] = wifiFirmwareVersion }
    if let lastInfoRefreshedAt { map["lastInfoRefreshedAt"] = lastInfoRefreshedAt }
    if let permissionProblem { map["permissionProblem"] = permissionProblem }
    if let statusMessage { map["statusMessage"] = statusMessage }
    return map
  }

  private func recordingInfoMap() -> [String: Any] {
    var map: [String: Any] = [
      "state": recordingState,
      "durationSeconds": recordingClock.durationSeconds,
      "observationSource": recordingObservationSource,
      "revision": recordingRevision,
      "observedAt": recordingObservedAt,
    ]
    if let startedAt = recordingClock.startedAt {
      map["startedAt"] = recordingCardClockTimestamp(startedAt)
    }
    if let currentFileName { map["currentFileName"] = currentFileName }
    if let currentFileSizeBytes { map["currentFileSizeBytes"] = currentFileSizeBytes }
    if let currentRecordingType { map["currentRecordingType"] = currentRecordingType }
    if let lastCompletedFileName { map["lastCompletedFileName"] = lastCompletedFileName }
    if let lastCompletedFileSizeBytes {
      map["lastCompletedFileSizeBytes"] = lastCompletedFileSizeBytes
    }
    if let lastCompletedRecordingType {
      map["lastCompletedRecordingType"] = lastCompletedRecordingType
    }
    if let lastCompletedFileNeedsSync {
      map["lastCompletedFileNeedsSync"] = lastCompletedFileNeedsSync
    }
    return map
  }

  private func runtimeSnapshotMap() -> [String: Any] {
    var map: [String: Any] = [
      "deviceState": baseDeviceMap(),
      "recordingInfo": recordingInfoMap(),
      "files": files,
      "discoveredDevices": Array(discoveredDevices.values),
      "loadingFiles": false,
      "lastDeviceUpdatedAt": isoNow(),
    ]
    if let downloadingFileKey = offlineCapture?.request.localFileKey
      ?? wifiTransferProgressOnMain?["localFileKey"] as? String
    {
      map["downloadingFileKey"] = downloadingFileKey
    }
    if let offlineCapture {
      map["transferProgress"] = transferProgressMap(offlineCapture)
    } else if let wifiTransferProgressOnMain {
      map["transferProgress"] = wifiTransferProgressOnMain
    }
    return map
  }

  private func transferProgressMap(
    _ capture: OfflineCapture,
    now: TimeInterval = ProcessInfo.processInfo.systemUptime
  ) -> [String: Any] {
    var map: [String: Any] = [
      "transport": "bluetooth",
      "localFileKey": capture.request.localFileKey,
      "receivedBytes": capture.receivedBytes,
      "correlationId": capture.correlationID,
      "startedAt": capture.startedAt,
      "updatedAt": isoNow(),
      "directorySizeMismatch": capture.directorySizeMismatch,
    ]
    if capture.request.targetBytes > 0 {
      map["totalBytes"] = capture.request.targetBytes
    }
    let elapsed = max(0, now - capture.startedUptime)
    if capture.receivedBytes > 0, elapsed > 0 {
      let rate = Double(capture.receivedBytes) / elapsed
      if rate.isFinite, rate > 0 {
        map["bytesPerSecond"] = rate
        let remaining = max(0, capture.request.targetBytes - capture.receivedBytes)
        map["estimatedRemainingSeconds"] = Int(ceil(Double(remaining) / rate))
      }
    }
    return map
  }

  private func wifiTransferProgressMap(
    _ transfer: WifiTcpDownload,
    phase: String? = nil
  ) -> [String: Any] {
    let capture = transfer.capture
    var progress = transferProgressMap(capture)
    progress["transport"] = "wifi"
    progress["phase"] = phase ?? (capture.dataComplete ? "verifying" : "transferring")
    if let batchID = transfer.batchID { progress["batchId"] = batchID }
    if let fileIndex = transfer.batchFileIndex { progress["fileIndex"] = fileIndex }
    if let fileCount = transfer.batchFileCount { progress["fileCount"] = fileCount }
    if let aggregateBase = transfer.aggregateReceivedBase {
      let aggregateReceived = aggregateBase + capture.receivedBytes
      progress["aggregateReceivedBytes"] = transfer.aggregateTotalBytes.map {
        min(aggregateReceived, $0)
      } ?? aggregateReceived
    }
    if let aggregateTotal = transfer.aggregateTotalBytes {
      progress["aggregateTotalBytes"] = aggregateTotal
    }
    if let rate = transfer.bytesPerSecond, rate > 0 {
      progress["bytesPerSecond"] = rate
      let remaining = max(0, capture.request.targetBytes - capture.receivedBytes)
      progress["estimatedRemainingSeconds"] = Int(ceil(Double(remaining) / rate))
    }
    return progress
  }

  private func publishWifiTransferProgress(
    _ transfer: WifiTcpDownload,
    force: Bool,
    phase: String? = nil,
    now: TimeInterval = ProcessInfo.processInfo.systemUptime
  ) {
    transfer.lastActivityUptime = ProcessInfo.processInfo.systemUptime
    if !force,
      now - transfer.lastProgressPublishUptime < Self.wifiProgressPublishInterval
    {
      return
    }
    transfer.lastProgressPublishUptime = now
    let progress = wifiTransferProgressMap(transfer, phase: phase)
    let event: [String: Any] = [
      "type": "transfer_progress",
      "progress": progress,
      "recoveryBatchId": transfer.recoveryBatchId ?? "",
      "attemptId": transfer.attemptId ?? "",
    ]
    let terminal = phase == "completed" || phase == "failed" || phase == "cancelled"
    let sessionID = transfer.sessionID
    DispatchQueue.main.async { [weak self] in
      guard let self,
        self.wifiSessionActiveOnMain,
        self.wifiSessionIdOnMain == sessionID
      else { return }
      self.wifiTransferProgressOnMain = progress
      self.onEvent?(event)
      if terminal { self.wifiTransferProgressOnMain = nil }
    }
  }

  private func publishConnection(state: String, stage: String, message: String?) {
    connectionState = state
    connectionStage = stage
    statusMessage = message
    onEvent?([
      "type": "connection_state",
      "deviceState": baseDeviceMap(),
    ])
    publishSnapshot()
  }

  private func publishRecording() {
    onEvent?([
      "type": "recording_state",
      "recordingInfo": recordingInfoMap(),
    ])
    publishSnapshot()
  }

  private func publishRecordingStateInvalidated() {
    onEvent?(["type": "recording_state_invalidated"])
  }

  private func updateRecordingState(_ next: String?, source: String, fileName: String? = nil) {
    guard let next else { return }
    let observedAt = Date()
    recordingClock.observe(next, fileName: fileName ?? currentFileName, at: observedAt)
    let previous = recordingState
    recordingState = next
    if next == "idle" {
      currentFileName = nil
      currentFileSizeBytes = nil
      currentRecordingType = nil
    }
    recordingRevision += 1
    recordingObservationSource = source
    recordingObservedAt = recordingCardClockTimestamp(observedAt)
    recordingCardDebugLog(
      "recording state previous=\(previous) next=\(next) source=\(source) revision=\(recordingRevision)"
    )
  }

  private func resetRecordingRuntime(source: String) {
    updateRecordingState("idle", source: source)
    lastCompletedFileName = nil
    lastCompletedFileSizeBytes = nil
    lastCompletedRecordingType = nil
    lastCompletedFileNeedsSync = nil
  }

  private func publishSnapshot() {
    onEvent?(runtimeSnapshotEvent())
  }

  private func finishConnectWithError(
    code: String,
    message: String,
    failureState: String = "error",
    failureStage: String = "failed"
  ) {
    endWifiBackgroundRecoveryIfOwned(by: requestedFingerprint ?? safeFingerprint)
    recordingCardDebugLog("connect failed code=\(code) stage=\(connectionStage) handshakeCommand=\(handshakeCommand?.rawValue ?? -1)")
    connectionAttempt.finish()
    resetHandshake()
    connectTimer?.invalidate()
    connectTimer = nil
    scanTimer?.invalidate()
    scanTimer = nil
    stopActiveScan()
    abandonFailedConnectionTransport()
    resetRecordingRuntime(source: "transportDisconnected")
    publishConnection(state: failureState, stage: failureStage, message: message)
    if let connectResult {
      connectResult(error(code, message))
      self.connectResult = nil
    }
    requestedFingerprint = nil
    requestedBindingToken = nil
    requestedExpectedSerialNumber = nil
    finishWifiPreparation(errorCode: "RECORDING_CARD_WIFI_DISCONNECTED")
  }

  private func abandonFailedConnectionTransport() {
    let failedPeripheral = peripheral
    peripheral = nil
    clearActiveBleConnectionEpoch()
    transientHandshakeIdentity.clear()
    if let failedPeripheral { retireBleTransport(failedPeripheral) }
    for timer in commandTimers.values {
      timer.invalidate()
    }
    commandTimers.removeAll()
    pendingCommands.removeAll()
    queuedWritesWithoutResponse.removeAll()
    writeCharacteristic = nil
    controlNotifyCharacteristic = nil
    realtimeNotifyCharacteristic = nil
    offlineNotifyCharacteristic = nil
    pendingNotificationUUIDs.removeAll()
    readyNotificationUUIDs.removeAll()
    clearWifiCredentialLease()
    acceptsUnsolicitedWifiCredentials = false
    wifiBleDisconnectExpected = false
    wifiHandoffReady = false
    decoder.reset()
  }

  private func retireBleTransport(_ retiringPeripheral: RecordingCardPeripheral) {
    guard retiringPeripheral.state != .disconnected else { return }
    restoredStalePeripherals[retiringPeripheral.identifier] = retiringPeripheral
    if recordingCardFailedPeripheralNeedsCancellation(retiringPeripheral.state) {
      restoredTransportDisconnectExpectedIDs.insert(retiringPeripheral.identifier)
      central.cancelPeripheralConnection(retiringPeripheral)
    }
  }

  private func cancelPendingConnectForExplicitDisconnect() {
    guard let pendingConnect = connectResult else { return }
    connectResult = nil
    pendingConnect(
      error(
        "RECORDING_CARD_CONNECTION_CANCELLED",
        "Recording-card connection was cancelled."
      )
    )
  }

  private func cancelPendingScanForExplicitDisconnect() {
    guard let pendingScan = scanResult else { return }
    scanResult = nil
    pendingScan(
      error(
        "RECORDING_CARD_SCAN_CANCELLED",
        "Recording-card scan was cancelled."
      )
    )
  }

  private func finishScanWithError(_ flutterError: FlutterError) {
    scanTimer?.invalidate()
    scanTimer = nil
    stopActiveScan()
    if let scanResult {
      scanResult(flutterError)
      self.scanResult = nil
    }
    publishSnapshot()
  }

  private func handleBluetoothUnavailableState() {
    updateBluetoothPermissionProblem()
    let bluetoothError = bluetoothStateError()
    if scanResult != nil {
      finishScanWithError(bluetoothError)
    }
    if connectResult != nil {
      finishConnectWithError(
        code: bluetoothError.code,
        message: bluetoothError.message ?? bluetoothUnavailableStatusMessage(),
        failureState: "disconnected",
        failureStage: "idle"
      )
      return
    }
    publishBluetoothUnavailableState()
  }

  private func updateBluetoothPermissionProblem() {
    #if DEBUG && targetEnvironment(simulator)
    if central.failureCode != nil {
      permissionProblem = "ble_proxy_disconnected"
      return
    }
    #endif
    switch central.state {
    case .unauthorized:
      permissionProblem = "bluetooth_unauthorized"
    case .poweredOff:
      permissionProblem = "bluetooth_powered_off"
    case .unsupported:
      permissionProblem = "bluetooth_unsupported"
    default:
      permissionProblem = nil
    }
  }

  private func publishBluetoothUnavailableState() {
    resetRecordingRuntime(source: "transportDisconnected")
    publishConnection(
      state: "disconnected",
      stage: "idle",
      message: bluetoothUnavailableStatusMessage()
    )
  }

  private func bluetoothUnavailableStatusMessage() -> String {
    #if DEBUG && targetEnvironment(simulator)
    if central.failureCode != nil {
      return "Mac 蓝牙测试代理已断开，请重新启动测试会话"
    }
    if ProcessInfo.processInfo.environment["HUAHUO_BLE_PROXY_PORT"] != nil {
      return "Mac 蓝牙暂不可用，请检查 Mac 蓝牙开关与代理的蓝牙权限"
    }
    #endif
    switch central.state {
    case .unauthorized:
      return "请在系统设置中允许应用使用蓝牙"
    case .poweredOff:
      return "请先打开手机蓝牙"
    case .unsupported:
      return "当前设备不支持低功耗蓝牙"
    default:
      return "蓝牙暂不可用"
    }
  }

  private func error(_ code: String, _ message: String) -> FlutterError {
    FlutterError(code: code, message: message, details: nil)
  }

  private func bluetoothStateError() -> FlutterError {
    #if DEBUG && targetEnvironment(simulator)
    if let code = central.failureCode {
      return error(code, "Mac Bluetooth relay disconnected; restart the test session.")
    }
    #endif
    switch central.state {
    case .unauthorized:
      return error("RECORDING_CARD_BLUETOOTH_UNAUTHORIZED", "Bluetooth permission is not authorized.")
    case .poweredOff:
      return error("RECORDING_CARD_BLUETOOTH_POWERED_OFF", "Bluetooth is powered off.")
    case .unsupported:
      return error("RECORDING_CARD_BLUETOOTH_UNSUPPORTED", "Bluetooth LE is not supported.")
    default:
      return error("RECORDING_CARD_BLUETOOTH_UNAVAILABLE", "Bluetooth is not ready.")
    }
  }

  private func connectPeripheral(_ peripheral: RecordingCardPeripheral, name: String, fingerprint: String) {
    if isRestoredStaleTransport(peripheral) {
      _ = resetRestoredBleTransportsForFreshConnection()
    }
    guard !isRestoredStaleTransport(peripheral) else {
      recordingCardDebugLog("deferred BLE connect while restored transport reset is pending")
      return
    }
    scanTimer?.invalidate()
    scanTimer = nil
    scanResult = nil
    stopActiveScan()
    resetRecordingRuntime(source: "connectionReset")
    transportGeneration &+= 1
    if transportGeneration == 0 { transportGeneration &+= 1 }
    self.peripheral = peripheral
    deviceName = name.isEmpty ? "花火录音卡" : name
    safeFingerprint = fingerprint
    acceptsUnsolicitedWifiCredentials = true
    publishConnection(state: "connecting", stage: "connecting", message: "正在连接录音卡")
    peripheral.delegate = self
    activeBleConnectStartedAt = CFAbsoluteTimeGetCurrent()
    activeBleNativeConnectionConfirmed = false
    central.connect(peripheral, options: nil)
  }

  private func isRestoredStaleTransport(_ candidate: RecordingCardPeripheral) -> Bool {
    restoredStalePeripherals[candidate.identifier] != nil
      || restoredTransportDisconnectExpectedIDs.contains(candidate.identifier)
  }

  private func shouldIgnoreInactivePeripheralCallback(
    _ candidate: RecordingCardPeripheral,
    callback: String
  ) -> Bool {
    guard self.peripheral === candidate,
      connectResult != nil || connectionState == "connected"
    else {
      let restoredTransport = isRestoredStaleTransport(candidate)
      recordingCardDebugLog(
        "ignored \(restoredTransport ? "stale" : "inactive") BLE \(callback) callback"
      )
      if restoredTransport {
        central.cancelPeripheralConnection(candidate)
      }
      return true
    }
    return false
  }

  /// Returns true while at least one restored transport is still live. Discovery
  /// may run in parallel, but a quarantined peripheral can never become active.
  @discardableResult
  private func resetRestoredBleTransportsForFreshConnection(
    scheduleRecheck: Bool = true
  ) -> Bool {
    var awaitingDisconnect = false
    let bluetoothReady = central.state == .poweredOn
    for (identifier, restoredPeripheral) in Array(restoredStalePeripherals) {
      switch recordingCardRestoredTransportResetAction(
        isDisconnected: restoredPeripheral.state == .disconnected,
        bluetoothReady: bluetoothReady,
        awaitingDisconnectCallback: restoredTransportDisconnectExpectedIDs.contains(identifier)
      ) {
      case .clear:
        cancelRestoredTransportLateCallbackDrain(for: identifier)
        restoredStalePeripherals.removeValue(forKey: identifier)
        restoredTransportDisconnectExpectedIDs.remove(identifier)
      case .drainLateCallback:
        scheduleRestoredTransportLateCallbackDrain(
          for: identifier,
          peripheral: restoredPeripheral
        )
      case .waitForBluetooth, .awaitDisconnect:
        awaitingDisconnect = true
      case .cancelAndAwaitDisconnect:
        awaitingDisconnect = true
        guard restoredTransportDisconnectExpectedIDs.insert(identifier).inserted else {
          continue
        }
        restoredPeripheral.delegate = self
        central.cancelPeripheralConnection(restoredPeripheral)
        recordingCardDebugLog("restored BLE transport reset requested")
      }
    }
    if scheduleRecheck {
      if awaitingDisconnect {
        scheduleRestoredTransportResetPoll()
      } else {
        stopRestoredTransportResetPoll()
      }
    }
    return awaitingDisconnect
  }

  private func completeRestoredBleTransportReset(
    for peripheral: RecordingCardPeripheral,
    callback: String
  ) -> Bool {
    let identifier = peripheral.identifier
    let trackedPeripheralMatches = restoredStalePeripherals[identifier] === peripheral
    let lateCallbackPeripheralMatches =
      restoredTransportLateCallbackPeripherals[identifier] === peripheral
    guard trackedPeripheralMatches || lateCallbackPeripheralMatches else { return false }
    if trackedPeripheralMatches {
      cancelRestoredTransportLateCallbackDrain(for: identifier)
      restoredStalePeripherals.removeValue(forKey: identifier)
      restoredTransportDisconnectExpectedIDs.remove(identifier)
    }
    if lateCallbackPeripheralMatches {
      restoredTransportLateCallbackPeripherals.removeValue(forKey: identifier)
    }
    recordingCardDebugLog("restored BLE transport reset completed callback=\(callback)")
    return true
  }

  private func resumePendingBleWorkAfterRestoredTransportReset() {
    guard central.state == .poweredOn,
      forceScanDisconnectExpectedID == nil,
      peripheral == nil
    else { return }
    _ = resetRestoredBleTransportsForFreshConnection()
    switch recordingCardRestoredTransportResumeAction(
      hasPendingConnect: connectResult != nil,
      hasPendingManualScan: scanResult != nil,
      hasSelectedPeripheral: peripheral != nil,
      hasActiveScan: scanOwner != .none
    ) {
    case .startConnectScan:
      startScan()
    case .startManualScan:
      beginManualScan()
    case .none:
      break
    }
  }

  private func scheduleRestoredTransportResetPoll() {
    guard restoredTransportResetPollTimer == nil else { return }
    restoredTransportResetPollGeneration &+= 1
    if restoredTransportResetPollGeneration == 0 {
      restoredTransportResetPollGeneration &+= 1
    }
    let generation = restoredTransportResetPollGeneration
    restoredTransportResetPollDeadlineUptime =
      ProcessInfo.processInfo.systemUptime + Self.restoredTransportResetPollWindow
    let timer = Timer(
      timeInterval: Self.restoredTransportResetPollInterval,
      repeats: true
    ) { [weak self] _ in
      self?.pollRestoredTransportReset(generation: generation)
    }
    restoredTransportResetPollTimer = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  private func pollRestoredTransportReset(generation: UInt64) {
    guard generation == restoredTransportResetPollGeneration,
      restoredTransportResetPollTimer != nil
    else { return }
    let awaitingDisconnect = resetRestoredBleTransportsForFreshConnection(
      scheduleRecheck: false
    )
    if !awaitingDisconnect {
      stopRestoredTransportResetPoll()
      resumePendingBleWorkAfterRestoredTransportReset()
      return
    }
    guard ProcessInfo.processInfo.systemUptime
      >= (restoredTransportResetPollDeadlineUptime ?? 0)
    else { return }
    stopRestoredTransportResetPoll()
    recordingCardDebugLog(
      "restored BLE transport reset poll expired; live transport remains quarantined"
    )
  }

  private func stopRestoredTransportResetPoll() {
    restoredTransportResetPollTimer?.invalidate()
    restoredTransportResetPollTimer = nil
    restoredTransportResetPollDeadlineUptime = nil
    restoredTransportResetPollGeneration &+= 1
  }

  private func scheduleRestoredTransportLateCallbackDrain(
    for identifier: UUID,
    peripheral: RecordingCardPeripheral
  ) {
    guard restoredTransportDrainTickets[identifier] == nil else { return }
    restoredTransportDrainTicketCounter &+= 1
    if restoredTransportDrainTicketCounter == 0 {
      restoredTransportDrainTicketCounter &+= 1
    }
    let ticket = restoredTransportDrainTicketCounter
    restoredTransportDrainTickets[identifier] = ticket
    let timer = Timer(
      timeInterval: Self.restoredTransportLateCallbackDrain,
      repeats: false
    ) { [weak self, peripheral] _ in
      guard let self else { return }
      let ownsEntry = recordingCardRestoredTransportDrainOwnsEntry(
        capturedTicket: ticket,
        currentTicket: self.restoredTransportDrainTickets[identifier],
        matchesPeripheralObject: self.restoredStalePeripherals[identifier] === peripheral
      )
      guard self.restoredTransportDrainTickets[identifier] == ticket else { return }
      self.restoredTransportDrainTimers.removeValue(forKey: identifier)
      self.restoredTransportDrainTickets.removeValue(forKey: identifier)
      guard ownsEntry else {
        _ = self.resetRestoredBleTransportsForFreshConnection()
        return
      }
      guard peripheral.state == .disconnected else {
        _ = self.resetRestoredBleTransportsForFreshConnection()
        return
      }
      self.restoredTransportLateCallbackPeripherals[identifier] = peripheral
      self.restoredStalePeripherals.removeValue(forKey: identifier)
      self.restoredTransportDisconnectExpectedIDs.remove(identifier)
      recordingCardDebugLog(
        "restored BLE transport reset completed observation=disconnected"
      )
      _ = self.resetRestoredBleTransportsForFreshConnection()
      self.resumePendingBleWorkAfterRestoredTransportReset()
    }
    restoredTransportDrainTimers[identifier] = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  private func cancelRestoredTransportLateCallbackDrain(for identifier: UUID) {
    restoredTransportDrainTimers.removeValue(forKey: identifier)?.invalidate()
    restoredTransportDrainTickets.removeValue(forKey: identifier)
  }

  private func retryActiveConnectionAfterRetiredCallback(
    _ retiredPeripheral: RecordingCardPeripheral,
    callback: String
  ) {
    guard self.peripheral === retiredPeripheral,
      connectResult != nil,
      !activeBleNativeConnectionConfirmed
    else { return }
    self.peripheral = nil
    clearActiveBleConnectionEpoch()
    transientHandshakeIdentity.clear()
    writeCharacteristic = nil
    controlNotifyCharacteristic = nil
    realtimeNotifyCharacteristic = nil
    offlineNotifyCharacteristic = nil
    pendingNotificationUUIDs.removeAll()
    readyNotificationUUIDs.removeAll()
    queuedWritesWithoutResponse.removeAll()
    decoder.reset()
    recordingCardDebugLog(
      "retired BLE \(callback) overlapped fresh connect; resuming discovery within deadline"
    )
    guard central.state == .poweredOn, forceScanDisconnectExpectedID == nil else {
      return
    }
    startScan()
  }

  private func clearActiveBleConnectionEpoch() {
    activeBleConnectStartedAt = nil
    activeBleNativeConnectionConfirmed = false
  }

  private func scheduleConnectionDeadline(timeout: TimeInterval) {
    connectTimer?.invalidate()
    let attempt = connectionAttempt.begin()
    let timer = Timer(timeInterval: timeout, repeats: false) { [weak self] _ in
      DispatchQueue.main.async { [weak self] in
        guard let self, self.connectResult != nil,
          self.connectionAttempt.owns(attempt)
        else { return }
        let code = recordingCardConnectionDeadlineErrorCode(stage: self.connectionStage)
        self.finishConnectWithError(
          code: code,
          message: code == "RECORDING_CARD_NOT_FOUND"
            ? "No Huahuo recording card was found nearby."
            : "Recording-card connection setup timed out."
        )
      }
    }
    connectTimer = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  private func resetBleTransportForForceScan() -> Bool {
    let connectedPeripheral = peripheral
    let awaitDisconnect = connectedPeripheral.map {
      central.state == .poweredOn && $0.state != .disconnected
    } ?? false
    if awaitDisconnect, let connectedPeripheral {
      forceScanDisconnectExpectedID = connectedPeripheral.identifier
      central.cancelPeripheralConnection(connectedPeripheral)
    }
    peripheral = nil
    clearActiveBleConnectionEpoch()
    writeCharacteristic = nil
    controlNotifyCharacteristic = nil
    realtimeNotifyCharacteristic = nil
    offlineNotifyCharacteristic = nil
    pendingNotificationUUIDs.removeAll()
    readyNotificationUUIDs.removeAll()
    queuedWritesWithoutResponse.removeAll()
    clearWifiCredentialLease()
    acceptsUnsolicitedWifiCredentials = false
    wifiBleDisconnectExpected = false
    wifiHandoffReady = false
    decoder.reset()
    resetRecordingRuntime(source: "transportDisconnected")
    return awaitDisconnect
  }

  private func removeJoinedWifiConfiguration() {
    wifiJoinGeneration &+= 1
    wifiJoinInProgress = false
    let ssids = Set([joinedWifiSSID, wifiJoiningSSID].compactMap { $0 })
    joinedWifiSSID = nil
    wifiJoiningSSID = nil
    for ssid in ssids {
      NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
    }
  }

  private func bindingTokenBytes(_ value: String?) -> [UInt8]? {
    guard let value,
      value.range(of: "^[a-fA-F0-9]{32}$", options: .regularExpression) != nil
    else { return nil }
    var bytes: [UInt8] = []
    var index = value.startIndex
    while index < value.endIndex {
      let next = value.index(index, offsetBy: 2)
      guard let byte = UInt8(value[index..<next], radix: 16) else { return nil }
      bytes.append(byte)
      index = next
    }
    return bytes.count == 16 ? bytes : nil
  }

  private func safeFingerprintFor(_ peripheral: RecordingCardPeripheral) -> String {
    // Swift's hashValue changes across processes, so use a stable FNV-1a hash
    // without exposing the raw peripheral UUID to Dart.
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in peripheral.identifier.uuidString.lowercased().utf8 {
      hash ^= UInt64(byte)
      hash &*= 1_099_511_628_211
    }
    return String(format: "ios-card-%016llx", hash)
  }

  private func discoveredDeviceMap(
    peripheral: RecordingCardPeripheral,
    rssi RSSI: NSNumber,
    advertisementData: [String: Any],
    fingerprint: String,
    serialNumber: String?,
    current: [String: Any]?
  ) -> [String: Any] {
    let explicitlyConnectable = advertisementData[CBAdvertisementDataIsConnectable] as? Bool
    let hasValidatedIdentity = serialNumber != nil || current?["serialNumber"] as? String != nil
    let isConnectable: Bool?
    if !hasValidatedIdentity {
      isConnectable = false
    } else if let explicitlyConnectable {
      isConnectable = explicitlyConnectable
    } else if serialNumber != nil {
      isConnectable = true
    } else {
      isConnectable = nil
    }
    return recordingCardMergedDiscoveredDeviceMap(
      current: current,
      advertisedName: advertisementData[CBAdvertisementDataLocalNameKey] as? String,
      peripheralName: peripheral.name,
      defaultName: "花火录音卡",
      fingerprint: fingerprint,
      rssi: RSSI.intValue,
      isConnectable: isConnectable,
      serialNumber: serialNumber,
      lastSeenAt: isoNow()
    )
  }
}

private struct PendingCommand {
  let ownership: RecordingCardCommandOwnership
  let frame: Data
  let timeoutSeconds: TimeInterval
  let timeoutStartsOnDispatch: Bool
  let onFirstDispatch: ((RecordingCardCommandOwnership, TimeInterval) -> Void)?
  var dispatchState = RecordingCardCommandDispatchState()
  let result: FlutterResult
  let transform: ([UInt8]) throws -> Any
}

private struct QueuedWriteWithoutResponse {
  let command: Int
  let ownership: RecordingCardCommandOwnership
  let frame: Data
}

private struct DownloadRequest {
  let deviceFilename: String
  let localFileKey: String
  let directorySizeBytes: Int?
  let sizeConfidence: String?
  let targetBytes: Int
  let durationSeconds: Int?
  let format: String

  func withTargetBytes(_ value: Int) -> DownloadRequest {
    DownloadRequest(
      deviceFilename: deviceFilename,
      localFileKey: localFileKey,
      directorySizeBytes: directorySizeBytes,
      sizeConfidence: sizeConfidence,
      targetBytes: value,
      durationSeconds: durationSeconds,
      format: format
    )
  }

  func withDirectorySize(_ value: Int?, confidence: String?) -> DownloadRequest {
    DownloadRequest(
      deviceFilename: deviceFilename,
      localFileKey: localFileKey,
      directorySizeBytes: value,
      sizeConfidence: confidence,
      targetBytes: value ?? 0,
      durationSeconds: durationSeconds,
      format: format
    )
  }
}

private struct WifiCredentials {
  let ssid: String
  let password: String
}

private struct RecordingCardWifiAttemptScope {
  let identityProvided: Bool
  let batchId: String?
  let attemptId: String?
}

private struct RecordingCardWifiAttemptOwnershipSnapshot {
  let owned: Bool
  let batchId: String?
  let attemptId: String?
}

private struct RecordingCardWifiFailureProjection {
  let ownsProjectedSession: Bool
  let preservesAttemptOwnership: Bool
  let cleanupMode: RecordingCardWifiFailureCleanupMode
  let shouldPublishDisconnected: Bool
}

private struct WifiProgressContext {
  init(
    batchID: String? = nil,
    fileIndex: Int? = nil,
    fileCount: Int? = nil,
    aggregateReceivedBase: Int? = nil,
    aggregateTotalBytes: Int? = nil
  ) {
    self.batchID = batchID
    self.fileIndex = fileIndex
    self.fileCount = fileCount
    self.aggregateReceivedBase = aggregateReceivedBase
    self.aggregateTotalBytes = aggregateTotalBytes
  }

  let batchID: String?
  let fileIndex: Int?
  let fileCount: Int?
  let aggregateReceivedBase: Int?
  let aggregateTotalBytes: Int?
}

private final class OfflineCapture {
  init(
    request: DownloadRequest,
    fileID: String,
    appPrivateURI: String,
    displayName: String,
    partURL: URL,
    finalURL: URL,
    output: FileHandle
  ) {
    self.request = request
    self.fileID = fileID
    self.appPrivateURI = appPrivateURI
    self.displayName = displayName
    self.partURL = partURL
    self.finalURL = finalURL
    self.output = output
  }

  var request: DownloadRequest
  let fileID: String
  let appPrivateURI: String
  let displayName: String
  let partURL: URL
  let finalURL: URL
  let output: FileHandle
  let correlationID = "transfer-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
  let startedAt = ISO8601DateFormatter().string(from: Date())
  let startedUptime = ProcessInfo.processInfo.systemUptime
  var digest = SHA256()
  var receivedBytes = 0
  var acknowledged = false
  var dataComplete = false
  var preAckChunks: [Data] = []
  var preAckBytes = 0
  var directorySizeMismatch = false
  var lastProgressPublishUptime: TimeInterval = 0
}

private final class RecordingCardWifiBackgroundLease {
  init(
    generation: UInt64,
    batchId: String?,
    attemptId: String?,
    ownerFingerprint: String?
  ) {
    self.generation = generation
    self.batchId = batchId
    self.attemptId = attemptId
    self.ownerFingerprint = ownerFingerprint
  }

  let generation: UInt64
  let batchId: String?
  let attemptId: String?
  let ownerFingerprint: String?
  var identifier: UIBackgroundTaskIdentifier = .invalid
  var awaitingBleRecovery = false
  var recoveryTimer: Timer?
}

private final class WifiTcpDownload {
  init(
    capture: OfflineCapture,
    connection: NWConnection,
    allowOmittedDataCrc: Bool,
    allowQuietStopBoundary: Bool,
    openResult: @escaping FlutterResult,
    requestedFiles: [DownloadRequest],
    recoveryBatchId: String?,
    attemptId: String?
  ) {
    self.capture = capture
    self.connection = connection
    self.allowOmittedDataCrc = allowOmittedDataCrc
    self.allowQuietStopBoundary = allowQuietStopBoundary
    self.openResult = openResult
    self.requestedFiles = requestedFiles
    self.recoveryBatchId = recoveryBatchId
    self.attemptId = attemptId
  }

  var capture: OfflineCapture
  let connection: NWConnection
  let allowOmittedDataCrc: Bool
  let allowQuietStopBoundary: Bool
  let requestedFiles: [DownloadRequest]
  let recoveryBatchId: String?
  let attemptId: String?
  let sessionID = "wifi-session-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
  var lastActivityUptime = ProcessInfo.processInfo.systemUptime
  var openResult: FlutterResult?
  var result: FlutterResult?
  let startedUptime = ProcessInfo.processInfo.systemUptime
  var buffer = Data()
  var overallTimeoutWorkItem: DispatchWorkItem?
  var inactivityTimeoutWorkItem: DispatchWorkItem?
  var networkBytesReceived = 0
  var nextNetworkLogBytes = 256 * 1024
  var nextAcceptedLogBytes = 256 * 1024
  var connectionAccepted = false
  var connectionHealthy = false
  var receiveStarted = false
  var directoryRequestSent = false
  var directoryComplete = false
  var directoryRowsReceived = 0
  var lateDirectoryRows = 0
  var selectedDirectoryRowObserved = false
  var requestSent = false
  var readyForFile = false
  var fileActive = false
  var catalogRows: [[String: Any]] = []
  var catalogByFilename: [String: [String: Any]] = [:]
  var expectedDataSequence: UInt16?
  var completedFileCount = 0
  var boundaryWorkItem: DispatchWorkItem?
  var awaitingStopBoundary = false
  var boundaryFrameObserved = false
  var prematureEndWorkItem: DispatchWorkItem?
  var prematureEndObserved = false
  var tailSeekAttempted = false
  var tailSeekOffset: Int?
  var tailSeekAwaitingData = false
  var lastProgressPublishUptime: TimeInterval = 0
  var rateSampleUptime = ProcessInfo.processInfo.systemUptime
  var rateSampleBytes = 0
  var bytesPerSecond: Double?
  var batchID: String?
  var batchFileIndex: Int?
  var batchFileCount: Int?
  var aggregateReceivedBase: Int?
  var aggregateTotalBytes: Int?
  var cancelling = false
  var cancellationWorkItem: DispatchWorkItem?
  var cancellationResults: [FlutterResult] = []

  var elapsedMilliseconds: Int {
    Int((ProcessInfo.processInfo.systemUptime - startedUptime) * 1000)
  }
}

private func recordingCardWifiNetworkStateLabel(_ state: NWConnection.State) -> String {
  switch state {
  case .setup: return "setup"
  case .waiting: return "waiting"
  case .preparing: return "preparing"
  case .ready: return "ready"
  case .failed: return "failed"
  case .cancelled: return "cancelled"
  @unknown default: return "unknown"
  }
}

private func recordingCardWifiWireSignature(_ data: Data) -> String {
  let bytes = [UInt8](data.prefix(16))
  if bytes.count >= 2, bytes[0] == 0xD2, bytes[1] == 0x2D { return "ble" }
  if bytes.starts(with: Array("XnoteWifiHead".utf8)) { return "xnote" }
  return "unknown"
}

private func recordingCardWifiEnvelopeDiagnostic(_ data: Data) -> String {
  let bytes = [UInt8](data)
  let signature = Array("XnoteWifiHead".utf8)
  guard bytes.starts(with: signature) else { return "none" }
  guard bytes.count >= 24 else { return "xnote-short-\(bytes.count)" }
  let command = bytes[15]
  let tailPrefix = Array("XnoteWifiTail".utf8)
  let tailOffset = bytes.indices.first { index in
    index >= 24 && bytes[index...].starts(with: tailPrefix)
  }
  let controlLayout: String
  if command == 0x20, bytes.count <= 64, let tailOffset {
    controlLayout = bytes[13..<tailOffset]
      .map { String(format: "%02x", $0) }
      .joined()
  } else {
    controlLayout = "hidden"
  }
  let sequence = (Int(bytes[16]) << 8) | Int(bytes[17])
  let declaredCrc = (UInt16(bytes[18]) << 8) | UInt16(bytes[19])
  let declaredLength =
    (Int(bytes[20]) << 24) |
    (Int(bytes[21]) << 16) |
    (Int(bytes[22]) << 8) |
    Int(bytes[23])
  let headerTerminated = bytes[13] == 0x20 && bytes[14] == 0x20
  guard declaredLength >= 0, declaredLength <= 64 * 1024 * 1024 else {
    return "xnote-cmd-\(String(format: "%02x", command))-seq-\(sequence)-length-invalid"
  }
  let payloadEnd = 24 + declaredLength
  guard bytes.count >= payloadEnd else {
    return "xnote-cmd-\(String(format: "%02x", command))-seq-\(sequence)-length-\(declaredLength)-pending"
  }
  let payload = Array(bytes[24..<payloadEnd])
  let computedCrc = crc16(payload)
  let crcMatch = declaredCrc == computedCrc
  let trailing = Array(bytes[payloadEnd...])
  let tailKind: String
  if trailing == tailPrefix + [0x20, 0x20, 0x20] {
    tailKind = "space-padded"
  } else if trailing == tailPrefix + [0x0D, 0x0A, 0x00] {
    tailKind = "crlf-null"
  } else if trailing == tailPrefix + [0x00, 0x0D, 0x0A] {
    tailKind = "null-crlf"
  } else if trailing == tailPrefix + [0x0D, 0x0A] {
    tailKind = "crlf"
  } else if trailing.starts(with: tailPrefix) {
    tailKind = "xnote-\(trailing.count)"
  } else {
    tailKind = "unknown-\(trailing.count)"
  }
  let status = declaredLength == 1
    ? String(format: "%02x", payload[0])
    : "none"
  return "xnote-cmd-\(String(format: "%02x", command))-seq-\(sequence)-length-\(declaredLength)-header-\(headerTerminated)-crc-\(crcMatch)-declared-\(String(format: "%04x", declaredCrc))-computed-\(String(format: "%04x", computedCrc))-status-\(status)-tail-\(tailKind)-tailOffset-\(tailOffset ?? -1)-control-\(controlLayout)"
}

struct RecordingCardWifiPacket: Equatable {
  let command: UInt8
  let sequence: UInt16
  let payload: [UInt8]
}

enum RecordingCardWifiStatusOnlyResponse: Equatable {
  case accepted
  case rejected
  case incomplete
  case notStatus
}

func recordingCardWifiStatusOnlyResponse(
  _ payload: [UInt8]
) -> RecordingCardWifiStatusOnlyResponse {
  guard payload.count == 1 else { return .notStatus }
  return switch payload[0] {
  case 0x00: .accepted
  case 0x01: .rejected
  case 0x02: .incomplete
  default: .notStatus
  }
}

enum RecordingCardWifiEndDecision: Equatable {
  case complete
  case awaitTrailingData
  case failIncomplete
}

func recordingCardWifiEndDecision(
  receivedBytes: Int,
  targetBytes: Int,
  graceExpired: Bool
) -> RecordingCardWifiEndDecision {
  guard targetBytes > 0, receivedBytes >= 0 else { return .failIncomplete }
  if receivedBytes == targetBytes { return .complete }
  guard receivedBytes < targetBytes else { return .failIncomplete }
  return graceExpired ? .failIncomplete : .awaitTrailingData
}

func recordingCardWifiAllowsQuietBoundary(
  firmwareVersion: String?,
  wifiFirmwareVersion: String?
) -> Bool {
  firmwareVersion == "1.0.6" && wifiFirmwareVersion == "1.0.2"
}

func recordingCardWifiTailResumeOffset(
  verifiedProfile: Bool,
  receivedBytes: Int,
  targetBytes: Int,
  alreadyAttempted: Bool
) -> Int? {
  guard verifiedProfile, !alreadyAttempted,
    receivedBytes >= 4_040,
    UInt32(exactly: receivedBytes) != nil,
    targetBytes > receivedBytes
  else { return nil }
  let remainingBytes = targetBytes - receivedBytes
  guard recordingCardWifiTailGapIsRecoverable(remainingBytes) else { return nil }
  return receivedBytes
}

func recordingCardWifiTailGapIsRecoverable(_ remainingBytes: Int) -> Bool {
  remainingBytes > 0 && remainingBytes <= 4_040
}

func recordingCardWifiTailPayloadMatches(
  remainingBytes: Int,
  payloadBytes: Int
) -> Bool {
  recordingCardWifiTailGapIsRecoverable(remainingBytes)
    && payloadBytes == remainingBytes
}

enum RecordingCardWifiBoundaryMode: Equatable {
  case interFileQuiet
  case requestStop
}

func recordingCardWifiBoundaryMode(
  allowQuietBoundary: Bool,
  requestedFileCount: Int,
  completedFileCount: Int
) -> RecordingCardWifiBoundaryMode {
  guard allowQuietBoundary, requestedFileCount > 1 else { return .requestStop }
  guard completedFileCount >= 0,
    completedFileCount + 1 < requestedFileCount
  else {
    return .requestStop
  }
  return .interFileQuiet
}

func recordingCardWifiNextSequence(
  expected: UInt16?,
  received: UInt16
) -> UInt16? {
  if let expected, expected != received { return nil }
  return received &+ 1
}

func recordingCardWifiPayloadFits(
  remainingBytes: Int,
  payloadBytes: Int
) -> Bool {
  remainingBytes >= 0 && payloadBytes > 0 && payloadBytes <= remainingBytes
}

enum RecordingCardWifiFrameParseResult {
  case pending
  case frame(RecordingCardWifiPacket, frameLength: Int)
  case invalid
}

private let recordingCardWifiHeader = Array("XnoteWifiHead  ".utf8)
private let recordingCardWifiTail = Array("XnoteWifiTail   ".utf8)

func encodeRecordingCardWifiFrame(
  command: UInt8,
  sequence: UInt16,
  payload: [UInt8]
) -> Data {
  var bytes = recordingCardWifiHeader
  bytes.append(command)
  bytes.append(UInt8((sequence >> 8) & 0xFF))
  bytes.append(UInt8(sequence & 0xFF))
  let payloadCrc = crc16(payload)
  bytes.append(UInt8((payloadCrc >> 8) & 0xFF))
  bytes.append(UInt8(payloadCrc & 0xFF))
  let length = UInt32(payload.count)
  bytes.append(UInt8((length >> 24) & 0xFF))
  bytes.append(UInt8((length >> 16) & 0xFF))
  bytes.append(UInt8((length >> 8) & 0xFF))
  bytes.append(UInt8(length & 0xFF))
  bytes.append(contentsOf: payload)
  bytes.append(contentsOf: recordingCardWifiTail)
  return Data(bytes)
}

func parseRecordingCardWifiFrame(
  _ data: Data,
  allowOmittedDataCrc: Bool = false
) -> RecordingCardWifiFrameParseResult {
  guard data.count >= recordingCardWifiHeader.count else { return .pending }
  return data.withUnsafeBytes { rawBuffer -> RecordingCardWifiFrameParseResult in
    let bytes = rawBuffer.bindMemory(to: UInt8.self)
    for index in recordingCardWifiHeader.indices {
      if bytes[index] != recordingCardWifiHeader[index] { return .invalid }
    }
    guard bytes.count >= 24 else { return .pending }
    let payloadLength =
      (Int(bytes[20]) << 24)
      | (Int(bytes[21]) << 16)
      | (Int(bytes[22]) << 8)
      | Int(bytes[23])
    guard payloadLength <= 64 * 1024 * 1024 else { return .invalid }
    let payloadEnd = 24 + payloadLength
    let frameLength = payloadEnd + recordingCardWifiTail.count
    guard bytes.count >= frameLength else { return .pending }
    for index in recordingCardWifiTail.indices {
      if bytes[payloadEnd + index] != recordingCardWifiTail[index] { return .invalid }
    }
    let payloadBytes = bytes[24..<payloadEnd]
    let expectedCrc = (UInt16(bytes[18]) << 8) | UInt16(bytes[19])
    guard expectedCrc == crc16(payloadBytes)
      || (allowOmittedDataCrc && expectedCrc == 0x0000)
    else { return .invalid }
    let payload = Array(payloadBytes)
    let packet = RecordingCardWifiPacket(
      command: bytes[15],
      sequence: (UInt16(bytes[16]) << 8) | UInt16(bytes[17]),
      payload: payload
    )
    return .frame(packet, frameLength: frameLength)
  }
}

private enum RecordingCardCommandError: Error {
  case failedAck
}

private struct FileRequestFailure: Error {
  let code: String
  let safeMessage: String
}

private enum RecordingCardLocalFileError: Error {
  case writeFailed
}

struct RecordingCardPacket: Equatable {
  let command: UInt8
  let payload: [UInt8]
}

enum RecordingCardFrameCodec {
  static func encode(command: UInt8, payload: [UInt8]) -> Data {
    var frame: [UInt8] = [0xD2, 0x2D, 0x02, command, UInt8(payload.count)]
    frame.append(contentsOf: payload)
    let crc = crc16(frame)
    frame.append(UInt8(crc & 0xFF))
    frame.append(UInt8((crc >> 8) & 0xFF))
    return Data(frame)
  }
}

enum RecordingCardFrameDecodeIssue: Equatable {
  case discardedNoise
  case unsupportedVersion
  case crcMismatch
  case bufferTrimmed

  var requestsBindingInfoRetry: Bool {
    switch self {
    case .discardedNoise:
      return false
    case .unsupportedVersion, .crcMismatch, .bufferTrimmed:
      return true
    }
  }
}

struct RecordingCardFrameDecodeBatch: Equatable {
  let packets: [RecordingCardPacket]
  let issues: [RecordingCardFrameDecodeIssue]
  let awaitingBytes: Int?
  let bufferedByteCount: Int
}

final class RecordingCardFrameDecoder {
  private static let maximumBufferedBytes = 1024
  private var buffer: [UInt8] = []

  func reset() {
    buffer.removeAll()
  }

  func push(_ data: Data) -> RecordingCardFrameDecodeBatch {
    buffer.append(contentsOf: data)
    var packets: [RecordingCardPacket] = []
    var issues: [RecordingCardFrameDecodeIssue] = []
    while buffer.count >= 2 {
      guard let headerIndex = findHeader(startingAt: 0) else {
        if buffer.count > 1 {
          buffer = Array(buffer.suffix(1))
          issues.append(.discardedNoise)
        }
        break
      }
      if headerIndex > 0 {
        buffer.removeFirst(headerIndex)
        issues.append(.discardedNoise)
      }
      if buffer.count < 5 {
        break
      }
      guard Self.isSupportedVersion(buffer[2]) else {
        buffer.removeFirst()
        issues.append(.unsupportedVersion)
        continue
      }
      let length = Int(buffer[4])
      let frameLength = 5 + length + 2
      if buffer.count < frameLength {
        break
      }
      let frame = Array(buffer.prefix(frameLength))
      let payloadEnd = 5 + length
      let actualCrc = UInt16(frame[payloadEnd]) | (UInt16(frame[payloadEnd + 1]) << 8)
      let computedCrc = crc16(frame.prefix(payloadEnd))
      guard actualCrc == computedCrc else {
        buffer.removeFirst()
        issues.append(.crcMismatch)
        continue
      }
      buffer.removeFirst(frameLength)
      packets.append(
        RecordingCardPacket(
          command: frame[3],
          payload: Array(frame[5..<payloadEnd])
        )
      )
    }
    if buffer.count > Self.maximumBufferedBytes {
      buffer = Array(buffer.suffix(Self.maximumBufferedBytes))
      issues.append(.bufferTrimmed)
    }
    return RecordingCardFrameDecodeBatch(
      packets: packets,
      issues: issues,
      awaitingBytes: awaitingByteCount(),
      bufferedByteCount: buffer.count
    )
  }

  private static func isSupportedVersion(_ value: UInt8) -> Bool {
    value == 0x01 || value == 0x02
  }

  private func findHeader(startingAt start: Int) -> Int? {
    guard start >= 0, buffer.count >= start + 2 else { return nil }
    for index in start...(buffer.count - 2) {
      if buffer[index] == 0xD2 && buffer[index + 1] == 0x2D {
        return index
      }
    }
    return nil
  }

  private func awaitingByteCount() -> Int? {
    if buffer.count == 1 { return buffer[0] == 0xD2 ? 1 : nil }
    guard buffer.count >= 2, buffer[0] == 0xD2, buffer[1] == 0x2D else {
      return nil
    }
    guard buffer.count >= 5 else { return 5 - buffer.count }
    guard Self.isSupportedVersion(buffer[2]) else { return nil }
    let frameLength = 5 + Int(buffer[4]) + 2
    return buffer.count < frameLength ? frameLength - buffer.count : nil
  }
}

private let recordingCardCrc16Table: [UInt16] = (0..<256).map { seed in
  var value = UInt16(seed)
  for _ in 0..<8 {
    value = value & 0x0001 == 0x0001
      ? (value >> 1) ^ 0xA001
      : value >> 1
  }
  return value
}

private func crc16<Bytes: Collection>(_ bytes: Bytes) -> UInt16
where Bytes.Element == UInt8 {
  var crc: UInt16 = 0x0000
  for byte in bytes {
    let tableIndex = Int((crc ^ UInt16(byte)) & 0x00FF)
    crc = (crc >> 8) ^ recordingCardCrc16Table[tableIndex]
  }
  return crc
}

private func readUInt32(_ bytes: [UInt8], offset: Int, littleEndian: Bool = false) -> Int {
  guard bytes.count >= offset + 4 else { return 0 }
  if littleEndian {
    return Int(bytes[offset])
      | (Int(bytes[offset + 1]) << 8)
      | (Int(bytes[offset + 2]) << 16)
      | (Int(bytes[offset + 3]) << 24)
  }
  return (Int(bytes[offset]) << 24)
    | (Int(bytes[offset + 1]) << 16)
    | (Int(bytes[offset + 2]) << 8)
    | Int(bytes[offset + 3])
}

private func sanitizeBattery(_ value: Int) -> Int {
  max(0, min(100, value))
}

private func recordingStateFromRecordingInfo(_ value: UInt8) -> String? {
  switch value {
  case 0x00:
    return "recording"
  case 0x01:
    return "idle"
  case 0x02:
    return "paused"
  default:
    return nil
  }
}

private func recordingStateFromDeviceInfo(_ value: UInt8) -> String? {
  switch value {
  case 0x00:
    return "idle"
  case 0x01:
    return "recording"
  case 0x02:
    return "paused"
  default:
    return nil
  }
}

private func asciiString(_ bytes: [UInt8]) -> String? {
  let trimmed = bytes.prefix { $0 != 0x00 }
  guard !trimmed.isEmpty else { return nil }
  let text = String(bytes: trimmed, encoding: .ascii)?.trimmingCharacters(in: .whitespacesAndNewlines)
  return text?.isEmpty == false ? text : nil
}

func recordingCardFileRequestPayload(
  _ filename: String,
  seekOffset: Int
) -> [UInt8]? {
  let filenameBytes = Array(filename.utf8)
  guard !filenameBytes.isEmpty, filenameBytes.count <= 14,
    filenameBytes.allSatisfy({ $0 < 0x80 }),
    seekOffset >= 0, UInt64(seekOffset) <= UInt64(UInt32.max)
  else { return nil }
  var payload = filenameBytes
  payload.append(contentsOf: repeatElement(0, count: max(0, 14 - payload.count)))
  let seek = UInt32(seekOffset)
  payload.append(UInt8((seek >> 24) & 0xFF))
  payload.append(UInt8((seek >> 16) & 0xFF))
  payload.append(UInt8((seek >> 8) & 0xFF))
  payload.append(UInt8(seek & 0xFF))
  return payload
}

private func isSafeFilename(_ filename: String) -> Bool {
  !filename.isEmpty
    && filename.count <= 64
    && !filename.lowercased().hasSuffix(".part")
    && filename.range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil
}

#if DEBUG
  private func recordingCardWifiLegacyDeepTailSeekProbeURL() -> URL? {
    guard let caches = FileManager.default.urls(
      for: .cachesDirectory,
      in: .userDomainMask
    ).first else { return nil }
    return caches.appendingPathComponent("fw920-wifi-deep-tail-seek-probe.bin")
  }
#endif

private func isSafeFileRequestName(_ filename: String) -> Bool {
  isSafeFilename(filename) && filename.utf8.count <= 14
}

private func safeWifiIdentifier(_ value: Any?) -> String? {
  guard let text = value as? String,
    !text.isEmpty,
    text.count <= 160,
    text.range(of: #"^[A-Za-z0-9_.:-]+$"#, options: .regularExpression) != nil
  else { return nil }
  return text
}

private func positiveInteger(_ value: Any?) -> Int? {
  recordingCardChannelInteger(value, minimum: 1)
}

private func isValidDeviceFileSize(_ value: Int) -> Bool {
  value > 0 && value <= 1024 * 1024 * 1024
}

private func nonNegativeInteger(_ value: Any?) -> Int? {
  recordingCardChannelInteger(value, minimum: 0)
}

func recordingCardChannelInteger(_ value: Any?, minimum: Int) -> Int? {
  guard minimum >= 0,
    let number = value as? NSNumber,
    CFGetTypeID(number) != CFBooleanGetTypeID()
  else { return nil }
  let parsed = number.int64Value
  guard parsed >= Int64(minimum), parsed <= Int64(Int.max) else { return nil }
  return Int(parsed)
}

private func isoNow() -> String {
  ISO8601DateFormatter().string(from: Date())
}
