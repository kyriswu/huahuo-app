import 'package:huahuoai_app/app/di/diagnostics_providers.dart';
import 'package:huahuoai_app/app/di/database_providers.dart';
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuo_api/huahuo_api.dart';
import 'package:huahuoai_app/app/bootstrap/app_providers.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/database/diagnostic_log_dao.dart';
import 'package:huahuoai_app/core/diagnostics/diagnostic_logger.dart';
import 'package:huahuoai_app/core/native/native_file_port.dart';
import 'package:huahuoai_app/core/native/platform_permissions_port.dart';
import 'package:huahuoai_app/core/native/recording_card_native_port.dart';
import 'package:huahuoai_app/core/native/voice_recorder_port.dart';
import 'package:huahuoai_app/core/storage/file_storage_port.dart';
import 'package:huahuoai_app/core/storage/upload_draft_store.dart';
import 'package:huahuoai_app/features/ingestion/application/meeting_capture_controller.dart';
import 'package:huahuoai_app/features/ingestion/data/meeting_capture_session_store.dart';
import 'package:huahuoai_app/features/recording_card/application/recording_card_controller.dart';
import 'package:huahuoai_app/features/recordings/application/recording_library_controller.dart';
import 'package:huahuoai_app/features/recordings/data/local_recording_repository.dart';
import 'package:huahuoai_app/features/recordings/data/recording_api.dart';
import 'package:huahuoai_app/features/recordings/application/recording_upload_controller.dart';
import 'package:huahuoai_app/features/recordings/domain/recording_library.dart';
import 'package:huahuoai_app/features/ui_v3/application/digital_twin_material_controller.dart';
import 'package:huahuoai_app/features/ui_v3/data/digital_twin_material_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'real provider survives dependency notifications but not account replacement',
    () async {
      final database = AppDatabase();
      final repository = LocalRecordingRepository(
        database: database,
        fileStorage: const _FileStorage(),
      );
      final recorder = _FakeRecorder();
      final library = RecordingLibraryController(
        repository: repository,
        nativeFilePort: const UnavailableNativeFilePort(),
      );
      final card = RecordingCardController(
        port: const UnavailableRecordingCardPort(),
        localRecordingRepository: repository,
        platformPermissionsPort: const MethodChannelPlatformPermissionsPort(),
        requiresBluetoothPermissionRequest: () => false,
        requiresWifiPermissionRequest: () => false,
      );
      final apiClient = ApiClient(
        config: ApiClientConfig(
          baseUrl: Uri.parse('https://api.example.test'),
          clientVersion: 'test',
          deviceId: 'test-device',
          platform: 'ios',
          locale: 'zh-CN',
          getAccessToken: () => null,
        ),
        transport: const _NoNetworkTransport(),
      );
      final uploader = RecordingUploadController(
        uploadClient: UploadClient(
          apiClient: apiClient,
          objectTransport: const _NoNetworkTransport(),
        ),
        draftStore: UploadDraftStore(database: database),
        recordingApi: RecordingApi(apiClient: apiClient),
        localRecordingRepository: repository,
        activeWorkspaceId: () => null,
      );
      final logger = DiagnosticLogger(dao: DiagnosticLogDao(database));
      addTearDown(logger.dispose);
      final accountProvider = StateProvider<String>((ref) => 'account-a');
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWithValue(database),
          authenticatedRecordingUserScopeProvider.overrideWith(
            (ref) => ref.watch(accountProvider),
          ),
          localRecordingRepositoryProvider.overrideWithValue(repository),
          voiceRecorderPortProvider.overrideWithValue(recorder),
          recordingLibraryControllerProvider.overrideWith((ref) => library),
          recordingCardControllerProvider.overrideWith((ref) => card),
          recordingUploadControllerProvider.overrideWith((ref) => uploader),
          diagnosticLoggerProvider.overrideWithValue(logger),
          digitalTwinMaterialControllerProvider.overrideWith(
            (ref) => DigitalTwinMaterialController(
              store: DigitalTwinMaterialStore(
                database: database,
                scope: 'test',
              ),
              apiFactory: () => throw StateError('Unexpected material request'),
              resolveSource: (_) async => null,
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      final subscription = container.listen(
        meetingCaptureControllerProvider,
        (previous, next) {},
        fireImmediately: true,
      );
      addTearDown(subscription.close);
      final controller = subscription.read();
      expect(await controller.initialize(), MeetingCaptureEntryOutcome.ready);
      await container.pump();
      expect(subscription.read(), same(controller));
      expect(await controller.startLiveRecording(), isTrue);

      library.setSearchText('changed library filter');
      await container.pump();
      expect(subscription.read(), same(controller));
      expect(controller.state.status, MeetingCaptureStatus.recording);

      await card.scanDevices();
      await container.pump();
      expect(subscription.read(), same(controller));
      expect(controller.state.status, MeetingCaptureStatus.recording);

      await uploader.uploadLocalRecording(item: _item(id: 'separate-job'));
      await container.pump();
      expect(subscription.read(), same(controller));
      expect(controller.state.status, MeetingCaptureStatus.recording);
      expect(
        uploader.state.lastErrorCode,
        'RECORDING_UPLOAD_WORKSPACE_UNAVAILABLE',
      );
      expect(recorder.cancelCalls, 0);

      container.read(accountProvider.notifier).state = 'account-b';
      await container.pump();
      expect(subscription.read(), isNot(same(controller)));
      expect(recorder.cancelCalls, 1);
    },
  );

  testWidgets('pause rejects a stale read without stranding observation', (
    tester,
  ) async {
    final recorder = _FakeRecorder();
    final controller = MeetingCaptureController(
      recorder: recorder,
      localRecordingRepository: _repository(),
      recordingLibrary: _FakeLibrary(),
      recordingCard: _FakeCard(),
      uploader: _FakeUploader(),
    );
    try {
      expect(await controller.startLiveRecording(), isTrue);
      final recordingSnapshot = recorder.snapshot;
      final pendingRead =
          Completer<VoiceRecorderResult<VoiceRecorderSnapshot>>();
      recorder.refreshResult = pendingRead;
      await tester.pump(const Duration(seconds: 1));
      expect(recorder.refreshCalls, 1);
      expect(await controller.pause(), isTrue);
      recorder.refreshResult = null;
      pendingRead.complete(VoiceRecorderResult.success(recordingSnapshot));
      await tester.pump();
      expect(controller.state.status, MeetingCaptureStatus.paused);
      await tester.pump(const Duration(seconds: 1));
      expect(recorder.refreshCalls, 2);
      expect(controller.state.status, MeetingCaptureStatus.paused);
      expect(await controller.resume(), isTrue);
      await tester.pump(const Duration(seconds: 1));
      expect(recorder.refreshCalls, 3);
      expect(controller.state.status, MeetingCaptureStatus.recording);
    } finally {
      controller.dispose();
    }
  });

  testWidgets('failed native controls retain and reconcile owned capture', (
    tester,
  ) async {
    final recorder = _FakeRecorder();
    final controller = MeetingCaptureController(
      recorder: recorder,
      localRecordingRepository: _repository(),
      recordingLibrary: _FakeLibrary(),
      recordingCard: _FakeCard(),
      uploader: _FakeUploader(),
    );
    try {
      expect(await controller.startLiveRecording(), isTrue);

      recorder.pauseFailureCode = 'VOICE_RECORDER_PAUSE_FAILED';
      expect(await controller.pause(), isFalse);
      expect(controller.state.status, MeetingCaptureStatus.recording);
      expect(controller.state.nativeRecordingId, 'voice-meeting-1');
      expect(controller.state.projectsActiveMessage, isTrue);
      expect(controller.state.lastErrorCode, 'VOICE_RECORDER_PAUSE_FAILED');

      recorder.pauseFailureCode = null;
      expect(await controller.pause(), isTrue);
      recorder.resumeFailureCode = 'VOICE_RECORDER_RESUME_FAILED';
      expect(await controller.resume(), isFalse);
      expect(controller.state.status, MeetingCaptureStatus.paused);
      expect(controller.state.projectsActiveMessage, isTrue);

      recorder.resumeFailureCode = null;
      expect(await controller.resume(), isTrue);
      final stopRefresh =
          Completer<VoiceRecorderResult<VoiceRecorderSnapshot>>();
      recorder.refreshResult = stopRefresh;
      recorder.stopFailureCode = 'VOICE_RECORDER_STOP_FAILED';
      expect(await controller.stop(), isFalse);
      expect(controller.state.status, MeetingCaptureStatus.recording);
      expect(controller.state.nativeRecordingId, 'voice-meeting-1');
      expect(controller.state.projectsActiveMessage, isTrue);
      expect(controller.state.lastErrorCode, 'VOICE_RECORDER_STOP_FAILED');
      expect(recorder.refreshCalls, 1);

      recorder.stopFailureCode = null;
      recorder.refreshResult = null;
      stopRefresh.complete(VoiceRecorderResult.success(recorder.snapshot));
      await tester.pump();
      expect(controller.state.status, MeetingCaptureStatus.recording);
      expect(controller.state.lastErrorCode, isNull);

      final cancelRefresh =
          Completer<VoiceRecorderResult<VoiceRecorderSnapshot>>();
      recorder.refreshResult = cancelRefresh;
      recorder.cancelFailureCode = 'VOICE_RECORDER_CANCEL_FAILED';
      expect(await controller.cancel(), isFalse);
      expect(controller.state.status, MeetingCaptureStatus.recording);
      expect(controller.state.nativeRecordingId, 'voice-meeting-1');
      expect(controller.state.projectsActiveMessage, isTrue);
      expect(controller.state.lastErrorCode, 'VOICE_RECORDER_CANCEL_FAILED');
      expect(recorder.refreshCalls, 2);

      recorder.cancelFailureCode = null;
      recorder.refreshResult = null;
      cancelRefresh.complete(VoiceRecorderResult.success(recorder.snapshot));
      await tester.pump();
      expect(controller.state.status, MeetingCaptureStatus.recording);
      expect(controller.state.lastErrorCode, isNull);
    } finally {
      controller.dispose();
    }
  });

  testWidgets('dispose waits for failed stop before cancelling owned capture', (
    tester,
  ) async {
    final stopResult = Completer<VoiceRecorderResult<VoiceRecordingDraft>>();
    final recorder = _FakeRecorder()..stopResult = stopResult;
    final controller = MeetingCaptureController(
      recorder: recorder,
      localRecordingRepository: _repository(),
      recordingLibrary: _FakeLibrary(),
      recordingCard: _FakeCard(),
      uploader: _FakeUploader(),
    );
    expect(await controller.startLiveRecording(), isTrue);

    final stopping = controller.stop();
    controller.dispose();
    expect(recorder.stopCalls, 0);
    expect(recorder.cancelCalls, 0);
    await tester.pump();
    expect(recorder.stopCalls, 1);

    stopResult.complete(
      VoiceRecorderResult.failure(
        voiceRecorderFailure('VOICE_RECORDER_STOP_FAILED'),
      ),
    );
    expect(await stopping, isFalse);
    await tester.pump();
    expect(recorder.cancelCalls, 1);
  });

  testWidgets('serializes stop behind an in-flight pause', (tester) async {
    final pauseResult = Completer<VoiceRecorderResult<VoiceRecorderSnapshot>>();
    final recorder = _FakeRecorder()..pauseResult = pauseResult;
    final controller = MeetingCaptureController(
      recorder: recorder,
      localRecordingRepository: _repository(),
      recordingLibrary: _FakeLibrary(),
      recordingCard: _FakeCard(),
      uploader: _FakeUploader(),
    );
    try {
      expect(await controller.startLiveRecording(), isTrue);
      final pausing = controller.pause();
      await tester.pump();
      expect(recorder.pauseCalls, 1);
      expect(await controller.pause(), isFalse);

      final stopping = controller.stop();
      await tester.pump();
      expect(recorder.stopCalls, 0);

      final pausedSnapshot = VoiceRecorderSnapshot(
        state: VoiceRecorderState.paused,
        session: recorder.session(VoiceRecorderState.paused),
      );
      recorder.setSnapshot(pausedSnapshot);
      pauseResult.complete(VoiceRecorderResult.success(pausedSnapshot));
      expect(await pausing, isFalse);
      await tester.pump();
      expect(recorder.stopCalls, 1);
      expect(await stopping, isTrue);
    } finally {
      controller.dispose();
    }
  });

  testWidgets('accepted stop behind pause survives controller disposal', (
    tester,
  ) async {
    final pauseResult = Completer<VoiceRecorderResult<VoiceRecorderSnapshot>>();
    final repository = _repository();
    final recorder = _FakeRecorder()..pauseResult = pauseResult;
    final controller = MeetingCaptureController(
      recorder: recorder,
      localRecordingRepository: repository,
      recordingLibrary: _FakeLibrary(repository: repository),
      recordingCard: _FakeCard(),
      uploader: _FakeUploader(),
    );
    expect(await controller.startLiveRecording(), isTrue);

    final pausing = controller.pause();
    await tester.pump();
    expect(recorder.pauseCalls, 1);

    final stopping = controller.stop();
    expect(controller.state.status, MeetingCaptureStatus.stopping);
    controller.dispose();
    expect(recorder.stopCalls, 0);
    expect(recorder.cancelCalls, 0);

    final pausedSnapshot = VoiceRecorderSnapshot(
      state: VoiceRecorderState.paused,
      session: recorder.session(VoiceRecorderState.paused),
    );
    recorder.setSnapshot(pausedSnapshot);
    pauseResult.complete(VoiceRecorderResult.success(pausedSnapshot));

    expect(await pausing, isFalse);
    await tester.pump();
    expect(recorder.stopCalls, 1);
    expect(await stopping, isFalse);
    await tester.pump();
    expect(recorder.cancelCalls, 0);
    final saved = repository.list().rows.single;
    expect(saved.appPrivateUri, 'app-private://voice-meeting-1.wav');
    expect(saved.source, RecordingLibrarySource.microphone);
    expect(saved.tagIds, contains(externalRecordingHistoryTagId));
  });

  testWidgets(
    'dispose waits for failed cancel before cancelling owned capture again',
    (tester) async {
      final cancelResult =
          Completer<VoiceRecorderResult<VoiceRecorderSnapshot>>();
      final recorder = _FakeRecorder()..cancelResult = cancelResult;
      final controller = MeetingCaptureController(
        recorder: recorder,
        localRecordingRepository: _repository(),
        recordingLibrary: _FakeLibrary(),
        recordingCard: _FakeCard(),
        uploader: _FakeUploader(),
      );
      expect(await controller.startLiveRecording(), isTrue);

      final cancelling = controller.cancel();
      await tester.pump();
      expect(recorder.cancelCalls, 1);
      controller.dispose();
      expect(recorder.cancelCalls, 1);

      cancelResult.complete(
        VoiceRecorderResult.failure(
          voiceRecorderFailure('VOICE_RECORDER_CANCEL_FAILED'),
        ),
      );
      expect(await cancelling, isFalse);
      await tester.pump();
      expect(recorder.cancelCalls, 2);
    },
  );

  testWidgets(
    'background keeps native capture and resume reconciles elapsed time',
    (tester) async {
      final recorder = _FakeRecorder();
      final controller = MeetingCaptureController(
        recorder: recorder,
        localRecordingRepository: _repository(),
        recordingLibrary: _FakeLibrary(),
        recordingCard: _FakeCard(),
        uploader: _FakeUploader(),
      );
      try {
        expect(await controller.startLiveRecording(), isTrue);
        expect(controller.state.startedAt, DateTime.utc(2026, 7, 14, 9));

        final staleSnapshot = recorder.snapshot;
        final staleRead =
            Completer<VoiceRecorderResult<VoiceRecorderSnapshot>>();
        recorder.refreshResult = staleRead;
        await tester.pump(const Duration(seconds: 1));
        expect(recorder.refreshCalls, 1);

        controller.didChangeAppLifecycleState(AppLifecycleState.paused);
        await tester.pump();
        await tester.pump(const Duration(seconds: 2));
        expect(recorder.refreshCalls, 1);
        expect(recorder.pauseCalls, 0);
        expect(recorder.stopCalls, 0);
        expect(recorder.cancelCalls, 0);

        final resumedAt = DateTime.utc(2026, 7, 14, 9, 0, 5);
        recorder.setActiveSnapshot(elapsedSeconds: 125, startedAt: resumedAt);
        controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
        await tester.pump();

        controller.didChangeAppLifecycleState(AppLifecycleState.paused);
        controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
        await tester.pump();
        expect(recorder.refreshCalls, 1);

        recorder.refreshResult = null;
        staleRead.complete(VoiceRecorderResult.success(staleSnapshot));
        await tester.pump();

        expect(recorder.refreshCalls, 2);
        expect(controller.state.status, MeetingCaptureStatus.recording);
        expect(controller.state.elapsedSeconds, 125);
        expect(controller.state.startedAt, resumedAt);
        expect(recorder.pauseCalls, 0);
        expect(recorder.stopCalls, 0);
        expect(recorder.cancelCalls, 0);

        await tester.pump(const Duration(seconds: 1));
        expect(recorder.refreshCalls, 3);
      } finally {
        controller.dispose();
      }
    },
  );

  testWidgets('native start waits until the application is resumed', (
    tester,
  ) async {
    final permission = Completer<VoiceRecorderPermission>();
    final recorder = _FakeRecorder(permissionCompleter: permission);
    final controller = MeetingCaptureController(
      recorder: recorder,
      localRecordingRepository: _repository(),
      recordingLibrary: _FakeLibrary(),
      recordingCard: _FakeCard(),
      uploader: _FakeUploader(),
    );
    try {
      final starting = controller.startLiveRecording();
      await tester.pump();
      controller.didChangeAppLifecycleState(AppLifecycleState.paused);
      permission.complete(
        const VoiceRecorderPermission(
          state: VoiceRecorderPermissionState.granted,
          canAskAgain: false,
        ),
      );
      await tester.pump();

      expect(controller.state.status, MeetingCaptureStatus.starting);
      expect(recorder.startCalls, 0);

      controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await tester.pump();
      expect(await starting, isTrue);
      expect(recorder.startCalls, 1);
      expect(controller.state.status, MeetingCaptureStatus.recording);
    } finally {
      controller.dispose();
    }
  });

  testWidgets('stale resume cannot start native capture in background', (
    tester,
  ) async {
    final permission = Completer<VoiceRecorderPermission>();
    final recorder = _FakeRecorder(permissionCompleter: permission);
    final controller = MeetingCaptureController(
      recorder: recorder,
      localRecordingRepository: _repository(),
      recordingLibrary: _FakeLibrary(),
      recordingCard: _FakeCard(),
      uploader: _FakeUploader(),
    );
    try {
      final starting = controller.startLiveRecording();
      await tester.pump();
      controller.didChangeAppLifecycleState(AppLifecycleState.paused);
      permission.complete(
        const VoiceRecorderPermission(
          state: VoiceRecorderPermissionState.granted,
          canAskAgain: false,
        ),
      );
      await tester.pump();
      expect(controller.state.status, MeetingCaptureStatus.starting);

      controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
      controller.didChangeAppLifecycleState(AppLifecycleState.paused);
      await tester.pump();
      expect(recorder.startCalls, 0);
      expect(controller.state.status, MeetingCaptureStatus.starting);

      controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await tester.pump();
      expect(await starting, isTrue);
      expect(recorder.startCalls, 1);
      expect(controller.state.status, MeetingCaptureStatus.recording);
    } finally {
      controller.dispose();
    }
  });

  testWidgets('snapshot reconciliation rejects another native session', (
    tester,
  ) async {
    final recorder = _FakeRecorder();
    final controller = MeetingCaptureController(
      recorder: recorder,
      localRecordingRepository: _repository(),
      recordingLibrary: _FakeLibrary(),
      recordingCard: _FakeCard(),
      uploader: _FakeUploader(),
    );
    try {
      expect(await controller.startLiveRecording(), isTrue);
      recorder.setActiveSnapshot(
        elapsedSeconds: 9,
        startedAt: DateTime.utc(2026, 7, 14, 9),
        recordingId: 'other-recording',
        scene: VoiceRecordingScene.monologue,
      );
      await tester.pump(const Duration(seconds: 1));

      expect(controller.state.status, MeetingCaptureStatus.failed);
      expect(controller.state.lastErrorCode, voiceRecorderSessionMismatchCode);
      expect(controller.state.projectsActiveMessage, isTrue);
      expect(recorder.cancelCalls, 0);
    } finally {
      controller.dispose();
    }
  });

  testWidgets('unexpected native idle remains an actionable journey', (
    tester,
  ) async {
    final recorder = _FakeRecorder();
    final controller = MeetingCaptureController(
      recorder: recorder,
      localRecordingRepository: _repository(),
      recordingLibrary: _FakeLibrary(),
      recordingCard: _FakeCard(),
      uploader: _FakeUploader(),
    );
    try {
      expect(await controller.startLiveRecording(), isTrue);
      recorder.setIdleSnapshot();
      await tester.pump(const Duration(seconds: 1));

      expect(controller.state.status, MeetingCaptureStatus.failed);
      expect(controller.state.lastErrorCode, 'MEETING_CAPTURE_INTERRUPTED');
      expect(controller.state.projectsActiveMessage, isTrue);
    } finally {
      controller.dispose();
    }
  });

  test(
    'durable: meeting opt-in survives failed enqueue and controller recreation',
    () async {
      final database = AppDatabase();
      final store = MeetingCaptureSessionStore(
        database: database,
        scope: 'account-a',
      );
      final repository = _repository();
      final uploader = _FakeUploader();
      final first = MeetingCaptureController(
        recorder: _FakeRecorder(),
        localRecordingRepository: repository,
        recordingLibrary: _FakeLibrary(repository: repository),
        recordingCard: _FakeCard(),
        uploader: uploader,
        sessionStore: store,
        onDistillationJobReady: (_, _) async => false,
      );
      await first.initialize();
      expect(
        await first.startLiveRecording(distillToDigitalTwin: true),
        isTrue,
      );
      expect(store.read()?.distillToDigitalTwin, isTrue);
      expect(await first.stop(), isFalse);
      expect(uploader.items, isEmpty);
      expect(store.read()?.draft, isNotNull);
      final localId = store.read()!.localRecordingId;
      first.dispose();
      final recorder = _FakeRecorder();
      final jobs = <String>[];
      final resumed = MeetingCaptureController(
        recorder: recorder,
        localRecordingRepository: repository,
        recordingLibrary: _FakeLibrary(repository: repository),
        recordingCard: _FakeCard(),
        uploader: uploader,
        sessionStore: MeetingCaptureSessionStore(
          database: database,
          scope: 'account-a',
        ),
        onDistillationJobReady: (jobId, _) async {
          jobs.add(jobId);
          return true;
        },
      );
      addTearDown(resumed.dispose);
      expect(resumed.beginFreshJourney(), isFalse);
      expect(await resumed.initialize(), MeetingCaptureEntryOutcome.restored);
      expect(recorder.startCalls, 0);
      expect(jobs.single, recordingFileJobId(repository.findById(localId!)!));
      expect(uploader.items.single.recordingId, localId);
      expect(store.read(), isNull);
      expect(resumed.state.status, MeetingCaptureStatus.completed);
    },
  );

  test(
    'durable: interrupted microphone intent never restarts recording automatically',
    () async {
      final database = AppDatabase();
      final store = MeetingCaptureSessionStore(
        database: database,
        scope: 'account-a',
      );
      await store.save(
        const MeetingCaptureCheckpoint(
          correlationId: 'interrupted',
          distillToDigitalTwin: true,
        ),
      );
      final recorder = _FakeRecorder();
      final controller = MeetingCaptureController(
        recorder: recorder,
        localRecordingRepository: _repository(),
        recordingLibrary: _FakeLibrary(),
        recordingCard: _FakeCard(),
        uploader: _FakeUploader(),
        sessionStore: store,
      );
      addTearDown(controller.dispose);
      expect(
        await controller.initialize(),
        MeetingCaptureEntryOutcome.restored,
      );
      expect(controller.state.lastErrorCode, 'MEETING_CAPTURE_INTERRUPTED');
      expect(recorder.startCalls, 0);
      expect(store.read()?.distillToDigitalTwin, isTrue);
      expect(
        MeetingCaptureSessionStore(
          database: database,
          scope: 'account-b',
        ).read(),
        isNull,
      );
    },
  );
  group('MeetingCaptureController', () {
    test(
      'captures live audio and hands one recording to the shared job',
      () async {
        final repository = _repository();
        final library = _FakeLibrary(repository: repository);
        final recorder = _FakeRecorder();
        final uploader = _FakeUploader();
        final controller = MeetingCaptureController(
          recorder: recorder,
          localRecordingRepository: repository,
          recordingLibrary: library,
          recordingCard: _FakeCard(),
          uploader: uploader,
          correlationIdFactory: () => 'meeting-trace-1',
        );
        addTearDown(controller.dispose);

        controller.waveform.addListener(() {});
        expect(await controller.startLiveRecording(), isTrue);
        expect(recorder.scene, VoiceRecordingScene.meeting);
        var businessNotifications = 0;
        controller.addListener(() => businessNotifications++);
        final beforeSample = controller.state;
        recorder.emitLevel(average: .4, peak: .8);
        await Future<void>.delayed(const Duration(milliseconds: 5));
        expect(controller.waveform.value, hasLength(68));
        expect(controller.waveform.value.last, greaterThan(0));
        expect(controller.state, same(beforeSample));
        expect(businessNotifications, 0);

        expect(await controller.pause(), isTrue);
        expect(recorder.hasLevelListeners, isFalse);
        recorder.emitLevel(average: .9, peak: 1);
        await Future<void>.delayed(const Duration(milliseconds: 5));
        expect(controller.waveform.value, everyElement(0));
        expect(await controller.resume(), isTrue);
        expect(recorder.hasLevelListeners, isTrue);
        recorder.emitLevel(average: .4, peak: .8);
        await Future<void>.delayed(const Duration(milliseconds: 5));
        expect(controller.waveform.value.last, greaterThan(0));
        expect(await controller.stop(), isTrue);

        expect(uploader.items, hasLength(1));
        expect(uploader.items.single.source, RecordingLibrarySource.microphone);
        expect(
          uploader.items.single.tagIds,
          contains(externalRecordingHistoryTagId),
        );
        expect(uploader.items.single.format, RecordingLibraryFormat.wav);
        expect(uploader.items.single.displayName, startsWith('外录-'));
        expect(uploader.items.single.displayName, endsWith('.wav'));
        expect(controller.state.status, MeetingCaptureStatus.completed);
        expect(controller.state.remoteRecordingId, 'remote-meeting-1');
        expect(controller.state.transcriptionJobId, isNotNull);
        expect(controller.state.correlationId, 'meeting-trace-1');
      },
    );

    test(
      'dispose while permission is pending never starts native capture',
      () async {
        final permission = Completer<VoiceRecorderPermission>();
        final recorder = _FakeRecorder(permissionCompleter: permission);
        final controller = MeetingCaptureController(
          recorder: recorder,
          localRecordingRepository: _repository(),
          recordingLibrary: _FakeLibrary(),
          recordingCard: _FakeCard(),
          uploader: _FakeUploader(),
        );

        final starting = controller.startLiveRecording();
        controller.dispose();
        permission.complete(
          const VoiceRecorderPermission(
            state: VoiceRecorderPermissionState.granted,
            canAskAgain: false,
          ),
        );

        expect(await starting, isFalse);
        expect(recorder.startCalls, 0);
        expect(recorder.cancelCalls, 0);
        expect(recorder.hasLevelListeners, isFalse);
      },
    );

    test('explicit leave during permission prevents native capture', () async {
      final permission = Completer<VoiceRecorderPermission>();
      final recorder = _FakeRecorder(permissionCompleter: permission);
      final controller = MeetingCaptureController(
        recorder: recorder,
        localRecordingRepository: _repository(),
        recordingLibrary: _FakeLibrary(),
        recordingCard: _FakeCard(),
        uploader: _FakeUploader(),
      );
      addTearDown(controller.dispose);

      final starting = controller.startLiveRecording();
      expect(await controller.endCaptureForLeave(), isTrue);
      permission.complete(
        const VoiceRecorderPermission(
          state: VoiceRecorderPermissionState.granted,
          canAskAgain: false,
        ),
      );

      expect(await starting, isTrue);
      expect(recorder.startCalls, 0);
      expect(controller.state.status, MeetingCaptureStatus.idle);
    });

    test(
      'dispose during native start cancels a late successful session',
      () async {
        final startGate = Completer<void>();
        final recorder = _FakeRecorder(startGate: startGate);
        final controller = MeetingCaptureController(
          recorder: recorder,
          localRecordingRepository: _repository(),
          recordingLibrary: _FakeLibrary(),
          recordingCard: _FakeCard(),
          uploader: _FakeUploader(),
        );

        final starting = controller.startLiveRecording();
        await Future<void>.delayed(Duration.zero);
        expect(recorder.startCalls, 1);
        controller.dispose();
        startGate.complete();

        expect(await starting, isFalse);
        expect(recorder.cancelCalls, 1);
        expect(recorder.hasLevelListeners, isFalse);
        await Future<void>.delayed(const Duration(milliseconds: 1100));
        expect(recorder.refreshCalls, 0);
      },
    );

    test('explicit leave closes a late native start', () async {
      final startGate = Completer<void>();
      final recorder = _FakeRecorder(startGate: startGate);
      final controller = MeetingCaptureController(
        recorder: recorder,
        localRecordingRepository: _repository(),
        recordingLibrary: _FakeLibrary(),
        recordingCard: _FakeCard(),
        uploader: _FakeUploader(),
      );
      addTearDown(controller.dispose);

      final starting = controller.startLiveRecording();
      await Future<void>.delayed(Duration.zero);
      expect(recorder.startCalls, 1);
      expect(await controller.endCaptureForLeave(), isTrue);
      startGate.complete();

      expect(await starting, isTrue);
      expect(recorder.cancelCalls, 1);
      expect(controller.state.status, MeetingCaptureStatus.idle);
    });

    test(
      'uploads a playable local recording through the meeting path',
      () async {
        final item = _item(id: 'local-meeting-1');
        final library = _FakeLibrary(seed: <RecordingLibraryItem>[item]);
        final uploader = _FakeUploader();
        final controller = MeetingCaptureController(
          recorder: _FakeRecorder(),
          localRecordingRepository: _repository(),
          recordingLibrary: library,
          recordingCard: _FakeCard(),
          uploader: uploader,
        );
        addTearDown(controller.dispose);

        await controller.initialize();
        expect(controller.localRecordings, <RecordingLibraryItem>[item]);
        expect(await controller.selectLocalRecording(item), isTrue);
        expect(uploader.items.single.recordingId, 'local-meeting-1');
        expect(controller.state.source, MeetingCaptureSource.localLibrary);
        expect(controller.state.status, MeetingCaptureStatus.completed);
        expect(controller.state.transcriptionJobId, isNotNull);
      },
    );

    test(
      'downloads a device-only file before uploading its local mapping',
      () async {
        final local = _item(
          id: 'downloaded-meeting-1',
          source: RecordingLibrarySource.device,
        );
        final library = _FakeLibrary();
        const file = RecordingCardScannedFile(
          deviceFileId: 'device-file-1',
          localFileKey: 'device-file-1.m4a',
          deviceFilename: '20260714093000',
          durationSeconds: 120,
          sizeBytes: 2048,
        );
        final card = _FakeCard(
          connected: true,
          files: <RecordingCardScannedFile>[file],
          onDownload: (_) {
            library.add(local);
            return RecordingCardDownloadedFile(
              localFileKey: file.localFileKey,
              localFileId: local.recordingId,
              appPrivateUri: local.appPrivateUri!,
            );
          },
        );
        final uploader = _FakeUploader();
        final controller = MeetingCaptureController(
          recorder: _FakeRecorder(),
          localRecordingRepository: _repository(),
          recordingLibrary: library,
          recordingCard: card,
          uploader: uploader,
        );
        addTearDown(controller.dispose);

        expect(await controller.selectRecordingCardFile(file), isTrue);
        expect(card.downloadCalls, 1);
        expect(uploader.items.single.recordingId, local.recordingId);
        expect(controller.state.source, MeetingCaptureSource.recordingCard);
      },
    );

    test(
      'fails closed for unavailable files and retries upload in place',
      () async {
        final invalid = _item(
          id: 'missing-meeting',
          localFileState: RecordingLocalFileState.missing,
        );
        final valid = _item(id: 'retry-meeting');
        final uploader = _FakeUploader(failuresBeforeSuccess: 1);
        final controller = MeetingCaptureController(
          recorder: _FakeRecorder(),
          localRecordingRepository: _repository(),
          recordingLibrary: _FakeLibrary(seed: <RecordingLibraryItem>[valid]),
          recordingCard: _FakeCard(),
          uploader: uploader,
        );
        addTearDown(controller.dispose);

        expect(await controller.selectLocalRecording(invalid), isFalse);
        expect(
          controller.state.lastErrorCode,
          'MEETING_LOCAL_RECORDING_UNAVAILABLE',
        );

        expect(await controller.selectLocalRecording(valid), isFalse);
        expect(controller.state.failureStage, MeetingFailureStage.upload);
        expect(controller.state.canRetry, isTrue);
        expect(await controller.retry(), isTrue);
        expect(uploader.items, hasLength(2));
        expect(controller.state.status, MeetingCaptureStatus.completed);
      },
    );

    test(
      'does not claim a device download while the card is disconnected',
      () async {
        const file = RecordingCardScannedFile(
          deviceFileId: 'device-file-2',
          localFileKey: 'device-file-2.m4a',
          deviceFilename: '20260714100000',
        );
        final card = _FakeCard(files: <RecordingCardScannedFile>[file]);
        final controller = MeetingCaptureController(
          recorder: _FakeRecorder(),
          localRecordingRepository: _repository(),
          recordingLibrary: _FakeLibrary(),
          recordingCard: card,
          uploader: _FakeUploader(),
        );
        addTearDown(controller.dispose);

        expect(await controller.selectRecordingCardFile(file), isFalse);
        expect(card.downloadCalls, 0);
        expect(
          controller.state.lastErrorCode,
          'MEETING_RECORDING_CARD_NOT_CONNECTED',
        );
      },
    );

    test('legacy material recovery ids are unavailable', () async {
      final controller = MeetingCaptureController(
        recorder: _FakeRecorder(),
        localRecordingRepository: _repository(),
        recordingLibrary: _FakeLibrary(),
        recordingCard: _FakeCard(),
        uploader: _FakeUploader(),
      );
      addTearDown(controller.dispose);

      expect(controller.beginFreshJourney(), isTrue);
      expect(
        await controller.initialize(restorePending: false),
        MeetingCaptureEntryOutcome.ready,
      );
      expect(controller.state.status, MeetingCaptureStatus.idle);

      expect(
        await controller.initialize(
          recoveryDraftId: 'meeting-remote-requested',
        ),
        MeetingCaptureEntryOutcome.unavailable,
      );
    });

    test('fresh reset cannot steal a pending permission journey', () async {
      final permission = Completer<VoiceRecorderPermission>();
      final recorder = _FakeRecorder(permissionCompleter: permission);
      final controller = MeetingCaptureController(
        recorder: recorder,
        localRecordingRepository: _repository(),
        recordingLibrary: _FakeLibrary(),
        recordingCard: _FakeCard(),
        uploader: _FakeUploader(),
      );
      addTearDown(controller.dispose);

      final starting = controller.startLiveRecording();
      await Future<void>.delayed(Duration.zero);
      expect(controller.state.status, MeetingCaptureStatus.checkingPermission);
      expect(controller.beginFreshJourney(), isFalse);
      permission.complete(
        const VoiceRecorderPermission(
          state: VoiceRecorderPermissionState.granted,
          canAskAgain: false,
        ),
      );

      expect(await starting, isTrue);
      expect(controller.state.status, MeetingCaptureStatus.recording);
    });
  });
}

LocalRecordingRepository _repository() => LocalRecordingRepository(
  database: AppDatabase(),
  fileStorage: const _FileStorage(),
);

RecordingLibraryItem _item({
  required String id,
  RecordingLibrarySource source = RecordingLibrarySource.localImport,
  RecordingLocalFileState localFileState = RecordingLocalFileState.ready,
}) {
  return RecordingLibraryItem(
    recordingId: id,
    source: source,
    displayName: '$id.m4a',
    format: RecordingLibraryFormat.m4a,
    localFileState: localFileState,
    status: RecordingLibraryStatus.localOnly,
    durationSeconds: 120,
    sizeBytes: 2048,
    isFavorite: false,
    tagIds: const <String>[],
    createdAt: DateTime.utc(2026, 7, 14, 9),
    updatedAt: DateTime.utc(2026, 7, 14, 9),
    appPrivateUri: 'app-private://$id.m4a',
  );
}

final class _NoNetworkTransport implements ApiTransport, ObjectUploadTransport {
  const _NoNetworkTransport();

  @override
  Future<ApiTransportResponse> send(ApiTransportRequest request) =>
      throw StateError('Unexpected API request');

  @override
  Future<ObjectUploadResult> upload(ObjectUploadRequest request) =>
      throw StateError('Unexpected object upload');
}

final class _FakeRecorder
    implements VoiceRecorderPort, VoiceRecorderLevelSource {
  _FakeRecorder({this.permissionCompleter, this.startGate});

  final Completer<VoiceRecorderPermission>? permissionCompleter;
  final Completer<void>? startGate;
  final StreamController<VoiceLevelSample> _levels =
      StreamController<VoiceLevelSample>.broadcast();
  VoiceRecorderSnapshot _snapshot = const VoiceRecorderSnapshot.idle();
  VoiceRecordingScene? scene;
  int startCalls = 0;
  int pauseCalls = 0;
  int stopCalls = 0;
  int cancelCalls = 0;
  int refreshCalls = 0;
  String? pauseFailureCode;
  String? resumeFailureCode;
  String? stopFailureCode;
  String? cancelFailureCode;
  Completer<VoiceRecorderResult<VoiceRecorderSnapshot>>? pauseResult;
  Completer<VoiceRecorderResult<VoiceRecordingDraft>>? stopResult;
  Completer<VoiceRecorderResult<VoiceRecorderSnapshot>>? cancelResult;
  Completer<VoiceRecorderResult<VoiceRecorderSnapshot>>? refreshResult;

  bool get hasLevelListeners => _levels.hasListener;

  @override
  VoiceRecorderSnapshot get snapshot => _snapshot;

  @override
  Stream<VoiceLevelSample> get levelSamples => _levels.stream;

  void emitLevel({required double average, required double peak}) {
    _levels.add(
      VoiceLevelSample(
        capturedAt: DateTime.utc(2026, 7, 14, 9),
        average: average,
        peak: peak,
      ),
    );
  }

  void setActiveSnapshot({
    required int elapsedSeconds,
    required DateTime startedAt,
    String recordingId = 'voice-meeting-1',
    VoiceRecordingScene scene = VoiceRecordingScene.meeting,
  }) {
    _snapshot = VoiceRecorderSnapshot(
      state: VoiceRecorderState.recording,
      session: _session(
        VoiceRecorderState.recording,
        elapsedSeconds: elapsedSeconds,
        startedAt: startedAt,
        recordingId: recordingId,
        sessionScene: scene,
      ),
    );
  }

  void setIdleSnapshot() {
    _snapshot = const VoiceRecorderSnapshot.idle();
  }

  void setSnapshot(VoiceRecorderSnapshot snapshot) {
    _snapshot = snapshot;
  }

  VoiceRecordingSession session(VoiceRecorderState state) => _session(state);

  @override
  Future<VoiceRecorderResult<VoiceRecorderPermission>>
  getMicrophonePermission() async {
    final pending = permissionCompleter;
    if (pending != null) {
      return VoiceRecorderResult.success(await pending.future);
    }
    return VoiceRecorderResult.success(
      const VoiceRecorderPermission(
        state: VoiceRecorderPermissionState.granted,
        canAskAgain: false,
      ),
    );
  }

  @override
  Future<VoiceRecorderResult<VoiceRecorderPermission>>
  requestMicrophonePermission() => getMicrophonePermission();

  @override
  Future<VoiceRecorderResult<VoiceRecordingSession>> startRecording({
    required VoiceRecordingScene scene,
  }) async {
    startCalls += 1;
    this.scene = scene;
    final gate = startGate;
    if (gate != null) await gate.future;
    final session = _session(VoiceRecorderState.recording);
    _snapshot = VoiceRecorderSnapshot(
      state: VoiceRecorderState.recording,
      session: session,
    );
    return VoiceRecorderResult.success(session);
  }

  @override
  Future<VoiceRecorderResult<VoiceRecorderSnapshot>> pauseRecording() async {
    pauseCalls += 1;
    final pending = pauseResult;
    if (pending != null) {
      pauseResult = null;
      return pending.future;
    }
    final failureCode = pauseFailureCode;
    if (failureCode != null) {
      return VoiceRecorderResult.failure(voiceRecorderFailure(failureCode));
    }
    _snapshot = VoiceRecorderSnapshot(
      state: VoiceRecorderState.paused,
      session: _session(VoiceRecorderState.paused),
    );
    return VoiceRecorderResult.success(_snapshot);
  }

  @override
  Future<VoiceRecorderResult<VoiceRecorderSnapshot>> resumeRecording() async {
    final failureCode = resumeFailureCode;
    if (failureCode != null) {
      return VoiceRecorderResult.failure(voiceRecorderFailure(failureCode));
    }
    _snapshot = VoiceRecorderSnapshot(
      state: VoiceRecorderState.recording,
      session: _session(VoiceRecorderState.recording),
    );
    return VoiceRecorderResult.success(_snapshot);
  }

  @override
  Future<VoiceRecorderResult<VoiceRecorderSnapshot>> refreshState() async {
    refreshCalls += 1;
    final pending = refreshResult;
    if (pending != null) return pending.future;
    return VoiceRecorderResult.success(_snapshot);
  }

  @override
  Future<VoiceRecorderResult<VoiceRecordingDraft>> stopRecording() async {
    stopCalls += 1;
    final pending = stopResult;
    if (pending != null) {
      stopResult = null;
      return pending.future;
    }
    final failureCode = stopFailureCode;
    if (failureCode != null) {
      return VoiceRecorderResult.failure(voiceRecorderFailure(failureCode));
    }
    _snapshot = const VoiceRecorderSnapshot.idle();
    return VoiceRecorderResult.success(
      VoiceRecordingDraft(
        recordingId: 'voice-meeting-1',
        appPrivateUri: 'app-private://voice-meeting-1.wav',
        fileName: 'source.wav',
        mimeType: 'audio/wav',
        sizeBytes: 2048,
        durationSeconds: 120,
        sha256:
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        scene: VoiceRecordingScene.meeting,
        sampleRateHz: 16000,
        bitDepth: 16,
        channelCount: 1,
        recordedAt: DateTime.utc(2026, 7, 14, 9),
      ),
    );
  }

  @override
  Future<VoiceRecorderResult<VoiceRecorderSnapshot>> cancelRecording() async {
    cancelCalls += 1;
    final pending = cancelResult;
    if (pending != null) {
      cancelResult = null;
      return pending.future;
    }
    final failureCode = cancelFailureCode;
    if (failureCode != null) {
      return VoiceRecorderResult.failure(voiceRecorderFailure(failureCode));
    }
    _snapshot = const VoiceRecorderSnapshot.idle();
    return VoiceRecorderResult.success(_snapshot);
  }

  VoiceRecordingSession _session(
    VoiceRecorderState state, {
    int elapsedSeconds = 3,
    DateTime? startedAt,
    String recordingId = 'voice-meeting-1',
    VoiceRecordingScene? sessionScene,
  }) => VoiceRecordingSession(
    recordingId: recordingId,
    scene: sessionScene ?? scene ?? VoiceRecordingScene.meeting,
    state: state,
    startedAt: startedAt ?? DateTime.utc(2026, 7, 14, 9),
    elapsedSeconds: elapsedSeconds,
  );
}

final class _FakeLibrary implements MeetingRecordingLibraryPort {
  _FakeLibrary({
    this.repository,
    List<RecordingLibraryItem> seed = const <RecordingLibraryItem>[],
  }) : _items = List<RecordingLibraryItem>.of(seed);

  final LocalRecordingRepository? repository;
  final List<VoidCallback> _listeners = <VoidCallback>[];
  List<RecordingLibraryItem> _items;

  @override
  List<RecordingLibraryItem> get items => List.unmodifiable(_items);

  void add(RecordingLibraryItem item) {
    _items = <RecordingLibraryItem>[
      ..._items.where((candidate) => candidate.recordingId != item.recordingId),
      item,
    ];
  }

  @override
  Future<void> load() async {
    final repository = this.repository;
    if (repository != null) _items = repository.list().rows;
    for (final listener in List<VoidCallback>.of(_listeners)) {
      listener();
    }
  }

  @override
  void addListener(VoidCallback listener) => _listeners.add(listener);

  @override
  void removeListener(VoidCallback listener) => _listeners.remove(listener);
}

final class _FakeCard implements MeetingRecordingCardPort {
  _FakeCard({
    this.connected = false,
    this.files = const <RecordingCardScannedFile>[],
    this.onDownload,
  });

  final bool connected;
  @override
  final List<RecordingCardScannedFile> files;
  final RecordingCardDownloadedFile? Function(RecordingCardScannedFile file)?
  onDownload;
  final List<VoidCallback> _listeners = <VoidCallback>[];
  int downloadCalls = 0;

  @override
  bool get isConnected => connected;

  @override
  String? get lastErrorCode => null;

  @override
  Future<void> scanFiles() async {}

  @override
  Future<RecordingCardResult<RecordingCardDownloadedFile>> downloadFile(
    RecordingCardScannedFile file,
  ) async {
    downloadCalls += 1;
    final downloaded = onDownload?.call(file);
    for (final listener in List<VoidCallback>.of(_listeners)) {
      listener();
    }
    if (downloaded != null) {
      return RecordingCardResult<RecordingCardDownloadedFile>.success(
        downloaded,
      );
    }
    return RecordingCardResult<RecordingCardDownloadedFile>.failure(
      recordingCardFailure(
        'MEETING_DEVICE_DOWNLOAD_FAILED',
        'Fake recording-card download failed',
      ),
    );
  }

  @override
  void addListener(VoidCallback listener) => _listeners.add(listener);

  @override
  void removeListener(VoidCallback listener) => _listeners.remove(listener);
}

final class _FakeUploader implements MeetingRecordingUploadPort {
  _FakeUploader({this.failuresBeforeSuccess = 0});

  final int failuresBeforeSuccess;
  final List<RecordingLibraryItem> items = <RecordingLibraryItem>[];

  @override
  Future<MeetingUploadResult> upload(RecordingLibraryItem item) async {
    items.add(item);
    if (items.length <= failuresBeforeSuccess) {
      return MeetingUploadResult.failure('MEETING_UPLOAD_FAILED');
    }
    return MeetingUploadResult.success('remote-meeting-1');
  }
}

final class _FileStorage extends UnavailableFileStoragePort {
  const _FileStorage();

  @override
  Future<FileStorageResult<PrivateAudioFileStat>> statPrivateAudio(
    String appPrivateUri,
  ) async => FileStorageResult.success(
    const PrivateAudioFileStat(exists: true, sizeBytes: 2048),
  );
}
