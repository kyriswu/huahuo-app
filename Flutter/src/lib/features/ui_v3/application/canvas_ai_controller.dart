import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/bootstrap/app_providers.dart';
import '../../../core/database/diagnostic_log_dao.dart';
import '../../../core/diagnostics/diagnostic_logger.dart';
import '../data/canvas_ai_transform_port.dart';
import '../domain/canvas_ai_models.dart';

@immutable
final class CanvasAiControllerScope {
  const CanvasAiControllerScope({required this.owner, required this.sessionId});

  final Object owner;
  final String sessionId;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CanvasAiControllerScope &&
          identical(owner, other.owner) &&
          sessionId == other.sessionId;

  @override
  int get hashCode => Object.hash(identityHashCode(owner), sessionId);
}

final canvasAiControllerProvider = ChangeNotifierProvider.autoDispose
    .family<CanvasAiController, CanvasAiControllerScope>((ref, _) {
      return CanvasAiController(
        ref.read(canvasAiTransformPortProvider),
        diagnosticLogger: ref.read(diagnosticLoggerProvider),
      );
    });

@immutable
final class CanvasAiControllerState {
  const CanvasAiControllerState({
    this.status = CanvasAiTransformStatus.idle,
    this.request,
    this.result,
    this.errorCode,
    this.failureRecovery = CanvasAiFailureRecovery.regenerate,
  });

  final CanvasAiTransformStatus status;
  final CanvasAiRequest? request;
  final CanvasAiResult? result;
  final String? errorCode;
  final CanvasAiFailureRecovery failureRecovery;
}

final class CanvasAiController extends ChangeNotifier {
  CanvasAiController(
    this._port, {
    String? requestNamespace,
    DiagnosticLogger? diagnosticLogger,
  }) : _requestNamespace = _canvasAiRequestNamespace(requestNamespace),
       _logger = diagnosticLogger;

  final CanvasAiTransformPort _port;
  final String _requestNamespace;
  final DiagnosticLogger? _logger;

  CanvasAiControllerState _state = const CanvasAiControllerState();
  CanvasAiRequest? _retryRequest;
  String? _suppliedDiffRequestId;
  CanvasAiRequest? _unsettledCancellationRequest;
  Future<bool>? _cancellationSettlement;
  int _generationToken = 0;
  int _requestSequence = 0;
  bool _disposed = false;

  CanvasAiControllerState get state => _state;
  CanvasAiTransformStatus get status => _state.status;
  CanvasAiRequest? get request => _state.request;
  CanvasAiResult? get result => _state.result;
  String? get errorCode => _state.errorCode;
  bool get canRetry =>
      (_state.status == CanvasAiTransformStatus.failed ||
          _state.status == CanvasAiTransformStatus.awaitingCompletion) &&
      _retryRequest != null &&
      _state.failureRecovery == CanvasAiFailureRecovery.retrySameRequest;
  bool get canRegenerate =>
      (_state.status == CanvasAiTransformStatus.previewing ||
          _state.status == CanvasAiTransformStatus.failed) &&
      _state.request != null &&
      _state.errorCode != 'CANVAS_AI_SOURCE_CHANGED' &&
      _state.request?.requestId != _suppliedDiffRequestId;

  Future<bool> generate({
    required CanvasAiAction action,
    required String documentMarkdown,
    required int documentRevision,
    CanvasAiEditScope editScope = CanvasAiEditScope.global,
    int? selectionStart,
    int? selectionEnd,
    CanvasOpeningVariant? openingVariant,
    CanvasImageVariant? imageVariant,
    CanvasRelationTarget? relationTarget,
    String? personaContext,
    String? sourceNoteId,
    String? sourcePartRevisionId,
  }) => _generate(
    command: CanvasAiSkillCommand(action),
    documentMarkdown: documentMarkdown,
    documentRevision: documentRevision,
    editScope: editScope,
    selectionStart: selectionStart,
    selectionEnd: selectionEnd,
    openingVariant: openingVariant,
    imageVariant: imageVariant,
    relationTarget: relationTarget,
    personaContext: personaContext,
    sourceNoteId: sourceNoteId,
    sourcePartRevisionId: sourcePartRevisionId,
  );

  Future<bool> generateChatRewrite({
    required String instruction,
    String? unifiedDiff,
    required String documentMarkdown,
    required int documentRevision,
    CanvasAiEditScope editScope = CanvasAiEditScope.global,
    int? selectionStart,
    int? selectionEnd,
  }) async {
    CanvasAiChatRewriteCommand command;
    try {
      command = CanvasAiChatRewriteCommand(instruction);
    } on ArgumentError {
      _emit(
        const CanvasAiControllerState(
          status: CanvasAiTransformStatus.failed,
          errorCode: 'CANVAS_AI_CHAT_INSTRUCTION_INVALID',
        ),
      );
      return false;
    }
    return _generate(
      command: command,
      documentMarkdown: documentMarkdown,
      documentRevision: documentRevision,
      editScope: editScope,
      selectionStart: selectionStart,
      selectionEnd: selectionEnd,
      unifiedDiff: unifiedDiff,
    );
  }

  Future<bool> _generate({
    required CanvasAiCommand command,
    String? unifiedDiff,
    required String documentMarkdown,
    required int documentRevision,
    required CanvasAiEditScope editScope,
    int? selectionStart,
    int? selectionEnd,
    CanvasOpeningVariant? openingVariant,
    CanvasImageVariant? imageVariant,
    CanvasRelationTarget? relationTarget,
    String? personaContext,
    String? sourceNoteId,
    String? sourcePartRevisionId,
  }) async {
    _latchRemoteCleanupForCurrentState();
    _generationToken++;
    _retryRequest = null;

    final validation = _validateInput(
      command: command,
      documentMarkdown: documentMarkdown,
      documentRevision: documentRevision,
      openingVariant: openingVariant,
      imageVariant: imageVariant,
      relationTarget: relationTarget,
      personaContext: personaContext,
      sourceNoteId: sourceNoteId,
      sourcePartRevisionId: sourcePartRevisionId,
    );
    if (validation != null) {
      _emit(
        CanvasAiControllerState(
          status: CanvasAiTransformStatus.failed,
          errorCode: validation,
        ),
      );
      return false;
    }

    final target = _resolveTarget(
      editScope: editScope,
      documentMarkdown: documentMarkdown,
      selectionStart: selectionStart,
      selectionEnd: selectionEnd,
    );
    if (target == null ||
        target.range.textFrom(documentMarkdown).trim().isEmpty) {
      _emit(
        CanvasAiControllerState(
          status: CanvasAiTransformStatus.failed,
          errorCode: editScope == CanvasAiEditScope.local
              ? 'CANVAS_AI_SELECTION_REQUIRED'
              : 'CANVAS_AI_SOURCE_REQUIRED',
        ),
      );
      return false;
    }

    final targetMarkdown = target.range.textFrom(documentMarkdown);
    final request = CanvasAiRequest(
      requestId: _nextRequestId(),
      command: command,
      scope: target.scope,
      editScope: editScope,
      documentMarkdown: documentMarkdown,
      documentRevision: documentRevision,
      documentHash: canvasTextHash(documentMarkdown),
      targetRange: target.range,
      targetMarkdown: targetMarkdown,
      targetHash: canvasTextHash(targetMarkdown),
      openingVariant: openingVariant,
      imageVariant: imageVariant,
      relationTarget: relationTarget,
      personaContext: personaContext?.trim(),
      sourceNoteId: sourceNoteId?.trim(),
      sourcePartRevisionId: sourcePartRevisionId?.trim(),
    );
    if (unifiedDiff == null) return _run(request);
    _suppliedDiffRequestId = request.requestId;
    final token = _generationToken;
    final settled = await _settlePriorCancellation();
    if (_disposed || token != _generationToken) return false;
    if (!settled) {
      _emit(
        CanvasAiControllerState(
          status: CanvasAiTransformStatus.failed,
          request: request,
          errorCode: 'CANVAS_AI_CANCELLATION_UNRESOLVED',
        ),
      );
      return false;
    }
    try {
      if (unifiedDiff.length > 256000) throw const CanvasUnifiedDiffException();
      final target = request.targetMarkdown;
      final replacement = canvasApplyUnifiedDiff(
        baseMarkdown: target.trim(),
        unifiedDiff: unifiedDiff,
      );
      final leading = target.substring(
        0,
        target.length - target.trimLeft().length,
      );
      final trailing = target.substring(target.trimRight().length);
      final resolvedReplacement = '$leading$replacement$trailing';
      final candidateError = _candidateAdmissionErrorCode(
        request,
        resolvedReplacement,
      );
      if (candidateError != null) {
        _emit(
          CanvasAiControllerState(
            status: CanvasAiTransformStatus.failed,
            request: request,
            errorCode: candidateError,
          ),
        );
        return false;
      }
      final result = CanvasAiResult(
        requestId: request.requestId,
        command: request.command,
        unifiedDiff: unifiedDiff,
        sourceDocumentHash: request.documentHash,
        sourceTargetHash: request.targetHash,
        generatedAt: DateTime.now(),
      ).withResolvedReplacement(resolvedReplacement);
      _emit(
        CanvasAiControllerState(
          status: CanvasAiTransformStatus.previewing,
          request: request,
          result: result,
        ),
      );
      return true;
    } on CanvasUnifiedDiffException {
      _emit(
        CanvasAiControllerState(
          status: CanvasAiTransformStatus.failed,
          request: request,
          errorCode: 'CANVAS_AI_DIFF_INVALID',
        ),
      );
      return false;
    }
  }

  Future<bool> retry() {
    if (!canRetry) return Future<bool>.value(false);
    return _run(_retryRequest!);
  }

  Future<bool> regenerate() {
    final preview = _state.request;
    if (!canRegenerate || preview == null) return Future<bool>.value(false);
    if (_state.status == CanvasAiTransformStatus.failed &&
        _state.failureRecovery == CanvasAiFailureRecovery.retrySameRequest) {
      _latchCancellation(preview);
    }
    return _run(preview.withRequestId(_nextRequestId()));
  }

  bool isPreviewCurrent({
    required String currentMarkdown,
    required int currentRevision,
  }) {
    final request = _state.request;
    final result = _state.result;
    if (_state.status != CanvasAiTransformStatus.previewing ||
        request == null ||
        result == null) {
      return false;
    }
    return _matchesFrozenSource(
      request,
      currentMarkdown: currentMarkdown,
      currentRevision: currentRevision,
    );
  }

  void invalidatePreviewSource() => _failPreview('CANVAS_AI_SOURCE_CHANGED');

  void failPreviewRendering() => _failPreview('CANVAS_AI_PREVIEW_INVALID');

  void _failPreview(String errorCode) {
    if (_state.status != CanvasAiTransformStatus.previewing) return;
    _retryRequest = null;
    _emit(
      CanvasAiControllerState(
        status: CanvasAiTransformStatus.failed,
        request: _state.request,
        result: _state.result,
        errorCode: errorCode,
      ),
    );
  }

  CanvasAiApplication? beginApply({
    required String currentMarkdown,
    required int currentRevision,
  }) {
    final request = _state.request;
    final result = _state.result;
    if (_state.status != CanvasAiTransformStatus.previewing ||
        request == null ||
        result == null) {
      return null;
    }
    if (!_matchesFrozenSource(
      request,
      currentMarkdown: currentMarkdown,
      currentRevision: currentRevision,
    )) {
      _retryRequest = null;
      _emit(
        CanvasAiControllerState(
          status: CanvasAiTransformStatus.failed,
          request: request,
          result: result,
          errorCode: 'CANVAS_AI_SOURCE_CHANGED',
        ),
      );
      return null;
    }

    final range = request.targetRange;
    final updatedMarkdown = currentMarkdown.replaceRange(
      range.start,
      range.end,
      result.replacementMarkdown,
    );
    _emit(
      CanvasAiControllerState(
        status: CanvasAiTransformStatus.applying,
        request: request,
        result: result,
      ),
    );
    return CanvasAiApplication(
      requestId: request.requestId,
      updatedMarkdown: updatedMarkdown,
      replacedRange: range,
      replacementMarkdown: result.replacementMarkdown,
      sourceRevision: request.documentRevision,
      sourceDocumentHash: request.documentHash,
    );
  }

  void completeApply({bool succeeded = true}) {
    if (_state.status != CanvasAiTransformStatus.applying) return;
    _retryRequest = null;
    _emit(
      succeeded
          ? const CanvasAiControllerState()
          : CanvasAiControllerState(
              status: CanvasAiTransformStatus.failed,
              request: _state.request,
              result: _state.result,
              errorCode: 'CANVAS_AI_APPLY_FAILED',
            ),
    );
  }

  void cancel() {
    if (_state.status == CanvasAiTransformStatus.idle ||
        _state.status == CanvasAiTransformStatus.cancelled) {
      return;
    }
    final runningRequest =
        _state.status == CanvasAiTransformStatus.running ||
            _state.status == CanvasAiTransformStatus.awaitingCompletion ||
            (_state.status == CanvasAiTransformStatus.failed &&
                _state.failureRecovery ==
                    CanvasAiFailureRecovery.retrySameRequest)
        ? _state.request
        : null;
    _latchCancellation(runningRequest);
    _generationToken++;
    _retryRequest = null;
    _emit(
      CanvasAiControllerState(
        status: CanvasAiTransformStatus.cancelled,
        request: _state.request,
      ),
    );
  }

  void reset() {
    _latchRemoteCleanupForCurrentState();
    _generationToken++;
    _retryRequest = null;
    _emit(const CanvasAiControllerState());
  }

  Future<bool> _run(CanvasAiRequest request) {
    final token = ++_generationToken;
    if (_unsettledCancellationRequest == null) {
      return _runTransform(request, token);
    }
    return _settleAndRun(request, token);
  }

  Future<bool> _settleAndRun(CanvasAiRequest request, int token) async {
    if (!await _settlePriorCancellation()) {
      if (token == _generationToken && !_disposed) {
        _retryRequest = null;
        _emit(
          CanvasAiControllerState(
            status: CanvasAiTransformStatus.failed,
            request: request,
            errorCode: 'CANVAS_AI_CANCELLATION_UNRESOLVED',
          ),
        );
      }
      return false;
    }
    if (token != _generationToken || _disposed) return false;
    return _runTransform(request, token);
  }

  Future<bool> _runTransform(CanvasAiRequest request, int token) async {
    _retryRequest = request;
    _emit(
      CanvasAiControllerState(
        status: CanvasAiTransformStatus.running,
        request: request,
      ),
    );
    try {
      final rawResult = await _port.transform(request);
      if (token != _generationToken || _disposed) return false;
      final mismatchCode = _resultMismatchCode(request, rawResult);
      if (mismatchCode != null) {
        _emit(
          CanvasAiControllerState(
            status: CanvasAiTransformStatus.failed,
            request: request,
            errorCode: mismatchCode,
          ),
        );
        return false;
      }
      final result = _resolveResult(request, rawResult);
      _emit(
        CanvasAiControllerState(
          status: CanvasAiTransformStatus.previewing,
          request: request,
          result: result,
        ),
      );
      return true;
    } on CanvasUnifiedDiffException {
      if (token != _generationToken || _disposed) return false;
      _emit(
        CanvasAiControllerState(
          status: CanvasAiTransformStatus.failed,
          request: request,
          errorCode: 'CANVAS_AI_DIFF_INVALID',
        ),
      );
      return false;
    } on CanvasAiTransformException catch (error) {
      if (token != _generationToken || _disposed) return false;
      _emit(
        CanvasAiControllerState(
          status: error.isAwaitingCompletion
              ? CanvasAiTransformStatus.awaitingCompletion
              : CanvasAiTransformStatus.failed,
          request: request,
          errorCode: error.code,
          failureRecovery: error.recovery,
        ),
      );
      return false;
    } catch (_) {
      if (token != _generationToken || _disposed) return false;
      _emit(
        CanvasAiControllerState(
          status: CanvasAiTransformStatus.failed,
          request: request,
          errorCode: 'CANVAS_AI_TRANSFORM_FAILED',
        ),
      );
      return false;
    }
  }

  bool _matchesFrozenSource(
    CanvasAiRequest request, {
    required String currentMarkdown,
    required int currentRevision,
  }) {
    if (request.documentRevision != currentRevision ||
        request.documentHash != canvasTextHash(currentMarkdown) ||
        !request.targetRange.isValidFor(currentMarkdown)) {
      return false;
    }
    return canvasTextHash(request.targetRange.textFrom(currentMarkdown)) ==
        request.targetHash;
  }

  String? _resultMismatchCode(CanvasAiRequest request, CanvasAiResult result) {
    if (result.requestId != request.requestId ||
        result.command != request.command ||
        result.sourceDocumentHash != request.documentHash ||
        result.sourceTargetHash != request.targetHash) {
      return 'CANVAS_AI_RESULT_MISMATCH';
    }
    if (!result.hasUnifiedDiff) return 'CANVAS_AI_DIFF_REQUIRED';
    return null;
  }

  CanvasAiResult _resolveResult(
    CanvasAiRequest request,
    CanvasAiResult result,
  ) {
    final diff = result.unifiedDiff!;
    final candidate = canvasApplyUnifiedDiff(
      baseMarkdown: request.targetMarkdown,
      unifiedDiff: diff,
    );
    final candidateError = _candidateAdmissionErrorCode(request, candidate);
    if (candidateError != null) {
      throw CanvasAiTransformException(candidateError);
    }
    return result.withResolvedReplacement(candidate);
  }

  String? _candidateAdmissionErrorCode(
    CanvasAiRequest request,
    String candidate,
  ) {
    if (canvasAiIntroducesInvalidLineBreaks(
      sourceMarkdown: request.targetMarkdown,
      candidateMarkdown: candidate,
    )) {
      return 'CANVAS_AI_INVALID_LINE_BREAKS';
    }
    if (request.action == CanvasAiAction.imageBrief) {
      if (!candidate.startsWith(request.targetMarkdown) ||
          candidate.substring(request.targetMarkdown.length).trim().isEmpty) {
        return 'CANVAS_AI_IMAGE_BRIEF_INVALID';
      }
      return null;
    }
    if (candidate.trim().isEmpty) return 'CANVAS_AI_EMPTY_RESULT';
    final normalizedCandidate = candidate.replaceAll('\r\n', '\n');
    final normalizedTarget = request.targetMarkdown.replaceAll('\r\n', '\n');
    if (normalizedCandidate == normalizedTarget) {
      return 'CANVAS_AI_NO_CHANGES';
    }
    return null;
  }

  String? _validateInput({
    required CanvasAiCommand command,
    required String documentMarkdown,
    required int documentRevision,
    required CanvasOpeningVariant? openingVariant,
    required CanvasImageVariant? imageVariant,
    required CanvasRelationTarget? relationTarget,
    required String? personaContext,
    required String? sourceNoteId,
    required String? sourcePartRevisionId,
  }) {
    if (documentRevision < 0) return 'CANVAS_AI_INVALID_REVISION';
    if (documentMarkdown.trim().isEmpty) return 'CANVAS_AI_SOURCE_REQUIRED';
    final action = command.action;
    if (command is CanvasAiChatRewriteCommand) {
      if (openingVariant != null ||
          imageVariant != null ||
          relationTarget != null ||
          personaContext != null ||
          sourceNoteId != null ||
          sourcePartRevisionId != null) {
        return 'CANVAS_AI_CHAT_REQUEST_INVALID';
      }
      return null;
    }
    if (command is! CanvasAiSkillCommand || action == null) {
      return 'CANVAS_AI_COMMAND_INVALID';
    }
    if (action == CanvasAiAction.openingOptimization &&
        openingVariant == null) {
      return 'CANVAS_AI_OPENING_VARIANT_REQUIRED';
    }
    if (action == CanvasAiAction.imageBrief && imageVariant == null) {
      return 'CANVAS_AI_IMAGE_VARIANT_REQUIRED';
    }
    if (action == CanvasAiAction.socialRelationShift &&
        relationTarget == null) {
      return 'CANVAS_AI_RELATION_TARGET_REQUIRED';
    }
    if (action == CanvasAiAction.personaInsertion &&
        (personaContext?.trim().isEmpty ?? true)) {
      return 'CANVAS_AI_PERSONA_REQUIRED';
    }
    if ((sourceNoteId == null) != (sourcePartRevisionId == null) ||
        sourceNoteId?.trim().isEmpty == true ||
        sourcePartRevisionId?.trim().isEmpty == true) {
      return 'CANVAS_AI_HNOTE_REVISION_INVALID';
    }
    return null;
  }

  _CanvasTarget? _resolveTarget({
    required CanvasAiEditScope editScope,
    required String documentMarkdown,
    required int? selectionStart,
    required int? selectionEnd,
  }) {
    if (editScope == CanvasAiEditScope.local &&
        selectionStart != null &&
        selectionEnd != null) {
      final start = selectionStart < selectionEnd
          ? selectionStart
          : selectionEnd;
      final end = selectionStart < selectionEnd ? selectionEnd : selectionStart;
      final selection = CanvasTextRange(start: start, end: end);
      if (!selection.isCollapsed && selection.isValidFor(documentMarkdown)) {
        return _CanvasTarget(
          scope: CanvasTransformScope.selection,
          range: selection,
        );
      }
    }
    if (editScope == CanvasAiEditScope.local) return null;
    return _CanvasTarget(
      scope: CanvasTransformScope.document,
      range: CanvasTextRange(start: 0, end: documentMarkdown.length),
    );
  }

  String _nextRequestId() =>
      'canvas-ai-$_requestNamespace-${++_requestSequence}';

  void _emit(CanvasAiControllerState state) {
    if (_disposed) return;
    _recordStateTransition(state);
    _state = state;
    notifyListeners();
  }

  void _recordStateTransition(CanvasAiControllerState state) {
    try {
      _logger?.log(
        DiagnosticLogInput(
          category: DiagnosticCategory.workAi,
          severity: state.errorCode == null
              ? DiagnosticSeverity.info
              : DiagnosticSeverity.warning,
          correlationId: state.request?.requestId ?? _state.request?.requestId,
          safeSummary: 'Canvas AI editor transaction state changed',
          flushImmediately: state.errorCode != null,
          metadata: {
            'phase': state.status.name,
            'operation_id':
                state.request?.requestId ?? _state.request?.requestId,
            'action': state.request?.action?.name,
            'error_code': state.errorCode,
            'target_hash': state.request?.targetHash,
            'target_start': state.request?.targetRange.start,
            'target_end': state.request?.targetRange.end,
            'document_revision': state.request?.documentRevision,
          },
        ),
      );
    } on Object {
      return;
    }
  }

  void _latchRemoteCleanupForCurrentState() {
    final shouldClean =
        _state.status == CanvasAiTransformStatus.running ||
        _state.status == CanvasAiTransformStatus.awaitingCompletion ||
        (_state.status == CanvasAiTransformStatus.failed &&
            _state.failureRecovery == CanvasAiFailureRecovery.retrySameRequest);
    if (shouldClean) _latchCancellation(_state.request);
  }

  void _latchCancellation(CanvasAiRequest? request) {
    if (request == null) return;
    final pending = _unsettledCancellationRequest;
    if (pending != null && pending.requestId != request.requestId) return;
    _unsettledCancellationRequest = request;
    _startCancellationSettlement();
  }

  void _startCancellationSettlement() {
    if (_cancellationSettlement != null ||
        _unsettledCancellationRequest == null) {
      return;
    }
    final request = _unsettledCancellationRequest!;
    final future = _cancelTransform(request);
    _cancellationSettlement = future;
    unawaited(
      future.then((settled) {
        if (!identical(_cancellationSettlement, future)) return;
        _cancellationSettlement = null;
        if (settled &&
            _unsettledCancellationRequest?.requestId == request.requestId) {
          _unsettledCancellationRequest = null;
        }
      }),
    );
  }

  Future<bool> _settlePriorCancellation() async {
    while (_unsettledCancellationRequest != null) {
      _startCancellationSettlement();
      final future = _cancellationSettlement;
      if (future == null) return false;
      final settled = await future;
      if (!settled) return false;
    }
    return true;
  }

  Future<bool> _cancelTransform(CanvasAiRequest request) async {
    final port = _port;
    if (port is! CanvasAiTransformCancellationPort) return true;
    final cancellationPort = port as CanvasAiTransformCancellationPort;
    try {
      return await cancellationPort.cancelTransform(request.requestId);
    } on Object {
      return false;
    }
  }

  @override
  void dispose() {
    _latchRemoteCleanupForCurrentState();
    _disposed = true;
    _generationToken++;
    super.dispose();
  }
}

int _canvasAiNamespaceSequence = 0;

String _canvasAiRequestNamespace(String? requested) {
  final normalized = requested?.trim();
  if (normalized != null &&
      RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,79}$').hasMatch(normalized)) {
    return normalized;
  }
  if (normalized?.isNotEmpty == true) {
    throw ArgumentError.value(requested, 'requestNamespace');
  }
  final random = Random.secure();
  final entropy = List<String>.generate(
    8,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    growable: false,
  ).join();
  final timestamp = DateTime.now().toUtc().microsecondsSinceEpoch.toRadixString(
    36,
  );
  final sequence = (++_canvasAiNamespaceSequence).toRadixString(36);
  return '$timestamp-$sequence-$entropy';
}

@immutable
final class _CanvasTarget {
  const _CanvasTarget({required this.scope, required this.range});

  final CanvasTransformScope scope;
  final CanvasTextRange range;
}
