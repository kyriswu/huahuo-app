import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:huahuoai_app/app/bootstrap/app_providers.dart';
import 'package:huahuoai_app/core/api/api_client.dart';
import 'package:huahuoai_app/core/api/idempotency.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/native/voice_recorder_port.dart';
import 'package:huahuoai_app/core/storage/file_storage_port.dart';
import 'package:huahuoai_app/features/recordings/application/monologue_recording_controller.dart';
import 'package:huahuoai_app/features/recordings/data/local_recording_repository.dart';
import 'package:huahuoai_app/features/transcription/application/live_transcript_controller.dart';
import 'package:huahuoai_app/features/transcription/data/live_transcription_api.dart';
import 'package:huahuoai_app/features/transcription/data/tencent_live_asr_port.dart';
import 'package:huahuoai_app/features/transcription/domain/live_transcript.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_library_controller.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_capture_pages.dart';
import 'package:huahuoai_app/shared/ui_v3/v3_chat_mark.dart';

import '../../support/figma_golden_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(loadFigmaGoldenFonts);

  test('formal monologue note-save failure never exposes the error code', () {
    const code = 'MONOLOGUE_NOTE_NETWORK_FAILED';
    final message = monologueRecordingFailureMessage(
      MonologueFailureStage.noteSave,
      code,
    );

    expect(message, '独白笔记保存失败，请检查网络后重试');
    expect(message, isNot(contains(code)));
  });

  testWidgets('active monologue shows realtime text above a pause action', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(402, 874)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    var pauseCalls = 0;
    const transcript =
        '我刚刚想到，真正有价值的笔记，\n不是把信息存下来，而是让不同时间\n的想法能够重新相遇。\n\n也许，整理本身就是一次新的思考。';
    final transcriptController = TextEditingController(text: transcript);
    addTearDown(transcriptController.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: figmaGoldenTheme(),
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(402, 874),
            padding: EdgeInsets.only(top: 54, bottom: 34),
          ),
          child: V3MonologueCaptureSurface(
            recording: MonologueRecordingState(
              status: MonologueRecordingStatus.recording,
              nativeCaptureLatch: MonologueNativeCaptureLatch.recording,
              elapsedSeconds: 18,
              transcriptText: transcript,
            ),
            liveTranscript: LiveTranscriptState(
              status: LiveTranscriptStatus.transcribing,
              sentences: <LiveTranscriptSentence>[
                _sentence(
                  1,
                  '我刚刚想到，真正有价值的笔记，\n不是把信息存下来，而是让不同时间\n的想法能够重新相遇。',
                  stable: true,
                ),
                _sentence(2, '\n\n也许，整理本身就是一次新的思考。'),
              ],
            ),
            transcriptController: transcriptController,
            hasHistory: false,
            onBack: () {},
            onHistory: () {},
            onDone: () {},
            onStatusTap: () {},
            onPrimaryTap: () => pauseCalls += 1,
            supplementary: const SizedBox.shrink(),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('正在实时转写'), findsOneWidget);
    expect(find.text('00:18.0'), findsOneWidget);
    expect(find.text('完成'), findsOneWidget);
    expect(find.byKey(const ValueKey('monologue-primary-action')), findsOne);
    final editor = tester.widget<TextField>(
      find.byKey(const ValueKey<String>('monologue-transcript-editor')),
    );
    expect(editor.readOnly, isTrue);
    expect(editor.decoration?.enabledBorder, isA<OutlineInputBorder>());
    final waveform = _findMonologueWaveform();
    expect(
      tester.getBottomLeft(waveform).dy,
      lessThanOrEqualTo(
        tester
            .getTopLeft(
              find.byKey(const ValueKey<String>('monologue-transcript-window')),
            )
            .dy,
      ),
    );
    expect(find.text('暂停转写'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('monologue-primary-action')),
    );
    await tester.pump();
    expect(pauseCalls, 1);
  });

  testWidgets('completed monologue can restart and keeps saved-note access', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(320, 568)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    var restartCalls = 0;
    var openAssetCalls = 0;
    final transcriptController = TextEditingController(
      text: '这是已经完成、仍可编辑的独白文字。',
    );
    addTearDown(transcriptController.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 568),
            padding: EdgeInsets.only(top: 20),
            textScaler: TextScaler.linear(1.3),
          ),
          child: V3MonologueCaptureSurface(
            recording: const MonologueRecordingState(
              status: MonologueRecordingStatus.completed,
              localNoteId: 'note-completed',
              transcriptText: '这是已经完成的独白文字。',
              elapsedSeconds: 21,
            ),
            liveTranscript: LiveTranscriptState(
              status: LiveTranscriptStatus.idle,
              sentences: [_sentence(1, '这是已经完成、仍可编辑的独白文字。', stable: true)],
            ),
            transcriptController: transcriptController,
            hasHistory: false,
            onBack: () {},
            onHistory: () {},
            onDone: () {},
            onStatusTap: null,
            onPrimaryTap: () => restartCalls += 1,
            onOpenAsset: () => openAssetCalls += 1,
            supplementary: const SizedBox.shrink(),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('笔记已保存'), findsOneWidget);
    expect(find.text('再次独白'), findsOneWidget);
    expect(find.text('查看已保存笔记'), findsOneWidget);
    expect(find.text('开始录音'), findsNothing);
    final statusRect = tester.getRect(find.text('笔记已保存'));
    final durationRect = tester.getRect(
      find.byKey(const ValueKey<String>('monologue-duration')),
    );
    expect(statusRect.bottom, lessThanOrEqualTo(durationRect.top));
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(
      find.byKey(const ValueKey<String>('monologue-primary-action')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('monologue-primary-action')),
    );
    expect(restartCalls, 1);
    await tester.tap(
      find.byKey(const ValueKey<String>('monologue-open-saved-note')),
    );
    expect(openAssetCalls, 1);
  });

  testWidgets('monologue keeps the V5 transcript canvas below the timer', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(393, 852)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final asr = _AsrPort();
    final liveTranscript = _liveTranscript(asr);
    final monologue = MonologueRecordingController(
      recorder: const UnavailableVoiceRecorderPort(),
      localRecordingRepository: LocalRecordingRepository(
        database: AppDatabase(),
        fileStorage: const UnavailableFileStoragePort(),
      ),
      knowledgeLibrary: KnowledgeLibraryController(),
      liveTranscriptController: liveTranscript,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          monologueRecordingControllerProvider.overrideWith((ref) => monologue),
          liveTranscriptControllerProvider.overrideWith(
            (ref) => liveTranscript,
          ),
        ],
        child: const MaterialApp(home: V3MonologuePage()),
      ),
    );
    await tester.pump();

    final window = find.byKey(
      const ValueKey<String>('monologue-transcript-window'),
    );
    final duration = find.byKey(const ValueKey<String>('monologue-duration'));
    expect(window, findsOneWidget);
    expect(duration, findsOneWidget);
    expect(
      tester.getTopLeft(window).dy,
      greaterThan(tester.getTopLeft(duration).dy),
    );
    final waveform = _findMonologueWaveform();
    expect(
      tester.getBottomLeft(waveform).dy,
      lessThanOrEqualTo(tester.getTopLeft(window).dy),
    );
    expect(find.text('开始独白后，文字会实时显示在这里'), findsOneWidget);
    expect(find.text('查看笔记'), findsNothing);
    expect(find.textContaining('聊一聊'), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await asr.close();
  });

  testWidgets('idle page retains a previous completed transcript', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: V3MonologueTranscriptWindow(
            sessionActive: false,
            state: LiveTranscriptState(
              status: LiveTranscriptStatus.idle,
              sentences: [_sentence(1, '上一轮继续显示', stable: true)],
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('待开始'), findsOneWidget);
    expect(find.textContaining('上一轮继续显示'), findsOneWidget);
  });

  testWidgets('transcript window shows interim and stable text after stop', (
    tester,
  ) async {
    final sentences = <LiveTranscriptSentence>[
      _sentence(1, '第一句已经确认', stable: true),
      _sentence(2, '第二句仍在识别', speakerId: 1),
      for (var id = 3; id <= 10; id++)
        _sentence(id, '这是用于验证完整转录窗口滚动能力的第 $id 句', stable: true),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: V3MonologueTranscriptWindow(
            sessionActive: true,
            state: LiveTranscriptState(
              status: LiveTranscriptStatus.transcribing,
              sentences: sentences,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('转录中'), findsOneWidget);
    expect(find.textContaining('第一句已经确认'), findsOneWidget);
    expect(find.textContaining('说话人 2 · 第二句仍在识别'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('monologue-transcript-editor')),
      findsOneWidget,
    );
    final transcriptEditor = tester.widget<TextField>(
      find.byKey(const ValueKey<String>('monologue-transcript-editor')),
    );
    expect(
      transcriptEditor.scrollController!.position.maxScrollExtent,
      greaterThan(0),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: V3MonologueTranscriptWindow(
            sessionActive: true,
            state: LiveTranscriptState(
              status: LiveTranscriptStatus.idle,
              sentences: sentences,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('待开始'), findsOneWidget);
    expect(find.textContaining('第一句已经确认'), findsOneWidget);
    expect(find.textContaining('第二句仍在识别'), findsOneWidget);
  });

  testWidgets('paused monologue exposes an editable transcript field', (
    tester,
  ) async {
    const initialText = '第一句自动转录';
    var editedText = '';
    final controller = TextEditingController(text: initialText);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: V3MonologueCaptureSurface(
          recording: const MonologueRecordingState(
            status: MonologueRecordingStatus.paused,
            nativeCaptureLatch: MonologueNativeCaptureLatch.paused,
            transcriptText: initialText,
            elapsedSeconds: 12,
          ),
          liveTranscript: LiveTranscriptState(
            status: LiveTranscriptStatus.idle,
            sentences: <LiveTranscriptSentence>[
              _sentence(1, initialText, stable: true),
            ],
          ),
          transcriptController: controller,
          hasHistory: false,
          onBack: () {},
          onHistory: () {},
          onDone: () {},
          onStatusTap: () {},
          onPrimaryTap: () {},
          onTranscriptChanged: (value) => editedText = value,
          supplementary: const SizedBox.shrink(),
        ),
      ),
    );
    await tester.pump();

    final editor = find.byKey(
      const ValueKey<String>('monologue-transcript-editor'),
    );
    expect(tester.widget<TextField>(editor).readOnly, isFalse);
    expect(find.text('可编辑'), findsOneWidget);
    expect(find.textContaining('录音已暂停，可修改文字'), findsOneWidget);
    expect(find.text('继续转写'), findsOneWidget);

    await tester.enterText(editor, '用户修订后的独白内容');
    await tester.pump();

    expect(controller.text, '用户修订后的独白内容');
    expect(editedText, '用户修订后的独白内容');
  });

  testWidgets('resuming monologue does not claim that it is saving', (
    tester,
  ) async {
    final controller = TextEditingController(text: '继续前保留的文字');
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: V3MonologueCaptureSurface(
          recording: const MonologueRecordingState(
            status: MonologueRecordingStatus.resuming,
            nativeCaptureLatch: MonologueNativeCaptureLatch.recording,
            transcriptText: '继续前保留的文字',
            elapsedSeconds: 12,
          ),
          liveTranscript: const LiveTranscriptState(
            status: LiveTranscriptStatus.starting,
          ),
          transcriptController: controller,
          hasHistory: false,
          onBack: () {},
          onHistory: () {},
          onDone: null,
          onStatusTap: null,
          onPrimaryTap: null,
          supplementary: const SizedBox.shrink(),
        ),
      ),
    );

    expect(find.text('正在继续'), findsWidgets);
    expect(find.text('保存中'), findsNothing);
  });

  testWidgets('paused native failure stays visibly resumable', (tester) async {
    final controller = TextEditingController(text: '失败前保留的文字');
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: V3MonologueCaptureSurface(
          recording: const MonologueRecordingState(
            status: MonologueRecordingStatus.failed,
            nativeCaptureLatch: MonologueNativeCaptureLatch.paused,
            transcriptText: '失败前保留的文字',
            elapsedSeconds: 12,
            lastErrorCode: 'VOICE_RECORDER_RESUME_FAILED',
            failureStage: MonologueFailureStage.nativeCapture,
          ),
          liveTranscript: const LiveTranscriptState(
            status: LiveTranscriptStatus.idle,
          ),
          transcriptController: controller,
          hasHistory: false,
          onBack: () {},
          onHistory: () {},
          onDone: () {},
          onStatusTap: () {},
          onPrimaryTap: () {},
          supplementary: const SizedBox.shrink(),
        ),
      ),
    );

    expect(find.text('继续转写'), findsOneWidget);
    expect(find.textContaining('录音已暂停，可修改文字后重试继续'), findsOneWidget);
    expect(find.textContaining('录音已结束'), findsNothing);
  });

  testWidgets('controlled transcript follows later realtime text', (
    tester,
  ) async {
    final controller = TextEditingController(text: '第一句自动转录');
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: V3MonologueTranscriptWindow(
            sessionActive: true,
            editable: false,
            controller: controller,
            transcriptText: '第一句自动转录',
            state: LiveTranscriptState(
              status: LiveTranscriptStatus.transcribing,
              sentences: <LiveTranscriptSentence>[
                _sentence(1, '第一句自动转录', stable: true),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: V3MonologueTranscriptWindow(
            sessionActive: true,
            editable: false,
            controller: controller,
            transcriptText: '第一句自动转录\n第二句后续到达',
            state: LiveTranscriptState(
              status: LiveTranscriptStatus.transcribing,
              sentences: <LiveTranscriptSentence>[
                _sentence(1, '第一句自动转录', stable: true),
                _sentence(2, '第二句后续到达', stable: true),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(controller.text, '第一句自动转录\n第二句后续到达');
  });

  testWidgets('failed live ASR leaves neutral formal-recording copy', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: V3MonologueTranscriptWindow(
            sessionActive: true,
            state: LiveTranscriptState(
              status: LiveTranscriptStatus.failed,
              lastErrorCode: 'TENCENT_LIVE_ASR_SDK_UNAVAILABLE',
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('monologue-transcript-window')),
      findsOneWidget,
    );
    expect(find.text('转写暂停'), findsOneWidget);
    expect(find.text('实时转写暂时不可用，请重试后继续'), findsOneWidget);
    expect(find.textContaining('失败'), findsNothing);
    expect(find.textContaining('已停止'), findsNothing);
  });

  testWidgets(
    'a monologue live-start failure overrides a foreign transcribing state',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: V3MonologueTranscriptWindow(
              sessionActive: true,
              liveTranscriptErrorCode: 'LIVE_TRANSCRIPT_SESSION_BUSY',
              state: LiveTranscriptState(
                status: LiveTranscriptStatus.transcribing,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('转写暂停'), findsOneWidget);
      expect(find.text('实时转写暂时不可用，请重试后继续'), findsOneWidget);
      expect(find.text('转录中'), findsNothing);
      expect(find.text('LIVE_TRANSCRIPT_SESSION_BUSY'), findsNothing);
    },
  );

  testWidgets('matched voiceprint name replaces only its anonymous label', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: V3MonologueTranscriptWindow(
            sessionActive: true,
            state: LiveTranscriptState(
              status: LiveTranscriptStatus.transcribing,
              sentences: <LiveTranscriptSentence>[
                LiveTranscriptSentence(
                  sentenceId: 1,
                  text: '这是本人发言',
                  stable: true,
                  anonymousSpeakerId: 0,
                  speakerIdentityState: LiveSpeakerIdentityState.matched,
                  speakerProfileId: 'vp-self',
                  speakerDisplayName: '我的声纹',
                  speakerIdentityScore: 86.1,
                ),
                _sentence(2, '仍然保持匿名', stable: true, speakerId: 1),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.textContaining('我的声纹 · 这是本人发言'), findsOneWidget);
    expect(find.textContaining('说话人 2 · 仍然保持匿名'), findsOneWidget);
    expect(find.textContaining('说话人 1 · 这是本人发言'), findsNothing);
  });

  testWidgets(
    'transcription completion enters memory without automatic deposit',
    (tester) async {
      final library = KnowledgeLibraryController();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            knowledgeLibraryControllerProvider.overrideWith((ref) => library),
          ],
          child: const MaterialApp(home: V3TranscriptionDonePage()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('继续追问'), findsOneWidget);
      expect(find.byType(V3ChatMark), findsOneWidget);

      await tester.tap(find.byTooltip('\u6c89\u6dc0\u5230...'));
      await tester.pumpAndSettle();

      final note = library.noteForId('transcription-preview');
      expect(note, isNotNull);
      expect(library.mineNotes.map((item) => item.id), contains(note!.id));
      expect(library.isDeposited(note.id), isTrue);
      expect(find.text('\u672a\u5206\u7c7b'), findsOneWidget);
    },
  );

  testWidgets(
    'compact scaled transcription results use reachable two-column cards',
    (tester) async {
      tester.view
        ..physicalSize = const Size(320, 568)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final library = KnowledgeLibraryController();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            knowledgeLibraryControllerProvider.overrideWith((ref) => library),
          ],
          child: const MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(
                size: Size(320, 568),
                padding: EdgeInsets.only(top: 20),
                textScaler: TextScaler.linear(1.3),
              ),
              child: V3TranscriptionDonePage(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.text('本次沉淀结果'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('deposit-results-compact-grid')),
        findsOne,
      );
      final resultLabel = tester.renderObject<RenderBox>(find.text('2条核心观点'));
      expect(
        resultLabel.getMaxIntrinsicWidth(double.infinity),
        lessThanOrEqualTo(resultLabel.size.width + .1),
      );
      expect(tester.takeException(), isNull);

      await tester.scrollUntilVisible(
        find.text('接下来，你可以'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('transcription-next-actions-compact-grid')),
        findsOne,
      );
      await tester.ensureVisible(find.text('加入思想图谱'));
      await tester.pumpAndSettle();

      for (final label in <String>['加入思想图谱', '沉淀素材\n喂养大脑']) {
        final box = tester.renderObject<RenderBox>(find.text(label));
        expect(
          box.getMaxIntrinsicWidth(double.infinity),
          lessThanOrEqualTo(box.size.width + .1),
          reason: '$label should not be ellipsized in the compact grid',
        );
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('transcription follow-up carries the stable preview Note', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final library = KnowledgeLibraryController();
    Uri? openedChat;
    final router = GoRouter(
      routes: <RouteBase>[
        GoRoute(
          path: '/',
          builder: (context, state) => const V3TranscriptionDonePage(),
        ),
        GoRoute(
          path: '/v3/feed/chat',
          builder: (context, state) {
            openedChat = state.uri;
            return const Scaffold(body: Text('聊一聊目标页'));
          },
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('继续追问'));
    await tester.pumpAndSettle();

    expect(openedChat?.path, '/v3/feed/chat');
    expect(openedChat?.queryParameters['itemId'], 'transcription-preview');
    expect(library.noteForId('transcription-preview'), isNotNull);
  });
}

LiveTranscriptController _liveTranscript(_AsrPort asr) {
  return LiveTranscriptController(
    credentialPort: const _CredentialPort(),
    asrPort: asr,
    now: () => DateTime.utc(2026, 7, 24, 12),
  );
}

Finder _findMonologueWaveform() => find.byWidgetPredicate(
  (widget) =>
      widget is CustomPaint &&
      widget.child is SizedBox &&
      (widget.child! as SizedBox).height == 92,
  description: 'monologue waveform',
);

LiveTranscriptSentence _sentence(
  int id,
  String text, {
  bool stable = false,
  int? speakerId,
}) {
  return LiveTranscriptSentence(
    sentenceId: id,
    text: text,
    stable: stable,
    anonymousSpeakerId: speakerId,
  );
}

final class _CredentialPort implements LiveTranscriptionCredentialPort {
  const _CredentialPort();

  @override
  Future<ApiResult<LiveAsrSessionCredential>> requestSessionCredential({
    String? voiceprintProfileId,
  }) async {
    return ApiResult<LiveAsrSessionCredential>.success(
      data: LiveAsrSessionCredential(
        sessionId: 'live-session-widget',
        appId: 123456789,
        projectId: 0,
        tmpSecretId: 'tmp-secret-id',
        tmpSecretKey: 'tmp-secret-key',
        token: 'tmp-token',
        expiresAt: DateTime.utc(2026, 7, 24, 12, 15),
      ),
      status: 200,
      idempotencyStore: SubmissionKeyStore.empty,
    );
  }
}

final class _AsrPort implements TencentLiveAsrPort {
  final StreamController<LiveTranscriptSentence> _events =
      StreamController<LiveTranscriptSentence>.broadcast();

  @override
  Stream<LiveTranscriptSentence> get events => _events.stream;

  void add(LiveTranscriptSentence sentence) => _events.add(sentence);

  @override
  Future<LiveAsrOperationResult> connect(
    LiveAsrSessionCredential credential,
  ) async => const LiveAsrOperationResult.success();

  @override
  Future<LiveAsrOperationResult> release() async =>
      const LiveAsrOperationResult.success();

  @override
  Future<LiveAsrOperationResult> stop() async =>
      const LiveAsrOperationResult.success();

  Future<void> close() => _events.close();
}
