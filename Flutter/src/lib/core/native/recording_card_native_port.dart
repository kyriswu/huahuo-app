import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import 'package:huahuo_api/huahuo_api.dart';
import '../storage/private_recording_path_resolver.dart';

enum RecordingCardConnectionState { disconnected, connecting, connected, error }

enum RecordingCardConnectionStage {
  idle,
  searching,
  connecting,
  connected,
  failed,
}

enum RecordingCardRecordingState { idle, recording, paused }

enum RecordingCardObservationSource {
  command,
  recordingInfo,
  statusNotification,
  deviceInfo,
  runtimeSnapshot,
}

enum RecordingCardFileSyncState {
  deviceOnly,
  downloading,
  synced,
  localMissing,
  failed,
}

enum RecordingCardFileFormat { mp3, opus, m4a, wav, unknown }

enum RecordingCardFileSizeConfidence { trusted, suspect }

enum RecordingCardFailureStage {
  coordination,
  connection,
  request,
  transfer,
  verification,
  storage,
}

enum RecordingCardTransferTransport { bluetooth, wifi }

enum RecordingCardTransferPhase {
  queued,
  awaitingHotspot,
  openingSession,
  transferring,
  verifying,
  registering,
  paused,
  completed,
  failed,
  cancelled,
}

final class RecordingCardResult<T> {
  const RecordingCardResult._({required this.ok, this.value, this.error});

  factory RecordingCardResult.success(T value) {
    return RecordingCardResult<T>._(ok: true, value: value);
  }

  factory RecordingCardResult.failure(AppFailure error) {
    return RecordingCardResult<T>._(ok: false, error: error);
  }

  final bool ok;
  final T? value;
  final AppFailure? error;
}

/// FW920 reserves a fixed 32-byte field for the Bluetooth advertising name.
const recordingCardBluetoothNameMaxUtf8Bytes = 32;

/// Returns the protocol-safe Bluetooth name, or `null` when it cannot be
/// encoded safely into the FW920 32-byte name field.
String? normalizeRecordingCardBluetoothName(String value) {
  final normalized = value.trim();
  if (normalized.isEmpty ||
      normalized.runes.any(_isUnsafeRecordingCardBluetoothNameRune)) {
    return null;
  }
  final byteLength = recordingCardBluetoothNameUtf8ByteLength(normalized);
  if (byteLength < 1 || byteLength > recordingCardBluetoothNameMaxUtf8Bytes) {
    return null;
  }
  return normalized;
}

/// Computes the on-wire UTF-8 byte length without treating malformed Dart
/// strings as valid Bluetooth names.
int recordingCardBluetoothNameUtf8ByteLength(String value) {
  try {
    return utf8.encode(value).length;
  } on FormatException {
    return 0;
  }
}

bool _isUnsafeRecordingCardBluetoothNameRune(int rune) {
  return rune <= 0x1f ||
      (rune >= 0x7f && rune <= 0x9f) ||
      (rune >= 0xd800 && rune <= 0xdfff);
}

final class RecordingCardConnectRequest {
  const RecordingCardConnectRequest({
    this.displayName,
    this.safeDeviceFingerprint,
    this.expectedSerialNumber,
    this.overallTimeoutMs,
    this.bindingTokenHex,
    this.forceScan = false,
  });

  final String? displayName;
  final String? safeDeviceFingerprint;
  final String? expectedSerialNumber;
  final int? overallTimeoutMs;
  final bool forceScan;

  /// A one-connection FW920 token. It is deliberately absent from snapshots.
  final String? bindingTokenHex;

  RecordingCardConnectRequest withBindingToken(String token) {
    return RecordingCardConnectRequest(
      displayName: displayName,
      safeDeviceFingerprint: safeDeviceFingerprint,
      expectedSerialNumber: expectedSerialNumber,
      overallTimeoutMs: overallTimeoutMs,
      bindingTokenHex: token,
      forceScan: forceScan,
    );
  }

  Map<String, Object?> toChannelMap() {
    return <String, Object?>{
      if (displayName != null) 'displayName': displayName,
      if (safeDeviceFingerprint != null)
        'safeDeviceFingerprint': safeDeviceFingerprint,
      if (expectedSerialNumber != null)
        'expectedSerialNumber': expectedSerialNumber,
      if (overallTimeoutMs != null) 'overallTimeoutMs': overallTimeoutMs,
      if (bindingTokenHex != null) 'bindingToken': bindingTokenHex,
      if (forceScan) 'forceScan': true,
    };
  }
}

final class RecordingCardDiscoveredDevice {
  const RecordingCardDiscoveredDevice({
    required this.displayName,
    required this.safeDeviceFingerprint,
    this.serialNumber,
    this.rssi,
    this.isConnectable,
    this.lastSeenAt,
  });

  final String displayName;
  final String safeDeviceFingerprint;
  final String? serialNumber;
  final int? rssi;
  final bool? isConnectable;
  final DateTime? lastSeenAt;
}

final class RecordingCardDeviceState {
  const RecordingCardDeviceState({
    required this.connectionState,
    this.connectionStage = RecordingCardConnectionStage.idle,
    this.displayName,
    this.safeDeviceFingerprint,
    this.serialNumber,
    this.batteryPercent,
    this.storageTotalBytes,
    this.storageFreeBytes,
    this.storageUsedBytes,
    this.firmwareVersion,
    this.deviceModel,
    this.wifiSupported,
    this.wifiFirmwareVersion,
    this.recordingFormat = RecordingCardFileFormat.unknown,
    this.lastInfoRefreshedAt,
    this.permissionProblem,
    this.statusMessage,
  });

  factory RecordingCardDeviceState.disconnected() {
    return const RecordingCardDeviceState(
      connectionState: RecordingCardConnectionState.disconnected,
    );
  }

  factory RecordingCardDeviceState.error({String? permissionProblem}) {
    return RecordingCardDeviceState(
      connectionState: RecordingCardConnectionState.error,
      connectionStage: RecordingCardConnectionStage.failed,
      permissionProblem: permissionProblem,
    );
  }

  final RecordingCardConnectionState connectionState;
  final RecordingCardConnectionStage connectionStage;
  final String? displayName;
  final String? safeDeviceFingerprint;
  final String? serialNumber;
  final int? batteryPercent;
  final int? storageTotalBytes;
  final int? storageFreeBytes;
  final int? storageUsedBytes;
  final String? firmwareVersion;
  final String? deviceModel;
  final bool? wifiSupported;
  final String? wifiFirmwareVersion;
  final RecordingCardFileFormat recordingFormat;
  final DateTime? lastInfoRefreshedAt;
  final String? permissionProblem;
  final String? statusMessage;

  bool get isOperationallyConnected {
    return connectionState == RecordingCardConnectionState.connected;
  }

  RecordingCardDeviceState copyWith({
    RecordingCardConnectionState? connectionState,
    RecordingCardConnectionStage? connectionStage,
    String? displayName,
    String? safeDeviceFingerprint,
    String? serialNumber,
    int? batteryPercent,
    int? storageTotalBytes,
    int? storageFreeBytes,
    int? storageUsedBytes,
    String? firmwareVersion,
    String? deviceModel,
    bool? wifiSupported,
    String? wifiFirmwareVersion,
    RecordingCardFileFormat? recordingFormat,
    DateTime? lastInfoRefreshedAt,
    String? permissionProblem,
    String? statusMessage,
    bool clearPermissionProblem = false,
    bool clearStatusMessage = false,
  }) {
    return RecordingCardDeviceState(
      connectionState: connectionState ?? this.connectionState,
      connectionStage: connectionStage ?? this.connectionStage,
      displayName: displayName ?? this.displayName,
      safeDeviceFingerprint:
          safeDeviceFingerprint ?? this.safeDeviceFingerprint,
      serialNumber: serialNumber ?? this.serialNumber,
      batteryPercent: batteryPercent ?? this.batteryPercent,
      storageTotalBytes: storageTotalBytes ?? this.storageTotalBytes,
      storageFreeBytes: storageFreeBytes ?? this.storageFreeBytes,
      storageUsedBytes: storageUsedBytes ?? this.storageUsedBytes,
      firmwareVersion: firmwareVersion ?? this.firmwareVersion,
      deviceModel: deviceModel ?? this.deviceModel,
      wifiSupported: wifiSupported ?? this.wifiSupported,
      wifiFirmwareVersion: wifiFirmwareVersion ?? this.wifiFirmwareVersion,
      recordingFormat: recordingFormat ?? this.recordingFormat,
      lastInfoRefreshedAt: lastInfoRefreshedAt ?? this.lastInfoRefreshedAt,
      permissionProblem: clearPermissionProblem
          ? null
          : permissionProblem ?? this.permissionProblem,
      statusMessage: clearStatusMessage
          ? null
          : statusMessage ?? this.statusMessage,
    );
  }
}

final class RecordingCardRecordingInfo {
  const RecordingCardRecordingInfo({
    required this.state,
    this.currentFileName,
    this.startedAt,
    this.durationSeconds,
  });

  factory RecordingCardRecordingInfo.idle() {
    return const RecordingCardRecordingInfo(
      state: RecordingCardRecordingState.idle,
    );
  }

  final RecordingCardRecordingState state;
  final String? currentFileName;
  final DateTime? startedAt;
  final int? durationSeconds;
}

final class RecordingCardRecordingObservation {
  const RecordingCardRecordingObservation({
    required this.info,
    required this.source,
    required this.revision,
    required this.observedAt,
  });

  final RecordingCardRecordingInfo info;
  final RecordingCardObservationSource source;
  final int revision;
  final DateTime observedAt;

  RecordingCardRecordingObservation copyWith({
    RecordingCardRecordingInfo? info,
  }) {
    return RecordingCardRecordingObservation(
      info: info ?? this.info,
      source: source,
      revision: revision,
      observedAt: observedAt,
    );
  }
}

final class RecordingCardScannedFile {
  const RecordingCardScannedFile({
    required this.deviceFileId,
    required this.localFileKey,
    required this.deviceFilename,
    this.sizeBytes,
    this.durationSeconds,
    this.recordedAt,
    this.contentHash,
    this.sizeConfidence,
    this.format = RecordingCardFileFormat.unknown,
    this.mimeType,
    this.syncState = RecordingCardFileSyncState.deviceOnly,
    this.localFileId,
    this.appPrivateUri,
  });

  final String deviceFileId;
  final String localFileKey;
  final String deviceFilename;
  final int? sizeBytes;
  final int? durationSeconds;
  final DateTime? recordedAt;
  final String? contentHash;
  final RecordingCardFileSizeConfidence? sizeConfidence;
  final RecordingCardFileFormat format;
  final String? mimeType;
  final RecordingCardFileSyncState syncState;
  final String? localFileId;
  final String? appPrivateUri;

  RecordingCardScannedFile copyWith({
    int? durationSeconds,
    RecordingCardFileSyncState? syncState,
    String? localFileId,
    String? appPrivateUri,
  }) {
    return RecordingCardScannedFile(
      deviceFileId: deviceFileId,
      localFileKey: localFileKey,
      deviceFilename: deviceFilename,
      sizeBytes: sizeBytes,
      durationSeconds: durationSeconds ?? this.durationSeconds,
      recordedAt: recordedAt,
      contentHash: contentHash,
      sizeConfidence: sizeConfidence,
      format: format,
      mimeType: mimeType,
      syncState: syncState ?? this.syncState,
      localFileId: localFileId ?? this.localFileId,
      appPrivateUri: appPrivateUri ?? this.appPrivateUri,
    );
  }

  Map<String, Object?> toChannelMap() {
    return <String, Object?>{
      'deviceFileId': deviceFileId,
      'localFileKey': localFileKey,
      'deviceFilename': deviceFilename,
      if (sizeBytes != null) 'sizeBytes': sizeBytes,
      if (durationSeconds != null) 'durationSeconds': durationSeconds,
      if (recordedAt != null) 'recordedAt': recordedAt!.toIso8601String(),
      if (contentHash != null) 'contentHash': contentHash,
      if (sizeConfidence != null) 'sizeConfidence': sizeConfidence!.name,
      if (format != RecordingCardFileFormat.unknown) 'format': format.name,
      if (mimeType != null) 'mimeType': mimeType,
      'syncState': syncState.name,
      if (localFileId != null) 'localFileId': localFileId,
      if (appPrivateUri != null) 'appPrivateUri': appPrivateUri,
    };
  }
}

final class RecordingCardDownloadedFile {
  const RecordingCardDownloadedFile({
    required this.localFileKey,
    required this.appPrivateUri,
    this.localFileId,
    this.displayName,
    this.durationSeconds,
    this.sizeBytes,
    this.contentHash,
    this.format = RecordingCardFileFormat.unknown,
    this.mimeType,
  });

  final String localFileKey;
  final String appPrivateUri;
  final String? localFileId;
  final String? displayName;
  final int? durationSeconds;
  final int? sizeBytes;
  final String? contentHash;
  final RecordingCardFileFormat format;
  final String? mimeType;
}

final class RecordingCardDeleteResult {
  const RecordingCardDeleteResult({
    required this.deviceFileId,
    required this.deviceFilename,
  });

  final String deviceFileId;
  final String deviceFilename;
  bool get deleted => true;
}

final class RecordingCardFileListDiagnostics {
  const RecordingCardFileListDiagnostics({
    required this.invalidRowCount,
    this.firstInvalidReason,
  });

  final int invalidRowCount;
  final String? firstInvalidReason;
}

final class RecordingCardTransferProgress {
  const RecordingCardTransferProgress({
    required this.localFileKey,
    required this.receivedBytes,
    required this.correlationId,
    this.totalBytes,
    this.startedAt,
    this.updatedAt,
    this.directorySizeMismatch = false,
    this.transport,
    this.batchId,
    this.fileIndex,
    this.fileCount,
    this.aggregateReceivedBytes,
    this.aggregateTotalBytes,
    this.phase,
    this.bytesPerSecond,
    this.estimatedRemainingSeconds,
  });

  final String localFileKey;
  final int receivedBytes;
  final int? totalBytes;
  final String correlationId;
  final DateTime? startedAt;
  final DateTime? updatedAt;
  final bool directorySizeMismatch;
  final RecordingCardTransferTransport? transport;
  final String? batchId;
  final int? fileIndex;
  final int? fileCount;
  final int? aggregateReceivedBytes;
  final int? aggregateTotalBytes;
  final RecordingCardTransferPhase? phase;
  final double? bytesPerSecond;
  final int? estimatedRemainingSeconds;

  double? get fraction {
    final total = totalBytes;
    if (total == null || total <= 0) return null;
    return (receivedBytes / total).clamp(0, 1).toDouble();
  }

  double? get aggregateFraction {
    final total = aggregateTotalBytes;
    final received = aggregateReceivedBytes;
    if (total == null || received == null || total <= 0) return null;
    return (received / total).clamp(0, 1).toDouble();
  }
}

final class RecordingCardRuntimeSnapshot {
  const RecordingCardRuntimeSnapshot({
    required this.deviceState,
    required this.recordingInfo,
    required this.files,
    this.discoveredDevices = const <RecordingCardDiscoveredDevice>[],
    this.loadingFiles = false,
    this.downloadingFileKey,
    this.fileListDiagnostics,
    this.recordingObservation,
    this.transferProgress,
    this.lastDeviceUpdatedAt,
  });

  factory RecordingCardRuntimeSnapshot.initial() {
    return RecordingCardRuntimeSnapshot(
      deviceState: RecordingCardDeviceState.disconnected(),
      recordingInfo: RecordingCardRecordingInfo.idle(),
      files: const <RecordingCardScannedFile>[],
      discoveredDevices: const <RecordingCardDiscoveredDevice>[],
    );
  }

  final RecordingCardDeviceState deviceState;
  final RecordingCardRecordingInfo recordingInfo;
  final List<RecordingCardScannedFile> files;
  final List<RecordingCardDiscoveredDevice> discoveredDevices;
  final bool loadingFiles;
  final String? downloadingFileKey;
  final RecordingCardFileListDiagnostics? fileListDiagnostics;
  final RecordingCardRecordingObservation? recordingObservation;
  final RecordingCardTransferProgress? transferProgress;
  final DateTime? lastDeviceUpdatedAt;

  RecordingCardRuntimeSnapshot copyWith({
    RecordingCardDeviceState? deviceState,
    RecordingCardRecordingInfo? recordingInfo,
    List<RecordingCardScannedFile>? files,
    List<RecordingCardDiscoveredDevice>? discoveredDevices,
    bool? loadingFiles,
    String? downloadingFileKey,
    RecordingCardFileListDiagnostics? fileListDiagnostics,
    RecordingCardRecordingObservation? recordingObservation,
    RecordingCardTransferProgress? transferProgress,
    DateTime? lastDeviceUpdatedAt,
    bool clearDownloadingFileKey = false,
    bool clearRecordingObservation = false,
    bool clearTransferProgress = false,
  }) {
    return RecordingCardRuntimeSnapshot(
      deviceState: deviceState ?? this.deviceState,
      recordingInfo: recordingInfo ?? this.recordingInfo,
      files: files ?? this.files,
      discoveredDevices: discoveredDevices ?? this.discoveredDevices,
      loadingFiles: loadingFiles ?? this.loadingFiles,
      downloadingFileKey: clearDownloadingFileKey
          ? null
          : downloadingFileKey ?? this.downloadingFileKey,
      fileListDiagnostics: fileListDiagnostics ?? this.fileListDiagnostics,
      recordingObservation: clearRecordingObservation
          ? null
          : recordingObservation ?? this.recordingObservation,
      transferProgress: clearTransferProgress
          ? null
          : transferProgress ?? this.transferProgress,
      lastDeviceUpdatedAt: lastDeviceUpdatedAt ?? this.lastDeviceUpdatedAt,
    );
  }
}

typedef RecordingCardRuntimeSnapshotListener =
    void Function(RecordingCardRuntimeSnapshot snapshot);

final class RecordingCardSnapshotSubscription {
  const RecordingCardSnapshotSubscription(this.unsubscribe);

  final void Function() unsubscribe;
}

abstract interface class RecordingCardPort {
  RecordingCardRuntimeSnapshot get runtimeSnapshot;

  RecordingCardSnapshotSubscription subscribeRuntimeSnapshot(
    RecordingCardRuntimeSnapshotListener listener,
  );

  Future<RecordingCardResult<RecordingCardDeviceState>> connect({
    RecordingCardConnectRequest? request,
  });

  Future<RecordingCardResult<List<RecordingCardDiscoveredDevice>>>
  scanDevices();

  Future<RecordingCardResult<RecordingCardDeviceState>> getConnectionState();

  Future<RecordingCardResult<RecordingCardRuntimeSnapshot>> refreshDeviceInfo();

  Future<RecordingCardResult<RecordingCardRecordingInfo>> readRecordingState();

  Future<RecordingCardResult<RecordingCardRecordingInfo>> startRecording();

  Future<RecordingCardResult<RecordingCardRecordingInfo>> pauseRecording();

  Future<RecordingCardResult<RecordingCardRecordingInfo>> resumeRecording();

  Future<RecordingCardResult<RecordingCardRecordingInfo>> stopRecording();

  Future<RecordingCardResult<List<RecordingCardScannedFile>>> scanFiles();

  Future<RecordingCardResult<RecordingCardDownloadedFile>>
  downloadFileToLocalCache(RecordingCardScannedFile file);

  Future<RecordingCardResult<RecordingCardDownloadedFile>> syncFileToLocalCache(
    RecordingCardScannedFile file,
  );

  Future<RecordingCardResult<RecordingCardDeleteResult>> deleteFileFromDevice(
    RecordingCardScannedFile file,
  );

  Future<RecordingCardResult<RecordingCardDeviceState>> disconnect();
}

/// Optional cancellation for a discovery lease; it never disconnects GATT.
///
/// A successful acknowledgement is terminal: the pending [RecordingCardPort]
/// scan call must have received its completion before this Future completes.
abstract interface class RecordingCardDiscoveryCancellationPort {
  Future<RecordingCardResult<bool>> cancelDiscovery();
}

/// Optional FW920 Wi-Fi handoff capability.
///
/// It stays separate from [RecordingCardPort] so existing BLE-only ports and
/// test doubles keep their source-compatible contract.
abstract interface class RecordingCardWifiTransferPort {
  Future<RecordingCardResult<RecordingCardWifiCredentials>> prepareWifiTransfer(
    RecordingCardScannedFile file,
  );

  Future<RecordingCardResult<RecordingCardWifiHandoffResult>>
  verifyWifiHandoff();

  Future<RecordingCardResult<RecordingCardDownloadedFile>> downloadFileOverWifi(
    RecordingCardScannedFile file,
  );
}

/// Optional persistent-session Wi-Fi capability used by ordered batches.
abstract interface class RecordingCardWifiSessionPort {
  Future<RecordingCardResult<RecordingCardWifiCredentials>> prepareWifiSession(
    List<RecordingCardScannedFile> files,
  );

  Future<RecordingCardResult<RecordingCardWifiSessionInfo>> openWifiSession(
    List<RecordingCardScannedFile> files,
  );

  Future<RecordingCardResult<RecordingCardDownloadedFile>>
  downloadFileInWifiSession(RecordingCardScannedFile file);

  Future<RecordingCardResult<bool>> closeWifiSession();

  Future<RecordingCardResult<bool>> cancelWifiSession();
}

final class RecordingCardWifiSessionObservation {
  const RecordingCardWifiSessionObservation({
    required this.batchId,
    required this.attemptId,
    required this.active,
    this.failureCode,
  });

  final String batchId;
  final String attemptId;
  final bool active;
  final String? failureCode;

  static RecordingCardWifiSessionObservation? fromChannel(Object? raw) {
    if (raw is! Map || raw['active'] is! bool) return null;
    final batchId = raw['batchId'];
    final attemptId = raw['attemptId'];
    if (batchId is! String || attemptId is! String) return null;
    return RecordingCardWifiSessionObservation(
      batchId: batchId,
      attemptId: attemptId,
      active: raw['active'] as bool,
      failureCode: raw['failureCode'] is String
          ? raw['failureCode'] as String
          : null,
    );
  }
}

final class RecordingCardWifiRecoveredDownload {
  const RecordingCardWifiRecoveredDownload(this.file);
  final RecordingCardDownloadedFile? file;
}

final class RecordingCardBluetoothRecoveredDownload {
  const RecordingCardBluetoothRecoveredDownload(this.file);
  final RecordingCardDownloadedFile? file;
}

/// Optional BLE transfer capability with a caller-planned native file id.
///
/// Implementations must make [recoverBluetoothDownload] a local-only lookup:
/// it must not start a new Bluetooth transfer.
abstract interface class RecordingCardRecoverableBluetoothTransferPort {
  Future<RecordingCardResult<RecordingCardDownloadedFile>>
  downloadRecoverableBluetoothFile(
    RecordingCardScannedFile file, {
    required String plannedNativeFileId,
  });

  Future<RecordingCardResult<RecordingCardBluetoothRecoveredDownload>>
  recoverBluetoothDownload(
    RecordingCardScannedFile file, {
    required String plannedNativeFileId,
  });
}

abstract interface class RecordingCardWifiRecoveryPort {
  Future<RecordingCardResult<bool>> beginWifiAttempt({
    required String batchId,
    required String attemptId,
  });
  Future<RecordingCardResult<RecordingCardWifiSessionObservation>>
  queryWifiSession();
  RecordingCardSnapshotSubscription subscribeWifiSession(
    void Function(RecordingCardWifiSessionObservation) listener,
  );
  Future<RecordingCardResult<RecordingCardDownloadedFile>>
  downloadRecoverableWifiFile(
    RecordingCardScannedFile file, {
    required String nativeFileId,
  });
  Future<RecordingCardResult<RecordingCardWifiRecoveredDownload>>
  recoverWifiDownload(
    RecordingCardScannedFile file, {
    required String nativeFileId,
  });
}

/// Optional acknowledgement for releasing native resources retained across a
/// completed Wi-Fi-to-Bluetooth recovery.
abstract interface class RecordingCardWifiRecoverySettlementPort {
  Future<RecordingCardResult<bool>> settleWifiRecovery({
    required String batchId,
    required String attemptId,
    required String safeDeviceFingerprint,
  });
}

abstract interface class RecordingCardWifiJoinPort {
  Future<RecordingCardResult<bool>> joinWifiNetwork(
    RecordingCardWifiCredentials credentials,
  );
}

abstract interface class RecordingCardCancelableTransferPort {
  Future<RecordingCardResult<bool>> cancelFileTransfer();
}

/// Optional destructive capability for removing the current device binding.
abstract interface class RecordingCardUnbindPort {
  Future<RecordingCardResult<RecordingCardDeviceState>> unbindDevice({
    required String bindingTokenHex,
    bool deleteDeviceFiles = false,
  });
}

/// Optional capability for changing the connected card's advertised name.
abstract interface class RecordingCardBluetoothNamePort {
  Future<RecordingCardResult<RecordingCardDeviceState>> setBluetoothName({
    required String bluetoothName,
  });
}

/// Reads an account-binding claim without exposing the FW920 serial to Dart.
abstract interface class RecordingCardAccountClaimPort {
  Future<RecordingCardResult<RecordingCardAccountClaim>>
  readAccountBindingClaim();
}

/// Transient physical-possession proof used by the Backend SN ownership flow.
abstract interface class RecordingCardOwnershipProofPort {
  Future<RecordingCardResult<RecordingCardOwnershipIdentity>>
  readAccountBindingIdentity();

  Future<RecordingCardResult<RecordingCardOwnershipProof>>
  signAccountBindingChallenge({required String payloadJson});
}

final class UnavailableRecordingCardOwnershipProofPort
    implements RecordingCardOwnershipProofPort {
  const UnavailableRecordingCardOwnershipProofPort();

  @override
  Future<RecordingCardResult<RecordingCardOwnershipIdentity>>
  readAccountBindingIdentity() async => RecordingCardResult.failure(
    recordingCardFailure(
      'RECORDING_CARD_ATTESTATION_UNAVAILABLE',
      'Recording-card ownership proof is unavailable',
      isRetryable: false,
    ),
  );

  @override
  Future<RecordingCardResult<RecordingCardOwnershipProof>>
  signAccountBindingChallenge({required String payloadJson}) async =>
      RecordingCardResult.failure(
        recordingCardFailure(
          'RECORDING_CARD_ATTESTATION_UNAVAILABLE',
          'Recording-card ownership proof is unavailable',
          isRetryable: false,
        ),
      );
}

final class RecordingCardAccountClaim {
  const RecordingCardAccountClaim({required this.opaqueClaim});

  final String opaqueClaim;
}

final class RecordingCardOwnershipIdentity {
  const RecordingCardOwnershipIdentity({required this.serialNumber});

  final String serialNumber;
}

final class RecordingCardOwnershipProof {
  const RecordingCardOwnershipProof({
    required this.scheme,
    required this.keyId,
    required this.signature,
  });

  final String scheme;
  final String keyId;
  final String signature;
}

final class RecordingCardWifiCredentials {
  const RecordingCardWifiCredentials({
    required this.ssid,
    required this.password,
  });

  final String ssid;
  final String password;
}

final class RecordingCardWifiSessionInfo {
  const RecordingCardWifiSessionInfo({
    required this.sessionId,
    required this.files,
    this.openedAt,
  });

  final String sessionId;
  final List<RecordingCardScannedFile> files;
  final DateTime? openedAt;
}

enum RecordingCardWifiHandoffStatus { ready, networkUnavailable }

final class RecordingCardWifiHandoffResult {
  const RecordingCardWifiHandoffResult({required this.status});

  final RecordingCardWifiHandoffStatus status;
}

final class MethodChannelRecordingCardPort
    implements
        RecordingCardPort,
        RecordingCardRecoverableBluetoothTransferPort,
        RecordingCardDiscoveryCancellationPort,
        RecordingCardWifiTransferPort,
        RecordingCardWifiJoinPort,
        RecordingCardWifiSessionPort,
        RecordingCardWifiRecoveryPort,
        RecordingCardWifiRecoverySettlementPort,
        RecordingCardCancelableTransferPort,
        RecordingCardUnbindPort,
        RecordingCardBluetoothNamePort,
        RecordingCardAccountClaimPort,
        RecordingCardOwnershipProofPort {
  MethodChannelRecordingCardPort({
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
    Stream<Object?>? nativeEvents,
    DateTime Function()? clock,
    List<Duration> recordingStateInvalidationRetryDelays = const <Duration>[
      Duration.zero,
      Duration(milliseconds: 250),
      Duration(seconds: 1),
    ],
  }) : _methodChannel =
           methodChannel ?? const MethodChannel(_methodChannelName),
       _clock = clock ?? DateTime.now,
       _recordingStateInvalidationRetryDelays = List<Duration>.unmodifiable(
         recordingStateInvalidationRetryDelays,
       ) {
    final events =
        nativeEvents ??
        (eventChannel ?? const EventChannel(_eventChannelName))
            .receiveBroadcastStream();
    _nativeEventSubscription = events.listen(
      _handleNativeEvent,
      onError: (_) => _publishDeviceSessionSnapshot(
        _snapshot.copyWith(
          deviceState: RecordingCardDeviceState.error(
            permissionProblem: 'native_event_unavailable',
          ),
          lastDeviceUpdatedAt: _clock(),
        ),
      ),
    );
  }

  static const String _methodChannelName = 'huahuoai/recording_card';
  static const String _eventChannelName = 'huahuoai/recording_card/events';
  static const Set<String> _wifiAttemptDefinitelyNotInstalledCodes = <String>{
    'RECORDING_CARD_WIFI_SESSION_BUSY',
    'RECORDING_CARD_WIFI_ATTEMPT_INVALID',
    'RECORDING_CARD_WIFI_ATTEMPT_SUPERSEDED',
  };

  final MethodChannel _methodChannel;
  final DateTime Function() _clock;
  final List<Duration> _recordingStateInvalidationRetryDelays;
  final Set<RecordingCardRuntimeSnapshotListener> _listeners =
      <RecordingCardRuntimeSnapshotListener>{};
  StreamSubscription<Object?>? _nativeEventSubscription;
  RecordingCardRuntimeSnapshot _snapshot =
      RecordingCardRuntimeSnapshot.initial();
  int _snapshotRevision = 0;
  int _deviceSessionRevision = 0;
  int _transferOwnerRevision = 0;
  int _deviceStateCommandGeneration = 0;
  int _fileScanGeneration = 0;
  int _transferGeneration = 0;
  int _wifiSessionGeneration = 0;
  String? _wifiBatchId;
  String? _wifiAttemptId;
  final Set<void Function(RecordingCardWifiSessionObservation)> _wifiListeners =
      {};

  ({String? batchId, String? attemptId}) get _wifiAttemptIdentity =>
      (batchId: _wifiBatchId, attemptId: _wifiAttemptId);

  Map<String, Object?> get _wifiAttemptArguments =>
      _wifiAttemptArgumentsFor(_wifiAttemptIdentity);

  String? _activeTransferCorrelationId;
  final Set<String> _retiredTransferCorrelations = <String>{};
  var _recordingRevision = -1;
  Future<RecordingCardResult<RecordingCardRecordingInfo>>?
  _recordingStateReadInFlight;
  Future<void>? _recordingInvalidationRecoveryInFlight;
  bool _recordingInvalidationQueued = false;
  bool _disposed = false;
  int? _activeWifiSessionGeneration;
  bool _wifiSessionInFlightOrOpen = false;
  RecordingCardWifiSessionInfo? _activeWifiSession;
  List<RecordingCardScannedFile> _activeWifiRequestedFiles =
      const <RecordingCardScannedFile>[];

  @override
  RecordingCardRuntimeSnapshot get runtimeSnapshot => _snapshot;

  @override
  RecordingCardSnapshotSubscription subscribeRuntimeSnapshot(
    RecordingCardRuntimeSnapshotListener listener,
  ) {
    _listeners.add(listener);
    listener(_snapshot);
    return RecordingCardSnapshotSubscription(() => _listeners.remove(listener));
  }

  @override
  Future<RecordingCardResult<RecordingCardDeviceState>> connect({
    RecordingCardConnectRequest? request,
  }) async {
    return _invokeDeviceStateCommand(
      'connect',
      request?.toChannelMap() ?? const <String, Object?>{},
      project: (deviceState) => _snapshot.copyWith(
        deviceState: deviceState,
        files: _sameDeviceSessionOwner(_snapshot.deviceState, deviceState)
            ? _snapshot.files
            : const <RecordingCardScannedFile>[],
        loadingFiles: false,
        clearDownloadingFileKey: true,
        clearTransferProgress: true,
        lastDeviceUpdatedAt: _clock(),
      ),
    );
  }

  @override
  Future<RecordingCardResult<List<RecordingCardDiscoveredDevice>>>
  scanDevices() async {
    final result = await _invokeNative<List<RecordingCardDiscoveredDevice>>(
      'scanDevices',
      null,
      parse: parseRecordingCardDiscoveredDeviceList,
      onSuccess: (devices) => _publish(
        _snapshot.copyWith(
          discoveredDevices: devices,
          lastDeviceUpdatedAt: _clock(),
        ),
      ),
    );
    return result;
  }

  @override
  Future<RecordingCardResult<bool>> cancelDiscovery() {
    return _invokeNative<bool>(
      'cancelDiscovery',
      null,
      parse: _parseStrictBool,
    );
  }

  @override
  Future<RecordingCardResult<RecordingCardDeviceState>>
  getConnectionState() async {
    final snapshotRevision = _snapshotRevision;
    final result = await _invokeNative<RecordingCardDeviceState>(
      'getConnectionState',
      null,
      parse: parseRecordingCardDeviceState,
    );
    if (snapshotRevision != _snapshotRevision) {
      return RecordingCardResult<RecordingCardDeviceState>.failure(
        recordingCardFailure(
          'RECORDING_CARD_CONNECTION_QUERY_STALE',
          'Recording-card connection changed during foreground query',
          isRetryable: true,
        ),
      );
    }
    final deviceState = result.value;
    if (result.ok && deviceState != null) {
      _snapshot = _projectDeviceSessionSnapshot(
        _snapshot.copyWith(
          deviceState: deviceState,
          lastDeviceUpdatedAt: _clock(),
        ),
      );
      _snapshot = _enforceDisconnectedRecordingInvariant(_snapshot);
    }
    return result;
  }

  @override
  Future<RecordingCardResult<RecordingCardRuntimeSnapshot>>
  refreshDeviceInfo() async {
    final sessionRevision = _deviceSessionRevision;
    final fileScanGeneration = _fileScanGeneration;
    final result = await _invokeNative<RecordingCardRuntimeSnapshot>(
      'refreshDeviceInfo',
      null,
      parse: (raw) => parseRecordingCardRuntimeSnapshot(
        raw,
        fallbackObservationRevision: _recordingRevision + 1,
        fallbackObservedAt: _clock(),
      ),
    );
    if (sessionRevision != _deviceSessionRevision) {
      return _staleDeviceSessionResult<RecordingCardRuntimeSnapshot>();
    }
    final snapshot = result.value;
    if (result.ok && snapshot != null) {
      final merged = _mergeRuntimeSnapshot(snapshot);
      if (fileScanGeneration == _fileScanGeneration) {
        _publishDeviceSessionSnapshot(merged);
      } else {
        final current = _snapshot;
        _publishDeviceSessionSnapshot(
          RecordingCardRuntimeSnapshot(
            deviceState: merged.deviceState,
            recordingInfo: merged.recordingInfo,
            files: current.files,
            discoveredDevices: merged.discoveredDevices,
            loadingFiles: current.loadingFiles,
            downloadingFileKey: merged.downloadingFileKey,
            fileListDiagnostics: current.fileListDiagnostics,
            recordingObservation: merged.recordingObservation,
            transferProgress: merged.transferProgress,
            lastDeviceUpdatedAt: merged.lastDeviceUpdatedAt,
          ),
        );
      }
    }
    return result;
  }

  @override
  Future<RecordingCardResult<RecordingCardRecordingInfo>> readRecordingState() {
    return _readRecordingStateAuthoritatively();
  }

  @override
  Future<RecordingCardResult<RecordingCardRecordingInfo>> startRecording() {
    return _invokeRecordingCommand('startRecording');
  }

  @override
  Future<RecordingCardResult<RecordingCardRecordingInfo>> pauseRecording() {
    return _invokeRecordingCommand('pauseRecording');
  }

  @override
  Future<RecordingCardResult<RecordingCardRecordingInfo>> resumeRecording() {
    return _invokeRecordingCommand('resumeRecording');
  }

  @override
  Future<RecordingCardResult<RecordingCardRecordingInfo>> stopRecording() {
    return _invokeRecordingCommand('stopRecording');
  }

  @override
  Future<RecordingCardResult<List<RecordingCardScannedFile>>>
  scanFiles() async {
    final sessionRevision = _deviceSessionRevision;
    final scanGeneration = ++_fileScanGeneration;
    _publish(
      _snapshot.copyWith(loadingFiles: true, lastDeviceUpdatedAt: _clock()),
    );
    final result = await _invokeNative<List<RecordingCardScannedFile>>(
      'scanFiles',
      null,
      parse: parseRecordingCardFileList,
    );
    if (sessionRevision != _deviceSessionRevision ||
        scanGeneration != _fileScanGeneration) {
      return _staleDeviceSessionResult<List<RecordingCardScannedFile>>();
    }
    final files = result.value;
    if (result.ok && files != null) {
      _publish(
        _snapshot.copyWith(
          files: _mergeScannedFiles(files),
          loadingFiles: false,
          lastDeviceUpdatedAt: _clock(),
        ),
      );
    } else {
      _publish(
        _snapshot.copyWith(loadingFiles: false, lastDeviceUpdatedAt: _clock()),
      );
    }
    return result;
  }

  @override
  Future<RecordingCardResult<RecordingCardDownloadedFile>>
  downloadFileToLocalCache(RecordingCardScannedFile file) {
    return _downloadLike('downloadFileToLocalCache', file);
  }

  @override
  Future<RecordingCardResult<RecordingCardDownloadedFile>>
  downloadRecoverableBluetoothFile(
    RecordingCardScannedFile file, {
    required String plannedNativeFileId,
  }) => _downloadLike(
    'downloadRecoverableBluetoothFile',
    file,
    arguments: <String, Object?>{
      ...file.toChannelMap(),
      'plannedNativeFileId': plannedNativeFileId,
    },
  );

  @override
  Future<RecordingCardResult<RecordingCardBluetoothRecoveredDownload>>
  recoverBluetoothDownload(
    RecordingCardScannedFile file, {
    required String plannedNativeFileId,
  }) => _invokeNative<RecordingCardBluetoothRecoveredDownload>(
    'recoverBluetoothDownload',
    <String, Object?>{
      ...file.toChannelMap(),
      'plannedNativeFileId': plannedNativeFileId,
    },
    parse: (raw) {
      if (raw is Map && raw['exists'] == false) {
        return const RecordingCardBluetoothRecoveredDownload(null);
      }
      final downloaded = parseRecordingCardDownloadedFile(raw);
      return downloaded == null
          ? null
          : RecordingCardBluetoothRecoveredDownload(downloaded);
    },
  );

  @override
  Future<RecordingCardResult<RecordingCardDownloadedFile>> syncFileToLocalCache(
    RecordingCardScannedFile file,
  ) {
    return _downloadLike('syncFileToLocalCache', file);
  }

  @override
  Future<RecordingCardResult<RecordingCardDeleteResult>> deleteFileFromDevice(
    RecordingCardScannedFile file,
  ) async {
    final sessionRevision = _deviceSessionRevision;
    final result = await _invokeNative<RecordingCardDeleteResult>(
      'deleteFileFromDevice',
      file.toChannelMap(),
      parse: parseRecordingCardDeleteResult,
    );
    if (sessionRevision != _deviceSessionRevision) {
      return _staleDeviceSessionResult<RecordingCardDeleteResult>();
    }
    final deleted = result.value;
    if (result.ok && deleted != null) {
      _publish(
        _snapshot.copyWith(
          files: _snapshot.files
              .where((item) => item.deviceFileId != deleted.deviceFileId)
              .toList(growable: false),
          lastDeviceUpdatedAt: _clock(),
        ),
      );
    }
    return result;
  }

  @override
  Future<RecordingCardResult<RecordingCardDeviceState>> disconnect() async {
    final attemptIdentity = _wifiAttemptIdentity;
    final result = await _invokeDeviceStateCommand(
      'disconnect',
      null,
      project: (deviceState) => _snapshot.copyWith(
        deviceState: deviceState,
        files: const <RecordingCardScannedFile>[],
        loadingFiles: false,
        clearDownloadingFileKey: true,
        clearTransferProgress: true,
        lastDeviceUpdatedAt: _clock(),
      ),
    );
    if (result.ok && result.value?.isOperationallyConnected == false) {
      _clearWifiAttemptIdentityIfOwned(attemptIdentity);
    }
    return result;
  }

  @override
  Future<RecordingCardResult<RecordingCardDeviceState>> setBluetoothName({
    required String bluetoothName,
  }) {
    final normalizedName = normalizeRecordingCardBluetoothName(bluetoothName);
    if (normalizedName == null) {
      return Future<RecordingCardResult<RecordingCardDeviceState>>.value(
        RecordingCardResult<RecordingCardDeviceState>.failure(
          recordingCardFailure(
            'RECORDING_CARD_BLUETOOTH_NAME_INVALID',
            'Bluetooth name must be 1 to 32 UTF-8 bytes without control characters',
            isRetryable: false,
          ),
        ),
      );
    }
    return _invokeDeviceStateCommand(
      'setBluetoothName',
      <String, Object?>{'bluetoothName': normalizedName},
      project: (deviceState) => _snapshot.copyWith(
        deviceState: deviceState,
        lastDeviceUpdatedAt: _clock(),
      ),
    );
  }

  @override
  Future<RecordingCardResult<RecordingCardDeviceState>> unbindDevice({
    required String bindingTokenHex,
    bool deleteDeviceFiles = false,
  }) {
    return _invokeDeviceStateCommand(
      'unbindDevice',
      <String, Object?>{
        'bindingToken': bindingTokenHex,
        'deleteDeviceFiles': deleteDeviceFiles,
      },
      project: (deviceState) => RecordingCardRuntimeSnapshot(
        deviceState: deviceState,
        recordingInfo: RecordingCardRecordingInfo.idle(),
        files: const <RecordingCardScannedFile>[],
        discoveredDevices: _snapshot.discoveredDevices,
        loadingFiles: false,
        lastDeviceUpdatedAt: _clock(),
      ),
    );
  }

  @override
  Future<RecordingCardResult<RecordingCardAccountClaim>>
  readAccountBindingClaim() {
    return _invokeNative<RecordingCardAccountClaim>(
      'readAccountBindingClaim',
      null,
      parse: parseRecordingCardAccountClaim,
    );
  }

  @override
  Future<RecordingCardResult<RecordingCardOwnershipIdentity>>
  readAccountBindingIdentity() {
    return _invokeNative<RecordingCardOwnershipIdentity>(
      'readAccountBindingIdentity',
      null,
      parse: parseRecordingCardOwnershipIdentity,
    );
  }

  @override
  Future<RecordingCardResult<RecordingCardOwnershipProof>>
  signAccountBindingChallenge({required String payloadJson}) {
    final normalizedPayload = payloadJson.trim();
    if (normalizedPayload.isEmpty || normalizedPayload.length > 4096) {
      return Future<RecordingCardResult<RecordingCardOwnershipProof>>.value(
        RecordingCardResult.failure(
          recordingCardFailure(
            'RECORDING_CARD_ATTESTATION_PAYLOAD_INVALID',
            'Recording-card attestation payload is invalid',
            isRetryable: false,
          ),
        ),
      );
    }
    return _invokeNative<RecordingCardOwnershipProof>(
      'signAccountBindingChallenge',
      <String, Object?>{'payloadJson': normalizedPayload},
      parse: parseRecordingCardOwnershipProof,
    );
  }

  @override
  Future<RecordingCardResult<RecordingCardWifiCredentials>> prepareWifiTransfer(
    RecordingCardScannedFile file,
  ) {
    return _invokeNative<RecordingCardWifiCredentials>(
      'prepareWifiTransfer',
      file.toChannelMap(),
      parse: parseRecordingCardWifiCredentials,
    );
  }

  @override
  Future<RecordingCardResult<RecordingCardWifiHandoffResult>>
  verifyWifiHandoff() {
    return _invokeNative<RecordingCardWifiHandoffResult>(
      'verifyWifiHandoff',
      _wifiAttemptArguments,
      parse: parseRecordingCardWifiHandoffResult,
    );
  }

  @override
  Future<RecordingCardResult<RecordingCardDownloadedFile>> downloadFileOverWifi(
    RecordingCardScannedFile file,
  ) {
    return _downloadLike('downloadFileOverWifi', file);
  }

  @override
  Future<RecordingCardResult<bool>> beginWifiAttempt({
    required String batchId,
    required String attemptId,
  }) async {
    final generation = _wifiSessionGeneration;
    final previousIdentity = _wifiAttemptIdentity;
    final candidateIdentity = (batchId: batchId, attemptId: attemptId);
    _setWifiAttemptIdentity(candidateIdentity);
    final result = await _invokeNative<bool>('beginWifiAttempt', {
      'recoveryBatchId': batchId,
      'attemptId': attemptId,
    }, parse: _parseStrictTrue);
    if (_disposed ||
        generation != _wifiSessionGeneration ||
        !_ownsWifiAttemptIdentity(candidateIdentity)) {
      return _staleTransferOperationResult<bool>();
    }
    if (!result.ok &&
        _wifiAttemptDefinitelyNotInstalledCodes.contains(result.error?.code)) {
      _setWifiAttemptIdentity(previousIdentity);
    }
    return result;
  }

  @override
  Future<RecordingCardResult<RecordingCardWifiSessionObservation>>
  queryWifiSession() => _invokeNative<RecordingCardWifiSessionObservation>(
    'queryWifiSession',
    _wifiAttemptArguments,
    parse: RecordingCardWifiSessionObservation.fromChannel,
  );

  @override
  Future<RecordingCardResult<bool>> settleWifiRecovery({
    required String batchId,
    required String attemptId,
    required String safeDeviceFingerprint,
  }) => _invokeNative<bool>('settleWifiRecovery', <String, Object?>{
    'recoveryBatchId': batchId,
    'attemptId': attemptId,
    'safeDeviceFingerprint': safeDeviceFingerprint,
  }, parse: _parseStrictTrue);

  @override
  RecordingCardSnapshotSubscription subscribeWifiSession(
    void Function(RecordingCardWifiSessionObservation) listener,
  ) {
    _wifiListeners.add(listener);
    return RecordingCardSnapshotSubscription(
      () => _wifiListeners.remove(listener),
    );
  }

  @override
  Future<RecordingCardResult<RecordingCardWifiRecoveredDownload>>
  recoverWifiDownload(
    RecordingCardScannedFile file, {
    required String nativeFileId,
  }) async {
    final filename = file.deviceFilename.trim().toLowerCase();
    final filenameFormat = RecordingCardFileFormat.values
        .where(
          (format) =>
              format != RecordingCardFileFormat.unknown &&
              filename.endsWith('.${format.name}'),
        )
        .firstOrNull;
    final formats = file.format != RecordingCardFileFormat.unknown
        ? <RecordingCardFileFormat>[file.format]
        : filenameFormat != null
        ? <RecordingCardFileFormat>[filenameFormat]
        : RecordingCardFileFormat.values.where(
            (format) => format != RecordingCardFileFormat.unknown,
          );
    for (final format in formats) {
      final result = await _invokeNative<RecordingCardWifiRecoveredDownload>(
        'recoverWifiDownload',
        {
          ...file.toChannelMap(),
          'format': format.name,
          'plannedNativeFileId': nativeFileId,
        },
        parse: (raw) {
          if (raw is Map && raw['exists'] == false) {
            return const RecordingCardWifiRecoveredDownload(null);
          }
          final downloaded = parseRecordingCardDownloadedFile(raw);
          return downloaded == null
              ? null
              : RecordingCardWifiRecoveredDownload(downloaded);
        },
      );
      if (!result.ok || result.value?.file != null) {
        return result;
      }
    }
    return RecordingCardResult<RecordingCardWifiRecoveredDownload>.success(
      const RecordingCardWifiRecoveredDownload(null),
    );
  }

  @override
  Future<RecordingCardResult<RecordingCardDownloadedFile>>
  downloadRecoverableWifiFile(
    RecordingCardScannedFile file, {
    required String nativeFileId,
  }) => _downloadWifiSessionFile(file, nativeFileId: nativeFileId);

  @override
  Future<RecordingCardResult<RecordingCardWifiCredentials>> prepareWifiSession(
    List<RecordingCardScannedFile> files,
  ) {
    return _invokeNative<RecordingCardWifiCredentials>('prepareWifiSession', {
      ..._wifiFilesArgument(files),
      ..._wifiAttemptArguments,
    }, parse: parseRecordingCardWifiCredentials);
  }

  @override
  Future<RecordingCardResult<bool>> joinWifiNetwork(
    RecordingCardWifiCredentials credentials,
  ) {
    return _invokeNative<bool>('joinWifiNetwork', <String, Object?>{
      ..._wifiAttemptArguments,
      'ssid': credentials.ssid,
      'password': credentials.password,
    }, parse: _parseStrictTrue);
  }

  @override
  Future<RecordingCardResult<RecordingCardWifiSessionInfo>> openWifiSession(
    List<RecordingCardScannedFile> files,
  ) async {
    final sessionGeneration = ++_wifiSessionGeneration;
    _clearWifiSessionContext();
    _retireTransferCorrelation();
    _transferGeneration += 1;
    _wifiSessionInFlightOrOpen = true;
    final result = await _invokeNative<RecordingCardWifiSessionInfo>(
      'openWifiSession',
      {..._wifiFilesArgument(files), ..._wifiAttemptArguments},
      parse: (raw) => parseRecordingCardWifiSessionInfo(raw, files),
    );
    if (sessionGeneration != _wifiSessionGeneration) {
      return _staleWifiSessionResult<RecordingCardWifiSessionInfo>();
    }
    if (result.ok && result.value != null) {
      _activeWifiSessionGeneration = sessionGeneration;
      _activeWifiSession = result.value;
      _activeWifiRequestedFiles = List<RecordingCardScannedFile>.unmodifiable(
        files,
      );
      _publish(
        _snapshot.copyWith(
          clearDownloadingFileKey: true,
          clearTransferProgress: true,
          lastDeviceUpdatedAt: _clock(),
        ),
      );
    } else {
      _clearWifiSessionContext(expectedGeneration: sessionGeneration);
    }
    return result;
  }

  @override
  Future<RecordingCardResult<RecordingCardDownloadedFile>>
  downloadFileInWifiSession(RecordingCardScannedFile file) =>
      _downloadWifiSessionFile(file);

  Future<RecordingCardResult<RecordingCardDownloadedFile>>
  _downloadWifiSessionFile(
    RecordingCardScannedFile file, {
    String? nativeFileId,
  }) {
    final sessionGeneration = _wifiSessionGeneration;
    final hasCurrentSession = _activeWifiSessionGeneration == sessionGeneration;
    final session = hasCurrentSession ? _activeWifiSession : null;
    final files = hasCurrentSession
        ? _activeWifiRequestedFiles
        : const <RecordingCardScannedFile>[];
    final index = files.indexWhere(
      (candidate) => candidate.deviceFileId == file.deviceFileId,
    );
    final aggregateTotal = files.fold<int>(
      0,
      (total, candidate) => total + (candidate.sizeBytes ?? 0),
    );
    final aggregateBase = index <= 0
        ? 0
        : files
              .take(index)
              .fold<int>(
                0,
                (total, candidate) => total + (candidate.sizeBytes ?? 0),
              );
    return _downloadLike(
      'downloadFileInWifiSession',
      file,
      arguments: <String, Object?>{
        ...file.toChannelMap(),
        ..._wifiAttemptArguments,
        if (nativeFileId != null) 'plannedNativeFileId': nativeFileId,
        if (session != null) 'sessionId': session.sessionId,
        if (session != null) 'batchId': session.sessionId,
        if (index >= 0) 'fileIndex': index,
        if (index >= 0) 'fileCount': files.length,
        if (index >= 0) 'aggregateReceivedBytes': aggregateBase,
        if (aggregateTotal > 0) 'aggregateTotalBytes': aggregateTotal,
      },
      wifiSessionGeneration: sessionGeneration,
    );
  }

  @override
  Future<RecordingCardResult<bool>> closeWifiSession() async {
    final attemptIdentity = _wifiAttemptIdentity;
    final teardownGeneration = ++_wifiSessionGeneration;
    _clearWifiSessionContext();
    try {
      final result = await _invokeNative<bool>(
        'closeWifiSession',
        _wifiAttemptArgumentsFor(attemptIdentity),
        parse: _parseTransferCancellation,
      );
      if (result.ok && result.value == true) {
        _clearWifiAttemptIdentityIfOwned(attemptIdentity);
      }
      return result;
    } finally {
      _clearWifiSessionContext(expectedGeneration: teardownGeneration);
    }
  }

  @override
  Future<RecordingCardResult<bool>> cancelWifiSession() async {
    final attemptIdentity = _wifiAttemptIdentity;
    final teardownGeneration = ++_wifiSessionGeneration;
    _clearWifiSessionContext();
    try {
      final result = await _cancelTransfer(
        'cancelWifiSession',
        wifiSessionGeneration: teardownGeneration,
        preserveReceiptWhenSuperseded: true,
        wifiAttemptArguments: _wifiAttemptArgumentsFor(attemptIdentity),
      );
      if (result.ok && result.value == true) {
        _clearWifiAttemptIdentityIfOwned(attemptIdentity);
      }
      return result;
    } finally {
      _clearWifiSessionContext(expectedGeneration: teardownGeneration);
    }
  }

  @override
  Future<RecordingCardResult<bool>> cancelFileTransfer() {
    return _cancelTransfer('cancelFileTransfer');
  }

  Future<RecordingCardResult<bool>> _cancelTransfer(
    String method, {
    int? wifiSessionGeneration,
    bool preserveReceiptWhenSuperseded = false,
    Map<String, Object?>? wifiAttemptArguments,
  }) async {
    final sessionRevision = _deviceSessionRevision;
    final generation = _transferGeneration;
    final fileKey =
        _snapshot.transferProgress?.localFileKey ??
        _snapshot.downloadingFileKey;
    final result = await _invokeNative<bool>(
      method,
      method == 'cancelWifiSession'
          ? wifiAttemptArguments ?? _wifiAttemptArguments
          : null,
      parse: _parseTransferCancellation,
    );
    if (!_ownsTransfer(
      sessionRevision,
      generation,
      wifiSessionGeneration: wifiSessionGeneration,
    )) {
      if (preserveReceiptWhenSuperseded) return result;
      return _staleTransferOperationResult<bool>();
    }
    if (result.ok) {
      _retireTransferCorrelation();
      _transferGeneration += 1;
      _publish(
        _snapshot.copyWith(
          clearDownloadingFileKey: true,
          clearTransferProgress: true,
          files: _restoreCancelledDownload(fileKey),
          lastDeviceUpdatedAt: _clock(),
        ),
      );
    }
    return result;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _recordingInvalidationQueued = false;
    try {
      await disconnect();
    } finally {
      _setWifiAttemptIdentity((batchId: null, attemptId: null));
      _deviceStateCommandGeneration += 1;
      _advanceDeviceSession();
      await _nativeEventSubscription?.cancel();
      _nativeEventSubscription = null;
      _recordingStateReadInFlight = null;
      _recordingInvalidationRecoveryInFlight = null;
      _listeners.clear();
      _wifiListeners.clear();
      _retiredTransferCorrelations.clear();
      _snapshot = RecordingCardRuntimeSnapshot.initial();
    }
  }

  Future<RecordingCardResult<RecordingCardRecordingInfo>>
  _invokeRecordingCommand(String method) async {
    final sessionRevision = _deviceSessionRevision;
    try {
      final raw = await _methodChannel.invokeMethod<Object?>(method);
      final observation = parseRecordingCardRecordingObservation(
        raw,
        fallbackSource: RecordingCardObservationSource.command,
        fallbackRevision: _recordingRevision + 1,
        fallbackObservedAt: _clock(),
      );
      if (observation == null) {
        return RecordingCardResult<RecordingCardRecordingInfo>.failure(
          recordingCardFailure(
            'NATIVE_RECORDING_CARD_MALFORMED_PAYLOAD',
            'Native recording-card payload was malformed',
            isRetryable: true,
          ),
        );
      }
      if (sessionRevision != _deviceSessionRevision) {
        return _staleDeviceSessionResult<RecordingCardRecordingInfo>();
      }
      _publish(_snapshotWithRecordingObservation(observation));
      return RecordingCardResult<RecordingCardRecordingInfo>.success(
        _snapshot.recordingInfo,
      );
    } on MissingPluginException catch (error) {
      return RecordingCardResult<RecordingCardRecordingInfo>.failure(
        nativeRecordingCardUnavailable(error),
      );
    } on PlatformException catch (error) {
      return RecordingCardResult<RecordingCardRecordingInfo>.failure(
        _platformFailure(error),
      );
    } catch (error) {
      return RecordingCardResult<RecordingCardRecordingInfo>.failure(
        recordingCardFailure(
          'NATIVE_RECORDING_CARD_METHOD_FAILED',
          'Native recording-card method failed',
          isRetryable: true,
          cause: error,
        ),
      );
    }
  }

  Future<RecordingCardResult<RecordingCardRecordingInfo>>
  _readRecordingStateAuthoritatively() {
    final running = _recordingStateReadInFlight;
    if (running != null) return running;
    if (_disposed || !_snapshot.deviceState.isOperationallyConnected) {
      return Future<RecordingCardResult<RecordingCardRecordingInfo>>.value(
        RecordingCardResult<RecordingCardRecordingInfo>.failure(
          recordingCardFailure(
            'RECORDING_CARD_NOT_CONNECTED',
            'Recording-card is not connected',
            isRetryable: true,
          ),
        ),
      );
    }

    late final Future<RecordingCardResult<RecordingCardRecordingInfo>>
    operation;
    operation = _invokeRecordingCommand('readRecordingState');
    _recordingStateReadInFlight = operation;
    unawaited(
      operation.whenComplete(() {
        if (!identical(_recordingStateReadInFlight, operation)) return;
        _recordingStateReadInFlight = null;
      }),
    );
    return operation;
  }

  void _scheduleRecordingInvalidationRecovery() {
    if (_disposed || !_snapshot.deviceState.isOperationallyConnected) return;
    _recordingInvalidationQueued = true;
    if (_recordingInvalidationRecoveryInFlight != null) return;
    late final Future<void> operation;
    operation = _recoverRecordingStateAfterInvalidation().whenComplete(() {
      if (!identical(_recordingInvalidationRecoveryInFlight, operation)) return;
      _recordingInvalidationRecoveryInFlight = null;
      if (!_disposed &&
          _recordingInvalidationQueued &&
          _snapshot.deviceState.isOperationallyConnected) {
        _scheduleRecordingInvalidationRecovery();
      }
    });
    _recordingInvalidationRecoveryInFlight = operation;
  }

  Future<void> _recoverRecordingStateAfterInvalidation() async {
    final sessionRevision = _deviceSessionRevision;
    final existingRead = _recordingStateReadInFlight;
    if (existingRead != null) {
      await existingRead;
      if (_disposed || sessionRevision != _deviceSessionRevision) return;
    }
    final delays = _recordingStateInvalidationRetryDelays.isEmpty
        ? const <Duration>[Duration.zero]
        : _recordingStateInvalidationRetryDelays;
    while (_recordingInvalidationQueued) {
      _recordingInvalidationQueued = false;
      for (final delay in delays) {
        if (delay > Duration.zero) await Future<void>.delayed(delay);
        if (_disposed ||
            sessionRevision != _deviceSessionRevision ||
            !_snapshot.deviceState.isOperationallyConnected) {
          return;
        }
        final result = await _readRecordingStateAuthoritatively();
        if (_disposed || sessionRevision != _deviceSessionRevision) return;
        if (result.ok && result.value != null) break;
        if (result.error?.isRetryable != true) break;
      }
    }
  }

  Future<RecordingCardResult<RecordingCardDownloadedFile>> _downloadLike(
    String method,
    RecordingCardScannedFile file, {
    Object? arguments,
    int? wifiSessionGeneration,
  }) async {
    final deviceSessionRevision = _deviceSessionRevision;
    final transferOwnerRevision = _transferOwnerRevision;
    _retireTransferCorrelation();
    final generation = ++_transferGeneration;
    _publish(
      _snapshot.copyWith(
        downloadingFileKey: file.localFileKey,
        clearTransferProgress: true,
        files: _snapshot.files
            .map(
              (item) => item.localFileKey == file.localFileKey
                  ? item.copyWith(
                      syncState: RecordingCardFileSyncState.downloading,
                    )
                  : item,
            )
            .toList(growable: false),
        lastDeviceUpdatedAt: _clock(),
      ),
    );
    final result = await _invokeNative<RecordingCardDownloadedFile>(
      method,
      arguments ?? file.toChannelMap(),
      parse: parseRecordingCardDownloadedFile,
    );
    final ownsTransferProjection = _ownsTransfer(
      deviceSessionRevision,
      generation,
      wifiSessionGeneration: wifiSessionGeneration,
    );
    if (!ownsTransferProjection && !result.ok) {
      return _staleTransferOperationResult<RecordingCardDownloadedFile>();
    }
    final canMergeReceipt =
        !_disposed && transferOwnerRevision == _transferOwnerRevision;
    if (ownsTransferProjection) _retireTransferCorrelation();
    final downloaded = result.value;
    if (result.ok && downloaded != null && canMergeReceipt) {
      _publish(
        _snapshot.copyWith(
          clearDownloadingFileKey: ownsTransferProjection,
          clearTransferProgress: ownsTransferProjection,
          files: _mergeDownloadedFile(downloaded),
          lastDeviceUpdatedAt: _clock(),
        ),
      );
    } else if (!result.ok && ownsTransferProjection) {
      _publish(
        _snapshot.copyWith(
          clearDownloadingFileKey: true,
          clearTransferProgress: true,
          files: _snapshot.files
              .map(
                (item) => item.localFileKey == file.localFileKey
                    ? item.copyWith(
                        syncState: RecordingCardFileSyncState.failed,
                      )
                    : item,
              )
              .toList(growable: false),
          lastDeviceUpdatedAt: _clock(),
        ),
      );
    }
    return result;
  }

  void _clearWifiSessionContext({int? expectedGeneration}) {
    if (expectedGeneration != null &&
        expectedGeneration != _wifiSessionGeneration) {
      return;
    }
    _activeWifiSessionGeneration = null;
    _wifiSessionInFlightOrOpen = false;
    _activeWifiSession = null;
    _activeWifiRequestedFiles = const <RecordingCardScannedFile>[];
  }

  Map<String, Object?> _wifiAttemptArgumentsFor(
    ({String? batchId, String? attemptId}) identity,
  ) => <String, Object?>{
    if (identity.batchId != null) 'recoveryBatchId': identity.batchId,
    if (identity.attemptId != null) 'attemptId': identity.attemptId,
  };

  bool _ownsWifiAttemptIdentity(
    ({String? batchId, String? attemptId}) identity,
  ) => _wifiBatchId == identity.batchId && _wifiAttemptId == identity.attemptId;

  void _setWifiAttemptIdentity(
    ({String? batchId, String? attemptId}) identity,
  ) {
    _wifiBatchId = identity.batchId;
    _wifiAttemptId = identity.attemptId;
  }

  void _clearWifiAttemptIdentityIfOwned(
    ({String? batchId, String? attemptId}) identity,
  ) {
    if (!_ownsWifiAttemptIdentity(identity)) return;
    _setWifiAttemptIdentity((batchId: null, attemptId: null));
  }

  RecordingCardResult<T> _staleWifiSessionResult<T>() {
    return RecordingCardResult<T>.failure(
      recordingCardFailure(
        'RECORDING_CARD_WIFI_SESSION_STALE',
        'Recording-card Wi-Fi session operation was superseded',
        isRetryable: true,
      ),
    );
  }

  bool _ownsWifiTransferProgress(RecordingCardTransferProgress progress) {
    if (progress.transport != RecordingCardTransferTransport.wifi ||
        progress.batchId == null) {
      return true;
    }
    return _activeWifiSessionGeneration == _wifiSessionGeneration &&
        _activeWifiSession?.sessionId == progress.batchId;
  }

  void _retireTransferCorrelation() {
    final correlationId = _activeTransferCorrelationId;
    if (correlationId != null) _retiredTransferCorrelations.add(correlationId);
    _activeTransferCorrelationId = null;
  }

  List<RecordingCardScannedFile> _restoreCancelledDownload(String? activeKey) {
    if (activeKey == null) return _snapshot.files;
    return _snapshot.files
        .map(
          (item) =>
              item.localFileKey == activeKey &&
                  (item.syncState == RecordingCardFileSyncState.downloading ||
                      item.syncState == RecordingCardFileSyncState.failed)
              ? item.copyWith(syncState: RecordingCardFileSyncState.deviceOnly)
              : item,
        )
        .toList(growable: false);
  }

  List<RecordingCardScannedFile> _mergeDownloadedFile(
    RecordingCardDownloadedFile downloaded,
  ) {
    return _snapshot.files
        .map(
          (item) => item.localFileKey == downloaded.localFileKey
              ? item.copyWith(
                  syncState: RecordingCardFileSyncState.synced,
                  durationSeconds: downloaded.durationSeconds,
                  localFileId: downloaded.localFileId,
                  appPrivateUri: downloaded.appPrivateUri,
                )
              : item,
        )
        .toList(growable: false);
  }

  Future<RecordingCardResult<RecordingCardDeviceState>>
  _invokeDeviceStateCommand(
    String method,
    Object? arguments, {
    required RecordingCardRuntimeSnapshot Function(
      RecordingCardDeviceState deviceState,
    )
    project,
  }) async {
    final commandGeneration = ++_deviceStateCommandGeneration;
    final snapshotRevision = _snapshotRevision;
    _advanceDeviceSession();
    final result = await _invokeNative<RecordingCardDeviceState>(
      method,
      arguments,
      parse: parseRecordingCardDeviceState,
    );
    if (commandGeneration != _deviceStateCommandGeneration) {
      return _staleDeviceOperationResult();
    }
    final deviceState = result.value;
    if (result.ok && deviceState != null) {
      if (snapshotRevision != _snapshotRevision &&
          !_compatibleDeviceStateResult(_snapshot.deviceState, deviceState)) {
        return _staleDeviceOperationResult();
      }
      _publishDeviceSessionSnapshot(project(deviceState));
    }
    return result;
  }

  RecordingCardResult<RecordingCardDeviceState> _staleDeviceOperationResult() {
    return RecordingCardResult<RecordingCardDeviceState>.failure(
      recordingCardFailure(
        'RECORDING_CARD_DEVICE_OPERATION_STALE',
        'Recording-card device operation was superseded',
        isRetryable: true,
      ),
    );
  }

  RecordingCardResult<T> _staleDeviceSessionResult<T>() {
    return RecordingCardResult<T>.failure(
      recordingCardFailure(
        'RECORDING_CARD_DEVICE_SESSION_STALE',
        'Recording-card device session changed during the operation',
        isRetryable: true,
      ),
    );
  }

  bool _ownsTransfer(
    int sessionRevision,
    int generation, {
    int? wifiSessionGeneration,
  }) {
    return !_disposed &&
        (wifiSessionGeneration == null
            ? sessionRevision == _deviceSessionRevision
            : wifiSessionGeneration == _wifiSessionGeneration) &&
        generation == _transferGeneration;
  }

  RecordingCardResult<T> _staleTransferOperationResult<T>() {
    return RecordingCardResult<T>.failure(
      recordingCardFailure(
        'RECORDING_CARD_TRANSFER_OPERATION_STALE',
        'Recording-card transfer operation was superseded',
        isRetryable: true,
      ),
    );
  }

  Future<RecordingCardResult<T>> _invokeNative<T>(
    String method,
    Object? arguments, {
    required T? Function(Object? raw) parse,
    void Function(T value)? onSuccess,
  }) async {
    try {
      final raw = await _methodChannel.invokeMethod<Object?>(method, arguments);
      final parsed = parse(raw);
      if (parsed == null) {
        return RecordingCardResult<T>.failure(
          recordingCardFailure(
            'NATIVE_RECORDING_CARD_MALFORMED_PAYLOAD',
            'Native recording-card payload was malformed',
            isRetryable: true,
          ),
        );
      }
      onSuccess?.call(parsed);
      return RecordingCardResult<T>.success(parsed);
    } on MissingPluginException catch (error) {
      return RecordingCardResult<T>.failure(
        nativeRecordingCardUnavailable(error),
      );
    } on PlatformException catch (error) {
      return RecordingCardResult<T>.failure(_platformFailure(error));
    } catch (error) {
      return RecordingCardResult<T>.failure(
        recordingCardFailure(
          'NATIVE_RECORDING_CARD_METHOD_FAILED',
          'Native recording-card method failed',
          isRetryable: true,
          cause: error,
        ),
      );
    }
  }

  void _handleNativeEvent(Object? event) {
    if (_disposed) return;
    final object = _asStringMap(event);
    if (object == null) return;
    final type = _string(object['type']);
    switch (type) {
      case 'wifi_session':
        final observation = RecordingCardWifiSessionObservation.fromChannel(
          object,
        );
        if (observation != null) {
          for (final listener in List.of(_wifiListeners)) {
            listener(observation);
          }
        }
      case 'runtime_snapshot':
        final snapshot = parseRecordingCardRuntimeSnapshot(
          object['snapshot'] ?? object,
          fallbackObservationRevision: _recordingRevision + 1,
          fallbackObservedAt: _clock(),
        );
        if (snapshot != null) {
          _publishDeviceSessionSnapshot(_mergeRuntimeSnapshot(snapshot));
        }
      case 'connection_state':
        final deviceState = parseRecordingCardDeviceState(
          object['deviceState'] ?? object,
        );
        if (deviceState != null) {
          _publishDeviceSessionSnapshot(
            _snapshot.copyWith(
              deviceState: _mergeDeviceState(deviceState),
              lastDeviceUpdatedAt: _clock(),
            ),
          );
        }
      case 'recording_state':
        if (!_snapshot.deviceState.isOperationallyConnected) return;
        final observation = parseRecordingCardRecordingObservation(
          object['recordingInfo'] ?? object,
          fallbackSource: RecordingCardObservationSource.statusNotification,
          fallbackRevision: _recordingRevision + 1,
          fallbackObservedAt: _clock(),
        );
        if (observation != null) {
          _publish(_snapshotWithRecordingObservation(observation));
        }
      case 'recording_state_invalidated':
        if (_snapshot.deviceState.isOperationallyConnected) {
          _scheduleRecordingInvalidationRecovery();
        }
      case 'transfer_progress':
        final progressAttempt = _string(object['attemptId']);
        if (progressAttempt != null &&
            progressAttempt.isNotEmpty &&
            (progressAttempt != _wifiAttemptId ||
                _string(object['recoveryBatchId']) != _wifiBatchId)) {
          return;
        }
        final progress = parseRecordingCardTransferProgress(
          object['progress'] ?? object,
        );
        if (progress != null && _ownsWifiTransferProgress(progress)) {
          _publish(
            _snapshot.copyWith(
              downloadingFileKey: progress.localFileKey,
              transferProgress: progress,
              lastDeviceUpdatedAt: _clock(),
            ),
          );
        }
      default:
        return;
    }
  }

  RecordingCardRuntimeSnapshot _mergeRuntimeSnapshot(
    RecordingCardRuntimeSnapshot next,
  ) {
    var ownedNext = next;
    if (_activeWifiSessionGeneration == _wifiSessionGeneration &&
        (next.transferProgress == null ||
            !_ownsWifiTransferProgress(next.transferProgress!))) {
      ownedNext = next.copyWith(
        downloadingFileKey: _snapshot.downloadingFileKey,
        transferProgress: _snapshot.transferProgress,
        clearDownloadingFileKey: _snapshot.downloadingFileKey == null,
        clearTransferProgress: _snapshot.transferProgress == null,
      );
    }
    final observation = ownedNext.recordingObservation;
    final base = ownedNext.copyWith(
      deviceState: _mergeDeviceState(ownedNext.deviceState),
      files:
          _deviceSessionBoundaryChanged(
                _snapshot.deviceState,
                ownedNext.deviceState,
              ) &&
              !_preservesWifiSession(ownedNext.deviceState)
          ? ownedNext.files
          : _mergeScannedFiles(ownedNext.files),
    );
    if (!base.deviceState.isOperationallyConnected) {
      return _enforceDisconnectedRecordingInvariant(base);
    }
    if (observation == null) {
      final sessionChanged = _deviceSessionBoundaryChanged(
        _snapshot.deviceState,
        base.deviceState,
      );
      return base.copyWith(
        recordingInfo: sessionChanged
            ? RecordingCardRecordingInfo.idle()
            : _snapshot.recordingInfo,
        recordingObservation: sessionChanged
            ? null
            : _snapshot.recordingObservation,
        clearRecordingObservation: sessionChanged,
      );
    }
    return _snapshotWithRecordingObservation(observation, base: base);
  }

  List<RecordingCardScannedFile> _mergeScannedFiles(
    List<RecordingCardScannedFile> next,
  ) {
    final syncedByKey = <String, RecordingCardScannedFile>{
      for (final file in _snapshot.files)
        if (file.syncState == RecordingCardFileSyncState.synced &&
            file.appPrivateUri != null)
          file.localFileKey: file,
    };
    return next
        .map((file) {
          final synced = syncedByKey[file.localFileKey];
          if (synced == null) return file;
          return file.copyWith(
            syncState: RecordingCardFileSyncState.synced,
            durationSeconds: file.durationSeconds ?? synced.durationSeconds,
            localFileId: synced.localFileId,
            appPrivateUri: synced.appPrivateUri,
          );
        })
        .toList(growable: false);
  }

  RecordingCardDeviceState _mergeDeviceState(RecordingCardDeviceState next) {
    if (next.connectionState == RecordingCardConnectionState.disconnected ||
        next.connectionState == RecordingCardConnectionState.error) {
      return next;
    }
    final current = _snapshot.deviceState;
    return next.copyWith(
      displayName: next.displayName ?? current.displayName,
      safeDeviceFingerprint:
          next.safeDeviceFingerprint ?? current.safeDeviceFingerprint,
      serialNumber: next.serialNumber ?? current.serialNumber,
      batteryPercent: next.batteryPercent ?? current.batteryPercent,
      storageTotalBytes: next.storageTotalBytes ?? current.storageTotalBytes,
      storageFreeBytes: next.storageFreeBytes ?? current.storageFreeBytes,
      storageUsedBytes: next.storageUsedBytes ?? current.storageUsedBytes,
      firmwareVersion: next.firmwareVersion ?? current.firmwareVersion,
      deviceModel: next.deviceModel ?? current.deviceModel,
      wifiSupported: next.wifiSupported ?? current.wifiSupported,
      wifiFirmwareVersion:
          next.wifiFirmwareVersion ?? current.wifiFirmwareVersion,
      recordingFormat: next.recordingFormat == RecordingCardFileFormat.unknown
          ? current.recordingFormat
          : next.recordingFormat,
      lastInfoRefreshedAt:
          next.lastInfoRefreshedAt ?? current.lastInfoRefreshedAt,
      permissionProblem: next.permissionProblem,
      statusMessage: next.statusMessage,
      clearPermissionProblem: next.permissionProblem == null,
      clearStatusMessage: next.statusMessage == null,
    );
  }

  RecordingCardRuntimeSnapshot _snapshotWithRecordingObservation(
    RecordingCardRecordingObservation observation, {
    RecordingCardRuntimeSnapshot? base,
  }) {
    final target = base ?? _snapshot;
    final sessionChanged = _deviceSessionBoundaryChanged(
      _snapshot.deviceState,
      target.deviceState,
    );
    if (!sessionChanged && observation.revision <= _recordingRevision) {
      return target.copyWith(
        recordingInfo: _snapshot.recordingInfo,
        recordingObservation: _snapshot.recordingObservation,
      );
    }
    final merged = mergeRecordingCardRecordingObservation(
      sessionChanged
          ? RecordingCardRecordingInfo.idle()
          : _snapshot.recordingInfo,
      observation,
    );
    _recordingRevision = observation.revision;
    return target.copyWith(
      recordingInfo: merged,
      recordingObservation: observation.copyWith(info: merged),
      lastDeviceUpdatedAt: observation.observedAt,
    );
  }

  void _publishDeviceSessionSnapshot(RecordingCardRuntimeSnapshot snapshot) {
    _publish(_projectDeviceSessionSnapshot(snapshot));
  }

  void _advanceDeviceSession({bool preserveWifiSession = false}) {
    _deviceSessionRevision += 1;
    _recordingStateReadInFlight = null;
    _recordingInvalidationRecoveryInFlight = null;
    _recordingInvalidationQueued = false;
    if (!preserveWifiSession) {
      _transferOwnerRevision += 1;
      _wifiSessionGeneration += 1;
      _clearWifiSessionContext();
      _retireTransferCorrelation();
    }
  }

  bool _preservesWifiSession(RecordingCardDeviceState deviceState) {
    return _wifiSessionInFlightOrOpen &&
        (deviceState.connectionState ==
                RecordingCardConnectionState.disconnected ||
            deviceState.connectionState == RecordingCardConnectionState.error);
  }

  RecordingCardRuntimeSnapshot _projectDeviceSessionSnapshot(
    RecordingCardRuntimeSnapshot snapshot,
  ) {
    var projected = snapshot;
    if (_deviceSessionBoundaryChanged(
      _snapshot.deviceState,
      snapshot.deviceState,
    )) {
      final preserveWifiSession = _preservesWifiSession(snapshot.deviceState);
      _advanceDeviceSession(preserveWifiSession: preserveWifiSession);
      if (identical(
        snapshot.recordingObservation,
        _snapshot.recordingObservation,
      )) {
        projected = snapshot.copyWith(
          recordingInfo: RecordingCardRecordingInfo.idle(),
          clearRecordingObservation: true,
        );
      }
      projected = projected.copyWith(
        files:
            !preserveWifiSession &&
                (!snapshot.deviceState.isOperationallyConnected ||
                    identical(snapshot.files, _snapshot.files))
            ? const <RecordingCardScannedFile>[]
            : projected.files,
        loadingFiles: false,
        clearDownloadingFileKey:
            !preserveWifiSession &&
            identical(snapshot.transferProgress, _snapshot.transferProgress) &&
            snapshot.downloadingFileKey == _snapshot.downloadingFileKey,
        clearTransferProgress:
            !preserveWifiSession &&
            identical(snapshot.transferProgress, _snapshot.transferProgress),
      );
      _recordingRevision = projected.recordingObservation?.revision ?? -1;
    }
    return projected;
  }

  bool _deviceSessionBoundaryChanged(
    RecordingCardDeviceState current,
    RecordingCardDeviceState next,
  ) {
    if (current.connectionState != next.connectionState) return true;
    return current.isOperationallyConnected &&
        next.isOperationallyConnected &&
        !_sameDeviceSessionOwner(current, next);
  }

  bool _compatibleDeviceStateResult(
    RecordingCardDeviceState current,
    RecordingCardDeviceState result,
  ) {
    final compatibleState =
        current.connectionState == result.connectionState ||
        (current.connectionState == RecordingCardConnectionState.connecting &&
            result.connectionState == RecordingCardConnectionState.connected);
    if (!compatibleState) return false;
    return _sameDeviceSessionOwner(current, result);
  }

  bool _sameDeviceSessionOwner(
    RecordingCardDeviceState left,
    RecordingCardDeviceState right,
  ) {
    final leftSerial = left.serialNumber?.trim();
    final rightSerial = right.serialNumber?.trim();
    if (leftSerial != null &&
        leftSerial.isNotEmpty &&
        rightSerial != null &&
        rightSerial.isNotEmpty &&
        leftSerial != rightSerial) {
      return false;
    }
    final leftFingerprint = left.safeDeviceFingerprint?.trim();
    final rightFingerprint = right.safeDeviceFingerprint?.trim();
    if (leftFingerprint != null &&
        leftFingerprint.isNotEmpty &&
        rightFingerprint != null &&
        rightFingerprint.isNotEmpty &&
        leftFingerprint != rightFingerprint) {
      return false;
    }
    return true;
  }

  void _publish(RecordingCardRuntimeSnapshot snapshot) {
    final nextProgress = snapshot.transferProgress;
    if (nextProgress != null &&
        _retiredTransferCorrelations.contains(nextProgress.correlationId)) {
      final currentProgress = _snapshot.transferProgress;
      final currentRetired =
          currentProgress != null &&
          _retiredTransferCorrelations.contains(currentProgress.correlationId);
      snapshot = snapshot.copyWith(
        transferProgress: currentProgress,
        downloadingFileKey: _snapshot.downloadingFileKey,
        clearTransferProgress: currentProgress == null || currentRetired,
        clearDownloadingFileKey:
            _snapshot.downloadingFileKey == null || currentRetired,
      );
    } else if (nextProgress != null &&
        nextProgress.correlationId != _activeTransferCorrelationId) {
      if (_activeTransferCorrelationId != null ||
          nextProgress.localFileKey != _snapshot.downloadingFileKey) {
        _transferGeneration += 1;
      }
      _retireTransferCorrelation();
      _activeTransferCorrelationId = nextProgress.correlationId;
    }
    _snapshotRevision += 1;
    _snapshot = _enforceDisconnectedRecordingInvariant(snapshot);
    for (final listener in List<RecordingCardRuntimeSnapshotListener>.of(
      _listeners,
    )) {
      listener(_snapshot);
    }
  }

  RecordingCardRuntimeSnapshot _enforceDisconnectedRecordingInvariant(
    RecordingCardRuntimeSnapshot snapshot,
  ) {
    if (snapshot.deviceState.isOperationallyConnected) return snapshot;
    return snapshot.copyWith(
      recordingInfo: const RecordingCardRecordingInfo(
        state: RecordingCardRecordingState.idle,
        durationSeconds: 0,
      ),
      clearRecordingObservation: true,
    );
  }
}

final class UnavailableRecordingCardPort implements RecordingCardPort {
  const UnavailableRecordingCardPort();

  @override
  RecordingCardRuntimeSnapshot get runtimeSnapshot =>
      RecordingCardRuntimeSnapshot(
        deviceState: RecordingCardDeviceState.error(
          permissionProblem: 'driver_unsupported',
        ),
        recordingInfo: RecordingCardRecordingInfo.idle(),
        files: const <RecordingCardScannedFile>[],
        discoveredDevices: const <RecordingCardDiscoveredDevice>[],
      );

  @override
  RecordingCardSnapshotSubscription subscribeRuntimeSnapshot(
    RecordingCardRuntimeSnapshotListener listener,
  ) {
    listener(runtimeSnapshot);
    return const RecordingCardSnapshotSubscription(_noop);
  }

  @override
  Future<RecordingCardResult<RecordingCardDeviceState>> connect({
    RecordingCardConnectRequest? request,
  }) async {
    return RecordingCardResult<RecordingCardDeviceState>.failure(
      nativeRecordingCardUnavailable(),
    );
  }

  @override
  Future<RecordingCardResult<List<RecordingCardDiscoveredDevice>>>
  scanDevices() async {
    return RecordingCardResult<List<RecordingCardDiscoveredDevice>>.failure(
      nativeRecordingCardUnavailable(),
    );
  }

  @override
  Future<RecordingCardResult<RecordingCardDeviceState>>
  getConnectionState() async {
    return RecordingCardResult<RecordingCardDeviceState>.success(
      runtimeSnapshot.deviceState,
    );
  }

  @override
  Future<RecordingCardResult<RecordingCardRuntimeSnapshot>>
  refreshDeviceInfo() async {
    return RecordingCardResult<RecordingCardRuntimeSnapshot>.failure(
      nativeRecordingCardUnavailable(),
    );
  }

  @override
  Future<RecordingCardResult<RecordingCardRecordingInfo>>
  readRecordingState() async {
    return RecordingCardResult<RecordingCardRecordingInfo>.failure(
      _notConnectedFailure(),
    );
  }

  @override
  Future<RecordingCardResult<RecordingCardRecordingInfo>>
  startRecording() async {
    return RecordingCardResult<RecordingCardRecordingInfo>.failure(
      nativeRecordingCardUnavailable(),
    );
  }

  @override
  Future<RecordingCardResult<RecordingCardRecordingInfo>>
  pauseRecording() async {
    return RecordingCardResult<RecordingCardRecordingInfo>.failure(
      nativeRecordingCardUnavailable(),
    );
  }

  @override
  Future<RecordingCardResult<RecordingCardRecordingInfo>>
  resumeRecording() async {
    return RecordingCardResult<RecordingCardRecordingInfo>.failure(
      nativeRecordingCardUnavailable(),
    );
  }

  @override
  Future<RecordingCardResult<RecordingCardRecordingInfo>>
  stopRecording() async {
    return RecordingCardResult<RecordingCardRecordingInfo>.failure(
      nativeRecordingCardUnavailable(),
    );
  }

  @override
  Future<RecordingCardResult<List<RecordingCardScannedFile>>>
  scanFiles() async {
    return RecordingCardResult<List<RecordingCardScannedFile>>.failure(
      nativeRecordingCardUnavailable(),
    );
  }

  @override
  Future<RecordingCardResult<RecordingCardDownloadedFile>>
  downloadFileToLocalCache(RecordingCardScannedFile file) async {
    return RecordingCardResult<RecordingCardDownloadedFile>.failure(
      nativeRecordingCardUnavailable(),
    );
  }

  @override
  Future<RecordingCardResult<RecordingCardDownloadedFile>> syncFileToLocalCache(
    RecordingCardScannedFile file,
  ) async {
    return RecordingCardResult<RecordingCardDownloadedFile>.failure(
      nativeRecordingCardUnavailable(),
    );
  }

  @override
  Future<RecordingCardResult<RecordingCardDeleteResult>> deleteFileFromDevice(
    RecordingCardScannedFile file,
  ) async {
    return RecordingCardResult<RecordingCardDeleteResult>.failure(
      nativeRecordingCardUnavailable(),
    );
  }

  @override
  Future<RecordingCardResult<RecordingCardDeviceState>> disconnect() async {
    return RecordingCardResult<RecordingCardDeviceState>.success(
      RecordingCardDeviceState.disconnected(),
    );
  }
}

RecordingCardDeviceState? parseRecordingCardDeviceState(Object? raw) {
  final object = _asStringMap(raw);
  if (object == null) return null;
  final connectionState = _parseConnectionState(
    object['connectionState'] ?? object['state'],
  );
  if (connectionState == null) return null;
  final fingerprint = _safeOptionalIdentifier(object['safeDeviceFingerprint']);
  return RecordingCardDeviceState(
    connectionState: connectionState,
    connectionStage:
        _parseConnectionStage(object['connectionStage']) ??
        (connectionState == RecordingCardConnectionState.connected
            ? RecordingCardConnectionStage.connected
            : RecordingCardConnectionStage.idle),
    displayName: _safeOptionalDisplayText(object['displayName']),
    safeDeviceFingerprint: fingerprint,
    serialNumber: _safeOptionalRecordingCardConnectedSerialNumber(
      object['serialNumber'],
    ),
    batteryPercent: _boundedInt(object['batteryPercent'], min: 0, max: 100),
    storageTotalBytes: _nonNegativeInt(object['storageTotalBytes']),
    storageFreeBytes: _nonNegativeInt(object['storageFreeBytes']),
    storageUsedBytes: _nonNegativeInt(object['storageUsedBytes']),
    firmwareVersion: _safeOptionalIdentifier(object['firmwareVersion']),
    deviceModel: _safeOptionalDisplayText(object['deviceModel']),
    wifiSupported: object['wifiSupported'] is bool
        ? object['wifiSupported'] as bool
        : null,
    wifiFirmwareVersion: _safeOptionalIdentifier(object['wifiFirmwareVersion']),
    recordingFormat:
        _parseFileFormat(object['recordingFormat']) ??
        RecordingCardFileFormat.unknown,
    lastInfoRefreshedAt: _date(object['lastInfoRefreshedAt']),
    permissionProblem: _safeOptionalIdentifier(object['permissionProblem']),
    statusMessage: _safeOptionalDisplayText(object['statusMessage']),
  );
}

RecordingCardAccountClaim? parseRecordingCardAccountClaim(Object? raw) {
  final object = _asStringMap(raw);
  if (object == null || object.length != 1) return null;
  final claim = object['opaqueClaim'];
  if (claim is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(claim)) {
    return null;
  }
  return RecordingCardAccountClaim(opaqueClaim: claim);
}

RecordingCardOwnershipIdentity? parseRecordingCardOwnershipIdentity(
  Object? raw,
) {
  final object = _asStringMap(raw);
  if (object == null || object.length != 1) return null;
  final serialNumber = object['serialNumber'];
  if (serialNumber is! String ||
      !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{5,63}$').hasMatch(serialNumber)) {
    return null;
  }
  return RecordingCardOwnershipIdentity(serialNumber: serialNumber);
}

RecordingCardOwnershipProof? parseRecordingCardOwnershipProof(Object? raw) {
  final object = _asStringMap(raw);
  if (object == null || object.length != 3) return null;
  final scheme = object['scheme'];
  final keyId = object['keyId'];
  final signature = object['signature'];
  if (scheme != 'card-v1' ||
      keyId is! String ||
      !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,119}$').hasMatch(keyId) ||
      signature is! String ||
      !RegExp(r'^[A-Za-z0-9_-]{86}$').hasMatch(signature)) {
    return null;
  }
  return RecordingCardOwnershipProof(
    scheme: scheme as String,
    keyId: keyId,
    signature: signature,
  );
}

RecordingCardRecordingInfo? parseRecordingCardRecordingInfo(Object? raw) {
  final object = _asStringMap(raw);
  if (object == null) return null;
  final state = _parseRecordingState(
    object['state'] ?? object['recordingState'],
  );
  if (state == null) return null;
  return RecordingCardRecordingInfo(
    state: state,
    currentFileName: _safeOptionalDisplayText(object['currentFileName']),
    startedAt: _date(object['startedAt']),
    durationSeconds: _nonNegativeInt(object['durationSeconds']),
  );
}

RecordingCardRecordingObservation? parseRecordingCardRecordingObservation(
  Object? raw, {
  required RecordingCardObservationSource fallbackSource,
  required int fallbackRevision,
  required DateTime fallbackObservedAt,
}) {
  final object = _asStringMap(raw);
  final info = parseRecordingCardRecordingInfo(raw);
  if (object == null || info == null) return null;
  final source =
      _parseObservationSource(object['observationSource']) ?? fallbackSource;
  final revision = _nonNegativeInt(object['revision']) ?? fallbackRevision;
  final observedAt = _date(object['observedAt']) ?? fallbackObservedAt;
  return RecordingCardRecordingObservation(
    info: info,
    source: source,
    revision: revision,
    observedAt: observedAt,
  );
}

RecordingCardTransferProgress? parseRecordingCardTransferProgress(Object? raw) {
  final object = _asStringMap(raw);
  if (object == null) return null;
  final localFileKey = _safeOptionalIdentifier(object['localFileKey']);
  final correlationId = _safeOptionalIdentifier(object['correlationId']);
  final receivedBytes = _nonNegativeInt(object['receivedBytes']);
  final totalBytes = _positiveFileSize(object['totalBytes']);
  final fileIndex = _nonNegativeInt(object['fileIndex']);
  final fileCount = _positiveFileSize(object['fileCount']);
  final aggregateReceivedBytes = _nonNegativeInt(
    object['aggregateReceivedBytes'],
  );
  final aggregateTotalBytes = _positiveFileSize(object['aggregateTotalBytes']);
  if (localFileKey == null ||
      correlationId == null ||
      receivedBytes == null ||
      (totalBytes != null && receivedBytes > totalBytes) ||
      (fileIndex != null && fileCount != null && fileIndex >= fileCount) ||
      (aggregateReceivedBytes != null &&
          aggregateTotalBytes != null &&
          aggregateReceivedBytes > aggregateTotalBytes)) {
    return null;
  }
  return RecordingCardTransferProgress(
    localFileKey: localFileKey,
    receivedBytes: receivedBytes,
    totalBytes: totalBytes,
    correlationId: correlationId,
    startedAt: _date(object['startedAt']),
    updatedAt: _date(object['updatedAt']),
    directorySizeMismatch: object['directorySizeMismatch'] == true,
    transport: _parseTransferTransport(object['transport']),
    batchId: _safeOptionalIdentifier(object['batchId']),
    fileIndex: fileIndex,
    fileCount: fileCount,
    aggregateReceivedBytes: aggregateReceivedBytes,
    aggregateTotalBytes: aggregateTotalBytes,
    phase: _parseTransferPhase(object['phase']),
    bytesPerSecond: _nonNegativeDouble(object['bytesPerSecond']),
    estimatedRemainingSeconds: _nonNegativeInt(
      object['estimatedRemainingSeconds'],
    ),
  );
}

RecordingCardDiscoveredDevice? parseRecordingCardDiscoveredDevice(Object? raw) {
  final object = _asStringMap(raw);
  if (object == null) return null;
  final displayName = _safeOptionalDisplayText(object['displayName']);
  final fingerprint = _safeOptionalIdentifier(object['safeDeviceFingerprint']);
  if (displayName == null || fingerprint == null) return null;
  return RecordingCardDiscoveredDevice(
    displayName: displayName,
    safeDeviceFingerprint: fingerprint,
    serialNumber: _safeOptionalRecordingCardAdvertisementSerialNumber(
      object['serialNumber'],
    ),
    rssi: _boundedInt(object['rssi'], min: -127, max: 40),
    isConnectable: object['isConnectable'] is bool
        ? object['isConnectable'] as bool
        : null,
    lastSeenAt: _date(object['lastSeenAt']),
  );
}

String? _safeOptionalRecordingCardAdvertisementSerialNumber(Object? value) {
  if (value is! String || value.length < 6 || value.length > 64) return null;
  var normalizedLength = 0;
  for (var index = 0; index < value.length; index += 1) {
    final codeUnit = value.codeUnitAt(index);
    final isAlphaNumeric =
        (codeUnit >= 0x30 && codeUnit <= 0x39) ||
        (codeUnit >= 0x41 && codeUnit <= 0x5a) ||
        (codeUnit >= 0x61 && codeUnit <= 0x7a);
    if (isAlphaNumeric) {
      normalizedLength += 1;
      continue;
    }
    if (index == 0 || (codeUnit != 0x2d && codeUnit != 0x3a)) return null;
  }
  return normalizedLength >= 6 ? value : null;
}

String? _safeOptionalRecordingCardConnectedSerialNumber(Object? value) {
  if (value is! String || value.length < 6 || value.length > 64) return null;
  return RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{5,63}$').hasMatch(value)
      ? value
      : null;
}

List<RecordingCardDiscoveredDevice>? parseRecordingCardDiscoveredDeviceList(
  Object? raw,
) {
  final object = _asStringMap(raw);
  final devices = object == null ? raw : object['devices'];
  if (devices is! Iterable) return null;
  final parsed = <RecordingCardDiscoveredDevice>[];
  for (final device in devices) {
    final parsedDevice = parseRecordingCardDiscoveredDevice(device);
    if (parsedDevice == null) return null;
    parsed.add(parsedDevice);
  }
  return List<RecordingCardDiscoveredDevice>.unmodifiable(parsed);
}

RecordingCardScannedFile? parseRecordingCardScannedFile(Object? raw) {
  final object = _asStringMap(raw);
  if (object == null) return null;
  final localFileKey = _safeOptionalIdentifier(object['localFileKey']);
  final deviceFilename = _safeOptionalDisplayText(object['deviceFilename']);
  final deviceFileId =
      _safeOptionalIdentifier(object['deviceFileId']) ?? localFileKey;
  if (localFileKey == null || deviceFileId == null || deviceFilename == null) {
    return null;
  }
  final appPrivateUri = _safeOptionalUri(object['appPrivateUri']);
  return RecordingCardScannedFile(
    deviceFileId: deviceFileId,
    localFileKey: localFileKey,
    deviceFilename: deviceFilename,
    sizeBytes: _nonNegativeInt(object['sizeBytes']),
    durationSeconds: _nonNegativeInt(object['durationSeconds']),
    recordedAt:
        _date(object['recordedAt']) ??
        _recordedAtFromDeviceFilename(deviceFilename),
    contentHash: _safeOptionalIdentifier(object['contentHash']),
    sizeConfidence: _parseSizeConfidence(object['sizeConfidence']),
    format:
        _parseFileFormat(object['format']) ?? RecordingCardFileFormat.unknown,
    mimeType: _safeOptionalIdentifier(object['mimeType']),
    syncState:
        _parseFileSyncState(object['syncState']) ??
        RecordingCardFileSyncState.deviceOnly,
    localFileId: _safeOptionalIdentifier(object['localFileId']),
    appPrivateUri: appPrivateUri,
  );
}

List<RecordingCardScannedFile>? parseRecordingCardFileList(Object? raw) {
  final object = _asStringMap(raw);
  final files = object == null ? raw : object['files'];
  if (files is! Iterable) return null;
  final parsed = <RecordingCardScannedFile>[];
  for (final file in files) {
    final parsedFile = parseRecordingCardScannedFile(file);
    if (parsedFile == null) return null;
    parsed.add(parsedFile);
  }
  return List<RecordingCardScannedFile>.unmodifiable(parsed);
}

RecordingCardDownloadedFile? parseRecordingCardDownloadedFile(Object? raw) {
  final object = _asStringMap(raw);
  if (object == null) return null;
  final localFileKey = _safeOptionalIdentifier(object['localFileKey']);
  final appPrivateUri = _safeRecordingLibraryUri(
    object['appPrivateUri'] ?? object['localUri'],
  );
  if (localFileKey == null || appPrivateUri == null) return null;
  return RecordingCardDownloadedFile(
    localFileKey: localFileKey,
    appPrivateUri: appPrivateUri,
    localFileId: _safeOptionalIdentifier(object['localFileId']),
    displayName: _safeOptionalDisplayText(object['displayName']),
    durationSeconds: _nonNegativeInt(object['durationSeconds']),
    sizeBytes: _nonNegativeInt(object['sizeBytes']),
    contentHash: _safeOptionalIdentifier(
      object['contentHash'] ?? object['sha256'],
    ),
    format:
        _parseFileFormat(object['format']) ?? RecordingCardFileFormat.unknown,
    mimeType: _safeOptionalIdentifier(object['mimeType']),
  );
}

RecordingCardDeleteResult? parseRecordingCardDeleteResult(Object? raw) {
  final object = _asStringMap(raw);
  if (object == null || object['deleted'] != true) return null;
  final deviceFileId = _safeOptionalIdentifier(object['deviceFileId']);
  final deviceFilename = _safeOptionalDisplayText(object['deviceFilename']);
  if (deviceFileId == null || deviceFilename == null) return null;
  return RecordingCardDeleteResult(
    deviceFileId: deviceFileId,
    deviceFilename: deviceFilename,
  );
}

RecordingCardWifiCredentials? parseRecordingCardWifiCredentials(Object? raw) {
  final object = _asStringMap(raw);
  if (object == null) return null;
  final ssid = _safeWifiCredential(object['ssid'], maxLength: 64);
  final password = _safeWifiCredential(object['password'], maxLength: 128);
  if (ssid == null || password == null) return null;
  return RecordingCardWifiCredentials(ssid: ssid, password: password);
}

RecordingCardWifiSessionInfo? parseRecordingCardWifiSessionInfo(
  Object? raw,
  List<RecordingCardScannedFile> requestedFiles,
) {
  final object = _asStringMap(raw);
  if (object == null) return null;
  final sessionId = _safeOptionalIdentifier(object['sessionId']);
  if (sessionId == null) return null;
  final rawFiles = object['files'];
  final files = rawFiles == null
      ? List<RecordingCardScannedFile>.unmodifiable(requestedFiles)
      : parseRecordingCardFileList(rawFiles);
  if (files == null) return null;
  return RecordingCardWifiSessionInfo(
    sessionId: sessionId,
    files: files,
    openedAt: _date(object['openedAt']),
  );
}

RecordingCardWifiHandoffResult? parseRecordingCardWifiHandoffResult(
  Object? raw,
) {
  final object = _asStringMap(raw);
  final status = object?['status'];
  return switch (status) {
    'ready' ||
    'firmwareTransferUnverified' => const RecordingCardWifiHandoffResult(
      status: RecordingCardWifiHandoffStatus.ready,
    ),
    'networkUnavailable' => const RecordingCardWifiHandoffResult(
      status: RecordingCardWifiHandoffStatus.networkUnavailable,
    ),
    _ => null,
  };
}

RecordingCardRuntimeSnapshot? parseRecordingCardRuntimeSnapshot(
  Object? raw, {
  int fallbackObservationRevision = 0,
  DateTime? fallbackObservedAt,
}) {
  final object = _asStringMap(raw);
  if (object == null) return null;
  final deviceState = parseRecordingCardDeviceState(object['deviceState']);
  final recordingObservation = parseRecordingCardRecordingObservation(
    object['recordingInfo'],
    fallbackSource: RecordingCardObservationSource.runtimeSnapshot,
    fallbackRevision: fallbackObservationRevision,
    fallbackObservedAt:
        fallbackObservedAt ?? DateTime.fromMillisecondsSinceEpoch(0),
  );
  final recordingInfo =
      recordingObservation?.info ?? RecordingCardRecordingInfo.idle();
  final files = parseRecordingCardFileList(
    object['files'] ?? const <Object?>[],
  );
  final discoveredDevices = parseRecordingCardDiscoveredDeviceList(
    object['discoveredDevices'] ?? const <Object?>[],
  );
  if (deviceState == null || files == null || discoveredDevices == null) {
    return null;
  }
  return RecordingCardRuntimeSnapshot(
    deviceState: deviceState,
    recordingInfo: recordingInfo,
    files: files,
    discoveredDevices: discoveredDevices,
    loadingFiles: object['loadingFiles'] == true,
    downloadingFileKey: _safeOptionalIdentifier(object['downloadingFileKey']),
    fileListDiagnostics: _parseFileListDiagnostics(
      object['fileListDiagnostics'],
    ),
    recordingObservation: recordingObservation,
    transferProgress: parseRecordingCardTransferProgress(
      object['transferProgress'],
    ),
    lastDeviceUpdatedAt: _date(object['lastDeviceUpdatedAt']),
  );
}

AppFailure nativeRecordingCardUnavailable([Object? cause]) {
  return recordingCardFailure(
    'NATIVE_RECORDING_CARD_DRIVER_UNAVAILABLE',
    'Native recording-card driver is unavailable',
    isRetryable: false,
    recoveryActions: const <String>['none'],
    cause: cause,
  );
}

AppFailure recordingCardFailure(
  String code,
  String message, {
  bool isRetryable = true,
  List<String>? recoveryActions,
  Object? cause,
}) {
  return AppFailure(
    code: code,
    category: AppFailureCategory.compatibility,
    message: message,
    userMessageKey: 'recordingCard.error.$code',
    isRetryable: isRetryable,
    recoveryActions:
        recoveryActions ??
        (isRetryable ? const <String>['retry'] : const <String>['none']),
    cause: cause,
  );
}

RecordingCardFailureStage recordingCardFailureStage(String code) {
  final normalized = code.toUpperCase();
  if (normalized.contains('BUSY') ||
      normalized.contains('IN_PROGRESS') ||
      normalized.contains('DEFERRED') ||
      normalized.contains('SUPERSEDED') ||
      normalized.contains('STALE') ||
      normalized.contains('CANCELLED')) {
    return RecordingCardFailureStage.coordination;
  }
  if (normalized.contains('FILE_NOT_FOUND') ||
      normalized.contains('REQUEST_REJECTED') ||
      normalized.contains('COMMAND_REJECTED')) {
    return RecordingCardFailureStage.request;
  }
  if (normalized.contains('LOCAL_STORAGE') ||
      normalized.contains('LOCAL_FILE') ||
      normalized.contains('LOCAL_LIBRARY') ||
      normalized.contains('CHECKPOINT') ||
      normalized.contains('PERSIST')) {
    return RecordingCardFailureStage.storage;
  }
  if (normalized.contains('SIZE_MISMATCH') ||
      normalized.contains('IDENTITY_MISMATCH') ||
      normalized.contains('CHECKSUM') ||
      normalized.contains('PROTOCOL_INVALID') ||
      normalized.contains('PROTOCOL_ORDER') ||
      normalized.contains('INCOMPLETE') ||
      normalized.contains('MALFORMED')) {
    return RecordingCardFailureStage.verification;
  }
  if (normalized.contains('BLUETOOTH') ||
      normalized.contains('NOT_CONNECTED') ||
      normalized.contains('DISCONNECTED') ||
      normalized.contains('CONNECT') ||
      normalized.contains('SERVICE') ||
      normalized.contains('CHARACTERISTIC') ||
      normalized.contains('NOTIFICATION') ||
      normalized.contains('HANDSHAKE') ||
      normalized.contains('PROFILE') ||
      normalized.contains('BINDING')) {
    return RecordingCardFailureStage.connection;
  }
  if (normalized.contains('DOWNLOAD') ||
      normalized.contains('OFFLINE_TRANSFER') ||
      normalized.contains('WIFI') ||
      normalized.contains('WRITE')) {
    return RecordingCardFailureStage.transfer;
  }
  return RecordingCardFailureStage.request;
}

bool isSafeRecordingCardIdentifier(String value) {
  final text = value.trim();
  if (text.isEmpty || text.length > 160) return false;
  return !_unsafeRecordingCardText(text);
}

RecordingCardRecordingInfo mergeRecordingCardRecordingObservation(
  RecordingCardRecordingInfo current,
  RecordingCardRecordingObservation observation,
) {
  final next = observation.info;
  if (next.state == RecordingCardRecordingState.idle) {
    return const RecordingCardRecordingInfo(
      state: RecordingCardRecordingState.idle,
      durationSeconds: 0,
    );
  }
  final nextName = next.currentFileName;
  final currentName = current.currentFileName;
  final newRecording =
      current.state == RecordingCardRecordingState.idle ||
      (nextName != null && currentName != null && nextName != currentName);
  final fileName = nextName ?? (newRecording ? null : currentName);
  final retainedDuration = newRecording
      ? 0
      : recordingCardElapsedSeconds(current, now: observation.observedAt);
  if (next.state == RecordingCardRecordingState.paused) {
    return RecordingCardRecordingInfo(
      state: next.state,
      currentFileName: fileName,
      durationSeconds: next.durationSeconds ?? retainedDuration,
    );
  }
  if (next.startedAt != null) {
    return RecordingCardRecordingInfo(
      state: next.state,
      currentFileName: fileName,
      startedAt: next.startedAt,
      durationSeconds:
          next.durationSeconds ??
          (newRecording ? 0 : current.durationSeconds ?? 0),
    );
  }
  if (next.durationSeconds != null) {
    return RecordingCardRecordingInfo(
      state: next.state,
      currentFileName: fileName,
      startedAt: observation.observedAt,
      durationSeconds: next.durationSeconds,
    );
  }
  if (!newRecording &&
      current.state == RecordingCardRecordingState.recording &&
      current.startedAt != null) {
    return RecordingCardRecordingInfo(
      state: next.state,
      currentFileName: fileName,
      startedAt: current.startedAt,
      durationSeconds: current.durationSeconds ?? 0,
    );
  }
  return RecordingCardRecordingInfo(
    state: next.state,
    currentFileName: fileName,
    startedAt: observation.observedAt,
    durationSeconds: retainedDuration,
  );
}

int recordingCardElapsedSeconds(
  RecordingCardRecordingInfo info, {
  DateTime? now,
}) {
  final base = info.durationSeconds == null || info.durationSeconds! < 0
      ? 0
      : info.durationSeconds!;
  final startedAt = info.startedAt;
  if (startedAt == null ||
      info.state != RecordingCardRecordingState.recording) {
    return base;
  }
  final elapsed = (now ?? DateTime.now()).difference(startedAt).inSeconds;
  return base + (elapsed < 0 ? 0 : elapsed);
}

AppFailure _platformFailure(PlatformException error) {
  final code =
      _safeOptionalIdentifier(error.code) ??
      'NATIVE_RECORDING_CARD_METHOD_FAILED';
  if (code == 'NATIVE_RECORDING_CARD_DRIVER_UNAVAILABLE' ||
      code == 'native_unsupported') {
    return nativeRecordingCardUnavailable(error);
  }
  if (code == 'RECORDING_CARD_BLUETOOTH_PERMISSION_REQUIRED' ||
      code == 'RECORDING_CARD_BLUETOOTH_UNAUTHORIZED') {
    return AppFailure(
      code: code,
      category: AppFailureCategory.permission,
      message: 'Bluetooth permission is required for recording-card access',
      userMessageKey: 'recordingCard.error.$code',
      isRetryable: true,
      recoveryActions: const <String>['open_settings', 'retry'],
      cause: error,
    );
  }
  if (code == 'RECORDING_CARD_BLUETOOTH_UNSUPPORTED') {
    return recordingCardFailure(
      code,
      'Bluetooth LE is unavailable on this device',
      isRetryable: false,
      recoveryActions: const <String>['none'],
      cause: error,
    );
  }
  if (code == 'RECORDING_CARD_BLUETOOTH_POWERED_OFF') {
    return recordingCardFailure(
      code,
      'Bluetooth is powered off',
      recoveryActions: const <String>['enable_bluetooth', 'retry'],
      cause: error,
    );
  }
  if (code == 'RECORDING_CARD_LOCATION_SERVICES_DISABLED') {
    return recordingCardFailure(
      code,
      'System location services are required for legacy Android BLE discovery',
      recoveryActions: const <String>['open_location_settings', 'retry'],
      cause: error,
    );
  }
  if (code == 'RECORDING_CARD_SCAN_CANCELLED') {
    return recordingCardFailure(
      code,
      'Recording-card discovery was cancelled',
      isRetryable: false,
      recoveryActions: const <String>['none'],
      cause: error,
    );
  }
  return recordingCardFailure(
    code,
    'Native recording-card method failed',
    isRetryable: true,
    cause: error,
  );
}

AppFailure _notConnectedFailure() {
  return recordingCardFailure(
    'RECORDING_CARD_NOT_CONNECTED',
    'Recording card is not connected',
    isRetryable: true,
  );
}

RecordingCardFileListDiagnostics? _parseFileListDiagnostics(Object? raw) {
  final object = _asStringMap(raw);
  if (object == null) return null;
  return RecordingCardFileListDiagnostics(
    invalidRowCount: _nonNegativeInt(object['invalidRowCount']) ?? 0,
    firstInvalidReason: _safeOptionalIdentifier(object['firstInvalidReason']),
  );
}

Map<String, Object?>? _asStringMap(Object? raw) {
  if (raw is! Map) return null;
  final result = <String, Object?>{};
  for (final entry in raw.entries) {
    final key = entry.key;
    if (key is String) result[key] = entry.value;
  }
  return result;
}

RecordingCardConnectionState? _parseConnectionState(Object? raw) {
  final value = _string(raw);
  switch (value) {
    case 'disconnected':
    case 'idle':
      return RecordingCardConnectionState.disconnected;
    case 'connecting':
    case 'scanning':
    case 'connected_unverified':
    case 'subscribing_notifications':
      return RecordingCardConnectionState.connecting;
    case 'connected':
    case 'ble_ready':
      return RecordingCardConnectionState.connected;
    case 'error':
    case 'failed':
    case 'connect_failed':
    case 'native_unsupported':
      return RecordingCardConnectionState.error;
  }
  return null;
}

RecordingCardConnectionStage? _parseConnectionStage(Object? raw) {
  return _parseEnum(RecordingCardConnectionStage.values, raw);
}

RecordingCardRecordingState? _parseRecordingState(Object? raw) {
  return _parseEnum(RecordingCardRecordingState.values, raw);
}

RecordingCardObservationSource? _parseObservationSource(Object? raw) {
  return _parseEnum(RecordingCardObservationSource.values, raw);
}

RecordingCardFileFormat? _parseFileFormat(Object? raw) {
  return _parseEnum(RecordingCardFileFormat.values, raw);
}

RecordingCardFileSizeConfidence? _parseSizeConfidence(Object? raw) {
  return _parseEnum(RecordingCardFileSizeConfidence.values, raw);
}

RecordingCardFileSyncState? _parseFileSyncState(Object? raw) {
  return _parseEnum(RecordingCardFileSyncState.values, raw);
}

RecordingCardTransferTransport? _parseTransferTransport(Object? raw) {
  return _parseEnum(RecordingCardTransferTransport.values, raw);
}

RecordingCardTransferPhase? _parseTransferPhase(Object? raw) {
  return _parseEnum(RecordingCardTransferPhase.values, raw);
}

T? _parseEnum<T extends Enum>(List<T> values, Object? raw) {
  final value = _string(raw);
  if (value == null) return null;
  for (final candidate in values) {
    if (candidate.name == value) return candidate;
  }
  return null;
}

String? _string(Object? value) {
  if (value is! String) return null;
  final text = value.trim();
  return text.isEmpty ? null : text;
}

String? _safeOptionalIdentifier(Object? value) {
  final text = _string(value);
  return text != null && isSafeRecordingCardIdentifier(text) ? text : null;
}

String? _safeOptionalDisplayText(Object? value) {
  final text = _string(value);
  if (text == null || text.length > 120 || _unsafeRecordingCardText(text)) {
    return null;
  }
  return text;
}

String? _safeWifiCredential(Object? value, {required int maxLength}) {
  if (value is! String) return null;
  final text = value.trim();
  if (text.isEmpty || text.length > maxLength) return null;
  if (text.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f)) return null;
  return text;
}

String? _safeOptionalUri(Object? value) {
  final text = _safeOptionalIdentifier(value);
  if (text == null) return null;
  if (!RegExp(r'^[a-z][a-z0-9+.-]*://', caseSensitive: false).hasMatch(text)) {
    return null;
  }
  if (text.toLowerCase().startsWith('file://') ||
      text.toLowerCase().startsWith('http://') ||
      text.toLowerCase().startsWith('https://')) {
    return null;
  }
  return text;
}

String? _safeRecordingLibraryUri(Object? value) {
  final text = _safeOptionalUri(value);
  if (text == null) return null;
  final reference = PrivateRecordingPathResolver().parse(text);
  if (reference == null ||
      reference.kind != PrivateRecordingReferenceKind.recordingCard) {
    return null;
  }
  return text;
}

int? _nonNegativeInt(Object? value) {
  if (value is int && value >= 0) return value;
  return null;
}

double? _nonNegativeDouble(Object? value) {
  if (value is num && value.isFinite && value >= 0) return value.toDouble();
  return null;
}

int? _positiveFileSize(Object? value) {
  if (value is int && value > 0 && value <= 1024 * 1024 * 1024) return value;
  return null;
}

bool? _parseTransferCancellation(Object? raw) {
  if (raw is bool) return raw;
  final object = _asStringMap(raw);
  return object?['cancelled'] == true ? true : null;
}

bool? _parseStrictTrue(Object? raw) => raw == true ? true : null;

bool? _parseStrictBool(Object? raw) => raw is bool ? raw : null;

Map<String, Object?> _wifiFilesArgument(List<RecordingCardScannedFile> files) {
  return <String, Object?>{
    'files': files.map((file) => file.toChannelMap()).toList(growable: false),
  };
}

int? _boundedInt(Object? value, {required int min, required int max}) {
  if (value is int && value >= min && value <= max) return value;
  return null;
}

DateTime? _date(Object? value) {
  final text = _string(value);
  return text == null ? null : DateTime.tryParse(text);
}

DateTime? _recordedAtFromDeviceFilename(String value) {
  final match = RegExp(
    r'^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})',
  ).firstMatch(value);
  if (match == null) return null;
  final year = int.tryParse(match.group(1)!);
  final month = int.tryParse(match.group(2)!);
  final day = int.tryParse(match.group(3)!);
  final hour = int.tryParse(match.group(4)!);
  final minute = int.tryParse(match.group(5)!);
  final second = int.tryParse(match.group(6)!);
  if (year == null ||
      month == null ||
      day == null ||
      hour == null ||
      minute == null ||
      second == null) {
    return null;
  }
  if (year < 1) return null;
  final date = DateTime(year, month, day, hour, minute, second);
  if (date.year != year ||
      date.month != month ||
      date.day != day ||
      date.hour != hour ||
      date.minute != minute ||
      date.second != second) {
    return null;
  }
  return date.toUtc();
}

bool _unsafeRecordingCardText(String value) {
  return _unsafeRecordingCardPatterns.any((pattern) => pattern.hasMatch(value));
}

final List<RegExp> _unsafeRecordingCardPatterns = <RegExp>[
  RegExp(r'([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}'),
  RegExp(r'^[A-Za-z]:[\\/]'),
  RegExp(
    r'(?:^|[\\/])(?:Users|home|workspace)(?:[\\/]|$)',
    caseSensitive: false,
  ),
  RegExp(r'file://', caseSensitive: false),
  RegExp(r'https?://', caseSensitive: false),
  RegExp(r'binding.*identity', caseSensitive: false),
  RegExp(r'wifi.*password', caseSensitive: false),
  RegExp(
    r'\b(?:token|secret|provider|runtime|OpenClaw|serial)\b',
    caseSensitive: false,
  ),
  RegExp(
    r'GATT_ERROR|CRC_FAIL|SOCKET_ECONNRESET|Native Module Error|HTTP\s*500|data_lenght|0x0B|E5E4',
    caseSensitive: false,
  ),
];

void _noop() {}
