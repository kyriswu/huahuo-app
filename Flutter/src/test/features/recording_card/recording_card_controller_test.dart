import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/api/api_envelope.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/database/recording_dao.dart';
import 'package:huahuoai_app/core/native/native_file_port.dart';
import 'package:huahuoai_app/core/native/platform_permissions_port.dart';
import 'package:huahuoai_app/core/native/recording_card_native_port.dart';
import 'package:huahuoai_app/core/storage/file_storage_port.dart';
import 'package:huahuoai_app/features/recording_card/application/recording_card_auto_sync_coordinator.dart';
import 'package:huahuoai_app/features/recording_card/application/recording_card_controller.dart';
import 'package:huahuoai_app/features/recording_card/data/recording_card_sync_ledger_store.dart';
import 'package:huahuoai_app/features/recording_card/domain/recording_card_account_binding.dart';
import 'package:huahuoai_app/features/recording_card/domain/recording_card_connection_history.dart';
import 'package:huahuoai_app/features/recording_card/domain/recording_card_sync_ledger.dart';
import 'package:huahuoai_app/features/recordings/data/local_recording_repository.dart';
import 'package:huahuoai_app/features/recordings/domain/recording_library.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('RecordingCardController', () {
    test(
      'resident recording listener accepts samples and replacement card immediately',
      () async {
        var now = DateTime.utc(2026, 9, 7, 9);
        final port = _FakeRecordingCardPort();
        final controller = _controllerFor(port, clock: () => now);
        addTearDown(controller.dispose);
        await controller.connect();
        await _awaitAutomaticScan(controller, port);
        void publish(int revision, RecordingCardRecordingInfo info) {
          port.emit(
            port.runtimeSnapshot.copyWith(
              recordingInfo: info,
              recordingObservation: RecordingCardRecordingObservation(
                info: info,
                source: RecordingCardObservationSource.statusNotification,
                revision: revision,
                observedAt: now,
              ),
            ),
          );
        }

        publish(
          50,
          const RecordingCardRecordingInfo(
            state: RecordingCardRecordingState.recording,
          ),
        );
        expect(controller.state.snapshot.recordingInfo.startedAt, now);
        now = now.add(const Duration(seconds: 10));
        publish(
          51,
          const RecordingCardRecordingInfo(
            state: RecordingCardRecordingState.recording,
            durationSeconds: 12,
          ),
        );
        expect(
          recordingCardElapsedSeconds(
            controller.state.snapshot.recordingInfo,
            now: now,
          ),
          12,
        );
        now = now.add(const Duration(seconds: 80));
        const info = RecordingCardRecordingInfo(
          state: RecordingCardRecordingState.recording,
        );
        port.emit(
          port.runtimeSnapshot.copyWith(
            deviceState: const RecordingCardDeviceState(
              connectionState: RecordingCardConnectionState.connected,
              safeDeviceFingerprint: 'replacement-clock-card',
            ),
            recordingInfo: info,
            recordingObservation: RecordingCardRecordingObservation(
              info: info,
              source: RecordingCardObservationSource.statusNotification,
              revision: 1,
              observedAt: now,
            ),
          ),
        );
        expect(controller.state.snapshot.recordingObservation?.revision, 1);
        expect(controller.state.snapshot.recordingInfo.startedAt, now);
        expect(
          recordingCardElapsedSeconds(
            controller.state.snapshot.recordingInfo,
            now: now,
          ),
          0,
        );
      },
    );

    test('binding token grammar stays separate from staged file IDs', () async {
      final token = await recordingCardBindingTokenFor(
        Future<String>.value('install-identity'),
      );

      expect(token, matches(RegExp(r'^[a-f0-9]{32}$')));
      expect(isRecordingCardBindingToken(token), isTrue);
      expect(isRecordingCardBindingToken('card-$token'), isFalse);
    });

    test(
      'connect and mock native snapshot event update shared state',
      () async {
        final port = _FakeRecordingCardPort();
        final controller = _controllerFor(port);
        addTearDown(controller.dispose);

        await controller.connect();
        await _awaitAutomaticScan(controller, port);
        port.emit(
          port.runtimeSnapshot.copyWith(
            recordingInfo: const RecordingCardRecordingInfo(
              state: RecordingCardRecordingState.recording,
            ),
            recordingObservation: RecordingCardRecordingObservation(
              info: const RecordingCardRecordingInfo(
                state: RecordingCardRecordingState.recording,
              ),
              source: RecordingCardObservationSource.statusNotification,
              revision: 1,
              observedAt: DateTime.utc(2026, 7, 15, 9),
            ),
          ),
        );

        expect(controller.state.status, RecordingCardControllerStatus.idle);
        expect(
          controller.state.snapshot.deviceState.connectionState,
          RecordingCardConnectionState.connected,
        );
        expect(
          controller.state.snapshot.recordingInfo.state,
          RecordingCardRecordingState.recording,
        );
        expect(controller.state.lastErrorCode, isNull);
      },
    );

    test(
      'cloud gate keeps connection provisional and runs again after reconnect',
      () async {
        final port = _FakeRecordingCardPort();
        final history = InMemoryRecordingCardConnectionHistory();
        final authorization = _FakeConnectionAuthorization.pending();
        final controller = _controllerFor(
          port,
          connectionAuthorization: authorization,
          connectionHistory: history,
        );
        addTearDown(controller.dispose);

        final firstConnect = controller.connect();
        await _waitFor(() => authorization.callCount == 1);

        expect(
          controller.state.status,
          RecordingCardControllerStatus.authorizing,
        );
        expect(
          controller.state.snapshot.deviceState.connectionState,
          RecordingCardConnectionState.connecting,
        );
        expect(port.scanFilesCallCount, 0);
        expect(history.load(), isEmpty);

        authorization.completeSuccess();
        await firstConnect;
        await _awaitAutomaticScan(controller, port);
        expect(
          controller.state.snapshot.deviceState.isOperationallyConnected,
          isTrue,
        );
        expect(history.load(), hasLength(1));

        await controller.disconnect();
        await controller.connect();
        await _awaitAutomaticScan(controller, port, minimumCalls: 2);

        expect(authorization.callCount, 2);
        expect(port.connectCallCount, 2);
        expect(port.disconnectCallCount, 1);
      },
    );

    test(
      'explicit cloud authorization adopts recording state received while pending',
      () async {
        final port = _FakeRecordingCardPort();
        final authorization = _FakeConnectionAuthorization.pending();
        final controller = _controllerFor(
          port,
          connectionAuthorization: authorization,
        );
        addTearDown(controller.dispose);

        final connection = controller.connect();
        await _waitFor(() => authorization.callCount == 1);
        const recording = RecordingCardRecordingInfo(
          state: RecordingCardRecordingState.recording,
          currentFileName: '25090512000001',
        );
        port.emit(
          port.runtimeSnapshot.copyWith(
            recordingInfo: recording,
            recordingObservation: RecordingCardRecordingObservation(
              info: recording,
              source: RecordingCardObservationSource.statusNotification,
              revision: 1,
              observedAt: DateTime.utc(2026, 9, 5, 12),
            ),
          ),
        );

        expect(
          controller.state.status,
          RecordingCardControllerStatus.authorizing,
        );
        expect(
          controller.state.snapshot.recordingInfo.state,
          RecordingCardRecordingState.idle,
        );
        authorization.completeSuccess();
        await connection;

        expect(controller.state.status, RecordingCardControllerStatus.idle);
        expect(
          controller.state.snapshot.recordingInfo.state,
          RecordingCardRecordingState.recording,
        );
        expect(
          controller.state.snapshot.recordingInfo.currentFileName,
          '25090512000001',
        );
        expect(port.scanFilesCallCount, 0);
      },
    );

    test('cloud gate rejection forcibly disconnects and never scans', () async {
      final port = _FakeRecordingCardPort();
      final history = InMemoryRecordingCardConnectionHistory();
      final authorization = _FakeConnectionAuthorization.failure(
        'RECORDING_CARD_ALREADY_BOUND',
      );
      final controller = _controllerFor(
        port,
        connectionAuthorization: authorization,
        connectionHistory: history,
      );
      addTearDown(controller.dispose);

      await controller.connect();

      expect(authorization.callCount, 1);
      expect(port.disconnectCallCount, 1);
      expect(controller.state.status, RecordingCardControllerStatus.error);
      expect(controller.state.lastErrorCode, 'RECORDING_CARD_ALREADY_BOUND');
      expect(
        controller.state.snapshot.deviceState.isOperationallyConnected,
        isFalse,
      );
      expect(port.scanFilesCallCount, 0);
      expect(history.load(), isEmpty);
    });

    test(
      'unsolicited native connection also passes through cloud gate',
      () async {
        final port = _FakeRecordingCardPort();
        final authorization = _FakeConnectionAuthorization.success();
        final controller = _controllerFor(
          port,
          connectionAuthorization: authorization,
        );
        addTearDown(controller.dispose);

        port.emit(
          port.runtimeSnapshot.copyWith(
            deviceState: const RecordingCardDeviceState(
              connectionState: RecordingCardConnectionState.connected,
              connectionStage: RecordingCardConnectionStage.connected,
              displayName: 'Huahuo FW920',
              safeDeviceFingerprint: 'restored-card-fingerprint',
            ),
          ),
        );
        await _waitFor(() => authorization.callCount == 1);
        await _awaitAutomaticScan(controller, port);

        expect(
          controller.state.snapshot.deviceState.isOperationallyConnected,
          isTrue,
        );
        expect(controller.state.status, RecordingCardControllerStatus.idle);
      },
    );

    test(
      'physical recording observation owns timer until explicit newer stop',
      () async {
        var now = DateTime.utc(2026, 7, 17, 13);
        final port = _FakeRecordingCardPort();
        final controller = _controllerFor(port, clock: () => now);
        addTearDown(controller.dispose);
        await controller.connect();
        await _awaitAutomaticScan(controller, port);

        port.emit(
          port.runtimeSnapshot.copyWith(
            recordingInfo: const RecordingCardRecordingInfo(
              state: RecordingCardRecordingState.recording,
            ),
            recordingObservation: RecordingCardRecordingObservation(
              info: const RecordingCardRecordingInfo(
                state: RecordingCardRecordingState.recording,
              ),
              source: RecordingCardObservationSource.statusNotification,
              revision: 10,
              observedAt: now,
            ),
          ),
        );
        expect(controller.state.snapshot.recordingInfo.startedAt, now);

        now = now.add(const Duration(seconds: 14));
        port.emit(
          RecordingCardRuntimeSnapshot(
            deviceState: port.runtimeSnapshot.deviceState,
            recordingInfo: RecordingCardRecordingInfo.idle(),
            files: port.runtimeSnapshot.files,
            discoveredDevices: port.runtimeSnapshot.discoveredDevices,
            lastDeviceUpdatedAt: now,
          ),
        );
        expect(
          controller.state.snapshot.recordingInfo.state,
          RecordingCardRecordingState.recording,
        );
        expect(
          recordingCardElapsedSeconds(
            controller.state.snapshot.recordingInfo,
            now: now,
          ),
          14,
        );

        port.emit(
          port.runtimeSnapshot.copyWith(
            recordingInfo: RecordingCardRecordingInfo.idle(),
            recordingObservation: RecordingCardRecordingObservation(
              info: RecordingCardRecordingInfo.idle(),
              source: RecordingCardObservationSource.deviceInfo,
              revision: 9,
              observedAt: now,
            ),
          ),
        );
        expect(
          controller.state.snapshot.recordingInfo.state,
          RecordingCardRecordingState.recording,
        );

        port.emit(
          port.runtimeSnapshot.copyWith(
            recordingInfo: RecordingCardRecordingInfo.idle(),
            recordingObservation: RecordingCardRecordingObservation(
              info: RecordingCardRecordingInfo.idle(),
              source: RecordingCardObservationSource.statusNotification,
              revision: 11,
              observedAt: now,
            ),
          ),
        );
        expect(
          controller.state.snapshot.recordingInfo.state,
          RecordingCardRecordingState.idle,
        );
        expect(controller.state.snapshot.recordingInfo.durationSeconds, 0);
        expect(controller.state.snapshot.recordingInfo.startedAt, isNull);
      },
    );

    test(
      'requests Android Bluetooth permission before scan and connect',
      () async {
        final operations = <String>[];
        final port = _FakeRecordingCardPort(operationLog: operations);
        final permissions = _FakePlatformPermissionsPort(
          operationLog: operations,
        );
        final controller = _controllerFor(
          port,
          platformPermissionsPort: permissions,
          requiresBluetoothPermissionRequest: () => true,
        );
        addTearDown(controller.dispose);

        await controller.scanDevices();
        await controller.connect();
        await _awaitAutomaticScan(controller, port);

        expect(operations, <String>[
          'permission',
          'scan',
          'permission',
          'connect',
          'scanFiles',
        ]);
        expect(permissions.requestedKinds, <Set<PlatformPermissionKind>>[
          <PlatformPermissionKind>{PlatformPermissionKind.bluetooth},
          <PlatformPermissionKind>{PlatformPermissionKind.bluetooth},
        ]);
      },
    );

    test(
      'denied Android Bluetooth permission prevents BLE operations',
      () async {
        final port = _FakeRecordingCardPort();
        final controller = _controllerFor(
          port,
          platformPermissionsPort: _FakePlatformPermissionsPort(
            statuses: const <PlatformPermissionKind, PlatformPermissionStatus>{
              PlatformPermissionKind.bluetooth: PlatformPermissionStatus.denied,
            },
          ),
          requiresBluetoothPermissionRequest: () => true,
        );
        addTearDown(controller.dispose);

        await controller.scanDevices();

        expect(port.scanDevicesCallCount, 0);
        expect(controller.state.status, RecordingCardControllerStatus.error);
        expect(
          controller.state.lastErrorCode,
          'RECORDING_CARD_BLUETOOTH_PERMISSION_REQUIRED',
        );
      },
    );

    test(
      'recording controls transition through one runtime snapshot',
      () async {
        final port = _FakeRecordingCardPort();
        final controller = _controllerFor(port);
        addTearDown(controller.dispose);
        await controller.connect();

        await controller.startRecording();
        expect(
          controller.state.snapshot.recordingInfo.state,
          RecordingCardRecordingState.recording,
        );

        await controller.pauseRecording();
        expect(
          controller.state.snapshot.recordingInfo.state,
          RecordingCardRecordingState.paused,
        );

        await controller.resumeRecording();
        expect(
          controller.state.snapshot.recordingInfo.state,
          RecordingCardRecordingState.recording,
        );

        await controller.stopRecording();
        expect(
          controller.state.snapshot.recordingInfo.state,
          RecordingCardRecordingState.idle,
        );
        expect(controller.state.status, RecordingCardControllerStatus.idle);
      },
    );

    test(
      'foreground resume joins the recording completion directory scan',
      () async {
        final port = _FakeRecordingCardPort();
        final controller = RecordingCardController(
          port: port,
          localRecordingRepository: _repository(),
          platformPermissionsPort: _FakePlatformPermissionsPort(),
          bindingTokenProvider: _bindingToken,
          recordingCompletionScanDelays: const <Duration>[
            Duration(milliseconds: 20),
          ],
        );
        addTearDown(controller.dispose);
        await controller.connect();
        await _awaitAutomaticScan(controller, port);
        final scanCountBeforeRecording = port.scanFilesCallCount;
        final queryCountBeforeRecording = port.getConnectionStateCallCount;
        final infoCountBeforeRecording = port.refreshDeviceInfoCallCount;
        var completionOwnerWasLatchedForReading = false;
        controller.addListener(() {
          if (controller.state.fileCatalog.phase ==
                  RecordingCardFileCatalogPhase.reading &&
              controller.hasPendingRecordingCompletionRefresh) {
            completionOwnerWasLatchedForReading = true;
          }
        });

        await controller.startRecording();
        await controller.stopRecording();
        final foreground = controller.reconcileConnectionState(
          refreshDirectory: true,
        );
        expect(controller.canRefreshFilesNow, isFalse);
        await foreground;

        expect(port.scanFilesCallCount, scanCountBeforeRecording + 1);
        expect(port.getConnectionStateCallCount, queryCountBeforeRecording + 1);
        expect(port.refreshDeviceInfoCallCount, infoCountBeforeRecording + 1);
        expect(completionOwnerWasLatchedForReading, isTrue);
        expect(controller.canRefreshFilesNow, isTrue);
      },
    );

    test(
      'same-card command cannot consume the recording settlement refresh',
      () async {
        final port = _FakeRecordingCardPort();
        final controller = RecordingCardController(
          port: port,
          localRecordingRepository: _repository(),
          platformPermissionsPort: _FakePlatformPermissionsPort(),
          bindingTokenProvider: _bindingToken,
          recordingCompletionScanDelays: const <Duration>[
            Duration(milliseconds: 30),
          ],
        );
        addTearDown(controller.dispose);
        await controller.connect();
        await _awaitAutomaticScan(controller, port);
        final scanCount = port.scanFilesCallCount;

        await controller.startRecording();
        await controller.stopRecording();
        final renamed = await controller.setBluetoothName('无限花火录音卡');

        expect(renamed.ok, isTrue);
        await Future<void>.delayed(const Duration(milliseconds: 40));
        await _waitFor(() => port.scanFilesCallCount == scanCount + 1);
        expect(controller.state.fileCatalog.isReady, isTrue);
      },
    );

    test(
      'failed recording settlement retries within the bounded delay sequence',
      () async {
        final port = _FakeRecordingCardPort();
        final controller = RecordingCardController(
          port: port,
          localRecordingRepository: _repository(),
          platformPermissionsPort: _FakePlatformPermissionsPort(),
          bindingTokenProvider: _bindingToken,
          recordingCompletionScanDelays: const <Duration>[
            Duration.zero,
            Duration(milliseconds: 5),
            Duration(milliseconds: 10),
          ],
        );
        addTearDown(controller.dispose);
        await controller.connect();
        await _awaitAutomaticScan(controller, port);
        final scanCount = port.scanFilesCallCount;

        await controller.startRecording();
        port._directoryFiles = <RecordingCardScannedFile>[
          port.scannedFile,
          _fileWithId(2),
        ];
        port.failNextScan = true;
        await controller.stopRecording();
        await Future<void>.delayed(const Duration(milliseconds: 30));

        expect(port.scanFilesCallCount, scanCount + 2);
        expect(
          controller.state.fileCatalog.phase,
          RecordingCardFileCatalogPhase.ready,
        );
        expect(controller.state.lastErrorCode, isNull);
        expect(controller.hasPendingRecordingCompletionRefresh, isFalse);
      },
    );

    test(
      'recording completion blocked by transfer is consumed once after release',
      () async {
        final port = _FakeRecordingCardPort();
        final controller = RecordingCardController(
          port: port,
          localRecordingRepository: _repository(),
          platformPermissionsPort: _FakePlatformPermissionsPort(),
          bindingTokenProvider: _bindingToken,
          recordingCompletionScanDelays: const <Duration>[Duration.zero],
        );
        addTearDown(controller.dispose);
        await controller.connect();
        await _awaitAutomaticScan(controller, port);
        final scanCount = port.scanFilesCallCount;
        final deferred =
            Completer<RecordingCardResult<RecordingCardDownloadedFile>>();
        port.bleDownloadCompleter = deferred;

        final transfer = controller.downloadFile(
          controller.state.snapshot.files.single,
          refreshAfterTransfer: false,
        );
        await _waitFor(() => port.bleDownloadCallCount == 1);
        final observedAt = DateTime.utc(2026, 9, 4, 10);
        for (var revision = 1; revision <= 4; revision += 1) {
          final recordingState = revision.isOdd
              ? RecordingCardRecordingState.recording
              : RecordingCardRecordingState.idle;
          final info = RecordingCardRecordingInfo(state: recordingState);
          port.emit(
            port.runtimeSnapshot.copyWith(
              recordingInfo: info,
              recordingObservation: RecordingCardRecordingObservation(
                info: info,
                source: RecordingCardObservationSource.statusNotification,
                revision: revision,
                observedAt: observedAt.add(Duration(seconds: revision)),
              ),
            ),
          );
        }
        port.failNextScan = true;
        deferred.complete(
          RecordingCardResult<RecordingCardDownloadedFile>.failure(
            _failure('RECORDING_CARD_TRANSFER_CANCELLED'),
          ),
        );

        await transfer;
        await _waitFor(() => port.scanFilesCallCount == scanCount + 1);
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        expect(port.scanFilesCallCount, scanCount + 1);
        expect(controller.hasActiveTransfer, isFalse);
        expect(controller.state.lastErrorCode, 'RECORDING_CARD_SCAN_FAILED');
      },
    );

    test(
      'recording completion keeps the file baseline frozen at the idle edge',
      () async {
        final port = _FakeRecordingCardPort();
        final controller = RecordingCardController(
          port: port,
          localRecordingRepository: _repository(),
          platformPermissionsPort: _FakePlatformPermissionsPort(),
          bindingTokenProvider: _bindingToken,
          recordingCompletionScanDelays: const <Duration>[
            Duration.zero,
            Duration(milliseconds: 5),
            Duration(milliseconds: 10),
          ],
        );
        addTearDown(controller.dispose);
        await controller.connect();
        await _awaitAutomaticScan(controller, port);
        final scanCount = port.scanFilesCallCount;
        final transferResult =
            Completer<RecordingCardResult<RecordingCardDownloadedFile>>();
        port.bleDownloadCompleter = transferResult;
        final transfer = controller.downloadFile(
          controller.state.snapshot.files.single,
          refreshAfterTransfer: false,
        );
        await _waitFor(() => port.bleDownloadCallCount == 1);

        final observedAt = DateTime.utc(2026, 9, 5, 12);
        const recording = RecordingCardRecordingInfo(
          state: RecordingCardRecordingState.recording,
        );
        port.emit(
          port.runtimeSnapshot.copyWith(
            recordingInfo: recording,
            recordingObservation: RecordingCardRecordingObservation(
              info: recording,
              source: RecordingCardObservationSource.statusNotification,
              revision: 1,
              observedAt: observedAt,
            ),
          ),
        );
        final idle = RecordingCardRecordingInfo.idle();
        port.emit(
          port.runtimeSnapshot.copyWith(
            recordingInfo: idle,
            recordingObservation: RecordingCardRecordingObservation(
              info: idle,
              source: RecordingCardObservationSource.statusNotification,
              revision: 2,
              observedAt: observedAt.add(const Duration(seconds: 1)),
            ),
          ),
        );
        port.emitFileDirectory(<RecordingCardScannedFile>[
          port.scannedFile,
          _fileWithId(2),
        ]);
        transferResult.complete(
          RecordingCardResult<RecordingCardDownloadedFile>.failure(
            _failure('RECORDING_CARD_TRANSFER_CANCELLED'),
          ),
        );

        await transfer;
        await _waitFor(() => port.scanFilesCallCount == scanCount + 1);
        await Future<void>.delayed(const Duration(milliseconds: 25));

        expect(port.scanFilesCallCount, scanCount + 1);
        expect(controller.hasPendingRecordingCompletionRefresh, isFalse);
      },
    );

    test(
      'device unbind forwards binding token and retains local recordings',
      () async {
        final port = _FakeRecordingCardPort();
        final repository = _repository();
        final controller = RecordingCardController(
          port: port,
          localRecordingRepository: repository,
          platformPermissionsPort: _FakePlatformPermissionsPort(),
          bindingTokenProvider: _bindingToken,
        );
        addTearDown(controller.dispose);
        await controller.connect();
        await controller.scanFiles();
        await controller.downloadFile(port.scannedFile);
        expect(repository.list().rows, hasLength(1));

        await controller.unbindDevice(deleteDeviceFiles: true);

        expect(port.unbindCallCount, 1);
        expect(port.unbindBindingToken, '0123456789abcdef0123456789abcdef');
        expect(port.unbindDeleteDeviceFiles, isTrue);
        expect(controller.state.status, RecordingCardControllerStatus.idle);
        expect(
          controller.state.snapshot.deviceState.connectionState,
          RecordingCardConnectionState.disconnected,
        );
        expect(
          controller.state.snapshot.recordingInfo.state,
          RecordingCardRecordingState.idle,
        );
        expect(controller.state.snapshot.files, isEmpty);
        expect(repository.list().rows, hasLength(1));
      },
    );

    test(
      'device unbind freezes its card while resolving the binding token',
      () async {
        final port = _FakeRecordingCardPort();
        final deferredToken = Completer<String>();
        var tokenCallCount = 0;
        final controller = RecordingCardController(
          port: port,
          localRecordingRepository: _repository(),
          platformPermissionsPort: _FakePlatformPermissionsPort(),
          bindingTokenProvider: () {
            tokenCallCount += 1;
            return tokenCallCount == 1
                ? Future<String>.value('0123456789abcdef0123456789abcdef')
                : deferredToken.future;
          },
        );
        addTearDown(controller.dispose);
        await controller.connect();
        await _awaitAutomaticScan(controller, port);

        final unbind = controller.unbindDevice(deleteDeviceFiles: true);
        await _waitFor(
          () =>
              controller.state.status ==
              RecordingCardControllerStatus.unbinding,
        );
        await controller.connect(
          request: const RecordingCardConnectRequest(
            displayName: 'Huahuo FW920 B',
            safeDeviceFingerprint: 'card-fingerprint-2',
          ),
        );
        expect(port.connectCallCount, 1);

        const cardB = RecordingCardDeviceState(
          connectionState: RecordingCardConnectionState.connected,
          connectionStage: RecordingCardConnectionStage.connected,
          displayName: 'Huahuo FW920 B',
          safeDeviceFingerprint: 'card-fingerprint-2',
          recordingFormat: RecordingCardFileFormat.m4a,
        );
        port.emit(
          port.runtimeSnapshot.copyWith(
            deviceState: cardB,
            files: const <RecordingCardScannedFile>[],
          ),
        );
        deferredToken.complete('0123456789abcdef0123456789abcdef');
        await unbind;
        await _awaitAutomaticScan(controller, port, minimumCalls: 2);

        expect(port.unbindCallCount, 0);
        expect(port.scanFilesCallCount, 2);
        expect(controller.state.status, RecordingCardControllerStatus.idle);
        expect(
          controller.state.snapshot.deviceState.safeDeviceFingerprint,
          'card-fingerprint-2',
        );
      },
    );

    test(
      'device unbind rejects active recording before native invocation',
      () async {
        final port = _FakeRecordingCardPort();
        final controller = _controllerFor(port);
        addTearDown(controller.dispose);
        await controller.connect();
        await _awaitAutomaticScan(controller, port);
        await controller.startRecording();

        await controller.unbindDevice();

        expect(port.unbindCallCount, 0);
        expect(
          controller.state.lastErrorCode,
          'RECORDING_CARD_UNBIND_RECORDING_ACTIVE',
        );
        expect(
          controller.state.snapshot.deviceState.isOperationallyConnected,
          isTrue,
        );
      },
    );

    test(
      'Bluetooth name update forwards a validated UTF-8 name and updates the shared device state',
      () async {
        final port = _FakeRecordingCardPort();
        final controller = _controllerFor(port);
        addTearDown(controller.dispose);
        await controller.connect();
        await _awaitAutomaticScan(controller, port);

        final result = await controller.setBluetoothName('无限花火录音卡');

        expect(result.ok, isTrue);
        expect(port.bluetoothNameCallCount, 1);
        expect(port.bluetoothNames, <String>['无限花火录音卡']);
        expect(controller.state.snapshot.deviceState.displayName, '无限花火录音卡');
        expect(controller.state.status, RecordingCardControllerStatus.idle);
        expect(controller.state.lastErrorCode, isNull);
      },
    );

    test(
      'Bluetooth name update fails closed before native access and preserves a connected card on rejection',
      () async {
        final port = _FakeRecordingCardPort();
        final controller = _controllerFor(port);
        addTearDown(controller.dispose);

        final disconnected = await controller.setBluetoothName('无限花火');
        expect(disconnected.ok, isFalse);
        expect(
          disconnected.error?.code,
          'RECORDING_CARD_BLUETOOTH_NAME_NOT_CONNECTED',
        );
        expect(port.bluetoothNameCallCount, 0);

        await controller.connect();
        await _awaitAutomaticScan(controller, port);
        final invalid = await controller.setBluetoothName('花' * 11);
        expect(invalid.ok, isFalse);
        expect(invalid.error?.code, 'RECORDING_CARD_BLUETOOTH_NAME_INVALID');
        expect(port.bluetoothNameCallCount, 0);

        await controller.startRecording();
        final recording = await controller.setBluetoothName('无限花火');
        expect(recording.ok, isFalse);
        expect(
          recording.error?.code,
          'RECORDING_CARD_BLUETOOTH_NAME_RECORDING_ACTIVE',
        );
        expect(port.bluetoothNameCallCount, 0);
        await controller.stopRecording();

        port.failNextBluetoothName = true;
        final rejected = await controller.setBluetoothName('无限花火');
        expect(rejected.ok, isFalse);
        expect(rejected.error?.code, 'RECORDING_CARD_BLUETOOTH_NAME_REJECTED');
        expect(port.bluetoothNameCallCount, 1);
        expect(
          controller.state.snapshot.deviceState.isOperationallyConnected,
          isTrue,
        );
        expect(
          controller.state.lastErrorCode,
          'RECORDING_CARD_BLUETOOTH_NAME_REJECTED',
        );
      },
    );

    test(
      'account claim requires connected idle hardware and stays opaque',
      () async {
        final port = _FakeRecordingCardPort();
        final controller = _controllerFor(port);
        addTearDown(controller.dispose);

        final disconnected = await controller.readAccountBindingClaim();
        expect(disconnected.ok, isFalse);
        expect(
          disconnected.error?.code,
          'RECORDING_CARD_ACCOUNT_BIND_NOT_CONNECTED',
        );
        expect(port.accountClaimCallCount, 0);

        await controller.connect();
        await _awaitAutomaticScan(controller, port);
        final connected = await controller.readAccountBindingClaim();
        expect(connected.ok, isTrue);
        expect(connected.value?.opaqueClaim, 'a' * 64);
        expect(port.accountClaimCallCount, 1);
        expect(controller.state.status, RecordingCardControllerStatus.idle);

        await controller.startRecording();
        final recording = await controller.readAccountBindingClaim();
        expect(recording.ok, isFalse);
        expect(
          recording.error?.code,
          'RECORDING_CARD_ACCOUNT_BIND_RECORDING_ACTIVE',
        );
        expect(port.accountClaimCallCount, 1);
      },
    );

    test('native unbind rejection preserves connected runtime', () async {
      final port = _FakeRecordingCardPort()..failNextUnbind = true;
      final controller = _controllerFor(port);
      addTearDown(controller.dispose);
      await controller.connect();
      await controller.scanFiles();

      await controller.unbindDevice();

      expect(port.unbindCallCount, 1);
      expect(controller.state.status, RecordingCardControllerStatus.error);
      expect(controller.state.lastErrorCode, 'RECORDING_CARD_UNBIND_REJECTED');
      expect(
        controller.state.snapshot.deviceState.isOperationallyConnected,
        isTrue,
      );
      expect(controller.state.snapshot.files, isNotEmpty);
    });

    test(
      'unrelated and stale snapshots cannot interrupt recording timer',
      () async {
        var now = DateTime.utc(2026, 7, 15, 9);
        final port = _FakeRecordingCardPort();
        final controller = _controllerFor(port, clock: () => now);
        addTearDown(controller.dispose);
        await controller.connect();
        await _awaitAutomaticScan(controller, port);

        await controller.startRecording();
        now = now.add(const Duration(seconds: 25));
        port.emit(
          port.runtimeSnapshot.copyWith(
            files: <RecordingCardScannedFile>[port.scannedFile],
          ),
        );

        expect(
          recordingCardElapsedSeconds(
            controller.state.snapshot.recordingInfo,
            now: now,
          ),
          25,
        );

        port.emit(
          port.runtimeSnapshot.copyWith(
            recordingInfo: RecordingCardRecordingInfo.idle(),
            recordingObservation: RecordingCardRecordingObservation(
              info: RecordingCardRecordingInfo.idle(),
              source: RecordingCardObservationSource.deviceInfo,
              revision: 0,
              observedAt: now,
            ),
          ),
        );
        expect(
          controller.state.snapshot.recordingInfo.state,
          RecordingCardRecordingState.recording,
        );

        port.emit(
          port.runtimeSnapshot.copyWith(
            recordingInfo: RecordingCardRecordingInfo.idle(),
            recordingObservation: RecordingCardRecordingObservation(
              info: RecordingCardRecordingInfo.idle(),
              source: RecordingCardObservationSource.statusNotification,
              revision: 1,
              observedAt: now,
            ),
          ),
        );
        expect(
          controller.state.snapshot.recordingInfo.state,
          RecordingCardRecordingState.idle,
        );
        expect(controller.state.snapshot.recordingInfo.durationSeconds, 0);
      },
    );

    test(
      'transfer progress can be cancelled without registering a file',
      () async {
        final port = _FakeRecordingCardPort();
        final controller = _controllerFor(port);
        addTearDown(controller.dispose);
        await controller.connect();
        await controller.scanFiles();
        port.emit(
          port.runtimeSnapshot.copyWith(
            downloadingFileKey: port.scannedFile.localFileKey,
            transferProgress: RecordingCardTransferProgress(
              localFileKey: port.scannedFile.localFileKey,
              receivedBytes: 1024,
              totalBytes: 4096,
              correlationId: 'transfer-test',
            ),
          ),
        );

        expect(controller.state.snapshot.transferProgress?.fraction, .25);
        await controller.cancelFileTransfer();

        expect(port.cancelCallCount, 1);
        expect(controller.state.snapshot.transferProgress, isNull);
        expect(controller.state.lastDownloadedFile, isNull);
        expect(_repository().list().rows, isEmpty);
      },
    );

    test(
      'direct cancellation is coalesced and waits for transfer settlement',
      () async {
        final port = _FakeRecordingCardPort();
        final controller = _controllerFor(port);
        addTearDown(controller.dispose);
        await controller.connect();
        await _awaitAutomaticScan(controller, port);
        final downloadGate =
            Completer<RecordingCardResult<RecordingCardDownloadedFile>>();
        final cancelGate = Completer<RecordingCardResult<bool>>();
        port.bleDownloadCompleter = downloadGate;
        port.cancelCompleter = cancelGate;
        final transfer = controller.downloadFile(
          port.scannedFile,
          refreshAfterTransfer: false,
        );
        await _waitFor(() => port.bleDownloadCallCount == 1);
        final firstCancel = controller.cancelFileTransfer();
        final secondCancel = controller.cancelFileTransfer();
        expect(identical(firstCancel, secondCancel), isTrue);
        await _waitFor(() => port.cancelCallCount == 1);
        cancelGate.complete(RecordingCardResult<bool>.success(true));
        await firstCancel;
        expect(controller.hasActiveTransfer, isTrue);
        expect(
          controller.state.operation.phase,
          RecordingCardOperationPhase.cancelling,
        );
        expect(
          controller.state.status,
          RecordingCardControllerStatus.cancellingTransfer,
        );
        downloadGate.complete(
          RecordingCardResult<RecordingCardDownloadedFile>.failure(
            _failure('RECORDING_CARD_TRANSFER_CANCELLED'),
          ),
        );
        await transfer;
        expect(controller.hasActiveTransfer, isFalse);
        expect(
          controller.state.operation.phase,
          RecordingCardOperationPhase.cancelled,
        );
        expect(controller.state.status, RecordingCardControllerStatus.idle);
        expect(controller.state.lastDownloadedFile, isNull);
      },
    );

    test(
      'user BLE cancellation clears the whole batch resume intent before native acknowledgement',
      () async {
        const accountScope = 'bluetooth-pre-cancel-persistence-account';
        const serialNumber = 'CARD-BLE-PRE-CANCEL-001';
        final database = AppDatabase();
        final repository = LocalRecordingRepository(
          database: database,
          fileStorage: const _RecordingCardFileStorage(),
          accountScope: accountScope,
        );
        final ledger = RecordingCardSyncLedgerStore(
          database: database,
          accountScope: accountScope,
        );
        final files = <RecordingCardScannedFile>[
          _fileWithId(1),
          _fileWithId(2),
        ];
        final downloadGate =
            Completer<RecordingCardResult<RecordingCardDownloadedFile>>();
        final cancelGate = Completer<RecordingCardResult<bool>>();
        final port = _FakeRecordingCardPort(serialNumber: serialNumber)
          ..bleDownloadCompletersByDeviceFileId[files.first.deviceFileId] =
              downloadGate
          ..cancelCompleter = cancelGate;
        final controller = RecordingCardController(
          port: port,
          localRecordingRepository: repository,
          platformPermissionsPort: _FakePlatformPermissionsPort(),
          syncLedgerPersistence: ledger,
          bindingTokenProvider: _bindingToken,
        );
        addTearDown(controller.dispose);
        await controller.connect();
        await _awaitAutomaticScan(controller, port);
        port.emitFileDirectory(files);
        await controller.scanFiles();

        final transfer = controller.downloadFilesOverBluetooth(files);
        await _waitFor(() => port.bleDownloadCallCount == 1);
        final digest = RecordingCardFileIdentity.digestSerialNumber(
          serialNumber,
        )!;
        final beforeCancellation = ledger.loadFileLedger(digest);
        expect(beforeCancellation, hasLength(2));
        expect(
          beforeCancellation.map((entry) => entry.resumeRequested),
          everyElement(isTrue),
        );

        var cancellationSettled = false;
        final cancellation = controller.cancelFileTransfer().whenComplete(() {
          cancellationSettled = true;
        });
        await _waitFor(() => port.cancelCallCount == 1);

        expect(cancellationSettled, isFalse);
        final duringCancellation = ledger.loadFileLedger(digest);
        expect(duringCancellation, hasLength(2));
        expect(
          duringCancellation.map((entry) => entry.resumeRequested),
          everyElement(isFalse),
        );

        cancelGate.complete(RecordingCardResult<bool>.success(true));
        await cancellation;
        downloadGate.complete(
          RecordingCardResult<RecordingCardDownloadedFile>.failure(
            _failure('RECORDING_CARD_TRANSFER_CANCELLED'),
          ),
        );
        final settled = await transfer;
        expect(
          settled.value?.interruptionCode,
          'RECORDING_CARD_TRANSFER_CANCELLED',
        );
      },
    );

    test(
      'rejected direct cancellation retains the active transfer owner',
      () async {
        final port = _FakeRecordingCardPort();
        final controller = _controllerFor(port);
        addTearDown(controller.dispose);
        await controller.connect();
        await _awaitAutomaticScan(controller, port);
        final downloadGate =
            Completer<RecordingCardResult<RecordingCardDownloadedFile>>();
        port.bleDownloadCompleter = downloadGate;
        port.cancelCompleter = Completer<RecordingCardResult<bool>>()
          ..complete(
            RecordingCardResult<bool>.failure(_failure('CANCEL_REJECTED')),
          );
        final transfer = controller.downloadFile(
          port.scannedFile,
          refreshAfterTransfer: false,
        );
        await _waitFor(() => port.bleDownloadCallCount == 1);
        final generation = controller.state.operation.generation;
        await controller.cancelFileTransfer();
        expect(controller.hasActiveTransfer, isTrue);
        expect(
          controller.state.operation.phase,
          RecordingCardOperationPhase.running,
        );
        expect(controller.state.operation.generation, generation);
        expect(
          controller.state.status,
          RecordingCardControllerStatus.downloading,
        );
        expect(controller.state.activeFileKey, port.scannedFile.localFileKey);
        expect(controller.state.lastErrorCode, 'CANCEL_REJECTED');
        downloadGate.complete(
          RecordingCardResult<RecordingCardDownloadedFile>.failure(
            _failure('RECORDING_CARD_TRANSFER_CANCELLED'),
          ),
        );
        await transfer;
      },
    );

    test(
      'late direct cancellation acknowledgement cannot replace a new connection',
      () async {
        final port = _FakeRecordingCardPort();
        final controller = _controllerFor(port);
        addTearDown(controller.dispose);
        await controller.connect();
        await _awaitAutomaticScan(controller, port);
        port.emit(
          port.runtimeSnapshot.copyWith(
            downloadingFileKey: port.scannedFile.localFileKey,
          ),
        );
        final cancelGate = Completer<RecordingCardResult<bool>>();
        port.cancelCompleter = cancelGate;
        final cancellation = controller.cancelFileTransfer();
        port.emit(
          port.runtimeSnapshot.copyWith(
            deviceState: const RecordingCardDeviceState(
              connectionState: RecordingCardConnectionState.connected,
              connectionStage: RecordingCardConnectionStage.connected,
              safeDeviceFingerprint: 'new-card-after-cancellation',
            ),
            clearDownloadingFileKey: true,
          ),
        );
        await _waitFor(() => controller.hasLoadedFilesForCurrentConnection);
        final newerState = controller.state;
        cancelGate.complete(
          RecordingCardResult<bool>.failure(_failure('STALE_CANCEL_FAILURE')),
        );
        await cancellation;
        expect(
          controller.state.snapshot.deviceState.safeDeviceFingerprint,
          'new-card-after-cancellation',
        );
        expect(
          controller.state.operation.generation,
          newerState.operation.generation,
        );
        expect(controller.state.operation.phase, newerState.operation.phase);
        expect(controller.state.lastErrorCode, isNot('STALE_CANCEL_FAILURE'));
      },
    );

    test(
      'MethodChannel recording controls retain elapsed-time anchors',
      () async {
        var now = DateTime.utc(2026, 7, 14, 9);
        const channel = MethodChannel(
          'huahuoai/recording_card_controller_elapsed',
        );
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        messenger.setMockMethodCallHandler(channel, (call) async {
          return switch (call.method) {
            'connect' => <String, Object?>{
              'connectionState': 'connected',
              'connectionStage': 'connected',
              'safeDeviceFingerprint': 'elapsed-test-card',
            },
            'scanFiles' => <Object?>[],
            'startRecording' ||
            'resumeRecording' => <String, Object?>{'state': 'recording'},
            'pauseRecording' => <String, Object?>{'state': 'paused'},
            'stopRecording' => <String, Object?>{'state': 'idle'},
            _ => null,
          };
        });
        final port = MethodChannelRecordingCardPort(
          methodChannel: channel,
          clock: () => now,
        );
        final controller = _controllerFor(port);
        addTearDown(() async {
          controller.dispose();
          await port.dispose();
        });
        await controller.connect();
        await controller.ensureFilesLoadedForCurrentConnection();

        await controller.startRecording();
        expect(controller.state.snapshot.recordingInfo.startedAt, now);
        now = now.add(const Duration(seconds: 12));
        expect(
          recordingCardElapsedSeconds(
            controller.state.snapshot.recordingInfo,
            now: now,
          ),
          12,
        );

        await controller.pauseRecording();
        expect(controller.state.snapshot.recordingInfo.startedAt, isNull);
        expect(controller.state.snapshot.recordingInfo.durationSeconds, 12);
        now = now.add(const Duration(seconds: 3));
        await controller.resumeRecording();
        expect(controller.state.snapshot.recordingInfo.startedAt, now);
        expect(controller.state.snapshot.recordingInfo.durationSeconds, 12);
        now = now.add(const Duration(seconds: 8));
        expect(
          recordingCardElapsedSeconds(
            controller.state.snapshot.recordingInfo,
            now: now,
          ),
          20,
        );

        await controller.stopRecording();
        expect(controller.state.snapshot.recordingInfo.startedAt, isNull);
        expect(controller.state.snapshot.recordingInfo.durationSeconds, 0);
      },
    );

    test(
      'scan sync download and delete update file projection only on success',
      () async {
        final port = _FakeRecordingCardPort();
        final repository = _repository();
        final controller = RecordingCardController(
          port: port,
          localRecordingRepository: repository,
          platformPermissionsPort: _FakePlatformPermissionsPort(),
          bindingTokenProvider: _bindingToken,
        );
        addTearDown(controller.dispose);
        await controller.connect();
        await _awaitAutomaticScan(controller, port);

        await controller.scanDevices();
        expect(controller.state.snapshot.discoveredDevices, hasLength(1));

        await controller.scanFiles();
        expect(controller.state.snapshot.files, hasLength(1));
        expect(
          controller.state.snapshot.files.single.syncState,
          RecordingCardFileSyncState.deviceOnly,
        );

        await controller.syncFileToLocal(
          controller.state.snapshot.files.single,
        );
        expect(controller.state.status, RecordingCardControllerStatus.idle);
        expect(
          controller.state.lastDownloadedFile?.appPrivateUri,
          startsWith('app-private://'),
        );
        expect(
          controller.state.snapshot.files.single.syncState,
          RecordingCardFileSyncState.synced,
        );
        expect(controller.state.snapshot.files.single.durationSeconds, 38);
        expect(repository.list().rows, hasLength(1));
        expect(
          repository.list().rows.single.source,
          RecordingLibrarySource.device,
        );

        await controller.deleteFile(controller.state.snapshot.files.single);
        expect(controller.state.snapshot.files, isEmpty);
      },
    );

    test(
      'Bluetooth batch keeps completed files and requeues the tail on disconnect',
      () async {
        const accountScope = 'bluetooth-partial-disconnect-account';
        const serialNumber = 'CARD-BLE-PARTIAL-001';
        final database = AppDatabase();
        final repository = LocalRecordingRepository(
          database: database,
          fileStorage: const _RecordingCardFileStorage(),
          accountScope: accountScope,
        );
        final ledger = RecordingCardSyncLedgerStore(
          database: database,
          accountScope: accountScope,
        );
        final port = _FakeRecordingCardPort(serialNumber: serialNumber);
        final controller = RecordingCardController(
          port: port,
          localRecordingRepository: repository,
          platformPermissionsPort: _FakePlatformPermissionsPort(),
          syncLedgerPersistence: ledger,
          bindingTokenProvider: _bindingToken,
        );
        addTearDown(controller.dispose);
        await controller.connect();
        await _awaitAutomaticScan(controller, port);
        final files = <RecordingCardScannedFile>[
          _fileWithId(1),
          _fileWithId(2),
          _fileWithId(3),
        ];
        port.emitFileDirectory(files);
        await controller.scanFiles();
        final secondDownload =
            Completer<RecordingCardResult<RecordingCardDownloadedFile>>();
        port.bleDownloadCompletersByDeviceFileId[files[1].deviceFileId] =
            secondDownload;

        final transfer = controller.downloadFilesOverBluetooth(files);
        await _waitFor(
          () => port.bleDownloadedKeys.contains(files[1].deviceFileId),
        );
        port.emit(
          port.runtimeSnapshot.copyWith(
            deviceState: RecordingCardDeviceState.disconnected(),
            files: const <RecordingCardScannedFile>[],
            clearDownloadingFileKey: true,
            clearTransferProgress: true,
          ),
        );
        secondDownload.complete(
          RecordingCardResult<RecordingCardDownloadedFile>.failure(
            _failure('RECORDING_CARD_NOT_CONNECTED'),
          ),
        );

        final result = await transfer;

        expect(result.ok, isTrue);
        expect(result.value?.completedFiles, <RecordingCardScannedFile>[
          files[0],
        ]);
        expect(result.value?.remainingFiles, <RecordingCardScannedFile>[
          files[1],
          files[2],
        ]);
        expect(result.value?.interruptionCode, 'RECORDING_CARD_DISCONNECTED');
        expect(port.bleDownloadedKeys, <String>[
          files[0].deviceFileId,
          files[1].deviceFileId,
        ]);
        expect(repository.list().rows, hasLength(1));
        expect(controller.localRecordingRegistrationRevision, 1);

        final cardDigest = RecordingCardFileIdentity.digestSerialNumber(
          serialNumber,
        )!;
        final entriesByDeviceFileId = <String, RecordingCardFileLedgerEntry>{
          for (final entry in ledger.loadFileLedger(cardDigest))
            entry.deviceFileId: entry,
        };
        expect(
          entriesByDeviceFileId[files[0].deviceFileId]?.localState,
          RecordingCardFileLocalState.synced,
        );
        for (final file in files.skip(1)) {
          expect(
            entriesByDeviceFileId[file.deviceFileId]?.localState,
            RecordingCardFileLocalState.queued,
          );
          expect(entriesByDeviceFileId[file.deviceFileId]?.attemptCount, 0);
        }
      },
    );

    test(
      'single Bluetooth exception settles the durable ledger as failed',
      () async {
        const accountScope = 'bluetooth-thrown-download-account';
        const serialNumber = 'CARD-BLE-THROWN-001';
        final database = AppDatabase();
        final repository = LocalRecordingRepository(
          database: database,
          fileStorage: const _RecordingCardFileStorage(),
          accountScope: accountScope,
        );
        final ledger = RecordingCardSyncLedgerStore(
          database: database,
          accountScope: accountScope,
        );
        final port = _FakeRecordingCardPort(serialNumber: serialNumber);
        final controller = RecordingCardController(
          port: port,
          localRecordingRepository: repository,
          platformPermissionsPort: _FakePlatformPermissionsPort(),
          syncLedgerPersistence: ledger,
          bindingTokenProvider: _bindingToken,
        );
        addTearDown(controller.dispose);
        await controller.connect();
        await _awaitAutomaticScan(controller, port);
        final file = controller.state.snapshot.files.single;
        port.bleDownloadExceptionsByDeviceFileId[file.deviceFileId] =
            StateError('native callback failed');

        final result = await controller.downloadFileResult(file);

        expect(result.ok, isFalse);
        expect(result.error?.code, 'RECORDING_CARD_DOWNLOAD_FAILED');
        expect(repository.list().rows, isEmpty);
        final cardDigest = RecordingCardFileIdentity.digestSerialNumber(
          serialNumber,
        )!;
        final entry = ledger.loadFileLedger(cardDigest).single;
        expect(entry.localState, RecordingCardFileLocalState.failed);
        expect(entry.errorCode, 'RECORDING_CARD_DOWNLOAD_FAILED');
      },
    );

    test(
      'recoverable Bluetooth reuses the exact planned committed target',
      () async {
        const accountScope = 'bluetooth-planned-recovery-account';
        const serialNumber = 'CARD-BLE-RECOVERY-001';
        final database = AppDatabase();
        final repository = LocalRecordingRepository(
          database: database,
          fileStorage: const _RecordingCardFileStorage(),
          accountScope: accountScope,
        );
        final ledger = RecordingCardSyncLedgerStore(
          database: database,
          accountScope: accountScope,
        );
        final port = _RecoverableBluetoothRecordingCardPort(
          serialNumber: serialNumber,
          recoverCommitted: true,
        );
        final controller = RecordingCardController(
          port: port,
          localRecordingRepository: repository,
          platformPermissionsPort: _FakePlatformPermissionsPort(),
          syncLedgerPersistence: ledger,
          bindingTokenProvider: _bindingToken,
        );
        addTearDown(controller.dispose);
        await controller.connect();
        await _awaitAutomaticScan(controller, port);
        final file = controller.state.snapshot.files.single;

        final result = await controller.downloadFileResult(file);

        expect(result.ok, isTrue, reason: result.error?.code);
        expect(port.recoveredTargets, hasLength(1));
        expect(port.downloadedTargets, isEmpty);
        expect(repository.list().rows, hasLength(1));
        expect(
          repository.list().rows.single.appPrivateUri,
          contains(port.recoveredTargets.single),
        );
        final digest = RecordingCardFileIdentity.digestSerialNumber(
          serialNumber,
        )!;
        final entry = ledger.loadFileLedger(digest).single;
        expect(entry.localState, RecordingCardFileLocalState.synced);
        expect(entry.plannedNativeFileId, isNull);
        expect(entry.resumeRequested, isFalse);
      },
    );

    test(
      'cold Bluetooth recovery registers a committed target while card is offline',
      () async {
        const accountScope = 'bluetooth-offline-recovery-account';
        const serialNumber = 'CARD-BLE-OFFLINE-001';
        const plannedNativeFileId = 'card-1234567890abcdef1234567890abcdef';
        final database = AppDatabase();
        final repository = LocalRecordingRepository(
          database: database,
          fileStorage: const _RecordingCardFileStorage(),
          accountScope: accountScope,
        );
        final ledger = RecordingCardSyncLedgerStore(
          database: database,
          accountScope: accountScope,
        );
        final digest = RecordingCardFileIdentity.digestSerialNumber(
          serialNumber,
        )!;
        final file = _fileWithId(1);
        final queued = ledger.queueManualSyncForFile(
          cardSnDigest: digest,
          file: file,
          at: DateTime.utc(2026, 9, 13, 8),
        );
        ledger.saveFileLedgerEntry(
          queued.planBluetoothDownload(
            at: DateTime.utc(2026, 9, 13, 8, 1),
            plannedNativeFileId: plannedNativeFileId,
            syncOrigin: RecordingCardSyncOrigin.user,
          ),
        );
        await ledger.flushSyncPersistence();
        final port = _RecoverableBluetoothRecordingCardPort(
          serialNumber: serialNumber,
          recoverCommitted: true,
        );
        final controller = RecordingCardController(
          port: port,
          localRecordingRepository: repository,
          platformPermissionsPort: _FakePlatformPermissionsPort(),
          syncLedgerPersistence: ledger,
          bindingTokenProvider: _bindingToken,
        );
        addTearDown(controller.dispose);
        await controller.restoreWifiBatch();
        await _waitFor(
          () =>
              repository.list().rows.length == 1 &&
              !controller.hasPendingBluetoothSync,
        );

        expect(port.recoveredTargets, <String>[plannedNativeFileId]);
        expect(port.downloadedTargets, isEmpty);
        expect(port.connectCallCount, 0);
        expect(port.bleDownloadCallCount, 0);
        expect(repository.list().rows, hasLength(1));
        final settled = ledger.loadFileLedger(digest).single;
        expect(settled.localState, RecordingCardFileLocalState.synced);
        expect(settled.plannedNativeFileId, isNull);
        expect(settled.resumeRequested, isFalse);
        expect(controller.hasPendingBluetoothSync, isFalse);
      },
    );

    for (final recoverCommitted in <bool>[true, false]) {
      test('recoverable Bluetooth rejects a mismatched '
          '${recoverCommitted ? 'recovered' : 'downloaded'} target', () async {
        const accountScope = 'bluetooth-planned-mismatch-account';
        const serialNumber = 'CARD-BLE-MISMATCH-001';
        final database = AppDatabase();
        final repository = LocalRecordingRepository(
          database: database,
          fileStorage: const _RecordingCardFileStorage(),
          accountScope: accountScope,
        );
        final ledger = RecordingCardSyncLedgerStore(
          database: database,
          accountScope: accountScope,
        );
        final port = _RecoverableBluetoothRecordingCardPort(
          serialNumber: serialNumber,
          recoverCommitted: recoverCommitted,
          mismatchNativeFileId: true,
        );
        final controller = RecordingCardController(
          port: port,
          localRecordingRepository: repository,
          platformPermissionsPort: _FakePlatformPermissionsPort(),
          syncLedgerPersistence: ledger,
          bindingTokenProvider: _bindingToken,
        );
        addTearDown(controller.dispose);
        await controller.connect();
        await _awaitAutomaticScan(controller, port);

        final result = await controller.downloadFileResult(
          controller.state.snapshot.files.single,
        );

        expect(result.ok, isFalse);
        expect(result.error?.code, 'RECORDING_CARD_BLUETOOTH_TARGET_MISMATCH');
        expect(port.recoveredTargets, hasLength(1));
        expect(port.downloadedTargets, hasLength(recoverCommitted ? 0 : 1));
        expect(repository.list().rows, isEmpty);
      });
    }

    test(
      'Bluetooth batch does not touch hardware when planning persistence throws',
      () async {
        const accountScope = 'bluetooth-double-failure-account';
        const serialNumber = 'CARD-BLE-DOUBLE-FAILURE-001';
        final database = AppDatabase();
        final repository = LocalRecordingRepository(
          database: database,
          fileStorage: const _RecordingCardFileStorage(),
          accountScope: accountScope,
        );
        final ledgerStore = RecordingCardSyncLedgerStore(
          database: database,
          accountScope: accountScope,
        );
        final ledger = _FailingManualBluetoothLedger(ledgerStore);
        final port = _FakeRecordingCardPort(serialNumber: serialNumber);
        final controller = RecordingCardController(
          port: port,
          localRecordingRepository: repository,
          platformPermissionsPort: _FakePlatformPermissionsPort(),
          syncLedgerPersistence: ledger,
          bindingTokenProvider: _bindingToken,
        );
        addTearDown(controller.dispose);
        await controller.connect();
        await _awaitAutomaticScan(controller, port);
        final files = <RecordingCardScannedFile>[
          _fileWithId(1),
          _fileWithId(2),
        ];
        port.emitFileDirectory(files);
        await controller.scanFiles();
        port.bleDownloadExceptionsByDeviceFileId[files.first.deviceFileId] =
            StateError('native callback failed');

        final result = await controller.downloadFilesOverBluetooth(files);

        expect(result.ok, isTrue);
        expect(result.value?.completedFiles, isEmpty);
        expect(result.value?.remainingFiles, files);
        expect(
          result.value?.interruptionCode,
          'RECORDING_CARD_LEDGER_FAILURE_PERSIST_FAILED',
        );
        expect(port.bleDownloadedKeys, isEmpty);
        final cardDigest = RecordingCardFileIdentity.digestSerialNumber(
          serialNumber,
        )!;
        final entries = ledgerStore.loadFileLedger(cardDigest);
        expect(entries, hasLength(2));
        expect(
          entries.map((entry) => entry.localState),
          everyElement(RecordingCardFileLocalState.queued),
        );
      },
    );

    test(
      'guided connection requires exactly one nearby recording card',
      () async {
        final port = _FakeRecordingCardPort();
        final controller = _controllerFor(port);
        addTearDown(controller.dispose);

        port.discoveredDevices = const <RecordingCardDiscoveredDevice>[];
        await controller.connectSingleNearbyDevice();
        expect(
          controller.state.lastErrorCode,
          'RECORDING_CARD_GUIDED_DEVICE_NOT_FOUND',
        );
        expect(port.connectCallCount, 0);

        port.discoveredDevices = const <RecordingCardDiscoveredDevice>[
          RecordingCardDiscoveredDevice(
            displayName: 'Huahuo FW920 A',
            safeDeviceFingerprint: 'guided-card-a',
            isConnectable: true,
          ),
          RecordingCardDiscoveredDevice(
            displayName: 'Huahuo FW920 B',
            safeDeviceFingerprint: 'guided-card-b',
            isConnectable: true,
          ),
        ];
        await controller.connectSingleNearbyDevice();
        expect(
          controller.state.lastErrorCode,
          'RECORDING_CARD_GUIDED_MULTIPLE_DEVICES',
        );
        expect(port.connectCallCount, 0);

        port.discoveredDevices = const <RecordingCardDiscoveredDevice>[
          RecordingCardDiscoveredDevice(
            displayName: 'Huahuo FW920',
            safeDeviceFingerprint: 'guided-card-only',
            isConnectable: true,
          ),
        ];
        await controller.connectSingleNearbyDevice();
        await _awaitAutomaticScan(controller, port);

        expect(port.scanDevicesCallCount, 3);
        expect(port.connectCallCount, 1);
        expect(
          port.connectRequests.single?.safeDeviceFingerprint,
          'guided-card-only',
        );
        expect(
          controller.state.snapshot.deviceState.isOperationallyConnected,
          isTrue,
        );
      },
    );

    test(
      'selected discovery records only its safe connection projection',
      () async {
        final port = _FakeRecordingCardPort();
        final history = InMemoryRecordingCardConnectionHistory();
        final controller = _controllerFor(
          port,
          connectionHistory: history,
          clock: () => DateTime.utc(2026, 8, 19, 10),
        );
        addTearDown(controller.dispose);

        await controller.connectDiscoveredDevice(port.discoveredDevices.single);
        await _awaitAutomaticScan(controller, port);

        expect(
          port.connectRequests.single?.safeDeviceFingerprint,
          'card-fingerprint-1',
        );
        expect(history.load(), hasLength(1));
        expect(
          history.load().single.safeDeviceFingerprint,
          'card-fingerprint-1',
        );
        expect(history.load().single.displayName, 'Huahuo FW920');
      },
    );

    test('discovery cloud rejection happens before native connect', () async {
      final port = _FakeRecordingCardPort();
      port.discoveredDevices = const <RecordingCardDiscoveredDevice>[
        RecordingCardDiscoveredDevice(
          displayName: 'Huahuo FW920',
          safeDeviceFingerprint: 'card-fingerprint-1',
          serialNumber: 'SP63A03003',
          isConnectable: true,
        ),
      ];
      final authorization = _FakeDiscoveryAuthorization(
        preauthorization: RecordingCardResult<bool>.failure(
          recordingCardFailure(
            'RECORDING_CARD_ALREADY_BOUND',
            'Recording card is already bound',
          ),
        ),
      );
      final controller = _controllerFor(
        port,
        connectionAuthorization: authorization,
      );
      addTearDown(controller.dispose);

      await controller.connectDiscoveredDevice(port.discoveredDevices.single);

      expect(port.connectCallCount, 0);
      expect(controller.state.lastErrorCode, 'RECORDING_CARD_ALREADY_BOUND');
      expect(authorization.discoveryAuthorizationCount, 1);
    });

    test('preauthorized discovery forwards expected SN to native', () async {
      final port = _FakeRecordingCardPort();
      port.discoveredDevices = const <RecordingCardDiscoveredDevice>[
        RecordingCardDiscoveredDevice(
          displayName: 'Huahuo FW920',
          safeDeviceFingerprint: 'card-fingerprint-1',
          serialNumber: 'sp63-a03003',
          isConnectable: true,
        ),
      ];
      final authorization = _FakeDiscoveryAuthorization();
      final controller = _controllerFor(
        port,
        connectionAuthorization: authorization,
      );
      addTearDown(controller.dispose);

      await controller.connectDiscoveredDevice(port.discoveredDevices.single);
      await _awaitAutomaticScan(controller, port);

      expect(port.connectCallCount, 1);
      expect(port.connectRequests.single?.expectedSerialNumber, 'SP63A03003');
      expect(authorization.discoveryAuthorizationCount, 1);
    });

    test(
      'selected discovery settles native scan before cloud authorization',
      () async {
        final port = _FakeRecordingCardPort(serialNumber: 'SP63A03003');
        port.discoveredDevices = const <RecordingCardDiscoveredDevice>[
          RecordingCardDiscoveredDevice(
            displayName: 'Huahuo FW920',
            safeDeviceFingerprint: 'card-fingerprint-1',
            serialNumber: 'SP63A03003',
            isConnectable: true,
          ),
        ];
        final scanResult =
            Completer<
              RecordingCardResult<List<RecordingCardDiscoveredDevice>>
            >();
        final cancellation = Completer<RecordingCardResult<bool>>();
        port.scanDevicesCompleter = scanResult;
        port.discoveryCancellationCompleter = cancellation;
        final authorization = _FakeDiscoveryAuthorization();
        final controller = _controllerFor(
          port,
          connectionAuthorization: authorization,
          requiresBluetoothPermissionRequest: () => false,
        );
        addTearDown(controller.dispose);

        final scan = controller.scanDevices();
        await _waitFor(
          () =>
              controller.state.status == RecordingCardControllerStatus.scanning,
        );
        final connection = controller.connectDiscoveredDevice(
          port.discoveredDevices.single,
        );
        await _waitFor(() => port.discoveryCancellationCallCount == 1);

        expect(authorization.discoveryAuthorizationCount, 0);
        expect(port.connectCallCount, 0);

        cancellation.complete(RecordingCardResult<bool>.success(true));
        await connection;

        expect(authorization.discoveryAuthorizationCount, 1);
        expect(port.connectCallCount, 1);
        await scan;
      },
    );

    test(
      'failed discovery cancellation still waits for scan termination',
      () async {
        final port = _FakeRecordingCardPort(serialNumber: 'SP63A03003');
        port.discoveredDevices = const <RecordingCardDiscoveredDevice>[
          RecordingCardDiscoveredDevice(
            displayName: 'Huahuo FW920',
            safeDeviceFingerprint: 'card-fingerprint-1',
            serialNumber: 'SP63A03003',
            isConnectable: true,
          ),
        ];
        final pendingScan =
            Completer<
              RecordingCardResult<List<RecordingCardDiscoveredDevice>>
            >();
        final pendingCancellation = Completer<RecordingCardResult<bool>>();
        port.scanDevicesCompleter = pendingScan;
        port.discoveryCancellationCompleter = pendingCancellation;
        final authorization = _FakeDiscoveryAuthorization();
        final controller = _controllerFor(
          port,
          connectionAuthorization: authorization,
          requiresBluetoothPermissionRequest: () => false,
        );
        addTearDown(controller.dispose);

        final scan = controller.scanDevices();
        await _waitFor(() => port.scanDevicesCallCount == 1);
        final connection = controller.connectDiscoveredDevice(
          port.discoveredDevices.single,
        );
        await _waitFor(() => port.discoveryCancellationCallCount == 1);
        pendingCancellation.complete(
          RecordingCardResult<bool>.failure(
            recordingCardFailure(
              'RECORDING_CARD_SCAN_CANCEL_FAILED',
              'Unable to cancel recording-card discovery',
              isRetryable: true,
            ),
          ),
        );
        await Future<void>.delayed(Duration.zero);

        expect(authorization.discoveryAuthorizationCount, 0);
        expect(port.connectCallCount, 0);

        port.scanDevicesCompleter = null;
        pendingScan.complete(
          RecordingCardResult<List<RecordingCardDiscoveredDevice>>.success(
            port.discoveredDevices,
          ),
        );
        await scan;
        await connection;
        await _awaitAutomaticScan(controller, port);

        expect(authorization.discoveryAuthorizationCount, 1);
        expect(port.connectCallCount, 1);
        expect(controller.state.operation.isActive, isFalse);
      },
    );

    test(
      'blocked discovery stays pending and runs once after owner settles',
      () async {
        final port = _FakeRecordingCardPort();
        final pendingConnection =
            Completer<RecordingCardResult<RecordingCardDeviceState>>();
        port.connectCompleter = pendingConnection;
        final controller = _controllerFor(
          port,
          requiresBluetoothPermissionRequest: () => false,
        );
        addTearDown(controller.dispose);

        final connection = controller.connect();
        await _waitFor(() => port.connectCallCount == 1);
        final firstScan = controller.scanDevices();
        final joinedScan = controller.scanDevices();
        var scanCompleted = false;
        unawaited(firstScan.whenComplete(() => scanCompleted = true));
        await Future<void>.delayed(Duration.zero);

        expect(identical(firstScan, joinedScan), isTrue);
        expect(port.scanDevicesCallCount, 0);
        expect(scanCompleted, isFalse);
        expect(controller.operationBlockCode, isNull);

        pendingConnection.complete(
          RecordingCardResult<RecordingCardDeviceState>.failure(
            _failure('RECORDING_CARD_CONNECTION_FAILED'),
          ),
        );
        await connection;
        await firstScan;

        expect(port.scanDevicesCallCount, 1);
        expect(scanCompleted, isTrue);
        expect(controller.state.status, RecordingCardControllerStatus.idle);
        expect(controller.state.snapshot.discoveredDevices, isNotEmpty);
      },
    );

    test(
      'cancelling deferred discovery leaves its active owner intact',
      () async {
        final port = _FakeRecordingCardPort();
        final pendingConnection =
            Completer<RecordingCardResult<RecordingCardDeviceState>>();
        port.connectCompleter = pendingConnection;
        final controller = _controllerFor(
          port,
          requiresBluetoothPermissionRequest: () => false,
        );
        addTearDown(controller.dispose);

        final connection = controller.connect();
        await _waitFor(() => port.connectCallCount == 1);
        final scan = controller.scanDevices();
        await Future<void>.delayed(Duration.zero);

        await controller.cancelDiscovery();
        await scan;

        expect(port.scanDevicesCallCount, 0);
        expect(port.discoveryCancellationCallCount, 0);
        expect(
          controller.state.status,
          RecordingCardControllerStatus.connecting,
        );
        expect(
          controller.state.operation.kind,
          RecordingCardOperationKind.connection,
        );
        expect(controller.state.operation.isActive, isTrue);
        expect(controller.operationBlockCode, isNull);

        pendingConnection.complete(
          RecordingCardResult<RecordingCardDeviceState>.failure(
            _failure('RECORDING_CARD_CONNECTION_FAILED'),
          ),
        );
        await connection;
      },
    );

    test(
      'cancelling deferred discovery does not cancel directory refresh',
      () async {
        final port = _FakeRecordingCardPort();
        final controller = _controllerFor(
          port,
          requiresBluetoothPermissionRequest: () => false,
        );
        addTearDown(controller.dispose);
        await controller.connect();
        await _awaitAutomaticScan(controller, port);
        final initialFileScanCount = port.scanFilesCallCount;
        final pendingFileScan =
            Completer<RecordingCardResult<List<RecordingCardScannedFile>>>();
        port.scanFilesCompleter = pendingFileScan;

        final fileScan = controller.scanFiles();
        await _waitFor(
          () =>
              port.scanFilesCallCount == initialFileScanCount + 1 &&
              controller.state.operation.kind ==
                  RecordingCardOperationKind.directoryRefresh &&
              controller.state.operation.isActive,
        );
        final discovery = controller.scanDevices();
        await Future<void>.delayed(Duration.zero);

        await controller.cancelDiscovery();
        await discovery;

        expect(port.scanDevicesCallCount, 0);
        expect(port.discoveryCancellationCallCount, 0);
        expect(controller.state.status, RecordingCardControllerStatus.scanning);
        expect(
          controller.state.operation.kind,
          RecordingCardOperationKind.directoryRefresh,
        );
        expect(controller.state.operation.isActive, isTrue);

        pendingFileScan.complete(
          RecordingCardResult<List<RecordingCardScannedFile>>.success(
            <RecordingCardScannedFile>[port.scannedFile],
          ),
        );
        await fileScan;
      },
    );

    test(
      'selected device withdraws discovery deferred behind directory refresh',
      () async {
        final port = _FakeRecordingCardPort();
        port.discoveredDevices = const <RecordingCardDiscoveredDevice>[
          RecordingCardDiscoveredDevice(
            displayName: 'Huahuo FW920',
            safeDeviceFingerprint: 'card-fingerprint-1',
            serialNumber: 'SP63A03003',
            isConnectable: true,
          ),
        ];
        final authorization = _FakeDiscoveryAuthorization();
        final controller = _controllerFor(
          port,
          connectionAuthorization: authorization,
          requiresBluetoothPermissionRequest: () => false,
        );
        addTearDown(controller.dispose);
        await controller.connect();
        await _awaitAutomaticScan(controller, port);
        final initialFileScanCount = port.scanFilesCallCount;
        final pendingFileScan =
            Completer<RecordingCardResult<List<RecordingCardScannedFile>>>();
        port.scanFilesCompleter = pendingFileScan;

        final fileScan = controller.scanFiles();
        await _waitFor(
          () =>
              port.scanFilesCallCount == initialFileScanCount + 1 &&
              controller.state.operation.kind ==
                  RecordingCardOperationKind.directoryRefresh,
        );
        final discovery = controller.scanDevices();
        await Future<void>.delayed(Duration.zero);

        await controller.connectDiscoveredDevice(port.discoveredDevices.single);
        await discovery;

        expect(port.scanDevicesCallCount, 0);
        expect(port.discoveryCancellationCallCount, 0);
        expect(authorization.discoveryAuthorizationCount, 1);
        expect(port.connectCallCount, 2);

        pendingFileScan.complete(
          RecordingCardResult<List<RecordingCardScannedFile>>.success(
            <RecordingCardScannedFile>[port.scannedFile],
          ),
        );
        await fileScan;
        await Future<void>.delayed(Duration.zero);
        expect(port.scanDevicesCallCount, 0);
      },
    );

    test('discovery requested during unbind is not replayed', () async {
      final port = _FakeRecordingCardPort();
      final pendingUnbindToken = Completer<String>();
      var tokenCallCount = 0;
      final controller = RecordingCardController(
        port: port,
        localRecordingRepository: _repository(),
        platformPermissionsPort: _FakePlatformPermissionsPort(),
        bindingTokenProvider: () {
          tokenCallCount += 1;
          return tokenCallCount == 1
              ? Future<String>.value('0123456789abcdef0123456789abcdef')
              : pendingUnbindToken.future;
        },
        requiresBluetoothPermissionRequest: () => false,
      );
      addTearDown(controller.dispose);
      await controller.connect();
      await _awaitAutomaticScan(controller, port);

      final unbind = controller.unbindDevice(deleteDeviceFiles: false);
      await _waitFor(
        () =>
            controller.state.status == RecordingCardControllerStatus.unbinding,
      );
      await controller.scanDevices();

      expect(port.scanDevicesCallCount, 0);
      pendingUnbindToken.complete('0123456789abcdef0123456789abcdef');
      await unbind;
      await Future<void>.delayed(Duration.zero);
      expect(port.scanDevicesCallCount, 0);
    });

    test(
      'late native discovery cancellation does not notify after dispose',
      () async {
        final port = _FakeRecordingCardPort();
        final pendingScan =
            Completer<
              RecordingCardResult<List<RecordingCardDiscoveredDevice>>
            >();
        final pendingCancellation = Completer<RecordingCardResult<bool>>();
        port.scanDevicesCompleter = pendingScan;
        port.discoveryCancellationCompleter = pendingCancellation;
        final controller = _controllerFor(
          port,
          requiresBluetoothPermissionRequest: () => false,
        );

        final scan = controller.scanDevices();
        await _waitFor(() => port.scanDevicesCallCount == 1);
        final cancellation = controller.cancelDiscovery();
        await _waitFor(() => port.discoveryCancellationCallCount == 1);
        controller.dispose();

        pendingCancellation.complete(RecordingCardResult<bool>.success(true));
        await cancellation;
        await scan;
      },
    );

    test('disposing an active discovery cancels its native scan', () async {
      final port = _FakeRecordingCardPort();
      final pendingScan =
          Completer<RecordingCardResult<List<RecordingCardDiscoveredDevice>>>();
      port.scanDevicesCompleter = pendingScan;
      final controller = _controllerFor(
        port,
        requiresBluetoothPermissionRequest: () => false,
      );

      final scan = controller.scanDevices();
      await _waitFor(() => port.scanDevicesCallCount == 1);
      controller.dispose();

      await _waitFor(() => port.discoveryCancellationCallCount == 1);
      await scan;
    });

    test(
      'overlapping discovery cancellations share one native request',
      () async {
        final port = _FakeRecordingCardPort();
        final pendingScan =
            Completer<
              RecordingCardResult<List<RecordingCardDiscoveredDevice>>
            >();
        final pendingCancellation = Completer<RecordingCardResult<bool>>();
        port.scanDevicesCompleter = pendingScan;
        port.discoveryCancellationCompleter = pendingCancellation;
        final controller = _controllerFor(
          port,
          requiresBluetoothPermissionRequest: () => false,
        );
        addTearDown(controller.dispose);

        final scan = controller.scanDevices();
        await _waitFor(() => port.scanDevicesCallCount == 1);
        final firstCancellation = controller.cancelDiscovery();
        final joinedCancellation = controller.cancelDiscovery();

        expect(identical(firstCancellation, joinedCancellation), isTrue);
        await _waitFor(() => port.discoveryCancellationCallCount == 1);
        expect(port.discoveryCancellationCallCount, 1);

        pendingCancellation.complete(RecordingCardResult<bool>.success(true));
        await Future.wait(<Future<void>>[
          firstCancellation,
          joinedCancellation,
        ]);
        await scan;

        await controller.connectDiscoveredDevice(port.discoveredDevices.single);
        expect(port.connectCallCount, 1);
        expect(
          controller.state.snapshot.deviceState.isOperationallyConnected,
          isTrue,
        );
      },
    );

    test('rescan during cancellation starts after the retired scan', () async {
      final port = _FakeRecordingCardPort();
      final pendingScan =
          Completer<RecordingCardResult<List<RecordingCardDiscoveredDevice>>>();
      final pendingCancellation = Completer<RecordingCardResult<bool>>();
      port.scanDevicesCompleter = pendingScan;
      port.discoveryCancellationCompleter = pendingCancellation;
      final controller = _controllerFor(
        port,
        requiresBluetoothPermissionRequest: () => false,
      );
      addTearDown(controller.dispose);

      final retiredScan = controller.scanDevices();
      await _waitFor(() => port.scanDevicesCallCount == 1);
      final cancellation = controller.cancelDiscovery();
      await _waitFor(() => port.discoveryCancellationCallCount == 1);
      final rescan = controller.scanDevices();
      await Future<void>.delayed(Duration.zero);

      expect(port.scanDevicesCallCount, 1);
      pendingCancellation.complete(RecordingCardResult<bool>.success(true));
      await cancellation;
      await retiredScan;
      await rescan;

      expect(port.scanDevicesCallCount, 2);
      expect(controller.state.snapshot.discoveredDevices, isNotEmpty);
      expect(controller.state.status, RecordingCardControllerStatus.idle);
    });

    test('listener reentry joins the installed discovery request', () async {
      final port = _FakeRecordingCardPort();
      final controller = _controllerFor(
        port,
        requiresBluetoothPermissionRequest: () => false,
      );
      addTearDown(controller.dispose);
      Future<void>? joined;
      controller.addListener(() {
        if (joined == null &&
            controller.state.status == RecordingCardControllerStatus.scanning &&
            controller.state.operation.kind ==
                RecordingCardOperationKind.discovery) {
          joined = controller.scanDevices();
        }
      });

      final first = controller.scanDevices();
      await first;

      expect(joined, isNotNull);
      expect(identical(first, joined), isTrue);
      expect(port.scanDevicesCallCount, 1);
      expect(controller.state.operation.isActive, isFalse);
    });

    test('cached SN lookup keeps duplicate physical rows explicit', () async {
      final port = _FakeRecordingCardPort();
      port.discoveredDevices = const <RecordingCardDiscoveredDevice>[
        RecordingCardDiscoveredDevice(
          displayName: 'Duplicate A',
          safeDeviceFingerprint: 'duplicate-a',
          serialNumber: 'SP63A03003',
        ),
        RecordingCardDiscoveredDevice(
          displayName: 'Duplicate B',
          safeDeviceFingerprint: 'duplicate-b',
          serialNumber: 'SP63A03003',
        ),
      ];
      final controller = _controllerFor(
        port,
        connectionAuthorization: _FakeDiscoveryAuthorization(
          cachedSerials: const <String>{'SP63A03003'},
        ),
      );
      addTearDown(controller.dispose);
      await controller.scanDevices();

      final matches = await controller.cachedAuthorizedDiscoveredDevices();

      expect(matches, hasLength(2));
      expect(matches.map((device) => device.safeDeviceFingerprint), <String>[
        'duplicate-a',
        'duplicate-b',
      ]);
      expect(port.connectCallCount, 0);
    });

    test(
      'selected connection waits for the cancelled scan terminal callback',
      () async {
        final port = _FakeRecordingCardPort();
        final pendingScan =
            Completer<
              RecordingCardResult<List<RecordingCardDiscoveredDevice>>
            >();
        port.scanDevicesCompleter = pendingScan;
        final controller = _controllerFor(
          port,
          requiresBluetoothPermissionRequest: () => false,
        );
        addTearDown(controller.dispose);

        final scan = controller.scanDevices();
        await Future<void>.delayed(Duration.zero);
        expect(controller.state.status, RecordingCardControllerStatus.scanning);

        final connection = controller.connectDiscoveredDevice(
          port.discoveredDevices.single,
        );
        await _waitFor(() => port.discoveryCancellationCallCount == 1);
        await connection;
        expect(
          controller.state.snapshot.deviceState.isOperationallyConnected,
          isTrue,
        );
        await scan;
        await _awaitAutomaticScan(controller, port);

        expect(controller.state.status, RecordingCardControllerStatus.idle);
        expect(
          controller.state.snapshot.deviceState.isOperationallyConnected,
          isTrue,
        );
      },
    );

    test(
      'one directory scan is scheduled per genuine BLE connection session',
      () async {
        final port = _FakeRecordingCardPort();
        final controller = _controllerFor(port);
        addTearDown(controller.dispose);

        await controller.connect();
        await _awaitAutomaticScan(controller, port);
        expect(port.scanFilesCallCount, 1);

        port.emit(
          port.runtimeSnapshot.copyWith(
            deviceState: port.runtimeSnapshot.deviceState.copyWith(
              batteryPercent: 73,
            ),
          ),
        );
        await controller.ensureFilesLoadedForCurrentConnection();
        expect(port.scanFilesCallCount, 1);

        await controller.disconnect();
        await controller.connect();
        await _awaitAutomaticScan(controller, port, minimumCalls: 2);
        expect(port.scanFilesCallCount, 2);

        final restoredPort = _FakeRecordingCardPort();
        restoredPort.emit(
          RecordingCardRuntimeSnapshot(
            deviceState: const RecordingCardDeviceState(
              connectionState: RecordingCardConnectionState.connected,
              connectionStage: RecordingCardConnectionStage.connected,
              safeDeviceFingerprint: 'card-fingerprint-1',
            ),
            recordingInfo: RecordingCardRecordingInfo.idle(),
            files: <RecordingCardScannedFile>[restoredPort.scannedFile],
            discoveredDevices: const <RecordingCardDiscoveredDevice>[],
          ),
        );
        final restoredController = _controllerFor(restoredPort);
        addTearDown(restoredController.dispose);
        await _awaitAutomaticScan(restoredController, restoredPort);
        expect(restoredPort.scanFilesCallCount, 1);
      },
    );

    test(
      'new card first read waits for obsolete device info without being consumed',
      () async {
        final port = _FakeRecordingCardPort();
        final controller = _controllerFor(port);
        addTearDown(controller.dispose);
        await controller.connect();
        await _awaitAutomaticScan(controller, port);
        final scansAfterCardA = port.scanFilesCallCount;
        final cardASnapshot = port.runtimeSnapshot;
        final pendingDeviceInfo =
            Completer<RecordingCardResult<RecordingCardRuntimeSnapshot>>();
        port.refreshDeviceInfoCompleter = pendingDeviceInfo;

        final deviceInfo = controller.refreshDeviceInfo();
        await _waitFor(() => port.refreshDeviceInfoCallCount == 1);
        final cardBFile = _fileWithId(2);
        port._directoryFiles = <RecordingCardScannedFile>[cardBFile];
        port.emit(
          port.runtimeSnapshot.copyWith(
            deviceState: const RecordingCardDeviceState(
              connectionState: RecordingCardConnectionState.connected,
              connectionStage: RecordingCardConnectionStage.connected,
              displayName: 'Huahuo FW920 B',
              safeDeviceFingerprint: 'card-fingerprint-2',
              recordingFormat: RecordingCardFileFormat.m4a,
            ),
            files: <RecordingCardScannedFile>[cardBFile],
          ),
        );
        await Future<void>.delayed(Duration.zero);

        expect(port.scanFilesCallCount, scansAfterCardA);
        expect(
          controller.state.fileCatalog.phase,
          RecordingCardFileCatalogPhase.reading,
        );

        port.refreshDeviceInfoCompleter = null;
        pendingDeviceInfo.complete(
          RecordingCardResult<RecordingCardRuntimeSnapshot>.success(
            cardASnapshot,
          ),
        );
        await deviceInfo;
        await _awaitAutomaticScan(
          controller,
          port,
          minimumCalls: scansAfterCardA + 1,
        );

        expect(port.scanFilesCallCount, scansAfterCardA + 1);
        expect(
          controller.state.snapshot.deviceState.safeDeviceFingerprint,
          'card-fingerprint-2',
        );
        expect(
          controller.state.snapshot.files.single.deviceFileId,
          cardBFile.deviceFileId,
        );
        expect(controller.state.fileCatalog.isReady, isTrue);
      },
    );

    test(
      'new card owns one trailing first read behind the old card scan',
      () async {
        final port = _FakeRecordingCardPort();
        final pendingCardAScan =
            Completer<RecordingCardResult<List<RecordingCardScannedFile>>>();
        port.scanFilesCompleter = pendingCardAScan;
        final controller = _controllerFor(port);
        addTearDown(controller.dispose);

        await controller.connect();
        await _waitFor(() => port.scanFilesCallCount == 1);
        final cardBFile = _fileWithId(2);
        port._directoryFiles = <RecordingCardScannedFile>[cardBFile];
        port.emit(
          port.runtimeSnapshot.copyWith(
            deviceState: const RecordingCardDeviceState(
              connectionState: RecordingCardConnectionState.connected,
              connectionStage: RecordingCardConnectionStage.connected,
              displayName: 'Huahuo FW920 B',
              safeDeviceFingerprint: 'card-fingerprint-2',
              recordingFormat: RecordingCardFileFormat.m4a,
            ),
            files: <RecordingCardScannedFile>[cardBFile],
          ),
        );
        await Future<void>.delayed(Duration.zero);

        expect(port.scanFilesCallCount, 1);
        expect(
          controller.state.fileCatalog.phase,
          RecordingCardFileCatalogPhase.reading,
        );

        port.scanFilesCompleter = null;
        pendingCardAScan.complete(
          RecordingCardResult<List<RecordingCardScannedFile>>.success(
            <RecordingCardScannedFile>[port.scannedFile],
          ),
        );
        await _awaitAutomaticScan(controller, port, minimumCalls: 2);

        expect(port.scanFilesCallCount, 2);
        expect(
          controller.state.snapshot.deviceState.safeDeviceFingerprint,
          'card-fingerprint-2',
        );
        expect(
          controller.state.snapshot.files.single.deviceFileId,
          cardBFile.deviceFileId,
        );
        expect(controller.state.fileCatalog.isReady, isTrue);
        expect(controller.state.status, RecordingCardControllerStatus.idle);
      },
    );

    test(
      'disconnect cancels a new-card tail behind an obsolete scan',
      () async {
        final port = _FakeRecordingCardPort();
        final pendingCardAScan =
            Completer<RecordingCardResult<List<RecordingCardScannedFile>>>();
        port.scanFilesCompleter = pendingCardAScan;
        final controller = _controllerFor(port);
        addTearDown(controller.dispose);

        await controller.connect();
        await _waitFor(() => port.scanFilesCallCount == 1);
        final cardBFile = _fileWithId(2);
        port._directoryFiles = <RecordingCardScannedFile>[cardBFile];
        port.emit(
          port.runtimeSnapshot.copyWith(
            deviceState: const RecordingCardDeviceState(
              connectionState: RecordingCardConnectionState.connected,
              connectionStage: RecordingCardConnectionStage.connected,
              displayName: 'Huahuo FW920 B',
              safeDeviceFingerprint: 'card-fingerprint-2',
              recordingFormat: RecordingCardFileFormat.m4a,
            ),
            files: <RecordingCardScannedFile>[cardBFile],
          ),
        );
        final drain = controller.ensureFilesLoadedForCurrentConnection();
        await port.disconnect();

        expect(
          controller.state.fileCatalog.phase,
          RecordingCardFileCatalogPhase.disconnected,
        );
        expect(controller.state.status, RecordingCardControllerStatus.idle);

        port.scanFilesCompleter = null;
        pendingCardAScan.complete(
          RecordingCardResult<List<RecordingCardScannedFile>>.success(
            <RecordingCardScannedFile>[port.scannedFile],
          ),
        );
        await drain;
        await Future<void>.delayed(Duration.zero);

        expect(port.scanFilesCallCount, 1);
        expect(
          controller.state.snapshot.deviceState.isOperationallyConnected,
          isFalse,
        );
        expect(controller.state.snapshot.files, isEmpty);
        expect(
          controller.state.fileCatalog.phase,
          RecordingCardFileCatalogPhase.disconnected,
        );
        expect(controller.state.status, RecordingCardControllerStatus.idle);
        expect(controller.state.lastErrorCode, isNull);
      },
    );

    test(
      'same-card connect invalidates a scan and schedules one owned reread',
      () async {
        final port = _FakeRecordingCardPort();
        final controller = _controllerFor(port);
        addTearDown(controller.dispose);
        await controller.connect();
        await _awaitAutomaticScan(controller, port);
        final initialScanCount = port.scanFilesCallCount;
        final initialSuccessfulRevision =
            controller.successfulFileRefreshRevision;
        final pendingScan =
            Completer<RecordingCardResult<List<RecordingCardScannedFile>>>();
        port.scanFilesCompleter = pendingScan;

        final staleScan = controller.scanFiles();
        await _waitFor(() => port.scanFilesCallCount == initialScanCount + 1);
        await controller.connect();

        port.scanFilesCompleter = null;
        pendingScan.complete(
          RecordingCardResult<List<RecordingCardScannedFile>>.success(
            <RecordingCardScannedFile>[port.scannedFile],
          ),
        );
        await staleScan;
        await _awaitAutomaticScan(
          controller,
          port,
          minimumCalls: initialScanCount + 2,
        );

        expect(port.scanFilesCallCount, initialScanCount + 2);
        expect(
          controller.successfulFileRefreshRevision,
          initialSuccessfulRevision + 1,
        );
        expect(controller.state.fileCatalog.isReady, isTrue);
        expect(controller.state.status, RecordingCardControllerStatus.idle);
      },
    );

    test(
      'new card scan waits for an obsolete single-file transfer to unwind',
      () async {
        final port = _FakeRecordingCardPort();
        final controller = _controllerFor(port);
        addTearDown(controller.dispose);
        await controller.connect();
        await _awaitAutomaticScan(controller, port);
        final cardAFile = controller.state.snapshot.files.single;
        final scansAfterCardA = port.scanFilesCallCount;
        final pendingDownload =
            Completer<RecordingCardResult<RecordingCardDownloadedFile>>();
        port.bleDownloadCompleter = pendingDownload;

        final transfer = controller.downloadFileResult(cardAFile);
        await _waitFor(() => port.bleDownloadCallCount == 1);

        final cardBFile = _fileWithId(2);
        port._directoryFiles = <RecordingCardScannedFile>[cardBFile];
        port.emit(
          port.runtimeSnapshot.copyWith(
            deviceState: const RecordingCardDeviceState(
              connectionState: RecordingCardConnectionState.connected,
              connectionStage: RecordingCardConnectionStage.connected,
              displayName: 'Huahuo FW920 B',
              safeDeviceFingerprint: 'card-fingerprint-2',
              recordingFormat: RecordingCardFileFormat.m4a,
            ),
            files: <RecordingCardScannedFile>[cardBFile],
          ),
        );
        await Future<void>.delayed(Duration.zero);

        expect(port.scanFilesCallCount, scansAfterCardA);
        expect(
          controller.state.fileCatalog.phase,
          RecordingCardFileCatalogPhase.reading,
        );

        final digest = sha256
            .convert(utf8.encode(cardAFile.localFileKey))
            .toString();
        final nativeFileId = 'card-${digest.substring(0, 32)}';
        pendingDownload.complete(
          RecordingCardResult<RecordingCardDownloadedFile>.success(
            RecordingCardDownloadedFile(
              localFileKey: cardAFile.localFileKey,
              localFileId: nativeFileId,
              appPrivateUri: 'app-private://recording-card/$nativeFileId.m4a',
              displayName: '${cardAFile.deviceFilename}.m4a',
              durationSeconds: 38,
              sizeBytes: cardAFile.sizeBytes,
              contentHash: digest,
              format: RecordingCardFileFormat.m4a,
              mimeType: 'audio/mp4',
            ),
          ),
        );
        final settled = await transfer;
        await _awaitAutomaticScan(
          controller,
          port,
          minimumCalls: scansAfterCardA + 1,
        );

        expect(port.scanFilesCallCount, scansAfterCardA + 1);
        expect(settled.ok, isFalse);
        expect(
          settled.error?.code,
          'RECORDING_CARD_BLUETOOTH_RESUME_SUPERSEDED',
        );
        expect(
          controller.state.snapshot.deviceState.safeDeviceFingerprint,
          'card-fingerprint-2',
        );
        expect(
          controller.state.snapshot.files.single.deviceFileId,
          cardBFile.deviceFileId,
        );
        expect(controller.state.fileCatalog.isReady, isTrue);
        expect(controller.state.status, RecordingCardControllerStatus.idle);
      },
    );

    test(
      'new card scan resumes when obsolete Wi-Fi queue verification exits',
      () async {
        final cardAFile = _file();
        final digest = sha256
            .convert(utf8.encode(cardAFile.localFileKey))
            .toString();
        var blockVerification = false;
        final verificationStarted = Completer<void>();
        final releaseVerification =
            Completer<FileStorageResult<PrivateAudioFileStat>>();
        final storage = _RecordingCardFileStorage(
          contentHash: digest,
          statResult: (_) {
            if (!blockVerification) {
              return Future<FileStorageResult<PrivateAudioFileStat>>.value(
                FileStorageResult<PrivateAudioFileStat>.success(
                  PrivateAudioFileStat(exists: true, sizeBytes: 4096),
                ),
              );
            }
            if (!verificationStarted.isCompleted) {
              verificationStarted.complete();
            }
            return releaseVerification.future;
          },
        );
        final repository = LocalRecordingRepository(
          database: AppDatabase(),
          fileStorage: storage,
        );
        final registered = await repository.registerDownloadedRecording(
          file: PrivateAudioFile(
            fileId: 'recording-card/queue-race.m4a',
            appPrivateUri: 'app-private://recording-card/queue-race.m4a',
            displayName: 'Queue race.m4a',
            mimeType: 'audio/mp4',
            sizeBytes: 4096,
            durationSeconds: 20,
            contentHash: digest,
          ),
          deviceId: 'card-fingerprint-1',
          deviceFileId: cardAFile.deviceFileId,
          deviceFingerprint: 'card-fingerprint-1',
          deviceFilename: cardAFile.deviceFilename,
          downloadedAt: cardAFile.recordedAt,
        );
        expect(registered.ok, isTrue);
        final port = _FakeRecordingCardPort(scannedFile: cardAFile);
        final controller = RecordingCardController(
          port: port,
          localRecordingRepository: repository,
          platformPermissionsPort: _FakePlatformPermissionsPort(),
          bindingTokenProvider: _bindingToken,
        );
        addTearDown(controller.dispose);
        await controller.connect();
        await _awaitAutomaticScan(controller, port);
        final scansAfterCardA = port.scanFilesCallCount;
        blockVerification = true;

        final queued = controller.queueWifiBatch(<RecordingCardScannedFile>[
          controller.state.snapshot.files.single,
        ]);
        await verificationStarted.future;
        final cardBFile = _fileWithId(2);
        port._directoryFiles = <RecordingCardScannedFile>[cardBFile];
        port.emit(
          port.runtimeSnapshot.copyWith(
            deviceState: const RecordingCardDeviceState(
              connectionState: RecordingCardConnectionState.connected,
              connectionStage: RecordingCardConnectionStage.connected,
              displayName: 'Huahuo FW920 B',
              safeDeviceFingerprint: 'card-fingerprint-2',
              recordingFormat: RecordingCardFileFormat.m4a,
            ),
            files: <RecordingCardScannedFile>[cardBFile],
          ),
        );
        expect(port.scanFilesCallCount, scansAfterCardA);
        releaseVerification.complete(
          FileStorageResult<PrivateAudioFileStat>.success(
            PrivateAudioFileStat(exists: true, sizeBytes: 4096),
          ),
        );

        final result = await queued;
        expect(result.ok, isFalse);
        expect(result.error?.code, 'RECORDING_CARD_FILE_CATALOG_CHANGED');
        await _awaitAutomaticScan(
          controller,
          port,
          minimumCalls: scansAfterCardA + 1,
        );
        expect(port.scanFilesCallCount, scansAfterCardA + 1);
        expect(
          controller.state.snapshot.files.single.deviceFileId,
          'card-file-2',
        );
        expect(controller.state.fileCatalog.isReady, isTrue);
      },
    );

    test(
      'BLE transfer and device delete refresh once while local sync refresh never scans',
      () async {
        final port = _FakeRecordingCardPort();
        final controller = _controllerFor(port);
        addTearDown(controller.dispose);
        await controller.connect();
        await _awaitAutomaticScan(controller, port);
        final afterConnect = port.scanFilesCallCount;

        await controller.downloadFile(controller.state.snapshot.files.single);
        expect(port.scanFilesCallCount, afterConnect + 1);

        await controller.downloadFile(
          controller.state.snapshot.files.single,
          refreshAfterTransfer: false,
        );
        expect(port.scanFilesCallCount, afterConnect + 1);

        final result = await controller.deleteFiles(<RecordingCardScannedFile>[
          controller.state.snapshot.files.single,
        ]);
        expect(result.deletedCount, 1);
        expect(port.scanFilesCallCount, afterConnect + 2);

        await controller.refreshLocalSyncState();
        expect(port.scanFilesCallCount, afterConnect + 2);
      },
    );

    test('failed catalog cannot delete a retained device row', () async {
      final port = _FakeRecordingCardPort();
      final controller = _controllerFor(port);
      addTearDown(controller.dispose);
      await controller.connect();
      await _awaitAutomaticScan(controller, port);
      final retained = controller.state.snapshot.files.single;
      port.failNextScan = true;
      await controller.scanFiles();

      expect(
        controller.state.fileCatalog.phase,
        RecordingCardFileCatalogPhase.failed,
      );
      expect(controller.state.snapshot.files, isNotEmpty);
      final result = await controller.deleteFiles(<RecordingCardScannedFile>[
        retained,
      ]);

      expect(result.deletedCount, 0);
      expect(
        result.failureCodes[retained.deviceFileId],
        'RECORDING_CARD_FILE_CATALOG_NOT_READY',
      );
      expect(port.deleteFileCallCount, 0);
    });

    test(
      'device delete rejects recording and owns the transfer latch',
      () async {
        final port = _FakeRecordingCardPort();
        final controller = _controllerFor(port);
        addTearDown(controller.dispose);
        await controller.connect();
        await _awaitAutomaticScan(controller, port);
        final file = controller.state.snapshot.files.single;

        await controller.startRecording();
        final recordingResult = await controller.deleteFiles(
          <RecordingCardScannedFile>[file],
        );
        expect(recordingResult.deletedCount, 0);
        expect(
          recordingResult.failureCodes[file.deviceFileId],
          'RECORDING_CARD_DELETE_RECORDING_ACTIVE',
        );
        expect(port.deleteFileCallCount, 0);

        await controller.stopRecording();
        final deferredDelete =
            Completer<RecordingCardResult<RecordingCardDeleteResult>>();
        port.deleteFileCompleter = deferredDelete;
        final deleting = controller.deleteFiles(<RecordingCardScannedFile>[
          file,
        ]);
        expect(controller.state.status, RecordingCardControllerStatus.deleting);
        expect(controller.state.hasActiveTransfer, isTrue);

        await controller.downloadFile(file, refreshAfterTransfer: false);
        expect(controller.state.lastErrorCode, isNull);
        expect(controller.operationBlockCode, recordingCardOperationBusyCode);
        expect(controller.state.status, RecordingCardControllerStatus.deleting);
        expect(controller.state.hasActiveTransfer, isTrue);
        expect(port.bleDownloadCallCount, 0);
        deferredDelete.complete(
          RecordingCardResult<RecordingCardDeleteResult>.success(
            RecordingCardDeleteResult(
              deviceFileId: file.deviceFileId,
              deviceFilename: file.deviceFilename,
            ),
          ),
        );
        expect((await deleting).deletedCount, 1);
      },
    );

    test('device delete rejects a stale recorded-time identity', () async {
      final recordedAt = DateTime.utc(2026, 9, 4, 8);
      final port = _FakeRecordingCardPort(
        scannedFile: _file(recordedAt: recordedAt),
      );
      final controller = _controllerFor(port);
      addTearDown(controller.dispose);
      await controller.connect();
      await _awaitAutomaticScan(controller, port);
      final selected = controller.state.snapshot.files.single;
      port._directoryFiles = <RecordingCardScannedFile>[
        _file(recordedAt: recordedAt.add(const Duration(seconds: 1))),
      ];
      await controller.scanFiles();

      final result = await controller.deleteFiles(<RecordingCardScannedFile>[
        selected,
      ]);

      expect(result.deletedCount, 0);
      expect(
        result.failureCodes[selected.deviceFileId],
        'RECORDING_CARD_FILE_SELECTION_STALE',
      );
      expect(port.deleteFileCallCount, 0);
    });

    test('device delete rejects a mismatched success receipt', () async {
      final port = _FakeRecordingCardPort();
      final controller = _controllerFor(port);
      addTearDown(controller.dispose);
      await controller.connect();
      await _awaitAutomaticScan(controller, port);
      final file = controller.state.snapshot.files.single;
      final deferredDelete =
          Completer<RecordingCardResult<RecordingCardDeleteResult>>();
      port.deleteFileCompleter = deferredDelete;

      final deleting = controller.deleteFiles(<RecordingCardScannedFile>[file]);
      deferredDelete.complete(
        RecordingCardResult<RecordingCardDeleteResult>.success(
          const RecordingCardDeleteResult(
            deviceFileId: 'another-file',
            deviceFilename: 'another-file.m4a',
          ),
        ),
      );
      final result = await deleting;

      expect(result.deletedCount, 0);
      expect(
        result.failureCodes[file.deviceFileId],
        'RECORDING_CARD_DELETE_IDENTITY_MISMATCH',
      );
    });

    test(
      'fresh controller restores a renamed local download and raw snapshots keep it synced',
      () async {
        final database = AppDatabase();
        const storage = _RecordingCardFileStorage();
        final repository = LocalRecordingRepository(
          database: database,
          fileStorage: storage,
        );
        final firstPort = _FakeRecordingCardPort();
        final firstController = RecordingCardController(
          port: firstPort,
          localRecordingRepository: repository,
          platformPermissionsPort: _FakePlatformPermissionsPort(),
          bindingTokenProvider: _bindingToken,
        );
        addTearDown(firstController.dispose);
        await firstController.connect();
        await firstController.scanFiles();
        await firstController.downloadFile(
          firstController.state.snapshot.files.single,
        );
        final downloaded = repository.list().rows.single;
        final renamed = await repository.rename(
          recordingId: downloaded.recordingId,
          displayName: '用户重命名的录音.m4a',
        );
        expect(renamed.ok, isTrue);

        final restoredPort = _FakeRecordingCardPort();
        final restoredController = RecordingCardController(
          port: restoredPort,
          localRecordingRepository: LocalRecordingRepository(
            database: database,
            fileStorage: storage,
          ),
          platformPermissionsPort: _FakePlatformPermissionsPort(),
          bindingTokenProvider: _bindingToken,
        );
        addTearDown(restoredController.dispose);
        await restoredController.connect();
        await restoredController.scanFiles();

        expect(
          restoredController.state.snapshot.files.single.syncState,
          RecordingCardFileSyncState.synced,
        );
        expect(
          restoredController.state.snapshot.files.single.localFileId,
          downloaded.recordingId,
        );
        expect(repository.list().rows.single.displayName, '用户重命名的录音.m4a');

        restoredPort.emit(
          restoredPort.runtimeSnapshot.copyWith(
            files: <RecordingCardScannedFile>[
              restoredPort.scannedFile.copyWith(
                syncState: RecordingCardFileSyncState.synced,
                localFileId: 'native-bogus-local-id',
                appPrivateUri:
                    'app-private://recording-card/native-bogus-local-id.m4a',
              ),
            ],
          ),
        );

        expect(
          restoredController.state.snapshot.files.single.syncState,
          RecordingCardFileSyncState.synced,
        );
        expect(
          restoredController.state.snapshot.files.single.localFileId,
          downloaded.recordingId,
        );
        expect(
          restoredController.state.snapshot.files.single.appPrivateUri,
          downloaded.appPrivateUri,
        );
      },
    );

    test(
      'a second card cannot inherit a same-key native synced projection',
      () async {
        final database = AppDatabase();
        const storage = _RecordingCardFileStorage();
        final repository = LocalRecordingRepository(
          database: database,
          fileStorage: storage,
        );
        final firstPort = _FakeRecordingCardPort();
        final firstController = RecordingCardController(
          port: firstPort,
          localRecordingRepository: repository,
          platformPermissionsPort: _FakePlatformPermissionsPort(),
          bindingTokenProvider: _bindingToken,
        );
        addTearDown(firstController.dispose);
        await firstController.connect();
        await _awaitAutomaticScan(firstController, firstPort);
        await firstController.downloadFile(
          firstController.state.snapshot.files.single,
        );
        final firstLocal = repository.list().rows.single;
        final polluted = firstPort.scannedFile.copyWith(
          syncState: RecordingCardFileSyncState.synced,
          localFileId: firstLocal.recordingId,
          appPrivateUri: firstLocal.appPrivateUri,
        );
        final secondPort = _FakeRecordingCardPort(
          scannedFile: polluted,
          serialNumber: 'CARD-000002',
          safeDeviceFingerprint: 'card-fingerprint-2',
        );
        final secondController = RecordingCardController(
          port: secondPort,
          localRecordingRepository: LocalRecordingRepository(
            database: database,
            fileStorage: storage,
          ),
          platformPermissionsPort: _FakePlatformPermissionsPort(),
          bindingTokenProvider: _bindingToken,
        );
        addTearDown(secondController.dispose);
        await secondController.connect();
        await _awaitAutomaticScan(secondController, secondPort);

        final secondFile = secondController.state.snapshot.files.single;
        expect(secondFile.syncState, RecordingCardFileSyncState.deviceOnly);
        expect(secondFile.localFileId, isNull);
        expect(secondFile.appPrivateUri, isNull);
      },
    );

    test(
      'fresh controller rejects a persisted link when hashes disagree',
      () async {
        const downloadedHash =
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
        const differentHash =
            'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
        final database = AppDatabase();
        const storage = _RecordingCardFileStorage(contentHash: downloadedHash);
        final repository = LocalRecordingRepository(
          database: database,
          fileStorage: storage,
        );
        final firstController = RecordingCardController(
          port: _FakeRecordingCardPort(
            scannedFile: _file(contentHash: downloadedHash),
          ),
          localRecordingRepository: repository,
          platformPermissionsPort: _FakePlatformPermissionsPort(),
          bindingTokenProvider: _bindingToken,
        );
        addTearDown(firstController.dispose);
        await firstController.connect();
        await firstController.scanFiles();
        await firstController.downloadFile(
          firstController.state.snapshot.files.single,
        );
        expect(repository.list().rows.single.contentHash, downloadedHash);

        final restoredController = RecordingCardController(
          port: _FakeRecordingCardPort(
            scannedFile: _file(contentHash: differentHash),
          ),
          localRecordingRepository: LocalRecordingRepository(
            database: database,
            fileStorage: storage,
          ),
          platformPermissionsPort: _FakePlatformPermissionsPort(),
          bindingTokenProvider: _bindingToken,
        );
        addTearDown(restoredController.dispose);
        await restoredController.connect();
        await restoredController.scanFiles();

        expect(
          restoredController.state.snapshot.files.single.syncState,
          RecordingCardFileSyncState.deviceOnly,
        );
        expect(
          restoredController.state.snapshot.files.single.localFileId,
          isNull,
        );
      },
    );

    test('BLE receipt hash conflict is rejected before registration', () async {
      const directoryHash =
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      const downloadedHash =
          'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
      final repository = _repository();
      final port = _FakeRecordingCardPort(
        scannedFile: _file(contentHash: directoryHash),
        downloadedContentHash: downloadedHash,
      );
      final controller = RecordingCardController(
        port: port,
        localRecordingRepository: repository,
        platformPermissionsPort: _FakePlatformPermissionsPort(),
        bindingTokenProvider: _bindingToken,
      );
      addTearDown(controller.dispose);
      await controller.connect();
      await _awaitAutomaticScan(controller, port);
      expect(
        controller.hasActiveDeviceOperation,
        isFalse,
        reason:
            'directory completion must release ${controller.state.operation.kind} '
            'before a transfer begins',
      );

      await controller.downloadFile(controller.state.snapshot.files.single);

      expect(port.bleDownloadCallCount, 1);
      expect(
        controller.state.lastErrorCode,
        'RECORDING_CARD_DOWNLOAD_HASH_MISMATCH',
        reason:
            'status=${controller.state.status}, '
            'operation=${controller.state.operation.phase}/'
            '${controller.state.operation.kind}/'
            '${controller.state.operation.errorCode}, '
            'catalog=${controller.state.fileCatalog.phase}/'
            '${controller.state.fileCatalog.errorCode}',
      );
      expect(repository.list().rows, isEmpty);
      expect(controller.state.lastDownloadedFile, isNull);
    });

    test(
      'hashless exact download requires trusted matching directory size',
      () async {
        final database = AppDatabase();
        const storage = _RecordingCardFileStorage();
        final repository = LocalRecordingRepository(
          database: database,
          fileStorage: storage,
        );
        final registered = await repository.registerDownloadedRecording(
          file: const PrivateAudioFile(
            fileId: 'recording-card/exact-card-file.m4a',
            appPrivateUri: 'app-private://recording-card/exact-card-file.m4a',
            displayName: 'Exact card recording.m4a',
            mimeType: 'audio/mp4',
            sizeBytes: 4096,
            durationSeconds: 20,
          ),
          deviceId: 'card-fingerprint-1',
          deviceFileId: 'card-file-1',
          deviceFingerprint: 'card-fingerprint-1',
          deviceFilename: '20260701090000',
          downloadedAt: DateTime.utc(2026, 7, 1, 9),
        );
        expect(registered.ok, isTrue);

        final port = _FakeRecordingCardPort(
          scannedFile: _file(
            sizeBytes: 8192,
            sizeConfidence: RecordingCardFileSizeConfidence.suspect,
          ),
        );
        final controller = RecordingCardController(
          port: port,
          localRecordingRepository: LocalRecordingRepository(
            database: database,
            fileStorage: storage,
          ),
          platformPermissionsPort: _FakePlatformPermissionsPort(),
          bindingTokenProvider: _bindingToken,
        );
        addTearDown(controller.dispose);
        await controller.connect();
        await controller.scanFiles();
        await controller.scanFiles();

        final file = controller.state.snapshot.files.single;
        expect(file.syncState, RecordingCardFileSyncState.deviceOnly);
        expect(file.localFileId, isNull);
        expect(file.appPrivateUri, isNull);
        expect(port.bleDownloadCallCount, 0);

        final missingSizePort = _FakeRecordingCardPort(
          scannedFile: _file(sizeBytes: null),
        );
        final missingSizeController = RecordingCardController(
          port: missingSizePort,
          localRecordingRepository: LocalRecordingRepository(
            database: database,
            fileStorage: storage,
          ),
          platformPermissionsPort: _FakePlatformPermissionsPort(),
          bindingTokenProvider: _bindingToken,
        );
        addTearDown(missingSizeController.dispose);
        await missingSizeController.connect();
        await missingSizeController.scanFiles();

        expect(
          missingSizeController.state.snapshot.files.single.syncState,
          RecordingCardFileSyncState.deviceOnly,
        );
        expect(missingSizePort.bleDownloadCallCount, 0);

        final matchingSizePort = _FakeRecordingCardPort(
          scannedFile: _file(
            sizeBytes: 4096,
            sizeConfidence: RecordingCardFileSizeConfidence.trusted,
          ),
        );
        final matchingSizeController = RecordingCardController(
          port: matchingSizePort,
          localRecordingRepository: LocalRecordingRepository(
            database: database,
            fileStorage: storage,
          ),
          platformPermissionsPort: _FakePlatformPermissionsPort(),
          bindingTokenProvider: _bindingToken,
        );
        addTearDown(matchingSizeController.dispose);
        await matchingSizeController.connect();
        await matchingSizeController.scanFiles();

        expect(
          matchingSizeController.state.snapshot.files.single.syncState,
          RecordingCardFileSyncState.synced,
        );
        expect(
          matchingSizeController.state.snapshot.files.single.localFileId,
          registered.value!.recordingId,
        );

        const laterDeviceHash =
            'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
        final hashedDirectoryPort = _FakeRecordingCardPort(
          scannedFile: _file(contentHash: laterDeviceHash),
        );
        final hashedDirectoryController = RecordingCardController(
          port: hashedDirectoryPort,
          localRecordingRepository: LocalRecordingRepository(
            database: database,
            fileStorage: storage,
          ),
          platformPermissionsPort: _FakePlatformPermissionsPort(),
          bindingTokenProvider: _bindingToken,
        );
        addTearDown(hashedDirectoryController.dispose);
        await hashedDirectoryController.connect();
        await hashedDirectoryController.scanFiles();

        expect(
          hashedDirectoryController.state.snapshot.files.single.syncState,
          RecordingCardFileSyncState.deviceOnly,
        );
        expect(hashedDirectoryPort.bleDownloadCallCount, 0);
      },
    );

    test(
      'local sync revalidation marks a confirmed missing download explicitly',
      () async {
        var localFileExists = true;
        final storage = _RecordingCardFileStorage(
          statExists: () => localFileExists,
        );
        final controller = RecordingCardController(
          port: _FakeRecordingCardPort(),
          localRecordingRepository: LocalRecordingRepository(
            database: AppDatabase(),
            fileStorage: storage,
          ),
          platformPermissionsPort: _FakePlatformPermissionsPort(),
          bindingTokenProvider: _bindingToken,
        );
        addTearDown(controller.dispose);
        await controller.connect();
        await controller.scanFiles();
        await controller.downloadFile(controller.state.snapshot.files.single);
        expect(
          controller.state.snapshot.files.single.syncState,
          RecordingCardFileSyncState.synced,
        );

        localFileExists = false;
        await controller.refreshLocalSyncState();

        expect(
          controller.state.snapshot.files.single.syncState,
          RecordingCardFileSyncState.localMissing,
        );
        expect(controller.state.snapshot.files.single.localFileId, isNull);
      },
    );

    test(
      'fresh controller does not reuse another fingerprint by size alone',
      () async {
        final database = AppDatabase();
        const storage = _RecordingCardFileStorage();
        final repository = LocalRecordingRepository(
          database: database,
          fileStorage: storage,
        );
        final oldDownload = await repository.registerDownloadedRecording(
          file: const PrivateAudioFile(
            fileId: 'recording-card/legacy-card-file.m4a',
            appPrivateUri: 'app-private://recording-card/legacy-card-file.m4a',
            displayName: 'Legacy card recording.m4a',
            mimeType: 'audio/mp4',
            sizeBytes: 4096,
            durationSeconds: 38,
          ),
          deviceId: 'legacy-card-fingerprint',
          deviceFileId: 'card-file-1',
          deviceFingerprint: 'legacy-card-fingerprint',
          deviceFilename: '20260701090000',
          downloadedAt: DateTime.utc(2026, 7, 1, 9),
        );
        final currentDeviceHistory = await repository
            .registerDownloadedRecording(
              file: const PrivateAudioFile(
                fileId: 'recording-card/current-card-file.m4a',
                appPrivateUri:
                    'app-private://recording-card/current-card-file.m4a',
                displayName: 'Current card recording.m4a',
                mimeType: 'audio/mp4',
                sizeBytes: 4096,
                durationSeconds: 20,
              ),
              deviceId: 'card-fingerprint-1',
              deviceFileId: 'card-file-2',
              deviceFingerprint: 'card-fingerprint-1',
              deviceFilename: '20260701093000',
              downloadedAt: DateTime.utc(2026, 7, 1, 9, 30),
            );
        expect(oldDownload.ok, isTrue);
        expect(currentDeviceHistory.ok, isTrue);

        final controller = RecordingCardController(
          port: _FakeRecordingCardPort(
            scannedFile: _file(
              sizeConfidence: RecordingCardFileSizeConfidence.trusted,
            ),
          ),
          localRecordingRepository: LocalRecordingRepository(
            database: database,
            fileStorage: storage,
          ),
          platformPermissionsPort: _FakePlatformPermissionsPort(),
          bindingTokenProvider: _bindingToken,
        );
        addTearDown(controller.dispose);
        await controller.connect();
        await controller.scanFiles();

        expect(
          controller.state.snapshot.deviceState.safeDeviceFingerprint,
          'card-fingerprint-1',
        );
        expect(
          controller.state.snapshot.files.single.syncState,
          RecordingCardFileSyncState.deviceOnly,
        );
        expect(controller.state.snapshot.files.single.localFileId, isNull);
        expect(controller.state.snapshot.files.single.appPrivateUri, isNull);
      },
    );

    test(
      'concurrent scans share one request and failure preserves old rows',
      () async {
        final port = _FakeRecordingCardPort();
        final controller = _controllerFor(port);
        addTearDown(controller.dispose);
        await controller.connect();
        await _awaitAutomaticScan(controller, port);
        final initialScanCount = port.scanFilesCallCount;
        final deferred =
            Completer<RecordingCardResult<List<RecordingCardScannedFile>>>();
        port.scanFilesCompleter = deferred;

        final first = controller.scanFiles();
        final second = controller.scanFiles();
        expect(port.scanFilesCallCount, initialScanCount + 1);
        deferred.complete(
          RecordingCardResult<List<RecordingCardScannedFile>>.success(
            <RecordingCardScannedFile>[port.scannedFile],
          ),
        );
        await Future.wait(<Future<void>>[first, second]);
        expect(controller.hasActiveDeviceOperation, isFalse);

        expect(controller.state.snapshot.files, <RecordingCardScannedFile>[
          port.scannedFile,
        ]);
        port.scanFilesCompleter = null;
        port.failNextScan = true;
        await controller.scanFiles();

        expect(port.scanFilesCallCount, initialScanCount + 2);
        expect(controller.state.lastErrorCode, 'RECORDING_CARD_SCAN_FAILED');
        expect(controller.state.snapshot.files, <RecordingCardScannedFile>[
          port.scannedFile,
        ]);
      },
    );

    test(
      'device info refresh is single-flight for the current connection',
      () async {
        final port = _FakeRecordingCardPort();
        final controller = _controllerFor(port);
        addTearDown(controller.dispose);
        await controller.connect();
        await _awaitAutomaticScan(controller, port);
        expect(controller.hasLoadedFilesForCurrentConnection, isTrue);
        final deferred =
            Completer<RecordingCardResult<RecordingCardRuntimeSnapshot>>();
        port.refreshDeviceInfoCompleter = deferred;

        final first = controller.refreshDeviceInfo();
        final second = controller.refreshDeviceInfo();

        expect(port.refreshDeviceInfoCallCount, 1);
        expect(
          controller.state.status,
          RecordingCardControllerStatus.refreshing,
        );
        deferred.complete(
          RecordingCardResult<RecordingCardRuntimeSnapshot>.success(
            port.runtimeSnapshot,
          ),
        );
        await Future.wait(<Future<void>>[first, second]);

        expect(controller.state.status, RecordingCardControllerStatus.idle);
      },
    );

    test(
      'successful directory revision advances only after verified reads',
      () async {
        final port = _FakeRecordingCardPort();
        final controller = _controllerFor(port);
        addTearDown(controller.dispose);

        await controller.connect();
        await _awaitAutomaticScan(controller, port);
        final connectedRevision = controller.successfulFileRefreshRevision;
        expect(connectedRevision, 1);

        port.failNextScan = true;
        await controller.scanFiles();
        expect(controller.successfulFileRefreshRevision, connectedRevision);
        expect(
          controller.state.fileCatalog.phase,
          RecordingCardFileCatalogPhase.failed,
        );

        await controller.scanFiles();
        expect(controller.successfulFileRefreshRevision, connectedRevision + 1);
      },
    );

    test(
      'foreground reconciliation separates initial activation from real resume',
      () async {
        final port = _FakeRecordingCardPort();
        final controller = _controllerFor(port);
        addTearDown(controller.dispose);
        await controller.connect();
        await _awaitAutomaticScan(controller, port);

        final initialScanCount = port.scanFilesCallCount;
        await controller.reconcileConnectionState(refreshDirectory: false);
        expect(port.scanFilesCallCount, initialScanCount);

        await controller.reconcileConnectionState(refreshDirectory: true);
        expect(port.scanFilesCallCount, initialScanCount + 1);

        await controller.reconcileConnectionState(refreshDirectory: true);
        expect(port.scanFilesCallCount, initialScanCount + 2);

        port._snapshot = port.runtimeSnapshot.copyWith(
          deviceState: RecordingCardDeviceState.disconnected(),
        );
        await controller.reconcileConnectionState();
        expect(
          controller.state.snapshot.deviceState.isOperationallyConnected,
          isFalse,
        );
        expect(controller.state.snapshot.files, isEmpty);
        expect(controller.hasLoadedFilesForCurrentConnection, isFalse);
        expect(port.scanFilesCallCount, initialScanCount + 2);
      },
    );

    test(
      'concurrent foreground reconciliations share one connection query',
      () async {
        final port = _FakeRecordingCardPort();
        final controller = _controllerFor(port);
        addTearDown(controller.dispose);
        await controller.connect();
        await _awaitAutomaticScan(controller, port);
        final initialQueryCount = port.getConnectionStateCallCount;
        final initialScanCount = port.scanFilesCallCount;
        final deferred =
            Completer<RecordingCardResult<RecordingCardDeviceState>>();
        port.getConnectionStateCompleter = deferred;

        final initialActivation = controller.reconcileConnectionState(
          refreshDirectory: false,
        );
        final realResume = controller.reconcileConnectionState(
          refreshDirectory: true,
        );

        expect(identical(initialActivation, realResume), isTrue);
        expect(controller.canRefreshFilesNow, isFalse);
        expect(port.getConnectionStateCallCount, initialQueryCount + 1);
        port.getConnectionStateCompleter = null;
        deferred.complete(
          RecordingCardResult<RecordingCardDeviceState>.success(
            port.runtimeSnapshot.deviceState,
          ),
        );
        await Future.wait(<Future<void>>[initialActivation, realResume]);

        expect(port.getConnectionStateCallCount, initialQueryCount + 1);
        expect(port.scanFilesCallCount, initialScanCount + 1);
      },
    );

    test('late foreground query cannot restore a disconnected card', () async {
      final port = _FakeRecordingCardPort();
      final controller = _controllerFor(port);
      addTearDown(controller.dispose);
      await controller.connect();
      await _awaitAutomaticScan(controller, port);
      final connected = port.runtimeSnapshot.deviceState;
      final initialScanCount = port.scanFilesCallCount;
      final initialDeviceInfoCount = port.refreshDeviceInfoCallCount;
      final deferred =
          Completer<RecordingCardResult<RecordingCardDeviceState>>();
      port.getConnectionStateCompleter = deferred;

      final reconciliation = controller.reconcileConnectionState(
        refreshDirectory: true,
      );
      await _waitFor(() => port.getConnectionStateCallCount == 1);
      await controller.disconnect();
      deferred.complete(
        RecordingCardResult<RecordingCardDeviceState>.success(connected),
      );
      await reconciliation;

      expect(
        controller.state.snapshot.deviceState.isOperationallyConnected,
        isFalse,
      );
      expect(controller.state.snapshot.files, isEmpty);
      expect(port.refreshDeviceInfoCallCount, initialDeviceInfoCount);
      expect(port.scanFilesCallCount, initialScanCount);
    });

    test(
      'superseded foreground authorization cannot disconnect discovery owner',
      () async {
        final staleAuthorization = Completer<RecordingCardResult<bool>>();
        final authorization = _FakeConnectionAuthorization.success()
          ..pendingResult = staleAuthorization;
        final port = _FakeRecordingCardPort(serialNumber: 'CARD-RECONCILE-001');
        final controller = _controllerFor(
          port,
          connectionAuthorization: authorization,
        );
        addTearDown(controller.dispose);
        const connected = RecordingCardDeviceState(
          connectionState: RecordingCardConnectionState.connected,
          connectionStage: RecordingCardConnectionStage.connected,
          displayName: 'Huahuo FW920',
          safeDeviceFingerprint: 'card-fingerprint-1',
          serialNumber: 'CARD-RECONCILE-001',
          recordingFormat: RecordingCardFileFormat.m4a,
        );
        port._snapshot = port.runtimeSnapshot.copyWith(deviceState: connected);

        final reconciliation = controller.reconcileConnectionState(
          refreshDirectory: false,
        );
        await _waitFor(() => authorization.callCount == 1);
        final discoveryGate =
            Completer<
              RecordingCardResult<List<RecordingCardDiscoveredDevice>>
            >();
        port.scanDevicesCompleter = discoveryGate;
        final discovery = controller.scanDevices();
        await _waitFor(() => port.scanDevicesCallCount == 1);

        staleAuthorization.complete(
          RecordingCardResult<bool>.failure(
            recordingCardFailure(
              'RECORDING_CARD_CLOUD_BINDING_REJECTED',
              'Late reconciliation authorization was rejected',
            ),
          ),
        );
        await reconciliation;

        expect(port.disconnectCallCount, 0);
        authorization.pendingResult = null;
        port.scanDevicesCompleter = null;
        discoveryGate.complete(
          RecordingCardResult<List<RecordingCardDiscoveredDevice>>.success(
            port.discoveredDevices,
          ),
        );
        await discovery;
        await controller.reconcileConnectionState(refreshDirectory: false);

        expect(authorization.callCount, 2);
        expect(port.disconnectCallCount, 0);
        expect(
          controller.state.snapshot.deviceState.isOperationallyConnected,
          isTrue,
        );
        expect(controller.state.lastErrorCode, isNull);
      },
    );

    test(
      'foreground connection query failure locks the retained catalog once',
      () async {
        final port = _FakeRecordingCardPort();
        final controller = _controllerFor(port);
        addTearDown(controller.dispose);
        await controller.connect();
        await _awaitAutomaticScan(controller, port);
        final retainedFiles = controller.state.snapshot.files;
        final initialQueryCount = port.getConnectionStateCallCount;
        final initialScanCount = port.scanFilesCallCount;
        final deferred =
            Completer<RecordingCardResult<RecordingCardDeviceState>>();
        port.getConnectionStateCompleter = deferred;

        final reconciliation = controller.reconcileConnectionState(
          refreshDirectory: true,
        );
        deferred.complete(
          RecordingCardResult<RecordingCardDeviceState>.failure(
            _failure('RECORDING_CARD_CONNECTION_QUERY_FAILED'),
          ),
        );
        await reconciliation;
        await Future<void>.delayed(Duration.zero);

        expect(port.getConnectionStateCallCount, initialQueryCount + 1);
        expect(port.scanFilesCallCount, initialScanCount);
        expect(controller.state.snapshot.files, retainedFiles);
        expect(
          controller.state.fileCatalog.phase,
          RecordingCardFileCatalogPhase.failed,
        );
        expect(
          controller.state.fileCatalog.errorCode,
          'RECORDING_CARD_CONNECTION_QUERY_FAILED',
        );
        expect(controller.state.status, RecordingCardControllerStatus.error);
      },
    );

    test(
      'production auto-sync adapter retries a failed catalog read',
      () async {
        final port = _FakeRecordingCardPort();
        final controller = _controllerFor(port);
        addTearDown(controller.dispose);
        await controller.connect();
        await _awaitAutomaticScan(controller, port);
        final successfulRevision = controller.successfulFileRefreshRevision;

        port.failNextScan = true;
        await controller.scanFiles();
        final failedScanCount = port.scanFilesCallCount;
        expect(
          controller.state.fileCatalog.phase,
          RecordingCardFileCatalogPhase.failed,
        );

        final result = await ControllerRecordingCardAutoSyncActions(
          controller,
        ).loadConnectionFiles();

        expect(result.ok, isTrue);
        expect(port.scanFilesCallCount, failedScanCount + 1);
        expect(
          controller.successfulFileRefreshRevision,
          successfulRevision + 1,
        );
        expect(
          controller.state.fileCatalog.phase,
          RecordingCardFileCatalogPhase.ready,
        );
      },
    );

    test(
      'production auto-sync adapter awaits any same-session scan owner',
      () async {
        final port = _FakeRecordingCardPort();
        final controller = _controllerFor(port);
        addTearDown(controller.dispose);
        await controller.connect();
        await _awaitAutomaticScan(controller, port);
        final initialScanCount = port.scanFilesCallCount;
        final replacement = _fileWithId(2);
        final deferred =
            Completer<RecordingCardResult<List<RecordingCardScannedFile>>>();
        port.scanFilesCompleter = deferred;

        final scan = controller.scanFiles();
        await _waitFor(() => port.scanFilesCallCount == initialScanCount + 1);
        var adapterSettled = false;
        final load = ControllerRecordingCardAutoSyncActions(
          controller,
        ).loadConnectionFiles().whenComplete(() => adapterSettled = true);
        await Future<void>.delayed(Duration.zero);

        expect(adapterSettled, isFalse);
        deferred.complete(
          RecordingCardResult<List<RecordingCardScannedFile>>.success(
            <RecordingCardScannedFile>[replacement],
          ),
        );
        final result = await load;
        await scan;

        expect(result.ok, isTrue);
        expect(result.value, <RecordingCardScannedFile>[replacement]);
        expect(port.scanFilesCallCount, initialScanCount + 1);
      },
    );

    test(
      'production auto-sync adapter rejects a forced read while recording',
      () async {
        final port = _FakeRecordingCardPort();
        final controller = _controllerFor(port);
        addTearDown(controller.dispose);
        await controller.connect();
        await _awaitAutomaticScan(controller, port);
        final successfulRevision = controller.successfulFileRefreshRevision;
        final scanCount = port.scanFilesCallCount;
        await controller.startRecording();

        final result = await ControllerRecordingCardAutoSyncActions(
          controller,
        ).loadConnectionFiles(forceRefresh: true);

        expect(result.ok, isFalse);
        expect(result.error?.code, 'RECORDING_CARD_RECORDING_ACTIVE');
        expect(port.scanFilesCallCount, scanCount);
        expect(controller.successfulFileRefreshRevision, successfulRevision);
      },
    );

    test(
      'foreground resume waits for transfer and consumes one deferred read',
      () async {
        final port = _FakeRecordingCardPort()
          .._directoryFiles = <RecordingCardScannedFile>[
            _fileWithId(1),
            _fileWithId(2),
          ];
        final controller = _controllerFor(port);
        addTearDown(controller.dispose);
        await controller.connect();
        await _awaitAutomaticScan(controller, port);
        final scanCount = port.scanFilesCallCount;
        final deferred =
            Completer<RecordingCardResult<RecordingCardDownloadedFile>>();
        port.bleDownloadCompleter = deferred;

        final transfer = controller.downloadFile(
          controller.state.snapshot.files.first,
          refreshAfterTransfer: false,
        );
        await _waitFor(() => port.bleDownloadCallCount == 1);
        await controller.reconcileConnectionState(refreshDirectory: true);
        expect(port.scanFilesCallCount, scanCount);

        deferred.complete(
          RecordingCardResult<RecordingCardDownloadedFile>.failure(
            _failure('RECORDING_CARD_TRANSFER_CANCELLED'),
          ),
        );
        await transfer;
        final secondDeferred =
            Completer<RecordingCardResult<RecordingCardDownloadedFile>>();
        port.bleDownloadCompleter = secondDeferred;
        final secondTransfer = controller.downloadFile(
          controller.state.snapshot.files.last,
          refreshAfterTransfer: false,
        );
        await _waitFor(() => port.bleDownloadCallCount == 2);
        await Future<void>.delayed(Duration.zero);
        expect(port.scanFilesCallCount, scanCount);

        secondDeferred.complete(
          RecordingCardResult<RecordingCardDownloadedFile>.failure(
            _failure('RECORDING_CARD_TRANSFER_CANCELLED'),
          ),
        );
        await secondTransfer;
        await _waitFor(() => port.scanFilesCallCount == scanCount + 1);
        await Future<void>.delayed(Duration.zero);

        expect(port.scanFilesCallCount, scanCount + 1);
      },
    );

    test(
      'foreground recording completion waits for one settlement scan',
      () async {
        final port = _FakeRecordingCardPort();
        final controller = RecordingCardController(
          port: port,
          localRecordingRepository: _repository(),
          platformPermissionsPort: _FakePlatformPermissionsPort(),
          bindingTokenProvider: _bindingToken,
          recordingCompletionScanDelays: const <Duration>[
            Duration(milliseconds: 40),
          ],
        );
        addTearDown(controller.dispose);
        await controller.connect();
        await _awaitAutomaticScan(controller, port);
        final initialScanCount = port.scanFilesCallCount;
        final observedAt = DateTime.utc(2026, 9, 4, 12);
        const recording = RecordingCardRecordingInfo(
          state: RecordingCardRecordingState.recording,
        );
        port.emit(
          port.runtimeSnapshot.copyWith(
            recordingInfo: recording,
            recordingObservation: RecordingCardRecordingObservation(
              info: recording,
              source: RecordingCardObservationSource.statusNotification,
              revision: 1,
              observedAt: observedAt,
            ),
          ),
        );
        final idle = RecordingCardRecordingInfo.idle();
        port._snapshot = port.runtimeSnapshot.copyWith(
          recordingInfo: idle,
          recordingObservation: RecordingCardRecordingObservation(
            info: idle,
            source: RecordingCardObservationSource.deviceInfo,
            revision: 2,
            observedAt: observedAt.add(const Duration(seconds: 1)),
          ),
        );
        port.emitRefreshDeviceInfoResult = true;
        var settled = false;

        final resume = controller
            .reconcileConnectionState(refreshDirectory: true)
            .whenComplete(() {
              settled = true;
            });
        await _waitFor(() => port.refreshDeviceInfoCallCount == 1);
        await Future<void>.delayed(const Duration(milliseconds: 10));

        expect(settled, isFalse);
        expect(port.scanFilesCallCount, initialScanCount);

        await resume;

        expect(settled, isTrue);
        expect(port.scanFilesCallCount, initialScanCount + 1);
      },
    );

    test(
      'recording settlement stays with the card that emitted the idle edge',
      () async {
        final port = _FakeRecordingCardPort();
        final controller = RecordingCardController(
          port: port,
          localRecordingRepository: _repository(),
          platformPermissionsPort: _FakePlatformPermissionsPort(),
          bindingTokenProvider: _bindingToken,
          recordingCompletionScanDelays: const <Duration>[
            Duration(milliseconds: 30),
          ],
        );
        addTearDown(controller.dispose);
        await controller.connect();
        await _awaitAutomaticScan(controller, port);
        final initialScanCount = port.scanFilesCallCount;
        const recording = RecordingCardRecordingInfo(
          state: RecordingCardRecordingState.recording,
        );
        port.emit(
          port.runtimeSnapshot.copyWith(
            recordingInfo: recording,
            recordingObservation: RecordingCardRecordingObservation(
              info: recording,
              source: RecordingCardObservationSource.statusNotification,
              revision: 1,
              observedAt: DateTime.utc(2026, 9, 4, 13),
            ),
          ),
        );
        final idle = RecordingCardRecordingInfo.idle();
        port.emit(
          port.runtimeSnapshot.copyWith(
            recordingInfo: idle,
            recordingObservation: RecordingCardRecordingObservation(
              info: idle,
              source: RecordingCardObservationSource.statusNotification,
              revision: 2,
              observedAt: DateTime.utc(2026, 9, 4, 13, 0, 1),
            ),
          ),
        );
        const cardB = RecordingCardDeviceState(
          connectionState: RecordingCardConnectionState.connected,
          connectionStage: RecordingCardConnectionStage.connected,
          displayName: 'Huahuo FW920 B',
          safeDeviceFingerprint: 'card-fingerprint-2',
          recordingFormat: RecordingCardFileFormat.m4a,
        );
        port.emit(
          port.runtimeSnapshot.copyWith(
            deviceState: cardB,
            files: const <RecordingCardScannedFile>[],
          ),
        );

        await _waitFor(() => port.scanFilesCallCount == initialScanCount + 1);
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(port.scanFilesCallCount, initialScanCount + 1);
        expect(
          controller.state.snapshot.deviceState.safeDeviceFingerprint,
          'card-fingerprint-2',
        );
      },
    );

    test(
      'foreground read drains after an idle recording command settles',
      () async {
        final port = _FakeRecordingCardPort();
        final controller = _controllerFor(port);
        addTearDown(controller.dispose);
        await controller.connect();
        await _awaitAutomaticScan(controller, port);
        final initialScanCount = port.scanFilesCallCount;
        final initialDeviceInfoCount = port.refreshDeviceInfoCallCount;
        final deferredCommand =
            Completer<RecordingCardResult<RecordingCardRecordingInfo>>();
        port.readRecordingStateCompleter = deferredCommand;

        final command = controller.readRecordingState();
        await _waitFor(() => port.readRecordingStateCallCount == 1);
        await controller.reconcileConnectionState(refreshDirectory: true);
        expect(port.scanFilesCallCount, initialScanCount);

        deferredCommand.complete(
          RecordingCardResult<RecordingCardRecordingInfo>.success(
            RecordingCardRecordingInfo.idle(),
          ),
        );
        await command;
        await _waitFor(() => port.scanFilesCallCount == initialScanCount + 1);

        expect(port.scanFilesCallCount, initialScanCount + 1);
        expect(port.refreshDeviceInfoCallCount, initialDeviceInfoCount + 1);
      },
    );

    test(
      'foreground read drains after an existing device-info read settles',
      () async {
        final port = _FakeRecordingCardPort();
        final controller = _controllerFor(port);
        addTearDown(controller.dispose);
        await controller.connect();
        await _awaitAutomaticScan(controller, port);
        final initialScanCount = port.scanFilesCallCount;
        final initialDeviceInfoCount = port.refreshDeviceInfoCallCount;
        final deferredInfo =
            Completer<RecordingCardResult<RecordingCardRuntimeSnapshot>>();
        port.refreshDeviceInfoCompleter = deferredInfo;

        final deviceInfo = controller.refreshDeviceInfo();
        await _waitFor(
          () => port.refreshDeviceInfoCallCount == initialDeviceInfoCount + 1,
        );
        await controller.reconcileConnectionState(refreshDirectory: true);
        expect(port.scanFilesCallCount, initialScanCount);

        port.refreshDeviceInfoCompleter = null;
        deferredInfo.complete(
          RecordingCardResult<RecordingCardRuntimeSnapshot>.success(
            port.runtimeSnapshot,
          ),
        );
        await deviceInfo;
        await _waitFor(() => port.scanFilesCallCount == initialScanCount + 1);

        expect(port.scanFilesCallCount, initialScanCount + 1);
        expect(port.refreshDeviceInfoCallCount, initialDeviceInfoCount + 2);
      },
    );

    test(
      'recording commands and directory reads yield to transfer latch',
      () async {
        final port = _FakeRecordingCardPort();
        final controller = _controllerFor(port);
        addTearDown(controller.dispose);
        await controller.connect();
        await _awaitAutomaticScan(controller, port);
        final file = controller.state.snapshot.files.single;
        final scanCount = port.scanFilesCallCount;
        final deferred =
            Completer<RecordingCardResult<RecordingCardDownloadedFile>>();
        port.bleDownloadCompleter = deferred;

        final transfer = controller.downloadFile(
          file,
          refreshAfterTransfer: false,
        );
        await _waitFor(() => port.bleDownloadCallCount == 1);
        expect(controller.hasActiveTransfer, isTrue);

        await controller.startRecording();
        await controller.scanFiles();
        expect(
          controller.state.snapshot.recordingInfo.state,
          RecordingCardRecordingState.idle,
        );
        expect(port.scanFilesCallCount, scanCount);

        deferred.complete(
          RecordingCardResult<RecordingCardDownloadedFile>.failure(
            _failure('RECORDING_CARD_TRANSFER_CANCELLED'),
          ),
        );
        await transfer;
        expect(controller.hasActiveTransfer, isFalse);
      },
    );

    test('device info refresh yields to an active directory scan', () async {
      final port = _FakeRecordingCardPort();
      final controller = _controllerFor(port);
      addTearDown(controller.dispose);
      await controller.connect();
      await _awaitAutomaticScan(controller, port);
      final initialRefreshCount = port.refreshDeviceInfoCallCount;
      final deferred =
          Completer<RecordingCardResult<List<RecordingCardScannedFile>>>();
      port.scanFilesCompleter = deferred;

      final scan = controller.scanFiles();
      await Future<void>.delayed(Duration.zero);
      await controller.refreshDeviceInfo();

      expect(port.refreshDeviceInfoCallCount, initialRefreshCount);
      expect(controller.state.status, RecordingCardControllerStatus.scanning);
      deferred.complete(
        RecordingCardResult<List<RecordingCardScannedFile>>.success(
          <RecordingCardScannedFile>[port.scannedFile],
        ),
      );
      await scan;
    });

    test(
      'late device info result cannot restore a disconnected card',
      () async {
        final port = _FakeRecordingCardPort();
        final controller = _controllerFor(port);
        addTearDown(controller.dispose);
        await controller.connect();
        await _awaitAutomaticScan(controller, port);
        final connectedSnapshot = port.runtimeSnapshot;
        final deferred =
            Completer<RecordingCardResult<RecordingCardRuntimeSnapshot>>();
        port.refreshDeviceInfoCompleter = deferred;

        final refresh = controller.refreshDeviceInfo();
        await controller.disconnect();
        deferred.complete(
          RecordingCardResult<RecordingCardRuntimeSnapshot>.success(
            connectedSnapshot,
          ),
        );
        await refresh;

        expect(
          controller.state.snapshot.deviceState.isOperationallyConnected,
          isFalse,
        );
        expect(controller.hasLoadedFilesForCurrentConnection, isFalse);
        expect(controller.state.status, RecordingCardControllerStatus.idle);
      },
    );

    test(
      'wifi preparation waits for scan and suppresses transfer refreshes',
      () async {
        final port = _FakeRecordingCardPort();
        final controller = _controllerFor(port);
        addTearDown(controller.dispose);
        await controller.connect();
        await _awaitAutomaticScan(controller, port);
        final initialScanCount = port.scanFilesCallCount;
        final deferred =
            Completer<RecordingCardResult<List<RecordingCardScannedFile>>>();
        port.scanFilesCompleter = deferred;

        final scan = controller.scanFiles();
        final prepare = controller.prepareWifiBatch(<RecordingCardScannedFile>[
          port.scannedFile,
        ]);
        await Future<void>.delayed(Duration.zero);
        expect(port.wifiSessionPrepareCallCount, 0);

        deferred.complete(
          RecordingCardResult<List<RecordingCardScannedFile>>.success(
            <RecordingCardScannedFile>[port.scannedFile],
          ),
        );
        await scan;
        final credentials = await prepare;
        expect(credentials.ok, isTrue);
        expect(port.wifiSessionPrepareCallCount, 1);
        expect(
          controller.state.wifiBatch?.state,
          RecordingCardWifiBatchState.awaitingHotspot,
        );

        await controller.readRecordingState();
        await controller.scanFiles();
        expect(port.readRecordingStateCallCount, 0);
        expect(port.scanFilesCallCount, initialScanCount + 1);
      },
    );

    test(
      'disconnect clears device directory and ignores a late scan result',
      () async {
        final port = _FakeRecordingCardPort();
        final controller = _controllerFor(port);
        addTearDown(controller.dispose);
        await controller.connect();
        await _awaitAutomaticScan(controller, port);
        expect(controller.state.snapshot.files, isNotEmpty);

        final deferred =
            Completer<RecordingCardResult<List<RecordingCardScannedFile>>>();
        port.scanFilesCompleter = deferred;
        final scan = controller.scanFiles();
        await Future<void>.delayed(Duration.zero);

        await controller.disconnect();

        expect(
          controller.state.snapshot.deviceState.isOperationallyConnected,
          isFalse,
        );
        expect(controller.state.snapshot.files, isEmpty);
        expect(controller.state.snapshot.transferProgress, isNull);
        expect(controller.state.activeFileKey, isNull);

        deferred.complete(
          RecordingCardResult<List<RecordingCardScannedFile>>.success(
            <RecordingCardScannedFile>[port.scannedFile],
          ),
        );
        await scan;

        expect(controller.state.snapshot.files, isEmpty);
        expect(controller.state.status, RecordingCardControllerStatus.idle);
      },
    );

    test(
      'starting disconnect invalidates a directory result before native reply',
      () async {
        final port = _FakeRecordingCardPort();
        final controller = _controllerFor(port);
        addTearDown(controller.dispose);
        await controller.connect();
        await _awaitAutomaticScan(controller, port);
        final successfulRevision = controller.successfulFileRefreshRevision;
        final deferredScan =
            Completer<RecordingCardResult<List<RecordingCardScannedFile>>>();
        final deferredDisconnect =
            Completer<RecordingCardResult<RecordingCardDeviceState>>();
        port.scanFilesCompleter = deferredScan;
        port.disconnectCompleter = deferredDisconnect;

        final scan = controller.scanFiles();
        await _waitFor(() => controller.isRefreshingFiles);
        final disconnect = controller.disconnect();
        deferredScan.complete(
          RecordingCardResult<List<RecordingCardScannedFile>>.success(
            <RecordingCardScannedFile>[port.scannedFile],
          ),
        );
        await scan;

        expect(controller.successfulFileRefreshRevision, successfulRevision);
        expect(
          controller.state.status,
          RecordingCardControllerStatus.disconnecting,
        );

        deferredDisconnect.complete(
          RecordingCardResult<RecordingCardDeviceState>.success(
            RecordingCardDeviceState.disconnected(),
          ),
        );
        await disconnect;

        expect(
          controller.state.snapshot.deviceState.connectionState,
          RecordingCardConnectionState.disconnected,
        );
        expect(controller.state.snapshot.files, isEmpty);
      },
    );

    test(
      'wifi join requests local-network permission before native join',
      () async {
        final operations = <String>[];
        final port = _FakeRecordingCardPort(operationLog: operations);
        final permissions = _FakePlatformPermissionsPort(
          statuses: const <PlatformPermissionKind, PlatformPermissionStatus>{
            PlatformPermissionKind.localNetwork:
                PlatformPermissionStatus.granted,
          },
          operationLog: operations,
        );
        final controller = _controllerFor(
          port,
          platformPermissionsPort: permissions,
          requiresBluetoothPermissionRequest: () => false,
          requiresWifiPermissionRequest: () => true,
        );
        addTearDown(controller.dispose);
        await controller.connect();
        await _awaitAutomaticScan(controller, port);
        operations.clear();

        final prepared = await controller.prepareWifiBatch(
          <RecordingCardScannedFile>[port.scannedFile],
        );
        final joined = await controller.joinPreparedWifiNetwork(
          prepared.value!,
        );

        expect(joined.ok, isTrue);
        expect(port.wifiJoinCallCount, 1);
        expect(permissions.requestedKinds, <Set<PlatformPermissionKind>>[
          <PlatformPermissionKind>{PlatformPermissionKind.localNetwork},
        ]);
        expect(operations, <String>[
          'prepareWifiSession',
          'permission',
          'joinWifiNetwork',
        ]);
      },
    );

    test(
      'denied local-network permission prevents native Wi-Fi join',
      () async {
        final port = _FakeRecordingCardPort();
        final permissions = _FakePlatformPermissionsPort(
          statuses: const <PlatformPermissionKind, PlatformPermissionStatus>{
            PlatformPermissionKind.localNetwork:
                PlatformPermissionStatus.denied,
          },
        );
        final controller = _controllerFor(
          port,
          platformPermissionsPort: permissions,
          requiresBluetoothPermissionRequest: () => false,
          requiresWifiPermissionRequest: () => true,
        );
        addTearDown(controller.dispose);
        await controller.connect();
        await _awaitAutomaticScan(controller, port);

        final prepared = await controller.prepareWifiBatch(
          <RecordingCardScannedFile>[port.scannedFile],
        );
        final joined = await controller.joinPreparedWifiNetwork(
          prepared.value!,
        );

        expect(joined.ok, isFalse);
        expect(joined.error?.code, 'RECORDING_CARD_WIFI_PERMISSION_REQUIRED');
        expect(port.wifiJoinCallCount, 0);
        expect(
          controller.state.wifiBatch?.state,
          RecordingCardWifiBatchState.paused,
        );
        expect(
          controller.state.wifiBatch?.failureCode,
          'RECORDING_CARD_WIFI_PERMISSION_REQUIRED',
        );
        expect(
          controller.state.lastErrorCode,
          'RECORDING_CARD_WIFI_PERMISSION_REQUIRED',
        );
      },
    );

    test('late Wi-Fi join result cannot replace a cancelled batch', () async {
      final port = _FakeRecordingCardPort();
      final controller = _controllerFor(
        port,
        requiresWifiPermissionRequest: () => false,
      );
      addTearDown(controller.dispose);
      await controller.connect();
      await _awaitAutomaticScan(controller, port);
      final prepared = await controller.prepareWifiBatch(
        <RecordingCardScannedFile>[port.scannedFile],
      );
      final joinGate = Completer<RecordingCardResult<bool>>();
      port.wifiJoinCompleter = joinGate;

      final joining = controller.joinPreparedWifiNetwork(prepared.value!);
      await _waitFor(() => port.wifiJoinCallCount == 1);
      await controller.cancelWifiBatch();
      expect(
        controller.state.wifiBatch?.state,
        RecordingCardWifiBatchState.cancelled,
      );

      joinGate.complete(RecordingCardResult<bool>.success(true));
      final joined = await joining;

      expect(joined.ok, isFalse);
      expect(joined.error?.code, 'RECORDING_CARD_WIFI_JOIN_SUPERSEDED');
      expect(
        controller.state.wifiBatch?.state,
        RecordingCardWifiBatchState.cancelled,
      );
      expect(controller.state.status, RecordingCardControllerStatus.idle);
    });

    test('suspect directory size accepts verified downloaded size', () async {
      final port = _FakeRecordingCardPort(
        scannedFile: _file(
          sizeBytes: 8192,
          sizeConfidence: RecordingCardFileSizeConfidence.suspect,
        ),
        downloadedSizeBytes: 4096,
      );
      final controller = _controllerFor(port);
      addTearDown(controller.dispose);
      await controller.connect();
      await controller.scanFiles();

      await controller.downloadFile(controller.state.snapshot.files.single);

      expect(controller.state.status, RecordingCardControllerStatus.idle);
      expect(controller.state.lastDownloadedFile?.sizeBytes, 4096);
    });

    test(
      'trusted directory mismatch accepts verified downloaded size',
      () async {
        final port = _FakeRecordingCardPort(
          scannedFile: _file(
            sizeBytes: 8192,
            sizeConfidence: RecordingCardFileSizeConfidence.trusted,
          ),
          downloadedSizeBytes: 4096,
        );
        final controller = _controllerFor(port);
        addTearDown(controller.dispose);
        await controller.connect();
        await controller.scanFiles();

        await controller.downloadFile(controller.state.snapshot.files.single);

        expect(controller.state.status, RecordingCardControllerStatus.idle);
        expect(controller.state.lastErrorCode, isNull);
        expect(controller.state.lastDownloadedFile?.sizeBytes, 4096);
      },
    );

    test(
      'Wi-Fi download uses the shared verified library registration path',
      () async {
        final port = _FakeRecordingCardPort();
        final controller = _controllerFor(port);
        addTearDown(controller.dispose);
        await controller.connect();
        await controller.scanFiles();

        await controller.downloadFileOverWifi(
          controller.state.snapshot.files.single,
        );

        expect(port.wifiDownloadCallCount, 1);
        expect(controller.state.status, RecordingCardControllerStatus.idle);
        expect(controller.state.lastErrorCode, isNull);
        expect(
          controller.state.snapshot.files.single.syncState,
          RecordingCardFileSyncState.synced,
        );
        expect(
          controller.state.lastDownloadedFile?.appPrivateUri,
          startsWith('app-private://recording-card/'),
        );
      },
    );

    test(
      'queued Wi-Fi batch waits for the explicit native start intent',
      () async {
        final port = _FakeRecordingCardPort();
        final controller = _controllerFor(port);
        addTearDown(controller.dispose);
        await controller.connect();
        await _awaitAutomaticScan(controller, port);

        final queued = await _queueWifiBatchForTest(
          controller,
          port,
          <RecordingCardScannedFile>[_fileWithId(1), _fileWithId(2)],
        );

        expect(queued.ok, isTrue);
        expect(port.wifiSessionPrepareCallCount, 0);
        expect(
          controller.state.wifiBatch?.state,
          RecordingCardWifiBatchState.queued,
        );

        final prepared = await controller.startQueuedWifiBatch();

        expect(prepared.ok, isTrue, reason: prepared.error?.code);
        expect(port.wifiSessionPrepareCallCount, 1);
        expect(
          controller.state.wifiBatch?.state,
          RecordingCardWifiBatchState.completed,
        );
      },
    );

    test(
      'Wi-Fi batch prepares once and registers files strictly serially',
      () async {
        final operations = <String>[];
        final port = _FakeRecordingCardPort(operationLog: operations);
        final repository = _repository(operationLog: operations);
        final controller = RecordingCardController(
          port: port,
          localRecordingRepository: repository,
          platformPermissionsPort: _FakePlatformPermissionsPort(),
          bindingTokenProvider: _bindingToken,
        );
        addTearDown(controller.dispose);
        await controller.connect();
        await _awaitAutomaticScan(controller, port);
        final initialScanCount = port.scanFilesCallCount;
        final files = <RecordingCardScannedFile>[
          _fileWithId(1),
          _fileWithId(2),
        ];

        final credentials = await _prepareWifiBatchForTest(
          controller,
          port,
          files,
        );
        expect(credentials.ok, isTrue);
        expect(
          controller.state.wifiBatch?.state,
          RecordingCardWifiBatchState.awaitingHotspot,
        );
        expect(
          controller.state.snapshot.deviceState.isOperationallyConnected,
          isFalse,
        );
        expect(
          port.runtimeSnapshot.deviceState.isOperationallyConnected,
          isTrue,
        );
        port.emit(port.runtimeSnapshot);
        expect(
          controller.state.snapshot.deviceState.isOperationallyConnected,
          isFalse,
        );
        operations.clear();
        await controller.startPreparedWifiBatch();

        expect(port.wifiSessionPrepareCallCount, 1);
        expect(port.wifiSessionOpenCallCount, 1);
        expect(port.wifiSessionCloseCallCount, 1);
        expect(port.wifiSessionDownloadedKeys, <String>[
          'card-file-1',
          'card-file-2',
        ]);
        expect(operations.take(6), <String>[
          'open',
          'download:card-file-1',
          'stat',
          'download:card-file-2',
          'stat',
          'close',
        ]);
        expect(
          controller.state.wifiBatch?.state,
          RecordingCardWifiBatchState.completed,
        );
        expect(controller.state.wifiBatch?.completedCount, 2);
        expect(repository.list().rows, hasLength(2));
        expect(port.connectCallCount, 2);
        expect(port.connectRequests.last?.forceScan, isTrue);
        expect(port.scanFilesCallCount, initialScanCount + 1);
        expect(port.refreshDeviceInfoCallCount, 1);
        expect(port.readRecordingStateCallCount, 1);
      },
    );

    test(
      'Wi-Fi batch reconnects the exact card after hotspot drops Bluetooth',
      () async {
        const serialNumber = 'CARD-WIFI-HOTSPOT-001';
        final operations = <String>[];
        final port = _RecoveryRecordingCardPort(
          operationLog: operations,
          serialNumber: serialNumber,
        );
        final repository = _repository(operationLog: operations);
        final controller = RecordingCardController(
          port: port,
          localRecordingRepository: repository,
          platformPermissionsPort: _FakePlatformPermissionsPort(),
          bindingTokenProvider: _bindingToken,
        );
        port.wifiBatchStateReader = () => controller.state.wifiBatch?.state;
        addTearDown(controller.dispose);
        await controller.connect();
        await _awaitAutomaticScan(controller, port);
        final initialScanCount = port.scanFilesCallCount;
        final files = <RecordingCardScannedFile>[
          _fileWithId(1),
          _fileWithId(2),
        ];

        port.emitFileDirectory(files);
        await controller.ensureFilesLoadedForCurrentConnection();
        final queued = await controller.queueWifiBatch(files);
        expect(queued.ok, isTrue, reason: queued.error?.code);
        operations.clear();

        final completed = await controller.startQueuedWifiBatch();
        expect(completed.ok, isTrue, reason: completed.error?.code);

        expect(port.wifiSessionDownloadedKeys, <String>[
          'card-file-1',
          'card-file-2',
        ]);
        expect(
          operations,
          containsAllInOrder(<String>[
            'prepareWifiSession',
            'joinWifiNetwork',
            'verifyWifiHandoff',
            'open',
            'download:card-file-1',
            'stat',
            'download:card-file-2',
            'stat',
            'close',
            'connect',
          ]),
        );
        expect(port.connectCallCount, 2);
        expect(
          port.connectRequests.last?.safeDeviceFingerprint,
          'card-fingerprint-1',
        );
        expect(
          port.connectRequests.last?.expectedSerialNumber,
          normalizeRecordingCardSerialNumberForOwnership(serialNumber),
        );
        expect(port.connectRequests.last?.forceScan, isTrue);
        expect(port.refreshDeviceInfoCallCount, 1);
        expect(port.readRecordingStateCallCount, 1);
        expect(port.scanFilesCallCount, initialScanCount + 1);
        expect(
          controller.state.wifiBatch?.state,
          RecordingCardWifiBatchState.completed,
        );
        expect(controller.state.wifiBatch?.completedCount, 2);
        expect(repository.list().rows, hasLength(2));
        expect(
          controller.state.snapshot.deviceState.isOperationallyConnected,
          isTrue,
        );
        expect(controller.hasActiveTransfer, isFalse);
        expect(port.wifiRecoverySettlements, hasLength(1));
        expect(port.wifiRecoverySettlements.single, (
          batchId: controller.state.wifiBatch!.batchId,
          attemptId: controller.state.wifiBatch!.attemptId!,
          safeDeviceFingerprint: 'card-fingerprint-1',
          batchState: RecordingCardWifiBatchState.completed,
        ));
      },
    );

    test(
      'Wi-Fi recovery owns the transfer lock and one private directory scan',
      () async {
        final port = _FakeRecordingCardPort();
        final controller = _controllerFor(port);
        addTearDown(controller.dispose);
        await controller.connect();
        await _awaitAutomaticScan(controller, port);
        final initialScanCount = port.scanFilesCallCount;
        final deferredInfo =
            Completer<RecordingCardResult<RecordingCardRuntimeSnapshot>>();
        port.refreshDeviceInfoCompleter = deferredInfo;
        await _prepareWifiBatchForTest(
          controller,
          port,
          <RecordingCardScannedFile>[_fileWithId(1)],
        );

        final running = controller.startPreparedWifiBatch();
        await _waitFor(() => port.refreshDeviceInfoCallCount == 1);
        expect(controller.hasActiveTransfer, isTrue);

        await controller.scanFiles();
        await controller.startRecording();
        expect(port.scanFilesCallCount, initialScanCount);
        expect(port.startRecordingCallCount, 0);

        port.refreshDeviceInfoCompleter = null;
        deferredInfo.complete(
          RecordingCardResult<RecordingCardRuntimeSnapshot>.success(
            port.runtimeSnapshot,
          ),
        );
        await running;

        expect(port.scanFilesCallCount, initialScanCount + 1);
        expect(controller.hasActiveTransfer, isFalse);
        expect(
          controller.state.wifiBatch?.state,
          RecordingCardWifiBatchState.completed,
        );
      },
    );

    test(
      'completed batch cannot be dismissed from a running listener',
      () async {
        final database = AppDatabase();
        final repository = LocalRecordingRepository(
          database: database,
          fileStorage: const _RecordingCardFileStorage(),
          accountScope: 'wifi-dismiss-listener-account',
        );
        final port = _FakeRecordingCardPort();
        final controller = RecordingCardController(
          port: port,
          localRecordingRepository: repository,
          platformPermissionsPort: _FakePlatformPermissionsPort(),
          bindingTokenProvider: _bindingToken,
        );
        addTearDown(controller.dispose);
        var dismissAttempts = 0;
        Future<bool>? dismissDuringRun;
        controller.addListener(() {
          if (controller.state.wifiBatch?.state ==
                  RecordingCardWifiBatchState.completed &&
              dismissDuringRun == null) {
            dismissAttempts += 1;
            dismissDuringRun = controller.dismissWifiBatch();
          }
        });
        await controller.connect();
        await _prepareWifiBatchForTest(
          controller,
          port,
          <RecordingCardScannedFile>[_fileWithId(1)],
        );

        await controller.startPreparedWifiBatch();

        expect(dismissAttempts, greaterThan(0));
        expect(await dismissDuringRun, isFalse);
        expect(
          controller.state.wifiBatch?.state,
          RecordingCardWifiBatchState.completed,
        );
        expect(repository.recordingCardWifiBatchItems(), isNotEmpty);
        expect(await controller.dismissWifiBatch(), isTrue);
        expect(controller.state.wifiBatch, isNull);
        expect(repository.recordingCardWifiBatchItems(), isEmpty);
      },
    );

    test(
      'completed Wi-Fi files stay synced when session close cleanup fails',
      () async {
        final database = AppDatabase();
        final repository = LocalRecordingRepository(
          database: database,
          fileStorage: const _RecordingCardFileStorage(),
          accountScope: 'wifi-close-account',
        );
        final ledger = RecordingCardSyncLedgerStore(
          database: database,
          accountScope: 'wifi-close-account',
        );
        final port = _FakeRecordingCardPort(serialNumber: 'CARD-CLOSE-001')
          ..failNextWifiClose = true;
        final controller = RecordingCardController(
          port: port,
          localRecordingRepository: repository,
          platformPermissionsPort: _FakePlatformPermissionsPort(),
          syncLedgerPersistence: ledger,
          bindingTokenProvider: _bindingToken,
        );
        addTearDown(controller.dispose);
        await controller.connect();
        await _awaitAutomaticScan(controller, port);

        final prepared = await _prepareWifiBatchForTest(
          controller,
          port,
          <RecordingCardScannedFile>[_fileWithId(1)],
        );
        expect(prepared.ok, isTrue, reason: prepared.error?.code);
        await controller.startPreparedWifiBatch();

        final digest = RecordingCardFileIdentity.digestSerialNumber(
          'CARD-CLOSE-001',
        )!;
        final entry = ledger.loadFileLedger(digest).single;
        expect(
          controller.state.wifiBatch?.state,
          RecordingCardWifiBatchState.completed,
        );
        expect(controller.state.wifiBatch?.failureCode, isNull);
        expect(controller.state.lastErrorCode, isNull);
        expect(entry.localState, RecordingCardFileLocalState.synced);
        expect(entry.localRecordingId, isNotEmpty);
        expect(port.wifiSessionDownloadedKeys, <String>['card-file-1']);
        expect(
          ControllerRecordingCardAutoSyncActions(controller).hasActiveTransfer,
          isFalse,
        );
      },
    );

    test(
      'typed close and cancel failures retain teardown without an active transport lease',
      () async {
        final database = AppDatabase();
        final repository = LocalRecordingRepository(
          database: database,
          fileStorage: const _RecordingCardFileStorage(),
          accountScope: 'wifi-teardown-account',
        );
        final ledger = RecordingCardSyncLedgerStore(
          database: database,
          accountScope: 'wifi-teardown-account',
        );
        final port = _FakeRecordingCardPort(serialNumber: 'CARD-TEARDOWN-001')
          ..failNextWifiClose = true
          ..failNextWifiCancel = true
          ..failNextDisconnect = true;
        final controller = RecordingCardController(
          port: port,
          localRecordingRepository: repository,
          platformPermissionsPort: _FakePlatformPermissionsPort(),
          syncLedgerPersistence: ledger,
          bindingTokenProvider: _bindingToken,
        );
        addTearDown(controller.dispose);
        await controller.connect();
        await _awaitAutomaticScan(controller, port);
        final queued = await _queueWifiBatchForTest(
          controller,
          port,
          <RecordingCardScannedFile>[_fileWithId(1)],
        );
        expect(queued.ok, isTrue);

        await controller.startQueuedWifiBatch();

        final paused = controller.state.wifiBatch!;
        final pendingAttemptId = paused.attemptId;
        expect(pendingAttemptId, isNotNull);
        expect(paused.state, RecordingCardWifiBatchState.paused);
        expect(paused.operationPhase, RecordingCardWifiOperationPhase.stopping);
        expect(paused.isTerminal, isFalse);
        expect(paused.items.single.isCompleted, isTrue);
        expect(controller.hasActiveTransfer, isTrue);
        expect(
          ControllerRecordingCardAutoSyncActions(controller).hasActiveTransfer,
          isTrue,
        );
        expect(controller.state.operation.isActive, isFalse);
        expect(
          ControllerRecordingCardAutoSyncActions(
            controller,
          ).activeTransferTransport,
          isNull,
        );
        expect(port.wifiSessionCloseCallCount, 1);
        expect(port.cancelCallCount, 1);
        expect(
          repository.recordingCardWifiBatchItems().single['batch_stage'],
          RecordingCardWifiBatchState.paused.name,
        );
        expect(await controller.dismissWifiBatch(), isFalse);

        final prepareCallsBeforeRetry = port.wifiSessionPrepareCallCount;
        port
          ..failNextWifiClose = true
          ..failNextWifiCancel = true
          ..failNextDisconnect = true;
        final stillPending = await controller.resumeWifiBatch();

        expect(stillPending.ok, isFalse);
        expect(port.wifiSessionCloseCallCount, 2);
        expect(port.cancelCallCount, 2);
        expect(port.disconnectCallCount, 2);
        expect(controller.state.wifiBatch?.attemptId, pendingAttemptId);
        expect(
          controller.state.wifiBatch?.state,
          RecordingCardWifiBatchState.paused,
        );
        expect(
          controller.state.wifiBatch?.operationPhase,
          RecordingCardWifiOperationPhase.stopping,
        );
        expect(controller.hasActiveTransfer, isTrue);
        expect(controller.state.operation.isActive, isFalse);
        expect(
          ControllerRecordingCardAutoSyncActions(
            controller,
          ).activeTransferTransport,
          isNull,
        );
        expect(port.wifiSessionPrepareCallCount, prepareCallsBeforeRetry);

        final recovered = await controller.resumeWifiBatch();

        expect(recovered.ok, isTrue, reason: recovered.error?.code);
        expect(port.wifiSessionCloseCallCount, 3);
        expect(controller.state.wifiBatch?.attemptId, isNot(pendingAttemptId));
        expect(
          controller.state.wifiBatch?.state,
          RecordingCardWifiBatchState.completed,
        );
        expect(controller.hasActiveTransfer, isFalse);
        expect(controller.state.operation.isActive, isFalse);
        expect(
          ControllerRecordingCardAutoSyncActions(controller).hasActiveTransfer,
          isFalse,
        );
        final digest = RecordingCardFileIdentity.digestSerialNumber(
          'CARD-TEARDOWN-001',
        )!;
        expect(
          ledger.loadFileLedger(digest).single.localState,
          RecordingCardFileLocalState.synced,
        );
      },
    );

    test(
      'settled teardown releases its lease when attempt persistence fails',
      () async {
        const accountScope = 'wifi-teardown-persist-failure-account';
        final database = AppDatabase();
        final repository = LocalRecordingRepository(
          database: database,
          fileStorage: const _RecordingCardFileStorage(),
          accountScope: accountScope,
        );
        final ledger = _DeferredFlushRecordingCardLedger(
          RecordingCardSyncLedgerStore(
            database: database,
            accountScope: accountScope,
          ),
        );
        final port =
            _FakeRecordingCardPort(serialNumber: 'CARD-TEARDOWN-PERSIST-001')
              ..failNextWifiClose = true
              ..failNextWifiCancel = true
              ..failNextDisconnect = true;
        final controller = RecordingCardController(
          port: port,
          localRecordingRepository: repository,
          platformPermissionsPort: _FakePlatformPermissionsPort(),
          syncLedgerPersistence: ledger,
          bindingTokenProvider: _bindingToken,
        );
        addTearDown(controller.dispose);
        await controller.connect();
        await _awaitAutomaticScan(controller, port);
        final queued = await _queueWifiBatchForTest(
          controller,
          port,
          <RecordingCardScannedFile>[_fileWithId(1)],
        );
        expect(queued.ok, isTrue);
        await controller.startQueuedWifiBatch();
        expect(
          controller.state.wifiBatch?.operationPhase,
          RecordingCardWifiOperationPhase.stopping,
        );

        final failedFlush = ledger.deferNextFlush(
          failure: StateError('forced rotated attempt persistence failure'),
        );
        addTearDown(failedFlush.release);
        final failingRetry = controller.resumeWifiBatch();
        await failedFlush.started.future;
        failedFlush.release();
        final failed = await failingRetry;

        expect(failed.ok, isFalse);
        expect(failed.error?.code, 'RECORDING_CARD_WIFI_BATCH_PERSIST_FAILED');
        expect(controller.state.hasRunningTransfer, isFalse);
        expect(controller.state.operation.isActive, isFalse);
        expect(
          controller.state.wifiBatch?.operationPhase,
          RecordingCardWifiOperationPhase.idle,
        );
        expect(
          ControllerRecordingCardAutoSyncActions(
            controller,
          ).activeTransferTransport,
          isNull,
        );

        final retried = await controller.resumeWifiBatch();

        expect(retried.ok, isTrue, reason: retried.error?.code);
        expect(
          controller.state.wifiBatch?.state,
          RecordingCardWifiBatchState.completed,
        );
        expect(controller.state.operation.isActive, isFalse);
      },
    );

    test(
      'native cancellation and retirement timeout remain stopped until retry',
      () async {
        final database = AppDatabase();
        final repository = LocalRecordingRepository(
          database: database,
          fileStorage: const _RecordingCardFileStorage(),
          accountScope: 'wifi-cancel-timeout-account',
        );
        final ledger = RecordingCardSyncLedgerStore(
          database: database,
          accountScope: 'wifi-cancel-timeout-account',
        );
        final port = _FakeRecordingCardPort(
          serialNumber: 'CARD-CANCEL-TIMEOUT-001',
        );
        final controller = RecordingCardController(
          port: port,
          localRecordingRepository: repository,
          platformPermissionsPort: _FakePlatformPermissionsPort(),
          syncLedgerPersistence: ledger,
          bindingTokenProvider: _bindingToken,
          wifiTeardownTimeout: const Duration(milliseconds: 10),
        );
        addTearDown(controller.dispose);
        await controller.connect();
        await _awaitAutomaticScan(controller, port);
        await _prepareWifiBatchForTest(
          controller,
          port,
          <RecordingCardScannedFile>[_fileWithId(1)],
        );
        port.wifiCancelCompleter = Completer<RecordingCardResult<bool>>();
        port.disconnectCompleter =
            Completer<RecordingCardResult<RecordingCardDeviceState>>();

        await controller.cancelWifiBatch();

        expect(
          controller.state.wifiBatch?.state,
          RecordingCardWifiBatchState.paused,
        );
        expect(
          controller.state.wifiBatch?.failureCode,
          'RECORDING_CARD_WIFI_CANCEL_TIMEOUT',
        );
        expect(
          controller.state.wifiBatch?.operationPhase,
          RecordingCardWifiOperationPhase.stopping,
        );
        expect(
          controller.state.lastErrorCode,
          'RECORDING_CARD_WIFI_CANCEL_TIMEOUT',
        );
        expect(controller.hasActiveTransfer, isTrue);
        expect(controller.state.operation.isActive, isFalse);
        expect(
          ControllerRecordingCardAutoSyncActions(
            controller,
          ).activeTransferTransport,
          isNull,
        );
        expect(await controller.dismissWifiBatch(), isFalse);

        port.wifiCancelCompleter = null;
        port.disconnectCompleter = null;
        final cancelGate = Completer<RecordingCardResult<bool>>();
        port.wifiCancelCompleter = cancelGate;
        final cancelCallsBeforeRetry = port.cancelCallCount;
        final firstCancel = controller.cancelWifiBatch();
        final secondCancel = controller.cancelWifiBatch();
        expect(identical(firstCancel, secondCancel), isTrue);
        await _waitFor(
          () => port.cancelCallCount == cancelCallsBeforeRetry + 1,
        );
        cancelGate.complete(RecordingCardResult<bool>.success(true));
        await firstCancel;
        expect(
          controller.state.wifiBatch?.state,
          RecordingCardWifiBatchState.cancelled,
          reason: controller.state.wifiBatch?.failureCode,
        );
        expect((await controller.resumeWifiBatch()).ok, isFalse);
      },
    );

    test(
      'user pause keeps recovery ownership while durable settlement waits',
      () async {
        const accountScope = 'wifi-pause-recovery-ownership-account';
        final database = AppDatabase();
        final repository = LocalRecordingRepository(
          database: database,
          fileStorage: const _RecordingCardFileStorage(),
          accountScope: accountScope,
        );
        final ledger = _DeferredFlushRecordingCardLedger(
          RecordingCardSyncLedgerStore(
            database: database,
            accountScope: accountScope,
          ),
        );
        final port = _FakeRecordingCardPort(
          serialNumber: 'CARD-PAUSE-RECOVERY-001',
        );
        var bindingTokenUnavailable = false;
        final controller = RecordingCardController(
          port: port,
          localRecordingRepository: repository,
          platformPermissionsPort: _FakePlatformPermissionsPort(),
          syncLedgerPersistence: ledger,
          bindingTokenProvider: () {
            if (bindingTokenUnavailable) {
              return Future<String>.error(
                StateError('binding token temporarily unavailable'),
              );
            }
            return _bindingToken();
          },
        );
        addTearDown(controller.dispose);
        await controller.connect();
        await _awaitAutomaticScan(controller, port);
        final queued = await _queueWifiBatchForTest(
          controller,
          port,
          <RecordingCardScannedFile>[_fileWithId(1)],
        );
        expect(queued.ok, isTrue);
        bindingTokenUnavailable = true;
        final connectCallsBeforePause = port.connectRequests.length;
        final scanCallsBeforePause = port.scanFilesCallCount;
        final terminalPhases = <RecordingCardWifiOperationPhase>[];
        void observeTerminalPhase() {
          final batch = controller.state.wifiBatch;
          if (batch != null &&
              (batch.state == RecordingCardWifiBatchState.paused ||
                  batch.state == RecordingCardWifiBatchState.failed ||
                  batch.state == RecordingCardWifiBatchState.cancelled)) {
            terminalPhases.add(batch.operationPhase);
          }
        }

        controller.addListener(observeTerminalPhase);
        addTearDown(() => controller.removeListener(observeTerminalPhase));
        final flush = ledger.deferNextFlush();
        addTearDown(flush.release);

        final pausing = controller.pauseWifiBatch();
        await flush.started.future;
        await Future<void>.delayed(Duration.zero);

        expect(
          controller.state.wifiBatch?.state,
          RecordingCardWifiBatchState.paused,
        );
        expect(
          controller.state.wifiBatch?.operationPhase,
          RecordingCardWifiOperationPhase.recovering,
        );
        expect(controller.hasActiveTransfer, isTrue);
        expect(port.connectRequests, hasLength(connectCallsBeforePause));
        expect(terminalPhases, isNotEmpty);
        expect(
          terminalPhases,
          everyElement(RecordingCardWifiOperationPhase.recovering),
        );

        final recoveryDirectory =
            Completer<RecordingCardResult<List<RecordingCardScannedFile>>>();
        port.scanFilesCompleter = recoveryDirectory;
        flush.release();
        await _waitFor(
          () => port.scanFilesCallCount == scanCallsBeforePause + 1,
        );
        final actions = ControllerRecordingCardAutoSyncActions(controller);
        expect(
          controller.state.operation.kind,
          RecordingCardOperationKind.bluetoothTransfer,
        );
        expect(
          actions.activeTransferTransport,
          RecordingCardBackgroundTransferTransport.bluetooth,
        );
        recoveryDirectory.complete(
          RecordingCardResult<List<RecordingCardScannedFile>>.success(
            <RecordingCardScannedFile>[port.scannedFile],
          ),
        );
        await pausing;

        expect(port.connectRequests, hasLength(connectCallsBeforePause));
        expect(
          controller.state.wifiBatch?.state,
          RecordingCardWifiBatchState.paused,
        );
        expect(
          controller.state.wifiBatch?.operationPhase,
          RecordingCardWifiOperationPhase.idle,
        );
      },
    );

    test(
      'cancel upgrades an in-flight pause without repeating native teardown',
      () async {
        final port = _FakeRecordingCardPort();
        final controller = _controllerFor(port);
        addTearDown(controller.dispose);
        await controller.connect();
        await _awaitAutomaticScan(controller, port);
        await _prepareWifiBatchForTest(
          controller,
          port,
          <RecordingCardScannedFile>[port.scannedFile],
        );
        final nativeCancel = Completer<RecordingCardResult<bool>>();
        port.wifiCancelCompleter = nativeCancel;
        final connectCallsBeforePause = port.connectCallCount;

        final pausing = controller.pauseWifiBatch();
        await _waitFor(() => port.cancelCallCount == 1);
        final firstCancel = controller.cancelWifiBatch();
        final secondCancel = controller.cancelWifiBatch();
        expect(identical(firstCancel, secondCancel), isTrue);
        nativeCancel.complete(RecordingCardResult<bool>.success(true));
        await Future.wait<void>(<Future<void>>[pausing, firstCancel]);

        expect(port.cancelCallCount, 1);
        expect(
          controller.state.wifiBatch?.state,
          RecordingCardWifiBatchState.cancelled,
        );
        expect(port.connectCallCount, connectCallsBeforePause);
      },
    );

    test(
      'BLE recovery rebases when device info publishes serial before returning',
      () async {
        final port = _FakeRecordingCardPort();
        final controller = _controllerFor(port);
        addTearDown(controller.dispose);
        await controller.connect();
        await _awaitAutomaticScan(controller, port);
        final prepared = await _prepareWifiBatchForTest(
          controller,
          port,
          <RecordingCardScannedFile>[_fileWithId(1)],
        );
        expect(prepared.ok, isTrue, reason: prepared.error?.code);
        final refreshedSnapshot = port.runtimeSnapshot.copyWith(
          deviceState: port.runtimeSnapshot.deviceState.copyWith(
            serialNumber: 'CARD-REFRESH-REBASING-001',
          ),
        );
        port
          ..emitRefreshDeviceInfoResult = true
          ..refreshDeviceInfoCompleter =
              (Completer<RecordingCardResult<RecordingCardRuntimeSnapshot>>()
                ..complete(
                  RecordingCardResult<RecordingCardRuntimeSnapshot>.success(
                    refreshedSnapshot,
                  ),
                ));

        await controller.startPreparedWifiBatch();

        expect(
          controller.state.wifiBatch?.state,
          RecordingCardWifiBatchState.completed,
        );
        expect(controller.state.lastErrorCode, isNull);
        expect(
          controller.state.operation.phase,
          RecordingCardOperationPhase.succeeded,
        );
        expect(controller.hasActiveDeviceOperation, isFalse);
      },
    );

    test('pending Wi-Fi cancellation rejects repeated start intent', () async {
      final port = _FakeRecordingCardPort();
      final controller = _controllerFor(port);
      addTearDown(controller.dispose);
      await controller.connect();
      await _awaitAutomaticScan(controller, port);
      await _prepareWifiBatchForTest(
        controller,
        port,
        <RecordingCardScannedFile>[port.scannedFile],
      );
      final nativeCancel = Completer<RecordingCardResult<bool>>();
      port.wifiCancelCompleter = nativeCancel;

      final cancelling = controller.cancelWifiBatch();
      await _waitFor(() => port.cancelCallCount == 1);
      await controller.startPreparedWifiBatch();

      expect(port.wifiSessionOpenCallCount, 0);
      expect(
        controller.state.wifiBatch?.state,
        RecordingCardWifiBatchState.awaitingHotspot,
      );
      nativeCancel.complete(RecordingCardResult<bool>.success(true));
      await cancelling;
      expect(
        controller.state.wifiBatch?.state,
        RecordingCardWifiBatchState.cancelled,
      );
    });

    test(
      'pause settles when native cancellation loses the download callback',
      () async {
        final port = _FakeRecordingCardPort(
          serialNumber: 'CARD-PAUSE-LOST-CALLBACK-001',
        )..cancelLeavesDownloadFuturePending = true;
        final controller = RecordingCardController(
          port: port,
          localRecordingRepository: _repository(),
          platformPermissionsPort: _FakePlatformPermissionsPort(),
          bindingTokenProvider: _bindingToken,
        );
        addTearDown(controller.dispose);
        await controller.connect();
        await _awaitAutomaticScan(controller, port);
        final file = _fileWithId(1);
        port.wifiSessionDownloadCompletersByDeviceFileId[file.deviceFileId] =
            Completer<RecordingCardResult<RecordingCardDownloadedFile>>();
        await _prepareWifiBatchForTest(
          controller,
          port,
          <RecordingCardScannedFile>[file],
        );
        final running = controller.startPreparedWifiBatch();
        await _waitFor(
          () =>
              controller.state.wifiBatch?.state ==
              RecordingCardWifiBatchState.transferring,
        );

        await controller.pauseWifiBatch().timeout(const Duration(seconds: 1));
        await running.timeout(const Duration(seconds: 1));

        expect(
          controller.state.wifiBatch?.state,
          RecordingCardWifiBatchState.paused,
        );
        expect(
          controller.state.wifiBatch?.items.single.state,
          RecordingCardWifiBatchItemState.queued,
        );
        expect(controller.state.lastErrorCode, isNull);
        expect(controller.hasActiveTransfer, isTrue);
        expect(port.cancelCallCount, greaterThanOrEqualTo(1));
      },
    );

    test(
      'restore preserves a legacy completed batch backed by synced ledger',
      () async {
        final database = AppDatabase();
        final repository = LocalRecordingRepository(
          database: database,
          fileStorage: const _RecordingCardFileStorage(),
          accountScope: 'wifi-restore-account',
        );
        final firstPort = _FakeRecordingCardPort(
          serialNumber: 'CARD-RESTORE-001',
        );
        final firstController = RecordingCardController(
          port: firstPort,
          localRecordingRepository: repository,
          platformPermissionsPort: _FakePlatformPermissionsPort(),
          bindingTokenProvider: _bindingToken,
        );
        await firstController.connect();
        await _awaitAutomaticScan(firstController, firstPort);
        final source = _fileWithId(1);
        final prepared = await _prepareWifiBatchForTest(
          firstController,
          firstPort,
          <RecordingCardScannedFile>[source],
        );
        expect(prepared.ok, isTrue, reason: prepared.error?.code);
        await firstController.startPreparedWifiBatch();
        expect(
          firstController.state.wifiBatch?.state,
          RecordingCardWifiBatchState.completed,
        );
        firstController.dispose();

        final legacyRow = repository.recordingCardWifiBatchItems().single;
        repository.upsertRecordingCardWifiBatchItem(
          transferId: legacyRow['transfer_id']! as String,
          batchId: legacyRow['batch_id']! as String,
          deviceFingerprint: legacyRow['device_fingerprint']! as String,
          deviceIdentity: legacyRow['device_identity']! as String,
          deviceFileId: legacyRow['device_file_id']! as String,
          deviceFilename: legacyRow['device_filename']! as String,
          localFileKey: legacyRow['local_file_key']! as String,
          itemOrder: legacyRow['item_order']! as int,
          expectedSizeBytes: legacyRow['expected_size_bytes']! as int,
          attemptCount: legacyRow['attempt_count']! as int,
          batchStage: legacyRow['batch_stage']! as String,
          stage: legacyRow['stage']! as String,
          idempotencyKey: legacyRow['idempotency_key']! as String,
          createdAt: DateTime.parse(legacyRow['created_at']! as String),
          updatedAt: DateTime.parse(legacyRow['updated_at']! as String),
          errorCode: legacyRow['error_code'] as String?,
          localRecordingId: legacyRow['local_recording_id'] as String?,
          fileFormat: legacyRow['file_format'] as String?,
          mimeType: legacyRow['mime_type'] as String?,
          durationSeconds: legacyRow['duration_seconds'] as int?,
          recordedAt: legacyRow['recorded_at'] == null
              ? null
              : DateTime.parse(legacyRow['recorded_at']! as String),
          contentHash: legacyRow['content_hash'] as String?,
        );
        final digestlessRow = repository.recordingCardWifiBatchItems().single;
        final encodedScope = base64Url
            .encode(utf8.encode('wifi-restore-account'))
            .replaceAll('=', '');
        final encodedId = base64Url
            .encode(utf8.encode(digestlessRow['transfer_id']! as String))
            .replaceAll('=', '');
        database.upsertRecord(
          LocalTableName.localTransferRecords,
          'recording:$encodedScope:local_transfer_records:$encodedId',
          <String, Object?>{...digestlessRow, 'card_sn_digest': ' '},
        );
        final rewritten = repository.recordingCardWifiBatchItems().single;
        expect(rewritten['card_sn_digest'], ' ');
        expect(rewritten['ledger_source_signature'], isNull);

        final ledger = RecordingCardSyncLedgerStore(
          database: database,
          accountScope: 'wifi-restore-account',
        );
        final digest = RecordingCardFileIdentity.digestSerialNumber(
          'CARD-RESTORE-001',
        )!;
        final syncing = ledger.beginManualSyncForFile(
          cardSnDigest: digest,
          file: source,
          at: DateTime.utc(2026, 9, 5, 8),
        );
        final localRecordingId = legacyRow['local_recording_id']! as String;
        final localItem = repository.findById(localRecordingId)!;
        ledger.completeManualSync(
          cardSnDigest: digest,
          sourceSignature: syncing.sourceSignature,
          localRecordingId: localRecordingId,
          contentHash: localItem.contentHash,
          at: DateTime.utc(2026, 9, 5, 8, 1),
        );
        expect(
          ledger.loadFileLedger(digest).single.localState,
          RecordingCardFileLocalState.synced,
        );

        final restoredPort = _FakeRecordingCardPort(
          serialNumber: 'CARD-RESTORE-001',
          scannedFile: source,
        );
        final restoredController = RecordingCardController(
          port: restoredPort,
          localRecordingRepository: repository,
          platformPermissionsPort: _FakePlatformPermissionsPort(),
          syncLedgerPersistence: ledger,
          bindingTokenProvider: _bindingToken,
        );
        addTearDown(restoredController.dispose);
        await restoredController.restoreWifiBatch();

        final repaired = ledger.loadFileLedger(digest).single;
        expect(
          restoredController.state.wifiBatch?.state,
          RecordingCardWifiBatchState.completed,
          reason: restoredController.state.lastErrorCode,
        );
        expect(repaired.localState, RecordingCardFileLocalState.synced);
        expect(repaired.localRecordingId, localRecordingId);
        expect(repaired.contentHash, localItem.contentHash);
        expect(restoredController.state.wifiBatch?.completedCount, 1);
        expect(restoredPort.wifiSessionDownloadedKeys, isEmpty);
        expect(
          repository.recordingCardWifiBatchItems().single['card_sn_digest'],
          digest,
        );
      },
    );

    test(
      'restore repairs a syncing ledger but waits for directory projection',
      () async {
        final fixture = await _persistCompletedWifiBatch(
          accountScope: 'wifi-restore-syncing-account',
          serialNumber: 'CARD-RESTORE-SYNCING-001',
        );
        final synced = fixture.ledger.loadFileLedger(fixture.cardDigest).single;
        fixture.ledger.saveFileLedgerEntry(
          synced
              .queue(
                at: DateTime.utc(2026, 9, 5, 9),
                manual: true,
                resetAttemptCount: true,
              )
              .beginSync(DateTime.utc(2026, 9, 5, 9, 1)),
        );
        expect(
          fixture.ledger.loadFileLedger(fixture.cardDigest).single.localState,
          RecordingCardFileLocalState.syncing,
        );
        final restoredPort = _FakeRecordingCardPort(
          serialNumber: fixture.serialNumber,
        );
        final restored = RecordingCardController(
          port: restoredPort,
          localRecordingRepository: fixture.repository,
          platformPermissionsPort: _FakePlatformPermissionsPort(),
          syncLedgerPersistence: fixture.ledger,
          bindingTokenProvider: _bindingToken,
        );
        addTearDown(restored.dispose);

        await restored.restoreWifiBatch();

        expect(
          restored.state.wifiBatch?.state,
          RecordingCardWifiBatchState.reconciling,
        );
        expect(restored.state.wifiBatch?.completedCount, 1);
        expect(
          restored.state.lastErrorCode,
          'RECORDING_CARD_WIFI_LOCAL_PROJECTION_INCOMPLETE',
        );
        expect(restoredPort.wifiSessionDownloadedKeys, isEmpty);
        final repaired = fixture.ledger
            .loadFileLedger(fixture.cardDigest)
            .single;
        expect(repaired.localState, RecordingCardFileLocalState.synced);
        expect(repaired.localRecordingId, fixture.localRecordingId);
      },
    );

    final invalidLocalMutations =
        <(String, RecordingLibraryItem Function(RecordingLibraryItem))>[
          (
            'missing local file',
            (item) =>
                item.copyWith(localFileState: RecordingLocalFileState.missing),
          ),
          (
            'unsafe local URI',
            (item) => item.copyWith(appPrivateUri: '/tmp/outside-app.m4a'),
          ),
        ];
    for (var index = 0; index < invalidLocalMutations.length; index += 1) {
      final mutation = invalidLocalMutations[index];
      test('restore re-queues a completed batch with ${mutation.$1}', () async {
        final fixture = await _persistCompletedWifiBatch(
          accountScope: 'wifi-restore-invalid-$index',
          serialNumber: 'CARD-RESTORE-INVALID-00$index',
        );
        final localItem = fixture.repository.findById(
          fixture.localRecordingId,
        )!;
        RecordingDao(
          fixture.database,
          userScope: fixture.accountScope,
        ).upsertLocalRecording(
          localItem.recordingId,
          mutation.$2(localItem).toRecord(),
        );
        final restoredPort = _FakeRecordingCardPort(
          serialNumber: fixture.serialNumber,
        );
        final restored = RecordingCardController(
          port: restoredPort,
          localRecordingRepository: fixture.repository,
          platformPermissionsPort: _FakePlatformPermissionsPort(),
          syncLedgerPersistence: fixture.ledger,
          bindingTokenProvider: _bindingToken,
        );
        addTearDown(restored.dispose);

        await restored.restoreWifiBatch();

        final batch = restored.state.wifiBatch!;
        expect(batch.state, RecordingCardWifiBatchState.cancelled);
        expect(batch.isTerminal, isTrue);
        expect(
          batch.items.single.state,
          RecordingCardWifiBatchItemState.cancelled,
        );
        expect(batch.failureCode, 'RECORDING_CARD_WIFI_HANDOFF_TO_BLUETOOTH');
        expect(batch.items.single.localRecordingId, isNull);
        expect(batch.items.single.file.localFileId, isNull);
        expect(batch.items.single.file.appPrivateUri, isNull);
        expect(
          fixture.ledger.loadFileLedger(fixture.cardDigest).single.localState,
          RecordingCardFileLocalState.queued,
        );
        expect(
          fixture.ledger
              .loadFileLedger(fixture.cardDigest)
              .single
              .resumeRequested,
          isTrue,
        );
        expect(restoredPort.wifiSessionDownloadedKeys, isEmpty);
        await restored.resumePendingBluetoothTransfers();
      });
    }

    test(
      'restore re-queues completed metadata when the private file disappeared',
      () async {
        var fileExists = true;
        final fixture = await _persistCompletedWifiBatch(
          accountScope: 'wifi-restore-file-missing',
          serialNumber: 'CARD-RESTORE-FILE-MISSING-001',
          fileStorage: _RecordingCardFileStorage(statExists: () => fileExists),
        );
        fileExists = false;
        final restored = RecordingCardController(
          port: _FakeRecordingCardPort(serialNumber: fixture.serialNumber),
          localRecordingRepository: fixture.repository,
          platformPermissionsPort: _FakePlatformPermissionsPort(),
          syncLedgerPersistence: fixture.ledger,
          bindingTokenProvider: _bindingToken,
        );
        addTearDown(restored.dispose);

        await restored.restoreWifiBatch();

        final batch = restored.state.wifiBatch!;
        expect(batch.state, RecordingCardWifiBatchState.cancelled);
        expect(
          batch.items.single.state,
          RecordingCardWifiBatchItemState.cancelled,
        );
        expect(batch.failureCode, 'RECORDING_CARD_WIFI_HANDOFF_TO_BLUETOOTH');
        expect(batch.items.single.localRecordingId, isNull);
        expect(
          fixture.repository.findById(fixture.localRecordingId)?.localFileState,
          RecordingLocalFileState.missing,
        );
        expect(
          fixture.ledger.loadFileLedger(fixture.cardDigest).single.localState,
          RecordingCardFileLocalState.queued,
        );
        await restored.resumePendingBluetoothTransfers();
      },
    );

    test(
      'Wi-Fi hash conflict fails before checkpoint or registration',
      () async {
        const directoryHash =
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
        const downloadedHash =
            'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
        final operations = <String>[];
        final file = _fileWithId(1, contentHash: directoryHash);
        final port = _FakeRecordingCardPort(
          operationLog: operations,
          scannedFile: file,
          downloadedContentHash: downloadedHash,
          wifiSessionFiles: <RecordingCardScannedFile>[_fileWithId(1)],
        );
        final repository = _repository(operationLog: operations);
        final controller = RecordingCardController(
          port: port,
          localRecordingRepository: repository,
          platformPermissionsPort: _FakePlatformPermissionsPort(),
          bindingTokenProvider: _bindingToken,
        );
        addTearDown(controller.dispose);
        await controller.connect();
        await _awaitAutomaticScan(controller, port);

        final prepared = await _prepareWifiBatchForTest(
          controller,
          port,
          <RecordingCardScannedFile>[file],
        );
        expect(prepared.ok, isTrue, reason: prepared.error?.code);
        operations.clear();
        await controller.startPreparedWifiBatch();

        final item = controller.state.wifiBatch!.items.single;
        expect(item.state, RecordingCardWifiBatchItemState.failed);
        expect(item.errorCode, 'RECORDING_CARD_DOWNLOAD_HASH_MISMATCH');
        expect(item.stagedDownload, isNull);
        expect(repository.list().rows, isEmpty);
        expect(operations, isNot(contains('stat')));
        final persisted = repository.recordingCardWifiBatchItems().single;
        expect(persisted.keys, isNot(contains('staged_content_hash')));
      },
    );

    test(
      'verified firmware waits before the next shared-session file',
      () async {
        final port = _FakeRecordingCardPort();
        final controller = _controllerFor(port);
        addTearDown(controller.dispose);
        await controller.connect();
        port.emit(
          port.runtimeSnapshot.copyWith(
            deviceState: port.runtimeSnapshot.deviceState.copyWith(
              firmwareVersion: '1.0.6',
              wifiFirmwareVersion: '1.0.2',
            ),
          ),
        );
        final prepared = await _prepareWifiBatchForTest(
          controller,
          port,
          <RecordingCardScannedFile>[_fileWithId(1), _fileWithId(2)],
        );
        expect(prepared.ok, isTrue, reason: prepared.error?.code);
        final elapsed = Stopwatch()..start();

        await controller.startPreparedWifiBatch();
        elapsed.stop();

        expect(
          elapsed.elapsed,
          greaterThanOrEqualTo(const Duration(milliseconds: 450)),
        );
        expect(port.wifiSessionDownloadedKeys, <String>[
          'card-file-1',
          'card-file-2',
        ]);
        expect(
          controller.state.wifiBatch?.state,
          RecordingCardWifiBatchState.completed,
        );
      },
    );

    test(
      'Wi-Fi batch registers each file before requesting the next',
      () async {
        final operations = <String>[];
        final port = _FakeRecordingCardPort(operationLog: operations)
          ..wifiSessionFailuresByDeviceFileId['card-file-2'] =
              'RECORDING_CARD_WIFI_PROTOCOL_INVALID';
        final repository = _repository(operationLog: operations);
        final controller = RecordingCardController(
          port: port,
          localRecordingRepository: repository,
          platformPermissionsPort: _FakePlatformPermissionsPort(),
          bindingTokenProvider: _bindingToken,
        );
        addTearDown(controller.dispose);
        await controller.connect();
        await _prepareWifiBatchForTest(
          controller,
          port,
          <RecordingCardScannedFile>[
            _fileWithId(1),
            _fileWithId(2),
            _fileWithId(3),
          ],
        );
        operations.clear();

        await controller.startPreparedWifiBatch();

        expect(operations.take(5), <String>[
          'open',
          'download:card-file-1',
          'stat',
          'download:card-file-2',
          'close',
        ]);
        expect(repository.list().rows, hasLength(1));
        expect(
          controller.state.wifiBatch?.state,
          RecordingCardWifiBatchState.paused,
        );
        expect(
          controller.state.wifiBatch?.items[0].state,
          RecordingCardWifiBatchItemState.completed,
        );
        expect(controller.state.wifiBatch?.items[0].stagedDownload, isNull);
        expect(
          controller.state.wifiBatch?.items[1].state,
          RecordingCardWifiBatchItemState.failed,
        );
        expect(
          controller.state.wifiBatch?.items[2].state,
          RecordingCardWifiBatchItemState.queued,
        );
      },
    );

    test(
      'incomplete Wi-Fi file ends the batch and a fresh selection starts cleanly',
      () async {
        final operations = <String>[];
        final port = _FakeRecordingCardPort(operationLog: operations)
          ..wifiSessionFailuresByDeviceFileId['card-file-4'] =
              'RECORDING_CARD_WIFI_DOWNLOAD_INCOMPLETE';
        final repository = _repository(operationLog: operations);
        final controller = RecordingCardController(
          port: port,
          localRecordingRepository: repository,
          platformPermissionsPort: _FakePlatformPermissionsPort(),
          bindingTokenProvider: _bindingToken,
        );
        addTearDown(controller.dispose);
        await controller.connect();
        await _prepareWifiBatchForTest(
          controller,
          port,
          <RecordingCardScannedFile>[
            for (var index = 1; index <= 6; index += 1) _fileWithId(index),
          ],
        );
        final failedBatchId = controller.state.wifiBatch!.batchId;

        await controller.startPreparedWifiBatch();

        final failed = controller.state.wifiBatch!;
        expect(failed.batchId, failedBatchId);
        expect(failed.state, RecordingCardWifiBatchState.failed);
        expect(failed.isTerminal, isTrue);
        expect(controller.state.hasActiveTransfer, isFalse);
        expect(port.wifiSessionDownloadedKeys, <String>[
          'card-file-1',
          'card-file-2',
          'card-file-3',
          'card-file-4',
        ]);
        expect(
          failed.items.map((item) => item.state),
          <RecordingCardWifiBatchItemState>[
            RecordingCardWifiBatchItemState.completed,
            RecordingCardWifiBatchItemState.completed,
            RecordingCardWifiBatchItemState.completed,
            RecordingCardWifiBatchItemState.failed,
            RecordingCardWifiBatchItemState.failed,
            RecordingCardWifiBatchItemState.failed,
          ],
        );
        expect(
          failed.items.every((item) => item.stagedDownload == null),
          isTrue,
        );
        expect(repository.list().rows, hasLength(3));
        expect(
          controller.state.lastErrorCode,
          'RECORDING_CARD_WIFI_DOWNLOAD_INCOMPLETE',
        );
        expect(port.connectCallCount, 2);
        expect(port.connectRequests.last?.forceScan, isTrue);
        expect(
          controller.state.snapshot.deviceState.isOperationallyConnected,
          isTrue,
        );

        port.wifiSessionFailuresByDeviceFileId.remove('card-file-4');
        final prepared = await controller.prepareWifiBatch(
          <RecordingCardScannedFile>[_fileWithId(5), _fileWithId(6)],
        );

        expect(prepared.ok, isTrue, reason: prepared.error?.code);
        expect(controller.state.wifiBatch?.batchId, isNot(failedBatchId));
        expect(
          controller.state.wifiBatch?.state,
          RecordingCardWifiBatchState.awaitingHotspot,
        );
        expect(port.wifiSessionPrepareCallCount, 2);
      },
    );

    test(
      'post-close staged registration retry stays local without reopening transports',
      () async {
        var failRegistration = true;
        final storage = _RecordingCardFileStorage(
          statFailure: () => failRegistration,
        );
        final repository = LocalRecordingRepository(
          database: AppDatabase(),
          fileStorage: storage,
        );
        final port = _FakeRecordingCardPort();
        final controller = RecordingCardController(
          port: port,
          localRecordingRepository: repository,
          platformPermissionsPort: _FakePlatformPermissionsPort(),
          bindingTokenProvider: _bindingToken,
        );
        addTearDown(controller.dispose);
        await controller.connect();
        await _prepareWifiBatchForTest(
          controller,
          port,
          <RecordingCardScannedFile>[_fileWithId(1)],
        );
        await controller.startPreparedWifiBatch();

        expect(
          controller.state.wifiBatch?.state,
          RecordingCardWifiBatchState.paused,
        );
        expect(
          controller.state.wifiBatch?.items.single.stagedDownload,
          isNotNull,
        );
        final callsBeforeRetry = (
          connect: port.connectCallCount,
          prepare: port.wifiSessionPrepareCallCount,
          open: port.wifiSessionOpenCallCount,
          downloads: port.wifiSessionDownloadedKeys.length,
        );

        failRegistration = false;
        final resumed = await controller.resumeWifiBatch();

        expect(resumed.ok, isTrue, reason: resumed.error?.code);
        expect(port.connectCallCount, callsBeforeRetry.connect);
        expect(
          (
            prepare: port.wifiSessionPrepareCallCount,
            open: port.wifiSessionOpenCallCount,
            downloads: port.wifiSessionDownloadedKeys.length,
          ),
          (
            prepare: callsBeforeRetry.prepare,
            open: callsBeforeRetry.open,
            downloads: callsBeforeRetry.downloads,
          ),
        );
        expect(
          controller.state.wifiBatch?.state,
          RecordingCardWifiBatchState.completed,
        );
        expect(controller.state.wifiBatch?.items.single.stagedDownload, isNull);
        expect(repository.list().rows, hasLength(1));
      },
    );

    test('paused batch blocks replacement Wi-Fi and BLE downloads', () async {
      final port = _FakeRecordingCardPort()
        ..wifiSessionFailuresByDeviceFileId['card-file-1'] =
            'RECORDING_CARD_WIFI_PROTOCOL_INVALID';
      final controller = _controllerFor(port);
      addTearDown(controller.dispose);
      await controller.connect();
      await _prepareWifiBatchForTest(
        controller,
        port,
        <RecordingCardScannedFile>[_fileWithId(1)],
      );
      await controller.startPreparedWifiBatch();
      final paused = controller.state.wifiBatch!;
      final prepareCalls = port.wifiSessionPrepareCallCount;
      final downloads = List<String>.of(port.wifiSessionDownloadedKeys);

      final replacement = await controller.prepareWifiBatch(
        <RecordingCardScannedFile>[_fileWithId(2)],
      );
      await controller.downloadFile(_fileWithId(2));

      expect(replacement.ok, isFalse);
      expect(replacement.error?.code, recordingCardOperationBusyCode);
      expect(port.wifiSessionPrepareCallCount, prepareCalls);
      expect(port.wifiSessionDownloadedKeys, downloads);
      expect(port.bleDownloadCallCount, 0);
      expect(
        controller.state.lastErrorCode,
        'RECORDING_CARD_WIFI_PROTOCOL_INVALID',
      );
      expect(controller.operationBlockCode, recordingCardOperationBusyCode);
      expect(controller.state.wifiBatch?.batchId, paused.batchId);
      expect(
        controller.state.wifiBatch?.state,
        RecordingCardWifiBatchState.paused,
      );
      expect(
        controller.state.wifiBatch?.items.map((item) => item.file.deviceFileId),
        <String>['card-file-1'],
      );
    });

    test(
      'cancel keeps a persistently unregistrable staged file paused and non-dismissible',
      () async {
        final repository = LocalRecordingRepository(
          database: AppDatabase(),
          fileStorage: _RecordingCardFileStorage(statFailure: () => true),
        );
        final port = _FakeRecordingCardPort();
        final controller = RecordingCardController(
          port: port,
          localRecordingRepository: repository,
          platformPermissionsPort: _FakePlatformPermissionsPort(),
          bindingTokenProvider: _bindingToken,
        );
        addTearDown(controller.dispose);
        await controller.connect();
        await _prepareWifiBatchForTest(
          controller,
          port,
          <RecordingCardScannedFile>[_fileWithId(1)],
        );
        await controller.startPreparedWifiBatch();
        final batchId = controller.state.wifiBatch!.batchId;

        await controller.cancelWifiBatch();

        final paused = controller.state.wifiBatch!;
        expect(paused.batchId, batchId);
        expect(paused.state, RecordingCardWifiBatchState.paused);
        expect(paused.isTerminal, isFalse);
        expect(
          paused.items.single.state,
          RecordingCardWifiBatchItemState.failed,
        );
        expect(paused.items.single.stagedDownload, isNotNull);
        final checkpoint = repository.recordingCardWifiBatchItems().single;
        expect(
          checkpoint['batch_stage'],
          RecordingCardWifiBatchState.paused.name,
        );
        expect(
          checkpoint['staged_native_file_id'],
          matches(RegExp(r'^card-[a-f0-9]{32}$')),
        );
        expect(checkpoint['staged_size_bytes'], 4096);

        expect(await controller.dismissWifiBatch(), isFalse);

        expect(controller.state.wifiBatch?.batchId, batchId);
        expect(repository.recordingCardWifiBatchItems(), hasLength(1));
      },
    );

    test(
      'registration failure preserves staged progress and skips the tail',
      () async {
        final repository = LocalRecordingRepository(
          database: AppDatabase(),
          fileStorage: _RecordingCardFileStorage(statFailure: () => true),
        );
        final port = _FakeRecordingCardPort(downloadedSizeBytes: 6144);
        final controller = RecordingCardController(
          port: port,
          localRecordingRepository: repository,
          platformPermissionsPort: _FakePlatformPermissionsPort(),
          bindingTokenProvider: _bindingToken,
        );
        addTearDown(controller.dispose);
        await controller.connect();
        await _prepareWifiBatchForTest(
          controller,
          port,
          <RecordingCardScannedFile>[_file(sizeBytes: 4096), _fileWithId(2)],
        );
        await controller.startPreparedWifiBatch();
        final afterTransfer = controller.state.wifiBatch!;

        expect(afterTransfer.state, RecordingCardWifiBatchState.paused);
        expect(afterTransfer.items.first.expectedSizeBytes, 4096);
        expect(afterTransfer.items.first.stagedDownload?.sizeBytes, 6144);
        expect(
          afterTransfer.items.last.state,
          RecordingCardWifiBatchItemState.queued,
        );
        expect(afterTransfer.completedCount, 0);
        expect(afterTransfer.aggregateReceivedBytes, 6144);
        expect(port.wifiSessionDownloadedKeys, <String>['card-file-1']);

        final resumed = await controller.resumeWifiBatch();
        final afterRetry = controller.state.wifiBatch!;

        expect(resumed.ok, isFalse);
        expect(afterRetry.state, RecordingCardWifiBatchState.paused);
        expect(
          afterRetry.completedCount,
          greaterThanOrEqualTo(afterTransfer.completedCount),
        );
        expect(
          afterRetry.aggregateReceivedBytes,
          greaterThanOrEqualTo(afterTransfer.aggregateReceivedBytes),
        );
        expect(afterRetry.items.first.stagedDownload?.sizeBytes, 6144);
        expect(port.wifiSessionDownloadedKeys, <String>['card-file-1']);
      },
    );

    test(
      'cancel waits for staged registration and keeps progress monotonic',
      () async {
        final operations = <String>[];
        final port = _FakeRecordingCardPort(operationLog: operations);
        port.wifiSessionDownloadCompletersByDeviceFileId['card-file-2'] =
            Completer<RecordingCardResult<RecordingCardDownloadedFile>>();
        final repository = _repository(operationLog: operations);
        final controller = RecordingCardController(
          port: port,
          localRecordingRepository: repository,
          platformPermissionsPort: _FakePlatformPermissionsPort(),
          bindingTokenProvider: _bindingToken,
        );
        addTearDown(controller.dispose);
        await controller.connect();
        await _prepareWifiBatchForTest(
          controller,
          port,
          <RecordingCardScannedFile>[
            _fileWithId(1),
            _fileWithId(2),
            _fileWithId(3),
          ],
        );
        operations.clear();
        final running = controller.startPreparedWifiBatch();
        for (
          var attempt = 0;
          attempt < 20 && port.wifiSessionDownloadedKeys.length < 2;
          attempt += 1
        ) {
          await Future<void>.delayed(Duration.zero);
        }
        expect(port.wifiSessionDownloadedKeys, hasLength(2));
        final stagedRows = repository.recordingCardWifiBatchItems();
        final completedRow = stagedRows.firstWhere(
          (row) => row['device_file_id'] == 'card-file-1',
        );
        expect(completedRow['stage'], 'completed');
        expect(completedRow['local_recording_id'], isNotNull);
        expect(completedRow.keys, isNot(contains('staged_native_file_id')));
        expect(completedRow.keys, isNot(contains('staged_file_format')));
        expect(completedRow.keys, isNot(contains('staged_size_bytes')));
        expect(completedRow.keys, isNot(contains('staged_content_hash')));
        for (final row in stagedRows) {
          expect(row.keys, isNot(contains('app_private_uri')));
          expect(row.keys, isNot(contains('ssid')));
          expect(row.keys, isNot(contains('password')));
        }
        port.emit(
          port.runtimeSnapshot.copyWith(
            transferProgress: RecordingCardTransferProgress(
              localFileKey: _fileWithId(2).localFileKey,
              receivedBytes: 100,
              aggregateReceivedBytes: 1,
              aggregateTotalBytes: 8192,
              bytesPerSecond: 1024,
              estimatedRemainingSeconds: 999,
              correlationId: 'wifi-progress-test',
            ),
          ),
        );
        expect(controller.state.wifiBatch?.rateSampleCount, 1);
        expect(controller.state.wifiBatch?.bytesPerSecond, isNull);
        expect(
          controller.state.wifiBatch?.currentFileEstimatedRemainingSeconds,
          isNull,
        );
        expect(
          controller.state.wifiBatch?.aggregateEstimatedRemainingSeconds,
          isNull,
        );
        port.emit(
          port.runtimeSnapshot.copyWith(
            transferProgress: RecordingCardTransferProgress(
              localFileKey: _fileWithId(2).localFileKey,
              receivedBytes: 100,
              aggregateReceivedBytes: 1,
              aggregateTotalBytes: 12288,
              bytesPerSecond: 1024,
              estimatedRemainingSeconds: 999,
              correlationId: 'wifi-progress-test',
            ),
          ),
        );
        expect(controller.state.wifiBatch?.completedCount, 1);
        expect(controller.state.wifiBatch?.aggregateReceivedBytes, 4196);
        expect(controller.state.wifiBatch?.rateSampleCount, 2);
        expect(controller.state.wifiBatch?.bytesPerSecond, 1024);
        expect(
          controller.state.wifiBatch?.currentFileEstimatedRemainingSeconds,
          4,
        );
        expect(
          controller.state.wifiBatch?.aggregateEstimatedRemainingSeconds,
          8,
        );

        await controller.cancelWifiBatch();
        await running;

        expect(operations, <String>[
          'open',
          'download:card-file-1',
          'stat',
          'download:card-file-2',
          'cancel',
          'refreshDeviceInfo',
          'readRecordingState',
          'scanFiles',
          'stat',
        ]);
        expect(repository.list().rows, hasLength(1));
        expect(
          controller.state.wifiBatch?.state,
          RecordingCardWifiBatchState.cancelled,
        );
        expect(
          controller.state.wifiBatch?.items[0].state,
          RecordingCardWifiBatchItemState.completed,
        );
        expect(controller.state.wifiBatch?.items[0].stagedDownload, isNull);
        expect(
          controller.state.wifiBatch?.items[1].state,
          RecordingCardWifiBatchItemState.cancelled,
        );
        expect(
          controller.state.wifiBatch?.items[2].state,
          RecordingCardWifiBatchItemState.cancelled,
        );
      },
    );

    test(
      'user pause preserves completed files and rearms unfinished work',
      () async {
        final port = _FakeRecordingCardPort();
        port.wifiSessionDownloadCompletersByDeviceFileId['card-file-2'] =
            Completer<RecordingCardResult<RecordingCardDownloadedFile>>();
        final repository = _repository();
        final controller = RecordingCardController(
          port: port,
          localRecordingRepository: repository,
          platformPermissionsPort: _FakePlatformPermissionsPort(),
          bindingTokenProvider: _bindingToken,
        );
        addTearDown(controller.dispose);
        await controller.connect();
        await _prepareWifiBatchForTest(
          controller,
          port,
          <RecordingCardScannedFile>[_fileWithId(1), _fileWithId(2)],
        );
        final running = controller.startPreparedWifiBatch();
        for (
          var attempt = 0;
          attempt < 20 && port.wifiSessionDownloadedKeys.length < 2;
          attempt += 1
        ) {
          await Future<void>.delayed(Duration.zero);
        }

        await controller.pauseWifiBatch();
        await running;

        final paused = controller.state.wifiBatch!;
        expect(paused.state, RecordingCardWifiBatchState.paused);
        expect(
          paused.items.first.state,
          RecordingCardWifiBatchItemState.completed,
        );
        expect(paused.items.last.state, RecordingCardWifiBatchItemState.queued);
        expect(controller.state.lastErrorCode, isNull);
        expect(
          repository.recordingCardWifiBatchItems().first['batch_stage'],
          RecordingCardWifiBatchState.paused.name,
        );

        port.wifiSessionDownloadCompletersByDeviceFileId.remove('card-file-2');
        final resumed = await controller.resumeWifiBatch();
        expect(resumed.ok, isTrue, reason: resumed.error?.code);
        expect(
          controller.state.wifiBatch?.state,
          RecordingCardWifiBatchState.completed,
        );
        expect(
          controller.state.wifiBatch?.items.first.state,
          RecordingCardWifiBatchItemState.completed,
        );
        expect(
          controller.state.wifiBatch?.items.last.state,
          RecordingCardWifiBatchItemState.completed,
        );
        expect(repository.list().rows, hasLength(2));
      },
    );

    test(
      'restores staged files without opening Wi-Fi or downloading again',
      () async {
        final operations = <String>[];
        final database = AppDatabase();
        final repository = LocalRecordingRepository(
          database: database,
          fileStorage: _RecordingCardFileStorage(operationLog: operations),
        );
        final createdAt = DateTime.utc(2026, 7, 16, 9);
        repository.upsertRecordingCardWifiBatchItem(
          transferId:
              'wifi-${sha256.convert(utf8.encode('wifi-staged-batch:0'))}',
          batchId: 'wifi-staged-batch',
          deviceFingerprint: 'card-fingerprint-1',
          deviceIdentity: 'card-fingerprint-1',
          deviceFileId: 'card-file-1',
          deviceFilename: '20260701090001',
          localFileKey: _fileWithId(1).localFileKey,
          itemOrder: 0,
          expectedSizeBytes: 4096,
          attemptCount: 1,
          batchStage: 'registering',
          stage: 'verifying',
          idempotencyKey: sha256
              .convert(
                utf8.encode('card-fingerprint-1:card-file-1:wifi-staged-batch'),
              )
              .toString(),
          createdAt: createdAt,
          updatedAt: createdAt,
          fileFormat: 'm4a',
          mimeType: 'audio/mp4',
          stagedNativeFileId: 'card-11111111111111111111111111111111',
          stagedFileFormat: 'm4a',
          stagedSizeBytes: 4096,
          stagedContentHash:
              'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        );
        final port = _FakeRecordingCardPort(
          operationLog: operations,
          scannedFile: _fileWithId(1),
        );
        final deferredScan =
            Completer<RecordingCardResult<List<RecordingCardScannedFile>>>();
        port.scanFilesCompleter = deferredScan;
        final controller = RecordingCardController(
          port: port,
          localRecordingRepository: repository,
          platformPermissionsPort: _FakePlatformPermissionsPort(),
          bindingTokenProvider: _bindingToken,
        );
        addTearDown(controller.dispose);

        var restoreSettled = false;
        final restore = controller.restoreWifiBatch().whenComplete(() {
          restoreSettled = true;
        });
        await _waitFor(() => port.scanFilesCallCount == 1);

        expect(port.wifiSessionOpenCallCount, 0);
        expect(port.wifiSessionDownloadedKeys, isEmpty);
        expect(operations, <String>[
          'stat',
          'close',
          'connect',
          'refreshDeviceInfo',
          'readRecordingState',
          'scanFiles',
        ]);
        expect(port.connectRequests.single?.forceScan, isFalse);
        expect(controller.hasActiveTransfer, isTrue);
        expect(restoreSettled, isFalse);
        expect(await controller.dismissWifiBatch(), isFalse);
        expect(controller.state.wifiBatch, isNotNull);

        port.scanFilesCompleter = null;
        deferredScan.complete(
          RecordingCardResult<List<RecordingCardScannedFile>>.success(
            <RecordingCardScannedFile>[port.scannedFile],
          ),
        );
        await restore;

        expect(repository.list().rows, hasLength(1));
        expect(
          controller.state.wifiBatch?.state,
          RecordingCardWifiBatchState.completed,
        );
        expect(
          controller.state.wifiBatch?.items[0].state,
          RecordingCardWifiBatchItemState.completed,
        );
        expect(controller.state.wifiBatch?.items[0].stagedDownload, isNull);
        expect(controller.hasActiveTransfer, isFalse);
        expect(restoreSettled, isTrue);
        final completedRow = repository
            .recordingCardWifiBatchItems()
            .firstWhere((row) => row['device_file_id'] == 'card-file-1');
        expect(
          completedRow['stage'],
          RecordingCardWifiBatchItemState.completed.name,
        );
        expect(completedRow.keys, isNot(contains('staged_native_file_id')));
        expect(completedRow.keys, isNot(contains('app_private_uri')));
      },
    );

    test(
      'cold restore settles 23 staged unknown-format files and releases a stopped 40-file batch',
      () async {
        const serialNumber = 'CARD-COLD-RESTORE-001';
        final fixture = _persistUnknownFormatWifiBatch(
          accountScope: 'cold-restore-40-files',
          serialNumber: serialNumber,
          fileCount: 40,
          stagedCount: 23,
          stopRequested: true,
        );
        final port = _RecoveryRecordingCardPort(serialNumber: serialNumber);
        port.onRecoveryLookup = (_) {
          expect(fixture.repository.list().rows, hasLength(23));
        };
        RecordingCardController createController() => RecordingCardController(
          port: port,
          localRecordingRepository: fixture.repository,
          platformPermissionsPort: _FakePlatformPermissionsPort(),
          syncLedgerPersistence: fixture.ledger,
          bindingTokenProvider: _bindingToken,
        );
        var controller = createController();
        addTearDown(() => controller.dispose());

        await controller.restoreWifiBatch();

        final restored = controller.state.wifiBatch!;
        expect(restored.state, RecordingCardWifiBatchState.cancelled);
        expect(restored.stopRequested, isTrue);
        expect(restored.items.where((item) => item.isCompleted), hasLength(23));
        expect(
          restored.items.where(
            (item) => item.state == RecordingCardWifiBatchItemState.cancelled,
          ),
          hasLength(17),
        );
        expect(
          restored.items.any((item) => item.stagedDownload != null),
          isFalse,
        );
        expect(port.recoveryTargets, hasLength(17));
        expect(controller.state.lastErrorCode, isNull);
        expect(controller.hasActiveTransfer, isFalse);
        expect(controller.hasAutomaticSyncBlockingWifiBatch, isFalse);
        expect(port.connectCallCount, 0);
        expect(port.wifiSessionPrepareCallCount, 0);
        expect(port.wifiSessionOpenCallCount, 0);
        expect(port.wifiSessionDownloadedKeys, isEmpty);

        controller.dispose();
        controller = createController();
        await controller.restoreWifiBatch();

        expect(fixture.repository.list().rows, hasLength(23));
        expect(
          controller.state.wifiBatch?.state,
          RecordingCardWifiBatchState.cancelled,
        );
        expect(controller.hasAutomaticSyncBlockingWifiBatch, isFalse);
        expect(controller.pendingBluetoothResumeEntries, isEmpty);
        await controller.connect();
        await _awaitAutomaticScan(controller, port);
        final queued = await _queueWifiBatchForTest(controller, port, [
          fixture.files.last,
        ]);
        expect(queued.ok, isTrue, reason: queued.error?.code);
        expect(queued.value?.state, RecordingCardWifiBatchState.queued);
      },
    );

    test(
      'cold restore registers staged and later committed files despite another target lookup failure',
      () async {
        const serialNumber = 'CARD-COLD-FAILURE-001';
        final fixture = _persistUnknownFormatWifiBatch(
          accountScope: 'cold-restore-isolated-failure',
          serialNumber: serialNumber,
          fileCount: 3,
          stagedCount: 1,
          stopRequested: false,
        );
        final port = _RecoveryRecordingCardPort(serialNumber: serialNumber);
        final failedTarget = fixture.downloads[1].localFileId!;
        final recovered = fixture.downloads[2];
        port.recoveryErrors[failedTarget] =
            'RECORDING_CARD_WIFI_LOCAL_RECOVERY_FAILED';
        port.committed[recovered.localFileId!] = recovered;
        port.onRecoveryLookup = (_) {
          expect(fixture.repository.list().rows, hasLength(1));
        };
        final controller = RecordingCardController(
          port: port,
          localRecordingRepository: fixture.repository,
          platformPermissionsPort: _FakePlatformPermissionsPort(),
          syncLedgerPersistence: fixture.ledger,
          bindingTokenProvider: _bindingToken,
        );
        addTearDown(controller.dispose);

        await controller.restoreWifiBatch();

        expect(port.recoveryTargets, [failedTarget, recovered.localFileId]);
        expect(fixture.repository.list().rows, hasLength(2));
        expect(controller.state.wifiBatch?.completedCount, 2);
        expect(
          controller.state.wifiBatch?.state,
          RecordingCardWifiBatchState.paused,
        );
        expect(
          controller.state.lastErrorCode,
          'RECORDING_CARD_WIFI_LOCAL_RECOVERY_FAILED',
        );
        expect(controller.state.hasRunningTransfer, isFalse);
        expect(controller.state.operation.isActive, isFalse);
        expect(controller.hasAutomaticSyncBlockingWifiBatch, isTrue);
        expect(port.connectCallCount, 0);
        expect(port.wifiSessionOpenCallCount, 0);
        expect(port.wifiSessionDownloadedKeys, isEmpty);
      },
    );

    test(
      'restored fingerprint-only batch can be cancelled and dismissed',
      () async {
        final fixture = _persistLegacyFingerprintWifiBatch(
          accountScope: 'wifi-legacy-cancel-account',
          batchId: 'wifi-legacy-cancel-batch',
        );
        final port = _FakeRecordingCardPort(
          serialNumber: 'CARD-LEGACY-CANCEL-001',
        );
        final controller = RecordingCardController(
          port: port,
          localRecordingRepository: fixture.repository,
          platformPermissionsPort: _FakePlatformPermissionsPort(),
          syncLedgerPersistence: fixture.ledger,
          bindingTokenProvider: _bindingToken,
        );
        addTearDown(controller.dispose);

        await controller.restoreWifiBatch();

        expect(
          controller.state.wifiBatch?.state,
          RecordingCardWifiBatchState.paused,
        );
        expect(
          controller.state.wifiBatch?.failureCode,
          'RECORDING_CARD_WIFI_BATCH_IDENTITY_RECOVERY_REQUIRED',
        );
        expect(controller.hasUnresolvedWifiBatch, isTrue);
        expect(controller.hasAutomaticSyncBlockingWifiBatch, isTrue);
        expect(controller.state.hasRunningTransfer, isFalse);
        expect(port.connectCallCount, 0);

        await controller.cancelWifiBatch();

        expect(
          controller.state.wifiBatch?.state,
          RecordingCardWifiBatchState.cancelled,
        );
        expect(controller.state.lastErrorCode, isNull);
        expect(controller.hasActiveTransfer, isFalse);
        expect(await controller.dismissWifiBatch(), isTrue);
        expect(controller.state.wifiBatch, isNull);
        expect(fixture.repository.recordingCardWifiBatchItems(), isEmpty);
      },
    );

    test(
      'resume upgrades fingerprint-only batch identity before ledger reuse',
      () async {
        const serialNumber = 'CARD-LEGACY-RESUME-001';
        final fixture = _persistLegacyFingerprintWifiBatch(
          accountScope: 'wifi-legacy-resume-account',
          batchId: 'wifi-legacy-resume-batch',
        );
        final authorization = _FakeConnectionAuthorization.success();
        final port = _FakeRecordingCardPort(
          serialNumber: serialNumber,
          scannedFile: _fileWithId(1),
        );
        final controller = RecordingCardController(
          port: port,
          localRecordingRepository: fixture.repository,
          platformPermissionsPort: _FakePlatformPermissionsPort(),
          syncLedgerPersistence: fixture.ledger,
          bindingTokenProvider: _bindingToken,
          connectionAuthorization: authorization,
        );
        addTearDown(controller.dispose);
        await controller.restoreWifiBatch();

        final resumed = await controller.resumeWifiBatch();

        expect(resumed.ok, isTrue, reason: resumed.error?.code);
        expect(
          controller.state.wifiBatch?.state,
          RecordingCardWifiBatchState.completed,
        );
        expect(port.connectCallCount, 1);
        expect(
          port.connectRequests.last?.safeDeviceFingerprint,
          fixture.deviceFingerprint,
        );
        expect(authorization.callCount, 1);
        final digest = RecordingCardFileIdentity.digestSerialNumber(
          serialNumber,
        )!;
        final normalizedSerial = normalizeRecordingCardSerialNumberForOwnership(
          serialNumber,
        )!;
        final row = fixture.repository.recordingCardWifiBatchItems().single;
        expect(row['device_identity'], 'serial:$normalizedSerial');
        expect(row['card_sn_digest'], digest);
        expect(row['ledger_source_signature'], isNotNull);
        final ledgerEntry = fixture.ledger.loadFileLedger(digest).single;
        expect(ledgerEntry.sourceSignature, row['ledger_source_signature']);
        expect(ledgerEntry.localState, RecordingCardFileLocalState.synced);

        await controller.cancelWifiBatch();
      },
    );

    test('wrong card cannot upgrade a fingerprint-only batch', () async {
      final fixture = _persistLegacyFingerprintWifiBatch(
        accountScope: 'wifi-legacy-mismatch-account',
        batchId: 'wifi-legacy-mismatch-batch',
      );
      final authorization = _FakeConnectionAuthorization.success();
      final port = _FakeRecordingCardPort(serialNumber: 'CARD-WRONG-001');
      final controller = RecordingCardController(
        port: port,
        localRecordingRepository: fixture.repository,
        platformPermissionsPort: _FakePlatformPermissionsPort(),
        syncLedgerPersistence: fixture.ledger,
        bindingTokenProvider: _bindingToken,
        connectionAuthorization: authorization,
      );
      addTearDown(controller.dispose);
      await controller.restoreWifiBatch();
      port.emit(
        port.runtimeSnapshot.copyWith(
          deviceState: const RecordingCardDeviceState(
            connectionState: RecordingCardConnectionState.connected,
            connectionStage: RecordingCardConnectionStage.connected,
            displayName: 'Other FW920',
            safeDeviceFingerprint: 'different-card-fingerprint',
            serialNumber: 'CARD-WRONG-001',
          ),
        ),
      );

      final resumed = await controller.resumeWifiBatch();

      expect(resumed.ok, isFalse);
      expect(resumed.error?.code, 'RECORDING_CARD_WIFI_BATCH_DEVICE_MISMATCH');
      expect(
        controller.state.wifiBatch?.state,
        RecordingCardWifiBatchState.paused,
      );
      expect(controller.state.hasRunningTransfer, isFalse);
      final row = fixture.repository.recordingCardWifiBatchItems().single;
      expect(row['device_identity'], fixture.deviceFingerprint);
      expect(row['card_sn_digest'], isNull);
      expect(row['ledger_source_signature'], isNull);
    });

    test(
      'fresh selection releases a restored incomplete batch without stages',
      () async {
        final repository = _repository();
        final createdAt = DateTime.utc(2026, 7, 16, 10);
        repository.upsertRecordingCardWifiBatchItem(
          transferId:
              'wifi-${sha256.convert(utf8.encode('wifi-incomplete-batch:0'))}',
          batchId: 'wifi-incomplete-batch',
          deviceFingerprint: 'card-fingerprint-1',
          deviceIdentity: 'card-fingerprint-1',
          deviceFileId: 'card-file-1',
          deviceFilename: '20260716100000',
          localFileKey: _fileWithId(1).localFileKey,
          itemOrder: 0,
          expectedSizeBytes: 4924,
          attemptCount: 1,
          batchStage: RecordingCardWifiBatchState.paused.name,
          stage: RecordingCardWifiBatchItemState.failed.name,
          idempotencyKey: sha256
              .convert(
                utf8.encode(
                  'card-fingerprint-1:card-file-1:wifi-incomplete-batch',
                ),
              )
              .toString(),
          createdAt: createdAt,
          updatedAt: createdAt,
          errorCode: 'RECORDING_CARD_WIFI_DOWNLOAD_INCOMPLETE',
          fileFormat: 'm4a',
          mimeType: 'audio/mp4',
        );
        final port = _FakeRecordingCardPort();
        final controller = RecordingCardController(
          port: port,
          localRecordingRepository: repository,
          platformPermissionsPort: _FakePlatformPermissionsPort(),
          bindingTokenProvider: _bindingToken,
        );
        addTearDown(controller.dispose);
        await controller.restoreWifiBatch();
        expect(
          controller.state.wifiBatch?.state,
          RecordingCardWifiBatchState.cancelled,
        );
        expect(
          controller.state.wifiBatch?.failureCode,
          'RECORDING_CARD_WIFI_HANDOFF_TO_BLUETOOTH',
        );
        await controller.connect();

        final prepared = await _prepareWifiBatchForTest(
          controller,
          port,
          <RecordingCardScannedFile>[_fileWithId(2)],
        );

        expect(prepared.ok, isTrue, reason: prepared.error?.code);
        expect(
          controller.state.wifiBatch?.batchId,
          isNot('wifi-incomplete-batch'),
        );
        expect(
          controller.state.wifiBatch?.state,
          RecordingCardWifiBatchState.awaitingHotspot,
        );
        final oldRows = repository.recordingCardWifiBatchItems().where(
          (row) => row['batch_id'] == 'wifi-incomplete-batch',
        );
        expect(oldRows, isEmpty);
        expect(
          repository.recordingCardWifiBatchItems().map(
            (row) => row['batch_id'],
          ),
          everyElement(controller.state.wifiBatch?.batchId),
        );
      },
    );

    test(
      'awaiting Wi-Fi batch rearms hotspot without replacing task',
      () async {
        final port = _FakeRecordingCardPort();
        final repository = _repository();
        final controller = RecordingCardController(
          port: port,
          localRecordingRepository: repository,
          platformPermissionsPort: _FakePlatformPermissionsPort(),
          bindingTokenProvider: _bindingToken,
        );
        addTearDown(controller.dispose);
        await controller.connect();

        final prepared = await _prepareWifiBatchForTest(
          controller,
          port,
          <RecordingCardScannedFile>[_fileWithId(1)],
        );
        expect(prepared.ok, isTrue, reason: prepared.error?.code);
        final batchId = controller.state.wifiBatch!.batchId;
        final recordsBefore = repository.recordingCardWifiBatchItems();

        final rearmed = await controller.resumeWifiBatch();

        expect(rearmed.ok, isTrue, reason: rearmed.error?.code);
        expect(port.wifiSessionPrepareCallCount, 2);
        expect(port.wifiSessionOpenCallCount, 1);
        expect(controller.state.wifiBatch?.batchId, batchId);
        expect(controller.state.wifiBatch?.items, hasLength(1));
        expect(
          controller.state.wifiBatch?.state,
          RecordingCardWifiBatchState.completed,
        );
        expect(
          repository
              .recordingCardWifiBatchItems()
              .map((row) => row['transfer_id'])
              .toList(),
          recordsBefore.map((row) => row['transfer_id']).toList(),
        );
      },
    );

    test(
      'reconciliation intent persistence failure still recovers exact card',
      () async {
        const accountScope = 'wifi-reconciliation-persist-failure-account';
        const serialNumber = 'CARDRECONCILEPERSIST001';
        final database = AppDatabase();
        final repository = LocalRecordingRepository(
          database: database,
          fileStorage: const _RecordingCardFileStorage(),
          accountScope: accountScope,
        );
        final ledger = _DeferredFlushRecordingCardLedger(
          RecordingCardSyncLedgerStore(
            database: database,
            accountScope: accountScope,
          ),
        );
        final operations = <String>[];
        final port = _FakeRecordingCardPort(
          operationLog: operations,
          serialNumber: serialNumber,
        );
        final controller = RecordingCardController(
          port: port,
          localRecordingRepository: repository,
          platformPermissionsPort: _FakePlatformPermissionsPort(),
          syncLedgerPersistence: ledger,
          bindingTokenProvider: _bindingToken,
        );
        addTearDown(controller.dispose);
        await controller.connect();
        await _awaitAutomaticScan(controller, port);
        final prepared = await _prepareWifiBatchForTest(
          controller,
          port,
          <RecordingCardScannedFile>[_fileWithId(1)],
        );
        expect(prepared.ok, isTrue, reason: prepared.error?.code);
        final connectsBeforeRun = port.connectCallCount;
        final refreshesBeforeRun = port.refreshDeviceInfoCallCount;
        final recordingReadsBeforeRun = port.readRecordingStateCallCount;
        final scansBeforeRun = port.scanFilesCallCount;
        final nativeClose = Completer<RecordingCardResult<bool>>();
        port.wifiCloseCompleter = nativeClose;

        final running = controller.startPreparedWifiBatch();
        await _waitFor(() => port.wifiSessionCloseCallCount == 1);
        final flush = ledger.deferNextFlush(
          failure: StateError('forced reconciliation intent flush failure'),
        );
        addTearDown(flush.release);
        port.emit(
          port.runtimeSnapshot.copyWith(
            deviceState: RecordingCardDeviceState.disconnected(),
          ),
        );
        nativeClose.complete(RecordingCardResult<bool>.success(true));
        await flush.started.future;
        await Future<void>.delayed(Duration.zero);

        expect(
          controller.state.wifiBatch?.state,
          RecordingCardWifiBatchState.reconciling,
          reason:
              'failure=${controller.state.wifiBatch?.failureCode}, '
              'phase=${controller.state.wifiBatch?.operationPhase}, '
              'items=${controller.state.wifiBatch?.items.map((item) => '${item.state}:${item.errorCode}').join(',')}',
        );
        expect(
          controller.state.wifiBatch?.operationPhase,
          RecordingCardWifiOperationPhase.recovering,
        );

        flush.release();
        await running;

        expect(port.connectCallCount, connectsBeforeRun + 1);
        expect(
          port.connectRequests.last?.safeDeviceFingerprint,
          'card-fingerprint-1',
        );
        expect(port.connectRequests.last?.expectedSerialNumber, serialNumber);
        expect(
          port.connectRequests.last?.bindingTokenHex,
          '0123456789abcdef0123456789abcdef',
        );
        expect(port.refreshDeviceInfoCallCount, refreshesBeforeRun + 1);
        expect(port.readRecordingStateCallCount, recordingReadsBeforeRun + 1);
        expect(port.scanFilesCallCount, scansBeforeRun + 1);
        expect(
          controller.state.wifiBatch?.state,
          RecordingCardWifiBatchState.reconciling,
        );
        expect(
          controller.state.wifiBatch?.failureCode,
          'RECORDING_CARD_WIFI_BATCH_PERSIST_FAILED',
        );
        expect(
          controller.state.wifiBatch?.operationPhase,
          RecordingCardWifiOperationPhase.idle,
        );
        expect(
          controller.state.lastErrorCode,
          'RECORDING_CARD_WIFI_BATCH_PERSIST_FAILED',
        );
        expect(controller.hasActiveDeviceOperation, isFalse);
        expect(controller.hasActiveTransfer, isTrue);
        expect(repository.list().rows, hasLength(1));
      },
    );

    for (final failedFinalization in <bool>[false, true]) {
      final finalizationName = failedFinalization
          ? 'failed batch finalization'
          : 'final reconciliation';
      test(
        'user cancel wins while $finalizationName persistence is pending',
        () async {
          final accountScope = failedFinalization
              ? 'wifi-failed-finalization-cancel-account'
              : 'wifi-reconciliation-cancel-account';
          final database = AppDatabase();
          final repository = LocalRecordingRepository(
            database: database,
            fileStorage: const _RecordingCardFileStorage(),
            accountScope: accountScope,
          );
          final ledger = _DeferredFlushRecordingCardLedger(
            RecordingCardSyncLedgerStore(
              database: database,
              accountScope: accountScope,
            ),
          );
          final port = _FakeRecordingCardPort(
            serialNumber: failedFinalization
                ? 'CARD-FAILED-CANCEL-001'
                : 'CARD-RECONCILE-CANCEL-001',
          );
          final controller = RecordingCardController(
            port: port,
            localRecordingRepository: repository,
            platformPermissionsPort: _FakePlatformPermissionsPort(),
            syncLedgerPersistence: ledger,
            bindingTokenProvider: _bindingToken,
          );
          addTearDown(controller.dispose);
          await controller.connect();
          await _awaitAutomaticScan(controller, port);
          final file = _fileWithId(1);
          final prepared = await _prepareWifiBatchForTest(
            controller,
            port,
            <RecordingCardScannedFile>[file],
          );
          expect(prepared.ok, isTrue, reason: prepared.error?.code);
          if (failedFinalization) {
            port.wifiSessionFailuresByDeviceFileId[file.deviceFileId] =
                'RECORDING_CARD_WIFI_DOWNLOAD_INCOMPLETE';
          }
          final nativeClose = Completer<RecordingCardResult<bool>>();
          port.wifiCloseCompleter = nativeClose;

          final running = controller.startPreparedWifiBatch();
          await _waitFor(() => port.wifiSessionCloseCallCount == 1);
          final flush = ledger.deferNextFlush();
          addTearDown(flush.release);
          port.emit(
            port.runtimeSnapshot.copyWith(
              deviceState: RecordingCardDeviceState.disconnected(),
            ),
          );
          nativeClose.complete(RecordingCardResult<bool>.success(true));
          await flush.started.future;
          await Future<void>.delayed(Duration.zero);
          final connectsBeforeCancel = port.connectCallCount;

          final cancelling = controller.cancelWifiBatch();
          await _waitFor(
            () => controller.state.wifiBatch?.stopRequested == true,
          );
          expect(
            controller.state.wifiBatch?.state,
            isNot(RecordingCardWifiBatchState.completed),
          );
          expect(
            controller.state.wifiBatch?.state,
            isNot(RecordingCardWifiBatchState.failed),
          );

          flush.release();
          await Future.wait<void>(<Future<void>>[running, cancelling]);

          expect(
            controller.state.wifiBatch?.state,
            RecordingCardWifiBatchState.cancelled,
            reason: finalizationName,
          );
          expect(
            controller.state.wifiBatch?.stopRequested,
            isTrue,
            reason: finalizationName,
          );
          expect(
            port.connectCallCount,
            connectsBeforeCancel + 1,
            reason: 'only the cancellation owner may recover BLE',
          );
          expect(
            controller.state.wifiBatch?.operationPhase,
            RecordingCardWifiOperationPhase.idle,
          );
          expect(controller.hasActiveDeviceOperation, isFalse);
        },
      );
    }

    test(
      'reconciling Wi-Fi batch exposes bounded BLE recovery failure',
      () async {
        final repository = _repository();
        final port = _FakeRecordingCardPort();
        final controller = RecordingCardController(
          port: port,
          localRecordingRepository: repository,
          platformPermissionsPort: _FakePlatformPermissionsPort(),
          bindingTokenProvider: _bindingToken,
          wifiBleRecoveryTimeout: const Duration(milliseconds: 50),
        );
        addTearDown(controller.dispose);
        await controller.connect();
        await _awaitAutomaticScan(controller, port);
        final initialScanCount = port.scanFilesCallCount;
        await _prepareWifiBatchForTest(
          controller,
          port,
          <RecordingCardScannedFile>[_fileWithId(1)],
        );
        final nativeClose = Completer<RecordingCardResult<bool>>();
        port.wifiCloseCompleter = nativeClose;

        final running = controller.startPreparedWifiBatch();
        await _waitFor(() => port.wifiSessionCloseCallCount == 1);
        port.emit(
          port.runtimeSnapshot.copyWith(
            deviceState: RecordingCardDeviceState.disconnected(),
          ),
        );
        port.failNextConnect = true;
        nativeClose.complete(RecordingCardResult<bool>.success(true));
        await running;

        expect(port.connectCallCount, 2);
        expect(port.scanFilesCallCount, initialScanCount);
        expect(
          controller.state.wifiBatch?.state,
          RecordingCardWifiBatchState.reconciling,
        );
        expect(controller.hasActiveTransfer, isTrue);
        expect(controller.state.lastDownloadedFile, isNotNull);
        expect(
          controller.state.lastErrorCode,
          'RECORDING_CARD_CONNECTION_FAILED',
        );
        expect(controller.state.status, RecordingCardControllerStatus.error);
        expect(repository.list().rows, hasLength(1));
      },
    );

    test(
      'Wi-Fi recovery reconnect timeout retains unresolved ownership',
      () async {
        final port = _FakeRecordingCardPort();
        final controller = RecordingCardController(
          port: port,
          localRecordingRepository: _repository(),
          platformPermissionsPort: _FakePlatformPermissionsPort(),
          bindingTokenProvider: _bindingToken,
          wifiBleRecoveryTimeout: const Duration(milliseconds: 20),
        );
        addTearDown(controller.dispose);
        await controller.connect();
        await _awaitAutomaticScan(controller, port);
        await _prepareWifiBatchForTest(
          controller,
          port,
          <RecordingCardScannedFile>[_fileWithId(1)],
        );
        final nativeClose = Completer<RecordingCardResult<bool>>();
        port.wifiCloseCompleter = nativeClose;
        port.connectCompleter =
            Completer<RecordingCardResult<RecordingCardDeviceState>>();

        final running = controller.startPreparedWifiBatch();
        await _waitFor(() => port.wifiSessionCloseCallCount == 1);
        port.emit(
          port.runtimeSnapshot.copyWith(
            deviceState: RecordingCardDeviceState.disconnected(),
          ),
        );
        nativeClose.complete(RecordingCardResult<bool>.success(true));
        await running.timeout(const Duration(seconds: 1));

        expect(port.connectCallCount, 2);
        expect(controller.hasActiveTransfer, isTrue);
        expect(
          controller.state.wifiBatch?.state,
          RecordingCardWifiBatchState.reconciling,
        );
        expect(
          controller.state.lastErrorCode,
          'RECORDING_CARD_WIFI_BLE_RECONNECT_TIMEOUT',
        );
      },
    );

    test(
      'Wi-Fi recovery authorization timeout retains unresolved ownership',
      () async {
        final port = _FakeRecordingCardPort();
        final authorization = _FakeConnectionAuthorization.success();
        final controller = RecordingCardController(
          port: port,
          localRecordingRepository: _repository(),
          platformPermissionsPort: _FakePlatformPermissionsPort(),
          bindingTokenProvider: _bindingToken,
          connectionAuthorization: authorization,
          wifiBleRecoveryTimeout: const Duration(milliseconds: 20),
        );
        addTearDown(controller.dispose);
        await controller.connect();
        await _awaitAutomaticScan(controller, port);
        await _prepareWifiBatchForTest(
          controller,
          port,
          <RecordingCardScannedFile>[_fileWithId(1)],
        );
        final nativeClose = Completer<RecordingCardResult<bool>>();
        port.wifiCloseCompleter = nativeClose;
        authorization.pendingResult = Completer<RecordingCardResult<bool>>();

        final running = controller.startPreparedWifiBatch();
        await _waitFor(() => port.wifiSessionCloseCallCount == 1);
        port.emit(
          port.runtimeSnapshot.copyWith(
            deviceState: RecordingCardDeviceState.disconnected(),
          ),
        );
        nativeClose.complete(RecordingCardResult<bool>.success(true));
        await running.timeout(const Duration(seconds: 1));

        expect(authorization.callCount, 2);
        expect(controller.hasActiveTransfer, isTrue);
        expect(
          controller.state.wifiBatch?.state,
          RecordingCardWifiBatchState.reconciling,
        );
        expect(
          controller.state.lastErrorCode,
          'RECORDING_CARD_WIFI_BLE_AUTHORIZATION_TIMEOUT',
        );
      },
    );

    for (final recoveryStage in <String>['device-info', 'recording-state']) {
      test(
        'Wi-Fi recovery $recoveryStage timeout continues to directory',
        () async {
          final port = _FakeRecordingCardPort();
          final controller = RecordingCardController(
            port: port,
            localRecordingRepository: _repository(),
            platformPermissionsPort: _FakePlatformPermissionsPort(),
            bindingTokenProvider: _bindingToken,
            wifiBleRecoveryTimeout: const Duration(milliseconds: 20),
          );
          addTearDown(controller.dispose);
          await controller.connect();
          await _awaitAutomaticScan(controller, port);
          final initialScanCount = port.scanFilesCallCount;
          await _prepareWifiBatchForTest(
            controller,
            port,
            <RecordingCardScannedFile>[_fileWithId(1)],
          );
          if (recoveryStage == 'device-info') {
            port.refreshDeviceInfoCompleter =
                Completer<RecordingCardResult<RecordingCardRuntimeSnapshot>>();
          } else {
            port.readRecordingStateCompleter =
                Completer<RecordingCardResult<RecordingCardRecordingInfo>>();
          }

          await controller.startPreparedWifiBatch().timeout(
            const Duration(seconds: 1),
          );

          expect(controller.hasActiveTransfer, isFalse);
          expect(port.scanFilesCallCount, initialScanCount + 1);
          expect(controller.state.lastErrorCode, isNull);
          expect(controller.state.status, RecordingCardControllerStatus.idle);
        },
      );
    }

    test(
      'Wi-Fi recovery directory timeout retains batch but releases scan drain',
      () async {
        final port = _FakeRecordingCardPort();
        final controller = RecordingCardController(
          port: port,
          localRecordingRepository: _repository(),
          platformPermissionsPort: _FakePlatformPermissionsPort(),
          bindingTokenProvider: _bindingToken,
          wifiBleRecoveryTimeout: const Duration(milliseconds: 20),
        );
        addTearDown(controller.dispose);
        await controller.connect();
        await _awaitAutomaticScan(controller, port);
        await _prepareWifiBatchForTest(
          controller,
          port,
          <RecordingCardScannedFile>[_fileWithId(1)],
        );
        final initialScanCount = port.scanFilesCallCount;
        port.scanFilesCompleter =
            Completer<RecordingCardResult<List<RecordingCardScannedFile>>>();

        await controller.startPreparedWifiBatch().timeout(
          const Duration(seconds: 1),
        );

        expect(controller.hasActiveTransfer, isTrue);
        expect(
          controller.state.wifiBatch?.state,
          RecordingCardWifiBatchState.reconciling,
        );
        expect(
          controller.state.lastErrorCode,
          'RECORDING_CARD_WIFI_BLE_DIRECTORY_TIMEOUT',
        );
        expect(
          controller.state.fileCatalog.phase,
          RecordingCardFileCatalogPhase.failed,
        );

        port.scanFilesCompleter = null;
        await controller.resumeWifiBatch().timeout(const Duration(seconds: 1));

        expect(port.scanFilesCallCount, initialScanCount + 2);
        expect(
          controller.state.fileCatalog.phase,
          RecordingCardFileCatalogPhase.ready,
        );
      },
    );

    test(
      'cold Wi-Fi batch hands unfinished user work to BLE without hotspot',
      () async {
        const accountScope = 'wifi-cold-ble-handoff-account';
        const serialNumber = 'CARD-COLD-HANDOFF-001';
        final database = AppDatabase();
        final repository = LocalRecordingRepository(
          database: database,
          fileStorage: const _RecordingCardFileStorage(),
          accountScope: accountScope,
        );
        final ledger = RecordingCardSyncLedgerStore(
          database: database,
          accountScope: accountScope,
        );
        final firstPort = _FakeRecordingCardPort(serialNumber: serialNumber);
        final first = RecordingCardController(
          port: firstPort,
          localRecordingRepository: repository,
          platformPermissionsPort: _FakePlatformPermissionsPort(),
          syncLedgerPersistence: ledger,
          bindingTokenProvider: _bindingToken,
        );
        await first.connect();
        await _awaitAutomaticScan(first, firstPort);
        final queued = await _queueWifiBatchForTest(
          first,
          firstPort,
          <RecordingCardScannedFile>[_fileWithId(1)],
        );
        expect(queued.ok, isTrue, reason: queued.error?.code);
        final persisted = repository.recordingCardWifiBatchItems();
        expect(persisted, hasLength(1));
        for (final row in persisted) {
          expect(row.keys, isNot(contains('ssid')));
          expect(row.keys, isNot(contains('password')));
          expect(row.keys, isNot(contains('app_private_uri')));
        }
        first.dispose();

        final restoredPort = _FakeRecordingCardPort(
          serialNumber: serialNumber,
          scannedFile: _fileWithId(1),
        );
        final restored = RecordingCardController(
          port: restoredPort,
          localRecordingRepository: repository,
          platformPermissionsPort: _FakePlatformPermissionsPort(),
          syncLedgerPersistence: ledger,
          bindingTokenProvider: _bindingToken,
        );
        addTearDown(restored.dispose);
        await restored.restoreWifiBatch();
        final resumed = await restored.resumePendingBluetoothTransfers();

        expect(resumed.ok, isTrue, reason: resumed.error?.code);
        expect(
          restored.state.wifiBatch?.state,
          RecordingCardWifiBatchState.cancelled,
        );
        expect(
          restored.state.wifiBatch?.failureCode,
          'RECORDING_CARD_WIFI_HANDOFF_TO_BLUETOOTH',
        );
        expect(restored.state.wifiBatch?.isActive, isFalse);
        expect(restoredPort.wifiSessionPrepareCallCount, 0);
        expect(restoredPort.wifiJoinCallCount, 0);
        expect(restoredPort.wifiSessionOpenCallCount, 0);
        expect(restoredPort.bleDownloadCallCount, 1);
        expect(
          restoredPort.connectRequests.single?.expectedSerialNumber,
          normalizeRecordingCardSerialNumberForOwnership(serialNumber),
        );
        expect(
          restoredPort.connectRequests.single?.safeDeviceFingerprint,
          'card-fingerprint-1',
        );
        expect(restored.hasPendingBluetoothSync, isFalse);
        final digest = RecordingCardFileIdentity.digestSerialNumber(
          serialNumber,
        )!;
        expect(
          ledger.loadFileLedger(digest).single.localState,
          RecordingCardFileLocalState.synced,
        );
      },
    );

    test(
      'cold handoff keeps Bluetooth lease through reconnect and directory',
      () async {
        const accountScope = 'wifi-cold-lease-account';
        const serialNumber = 'CARD-COLD-LEASE-001';
        final fixture = await _persistColdWifiHandoffFixture(
          accountScope: accountScope,
          serialNumber: serialNumber,
        );
        final connectGate =
            Completer<RecordingCardResult<RecordingCardDeviceState>>();
        final scanGate =
            Completer<RecordingCardResult<List<RecordingCardScannedFile>>>();
        final downloadGate =
            Completer<RecordingCardResult<RecordingCardDownloadedFile>>();
        final port =
            _FakeRecordingCardPort(
                serialNumber: serialNumber,
                scannedFile: fixture.file,
              )
              ..connectCompleter = connectGate
              ..scanFilesCompleter = scanGate
              ..bleDownloadCompletersByDeviceFileId[fixture.file.deviceFileId] =
                  downloadGate;
        final controller = RecordingCardController(
          port: port,
          localRecordingRepository: fixture.repository,
          platformPermissionsPort: _FakePlatformPermissionsPort(),
          syncLedgerPersistence: fixture.ledger,
          bindingTokenProvider: _bindingToken,
        );
        addTearDown(controller.dispose);
        await _waitFor(() => port.connectCallCount == 1);
        final resume = controller.resumePendingBluetoothTransfers();
        final actions = ControllerRecordingCardAutoSyncActions(controller);
        final connectingRevision =
            controller.state.operation.connectionRevision;
        expect(connectingRevision, isNotNull);
        final observedOperations = <RecordingCardOperationState>[];
        final observedTransports =
            <RecordingCardBackgroundTransferTransport?>[];
        var observeLease = true;
        void observe() {
          if (!observeLease) return;
          observedOperations.add(controller.state.operation);
          observedTransports.add(actions.activeTransferTransport);
        }

        controller.addListener(observe);
        addTearDown(() => controller.removeListener(observe));
        observe();

        expect(controller.hasActiveTransfer, isTrue);
        expect(
          controller.state.operation.kind,
          RecordingCardOperationKind.bluetoothTransfer,
        );
        expect(
          controller.state.operation.phase,
          RecordingCardOperationPhase.running,
        );
        expect(
          actions.activeTransferTransport,
          RecordingCardBackgroundTransferTransport.bluetooth,
        );

        final connected = RecordingCardDeviceState(
          connectionState: RecordingCardConnectionState.connected,
          connectionStage: RecordingCardConnectionStage.connected,
          displayName: 'Huahuo FW920',
          safeDeviceFingerprint: 'card-fingerprint-1',
          serialNumber: serialNumber,
          recordingFormat: RecordingCardFileFormat.m4a,
        );
        port.emit(port.runtimeSnapshot.copyWith(deviceState: connected));
        connectGate.complete(
          RecordingCardResult<RecordingCardDeviceState>.success(connected),
        );
        await _waitFor(() => port.scanFilesCallCount == 1);

        expect(controller.hasActiveTransfer, isTrue);
        expect(
          controller.state.operation.connectionRevision,
          greaterThan(connectingRevision!),
        );
        expect(
          actions.activeTransferTransport,
          RecordingCardBackgroundTransferTransport.bluetooth,
        );

        scanGate.complete(
          RecordingCardResult<List<RecordingCardScannedFile>>.success(
            <RecordingCardScannedFile>[fixture.file],
          ),
        );
        await _waitFor(() => port.bleDownloadCallCount == 1);
        expect(controller.hasActiveTransfer, isTrue);
        expect(
          actions.activeTransferTransport,
          RecordingCardBackgroundTransferTransport.bluetooth,
        );
        observeLease = false;
        expect(observedOperations, isNotEmpty);
        expect(
          observedOperations.map((operation) => operation.kind),
          everyElement(RecordingCardOperationKind.bluetoothTransfer),
        );
        expect(
          observedOperations.map((operation) => operation.phase),
          everyElement(RecordingCardOperationPhase.running),
        );
        expect(
          observedTransports,
          everyElement(RecordingCardBackgroundTransferTransport.bluetooth),
        );

        port.bleDownloadCompletersByDeviceFileId.remove(
          fixture.file.deviceFileId,
        );
        final downloaded = await port.syncFileToLocalCache(fixture.file);
        downloadGate.complete(downloaded);
        final result = await resume;

        expect(result.ok, isTrue, reason: result.error?.code);
        expect(controller.hasActiveTransfer, isFalse);
        expect(actions.activeTransferTransport, isNull);
        expect(
          fixture.ledger
              .loadFileLedger(fixture.cardDigest)
              .single
              .resumeRequested,
          isFalse,
        );
      },
    );

    test(
      'user cancel settles cold handoff before late reconnect returns',
      () async {
        const accountScope = 'wifi-cold-preflight-cancel-account';
        const serialNumber = 'CARD-COLD-PREFLIGHT-CANCEL-001';
        final fixture = await _persistColdWifiHandoffFixture(
          accountScope: accountScope,
          serialNumber: serialNumber,
        );
        final connectGate =
            Completer<RecordingCardResult<RecordingCardDeviceState>>();
        final port = _FakeRecordingCardPort(
          serialNumber: serialNumber,
          scannedFile: fixture.file,
        )..connectCompleter = connectGate;
        final controller = RecordingCardController(
          port: port,
          localRecordingRepository: fixture.repository,
          platformPermissionsPort: _FakePlatformPermissionsPort(),
          syncLedgerPersistence: fixture.ledger,
          bindingTokenProvider: _bindingToken,
        );
        addTearDown(controller.dispose);
        await _waitFor(() => port.connectCallCount == 1);
        final resume = controller.resumePendingBluetoothTransfers();
        final actions = ControllerRecordingCardAutoSyncActions(controller);

        expect(controller.hasActiveTransfer, isTrue);
        expect(
          actions.activeTransferTransport,
          RecordingCardBackgroundTransferTransport.bluetooth,
        );

        await controller.cancelWifiBatch().timeout(const Duration(seconds: 1));

        expect(controller.hasActiveTransfer, isFalse);
        expect(actions.activeTransferTransport, isNull);
        expect(controller.state.operation.isActive, isFalse);
        expect(controller.hasPendingBluetoothResume, isFalse);
        expect(
          fixture.ledger
              .loadFileLedger(fixture.cardDigest)
              .single
              .resumeRequested,
          isFalse,
        );
        expect(port.cancelCallCount, 0);
        expect(port.scanFilesCallCount, 0);
        expect(port.bleDownloadCallCount, 0);

        final connected = RecordingCardDeviceState(
          connectionState: RecordingCardConnectionState.connected,
          connectionStage: RecordingCardConnectionStage.connected,
          displayName: 'Huahuo FW920',
          safeDeviceFingerprint: 'card-fingerprint-1',
          serialNumber: serialNumber,
          recordingFormat: RecordingCardFileFormat.m4a,
        );
        connectGate.complete(
          RecordingCardResult<RecordingCardDeviceState>.success(connected),
        );
        final result = await resume;
        await Future<void>.delayed(Duration.zero);

        expect(result.ok, isFalse);
        expect(
          result.error?.code,
          'RECORDING_CARD_BLUETOOTH_RESUME_SUPERSEDED',
        );
        expect(port.scanFilesCallCount, 0);
        expect(port.bleDownloadCallCount, 0);
        expect(controller.hasActiveTransfer, isFalse);
        expect(controller.hasPendingBluetoothResume, isFalse);
      },
    );

    test(
      'user cancel fences late cold handoff authorization rejection',
      () async {
        const accountScope = 'wifi-cold-authorization-cancel-account';
        const serialNumber = 'CARD-COLD-AUTHORIZATION-CANCEL-001';
        final fixture = await _persistColdWifiHandoffFixture(
          accountScope: accountScope,
          serialNumber: serialNumber,
        );
        final staleAuthorization = Completer<RecordingCardResult<bool>>();
        final authorization = _FakeConnectionAuthorization.success()
          ..pendingResult = staleAuthorization;
        final port = _FakeRecordingCardPort(
          serialNumber: serialNumber,
          scannedFile: fixture.file,
        );
        final controller = RecordingCardController(
          port: port,
          localRecordingRepository: fixture.repository,
          platformPermissionsPort: _FakePlatformPermissionsPort(),
          syncLedgerPersistence: fixture.ledger,
          bindingTokenProvider: _bindingToken,
          connectionAuthorization: authorization,
        );
        addTearDown(controller.dispose);
        await _waitFor(() => authorization.callCount == 1);
        final resume = controller.resumePendingBluetoothTransfers();
        final actions = ControllerRecordingCardAutoSyncActions(controller);

        expect(controller.hasActiveTransfer, isTrue);
        expect(
          actions.activeTransferTransport,
          RecordingCardBackgroundTransferTransport.bluetooth,
        );

        await controller.cancelWifiBatch().timeout(const Duration(seconds: 1));
        final disconnectsAfterCancel = port.disconnectCallCount;
        final replacementAuthorization = Completer<RecordingCardResult<bool>>();
        authorization.pendingResult = replacementAuthorization;

        staleAuthorization.complete(
          RecordingCardResult<bool>.failure(
            recordingCardFailure(
              'RECORDING_CARD_CLOUD_BINDING_REJECTED',
              'Late cloud authorization rejected an obsolete handoff',
            ),
          ),
        );
        final result = await resume;
        await _waitFor(() => authorization.callCount == 2);

        expect(result.ok, isFalse);
        expect(
          result.error?.code,
          'RECORDING_CARD_BLUETOOTH_RESUME_SUPERSEDED',
        );
        expect(port.disconnectCallCount, disconnectsAfterCancel);
        expect(port.scanFilesCallCount, 0);
        expect(port.bleDownloadCallCount, 0);
        expect(controller.hasActiveTransfer, isFalse);
        expect(actions.activeTransferTransport, isNull);
        expect(controller.state.operation.isActive, isFalse);
        expect(controller.hasPendingBluetoothResume, isFalse);
        expect(
          fixture.ledger
              .loadFileLedger(fixture.cardDigest)
              .single
              .resumeRequested,
          isFalse,
        );
      },
    );

    for (final persistedState in <RecordingCardWifiBatchState>[
      RecordingCardWifiBatchState.transferring,
      RecordingCardWifiBatchState.paused,
    ]) {
      test(
        'cold ${persistedState.name} Wi-Fi interruption keeps the BLE handoff marker',
        () async {
          final accountScope =
              'wifi-cold-${persistedState.name}-handoff-account';
          final serialNumber =
              'CARD-COLD-${persistedState.name.toUpperCase()}-001';
          final database = AppDatabase();
          final repository = LocalRecordingRepository(
            database: database,
            fileStorage: const _RecordingCardFileStorage(),
            accountScope: accountScope,
          );
          final ledger = RecordingCardSyncLedgerStore(
            database: database,
            accountScope: accountScope,
          );
          final file = _fileWithId(1);
          final digest = RecordingCardFileIdentity.digestSerialNumber(
            serialNumber,
          )!;
          final normalizedSerial =
              normalizeRecordingCardSerialNumberForOwnership(serialNumber)!;
          final queued = ledger.queueManualSyncForFile(
            cardSnDigest: digest,
            file: file,
            at: DateTime.utc(2026, 9, 13, 10),
          );
          await ledger.flushSyncPersistence();
          final batchId = 'wifi-cold-${persistedState.name}-handoff';
          repository.upsertRecordingCardWifiBatchItem(
            transferId:
                'wifi-${sha256.convert(utf8.encode('$batchId:0')).toString()}',
            batchId: batchId,
            deviceFingerprint: 'card-fingerprint-1',
            deviceIdentity: 'serial:$normalizedSerial',
            cardSnDigest: digest,
            deviceFileId: file.deviceFileId,
            deviceFilename: file.deviceFilename,
            localFileKey: file.localFileKey,
            itemOrder: 0,
            expectedSizeBytes: file.sizeBytes!,
            attemptCount: 1,
            batchStage: persistedState.name,
            batchErrorCode: 'RECORDING_CARD_WIFI_PROCESS_INTERRUPTED',
            stage: persistedState == RecordingCardWifiBatchState.transferring
                ? RecordingCardWifiBatchItemState.transferring.name
                : RecordingCardWifiBatchItemState.queued.name,
            idempotencyKey: sha256
                .convert(
                  utf8.encode(
                    'serial:$normalizedSerial:${file.deviceFileId}:$batchId',
                  ),
                )
                .toString(),
            createdAt: DateTime.utc(2026, 9, 13, 10),
            updatedAt: DateTime.utc(2026, 9, 13, 10, 1),
            ledgerSourceSignature: queued.sourceSignature,
            fileFormat: file.format.name,
            mimeType: file.mimeType,
            sourceSizeConfidence: file.sizeConfidence?.name,
          );
          final port = _FakeRecordingCardPort(
            serialNumber: serialNumber,
            scannedFile: file,
          );
          final controller = RecordingCardController(
            port: port,
            localRecordingRepository: repository,
            platformPermissionsPort: _FakePlatformPermissionsPort(),
            syncLedgerPersistence: ledger,
            bindingTokenProvider: _bindingToken,
          );
          addTearDown(controller.dispose);

          await controller.restoreWifiBatch();
          expect(
            controller.state.wifiBatch?.state,
            RecordingCardWifiBatchState.cancelled,
            reason:
                '${controller.state.wifiBatch?.failureCode} / '
                '${controller.state.lastErrorCode}',
          );
          expect(
            controller.state.wifiBatch?.failureCode,
            'RECORDING_CARD_WIFI_HANDOFF_TO_BLUETOOTH',
          );
          final resumed = await controller.resumePendingBluetoothTransfers();

          expect(resumed.ok, isTrue, reason: resumed.error?.code);
          expect(port.bleDownloadedKeys, <String>[file.deviceFileId]);
          expect(port.wifiSessionPrepareCallCount, 0);
          expect(port.wifiJoinCallCount, 0);
          expect(port.wifiSessionOpenCallCount, 0);
          expect(
            port.connectRequests.single?.expectedSerialNumber,
            normalizedSerial,
          );
          expect(
            port.connectRequests.single?.safeDeviceFingerprint,
            'card-fingerprint-1',
          );
          expect(ledger.loadFileLedger(digest).single.resumeRequested, isFalse);
        },
      );
    }

    test(
      'cold handoff rejects the same serial on a different BLE fingerprint',
      () async {
        const accountScope = 'wifi-cold-identity-mismatch-account';
        const serialNumber = 'CARD-COLD-IDENTITY-001';
        final database = AppDatabase();
        final repository = LocalRecordingRepository(
          database: database,
          fileStorage: const _RecordingCardFileStorage(),
          accountScope: accountScope,
        );
        final ledger = RecordingCardSyncLedgerStore(
          database: database,
          accountScope: accountScope,
        );
        final firstPort = _FakeRecordingCardPort(serialNumber: serialNumber);
        final first = RecordingCardController(
          port: firstPort,
          localRecordingRepository: repository,
          platformPermissionsPort: _FakePlatformPermissionsPort(),
          syncLedgerPersistence: ledger,
          bindingTokenProvider: _bindingToken,
        );
        await first.connect();
        await _awaitAutomaticScan(first, firstPort);
        final queued = await _queueWifiBatchForTest(
          first,
          firstPort,
          <RecordingCardScannedFile>[_fileWithId(1)],
        );
        expect(queued.ok, isTrue, reason: queued.error?.code);
        first.dispose();

        final restoredPort = _FakeRecordingCardPort(
          serialNumber: serialNumber,
          safeDeviceFingerprint: 'different-card-fingerprint',
        );
        final restored = RecordingCardController(
          port: restoredPort,
          localRecordingRepository: repository,
          platformPermissionsPort: _FakePlatformPermissionsPort(),
          syncLedgerPersistence: ledger,
          bindingTokenProvider: _bindingToken,
        );
        addTearDown(restored.dispose);
        await restored.restoreWifiBatch();

        final resumed = await restored.resumePendingBluetoothTransfers();

        expect(resumed.ok, isFalse);
        expect(
          resumed.error?.code,
          'RECORDING_CARD_WIFI_BATCH_DEVICE_MISMATCH',
        );
        expect(restoredPort.bleDownloadCallCount, 0);
        expect(restoredPort.wifiSessionPrepareCallCount, 0);
        expect(
          restoredPort.connectRequests.single?.expectedSerialNumber,
          normalizeRecordingCardSerialNumberForOwnership(serialNumber),
        );
        expect(
          restoredPort.connectRequests.single?.safeDeviceFingerprint,
          'card-fingerprint-1',
        );
        expect(restored.hasPendingBluetoothSync, isTrue);
        expect(restored.hasPendingBluetoothResume, isTrue);
      },
    );

    test(
      'cold handoff retries the exact card after app-resume conditions recover',
      () async {
        const accountScope = 'wifi-cold-retry-account';
        const serialNumber = 'CARD-COLD-RETRY-001';
        final database = AppDatabase();
        final repository = LocalRecordingRepository(
          database: database,
          fileStorage: const _RecordingCardFileStorage(),
          accountScope: accountScope,
        );
        final ledger = RecordingCardSyncLedgerStore(
          database: database,
          accountScope: accountScope,
        );
        final firstPort = _FakeRecordingCardPort(serialNumber: serialNumber);
        final first = RecordingCardController(
          port: firstPort,
          localRecordingRepository: repository,
          platformPermissionsPort: _FakePlatformPermissionsPort(),
          syncLedgerPersistence: ledger,
          bindingTokenProvider: _bindingToken,
        );
        await first.connect();
        await _awaitAutomaticScan(first, firstPort);
        final queued = await _queueWifiBatchForTest(
          first,
          firstPort,
          <RecordingCardScannedFile>[_fileWithId(1)],
        );
        expect(queued.ok, isTrue, reason: queued.error?.code);
        first.dispose();

        final restoredPort = _FakeRecordingCardPort(
          serialNumber: serialNumber,
          scannedFile: _fileWithId(1),
        )..failNextConnect = true;
        final restored = RecordingCardController(
          port: restoredPort,
          localRecordingRepository: repository,
          platformPermissionsPort: _FakePlatformPermissionsPort(),
          syncLedgerPersistence: ledger,
          bindingTokenProvider: _bindingToken,
        );
        addTearDown(restored.dispose);
        await _waitFor(
          () =>
              restoredPort.connectCallCount == 1 &&
              restored.state.lastErrorCode ==
                  'RECORDING_CARD_CONNECTION_FAILED',
        );
        await Future<void>.delayed(const Duration(milliseconds: 1));

        final retainedBatchId = restored.state.wifiBatch!.batchId;
        expect(
          restored.state.wifiBatch?.failureCode,
          recordingCardWifiBluetoothResumeFailureCode,
        );
        expect(await restored.dismissWifiBatch(), isFalse);
        final competing = await restored.queueWifiBatch(
          <RecordingCardScannedFile>[_fileWithId(1)],
        );
        expect(competing.ok, isFalse);
        expect(competing.error?.code, recordingCardOperationBusyCode);
        expect(restored.state.wifiBatch?.batchId, retainedBatchId);
        expect(
          repository.recordingCardWifiBatchItems().map(
            (row) => row['batch_id'],
          ),
          everyElement(retainedBatchId),
        );

        await restored.reconcileConnectionState(refreshDirectory: false);
        await _waitFor(
          () =>
              restoredPort.bleDownloadCallCount == 1 &&
              !restored.hasPendingBluetoothSync &&
              !restored.hasActiveTransfer,
        );

        expect(restoredPort.connectCallCount, 2);
        for (final request in restoredPort.connectRequests) {
          expect(request?.safeDeviceFingerprint, 'card-fingerprint-1');
          expect(
            request?.expectedSerialNumber,
            normalizeRecordingCardSerialNumberForOwnership(serialNumber),
          );
        }
        expect(restoredPort.wifiSessionPrepareCallCount, 0);
        expect(await restored.dismissWifiBatch(), isTrue);
        expect(restored.state.wifiBatch, isNull);
        expect(repository.recordingCardWifiBatchItems(), isEmpty);
      },
    );

    test(
      'connected pending resume retries after a transient failure',
      () async {
        const accountScope = 'bluetooth-same-connection-retry-account';
        const serialNumber = 'CARD-BLE-SAME-CONNECTION-001';
        final database = AppDatabase();
        final repository = LocalRecordingRepository(
          database: database,
          fileStorage: const _RecordingCardFileStorage(),
          accountScope: accountScope,
        );
        final ledger = RecordingCardSyncLedgerStore(
          database: database,
          accountScope: accountScope,
        );
        final digest = RecordingCardFileIdentity.digestSerialNumber(
          serialNumber,
        )!;
        final file = _fileWithId(1);
        ledger.queueManualSyncForFile(
          cardSnDigest: digest,
          file: file,
          at: DateTime.utc(2026, 9, 13, 9),
        );
        await ledger.flushSyncPersistence();
        final firstAttempt =
            Completer<RecordingCardResult<RecordingCardDownloadedFile>>()
              ..complete(
                RecordingCardResult<RecordingCardDownloadedFile>.failure(
                  _failure('RECORDING_CARD_DISCONNECTED'),
                ),
              );
        final port =
            _FakeRecordingCardPort(
                serialNumber: serialNumber,
                scannedFile: file,
              )
              ..bleDownloadCompletersByDeviceFileId[file.deviceFileId] =
                  firstAttempt;
        final controller = RecordingCardController(
          port: port,
          localRecordingRepository: repository,
          platformPermissionsPort: _FakePlatformPermissionsPort(),
          syncLedgerPersistence: ledger,
          bindingTokenProvider: _bindingToken,
        );
        addTearDown(controller.dispose);

        await controller.connect();
        await _awaitAutomaticScan(controller, port);
        await _waitFor(
          () =>
              port.bleDownloadCallCount == 1 &&
              controller.hasPendingBluetoothResume,
        );
        port.bleDownloadCompletersByDeviceFileId.remove(file.deviceFileId);

        await controller.reconcileConnectionState(refreshDirectory: false);
        await _waitFor(
          () =>
              port.bleDownloadCallCount == 2 &&
              !controller.hasPendingBluetoothSync,
        );

        expect(port.connectCallCount, 1);
        expect(repository.list().rows, hasLength(1));
      },
    );

    test(
      'Bluetooth handoff failure retries BLE without reopening Wi-Fi',
      () async {
        const accountScope = 'wifi-handoff-ble-retry-account';
        const serialNumber = 'CARD-WIFI-BLE-RETRY-001';
        final fixture = await _persistColdWifiHandoffFixture(
          accountScope: accountScope,
          serialNumber: serialNumber,
        );
        final firstAttempt =
            Completer<RecordingCardResult<RecordingCardDownloadedFile>>()
              ..complete(
                RecordingCardResult<RecordingCardDownloadedFile>.failure(
                  _failure('RECORDING_CARD_DOWNLOAD_FAILED'),
                ),
              );
        final port =
            _FakeRecordingCardPort(
                serialNumber: serialNumber,
                scannedFile: fixture.file,
              )
              ..bleDownloadCompletersByDeviceFileId[fixture.file.deviceFileId] =
                  firstAttempt;
        final controller = RecordingCardController(
          port: port,
          localRecordingRepository: fixture.repository,
          platformPermissionsPort: _FakePlatformPermissionsPort(),
          syncLedgerPersistence: fixture.ledger,
          bindingTokenProvider: _bindingToken,
        );
        addTearDown(controller.dispose);

        await _waitFor(
          () =>
              controller.state.wifiBatch?.failureCode ==
                  recordingCardWifiBluetoothResumeFailureCode &&
              !controller.state.hasRunningTransfer &&
              !controller.hasActiveDeviceOperation,
        );
        expect(
          ControllerRecordingCardAutoSyncActions(
            controller,
          ).activeTransferTransport,
          isNull,
        );
        expect(
          controller.state.wifiBatch?.state,
          RecordingCardWifiBatchState.paused,
        );
        expect(
          controller.state.wifiBatch?.items.single.errorCode,
          'RECORDING_CARD_DOWNLOAD_FAILED',
        );

        port.emit(
          port.runtimeSnapshot.copyWith(
            deviceState: RecordingCardDeviceState.disconnected(),
          ),
        );
        port.bleDownloadCompletersByDeviceFileId.remove(
          fixture.file.deviceFileId,
        );
        final resumed = await controller.resumeWifiBatch();

        expect(resumed.ok, isTrue, reason: resumed.error?.code);
        expect(port.bleDownloadCallCount, 2);
        expect(port.connectCallCount, 2);
        expect(
          port.connectRequests.last?.safeDeviceFingerprint,
          'card-fingerprint-1',
        );
        expect(
          port.connectRequests.last?.expectedSerialNumber,
          normalizeRecordingCardSerialNumberForOwnership(serialNumber),
        );
        expect(port.wifiSessionPrepareCallCount, 0);
        expect(port.wifiJoinCallCount, 0);
        expect(port.wifiSessionOpenCallCount, 0);
        expect(
          fixture.ledger.loadFileLedger(fixture.cardDigest).single.localState,
          RecordingCardFileLocalState.synced,
        );
      },
    );

    test(
      'user-cancelled BLE work stays visible without automatic resume intent',
      () async {
        const accountScope = 'bluetooth-user-cancelled-projection-account';
        const serialNumber = 'CARD-USER-CANCELLED-001';
        final database = AppDatabase();
        final repository = LocalRecordingRepository(
          database: database,
          fileStorage: const _RecordingCardFileStorage(),
          accountScope: accountScope,
        );
        final ledger = RecordingCardSyncLedgerStore(
          database: database,
          accountScope: accountScope,
        );
        final digest = RecordingCardFileIdentity.digestSerialNumber(
          serialNumber,
        )!;
        final queued = ledger.queueManualSyncForFile(
          cardSnDigest: digest,
          file: _fileWithId(1),
          at: DateTime.utc(2026, 9, 13, 9),
        );
        ledger.saveFileLedgerEntry(
          queued.clearBluetoothResumeRequest(DateTime.utc(2026, 9, 13, 9, 1)),
        );
        final port = _FakeRecordingCardPort(serialNumber: serialNumber);
        final controller = RecordingCardController(
          port: port,
          localRecordingRepository: repository,
          platformPermissionsPort: _FakePlatformPermissionsPort(),
          syncLedgerPersistence: ledger,
          bindingTokenProvider: _bindingToken,
        );
        addTearDown(controller.dispose);
        await controller.restoreWifiBatch();

        expect(controller.pendingBluetoothSyncEntries, hasLength(1));
        expect(controller.hasPendingBluetoothSync, isTrue);
        expect(controller.pendingBluetoothResumeEntries, isEmpty);
        expect(controller.pendingUserBluetoothResumeEntries, isEmpty);
        expect(controller.hasPendingBluetoothResume, isFalse);
        expect(port.connectCallCount, 0);
        expect(port.bleDownloadCallCount, 0);
      },
    );

    test(
      'active Wi-Fi batch excludes a concurrent single-file transfer',
      () async {
        final port = _FakeRecordingCardPort();
        final controller = _controllerFor(port);
        addTearDown(controller.dispose);
        await controller.connect();
        final file = _fileWithId(1);
        await _prepareWifiBatchForTest(
          controller,
          port,
          <RecordingCardScannedFile>[file],
        );

        await controller.downloadFile(file);

        expect(controller.state.lastErrorCode, isNull);
        expect(controller.operationBlockCode, recordingCardOperationBusyCode);
        expect(port.wifiSessionDownloadedKeys, isEmpty);
        expect(
          controller.state.wifiBatch?.state,
          RecordingCardWifiBatchState.awaitingHotspot,
        );
      },
    );

    test(
      'cancelling a Wi-Fi batch preserves summary until dismissed',
      () async {
        final database = AppDatabase();
        final repository = LocalRecordingRepository(
          database: database,
          fileStorage: const _RecordingCardFileStorage(),
          accountScope: 'wifi-cancel-account',
        );
        final ledger = RecordingCardSyncLedgerStore(
          database: database,
          accountScope: 'wifi-cancel-account',
        );
        final port = _FakeRecordingCardPort(serialNumber: 'CARD-CANCEL-001');
        final controller = RecordingCardController(
          port: port,
          localRecordingRepository: repository,
          platformPermissionsPort: _FakePlatformPermissionsPort(),
          syncLedgerPersistence: ledger,
          bindingTokenProvider: _bindingToken,
        );
        addTearDown(controller.dispose);
        await controller.connect();
        await _awaitAutomaticScan(controller, port);
        final scanCount = port.scanFilesCallCount;
        await _prepareWifiBatchForTest(
          controller,
          port,
          <RecordingCardScannedFile>[_fileWithId(1)],
        );

        await controller.cancelWifiBatch();
        expect(
          controller.state.wifiBatch?.state,
          RecordingCardWifiBatchState.cancelled,
        );
        expect(
          controller.state.wifiBatch?.items.single.state,
          RecordingCardWifiBatchItemState.cancelled,
        );
        expect(repository.recordingCardWifiBatchItems(), hasLength(1));
        final digest = RecordingCardFileIdentity.digestSerialNumber(
          port.runtimeSnapshot.deviceState.serialNumber!,
        )!;
        final cancelledLedger = ledger.loadFileLedger(digest).single;
        expect(cancelledLedger.localState, RecordingCardFileLocalState.failed);
        expect(
          cancelledLedger.retryability,
          RecordingCardSyncRetryability.permanent,
        );
        expect(
          cancelledLedger.errorCode,
          'RECORDING_CARD_WIFI_BATCH_STOPPED_BY_USER',
        );
        expect(cancelledLedger.resumeRequested, isFalse);
        expect(port.connectCallCount, 1);
        expect(port.scanFilesCallCount, scanCount + 1);
        expect(controller.hasActiveTransfer, isFalse);
        expect(controller.hasUnresolvedWifiBatch, isTrue);
        expect(controller.hasAutomaticSyncBlockingWifiBatch, isFalse);
        expect(
          ControllerRecordingCardAutoSyncActions(controller).hasActiveTransfer,
          isFalse,
        );

        expect(await controller.dismissWifiBatch(), isTrue);
        expect(controller.state.wifiBatch, isNull);
        expect(repository.recordingCardWifiBatchItems(), isEmpty);
        expect(
          ControllerRecordingCardAutoSyncActions(controller).hasActiveTransfer,
          isFalse,
        );

        final nextPrepared = await _prepareWifiBatchForTest(
          controller,
          port,
          <RecordingCardScannedFile>[_fileWithId(2)],
        );
        expect(nextPrepared.ok, isTrue);
        port.failNextWifiJoin = true;
        final joined = await controller.joinPreparedWifiNetwork(
          nextPrepared.value!,
        );
        expect(joined.ok, isFalse);
        expect(
          controller.state.wifiBatch?.state,
          RecordingCardWifiBatchState.paused,
        );
        final rearmed = await controller.resumeWifiBatch();
        expect(rearmed.ok, isTrue, reason: rearmed.error?.code);
        expect(
          controller.state.wifiBatch?.state,
          RecordingCardWifiBatchState.completed,
        );
      },
    );

    test(
      'cancelling after BLE disconnect performs one bounded recovery',
      () async {
        final port = _FakeRecordingCardPort();
        final controller = _controllerFor(port);
        addTearDown(controller.dispose);
        await controller.connect();
        await _awaitAutomaticScan(controller, port);
        await _prepareWifiBatchForTest(
          controller,
          port,
          <RecordingCardScannedFile>[_fileWithId(1)],
        );
        await port.disconnect();
        final scanCount = port.scanFilesCallCount;

        await controller.cancelWifiBatch();

        expect(port.connectCallCount, 2);
        expect(port.connectRequests.last?.forceScan, isFalse);
        expect(port.scanFilesCallCount, scanCount + 1);
        expect(controller.hasActiveTransfer, isFalse);
        expect(
          controller.state.wifiBatch?.state,
          RecordingCardWifiBatchState.cancelled,
        );
        expect(
          controller.state.snapshot.deviceState.isOperationallyConnected,
          isTrue,
        );
      },
    );

    test('Wi-Fi prepare failure restores the original BLE card', () async {
      final operations = <String>[];
      final port = _FakeRecordingCardPort(
        operationLog: operations,
        serialNumber: 'FW920SN001',
      );
      final controller = _controllerFor(port);
      addTearDown(controller.dispose);
      await controller.connect();
      await _awaitAutomaticScan(controller, port);

      final files = <RecordingCardScannedFile>[_fileWithId(1)];
      port.emitFileDirectory(files);
      await controller.ensureFilesLoadedForCurrentConnection();
      operations.clear();
      port
        ..failNextWifiPrepare = true
        ..disconnectOnNextWifiPrepareFailure = true
        ..failNextWifiCancel = true;

      final first = await controller.prepareWifiBatch(files);
      expect(first.ok, isFalse);
      expect(operations, <String>[
        'prepareWifiSession',
        'cancel',
        'disconnect',
        'connect',
        'refreshDeviceInfo',
        'readRecordingState',
        'scanFiles',
      ]);
      expect(port.connectRequests.last?.forceScan, isFalse);
      expect(
        port.connectRequests.last?.safeDeviceFingerprint,
        'card-fingerprint-1',
      );
      expect(port.connectRequests.last?.expectedSerialNumber, 'FW920SN001');
      expect(
        port.connectRequests.last?.bindingTokenHex,
        '0123456789abcdef0123456789abcdef',
      );
      expect(
        controller.state.snapshot.deviceState.isOperationallyConnected,
        isTrue,
      );
      expect(controller.hasActiveTransfer, isTrue);
      expect(controller.state.hasRunningTransfer, isFalse);
      expect(controller.hasActiveDeviceOperation, isFalse);
      expect(
        controller.state.wifiBatch?.state,
        RecordingCardWifiBatchState.paused,
      );

      final retryOperation = controller.resumeWifiBatch();
      final duplicateRetry = controller.resumeWifiBatch();
      expect(identical(retryOperation, duplicateRetry), isTrue);
      final retried = await retryOperation;
      expect(retried.ok, isTrue, reason: retried.error?.code);
      expect(port.wifiSessionPrepareCallCount, 2);
      expect(
        controller.state.wifiBatch?.state,
        RecordingCardWifiBatchState.completed,
      );
    });

    test(
      'user cancel supersedes a prepare failure waiting for native teardown',
      () async {
        final operations = <String>[];
        final port = _FakeRecordingCardPort(
          operationLog: operations,
          serialNumber: 'FW920SN001',
        );
        final controller = _controllerFor(port);
        addTearDown(controller.dispose);
        await controller.connect();
        await _awaitAutomaticScan(controller, port);
        final files = <RecordingCardScannedFile>[_fileWithId(1)];
        port.emitFileDirectory(files);
        await controller.ensureFilesLoadedForCurrentConnection();
        operations.clear();
        final nativeCancel = Completer<RecordingCardResult<bool>>();
        port
          ..failNextWifiPrepare = true
          ..disconnectOnNextWifiPrepareFailure = true
          ..wifiCancelCompleter = nativeCancel;

        final preparing = controller.prepareWifiBatch(files);
        await _waitFor(() => port.cancelCallCount == 1);
        final cancelling = controller.cancelWifiBatch();
        nativeCancel.complete(RecordingCardResult<bool>.success(true));
        final preparationResult = await preparing;
        await cancelling;

        expect(preparationResult.ok, isFalse);
        expect(port.cancelCallCount, 1);
        expect(
          operations.where((operation) => operation == 'connect'),
          hasLength(1),
        );
        expect(
          controller.state.wifiBatch?.state,
          RecordingCardWifiBatchState.cancelled,
        );
        expect(controller.state.wifiBatch?.stopRequested, isTrue);
        expect(controller.state.lastErrorCode, isNull);
      },
    );

    test(
      'user cancel wins while successful Wi-Fi preparation is being flushed',
      () async {
        for (final flushFailure in <Object?>[
          null,
          StateError('forced obsolete preparation flush failure'),
        ]) {
          final scenario = flushFailure == null ? 'success' : 'failure';
          final accountScope = 'wifi-prepare-flush-cancel-$scenario-account';
          final database = AppDatabase();
          final repository = LocalRecordingRepository(
            database: database,
            fileStorage: const _RecordingCardFileStorage(),
            accountScope: accountScope,
          );
          final ledger = _DeferredFlushRecordingCardLedger(
            RecordingCardSyncLedgerStore(
              database: database,
              accountScope: accountScope,
            ),
          );
          final port = _FakeRecordingCardPort(serialNumber: 'FW920SN001');
          final controller = RecordingCardController(
            port: port,
            localRecordingRepository: repository,
            platformPermissionsPort: _FakePlatformPermissionsPort(),
            syncLedgerPersistence: ledger,
            bindingTokenProvider: _bindingToken,
          );
          addTearDown(controller.dispose);
          await controller.connect();
          await _awaitAutomaticScan(controller, port);
          final files = <RecordingCardScannedFile>[_fileWithId(1)];
          port.emitFileDirectory(files);
          await controller.ensureFilesLoadedForCurrentConnection();
          final nativePrepare =
              Completer<RecordingCardResult<RecordingCardWifiCredentials>>();
          port.wifiPrepareCompleter = nativePrepare;

          final preparing = controller.prepareWifiBatch(files);
          await _waitFor(() => port.wifiSessionPrepareCallCount == 1);
          final flush = ledger.deferNextFlush(failure: flushFailure);
          addTearDown(flush.release);
          nativePrepare.complete(
            RecordingCardResult<RecordingCardWifiCredentials>.success(
              const RecordingCardWifiCredentials(
                ssid: 'FW920_TEST',
                password: '12345678', // secret-scan: allow
              ),
            ),
          );
          await flush.started.future;

          final cancelling = controller.cancelWifiBatch();
          await _waitFor(() => port.cancelCallCount == 1);
          flush.release();
          final preparationResult = await preparing;
          await cancelling;

          expect(preparationResult.ok, isFalse, reason: scenario);
          expect(
            preparationResult.error?.code,
            'RECORDING_CARD_WIFI_PREPARATION_STALE',
            reason: scenario,
          );
          expect(port.wifiSessionOpenCallCount, 0, reason: scenario);
          expect(port.cancelCallCount, 1, reason: scenario);
          expect(
            controller.state.wifiBatch?.state,
            RecordingCardWifiBatchState.cancelled,
            reason: scenario,
          );
          expect(
            controller.state.wifiBatch?.stopRequested,
            isTrue,
            reason: scenario,
          );
          expect(controller.state.lastErrorCode, isNull, reason: scenario);
        }
      },
    );

    test(
      'normal close and user cancel share one attempt teardown escalation',
      () async {
        final operations = <String>[];
        final port = _FakeRecordingCardPort(operationLog: operations);
        final controller = _controllerFor(port);
        addTearDown(controller.dispose);
        await controller.connect();
        await _awaitAutomaticScan(controller, port);
        final queued = await _queueWifiBatchForTest(
          controller,
          port,
          <RecordingCardScannedFile>[_fileWithId(1)],
        );
        expect(queued.ok, isTrue);
        final nativeClose = Completer<RecordingCardResult<bool>>();
        final nativeCancel = Completer<RecordingCardResult<bool>>();
        port
          ..wifiCloseCompleter = nativeClose
          ..wifiCancelCompleter = nativeCancel;

        final running = controller.startQueuedWifiBatch();
        await _waitFor(() => port.wifiSessionCloseCallCount == 1);
        port.emit(
          port.runtimeSnapshot.copyWith(
            deviceState: RecordingCardDeviceState.disconnected(),
          ),
        );
        final attemptId = controller.state.wifiBatch?.attemptId;
        expect(attemptId, isNotNull);
        final connectsBeforeTeardown = operations
            .where((operation) => operation == 'connect')
            .length;
        final cancelling = controller.cancelWifiBatch();
        await _waitFor(
          () =>
              controller.state.operation.phase ==
              RecordingCardOperationPhase.cancelling,
        );
        expect(port.wifiSessionCloseCallCount, 1);
        expect(port.cancelCallCount, 0);

        nativeClose.complete(
          RecordingCardResult<bool>.failure(
            _failure('RECORDING_CARD_WIFI_SESSION_CLOSE_FAILED'),
          ),
        );
        await _waitFor(() => port.cancelCallCount == 1);
        expect(port.wifiSessionCloseCallCount, 1);
        expect(
          operations.where((operation) => operation == 'cancel'),
          hasLength(1),
        );
        expect(
          operations.where((operation) => operation == 'connect'),
          hasLength(connectsBeforeTeardown),
        );

        nativeCancel.complete(RecordingCardResult<bool>.success(true));
        await running;
        await cancelling;

        expect(port.wifiSessionCloseCallCount, 1);
        expect(port.cancelCallCount, 1);
        expect(
          operations.where((operation) => operation == 'connect'),
          hasLength(connectsBeforeTeardown + 1),
        );
        expect(
          controller.state.wifiBatch?.state,
          RecordingCardWifiBatchState.cancelled,
        );
        expect(controller.state.wifiBatch?.stopRequested, isTrue);
      },
    );

    test('Wi-Fi prepare failure releases a deferred foreground read', () async {
      final port = _FakeRecordingCardPort();
      final controller = _controllerFor(port);
      addTearDown(controller.dispose);
      await controller.connect();
      await _awaitAutomaticScan(controller, port);
      final scanCount = port.scanFilesCallCount;
      final queued = await _queueWifiBatchForTest(
        controller,
        port,
        <RecordingCardScannedFile>[_fileWithId(1)],
      );
      expect(queued.ok, isTrue);

      await controller.reconcileConnectionState(refreshDirectory: true);
      port.failNextWifiPrepare = true;
      final prepared = await controller.startQueuedWifiBatch();
      expect(prepared.ok, isFalse);
      await _waitFor(() => port.scanFilesCallCount == scanCount + 1);

      expect(port.scanFilesCallCount, scanCount + 1);
      expect(controller.hasActiveTransfer, isTrue);
      expect(controller.state.hasRunningTransfer, isFalse);
      expect(
        controller.state.wifiBatch?.state,
        RecordingCardWifiBatchState.paused,
      );
    });

    test(
      'paused Wi-Fi batch reconnects BLE before hotspot preparation',
      () async {
        final operations = <String>[];
        final port = _FakeRecordingCardPort(operationLog: operations)
          ..wifiSessionFailuresByDeviceFileId['card-file-1'] =
              'RECORDING_CARD_WIFI_PROTOCOL_INVALID';
        final authorization = _FakeConnectionAuthorization.success();
        final controller = _controllerFor(
          port,
          connectionAuthorization: authorization,
        );
        addTearDown(controller.dispose);
        await controller.connect();
        await _prepareWifiBatchForTest(
          controller,
          port,
          <RecordingCardScannedFile>[_fileWithId(1), _fileWithId(2)],
        );
        await controller.startPreparedWifiBatch();
        expect(
          controller.state.wifiBatch?.state,
          RecordingCardWifiBatchState.paused,
        );
        expect(
          controller.state.wifiBatch?.items.first.state,
          RecordingCardWifiBatchItemState.failed,
        );
        expect(port.connectCallCount, 1);
        expect(port.connectRequests.last?.forceScan, isFalse);

        await port.disconnect();
        port.wifiSessionFailuresByDeviceFileId.clear();
        operations.clear();
        final resumed = await controller.resumeWifiBatch();

        expect(resumed.ok, isTrue, reason: resumed.error?.code);
        expect(operations.take(2), <String>['connect', 'prepareWifiSession']);
        expect(port.connectCallCount, 2);
        expect(authorization.callCount, 2);
        expect(
          port.connectRequests.last?.safeDeviceFingerprint,
          'card-fingerprint-1',
        );
        expect(
          port.connectRequests.last?.bindingTokenHex,
          '0123456789abcdef0123456789abcdef',
        );
        expect(
          controller.state.wifiBatch?.state,
          RecordingCardWifiBatchState.completed,
        );
        expect(
          controller.state.wifiBatch?.items
              .where(
                (item) => item.state == RecordingCardWifiBatchItemState.queued,
              )
              .length,
          0,
        );
      },
    );

    test(
      'failed BLE reconnect preserves paused Wi-Fi batch item states',
      () async {
        final operations = <String>[];
        final port = _FakeRecordingCardPort(operationLog: operations)
          ..wifiSessionFailuresByDeviceFileId['card-file-1'] =
              'RECORDING_CARD_WIFI_PROTOCOL_INVALID';
        final controller = _controllerFor(port);
        addTearDown(controller.dispose);
        await controller.connect();
        await _prepareWifiBatchForTest(
          controller,
          port,
          <RecordingCardScannedFile>[_fileWithId(1), _fileWithId(2)],
        );
        await controller.startPreparedWifiBatch();
        await port.disconnect();
        final before = controller.state.wifiBatch!;
        final beforeStates = before.items
            .map((item) => (state: item.state, error: item.errorCode))
            .toList(growable: false);
        final prepareCallsBefore = port.wifiSessionPrepareCallCount;
        port.failNextConnect = true;
        operations.clear();

        final resumed = await controller.resumeWifiBatch();

        expect(resumed.ok, isFalse);
        expect(resumed.error?.code, 'RECORDING_CARD_CONNECTION_FAILED');
        expect(resumed.error?.isRetryable, isTrue);
        expect(operations, <String>['connect']);
        expect(port.wifiSessionPrepareCallCount, prepareCallsBefore);
        expect(
          controller.state.wifiBatch?.state,
          RecordingCardWifiBatchState.paused,
        );
        expect(
          controller.state.wifiBatch?.items
              .map((item) => (state: item.state, error: item.errorCode))
              .toList(growable: false),
          beforeStates,
        );
      },
    );

    test(
      'request rejection continues but protocol failure pauses the batch',
      () async {
        final requestPort = _FakeRecordingCardPort()
          ..wifiSessionFailuresByDeviceFileId['card-file-1'] =
              'RECORDING_CARD_WIFI_REQUEST_REJECTED';
        final requestController = _controllerFor(requestPort);
        addTearDown(requestController.dispose);
        await requestController.connect();
        await _prepareWifiBatchForTest(
          requestController,
          requestPort,
          <RecordingCardScannedFile>[_fileWithId(1), _fileWithId(2)],
        );
        await requestController.startPreparedWifiBatch();
        expect(requestPort.wifiSessionDownloadedKeys, <String>[
          'card-file-1',
          'card-file-2',
        ]);
        final failedBatchId = requestController.state.wifiBatch?.batchId;
        expect(
          requestController.state.wifiBatch?.state,
          RecordingCardWifiBatchState.failed,
        );
        expect(requestController.state.wifiBatch?.completedCount, 1);
        expect(requestController.state.wifiBatch?.failedCount, 1);
        expect(
          requestController.state.wifiBatch?.failureCode,
          'RECORDING_CARD_WIFI_REQUEST_REJECTED',
        );

        requestPort.wifiSessionFailuresByDeviceFileId.clear();
        final retried = await requestController.retryFailedWifiBatch();
        expect(retried.ok, isTrue, reason: retried.error?.code);
        expect(
          requestController.state.wifiBatch?.state,
          RecordingCardWifiBatchState.completed,
        );
        expect(requestController.state.wifiBatch?.batchId, failedBatchId);
        expect(requestController.state.wifiBatch?.completedCount, 2);
        expect(requestController.state.wifiBatch?.failedCount, 0);
        expect(
          requestController.state.wifiBatch?.state,
          RecordingCardWifiBatchState.completed,
        );
        expect(requestPort.wifiSessionDownloadedKeys, <String>[
          'card-file-1',
          'card-file-2',
          'card-file-1',
        ]);

        final protocolPort = _FakeRecordingCardPort()
          ..wifiSessionFailuresByDeviceFileId['card-file-1'] =
              'RECORDING_CARD_WIFI_PROTOCOL_INVALID';
        final protocolController = _controllerFor(protocolPort);
        addTearDown(protocolController.dispose);
        await protocolController.connect();
        await _prepareWifiBatchForTest(
          protocolController,
          protocolPort,
          <RecordingCardScannedFile>[_fileWithId(1), _fileWithId(2)],
        );
        await protocolController.startPreparedWifiBatch();
        expect(protocolPort.wifiSessionDownloadedKeys, <String>['card-file-1']);
        expect(
          protocolController.state.wifiBatch?.state,
          RecordingCardWifiBatchState.paused,
        );
        expect(
          protocolController.state.lastErrorCode,
          'RECORDING_CARD_WIFI_PROTOCOL_INVALID',
        );
      },
    );

    test(
      'registers a completed download while fingerprint is delayed',
      () async {
        final port = _FakeRecordingCardPort();
        final repository = _repository();
        final controller = RecordingCardController(
          port: port,
          localRecordingRepository: repository,
          platformPermissionsPort: _FakePlatformPermissionsPort(),
          bindingTokenProvider: _bindingToken,
        );
        addTearDown(controller.dispose);
        await controller.connect();
        port.emit(
          port.runtimeSnapshot.copyWith(
            deviceState: const RecordingCardDeviceState(
              connectionState: RecordingCardConnectionState.connected,
              connectionStage: RecordingCardConnectionStage.connected,
              displayName: 'Huahuo FW920',
              recordingFormat: RecordingCardFileFormat.m4a,
            ),
          ),
        );
        await controller.scanFiles();

        await controller.downloadFile(controller.state.snapshot.files.single);

        expect(controller.state.lastErrorCode, isNull);
        expect(repository.list().rows, hasLength(1));
        expect(
          repository.list().rows.single.source,
          RecordingLibrarySource.device,
        );
      },
    );

    test(
      'Wi-Fi recovery observes healthy session and rebuilds lost session once',
      () async {
        final port = _RecoveryRecordingCardPort()..holdReply = true;
        final controller = _controllerFor(port);
        addTearDown(controller.dispose);
        await controller.connect();
        await _queueWifiBatchForTest(controller, port, [_fileWithId(1)]);
        final running = controller.startQueuedWifiBatch();
        expect(identical(running, controller.resumeWifiBatch()), isTrue);
        await _waitFor(() => port.targets.isNotEmpty);
        final firstAttempt = controller.state.wifiBatch!.attemptId!;
        await controller.reconcileWifiBatch();
        expect(port.beginCount, 1);
        expect(controller.state.wifiBatch!.isBusy, isTrue);
        port.sessionActive = false;
        await controller.reconcileWifiBatch();
        expect((await running).ok, isFalse);
        expect(controller.state.wifiBatch!.canContinue, isTrue);
        expect(controller.state.hasRunningTransfer, isFalse);
        port.holdReply = false;
        final resumed = await controller.resumeWifiBatch();
        expect(resumed.ok, isTrue, reason: resumed.error?.code);
        expect(port.beginCount, 2);
        expect(port.wifiSessionPrepareCallCount, 2);
        expect(port.wifiJoinCallCount, 2);
        expect(port.targets, hasLength(2));
        expect(port.targets.toSet(), hasLength(1));
        port.emitInterruption(firstAttempt);
        await Future<void>.delayed(Duration.zero);
        expect(
          controller.state.wifiBatch!.state,
          RecordingCardWifiBatchState.completed,
        );
      },
    );

    test(
      'Wi-Fi query reconciles an active scoped failure after a missed event',
      () async {
        final port = _RecoveryRecordingCardPort()..holdReply = true;
        final controller = _controllerFor(port);
        addTearDown(controller.dispose);
        await controller.connect();
        await _queueWifiBatchForTest(controller, port, [_fileWithId(1)]);
        final running = controller.startQueuedWifiBatch();
        await _waitFor(() => port.targets.isNotEmpty);
        final attemptId = controller.state.wifiBatch!.attemptId;
        port.sessionFailureCode = 'RECORDING_CARD_WIFI_NETWORK_LOST';

        await controller.reconcileWifiBatch();
        final result = await running;

        expect(port.queryCount, 1);
        expect(port.beginCount, 1);
        expect(result.ok, isFalse);
        expect(controller.state.wifiBatch?.attemptId, attemptId);
        expect(
          controller.state.wifiBatch?.state,
          RecordingCardWifiBatchState.paused,
        );
        expect(
          controller.state.wifiBatch?.failureCode,
          'RECORDING_CARD_WIFI_NETWORK_LOST',
        );
        expect(
          controller.state.lastErrorCode,
          'RECORDING_CARD_WIFI_NETWORK_LOST',
        );
      },
    );

    for (final stopBeforeRestart in [false, true]) {
      test(
        'Wi-Fi recovery finds atomic file before callback; stopped=$stopBeforeRestart',
        () async {
          final database = AppDatabase();
          final repository = LocalRecordingRepository(
            database: database,
            fileStorage: const _RecordingCardFileStorage(),
            accountScope: 'wifi-recovery',
          );
          final ledger = RecordingCardSyncLedgerStore(
            database: database,
            accountScope: 'wifi-recovery',
          );
          final port = _RecoveryRecordingCardPort()
            ..holdReply = true
            ..commitBeforeReply = true;
          final first = RecordingCardController(
            port: port,
            localRecordingRepository: repository,
            platformPermissionsPort: _FakePlatformPermissionsPort(),
            syncLedgerPersistence: ledger,
            bindingTokenProvider: _bindingToken,
          );
          await first.connect();
          await _queueWifiBatchForTest(first, port, [
            _fileWithId(1),
            _fileWithId(2),
          ]);
          final running = first.startQueuedWifiBatch();
          await _waitFor(() => port.targets.isNotEmpty);
          final records = repository.recordingCardWifiBatchItems();
          final intent = records.firstWhere(
            (row) => row['planned_native_file_id'] != null,
          );
          expect(intent['planned_native_file_id'], port.targets.single);
          expect(intent['attempt_id'], first.state.wifiBatch!.attemptId);
          expect(intent['staged_native_file_id'], isNull);
          if (stopBeforeRestart) await first.cancelWifiBatch();
          first.dispose();
          await running;
          final restored = RecordingCardController(
            port: port,
            localRecordingRepository: repository,
            platformPermissionsPort: _FakePlatformPermissionsPort(),
            syncLedgerPersistence: ledger,
            bindingTokenProvider: _bindingToken,
          );
          addTearDown(restored.dispose);
          await restored.restoreWifiBatch();
          expect(
            repository.list().rows,
            hasLength(1),
            reason: restored.state.wifiBatch!.failureCode,
          );
          expect(restored.state.wifiBatch!.completedCount, 1);
          expect(restored.state.wifiBatch!.stopRequested, stopBeforeRestart);
          if (stopBeforeRestart) {
            expect(
              restored.state.wifiBatch!.state,
              RecordingCardWifiBatchState.cancelled,
            );
            expect((await restored.resumeWifiBatch()).ok, isFalse);
            expect(port.targets, hasLength(1));
          } else {
            port.holdReply = false;
            final resumed = await restored.resumePendingBluetoothTransfers();
            expect(resumed.ok, isTrue, reason: resumed.error?.code);
            expect(port.targets, hasLength(1));
            expect(port.bleDownloadedKeys, contains('card-file-2'));
            expect(repository.list().rows, hasLength(2));
          }
        },
      );
    }

    test(
      'Wi-Fi recovery with corrupt identity blocks resume but permits durable finish',
      () async {
        final database = AppDatabase();
        final repository = LocalRecordingRepository(
          database: database,
          fileStorage: const _RecordingCardFileStorage(),
          accountScope: 'wifi-corrupt',
        );
        final port = _RecoveryRecordingCardPort();
        final first = RecordingCardController(
          port: port,
          localRecordingRepository: repository,
          platformPermissionsPort: _FakePlatformPermissionsPort(),
          bindingTokenProvider: _bindingToken,
        );
        await first.connect();
        await _queueWifiBatchForTest(first, port, [_fileWithId(1)]);
        final row = repository.recordingCardWifiBatchItems().single;
        final encodedScope = base64Url
            .encode(utf8.encode('wifi-corrupt'))
            .replaceAll('=', '');
        final encodedId = base64Url
            .encode(utf8.encode(row['transfer_id']! as String))
            .replaceAll('=', '');
        database.upsertRecord(
          LocalTableName.localTransferRecords,
          'recording:$encodedScope:local_transfer_records:$encodedId',
          {...row, 'device_identity': ''},
        );
        first.dispose();
        final restored = RecordingCardController(
          port: port,
          localRecordingRepository: repository,
          platformPermissionsPort: _FakePlatformPermissionsPort(),
          bindingTokenProvider: _bindingToken,
        );
        addTearDown(restored.dispose);
        await restored.restoreWifiBatch();
        expect(restored.state.wifiBatch!.canContinue, isFalse);
        expect(restored.state.wifiBatch!.canFinish, isTrue);
        await restored.cancelWifiBatch();
        expect(
          restored.state.wifiBatch!.state,
          RecordingCardWifiBatchState.cancelled,
        );
        expect(
          repository.recordingCardWifiBatchItems().single['stop_requested'],
          isTrue,
        );
        expect(port.beginCount, 0);
      },
    );

    test(
      'unavailable driver does not create synthetic connected state or files',
      () async {
        final controller = _controllerFor(const UnavailableRecordingCardPort());
        addTearDown(controller.dispose);

        await controller.connect();

        expect(controller.state.status, RecordingCardControllerStatus.error);
        expect(
          controller.state.lastErrorCode,
          'NATIVE_RECORDING_CARD_DRIVER_UNAVAILABLE',
        );
        expect(
          controller.state.snapshot.deviceState.connectionState,
          isNot(RecordingCardConnectionState.connected),
        );
        expect(controller.state.snapshot.files, isEmpty);
      },
    );
  });
}

({
  AppDatabase database,
  LocalRecordingRepository repository,
  RecordingCardSyncLedgerStore ledger,
  String deviceFingerprint,
})
_persistLegacyFingerprintWifiBatch({
  required String accountScope,
  required String batchId,
}) {
  const deviceFingerprint = 'card-fingerprint-1';
  final database = AppDatabase();
  final repository = LocalRecordingRepository(
    database: database,
    fileStorage: const _RecordingCardFileStorage(),
    accountScope: accountScope,
  );
  final ledger = RecordingCardSyncLedgerStore(
    database: database,
    accountScope: accountScope,
  );
  final file = _fileWithId(1);
  final createdAt = DateTime.utc(2026, 9, 5, 9);
  repository.upsertRecordingCardWifiBatchItem(
    transferId: 'wifi-${sha256.convert(utf8.encode('$batchId:0')).toString()}',
    batchId: batchId,
    deviceFingerprint: deviceFingerprint,
    deviceIdentity: deviceFingerprint,
    deviceFileId: file.deviceFileId,
    deviceFilename: file.deviceFilename,
    localFileKey: file.localFileKey,
    itemOrder: 0,
    expectedSizeBytes: file.sizeBytes!,
    attemptCount: 0,
    batchStage: RecordingCardWifiBatchState.paused.name,
    stage: RecordingCardWifiBatchItemState.queued.name,
    idempotencyKey: sha256
        .convert(
          utf8.encode('$deviceFingerprint:${file.deviceFileId}:$batchId'),
        )
        .toString(),
    createdAt: createdAt,
    updatedAt: createdAt,
    fileFormat: file.format.name,
    mimeType: file.mimeType,
  );
  return (
    database: database,
    repository: repository,
    ledger: ledger,
    deviceFingerprint: deviceFingerprint,
  );
}

Future<
  ({
    LocalRecordingRepository repository,
    RecordingCardSyncLedgerStore ledger,
    RecordingCardScannedFile file,
    String cardDigest,
  })
>
_persistColdWifiHandoffFixture({
  required String accountScope,
  required String serialNumber,
}) async {
  final database = AppDatabase();
  final repository = LocalRecordingRepository(
    database: database,
    fileStorage: const _RecordingCardFileStorage(),
    accountScope: accountScope,
  );
  final ledger = RecordingCardSyncLedgerStore(
    database: database,
    accountScope: accountScope,
  );
  final file = _fileWithId(1);
  final port = _FakeRecordingCardPort(
    serialNumber: serialNumber,
    scannedFile: file,
  );
  final controller = RecordingCardController(
    port: port,
    localRecordingRepository: repository,
    platformPermissionsPort: _FakePlatformPermissionsPort(),
    syncLedgerPersistence: ledger,
    bindingTokenProvider: _bindingToken,
  );
  try {
    await controller.connect();
    await _awaitAutomaticScan(controller, port);
    final queued = await _queueWifiBatchForTest(
      controller,
      port,
      <RecordingCardScannedFile>[file],
    );
    expect(queued.ok, isTrue, reason: queued.error?.code);
  } finally {
    controller.dispose();
  }
  return (
    repository: repository,
    ledger: ledger,
    file: file,
    cardDigest: RecordingCardFileIdentity.digestSerialNumber(serialNumber)!,
  );
}

({
  LocalRecordingRepository repository,
  RecordingCardSyncLedgerStore ledger,
  List<RecordingCardScannedFile> files,
  List<RecordingCardDownloadedFile> downloads,
})
_persistUnknownFormatWifiBatch({
  required String accountScope,
  required String serialNumber,
  required int fileCount,
  required int stagedCount,
  required bool stopRequested,
}) {
  final database = AppDatabase();
  final repository = LocalRecordingRepository(
    database: database,
    fileStorage: const _RecordingCardFileStorage(),
    accountScope: accountScope,
  );
  final ledger = RecordingCardSyncLedgerStore(
    database: database,
    accountScope: accountScope,
  );
  final cardDigest = RecordingCardFileIdentity.digestSerialNumber(
    serialNumber,
  )!;
  final normalizedSerial = normalizeRecordingCardSerialNumberForOwnership(
    serialNumber,
  )!;
  final createdAt = DateTime.utc(2026, 9, 16, 15, 33);
  final files = <RecordingCardScannedFile>[];
  final downloads = <RecordingCardDownloadedFile>[];
  for (var index = 0; index < fileCount; index += 1) {
    final filename = '2026090212${index.toString().padLeft(4, '0')}';
    final file = RecordingCardScannedFile(
      deviceFileId: 'card-$filename',
      localFileKey: 'card-$filename',
      deviceFilename: filename,
      sizeBytes: 4096,
      sizeConfidence: RecordingCardFileSizeConfidence.trusted,
    );
    final digest = sha256
        .convert(utf8.encode('$accountScope:$index'))
        .toString();
    final nativeFileId = 'card-${digest.substring(0, 32)}';
    final privateUri = 'app-private://recording-card/$nativeFileId.mp3';
    final contentHash = sha256.convert(utf8.encode(privateUri)).toString();
    final staged = index < stagedCount;
    final entry = ledger.queueManualSyncForFile(
      cardSnDigest: cardDigest,
      file: file,
      at: createdAt,
    );
    if (stopRequested && !staged) {
      final failed = ledger.failManualSync(
        cardSnDigest: cardDigest,
        sourceSignature: entry.sourceSignature,
        errorCode: 'RECORDING_CARD_WIFI_BATCH_STOPPED_BY_USER',
        retryability: RecordingCardSyncRetryability.permanent,
        at: createdAt,
      );
      ledger.saveFileLedgerEntry(failed.clearBluetoothResumeRequest(createdAt));
    }
    repository.upsertRecordingCardWifiBatchItem(
      transferId:
          'wifi-${sha256.convert(utf8.encode('wifi-$accountScope:$index'))}',
      batchId: 'wifi-$accountScope',
      deviceFingerprint: 'card-fingerprint-1',
      deviceIdentity: 'serial:$normalizedSerial',
      cardSnDigest: cardDigest,
      ledgerSourceSignature: entry.sourceSignature,
      deviceFileId: file.deviceFileId,
      deviceFilename: filename,
      localFileKey: file.localFileKey,
      itemOrder: index,
      expectedSizeBytes: 4096,
      attemptCount: staged ? 1 : 0,
      batchStage: 'registering',
      stage: staged ? 'verifying' : 'queued',
      batchErrorCode: 'RECORDING_CARD_WIFI_TARGET_INVALID',
      idempotencyKey: sha256
          .convert(
            utf8.encode(
              'serial:$normalizedSerial:${file.deviceFileId}:wifi-$accountScope',
            ),
          )
          .toString(),
      createdAt: createdAt,
      updatedAt: createdAt,
      fileFormat: 'unknown',
      sourceSizeConfidence: 'trusted',
      plannedNativeFileId: nativeFileId,
      stopRequested: stopRequested,
      stagedNativeFileId: staged ? nativeFileId : null,
      stagedFileFormat: staged ? 'mp3' : null,
      stagedSizeBytes: staged ? 4096 : null,
      stagedContentHash: staged ? contentHash : null,
    );
    files.add(file);
    downloads.add(
      RecordingCardDownloadedFile(
        localFileKey: file.localFileKey,
        localFileId: nativeFileId,
        appPrivateUri: privateUri,
        displayName: '$filename.mp3',
        sizeBytes: 4096,
        contentHash: contentHash,
        format: RecordingCardFileFormat.mp3,
        mimeType: 'audio/mpeg',
      ),
    );
  }
  return (
    repository: repository,
    ledger: ledger,
    files: files,
    downloads: downloads,
  );
}

final class _PersistedCompletedWifiBatch {
  const _PersistedCompletedWifiBatch({
    required this.database,
    required this.repository,
    required this.ledger,
    required this.accountScope,
    required this.serialNumber,
    required this.cardDigest,
    required this.localRecordingId,
  });

  final AppDatabase database;
  final LocalRecordingRepository repository;
  final RecordingCardSyncLedgerStore ledger;
  final String accountScope;
  final String serialNumber;
  final String cardDigest;
  final String localRecordingId;
}

Future<_PersistedCompletedWifiBatch> _persistCompletedWifiBatch({
  required String accountScope,
  required String serialNumber,
  FileStoragePort fileStorage = const _RecordingCardFileStorage(),
}) async {
  final database = AppDatabase();
  final repository = LocalRecordingRepository(
    database: database,
    fileStorage: fileStorage,
    accountScope: accountScope,
  );
  final ledger = RecordingCardSyncLedgerStore(
    database: database,
    accountScope: accountScope,
  );
  final port = _FakeRecordingCardPort(serialNumber: serialNumber);
  final controller = RecordingCardController(
    port: port,
    localRecordingRepository: repository,
    platformPermissionsPort: _FakePlatformPermissionsPort(),
    syncLedgerPersistence: ledger,
    bindingTokenProvider: _bindingToken,
  );
  await controller.connect();
  await _awaitAutomaticScan(controller, port);
  final prepared = await _prepareWifiBatchForTest(
    controller,
    port,
    <RecordingCardScannedFile>[_fileWithId(1)],
  );
  expect(prepared.ok, isTrue, reason: prepared.error?.code);
  await controller.startPreparedWifiBatch();
  expect(
    controller.state.wifiBatch?.state,
    RecordingCardWifiBatchState.completed,
  );
  final localRecordingId = repository.list().rows.single.recordingId;
  final cardDigest = RecordingCardFileIdentity.digestSerialNumber(
    serialNumber,
  )!;
  controller.dispose();
  return _PersistedCompletedWifiBatch(
    database: database,
    repository: repository,
    ledger: ledger,
    accountScope: accountScope,
    serialNumber: serialNumber,
    cardDigest: cardDigest,
    localRecordingId: localRecordingId,
  );
}

Future<void> _awaitAutomaticScan(
  RecordingCardController controller,
  _FakeRecordingCardPort port, {
  int minimumCalls = 1,
}) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    await Future<void>.delayed(Duration.zero);
    if (port.scanFilesCallCount >= minimumCalls &&
        controller.state.status != RecordingCardControllerStatus.scanning) {
      return;
    }
  }
  fail(
    'automatic recording-card scan did not settle '
    '(calls=${port.scanFilesCallCount}, status=${controller.state.status})',
  );
}

Future<void> _waitFor(bool Function() condition) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (condition()) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('condition did not become true');
}

RecordingCardController _controllerFor(
  RecordingCardPort port, {
  PlatformPermissionsPort? platformPermissionsPort,
  RecordingCardConnectionAuthorizationPort? connectionAuthorization,
  RecordingCardConnectionHistoryPort? connectionHistory,
  bool Function()? requiresBluetoothPermissionRequest,
  bool Function()? requiresWifiPermissionRequest,
  DateTime Function()? clock,
}) {
  return RecordingCardController(
    port: port,
    localRecordingRepository: _repository(),
    platformPermissionsPort:
        platformPermissionsPort ?? _FakePlatformPermissionsPort(),
    bindingTokenProvider: _bindingToken,
    connectionAuthorization: connectionAuthorization,
    connectionHistory: connectionHistory,
    requiresBluetoothPermissionRequest: requiresBluetoothPermissionRequest,
    requiresWifiPermissionRequest: requiresWifiPermissionRequest,
    clock: clock,
  );
}

Future<String> _bindingToken() async => '0123456789abcdef0123456789abcdef';

Future<RecordingCardResult<RecordingCardWifiBatchSnapshot>>
_queueWifiBatchForTest(
  RecordingCardController controller,
  _FakeRecordingCardPort port,
  List<RecordingCardScannedFile> files,
) async {
  port.emitFileDirectory(files);
  await controller.ensureFilesLoadedForCurrentConnection();
  if (!_sameTestFileDirectory(controller.state.snapshot.files, files)) {
    await controller.scanFiles();
  }
  return controller.queueWifiBatch(files);
}

Future<RecordingCardResult<RecordingCardWifiCredentials>>
_prepareWifiBatchForTest(
  RecordingCardController controller,
  _FakeRecordingCardPort port,
  List<RecordingCardScannedFile> files,
) async {
  port.emitFileDirectory(files);
  await controller.ensureFilesLoadedForCurrentConnection();
  if (!_sameTestFileDirectory(controller.state.snapshot.files, files)) {
    await controller.scanFiles();
  }
  return controller.prepareWifiBatch(files);
}

bool _sameTestFileDirectory(
  List<RecordingCardScannedFile> actual,
  List<RecordingCardScannedFile> expected,
) {
  if (actual.length != expected.length) return false;
  final signatures = actual
      .map(
        (file) => (
          file.deviceFileId,
          file.localFileKey,
          file.deviceFilename,
          file.sizeBytes,
          file.contentHash,
        ),
      )
      .toSet();
  return expected.every(
    (file) => signatures.contains((
      file.deviceFileId,
      file.localFileKey,
      file.deviceFilename,
      file.sizeBytes,
      file.contentHash,
    )),
  );
}

LocalRecordingRepository _repository({List<String>? operationLog}) {
  return LocalRecordingRepository(
    database: AppDatabase(),
    fileStorage: _RecordingCardFileStorage(operationLog: operationLog),
  );
}

final class _FakeRecordingCardPort
    implements
        RecordingCardPort,
        RecordingCardDiscoveryCancellationPort,
        RecordingCardWifiTransferPort,
        RecordingCardWifiJoinPort,
        RecordingCardWifiSessionPort,
        RecordingCardWifiRecoverySettlementPort,
        RecordingCardCancelableTransferPort,
        RecordingCardUnbindPort,
        RecordingCardBluetoothNamePort,
        RecordingCardAccountClaimPort {
  _FakeRecordingCardPort({
    List<String>? operationLog,
    RecordingCardScannedFile? scannedFile,
    this.downloadedSizeBytes,
    this.downloadedContentHash,
    this.wifiSessionFiles,
    this.serialNumber,
    this.safeDeviceFingerprint = 'card-fingerprint-1',
  }) : scannedFile = scannedFile ?? _file(),
       _operationLog = operationLog,
       _snapshot = RecordingCardRuntimeSnapshot(
         deviceState: RecordingCardDeviceState.disconnected(),
         recordingInfo: RecordingCardRecordingInfo.idle(),
         files: const <RecordingCardScannedFile>[],
         discoveredDevices: const <RecordingCardDiscoveredDevice>[],
       ) {
    _directoryFiles = <RecordingCardScannedFile>[this.scannedFile];
  }

  final Set<RecordingCardRuntimeSnapshotListener> _listeners =
      <RecordingCardRuntimeSnapshotListener>{};
  final List<String>? _operationLog;
  final RecordingCardScannedFile scannedFile;
  late List<RecordingCardScannedFile> _directoryFiles;
  final Set<String> _deletedDeviceFileIds = <String>{};
  final int? downloadedSizeBytes;
  final String? downloadedContentHash;
  final List<RecordingCardScannedFile>? wifiSessionFiles;
  final String? serialNumber;
  final String safeDeviceFingerprint;
  RecordingCardRuntimeSnapshot _snapshot;
  var connectCallCount = 0;
  var getConnectionStateCallCount = 0;
  var disconnectCallCount = 0;
  final connectRequests = <RecordingCardConnectRequest?>[];
  var scanDevicesCallCount = 0;
  var discoveryCancellationCallCount = 0;
  var scanFilesCallCount = 0;
  var refreshDeviceInfoCallCount = 0;
  var readRecordingStateCallCount = 0;
  var startRecordingCallCount = 0;
  var unbindCallCount = 0;
  var bluetoothNameCallCount = 0;
  var accountClaimCallCount = 0;
  String? unbindBindingToken;
  var unbindDeleteDeviceFiles = false;
  final bluetoothNames = <String>[];
  var wifiDownloadCallCount = 0;
  var cancelCallCount = 0;
  Completer<RecordingCardResult<bool>>? cancelCompleter;
  var wifiSessionPrepareCallCount = 0;
  var wifiJoinCallCount = 0;
  var wifiHandoffVerifyCallCount = 0;
  var failNextWifiJoin = false;
  Completer<RecordingCardResult<bool>>? wifiJoinCompleter;
  var wifiSessionOpenCallCount = 0;
  var wifiSessionCloseCallCount = 0;
  RecordingCardWifiBatchState? Function()? wifiBatchStateReader;
  final wifiRecoverySettlements =
      <
        ({
          String batchId,
          String attemptId,
          String safeDeviceFingerprint,
          RecordingCardWifiBatchState? batchState,
        })
      >[];
  var bleDownloadCallCount = 0;
  var deleteFileCallCount = 0;
  List<RecordingCardDiscoveredDevice> discoveredDevices =
      const <RecordingCardDiscoveredDevice>[
        RecordingCardDiscoveredDevice(
          displayName: 'Huahuo FW920',
          safeDeviceFingerprint: 'card-fingerprint-1',
          rssi: -42,
          isConnectable: true,
        ),
      ];
  final wifiSessionDownloadedKeys = <String>[];
  final wifiSessionFailuresByDeviceFileId = <String, String>{};
  final wifiSessionDownloadCompletersByDeviceFileId =
      <String, Completer<RecordingCardResult<RecordingCardDownloadedFile>>>{};
  final bleDownloadedKeys = <String>[];
  final bleDownloadCompletersByDeviceFileId =
      <String, Completer<RecordingCardResult<RecordingCardDownloadedFile>>>{};
  final bleDownloadExceptionsByDeviceFileId = <String, Object>{};
  var failNextWifiPrepare = false;
  var disconnectOnNextWifiPrepareFailure = false;
  var disconnectOnNextWifiPrepareSuccess = false;
  Completer<RecordingCardResult<RecordingCardWifiCredentials>>?
  wifiPrepareCompleter;
  var failNextWifiClose = false;
  Completer<RecordingCardResult<bool>>? wifiCloseCompleter;
  var failNextWifiCancel = false;
  var failNextDisconnect = false;
  Completer<RecordingCardResult<bool>>? wifiCancelCompleter;
  var cancelLeavesDownloadFuturePending = false;
  var failNextScan = false;
  var failNextConnect = false;
  var failNextUnbind = false;
  var failNextBluetoothName = false;
  var emitRefreshDeviceInfoResult = false;
  var emitScanFilesResult = true;
  Completer<RecordingCardResult<List<RecordingCardScannedFile>>>?
  scanFilesCompleter;
  Completer<RecordingCardResult<RecordingCardDeviceState>>? disconnectCompleter;
  Completer<RecordingCardResult<RecordingCardDeviceState>>? connectCompleter;
  Completer<RecordingCardResult<RecordingCardDeviceState>>?
  getConnectionStateCompleter;
  Completer<RecordingCardResult<RecordingCardRuntimeSnapshot>>?
  refreshDeviceInfoCompleter;
  Completer<RecordingCardResult<RecordingCardRecordingInfo>>?
  readRecordingStateCompleter;
  Completer<RecordingCardResult<RecordingCardDownloadedFile>>?
  bleDownloadCompleter;
  Completer<RecordingCardResult<RecordingCardDeleteResult>>?
  deleteFileCompleter;
  Completer<RecordingCardResult<List<RecordingCardDiscoveredDevice>>>?
  scanDevicesCompleter;
  Completer<RecordingCardResult<bool>>? discoveryCancellationCompleter;

  @override
  RecordingCardRuntimeSnapshot get runtimeSnapshot => _snapshot;

  void emit(RecordingCardRuntimeSnapshot snapshot) {
    _snapshot = snapshot;
    for (final listener in List<RecordingCardRuntimeSnapshotListener>.of(
      _listeners,
    )) {
      listener(_snapshot);
    }
  }

  void emitFileDirectory(List<RecordingCardScannedFile> files) {
    _directoryFiles = List<RecordingCardScannedFile>.unmodifiable(files);
    emit(_snapshot.copyWith(files: _directoryFiles));
  }

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
    connectCallCount += 1;
    connectRequests.add(request);
    _operationLog?.add('connect');
    if (failNextConnect) {
      failNextConnect = false;
      return RecordingCardResult<RecordingCardDeviceState>.failure(
        _failure('RECORDING_CARD_CONNECTION_FAILED'),
      );
    }
    final deferred = connectCompleter;
    if (deferred != null) return deferred.future;
    final deviceState = RecordingCardDeviceState(
      connectionState: RecordingCardConnectionState.connected,
      connectionStage: RecordingCardConnectionStage.connected,
      displayName: 'Huahuo FW920',
      safeDeviceFingerprint: safeDeviceFingerprint,
      serialNumber: serialNumber,
      recordingFormat: RecordingCardFileFormat.m4a,
    );
    emit(_snapshot.copyWith(deviceState: deviceState));
    return RecordingCardResult<RecordingCardDeviceState>.success(deviceState);
  }

  @override
  Future<RecordingCardResult<RecordingCardDeviceState>>
  getConnectionState() async {
    getConnectionStateCallCount += 1;
    final deferred = getConnectionStateCompleter;
    if (deferred != null) return deferred.future;
    return RecordingCardResult<RecordingCardDeviceState>.success(
      _snapshot.deviceState,
    );
  }

  @override
  Future<RecordingCardResult<List<RecordingCardDiscoveredDevice>>>
  scanDevices() async {
    scanDevicesCallCount += 1;
    _operationLog?.add('scan');
    final deferred = scanDevicesCompleter;
    if (deferred != null) return deferred.future;
    final devices = discoveredDevices;
    emit(_snapshot.copyWith(discoveredDevices: devices));
    return RecordingCardResult<List<RecordingCardDiscoveredDevice>>.success(
      devices,
    );
  }

  @override
  Future<RecordingCardResult<bool>> cancelDiscovery() async {
    discoveryCancellationCallCount += 1;
    _operationLog?.add('cancelDiscovery');
    final deferred = discoveryCancellationCompleter;
    final result = deferred == null
        ? RecordingCardResult<bool>.success(true)
        : await deferred.future;
    if (result.ok && result.value == true) {
      final pendingScan = scanDevicesCompleter;
      if (pendingScan != null && !pendingScan.isCompleted) {
        scanDevicesCompleter = null;
        pendingScan.complete(
          RecordingCardResult<List<RecordingCardDiscoveredDevice>>.failure(
            _failure('RECORDING_CARD_SCAN_CANCELLED'),
          ),
        );
      }
    }
    return result;
  }

  @override
  Future<RecordingCardResult<RecordingCardRuntimeSnapshot>>
  refreshDeviceInfo() async {
    refreshDeviceInfoCallCount += 1;
    _operationLog?.add('refreshDeviceInfo');
    final deferred = refreshDeviceInfoCompleter;
    final result = deferred != null
        ? await deferred.future
        : RecordingCardResult<RecordingCardRuntimeSnapshot>.success(_snapshot);
    if (emitRefreshDeviceInfoResult && result.ok && result.value != null) {
      emit(result.value!);
    }
    return result;
  }

  @override
  Future<RecordingCardResult<RecordingCardRecordingInfo>>
  readRecordingState() async {
    readRecordingStateCallCount += 1;
    _operationLog?.add('readRecordingState');
    final deferred = readRecordingStateCompleter;
    if (deferred != null) return deferred.future;
    return RecordingCardResult<RecordingCardRecordingInfo>.success(
      _snapshot.recordingInfo,
    );
  }

  @override
  Future<RecordingCardResult<RecordingCardRecordingInfo>> startRecording() {
    startRecordingCallCount += 1;
    return _setRecordingState(RecordingCardRecordingState.recording);
  }

  @override
  Future<RecordingCardResult<RecordingCardRecordingInfo>> pauseRecording() {
    return _setRecordingState(RecordingCardRecordingState.paused);
  }

  @override
  Future<RecordingCardResult<RecordingCardRecordingInfo>> resumeRecording() {
    return _setRecordingState(RecordingCardRecordingState.recording);
  }

  @override
  Future<RecordingCardResult<RecordingCardRecordingInfo>> stopRecording() {
    return _setRecordingState(RecordingCardRecordingState.idle);
  }

  @override
  Future<RecordingCardResult<List<RecordingCardScannedFile>>>
  scanFiles() async {
    scanFilesCallCount += 1;
    _operationLog?.add('scanFiles');
    final deferred = scanFilesCompleter;
    if (deferred != null) return deferred.future;
    if (failNextScan) {
      failNextScan = false;
      return RecordingCardResult<List<RecordingCardScannedFile>>.failure(
        _failure('RECORDING_CARD_SCAN_FAILED'),
      );
    }
    final visibleFiles = _directoryFiles
        .where((file) => !_deletedDeviceFileIds.contains(file.deviceFileId))
        .toList(growable: false);
    if (emitScanFilesResult) {
      emit(_snapshot.copyWith(files: visibleFiles));
    }
    return RecordingCardResult<List<RecordingCardScannedFile>>.success(
      visibleFiles,
    );
  }

  @override
  Future<RecordingCardResult<RecordingCardDownloadedFile>>
  downloadFileToLocalCache(RecordingCardScannedFile file) {
    bleDownloadCallCount += 1;
    bleDownloadedKeys.add(file.deviceFileId);
    final exception = bleDownloadExceptionsByDeviceFileId[file.deviceFileId];
    if (exception != null) {
      return Future<RecordingCardResult<RecordingCardDownloadedFile>>.error(
        exception,
      );
    }
    final deferred = bleDownloadCompletersByDeviceFileId[file.deviceFileId];
    if (deferred != null) return deferred.future;
    return syncFileToLocalCache(file);
  }

  @override
  Future<RecordingCardResult<RecordingCardDownloadedFile>> downloadFileOverWifi(
    RecordingCardScannedFile file,
  ) {
    wifiDownloadCallCount += 1;
    return syncFileToLocalCache(file);
  }

  @override
  Future<RecordingCardResult<bool>> cancelFileTransfer() async {
    cancelCallCount += 1;
    final pending = cancelCompleter;
    if (pending != null) return pending.future;
    emit(
      _snapshot.copyWith(
        clearDownloadingFileKey: true,
        clearTransferProgress: true,
        files: _snapshot.files
            .map(
              (file) => file.copyWith(
                syncState: RecordingCardFileSyncState.deviceOnly,
              ),
            )
            .toList(growable: false),
      ),
    );
    return RecordingCardResult<bool>.success(true);
  }

  @override
  Future<RecordingCardResult<RecordingCardWifiCredentials>> prepareWifiTransfer(
    RecordingCardScannedFile file,
  ) async {
    return RecordingCardResult<RecordingCardWifiCredentials>.success(
      const RecordingCardWifiCredentials(
        ssid: 'FW920_TEST',
        password: '12345678', // secret-scan: allow
      ),
    );
  }

  @override
  Future<RecordingCardResult<RecordingCardWifiHandoffResult>>
  verifyWifiHandoff() async {
    wifiHandoffVerifyCallCount += 1;
    _operationLog?.add('verifyWifiHandoff');
    return RecordingCardResult<RecordingCardWifiHandoffResult>.success(
      const RecordingCardWifiHandoffResult(
        status: RecordingCardWifiHandoffStatus.ready,
      ),
    );
  }

  @override
  Future<RecordingCardResult<RecordingCardWifiCredentials>> prepareWifiSession(
    List<RecordingCardScannedFile> files,
  ) async {
    wifiSessionPrepareCallCount += 1;
    _operationLog?.add('prepareWifiSession');
    final deferred = wifiPrepareCompleter;
    if (deferred != null) return deferred.future;
    if (failNextWifiPrepare) {
      failNextWifiPrepare = false;
      if (disconnectOnNextWifiPrepareFailure) {
        disconnectOnNextWifiPrepareFailure = false;
        emit(
          _snapshot.copyWith(
            deviceState: RecordingCardDeviceState.disconnected(),
          ),
        );
      }
      return RecordingCardResult<RecordingCardWifiCredentials>.failure(
        _failure('RECORDING_CARD_WIFI_CREDENTIALS_TIMEOUT'),
      );
    }
    if (disconnectOnNextWifiPrepareSuccess) {
      disconnectOnNextWifiPrepareSuccess = false;
      emit(
        _snapshot.copyWith(
          deviceState: RecordingCardDeviceState.disconnected(),
        ),
      );
    }
    return RecordingCardResult<RecordingCardWifiCredentials>.success(
      const RecordingCardWifiCredentials(
        ssid: 'FW920_TEST',
        password: '12345678', // secret-scan: allow
      ),
    );
  }

  @override
  Future<RecordingCardResult<bool>> joinWifiNetwork(
    RecordingCardWifiCredentials credentials,
  ) async {
    wifiJoinCallCount += 1;
    _operationLog?.add('joinWifiNetwork');
    final pending = wifiJoinCompleter;
    if (pending != null) return pending.future;
    if (failNextWifiJoin) {
      failNextWifiJoin = false;
      return RecordingCardResult<bool>.failure(
        _failure('RECORDING_CARD_WIFI_NETWORK_JOIN_FAILED'),
      );
    }
    return RecordingCardResult<bool>.success(true);
  }

  @override
  Future<RecordingCardResult<bool>> settleWifiRecovery({
    required String batchId,
    required String attemptId,
    required String safeDeviceFingerprint,
  }) async {
    wifiRecoverySettlements.add((
      batchId: batchId,
      attemptId: attemptId,
      safeDeviceFingerprint: safeDeviceFingerprint,
      batchState: wifiBatchStateReader?.call(),
    ));
    return RecordingCardResult<bool>.success(true);
  }

  @override
  Future<RecordingCardResult<RecordingCardWifiSessionInfo>> openWifiSession(
    List<RecordingCardScannedFile> files,
  ) async {
    wifiSessionOpenCallCount += 1;
    _operationLog?.add('open');
    return RecordingCardResult<RecordingCardWifiSessionInfo>.success(
      RecordingCardWifiSessionInfo(
        sessionId: 'wifi-session-1',
        files: List<RecordingCardScannedFile>.unmodifiable(
          wifiSessionFiles ?? files,
        ),
      ),
    );
  }

  @override
  Future<RecordingCardResult<RecordingCardDownloadedFile>>
  downloadFileInWifiSession(RecordingCardScannedFile file) {
    wifiSessionDownloadedKeys.add(file.deviceFileId);
    _operationLog?.add('download:${file.deviceFileId}');
    final deferred =
        wifiSessionDownloadCompletersByDeviceFileId[file.deviceFileId];
    if (deferred != null) return deferred.future;
    final errorCode = wifiSessionFailuresByDeviceFileId[file.deviceFileId];
    if (errorCode != null) {
      return Future<RecordingCardResult<RecordingCardDownloadedFile>>.value(
        RecordingCardResult<RecordingCardDownloadedFile>.failure(
          _failure(errorCode),
        ),
      );
    }
    return Future<RecordingCardResult<RecordingCardDownloadedFile>>.value(
      RecordingCardResult<RecordingCardDownloadedFile>.success(
        _downloadedFileFor(file),
      ),
    );
  }

  @override
  Future<RecordingCardResult<bool>> closeWifiSession() async {
    wifiSessionCloseCallCount += 1;
    _operationLog?.add('close');
    final deferred = wifiCloseCompleter;
    if (deferred != null) return deferred.future;
    if (failNextWifiClose) {
      failNextWifiClose = false;
      return RecordingCardResult<bool>.failure(
        _failure('RECORDING_CARD_WIFI_SESSION_CLOSE_FAILED'),
      );
    }
    return RecordingCardResult<bool>.success(true);
  }

  @override
  Future<RecordingCardResult<bool>> cancelWifiSession() async {
    cancelCallCount += 1;
    _operationLog?.add('cancel');
    final deferred = wifiCancelCompleter;
    if (deferred != null) return deferred.future;
    if (failNextWifiCancel) {
      failNextWifiCancel = false;
      return RecordingCardResult<bool>.failure(
        _failure('RECORDING_CARD_WIFI_CANCEL_FAILED'),
      );
    }
    if (!cancelLeavesDownloadFuturePending) {
      for (final deferred
          in wifiSessionDownloadCompletersByDeviceFileId.values) {
        if (!deferred.isCompleted) {
          deferred.complete(
            RecordingCardResult<RecordingCardDownloadedFile>.failure(
              _failure('RECORDING_CARD_WIFI_TRANSFER_CANCELLED'),
            ),
          );
        }
      }
    }
    return RecordingCardResult<bool>.success(true);
  }

  @override
  Future<RecordingCardResult<RecordingCardDownloadedFile>> syncFileToLocalCache(
    RecordingCardScannedFile file,
  ) async {
    if (_snapshot.deviceState.connectionState !=
        RecordingCardConnectionState.connected) {
      return RecordingCardResult<RecordingCardDownloadedFile>.failure(
        _failure('RECORDING_CARD_NOT_CONNECTED'),
      );
    }
    final deferred = bleDownloadCompleter;
    if (deferred != null) return deferred.future;
    final downloaded = _downloadedFileFor(file);
    emit(
      _snapshot.copyWith(
        files: _snapshot.files
            .map(
              (item) => item.localFileKey == file.localFileKey
                  ? item.copyWith(
                      syncState: RecordingCardFileSyncState.synced,
                      durationSeconds: downloaded.durationSeconds,
                      localFileId: downloaded.localFileId,
                      appPrivateUri: downloaded.appPrivateUri,
                    )
                  : item,
            )
            .toList(growable: false),
      ),
    );
    return RecordingCardResult<RecordingCardDownloadedFile>.success(downloaded);
  }

  RecordingCardDownloadedFile _downloadedFileFor(
    RecordingCardScannedFile file,
  ) {
    final digest = sha256.convert(utf8.encode(file.localFileKey)).toString();
    final nativeFileId = 'card-${digest.substring(0, 32)}';
    return RecordingCardDownloadedFile(
      localFileKey: file.localFileKey,
      localFileId: nativeFileId,
      appPrivateUri: 'app-private://recording-card/$nativeFileId.m4a',
      displayName: '${file.deviceFilename}.m4a',
      durationSeconds: 38,
      sizeBytes: downloadedSizeBytes ?? file.sizeBytes,
      contentHash: downloadedContentHash ?? file.contentHash ?? digest,
      format: RecordingCardFileFormat.m4a,
      mimeType: 'audio/mp4',
    );
  }

  @override
  Future<RecordingCardResult<RecordingCardDeleteResult>> deleteFileFromDevice(
    RecordingCardScannedFile file,
  ) async {
    deleteFileCallCount += 1;
    final deferred = deleteFileCompleter;
    final result = deferred == null
        ? RecordingCardResult<RecordingCardDeleteResult>.success(
            RecordingCardDeleteResult(
              deviceFileId: file.deviceFileId,
              deviceFilename: file.deviceFilename,
            ),
          )
        : await deferred.future;
    final deletedFileId = result.value?.deviceFileId;
    if (!result.ok || deletedFileId == null) return result;
    _deletedDeviceFileIds.add(deletedFileId);
    emit(
      _snapshot.copyWith(
        files: _snapshot.files
            .where((item) => item.deviceFileId != deletedFileId)
            .toList(growable: false),
      ),
    );
    return result;
  }

  @override
  Future<RecordingCardResult<RecordingCardDeviceState>> disconnect() async {
    disconnectCallCount += 1;
    _operationLog?.add('disconnect');
    if (failNextDisconnect) {
      failNextDisconnect = false;
      return RecordingCardResult<RecordingCardDeviceState>.failure(
        _failure('RECORDING_CARD_DISCONNECT_FAILED'),
      );
    }
    final deferred = disconnectCompleter;
    final result = deferred == null
        ? RecordingCardResult<RecordingCardDeviceState>.success(
            RecordingCardDeviceState.disconnected(),
          )
        : await deferred.future;
    final deviceState = result.value;
    if (result.ok && deviceState != null) {
      emit(_snapshot.copyWith(deviceState: deviceState));
    }
    return result;
  }

  @override
  Future<RecordingCardResult<RecordingCardDeviceState>> setBluetoothName({
    required String bluetoothName,
  }) async {
    bluetoothNameCallCount += 1;
    bluetoothNames.add(bluetoothName);
    _operationLog?.add('setBluetoothName');
    if (failNextBluetoothName) {
      failNextBluetoothName = false;
      return RecordingCardResult<RecordingCardDeviceState>.failure(
        _failure('RECORDING_CARD_BLUETOOTH_NAME_REJECTED'),
      );
    }
    final deviceState = _snapshot.deviceState.copyWith(
      displayName: bluetoothName,
    );
    emit(_snapshot.copyWith(deviceState: deviceState));
    return RecordingCardResult<RecordingCardDeviceState>.success(deviceState);
  }

  @override
  Future<RecordingCardResult<RecordingCardDeviceState>> unbindDevice({
    required String bindingTokenHex,
    bool deleteDeviceFiles = false,
  }) async {
    unbindCallCount += 1;
    unbindBindingToken = bindingTokenHex;
    unbindDeleteDeviceFiles = deleteDeviceFiles;
    if (failNextUnbind) {
      failNextUnbind = false;
      return RecordingCardResult<RecordingCardDeviceState>.failure(
        _failure('RECORDING_CARD_UNBIND_REJECTED'),
      );
    }
    final deviceState = RecordingCardDeviceState.disconnected();
    emit(
      RecordingCardRuntimeSnapshot(
        deviceState: deviceState,
        recordingInfo: RecordingCardRecordingInfo.idle(),
        files: const <RecordingCardScannedFile>[],
        discoveredDevices: _snapshot.discoveredDevices,
      ),
    );
    return RecordingCardResult<RecordingCardDeviceState>.success(deviceState);
  }

  @override
  Future<RecordingCardResult<RecordingCardAccountClaim>>
  readAccountBindingClaim() async {
    accountClaimCallCount += 1;
    return RecordingCardResult<RecordingCardAccountClaim>.success(
      RecordingCardAccountClaim(opaqueClaim: 'a' * 64),
    );
  }

  Future<RecordingCardResult<RecordingCardRecordingInfo>> _setRecordingState(
    RecordingCardRecordingState state,
  ) async {
    final info = RecordingCardRecordingInfo(state: state);
    emit(_snapshot.copyWith(recordingInfo: info));
    return RecordingCardResult<RecordingCardRecordingInfo>.success(info);
  }
}

final class _FakeConnectionAuthorization
    implements RecordingCardConnectionAuthorizationPort {
  _FakeConnectionAuthorization._(this._result, this._pending);

  factory _FakeConnectionAuthorization.success() =>
      _FakeConnectionAuthorization._(
        RecordingCardResult<bool>.success(true),
        null,
      );

  factory _FakeConnectionAuthorization.failure(String code) =>
      _FakeConnectionAuthorization._(
        RecordingCardResult<bool>.failure(
          recordingCardFailure(
            code,
            'Cloud connection authorization rejected the recording card',
          ),
        ),
        null,
      );

  factory _FakeConnectionAuthorization.pending() =>
      _FakeConnectionAuthorization._(
        RecordingCardResult<bool>.success(true),
        Completer<RecordingCardResult<bool>>(),
      );

  final RecordingCardResult<bool> _result;
  final Completer<RecordingCardResult<bool>>? _pending;
  Completer<RecordingCardResult<bool>>? pendingResult;
  int callCount = 0;

  @override
  Future<RecordingCardResult<bool>> authorizeConnection(
    RecordingCardDeviceState device,
  ) {
    callCount += 1;
    return pendingResult?.future ?? _pending?.future ?? Future.value(_result);
  }

  void completeSuccess() {
    final pending = _pending;
    if (pending != null && !pending.isCompleted) {
      pending.complete(RecordingCardResult<bool>.success(true));
    }
  }
}

final class _FakeDiscoveryAuthorization
    implements
        RecordingCardConnectionAuthorizationPort,
        RecordingCardDiscoveryAuthorizationPort {
  _FakeDiscoveryAuthorization({
    RecordingCardResult<bool>? preauthorization,
    this.cachedSerials = const <String>{},
  }) : _preauthorization =
           preauthorization ?? RecordingCardResult<bool>.success(true);

  final RecordingCardResult<bool> _preauthorization;
  final Set<String> cachedSerials;
  var discoveryAuthorizationCount = 0;

  @override
  Future<RecordingCardResult<bool>> authorizeConnection(
    RecordingCardDeviceState device,
  ) async => RecordingCardResult<bool>.success(true);

  @override
  Future<RecordingCardResult<bool>> authorizeDiscoveredDevice({
    required String serialNumber,
    required String displayName,
  }) async {
    discoveryAuthorizationCount += 1;
    return _preauthorization;
  }

  @override
  Future<RecordingCardResult<bool>> matchesCachedSerial(
    String serialNumber,
  ) async =>
      RecordingCardResult<bool>.success(cachedSerials.contains(serialNumber));
}

final class _RecoveryRecordingCardPort extends _FakeRecordingCardPort
    implements RecordingCardWifiRecoveryPort {
  _RecoveryRecordingCardPort({
    List<String>? operationLog,
    String serialNumber = 'RECOVERY-CARD-001',
  }) : super(operationLog: operationLog, serialNumber: serialNumber);
  String batchId = '';
  String attemptId = '';
  bool sessionActive = false;
  bool holdReply = false;
  bool commitBeforeReply = false;
  String? sessionFailureCode;
  int beginCount = 0;
  int queryCount = 0;
  final targets = <String>[];
  final committed = <String, RecordingCardDownloadedFile>{};
  final recoveryTargets = <String>[];
  final recoveryErrors = <String, String>{};
  void Function(RecordingCardScannedFile file)? onRecoveryLookup;
  final replies =
      <Completer<RecordingCardResult<RecordingCardDownloadedFile>>>[];
  final observers = <void Function(RecordingCardWifiSessionObservation)>{};

  @override
  Future<RecordingCardResult<bool>> beginWifiAttempt({
    required String batchId,
    required String attemptId,
  }) async {
    this.batchId = batchId;
    this.attemptId = attemptId;
    beginCount += 1;
    sessionActive = true;
    return RecordingCardResult.success(true);
  }

  @override
  Future<RecordingCardResult<RecordingCardWifiSessionObservation>>
  queryWifiSession() async {
    queryCount += 1;
    return RecordingCardResult.success(
      RecordingCardWifiSessionObservation(
        batchId: batchId,
        attemptId: attemptId,
        active: sessionActive,
        failureCode: sessionFailureCode,
      ),
    );
  }

  @override
  RecordingCardSnapshotSubscription subscribeWifiSession(
    void Function(RecordingCardWifiSessionObservation) listener,
  ) {
    observers.add(listener);
    return RecordingCardSnapshotSubscription(() => observers.remove(listener));
  }

  void emitInterruption(String attempt) {
    for (final listener in List.of(observers)) {
      listener(
        RecordingCardWifiSessionObservation(
          batchId: batchId,
          attemptId: attempt,
          active: false,
          failureCode: 'RECORDING_CARD_WIFI_NETWORK_LOST',
        ),
      );
    }
  }

  @override
  Future<RecordingCardResult<RecordingCardDownloadedFile>>
  downloadRecoverableWifiFile(
    RecordingCardScannedFile file, {
    required String nativeFileId,
  }) {
    targets.add(nativeFileId);
    wifiSessionDownloadedKeys.add(file.deviceFileId);
    _operationLog?.add('download:${file.deviceFileId}');
    final download = RecordingCardDownloadedFile(
      localFileKey: file.localFileKey,
      localFileId: nativeFileId,
      appPrivateUri: 'app-private://recording-card/$nativeFileId.m4a',
      displayName: '${file.deviceFilename}.m4a',
      sizeBytes: file.sizeBytes,
      durationSeconds: 38,
      contentHash: sha256
          .convert(
            utf8.encode('app-private://recording-card/$nativeFileId.m4a'),
          )
          .toString(),
      format: RecordingCardFileFormat.m4a,
      mimeType: 'audio/mp4',
    );
    if (!holdReply || commitBeforeReply) committed[nativeFileId] = download;
    if (!holdReply) return Future.value(RecordingCardResult.success(download));
    final reply = Completer<RecordingCardResult<RecordingCardDownloadedFile>>();
    replies.add(reply);
    return reply.future;
  }

  @override
  Future<RecordingCardResult<RecordingCardWifiRecoveredDownload>>
  recoverWifiDownload(
    RecordingCardScannedFile file, {
    required String nativeFileId,
  }) async {
    recoveryTargets.add(nativeFileId);
    onRecoveryLookup?.call(file);
    final errorCode = recoveryErrors[nativeFileId];
    if (errorCode != null) {
      return RecordingCardResult.failure(_failure(errorCode));
    }
    return RecordingCardResult.success(
      RecordingCardWifiRecoveredDownload(committed[nativeFileId]),
    );
  }

  @override
  Future<RecordingCardResult<bool>> cancelWifiSession() async {
    sessionActive = false;
    return super.cancelWifiSession();
  }

  @override
  Future<RecordingCardResult<bool>> closeWifiSession() async {
    sessionActive = false;
    return super.closeWifiSession();
  }
}

final class _RecoverableBluetoothRecordingCardPort
    extends _FakeRecordingCardPort
    implements RecordingCardRecoverableBluetoothTransferPort {
  _RecoverableBluetoothRecordingCardPort({
    required super.serialNumber,
    required this.recoverCommitted,
    this.mismatchNativeFileId = false,
  });

  final bool recoverCommitted;
  final bool mismatchNativeFileId;
  final List<String> recoveredTargets = <String>[];
  final List<String> downloadedTargets = <String>[];

  @override
  Future<RecordingCardResult<RecordingCardBluetoothRecoveredDownload>>
  recoverBluetoothDownload(
    RecordingCardScannedFile file, {
    required String plannedNativeFileId,
  }) async {
    recoveredTargets.add(plannedNativeFileId);
    return RecordingCardResult<RecordingCardBluetoothRecoveredDownload>.success(
      RecordingCardBluetoothRecoveredDownload(
        recoverCommitted ? _downloadedFile(file, plannedNativeFileId) : null,
      ),
    );
  }

  @override
  Future<RecordingCardResult<RecordingCardDownloadedFile>>
  downloadRecoverableBluetoothFile(
    RecordingCardScannedFile file, {
    required String plannedNativeFileId,
  }) async {
    downloadedTargets.add(plannedNativeFileId);
    return RecordingCardResult<RecordingCardDownloadedFile>.success(
      _downloadedFile(file, plannedNativeFileId),
    );
  }

  RecordingCardDownloadedFile _downloadedFile(
    RecordingCardScannedFile file,
    String plannedNativeFileId,
  ) {
    final nativeFileId = mismatchNativeFileId
        ? 'card-ffffffffffffffffffffffffffffffff'
        : plannedNativeFileId;
    final appPrivateUri = 'app-private://recording-card/$nativeFileId.m4a';
    return RecordingCardDownloadedFile(
      localFileKey: file.localFileKey,
      localFileId: nativeFileId,
      appPrivateUri: appPrivateUri,
      displayName: '${file.deviceFilename}.m4a',
      sizeBytes: file.sizeBytes,
      durationSeconds: file.durationSeconds ?? 38,
      contentHash: sha256.convert(utf8.encode(appPrivateUri)).toString(),
      format: RecordingCardFileFormat.m4a,
      mimeType: 'audio/mp4',
    );
  }
}

final class _FakePlatformPermissionsPort implements PlatformPermissionsPort {
  _FakePlatformPermissionsPort({
    this.statuses = const <PlatformPermissionKind, PlatformPermissionStatus>{
      PlatformPermissionKind.bluetooth: PlatformPermissionStatus.granted,
      PlatformPermissionKind.localNetwork: PlatformPermissionStatus.granted,
    },
    this.operationLog,
  });

  final Map<PlatformPermissionKind, PlatformPermissionStatus> statuses;
  final List<String>? operationLog;
  final requestedKinds = <Set<PlatformPermissionKind>>[];

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
      buildPermissionSummaryRows(statuses),
    );
  }

  @override
  Future<PlatformPermissionResult<List<PlatformPermissionSummary>>>
  requestPermissions(Set<PlatformPermissionKind> kinds) async {
    operationLog?.add('permission');
    requestedKinds.add(Set<PlatformPermissionKind>.of(kinds));
    return PlatformPermissionResult<List<PlatformPermissionSummary>>.success(
      buildPermissionSummaryRows(statuses),
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
}

RecordingCardScannedFile _file({
  int? sizeBytes = 4096,
  RecordingCardFileSizeConfidence? sizeConfidence =
      RecordingCardFileSizeConfidence.trusted,
  String? contentHash,
  DateTime? recordedAt,
}) {
  return RecordingCardScannedFile(
    deviceFileId: 'card-file-1',
    localFileKey: 'card-20260701090000',
    deviceFilename: '20260701090000',
    sizeBytes: sizeBytes,
    sizeConfidence: sizeConfidence,
    contentHash: contentHash,
    recordedAt: recordedAt,
    syncState: RecordingCardFileSyncState.deviceOnly,
  );
}

RecordingCardScannedFile _fileWithId(int id, {String? contentHash}) {
  return RecordingCardScannedFile(
    deviceFileId: 'card-file-$id',
    localFileKey: 'card-2026070109000$id',
    deviceFilename: '2026070109000$id',
    sizeBytes: 4096,
    sizeConfidence: RecordingCardFileSizeConfidence.trusted,
    contentHash: contentHash,
    format: RecordingCardFileFormat.m4a,
    mimeType: 'audio/mp4',
  );
}

final class _RecordingCardFileStorage extends UnavailableFileStoragePort {
  const _RecordingCardFileStorage({
    this.operationLog,
    this.statFailure,
    this.statExists,
    this.contentHash,
    this.statResult,
  });

  final List<String>? operationLog;
  final bool Function()? statFailure;
  final bool Function()? statExists;
  final String? contentHash;
  final Future<FileStorageResult<PrivateAudioFileStat>> Function(String uri)?
  statResult;

  @override
  Future<FileStorageResult<PrivateAudioFile>> copyPickedAudioToPrivateLibrary(
    PickedAudioFile picked,
  ) async {
    return FileStorageResult<PrivateAudioFile>.failure(_failure('UNUSED'));
  }

  @override
  Future<FileStorageResult<bool>> deletePrivateAudio(
    String appPrivateUri,
  ) async {
    return FileStorageResult<bool>.failure(_failure('UNUSED'));
  }

  @override
  Future<FileStorageResult<PreparedAudioExport>> prepareAudioExport({
    required String appPrivateUri,
    required String displayName,
  }) async {
    return FileStorageResult<PreparedAudioExport>.failure(_failure('UNUSED'));
  }

  @override
  Future<FileStorageResult<PrivateAudioFileStat>> statPrivateAudio(
    String appPrivateUri,
  ) async {
    operationLog?.add('stat');
    final configuredResult = statResult;
    if (configuredResult != null) return configuredResult(appPrivateUri);
    if (statFailure?.call() == true) {
      return FileStorageResult<PrivateAudioFileStat>.failure(
        _failure('RECORDING_PRIVATE_FILE_STAT_FAILED'),
      );
    }
    return FileStorageResult<PrivateAudioFileStat>.success(
      PrivateAudioFileStat(exists: statExists?.call() ?? true, sizeBytes: 4096),
    );
  }

  @override
  Future<FileStorageResult<String>> hashPrivateAudio(
    String appPrivateUri,
  ) async {
    if (contentHash case final configured?) {
      return FileStorageResult<String>.success(configured);
    }
    if (appPrivateUri.contains('card-11111111111111111111111111111111')) {
      return FileStorageResult<String>.success(
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      );
    }
    for (var suffix = 0; suffix <= 20; suffix += 1) {
      final localFileKey = suffix == 0
          ? 'card-20260701090000'
          : 'card-2026070109000$suffix';
      final digest = sha256.convert(utf8.encode(localFileKey)).toString();
      if (appPrivateUri.contains('card-${digest.substring(0, 32)}')) {
        return FileStorageResult<String>.success(digest);
      }
    }
    return FileStorageResult<String>.success(
      sha256.convert(utf8.encode(appPrivateUri)).toString(),
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

final class _FailingManualBluetoothLedger
    implements RecordingCardSyncLedgerPersistencePort {
  _FailingManualBluetoothLedger(this._delegate);

  final RecordingCardSyncLedgerStore _delegate;
  bool _failNextFailureWrite = true;

  @override
  String get accountScope => _delegate.accountScope;

  @override
  Future<void> flushSyncPersistence() => _delegate.flushSyncPersistence();

  @override
  List<RecordingCardFileLedgerEntry> loadFileLedger(String cardSnDigest) =>
      _delegate.loadFileLedger(cardSnDigest);

  @override
  RecordingCardFileLedgerEntry queueManualSyncForFile({
    required String cardSnDigest,
    required RecordingCardScannedFile file,
    required DateTime at,
  }) => _delegate.queueManualSyncForFile(
    cardSnDigest: cardSnDigest,
    file: file,
    at: at,
  );

  @override
  RecordingCardFileLedgerEntry beginManualSync({
    required String cardSnDigest,
    required String sourceSignature,
    required DateTime at,
  }) => _delegate.beginManualSync(
    cardSnDigest: cardSnDigest,
    sourceSignature: sourceSignature,
    at: at,
  );

  @override
  RecordingCardFileLedgerEntry failManualSync({
    required String cardSnDigest,
    required String sourceSignature,
    required String errorCode,
    required RecordingCardSyncRetryability retryability,
    required DateTime at,
  }) {
    if (_failNextFailureWrite) {
      _failNextFailureWrite = false;
      throw StateError('forced ledger failure write');
    }
    return _delegate.failManualSync(
      cardSnDigest: cardSnDigest,
      sourceSignature: sourceSignature,
      errorCode: errorCode,
      retryability: retryability,
      at: at,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unexpected ledger call: $invocation');
}

final class _DeferredLedgerFlush {
  _DeferredLedgerFlush({this.failure});

  final Object? failure;
  final started = Completer<void>();
  final released = Completer<void>();

  void release() {
    if (!released.isCompleted) released.complete();
  }
}

final class _DeferredFlushRecordingCardLedger
    implements RecordingCardSyncLedgerPersistencePort {
  _DeferredFlushRecordingCardLedger(this._delegate);

  final RecordingCardSyncLedgerStore _delegate;
  _DeferredLedgerFlush? _nextFlush;

  _DeferredLedgerFlush deferNextFlush({Object? failure}) {
    if (_nextFlush != null) {
      throw StateError(
        'A deferred recording-card ledger flush is already armed',
      );
    }
    final gate = _DeferredLedgerFlush(failure: failure);
    _nextFlush = gate;
    return gate;
  }

  @override
  String get accountScope => _delegate.accountScope;

  @override
  Future<void> flushSyncPersistence() async {
    final gate = _nextFlush;
    if (gate != null) {
      _nextFlush = null;
      gate.started.complete();
      await gate.released.future;
      if (gate.failure case final failure?) throw failure;
    }
    await _delegate.flushSyncPersistence();
  }

  @override
  List<String> loadKnownCardDigests() => _delegate.loadKnownCardDigests();

  @override
  String? latestKnownCardSnDigest() => _delegate.latestKnownCardSnDigest();

  @override
  List<RecordingCardFileLedgerEntry> loadFileLedger(String cardSnDigest) =>
      _delegate.loadFileLedger(cardSnDigest);

  @override
  RecordingCardFileLedgerEntry? findFileLedgerEntry({
    required String cardSnDigest,
    required String sourceSignature,
  }) => _delegate.findFileLedgerEntry(
    cardSnDigest: cardSnDigest,
    sourceSignature: sourceSignature,
  );

  @override
  RecordingCardFileLedgerEntry queueManualSync({
    required String cardSnDigest,
    required String sourceSignature,
    required DateTime at,
  }) => _delegate.queueManualSync(
    cardSnDigest: cardSnDigest,
    sourceSignature: sourceSignature,
    at: at,
  );

  @override
  RecordingCardFileLedgerEntry queueManualSyncForFile({
    required String cardSnDigest,
    required RecordingCardScannedFile file,
    required DateTime at,
  }) => _delegate.queueManualSyncForFile(
    cardSnDigest: cardSnDigest,
    file: file,
    at: at,
  );

  @override
  RecordingCardFileLedgerEntry beginManualSync({
    required String cardSnDigest,
    required String sourceSignature,
    required DateTime at,
  }) => _delegate.beginManualSync(
    cardSnDigest: cardSnDigest,
    sourceSignature: sourceSignature,
    at: at,
  );

  @override
  RecordingCardFileLedgerEntry beginManualSyncForFile({
    required String cardSnDigest,
    required RecordingCardScannedFile file,
    required DateTime at,
  }) => _delegate.beginManualSyncForFile(
    cardSnDigest: cardSnDigest,
    file: file,
    at: at,
  );

  @override
  RecordingCardFileLedgerEntry completeManualSync({
    required String cardSnDigest,
    required String sourceSignature,
    required String localRecordingId,
    required DateTime at,
    String? contentHash,
  }) => _delegate.completeManualSync(
    cardSnDigest: cardSnDigest,
    sourceSignature: sourceSignature,
    localRecordingId: localRecordingId,
    at: at,
    contentHash: contentHash,
  );

  @override
  RecordingCardFileLedgerEntry failManualSync({
    required String cardSnDigest,
    required String sourceSignature,
    required String errorCode,
    required RecordingCardSyncRetryability retryability,
    required DateTime at,
  }) => _delegate.failManualSync(
    cardSnDigest: cardSnDigest,
    sourceSignature: sourceSignature,
    errorCode: errorCode,
    retryability: retryability,
    at: at,
  );

  @override
  void saveFileLedgerEntry(RecordingCardFileLedgerEntry entry) {
    _delegate.saveFileLedgerEntry(entry);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unexpected ledger call: $invocation');
}

AppFailure _failure(String code) {
  return AppFailure(
    code: code,
    category: AppFailureCategory.compatibility,
    message: 'recording card test failure',
    userMessageKey: 'recordingCard.error.$code',
  );
}
