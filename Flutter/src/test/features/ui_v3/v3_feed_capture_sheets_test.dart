import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:huahuoai_app/features/recordings/application/monologue_recording_controller.dart';
import 'package:huahuoai_app/features/transcription/application/live_transcript_controller.dart';
import 'package:huahuoai_app/features/transcription/domain/live_transcript.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_capture_pages.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_feed_capture_sheets.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_material_import_surfaces.dart';

import '../../support/figma_golden_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadFigmaGoldenFonts);

  testWidgets('compact monologue ready explains realtime text and starts', (
    tester,
  ) async {
    _setPhoneViewport(tester);
    var startCalls = 0;
    final callbacks = _MonologueCallbacks(onStart: () => startCalls += 1);
    await tester.pumpWidget(
      _sheetApp(
        V3MonologueQuickCaptureSheet(
          recording: MonologueRecordingState.initial(),
          transcript: const LiveTranscriptState(
            status: LiveTranscriptStatus.idle,
          ),
          onClose: callbacks.close,
          onExpand: callbacks.expand,
          onStart: callbacks.start,
          onPause: callbacks.pause,
          onResume: callbacks.resume,
          onDone: callbacks.done,
        ),
      ),
    );

    expect(find.text('开始独白后，文字会实时显示在这里'), findsOneWidget);
    expect(find.byTooltip('开始独白'), findsOneWidget);
    await tester.tap(find.byTooltip('开始独白'));
    expect(startCalls, 1);
  });

  testWidgets('compact completed monologue can restart or open saved note', (
    tester,
  ) async {
    _setPhoneViewport(tester);
    var restartCalls = 0;
    var openNoteCalls = 0;
    final callbacks = _MonologueCallbacks(onStart: () => restartCalls += 1);
    await tester.pumpWidget(
      _sheetApp(
        V3MonologueQuickCaptureSheet(
          recording: MonologueRecordingState(
            status: MonologueRecordingStatus.completed,
            transcriptText: _monologueTranscriptText,
            localNoteId: 'note-completed',
          ),
          transcript: const LiveTranscriptState(
            status: LiveTranscriptStatus.idle,
          ),
          onClose: callbacks.close,
          onExpand: callbacks.expand,
          onStart: callbacks.start,
          onPause: callbacks.pause,
          onResume: callbacks.resume,
          onDone: callbacks.done,
          onOpenAsset: () => openNoteCalls += 1,
        ),
      ),
    );

    expect(find.byTooltip('再次独白'), findsOneWidget);
    expect(find.byTooltip('查看已保存笔记'), findsOneWidget);
    await tester.tap(find.byTooltip('再次独白'));
    await tester.tap(find.byTooltip('查看已保存笔记'));
    expect(restartCalls, 1);
    expect(openNoteCalls, 1);
  });

  for (final status in <MonologueRecordingStatus>[
    MonologueRecordingStatus.checkingPermission,
    MonologueRecordingStatus.starting,
  ]) {
    testWidgets('compact monologue $status is active and prevents restart', (
      tester,
    ) async {
      _setPhoneViewport(tester);
      var startCalls = 0;
      final callbacks = _MonologueCallbacks(onStart: () => startCalls += 1);
      await tester.pumpWidget(
        _sheetApp(
          V3MonologueQuickCaptureSheet(
            recording: _recording(status),
            transcript: const LiveTranscriptState(
              status: LiveTranscriptStatus.idle,
            ),
            onClose: callbacks.close,
            onExpand: callbacks.expand,
            onStart: callbacks.start,
            onPause: callbacks.pause,
            onResume: callbacks.resume,
            onDone: callbacks.done,
          ),
        ),
      );

      expect(
        find.text(
          status == MonologueRecordingStatus.checkingPermission
              ? '正在请求麦克风'
              : '正在启动',
        ),
        findsOneWidget,
      );
      expect(find.text('处理中'), findsOneWidget);
      final start = tester.widget<IconButton>(find.byType(IconButton).last);
      expect(start.onPressed, isNull);
      await tester.tap(find.byTooltip('处理中'), warnIfMissed: false);
      expect(startCalls, 0);
    });
  }

  testWidgets('compact monologue live failure remains editable and resumable', (
    tester,
  ) async {
    _setPhoneViewport(tester);
    final callbacks = _MonologueCallbacks();
    await tester.pumpWidget(
      _sheetApp(
        V3MonologueQuickCaptureSheet(
          recording: MonologueRecordingState(
            status: MonologueRecordingStatus.failed,
            nativeCaptureLatch: MonologueNativeCaptureLatch.paused,
            failureStage: MonologueFailureStage.liveTranscription,
            liveTranscriptErrorCode: 'TENCENT_LIVE_ASR_PROVIDER_FATAL',
            transcriptText: _monologueTranscriptText,
          ),
          transcript: const LiveTranscriptState(
            status: LiveTranscriptStatus.idle,
          ),
          onClose: callbacks.close,
          onExpand: callbacks.expand,
          onStart: callbacks.start,
          onPause: callbacks.pause,
          onResume: callbacks.resume,
          onDone: callbacks.done,
        ),
      ),
    );

    final editor = tester.widget<TextField>(
      find.byKey(const ValueKey<String>('monologue-transcript-editor')),
    );
    expect(editor.readOnly, isFalse);
    expect(find.text('转写已暂停'), findsOneWidget);
    expect(find.byTooltip('继续录音'), findsOneWidget);
    expect(find.byTooltip('完成录音'), findsOneWidget);
  });

  testWidgets('compact monologue active uses transcriptText and acts', (
    tester,
  ) async {
    _setPhoneViewport(tester);
    var pauseCalls = 0;
    var doneCalls = 0;
    final callbacks = _MonologueCallbacks(
      onPause: () => pauseCalls += 1,
      onDone: () => doneCalls += 1,
    );
    await tester.pumpWidget(
      _sheetApp(
        V3MonologueQuickCaptureSheet(
          recording: _recording(MonologueRecordingStatus.recording),
          transcript: _transcript,
          onClose: callbacks.close,
          onExpand: callbacks.expand,
          onStart: callbacks.start,
          onPause: callbacks.pause,
          onResume: callbacks.resume,
          onDone: callbacks.done,
        ),
      ),
    );

    expect(find.text(_monologueTranscriptText), findsOneWidget);
    await tester.tap(find.byTooltip('暂停录音'));
    await tester.tap(find.byTooltip('完成录音'));
    expect(pauseCalls, 1);
    expect(doneCalls, 1);
  });

  testWidgets('compact monologue paused offers resume and editing entry', (
    tester,
  ) async {
    _setPhoneViewport(tester);
    var resumeCalls = 0;
    var expandCalls = 0;
    final callbacks = _MonologueCallbacks(
      onResume: () => resumeCalls += 1,
      onExpand: () => expandCalls += 1,
    );
    await tester.pumpWidget(
      _sheetApp(
        V3MonologueQuickCaptureSheet(
          recording: _recording(MonologueRecordingStatus.paused),
          transcript: _transcript,
          onClose: callbacks.close,
          onExpand: callbacks.expand,
          onStart: callbacks.start,
          onPause: callbacks.pause,
          onResume: callbacks.resume,
          onDone: callbacks.done,
        ),
      ),
    );

    expect(find.text(_monologueTranscriptText), findsOneWidget);
    expect(
      tester
          .widget<TextField>(
            find.byKey(const ValueKey<String>('monologue-transcript-editor')),
          )
          .readOnly,
      isFalse,
    );
    await tester.tap(find.byTooltip('继续录音'));
    await tester.tap(find.byTooltip('展开独白'));
    expect(resumeCalls, 1);
    expect(expandCalls, 1);
  });

  testWidgets('compact monologue scrolls long text and edits without expand', (
    tester,
  ) async {
    _setPhoneViewport(tester);
    final longTranscript = List<String>.generate(
      24,
      (index) => '第 ${index + 1} 行独白内容会完整保留',
    ).join('\n');
    final editor = TextEditingController(text: longTranscript);
    addTearDown(editor.dispose);
    String? editedText;
    final callbacks = _MonologueCallbacks();
    await tester.pumpWidget(
      _sheetApp(
        V3MonologueQuickCaptureSheet(
          recording: MonologueRecordingState(
            status: MonologueRecordingStatus.paused,
            nativeCaptureLatch: MonologueNativeCaptureLatch.paused,
            elapsedSeconds: 18,
            transcriptText: longTranscript,
          ),
          transcript: const LiveTranscriptState(
            status: LiveTranscriptStatus.idle,
          ),
          transcriptController: editor,
          onTranscriptChanged: (value) => editedText = value,
          onClose: callbacks.close,
          onExpand: callbacks.expand,
          onStart: callbacks.start,
          onPause: callbacks.pause,
          onResume: callbacks.resume,
          onDone: callbacks.done,
        ),
      ),
    );
    await tester.pump();

    final field = tester.widget<TextField>(
      find.byKey(const ValueKey<String>('monologue-transcript-editor')),
    );
    expect(field.maxLines, isNull);
    expect(field.readOnly, isFalse);
    expect(field.scrollController, isNotNull);
    expect(field.scrollController!.position.maxScrollExtent, greaterThan(0));

    await tester.enterText(
      find.byKey(const ValueKey<String>('monologue-transcript-editor')),
      '$longTranscript\n用户在小窗完成修改',
    );
    expect(editedText, endsWith('用户在小窗完成修改'));
    expect(find.byTooltip('继续录音'), findsOneWidget);
    expect(find.byTooltip('完成录音'), findsOneWidget);
  });

  testWidgets('compact paused editor and actions stay above the keyboard', (
    tester,
  ) async {
    const size = Size(320, 568);
    _setPhoneViewport(tester, size: size);
    final callbacks = _MonologueCallbacks();
    await tester.pumpWidget(
      _sheetApp(
        MediaQuery(
          data: const MediaQueryData(
            size: size,
            viewInsets: EdgeInsets.only(bottom: 300),
            textScaler: TextScaler.linear(1.3),
          ),
          child: V3MonologueQuickCaptureSheet(
            recording: _recording(MonologueRecordingStatus.paused),
            transcript: _transcript,
            onClose: callbacks.close,
            onExpand: callbacks.expand,
            onStart: callbacks.start,
            onPause: callbacks.pause,
            onResume: callbacks.resume,
            onDone: callbacks.done,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final sheet = find.byKey(const ValueKey('monologue-quick-sheet'));
    expect(tester.getSize(sheet).height, lessThanOrEqualTo(268));
    expect(
      find
          .byKey(const ValueKey<String>('monologue-transcript-editor'))
          .hitTestable(),
      findsOneWidget,
    );
    expect(find.byTooltip('继续录音').hitTestable(), findsOneWidget);
    expect(find.byTooltip('完成录音').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact monologue separates scaled copy on a short phone', (
    tester,
  ) async {
    const size = Size(320, 568);
    _setPhoneViewport(tester, size: size);
    final callbacks = _MonologueCallbacks();
    await tester.pumpWidget(
      _sheetApp(
        MediaQuery(
          data: const MediaQueryData(
            size: size,
            textScaler: TextScaler.linear(1.3),
          ),
          child: V3MonologueQuickCaptureSheet(
            recording: _recording(MonologueRecordingStatus.recording),
            transcript: _transcript,
            onClose: callbacks.close,
            onExpand: callbacks.expand,
            onStart: callbacks.start,
            onPause: callbacks.pause,
            onResume: callbacks.resume,
            onDone: callbacks.done,
          ),
        ),
      ),
    );
    await tester.pump();

    final sheet = find.byKey(const ValueKey('monologue-quick-sheet'));
    expect(tester.getSize(sheet).height, lessThanOrEqualTo(size.height));
    expect(
      tester
          .getBottomLeft(
            find.byKey(const ValueKey('monologue-transcript-scroll')),
          )
          .dy,
      lessThanOrEqualTo(tester.getTopLeft(find.byTooltip('暂停录音')).dy),
    );
    expect(tester.takeException(), isNull);
    expect(find.byTooltip('暂停录音').hitTestable(), findsOneWidget);
    expect(find.byTooltip('完成录音').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('M01 compact text matches Mobile V5 and edits', (tester) async {
    _setPhoneViewport(tester);
    final title = TextEditingController();
    final body = TextEditingController();
    addTearDown(title.dispose);
    addTearDown(body.dispose);
    var checklistCalls = 0;
    var continueCalls = 0;
    await tester.pumpWidget(
      _sheetApp(
        V3TextQuickCaptureSheet(
          titleController: title,
          bodyController: body,
          onClose: () {},
          onExpand: () {},
          onAdd: () {},
          onChecklist: () => checklistCalls += 1,
          onImage: () {},
          onContinue: () => continueCalls += 1,
        ),
      ),
    );

    await expectLater(
      find.byType(V3TextQuickCaptureSheet),
      matchesGoldenFile('goldens/note_quick_editing.png'),
    );
    await tester.enterText(
      find.byKey(const ValueKey('text-quick-body')),
      '新的想法',
    );
    await tester.tap(find.byTooltip('清单'));
    await tester.tap(find.byKey(const ValueKey('text-quick-continue')));
    expect(body.text, '新的想法');
    expect(checklistCalls, 1);
    expect(continueCalls, 1);
  });

  testWidgets('compact text keeps its toolbar above the keyboard', (
    tester,
  ) async {
    const size = Size(320, 568);
    _setPhoneViewport(tester, size: size);
    final keyboardInset = ValueNotifier<double>(0);
    final title = TextEditingController();
    final body = TextEditingController();
    addTearDown(keyboardInset.dispose);
    addTearDown(title.dispose);
    addTearDown(body.dispose);

    await tester.pumpWidget(
      _sheetApp(
        ValueListenableBuilder<double>(
          valueListenable: keyboardInset,
          builder: (context, inset, _) => MediaQuery(
            data: MediaQueryData(
              size: size,
              viewInsets: EdgeInsets.only(bottom: inset),
              textScaler: const TextScaler.linear(1.3),
            ),
            child: V3TextQuickCaptureSheet(
              titleController: title,
              bodyController: body,
              onClose: () {},
              onExpand: () {},
              onAdd: () {},
              onChecklist: () {},
              onImage: () {},
              onContinue: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final bodyField = find.byKey(const ValueKey('text-quick-body'));
    await tester.tap(bodyField);
    await tester.pump();
    expect(tester.widget<TextField>(bodyField).focusNode?.hasFocus, isTrue);

    keyboardInset.value = 300;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 180));

    final keyboardTop =
        tester.view.physicalSize.height / tester.view.devicePixelRatio - 300;
    final sheet = find.byKey(const ValueKey('text-quick-sheet'));
    final titleField = find.byKey(const ValueKey('text-quick-title'));
    expect(tester.getBottomRight(sheet).dy, lessThanOrEqualTo(keyboardTop));
    expect(titleField.hitTestable(), findsOneWidget);
    await tester.ensureVisible(bodyField);
    await tester.pump();
    expect(bodyField.hitTestable(), findsOneWidget);
    expect(tester.widget<TextField>(bodyField).focusNode?.hasFocus, isTrue);
    expect(
      tester
          .getBottomRight(find.byKey(const ValueKey('text-quick-continue')))
          .dy,
      lessThanOrEqualTo(keyboardTop),
    );
    expect(
      find.byKey(const ValueKey('text-quick-continue')).hitTestable(),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact text expands with its exact draft', (tester) async {
    _setPhoneViewport(tester);
    String? presentation;
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => showV3TextQuickCapture(context),
                child: const Text('新建文字'),
              ),
            ),
          ),
        ),
        GoRoute(
          path: '/v3/feed/note',
          builder: (context, state) {
            presentation = state.uri.queryParameters['presentation'];
            final draft = state.extra! as Map<String, String>;
            return Text('${draft['title']}|${draft['body']}');
          },
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));

    await tester.tap(find.text('新建文字'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('text-quick-title')),
      '弹窗标题',
    );
    await tester.enterText(
      find.byKey(const ValueKey('text-quick-body')),
      '弹窗正文',
    );
    await tester.tap(find.byTooltip('展开文字编辑'));
    await tester.pumpAndSettle();

    expect(find.text('弹窗标题|弹窗正文'), findsOneWidget);
    expect(presentation, 'sheet');
    expect(find.byKey(const ValueKey('text-quick-sheet')), findsNothing);
  });

  testWidgets(
    'compact monologue savingNote keeps transcript and locks actions',
    (tester) async {
      _setPhoneViewport(tester);
      final callbacks = _MonologueCallbacks();
      await tester.pumpWidget(
        _sheetApp(
          V3MonologueQuickCaptureSheet(
            recording: _recording(MonologueRecordingStatus.savingNote),
            transcript: _transcript,
            onClose: callbacks.close,
            onExpand: callbacks.expand,
            onStart: callbacks.start,
            onPause: callbacks.pause,
            onResume: callbacks.resume,
            onDone: callbacks.done,
          ),
        ),
      );

      expect(find.text('正在保存笔记'), findsOneWidget);
      expect(find.text(_monologueTranscriptText), findsOneWidget);
      expect(find.text('保存中'), findsOneWidget);
      final action = tester.widget<IconButton>(find.byType(IconButton).last);
      expect(action.onPressed, isNull);
    },
  );

  testWidgets('M01 text processing matches Mobile V5', (tester) async {
    _setPhoneViewport(tester, safeTop: 54);
    await tester.pumpWidget(
      _pageApp(
        V3MaterialImportProgressSurface(
          sourceLabel: '今日随想',
          sourceIcon: Icons.link_rounded,
          title: '文字整理中...',
          message: '正在提取主题与结构，完成后会自动保存为笔记。',
          onBack: () {},
        ),
      ),
    );
    await expectLater(
      find.byType(V3MaterialImportProgressSurface),
      matchesGoldenFile('goldens/note_processing.png'),
    );
  });

  testWidgets('full monologue ready has a bordered realtime editor', (
    tester,
  ) async {
    _setPhoneViewport(tester, safeTop: 54);
    final editor = TextEditingController();
    addTearDown(editor.dispose);
    await tester.pumpWidget(
      _pageApp(
        V3MonologueCaptureSurface(
          recording: MonologueRecordingState.initial(),
          liveTranscript: const LiveTranscriptState(
            status: LiveTranscriptStatus.idle,
          ),
          transcriptController: editor,
          hasHistory: false,
          onBack: () {},
          onHistory: () {},
          onDone: () {},
          onStatusTap: null,
          onPrimaryTap: () {},
          supplementary: const SizedBox.shrink(),
        ),
      ),
    );
    final transcript = tester.widget<TextField>(
      find.byKey(const ValueKey<String>('monologue-transcript-editor')),
    );
    expect(transcript.readOnly, isTrue);
    expect(transcript.decoration?.enabledBorder, isA<OutlineInputBorder>());
    expect(find.text('开始独白'), findsOneWidget);
  });

  testWidgets('full monologue paused makes the transcript editable', (
    tester,
  ) async {
    _setPhoneViewport(tester, safeTop: 54);
    final editor = TextEditingController(
      text: '我刚刚想到，真正有价值的笔记，\n不是把信息存下来，而是让不同时间\n的想法能够重新相遇。\n\n也许，整理本身就是一次新的思考。',
    );
    addTearDown(editor.dispose);
    await tester.pumpWidget(
      _pageApp(
        V3MonologueCaptureSurface(
          recording: _recording(MonologueRecordingStatus.paused),
          liveTranscript: _transcript,
          transcriptController: editor,
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
    final transcript = find.byKey(
      const ValueKey<String>('monologue-transcript-editor'),
    );
    expect(tester.widget<TextField>(transcript).readOnly, isFalse);
    expect(find.text('可编辑'), findsOneWidget);
    expect(find.textContaining('录音已暂停，可修改文字'), findsOneWidget);
    expect(find.text('继续转写'), findsOneWidget);
  });
}

MonologueRecordingState _recording(MonologueRecordingStatus status) =>
    MonologueRecordingState(
      status: status,
      nativeCaptureLatch: switch (status) {
        MonologueRecordingStatus.recording ||
        MonologueRecordingStatus.pausing ||
        MonologueRecordingStatus.resuming =>
          MonologueNativeCaptureLatch.recording,
        MonologueRecordingStatus.paused => MonologueNativeCaptureLatch.paused,
        _ => MonologueNativeCaptureLatch.none,
      },
      elapsedSeconds: 18,
      transcriptText: _monologueTranscriptText,
    );

const _monologueTranscriptText =
    '真正有价值的笔记，不只是把信息存下来。\n当不同时间的想法再次相遇，它们会产生新的联系。\n整理本身，也许就是一次新的思考。';

final _transcript = LiveTranscriptState(
  status: LiveTranscriptStatus.transcribing,
  sentences: <LiveTranscriptSentence>[
    LiveTranscriptSentence(
      sentenceId: 1,
      text: '真正有价值的笔记，不只是把信息存下来。\n当不同时间的想法再次相遇，它们会产生新的联系。',
      stable: true,
    ),
    LiveTranscriptSentence(
      sentenceId: 2,
      text: '整理本身，也许就是一次新的思考。',
      stable: false,
    ),
  ],
);

final class _MonologueCallbacks {
  _MonologueCallbacks({
    VoidCallback? onClose,
    VoidCallback? onExpand,
    VoidCallback? onStart,
    VoidCallback? onPause,
    VoidCallback? onResume,
    VoidCallback? onDone,
  }) : close = onClose ?? _noop,
       expand = onExpand ?? _noop,
       start = onStart ?? _noop,
       pause = onPause ?? _noop,
       resume = onResume ?? _noop,
       done = onDone ?? _noop;

  final VoidCallback close;
  final VoidCallback expand;
  final VoidCallback start;
  final VoidCallback pause;
  final VoidCallback resume;
  final VoidCallback done;

  static void _noop() {}
}

Widget _sheetApp(Widget sheet) => MaterialApp(
  theme: figmaGoldenTheme(),
  home: Scaffold(
    resizeToAvoidBottomInset: false,
    backgroundColor: const Color(0xffd2d2d2),
    body: Align(alignment: Alignment.bottomCenter, child: sheet),
  ),
);

Widget _pageApp(Widget page) =>
    MaterialApp(theme: figmaGoldenTheme(), home: page);

void _setPhoneViewport(
  WidgetTester tester, {
  Size size = const Size(402, 874),
  double safeTop = 0,
}) {
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1
    ..padding = FakeViewPadding(top: safeTop, bottom: safeTop == 0 ? 0 : 34);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPadding);
}
