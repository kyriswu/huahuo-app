import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/bootstrap/app_providers.dart';
import '../../../core/api/api_client.dart';
import '../../../core/database/diagnostic_log_dao.dart';
import '../../../core/diagnostics/diagnostic_logger.dart';
import '../../agent/application/mobile_agent_capability_controller.dart';
import '../domain/canvas_ai_models.dart';

const _canvasDebugRemoteDiffRequested = bool.fromEnvironment(
  'HUAHUO_CANVAS_DEBUG_REMOTE_DIFF',
);
const canvasAiMaxUnifiedDiffBytes = 2 * 1024 * 1024;

bool get canvasDebugRemoteDiffEnabled =>
    kDebugMode && _canvasDebugRemoteDiffRequested;

// resident-provider: Shares one canvas ai transform port dependency for the full account session.
final canvasAiTransformPortProvider = Provider<CanvasAiTransformPort>((ref) {
  if (canvasDebugRemoteDiffEnabled) {
    return CanvasAiDebugRemoteDiffPort();
  }
  CanvasAiDiffFileReader diffFileReader =
      const UnavailableCanvasAiDiffFileReader();
  try {
    diffFileReader = RemoteCanvasAiDiffFileReader(ref.watch(apiClientProvider));
  } on StateError catch (error) {
    if (error.message != 'DEVICE_IDENTITY_NOT_RESOLVED') rethrow;
  }
  return MobileAgentCanvasAiTransformPort(
    ref.watch(mobileAgentCapabilityControllerProvider),
    diffFileReader: diffFileReader,
    diagnosticLogger: ref.watch(diagnosticLoggerProvider),
  );
});

abstract interface class CanvasAiTransformPort {
  Future<CanvasAiResult> transform(CanvasAiRequest request);
}

abstract interface class CanvasAiTransformCancellationPort {
  Future<bool> cancelTransform(String requestId);
}

enum CanvasAiFailureRecovery { retrySameRequest, regenerate }

final class CanvasAiTransformException implements Exception {
  const CanvasAiTransformException(
    this.code, {
    this.recovery = CanvasAiFailureRecovery.regenerate,
    this.agentRunId,
    this.isAwaitingCompletion = false,
  });

  final String code;
  final CanvasAiFailureRecovery recovery;
  final String? agentRunId;
  final bool isAwaitingCompletion;

  @override
  String toString() => 'CanvasAiTransformException($code)';
}

abstract interface class CanvasAiDiffFileReader {
  Future<String> read(AgentRunOutputFile outputFile);
}

final class UnavailableCanvasAiDiffFileReader
    implements CanvasAiDiffFileReader {
  const UnavailableCanvasAiDiffFileReader();

  @override
  Future<String> read(AgentRunOutputFile outputFile) async =>
      throw const CanvasAiTransformException(
        'CANVAS_AI_DIFF_FILE_UNAVAILABLE',
        recovery: CanvasAiFailureRecovery.retrySameRequest,
      );
}

final class RemoteCanvasAiDiffFileReader implements CanvasAiDiffFileReader {
  RemoteCanvasAiDiffFileReader(this._apiClient);

  final ApiClient _apiClient;

  @override
  Future<String> read(AgentRunOutputFile outputFile) async {
    if (!_isCanvasUnifiedDiffOutputFile(outputFile) ||
        outputFile.sizeBytes < 1 ||
        outputFile.sizeBytes > canvasAiMaxUnifiedDiffBytes) {
      throw const CanvasAiTransformException('CANVAS_AI_DIFF_FILE_INVALID');
    }
    try {
      final playback = await _apiClient.request<Uri>(
        ApiRequestOptions<Uri>(
          endpointId: 'mediaResourcePlayback',
          pathParams: <String, Object>{'resourceId': outputFile.resourceId},
          parseData: _parseCanvasDiffPlaybackUrl,
        ),
      );
      final url = playback.data;
      if (!playback.ok) {
        throw CanvasAiTransformException(
          'CANVAS_AI_DIFF_FILE_UNAVAILABLE',
          recovery:
              playback.error?.isRetryable == true ||
                  _isRetryablePlaybackStatus(playback.status)
              ? CanvasAiFailureRecovery.retrySameRequest
              : CanvasAiFailureRecovery.regenerate,
        );
      }
      if (url == null) {
        throw const CanvasAiTransformException('CANVAS_AI_DIFF_FILE_INVALID');
      }
      final response = await _apiClient.transport
          .send(
            ApiTransportRequest(
              url: url,
              method: 'GET',
              headers: const <String, String>{
                'Accept': 'text/x-diff, text/x-patch, text/plain',
              },
              responseMode: EndpointResponseMode.binary,
            ),
          )
          .timeout(_apiClient.config.requestTimeout);
      if (!response.ok) {
        throw const CanvasAiTransformException(
          'CANVAS_AI_DIFF_FILE_UNAVAILABLE',
          recovery: CanvasAiFailureRecovery.retrySameRequest,
        );
      }
      final bytes = switch (response.body) {
        Uint8List value => value,
        List<int> value => Uint8List.fromList(value),
        _ => null,
      };
      if (bytes == null ||
          bytes.isEmpty ||
          bytes.length != outputFile.sizeBytes ||
          bytes.length > canvasAiMaxUnifiedDiffBytes) {
        throw const CanvasAiTransformException('CANVAS_AI_DIFF_FILE_INVALID');
      }
      return utf8.decode(bytes);
    } on CanvasAiTransformException {
      rethrow;
    } on FormatException {
      throw const CanvasAiTransformException('CANVAS_AI_DIFF_FILE_INVALID');
    } catch (_) {
      throw const CanvasAiTransformException(
        'CANVAS_AI_DIFF_FILE_UNAVAILABLE',
        recovery: CanvasAiFailureRecovery.retrySameRequest,
      );
    }
  }
}

bool _isRetryablePlaybackStatus(int? status) =>
    status == 408 ||
    status == 429 ||
    (status != null && status >= 500 && status < 600);

final class UnavailableCanvasAiTransformPort implements CanvasAiTransformPort {
  const UnavailableCanvasAiTransformPort();

  @override
  Future<CanvasAiResult> transform(CanvasAiRequest request) async =>
      throw const CanvasAiTransformException('CANVAS_AI_BACKEND_UNAVAILABLE');
}

final class MobileAgentCanvasAiTransformPort
    implements CanvasAiTransformPort, CanvasAiTransformCancellationPort {
  MobileAgentCanvasAiTransformPort(
    this._agent, {
    CanvasAiDiffFileReader? diffFileReader,
    this.pollingPolicy = const MobileAgentRunPollingPolicy(),
    DiagnosticLogger? diagnosticLogger,
  }) : _diffFileReader =
           diffFileReader ?? const UnavailableCanvasAiDiffFileReader(),
       _logger = diagnosticLogger;

  final MobileAgentCapabilityController _agent;
  final CanvasAiDiffFileReader _diffFileReader;
  final MobileAgentRunPollingPolicy pollingPolicy;
  final DiagnosticLogger? _logger;
  final Set<String> _activeRequestIds = <String>{};
  final Map<String, String?> _requestUserScopes = {};
  final Map<String, String> _requestRunIds = {};
  final Set<String> _cancelledRequestIds = <String>{};

  @override
  Future<CanvasAiResult> transform(CanvasAiRequest request) async {
    final requestId = request.requestId;
    _activeRequestIds.add(requestId);
    _requestUserScopes[requestId] = _agent.identity.userId;
    _diagnose(request, 'started');
    try {
      final result = await _transform(request);
      _diagnose(request, 'result_received');
      return result;
    } on CanvasAiTransformException catch (error) {
      _diagnose(
        request,
        error.isAwaitingCompletion ? 'awaiting_completion' : 'failed',
        errorCode: error.code,
        runId: error.agentRunId,
      );
      rethrow;
    } finally {
      _activeRequestIds.remove(requestId);
      _requestUserScopes.remove(requestId);
      _requestRunIds.remove(requestId);
      _cancelledRequestIds.remove(requestId);
    }
  }

  @override
  Future<bool> cancelTransform(String requestId) async {
    final normalized = requestId.trim();
    if (normalized.isEmpty) return true;
    if (_activeRequestIds.contains(normalized)) {
      _cancelledRequestIds.add(normalized);
    }
    return _agent.cancelOperation(normalized);
  }

  void _diagnose(
    CanvasAiRequest request,
    String phase, {
    String? runId,
    String? errorCode,
  }) {
    if (runId != null) _requestRunIds[request.requestId] = runId;
    try {
      _logger?.log(
        DiagnosticLogInput(
          category: DiagnosticCategory.workAi,
          severity: errorCode == null
              ? DiagnosticSeverity.info
              : DiagnosticSeverity.warning,
          correlationId: request.requestId,
          safeSummary: 'Canvas AI operation state changed',
          flushImmediately: errorCode != null,
          metadata: {
            'phase': phase,
            'operation_id': request.requestId,
            'run_id': runId ?? _requestRunIds[request.requestId],
            'user_scope': _requestUserScopes[request.requestId],
            'action': request.action?.name ?? 'rewrite',
            'scope': request.editScope.name,
            'target_start': request.targetRange.start,
            'target_end': request.targetRange.end,
            'target_hash': request.targetHash,
            'document_revision': request.documentRevision,
            'error_code': errorCode,
          },
        ),
      );
    } on Object {
      return;
    }
  }

  Future<CanvasAiResult> _transform(CanvasAiRequest request) async {
    _throwIfCancelled(request.requestId);
    final featureId = _canvasFeatureId(request);
    final access = await _agent.ensureFeature(featureId);
    _throwIfCancelled(request.requestId);
    if (!access.isAvailable) {
      throw CanvasAiTransformException(
        access.errorCode ?? 'CANVAS_AI_FEATURE_UNAVAILABLE',
      );
    }
    final noteId = request.sourceNoteId?.trim();
    final partRevisionId = request.sourcePartRevisionId?.trim();
    if ((noteId == null) != (partRevisionId == null) ||
        noteId?.isEmpty == true ||
        partRevisionId?.isEmpty == true) {
      throw const CanvasAiTransformException(
        'CANVAS_AI_HNOTE_REVISION_INVALID',
      );
    }
    final outcome = await _agent.execute(
      MobileAgentRunCommand(
        operationId: request.requestId,
        featureId: featureId,
        visibleText: _canvasVisibleInstruction(request),
        additionalText: request.action == CanvasAiAction.imageBrief
            ? request.targetMarkdown
            : jsonEncode(<String, Object>{
                'schema': 'canvas_baseline.v1',
                'requestId': request.requestId,
                'baseHash': request.targetHash,
                'lineCount': const LineSplitter()
                    .convert(request.targetMarkdown)
                    .length,
                'markdown': request.targetMarkdown,
              }),
        supplementalText: _canvasSupplementalText(request),
        references: <MobileAgentInputReference>[
          if (noteId != null && partRevisionId != null)
            MobileAgentHNoteReference(
              noteId: noteId,
              part: 'raw',
              partRevisionId: partRevisionId,
            ),
        ],
      ),
      pollingPolicy: pollingPolicy,
      onProgress: (run) =>
          _diagnose(request, 'remote_${run.status}', runId: run.agentRunId),
    );
    _diagnose(
      request,
      outcome.succeeded ? 'remote_succeeded' : 'remote_unsettled',
      runId: outcome.run?.agentRunId,
      errorCode: outcome.errorCode,
    );
    final output = outcome.outputMarkdown ?? '';
    if (!outcome.succeeded) {
      throw CanvasAiTransformException(
        outcome.errorCode ?? 'CANVAS_AI_TRANSFORM_FAILED',
        recovery: _recoveryForAgentOutcome(outcome),
        agentRunId: outcome.run?.agentRunId,
        isAwaitingCompletion:
            outcome.errorCode == 'AGENT_RUN_POLL_TIMEOUT' &&
            outcome.run?.isTerminal == false,
      );
    }
    _throwIfCancelled(request.requestId);
    if (utf8.encode(output).length > canvasAiMaxUnifiedDiffBytes) {
      throw const CanvasAiTransformException('CANVAS_AI_DIFF_TOO_LARGE');
    }
    final replacement = request.action == CanvasAiAction.imageBrief
        ? null
        : _canvasStructuredReplacement(output, request);
    final inlineDiff = replacement == null
        ? canvasExtractUnifiedDiff(output)
        : null;
    final outputFiles =
        outcome.run?.outputFiles ?? const <AgentRunOutputFile>[];
    final fileDiffCount = outputFiles
        .where(_isCanvasUnifiedDiffOutputFile)
        .length;
    if ((inlineDiff != null || replacement != null) && fileDiffCount > 0) {
      throw const CanvasAiTransformException('CANVAS_AI_DIFF_FILE_AMBIGUOUS');
    }
    var unifiedDiff = replacement == null
        ? inlineDiff ?? await _readOutputFileDiff(outputFiles)
        : canvasBuildWholePayloadUnifiedDiff(
            baseMarkdown: request.targetMarkdown,
            replacementMarkdown: replacement,
          );
    if (unifiedDiff != null &&
        utf8.encode(unifiedDiff).length > canvasAiMaxUnifiedDiffBytes) {
      throw const CanvasAiTransformException('CANVAS_AI_DIFF_TOO_LARGE');
    }
    if (unifiedDiff == null) {
      if (request.action == CanvasAiAction.imageBrief &&
          output.trim().isNotEmpty) {
        unifiedDiff = canvasBuildWholePayloadUnifiedDiff(
          baseMarkdown: request.targetMarkdown,
          replacementMarkdown: _canvasImageBriefReplacement(
            request.targetMarkdown,
            output,
          ),
        );
        if (utf8.encode(unifiedDiff).length > canvasAiMaxUnifiedDiffBytes) {
          throw const CanvasAiTransformException('CANVAS_AI_DIFF_TOO_LARGE');
        }
      } else {
        throw const CanvasAiTransformException('CANVAS_AI_DIFF_REQUIRED');
      }
    }
    if (request.action == CanvasAiAction.imageBrief) {
      _validateCanvasImageBriefDiff(
        baseMarkdown: request.targetMarkdown,
        unifiedDiff: unifiedDiff,
      );
    }
    return CanvasAiResult(
      requestId: request.requestId,
      command: request.command,
      replacementMarkdown: '',
      unifiedDiff: unifiedDiff,
      sourceDocumentHash: request.documentHash,
      sourceTargetHash: request.targetHash,
      generatedAt: outcome.run!.updatedAt,
    );
  }

  void _throwIfCancelled(String requestId) {
    if (_cancelledRequestIds.contains(requestId)) {
      throw const CanvasAiTransformException('CANVAS_AI_CANCELLED');
    }
  }

  Future<String?> _readOutputFileDiff(
    List<AgentRunOutputFile> outputFiles,
  ) async {
    final candidates = outputFiles
        .where(_isCanvasUnifiedDiffOutputFile)
        .toList(growable: false);
    if (candidates.isEmpty) return null;
    if (candidates.length != 1) {
      throw const CanvasAiTransformException('CANVAS_AI_DIFF_FILE_AMBIGUOUS');
    }
    final output = await _diffFileReader.read(candidates.single);
    if (utf8.encode(output).length > canvasAiMaxUnifiedDiffBytes) {
      throw const CanvasAiTransformException('CANVAS_AI_DIFF_TOO_LARGE');
    }
    final diff = canvasExtractUnifiedDiff(output);
    if (diff == null) {
      throw const CanvasAiTransformException('CANVAS_AI_DIFF_FILE_INVALID');
    }
    return diff;
  }
}

CanvasAiFailureRecovery _recoveryForAgentOutcome(
  MobileAgentRunOutcome outcome,
) {
  final run = outcome.run;
  return run == null || !run.isTerminal
      ? CanvasAiFailureRecovery.retrySameRequest
      : CanvasAiFailureRecovery.regenerate;
}

Uri _parseCanvasDiffPlaybackUrl(Object? value) {
  if (value is! Map) {
    throw const FormatException('Playback response must be an object');
  }
  final rawUrl = value['url'];
  if (rawUrl is! String || rawUrl.trim().isEmpty) {
    throw const FormatException('Playback response URL missing');
  }
  final url = Uri.tryParse(rawUrl.trim());
  if (url == null ||
      !url.hasScheme ||
      !url.hasAuthority ||
      url.scheme != 'https') {
    throw const FormatException('Playback response URL invalid');
  }
  return url;
}

const _canvasUnifiedDiffMimeTypes = <String>{
  'text/x-diff',
  'text/x-patch',
  'application/x-diff',
  'application/x-patch',
};

bool _isCanvasUnifiedDiffOutputFile(AgentRunOutputFile outputFile) {
  if (outputFile.resourceId.trim().isEmpty) return false;
  final fileName = outputFile.fileName.trim().toLowerCase();
  final mimeType = outputFile.mimeType.trim().toLowerCase();
  return fileName.endsWith('.diff') ||
      fileName.endsWith('.patch') ||
      _canvasUnifiedDiffMimeTypes.contains(mimeType);
}

/// Explicit simulator-only adapter for a future AgentRun patch artifact.
///
/// It is selected only by [canvasDebugRemoteDiffEnabled], so the deterministic
/// content generator cannot become a normal runtime fallback.
final class CanvasAiDebugRemoteDiffPort implements CanvasAiTransformPort {
  CanvasAiDebugRemoteDiffPort({CanvasAiTransformPort? transformPort})
    : _transformPort =
          transformPort ??
          const CanvasAiTransformMockPort(delay: Duration(milliseconds: 180));

  final CanvasAiTransformPort _transformPort;

  @override
  Future<CanvasAiResult> transform(CanvasAiRequest request) async {
    final transformed = await _transformPort.transform(request);
    final transformedDiff = transformed.unifiedDiff;
    if (transformedDiff == null || transformedDiff.trim().isEmpty) {
      throw const CanvasAiTransformException('CANVAS_AI_DIFF_REQUIRED');
    }
    late final String transformedReplacement;
    try {
      transformedReplacement = canvasApplyUnifiedDiff(
        baseMarkdown: request.targetMarkdown,
        unifiedDiff: transformedDiff,
      );
    } on CanvasUnifiedDiffException {
      throw const CanvasAiTransformException('CANVAS_AI_DIFF_INVALID');
    }
    final replacement = request.action == CanvasAiAction.imageBrief
        ? transformedReplacement
        : _debugRemoteReviewReplacement(
            source: request.targetMarkdown,
            transformed: transformedReplacement,
          );
    final diff = canvasBuildWholePayloadUnifiedDiff(
      baseMarkdown: request.targetMarkdown,
      replacementMarkdown: replacement,
    );
    if (utf8.encode(diff).length > canvasAiMaxUnifiedDiffBytes) {
      throw const CanvasAiTransformException('CANVAS_AI_DIFF_TOO_LARGE');
    }
    final artifact = AgentRunOutputFile(
      resourceId: 'debug-canvas-diff-${request.requestId}',
      fileName: 'canvas-${request.action?.name ?? 'chat-rewrite'}.diff',
      mimeType: 'text/x-diff',
      sizeBytes: utf8.encode(diff).length,
    );
    final payload = await _CanvasAiDebugDiffFileReader(
      artifact: artifact,
      payload: diff,
    ).read(artifact);
    final unifiedDiff = canvasExtractUnifiedDiff(payload);
    if (unifiedDiff == null) {
      throw const CanvasAiTransformException('CANVAS_AI_DIFF_FILE_INVALID');
    }
    if (request.action == CanvasAiAction.imageBrief) {
      _validateCanvasImageBriefDiff(
        baseMarkdown: request.targetMarkdown,
        unifiedDiff: unifiedDiff,
      );
    }
    return CanvasAiResult(
      requestId: request.requestId,
      command: request.command,
      sourceDocumentHash: request.documentHash,
      sourceTargetHash: request.targetHash,
      generatedAt: transformed.generatedAt,
      unifiedDiff: unifiedDiff,
    );
  }
}

void _validateCanvasImageBriefDiff({
  required String baseMarkdown,
  required String unifiedDiff,
}) {
  try {
    final candidate = canvasApplyUnifiedDiff(
      baseMarkdown: baseMarkdown,
      unifiedDiff: unifiedDiff,
    );
    if (!candidate.startsWith(baseMarkdown) ||
        candidate.substring(baseMarkdown.length).trim().isEmpty) {
      throw const CanvasAiTransformException('CANVAS_AI_IMAGE_BRIEF_INVALID');
    }
  } on CanvasUnifiedDiffException {
    throw const CanvasAiTransformException('CANVAS_AI_DIFF_INVALID');
  }
}

String _canvasImageBriefReplacement(String source, String imageBrief) {
  final brief = imageBrief.trim();
  if (brief.isEmpty) return source;
  final separator = source.endsWith('\n\n')
      ? ''
      : source.endsWith('\n')
      ? '\n'
      : '\n\n';
  return '$source$separator$brief';
}

String _debugRemoteReviewReplacement({
  required String source,
  required String transformed,
}) {
  final runes = source.runes.toList(growable: false);
  if (runes.isEmpty || !transformed.contains(source)) return transformed;
  final replacedCount = runes.length < 4 ? runes.length : 4;
  final originalLead = String.fromCharCodes(runes.take(replacedCount));
  return transformed.replaceFirst(originalLead, '经过验证的表达');
}

final class _CanvasAiDebugDiffFileReader implements CanvasAiDiffFileReader {
  const _CanvasAiDebugDiffFileReader({
    required this.artifact,
    required this.payload,
  });

  final AgentRunOutputFile artifact;
  final String payload;

  @override
  Future<String> read(AgentRunOutputFile outputFile) async {
    if (outputFile.resourceId != artifact.resourceId ||
        outputFile.fileName != artifact.fileName ||
        outputFile.mimeType != artifact.mimeType ||
        outputFile.sizeBytes != artifact.sizeBytes ||
        !_isCanvasUnifiedDiffOutputFile(outputFile) ||
        utf8.encode(payload).length != outputFile.sizeBytes) {
      throw const CanvasAiTransformException('CANVAS_AI_DIFF_FILE_INVALID');
    }
    return payload;
  }
}

final class CanvasAiTransformMockPort implements CanvasAiTransformPort {
  const CanvasAiTransformMockPort({
    this.delay = const Duration(milliseconds: 720),
    this.fail = false,
    this.failureCode = 'CANVAS_AI_TRANSFORM_FAILED',
  });

  final Duration delay;
  final bool fail;
  final String failureCode;

  @override
  Future<CanvasAiResult> transform(CanvasAiRequest request) async {
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    if (fail) throw CanvasAiTransformException(failureCode);
    _validate(request);

    final command = request.command;
    final transformed = command is CanvasAiChatRewriteCommand
        ? _applyChatAdvice(request.targetMarkdown, command.instruction)
        : switch ((command as CanvasAiSkillCommand).value) {
            CanvasAiAction.socialRelationShift => _shiftRelationship(request),
            CanvasAiAction.needsDeepening => _deepenNeeds(
              request.targetMarkdown,
            ),
            CanvasAiAction.differentiationStrengthening =>
              _strengthenDifference(request.targetMarkdown),
            CanvasAiAction.openingOptimization => _optimizeOpening(request),
            CanvasAiAction.expansion => _expand(request.targetMarkdown),
            CanvasAiAction.personaInsertion => _insertPersona(request),
            CanvasAiAction.imageBrief => _buildImageBrief(
              request.targetMarkdown,
            ),
            CanvasAiAction.atomization => _atomize(request.targetMarkdown),
          };
    final replacement = request.action == CanvasAiAction.imageBrief
        ? _canvasImageBriefReplacement(request.targetMarkdown, transformed)
        : transformed;
    final candidate = request.action == CanvasAiAction.imageBrief
        ? replacement
        : replacement.trim();
    final unifiedDiff = canvasBuildWholePayloadUnifiedDiff(
      baseMarkdown: request.targetMarkdown,
      replacementMarkdown: candidate,
    );

    return CanvasAiResult(
      requestId: request.requestId,
      command: request.command,
      unifiedDiff: unifiedDiff,
      sourceDocumentHash: request.documentHash,
      sourceTargetHash: request.targetHash,
      generatedAt: DateTime.now(),
    );
  }

  void _validate(CanvasAiRequest request) {
    if (request.requestId.trim().isEmpty ||
        request.documentRevision < 0 ||
        !request.targetRange.isValidFor(request.documentMarkdown) ||
        request.targetRange.textFrom(request.documentMarkdown) !=
            request.targetMarkdown ||
        canvasTextHash(request.documentMarkdown) != request.documentHash ||
        canvasTextHash(request.targetMarkdown) != request.targetHash) {
      throw const CanvasAiTransformException('CANVAS_AI_INVALID_REQUEST');
    }
    if (request.targetMarkdown.trim().isEmpty) {
      throw const CanvasAiTransformException('CANVAS_AI_SOURCE_REQUIRED');
    }
    if (request.command is CanvasAiChatRewriteCommand) return;
    if (request.action == CanvasAiAction.openingOptimization &&
        request.openingVariant == null) {
      throw const CanvasAiTransformException(
        'CANVAS_AI_OPENING_VARIANT_REQUIRED',
      );
    }
    if (request.action == CanvasAiAction.imageBrief &&
        request.imageVariant == null) {
      throw const CanvasAiTransformException(
        'CANVAS_AI_IMAGE_VARIANT_REQUIRED',
      );
    }
    if (request.action == CanvasAiAction.socialRelationShift &&
        request.relationTarget == null) {
      throw const CanvasAiTransformException(
        'CANVAS_AI_RELATION_TARGET_REQUIRED',
      );
    }
    if (request.action == CanvasAiAction.personaInsertion &&
        (request.personaContext?.trim().isEmpty ?? true)) {
      throw const CanvasAiTransformException('CANVAS_AI_PERSONA_REQUIRED');
    }
  }

  String _shiftRelationship(CanvasAiRequest request) {
    final target = request.relationTarget!;
    final opening = switch (target) {
      CanvasRelationTarget.peer => '我们站在相近的位置，可以先交换彼此的判断',
      CanvasRelationTarget.friend => '我想像朋友一样，把这件事坦诚地分享给你',
      CanvasRelationTarget.advisor => '先从目标、限制和可验证的结果来看这件事',
      CanvasRelationTarget.mentor => '先别急着给答案，我们把关键步骤逐一拆开',
      CanvasRelationTarget.customer => '先从你真正需要解决的问题出发',
    };
    final closing = switch (target) {
      CanvasRelationTarget.peer => '如果你的观察不同，也可以从事实和结果继续讨论。',
      CanvasRelationTarget.friend => '不用立刻接受这个结论，先看看它是否符合你的真实处境。',
      CanvasRelationTarget.advisor => '下一步应先补齐缺少的信息，再选择可以验证的行动。',
      CanvasRelationTarget.mentor => '掌握判断方法比记住一个标准答案更重要。',
      CanvasRelationTarget.customer => '确认目标后，再决定哪条路径真正适合你。',
    };
    return '$opening：\n\n${request.targetMarkdown.trim()}\n\n$closing';
  }

  String _deepenNeeds(String source) => '''${source.trim()}

### 需求深化

- **表层需求**：从原文中确认当前最直接、最具体的问题。
- **深层动机**：继续追问为什么现在需要解决，以及理想变化是什么。
- **现实影响**：说明问题不处理会影响哪些过程或结果，不补写未经证实的数据。
- **完成标准**：把目标改写为可以观察、比较或验证的结果。''';

  String _strengthenDifference(String source) => '''${source.trim()}

### 差异化增强

- **独特判断**：明确这段内容与常见说法不同的核心观点。
- **方法路径**：说明观点如何转化为可复用的步骤。
- **已有依据**：只保留原文中能够支撑判断的经历、案例或结果。
- **证据缺口**：缺少证明的部分保持待补充，不虚构案例或数据。''';

  String _optimizeOpening(CanvasAiRequest request) {
    final source = request.targetMarkdown.trim();
    return switch (request.openingVariant!) {
      CanvasOpeningVariant.labeling =>
        '**给正在处理这一问题的人：先看清目标，再决定行动。**\n\n$source',
      CanvasOpeningVariant.defamiliarization =>
        '**真正拉开差距的，往往不是做得更多，而是先换一个观察角度。**\n\n$source',
    };
  }

  String _expand(String source) {
    final normalized = source.trim();
    final sourceLength = normalized.replaceAll(RegExp(r'\s+'), '').runes.length;
    final additionLength = (sourceLength * .65).round().clamp(1, sourceLength);
    const material =
        '进一步说明时，可以依次补充当下发生的情况、形成这一判断的原因，以及希望通过行动得到的变化。'
        '这样既保留原有观点，也让读者更容易从理解过渡到判断和行动；案例与数据仍以原文事实为准。';
    final buffer = StringBuffer();
    while (buffer.toString().runes.length < additionLength) {
      buffer.write(material);
    }
    final addition = String.fromCharCodes(
      buffer.toString().runes.take(additionLength),
    );
    return '$normalized\n\n$addition';
  }

  String _insertPersona(CanvasAiRequest request) =>
      '''> **表达视角**：${request.personaContext!.trim()}

${request.targetMarkdown.trim()}

表达时保持上述身份、服务对象和价值取向，并只使用已有经历与事实支撑判断。''';

  String _buildImageBrief(String source) {
    final excerpt = _compactExcerpt(source, 56);
    return '''> **配图建议**
>
> - **构图**：主体居中或三分构图，保留清晰的视觉动线和呼吸空间。
> - **主体**：围绕“$excerpt”选择一个可被直接识别的核心人物或物件。
> - **场景**：使用与正文事实一致的真实环境，避免纯氛围背景。
> - **比例**：优先 4:3；发布平台有固定规格时再适配，不在图片内叠加文字。
> - **提示词**：$excerpt，真实场景，自然光，主体清晰，细节可辨，无文字、Logo 或水印。
> - **替代文本**：表现“$excerpt”的内容配图。''';
  }

  String _atomize(String source) {
    final atoms = _extractAtoms(source);
    return '## 原子化内容\n\n${atoms.map((atom) => '- $atom').join('\n')}';
  }

  String _applyChatAdvice(String source, String instruction) =>
      '''${source.trim()}

> **根据创作建议调整**：${instruction.trim()}''';
}

String _canvasFeatureId(CanvasAiRequest request) {
  if (request.command is CanvasAiChatRewriteCommand) return 'creation.free';
  return switch (request.action!) {
    CanvasAiAction.socialRelationShift => 'canvas.relationship_shift',
    CanvasAiAction.needsDeepening => 'canvas.demand_deepening',
    CanvasAiAction.differentiationStrengthening =>
      'canvas.differentiation_strengthening',
    CanvasAiAction.openingOptimization => switch (request.openingVariant) {
      CanvasOpeningVariant.labeling => 'canvas.opening_labeling',
      CanvasOpeningVariant.defamiliarization =>
        'canvas.opening_defamiliarization',
      null => throw const CanvasAiTransformException(
        'CANVAS_AI_OPENING_VARIANT_REQUIRED',
      ),
    },
    CanvasAiAction.expansion => 'canvas.expansion',
    CanvasAiAction.personaInsertion => 'canvas.persona_insertion',
    CanvasAiAction.imageBrief => switch (request.imageVariant) {
      CanvasImageVariant.sceneDesign => 'canvas.scene_design',
      CanvasImageVariant.spokenVisuals => 'canvas.spoken_visuals',
      null => throw const CanvasAiTransformException(
        'CANVAS_AI_IMAGE_VARIANT_REQUIRED',
      ),
    },
    CanvasAiAction.atomization => 'canvas.atomic_structure',
  };
}

String _canvasVisibleInstruction(CanvasAiRequest request) {
  final command = request.command;
  final action = command is CanvasAiChatRewriteCommand
      ? '根据第三个文本输入中的创作助手建议改写，保留未要求变更的事实。'
      : switch (request.action!) {
          CanvasAiAction.socialRelationShift =>
            switch (request.relationTarget) {
              final target? => '调整表达关系，目标关系：${target.label}。',
              null => throw const CanvasAiTransformException(
                'CANVAS_AI_RELATION_TARGET_REQUIRED',
              ),
            },
          CanvasAiAction.needsDeepening => '深化用户需求。',
          CanvasAiAction.differentiationStrengthening => '增强差异化表达。',
          CanvasAiAction.openingOptimization =>
            request.openingVariant == CanvasOpeningVariant.labeling
                ? '执行开头标签化。'
                : '执行开头陌生化。',
          CanvasAiAction.expansion => '扩写，并保持已有事实不变。',
          CanvasAiAction.personaInsertion => switch (request.personaContext
              ?.trim()) {
            final context? when context.isNotEmpty =>
              '根据第三个文本输入中已锁存的人设与定位改写，不虚构补充信息。',
            _ => throw const CanvasAiTransformException(
              'CANVAS_AI_PERSONA_REQUIRED',
            ),
          },
          CanvasAiAction.imageBrief =>
            request.imageVariant == CanvasImageVariant.sceneDesign
                ? '设计影像增强成品配图。'
                : '设计口播解释性画面。',
          CanvasAiAction.atomization => '整理为原子化信息结构。',
        };
  final scope = request.editScope == CanvasAiEditScope.global
      ? '全局：处理整个基线。'
      : '局部：只能改写基线中的选中内容，不扩展范围。';
  if (request.action == CanvasAiAction.imageBrief) {
    return '$action $scope 第二个文本输入是基线，只返回可插入的 Markdown 配图建议。';
  }
  return '$action $scope 唯一基线是 canvas_baseline.v1 JSON 的 markdown 字段全部内容，'
      '即使包含多个标题/段落也不可只返回最后一节。其他文本只提供约束，不属于基线。'
      '不要计算 diff 行号。只返回一个 JSON 对象：'
      '{"schema":"canvas_edit.v1","requestId":"原样复制基线 requestId",'
      '"baseHash":"原样复制基线 baseHash","replacementMarkdown":"完整改写后的基线 Markdown"}。'
      '未修改部分逐字保留，JSON 外不加解释，不将基线 JSON 的字段名或边界当成正文。'
      '段落换行必须在 JSON 解码后成为真实换行，禁止使用 /n/n 或双重转义的换行文本。';
}

String? _canvasSupplementalText(CanvasAiRequest request) {
  final command = request.command;
  if (command is CanvasAiChatRewriteCommand) {
    return '创作助手建议（仅作修改约束，不是 diff 基线）：\n${command.instruction}';
  }
  if (request.action != CanvasAiAction.personaInsertion) return null;
  return switch (request.personaContext?.trim()) {
    final context? when context.isNotEmpty =>
      '已锁存的人设与定位（仅作修改约束，不是 diff 基线）：\n$context',
    _ => throw const CanvasAiTransformException('CANVAS_AI_PERSONA_REQUIRED'),
  };
}

String _compactExcerpt(String source, int maxRunes) {
  final normalized = source
      .replaceAll(RegExp(r'[#>*_`\[\]()]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (normalized.isEmpty) return '正文主题';
  final runes = normalized.runes.toList(growable: false);
  if (runes.length <= maxRunes) return normalized;
  return '${String.fromCharCodes(runes.take(maxRunes - 1))}…';
}

List<String> _extractAtoms(String source) {
  final atoms = <String>[];
  final seen = <String>{};
  final buffer = StringBuffer();

  void flush() {
    final value = buffer
        .toString()
        .replaceFirst(RegExp(r'^\s*(?:#{1,6}|[-+*>]|\d+[.)])\s*'), '')
        .trim();
    buffer.clear();
    if (value.isNotEmpty && seen.add(value)) atoms.add(value);
  }

  for (final rune in source.runes) {
    final character = String.fromCharCode(rune);
    if (character == '\n') {
      flush();
      continue;
    }
    buffer.write(character);
    if ('。！？!?；;'.contains(character)) flush();
  }
  flush();
  if (atoms.isEmpty) atoms.add(source.trim());
  return atoms;
}

String? _canvasStructuredReplacement(String output, CanvasAiRequest request) {
  var candidate = output.trim();
  if (candidate.startsWith('```json\n') && candidate.endsWith('\n```')) {
    candidate = candidate.substring(8, candidate.length - 4).trim();
  }
  if (!candidate.startsWith('{')) return null;
  Object? decoded;
  try {
    decoded = jsonDecode(candidate);
  } on FormatException {
    throw const CanvasAiTransformException('CANVAS_AI_RESPONSE_INVALID');
  }
  if (decoded is! Map || decoded['schema'] != 'canvas_edit.v1') {
    throw const CanvasAiTransformException('CANVAS_AI_RESPONSE_INVALID');
  }
  if (decoded['requestId'] != request.requestId ||
      decoded['baseHash'] != request.targetHash) {
    throw const CanvasAiTransformException('CANVAS_AI_RESULT_MISMATCH');
  }
  final replacement = decoded['replacementMarkdown'];
  if (replacement is! String || replacement.trim().isEmpty) {
    throw const CanvasAiTransformException('CANVAS_AI_EMPTY_RESULT');
  }
  if (canvasAiIntroducesInvalidLineBreaks(
    sourceMarkdown: request.targetMarkdown,
    candidateMarkdown: replacement,
  )) {
    throw const CanvasAiTransformException('CANVAS_AI_INVALID_LINE_BREAKS');
  }
  return replacement;
}
