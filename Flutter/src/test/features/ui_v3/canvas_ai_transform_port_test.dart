import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/database/diagnostic_log_dao.dart';
import 'package:huahuoai_app/core/diagnostics/diagnostic_logger.dart';
import 'package:huahuo_api/huahuo_api.dart';
import 'package:huahuoai_app/features/agent/application/mobile_agent_capability_controller.dart';
import 'package:huahuoai_app/features/agent/data/mobile_agent_capability_port.dart';
import 'package:huahuoai_app/features/ui_v3/data/canvas_ai_transform_port.dart';
import 'package:huahuoai_app/features/ui_v3/domain/canvas_ai_models.dart';

import '../../support/mobile_agent_test_support.dart';

void main() {
  for (final malformed in ['第一段/n/n第二段', r'第一段\n\n第二段']) {
    test('structured edit rejects malformed paragraphs $malformed', () async {
      final request = _request(action: CanvasAiAction.expansion);
      final agent = MobileAgentCapabilityController(
        port: MobileAgentReadyTestPort(
          finalAnswer: jsonEncode({
            'schema': 'canvas_edit.v1',
            'requestId': request.requestId,
            'baseHash': request.targetHash,
            'replacementMarkdown': malformed,
          }),
        ),
        identity: const MobileAgentRuntimeIdentity(
          userId: 'test-user',
          workspaceId: 'test-workspace',
          locale: 'zh-CN',
          timezone: 'Asia/Shanghai',
        ),
        delay: (_) async {},
      );
      addTearDown(agent.dispose);
      await expectLater(
        MobileAgentCanvasAiTransformPort(agent).transform(request),
        throwsA(
          isA<CanvasAiTransformException>().having(
            (error) => error.code,
            'code',
            'CANVAS_AI_INVALID_LINE_BREAKS',
          ),
        ),
      );
    });
  }

  test(
    'structured edits build exact diffs across multiple headings and preserve whitespace',
    () async {
      const source =
          '### DS 截图/屏幕图像读取\n\n保留此段。\n\n## SDS3054 示波器测量项\n\n原来的说明。\n';
      const replacement =
          '### DS 截图/屏幕图像读取\n\n保留此段。\n\n## SDS3054 示波器测量项\n\n原来的说明。补充使用说明。\n';
      final request = _request(
        action: CanvasAiAction.expansion,
        source: source,
        editScope: CanvasAiEditScope.local,
      );
      final recordingPort = _RecordingMobileAgentPort(
        MobileAgentReadyTestPort(
          finalAnswer: jsonEncode({
            'schema': 'canvas_edit.v1',
            'requestId': request.requestId,
            'baseHash': request.targetHash,
            'replacementMarkdown': replacement,
          }),
        ),
      );
      final logger = DiagnosticLogger(dao: DiagnosticLogDao(AppDatabase()));
      final agent = MobileAgentCapabilityController(
        port: recordingPort,
        identity: const MobileAgentRuntimeIdentity(
          userId: 'test-user',
          workspaceId: 'test-workspace',
          locale: 'zh-CN',
          timezone: 'Asia/Shanghai',
        ),
        delay: (_) async {},
      );
      addTearDown(agent.dispose);
      addTearDown(logger.dispose);
      final result = await MobileAgentCanvasAiTransformPort(
        agent,
        diagnosticLogger: logger,
      ).transform(request);
      expect(
        canvasApplyUnifiedDiff(
          baseMarkdown: source,
          unifiedDiff: result.unifiedDiff!,
        ),
        replacement,
      );
      final baseline =
          jsonDecode(_textParts(recordingPort.requests.single)[1]) as Map;
      expect(baseline['schema'], 'canvas_baseline.v1');
      expect(baseline['markdown'], source);
      expect(baseline['baseHash'], request.targetHash);
      expect(baseline['lineCount'], 7);
      expect(
        _visibleText(recordingPort.requests.single).length,
        lessThanOrEqualTo(1000),
      );
    },
  );

  for (final corruptField in ['requestId', 'baseHash', 'schema']) {
    test('structured edit rejects a mismatched $corruptField', () async {
      final request = _request(action: CanvasAiAction.expansion);
      final response = <String, Object>{
        'schema': 'canvas_edit.v1',
        'requestId': request.requestId,
        'baseHash': request.targetHash,
        'replacementMarkdown': '不能应用的改写',
      };
      response[corruptField] = 'wrong';
      final agent = MobileAgentCapabilityController(
        port: MobileAgentReadyTestPort(finalAnswer: jsonEncode(response)),
        identity: const MobileAgentRuntimeIdentity(
          userId: 'test-user',
          workspaceId: 'test-workspace',
          locale: 'zh-CN',
          timezone: 'Asia/Shanghai',
        ),
        delay: (_) async {},
      );
      addTearDown(agent.dispose);
      await expectLater(
        MobileAgentCanvasAiTransformPort(agent).transform(request),
        throwsA(
          isA<CanvasAiTransformException>().having(
            (error) => error.code,
            'code',
            corruptField == 'schema'
                ? 'CANVAS_AI_RESPONSE_INVALID'
                : 'CANVAS_AI_RESULT_MISMATCH',
          ),
        ),
      );
    });
  }

  test(
    'pending Canvas runs expose resumable waiting and persistent safe diagnostics',
    () async {
      final run = AgentRunSnapshot.fromValue({
        'agentRunId': 'pending-canvas-run',
        'workspaceId': 'test-workspace',
        'status': 'running',
        'workspaceVersion': 1,
        'workspaceBindingVersion': 1,
        'contextGeneration': 1,
        'usage': {
          'measurementStatus': 'pending',
          'inputTokens': null,
          'outputTokens': null,
          'imageCount': null,
          'videoSeconds': null,
          'accountedCredits': null,
          'policyVersion': null,
        },
        'createdAt': DateTime.now().toUtc().toIso8601String(),
        'updatedAt': DateTime.now().toUtc().toIso8601String(),
      });
      final agent = _agentForRun(run);
      addTearDown(agent.dispose);
      final database = AppDatabase();
      final dao = DiagnosticLogDao(database);
      final logger = DiagnosticLogger(dao: dao);
      addTearDown(logger.dispose);
      final request = _request(
        action: CanvasAiAction.expansion,
        source: '不能出现在日志中的私密正文',
      );
      await expectLater(
        MobileAgentCanvasAiTransformPort(
          agent,
          pollingPolicy: const MobileAgentRunPollingPolicy(maxAttempts: 2),
          diagnosticLogger: logger,
        ).transform(request),
        throwsA(
          isA<CanvasAiTransformException>()
              .having((error) => error.isAwaitingCompletion, 'waiting', isTrue)
              .having(
                (error) => error.agentRunId,
                'run id',
                'pending-canvas-run',
              ),
        ),
      );
      logger.flush();
      final records = DiagnosticLogDao(database).query();
      final wait = records.firstWhere(
        (record) => record.redactedMetadata['phase'] == 'awaiting_completion',
      );
      expect(wait.redactedMetadata['run_id'], 'pending-canvas-run');
      expect(wait.redactedMetadata['user_scope'], 'test-user');
      expect(wait.redactedMetadata['action'], 'expansion');
      expect(wait.redactedMetadata['target_hash'], request.targetHash);
      expect(wait.redactedMetadata['error_code'], 'AGENT_RUN_POLL_TIMEOUT');
      expect(
        records.map((record) => record.redactedMetadata).toString(),
        isNot(contains(request.targetMarkdown)),
      );
    },
  );

  const port = CanvasAiTransformMockPort(delay: Duration.zero);

  test('all eight actions return applicable unified diffs', () async {
    for (final action in CanvasAiAction.values) {
      final request = _request(action: action);
      final result = await port.transform(request);
      final replacement = _applyResult(request, result);

      expect(result.requestId, request.requestId);
      expect(result.action, action);
      expect(result.sourceDocumentHash, request.documentHash);
      expect(result.sourceTargetHash, request.targetHash);
      expect(result.replacementMarkdown, isEmpty);
      expect(result.unifiedDiff, isNotNull);
      expect(replacement.trim(), isNotEmpty);
      expect(
        replacement,
        contains(switch (action) {
          CanvasAiAction.socialRelationShift => '先交换彼此的判断',
          CanvasAiAction.needsDeepening => '需求深化',
          CanvasAiAction.differentiationStrengthening => '差异化增强',
          CanvasAiAction.openingOptimization => '正在处理',
          CanvasAiAction.expansion => '进一步说明',
          CanvasAiAction.personaInsertion => '表达视角',
          CanvasAiAction.imageBrief => '配图建议',
          CanvasAiAction.atomization => '原子化内容',
        }),
      );

      final repeated = await port.transform(request);
      expect(repeated.unifiedDiff, result.unifiedDiff);
    }
  });

  test('opening variants are distinct and preserve the source', () async {
    final outputs = <CanvasOpeningVariant, String>{};
    for (final variant in CanvasOpeningVariant.values) {
      final request = _request(
        action: CanvasAiAction.openingOptimization,
        openingVariant: variant,
      );
      final result = await port.transform(request);
      final replacement = _applyResult(request, result);
      outputs[variant] = replacement;
      expect(replacement, contains('先说清真正的问题'));
    }

    expect(outputs.length, 2);
    expect(outputs.values.toSet().length, 2);
    expect(outputs[CanvasOpeningVariant.labeling], contains('正在处理'));
    expect(outputs[CanvasOpeningVariant.defamiliarization], contains('观察角度'));
  });

  test(
    'all relationship targets produce a distinct relationship framing',
    () async {
      final outputs = <String>{};
      for (final target in CanvasRelationTarget.values) {
        final request = _request(
          action: CanvasAiAction.socialRelationShift,
          relationTarget: target,
        );
        final result = await port.transform(request);
        final replacement = _applyResult(request, result);
        outputs.add(replacement);
        expect(replacement, contains('先说清真正的问题'));
      }

      expect(outputs.length, CanvasRelationTarget.values.length);
    },
  );

  test(
    'image assistance is an editable brief and does not claim an image',
    () async {
      final request = _request(action: CanvasAiAction.imageBrief);
      final result = await port.transform(request);
      final replacement = _applyResult(request, result);

      expect(result.replacementMarkdown, isEmpty);
      expect(replacement, startsWith(request.targetMarkdown));
      expect(replacement, contains('> **配图建议**'));
      expect(replacement, contains('构图'));
      expect(replacement, contains('主体'));
      expect(replacement, contains('场景'));
      expect(replacement, contains('比例'));
      expect(replacement, contains('提示词'));
      expect(replacement, contains('替代文本'));
      expect(replacement, isNot(contains('图片已生成')));
    },
  );

  test('mock image assistance preserves exact source boundaries', () async {
    const source = '  保留开头空格\n保留结尾空格  \n';
    final request = _request(action: CanvasAiAction.imageBrief, source: source);
    final result = await port.transform(request);
    final replacement = _applyResult(request, result);

    expect(replacement.substring(0, source.length), source);
    expect(replacement.substring(source.length).trim(), isNotEmpty);
  });

  test(
    'expansion stays near one-and-a-half to two times source length',
    () async {
      const source = '真实经历需要写清楚具体环境、判断过程、采取的行动和可以验证的结果。';
      final request = _request(
        action: CanvasAiAction.expansion,
        source: source,
      );
      final result = await port.transform(request);
      final replacement = _applyResult(request, result);
      int compactLength(String value) =>
          value.replaceAll(RegExp(r'\s+'), '').runes.length;
      final ratio = compactLength(replacement) / compactLength(source);
      expect(ratio, greaterThanOrEqualTo(1.5));
      expect(ratio, lessThanOrEqualTo(2));
    },
  );

  test('atomization returns one idea per Markdown list item', () async {
    final request = _request(
      action: CanvasAiAction.atomization,
      source: '先明确问题。再验证原因！最后选择行动。',
    );
    final result = await port.transform(request);
    final replacement = _applyResult(request, result);

    expect(replacement, startsWith('## 原子化内容'));
    expect(RegExp(r'^- ', multiLine: true).allMatches(replacement).length, 3);
  });

  test('injected failure keeps a stable error code', () async {
    const failingPort = CanvasAiTransformMockPort(
      delay: Duration.zero,
      fail: true,
      failureCode: 'CANVAS_AI_TEST_FAILURE',
    );

    await expectLater(
      failingPort.transform(_request(action: CanvasAiAction.expansion)),
      throwsA(
        isA<CanvasAiTransformException>().having(
          (error) => error.code,
          'code',
          'CANVAS_AI_TEST_FAILURE',
        ),
      ),
    );
  });

  test('recognizes raw and fenced unified-diff Agent output', () {
    const diff =
        '--- a/draft.md\n'
        '+++ b/draft.md\n'
        '@@ -1 +1 @@\n'
        '-旧内容\n'
        '+新内容';

    expect(canvasExtractUnifiedDiff(diff), diff);
    expect(canvasExtractUnifiedDiff('```diff\n$diff\n```'), diff);
    expect(
      canvasExtractUnifiedDiff(
        jsonEncode(<String, Object?>{
          'diff': <String, Object?>{'format': 'unified', 'content': diff},
        }),
      ),
      diff,
    );
  });

  test('rejects multiple fenced unified-diff candidates as ambiguous', () {
    const first =
        '--- a/draft.md\n'
        '+++ b/draft.md\n'
        '@@ -1 +1 @@\n'
        '-旧内容\n'
        '+候选一';
    const second =
        '--- a/draft.md\n'
        '+++ b/draft.md\n'
        '@@ -1 +1 @@\n'
        '-旧内容\n'
        '+候选二';

    expect(
      () => canvasExtractUnifiedDiff(
        '```diff\n$first\n```\n\n```patch\n$second\n```',
      ),
      throwsA(isA<CanvasUnifiedDiffException>()),
    );
  });

  test('rejects mixed fenced and bare unified-diff candidates', () {
    const bare =
        '--- a/draft.md\n'
        '+++ b/draft.md\n'
        '@@ -1 +1 @@\n'
        '-旧内容\n'
        '+裸差分';
    const fenced =
        '--- a/draft.md\n'
        '+++ b/draft.md\n'
        '@@ -1 +1 @@\n'
        '-旧内容\n'
        '+围栏差分';

    expect(
      () => canvasExtractUnifiedDiff('$bare\n\n```diff\n$fenced\n```'),
      throwsA(isA<CanvasUnifiedDiffException>()),
    );
  });

  test('rejects conflicting nested and top-level structured diffs', () {
    const first =
        '--- a/draft.md\n'
        '+++ b/draft.md\n'
        '@@ -1 +1 @@\n'
        '-旧内容\n'
        '+候选一';
    const second =
        '--- a/draft.md\n'
        '+++ b/draft.md\n'
        '@@ -1 +1 @@\n'
        '-旧内容\n'
        '+候选二';

    expect(
      () => canvasExtractUnifiedDiff(
        jsonEncode(<String, Object?>{
          'format': 'unified',
          'content': first,
          'diff': <String, Object?>{'format': 'unified', 'content': second},
        }),
      ),
      throwsA(isA<CanvasUnifiedDiffException>()),
    );
  });

  test('four-backtick fence preserves a patch that adds triple backticks', () {
    const source = '说明\n';
    const replacement = '说明\n```dart\nprint("ok");\n```\n';
    final diff = canvasBuildWholePayloadUnifiedDiff(
      baseMarkdown: source,
      replacementMarkdown: replacement,
    );

    final extracted = canvasExtractUnifiedDiff('````diff\n$diff````');

    expect(extracted, isNotNull);
    expect(extracted, contains('+```dart'));
    expect(
      canvasApplyUnifiedDiff(baseMarkdown: source, unifiedDiff: extracted!),
      replacement,
    );
  });

  test('Markdown fence context remains part of raw and fenced patches', () {
    const source = '说明\n```\nold code\n```\n结尾\n';
    const replacement = '说明\n```\nnew code\n```\n结尾\n';
    const diff =
        '--- a/draft.md\n'
        '+++ b/draft.md\n'
        '@@ -1,5 +1,5 @@\n'
        ' 说明\n'
        ' ```\n'
        '-old code\n'
        '+new code\n'
        ' ```\n'
        ' 结尾\n';

    for (final answer in <String>[diff, '```diff\n$diff```']) {
      final extracted = canvasExtractUnifiedDiff(answer);

      expect(extracted, isNotNull);
      expect(extracted, contains(' ```'));
      expect(
        canvasApplyUnifiedDiff(baseMarkdown: source, unifiedDiff: extracted!),
        replacement,
      );
    }
  });

  test('rejects an unclosed diff fence', () {
    const diff =
        '--- a/draft.md\n'
        '+++ b/draft.md\n'
        '@@ -1 +1 @@\n'
        '-旧内容\n'
        '+新内容';

    expect(
      () => canvasExtractUnifiedDiff('```diff\n$diff'),
      throwsA(isA<CanvasUnifiedDiffException>()),
    );
  });

  test(
    'production port rejects a bare terminal answer without a diff',
    () async {
      final agent = MobileAgentCapabilityController(
        port: const MobileAgentReadyTestPort(),
        identity: const MobileAgentRuntimeIdentity(
          userId: 'test-user',
          workspaceId: 'test-workspace',
          locale: 'zh-CN',
          timezone: 'Asia/Shanghai',
        ),
        pollInterval: Duration.zero,
        retryInterval: Duration.zero,
        delay: (_) async {},
      );
      addTearDown(agent.dispose);

      await expectLater(
        MobileAgentCanvasAiTransformPort(agent).transform(
          _request(
            action: CanvasAiAction.expansion,
            editScope: CanvasAiEditScope.local,
          ),
        ),
        throwsA(
          isA<CanvasAiTransformException>().having(
            (error) => error.code,
            'code',
            'CANVAS_AI_DIFF_REQUIRED',
          ),
        ),
      );
    },
  );

  test(
    'production payload preserves relationship options and isolates persona',
    () async {
      const diff =
          '--- a/draft.md\n'
          '+++ b/draft.md\n'
          '@@ -1 +1 @@\n'
          '-先说清真正的问题，再决定下一步行动。\n'
          '+换一种表达。';
      final recordingPort = _RecordingMobileAgentPort(
        const MobileAgentReadyTestPort(finalAnswer: diff),
      );
      final agent = MobileAgentCapabilityController(
        port: recordingPort,
        identity: const MobileAgentRuntimeIdentity(
          userId: 'test-user',
          workspaceId: 'test-workspace',
          locale: 'zh-CN',
          timezone: 'Asia/Shanghai',
        ),
        pollInterval: Duration.zero,
        retryInterval: Duration.zero,
        delay: (_) async {},
      );
      addTearDown(agent.dispose);
      final transformPort = MobileAgentCanvasAiTransformPort(agent);

      for (final target in CanvasRelationTarget.values) {
        await transformPort.transform(
          _request(
            action: CanvasAiAction.socialRelationShift,
            relationTarget: target,
          ),
        );
        expect(
          _visibleText(recordingPort.requests.last),
          contains('目标关系：${target.label}'),
        );
      }

      await transformPort.transform(
        _request(action: CanvasAiAction.personaInsertion),
      );
      final personaParts = _textParts(recordingPort.requests.last);
      expect(personaParts, hasLength(3));
      expect(personaParts.first.length, lessThanOrEqualTo(1000));
      expect(personaParts.first, isNot(contains('面向创业者的内容顾问')));
      expect(
        (jsonDecode(personaParts[1]) as Map)['markdown'],
        '先说清真正的问题，再决定下一步行动。',
      );
      expect(personaParts[2], contains('面向创业者的内容顾问，擅长把复杂问题拆成步骤'));
    },
  );

  test(
    'long chat advice is a supplemental part and Markdown stays sole baseline',
    () async {
      const source = '先说清真正的问题，再决定下一步行动。';
      const diff =
          '--- a/draft.md\n'
          '+++ b/draft.md\n'
          '@@ -1 +1 @@\n'
          '-先说清真正的问题，再决定下一步行动。\n'
          '+换一种表达。';
      final advice = List<String>.filled(240, '请加强节奏并保留事实。').join();
      expect(advice.length, greaterThan(1000));
      final recordingPort = _RecordingMobileAgentPort(
        const MobileAgentReadyTestPort(finalAnswer: diff),
      );
      final agent = MobileAgentCapabilityController(
        port: recordingPort,
        identity: const MobileAgentRuntimeIdentity(
          userId: 'test-user',
          workspaceId: 'test-workspace',
          locale: 'zh-CN',
          timezone: 'Asia/Shanghai',
        ),
        pollInterval: Duration.zero,
        retryInterval: Duration.zero,
        delay: (_) async {},
      );
      addTearDown(agent.dispose);

      await MobileAgentCanvasAiTransformPort(
        agent,
      ).transform(_chatRequest(instruction: advice, source: source));

      final parts = _textParts(recordingPort.requests.single);
      expect(parts, hasLength(3));
      expect(parts.first.length, lessThanOrEqualTo(1000));
      expect(parts.first, isNot(contains(advice)));
      expect((jsonDecode(parts[1]) as Map)['markdown'], source);
      expect(parts[2], contains(advice));
      expect(parts[2], contains('不是 diff 基线'));
    },
  );

  test(
    'Canvas cancellation cancels an AgentRun whose receipt arrives late',
    () async {
      final mobilePort = _DelayedCreateCancellationPort();
      final agent = MobileAgentCapabilityController(
        port: mobilePort,
        identity: const MobileAgentRuntimeIdentity(
          userId: 'test-user',
          workspaceId: 'test-workspace',
          locale: 'zh-CN',
          timezone: 'Asia/Shanghai',
        ),
        pollInterval: Duration.zero,
        retryInterval: Duration.zero,
        delay: (_) async {},
      );
      addTearDown(agent.dispose);
      final transformPort = MobileAgentCanvasAiTransformPort(agent);
      final request = _request(action: CanvasAiAction.expansion);

      final pending = transformPort.transform(request);
      final pendingExpectation = expectLater(
        pending,
        throwsA(
          isA<CanvasAiTransformException>().having(
            (error) => error.code,
            'code',
            'AGENT_RUN_SUPERSEDED',
          ),
        ),
      );
      while (mobilePort.createRequest == null) {
        await Future<void>.delayed(Duration.zero);
      }
      final cancelling = transformPort.cancelTransform(request.requestId);
      await mobilePort.completeCreate();
      expect(await cancelling, isTrue);
      await pendingExpectation;
      expect(mobilePort.cancelledRunIds, <String>['test-agent-run']);
      expect(mobilePort.cancelIdempotencyKeys, hasLength(1));
    },
  );

  test(
    'terminal AgentRun failures require a fresh Canvas generation',
    () async {
      final agent = _agentForRun(
        AgentRunSnapshot(
          agentRunId: 'terminal-failure-run',
          workspaceId: 'test-workspace',
          status: 'failed',
          workspaceVersion: 1,
          workspaceBindingVersion: 1,
          contextGeneration: 1,
          error: AgentRunPublicError(code: 'AGENT_RUN_FAILED'),
          usage: const AgentRunUsage(
            measurementStatus: 'unavailable',
            inputTokens: null,
            outputTokens: null,
            imageCount: null,
            videoSeconds: null,
            accountedCredits: null,
            policyVersion: null,
          ),
          toolTrace: const <AgentRunToolTrace>[],
          createdAt: DateTime.utc(2026, 8, 11),
          updatedAt: DateTime.utc(2026, 8, 11),
        ),
      );
      addTearDown(agent.dispose);

      await expectLater(
        MobileAgentCanvasAiTransformPort(
          agent,
        ).transform(_request(action: CanvasAiAction.expansion)),
        throwsA(
          isA<CanvasAiTransformException>()
              .having((error) => error.code, 'code', 'AGENT_RUN_FAILED')
              .having(
                (error) => error.recovery,
                'recovery',
                CanvasAiFailureRecovery.regenerate,
              ),
        ),
      );
    },
  );

  test(
    'unfinished AgentRun failures retain their Canvas operation ID',
    () async {
      final agent = _agentForRun(
        AgentRunSnapshot(
          agentRunId: 'unfinished-run',
          workspaceId: 'test-workspace',
          status: 'running',
          workspaceVersion: 1,
          workspaceBindingVersion: 1,
          contextGeneration: 1,
          usage: const AgentRunUsage(
            measurementStatus: 'pending',
            inputTokens: null,
            outputTokens: null,
            imageCount: null,
            videoSeconds: null,
            accountedCredits: null,
            policyVersion: null,
          ),
          toolTrace: const <AgentRunToolTrace>[],
          createdAt: DateTime.utc(2026, 8, 11),
          updatedAt: DateTime.utc(2026, 8, 11),
        ),
        maxPollAttempts: 1,
      );
      addTearDown(agent.dispose);

      await expectLater(
        MobileAgentCanvasAiTransformPort(
          agent,
        ).transform(_request(action: CanvasAiAction.expansion)),
        throwsA(
          isA<CanvasAiTransformException>()
              .having((error) => error.code, 'code', 'AGENT_RUN_POLL_TIMEOUT')
              .having(
                (error) => error.recovery,
                'recovery',
                CanvasAiFailureRecovery.retrySameRequest,
              ),
        ),
      );
    },
  );

  test(
    'production port wraps a terminal image brief in a verified diff',
    () async {
      const imageBrief =
          '> **配图建议**\n>\n> - **构图**：让核心行动保持在画面中心。\n'
          '> - **替代文本**：创作者正在记录真实场景。';
      final agent = MobileAgentCapabilityController(
        port: const MobileAgentReadyTestPort(finalAnswer: imageBrief),
        identity: const MobileAgentRuntimeIdentity(
          userId: 'test-user',
          workspaceId: 'test-workspace',
          locale: 'zh-CN',
          timezone: 'Asia/Shanghai',
        ),
        pollInterval: Duration.zero,
        retryInterval: Duration.zero,
        delay: (_) async {},
      );
      addTearDown(agent.dispose);

      final request = _request(action: CanvasAiAction.imageBrief);
      final result = await MobileAgentCanvasAiTransformPort(
        agent,
      ).transform(request);

      expect(result.replacementMarkdown, isEmpty);
      expect(result.unifiedDiff, isNotNull);
      final applied = canvasApplyUnifiedDiff(
        baseMarkdown: request.targetMarkdown,
        unifiedDiff: result.unifiedDiff!,
      );
      expect(applied, startsWith(request.targetMarkdown));
      expect(applied, endsWith(imageBrief));
    },
  );

  test('production port rejects a destructive image-brief patch', () async {
    final request = _request(action: CanvasAiAction.imageBrief);
    final destructiveDiff = canvasBuildWholePayloadUnifiedDiff(
      baseMarkdown: request.targetMarkdown,
      replacementMarkdown: '> **配图建议**\n\n- 只留下配图说明。',
    );
    final agent = MobileAgentCapabilityController(
      port: MobileAgentReadyTestPort(finalAnswer: destructiveDiff),
      identity: const MobileAgentRuntimeIdentity(
        userId: 'test-user',
        workspaceId: 'test-workspace',
        locale: 'zh-CN',
        timezone: 'Asia/Shanghai',
      ),
      pollInterval: Duration.zero,
      retryInterval: Duration.zero,
      delay: (_) async {},
    );
    addTearDown(agent.dispose);

    await expectLater(
      MobileAgentCanvasAiTransformPort(agent).transform(request),
      throwsA(
        isA<CanvasAiTransformException>().having(
          (error) => error.code,
          'code',
          'CANVAS_AI_IMAGE_BRIEF_INVALID',
        ),
      ),
    );
  });

  test('production port rejects oversized inline terminal output', () async {
    final oversized = String.fromCharCodes(
      List<int>.filled(canvasAiMaxUnifiedDiffBytes + 1, 0x78),
    );
    final agent = MobileAgentCapabilityController(
      port: MobileAgentReadyTestPort(finalAnswer: oversized),
      identity: const MobileAgentRuntimeIdentity(
        userId: 'test-user',
        workspaceId: 'test-workspace',
        locale: 'zh-CN',
        timezone: 'Asia/Shanghai',
      ),
      pollInterval: Duration.zero,
      retryInterval: Duration.zero,
      delay: (_) async {},
    );
    addTearDown(agent.dispose);

    await expectLater(
      MobileAgentCanvasAiTransformPort(
        agent,
      ).transform(_request(action: CanvasAiAction.expansion)),
      throwsA(
        isA<CanvasAiTransformException>().having(
          (error) => error.code,
          'code',
          'CANVAS_AI_DIFF_TOO_LARGE',
        ),
      ),
    );
  });

  test('production port reads a unified diff output file', () async {
    const canonicalDiff =
        '--- a/draft.md\n'
        '+++ b/draft.md\n'
        '@@ -1 +1 @@\n'
        '-旧内容\n'
        '+新内容';
    const diff = '$canonicalDiff\n';
    const outputFile = AgentRunOutputFile(
      resourceId: 'canvas-diff-file',
      fileName: 'canvas.patch',
      mimeType: 'text/x-diff',
      sizeBytes: 64,
    );
    final agent = MobileAgentCapabilityController(
      port: const MobileAgentReadyTestPort(
        finalAnswer: '修改文件已准备好。',
        outputFiles: <AgentRunOutputFile>[outputFile],
      ),
      identity: const MobileAgentRuntimeIdentity(
        userId: 'test-user',
        workspaceId: 'test-workspace',
        locale: 'zh-CN',
        timezone: 'Asia/Shanghai',
      ),
      pollInterval: Duration.zero,
      retryInterval: Duration.zero,
      delay: (_) async {},
    );
    addTearDown(agent.dispose);
    final reader = _RecordingDiffFileReader(diff);

    final result = await MobileAgentCanvasAiTransformPort(
      agent,
      diffFileReader: reader,
    ).transform(_request(action: CanvasAiAction.expansion));

    expect(reader.requested?.resourceId, outputFile.resourceId);
    expect(reader.requested?.fileName, outputFile.fileName);
    expect(result.unifiedDiff, canonicalDiff);
    expect(result.replacementMarkdown, isEmpty);
  });

  test('production port bounds an injected diff file reader', () async {
    final oversized = String.fromCharCodes(
      List<int>.filled(canvasAiMaxUnifiedDiffBytes + 1, 0x78),
    );
    const outputFile = AgentRunOutputFile(
      resourceId: 'canvas-diff-file',
      fileName: 'canvas.patch',
      mimeType: 'text/x-diff',
      sizeBytes: 1,
    );
    final agent = MobileAgentCapabilityController(
      port: const MobileAgentReadyTestPort(
        finalAnswer: '修改文件已准备好。',
        outputFiles: <AgentRunOutputFile>[outputFile],
      ),
      identity: const MobileAgentRuntimeIdentity(
        userId: 'test-user',
        workspaceId: 'test-workspace',
        locale: 'zh-CN',
        timezone: 'Asia/Shanghai',
      ),
      pollInterval: Duration.zero,
      retryInterval: Duration.zero,
      delay: (_) async {},
    );
    addTearDown(agent.dispose);

    await expectLater(
      MobileAgentCanvasAiTransformPort(
        agent,
        diffFileReader: _RecordingDiffFileReader(oversized),
      ).transform(_request(action: CanvasAiAction.expansion)),
      throwsA(
        isA<CanvasAiTransformException>().having(
          (error) => error.code,
          'code',
          'CANVAS_AI_DIFF_TOO_LARGE',
        ),
      ),
    );
  });

  test(
    'production port rejects both an inline and file patch as ambiguous',
    () async {
      const diff =
          '--- a/draft.md\n'
          '+++ b/draft.md\n'
          '@@ -1 +1 @@\n'
          '-旧内容\n'
          '+新内容';
      const outputFile = AgentRunOutputFile(
        resourceId: 'canvas-diff-file',
        fileName: 'canvas.patch',
        mimeType: 'text/x-diff',
        sizeBytes: 64,
      );
      final agent = MobileAgentCapabilityController(
        port: const MobileAgentReadyTestPort(
          finalAnswer: diff,
          outputFiles: <AgentRunOutputFile>[outputFile],
        ),
        identity: const MobileAgentRuntimeIdentity(
          userId: 'test-user',
          workspaceId: 'test-workspace',
          locale: 'zh-CN',
          timezone: 'Asia/Shanghai',
        ),
        pollInterval: Duration.zero,
        retryInterval: Duration.zero,
        delay: (_) async {},
      );
      addTearDown(agent.dispose);

      await expectLater(
        MobileAgentCanvasAiTransformPort(
          agent,
          diffFileReader: _RecordingDiffFileReader(diff),
        ).transform(_request(action: CanvasAiAction.expansion)),
        throwsA(
          isA<CanvasAiTransformException>().having(
            (error) => error.code,
            'code',
            'CANVAS_AI_DIFF_FILE_AMBIGUOUS',
          ),
        ),
      );
    },
  );

  test(
    'debug remote diff fixture returns an applyable output-file patch',
    () async {
      final request = _request(
        action: CanvasAiAction.expansion,
        source: '先说清楚用户在什么场景里遇到了什么问题。',
      );

      final result = await CanvasAiDebugRemoteDiffPort(
        transformPort: const CanvasAiTransformMockPort(delay: Duration.zero),
      ).transform(request);

      expect(result.replacementMarkdown, isEmpty);
      expect(result.unifiedDiff, isNotNull);
      final applied = canvasApplyUnifiedDiff(
        baseMarkdown: request.targetMarkdown,
        unifiedDiff: result.unifiedDiff!,
      );
      expect(applied, contains('进一步说明'));
      expect(applied, contains('用户在什么场景'));
    },
  );

  test('debug remote diff fixture verifies image brief insertion', () async {
    final request = _request(action: CanvasAiAction.imageBrief);
    final result = await CanvasAiDebugRemoteDiffPort(
      transformPort: const CanvasAiTransformMockPort(delay: Duration.zero),
    ).transform(request);

    expect(result.replacementMarkdown, isEmpty);
    expect(result.unifiedDiff, isNotNull);
    final applied = canvasApplyUnifiedDiff(
      baseMarkdown: request.targetMarkdown,
      unifiedDiff: result.unifiedDiff!,
    );
    expect(applied, startsWith(request.targetMarkdown));
    expect(applied, contains('> **配图建议**'));
  });

  test(
    'remote diff reader obtains a signed playback URL then UTF-8 patch',
    () async {
      const diff =
          '--- a/draft.md\n'
          '+++ b/draft.md\n'
          '@@ -1 +1 @@\n'
          '-旧内容\n'
          '+新内容\n';
      final outputFile = AgentRunOutputFile(
        resourceId: 'canvas-diff-file',
        fileName: 'canvas.diff',
        mimeType: 'text/x-diff',
        sizeBytes: utf8.encode(diff).length,
      );
      final transport = _PlaybackTransport(diff);
      final reader = RemoteCanvasAiDiffFileReader(
        ApiClient(
          config: ApiClientConfig(
            baseUrl: Uri.parse('https://api.example.test'),
            clientVersion: 'test',
            deviceId: 'device-test',
            platform: 'ios',
            locale: 'zh-CN',
            getAccessToken: () => 'access-token',
          ),
          transport: transport,
        ),
      );

      expect(await reader.read(outputFile), diff);
      expect(transport.requests, hasLength(2));
      expect(transport.requests.first.url.path, contains('/playback'));
      expect(
        transport.requests.first.headers['Authorization'],
        'Bearer access-token',
      );
      expect(
        transport.requests.last.url,
        Uri.parse('https://storage.example.test/canvas.diff'),
      );
    },
  );

  test('remote diff reader rejects a mismatched resource byte count', () async {
    const diff =
        '--- a/draft.md\n'
        '+++ b/draft.md\n'
        '@@ -1 +1 @@\n'
        '-旧内容\n'
        '+新内容\n';
    final outputFile = AgentRunOutputFile(
      resourceId: 'canvas-diff-file',
      fileName: 'canvas.diff',
      mimeType: 'text/x-diff',
      sizeBytes: utf8.encode(diff).length + 1,
    );
    final reader = RemoteCanvasAiDiffFileReader(
      ApiClient(
        config: ApiClientConfig(
          baseUrl: Uri.parse('https://api.example.test'),
          clientVersion: 'test',
          deviceId: 'device-test',
          platform: 'ios',
          locale: 'zh-CN',
          getAccessToken: () => 'access-token',
        ),
        transport: _PlaybackTransport(diff),
      ),
    );

    await expectLater(
      reader.read(outputFile),
      throwsA(
        isA<CanvasAiTransformException>().having(
          (error) => error.code,
          'code',
          'CANVAS_AI_DIFF_FILE_INVALID',
        ),
      ),
    );
  });

  test('remote diff reader refuses a non-HTTPS playback receipt', () async {
    const diff =
        '--- a/draft.md\n'
        '+++ b/draft.md\n'
        '@@ -1 +1 @@\n'
        '-旧内容\n'
        '+新内容\n';
    final outputFile = AgentRunOutputFile(
      resourceId: 'canvas-diff-file',
      fileName: 'canvas.diff',
      mimeType: 'text/x-diff',
      sizeBytes: utf8.encode(diff).length,
    );
    final reader = RemoteCanvasAiDiffFileReader(
      ApiClient(
        config: ApiClientConfig(
          baseUrl: Uri.parse('https://api.example.test'),
          clientVersion: 'test',
          deviceId: 'device-test',
          platform: 'ios',
          locale: 'zh-CN',
          getAccessToken: () => 'access-token',
        ),
        transport: _PlaybackTransport(
          diff,
          playbackUrl: 'http://storage.example.test/canvas.diff',
        ),
      ),
    );

    await expectLater(
      reader.read(outputFile),
      throwsA(
        isA<CanvasAiTransformException>()
            .having(
              (error) => error.code,
              'code',
              'CANVAS_AI_DIFF_FILE_UNAVAILABLE',
            )
            .having(
              (error) => error.recovery,
              'recovery',
              CanvasAiFailureRecovery.regenerate,
            ),
      ),
    );
  });

  test('remote diff reader retries a retryable playback receipt', () async {
    const diff =
        '--- a/draft.md\n'
        '+++ b/draft.md\n'
        '@@ -1 +1 @@\n'
        '-旧内容\n'
        '+新内容\n';
    final outputFile = AgentRunOutputFile(
      resourceId: 'canvas-diff-file',
      fileName: 'canvas.diff',
      mimeType: 'text/x-diff',
      sizeBytes: utf8.encode(diff).length,
    );
    final transport = _PlaybackTransport(diff, playbackStatus: 503);
    final reader = RemoteCanvasAiDiffFileReader(
      ApiClient(
        config: ApiClientConfig(
          baseUrl: Uri.parse('https://api.example.test'),
          clientVersion: 'test',
          deviceId: 'device-test',
          platform: 'ios',
          locale: 'zh-CN',
          getAccessToken: () => 'access-token',
        ),
        transport: transport,
      ),
    );

    await expectLater(
      reader.read(outputFile),
      throwsA(
        isA<CanvasAiTransformException>()
            .having(
              (error) => error.code,
              'code',
              'CANVAS_AI_DIFF_FILE_UNAVAILABLE',
            )
            .having(
              (error) => error.recovery,
              'recovery',
              CanvasAiFailureRecovery.retrySameRequest,
            ),
      ),
    );
    expect(transport.requests, hasLength(1));
  });
}

final class _RecordingDiffFileReader implements CanvasAiDiffFileReader {
  _RecordingDiffFileReader(this._content);

  final String _content;
  AgentRunOutputFile? requested;

  @override
  Future<String> read(AgentRunOutputFile outputFile) async {
    requested = outputFile;
    return _content;
  }
}

String _visibleText(AgentRunRequest request) =>
    (request.input.content.first as SharedAgentTextContent).text;

List<String> _textParts(AgentRunRequest request) => request.input.content
    .whereType<SharedAgentTextContent>()
    .map((part) => part.text)
    .toList(growable: false);

final class _RecordingMobileAgentPort implements MobileAgentCapabilityPort {
  _RecordingMobileAgentPort(this._delegate);

  final MobileAgentCapabilityPort _delegate;
  final List<AgentRunRequest> requests = <AgentRunRequest>[];

  @override
  Future<ApiResult<AgentProfileCatalog>> profiles() => _delegate.profiles();

  @override
  Future<ApiResult<List<SkillProfileCatalogItem>>> skills(
    String agentProfileId,
  ) => _delegate.skills(agentProfileId);

  @override
  Future<ApiResult<List<ModelProfileCatalogItem>>> models(
    String agentProfileId,
  ) => _delegate.models(agentProfileId);

  @override
  Future<ApiResult<SharedSkillInstallationList>> installations(
    String workspaceId,
  ) => _delegate.installations(workspaceId);

  @override
  Future<ApiResult<AgentRunSnapshot>> createRun(
    AgentRunRequest request, {
    required String idempotencyKey,
  }) {
    requests.add(request);
    return _delegate.createRun(request, idempotencyKey: idempotencyKey);
  }

  @override
  Future<ApiResult<AgentRunSnapshot>> run(String agentRunId) =>
      _delegate.run(agentRunId);

  @override
  Future<ApiResult<SharedRunUsage>> runUsage(String agentRunId) =>
      _delegate.runUsage(agentRunId);
}

final class _PlaybackTransport implements ApiTransport {
  _PlaybackTransport(
    this._diff, {
    this.playbackUrl = 'https://storage.example.test/canvas.diff',
    this.playbackStatus = 200,
  });

  final String _diff;
  final String playbackUrl;
  final int playbackStatus;
  final List<ApiTransportRequest> requests = <ApiTransportRequest>[];

  @override
  Future<ApiTransportResponse> send(ApiTransportRequest request) async {
    requests.add(request);
    if (request.url.path.endsWith('/playback')) {
      if (playbackStatus != 200) {
        return ApiTransportResponse(
          status: playbackStatus,
          body: <String, Object?>{
            'success': false,
            'error': <String, Object?>{'code': 'PLAYBACK_UNAVAILABLE'},
          },
        );
      }
      return ApiTransportResponse(
        status: 200,
        body: <String, Object?>{
          'success': true,
          'data': <String, Object?>{
            'resourceId': 'canvas-diff-file',
            'url': playbackUrl,
            'status': 'available',
            'expiresIn': 900,
          },
        },
      );
    }
    return ApiTransportResponse(
      status: 200,
      body: Uint8List.fromList(utf8.encode(_diff)),
    );
  }
}

MobileAgentCapabilityController _agentForRun(
  AgentRunSnapshot run, {
  int maxPollAttempts = 40,
}) => MobileAgentCapabilityController(
  port: _SingleRunMobileAgentPort(run),
  identity: const MobileAgentRuntimeIdentity(
    userId: 'test-user',
    workspaceId: 'test-workspace',
    locale: 'zh-CN',
    timezone: 'Asia/Shanghai',
  ),
  pollInterval: Duration.zero,
  retryInterval: Duration.zero,
  maxPollAttempts: maxPollAttempts,
  delay: (_) async {},
);

final class _SingleRunMobileAgentPort implements MobileAgentCapabilityPort {
  _SingleRunMobileAgentPort(this._run);

  final AgentRunSnapshot _run;
  final MobileAgentReadyTestPort _ready = const MobileAgentReadyTestPort();

  @override
  Future<ApiResult<AgentProfileCatalog>> profiles() => _ready.profiles();

  @override
  Future<ApiResult<List<SkillProfileCatalogItem>>> skills(
    String agentProfileId,
  ) => _ready.skills(agentProfileId);

  @override
  Future<ApiResult<List<ModelProfileCatalogItem>>> models(
    String agentProfileId,
  ) => _ready.models(agentProfileId);

  @override
  Future<ApiResult<SharedSkillInstallationList>> installations(
    String workspaceId,
  ) => _ready.installations(workspaceId);

  @override
  Future<ApiResult<AgentRunSnapshot>> createRun(
    AgentRunRequest request, {
    required String idempotencyKey,
  }) async => _runResult();

  @override
  Future<ApiResult<AgentRunSnapshot>> run(String agentRunId) async =>
      _runResult();

  @override
  Future<ApiResult<SharedRunUsage>> runUsage(String agentRunId) =>
      _ready.runUsage(agentRunId);

  ApiResult<AgentRunSnapshot> _runResult() =>
      ApiResult<AgentRunSnapshot>.success(
        data: _run,
        status: 200,
        idempotencyStore: SubmissionKeyStore.empty,
      );
}

final class _DelayedCreateCancellationPort
    implements MobileAgentCapabilityPort, MobileAgentRunCancellationPort {
  final MobileAgentReadyTestPort _ready = const MobileAgentReadyTestPort();
  final Completer<ApiResult<AgentRunSnapshot>> _create =
      Completer<ApiResult<AgentRunSnapshot>>();
  AgentRunRequest? createRequest;
  String? createIdempotencyKey;
  final List<String> cancelledRunIds = <String>[];
  final List<String> cancelIdempotencyKeys = <String>[];

  @override
  Future<ApiResult<AgentProfileCatalog>> profiles() => _ready.profiles();

  @override
  Future<ApiResult<List<SkillProfileCatalogItem>>> skills(
    String agentProfileId,
  ) => _ready.skills(agentProfileId);

  @override
  Future<ApiResult<List<ModelProfileCatalogItem>>> models(
    String agentProfileId,
  ) => _ready.models(agentProfileId);

  @override
  Future<ApiResult<SharedSkillInstallationList>> installations(
    String workspaceId,
  ) => _ready.installations(workspaceId);

  @override
  Future<ApiResult<AgentRunSnapshot>> createRun(
    AgentRunRequest request, {
    required String idempotencyKey,
  }) {
    createRequest = request;
    createIdempotencyKey = idempotencyKey;
    return _create.future;
  }

  Future<void> completeCreate() async {
    final request = createRequest!;
    _create.complete(
      await _ready.createRun(request, idempotencyKey: createIdempotencyKey!),
    );
  }

  @override
  Future<ApiResult<AgentRunSnapshot>> cancelRun(
    String agentRunId, {
    required String idempotencyKey,
  }) async {
    cancelledRunIds.add(agentRunId);
    cancelIdempotencyKeys.add(idempotencyKey);
    return _ready.run(agentRunId);
  }

  @override
  Future<ApiResult<AgentRunSnapshot>> run(String agentRunId) =>
      _ready.run(agentRunId);

  @override
  Future<ApiResult<SharedRunUsage>> runUsage(String agentRunId) =>
      _ready.runUsage(agentRunId);
}

String _applyResult(CanvasAiRequest request, CanvasAiResult result) =>
    canvasApplyUnifiedDiff(
      baseMarkdown: request.targetMarkdown,
      unifiedDiff: result.unifiedDiff!,
    );

CanvasAiRequest _request({
  required CanvasAiAction action,
  String source = '先说清真正的问题，再决定下一步行动。',
  CanvasOpeningVariant? openingVariant,
  CanvasImageVariant? imageVariant,
  CanvasRelationTarget? relationTarget,
  CanvasAiEditScope editScope = CanvasAiEditScope.global,
}) {
  final effectiveOpening = action == CanvasAiAction.openingOptimization
      ? openingVariant ?? CanvasOpeningVariant.labeling
      : openingVariant;
  final effectiveRelation = action == CanvasAiAction.socialRelationShift
      ? relationTarget ?? CanvasRelationTarget.peer
      : relationTarget;
  final effectiveImage = action == CanvasAiAction.imageBrief
      ? imageVariant ?? CanvasImageVariant.sceneDesign
      : imageVariant;
  return CanvasAiRequest(
    requestId: 'request-${action.name}',
    command: CanvasAiSkillCommand(action),
    scope: editScope == CanvasAiEditScope.local
        ? CanvasTransformScope.selection
        : CanvasTransformScope.document,
    editScope: editScope,
    documentMarkdown: source,
    documentRevision: 3,
    documentHash: canvasTextHash(source),
    targetRange: CanvasTextRange(start: 0, end: source.length),
    targetMarkdown: source,
    targetHash: canvasTextHash(source),
    openingVariant: effectiveOpening,
    imageVariant: effectiveImage,
    relationTarget: effectiveRelation,
    personaContext: action == CanvasAiAction.personaInsertion
        ? '面向创业者的内容顾问，擅长把复杂问题拆成步骤'
        : null,
  );
}

CanvasAiRequest _chatRequest({
  required String instruction,
  required String source,
}) => CanvasAiRequest(
  requestId: 'request-chat-rewrite',
  command: CanvasAiChatRewriteCommand(instruction),
  scope: CanvasTransformScope.document,
  editScope: CanvasAiEditScope.global,
  documentMarkdown: source,
  documentRevision: 3,
  documentHash: canvasTextHash(source),
  targetRange: CanvasTextRange(start: 0, end: source.length),
  targetMarkdown: source,
  targetHash: canvasTextHash(source),
);
