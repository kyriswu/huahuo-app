import 'package:huahuo_api/huahuo_api.dart';
import '../../chat/domain/chat_models.dart';

final class CreateFirstContentLineRequest {
  const CreateFirstContentLineRequest({
    required this.name,
    required this.industry,
    required this.accountGoal,
    required this.commonExpressions,
    this.targetAudience,
  });

  final String name;
  final String industry;
  final String accountGoal;
  final String? targetAudience;
  final List<String> commonExpressions;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'name': name,
      'industry': industry,
      'accountGoal': accountGoal,
      if (targetAudience != null) 'targetAudience': targetAudience,
      'commonExpressions': commonExpressions,
    };
  }

  Map<String, Object?> toInitialPositioningJson() {
    return <String, Object?>{
      'name': name,
      'industry': industry,
      'accountGoal': accountGoal,
      if (targetAudience != null) 'targetAudience': targetAudience,
    };
  }
}

final class OnboardingContentLine {
  const OnboardingContentLine({
    required this.contentLineId,
    required this.name,
    required this.industry,
    required this.status,
    required this.version,
    required this.isDefault,
    required this.isPlaceholder,
    this.accountGoal,
    this.targetAudience,
  });

  final String contentLineId;
  final String name;
  final String industry;
  final String status;
  final int version;
  final bool isDefault;
  final bool isPlaceholder;
  final String? accountGoal;
  final String? targetAudience;
}

final class CreateFirstContentLineResult {
  const CreateFirstContentLineResult({
    required this.contentLine,
    required this.onboardingCompleted,
  });

  final OnboardingContentLine contentLine;
  final bool onboardingCompleted;
}

final class OnboardingDefaultContentLineRead {
  const OnboardingDefaultContentLineRead({this.contentLine});

  final OnboardingContentLine? contentLine;
}

final class InitialPositioningAttempt {
  const InitialPositioningAttempt({
    required this.workspaceId,
    required this.state,
    this.attemptId,
    this.agentRunId,
    this.failureCode,
    this.reportEvidence,
    this.createdAt,
    this.updatedAt,
    this.finalizedAt,
  });

  final String workspaceId;
  final String state;
  final String? attemptId;
  final String? agentRunId;
  final String? failureCode;
  final InitialPositioningReportEvidence? reportEvidence;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final DateTime? finalizedAt;

  bool get isCompleted => state == 'completed';
  bool get isFailure =>
      state == 'failed_retryable' ||
      state == 'failed_terminal' ||
      state == 'cancelled' ||
      state == 'superseded';
  bool get isNotStarted => state == 'not_started';

  bool get hasCommittedReportForTerminalGap {
    final evidence = reportEvidence;
    final startedAt = createdAt;
    final terminalAt = updatedAt;
    return state == 'failed_terminal' &&
        failureCode == 'AGENT_RUN_TERMINAL' &&
        evidence != null &&
        startedAt != null &&
        terminalAt != null &&
        !evidence.lastUpdated.isBefore(startedAt) &&
        !evidence.lastUpdated.isAfter(terminalAt);
  }
}

final class InitialPositioningReportEvidence {
  const InitialPositioningReportEvidence({required this.lastUpdated});

  final DateTime lastUpdated;
}

abstract interface class OnboardingApiPort {
  Future<ApiResult<CreateFirstContentLineResult>> createFirstContentLine({
    required CreateFirstContentLineRequest request,
    required IdempotencyRequestContext idempotency,
    SubmissionKeyStore idempotencyStore,
  });
}

abstract interface class OnboardingDefaultContentLineReadPort {
  Future<ApiResult<OnboardingDefaultContentLineRead>> readDefaultContentLine();
}

abstract interface class OnboardingInitialPositioningPort {
  Future<ApiResult<InitialPositioningAttempt>> createInitialPositioningAttempt({
    required String workspaceId,
    required String agentRunId,
  });

  Future<ApiResult<InitialPositioningAttempt>> currentInitialPositioning({
    required String workspaceId,
  });
}

final class OnboardingApi
    implements
        OnboardingApiPort,
        OnboardingDefaultContentLineReadPort,
        OnboardingInitialPositioningPort {
  const OnboardingApi({required ApiClient apiClient}) : _apiClient = apiClient;

  final ApiClient _apiClient;

  @override
  Future<ApiResult<CreateFirstContentLineResult>> createFirstContentLine({
    required CreateFirstContentLineRequest request,
    required IdempotencyRequestContext idempotency,
    SubmissionKeyStore idempotencyStore = SubmissionKeyStore.empty,
  }) {
    if (!_isValidCreateRequest(request)) {
      return Future<ApiResult<CreateFirstContentLineResult>>.value(
        _invalid<CreateFirstContentLineResult>(
          'ONBOARDING_CONTENT_LINE_INVALID',
        ),
      );
    }
    return _apiClient.request<CreateFirstContentLineResult>(
      ApiRequestOptions<CreateFirstContentLineResult>(
        endpointId: 'onboardingCreativePositioning',
        body: request.toJson(),
        idempotency: idempotency,
        idempotencyStore: idempotencyStore,
        parseData: parseCreateFirstContentLineResult,
      ),
    );
  }

  @override
  Future<ApiResult<OnboardingDefaultContentLineRead>> readDefaultContentLine() {
    return _apiClient.request<OnboardingDefaultContentLineRead>(
      ApiRequestOptions<OnboardingDefaultContentLineRead>(
        endpointId: 'creativePositionings',
        parseData: parseOnboardingDefaultContentLineRead,
      ),
    );
  }

  @override
  Future<ApiResult<InitialPositioningAttempt>> createInitialPositioningAttempt({
    required String workspaceId,
    required String agentRunId,
  }) {
    final safeWorkspaceId = _safeIdentifier(workspaceId);
    final safeAgentRunId = _safeAgentRunIdentifier(agentRunId);
    if (safeWorkspaceId == null || safeAgentRunId == null) {
      return Future<ApiResult<InitialPositioningAttempt>>.value(
        _invalid<InitialPositioningAttempt>('INITIAL_POSITIONING_INVALID'),
      );
    }
    return _apiClient.request<InitialPositioningAttempt>(
      ApiRequestOptions<InitialPositioningAttempt>(
        endpointId: 'createWorkspaceInitialPositioningAttempt',
        pathParams: <String, Object>{'workspaceId': safeWorkspaceId},
        body: <String, Object?>{'agentRunId': safeAgentRunId},
        idempotency: IdempotencyRequestContext(
          explicitKey: 'initial-positioning-$safeAgentRunId',
        ),
        parseData: (value) => parseInitialPositioningAttempt(
          value,
          expectedWorkspaceId: safeWorkspaceId,
          expectedAgentRunId: safeAgentRunId,
        ),
      ),
    );
  }

  @override
  Future<ApiResult<InitialPositioningAttempt>> currentInitialPositioning({
    required String workspaceId,
  }) {
    final safeWorkspaceId = _safeIdentifier(workspaceId);
    if (safeWorkspaceId == null) {
      return Future<ApiResult<InitialPositioningAttempt>>.value(
        _invalid<InitialPositioningAttempt>('INITIAL_POSITIONING_INVALID'),
      );
    }
    return _apiClient.request<InitialPositioningAttempt>(
      ApiRequestOptions<InitialPositioningAttempt>(
        endpointId: 'currentWorkspaceInitialPositioning',
        pathParams: <String, Object>{'workspaceId': safeWorkspaceId},
        parseData: (value) => parseInitialPositioningAttempt(
          value,
          expectedWorkspaceId: safeWorkspaceId,
        ),
      ),
    );
  }
}

CreateFirstContentLineRequest? buildCreateFirstContentLineRequest({
  required String name,
  required String industry,
  required String accountGoal,
  String? targetAudience,
  String commonExpressionsText = '',
}) {
  final safeName = _safeText(name, maximum: 240);
  final safeIndustry = _safeText(industry, maximum: 240);
  final safeAccountGoal = _safeText(accountGoal, maximum: 800);
  final trimmedAudience = targetAudience?.trim() ?? '';
  final safeAudience = trimmedAudience.isEmpty
      ? null
      : _safeText(trimmedAudience, maximum: 800);
  if (safeName == null ||
      safeIndustry == null ||
      safeAccountGoal == null ||
      (trimmedAudience.isNotEmpty && safeAudience == null)) {
    return null;
  }
  return CreateFirstContentLineRequest(
    name: safeName,
    industry: safeIndustry,
    accountGoal: safeAccountGoal,
    targetAudience: safeAudience,
    commonExpressions: normalizeCommonExpressions(commonExpressionsText),
  );
}

List<String> normalizeCommonExpressions(String value) {
  final output = <String>[];
  for (final raw in value.split(RegExp(r'[,\n\uFF0C\u3001]'))) {
    final text = _safeText(raw, maximum: 240);
    if (text != null && !output.contains(text)) output.add(text);
    if (output.length == 8) break;
  }
  return List<String>.unmodifiable(output);
}

CreateFirstContentLineResult? parseCreateFirstContentLineResult(Object? value) {
  if (_containsUnsafeValue(value)) return null;
  final root = asObjectMap(value);
  if (root == null) return null;
  final wrappedContentLine = root['creativePositioning'] ?? root['contentLine'];
  final isDirectProjection = wrappedContentLine == null;
  final contentLine = _parseContentLine(wrappedContentLine ?? root);
  final explicitCompletion = root['onboardingCompleted'];
  if (contentLine == null) return null;
  final onboardingCompleted = switch (explicitCompletion) {
    bool value => value,
    _
        when isDirectProjection &&
            contentLine.status == 'active' &&
            contentLine.isDefault &&
            !contentLine.isPlaceholder =>
      true,
    _ => null,
  };
  if (onboardingCompleted == null) return null;
  return CreateFirstContentLineResult(
    contentLine: contentLine,
    onboardingCompleted: onboardingCompleted,
  );
}

OnboardingDefaultContentLineRead? parseOnboardingDefaultContentLineRead(
  Object? value,
) {
  if (_containsUnsafeValue(value)) return null;
  final root = asObjectMap(value);
  final items = root?['items'];
  if (items is! List) return null;

  OnboardingContentLine? defaultContentLine;
  for (final rawItem in items) {
    final item = asObjectMap(rawItem);
    if (item == null) return null;
    final contentLine = _parseContentLine(item);
    if (contentLine == null || contentLine.status != 'active') return null;
    if (contentLine.isDefault && !contentLine.isPlaceholder) {
      if (defaultContentLine != null) return null;
      defaultContentLine = contentLine;
    }
  }
  return OnboardingDefaultContentLineRead(contentLine: defaultContentLine);
}

InitialPositioningAttempt? parseInitialPositioningAttempt(
  Object? value, {
  required String expectedWorkspaceId,
  String? expectedAgentRunId,
}) {
  if (_containsUnsafeValue(value)) return null;
  final object = asObjectMap(value);
  if (object == null ||
      object['schemaVersion'] != 'huahuo.initial-positioning.v1') {
    return null;
  }
  final workspaceId = _safeIdentifier(object['workspaceId']);
  final state = object['state'];
  final agentRunId = object['agentRunId'] == null
      ? null
      : _safeAgentRunIdentifier(object['agentRunId']);
  final attemptId = object['attemptId'] == null
      ? null
      : _safeInitialPositioningAttemptIdentifier(
          object['attemptId'],
          agentRunId: agentRunId,
        );
  final failureCode = object['failureCode'] == null
      ? null
      : _safeText(object['failureCode'], maximum: 160);
  final reportEvidence = _initialPositioningReportEvidence(object['progress']);
  final createdAt = _serverDateTime(object['createdAt']);
  final updatedAt = _serverDateTime(object['updatedAt']);
  final finalizedAt = _serverDateTime(object['finalizedAt']);
  const states = <String>{
    'not_started',
    'queued',
    'running',
    'finalizing',
    'completed',
    'failed_retryable',
    'failed_terminal',
    'cancelled',
    'superseded',
  };
  if (workspaceId != expectedWorkspaceId ||
      state is! String ||
      !states.contains(state) ||
      (object['attemptId'] != null && attemptId == null) ||
      (object['agentRunId'] != null && agentRunId == null) ||
      (object['failureCode'] != null && failureCode == null) ||
      (object['createdAt'] != null && createdAt == null) ||
      (object['updatedAt'] != null && updatedAt == null) ||
      (object['finalizedAt'] != null && finalizedAt == null) ||
      (expectedAgentRunId != null &&
          state != 'not_started' &&
          agentRunId != expectedAgentRunId)) {
    return null;
  }
  return InitialPositioningAttempt(
    workspaceId: workspaceId!,
    state: state,
    attemptId: attemptId,
    agentRunId: agentRunId,
    failureCode: failureCode,
    reportEvidence: reportEvidence,
    createdAt: createdAt,
    updatedAt: updatedAt,
    finalizedAt: finalizedAt,
  );
}

InitialPositioningReportEvidence? _initialPositioningReportEvidence(
  Object? value,
) {
  final progress = asObjectMap(value);
  if (progress == null ||
      progress['source'] != 'workspace_file' ||
      progress['available'] != true ||
      progress['schemaVersion'] != 'huahuo.positioning_profile.v1' ||
      progress['scoringModel'] != 'positioning_coverage_v4' ||
      progress['targetFile'] !=
          'profile/user-positioning/positioning-profile.md' ||
      _nonNegativeInt(progress['totalWeight']) != 100) {
    return null;
  }
  const expectedWeights = <String, int>{
    'credible_self': 10,
    'audience_person': 10,
    'value_destination': 10,
    'entry_scene': 10,
    'value_delivery': 10,
    'belief_framework': 10,
    'relationship_persona': 20,
    'visual_assets': 20,
  };
  final modules = progress['modules'];
  if (modules is! List || modules.length != expectedWeights.length) {
    return null;
  }
  final seen = <String>{};
  for (final raw in modules) {
    final module = asObjectMap(raw);
    final id = _safeIdentifier(module?['id']);
    final weight = _nonNegativeInt(module?['weight']);
    final score = _nonNegativeInt(module?['score']);
    final expectedWeight = id == null ? null : expectedWeights[id];
    if (id == null ||
        !seen.add(id) ||
        expectedWeight == null ||
        weight != expectedWeight ||
        score == null ||
        score > expectedWeight) {
      return null;
    }
  }
  final lastUpdated = _serverDateTime(progress['lastUpdated']);
  return lastUpdated == null
      ? null
      : InitialPositioningReportEvidence(lastUpdated: lastUpdated);
}

OnboardingContentLine? _parseContentLine(Object? value) {
  final map = asObjectMap(value);
  if (map == null) return null;
  final contentLineId = _safeIdentifier(
    map['creativePositioningId'] ?? map['contentLineId'],
  );
  final name = _safeText(map['name'], maximum: 240);
  final industry = _safeText(map['industry'], maximum: 240);
  final status = map['status'];
  final version = _nonNegativeInt(map['version']);
  final isDefault = map['isDefault'] ?? true;
  final isPlaceholder = map['isPlaceholder'] ?? false;
  if (contentLineId == null ||
      name == null ||
      industry == null ||
      (status != 'active' && status != 'inactive' && status != 'unknown') ||
      version == null ||
      isDefault is! bool ||
      isPlaceholder is! bool) {
    return null;
  }
  return OnboardingContentLine(
    contentLineId: contentLineId,
    name: name,
    industry: industry,
    status: status as String,
    version: version,
    isDefault: isDefault,
    isPlaceholder: isPlaceholder,
    accountGoal: _safeOptionalText(map['accountGoal'], maximum: 800),
    targetAudience: _safeOptionalText(map['targetAudience'], maximum: 800),
  );
}

bool _isValidCreateRequest(CreateFirstContentLineRequest request) {
  if (_safeText(request.name, maximum: 240) != request.name ||
      _safeText(request.industry, maximum: 240) != request.industry ||
      _safeText(request.accountGoal, maximum: 800) != request.accountGoal ||
      (request.targetAudience != null &&
          _safeText(request.targetAudience!, maximum: 800) !=
              request.targetAudience) ||
      request.commonExpressions.length > 8) {
    return false;
  }
  return request.commonExpressions.every(
    (item) => _safeText(item, maximum: 240) == item,
  );
}

int? _nonNegativeInt(Object? value) {
  if (value is int && value >= 0) return value;
  if (value is num && value >= 0 && value == value.roundToDouble()) {
    return value.toInt();
  }
  return null;
}

DateTime? _serverDateTime(Object? value) {
  if (value is! String ||
      value.isEmpty ||
      value.length > 64 ||
      value != value.trim() ||
      !RegExp(r'(?:Z|[+-]\d{2}:\d{2})$').hasMatch(value)) {
    return null;
  }
  return DateTime.tryParse(value)?.toUtc();
}

String? _safeIdentifier(Object? value) {
  final text = _safeText(value, maximum: 128);
  return text != null &&
          RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$').hasMatch(text)
      ? text
      : null;
}

String? _safeAgentRunIdentifier(Object? value) {
  final text = value is String ? value.trim() : null;
  return text != null &&
          isSafeAgentRunIdentifier(text) &&
          !_containsUnsafeValue(text)
      ? text
      : null;
}

String? _safeInitialPositioningAttemptIdentifier(
  Object? value, {
  required String? agentRunId,
}) {
  final text = value is String ? value.trim() : null;
  if (agentRunId != null && text == 'positioning_attempt_$agentRunId') {
    return text;
  }
  return _safeIdentifier(value);
}

String? _safeText(Object? value, {required int maximum}) {
  final text = value is String ? value.trim() : null;
  if (text == null || text.isEmpty || text.length > maximum) return null;
  return _unsafeValues.any((pattern) => pattern.hasMatch(text)) ? null : text;
}

String? _safeOptionalText(Object? value, {required int maximum}) {
  return value == null ? null : _safeText(value, maximum: maximum);
}

bool _containsUnsafeValue(Object? value) {
  if (value is String) {
    return _unsafeValues.any((pattern) => pattern.hasMatch(value));
  }
  if (value is List) return value.any(_containsUnsafeValue);
  final map = asObjectMap(value);
  if (map == null) return false;
  return map.entries.any(
    (entry) =>
        _unsafeKeys.any((pattern) => pattern.hasMatch(entry.key)) ||
        _containsUnsafeValue(entry.value),
  );
}

ApiResult<T> _invalid<T>(String code) {
  return ApiResult<T>.failure(
    error: AppFailure(
      code: code,
      category: AppFailureCategory.api,
      message: 'Onboarding request is invalid',
      userMessageKey: 'onboarding.api.error.$code',
    ),
    idempotencyStore: SubmissionKeyStore.empty,
  );
}

final _unsafeKeys = <RegExp>[
  RegExp(r'access.*token', caseSensitive: false),
  RegExp(r'refresh.*token', caseSensitive: false),
  RegExp(r'authorization', caseSensitive: false),
  RegExp(r'password', caseSensitive: false),
  RegExp(r'secret', caseSensitive: false),
  RegExp(r'provider', caseSensitive: false),
  RegExp(r'model.*key', caseSensitive: false),
  RegExp(r'api.*key', caseSensitive: false),
  RegExp(r'openclaw', caseSensitive: false),
  RegExp(r'runtime', caseSensitive: false),
  RegExp(r'workspace.*(real|path)', caseSensitive: false),
  RegExp(r'server.*path', caseSensitive: false),
  RegExp(r'local.*path', caseSensitive: false),
  RegExp(r'file.*path', caseSensitive: false),
  RegExp(r'^path$', caseSensitive: false),
  RegExp(r'markdown', caseSensitive: false),
  RegExp(r'transcript', caseSensitive: false),
];

final _unsafeValues = <RegExp>[
  RegExp(r'^file://', caseSensitive: false),
  RegExp(r'^[A-Za-z]:[\\/]'),
  RegExp(r'[\\/]Users[\\/]', caseSensitive: false),
  RegExp(r'/home/huahuo-runtime', caseSensitive: false),
  RegExp(r'/home/data/huahuo', caseSensitive: false),
  RegExp(r'runtime:tenant', caseSensitive: false),
  RegExp(r'openclaw', caseSensitive: false),
  RegExp(r'provider', caseSensitive: false),
  RegExp(r'model.*key', caseSensitive: false),
  RegExp(r'api.*key', caseSensitive: false),
  RegExp(r'secret', caseSensitive: false),
  RegExp(r'token', caseSensitive: false),
];
