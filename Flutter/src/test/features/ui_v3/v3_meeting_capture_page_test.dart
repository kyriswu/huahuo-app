import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/native/recording_card_native_port.dart';
import 'package:huahuoai_app/core/native/voice_recorder_port.dart';
import 'package:huahuoai_app/core/storage/file_storage_port.dart';
import 'package:huahuoai_app/features/ingestion/application/meeting_capture_controller.dart';
import 'package:huahuoai_app/features/recordings/data/local_recording_repository.dart';
import 'package:huahuoai_app/features/recordings/domain/recording_library.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_meeting_capture_page.dart';
import 'package:huahuoai_app/shared/navigation/foreground_ingress_coordinator.dart';
import 'package:huahuoai_app/shared/theme/huahuo_v3_theme.dart';

void main() {
  testWidgets('external recording survives route departure and fresh reentry', (
    tester,
  ) async {
    final recorder = _Recorder();
    final controller = _controller(recorder: recorder);
    final router = GoRouter(
      initialLocation: '/home',
      routes: [
        GoRoute(
          path: '/home',
          builder: (_, __) => const Scaffold(body: Text('其他界面')),
        ),
        GoRoute(
          path: '/record',
          builder: (_, __) => const V3MeetingCapturePage(freshEntry: true),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          meetingCaptureControllerProvider.overrideWith((ref) {
            ref.keepAlive();
            return controller;
          }),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    unawaited(router.push<void>('/record'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始外录'));
    await tester.pumpAndSettle();
    expect(recorder.startCalls, 1);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('其他界面'), findsOneWidget);
    expect(controller.state.status, MeetingCaptureStatus.recording);
    expect(recorder.stopCalls, 0);
    expect(recorder.cancelCalls, 0);
    unawaited(router.push<void>('/record'));
    await tester.pumpAndSettle();
    expect(find.text('结束并转写'), findsOneWidget);
    expect(find.text('当前无法进入外录'), findsNothing);
    expect(recorder.startCalls, 1);
  });

  testWidgets('exposes only the phone microphone capture source', (
    tester,
  ) async {
    final controller = _controller(
      card: _Card(
        files: const <RecordingCardScannedFile>[
          RecordingCardScannedFile(
            deviceFileId: 'device-1',
            localFileKey: 'device-1.m4a',
            deviceFilename: '20260714093000',
          ),
        ],
      ),
    );

    await tester.pumpWidget(_app(controller));
    await tester.pump();

    expect(find.text('麦克风录音'), findsOneWidget);
    expect(find.text('本地录音'), findsNothing);
    expect(find.text('录音卡文件'), findsNothing);
    expect(find.text('继续处理'), findsNothing);
    expect(
      find.byKey(const ValueKey('meeting-local-source'), skipOffstage: false),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('meeting-device-source'), skipOffstage: false),
      findsNothing,
    );
  });

  testWidgets('starts the native meeting scene and shows live controls', (
    tester,
  ) async {
    final recorder = _Recorder();
    final controller = _controller(recorder: recorder);

    await tester.pumpWidget(_app(controller, theme: HuahuoV3Theme.dark()));
    await tester.pump();
    await tester.tap(find.text('开始外录'));
    await tester.pumpAndSettle();

    expect(recorder.scene, VoiceRecordingScene.meeting);
    expect(find.byKey(const ValueKey('meeting-live-waveform')), findsOneWidget);
    expect(find.text('结束并转写'), findsOneWidget);
    expect(find.byTooltip('暂停录音'), findsOneWidget);
    expect(find.byTooltip('取消本次录音'), findsOneWidget);
    expect(
      tester.widget<Text>(find.text('录音中')).style?.color,
      HuahuoV3Theme.darkTokens.text,
    );
    final stateBadge = tester.widget<Container>(
      find.byKey(const ValueKey('meeting-live-state-badge')),
    );
    expect(
      (stateBadge.decoration! as BoxDecoration).color,
      HuahuoV3Theme.darkTokens.surfaceMuted,
    );
    final pauseButton = tester.widget<IconButton>(
      find.byWidgetPredicate(
        (widget) => widget is IconButton && widget.tooltip == '暂停录音',
      ),
    );
    expect(
      pauseButton.style?.backgroundColor?.resolve(const <WidgetState>{}),
      HuahuoV3Theme.darkTokens.surfaceMuted,
    );
    expect(
      pauseButton.style?.foregroundColor?.resolve(const <WidgetState>{}),
      HuahuoV3Theme.darkTokens.ink,
    );

    recorder.emitLevel(.7);
    await tester.pump(const Duration(milliseconds: 5));
    expect(controller.waveform.value.last, greaterThan(0));
  });

  testWidgets('stop immediately enters transcription processing', (
    tester,
  ) async {
    final stopResult = Completer<VoiceRecorderResult<VoiceRecordingDraft>>();
    final recorder = _Recorder(stopResult: stopResult);
    final controller = _controller(recorder: recorder);

    await tester.pumpWidget(_app(controller));
    await tester.pump();
    await tester.tap(find.text('开始外录'));
    await tester.pumpAndSettle();
    final stopButton = tester.widget<FilledButton>(
      find.descendant(
        of: find.byKey(const ValueKey('meeting-stop-and-transcribe')),
        matching: find.byType(FilledButton),
      ),
    );
    stopButton.onPressed!();
    await tester.pump();

    expect(
      find.byKey(const ValueKey('transcription-pending-surface')),
      findsOneWidget,
    );
    expect(find.text('转写详情'), findsOneWidget);
    expect(find.text('正在结束录音'), findsWidgets);
    expect(find.text('麦克风录音'), findsNothing);

    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(recorder.stopCalls, 1);
    expect(find.text('正在结束录音'), findsWidgets);

    stopResult.complete(
      VoiceRecorderResult.failure(
        voiceRecorderFailure('VOICE_RECORDER_STOP_FAILED'),
      ),
    );
    await tester.pump();
    expect(find.text('结束录音失败，请稍后重试'), findsWidgets);
    expect(find.text('结束并转写'), findsOneWidget);
    expect(controller.state.status, MeetingCaptureStatus.recording);
    expect(find.textContaining('VOICE_RECORDER_STOP_FAILED'), findsNothing);
  });

  testWidgets('reentry keeps an existing active control error visible', (
    tester,
  ) async {
    final stopResult = Completer<VoiceRecorderResult<VoiceRecordingDraft>>();
    final recorder = _Recorder(
      stopResult: stopResult,
      refreshFailureCode: 'VOICE_RECORDER_STATE_REFRESH_FAILED',
    );
    final controller = _controller(recorder: recorder);
    expect(await controller.startLiveRecording(), isTrue);

    final stopping = controller.stop();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    expect(recorder.stopCalls, 1);
    stopResult.complete(
      VoiceRecorderResult.failure(
        voiceRecorderFailure('VOICE_RECORDER_STOP_FAILED'),
      ),
    );
    expect(await stopping, isFalse);
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    expect(controller.state.status, MeetingCaptureStatus.recording);
    expect(controller.state.lastErrorCode, isNotNull);

    await tester.pumpWidget(_app(controller));
    await tester.pump();
    await tester.pump();

    expect(
      find.byKey(const ValueKey('meeting-active-control-error')),
      findsOneWidget,
    );
    expect(find.text('结束录音失败，请稍后重试'), findsOneWidget);
    expect(find.text('结束并转写'), findsOneWidget);
    expect(find.byTooltip('暂停录音'), findsOneWidget);
    expect(find.textContaining('VOICE_RECORDER_'), findsNothing);
  });

  testWidgets('accepted recording opens transcription once', (tester) async {
    final item = _item('completed-meeting');
    final controller = _controller(
      library: _Library(<RecordingLibraryItem>[item]),
    );
    final router = GoRouter(
      initialLocation: '/source',
      routes: [
        GoRoute(
          path: '/source',
          builder: (context, state) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => context.push('/v3/feed/meeting'),
                child: const Text('打开外录'),
              ),
            ),
          ),
        ),
        GoRoute(
          path: '/v3/feed/meeting',
          builder: (context, state) => ProviderScope(
            overrides: <Override>[
              meetingCaptureControllerProvider.overrideWith((ref) {
                ref.keepAlive();
                return controller;
              }),
            ],
            child: const V3MeetingCapturePage(),
          ),
        ),
        GoRoute(
          path: '/v3/feed/transcription-jobs/:jobId',
          builder: (context, state) => Scaffold(
            body: Center(
              child: Text(
                '转写 ${state.pathParameters['jobId'] ?? ''} '
                '${state.uri.queryParameters['source'] ?? ''}',
              ),
            ),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.tap(find.text('打开外录'));
    await tester.pumpAndSettle();
    expect(find.text('外录'), findsOneWidget);

    expect(await controller.selectLocalRecording(item), isTrue);
    expect(controller.state.status, MeetingCaptureStatus.completed);
    await tester.pumpAndSettle();
    expect(
      find.text('转写 draft-completed-meeting local-library'),
      findsOneWidget,
    );

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('打开外录'), findsOneWidget);
    expect(find.text('外录'), findsNothing);
  });

  testWidgets('fresh capture detaches an accepted recording job', (
    tester,
  ) async {
    final item = _item('previous-meeting');
    final controller = _controller(
      library: _Library(<RecordingLibraryItem>[item]),
    );
    await controller.initialize();
    expect(await controller.selectLocalRecording(item), isTrue);
    expect(controller.state.status, MeetingCaptureStatus.completed);

    await tester.pumpWidget(_app(controller, freshEntry: true));
    await tester.pump();

    expect(controller.state.status, MeetingCaptureStatus.idle);
    expect(controller.state.remoteRecordingId, isNull);
    expect(find.text('麦克风录音'), findsOneWidget);
    expect(find.text('转写详情'), findsNothing);
  });

  testWidgets(
    'fresh entry attaches to the resident upload without starting another journey',
    (tester) async {
      final item = _item('resident-upload');
      final uploader = _BlockingUploader();
      final controller = _controller(
        library: _Library(<RecordingLibraryItem>[item]),
        uploader: uploader,
      );
      await controller.initialize();
      final residentUpload = controller.selectLocalRecording(item);
      await uploader.started.future;
      expect(controller.state.status, MeetingCaptureStatus.uploading);

      final router = GoRouter(
        initialLocation: '/record',
        routes: [
          GoRoute(
            path: '/record',
            builder: (_, __) => const V3MeetingCapturePage(freshEntry: true),
          ),
          GoRoute(
            path: '/v3/feed/transcription-jobs/:jobId',
            builder: (_, state) =>
                Scaffold(body: Text('原任务 ${state.pathParameters["jobId"]}')),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            meetingCaptureControllerProvider.overrideWith((ref) {
              ref.keepAlive();
              return controller;
            }),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pump();
      expect(find.text('当前无法进入外录'), findsNothing);

      uploader.complete('remote-resident-upload');
      expect(await residentUpload, isTrue);
      expect(controller.state.remoteRecordingId, 'remote-resident-upload');
      expect(find.text('当前无法进入外录'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'background capture allows ingress and completion cannot cover its target',
    (tester) async {
      final stopResult = Completer<VoiceRecorderResult<VoiceRecordingDraft>>();
      final recorder = _Recorder(stopResult: stopResult);
      final controller = _controller(recorder: recorder);
      final ingress = ForegroundIngressCoordinator();
      final router = GoRouter(
        observers: <NavigatorObserver>[foregroundIngressRouteObserver],
        initialLocation: '/source',
        routes: <RouteBase>[
          GoRoute(
            path: '/source',
            builder: (context, state) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => context.push('/v3/feed/meeting'),
                  child: const Text('打开外录'),
                ),
              ),
            ),
          ),
          GoRoute(
            path: '/v3/feed/meeting',
            builder: (context, state) => ProviderScope(
              overrides: <Override>[
                meetingCaptureControllerProvider.overrideWith(
                  (ref) => controller,
                ),
              ],
              child: const V3MeetingCapturePage(),
            ),
          ),
          GoRoute(
            path: '/ingress',
            builder: (_, __) => const Scaffold(body: Text('前台入口目标')),
          ),
          GoRoute(
            path: '/v3/feed/transcription-jobs/:jobId',
            builder: (context, state) => Scaffold(
              body: Text('转写 ${state.pathParameters['jobId'] ?? ''}'),
            ),
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        MaterialApp.router(
          routerConfig: router,
          builder: (context, child) => ForegroundIngressScope(
            coordinator: ingress,
            child: child ?? const SizedBox.shrink(),
          ),
        ),
      );
      await tester.tap(find.text('打开外录'));
      await tester.pumpAndSettle();
      expect(await controller.startLiveRecording(), isTrue);
      await tester.pump();
      expect(controller.state.status, MeetingCaptureStatus.recording);

      expect(await ingress.requestNavigation(), isTrue);
      await tester.pump();
      expect(find.text('正在录制'), findsNothing);
      expect(controller.state.status, MeetingCaptureStatus.recording);
      expect(recorder.stopCalls, 0);

      unawaited(router.push<void>('/ingress'));
      await tester.pumpAndSettle();
      expect(find.text('前台入口目标'), findsOneWidget);

      final stopping = controller.stop();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      expect(recorder.stopCalls, 1);
      stopResult.complete(
        VoiceRecorderResult.success(_completedMeetingDraft()),
      );
      await stopping;
      await tester.pumpAndSettle();

      expect(
        controller.state.status,
        MeetingCaptureStatus.completed,
        reason: controller.state.lastErrorCode,
      );
      expect(controller.state.remoteRecordingId, 'remote-widget-meeting');
      expect(find.text('前台入口目标'), findsOneWidget);
      expect(find.text('转写 remote-widget-meeting'), findsNothing);
    },
  );
}

Widget _app(
  MeetingCaptureController controller, {
  ThemeData? theme,
  bool freshEntry = false,
}) {
  return ProviderScope(
    overrides: <Override>[
      meetingCaptureControllerProvider.overrideWith((ref) => controller),
    ],
    child: MaterialApp(
      theme: theme,
      home: V3MeetingCapturePage(freshEntry: freshEntry),
    ),
  );
}

MeetingCaptureController _controller({
  _Recorder? recorder,
  _Library? library,
  _Card? card,
  MeetingRecordingUploadPort? uploader,
}) {
  return MeetingCaptureController(
    recorder: recorder ?? _Recorder(),
    localRecordingRepository: LocalRecordingRepository(
      database: AppDatabase(),
      fileStorage: const _FileStorage(),
    ),
    recordingLibrary: library ?? _Library(),
    recordingCard: card ?? _Card(),
    uploader: uploader ?? _Uploader(),
  );
}

RecordingLibraryItem _item(String id) => RecordingLibraryItem(
  recordingId: id,
  source: RecordingLibrarySource.localImport,
  displayName: '$id.m4a',
  format: RecordingLibraryFormat.m4a,
  localFileState: RecordingLocalFileState.ready,
  status: RecordingLibraryStatus.localOnly,
  durationSeconds: 300,
  sizeBytes: 4096,
  isFavorite: false,
  tagIds: const <String>[],
  createdAt: DateTime.utc(2026, 7, 14, 9),
  updatedAt: DateTime.utc(2026, 7, 14, 9),
  appPrivateUri: 'app-private://$id.m4a',
);

final class _Recorder implements VoiceRecorderPort, VoiceRecorderLevelSource {
  _Recorder({this.stopResult, this.refreshFailureCode});

  final Completer<VoiceRecorderResult<VoiceRecordingDraft>>? stopResult;
  final String? refreshFailureCode;
  final _levels = StreamController<VoiceLevelSample>.broadcast();
  VoiceRecordingScene? scene;
  VoiceRecorderSnapshot _snapshot = const VoiceRecorderSnapshot.idle();
  var stopCalls = 0;
  var startCalls = 0;
  var cancelCalls = 0;

  @override
  VoiceRecorderSnapshot get snapshot => _snapshot;

  @override
  Stream<VoiceLevelSample> get levelSamples => _levels.stream;

  void emitLevel(double value) {
    _levels.add(
      VoiceLevelSample(
        capturedAt: DateTime.utc(2026, 7, 14, 9),
        average: value,
        peak: value,
      ),
    );
  }

  @override
  Future<VoiceRecorderResult<VoiceRecorderPermission>>
  getMicrophonePermission() async => VoiceRecorderResult.success(
    const VoiceRecorderPermission(
      state: VoiceRecorderPermissionState.granted,
      canAskAgain: false,
    ),
  );

  @override
  Future<VoiceRecorderResult<VoiceRecorderPermission>>
  requestMicrophonePermission() => getMicrophonePermission();

  @override
  Future<VoiceRecorderResult<VoiceRecordingSession>> startRecording({
    required VoiceRecordingScene scene,
  }) async {
    startCalls++;
    this.scene = scene;
    final session = VoiceRecordingSession(
      recordingId: 'meeting-live',
      scene: scene,
      state: VoiceRecorderState.recording,
      startedAt: DateTime.utc(2026, 7, 14, 9),
    );
    _snapshot = VoiceRecorderSnapshot(
      state: VoiceRecorderState.recording,
      session: session,
    );
    return VoiceRecorderResult.success(session);
  }

  @override
  Future<VoiceRecorderResult<VoiceRecorderSnapshot>> refreshState() async {
    final failureCode = refreshFailureCode;
    return failureCode == null
        ? VoiceRecorderResult.success(_snapshot)
        : VoiceRecorderResult.failure(voiceRecorderFailure(failureCode));
  }

  @override
  Future<VoiceRecorderResult<VoiceRecorderSnapshot>> pauseRecording() async =>
      VoiceRecorderResult.success(_snapshot);

  @override
  Future<VoiceRecorderResult<VoiceRecorderSnapshot>> resumeRecording() async =>
      VoiceRecorderResult.success(_snapshot);

  @override
  Future<VoiceRecorderResult<VoiceRecordingDraft>> stopRecording() {
    stopCalls += 1;
    final result =
        stopResult?.future ??
        Future<VoiceRecorderResult<VoiceRecordingDraft>>.value(
          VoiceRecorderResult.failure(voiceRecorderFailure('NOT_USED')),
        );
    return result.then((value) {
      if (value.ok) _snapshot = const VoiceRecorderSnapshot.idle();
      return value;
    });
  }

  @override
  Future<VoiceRecorderResult<VoiceRecorderSnapshot>> cancelRecording() async {
    cancelCalls++;
    _snapshot = const VoiceRecorderSnapshot.idle();
    return VoiceRecorderResult.success(_snapshot);
  }
}

VoiceRecordingDraft _completedMeetingDraft() => VoiceRecordingDraft(
  recordingId: 'meeting-live',
  appPrivateUri: 'app-private://meeting-live.wav',
  fileName: 'meeting-live.wav',
  mimeType: 'audio/wav',
  sizeBytes: 4096,
  durationSeconds: 20,
  sha256: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  scene: VoiceRecordingScene.meeting,
  sampleRateHz: 16000,
  bitDepth: 16,
  channelCount: 1,
  recordedAt: DateTime.utc(2026, 7, 14, 9),
);

final class _Library implements MeetingRecordingLibraryPort {
  _Library([List<RecordingLibraryItem> items = const <RecordingLibraryItem>[]])
    : _items = items;

  final List<RecordingLibraryItem> _items;
  final List<VoidCallback> _listeners = <VoidCallback>[];

  @override
  List<RecordingLibraryItem> get items => _items;

  @override
  Future<void> load() async {
    for (final listener in List<VoidCallback>.of(_listeners)) {
      listener();
    }
  }

  @override
  void addListener(VoidCallback listener) => _listeners.add(listener);

  @override
  void removeListener(VoidCallback listener) => _listeners.remove(listener);
}

final class _Card implements MeetingRecordingCardPort {
  _Card({this.files = const <RecordingCardScannedFile>[]});

  @override
  final List<RecordingCardScannedFile> files;

  @override
  bool get isConnected => true;

  @override
  String? get lastErrorCode => null;

  @override
  Future<RecordingCardResult<RecordingCardDownloadedFile>> downloadFile(
    RecordingCardScannedFile file,
  ) async {
    return RecordingCardResult<RecordingCardDownloadedFile>.failure(
      recordingCardFailure(
        'MEETING_DEVICE_DOWNLOAD_FAILED',
        'Fake recording-card download is unavailable',
      ),
    );
  }

  @override
  Future<void> scanFiles() async {}

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}
}

final class _Uploader implements MeetingRecordingUploadPort {
  @override
  Future<MeetingUploadResult> upload(RecordingLibraryItem item) async =>
      MeetingUploadResult.success('remote-widget-meeting');
}

final class _BlockingUploader implements MeetingRecordingUploadPort {
  final Completer<void> started = Completer<void>();
  final Completer<MeetingUploadResult> _result =
      Completer<MeetingUploadResult>();

  @override
  Future<MeetingUploadResult> upload(RecordingLibraryItem item) {
    if (!started.isCompleted) started.complete();
    return _result.future;
  }

  void complete(String recordingId) {
    _result.complete(MeetingUploadResult.success(recordingId));
  }
}

final class _FileStorage extends UnavailableFileStoragePort {
  const _FileStorage();

  @override
  Future<FileStorageResult<PrivateAudioFileStat>> statPrivateAudio(
    String appPrivateUri,
  ) async => FileStorageResult.success(
    const PrivateAudioFileStat(exists: true, sizeBytes: 4096),
  );
}
