import 'package:huahuo_api/huahuo_api.dart';

const _noteFileAgentTerminalStatuses = <String>{
  'succeeded',
  'failed',
  'timeout',
  'conflict',
  'cancelled',
};

enum NoteFileAgentPart { raw, outline, germination }

extension NoteFileAgentPartX on NoteFileAgentPart {
  String get wireName => name;
}

final class NoteFileAgentSelector {
  const NoteFileAgentSelector({
    required this.agentProfileId,
    required this.skillProfileIds,
  });

  final String agentProfileId;
  final List<String> skillProfileIds;

  bool matches(NoteFileAgentSelector other) =>
      agentProfileId == other.agentProfileId &&
      _sameStrings(skillProfileIds, other.skillProfileIds);
}

final class NoteFileAgentRequest {
  const NoteFileAgentRequest({
    required this.noteId,
    required this.inputPart,
    required this.inputPartRevisionId,
    required this.targetPart,
    required this.targetPartRevisionId,
    required this.instruction,
    required this.selector,
    required this.idempotencyKey,
    this.modelProfileId,
  });

  final String noteId;
  final NoteFileAgentPart inputPart;
  final String inputPartRevisionId;
  final NoteFileAgentPart targetPart;
  final String targetPartRevisionId;
  final String instruction;
  final NoteFileAgentSelector selector;
  final String idempotencyKey;
  final String? modelProfileId;
}

final class NoteFileAgentResult {
  const NoteFileAgentResult({
    required this.noteId,
    required this.fileAgentRunId,
    required this.agentRunId,
    required this.inputPart,
    required this.inputPartRevisionId,
    required this.targetPart,
    required this.targetPartRevisionId,
    required this.outputPartRevisionId,
    required this.markdown,
    required this.selector,
  });

  final String noteId;
  final String fileAgentRunId;
  final String agentRunId;
  final NoteFileAgentPart inputPart;
  final String inputPartRevisionId;
  final NoteFileAgentPart targetPart;
  final String targetPartRevisionId;
  final String outputPartRevisionId;
  final String markdown;
  final NoteFileAgentSelector selector;
}

/// Safe public File-Agent lifecycle projection used by foreground task
/// tracking. Selector details and output Markdown deliberately stay out of
/// this object so it can be persisted without carrying routing internals.
final class NoteFileAgentRunSnapshot {
  const NoteFileAgentRunSnapshot({
    required this.fileAgentRunId,
    required this.noteId,
    required this.status,
    required this.agentRunId,
    required this.inputPart,
    required this.inputPartRevisionId,
    required this.targetPart,
    required this.targetPartRevisionId,
    this.outputPartRevisionId,
    this.failureCode,
  });

  final String fileAgentRunId;
  final String noteId;
  final String status;
  final String agentRunId;
  final NoteFileAgentPart inputPart;
  final String inputPartRevisionId;
  final NoteFileAgentPart targetPart;
  final String targetPartRevisionId;
  final String? outputPartRevisionId;
  final String? failureCode;

  bool get isTerminal => _noteFileAgentTerminalStatuses.contains(status);
  bool get isSuccessful => status == 'succeeded';
}

/// Safe lifecycle state for an already-admitted File-Agent run. This excludes
/// selectors and generated Markdown while retaining the public output revision
/// needed to verify durable Part projection.
final class NoteFileAgentRunStatus {
  const NoteFileAgentRunStatus({
    required this.fileAgentRunId,
    required this.noteId,
    required this.status,
    this.agentRunId,
    this.targetPart,
    this.outputPartRevisionId,
    this.failureCode,
  });

  factory NoteFileAgentRunStatus.fromValue(Object? value) {
    final data = asObjectMap(value);
    final run = data == null ? null : asObjectMap(data['fileAgentRun']) ?? data;
    if (run == null) throw const FormatException('file agent run missing');
    final target = asObjectMap(run['target']);
    if (run['target'] != null && target == null) {
      throw const FormatException('file agent run target invalid');
    }
    final directTarget = _optionalPart(run['targetPart']);
    final nestedTarget = target == null ? null : _optionalPart(target['part']);
    if (directTarget != null &&
        nestedTarget != null &&
        directTarget != nestedTarget) {
      throw const FormatException('file agent run target mismatch');
    }
    return NoteFileAgentRunStatus(
      fileAgentRunId: _requiredId(
        run['fileAgentRunId'],
        'fileAgentRunId missing',
      ),
      noteId: _requiredId(run['noteId'], 'noteId missing'),
      status: _status(run['status']),
      agentRunId: _optionalPublicIdentifier(
        run['agentRunId'],
        'agentRunId invalid',
      ),
      targetPart: nestedTarget ?? directTarget,
      outputPartRevisionId: _optionalPublicIdentifier(
        run['outputPartRevisionId'],
        'outputPartRevisionId invalid',
      ),
      failureCode: _publicFailureCode(run),
    );
  }

  final String fileAgentRunId;
  final String noteId;
  final String status;
  final String? agentRunId;
  final NoteFileAgentPart? targetPart;
  final String? outputPartRevisionId;
  final String? failureCode;

  bool get isTerminal => _noteFileAgentTerminalStatuses.contains(status);
  bool get isSuccessful => status == 'succeeded';
}

abstract interface class NoteFileAgentRunStatusPort {
  Future<NoteFileAgentRunStatus> getRun({
    required String noteId,
    required String fileAgentRunId,
  });
}

enum NoteFileAgentAdmissionFailureDisposition {
  none,
  replaySameKey,
  retryWithFreshKey,
}

final class NoteFileAgentException implements Exception {
  const NoteFileAgentException(
    this.code, {
    this.isRetryable = false,
    this.admissionDisposition = NoteFileAgentAdmissionFailureDisposition.none,
    this.isFailedIdempotencyReceipt = false,
  });

  final String code;
  final bool isRetryable;
  final NoteFileAgentAdmissionFailureDisposition admissionDisposition;
  final bool isFailedIdempotencyReceipt;

  @override
  String toString() => 'NoteFileAgentException($code)';
}

/// Typed adapter for the deployed Workspace Note File-Agent contract.
///
/// The backend remains the sole writer. Client success requires both the run
/// completion projection and a current non-empty target-part readback.
final class NoteFileAgentClient implements NoteFileAgentRunStatusPort {
  NoteFileAgentClient({
    required ApiClient apiClient,
    required String? Function() workspaceId,
    this.pollInterval = const Duration(seconds: 3),
    this.maxPollAttempts = 200,
    Future<void> Function(Duration)? delay,
  }) : _apiClient = apiClient,
       _workspaceId = workspaceId,
       _delay = delay ?? _defaultDelay;

  final ApiClient _apiClient;
  final String? Function() _workspaceId;
  final Future<void> Function(Duration) _delay;
  final Duration pollInterval;
  final int maxPollAttempts;

  /// Admits a strict File-Agent operation without waiting for model execution.
  /// The returned snapshot is safe to persist in a foreground tracker.
  Future<NoteFileAgentRunSnapshot> submit(
    NoteFileAgentRequest request, {
    void Function()? onDispatch,
  }) async {
    final submitted = await _submit(request, onDispatch: onDispatch);
    return _snapshotFor(submitted.initial);
  }

  /// Replays an already validated immutable admission request. This deliberately
  /// skips the mutable Note-head preflight so the backend idempotency registry
  /// can return a Run accepted by an earlier request whose response was lost.
  Future<NoteFileAgentRunSnapshot> replaySubmit(
    NoteFileAgentRequest request, {
    void Function()? onDispatch,
  }) async {
    final workspaceId = _requiredId(
      _workspaceId(),
      'NOTE_FILE_AGENT_WORKSPACE_REQUIRED',
    );
    _validateRequest(request);
    final initial = await _createRun(
      workspaceId: workspaceId,
      request: request,
      onDispatch: onDispatch,
    );
    return _snapshotFor(initial);
  }

  /// Reads a public File-Agent lifecycle projection for a previously admitted
  /// run. Completion content is still verified by [run] or by the owning HNote
  /// detail readback after a successful terminal state.
  @override
  Future<NoteFileAgentRunStatus> getRun({
    required String noteId,
    required String fileAgentRunId,
  }) async {
    final workspaceId = _requiredId(
      _workspaceId(),
      'NOTE_FILE_AGENT_WORKSPACE_REQUIRED',
    );
    final normalizedNoteId = _requiredId(
      noteId,
      'NOTE_FILE_AGENT_NOTE_REQUIRED',
    );
    final normalizedRunId = _requiredId(
      fileAgentRunId,
      'NOTE_FILE_AGENT_RUN_REQUIRED',
    );
    final run = await _readPublicRun(
      workspaceId: workspaceId,
      noteId: normalizedNoteId,
      fileAgentRunId: normalizedRunId,
    );
    if (run.noteId != normalizedNoteId ||
        run.fileAgentRunId != normalizedRunId) {
      throw const NoteFileAgentException('NOTE_FILE_AGENT_RUN_MISMATCH');
    }
    return run;
  }

  Future<NoteFileAgentResult> run(NoteFileAgentRequest request) async {
    final submitted = await _submit(request);
    final workspaceId = submitted.workspaceId;
    final before = submitted.before;
    final initial = submitted.initial;
    final terminal = await _waitForTerminal(
      workspaceId: workspaceId,
      noteId: request.noteId,
      initial: initial,
    );
    _ensureRunMatchesRequest(terminal, request);
    if (terminal.status != 'succeeded') {
      throw NoteFileAgentException(
        terminal.failureCode ??
            'NOTE_FILE_AGENT_${terminal.status.toUpperCase()}',
      );
    }
    final outputRevisionId = _nonEmpty(terminal.outputPartRevisionId);
    if (outputRevisionId == null ||
        outputRevisionId == request.targetPartRevisionId) {
      throw const NoteFileAgentException(
        'NOTE_FILE_AGENT_OUTPUT_REVISION_INVALID',
      );
    }

    final after = await readNoteHead(
      workspaceId: workspaceId,
      noteId: request.noteId,
    );
    if (after.revisionFor(request.targetPart) != outputRevisionId) {
      throw const NoteFileAgentException(
        'NOTE_FILE_AGENT_OUTPUT_REVISION_STALE',
      );
    }
    if (request.targetPart != NoteFileAgentPart.outline &&
        after.outlinePartRevisionId != before.outlinePartRevisionId) {
      throw const NoteFileAgentException('NOTE_FILE_AGENT_OUTLINE_CHANGED');
    }
    final output = await readPart(
      workspaceId: workspaceId,
      noteId: request.noteId,
      part: request.targetPart,
    );
    if (output.partRevisionId != outputRevisionId ||
        output.markdown.trim().isEmpty) {
      throw const NoteFileAgentException('NOTE_FILE_AGENT_OUTPUT_EMPTY');
    }
    return NoteFileAgentResult(
      noteId: request.noteId,
      fileAgentRunId: terminal.fileAgentRunId,
      agentRunId: terminal.agentRunId,
      inputPart: request.inputPart,
      inputPartRevisionId: request.inputPartRevisionId,
      targetPart: request.targetPart,
      targetPartRevisionId: request.targetPartRevisionId,
      outputPartRevisionId: outputRevisionId,
      markdown: output.markdown,
      selector: terminal.selector,
    );
  }

  Future<_SubmittedNoteFileAgentRun> _submit(
    NoteFileAgentRequest request, {
    void Function()? onDispatch,
  }) async {
    final workspaceId = _requiredId(
      _workspaceId(),
      'NOTE_FILE_AGENT_WORKSPACE_REQUIRED',
    );
    _validateRequest(request);

    final before = await readNoteHead(
      workspaceId: workspaceId,
      noteId: request.noteId,
    );
    if (before.revisionFor(request.inputPart) != request.inputPartRevisionId ||
        before.revisionFor(request.targetPart) !=
            request.targetPartRevisionId) {
      throw const NoteFileAgentException(
        'NOTE_FILE_AGENT_SOURCE_REVISION_CHANGED',
      );
    }

    final initial = await _createRun(
      workspaceId: workspaceId,
      request: request,
      onDispatch: onDispatch,
    );
    return _SubmittedNoteFileAgentRun(
      workspaceId: workspaceId,
      before: before,
      initial: initial,
    );
  }

  Future<_NoteFileAgentRun> _createRun({
    required String workspaceId,
    required NoteFileAgentRequest request,
    void Function()? onDispatch,
  }) async {
    onDispatch?.call();
    final created = await _apiClient.request<Map<String, Object?>>(
      ApiRequestOptions<Map<String, Object?>>(
        endpointId: 'createWorkspaceNoteFileAgentRun',
        pathParams: <String, Object>{
          'workspaceId': workspaceId,
          'noteId': request.noteId,
        },
        body: <String, Object?>{
          'input': <String, Object?>{
            'part': request.inputPart.wireName,
            'partRevisionId': request.inputPartRevisionId,
          },
          'target': <String, Object?>{
            'part': request.targetPart.wireName,
            'partRevisionId': request.targetPartRevisionId,
          },
          'instruction': request.instruction,
          'agentProfileId': request.selector.agentProfileId,
          'skillProfileIds': request.selector.skillProfileIds,
          if (_nonEmpty(request.modelProfileId) != null)
            'modelProfileId': request.modelProfileId!.trim(),
        },
        idempotency: IdempotencyRequestContext(
          explicitKey: request.idempotencyKey,
        ),
        parseData: asObjectMap,
      ),
    );
    final payload = created.data;
    if (!created.ok || payload == null) {
      final code = created.error?.code ?? 'NOTE_FILE_AGENT_CREATE_FAILED';
      final responseUncertain =
          created.status == null ||
          created.status! >= 500 ||
          code == 'API_RESPONSE_INVALID';
      final retryable =
          responseUncertain || (created.error?.isRetryable ?? false);
      final isFailedIdempotencyReceipt =
          created.status == 409 &&
          created.error?.message.trim() == 'previous idempotent request failed';
      throw NoteFileAgentException(
        code == 'API_RESPONSE_INVALID'
            ? 'NOTE_FILE_AGENT_CREATE_RESPONSE_UNCERTAIN'
            : code,
        isRetryable: retryable,
        admissionDisposition: responseUncertain
            ? NoteFileAgentAdmissionFailureDisposition.replaySameKey
            : code == 'WORKSPACE_NOT_READY'
            ? NoteFileAgentAdmissionFailureDisposition.replaySameKey
            : retryable
            ? NoteFileAgentAdmissionFailureDisposition.retryWithFreshKey
            : NoteFileAgentAdmissionFailureDisposition.none,
        isFailedIdempotencyReceipt: isFailedIdempotencyReceipt,
      );
    }
    if (_isGenericAdmissionProcessing(payload)) {
      throw const NoteFileAgentException(
        'NOTE_FILE_AGENT_ADMISSION_PENDING',
        isRetryable: true,
        admissionDisposition:
            NoteFileAgentAdmissionFailureDisposition.replaySameKey,
      );
    }
    late final _NoteFileAgentRun initial;
    try {
      initial = _NoteFileAgentRun.fromValue(payload);
    } on Object {
      throw const NoteFileAgentException(
        'NOTE_FILE_AGENT_CREATE_RESPONSE_UNCERTAIN',
        isRetryable: true,
        admissionDisposition:
            NoteFileAgentAdmissionFailureDisposition.replaySameKey,
      );
    }
    _ensureRunMatchesRequest(initial, request);
    return initial;
  }

  Future<NoteFileAgentNoteHead> readCurrentNote(String noteId) async {
    final workspaceId = _requiredId(
      _workspaceId(),
      'NOTE_FILE_AGENT_WORKSPACE_REQUIRED',
    );
    return readNoteHead(workspaceId: workspaceId, noteId: noteId);
  }

  Future<NoteFileAgentPartContent> readCurrentPart(
    String noteId,
    NoteFileAgentPart part,
  ) async {
    final workspaceId = _requiredId(
      _workspaceId(),
      'NOTE_FILE_AGENT_WORKSPACE_REQUIRED',
    );
    return readPart(workspaceId: workspaceId, noteId: noteId, part: part);
  }

  Future<NoteFileAgentNoteHead> readNoteHead({
    required String workspaceId,
    required String noteId,
  }) async {
    final result = await _apiClient.request<NoteFileAgentNoteHead>(
      ApiRequestOptions<NoteFileAgentNoteHead>(
        endpointId: 'workspaceNoteDetail',
        pathParams: <String, Object>{
          'workspaceId': workspaceId,
          'noteId': noteId,
        },
        parseData: NoteFileAgentNoteHead.fromValue,
      ),
    );
    if (!result.ok || result.data == null) {
      throw NoteFileAgentException(
        result.error?.code ?? 'NOTE_FILE_AGENT_NOTE_READ_FAILED',
        isRetryable: result.error?.isRetryable ?? false,
      );
    }
    return result.data!;
  }

  Future<NoteFileAgentPartContent> readPart({
    required String workspaceId,
    required String noteId,
    required NoteFileAgentPart part,
  }) async {
    final result = await _apiClient.request<NoteFileAgentPartContent>(
      ApiRequestOptions<NoteFileAgentPartContent>(
        endpointId: 'workspaceNotePart',
        pathParams: <String, Object>{
          'workspaceId': workspaceId,
          'noteId': noteId,
          'part': part.wireName,
        },
        parseData: NoteFileAgentPartContent.fromValue,
      ),
    );
    if (!result.ok || result.data == null) {
      throw NoteFileAgentException(
        result.error?.code ?? 'NOTE_FILE_AGENT_PART_READ_FAILED',
        isRetryable: result.error?.isRetryable ?? false,
      );
    }
    final content = result.data!;
    if (content.noteId != noteId || content.part != part) {
      throw const NoteFileAgentException(
        'NOTE_FILE_AGENT_PART_RESPONSE_INVALID',
      );
    }
    return content;
  }

  Future<_NoteFileAgentRun> _waitForTerminal({
    required String workspaceId,
    required String noteId,
    required _NoteFileAgentRun initial,
  }) async {
    var current = initial;
    for (var attempt = 0; attempt < maxPollAttempts; attempt += 1) {
      if (_noteFileAgentTerminalStatuses.contains(current.status)) {
        return current;
      }
      if (attempt + 1 >= maxPollAttempts) break;
      await _delay(pollInterval);
      current = await _readRun(
        workspaceId: workspaceId,
        noteId: noteId,
        fileAgentRunId: current.fileAgentRunId,
      );
      if (current.fileAgentRunId != initial.fileAgentRunId) {
        throw const NoteFileAgentException('NOTE_FILE_AGENT_RUN_MISMATCH');
      }
    }
    throw const NoteFileAgentException('NOTE_FILE_AGENT_POLL_TIMEOUT');
  }

  Future<_NoteFileAgentRun> _readRun({
    required String workspaceId,
    required String noteId,
    required String fileAgentRunId,
  }) async {
    final result = await _apiClient.request<_NoteFileAgentRun>(
      ApiRequestOptions<_NoteFileAgentRun>(
        endpointId: 'workspaceNoteFileAgentRun',
        pathParams: <String, Object>{
          'workspaceId': workspaceId,
          'noteId': noteId,
          'fileAgentRunId': fileAgentRunId,
        },
        parseData: _NoteFileAgentRun.fromValue,
      ),
    );
    if (!result.ok || result.data == null) {
      throw NoteFileAgentException(
        result.error?.code ?? 'NOTE_FILE_AGENT_POLL_FAILED',
        isRetryable: result.error?.isRetryable ?? false,
      );
    }
    return result.data!;
  }

  Future<NoteFileAgentRunStatus> _readPublicRun({
    required String workspaceId,
    required String noteId,
    required String fileAgentRunId,
  }) async {
    final result = await _apiClient.request<NoteFileAgentRunStatus>(
      ApiRequestOptions<NoteFileAgentRunStatus>(
        endpointId: 'workspaceNoteFileAgentRun',
        pathParams: <String, Object>{
          'workspaceId': workspaceId,
          'noteId': noteId,
          'fileAgentRunId': fileAgentRunId,
        },
        parseData: NoteFileAgentRunStatus.fromValue,
      ),
    );
    if (!result.ok || result.data == null) {
      throw NoteFileAgentException(
        result.error?.code ?? 'NOTE_FILE_AGENT_POLL_FAILED',
        isRetryable: result.error?.isRetryable ?? false,
      );
    }
    return result.data!;
  }
}

final class _SubmittedNoteFileAgentRun {
  const _SubmittedNoteFileAgentRun({
    required this.workspaceId,
    required this.before,
    required this.initial,
  });

  final String workspaceId;
  final NoteFileAgentNoteHead before;
  final _NoteFileAgentRun initial;
}

final class NoteFileAgentNoteHead {
  const NoteFileAgentNoteHead({
    required this.noteId,
    required this.rawPartRevisionId,
    required this.outlinePartRevisionId,
    required this.germinationPartRevisionId,
    this.sourceKind,
  });

  factory NoteFileAgentNoteHead.fromValue(Object? value) {
    final data = asObjectMap(value);
    final note = data == null ? null : asObjectMap(data['note']) ?? data;
    if (note == null) throw const FormatException('note missing');
    final noteId = _requiredId(note['noteId'], 'noteId missing');
    final directRaw = _nonEmpty(note['rawPartRevisionId']);
    final directOutline = _nonEmpty(note['outlinePartRevisionId']);
    final directGermination = _nonEmpty(note['germinationPartRevisionId']);
    final parts = asObjectMap(note['parts']);
    final raw = directRaw ?? _partRevision(parts, 'raw');
    final outline = directOutline ?? _partRevision(parts, 'outline');
    final germination =
        directGermination ?? _partRevision(parts, 'germination');
    if (raw == null || outline == null || germination == null) {
      throw const FormatException('note revisions missing');
    }
    return NoteFileAgentNoteHead(
      noteId: noteId,
      rawPartRevisionId: raw,
      outlinePartRevisionId: outline,
      germinationPartRevisionId: germination,
      sourceKind: _nonEmpty(note['sourceKind']),
    );
  }

  final String noteId;
  final String rawPartRevisionId;
  final String outlinePartRevisionId;
  final String germinationPartRevisionId;
  final String? sourceKind;

  String revisionFor(NoteFileAgentPart part) => switch (part) {
    NoteFileAgentPart.raw => rawPartRevisionId,
    NoteFileAgentPart.outline => outlinePartRevisionId,
    NoteFileAgentPart.germination => germinationPartRevisionId,
  };
}

final class NoteFileAgentPartContent {
  const NoteFileAgentPartContent({
    required this.noteId,
    required this.part,
    required this.partRevisionId,
    required this.markdown,
  });

  factory NoteFileAgentPartContent.fromValue(Object? value) {
    final data = asObjectMap(value);
    final part = data == null ? null : asObjectMap(data['part']) ?? data;
    if (part == null) throw const FormatException('part missing');
    final partName = _part(part['part']);
    final noteId = _requiredId(part['noteId'], 'noteId missing');
    final revision = _requiredId(
      part['partRevisionId'],
      'partRevisionId missing',
    );
    final markdown = part['contentMarkdown'] ?? part['markdown'];
    if (markdown is! String) {
      throw const FormatException('content markdown missing');
    }
    return NoteFileAgentPartContent(
      noteId: noteId,
      part: partName,
      partRevisionId: revision,
      markdown: markdown,
    );
  }

  final String noteId;
  final NoteFileAgentPart part;
  final String partRevisionId;
  final String markdown;
}

final class _NoteFileAgentRun {
  const _NoteFileAgentRun({
    required this.fileAgentRunId,
    required this.noteId,
    required this.status,
    required this.inputPart,
    required this.inputPartRevisionId,
    required this.targetPart,
    required this.targetPartRevisionId,
    required this.selector,
    required this.agentRunId,
    this.outputPartRevisionId,
    this.failureCode,
  });

  factory _NoteFileAgentRun.fromValue(Object? value) {
    final data = asObjectMap(value);
    final run = data == null ? null : asObjectMap(data['fileAgentRun']) ?? data;
    if (run == null) throw const FormatException('file agent run missing');
    final input = asObjectMap(run['input']);
    final target = asObjectMap(run['target']);
    final selector = asObjectMap(run['selector']);
    if (input == null || target == null || selector == null) {
      throw const FormatException('file agent run fields missing');
    }
    final skills = selector['skillProfileIds'];
    if (skills is! List || skills.any((value) => _nonEmpty(value) == null)) {
      throw const FormatException('skills missing');
    }
    return _NoteFileAgentRun(
      fileAgentRunId: _requiredId(
        run['fileAgentRunId'],
        'fileAgentRunId missing',
      ),
      noteId: _requiredId(run['noteId'], 'noteId missing'),
      status: _status(run['status']),
      inputPart: _part(input['part']),
      inputPartRevisionId: _requiredId(
        input['partRevisionId'],
        'input revision missing',
      ),
      targetPart: _part(target['part']),
      targetPartRevisionId: _requiredId(
        target['partRevisionId'],
        'target revision missing',
      ),
      selector: NoteFileAgentSelector(
        agentProfileId: _requiredId(
          selector['agentProfileId'],
          'agent profile missing',
        ),
        skillProfileIds: List<String>.unmodifiable(
          skills.map((value) => (value as String).trim()),
        ),
      ),
      agentRunId: _requiredId(run['agentRunId'], 'agentRunId missing'),
      outputPartRevisionId: _nonEmpty(run['outputPartRevisionId']),
      failureCode: _failureCode(run['failure']),
    );
  }

  final String fileAgentRunId;
  final String noteId;
  final String status;
  final NoteFileAgentPart inputPart;
  final String inputPartRevisionId;
  final NoteFileAgentPart targetPart;
  final String targetPartRevisionId;
  final NoteFileAgentSelector selector;
  final String agentRunId;
  final String? outputPartRevisionId;
  final String? failureCode;
}

NoteFileAgentRunSnapshot _snapshotFor(_NoteFileAgentRun run) =>
    NoteFileAgentRunSnapshot(
      fileAgentRunId: run.fileAgentRunId,
      noteId: run.noteId,
      status: run.status,
      agentRunId: run.agentRunId,
      inputPart: run.inputPart,
      inputPartRevisionId: run.inputPartRevisionId,
      targetPart: run.targetPart,
      targetPartRevisionId: run.targetPartRevisionId,
      outputPartRevisionId: run.outputPartRevisionId,
      failureCode: run.failureCode,
    );

void _ensureRunMatchesRequest(
  _NoteFileAgentRun run,
  NoteFileAgentRequest request,
) {
  if (run.noteId != request.noteId ||
      run.inputPart != request.inputPart ||
      run.inputPartRevisionId != request.inputPartRevisionId ||
      run.targetPart != request.targetPart ||
      run.targetPartRevisionId != request.targetPartRevisionId ||
      !run.selector.matches(request.selector)) {
    throw const NoteFileAgentException('NOTE_FILE_AGENT_SELECTOR_MISMATCH');
  }
}

bool _isGenericAdmissionProcessing(Map<String, Object?> value) =>
    _nonEmpty(value['status'])?.toLowerCase() == 'processing' &&
    !value.containsKey('fileAgentRun');

void _validateRequest(NoteFileAgentRequest request) {
  if (_nonEmpty(request.noteId) == null ||
      _nonEmpty(request.inputPartRevisionId) == null ||
      _nonEmpty(request.targetPartRevisionId) == null ||
      _nonEmpty(request.instruction) == null ||
      _nonEmpty(request.idempotencyKey) == null ||
      _nonEmpty(request.selector.agentProfileId) == null ||
      request.selector.skillProfileIds.isEmpty ||
      request.selector.skillProfileIds.any(
        (skill) => _nonEmpty(skill) == null,
      )) {
    throw const NoteFileAgentException('NOTE_FILE_AGENT_REQUEST_INVALID');
  }
}

NoteFileAgentPart _part(Object? value) => switch (_nonEmpty(value)) {
  'raw' => NoteFileAgentPart.raw,
  'outline' => NoteFileAgentPart.outline,
  'germination' => NoteFileAgentPart.germination,
  _ => throw const FormatException('unsupported note part'),
};

NoteFileAgentPart? _optionalPart(Object? value) {
  if (value == null) return null;
  return _part(value);
}

String _status(Object? value) {
  final status = _nonEmpty(value)?.toLowerCase();
  if (status == null ||
      !const <String>{
        'admitting',
        'retry_wait',
        'retry_admitting',
        'queued',
        'resolving',
        'planning',
        'running',
        'finalizing',
        'succeeded',
        'failed',
        'timeout',
        'conflict',
        'cancelled',
      }.contains(status)) {
    throw const FormatException('unsupported file agent status');
  }
  return status;
}

String? _partRevision(Map<String, Object?>? parts, String part) =>
    _nonEmpty(asObjectMap(parts?[part])?['partRevisionId']);

String? _failureCode(Object? value) {
  final failure = asObjectMap(value);
  return _nonEmpty(failure?['code']) ?? _nonEmpty(failure?['errorCode']);
}

String? _optionalPublicIdentifier(Object? value, String message) {
  if (value == null) return null;
  return _requiredId(value, message);
}

String? _publicFailureCode(Map<String, Object?> run) {
  final direct = _nonEmpty(run['failureCode']);
  final nested = _failureCode(run['failure']);
  if (direct != null && nested != null && direct != nested) {
    throw const FormatException('file agent failure mismatch');
  }
  final code = direct ?? nested;
  if (code == null) return null;
  if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,159}$').hasMatch(code)) {
    throw const FormatException('file agent failure code invalid');
  }
  return code;
}

String _requiredId(Object? value, String message) {
  final id = _nonEmpty(value);
  if (id == null || !RegExp(r'^[A-Za-z0-9._:-]{1,160}$').hasMatch(id)) {
    throw NoteFileAgentException(message);
  }
  return id;
}

String? _nonEmpty(Object? value) {
  if (value is! String) return null;
  final text = value.trim();
  return text.isEmpty ? null : text;
}

bool _sameStrings(List<String> left, List<String> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

Future<void> _defaultDelay(Duration duration) => Future<void>.delayed(duration);
