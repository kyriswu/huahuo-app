import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../../../core/api/api_envelope.dart';
import '../../../core/device/device_identity_store.dart';
import '../../../core/native/platform_permissions_port.dart';
import '../../../core/native/recording_card_native_port.dart';
import '../../../core/storage/file_storage_port.dart';
import '../../../core/storage/private_recording_path_resolver.dart';
import '../../recordings/data/local_recording_repository.dart';
import '../../recordings/domain/recording_library.dart';
import '../data/recording_card_sync_ledger_store.dart';
import '../domain/recording_card_account_binding.dart';
import '../domain/recording_card_connection_history.dart';
import '../domain/recording_card_file_sync.dart';
import '../domain/recording_card_sync_ledger.dart';
import '../domain/recording_card_wifi_batch.dart';
import 'recording_card_operation_machine.dart';
import 'recording_card_permission_coordinator.dart';

export '../domain/recording_card_wifi_batch.dart';
export '../domain/recording_card_file_sync.dart';
export 'recording_card_operation_machine.dart';

part 'recording_card_wifi_recovery.dart';

const recordingCardWifiBluetoothHandoffFailureCode =
    'RECORDING_CARD_WIFI_HANDOFF_TO_BLUETOOTH';
const recordingCardWifiBluetoothResumeFailureCode =
    'RECORDING_CARD_WIFI_BLUETOOTH_RESUME_FAILED';

typedef _RecordingCardWifiNativeTeardownKey = ({
  String batchId,
  String? attemptId,
});

enum _RecordingCardWifiNativeTeardownMode { close, cancel }

const _recordingCardWifiSettledTeardownRetention = 8;

bool recordingCardWifiBatchIsBluetoothHandoff(
  RecordingCardWifiBatchSnapshot? batch,
) =>
    batch != null &&
    batch.state == RecordingCardWifiBatchState.cancelled &&
    !batch.stopRequested &&
    batch.failureCode == recordingCardWifiBluetoothHandoffFailureCode;

bool recordingCardWifiBatchIsBluetoothResumeFailure(
  RecordingCardWifiBatchSnapshot? batch,
) =>
    batch != null &&
    batch.state == RecordingCardWifiBatchState.paused &&
    !batch.stopRequested &&
    batch.failureCode == recordingCardWifiBluetoothResumeFailureCode;

bool _recordingCardWifiBatchOwnsBluetoothResume(
  RecordingCardWifiBatchSnapshot? batch,
) =>
    recordingCardWifiBatchIsBluetoothHandoff(batch) ||
    recordingCardWifiBatchIsBluetoothResumeFailure(batch);

enum RecordingCardControllerStatus {
  idle,
  connecting,
  authorizing,
  refreshing,
  scanning,
  syncing,
  downloading,
  deleting,
  commanding,
  disconnecting,
  unbinding,
  preparingWifi,
  cancellingTransfer,
  error,
}

abstract interface class RecordingCardConnectionAuthorizationPort {
  Future<RecordingCardResult<bool>> authorizeConnection(
    RecordingCardDeviceState device,
  );
}

abstract interface class RecordingCardDiscoveryAuthorizationPort {
  Future<RecordingCardResult<bool>> matchesCachedSerial(String serialNumber);

  Future<RecordingCardResult<bool>> authorizeDiscoveredDevice({
    required String serialNumber,
    required String displayName,
  });
}

enum RecordingCardFileRefreshReason {
  connection,
  appResumed,
  recordingCompleted,
  transferCompleted,
  deviceDeleted,
  manual,
}

final class RecordingCardBluetoothBatchResult {
  const RecordingCardBluetoothBatchResult({
    required this.requestedFiles,
    required this.completedFiles,
    required this.remainingFiles,
    required this.failureCodes,
    this.interruptionCode,
  });

  final List<RecordingCardScannedFile> requestedFiles;
  final List<RecordingCardScannedFile> completedFiles;
  final List<RecordingCardScannedFile> remainingFiles;
  final Map<String, String> failureCodes;
  final String? interruptionCode;

  int get requestedCount => requestedFiles.length;
  int get completedCount => completedFiles.length;
  int get remainingCount => remainingFiles.length;
  bool get isComplete => remainingFiles.isEmpty;
}

final class RecordingCardControllerState {
  const RecordingCardControllerState({
    required this.status,
    required this.snapshot,
    required this.fileCatalog,
    required this.operation,
    this.activeFileKey,
    this.lastErrorCode,
    this.lastDownloadedFile,
    this.wifiBatch,
  });

  factory RecordingCardControllerState.initial(
    RecordingCardRuntimeSnapshot snapshot,
  ) {
    return RecordingCardControllerState(
      status: RecordingCardControllerStatus.idle,
      snapshot: snapshot,
      fileCatalog: const RecordingCardFileCatalogState.disconnected(),
      operation: const RecordingCardOperationState.idle(),
    );
  }

  final RecordingCardControllerStatus status;
  final RecordingCardRuntimeSnapshot snapshot;
  final RecordingCardFileCatalogState fileCatalog;
  final RecordingCardOperationState operation;
  final String? activeFileKey;
  final String? lastErrorCode;
  final RecordingCardDownloadedFile? lastDownloadedFile;
  final RecordingCardWifiBatchSnapshot? wifiBatch;

  bool get hasActiveTransfer =>
      (wifiBatch != null && !wifiBatch!.isTerminal) ||
      status == RecordingCardControllerStatus.syncing ||
      status == RecordingCardControllerStatus.downloading ||
      status == RecordingCardControllerStatus.deleting ||
      status == RecordingCardControllerStatus.cancellingTransfer;

  bool get hasRunningTransfer =>
      (wifiBatch?.isActive ?? false) ||
      status == RecordingCardControllerStatus.syncing ||
      status == RecordingCardControllerStatus.downloading ||
      status == RecordingCardControllerStatus.deleting ||
      status == RecordingCardControllerStatus.cancellingTransfer;

  RecordingCardControllerState copyWith({
    RecordingCardControllerStatus? status,
    RecordingCardRuntimeSnapshot? snapshot,
    RecordingCardFileCatalogState? fileCatalog,
    RecordingCardOperationState? operation,
    String? activeFileKey,
    String? lastErrorCode,
    RecordingCardDownloadedFile? lastDownloadedFile,
    RecordingCardWifiBatchSnapshot? wifiBatch,
    bool clearActiveFileKey = false,
    bool clearLastDownloadedFile = false,
    bool clearWifiBatch = false,
  }) {
    return RecordingCardControllerState(
      status: status ?? this.status,
      snapshot: snapshot ?? this.snapshot,
      fileCatalog: fileCatalog ?? this.fileCatalog,
      operation: operation ?? this.operation,
      activeFileKey: clearActiveFileKey
          ? null
          : activeFileKey ?? this.activeFileKey,
      lastErrorCode: lastErrorCode,
      lastDownloadedFile: clearLastDownloadedFile
          ? null
          : lastDownloadedFile ?? this.lastDownloadedFile,
      wifiBatch: clearWifiBatch ? null : wifiBatch ?? this.wifiBatch,
    );
  }
}

final class _RecordingCardTransferOwner {
  const _RecordingCardTransferOwner({
    required this.connectionRevision,
    required this.deviceIdentity,
    required this.reconnectFingerprint,
    required this.fileSignature,
  });

  final int connectionRevision;
  final String deviceIdentity;
  final String reconnectFingerprint;
  final String fileSignature;
}

final class _RecordingCardBluetoothBatchOwner {
  const _RecordingCardBluetoothBatchOwner({
    required this.connectionRevision,
    required this.deviceIdentity,
    required this.reconnectFingerprint,
    required this.directorySignatures,
    required this.cardSnDigest,
  });

  final int connectionRevision;
  final String deviceIdentity;
  final String reconnectFingerprint;
  final Set<String> directorySignatures;
  final String? cardSnDigest;

  _RecordingCardTransferOwner ownerFor(RecordingCardScannedFile file) {
    return _RecordingCardTransferOwner(
      connectionRevision: connectionRevision,
      deviceIdentity: deviceIdentity,
      reconnectFingerprint: reconnectFingerprint,
      fileSignature: _recordingCardFileSignature(file),
    );
  }
}

final class _RecordingCardManualSyncTarget {
  const _RecordingCardManualSyncTarget({
    required this.file,
    required this.sourceSignature,
  });

  final RecordingCardScannedFile file;
  final String sourceSignature;
}

final class _RecordingCardWifiLedgerTransition {
  const _RecordingCardWifiLedgerTransition({
    required this.item,
    this.ledgerEntry,
    this.failure,
  });

  final RecordingCardWifiBatchItem item;
  final RecordingCardFileLedgerEntry? ledgerEntry;
  final AppFailure? failure;
}

final class RecordingCardController extends ChangeNotifier {
  static const _wifiInterFileCooldown = Duration(milliseconds: 500);
  static const _localVerificationTimeout = Duration(minutes: 2);

  RecordingCardController({
    required RecordingCardPort port,
    required LocalRecordingRepository localRecordingRepository,
    required PlatformPermissionsPort platformPermissionsPort,
    RecordingCardSyncLedgerPersistencePort? syncLedgerPersistence,
    DeviceIdentityStore? deviceIdentityStore,
    RecordingCardBindingTokenProvider? bindingTokenProvider,
    RecordingCardConnectionAuthorizationPort? connectionAuthorization,
    RecordingCardConnectionHistoryPort? connectionHistory,
    bool Function()? requiresBluetoothPermissionRequest,
    bool Function()? requiresWifiPermissionRequest,
    DateTime Function()? clock,
    List<Duration> recordingCompletionScanDelays = const <Duration>[
      Duration(milliseconds: 350),
      Duration(milliseconds: 900),
      Duration(milliseconds: 1800),
    ],
    Duration wifiBleRecoveryTimeout = const Duration(seconds: 15),
    Duration wifiSetupTimeout = const Duration(minutes: 1),
    Duration wifiTeardownTimeout = const Duration(seconds: 10),
    Duration wifiFileTransferTimeout = const Duration(minutes: 31),
  }) : _port = port,
       _localRecordingRepository = localRecordingRepository,
       _syncLedgerPersistence = syncLedgerPersistence,
       _permissionCoordinator = RecordingCardPermissionCoordinator(
         platformPermissionsPort: platformPermissionsPort,
         requiresBluetoothPermissionRequest:
             requiresBluetoothPermissionRequest ?? _isAndroidRuntime,
         requiresLocalNetworkPermissionRequest:
             requiresWifiPermissionRequest ?? _isAndroidRuntime,
       ),
       _bindingTokenProvider =
           bindingTokenProvider ??
           (deviceIdentityStore == null
               ? _unavailableBindingToken
               : () => recordingCardBindingTokenFor(
                   deviceIdentityStore.resolve(),
                 )),
       _connectionAuthorization = connectionAuthorization,
       _connectionHistory =
           connectionHistory ?? InMemoryRecordingCardConnectionHistory(),
       _clock = clock ?? DateTime.now,
       _recordingCompletionScanDelays = List<Duration>.unmodifiable(
         recordingCompletionScanDelays,
       ),
       _wifiBleRecoveryTimeout = wifiBleRecoveryTimeout,
       _wifiSetupTimeout = wifiSetupTimeout,
       _wifiTeardownTimeout = wifiTeardownTimeout,
       _wifiFileTransferTimeout = wifiFileTransferTimeout {
    if (wifiBleRecoveryTimeout.inMilliseconds <= 0 ||
        wifiSetupTimeout.inMilliseconds <= 0 ||
        wifiTeardownTimeout.inMilliseconds <= 0 ||
        wifiFileTransferTimeout.inMilliseconds <= 0) {
      throw ArgumentError('Wi-Fi operation timeouts must be positive');
    }
    final nativeInitial = _sanitizeDisconnectedDeviceDirectory(
      port.runtimeSnapshot,
    );
    final requiresInitialAuthorization =
        connectionAuthorization != null &&
        nativeInitial.deviceState.isOperationallyConnected;
    if (requiresInitialAuthorization) {
      _connectionAuthorizationGeneration = 1;
      _provisionalConnectedDevice = nativeInitial.deviceState;
    } else {
      _connectionAuthorizationSatisfied = connectionAuthorization == null;
    }
    final initial = requiresInitialAuthorization
        ? _provisionalRuntimeSnapshot(nativeInitial)
        : nativeInitial;
    _recordingAnchor = initial.recordingInfo;
    _recordingObservation = initial.recordingObservation;
    _recordingRevision = initial.recordingObservation?.revision ?? -1;
    _state = RecordingCardControllerState.initial(initial);
    if (requiresInitialAuthorization) {
      _state = _state.copyWith(
        status: RecordingCardControllerStatus.authorizing,
      );
    }
    _recentlyConnectedDevices = _loadRecentConnectionHistory();
    if (initial.deviceState.isOperationallyConnected) {
      _connectionRevision = 1;
      _connectionFingerprint = initial.deviceState.safeDeviceFingerprint;
      _connectionDeviceIdentity = _recordingCardDeviceIdentity(
        initial.deviceState,
      );
      _rememberConnectedDevice(initial.deviceState);
      _state = _state.copyWith(
        snapshot: initial.copyWith(files: const <RecordingCardScannedFile>[]),
        fileCatalog: RecordingCardFileCatalogState(
          phase: RecordingCardFileCatalogPhase.reading,
          connectionRevision: _connectionRevision,
          deviceIdentity: _recordingCardDeviceIdentity(initial.deviceState),
        ),
      );
    }
    _wifiBatchCoordinator = RecordingCardWifiBatchCoordinator(
      onChanged: (batch) {
        _state = _state.copyWith(
          wifiBatch: batch,
          clearWifiBatch: batch == null,
        );
        notifyListeners();
      },
    );
    final restoringWifiBatch = restoreWifiBatch();
    final recoveryPort = _port;
    if (recoveryPort is RecordingCardWifiRecoveryPort) {
      _wifiRecoverySubscription =
          (recoveryPort as RecordingCardWifiRecoveryPort).subscribeWifiSession(
            _onWifiSessionObservation,
          );
    }
    _snapshotSubscription = _port.subscribeRuntimeSnapshot((snapshot) {
      if (_connectionReconcileInFlight != null &&
          _state.status != RecordingCardControllerStatus.authorizing) {
        _connectionReconcileGeneration += 1;
      }
      final previousDevice = _state.snapshot.deviceState;
      final previousRecordingState = _state.snapshot.recordingInfo.state;
      final normalized = _normalizeRuntimeSnapshot(snapshot);
      final requiresAuthorization = _requiresConnectionAuthorization(
        normalized.deviceState,
      );
      final operationOwnsAuthorization =
          _state.status == RecordingCardControllerStatus.connecting ||
          _state.status == RecordingCardControllerStatus.preparingWifi ||
          _state.status == RecordingCardControllerStatus.authorizing ||
          _wifiBleRecoveryInFlight;
      if (requiresAuthorization) {
        _stageProvisionalConnection(normalized.deviceState);
      } else if (!normalized.deviceState.isOperationallyConnected) {
        _resetConnectionAuthorization();
      }
      final authorizedProjection = requiresAuthorization
          ? _provisionalRuntimeSnapshot(normalized)
          : normalized;
      final projected = _preserveDirectoryUntilVerified(authorizedProjection);
      _state = _state.copyWith(
        status: requiresAuthorization && !operationOwnsAuthorization
            ? RecordingCardControllerStatus.authorizing
            : _state.status,
        snapshot: projected,
      );
      final wifiBatchPublished = _applyWifiBatchProgress(
        projected.transferProgress,
      );
      if (!wifiBatchPublished) notifyListeners();
      if (!requiresAuthorization) {
        _observeConnectionTransition(previousDevice, normalized.deviceState);
      }
      _observeRecordingTransition(
        previousRecordingState,
        normalized.recordingInfo.state,
      );
      if (requiresAuthorization && !operationOwnsAuthorization) {
        unawaited(
          _authorizeObservedConnection(
            normalized.deviceState,
            _connectionAuthorizationGeneration,
          ),
        );
      }
    });
    if (requiresInitialAuthorization) {
      scheduleMicrotask(
        () => _authorizeObservedConnection(
          nativeInitial.deviceState,
          _connectionAuthorizationGeneration,
        ),
      );
    }
    if (!requiresInitialAuthorization &&
        initial.deviceState.isOperationallyConnected) {
      unawaited(
        restoringWifiBatch.then((_) {
          if (!_disposed) return ensureFilesLoadedForCurrentConnection();
        }),
      );
    }
  }

  final RecordingCardPort _port;
  final LocalRecordingRepository _localRecordingRepository;
  final RecordingCardSyncLedgerPersistencePort? _syncLedgerPersistence;
  final RecordingCardPermissionCoordinator _permissionCoordinator;
  final RecordingCardBindingTokenProvider _bindingTokenProvider;
  final RecordingCardConnectionAuthorizationPort? _connectionAuthorization;
  final RecordingCardConnectionHistoryPort _connectionHistory;
  final DateTime Function() _clock;
  final List<Duration> _recordingCompletionScanDelays;
  final Duration _wifiBleRecoveryTimeout;
  final Duration _wifiSetupTimeout;
  final Duration _wifiTeardownTimeout;
  final Duration _wifiFileTransferTimeout;
  final RecordingCardOperationMachine _operationMachine =
      RecordingCardOperationMachine();
  late RecordingCardControllerState _state;
  late final RecordingCardSnapshotSubscription _snapshotSubscription;
  Future<void>? _directTransferCancellationInFlight;
  RecordingCardOperationLease? _observedTransferCancellationLease;
  Set<String> _activeManualBluetoothLedgerSignatures = const <String>{};
  Future<void>? _deviceInfoRefreshInFlight;
  Future<void>? _scanFilesInFlight;
  Future<void>? _connectionReconcileInFlight;
  bool _connectionReconcileDirectoryRequested = false;
  int _connectionReconcileGeneration = 0;
  Map<String, VerifiedRecordingCardDownload> _verifiedDownloadsByIdentity =
      const <String, VerifiedRecordingCardDownload>{};
  int _verifiedDownloadRefreshGeneration = 0;
  int _localRecordingRegistrationRevision = 0;
  late RecordingCardRecordingInfo _recordingAnchor;
  RecordingCardRecordingObservation? _recordingObservation;
  var _recordingRevision = -1;
  late final RecordingCardWifiBatchCoordinator _wifiBatchCoordinator;
  bool _transferInFlight = false;
  int _transferLatchGeneration = 0;
  RecordingCardOperationLease? _activeTransferOperationLease;
  RecordingCardOperationLease? _activeControllerOperationLease;
  RecordingCardOperationLease? _fileRefreshOperationLease;
  int _deferredConnectionFileRefreshRevision = -1;
  bool _scanFilesRequested = false;
  final Set<RecordingCardFileRefreshReason> _pendingFileRefreshReasons =
      <RecordingCardFileRefreshReason>{};
  final Set<RecordingCardFileRefreshReason> _activeFileRefreshReasons =
      <RecordingCardFileRefreshReason>{};
  int _connectionRevision = 0;
  int _recordingStateRevision = 0;
  int _loadedFileDirectoryConnectionRevision = -1;
  int _successfulFileRefreshRevision = 0;
  int _autoScanAttemptedConnectionRevision = -1;
  int _connectionScanRevisionInFlight = -1;
  int _activeFileScanConnectionRevision = -1;
  String? _connectionFingerprint;
  String? _connectionDeviceIdentity;
  Future<void>? _deviceDiscoveryInFlight;
  Future<void>? _deviceDiscoveryCancellationInFlight;
  Completer<void>? _deviceDiscoveryAdmissionWaiter;
  int _deviceDiscoveryRequestGeneration = 0;
  Future<void>? _recordingCompletionRefreshInFlight;
  bool _recordingCompletionRefreshRequested = false;
  Set<String>? _recordingCompletionKnownFiles;
  bool _appResumeFileRefreshRequested = false;
  Timer? _recordingCompletionTimer;
  Timer? _deferredFileRefreshTimer;
  Completer<void>? _recordingCompletionDelayCompleter;
  bool _disposed = false;
  bool _connectionAuthorizationSatisfied = false;
  int _connectionAuthorizationGeneration = 0;
  RecordingCardDeviceState? _provisionalConnectedDevice;
  String? _authorizedConnectionFingerprint;
  Future<RecordingCardResult<bool>>? _connectionAuthorizationInFlight;
  int? _connectionAuthorizationInFlightGeneration;
  bool _wifiBleRecoveryInFlight = false;
  bool _wifiHandoffBleUnavailable = false;
  int _wifiBleRecoveryGeneration = 0;
  bool _batchCancelRequested = false;
  bool _batchPauseRequested = false;
  Future<void>? _batchRunInFlight;
  RecordingCardSnapshotSubscription? _wifiRecoverySubscription;
  Future<RecordingCardResult<RecordingCardWifiBatchSnapshot>>?
  _wifiFlowInFlight;
  Future<void>? _wifiReconciliationInFlight;
  int _wifiFlowGeneration = 0;
  Completer<void>? _wifiFlowAbort;

  Future<void>? _wifiBatchPauseInFlight;
  Future<void>? _wifiBatchCancelInFlight;
  Future<void>? _wifiBatchRestoreInFlight;
  Future<RecordingCardResult<RecordingCardBluetoothBatchResult>>?
  _pendingBluetoothResumeInFlight;
  bool _pendingBluetoothResumeScheduled = false;
  int _lastAutomaticBluetoothResumeConnectionRevision = -1;
  String? _pendingBluetoothRecoveryAttemptKey;
  int _pendingBluetoothResumeGeneration = 0;
  RecordingCardOperationLease? _pendingBluetoothResumeOperationLease;
  int? _pendingBluetoothResumeLatchGeneration;
  bool _pendingBluetoothResumePreflight = false;
  int? _pendingBluetoothResumeFileRefreshGeneration;
  Future<AppFailure?>? _stagedBatchRegistrationInFlight;
  Completer<RecordingCardResult<RecordingCardDownloadedFile>>?
  _wifiBatchDownloadInterrupt;
  Future<RecordingCardResult<RecordingCardWifiCredentials>>?
  _wifiBatchReprepareInFlight;
  Future<bool>? _wifiBatchDismissInFlight;
  int _wifiBatchStateGeneration = 0;
  int _wifiPreparationGeneration = 0;
  String? _wifiBatchReconnectFingerprint;
  String? _wifiBatchPersistenceFailureBatchId;
  String? _wifiBatchLedgerFailureBatchId;
  _RecordingCardWifiNativeTeardownKey? _wifiNativeTeardownPendingKey;
  Future<AppFailure?>? _wifiNativeTeardownInFlight;
  _RecordingCardWifiNativeTeardownKey? _wifiNativeTeardownInFlightKey;
  final Set<_RecordingCardWifiNativeTeardownKey>
  _wifiNativeTeardownSettledKeys = <_RecordingCardWifiNativeTeardownKey>{};
  late List<RecordingCardConnectionHistoryEntry> _recentlyConnectedDevices;
  int _deviceDiscoveryOperation = 0;

  RecordingCardControllerState get state => _state;

  bool get hasActiveDeviceOperation => _operationMachine.state.isActive;

  String? get operationBlockCode => _operationMachine.state.blockCode;

  bool get _hasActiveOrPendingDeviceDiscovery =>
      _deviceDiscoveryInFlight != null ||
      (_operationMachine.state.isActive &&
          _operationMachine.state.kind == RecordingCardOperationKind.discovery);

  bool get hasActiveTransfer =>
      _transferInFlight || _wifiBleRecoveryInFlight || _state.hasActiveTransfer;

  bool get hasUnresolvedWifiBatch {
    final batch = _wifiBatchCoordinator.snapshot;
    return batch != null &&
        batch.state != RecordingCardWifiBatchState.completed;
  }

  String? get _wifiBatchTeardownPendingBatchId =>
      _wifiNativeTeardownPendingKey?.batchId;

  bool get hasAutomaticSyncBlockingWifiBatch {
    final batch = _wifiBatchCoordinator.snapshot;
    return batch != null &&
        (batch.operationPhase != RecordingCardWifiOperationPhase.idle ||
            (batch.state != RecordingCardWifiBatchState.completed &&
                batch.state != RecordingCardWifiBatchState.cancelled));
  }

  List<RecordingCardFileLedgerEntry> get pendingBluetoothSyncEntries {
    final persistence = _syncLedgerPersistence;
    if (persistence == null) return const <RecordingCardFileLedgerEntry>[];
    try {
      final entries = <RecordingCardFileLedgerEntry>[];
      for (final digest in persistence.loadKnownCardDigests()) {
        entries.addAll(
          persistence
              .loadFileLedger(digest)
              .where(
                (entry) =>
                    entry.localState == RecordingCardFileLocalState.queued ||
                    entry.localState == RecordingCardFileLocalState.syncing,
              ),
        );
      }
      entries.sort((left, right) => left.updatedAt.compareTo(right.updatedAt));
      return List<RecordingCardFileLedgerEntry>.unmodifiable(entries);
    } on Object {
      return const <RecordingCardFileLedgerEntry>[];
    }
  }

  List<RecordingCardFileLedgerEntry> get pendingBluetoothResumeEntries =>
      List<RecordingCardFileLedgerEntry>.unmodifiable(
        pendingBluetoothSyncEntries.where((entry) => entry.resumeRequested),
      );

  List<RecordingCardFileLedgerEntry> get pendingUserBluetoothResumeEntries =>
      List<RecordingCardFileLedgerEntry>.unmodifiable(
        pendingBluetoothResumeEntries.where(
          (entry) => entry.syncOrigin == RecordingCardSyncOrigin.user,
        ),
      );

  List<RecordingCardFileLedgerEntry> get _resumableUserBluetoothEntries =>
      List<RecordingCardFileLedgerEntry>.unmodifiable(
        pendingUserBluetoothResumeEntries.where(
          (entry) => !_stoppedWifiBatchOwnsBluetoothEntry(entry),
        ),
      );

  bool _stoppedWifiBatchOwnsBluetoothEntry(RecordingCardFileLedgerEntry entry) {
    final batch = _wifiBatchCoordinator.snapshot;
    if (batch == null ||
        !batch.stopRequested ||
        _wifiBatchCardSnDigest(batch) != entry.cardSnDigest) {
      return false;
    }
    return batch.items.any((item) {
      final signature = item.ledgerSourceSignature?.trim();
      return signature == entry.sourceSignature ||
          (signature == null &&
              item.file.deviceFileId == entry.deviceFileId &&
              item.file.deviceFilename == entry.deviceFilename);
    });
  }

  bool get hasPendingBluetoothSync => pendingBluetoothSyncEntries.isNotEmpty;

  bool get hasPendingBluetoothResume =>
      pendingBluetoothResumeEntries.isNotEmpty;

  Future<void> recoverPersistedTransfers() async {
    await restoreWifiBatch();
    if (_resumableUserBluetoothEntries.isNotEmpty) {
      await resumePendingBluetoothTransfers();
    }
  }

  Future<RecordingCardResult<RecordingCardBluetoothBatchResult>>
  resumePendingBluetoothTransfers() => _startPendingBluetoothResume(
    preclaimedLatchGeneration: _pendingBluetoothResumeLatchGeneration,
  );

  Future<RecordingCardResult<RecordingCardBluetoothBatchResult>>
  _startPendingBluetoothResume({int? preclaimedLatchGeneration}) {
    final running = _pendingBluetoothResumeInFlight;
    if (running != null) return running;
    late final Future<RecordingCardResult<RecordingCardBluetoothBatchResult>>
    operation;
    operation =
        _resumePendingBluetoothTransfers(
          preclaimedLatchGeneration: preclaimedLatchGeneration,
        ).whenComplete(() {
          if (identical(_pendingBluetoothResumeInFlight, operation)) {
            _pendingBluetoothResumeInFlight = null;
            _pendingBluetoothRecoveryAttemptKey = null;
          }
        });
    _pendingBluetoothResumeInFlight = operation;
    return operation;
  }

  Future<RecordingCardResult<RecordingCardBluetoothBatchResult>>
  _resumePendingBluetoothTransfers({int? preclaimedLatchGeneration}) async {
    final pending = _resumableUserBluetoothEntries;
    if (pending.isEmpty) {
      if (preclaimedLatchGeneration != null) {
        _releaseTransferLatch(preclaimedLatchGeneration);
      }
      return RecordingCardResult<RecordingCardBluetoothBatchResult>.success(
        const RecordingCardBluetoothBatchResult(
          requestedFiles: <RecordingCardScannedFile>[],
          completedFiles: <RecordingCardScannedFile>[],
          remainingFiles: <RecordingCardScannedFile>[],
          failureCodes: <String, String>{},
        ),
      );
    }

    final handoffBatch = _wifiBluetoothHandoffBatchFor(pending);
    final attemptKey =
        _pendingBluetoothRecoveryAttemptKey ??
        (handoffBatch == null
            ? 'bluetooth-resume:${pending.first.cardSnDigest}:${pending.first.sourceSignature}'
            : 'wifi-handoff:${handoffBatch.batchId}');
    _pendingBluetoothRecoveryAttemptKey = attemptKey;
    late final int latchGeneration;
    late RecordingCardOperationLease operationLease;
    if (preclaimedLatchGeneration case final preclaimed?) {
      final activeLease = _activeTransferOperationLease;
      if (!_transferInFlight ||
          preclaimed != _transferLatchGeneration ||
          activeLease == null ||
          !_operationMachine.owns(activeLease)) {
        _releaseTransferLatch(preclaimed);
        return RecordingCardResult<RecordingCardBluetoothBatchResult>.failure(
          _fallbackFailure('RECORDING_CARD_BLUETOOTH_RESUME_SUPERSEDED'),
        );
      }
      latchGeneration = preclaimed;
      if (activeLease.kind == RecordingCardOperationKind.bluetoothTransfer &&
          activeLease.connectionRevision == _connectionRevision) {
        operationLease = activeLease;
      } else {
        final admission = _operationMachine.supersede(
          kind: RecordingCardOperationKind.bluetoothTransfer,
          origin: RecordingCardOperationOrigin.automatic,
          connectionRevision: _connectionRevision,
        );
        final rebasedLease = admission.lease;
        if (rebasedLease == null) {
          _releaseTransferLatch(preclaimed);
          return RecordingCardResult<RecordingCardBluetoothBatchResult>.failure(
            _fallbackFailure(recordingCardOperationDeferredCode),
          );
        }
        operationLease = rebasedLease;
        _activeTransferOperationLease = operationLease;
        _state = _state.copyWith(operation: admission.state);
      }
    } else {
      if (!_beginTransfer(
        kind: RecordingCardOperationKind.bluetoothTransfer,
        origin: RecordingCardOperationOrigin.automatic,
      )) {
        return RecordingCardResult<RecordingCardBluetoothBatchResult>.failure(
          _operationAdmissionFailure(
            fallbackCode: recordingCardOperationDeferredCode,
          ),
        );
      }
      latchGeneration = _transferLatchGeneration;
      operationLease = _activeTransferOperationLease!;
    }
    final resumeGeneration = ++_pendingBluetoothResumeGeneration;
    final deviceOperation = ++_deviceDiscoveryOperation;
    _pendingBluetoothResumeOperationLease = operationLease;
    _pendingBluetoothResumeLatchGeneration = latchGeneration;
    _pendingBluetoothResumePreflight = true;
    _state = _state.copyWith(operation: _operationMachine.state);
    notifyListeners();
    final result = await _resumePendingBluetoothTransfersOwned(
      initialPending: pending,
      initialHandoffBatch: handoffBatch,
      resumeGeneration: resumeGeneration,
      attemptKey: attemptKey,
      deviceOperation: deviceOperation,
      operationLease: operationLease,
      latchGeneration: latchGeneration,
    );
    if (handoffBatch != null) {
      final batchResult = result.value;
      final hasIncompleteResult =
          batchResult != null &&
          (batchResult.remainingFiles.isNotEmpty ||
              batchResult.failureCodes.isNotEmpty);
      final failureCode =
          result.error?.code ??
          batchResult?.failureCodes.values.firstOrNull ??
          batchResult?.interruptionCode;
      if ((!result.ok || hasIncompleteResult) &&
          failureCode != null &&
          !_isBluetoothResumeSupersessionCode(failureCode)) {
        final projectionFailure = await _projectBluetoothHandoffFailure(
          handoffBatch,
          result: batchResult,
          failureCode: failureCode,
        );
        if (projectionFailure != null) {
          return RecordingCardResult<RecordingCardBluetoothBatchResult>.failure(
            projectionFailure,
          );
        }
      }
    }
    return result;
  }

  Future<RecordingCardResult<RecordingCardBluetoothBatchResult>>
  _resumePendingBluetoothTransfersOwned({
    required List<RecordingCardFileLedgerEntry> initialPending,
    required RecordingCardWifiBatchSnapshot? initialHandoffBatch,
    required int resumeGeneration,
    required String attemptKey,
    required int deviceOperation,
    required RecordingCardOperationLease operationLease,
    required int latchGeneration,
  }) async {
    var pending = initialPending;
    var handoffBatch = initialHandoffBatch;
    var activeLease = operationLease;
    var downloadOwnsLatch = false;
    bool ownsResume() => _ownsPendingBluetoothResume(
      resumeGeneration: resumeGeneration,
      attemptKey: attemptKey,
      deviceOperation: deviceOperation,
      operationLease: activeLease,
      latchGeneration: latchGeneration,
    );
    RecordingCardResult<RecordingCardBluetoothBatchResult> superseded() {
      return RecordingCardResult<RecordingCardBluetoothBatchResult>.failure(
        _fallbackFailure('RECORDING_CARD_BLUETOOTH_RESUME_SUPERSEDED'),
      );
    }

    try {
      final localRecovery = await _recoverCommittedBluetoothEntries(
        pending,
        ownsRecovery: ownsResume,
      );
      if (!ownsResume()) return superseded();
      if (localRecovery.failure case final failure?) {
        return _pendingBluetoothResumeFailure(failure.code, failure: failure);
      }
      final locallyRecovered = localRecovery.completedFiles;
      pending = localRecovery.remainingEntries;
      if (pending.isEmpty) {
        if (_state.snapshot.deviceState.isOperationallyConnected) {
          _lastAutomaticBluetoothResumeConnectionRevision = _connectionRevision;
        }
        return RecordingCardResult<RecordingCardBluetoothBatchResult>.success(
          RecordingCardBluetoothBatchResult(
            requestedFiles: List<RecordingCardScannedFile>.unmodifiable(
              locallyRecovered,
            ),
            completedFiles: List<RecordingCardScannedFile>.unmodifiable(
              locallyRecovered,
            ),
            remainingFiles: const <RecordingCardScannedFile>[],
            failureCodes: const <String, String>{},
          ),
        );
      }

      handoffBatch = _wifiBluetoothHandoffBatchFor(pending) ?? handoffBatch;
      var device = _state.snapshot.deviceState;
      if (!device.isOperationallyConnected) {
        if (handoffBatch == null) {
          return _pendingBluetoothResumeFailure(
            'RECORDING_CARD_BLUETOOTH_RESUME_DEVICE_UNAVAILABLE',
          );
        }
        final connected = await _ensureWifiBatchBleConnection(
          handoffBatch,
          ownsRecovery: ownsResume,
        );
        if (!ownsResume()) return superseded();
        if (!connected.ok || connected.value == null) {
          return _pendingBluetoothResumeFailure(
            connected.error?.code ?? 'RECORDING_CARD_WIFI_BLE_RECONNECT_FAILED',
            failure: connected.error,
          );
        }
        final admission = _operationMachine.supersede(
          kind: RecordingCardOperationKind.bluetoothTransfer,
          origin: RecordingCardOperationOrigin.automatic,
          connectionRevision: _connectionRevision,
        );
        final rebasedLease = admission.lease;
        if (rebasedLease == null) return superseded();
        activeLease = rebasedLease;
        _activeTransferOperationLease = rebasedLease;
        _pendingBluetoothResumeOperationLease = rebasedLease;
        _state = _state.copyWith(
          status: RecordingCardControllerStatus.idle,
          operation: admission.state,
          lastErrorCode: null,
          clearActiveFileKey: true,
        );
        notifyListeners();
        if (!ownsResume()) return superseded();
        device = connected.value!;
      }

      if (handoffBatch != null &&
          (!_matchesWifiBatchReconnectTarget(device, handoffBatch) ||
              !_matchesWifiBatchReconnectTarget(
                _port.runtimeSnapshot.deviceState,
                handoffBatch,
              ))) {
        return _pendingBluetoothResumeFailure(
          'RECORDING_CARD_WIFI_BATCH_DEVICE_MISMATCH',
        );
      }

      if (!hasLoadedFilesForCurrentConnection) {
        _pendingBluetoothResumeFileRefreshGeneration = resumeGeneration;
        try {
          await _refreshFiles(
            reason: RecordingCardFileRefreshReason.appResumed,
            pendingBluetoothResumeGeneration: resumeGeneration,
          );
        } finally {
          if (_pendingBluetoothResumeFileRefreshGeneration ==
              resumeGeneration) {
            _pendingBluetoothResumeFileRefreshGeneration = null;
          }
        }
      }
      if (!ownsResume()) return superseded();
      device = _state.snapshot.deviceState;
      if (!device.isOperationallyConnected ||
          !hasLoadedFilesForCurrentConnection) {
        return _pendingBluetoothResumeFailure(
          _state.fileCatalog.errorCode ??
              'RECORDING_CARD_BLUETOOTH_RESUME_DIRECTORY_UNAVAILABLE',
        );
      }
      if (handoffBatch != null &&
          (!_matchesWifiBatchReconnectTarget(device, handoffBatch) ||
              !_matchesWifiBatchReconnectTarget(
                _port.runtimeSnapshot.deviceState,
                handoffBatch,
              ))) {
        return _pendingBluetoothResumeFailure(
          'RECORDING_CARD_WIFI_BATCH_DEVICE_MISMATCH',
        );
      }

      final digest = _recordingCardDigestForDevice(device);
      if (digest == null) {
        return _pendingBluetoothResumeFailure(
          'RECORDING_CARD_LEDGER_IDENTITY_UNAVAILABLE',
        );
      }
      pending = _resumableUserBluetoothEntries
          .where((entry) => entry.cardSnDigest == digest)
          .toList(growable: false);
      if (pending.isEmpty) {
        return _pendingBluetoothResumeFailure(
          'RECORDING_CARD_BLUETOOTH_RESUME_DEVICE_MISMATCH',
        );
      }

      final files = <RecordingCardScannedFile>[];
      final seenSignatures = <String>{};
      for (final entry in pending) {
        final exact = _state.snapshot.files
            .where(
              (file) =>
                  RecordingCardFileIdentity.sourceSignatureFor(
                    cardSnDigest: digest,
                    deviceFileId: file.deviceFileId,
                    deviceFilename: file.deviceFilename,
                    sizeBytes: file.sizeBytes,
                    recordedAt: file.recordedAt,
                  ) ==
                  entry.sourceSignature,
            )
            .toList(growable: false);
        var matches = exact;
        if (matches.isEmpty) {
          matches = _state.snapshot.files
              .where(
                (file) =>
                    file.deviceFileId == entry.deviceFileId &&
                    file.deviceFilename == entry.deviceFilename,
              )
              .toList(growable: false);
        }
        if (matches.length != 1) {
          return _pendingBluetoothResumeFailure(
            'RECORDING_CARD_BLUETOOTH_RESUME_DIRECTORY_INCOMPLETE',
          );
        }
        final file = matches.single;
        if (seenSignatures.add(_recordingCardFileSignature(file))) {
          files.add(file);
        }
      }
      if (files.isEmpty) {
        return _pendingBluetoothResumeFailure(
          'RECORDING_CARD_BLUETOOTH_RESUME_DIRECTORY_INCOMPLETE',
        );
      }
      _pendingBluetoothResumePreflight = false;
      downloadOwnsLatch = true;
      final transferred = await _downloadFilesOverBluetooth(
        files,
        preclaimedLatchGeneration: latchGeneration,
        preclaimedOperationLease: activeLease,
        ledgerOrigin: RecordingCardOperationOrigin.user,
      );
      final batchResult = transferred.value;
      if (transferred.ok &&
          batchResult != null &&
          batchResult.remainingFiles.isEmpty &&
          pendingUserBluetoothResumeEntries.isEmpty) {
        _lastAutomaticBluetoothResumeConnectionRevision = _connectionRevision;
      }
      if (!transferred.ok || batchResult == null || locallyRecovered.isEmpty) {
        return transferred;
      }
      return RecordingCardResult<RecordingCardBluetoothBatchResult>.success(
        RecordingCardBluetoothBatchResult(
          requestedFiles: List<RecordingCardScannedFile>.unmodifiable(
            <RecordingCardScannedFile>[
              ...locallyRecovered,
              ...batchResult.requestedFiles,
            ],
          ),
          completedFiles: List<RecordingCardScannedFile>.unmodifiable(
            <RecordingCardScannedFile>[
              ...locallyRecovered,
              ...batchResult.completedFiles,
            ],
          ),
          remainingFiles: batchResult.remainingFiles,
          failureCodes: batchResult.failureCodes,
          interruptionCode: batchResult.interruptionCode,
        ),
      );
    } finally {
      if (resumeGeneration == _pendingBluetoothResumeGeneration &&
          _pendingBluetoothRecoveryAttemptKey == attemptKey) {
        _pendingBluetoothResumePreflight = false;
        _pendingBluetoothResumeFileRefreshGeneration = null;
        _pendingBluetoothResumeOperationLease = null;
        _pendingBluetoothResumeLatchGeneration = null;
        if (!downloadOwnsLatch) _releaseTransferLatch(latchGeneration);
      }
    }
  }

  Future<
    ({
      List<RecordingCardScannedFile> completedFiles,
      List<RecordingCardFileLedgerEntry> remainingEntries,
      AppFailure? failure,
    })
  >
  _recoverCommittedBluetoothEntries(
    List<RecordingCardFileLedgerEntry> entries, {
    bool Function()? ownsRecovery,
  }) async {
    final persistence = _syncLedgerPersistence;
    final port = _port;
    if (persistence == null ||
        port is! RecordingCardRecoverableBluetoothTransferPort) {
      return (
        completedFiles: const <RecordingCardScannedFile>[],
        remainingEntries: entries,
        failure: null,
      );
    }
    final recoverablePort =
        port as RecordingCardRecoverableBluetoothTransferPort;
    final completedFiles = <RecordingCardScannedFile>[];
    final remainingEntries = <RecordingCardFileLedgerEntry>[];
    for (var entryIndex = 0; entryIndex < entries.length; entryIndex += 1) {
      final entry = entries[entryIndex];
      List<RecordingCardFileLedgerEntry> unresolvedTail() =>
          <RecordingCardFileLedgerEntry>[
            ...remainingEntries,
            ...entries.skip(entryIndex),
          ];
      if (ownsRecovery != null && !ownsRecovery()) {
        return (
          completedFiles: completedFiles,
          remainingEntries: unresolvedTail(),
          failure: null,
        );
      }
      final plannedNativeFileId = entry.plannedNativeFileId;
      if (plannedNativeFileId == null) {
        remainingEntries.add(entry);
        continue;
      }
      RecordingCardScannedFile? recoveredSource;
      RecordingCardDownloadedFile? recoveredDownload;
      for (final format in _recordingCardRecoveryFormats(entry)) {
        final source = _recordingCardFileFromLedger(entry, format: format);
        final recovered = await recoverablePort.recoverBluetoothDownload(
          source,
          plannedNativeFileId: plannedNativeFileId,
        );
        if (ownsRecovery != null && !ownsRecovery()) {
          return (
            completedFiles: completedFiles,
            remainingEntries: unresolvedTail(),
            failure: null,
          );
        }
        if (!recovered.ok || recovered.value == null) {
          return (
            completedFiles: completedFiles,
            remainingEntries: unresolvedTail(),
            failure:
                recovered.error ??
                _fallbackFailure('RECORDING_CARD_BLUETOOTH_RECOVERY_FAILED'),
          );
        }
        final committed = recovered.value!.file;
        if (committed == null) continue;
        final validated = _validatePlannedBluetoothDownload(
          RecordingCardResult<RecordingCardDownloadedFile>.success(committed),
          plannedNativeFileId,
        );
        if (!validated.ok || validated.value == null) {
          return (
            completedFiles: completedFiles,
            remainingEntries: unresolvedTail(),
            failure:
                validated.error ??
                _fallbackFailure('RECORDING_CARD_BLUETOOTH_TARGET_MISMATCH'),
          );
        }
        recoveredSource = source;
        recoveredDownload = validated.value;
        break;
      }
      if (recoveredSource == null || recoveredDownload == null) {
        remainingEntries.add(entry);
        continue;
      }
      if (ownsRecovery != null && !ownsRecovery()) {
        return (
          completedFiles: completedFiles,
          remainingEntries: unresolvedTail(),
          failure: null,
        );
      }
      final registered = await _registerBatchDownloadedFile(
        recoveredDownload,
        recoveredSource,
        fallbackDeviceIdentity: entry.cardSnDigest,
        fallbackReconnectFingerprint: entry.cardSnDigest,
      );
      if (ownsRecovery != null && !ownsRecovery()) {
        return (
          completedFiles: completedFiles,
          remainingEntries: unresolvedTail(),
          failure: null,
        );
      }
      if (!registered.ok || registered.value == null) {
        return (
          completedFiles: completedFiles,
          remainingEntries: unresolvedTail(),
          failure:
              registered.error ??
              _fallbackFailure(
                'RECORDING_CARD_LOCAL_LIBRARY_REGISTRATION_FAILED',
              ),
        );
      }
      try {
        final current = persistence.findFileLedgerEntry(
          cardSnDigest: entry.cardSnDigest,
          sourceSignature: entry.sourceSignature,
        );
        if (current == null) {
          return (
            completedFiles: completedFiles,
            remainingEntries: unresolvedTail(),
            failure: _fallbackFailure(
              'RECORDING_CARD_LEDGER_IDENTITY_UNAVAILABLE',
            ),
          );
        }
        persistence.saveFileLedgerEntry(
          current.markSynced(
            at: _clock(),
            localRecordingId: registered.value!.localFileId!,
            contentHash: registered.value!.contentHash,
          ),
        );
        await persistence.flushSyncPersistence();
        if (ownsRecovery != null && !ownsRecovery()) {
          return (
            completedFiles: completedFiles,
            remainingEntries: unresolvedTail(),
            failure: null,
          );
        }
      } on Object catch (error) {
        return (
          completedFiles: completedFiles,
          remainingEntries: unresolvedTail(),
          failure: recordingCardFailure(
            'RECORDING_CARD_LEDGER_COMPLETION_FAILED',
            'Recovered recording-card file could not be committed to the ledger',
            cause: error,
            isRetryable: true,
          ),
        );
      }
      completedFiles.add(recoveredSource);
      if (!_disposed) notifyListeners();
    }
    return (
      completedFiles: List<RecordingCardScannedFile>.unmodifiable(
        completedFiles,
      ),
      remainingEntries: List<RecordingCardFileLedgerEntry>.unmodifiable(
        remainingEntries,
      ),
      failure: null,
    );
  }

  RecordingCardResult<RecordingCardBluetoothBatchResult>
  _pendingBluetoothResumeFailure(String code, {AppFailure? failure}) {
    final resolved = failure ?? _fallbackFailure(code);
    _fail(resolved);
    return RecordingCardResult<RecordingCardBluetoothBatchResult>.failure(
      resolved,
    );
  }

  bool _isBluetoothResumeSupersessionCode(String code) =>
      code == 'RECORDING_CARD_TRANSFER_CANCELLED' ||
      code == 'RECORDING_CARD_BLUETOOTH_RESUME_SUPERSEDED' ||
      code == recordingCardOperationSessionChangedCode;

  Future<AppFailure?> _projectBluetoothHandoffFailure(
    RecordingCardWifiBatchSnapshot owner, {
    required RecordingCardBluetoothBatchResult? result,
    required String failureCode,
  }) async {
    final current = _wifiBatchCoordinator.snapshot;
    if (!_recordingCardWifiBatchOwnsBluetoothResume(current) ||
        current!.batchId != owner.batchId ||
        current.attemptId != owner.attemptId) {
      return null;
    }
    final completedByDeviceId = <String, RecordingCardScannedFile>{
      for (final file
          in result?.completedFiles ?? const <RecordingCardScannedFile>[])
        file.deviceFileId: file,
    };
    final failureCodes = result?.failureCodes ?? const <String, String>{};
    var assignedFallbackFailure = false;
    final pausedItems = current.items
        .map((item) {
          if (item.isCompleted) return item;
          final completed = completedByDeviceId[item.file.deviceFileId];
          if (completed != null) {
            final projected = _state.snapshot.files
                .where((file) => file.deviceFileId == completed.deviceFileId)
                .firstOrNull;
            return item.copyWith(
              file: projected ?? completed,
              state: RecordingCardWifiBatchItemState.completed,
              localRecordingId: projected?.localFileId ?? completed.localFileId,
              clearError: true,
              clearStagedDownload: true,
            );
          }
          final itemFailure = failureCodes[item.file.deviceFileId];
          if (itemFailure != null || !assignedFallbackFailure) {
            assignedFallbackFailure = true;
            return item.copyWith(
              state: RecordingCardWifiBatchItemState.failed,
              errorCode: itemFailure ?? failureCode,
              clearStagedDownload: true,
            );
          }
          return item.copyWith(
            state: RecordingCardWifiBatchItemState.cancelled,
            clearStagedDownload: true,
          );
        })
        .toList(growable: false);
    final paused = current.copyWith(
      state: RecordingCardWifiBatchState.paused,
      operationPhase: RecordingCardWifiOperationPhase.idle,
      items: pausedItems,
      failureCode: recordingCardWifiBluetoothResumeFailureCode,
      updatedAt: _clock(),
      clearCurrentItem: true,
      receivedBytes: 0,
      clearRate: true,
    );
    _wifiBatchCoordinator.replace(paused);
    final persistenceFailure = await _persistWifiBatchDurably(paused);
    final latest = _wifiBatchCoordinator.snapshot;
    if (!recordingCardWifiBatchIsBluetoothResumeFailure(latest) ||
        latest!.batchId != owner.batchId ||
        latest.attemptId != owner.attemptId) {
      return persistenceFailure;
    }
    if (persistenceFailure != null) {
      _fail(persistenceFailure);
      return persistenceFailure;
    }
    _state = _state.copyWith(
      status: RecordingCardControllerStatus.error,
      clearActiveFileKey: true,
      lastErrorCode: failureCode,
    );
    notifyListeners();
    return null;
  }

  RecordingCardWifiBatchSnapshot? _wifiBluetoothHandoffBatchFor(
    List<RecordingCardFileLedgerEntry> entries,
  ) {
    final batch = _wifiBatchCoordinator.snapshot;
    if (!_recordingCardWifiBatchOwnsBluetoothResume(batch)) {
      return null;
    }
    final ownedBatch = batch!;
    final digest = _wifiBatchCardSnDigest(ownedBatch);
    if (digest == null ||
        !entries.any((entry) => entry.cardSnDigest == digest)) {
      return null;
    }
    return ownedBatch;
  }

  bool _wifiBluetoothHandoffHasDurableTargets(
    RecordingCardWifiBatchSnapshot batch,
  ) {
    if (!_recordingCardWifiBatchOwnsBluetoothResume(batch) ||
        _syncLedgerPersistence == null) {
      return false;
    }
    return batch.items.any((item) {
      final signature = item.ledgerSourceSignature?.trim();
      return !item.isCompleted && signature != null && signature.isNotEmpty;
    });
  }

  bool _wifiBluetoothHandoffHasUnsettledTargets(
    RecordingCardWifiBatchSnapshot batch,
  ) {
    if (!_wifiBluetoothHandoffHasDurableTargets(batch)) return false;
    for (final item in batch.items.where((item) => !item.isCompleted)) {
      final resolved = _resolveWifiLedgerItem(batch, item);
      if (resolved.failure != null || !resolved.item.isCompleted) return true;
    }
    return false;
  }

  void _schedulePendingBluetoothResume() {
    final preclaimedLatch = _pendingBluetoothResumeLatchGeneration;
    final visibleBatch = _wifiBatchCoordinator.snapshot;
    final hasRetryableBluetoothFailure =
        recordingCardWifiBatchIsBluetoothResumeFailure(visibleBatch);
    final pending = _resumableUserBluetoothEntries;
    if (pending.isEmpty && !hasRetryableBluetoothFailure) {
      if (preclaimedLatch != null && _pendingBluetoothResumePreflight) {
        _clearPendingBluetoothResumeOwner(releaseLatch: true);
      }
      return;
    }
    if (_disposed ||
        _pendingBluetoothResumeScheduled ||
        _pendingBluetoothResumeInFlight != null ||
        _wifiBatchRestoreInFlight != null) {
      return;
    }
    final device = _state.snapshot.deviceState;
    if (device.isOperationallyConnected) {
      if (_lastAutomaticBluetoothResumeConnectionRevision ==
          _connectionRevision) {
        return;
      }
    } else {
      final failedResumeBatch =
          hasRetryableBluetoothFailure &&
              (pending.isEmpty ||
                  pending.any(
                    (entry) =>
                        entry.cardSnDigest ==
                        _wifiBatchCardSnDigest(visibleBatch!),
                  ))
          ? visibleBatch
          : null;
      final handoff =
          _wifiBluetoothHandoffBatchFor(pending) ?? failedResumeBatch;
      final canRecoverLocally =
          _port is RecordingCardRecoverableBluetoothTransferPort &&
          pending.any((entry) => entry.plannedNativeFileId != null);
      final attemptKey = handoff == null
          ? canRecoverLocally
                ? 'local-planned-recovery'
                : null
          : 'wifi-handoff:${handoff.batchId}';
      if (attemptKey == null ||
          (_pendingBluetoothRecoveryAttemptKey == attemptKey &&
              preclaimedLatch == null)) {
        return;
      }
      _pendingBluetoothRecoveryAttemptKey = attemptKey;
    }
    _pendingBluetoothResumeScheduled = true;
    scheduleMicrotask(() {
      _pendingBluetoothResumeScheduled = false;
      if (_disposed || _pendingBluetoothResumeInFlight != null) return;
      final batch = _wifiBatchCoordinator.snapshot;
      if (recordingCardWifiBatchIsBluetoothResumeFailure(batch)) {
        unawaited(_resumeBluetoothHandoffFailure(batch!));
      } else {
        unawaited(
          _startPendingBluetoothResume(
            preclaimedLatchGeneration: _pendingBluetoothResumeLatchGeneration,
          ),
        );
      }
    });
  }

  bool _ownsPendingBluetoothResume({
    required int resumeGeneration,
    required String attemptKey,
    required int deviceOperation,
    required RecordingCardOperationLease operationLease,
    required int latchGeneration,
  }) {
    final operation = _operationMachine.state;
    return !_disposed &&
        _pendingBluetoothResumePreflight &&
        resumeGeneration == _pendingBluetoothResumeGeneration &&
        attemptKey == _pendingBluetoothRecoveryAttemptKey &&
        deviceOperation == _deviceDiscoveryOperation &&
        identical(_pendingBluetoothResumeOperationLease, operationLease) &&
        _pendingBluetoothResumeLatchGeneration == latchGeneration &&
        latchGeneration == _transferLatchGeneration &&
        _transferInFlight &&
        operation.phase == RecordingCardOperationPhase.running &&
        _operationMachine.owns(operationLease);
  }

  bool _ownsPendingBluetoothResumeFileRefresh(int? resumeGeneration) {
    if (resumeGeneration == null ||
        _pendingBluetoothResumeFileRefreshGeneration != resumeGeneration) {
      return false;
    }
    final lease = _pendingBluetoothResumeOperationLease;
    final latchGeneration = _pendingBluetoothResumeLatchGeneration;
    return lease != null &&
        latchGeneration != null &&
        _pendingBluetoothResumePreflight &&
        resumeGeneration == _pendingBluetoothResumeGeneration &&
        _pendingBluetoothRecoveryAttemptKey != null &&
        latchGeneration == _transferLatchGeneration &&
        _transferInFlight &&
        _operationMachine.state.phase == RecordingCardOperationPhase.running &&
        _operationMachine.owns(lease);
  }

  void _clearPendingBluetoothResumeOwner({required bool releaseLatch}) {
    final latchGeneration = _pendingBluetoothResumeLatchGeneration;
    _pendingBluetoothResumeGeneration += 1;
    _pendingBluetoothResumePreflight = false;
    _pendingBluetoothResumeFileRefreshGeneration = null;
    _pendingBluetoothResumeOperationLease = null;
    _pendingBluetoothResumeLatchGeneration = null;
    _pendingBluetoothRecoveryAttemptKey = null;
    _deviceDiscoveryOperation += 1;
    if (releaseLatch && latchGeneration != null) {
      _releaseTransferLatch(latchGeneration);
    }
  }

  bool get _hasRunningTransfer =>
      _transferInFlight ||
      _wifiBleRecoveryInFlight ||
      _state.hasRunningTransfer;

  bool get canRefreshFilesNow =>
      _state.snapshot.deviceState.isOperationallyConnected &&
      _state.snapshot.recordingInfo.state == RecordingCardRecordingState.idle &&
      !_hasRunningTransfer &&
      _scanFilesInFlight == null &&
      _deviceInfoRefreshInFlight == null &&
      _connectionReconcileInFlight == null &&
      !_recordingCompletionRefreshRequested &&
      _recordingCompletionRefreshInFlight == null &&
      !_operationMachine.state.isActive &&
      (_state.status == RecordingCardControllerStatus.idle ||
          _state.status == RecordingCardControllerStatus.error);

  int get successfulFileRefreshRevision => _successfulFileRefreshRevision;

  int get localRecordingRegistrationRevision =>
      _localRecordingRegistrationRevision;

  (int, int) get recordingControlRevision =>
      (_connectionRevision, _recordingStateRevision);

  bool get hasPendingRecordingCompletionRefresh =>
      _recordingCompletionRefreshRequested ||
      _recordingCompletionRefreshInFlight != null;

  String? get fileCatalogFailureCode =>
      _state.fileCatalog.phase == RecordingCardFileCatalogPhase.failed
      ? _state.fileCatalog.errorCode ?? _state.lastErrorCode
      : null;

  bool get hasLoadedFilesForCurrentConnection =>
      _state.snapshot.deviceState.isOperationallyConnected &&
      _state.fileCatalog.isReady &&
      _state.fileCatalog.connectionRevision == _connectionRevision &&
      _state.fileCatalog.deviceIdentity ==
          _activeConnectionDeviceIdentity(_state.snapshot.deviceState) &&
      _loadedFileDirectoryConnectionRevision == _connectionRevision;

  bool get isRefreshingFiles =>
      _scanFilesInFlight != null &&
      (_state.fileCatalog.phase == RecordingCardFileCatalogPhase.reading ||
          _state.fileCatalog.phase == RecordingCardFileCatalogPhase.verifying);

  List<RecordingCardConnectionHistoryEntry> get recentlyConnectedDevices =>
      List.unmodifiable(_recentlyConnectedDevices);

  @visibleForTesting
  Future<RecordingCardResult<RecordingCardWifiCredentials>> prepareWifiBatch(
    List<RecordingCardScannedFile> files,
  ) async {
    final staged = await queueWifiBatch(files);
    if (!staged.ok || staged.value == null) {
      return RecordingCardResult<RecordingCardWifiCredentials>.failure(
        staged.error ?? _fallbackFailure('RECORDING_CARD_WIFI_PREPARE_FAILED'),
      );
    }
    return _prepareWifiBatchSession(
      _port as RecordingCardWifiSessionPort,
      staged.value!,
      _pendingWifiFiles(staged.value!),
    );
  }

  Future<RecordingCardResult<RecordingCardWifiBatchSnapshot>> queueWifiBatch(
    List<RecordingCardScannedFile> files, {
    String? expectedCardSnDigest,
  }) async {
    if (files.isEmpty) {
      return RecordingCardResult<RecordingCardWifiBatchSnapshot>.failure(
        _fallbackFailure('RECORDING_CARD_WIFI_BATCH_EMPTY'),
      );
    }
    final requestedDevice = _state.snapshot.deviceState;
    final requestedConnectionRevision = _connectionRevision;
    final requestedDeviceIdentity = _activeConnectionDeviceIdentity(
      requestedDevice,
    );
    final requestedReconnectFingerprint = _activeReconnectFingerprint(
      requestedDevice,
    );
    final requestedCardSnDigest = _recordingCardDigestForDevice(
      requestedDevice,
    );
    final requestedDirectorySignatures = _state.snapshot.files
        .map(_recordingCardFileSignature)
        .toSet();
    final normalizedExpectedDigest = expectedCardSnDigest?.trim();
    bool ownsRequestedTarget() {
      return !_disposed &&
          requestedConnectionRevision == _connectionRevision &&
          requestedDeviceIdentity != null &&
          requestedDeviceIdentity ==
              _activeConnectionDeviceIdentity(_state.snapshot.deviceState) &&
          requestedReconnectFingerprint != null &&
          requestedReconnectFingerprint ==
              _activeReconnectFingerprint(_state.snapshot.deviceState) &&
          requestedCardSnDigest ==
              _recordingCardDigestForDevice(_state.snapshot.deviceState) &&
          setEquals(
            requestedDirectorySignatures,
            _state.snapshot.files.map(_recordingCardFileSignature).toSet(),
          );
    }

    if (normalizedExpectedDigest != null &&
        (normalizedExpectedDigest.isEmpty ||
            requestedCardSnDigest != normalizedExpectedDigest)) {
      final failure = recordingCardFailure(
        'RECORDING_CARD_WIFI_BATCH_CARD_CHANGED',
        'Recording-card identity changed before Wi-Fi batch queueing',
        isRetryable: true,
      );
      _fail(failure);
      return RecordingCardResult<RecordingCardWifiBatchSnapshot>.failure(
        failure,
      );
    }
    final retainedHandoff = _wifiBatchCoordinator.snapshot;
    if (retainedHandoff != null &&
        _wifiBluetoothHandoffHasDurableTargets(retainedHandoff)) {
      _blockDeviceOperation(
        kind: RecordingCardOperationKind.wifiTransfer,
        origin: RecordingCardOperationOrigin.user,
      );
      final failure = _operationAdmissionFailure();
      _reportOperationBlocked();
      return RecordingCardResult<RecordingCardWifiBatchSnapshot>.failure(
        failure,
      );
    }
    final legacySettlementFailure =
        await _settleLegacyIncompleteWifiBatchForFreshSelection();
    if (legacySettlementFailure != null) {
      _fail(legacySettlementFailure);
      return RecordingCardResult<RecordingCardWifiBatchSnapshot>.failure(
        legacySettlementFailure,
      );
    }
    if (!ownsRequestedTarget()) {
      final failure = recordingCardFailure(
        'RECORDING_CARD_WIFI_BATCH_CARD_CHANGED',
        'Recording-card identity or directory changed while queueing Wi-Fi',
        isRetryable: true,
      );
      _fail(failure);
      return RecordingCardResult<RecordingCardWifiBatchSnapshot>.failure(
        failure,
      );
    }
    if (_hasTransferConflict) {
      _blockDeviceOperation(
        kind: RecordingCardOperationKind.wifiTransfer,
        origin: RecordingCardOperationOrigin.user,
      );
      final failure = _operationAdmissionFailure();
      _reportOperationBlocked();
      return RecordingCardResult<RecordingCardWifiBatchSnapshot>.failure(
        failure,
      );
    }
    final scanInFlight = _scanFilesInFlight;
    if (scanInFlight != null) await scanInFlight;
    if (!ownsRequestedTarget()) {
      final failure = recordingCardFailure(
        'RECORDING_CARD_WIFI_BATCH_CARD_CHANGED',
        'Recording-card identity or directory changed while queueing Wi-Fi',
        isRetryable: true,
      );
      _fail(failure);
      return RecordingCardResult<RecordingCardWifiBatchSnapshot>.failure(
        failure,
      );
    }
    final port = _port;
    if (port is! RecordingCardWifiSessionPort) {
      final failure = recordingCardFailure(
        'RECORDING_CARD_WIFI_UNAVAILABLE',
        'Recording-card Wi-Fi session transfer is unavailable',
        isRetryable: false,
      );
      _fail(failure);
      return RecordingCardResult<RecordingCardWifiBatchSnapshot>.failure(
        failure,
      );
    }
    final catalogDevice = _state.snapshot.deviceState;
    final catalogRevision = requestedConnectionRevision;
    final catalogIdentity = requestedDeviceIdentity;
    final catalogSignatures = requestedDirectorySignatures;
    if (catalogIdentity == null ||
        !hasLoadedFilesForCurrentConnection ||
        !_state.fileCatalog.owns(
          connectionRevision: catalogRevision,
          deviceIdentity: catalogIdentity,
        )) {
      final failure = recordingCardFailure(
        'RECORDING_CARD_FILE_CATALOG_NOT_READY',
        'Recording-card file directory is not verified',
        isRetryable: true,
      );
      _fail(failure);
      return RecordingCardResult<RecordingCardWifiBatchSnapshot>.failure(
        failure,
      );
    }
    final reconnectFingerprint = requestedReconnectFingerprint;
    if (reconnectFingerprint == null) {
      final failure = recordingCardFailure(
        'RECORDING_CARD_DEVICE_IDENTITY_UNAVAILABLE',
        'Recording-card reconnect identity is unavailable',
        isRetryable: true,
      );
      _fail(failure);
      return RecordingCardResult<RecordingCardWifiBatchSnapshot>.failure(
        failure,
      );
    }
    final cardSnDigest = requestedCardSnDigest;
    if (_syncLedgerPersistence != null && cardSnDigest == null) {
      final failure = recordingCardFailure(
        'RECORDING_CARD_LEDGER_IDENTITY_UNAVAILABLE',
        'Recording-card ledger identity is unavailable',
        isRetryable: true,
      );
      _fail(failure);
      return RecordingCardResult<RecordingCardWifiBatchSnapshot>.failure(
        failure,
      );
    }
    final currentFilesById = <String, RecordingCardScannedFile>{
      for (final file in _state.snapshot.files) file.deviceFileId: file,
    };
    final selectedFilesById = <String, RecordingCardScannedFile>{};
    for (final selected in files) {
      final current = currentFilesById[selected.deviceFileId];
      if (current == null ||
          _recordingCardFileSignature(current) !=
              _recordingCardFileSignature(selected)) {
        final failure = recordingCardFailure(
          'RECORDING_CARD_FILE_SELECTION_STALE',
          'Selected recording-card files no longer match the verified directory',
          isRetryable: true,
        );
        _fail(failure);
        return RecordingCardResult<RecordingCardWifiBatchSnapshot>.failure(
          failure,
        );
      }
      selectedFilesById.putIfAbsent(current.deviceFileId, () => current);
    }
    final selectedFiles = selectedFilesById.values.toList(growable: false);
    if (!_beginTransfer(kind: RecordingCardOperationKind.wifiTransfer)) {
      final failure = _operationAdmissionFailure();
      _reportOperationBlocked();
      return RecordingCardResult<RecordingCardWifiBatchSnapshot>.failure(
        failure,
      );
    }
    final latchGeneration = _transferLatchGeneration;
    _batchCancelRequested = false;
    _batchPauseRequested = false;
    _wifiBatchReconnectFingerprint = reconnectFingerprint;
    final verificationFailure = await _refreshVerifiedDownloadCache();
    if (!_ownsReadyFileCatalog(
      revision: catalogRevision,
      deviceIdentity: catalogIdentity,
      directorySignatures: catalogSignatures,
    )) {
      _releaseTransferLatch(latchGeneration);
      return RecordingCardResult<RecordingCardWifiBatchSnapshot>.failure(
        recordingCardFailure(
          'RECORDING_CARD_FILE_CATALOG_CHANGED',
          'Recording-card connection or verified directory changed',
          isRetryable: true,
        ),
      );
    }
    if (verificationFailure != null) {
      _releaseTransferLatch(latchGeneration);
      _failFileCatalog(verificationFailure);
      return RecordingCardResult<RecordingCardWifiBatchSnapshot>.failure(
        verificationFailure,
      );
    }
    final restored = _restoreVerifiedDownloads(selectedFiles, catalogDevice);
    final now = _clock();
    final batchId = _wifiBatchId(restored, now);
    final items = <RecordingCardWifiBatchItem>[
      for (var index = 0; index < restored.length; index += 1)
        RecordingCardWifiBatchItem(
          file: restored[index],
          state: restored[index].syncState == RecordingCardFileSyncState.synced
              ? RecordingCardWifiBatchItemState.skipped
              : RecordingCardWifiBatchItemState.queued,
          order: index,
          expectedSizeBytes: restored[index].sizeBytes ?? 0,
          localRecordingId: restored[index].localFileId,
        ),
    ];
    var batch = RecordingCardWifiBatchSnapshot(
      batchId: batchId,
      deviceFingerprint: reconnectFingerprint,
      deviceIdentity: catalogIdentity,
      cardSnDigest: cardSnDigest,
      state: RecordingCardWifiBatchState.queued,
      items: List<RecordingCardWifiBatchItem>.unmodifiable(items),
      createdAt: now,
      updatedAt: now,
    );
    final supersededBatchIds = _localRecordingRepository
        .recordingCardWifiBatchItems()
        .map((row) => _safeBatchRecordText(row['batch_id']))
        .whereType<String>()
        .where((id) => id != batchId)
        .toSet();
    AppFailure? ledgerInitializationFailure;
    final initialization = _localRecordingRepository
        .writeRecordingCardWifiBatchAtomically(() {
          for (final supersededBatchId in supersededBatchIds) {
            _localRecordingRepository.deleteRecordingCardWifiBatch(
              supersededBatchId,
            );
          }
          var working = batch;
          final resolvedItems = <RecordingCardWifiBatchItem>[...working.items];
          for (var index = 0; index < resolvedItems.length; index += 1) {
            final transition = _queueWifiLedgerItem(
              working,
              resolvedItems[index],
            );
            if (transition.failure != null) {
              ledgerInitializationFailure = transition.failure;
              throw StateError(transition.failure!.code);
            }
            resolvedItems[index] = transition.item;
            working = working.copyWith(items: resolvedItems);
          }
          batch = working;
          for (final item in batch.items) {
            _upsertWifiBatchItem(batch, item);
          }
        });
    if (!initialization.ok) {
      final failure =
          ledgerInitializationFailure ??
          recordingCardFailure(
            'RECORDING_CARD_LEDGER_INITIALIZATION_FAILED',
            'Recording-card batch and sync ledger could not be initialized',
            cause: initialization.error,
            isRetryable: true,
          );
      _releaseTransferLatch(latchGeneration);
      _fail(failure);
      return RecordingCardResult<RecordingCardWifiBatchSnapshot>.failure(
        failure,
      );
    }
    final initializationFlushFailure = await _flushWifiBatchPersistence();
    if (initializationFlushFailure != null) {
      _releaseTransferLatch(latchGeneration);
      _fail(initializationFlushFailure);
      return RecordingCardResult<RecordingCardWifiBatchSnapshot>.failure(
        initializationFlushFailure,
      );
    }
    _wifiBatchStateGeneration += 1;
    _wifiBatchCoordinator.replace(batch);
    final ledgerFailure = await _completeSkippedWifiLedgerItems(batch);
    if (ledgerFailure != null) {
      final current = _wifiBatchCoordinator.snapshot ?? batch;
      var paused = current.copyWith(
        state: RecordingCardWifiBatchState.paused,
        failureCode: ledgerFailure.code,
        updatedAt: _clock(),
      );
      final persistenceFailure = await _persistWifiBatchDurably(paused);
      final effectiveFailure = persistenceFailure ?? ledgerFailure;
      if (persistenceFailure != null) {
        paused = _pausedWifiBatchSnapshot(
          paused,
          failureCode: persistenceFailure.code,
        );
      }
      _wifiBatchCoordinator.replace(paused);
      _releaseTransferLatch(latchGeneration);
      _fail(effectiveFailure);
      return RecordingCardResult<RecordingCardWifiBatchSnapshot>.failure(
        effectiveFailure,
      );
    }
    batch = _wifiBatchCoordinator.snapshot ?? batch;
    final pending = _pendingWifiFiles(batch);
    if (pending.isEmpty) {
      batch = batch.copyWith(
        state: RecordingCardWifiBatchState.completed,
        clearFailure: true,
        updatedAt: _clock(),
      );
      final persistenceFailure = await _persistWifiBatchDurably(batch);
      if (persistenceFailure != null) {
        final paused = batch.copyWith(
          state: RecordingCardWifiBatchState.paused,
          failureCode: persistenceFailure.code,
          updatedAt: _clock(),
        );
        _wifiBatchCoordinator.replace(paused);
        _releaseTransferLatch(latchGeneration);
        _fail(persistenceFailure);
        return RecordingCardResult<RecordingCardWifiBatchSnapshot>.failure(
          persistenceFailure,
        );
      }
      _wifiBatchCoordinator.replace(batch);
      _releaseTransferLatch(latchGeneration);
      return RecordingCardResult<RecordingCardWifiBatchSnapshot>.failure(
        _fallbackFailure('RECORDING_CARD_WIFI_BATCH_ALREADY_SYNCED'),
      );
    }
    _state = _state.copyWith(
      status: RecordingCardControllerStatus.idle,
      clearActiveFileKey: true,
      lastErrorCode: null,
    );
    notifyListeners();
    return RecordingCardResult<RecordingCardWifiBatchSnapshot>.success(batch);
  }

  Future<RecordingCardResult<bool>> _joinPreparedWifiNetwork(
    RecordingCardWifiCredentials credentials,
  ) async {
    final batch = _wifiBatchCoordinator.snapshot;
    final joinPort = _port;
    if (batch == null ||
        batch.state != RecordingCardWifiBatchState.awaitingHotspot) {
      return RecordingCardResult<bool>.failure(
        _fallbackFailure('RECORDING_CARD_WIFI_BATCH_NOT_PREPARED'),
      );
    }
    final stateGeneration = _wifiBatchStateGeneration;
    bool ownsJoin() {
      final current = _wifiBatchCoordinator.snapshot;
      return stateGeneration == _wifiBatchStateGeneration &&
          current?.batchId == batch.batchId &&
          current?.state == RecordingCardWifiBatchState.awaitingHotspot;
    }

    if (joinPort is! RecordingCardWifiJoinPort) {
      final failure = _fallbackFailure('RECORDING_CARD_WIFI_JOIN_UNAVAILABLE');
      await _pauseWifiBatch(failure);
      return RecordingCardResult<bool>.failure(failure);
    }
    final wifiJoinPort = joinPort as RecordingCardWifiJoinPort;
    _state = _state.copyWith(
      status: RecordingCardControllerStatus.preparingWifi,
      lastErrorCode: null,
    );
    notifyListeners();
    AppFailure? permissionFailure;
    try {
      permissionFailure = await _permissionCoordinator
          .requestLocalNetworkAccess();
    } catch (error) {
      permissionFailure = recordingCardFailure(
        'RECORDING_CARD_WIFI_PERMISSION_FAILED',
        'Recording-card Wi-Fi permission request threw unexpectedly',
        cause: error,
        isRetryable: true,
      );
    }
    if (!ownsJoin()) {
      return RecordingCardResult<bool>.failure(
        _fallbackFailure('RECORDING_CARD_WIFI_JOIN_SUPERSEDED'),
      );
    }
    if (permissionFailure != null) {
      await _pauseWifiBatch(permissionFailure);
      return RecordingCardResult<bool>.failure(permissionFailure);
    }
    late final RecordingCardResult<bool> result;
    try {
      result = await wifiJoinPort
          .joinWifiNetwork(credentials)
          .timeout(_wifiSetupTimeout);
    } on TimeoutException catch (error) {
      result = RecordingCardResult<bool>.failure(
        recordingCardFailure(
          'RECORDING_CARD_WIFI_NETWORK_JOIN_TIMEOUT',
          'Recording-card Wi-Fi join timed out',
          cause: error,
          isRetryable: true,
        ),
      );
    } catch (error) {
      result = RecordingCardResult<bool>.failure(
        recordingCardFailure(
          'RECORDING_CARD_WIFI_NETWORK_JOIN_FAILED',
          'Recording-card Wi-Fi join threw unexpectedly',
          cause: error,
          isRetryable: true,
        ),
      );
    }
    if (!ownsJoin()) {
      return RecordingCardResult<bool>.failure(
        _fallbackFailure('RECORDING_CARD_WIFI_JOIN_SUPERSEDED'),
      );
    }
    if (!result.ok || result.value != true) {
      final failure =
          result.error ??
          _fallbackFailure('RECORDING_CARD_WIFI_NETWORK_JOIN_FAILED');
      await _pauseWifiBatch(failure);
      return RecordingCardResult<bool>.failure(failure);
    }
    _state = _state.copyWith(
      status: RecordingCardControllerStatus.idle,
      clearActiveFileKey: true,
      lastErrorCode: null,
    );
    notifyListeners();
    return RecordingCardResult<bool>.success(true);
  }

  Future<RecordingCardResult<RecordingCardWifiHandoffResult>>
  _verifyPreparedWifiHandoff() async {
    final port = _port;
    if (port is! RecordingCardWifiTransferPort) {
      return RecordingCardResult<RecordingCardWifiHandoffResult>.failure(
        recordingCardFailure(
          'RECORDING_CARD_WIFI_UNAVAILABLE',
          'Recording-card Wi-Fi handoff is unavailable',
          isRetryable: false,
        ),
      );
    }
    late final RecordingCardResult<RecordingCardWifiHandoffResult> result;
    try {
      result = await (port as RecordingCardWifiTransferPort)
          .verifyWifiHandoff()
          .timeout(_wifiSetupTimeout);
    } on TimeoutException catch (error) {
      return RecordingCardResult<RecordingCardWifiHandoffResult>.failure(
        recordingCardFailure(
          'RECORDING_CARD_WIFI_HANDOFF_TIMEOUT',
          'Recording-card Wi-Fi handoff verification timed out',
          cause: error,
          isRetryable: true,
        ),
      );
    } catch (error) {
      return RecordingCardResult<RecordingCardWifiHandoffResult>.failure(
        recordingCardFailure(
          'RECORDING_CARD_WIFI_CHECK_FAILED',
          'Recording-card Wi-Fi handoff verification failed',
          cause: error,
          isRetryable: true,
        ),
      );
    }
    if (!result.ok || result.value == null) return result;
    if (result.value!.status != RecordingCardWifiHandoffStatus.ready) {
      return RecordingCardResult<RecordingCardWifiHandoffResult>.failure(
        recordingCardFailure(
          'RECORDING_CARD_WIFI_NETWORK_UNAVAILABLE',
          'Recording-card Wi-Fi endpoint is unavailable after handoff',
          isRetryable: true,
        ),
      );
    }
    return result;
  }

  Future<RecordingCardResult<RecordingCardWifiBatchSnapshot>>
  resumeWifiBatch() {
    final batch = _wifiBatchCoordinator.snapshot;
    if (recordingCardWifiBatchIsBluetoothResumeFailure(batch)) {
      return _resumeBluetoothHandoffFailure(batch!);
    }
    return _startWifiFlow(failedOnly: false);
  }

  Future<RecordingCardResult<RecordingCardWifiBatchSnapshot>>
  startQueuedWifiBatch() => _startWifiFlow(failedOnly: false);

  Future<RecordingCardResult<RecordingCardWifiBatchSnapshot>>
  retryFailedWifiBatch() => _startWifiFlow(failedOnly: true);

  Future<RecordingCardResult<RecordingCardWifiBatchSnapshot>>
  _resumeBluetoothHandoffFailure(RecordingCardWifiBatchSnapshot owner) async {
    final stateGeneration = ++_wifiBatchStateGeneration;
    final persistence = _syncLedgerPersistence;
    final digest = _wifiBatchCardSnDigest(owner);
    if (persistence == null || digest == null) {
      final failure = _fallbackFailure(
        'RECORDING_CARD_LEDGER_IDENTITY_UNAVAILABLE',
      );
      _fail(failure);
      return RecordingCardResult<RecordingCardWifiBatchSnapshot>.failure(
        failure,
      );
    }
    final targetSignatures = owner.items
        .where((item) => !item.isCompleted)
        .map((item) => item.ledgerSourceSignature?.trim())
        .whereType<String>()
        .where((signature) => signature.isNotEmpty)
        .toSet();
    if (targetSignatures.isEmpty) {
      final failure = _fallbackFailure(
        'RECORDING_CARD_LEDGER_IDENTITY_UNAVAILABLE',
      );
      _fail(failure);
      return RecordingCardResult<RecordingCardWifiBatchSnapshot>.failure(
        failure,
      );
    }
    final syncedSignatures = <String>{};
    try {
      final at = _clock();
      for (final signature in targetSignatures) {
        final entry = persistence.findFileLedgerEntry(
          cardSnDigest: digest,
          sourceSignature: signature,
        );
        if (entry == null) {
          throw StateError('Bluetooth handoff ledger entry is unavailable');
        }
        if (entry.localState == RecordingCardFileLocalState.synced) {
          syncedSignatures.add(signature);
          continue;
        }
        persistence.saveFileLedgerEntry(
          entry.queue(at: at, manual: true, resetAttemptCount: true),
        );
      }
      await persistence.flushSyncPersistence();
    } on Object catch (error) {
      final failure = recordingCardFailure(
        'RECORDING_CARD_LEDGER_RECOVERY_FAILED',
        'Recording-card Bluetooth retry intent could not be persisted',
        cause: error,
        isRetryable: true,
      );
      _fail(failure);
      return RecordingCardResult<RecordingCardWifiBatchSnapshot>.failure(
        failure,
      );
    }
    final current = _wifiBatchCoordinator.snapshot;
    if (_disposed ||
        stateGeneration != _wifiBatchStateGeneration ||
        current?.batchId != owner.batchId ||
        current?.attemptId != owner.attemptId ||
        !recordingCardWifiBatchIsBluetoothResumeFailure(current)) {
      return RecordingCardResult<RecordingCardWifiBatchSnapshot>.failure(
        _fallbackFailure('RECORDING_CARD_BLUETOOTH_RESUME_SUPERSEDED'),
      );
    }
    final handoff = current!.copyWith(
      state: RecordingCardWifiBatchState.cancelled,
      operationPhase: RecordingCardWifiOperationPhase.idle,
      stopRequested: false,
      items: current.items
          .map((item) {
            final signature = item.ledgerSourceSignature?.trim();
            if (item.isCompleted ||
                (signature != null && syncedSignatures.contains(signature))) {
              return item.copyWith(
                state: RecordingCardWifiBatchItemState.completed,
                clearError: true,
              );
            }
            return item.copyWith(
              state: RecordingCardWifiBatchItemState.cancelled,
              clearError: true,
              clearStagedDownload: true,
            );
          })
          .toList(growable: false),
      failureCode: recordingCardWifiBluetoothHandoffFailureCode,
      updatedAt: _clock(),
      clearCurrentItem: true,
      receivedBytes: 0,
      clearRate: true,
    );
    final persistenceFailure = await _persistWifiBatchDurably(handoff);
    if (_disposed ||
        stateGeneration != _wifiBatchStateGeneration ||
        _wifiBatchCoordinator.snapshot?.batchId != owner.batchId ||
        _wifiBatchCoordinator.snapshot?.attemptId != owner.attemptId) {
      return RecordingCardResult<RecordingCardWifiBatchSnapshot>.failure(
        _fallbackFailure('RECORDING_CARD_BLUETOOTH_RESUME_SUPERSEDED'),
      );
    }
    if (persistenceFailure != null) {
      _fail(persistenceFailure);
      return RecordingCardResult<RecordingCardWifiBatchSnapshot>.failure(
        persistenceFailure,
      );
    }
    _wifiBatchCoordinator.replace(handoff);
    _pendingBluetoothRecoveryAttemptKey = null;
    final resumed = await _startPendingBluetoothResume();
    final latest = _wifiBatchCoordinator.snapshot;
    if (!resumed.ok) {
      return RecordingCardResult<RecordingCardWifiBatchSnapshot>.failure(
        resumed.error ??
            _fallbackFailure('RECORDING_CARD_BLUETOOTH_RESUME_FAILED'),
      );
    }
    if (latest == null || latest.batchId != owner.batchId) {
      return RecordingCardResult<RecordingCardWifiBatchSnapshot>.failure(
        _fallbackFailure('RECORDING_CARD_BLUETOOTH_RESUME_SUPERSEDED'),
      );
    }
    return RecordingCardResult<RecordingCardWifiBatchSnapshot>.success(latest);
  }

  Future<RecordingCardResult<RecordingCardWifiCredentials>>
  _startWifiBatchReprepare({required bool failedOnly}) {
    final running = _wifiBatchReprepareInFlight;
    if (running != null) return running;
    if (_wifiBatchDismissInFlight != null) {
      return Future<RecordingCardResult<RecordingCardWifiCredentials>>.value(
        RecordingCardResult<RecordingCardWifiCredentials>.failure(
          _fallbackFailure('RECORDING_CARD_WIFI_BATCH_DISMISS_IN_PROGRESS'),
        ),
      );
    }
    late final Future<RecordingCardResult<RecordingCardWifiCredentials>>
    operation;
    operation = _reprepareWifiBatch(failedOnly: failedOnly).whenComplete(() {
      if (identical(_wifiBatchReprepareInFlight, operation)) {
        _wifiBatchReprepareInFlight = null;
      }
    });
    _wifiBatchReprepareInFlight = operation;
    return operation;
  }

  @visibleForTesting
  Future<void> startPreparedWifiBatch() => _startPreparedWifiBatch();

  @visibleForTesting
  Future<RecordingCardResult<bool>> joinPreparedWifiNetwork(
    RecordingCardWifiCredentials credentials,
  ) => _joinPreparedWifiNetwork(credentials);

  Future<void> _startPreparedWifiBatch() {
    final running = _batchRunInFlight;
    if (running != null) return running;
    if (_wifiBatchCancelInFlight != null ||
        _wifiBatchPauseInFlight != null ||
        _batchStopRequested) {
      return Future<void>.value();
    }
    late final Future<void> operation;
    operation = _runPreparedWifiBatch().whenComplete(() {
      if (identical(_batchRunInFlight, operation)) _batchRunInFlight = null;
    });
    _batchRunInFlight = operation;
    return operation;
  }

  Future<void> pauseWifiBatch() {
    final cancelling = _wifiBatchCancelInFlight;
    if (cancelling != null) return cancelling;
    final running = _wifiBatchPauseInFlight;
    if (running != null) return running;
    late final Future<void> operation;
    operation = _pauseWifiBatchByUser().whenComplete(() {
      if (identical(_wifiBatchPauseInFlight, operation)) {
        _wifiBatchPauseInFlight = null;
      }
    });
    _wifiBatchPauseInFlight = operation;
    return operation;
  }

  Future<void> _pauseWifiBatchByUser() async {
    _abortWifiFlow();
    final stateGeneration = ++_wifiBatchStateGeneration;
    _wifiPreparationGeneration += 1;
    _wifiBatchReconnectFingerprint = null;
    _pendingBluetoothRecoveryAttemptKey = null;
    final restoring = _wifiBatchRestoreInFlight;
    if (restoring != null) await restoring;
    if (_disposed || stateGeneration != _wifiBatchStateGeneration) return;
    final initialBatch = _wifiBatchCoordinator.snapshot;
    if (initialBatch == null || !initialBatch.isActive) return;
    final batchId = initialBatch.batchId;
    final attemptId = initialBatch.attemptId;
    bool ownsPause() {
      final current = _wifiBatchCoordinator.snapshot;
      return !_disposed &&
          stateGeneration == _wifiBatchStateGeneration &&
          !_batchCancelRequested &&
          current?.batchId == batchId &&
          current?.attemptId == attemptId;
    }

    final latchGeneration = _transferLatchGeneration;
    final operationLease = _activeTransferOperationLease;
    if (operationLease != null &&
        _operationMachine.requestCancellation(operationLease)) {
      _publishOperationState();
    }
    _batchPauseRequested = true;
    _batchCancelRequested = false;
    try {
      _state = _state.copyWith(
        status: RecordingCardControllerStatus.cancellingTransfer,
        lastErrorCode: null,
      );
      notifyListeners();
      var nativePauseFailure = await _cancelNativeWifiTransfer(
        initialBatch.batchId,
        attemptId: initialBatch.attemptId,
      );
      if (!ownsPause()) return;
      _interruptWifiBatchDownload(
        nativePauseFailure?.code ?? 'RECORDING_CARD_WIFI_TRANSFER_PAUSED',
      );
      final repreparing = _wifiBatchReprepareInFlight;
      if (repreparing != null) {
        await repreparing.timeout(
          _wifiSetupTimeout,
          onTimeout: () => RecordingCardResult.failure(
            _fallbackFailure('RECORDING_CARD_WIFI_PREPARATION_STALE'),
          ),
        );
        if (!ownsPause()) return;
      }
      final runOwner = _batchRunInFlight;
      if (runOwner != null) {
        await runOwner.timeout(_wifiSetupTimeout, onTimeout: () {});
        if (!ownsPause()) return;
      }
      final batch = _wifiBatchCoordinator.snapshot;
      if (!ownsPause()) return;
      if (batch == null || batch.isTerminal) {
        _releaseTransferLatch(latchGeneration);
        _state = _state.copyWith(
          status: RecordingCardControllerStatus.idle,
          clearActiveFileKey: true,
          lastErrorCode: null,
        );
        notifyListeners();
        return;
      }
      if (_wifiBatchTeardownPendingBatchId != batch.batchId) {
        nativePauseFailure = null;
      }
      final needsBleRecovery =
          _wifiBatchTeardownPendingBatchId != batch.batchId;
      var paused = _pausedWifiBatchSnapshot(
        batch,
        failureCode: nativePauseFailure?.code,
        willRecoverBle: needsBleRecovery,
      );
      _wifiBatchCoordinator.replace(paused);
      final ledgerFailure = await _reconcileRestoredWifiLedger(paused.batchId);
      if (!ownsPause()) return;
      paused = _wifiBatchCoordinator.snapshot ?? paused;
      final persistenceFailure = await _persistWifiBatchDurably(paused);
      if (!ownsPause()) return;
      final pauseFailure =
          nativePauseFailure ?? ledgerFailure ?? persistenceFailure;
      if (persistenceFailure != null) {
        paused = _pausedWifiBatchSnapshot(
          paused,
          failureCode: persistenceFailure.code,
        );
        _wifiBatchCoordinator.replace(paused);
      }
      if (pauseFailure == null) {
        _state = _state.copyWith(
          status: RecordingCardControllerStatus.idle,
          clearActiveFileKey: true,
          lastErrorCode: null,
        );
        notifyListeners();
      } else {
        _fail(pauseFailure);
      }
      if (!needsBleRecovery) {
        _releaseTransferLatch(latchGeneration);
        return;
      }
      if (!ownsPause()) return;
      await _recoverBleAfterWifiBatch(paused);
    } finally {
      _batchPauseRequested = false;
    }
  }

  Future<void> reconcileWifiBatch({String? interruptionCode}) =>
      _reconcileWifiBatch(interruptionCode: interruptionCode);

  Future<void> cancelWifiBatch() {
    final running = _wifiBatchCancelInFlight;
    if (running != null) return running;
    late final Future<void> operation;
    operation =
        (() async {
          await _cancelWifiBatchByUser();
        })().whenComplete(() {
          if (identical(_wifiBatchCancelInFlight, operation)) {
            _wifiBatchCancelInFlight = null;
          }
        });
    _wifiBatchCancelInFlight = operation;
    return operation;
  }

  Future<void> _cancelWifiBatchByUser() async {
    final stateGeneration = ++_wifiBatchStateGeneration;
    _wifiPreparationGeneration += 1;
    final restoring = _wifiBatchRestoreInFlight;
    if (restoring != null) await restoring;
    final initialBatch = _wifiBatchCoordinator.snapshot;
    final isBluetoothHandoff = recordingCardWifiBatchIsBluetoothHandoff(
      initialBatch,
    );
    if (initialBatch == null ||
        (initialBatch.state == RecordingCardWifiBatchState.cancelled &&
            !isBluetoothHandoff) ||
        (initialBatch.state == RecordingCardWifiBatchState.completed &&
            initialBatch.remainingCount == 0)) {
      return;
    }
    _abortWifiFlow();
    if (isBluetoothHandoff) {
      await _cancelBluetoothHandoffByUser(
        initialBatch,
        stateGeneration: stateGeneration,
      );
      return;
    }
    if (initialBatch.recoveryBlocked) {
      _setWifiOperation(RecordingCardWifiOperationPhase.stopping);
      final stopped = await _localRecordingRepository
          .stopInvalidRecordingCardWifiBatch(initialBatch.batchId);
      _wifiBatchCoordinator.replace(
        initialBatch.copyWith(
          state: stopped.ok
              ? RecordingCardWifiBatchState.cancelled
              : RecordingCardWifiBatchState.paused,
          operationPhase: RecordingCardWifiOperationPhase.idle,
          stopRequested: stopped.ok,
        ),
      );
      if (!stopped.ok) {
        _fail(_fallbackFailure('RECORDING_CARD_WIFI_BATCH_PERSIST_FAILED'));
      }
      return;
    }
    final stopping = initialBatch.copyWith(
      stopRequested: true,
      operationPhase: RecordingCardWifiOperationPhase.stopping,
      updatedAt: _clock(),
    );
    _wifiBatchCoordinator.replace(stopping);
    _batchCancelRequested = true;
    final stopPersistenceFailure = await _persistWifiBatchDurably(stopping);
    if (stopPersistenceFailure != null) _fail(stopPersistenceFailure);
    final pausing = _wifiBatchPauseInFlight;
    if (pausing != null) await pausing;
    final batchAfterPause = _wifiBatchCoordinator.snapshot;
    if (batchAfterPause == null ||
        batchAfterPause.state == RecordingCardWifiBatchState.cancelled ||
        (batchAfterPause.state == RecordingCardWifiBatchState.completed &&
            batchAfterPause.remainingCount == 0)) {
      return;
    }
    final claimedLatchGeneration = _transferInFlight
        ? _transferLatchGeneration
        : _claimWifiTransitionLatch();
    if (claimedLatchGeneration == null) {
      _fail(_operationAdmissionFailure());
      return;
    }
    var latchGeneration = claimedLatchGeneration;
    final operationLease = _activeTransferOperationLease;
    if (operationLease != null &&
        _operationMachine.requestCancellation(operationLease)) {
      _publishOperationState();
    }
    _batchCancelRequested = true;
    _batchPauseRequested = false;
    try {
      final retiringLegacyBatch = _canRetireLegacyWifiBatch(batchAfterPause);
      final nativeTeardownAlreadySettled =
          batchAfterPause.state == RecordingCardWifiBatchState.paused &&
          _wifiBatchTeardownPendingBatchId != batchAfterPause.batchId;
      var nativeCancelFailure =
          retiringLegacyBatch || nativeTeardownAlreadySettled
          ? null
          : await _cancelNativeWifiTransfer(
              batchAfterPause.batchId,
              attemptId: batchAfterPause.attemptId,
            );
      _interruptWifiBatchDownload(
        nativeCancelFailure?.code ?? 'RECORDING_CARD_WIFI_TRANSFER_CANCELLED',
      );
      final repreparing = _wifiBatchReprepareInFlight;
      if (repreparing != null) {
        await repreparing.timeout(
          _wifiSetupTimeout,
          onTimeout: () => RecordingCardResult.failure(
            _fallbackFailure('RECORDING_CARD_WIFI_PREPARATION_STALE'),
          ),
        );
      }
      final runOwner = _batchRunInFlight;
      if (runOwner != null) {
        await runOwner.timeout(_wifiSetupTimeout, onTimeout: () {});
      }
      var batch = _wifiBatchCoordinator.snapshot;
      if (batch == null ||
          batch.state == RecordingCardWifiBatchState.cancelled ||
          (batch.state == RecordingCardWifiBatchState.completed &&
              batch.remainingCount == 0)) {
        return;
      }
      if (_wifiBatchTeardownPendingBatchId != batch.batchId) {
        nativeCancelFailure = null;
      }
      if (nativeCancelFailure != null) {
        var paused = _pausedWifiBatchSnapshot(
          batch,
          failureCode: nativeCancelFailure.code,
        );
        _wifiBatchCoordinator.replace(paused);
        final ledgerFailure = await _reconcileRestoredWifiLedger(
          paused.batchId,
        );
        paused = _wifiBatchCoordinator.snapshot ?? paused;
        final persistenceFailure = await _persistWifiBatchDurably(paused);
        final failure =
            persistenceFailure ?? ledgerFailure ?? nativeCancelFailure;
        if (persistenceFailure != null) {
          paused = _pausedWifiBatchSnapshot(
            paused,
            failureCode: persistenceFailure.code,
          );
          _wifiBatchCoordinator.replace(paused);
        }
        _fail(failure);
        _releaseTransferLatch(latchGeneration);
        return;
      }
      final recoveryFailure = await _recoverPlannedWifiDownloads(batch.batchId);
      batch = _wifiBatchCoordinator.snapshot;
      if (batch == null) return;
      if (recoveryFailure != null) {
        final needsBleRecovery = _wifiCancellationNeedsBleRecovery(batch);
        final paused = _pausedWifiBatchSnapshot(
          batch,
          failureCode: recoveryFailure.code,
          willRecoverBle: needsBleRecovery,
        );
        _wifiBatchCoordinator.replace(paused);
        _fail(recoveryFailure);
        if (needsBleRecovery) {
          await _recoverBleAfterWifiBatch(paused);
        } else {
          _releaseTransferLatch(latchGeneration);
        }
        return;
      }
      if (batch.items.any((item) => item.stagedDownload != null)) {
        latchGeneration = _claimTransferLatch();
        final registrationFailure = await _registerStagedWifiBatchFilesOnce();
        batch = _wifiBatchCoordinator.snapshot;
        final hasRetainedStage =
            batch?.items.any((item) => item.stagedDownload != null) ?? false;
        if (batch != null &&
            (registrationFailure != null || hasRetainedStage)) {
          final failure =
              registrationFailure ??
              _fallbackFailure(
                'RECORDING_CARD_LOCAL_LIBRARY_REGISTRATION_FAILED',
              );
          final needsBleRecovery = _wifiCancellationNeedsBleRecovery(batch);
          var paused = _pausedWifiBatchSnapshot(
            batch,
            failureCode: failure.code,
            willRecoverBle: needsBleRecovery,
          );
          _wifiBatchCoordinator.replace(paused);
          final ledgerFailure = await _reconcileRestoredWifiLedger(
            paused.batchId,
          );
          paused = _wifiBatchCoordinator.snapshot ?? paused;
          final persistenceFailure = await _persistWifiBatchDurably(paused);
          final effectiveFailure =
              persistenceFailure ?? ledgerFailure ?? failure;
          if (persistenceFailure != null) {
            paused = _pausedWifiBatchSnapshot(
              paused,
              failureCode: persistenceFailure.code,
            );
            _wifiBatchCoordinator.replace(paused);
          }
          _fail(effectiveFailure);
          if (needsBleRecovery) {
            await _recoverBleAfterWifiBatch(paused);
          } else {
            _releaseTransferLatch(latchGeneration);
          }
          return;
        }
      }
      if (batch == null ||
          batch.state == RecordingCardWifiBatchState.cancelled ||
          (batch.state == RecordingCardWifiBatchState.completed &&
              batch.remainingCount == 0)) {
        return;
      }
      final needsBleRecovery =
          !retiringLegacyBatch && _wifiCancellationNeedsBleRecovery(batch);
      final cancellationProjection = batch.copyWith(
        state: RecordingCardWifiBatchState.paused,
        operationPhase: needsBleRecovery
            ? RecordingCardWifiOperationPhase.recovering
            : RecordingCardWifiOperationPhase.idle,
        items: batch.items
            .map((item) {
              if (item.state == RecordingCardWifiBatchItemState.completed ||
                  item.state == RecordingCardWifiBatchItemState.skipped ||
                  item.state == RecordingCardWifiBatchItemState.failed) {
                return item;
              }
              return item.copyWith(
                state: RecordingCardWifiBatchItemState.cancelled,
                clearError: true,
              );
            })
            .toList(growable: false),
        updatedAt: _clock(),
        clearFailure: true,
        clearCurrentItem: true,
        receivedBytes: 0,
        clearRate: true,
      );
      _wifiBatchCoordinator.replace(cancellationProjection);
      final ledgerFailure = retiringLegacyBatch
          ? null
          : await _reconcileRestoredWifiLedger(cancellationProjection.batchId);
      if (ledgerFailure != null) {
        var paused = _pausedWifiBatchSnapshot(
          batch,
          failureCode: ledgerFailure.code,
          willRecoverBle: needsBleRecovery,
        );
        final persistenceFailure = await _persistWifiBatchDurably(paused);
        final effectiveFailure = persistenceFailure ?? ledgerFailure;
        if (persistenceFailure != null) {
          paused = _pausedWifiBatchSnapshot(
            paused,
            failureCode: persistenceFailure.code,
          );
        }
        _wifiBatchCoordinator.replace(paused);
        _fail(effectiveFailure);
        if (needsBleRecovery) {
          await _recoverBleAfterWifiBatch(paused);
        } else {
          _releaseTransferLatch(latchGeneration);
        }
        return;
      }
      final reconciled =
          _wifiBatchCoordinator.snapshot ?? cancellationProjection;
      final cancelled = reconciled.copyWith(
        state: RecordingCardWifiBatchState.cancelled,
        clearFailure: true,
        updatedAt: _clock(),
      );
      final persistenceFailure = await _persistWifiBatchDurably(cancelled);
      if (persistenceFailure != null) {
        final paused = _pausedWifiBatchSnapshot(
          batch,
          failureCode: persistenceFailure.code,
          willRecoverBle: needsBleRecovery,
        );
        _wifiBatchCoordinator.replace(paused);
        _fail(persistenceFailure);
        if (needsBleRecovery) {
          await _recoverBleAfterWifiBatch(paused);
        } else {
          _releaseTransferLatch(latchGeneration);
        }
        return;
      }
      if (retiringLegacyBatch &&
          _wifiBatchLedgerFailureBatchId == cancelled.batchId) {
        _wifiBatchLedgerFailureBatchId = null;
      }
      _wifiBatchCoordinator.replace(cancelled);
      _state = _state.copyWith(
        status: RecordingCardControllerStatus.idle,
        clearActiveFileKey: true,
        lastErrorCode: null,
      );
      notifyListeners();
      if (needsBleRecovery) {
        await _recoverBleAfterWifiBatch(cancelled);
      } else {
        _releaseTransferLatch(latchGeneration);
      }
    } finally {
      _batchCancelRequested = false;
    }
  }

  Future<void> _cancelBluetoothHandoffByUser(
    RecordingCardWifiBatchSnapshot initialBatch, {
    required int stateGeneration,
  }) async {
    bool ownsBatch() {
      final current = _wifiBatchCoordinator.snapshot;
      return !_disposed &&
          stateGeneration == _wifiBatchStateGeneration &&
          current?.batchId == initialBatch.batchId;
    }

    final attemptKey = 'wifi-handoff:${initialBatch.batchId}';
    final ownsPendingResume =
        _pendingBluetoothRecoveryAttemptKey == attemptKey &&
        _pendingBluetoothResumeLatchGeneration != null;
    final preflightOnly = ownsPendingResume && _pendingBluetoothResumePreflight;
    final latchGeneration = ownsPendingResume
        ? _pendingBluetoothResumeLatchGeneration
        : null;
    final operationLease = ownsPendingResume
        ? _pendingBluetoothResumeOperationLease
        : null;
    final activeResume = ownsPendingResume
        ? _pendingBluetoothResumeInFlight
        : null;
    final capturedActiveBluetooth =
        !preflightOnly &&
        operationLease?.kind == RecordingCardOperationKind.bluetoothTransfer &&
        identical(_activeTransferOperationLease, operationLease) &&
        activeResume != null;
    bool ownsCapturedActiveBluetooth() =>
        capturedActiveBluetooth &&
        latchGeneration != null &&
        _transferInFlight &&
        latchGeneration == _transferLatchGeneration &&
        identical(_activeTransferOperationLease, operationLease) &&
        _operationMachine.owns(operationLease);
    int? cancelledPreflightDeviceOperation;
    var preflightOwnershipSettled = false;

    void settlePreflightOwnership() {
      if (!preflightOnly || preflightOwnershipSettled) return;
      preflightOwnershipSettled = true;
      if (latchGeneration != null) {
        _releaseTransferLatch(latchGeneration);
      }
      if (activeResume != null && cancelledPreflightDeviceOperation != null) {
        _reconcileAfterCancelledBluetoothPreflight(
          activeResume,
          deviceOperation: cancelledPreflightDeviceOperation,
        );
      }
    }

    if (preflightOnly) {
      _clearPendingBluetoothResumeOwner(releaseLatch: false);
      cancelledPreflightDeviceOperation = _deviceDiscoveryOperation;
    }

    final stopping = initialBatch.copyWith(
      stopRequested: true,
      operationPhase: RecordingCardWifiOperationPhase.stopping,
      updatedAt: _clock(),
    );
    _wifiBatchCoordinator.replace(stopping);
    _state = _state.copyWith(
      status: RecordingCardControllerStatus.cancellingTransfer,
      lastErrorCode: null,
    );
    notifyListeners();
    _batchCancelRequested = true;
    try {
      final stopPersistenceFailure = await _persistWifiBatchDurably(stopping);
      if (!ownsBatch()) return;
      if (stopPersistenceFailure != null) {
        _wifiBatchCoordinator.replace(
          stopping.copyWith(
            state: RecordingCardWifiBatchState.paused,
            operationPhase: RecordingCardWifiOperationPhase.idle,
            failureCode: stopPersistenceFailure.code,
            updatedAt: _clock(),
          ),
        );
        settlePreflightOwnership();
        _fail(stopPersistenceFailure);
        return;
      }

      final ledgerFailure = await _reconcileRestoredWifiLedger(
        initialBatch.batchId,
      );
      if (!ownsBatch()) return;
      final reconciled = _wifiBatchCoordinator.snapshot ?? stopping;
      final willCancelActiveBluetooth = ownsCapturedActiveBluetooth();
      final cancelled = reconciled.copyWith(
        state: RecordingCardWifiBatchState.cancelled,
        operationPhase: willCancelActiveBluetooth
            ? RecordingCardWifiOperationPhase.stopping
            : RecordingCardWifiOperationPhase.idle,
        stopRequested: true,
        items: reconciled.items
            .map(
              (item) => item.isCompleted
                  ? item
                  : item.copyWith(
                      state: RecordingCardWifiBatchItemState.cancelled,
                      clearStagedDownload: true,
                    ),
            )
            .toList(growable: false),
        clearFailure: true,
        clearCurrentItem: true,
        receivedBytes: 0,
        clearRate: true,
        updatedAt: _clock(),
      );
      final persistenceFailure = ledgerFailure == null
          ? await _persistWifiBatchDurably(cancelled)
          : ledgerFailure;
      if (!ownsBatch()) return;
      if (persistenceFailure != null) {
        _wifiBatchCoordinator.replace(
          stopping.copyWith(
            state: RecordingCardWifiBatchState.paused,
            operationPhase: RecordingCardWifiOperationPhase.idle,
            failureCode: persistenceFailure.code,
            updatedAt: _clock(),
          ),
        );
        settlePreflightOwnership();
        _fail(persistenceFailure);
        return;
      }

      if (willCancelActiveBluetooth && !ownsCapturedActiveBluetooth()) {
        final settled = cancelled.copyWith(
          operationPhase: RecordingCardWifiOperationPhase.idle,
          updatedAt: _clock(),
        );
        final settlementFailure = await _persistWifiBatchDurably(settled);
        if (!ownsBatch()) return;
        _wifiBatchCoordinator.replace(settled);
        settlePreflightOwnership();
        _state = _state.copyWith(
          status: settlementFailure == null
              ? RecordingCardControllerStatus.idle
              : RecordingCardControllerStatus.error,
          clearActiveFileKey: true,
          lastErrorCode: settlementFailure?.code,
        );
        notifyListeners();
        return;
      }

      AppFailure? nativeCancellationFailure;
      final cancelOwnedBluetooth =
          willCancelActiveBluetooth && ownsCapturedActiveBluetooth();
      if (cancelOwnedBluetooth &&
          operationLease != null &&
          _operationMachine.requestCancellation(operationLease)) {
        _publishOperationState();
      }
      final port = _port;
      if (cancelOwnedBluetooth &&
          ownsCapturedActiveBluetooth() &&
          port is RecordingCardCancelableTransferPort) {
        try {
          final result = await (port as RecordingCardCancelableTransferPort)
              .cancelFileTransfer();
          if (!result.ok || result.value != true) {
            nativeCancellationFailure =
                result.error ??
                _fallbackFailure('RECORDING_CARD_TRANSFER_CANCEL_FAILED');
          }
        } on Object catch (error) {
          nativeCancellationFailure = recordingCardFailure(
            'RECORDING_CARD_TRANSFER_CANCEL_FAILED',
            'Recording-card Bluetooth cancellation failed',
            cause: error,
            isRetryable: true,
          );
        }
      }
      if (!ownsBatch()) return;
      _wifiBatchCoordinator.replace(cancelled);
      settlePreflightOwnership();
      if (cancelOwnedBluetooth && activeResume != null) {
        _settleCancelledBluetoothHandoffAfterResume(
          activeResume,
          batchId: initialBatch.batchId,
          attemptId: initialBatch.attemptId,
          stateGeneration: stateGeneration,
        );
      }
      _state = _state.copyWith(
        status: nativeCancellationFailure != null
            ? RecordingCardControllerStatus.error
            : cancelOwnedBluetooth
            ? RecordingCardControllerStatus.cancellingTransfer
            : RecordingCardControllerStatus.idle,
        clearActiveFileKey: true,
        lastErrorCode: nativeCancellationFailure?.code,
      );
      notifyListeners();
    } finally {
      settlePreflightOwnership();
      _batchCancelRequested = false;
    }
  }

  void _reconcileAfterCancelledBluetoothPreflight(
    Future<RecordingCardResult<RecordingCardBluetoothBatchResult>> resume, {
    required int deviceOperation,
  }) {
    unawaited(
      _reconcileAfterCancelledBluetoothPreflightOwned(
        resume,
        deviceOperation: deviceOperation,
      ),
    );
  }

  Future<void> _reconcileAfterCancelledBluetoothPreflightOwned(
    Future<RecordingCardResult<RecordingCardBluetoothBatchResult>> resume, {
    required int deviceOperation,
  }) async {
    try {
      await resume;
    } on Object {
      // A thrown stale continuation still requires native-state reconciliation.
    }
    if (_disposed ||
        deviceOperation != _deviceDiscoveryOperation ||
        _hasRunningTransfer ||
        _operationMachine.state.isActive) {
      return;
    }
    try {
      await reconcileConnectionState(refreshDirectory: false);
    } on Object {
      // The next lifecycle reconciliation will retry the read-only adoption.
    }
  }

  void _settleCancelledBluetoothHandoffAfterResume(
    Future<RecordingCardResult<RecordingCardBluetoothBatchResult>> resume, {
    required String batchId,
    required String? attemptId,
    required int stateGeneration,
  }) {
    unawaited(
      _settleCancelledBluetoothHandoffAfterResumeOwned(
        resume,
        batchId: batchId,
        attemptId: attemptId,
        stateGeneration: stateGeneration,
      ),
    );
  }

  Future<void> _settleCancelledBluetoothHandoffAfterResumeOwned(
    Future<RecordingCardResult<RecordingCardBluetoothBatchResult>> resume, {
    required String batchId,
    required String? attemptId,
    required int stateGeneration,
  }) async {
    try {
      await resume;
    } on Object {
      // Terminal projection must settle even when a stale transfer throws.
    }
    if (_disposed ||
        _transferInFlight ||
        stateGeneration != _wifiBatchStateGeneration) {
      return;
    }
    final current = _wifiBatchCoordinator.snapshot;
    if (current == null ||
        current.batchId != batchId ||
        current.attemptId != attemptId ||
        !current.stopRequested ||
        current.state != RecordingCardWifiBatchState.cancelled ||
        current.operationPhase != RecordingCardWifiOperationPhase.stopping) {
      return;
    }
    final settled = current.copyWith(
      operationPhase: RecordingCardWifiOperationPhase.idle,
      updatedAt: _clock(),
    );
    final persistenceFailure = await _persistWifiBatchDurably(settled);
    if (_disposed ||
        _transferInFlight ||
        stateGeneration != _wifiBatchStateGeneration) {
      return;
    }
    final latest = _wifiBatchCoordinator.snapshot;
    if (latest?.batchId != batchId ||
        latest?.attemptId != attemptId ||
        latest?.stopRequested != true ||
        latest?.operationPhase != RecordingCardWifiOperationPhase.stopping) {
      return;
    }
    _wifiBatchCoordinator.replace(settled);
    _state = _state.copyWith(
      status: persistenceFailure == null
          ? RecordingCardControllerStatus.idle
          : RecordingCardControllerStatus.error,
      clearActiveFileKey: true,
      lastErrorCode: persistenceFailure?.code,
    );
    notifyListeners();
  }

  Future<void> restoreWifiBatch() {
    final running = _wifiBatchRestoreInFlight;
    if (running != null) return running;
    final stateGeneration = ++_wifiBatchStateGeneration;
    late final Future<void> operation;
    operation = _restoreWifiBatch(stateGeneration)
        .catchError((Object error) {
          if (_disposed || stateGeneration != _wifiBatchStateGeneration) return;
          final failure = recordingCardFailure(
            'RECORDING_CARD_WIFI_RECOVERY_FAILED',
            'Wi-Fi recovery could not read or reconcile checkpoints',
            cause: error,
            isRetryable: true,
          );
          final batch = _wifiBatchCoordinator.snapshot;
          if (batch != null) {
            _wifiBatchCoordinator.replace(
              _pausedWifiBatchSnapshot(batch, failureCode: failure.code),
            );
          }
          _releaseTransferLatch(_transferLatchGeneration);
          _fail(failure);
        })
        .whenComplete(() {
          if (identical(_wifiBatchRestoreInFlight, operation)) {
            _wifiBatchRestoreInFlight = null;
            _schedulePendingBluetoothResume();
          }
        });
    _wifiBatchRestoreInFlight = operation;
    return operation;
  }

  Future<void> _restoreWifiBatch(int stateGeneration) async {
    final rows = _localRecordingRepository.recordingCardWifiBatchItems();
    final restored = _wifiBatchFromRecords(rows);
    if (restored == null) {
      _wifiBatchReconnectFingerprint = null;
      return;
    }
    if (restored.recoveryBlocked) {
      _wifiBatchCoordinator.replace(restored);
      if (!restored.stopRequested) {
        _fail(_fallbackFailure(restored.failureCode!));
      }
      return;
    }
    final latchGeneration = _claimTransferLatch();
    final restoring = restored.copyWith(
      state: RecordingCardWifiBatchState.paused,
      updatedAt: _clock(),
      clearCurrentItem: true,
      receivedBytes: 0,
      clearRate: true,
    );
    _wifiBatchCoordinator.replace(restoring);
    bool ownsRestore() =>
        !_disposed &&
        stateGeneration == _wifiBatchStateGeneration &&
        _wifiBatchCoordinator.snapshot?.batchId == restored.batchId;
    var failure = await _refreshVerifiedDownloadCache();
    var current = _wifiBatchCoordinator.snapshot;
    if (failure == null &&
        current != null &&
        _syncLedgerPersistence != null &&
        _persistedWifiBatchCardSnDigest(current) == null) {
      final repair = await _repairLegacyWifiBatchIdentity(
        current,
        allowReconnect: false,
        ownsRepair: () {
          final latest = _wifiBatchCoordinator.snapshot;
          return !_disposed &&
              stateGeneration == _wifiBatchStateGeneration &&
              latest != null &&
              latest.batchId == restored.batchId;
        },
      );
      if (repair.ok && repair.value != null) {
        current = repair.value;
      } else {
        failure = repair.error;
      }
    }
    if (!ownsRestore()) {
      _releaseTransferLatch(latchGeneration);
      return;
    }
    failure ??= await _reconcileRestoredWifiLedger(restored.batchId);
    if (!ownsRestore()) {
      _releaseTransferLatch(latchGeneration);
      return;
    }
    if (failure == null) {
      failure = await _registerStagedWifiBatchFilesOnce();
      if (!ownsRestore()) {
        _releaseTransferLatch(latchGeneration);
        return;
      }
    }
    if (failure == null) {
      failure = await _recoverPlannedWifiDownloads(restored.batchId);
      if (!ownsRestore()) {
        _releaseTransferLatch(latchGeneration);
        return;
      }
      final registrationFailure = await _registerStagedWifiBatchFilesOnce();
      failure = registrationFailure ?? failure;
    }
    current = _wifiBatchCoordinator.snapshot;
    if (!ownsRestore() || current == null) {
      _releaseTransferLatch(latchGeneration);
      return;
    }
    final teardownFailure = await _closeNativeWifiSession(
      current.batchId,
      attemptId: current.attemptId,
    );
    failure ??= teardownFailure;
    current = _wifiBatchCoordinator.snapshot;
    if (!ownsRestore() || current == null) {
      _releaseTransferLatch(latchGeneration);
      return;
    }
    if (current.stopRequested) {
      current = current.copyWith(
        items: current.items
            .map(
              (item) => item.isCompleted || item.stagedDownload != null
                  ? item
                  : item.copyWith(
                      state: RecordingCardWifiBatchItemState.cancelled,
                    ),
            )
            .toList(growable: false),
      );
      _wifiBatchCoordinator.replace(current);
    }
    final allItemsCompleted = current.items.every((item) => item.isCompleted);
    final handedOffToBluetooth =
        failure == null && !allItemsCompleted && !current.stopRequested;
    if (handedOffToBluetooth) {
      current = current.copyWith(
        items: current.items
            .map(
              (item) => item.isCompleted
                  ? item
                  : item.copyWith(
                      state: RecordingCardWifiBatchItemState.cancelled,
                      clearError: true,
                      clearStagedDownload: true,
                    ),
            )
            .toList(growable: false),
      );
      _wifiBatchCoordinator.replace(current);
    }
    final nextState = switch (restored.state) {
      _ when failure != null => RecordingCardWifiBatchState.paused,
      _ when allItemsCompleted => RecordingCardWifiBatchState.reconciling,
      _ when current.stopRequested => RecordingCardWifiBatchState.cancelled,
      _ when handedOffToBluetooth => RecordingCardWifiBatchState.cancelled,
      RecordingCardWifiBatchState.cancelled =>
        RecordingCardWifiBatchState.cancelled,
      RecordingCardWifiBatchState.failed => RecordingCardWifiBatchState.failed,
      _ => RecordingCardWifiBatchState.paused,
    };
    final restoredFailureCode =
        failure?.code ??
        (handedOffToBluetooth
            ? recordingCardWifiBluetoothHandoffFailureCode
            : current.failureCode ??
                  current.items
                      .where((item) => item.errorCode != null)
                      .map((item) => item.errorCode)
                      .firstOrNull);
    final settled = current.copyWith(
      state: nextState,
      failureCode:
          nextState == RecordingCardWifiBatchState.paused ||
              nextState == RecordingCardWifiBatchState.failed ||
              handedOffToBluetooth
          ? restoredFailureCode
          : null,
      clearFailure:
          nextState != RecordingCardWifiBatchState.paused &&
          nextState != RecordingCardWifiBatchState.failed &&
          !handedOffToBluetooth,
      updatedAt: _clock(),
      clearCurrentItem: true,
      receivedBytes: 0,
      clearRate: true,
    );
    if (nextState == RecordingCardWifiBatchState.reconciling) {
      _wifiBatchCoordinator.replace(settled);
      await _completeWifiBatchReconciliation(settled);
      return;
    }
    final persistenceFailure = await _persistWifiBatchDurably(settled);
    if (stateGeneration != _wifiBatchStateGeneration || _disposed) {
      _releaseTransferLatch(latchGeneration);
      return;
    }
    final effectiveFailure = persistenceFailure ?? failure;
    final visible = persistenceFailure == null
        ? settled
        : _pausedWifiBatchSnapshot(
            current,
            failureCode: persistenceFailure.code,
          );
    _wifiBatchCoordinator.replace(visible);
    _state = _state.copyWith(
      status: effectiveFailure == null
          ? RecordingCardControllerStatus.idle
          : RecordingCardControllerStatus.error,
      clearActiveFileKey: true,
      lastErrorCode: effectiveFailure?.code,
    );
    notifyListeners();
    if (handedOffToBluetooth &&
        persistenceFailure == null &&
        pendingUserBluetoothResumeEntries.isNotEmpty) {
      final activeLease = _activeTransferOperationLease;
      if (activeLease != null && _operationMachine.owns(activeLease)) {
        final admission = _operationMachine.supersede(
          kind: RecordingCardOperationKind.bluetoothTransfer,
          origin: RecordingCardOperationOrigin.automatic,
          connectionRevision: _connectionRevision,
        );
        final bluetoothLease = admission.lease;
        if (bluetoothLease != null) {
          _activeTransferOperationLease = bluetoothLease;
          _pendingBluetoothResumeOperationLease = bluetoothLease;
          _pendingBluetoothResumeLatchGeneration = latchGeneration;
          _pendingBluetoothResumePreflight = true;
          _pendingBluetoothRecoveryAttemptKey =
              'wifi-handoff:${settled.batchId}';
          _state = _state.copyWith(operation: admission.state);
          notifyListeners();
          return;
        }
      }
    }
    _releaseTransferLatch(latchGeneration);
  }

  Future<bool> dismissWifiBatch() {
    final running = _wifiBatchDismissInFlight;
    if (running != null) return running;
    late final Future<bool> operation;
    operation = _dismissWifiBatchDurably().whenComplete(() {
      if (identical(_wifiBatchDismissInFlight, operation)) {
        _wifiBatchDismissInFlight = null;
      }
    });
    _wifiBatchDismissInFlight = operation;
    return operation;
  }

  Future<bool> _dismissWifiBatchDurably() async {
    final batch = _wifiBatchCoordinator.snapshot;
    if (batch == null ||
        _transferInFlight ||
        _wifiBleRecoveryInFlight ||
        _batchRunInFlight != null ||
        _wifiBatchRestoreInFlight != null ||
        _wifiBatchReprepareInFlight != null ||
        _stagedBatchRegistrationInFlight != null ||
        _wifiBatchPersistenceFailureBatchId == batch.batchId ||
        _wifiBatchLedgerFailureBatchId == batch.batchId ||
        _wifiBatchTeardownPendingBatchId == batch.batchId ||
        !batch.isTerminal ||
        _wifiBluetoothHandoffHasUnsettledTargets(batch) ||
        batch.items.any((item) => item.stagedDownload != null)) {
      return false;
    }
    _localRecordingRepository.deleteRecordingCardWifiBatch(batch.batchId);
    final flushed = await _localRecordingRepository
        .flushRecordingCardPersistence();
    if (!flushed.ok) {
      _fail(
        recordingCardFailure(
          'RECORDING_CARD_WIFI_BATCH_DISMISS_FAILED',
          'Recording-card Wi-Fi batch dismissal was not durable',
          cause: flushed.error,
          isRetryable: true,
        ),
      );
      return false;
    }
    if (!identical(_wifiBatchCoordinator.snapshot, batch)) return false;
    if (_wifiBatchPersistenceFailureBatchId == batch.batchId) {
      _wifiBatchPersistenceFailureBatchId = null;
    }
    if (_wifiBatchLedgerFailureBatchId == batch.batchId) {
      _wifiBatchLedgerFailureBatchId = null;
    }
    _wifiBatchReconnectFingerprint = null;
    _wifiBatchCoordinator.dismiss();
    return true;
  }

  Future<RecordingCardResult<RecordingCardWifiCredentials>>
  _prepareWifiBatchSession(
    RecordingCardWifiSessionPort port,
    RecordingCardWifiBatchSnapshot batch,
    List<RecordingCardScannedFile> files,
  ) async {
    final preparationLatchGeneration = _transferInFlight
        ? _transferLatchGeneration
        : null;
    if (!identical(_wifiBatchCoordinator.snapshot, batch)) {
      return RecordingCardResult<RecordingCardWifiCredentials>.failure(
        _fallbackFailure('RECORDING_CARD_WIFI_PREPARATION_STALE'),
      );
    }
    batch = batch.copyWith(
      operationPhase: _wifiFlowInFlight != null
          ? RecordingCardWifiOperationPhase.preparingHotspot
          : RecordingCardWifiOperationPhase.idle,
    );
    final preparationTeardownKey = (
      batchId: batch.batchId,
      attemptId: batch.attemptId,
    );
    _wifiNativeTeardownSettledKeys.remove(preparationTeardownKey);
    _wifiBatchCoordinator.replace(batch);
    final preparationGeneration = ++_wifiPreparationGeneration;
    final preparationBatchId = batch.batchId;
    final preparationAttemptId = batch.attemptId;
    RecordingCardWifiBatchSnapshot? ownedPreparationBatch() {
      final current = _wifiBatchCoordinator.snapshot;
      if (_disposed ||
          preparationGeneration != _wifiPreparationGeneration ||
          current == null ||
          current.batchId != preparationBatchId ||
          current.attemptId != preparationAttemptId ||
          current.stopRequested ||
          _batchPauseRequested ||
          _batchCancelRequested) {
        return null;
      }
      return current;
    }

    _state = _state.copyWith(
      status: RecordingCardControllerStatus.preparingWifi,
      lastErrorCode: null,
    );
    notifyListeners();
    late final RecordingCardResult<RecordingCardWifiCredentials> result;
    try {
      final recoveryPort = _port;
      if (batch.attemptId != null &&
          recoveryPort is RecordingCardWifiRecoveryPort) {
        final begun = await (recoveryPort as RecordingCardWifiRecoveryPort)
            .beginWifiAttempt(
              batchId: batch.batchId,
              attemptId: batch.attemptId!,
            )
            .timeout(_wifiSetupTimeout);
        if (!begun.ok) {
          throw begun.error ??
              _fallbackFailure('RECORDING_CARD_WIFI_RECOVERY_FAILED');
        }
        if (ownedPreparationBatch() == null) {
          return RecordingCardResult.failure(
            _fallbackFailure('RECORDING_CARD_WIFI_PREPARATION_STALE'),
          );
        }
      }
      result = await port.prepareWifiSession(files).timeout(_wifiSetupTimeout);
    } on TimeoutException catch (error) {
      result = RecordingCardResult<RecordingCardWifiCredentials>.failure(
        recordingCardFailure(
          'RECORDING_CARD_WIFI_PREPARE_TIMEOUT',
          'Recording-card Wi-Fi preparation timed out',
          cause: error,
          isRetryable: true,
        ),
      );
    } catch (error) {
      result = RecordingCardResult<RecordingCardWifiCredentials>.failure(
        recordingCardFailure(
          'RECORDING_CARD_WIFI_PREPARE_FAILED',
          'Recording-card Wi-Fi preparation threw unexpectedly',
          cause: error,
          isRetryable: true,
        ),
      );
    }
    final preparedBatch = ownedPreparationBatch();
    if (preparedBatch == null) {
      return RecordingCardResult<RecordingCardWifiCredentials>.failure(
        _fallbackFailure('RECORDING_CARD_WIFI_PREPARATION_STALE'),
      );
    }
    if (!result.ok || result.value == null) {
      final failure =
          result.error ??
          _fallbackFailure('RECORDING_CARD_WIFI_PREPARE_FAILED');
      final teardownFailure = await _cancelNativeWifiTransfer(
        batch.batchId,
        attemptId: batch.attemptId,
      );
      final settlementBatch = ownedPreparationBatch();
      if (settlementBatch == null) {
        return RecordingCardResult<RecordingCardWifiCredentials>.failure(
          _fallbackFailure('RECORDING_CARD_WIFI_PREPARATION_STALE'),
        );
      }
      final transitionFailure = teardownFailure ?? failure;
      final needsBleRecovery =
          _wifiBatchTeardownPendingBatchId != batch.batchId;
      var paused = _pausedWifiBatchSnapshot(
        settlementBatch,
        failureCode: transitionFailure.code,
        willRecoverBle: needsBleRecovery,
      );
      final persistenceFailure = await _persistWifiBatchDurably(paused);
      if (ownedPreparationBatch() == null) {
        return RecordingCardResult<RecordingCardWifiCredentials>.failure(
          _fallbackFailure('RECORDING_CARD_WIFI_PREPARATION_STALE'),
        );
      }
      final effectiveFailure = persistenceFailure ?? transitionFailure;
      if (persistenceFailure != null) {
        paused = _pausedWifiBatchSnapshot(
          settlementBatch,
          failureCode: persistenceFailure.code,
          willRecoverBle: needsBleRecovery,
        );
      }
      _wifiBatchCoordinator.replace(paused);
      _fail(effectiveFailure);
      if (needsBleRecovery) {
        await _recoverBleAfterWifiBatch(paused);
      } else if (preparationLatchGeneration != null) {
        _releaseTransferLatch(preparationLatchGeneration);
      }
      return RecordingCardResult<RecordingCardWifiCredentials>.failure(
        effectiveFailure,
      );
    }
    _markWifiHandoffBleUnavailable();
    final awaiting = preparedBatch.copyWith(
      state: RecordingCardWifiBatchState.awaitingHotspot,
      clearFailure: true,
      updatedAt: _clock(),
      clearCurrentItem: true,
      receivedBytes: 0,
      clearRate: true,
    );
    final persistenceFailure = await _persistWifiBatchDurably(awaiting);
    if (ownedPreparationBatch() == null) {
      return RecordingCardResult<RecordingCardWifiCredentials>.failure(
        _fallbackFailure('RECORDING_CARD_WIFI_PREPARATION_STALE'),
      );
    }
    if (persistenceFailure != null) {
      await _pauseWifiBatch(persistenceFailure);
      return RecordingCardResult<RecordingCardWifiCredentials>.failure(
        persistenceFailure,
      );
    }
    _wifiBatchCoordinator.replace(awaiting);
    _state = _state.copyWith(
      status: RecordingCardControllerStatus.idle,
      clearActiveFileKey: true,
      lastErrorCode: null,
    );
    notifyListeners();
    return result;
  }

  Future<RecordingCardResult<RecordingCardWifiCredentials>>
  _reprepareWifiBatch({required bool failedOnly}) async {
    final restoring = _wifiBatchRestoreInFlight;
    if (restoring != null) await restoring;
    var current = _wifiBatchCoordinator.snapshot;
    final port = _port;
    if (current == null ||
        port is! RecordingCardWifiSessionPort ||
        _batchStopRequested ||
        _wifiBatchCancelInFlight != null ||
        _wifiBatchPauseInFlight != null) {
      return RecordingCardResult<RecordingCardWifiCredentials>.failure(
        _fallbackFailure('RECORDING_CARD_WIFI_BATCH_NOT_RECOVERABLE'),
      );
    }
    final stateGeneration = _wifiBatchStateGeneration;
    final batchId = current.batchId;
    int? latchGeneration = _transferInFlight ? _transferLatchGeneration : null;
    bool ownsReprepare() {
      final latest = _wifiBatchCoordinator.snapshot;
      return !_disposed &&
          stateGeneration == _wifiBatchStateGeneration &&
          !_batchStopRequested &&
          _wifiBatchCancelInFlight == null &&
          _wifiBatchPauseInFlight == null &&
          latest != null &&
          latest.batchId == batchId &&
          latest.state != RecordingCardWifiBatchState.cancelled;
    }

    RecordingCardResult<RecordingCardWifiCredentials> superseded() {
      if (latchGeneration != null &&
          !_batchStopRequested &&
          _wifiBatchCancelInFlight == null &&
          _wifiBatchPauseInFlight == null) {
        _releaseTransferLatch(latchGeneration);
      }
      return RecordingCardResult<RecordingCardWifiCredentials>.failure(
        _fallbackFailure('RECORDING_CARD_WIFI_BATCH_SUPERSEDED'),
      );
    }

    final wifiPort = port as RecordingCardWifiSessionPort;
    if (current.state == RecordingCardWifiBatchState.cancelled) {
      return RecordingCardResult<RecordingCardWifiCredentials>.failure(
        _fallbackFailure('RECORDING_CARD_WIFI_BATCH_CANCELLED'),
      );
    }
    final recoverableState = failedOnly
        ? current.state == RecordingCardWifiBatchState.completed ||
              current.state == RecordingCardWifiBatchState.failed
        : current.state == RecordingCardWifiBatchState.paused ||
              current.state == RecordingCardWifiBatchState.queued ||
              current.state == RecordingCardWifiBatchState.awaitingHotspot;
    if (!recoverableState) {
      return RecordingCardResult<RecordingCardWifiCredentials>.failure(
        _fallbackFailure('RECORDING_CARD_WIFI_BATCH_NOT_RECOVERABLE'),
      );
    }
    if (_wifiBatchTeardownPendingBatchId == current.batchId) {
      latchGeneration ??= _claimWifiTransitionLatch();
      if (latchGeneration == null) {
        return RecordingCardResult<RecordingCardWifiCredentials>.failure(
          _operationAdmissionFailure(),
        );
      }
      final pendingKey = _wifiNativeTeardownPendingKey;
      final teardownFailure = await _closeNativeWifiSession(
        current.batchId,
        attemptId: pendingKey?.batchId == current.batchId
            ? pendingKey?.attemptId
            : current.attemptId,
      );
      if (!ownsReprepare()) return superseded();
      if (teardownFailure != null) {
        var paused = _pausedWifiBatchSnapshot(
          current,
          failureCode: teardownFailure.code,
        );
        final persistenceFailure = await _persistWifiBatchDurably(paused);
        if (!ownsReprepare()) return superseded();
        final failure = persistenceFailure ?? teardownFailure;
        if (persistenceFailure != null) {
          paused = _pausedWifiBatchSnapshot(
            paused,
            failureCode: persistenceFailure.code,
          );
        }
        _wifiBatchCoordinator.replace(paused);
        _fail(failure);
        _releaseTransferLatch(latchGeneration);
        return RecordingCardResult<RecordingCardWifiCredentials>.failure(
          failure,
        );
      }
    }
    if (_syncLedgerPersistence != null &&
        _persistedWifiBatchCardSnDigest(current) == null) {
      latchGeneration ??= _claimTransferLatch();
      final repair = await _repairLegacyWifiBatchIdentity(
        current,
        allowReconnect: true,
        ownsRepair: ownsReprepare,
      );
      if (!ownsReprepare()) return superseded();
      if (!repair.ok || repair.value == null) {
        final repairFailure =
            repair.error ??
            _fallbackFailure(
              'RECORDING_CARD_WIFI_BATCH_IDENTITY_RECOVERY_REQUIRED',
            );
        var paused = _pausedWifiBatchSnapshot(
          current,
          failureCode: repairFailure.code,
        );
        final persistenceFailure = await _persistWifiBatchDurably(paused);
        if (!ownsReprepare()) return superseded();
        final failure = persistenceFailure ?? repairFailure;
        if (persistenceFailure != null) {
          paused = _pausedWifiBatchSnapshot(
            paused,
            failureCode: persistenceFailure.code,
          );
        }
        _wifiBatchCoordinator.replace(paused);
        _releaseTransferLatch(latchGeneration);
        _fail(failure);
        return RecordingCardResult<RecordingCardWifiCredentials>.failure(
          failure,
        );
      }
      current = repair.value!;
    }
    final reconciliationFailure = await _reconcileRestoredWifiLedger(
      current.batchId,
    );
    if (!ownsReprepare()) return superseded();
    current = _wifiBatchCoordinator.snapshot ?? current;
    if (reconciliationFailure != null) {
      final paused = _pausedWifiBatchSnapshot(
        current,
        failureCode: reconciliationFailure.code,
      );
      final persistenceFailure = await _persistWifiBatchDurably(paused);
      if (!ownsReprepare()) return superseded();
      final failure = persistenceFailure ?? reconciliationFailure;
      _wifiBatchCoordinator.replace(
        persistenceFailure == null
            ? paused
            : _pausedWifiBatchSnapshot(
                paused,
                failureCode: persistenceFailure.code,
              ),
      );
      _fail(failure);
      if (latchGeneration != null) _releaseTransferLatch(latchGeneration);
      return RecordingCardResult<RecordingCardWifiCredentials>.failure(failure);
    }
    final recoveryState = current.state;
    if (current.items.any((item) => item.stagedDownload != null)) {
      latchGeneration = _claimTransferLatch();
      final registrationFailure = await _registerStagedWifiBatchFilesOnce();
      if (!ownsReprepare()) return superseded();
      final registered = _wifiBatchCoordinator.snapshot;
      if (registered == null || registered.batchId != current.batchId) {
        _releaseTransferLatch(latchGeneration);
        return RecordingCardResult<RecordingCardWifiCredentials>.failure(
          _fallbackFailure('RECORDING_CARD_WIFI_BATCH_NOT_RECOVERABLE'),
        );
      }
      if (registrationFailure != null) {
        var paused = _pausedWifiBatchSnapshot(
          registered,
          failureCode: registrationFailure.code,
        );
        _wifiBatchCoordinator.replace(paused);
        final ledgerFailure = await _reconcileRestoredWifiLedger(
          paused.batchId,
        );
        if (!ownsReprepare()) return superseded();
        paused = _wifiBatchCoordinator.snapshot ?? paused;
        final persistenceFailure = await _persistWifiBatchDurably(paused);
        if (!ownsReprepare()) return superseded();
        final failure =
            persistenceFailure ?? ledgerFailure ?? registrationFailure;
        if (persistenceFailure != null) {
          paused = _pausedWifiBatchSnapshot(
            paused,
            failureCode: persistenceFailure.code,
          );
          _wifiBatchCoordinator.replace(paused);
        }
        _releaseTransferLatch(latchGeneration);
        _fail(failure);
        return RecordingCardResult<RecordingCardWifiCredentials>.failure(
          failure,
        );
      }
      current = registered.copyWith(
        state: recoveryState,
        updatedAt: _clock(),
        clearCurrentItem: true,
        receivedBytes: 0,
        clearRate: true,
      );
      final persistenceFailure = await _persistWifiBatchDurably(current);
      if (!ownsReprepare()) return superseded();
      if (persistenceFailure != null) {
        final paused = _pausedWifiBatchSnapshot(
          registered,
          failureCode: persistenceFailure.code,
        );
        _wifiBatchCoordinator.replace(paused);
        _releaseTransferLatch(latchGeneration);
        _fail(persistenceFailure);
        return RecordingCardResult<RecordingCardWifiCredentials>.failure(
          persistenceFailure,
        );
      }
      _wifiBatchCoordinator.replace(current);
    }
    final items = current.items
        .map((item) {
          final retry = failedOnly
              ? item.state == RecordingCardWifiBatchItemState.failed
              : item.state != RecordingCardWifiBatchItemState.completed &&
                    item.state != RecordingCardWifiBatchItemState.skipped &&
                    item.state != RecordingCardWifiBatchItemState.cancelled;
          return retry
              ? item.copyWith(
                  state: RecordingCardWifiBatchItemState.queued,
                  clearError: true,
                )
              : item;
        })
        .toList(growable: false);
    final pending = items
        .where((item) => item.state == RecordingCardWifiBatchItemState.queued)
        .map((item) => item.file)
        .toList(growable: false);
    if (pending.isEmpty) {
      if (items.every((item) => item.isCompleted)) {
        final reconciled = current.copyWith(items: items);
        _wifiBatchCoordinator.replace(reconciled);
        final failure = await _completeWifiBatchReconciliation(reconciled);
        if (failure != null) {
          return RecordingCardResult<RecordingCardWifiCredentials>.failure(
            failure,
          );
        }
      }
      return RecordingCardResult<RecordingCardWifiCredentials>.failure(
        _fallbackFailure('RECORDING_CARD_WIFI_BATCH_ALREADY_SYNCED'),
      );
    }
    latchGeneration ??= _claimTransferLatch();
    final reconnected = await _ensureWifiBatchBleConnection(
      current,
      ownsRecovery: ownsReprepare,
    );
    if (!ownsReprepare()) return superseded();
    if (!reconnected.ok || reconnected.value == null) {
      final failure =
          reconnected.error ??
          _fallbackFailure('RECORDING_CARD_WIFI_BLE_RECONNECT_FAILED');
      final paused = _pausedWifiBatchSnapshot(
        current,
        failureCode: failure.code,
      );
      final persistenceFailure = await _persistWifiBatchDurably(paused);
      if (!ownsReprepare()) return superseded();
      final effectiveFailure = persistenceFailure ?? failure;
      _wifiBatchCoordinator.replace(
        persistenceFailure == null
            ? paused
            : _pausedWifiBatchSnapshot(
                paused,
                failureCode: persistenceFailure.code,
              ),
      );
      _releaseTransferLatch(latchGeneration);
      _fail(effectiveFailure);
      return RecordingCardResult<RecordingCardWifiCredentials>.failure(
        effectiveFailure,
      );
    }
    final latest = _wifiBatchCoordinator.snapshot;
    if (latest == null ||
        latest.batchId != current.batchId ||
        latest.state != current.state) {
      _releaseTransferLatch(latchGeneration);
      return RecordingCardResult<RecordingCardWifiCredentials>.failure(
        _fallbackFailure('RECORDING_CARD_WIFI_BATCH_NOT_RECOVERABLE'),
      );
    }
    _wifiBatchReconnectFingerprint = current.deviceFingerprint;
    final queued = current.copyWith(
      state: RecordingCardWifiBatchState.queued,
      items: items,
      clearFailure: true,
      updatedAt: _clock(),
      clearCurrentItem: true,
      receivedBytes: 0,
      clearRate: true,
    );
    final persistenceFailure = await _persistWifiBatchDurably(queued);
    if (!ownsReprepare()) return superseded();
    if (persistenceFailure != null) {
      _wifiBatchCoordinator.replace(
        _pausedWifiBatchSnapshot(current, failureCode: persistenceFailure.code),
      );
      _releaseTransferLatch(latchGeneration);
      _fail(persistenceFailure);
      return RecordingCardResult<RecordingCardWifiCredentials>.failure(
        persistenceFailure,
      );
    }
    _wifiBatchCoordinator.replace(queued);
    final prepared = await _prepareWifiBatchSession(wifiPort, queued, pending);
    if (!ownsReprepare()) return superseded();
    return prepared;
  }

  Future<RecordingCardResult<RecordingCardDeviceState>>
  _ensureWifiBatchBleConnection(
    RecordingCardWifiBatchSnapshot batch, {
    bool forceTransportReset = false,
    bool Function()? ownsRecovery,
  }) async {
    bool stillOwnsRecovery() => ownsRecovery?.call() ?? !_disposed;
    RecordingCardResult<RecordingCardDeviceState> superseded() =>
        RecordingCardResult<RecordingCardDeviceState>.failure(
          _fallbackFailure('RECORDING_CARD_BLUETOOTH_RESUME_SUPERSEDED'),
        );
    if (!stillOwnsRecovery()) return superseded();
    final controllerDevice = _state.snapshot.deviceState;
    final nativeDevice = _port.runtimeSnapshot.deviceState;
    final requiresTransportReset =
        forceTransportReset || _wifiHandoffBleUnavailable;
    final batchFingerprint = _recordingCardReconnectFingerprintValue(
      batch.deviceFingerprint,
    );
    if (batchFingerprint == null) {
      return RecordingCardResult<RecordingCardDeviceState>.failure(
        recordingCardFailure(
          'RECORDING_CARD_WIFI_BLE_RECONNECT_DEVICE_UNAVAILABLE',
          'Recording-card identity is unavailable for Wi-Fi batch recovery',
        ),
      );
    }
    final observedFingerprints = <String?>[
      _recordingCardReconnectFingerprintValue(_wifiBatchReconnectFingerprint),
      _recordingCardReconnectFingerprintValue(
        controllerDevice.safeDeviceFingerprint,
      ),
      _recordingCardReconnectFingerprintValue(
        nativeDevice.safeDeviceFingerprint,
      ),
    ];
    if (observedFingerprints.any(
      (fingerprint) => fingerprint != null && fingerprint != batchFingerprint,
    )) {
      return RecordingCardResult<RecordingCardDeviceState>.failure(
        recordingCardFailure(
          'RECORDING_CARD_WIFI_BATCH_DEVICE_MISMATCH',
          'Cached recording-card identity does not own the persisted Wi-Fi batch',
          isRetryable: true,
        ),
      );
    }
    if (!requiresTransportReset &&
        controllerDevice.isOperationallyConnected &&
        nativeDevice.isOperationallyConnected) {
      if (!_matchesWifiBatchReconnectTarget(controllerDevice, batch) ||
          !_matchesWifiBatchReconnectTarget(nativeDevice, batch)) {
        return RecordingCardResult<RecordingCardDeviceState>.failure(
          recordingCardFailure(
            'RECORDING_CARD_WIFI_BATCH_DEVICE_MISMATCH',
            'Connected recording card does not own the persisted Wi-Fi batch',
            isRetryable: true,
          ),
        );
      }
      return RecordingCardResult<RecordingCardDeviceState>.success(
        controllerDevice,
      );
    }
    if ((controllerDevice.isOperationallyConnected &&
            !_matchesWifiBatchReconnectTarget(controllerDevice, batch)) ||
        (nativeDevice.isOperationallyConnected &&
            !_matchesWifiBatchReconnectTarget(nativeDevice, batch))) {
      return RecordingCardResult<RecordingCardDeviceState>.failure(
        recordingCardFailure(
          'RECORDING_CARD_WIFI_BATCH_DEVICE_MISMATCH',
          'A different recording card is connected',
          isRetryable: true,
        ),
      );
    }
    final safeFingerprint = batchFingerprint;
    if (!stillOwnsRecovery()) return superseded();
    _wifiBatchReconnectFingerprint = safeFingerprint;
    _state = _state.copyWith(
      status: RecordingCardControllerStatus.connecting,
      lastErrorCode: null,
      clearActiveFileKey: true,
    );
    notifyListeners();
    try {
      final bindingToken = await _bindingTokenProvider().timeout(
        _wifiBleRecoveryTimeout,
      );
      if (!stillOwnsRecovery()) return superseded();
      if (!isRecordingCardBindingToken(bindingToken)) {
        return RecordingCardResult<RecordingCardDeviceState>.failure(
          recordingCardFailure(
            'RECORDING_CARD_BINDING_IDENTITY_UNAVAILABLE',
            'Recording-card secure binding identity is unavailable',
          ),
        );
      }
      _beginConnectionAuthorizationAttempt();
      final nativeResult = await _port
          .connect(
            request: RecordingCardConnectRequest(
              safeDeviceFingerprint: safeFingerprint,
              expectedSerialNumber: _recordingCardSerialFromIdentity(
                batch.deviceIdentity,
              ),
              overallTimeoutMs: _wifiBleRecoveryTimeout.inMilliseconds,
              forceScan: requiresTransportReset,
            ).withBindingToken(bindingToken),
          )
          .timeout(_wifiBleRecoveryTimeout);
      if (!stillOwnsRecovery()) return superseded();
      final result = await _authorizeConnectedDeviceResult(
        nativeResult,
        ownsOperation: stillOwnsRecovery,
      ).timeout(_wifiBleRecoveryTimeout);
      if (!stillOwnsRecovery()) return superseded();
      if (!result.ok || result.value?.isOperationallyConnected != true) {
        final failure =
            (result.error ??
                    recordingCardFailure(
                      'RECORDING_CARD_WIFI_BLE_RECONNECT_FAILED',
                      'Recording-card BLE reconnect failed before Wi-Fi recovery',
                    ))
                .copyWith(
                  isRetryable: true,
                  recoveryActions: const <String>['retry'],
                );
        return RecordingCardResult<RecordingCardDeviceState>.failure(failure);
      }
      final connected = result.value!;
      if (!_matchesWifiBatchReconnectTarget(connected, batch)) {
        return RecordingCardResult<RecordingCardDeviceState>.failure(
          recordingCardFailure(
            'RECORDING_CARD_WIFI_BATCH_DEVICE_MISMATCH',
            'Reconnected recording card does not own the persisted Wi-Fi batch',
            isRetryable: true,
          ),
        );
      }
      _wifiHandoffBleUnavailable = false;
      final nativeSnapshot = _port.runtimeSnapshot;
      final previousDevice = _state.snapshot.deviceState;
      if (!stillOwnsRecovery()) return superseded();
      _state = _state.copyWith(
        status: RecordingCardControllerStatus.preparingWifi,
        snapshot: _normalizeRuntimeSnapshot(
          nativeSnapshot.copyWith(deviceState: connected),
        ),
        lastErrorCode: null,
        clearActiveFileKey: true,
      );
      notifyListeners();
      _observeConnectionTransition(previousDevice, connected);
      return RecordingCardResult<RecordingCardDeviceState>.success(connected);
    } on TimeoutException catch (error) {
      if (!stillOwnsRecovery()) return superseded();
      _beginConnectionAuthorizationAttempt();
      return RecordingCardResult<RecordingCardDeviceState>.failure(
        recordingCardFailure(
          'RECORDING_CARD_WIFI_BLE_RECONNECT_TIMEOUT',
          'Recording-card BLE reconnect timed out before Wi-Fi recovery',
          cause: error,
        ),
      );
    } catch (error) {
      if (!stillOwnsRecovery()) return superseded();
      return RecordingCardResult<RecordingCardDeviceState>.failure(
        recordingCardFailure(
          'RECORDING_CARD_WIFI_BLE_RECONNECT_FAILED',
          'Recording-card BLE reconnect failed before Wi-Fi recovery',
          cause: error,
        ),
      );
    }
  }

  Future<RecordingCardResult<RecordingCardWifiBatchSnapshot>>
  _repairLegacyWifiBatchIdentity(
    RecordingCardWifiBatchSnapshot batch, {
    required bool allowReconnect,
    bool Function()? ownsRepair,
  }) async {
    bool stillOwnsRepair() => ownsRepair?.call() ?? !_disposed;
    RecordingCardResult<RecordingCardWifiBatchSnapshot> superseded() =>
        RecordingCardResult<RecordingCardWifiBatchSnapshot>.failure(
          _fallbackFailure('RECORDING_CARD_WIFI_BATCH_SUPERSEDED'),
        );
    if (!stillOwnsRepair()) return superseded();
    if (_persistedWifiBatchCardSnDigest(batch) != null) {
      return RecordingCardResult<RecordingCardWifiBatchSnapshot>.success(batch);
    }
    final owner = _wifiBatchCoordinator.snapshot;
    if (owner == null || owner.batchId != batch.batchId) {
      return RecordingCardResult<RecordingCardWifiBatchSnapshot>.failure(
        _fallbackFailure('RECORDING_CARD_WIFI_BATCH_NOT_RECOVERABLE'),
      );
    }

    RecordingCardDeviceState? connected;
    var serial = normalizeRecordingCardSerialNumberForOwnership(
      _recordingCardSerialFromIdentity(batch.deviceIdentity) ?? '',
    );
    var digest = serial == null
        ? null
        : RecordingCardFileIdentity.digestSerialNumber(serial);
    final nativeDevice = _port.runtimeSnapshot.deviceState;
    if (serial != null && digest != null) {
      // The persisted canonical serial is already sufficient to derive the
      // deterministic digest. Hardware authorization is only needed for old
      // rows that contain no serial identity at all.
    } else if (nativeDevice.isOperationallyConnected) {
      if (!_matchesWifiBatchReconnectTarget(nativeDevice, batch)) {
        return RecordingCardResult<RecordingCardWifiBatchSnapshot>.failure(
          recordingCardFailure(
            'RECORDING_CARD_WIFI_BATCH_DEVICE_MISMATCH',
            'Connected recording card does not own the legacy Wi-Fi batch',
            isRetryable: true,
          ),
        );
      }
      _beginConnectionAuthorizationAttempt();
      try {
        final authorized = await _authorizeConnectedDeviceResult(
          RecordingCardResult<RecordingCardDeviceState>.success(nativeDevice),
          ownsOperation: stillOwnsRepair,
        ).timeout(_wifiBleRecoveryTimeout);
        if (!stillOwnsRepair()) return superseded();
        if (!authorized.ok || authorized.value == null) {
          return RecordingCardResult<RecordingCardWifiBatchSnapshot>.failure(
            authorized.error ??
                _fallbackFailure('RECORDING_CARD_CLOUD_AUTHORIZATION_FAILED'),
          );
        }
        connected = authorized.value;
      } on TimeoutException catch (error) {
        if (!stillOwnsRepair()) return superseded();
        _beginConnectionAuthorizationAttempt();
        return RecordingCardResult<RecordingCardWifiBatchSnapshot>.failure(
          recordingCardFailure(
            'RECORDING_CARD_WIFI_BLE_AUTHORIZATION_TIMEOUT',
            'Legacy Wi-Fi batch ownership authorization timed out',
            cause: error,
            isRetryable: true,
          ),
        );
      } catch (error) {
        if (!stillOwnsRepair()) return superseded();
        return RecordingCardResult<RecordingCardWifiBatchSnapshot>.failure(
          recordingCardFailure(
            'RECORDING_CARD_CLOUD_AUTHORIZATION_FAILED',
            'Legacy Wi-Fi batch ownership authorization failed',
            cause: error,
            isRetryable: true,
          ),
        );
      }
    } else if (allowReconnect) {
      final reconnected = await _ensureWifiBatchBleConnection(
        batch,
        ownsRecovery: stillOwnsRepair,
      );
      if (!stillOwnsRepair()) return superseded();
      if (!reconnected.ok || reconnected.value == null) {
        return RecordingCardResult<RecordingCardWifiBatchSnapshot>.failure(
          reconnected.error ??
              _fallbackFailure('RECORDING_CARD_WIFI_BLE_RECONNECT_FAILED'),
        );
      }
      connected = reconnected.value;
    } else {
      return RecordingCardResult<RecordingCardWifiBatchSnapshot>.failure(
        recordingCardFailure(
          'RECORDING_CARD_WIFI_BATCH_IDENTITY_RECOVERY_REQUIRED',
          'The original recording card is required to migrate this Wi-Fi batch',
          isRetryable: true,
        ),
      );
    }

    final ownedDevice = connected;
    if (ownedDevice == null && (serial == null || digest == null)) {
      return RecordingCardResult<RecordingCardWifiBatchSnapshot>.failure(
        recordingCardFailure(
          'RECORDING_CARD_WIFI_BATCH_IDENTITY_RECOVERY_REQUIRED',
          'Authorized recording card did not expose an owned device',
          isRetryable: true,
        ),
      );
    }
    if (ownedDevice != null &&
        !_matchesWifiBatchReconnectTarget(ownedDevice, batch)) {
      return RecordingCardResult<RecordingCardWifiBatchSnapshot>.failure(
        recordingCardFailure(
          'RECORDING_CARD_WIFI_BATCH_DEVICE_MISMATCH',
          'Authorized recording card does not own the legacy Wi-Fi batch',
          isRetryable: true,
        ),
      );
    }
    serial ??= normalizeRecordingCardSerialNumberForOwnership(
      ownedDevice?.serialNumber ?? '',
    );
    digest ??= serial == null
        ? null
        : RecordingCardFileIdentity.digestSerialNumber(serial);
    if (serial == null || digest == null) {
      return RecordingCardResult<RecordingCardWifiBatchSnapshot>.failure(
        recordingCardFailure(
          'RECORDING_CARD_WIFI_BATCH_IDENTITY_RECOVERY_REQUIRED',
          'Authorized recording card did not expose a valid serial identity',
          isRetryable: true,
        ),
      );
    }
    final repairedSerial = serial;
    final repairedDigest = digest;
    if (!stillOwnsRepair()) return superseded();
    final current = _wifiBatchCoordinator.snapshot;
    if (current == null ||
        current.batchId != batch.batchId ||
        current.state != batch.state) {
      return RecordingCardResult<RecordingCardWifiBatchSnapshot>.failure(
        _fallbackFailure('RECORDING_CARD_WIFI_BATCH_NOT_RECOVERABLE'),
      );
    }
    final repaired = current.copyWith(
      deviceIdentity: 'serial:$repairedSerial',
      cardSnDigest: repairedDigest,
      items: current.items
          .map(
            (item) => item.copyWith(
              ledgerSourceSignature:
                  RecordingCardFileIdentity.sourceSignatureFor(
                    cardSnDigest: repairedDigest,
                    deviceFileId: item.file.deviceFileId,
                    deviceFilename: item.file.deviceFilename,
                    sizeBytes: item.file.sizeBytes,
                    recordedAt: item.file.recordedAt,
                  ),
            ),
          )
          .toList(growable: false),
      updatedAt: _clock(),
    );
    final persistenceFailure = await _persistWifiBatchDurably(
      repaired,
      allowLegacyIdentityUpgrade: true,
    );
    if (persistenceFailure != null) {
      return RecordingCardResult<RecordingCardWifiBatchSnapshot>.failure(
        persistenceFailure,
      );
    }
    if (_wifiBatchCoordinator.snapshot?.batchId != repaired.batchId) {
      return RecordingCardResult<RecordingCardWifiBatchSnapshot>.failure(
        _fallbackFailure('RECORDING_CARD_WIFI_BATCH_NOT_RECOVERABLE'),
      );
    }
    _wifiBatchCoordinator.replace(repaired);
    if (ownedDevice != null) {
      final previousDevice = _state.snapshot.deviceState;
      final connectedSnapshot = _normalizeRuntimeSnapshot(
        _port.runtimeSnapshot.copyWith(deviceState: ownedDevice),
      );
      _state = _state.copyWith(
        status: RecordingCardControllerStatus.idle,
        snapshot: _preserveDirectoryUntilVerified(connectedSnapshot),
        lastErrorCode: null,
      );
      notifyListeners();
      _observeConnectionTransition(previousDevice, ownedDevice);
    }
    return RecordingCardResult<RecordingCardWifiBatchSnapshot>.success(
      repaired,
    );
  }

  Future<void> _runPreparedWifiBatch() async {
    final stateGeneration = _wifiBatchStateGeneration;
    final batchId = _wifiBatchCoordinator.snapshot?.batchId;
    final attemptId = _wifiBatchCoordinator.snapshot?.attemptId;
    bool ownsFailureSettlement() {
      return !_disposed &&
          !_batchStopRequested &&
          stateGeneration == _wifiBatchStateGeneration &&
          batchId != null &&
          _wifiBatchCoordinator.snapshot?.batchId == batchId &&
          _wifiBatchCoordinator.snapshot?.attemptId == attemptId;
    }

    try {
      await _runPreparedWifiBatchCore();
    } catch (error) {
      if (!ownsFailureSettlement()) return;
      final phase = _wifiBatchCoordinator.snapshot?.state;
      final code = switch (phase) {
        RecordingCardWifiBatchState.openingSession =>
          'RECORDING_CARD_WIFI_SESSION_OPEN_FAILED',
        RecordingCardWifiBatchState.verifying =>
          'RECORDING_CARD_WIFI_VERIFICATION_FAILED',
        RecordingCardWifiBatchState.registering =>
          'RECORDING_CARD_LOCAL_LIBRARY_REGISTRATION_FAILED',
        _ => 'RECORDING_CARD_WIFI_TRANSFER_FAILED',
      };
      final failure = recordingCardFailure(
        code,
        'Recording-card Wi-Fi batch threw unexpectedly',
        cause: error,
        isRetryable: true,
      );
      final teardownFailure = await _closeNativeWifiSession(
        batchId!,
        attemptId: attemptId,
      );
      if (!ownsFailureSettlement()) return;
      final registrationFailure = await _registerStagedWifiBatchFilesOnce();
      if (!ownsFailureSettlement()) return;
      await _pauseWifiBatch(
        registrationFailure ?? teardownFailure ?? failure,
        closeNativeSession: false,
      );
    }
  }

  Future<void> _runPreparedWifiBatchCore() async {
    final initialBatch = _wifiBatchCoordinator.snapshot;
    final port = _port;
    if (initialBatch == null ||
        initialBatch.state != RecordingCardWifiBatchState.awaitingHotspot ||
        port is! RecordingCardWifiSessionPort ||
        _wifiBatchCancelInFlight != null ||
        _wifiBatchPauseInFlight != null ||
        _batchStopRequested) {
      return;
    }
    final wifiPort = port as RecordingCardWifiSessionPort;
    var batch = initialBatch;
    _claimTransferLatch();
    batch = batch.copyWith(
      state: RecordingCardWifiBatchState.openingSession,
      clearFailure: true,
      updatedAt: _clock(),
      clearCurrentItem: true,
      clearRate: true,
    );
    final openingPersistenceFailure = await _persistWifiBatchDurably(batch);
    if (openingPersistenceFailure != null) {
      await _pauseWifiBatch(openingPersistenceFailure);
      return;
    }
    _wifiBatchCoordinator.replace(batch);
    final pending = _pendingWifiFiles(batch);
    late final RecordingCardResult<RecordingCardWifiSessionInfo> opened;
    try {
      opened = await wifiPort
          .openWifiSession(pending)
          .timeout(_wifiSetupTimeout);
    } on TimeoutException catch (error) {
      opened = RecordingCardResult<RecordingCardWifiSessionInfo>.failure(
        recordingCardFailure(
          'RECORDING_CARD_WIFI_SESSION_OPEN_TIMEOUT',
          'Recording-card Wi-Fi session open timed out',
          cause: error,
          isRetryable: true,
        ),
      );
    }
    if (!opened.ok || opened.value == null) {
      if (_batchStopRequested) return;
      await _pauseWifiBatch(
        opened.error ??
            _fallbackFailure('RECORDING_CARD_WIFI_SESSION_OPEN_FAILED'),
      );
      return;
    }
    AppFailure? deferredFailure;
    final refreshedById = <String, RecordingCardScannedFile>{
      for (final file in opened.value!.files) file.deviceFileId: file,
    };
    for (var index = 0; index < batch.items.length; index += 1) {
      if (_batchStopRequested) break;
      batch = _wifiBatchCoordinator.snapshot!;
      final item = batch.items[index];
      if (item.state != RecordingCardWifiBatchItemState.queued) continue;
      final refreshed = refreshedById[item.file.deviceFileId];
      if (refreshed == null) {
        final ledgerFailure = _failWifiLedgerItems(
          cardSnDigest: _wifiBatchCardSnDigest(batch),
          items: <RecordingCardWifiBatchItem>[item],
          errorCode: 'RECORDING_CARD_WIFI_FILE_NOT_FOUND',
        );
        _replaceWifiBatchItem(
          index,
          item.copyWith(
            state: RecordingCardWifiBatchItemState.failed,
            errorCode: 'RECORDING_CARD_WIFI_FILE_NOT_FOUND',
          ),
        );
        if (ledgerFailure != null) {
          deferredFailure = ledgerFailure;
          break;
        }
        continue;
      }
      final verifiedSource = _wifiSessionFileWithRetainedEvidence(
        item.file,
        refreshed,
      );
      if (verifiedSource == null) {
        final failure = recordingCardFailure(
          'RECORDING_CARD_WIFI_DIRECTORY_CHANGED',
          'Recording-card Wi-Fi directory changed after file selection',
          isRetryable: true,
        );
        final ledgerFailure = _failWifiLedgerItems(
          cardSnDigest: _wifiBatchCardSnDigest(batch),
          items: <RecordingCardWifiBatchItem>[item],
          errorCode: failure.code,
        );
        _replaceWifiBatchItem(
          index,
          item.copyWith(
            state: RecordingCardWifiBatchItemState.failed,
            errorCode: failure.code,
            clearStagedDownload: true,
          ),
        );
        if (ledgerFailure != null) {
          deferredFailure = ledgerFailure;
          break;
        }
        continue;
      }
      final ledgerTransition = _beginWifiLedgerItem(batch, item);
      if (ledgerTransition.failure != null) {
        final failure = ledgerTransition.failure!;
        _replaceWifiBatchItem(
          index,
          ledgerTransition.item.copyWith(
            state: RecordingCardWifiBatchItemState.failed,
            errorCode: failure.code,
          ),
        );
        deferredFailure = failure;
        break;
      }
      if (ledgerTransition.item.isCompleted) {
        _replaceWifiBatchItem(index, ledgerTransition.item);
        continue;
      }
      final transferring = ledgerTransition.item.copyWith(
        file: verifiedSource,
        state: RecordingCardWifiBatchItemState.transferring,
        attemptCount: item.attemptCount + 1,
        plannedNativeFileId: wifiPort is RecordingCardWifiRecoveryPort
            ? item.plannedNativeFileId ?? _plannedWifiTarget(batch, item)
            : null,
        clearError: true,
      );
      _replaceWifiBatchItem(
        index,
        transferring,
        batchState: RecordingCardWifiBatchState.transferring,
        receivedBytes: 0,
        persist: false,
      );
      _state = _state.copyWith(
        status: RecordingCardControllerStatus.downloading,
        activeFileKey: refreshed.localFileKey,
        lastErrorCode: null,
      );
      notifyListeners();
      final checkpointFailure = _persistWifiBatchItem(
        _wifiBatchCoordinator.snapshot!,
        transferring,
        checkpointOnly: true,
      );
      if (checkpointFailure != null) {
        deferredFailure = checkpointFailure;
        break;
      }
      final intentFlushFailure = await _flushWifiBatchPersistence();
      if (intentFlushFailure != null) {
        deferredFailure = intentFlushFailure;
        break;
      }
      if (_batchStopRequested) break;
      final result = await _downloadWifiBatchFile(
        wifiPort,
        verifiedSource,
        nativeFileId: transferring.plannedNativeFileId,
      );
      if (!result.ok || result.value == null) {
        if (_batchStopRequested) break;
        final failure =
            result.error ?? _fallbackFailure('RECORDING_CARD_DOWNLOAD_FAILED');
        _replaceWifiBatchItem(
          index,
          transferring.copyWith(
            state: RecordingCardWifiBatchItemState.failed,
            errorCode: failure.code,
          ),
        );
        final ledgerFailure = _failWifiLedgerItems(
          cardSnDigest: _wifiBatchCardSnDigest(batch),
          items: <RecordingCardWifiBatchItem>[transferring],
          errorCode: failure.code,
        );
        if (ledgerFailure == null &&
            recordingCardFailureStage(failure.code) ==
                RecordingCardFailureStage.request) {
          continue;
        }
        deferredFailure = ledgerFailure ?? failure;
        break;
      }
      final integrityFailure = _downloadedFileIntegrityFailure(
        result.value!,
        verifiedSource,
      );
      if (integrityFailure != null) {
        final ledgerFailure = _failWifiLedgerItems(
          cardSnDigest: _wifiBatchCardSnDigest(batch),
          items: <RecordingCardWifiBatchItem>[transferring],
          errorCode: integrityFailure.code,
        );
        _replaceWifiBatchItem(
          index,
          transferring.copyWith(
            state: RecordingCardWifiBatchItemState.failed,
            errorCode: integrityFailure.code,
            clearStagedDownload: true,
          ),
        );
        deferredFailure = ledgerFailure ?? integrityFailure;
        break;
      }
      final staged = _validatedStagedWifiDownload(
        result.value!,
        verifiedSource,
      );
      if (staged == null) {
        final failure = recordingCardFailure(
          'RECORDING_CARD_LOCAL_FILE_METADATA_INVALID',
          'Recording-card Wi-Fi download returned unsafe staged metadata',
        );
        final ledgerFailure = _failWifiLedgerItems(
          cardSnDigest: _wifiBatchCardSnDigest(batch),
          items: <RecordingCardWifiBatchItem>[transferring],
          errorCode: failure.code,
        );
        _replaceWifiBatchItem(
          index,
          transferring.copyWith(
            state: RecordingCardWifiBatchItemState.failed,
            errorCode: failure.code,
            clearStagedDownload: true,
          ),
        );
        deferredFailure = ledgerFailure ?? failure;
        break;
      }
      _replaceWifiBatchItem(
        index,
        transferring.copyWith(
          state: RecordingCardWifiBatchItemState.verifying,
          stagedDownload: staged,
        ),
        batchState: RecordingCardWifiBatchState.verifying,
        receivedBytes: 0,
        persist: false,
      );
      final checkpointBatch = _wifiBatchCoordinator.snapshot;
      if (checkpointBatch == null) {
        deferredFailure = _fallbackFailure(
          'RECORDING_CARD_WIFI_BATCH_CHECKPOINT_FAILED',
        );
        break;
      }
      final stagedCheckpointFailure = _persistWifiBatchItem(
        checkpointBatch,
        checkpointBatch.items[index],
        checkpointOnly: true,
      );
      if (stagedCheckpointFailure != null) {
        deferredFailure = stagedCheckpointFailure;
        break;
      }
      final checkpointFlushFailure = await _flushWifiBatchPersistence();
      if (checkpointFlushFailure != null) {
        deferredFailure = checkpointFlushFailure;
        break;
      }
      if (_batchStopRequested) break;
      final registrationFailure = await _registerStagedWifiBatchFilesOnce();
      if (registrationFailure != null) {
        deferredFailure = registrationFailure;
        break;
      }
      final registeredBatch = _wifiBatchCoordinator.snapshot;
      if (registeredBatch == null ||
          index >= registeredBatch.items.length ||
          !registeredBatch.items[index].isCompleted) {
        deferredFailure = _fallbackFailure(
          'RECORDING_CARD_LOCAL_LIBRARY_REGISTRATION_FAILED',
        );
        break;
      }
      if (_batchStopRequested) break;
      if (_shouldWaitForWifiFirmwareReset(index)) {
        await Future<void>.delayed(_wifiInterFileCooldown);
      }
    }
    if (_disposed) return;
    final teardownFailure = await _closeNativeWifiSession(
      batch.batchId,
      attemptId: batch.attemptId,
    );
    deferredFailure ??= teardownFailure;
    final afterClose = _wifiBatchCoordinator.snapshot;
    if (afterClose != null) {
      final afterClosePersistenceFailure = _persistWifiBatch(afterClose);
      deferredFailure ??= afterClosePersistenceFailure;
    }
    final registrationFailure = deferredFailure == null
        ? await _registerStagedWifiBatchFilesOnce()
        : null;
    if (_batchStopRequested) return;
    if (registrationFailure != null) {
      await _pauseWifiBatch(registrationFailure, closeNativeSession: false);
      return;
    }
    batch = _wifiBatchCoordinator.snapshot!;
    if (_wifiBatchTeardownPendingBatchId == batch.batchId) {
      await _pauseWifiBatch(
        teardownFailure ??
            deferredFailure ??
            _fallbackFailure('RECORDING_CARD_WIFI_SESSION_CLOSE_FAILED'),
        closeNativeSession: false,
      );
      return;
    }
    if (deferredFailure != null) {
      if (_endsWifiBatchWithoutResume(deferredFailure)) {
        await _finishFailedWifiBatch(deferredFailure);
      } else {
        await _pauseWifiBatch(deferredFailure, closeNativeSession: false);
      }
      return;
    }
    if (batch.failedCount > 0) {
      final firstCode = batch.items
          .where((item) => item.errorCode != null)
          .map((item) => item.errorCode!)
          .firstOrNull;
      await _finishFailedWifiBatch(
        recordingCardFailure(
          firstCode ?? 'RECORDING_CARD_WIFI_TRANSFER_FAILED',
          'One or more recording-card files could not be synchronized',
          isRetryable: true,
        ),
      );
      return;
    }
    if (!batch.items.every((item) => item.isCompleted)) {
      await _pauseWifiBatch(
        _fallbackFailure('RECORDING_CARD_WIFI_DOWNLOAD_INCOMPLETE'),
        closeNativeSession: false,
      );
      return;
    }
    await _completeWifiBatchReconciliation(batch);
  }

  Future<AppFailure?> _registerStagedWifiBatchFilesOnce() {
    final running = _stagedBatchRegistrationInFlight;
    if (running != null) return running;
    late final Future<AppFailure?> operation;
    operation = _registerStagedWifiBatchFiles().whenComplete(() {
      if (identical(_stagedBatchRegistrationInFlight, operation)) {
        _stagedBatchRegistrationInFlight = null;
      }
    });
    _stagedBatchRegistrationInFlight = operation;
    return operation;
  }

  Future<AppFailure?> _registerStagedWifiBatchFiles() async {
    AppFailure? firstFailure;
    final initial = _wifiBatchCoordinator.snapshot;
    if (initial == null) return null;
    for (var index = 0; index < initial.items.length; index += 1) {
      final current = _wifiBatchCoordinator.snapshot;
      if (current == null || index >= current.items.length) break;
      final item = current.items[index];
      final staged = item.stagedDownload;
      if (staged == null ||
          item.state == RecordingCardWifiBatchItemState.completed ||
          item.state == RecordingCardWifiBatchItemState.skipped ||
          item.state == RecordingCardWifiBatchItemState.cancelled) {
        continue;
      }
      final registering = item.copyWith(
        state: RecordingCardWifiBatchItemState.registering,
        clearError: true,
      );
      _replaceWifiBatchItem(
        index,
        registering,
        batchState: RecordingCardWifiBatchState.registering,
        receivedBytes: 0,
      );
      RecordingCardResult<RecordingCardDownloadedFile> registration;
      try {
        registration = await _registerBatchDownloadedFile(
          staged,
          item.file,
        ).timeout(const Duration(seconds: 30));
      } on TimeoutException catch (error) {
        registration = RecordingCardResult<RecordingCardDownloadedFile>.failure(
          recordingCardFailure(
            'RECORDING_CARD_LOCAL_LIBRARY_REGISTRATION_TIMEOUT',
            'Recording-card staged file registration timed out',
            cause: error,
          ),
        );
      } catch (error) {
        registration = RecordingCardResult<RecordingCardDownloadedFile>.failure(
          recordingCardFailure(
            'RECORDING_CARD_LOCAL_LIBRARY_REGISTRATION_FAILED',
            'Recording-card staged file registration failed',
            cause: error,
          ),
        );
      }
      if (!registration.ok || registration.value == null) {
        final failure =
            registration.error ??
            _fallbackFailure(
              'RECORDING_CARD_LOCAL_LIBRARY_REGISTRATION_FAILED',
            );
        firstFailure ??= failure;
        _replaceWifiBatchItem(
          index,
          registering.copyWith(
            state: RecordingCardWifiBatchItemState.failed,
            errorCode: failure.code,
          ),
          batchState: RecordingCardWifiBatchState.registering,
          receivedBytes: 0,
        );
        break;
      }
      final linked = registration.value!;
      final currentBatch = _wifiBatchCoordinator.snapshot;
      if (currentBatch == null) {
        firstFailure ??= _fallbackFailure(
          'RECORDING_CARD_WIFI_BATCH_NOT_RECOVERABLE',
        );
        break;
      }
      final ledgerTransition = await _completeWifiLedgerItem(
        currentBatch,
        registering,
        localRecordingId: linked.localFileId,
        contentHash: linked.contentHash ?? item.file.contentHash,
      );
      if (ledgerTransition.failure != null) {
        final failure = ledgerTransition.failure!;
        firstFailure ??= failure;
        _replaceWifiBatchItem(
          index,
          ledgerTransition.item.copyWith(
            state: RecordingCardWifiBatchItemState.failed,
            errorCode: failure.code,
          ),
          batchState: RecordingCardWifiBatchState.registering,
          receivedBytes: 0,
        );
        break;
      }
      _applyLinkedBatchDownload(linked);
      _replaceWifiBatchItem(
        index,
        ledgerTransition.item.copyWith(
          file: _recordingCardFileWithLinkedDownload(item.file, linked),
          state: RecordingCardWifiBatchItemState.completed,
          localRecordingId: linked.localFileId,
          clearError: true,
          clearStagedDownload: true,
        ),
        batchState: RecordingCardWifiBatchState.registering,
        receivedBytes: 0,
      );
      final settlementFlushFailure = await _flushWifiBatchPersistence();
      if (settlementFlushFailure != null) {
        firstFailure ??= settlementFlushFailure;
        break;
      }
    }
    return firstFailure;
  }

  Future<void> _recoverBleAfterWifiBatch(
    RecordingCardWifiBatchSnapshot settledBatch, {
    bool deferNativeBackgroundSettlement = false,
  }) async {
    if (!identical(_wifiBatchCoordinator.snapshot, settledBatch)) return;
    final preservedDownload = _state.lastDownloadedFile;
    final preservedError = _state.lastErrorCode;
    final recoveryBatch = settledBatch.copyWith(
      operationPhase: RecordingCardWifiOperationPhase.recovering,
      updatedAt: _clock(),
      clearRate: true,
    );
    final recoveryOrigin =
        _activeTransferOperationLease?.origin ??
        RecordingCardOperationOrigin.user;
    final recoveryAdmission = _operationMachine.supersede(
      kind: RecordingCardOperationKind.bluetoothTransfer,
      origin: recoveryOrigin,
      connectionRevision: _connectionRevision,
    );
    final admittedRecoveryLease = recoveryAdmission.lease;
    if (admittedRecoveryLease == null) return;
    final latchGeneration = _claimTransferLatch(
      operationLease: admittedRecoveryLease,
    );
    _state = _state.copyWith(operation: recoveryAdmission.state);
    final recoveryGeneration = ++_wifiBleRecoveryGeneration;
    _wifiBleRecoveryInFlight = true;
    _wifiBatchCoordinator.replace(recoveryBatch);
    notifyListeners();
    final safeFingerprint = _recordingCardReconnectFingerprintValue(
      recoveryBatch.deviceFingerprint,
    );
    final observedFingerprints = <String?>[
      _recordingCardReconnectFingerprintValue(_wifiBatchReconnectFingerprint),
      _recordingCardReconnectFingerprintValue(
        _state.snapshot.deviceState.safeDeviceFingerprint,
      ),
      _recordingCardReconnectFingerprintValue(
        _port.runtimeSnapshot.deviceState.safeDeviceFingerprint,
      ),
    ];
    final hasFingerprintConflict =
        safeFingerprint != null &&
        observedFingerprints.any(
          (fingerprint) =>
              fingerprint != null && fingerprint != safeFingerprint,
        );
    String? authorizationFailureCode;
    String? directoryFailureCode;
    var timeoutFailureCode =
        'RECORDING_CARD_WIFI_BLE_RECOVERY_IDENTITY_TIMEOUT';
    var authorizationAttemptStarted = false;
    var ownsTerminalRecovery = false;
    try {
      if (safeFingerprint == null) {
        authorizationFailureCode =
            'RECORDING_CARD_WIFI_BLE_RECOVERY_IDENTITY_UNAVAILABLE';
        return;
      }
      if (hasFingerprintConflict) {
        authorizationFailureCode = 'RECORDING_CARD_WIFI_BATCH_DEVICE_MISMATCH';
        return;
      }
      _wifiBatchReconnectFingerprint = safeFingerprint;
      final bindingToken = await _bindingTokenProvider().timeout(
        _wifiBleRecoveryTimeout,
      );
      if (!_ownsWifiBleRecovery(recoveryGeneration, recoveryBatch)) return;
      if (!isRecordingCardBindingToken(bindingToken)) {
        authorizationFailureCode =
            'RECORDING_CARD_BINDING_IDENTITY_UNAVAILABLE';
        return;
      }
      _beginConnectionAuthorizationAttempt();
      authorizationAttemptStarted = true;
      timeoutFailureCode = 'RECORDING_CARD_WIFI_BLE_RECONNECT_TIMEOUT';
      final nativeConnected = await _port
          .connect(
            request: RecordingCardConnectRequest(
              safeDeviceFingerprint: safeFingerprint,
              expectedSerialNumber: _recordingCardSerialFromIdentity(
                recoveryBatch.deviceIdentity,
              ),
              overallTimeoutMs: _wifiBleRecoveryTimeout.inMilliseconds,
              forceScan: true,
            ).withBindingToken(bindingToken),
          )
          .timeout(_wifiBleRecoveryTimeout);
      if (!_rebaseWifiBleRecoveryLease(
        recoveryGeneration,
        recoveryBatch,
        origin: recoveryOrigin,
      )) {
        return;
      }
      timeoutFailureCode = 'RECORDING_CARD_WIFI_BLE_AUTHORIZATION_TIMEOUT';
      final connected = await _authorizeConnectedDeviceResult(
        nativeConnected,
        ownsOperation: () =>
            _ownsWifiBleRecovery(recoveryGeneration, recoveryBatch),
      ).timeout(_wifiBleRecoveryTimeout);
      if (!_ownsWifiBleRecovery(recoveryGeneration, recoveryBatch)) return;
      if (!connected.ok || connected.value?.isOperationallyConnected != true) {
        authorizationFailureCode =
            connected.error?.code ?? 'RECORDING_CARD_WIFI_BLE_RECOVERY_FAILED';
        return;
      }
      if (_recordingCardReconnectFingerprint(connected.value!) !=
          safeFingerprint) {
        authorizationFailureCode = 'RECORDING_CARD_WIFI_BATCH_DEVICE_MISMATCH';
        return;
      }
      _wifiHandoffBleUnavailable = false;
      var previousDevice = _state.snapshot.deviceState;
      final connectedSnapshot = _normalizeRuntimeSnapshot(
        _port.runtimeSnapshot.copyWith(deviceState: connected.value!),
      );
      _state = _state.copyWith(
        status: RecordingCardControllerStatus.idle,
        snapshot: connectedSnapshot,
        lastErrorCode: null,
      );
      notifyListeners();
      _observeConnectionTransition(
        previousDevice,
        connectedSnapshot.deviceState,
      );
      if (!_rebaseWifiBleRecoveryLease(
        recoveryGeneration,
        recoveryBatch,
        origin: recoveryOrigin,
      )) {
        return;
      }
      if (!_ownsWifiBleRecovery(
        recoveryGeneration,
        recoveryBatch,
        requireConnected: true,
      )) {
        return;
      }
      try {
        final refreshed = await _port.refreshDeviceInfo().timeout(
          _wifiBleRecoveryTimeout,
        );
        if (!_rebaseWifiBleRecoveryLease(
              recoveryGeneration,
              recoveryBatch,
              origin: recoveryOrigin,
            ) ||
            !_ownsWifiBleRecovery(
              recoveryGeneration,
              recoveryBatch,
              requireConnected: true,
            )) {
          return;
        }
        if (refreshed.ok && refreshed.value != null) {
          if (!refreshed.value!.deviceState.isOperationallyConnected ||
              !_matchesWifiBatchReconnectTarget(
                refreshed.value!.deviceState,
                recoveryBatch,
              )) {
            authorizationFailureCode =
                'RECORDING_CARD_WIFI_BATCH_DEVICE_MISMATCH';
            return;
          }
          previousDevice = _state.snapshot.deviceState;
          final refreshedSnapshot = _normalizeRuntimeSnapshot(refreshed.value!);
          _state = _state.copyWith(
            status: RecordingCardControllerStatus.idle,
            snapshot: _preserveDirectoryUntilVerified(refreshedSnapshot),
            lastErrorCode: null,
          );
          notifyListeners();
          _observeConnectionTransition(
            previousDevice,
            refreshedSnapshot.deviceState,
          );
          if (!_rebaseWifiBleRecoveryLease(
            recoveryGeneration,
            recoveryBatch,
            origin: recoveryOrigin,
          )) {
            return;
          }
        }
      } on TimeoutException {
        // Directory verification below is authoritative for transfer success.
      } catch (_) {}
      if (!_ownsWifiBleRecovery(
        recoveryGeneration,
        recoveryBatch,
        requireConnected: true,
      )) {
        return;
      }
      try {
        await _port.readRecordingState().timeout(_wifiBleRecoveryTimeout);
      } on TimeoutException {
        // Recording-state refresh is advisory after the session has closed.
      } catch (_) {}
      if (!_ownsWifiBleRecovery(
        recoveryGeneration,
        recoveryBatch,
        requireConnected: true,
      )) {
        return;
      }
      try {
        final successfulRevision = _successfulFileRefreshRevision;
        await _refreshFiles(
          reason: RecordingCardFileRefreshReason.transferCompleted,
          wifiBleRecoveryOwner: true,
        );
        if (!_ownsWifiBleRecovery(
          recoveryGeneration,
          recoveryBatch,
          requireConnected: true,
        )) {
          return;
        }
        if (_successfulFileRefreshRevision == successfulRevision ||
            !hasLoadedFilesForCurrentConnection) {
          directoryFailureCode =
              _state.fileCatalog.errorCode ?? 'RECORDING_CARD_SCAN_FAILED';
          return;
        }
      } catch (error) {
        if (!_ownsWifiBleRecovery(
          recoveryGeneration,
          recoveryBatch,
          requireConnected: true,
        )) {
          return;
        }
        final failure = recordingCardFailure(
          'RECORDING_CARD_SCAN_FAILED',
          'Recording-card directory recovery failed',
          cause: error,
          isRetryable: true,
        );
        directoryFailureCode = failure.code;
        _failFileCatalog(failure);
        return;
      }
    } on TimeoutException {
      if (_ownsWifiBleRecovery(recoveryGeneration, recoveryBatch)) {
        authorizationFailureCode ??= timeoutFailureCode;
        if (authorizationAttemptStarted) {
          _beginConnectionAuthorizationAttempt();
        }
      }
    } catch (_) {
      if (_ownsWifiBleRecovery(recoveryGeneration, recoveryBatch)) {
        authorizationFailureCode ??= 'RECORDING_CARD_WIFI_BLE_RECOVERY_FAILED';
      }
    } finally {
      if (recoveryGeneration == _wifiBleRecoveryGeneration) {
        ownsTerminalRecovery = true;
        _wifiBleRecoveryInFlight = false;
        _wifiBleRecoveryGeneration += 1;
        if (authorizationFailureCode != null) {
          _markWifiHandoffBleUnavailable();
        }
        final currentBatch = _wifiBatchCoordinator.snapshot;
        if (identical(currentBatch, recoveryBatch)) {
          _wifiBatchCoordinator.replace(
            recoveryBatch.copyWith(
              operationPhase: RecordingCardWifiOperationPhase.idle,
              updatedAt: _clock(),
            ),
          );
          _state = _state.copyWith(
            status:
                authorizationFailureCode == null &&
                    directoryFailureCode == null &&
                    preservedError == null
                ? RecordingCardControllerStatus.idle
                : RecordingCardControllerStatus.error,
            lastDownloadedFile: preservedDownload,
            clearLastDownloadedFile: preservedDownload == null,
            lastErrorCode:
                authorizationFailureCode ??
                directoryFailureCode ??
                preservedError,
            clearActiveFileKey: true,
          );
          notifyListeners();
        }
      }
      if (ownsTerminalRecovery && !deferNativeBackgroundSettlement) {
        await _settleNativeWifiRecoveryBackground(recoveryBatch);
      }
      _releaseTransferLatch(latchGeneration);
    }
  }

  Future<void> _settleNativeWifiRecoveryBackground(
    RecordingCardWifiBatchSnapshot batch,
  ) async {
    final port = _port;
    final attemptId = batch.attemptId?.trim();
    final safeFingerprint = _recordingCardReconnectFingerprintValue(
      batch.deviceFingerprint,
    );
    if (port is! RecordingCardWifiRecoverySettlementPort ||
        attemptId == null ||
        attemptId.isEmpty ||
        safeFingerprint == null) {
      return;
    }
    try {
      await (port as RecordingCardWifiRecoverySettlementPort)
          .settleWifiRecovery(
            batchId: batch.batchId,
            attemptId: attemptId,
            safeDeviceFingerprint: safeFingerprint,
          )
          .timeout(_wifiTeardownTimeout);
    } on Object {
      // Native expiry remains the bounded fallback for a lost settlement ACK.
    }
  }

  Future<AppFailure?> _completeWifiBatchReconciliation(
    RecordingCardWifiBatchSnapshot batch,
  ) async {
    final settlementGeneration = _wifiBatchStateGeneration;
    final settlementBatchId = batch.batchId;
    final settlementAttemptId = batch.attemptId;
    bool stillOwnsSettlement() => _ownsWifiBatchSettlement(
      batchId: settlementBatchId,
      attemptId: settlementAttemptId,
      stateGeneration: settlementGeneration,
    );
    AppFailure staleFailure() =>
        _fallbackFailure('RECORDING_CARD_WIFI_RECONCILIATION_STALE');
    if (!stillOwnsSettlement() ||
        _wifiBatchCoordinator.snapshot?.batchId != batch.batchId ||
        _wifiBatchCoordinator.snapshot?.attemptId != batch.attemptId ||
        batch.items.any((item) => !item.isCompleted) ||
        batch.items.any((item) => item.stagedDownload != null)) {
      return _fallbackFailure('RECORDING_CARD_WIFI_RECONCILIATION_INVALID');
    }
    var reconciling = batch.copyWith(
      state: RecordingCardWifiBatchState.reconciling,
      operationPhase: RecordingCardWifiOperationPhase.recovering,
      clearFailure: true,
      updatedAt: _clock(),
      clearCurrentItem: true,
      receivedBytes: 0,
      clearRate: true,
    );
    _wifiBatchCoordinator.replace(reconciling);
    if (!stillOwnsSettlement()) return staleFailure();
    final intentFailure = await _persistWifiBatchDurably(reconciling);
    if (!stillOwnsSettlement()) return staleFailure();
    if (intentFailure != null) {
      reconciling = reconciling.copyWith(
        failureCode: intentFailure.code,
        updatedAt: _clock(),
      );
      _wifiBatchCoordinator.replace(reconciling);
      if (!stillOwnsSettlement()) return staleFailure();
      _fail(intentFailure, preserveLastDownloadedFile: true);
      if (!stillOwnsSettlement()) return staleFailure();
      await _recoverBleAfterWifiBatch(reconciling);
      return intentFailure;
    }
    _state = _state.copyWith(
      status: RecordingCardControllerStatus.idle,
      clearActiveFileKey: true,
      lastErrorCode: null,
    );
    notifyListeners();
    if (!stillOwnsSettlement()) return staleFailure();

    await _recoverBleAfterWifiBatch(
      reconciling,
      deferNativeBackgroundSettlement: true,
    );
    if (!stillOwnsSettlement()) return staleFailure();
    final current = _wifiBatchCoordinator.snapshot;
    if (current == null) return staleFailure();
    final recoveryCode = _state.lastErrorCode;
    final verificationFailure = recoveryCode == null
        ? _verifyWifiBatchLocalProjection(current)
        : _fallbackFailure(recoveryCode);
    if (verificationFailure != null) {
      reconciling = current.copyWith(
        state: RecordingCardWifiBatchState.reconciling,
        failureCode: verificationFailure.code,
        updatedAt: _clock(),
        clearCurrentItem: true,
        receivedBytes: 0,
        clearRate: true,
      );
      final persistenceFailure = await _persistWifiBatchDurably(reconciling);
      if (!stillOwnsSettlement()) return staleFailure();
      final effectiveFailure = persistenceFailure ?? verificationFailure;
      reconciling = reconciling.copyWith(
        failureCode: effectiveFailure.code,
        updatedAt: _clock(),
      );
      _wifiBatchCoordinator.replace(reconciling);
      if (!stillOwnsSettlement()) return staleFailure();
      _fail(effectiveFailure, preserveLastDownloadedFile: true);
      await _settleNativeWifiRecoveryBackground(reconciling);
      return effectiveFailure;
    }

    final completed = current.copyWith(
      state: RecordingCardWifiBatchState.completed,
      clearFailure: true,
      updatedAt: _clock(),
      clearCurrentItem: true,
      receivedBytes: 0,
      clearRate: true,
    );
    final completionFailure = await _persistWifiBatchDurably(completed);
    if (!stillOwnsSettlement()) return staleFailure();
    if (completionFailure != null) {
      reconciling = current.copyWith(
        state: RecordingCardWifiBatchState.reconciling,
        failureCode: completionFailure.code,
        updatedAt: _clock(),
        clearCurrentItem: true,
        receivedBytes: 0,
        clearRate: true,
      );
      _persistWifiBatch(reconciling);
      await _flushWifiBatchPersistence();
      if (!stillOwnsSettlement()) return staleFailure();
      _wifiBatchCoordinator.replace(reconciling);
      if (!stillOwnsSettlement()) return staleFailure();
      _fail(completionFailure, preserveLastDownloadedFile: true);
      await _settleNativeWifiRecoveryBackground(reconciling);
      return completionFailure;
    }
    if (_wifiBatchLedgerFailureBatchId == completed.batchId) {
      _wifiBatchLedgerFailureBatchId = null;
    }
    _wifiBatchCoordinator.replace(completed);
    if (!stillOwnsSettlement()) return staleFailure();
    _state = _state.copyWith(
      status: RecordingCardControllerStatus.idle,
      clearActiveFileKey: true,
      lastErrorCode: null,
    );
    notifyListeners();
    await _settleNativeWifiRecoveryBackground(completed);
    return null;
  }

  AppFailure? _verifyWifiBatchLocalProjection(
    RecordingCardWifiBatchSnapshot batch,
  ) {
    if (!_state.snapshot.deviceState.isOperationallyConnected ||
        !_matchesWifiBatchReconnectTarget(_state.snapshot.deviceState, batch) ||
        !hasLoadedFilesForCurrentConnection) {
      return _fallbackFailure('RECORDING_CARD_WIFI_BLE_DIRECTORY_UNVERIFIED');
    }
    final persistence = _syncLedgerPersistence;
    final cardSnDigest = _wifiBatchCardSnDigest(batch);
    for (final item in batch.items) {
      final localRecordingId = item.localRecordingId?.trim();
      if (!item.isCompleted ||
          localRecordingId == null ||
          localRecordingId.isEmpty) {
        return _fallbackFailure(
          'RECORDING_CARD_WIFI_LOCAL_PROJECTION_INCOMPLETE',
        );
      }
      final local = _localRecordingRepository.findById(localRecordingId);
      final localUri = local?.appPrivateUri;
      final projected = _state.snapshot.files
          .where(
            (file) =>
                file.deviceFileId == item.file.deviceFileId &&
                file.deviceFilename == item.file.deviceFilename,
          )
          .firstOrNull;
      if (local == null ||
          localUri == null ||
          localUri.trim().isEmpty ||
          projected == null ||
          projected.syncState != RecordingCardFileSyncState.synced ||
          projected.localFileId != localRecordingId ||
          projected.appPrivateUri != localUri) {
        return _fallbackFailure(
          'RECORDING_CARD_WIFI_LOCAL_PROJECTION_INCOMPLETE',
        );
      }
      if (persistence != null) {
        final sourceSignature = item.ledgerSourceSignature;
        if (cardSnDigest == null || sourceSignature == null) {
          return _fallbackFailure('RECORDING_CARD_LEDGER_IDENTITY_UNAVAILABLE');
        }
        final ledgerEntry = persistence.findFileLedgerEntry(
          cardSnDigest: cardSnDigest,
          sourceSignature: sourceSignature,
        );
        if (ledgerEntry?.localState != RecordingCardFileLocalState.synced ||
            ledgerEntry?.localRecordingId != localRecordingId) {
          return _fallbackFailure(
            'RECORDING_CARD_LEDGER_RECONCILIATION_FAILED',
          );
        }
      }
    }
    return null;
  }

  bool _wifiCancellationNeedsBleRecovery(RecordingCardWifiBatchSnapshot batch) {
    final nativeDevice = _port.runtimeSnapshot.deviceState;
    if (nativeDevice.isOperationallyConnected) {
      if (!_matchesWifiBatchReconnectTarget(nativeDevice, batch)) return false;
      return switch (batch.state) {
        RecordingCardWifiBatchState.queued ||
        RecordingCardWifiBatchState.awaitingHotspot ||
        RecordingCardWifiBatchState.openingSession ||
        RecordingCardWifiBatchState.transferring ||
        RecordingCardWifiBatchState.verifying ||
        RecordingCardWifiBatchState.registering ||
        RecordingCardWifiBatchState.reconciling => true,
        _ => false,
      };
    }
    final controllerDevice = _state.snapshot.deviceState;
    return !controllerDevice.isOperationallyConnected ||
        _matchesWifiBatchReconnectTarget(controllerDevice, batch);
  }

  bool _canRetireLegacyWifiBatch(RecordingCardWifiBatchSnapshot batch) {
    if (_syncLedgerPersistence == null ||
        _persistedWifiBatchCardSnDigest(batch) != null ||
        _wifiBatchTeardownPendingBatchId == batch.batchId ||
        batch.items.any((item) => item.stagedDownload != null)) {
      return false;
    }
    return batch.items.every(
      (item) => item.ledgerSourceSignature?.trim().isNotEmpty != true,
    );
  }

  Future<AppFailure?>
  _settleLegacyIncompleteWifiBatchForFreshSelection() async {
    final batch = _wifiBatchCoordinator.snapshot;
    if (batch == null ||
        batch.state != RecordingCardWifiBatchState.paused ||
        batch.items.any((item) => item.stagedDownload != null) ||
        !batch.items.any(
          (item) => item.errorCode == 'RECORDING_CARD_WIFI_DOWNLOAD_INCOMPLETE',
        )) {
      return null;
    }
    final failure = _fallbackFailure('RECORDING_CARD_WIFI_DOWNLOAD_INCOMPLETE');
    final failed = _terminalFailedWifiBatch(batch, failure);
    final ledgerFailure = _failWifiLedgerItems(
      cardSnDigest: _wifiBatchCardSnDigest(failed),
      items: failed.items.where(
        (item) => item.state == RecordingCardWifiBatchItemState.failed,
      ),
      errorCode: failure.code,
    );
    if (ledgerFailure != null) {
      var paused = _pausedWifiBatchSnapshot(
        batch,
        failureCode: ledgerFailure.code,
      );
      final persistenceFailure = await _persistWifiBatchDurably(paused);
      final effectiveFailure = persistenceFailure ?? ledgerFailure;
      if (persistenceFailure != null) {
        paused = _pausedWifiBatchSnapshot(
          paused,
          failureCode: persistenceFailure.code,
        );
      }
      _wifiBatchCoordinator.replace(paused);
      return effectiveFailure;
    }
    if (_wifiBatchLedgerFailureBatchId == failed.batchId) {
      _wifiBatchLedgerFailureBatchId = null;
    }
    final persistenceFailure = await _persistWifiBatchDurably(failed);
    if (persistenceFailure != null) {
      final paused = _pausedWifiBatchSnapshot(
        batch,
        failureCode: persistenceFailure.code,
      );
      _wifiBatchCoordinator.replace(paused);
      return persistenceFailure;
    }
    _wifiBatchCoordinator.replace(failed);
    _releaseTransferLatch(_transferLatchGeneration);
    return null;
  }

  bool _shouldWaitForWifiFirmwareReset(int completedItemIndex) {
    final batch = _wifiBatchCoordinator.snapshot;
    final device = _state.snapshot.deviceState;
    if (batch == null ||
        device.firmwareVersion != '1.0.6' ||
        device.wifiFirmwareVersion != '1.0.2') {
      return false;
    }
    return batch.items
        .skip(completedItemIndex + 1)
        .any((item) => item.state == RecordingCardWifiBatchItemState.queued);
  }

  bool _endsWifiBatchWithoutResume(AppFailure failure) {
    return failure.code == 'RECORDING_CARD_WIFI_DOWNLOAD_INCOMPLETE';
  }

  RecordingCardWifiBatchSnapshot _pausedWifiBatchSnapshot(
    RecordingCardWifiBatchSnapshot batch, {
    String? failureCode,
    bool willRecoverBle = false,
  }) {
    final pendingTeardown = _wifiNativeTeardownPendingKey;
    final hasPendingTeardown =
        pendingTeardown != null &&
        pendingTeardown.batchId == batch.batchId &&
        pendingTeardown.attemptId == batch.attemptId;
    final operationPhase = hasPendingTeardown
        ? RecordingCardWifiOperationPhase.stopping
        : willRecoverBle ||
              batch.operationPhase == RecordingCardWifiOperationPhase.recovering
        ? RecordingCardWifiOperationPhase.recovering
        : RecordingCardWifiOperationPhase.idle;
    return batch.copyWith(
      state: RecordingCardWifiBatchState.paused,
      operationPhase: operationPhase,
      items: batch.items
          .map((item) {
            if (item.isTerminal) return item;
            return item.copyWith(
              state: item.stagedDownload == null
                  ? RecordingCardWifiBatchItemState.queued
                  : RecordingCardWifiBatchItemState.verifying,
              clearError: true,
            );
          })
          .toList(growable: false),
      failureCode: failureCode,
      clearFailure: failureCode == null,
      updatedAt: _clock(),
      clearCurrentItem: true,
      receivedBytes: 0,
      clearRate: true,
    );
  }

  bool _ownsWifiBatchSettlement({
    required String batchId,
    required String? attemptId,
    required int stateGeneration,
  }) {
    final current = _wifiBatchCoordinator.snapshot;
    return !_disposed &&
        !_batchStopRequested &&
        stateGeneration == _wifiBatchStateGeneration &&
        current != null &&
        current.batchId == batchId &&
        current.attemptId == attemptId &&
        !current.stopRequested;
  }

  Future<void> _finishFailedWifiBatch(AppFailure failure) async {
    final batch = _wifiBatchCoordinator.snapshot;
    if (batch == null ||
        _wifiBatchTeardownPendingBatchId == batch.batchId ||
        batch.items.any((item) => item.stagedDownload != null)) {
      await _pauseWifiBatch(failure, closeNativeSession: false);
      return;
    }
    final settlementGeneration = _wifiBatchStateGeneration;
    final settlementBatchId = batch.batchId;
    final settlementAttemptId = batch.attemptId;
    bool stillOwnsSettlement() => _ownsWifiBatchSettlement(
      batchId: settlementBatchId,
      attemptId: settlementAttemptId,
      stateGeneration: settlementGeneration,
    );
    if (!stillOwnsSettlement()) return;
    final failed = _terminalFailedWifiBatch(
      batch,
      failure,
    ).copyWith(operationPhase: RecordingCardWifiOperationPhase.recovering);
    final ledgerFailure = _failWifiLedgerItems(
      cardSnDigest: _wifiBatchCardSnDigest(failed),
      items: failed.items.where(
        (item) => item.state == RecordingCardWifiBatchItemState.failed,
      ),
      errorCode: failure.code,
    );
    if (ledgerFailure != null) {
      var paused = _pausedWifiBatchSnapshot(
        batch,
        failureCode: ledgerFailure.code,
        willRecoverBle: true,
      );
      final persistenceFailure = await _persistWifiBatchDurably(paused);
      if (!stillOwnsSettlement()) return;
      final finalizationFailure = persistenceFailure ?? ledgerFailure;
      if (persistenceFailure != null) {
        paused = _pausedWifiBatchSnapshot(
          paused,
          failureCode: persistenceFailure.code,
        );
      }
      _wifiBatchCoordinator.replace(paused);
      if (!stillOwnsSettlement()) return;
      _fail(finalizationFailure);
      if (stillOwnsSettlement() &&
          _wifiBatchTeardownPendingBatchId != paused.batchId) {
        await _recoverBleAfterWifiBatch(paused);
      }
      return;
    }
    if (_wifiBatchLedgerFailureBatchId == failed.batchId) {
      _wifiBatchLedgerFailureBatchId = null;
    }
    final persistenceFailure = await _persistWifiBatchDurably(failed);
    if (!stillOwnsSettlement()) return;
    if (persistenceFailure != null) {
      var paused = _pausedWifiBatchSnapshot(
        batch,
        failureCode: persistenceFailure.code,
        willRecoverBle: true,
      );
      final pausedPersistenceFailure = await _persistWifiBatchDurably(paused);
      if (!stillOwnsSettlement()) return;
      final finalizationFailure =
          pausedPersistenceFailure ?? persistenceFailure;
      if (pausedPersistenceFailure != null) {
        paused = _pausedWifiBatchSnapshot(
          paused,
          failureCode: pausedPersistenceFailure.code,
        );
      }
      _wifiBatchCoordinator.replace(paused);
      if (!stillOwnsSettlement()) return;
      _fail(finalizationFailure);
      if (stillOwnsSettlement() &&
          _wifiBatchTeardownPendingBatchId != paused.batchId) {
        await _recoverBleAfterWifiBatch(paused);
      }
      return;
    }
    _wifiBatchCoordinator.replace(failed);
    if (!stillOwnsSettlement()) return;
    _fail(failure);
    if (!stillOwnsSettlement()) return;
    await _recoverBleAfterWifiBatch(failed);
  }

  RecordingCardWifiBatchSnapshot _terminalFailedWifiBatch(
    RecordingCardWifiBatchSnapshot batch,
    AppFailure failure,
  ) {
    return batch.copyWith(
      state: RecordingCardWifiBatchState.failed,
      items: batch.items
          .map((item) {
            if (item.state == RecordingCardWifiBatchItemState.completed ||
                item.state == RecordingCardWifiBatchItemState.skipped ||
                item.state == RecordingCardWifiBatchItemState.cancelled) {
              return item;
            }
            return item.copyWith(
              state: RecordingCardWifiBatchItemState.failed,
              errorCode: item.errorCode ?? failure.code,
              clearStagedDownload: true,
            );
          })
          .toList(growable: false),
      updatedAt: _clock(),
      failureCode: failure.code,
      clearCurrentItem: true,
      receivedBytes: 0,
      clearRate: true,
    );
  }

  Future<RecordingCardResult<RecordingCardDownloadedFile>>
  _downloadWifiBatchFile(
    RecordingCardWifiSessionPort port,
    RecordingCardScannedFile file, {
    String? nativeFileId,
  }) async {
    final interrupt =
        Completer<RecordingCardResult<RecordingCardDownloadedFile>>();
    _wifiBatchDownloadInterrupt = interrupt;
    try {
      return await Future.any<RecordingCardResult<RecordingCardDownloadedFile>>(
        <Future<RecordingCardResult<RecordingCardDownloadedFile>>>[
          (port is RecordingCardWifiRecoveryPort && nativeFileId != null
                  ? (port as RecordingCardWifiRecoveryPort)
                        .downloadRecoverableWifiFile(
                          file,
                          nativeFileId: nativeFileId,
                        )
                  : port.downloadFileInWifiSession(file))
              .timeout(_wifiFileTransferTimeout),
          interrupt.future,
        ],
      );
    } on TimeoutException catch (error) {
      return RecordingCardResult<RecordingCardDownloadedFile>.failure(
        recordingCardFailure(
          'RECORDING_CARD_WIFI_DOWNLOAD_TIMEOUT',
          'Recording-card Wi-Fi download timed out',
          cause: error,
          isRetryable: true,
        ),
      );
    } finally {
      if (identical(_wifiBatchDownloadInterrupt, interrupt)) {
        _wifiBatchDownloadInterrupt = null;
      }
    }
  }

  void _interruptWifiBatchDownload(String code) {
    final interrupt = _wifiBatchDownloadInterrupt;
    if (interrupt == null || interrupt.isCompleted) return;
    interrupt.complete(
      RecordingCardResult<RecordingCardDownloadedFile>.failure(
        recordingCardFailure(
          code,
          'Recording-card Wi-Fi download was interrupted',
          isRetryable: true,
        ),
      ),
    );
  }

  Future<AppFailure?> _cancelNativeWifiTransfer(
    String batchId, {
    String? attemptId,
  }) => _teardownNativeWifiSession(
    key: (batchId: batchId, attemptId: attemptId),
    mode: _RecordingCardWifiNativeTeardownMode.cancel,
  );

  Future<AppFailure?> _closeNativeWifiSession(
    String batchId, {
    String? attemptId,
  }) => _teardownNativeWifiSession(
    key: (batchId: batchId, attemptId: attemptId),
    mode: _RecordingCardWifiNativeTeardownMode.close,
  );

  Future<AppFailure?> _teardownNativeWifiSession({
    required _RecordingCardWifiNativeTeardownKey key,
    required _RecordingCardWifiNativeTeardownMode mode,
  }) {
    if (_wifiNativeTeardownSettledKeys.contains(key)) {
      return Future<AppFailure?>.value();
    }
    if (!_ownsNativeWifiTeardownKey(key)) {
      return Future<AppFailure?>.value(
        _supersededNativeWifiTeardownResult(key),
      );
    }
    final running = _wifiNativeTeardownInFlight;
    if (running != null) {
      if (_wifiNativeTeardownInFlightKey == key) return running;
      return running.then(
        (_) => _teardownNativeWifiSession(key: key, mode: mode),
      );
    }
    late final Future<AppFailure?> operation;
    operation = _performNativeWifiTeardown(key, mode).whenComplete(() {
      if (identical(_wifiNativeTeardownInFlight, operation)) {
        _wifiNativeTeardownInFlight = null;
        _wifiNativeTeardownInFlightKey = null;
      }
    });
    _wifiNativeTeardownInFlightKey = key;
    _wifiNativeTeardownInFlight = operation;
    return operation;
  }

  Future<AppFailure?> _performNativeWifiTeardown(
    _RecordingCardWifiNativeTeardownKey key,
    _RecordingCardWifiNativeTeardownMode mode,
  ) async {
    if (!_ownsNativeWifiTeardownKey(key)) {
      return _supersededNativeWifiTeardownResult(key);
    }
    final port = _port;
    if (mode == _RecordingCardWifiNativeTeardownMode.cancel ||
        port is! RecordingCardWifiSessionPort) {
      return _performNativeWifiCancellation(key);
    }
    RecordingCardResult<bool> result;
    try {
      result = await (port as RecordingCardWifiSessionPort)
          .closeWifiSession()
          .timeout(_wifiTeardownTimeout);
    } on TimeoutException catch (error) {
      result = RecordingCardResult<bool>.failure(
        recordingCardFailure(
          'RECORDING_CARD_WIFI_SESSION_CLOSE_TIMEOUT',
          'Recording-card Wi-Fi session close timed out',
          cause: error,
          isRetryable: true,
        ),
      );
    } catch (error) {
      result = RecordingCardResult<bool>.failure(
        recordingCardFailure(
          'RECORDING_CARD_WIFI_SESSION_CLOSE_FAILED',
          'Recording-card Wi-Fi session close threw unexpectedly',
          cause: error,
          isRetryable: true,
        ),
      );
    }
    if (!_ownsNativeWifiTeardownKey(key)) {
      return _supersededNativeWifiTeardownResult(key);
    }
    if (result.ok && result.value == true) {
      _settleNativeWifiTeardown(key);
      return null;
    }
    final cancellationFailure = await _performNativeWifiCancellation(key);
    if (cancellationFailure == null) return null;
    return (result.error ?? cancellationFailure).copyWith(
      isRetryable: true,
      recoveryActions: const <String>['retry'],
    );
  }

  Future<AppFailure?> _performNativeWifiCancellation(
    _RecordingCardWifiNativeTeardownKey key,
  ) async {
    if (!_ownsNativeWifiTeardownKey(key)) {
      return _supersededNativeWifiTeardownResult(key);
    }
    final port = _port;
    late final RecordingCardResult<bool> result;
    try {
      if (port is RecordingCardWifiSessionPort) {
        result = await (port as RecordingCardWifiSessionPort)
            .cancelWifiSession()
            .timeout(_wifiTeardownTimeout);
      } else if (port is RecordingCardCancelableTransferPort) {
        result = await (port as RecordingCardCancelableTransferPort)
            .cancelFileTransfer()
            .timeout(_wifiTeardownTimeout);
      } else {
        result = RecordingCardResult<bool>.failure(
          recordingCardFailure(
            'RECORDING_CARD_WIFI_CANCEL_UNAVAILABLE',
            'Recording-card Wi-Fi cancellation is unavailable',
            isRetryable: true,
          ),
        );
      }
    } on TimeoutException catch (error) {
      result = RecordingCardResult<bool>.failure(
        recordingCardFailure(
          'RECORDING_CARD_WIFI_CANCEL_TIMEOUT',
          'Recording-card Wi-Fi cancellation timed out',
          cause: error,
          isRetryable: true,
        ),
      );
    } catch (error) {
      result = RecordingCardResult<bool>.failure(
        recordingCardFailure(
          'RECORDING_CARD_WIFI_CANCEL_FAILED',
          'Recording-card Wi-Fi cancellation threw unexpectedly',
          cause: error,
          isRetryable: true,
        ),
      );
    }
    if (!_ownsNativeWifiTeardownKey(key)) {
      return _supersededNativeWifiTeardownResult(key);
    }
    if (result.ok && result.value == true) {
      _settleNativeWifiTeardown(key);
      return null;
    }
    final cancellationFailure =
        (result.error ??
                recordingCardFailure(
                  'RECORDING_CARD_WIFI_CANCEL_FAILED',
                  'Recording-card Wi-Fi cancellation was not acknowledged',
                  isRetryable: true,
                ))
            .copyWith(
              isRetryable: true,
              recoveryActions: const <String>['retry'],
            );
    if (!_ownsNativeWifiTeardownKey(key)) {
      return _supersededNativeWifiTeardownResult(key);
    }
    final retirementFailure = await _retireNativeWifiTransport();
    if (!_ownsNativeWifiTeardownKey(key)) {
      return _supersededNativeWifiTeardownResult(key);
    }
    if (retirementFailure == null) {
      _settleNativeWifiTeardown(key);
      return null;
    }
    _wifiNativeTeardownPendingKey = key;
    return cancellationFailure.copyWith(cause: retirementFailure);
  }

  void _settleNativeWifiTeardown(_RecordingCardWifiNativeTeardownKey key) {
    _wifiNativeTeardownSettledKeys.remove(key);
    _wifiNativeTeardownSettledKeys.add(key);
    while (_wifiNativeTeardownSettledKeys.length >
        _recordingCardWifiSettledTeardownRetention) {
      _wifiNativeTeardownSettledKeys.remove(
        _wifiNativeTeardownSettledKeys.first,
      );
    }
    if (_wifiNativeTeardownPendingKey == key) {
      _wifiNativeTeardownPendingKey = null;
    }
  }

  AppFailure? _supersededNativeWifiTeardownResult(
    _RecordingCardWifiNativeTeardownKey key,
  ) {
    if (_wifiNativeTeardownPendingKey == key) {
      return recordingCardFailure(
        'RECORDING_CARD_WIFI_BATCH_SUPERSEDED',
        'A pending recording-card Wi-Fi teardown lost its attempt owner',
        isRetryable: true,
      );
    }
    _settleNativeWifiTeardown(key);
    return null;
  }

  bool _ownsNativeWifiTeardownKey(_RecordingCardWifiNativeTeardownKey key) {
    final current = _wifiBatchCoordinator.snapshot;
    return !_disposed &&
        current != null &&
        current.batchId == key.batchId &&
        current.attemptId == key.attemptId;
  }

  Future<AppFailure?> _retireNativeWifiTransport() async {
    late final RecordingCardResult<RecordingCardDeviceState> result;
    try {
      result = await _port.disconnect().timeout(_wifiTeardownTimeout);
    } on TimeoutException catch (error) {
      return recordingCardFailure(
        'RECORDING_CARD_WIFI_TRANSPORT_RETIRE_TIMEOUT',
        'Recording-card Wi-Fi transport retirement timed out',
        cause: error,
        isRetryable: true,
      );
    } catch (error) {
      return recordingCardFailure(
        'RECORDING_CARD_WIFI_TRANSPORT_RETIRE_FAILED',
        'Recording-card Wi-Fi transport retirement threw unexpectedly',
        cause: error,
        isRetryable: true,
      );
    }
    final device = result.value;
    if (result.ok && device != null && !device.isOperationallyConnected) {
      return null;
    }
    return recordingCardFailure(
      'RECORDING_CARD_WIFI_TRANSPORT_RETIRE_FAILED',
      'Recording-card Wi-Fi transport could not be retired',
      cause: result.error,
      isRetryable: true,
    );
  }

  Future<void> _pauseWifiBatch(
    AppFailure failure, {
    bool closeNativeSession = true,
  }) async {
    final latchGeneration = _transferLatchGeneration;
    final batch = _wifiBatchCoordinator.snapshot;
    final stateGeneration = _wifiBatchStateGeneration;
    bool ownsPauseSettlement() {
      final current = _wifiBatchCoordinator.snapshot;
      return !_disposed &&
          !_batchStopRequested &&
          stateGeneration == _wifiBatchStateGeneration &&
          current?.batchId == batch?.batchId &&
          current?.attemptId == batch?.attemptId;
    }

    final teardownFailure = closeNativeSession && batch != null
        ? await _closeNativeWifiSession(
            batch.batchId,
            attemptId: batch.attemptId,
          )
        : null;
    if (batch != null && !ownsPauseSettlement()) return;
    final needsBleRecovery =
        batch != null &&
        !_batchStopRequested &&
        _wifiBatchTeardownPendingBatchId != batch.batchId;
    RecordingCardWifiBatchSnapshot? pausedBatch;
    AppFailure? ledgerFailure;
    AppFailure? persistenceFailure;
    if (batch != null && !_batchStopRequested) {
      var paused = _pausedWifiBatchSnapshot(
        batch,
        failureCode: (teardownFailure ?? failure).code,
        willRecoverBle: needsBleRecovery,
      );
      _wifiBatchCoordinator.replace(paused);
      ledgerFailure = await _reconcileRestoredWifiLedger(paused.batchId);
      if (!ownsPauseSettlement()) return;
      paused = _wifiBatchCoordinator.snapshot ?? paused;
      if (ledgerFailure != null) {
        paused = _pausedWifiBatchSnapshot(
          paused,
          failureCode: ledgerFailure.code,
        );
        _wifiBatchCoordinator.replace(paused);
      }
      persistenceFailure = await _persistWifiBatchDurably(paused);
      if (!ownsPauseSettlement()) return;
      if (persistenceFailure != null) {
        paused = _pausedWifiBatchSnapshot(
          paused,
          failureCode: persistenceFailure.code,
        );
        _wifiBatchCoordinator.replace(paused);
      }
      pausedBatch = paused;
    }
    _fail(persistenceFailure ?? ledgerFailure ?? teardownFailure ?? failure);
    if (pausedBatch != null) {
      if (!needsBleRecovery) {
        _releaseTransferLatch(latchGeneration);
        return;
      }
      await _recoverBleAfterWifiBatch(pausedBatch);
    } else if (!_batchStopRequested &&
        (batch == null || _wifiBatchTeardownPendingBatchId != batch.batchId)) {
      _releaseTransferLatch(_transferLatchGeneration);
    }
  }

  bool get _batchStopRequested =>
      _disposed || _batchCancelRequested || _batchPauseRequested;

  void _replaceWifiBatchItem(
    int index,
    RecordingCardWifiBatchItem item, {
    RecordingCardWifiBatchState? batchState,
    int? receivedBytes,
    bool persist = true,
  }) {
    final current = _wifiBatchCoordinator.snapshot;
    if (current == null || index < 0 || index >= current.items.length) return;
    final items = <RecordingCardWifiBatchItem>[...current.items];
    items[index] = item;
    final updated = current.copyWith(
      state: batchState,
      items: items,
      updatedAt: _clock(),
      currentItemIndex: index,
      receivedBytes: receivedBytes,
    );
    _wifiBatchCoordinator.replace(updated);
    if (persist) _persistWifiBatch(updated);
  }

  Future<void> connect({RecordingCardConnectRequest? request}) =>
      _connect(request: request);

  Future<void> _connect({
    RecordingCardConnectRequest? request,
    RecordingCardOperationLease? operationLease,
  }) async {
    if (_state.status == RecordingCardControllerStatus.unbinding) return;
    if (operationLease == null && _pendingBluetoothResumePreflight) {
      _clearPendingBluetoothResumeOwner(releaseLatch: true);
    }
    if (_hasActiveOrPendingDeviceDiscovery) {
      await cancelDiscovery();
      if (_disposed) return;
    }
    if (operationLease == null) {
      if (!_startControllerOperation(
        status: RecordingCardControllerStatus.connecting,
        kind: RecordingCardOperationKind.connection,
        allowLifecycleSupersession: true,
      )) {
        return;
      }
    } else {
      if (!_operationMachine.owns(operationLease)) return;
      _activeControllerOperationLease = operationLease;
      _setBusy(RecordingCardControllerStatus.connecting);
    }
    final operation = ++_deviceDiscoveryOperation;
    final permissionFailure = await _permissionCoordinator
        .requestBluetoothAccess();
    if (!_isCurrentDeviceDiscoveryOperation(operation)) return;
    if (permissionFailure != null) {
      _fail(permissionFailure);
      return;
    }
    if (_port is UnavailableRecordingCardPort) {
      _beginConnectionAuthorizationAttempt();
      final nativeResult = await _port.connect(request: request);
      if (!_isCurrentDeviceDiscoveryOperation(operation)) return;
      if (_isStaleDeviceOperation(nativeResult)) {
        await _adoptCurrentNativeDeviceState(
          operation,
          acceptsWifiHandoffConnection: true,
        );
        return;
      }
      final result = await _authorizeConnectedDeviceResult(nativeResult);
      if (!_isCurrentDeviceDiscoveryOperation(operation)) return;
      _handleDeviceStateResult(
        result,
        requestedDevice: request,
        acceptsWifiHandoffConnection: true,
      );
      return;
    }
    final String bindingToken;
    try {
      bindingToken = await _bindingTokenProvider();
    } catch (_) {
      if (!_isCurrentDeviceDiscoveryOperation(operation)) return;
      _fail(
        recordingCardFailure(
          'RECORDING_CARD_BINDING_IDENTITY_UNAVAILABLE',
          'Recording-card secure binding identity is unavailable',
          isRetryable: true,
        ),
      );
      return;
    }
    if (!_isCurrentDeviceDiscoveryOperation(operation)) return;
    if (!isRecordingCardBindingToken(bindingToken)) {
      _fail(
        recordingCardFailure(
          'RECORDING_CARD_BINDING_IDENTITY_UNAVAILABLE',
          'Recording-card secure binding identity is unavailable',
          isRetryable: true,
        ),
      );
      return;
    }
    _beginConnectionAuthorizationAttempt();
    final nativeResult = await _port.connect(
      request: (request ?? const RecordingCardConnectRequest())
          .withBindingToken(bindingToken),
    );
    if (!_isCurrentDeviceDiscoveryOperation(operation)) return;
    if (_isStaleDeviceOperation(nativeResult)) {
      await _adoptCurrentNativeDeviceState(
        operation,
        acceptsWifiHandoffConnection: true,
      );
      return;
    }
    final result = await _authorizeConnectedDeviceResult(nativeResult);
    if (!_isCurrentDeviceDiscoveryOperation(operation)) return;
    _handleDeviceStateResult(
      result,
      requestedDevice: request,
      acceptsWifiHandoffConnection: true,
    );
  }

  Future<void> connectDiscoveredDevice(
    RecordingCardDiscoveredDevice device,
  ) async {
    if (_state.status == RecordingCardControllerStatus.unbinding) return;
    final fingerprint = device.safeDeviceFingerprint.trim();
    final displayName = device.displayName.trim();
    if (device.isConnectable == false ||
        !isSafeRecordingCardIdentifier(fingerprint) ||
        !isSafeRecordingCardIdentifier(displayName)) {
      _fail(
        recordingCardFailure(
          'RECORDING_CARD_DISCOVERED_DEVICE_UNAVAILABLE',
          'The selected recording-card discovery is unavailable',
          isRetryable: true,
        ),
      );
      return;
    }
    if (_pendingBluetoothResumePreflight) {
      _clearPendingBluetoothResumeOwner(releaseLatch: true);
    }
    if (_hasActiveOrPendingDeviceDiscovery) {
      await cancelDiscovery();
      if (_disposed) return;
    }
    String? expectedSerialNumber;
    RecordingCardOperationLease? connectionLease;
    final discoveryAuthorization = _connectionAuthorization;
    if (discoveryAuthorization is RecordingCardDiscoveryAuthorizationPort) {
      final authorizationPort =
          discoveryAuthorization as RecordingCardDiscoveryAuthorizationPort;
      expectedSerialNumber = normalizeRecordingCardSerialNumberForOwnership(
        device.serialNumber ?? '',
      );
      if (expectedSerialNumber == null) {
        _fail(
          recordingCardFailure(
            'RECORDING_CARD_ADVERTISEMENT_SN_INVALID',
            'Recording-card advertisement serial number is unavailable',
            isRetryable: true,
          ),
        );
        return;
      }
      if (!_startControllerOperation(
        status: RecordingCardControllerStatus.authorizing,
        kind: RecordingCardOperationKind.connection,
        allowLifecycleSupersession: true,
      )) {
        return;
      }
      connectionLease = _activeControllerOperationLease;
      final operation = ++_deviceDiscoveryOperation;
      final authorization = await authorizationPort.authorizeDiscoveredDevice(
        serialNumber: expectedSerialNumber,
        displayName: displayName,
      );
      if (!_isCurrentDeviceDiscoveryOperation(operation)) return;
      if (!authorization.ok || authorization.value != true) {
        _fail(
          authorization.error ??
              _fallbackFailure('RECORDING_CARD_CLOUD_AUTHORIZATION_FAILED'),
        );
        return;
      }
    }
    await _connect(
      request: RecordingCardConnectRequest(
        displayName: displayName,
        safeDeviceFingerprint: fingerprint,
        expectedSerialNumber: expectedSerialNumber,
      ),
      operationLease: connectionLease,
    );
  }

  Future<List<RecordingCardDiscoveredDevice>>
  cachedAuthorizedDiscoveredDevices() async {
    final discoveryAuthorization = _connectionAuthorization;
    if (discoveryAuthorization is! RecordingCardDiscoveryAuthorizationPort) {
      return const <RecordingCardDiscoveredDevice>[];
    }
    final authorizationPort =
        discoveryAuthorization as RecordingCardDiscoveryAuthorizationPort;
    final matches = <RecordingCardDiscoveredDevice>[];
    for (final device in _state.snapshot.discoveredDevices) {
      if (device.isConnectable == false) continue;
      final serialNumber = normalizeRecordingCardSerialNumberForOwnership(
        device.serialNumber ?? '',
      );
      if (serialNumber == null) continue;
      final result = await authorizationPort.matchesCachedSerial(serialNumber);
      if (result.ok && result.value == true) matches.add(device);
    }
    return List<RecordingCardDiscoveredDevice>.unmodifiable(matches);
  }

  Future<void> connectSingleNearbyDevice() async {
    if (_state.snapshot.deviceState.isOperationallyConnected) return;
    await scanDevices();
    if (_state.status == RecordingCardControllerStatus.error) return;
    final connectable = _state.snapshot.discoveredDevices
        .where((device) => device.isConnectable != false)
        .toList(growable: false);
    if (connectable.isEmpty) {
      _fail(
        recordingCardFailure(
          'RECORDING_CARD_GUIDED_DEVICE_NOT_FOUND',
          'No connectable recording card was discovered for guided connection',
          isRetryable: true,
        ),
      );
      return;
    }
    if (connectable.length != 1) {
      _fail(
        recordingCardFailure(
          'RECORDING_CARD_GUIDED_MULTIPLE_DEVICES',
          'Multiple recording cards were discovered for guided connection',
          isRetryable: true,
        ),
      );
      return;
    }
    final device = connectable.single;
    await connectDiscoveredDevice(device);
  }

  Future<RecordingCardResult<RecordingCardWifiCredentials>> prepareWifiTransfer(
    RecordingCardScannedFile file,
  ) async {
    final port = _port;
    if (port is! RecordingCardWifiTransferPort) {
      return RecordingCardResult<RecordingCardWifiCredentials>.failure(
        recordingCardFailure(
          'RECORDING_CARD_WIFI_UNAVAILABLE',
          'Recording-card Wi-Fi handoff is unavailable',
          isRetryable: false,
        ),
      );
    }
    final wifiPort = port as RecordingCardWifiTransferPort;
    if (!_startControllerOperation(
      status: RecordingCardControllerStatus.preparingWifi,
      kind: RecordingCardOperationKind.wifiTransfer,
    )) {
      return RecordingCardResult<RecordingCardWifiCredentials>.failure(
        _operationAdmissionFailure(),
      );
    }
    final result = await wifiPort.prepareWifiTransfer(file);
    if (!result.ok || result.value == null) {
      _fail(
        result.error ?? _fallbackFailure('RECORDING_CARD_WIFI_PREPARE_FAILED'),
      );
      return result;
    }
    _settleControllerOperation();
    _state = _state.copyWith(
      status: RecordingCardControllerStatus.idle,
      clearActiveFileKey: true,
      lastErrorCode: null,
    );
    notifyListeners();
    return result;
  }

  Future<RecordingCardResult<RecordingCardWifiHandoffResult>>
  verifyWifiHandoff() async {
    final port = _port;
    if (port is! RecordingCardWifiTransferPort) {
      return RecordingCardResult<RecordingCardWifiHandoffResult>.failure(
        recordingCardFailure(
          'RECORDING_CARD_WIFI_UNAVAILABLE',
          'Recording-card Wi-Fi handoff is unavailable',
          isRetryable: false,
        ),
      );
    }
    if (!_startControllerOperation(
      status: RecordingCardControllerStatus.preparingWifi,
      kind: RecordingCardOperationKind.wifiTransfer,
    )) {
      return RecordingCardResult<RecordingCardWifiHandoffResult>.failure(
        _operationAdmissionFailure(),
      );
    }
    final result = await _verifyPreparedWifiHandoff();
    if (!result.ok || result.value == null) {
      _fail(
        result.error ?? _fallbackFailure('RECORDING_CARD_WIFI_CHECK_FAILED'),
      );
      return result;
    }
    _settleControllerOperation();
    _state = _state.copyWith(
      status: RecordingCardControllerStatus.idle,
      clearActiveFileKey: true,
      lastErrorCode: null,
    );
    notifyListeners();
    return result;
  }

  Future<void> scanDevices() {
    if (_disposed ||
        _state.status == RecordingCardControllerStatus.unbinding ||
        (_operationMachine.state.isActive &&
            _operationMachine.state.kind ==
                RecordingCardOperationKind.unbind)) {
      return Future<void>.value();
    }
    final cancellationInFlight = _deviceDiscoveryCancellationInFlight;
    if (cancellationInFlight != null) {
      return cancellationInFlight.then<void>((_) => scanDevices());
    }
    final inFlight = _deviceDiscoveryInFlight;
    if (inFlight != null) return inFlight;
    final requestGeneration = ++_deviceDiscoveryRequestGeneration;
    late final Future<void> request;
    request =
        Future<void>.microtask(
          () => _scanDevicesWhenAdmitted(requestGeneration),
        ).whenComplete(() {
          if (identical(_deviceDiscoveryInFlight, request)) {
            _deviceDiscoveryInFlight = null;
          }
        });
    _deviceDiscoveryInFlight = request;
    return request;
  }

  Future<void> _scanDevicesWhenAdmitted(int requestGeneration) async {
    while (!_disposed &&
        requestGeneration == _deviceDiscoveryRequestGeneration) {
      if (_operationMachine.state.isActive) {
        await _waitForDeviceDiscoveryAdmission();
        continue;
      }
      if (_startControllerOperation(
        status: RecordingCardControllerStatus.scanning,
        kind: RecordingCardOperationKind.discovery,
      )) {
        break;
      }
      await _waitForDeviceDiscoveryAdmission();
    }
    if (_disposed || requestGeneration != _deviceDiscoveryRequestGeneration) {
      return;
    }
    final operation = ++_deviceDiscoveryOperation;
    _state = _state.copyWith(
      snapshot: _state.snapshot.copyWith(
        discoveredDevices: const <RecordingCardDiscoveredDevice>[],
      ),
      lastErrorCode: null,
      clearActiveFileKey: true,
    );
    notifyListeners();
    final permissionFailure = await _permissionCoordinator
        .requestBluetoothAccess();
    if (!_isCurrentDeviceDiscoveryOperation(operation)) return;
    if (permissionFailure != null) {
      _fail(permissionFailure);
      return;
    }
    final result = await _port.scanDevices();
    if (!_isCurrentDeviceDiscoveryOperation(operation)) return;
    if (!result.ok || result.value == null) {
      _fail(result.error ?? _fallbackFailure('RECORDING_CARD_SCAN_FAILED'));
      return;
    }
    _settleControllerOperation();
    _state = _state.copyWith(
      status: RecordingCardControllerStatus.idle,
      snapshot: _state.snapshot.copyWith(discoveredDevices: result.value),
      clearActiveFileKey: true,
      lastErrorCode: null,
    );
    notifyListeners();
    _scheduleDeferredFileRefreshes();
  }

  Future<void> cancelDiscovery() {
    final inFlight = _deviceDiscoveryCancellationInFlight;
    if (inFlight != null) return inFlight;
    if (_disposed) return Future<void>.value();
    late final Future<void> request;
    request = Future<void>.microtask(_cancelDiscoveryOnce).whenComplete(() {
      if (identical(_deviceDiscoveryCancellationInFlight, request)) {
        _deviceDiscoveryCancellationInFlight = null;
      }
    });
    _deviceDiscoveryCancellationInFlight = request;
    return request;
  }

  Future<void> _cancelDiscoveryOnce() async {
    final discoveryRequest = _deviceDiscoveryInFlight;
    final operationLease = _activeControllerOperationLease;
    final ownsActiveDiscovery =
        _operationMachine.state.isActive &&
        _operationMachine.state.kind == RecordingCardOperationKind.discovery &&
        _operationMachine.owns(operationLease);
    if (!ownsActiveDiscovery) {
      if (discoveryRequest == null) return;
      _deviceDiscoveryRequestGeneration += 1;
      _releaseDeviceDiscoveryAdmissionWaiter(force: true);
      await discoveryRequest;
      return;
    }
    _deviceDiscoveryRequestGeneration += 1;
    _releaseDeviceDiscoveryAdmissionWaiter(force: true);
    if (_operationMachine.requestCancellation(operationLease!)) {
      _publishOperationState();
    }
    ++_deviceDiscoveryOperation;
    _state = _state.copyWith(
      status: RecordingCardControllerStatus.idle,
      lastErrorCode: null,
      clearActiveFileKey: true,
    );
    notifyListeners();
    final port = _port;
    if (port is RecordingCardDiscoveryCancellationPort) {
      await (port as RecordingCardDiscoveryCancellationPort).cancelDiscovery();
    }
    if (_disposed) return;
    if (discoveryRequest != null) await discoveryRequest;
    if (_disposed) return;
    if (identical(_activeControllerOperationLease, operationLease)) {
      _activeControllerOperationLease = null;
    }
    _settleDeviceOperation(operationLease);
    notifyListeners();
    _scheduleDeferredFileRefreshes();
  }

  Future<void> refreshDeviceInfo() {
    final inFlight = _deviceInfoRefreshInFlight;
    if (inFlight != null) return inFlight;
    if (!_state.snapshot.deviceState.isOperationallyConnected ||
        _hasRunningTransfer ||
        _scanFilesInFlight != null ||
        (_state.status != RecordingCardControllerStatus.idle &&
            _state.status != RecordingCardControllerStatus.error)) {
      return Future<void>.value();
    }
    final connectionRevision = _connectionRevision;
    final deviceOperation = _deviceDiscoveryOperation;
    final deviceIdentity = _activeConnectionDeviceIdentity(
      _state.snapshot.deviceState,
    );
    if (deviceIdentity == null) return Future<void>.value();
    late final Future<void> operation;
    operation =
        _refreshDeviceInfoForConnection(
          connectionRevision,
          deviceOperation,
          deviceIdentity,
        ).whenComplete(() {
          if (identical(_deviceInfoRefreshInFlight, operation)) {
            _deviceInfoRefreshInFlight = null;
          }
        });
    _deviceInfoRefreshInFlight = operation;
    return operation;
  }

  Future<void> _refreshDeviceInfoForConnection(
    int connectionRevision,
    int deviceOperation,
    String deviceIdentity,
  ) async {
    final admission = _beginDeviceOperation(
      kind: RecordingCardOperationKind.deviceRefresh,
      origin: RecordingCardOperationOrigin.automatic,
    );
    final operationLease = admission.lease;
    if (operationLease == null) return;
    _setBusy(RecordingCardControllerStatus.refreshing);
    final result = await _port.refreshDeviceInfo();
    if (!_ownsConnectionBoundOperation(
      deviceOperation: deviceOperation,
      connectionRevision: connectionRevision,
      deviceIdentity: deviceIdentity,
    )) {
      if (!_disposed &&
          _state.status == RecordingCardControllerStatus.refreshing) {
        _state = _state.copyWith(
          status: RecordingCardControllerStatus.idle,
          clearActiveFileKey: true,
        );
        notifyListeners();
        _scheduleDeferredFileRefreshes();
      }
      _settleDeviceOperation(
        operationLease,
        failureCode: recordingCardOperationSessionChangedCode,
      );
      return;
    }
    if (!result.ok || result.value == null) {
      _fail(
        result.error ?? _fallbackFailure('RECORDING_CARD_REFRESH_FAILED'),
        operationLease: operationLease,
      );
      return;
    }
    _settleDeviceOperation(operationLease);
    final previous = _state.snapshot;
    final normalized = _normalizeRuntimeSnapshot(result.value!);
    _state = _state.copyWith(
      status: RecordingCardControllerStatus.idle,
      snapshot: _preserveDirectoryUntilVerified(normalized),
      lastErrorCode: null,
    );
    notifyListeners();
    _observeConnectionTransition(previous.deviceState, normalized.deviceState);
    _observeRecordingTransition(
      previous.recordingInfo.state,
      normalized.recordingInfo.state,
    );
    _scheduleDeferredFileRefreshes();
  }

  Future<void> readRecordingState() =>
      _runRecordingCommand(_port.readRecordingState);

  Future<void> startRecording({
    String? expectedDeviceFingerprint,
    bool Function()? canExecute,
  }) => _runRecordingCommand(
    _port.startRecording,
    expectedDeviceFingerprint: expectedDeviceFingerprint,
    canExecute: canExecute,
  );

  Future<void> pauseRecording({
    String? expectedDeviceFingerprint,
    bool Function()? canExecute,
  }) => _runRecordingCommand(
    _port.pauseRecording,
    expectedDeviceFingerprint: expectedDeviceFingerprint,
    canExecute: canExecute,
  );

  Future<void> resumeRecording({
    String? expectedDeviceFingerprint,
    bool Function()? canExecute,
  }) => _runRecordingCommand(
    _port.resumeRecording,
    expectedDeviceFingerprint: expectedDeviceFingerprint,
    canExecute: canExecute,
  );

  Future<void> stopRecording() => _runRecordingCommand(_port.stopRecording);

  Future<void> scanFiles() =>
      refreshFiles(reason: RecordingCardFileRefreshReason.manual);

  void cancelFileRefresh() {
    if (!isRefreshingFiles) return;
    final operationLease = _fileRefreshOperationLease;
    if (operationLease != null &&
        _operationMachine.requestCancellation(operationLease)) {
      _publishOperationState();
    }
    _activeFileScanConnectionRevision = -1;
    _scanFilesRequested = false;
    _pendingFileRefreshReasons.clear();
    _state = _state.copyWith(
      fileCatalog: _state.fileCatalog.transition(
        RecordingCardFileCatalogPhase.failed,
        errorCode: 'RECORDING_CARD_SCAN_CANCELLED',
      ),
      lastErrorCode: null,
      clearActiveFileKey: true,
    );
    notifyListeners();
  }

  Future<void> ensureFilesLoadedForCurrentConnection() {
    if (!_state.snapshot.deviceState.isOperationallyConnected) {
      return Future.value();
    }
    if (_connectionScanRevisionInFlight == _connectionRevision ||
        (_scanFilesInFlight != null &&
            _activeFileScanConnectionRevision == _connectionRevision)) {
      return _scanFilesInFlight ?? Future.value();
    }
    return _autoScanAttemptedConnectionRevision == _connectionRevision
        ? Future.value()
        : refreshFiles(reason: RecordingCardFileRefreshReason.connection);
  }

  Future<void> refreshFiles({required RecordingCardFileRefreshReason reason}) {
    return _refreshFiles(reason: reason);
  }

  Future<void> _refreshFiles({
    required RecordingCardFileRefreshReason reason,
    bool wifiBleRecoveryOwner = false,
    int? pendingBluetoothResumeGeneration,
  }) {
    if (_disposed ||
        _state.snapshot.recordingInfo.state !=
            RecordingCardRecordingState.idle) {
      return Future<void>.value();
    }
    final ownsWifiBleRecovery =
        wifiBleRecoveryOwner && _wifiBleRecoveryInFlight;
    final ownsPendingBluetoothResume = _ownsPendingBluetoothResumeFileRefresh(
      pendingBluetoothResumeGeneration,
    );
    final ownsTransportRecovery =
        ownsWifiBleRecovery || ownsPendingBluetoothResume;
    final operationOrigin = reason == RecordingCardFileRefreshReason.manual
        ? RecordingCardOperationOrigin.user
        : RecordingCardOperationOrigin.automatic;
    final hasFileRefreshConflict =
        _hasRunningTransfer || _wifiBatchRestoreInFlight != null;
    if (hasFileRefreshConflict && !ownsTransportRecovery) {
      _blockDeviceOperation(
        kind: RecordingCardOperationKind.directoryRefresh,
        origin: operationOrigin,
      );
      if (reason == RecordingCardFileRefreshReason.connection &&
          _state.snapshot.deviceState.isOperationallyConnected) {
        _deferredConnectionFileRefreshRevision = _connectionRevision;
      }
      if (reason == RecordingCardFileRefreshReason.recordingCompleted) {
        _recordingCompletionRefreshRequested = true;
      }
      if (reason == RecordingCardFileRefreshReason.appResumed) {
        _appResumeFileRefreshRequested = true;
      }
      if (operationOrigin == RecordingCardOperationOrigin.user) {
        _reportOperationBlocked();
      }
      return Future<void>.value();
    }
    if (reason == RecordingCardFileRefreshReason.connection &&
        (_autoScanAttemptedConnectionRevision == _connectionRevision ||
            _connectionScanRevisionInFlight == _connectionRevision)) {
      return _scanFilesInFlight ?? Future<void>.value();
    }
    final inFlight = _scanFilesInFlight;
    if (inFlight != null) {
      if (reason == RecordingCardFileRefreshReason.connection) {
        if (_activeFileScanConnectionRevision != _connectionRevision) {
          _pendingFileRefreshReasons.add(reason);
          _scanFilesRequested = true;
        }
        _autoScanAttemptedConnectionRevision = _connectionRevision;
        _connectionScanRevisionInFlight = _connectionRevision;
        return inFlight;
      }
      final requiresTrailingRefresh =
          reason == RecordingCardFileRefreshReason.recordingCompleted ||
          reason == RecordingCardFileRefreshReason.transferCompleted ||
          reason == RecordingCardFileRefreshReason.deviceDeleted;
      if (requiresTrailingRefresh &&
          !_activeFileRefreshReasons.contains(reason)) {
        _pendingFileRefreshReasons.add(reason);
        _scanFilesRequested = true;
      }
      return inFlight;
    }
    final deviceInfoRefresh = _deviceInfoRefreshInFlight;
    if (deviceInfoRefresh != null) {
      return deviceInfoRefresh.then(
        (_) => _refreshFiles(
          reason: reason,
          wifiBleRecoveryOwner: wifiBleRecoveryOwner,
          pendingBluetoothResumeGeneration: pendingBluetoothResumeGeneration,
        ),
      );
    }
    if (_state.status != RecordingCardControllerStatus.idle &&
        _state.status != RecordingCardControllerStatus.error) {
      _blockDeviceOperation(
        kind: RecordingCardOperationKind.directoryRefresh,
        origin: operationOrigin,
      );
      if (reason == RecordingCardFileRefreshReason.connection &&
          _state.snapshot.deviceState.isOperationallyConnected) {
        _deferredConnectionFileRefreshRevision = _connectionRevision;
      }
      if (reason == RecordingCardFileRefreshReason.recordingCompleted) {
        _recordingCompletionRefreshRequested = true;
      }
      if (reason == RecordingCardFileRefreshReason.appResumed) {
        _appResumeFileRefreshRequested = true;
      }
      if (operationOrigin == RecordingCardOperationOrigin.user) {
        _reportOperationBlocked();
      }
      return Future<void>.value();
    }
    if (reason == RecordingCardFileRefreshReason.connection) {
      _autoScanAttemptedConnectionRevision = _connectionRevision;
      _connectionScanRevisionInFlight = _connectionRevision;
    }
    _pendingFileRefreshReasons.add(reason);
    _scanFilesRequested = true;
    if (!ownsTransportRecovery) {
      final admission = _beginDeviceOperation(
        kind: RecordingCardOperationKind.directoryRefresh,
        origin: operationOrigin,
      );
      final lease = admission.lease;
      if (lease == null) {
        _scanFilesRequested = false;
        _pendingFileRefreshReasons.remove(reason);
        if (reason == RecordingCardFileRefreshReason.connection) {
          _deferredConnectionFileRefreshRevision = _connectionRevision;
        } else if (reason ==
            RecordingCardFileRefreshReason.recordingCompleted) {
          _recordingCompletionRefreshRequested = true;
        } else if (reason == RecordingCardFileRefreshReason.appResumed) {
          _appResumeFileRefreshRequested = true;
        }
        if (operationOrigin == RecordingCardOperationOrigin.user) {
          _reportOperationBlocked();
        }
        return Future<void>.value();
      }
      _fileRefreshOperationLease = lease;
    }
    final completer = Completer<void>();
    final operation = completer.future;
    _scanFilesInFlight = operation;
    unawaited(_completeFileRefreshDrain(completer, operation));
    return operation;
  }

  Future<void> _completeFileRefreshDrain(
    Completer<void> completer,
    Future<void> operation,
  ) async {
    Object? failure;
    StackTrace? failureStackTrace;
    try {
      await _drainFileRefreshes();
    } catch (error, stackTrace) {
      failure = error;
      failureStackTrace = stackTrace;
    } finally {
      if (identical(_scanFilesInFlight, operation)) {
        final operationLease = _fileRefreshOperationLease;
        _fileRefreshOperationLease = null;
        final failureCode =
            _state.fileCatalog.phase == RecordingCardFileCatalogPhase.failed
            ? _state.fileCatalog.errorCode
            : null;
        _settleDeviceOperation(operationLease, failureCode: failureCode);
        _scanFilesInFlight = null;
        _connectionScanRevisionInFlight = -1;
        if (_state.status == RecordingCardControllerStatus.scanning &&
            _state.fileCatalog.phase == RecordingCardFileCatalogPhase.ready) {
          _state = _state.copyWith(
            status: RecordingCardControllerStatus.idle,
            clearActiveFileKey: true,
          );
        }
        if (!_disposed) notifyListeners();
        _scheduleDeferredFileRefreshes();
      }
    }
    if (failure == null) {
      completer.complete();
    } else {
      completer.completeError(failure, failureStackTrace!);
    }
  }

  Future<void> _drainFileRefreshes() async {
    while (_scanFilesRequested) {
      _scanFilesRequested = false;
      _activeFileRefreshReasons
        ..clear()
        ..addAll(_pendingFileRefreshReasons);
      _pendingFileRefreshReasons.clear();
      final fileRefreshLease = _fileRefreshOperationLease;
      if (fileRefreshLease != null &&
          fileRefreshLease.connectionRevision != _connectionRevision) {
        final admission = _operationMachine.supersede(
          kind: RecordingCardOperationKind.directoryRefresh,
          origin:
              _activeFileRefreshReasons.contains(
                RecordingCardFileRefreshReason.manual,
              )
              ? RecordingCardOperationOrigin.user
              : RecordingCardOperationOrigin.automatic,
          connectionRevision: _connectionRevision,
        );
        _fileRefreshOperationLease = admission.lease;
        _publishOperationState();
      }
      _activeFileScanConnectionRevision = _connectionRevision;
      try {
        await _scanFilesOnce();
      } finally {
        _activeFileRefreshReasons.clear();
        _activeFileScanConnectionRevision = -1;
      }
    }
  }

  Future<void> _scanFilesOnce() async {
    final scanDeviceOperation = _deviceDiscoveryOperation;
    final scanConnectionRevision =
        _state.snapshot.deviceState.isOperationallyConnected
        ? _connectionRevision
        : -1;
    final scanDeviceIdentity = _activeConnectionDeviceIdentity(
      _state.snapshot.deviceState,
    );
    if (scanConnectionRevision >= 0) {
      _autoScanAttemptedConnectionRevision = scanConnectionRevision;
    }
    if (scanConnectionRevision < 0 || scanDeviceIdentity == null) {
      _failFileCatalog(
        recordingCardFailure(
          'RECORDING_CARD_DEVICE_IDENTITY_UNAVAILABLE',
          'Recording-card stable identity is unavailable',
          isRetryable: true,
        ),
      );
      return;
    }
    _appResumeFileRefreshRequested = false;
    _state = _state.copyWith(
      status: RecordingCardControllerStatus.scanning,
      fileCatalog: RecordingCardFileCatalogState(
        phase: RecordingCardFileCatalogPhase.reading,
        connectionRevision: scanConnectionRevision,
        deviceIdentity: scanDeviceIdentity,
      ),
      lastErrorCode: null,
      clearActiveFileKey: true,
    );
    notifyListeners();
    late final RecordingCardResult<List<RecordingCardScannedFile>> result;
    final isWifiRecoveryScan =
        (_wifiBleRecoveryInFlight &&
            _activeFileRefreshReasons.contains(
              RecordingCardFileRefreshReason.transferCompleted,
            )) ||
        _pendingBluetoothResumeFileRefreshGeneration != null;
    try {
      final scan = _port.scanFiles();
      result = isWifiRecoveryScan
          ? await scan.timeout(_wifiBleRecoveryTimeout)
          : await scan;
    } on TimeoutException catch (error) {
      result = RecordingCardResult<List<RecordingCardScannedFile>>.failure(
        recordingCardFailure(
          'RECORDING_CARD_WIFI_BLE_DIRECTORY_TIMEOUT',
          'Recording-card directory recovery timed out',
          cause: error,
          isRetryable: true,
        ),
      );
    }
    if (scanConnectionRevision != _activeFileScanConnectionRevision) return;
    if (!_ownsFileCatalogWork(
      scanConnectionRevision,
      scanDeviceIdentity,
      deviceOperation: scanDeviceOperation,
    )) {
      _retainConnectionRefreshAfterScanOwnershipLoss(
        scanConnectionRevision,
        scanDeviceIdentity,
      );
      return;
    }
    if (!result.ok || result.value == null) {
      _failFileCatalog(
        result.error ?? _fallbackFailure('RECORDING_CARD_SCAN_FAILED'),
      );
      return;
    }
    _state = _state.copyWith(
      fileCatalog: _state.fileCatalog.transition(
        RecordingCardFileCatalogPhase.verifying,
      ),
    );
    notifyListeners();
    AppFailure? verificationFailure;
    try {
      final verification = _refreshVerifiedDownloadCache();
      verificationFailure = isWifiRecoveryScan
          ? await verification.timeout(_wifiBleRecoveryTimeout)
          : await verification;
    } on TimeoutException catch (error) {
      verificationFailure = recordingCardFailure(
        'RECORDING_CARD_WIFI_BLE_LOCAL_VERIFICATION_TIMEOUT',
        'Local recording verification timed out after Wi-Fi transfer',
        cause: error,
        isRetryable: true,
      );
    }
    if (scanConnectionRevision != _activeFileScanConnectionRevision) return;
    if (!_ownsFileCatalogWork(
      scanConnectionRevision,
      scanDeviceIdentity,
      deviceOperation: scanDeviceOperation,
    )) {
      _retainConnectionRefreshAfterScanOwnershipLoss(
        scanConnectionRevision,
        scanDeviceIdentity,
      );
      return;
    }
    if (verificationFailure != null) {
      _failFileCatalog(verificationFailure);
      return;
    }
    final files = _restoreVerifiedDownloads(
      result.value!,
      _state.snapshot.deviceState,
    );
    _loadedFileDirectoryConnectionRevision = scanConnectionRevision;
    _successfulFileRefreshRevision += 1;
    _state = _state.copyWith(
      snapshot: _state.snapshot.copyWith(files: files),
      fileCatalog: _state.fileCatalog.transition(
        RecordingCardFileCatalogPhase.ready,
      ),
      clearActiveFileKey: true,
      lastErrorCode: null,
    );
    notifyListeners();
    _schedulePendingBluetoothResume();
  }

  Future<void> syncFileToLocal(RecordingCardScannedFile file) async {
    await downloadFileResult(file);
  }

  Future<void> downloadFile(
    RecordingCardScannedFile file, {
    bool refreshAfterTransfer = true,
    RecordingCardOperationOrigin origin = RecordingCardOperationOrigin.user,
  }) async {
    await downloadFileResult(
      file,
      refreshAfterTransfer: refreshAfterTransfer,
      origin: origin,
    );
  }

  Future<RecordingCardResult<RecordingCardDownloadedFile>> downloadFileResult(
    RecordingCardScannedFile file, {
    bool refreshAfterTransfer = true,
    RecordingCardOperationOrigin origin = RecordingCardOperationOrigin.user,
  }) async {
    if (!_beginTransfer(
      kind: RecordingCardOperationKind.bluetoothTransfer,
      origin: origin,
    )) {
      _reportOperationBlocked();
      return RecordingCardResult<RecordingCardDownloadedFile>.failure(
        _fallbackFailure(
          _operationMachine.state.blockCode ??
              'RECORDING_CARD_TRANSFER_OPERATION_BLOCKED',
        ),
      );
    }
    final latchGeneration = _transferLatchGeneration;
    final operationLease = _activeTransferOperationLease!;
    bool ownsOperation() =>
        !_disposed &&
        _transferInFlight &&
        latchGeneration == _transferLatchGeneration &&
        identical(_activeTransferOperationLease, operationLease) &&
        operationLease.connectionRevision == _connectionRevision &&
        _operationMachine.state.phase == RecordingCardOperationPhase.running &&
        _operationMachine.owns(operationLease);
    final owner = _captureVerifiedTransferOwner(file);
    if (owner == null) {
      _releaseTransferLatch(latchGeneration);
      final failure = _singleFileTransferPreconditionFailure();
      _fail(failure);
      return RecordingCardResult<RecordingCardDownloadedFile>.failure(failure);
    }
    _RecordingCardBluetoothBatchOwner? manualLedgerOwner;
    _RecordingCardManualSyncTarget? manualLedgerTarget;
    if (origin == RecordingCardOperationOrigin.user) {
      manualLedgerOwner = _captureVerifiedBluetoothBatchOwner(
        <RecordingCardScannedFile>[file],
      );
      if (manualLedgerOwner == null) {
        _releaseTransferLatch(latchGeneration);
        final failure = _singleFileTransferPreconditionFailure();
        _fail(failure);
        return RecordingCardResult<RecordingCardDownloadedFile>.failure(
          failure,
        );
      }
      final targets = <String, _RecordingCardManualSyncTarget>{};
      final queueFailure = await _queueManualBluetoothBatch(
        manualLedgerOwner,
        <RecordingCardScannedFile>[file],
        targets,
      );
      if (!ownsOperation()) {
        _releaseTransferLatch(latchGeneration);
        return RecordingCardResult<RecordingCardDownloadedFile>.failure(
          _fallbackFailure(
            _manualBluetoothCancellationRequested
                ? 'RECORDING_CARD_TRANSFER_CANCELLED'
                : 'RECORDING_CARD_BLUETOOTH_RESUME_SUPERSEDED',
          ),
        );
      }
      manualLedgerTarget = targets[_recordingCardFileSignature(file)];
      final beginFailure =
          queueFailure ??
          await _beginManualBluetoothSync(
            manualLedgerOwner,
            manualLedgerTarget,
          );
      if (beginFailure != null || !ownsOperation()) {
        final recoveryFailure = await _deferManualBluetoothBatch(
          manualLedgerOwner,
          <RecordingCardScannedFile>[file],
          resumeRequested: !_manualBluetoothCancellationRequested,
        );
        _releaseTransferLatch(latchGeneration);
        final effectiveFailure =
            recoveryFailure ??
            beginFailure ??
            _fallbackFailure(
              _manualBluetoothCancellationRequested
                  ? 'RECORDING_CARD_TRANSFER_CANCELLED'
                  : 'RECORDING_CARD_BLUETOOTH_RESUME_SUPERSEDED',
            );
        _fail(effectiveFailure);
        return RecordingCardResult<RecordingCardDownloadedFile>.failure(
          effectiveFailure,
        );
      }
    }
    final activeLedgerSignatures = manualLedgerTarget == null
        ? const <String>{}
        : Set<String>.unmodifiable(<String>{
            manualLedgerTarget.sourceSignature,
          });
    if (activeLedgerSignatures.isNotEmpty) {
      _activeManualBluetoothLedgerSignatures = activeLedgerSignatures;
    }
    _state = _state.copyWith(
      status: RecordingCardControllerStatus.downloading,
      activeFileKey: file.localFileKey,
      lastErrorCode: null,
      clearLastDownloadedFile: true,
    );
    notifyListeners();
    late RecordingCardResult<RecordingCardDownloadedFile> settled;
    try {
      late final RecordingCardResult<RecordingCardDownloadedFile> result;
      try {
        result = await _downloadBluetoothFileWithRecovery(
          file,
          origin: origin,
          sourceSignature: manualLedgerTarget?.sourceSignature,
          ownsTransfer: ownsOperation,
        );
      } on Object catch (error) {
        result = RecordingCardResult<RecordingCardDownloadedFile>.failure(
          recordingCardFailure(
            'RECORDING_CARD_DOWNLOAD_FAILED',
            'Recording-card Bluetooth download threw unexpectedly',
            cause: error,
            isRetryable: true,
          ),
        );
      }
      settled = await _handleDownloadedResult(result, file, owner);
      if (manualLedgerOwner != null) {
        AppFailure? ledgerFailure;
        final downloaded = settled.value;
        if (settled.ok && downloaded != null) {
          ledgerFailure = await _completeManualBluetoothSync(
            manualLedgerOwner,
            manualLedgerTarget,
            downloaded,
          );
        } else {
          final failureCode =
              settled.error?.code ?? 'RECORDING_CARD_TRANSFER_FAILED';
          if (_manualBluetoothCancellationRequested ||
              !_ownsBluetoothBatchOwner(manualLedgerOwner) ||
              _isRecordingCardDisconnectFailureCode(failureCode)) {
            ledgerFailure = await _deferManualBluetoothBatch(
              manualLedgerOwner,
              <RecordingCardScannedFile>[file],
              resumeRequested: !_manualBluetoothCancellationRequested,
            );
          } else {
            ledgerFailure = await _failManualBluetoothSync(
              manualLedgerOwner,
              manualLedgerTarget,
              failureCode,
            );
          }
        }
        if (ledgerFailure != null) {
          final recoveryFailure = await _deferManualBluetoothBatch(
            manualLedgerOwner,
            <RecordingCardScannedFile>[file],
          );
          final effectiveFailure = recoveryFailure ?? ledgerFailure;
          settled = RecordingCardResult<RecordingCardDownloadedFile>.failure(
            effectiveFailure,
          );
          _fail(effectiveFailure);
        }
      }
    } finally {
      if (identical(
        _activeManualBluetoothLedgerSignatures,
        activeLedgerSignatures,
      )) {
        _activeManualBluetoothLedgerSignatures = const <String>{};
      }
      _releaseTransferLatch(latchGeneration);
    }
    if (refreshAfterTransfer &&
        settled.ok &&
        settled.value != null &&
        _ownsTransferOwner(owner)) {
      await _refreshAfterBleTransfer();
    }
    return settled;
  }

  Future<RecordingCardResult<RecordingCardBluetoothBatchResult>>
  downloadFilesOverBluetooth(List<RecordingCardScannedFile> files) =>
      _downloadFilesOverBluetooth(files);

  Future<RecordingCardResult<RecordingCardBluetoothBatchResult>>
  _downloadFilesOverBluetooth(
    List<RecordingCardScannedFile> files, {
    int? preclaimedLatchGeneration,
    RecordingCardOperationLease? preclaimedOperationLease,
    RecordingCardOperationOrigin ledgerOrigin =
        RecordingCardOperationOrigin.user,
  }) async {
    final hasPreclaimedLatch = preclaimedLatchGeneration != null;
    final hasPreclaimedLease = preclaimedOperationLease != null;
    if (hasPreclaimedLatch != hasPreclaimedLease) {
      if (preclaimedLatchGeneration case final latchGeneration?) {
        _releaseTransferLatch(latchGeneration);
      }
      return RecordingCardResult<RecordingCardBluetoothBatchResult>.failure(
        _fallbackFailure('RECORDING_CARD_BLUETOOTH_RESUME_SUPERSEDED'),
      );
    }
    final requestedFiles = List<RecordingCardScannedFile>.unmodifiable(files);
    if (requestedFiles.isEmpty) {
      if (preclaimedLatchGeneration case final latchGeneration?) {
        _releaseTransferLatch(latchGeneration);
      }
      return RecordingCardResult<RecordingCardBluetoothBatchResult>.failure(
        _fallbackFailure('RECORDING_CARD_BLUETOOTH_BATCH_EMPTY'),
      );
    }
    late final int latchGeneration;
    late final RecordingCardOperationLease operationLease;
    if (preclaimedLatchGeneration case final preclaimedLatch?) {
      final preclaimedLease = preclaimedOperationLease!;
      final operation = _operationMachine.state;
      final ownsPreclaimedTransfer =
          !_disposed &&
          _transferInFlight &&
          preclaimedLatch == _transferLatchGeneration &&
          identical(_activeTransferOperationLease, preclaimedLease) &&
          preclaimedLease.kind ==
              RecordingCardOperationKind.bluetoothTransfer &&
          preclaimedLease.connectionRevision == _connectionRevision &&
          operation.phase == RecordingCardOperationPhase.running &&
          _operationMachine.owns(preclaimedLease);
      if (!ownsPreclaimedTransfer) {
        _releaseTransferLatch(preclaimedLatch);
        return RecordingCardResult<RecordingCardBluetoothBatchResult>.failure(
          _fallbackFailure('RECORDING_CARD_BLUETOOTH_RESUME_SUPERSEDED'),
        );
      }
      latchGeneration = preclaimedLatch;
      operationLease = preclaimedLease;
    } else {
      if (!_beginTransfer(
        kind: RecordingCardOperationKind.bluetoothTransfer,
        origin: ledgerOrigin,
      )) {
        _reportOperationBlocked();
        return RecordingCardResult<RecordingCardBluetoothBatchResult>.failure(
          _operationAdmissionFailure(),
        );
      }
      latchGeneration = _transferLatchGeneration;
      operationLease = _activeTransferOperationLease!;
    }
    bool ownsOperation() =>
        !_disposed &&
        _transferInFlight &&
        latchGeneration == _transferLatchGeneration &&
        identical(_activeTransferOperationLease, operationLease) &&
        operationLease.connectionRevision == _connectionRevision &&
        _operationMachine.state.phase == RecordingCardOperationPhase.running &&
        _operationMachine.owns(operationLease);
    bool ownsLedgerSettlement() =>
        !_disposed &&
        _transferInFlight &&
        latchGeneration == _transferLatchGeneration &&
        identical(_activeTransferOperationLease, operationLease);
    final owner = _captureVerifiedBluetoothBatchOwner(requestedFiles);
    if (owner == null || !ownsOperation()) {
      final failure = _singleFileTransferPreconditionFailure();
      _releaseTransferLatch(latchGeneration);
      if (owner == null) _fail(failure);
      return RecordingCardResult<RecordingCardBluetoothBatchResult>.failure(
        owner == null
            ? failure
            : _fallbackFailure('RECORDING_CARD_BLUETOOTH_RESUME_SUPERSEDED'),
      );
    }
    final canonicalFiles = _canonicalBluetoothBatchFiles(requestedFiles, owner);
    if (canonicalFiles == null) {
      final failure = recordingCardFailure(
        'RECORDING_CARD_FILE_SELECTION_STALE',
        'Selected recording-card files no longer match the verified directory',
        isRetryable: true,
      );
      _releaseTransferLatch(latchGeneration);
      _fail(failure);
      return RecordingCardResult<RecordingCardBluetoothBatchResult>.failure(
        failure,
      );
    }
    final targets = <String, _RecordingCardManualSyncTarget>{};
    final initializationFailure = await _queueManualBluetoothBatch(
      owner,
      canonicalFiles,
      targets,
    );
    if (initializationFailure != null || !ownsOperation()) {
      _releaseTransferLatch(latchGeneration);
      if (initializationFailure != null) _fail(initializationFailure);
      return RecordingCardResult<RecordingCardBluetoothBatchResult>.failure(
        initializationFailure ??
            _fallbackFailure('RECORDING_CARD_BLUETOOTH_RESUME_SUPERSEDED'),
      );
    }
    final activeLedgerSignatures = Set<String>.unmodifiable(
      targets.values.map((target) => target.sourceSignature),
    );
    _activeManualBluetoothLedgerSignatures = activeLedgerSignatures;

    final completedFiles = <RecordingCardScannedFile>[];
    final failureCodes = <String, String>{};
    String? interruptionCode;
    var shouldRefresh = false;

    Future<void> deferTail(int index) async {
      final deferredFiles = canonicalFiles.skip(index).toList(growable: false);
      if (deferredFiles.isEmpty) return;
      final recoveryFailure = await _deferManualBluetoothBatch(
        owner,
        deferredFiles,
        resumeRequested: !_manualBluetoothCancellationRequested,
      );
      if (recoveryFailure == null) return;
      interruptionCode = recoveryFailure.code;
      for (final deferredFile in deferredFiles) {
        failureCodes.putIfAbsent(
          deferredFile.deviceFileId,
          () => recoveryFailure.code,
        );
      }
    }

    try {
      for (var index = 0; index < canonicalFiles.length; index += 1) {
        final file = canonicalFiles[index];
        final fileSignature = _recordingCardFileSignature(file);
        final target = targets[fileSignature];
        final cancellationRequested = _manualBluetoothCancellationRequested;
        final operationOwned = ownsOperation();
        if (cancellationRequested ||
            !operationOwned ||
            !_ownsBluetoothBatchOwner(owner)) {
          interruptionCode = cancellationRequested
              ? 'RECORDING_CARD_TRANSFER_CANCELLED'
              : _state.snapshot.deviceState.isOperationallyConnected
              ? recordingCardOperationSessionChangedCode
              : 'RECORDING_CARD_DISCONNECTED';
          if (ownsLedgerSettlement() && !cancellationRequested) {
            await deferTail(index);
          }
          break;
        }

        final beginFailure = await _beginManualBluetoothSync(owner, target);
        final ownsAfterBegin = ownsOperation();
        if (beginFailure != null || !ownsAfterBegin) {
          interruptionCode =
              beginFailure?.code ??
              (_manualBluetoothCancellationRequested
                  ? 'RECORDING_CARD_TRANSFER_CANCELLED'
                  : 'RECORDING_CARD_BLUETOOTH_RESUME_SUPERSEDED');
          if (beginFailure != null) {
            failureCodes[file.deviceFileId] = beginFailure.code;
          }
          if (ownsLedgerSettlement() &&
              !_manualBluetoothCancellationRequested) {
            await deferTail(index);
          }
          break;
        }
        _state = _state.copyWith(
          status: RecordingCardControllerStatus.downloading,
          activeFileKey: file.localFileKey,
          lastErrorCode: null,
          clearLastDownloadedFile: true,
        );
        notifyListeners();

        RecordingCardResult<RecordingCardDownloadedFile> nativeResult;
        try {
          nativeResult = await _downloadBluetoothFileWithRecovery(
            file,
            origin: ledgerOrigin,
            sourceSignature: target?.sourceSignature,
            ownsTransfer: ownsOperation,
          );
        } on Object catch (error) {
          nativeResult =
              RecordingCardResult<RecordingCardDownloadedFile>.failure(
                recordingCardFailure(
                  'RECORDING_CARD_DOWNLOAD_FAILED',
                  'Recording-card Bluetooth download threw unexpectedly',
                  cause: error,
                  isRetryable: true,
                ),
              );
        }
        if (!ownsOperation()) {
          final disconnected =
              !_state.snapshot.deviceState.isOperationallyConnected;
          interruptionCode = _manualBluetoothCancellationRequested
              ? 'RECORDING_CARD_TRANSFER_CANCELLED'
              : disconnected
              ? 'RECORDING_CARD_DISCONNECTED'
              : recordingCardOperationSessionChangedCode;
          if (ownsLedgerSettlement() &&
              !_manualBluetoothCancellationRequested) {
            await deferTail(index);
          }
          break;
        }
        final settled = await _handleDownloadedResult(
          nativeResult,
          file,
          owner.ownerFor(file),
        );
        final downloaded = settled.value;
        if (settled.ok &&
            downloaded != null &&
            downloaded.localFileKey == file.localFileKey) {
          if (!ownsOperation()) {
            interruptionCode = _manualBluetoothCancellationRequested
                ? 'RECORDING_CARD_TRANSFER_CANCELLED'
                : recordingCardOperationSessionChangedCode;
            break;
          }
          final completionFailure = await _completeManualBluetoothSync(
            owner,
            target,
            downloaded,
          );
          if (completionFailure != null) {
            failureCodes[file.deviceFileId] = completionFailure.code;
            interruptionCode = completionFailure.code;
            await deferTail(index);
            break;
          }
          completedFiles.add(file);
          shouldRefresh = true;
          if (_manualBluetoothCancellationRequested ||
              !ownsOperation() ||
              !_ownsBluetoothBatchOwner(owner)) {
            interruptionCode = _manualBluetoothCancellationRequested
                ? 'RECORDING_CARD_TRANSFER_CANCELLED'
                : _state.snapshot.deviceState.isOperationallyConnected
                ? recordingCardOperationSessionChangedCode
                : 'RECORDING_CARD_DISCONNECTED';
            if (ownsLedgerSettlement() &&
                !_manualBluetoothCancellationRequested) {
              await deferTail(index + 1);
            }
            break;
          }
          continue;
        }

        final failureCode =
            settled.error?.code ?? 'RECORDING_CARD_TRANSFER_FAILED';
        final interrupted =
            _manualBluetoothCancellationRequested ||
            !ownsOperation() ||
            !_ownsBluetoothBatchOwner(owner) ||
            _isRecordingCardDisconnectFailureCode(failureCode);
        if (interrupted) {
          interruptionCode = _manualBluetoothCancellationRequested
              ? 'RECORDING_CARD_TRANSFER_CANCELLED'
              : _isRecordingCardDisconnectFailureCode(failureCode)
              ? 'RECORDING_CARD_DISCONNECTED'
              : recordingCardOperationSessionChangedCode;
          if (ownsLedgerSettlement() &&
              !_manualBluetoothCancellationRequested) {
            await deferTail(index);
          }
          break;
        }
        failureCodes[file.deviceFileId] = failureCode;
        final ledgerFailure = await _failManualBluetoothSync(
          owner,
          target,
          failureCode,
        );
        if (ledgerFailure != null) {
          failureCodes[file.deviceFileId] = ledgerFailure.code;
          interruptionCode = ledgerFailure.code;
          await deferTail(index);
          break;
        }
      }
    } finally {
      if (interruptionCode == 'RECORDING_CARD_TRANSFER_CANCELLED') {
        _state = _state.copyWith(
          lastErrorCode: 'RECORDING_CARD_TRANSFER_CANCELLED',
        );
      } else if (_isRecordingCardDisconnectFailureCode(interruptionCode)) {
        final lease = _activeTransferOperationLease;
        if (lease != null && _operationMachine.owns(lease)) {
          _operationMachine.interrupt(
            lease,
            errorCode: 'RECORDING_CARD_DISCONNECTED',
          );
          _publishOperationState();
        }
      }
      if (identical(
        _activeManualBluetoothLedgerSignatures,
        activeLedgerSignatures,
      )) {
        _activeManualBluetoothLedgerSignatures = const <String>{};
      }
      _releaseTransferLatch(latchGeneration);
    }

    if (shouldRefresh && _ownsBluetoothBatchOwner(owner)) {
      await _refreshAfterBleTransfer();
    }
    final completedSignatures = completedFiles
        .map(_recordingCardFileSignature)
        .toSet();
    final remainingFiles = canonicalFiles
        .where(
          (file) =>
              !completedSignatures.contains(_recordingCardFileSignature(file)),
        )
        .toList(growable: false);
    return RecordingCardResult<RecordingCardBluetoothBatchResult>.success(
      RecordingCardBluetoothBatchResult(
        requestedFiles: List<RecordingCardScannedFile>.unmodifiable(
          canonicalFiles,
        ),
        completedFiles: List<RecordingCardScannedFile>.unmodifiable(
          completedFiles,
        ),
        remainingFiles: List<RecordingCardScannedFile>.unmodifiable(
          remainingFiles,
        ),
        failureCodes: Map<String, String>.unmodifiable(failureCodes),
        interruptionCode: interruptionCode,
      ),
    );
  }

  Future<void> cancelFileTransfer() {
    final running = _directTransferCancellationInFlight;
    if (running != null) return running;
    late final Future<void> operation;
    operation = _cancelDirectFileTransfer().whenComplete(() {
      if (identical(_directTransferCancellationInFlight, operation)) {
        _directTransferCancellationInFlight = null;
        _observedTransferCancellationLease = null;
      }
    });
    _directTransferCancellationInFlight = operation;
    return operation;
  }

  Future<void> _cancelDirectFileTransfer() async {
    if (_disposed) return;
    final batch = _wifiBatchCoordinator.snapshot;
    if (recordingCardWifiBatchIsBluetoothHandoff(batch)) {
      await cancelWifiBatch();
      return;
    }
    if (batch != null && !batch.isTerminal) {
      await cancelWifiBatch();
      return;
    }
    final port = _port;
    final ownedTransfer = _activeTransferOperationLease;
    if (ownedTransfer != null &&
        ownedTransfer.kind != RecordingCardOperationKind.bluetoothTransfer &&
        ownedTransfer.kind != RecordingCardOperationKind.wifiTransfer) {
      return;
    }
    if (ownedTransfer == null &&
        _state.snapshot.downloadingFileKey == null &&
        _state.snapshot.transferProgress == null) {
      return;
    }
    if (port is! RecordingCardCancelableTransferPort) {
      _state = _state.copyWith(
        lastErrorCode: 'RECORDING_CARD_TRANSFER_CANCEL_UNAVAILABLE',
      );
      notifyListeners();
      return;
    }
    final lease =
        ownedTransfer ??
        _beginDeviceOperation(
          kind: RecordingCardOperationKind.bluetoothTransfer,
          origin: RecordingCardOperationOrigin.user,
        ).lease;
    if (lease == null || !_operationMachine.owns(lease)) return;
    if (ownedTransfer == null) _observedTransferCancellationLease = lease;
    final revision = _connectionRevision;
    final previousStatus = _state.status;
    final previousFileKey = _state.activeFileKey;
    _operationMachine.requestCancellation(lease);
    _publishOperationState();
    _state = _state.copyWith(
      status: RecordingCardControllerStatus.cancellingTransfer,
      lastErrorCode: null,
    );
    notifyListeners();
    if (lease.origin == RecordingCardOperationOrigin.user) {
      final persistenceFailure = await _clearBluetoothResumeRequests(
        previousFileKey,
      );
      if (persistenceFailure != null) {
        if (!_operationMachine.owns(lease)) return;
        if (ownedTransfer == null) {
          _settleDeviceOperation(lease, failureCode: persistenceFailure.code);
        } else {
          _operationMachine.rejectCancellation(lease);
          _publishOperationState();
        }
        _state = _state.copyWith(
          status: previousStatus,
          activeFileKey: previousFileKey,
          lastErrorCode: persistenceFailure.code,
        );
        notifyListeners();
        return;
      }
      if (_disposed ||
          revision != _connectionRevision ||
          !_operationMachine.owns(lease)) {
        return;
      }
    }
    RecordingCardResult<bool> result;
    try {
      result = await (port as RecordingCardCancelableTransferPort)
          .cancelFileTransfer();
    } on Object {
      result = RecordingCardResult<bool>.failure(
        _fallbackFailure('RECORDING_CARD_TRANSFER_CANCEL_FAILED'),
      );
    }
    final operation = _operationMachine.state;
    if (_disposed ||
        revision != _connectionRevision ||
        operation.generation != lease.generation ||
        operation.kind != lease.kind ||
        operation.connectionRevision != lease.connectionRevision) {
      return;
    }
    if (operation.hasTerminalOutcome &&
        operation.phase != RecordingCardOperationPhase.cancelled) {
      return;
    }
    if (!result.ok || result.value != true) {
      if (!_operationMachine.owns(lease)) return;
      final failureCode =
          result.error?.code ?? 'RECORDING_CARD_TRANSFER_CANCEL_FAILED';
      if (ownedTransfer == null) {
        _settleDeviceOperation(lease, failureCode: failureCode);
      } else {
        _operationMachine.rejectCancellation(lease);
        _publishOperationState();
      }
      _state = _state.copyWith(
        status: previousStatus,
        activeFileKey: previousFileKey,
        lastErrorCode: failureCode,
      );
      notifyListeners();
      return;
    }
    if (ownedTransfer != null && _operationMachine.owns(lease)) return;
    if (ownedTransfer == null) {
      _operationMachine.cancel(lease);
      _publishOperationState();
    }
    _state = _state.copyWith(
      status: RecordingCardControllerStatus.idle,
      snapshot: _normalizeRuntimeSnapshot(
        port.runtimeSnapshot,
      ).copyWith(clearDownloadingFileKey: true, clearTransferProgress: true),
      clearActiveFileKey: true,
      lastErrorCode: null,
    );
    notifyListeners();
  }

  Future<void> downloadFileOverWifi(RecordingCardScannedFile file) async {
    final port = _port;
    if (port is! RecordingCardWifiTransferPort) {
      _fail(
        recordingCardFailure(
          'RECORDING_CARD_WIFI_UNAVAILABLE',
          'Recording-card Wi-Fi transfer is unavailable',
          isRetryable: false,
        ),
      );
      return;
    }
    final wifiPort = port as RecordingCardWifiTransferPort;
    if (!_beginTransfer(kind: RecordingCardOperationKind.wifiTransfer)) {
      _reportOperationBlocked();
      return;
    }
    final latchGeneration = _transferLatchGeneration;
    final owner = _captureVerifiedTransferOwner(file);
    if (owner == null) {
      _releaseTransferLatch(latchGeneration);
      _fail(_singleFileTransferPreconditionFailure());
      return;
    }
    _state = _state.copyWith(
      status: RecordingCardControllerStatus.downloading,
      activeFileKey: file.localFileKey,
      lastErrorCode: null,
      clearLastDownloadedFile: true,
    );
    notifyListeners();
    var shouldRefresh = false;
    try {
      final result = await wifiPort.downloadFileOverWifi(file);
      final settled = await _handleDownloadedResult(result, file, owner);
      shouldRefresh = settled.ok && settled.value != null;
    } finally {
      _releaseTransferLatch(latchGeneration);
    }
    if (shouldRefresh && _ownsTransferOwner(owner)) {
      await _refreshAfterBleTransfer();
    }
  }

  Future<void> deleteFile(RecordingCardScannedFile file) async {
    await deleteFiles(<RecordingCardScannedFile>[file]);
  }

  Future<RecordingCardBatchDeleteResult> deleteFiles(
    List<RecordingCardScannedFile> files,
  ) async {
    final unique = <String, RecordingCardScannedFile>{
      for (final file in files) file.deviceFileId: file,
    }.values.toList(growable: false);
    RecordingCardBatchDeleteResult rejectAll(AppFailure failure) {
      _fail(failure);
      return RecordingCardBatchDeleteResult(
        requestedCount: unique.length,
        deletedCount: 0,
        failureCodes: <String, String>{
          for (final file in unique) file.deviceFileId: failure.code,
        },
      );
    }

    if (unique.isEmpty) {
      return const RecordingCardBatchDeleteResult(
        requestedCount: 0,
        deletedCount: 0,
        failureCodes: <String, String>{},
      );
    }
    if (_state.snapshot.recordingInfo.state !=
        RecordingCardRecordingState.idle) {
      return rejectAll(
        recordingCardFailure(
          'RECORDING_CARD_DELETE_RECORDING_ACTIVE',
          'Stop the active recording before deleting recording-card files',
          isRetryable: true,
        ),
      );
    }
    final catalogRevision = _connectionRevision;
    final catalogIdentity = _activeConnectionDeviceIdentity(
      _state.snapshot.deviceState,
    );
    final frozenDirectorySignatures = _state.snapshot.files
        .map(_recordingCardFileSignature)
        .toSet();
    final currentFiles = <String, RecordingCardScannedFile>{
      for (final file in _state.snapshot.files) file.deviceFileId: file,
    };
    final ownsCatalog =
        catalogIdentity != null &&
        _ownsReadyFileCatalog(
          revision: catalogRevision,
          deviceIdentity: catalogIdentity,
          directorySignatures: frozenDirectorySignatures,
        );
    final ownsSelection = unique.every((selected) {
      final current = currentFiles[selected.deviceFileId];
      return current != null &&
          _recordingCardFileSignature(current) ==
              _recordingCardFileSignature(selected);
    });
    if (!ownsCatalog || !ownsSelection) {
      return rejectAll(
        recordingCardFailure(
          ownsCatalog
              ? 'RECORDING_CARD_FILE_SELECTION_STALE'
              : 'RECORDING_CARD_FILE_CATALOG_NOT_READY',
          ownsCatalog
              ? 'Selected recording-card files no longer match the verified directory'
              : 'Recording-card file directory is not verified',
          isRetryable: true,
        ),
      );
    }
    if (!_beginTransfer(kind: RecordingCardOperationKind.fileDeletion)) {
      final failure = _operationAdmissionFailure();
      _reportOperationBlocked();
      return RecordingCardBatchDeleteResult(
        requestedCount: unique.length,
        deletedCount: 0,
        failureCodes: <String, String>{
          for (final file in unique) file.deviceFileId: failure.code,
        },
      );
    }
    final latchGeneration = _transferLatchGeneration;
    var expectedDirectorySignatures = frozenDirectorySignatures;
    final failures = <String, String>{};
    var deleted = 0;
    try {
      for (var index = 0; index < unique.length; index += 1) {
        final file = unique[index];
        final current = _state.snapshot.files
            .where((candidate) => candidate.deviceFileId == file.deviceFileId)
            .firstOrNull;
        if (_state.snapshot.recordingInfo.state !=
                RecordingCardRecordingState.idle ||
            !_ownsReadyFileCatalog(
              revision: catalogRevision,
              deviceIdentity: catalogIdentity,
              directorySignatures: expectedDirectorySignatures,
            ) ||
            current == null ||
            _recordingCardFileSignature(current) !=
                _recordingCardFileSignature(file)) {
          for (final remaining in unique.skip(index)) {
            failures[remaining.deviceFileId] =
                'RECORDING_CARD_FILE_CATALOG_CHANGED';
          }
          break;
        }
        _state = _state.copyWith(
          status: RecordingCardControllerStatus.deleting,
          activeFileKey: file.localFileKey,
          lastErrorCode: null,
        );
        notifyListeners();
        final result = await _port.deleteFileFromDevice(file);
        if (!_ownsReadyFileCatalogOwner(catalogRevision, catalogIdentity)) {
          for (final remaining in unique.skip(index)) {
            failures[remaining.deviceFileId] =
                'RECORDING_CARD_FILE_CATALOG_CHANGED';
          }
          break;
        }
        if (!result.ok || result.value == null) {
          final currentSignatures = _state.snapshot.files
              .map(_recordingCardFileSignature)
              .toSet();
          if (!setEquals(currentSignatures, expectedDirectorySignatures)) {
            for (final remaining in unique.skip(index)) {
              failures[remaining.deviceFileId] =
                  'RECORDING_CARD_FILE_CATALOG_CHANGED';
            }
            break;
          }
          failures[file.deviceFileId] =
              result.error?.code ?? 'RECORDING_CARD_DELETE_FAILED';
          continue;
        }
        final receipt = result.value!;
        if (receipt.deviceFileId != file.deviceFileId ||
            receipt.deviceFilename != file.deviceFilename) {
          failures[file.deviceFileId] =
              'RECORDING_CARD_DELETE_IDENTITY_MISMATCH';
          for (final remaining in unique.skip(index + 1)) {
            failures[remaining.deviceFileId] =
                'RECORDING_CARD_FILE_CATALOG_CHANGED';
          }
          break;
        }
        final nextExpectedDirectorySignatures = Set<String>.of(
          expectedDirectorySignatures,
        )..remove(_recordingCardFileSignature(file));
        final currentSignatures = _state.snapshot.files
            .map(_recordingCardFileSignature)
            .toSet();
        final directoryChangedUnexpectedly =
            !setEquals(currentSignatures, expectedDirectorySignatures) &&
            !setEquals(currentSignatures, nextExpectedDirectorySignatures);
        deleted += 1;
        expectedDirectorySignatures = nextExpectedDirectorySignatures;
        _state = _state.copyWith(
          status: RecordingCardControllerStatus.deleting,
          snapshot: _state.snapshot.copyWith(
            files: _state.snapshot.files
                .where((item) => item.deviceFileId != receipt.deviceFileId)
                .toList(growable: false),
          ),
          clearActiveFileKey: true,
          lastErrorCode: null,
        );
        notifyListeners();
        if (directoryChangedUnexpectedly) {
          for (final remaining in unique.skip(index + 1)) {
            failures[remaining.deviceFileId] =
                'RECORDING_CARD_FILE_CATALOG_CHANGED';
          }
          break;
        }
      }
    } finally {
      _releaseTransferLatch(latchGeneration);
    }
    final attemptedRefresh = _ownsReadyFileCatalogOwner(
      catalogRevision,
      catalogIdentity,
    );
    if (attemptedRefresh) {
      final preservedError = failures.isEmpty ? null : failures.values.first;
      await refreshFiles(reason: RecordingCardFileRefreshReason.deviceDeleted);
      if (preservedError != null) {
        _state = _state.copyWith(
          status: RecordingCardControllerStatus.error,
          lastErrorCode: preservedError,
          clearActiveFileKey: true,
        );
        notifyListeners();
      }
    }
    if (unique.isEmpty || (!attemptedRefresh && failures.isEmpty)) {
      _state = _state.copyWith(
        status: RecordingCardControllerStatus.idle,
        clearActiveFileKey: true,
        lastErrorCode: null,
      );
      notifyListeners();
    } else if (!attemptedRefresh && failures.isNotEmpty) {
      _state = _state.copyWith(
        status: RecordingCardControllerStatus.error,
        lastErrorCode: failures.values.first,
        clearActiveFileKey: true,
      );
      notifyListeners();
    }
    return RecordingCardBatchDeleteResult(
      requestedCount: unique.length,
      deletedCount: deleted,
      failureCodes: Map<String, String>.unmodifiable(failures),
    );
  }

  Future<void> refreshLocalSyncState() async {
    final catalogRevision = _connectionRevision;
    final catalogIdentity = _recordingCardDeviceIdentity(
      _state.snapshot.deviceState,
    );
    final canProjectDirectory =
        catalogIdentity != null &&
        hasLoadedFilesForCurrentConnection &&
        _state.fileCatalog.owns(
          connectionRevision: catalogRevision,
          deviceIdentity: catalogIdentity,
        );
    final catalogSignatures = canProjectDirectory
        ? _state.snapshot.files.map(_recordingCardFileSignature).toSet()
        : const <String>{};
    if (!canProjectDirectory) return;
    final verificationFailure = await _refreshVerifiedDownloadCache();
    if (!_ownsReadyFileCatalog(
      revision: catalogRevision,
      deviceIdentity: catalogIdentity,
      directorySignatures: catalogSignatures,
    )) {
      return;
    }
    if (verificationFailure != null) {
      _failFileCatalog(verificationFailure);
      return;
    }
    final reset = _state.snapshot.files
        .map(_withoutVerifiedLocalProjection)
        .toList(growable: false);
    _state = _state.copyWith(
      snapshot: _state.snapshot.copyWith(
        files: _restoreVerifiedDownloads(reset, _state.snapshot.deviceState),
      ),
    );
    notifyListeners();
  }

  Future<void> reconcileConnectionState({bool refreshDirectory = true}) {
    if (_disposed) return Future<void>.value();
    if (refreshDirectory && _recordingCompletionRefreshInFlight != null) {
      return _reconcileAfterRecordingCompletion();
    }
    final running = _connectionReconcileInFlight;
    if (running != null) {
      if (refreshDirectory) {
        _connectionReconcileDirectoryRequested = true;
        _appResumeFileRefreshRequested = true;
      }
      return running;
    }
    _connectionReconcileDirectoryRequested = refreshDirectory;
    final generation = ++_connectionReconcileGeneration;
    final deviceOperation = _deviceDiscoveryOperation;
    late final Future<void> operation;
    operation = _reconcileConnectionState(generation, deviceOperation)
        .whenComplete(() {
          if (identical(_connectionReconcileInFlight, operation)) {
            _connectionReconcileInFlight = null;
            _connectionReconcileDirectoryRequested = false;
            _tryStartAppResumeFileRefresh();
            _schedulePendingBluetoothResume();
          }
        });
    _connectionReconcileInFlight = operation;
    return operation;
  }

  Future<void> _reconcileAfterRecordingCompletion() async {
    await _awaitRecordingCompletionSettlement();
    if (_disposed) return;
    await reconcileConnectionState(refreshDirectory: false);
  }

  Future<void> _reconcileConnectionState(
    int generation,
    int deviceOperation,
  ) async {
    bool requestsDirectory() => _connectionReconcileDirectoryRequested;

    if (_hasRunningTransfer ||
        (_state.status != RecordingCardControllerStatus.idle &&
            _state.status != RecordingCardControllerStatus.error)) {
      if (requestsDirectory()) _appResumeFileRefreshRequested = true;
      return;
    }
    final previousConnectionRevision = _connectionRevision;
    final admission = _beginDeviceOperation(
      kind: RecordingCardOperationKind.connectionReconciliation,
      origin: RecordingCardOperationOrigin.automatic,
    );
    final operationLease = admission.lease;
    if (operationLease == null) {
      if (requestsDirectory()) _appResumeFileRefreshRequested = true;
      return;
    }
    notifyListeners();
    var result = await _port.getConnectionState();
    if (!_ownsConnectionReconciliation(generation, deviceOperation)) {
      _settleDeviceOperation(
        operationLease,
        failureCode: recordingCardOperationSessionChangedCode,
      );
      if (requestsDirectory() &&
          _state.snapshot.deviceState.isOperationallyConnected) {
        _appResumeFileRefreshRequested = true;
      }
      return;
    }
    _settleDeviceOperation(
      operationLease,
      failureCode: result.ok
          ? null
          : result.error?.code ?? 'RECORDING_CARD_CONNECTION_QUERY_FAILED',
    );
    if (!result.ok || result.value == null) {
      if (result.error?.code != 'RECORDING_CARD_CONNECTION_QUERY_STALE') {
        _failFileCatalog(
          result.error ??
              _fallbackFailure('RECORDING_CARD_CONNECTION_QUERY_FAILED'),
        );
      }
      return;
    }
    if (_requiresConnectionAuthorization(result.value!)) {
      result = await _authorizeConnectedDeviceResult(
        result,
        ownsOperation: () => _ownsConnectionReconciliation(
          generation,
          deviceOperation,
          allowAuthorizing: true,
        ),
      );
      if (!_ownsConnectionReconciliation(
        generation,
        deviceOperation,
        allowAuthorizing: true,
      )) {
        if (requestsDirectory() &&
            _state.snapshot.deviceState.isOperationallyConnected) {
          _appResumeFileRefreshRequested = true;
        }
        return;
      }
      if (!result.ok || result.value == null) {
        _handleDeviceStateResult(result);
        return;
      }
    }
    _handleDeviceStateResult(result);
    if (!result.value!.isOperationallyConnected || _disposed) return;
    if (_connectionRevision != previousConnectionRevision) {
      await ensureFilesLoadedForCurrentConnection();
      await refreshDeviceInfo();
      return;
    }
    final previousRecordingState = _state.snapshot.recordingInfo.state;
    await refreshDeviceInfo();
    if (_disposed ||
        !_state.snapshot.deviceState.isOperationallyConnected ||
        _state.status == RecordingCardControllerStatus.error) {
      return;
    }
    final current = _state.snapshot;
    final recordingBecameIdle =
        previousRecordingState != RecordingCardRecordingState.idle &&
        current.recordingInfo.state == RecordingCardRecordingState.idle;
    if (recordingBecameIdle ||
        _recordingCompletionRefreshRequested ||
        _recordingCompletionRefreshInFlight != null) {
      await _awaitRecordingCompletionSettlement();
      return;
    }
    if (current.recordingInfo.state != RecordingCardRecordingState.idle) {
      if (requestsDirectory()) _appResumeFileRefreshRequested = true;
      return;
    }
    if (requestsDirectory() || !hasLoadedFilesForCurrentConnection) {
      if (requestsDirectory()) _appResumeFileRefreshRequested = true;
      await refreshFiles(reason: RecordingCardFileRefreshReason.appResumed);
    }
  }

  bool _ownsConnectionReconciliation(
    int generation,
    int deviceOperation, {
    bool allowAuthorizing = false,
  }) {
    final statusIsOwned =
        _state.status == RecordingCardControllerStatus.idle ||
        _state.status == RecordingCardControllerStatus.error ||
        (allowAuthorizing &&
            _state.status == RecordingCardControllerStatus.authorizing);
    return !_disposed &&
        generation == _connectionReconcileGeneration &&
        deviceOperation == _deviceDiscoveryOperation &&
        !_hasRunningTransfer &&
        statusIsOwned;
  }

  Future<void> disconnect() async {
    if (_state.status == RecordingCardControllerStatus.unbinding) return;
    if (_hasActiveOrPendingDeviceDiscovery) {
      await cancelDiscovery();
      if (_disposed) return;
    }
    if (!_startControllerOperation(
      status: RecordingCardControllerStatus.disconnecting,
      kind: RecordingCardOperationKind.disconnect,
      allowLifecycleSupersession: true,
    )) {
      return;
    }
    final operation = ++_deviceDiscoveryOperation;
    final result = await _port.disconnect();
    if (!_isCurrentDeviceDiscoveryOperation(operation)) return;
    if (_isStaleDeviceOperation(result)) {
      await _adoptCurrentNativeDeviceState(operation);
      return;
    }
    _handleDeviceStateResult(result);
  }

  Future<RecordingCardResult<RecordingCardDeviceState>> setBluetoothName(
    String bluetoothName,
  ) async {
    final normalizedName = normalizeRecordingCardBluetoothName(bluetoothName);
    if (normalizedName == null) {
      final failure = recordingCardFailure(
        'RECORDING_CARD_BLUETOOTH_NAME_INVALID',
        'Bluetooth name must be 1 to 32 UTF-8 bytes without control characters',
        isRetryable: false,
      );
      _fail(failure);
      return RecordingCardResult<RecordingCardDeviceState>.failure(failure);
    }
    final device = _state.snapshot.deviceState;
    if (!device.isOperationallyConnected) {
      final failure = recordingCardFailure(
        'RECORDING_CARD_BLUETOOTH_NAME_NOT_CONNECTED',
        'Recording card must be connected before changing its Bluetooth name',
        isRetryable: true,
      );
      _fail(failure);
      return RecordingCardResult<RecordingCardDeviceState>.failure(failure);
    }
    if (_state.snapshot.recordingInfo.state !=
        RecordingCardRecordingState.idle) {
      final failure = recordingCardFailure(
        'RECORDING_CARD_BLUETOOTH_NAME_RECORDING_ACTIVE',
        'Stop the active recording before changing its Bluetooth name',
        isRetryable: true,
      );
      _fail(failure);
      return RecordingCardResult<RecordingCardDeviceState>.failure(failure);
    }
    if (_transferInFlight ||
        _state.hasActiveTransfer ||
        (_state.status != RecordingCardControllerStatus.idle &&
            _state.status != RecordingCardControllerStatus.error)) {
      final failure = recordingCardFailure(
        'RECORDING_CARD_BLUETOOTH_NAME_BUSY',
        'Recording card is busy and cannot change its Bluetooth name',
        isRetryable: true,
      );
      _fail(failure);
      return RecordingCardResult<RecordingCardDeviceState>.failure(failure);
    }
    final bluetoothNamePort = _port as RecordingCardBluetoothNamePort?;
    if (bluetoothNamePort == null) {
      final failure = recordingCardFailure(
        'RECORDING_CARD_BLUETOOTH_NAME_UNAVAILABLE',
        'Recording-card Bluetooth name changes are unavailable',
        isRetryable: false,
      );
      _fail(failure);
      return RecordingCardResult<RecordingCardDeviceState>.failure(failure);
    }

    final deviceIdentity = _activeConnectionDeviceIdentity(device);
    if (deviceIdentity == null) {
      final failure = recordingCardFailure(
        'RECORDING_CARD_DEVICE_IDENTITY_UNAVAILABLE',
        'Recording-card stable identity is unavailable',
        isRetryable: true,
      );
      _fail(failure);
      return RecordingCardResult<RecordingCardDeviceState>.failure(failure);
    }
    final connectionRevision = _connectionRevision;
    if (!_startControllerOperation(
      status: RecordingCardControllerStatus.commanding,
      kind: RecordingCardOperationKind.deviceConfiguration,
    )) {
      return RecordingCardResult<RecordingCardDeviceState>.failure(
        _operationAdmissionFailure(),
      );
    }
    final operation = ++_deviceDiscoveryOperation;
    final result = await bluetoothNamePort.setBluetoothName(
      bluetoothName: normalizedName,
    );
    if (!_ownsConnectionBoundOperation(
      deviceOperation: operation,
      connectionRevision: connectionRevision,
      deviceIdentity: deviceIdentity,
    )) {
      if (_isCurrentDeviceDiscoveryOperation(operation)) {
        await _adoptCurrentNativeDeviceState(operation);
      }
      return _staleControllerDeviceOperationResult();
    }
    if (_isStaleDeviceOperation(result)) {
      await _adoptCurrentNativeDeviceState(operation);
      return result;
    }
    if (!result.ok || result.value == null) {
      _fail(
        result.error ??
            _fallbackFailure('RECORDING_CARD_BLUETOOTH_NAME_FAILED'),
      );
      return result;
    }

    _settleControllerOperation();
    final previousDevice = _state.snapshot.deviceState;
    final updatedDevice = result.value!;
    _state = _state.copyWith(
      status: RecordingCardControllerStatus.idle,
      snapshot: _sanitizeDisconnectedDeviceDirectory(
        _state.snapshot.copyWith(deviceState: updatedDevice),
      ),
      clearActiveFileKey: true,
      lastErrorCode: null,
    );
    notifyListeners();
    _observeConnectionTransition(previousDevice, updatedDevice);
    _scheduleDeferredFileRefreshes();
    return result;
  }

  Future<RecordingCardResult<RecordingCardAccountClaim>>
  readAccountBindingClaim() async {
    final device = _state.snapshot.deviceState;
    if (!device.isOperationallyConnected) {
      return RecordingCardResult<RecordingCardAccountClaim>.failure(
        recordingCardFailure(
          'RECORDING_CARD_ACCOUNT_BIND_NOT_CONNECTED',
          'Recording card must be connected before reading its account claim',
          isRetryable: true,
        ),
      );
    }
    if (_state.snapshot.recordingInfo.state !=
        RecordingCardRecordingState.idle) {
      return RecordingCardResult<RecordingCardAccountClaim>.failure(
        recordingCardFailure(
          'RECORDING_CARD_ACCOUNT_BIND_RECORDING_ACTIVE',
          'Stop recording before managing the recording-card account binding',
          isRetryable: true,
        ),
      );
    }
    if (_transferInFlight ||
        _state.hasActiveTransfer ||
        (_state.status != RecordingCardControllerStatus.idle &&
            _state.status != RecordingCardControllerStatus.error)) {
      return RecordingCardResult<RecordingCardAccountClaim>.failure(
        recordingCardFailure(
          'RECORDING_CARD_ACCOUNT_BIND_BUSY',
          'Recording card is busy and cannot read its account claim',
          isRetryable: true,
        ),
      );
    }
    final port = _port;
    if (port is! RecordingCardAccountClaimPort) {
      return RecordingCardResult<RecordingCardAccountClaim>.failure(
        recordingCardFailure(
          'RECORDING_CARD_ACCOUNT_CLAIM_UNAVAILABLE',
          'Recording-card account claim is unavailable',
        ),
      );
    }
    final claimPort = port as RecordingCardAccountClaimPort;
    final deviceIdentity = _activeConnectionDeviceIdentity(device);
    if (deviceIdentity == null) {
      return _staleControllerOperationResult<RecordingCardAccountClaim>(
        code: 'RECORDING_CARD_DEVICE_IDENTITY_UNAVAILABLE',
        message: 'Recording-card stable identity is unavailable',
      );
    }
    final connectionRevision = _connectionRevision;
    if (!_startControllerOperation(
      status: RecordingCardControllerStatus.commanding,
      kind: RecordingCardOperationKind.accountBinding,
    )) {
      return RecordingCardResult<RecordingCardAccountClaim>.failure(
        _operationAdmissionFailure(),
      );
    }
    final operation = ++_deviceDiscoveryOperation;
    final result = await claimPort.readAccountBindingClaim();
    if (!_ownsConnectionBoundOperation(
      deviceOperation: operation,
      connectionRevision: connectionRevision,
      deviceIdentity: deviceIdentity,
    )) {
      if (_isCurrentDeviceDiscoveryOperation(operation)) {
        await _adoptCurrentNativeDeviceState(operation);
      }
      return _staleControllerOperationResult<RecordingCardAccountClaim>();
    }
    if (!result.ok || result.value == null) {
      _fail(
        result.error ??
            _fallbackFailure('RECORDING_CARD_ACCOUNT_CLAIM_READ_FAILED'),
      );
      return result;
    }
    _settleControllerOperation();
    _state = _state.copyWith(
      status: RecordingCardControllerStatus.idle,
      lastErrorCode: null,
      clearActiveFileKey: true,
    );
    notifyListeners();
    _scheduleDeferredFileRefreshes();
    return result;
  }

  Future<void> unbindDevice({bool deleteDeviceFiles = false}) async {
    final device = _state.snapshot.deviceState;
    if (!device.isOperationallyConnected) {
      _fail(
        recordingCardFailure(
          'RECORDING_CARD_UNBIND_NOT_CONNECTED',
          'Recording card must be connected before it can be unbound',
          isRetryable: true,
        ),
      );
      return;
    }
    if (_state.snapshot.recordingInfo.state !=
        RecordingCardRecordingState.idle) {
      _fail(
        recordingCardFailure(
          'RECORDING_CARD_UNBIND_RECORDING_ACTIVE',
          'Stop the active recording before unbinding the recording card',
          isRetryable: true,
        ),
      );
      return;
    }
    if (_transferInFlight ||
        _state.hasActiveTransfer ||
        (_state.status != RecordingCardControllerStatus.idle &&
            _state.status != RecordingCardControllerStatus.error)) {
      _fail(
        recordingCardFailure(
          'RECORDING_CARD_UNBIND_BUSY',
          'Recording card is busy and cannot be unbound',
          isRetryable: true,
        ),
      );
      return;
    }
    final port = _port;
    if (port is! RecordingCardUnbindPort) {
      _fail(
        recordingCardFailure(
          'RECORDING_CARD_UNBIND_UNAVAILABLE',
          'Recording-card unbind is unavailable',
          isRetryable: false,
        ),
      );
      return;
    }
    final unbindPort = port as RecordingCardUnbindPort;
    final deviceIdentity = _activeConnectionDeviceIdentity(device);
    if (deviceIdentity == null) {
      _fail(
        recordingCardFailure(
          'RECORDING_CARD_DEVICE_IDENTITY_UNAVAILABLE',
          'Recording-card stable identity is unavailable',
          isRetryable: true,
        ),
      );
      return;
    }
    final connectionRevision = _connectionRevision;
    if (!_startControllerOperation(
      status: RecordingCardControllerStatus.unbinding,
      kind: RecordingCardOperationKind.unbind,
    )) {
      return;
    }
    final operation = ++_deviceDiscoveryOperation;
    final String bindingToken;
    try {
      bindingToken = await _bindingTokenProvider();
    } catch (_) {
      if (!_ownsConnectionBoundOperation(
        deviceOperation: operation,
        connectionRevision: connectionRevision,
        deviceIdentity: deviceIdentity,
      )) {
        if (_isCurrentDeviceDiscoveryOperation(operation)) {
          await _adoptCurrentNativeDeviceState(operation);
        }
        return;
      }
      _fail(
        recordingCardFailure(
          'RECORDING_CARD_BINDING_IDENTITY_UNAVAILABLE',
          'Recording-card secure binding identity is unavailable',
          isRetryable: true,
        ),
      );
      return;
    }
    if (!_ownsConnectionBoundOperation(
      deviceOperation: operation,
      connectionRevision: connectionRevision,
      deviceIdentity: deviceIdentity,
    )) {
      if (_isCurrentDeviceDiscoveryOperation(operation)) {
        await _adoptCurrentNativeDeviceState(operation);
      }
      return;
    }
    if (!isRecordingCardBindingToken(bindingToken)) {
      _fail(
        recordingCardFailure(
          'RECORDING_CARD_BINDING_IDENTITY_UNAVAILABLE',
          'Recording-card secure binding identity is unavailable',
          isRetryable: true,
        ),
      );
      return;
    }
    final result = await unbindPort.unbindDevice(
      bindingTokenHex: bindingToken,
      deleteDeviceFiles: deleteDeviceFiles,
    );
    if (!_isCurrentDeviceDiscoveryOperation(operation)) return;
    if (_isStaleDeviceOperation(result)) {
      await _adoptCurrentNativeDeviceState(operation);
      return;
    }
    if (!result.ok || result.value == null) {
      _fail(result.error ?? _fallbackFailure('RECORDING_CARD_UNBIND_FAILED'));
      return;
    }
    _settleControllerOperation();
    _recordingAnchor = RecordingCardRecordingInfo.idle();
    _recordingObservation = null;
    _state = _state.copyWith(
      status: RecordingCardControllerStatus.idle,
      snapshot: _sanitizeDisconnectedDeviceDirectory(_port.runtimeSnapshot),
      clearActiveFileKey: true,
      lastErrorCode: null,
    );
    notifyListeners();
  }

  @override
  void dispose() {
    final cancelNativeDiscovery =
        _operationMachine.state.phase == RecordingCardOperationPhase.running &&
        _operationMachine.state.kind == RecordingCardOperationKind.discovery;
    _disposed = true;
    _pendingBluetoothResumeGeneration += 1;
    _pendingBluetoothResumePreflight = false;
    _pendingBluetoothResumeFileRefreshGeneration = null;
    _pendingBluetoothResumeOperationLease = null;
    _pendingBluetoothResumeLatchGeneration = null;
    _pendingBluetoothRecoveryAttemptKey = null;
    _deviceDiscoveryRequestGeneration += 1;
    _releaseDeviceDiscoveryAdmissionWaiter(force: true);
    _deviceDiscoveryOperation += 1;
    _connectionReconcileGeneration += 1;
    _recordingCompletionTimer?.cancel();
    _deferredFileRefreshTimer?.cancel();
    final delayCompleter = _recordingCompletionDelayCompleter;
    if (delayCompleter != null && !delayCompleter.isCompleted) {
      delayCompleter.complete();
    }
    _abortWifiFlow();
    _wifiBatchStateGeneration += 1;
    _wifiPreparationGeneration += 1;
    _interruptWifiBatchDownload('RECORDING_CARD_WIFI_SESSION_INTERRUPTED');
    final port = _port;
    if (cancelNativeDiscovery &&
        port is RecordingCardDiscoveryCancellationPort) {
      unawaited(
        (port as RecordingCardDiscoveryCancellationPort)
            .cancelDiscovery()
            .then<void>((_) {})
            .catchError((Object _) {}),
      );
    }
    if (_wifiBatchCoordinator.snapshot?.isActive == true &&
        port is RecordingCardWifiSessionPort) {
      unawaited(
        (port as RecordingCardWifiSessionPort)
            .cancelWifiSession()
            .then<void>((_) {})
            .catchError((Object _) {}),
      );
    }
    _wifiRecoverySubscription?.unsubscribe();
    _snapshotSubscription.unsubscribe();
    _operationMachine.reset();
    super.dispose();
  }

  void _setBusy(RecordingCardControllerStatus status) {
    _connectionReconcileGeneration += 1;
    _state = _state.copyWith(
      status: status,
      lastErrorCode: null,
      clearActiveFileKey: true,
    );
    notifyListeners();
  }

  RecordingCardOperationAdmission _beginDeviceOperation({
    required RecordingCardOperationKind kind,
    required RecordingCardOperationOrigin origin,
  }) {
    final admission = _operationMachine.begin(
      kind: kind,
      origin: origin,
      connectionRevision: _connectionRevision,
    );
    _state = _state.copyWith(operation: admission.state);
    return admission;
  }

  RecordingCardOperationAdmission _blockDeviceOperation({
    required RecordingCardOperationKind kind,
    required RecordingCardOperationOrigin origin,
  }) {
    final admission = _operationMachine.block(kind: kind, origin: origin);
    _state = _state.copyWith(
      operation: admission.state,
      lastErrorCode: _state.lastErrorCode,
    );
    return admission;
  }

  void _publishOperationState() {
    _state = _state.copyWith(
      operation: _operationMachine.state,
      lastErrorCode: _state.lastErrorCode,
    );
    _releaseDeviceDiscoveryAdmissionWaiter();
  }

  Future<void> _waitForDeviceDiscoveryAdmission() {
    if (!_operationMachine.state.isActive) return Future<void>.value();
    final current = _deviceDiscoveryAdmissionWaiter;
    if (current != null) return current.future;
    final waiter = Completer<void>();
    _deviceDiscoveryAdmissionWaiter = waiter;
    return waiter.future;
  }

  void _releaseDeviceDiscoveryAdmissionWaiter({bool force = false}) {
    if (!force && _operationMachine.state.isActive) return;
    final waiter = _deviceDiscoveryAdmissionWaiter;
    _deviceDiscoveryAdmissionWaiter = null;
    if (waiter != null && !waiter.isCompleted) waiter.complete();
  }

  void _settleDeviceOperation(
    RecordingCardOperationLease? lease, {
    String? failureCode,
  }) {
    if (lease == null) return;
    final cancelled =
        failureCode == 'RECORDING_CARD_TRANSFER_CANCELLED' ||
        failureCode == 'RECORDING_CARD_WIFI_TRANSFER_CANCELLED' ||
        failureCode == 'RECORDING_CARD_WIFI_BATCH_CANCELLED' ||
        failureCode == 'RECORDING_CARD_SCAN_CANCELLED';
    final changed = cancelled
        ? _operationMachine.cancel(lease, errorCode: failureCode)
        : failureCode == null
        ? _operationMachine.succeed(lease)
        : failureCode == recordingCardOperationSessionChangedCode
        ? _operationMachine.interrupt(lease)
        : _operationMachine.fail(lease, failureCode);
    if (changed) _publishOperationState();
  }

  bool _startControllerOperation({
    required RecordingCardControllerStatus status,
    required RecordingCardOperationKind kind,
    RecordingCardOperationOrigin origin = RecordingCardOperationOrigin.user,
    bool allowLifecycleSupersession = false,
  }) {
    final active = _operationMachine.state;
    final activeKind = active.kind;
    final supersedableLifecycleOwner =
        activeKind == RecordingCardOperationKind.connectionReconciliation ||
        activeKind == RecordingCardOperationKind.deviceRefresh ||
        activeKind == RecordingCardOperationKind.directoryRefresh;
    final maySupersede =
        allowLifecycleSupersession &&
        active.isActive &&
        supersedableLifecycleOwner &&
        (kind == RecordingCardOperationKind.connection ||
            kind == RecordingCardOperationKind.disconnect);
    if (maySupersede) {
      final activeControllerLease = _activeControllerOperationLease;
      if (_operationMachine.owns(activeControllerLease)) {
        _activeControllerOperationLease = null;
      }
    }
    final admission = maySupersede
        ? _operationMachine.supersede(
            kind: kind,
            origin: origin,
            connectionRevision: _connectionRevision,
          )
        : _beginDeviceOperation(kind: kind, origin: origin);
    if (maySupersede) {
      _state = _state.copyWith(operation: admission.state);
    }
    final lease = admission.lease;
    if (lease == null) {
      if (origin == RecordingCardOperationOrigin.user) {
        _reportOperationBlocked();
      }
      return false;
    }
    _activeControllerOperationLease = lease;
    _setBusy(status);
    return true;
  }

  void _settleControllerOperation({String? failureCode}) {
    final lease = _activeControllerOperationLease;
    _activeControllerOperationLease = null;
    _settleDeviceOperation(lease, failureCode: failureCode);
  }

  AppFailure _operationAdmissionFailure({String? fallbackCode}) {
    final code =
        _operationMachine.state.blockCode ??
        fallbackCode ??
        recordingCardOperationBusyCode;
    return recordingCardFailure(
      code,
      code == recordingCardOperationDeferredCode
          ? 'Recording-card operation is waiting for the active task'
          : 'Recording card is already processing another operation',
      isRetryable: true,
    );
  }

  bool _requiresConnectionAuthorization(RecordingCardDeviceState device) {
    if (_connectionAuthorization == null || !device.isOperationallyConnected) {
      return false;
    }
    if (!_connectionAuthorizationSatisfied) return true;
    final authorizedFingerprint = _authorizedConnectionFingerprint;
    final nextFingerprint = device.safeDeviceFingerprint;
    return authorizedFingerprint != null &&
        nextFingerprint != null &&
        authorizedFingerprint != nextFingerprint;
  }

  void _beginConnectionAuthorizationAttempt() {
    if (_connectionAuthorization == null) return;
    _connectionAuthorizationSatisfied = false;
    _authorizedConnectionFingerprint = null;
    _provisionalConnectedDevice = null;
    _connectionAuthorizationGeneration += 1;
  }

  void _stageProvisionalConnection(RecordingCardDeviceState device) {
    if (_connectionAuthorization == null) return;
    final previous = _provisionalConnectedDevice;
    if (previous == null || !_samePhysicalConnection(previous, device)) {
      _connectionAuthorizationGeneration += 1;
    }
    _connectionAuthorizationSatisfied = false;
    _authorizedConnectionFingerprint = null;
    _provisionalConnectedDevice = device;
  }

  void _resetConnectionAuthorization() {
    if (_connectionAuthorization == null) return;
    final hadConnection =
        _connectionAuthorizationSatisfied ||
        _provisionalConnectedDevice != null;
    _connectionAuthorizationSatisfied = false;
    _authorizedConnectionFingerprint = null;
    _provisionalConnectedDevice = null;
    if (hadConnection) _connectionAuthorizationGeneration += 1;
  }

  bool _samePhysicalConnection(
    RecordingCardDeviceState left,
    RecordingCardDeviceState right,
  ) {
    final leftFingerprint = left.safeDeviceFingerprint;
    final rightFingerprint = right.safeDeviceFingerprint;
    if (leftFingerprint != null && rightFingerprint != null) {
      return leftFingerprint == rightFingerprint;
    }
    return left.displayName == right.displayName;
  }

  RecordingCardRuntimeSnapshot _provisionalRuntimeSnapshot(
    RecordingCardRuntimeSnapshot snapshot,
  ) {
    final device = snapshot.deviceState;
    return snapshot.copyWith(
      deviceState: device.copyWith(
        connectionState: RecordingCardConnectionState.connecting,
        connectionStage: RecordingCardConnectionStage.connecting,
        statusMessage: 'cloud_authorizing',
      ),
      recordingInfo: const RecordingCardRecordingInfo(
        state: RecordingCardRecordingState.idle,
        durationSeconds: 0,
      ),
      files: const <RecordingCardScannedFile>[],
      loadingFiles: false,
      clearDownloadingFileKey: true,
      clearRecordingObservation: true,
      clearTransferProgress: true,
    );
  }

  Future<RecordingCardResult<RecordingCardDeviceState>>
  _authorizeConnectedDeviceResult(
    RecordingCardResult<RecordingCardDeviceState> result, {
    bool Function()? ownsOperation,
  }) async {
    final device = result.value;
    if (!result.ok ||
        device == null ||
        !device.isOperationallyConnected ||
        _connectionAuthorization == null) {
      return result;
    }
    if (ownsOperation != null && !ownsOperation()) {
      return RecordingCardResult<RecordingCardDeviceState>.failure(
        _fallbackFailure(recordingCardOperationSessionChangedCode),
      );
    }
    _stageProvisionalConnection(device);
    final generation = _connectionAuthorizationGeneration;
    final nativeSnapshot = _normalizeRuntimeSnapshot(_port.runtimeSnapshot);
    _state = _state.copyWith(
      status: RecordingCardControllerStatus.authorizing,
      snapshot: _provisionalRuntimeSnapshot(
        nativeSnapshot.copyWith(deviceState: device),
      ),
      lastErrorCode: null,
      clearActiveFileKey: true,
    );
    notifyListeners();
    final authorization = await _authorizeConnection(
      device,
      generation,
      ownsOperation: ownsOperation,
    );
    if (ownsOperation != null && !ownsOperation()) {
      return RecordingCardResult<RecordingCardDeviceState>.failure(
        _fallbackFailure(recordingCardOperationSessionChangedCode),
      );
    }
    if (!authorization.ok || authorization.value != true) {
      return RecordingCardResult<RecordingCardDeviceState>.failure(
        authorization.error ??
            _fallbackFailure('RECORDING_CARD_CLOUD_AUTHORIZATION_FAILED'),
      );
    }
    return result;
  }

  Future<RecordingCardResult<bool>> _authorizeConnection(
    RecordingCardDeviceState device,
    int generation, {
    bool Function()? ownsOperation,
  }) {
    final existing = _connectionAuthorizationInFlight;
    if (existing != null &&
        _connectionAuthorizationInFlightGeneration == generation) {
      return existing;
    }
    late final Future<RecordingCardResult<bool>> operation;
    operation =
        _performConnectionAuthorization(
          device,
          generation,
          ownsOperation: ownsOperation,
        ).whenComplete(() {
          if (identical(_connectionAuthorizationInFlight, operation)) {
            _connectionAuthorizationInFlight = null;
            _connectionAuthorizationInFlightGeneration = null;
          }
        });
    _connectionAuthorizationInFlight = operation;
    _connectionAuthorizationInFlightGeneration = generation;
    return operation;
  }

  Future<RecordingCardResult<bool>> _performConnectionAuthorization(
    RecordingCardDeviceState device,
    int generation, {
    bool Function()? ownsOperation,
  }) async {
    final authorizationPort = _connectionAuthorization;
    if (authorizationPort == null) {
      return RecordingCardResult<bool>.success(true);
    }
    if (ownsOperation != null && !ownsOperation()) {
      return RecordingCardResult<bool>.failure(
        _fallbackFailure(recordingCardOperationSessionChangedCode),
      );
    }
    RecordingCardResult<bool> result;
    try {
      result = await authorizationPort.authorizeConnection(device);
    } on Object catch (error) {
      result = RecordingCardResult<bool>.failure(
        recordingCardFailure(
          'RECORDING_CARD_CLOUD_BINDING_REQUEST_FAILED',
          'Recording-card cloud authorization request failed',
          cause: error,
          isRetryable: true,
        ),
      );
    }
    if (_disposed ||
        generation != _connectionAuthorizationGeneration ||
        (ownsOperation != null && !ownsOperation())) {
      return RecordingCardResult<bool>.failure(
        recordingCardFailure(
          'RECORDING_CARD_CLOUD_AUTHORIZATION_STALE',
          'Recording-card connection changed during cloud authorization',
          isRetryable: true,
        ),
      );
    }
    if (result.ok && result.value == true) {
      _connectionAuthorizationSatisfied = true;
      _authorizedConnectionFingerprint = device.safeDeviceFingerprint;
      _provisionalConnectedDevice = null;
      return result;
    }
    try {
      await _port.disconnect();
    } on Object {
      // The cloud rejection remains authoritative even if native cleanup fails.
    }
    _provisionalConnectedDevice = null;
    return RecordingCardResult<bool>.failure(
      result.error ??
          _fallbackFailure('RECORDING_CARD_CLOUD_AUTHORIZATION_FAILED'),
    );
  }

  Future<void> _authorizeObservedConnection(
    RecordingCardDeviceState device,
    int generation,
  ) async {
    final result = await _authorizeConnection(device, generation);
    if (_disposed) return;
    if (!result.ok || result.value != true) {
      if (result.error?.code == 'RECORDING_CARD_CLOUD_AUTHORIZATION_STALE' &&
          generation != _connectionAuthorizationGeneration) {
        return;
      }
      _fail(
        result.error ??
            _fallbackFailure('RECORDING_CARD_CLOUD_AUTHORIZATION_FAILED'),
      );
      return;
    }
    if (generation != _connectionAuthorizationGeneration) return;
    final nativeSnapshot = _normalizeRuntimeSnapshot(_port.runtimeSnapshot);
    if (!nativeSnapshot.deviceState.isOperationallyConnected) {
      _resetConnectionAuthorization();
      return;
    }
    final previousDevice = _state.snapshot.deviceState;
    final previousRecordingState = _state.snapshot.recordingInfo.state;
    _state = _state.copyWith(
      status: RecordingCardControllerStatus.idle,
      snapshot: _preserveDirectoryUntilVerified(nativeSnapshot),
      lastErrorCode: null,
      clearActiveFileKey: true,
    );
    notifyListeners();
    _observeConnectionTransition(previousDevice, nativeSnapshot.deviceState);
    _observeRecordingTransition(
      previousRecordingState,
      nativeSnapshot.recordingInfo.state,
    );
  }

  void _handleDeviceStateResult(
    RecordingCardResult<RecordingCardDeviceState> result, {
    RecordingCardConnectRequest? requestedDevice,
    bool acceptsWifiHandoffConnection = false,
  }) {
    if (!result.ok || result.value == null) {
      if (!_port.runtimeSnapshot.deviceState.isOperationallyConnected) {
        _resetConnectionAuthorization();
      }
      _fail(
        result.error ?? _fallbackFailure('RECORDING_CARD_CONNECTION_FAILED'),
      );
      return;
    }
    _settleControllerOperation();
    final previousSnapshot = _state.snapshot;
    final previousDevice = _state.snapshot.deviceState;
    if (acceptsWifiHandoffConnection &&
        result.value!.isOperationallyConnected) {
      _wifiHandoffBleUnavailable = false;
    }
    var nextSnapshot = _normalizeRuntimeSnapshot(
      _state.snapshot.copyWith(deviceState: result.value),
    );
    if (_connectionAuthorization != null &&
        _connectionAuthorizationSatisfied &&
        result.value!.isOperationallyConnected) {
      final nativeSnapshot = _normalizeRuntimeSnapshot(_port.runtimeSnapshot);
      final nativeDevice = nativeSnapshot.deviceState;
      if (!nativeDevice.isOperationallyConnected ||
          _samePhysicalConnection(result.value!, nativeDevice)) {
        nextSnapshot = nativeSnapshot;
      }
    }
    nextSnapshot = _preserveDirectoryUntilVerified(nextSnapshot);
    _state = _state.copyWith(
      status: RecordingCardControllerStatus.idle,
      snapshot: nextSnapshot,
      clearActiveFileKey: true,
      lastErrorCode: null,
    );
    notifyListeners();
    _observeConnectionTransition(
      previousDevice,
      nextSnapshot.deviceState,
      requestedDevice: requestedDevice,
    );
    _observeRecordingTransition(
      previousSnapshot.recordingInfo.state,
      nextSnapshot.recordingInfo.state,
    );
    _scheduleDeferredFileRefreshes();
  }

  void _observeConnectionTransition(
    RecordingCardDeviceState previous,
    RecordingCardDeviceState next, {
    RecordingCardConnectRequest? requestedDevice,
  }) {
    final wasConnected = previous.isOperationallyConnected;
    final connected = next.isOperationallyConnected;
    if (!connected) {
      final transferLease = _activeTransferOperationLease;
      if (wasConnected &&
          transferLease != null &&
          transferLease.kind == RecordingCardOperationKind.bluetoothTransfer &&
          _operationMachine.owns(transferLease)) {
        _operationMachine.interrupt(
          transferLease,
          errorCode: 'RECORDING_CARD_DISCONNECTED',
        );
        _publishOperationState();
      }
      _invalidateDirectTransferCancellation();
      _recordingAnchor = const RecordingCardRecordingInfo(
        state: RecordingCardRecordingState.idle,
        durationSeconds: 0,
      );
      _recordingObservation = null;
      _activeFileScanConnectionRevision = -1;
      _scanFilesRequested = false;
      _pendingFileRefreshReasons.clear();
      _deferredConnectionFileRefreshRevision = -1;
      _recordingCompletionRefreshRequested = false;
      _recordingCompletionKnownFiles = null;
      _appResumeFileRefreshRequested = false;
      _connectionFingerprint = null;
      _connectionDeviceIdentity = null;
      _state = _state.copyWith(
        fileCatalog: RecordingCardFileCatalogState.disconnected(
          connectionRevision: _connectionRevision,
        ),
      );
      _clearDisconnectedDeviceDirectory();
      return;
    }
    final nextFingerprint = next.safeDeviceFingerprint;
    final nextDeviceIdentity = _recordingCardDeviceIdentity(next);
    final fingerprintChanged =
        wasConnected &&
        _connectionFingerprint != null &&
        nextFingerprint != null &&
        nextFingerprint != _connectionFingerprint;
    final deviceIdentityChanged =
        wasConnected &&
        nextDeviceIdentity != null &&
        nextDeviceIdentity != _connectionDeviceIdentity;
    final isNewConnection =
        !wasConnected ||
        fingerprintChanged ||
        deviceIdentityChanged ||
        _connectionRevision == 0;
    if (isNewConnection) {
      _invalidateDirectTransferCancellation();
      _recordingCompletionRefreshRequested = false;
      _recordingCompletionKnownFiles = null;
      _connectionRevision += 1;
      _connectionFingerprint = nextFingerprint;
      _connectionDeviceIdentity = nextDeviceIdentity;
      _rememberConnectedDevice(next, requestedDevice: requestedDevice);
      _loadedFileDirectoryConnectionRevision = -1;
      _state = _state.copyWith(
        snapshot: _state.snapshot.copyWith(
          files: const <RecordingCardScannedFile>[],
        ),
        fileCatalog: RecordingCardFileCatalogState(
          phase: RecordingCardFileCatalogPhase.reading,
          connectionRevision: _connectionRevision,
          deviceIdentity: _recordingCardDeviceIdentity(next),
        ),
      );
      notifyListeners();
    } else if (nextFingerprint != null) {
      _connectionFingerprint = nextFingerprint;
      _connectionDeviceIdentity =
          nextDeviceIdentity ?? _connectionDeviceIdentity;
    }
    if (_wifiBleRecoveryInFlight ||
        _state.status == RecordingCardControllerStatus.connecting ||
        _state.status == RecordingCardControllerStatus.authorizing) {
      return;
    }
    unawaited(ensureFilesLoadedForCurrentConnection());
  }

  bool _isCurrentDeviceDiscoveryOperation(int operation) =>
      !_disposed && operation == _deviceDiscoveryOperation;

  void _invalidateDirectTransferCancellation() {
    _directTransferCancellationInFlight = null;
    final observedLease = _observedTransferCancellationLease;
    _observedTransferCancellationLease = null;
    if (!_operationMachine.owns(observedLease)) return;
    _operationMachine.interrupt(observedLease!);
    _publishOperationState();
    _state = _state.copyWith(
      status: RecordingCardControllerStatus.idle,
      clearActiveFileKey: true,
      lastErrorCode: null,
    );
  }

  bool _ownsConnectionBoundOperation({
    required int deviceOperation,
    required int connectionRevision,
    required String deviceIdentity,
  }) {
    final device = _state.snapshot.deviceState;
    return _isCurrentDeviceDiscoveryOperation(deviceOperation) &&
        connectionRevision == _connectionRevision &&
        device.isOperationallyConnected &&
        _activeConnectionDeviceIdentity(device) == deviceIdentity;
  }

  bool _isStaleDeviceOperation<T>(RecordingCardResult<T> result) {
    return result.error?.code == 'RECORDING_CARD_DEVICE_OPERATION_STALE' ||
        result.error?.code == 'RECORDING_CARD_DEVICE_SESSION_STALE';
  }

  Future<void> _adoptCurrentNativeDeviceState(
    int operation, {
    bool acceptsWifiHandoffConnection = false,
  }) async {
    if (!_isCurrentDeviceDiscoveryOperation(operation)) return;
    var result = RecordingCardResult<RecordingCardDeviceState>.success(
      _port.runtimeSnapshot.deviceState,
    );
    if (_requiresConnectionAuthorization(result.value!)) {
      result = await _authorizeConnectedDeviceResult(result);
      if (!_isCurrentDeviceDiscoveryOperation(operation)) return;
    }
    _handleDeviceStateResult(
      result,
      acceptsWifiHandoffConnection: acceptsWifiHandoffConnection,
    );
  }

  RecordingCardResult<T> _staleControllerOperationResult<T>({
    String code = 'RECORDING_CARD_DEVICE_OPERATION_STALE',
    String message = 'Recording-card device operation was superseded',
  }) {
    return RecordingCardResult<T>.failure(
      recordingCardFailure(code, message, isRetryable: true),
    );
  }

  RecordingCardResult<RecordingCardDeviceState>
  _staleControllerDeviceOperationResult() {
    return _staleControllerOperationResult<RecordingCardDeviceState>();
  }

  List<RecordingCardConnectionHistoryEntry> _loadRecentConnectionHistory() {
    try {
      return _connectionHistory
          .load()
          .where(
            (entry) =>
                isSafeRecordingCardIdentifier(entry.displayName) &&
                isSafeRecordingCardIdentifier(entry.safeDeviceFingerprint),
          )
          .toList(growable: false);
    } on Object {
      return const <RecordingCardConnectionHistoryEntry>[];
    }
  }

  void _rememberConnectedDevice(
    RecordingCardDeviceState device, {
    RecordingCardConnectRequest? requestedDevice,
  }) {
    final fingerprint =
        device.safeDeviceFingerprint?.trim() ??
        requestedDevice?.safeDeviceFingerprint?.trim();
    final displayName =
        device.displayName?.trim() ?? requestedDevice?.displayName?.trim();
    if (fingerprint == null ||
        displayName == null ||
        !isSafeRecordingCardIdentifier(fingerprint) ||
        !isSafeRecordingCardIdentifier(displayName)) {
      return;
    }
    final entry = RecordingCardConnectionHistoryEntry(
      displayName: displayName,
      safeDeviceFingerprint: fingerprint,
      lastConnectedAt: _clock().toUtc(),
    );
    _recentlyConnectedDevices = <RecordingCardConnectionHistoryEntry>[
      entry,
      for (final existing in _recentlyConnectedDevices)
        if (existing.safeDeviceFingerprint != fingerprint) existing,
    ];
    try {
      _connectionHistory.remember(entry);
    } on Object {
      // Connection history makes future selection more convenient; persistence
      // failures must never change an already-successful BLE connection.
    }
  }

  void _observeRecordingTransition(
    RecordingCardRecordingState previous,
    RecordingCardRecordingState next,
  ) {
    if (_disposed) return;
    if (previous != next) _recordingStateRevision += 1;
    if (next != RecordingCardRecordingState.idle) {
      final batch = _wifiBatchCoordinator.snapshot;
      if (batch != null &&
          batch.isBusy &&
          !batch.stopRequested &&
          batch.state != RecordingCardWifiBatchState.registering) {
        _interruptWifiBatchDownload('RECORDING_CARD_RECORDING_ACTIVE');
        unawaited(
          reconcileWifiBatch(
            interruptionCode: 'RECORDING_CARD_RECORDING_ACTIVE',
          ),
        );
      }
      if (_scanFilesInFlight != null) {
        _activeFileScanConnectionRevision = -1;
        _scanFilesRequested = false;
        _pendingFileRefreshReasons.clear();
        _state = _state.copyWith(
          status: RecordingCardControllerStatus.idle,
          fileCatalog: _state.fileCatalog.transition(
            RecordingCardFileCatalogPhase.failed,
            errorCode: 'RECORDING_CARD_RECORDING_ACTIVE',
          ),
          clearActiveFileKey: true,
        );
        notifyListeners();
      }
      return;
    }
    if (previous == RecordingCardRecordingState.idle ||
        !_state.snapshot.deviceState.isOperationallyConnected) {
      return;
    }
    _recordingCompletionKnownFiles = _state.snapshot.files
        .map(_recordingCardFileSignature)
        .toSet();
    _recordingCompletionRefreshRequested = true;
    _tryStartRecordingCompletionRefresh();
  }

  void _tryStartRecordingCompletionRefresh() {
    if (!_recordingCompletionRefreshRequested ||
        _recordingCompletionRefreshInFlight != null ||
        _disposed ||
        !_state.snapshot.deviceState.isOperationallyConnected ||
        _state.snapshot.recordingInfo.state !=
            RecordingCardRecordingState.idle ||
        _hasRunningTransfer ||
        _scanFilesInFlight != null ||
        (_state.status != RecordingCardControllerStatus.idle &&
            _state.status != RecordingCardControllerStatus.error)) {
      return;
    }
    _recordingCompletionRefreshRequested = false;
    _startRecordingCompletionRefresh();
  }

  void _startRecordingCompletionRefresh() {
    final deviceIdentity = _activeConnectionDeviceIdentity(
      _state.snapshot.deviceState,
    );
    if (deviceIdentity == null) {
      _recordingCompletionRefreshRequested = false;
      _recordingCompletionKnownFiles = null;
      _failFileCatalog(
        recordingCardFailure(
          'RECORDING_CARD_DEVICE_IDENTITY_UNAVAILABLE',
          'Recording-card stable identity is unavailable',
          isRetryable: true,
        ),
      );
      return;
    }
    final knownFiles =
        _recordingCompletionKnownFiles ??
        _state.snapshot.files.map(_recordingCardFileSignature).toSet();
    final connectionRevision = _connectionRevision;
    late final Future<void> operation;
    operation =
        Future<void>.microtask(
          () => _refreshAfterRecordingCompletion(
            knownFiles,
            connectionRevision: connectionRevision,
            deviceIdentity: deviceIdentity,
          ),
        ).whenComplete(() {
          if (identical(_recordingCompletionRefreshInFlight, operation)) {
            _recordingCompletionRefreshInFlight = null;
            if (!_recordingCompletionRefreshRequested) {
              _recordingCompletionKnownFiles = null;
            }
            _tryStartRecordingCompletionRefresh();
            _tryStartAppResumeFileRefresh();
            if (!_disposed) notifyListeners();
          }
        });
    _recordingCompletionRefreshInFlight = operation;
  }

  Future<void> _refreshAfterRecordingCompletion(
    Set<String> knownFiles, {
    required int connectionRevision,
    required String deviceIdentity,
  }) async {
    final delays = _recordingCompletionScanDelays.isEmpty
        ? const <Duration>[Duration.zero]
        : _recordingCompletionScanDelays;
    for (final delay in delays) {
      if (!_ownsFileCatalogWork(connectionRevision, deviceIdentity)) {
        return;
      }
      if (delay > Duration.zero && !await _waitForRecordingSettlement(delay)) {
        return;
      }
      if (!_ownsFileCatalogWork(connectionRevision, deviceIdentity) ||
          _state.snapshot.recordingInfo.state !=
              RecordingCardRecordingState.idle) {
        return;
      }
      final successfulRevision = _successfulFileRefreshRevision;
      await _refreshFiles(
        reason: RecordingCardFileRefreshReason.recordingCompleted,
      );
      if (!_ownsFileCatalogWork(connectionRevision, deviceIdentity)) {
        return;
      }
      if (_successfulFileRefreshRevision == successfulRevision ||
          !hasLoadedFilesForCurrentConnection) {
        continue;
      }
      if (_state.snapshot.files
          .map(_recordingCardFileSignature)
          .any((signature) => !knownFiles.contains(signature))) {
        return;
      }
    }
  }

  Future<void> _awaitRecordingCompletionSettlement() async {
    while (!_disposed &&
        (_recordingCompletionRefreshRequested ||
            _recordingCompletionRefreshInFlight != null)) {
      _tryStartRecordingCompletionRefresh();
      final operation = _recordingCompletionRefreshInFlight;
      if (operation == null) return;
      await operation;
    }
  }

  Future<bool> _waitForRecordingSettlement(Duration delay) async {
    if (_disposed) return false;
    final completer = Completer<void>();
    _recordingCompletionDelayCompleter = completer;
    _recordingCompletionTimer = Timer(delay, () {
      _recordingCompletionTimer = null;
      if (identical(_recordingCompletionDelayCompleter, completer)) {
        _recordingCompletionDelayCompleter = null;
      }
      if (!completer.isCompleted) completer.complete();
    });
    await completer.future;
    return !_disposed;
  }

  void _tryStartAppResumeFileRefresh() {
    if (!_appResumeFileRefreshRequested ||
        _disposed ||
        !_state.snapshot.deviceState.isOperationallyConnected ||
        _state.snapshot.recordingInfo.state !=
            RecordingCardRecordingState.idle ||
        _recordingCompletionRefreshRequested ||
        _recordingCompletionRefreshInFlight != null ||
        _hasRunningTransfer ||
        _scanFilesInFlight != null ||
        (_state.status != RecordingCardControllerStatus.idle &&
            _state.status != RecordingCardControllerStatus.error)) {
      return;
    }
    _appResumeFileRefreshRequested = false;
    unawaited(reconcileConnectionState(refreshDirectory: true));
  }

  Future<void> _refreshAfterBleTransfer() async {
    final operationError = _state.lastErrorCode;
    if (operationError == 'RECORDING_CARD_TRANSFER_CANCELLED' ||
        !_state.snapshot.deviceState.isOperationallyConnected) {
      return;
    }
    await refreshFiles(
      reason: RecordingCardFileRefreshReason.transferCompleted,
    );
    if (operationError == null) return;
    _state = _state.copyWith(
      status: RecordingCardControllerStatus.error,
      lastErrorCode: operationError,
      clearActiveFileKey: true,
    );
    notifyListeners();
  }

  RecordingCardScannedFile _withoutVerifiedLocalProjection(
    RecordingCardScannedFile file,
  ) {
    return RecordingCardScannedFile(
      deviceFileId: file.deviceFileId,
      localFileKey: file.localFileKey,
      deviceFilename: file.deviceFilename,
      sizeBytes: file.sizeBytes,
      durationSeconds: file.durationSeconds,
      recordedAt: file.recordedAt,
      contentHash: file.contentHash,
      sizeConfidence: file.sizeConfidence,
      format: file.format,
      mimeType: file.mimeType,
      syncState: file.syncState == RecordingCardFileSyncState.synced
          ? RecordingCardFileSyncState.localMissing
          : RecordingCardFileSyncState.deviceOnly,
    );
  }

  void _handleRecordingResult(
    RecordingCardResult<RecordingCardRecordingInfo> result, {
    required int revisionBefore,
  }) {
    if (!result.ok || result.value == null) {
      _fail(result.error ?? _fallbackFailure('RECORDING_CARD_COMMAND_FAILED'));
      return;
    }
    _settleControllerOperation();
    final previousRecordingState = _state.snapshot.recordingInfo.state;
    final snapshot = _recordingRevision > revisionBefore
        ? _normalizeRuntimeSnapshot(_port.runtimeSnapshot)
        : _normalizeRuntimeSnapshot(
            _state.snapshot.copyWith(
              recordingInfo: result.value,
              recordingObservation: RecordingCardRecordingObservation(
                info: result.value!,
                source: RecordingCardObservationSource.command,
                revision: _recordingRevision + 1,
                observedAt: _clock(),
              ),
            ),
          );
    _state = _state.copyWith(
      status: RecordingCardControllerStatus.idle,
      snapshot: snapshot,
      clearActiveFileKey: true,
      lastErrorCode: null,
    );
    notifyListeners();
    _observeRecordingTransition(
      previousRecordingState,
      snapshot.recordingInfo.state,
    );
    _tryStartRecordingCompletionRefresh();
    _scheduleDeferredFileRefreshes();
  }

  RecordingCardRuntimeSnapshot _normalizeRuntimeSnapshot(
    RecordingCardRuntimeSnapshot snapshot,
  ) {
    final sanitizedSnapshot = _sanitizeDisconnectedDeviceDirectory(
      _projectWifiHandoffBleState(snapshot),
    );
    if (!sanitizedSnapshot.deviceState.isOperationallyConnected) {
      _recordingAnchor = const RecordingCardRecordingInfo(
        state: RecordingCardRecordingState.idle,
        durationSeconds: 0,
      );
      _recordingObservation = null;
      _recordingRevision = -1;
      return sanitizedSnapshot;
    }
    final previousDevice = _state.snapshot.deviceState;
    final nextDevice = sanitizedSnapshot.deviceState;
    final changedCard =
        (previousDevice.safeDeviceFingerprint != null &&
            nextDevice.safeDeviceFingerprint != null &&
            previousDevice.safeDeviceFingerprint !=
                nextDevice.safeDeviceFingerprint) ||
        (previousDevice.serialNumber != null &&
            nextDevice.serialNumber != null &&
            previousDevice.serialNumber != nextDevice.serialNumber);
    if (!previousDevice.isOperationallyConnected || changedCard) {
      _recordingAnchor = RecordingCardRecordingInfo.idle();
      _recordingObservation = null;
      _recordingRevision = -1;
    }
    final restoredSnapshot = sanitizedSnapshot.copyWith(
      files: _restoreVerifiedDownloads(
        sanitizedSnapshot.files,
        sanitizedSnapshot.deviceState,
      ),
    );
    final observation = restoredSnapshot.recordingObservation;
    if (observation == null || observation.revision <= _recordingRevision) {
      return restoredSnapshot.copyWith(
        recordingInfo: _recordingAnchor,
        recordingObservation: _recordingObservation,
      );
    }
    final merged = mergeRecordingCardRecordingObservation(
      _recordingAnchor,
      observation,
    );
    _recordingAnchor = merged;
    _recordingRevision = observation.revision;
    _recordingObservation = observation.copyWith(info: merged);
    return restoredSnapshot.copyWith(
      recordingInfo: merged,
      recordingObservation: _recordingObservation,
    );
  }

  RecordingCardRuntimeSnapshot _projectWifiHandoffBleState(
    RecordingCardRuntimeSnapshot snapshot,
  ) {
    if (!_wifiHandoffBleUnavailable ||
        !snapshot.deviceState.isOperationallyConnected) {
      return snapshot;
    }
    return snapshot.copyWith(
      deviceState: _wifiHandoffDisconnectedDevice(snapshot.deviceState),
    );
  }

  RecordingCardDeviceState _wifiHandoffDisconnectedDevice(
    RecordingCardDeviceState device,
  ) {
    return device.copyWith(
      connectionState: RecordingCardConnectionState.disconnected,
      connectionStage: RecordingCardConnectionStage.idle,
      clearPermissionProblem: true,
      clearStatusMessage: true,
    );
  }

  void _markWifiHandoffBleUnavailable() {
    _wifiHandoffBleUnavailable = true;
    final previousDevice = _state.snapshot.deviceState;
    final disconnected = _wifiHandoffDisconnectedDevice(previousDevice);
    _resetConnectionAuthorization();
    _state = _state.copyWith(
      snapshot: _sanitizeDisconnectedDeviceDirectory(
        _state.snapshot.copyWith(deviceState: disconnected),
      ),
      clearActiveFileKey: true,
    );
    notifyListeners();
    _observeConnectionTransition(previousDevice, disconnected);
  }

  RecordingCardRuntimeSnapshot _preserveDirectoryUntilVerified(
    RecordingCardRuntimeSnapshot snapshot,
  ) {
    if (!snapshot.deviceState.isOperationallyConnected) return snapshot;
    final identity = _activeConnectionDeviceIdentity(snapshot.deviceState);
    final catalog = _state.fileCatalog;
    if (catalog.isReady &&
        catalog.connectionRevision == _connectionRevision &&
        catalog.deviceIdentity == identity) {
      return snapshot;
    }
    return snapshot.copyWith(files: _state.snapshot.files);
  }

  RecordingCardRuntimeSnapshot _sanitizeDisconnectedDeviceDirectory(
    RecordingCardRuntimeSnapshot snapshot,
  ) {
    if (snapshot.deviceState.isOperationallyConnected) return snapshot;
    return snapshot.copyWith(
      recordingInfo: const RecordingCardRecordingInfo(
        state: RecordingCardRecordingState.idle,
        durationSeconds: 0,
      ),
      files: const <RecordingCardScannedFile>[],
      loadingFiles: false,
      clearDownloadingFileKey: true,
      clearRecordingObservation: true,
      clearTransferProgress: true,
    );
  }

  void _clearDisconnectedDeviceDirectory() {
    final current = _state;
    final snapshot = _sanitizeDisconnectedDeviceDirectory(current.snapshot);
    final shouldResetStatus = switch (current.status) {
      RecordingCardControllerStatus.connecting ||
      RecordingCardControllerStatus.authorizing ||
      RecordingCardControllerStatus.refreshing ||
      RecordingCardControllerStatus.scanning ||
      RecordingCardControllerStatus.syncing ||
      RecordingCardControllerStatus.downloading ||
      RecordingCardControllerStatus.deleting ||
      RecordingCardControllerStatus.commanding ||
      RecordingCardControllerStatus.disconnecting ||
      RecordingCardControllerStatus.cancellingTransfer => true,
      _ => false,
    };
    final catalog = RecordingCardFileCatalogState.disconnected(
      connectionRevision: _connectionRevision,
    );
    final changed =
        !identical(snapshot, current.snapshot) ||
        shouldResetStatus ||
        current.fileCatalog.phase != RecordingCardFileCatalogPhase.disconnected;
    if (!changed) return;
    _state = current.copyWith(
      status: shouldResetStatus
          ? RecordingCardControllerStatus.idle
          : current.status,
      snapshot: snapshot,
      fileCatalog: catalog,
      clearActiveFileKey: true,
      lastErrorCode: current.lastErrorCode,
    );
    notifyListeners();
  }

  Future<RecordingCardResult<RecordingCardDownloadedFile>>
  _handleDownloadedResult(
    RecordingCardResult<RecordingCardDownloadedFile> result,
    RecordingCardScannedFile sourceFile,
    _RecordingCardTransferOwner owner,
  ) async {
    RecordingCardResult<RecordingCardDownloadedFile> reject(
      AppFailure failure,
    ) {
      final ownsTransfer = _ownsTransferOwner(owner);
      if (ownsTransfer) _fail(failure);
      return RecordingCardResult<RecordingCardDownloadedFile>.failure(failure);
    }

    if (!result.ok || result.value == null) {
      return reject(
        result.error ?? _fallbackFailure('RECORDING_CARD_DOWNLOAD_FAILED'),
      );
    }
    final downloaded = result.value!;
    if (downloaded.localFileKey != sourceFile.localFileKey) {
      return reject(
        recordingCardFailure(
          'RECORDING_CARD_DOWNLOAD_IDENTITY_MISMATCH',
          'Recording-card download did not match the selected file',
          isRetryable: false,
        ),
      );
    }
    final integrityFailure = _downloadedFileIntegrityFailure(
      downloaded,
      sourceFile,
    );
    if (integrityFailure != null) return reject(integrityFailure);
    final privateFile = _privateAudioFileFor(downloaded, sourceFile);
    if (privateFile == null) {
      return reject(
        recordingCardFailure(
          'RECORDING_CARD_LOCAL_FILE_METADATA_INVALID',
          'Recording-card download did not provide valid local file metadata',
          isRetryable: false,
        ),
      );
    }
    final registered = await _localRecordingRepository
        .registerDownloadedRecording(
          file: privateFile,
          deviceId: owner.reconnectFingerprint,
          deviceFileId: sourceFile.deviceFileId,
          deviceFingerprint: owner.deviceIdentity,
          deviceFilename: sourceFile.deviceFilename,
          downloadedAt: sourceFile.recordedAt,
        );
    if (!registered.ok || registered.value == null) {
      return reject(
        registered.error ??
            recordingCardFailure(
              'RECORDING_CARD_LOCAL_LIBRARY_REGISTRATION_FAILED',
              'Recording-card download could not be registered locally',
            ),
      );
    }
    final item = registered.value!;
    final verifiedDownload = VerifiedRecordingCardDownload(
      deviceIds: <String>{owner.deviceIdentity, owner.reconnectFingerprint},
      deviceFileId: sourceFile.deviceFileId,
      deviceFingerprint: owner.deviceIdentity,
      deviceFilename: sourceFile.deviceFilename,
      localRecordingId: item.recordingId,
      appPrivateUri: item.appPrivateUri!,
      actualSizeBytes: item.sizeBytes,
      durationSeconds: item.durationSeconds,
      contentHash: safeContentHash(item.contentHash),
    );
    _verifiedDownloadRefreshGeneration += 1;
    _verifiedDownloadsByIdentity = <String, VerifiedRecordingCardDownload>{
      ..._verifiedDownloadsByIdentity,
      for (final identity in verifiedDownload.deviceIds)
        _verifiedDownloadIdentity(identity, sourceFile.deviceFileId):
            verifiedDownload,
    };
    _localRecordingRegistrationRevision += 1;
    final linkedDownload = RecordingCardDownloadedFile(
      localFileKey: downloaded.localFileKey,
      localFileId: item.recordingId,
      appPrivateUri: item.appPrivateUri!,
      displayName: item.displayName,
      durationSeconds: item.durationSeconds,
      sizeBytes: item.sizeBytes,
      contentHash: item.contentHash,
      format: downloaded.format == RecordingCardFileFormat.unknown
          ? sourceFile.format
          : downloaded.format,
      mimeType: downloaded.mimeType ?? sourceFile.mimeType,
    );
    if (!_ownsTransferOwner(owner)) {
      if (!_disposed) notifyListeners();
      return RecordingCardResult<RecordingCardDownloadedFile>.success(
        linkedDownload,
      );
    }
    _state = _state.copyWith(
      snapshot: _state.snapshot.copyWith(
        clearDownloadingFileKey: true,
        files: _state.snapshot.files
            .map(
              (item) => item.localFileKey == linkedDownload.localFileKey
                  ? item.copyWith(
                      syncState: RecordingCardFileSyncState.synced,
                      durationSeconds: linkedDownload.durationSeconds,
                      localFileId: linkedDownload.localFileId,
                      appPrivateUri: linkedDownload.appPrivateUri,
                    )
                  : item,
            )
            .toList(growable: false),
      ),
      lastDownloadedFile: linkedDownload,
      lastErrorCode: null,
    );
    notifyListeners();
    return RecordingCardResult<RecordingCardDownloadedFile>.success(
      linkedDownload,
    );
  }

  Future<RecordingCardResult<RecordingCardDownloadedFile>>
  _registerBatchDownloadedFile(
    RecordingCardDownloadedFile downloaded,
    RecordingCardScannedFile sourceFile, {
    String? fallbackDeviceIdentity,
    String? fallbackReconnectFingerprint,
  }) async {
    if (downloaded.localFileKey != sourceFile.localFileKey) {
      return RecordingCardResult<RecordingCardDownloadedFile>.failure(
        recordingCardFailure(
          'RECORDING_CARD_DOWNLOAD_IDENTITY_MISMATCH',
          'Recording-card download did not match the selected file',
          isRetryable: false,
        ),
      );
    }
    final integrityFailure = _downloadedFileIntegrityFailure(
      downloaded,
      sourceFile,
    );
    if (integrityFailure != null) {
      return RecordingCardResult<RecordingCardDownloadedFile>.failure(
        integrityFailure,
      );
    }
    final privateFile = _privateAudioFileFor(downloaded, sourceFile);
    if (privateFile == null) {
      return RecordingCardResult<RecordingCardDownloadedFile>.failure(
        recordingCardFailure(
          'RECORDING_CARD_LOCAL_FILE_METADATA_INVALID',
          'Recording-card download did not provide valid local file metadata',
          isRetryable: false,
        ),
      );
    }
    final batch = _wifiBatchCoordinator.snapshot;
    final deviceIdentity =
        batch?.deviceIdentity ??
        _downloadDeviceKey(_state.snapshot.deviceState) ??
        fallbackDeviceIdentity;
    if (deviceIdentity == null) {
      return RecordingCardResult<RecordingCardDownloadedFile>.failure(
        recordingCardFailure(
          'RECORDING_CARD_DEVICE_IDENTITY_UNAVAILABLE',
          'Recording-card stable identity is unavailable',
          isRetryable: true,
        ),
      );
    }
    final reconnectFingerprint =
        batch?.deviceFingerprint ??
        _recordingCardReconnectFingerprint(_state.snapshot.deviceState) ??
        fallbackReconnectFingerprint ??
        deviceIdentity;
    final registered = await _localRecordingRepository
        .registerDownloadedRecording(
          file: privateFile,
          deviceId: reconnectFingerprint,
          deviceFileId: sourceFile.deviceFileId,
          deviceFingerprint: deviceIdentity,
          deviceFilename: sourceFile.deviceFilename,
          downloadedAt: sourceFile.recordedAt,
        );
    if (!registered.ok || registered.value == null) {
      return RecordingCardResult<RecordingCardDownloadedFile>.failure(
        registered.error ??
            recordingCardFailure(
              'RECORDING_CARD_LOCAL_LIBRARY_REGISTRATION_FAILED',
              'Recording-card download could not be registered locally',
            ),
      );
    }
    final item = registered.value!;
    final verifiedDownload = VerifiedRecordingCardDownload(
      deviceIds: <String>{deviceIdentity, reconnectFingerprint},
      deviceFileId: sourceFile.deviceFileId,
      deviceFingerprint: deviceIdentity,
      deviceFilename: sourceFile.deviceFilename,
      localRecordingId: item.recordingId,
      appPrivateUri: item.appPrivateUri!,
      actualSizeBytes: item.sizeBytes,
      durationSeconds: item.durationSeconds,
      contentHash: safeContentHash(item.contentHash),
    );
    _verifiedDownloadRefreshGeneration += 1;
    _verifiedDownloadsByIdentity = <String, VerifiedRecordingCardDownload>{
      ..._verifiedDownloadsByIdentity,
      for (final identity in verifiedDownload.deviceIds)
        _verifiedDownloadIdentity(identity, sourceFile.deviceFileId):
            verifiedDownload,
    };
    _localRecordingRegistrationRevision += 1;
    if (!_disposed) notifyListeners();
    return RecordingCardResult<RecordingCardDownloadedFile>.success(
      RecordingCardDownloadedFile(
        localFileKey: downloaded.localFileKey,
        localFileId: item.recordingId,
        appPrivateUri: item.appPrivateUri!,
        displayName: item.displayName,
        durationSeconds: item.durationSeconds,
        sizeBytes: item.sizeBytes,
        contentHash: item.contentHash,
        format: downloaded.format == RecordingCardFileFormat.unknown
            ? sourceFile.format
            : downloaded.format,
        mimeType: downloaded.mimeType ?? sourceFile.mimeType,
      ),
    );
  }

  void _applyLinkedBatchDownload(RecordingCardDownloadedFile linked) {
    _state = _state.copyWith(
      snapshot: _state.snapshot.copyWith(
        clearDownloadingFileKey: true,
        clearTransferProgress: true,
        files: _state.snapshot.files
            .map((item) {
              return item.localFileKey == linked.localFileKey
                  ? item.copyWith(
                      syncState: RecordingCardFileSyncState.synced,
                      durationSeconds: linked.durationSeconds,
                      localFileId: linked.localFileId,
                      appPrivateUri: linked.appPrivateUri,
                    )
                  : item;
            })
            .toList(growable: false),
      ),
      lastDownloadedFile: linked,
      lastErrorCode: null,
    );
    notifyListeners();
  }

  List<RecordingCardScannedFile> _pendingWifiFiles(
    RecordingCardWifiBatchSnapshot batch,
  ) {
    return batch.items
        .where((item) => item.state == RecordingCardWifiBatchItemState.queued)
        .map((item) => item.file)
        .toList(growable: false);
  }

  Future<AppFailure?> _reconcileRestoredWifiLedger(String batchId) async {
    final snapshot = _wifiBatchCoordinator.snapshot;
    if (snapshot == null || snapshot.batchId != batchId) return null;
    var working = snapshot;
    final items = <RecordingCardWifiBatchItem>[...working.items];
    for (var index = 0; index < items.length; index += 1) {
      final item = items[index];
      var transition = _resolveWifiLedgerItem(working, item);
      if (transition.failure != null) {
        _wifiBatchCoordinator.replace(working);
        _wifiBatchLedgerFailureBatchId = batchId;
        return transition.failure;
      }
      if (transition.item.isCompleted) {
        final localRecordingId =
            transition.item.localRecordingId ??
            transition.item.file.localFileId;
        final localItem = _validLocalRecordingForWifiCompletion(
          localRecordingId: localRecordingId,
          ledgerContentHash: transition.ledgerEntry?.contentHash,
          expectedContentHash: transition.item.file.contentHash,
        );
        if (localItem == null) {
          transition = _queueWifiLedgerItem(
            working,
            _wifiBatchItemQueuedForResync(transition.item),
          );
        } else {
          transition = await _completeWifiLedgerItem(
            working,
            transition.item,
            localRecordingId: localItem.recordingId,
            contentHash:
                transition.item.file.contentHash ?? localItem.contentHash,
          );
        }
      } else if (working.stopRequested && item.stagedDownload == null) {
        final ledgerFailure = _failWifiLedgerItems(
          cardSnDigest: _wifiBatchCardSnDigest(working),
          items: <RecordingCardWifiBatchItem>[transition.item],
          errorCode: 'RECORDING_CARD_WIFI_BATCH_STOPPED_BY_USER',
        );
        transition = _RecordingCardWifiLedgerTransition(
          item: transition.item.copyWith(
            state: RecordingCardWifiBatchItemState.cancelled,
          ),
          ledgerEntry: transition.ledgerEntry,
          failure: ledgerFailure,
        );
      } else if (item.state == RecordingCardWifiBatchItemState.failed) {
        final ledgerFailure = _failWifiLedgerItems(
          cardSnDigest: _wifiBatchCardSnDigest(working),
          items: <RecordingCardWifiBatchItem>[transition.item],
          errorCode: item.errorCode ?? 'RECORDING_CARD_WIFI_TRANSFER_FAILED',
        );
        if (ledgerFailure != null) {
          transition = _RecordingCardWifiLedgerTransition(
            item: transition.item,
            ledgerEntry: transition.ledgerEntry,
            failure: ledgerFailure,
          );
        }
      } else {
        transition = _queueWifiLedgerItem(working, item);
      }
      items[index] = transition.item;
      working = working.copyWith(items: items);
      if (transition.failure != null) {
        _wifiBatchCoordinator.replace(working);
        _wifiBatchLedgerFailureBatchId = batchId;
        return transition.failure;
      }
    }
    _wifiBatchCoordinator.replace(working);
    if (_wifiBatchLedgerFailureBatchId == batchId) {
      _wifiBatchLedgerFailureBatchId = null;
    }
    return null;
  }

  _RecordingCardWifiLedgerTransition _queueWifiLedgerItem(
    RecordingCardWifiBatchSnapshot batch,
    RecordingCardWifiBatchItem item,
  ) {
    final resolved = _resolveWifiLedgerItem(batch, item);
    final persistence = _syncLedgerPersistence;
    if (resolved.failure != null || persistence == null) return resolved;
    final cardSnDigest = _wifiBatchCardSnDigest(batch);
    final sourceSignature = resolved.item.ledgerSourceSignature;
    if (cardSnDigest == null || sourceSignature == null) {
      return _RecordingCardWifiLedgerTransition(
        item: resolved.item,
        failure: _fallbackFailure('RECORDING_CARD_LEDGER_IDENTITY_UNAVAILABLE'),
      );
    }
    try {
      if (resolved.item.isCompleted &&
          resolved.ledgerEntry?.localState ==
              RecordingCardFileLocalState.synced) {
        return resolved;
      }
      final queued = resolved.ledgerEntry == null
          ? persistence.queueManualSyncForFile(
              cardSnDigest: cardSnDigest,
              file: resolved.item.file,
              at: _clock(),
            )
          : persistence.queueManualSync(
              cardSnDigest: cardSnDigest,
              sourceSignature: sourceSignature,
              at: _clock(),
            );
      final localCopyMissing =
          resolved.ledgerEntry?.localState ==
              RecordingCardFileLocalState.synced &&
          !resolved.item.isCompleted;
      return _RecordingCardWifiLedgerTransition(
        item: resolved.item.copyWith(
          state: localCopyMissing
              ? RecordingCardWifiBatchItemState.queued
              : resolved.item.state,
          ledgerSourceSignature: queued.sourceSignature,
          clearError: localCopyMissing,
          clearStagedDownload: localCopyMissing,
        ),
        ledgerEntry: queued,
      );
    } catch (error) {
      return _RecordingCardWifiLedgerTransition(
        item: resolved.item,
        failure: recordingCardFailure(
          'RECORDING_CARD_LEDGER_RECONCILIATION_FAILED',
          'Recording-card sync ledger could not queue an item',
          cause: error,
          isRetryable: true,
        ),
      );
    }
  }

  Future<AppFailure?> _completeSkippedWifiLedgerItems(
    RecordingCardWifiBatchSnapshot batch,
  ) async {
    for (var index = 0; index < batch.items.length; index += 1) {
      final current = _wifiBatchCoordinator.snapshot;
      if (current == null || index >= current.items.length) {
        return _fallbackFailure('RECORDING_CARD_WIFI_BATCH_NOT_RECOVERABLE');
      }
      final item = current.items[index];
      if (item.state != RecordingCardWifiBatchItemState.skipped) continue;
      final localRecordingId = item.localRecordingId ?? item.file.localFileId;
      final transition = await _completeWifiLedgerItem(
        current,
        item,
        localRecordingId: localRecordingId,
        contentHash: item.file.contentHash,
      );
      if (transition.failure != null) return transition.failure;
      if (!identical(transition.item, item)) {
        _replaceWifiBatchItem(index, transition.item);
      }
    }
    return null;
  }

  _RecordingCardWifiLedgerTransition _beginWifiLedgerItem(
    RecordingCardWifiBatchSnapshot batch,
    RecordingCardWifiBatchItem item,
  ) {
    final resolved = _resolveWifiLedgerItem(batch, item);
    final persistence = _syncLedgerPersistence;
    if (resolved.failure != null || persistence == null) {
      return resolved;
    }
    if (resolved.item.isCompleted &&
        resolved.ledgerEntry?.localState ==
            RecordingCardFileLocalState.synced) {
      return resolved;
    }
    final cardSnDigest = _wifiBatchCardSnDigest(batch);
    final sourceSignature = resolved.item.ledgerSourceSignature;
    if (cardSnDigest == null || sourceSignature == null) {
      return _RecordingCardWifiLedgerTransition(
        item: resolved.item,
        failure: _fallbackFailure('RECORDING_CARD_LEDGER_IDENTITY_UNAVAILABLE'),
      );
    }
    try {
      final syncing = resolved.ledgerEntry == null
          ? persistence.beginManualSyncForFile(
              cardSnDigest: cardSnDigest,
              file: resolved.item.file,
              at: _clock(),
            )
          : persistence.beginManualSync(
              cardSnDigest: cardSnDigest,
              sourceSignature: sourceSignature,
              at: _clock(),
            );
      return _RecordingCardWifiLedgerTransition(
        item: resolved.item.copyWith(
          ledgerSourceSignature: syncing.sourceSignature,
        ),
        ledgerEntry: syncing,
      );
    } catch (error) {
      return _RecordingCardWifiLedgerTransition(
        item: resolved.item,
        failure: recordingCardFailure(
          'RECORDING_CARD_LEDGER_BEGIN_FAILED',
          'Recording-card sync ledger could not begin an item',
          cause: error,
          isRetryable: true,
        ),
      );
    }
  }

  Future<_RecordingCardWifiLedgerTransition> _completeWifiLedgerItem(
    RecordingCardWifiBatchSnapshot batch,
    RecordingCardWifiBatchItem item, {
    required String? localRecordingId,
    String? contentHash,
  }) async {
    final resolved = _resolveWifiLedgerItem(batch, item);
    final persistence = _syncLedgerPersistence;
    if (resolved.failure != null || persistence == null) {
      return resolved;
    }
    final normalizedLocalId =
        (resolved.item.localRecordingId ?? localRecordingId)?.trim();
    if (normalizedLocalId == null || normalizedLocalId.isEmpty) {
      return _RecordingCardWifiLedgerTransition(
        item: resolved.item,
        ledgerEntry: resolved.ledgerEntry,
        failure: _fallbackFailure(
          'RECORDING_CARD_LOCAL_LIBRARY_REGISTRATION_FAILED',
        ),
      );
    }
    final cardSnDigest = _wifiBatchCardSnDigest(batch);
    final sourceSignature = resolved.item.ledgerSourceSignature;
    if (cardSnDigest == null || sourceSignature == null) {
      return _RecordingCardWifiLedgerTransition(
        item: resolved.item,
        failure: _fallbackFailure('RECORDING_CARD_LEDGER_IDENTITY_UNAVAILABLE'),
      );
    }
    try {
      final currentLedger =
          resolved.ledgerEntry ??
          persistence.queueManualSyncForFile(
            cardSnDigest: cardSnDigest,
            file: resolved.item.file,
            at: _clock(),
          );
      if (currentLedger.localState ==
              RecordingCardFileLocalState.localDeleted ||
          currentLedger.localState == RecordingCardFileLocalState.deleting) {
        return _RecordingCardWifiLedgerTransition(
          item: resolved.item,
          failure: recordingCardFailure(
            'RECORDING_CARD_LOCAL_FILE_DELETED',
            'Recording-card local file was deleted before ledger completion',
            isRetryable: false,
          ),
        );
      }
      if (currentLedger.localState != RecordingCardFileLocalState.synced &&
          currentLedger.localState != RecordingCardFileLocalState.queued &&
          currentLedger.localState != RecordingCardFileLocalState.syncing) {
        persistence.queueManualSync(
          cardSnDigest: cardSnDigest,
          sourceSignature: sourceSignature,
          at: _clock(),
        );
      }
      persistence.completeManualSync(
        cardSnDigest: cardSnDigest,
        sourceSignature: sourceSignature,
        localRecordingId: normalizedLocalId,
        contentHash: contentHash,
        at: _clock(),
      );
      final flushFailure = await _flushWifiBatchPersistence();
      if (flushFailure != null) {
        return _RecordingCardWifiLedgerTransition(
          item: resolved.item,
          failure: recordingCardFailure(
            'RECORDING_CARD_LEDGER_COMPLETION_FAILED',
            'Recording-card sync ledger completion was not durable',
            cause: flushFailure,
            isRetryable: true,
          ),
        );
      }
      return resolved;
    } catch (error) {
      return _RecordingCardWifiLedgerTransition(
        item: resolved.item,
        failure: recordingCardFailure(
          'RECORDING_CARD_LEDGER_COMPLETION_FAILED',
          'Recording-card sync ledger could not complete an item',
          cause: error,
          isRetryable: true,
        ),
      );
    }
  }

  _RecordingCardWifiLedgerTransition _resolveWifiLedgerItem(
    RecordingCardWifiBatchSnapshot batch,
    RecordingCardWifiBatchItem item,
  ) {
    final persistence = _syncLedgerPersistence;
    if (persistence == null) {
      return _RecordingCardWifiLedgerTransition(item: item);
    }
    final digest = _wifiBatchCardSnDigest(batch);
    if (digest == null) {
      return _RecordingCardWifiLedgerTransition(
        item: item,
        failure: _fallbackFailure('RECORDING_CARD_LEDGER_IDENTITY_UNAVAILABLE'),
      );
    }
    try {
      RecordingCardFileLedgerEntry? entry;
      final currentContentHash = safeContentHash(item.file.contentHash);
      final persistedSignature = item.ledgerSourceSignature?.trim();
      if (persistedSignature != null && persistedSignature.isNotEmpty) {
        entry = persistence.findFileLedgerEntry(
          cardSnDigest: digest,
          sourceSignature: persistedSignature,
        );
        if (_wifiContentHashesConflict(
          currentContentHash,
          entry?.contentHash,
        )) {
          entry = null;
        }
      }
      final exactSignature = RecordingCardFileIdentity.sourceSignatureFor(
        cardSnDigest: digest,
        deviceFileId: item.file.deviceFileId,
        deviceFilename: item.file.deviceFilename,
        sizeBytes: item.file.sizeBytes,
        recordedAt: item.file.recordedAt,
      );
      entry ??= persistence.findFileLedgerEntry(
        cardSnDigest: digest,
        sourceSignature: exactSignature,
      );
      if (_wifiContentHashesConflict(currentContentHash, entry?.contentHash)) {
        entry = null;
      }
      if (entry == null && currentContentHash != null) {
        final matches = persistence
            .loadFileLedger(digest)
            .where(
              (candidate) =>
                  safeContentHash(candidate.contentHash) == currentContentHash,
            )
            .toList(growable: false);
        if (matches.length == 1) entry = matches.single;
      }
      var resolvedItem = item.copyWith(
        ledgerSourceSignature: entry?.sourceSignature ?? exactSignature,
      );
      final localItem = _validLocalRecordingForWifiLedger(
        entry,
        expectedContentHash: currentContentHash,
      );
      if (localItem != null) {
        resolvedItem = resolvedItem.copyWith(
          file: resolvedItem.file.copyWith(
            syncState: RecordingCardFileSyncState.synced,
            localFileId: localItem.recordingId,
            appPrivateUri: localItem.appPrivateUri,
          ),
          state: RecordingCardWifiBatchItemState.completed,
          localRecordingId: localItem.recordingId,
          clearError: true,
          clearStagedDownload: true,
        );
      }
      return _RecordingCardWifiLedgerTransition(
        item: resolvedItem,
        ledgerEntry: entry,
      );
    } catch (error) {
      return _RecordingCardWifiLedgerTransition(
        item: item,
        failure: recordingCardFailure(
          'RECORDING_CARD_LEDGER_RECONCILIATION_FAILED',
          'Recording-card sync ledger could not resolve an item',
          cause: error,
          isRetryable: true,
        ),
      );
    }
  }

  RecordingLibraryItem? _validLocalRecordingForWifiLedger(
    RecordingCardFileLedgerEntry? entry, {
    String? expectedContentHash,
  }) {
    if (entry == null || !entry.hasValidLocalRecording) return null;
    return _validLocalRecordingForWifiCompletion(
      localRecordingId: entry.localRecordingId,
      ledgerContentHash: entry.contentHash,
      expectedContentHash: expectedContentHash,
    );
  }

  RecordingLibraryItem? _validLocalRecordingForWifiCompletion({
    required String? localRecordingId,
    String? ledgerContentHash,
    String? expectedContentHash,
  }) {
    final localId = localRecordingId?.trim();
    if (localId == null || localId.isEmpty) return null;
    final localItem = _localRecordingRepository.findById(localId);
    final privateUri = localItem?.appPrivateUri?.trim();
    if (localItem == null ||
        localItem.localFileState != RecordingLocalFileState.ready ||
        privateUri == null ||
        privateUri.isEmpty ||
        !isSafeAppPrivateUri(privateUri)) {
      return null;
    }
    final ledgerHash = safeContentHash(ledgerContentHash);
    final localHash = safeContentHash(localItem.contentHash);
    final expectedHash = safeContentHash(expectedContentHash);
    if (_wifiContentHashesConflict(ledgerHash, localHash) ||
        _wifiContentHashesConflict(expectedHash, ledgerHash) ||
        _wifiContentHashesConflict(expectedHash, localHash) ||
        (expectedHash != null && ledgerHash == null && localHash == null)) {
      return null;
    }
    return localItem;
  }

  bool _wifiContentHashesConflict(String? left, String? right) {
    final safeLeft = safeContentHash(left);
    final safeRight = safeContentHash(right);
    return safeLeft != null && safeRight != null && safeLeft != safeRight;
  }

  RecordingCardWifiBatchItem _wifiBatchItemQueuedForResync(
    RecordingCardWifiBatchItem item,
  ) {
    return RecordingCardWifiBatchItem(
      file: _withoutVerifiedLocalProjection(item.file),
      state: RecordingCardWifiBatchItemState.queued,
      order: item.order,
      expectedSizeBytes: item.expectedSizeBytes,
      attemptCount: item.attemptCount,
      ledgerSourceSignature: item.ledgerSourceSignature,
    );
  }

  AppFailure? _failWifiLedgerItems({
    required String? cardSnDigest,
    required Iterable<RecordingCardWifiBatchItem> items,
    required String errorCode,
  }) {
    final persistence = _syncLedgerPersistence;
    if (persistence == null) return null;
    if (cardSnDigest == null) {
      return _fallbackFailure('RECORDING_CARD_LEDGER_IDENTITY_UNAVAILABLE');
    }
    AppFailure? firstFailure;
    for (final item in items) {
      final signature = item.ledgerSourceSignature;
      if (signature == null) {
        firstFailure ??= _fallbackFailure(
          'RECORDING_CARD_LEDGER_IDENTITY_UNAVAILABLE',
        );
        continue;
      }
      try {
        final current = persistence.findFileLedgerEntry(
          cardSnDigest: cardSnDigest,
          sourceSignature: signature,
        );
        if (current == null ||
            current.localState == RecordingCardFileLocalState.synced) {
          continue;
        }
        final stoppedByUser =
            errorCode == 'RECORDING_CARD_WIFI_BATCH_STOPPED_BY_USER';
        if (current.localState == RecordingCardFileLocalState.failed) {
          if (!stoppedByUser) continue;
          final at = _clock();
          if (current.errorCode == errorCode) {
            if (current.resumeRequested) {
              persistence.saveFileLedgerEntry(
                current.clearBluetoothResumeRequest(at),
              );
            }
            continue;
          }
          final stopped = current
              .queue(at: at, manual: true)
              .markFailed(
                at: at,
                errorCode: errorCode,
                retryability: RecordingCardSyncRetryability.permanent,
              )
              .clearBluetoothResumeRequest(at);
          persistence.saveFileLedgerEntry(stopped);
          continue;
        }
        final failed = persistence.failManualSync(
          cardSnDigest: cardSnDigest,
          sourceSignature: signature,
          errorCode: errorCode,
          retryability: _manualWifiSyncRetryability(errorCode),
          at: _clock(),
        );
        if (stoppedByUser) {
          persistence.saveFileLedgerEntry(
            failed.clearBluetoothResumeRequest(_clock()),
          );
        }
      } catch (error) {
        firstFailure ??= recordingCardFailure(
          'RECORDING_CARD_LEDGER_FAILURE_PERSIST_FAILED',
          'Recording-card sync ledger could not persist item failure',
          cause: error,
          isRetryable: true,
        );
      }
    }
    final batchId = _wifiBatchCoordinator.snapshot?.batchId;
    if (firstFailure != null && batchId != null) {
      _wifiBatchLedgerFailureBatchId = batchId;
    }
    return firstFailure;
  }

  AppFailure? _persistWifiBatch(
    RecordingCardWifiBatchSnapshot batch, {
    bool allowLegacyIdentityUpgrade = false,
  }) {
    final result = _localRecordingRepository
        .writeRecordingCardWifiBatchAtomically(() {
          for (final item in batch.items) {
            _upsertWifiBatchItem(
              batch,
              item,
              allowLegacyIdentityUpgrade: allowLegacyIdentityUpgrade,
            );
          }
        });
    if (result.ok) {
      if (_wifiBatchPersistenceFailureBatchId == batch.batchId) {
        _wifiBatchPersistenceFailureBatchId = null;
      }
      return null;
    }
    _wifiBatchPersistenceFailureBatchId = batch.batchId;
    return recordingCardFailure(
      'RECORDING_CARD_WIFI_BATCH_PERSIST_FAILED',
      'Recording-card Wi-Fi batch could not be persisted atomically',
      cause: result.error,
    );
  }

  Future<AppFailure?> _persistWifiBatchDurably(
    RecordingCardWifiBatchSnapshot batch, {
    bool allowLegacyIdentityUpgrade = false,
  }) async {
    final persistenceFailure = _persistWifiBatch(
      batch,
      allowLegacyIdentityUpgrade: allowLegacyIdentityUpgrade,
    );
    if (persistenceFailure != null) return persistenceFailure;
    final flushFailure = await _flushWifiBatchPersistence();
    if (flushFailure == null) return null;
    _wifiBatchPersistenceFailureBatchId = batch.batchId;
    return recordingCardFailure(
      'RECORDING_CARD_WIFI_BATCH_PERSIST_FAILED',
      'Recording-card Wi-Fi batch did not reach durable storage',
      cause: flushFailure,
      isRetryable: true,
    );
  }

  Future<AppFailure?> _flushWifiBatchPersistence() async {
    try {
      final result = await _localRecordingRepository
          .flushRecordingCardPersistence()
          .timeout(_localVerificationTimeout);
      if (!result.ok) {
        return recordingCardFailure(
          'RECORDING_CARD_WIFI_BATCH_CHECKPOINT_FAILED',
          'Recording-card Wi-Fi checkpoint did not reach durable storage',
          cause: result.error,
        );
      }
      await _syncLedgerPersistence?.flushSyncPersistence().timeout(
        _localVerificationTimeout,
      );
      return null;
    } catch (error) {
      return recordingCardFailure(
        'RECORDING_CARD_WIFI_BATCH_CHECKPOINT_FAILED',
        'Recording-card Wi-Fi checkpoint could not settle within its deadline',
        cause: error,
        isRetryable: true,
      );
    }
  }

  AppFailure? _persistWifiBatchItem(
    RecordingCardWifiBatchSnapshot batch,
    RecordingCardWifiBatchItem item, {
    bool checkpointOnly = false,
  }) {
    try {
      _upsertWifiBatchItem(batch, item, checkpointOnly: checkpointOnly);
      return null;
    } catch (error) {
      return recordingCardFailure(
        'RECORDING_CARD_WIFI_BATCH_CHECKPOINT_FAILED',
        'Recording-card Wi-Fi staged file checkpoint could not be persisted',
        cause: error,
      );
    }
  }

  void _upsertWifiBatchItem(
    RecordingCardWifiBatchSnapshot batch,
    RecordingCardWifiBatchItem item, {
    bool checkpointOnly = false,
    bool allowLegacyIdentityUpgrade = false,
  }) {
    final file = item.file;
    final staged = _stagedWifiDownloadMetadata(item.stagedDownload, file);
    final idempotency = sha256
        .convert(
          utf8.encode(
            '${batch.deviceIdentity}:${file.deviceFileId}:${batch.batchId}',
          ),
        )
        .toString();
    _localRecordingRepository.upsertRecordingCardWifiBatchItem(
      transferId: _wifiBatchTransferId(batch.batchId, item.order),
      batchId: batch.batchId,
      deviceFingerprint: batch.deviceFingerprint,
      deviceIdentity: batch.deviceIdentity,
      cardSnDigest: batch.cardSnDigest,
      deviceFileId: file.deviceFileId,
      deviceFilename: file.deviceFilename,
      localFileKey: file.localFileKey,
      itemOrder: item.order,
      expectedSizeBytes: item.effectiveSizeBytes,
      attemptCount: item.attemptCount,
      batchStage: batch.state.name,
      batchErrorCode: batch.failureCode,
      stage: item.state.name,
      idempotencyKey: idempotency,
      createdAt: batch.createdAt,
      updatedAt: batch.updatedAt,
      errorCode: item.errorCode,
      localRecordingId: item.localRecordingId,
      ledgerSourceSignature: item.ledgerSourceSignature,
      fileFormat: file.format.name,
      mimeType: file.mimeType,
      durationSeconds: file.durationSeconds,
      recordedAt: file.recordedAt,
      contentHash: file.contentHash,
      sourceSizeConfidence: file.sizeConfidence?.name,
      plannedNativeFileId: item.plannedNativeFileId,
      attemptId: batch.attemptId,
      stopRequested: batch.stopRequested,
      stagedNativeFileId: staged?.nativeFileId,
      stagedFileFormat: staged?.format,
      stagedSizeBytes: staged?.sizeBytes,
      stagedContentHash: staged?.contentHash,
      checkpointOnly: checkpointOnly,
      allowLegacyIdentityUpgrade: allowLegacyIdentityUpgrade,
    );
  }

  RecordingCardWifiBatchSnapshot? _wifiBatchFromRecords(
    List<Map<String, Object?>> rows,
  ) {
    if (rows.isEmpty) return null;
    final grouped = <String, List<Map<String, Object?>>>{};
    for (final row in rows) {
      final batchId = _safeBatchRecordText(row['batch_id']);
      if (batchId != null) grouped.putIfAbsent(batchId, () => []).add(row);
    }
    if (grouped.isEmpty) return null;
    final latest = grouped.entries.reduce((left, right) {
      final leftAt = _latestBatchRecordAt(left.value);
      final rightAt = _latestBatchRecordAt(right.value);
      return rightAt.isAfter(leftAt) ? right : left;
    });
    final sorted = <Map<String, Object?>>[...latest.value]
      ..sort(
        (left, right) => _batchRecordInt(
          left['item_order'],
        ).compareTo(_batchRecordInt(right['item_order'])),
      );
    final first = sorted.first;
    final fingerprint = _safeBatchRecordText(first['device_fingerprint']);
    final deviceIdentity =
        _safeBatchRecordText(first['device_identity']) ?? fingerprint;
    final cardSnDigest = _safeBatchDigest(first['card_sn_digest']);
    final rawState = _wifiBatchState(first['batch_stage']);
    RecordingCardWifiBatchSnapshot blocked() => RecordingCardWifiBatchSnapshot(
      batchId: latest.key,
      deviceFingerprint: fingerprint ?? '',
      deviceIdentity: deviceIdentity ?? '',
      cardSnDigest: cardSnDigest,
      state: sorted.every((row) => row['stop_requested'] == true)
          ? RecordingCardWifiBatchState.cancelled
          : RecordingCardWifiBatchState.paused,
      items: const [],
      createdAt: _latestBatchRecordAt(sorted),
      updatedAt: _latestBatchRecordAt(sorted),
      stopRequested: sorted.every((row) => row['stop_requested'] == true),
      failureCode: 'RECORDING_CARD_WIFI_BATCH_RECORD_INVALID',
    );
    if (fingerprint == null ||
        deviceIdentity == null ||
        (first.containsKey('device_identity') &&
            _safeBatchRecordText(first['device_identity']) == null) ||
        rawState == null ||
        _recordingCardReconnectFingerprintValue(fingerprint) == null ||
        !_isPersistableRecordingCardDeviceIdentity(deviceIdentity)) {
      return blocked();
    }
    final interrupted =
        rawState == RecordingCardWifiBatchState.awaitingHotspot ||
        rawState == RecordingCardWifiBatchState.openingSession ||
        rawState == RecordingCardWifiBatchState.transferring ||
        rawState == RecordingCardWifiBatchState.verifying ||
        rawState == RecordingCardWifiBatchState.registering;
    final items = <RecordingCardWifiBatchItem>[];
    for (final row in sorted) {
      final deviceFileId = _safeBatchRecordText(row['device_file_id']);
      final deviceFilename = _safeBatchRecordText(row['device_filename']);
      final localFileKey = _safeBatchRecordText(row['local_file_key']);
      final itemState = _wifiBatchItemState(row['stage']);
      if (deviceFileId == null ||
          deviceFilename == null ||
          localFileKey == null ||
          itemState == null) {
        return blocked();
      }
      if (row['device_fingerprint'] != first['device_fingerprint'] ||
          row['device_identity'] != first['device_identity'] ||
          (row['planned_native_file_id'] != null &&
              _safePlannedWifiTarget(row['planned_native_file_id']) == null)) {
        return blocked();
      }
      final expectedSize = _batchRecordInt(row['expected_size_bytes']);
      final file = RecordingCardScannedFile(
        deviceFileId: deviceFileId,
        localFileKey: localFileKey,
        deviceFilename: deviceFilename,
        sizeBytes: expectedSize > 0 ? expectedSize : null,
        sizeConfidence: switch (row['source_size_confidence']) {
          'trusted' => RecordingCardFileSizeConfidence.trusted,
          'suspect' => RecordingCardFileSizeConfidence.suspect,
          _ => null,
        },
        durationSeconds: _nullableBatchRecordInt(row['duration_seconds']),
        recordedAt: _batchRecordDate(row['recorded_at']),
        contentHash: _safeBatchRecordText(row['content_hash']),
        format: _recordingCardFileFormat(row['file_format']),
        mimeType: _safeBatchRecordText(row['mime_type']),
      );
      final staged = _stagedWifiDownloadFromRecord(row, file);
      final hasAnyStagedMetadata =
          row['staged_native_file_id'] != null ||
          row['staged_file_format'] != null ||
          row['staged_size_bytes'] != null ||
          row['staged_content_hash'] != null;
      final restoredState =
          staged != null &&
              itemState != RecordingCardWifiBatchItemState.completed &&
              itemState != RecordingCardWifiBatchItemState.skipped
          ? RecordingCardWifiBatchItemState.verifying
          : itemState == RecordingCardWifiBatchItemState.transferring ||
                itemState == RecordingCardWifiBatchItemState.verifying ||
                itemState == RecordingCardWifiBatchItemState.registering ||
                hasAnyStagedMetadata
          ? RecordingCardWifiBatchItemState.queued
          : itemState;
      items.add(
        RecordingCardWifiBatchItem(
          file: file,
          state: restoredState,
          order: _batchRecordInt(row['item_order']),
          expectedSizeBytes: expectedSize,
          attemptCount: _batchRecordInt(row['attempt_count']),
          errorCode: _safeBatchRecordText(row['error_code']),
          localRecordingId: _safeBatchRecordText(row['local_recording_id']),
          ledgerSourceSignature: _safeBatchDigest(
            row['ledger_source_signature'],
          ),
          stagedDownload: staged,
          plannedNativeFileId: _safePlannedWifiTarget(
            row['planned_native_file_id'],
          ),
        ),
      );
    }
    if (items.isEmpty ||
        items.map((item) => item.order).toSet().length != items.length ||
        items.map((item) => item.file.deviceFileId).toSet().length !=
            items.length) {
      return blocked();
    }
    final createdAt =
        _batchRecordDate(first['created_at']) ??
        DateTime.fromMillisecondsSinceEpoch(0);
    final updatedAt = _latestBatchRecordAt(sorted);
    final state = interrupted ? RecordingCardWifiBatchState.paused : rawState;
    return RecordingCardWifiBatchSnapshot(
      batchId: latest.key,
      deviceFingerprint: fingerprint,
      deviceIdentity: deviceIdentity,
      cardSnDigest: cardSnDigest,
      attemptId: _safeBatchRecordText(first['attempt_id']),
      stopRequested: sorted.any((row) => row['stop_requested'] == true),
      failureCode:
          _safeBatchRecordText(first['batch_error_code']) ??
          (interrupted ? 'RECORDING_CARD_WIFI_PROCESS_INTERRUPTED' : null),
      state: state,
      items: List<RecordingCardWifiBatchItem>.unmodifiable(items),
      createdAt: createdAt,
      updatedAt: updatedAt,
      currentItemIndex: state == RecordingCardWifiBatchState.paused
          ? items.indexWhere(
              (item) =>
                  item.stagedDownload != null ||
                  item.state == RecordingCardWifiBatchItemState.queued,
            )
          : null,
    );
  }

  bool _applyWifiBatchProgress(RecordingCardTransferProgress? progress) {
    final batch = _wifiBatchCoordinator.snapshot;
    if (batch == null || !batch.isActive || progress == null) return false;
    final progressBatchId = progress.batchId;
    if (progressBatchId != null && progressBatchId != batch.batchId) {
      return false;
    }
    final current = batch.currentItem;
    if (current == null || current.file.localFileKey != progress.localFileKey) {
      return false;
    }
    final progressTotal = progress.totalBytes;
    final knownTotal = progressTotal != null && progressTotal > 0
        ? progressTotal
        : current.effectiveSizeBytes;
    final currentBytes = knownTotal > 0
        ? progress.receivedBytes.clamp(0, knownTotal).toInt()
        : (progress.receivedBytes < 0 ? 0 : progress.receivedBytes);
    final observedRate = progress.bytesPerSecond;
    final hasValidRateSample =
        observedRate != null && observedRate.isFinite && observedRate > 0;
    final rateSampleCount = hasValidRateSample
        ? batch.rateSampleCount + 1
        : batch.rateSampleCount;
    final displayRate = rateSampleCount >= 2
        ? (hasValidRateSample ? observedRate : batch.bytesPerSecond)
        : null;
    final currentRemainingBytes = knownTotal <= 0
        ? null
        : (knownTotal - currentBytes).clamp(0, knownTotal).toInt();
    final aggregateRemainingBytes = batch.totalBytes <= 0
        ? null
        : (batch.totalBytes - batch.completedBytes - currentBytes)
              .clamp(0, batch.totalBytes)
              .toInt();
    final currentFileEta = currentRemainingBytes == null
        ? null
        : currentRemainingBytes == 0
        ? 0
        : displayRate == null
        ? null
        : (currentRemainingBytes / displayRate).ceil();
    final aggregateEta = aggregateRemainingBytes == null
        ? null
        : aggregateRemainingBytes == 0
        ? 0
        : displayRate == null
        ? null
        : (aggregateRemainingBytes / displayRate).ceil();
    if (batch.receivedBytes == currentBytes &&
        batch.bytesPerSecond == displayRate &&
        batch.rateSampleCount == rateSampleCount &&
        batch.currentFileEstimatedRemainingSeconds == currentFileEta &&
        batch.aggregateEstimatedRemainingSeconds == aggregateEta) {
      return false;
    }
    _wifiBatchCoordinator.replace(
      batch.copyWith(
        receivedBytes: currentBytes,
        bytesPerSecond: displayRate,
        currentFileEstimatedRemainingSeconds: currentFileEta,
        aggregateEstimatedRemainingSeconds: aggregateEta,
        rateSampleCount: rateSampleCount,
        updatedAt: progress.updatedAt ?? _clock(),
      ),
    );
    return true;
  }

  String? _activeConnectionDeviceIdentity(RecordingCardDeviceState device) {
    if (!device.isOperationallyConnected) return null;
    return _recordingCardDeviceIdentity(device) ?? _connectionDeviceIdentity;
  }

  String? _activeReconnectFingerprint(RecordingCardDeviceState device) {
    if (!device.isOperationallyConnected) return null;
    return _recordingCardReconnectFingerprint(device) ??
        _recordingCardReconnectFingerprintValue(_connectionFingerprint);
  }

  _RecordingCardTransferOwner? _captureVerifiedTransferOwner(
    RecordingCardScannedFile file,
  ) {
    final device = _state.snapshot.deviceState;
    final deviceIdentity = _activeConnectionDeviceIdentity(device);
    final reconnectFingerprint = _activeReconnectFingerprint(device);
    final fileSignature = _recordingCardFileSignature(file);
    if (!hasLoadedFilesForCurrentConnection ||
        deviceIdentity == null ||
        reconnectFingerprint == null ||
        !_state.snapshot.files.any(
          (current) => _recordingCardFileSignature(current) == fileSignature,
        )) {
      return null;
    }
    return _RecordingCardTransferOwner(
      connectionRevision: _connectionRevision,
      deviceIdentity: deviceIdentity,
      reconnectFingerprint: reconnectFingerprint,
      fileSignature: fileSignature,
    );
  }

  _RecordingCardBluetoothBatchOwner? _captureVerifiedBluetoothBatchOwner(
    List<RecordingCardScannedFile> files,
  ) {
    final device = _state.snapshot.deviceState;
    final deviceIdentity = _activeConnectionDeviceIdentity(device);
    final reconnectFingerprint = _activeReconnectFingerprint(device);
    final cardSnDigest = _recordingCardDigestForDevice(device);
    if (files.isEmpty ||
        !hasLoadedFilesForCurrentConnection ||
        deviceIdentity == null ||
        reconnectFingerprint == null ||
        (_syncLedgerPersistence != null && cardSnDigest == null)) {
      return null;
    }
    final directorySignatures = _state.snapshot.files
        .map(_recordingCardFileSignature)
        .toSet();
    if (files.any(
      (file) =>
          !directorySignatures.contains(_recordingCardFileSignature(file)),
    )) {
      return null;
    }
    return _RecordingCardBluetoothBatchOwner(
      connectionRevision: _connectionRevision,
      deviceIdentity: deviceIdentity,
      reconnectFingerprint: reconnectFingerprint,
      directorySignatures: Set<String>.unmodifiable(directorySignatures),
      cardSnDigest: cardSnDigest,
    );
  }

  List<RecordingCardScannedFile>? _canonicalBluetoothBatchFiles(
    List<RecordingCardScannedFile> selected,
    _RecordingCardBluetoothBatchOwner owner,
  ) {
    if (!_ownsBluetoothBatchOwner(owner)) return null;
    final currentBySignature = <String, RecordingCardScannedFile>{
      for (final file in _state.snapshot.files)
        _recordingCardFileSignature(file): file,
    };
    final canonical = <RecordingCardScannedFile>[];
    final seen = <String>{};
    for (final file in selected) {
      final signature = _recordingCardFileSignature(file);
      final current = currentBySignature[signature];
      if (current == null) return null;
      if (seen.add(signature)) canonical.add(current);
    }
    return List<RecordingCardScannedFile>.unmodifiable(canonical);
  }

  bool _ownsBluetoothBatchOwner(_RecordingCardBluetoothBatchOwner owner) {
    return _ownsReadyFileCatalog(
          revision: owner.connectionRevision,
          deviceIdentity: owner.deviceIdentity,
          directorySignatures: owner.directorySignatures,
        ) &&
        _activeReconnectFingerprint(_state.snapshot.deviceState) ==
            owner.reconnectFingerprint &&
        _recordingCardDigestForDevice(_state.snapshot.deviceState) ==
            owner.cardSnDigest;
  }

  bool get _manualBluetoothCancellationRequested {
    final lease = _activeTransferOperationLease;
    final operation = _operationMachine.state;
    return lease != null &&
        operation.generation == lease.generation &&
        operation.kind == RecordingCardOperationKind.bluetoothTransfer &&
        (operation.phase == RecordingCardOperationPhase.cancelling ||
            operation.phase == RecordingCardOperationPhase.cancelled);
  }

  Future<RecordingCardResult<RecordingCardDownloadedFile>>
  _downloadBluetoothFileWithRecovery(
    RecordingCardScannedFile file, {
    required RecordingCardOperationOrigin origin,
    String? sourceSignature,
    bool Function()? ownsTransfer,
  }) async {
    RecordingCardResult<RecordingCardDownloadedFile> interrupted() =>
        RecordingCardResult<RecordingCardDownloadedFile>.failure(
          _fallbackFailure(
            _manualBluetoothCancellationRequested
                ? 'RECORDING_CARD_TRANSFER_CANCELLED'
                : 'RECORDING_CARD_BLUETOOTH_RESUME_SUPERSEDED',
          ),
        );
    bool canContinue() => ownsTransfer?.call() ?? !_disposed;
    if (!canContinue()) return interrupted();
    final persistence = _syncLedgerPersistence;
    if (persistence == null) {
      if (!canContinue()) return interrupted();
      final downloaded = await _port.downloadFileToLocalCache(file);
      if (!canContinue()) return interrupted();
      return downloaded;
    }
    final cardSnDigest = _recordingCardDigestForDevice(
      _state.snapshot.deviceState,
    );
    if (cardSnDigest == null) {
      return RecordingCardResult<RecordingCardDownloadedFile>.failure(
        _fallbackFailure('RECORDING_CARD_LEDGER_IDENTITY_UNAVAILABLE'),
      );
    }

    try {
      final exactSignature = RecordingCardFileIdentity.sourceSignatureFor(
        cardSnDigest: cardSnDigest,
        deviceFileId: file.deviceFileId,
        deviceFilename: file.deviceFilename,
        sizeBytes: file.sizeBytes,
        recordedAt: file.recordedAt,
      );
      RecordingCardFileLedgerEntry? entry;
      final persistedSignature = sourceSignature?.trim();
      if (persistedSignature != null && persistedSignature.isNotEmpty) {
        entry = persistence.findFileLedgerEntry(
          cardSnDigest: cardSnDigest,
          sourceSignature: persistedSignature,
        );
      }
      entry ??= persistence.findFileLedgerEntry(
        cardSnDigest: cardSnDigest,
        sourceSignature: exactSignature,
      );
      if (entry == null) {
        final candidates = persistence
            .loadFileLedger(cardSnDigest)
            .where(
              (candidate) =>
                  candidate.deviceFileId == file.deviceFileId &&
                  candidate.deviceFilename == file.deviceFilename,
            )
            .toList(growable: false);
        if (candidates.length == 1) entry = candidates.single;
      }
      if (entry == null) {
        return RecordingCardResult<RecordingCardDownloadedFile>.failure(
          _fallbackFailure('RECORDING_CARD_LEDGER_IDENTITY_UNAVAILABLE'),
        );
      }
      final plannedNativeFileId =
          entry.plannedNativeFileId ?? _newBluetoothPlannedFileId();
      final planned = entry.planBluetoothDownload(
        at: _clock(),
        plannedNativeFileId: plannedNativeFileId,
        syncOrigin: origin == RecordingCardOperationOrigin.automatic
            ? RecordingCardSyncOrigin.automatic
            : RecordingCardSyncOrigin.user,
      );
      persistence.saveFileLedgerEntry(planned);
      await persistence.flushSyncPersistence();
      if (!canContinue()) return interrupted();

      final port = _port;
      if (port is! RecordingCardRecoverableBluetoothTransferPort) {
        if (!canContinue()) return interrupted();
        late final RecordingCardResult<RecordingCardDownloadedFile> downloaded;
        try {
          downloaded = await port.downloadFileToLocalCache(file);
        } on Object catch (error) {
          return RecordingCardResult<RecordingCardDownloadedFile>.failure(
            recordingCardFailure(
              'RECORDING_CARD_DOWNLOAD_FAILED',
              'Recording-card Bluetooth download threw unexpectedly',
              cause: error,
              isRetryable: true,
            ),
          );
        }
        if (!canContinue()) return interrupted();
        return downloaded;
      }
      final recoverablePort =
          port as RecordingCardRecoverableBluetoothTransferPort;
      final recovered = await recoverablePort.recoverBluetoothDownload(
        file,
        plannedNativeFileId: plannedNativeFileId,
      );
      if (!canContinue()) return interrupted();
      if (!recovered.ok || recovered.value == null) {
        return RecordingCardResult<RecordingCardDownloadedFile>.failure(
          recovered.error ??
              _fallbackFailure('RECORDING_CARD_BLUETOOTH_RECOVERY_FAILED'),
        );
      }
      final committed = recovered.value!.file;
      if (committed != null) {
        return _validatePlannedBluetoothDownload(
          RecordingCardResult<RecordingCardDownloadedFile>.success(committed),
          plannedNativeFileId,
        );
      }
      if (!canContinue()) return interrupted();
      late final RecordingCardResult<RecordingCardDownloadedFile> downloaded;
      try {
        downloaded = await recoverablePort.downloadRecoverableBluetoothFile(
          file,
          plannedNativeFileId: plannedNativeFileId,
        );
      } on Object catch (error) {
        return RecordingCardResult<RecordingCardDownloadedFile>.failure(
          recordingCardFailure(
            'RECORDING_CARD_DOWNLOAD_FAILED',
            'Recording-card Bluetooth download threw unexpectedly',
            cause: error,
            isRetryable: true,
          ),
        );
      }
      if (!canContinue()) return interrupted();
      return _validatePlannedBluetoothDownload(downloaded, plannedNativeFileId);
    } on Object catch (error) {
      return RecordingCardResult<RecordingCardDownloadedFile>.failure(
        recordingCardFailure(
          'RECORDING_CARD_BLUETOOTH_RECOVERY_FAILED',
          'Recording-card Bluetooth recovery plan could not be persisted',
          cause: error,
          isRetryable: true,
        ),
      );
    }
  }

  RecordingCardResult<RecordingCardDownloadedFile>
  _validatePlannedBluetoothDownload(
    RecordingCardResult<RecordingCardDownloadedFile> result,
    String plannedNativeFileId,
  ) {
    final downloaded = result.value;
    if (!result.ok || downloaded == null) return result;
    if (downloaded.localFileId == plannedNativeFileId) return result;
    return RecordingCardResult<RecordingCardDownloadedFile>.failure(
      recordingCardFailure(
        'RECORDING_CARD_BLUETOOTH_TARGET_MISMATCH',
        'Recording-card Bluetooth download returned an unexpected private target',
        isRetryable: false,
      ),
    );
  }

  Future<AppFailure?> _clearBluetoothResumeRequests(
    String? activeFileKey,
  ) async {
    final persistence = _syncLedgerPersistence;
    final digest = _recordingCardDigestForDevice(_state.snapshot.deviceState);
    if (persistence == null || digest == null) return null;
    try {
      final activeSignatures = _activeManualBluetoothLedgerSignatures;
      final file = activeFileKey == null
          ? null
          : _state.snapshot.files
                .where((candidate) => candidate.localFileKey == activeFileKey)
                .firstOrNull;
      final entries = persistence
          .loadFileLedger(digest)
          .where(
            (entry) =>
                (activeSignatures.contains(entry.sourceSignature) ||
                    (activeSignatures.isEmpty &&
                        file != null &&
                        entry.deviceFileId == file.deviceFileId &&
                        entry.deviceFilename == file.deviceFilename)) &&
                entry.resumeRequested,
          )
          .toList(growable: false);
      if (entries.isEmpty) return null;
      final at = _clock();
      persistence.saveFileLedgerEntries(
        entries.map((entry) => entry.clearBluetoothResumeRequest(at)),
      );
      await persistence.flushSyncPersistence();
      return null;
    } on Object catch (error) {
      return recordingCardFailure(
        'RECORDING_CARD_LEDGER_RECOVERY_FAILED',
        'Recording-card cancellation intent could not be persisted',
        cause: error,
        isRetryable: true,
      );
    }
  }

  Future<AppFailure?> _queueManualBluetoothBatch(
    _RecordingCardBluetoothBatchOwner owner,
    List<RecordingCardScannedFile> files,
    Map<String, _RecordingCardManualSyncTarget> targets,
  ) async {
    final persistence = _syncLedgerPersistence;
    if (persistence == null) {
      for (final file in files) {
        final signature = _recordingCardFileSignature(file);
        targets[signature] = _RecordingCardManualSyncTarget(
          file: file,
          sourceSignature: signature,
        );
      }
      return null;
    }
    final digest = owner.cardSnDigest;
    if (digest == null) {
      return _fallbackFailure('RECORDING_CARD_LEDGER_IDENTITY_UNAVAILABLE');
    }
    try {
      for (final file in files) {
        final entry = persistence.queueManualSyncForFile(
          cardSnDigest: digest,
          file: file,
          at: _clock(),
        );
        targets[_recordingCardFileSignature(
          file,
        )] = _RecordingCardManualSyncTarget(
          file: file,
          sourceSignature: entry.sourceSignature,
        );
      }
    } on Object catch (error) {
      return recordingCardFailure(
        'RECORDING_CARD_LEDGER_INITIALIZATION_FAILED',
        'Recording-card Bluetooth batch ledger could not be initialized',
        cause: error,
        isRetryable: true,
      );
    }
    return _flushManualBluetoothPersistence(
      code: 'RECORDING_CARD_LEDGER_INITIALIZATION_FAILED',
      message: 'Recording-card Bluetooth batch ledger was not durable',
    );
  }

  Future<AppFailure?> _beginManualBluetoothSync(
    _RecordingCardBluetoothBatchOwner owner,
    _RecordingCardManualSyncTarget? target,
  ) async {
    final persistence = _syncLedgerPersistence;
    if (persistence == null) return null;
    final digest = owner.cardSnDigest;
    if (digest == null || target == null) {
      return _fallbackFailure('RECORDING_CARD_LEDGER_IDENTITY_UNAVAILABLE');
    }
    try {
      persistence.beginManualSync(
        cardSnDigest: digest,
        sourceSignature: target.sourceSignature,
        at: _clock(),
      );
    } on Object catch (error) {
      return recordingCardFailure(
        'RECORDING_CARD_LEDGER_BEGIN_FAILED',
        'Recording-card Bluetooth ledger could not begin the file',
        cause: error,
        isRetryable: true,
      );
    }
    return _flushManualBluetoothPersistence(
      code: 'RECORDING_CARD_LEDGER_BEGIN_FAILED',
      message: 'Recording-card Bluetooth file start was not durable',
    );
  }

  Future<AppFailure?> _completeManualBluetoothSync(
    _RecordingCardBluetoothBatchOwner owner,
    _RecordingCardManualSyncTarget? target,
    RecordingCardDownloadedFile downloaded,
  ) async {
    final persistence = _syncLedgerPersistence;
    if (persistence == null) return null;
    final digest = owner.cardSnDigest;
    final localRecordingId = downloaded.localFileId?.trim();
    if (digest == null ||
        target == null ||
        localRecordingId == null ||
        localRecordingId.isEmpty) {
      return _fallbackFailure(
        'RECORDING_CARD_LOCAL_LIBRARY_REGISTRATION_FAILED',
      );
    }
    try {
      persistence.completeManualSync(
        cardSnDigest: digest,
        sourceSignature: target.sourceSignature,
        localRecordingId: localRecordingId,
        contentHash: downloaded.contentHash,
        at: _clock(),
      );
    } on Object catch (error) {
      return recordingCardFailure(
        'RECORDING_CARD_LEDGER_COMPLETION_FAILED',
        'Recording-card Bluetooth ledger could not complete the file',
        cause: error,
        isRetryable: true,
      );
    }
    return _flushManualBluetoothPersistence(
      code: 'RECORDING_CARD_LEDGER_COMPLETION_FAILED',
      message: 'Recording-card Bluetooth completion was not durable',
    );
  }

  Future<AppFailure?> _failManualBluetoothSync(
    _RecordingCardBluetoothBatchOwner owner,
    _RecordingCardManualSyncTarget? target,
    String failureCode,
  ) async {
    final persistence = _syncLedgerPersistence;
    if (persistence == null) return null;
    final digest = owner.cardSnDigest;
    if (digest == null || target == null) {
      return _fallbackFailure('RECORDING_CARD_LEDGER_IDENTITY_UNAVAILABLE');
    }
    try {
      persistence.failManualSync(
        cardSnDigest: digest,
        sourceSignature: target.sourceSignature,
        errorCode: failureCode,
        retryability: _manualWifiSyncRetryability(failureCode),
        at: _clock(),
      );
    } on Object catch (error) {
      return recordingCardFailure(
        'RECORDING_CARD_LEDGER_FAILURE_PERSIST_FAILED',
        'Recording-card Bluetooth failure could not be persisted',
        cause: error,
        isRetryable: true,
      );
    }
    return _flushManualBluetoothPersistence(
      code: 'RECORDING_CARD_LEDGER_FAILURE_PERSIST_FAILED',
      message: 'Recording-card Bluetooth failure was not durable',
    );
  }

  Future<AppFailure?> _deferManualBluetoothBatch(
    _RecordingCardBluetoothBatchOwner owner,
    Iterable<RecordingCardScannedFile> files, {
    bool resumeRequested = true,
  }) async {
    final persistence = _syncLedgerPersistence;
    if (persistence == null) return null;
    final digest = owner.cardSnDigest;
    if (digest == null) {
      return _fallbackFailure('RECORDING_CARD_LEDGER_IDENTITY_UNAVAILABLE');
    }
    AppFailure? failure;
    for (final file in files) {
      try {
        final queued = persistence.queueManualSyncForFile(
          cardSnDigest: digest,
          file: file,
          at: _clock(),
        );
        if (!resumeRequested) {
          persistence.saveFileLedgerEntry(
            queued.clearBluetoothResumeRequest(_clock()),
          );
        }
      } on Object catch (error) {
        failure ??= recordingCardFailure(
          'RECORDING_CARD_LEDGER_RECOVERY_FAILED',
          'Recording-card Bluetooth interruption could not be requeued',
          cause: error,
          isRetryable: true,
        );
      }
    }
    return failure ??
        await _flushManualBluetoothPersistence(
          code: 'RECORDING_CARD_LEDGER_RECOVERY_FAILED',
          message: 'Recording-card Bluetooth interruption was not durable',
        );
  }

  Future<AppFailure?> _flushManualBluetoothPersistence({
    required String code,
    required String message,
  }) async {
    final persistence = _syncLedgerPersistence;
    if (persistence == null) return null;
    try {
      await persistence.flushSyncPersistence();
      return null;
    } on Object catch (error) {
      return recordingCardFailure(
        code,
        message,
        cause: error,
        isRetryable: true,
      );
    }
  }

  AppFailure _singleFileTransferPreconditionFailure() {
    final device = _state.snapshot.deviceState;
    if (!device.isOperationallyConnected ||
        _activeConnectionDeviceIdentity(device) == null ||
        _activeReconnectFingerprint(device) == null) {
      return recordingCardFailure(
        'RECORDING_CARD_DEVICE_IDENTITY_UNAVAILABLE',
        'Recording-card stable identity is unavailable',
        isRetryable: true,
      );
    }
    if (!hasLoadedFilesForCurrentConnection) {
      return recordingCardFailure(
        'RECORDING_CARD_FILE_CATALOG_NOT_READY',
        'Recording-card file directory is not verified',
        isRetryable: true,
      );
    }
    return recordingCardFailure(
      'RECORDING_CARD_FILE_SELECTION_STALE',
      'Selected recording-card file no longer matches the verified directory',
      isRetryable: true,
    );
  }

  bool _ownsTransferOwner(_RecordingCardTransferOwner owner) {
    return _ownsFileCatalogWork(
          owner.connectionRevision,
          owner.deviceIdentity,
        ) &&
        hasLoadedFilesForCurrentConnection &&
        _state.fileCatalog.owns(
          connectionRevision: owner.connectionRevision,
          deviceIdentity: owner.deviceIdentity,
        ) &&
        _state.snapshot.files.any(
          (file) => _recordingCardFileSignature(file) == owner.fileSignature,
        );
  }

  Future<bool> _prepareRecordingCommand() async {
    if (hasActiveTransfer || _connectionReconcileInFlight != null) return false;
    final directoryRead = _scanFilesInFlight;
    if (directoryRead != null) await directoryRead;
    final deviceInfoRead = _deviceInfoRefreshInFlight;
    if (deviceInfoRead != null) await deviceInfoRead;
    return !hasActiveTransfer &&
        !_operationMachine.state.isActive &&
        (_state.status == RecordingCardControllerStatus.idle ||
            _state.status == RecordingCardControllerStatus.error);
  }

  Future<void> _runRecordingCommand(
    Future<RecordingCardResult<RecordingCardRecordingInfo>> Function()
    command, {
    String? expectedDeviceFingerprint,
    bool Function()? canExecute,
  }) async {
    final requestedConnectionRevision = _connectionRevision;
    if (_disposed) return;
    if (!_state.snapshot.deviceState.isOperationallyConnected) {
      _fail(
        recordingCardFailure(
          'RECORDING_CARD_NOT_CONNECTED',
          'Recording-card control requires an active device connection',
          isRetryable: true,
        ),
      );
      return;
    }
    if (!await _prepareRecordingCommand()) {
      _blockDeviceOperation(
        kind: RecordingCardOperationKind.recordingControl,
        origin: RecordingCardOperationOrigin.user,
      );
      _reportOperationBlocked();
      return;
    }
    if (_disposed) return;
    if (requestedConnectionRevision != _connectionRevision ||
        !_state.snapshot.deviceState.isOperationallyConnected ||
        (expectedDeviceFingerprint != null &&
            expectedDeviceFingerprint !=
                _state.snapshot.deviceState.safeDeviceFingerprint?.trim()) ||
        (canExecute != null && !canExecute())) {
      _fail(
        recordingCardFailure(
          'RECORDING_CARD_STALE_WIDGET_ACTION',
          'Recording-card target or widget authorization changed',
          isRetryable: true,
        ),
      );
      return;
    }
    if (!_startControllerOperation(
      status: RecordingCardControllerStatus.commanding,
      kind: RecordingCardOperationKind.recordingControl,
    )) {
      return;
    }
    final operation = ++_deviceDiscoveryOperation;
    final connectionRevision = _connectionRevision;
    final revisionBefore = _recordingRevision;
    final result = await command();
    if (!_isCurrentDeviceDiscoveryOperation(operation) ||
        connectionRevision != _connectionRevision) {
      if (_isCurrentDeviceDiscoveryOperation(operation)) {
        await _adoptCurrentNativeDeviceState(operation);
      }
      return;
    }
    if (_isStaleDeviceOperation(result)) {
      await _adoptCurrentNativeDeviceState(operation);
      return;
    }
    _handleRecordingResult(result, revisionBefore: revisionBefore);
  }

  bool _beginTransfer({
    required RecordingCardOperationKind kind,
    RecordingCardOperationOrigin origin = RecordingCardOperationOrigin.user,
  }) {
    if (_state.snapshot.recordingInfo.state !=
            RecordingCardRecordingState.idle ||
        _scanFilesInFlight != null ||
        _deviceInfoRefreshInFlight != null ||
        (_state.status != RecordingCardControllerStatus.idle &&
            _state.status != RecordingCardControllerStatus.error) ||
        _hasTransferConflict) {
      _blockDeviceOperation(kind: kind, origin: origin);
      return false;
    }
    final admission = _beginDeviceOperation(kind: kind, origin: origin);
    if (!admission.admitted) return false;
    _claimTransferLatch(operationLease: admission.lease);
    _state = _state.copyWith(lastErrorCode: null);
    notifyListeners();
    return true;
  }

  bool get _hasTransferConflict {
    final batch = _wifiBatchCoordinator.snapshot;
    return _transferInFlight ||
        _wifiBatchDismissInFlight != null ||
        _state.hasActiveTransfer ||
        (batch != null && (!batch.isTerminal || batch.isBusy));
  }

  int _claimTransferLatch({RecordingCardOperationLease? operationLease}) {
    var lease = operationLease;
    if (lease == null && !_transferInFlight) {
      final admission = _beginDeviceOperation(
        kind: RecordingCardOperationKind.wifiTransfer,
        origin: RecordingCardOperationOrigin.user,
      );
      lease = admission.lease;
    }
    if (lease != null) _activeTransferOperationLease = lease;
    _connectionReconcileGeneration += 1;
    _transferInFlight = true;
    _transferLatchGeneration += 1;
    return _transferLatchGeneration;
  }

  int? _claimWifiTransitionLatch() {
    if (_transferInFlight) return _transferLatchGeneration;
    final admission = _beginDeviceOperation(
      kind: RecordingCardOperationKind.wifiTransfer,
      origin: RecordingCardOperationOrigin.user,
    );
    final lease = admission.lease;
    if (lease == null) {
      _publishOperationState();
      return null;
    }
    final generation = _claimTransferLatch(operationLease: lease);
    _state = _state.copyWith(operation: admission.state);
    notifyListeners();
    return generation;
  }

  void _releaseTransferLatch(int generation) {
    if (generation != _transferLatchGeneration) return;
    _transferInFlight = false;
    final operationLease = _activeTransferOperationLease;
    _activeTransferOperationLease = null;
    final staleTransferStatus = switch (_state.status) {
      RecordingCardControllerStatus.syncing ||
      RecordingCardControllerStatus.downloading ||
      RecordingCardControllerStatus.deleting ||
      RecordingCardControllerStatus.cancellingTransfer => true,
      _ => false,
    };
    if (staleTransferStatus) {
      _state = _state.copyWith(
        status: RecordingCardControllerStatus.idle,
        snapshot: _state.snapshot.copyWith(
          clearDownloadingFileKey: true,
          clearTransferProgress: true,
        ),
        clearActiveFileKey: true,
      );
    }
    final settlementCode =
        operationLease != null &&
            operationLease.connectionRevision != _connectionRevision
        ? recordingCardOperationSessionChangedCode
        : _state.lastErrorCode;
    _settleDeviceOperation(operationLease, failureCode: settlementCode);
    if (_operationMachine.state.generation == operationLease?.generation &&
        _operationMachine.state.phase ==
            RecordingCardOperationPhase.cancelled) {
      _state = _state.copyWith(
        status: RecordingCardControllerStatus.idle,
        snapshot: _state.snapshot.copyWith(
          clearDownloadingFileKey: true,
          clearTransferProgress: true,
        ),
        clearActiveFileKey: true,
        lastErrorCode: null,
      );
    }
    if (!_disposed) notifyListeners();
    _resumeDeferredConnectionFileRefresh();
    _scheduleDeferredFileRefreshes();
  }

  void _scheduleDeferredFileRefreshes() {
    final hasPendingRefresh =
        _recordingCompletionRefreshRequested ||
        _appResumeFileRefreshRequested ||
        _deferredConnectionFileRefreshRevision >= 0;
    if (_disposed || !hasPendingRefresh || _deferredFileRefreshTimer != null) {
      return;
    }
    _deferredFileRefreshTimer = Timer(Duration.zero, () {
      _deferredFileRefreshTimer = null;
      if (_disposed) return;
      _tryStartRecordingCompletionRefresh();
      _tryStartAppResumeFileRefresh();
      _resumeDeferredConnectionFileRefresh();
    });
  }

  void _resumeDeferredConnectionFileRefresh() {
    final revision = _deferredConnectionFileRefreshRevision;
    if (revision < 0) return;
    if (_disposed ||
        revision != _connectionRevision ||
        !_state.snapshot.deviceState.isOperationallyConnected) {
      _deferredConnectionFileRefreshRevision = -1;
      return;
    }
    if (hasLoadedFilesForCurrentConnection) {
      _deferredConnectionFileRefreshRevision = -1;
      return;
    }
    if (_state.snapshot.recordingInfo.state !=
            RecordingCardRecordingState.idle ||
        _hasRunningTransfer ||
        _scanFilesInFlight != null ||
        _deviceInfoRefreshInFlight != null ||
        (_state.status != RecordingCardControllerStatus.idle &&
            _state.status != RecordingCardControllerStatus.error)) {
      return;
    }
    _deferredConnectionFileRefreshRevision = -1;
    if (_autoScanAttemptedConnectionRevision == revision) {
      _autoScanAttemptedConnectionRevision = -1;
    }
    unawaited(refreshFiles(reason: RecordingCardFileRefreshReason.connection));
  }

  void _retainConnectionRefreshAfterScanOwnershipLoss(
    int connectionRevision,
    String deviceIdentity,
  ) {
    if (_ownsFileCatalogWork(connectionRevision, deviceIdentity)) {
      _deferredConnectionFileRefreshRevision = connectionRevision;
    }
  }

  void _reportOperationBlocked() {
    _publishOperationState();
    notifyListeners();
  }

  Future<AppFailure?> _refreshVerifiedDownloadCache() async {
    final generation = ++_verifiedDownloadRefreshGeneration;
    try {
      final links = await _localRecordingRepository
          .verifiedRecordingCardDownloads()
          .timeout(_localVerificationTimeout);
      if (_disposed) return null;
      if (generation != _verifiedDownloadRefreshGeneration) {
        return recordingCardFailure(
          'RECORDING_CARD_LOCAL_VERIFICATION_SUPERSEDED',
          'Recording-card local verification was superseded',
          isRetryable: true,
        );
      }
      _verifiedDownloadsByIdentity = <String, VerifiedRecordingCardDownload>{
        for (final link in links)
          for (final deviceId in <String>{
            link.deviceFingerprint,
            ...link.deviceIds,
          })
            _verifiedDownloadIdentity(deviceId, link.deviceFileId): link,
      };
      return null;
    } catch (error) {
      if (_disposed) {
        return null;
      }
      if (generation != _verifiedDownloadRefreshGeneration) {
        return recordingCardFailure(
          'RECORDING_CARD_LOCAL_VERIFICATION_SUPERSEDED',
          'Recording-card local verification was superseded',
          isRetryable: true,
        );
      }
      return recordingCardFailure(
        'RECORDING_CARD_LOCAL_VERIFICATION_FAILED',
        'Recording-card local file integrity verification failed',
        cause: error,
        isRetryable: true,
      );
    }
  }

  List<RecordingCardScannedFile> _restoreVerifiedDownloads(
    List<RecordingCardScannedFile> files,
    RecordingCardDeviceState device,
  ) {
    final untrustedLocalProjection = files
        .map(_withoutNativeSyncedProjection)
        .toList(growable: false);
    if (untrustedLocalProjection.isEmpty ||
        _verifiedDownloadsByIdentity.isEmpty) {
      return untrustedLocalProjection;
    }
    final latchedIdentity = device.isOperationallyConnected
        ? _connectionDeviceIdentity
        : null;
    final latchedFingerprint = device.isOperationallyConnected
        ? _recordingCardReconnectFingerprintValue(_connectionFingerprint)
        : null;
    final cardSnDigest = device.isOperationallyConnected
        ? _recordingCardDigestForDevice(device)
        : null;
    final currentIdentities = <String>{
      ..._recordingCardDeviceIdentityCandidates(device),
      if (latchedIdentity != null) latchedIdentity,
      if (latchedFingerprint != null) latchedFingerprint,
      if (cardSnDigest != null) cardSnDigest,
    }.toList(growable: false);
    return untrustedLocalProjection
        .map((file) {
          if (file.syncState != RecordingCardFileSyncState.deviceOnly &&
              file.syncState != RecordingCardFileSyncState.localMissing) {
            return file;
          }
          final scannedHash = safeContentHash(file.contentHash);
          VerifiedRecordingCardDownload? exactLink;
          for (final identity in currentIdentities) {
            exactLink =
                _verifiedDownloadsByIdentity[_verifiedDownloadIdentity(
                  identity,
                  file.deviceFileId,
                )];
            if (exactLink != null) break;
          }
          final hashLink = scannedHash == null
              ? null
              : _verifiedDownloadsByIdentity.values
                    .where(
                      (candidate) =>
                          safeContentHash(candidate.contentHash) ==
                              scannedHash &&
                          (file.sizeBytes == null ||
                              file.sizeConfidence !=
                                  RecordingCardFileSizeConfidence.trusted ||
                              file.sizeBytes == candidate.actualSizeBytes),
                    )
                    .firstOrNull;
          final link = hashLink ?? exactLink;
          if (link == null ||
              !_verifiedDownloadMatches(
                file,
                link,
                exactIdentity: hashLink == null && exactLink != null,
              )) {
            return file;
          }
          return file.copyWith(
            syncState: RecordingCardFileSyncState.synced,
            durationSeconds: link.durationSeconds,
            localFileId: link.localRecordingId,
            appPrivateUri: link.appPrivateUri,
          );
        })
        .toList(growable: false);
  }

  RecordingCardScannedFile _withoutNativeSyncedProjection(
    RecordingCardScannedFile file,
  ) {
    if (file.syncState != RecordingCardFileSyncState.synced) return file;
    return RecordingCardScannedFile(
      deviceFileId: file.deviceFileId,
      localFileKey: file.localFileKey,
      deviceFilename: file.deviceFilename,
      sizeBytes: file.sizeBytes,
      durationSeconds: file.durationSeconds,
      recordedAt: file.recordedAt,
      contentHash: file.contentHash,
      sizeConfidence: file.sizeConfidence,
      format: file.format,
      mimeType: file.mimeType,
    );
  }

  void _fail(
    AppFailure failure, {
    RecordingCardOperationLease? operationLease,
    bool preserveLastDownloadedFile = false,
  }) {
    if (operationLease == null) {
      _settleControllerOperation(failureCode: failure.code);
    } else {
      if (identical(_activeControllerOperationLease, operationLease)) {
        _activeControllerOperationLease = null;
      }
      _settleDeviceOperation(operationLease, failureCode: failure.code);
    }
    _state = _state.copyWith(
      status: RecordingCardControllerStatus.error,
      lastErrorCode: failure.code,
      clearActiveFileKey: true,
      clearLastDownloadedFile: !preserveLastDownloadedFile,
    );
    notifyListeners();
    _scheduleDeferredFileRefreshes();
  }

  void _failFileCatalog(AppFailure failure) {
    final device = _state.snapshot.deviceState;
    _state = _state.copyWith(
      status: RecordingCardControllerStatus.error,
      fileCatalog: RecordingCardFileCatalogState(
        phase: RecordingCardFileCatalogPhase.failed,
        connectionRevision: _connectionRevision,
        deviceIdentity: device.isOperationallyConnected
            ? _activeConnectionDeviceIdentity(device)
            : null,
        errorCode: failure.code,
      ),
      lastErrorCode: failure.code,
      clearActiveFileKey: true,
      clearLastDownloadedFile: true,
    );
    notifyListeners();
  }

  bool _ownsFileCatalogWork(
    int revision,
    String deviceIdentity, {
    int? deviceOperation,
  }) {
    final device = _state.snapshot.deviceState;
    return !_disposed &&
        (deviceOperation == null ||
            deviceOperation == _deviceDiscoveryOperation) &&
        device.isOperationallyConnected &&
        revision == _connectionRevision &&
        _activeConnectionDeviceIdentity(device) == deviceIdentity;
  }

  bool _ownsReadyFileCatalog({
    required int revision,
    required String deviceIdentity,
    required Set<String> directorySignatures,
  }) {
    return _ownsReadyFileCatalogOwner(revision, deviceIdentity) &&
        setEquals(
          _state.snapshot.files.map(_recordingCardFileSignature).toSet(),
          directorySignatures,
        );
  }

  bool _ownsReadyFileCatalogOwner(int revision, String deviceIdentity) {
    return _ownsFileCatalogWork(revision, deviceIdentity) &&
        hasLoadedFilesForCurrentConnection &&
        _state.fileCatalog.owns(
          connectionRevision: revision,
          deviceIdentity: deviceIdentity,
        );
  }

  bool _ownsWifiBleRecovery(
    int generation,
    RecordingCardWifiBatchSnapshot batch, {
    bool requireConnected = false,
  }) {
    final controllerDevice = _state.snapshot.deviceState;
    final nativeDevice = _port.runtimeSnapshot.deviceState;
    final recoveryLease = _activeTransferOperationLease;
    final baseOwnership =
        !_disposed &&
        generation == _wifiBleRecoveryGeneration &&
        identical(_wifiBatchCoordinator.snapshot, batch) &&
        _transferInFlight &&
        recoveryLease?.kind == RecordingCardOperationKind.bluetoothTransfer &&
        recoveryLease?.connectionRevision == _connectionRevision &&
        _operationMachine.owns(recoveryLease) &&
        (!controllerDevice.isOperationallyConnected ||
            _matchesWifiBatchReconnectTarget(controllerDevice, batch)) &&
        (!nativeDevice.isOperationallyConnected ||
            _matchesWifiBatchReconnectTarget(nativeDevice, batch));
    return baseOwnership &&
        (!requireConnected ||
            (controllerDevice.isOperationallyConnected &&
                _matchesWifiBatchReconnectTarget(controllerDevice, batch)));
  }

  bool _rebaseWifiBleRecoveryLease(
    int generation,
    RecordingCardWifiBatchSnapshot batch, {
    required RecordingCardOperationOrigin origin,
  }) {
    final currentLease = _activeTransferOperationLease;
    final controllerDevice = _state.snapshot.deviceState;
    final nativeDevice = _port.runtimeSnapshot.deviceState;
    if (_disposed ||
        generation != _wifiBleRecoveryGeneration ||
        !identical(_wifiBatchCoordinator.snapshot, batch) ||
        !_transferInFlight ||
        currentLease == null ||
        currentLease.kind != RecordingCardOperationKind.bluetoothTransfer ||
        !_operationMachine.owns(currentLease) ||
        (controllerDevice.isOperationallyConnected &&
            !_matchesWifiBatchReconnectTarget(controllerDevice, batch)) ||
        (nativeDevice.isOperationallyConnected &&
            !_matchesWifiBatchReconnectTarget(nativeDevice, batch))) {
      return false;
    }
    if (currentLease.connectionRevision == _connectionRevision) return true;
    final admission = _operationMachine.supersede(
      kind: RecordingCardOperationKind.bluetoothTransfer,
      origin: origin,
      connectionRevision: _connectionRevision,
    );
    final rebasedLease = admission.lease;
    if (rebasedLease == null) return false;
    _activeTransferOperationLease = rebasedLease;
    _state = _state.copyWith(operation: admission.state);
    notifyListeners();
    return _ownsWifiBleRecovery(generation, batch);
  }

  AppFailure _fallbackFailure(String code) {
    return recordingCardFailure(
      code,
      'Recording-card controller operation failed',
      isRetryable: true,
    );
  }

  static bool _isAndroidRuntime() {
    return defaultTargetPlatform == TargetPlatform.android;
  }
}

String _wifiBatchId(List<RecordingCardScannedFile> files, DateTime createdAt) {
  final digest = sha256
      .convert(
        utf8.encode(
          '${createdAt.microsecondsSinceEpoch}:${files.map((f) => f.deviceFileId).join('|')}',
        ),
      )
      .toString()
      .substring(0, 12);
  return 'wifi-${createdAt.microsecondsSinceEpoch}-$digest';
}

String _newBluetoothPlannedFileId() {
  final random = Random.secure();
  final entropy = List<String>.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  return 'card-$entropy';
}

String _wifiBatchTransferId(String batchId, int order) {
  final digest = sha256.convert(utf8.encode('$batchId:$order')).toString();
  return 'wifi-$digest';
}

String? _safeBatchRecordText(Object? value) {
  if (value is! String) return null;
  final text = value.trim();
  if (text.isEmpty || text.length > 256 || text.endsWith('.part')) return null;
  if (text.contains('/Users/') || text.startsWith('file://')) return null;
  return text;
}

String? _safeBatchDigest(Object? value) {
  final digest = _safeBatchRecordText(value)?.toLowerCase();
  return digest != null && RegExp(r'^[a-f0-9]{64}$').hasMatch(digest)
      ? digest
      : null;
}

int _batchRecordInt(Object? value) {
  if (value is int && value >= 0) return value;
  if (value is num && value >= 0) return value.floor();
  final parsed = int.tryParse('$value');
  return parsed == null || parsed < 0 ? 0 : parsed;
}

int? _nullableBatchRecordInt(Object? value) {
  if (value == null) return null;
  return _batchRecordInt(value);
}

DateTime? _batchRecordDate(Object? value) {
  final text = _safeBatchRecordText(value);
  return text == null ? null : DateTime.tryParse(text);
}

DateTime _latestBatchRecordAt(List<Map<String, Object?>> rows) {
  var latest = DateTime.fromMillisecondsSinceEpoch(0);
  for (final row in rows) {
    final value = _batchRecordDate(row['updated_at']);
    if (value != null && value.isAfter(latest)) latest = value;
  }
  return latest;
}

RecordingCardWifiBatchState? _wifiBatchState(Object? value) {
  final name = _safeBatchRecordText(value);
  if (name == null) return null;
  for (final candidate in RecordingCardWifiBatchState.values) {
    if (candidate.name == name) return candidate;
  }
  return null;
}

RecordingCardWifiBatchItemState? _wifiBatchItemState(Object? value) {
  final name = _safeBatchRecordText(value);
  if (name == null) return null;
  for (final candidate in RecordingCardWifiBatchItemState.values) {
    if (candidate.name == name) return candidate;
  }
  return null;
}

RecordingCardFileFormat _recordingCardFileFormat(Object? value) {
  final name = _safeBatchRecordText(value);
  for (final candidate in RecordingCardFileFormat.values) {
    if (candidate.name == name) return candidate;
  }
  return RecordingCardFileFormat.unknown;
}

typedef RecordingCardBindingTokenProvider = Future<String> Function();
Future<String> _unavailableBindingToken() =>
    Future<String>.error(StateError('binding identity unavailable'));

Future<String> recordingCardBindingTokenFor(Future<String> identity) async =>
    sha256
        .convert(utf8.encode(await identity))
        .bytes
        .take(16)
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join();

bool isRecordingCardBindingToken(String value) =>
    RegExp(r'^[a-f0-9]{32}$').hasMatch(value);

typedef _StagedWifiDownloadMetadata = ({
  String nativeFileId,
  String format,
  int sizeBytes,
  String contentHash,
});

final _stagedWifiNativeFileName = RegExp(
  r'^(card-[a-f0-9]{32})\.(mp3|opus|m4a|wav)$',
);
final _stagedWifiId = RegExp(r'^card-[a-f0-9]{32}$');

RecordingCardDownloadedFile? _validatedStagedWifiDownload(
  RecordingCardDownloadedFile downloaded,
  RecordingCardScannedFile sourceFile,
) {
  if (downloaded.localFileKey != sourceFile.localFileKey ||
      downloaded.format == RecordingCardFileFormat.unknown ||
      _downloadedFileIntegrityFailure(downloaded, sourceFile) != null) {
    return null;
  }
  final reference = PrivateRecordingPathResolver().parse(
    downloaded.appPrivateUri,
  );
  if (reference == null ||
      reference.kind != PrivateRecordingReferenceKind.recordingCard) {
    return null;
  }
  final nameMatch = _stagedWifiNativeFileName.firstMatch(reference.fileName);
  final nativeFileId = nameMatch?.group(1);
  final extension = nameMatch?.group(2);
  final sizeBytes = downloaded.sizeBytes;
  final contentHash = safeContentHash(downloaded.contentHash);
  if (nativeFileId == null ||
      extension != downloaded.format.name ||
      sizeBytes == null ||
      sizeBytes <= 0 ||
      contentHash == null) {
    return null;
  }
  final canonicalUri = PrivateRecordingPathResolver().recordingCardUri(
    '$nativeFileId.$extension',
  );
  if (canonicalUri != downloaded.appPrivateUri) return null;
  return RecordingCardDownloadedFile(
    localFileKey: downloaded.localFileKey,
    localFileId: downloaded.localFileId,
    appPrivateUri: canonicalUri,
    displayName: downloaded.displayName,
    durationSeconds: downloaded.durationSeconds,
    sizeBytes: sizeBytes,
    contentHash: contentHash,
    format: downloaded.format,
    mimeType: downloaded.mimeType ?? _mimeTypeFor(downloaded.format),
  );
}

RecordingCardScannedFile _recordingCardFileWithLinkedDownload(
  RecordingCardScannedFile source,
  RecordingCardDownloadedFile linked,
) {
  final linkedSize = linked.sizeBytes;
  final hasLinkedSize = linkedSize != null && linkedSize > 0;
  return RecordingCardScannedFile(
    deviceFileId: source.deviceFileId,
    localFileKey: source.localFileKey,
    deviceFilename: source.deviceFilename,
    sizeBytes: hasLinkedSize ? linkedSize : source.sizeBytes,
    durationSeconds: linked.durationSeconds ?? source.durationSeconds,
    recordedAt: source.recordedAt,
    contentHash: safeContentHash(linked.contentHash) ?? source.contentHash,
    sizeConfidence: hasLinkedSize
        ? RecordingCardFileSizeConfidence.trusted
        : source.sizeConfidence,
    format: linked.format == RecordingCardFileFormat.unknown
        ? source.format
        : linked.format,
    mimeType: linked.mimeType ?? source.mimeType,
    syncState: RecordingCardFileSyncState.synced,
    localFileId: linked.localFileId,
    appPrivateUri: linked.appPrivateUri,
  );
}

_StagedWifiDownloadMetadata? _stagedWifiDownloadMetadata(
  RecordingCardDownloadedFile? downloaded,
  RecordingCardScannedFile sourceFile,
) {
  if (downloaded == null) return null;
  final validated = _validatedStagedWifiDownload(downloaded, sourceFile);
  if (validated == null) return null;
  final reference = PrivateRecordingPathResolver().parse(
    validated.appPrivateUri,
  );
  final nameMatch = reference == null
      ? null
      : _stagedWifiNativeFileName.firstMatch(reference.fileName);
  final nativeFileId = nameMatch?.group(1);
  final contentHash = safeContentHash(validated.contentHash);
  final sizeBytes = validated.sizeBytes;
  if (nativeFileId == null || contentHash == null || sizeBytes == null) {
    return null;
  }
  return (
    nativeFileId: nativeFileId,
    format: validated.format.name,
    sizeBytes: sizeBytes,
    contentHash: contentHash,
  );
}

RecordingCardDownloadedFile? _stagedWifiDownloadFromRecord(
  Map<String, Object?> row,
  RecordingCardScannedFile sourceFile,
) {
  final nativeFileId = _safeBatchRecordText(row['staged_native_file_id']);
  final format = _recordingCardFileFormat(row['staged_file_format']);
  final sizeBytes = _nullableBatchRecordInt(row['staged_size_bytes']);
  final contentHash = safeContentHash(
    _safeBatchRecordText(row['staged_content_hash']),
  );
  if (nativeFileId == null ||
      !_stagedWifiId.hasMatch(nativeFileId) ||
      format == RecordingCardFileFormat.unknown ||
      sizeBytes == null ||
      sizeBytes <= 0 ||
      contentHash == null) {
    return null;
  }
  final extension = format.name;
  final downloaded = RecordingCardDownloadedFile(
    localFileKey: sourceFile.localFileKey,
    localFileId: nativeFileId,
    appPrivateUri: PrivateRecordingPathResolver().recordingCardUri(
      '$nativeFileId.$extension',
    ),
    displayName: _downloadDisplayName(sourceFile.deviceFilename, format),
    durationSeconds: sourceFile.durationSeconds,
    sizeBytes: sizeBytes,
    contentHash: contentHash,
    format: format,
    mimeType: sourceFile.mimeType ?? _mimeTypeFor(format),
  );
  return _validatedStagedWifiDownload(downloaded, sourceFile);
}

PrivateAudioFile? _privateAudioFileFor(
  RecordingCardDownloadedFile downloaded,
  RecordingCardScannedFile sourceFile,
) {
  final reference = PrivateRecordingPathResolver().parse(
    downloaded.appPrivateUri,
  );
  if (reference == null ||
      reference.kind != PrivateRecordingReferenceKind.recordingCard) {
    return null;
  }
  final sizeBytes = downloaded.sizeBytes ?? sourceFile.sizeBytes;
  if (sizeBytes == null || sizeBytes <= 0) return null;
  final format = downloaded.format == RecordingCardFileFormat.unknown
      ? sourceFile.format
      : downloaded.format;
  final displayName = _downloadDisplayName(
    downloaded.displayName ?? sourceFile.deviceFilename,
    format,
  );
  if (displayName == null) return null;
  return PrivateAudioFile(
    fileId: reference.fileId,
    appPrivateUri: downloaded.appPrivateUri,
    displayName: displayName,
    mimeType:
        downloaded.mimeType ?? sourceFile.mimeType ?? _mimeTypeFor(format),
    sizeBytes: sizeBytes,
    durationSeconds: downloaded.durationSeconds ?? sourceFile.durationSeconds,
    contentHash:
        safeContentHash(downloaded.contentHash) ??
        safeContentHash(sourceFile.contentHash),
    recordedAt: sourceFile.recordedAt,
  );
}

String? _downloadDisplayName(String candidate, RecordingCardFileFormat format) {
  final trimmed = candidate.trim();
  if (trimmed.isEmpty || trimmed.length > 120 || trimmed.endsWith('.part')) {
    return null;
  }
  if (trimmed.contains('.')) return trimmed;
  final extension = switch (format) {
    RecordingCardFileFormat.mp3 => '.mp3',
    RecordingCardFileFormat.opus => '.opus',
    RecordingCardFileFormat.m4a => '.m4a',
    RecordingCardFileFormat.wav => '.wav',
    RecordingCardFileFormat.unknown => null,
  };
  return extension == null ? trimmed : '$trimmed$extension';
}

String _mimeTypeFor(RecordingCardFileFormat format) {
  return switch (format) {
    RecordingCardFileFormat.mp3 => 'audio/mpeg',
    RecordingCardFileFormat.opus => 'audio/ogg',
    RecordingCardFileFormat.m4a => 'audio/mp4',
    RecordingCardFileFormat.wav => 'audio/wav',
    RecordingCardFileFormat.unknown => 'application/octet-stream',
  };
}

bool _verifiedDownloadMatches(
  RecordingCardScannedFile file,
  VerifiedRecordingCardDownload link, {
  required bool exactIdentity,
}) {
  if (exactIdentity && file.deviceFilename != link.deviceFilename) return false;
  final rawScannedHash = file.contentHash;
  final scannedHash = safeContentHash(rawScannedHash);
  if (rawScannedHash != null && scannedHash == null) return false;
  final localHash = safeContentHash(link.contentHash);
  if (link.contentHash != null && localHash == null) return false;
  if (scannedHash != null) return localHash == scannedHash;
  if (!exactIdentity) return false;
  return file.sizeConfidence == RecordingCardFileSizeConfidence.trusted &&
      file.sizeBytes != null &&
      file.sizeBytes == link.actualSizeBytes;
}

AppFailure? _downloadedFileIntegrityFailure(
  RecordingCardDownloadedFile downloaded,
  RecordingCardScannedFile sourceFile,
) {
  final rawDownloadedHash = downloaded.contentHash;
  final downloadedHash = safeContentHash(rawDownloadedHash);
  final rawSourceHash = sourceFile.contentHash;
  final sourceHash = safeContentHash(rawSourceHash);
  if ((rawDownloadedHash != null && downloadedHash == null) ||
      (rawSourceHash != null && sourceHash == null)) {
    return recordingCardFailure(
      'RECORDING_CARD_LOCAL_FILE_METADATA_INVALID',
      'Recording-card download returned an invalid content digest',
      isRetryable: false,
    );
  }
  if (downloadedHash != null &&
      sourceHash != null &&
      downloadedHash != sourceHash) {
    return recordingCardFailure(
      'RECORDING_CARD_DOWNLOAD_HASH_MISMATCH',
      'Recording-card download did not match the directory content digest',
      isRetryable: true,
    );
  }
  if (sourceFile.format != RecordingCardFileFormat.unknown &&
      downloaded.format != RecordingCardFileFormat.unknown &&
      downloaded.format != sourceFile.format) {
    return recordingCardFailure(
      'RECORDING_CARD_DOWNLOAD_FORMAT_MISMATCH',
      'Recording-card download did not preserve the source format',
      isRetryable: false,
    );
  }
  return null;
}

RecordingCardScannedFile? _wifiSessionFileWithRetainedEvidence(
  RecordingCardScannedFile selected,
  RecordingCardScannedFile refreshed,
) {
  if (refreshed.deviceFileId != selected.deviceFileId ||
      refreshed.localFileKey != selected.localFileKey ||
      refreshed.deviceFilename != selected.deviceFilename) {
    return null;
  }
  final rawSelectedHash = selected.contentHash;
  final selectedHash = safeContentHash(rawSelectedHash);
  final rawRefreshedHash = refreshed.contentHash;
  final refreshedHash = safeContentHash(rawRefreshedHash);
  if ((rawSelectedHash != null && selectedHash == null) ||
      (rawRefreshedHash != null && refreshedHash == null) ||
      (selectedHash != null &&
          refreshedHash != null &&
          selectedHash != refreshedHash)) {
    return null;
  }
  if (selected.format != RecordingCardFileFormat.unknown &&
      refreshed.format != RecordingCardFileFormat.unknown &&
      selected.format != refreshed.format) {
    return null;
  }
  if (selected.sizeConfidence == RecordingCardFileSizeConfidence.trusted &&
      refreshed.sizeConfidence == RecordingCardFileSizeConfidence.trusted &&
      selected.sizeBytes != null &&
      refreshed.sizeBytes != null &&
      selected.sizeBytes != refreshed.sizeBytes) {
    return null;
  }
  final useRefreshedSize = refreshed.sizeBytes != null;
  final format = selected.format == RecordingCardFileFormat.unknown
      ? refreshed.format
      : selected.format;
  return RecordingCardScannedFile(
    deviceFileId: selected.deviceFileId,
    localFileKey: selected.localFileKey,
    deviceFilename: selected.deviceFilename,
    sizeBytes: useRefreshedSize ? refreshed.sizeBytes : selected.sizeBytes,
    durationSeconds: refreshed.durationSeconds ?? selected.durationSeconds,
    recordedAt: refreshed.recordedAt ?? selected.recordedAt,
    contentHash: selectedHash ?? refreshedHash,
    sizeConfidence: useRefreshedSize
        ? refreshed.sizeConfidence
        : selected.sizeConfidence,
    format: format,
    mimeType: selected.format == RecordingCardFileFormat.unknown
        ? refreshed.mimeType ?? selected.mimeType
        : selected.mimeType ?? refreshed.mimeType,
    syncState: selected.syncState,
    localFileId: selected.localFileId,
    appPrivateUri: selected.appPrivateUri,
  );
}

String _verifiedDownloadIdentity(String fingerprint, String deviceFileId) {
  return '${fingerprint.length}:$fingerprint:$deviceFileId';
}

String _recordingCardFileSignature(RecordingCardScannedFile file) {
  return '${file.deviceFileId}:${file.deviceFilename}:${file.sizeBytes ?? -1}:'
      '${file.recordedAt?.toUtc().toIso8601String() ?? ''}:'
      '${file.contentHash ?? ''}';
}

List<RecordingCardFileFormat> _recordingCardRecoveryFormats(
  RecordingCardFileLedgerEntry entry,
) {
  final extension = entry.deviceFilename.trim().split('.').last.toLowerCase();
  final inferred = RecordingCardFileFormat.values
      .where((format) => format != RecordingCardFileFormat.unknown)
      .where((format) => format.name == extension)
      .firstOrNull;
  return <RecordingCardFileFormat>{
    if (inferred != null) inferred,
    RecordingCardFileFormat.m4a,
    RecordingCardFileFormat.mp3,
    RecordingCardFileFormat.opus,
    RecordingCardFileFormat.wav,
  }.toList(growable: false);
}

RecordingCardScannedFile _recordingCardFileFromLedger(
  RecordingCardFileLedgerEntry entry, {
  required RecordingCardFileFormat format,
}) {
  final sizeBytes = entry.sizeBytes;
  return RecordingCardScannedFile(
    deviceFileId: entry.deviceFileId,
    localFileKey: entry.sourceSignature,
    deviceFilename: entry.deviceFilename,
    sizeBytes: sizeBytes,
    durationSeconds: entry.durationSeconds,
    recordedAt: entry.recordedAt,
    contentHash: entry.contentHash,
    sizeConfidence: sizeBytes != null && sizeBytes > 0
        ? RecordingCardFileSizeConfidence.trusted
        : null,
    format: format,
    mimeType: _mimeTypeFor(format),
  );
}

String? _downloadDeviceKey(RecordingCardDeviceState device) {
  return _recordingCardDeviceIdentity(device);
}

String? _recordingCardReconnectFingerprint(RecordingCardDeviceState device) {
  return _recordingCardReconnectFingerprintValue(device.safeDeviceFingerprint);
}

String? _recordingCardReconnectFingerprintValue(String? value) {
  final fingerprint = value?.trim();
  if (fingerprint == null ||
      fingerprint.isEmpty ||
      fingerprint.toLowerCase().startsWith('serial:') ||
      !isSafeRecordingCardIdentifier(fingerprint)) {
    return null;
  }
  return fingerprint;
}

bool _isPersistableRecordingCardDeviceIdentity(String value) {
  final identity = value.trim();
  if (identity.toLowerCase().startsWith('serial:')) {
    final serial = identity.substring('serial:'.length);
    return serial.isNotEmpty &&
        normalizeRecordingCardSerialNumberForOwnership(serial) == serial;
  }
  return isSafeRecordingCardIdentifier(identity);
}

bool _matchesWifiBatchReconnectTarget(
  RecordingCardDeviceState device,
  RecordingCardWifiBatchSnapshot batch,
) {
  final expectedDigest = _persistedWifiBatchCardSnDigest(batch);
  final connectedDigest = _recordingCardDigestForDevice(device);
  final fingerprintMatches =
      _recordingCardReconnectFingerprint(device) == batch.deviceFingerprint;
  if (expectedDigest != null) {
    return connectedDigest == expectedDigest && fingerprintMatches;
  }
  return fingerprintMatches;
}

String? _recordingCardDigestForDevice(RecordingCardDeviceState device) {
  return RecordingCardFileIdentity.digestSerialNumber(
    device.serialNumber ?? '',
  );
}

String? _recordingCardDigestFromIdentity(String? deviceIdentity) {
  final serial = _recordingCardSerialFromIdentity(deviceIdentity);
  if (serial == null) return null;
  return RecordingCardFileIdentity.digestSerialNumber(serial);
}

String? _recordingCardSerialFromIdentity(String? deviceIdentity) {
  final identity = deviceIdentity?.trim();
  if (identity == null ||
      !identity.toLowerCase().startsWith('serial:') ||
      identity.length <= 'serial:'.length) {
    return null;
  }
  return normalizeRecordingCardSerialNumberForOwnership(
    identity.substring('serial:'.length),
  );
}

String? _wifiBatchCardSnDigest(RecordingCardWifiBatchSnapshot batch) {
  final persisted = _persistedWifiBatchCardSnDigest(batch);
  return persisted == null
      ? _recordingCardDigestFromIdentity(batch.deviceIdentity)
      : persisted;
}

String? _persistedWifiBatchCardSnDigest(RecordingCardWifiBatchSnapshot batch) {
  final persisted = batch.cardSnDigest?.trim().toLowerCase();
  return persisted == null || persisted.isEmpty ? null : persisted;
}

RecordingCardSyncRetryability _manualWifiSyncRetryability(String errorCode) {
  final normalized = errorCode.trim().toUpperCase();
  if (normalized == 'RECORDING_CARD_WIFI_BATCH_STOPPED_BY_USER' ||
      normalized.contains('UNSUPPORTED') ||
      normalized.contains('INVALID') ||
      normalized.contains('CORRUPT') ||
      normalized.contains('HASH_MISMATCH')) {
    return RecordingCardSyncRetryability.permanent;
  }
  return RecordingCardSyncRetryability.transient;
}

bool _isRecordingCardDisconnectFailureCode(String? errorCode) {
  final normalized = errorCode?.trim().toUpperCase();
  if (normalized == null || normalized.isEmpty) return false;
  return normalized == 'RECORDING_CARD_DISCONNECTED' ||
      normalized == 'RECORDING_CARD_NOT_CONNECTED' ||
      normalized.endsWith('_DEVICE_DISCONNECTED') ||
      normalized.endsWith('_CONNECTION_LOST');
}

String? _recordingCardDeviceIdentity(RecordingCardDeviceState device) {
  final serial = normalizeRecordingCardSerialNumberForOwnership(
    device.serialNumber ?? '',
  );
  if (serial != null) return 'serial:$serial';
  final fingerprint = device.safeDeviceFingerprint?.trim();
  return fingerprint != null &&
          fingerprint.isNotEmpty &&
          isSafeRecordingCardIdentifier(fingerprint)
      ? fingerprint
      : null;
}

List<String> _recordingCardDeviceIdentityCandidates(
  RecordingCardDeviceState device,
) {
  final identities = <String>{};
  final canonical = _recordingCardDeviceIdentity(device);
  if (canonical != null) identities.add(canonical);
  final fingerprint = device.safeDeviceFingerprint?.trim();
  if (fingerprint != null &&
      fingerprint.isNotEmpty &&
      isSafeRecordingCardIdentifier(fingerprint)) {
    identities.add(fingerprint);
  }
  return identities.toList(growable: false);
}
