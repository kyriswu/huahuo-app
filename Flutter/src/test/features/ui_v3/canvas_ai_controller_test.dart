import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/app/bootstrap/app_providers.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/database/diagnostic_log_dao.dart';
import 'package:huahuoai_app/core/diagnostics/diagnostic_logger.dart';
import 'package:huahuoai_app/features/ui_v3/application/canvas_ai_controller.dart';
import 'package:huahuoai_app/features/ui_v3/data/canvas_ai_transform_port.dart';
import 'package:huahuoai_app/features/ui_v3/domain/canvas_ai_models.dart';

void main() {
  test('AI newline admission preserves code, URLs and baseline examples', () {
    for (final candidate in [
      '正文\n\n正常分段',
      '示例 `/n/n` 和 `\\n\\n` 不应变更',
      '```text\n/n/n\n\\n\\n\n```\n说明',
      '~~~text\n/n/n\n~~~\n说明',
      '地址 https://example.com/n/n 和 [文档](/n/n)',
    ]) {
      expect(
        canvasAiIntroducesInvalidLineBreaks(
          sourceMarkdown: '正文',
          candidateMarkdown: candidate,
        ),
        isFalse,
        reason: candidate,
      );
    }
    expect(
      canvasAiIntroducesInvalidLineBreaks(
        sourceMarkdown: '旧文已包含 /n/n',
        candidateMarkdown: '旧文已包含 /n/n，新增说明',
      ),
      isFalse,
    );
    expect(
      canvasAiIntroducesInvalidLineBreaks(
        sourceMarkdown: '旧文已包含 /n/n',
        candidateMarkdown: '旧文已包含 /n/n，新增 /n/n 错误',
      ),
      isTrue,
    );
  });

  test('provider scope preserves one owner and isolates a second owner', () {
    final database = AppDatabase();
    final logger = DiagnosticLogger(dao: DiagnosticLogDao(database));
    final container = ProviderContainer(
      overrides: <Override>[
        canvasAiTransformPortProvider.overrideWithValue(_CountingPort()),
        diagnosticLoggerProvider.overrideWithValue(logger),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(logger.dispose);
    final firstOwner = Object();
    final secondOwner = Object();

    final first = container.read(
      canvasAiControllerProvider(
        CanvasAiControllerScope(owner: firstOwner, sessionId: 'same-session'),
      ),
    );
    final sameScope = container.read(
      canvasAiControllerProvider(
        CanvasAiControllerScope(owner: firstOwner, sessionId: 'same-session'),
      ),
    );
    final otherOwner = container.read(
      canvasAiControllerProvider(
        CanvasAiControllerScope(owner: secondOwner, sessionId: 'same-session'),
      ),
    );

    expect(identical(first, sameScope), isTrue);
    expect(identical(first, otherOwner), isFalse);
  });

  test(
    'session family rebuilds never reuse an Agent operation namespace',
    () async {
      final database = AppDatabase();
      final logger = DiagnosticLogger(dao: DiagnosticLogDao(database));
      final port = _CountingPort();
      addTearDown(logger.dispose);

      final owner = Object();
      Future<String> generateFromFreshContainer(String sessionId) async {
        final container = ProviderContainer(
          overrides: <Override>[
            canvasAiTransformPortProvider.overrideWithValue(port),
            diagnosticLoggerProvider.overrideWithValue(logger),
          ],
        );
        final controller = container.read(
          canvasAiControllerProvider(
            CanvasAiControllerScope(owner: owner, sessionId: sessionId),
          ),
        );
        expect(
          await controller.generate(
            action: CanvasAiAction.expansion,
            documentMarkdown: '同一恢复草稿',
            documentRevision: 3,
          ),
          isTrue,
        );
        final requestId = controller.request!.requestId;
        container.dispose();
        return requestId;
      }

      final first = await generateFromFreshContainer('restored-session');
      final second = await generateFromFreshContainer('restored-session');
      final legacy = await generateFromFreshContainer('x' * 256);

      expect(second, isNot(first));
      expect(legacy.length, lessThanOrEqualTo(120));
    },
  );

  test(
    'unfinished generation waits without failure and retries the exact frozen request',
    () async {
      final port = _FailOncePort(
        failure: const CanvasAiTransformException(
          'AGENT_RUN_POLL_TIMEOUT',
          recovery: CanvasAiFailureRecovery.retrySameRequest,
          isAwaitingCompletion: true,
          agentRunId: 'pending-run',
        ),
      );
      final controller = CanvasAiController(port);
      addTearDown(controller.dispose);
      expect(
        await controller.generate(
          action: CanvasAiAction.expansion,
          documentMarkdown: '原文不能丢失',
          documentRevision: 9,
        ),
        isFalse,
      );
      expect(controller.status, CanvasAiTransformStatus.awaitingCompletion);
      expect(controller.canRetry, isTrue);
      expect(controller.canRegenerate, isFalse);
      final request = controller.request;
      expect(await controller.retry(), isTrue);
      expect(controller.request, same(request));
      expect(controller.status, CanvasAiTransformStatus.previewing);
      expect(
        controller.beginApply(currentMarkdown: '另外的正文', currentRevision: 10),
        isNull,
      );
    },
  );

  test(
    'closing an awaiting proposal cancels the pending remote operation',
    () async {
      final port = _QueuedPort();
      final controller = CanvasAiController(port);
      addTearDown(controller.dispose);
      final future = controller.generate(
        action: CanvasAiAction.expansion,
        documentMarkdown: '等待中的正文',
        documentRevision: 1,
      );
      port.pending.single.completeError(
        const CanvasAiTransformException(
          'AGENT_RUN_POLL_TIMEOUT',
          recovery: CanvasAiFailureRecovery.retrySameRequest,
          isAwaitingCompletion: true,
        ),
      );
      await future;
      expect(controller.status, CanvasAiTransformStatus.awaitingCompletion);
      controller.cancel();
      await Future<void>.delayed(Duration.zero);
      expect(port.cancelledRequestIds, [port.requests.single.requestId]);
      expect(controller.canRetry, isFalse);
      expect(controller.status, CanvasAiTransformStatus.cancelled);
    },
  );

  test(
    'wrong hunk origin is rejected and logs the exact validation failure without content',
    () async {
      const source = '### DS 截图/屏幕图像读取\n\n保留第一节\n\n## SDS3054 示波器测量项\n\n原有说明\n';
      const diff =
          '--- a/canvas.md\n+++ b/canvas.md\n@@ -1,3 +1,4 @@\n'
          ' ## SDS3054 示波器测量项\n \n 原有说明\n+扩写说明\n';
      final database = AppDatabase();
      final logger = DiagnosticLogger(dao: DiagnosticLogDao(database));
      addTearDown(logger.dispose);
      final controller = CanvasAiController(
        const _DiffPort(diff),
        diagnosticLogger: logger,
      );
      addTearDown(controller.dispose);
      expect(
        await controller.generate(
          action: CanvasAiAction.expansion,
          documentMarkdown: source,
          documentRevision: 1,
        ),
        isFalse,
      );
      expect(controller.errorCode, 'CANVAS_AI_DIFF_INVALID');
      expect(controller.result, isNull);
      logger.flush();
      final records = DiagnosticLogDao(database).query();
      expect(
        records.any(
          (record) =>
              record.redactedMetadata['error_code'] == 'CANVAS_AI_DIFF_INVALID',
        ),
        isTrue,
      );
      expect(
        records.map((record) => record.redactedMetadata).toString(),
        isNot(contains('SDS3054')),
      );
    },
  );

  test(
    'chat diff uses transmitted snapshot while preserving document boundaries',
    () async {
      final controller = CanvasAiController(
        const UnavailableCanvasAiTransformPort(),
      );
      addTearDown(controller.dispose);
      const source = '\n原来正文\n';
      final accepted = await controller.generateChatRewrite(
        instruction: '应用聊天差分',
        documentMarkdown: source,
        documentRevision: 2,
        unifiedDiff: canvasBuildWholePayloadUnifiedDiff(
          baseMarkdown: source.trim(),
          replacementMarkdown: '建议正文',
        ),
      );
      expect(accepted, isTrue);
      expect(
        controller
            .beginApply(currentMarkdown: source, currentRevision: 2)
            ?.replacementMarkdown,
        '\n建议正文\n',
      );
    },
  );

  test('returned chat diff is validated locally before accepting', () async {
    final controller = CanvasAiController(
      const UnavailableCanvasAiTransformPort(),
    );
    addTearDown(controller.dispose);
    final succeeded = await controller.generateChatRewrite(
      instruction: '确认差分',
      documentMarkdown: '保留原文',
      documentRevision: 4,
      unifiedDiff: canvasBuildWholePayloadUnifiedDiff(
        baseMarkdown: '保留原文',
        replacementMarkdown: '修改后的正文',
      ),
    );
    expect(succeeded, isTrue);
    expect(controller.status, CanvasAiTransformStatus.previewing);
    expect(
      controller.beginApply(currentMarkdown: '其他修改', currentRevision: 5),
      isNull,
    );
  });

  test('returned chat diff with wrong source cannot replace content', () async {
    final controller = CanvasAiController(
      const UnavailableCanvasAiTransformPort(),
    );
    addTearDown(controller.dispose);
    expect(
      await controller.generateChatRewrite(
        instruction: '确认差分',
        documentMarkdown: '实际正文',
        documentRevision: 4,
        unifiedDiff: canvasBuildWholePayloadUnifiedDiff(
          baseMarkdown: '错误基线',
          replacementMarkdown: '建议',
        ),
      ),
      isFalse,
    );
    expect(controller.errorCode, 'CANVAS_AI_DIFF_INVALID');
  });

  test(
    'selection is frozen, previewed, and applied as one transaction',
    () async {
      final controller = CanvasAiController(
        const CanvasAiTransformMockPort(delay: Duration.zero),
      );
      addTearDown(controller.dispose);
      final statuses = <CanvasAiTransformStatus>[];
      controller.addListener(() => statuses.add(controller.status));
      const document = '开头\n\n需要扩写的观点\n\n结尾';
      final start = document.indexOf('需要');
      final end = start + '需要扩写的观点'.length;

      expect(
        await controller.generate(
          action: CanvasAiAction.expansion,
          documentMarkdown: document,
          documentRevision: 7,
          editScope: CanvasAiEditScope.local,
          selectionStart: end,
          selectionEnd: start,
        ),
        isTrue,
      );

      expect(controller.status, CanvasAiTransformStatus.previewing);
      expect(controller.request!.scope, CanvasTransformScope.selection);
      expect(controller.request!.editScope, CanvasAiEditScope.local);
      expect(
        controller.request!.targetRange,
        CanvasTextRange(start: start, end: end),
      );
      expect(controller.request!.targetMarkdown, '需要扩写的观点');
      expect(controller.request!.documentRevision, 7);
      expect(controller.request!.documentHash, canvasTextHash(document));
      expect(controller.request!.targetHash, canvasTextHash('需要扩写的观点'));
      expect(
        controller.isPreviewCurrent(
          currentMarkdown: document,
          currentRevision: 7,
        ),
        isTrue,
      );

      final application = controller.beginApply(
        currentMarkdown: document,
        currentRevision: 7,
      );
      expect(application, isNotNull);
      expect(controller.status, CanvasAiTransformStatus.applying);
      expect(application!.updatedMarkdown, startsWith('开头\n\n需要扩写的观点'));
      expect(application.updatedMarkdown, endsWith('\n\n结尾'));
      expect(application.updatedMarkdown, contains('进一步说明'));

      controller.completeApply();
      expect(controller.status, CanvasAiTransformStatus.idle);
      expect(
        statuses,
        containsAllInOrder(<CanvasAiTransformStatus>[
          CanvasAiTransformStatus.running,
          CanvasAiTransformStatus.previewing,
          CanvasAiTransformStatus.applying,
          CanvasAiTransformStatus.idle,
        ]),
      );
    },
  );

  test('global scope targets the complete Markdown for every action', () async {
    final controller = CanvasAiController(
      const CanvasAiTransformMockPort(delay: Duration.zero),
    );
    addTearDown(controller.dispose);
    const document = '\n\n第一段\n仍是第一段\n\n第二段';

    expect(
      await controller.generate(
        action: CanvasAiAction.needsDeepening,
        documentMarkdown: document,
        documentRevision: 1,
      ),
      isTrue,
    );
    expect(controller.request!.scope, CanvasTransformScope.document);
    expect(controller.request!.editScope, CanvasAiEditScope.global);
    expect(
      controller.request!.targetRange,
      const CanvasTextRange(start: 0, end: document.length),
    );

    controller.reset();
    expect(
      await controller.generate(
        action: CanvasAiAction.openingOptimization,
        openingVariant: CanvasOpeningVariant.defamiliarization,
        documentMarkdown: document,
        documentRevision: 1,
      ),
      isTrue,
    );
    expect(controller.request!.scope, CanvasTransformScope.document);
    expect(controller.request!.editScope, CanvasAiEditScope.global);
    expect(controller.request!.targetMarkdown, document);
    expect(controller.result!.replacementMarkdown, contains('观察角度'));
  });

  test('local scope requires and freezes an exact selection', () async {
    final controller = CanvasAiController(
      const CanvasAiTransformMockPort(delay: Duration.zero),
    );
    addTearDown(controller.dispose);
    const document = '完整正文\n\n只改这一句\n\n保留这一句';
    final start = document.indexOf('只改');
    final end = start + '只改这一句'.length;

    expect(
      await controller.generate(
        action: CanvasAiAction.openingOptimization,
        openingVariant: CanvasOpeningVariant.labeling,
        documentMarkdown: document,
        documentRevision: 3,
        editScope: CanvasAiEditScope.local,
        selectionStart: start,
        selectionEnd: end,
      ),
      isTrue,
    );

    expect(controller.request!.scope, CanvasTransformScope.selection);
    expect(controller.request!.editScope, CanvasAiEditScope.local);
    expect(
      controller.request!.targetRange,
      CanvasTextRange(start: start, end: end),
    );
    expect(controller.request!.targetMarkdown, '只改这一句');

    controller.reset();
    expect(
      await controller.generate(
        action: CanvasAiAction.expansion,
        documentMarkdown: document,
        documentRevision: 3,
        editScope: CanvasAiEditScope.local,
      ),
      isFalse,
    );
    expect(controller.errorCode, 'CANVAS_AI_SELECTION_REQUIRED');
  });

  test(
    'a unified diff is verified and applied to the frozen Markdown',
    () async {
      const document = '标题\n原句\n结尾\n';
      const diff =
          '--- a/draft.md\n'
          '+++ b/draft.md\n'
          '@@ -1,3 +1,4 @@\n'
          ' 标题\n'
          '-原句\n'
          '+新句\n'
          '+补充\n'
          ' 结尾\n';
      final controller = CanvasAiController(const _DiffPort(diff));
      addTearDown(controller.dispose);

      expect(
        await controller.generate(
          action: CanvasAiAction.expansion,
          documentMarkdown: document,
          documentRevision: 4,
        ),
        isTrue,
      );
      expect(controller.result!.unifiedDiff, diff);
      expect(controller.result!.replacementMarkdown, '标题\n新句\n补充\n结尾\n');

      final application = controller.beginApply(
        currentMarkdown: document,
        currentRevision: 4,
      );
      expect(application?.updatedMarkdown, '标题\n新句\n补充\n结尾\n');
    },
  );

  test('a replacement-only result cannot become previewable', () async {
    final controller = CanvasAiController(const _ReplacementOnlyPort());
    addTearDown(controller.dispose);

    expect(
      await controller.generate(
        action: CanvasAiAction.expansion,
        documentMarkdown: '冻结原文',
        documentRevision: 4,
      ),
      isFalse,
    );
    expect(controller.status, CanvasAiTransformStatus.failed);
    expect(controller.errorCode, 'CANVAS_AI_DIFF_REQUIRED');
    expect(controller.result, isNull);
  });

  for (final invalidCandidate
      in <({String label, String replacement, String errorCode})>[
        (
          label: 'empty candidate',
          replacement: '',
          errorCode: 'CANVAS_AI_EMPTY_RESULT',
        ),
        (
          label: 'whitespace-only candidate',
          replacement: ' \t',
          errorCode: 'CANVAS_AI_EMPTY_RESULT',
        ),
        (
          label: 'unchanged candidate',
          replacement: '冻结原文',
          errorCode: 'CANVAS_AI_NO_CHANGES',
        ),
        (
          label: 'slash newline candidate',
          replacement: '冻结原文/n/n新增段落',
          errorCode: 'CANVAS_AI_INVALID_LINE_BREAKS',
        ),
        (
          label: 'double escaped newline candidate',
          replacement: r'冻结原文\n\n新增段落',
          errorCode: 'CANVAS_AI_INVALID_LINE_BREAKS',
        ),
        (
          label: 'escaped CRLF candidate',
          replacement: r'冻结原文\r\n新增段落',
          errorCode: 'CANVAS_AI_INVALID_LINE_BREAKS',
        ),
      ]) {
    test('remote diff rejects ${invalidCandidate.label}', () async {
      const source = '冻结原文';
      final controller = CanvasAiController(
        _DiffPort(
          canvasBuildWholePayloadUnifiedDiff(
            baseMarkdown: source,
            replacementMarkdown: invalidCandidate.replacement,
          ),
        ),
      );
      addTearDown(controller.dispose);

      expect(
        await controller.generate(
          action: CanvasAiAction.expansion,
          documentMarkdown: source,
          documentRevision: 4,
        ),
        isFalse,
      );
      expect(controller.status, CanvasAiTransformStatus.failed);
      expect(controller.errorCode, invalidCandidate.errorCode);
      expect(controller.result, isNull);
      expect(
        controller.beginApply(currentMarkdown: source, currentRevision: 4),
        isNull,
      );
    });

    test('supplied chat diff rejects ${invalidCandidate.label}', () async {
      const source = '冻结原文';
      final controller = CanvasAiController(
        const UnavailableCanvasAiTransformPort(),
      );
      addTearDown(controller.dispose);

      expect(
        await controller.generateChatRewrite(
          instruction: '应用聊天差分',
          documentMarkdown: source,
          documentRevision: 4,
          unifiedDiff: canvasBuildWholePayloadUnifiedDiff(
            baseMarkdown: source,
            replacementMarkdown: invalidCandidate.replacement,
          ),
        ),
        isFalse,
      );
      expect(controller.status, CanvasAiTransformStatus.failed);
      expect(controller.errorCode, invalidCandidate.errorCode);
      expect(controller.result, isNull);
      expect(
        controller.beginApply(currentMarkdown: source, currentRevision: 4),
        isNull,
      );
    });
  }

  test('remote diff rejects a line-ending-only candidate', () async {
    const source = '第一行\r\n第二行';
    final controller = CanvasAiController(
      _DiffPort(
        canvasBuildWholePayloadUnifiedDiff(
          baseMarkdown: source,
          replacementMarkdown: '第一行\n第二行',
        ),
      ),
    );
    addTearDown(controller.dispose);

    expect(
      await controller.generate(
        action: CanvasAiAction.expansion,
        documentMarkdown: source,
        documentRevision: 5,
      ),
      isFalse,
    );
    expect(controller.errorCode, 'CANVAS_AI_NO_CHANGES');
    expect(controller.result, isNull);
    expect(
      controller.beginApply(currentMarkdown: source, currentRevision: 5),
      isNull,
    );
  });

  test(
    'image brief rejects destructive and empty-suffix diff candidates',
    () async {
      const document = '  冻结原文  \n';
      for (final candidate in <String>[
        '> **配图建议**\n\n- 原文已被替换。',
        '$document \n\t',
      ]) {
        final diff = canvasBuildWholePayloadUnifiedDiff(
          baseMarkdown: document,
          replacementMarkdown: candidate,
        );
        final controller = CanvasAiController(_DiffPort(diff));
        addTearDown(controller.dispose);

        expect(
          await controller.generate(
            action: CanvasAiAction.imageBrief,
            documentMarkdown: document,
            documentRevision: 4,
            imageVariant: CanvasImageVariant.sceneDesign,
          ),
          isFalse,
        );
        expect(controller.status, CanvasAiTransformStatus.failed);
        expect(controller.errorCode, 'CANVAS_AI_IMAGE_BRIEF_INVALID');
        expect(controller.result, isNull);
      }
    },
  );

  test('a mismatched unified diff never becomes previewable', () async {
    const document = '标题\n原句\n结尾\n';
    const diff =
        '--- a/draft.md\n'
        '+++ b/draft.md\n'
        '@@ -1,3 +1,3 @@\n'
        ' 标题\n'
        '-不存在的原句\n'
        '+新句\n'
        ' 结尾\n';
    final controller = CanvasAiController(const _DiffPort(diff));
    addTearDown(controller.dispose);

    expect(
      await controller.generate(
        action: CanvasAiAction.expansion,
        documentMarkdown: document,
        documentRevision: 4,
      ),
      isFalse,
    );
    expect(controller.status, CanvasAiTransformStatus.failed);
    expect(controller.errorCode, 'CANVAS_AI_DIFF_INVALID');
    expect(controller.result, isNull);
  });

  test(
    'a zero-context unified diff inserts at the declared end position',
    () async {
      const document = 'one\n';
      const diff =
          '--- a/draft.md\n'
          '+++ b/draft.md\n'
          '@@ -1,0 +2 @@\n'
          '+two\n';
      final controller = CanvasAiController(const _DiffPort(diff));
      addTearDown(controller.dispose);

      expect(
        await controller.generate(
          action: CanvasAiAction.expansion,
          documentMarkdown: document,
          documentRevision: 4,
        ),
        isTrue,
      );
      expect(controller.result!.replacementMarkdown, 'one\ntwo\n');
    },
  );

  test('canonical patches handle Chinese, emoji, CRLF, and separate hunks', () {
    const base =
        '# 创作草稿\r\n'
        '第一段：把问题讲清楚。\r\n'
        '第二段：保留上下文。\r\n'
        '结尾🙂\r\n';
    const diff =
        '--- a/canvas.md\n'
        '+++ b/canvas.md\n'
        '@@ -2 +2 @@\n'
        '-第一段：把问题讲清楚。\n'
        '+第一段：先写清楚真实场景。\n'
        '@@ -4 +4 @@\n'
        '-结尾🙂\n'
        '+新增行动：今天先采访一位用户。\n';

    expect(
      canvasApplyUnifiedDiff(baseMarkdown: base, unifiedDiff: diff),
      '# 创作草稿\n第一段：先写清楚真实场景。\n第二段：保留上下文。\n新增行动：今天先采访一位用户。\n',
    );
  });

  test(
    'patches preserve insertion, deletion, and terminal newline semantics',
    () {
      const deleteFinalLine =
          '--- a/canvas.md\n'
          '+++ b/canvas.md\n'
          '@@ -2 +1,0 @@\n'
          '-二\n'
          r'\ No newline at end of file';
      const insertIntoEmpty =
          '--- a/canvas.md\n'
          '+++ b/canvas.md\n'
          '@@ -0,0 +1 @@\n'
          '+首行\n';

      expect(
        canvasApplyUnifiedDiff(
          baseMarkdown: '一\n二',
          unifiedDiff: deleteFinalLine,
        ),
        '一\n',
      );
      expect(
        canvasApplyUnifiedDiff(baseMarkdown: '', unifiedDiff: insertIntoEmpty),
        '首行\n',
      );
    },
  );

  test(
    'terminal newline markers cannot create an intermediate unterminated line',
    () {
      const unterminatedMiddleLine =
          '--- a/canvas.md\n'
          '+++ b/canvas.md\n'
          '@@ -1 +1,3 @@\n'
          ' a\n'
          '+x\n'
          r'\ No newline at end of file'
          '\n'
          '+y\n';
      const appendAfterUnterminatedBase =
          '--- a/canvas.md\n'
          '+++ b/canvas.md\n'
          '@@ -1,0 +2 @@\n'
          '+b\n';
      const missingBaselineMarker =
          '--- a/canvas.md\n'
          '+++ b/canvas.md\n'
          '@@ -1 +1 @@\n'
          '-a\n'
          '+b\n';
      const replaceUnterminatedLine =
          '--- a/canvas.md\n'
          '+++ b/canvas.md\n'
          '@@ -1 +1 @@\n'
          '-a\n'
          r'\ No newline at end of file'
          '\n'
          '+b\n'
          r'\ No newline at end of file';

      expect(
        () => canvasApplyUnifiedDiff(
          baseMarkdown: 'a\n',
          unifiedDiff: unterminatedMiddleLine,
        ),
        throwsA(isA<CanvasUnifiedDiffException>()),
      );
      expect(
        () => canvasApplyUnifiedDiff(
          baseMarkdown: 'a',
          unifiedDiff: appendAfterUnterminatedBase,
        ),
        throwsA(isA<CanvasUnifiedDiffException>()),
      );
      expect(
        () => canvasApplyUnifiedDiff(
          baseMarkdown: 'a',
          unifiedDiff: missingBaselineMarker,
        ),
        throwsA(isA<CanvasUnifiedDiffException>()),
      );
      expect(
        canvasApplyUnifiedDiff(
          baseMarkdown: 'a',
          unifiedDiff: replaceUnterminatedLine,
        ),
        'b',
      );
    },
  );

  test('malformed or overlapping patch hunks never partially apply', () {
    const invalidPosition =
        '--- a/canvas.md\n'
        '+++ b/canvas.md\n'
        '@@ -1 +4 @@\n'
        '-第一行\n'
        '+替换行\n';
    const overlapping =
        '--- a/canvas.md\n'
        '+++ b/canvas.md\n'
        '@@ -1 +1 @@\n'
        '-第一行\n'
        '+替换行\n'
        '@@ -1 +1 @@\n'
        '-第一行\n'
        '+再次替换\n';

    expect(
      () => canvasApplyUnifiedDiff(
        baseMarkdown: '第一行\n第二行\n',
        unifiedDiff: invalidPosition,
      ),
      throwsA(isA<CanvasUnifiedDiffException>()),
    );
    expect(
      () => canvasApplyUnifiedDiff(
        baseMarkdown: '第一行\n第二行\n',
        unifiedDiff: overlapping,
      ),
      throwsA(isA<CanvasUnifiedDiffException>()),
    );
  });

  test(
    'action-specific choices are validated before calling the port',
    () async {
      final port = _CountingPort();
      final controller = CanvasAiController(port);
      addTearDown(controller.dispose);

      expect(
        await controller.generate(
          action: CanvasAiAction.openingOptimization,
          documentMarkdown: '正文',
          documentRevision: 0,
        ),
        isFalse,
      );
      expect(controller.errorCode, 'CANVAS_AI_OPENING_VARIANT_REQUIRED');

      expect(
        await controller.generate(
          action: CanvasAiAction.socialRelationShift,
          documentMarkdown: '正文',
          documentRevision: 0,
        ),
        isFalse,
      );
      expect(controller.errorCode, 'CANVAS_AI_RELATION_TARGET_REQUIRED');

      expect(
        await controller.generate(
          action: CanvasAiAction.personaInsertion,
          documentMarkdown: '正文',
          documentRevision: 0,
          personaContext: '  ',
        ),
        isFalse,
      );
      expect(controller.errorCode, 'CANVAS_AI_PERSONA_REQUIRED');
      expect(port.calls, 0);
    },
  );

  test('changed revision or document rejects a stale preview', () async {
    final controller = CanvasAiController(
      const CanvasAiTransformMockPort(delay: Duration.zero),
    );
    addTearDown(controller.dispose);

    await controller.generate(
      action: CanvasAiAction.differentiationStrengthening,
      documentMarkdown: '原始正文',
      documentRevision: 2,
    );

    expect(
      controller.isPreviewCurrent(
        currentMarkdown: '原始正文已修改',
        currentRevision: 3,
      ),
      isFalse,
    );
    expect(
      controller.beginApply(currentMarkdown: '原始正文已修改', currentRevision: 3),
      isNull,
    );
    expect(controller.status, CanvasAiTransformStatus.failed);
    expect(controller.errorCode, 'CANVAS_AI_SOURCE_CHANGED');
    expect(controller.canRetry, isFalse);
    expect(controller.canRegenerate, isFalse);
  });

  test('a valid preview regenerates with a fresh request ID', () async {
    final port = _CountingPort();
    final controller = CanvasAiController(port);
    addTearDown(controller.dispose);

    expect(
      await controller.generate(
        action: CanvasAiAction.expansion,
        documentMarkdown: '需要扩写的正文',
        documentRevision: 1,
      ),
      isTrue,
    );
    final firstRequestId = controller.request!.requestId;
    expect(controller.canRetry, isFalse);
    expect(controller.canRegenerate, isTrue);

    expect(await controller.regenerate(), isTrue);
    expect(controller.request!.requestId, isNot(firstRequestId));
    expect(controller.request!.targetMarkdown, '需要扩写的正文');
    expect(port.calls, 2);
  });

  test('recreated controllers allocate disjoint AgentRun IDs', () async {
    final first = CanvasAiController(_CountingPort());
    final second = CanvasAiController(_CountingPort());
    addTearDown(first.dispose);
    addTearDown(second.dispose);

    expect(
      await first.generate(
        action: CanvasAiAction.expansion,
        documentMarkdown: '第一份正文',
        documentRevision: 1,
      ),
      isTrue,
    );
    expect(
      await second.generate(
        action: CanvasAiAction.expansion,
        documentMarkdown: '第二份正文',
        documentRevision: 1,
      ),
      isTrue,
    );

    expect(first.request!.requestId, isNot(second.request!.requestId));
  });

  test(
    'a newer generation wins and the older late result is ignored',
    () async {
      final port = _QueuedPort();
      final controller = CanvasAiController(port);
      addTearDown(controller.dispose);

      final older = controller.generate(
        action: CanvasAiAction.expansion,
        documentMarkdown: '第一份正文',
        documentRevision: 1,
      );
      final newer = controller.generate(
        action: CanvasAiAction.atomization,
        documentMarkdown: '第二份正文。第二个观点。',
        documentRevision: 2,
      );
      while (port.pending.length < 2) {
        await Future<void>.delayed(Duration.zero);
      }

      port.complete(1, '新的结果');
      expect(await newer, isTrue);
      final winningRequestId = controller.request!.requestId;
      port.complete(0, '过期结果');
      expect(await older, isFalse);

      expect(controller.status, CanvasAiTransformStatus.previewing);
      expect(controller.request!.requestId, winningRequestId);
      expect(controller.result!.replacementMarkdown, '新的结果');
    },
  );

  test('cancel invalidates a running result and remains cancelled', () async {
    final port = _QueuedPort();
    final controller = CanvasAiController(port);
    addTearDown(controller.dispose);

    final pending = controller.generate(
      action: CanvasAiAction.expansion,
      documentMarkdown: '等待扩写',
      documentRevision: 1,
    );
    expect(controller.status, CanvasAiTransformStatus.running);

    controller.cancel();
    expect(controller.status, CanvasAiTransformStatus.cancelled);
    expect(port.cancelledRequestIds, <String>[port.requests.single.requestId]);
    port.complete(0, '不应显示的结果');

    expect(await pending, isFalse);
    expect(controller.status, CanvasAiTransformStatus.cancelled);
    expect(controller.result, isNull);
  });

  test('failure retains the frozen request for an exact retry', () async {
    final port = _FailOncePort();
    final controller = CanvasAiController(port);
    addTearDown(controller.dispose);

    expect(
      await controller.generate(
        action: CanvasAiAction.imageBrief,
        documentMarkdown: '需要一张真实场景配图',
        documentRevision: 9,
        imageVariant: CanvasImageVariant.sceneDesign,
      ),
      isFalse,
    );
    final failedRequest = controller.request!;
    expect(controller.status, CanvasAiTransformStatus.failed);
    expect(controller.errorCode, 'CANVAS_AI_TEMPORARY_FAILURE');
    expect(controller.canRetry, isTrue);

    expect(await controller.retry(), isTrue);
    expect(controller.status, CanvasAiTransformStatus.previewing);
    expect(controller.request!.requestId, failedRequest.requestId);
    expect(
      controller.request!.documentRevision,
      failedRequest.documentRevision,
    );
    expect(controller.request!.documentHash, failedRequest.documentHash);
    expect(controller.request!.targetRange, failedRequest.targetRange);
    expect(controller.request!.targetHash, failedRequest.targetHash);
  });

  test('fresh generation waits for unresolved remote cancellation', () async {
    final port = _RecoverableCancellationPort();
    final controller = CanvasAiController(
      port,
      requestNamespace: 'cancellation-test',
    );
    addTearDown(controller.dispose);

    expect(
      await controller.generate(
        action: CanvasAiAction.expansion,
        documentMarkdown: '旧正文',
        documentRevision: 1,
      ),
      isFalse,
    );
    final failedRequestId = controller.request!.requestId;
    controller.reset();

    expect(
      await controller.generate(
        action: CanvasAiAction.expansion,
        documentMarkdown: '新正文',
        documentRevision: 2,
      ),
      isFalse,
    );
    expect(controller.errorCode, 'CANVAS_AI_CANCELLATION_UNRESOLVED');
    expect(port.transformCalls, 1);

    port.cancellationCanSettle = true;
    expect(
      await controller.generate(
        action: CanvasAiAction.expansion,
        documentMarkdown: '新正文',
        documentRevision: 2,
      ),
      isTrue,
    );
    expect(port.cancelledRequestIds, everyElement(failedRequestId));
    expect(port.transformCalls, 2);
  });

  test(
    'terminal failure regeneration creates a fresh AgentRun operation ID',
    () async {
      final port = _FailOncePort(
        failure: const CanvasAiTransformException('AGENT_RUN_FAILED'),
      );
      final controller = CanvasAiController(port);
      addTearDown(controller.dispose);

      expect(
        await controller.generate(
          action: CanvasAiAction.imageBrief,
          documentMarkdown: '需要一张真实场景配图',
          documentRevision: 9,
          imageVariant: CanvasImageVariant.sceneDesign,
        ),
        isFalse,
      );
      final failedRequest = controller.request!;
      expect(controller.canRetry, isFalse);
      expect(controller.canRegenerate, isTrue);

      expect(await controller.regenerate(), isTrue);
      expect(controller.request!.requestId, isNot(failedRequest.requestId));
      expect(controller.request!.documentHash, failedRequest.documentHash);
      expect(controller.request!.targetRange, failedRequest.targetRange);
      expect(port.calls, 2);
    },
  );
}

CanvasAiResult _resultFor(CanvasAiRequest request, String replacement) =>
    CanvasAiResult(
      requestId: request.requestId,
      command: request.command,
      unifiedDiff: canvasBuildWholePayloadUnifiedDiff(
        baseMarkdown: request.targetMarkdown,
        replacementMarkdown: replacement,
      ),
      sourceDocumentHash: request.documentHash,
      sourceTargetHash: request.targetHash,
      generatedAt: DateTime(2026, 7, 20),
    );

final class _ReplacementOnlyPort implements CanvasAiTransformPort {
  const _ReplacementOnlyPort();

  @override
  Future<CanvasAiResult> transform(CanvasAiRequest request) async =>
      CanvasAiResult(
        requestId: request.requestId,
        command: request.command,
        replacementMarkdown: '未经差分验证的正文',
        sourceDocumentHash: request.documentHash,
        sourceTargetHash: request.targetHash,
        generatedAt: DateTime(2026, 9, 10),
      );
}

final class _CountingPort implements CanvasAiTransformPort {
  int calls = 0;

  @override
  Future<CanvasAiResult> transform(CanvasAiRequest request) async {
    calls++;
    return _resultFor(request, '${request.targetMarkdown}\n有效扩写');
  }
}

final class _QueuedPort
    implements CanvasAiTransformPort, CanvasAiTransformCancellationPort {
  final List<CanvasAiRequest> requests = <CanvasAiRequest>[];
  final List<Completer<CanvasAiResult>> pending = <Completer<CanvasAiResult>>[];
  final List<String> cancelledRequestIds = <String>[];

  @override
  Future<CanvasAiResult> transform(CanvasAiRequest request) {
    requests.add(request);
    final completer = Completer<CanvasAiResult>();
    pending.add(completer);
    return completer.future;
  }

  @override
  Future<bool> cancelTransform(String requestId) async {
    cancelledRequestIds.add(requestId);
    return true;
  }

  void complete(int index, String replacement) {
    pending[index].complete(_resultFor(requests[index], replacement));
  }
}

final class _RecoverableCancellationPort
    implements CanvasAiTransformPort, CanvasAiTransformCancellationPort {
  final List<String> cancelledRequestIds = <String>[];
  bool cancellationCanSettle = false;
  int transformCalls = 0;

  @override
  Future<CanvasAiResult> transform(CanvasAiRequest request) async {
    transformCalls += 1;
    if (transformCalls == 1) {
      throw const CanvasAiTransformException(
        'AGENT_RUN_POLL_TIMEOUT',
        recovery: CanvasAiFailureRecovery.retrySameRequest,
      );
    }
    return _resultFor(request, '新结果');
  }

  @override
  Future<bool> cancelTransform(String requestId) async {
    cancelledRequestIds.add(requestId);
    return cancellationCanSettle;
  }
}

final class _FailOncePort implements CanvasAiTransformPort {
  _FailOncePort({
    this.failure = const CanvasAiTransformException(
      'CANVAS_AI_TEMPORARY_FAILURE',
      recovery: CanvasAiFailureRecovery.retrySameRequest,
    ),
  });

  final CanvasAiTransformException failure;
  var calls = 0;

  @override
  Future<CanvasAiResult> transform(CanvasAiRequest request) async {
    calls++;
    if (calls == 1) {
      throw failure;
    }
    final replacement = request.action == CanvasAiAction.imageBrief
        ? '${request.targetMarkdown}\n\n> **配图建议**\n\n- 构图：真实场景'
        : '> **配图建议**\n\n- 构图：真实场景';
    return _resultFor(request, replacement);
  }
}

final class _DiffPort implements CanvasAiTransformPort {
  const _DiffPort(this.diff);

  final String diff;

  @override
  Future<CanvasAiResult> transform(CanvasAiRequest request) async =>
      CanvasAiResult(
        requestId: request.requestId,
        command: request.command,
        sourceDocumentHash: request.documentHash,
        sourceTargetHash: request.targetHash,
        generatedAt: DateTime(2026, 8, 9),
        unifiedDiff: diff,
      );
}
