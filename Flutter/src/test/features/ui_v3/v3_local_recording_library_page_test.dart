import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:huahuoai_app/app/bootstrap/app_providers.dart';
import 'package:huahuoai_app/app/navigation/app_route_paths.dart';
import 'package:huahuoai_app/core/api/api_client.dart';
import 'package:huahuoai_app/core/api/upload_client.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/database/recording_dao.dart';
import 'package:huahuoai_app/core/native/native_file_port.dart';
import 'package:huahuoai_app/core/native/native_playback_port.dart';
import 'package:huahuoai_app/core/native/platform_permissions_port.dart';
import 'package:huahuoai_app/core/native/recording_card_native_port.dart';
import 'package:huahuoai_app/core/storage/file_storage_port.dart';
import 'package:huahuoai_app/core/storage/upload_draft_store.dart';
import 'package:huahuoai_app/features/recording_card/application/recording_card_auto_sync_coordinator.dart';
import 'package:huahuoai_app/features/recording_card/application/recording_card_controller.dart';
import 'package:huahuoai_app/features/recording_card/application/recording_card_file_presentation.dart';
import 'package:huahuoai_app/features/recording_card/application/recording_card_quick_wifi_coordinator.dart';
import 'package:huahuoai_app/features/recording_card/data/recording_card_auto_sync_store.dart';
import 'package:huahuoai_app/features/recording_card/domain/recording_card_auto_sync.dart';
import 'package:huahuoai_app/features/recordings/application/recording_batch_transcription_controller.dart';
import 'package:huahuoai_app/features/recordings/application/recording_processing_tracker.dart';
import 'package:huahuoai_app/features/recordings/application/recording_playback_controller.dart';
import 'package:huahuoai_app/features/recordings/application/recording_upload_controller.dart';
import 'package:huahuoai_app/features/recordings/data/local_recording_repository.dart';
import 'package:huahuoai_app/features/recordings/data/local_playback_position_store.dart';
import 'package:huahuoai_app/features/recordings/data/recording_batch_transcription_store.dart';
import 'package:huahuoai_app/features/recordings/data/recording_api.dart';
import 'package:huahuoai_app/features/recordings/data/recording_transcription_receipt_store.dart';
import 'package:huahuoai_app/features/recordings/domain/recording_transcription_receipt.dart';
import 'package:huahuoai_app/features/recordings/domain/recording_batch_transcription.dart';
import 'package:huahuoai_app/features/recordings/domain/recording_library.dart';
import 'package:huahuoai_app/features/recordings/application/recording_library_ui_controller.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_local_recording_library_page.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_recording_card_live_page.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_recording_library_surfaces.dart';
import 'package:huahuoai_app/shared/theme/huahuo_v3_theme.dart';
import 'package:huahuoai_app/shared/ui_v3/v3_components.dart';

import '../../support/figma_golden_test_support.dart';

const _recordingAccountScope = 'recording-page-test-user';
const _recordingCardEventsChannel = MethodChannel(
  'huahuoai/recording_card/events',
);

Widget _recordingTestProviderScope({
  required List<Override> overrides,
  required Widget child,
}) {
  return ProviderScope(
    overrides: <Override>[
      resolvedDeviceIdProvider.overrideWith((ref) => 'recording-page-device'),
      authenticatedRecordingUserScopeProvider.overrideWith(
        (ref) => _recordingAccountScope,
      ),
      recordingCardPortProvider.overrideWithValue(
        const UnavailableRecordingCardPort(),
      ),
      ...overrides,
    ],
    child: child,
  );
}

RecordingDao _recordingDao(AppDatabase database) {
  return RecordingDao(database, userScope: _recordingAccountScope);
}

LocalRecordingRepository _recordingRepository({
  required AppDatabase database,
  required FileStoragePort fileStorage,
}) {
  return LocalRecordingRepository(
    database: database,
    fileStorage: fileStorage,
    accountScope: _recordingAccountScope,
    requireAuthenticatedAccount: true,
  );
}

RecordingCardWifiBatchSnapshot _wifiUiBatch(
  RecordingCardWifiBatchState state,
  RecordingCardWifiBatchItemState itemState,
) {
  final at = DateTime.utc(2026, 9, 5, 8);
  return RecordingCardWifiBatchSnapshot(
    batchId: 'wifi-ui-${state.name}',
    deviceFingerprint: 'wifi-ui-card',
    deviceIdentity: 'serial:WIFI-UI-CARD',
    state: state,
    items: <RecordingCardWifiBatchItem>[
      RecordingCardWifiBatchItem(
        file: const RecordingCardScannedFile(
          deviceFileId: 'wifi-ui-file',
          localFileKey: 'wifi-ui-local-key',
          deviceFilename: '20260905080000.m4a',
          format: RecordingCardFileFormat.m4a,
          mimeType: 'audio/mp4',
        ),
        state: itemState,
        order: 0,
        expectedSizeBytes: 0,
        errorCode: itemState == RecordingCardWifiBatchItemState.failed
            ? 'RECORDING_CARD_WIFI_DOWNLOAD_FAILED'
            : null,
      ),
    ],
    createdAt: at,
    updatedAt: at,
    failureCode: state == RecordingCardWifiBatchState.failed
        ? 'RECORDING_CARD_WIFI_DOWNLOAD_FAILED'
        : null,
  );
}

final class _RecordingCardVisualHarness {
  _RecordingCardVisualHarness(AppDatabase database)
    : events = StreamController<Object?>(sync: true),
      channel = const MethodChannel('recording_card_visual_harness') {
    messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'scanFiles') {
        return <String, Object?>{'files': const <Object?>[]};
      }
      return null;
    });
    port = MethodChannelRecordingCardPort(
      methodChannel: channel,
      nativeEvents: events.stream,
    );
    controller = RecordingCardController(
      port: port,
      localRecordingRepository: _recordingRepository(
        database: database,
        fileStorage: const _ManagementFileStorage(),
      ),
      platformPermissionsPort: const _GrantedPermissionsPort(),
      bindingTokenProvider: _bindingToken,
      requiresBluetoothPermissionRequest: () => false,
    );
    events.add(_connectedCardSnapshot(files: const <Object?>[]));
  }

  final StreamController<Object?> events;
  final MethodChannel channel;
  late final TestDefaultBinaryMessenger messenger;
  late final MethodChannelRecordingCardPort port;
  late final RecordingCardController controller;

  Future<void> dispose() async {
    messenger.setMockMethodCallHandler(channel, null);
    await port.dispose();
    await events.close();
  }
}

void main() {
  late TestDefaultBinaryMessenger messenger;
  setUpAll(() async {
    await loadFigmaGoldenFonts();
    messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      _recordingCardEventsChannel,
      (call) async => null,
    );
  });
  tearDownAll(() {
    messenger.setMockMethodCallHandler(_recordingCardEventsChannel, null);
  });

  test('interrupted Wi-Fi handoff waits for a synced page projection', () {
    final cancelled = _wifiUiBatch(
      RecordingCardWifiBatchState.cancelled,
      RecordingCardWifiBatchItemState.cancelled,
    );
    final handoff = cancelled.copyWith(
      failureCode: recordingCardWifiBluetoothHandoffFailureCode,
    );
    final file = handoff.items.single.file;
    Map<String, RecordingCardFilePresentation> projection(
      RecordingCardFileDisplayStatus status,
    ) => <String, RecordingCardFilePresentation>{
      file.localFileKey: RecordingCardFilePresentation(
        file: file,
        status: status,
        transcribed: false,
      ),
    };

    expect(
      recordingCardTerminalWifiProjectionIsReady(
        batch: handoff,
        projectionByFileKey: projection(
          RecordingCardFileDisplayStatus.notSynced,
        ),
      ),
      isFalse,
    );
    expect(
      recordingCardTerminalWifiProjectionIsReady(
        batch: handoff,
        projectionByFileKey: projection(RecordingCardFileDisplayStatus.synced),
      ),
      isTrue,
    );
    expect(
      recordingCardTerminalWifiProjectionIsReady(
        batch: cancelled,
        projectionByFileKey: projection(
          RecordingCardFileDisplayStatus.notSynced,
        ),
      ),
      isTrue,
    );
  });

  testWidgets(
    'personal recordings never present a background card transcription',
    (tester) async {
      final database = AppDatabase();
      final harness = _RecordingCardVisualHarness(database);
      addTearDown(harness.dispose);
      final store = RecordingCardAutoSyncStore(
        database: database,
        accountScope: _recordingAccountScope,
      );
      store.savePreferences(
        const RecordingCardAutoSyncPreferences(autoSyncEnabled: false),
      );
      final at = DateTime.utc(2026, 9, 8);
      store.saveTask(
        RecordingCardAutoSyncTask(
          taskId: 'card-transcription-task',
          deviceFingerprint: 'card-fingerprint-1',
          deviceFileId: 'card-source',
          deviceFilename: '20260908080000.m4a',
          localFileKey: 'card-source',
          order: 0,
          state: RecordingCardAutoSyncTaskState.downloaded,
          attemptCount: 1,
          createdAt: at,
          updatedAt: at,
          localRecordingId: 'local-card-source',
          transcriptionRequested: true,
        ),
      );
      final transcription = _PendingCardTranscription();
      final autoSync = RecordingCardAutoSyncCoordinator(
        persistence: store,
        actions: ControllerRecordingCardAutoSyncActions(harness.controller),
        transcriptionPort: transcription,
      );
      autoSync.resume(requestDeviceSync: false);
      expect(autoSync.state.status, RecordingCardAutoSyncStatus.transcribing);
      await tester.pumpWidget(
        _recordingTestProviderScope(
          overrides: <Override>[
            appDatabaseProvider.overrideWith((ref) => database),
            fileStoragePortProvider.overrideWithValue(
              const UnavailableFileStoragePort(),
            ),
            recordingCardControllerProvider.overrideWith(
              (ref) => harness.controller,
            ),
            recordingCardAutoSyncCoordinatorProvider.overrideWith(
              (ref) => autoSync,
            ),
            recordingCardAutoSyncStoreProvider.overrideWithValue(store),
            recordingUploadControllerProvider.overrideWith(
              (ref) => throw StateError(
                'Personal history must not observe a card upload',
              ),
            ),
          ],
          child: MaterialApp(
            theme: figmaGoldenTheme(),
            home: const V3PersonalRecordingLibraryPage(),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(V3RecordingAutoSyncPanel), findsNothing);
      expect(find.byType(V3WifiBatchProgressPanel), findsNothing);
      expect(tester.takeException(), isNull);
      transcription.completion.complete(
        RecordingCardResult<bool>.success(true),
      );
      await tester.pump();
    },
  );

  testWidgets('inactive automatic panels never imply an active transfer', (
    tester,
  ) async {
    for (final status in <RecordingCardAutoSyncStatus>[
      RecordingCardAutoSyncStatus.idle,
      RecordingCardAutoSyncStatus.paused,
      RecordingCardAutoSyncStatus.waitingForDevice,
      RecordingCardAutoSyncStatus.waitingForRetry,
      RecordingCardAutoSyncStatus.failed,
    ]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: figmaGoldenTheme(),
          home: Scaffold(
            body: V3RecordingAutoSyncPanel(
              state: RecordingCardAutoSyncState(
                status: status,
                preferences: const RecordingCardAutoSyncPreferences(),
              ),
              unsyncedCount: 1,
              progress: null,
              onStart: () {},
              onPause: () {},
              onContinue: () {},
              onRetry: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        0,
      );
      expect(find.textContaining('100%'), findsNothing);
    }
  });

  testWidgets('automatic progress never replays a terminal native percentage', (
    tester,
  ) async {
    final at = DateTime.utc(2026, 9, 8);
    final task = RecordingCardAutoSyncTask(
      taskId: 'current',
      deviceFingerprint: 'card',
      deviceFileId: 'source',
      deviceFilename: '20260908080000.m4a',
      localFileKey: 'source',
      order: 0,
      state: RecordingCardAutoSyncTaskState.downloading,
      attemptCount: 1,
      createdAt: at,
      updatedAt: at,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: figmaGoldenTheme(),
        home: Scaffold(
          body: V3RecordingAutoSyncPanel(
            state: RecordingCardAutoSyncState(
              status: RecordingCardAutoSyncStatus.downloading,
              preferences: const RecordingCardAutoSyncPreferences(),
              tasks: <RecordingCardAutoSyncTask>[task],
              activeTaskId: task.taskId,
            ),
            unsyncedCount: 1,
            progress: const RecordingCardTransferProgress(
              localFileKey: 'source',
              receivedBytes: 4096,
              totalBytes: 4096,
              correlationId: 'old-transfer',
              phase: RecordingCardTransferPhase.completed,
            ),
            onStart: () {},
            onPause: () {},
            onContinue: () {},
            onRetry: () {},
          ),
        ),
      ),
    );
    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value,
      isNull,
    );
    expect(find.textContaining('100%'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('finalizing automatic panels cannot restart completed files', (
    tester,
  ) async {
    for (final status in <RecordingCardAutoSyncStatus>[
      RecordingCardAutoSyncStatus.pausing,
      RecordingCardAutoSyncStatus.verifying,
      RecordingCardAutoSyncStatus.committing,
    ]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: figmaGoldenTheme(),
          home: Scaffold(
            body: V3RecordingAutoSyncPanel(
              state: RecordingCardAutoSyncState(
                status: status,
                preferences: const RecordingCardAutoSyncPreferences(),
              ),
              unsyncedCount: 0,
              progress: null,
              onStart: () => fail('must not restart'),
              onPause: () => fail('must not pause twice'),
              onContinue: () => fail('must wait for cancellation settlement'),
              onRetry: () => fail('must not retry while committing'),
            ),
          ),
        ),
      );
      expect(find.text('开始'), findsNothing);
      expect(find.text('继续'), findsNothing);
      expect(find.text('重试'), findsNothing);
      expect(find.textContaining('100%'), findsNothing);
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        isNull,
      );
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('paused Wi-Fi batch notice maps failure without exposing its code', () {
    expect(
      recordingCardWifiPausedBatchMessage(
        itemErrorCodes: const <String?>[
          null,
          'RECORDING_CARD_WIFI_DATA_OVERRUN',
        ],
        fallbackErrorCode: 'RECORDING_CARD_WIFI_CONNECTION_TIMEOUT',
      ),
      'Wi-Fi 传输遇到问题，可重新连接后重试',
    );
    expect(
      recordingCardWifiPausedBatchMessage(
        itemErrorCodes: const <String?>[null],
        fallbackErrorCode: 'RECORDING_CARD_WIFI_NETWORK_UNAVAILABLE',
      ),
      'Wi-Fi 连接已中断，可重新连接后继续',
    );
  });

  test('Wi-Fi settlement summary counts completed and remaining files', () {
    final base = _wifiUiBatch(
      RecordingCardWifiBatchState.paused,
      RecordingCardWifiBatchItemState.queued,
    );
    final batch = base.copyWith(
      items: <RecordingCardWifiBatchItem>[
        base.items.single.copyWith(
          state: RecordingCardWifiBatchItemState.completed,
        ),
        RecordingCardWifiBatchItem(
          file: base.items.single.file.copyWith(
            syncState: RecordingCardFileSyncState.deviceOnly,
          ),
          state: RecordingCardWifiBatchItemState.queued,
          order: 1,
          expectedSizeBytes: 0,
        ),
      ],
    );

    expect(batch.completedCount, 1);
    expect(batch.remainingCount, 1);
    expect(
      recordingCardWifiBatchSettlementMessage(batch, prefix: 'Wi-Fi 连接已中断'),
      'Wi-Fi 连接已中断：已同步 1 条，未同步 1 条',
    );
  });

  test('sync settlement counts skipped files without reimporting them', () {
    final completedFile = _wifiUiBatch(
      RecordingCardWifiBatchState.completed,
      RecordingCardWifiBatchItemState.completed,
    ).items.single.file;
    final settlement = V3RecordingCardSyncSettlement(
      cardSnDigest:
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      completedFiles: <RecordingCardScannedFile>[completedFile],
      completedCount: 2,
      remainingCount: 0,
    );

    expect(settlement.completedFiles, <RecordingCardScannedFile>[
      completedFile,
    ]);
    expect(settlement.completedCount, 2);
    expect(settlement.remainingCount, 0);
  });

  test('recording library action errors use safe local messages', () {
    const code = 'RECORDING_FILE_NOT_FOUND';
    final message = recordingLibraryFailureMessage(code, action: '打开');

    expect(message, '打开失败，录音文件不可用');
    expect(message, isNot(contains(code)));
  });

  testWidgets('Wi-Fi panels retain state while exposing valid actions', (
    tester,
  ) async {
    var startCalls = 0;
    var cancelCalls = 0;
    var resumeCalls = 0;
    var dismissCalls = 0;
    var retryCalls = 0;

    Future<void> pumpPanel(
      RecordingCardWifiBatchSnapshot batch, {
      bool actionBusy = false,
    }) {
      return tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(320, 568),
              textScaler: TextScaler.linear(1.3),
            ),
            child: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 320,
                  child: V3WifiBatchProgressPanel(
                    batch: batch,
                    bytesPerSecond: 0,
                    actionBusy: actionBusy,
                    onStart: () => startCalls += 1,
                    onPause: () {},
                    onResume: () => resumeCalls += 1,
                    onRetryFailed: () => retryCalls += 1,
                    onCancel: () => cancelCalls += 1,
                    onDismiss: () => dismissCalls += 1,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    await pumpPanel(
      _wifiUiBatch(
        RecordingCardWifiBatchState.queued,
        RecordingCardWifiBatchItemState.queued,
      ),
    );
    expect(
      find.byKey(const ValueKey('recording-card-wifi-batch-cancel')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('recording-card-wifi-batch-start')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey('recording-card-wifi-batch-cancel')),
    );
    await tester.tap(
      find.byKey(const ValueKey('recording-card-wifi-batch-start')),
    );
    expect(cancelCalls, 1);
    expect(startCalls, 1);
    expect(find.text('Wi-Fi 传输过程中请勿离开当前页面，离开后传输会断开。'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await pumpPanel(
      _wifiUiBatch(
        RecordingCardWifiBatchState.paused,
        RecordingCardWifiBatchItemState.queued,
      ),
    );
    expect(
      find.byKey(const ValueKey('recording-card-wifi-batch-cancel')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('recording-card-wifi-batch-resume')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey('recording-card-wifi-batch-cancel')),
    );
    await tester.tap(
      find.byKey(const ValueKey('recording-card-wifi-batch-resume')),
    );
    expect(cancelCalls, 2);
    expect(resumeCalls, 1);
    expect(
      find.byKey(const ValueKey('recording-card-wifi-stay-notice')),
      findsNothing,
    );

    await pumpPanel(
      _wifiUiBatch(
        RecordingCardWifiBatchState.failed,
        RecordingCardWifiBatchItemState.failed,
      ),
    );
    expect(
      find.byKey(const ValueKey('recording-card-wifi-batch-dismiss')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('recording-card-wifi-batch-retry-failed')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey('recording-card-wifi-batch-retry-failed')),
    );
    expect(dismissCalls, 0);
    expect(retryCalls, 1);

    await pumpPanel(
      _wifiUiBatch(
        RecordingCardWifiBatchState.failed,
        RecordingCardWifiBatchItemState.failed,
      ),
      actionBusy: true,
    );
    expect(
      find.byKey(const ValueKey('recording-card-wifi-batch-dismiss')),
      findsNothing,
    );
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(
              const ValueKey('recording-card-wifi-batch-retry-failed'),
            ),
          )
          .onPressed,
      isNull,
    );

    for (final terminal in <RecordingCardWifiBatchState>[
      RecordingCardWifiBatchState.completed,
      RecordingCardWifiBatchState.cancelled,
    ]) {
      await pumpPanel(
        _wifiUiBatch(
          terminal,
          terminal == RecordingCardWifiBatchState.completed
              ? RecordingCardWifiBatchItemState.completed
              : RecordingCardWifiBatchItemState.cancelled,
        ),
      );
      expect(
        find.byKey(const ValueKey('recording-card-wifi-batch-dismiss')),
        findsNothing,
        reason: terminal.name,
      );
      if (terminal == RecordingCardWifiBatchState.cancelled) {
        expect(
          find.byKey(const ValueKey('recording-card-wifi-batch-cancel')),
          findsNothing,
        );
      }
    }

    final handoff = _wifiUiBatch(
      RecordingCardWifiBatchState.cancelled,
      RecordingCardWifiBatchItemState.cancelled,
    ).copyWith(failureCode: recordingCardWifiBluetoothHandoffFailureCode);
    await pumpPanel(handoff);
    expect(find.text('正在恢复蓝牙并继续同步'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('recording-card-wifi-batch-cancel')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('recording-card-wifi-batch-pause')),
      findsNothing,
    );
    await tester.tap(
      find.byKey(const ValueKey('recording-card-wifi-batch-cancel')),
    );
    expect(cancelCalls, 3);

    await pumpPanel(
      handoff.copyWith(
        state: RecordingCardWifiBatchState.paused,
        failureCode: recordingCardWifiBluetoothResumeFailureCode,
      ),
    );
    expect(find.text('蓝牙续传失败，等待继续'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('recording-card-wifi-batch-resume')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('unknown-byte inactive Wi-Fi states use static progress', (
    tester,
  ) async {
    for (final state in <RecordingCardWifiBatchState>[
      RecordingCardWifiBatchState.paused,
      RecordingCardWifiBatchState.failed,
      RecordingCardWifiBatchState.cancelled,
      RecordingCardWifiBatchState.completed,
    ]) {
      final itemState = switch (state) {
        RecordingCardWifiBatchState.failed =>
          RecordingCardWifiBatchItemState.failed,
        RecordingCardWifiBatchState.cancelled =>
          RecordingCardWifiBatchItemState.cancelled,
        RecordingCardWifiBatchState.completed =>
          RecordingCardWifiBatchItemState.completed,
        _ => RecordingCardWifiBatchItemState.queued,
      };
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: V3WifiBatchProgressPanel(
              batch: _wifiUiBatch(state, itemState),
              bytesPerSecond: 0,
              actionBusy: false,
              onStart: () {},
              onPause: () {},
              onResume: () {},
              onRetryFailed: () {},
              onCancel: () {},
              onDismiss: () {},
            ),
          ),
        ),
      );
      final progress = tester.widget<LinearProgressIndicator>(
        find.descendant(
          of: find.byKey(const ValueKey('recording-card-wifi-batch-progress')),
          matching: find.byType(LinearProgressIndicator),
        ),
      );
      expect(progress.value, isNotNull, reason: state.name);
      expect(
        find.byKey(const ValueKey('recording-card-wifi-stay-notice')),
        findsNothing,
        reason: state.name,
      );
      if (state == RecordingCardWifiBatchState.completed) {
        expect(progress.value, 1);
      }
    }
  });

  testWidgets(
    'Wi-Fi ETA waits for complete samples and resets after transfer',
    (tester) async {
      final at = DateTime.utc(2026, 9, 13, 9);

      RecordingCardWifiBatchSnapshot batch({
        required RecordingCardWifiBatchState state,
        required RecordingCardWifiBatchItemState itemState,
        required int expectedSizeBytes,
        int rateSampleCount = 0,
        double? bytesPerSecond,
        int? currentEta,
        int? aggregateEta,
      }) {
        return RecordingCardWifiBatchSnapshot(
          batchId: 'wifi-eta-${state.name}-$expectedSizeBytes',
          deviceFingerprint: 'wifi-eta-card',
          deviceIdentity: 'serial:WIFI-ETA-CARD',
          state: state,
          items: <RecordingCardWifiBatchItem>[
            RecordingCardWifiBatchItem(
              file: RecordingCardScannedFile(
                deviceFileId: 'wifi-eta-file',
                localFileKey: 'wifi-eta-local-key',
                deviceFilename: '20260913090000.m4a',
                sizeBytes: expectedSizeBytes == 0 ? null : expectedSizeBytes,
                format: RecordingCardFileFormat.m4a,
                mimeType: 'audio/mp4',
              ),
              state: itemState,
              order: 0,
              expectedSizeBytes: expectedSizeBytes,
            ),
          ],
          createdAt: at,
          updatedAt: at,
          currentItemIndex: 0,
          receivedBytes: expectedSizeBytes == 0 ? 250 : expectedSizeBytes ~/ 4,
          bytesPerSecond: bytesPerSecond,
          currentFileEstimatedRemainingSeconds: currentEta,
          aggregateEstimatedRemainingSeconds: aggregateEta,
          rateSampleCount: rateSampleCount,
        );
      }

      Future<void> pumpBatch(RecordingCardWifiBatchSnapshot value) {
        return tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: V3WifiBatchProgressPanel(
                batch: value,
                bytesPerSecond: 0,
                actionBusy: false,
                onStart: () {},
                onPause: () {},
                onResume: () {},
                onRetryFailed: () {},
                onCancel: () {},
                onDismiss: () {},
              ),
            ),
          ),
        );
      }

      await pumpBatch(
        batch(
          state: RecordingCardWifiBatchState.transferring,
          itemState: RecordingCardWifiBatchItemState.transferring,
          expectedSizeBytes: 1000,
          rateSampleCount: 1,
          bytesPerSecond: 100,
          currentEta: 8,
          aggregateEta: 18,
        ),
      );
      expect(find.textContaining('正在测算'), findsOneWidget);

      await pumpBatch(
        batch(
          state: RecordingCardWifiBatchState.transferring,
          itemState: RecordingCardWifiBatchItemState.transferring,
          expectedSizeBytes: 1000,
          rateSampleCount: 2,
          bytesPerSecond: 100,
          currentEta: 8,
          aggregateEta: 18,
        ),
      );
      expect(find.textContaining('100 B/s'), findsOneWidget);
      expect(find.text('Wi-Fi 传输过程中请勿离开当前页面，离开后传输会断开。'), findsOneWidget);
      expect(find.textContaining('当前 25%'), findsOneWidget);
      expect(find.textContaining('整批 18s'), findsOneWidget);

      await pumpBatch(
        batch(
          state: RecordingCardWifiBatchState.transferring,
          itemState: RecordingCardWifiBatchItemState.transferring,
          expectedSizeBytes: 0,
          rateSampleCount: 2,
          bytesPerSecond: 100,
        ),
      );
      expect(find.textContaining('正在测算'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await pumpBatch(
        batch(
          state: RecordingCardWifiBatchState.verifying,
          itemState: RecordingCardWifiBatchItemState.verifying,
          expectedSizeBytes: 1000,
          rateSampleCount: 2,
          bytesPerSecond: 100,
          currentEta: 8,
          aggregateEta: 18,
        ),
      );
      expect(find.text('正在校验文件完整性'), findsOneWidget);
      expect(find.textContaining('100 B/s'), findsNothing);
      expect(find.textContaining('整批 18s'), findsNothing);
    },
  );

  testWidgets('retained quick Wi-Fi failure uses static progress', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: V3QuickWifiPreparationPanel(
            state: RecordingCardQuickWifiState(
              phase: RecordingCardQuickWifiPhase.failed,
              updatedAt: DateTime.utc(2026, 9, 13, 10),
              requestId: 'quick-wifi-failure',
              expectedCardSnDigest:
                  'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
              expectedDeviceFingerprint: 'quick-wifi-card',
              failureCode: 'RECORDING_CARD_WIFI_HANDOFF_FAILED',
            ),
            onRetry: () {},
          ),
        ),
      ),
    );

    final indicator = tester.widget<LinearProgressIndicator>(
      find.descendant(
        of: find.byKey(const ValueKey('recording-card-wifi-batch-progress')),
        matching: find.byType(LinearProgressIndicator),
      ),
    );
    expect(indicator.value, 0);
    expect(
      find.byKey(const ValueKey('recording-card-quick-wifi-preparation-retry')),
      findsNothing,
    );
    expect(find.textContaining('指示灯'), findsNothing);
    expect(
      find.byKey(const ValueKey('recording-card-wifi-stay-notice')),
      findsNothing,
    );
  });

  testWidgets('preparing quick Wi-Fi shows the stay-on-page reminder', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: V3QuickWifiPreparationPanel(
            state: RecordingCardQuickWifiState(
              phase: RecordingCardQuickWifiPhase.preparingHandoff,
              updatedAt: DateTime.utc(2026, 9, 17),
              requestId: 'quick-wifi-preparing',
            ),
            onRetry: () {},
          ),
        ),
      ),
    );
    expect(find.text('Wi-Fi 传输过程中请勿离开当前页面，离开后传输会断开。'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('replaces injected playback when the recording account changes', (
    tester,
  ) async {
    final accountScopeProvider = StateProvider<String?>((ref) => 'user-a');
    final database = AppDatabase();
    final firstPort = _FakePlaybackPort();
    final secondPort = _FakePlaybackPort();
    final ports = <_FakePlaybackPort>[firstPort, secondPort];
    var factoryCalls = 0;
    final container = ProviderContainer(
      overrides: <Override>[
        authenticatedRecordingUserScopeProvider.overrideWith(
          (ref) => ref.watch(accountScopeProvider),
        ),
        appDatabaseProvider.overrideWith((ref) => database),
        fileStoragePortProvider.overrideWithValue(
          const UnavailableFileStoragePort(),
        ),
        recordingPlaybackControllerProvider.overrideWith(
          (ref) => RecordingPlaybackController(
            playbackPort: _FakePlaybackPort(),
            positionStore: InMemoryRecordingPlaybackPositionStore(),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: V3RecordingLibrarySection(
              projection: V3RecordingLibraryProjection.personalLibrary,
              initialTab: V3RecordingLibraryTab.local,
              automaticDeviceRefresh: false,
              playbackPortFactory: () => ports[factoryCalls++],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(factoryCalls, 1);

    container.read(accountScopeProvider.notifier).state = 'user-b';
    await tester.pump();
    await tester.pump();

    expect(factoryCalls, 2);
    expect(firstPort.disposeCalls, 1);
    expect(secondPort.disposeCalls, 0);
  });

  testWidgets('unified inventory scans once when connection becomes ready', (
    tester,
  ) async {
    final database = AppDatabase();
    final events = StreamController<Object?>();
    const channel = MethodChannel('recording_library_connect_scan');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var scanCalls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'scanFiles') {
        scanCalls += 1;
        return <String, Object?>{'files': const <Object?>[]};
      }
      return null;
    });
    addTearDown(() async {
      messenger.setMockMethodCallHandler(channel, null);
      await events.close();
    });
    final port = MethodChannelRecordingCardPort(
      methodChannel: channel,
      nativeEvents: events.stream,
    );
    addTearDown(port.dispose);
    final controller = RecordingCardController(
      port: port,
      localRecordingRepository: _recordingRepository(
        database: database,
        fileStorage: const UnavailableFileStoragePort(),
      ),
      platformPermissionsPort: const _GrantedPermissionsPort(),
      bindingTokenProvider: _bindingToken,
      requiresBluetoothPermissionRequest: () => false,
    );

    await tester.pumpWidget(
      _recordingTestProviderScope(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => database),
          fileStoragePortProvider.overrideWithValue(
            const UnavailableFileStoragePort(),
          ),
          recordingCardControllerProvider.overrideWith((ref) => controller),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: V3RecordingLibrarySection(
              projection: V3RecordingLibraryProjection.recordingCardInventory,
              initialTab: V3RecordingLibraryTab.device,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(scanCalls, 0);

    events.add(_connectedCardSnapshot(files: const <Object?>[]));
    await tester.pump();
    await tester.pump();
    expect(scanCalls, 1);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(scanCalls, 1);
  });

  testWidgets(
    'V3 library renders persisted recordings and drives real playback state',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(402, 874));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final database = AppDatabase();
      final item = _item(
        source: RecordingLibrarySource.microphone,
        tagIds: const <String>[monologueRecordingHistoryTagId],
      );
      final olderItem = _item(
        recordingId: 'local-recording-older',
        displayName: 'Older.m4a',
        source: RecordingLibrarySource.microphone,
        tagIds: const <String>[monologueRecordingHistoryTagId],
        createdAt: DateTime.utc(2026, 7, 9, 9),
      );
      _recordingDao(
        database,
      ).upsertLocalRecording(item.recordingId, item.toRecord());
      _recordingDao(
        database,
      ).upsertLocalRecording(olderItem.recordingId, olderItem.toRecord());
      final port = _FakePlaybackPort();
      final playbackController = RecordingPlaybackController(
        playbackPort: port,
        positionStore: InMemoryRecordingPlaybackPositionStore(),
      );
      final cardHarness = _RecordingCardVisualHarness(database);
      addTearDown(cardHarness.dispose);

      await tester.pumpWidget(
        _recordingTestProviderScope(
          overrides: [
            appDatabaseProvider.overrideWith((ref) => database),
            fileStoragePortProvider.overrideWithValue(
              const UnavailableFileStoragePort(),
            ),
            recordingPlaybackControllerProvider.overrideWith(
              (ref) => playbackController,
            ),
            recordingCardControllerProvider.overrideWith(
              (ref) => cardHarness.controller,
            ),
          ],
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: figmaGoldenTheme(),
            home: const V3PersonalRecordingLibraryPage(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Meeting'), findsOneWidget);
      expect(find.text('待转写'), findsNothing);
      expect(find.textContaining('07-10 10:00'), findsOneWidget);
      expect(find.textContaining('来源：独白'), findsNothing);

      await tester.tap(_recordingRow('Older.m4a'));
      await tester.pump();

      expect(port.loadCalls, 1);
      expect(port.playCalls, 1);
      expect(find.byTooltip('暂停'), findsOneWidget);
      final inlinePlayer = find.byKey(
        const ValueKey('recording-inline-player-local-recording-older'),
      );
      expect(inlinePlayer, findsOneWidget);
      expect(
        tester.getTopLeft(inlinePlayer).dy,
        greaterThan(tester.getTopLeft(find.text('Meeting')).dy),
      );
      expect(_recordingRow('Older.m4a'), findsNothing);
      expect(find.text('Older.m4a'), findsOneWidget);
      expect(find.textContaining('2026-07-09 09:00:00'), findsOneWidget);
      expect(find.textContaining('未转写'), findsOneWidget);
      expect(
        find.byKey(
          const ValueKey('recording-player-more-local-recording-older'),
        ),
        findsOneWidget,
      );
      final playPauseButton = tester.widget<IconButton>(
        find.byWidgetPredicate(
          (widget) => widget is IconButton && widget.tooltip == '暂停',
        ),
      );
      final playPauseStyle = playPauseButton.style;
      final colors = HuahuoV3Theme.tokensOf(tester.element(inlinePlayer));
      expect(
        playPauseStyle?.backgroundColor?.resolve(const <WidgetState>{}),
        colors.primary,
      );
      expect(
        playPauseStyle?.foregroundColor?.resolve(const <WidgetState>{}),
        colors.onPrimary,
      );
      expect(
        playPauseStyle?.backgroundColor?.resolve(const <WidgetState>{
          WidgetState.disabled,
        }),
        colors.line,
      );
      expect(
        playPauseStyle?.foregroundColor?.resolve(const <WidgetState>{
          WidgetState.disabled,
        }),
        colors.muted,
      );

      final scrubber = find.byKey(
        const ValueKey('recording-playback-scrubber'),
      );
      await tester.drag(scrubber, const Offset(80, 0));
      await tester.pump();
      expect(port.seekCalls, 1);
      expect(port.pauseCalls, 0);
      expect(find.byTooltip('暂停'), findsOneWidget);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile(
          '../recording_card/goldens/recording_card_playback_playing.png',
        ),
      );
      await tester.tap(find.byTooltip('暂停'));
      await tester.pump();
      expect(port.pauseCalls, 1);
      expect(find.byTooltip('播放'), findsWidgets);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile(
          '../recording_card/goldens/recording_card_playback_paused.png',
        ),
      );
    },
  );

  testWidgets('Mobile V5 playback exposes loading and failed states', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(402, 874));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final database = AppDatabase();
    final item = _item(
      source: RecordingLibrarySource.microphone,
      tagIds: const <String>[monologueRecordingHistoryTagId],
    );
    _recordingDao(
      database,
    ).upsertLocalRecording(item.recordingId, item.toRecord());
    final pendingLoad =
        Completer<NativePlaybackResult<NativePlaybackSnapshot>>();
    final port = _FakePlaybackPort(loadResult: pendingLoad.future);
    final playbackController = RecordingPlaybackController(
      playbackPort: port,
      positionStore: InMemoryRecordingPlaybackPositionStore(),
    );
    final cardHarness = _RecordingCardVisualHarness(database);
    addTearDown(cardHarness.dispose);

    await tester.pumpWidget(
      _recordingTestProviderScope(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => database),
          fileStoragePortProvider.overrideWithValue(
            const UnavailableFileStoragePort(),
          ),
          recordingPlaybackControllerProvider.overrideWith(
            (ref) => playbackController,
          ),
          recordingCardControllerProvider.overrideWith(
            (ref) => cardHarness.controller,
          ),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: figmaGoldenTheme(),
          home: const V3PersonalRecordingLibraryPage(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(_recordingRow(item.displayName));
    await tester.pump();

    expect(
      playbackController.state.status,
      RecordingPlaybackControllerStatus.loading,
    );
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile(
        '../recording_card/goldens/recording_card_playback_loading.png',
      ),
    );
    pendingLoad.complete(
      NativePlaybackResult.failure(
        playbackFailure('RECORDING_AUDIO_UNREADABLE'),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(
      playbackController.state.status,
      RecordingPlaybackControllerStatus.failed,
    );
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile(
        '../recording_card/goldens/recording_card_playback_failed.png',
      ),
    );
  });

  testWidgets(
    'personal history contains only monologue internal and external recordings',
    (tester) async {
      final database = AppDatabase();
      final dao = _recordingDao(database);
      final cardDownload = _item(
        recordingId: 'downloaded-card-recording',
        displayName: 'Card recording.mp3',
        source: RecordingLibrarySource.device,
      );
      dao.upsertLocalRecording(
        cardDownload.recordingId,
        cardDownload.toRecord(),
      );
      final imported = _item(
        recordingId: 'generic-import',
        displayName: 'Imported.m4a',
      );
      final monologue = _item(
        recordingId: 'personal-monologue',
        displayName: '我的独白.m4a',
        source: RecordingLibrarySource.microphone,
        tagIds: const <String>[monologueRecordingHistoryTagId],
      );
      final internal = _item(
        recordingId: 'personal-internal',
        displayName: '应用内录音.m4a',
        source: RecordingLibrarySource.microphone,
        tagIds: const <String>[internalRecordingHistoryTagId],
      );
      final external = _item(
        recordingId: 'personal-external',
        displayName: '外部会议.m4a',
        source: RecordingLibrarySource.microphone,
        tagIds: const <String>[externalRecordingHistoryTagId],
      );
      for (final item in <RecordingLibraryItem>[
        imported,
        monologue,
        internal,
        external,
      ]) {
        dao.upsertLocalRecording(item.recordingId, item.toRecord());
      }

      await tester.pumpWidget(
        _recordingTestProviderScope(
          overrides: [
            appDatabaseProvider.overrideWith((ref) => database),
            fileStoragePortProvider.overrideWithValue(
              const UnavailableFileStoragePort(),
            ),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: V3RecordingLibrarySection(
                projection: V3RecordingLibraryProjection.personalLibrary,
                initialTab: V3RecordingLibraryTab.local,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(
        find.byKey(
          const ValueKey('recording-availability-downloaded-card-recording'),
        ),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('recording-availability-generic-import')),
        findsNothing,
      );
      for (final recordingId in <String>[
        'personal-monologue',
        'personal-internal',
        'personal-external',
      ]) {
        expect(
          find.byKey(ValueKey('recording-availability-$recordingId')),
          findsOneWidget,
        );
      }
    },
  );

  testWidgets(
    'recording-card inventory excludes live card rows from the local page',
    (tester) async {
      final database = AppDatabase();
      final local = _item(
        recordingId: 'renamed-card-recording',
        displayName: '客户访谈.m4a',
        source: RecordingLibrarySource.device,
        deviceFilename: '20260715170000',
      );
      _recordingDao(
        database,
      ).upsertLocalRecording(local.recordingId, local.toRecord());
      final events = StreamController<Object?>(sync: true);
      final port = MethodChannelRecordingCardPort(nativeEvents: events.stream);
      final controller = RecordingCardController(
        port: port,
        localRecordingRepository: _recordingRepository(
          database: database,
          fileStorage: const UnavailableFileStoragePort(),
        ),
        platformPermissionsPort: const _GrantedPermissionsPort(),
        bindingTokenProvider: _bindingToken,
        requiresBluetoothPermissionRequest: () => false,
      );
      addTearDown(() async {
        await port.dispose();
        await events.close();
      });
      events.add(
        _connectedCardSnapshot(
          files: <Object?>[
            _deviceFileMap(
              deviceFileId: 'different-device-file-id',
              localFileKey: 'different-device-file-key',
              deviceFilename: '20260715170000',
            ),
          ],
        ),
      );

      await tester.pumpWidget(
        _recordingTestProviderScope(
          overrides: [
            appDatabaseProvider.overrideWith((ref) => database),
            fileStoragePortProvider.overrideWithValue(
              const UnavailableFileStoragePort(),
            ),
            recordingCardControllerProvider.overrideWith((ref) => controller),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: V3RecordingLibrarySection(
                projection: V3RecordingLibraryProjection.recordingCardInventory,
                initialTab: V3RecordingLibraryTab.device,
                automaticDeviceRefresh: false,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('客户访谈'), findsOneWidget);
      expect(
        find.byKey(
          const ValueKey('recording-card-device-row-different-device-file-key'),
        ),
        findsNothing,
      );
      expect(find.text('已同步'), findsOneWidget);
    },
  );

  testWidgets(
    'personal library reuses flat management rows without search and owns batch controls',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(430, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final database = AppDatabase();
      final dao = _recordingDao(database);
      for (final item in <RecordingLibraryItem>[
        _item(
          recordingId: 'batch-monologue',
          displayName: '批量独白.m4a',
          source: RecordingLibrarySource.microphone,
          tagIds: const <String>[monologueRecordingHistoryTagId],
        ),
        _item(
          recordingId: 'batch-internal',
          displayName: '批量内录.m4a',
          source: RecordingLibrarySource.microphone,
          tagIds: const <String>[internalRecordingHistoryTagId],
        ),
      ]) {
        dao.upsertLocalRecording(item.recordingId, item.toRecord());
      }

      await tester.pumpWidget(
        _recordingTestProviderScope(
          overrides: [
            appDatabaseProvider.overrideWith((ref) => database),
            fileStoragePortProvider.overrideWithValue(
              const UnavailableFileStoragePort(),
            ),
          ],
          child: const MaterialApp(home: V3PersonalRecordingLibraryPage()),
        ),
      );
      await tester.pumpAndSettle();

      final title = find.byKey(
        const ValueKey('recording-library-section-title'),
      );
      final enterBatch = find.byKey(
        const ValueKey('recording-card-toggle-batch'),
      );
      expect(
        find.byKey(const ValueKey('recording-library-search')),
        findsNothing,
      );
      expect(find.byType(TextField), findsNothing);
      for (final recordingId in ['batch-monologue', 'batch-internal']) {
        final row = find.byKey(
          ValueKey('recording-card-management-row-$recordingId'),
        );
        expect(row, findsOneWidget);
        final surface = tester.widget<V3Card>(
          find.ancestor(of: row, matching: find.byType(V3Card)),
        );
        expect(surface.variant, V3CardVariant.flat);
        expect(surface.radius, 0);
        expect(
          find.descendant(of: row, matching: find.text('01:00')),
          findsOneWidget,
        );
      }
      expect(find.text('批量独白'), findsOneWidget);
      expect(find.text('批量内录'), findsOneWidget);
      expect(find.text('本地文件'), findsNWidgets(2));
      expect(find.text('已同步'), findsNothing);
      expect(title, findsOneWidget);
      expect(enterBatch, findsOneWidget);
      expect(
        (tester.getCenter(title).dy - tester.getCenter(enterBatch).dy).abs(),
        lessThan(2),
      );

      await tester.tap(enterBatch);
      await tester.pumpAndSettle();

      final selectAll = find.byKey(
        const ValueKey('recording-library-batch-select-all'),
      );
      final clear = find.byKey(const ValueKey('recording-library-batch-clear'));
      final exit = find.byKey(const ValueKey('recording-library-batch-exit'));
      final delete = find.byKey(
        const ValueKey('personal-recording-batch-delete'),
      );
      final transcribe = find.byKey(
        const ValueKey('personal-recording-batch-transcribe'),
      );
      expect(selectAll, findsOneWidget);
      expect(clear, findsOneWidget);
      expect(exit, findsOneWidget);
      expect(delete, findsOneWidget);
      expect(transcribe, findsOneWidget);
      expect(tester.widget<TextButton>(clear).onPressed, isNull);
      expect(tester.widget<OutlinedButton>(delete).onPressed, isNull);
      expect(tester.widget<FilledButton>(transcribe).onPressed, isNull);

      await tester.tap(find.text('批量内录'));
      await tester.pumpAndSettle();
      expect(find.text('已选择 1 条'), findsOneWidget);
      expect(find.text('批量内录'), findsOneWidget);
      expect(find.text('批量独白'), findsOneWidget);
      expect(tester.widget<TextButton>(clear).onPressed, isNotNull);
      expect(tester.widget<FilledButton>(transcribe).onPressed, isNotNull);

      await tester.tap(selectAll);
      await tester.pumpAndSettle();
      expect(find.text('已选择 2 条'), findsOneWidget);
      expect(tester.widget<TextButton>(clear).onPressed, isNotNull);
      expect(tester.widget<OutlinedButton>(delete).onPressed, isNotNull);
      expect(tester.widget<FilledButton>(transcribe).onPressed, isNotNull);

      final startTranscription = tester
          .widget<FilledButton>(transcribe)
          .onPressed!;
      startTranscription();
      startTranscription();
      await tester.pumpAndSettle();
      expect(find.text('确认批量转写？'), findsOneWidget);
      expect(find.text('共选择'), findsOneWidget);
      expect(find.text('已转写，跳过'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('recording-batch-transcribe-cancel')),
      );
      await tester.pumpAndSettle();

      await tester.tap(clear);
      await tester.pumpAndSettle();

      expect(find.text('已选择 0 条'), findsOneWidget);
      expect(tester.widget<TextButton>(clear).onPressed, isNull);
      expect(tester.widget<OutlinedButton>(delete).onPressed, isNull);
      expect(tester.widget<FilledButton>(transcribe).onPressed, isNull);

      await tester.tap(selectAll);
      await tester.pumpAndSettle();
      await tester.tap(exit);
      await tester.pumpAndSettle();

      expect(enterBatch, findsOneWidget);
      expect(selectAll, findsNothing);
      expect(clear, findsNothing);
      expect(exit, findsNothing);
      expect(delete, findsNothing);
      expect(transcribe, findsNothing);
    },
  );

  testWidgets('recording row exposes a compact operations-only menu', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(402, 874));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final database = AppDatabase();
    final item = _item(
      originalFilename: 'meeting-original.m4a',
      source: RecordingLibrarySource.device,
      tagIds: const <String>['客户', '待办'],
    );
    _recordingDao(
      database,
    ).upsertLocalRecording(item.recordingId, item.toRecord());
    final cardHarness = _RecordingCardVisualHarness(database);
    addTearDown(cardHarness.dispose);
    await tester.pumpWidget(
      _recordingTestProviderScope(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => database),
          fileStoragePortProvider.overrideWithValue(
            const _ManagementFileStorage(),
          ),
          recordingCardControllerProvider.overrideWith(
            (ref) => cardHarness.controller,
          ),
        ],
        child: const MaterialApp(
          debugShowCheckedModeBanner: false,
          home: V3RecordingCardLivePage(
            initialTab: V3RecordingLibraryTab.local,
            focusLibrary: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey('recording-row-more-local-recording-1')),
    );
    await tester.pumpAndSettle();

    for (final label in <String>['上传并转写', '重命名', '用其他应用打开', '删除本地录音文件']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.text('保存到本地'), findsNothing);
    expect(find.text('创建时间'), findsNothing);
    expect(find.text('收藏'), findsNothing);
    expect(find.text('编辑标签'), findsNothing);

    final deleteLocal = find.text('删除本地录音文件');
    expect(deleteLocal, findsOneWidget);
    expect(deleteLocal.hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('重命名'));
    await tester.pumpAndSettle();
    expect(find.text('重命名录音'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      'Meeting.m4a',
    );
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('recording-row-more-local-recording-1')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除本地录音文件'));
    await tester.pumpAndSettle();
    expect(find.text('删除本地录音？'), findsOneWidget);
    expect(find.text('将永久删除手机本地录音文件。录音卡中的原文件不会被删除。'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '删除本地'), findsOneWidget);
  });

  testWidgets(
    'local inventory keeps only compatible durable transcription facts',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(402, 874));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      const matchingHash =
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      const changedHash =
          'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
      const staleHash =
          'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
      final database = AppDatabase();
      final matching = _item(
        recordingId: 'resynced-local',
        displayName: '同内容重同步.m4a',
        source: RecordingLibrarySource.device,
        contentHash: matchingHash,
      );
      final changed = _item(
        recordingId: 'changed-local',
        displayName: '内容已变化.m4a',
        source: RecordingLibrarySource.device,
        contentHash: changedHash,
        createdAt: DateTime.utc(2026, 7, 10, 9),
      );
      final dao = _recordingDao(database);
      dao
        ..upsertLocalRecording(matching.recordingId, matching.toRecord())
        ..upsertLocalRecording(changed.recordingId, changed.toRecord());
      final receipts = RecordingTranscriptionReceiptStore(
        database: database,
        accountScope: _recordingAccountScope,
      );
      final completedAt = DateTime.utc(2026, 7, 10, 11);
      receipts
        ..save(
          RecordingTranscriptionReceipt(
            userScope: _recordingAccountScope,
            fileIdentity: matchingHash,
            contentHash: matchingHash,
            localRecordingId: 'old-local-id',
            remoteRecordingId: 'remote-resynced',
            noteId: 'note-resynced',
            transcriptCompletedAt: completedAt,
            updatedAt: completedAt,
          ),
        )
        ..save(
          RecordingTranscriptionReceipt(
            userScope: _recordingAccountScope,
            fileIdentity: 'local:changed-local',
            contentHash: staleHash,
            localRecordingId: changed.recordingId,
            remoteRecordingId: 'remote-stale',
            noteId: 'note-stale',
            transcriptCompletedAt: completedAt,
            updatedAt: completedAt,
          ),
        );
      final cardHarness = _RecordingCardVisualHarness(database);
      addTearDown(cardHarness.dispose);
      final candidateFactory = RecordingTranscriptionCandidateFactory(
        draftStore: UploadDraftStore(
          database: database,
          accountScope: _recordingAccountScope,
        ),
        processing: const _NoProcessingObservationPort(),
      );
      final batchController = RecordingBatchTranscriptionController(
        store: RecordingBatchTranscriptionStore(
          database: database,
          accountScope: _recordingAccountScope,
          workspaceScope: 'workspace-1',
        ),
        receiptStore: receipts,
        executionPort: const _UnusedBatchTranscriptionExecutionPort(),
        accountScope: _recordingAccountScope,
        workspaceScope: 'workspace-1',
        candidateFactory: candidateFactory,
      );
      final router = GoRouter(
        routes: <RouteBase>[
          GoRoute(
            path: '/',
            builder: (context, state) => const V3RecordingCardLivePage(
              initialTab: V3RecordingLibraryTab.local,
              focusLibrary: true,
            ),
          ),
          GoRoute(
            path: AppRoutePaths.transcriptionDoneRoute,
            builder: (context, state) => Scaffold(
              body: Text(
                'detail:${state.pathParameters['recordingId']}',
                key: const ValueKey('transcription-detail-destination'),
              ),
            ),
          ),
          GoRoute(
            path: AppRoutePaths.transcriptionJobRoute,
            builder: (context, state) => Scaffold(
              body: Text(
                'job:${state.pathParameters['jobId']}',
                key: const ValueKey('transcription-job-destination'),
              ),
            ),
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        _recordingTestProviderScope(
          overrides: <Override>[
            appDatabaseProvider.overrideWith((ref) => database),
            fileStoragePortProvider.overrideWithValue(
              const _ManagementFileStorage(),
            ),
            recordingCardControllerProvider.overrideWith(
              (ref) => cardHarness.controller,
            ),
            recordingTranscriptionReceiptStoreProvider.overrideWith(
              (ref) => receipts,
            ),
            recordingTranscriptionCandidateFactoryProvider.overrideWithValue(
              candidateFactory,
            ),
            recordingBatchTranscriptionControllerProvider.overrideWith(
              (ref) => batchController,
            ),
          ],
          child: MaterialApp.router(
            theme: figmaGoldenTheme(),
            routerConfig: router,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('recording-transcribed-resynced-local')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('recording-transcribed-changed-local')),
        findsNothing,
      );
      expect(find.text('已转写'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('recording-card-toggle-batch')),
      );
      await tester.pump();
      await tester.tap(
        find.byKey(
          const ValueKey('recording-card-management-row-resynced-local'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('删除本地（1）'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('recording-library-batch-select-all')),
      );
      await tester.pumpAndSettle();
      expect(find.text('删除本地（2）'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('recording-card-local-batch-transcribe')),
      );
      await tester.pumpAndSettle();
      expect(find.text('确认批量转写？'), findsOneWidget);
      expect(find.text('共选择'), findsOneWidget);
      expect(find.text('将开始'), findsNWidgets(2));
      expect(find.text('已转写，跳过'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('recording-batch-transcribe-cancel')),
      );
      await tester.pumpAndSettle();
      expect(batchController.state.batches, isEmpty);
      expect(find.text('删除本地（2）'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('recording-library-batch-exit')),
      );
      await tester.pump();

      await tester.tap(
        find.byKey(const ValueKey('recording-row-more-resynced-local')),
      );
      await tester.pumpAndSettle();
      expect(find.text('查看转写'), findsOneWidget);
      expect(find.text('上传并转写'), findsNothing);
      expect(find.text('删除本地录音文件'), findsOneWidget);
      expect(find.text('Wi-Fi 传输'), findsNothing);
      expect(find.text('蓝牙传输'), findsNothing);
      expect(find.text('删除录音卡原文件'), findsNothing);

      await tester.tap(find.text('查看转写'));
      await tester.pumpAndSettle();
      expect(find.text('detail:remote-resynced'), findsOneWidget);
      router.pop();
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const ValueKey('recording-card-toggle-batch')),
      );
      await tester.pump();
      await tester.tap(
        find.byKey(
          const ValueKey('recording-card-management-row-resynced-local'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('recording-card-local-batch-transcribe')),
      );
      await tester.pumpAndSettle();

      expect(find.text('detail:remote-resynced'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('transcription-job-destination')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'single retryExisting retries the original recording before opening it',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(402, 874));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final database = AppDatabase();
      final item = _item(
        recordingId: 'retry-local',
        displayName: '待重试录音.m4a',
        source: RecordingLibrarySource.device,
        contentHash:
            'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd',
      );
      _recordingDao(
        database,
      ).upsertLocalRecording(item.recordingId, item.toRecord());
      final draftStore = UploadDraftStore(
        database: database,
        accountScope: _recordingAccountScope,
      );
      final draftResult = draftStore.saveDraft(
        UploadDraft(
          draftId: recordingFileJobId(item),
          localRecordingId: item.recordingId,
          appPrivateUri: item.appPrivateUri!,
          fileName: item.displayName,
          mimeType: 'audio/mp4',
          sizeBytes: item.sizeBytes,
          durationSeconds: item.durationSeconds,
          sourceScene: 'raw_material',
          workspaceId: 'workspace-1',
          stage: UploadDraftStage.asrFailed,
          updatedAt: item.updatedAt,
          uploadTokenKey: 'upload-retry-local',
          completeUploadKey: 'complete-retry-local',
          createRecordingKey: 'create-retry-local',
          contentHash: item.contentHash,
          recordingId: 'remote-retry-original',
          lastErrorCode: 'RECORDING_TRANSCRIPTION_FAILED',
        ),
      );
      expect(draftResult.ok, isTrue);
      final receipts = RecordingTranscriptionReceiptStore(
        database: database,
        accountScope: _recordingAccountScope,
      );
      final candidateFactory = RecordingTranscriptionCandidateFactory(
        draftStore: draftStore,
        processing: const _NoProcessingObservationPort(),
      );
      final frozenCandidate = candidateFactory.fromLibraryItem(item);
      expect(
        frozenCandidate.remoteFact,
        RecordingTranscriptionRemoteFact.terminalFailure,
      );
      expect(frozenCandidate.remoteRecordingId, 'remote-retry-original');
      final execution = _RecordingBatchExecutionSpy();
      final batchController = RecordingBatchTranscriptionController(
        store: RecordingBatchTranscriptionStore(
          database: database,
          accountScope: _recordingAccountScope,
          workspaceScope: 'workspace-1',
        ),
        receiptStore: receipts,
        executionPort: execution,
        accountScope: _recordingAccountScope,
        workspaceScope: 'workspace-1',
        candidateFactory: candidateFactory,
      );
      final cardHarness = _RecordingCardVisualHarness(database);
      addTearDown(cardHarness.dispose);
      final router = GoRouter(
        routes: <RouteBase>[
          GoRoute(
            path: '/',
            builder: (context, state) => const V3RecordingCardLivePage(
              initialTab: V3RecordingLibraryTab.local,
              focusLibrary: true,
            ),
          ),
          GoRoute(
            path: AppRoutePaths.transcriptionDoneRoute,
            builder: (context, state) => Scaffold(
              body: Text(
                'detail:${state.pathParameters['recordingId']}',
                key: const ValueKey('transcription-detail-destination'),
              ),
            ),
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        _recordingTestProviderScope(
          overrides: <Override>[
            appDatabaseProvider.overrideWith((ref) => database),
            fileStoragePortProvider.overrideWithValue(
              const _ManagementFileStorage(),
            ),
            recordingCardControllerProvider.overrideWith(
              (ref) => cardHarness.controller,
            ),
            recordingTranscriptionReceiptStoreProvider.overrideWith(
              (ref) => receipts,
            ),
            recordingTranscriptionCandidateFactoryProvider.overrideWithValue(
              candidateFactory,
            ),
            recordingBatchTranscriptionControllerProvider.overrideWith(
              (ref) => batchController,
            ),
          ],
          child: MaterialApp.router(
            theme: figmaGoldenTheme(),
            routerConfig: router,
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      await tester.tap(
        find.byKey(const ValueKey('recording-card-toggle-batch')),
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('recording-card-management-row-retry-local')),
      );
      await tester.pumpAndSettle();
      expect(find.text('转写（1）'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('recording-card-local-batch-transcribe')),
      );
      await tester.pumpAndSettle();

      expect(execution.retriedRemoteRecordingIds, <String>[
        'remote-retry-original',
      ]);
      expect(execution.submitCalls, 0);
      expect(batchController.state.batches, isEmpty);
      expect(find.text('detail:remote-retry-original'), findsOneWidget);
    },
  );

  testWidgets(
    'single upload presentation does not gate a second transcription handoff',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(402, 874));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final database = AppDatabase();
      final firstItem = _item(
        displayName: '第一条录音.m4a',
        source: RecordingLibrarySource.device,
        contentHash:
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      );
      final secondItem = _item(
        recordingId: 'local-recording-2',
        displayName: '第二条录音.m4a',
        source: RecordingLibrarySource.device,
        contentHash:
            'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        createdAt: DateTime.utc(2026, 7, 10, 11),
      );
      final dao = _recordingDao(database);
      dao
        ..upsertLocalRecording(firstItem.recordingId, firstItem.toRecord())
        ..upsertLocalRecording(secondItem.recordingId, secondItem.toRecord());
      final transport = _DelayedUploadTokenTransport();
      final apiClient = ApiClient(
        config: ApiClientConfig(
          baseUrl: Uri.parse('https://api.example.test'),
          clientVersion: 'test',
          deviceId: 'device-1',
          platform: 'ios',
          locale: 'zh-CN',
          getAccessToken: () => 'access-token-ok',
        ),
        transport: transport,
      );
      final uploadController = RecordingUploadController(
        uploadClient: UploadClient(
          apiClient: apiClient,
          objectTransport: const _NeverObjectUploadTransport(),
        ),
        draftStore: UploadDraftStore(
          database: database,
          accountScope: _recordingAccountScope,
        ),
        recordingApi: RecordingApi(apiClient: apiClient),
        localRecordingRepository: _recordingRepository(
          database: database,
          fileStorage: const UnavailableFileStoragePort(),
        ),
        activeWorkspaceId: () => 'workspace-1',
        accountScope: _recordingAccountScope,
      );
      final cardHarness = _RecordingCardVisualHarness(database);
      addTearDown(cardHarness.dispose);
      final router = GoRouter(
        routes: <RouteBase>[
          GoRoute(
            path: '/',
            builder: (context, state) => const V3RecordingCardLivePage(
              initialTab: V3RecordingLibraryTab.local,
              focusLibrary: true,
            ),
          ),
          GoRoute(
            path: AppRoutePaths.transcriptionJobRoute,
            builder: (context, state) => Scaffold(
              body: Text(
                'job:${state.pathParameters['jobId']}',
                key: const ValueKey('transcription-job-destination'),
              ),
            ),
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        _recordingTestProviderScope(
          overrides: [
            appDatabaseProvider.overrideWith((ref) => database),
            fileStoragePortProvider.overrideWithValue(
              const UnavailableFileStoragePort(),
            ),
            recordingUploadControllerProvider.overrideWith(
              (ref) => uploadController,
            ),
            recordingCardControllerProvider.overrideWith(
              (ref) => cardHarness.controller,
            ),
          ],
          child: MaterialApp.router(
            debugShowCheckedModeBanner: false,
            theme: figmaGoldenTheme(),
            routerConfig: router,
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      await tester.tap(
        find.byKey(const ValueKey('recording-row-more-local-recording-1')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('上传并转写'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(transport.tokenRequestCount, 1);
      expect(
        find.byKey(const ValueKey('transcription-job-destination')),
        findsOneWidget,
      );
      router.pop();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      await tester.tap(
        find.byKey(const ValueKey('recording-row-more-local-recording-2')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.tap(find.text('上传并转写'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(transport.tokenRequestCount, 2);
      router.pop();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      expect(
        find.byKey(const ValueKey('recording-upload-transcription-progress')),
        findsOneWidget,
      );
      expect(find.text('正在上传录音'), findsOneWidget);
      expect(find.text('第二条录音'), findsOneWidget);
      final progress = tester.widget<LinearProgressIndicator>(
        find.byKey(const ValueKey('recording-upload-transcription-indicator')),
      );
      expect(progress.value, isNull);

      transport.completeFailure(0);
      await tester.pump();
      await tester.pump();
      expect(
        find.byKey(const ValueKey('recording-upload-transcription-progress')),
        findsOneWidget,
      );
      expect(find.text('第二条录音'), findsOneWidget);

      transport.completeFailure(1);
      await tester.pump();
      await tester.pump();
      expect(
        find.byKey(const ValueKey('recording-upload-transcription-progress')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'V3 library restores historical trash and exposes direct permanent delete',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final database = AppDatabase();
      final dao = _recordingDao(database);
      final deletedUris = <String>[];
      final storage = _ManagementFileStorage(deletedUris: deletedUris);
      final active = _item(
        source: RecordingLibrarySource.microphone,
        tagIds: const <String>[monologueRecordingHistoryTagId],
      );
      final singleDelete = _item(
        recordingId: 'local-recording-2',
        displayName: 'Delete me.m4a',
        source: RecordingLibrarySource.microphone,
        tagIds: const <String>[monologueRecordingHistoryTagId],
      );
      final recycled = _item(
        recordingId: 'recycled-recording-1',
        displayName: 'Recycle.m4a',
        source: RecordingLibrarySource.microphone,
        status: RecordingLibraryStatus.recycled,
        deletedAt: DateTime.utc(2026, 7, 10, 11),
        tagIds: const <String>[monologueRecordingHistoryTagId],
      );
      dao.upsertLocalRecording(active.recordingId, active.toRecord());
      dao.upsertLocalRecording(
        singleDelete.recordingId,
        singleDelete.toRecord(),
      );
      dao.upsertLocalRecording(recycled.recordingId, recycled.toRecord());
      dao.upsertTrash(
        recordingId: recycled.recordingId,
        deletedAt: recycled.deletedAt!.toIso8601String(),
        retentionUntil: recycled.deletedAt!
            .add(const Duration(days: 30))
            .toIso8601String(),
      );
      final playbackController = RecordingPlaybackController(
        playbackPort: _FakePlaybackPort(),
        positionStore: InMemoryRecordingPlaybackPositionStore(),
      );

      await tester.pumpWidget(
        _recordingTestProviderScope(
          overrides: [
            appDatabaseProvider.overrideWith((ref) => database),
            fileStoragePortProvider.overrideWithValue(storage),
            recordingPlaybackControllerProvider.overrideWith(
              (ref) => playbackController,
            ),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: V3RecordingLibrarySection(
                projection: V3RecordingLibraryProjection.personalLibrary,
                initialTab: V3RecordingLibraryTab.local,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byTooltip('回收站'), findsNothing);
      expect(
        dao.getLocalRecording(recycled.recordingId)?['status'],
        RecordingLibraryStatus.localOnly.name,
      );
      expect(
        dao.getLocalRecording(recycled.recordingId),
        isNot(contains('deleted_at')),
      );
      expect(
        database.getRecord<LocalDatabaseRecord>(
          LocalTableName.localRecordingTrash,
          recycled.recordingId,
        ),
        isNull,
      );
      expect(deletedUris, isEmpty);

      await tester.tap(
        find.byKey(const ValueKey('recording-row-more-local-recording-1')),
      );
      await tester.pumpAndSettle();
      expect(find.text('收藏'), findsNothing);
      expect(find.text('编辑标签'), findsNothing);
      expect(find.text('删除本地录音文件'), findsOneWidget);
      expect(find.text('移入回收站'), findsNothing);
      expect(find.text('恢复录音'), findsNothing);
      await tester.tapAt(const Offset(4, 4));
      await tester.pumpAndSettle();

      await tester.ensureVisible(
        find.byKey(const ValueKey('recording-row-more-local-recording-2')),
      );
      await tester.tap(
        find.byKey(const ValueKey('recording-row-more-local-recording-2')),
      );
      await tester.pumpAndSettle();
      final deleteLocal = find.text('删除本地录音文件');
      await tester.tap(deleteLocal);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '删除本地'));
      await tester.pumpAndSettle();
      expect(dao.getLocalRecording(singleDelete.recordingId), isNull);

      final libraryContext = tester.element(
        find.byType(V3RecordingLibrarySection),
      );
      ProviderScope.containerOf(
        libraryContext,
      ).read(recordingLibraryUiControllerProvider).setBatchMode(true);
      await tester.pump();
      await tester.tap(_recordingRow('Meeting.m4a'));
      await tester.pump();
      expect(find.text('已选择 1 条'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('library-batch-actions')));
      await tester.pumpAndSettle();
      expect(find.text('全部收藏'), findsOneWidget);
      expect(find.text('设置标签'), findsOneWidget);
      expect(find.widgetWithText(ListTile, '永久删除'), findsOneWidget);
      expect(find.text('移入回收站'), findsNothing);

      await tester.tap(find.widgetWithText(ListTile, '永久删除'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '永久删除'));
      await tester.pumpAndSettle();
      expect(dao.getLocalRecording(active.recordingId), isNull);
      expect(
        dao.getLocalRecording(recycled.recordingId)?['status'],
        RecordingLibraryStatus.localOnly.name,
      );
    },
  );
  testWidgets('V3 library opens exports without exposing refs', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final database = AppDatabase();
    final dao = _recordingDao(database);
    final active = _item(
      source: RecordingLibrarySource.microphone,
      tagIds: const <String>[monologueRecordingHistoryTagId],
    );
    dao.upsertLocalRecording(active.recordingId, active.toRecord());
    final playbackController = RecordingPlaybackController(
      playbackPort: _FakePlaybackPort(),
      positionStore: InMemoryRecordingPlaybackPositionStore(),
    );
    final nativeFilePort = _RecordingExportNativeFilePort();

    await tester.pumpWidget(
      _recordingTestProviderScope(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => database),
          fileStoragePortProvider.overrideWithValue(
            const _ManagementFileStorage(),
          ),
          nativeFilePortProvider.overrideWithValue(nativeFilePort),
          recordingPlaybackControllerProvider.overrideWith(
            (ref) => playbackController,
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: V3RecordingLibrarySection(
              projection: V3RecordingLibraryProjection.personalLibrary,
              initialTab: V3RecordingLibraryTab.local,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(
      find.byKey(const ValueKey('recording-row-more-local-recording-1')),
    );
    await tester.pumpAndSettle();
    expect(find.text('保存到本地'), findsNothing);
    expect(find.text('用其他应用打开'), findsOneWidget);
    expect(find.text('准备导出'), findsNothing);
    expect(nativeFilePort.savedRefs, isEmpty);
    await tester.tap(find.text('用其他应用打开'));
    await tester.pumpAndSettle();

    expect(nativeFilePort.openedRefs, hasLength(1));
    expect(find.textContaining('app-private-export://'), findsNothing);
  });
}

final class _PendingCardTranscription
    implements RecordingCardAutoTranscriptionPort {
  final completion = Completer<RecordingCardResult<bool>>();

  @override
  Future<RecordingCardResult<bool>> transcribe(String localRecordingId) =>
      completion.future;
}

Map<String, Object?> _connectedCardSnapshot({required List<Object?> files}) {
  return <String, Object?>{
    'type': 'runtime_snapshot',
    'snapshot': <String, Object?>{
      'deviceState': <String, Object?>{
        'connectionState': 'ble_ready',
        'connectionStage': 'connected',
        'safeDeviceFingerprint': 'card-fingerprint-1',
        'wifiSupported': true,
        'recordingFormat': 'm4a',
      },
      'recordingInfo': <String, Object?>{'state': 'idle'},
      'files': files,
    },
  };
}

Map<String, Object?> _deviceFileMap({
  String deviceFileId = 'card-file-live',
  String localFileKey = 'card-live',
  String deviceFilename = '20260712090000',
  int sizeBytes = 2048,
  int? durationSeconds,
  String syncState = 'deviceOnly',
  String? localFileId,
  String? appPrivateUri,
}) {
  return <String, Object?>{
    'deviceFileId': deviceFileId,
    'localFileKey': localFileKey,
    'deviceFilename': deviceFilename,
    'sizeBytes': sizeBytes,
    if (durationSeconds != null) 'durationSeconds': durationSeconds,
    'sizeConfidence': 'trusted',
    'format': 'm4a',
    'syncState': syncState,
    if (localFileId != null) 'localFileId': localFileId,
    if (appPrivateUri != null) 'appPrivateUri': appPrivateUri,
  };
}

Future<String> _bindingToken() async => '0123456789abcdef0123456789abcdef';

Finder _recordingRow([String displayName = 'Meeting.m4a']) {
  return find.ancestor(
    of: find.text(
      displayName.replaceFirst(
        RegExp(r'\.(?:mp3|m4a|mp4|wav|opus)$', caseSensitive: false),
        '',
      ),
    ),
    matching: find.byWidgetPredicate(
      (widget) => widget is InkWell && widget.onTap != null,
    ),
  );
}

RecordingLibraryItem _item({
  String recordingId = 'local-recording-1',
  String displayName = 'Meeting.m4a',
  RecordingLibrarySource source = RecordingLibrarySource.localImport,
  RecordingLibraryStatus status = RecordingLibraryStatus.localOnly,
  DateTime? deletedAt,
  String? deviceFilename,
  String? originalFilename,
  List<String> tagIds = const <String>[],
  DateTime? createdAt,
  String? contentHash,
  String? remoteRecordingId,
}) {
  final at = createdAt ?? DateTime.utc(2026, 7, 10, 10);
  return RecordingLibraryItem(
    recordingId: recordingId,
    source: source,
    displayName: displayName,
    format: RecordingLibraryFormat.m4a,
    localFileState: RecordingLocalFileState.ready,
    status: status,
    durationSeconds: 60,
    sizeBytes: 2048,
    isFavorite: false,
    tagIds: tagIds,
    createdAt: at,
    updatedAt: at,
    appPrivateUri: 'app-private://recordings/$recordingId/source.m4a',
    deletedAt: deletedAt,
    deviceFilename: deviceFilename,
    originalFilename: originalFilename,
    contentHash: contentHash,
    remoteRecordingId: remoteRecordingId,
  );
}

final class _DelayedUploadTokenTransport implements ApiTransport {
  final List<Completer<ApiTransportResponse>> _tokenResponses =
      <Completer<ApiTransportResponse>>[];

  int get tokenRequestCount => _tokenResponses.length;

  @override
  Future<ApiTransportResponse> send(ApiTransportRequest request) {
    if (request.url.path == '/api/v1/media/upload-token') {
      final response = Completer<ApiTransportResponse>();
      _tokenResponses.add(response);
      return response.future;
    }
    return Future<ApiTransportResponse>.value(
      const ApiTransportResponse(
        status: 404,
        body: <String, Object?>{
          'success': false,
          'error': <String, Object?>{'code': 'NOT_FOUND'},
        },
      ),
    );
  }

  void completeFailure(int index) {
    _tokenResponses[index].complete(
      const ApiTransportResponse(
        status: 503,
        body: <String, Object?>{
          'success': false,
          'error': <String, Object?>{'code': 'SERVICE_BUSY'},
        },
      ),
    );
  }
}

final class _NoProcessingObservationPort
    implements RecordingProcessingDetailObservationPort {
  const _NoProcessingObservationPort();

  @override
  void addProcessingDetailListener(VoidCallback listener) {}

  @override
  RecordingProcessingTask? processingTaskFor(String recordingId) => null;

  @override
  void removeProcessingDetailListener(VoidCallback listener) {}
}

final class _UnusedBatchTranscriptionExecutionPort
    implements RecordingBatchTranscriptionExecutionPort {
  const _UnusedBatchTranscriptionExecutionPort();

  @override
  Future<RecordingBatchSubmissionResult> retryExisting(
    RecordingBatchTranscriptionItem item,
  ) => throw StateError('batch execution is not expected');

  @override
  Future<RecordingBatchSubmissionResult> submitNew(
    RecordingBatchTranscriptionItem item,
  ) => throw StateError('batch execution is not expected');

  @override
  Future<RecordingBatchAuthoritativeUpdate> verifyExisting(
    RecordingBatchTranscriptionItem item,
  ) => throw StateError('batch execution is not expected');
}

final class _RecordingBatchExecutionSpy
    implements RecordingBatchTranscriptionExecutionPort {
  final List<String> retriedRemoteRecordingIds = <String>[];
  int submitCalls = 0;

  @override
  Future<RecordingBatchSubmissionResult> retryExisting(
    RecordingBatchTranscriptionItem item,
  ) async {
    final remoteRecordingId = item.remoteRecordingId!;
    retriedRemoteRecordingIds.add(remoteRecordingId);
    return RecordingBatchSubmissionResult.accepted(
      remoteRecordingId: remoteRecordingId,
    );
  }

  @override
  Future<RecordingBatchSubmissionResult> submitNew(
    RecordingBatchTranscriptionItem item,
  ) async {
    submitCalls += 1;
    return const RecordingBatchSubmissionResult.accepted(
      remoteRecordingId: 'unexpected-new-recording',
    );
  }

  @override
  Future<RecordingBatchAuthoritativeUpdate> verifyExisting(
    RecordingBatchTranscriptionItem item,
  ) => throw StateError('verification is not expected');
}

final class _NeverObjectUploadTransport implements ObjectUploadTransport {
  const _NeverObjectUploadTransport();

  @override
  Future<ObjectUploadResult> upload(ObjectUploadRequest request) {
    throw StateError(
      'object upload must not start while token request is pending',
    );
  }
}

final class _FakePlaybackPort implements NativePlaybackPort {
  _FakePlaybackPort({this.loadResult});

  final Future<NativePlaybackResult<NativePlaybackSnapshot>>? loadResult;
  final StreamController<NativePlaybackSnapshot> _snapshots =
      StreamController<NativePlaybackSnapshot>.broadcast();
  NativePlaybackSnapshot _snapshot = const NativePlaybackSnapshot.idle();
  int loadCalls = 0;
  int playCalls = 0;
  int pauseCalls = 0;
  int seekCalls = 0;
  int disposeCalls = 0;

  @override
  Stream<NativePlaybackSnapshot> get snapshots => _snapshots.stream;

  @override
  Future<void> dispose() async {
    disposeCalls += 1;
    await _snapshots.close();
  }

  @override
  Future<NativePlaybackResult<NativePlaybackSnapshot>> load({
    required String recordingId,
    required String appPrivateUri,
    Duration knownDuration = Duration.zero,
  }) async {
    loadCalls += 1;
    final injected = loadResult;
    if (injected != null) return injected;
    _snapshot = NativePlaybackSnapshot(
      status: NativePlaybackStatus.ready,
      recordingId: recordingId,
      duration: knownDuration,
    );
    return NativePlaybackResult.success(_snapshot);
  }

  @override
  Future<NativePlaybackResult<NativePlaybackSnapshot>> pause() async {
    pauseCalls += 1;
    _snapshot = _snapshot.copyWith(status: NativePlaybackStatus.paused);
    return NativePlaybackResult.success(_snapshot);
  }

  @override
  Future<NativePlaybackResult<NativePlaybackSnapshot>> play() async {
    playCalls += 1;
    _snapshot = _snapshot.copyWith(status: NativePlaybackStatus.playing);
    return NativePlaybackResult.success(_snapshot);
  }

  @override
  Future<NativePlaybackResult<NativePlaybackSnapshot>> release() async {
    _snapshot = _snapshot.copyWith(
      status: NativePlaybackStatus.released,
      clearRecordingId: true,
    );
    return NativePlaybackResult.success(_snapshot);
  }

  @override
  Future<NativePlaybackResult<NativePlaybackSnapshot>> seekTo(
    Duration value,
  ) async {
    seekCalls += 1;
    _snapshot = _snapshot.copyWith(position: value);
    return NativePlaybackResult.success(_snapshot);
  }

  @override
  Future<NativePlaybackResult<NativePlaybackSnapshot>> setRate(
    double value,
  ) async {
    _snapshot = _snapshot.copyWith(rate: value);
    return NativePlaybackResult.success(_snapshot);
  }
}

final class _ManagementFileStorage extends UnavailableFileStoragePort {
  const _ManagementFileStorage({this.deletedUris});

  final List<String>? deletedUris;

  @override
  Future<FileStorageResult<PrivateAudioFile>> copyPickedAudioToPrivateLibrary(
    PickedAudioFile picked,
  ) async {
    return FileStorageResult<PrivateAudioFile>.success(
      PrivateAudioFile(
        fileId: 'recordings/test',
        appPrivateUri: 'app-private://recordings/test/source.m4a',
        displayName: picked.displayName,
        mimeType: picked.mimeType,
        sizeBytes: picked.sizeBytes,
      ),
    );
  }

  @override
  Future<FileStorageResult<bool>> deletePrivateAudio(
    String appPrivateUri,
  ) async {
    deletedUris?.add(appPrivateUri);
    return FileStorageResult<bool>.success(true);
  }

  @override
  Future<FileStorageResult<PreparedAudioExport>> prepareAudioExport({
    required String appPrivateUri,
    required String displayName,
  }) async {
    return FileStorageResult<PreparedAudioExport>.success(
      PreparedAudioExport(
        opaqueExportRef:
            'app-private-export://recordings/cache/export-test/$displayName',
        displayName: displayName,
        sizeBytes: 2048,
      ),
    );
  }

  @override
  Future<FileStorageResult<PrivateAudioFileStat>> statPrivateAudio(
    String appPrivateUri,
  ) async {
    return FileStorageResult<PrivateAudioFileStat>.success(
      PrivateAudioFileStat(
        exists: true,
        sizeBytes: appPrivateUri.contains('cccccccccccccccccccccccccccccccc')
            ? 1024
            : 2048,
      ),
    );
  }

  @override
  Future<FileStorageResult<String>> hashPrivateAudio(
    String appPrivateUri,
  ) async {
    return FileStorageResult<String>.success(
      appPrivateUri.contains('cccccccccccccccccccccccccccccccc')
          ? 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'
          : 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    );
  }

  @override
  Future<FileStorageResult<bool>> updatePrivateAudioMetadata({
    required String appPrivateUri,
    required String displayName,
  }) async {
    return FileStorageResult<bool>.success(true);
  }
}

final class _RecordingExportNativeFilePort
    implements NativeFilePort, NativePreparedAudioExportPort {
  final List<String> savedRefs = <String>[];
  final List<String> openedRefs = <String>[];

  @override
  Future<NativeFileResult<List<PickedAudioFile>>> pickAudioFiles() async {
    return NativeFileResult<List<PickedAudioFile>>.success(
      const <PickedAudioFile>[],
    );
  }

  @override
  Future<NativeFileResult<bool>> savePreparedAudioExport({
    required String opaqueExportRef,
    required String displayName,
    required String mimeType,
  }) async {
    savedRefs.add(opaqueExportRef);
    return NativeFileResult<bool>.success(true);
  }

  @override
  Future<NativeFileResult<bool>> openPreparedAudioExport({
    required String opaqueExportRef,
    required String displayName,
    required String mimeType,
  }) async {
    openedRefs.add(opaqueExportRef);
    return NativeFileResult<bool>.success(true);
  }
}

final class _GrantedPermissionsPort implements PlatformPermissionsPort {
  const _GrantedPermissionsPort();

  @override
  Future<PlatformPermissionResult<BluetoothActivationResult>>
  requestBluetoothActivation() async =>
      PlatformPermissionResult<BluetoothActivationResult>.success(
        BluetoothActivationResult.unavailable,
      );

  @override
  Future<PlatformPermissionResult<List<PlatformPermissionSummary>>>
  loadPermissionSummary() async {
    return PlatformPermissionResult<List<PlatformPermissionSummary>>.success(
      const <PlatformPermissionSummary>[],
    );
  }

  @override
  Future<PlatformPermissionResult<PermissionSettingsOpenReceipt>>
  openAppSettings(
    PlatformPermissionKind kind, {
    required bool impactAcknowledged,
  }) async {
    return PlatformPermissionResult<PermissionSettingsOpenReceipt>.success(
      PermissionSettingsOpenReceipt(
        kind: kind,
        opened: impactAcknowledged,
        impactText: buildPermissionImpactText(kind),
      ),
    );
  }

  @override
  Future<PlatformPermissionResult<List<PlatformPermissionSummary>>>
  requestPermissions(Set<PlatformPermissionKind> kinds) async {
    return PlatformPermissionResult<List<PlatformPermissionSummary>>.success(
      kinds
          .map(
            (kind) => PlatformPermissionSummary(
              kind: kind,
              status: PlatformPermissionStatus.granted,
              recoveryAction: PermissionRecoveryAction.none,
              impactText: buildPermissionImpactText(kind),
            ),
          )
          .toList(growable: false),
    );
  }
}
