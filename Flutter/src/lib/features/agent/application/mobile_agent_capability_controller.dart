import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/bootstrap/app_providers.dart';
import '../../../core/api/api_client.dart';
import '../../../core/api/api_envelope.dart';
import '../../../core/api/idempotency.dart';
import '../../../core/auth/session_store.dart';
import '../../../core/database/app_preferences_dao.dart';
import '../data/mobile_agent_capability_port.dart';

// resident-provider: Shares one mobile agent capability port dependency for the full account session.
final mobileAgentCapabilityPortProvider = Provider<MobileAgentCapabilityPort>((
  ref,
) {
  try {
    return RemoteMobileAgentCapabilityPort(ref.watch(apiClientProvider));
  } on StateError catch (error) {
    if (error.message == 'DEVICE_IDENTITY_NOT_RESOLVED') {
      return const UnavailableMobileAgentCapabilityPort();
    }
    rethrow;
  }
});

// resident-provider: Keeps the mobile agent runtime identity value consistent across sibling route consumers.
final mobileAgentRuntimeIdentityProvider = Provider<MobileAgentRuntimeIdentity>(
  (ref) {
    final sessionBinding = ref.watch(
      sessionStoreProvider.select((store) {
        final session = store.state;
        return (
          isAuthenticated: session.authState == SessionAuthState.authenticated,
          userId: session.user?.userId,
          workspaceId: session.workspace?.workspaceId,
          workspaceRecoveryRequired:
              session.needsWorkspaceRetry ||
              session.workspaceStatus != SessionWorkspaceStatus.ready,
        );
      }),
    );
    final metadata = ref.watch(runtimeClientMetadataProvider);
    if (!sessionBinding.isAuthenticated) {
      return MobileAgentRuntimeIdentity.anonymous(
        locale: metadata.locale,
        timezone: metadata.timeZone,
      );
    }
    return MobileAgentRuntimeIdentity(
      userId: sessionBinding.userId,
      workspaceId: sessionBinding.workspaceId,
      workspaceRecoveryRequired: sessionBinding.workspaceRecoveryRequired,
      locale: metadata.locale,
      timezone: metadata.timeZone,
    );
  },
);

// resident-provider: Preserves the mobile agent capability controller state machine across route transitions.
final mobileAgentCapabilityControllerProvider =
    ChangeNotifierProvider<MobileAgentCapabilityController>((ref) {
      return MobileAgentCapabilityController(
        port: ref.watch(mobileAgentCapabilityPortProvider),
        identity: ref.watch(mobileAgentRuntimeIdentityProvider),
        preferences: ref.watch(appPreferencesDaoProvider),
        catalogCacheTtlResolver: () =>
            ref.read(appCachePolicyProvider).cacheTtl,
      );
    });

@immutable
final class MobileAgentRuntimeIdentity {
  const MobileAgentRuntimeIdentity({
    required this.userId,
    required this.workspaceId,
    this.workspaceRecoveryRequired = false,
    required this.locale,
    required this.timezone,
  });

  const MobileAgentRuntimeIdentity.anonymous({
    required this.locale,
    required this.timezone,
  }) : userId = null,
       workspaceId = null,
       workspaceRecoveryRequired = false;

  final String? userId;
  final String? workspaceId;
  final bool workspaceRecoveryRequired;
  final String locale;
  final String timezone;

  bool get isReady =>
      userId?.trim().isNotEmpty == true &&
      workspaceId?.trim().isNotEmpty == true &&
      !workspaceRecoveryRequired;

  bool get isAuthenticated => userId?.trim().isNotEmpty == true;

  String get unavailableErrorCode {
    if (!isAuthenticated) return 'AGENT_SESSION_REQUIRED';
    if (workspaceRecoveryRequired) {
      return 'AGENT_WORKSPACE_RECOVERY_REQUIRED';
    }
    return 'AGENT_WORKSPACE_CONTEXT_UNAVAILABLE';
  }

  String get bindingKey => isAuthenticated
      ? '$userId\u0000${workspaceId ?? ''}\u0000$workspaceRecoveryRequired'
      : 'anonymous';
}

enum MobileAgentFeatureStatus { idle, loading, available, unavailable, failed }

@immutable
final class MobileAgentFeatureAccess {
  const MobileAgentFeatureAccess({
    required this.featureId,
    required this.status,
    this.catalogVersion,
    this.availability,
    this.errorCode,
  });

  final String featureId;
  final MobileAgentFeatureStatus status;
  final String? catalogVersion;
  final AgentFeatureAvailability? availability;
  final String? errorCode;

  bool get isAvailable =>
      status == MobileAgentFeatureStatus.available &&
      availability?.isAvailable == true;
}

sealed class MobileAgentInputReference {
  const MobileAgentInputReference();

  SharedAgentInputContent toShared();
}

@immutable
final class MobileAgentHNoteReference extends MobileAgentInputReference {
  MobileAgentHNoteReference({
    required String noteId,
    required String part,
    required String partRevisionId,
  }) : noteId = noteId.trim(),
       part = part.trim(),
       partRevisionId = partRevisionId.trim() {
    if (this.noteId.isEmpty || this.partRevisionId.isEmpty) {
      throw ArgumentError('Exact HNote identity is required');
    }
    if (!const <String>{'raw', 'outline', 'germination'}.contains(this.part)) {
      throw ArgumentError.value(part, 'part', 'Unsupported HNote part');
    }
  }

  final String noteId;
  final String part;
  final String partRevisionId;

  @override
  SharedAgentInputContent toShared() => SharedAgentWorkspaceDocumentContent(
    ownerKind: 'hnote',
    ownerId: noteId,
    part: part,
    partRevisionId: partRevisionId,
  );
}

@immutable
final class MobileAgentResourceReference extends MobileAgentInputReference {
  MobileAgentResourceReference({
    required String type,
    required String resourceId,
    String usage = 'reference',
  }) : type = type.trim(),
       resourceId = resourceId.trim(),
       usage = usage.trim();

  final String type;
  final String resourceId;
  final String usage;

  @override
  SharedAgentInputContent toShared() => SharedAgentResourceContent(
    type: type,
    resourceId: resourceId,
    usage: usage,
  );
}

@immutable
final class MobileAgentRunCommand {
  MobileAgentRunCommand({
    required String operationId,
    required String featureId,
    required String visibleText,
    String? additionalText,
    String? supplementalText,
    Iterable<MobileAgentInputReference> references =
        const <MobileAgentInputReference>[],
    String? threadId,
  }) : operationId = operationId.trim(),
       featureId = featureId.trim(),
       visibleText = visibleText.trim(),
       additionalText = additionalText,
       supplementalText = supplementalText,
       references = List<MobileAgentInputReference>.unmodifiable(references),
       threadId = _normalizedOptional(threadId) {
    if (this.operationId.isEmpty ||
        this.featureId.isEmpty ||
        this.visibleText.isEmpty ||
        this.visibleText.length > 1000 ||
        this.additionalText?.trim().isEmpty == true ||
        this.supplementalText?.trim().isEmpty == true) {
      throw ArgumentError(
        'Agent operation, feature, and visible text required',
      );
    }
    if (_containsUnsafeRunText(this.visibleText) ||
        (this.additionalText != null &&
            _containsUnsafeRunText(this.additionalText!)) ||
        (this.supplementalText != null &&
            _containsUnsafeRunText(this.supplementalText!))) {
      throw ArgumentError.value(
        supplementalText ?? additionalText ?? visibleText,
        'text',
        'Local paths and private credentials are forbidden',
      );
    }
  }

  final String operationId;
  final String featureId;
  final String visibleText;
  final String? additionalText;
  final String? supplementalText;
  final List<MobileAgentInputReference> references;
  final String? threadId;
}

enum MobileAgentRunStatus { succeeded, failed, superseded }

@immutable
final class MobileAgentRunPollingPolicy {
  const MobileAgentRunPollingPolicy({
    this.maxAttempts = 120,
    this.initialInterval = const Duration(milliseconds: 750),
    this.maxInterval = const Duration(seconds: 3),
  }) : assert(maxAttempts > 0);

  final int maxAttempts;
  final Duration initialInterval;
  final Duration maxInterval;

  Duration intervalFor(int attempt) => Duration(
    microseconds: (initialInterval.inMicroseconds * (1 + attempt ~/ 5)).clamp(
      0,
      maxInterval.inMicroseconds,
    ),
  );
}

@immutable
final class MobileAgentRunOutcome {
  const MobileAgentRunOutcome({
    required this.status,
    this.run,
    this.usage,
    this.errorCode,
    this.usageErrorCode,
  });

  final MobileAgentRunStatus status;
  final AgentRunSnapshot? run;
  final SharedRunUsage? usage;
  final String? errorCode;
  final String? usageErrorCode;

  bool get succeeded => status == MobileAgentRunStatus.succeeded;
  String? get outputMarkdown => succeeded ? run?.result?.finalAnswer : null;
}

final class _MobileAgentRunOperation {
  _MobileAgentRunOperation({
    required this.generation,
    required this.operationId,
    required this.cancelIdempotencyKey,
  });

  final int generation;
  final String operationId;
  final String cancelIdempotencyKey;
  AgentRunRequest? createRequest;
  String? createIdempotencyKey;
  Future<ApiResult<AgentRunSnapshot>>? createInFlight;
  String? agentRunId;
  AgentRunSnapshot? lastSnapshot;
  bool createStarted = false;
  bool createOutcomeUnknown = false;
  bool cancelRequested = false;
  bool cancelDispatched = false;
}

final class MobileAgentCapabilityController extends ChangeNotifier {
  MobileAgentCapabilityController({
    required MobileAgentCapabilityPort port,
    required MobileAgentRuntimeIdentity identity,
    Duration pollInterval = const Duration(milliseconds: 750),
    Duration retryInterval = const Duration(milliseconds: 300),
    int maxPollAttempts = 40,
    int maxTransientFailures = 2,
    Future<void> Function(Duration)? delay,
    AppPreferencesDao? preferences,
    Duration Function()? catalogCacheTtlResolver,
    DateTime Function()? now,
  }) : // Named constructor arguments intentionally keep their public names.
       // ignore: prefer_initializing_formals
       _port = port,
       // ignore: prefer_initializing_formals
       _identity = identity,
       _pollInterval = pollInterval,
       _retryInterval = retryInterval,
       _maxPollAttempts = maxPollAttempts,
       _maxTransientFailures = maxTransientFailures,
       _delay = delay ?? Future<void>.delayed,
       // ignore: prefer_initializing_formals
       _preferences = preferences,
       // ignore: prefer_initializing_formals
       _catalogCacheTtlResolver = catalogCacheTtlResolver,
       _now = now ?? DateTime.now {
    if (pollInterval.isNegative ||
        retryInterval.isNegative ||
        maxPollAttempts < 1 ||
        maxTransientFailures < 0) {
      throw ArgumentError('Invalid Mobile Agent polling configuration');
    }
  }

  final MobileAgentCapabilityPort _port;
  MobileAgentRuntimeIdentity _identity;
  final Duration _pollInterval;
  final Duration _retryInterval;
  final int _maxPollAttempts;
  final int _maxTransientFailures;
  final Future<void> Function(Duration) _delay;
  final AppPreferencesDao? _preferences;
  final Duration Function()? _catalogCacheTtlResolver;
  final DateTime Function() _now;

  AgentProfileCatalog? _profiles;
  final Map<String, MobileAgentFeatureAccess> _features =
      <String, MobileAgentFeatureAccess>{};
  final Map<String, Future<MobileAgentFeatureAccess>> _pendingFeatures =
      <String, Future<MobileAgentFeatureAccess>>{};
  final Map<int, _MobileAgentRunOperation> _runOperations =
      <int, _MobileAgentRunOperation>{};
  final Map<String, _MobileAgentRunOperation> _recoverableRunOperations =
      <String, _MobileAgentRunOperation>{};

  String? _catalogVersion;
  String? _catalogCacheRestoredScope;
  MobileAgentRunOutcome? _lastOutcome;
  bool _running = false;
  int _bindingGeneration = 0;
  int _catalogGeneration = 0;
  int _runGeneration = 0;
  bool _disposed = false;

  MobileAgentRuntimeIdentity get identity => _identity;
  String? get catalogVersion => _catalogVersion;
  bool get running => _running;
  MobileAgentRunOutcome? get lastOutcome => _lastOutcome;

  MobileAgentFeatureAccess accessFor(String featureId) =>
      _features[_featureKey(featureId)] ??
      MobileAgentFeatureAccess(
        featureId: featureId,
        status: MobileAgentFeatureStatus.idle,
      );

  /// Discards only this identity's public catalog after the main API has
  /// explicitly rejected a public Agent Profile. Transport failures and
  /// unrelated product services must not invalidate capability state.
  void invalidateCatalogCache() {
    final preferences = _preferences;
    if (_identity.isReady && preferences != null) {
      try {
        preferences.deleteValue(
          _catalogPreferenceKey(_catalogCacheScope(_identity)),
        );
      } on Object {
        // A failed cache deletion is harmless: in-memory state is still reset.
      }
    }
    _clearCatalog();
    _notify();
  }

  void bindIdentity(MobileAgentRuntimeIdentity identity) {
    if (_identity.bindingKey == identity.bindingKey &&
        _identity.locale == identity.locale &&
        _identity.timezone == identity.timezone) {
      return;
    }
    _identity = identity;
    _bindingGeneration += 1;
    _runGeneration += 1;
    _clearCatalog();
    _running = false;
    _lastOutcome = null;
    _notify();
  }

  Future<MobileAgentFeatureAccess> ensureFeature(
    String featureId, {
    bool forceRefresh = false,
  }) {
    final normalizedFeature = featureId.trim();
    final key = _featureKey(normalizedFeature);
    if (forceRefresh) {
      _catalogGeneration += 1;
      _profiles = null;
      _features.clear();
      _pendingFeatures.clear();
    }
    if (!forceRefresh) {
      final current = _features[key];
      if (current != null &&
          current.status != MobileAgentFeatureStatus.idle &&
          current.status != MobileAgentFeatureStatus.loading) {
        return Future<MobileAgentFeatureAccess>.value(current);
      }
      final pending = _pendingFeatures[key];
      if (pending != null) return pending;
    }
    final bindingGeneration = _bindingGeneration;
    final catalogGeneration = _catalogGeneration;
    final future =
        _resolveFeature(
          normalizedFeature,
          bypassPersistentCache: forceRefresh,
        ).onError((error, stackTrace) {
          if (!_catalogRequestIsCurrent(bindingGeneration, catalogGeneration)) {
            return _supersededFeature(normalizedFeature);
          }
          return _storeFeature(
            key,
            MobileAgentFeatureAccess(
              featureId: normalizedFeature,
              status: MobileAgentFeatureStatus.failed,
              catalogVersion: _catalogVersion,
              errorCode: 'AGENT_CATALOG_REQUEST_FAILED',
            ),
          );
        });
    _pendingFeatures[key] = future;
    return future.whenComplete(() {
      if (identical(_pendingFeatures[key], future)) {
        _pendingFeatures.remove(key);
      }
    });
  }

  Future<MobileAgentRunOutcome> execute(
    MobileAgentRunCommand command, {
    MobileAgentRunPollingPolicy? pollingPolicy,
    void Function(AgentRunSnapshot)? onProgress,
  }) {
    if (pollingPolicy != null &&
        (pollingPolicy.maxAttempts < 1 ||
            pollingPolicy.initialInterval.isNegative ||
            pollingPolicy.maxInterval < pollingPolicy.initialInterval)) {
      throw ArgumentError('Invalid Agent run polling policy');
    }
    final runGeneration = ++_runGeneration;
    final operation = _MobileAgentRunOperation(
      generation: runGeneration,
      operationId: command.operationId,
      cancelIdempotencyKey: _stableCancelIdempotencyKey(command, _identity),
    );
    _runOperations[runGeneration] = operation;
    final future =
        _execute(
          command,
          runGeneration,
          operation,
          pollingPolicy: pollingPolicy,
          onProgress: onProgress,
        ).onError((error, stackTrace) {
          if (operation.cancelRequested) return _superseded();
          return _finishRun(
            runGeneration,
            const MobileAgentRunOutcome(
              status: MobileAgentRunStatus.failed,
              errorCode: 'AGENT_RUNTIME_REQUEST_FAILED',
            ),
          );
        });
    return future.then((outcome) {
      if (identical(_runOperations[runGeneration], operation)) {
        _runOperations.remove(runGeneration);
      }
      _settleOperationTracking(operation, outcome);
      return outcome;
    });
  }

  Future<bool> cancelOperation(String operationId) async {
    final normalized = operationId.trim();
    if (normalized.isEmpty) return true;
    final matching = <_MobileAgentRunOperation>{
      ..._runOperations.values.where(
        (operation) => operation.operationId == normalized,
      ),
      if (_recoverableRunOperations[normalized] case final recovered?)
        recovered,
    }.toList(growable: false);
    if (matching.isEmpty) return true;

    var invalidatedCurrentRun = false;
    for (final operation in matching) {
      operation.cancelRequested = true;
      if (!_disposed && operation.generation == _runGeneration) {
        _runGeneration += 1;
        _running = false;
        invalidatedCurrentRun = true;
      }
    }
    if (invalidatedCurrentRun) _notify();
    final reconciled = await Future.wait(matching.map(_reconcileCancellation));
    for (var index = 0; index < matching.length; index++) {
      final operation = matching[index];
      if (reconciled[index] &&
          identical(
            _recoverableRunOperations[operation.operationId],
            operation,
          )) {
        _recoverableRunOperations.remove(operation.operationId);
      }
    }
    return reconciled.every((resolved) => resolved);
  }

  Future<MobileAgentRunOutcome> _execute(
    MobileAgentRunCommand command,
    int runGeneration,
    _MobileAgentRunOperation operation, {
    MobileAgentRunPollingPolicy? pollingPolicy,
    void Function(AgentRunSnapshot)? onProgress,
  }) async {
    final bindingGeneration = _bindingGeneration;
    if (!_identity.isReady) {
      return _finishRun(
        runGeneration,
        MobileAgentRunOutcome(
          status: MobileAgentRunStatus.failed,
          errorCode: _identity.unavailableErrorCode,
        ),
      );
    }
    if (_isProhibitedFeature(command.featureId)) {
      return _finishRun(
        runGeneration,
        const MobileAgentRunOutcome(
          status: MobileAgentRunStatus.failed,
          errorCode: 'AGENT_FEATURE_PROHIBITED',
        ),
      );
    }

    _running = true;
    _lastOutcome = null;
    _notify();
    final access = await ensureFeature(command.featureId);
    if (!_isCurrent(bindingGeneration, runGeneration)) {
      return _superseded();
    }
    if (!access.isAvailable || access.availability?.route == null) {
      return _finishRun(
        runGeneration,
        MobileAgentRunOutcome(
          status: MobileAgentRunStatus.failed,
          errorCode:
              access.errorCode ??
              access.availability?.reasonCode ??
              'AGENT_FEATURE_UNAVAILABLE',
        ),
      );
    }

    late final AgentRunRequest request;
    try {
      final input = SharedAgentInput(
        content: <SharedAgentInputContent>[
          SharedAgentTextContent(text: command.visibleText),
          if (command.additionalText != null)
            SharedAgentTextContent(text: command.additionalText!),
          if (command.supplementalText != null)
            SharedAgentTextContent(text: command.supplementalText!),
          for (final reference in command.references) reference.toShared(),
        ],
      );
      final route = access.availability!.route!;
      request = AgentRunRequest(
        workspaceId: _identity.workspaceId!,
        threadId: command.threadId,
        agentProfileId: route.agentProfileId,
        locale: _identity.locale,
        timezone: _identity.timezone,
        input: input,
      );
    } on ArgumentError {
      return _finishRun(
        runGeneration,
        const MobileAgentRunOutcome(
          status: MobileAgentRunStatus.failed,
          errorCode: 'AGENT_INPUT_REFERENCE_INVALID',
        ),
      );
    }

    final idempotencyKey = _stableIdempotencyKey(command, _identity);
    operation
      ..createRequest = request
      ..createIdempotencyKey = idempotencyKey
      ..createStarted = true;
    final recovered = pollingPolicy == null
        ? null
        : _recoverableRunOperations[command.operationId];
    final canResume =
        recovered?.agentRunId != null && !recovered!.cancelRequested;
    if (canResume) {
      if (recovered.createIdempotencyKey != idempotencyKey ||
          jsonEncode(recovered.createRequest?.toJson()) !=
              jsonEncode(request.toJson())) {
        return _finishRun(
          runGeneration,
          const MobileAgentRunOutcome(
            status: MobileAgentRunStatus.failed,
            errorCode: 'AGENT_RUN_RESUME_MISMATCH',
          ),
        );
      }
      operation
        ..agentRunId = recovered.agentRunId
        ..lastSnapshot = recovered.lastSnapshot;
    }
    Future<ApiResult<AgentRunSnapshot>> obtainRun() => canResume
        ? _callPort<AgentRunSnapshot>(
            () => _port.run(operation.agentRunId!),
            'AGENT_RUN_POLL_FAILED',
          )
        : _submitRunCreate(operation, request, idempotencyKey);
    var created = await obtainRun();
    if (!created.ok && created.error?.isRetryable == true) {
      await _delay(_retryInterval);
      if (!_isCurrent(bindingGeneration, runGeneration)) {
        if (operation.cancelRequested) {
          await _reconcileCancellation(operation);
        }
        return _superseded();
      }
      created = await obtainRun();
    }
    final createdRun = created.data;
    if (createdRun != null) {
      if (operation.cancelRequested) {
        await _reconcileCancellation(operation);
        return _superseded();
      }
    }
    if (!_isCurrent(bindingGeneration, runGeneration)) {
      if (operation.cancelRequested) {
        await _reconcileCancellation(operation);
      }
      return _superseded();
    }
    if (!created.ok || created.data == null) {
      return _finishRun(
        runGeneration,
        MobileAgentRunOutcome(
          status: MobileAgentRunStatus.failed,
          run: operation.lastSnapshot,
          errorCode:
              created.error?.code ??
              (canResume ? 'AGENT_RUN_POLL_FAILED' : 'AGENT_RUN_CREATE_FAILED'),
        ),
      );
    }
    var run = createdRun!;
    if (canResume && run.agentRunId != operation.agentRunId) {
      return _finishRun(
        runGeneration,
        MobileAgentRunOutcome(
          status: MobileAgentRunStatus.failed,
          run: operation.lastSnapshot,
          errorCode: 'AGENT_RUN_POLL_MISMATCH',
        ),
      );
    }
    if (run.workspaceId != _identity.workspaceId ||
        (command.threadId != null && run.threadId != command.threadId)) {
      return _finishRun(
        runGeneration,
        MobileAgentRunOutcome(
          status: MobileAgentRunStatus.failed,
          run: canResume ? operation.lastSnapshot : null,
          errorCode: 'AGENT_RUN_WORKSPACE_MISMATCH',
        ),
      );
    }

    operation.lastSnapshot = run;
    onProgress?.call(run);
    var transientFailures = 0;
    for (
      var attempt = 0;
      !run.isTerminal &&
          attempt < (pollingPolicy?.maxAttempts ?? _maxPollAttempts);
      attempt++
    ) {
      await _delay(pollingPolicy?.intervalFor(attempt) ?? _pollInterval);
      if (!_isCurrent(bindingGeneration, runGeneration)) return _superseded();
      final polled = await _callPort<AgentRunSnapshot>(
        () => _port.run(run.agentRunId),
        'AGENT_RUN_POLL_FAILED',
      );
      if (!polled.ok || polled.data == null) {
        if (polled.error?.isRetryable == true &&
            transientFailures < _maxTransientFailures) {
          transientFailures += 1;
          await _delay(_retryInterval);
          continue;
        }
        return _finishRun(
          runGeneration,
          MobileAgentRunOutcome(
            status: MobileAgentRunStatus.failed,
            run: run,
            errorCode: polled.error?.code ?? 'AGENT_RUN_POLL_FAILED',
          ),
        );
      }
      final next = polled.data!;
      if (next.agentRunId != run.agentRunId ||
          next.workspaceId != _identity.workspaceId ||
          (command.threadId != null && next.threadId != command.threadId)) {
        return _finishRun(
          runGeneration,
          MobileAgentRunOutcome(
            status: MobileAgentRunStatus.failed,
            run: pollingPolicy == null ? next : run,
            errorCode: 'AGENT_RUN_POLL_MISMATCH',
          ),
        );
      }
      transientFailures = 0;
      final statusChanged = run.status != next.status;
      run = next;
      operation.lastSnapshot = run;
      if (statusChanged) onProgress?.call(run);
    }
    if (!_isCurrent(bindingGeneration, runGeneration)) return _superseded();
    if (!run.isTerminal) {
      return _finishRun(
        runGeneration,
        MobileAgentRunOutcome(
          status: MobileAgentRunStatus.failed,
          run: run,
          errorCode: 'AGENT_RUN_POLL_TIMEOUT',
        ),
      );
    }
    final terminalError = _terminalFailure(run);
    if (terminalError != null) {
      return _finishRun(
        runGeneration,
        MobileAgentRunOutcome(
          status: MobileAgentRunStatus.failed,
          run: run,
          errorCode: terminalError,
        ),
      );
    }

    final usageResult = await _callPort<SharedRunUsage>(
      () => _port.runUsage(run.agentRunId),
      'AGENT_RUN_USAGE_FAILED',
    );
    if (!_isCurrent(bindingGeneration, runGeneration)) return _superseded();
    final usage = usageResult.ok && usageResult.data?.runId == run.agentRunId
        ? usageResult.data
        : null;
    return _finishRun(
      runGeneration,
      MobileAgentRunOutcome(
        status: MobileAgentRunStatus.succeeded,
        run: run,
        usage: usage,
        usageErrorCode: usage == null
            ? usageResult.error?.code ?? 'AGENT_RUN_USAGE_MISMATCH'
            : null,
      ),
    );
  }

  Future<MobileAgentFeatureAccess> _resolveFeature(
    String featureId, {
    required bool bypassPersistentCache,
  }) async {
    final key = _featureKey(featureId);
    if (_isProhibitedFeature(featureId)) {
      return _storeFeature(
        key,
        MobileAgentFeatureAccess(
          featureId: featureId,
          status: MobileAgentFeatureStatus.unavailable,
          errorCode: 'AGENT_FEATURE_PROHIBITED',
        ),
      );
    }
    if (!_identity.isReady) {
      return _storeFeature(
        key,
        MobileAgentFeatureAccess(
          featureId: featureId,
          status: MobileAgentFeatureStatus.unavailable,
          errorCode: _identity.unavailableErrorCode,
        ),
      );
    }
    final route = AgentFeatureRoutes.forFeature(featureId);
    if (route == null) {
      return _storeFeature(
        key,
        MobileAgentFeatureAccess(
          featureId: featureId,
          status: MobileAgentFeatureStatus.unavailable,
          errorCode: 'AGENT_FEATURE_ROUTE_UNKNOWN',
        ),
      );
    }
    final generation = _bindingGeneration;
    final catalogGeneration = _catalogGeneration;
    _features[key] = MobileAgentFeatureAccess(
      featureId: featureId,
      status: MobileAgentFeatureStatus.loading,
      catalogVersion: _catalogVersion,
    );
    _notify();

    if (!bypassPersistentCache) {
      _restoreFreshCatalogCache();
    }

    final profilesResult = _profiles == null
        ? await _callPort<AgentProfileCatalog>(
            _port.profiles,
            'AGENT_PROFILE_CATALOG_FAILED',
          )
        : null;
    if (!_catalogRequestIsCurrent(generation, catalogGeneration)) {
      return _supersededFeature(featureId);
    }
    if (profilesResult != null) {
      if (!profilesResult.ok || profilesResult.data == null) {
        return _featureFailure(key, featureId, profilesResult);
      }
      final nextProfiles = profilesResult.data!;
      if (_catalogVersion != null &&
          _catalogVersion != nextProfiles.catalogVersion) {
        _features.clear();
      }
      _profiles = nextProfiles;
      _catalogVersion = nextProfiles.catalogVersion;
      _persistPublicCatalog(nextProfiles);
    }

    final availability = AgentFeatureAvailabilityResolver.resolve(
      route: route,
      profiles: _profiles!,
    );
    return _storeFeature(
      key,
      MobileAgentFeatureAccess(
        featureId: featureId,
        status: availability.isAvailable
            ? MobileAgentFeatureStatus.available
            : MobileAgentFeatureStatus.unavailable,
        catalogVersion: _catalogVersion,
        availability: availability,
        errorCode: availability.reasonCode,
      ),
    );
  }

  MobileAgentFeatureAccess _featureFailure(
    String key,
    String featureId,
    ApiResult<dynamic> result,
  ) => _storeFeature(
    key,
    MobileAgentFeatureAccess(
      featureId: featureId,
      status: MobileAgentFeatureStatus.failed,
      catalogVersion: _catalogVersion,
      errorCode: result.error?.code ?? 'AGENT_CATALOG_UNAVAILABLE',
    ),
  );

  MobileAgentFeatureAccess _storeFeature(
    String key,
    MobileAgentFeatureAccess access,
  ) {
    if (!_disposed) {
      _features[key] = access;
      _notify();
    }
    return access;
  }

  MobileAgentFeatureAccess _supersededFeature(String featureId) =>
      MobileAgentFeatureAccess(
        featureId: featureId,
        status: MobileAgentFeatureStatus.failed,
        errorCode: 'AGENT_CATALOG_REQUEST_SUPERSEDED',
      );

  MobileAgentRunOutcome _finishRun(
    int generation,
    MobileAgentRunOutcome outcome,
  ) {
    if (!_disposed && generation == _runGeneration) {
      _running = false;
      _lastOutcome = outcome;
      _notify();
    }
    return outcome;
  }

  MobileAgentRunOutcome _superseded() => const MobileAgentRunOutcome(
    status: MobileAgentRunStatus.superseded,
    errorCode: 'AGENT_RUN_SUPERSEDED',
  );

  bool _bindingIsCurrent(int generation) =>
      !_disposed && generation == _bindingGeneration;

  bool _catalogRequestIsCurrent(int bindingGeneration, int catalogGeneration) =>
      _bindingIsCurrent(bindingGeneration) &&
      catalogGeneration == _catalogGeneration;

  bool _isCurrent(int bindingGeneration, int runGeneration) =>
      _bindingIsCurrent(bindingGeneration) && runGeneration == _runGeneration;

  void _recordCreateOutcome(
    _MobileAgentRunOperation operation,
    ApiResult<AgentRunSnapshot> result,
  ) {
    final run = result.data;
    if (run != null) {
      operation
        ..agentRunId = run.agentRunId
        ..lastSnapshot = run
        ..createOutcomeUnknown = false;
      return;
    }
    operation.createOutcomeUnknown = _remoteWriteOutcomeIsUnknown(result);
  }

  Future<ApiResult<AgentRunSnapshot>> _submitRunCreate(
    _MobileAgentRunOperation operation,
    AgentRunRequest request,
    String idempotencyKey,
  ) async {
    final inFlight = operation.createInFlight;
    if (inFlight != null) {
      final result = await inFlight;
      _recordCreateOutcome(operation, result);
      return result;
    }
    final future = _callPort<AgentRunSnapshot>(
      () => _port.createRun(request, idempotencyKey: idempotencyKey),
      'AGENT_RUN_CREATE_FAILED',
    );
    operation.createInFlight = future;
    try {
      final result = await future;
      _recordCreateOutcome(operation, result);
      return result;
    } finally {
      if (identical(operation.createInFlight, future)) {
        operation.createInFlight = null;
      }
    }
  }

  void _settleOperationTracking(
    _MobileAgentRunOperation operation,
    MobileAgentRunOutcome outcome,
  ) {
    if (outcome.errorCode == 'AGENT_RUN_RESUME_MISMATCH') return;
    final recoverable =
        operation.createOutcomeUnknown ||
        (operation.agentRunId != null &&
            outcome.status == MobileAgentRunStatus.failed &&
            outcome.run?.isTerminal == false);
    if (recoverable) {
      _recoverableRunOperations[operation.operationId] = operation;
      return;
    }
    _recoverableRunOperations.remove(operation.operationId);
  }

  Future<bool> _reconcileCancellation(
    _MobileAgentRunOperation operation,
  ) async {
    if (operation.agentRunId != null) {
      await _cancelKnownRun(operation);
      return true;
    }
    final inFlight = operation.createInFlight;
    if (inFlight != null) {
      _recordCreateOutcome(operation, await inFlight);
      if (operation.agentRunId != null) {
        await _cancelKnownRun(operation);
        return true;
      }
    }
    if (!operation.createStarted || !operation.createOutcomeUnknown) {
      return true;
    }
    final request = operation.createRequest;
    final idempotencyKey = operation.createIdempotencyKey;
    if (request == null || idempotencyKey == null) return false;
    await _submitRunCreate(operation, request, idempotencyKey);
    if (operation.agentRunId != null) {
      await _cancelKnownRun(operation);
      return true;
    }
    return !operation.createOutcomeUnknown;
  }

  Future<void> _cancelKnownRun(_MobileAgentRunOperation operation) async {
    final runId = operation.agentRunId;
    final port = _port;
    if (runId == null || operation.cancelDispatched) return;
    if (port is! MobileAgentRunCancellationPort) return;
    final cancellationPort = port as MobileAgentRunCancellationPort;
    operation.cancelDispatched = true;
    try {
      await cancellationPort.cancelRun(
        runId,
        idempotencyKey: operation.cancelIdempotencyKey,
      );
    } on Object {
      // Remote cancellation is cleanup; local generation invalidation wins.
    }
  }

  void _clearCatalog() {
    _catalogGeneration += 1;
    _profiles = null;
    _catalogVersion = null;
    _catalogCacheRestoredScope = null;
    _features.clear();
    _pendingFeatures.clear();
  }

  void _restoreFreshCatalogCache() {
    if (_profiles != null || !_identity.isReady) return;
    final preferences = _preferences;
    if (preferences == null) return;
    final scope = _catalogCacheScope(_identity);
    if (_catalogCacheRestoredScope == scope) return;
    _catalogCacheRestoredScope = scope;
    final raw = preferences.readValue(_catalogPreferenceKey(scope));
    if (raw == null) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final schemaVersion = decoded['schemaVersion'];
      final savedAtRaw = decoded['savedAt'];
      final catalogVersion = decoded['catalogVersion'];
      final rawItems = decoded['items'];
      if (schemaVersion != 1 ||
          savedAtRaw is! String ||
          !_isSafeCatalogToken(catalogVersion) ||
          rawItems is! List) {
        return;
      }
      final savedAt = DateTime.tryParse(savedAtRaw)?.toUtc();
      if (savedAt == null ||
          _now().toUtc().difference(savedAt) > _catalogCacheTtl) {
        return;
      }
      final items = <AgentProfileCatalogItem>[];
      for (final rawItem in rawItems) {
        final item = _cachedCatalogItem(rawItem);
        if (item == null) return;
        items.add(item);
      }
      if (items.isEmpty) return;
      _profiles = AgentProfileCatalog(
        catalogVersion: catalogVersion.trim(),
        items: List<AgentProfileCatalogItem>.unmodifiable(items),
      );
      _catalogVersion = catalogVersion.trim();
    } on Object {
      // A malformed local cache is treated as absent. Network admission remains
      // the authority for a new or expired catalog.
    }
  }

  void _persistPublicCatalog(AgentProfileCatalog catalog) {
    final preferences = _preferences;
    if (preferences == null || !_identity.isReady) return;
    final catalogVersion = catalog.catalogVersion.trim();
    if (!_isSafeCatalogToken(catalogVersion)) return;
    final items = <Map<String, Object?>>[];
    for (final item in catalog.items) {
      final id = item.agentProfileId.trim();
      final displayName = _safeCatalogDisplayText(item.displayName);
      final description = _safeCatalogDescription(item.description);
      final iconResourceId = item.icon?.resourceId?.trim();
      if (!_isSafeCatalogToken(id) || displayName == null) return;
      if (iconResourceId != null && !_isSafeCatalogToken(iconResourceId)) {
        return;
      }
      items.add(<String, Object?>{
        'agentProfileId': id,
        'displayName': displayName,
        if (description != null) 'description': description,
        if (iconResourceId != null) 'iconResourceId': iconResourceId,
      });
    }
    if (items.isEmpty) return;
    final scope = _catalogCacheScope(_identity);
    try {
      preferences.upsertValue(
        preferenceKey: _catalogPreferenceKey(scope),
        value: jsonEncode(<String, Object?>{
          'schemaVersion': 1,
          'savedAt': _now().toUtc().toIso8601String(),
          'catalogVersion': catalogVersion,
          'items': items,
        }),
        updatedAt: _now().toUtc().toIso8601String(),
      );
    } on Object {
      // Persistence is an optimization and must not affect agent admission.
    }
  }

  AgentProfileCatalogItem? _cachedCatalogItem(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['agentProfileId'];
    final displayName = raw['displayName'];
    final description = raw['description'];
    final iconResourceId = raw['iconResourceId'];
    if (!_isSafeCatalogToken(id) ||
        _safeCatalogDisplayText(displayName) == null ||
        (description != null && _safeCatalogDescription(description) == null) ||
        (iconResourceId != null && !_isSafeCatalogToken(iconResourceId))) {
      return null;
    }
    return AgentProfileCatalogItem(
      agentProfileId: (id as String).trim(),
      displayName: (displayName as String).trim(),
      description: description is String ? description.trim() : null,
      icon: iconResourceId is String
          ? AgentProfileIcon(resourceId: iconResourceId.trim())
          : null,
    );
  }

  Duration get _catalogCacheTtl {
    final value = _catalogCacheTtlResolver?.call();
    if (value == null ||
        value <= Duration.zero ||
        value > const Duration(days: 1)) {
      return const Duration(seconds: 300);
    }
    return value;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<ApiResult<T>> _callPort<T>(
    Future<ApiResult<T>> Function() call,
    String errorCode,
  ) async {
    try {
      return await call();
    } catch (error) {
      return ApiResult<T>.failure(
        error: AppFailure(
          code: errorCode,
          category: AppFailureCategory.network,
          message: 'Mobile Agent request failed',
          userMessageKey: 'error.agent.requestFailed',
          isRetryable: true,
          recoveryActions: const <String>['retry', 'checkNetwork'],
          cause: error,
        ),
        idempotencyStore: SubmissionKeyStore.empty,
      );
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _bindingGeneration += 1;
    _runGeneration += 1;
    super.dispose();
  }
}

String _featureKey(String featureId) => featureId.trim();

String _catalogCacheScope(MobileAgentRuntimeIdentity identity) => sha256
    .convert(utf8.encode(identity.bindingKey))
    .toString()
    .substring(0, 24);

String _catalogPreferenceKey(String scope) => 'agent.catalog.v1.$scope';

bool _isSafeCatalogToken(Object? value) {
  if (value is! String) return false;
  return RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,159}$').hasMatch(value.trim());
}

String? _safeCatalogDisplayText(Object? value) {
  if (value is! String) return null;
  final normalized = value.trim();
  return normalized.isEmpty || normalized.length > 160 ? null : normalized;
}

String? _safeCatalogDescription(Object? value) {
  if (value is! String) return null;
  final normalized = value.trim();
  return normalized.isEmpty || normalized.length > 1000 ? null : normalized;
}

String _stableIdempotencyKey(
  MobileAgentRunCommand command,
  MobileAgentRuntimeIdentity identity,
) {
  final operation = command.operationId.replaceAll(
    RegExp(r'[^A-Za-z0-9._:-]'),
    '_',
  );
  final feature = command.featureId.replaceAll(
    RegExp(r'[^A-Za-z0-9._:-]'),
    '_',
  );
  final ownerDigest = sha256
      .convert(utf8.encode(identity.bindingKey))
      .toString()
      .substring(0, 16);
  return 'mobile-agent:$ownerDigest:$feature:$operation';
}

String _stableCancelIdempotencyKey(
  MobileAgentRunCommand command,
  MobileAgentRuntimeIdentity identity,
) {
  final digest = sha256
      .convert(
        utf8.encode(
          '${identity.bindingKey}\u0000${command.featureId}\u0000${command.operationId}',
        ),
      )
      .toString()
      .substring(0, 32);
  return 'mobile-agent-cancel:$digest';
}

bool _remoteWriteOutcomeIsUnknown(ApiResult<dynamic> result) {
  if (result.ok && result.data != null) return false;
  final failure = result.error;
  final code = failure?.code;
  final status = result.status;
  return status == null ||
      status == 408 ||
      status == 429 ||
      status >= 500 ||
      failure == null ||
      failure.category == AppFailureCategory.network ||
      failure.category == AppFailureCategory.compatibility ||
      code == 'API_SERVER_UNAVAILABLE' ||
      code == 'API_MALFORMED_ENVELOPE' ||
      code == 'API_RESPONSE_INVALID';
}

String? _terminalFailure(AgentRunSnapshot run) {
  if (run.status != 'succeeded') {
    return run.error?.code ?? 'AGENT_RUN_${run.status.toUpperCase()}';
  }
  if (!run.hasDurableAssistantResult ||
      run.result?.finalAnswer.trim().isEmpty != false) {
    return 'AGENT_RUN_DURABLE_RESULT_REQUIRED';
  }
  return switch (run.completionMode) {
    'normal' => null,
    'degraded' => 'AGENT_RUN_DEGRADED',
    'system_fallback' => 'AGENT_RUN_SYSTEM_FALLBACK',
    'cancelled' => 'AGENT_RUN_CANCELLED',
    _ => 'AGENT_RUN_COMPLETION_INVALID',
  };
}

bool _isProhibitedFeature(String featureId) {
  final normalized = featureId.trim().toLowerCase().replaceAll('-', '_');
  return normalized == 'work_ai' ||
      normalized.startsWith('work_ai.') ||
      normalized == 'feed_ai' ||
      normalized.startsWith('feed_ai.');
}

bool _containsUnsafeRunText(String value) {
  final lower = value.toLowerCase();
  return lower.contains('file://') ||
      lower.contains('/users/') ||
      lower.contains('\\users\\') ||
      lower.contains('begin private key') ||
      lower.contains('providersecret') ||
      lower.contains('objectkey=');
}

String? _normalizedOptional(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}
