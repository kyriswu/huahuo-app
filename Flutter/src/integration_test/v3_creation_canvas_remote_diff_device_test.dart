import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:huahuoai_app/app/bootstrap/app_providers.dart';
import 'package:huahuoai_app/features/ui_v3/application/canvas_ai_inline_review.dart';
import 'package:huahuoai_app/features/ui_v3/application/canvas_autosave_coordinator.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_library_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_note_port.dart';
import 'package:huahuoai_app/features/ui_v3/application/profile_hub_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/script_draft_controller.dart';
import 'package:huahuoai_app/features/ui_v3/data/canvas_ai_transform_port.dart';
import 'package:huahuoai_app/features/ui_v3/data/creation_canvas_history_port.dart';
import 'package:huahuoai_app/features/ui_v3/domain/canvas_ai_models.dart';
import 'package:huahuoai_app/features/ui_v3/domain/creation_canvas_draft.dart';
import 'package:huahuoai_app/features/ui_v3/domain/feed_item_models.dart';
import 'package:huahuoai_app/features/ui_v3/domain/script_draft_models.dart';
import 'package:huahuoai_app/features/ui_v3/domain/ui_v3_models.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_creation_canvas_page.dart';
import 'package:huahuoai_app/main.dart' as app;
import 'package:huahuoai_app/shared/navigation/unsaved_changes_guard.dart';
import 'package:huahuoai_app/shared/theme/huahuo_v3_theme.dart';
import 'package:integration_test/integration_test.dart';

import '../test/support/mobile_agent_test_support.dart';

const _canvasInitialRoute = '/v3/workbench/canvas';
const _configuredInitialRoute = String.fromEnvironment(
  'HUAHUO_V3_INITIAL_ROUTE',
);
const _globalDiffScreenshotName =
    'v18_creation_canvas_global_remote_diff_device_actual';
const _localDiffScreenshotName =
    'v18_creation_canvas_local_remote_diff_device_actual';
const _expectedGlobalResult =
    '经过验证的表达创作者会把灵感停在脑海里。\n'
    '今天先记录一个真实场景，再决定下一步。\n'
    '需求深化\n'
    '表层需求：从原文中确认当前最直接、最具体的问题。\n'
    '深层动机：继续追问为什么现在需要解决，以及理想变化是什么。\n'
    '现实影响：说明问题不处理会影响哪些过程或结果，不补写未经证实的数据。\n'
    '完成标准：把目标改写为可以观察、比较或验证的结果。\n';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'renders and applies simulated remote diff files for global and local AI edits',
    (tester) async {
      expect(
        huahuoV3UiEnabled,
        isTrue,
        reason: 'Run with --dart-define=HUAHUO_V3_UI=true.',
      );
      expect(
        canvasDebugRemoteDiffEnabled,
        isTrue,
        reason: 'Run with --dart-define=HUAHUO_CANVAS_DEBUG_REMOTE_DIFF=true.',
      );
      expect(
        huahuoV3DemoAuthBypassEnabled,
        isTrue,
        reason: 'Run with --dart-define=HUAHUO_V3_DEMO_AUTH=true.',
      );
      expect(
        _configuredInitialRoute,
        _canvasInitialRoute,
        reason:
            'Run with --dart-define=HUAHUO_V3_INITIAL_ROUTE=$_canvasInitialRoute.',
      );

      await app.main();
      await tester.pump();
      await _waitForCanvas(tester);
      await _pumpAnimationFrames(tester, frames: 8);

      final editor = tester.widget<QuillEditor>(
        find.byKey(const ValueKey<String>('canvas-body-field')),
      );
      final controller = editor.controller;

      const globalSource = '很多内容创作者会把灵感停在脑海里。\n\n今天先记录一个真实场景，再决定下一步。';
      await _enterGlobalSource(tester, controller, globalSource);

      await _requestCanvasDiffPreview(
        tester,
        action: CanvasAiAction.needsDeepening,
      );
      _expectColoredDiffPreview(tester, deletedFragment: '很多内容');
      await _settlePreviewForScreenshot(tester);
      expect(
        await binding.takeScreenshot(_globalDiffScreenshotName),
        isNotEmpty,
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('canvas-ai-apply')).hitTestable(),
      );
      await _pumpAnimationFrames(tester, frames: 5);
      final globalResult = controller.document.toPlainText();
      expect(globalResult, _expectedGlobalResult);

      const selected = '中间这段需要更清楚。';
      const localSource = '开头保持不变。$selected结尾保持不变。';
      final selectionStart = localSource.indexOf(selected);
      controller.replaceText(
        0,
        controller.document.length - 1,
        localSource,
        TextSelection.collapsed(offset: selectionStart + selected.length),
      );
      controller.updateSelection(
        TextSelection(
          baseOffset: selectionStart,
          extentOffset: selectionStart + selected.length,
        ),
        ChangeSource.local,
      );
      await _pumpAnimationFrames(tester, frames: 3);

      await _requestCanvasDiffPreview(tester);
      _expectColoredDiffPreview(tester, deletedFragment: '中间这段');
      await _settlePreviewForScreenshot(tester);
      expect(
        await binding.takeScreenshot(_localDiffScreenshotName),
        isNotEmpty,
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('canvas-ai-apply')).hitTestable(),
      );
      await _pumpAnimationFrames(tester, frames: 5);
      final localResult = controller.document.toPlainText();
      expect(localResult, '开头保持不变。经过验证的表达需要更清楚。\n进一步说明时，结尾保持不变。\n');
      expect(localResult, isNot(contains(selected)));
      expect(tester.takeException(), isNull);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  testWidgets(
    'completes the Agent note ownership and bound-exit journey on iOS',
    (tester) async {
      expect(defaultTargetPlatform, TargetPlatform.iOS);
      final source = V3FeedItem(
        id: 'device-agent-source',
        title: '设备端 Agent 来源',
        source: V3MaterialSource.note,
        createdAt: DateTime.utc(2026, 9, 15),
        rawBody: '设备端冻结的来源正文',
        remoteNoteId: 'remote-device-agent-source',
        rawPartRevisionId: 'raw-device-agent-source-1',
      );
      final seed = AssetCanvasSeed.tryFromItem(
        item: source,
        stage: V3ContentStage.raw,
      )!.withInitialSourceMode(AssetCanvasInitialSourceMode.generateTranscript);
      final drafts = _DeviceCanvasDraftStore();
      final history = InMemoryCreationCanvasHistoryPort();
      final library = KnowledgeLibraryController(
        initialNotes: <V3FeedItem>[source],
        notePort: const _DeviceKnowledgeNotePort(),
        includeDemoFixtures: false,
      );
      String? createdId;
      final router = GoRouter(
        initialLocation: '/canvas',
        routes: <RouteBase>[
          GoRoute(
            path: '/canvas',
            builder: (_, __) => V3CreationCanvasPage(
              entryIntent: CanvasEntryIntent.asset(seed),
            ),
          ),
          GoRoute(
            path: '/history',
            builder: (_, __) => V3CreationCanvasPage(
              entryIntent: CanvasEntryIntent.history(createdId!),
            ),
          ),
          GoRoute(
            path: '/v3/feed/items/:itemId',
            builder: (_, state) => Scaffold(
              body: Center(
                child: Text('device-detail:${state.pathParameters['itemId']}'),
              ),
            ),
          ),
          GoRoute(
            path: '/v3',
            builder: (_, __) =>
                const Scaffold(body: Center(child: Text('设备测试工作台'))),
          ),
        ],
      );
      addTearDown(() {
        router.dispose();
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            ...mobileAgentReadyTestOverrides(),
            resolvedDeviceIdProvider.overrideWithValue(
              'device-free-creation-test',
            ),
            authenticatedUserDataScopeProvider.overrideWithValue(
              'device-free-creation-user',
            ),
            creationCanvasDraftRepositoryProvider.overrideWithValue(drafts),
            creationCanvasHistoryPortProvider.overrideWithValue(history),
            knowledgeLibraryControllerProvider.overrideWith((_) => library),
            knowledgeLibraryAutoSyncOwnedChangesProvider.overrideWithValue(
              false,
            ),
            profileHubControllerProvider.overrideWith(
              (_) => ProfileHubController(),
            ),
            canvasAiTransformPortProvider.overrideWithValue(
              const CanvasAiTransformMockPort(delay: Duration.zero),
            ),
            scriptDraftGenerationPortProvider.overrideWithValue(
              const _DeviceScriptDraftPort(),
            ),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await _waitForDeviceCondition(
        tester,
        () =>
            find
                .byKey(const ValueKey<String>('canvas-body-field'))
                .evaluate()
                .isNotEmpty &&
            library.notes.length == 2,
      );
      await _waitForDeviceCondition(
        tester,
        () => find.text('已保存').evaluate().isNotEmpty,
      );

      expect(find.text('保存为新笔记？'), findsNothing);
      expect(library.noteForId(source.id)?.rawBody, source.rawBody);
      createdId = library.notes.singleWhere((note) => note.id != source.id).id;
      expect(library.noteForId(createdId)?.rawBody, '设备端生成的新笔记正文');

      final titleField = find.byKey(
        const ValueKey<String>('canvas-title-field'),
      );
      await tester.tap(titleField);
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey<String>('canvas-ai-tools')).hitTestable(),
      );
      await _pumpAnimationFrames(tester, frames: 4);
      expect(
        find.byKey(const ValueKey<String>('canvas-ai-action-list')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('canvas-edit-mode')).hitTestable(),
      );
      await _pumpAnimationFrames(tester, frames: 3);
      expect(
        find.byKey(const ValueKey<String>('canvas-ai-action-list')),
        findsNothing,
      );

      final editor = tester.widget<QuillEditor>(
        find.byKey(const ValueKey<String>('canvas-body-field')),
      );
      const updatedBody = '设备端保存后的同一篇笔记正文';
      editor.controller.replaceText(
        0,
        editor.controller.document.length - 1,
        updatedBody,
        const TextSelection.collapsed(offset: updatedBody.length),
      );
      await tester.pump();
      await _waitForDeviceCondition(
        tester,
        () => find.text('修改未保存').evaluate().isNotEmpty,
      );

      await tester.tap(
        find.byKey(const ValueKey<String>('canvas-save')).hitTestable(),
      );
      await _waitForDeviceCondition(
        tester,
        () => find.text('确认保存').hitTestable().evaluate().isNotEmpty,
      );
      await tester.tap(find.text('确认保存').hitTestable());
      await _waitForDeviceCondition(
        tester,
        () => find.text('device-detail:$createdId').evaluate().isNotEmpty,
      );

      expect(library.notes, hasLength(2));
      expect(library.noteForId(createdId)?.rawBody, updatedBody);
      expect(library.noteForId(source.id)?.rawBody, source.rawBody);

      final outgoingGuardKey = tester
          .widget<UnsavedChangesGuard>(find.byType(UnsavedChangesGuard))
          .key;
      router.go('/history');
      await _waitForDeviceCondition(tester, () {
        final bodyFinder = find.byKey(
          const ValueKey<String>('canvas-body-field'),
        );
        final guardFinder = find.byType(UnsavedChangesGuard);
        if (bodyFinder.evaluate().length != 1 ||
            guardFinder.evaluate().length != 1) {
          return false;
        }
        final body = tester.widget<QuillEditor>(bodyFinder);
        final guard = tester.widget<UnsavedChangesGuard>(guardFinder);
        return body.controller.document.toPlainText().trim() == updatedBody &&
            guard.key != outgoingGuardKey &&
            find.text('已保存').evaluate().isNotEmpty;
      });
      final historyEditor = tester.widget<QuillEditor>(
        find.byKey(const ValueKey<String>('canvas-body-field')),
      );
      const discardedBody = '设备端决定放弃的修改';
      historyEditor.controller.replaceText(
        0,
        historyEditor.controller.document.length - 1,
        discardedBody,
        const TextSelection.collapsed(offset: discardedBody.length),
      );
      await tester.pump();
      await _waitForDeviceCondition(
        tester,
        () => find.text('修改未保存').evaluate().isNotEmpty,
      );

      await _tapDeviceCanvasBack(tester);
      await _waitForDeviceCondition(
        tester,
        () =>
            find.text('不保存并退出').hitTestable().evaluate().isNotEmpty &&
            find.text('继续编辑').hitTestable().evaluate().isNotEmpty,
      );
      expect(find.text('保留草稿并退出'), findsNothing);
      await tester.tap(find.text('继续编辑').hitTestable());
      await _pumpAnimationFrames(tester, frames: 3);
      expect(find.text('修改未保存'), findsOneWidget);

      await _tapDeviceCanvasBack(tester);
      await _waitForDeviceCondition(
        tester,
        () => find.text('不保存并退出').hitTestable().evaluate().isNotEmpty,
      );
      await tester.tap(find.text('不保存并退出').hitTestable());
      await _waitForDeviceCondition(
        tester,
        () => find.text('设备测试工作台').evaluate().isNotEmpty,
      );

      expect(library.noteForId(createdId)?.rawBody, updatedBody);
      expect(drafts.load(), isNull);
      expect(tester.takeException(), isNull);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

Future<void> _waitForDeviceCondition(
  WidgetTester tester,
  bool Function() condition,
) async {
  for (var attempt = 0; attempt < 200 && !condition(); attempt++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await tester.pump(const Duration(milliseconds: 20));
  }
  final visibleText = tester
      .widgetList<Text>(find.byType(Text))
      .map((widget) => widget.data)
      .whereType<String>()
      .join(' | ');
  expect(condition(), isTrue, reason: 'visible=$visibleText');
}

Future<void> _tapDeviceCanvasBack(WidgetTester tester) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await _pumpAnimationFrames(tester, frames: 5);
  final guardFinder = find.byType(UnsavedChangesGuard);
  expect(guardFinder, findsOneWidget);
  final guard = tester.widget<UnsavedChangesGuard>(guardFinder);
  expect(guard.hasUnsavedChanges, isTrue);
  expect(guard.hasUnsavedChangesNow?.call(), isTrue);
  unawaited(
    UnsavedChangesGuard.requestLeave(
      tester.element(find.byKey(const ValueKey<String>('canvas-body-field'))),
    ),
  );
  await tester.pump();
}

Future<void> _requestCanvasDiffPreview(
  WidgetTester tester, {
  CanvasAiAction action = CanvasAiAction.expansion,
}) async {
  await tester.tap(
    find.byKey(const ValueKey<String>('canvas-ai-tools')).hitTestable(),
  );
  await _pumpAnimationFrames(tester, frames: 4);
  final actionFinder = find.byKey(
    ValueKey<String>('canvas-ai-action-${action.name}'),
  );
  await tester.ensureVisible(actionFinder);
  await tester.tap(actionFinder.hitTestable());
  await _waitForDiffPreview(tester);
}

Future<void> _enterGlobalSource(
  WidgetTester tester,
  QuillController controller,
  String source,
) async {
  controller.replaceText(
    0,
    controller.document.length - 1,
    '',
    const TextSelection.collapsed(offset: 0),
  );
  await tester.pump();
  final priorText = controller.plainTextEditingValue.text;
  final editor = tester.widget<QuillEditor>(
    find.byKey(const ValueKey<String>('canvas-body-field')),
  );
  editor.focusNode.requestFocus();
  await tester.pump();
  expect(editor.focusNode.hasFocus, isTrue);
  tester.testTextInput.updateEditingValue(
    TextEditingValue(
      text: '$source\n',
      selection: TextSelection.collapsed(offset: priorText.length),
    ),
  );
  await tester.idle();
  await _pumpAnimationFrames(tester, frames: 3);
  expect(controller.document.toPlainText(), contains(source));
}

Future<void> _waitForDiffPreview(WidgetTester tester) async {
  final preview = find.byKey(const ValueKey<String>('canvas-ai-diff-preview'));
  const pollInterval = Duration(milliseconds: 100);
  for (var attempt = 0; attempt < 80; attempt++) {
    if (preview.hitTestable().evaluate().isNotEmpty) return;
    await Future<void>.delayed(pollInterval);
    await tester.pump();
  }
  expect(
    preview.hitTestable(),
    findsOneWidget,
    reason: 'The simulated remote diff did not reach a review state.',
  );
}

Future<void> _settlePreviewForScreenshot(WidgetTester tester) async {
  await Future<void>.delayed(const Duration(milliseconds: 700));
  await tester.pump();
  await Future<void>.delayed(const Duration(milliseconds: 150));
}

void _expectColoredDiffPreview(
  WidgetTester tester, {
  required String deletedFragment,
}) {
  expect(find.text('删除内容'), findsOneWidget);
  expect(find.text('保留内容'), findsOneWidget);
  final inline = find.byKey(const ValueKey<String>('canvas-ai-inline-editor'));
  final editor = tester.widget<QuillEditor>(inline);
  final operations = editor.controller.document.toDelta().toList();
  final dark = Theme.of(tester.element(inline)).brightness == Brightness.dark;
  final deletedColor = dark ? const Color(0xFFFFB4AB) : const Color(0xFFB42318);
  final retainedColor = dark
      ? const Color(0xFF81C995)
      : const Color(0xFF137333);
  for (final change in CanvasReviewChange.values) {
    final marked = operations
        .where(
          (operation) =>
              CanvasAiInlineReview.changeFor(operation.attributes) == change,
        )
        .toList();
    expect(
      marked.map((operation) => operation.data).join(),
      contains(
        change == CanvasReviewChange.deleted ? deletedFragment : '经过验证的表达',
      ),
    );
    final style = editor.config.customStyleBuilder!(
      Attribute.clone(Attribute.token, marked.first.attributes!['token']),
    );
    expect(
      style.color,
      change == CanvasReviewChange.deleted ? deletedColor : retainedColor,
    );
    expect(style.backgroundColor, isNotNull);
    if (change == CanvasReviewChange.deleted) {
      expect(style.decoration, TextDecoration.lineThrough);
    }
  }
  expect(
    ModalRoute.of(
      tester.element(
        find.byKey(const ValueKey<String>('canvas-ai-confirmation')),
      ),
    ),
    isA<PageRoute>(),
  );
}

Future<void> _waitForCanvas(WidgetTester tester) async {
  final canvasBody = find.byKey(const ValueKey<String>('canvas-body-field'));
  const pollInterval = Duration(milliseconds: 100);
  for (var attempt = 0; attempt < 50; attempt++) {
    if (canvasBody.hitTestable().evaluate().isNotEmpty) return;
    await Future<void>.delayed(pollInterval);
    await tester.pump();
  }
  expect(canvasBody.hitTestable(), findsOneWidget);
}

Future<void> _pumpAnimationFrames(
  WidgetTester tester, {
  required int frames,
}) async {
  for (var frame = 0; frame < frames; frame++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

final class _DeviceCanvasDraftStore implements CreationCanvasDraftStore {
  CreationCanvasDraft? _draft;

  @override
  String get userScope => 'device-free-creation-user';

  @override
  CreationCanvasDraft? load() => _draft;

  @override
  void upsert(CreationCanvasDraft draft) => _draft = draft;

  @override
  Future<void> upsertDeferred(CreationCanvasDraft draft) async {
    _draft = draft;
  }

  @override
  bool clear() {
    final existed = _draft != null;
    _draft = null;
    return existed;
  }

  @override
  Future<bool> clearDeferred() async => clear();
}

final class _DeviceKnowledgeNotePort implements KnowledgeNotePort {
  const _DeviceKnowledgeNotePort();

  @override
  Future<KnowledgeNotePortResult> updateNote(
    KnowledgeNoteUpdateRequest request,
  ) async {
    final source =
        request.localNote ??
        V3FeedItem(
          id: request.noteId,
          title: request.draft.title,
          source: V3MaterialSource.note,
          createdAt: DateTime.utc(2026, 9, 15),
          rawBody: request.draft.rawBody,
        );
    return KnowledgeNotePortResult.success(
      source.copyWith(
        title: request.draft.title,
        rawBody: request.draft.rawBody,
        localRevision: request.localRevision,
        remoteRevision: 1,
        remoteNoteId: request.remoteNoteId ?? 'remote-${request.noteId}',
        noteRevisionId: 'device-note-revision-1',
        rawPartRevisionId: 'device-raw-revision-1',
        etag: '"device-note-1"',
        contentCursor: 'device-cursor-1',
      ),
    );
  }
}

final class _DeviceScriptDraftPort implements ScriptDraftGenerationPort {
  const _DeviceScriptDraftPort();

  @override
  Future<String> createThread({required String idempotencyKey}) async =>
      'device-script-thread';

  @override
  Future<String> submit({
    required String threadId,
    required ScriptDraftRequest request,
    required String idempotencyKey,
  }) async => 'device-script-run';

  @override
  Future<Stream<ScriptDraftStreamSignal>> streamEvents({
    required String agentRunId,
    required int afterSequence,
  }) async => Stream<ScriptDraftStreamSignal>.fromIterable(
    const <ScriptDraftStreamSignal>[
      ScriptDraftStreamSignal.event(
        ScriptDraftRemoteEvent(sequence: 1, status: 'succeeded'),
      ),
    ],
  );

  @override
  Future<ScriptDraftEventPage> readEvents({
    required String agentRunId,
    required int afterSequence,
  }) async => ScriptDraftEventPage(
    items: const <ScriptDraftRemoteEvent>[],
    nextAfterSequence: afterSequence,
    hasMore: false,
    gap: false,
    oldestAvailableSequence: afterSequence,
  );

  @override
  Future<ScriptDraftRunSnapshot> getRun({required String agentRunId}) async =>
      const ScriptDraftRunSnapshot(
        status: 'succeeded',
        completionMode: 'normal',
        finalAnswer: '设备端生成的新笔记正文',
      );

  @override
  Future<void> cancelRun({
    required String agentRunId,
    required String idempotencyKey,
  }) async {}
}
