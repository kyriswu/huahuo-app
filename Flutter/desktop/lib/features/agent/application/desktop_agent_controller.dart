import 'dart:async';

import 'package:huahuo_api/huahuo_api.dart';

import '../../../shared/services/desktop_service_result.dart';
import '../../integration/domain/desktop_api_domains_port.dart';

typedef DesktopAgentIdempotencyKeyFactory = String Function();

final class DesktopAgentFeatureSelection {
  const DesktopAgentFeatureSelection({
    required this.route,
    required this.catalogVersion,
  });

  final AgentFeatureRoute route;
  final String catalogVersion;
}

final class DesktopAgentDocumentReference {
  DesktopAgentDocumentReference({
    required this.ownerId,
    required this.part,
    required this.partRevisionId,
    this.targetPartRevisionId,
  }) {
    SharedAgentWorkspaceDocumentContent(
      ownerKind: 'hnote',
      ownerId: ownerId,
      part: part,
      partRevisionId: partRevisionId,
    );
  }

  final String ownerId;
  final String part;
  final String partRevisionId;
  final String? targetPartRevisionId;

  String get identity =>
      '$ownerId:$part:$partRevisionId:${targetPartRevisionId ?? ''}';

  SharedAgentWorkspaceDocumentContent toShared() =>
      SharedAgentWorkspaceDocumentContent(
        ownerKind: 'hnote',
        ownerId: ownerId,
        part: part,
        partRevisionId: partRevisionId,
      );
}

final class DesktopAgentRunOutput {
  const DesktopAgentRunOutput({
    required this.agentRunId,
    required this.assistantMessageId,
    required this.finalAnswer,
    required this.usage,
    required this.outputFiles,
    this.outputPartRevisionId,
  });

  final String agentRunId;
  final String assistantMessageId;
  final String finalAnswer;
  final AgentRunUsage usage;
  final List<AgentRunOutputFile> outputFiles;
  final String? outputPartRevisionId;
}

final class DesktopAgentController {
  DesktopAgentController({
    required this._port,
    this.pollInterval = const Duration(seconds: 1),
    this.maxPollAttempts = 30,
    DesktopAgentIdempotencyKeyFactory? idempotencyKeyFactory,
  }) : _idempotencyKeyFactory = idempotencyKeyFactory ?? _defaultIdempotencyKey;

  final DesktopCatalogPort _port;
  final Duration pollInterval;
  final int maxPollAttempts;
  final DesktopAgentIdempotencyKeyFactory _idempotencyKeyFactory;

  _DesktopAgentScope? _scope;
  _DesktopAgentCatalogCache? _catalog;
  final Map<String, _DesktopPendingAgentAction> _pendingActions =
      <String, _DesktopPendingAgentAction>{};
  final Map<String, _DesktopInFlightAgentAction> _inFlightActions =
      <String, _DesktopInFlightAgentAction>{};

  String? get catalogVersion => _catalog?.catalogVersion;

  void bindAccount({required String userId, required String workspaceId}) {
    final next = _DesktopAgentScope(userId: userId, workspaceId: workspaceId);
    if (_scope == next) return;
    _scope = next;
    _clearScopedState();
  }

  void clearAccount() {
    _scope = null;
    _clearScopedState();
  }

  void invalidateCatalog() => _catalog = null;

  Future<DesktopServiceResult<DesktopAgentFeatureSelection>> resolveFeature(
    String featureId, {
    bool refresh = false,
  }) async {
    if (_isProhibitedFeature(featureId)) {
      return const DesktopServiceResult<
        DesktopAgentFeatureSelection
      >.unavailable(code: 'API_ENDPOINT_PROHIBITED', message: '该 AI 能力禁止接入');
    }
    final route = AgentFeatureRoutes.forFeature(featureId);
    if (route == null) {
      return const DesktopServiceResult<
        DesktopAgentFeatureSelection
      >.unavailable(
        code: 'AGENT_FEATURE_ROUTE_UNKNOWN',
        message: '该 AI 能力尚未发布',
      );
    }
    final scope = _scope;
    if (scope == null) {
      return const DesktopServiceResult<
        DesktopAgentFeatureSelection
      >.unavailable(
        code: 'DESKTOP_AGENT_ACCOUNT_REQUIRED',
        message: '请先登录并选择 Workspace',
      );
    }
    if (refresh) _catalog = null;
    final catalogResult = await _loadCatalog(scope);
    if (!catalogResult.isSuccess || catalogResult.data == null) {
      return _forwardFailure(catalogResult);
    }
    if (_scope != scope) return _accountChanged();
    final catalog = catalogResult.data!;
    final availability = AgentFeatureAvailabilityResolver.resolve(
      route: route,
      profiles: catalog.profiles,
    );
    if (!availability.isAvailable) {
      return DesktopServiceResult<DesktopAgentFeatureSelection>.unavailable(
        code: availability.reasonCode ?? 'DESKTOP_AGENT_FEATURE_UNAVAILABLE',
        message: _availabilityMessage(availability),
      );
    }
    return DesktopServiceResult<DesktopAgentFeatureSelection>.success(
      DesktopAgentFeatureSelection(
        route: route,
        catalogVersion: catalog.catalogVersion,
      ),
    );
  }

  Future<DesktopServiceResult<DesktopAgentRunOutput>> runFeature({
    required String featureId,
    required String actionId,
    required String instruction,
    required DesktopAgentDocumentReference document,
  }) {
    final normalizedFeatureId = featureId.trim();
    if (_isProhibitedFeature(normalizedFeatureId)) {
      return Future<DesktopServiceResult<DesktopAgentRunOutput>>.value(
        const DesktopServiceResult<DesktopAgentRunOutput>.unavailable(
          code: 'API_ENDPOINT_PROHIBITED',
          message: '该 AI 能力禁止接入',
        ),
      );
    }
    final scope = _scope;
    if (scope == null) {
      return Future<DesktopServiceResult<DesktopAgentRunOutput>>.value(
        const DesktopServiceResult<DesktopAgentRunOutput>.unavailable(
          code: 'DESKTOP_AGENT_ACCOUNT_REQUIRED',
          message: '请先登录并选择 Workspace',
        ),
      );
    }
    final normalizedActionId = actionId.trim();
    final normalizedInstruction = instruction.trim();
    if (normalizedActionId.isEmpty ||
        normalizedFeatureId.isEmpty ||
        normalizedInstruction.isEmpty ||
        normalizedInstruction.length > 1000) {
      return Future<DesktopServiceResult<DesktopAgentRunOutput>>.value(
        const DesktopServiceResult<DesktopAgentRunOutput>.failure(
          code: 'DESKTOP_AGENT_INPUT_INVALID',
          message: 'AI 操作参数无效',
        ),
      );
    }
    final actionScopeKey = _canonicalFingerprint(<String?>[
      scope.userId,
      scope.workspaceId,
      normalizedActionId,
    ]);
    final intentFingerprint = _canonicalFingerprint(<String?>[
      normalizedFeatureId,
      normalizedInstruction,
      document.ownerId,
      document.part,
      document.partRevisionId,
      document.targetPartRevisionId,
    ]);
    final pending = _pendingActions[actionScopeKey];
    if (pending != null && pending.intentFingerprint != intentFingerprint) {
      return _idempotencyConflict();
    }
    final existing = _inFlightActions[actionScopeKey];
    if (existing != null) {
      return existing.intentFingerprint == intentFingerprint
          ? existing.future
          : _idempotencyConflict();
    }
    final future = _runFeature(
      scope: scope,
      actionScopeKey: actionScopeKey,
      intentFingerprint: intentFingerprint,
      featureId: normalizedFeatureId,
      instruction: normalizedInstruction,
      document: document,
    );
    final inFlight = _DesktopInFlightAgentAction(
      intentFingerprint: intentFingerprint,
      future: future,
    );
    _inFlightActions[actionScopeKey] = inFlight;
    return future.whenComplete(() {
      if (identical(_inFlightActions[actionScopeKey], inFlight)) {
        _inFlightActions.remove(actionScopeKey);
      }
    });
  }

  Future<DesktopServiceResult<DesktopAgentRunOutput>> _runFeature({
    required _DesktopAgentScope scope,
    required String actionScopeKey,
    required String intentFingerprint,
    required String featureId,
    required String instruction,
    required DesktopAgentDocumentReference document,
  }) async {
    if (maxPollAttempts < 1 || pollInterval.isNegative) {
      return const DesktopServiceResult<DesktopAgentRunOutput>.failure(
        code: 'DESKTOP_AGENT_POLL_CONFIGURATION_INVALID',
        message: 'AgentRun 轮询配置无效',
      );
    }
    final selectionResult = await resolveFeature(featureId);
    if (!selectionResult.isSuccess || selectionResult.data == null) {
      return _forwardFailure(selectionResult);
    }
    if (_scope != scope) return _accountChanged();
    final selection = selectionResult.data!;
    final existingPending = _pendingActions[actionScopeKey];
    if (existingPending != null &&
        existingPending.intentFingerprint != intentFingerprint) {
      return _idempotencyConflictResult();
    }
    final pending =
        existingPending ??
        (_pendingActions[actionScopeKey] = _DesktopPendingAgentAction(
          intentFingerprint: intentFingerprint,
          idempotencyKey: _idempotencyKeyFactory(),
        ));
    if (featureId == 'note.sprout') {
      return _runSproutFileAgent(
        scope: scope,
        actionScopeKey: actionScopeKey,
        pending: pending,
        selection: selection,
        instruction: instruction,
        document: document,
      );
    }
    AgentRunSnapshot? run;
    if (pending.agentRunId == null) {
      final createResult = await _port.createAgentRun(
        AgentRunRequest(
          workspaceId: scope.workspaceId,
          agentProfileId: selection.route.agentProfileId,
          input: SharedAgentInput(
            content: <SharedAgentInputContent>[
              SharedAgentTextContent(text: instruction),
              document.toShared(),
            ],
          ),
        ),
        idempotencyKey: pending.idempotencyKey,
      );
      if (_scope != scope) return _accountChanged();
      if (!createResult.isSuccess || createResult.data == null) {
        return _forwardFailure(createResult);
      }
      run = createResult.data!;
      final mismatch = _runMismatch(run, scope, expectedRunId: null);
      if (mismatch != null) return mismatch;
      pending.agentRunId = run.agentRunId;
      final terminal = _terminalResult(run, actionScopeKey);
      if (terminal != null) return terminal;
    }

    for (var attempt = 0; attempt < maxPollAttempts; attempt += 1) {
      if (attempt > 0 && pollInterval != Duration.zero) {
        await Future<void>.delayed(pollInterval);
      }
      if (_scope != scope) return _accountChanged();
      final runId = pending.agentRunId!;
      final pollResult = await _port.loadAgentRun(runId);
      if (_scope != scope) return _accountChanged();
      if (!pollResult.isSuccess || pollResult.data == null) {
        if (pollResult.retryable) continue;
        return _forwardFailure(pollResult);
      }
      run = pollResult.data!;
      final mismatch = _runMismatch(run, scope, expectedRunId: runId);
      if (mismatch != null) return mismatch;
      final terminal = _terminalResult(run, actionScopeKey);
      if (terminal != null) return terminal;
    }
    return const DesktopServiceResult<DesktopAgentRunOutput>.failure(
      code: 'DESKTOP_AGENT_RUN_TIMEOUT',
      message: 'AI 任务仍在处理中，请稍后重试',
      retryable: true,
    );
  }

  Future<DesktopServiceResult<DesktopAgentRunOutput>> _runSproutFileAgent({
    required _DesktopAgentScope scope,
    required String actionScopeKey,
    required _DesktopPendingAgentAction pending,
    required DesktopAgentFeatureSelection selection,
    required String instruction,
    required DesktopAgentDocumentReference document,
  }) async {
    final targetRevision = document.targetPartRevisionId?.trim();
    if (selection.route.agentProfileId != 'faya_germination' ||
        document.part != 'raw' ||
        targetRevision == null ||
        targetRevision.isEmpty) {
      return const DesktopServiceResult<DesktopAgentRunOutput>.failure(
        code: 'DESKTOP_NOTE_FILE_AGENT_INPUT_INVALID',
        message: '发芽任务缺少精确的笔记版本',
      );
    }
    DesktopNoteFileAgentRun? run;
    if (pending.fileAgentRunId == null) {
      final created = await _port.createNoteFileAgentRun(
        workspaceId: scope.workspaceId,
        noteId: document.ownerId,
        inputPart: 'raw',
        inputPartRevisionId: document.partRevisionId,
        targetPart: 'germination',
        targetPartRevisionId: targetRevision,
        instruction: instruction,
        agentProfileId: 'faya_germination',
        skillProfileIds: const <String>['viewpoint_germination'],
        idempotencyKey: pending.idempotencyKey,
      );
      if (_scope != scope) return _accountChanged();
      if (!created.isSuccess || created.data == null) {
        return _forwardFailure(created);
      }
      run = created.data!;
      final mismatch = _fileAgentMismatch(run, document);
      if (mismatch != null) return mismatch;
      pending.fileAgentRunId = run.fileAgentRunId;
      final terminal = _fileAgentTerminal(run, actionScopeKey);
      if (terminal != null) return terminal;
    }
    for (var attempt = 0; attempt < maxPollAttempts; attempt += 1) {
      if (attempt > 0 && pollInterval != Duration.zero) {
        await Future<void>.delayed(pollInterval);
      }
      if (_scope != scope) return _accountChanged();
      final polled = await _port.loadNoteFileAgentRun(
        workspaceId: scope.workspaceId,
        noteId: document.ownerId,
        fileAgentRunId: pending.fileAgentRunId!,
      );
      if (_scope != scope) return _accountChanged();
      if (!polled.isSuccess || polled.data == null) {
        if (polled.retryable) continue;
        return _forwardFailure(polled);
      }
      run = polled.data!;
      final mismatch = _fileAgentMismatch(run, document);
      if (mismatch != null) return mismatch;
      final terminal = _fileAgentTerminal(run, actionScopeKey);
      if (terminal != null) return terminal;
    }
    return const DesktopServiceResult<DesktopAgentRunOutput>.failure(
      code: 'DESKTOP_AGENT_RUN_TIMEOUT',
      message: 'AI 任务仍在处理中，请稍后重试',
      retryable: true,
    );
  }

  DesktopServiceResult<DesktopAgentRunOutput>? _fileAgentMismatch(
    DesktopNoteFileAgentRun run,
    DesktopAgentDocumentReference document,
  ) {
    if (run.noteId == document.ownerId &&
        run.agentProfileId == 'faya_germination' &&
        run.skillProfileIds.length == 1 &&
        run.skillProfileIds.single == 'viewpoint_germination' &&
        run.inputPart == 'raw' &&
        run.inputPartRevisionId == document.partRevisionId &&
        run.targetPart == 'germination' &&
        run.targetPartRevisionId == document.targetPartRevisionId) {
      return null;
    }
    return const DesktopServiceResult<DesktopAgentRunOutput>.failure(
      code: 'DESKTOP_NOTE_FILE_AGENT_RUN_MISMATCH',
      message: '发芽任务与当前笔记版本不匹配',
    );
  }

  DesktopServiceResult<DesktopAgentRunOutput>? _fileAgentTerminal(
    DesktopNoteFileAgentRun run,
    String actionScopeKey,
  ) {
    if (!run.isTerminal) return null;
    _pendingActions.remove(actionScopeKey);
    if (run.status != 'succeeded') {
      return DesktopServiceResult<DesktopAgentRunOutput>.failure(
        code:
            run.failureCode ??
            'DESKTOP_NOTE_FILE_AGENT_${run.status.toUpperCase()}',
        message: '发芽任务未能写入笔记',
        retryable: run.status == 'failed' || run.status == 'timeout',
      );
    }
    final outputRevision = run.outputPartRevisionId?.trim();
    final agentRunId = run.agentRunId?.trim();
    if (outputRevision == null ||
        outputRevision.isEmpty ||
        agentRunId == null ||
        agentRunId.isEmpty) {
      return const DesktopServiceResult<DesktopAgentRunOutput>.failure(
        code: 'DESKTOP_NOTE_FILE_AGENT_OUTPUT_INVALID',
        message: '发芽任务缺少服务端写入版本',
      );
    }
    return DesktopServiceResult<DesktopAgentRunOutput>.success(
      DesktopAgentRunOutput(
        agentRunId: agentRunId,
        assistantMessageId: '',
        finalAnswer: '',
        usage: const AgentRunUsage(
          measurementStatus: 'unavailable',
          inputTokens: null,
          outputTokens: null,
          imageCount: null,
          videoSeconds: null,
          accountedCredits: null,
          policyVersion: null,
        ),
        outputFiles: const <AgentRunOutputFile>[],
        outputPartRevisionId: outputRevision,
      ),
    );
  }

  Future<DesktopServiceResult<_DesktopAgentCatalogCache>> _loadCatalog(
    _DesktopAgentScope scope,
  ) async {
    final cached = _catalog;
    if (cached != null && cached.scope == scope) {
      return DesktopServiceResult<_DesktopAgentCatalogCache>.success(cached);
    }
    final profiles = await _port.loadProfiles();
    if (!profiles.isSuccess || profiles.data == null) {
      return _forwardFailure(profiles);
    }
    if (_scope != scope) return _accountChanged();
    final loaded = _DesktopAgentCatalogCache(
      scope: scope,
      profiles: profiles.data!,
    );
    _catalog = loaded;
    return DesktopServiceResult<_DesktopAgentCatalogCache>.success(loaded);
  }

  DesktopServiceResult<DesktopAgentRunOutput>? _terminalResult(
    AgentRunSnapshot run,
    String actionKey,
  ) {
    if (!run.isTerminal) return null;
    _pendingActions.remove(actionKey);
    if (run.status == 'succeeded' &&
        run.completionMode == 'normal' &&
        (!run.hasDurableAssistantResult || run.result == null)) {
      return const DesktopServiceResult<DesktopAgentRunOutput>.failure(
        code: 'DESKTOP_AGENT_DURABLE_RESULT_MISSING',
        message: 'AI 任务缺少已持久化的正式结果',
      );
    }
    if (!run.isSuccessful || run.result == null) {
      return DesktopServiceResult<DesktopAgentRunOutput>.failure(
        code: switch (run.completionMode) {
          'degraded' => 'DESKTOP_AGENT_DEGRADED_RESULT',
          'system_fallback' => 'DESKTOP_AGENT_SYSTEM_FALLBACK',
          'cancelled' => 'DESKTOP_AGENT_RUN_CANCELLED',
          _ => 'DESKTOP_AGENT_RUN_${run.status.toUpperCase()}',
        },
        message: 'AI 任务未返回可采用的正式结果',
        retryable: run.status == 'failed' || run.status == 'timeout',
      );
    }
    final answer = run.result!.finalAnswer.trim();
    if (answer.isEmpty ||
        run.result!.assistantMessageId != run.assistantMessageId ||
        run.result!.completionMode != 'normal') {
      return const DesktopServiceResult<DesktopAgentRunOutput>.failure(
        code: 'DESKTOP_AGENT_DURABLE_RESULT_INVALID',
        message: 'AI 任务缺少可验证的持久结果',
      );
    }
    return DesktopServiceResult<DesktopAgentRunOutput>.success(
      DesktopAgentRunOutput(
        agentRunId: run.agentRunId,
        assistantMessageId: run.assistantMessageId!,
        finalAnswer: answer,
        usage: run.usage,
        outputFiles: run.outputFiles,
      ),
    );
  }

  DesktopServiceResult<DesktopAgentRunOutput>? _runMismatch(
    AgentRunSnapshot run,
    _DesktopAgentScope scope, {
    required String? expectedRunId,
  }) {
    if (run.workspaceId == scope.workspaceId &&
        (expectedRunId == null || run.agentRunId == expectedRunId)) {
      return null;
    }
    return const DesktopServiceResult<DesktopAgentRunOutput>.failure(
      code: 'DESKTOP_AGENT_RUN_SCOPE_MISMATCH',
      message: 'AgentRun 与当前账号或 Workspace 不匹配',
    );
  }

  void _clearScopedState() {
    _catalog = null;
    _pendingActions.clear();
    _inFlightActions.clear();
  }
}

final class _DesktopAgentScope {
  const _DesktopAgentScope({required this.userId, required this.workspaceId});

  final String userId;
  final String workspaceId;

  @override
  bool operator ==(Object other) =>
      other is _DesktopAgentScope &&
      other.userId == userId &&
      other.workspaceId == workspaceId;

  @override
  int get hashCode => Object.hash(userId, workspaceId);
}

final class _DesktopAgentCatalogCache {
  _DesktopAgentCatalogCache({required this.scope, required this.profiles});

  final _DesktopAgentScope scope;
  final AgentProfileCatalog profiles;

  String get catalogVersion => profiles.catalogVersion;
}

final class _DesktopPendingAgentAction {
  _DesktopPendingAgentAction({
    required this.intentFingerprint,
    required this.idempotencyKey,
  });

  final String intentFingerprint;
  final String idempotencyKey;
  String? agentRunId;
  String? fileAgentRunId;
}

final class _DesktopInFlightAgentAction {
  const _DesktopInFlightAgentAction({
    required this.intentFingerprint,
    required this.future,
  });

  final String intentFingerprint;
  final Future<DesktopServiceResult<DesktopAgentRunOutput>> future;
}

DesktopServiceResult<T> _forwardFailure<T>(
  DesktopServiceResult<dynamic> result,
) {
  if (result.isUnavailable) {
    return DesktopServiceResult<T>.unavailable(
      code: result.code,
      message: result.message,
    );
  }
  return DesktopServiceResult<T>.failure(
    code: result.code,
    message: result.message,
    retryable: result.retryable,
  );
}

DesktopServiceResult<T> _accountChanged<T>() => DesktopServiceResult<T>.failure(
  code: 'DESKTOP_AGENT_ACCOUNT_CHANGED',
  message: '账号或 Workspace 已切换，请重试',
);

Future<DesktopServiceResult<DesktopAgentRunOutput>> _idempotencyConflict() =>
    Future<DesktopServiceResult<DesktopAgentRunOutput>>.value(
      _idempotencyConflictResult(),
    );

DesktopServiceResult<DesktopAgentRunOutput> _idempotencyConflictResult() =>
    const DesktopServiceResult<DesktopAgentRunOutput>.failure(
      code: 'DESKTOP_AGENT_IDEMPOTENCY_CONFLICT',
      message: '同一 AI 操作的请求内容已经变化，请重新发起操作',
    );

String _availabilityMessage(AgentFeatureAvailability availability) =>
    switch (availability.status) {
      AgentFeatureAvailabilityStatus.publicationBlocked => '该 AI 能力尚未发布',
      AgentFeatureAvailabilityStatus.agentProfileUnavailable =>
        '所需 Agent 当前不可选择',
      AgentFeatureAvailabilityStatus.skillNotCandidate => '所需 Skill 当前不可选择',
      AgentFeatureAvailabilityStatus.skillNotInstalled => '请先安装所需 Skill',
      AgentFeatureAvailabilityStatus.skillDisabled => '所需 Skill 当前未启用',
      AgentFeatureAvailabilityStatus.modelNotSelectable => '所选模型当前不可用',
      AgentFeatureAvailabilityStatus.featureUnknown => '该 AI 能力尚未发布',
      AgentFeatureAvailabilityStatus.available => '',
    };

bool _isProhibitedFeature(String featureId) {
  final normalized = featureId.trim().toLowerCase();
  return normalized.startsWith('work-ai') ||
      normalized.startsWith('work_ai') ||
      normalized.startsWith('feed-ai') ||
      normalized.startsWith('feed_ai');
}

String _canonicalFingerprint(Iterable<String?> fields) => fields
    .map((field) => field == null ? '-1:' : '${field.length}:$field')
    .join('|');

int _agentKeySequence = 0;

String _defaultIdempotencyKey() {
  _agentKeySequence += 1;
  return 'desktop-agent-${DateTime.now().toUtc().microsecondsSinceEpoch}-$_agentKeySequence';
}
