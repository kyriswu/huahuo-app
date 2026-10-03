import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/api/api_client.dart';
import 'package:huahuoai_app/core/api/idempotency.dart';
import 'package:huahuoai_app/core/api/upload_client.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/database/database_write_queue.dart';
import 'package:huahuoai_app/core/database/recording_dao.dart';
import 'package:huahuoai_app/core/native/recording_card_native_port.dart';
import 'package:huahuoai_app/core/storage/file_storage_port.dart';
import 'package:huahuoai_app/core/storage/upload_draft_store.dart';
import 'package:huahuoai_app/core/tasking/task_orchestrator.dart';
import 'package:huahuoai_app/features/recording_card/application/recording_card_auto_sync_coordinator.dart';
import 'package:huahuoai_app/features/recording_card/application/recording_card_sync_planner.dart';
import 'package:huahuoai_app/features/recording_card/data/recording_card_auto_sync_store.dart';
import 'package:huahuoai_app/features/recording_card/domain/recording_card_auto_sync.dart';
import 'package:huahuoai_app/features/recording_card/domain/recording_card_sync_ledger.dart';
import 'package:huahuoai_app/features/recordings/application/recording_processing_tracker.dart';
import 'package:huahuoai_app/features/recordings/application/recording_upload_controller.dart';
import 'package:huahuoai_app/features/recordings/data/local_recording_repository.dart';
import 'package:huahuoai_app/features/recordings/data/recording_api.dart';
import 'package:huahuoai_app/features/recordings/domain/recording_library.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('method channel reads truthful process-bound capability', () async {
    const channel = MethodChannel('huahuoai/auto-sync-background-test');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    MethodCall? received;
    messenger.setMockMethodCallHandler(channel, (call) async {
      received = call;
      return <String, Object?>{
        'mode': 'processBound',
        'enabled': true,
        'restoresAfterProcessDeath': false,
        'resumesOnNextAppLaunch': true,
      };
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final capability =
        await const MethodChannelRecordingCardBackgroundExecutionPort(
          channel: channel,
        ).update(
          const RecordingCardBackgroundExecutionRequest(
            keepAlive: true,
            transferActive: true,
            transport: RecordingCardBackgroundTransferTransport.bluetooth,
          ),
        );

    expect(received?.method, 'setRecordingCardAutoSyncBackgroundEnabled');
    expect(received?.arguments, <String, Object?>{
      'enabled': true,
      'keepAlive': true,
      'transferActive': true,
      'transport': 'bluetooth',
    });
    expect(capability.mode, RecordingCardBackgroundExecutionMode.processBound);
    expect(capability.restoresAfterProcessDeath, isFalse);
    expect(capability.resumesOnNextAppLaunch, isTrue);
  });

  test(
    'coordinator disposal stops process-bound foreground execution',
    () async {
      final background = _BackgroundExecution();
      final coordinator = RecordingCardAutoSyncCoordinator(
        persistence: _MemoryPersistence(),
        actions: _FakeActions(snapshot: _connectedSnapshot(fileCount: 0)),
        backgroundExecutionPort: background,
      );
      await _waitFor(() => background.calls.isNotEmpty);

      expect(background.calls, <RecordingCardBackgroundExecutionRequest>[
        const RecordingCardBackgroundExecutionRequest(
          keepAlive: true,
          transferActive: false,
        ),
      ]);
      expect(
        coordinator.backgroundCapability.mode,
        RecordingCardBackgroundExecutionMode.processBound,
      );
      expect(
        coordinator.backgroundCapability.restoresAfterProcessDeath,
        isFalse,
      );

      coordinator.dispose();
      await _waitFor(() => background.calls.length == 2);
      expect(background.calls, <RecordingCardBackgroundExecutionRequest>[
        const RecordingCardBackgroundExecutionRequest(
          keepAlive: true,
          transferActive: false,
        ),
        const RecordingCardBackgroundExecutionRequest.disabled(),
      ]);
    },
  );

  test(
    'disconnected coordinator never starts connected-device service',
    () async {
      final background = _BackgroundExecution();
      final coordinator = RecordingCardAutoSyncCoordinator(
        persistence: _MemoryPersistence(),
        actions: _FakeActions(snapshot: RecordingCardRuntimeSnapshot.initial()),
        backgroundExecutionPort: background,
      );
      await _waitFor(() => background.calls.isNotEmpty);

      expect(background.calls, <RecordingCardBackgroundExecutionRequest>[
        const RecordingCardBackgroundExecutionRequest.disabled(),
      ]);
      expect(coordinator.backgroundCapability.enabled, isFalse);

      coordinator.dispose();
      await _waitFor(() => background.calls.length == 2);
      expect(background.calls, <RecordingCardBackgroundExecutionRequest>[
        const RecordingCardBackgroundExecutionRequest.disabled(),
        const RecordingCardBackgroundExecutionRequest.disabled(),
      ]);
    },
  );

  test(
    'background state follows live transport even when connection is unchanged',
    () async {
      final background = _BackgroundExecution();
      final actions = _FakeActions(snapshot: _connectedSnapshot(fileCount: 0));
      final coordinator = RecordingCardAutoSyncCoordinator(
        persistence: _MemoryPersistence(),
        actions: actions,
        backgroundExecutionPort: background,
      );
      addTearDown(actions.dispose);
      await coordinator.setAutoSyncEnabled(false);
      await _waitFor(() => background.calls.isNotEmpty);
      expect(background.calls, <RecordingCardBackgroundExecutionRequest>[
        const RecordingCardBackgroundExecutionRequest(
          keepAlive: true,
          transferActive: false,
        ),
      ]);
      actions.setManualTransfer(true);
      actions.setActiveTransferTransport(
        RecordingCardBackgroundTransferTransport.bluetooth,
      );
      await _waitFor(() => background.calls.length == 2);
      expect(
        background.calls.last,
        const RecordingCardBackgroundExecutionRequest(
          keepAlive: true,
          transferActive: true,
          transport: RecordingCardBackgroundTransferTransport.bluetooth,
        ),
      );
      actions.setActiveTransferTransport(
        RecordingCardBackgroundTransferTransport.wifi,
      );
      await _waitFor(() => background.calls.length == 3);
      expect(
        background.calls.last,
        const RecordingCardBackgroundExecutionRequest(
          keepAlive: true,
          transferActive: true,
          transport: RecordingCardBackgroundTransferTransport.wifi,
        ),
      );
      actions.setConnected(false);
      await _waitFor(() => background.calls.length == 4);
      expect(
        background.calls.last,
        const RecordingCardBackgroundExecutionRequest(
          keepAlive: false,
          transferActive: true,
          transport: RecordingCardBackgroundTransferTransport.wifi,
        ),
      );
      expect(coordinator.backgroundCapability.enabled, isTrue);
      actions.setActiveTransferTransport(null);
      await _waitFor(() => background.calls.length == 5);
      expect(actions.hasActiveTransfer, isTrue);
      expect(
        background.calls.last,
        const RecordingCardBackgroundExecutionRequest.disabled(),
      );
      coordinator.dispose();
      await _waitFor(() => background.calls.length == 6);
      expect(
        background.calls.last,
        const RecordingCardBackgroundExecutionRequest.disabled(),
      );
    },
  );

  test(
    'shared sync task starts in background with stable resource budgets',
    () async {
      final orchestrator = TaskOrchestrator()..setForeground(false);
      addTearDown(orchestrator.dispose);
      final actions = _FakeActions(snapshot: _connectedSnapshot(fileCount: 1));
      final coordinator = RecordingCardAutoSyncCoordinator(
        persistence: _MemoryPersistence(),
        actions: actions,
        taskOrchestrator: orchestrator,
      );
      addTearDown(coordinator.dispose);

      await _waitFor(() => coordinator.state.completedCount == 1);
      await _waitFor(
        () =>
            orchestrator
                    .projectionFor(
                      RecordingCardAutoSyncCoordinator.autoSyncTaskKey,
                    )
                    ?.state
                is AppTaskSucceeded,
      );

      final projection = orchestrator.projectionFor(
        RecordingCardAutoSyncCoordinator.autoSyncTaskKey,
      );
      expect(projection?.state, isA<AppTaskSucceeded>());
      expect(projection?.spec.owner, 'recording-card-auto-sync');
      expect(projection?.spec.foregroundOnly, isFalse);
      expect(projection?.spec.replaceExisting, isFalse);
      expect(projection?.spec.resources, <TaskResource>{
        TaskResource.network,
        TaskResource.media,
      });
      expect(actions.scanCalls, greaterThan(0));
      expect(actions.downloadLog, <String>['file-0']);
    },
  );

  test(
    'backgrounding keeps current download and advances to next file',
    () async {
      final orchestrator = TaskOrchestrator();
      addTearDown(orchestrator.dispose);
      final downloadGate = Completer<void>();
      final actions = _FakeActions(
        snapshot: _connectedSnapshot(fileCount: 2),
        downloadGate: downloadGate,
      );
      final coordinator = RecordingCardAutoSyncCoordinator(
        persistence: _MemoryPersistence(),
        actions: actions,
        taskOrchestrator: orchestrator,
      );
      addTearDown(coordinator.dispose);
      await _waitFor(() => actions.downloadLog.length == 1);

      orchestrator.setForeground(false);
      downloadGate.complete();
      await _waitFor(() => coordinator.state.completedCount == 2);

      expect(actions.downloadLog, <String>['file-0', 'file-1']);
      expect(
        orchestrator
            .projectionFor(RecordingCardAutoSyncCoordinator.autoSyncTaskKey)
            ?.state,
        isA<AppTaskSucceeded>(),
      );
    },
  );

  test('disconnect cancels a scan and reconnect resumes once', () async {
    final orchestrator = TaskOrchestrator();
    addTearDown(orchestrator.dispose);
    final scanGate = Completer<void>();
    final actions = _FakeActions(
      snapshot: _connectedSnapshot(fileCount: 1),
      scanGate: scanGate,
    );
    final coordinator = RecordingCardAutoSyncCoordinator(
      persistence: _MemoryPersistence(),
      actions: actions,
      taskOrchestrator: orchestrator,
    );
    addTearDown(coordinator.dispose);
    await _waitFor(
      () => coordinator.state.status == RecordingCardAutoSyncStatus.scanning,
    );

    actions.setConnected(false);
    expect(
      coordinator.state.status,
      RecordingCardAutoSyncStatus.waitingForDevice,
    );
    scanGate.complete();
    await _waitFor(
      () =>
          orchestrator
                  .projectionFor(
                    RecordingCardAutoSyncCoordinator.autoSyncTaskKey,
                  )
                  ?.state
              is AppTaskCancelled,
    );
    expect(actions.downloadLog, isEmpty);

    actions.setConnected(true);
    await _waitFor(() => coordinator.state.completedCount == 1);
    expect(actions.downloadLog, <String>['file-0']);
    expect(actions.maxConcurrentDownloads, 1);
  });

  test('defaults on and downloads connected files strictly serially', () async {
    final persistence = _MemoryPersistence();
    final actions = _FakeActions(snapshot: _connectedSnapshot(fileCount: 3));
    final coordinator = RecordingCardAutoSyncCoordinator(
      persistence: persistence,
      actions: actions,
    );
    addTearDown(coordinator.dispose);

    await _waitFor(() => coordinator.state.completedCount == 3);

    expect(coordinator.state.preferences.autoSyncEnabled, isTrue);
    expect(coordinator.state.preferences.autoTranscriptionEnabled, isFalse);
    expect(actions.downloadLog, <String>['file-0', 'file-1', 'file-2']);
    expect(actions.maxConcurrentDownloads, 1);
    expect(actions.scanCalls, 3);
    expect(actions.forceRefreshLog, <bool>[false, true, true]);
    expect(
      persistence.tasks.values.every(
        (task) => task.state == RecordingCardAutoSyncTaskState.completed,
      ),
      isTrue,
    );
  });

  test('fresh directory revision replaces duplicate preflight read', () async {
    final actions = _FakeActions(
      snapshot: _connectedSnapshot(fileCount: 1),
      publishSuccessfulRevisionOnScan: true,
    );
    final coordinator = RecordingCardAutoSyncCoordinator(
      persistence: _MemoryPersistence(),
      actions: actions,
    );
    addTearDown(coordinator.dispose);

    await _waitFor(() => coordinator.state.completedCount == 1);

    expect(actions.downloadLog, <String>['file-0']);
    expect(actions.scanCalls, 2);
    expect(actions.forceRefreshLog, <bool>[false, true]);
  });

  test(
    'foreground resume does not append a revision-owned directory run',
    () async {
      final actions = _FakeActions(
        snapshot: _connectedSnapshot(fileCount: 1),
        publishSuccessfulRevisionOnScan: true,
      );
      final coordinator = RecordingCardAutoSyncCoordinator(
        persistence: RecordingCardAutoSyncStore(
          database: AppDatabase(),
          accountScope: 'account-foreground-revision-deduplication',
        ),
        actions: actions,
      );
      addTearDown(coordinator.dispose);
      await _waitFor(
        () => coordinator.state.status == RecordingCardAutoSyncStatus.completed,
      );
      await Future<void>.delayed(Duration.zero);
      final scanCount = actions.scanCalls;

      actions.publishSuccessfulDirectoryRefresh();
      coordinator.resume(requestDeviceSync: false);
      await _waitFor(() => actions.scanCalls >= scanCount + 1);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(actions.forceRefreshLog.skip(scanCount), <bool>[false]);
    },
  );

  test(
    'raw directory projection cannot trigger but a successful revision can',
    () async {
      final actions = _FakeActions(snapshot: _connectedSnapshot(fileCount: 1));
      final coordinator = RecordingCardAutoSyncCoordinator(
        persistence: RecordingCardAutoSyncStore(
          database: AppDatabase(),
          accountScope: 'account-authoritative-directory-trigger',
        ),
        actions: actions,
      );
      addTearDown(coordinator.dispose);
      await _waitFor(
        () => coordinator.state.status == RecordingCardAutoSyncStatus.completed,
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final scansBeforeProjection = actions.scanCalls;

      actions.addFile(1);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(actions.scanCalls, scansBeforeProjection);
      expect(actions.downloadLog, <String>['file-0']);

      actions.publishSuccessfulDirectoryRefresh();
      await _waitFor(() => actions.downloadLog.length == 2);
      await _waitFor(
        () => coordinator.state.status == RecordingCardAutoSyncStatus.completed,
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(actions.downloadLog, <String>['file-0', 'file-1']);
      expect(actions.scanCalls, scansBeforeProjection + 2);
    },
  );

  test('unrelated transfer completion cannot restart terminal sync', () async {
    final actions = _FakeActions(snapshot: _connectedSnapshot(fileCount: 0));
    final coordinator = RecordingCardAutoSyncCoordinator(
      persistence: _MemoryPersistence(),
      actions: actions,
    );
    addTearDown(coordinator.dispose);
    await _waitFor(
      () => coordinator.state.status == RecordingCardAutoSyncStatus.completed,
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final scansBeforeTransfer = actions.scanCalls;

    actions.setManualTransfer(true);
    actions.setManualTransfer(false);
    actions.setManualTransfer(false);
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(actions.scanCalls, scansBeforeTransfer);
    expect(coordinator.state.status, RecordingCardAutoSyncStatus.completed);
    expect(coordinator.syncSession.waitingReason, isNull);
  });

  test('fresh empty directory needs no verification read', () async {
    final store = RecordingCardAutoSyncStore(
      database: AppDatabase(),
      accountScope: 'account-fresh-empty-directory',
    );
    final actions = _FakeActions(
      snapshot: _connectedSnapshot(fileCount: 0),
      publishSuccessfulRevisionOnScan: true,
    );
    final coordinator = RecordingCardAutoSyncCoordinator(
      persistence: store,
      actions: actions,
    );
    addTearDown(coordinator.dispose);

    await _waitFor(
      () =>
          coordinator.syncSession.status ==
          RecordingCardSyncSessionStatus.completed,
    );

    expect(actions.scanCalls, 1);
    expect(actions.forceRefreshLog, <bool>[false]);
  });

  test('verified empty directory skips post-transfer verification', () async {
    final actions = _FakeActions(snapshot: _connectedSnapshot(fileCount: 0));
    final coordinator = RecordingCardAutoSyncCoordinator(
      persistence: _MemoryPersistence(),
      actions: actions,
    );
    addTearDown(coordinator.dispose);

    await _waitFor(
      () => coordinator.state.status == RecordingCardAutoSyncStatus.completed,
    );

    expect(actions.downloadLog, isEmpty);
    expect(actions.scanCalls, 2);
    expect(actions.forceRefreshLog, <bool>[false, true]);
  });

  test('pause cancels active transfer until explicit continue', () async {
    final downloadGate = Completer<void>();
    final actions = _FakeActions(
      snapshot: _connectedSnapshot(fileCount: 1),
      downloadGate: downloadGate,
    );
    final coordinator = RecordingCardAutoSyncCoordinator(
      persistence: _MemoryPersistence(),
      actions: actions,
    );
    addTearDown(coordinator.dispose);
    await _waitFor(
      () => coordinator.state.status == RecordingCardAutoSyncStatus.downloading,
    );

    await coordinator.pause();

    expect(actions.pauseCalls, 1);
    expect(coordinator.state.status, RecordingCardAutoSyncStatus.paused);
    expect(
      coordinator.syncSession.status,
      RecordingCardSyncSessionStatus.paused,
    );
    expect(coordinator.state.pendingCount, 1);
    coordinator.resume();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(actions.downloadLog, <String>['file-0']);

    coordinator.continueSync();
    await _waitFor(() => coordinator.state.completedCount == 1);
    expect(actions.downloadLog, <String>['file-0', 'file-0']);
  });

  test('Wi-Fi handoff waits for BLE settlement before refreshing', () async {
    final downloadGate = Completer<void>();
    final actions = _FakeActions(
      snapshot: _connectedSnapshot(fileCount: 1),
      downloadGate: downloadGate,
      pauseReleasesDownload: false,
    );
    final coordinator = RecordingCardAutoSyncCoordinator(
      persistence: _MemoryPersistence(),
      actions: actions,
    );
    addTearDown(coordinator.dispose);
    await _waitFor(
      () => coordinator.state.status == RecordingCardAutoSyncStatus.downloading,
    );
    final scansBeforeHandoff = actions.scanCalls;
    final digest = RecordingCardFileIdentity.digestSerialNumber('CARD-000001')!;
    var handoffCompleted = false;

    final handoff = coordinator
        .prepareWifiHandoff(expectedCardSnDigest: digest)
        .whenComplete(() => handoffCompleted = true);
    await Future<void>.delayed(Duration.zero);

    expect(actions.pauseCalls, 1);
    expect(handoffCompleted, isFalse);
    expect(actions.scanCalls, scansBeforeHandoff);

    downloadGate.complete();
    final result = await handoff;

    expect(result.ok, isTrue);
    expect(coordinator.isPaused, isTrue);
    expect(coordinator.state.pendingFileSyncCount, 1);
    expect(actions.scanCalls, scansBeforeHandoff + 1);
    expect(actions.forceRefreshLog.last, isTrue);
  });

  test(
    'Wi-Fi handoff pauses and refreshes when automatic sync is off',
    () async {
      final actions = _FakeActions(snapshot: _connectedSnapshot(fileCount: 1));
      final coordinator = RecordingCardAutoSyncCoordinator(
        persistence: _MemoryPersistence(
          preferences: const RecordingCardAutoSyncPreferences(
            autoSyncEnabled: false,
          ),
        ),
        actions: actions,
      );
      addTearDown(coordinator.dispose);
      final digest = RecordingCardFileIdentity.digestSerialNumber(
        'CARD-000001',
      )!;

      final result = await coordinator.prepareWifiHandoff(
        expectedCardSnDigest: digest,
      );

      expect(result.ok, isTrue, reason: result.error?.code);
      expect(coordinator.isPaused, isTrue);
      expect(
        coordinator.syncSession.status,
        RecordingCardSyncSessionStatus.disabled,
      );
      expect(actions.scanCalls, 1);
      expect(actions.forceRefreshLog, <bool>[true]);
    },
  );

  test('Wi-Fi handoff pauses and refreshes with no automatic work', () async {
    final actions = _FakeActions(snapshot: _connectedSnapshot(fileCount: 0));
    final coordinator = RecordingCardAutoSyncCoordinator(
      persistence: _MemoryPersistence(),
      actions: actions,
    );
    addTearDown(coordinator.dispose);
    await _waitFor(
      () => coordinator.state.status == RecordingCardAutoSyncStatus.completed,
    );
    expect(coordinator.state.pendingFileSyncCount, 0);
    final scansBeforeHandoff = actions.scanCalls;
    final digest = RecordingCardFileIdentity.digestSerialNumber('CARD-000001')!;

    final result = await coordinator.prepareWifiHandoff(
      expectedCardSnDigest: digest,
    );

    expect(result.ok, isTrue, reason: result.error?.code);
    expect(coordinator.isPaused, isTrue);
    expect(
      coordinator.syncSession.status,
      RecordingCardSyncSessionStatus.paused,
    );
    expect(actions.scanCalls, scansBeforeHandoff + 1);
    expect(actions.forceRefreshLog.last, isTrue);
  });

  test(
    'completed task is rebuilt when its verified local file is gone',
    () async {
      final actions = _FakeActions(snapshot: _connectedSnapshot(fileCount: 1));
      final coordinator = RecordingCardAutoSyncCoordinator(
        persistence: _MemoryPersistence(),
        actions: actions,
      );
      addTearDown(coordinator.dispose);
      await _waitFor(() => coordinator.state.completedCount == 1);

      actions.markFileProjection(0, RecordingCardFileSyncState.localMissing);
      actions.publishSuccessfulDirectoryRefresh();
      await _waitFor(() => actions.downloadLog.length == 2);
      await _waitFor(() => coordinator.state.completedCount == 1);

      expect(actions.downloadLog, <String>['file-0', 'file-0']);
      expect(coordinator.state.completedCount, 1);
    },
  );

  test(
    'disabling a paused session clears pause without resuming work',
    () async {
      final gate = Completer<void>();
      final actions = _FakeActions(
        snapshot: _connectedSnapshot(fileCount: 1),
        downloadGate: gate,
      );
      final coordinator = RecordingCardAutoSyncCoordinator(
        persistence: _MemoryPersistence(),
        actions: actions,
      );
      addTearDown(coordinator.dispose);
      await _waitFor(
        () =>
            coordinator.state.status == RecordingCardAutoSyncStatus.downloading,
      );
      await coordinator.pause();
      await coordinator.setAutoSyncEnabled(false);
      await coordinator.pause();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(
        coordinator.syncSession.status,
        RecordingCardSyncSessionStatus.disabled,
      );
      expect(coordinator.state.status, RecordingCardAutoSyncStatus.idle);
      coordinator.continueSync();
      coordinator.resume();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(actions.downloadLog, <String>['file-0']);
      await coordinator.setAutoSyncEnabled(true);
      await _waitFor(() => coordinator.state.completedCount == 1);
      expect(actions.downloadLog, <String>['file-0', 'file-0']);
    },
  );

  test(
    'completed task ignores a later advisory device-only projection',
    () async {
      final actions = _FakeActions(snapshot: _connectedSnapshot(fileCount: 1));
      final coordinator = RecordingCardAutoSyncCoordinator(
        persistence: RecordingCardAutoSyncStore(
          database: AppDatabase(),
          accountScope: 'account-ledger-advisory-projection',
        ),
        actions: actions,
      );
      addTearDown(coordinator.dispose);
      await _waitFor(
        () =>
            coordinator.state.completedCount == 1 &&
            coordinator.state.status == RecordingCardAutoSyncStatus.completed,
      );
      final scansBeforeProjection = actions.scanCalls;

      actions.markFileProjection(0, RecordingCardFileSyncState.deviceOnly);
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(actions.downloadLog, <String>['file-0']);
      expect(actions.scanCalls, scansBeforeProjection);
      expect(coordinator.state.completedCount, 1);
      expect(
        coordinator.state.tasks.single.state,
        RecordingCardAutoSyncTaskState.completed,
      );
    },
  );

  test('ledger terminal facts settle stale queued tasks', () async {
    final digest = RecordingCardFileIdentity.digestSerialNumber('CARD-000001')!;
    final now = DateTime.utc(2026, 9, 4, 10);

    Future<void> verifyCase(
      String accountScope,
      RecordingCardFileLedgerEntry Function(
        RecordingCardFileLedgerEntry discovered,
      )
      buildEntry,
      RecordingCardAutoSyncTaskState expectedState,
    ) async {
      final store = RecordingCardAutoSyncStore(
        database: AppDatabase(),
        accountScope: accountScope,
      );
      final file = _file(0);
      final signature = RecordingCardFileIdentity.sourceSignatureFor(
        cardSnDigest: digest,
        deviceFileId: file.deviceFileId,
        deviceFilename: file.deviceFilename,
        sizeBytes: file.sizeBytes,
        recordedAt: file.recordedAt,
      );
      final entry = buildEntry(
        RecordingCardFileLedgerEntry.discovered(
          cardSnDigest: digest,
          sourceSignature: signature,
          deviceFileId: file.deviceFileId,
          deviceFilename: file.deviceFilename,
          seenAt: now,
          sizeBytes: file.sizeBytes,
        ),
      );
      store.saveFileLedgerEntry(entry);
      store.saveSyncCheckpoint(
        RecordingCardSyncCheckpoint.empty(
          cardSnDigest: digest,
          at: now,
        ).noteDirectoryRead(now),
      );
      store.saveTask(
        RecordingCardAutoSyncTask(
          taskId: 'stale-$accountScope',
          deviceFingerprint: 'device-safe',
          deviceFileId: file.deviceFileId,
          deviceFilename: file.deviceFilename,
          localFileKey: file.localFileKey,
          order: 0,
          state: RecordingCardAutoSyncTaskState.queued,
          attemptCount: 0,
          createdAt: now,
          updatedAt: now,
          cardSnDigest: digest,
          sourceSignature: signature,
        ),
      );
      final actions = _FakeActions(snapshot: _connectedSnapshot(fileCount: 1));
      final coordinator = RecordingCardAutoSyncCoordinator(
        persistence: store,
        actions: actions,
      );

      await _waitFor(
        () => coordinator.state.tasks.single.state == expectedState,
      );
      if (expectedState == RecordingCardAutoSyncTaskState.failed) {
        await _waitFor(
          () => coordinator.state.status == RecordingCardAutoSyncStatus.failed,
        );
      }

      expect(actions.downloadLog, isEmpty);
      coordinator.dispose();
    }

    await verifyCase(
      'account-reconcile-synced',
      (entry) => entry
          .queue(at: now, manual: false)
          .markSynced(at: now, localRecordingId: 'local-file-0'),
      RecordingCardAutoSyncTaskState.completed,
    );
    await verifyCase(
      'account-reconcile-failed',
      (entry) => entry
          .queue(at: now, manual: false)
          .markFailed(
            at: now,
            errorCode: 'PERMANENT_DOWNLOAD_FAILURE',
            retryability: RecordingCardSyncRetryability.permanent,
          ),
      RecordingCardAutoSyncTaskState.failed,
    );
    await verifyCase(
      'account-reconcile-card-deleted',
      (entry) => entry.markCardDeleted(now),
      RecordingCardAutoSyncTaskState.completed,
    );
    await verifyCase(
      'account-reconcile-local-deleted',
      (entry) => entry
          .queue(at: now, manual: false)
          .markSynced(at: now, localRecordingId: 'local-file-0')
          .beginLocalDeletion(now)
          .finishLocalDeletion(now),
      RecordingCardAutoSyncTaskState.completed,
    );
    await verifyCase(
      'account-reconcile-legacy-unknown',
      (entry) => RecordingCardFileLedgerEntry.legacyUnknown(
        cardSnDigest: entry.cardSnDigest,
        sourceSignature: entry.sourceSignature,
        deviceFileId: entry.deviceFileId,
        deviceFilename: entry.deviceFilename,
        seenAt: now,
        sizeBytes: entry.sizeBytes,
      ),
      RecordingCardAutoSyncTaskState.completed,
    );
  });

  test(
    'successful directory revision projects ledger while auto sync is disabled',
    () async {
      final store = RecordingCardAutoSyncStore(
        database: AppDatabase(),
        accountScope: 'account-disabled-directory-observation',
      );
      store.savePreferences(
        const RecordingCardAutoSyncPreferences(autoSyncEnabled: false),
      );
      final digest = RecordingCardFileIdentity.digestSerialNumber(
        'CARD-000001',
      )!;
      final now = DateTime.utc(2026, 9, 4, 10);
      final historicalSignature = RecordingCardFileIdentity.sourceSignatureFor(
        cardSnDigest: digest,
        deviceFileId: 'historical',
        deviceFilename: 'HISTORICAL.WAV',
        sizeBytes: 512,
      );
      store.saveFileLedgerEntry(
        RecordingCardFileLedgerEntry.discovered(
          cardSnDigest: digest,
          sourceSignature: historicalSignature,
          deviceFileId: 'historical',
          deviceFilename: 'HISTORICAL.WAV',
          seenAt: now,
          sizeBytes: 512,
        ),
      );
      final actions = _FakeActions(snapshot: _connectedSnapshot(fileCount: 1));
      final coordinator = RecordingCardAutoSyncCoordinator(
        persistence: store,
        actions: actions,
        clock: () => now,
      );
      addTearDown(coordinator.dispose);

      actions.publishSuccessfulDirectoryRefresh();
      await _waitFor(
        () => store.loadSyncCheckpoint(digest)?.lastDirectoryReadAt == now,
      );

      final entries = store.loadFileLedger(digest);
      final current = entries.singleWhere(
        (entry) => entry.deviceFileId == 'file-0',
      );
      final historical = entries.singleWhere(
        (entry) => entry.deviceFileId == 'historical',
      );
      expect(actions.scanCalls, 0);
      expect(current.localState, RecordingCardFileLocalState.neverSynced);
      expect(current.cardState, RecordingCardFilePresenceState.present);
      expect(historical.cardState, RecordingCardFilePresenceState.unknown);
    },
  );

  test('reconstruction reinstalls a persisted transient retry timer', () async {
    final store = RecordingCardAutoSyncStore(
      database: AppDatabase(),
      accountScope: 'account-persisted-transient-retry',
    );
    final digest = RecordingCardFileIdentity.digestSerialNumber('CARD-000001')!;
    final now = DateTime.utc(2026, 9, 4, 10);
    final retryAt = now.add(const Duration(minutes: 5));
    final file = _file(0);
    final signature = RecordingCardFileIdentity.sourceSignatureFor(
      cardSnDigest: digest,
      deviceFileId: file.deviceFileId,
      deviceFilename: file.deviceFilename,
      sizeBytes: file.sizeBytes,
      recordedAt: file.recordedAt,
    );
    final failedEntry =
        RecordingCardFileLedgerEntry.discovered(
              cardSnDigest: digest,
              sourceSignature: signature,
              deviceFileId: file.deviceFileId,
              deviceFilename: file.deviceFilename,
              seenAt: now,
              sizeBytes: file.sizeBytes,
            )
            .queue(at: now, manual: false)
            .beginSync(now)
            .markFailed(
              at: now,
              errorCode: 'TRANSIENT_DOWNLOAD_FAILURE',
              retryability: RecordingCardSyncRetryability.transient,
              nextRetryAt: retryAt,
            );
    store.saveFileLedgerEntry(failedEntry);
    store.saveSyncCheckpoint(
      RecordingCardSyncCheckpoint.empty(
        cardSnDigest: digest,
        at: now,
      ).noteDirectoryRead(now),
    );
    store.saveTask(
      RecordingCardAutoSyncTask(
        taskId: 'persisted-transient-task',
        deviceFingerprint: 'device-safe',
        deviceFileId: file.deviceFileId,
        deviceFilename: file.deviceFilename,
        localFileKey: file.localFileKey,
        order: 0,
        state: RecordingCardAutoSyncTaskState.failed,
        attemptCount: failedEntry.attemptCount,
        createdAt: now,
        updatedAt: now,
        cardSnDigest: digest,
        sourceSignature: signature,
        errorCode: failedEntry.errorCode,
        retryability: failedEntry.retryability,
        nextRetryAt: retryAt,
      ),
    );
    final retryGate = Completer<void>();
    Duration? observedDelay;
    final actions = _FakeActions(snapshot: _connectedSnapshot(fileCount: 1));
    final coordinator = RecordingCardAutoSyncCoordinator(
      persistence: store,
      actions: actions,
      clock: () => now,
      retryDelay: (delay) {
        observedDelay = delay;
        return retryGate.future;
      },
    );
    addTearDown(coordinator.dispose);

    await _waitFor(() => observedDelay != null);
    expect(observedDelay, const Duration(minutes: 5));
    expect(actions.downloadLog, isEmpty);

    retryGate.complete();
    await _waitFor(
      () => store.loadSyncCheckpoint(digest)?.lastSuccessfulAutoSyncAt != null,
    );
    expect(actions.downloadLog, <String>['file-0']);
  });

  test(
    'recording and manual transfer pause without interrupting either',
    () async {
      final actions = _FakeActions(
        snapshot: _connectedSnapshot(
          fileCount: 1,
          recordingState: RecordingCardRecordingState.recording,
        ),
      );
      final coordinator = RecordingCardAutoSyncCoordinator(
        persistence: _MemoryPersistence(),
        actions: actions,
      );
      addTearDown(coordinator.dispose);
      await _waitFor(
        () =>
            coordinator.state.status ==
            RecordingCardAutoSyncStatus.waitingForRecording,
      );
      expect(actions.downloadLog, isEmpty);

      actions.setManualTransfer(true);
      actions.setRecordingState(RecordingCardRecordingState.idle);
      await _waitFor(
        () =>
            coordinator.state.status ==
            RecordingCardAutoSyncStatus.waitingForTransfer,
      );
      expect(actions.downloadLog, isEmpty);

      actions.setManualTransfer(false);
      await _waitFor(() => coordinator.state.completedCount == 1);
      expect(actions.downloadLog, <String>['file-0']);
      final scansAfterResume = actions.scanCalls;

      actions.setManualTransfer(false);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(actions.scanCalls, scansAfterResume);
    },
  );

  test(
    'recording completion failure waits for the bounded refresh journey',
    () async {
      final actions = _FakeActions(
        snapshot: _connectedSnapshot(
          fileCount: 1,
          recordingState: RecordingCardRecordingState.recording,
        ),
      );
      final coordinator = RecordingCardAutoSyncCoordinator(
        persistence: _MemoryPersistence(),
        actions: actions,
      );
      addTearDown(coordinator.dispose);
      await _waitFor(
        () =>
            coordinator.state.status ==
            RecordingCardAutoSyncStatus.waitingForRecording,
      );

      actions.setCompletionRefreshState(
        pending: true,
        failureCode: 'RECORDING_CARD_SCAN_FAILED',
      );
      actions.setRecordingState(RecordingCardRecordingState.idle);
      await Future<void>.delayed(Duration.zero);

      expect(
        coordinator.state.status,
        RecordingCardAutoSyncStatus.waitingForRecording,
      );

      actions.setCompletionRefreshState(
        pending: false,
        failureCode: 'RECORDING_CARD_SCAN_FAILED',
      );
      await _waitFor(
        () => coordinator.state.status == RecordingCardAutoSyncStatus.failed,
      );

      expect(coordinator.state.lastErrorCode, 'RECORDING_CARD_SCAN_FAILED');
    },
  );

  test('manual Wi-Fi owner keeps its syncing ledger until release', () async {
    final store = RecordingCardAutoSyncStore(
      database: AppDatabase(),
      accountScope: 'account-manual-wifi-owner',
    );
    final actions = _FakeActions(snapshot: _connectedSnapshot(fileCount: 1));
    actions.setManualTransfer(true);
    final digest = RecordingCardFileIdentity.digestSerialNumber('CARD-000001')!;
    final syncing = store.beginManualSyncForFile(
      cardSnDigest: digest,
      file: actions.snapshot.files.single,
      at: DateTime.utc(2026, 9, 5, 8),
    );
    final coordinator = RecordingCardAutoSyncCoordinator(
      persistence: store,
      actions: actions,
    );
    addTearDown(coordinator.dispose);

    await _waitFor(
      () =>
          coordinator.state.status ==
          RecordingCardAutoSyncStatus.waitingForTransfer,
    );
    expect(
      store
          .findFileLedgerEntry(
            cardSnDigest: digest,
            sourceSignature: syncing.sourceSignature,
          )
          ?.localState,
      RecordingCardFileLocalState.syncing,
    );
    expect(actions.downloadLog, isEmpty);

    actions.setManualTransfer(false);
    await _waitFor(() => coordinator.state.completedCount == 1);

    expect(actions.downloadLog, <String>['file-0']);
    expect(
      store
          .findFileLedgerEntry(
            cardSnDigest: digest,
            sourceSignature: syncing.sourceSignature,
          )
          ?.localState,
      RecordingCardFileLocalState.synced,
    );
  });

  test(
    'cancelled Wi-Fi projection does not need route acknowledgement to continue',
    () async {
      final actions = _FakeActions(snapshot: _connectedSnapshot(fileCount: 1));
      actions.setManualTransfer(true);
      final coordinator = RecordingCardAutoSyncCoordinator(
        persistence: _MemoryPersistence(),
        actions: actions,
      );
      addTearDown(coordinator.dispose);
      addTearDown(actions.dispose);

      await _waitFor(
        () =>
            coordinator.state.status ==
            RecordingCardAutoSyncStatus.waitingForTransfer,
      );

      actions.settleManualWifiAsCancelledKeepingProjection();
      await _waitFor(() => coordinator.state.completedCount == 1);

      expect(actions.cancelledWifiProjectionRetained, isTrue);
      expect(actions.downloadLog, <String>['file-0']);
    },
  );

  test(
    'ledger commits a full sync but a no-op refresh only records reading',
    () async {
      var now = DateTime.utc(2026, 9, 4, 10);
      final store = RecordingCardAutoSyncStore(
        database: AppDatabase(),
        accountScope: 'account-checkpoint-boundary',
      );
      final actions = _FakeActions(snapshot: _connectedSnapshot(fileCount: 2));
      final coordinator = RecordingCardAutoSyncCoordinator(
        persistence: store,
        actions: actions,
        clock: () => now,
      );
      addTearDown(coordinator.dispose);
      final digest = RecordingCardFileIdentity.digestSerialNumber(
        'CARD-000001',
      )!;

      await _waitFor(
        () => store.loadSyncCheckpoint(digest)?.lastSuccessfulAutoSyncAt == now,
      );
      expect(
        store.loadFileLedger(digest).map((entry) => entry.localState),
        everyElement(RecordingCardFileLocalState.synced),
      );
      final committedAt = store
          .loadSyncCheckpoint(digest)!
          .lastSuccessfulAutoSyncAt;
      final scansBeforeRefresh = actions.scanCalls;

      now = now.add(const Duration(hours: 1));
      actions.publishSuccessfulDirectoryRefresh();
      await _waitFor(() => actions.scanCalls >= scansBeforeRefresh + 1);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      final refreshed = store.loadSyncCheckpoint(digest)!;
      expect(refreshed.lastSuccessfulAutoSyncAt, committedAt);
      expect(refreshed.lastDirectoryReadAt, now);
      expect(actions.downloadLog, <String>['file-0', 'file-1']);
    },
  );

  test(
    'plan and commit wait for durability without transcription overrides',
    () async {
      final planGate = Completer<void>();
      final commitGate = Completer<void>();
      var planReached = false;
      var commitReached = false;
      final worker = _ControlledLedgerWriteWorker((mutations) async {
        if (mutations.any(
          (mutation) => mutation.value?['local_state'] == 'queued',
        )) {
          planReached = true;
          await planGate.future;
        }
        if (mutations.any(
          (mutation) => mutation.value?['last_successful_auto_sync_at'] != null,
        )) {
          commitReached = true;
          await commitGate.future;
        }
      });
      final database = AppDatabase(
        writeWorker: worker,
        writeQueue: DatabaseWriteQueue(),
      );
      final store = RecordingCardAutoSyncStore(
        database: database,
        accountScope: 'durable-boundaries',
      );
      store.savePreferences(
        const RecordingCardAutoSyncPreferences(autoTranscriptionEnabled: true),
      );
      final actions = _FakeActions(snapshot: _connectedSnapshot(fileCount: 1));
      final transcription = _ControlledTranscriptionPort();
      final coordinator = RecordingCardAutoSyncCoordinator(
        persistence: store,
        actions: actions,
        transcriptionPort: transcription,
      );
      addTearDown(coordinator.dispose);
      await _waitFor(() => planReached);
      expect(
        coordinator.syncSession.status,
        RecordingCardSyncSessionStatus.planning,
      );
      expect(actions.downloadLog, isEmpty);
      planGate.complete();
      await _waitFor(() => commitReached);
      expect(
        coordinator.syncSession.status,
        RecordingCardSyncSessionStatus.committing,
      );
      expect(coordinator.state.status, RecordingCardAutoSyncStatus.committing);
      expect(
        coordinator.connectedCardCheckpoint?.lastSuccessfulAutoSyncAt,
        isNull,
      );
      transcription.completeSuccess();
      await _waitFor(() => coordinator.state.completedCount == 1);
      expect(coordinator.state.status, RecordingCardAutoSyncStatus.committing);
      commitGate.complete();
      await _waitFor(
        () =>
            coordinator.syncSession.status ==
            RecordingCardSyncSessionStatus.completed,
      );
      expect(coordinator.state.status, RecordingCardAutoSyncStatus.completed);
      expect(actions.downloadLog, <String>['file-0']);
    },
  );

  for (final failurePhase in <String>['plan', 'commit']) {
    test(
      '$failurePhase persistence failure resumes current facts without duplicate download',
      () async {
        var failWrites = true;
        var failureCount = 0;
        final worker = _ControlledLedgerWriteWorker((mutations) async {
          final matchesPhase = mutations.any(
            (mutation) => failurePhase == 'plan'
                ? (mutation.value?['local_state'] == 'queued')
                : (mutation.value?['last_successful_auto_sync_at'] != null),
          );
          if (failWrites && matchesPhase) {
            failureCount += 1;
            throw StateError('disk temporarily unavailable');
          }
        });
        final database = AppDatabase(
          writeWorker: worker,
          writeQueue: DatabaseWriteQueue(),
        );
        final store = RecordingCardAutoSyncStore(
          database: database,
          accountScope: 'recover-$failurePhase',
        );
        final actions = _FakeActions(
          snapshot: _connectedSnapshot(fileCount: 1),
        );
        final coordinator = RecordingCardAutoSyncCoordinator(
          persistence: store,
          actions: actions,
        );
        addTearDown(coordinator.dispose);
        await _waitFor(
          () =>
              coordinator.syncSession.waitingReason ==
              RecordingCardSyncWaitingReason.persistenceRequired,
        );
        expect(failureCount, greaterThan(0));
        expect(
          coordinator.connectedCardCheckpoint?.lastSuccessfulAutoSyncAt,
          isNull,
        );
        expect(actions.downloadLog.length, failurePhase == 'plan' ? 0 : 1);
        if (failurePhase == 'commit') {
          expect(
            coordinator.connectedCardLedger.single.localState,
            RecordingCardFileLocalState.synced,
          );
        }
        failWrites = false;
        coordinator.notifyPersistenceRestored();
        await _waitFor(
          () =>
              coordinator.syncSession.status ==
              RecordingCardSyncSessionStatus.completed,
        );
        expect(
          coordinator.connectedCardCheckpoint?.lastSuccessfulAutoSyncAt,
          isNotNull,
        );
        expect(actions.downloadLog, <String>['file-0']);
        expect(
          worker.records.values.any(
            (record) => record['local_state'] == 'synced',
          ),
          isTrue,
        );
        expect(
          worker.records.values.any(
            (record) => record['last_successful_auto_sync_at'] != null,
          ),
          isTrue,
        );
      },
    );
  }

  test('explicit retry probes a latched initial network wait once', () async {
    final store = RecordingCardAutoSyncStore(
      database: AppDatabase(),
      accountScope: 'account-network-scan-wait',
    );
    final actions = _FakeActions(
      snapshot: _connectedSnapshot(fileCount: 1),
      scanFailuresByCall: <int, AppFailure>{
        1: _prerequisiteFailure(
          'NETWORK_UNAVAILABLE',
          AppFailureCategory.network,
        ),
      },
    );
    final coordinator = RecordingCardAutoSyncCoordinator(
      persistence: store,
      actions: actions,
    );
    addTearDown(coordinator.dispose);
    final digest = RecordingCardFileIdentity.digestSerialNumber('CARD-000001')!;

    await _waitFor(
      () =>
          coordinator.state.waitingReason ==
          RecordingCardSyncWaitingReason.networkRequired,
    );

    expect(coordinator.state.status, isNot(RecordingCardAutoSyncStatus.failed));
    expect(coordinator.state.lastErrorCode, isNull);
    expect(
      coordinator.syncSession.status,
      RecordingCardSyncSessionStatus.waiting,
    );
    expect(store.loadSyncCheckpoint(digest), isNull);
    coordinator.notifyPermissionRestored();
    actions.publishSuccessfulDirectoryRefresh();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(actions.scanCalls, 1);

    coordinator.retry();
    await _waitFor(
      () => store.loadSyncCheckpoint(digest)?.lastSuccessfulAutoSyncAt != null,
    );
    expect(actions.downloadLog, <String>['file-0']);
  });

  test(
    'hardware disconnect overrides a prerequisite wait and reconnects',
    () async {
      final store = RecordingCardAutoSyncStore(
        database: AppDatabase(),
        accountScope: 'account-network-disconnect-priority',
      );
      final actions = _FakeActions(
        snapshot: _connectedSnapshot(fileCount: 1),
        scanFailuresByCall: <int, AppFailure>{
          1: _prerequisiteFailure(
            'NETWORK_UNAVAILABLE',
            AppFailureCategory.network,
          ),
        },
      );
      final coordinator = RecordingCardAutoSyncCoordinator(
        persistence: store,
        actions: actions,
      );
      addTearDown(coordinator.dispose);

      await _waitFor(
        () =>
            coordinator.state.waitingReason ==
            RecordingCardSyncWaitingReason.networkRequired,
      );

      actions.setConnected(false);
      await _waitFor(
        () =>
            coordinator.syncSession.waitingReason ==
            RecordingCardSyncWaitingReason.deviceDisconnected,
      );
      expect(
        coordinator.state.status,
        RecordingCardAutoSyncStatus.waitingForDevice,
      );

      actions.setConnected(true);
      await _waitFor(() => coordinator.state.completedCount == 1);
      expect(actions.downloadLog, <String>['file-0']);
    },
  );

  test(
    'app resume probes a latched confirmation permission wait once',
    () async {
      final store = RecordingCardAutoSyncStore(
        database: AppDatabase(),
        accountScope: 'account-permission-preflight-wait',
      );
      final actions = _FakeActions(
        snapshot: _connectedSnapshot(fileCount: 1),
        scanFailuresByCall: <int, AppFailure>{
          2: _prerequisiteFailure(
            'RECORDING_CARD_BLUETOOTH_PERMISSION_REQUIRED',
            AppFailureCategory.permission,
          ),
        },
      );
      final coordinator = RecordingCardAutoSyncCoordinator(
        persistence: store,
        actions: actions,
      );
      addTearDown(coordinator.dispose);
      final digest = RecordingCardFileIdentity.digestSerialNumber(
        'CARD-000001',
      )!;

      await _waitFor(
        () =>
            coordinator.state.waitingReason ==
            RecordingCardSyncWaitingReason.permissionRequired,
      );

      expect(coordinator.state.lastErrorCode, isNull);
      expect(store.loadSyncCheckpoint(digest), isNull);
      coordinator.notifyNetworkRestored();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(actions.scanCalls, 2);

      coordinator.resume();
      await _waitFor(
        () =>
            store.loadSyncCheckpoint(digest)?.lastSuccessfulAutoSyncAt != null,
      );
      expect(actions.downloadLog, <String>['file-0']);
    },
  );

  test(
    'storage wait during download preserves task and ledger attempt budget',
    () async {
      final store = RecordingCardAutoSyncStore(
        database: AppDatabase(),
        accountScope: 'account-storage-download-wait',
      );
      final actions = _FakeActions(
        snapshot: _connectedSnapshot(fileCount: 1),
        firstDownloadFailure: _prerequisiteFailure(
          'RECORDING_CARD_LOCAL_STORAGE_FAILED',
          AppFailureCategory.compatibility,
        ),
      );
      final coordinator = RecordingCardAutoSyncCoordinator(
        persistence: store,
        actions: actions,
      );
      addTearDown(coordinator.dispose);
      final digest = RecordingCardFileIdentity.digestSerialNumber(
        'CARD-000001',
      )!;

      await _waitFor(
        () =>
            coordinator.state.waitingReason ==
            RecordingCardSyncWaitingReason.storageInsufficient,
      );

      expect(
        coordinator.state.tasks.single.state,
        RecordingCardAutoSyncTaskState.queued,
      );
      expect(coordinator.state.tasks.single.attemptCount, 0);
      expect(
        store.loadFileLedger(digest).single.localState,
        RecordingCardFileLocalState.queued,
      );
      expect(store.loadFileLedger(digest).single.attemptCount, 0);
      expect(
        store.loadSyncCheckpoint(digest)?.lastSuccessfulAutoSyncAt,
        isNull,
      );
      coordinator.notifyPermissionRestored();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(actions.downloadLog, <String>['file-0']);

      await coordinator.setAutoSyncEnabled(false);
      await coordinator.setAutoSyncEnabled(true);
      await _waitFor(
        () =>
            store.loadSyncCheckpoint(digest)?.lastSuccessfulAutoSyncAt != null,
      );
      expect(actions.downloadLog, <String>['file-0', 'file-0']);
    },
  );

  test(
    'verification network wait retains frozen plan until restored',
    () async {
      final store = RecordingCardAutoSyncStore(
        database: AppDatabase(),
        accountScope: 'account-network-verification-wait',
      );
      final actions = _FakeActions(
        snapshot: _connectedSnapshot(fileCount: 1),
        scanFailuresByCall: <int, AppFailure>{
          3: _prerequisiteFailure(
            'RECORDING_CARD_WIFI_NETWORK_UNAVAILABLE',
            AppFailureCategory.compatibility,
          ),
        },
      );
      final coordinator = RecordingCardAutoSyncCoordinator(
        persistence: store,
        actions: actions,
      );
      addTearDown(coordinator.dispose);
      final digest = RecordingCardFileIdentity.digestSerialNumber(
        'CARD-000001',
      )!;

      await _waitFor(
        () =>
            coordinator.state.waitingReason ==
            RecordingCardSyncWaitingReason.networkRequired,
      );

      expect(actions.downloadLog, <String>['file-0']);
      expect(
        coordinator.state.tasks.single.state,
        RecordingCardAutoSyncTaskState.completed,
      );
      expect(
        store.loadFileLedger(digest).single.localState,
        RecordingCardFileLocalState.synced,
      );
      expect(
        store.loadSyncCheckpoint(digest)?.lastSuccessfulAutoSyncAt,
        isNull,
      );
      coordinator.notifyStorageRestored();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(actions.scanCalls, 3);

      coordinator.notifyNetworkRestored();
      await _waitFor(
        () =>
            store.loadSyncCheckpoint(digest)?.lastSuccessfulAutoSyncAt != null,
      );
      expect(actions.downloadLog, <String>['file-0']);
    },
  );

  test('frozen wait plan is replaced when the directory changes', () async {
    final store = RecordingCardAutoSyncStore(
      database: AppDatabase(),
      accountScope: 'account-network-wait-directory-change',
    );
    final actions = _FakeActions(
      snapshot: _connectedSnapshot(fileCount: 1),
      scanFailuresByCall: <int, AppFailure>{
        3: _prerequisiteFailure(
          'NETWORK_UNAVAILABLE',
          AppFailureCategory.network,
        ),
      },
    );
    final coordinator = RecordingCardAutoSyncCoordinator(
      persistence: store,
      actions: actions,
    );
    addTearDown(coordinator.dispose);
    final digest = RecordingCardFileIdentity.digestSerialNumber('CARD-000001')!;

    await _waitFor(
      () =>
          coordinator.state.waitingReason ==
          RecordingCardSyncWaitingReason.networkRequired,
    );
    actions.addFile(1);

    coordinator.notifyNetworkRestored();
    await _waitFor(
      () => store.loadSyncCheckpoint(digest)?.lastSuccessfulAutoSyncAt != null,
    );

    expect(actions.downloadLog, <String>['file-0', 'file-1']);
    expect(
      store.loadFileLedger(digest).map((entry) => entry.localState),
      everyElement(RecordingCardFileLocalState.synced),
    );
  });

  test('ledger persists a hash learned during verified download', () async {
    const verifiedHash =
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    final store = RecordingCardAutoSyncStore(
      database: AppDatabase(),
      accountScope: 'account-verified-download-hash',
    );
    final actions = _FakeActions(
      snapshot: _connectedSnapshot(fileCount: 1),
      verifiedDownloadHash: verifiedHash,
    );
    final coordinator = RecordingCardAutoSyncCoordinator(
      persistence: store,
      actions: actions,
    );
    addTearDown(coordinator.dispose);
    final digest = RecordingCardFileIdentity.digestSerialNumber('CARD-000001')!;

    await _waitFor(
      () => store.loadFileLedger(digest).firstOrNull?.contentHash != null,
    );

    expect(store.loadFileLedger(digest).single.contentHash, verifiedHash);
  });

  test('changed source metadata replans before transfer', () async {
    final store = RecordingCardAutoSyncStore(
      database: AppDatabase(),
      accountScope: 'account-source-signature-race',
    );
    final original = _file(0);
    final changed = RecordingCardScannedFile(
      deviceFileId: original.deviceFileId,
      localFileKey: original.localFileKey,
      deviceFilename: 'REPLACED.WAV',
      sizeBytes: original.sizeBytes! + 64,
      recordedAt: DateTime.utc(2026, 9, 4, 10),
      format: original.format,
      mimeType: original.mimeType,
    );
    final actions = _FakeActions(
      snapshot: _connectedSnapshot(fileCount: 1),
      replaceFileAfterFirstForcedScan: changed,
    );
    final coordinator = RecordingCardAutoSyncCoordinator(
      persistence: store,
      actions: actions,
    );
    addTearDown(coordinator.dispose);
    final digest = RecordingCardFileIdentity.digestSerialNumber('CARD-000001')!;
    final originalSignature = RecordingCardFileIdentity.sourceSignatureFor(
      cardSnDigest: digest,
      deviceFileId: original.deviceFileId,
      deviceFilename: original.deviceFilename,
      sizeBytes: original.sizeBytes,
      recordedAt: original.recordedAt,
    );
    final changedSignature = RecordingCardFileIdentity.sourceSignatureFor(
      cardSnDigest: digest,
      deviceFileId: changed.deviceFileId,
      deviceFilename: changed.deviceFilename,
      sizeBytes: changed.sizeBytes,
      recordedAt: changed.recordedAt,
    );

    await _waitFor(
      () => store.loadSyncCheckpoint(digest)?.lastSuccessfulAutoSyncAt != null,
    );

    final bySignature = <String, RecordingCardFileLedgerEntry>{
      for (final entry in store.loadFileLedger(digest))
        entry.sourceSignature: entry,
    };
    expect(actions.downloadLog, <String>['file-0']);
    expect(
      bySignature[originalSignature]?.localState,
      isNot(RecordingCardFileLocalState.synced),
    );
    expect(
      bySignature[changedSignature]?.localState,
      RecordingCardFileLocalState.synced,
    );
  });

  test('local deletion remains latched across an automatic refresh', () async {
    final store = RecordingCardAutoSyncStore(
      database: AppDatabase(),
      accountScope: 'account-local-delete-no-return',
    );
    final actions = _FakeActions(snapshot: _connectedSnapshot(fileCount: 1));
    final coordinator = RecordingCardAutoSyncCoordinator(
      persistence: store,
      actions: actions,
    );
    addTearDown(coordinator.dispose);
    final digest = RecordingCardFileIdentity.digestSerialNumber('CARD-000001')!;
    await _waitFor(
      () =>
          store.loadFileLedger(digest).firstOrNull?.localState ==
          RecordingCardFileLocalState.synced,
    );
    final entry = store.loadFileLedger(digest).single;
    store.beginLocalDeletion(
      cardSnDigest: digest,
      sourceSignature: entry.sourceSignature,
      at: DateTime.utc(2026, 9, 4, 11),
    );
    store.finishLocalDeletion(
      cardSnDigest: digest,
      sourceSignature: entry.sourceSignature,
      at: DateTime.utc(2026, 9, 4, 11, 1),
    );
    final scansBeforeRefresh = actions.scanCalls;

    actions.markFileProjection(0, RecordingCardFileSyncState.deviceOnly);
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(actions.downloadLog, <String>['file-0']);
    expect(actions.scanCalls, scansBeforeRefresh);
    expect(
      store.loadFileLedger(digest).single.localState,
      RecordingCardFileLocalState.localDeleted,
    );
  });

  test(
    'disconnect restores an active row and reconnect resumes remaining work',
    () async {
      final downloadGate = Completer<void>();
      final store = RecordingCardAutoSyncStore(
        database: AppDatabase(),
        accountScope: 'account-disconnect-resume-ledger',
      );
      final actions = _FakeActions(
        snapshot: _connectedSnapshot(fileCount: 2),
        downloadGate: downloadGate,
      );
      final coordinator = RecordingCardAutoSyncCoordinator(
        persistence: store,
        actions: actions,
      );
      addTearDown(coordinator.dispose);
      final digest = RecordingCardFileIdentity.digestSerialNumber(
        'CARD-000001',
      )!;
      await _waitFor(() => actions.downloadLog.isNotEmpty);

      actions.setConnected(false);
      await _waitFor(
        () => store
            .loadFileLedger(digest)
            .any(
              (entry) => entry.localState == RecordingCardFileLocalState.queued,
            ),
      );
      expect(
        store.loadSyncCheckpoint(digest)?.lastSuccessfulAutoSyncAt,
        isNull,
      );
      expect(
        coordinator.state.tasks.where(
          (task) =>
              task.cardSnDigest == digest &&
              task.state == RecordingCardAutoSyncTaskState.queued,
        ),
        isNotEmpty,
      );
      expect(coordinator.state.tasks.first.attemptCount, 0);
      expect(
        coordinator.syncSession.waitingReason,
        RecordingCardSyncWaitingReason.deviceDisconnected,
      );
      expect(
        coordinator.state.status,
        RecordingCardAutoSyncStatus.waitingForDevice,
      );
      downloadGate.complete();
      await _waitFor(
        () =>
            store
                .loadFileLedger(digest)
                .where(
                  (entry) =>
                      entry.localState == RecordingCardFileLocalState.synced,
                )
                .length ==
            1,
      );
      expect(actions.snapshot.deviceState.isOperationallyConnected, isFalse);
      expect(
        store.loadFileLedger(digest).map((entry) => entry.localState),
        containsAll(<RecordingCardFileLocalState>[
          RecordingCardFileLocalState.synced,
          RecordingCardFileLocalState.queued,
        ]),
      );
      expect(coordinator.state.fileSyncCompletedCount, 1);

      actions.setConnected(true);
      await _waitFor(
        () =>
            store.loadSyncCheckpoint(digest)?.lastSuccessfulAutoSyncAt != null,
      );

      expect(actions.downloadLog, <String>['file-0', 'file-1']);
      expect(
        store.loadFileLedger(digest).map((entry) => entry.localState),
        everyElement(RecordingCardFileLocalState.synced),
      );
    },
  );

  test(
    'native disconnect error defers before the disconnected snapshot arrives',
    () async {
      final store = RecordingCardAutoSyncStore(
        database: AppDatabase(),
        accountScope: 'account-disconnect-error-before-event',
      );
      final actions = _FakeActions(
        snapshot: _connectedSnapshot(fileCount: 1),
        firstDownloadFailure: _prerequisiteFailure(
          'RECORDING_CARD_DISCONNECTED',
          AppFailureCategory.compatibility,
        ),
      );
      final coordinator = RecordingCardAutoSyncCoordinator(
        persistence: store,
        actions: actions,
      );
      addTearDown(coordinator.dispose);
      final digest = RecordingCardFileIdentity.digestSerialNumber(
        'CARD-000001',
      )!;

      await _waitFor(
        () =>
            coordinator.syncSession.waitingReason ==
            RecordingCardSyncWaitingReason.deviceDisconnected,
      );

      expect(actions.snapshot.deviceState.isOperationallyConnected, isTrue);
      expect(
        coordinator.state.status,
        RecordingCardAutoSyncStatus.waitingForDevice,
      );
      expect(
        coordinator.state.tasks.single.state,
        RecordingCardAutoSyncTaskState.queued,
      );
      expect(coordinator.state.tasks.single.attemptCount, 0);
      expect(
        store.loadFileLedger(digest).single.localState,
        RecordingCardFileLocalState.queued,
      );
      expect(store.loadFileLedger(digest).single.attemptCount, 0);
      expect(actions.downloadLog, <String>['file-0']);

      actions.setConnected(false);
      await _waitFor(
        () =>
            coordinator.state.status ==
            RecordingCardAutoSyncStatus.waitingForDevice,
      );
      actions.setConnected(true);
      await _waitFor(
        () =>
            store.loadSyncCheckpoint(digest)?.lastSuccessfulAutoSyncAt != null,
      );

      expect(actions.downloadLog, <String>['file-0', 'file-0']);
      expect(
        store.loadFileLedger(digest).single.localState,
        RecordingCardFileLocalState.synced,
      );
    },
  );

  test(
    'transient failures retry three times without blocking another file',
    () async {
      final store = RecordingCardAutoSyncStore(
        database: AppDatabase(),
        accountScope: 'account-transient-retry-budget',
      );
      final actions = _FakeActions(
        snapshot: _connectedSnapshot(fileCount: 2),
        downloadFailures: <String, int>{'file-0': 2},
      );
      final coordinator = RecordingCardAutoSyncCoordinator(
        persistence: store,
        actions: actions,
        retryPolicy: const RecordingCardSyncRetryPolicy(
          baseDelay: Duration.zero,
          maximumDelay: Duration.zero,
        ),
        retryDelay: (_) async {},
      );
      addTearDown(coordinator.dispose);
      final digest = RecordingCardFileIdentity.digestSerialNumber(
        'CARD-000001',
      )!;

      await _waitFor(
        () =>
            store.loadSyncCheckpoint(digest)?.lastSuccessfulAutoSyncAt != null,
      );

      expect(actions.downloadLog, <String>[
        'file-0',
        'file-1',
        'file-0',
        'file-0',
      ]);
      expect(
        store.loadFileLedger(digest).map((entry) => entry.localState),
        everyElement(RecordingCardFileLocalState.synced),
      );
    },
  );

  test('permanent failure runs once and prevents checkpoint commit', () async {
    final store = RecordingCardAutoSyncStore(
      database: AppDatabase(),
      accountScope: 'account-permanent-failure',
    );
    final actions = _FakeActions(
      snapshot: _connectedSnapshot(fileCount: 2),
      downloadFailures: <String, int>{'file-0': 4},
      downloadFailureRetryable: false,
    );
    final coordinator = RecordingCardAutoSyncCoordinator(
      persistence: store,
      actions: actions,
    );
    addTearDown(coordinator.dispose);
    final digest = RecordingCardFileIdentity.digestSerialNumber('CARD-000001')!;

    await _waitFor(
      () => coordinator.state.status == RecordingCardAutoSyncStatus.failed,
    );

    expect(actions.downloadLog, <String>['file-0', 'file-1']);
    final byId = <String, RecordingCardFileLedgerEntry>{
      for (final entry in store.loadFileLedger(digest))
        entry.deviceFileId: entry,
    };
    expect(byId['file-0']?.localState, RecordingCardFileLocalState.failed);
    expect(
      byId['file-0']?.retryability,
      RecordingCardSyncRetryability.permanent,
    );
    expect(byId['file-1']?.localState, RecordingCardFileLocalState.synced);
    expect(store.loadSyncCheckpoint(digest)?.lastSuccessfulAutoSyncAt, isNull);
  });

  test('scheduled retry is waiting rather than an active transfer', () async {
    final retryGate = Completer<void>();
    final store = RecordingCardAutoSyncStore(
      database: AppDatabase(),
      accountScope: 'retry-wait-boundary',
    );
    final actions = _FakeActions(
      snapshot: _connectedSnapshot(fileCount: 1),
      downloadFailures: <String, int>{'file-0': 1},
    );
    final coordinator = RecordingCardAutoSyncCoordinator(
      persistence: store,
      actions: actions,
      retryDelay: (_) => retryGate.future,
    );
    addTearDown(coordinator.dispose);
    await _waitFor(
      () =>
          coordinator.state.status ==
          RecordingCardAutoSyncStatus.waitingForRetry,
    );
    expect(
      coordinator.syncSession.status,
      RecordingCardSyncSessionStatus.waiting,
    );
    expect(
      coordinator.syncSession.waitingReason,
      RecordingCardSyncWaitingReason.retryBackoff,
    );
    expect(coordinator.state.activeTaskId, isNull);
    expect(actions.downloadLog, <String>['file-0']);
    retryGate.complete();
    await _waitFor(
      () =>
          coordinator.syncSession.status ==
          RecordingCardSyncSessionStatus.completed,
    );
    expect(actions.downloadLog, <String>['file-0', 'file-0']);
  });

  test(
    'serial change settles the completed old file but not its plan',
    () async {
      final store = RecordingCardAutoSyncStore(
        database: AppDatabase(),
        accountScope: 'account-card-identity-change',
      );
      final actions = _FakeActions(
        snapshot: _connectedSnapshot(fileCount: 2),
        switchSerialAfterFirstSuccess: 'CARD-000002',
      );
      final coordinator = RecordingCardAutoSyncCoordinator(
        persistence: store,
        actions: actions,
      );
      addTearDown(coordinator.dispose);
      final oldDigest = RecordingCardFileIdentity.digestSerialNumber(
        'CARD-000001',
      )!;
      final newDigest = RecordingCardFileIdentity.digestSerialNumber(
        'CARD-000002',
      )!;

      await _waitFor(
        () =>
            store.loadSyncCheckpoint(newDigest)?.lastSuccessfulAutoSyncAt !=
            null,
      );

      expect(actions.downloadContexts.first, (
        serialNumber: 'CARD-000001',
        fileId: 'file-0',
      ));
      expect(
        actions.downloadContexts
            .where((context) => context.serialNumber == 'CARD-000001')
            .map((context) => context.fileId),
        <String>['file-0'],
      );
      expect(
        store.loadSyncCheckpoint(oldDigest)?.lastSuccessfulAutoSyncAt,
        isNull,
      );
      expect(
        store
            .loadFileLedger(oldDigest)
            .where(
              (entry) => entry.localState == RecordingCardFileLocalState.synced,
            )
            .length,
        1,
      );
      expect(
        store
            .loadFileLedger(oldDigest)
            .where(
              (entry) => entry.localState == RecordingCardFileLocalState.queued,
            )
            .length,
        1,
      );
    },
  );

  test(
    'automatic transcription applies only to newly downloaded files',
    () async {
      final persistence = _MemoryPersistence(
        preferences: const RecordingCardAutoSyncPreferences(
          autoTranscriptionEnabled: true,
        ),
      );
      final actions = _FakeActions(snapshot: _connectedSnapshot(fileCount: 1));
      final transcription = _FakeTranscriptionPort();
      final coordinator = RecordingCardAutoSyncCoordinator(
        persistence: persistence,
        actions: actions,
        transcriptionPort: transcription,
      );
      addTearDown(coordinator.dispose);

      await _waitFor(() => coordinator.state.completedCount == 1);
      expect(transcription.ids, <String>['local-file-0']);

      coordinator.setAutoTranscriptionEnabled(false);
      actions.addFile(1);
      actions.publishSuccessfulDirectoryRefresh();
      await _waitFor(() => coordinator.state.completedCount == 2);
      expect(transcription.ids, <String>['local-file-0']);
    },
  );

  test('transcription failure stays persisted until explicit retry', () async {
    final persistence = _MemoryPersistence(
      preferences: const RecordingCardAutoSyncPreferences(
        autoTranscriptionEnabled: true,
      ),
    );
    final actions = _FakeActions(snapshot: _connectedSnapshot(fileCount: 1));
    final transcription = _RetryableTranscriptionPort();
    final coordinator = RecordingCardAutoSyncCoordinator(
      persistence: persistence,
      actions: actions,
      transcriptionPort: transcription,
    );
    addTearDown(coordinator.dispose);

    await _waitFor(
      () => coordinator.state.status == RecordingCardAutoSyncStatus.failed,
    );
    expect(transcription.calls, 1);
    expect(
      persistence.tasks.values.single.state,
      RecordingCardAutoSyncTaskState.failed,
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(transcription.calls, 1);

    coordinator.retry();
    await _waitFor(() => coordinator.state.completedCount == 1);

    expect(transcription.calls, 2);
    expect(actions.downloadLog, <String>['file-0']);
  });

  test(
    'long transcription is detached from the shared orchestrator run',
    () async {
      final orchestrator = TaskOrchestrator();
      addTearDown(orchestrator.dispose);
      final persistence = _MemoryPersistence(
        preferences: const RecordingCardAutoSyncPreferences(
          autoTranscriptionEnabled: true,
        ),
      );
      final actions = _FakeActions(snapshot: _connectedSnapshot(fileCount: 1));
      final transcription = _ControlledTranscriptionPort();
      final coordinator = RecordingCardAutoSyncCoordinator(
        persistence: persistence,
        actions: actions,
        transcriptionPort: transcription,
        taskOrchestrator: orchestrator,
      );
      addTearDown(coordinator.dispose);

      await _waitFor(
        () =>
            coordinator.state.status ==
            RecordingCardAutoSyncStatus.transcribing,
      );
      expect(coordinator.state.completedCount, 0);
      expect(coordinator.state.pendingFileSyncCount, 0);
      expect(persistence.tasks.values.single.transcriptionRequested, isTrue);
      expect(
        persistence.tasks.values.single.state,
        RecordingCardAutoSyncTaskState.transcribing,
      );
      await _waitFor(
        () =>
            orchestrator
                    .projectionFor(
                      RecordingCardAutoSyncCoordinator.autoSyncTaskKey,
                    )
                    ?.state
                is AppTaskSucceeded,
      );
      expect(transcription.ids, <String>['local-file-0']);

      actions.setConnected(false);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(transcription.ids, <String>['local-file-0']);
      expect(
        coordinator.state.status,
        RecordingCardAutoSyncStatus.transcribing,
      );

      transcription.completeSuccess();
      await _waitFor(() => coordinator.state.completedCount == 1);
      expect(coordinator.state.status, RecordingCardAutoSyncStatus.completed);
    },
  );

  test(
    'transcription batch settles only after every detached operation ends',
    () async {
      final persistence = _MemoryPersistence();
      final first = _restoredTranscriptionTask();
      final second = _restoredTranscriptionTask(1);
      persistence.tasks[first.taskId] = first;
      persistence.tasks[second.taskId] = second;
      final transcription = _MultiControlledTranscriptionPort();
      final coordinator = RecordingCardAutoSyncCoordinator(
        persistence: persistence,
        actions: _FakeActions(snapshot: RecordingCardRuntimeSnapshot.initial()),
        transcriptionPort: transcription,
      );
      addTearDown(coordinator.dispose);

      await _waitFor(() => transcription.ids.length == 2);
      expect(
        coordinator.state.status,
        RecordingCardAutoSyncStatus.transcribing,
      );

      transcription.completeFailure('local-file-0');
      await _waitFor(
        () =>
            persistence.tasks[first.taskId]?.state ==
            RecordingCardAutoSyncTaskState.failed,
      );

      expect(
        coordinator.state.status,
        RecordingCardAutoSyncStatus.transcribing,
      );
      expect(
        persistence.tasks[second.taskId]?.state,
        RecordingCardAutoSyncTaskState.transcribing,
      );

      transcription.completeSuccess('local-file-1');
      await _waitFor(
        () => coordinator.state.status == RecordingCardAutoSyncStatus.failed,
      );

      expect(
        persistence.tasks[first.taskId]?.state,
        RecordingCardAutoSyncTaskState.failed,
      );
      expect(
        persistence.tasks[second.taskId]?.state,
        RecordingCardAutoSyncTaskState.completed,
      );
    },
  );

  test(
    'restored local transcription runs disconnected and remains deduplicated',
    () async {
      final persistence = _MemoryPersistence();
      final task = _restoredTranscriptionTask();
      persistence.tasks[task.taskId] = task;
      final actions = _FakeActions(
        snapshot: RecordingCardRuntimeSnapshot.initial(),
      );
      final transcription = _ControlledTranscriptionPort();
      final coordinator = RecordingCardAutoSyncCoordinator(
        persistence: persistence,
        actions: actions,
        transcriptionPort: transcription,
      );
      addTearDown(coordinator.dispose);

      await _waitFor(
        () =>
            coordinator.state.status ==
            RecordingCardAutoSyncStatus.transcribing,
      );
      expect(transcription.ids, <String>['local-file-0']);
      expect(actions.scanCalls, 0);
      expect(actions.downloadLog, isEmpty);
      expect(
        persistence.tasks.values.single.state,
        RecordingCardAutoSyncTaskState.transcribing,
      );

      actions.setConnected(false);
      coordinator.resume();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(transcription.ids, <String>['local-file-0']);
      expect(actions.scanCalls, 0);

      transcription.completeSuccess();
      await _waitFor(() => coordinator.state.completedCount == 1);
      expect(coordinator.state.status, RecordingCardAutoSyncStatus.completed);
    },
  );

  test(
    'transcription callback after disposal cannot mutate persistence',
    () async {
      final persistence = _MemoryPersistence();
      final task = _restoredTranscriptionTask();
      persistence.tasks[task.taskId] = task;
      final transcription = _ControlledTranscriptionPort();
      final coordinator = RecordingCardAutoSyncCoordinator(
        persistence: persistence,
        actions: _FakeActions(snapshot: RecordingCardRuntimeSnapshot.initial()),
        transcriptionPort: transcription,
      );
      await _waitFor(
        () =>
            persistence.tasks.values.single.state ==
            RecordingCardAutoSyncTaskState.transcribing,
      );

      coordinator.dispose();
      transcription.completeSuccess();
      await Future<void>.delayed(Duration.zero);

      expect(transcription.cancelCalls, 1);
      expect(
        persistence.tasks.values.single.state,
        RecordingCardAutoSyncTaskState.transcribing,
      );
    },
  );

  test(
    'restored transcription resumes without downloading the file again',
    () async {
      final now = DateTime.utc(2026, 7, 26, 11);
      final persistence = _MemoryPersistence(
        preferences: const RecordingCardAutoSyncPreferences(
          autoTranscriptionEnabled: false,
        ),
      );
      persistence.tasks['recording-card-auto:device-safe:file-0'] =
          RecordingCardAutoSyncTask(
            taskId: 'recording-card-auto:device-safe:file-0',
            deviceFingerprint: 'device-safe',
            deviceFileId: 'file-0',
            deviceFilename: 'REC0.WAV',
            localFileKey: 'local-key-0',
            order: 0,
            state: RecordingCardAutoSyncTaskState.queued,
            attemptCount: 1,
            createdAt: now,
            updatedAt: now,
            localRecordingId: 'local-file-0',
            transcriptionRequested: true,
          );
      final synced = _file(0).copyWith(
        syncState: RecordingCardFileSyncState.synced,
        localFileId: 'local-file-0',
        appPrivateUri: 'app-private://recording-card/local-file-0.wav',
      );
      final actions = _FakeActions(
        snapshot: _connectedSnapshot(
          fileCount: 0,
        ).copyWith(files: <RecordingCardScannedFile>[synced]),
      );
      final transcription = _FakeTranscriptionPort();
      final coordinator = RecordingCardAutoSyncCoordinator(
        persistence: persistence,
        actions: actions,
        transcriptionPort: transcription,
      );
      addTearDown(coordinator.dispose);

      await _waitFor(() => coordinator.state.completedCount == 1);

      expect(actions.downloadLog, isEmpty);
      expect(transcription.ids, <String>['local-file-0']);
    },
  );

  test(
    'automatic transcription waits for real shared processing completion',
    () async {
      final database = AppDatabase();
      final item = _linkedLibraryItem();
      RecordingDao(
        database,
      ).upsertLocalRecording(item.recordingId, item.toRecord());
      final repository = LocalRecordingRepository(
        database: database,
        fileStorage: const UnavailableFileStoragePort(),
      );
      final api = _PollingRecordingApi(const <RecordingDetail>[]);
      final processing = _TrackingProcessingPort();
      final controller = _unusedUploadController(
        database: database,
        repository: repository,
        recordingApi: api,
        processingPort: processing,
      );
      UploadDraftStore(database: database).saveDraft(_processingDraft(item));
      final completion = _ControlledProcessingCompletionPort();
      final port = RecordingUploadAutoTranscriptionPort(
        repository: repository,
        uploadController: controller,
        completionPort: completion,
      );

      final firstFuture = port.transcribe(item.recordingId);
      await _waitFor(() => completion.ids.isNotEmpty);
      var settled = false;
      unawaited(firstFuture.whenComplete(() => settled = true));
      await Future<void>.delayed(Duration.zero);
      expect(settled, isFalse);
      completion.complete(
        const RecordingProcessingCompletion(
          status: RecordingProcessingCompletionStatus.completed,
        ),
      );
      final first = await firstFuture;
      final second = await port.transcribe(item.recordingId);

      expect(first.ok, isTrue);
      expect(second.ok, isTrue);
      expect(processing.tracked, hasLength(1));
      expect(processing.tracked.single.recordingId, 'remote-recording-1');
      expect(processing.tracked.single.stage, UploadDraftStage.asrQueued);
      expect(completion.ids, <String>[
        'remote-recording-1',
        'remote-recording-1',
      ]);
      expect(api.detailCalls, 0);
    },
  );

  test('automatic transcription cancellation releases terminal wait', () async {
    final database = AppDatabase();
    final item = _linkedLibraryItem();
    RecordingDao(
      database,
    ).upsertLocalRecording(item.recordingId, item.toRecord());
    final repository = LocalRecordingRepository(
      database: database,
      fileStorage: const UnavailableFileStoragePort(),
    );
    final processing = _TrackingProcessingPort();
    final controller = _unusedUploadController(
      database: database,
      repository: repository,
      recordingApi: _PollingRecordingApi(const <RecordingDetail>[]),
      processingPort: processing,
    );
    UploadDraftStore(database: database).saveDraft(_processingDraft(item));
    final completion = _ControlledProcessingCompletionPort();
    final port = RecordingUploadAutoTranscriptionPort(
      repository: repository,
      uploadController: controller,
      completionPort: completion,
    );

    final operation = port.startTranscription(item.recordingId);
    await _waitFor(() => completion.ids.isNotEmpty);
    operation.cancel();
    final result = await operation.result;

    expect(result.ok, isFalse);
    expect(result.error?.code, 'RECORDING_CARD_AUTO_TRANSCRIPTION_CANCELLED');
    expect(completion.cancelCalls, 1);
    expect(processing.tracked, hasLength(1));
  });

  test(
    'automatic transcription preserves terminal processing errors',
    () async {
      final database = AppDatabase();
      final item = _linkedLibraryItem();
      RecordingDao(
        database,
      ).upsertLocalRecording(item.recordingId, item.toRecord());
      final repository = LocalRecordingRepository(
        database: database,
        fileStorage: const UnavailableFileStoragePort(),
      );
      final processing = _TrackingProcessingPort();
      final controller = _unusedUploadController(
        database: database,
        repository: repository,
        recordingApi: _PollingRecordingApi(const <RecordingDetail>[]),
        processingPort: processing,
      );
      UploadDraftStore(database: database).saveDraft(_processingDraft(item));
      final completion =
          _SequencedProcessingCompletionPort(<RecordingProcessingCompletion>[
            const RecordingProcessingCompletion(
              status: RecordingProcessingCompletionStatus.failed,
              errorCode: 'ASR_TERMINAL_FAILED',
            ),
            const RecordingProcessingCompletion(
              status: RecordingProcessingCompletionStatus.unavailable,
              errorCode: 'PROCESSING_SCOPE_UNAVAILABLE',
            ),
          ]);
      final port = RecordingUploadAutoTranscriptionPort(
        repository: repository,
        uploadController: controller,
        completionPort: completion,
      );

      final failed = await port.transcribe(item.recordingId);
      final unavailable = await port.transcribe(item.recordingId);

      expect(failed.ok, isFalse);
      expect(failed.error?.code, 'ASR_TERMINAL_FAILED');
      expect(unavailable.ok, isFalse);
      expect(unavailable.error?.code, 'PROCESSING_SCOPE_UNAVAILABLE');
      expect(processing.tracked, hasLength(1));
    },
  );

  test(
    'automatic transcription reports a missing linked checkpoint clearly',
    () async {
      final database = AppDatabase();
      final item = _linkedLibraryItem();
      RecordingDao(
        database,
      ).upsertLocalRecording(item.recordingId, item.toRecord());
      final repository = LocalRecordingRepository(
        database: database,
        fileStorage: const UnavailableFileStoragePort(),
      );
      final api = _PollingRecordingApi(const <RecordingDetail>[]);
      final processing = _TrackingProcessingPort();
      final port = RecordingUploadAutoTranscriptionPort(
        repository: repository,
        uploadController: _unusedUploadController(
          database: database,
          repository: repository,
          recordingApi: api,
          processingPort: processing,
        ),
        completionPort: _SequencedProcessingCompletionPort(
          const <RecordingProcessingCompletion>[],
        ),
      );

      final result = await port.transcribe(item.recordingId);

      expect(result.ok, isFalse);
      expect(result.error?.code, 'RECORDING_PROCESSING_CHECKPOINT_MISSING');
      expect(processing.tracked, isEmpty);
      expect(api.detailCalls, 0);
    },
  );

  test('historical transcription runs only through explicit command', () async {
    final transcription = _FakeTranscriptionPort();
    final coordinator = RecordingCardAutoSyncCoordinator(
      persistence: _MemoryPersistence(),
      actions: _FakeActions(snapshot: RecordingCardRuntimeSnapshot.initial()),
      transcriptionPort: transcription,
    );
    addTearDown(coordinator.dispose);
    coordinator.setAutoTranscriptionEnabled(true);
    await Future<void>.delayed(Duration.zero);
    expect(transcription.ids, isEmpty);

    final completed = await coordinator
        .backfillHistoricalTranscriptions(<RecordingLibraryItem>[
          _libraryItem('device-1', RecordingLibrarySource.device),
          _libraryItem('local-1', RecordingLibrarySource.localImport),
        ]);

    expect(completed, 1);
    expect(transcription.ids, <String>['device-1']);
  });
}

final class _MemoryPersistence implements RecordingCardAutoSyncPersistencePort {
  _MemoryPersistence({
    this.preferences = const RecordingCardAutoSyncPreferences(),
  });

  RecordingCardAutoSyncPreferences preferences;
  final Map<String, RecordingCardAutoSyncTask> tasks = {};

  @override
  RecordingCardAutoSyncPreferences loadPreferences() => preferences;

  @override
  List<RecordingCardAutoSyncTask> loadTasks() => tasks.values.toList();

  @override
  void savePreferences(RecordingCardAutoSyncPreferences preferences) {
    this.preferences = preferences;
  }

  @override
  void saveTask(RecordingCardAutoSyncTask task) {
    tasks[task.taskId] = task;
  }
}

final class _BackgroundExecution
    implements RecordingCardBackgroundExecutionPort {
  final List<RecordingCardBackgroundExecutionRequest> calls =
      <RecordingCardBackgroundExecutionRequest>[];

  @override
  Future<RecordingCardBackgroundExecutionCapability> update(
    RecordingCardBackgroundExecutionRequest request,
  ) async {
    calls.add(request);
    return RecordingCardBackgroundExecutionCapability(
      mode: RecordingCardBackgroundExecutionMode.processBound,
      enabled: request.enabled,
      restoresAfterProcessDeath: false,
      resumesOnNextAppLaunch: true,
    );
  }
}

final class _FakeActions extends ChangeNotifier
    implements
        RecordingCardAutoSyncActions,
        RecordingCardAutoSyncPauseActions,
        RecordingCardBackgroundTransportActions,
        RecordingCardSuccessfulFileRefreshActions,
        RecordingCardCompletionRefreshLifecycleActions {
  _FakeActions({
    required RecordingCardRuntimeSnapshot snapshot,
    Completer<void>? scanGate,
    Completer<void>? downloadGate,
    Map<String, int> downloadFailures = const <String, int>{},
    Map<int, AppFailure> scanFailuresByCall = const <int, AppFailure>{},
    this.downloadFailureRetryable = true,
    this.firstDownloadFailure,
    this.switchSerialAfterFirstSuccess,
    this.verifiedDownloadHash,
    this.replaceFileAfterFirstForcedScan,
    this.publishSuccessfulRevisionOnScan = false,
    this.pauseReleasesDownload = true,
  }) : _snapshot = snapshot,
       _scanGate = scanGate,
       _downloadGate = downloadGate,
       _downloadFailures = Map<String, int>.of(downloadFailures),
       _scanFailuresByCall = Map<int, AppFailure>.of(scanFailuresByCall);

  RecordingCardRuntimeSnapshot _snapshot;
  final Completer<void>? _scanGate;
  final Completer<void>? _downloadGate;
  final Map<String, int> _downloadFailures;
  final Map<int, AppFailure> _scanFailuresByCall;
  final bool downloadFailureRetryable;
  final AppFailure? firstDownloadFailure;
  final String? switchSerialAfterFirstSuccess;
  final String? verifiedDownloadHash;
  final RecordingCardScannedFile? replaceFileAfterFirstForcedScan;
  final bool publishSuccessfulRevisionOnScan;
  final bool pauseReleasesDownload;
  bool _manualTransfer = false;
  bool _cancelledWifiProjectionRetained = false;
  RecordingCardBackgroundTransferTransport? _activeTransferTransport;
  bool _pauseRequested = false;
  bool _serialSwitched = false;
  int _concurrentDownloads = 0;
  int maxConcurrentDownloads = 0;
  int scanCalls = 0;
  int _successfulFileRefreshRevision = 0;
  bool _completionRefreshPending = false;
  String? _completionRefreshFailureCode;
  bool _firstDownloadFailureConsumed = false;
  int pauseCalls = 0;
  final List<String> downloadLog = [];
  final List<({String? serialNumber, String fileId})> downloadContexts = [];
  final List<bool> forceRefreshLog = [];

  @override
  RecordingCardRuntimeSnapshot get snapshot => _snapshot;

  @override
  bool get hasActiveTransfer => _manualTransfer;

  bool get cancelledWifiProjectionRetained => _cancelledWifiProjectionRetained;

  @override
  RecordingCardBackgroundTransferTransport? get activeTransferTransport =>
      _activeTransferTransport;

  @override
  int get successfulFileRefreshRevision => _successfulFileRefreshRevision;

  @override
  bool get hasPendingRecordingCompletionRefresh => _completionRefreshPending;

  @override
  String? get fileCatalogFailureCode => _completionRefreshFailureCode;

  @override
  Future<RecordingCardResult<List<RecordingCardScannedFile>>>
  loadConnectionFiles({bool forceRefresh = false}) async {
    scanCalls += 1;
    forceRefreshLog.add(forceRefresh);
    final failure = _scanFailuresByCall[scanCalls];
    if (failure != null) {
      return RecordingCardResult<List<RecordingCardScannedFile>>.failure(
        failure,
      );
    }
    final gate = _scanGate;
    if (gate != null && !gate.isCompleted) await gate.future;
    final files = _snapshot.files;
    final replacement = replaceFileAfterFirstForcedScan;
    if (forceRefresh && scanCalls == 2 && replacement != null) {
      _snapshot = _snapshot.copyWith(
        files: <RecordingCardScannedFile>[
          for (final file in _snapshot.files)
            if (file.deviceFileId == replacement.deviceFileId)
              replacement
            else
              file,
        ],
      );
    }
    if (publishSuccessfulRevisionOnScan) {
      _successfulFileRefreshRevision += 1;
      notifyListeners();
    }
    return RecordingCardResult<List<RecordingCardScannedFile>>.success(files);
  }

  @override
  Future<RecordingCardResult<RecordingCardAutoSyncDownload>> download(
    RecordingCardScannedFile file,
  ) async {
    _concurrentDownloads += 1;
    maxConcurrentDownloads = maxConcurrentDownloads < _concurrentDownloads
        ? _concurrentDownloads
        : maxConcurrentDownloads;
    downloadLog.add(file.deviceFileId);
    downloadContexts.add((
      serialNumber: _snapshot.deviceState.serialNumber,
      fileId: file.deviceFileId,
    ));
    final gate = _downloadGate;
    if (gate != null && !gate.isCompleted) await gate.future;
    await Future<void>.delayed(const Duration(milliseconds: 2));
    _concurrentDownloads -= 1;
    if (!_firstDownloadFailureConsumed && firstDownloadFailure != null) {
      _firstDownloadFailureConsumed = true;
      return RecordingCardResult<RecordingCardAutoSyncDownload>.failure(
        firstDownloadFailure!,
      );
    }
    final failuresRemaining = _downloadFailures[file.deviceFileId] ?? 0;
    if (failuresRemaining > 0) {
      _downloadFailures[file.deviceFileId] = failuresRemaining - 1;
      return RecordingCardResult<RecordingCardAutoSyncDownload>.failure(
        recordingApiFailure(
          'TEST_RECORDING_CARD_DOWNLOAD_FAILED',
          retryable: downloadFailureRetryable,
        ),
      );
    }
    final localId = 'local-${file.deviceFileId}';
    if (_pauseRequested) {
      _pauseRequested = false;
      return RecordingCardResult<RecordingCardAutoSyncDownload>.failure(
        recordingApiFailure(
          'RECORDING_CARD_TRANSFER_CANCELLED',
          retryable: true,
        ),
      );
    }
    _snapshot = _snapshot.copyWith(
      files: <RecordingCardScannedFile>[
        for (final candidate in _snapshot.files)
          if (candidate.deviceFileId == file.deviceFileId)
            candidate.copyWith(
              syncState: RecordingCardFileSyncState.synced,
              localFileId: localId,
              appPrivateUri: 'app-private://recording-card/$localId.wav',
            )
          else
            candidate,
      ],
    );
    final nextSerial = switchSerialAfterFirstSuccess;
    if (!_serialSwitched && nextSerial != null) {
      _serialSwitched = true;
      _snapshot = _snapshot.copyWith(
        deviceState: RecordingCardDeviceState(
          connectionState: RecordingCardConnectionState.connected,
          connectionStage: RecordingCardConnectionStage.connected,
          safeDeviceFingerprint: 'device-safe-$nextSerial',
          serialNumber: nextSerial,
        ),
      );
    }
    notifyListeners();
    return RecordingCardResult<RecordingCardAutoSyncDownload>.success(
      RecordingCardAutoSyncDownload(
        localRecordingId: localId,
        contentHash: verifiedDownloadHash,
      ),
    );
  }

  @override
  Future<void> pauseActiveTransfer() async {
    pauseCalls += 1;
    _pauseRequested = true;
    final gate = _downloadGate;
    if (pauseReleasesDownload && gate != null && !gate.isCompleted) {
      gate.complete();
    }
  }

  void setRecordingState(RecordingCardRecordingState state) {
    _snapshot = _snapshot.copyWith(
      recordingInfo: RecordingCardRecordingInfo(state: state),
    );
    notifyListeners();
  }

  void setCompletionRefreshState({required bool pending, String? failureCode}) {
    _completionRefreshPending = pending;
    _completionRefreshFailureCode = failureCode;
    notifyListeners();
  }

  void setManualTransfer(bool value) {
    _manualTransfer = value;
    notifyListeners();
  }

  void settleManualWifiAsCancelledKeepingProjection() {
    _manualTransfer = false;
    _cancelledWifiProjectionRetained = true;
    notifyListeners();
  }

  void setActiveTransferTransport(
    RecordingCardBackgroundTransferTransport? transport,
  ) {
    _activeTransferTransport = transport;
    notifyListeners();
  }

  void setConnected(bool connected) {
    _snapshot = _snapshot.copyWith(
      deviceState: connected
          ? const RecordingCardDeviceState(
              connectionState: RecordingCardConnectionState.connected,
              connectionStage: RecordingCardConnectionStage.connected,
              safeDeviceFingerprint: 'device-safe',
              serialNumber: 'CARD-000001',
            )
          : RecordingCardDeviceState.disconnected(),
    );
    notifyListeners();
  }

  void addFile(int index) {
    _snapshot = _snapshot.copyWith(
      files: <RecordingCardScannedFile>[..._snapshot.files, _file(index)],
    );
    notifyListeners();
  }

  void publishSuccessfulDirectoryRefresh() {
    _successfulFileRefreshRevision += 1;
    notifyListeners();
  }

  void markFileProjection(int index, RecordingCardFileSyncState syncState) {
    _snapshot = _snapshot.copyWith(
      files: <RecordingCardScannedFile>[
        for (final file in _snapshot.files)
          if (file.deviceFileId == 'file-$index')
            RecordingCardScannedFile(
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
              syncState: syncState,
            )
          else
            file,
      ],
    );
    notifyListeners();
  }
}

AppFailure _prerequisiteFailure(String code, AppFailureCategory category) =>
    AppFailure(
      code: code,
      category: category,
      message: code,
      userMessageKey: 'test.$code',
      isRetryable: true,
    );

final class _FakeTranscriptionPort
    implements RecordingCardAutoTranscriptionPort {
  final List<String> ids = [];

  @override
  Future<RecordingCardResult<bool>> transcribe(String localRecordingId) async {
    ids.add(localRecordingId);
    return RecordingCardResult<bool>.success(true);
  }
}

final class _ControlledTranscriptionPort
    implements RecordingCardAutoTranscriptionOperationPort {
  final Completer<RecordingCardResult<bool>> _completer =
      Completer<RecordingCardResult<bool>>();
  final List<String> ids = <String>[];
  var cancelCalls = 0;

  @override
  Future<RecordingCardResult<bool>> transcribe(String localRecordingId) =>
      startTranscription(localRecordingId).result;

  @override
  RecordingCardAutoTranscriptionOperation startTranscription(
    String localRecordingId,
  ) {
    ids.add(localRecordingId);
    return RecordingCardAutoTranscriptionOperation(
      result: _completer.future,
      onCancel: () {
        cancelCalls += 1;
        if (!_completer.isCompleted) {
          _completer.complete(
            RecordingCardResult<bool>.failure(
              recordingApiFailure('TEST_TRANSCRIPTION_CANCELLED'),
            ),
          );
        }
      },
    );
  }

  void completeSuccess() {
    if (!_completer.isCompleted) {
      _completer.complete(RecordingCardResult<bool>.success(true));
    }
  }
}

final class _MultiControlledTranscriptionPort
    implements RecordingCardAutoTranscriptionOperationPort {
  final Map<String, Completer<RecordingCardResult<bool>>> _completers =
      <String, Completer<RecordingCardResult<bool>>>{};
  final List<String> ids = <String>[];

  @override
  Future<RecordingCardResult<bool>> transcribe(String localRecordingId) =>
      startTranscription(localRecordingId).result;

  @override
  RecordingCardAutoTranscriptionOperation startTranscription(
    String localRecordingId,
  ) {
    ids.add(localRecordingId);
    final completer = Completer<RecordingCardResult<bool>>();
    _completers[localRecordingId] = completer;
    return RecordingCardAutoTranscriptionOperation(
      result: completer.future,
      onCancel: () {
        if (!completer.isCompleted) {
          completer.complete(
            RecordingCardResult<bool>.failure(
              recordingApiFailure('TEST_TRANSCRIPTION_CANCELLED'),
            ),
          );
        }
      },
    );
  }

  void completeSuccess(String localRecordingId) {
    final completer = _completers[localRecordingId];
    if (completer != null && !completer.isCompleted) {
      completer.complete(RecordingCardResult<bool>.success(true));
    }
  }

  void completeFailure(String localRecordingId) {
    final completer = _completers[localRecordingId];
    if (completer != null && !completer.isCompleted) {
      completer.complete(
        RecordingCardResult<bool>.failure(
          recordingApiFailure('TEST_TRANSCRIPTION_FAILED'),
        ),
      );
    }
  }
}

final class _ControlledProcessingCompletionPort
    implements
        RecordingProcessingCompletionPort,
        RecordingProcessingCompletionSubscriptionPort {
  final Completer<RecordingProcessingCompletion> _completer =
      Completer<RecordingProcessingCompletion>();
  final List<String> ids = <String>[];
  var cancelCalls = 0;

  @override
  Future<RecordingProcessingCompletion> waitForTerminal(String recordingId) =>
      observeTerminal(recordingId).completion;

  @override
  RecordingProcessingCompletionSubscription observeTerminal(
    String recordingId,
  ) {
    ids.add(recordingId);
    return RecordingProcessingCompletionSubscription(
      completion: _completer.future,
      onCancel: () {
        cancelCalls += 1;
        if (!_completer.isCompleted) {
          _completer.complete(
            const RecordingProcessingCompletion(
              status: RecordingProcessingCompletionStatus.unavailable,
              errorCode: 'TEST_COMPLETION_CANCELLED',
            ),
          );
        }
      },
    );
  }

  void complete(RecordingProcessingCompletion completion) {
    _completer.complete(completion);
  }
}

final class _SequencedProcessingCompletionPort
    implements RecordingProcessingCompletionPort {
  _SequencedProcessingCompletionPort(
    List<RecordingProcessingCompletion> completions,
  ) : _completions = List<RecordingProcessingCompletion>.of(completions);

  final List<RecordingProcessingCompletion> _completions;

  @override
  Future<RecordingProcessingCompletion> waitForTerminal(
    String recordingId,
  ) async => _completions.removeAt(0);
}

final class _RetryableTranscriptionPort
    implements RecordingCardAutoTranscriptionPort {
  int calls = 0;

  @override
  Future<RecordingCardResult<bool>> transcribe(String localRecordingId) async {
    calls += 1;
    if (calls == 1) {
      return RecordingCardResult<bool>.failure(
        recordingApiFailure(
          'TRANSCRIPTION_BACKEND_UNAVAILABLE',
          retryable: true,
        ),
      );
    }
    return RecordingCardResult<bool>.success(true);
  }
}

RecordingCardRuntimeSnapshot _connectedSnapshot({
  required int fileCount,
  RecordingCardRecordingState recordingState = RecordingCardRecordingState.idle,
}) => RecordingCardRuntimeSnapshot(
  deviceState: const RecordingCardDeviceState(
    connectionState: RecordingCardConnectionState.connected,
    connectionStage: RecordingCardConnectionStage.connected,
    safeDeviceFingerprint: 'device-safe',
    serialNumber: 'CARD-000001',
  ),
  recordingInfo: RecordingCardRecordingInfo(state: recordingState),
  files: <RecordingCardScannedFile>[
    for (var index = 0; index < fileCount; index += 1) _file(index),
  ],
);

RecordingCardAutoSyncTask _restoredTranscriptionTask([int index = 0]) {
  final now = DateTime.utc(2026, 7, 26, 11);
  return RecordingCardAutoSyncTask(
    taskId: 'recording-card-auto:device-safe:file-$index',
    deviceFingerprint: 'device-safe',
    deviceFileId: 'file-$index',
    deviceFilename: 'REC$index.WAV',
    localFileKey: 'local-key-$index',
    order: index,
    state: RecordingCardAutoSyncTaskState.queued,
    attemptCount: 1,
    createdAt: now,
    updatedAt: now,
    localRecordingId: 'local-file-$index',
    transcriptionRequested: true,
  );
}

RecordingCardScannedFile _file(int index) => RecordingCardScannedFile(
  deviceFileId: 'file-$index',
  localFileKey: 'local-key-$index',
  deviceFilename: 'REC$index.WAV',
  sizeBytes: 1024 + index,
  format: RecordingCardFileFormat.wav,
  mimeType: 'audio/wav',
);

RecordingLibraryItem _libraryItem(String id, RecordingLibrarySource source) =>
    RecordingLibraryItem(
      recordingId: id,
      source: source,
      displayName: '$id.wav',
      format: RecordingLibraryFormat.wav,
      localFileState: RecordingLocalFileState.ready,
      status: RecordingLibraryStatus.localOnly,
      durationSeconds: 10,
      sizeBytes: 1024,
      isFavorite: false,
      tagIds: const <String>[],
      createdAt: DateTime.utc(2026, 7, 26),
      updatedAt: DateTime.utc(2026, 7, 26),
    );

RecordingLibraryItem _linkedLibraryItem() => RecordingLibraryItem(
  recordingId: 'local-recording-1',
  source: RecordingLibrarySource.device,
  displayName: 'REC001.WAV',
  format: RecordingLibraryFormat.wav,
  localFileState: RecordingLocalFileState.ready,
  status: RecordingLibraryStatus.localOnly,
  durationSeconds: 42,
  sizeBytes: 4096,
  isFavorite: false,
  tagIds: const <String>['客户访谈'],
  createdAt: DateTime.utc(2026, 7, 26, 8),
  updatedAt: DateTime.utc(2026, 7, 26, 8),
  appPrivateUri: 'app-private://recordings/local-recording-1/source.wav',
  remoteRecordingId: 'remote-recording-1',
);

UploadDraft _processingDraft(
  RecordingLibraryItem item, {
  UploadDraftStage stage = UploadDraftStage.asrQueued,
}) {
  return createInitialUploadDraft(
    draftId: 'draft-${item.recordingId}',
    localRecordingId: item.recordingId,
    appPrivateUri: item.appPrivateUri!,
    fileName: item.displayName,
    mimeType: 'audio/wav',
    sizeBytes: item.sizeBytes,
    durationSeconds: item.durationSeconds,
    sourceScene: 'raw_material',
    recordingSource: 'recording_card',
    updatedAt: DateTime.utc(2026, 7, 26, 12),
    workspaceId: 'workspace-1',
    recordedAt: item.createdAt,
    title: item.displayName,
  ).copyWith(
    stage: stage,
    recordingId: item.remoteRecordingId,
    asrTaskId: 'asr-remote-recording-1',
    updatedAt: DateTime.utc(2026, 7, 26, 12),
  );
}

RecordingUploadController _unusedUploadController({
  required AppDatabase database,
  required LocalRecordingRepository repository,
  required RecordingApiPort recordingApi,
  RecordingProcessingPort? processingPort,
}) {
  final apiClient = ApiClient(
    config: ApiClientConfig(
      baseUrl: Uri.parse('https://api.example.test'),
      clientVersion: 'test',
      deviceId: 'device-1',
      platform: 'ios',
      locale: 'zh-CN',
      getAccessToken: () => 'token',
    ),
    transport: const _NeverApiTransport(),
  );
  return RecordingUploadController(
    uploadClient: UploadClient(
      apiClient: apiClient,
      objectTransport: const _NeverObjectUploadTransport(),
    ),
    draftStore: UploadDraftStore(database: database),
    recordingApi: recordingApi,
    localRecordingRepository: repository,
    activeWorkspaceId: () => 'workspace-1',
    processingPort: processingPort,
  );
}

final class _PollingRecordingApi implements RecordingApiPort {
  _PollingRecordingApi(List<RecordingDetail> details)
    : _details = List<RecordingDetail>.of(details);

  final List<RecordingDetail> _details;
  int detailCalls = 0;

  Never _unexpected() => throw StateError('unexpected recording API call');

  @override
  Future<ApiResult<RecordingDetail>> getRecordingDetail(
    String recordingId,
  ) async {
    detailCalls += 1;
    final detail = _details.length == 1
        ? _details.single
        : _details.removeAt(0);
    return ApiResult<RecordingDetail>.success(
      data: detail,
      status: 200,
      idempotencyStore: SubmissionKeyStore.empty,
    );
  }

  @override
  Future<ApiResult<CreateRecordingResponse>> createRecording(
    CreateRecordingInput input,
  ) async => _unexpected();

  @override
  Future<ApiResult<AsrTaskSnapshot>> getAsrTask(String asrTaskId) async =>
      _unexpected();

  @override
  Future<ApiResult<RetryRecordingResponse>> retryRecording({
    required String recordingId,
    required String stage,
    required String idempotencyKey,
  }) async => _unexpected();

  @override
  Future<ApiResult<AsrTaskSnapshot>> retryAsrTask({
    required String asrTaskId,
    required String idempotencyKey,
  }) async => _unexpected();
}

final class _TrackingProcessingPort implements RecordingProcessingPort {
  final List<UploadDraft> tracked = <UploadDraft>[];

  @override
  Future<void> track(UploadDraft draft) async {
    tracked.add(draft);
  }
}

final class _NeverApiTransport implements ApiTransport {
  const _NeverApiTransport();

  @override
  Future<ApiTransportResponse> send(ApiTransportRequest request) async =>
      throw StateError('unexpected upload API call');
}

final class _NeverObjectUploadTransport implements ObjectUploadTransport {
  const _NeverObjectUploadTransport();

  @override
  Future<ObjectUploadResult> upload(ObjectUploadRequest request) async =>
      throw StateError('unexpected object upload');
}

Future<void> _waitFor(bool Function() predicate) async {
  for (var index = 0; index < 200; index += 1) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  fail('Timed out waiting for asynchronous coordinator state');
}

final class _ControlledLedgerWriteWorker
    implements LocalDatabaseWriteWorkerPort {
  _ControlledLedgerWriteWorker(this.onWrite);
  final Future<void> Function(List<LocalDatabaseMutation>) onWrite;
  final Map<String, LocalDatabaseRecord> records =
      <String, LocalDatabaseRecord>{};

  @override
  bool get isDisposed => false;

  @override
  Future<void> applyRecordMutations({
    required int schemaVersion,
    required Iterable<LocalDatabaseMutation> mutations,
  }) async {
    final batch = mutations.toList(growable: false);
    await onWrite(batch);
    for (final mutation in batch) {
      final key = '${mutation.table.name}:${mutation.key}';
      if (mutation.kind == LocalDatabaseMutationKind.delete) {
        records.remove(key);
      } else {
        records[key] = Map<String, Object?>.of(mutation.value!);
      }
    }
  }

  @override
  Future<void> replaceAllRecords({
    required int schemaVersion,
    required Map<LocalTableName, Map<String, LocalDatabaseRecord>> tables,
  }) async {}
}
