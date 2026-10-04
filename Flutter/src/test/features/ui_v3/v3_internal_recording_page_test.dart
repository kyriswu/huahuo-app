import 'dart:async';
import 'dart:convert';

import 'package:huahuo_api/huahuo_api.dart';
import 'package:crypto/crypto.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/app/bootstrap/app_providers.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/native/screen_capture_port.dart';
import 'package:huahuoai_app/features/ingestion/data/internal_recording_session_store.dart';
import 'package:huahuoai_app/features/ingestion/domain/material_ingestion.dart';
import 'package:huahuoai_app/core/storage/file_storage_port.dart';
import 'package:huahuoai_app/core/storage/upload_draft_store.dart';
import 'package:huahuoai_app/features/ingestion/application/internal_recording_controller.dart';
import 'package:huahuoai_app/features/recordings/application/recording_upload_controller.dart';
import 'package:huahuoai_app/features/recordings/data/local_recording_repository.dart';
import 'package:huahuoai_app/features/recordings/data/recording_api.dart';
import 'package:huahuoai_app/features/recordings/domain/recording_library.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_internal_recording_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'stop acknowledgment waits for finalized video before extraction',
    () async {
      final fixture = _fixture();
      addTearDown(fixture.close);
      await fixture.controller.start();
      fixture.capture.recording();
      await _until(() => fixture.controller.state.isRecording);
      fixture.capture.stopAcknowledgesOnly = true;
      expect(await fixture.controller.stop(), isTrue);
      expect(fixture.controller.state.status, InternalRecordingStatus.stopping);
      expect(
        fixture.store.read()?.stage,
        InternalRecordingCheckpointStage.stopping,
      );
      expect(fixture.capture.extractions, 0);
      expect(fixture.objectTransport.requests, isEmpty);
      fixture.capture.complete();
      await _until(
        () =>
            fixture.controller.state.status ==
            InternalRecordingStatus.completed,
      );
      expect(fixture.capture.extractions, 1);
      expect(fixture.objectTransport.requests, hasLength(1));
    },
  );

  test('late stop error cannot revive cancelled consent', () async {
    final fixture = _fixture();
    addTearDown(fixture.close);
    await fixture.controller.start();
    final gate = Completer<ScreenCaptureResult<ScreenCaptureSnapshot>>();
    fixture.capture.stopResult = gate;
    final stopping = fixture.controller.stop();
    await _until(() => fixture.capture.stops == 1);
    fixture.capture.emit(
      ScreenCaptureSnapshot(
        state: ScreenCaptureState.failed,
        sessionId: fixture.capture.activeSession,
        elapsedSeconds: 0,
        lastErrorCode: 'SCREEN_CAPTURE_CONSENT_CANCELLED',
      ),
    );
    await _until(
      () =>
          fixture.controller.state.status == InternalRecordingStatus.cancelled,
    );
    gate.complete(
      ScreenCaptureResult.failure(
        recordingApiFailure('SCREEN_CAPTURE_STOP_FAILED'),
      ),
    );
    expect(await stopping, isTrue);
    expect(fixture.controller.state.status, InternalRecordingStatus.cancelled);
    expect(fixture.capture.extractions, 0);
    expect(fixture.objectTransport.requests, isEmpty);
  });

  test(
    'capture stages are durable and late consent cannot reopen authorization',
    () async {
      final fixture = _fixture();
      addTearDown(fixture.close);
      expect(await fixture.controller.start(), isTrue);
      expect(
        fixture.store.read()?.stage,
        InternalRecordingCheckpointStage.awaitingConsent,
      );
      fixture.capture.recording();
      await _until(
        () =>
            fixture.store.read()?.stage ==
            InternalRecordingCheckpointStage.recording,
      );
      fixture.capture._events.add(
        ScreenCaptureSnapshot(
          state: ScreenCaptureState.starting,
          elapsedSeconds: 0,
          sessionId: fixture.capture.activeSession,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(
        fixture.controller.state.status,
        InternalRecordingStatus.recording,
      );
      expect(fixture.controller.state.elapsedSeconds, 12);
      expect(await fixture.controller.stop(), isTrue);
      await _until(
        () =>
            fixture.controller.state.status ==
            InternalRecordingStatus.completed,
      );
      expect(
        fixture.store.read()?.stage,
        InternalRecordingCheckpointStage.completed,
      );
      expect(fixture.capture.extractions, 1);
      expect(fixture.objectTransport.requests, hasLength(1));
    },
  );

  test('late refresh cannot overwrite a newer capture event', () async {
    final fixture = _fixture();
    addTearDown(fixture.close);
    await fixture.controller.start();
    final previous = fixture.capture.snapshot;
    final gate = Completer<ScreenCaptureResult<ScreenCaptureSnapshot>>();
    fixture.capture.recoveryResult = gate;
    final refresh = fixture.controller.refreshSession();
    fixture.capture.recording();
    await Future<void>.delayed(Duration.zero);
    gate.complete(ScreenCaptureResult.success(previous));
    await refresh;
    expect(fixture.controller.state.status, InternalRecordingStatus.recording);
    expect(fixture.controller.state.elapsedSeconds, 12);
  });

  test(
    'thrown stop preserves capture controls and can finalize on retry',
    () async {
      final fixture = _fixture();
      addTearDown(fixture.close);
      await fixture.controller.start();
      fixture.capture.recording();
      await _until(() => fixture.controller.state.isRecording);
      fixture.capture.stopThrows = true;
      expect(await fixture.controller.stop(), isFalse);
      expect(
        fixture.controller.state.status,
        InternalRecordingStatus.recording,
      );
      expect(
        fixture.controller.state.lastErrorCode,
        'SCREEN_CAPTURE_STOP_FAILED',
      );
      fixture.capture.stopThrows = false;
      expect(await fixture.controller.stop(), isTrue);
      await _until(
        () =>
            fixture.controller.state.status ==
            InternalRecordingStatus.completed,
      );
      expect(fixture.objectTransport.requests, hasLength(1));
    },
  );

  test(
    'durable: restored internal media enqueues its saved opt-in without a page',
    () async {
      final database = AppDatabase();
      final store = InternalRecordingSessionStore(
        database: database,
        ownerScope: 'user-a',
      );
      await store.save(
        InternalRecordingCheckpoint(
          sessionId: 'opted-in-session',
          startedAt: _media.recordedAt,
          media: _media,
          distillToDigitalTwin: true,
        ),
      );
      final jobs = <String>[];
      final fixture = _fixture(
        database: database,
        onDistillationJobReady: (jobId, _) async {
          jobs.add(jobId);
          return true;
        },
      );
      addTearDown(fixture.close);
      await fixture.controller.initialize();
      await _until(
        () =>
            fixture.controller.state.status ==
            InternalRecordingStatus.completed,
      );
      expect(jobs.single, fixture.controller.state.transcriptionJobId);
      expect(store.read()?.distillToDigitalTwin, isTrue);
      expect(store.read()?.handedOff, isTrue);
    },
  );

  test(
    'persisted discard resumes cleanup rather than audio processing',
    () async {
      final database = AppDatabase();
      final store = InternalRecordingSessionStore(
        database: database,
        ownerScope: 'user-a',
      );
      await store.save(
        InternalRecordingCheckpoint(
          sessionId: 'discarded-session',
          startedAt: _media.recordedAt,
          media: _media,
          discardRequested: true,
        ),
      );
      final fixture = _fixture(database: database);
      addTearDown(fixture.close);
      await fixture.controller.initialize();
      expect(fixture.controller.state.status, InternalRecordingStatus.idle);
      expect(fixture.capture.released, ['discarded-session']);
      expect(fixture.capture.extractions, 0);
      expect(fixture.objectTransport.requests, isEmpty);
      expect(store.read(), isNull);
    },
  );

  test(
    'recovers an old account session without adopting the current capture',
    () async {
      final database = AppDatabase();
      final store = InternalRecordingSessionStore(
        database: database,
        ownerScope: 'user-a',
      );
      await store.save(
        InternalRecordingCheckpoint(
          sessionId: 'old-session',
          startedAt: _media.recordedAt,
        ),
      );
      final capture = _ScreenCapture();
      capture.complete(sessionId: 'old-session');
      capture.activeSession = 'another-account';
      capture.recording();
      final fixture = _fixture(database: database, capturePort: capture);
      addTearDown(fixture.close);
      await fixture.controller.initialize();
      await _until(
        () =>
            fixture.controller.state.status ==
            InternalRecordingStatus.completed,
      );
      expect(capture.snapshot.sessionId, 'another-account');
      expect(capture.stops, 0);
      expect(capture.released, ['old-session']);
      expect(fixture.objectTransport.requests, hasLength(1));
    },
  );

  test(
    'unsupported playback capture still imports and hands off video audio',
    () async {
      final fixture = _fixture(supported: false);
      addTearDown(fixture.close);
      expect(await fixture.controller.importVideo(), isTrue);
      await _until(
        () =>
            fixture.controller.state.status ==
            InternalRecordingStatus.completed,
      );
      expect(fixture.capture.starts, 0);
      expect(fixture.capture.extractions, 1);
      expect(fixture.capture.released, hasLength(1));
      expect(fixture.objectTransport.requests, hasLength(1));
    },
  );

  test('cleanup retries never repeat successful upload', () async {
    final fixture = _fixture();
    addTearDown(fixture.close);
    fixture.capture.releaseFails = true;
    await fixture.controller.start();
    fixture.capture.complete();
    await _until(
      () => fixture.controller.state.status == InternalRecordingStatus.failed,
    );
    expect(
      fixture.controller.state.failureStage,
      InternalRecordingFailureStage.cleanup,
    );
    expect(fixture.store.read()?.handedOff, isTrue);
    expect(fixture.controller.beginFreshJourney(), isFalse);
    fixture.capture.releaseFails = false;
    fixture.capture.releaseThrows = true;
    expect(await fixture.controller.retry(), isFalse);
    expect(
      fixture.controller.state.failureStage,
      InternalRecordingFailureStage.cleanup,
    );
    expect(fixture.controller.beginFreshJourney(), isFalse);
    fixture.capture.releaseThrows = false;
    expect(await fixture.controller.retry(), isTrue);
    expect(fixture.objectTransport.requests, hasLength(1));
    expect(fixture.capture.extractions, 1);
  });

  test(
    'corrupt checkpoint can be quarantined without deleting captured files',
    () async {
      final database = AppDatabase();
      final key = 'internal-capture:${sha256.convert(utf8.encode('user-a'))}';
      database.upsertCheckpointRecord(
        LocalTableName.localRecordingRecoveryCheckpoints,
        key,
        <String, Object?>{'checkpoint_id': key, 'version': -1},
      );
      final fixture = _fixture(database: database);
      addTearDown(fixture.close);
      await fixture.controller.initialize();
      expect(fixture.controller.canResetCheckpoint, isTrue);
      expect(await fixture.controller.discardAndReset(), isTrue);
      expect(fixture.store.read(), isNull);
      expect(fixture.capture.released, isEmpty);
      expect(await fixture.controller.start(), isTrue);
    },
  );

  test(
    'system completion extracts audio and creates only one durable job',
    () async {
      final fixture = _fixture();
      addTearDown(fixture.close);
      expect(await fixture.controller.start(), isTrue);
      expect(
        fixture.controller.state.status,
        InternalRecordingStatus.awaitingConsent,
      );
      fixture.capture.recording();
      await _until(() => fixture.controller.state.isRecording);
      fixture.capture.complete();
      fixture.capture.complete();
      await _until(
        () =>
            fixture.controller.state.status ==
            InternalRecordingStatus.completed,
      );
      expect(fixture.capture.extractions, 1);
      expect(
        fixture.repository.list().rows.single.tagIds,
        contains(internalRecordingHistoryTagId),
      );
      expect(fixture.objectTransport.requests.single.mimeType, 'audio/mp4');
      final create =
          jsonDecode(fixture.apiTransport.requests.last.body!) as Map;
      expect(create['source'], 'internal_recording');
      expect(fixture.controller.hasDurableJob, isTrue);
      fixture.capture.complete();
      await Future<void>.delayed(Duration.zero);
      expect(fixture.objectTransport.requests, hasLength(1));
    },
  );

  test('consent cancellation never extracts or uploads', () async {
    final fixture = _fixture();
    addTearDown(fixture.close);
    await fixture.controller.start();
    expect(await fixture.controller.cancel(), isTrue);
    expect(fixture.controller.state.status, InternalRecordingStatus.cancelled);
    expect(fixture.capture.extractions, 0);
    expect(fixture.apiTransport.requests, isEmpty);
    expect(await fixture.controller.start(), isTrue);
    expect(fixture.capture.starts, 2);
  });

  test('unrelated and historical completions cannot be adopted', () async {
    final fixture = _fixture();
    addTearDown(fixture.close);
    fixture.capture.complete(sessionId: 'historical-other-account');
    await fixture.controller.initialize();
    expect(fixture.capture.extractions, 0);
    await fixture.controller.start();
    fixture.capture.emit(
      ScreenCaptureSnapshot(
        state: ScreenCaptureState.completed,
        elapsedSeconds: 12,
        sessionId: 'another-session',
        media: _media,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(fixture.capture.extractions, 0);
    expect(
      fixture.controller.state.status,
      InternalRecordingStatus.awaitingConsent,
    );
  });

  test(
    'extraction failure retains the MP4 and retry does not recapture',
    () async {
      final fixture = _fixture();
      addTearDown(fixture.close);
      fixture.capture.extractionFails = true;
      await fixture.controller.start();
      fixture.capture.complete();
      await _until(
        () => fixture.controller.state.status == InternalRecordingStatus.failed,
      );
      expect(
        fixture.controller.state.failureStage,
        InternalRecordingFailureStage.extraction,
      );
      expect(fixture.controller.beginFreshJourney(), isFalse);
      expect(fixture.store.read()?.media?.appPrivateUri, _media.appPrivateUri);
      fixture.capture.extractionFails = false;
      expect(await fixture.controller.retry(), isTrue);
      expect(fixture.capture.starts, 1);
      expect(fixture.capture.extractions, 2);
      expect(fixture.objectTransport.requests, hasLength(1));
    },
  );

  test(
    'handoff without a durable draft retries the same local audio',
    () async {
      final fixture = _fixture(workspaceAvailable: false);
      addTearDown(fixture.close);
      await fixture.controller.start();
      fixture.capture.complete();
      await _until(
        () => fixture.controller.state.status == InternalRecordingStatus.failed,
      );
      expect(
        fixture.controller.state.failureStage,
        InternalRecordingFailureStage.handoff,
      );
      expect(fixture.controller.hasDurableJob, isFalse);
      final jobId = fixture.controller.state.transcriptionJobId;
      fixture.workspace.value = 'workspace-internal-test';
      expect(await fixture.controller.retry(), isTrue);
      expect(fixture.controller.state.transcriptionJobId, jobId);
      expect(fixture.repository.list().rows, hasLength(1));
      expect(fixture.capture.extractions, 1);
    },
  );

  test(
    'retained checkpoint resumes processing after controller recreation',
    () async {
      final database = AppDatabase();
      final store = InternalRecordingSessionStore(
        database: database,
        ownerScope: 'user-a',
      );
      await store.save(
        InternalRecordingCheckpoint(
          sessionId: 'internal-recovered',
          startedAt: _media.recordedAt,
          media: _media,
        ),
      );
      final fixture = _fixture(database: database);
      addTearDown(fixture.close);
      await fixture.controller.initialize();
      await _until(
        () =>
            fixture.controller.state.status ==
            InternalRecordingStatus.completed,
      );
      expect(fixture.capture.starts, 0);
      expect(fixture.capture.extractions, 1);
      expect(store.read()?.handedOff, isTrue);
      expect(
        InternalRecordingSessionStore(
          database: database,
          ownerScope: 'user-b',
        ).read(),
        isNull,
      );
    },
  );

  test('unsupported OS never invokes capture', () async {
    final fixture = _fixture(supported: false);
    addTearDown(fixture.close);
    await fixture.controller.initialize();
    expect(
      fixture.controller.state.status,
      InternalRecordingStatus.unsupported,
    );
    expect(await fixture.controller.start(), isFalse);
    expect(fixture.capture.starts, 0);
  });

  testWidgets(
    'leaving the page preserves screen recording and removes pause UI',
    (tester) async {
      final fixture = _fixture();
      await fixture.controller.start();
      fixture.capture.recording();
      await tester.pumpWidget(_routeApp(fixture.controller));
      await tester.tap(find.byKey(const ValueKey('open-internal-recording')));
      await tester.pumpAndSettle();
      expect(find.text('正在内录'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('internal-recording-pause-resume')),
        findsNothing,
      );
      Navigator.of(tester.element(find.text('正在内录'))).pop();
      await tester.pumpAndSettle();
      expect(fixture.controller.state.isRecording, isTrue);
      expect(fixture.capture.stops, 0);
      await tester.pumpWidget(const SizedBox.shrink());
      await fixture.capture.close();
      fixture.uploadController.dispose();
    },
  );

  testWidgets(
    'unsupported screen explains compatibility without microphone fallback',
    (tester) async {
      final fixture = _fixture(supported: false);
      await tester.pumpWidget(_pageApp(fixture.controller));
      await tester.pumpAndSettle();
      expect(find.text('导入已有录音'), findsOneWidget);
      expect(find.textContaining('当前版本无法'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('internal-recording-import-video')),
        findsOneWidget,
      );
      expect(find.text('开始内录'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await fixture.capture.close();
      fixture.uploadController.dispose();
    },
  );
}

Future<void> _until(bool Function() predicate) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (predicate()) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(predicate(), isTrue, reason: 'screen capture journey did not settle');
}

Widget _pageApp(InternalRecordingController controller) {
  return ProviderScope(
    overrides: <Override>[
      internalRecordingControllerProvider.overrideWith((ref) => controller),
    ],
    child: const MaterialApp(home: V3InternalRecordingPage()),
  );
}

Widget _routeApp(InternalRecordingController controller) {
  return ProviderScope(
    overrides: <Override>[
      internalRecordingControllerProvider.overrideWith((ref) => controller),
    ],
    child: MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              key: const ValueKey('open-internal-recording'),
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (_) => const V3InternalRecordingPage(),
                ),
              ),
              child: const Text('打开内录'),
            ),
          ),
        ),
      ),
    ),
  );
}

final class _Fixture {
  _Fixture({
    required this.controller,
    required this.capture,
    required this.repository,
    required this.store,
    required this.uploadController,
    required this.apiTransport,
    required this.objectTransport,
    required this.workspace,
  });
  final InternalRecordingController controller;
  final _ScreenCapture capture;
  final LocalRecordingRepository repository;
  final InternalRecordingSessionStore store;
  final RecordingUploadController uploadController;
  final _UploadApiTransport apiTransport;
  final _ObjectTransport objectTransport;
  final _MutableWorkspace workspace;

  Future<void> close() async {
    controller.dispose();
    await capture.close();
    uploadController.dispose();
  }
}

_Fixture _fixture({
  AppDatabase? database,
  Future<bool> Function(String jobId, String title)? onDistillationJobReady,
  bool workspaceAvailable = true,
  bool supported = true,
  _ScreenCapture? capturePort,
}) {
  final storage = database ?? AppDatabase();
  final repository = LocalRecordingRepository(
    database: storage,
    fileStorage: const _FileStorage(),
  );
  final apiTransport = _UploadApiTransport();
  final objectTransport = _ObjectTransport();
  final workspace = _MutableWorkspace(
    workspaceAvailable ? 'workspace-internal-test' : null,
  );
  final apiClient = ApiClient(
    config: ApiClientConfig(
      baseUrl: Uri.parse('https://api.example.test'),
      clientVersion: 'test',
      deviceId: 'test-device',
      platform: 'ios',
      locale: 'zh-CN',
      getAccessToken: () => 'test-token',
    ),
    transport: apiTransport,
  );
  final uploadController = RecordingUploadController(
    uploadClient: UploadClient(
      apiClient: apiClient,
      objectTransport: objectTransport,
    ),
    draftStore: UploadDraftStore(database: storage),
    recordingApi: RecordingApi(apiClient: apiClient),
    localRecordingRepository: repository,
    activeWorkspaceId: () => workspace.value,
  );
  final capture = capturePort ?? _ScreenCapture(supported: supported);
  final store = InternalRecordingSessionStore(
    database: storage,
    ownerScope: 'user-a',
  );
  return _Fixture(
    controller: InternalRecordingController(
      onDistillationJobReady: onDistillationJobReady,
      capture: capture,
      sessionStore: store,
      localRecordingRepository: repository,
      uploadController: uploadController,
    ),
    capture: capture,
    repository: repository,
    store: store,
    uploadController: uploadController,
    apiTransport: apiTransport,
    objectTransport: objectTransport,
    workspace: workspace,
  );
}

final class _MutableWorkspace {
  _MutableWorkspace(this.value);
  String? value;
}

final _media = CapturedMediaInput(
  appPrivateUri: 'app-private-media://screen-capture/capture-test.mp4',
  fileName: 'capture-test.mp4',
  mimeType: 'video/mp4',
  sizeBytes: 4096,
  durationSeconds: 12,
  sha256: List.filled(64, 'b').join(),
  recordedAt: DateTime.utc(2026, 9, 5),
);

final class _ScreenCapture implements ScreenCapturePort {
  _ScreenCapture({this.supported = true});
  final bool supported;
  final _events = StreamController<ScreenCaptureSnapshot>.broadcast();
  ScreenCaptureSnapshot snapshot = const ScreenCaptureSnapshot.idle();
  String? activeSession;
  int starts = 0;
  int stops = 0;
  int extractions = 0;
  bool extractionFails = false;
  bool releaseFails = false;
  bool releaseThrows = false;
  bool stopThrows = false;
  bool stopAcknowledgesOnly = false;
  Completer<ScreenCaptureResult<ScreenCaptureSnapshot>>? stopResult;
  Completer<ScreenCaptureResult<ScreenCaptureSnapshot>>? recoveryResult;
  final journal = <String, ScreenCaptureSnapshot>{};
  final released = <String>[];

  void emit(ScreenCaptureSnapshot value) {
    snapshot = value;
    if (value.sessionId != null) journal[value.sessionId!] = value;
    if (!_events.isClosed) _events.add(value);
  }

  void recording() => emit(
    ScreenCaptureSnapshot(
      state: ScreenCaptureState.recording,
      elapsedSeconds: 12,
      sessionId: activeSession,
      startedAt: _media.recordedAt,
    ),
  );
  void complete({String? sessionId}) => emit(
    ScreenCaptureSnapshot(
      state: ScreenCaptureState.completed,
      elapsedSeconds: 12,
      sessionId: sessionId ?? activeSession,
      media: _media,
    ),
  );
  Future<void> close() => _events.close();
  @override
  Stream<ScreenCaptureSnapshot> get events => _events.stream;
  @override
  Future<ScreenCaptureResult<ScreenCaptureCapability>> getCapability() async =>
      ScreenCaptureResult.success(
        ScreenCaptureCapability(
          supported: supported,
          canCaptureSystemAudio: supported,
          requiresSystemPicker: true,
          reasonCode: supported
              ? null
              : 'SCREEN_CAPTURE_ANDROID_VERSION_UNSUPPORTED',
        ),
      );
  @override
  Future<ScreenCaptureResult<ScreenCaptureSnapshot>> refreshState() async =>
      ScreenCaptureResult.success(snapshot);
  @override
  Future<ScreenCaptureResult<ScreenCaptureSnapshot>> recoverSession(
    String sessionId,
  ) async => recoveryResult == null
      ? ScreenCaptureResult.success(
          journal[sessionId] ?? const ScreenCaptureSnapshot.idle(),
        )
      : await recoveryResult!.future;
  @override
  Future<ScreenCaptureResult<ScreenCaptureSnapshot>> importVideo(
    String sessionId,
  ) async {
    final value = ScreenCaptureSnapshot(
      state: ScreenCaptureState.completed,
      elapsedSeconds: 12,
      sessionId: sessionId,
      media: _media,
    );
    journal[sessionId] = value;
    return ScreenCaptureResult.success(value);
  }

  @override
  Future<ScreenCaptureResult<bool>> releaseSession(String sessionId) async {
    if (releaseThrows) throw StateError('native release unavailable');
    if (releaseFails) {
      return ScreenCaptureResult.failure(
        recordingApiFailure('SCREEN_CAPTURE_CLEANUP_FAILED'),
      );
    }
    released.add(sessionId);
    journal.remove(sessionId);
    return ScreenCaptureResult.success(true);
  }

  @override
  Future<ScreenCaptureResult<ScreenCaptureSnapshot>> startCapture({
    String? sessionId,
    int maxDurationSeconds = 1800,
    int maxSizeBytes = 500 * 1024 * 1024,
    int targetWidth = 720,
    int targetHeight = 1280,
  }) async {
    starts++;
    activeSession = sessionId;
    emit(
      ScreenCaptureSnapshot(
        state: ScreenCaptureState.starting,
        elapsedSeconds: 0,
        sessionId: sessionId,
      ),
    );
    return ScreenCaptureResult.success(snapshot);
  }

  @override
  Future<ScreenCaptureResult<ScreenCaptureSnapshot>> stopCapture({
    String? expectedSessionId,
  }) async {
    expect(expectedSessionId, activeSession);
    stops++;
    if (stopThrows) throw StateError('native stop interrupted');
    if (stopResult != null) return stopResult!.future;
    if (stopAcknowledgesOnly) {
      return ScreenCaptureResult.success(
        ScreenCaptureSnapshot(
          state: ScreenCaptureState.stopping,
          sessionId: activeSession,
          elapsedSeconds: snapshot.elapsedSeconds,
        ),
      );
    }
    if (snapshot.state == ScreenCaptureState.starting) {
      emit(
        ScreenCaptureSnapshot(
          state: ScreenCaptureState.failed,
          elapsedSeconds: 0,
          sessionId: activeSession,
          lastErrorCode: 'SCREEN_CAPTURE_CONSENT_CANCELLED',
        ),
      );
    } else {
      complete();
    }
    return ScreenCaptureResult.success(snapshot);
  }

  @override
  Future<ScreenCaptureResult<CapturedAudioInput>> extractAudio(
    CapturedMediaInput media,
  ) async {
    extractions++;
    expect(media.appPrivateUri, _media.appPrivateUri);
    if (extractionFails) {
      return ScreenCaptureResult.failure(
        recordingApiFailure('SCREEN_CAPTURE_AUDIO_EXPORT_FAILED'),
      );
    }
    return ScreenCaptureResult.success(
      CapturedAudioInput(
        appPrivateUri: 'app-private-media://screen-capture/capture-test.m4a',
        fileName: 'capture-test.m4a',
        mimeType: 'audio/mp4',
        sizeBytes: 2048,
        durationSeconds: 12,
        sha256: List.filled(64, 'a').join(),
        recordedAt: _media.recordedAt,
      ),
    );
  }
}

final class _FileStorage extends UnavailableFileStoragePort {
  const _FileStorage();
  @override
  Future<FileStorageResult<PrivateAudioFile>>
  copyPrivateMediaAudioToPrivateLibrary({
    required String sourceAppPrivateUri,
    required String displayName,
    required String mimeType,
    required int expectedSizeBytes,
    required int durationSeconds,
    required String expectedContentHash,
    required DateTime recordedAt,
  }) async => FileStorageResult.success(
    PrivateAudioFile(
      fileId: 'internal-audio-1',
      appPrivateUri: 'app-private://internal-audio-1.m4a',
      displayName: displayName,
      mimeType: mimeType,
      sizeBytes: expectedSizeBytes,
      durationSeconds: durationSeconds,
      contentHash: expectedContentHash,
      recordedAt: recordedAt,
    ),
  );
  @override
  Future<FileStorageResult<PrivateAudioFileStat>> statPrivateAudio(
    String appPrivateUri,
  ) async => FileStorageResult.success(
    const PrivateAudioFileStat(
      exists: true,
      sizeBytes: 2048,
      durationSeconds: 12,
    ),
  );
}

final class _UploadApiTransport implements ApiTransport {
  final List<String> paths = <String>[];
  final List<ApiTransportRequest> requests = <ApiTransportRequest>[];

  @override
  Future<ApiTransportResponse> send(ApiTransportRequest request) async {
    paths.add(request.url.path);
    requests.add(request);
    if (request.url.path == '/api/v1/media/upload-token') {
      return const ApiTransportResponse(
        status: 200,
        body: <String, Object?>{
          'success': true,
          'data': <String, Object?>{
            'uploadId': 'upload-internal-1',
            'uploadUrl':
                'https://upload.example.test/object/internal-1?signature=test',
            'method': 'PUT',
            'headers': <String, Object?>{},
          },
        },
      );
    }
    if (request.url.path ==
        '/api/v1/media/uploads/upload-internal-1/complete') {
      return const ApiTransportResponse(
        status: 200,
        body: <String, Object?>{
          'success': true,
          'data': <String, Object?>{
            'status': 'completed',
            'uploadId': 'upload-internal-1',
            'resourceId': 'resource-internal-1',
          },
        },
      );
    }
    if (request.url.path == '/api/v1/recordings') {
      return const ApiTransportResponse(
        status: 200,
        body: <String, Object?>{
          'success': true,
          'data': <String, Object?>{
            'recording': <String, Object?>{
              'recordingId': 'recording-internal-1',
              'title': '内录',
              'status': 'processing',
              'asrTaskId': 'asr-internal-1',
            },
            'asrTask': <String, Object?>{
              'asrTaskId': 'asr-internal-1',
              'status': 'queued',
            },
          },
        },
      );
    }
    return const ApiTransportResponse(
      status: 404,
      body: <String, Object?>{
        'success': false,
        'error': <String, Object?>{'code': 'NOT_FOUND'},
      },
    );
  }
}

final class _ObjectTransport implements ObjectUploadTransport {
  final List<ObjectUploadRequest> requests = <ObjectUploadRequest>[];

  @override
  Future<ObjectUploadResult> upload(ObjectUploadRequest request) async {
    requests.add(request);
    return ObjectUploadResult.success(
      statusCode: 200,
      bytesSent: request.sizeBytes,
    );
  }
}
