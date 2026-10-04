import 'package:huahuoai_app/app/di/database_providers.dart';
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/app/bootstrap/app_providers.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/database/recording_dao.dart';
import 'package:huahuoai_app/core/native/native_file_port.dart';
import 'package:huahuoai_app/core/native/native_playback_port.dart';
import 'package:huahuoai_app/core/native/platform_permissions_port.dart';
import 'package:huahuoai_app/core/native/recording_card_native_port.dart';
import 'package:huahuoai_app/core/storage/file_storage_port.dart';
import 'package:huahuoai_app/features/recording_card/application/recording_card_auto_sync_coordinator.dart';
import 'package:huahuoai_app/features/recording_card/application/recording_card_controller.dart';
import 'package:huahuoai_app/features/recording_card/data/recording_card_auto_sync_store.dart';
import 'package:huahuoai_app/features/recording_card/domain/recording_card_auto_sync.dart';
import 'package:huahuoai_app/features/recording_card/domain/recording_card_sync_ledger.dart';
import 'package:huahuoai_app/features/recordings/application/recording_library_controller.dart';
import 'package:huahuoai_app/features/recordings/application/recording_library_ui_controller.dart';
import 'package:huahuoai_app/features/recordings/application/recording_playback_controller.dart';
import 'package:huahuoai_app/features/recordings/data/local_playback_position_store.dart';
import 'package:huahuoai_app/features/recordings/data/local_recording_repository.dart';
import 'package:huahuoai_app/features/recordings/data/recording_transcription_receipt_store.dart';
import 'package:huahuoai_app/features/recordings/domain/recording_transcription_receipt.dart';
import 'package:huahuoai_app/features/recordings/domain/recording_library.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_recording_card_files_page.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_recording_library_surfaces.dart';
import 'package:huahuoai_app/shared/theme/huahuo_v3_theme.dart';

import '../../support/figma_golden_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Wi-Fi flow reports durable completion once before dismissal', (
    tester,
  ) async {
    const accountScope = 'wifi-flow-completion-account';
    const contentHash =
        'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
    final cardDigest = RecordingCardFileIdentity.digestSerialNumber(
      'SP63A03003',
    )!;
    final now = DateTime.utc(2026, 9, 9, 8);
    final database = AppDatabase();
    final localItem = RecordingLibraryItem(
      recordingId: 'wifi-flow-local',
      source: RecordingLibrarySource.device,
      displayName: '20260909080000.m4a',
      format: RecordingLibraryFormat.m4a,
      localFileState: RecordingLocalFileState.ready,
      status: RecordingLibraryStatus.localOnly,
      durationSeconds: 60,
      sizeBytes: 4096,
      isFavorite: false,
      tagIds: const <String>[],
      createdAt: now,
      updatedAt: now,
      appPrivateUri: 'app-private://recording-card/wifi-flow-local.m4a',
      deviceFilename: '20260909080000.m4a',
      contentHash: contentHash,
    );
    final recordingDao = RecordingDao(database, userScope: accountScope);
    recordingDao.upsertLocalRecording(
      localItem.recordingId,
      localItem.toRecord(),
    );
    recordingDao.upsertDownloadedManifest(
      deviceFileId: 'wifi-flow-file',
      deviceFingerprint: 'wifi-flow-card',
      deviceFilename: localItem.deviceFilename!,
      localFileId: localItem.recordingId,
      appPrivateUri: localItem.appPrivateUri!,
      expectedSizeBytes: localItem.sizeBytes,
      actualSizeBytes: localItem.sizeBytes,
      durationSeconds: localItem.durationSeconds,
      contentHash: contentHash,
      downloadedAt: now.toIso8601String(),
      updatedAt: now.toIso8601String(),
    );
    final repository = LocalRecordingRepository(
      database: database,
      fileStorage: const _ReadyFileStorage(
        sizeBytes: 4096,
        contentHash: contentHash,
      ),
      accountScope: accountScope,
      requireAuthenticatedAccount: true,
    );
    repository.upsertRecordingCardWifiBatchItem(
      transferId: 'wifi-flow-completed-0',
      batchId: 'wifi-flow-completed',
      deviceFingerprint: 'wifi-flow-card',
      deviceIdentity: 'serial:SP63A03003',
      cardSnDigest: cardDigest,
      deviceFileId: 'wifi-flow-file',
      deviceFilename: localItem.deviceFilename!,
      localFileKey: 'wifi-flow-file-key',
      itemOrder: 0,
      expectedSizeBytes: localItem.sizeBytes,
      attemptCount: 1,
      batchStage: RecordingCardWifiBatchState.completed.name,
      stage: RecordingCardWifiBatchItemState.completed.name,
      idempotencyKey: contentHash,
      localRecordingId: localItem.recordingId,
      fileFormat: RecordingCardFileFormat.m4a.name,
      mimeType: 'audio/mp4',
      durationSeconds: localItem.durationSeconds,
      recordedAt: now,
      contentHash: contentHash,
      createdAt: now,
      updatedAt: now,
    );
    const channel = MethodChannel(
      'recording_card_files_page_wifi_completion_test',
    );
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final events = StreamController<Object?>(sync: true);
    final connectedDevice = <String, Object?>{
      'connectionState': 'ble_ready',
      'connectionStage': 'connected',
      'displayName': '无限花火录音卡',
      'safeDeviceFingerprint': 'wifi-flow-card',
      'serialNumber': 'SP63A03003',
      'wifiSupported': true,
      'recordingFormat': 'm4a',
    };
    final syncedDeviceFile = <String, Object?>{
      'deviceFileId': 'wifi-flow-file',
      'localFileKey': 'wifi-flow-file-key',
      'deviceFilename': localItem.deviceFilename,
      'sizeBytes': localItem.sizeBytes,
      'durationSeconds': localItem.durationSeconds,
      'recordedAt': now.toIso8601String(),
      'contentHash': contentHash,
      'sizeConfidence': 'trusted',
      'format': 'm4a',
      'mimeType': 'audio/mp4',
      'syncState': 'synced',
      'localFileId': localItem.recordingId,
      'appPrivateUri': localItem.appPrivateUri,
    };
    final runtimeSnapshot = <String, Object?>{
      'deviceState': connectedDevice,
      'recordingInfo': <String, Object?>{'state': 'idle'},
      'files': <Object?>[syncedDeviceFile],
    };
    messenger.setMockMethodCallHandler(channel, (call) async {
      return switch (call.method) {
        'connect' => connectedDevice,
        'refreshDeviceInfo' => runtimeSnapshot,
        'readRecordingState' => <String, Object?>{'state': 'idle'},
        'scanFiles' => <String, Object?>{
          'files': <Object?>[syncedDeviceFile],
        },
        'closeWifiSession' => true,
        _ => null,
      };
    });
    final eventsPort = MethodChannelRecordingCardPort(
      methodChannel: channel,
      nativeEvents: events.stream,
    );
    events.add(<String, Object?>{
      'type': 'runtime_snapshot',
      'snapshot': runtimeSnapshot,
    });
    final controller = RecordingCardController(
      port: eventsPort,
      localRecordingRepository: repository,
      platformPermissionsPort: const _GrantedPermissions(),
      bindingTokenProvider: () async => '0123456789abcdef0123456789abcdef',
      requiresBluetoothPermissionRequest: () => false,
    );
    addTearDown(() async {
      controller.dispose();
      messenger.setMockMethodCallHandler(channel, null);
      await eventsPort.dispose();
      await events.close();
    });
    await controller.restoreWifiBatch();
    expect(
      controller.state.wifiBatch?.state,
      RecordingCardWifiBatchState.completed,
      reason:
          '${controller.state.lastErrorCode} / '
          '${controller.state.wifiBatch?.failureCode} / '
          '${controller.state.snapshot.files.map((file) => <Object?>[file.deviceFileId, file.deviceFilename, file.syncState, file.localFileId, file.appPrivateUri]).toList()}',
    );
    var completionCalls = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => FilledButton(
              key: const ValueKey('open-wifi-flow'),
              onPressed: () => unawaited(
                showModalBottomSheet<Object?>(
                  context: context,
                  builder: (_) => V3WifiTransferFlowSheet(
                    controller: controller,
                    batchId: 'wifi-flow-completed',
                    onCompleted: () => completionCalls += 1,
                  ),
                ),
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open-wifi-flow')));
    await tester.pumpAndSettle();

    expect(completionCalls, 1);
    expect(
      find.byKey(const ValueKey('recording-card-wifi-flow-done')),
      findsOneWidget,
    );
    final done = find.byKey(const ValueKey('recording-card-wifi-flow-done'));
    await tester.ensureVisible(done);
    await tester.pumpAndSettle();
    await tester.tap(done);
    await tester.pumpAndSettle();
    expect(completionCalls, 1);
    expect(
      find.byKey(const ValueKey('recording-card-wifi-flow-sheet')),
      findsNothing,
    );
  });

  testWidgets('disconnected page restores its unresolved Wi-Fi batch', (
    tester,
  ) async {
    const accountScope = 'wifi-offline-batch-account';
    const cardDigest =
        'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
    final now = DateTime.utc(2026, 9, 9, 9);
    final database = AppDatabase();
    final repository = LocalRecordingRepository(
      database: database,
      fileStorage: const UnavailableFileStoragePort(),
      accountScope: accountScope,
      requireAuthenticatedAccount: true,
    );
    repository.upsertRecordingCardWifiBatchItem(
      transferId: 'wifi-offline-batch-0',
      batchId: 'wifi-offline-batch',
      deviceFingerprint: 'wifi-offline-card',
      deviceIdentity: 'serial:SP63A03004',
      cardSnDigest: cardDigest,
      deviceFileId: 'wifi-offline-file',
      deviceFilename: '20260909090000.m4a',
      localFileKey: 'wifi-offline-file-key',
      itemOrder: 0,
      expectedSizeBytes: 4096,
      attemptCount: 1,
      batchStage: RecordingCardWifiBatchState.transferring.name,
      stage: RecordingCardWifiBatchItemState.queued.name,
      idempotencyKey:
          'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd',
      fileFormat: RecordingCardFileFormat.m4a.name,
      mimeType: 'audio/mp4',
      durationSeconds: 60,
      recordedAt: now,
      createdAt: now,
      updatedAt: now,
    );
    final ledger = RecordingCardAutoSyncStore(
      database: database,
      accountScope: accountScope,
    );
    ledger.savePreferences(
      const RecordingCardAutoSyncPreferences(autoSyncEnabled: false),
    );
    final controller = RecordingCardController(
      port: const UnavailableRecordingCardPort(),
      localRecordingRepository: repository,
      platformPermissionsPort: const _GrantedPermissions(),
      syncLedgerPersistence: ledger,
      bindingTokenProvider: () async => '0123456789abcdef0123456789abcdef',
      requiresBluetoothPermissionRequest: () => false,
    );
    final autoSync = RecordingCardAutoSyncCoordinator(
      persistence: ledger,
      actions: ControllerRecordingCardAutoSyncActions(controller),
    );
    final library = RecordingLibraryController(
      repository: repository,
      nativeFilePort: const UnavailableNativeFilePort(),
    );
    final playback = RecordingPlaybackController(
      playbackPort: const UnavailableNativePlaybackPort(),
      positionStore: InMemoryRecordingPlaybackPositionStore(),
    );
    await controller.restoreWifiBatch();
    expect(
      controller.state.wifiBatch?.state,
      RecordingCardWifiBatchState.paused,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          authenticatedRecordingUserScopeProvider.overrideWith(
            (ref) => accountScope,
          ),
          appDatabaseProvider.overrideWith((ref) => database),
          recordingCardControllerProvider.overrideWith((ref) => controller),
          recordingCardAutoSyncStoreProvider.overrideWithValue(ledger),
          recordingCardAutoSyncCoordinatorProvider.overrideWith(
            (ref) => autoSync,
          ),
          localRecordingRepositoryProvider.overrideWithValue(repository),
          recordingLibraryControllerProvider.overrideWith((ref) => library),
          recordingPlaybackControllerProvider.overrideWith((ref) => playback),
        ],
        child: MaterialApp(
          theme: HuahuoV3Theme.light(),
          home: const V3RecordingCardFilesPage(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(
      find.byKey(const ValueKey('recording-card-wifi-batch-progress')),
      findsOneWidget,
    );
    expect(find.textContaining('已同步 0 条 · 未同步 1 条'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('recording-card-wifi-batch-resume')),
      findsOneWidget,
    );
  });

  testWidgets(
    'offline user-cancelled work keeps the generic synchronization card',
    (tester) async {
      const accountScope = 'cancelled-ble-pending-card-account';
      const cardDigest =
          'abababababababababababababababababababababababababababababababab';
      const sourceSignature =
          'cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd';
      final now = DateTime.utc(2026, 9, 13, 11);
      final database = AppDatabase();
      final repository = LocalRecordingRepository(
        database: database,
        fileStorage: const UnavailableFileStoragePort(),
        accountScope: accountScope,
        requireAuthenticatedAccount: true,
      );
      final ledger = RecordingCardAutoSyncStore(
        database: database,
        accountScope: accountScope,
      );
      ledger.savePreferences(
        const RecordingCardAutoSyncPreferences(autoSyncEnabled: false),
      );
      ledger.saveFileLedgerEntry(
        RecordingCardFileLedgerEntry(
          cardSnDigest: cardDigest,
          sourceSignature: sourceSignature,
          deviceFileId: 'cancelled-ble-device-file',
          deviceFilename: '20260913110000.m4a',
          recordedAt: now,
          sizeBytes: 4096,
          durationSeconds: 60,
          localState: RecordingCardFileLocalState.queued,
          cardState: RecordingCardFilePresenceState.present,
          attemptCount: 1,
          lastSeenAt: now,
          syncOrigin: RecordingCardSyncOrigin.user,
          resumeRequested: false,
          updatedAt: now,
        ),
      );
      final controller = RecordingCardController(
        port: const UnavailableRecordingCardPort(),
        localRecordingRepository: repository,
        platformPermissionsPort: const _GrantedPermissions(),
        syncLedgerPersistence: ledger,
        bindingTokenProvider: () async => '0123456789abcdef0123456789abcdef',
        requiresBluetoothPermissionRequest: () => false,
      );
      final autoSync = RecordingCardAutoSyncCoordinator(
        persistence: ledger,
        actions: ControllerRecordingCardAutoSyncActions(controller),
      );
      final library = RecordingLibraryController(
        repository: repository,
        nativeFilePort: const UnavailableNativeFilePort(),
      );
      final playback = RecordingPlaybackController(
        playbackPort: const UnavailableNativePlaybackPort(),
        positionStore: InMemoryRecordingPlaybackPositionStore(),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            authenticatedRecordingUserScopeProvider.overrideWith(
              (ref) => accountScope,
            ),
            appDatabaseProvider.overrideWith((ref) => database),
            recordingCardControllerProvider.overrideWith((ref) => controller),
            recordingCardAutoSyncStoreProvider.overrideWithValue(ledger),
            recordingCardAutoSyncCoordinatorProvider.overrideWith(
              (ref) => autoSync,
            ),
            localRecordingRepositoryProvider.overrideWithValue(repository),
            recordingLibraryControllerProvider.overrideWith((ref) => library),
            recordingPlaybackControllerProvider.overrideWith((ref) => playback),
          ],
          child: MaterialApp(
            theme: HuahuoV3Theme.light(),
            home: const V3RecordingCardFilesPage(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(controller.state.wifiBatch, isNull);
      expect(
        find.byKey(const ValueKey('recording-card-auto-sync-progress')),
        findsOneWidget,
      );
      expect(find.text('待同步 1 条'), findsWidgets);
    },
  );

  testWidgets('card file page owns selection and device-only actions', (
    tester,
  ) async {
    const channel = MethodChannel('recording_card_files_page_test');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final files = <Object?>[_deviceFile()];
    final pendingBluetoothDownload = Completer<Object?>();
    var scanCalls = 0;
    var deleteCalls = 0;
    var bluetoothDownloadCalls = 0;
    String? plannedBluetoothFileId;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'scanFiles') {
        scanCalls += 1;
        return <String, Object?>{'files': files};
      }
      if (call.method == 'deleteFileFromDevice') {
        deleteCalls += 1;
        files.clear();
        return <String, Object?>{
          'deleted': true,
          'deviceFileId': 'card-file-one',
          'deviceFilename': '20260904080000.m4a',
        };
      }
      if (call.method == 'downloadRecoverableBluetoothFile') {
        bluetoothDownloadCalls += 1;
        plannedBluetoothFileId =
            (call.arguments as Map<Object?, Object?>)['plannedNativeFileId']
                as String?;
        return pendingBluetoothDownload.future;
      }
      if (call.method == 'recoverBluetoothDownload') {
        return <String, Object?>{'exists': false};
      }
      return null;
    });
    final events = StreamController<Object?>(sync: true);
    final port = MethodChannelRecordingCardPort(
      methodChannel: channel,
      nativeEvents: events.stream,
    );
    final database = AppDatabase();
    final repository = LocalRecordingRepository(
      database: database,
      fileStorage: const _ReadyFileStorage(sizeBytes: 4096),
      accountScope: 'card-files-account',
      requireAuthenticatedAccount: true,
    );
    final library = RecordingLibraryController(
      repository: repository,
      nativeFilePort: const UnavailableNativeFilePort(),
    );
    final ledger = RecordingCardAutoSyncStore(
      database: database,
      accountScope: 'card-files-account',
    );
    ledger.savePreferences(
      const RecordingCardAutoSyncPreferences(autoSyncEnabled: false),
    );
    final card = RecordingCardController(
      port: port,
      localRecordingRepository: repository,
      platformPermissionsPort: const _GrantedPermissions(),
      syncLedgerPersistence: ledger,
      bindingTokenProvider: () async => '0123456789abcdef0123456789abcdef',
      requiresBluetoothPermissionRequest: () => false,
    );
    final cardDigest = RecordingCardFileIdentity.digestSerialNumber(
      'SP63A03003',
    )!;
    final recordedAt = DateTime.utc(2026, 9, 4, 8);
    final sourceSignature = RecordingCardFileIdentity.sourceSignatureFor(
      cardSnDigest: cardDigest,
      deviceFileId: 'card-file-one',
      deviceFilename: '20260904080000.m4a',
      sizeBytes: 4096,
      recordedAt: recordedAt,
    );
    ledger.saveFileLedgerEntry(
      RecordingCardFileLedgerEntry(
        cardSnDigest: cardDigest,
        sourceSignature: sourceSignature,
        deviceFileId: 'card-file-one',
        deviceFilename: '20260904080000.m4a',
        recordedAt: recordedAt,
        sizeBytes: 4096,
        durationSeconds: 60,
        localState: RecordingCardFileLocalState.localDeleted,
        cardState: RecordingCardFilePresenceState.present,
        lastSyncedAt: DateTime.utc(2026, 9, 4, 9),
        localDeletedAt: DateTime.utc(2026, 9, 4, 10),
        attemptCount: 1,
        lastSeenAt: DateTime.utc(2026, 9, 4, 10),
        updatedAt: DateTime.utc(2026, 9, 4, 10),
      ),
    );
    final autoSync = RecordingCardAutoSyncCoordinator(
      persistence: ledger,
      actions: ControllerRecordingCardAutoSyncActions(card),
    );
    final playback = RecordingPlaybackController(
      playbackPort: const UnavailableNativePlaybackPort(),
      positionStore: InMemoryRecordingPlaybackPositionStore(),
    );
    addTearDown(() async {
      messenger.setMockMethodCallHandler(channel, null);
      await port.dispose();
      await events.close();
    });

    events.add(_connectedSnapshot(files));
    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          authenticatedRecordingUserScopeProvider.overrideWith(
            (ref) => 'card-files-account',
          ),
          recordingCardControllerProvider.overrideWith((ref) => card),
          recordingCardAutoSyncStoreProvider.overrideWithValue(ledger),
          recordingCardAutoSyncCoordinatorProvider.overrideWith(
            (ref) => autoSync,
          ),
          localRecordingRepositoryProvider.overrideWithValue(repository),
          recordingLibraryControllerProvider.overrideWith((ref) => library),
          recordingPlaybackControllerProvider.overrideWith((ref) => playback),
        ],
        child: MaterialApp(
          theme: HuahuoV3Theme.light(),
          home: const V3RecordingCardFilesPage(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));
    await tester.pump();

    final refreshRevision = card.successfulFileRefreshRevision;
    final scansBeforePull = scanCalls;
    expect(find.byType(RefreshIndicator), findsOneWidget);
    await tester.drag(find.byType(ListView).first, const Offset(0, 360));
    await tester.pumpAndSettle();
    expect(scanCalls, scansBeforePull + 1);
    expect(card.successfulFileRefreshRevision, refreshRevision + 1);

    expect(
      find.byKey(const ValueKey('recording-card-files-enter-batch')),
      findsOneWidget,
    );
    expect(find.text('删除本地录音文件'), findsNothing);
    expect(find.text('转写'), findsNothing);
    expect(find.text('本地已删除'), findsOneWidget);
    expect(find.byType(V3RecordingAutoSyncPanel), findsNothing);
    final lastSynced = tester.widget<Text>(
      find.byKey(
        const ValueKey('recording-card-last-synced-card-file-one-key'),
      ),
    );
    expect(lastSynced.data, contains('最近同步'));
    expect(lastSynced.data, contains('09-04'));

    await tester.tap(
      find.byKey(
        const ValueKey('recording-card-management-more-card-file-one-key'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('文件详情'), findsOneWidget);
    expect(find.text('蓝牙传输'), findsOneWidget);
    expect(find.text('Wi-Fi 传输'), findsOneWidget);
    expect(find.text('删除录音卡原文件'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey('recording-card-files-enter-batch')),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('recording-library-batch-select-all')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('recording-library-batch-clear')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('recording-library-batch-exit')),
      findsOneWidget,
    );
    expect(
      tester
          .widget<IconButton>(
            find.byKey(const ValueKey('recording-card-files-header-refresh')),
          )
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<IconButton>(
            find.byKey(const ValueKey('recording-card-files-menu')),
          )
          .onPressed,
      isNull,
    );

    await tester.tap(
      find.byKey(const ValueKey('recording-library-batch-select-all')),
    );
    await tester.pump();
    await tester.pump();

    files.clear();
    await card.refreshFiles(reason: RecordingCardFileRefreshReason.manual);
    await tester.pump();
    await tester.pump();
    files.add(_deviceFile());
    await card.refreshFiles(reason: RecordingCardFileRefreshReason.manual);
    await tester.pump();
    await tester.pump();
    expect(find.text('已选择 0 条'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('recording-library-batch-select-all')),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('recording-card-files-batch-sync')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('recording-card-files-batch-delete')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey('recording-library-batch-clear')),
    );
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey('recording-library-batch-exit')),
    );
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('recording-card-files-menu')));
    await tester.pumpAndSettle();
    expect(find.text('刷新文件列表'), findsNothing);
    expect(
      find.byKey(const ValueKey('recording-card-files-header-refresh')),
      findsOneWidget,
    );
    expect(find.text('蓝牙传输'), findsOneWidget);
    expect(find.text('Wi-Fi 传输'), findsOneWidget);
    expect(find.text('删除录音卡文件'), findsOneWidget);
    expect(find.text('删除本地录音文件'), findsNothing);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('recording-card-files-menu')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('recording-card-files-bluetooth-entry')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('recording-library-batch-select-all')),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('已选 1 条'), findsOneWidget);
    final bluetoothBatch = find.byKey(
      const ValueKey('recording-card-files-batch-bluetooth'),
    );
    await tester.tap(bluetoothBatch);
    await tester.tap(bluetoothBatch);
    await tester.pump();
    expect(bluetoothDownloadCalls, 1);
    final bluetoothButton = find.descendant(
      of: bluetoothBatch,
      matching: find.byType(FilledButton),
    );
    expect(tester.widget<FilledButton>(bluetoothButton).onPressed, isNull);
    final nativeFileId = plannedBluetoothFileId!;
    pendingBluetoothDownload.complete(<String, Object?>{
      'localFileKey': 'card-file-one-key',
      'localFileId': nativeFileId,
      'appPrivateUri': 'app-private://recording-card/$nativeFileId.m4a',
      'displayName': '20260904080000.m4a',
      'durationSeconds': 60,
      'sizeBytes': 4096,
      'contentHash':
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      'format': 'm4a',
      'mimeType': 'audio/mp4',
    });
    await tester.pumpAndSettle();
    expect(find.text('本轮同步：已同步 1 条，未同步 0 条'), findsOneWidget);
    final exitAfterBluetooth = find.byKey(
      const ValueKey('recording-library-batch-exit'),
    );
    if (exitAfterBluetooth.evaluate().isNotEmpty) {
      await tester.tap(exitAfterBluetooth);
      await tester.pump();
    }
    await card.refreshFiles(reason: RecordingCardFileRefreshReason.manual);
    await tester.pump();
    await tester.pump();

    final pageElement = tester.element(find.byType(V3RecordingCardFilesPage));
    final uiController = ProviderScope.containerOf(
      pageElement,
    ).read(recordingLibraryUiControllerProvider);
    await tester.tap(
      find.byKey(const ValueKey('recording-card-files-enter-batch')),
    );
    await tester.pump();
    expect(uiController.batchMode, isFalse);
    expect(
      find.byKey(const ValueKey('recording-library-batch-exit')),
      findsOneWidget,
    );

    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byType(V3RecordingCardFilesPage), findsOneWidget);
    expect(uiController.batchMode, isFalse);
    expect(
      find.byKey(const ValueKey('recording-library-batch-exit')),
      findsNothing,
    );

    await tester.tap(find.byKey(const ValueKey('recording-card-files-menu')));
    await tester.pumpAndSettle();
    expect(find.text('卡内文件均已同步到本地'), findsNWidgets(2));
    await tester.tap(
      find.byKey(const ValueKey('recording-card-files-delete-entry')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('recording-library-batch-select-all')),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('已选 1 条'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('recording-card-files-batch-delete')),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('本地录音副本会保留'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('recording-card-confirm-device-delete')),
    );
    await tester.pumpAndSettle();
    expect(
      deleteCalls,
      1,
      reason:
          'status=${card.state.status}, error=${card.state.lastErrorCode}, '
          'catalog=${card.state.fileCatalog.phase}, '
          'loaded=${card.hasLoadedFilesForCurrentConnection}, '
          'operation=${card.state.operation.phase}/'
          '${card.state.operation.kind}, block=${card.operationBlockCode}, '
          'activeTransfer=${card.hasActiveTransfer}',
    );
    expect(
      ledger.loadFileLedger(cardDigest).single.cardState,
      RecordingCardFilePresenceState.deleted,
    );

    uiController.setBatchMode(true);
    await tester.pump();
    expect(uiController.batchMode, isTrue);
    expect(
      find.byKey(const ValueKey('recording-library-batch-exit')),
      findsNothing,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    expect(uiController.batchMode, isTrue);
  });

  testWidgets(
    'offline local-deleted rows retain only hash-compatible transcription receipts',
    (tester) async {
      await loadFigmaGoldenFonts();
      await tester.binding.setSurfaceSize(const Size(320, 980));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      const accountScope = 'card-files-receipt-account';
      const cardDigest =
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      const matchingHash =
          'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
      const changedHash =
          'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
      const staleHash =
          'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd';
      const matchingSource =
          'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee';
      const changedSource =
          'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff';
      const readySource =
          '1111111111111111111111111111111111111111111111111111111111111111';
      const missingSource =
          '2222222222222222222222222222222222222222222222222222222222222222';
      const unknownSource =
          '3333333333333333333333333333333333333333333333333333333333333333';
      const readyHash =
          '3333333333333333333333333333333333333333333333333333333333333333';
      final at = DateTime.utc(2026, 9, 4, 8);
      final database = AppDatabase();
      final readyLocal = RecordingLibraryItem(
        recordingId: 'ready-local',
        source: RecordingLibrarySource.device,
        displayName: '已同步本地录音.m4a',
        format: RecordingLibraryFormat.m4a,
        localFileState: RecordingLocalFileState.ready,
        status: RecordingLibraryStatus.localOnly,
        durationSeconds: 45,
        sizeBytes: 3072,
        isFavorite: false,
        tagIds: const <String>[],
        createdAt: at,
        updatedAt: at,
        appPrivateUri: 'app-private://recordings/ready-local/source.m4a',
        deviceFilename: '20260904060000.m4a',
        contentHash: readyHash,
      );
      RecordingDao(
        database,
        userScope: accountScope,
      ).upsertLocalRecording(readyLocal.recordingId, readyLocal.toRecord());
      final repository = LocalRecordingRepository(
        database: database,
        fileStorage: const _ReadyFileStorage(),
        accountScope: accountScope,
        requireAuthenticatedAccount: true,
      );
      final library = RecordingLibraryController(
        repository: repository,
        nativeFilePort: const UnavailableNativeFilePort(),
      );
      final card = RecordingCardController(
        port: const UnavailableRecordingCardPort(),
        localRecordingRepository: repository,
        platformPermissionsPort: const _GrantedPermissions(),
        bindingTokenProvider: () async => '0123456789abcdef0123456789abcdef',
        requiresBluetoothPermissionRequest: () => false,
      );
      final ledger = RecordingCardAutoSyncStore(
        database: database,
        accountScope: accountScope,
      );
      ledger.savePreferences(
        const RecordingCardAutoSyncPreferences(autoSyncEnabled: false),
      );
      for (final entry in <RecordingCardFileLedgerEntry>[
        RecordingCardFileLedgerEntry(
          cardSnDigest: cardDigest,
          sourceSignature: matchingSource,
          deviceFileId: 'matching-device-file',
          deviceFilename: '20260904080000.m4a',
          recordedAt: at,
          sizeBytes: 4096,
          durationSeconds: 60,
          contentHash: matchingHash,
          localRecordingId: 'deleted-local-matching',
          localState: RecordingCardFileLocalState.localDeleted,
          cardState: RecordingCardFilePresenceState.present,
          lastSyncedAt: at,
          localDeletedAt: at.add(const Duration(minutes: 1)),
          attemptCount: 1,
          lastSeenAt: at,
          updatedAt: at.add(const Duration(minutes: 1)),
        ),
        RecordingCardFileLedgerEntry(
          cardSnDigest: cardDigest,
          sourceSignature: changedSource,
          deviceFileId: 'changed-device-file',
          deviceFilename: '20260904070000.m4a',
          recordedAt: at.subtract(const Duration(hours: 1)),
          sizeBytes: 2048,
          durationSeconds: 30,
          contentHash: changedHash,
          localRecordingId: 'deleted-local-changed',
          localState: RecordingCardFileLocalState.localDeleted,
          cardState: RecordingCardFilePresenceState.present,
          lastSyncedAt: at,
          localDeletedAt: at.add(const Duration(minutes: 1)),
          attemptCount: 1,
          lastSeenAt: at,
          updatedAt: at,
        ),
        RecordingCardFileLedgerEntry(
          cardSnDigest: cardDigest,
          sourceSignature: readySource,
          deviceFileId: 'ready-device-file',
          deviceFilename: '20260904060000.m4a',
          recordedAt: at.subtract(const Duration(hours: 2)),
          sizeBytes: 3072,
          durationSeconds: 45,
          contentHash: readyHash,
          localRecordingId: readyLocal.recordingId,
          localState: RecordingCardFileLocalState.synced,
          cardState: RecordingCardFilePresenceState.present,
          lastSyncedAt: at,
          attemptCount: 1,
          lastSeenAt: at,
          updatedAt: at,
        ),
        RecordingCardFileLedgerEntry(
          cardSnDigest: cardDigest,
          sourceSignature: missingSource,
          deviceFileId: 'missing-device-file',
          deviceFilename: '20260904050000.m4a',
          recordedAt: at.subtract(const Duration(hours: 3)),
          sizeBytes: 1024,
          durationSeconds: 20,
          localRecordingId: 'missing-local',
          localState: RecordingCardFileLocalState.synced,
          cardState: RecordingCardFilePresenceState.present,
          lastSyncedAt: at,
          attemptCount: 1,
          lastSeenAt: at,
          updatedAt: at,
        ),
        RecordingCardFileLedgerEntry(
          cardSnDigest: cardDigest,
          sourceSignature: unknownSource,
          deviceFileId: 'historical-device-file',
          deviceFilename: '20260904040000.m4a',
          recordedAt: at.subtract(const Duration(hours: 4)),
          sizeBytes: 512,
          localState: RecordingCardFileLocalState.neverSynced,
          cardState: RecordingCardFilePresenceState.unknown,
          attemptCount: 0,
          lastSeenAt: at.subtract(const Duration(days: 1)),
          updatedAt: at,
        ),
      ]) {
        ledger.saveFileLedgerEntry(entry);
      }
      final receipts = RecordingTranscriptionReceiptStore(
        database: database,
        accountScope: accountScope,
      );
      receipts
        ..save(
          RecordingTranscriptionReceipt(
            userScope: accountScope,
            fileIdentity: matchingHash,
            contentHash: matchingHash,
            localRecordingId: 'old-local-matching',
            remoteRecordingId: 'remote-matching',
            noteId: 'note-matching',
            transcriptCompletedAt: at,
            updatedAt: at,
          ),
        )
        ..save(
          RecordingTranscriptionReceipt(
            userScope: accountScope,
            fileIdentity: 'local:deleted-local-changed',
            contentHash: staleHash,
            localRecordingId: 'deleted-local-changed',
            remoteRecordingId: 'remote-stale',
            noteId: 'note-stale',
            transcriptCompletedAt: at,
            updatedAt: at,
          ),
        );
      final autoSync = RecordingCardAutoSyncCoordinator(
        persistence: ledger,
        actions: ControllerRecordingCardAutoSyncActions(card),
      );
      final playback = RecordingPlaybackController(
        playbackPort: const UnavailableNativePlaybackPort(),
        positionStore: InMemoryRecordingPlaybackPositionStore(),
      );
      await library.load();
      expect(
        library.state.items.map((item) => item.recordingId),
        contains(readyLocal.recordingId),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            authenticatedRecordingUserScopeProvider.overrideWith(
              (ref) => accountScope,
            ),
            recordingCardControllerProvider.overrideWith((ref) => card),
            recordingCardAutoSyncStoreProvider.overrideWithValue(ledger),
            recordingCardAutoSyncCoordinatorProvider.overrideWith(
              (ref) => autoSync,
            ),
            recordingLibraryControllerProvider.overrideWith((ref) => library),
            recordingPlaybackControllerProvider.overrideWith((ref) => playback),
            recordingTranscriptionReceiptStoreProvider.overrideWith(
              (ref) => receipts,
            ),
          ],
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: figmaGoldenTheme(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(1.4)),
              child: child!,
            ),
            home: const RepaintBoundary(
              key: ValueKey('card-file-audit-capture'),
              child: V3RecordingCardFilesPage(),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(
        find.byKey(
          const ValueKey('recording-card-transcribed-$matchingSource'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('recording-card-transcribed-$changedSource')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('recording-availability-ready-local')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('recording-availability-ready-local')),
            )
            .data,
        '已同步',
      );
      expect(
        find.byKey(
          const ValueKey('recording-card-device-unsynced-label-$missingSource'),
        ),
        findsOneWidget,
      );
      expect(find.text('本地已删除'), findsNWidgets(2));
      expect(find.text('本地文件缺失'), findsOneWidget);
      expect(find.byType(V3RecordingAutoSyncPanel), findsOneWidget);
      expect(
        find.byKey(const ValueKey('recording-transcribed-ready-local')),
        findsNothing,
      );
      receipts.save(
        RecordingTranscriptionReceipt(
          userScope: accountScope,
          fileIdentity: readyHash,
          contentHash: readyHash,
          localRecordingId: readyLocal.recordingId,
          remoteRecordingId: 'remote-ready',
          transcriptCompletedAt: at,
          updatedAt: at,
        ),
      );
      expect(await receipts.flush(), isTrue);
      await tester.pump();
      expect(
        find.byKey(const ValueKey('recording-transcribed-ready-local')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      if (const bool.fromEnvironment('RECORDING_CARD_UI_AUDIT_CAPTURE')) {
        await tester.runAsync(() async {
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const ValueKey('card-file-audit-capture')),
          );
          final image = await boundary.toImage(pixelRatio: 2);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            '/tmp/huahuo-recording-card-ui-audit.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      expect(find.text('20260904040000.m4a'), findsNothing);
      expect(
        find.byKey(const ValueKey('recording-card-files-offline')),
        findsOneWidget,
      );
    },
  );
}

Map<String, Object?> _connectedSnapshot(List<Object?> files) {
  return <String, Object?>{
    'type': 'runtime_snapshot',
    'snapshot': <String, Object?>{
      'deviceState': <String, Object?>{
        'connectionState': 'ble_ready',
        'connectionStage': 'connected',
        'displayName': '无限花火录音卡',
        'safeDeviceFingerprint': 'card-files-fixture',
        'serialNumber': 'SP63A03003',
        'wifiSupported': true,
        'recordingFormat': 'm4a',
      },
      'recordingInfo': <String, Object?>{'state': 'idle'},
      'files': files,
    },
  };
}

Map<String, Object?> _deviceFile() {
  return <String, Object?>{
    'deviceFileId': 'card-file-one',
    'localFileKey': 'card-file-one-key',
    'deviceFilename': '20260904080000.m4a',
    'sizeBytes': 4096,
    'durationSeconds': 60,
    'recordedAt': DateTime.utc(2026, 9, 4, 8).toIso8601String(),
    'sizeConfidence': 'trusted',
    'format': 'm4a',
    'syncState': 'deviceOnly',
  };
}

final class _GrantedPermissions implements PlatformPermissionsPort {
  const _GrantedPermissions();

  @override
  Future<PlatformPermissionResult<BluetoothActivationResult>>
  requestBluetoothActivation() async =>
      PlatformPermissionResult<BluetoothActivationResult>.success(
        BluetoothActivationResult.unavailable,
      );

  @override
  Future<PlatformPermissionResult<List<PlatformPermissionSummary>>>
  loadPermissionSummary() async =>
      PlatformPermissionResult<List<PlatformPermissionSummary>>.success(
        const <PlatformPermissionSummary>[],
      );

  @override
  Future<PlatformPermissionResult<PermissionSettingsOpenReceipt>>
  openAppSettings(
    PlatformPermissionKind kind, {
    required bool impactAcknowledged,
  }) async => PlatformPermissionResult<PermissionSettingsOpenReceipt>.success(
    PermissionSettingsOpenReceipt(
      kind: kind,
      opened: impactAcknowledged,
      impactText: buildPermissionImpactText(kind),
    ),
  );

  @override
  Future<PlatformPermissionResult<List<PlatformPermissionSummary>>>
  requestPermissions(Set<PlatformPermissionKind> kinds) async =>
      PlatformPermissionResult<List<PlatformPermissionSummary>>.success(
        const <PlatformPermissionSummary>[],
      );
}

final class _ReadyFileStorage extends UnavailableFileStoragePort {
  const _ReadyFileStorage({
    this.sizeBytes = 3072,
    this.contentHash =
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  });

  final int sizeBytes;
  final String contentHash;

  @override
  Future<FileStorageResult<PrivateAudioFileStat>> statPrivateAudio(
    String appPrivateUri,
  ) async => FileStorageResult<PrivateAudioFileStat>.success(
    PrivateAudioFileStat(exists: true, sizeBytes: sizeBytes),
  );

  @override
  Future<FileStorageResult<String>> hashPrivateAudio(
    String appPrivateUri,
  ) async => FileStorageResult<String>.success(contentHash);
}
