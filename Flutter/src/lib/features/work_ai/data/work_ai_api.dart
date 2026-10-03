import '../../../core/api/api_client.dart';
import '../../../core/api/api_envelope.dart';
import '../../../core/api/idempotency.dart';

final class WorkAiContentLine {
  const WorkAiContentLine({required this.contentLineId, required this.name});

  final String contentLineId;
  final String name;
}

final class WorkAiMaterialCandidate {
  const WorkAiMaterialCandidate({
    required this.recordingId,
    required this.title,
    this.durationSeconds,
  });

  final String recordingId;
  final String title;
  final int? durationSeconds;
}

final class WorkAiQuotaSummary {
  const WorkAiQuotaSummary({
    this.asrRemainingMinutes,
    this.generationRemainingCount,
    this.warning,
  });

  final int? asrRemainingMinutes;
  final int? generationRemainingCount;
  final String? warning;
}

final class WorkAiTopicOptions {
  const WorkAiTopicOptions({
    required this.contentLines,
    required this.recentDays,
    required this.availableRecordingCount,
    required this.recentMaterialCandidates,
    required this.quota,
    this.defaultContentLineId,
    this.hotspotId,
    this.hotspotSuggestionId,
    this.hotspotTitle,
  });

  final List<WorkAiContentLine> contentLines;
  final String? defaultContentLineId;
  final int recentDays;
  final int availableRecordingCount;
  final List<WorkAiMaterialCandidate> recentMaterialCandidates;
  final WorkAiQuotaSummary quota;
  final String? hotspotId;
  final String? hotspotSuggestionId;
  final String? hotspotTitle;

  bool hasContentLine(String value) =>
      contentLines.any((line) => line.contentLineId == value);

  bool hasCandidate(String value) =>
      recentMaterialCandidates.any((item) => item.recordingId == value);
}

enum WorkAiMaterialScopeType { recent, manual }

final class WorkAiMaterialScope {
  const WorkAiMaterialScope.recent({required this.recentDays})
    : type = WorkAiMaterialScopeType.recent,
      recordingIds = const <String>[];

  const WorkAiMaterialScope.manual({required this.recordingIds})
    : type = WorkAiMaterialScopeType.manual,
      recentDays = null;

  final WorkAiMaterialScopeType type;
  final int? recentDays;
  final List<String> recordingIds;

  bool get isValid {
    return switch (type) {
      WorkAiMaterialScopeType.recent =>
        recentDays == 7 || recentDays == 14 || recentDays == 30,
      WorkAiMaterialScopeType.manual =>
        recordingIds.isNotEmpty && recordingIds.every(isSafeWorkAiIdentifier),
    };
  }

  Map<String, Object> toRequest() {
    return switch (type) {
      WorkAiMaterialScopeType.recent => <String, Object>{
        'type': 'recent',
        'recentDays': recentDays!,
      },
      WorkAiMaterialScopeType.manual => <String, Object>{
        'type': 'manual',
        'recordingIds': recordingIds,
      },
    };
  }
}

final class CreateWorkAiTopicInput {
  const CreateWorkAiTopicInput({
    required this.contentLineId,
    required this.materialScope,
    required this.idempotency,
    this.useHotspot = false,
    this.hotspotId,
    this.hotspotSuggestionId,
    this.supplement,
    this.source = 'work_ai_panel',
  });

  final String contentLineId;
  final WorkAiMaterialScope materialScope;
  final IdempotencyRequestContext idempotency;
  final bool useHotspot;
  final String? hotspotId;
  final String? hotspotSuggestionId;
  final String? supplement;
  final String source;

  bool get isValid =>
      isSafeWorkAiIdentifier(contentLineId) &&
      materialScope.isValid &&
      (!useHotspot || isSafeWorkAiIdentifier(hotspotId ?? '')) &&
      (hotspotSuggestionId == null ||
          isSafeWorkAiIdentifier(hotspotSuggestionId!)) &&
      _isSafeSource(source) &&
      _isSafeSupplement(supplement);

  Map<String, Object?> toRequest() {
    return <String, Object?>{
      'contentLineId': contentLineId,
      'materialScope': materialScope.toRequest(),
      'useHotspot': useHotspot,
      if (hotspotId != null) 'hotspotId': hotspotId,
      if (hotspotSuggestionId != null)
        'hotspotSuggestionId': hotspotSuggestionId,
      if (supplement != null && supplement!.trim().isNotEmpty)
        'supplement': supplement!.trim(),
      'source': source,
    };
  }
}

final class WorkAiTopicTask {
  const WorkAiTopicTask({
    required this.threadId,
    required this.taskId,
    required this.status,
  });

  final String threadId;
  final String taskId;
  final String status;
}

abstract interface class WorkAiApiPort {
  Future<ApiResult<WorkAiTopicOptions>> getTopicOptions({
    String? contentLineId,
  });

  Future<ApiResult<WorkAiTopicTask>> createTopicGeneration(
    CreateWorkAiTopicInput input, {
    SubmissionKeyStore idempotencyStore,
  });
}

final class WorkAiApi implements WorkAiApiPort {
  const WorkAiApi({required ApiClient apiClient});

  @override
  Future<ApiResult<WorkAiTopicOptions>> getTopicOptions({
    String? contentLineId,
  }) async => _prohibited<WorkAiTopicOptions>();

  @override
  Future<ApiResult<WorkAiTopicTask>> createTopicGeneration(
    CreateWorkAiTopicInput input, {
    SubmissionKeyStore idempotencyStore = SubmissionKeyStore.empty,
  }) async => _prohibited<WorkAiTopicTask>(idempotencyStore);
}

final class UnavailableWorkAiApi implements WorkAiApiPort {
  const UnavailableWorkAiApi();

  @override
  Future<ApiResult<WorkAiTopicOptions>> getTopicOptions({
    String? contentLineId,
  }) async => _prohibited<WorkAiTopicOptions>();

  @override
  Future<ApiResult<WorkAiTopicTask>> createTopicGeneration(
    CreateWorkAiTopicInput input, {
    SubmissionKeyStore idempotencyStore = SubmissionKeyStore.empty,
  }) async => _prohibited<WorkAiTopicTask>(idempotencyStore);
}

WorkAiTopicOptions? parseWorkAiTopicOptions(Object? value) {
  final object = asObjectMap(value);
  final defaults = object == null
      ? null
      : asObjectMap(object['materialScopeDefaults']);
  final rawContentLines = object?['contentLines'];
  final rawCandidates = object?['recentMaterialCandidates'];
  if (object == null ||
      defaults == null ||
      rawContentLines is! List ||
      rawCandidates is! List) {
    return null;
  }
  final recentDays = _recentDays(defaults['recentDays']);
  final availableRecordingCount = _nonNegativeInt(
    defaults['availableRecordingCount'],
  );
  if (recentDays == null || availableRecordingCount == null) return null;
  final contentLines = <WorkAiContentLine>[];
  for (final raw in rawContentLines) {
    final line = _parseContentLine(raw);
    if (line == null) return null;
    contentLines.add(line);
  }
  final candidates = <WorkAiMaterialCandidate>[];
  for (final raw in rawCandidates) {
    final candidate = _parseMaterialCandidate(raw);
    if (candidate == null) return null;
    candidates.add(candidate);
  }
  final quota = _parseQuota(object['quotaSummary'] ?? object['quota']);
  if (quota == null) return null;
  final hotspot = asObjectMap(object['hotspotSuggestion']);
  final hotspotId = hotspot == null
      ? null
      : _safeIdentifier(hotspot['hotspotId']);
  final hotspotSuggestionId = hotspot == null
      ? null
      : _safeIdentifier(hotspot['suggestionId']);
  if (hotspot != null &&
      (hotspotSuggestionId == null || _safeText(hotspot['title']) == null)) {
    return null;
  }
  final defaultContentLineId = _safeOptionalIdentifier(
    object['defaultContentLineId'],
  );
  if (object.containsKey('defaultContentLineId') &&
      defaultContentLineId == null) {
    return null;
  }
  return WorkAiTopicOptions(
    contentLines: List<WorkAiContentLine>.unmodifiable(contentLines),
    defaultContentLineId: defaultContentLineId,
    recentDays: recentDays,
    availableRecordingCount: availableRecordingCount,
    recentMaterialCandidates: List<WorkAiMaterialCandidate>.unmodifiable(
      candidates,
    ),
    quota: quota,
    hotspotId: hotspotId,
    hotspotSuggestionId: hotspotSuggestionId,
    hotspotTitle: hotspot == null ? null : _safeText(hotspot['title']),
  );
}

WorkAiTopicTask? parseWorkAiTopicTask(Object? value) {
  final object = asObjectMap(value);
  if (object == null) return null;
  final thread = asObjectMap(object['thread']);
  final task = asObjectMap(object['task']);
  final threadId = _safeIdentifier(thread?['threadId'] ?? object['threadId']);
  final taskId = _safeIdentifier(task?['taskId'] ?? object['taskId']);
  final status = _safeStatus(task?['status'] ?? object['status']);
  if (threadId == null || taskId == null || status == null) return null;
  return WorkAiTopicTask(threadId: threadId, taskId: taskId, status: status);
}

bool isSafeWorkAiIdentifier(String value) {
  return RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$').hasMatch(value);
}

ApiResult<T> _prohibited<T>([
  SubmissionKeyStore store = SubmissionKeyStore.empty,
]) {
  return ApiResult<T>.failure(
    error: const AppFailure(
      code: 'API_ENDPOINT_PROHIBITED',
      category: AppFailureCategory.api,
      message: 'Work AI is prohibited by the active API integration policy',
      userMessageKey: 'work_ai.api.waitingForReplacement',
      recoveryActions: <String>['none'],
    ),
    idempotencyStore: store,
  );
}

WorkAiContentLine? _parseContentLine(Object? value) {
  final object = asObjectMap(value);
  final contentLineId = object == null
      ? null
      : _safeIdentifier(object['contentLineId']);
  final name = object == null ? null : _safeText(object['name']);
  if (contentLineId == null || name == null) return null;
  return WorkAiContentLine(contentLineId: contentLineId, name: name);
}

WorkAiMaterialCandidate? _parseMaterialCandidate(Object? value) {
  final object = asObjectMap(value);
  if (object == null) return null;
  final recordingId = _safeIdentifier(object['recordingId']);
  final title = _safeText(object['title']);
  if (recordingId == null || title == null) return null;
  final depositStatus = object['depositStatus'];
  if (depositStatus != null && depositStatus != 'deposited') return null;
  return WorkAiMaterialCandidate(
    recordingId: recordingId,
    title: title,
    durationSeconds: _nonNegativeInt(object['durationSeconds']),
  );
}

WorkAiQuotaSummary? _parseQuota(Object? value) {
  final object = asObjectMap(value);
  if (object == null) return null;
  return WorkAiQuotaSummary(
    asrRemainingMinutes: _nonNegativeInt(object['asrRemainingMinutes']),
    generationRemainingCount: _nonNegativeInt(
      object['generationRemainingCount'],
    ),
    warning: _safeOptionalText(object['warning']),
  );
}

int? _recentDays(Object? value) {
  return value == 7 || value == 14 || value == 30 ? value as int : null;
}

int? _nonNegativeInt(Object? value) {
  if (value is int && value >= 0) return value;
  if (value is num && value >= 0 && value == value.roundToDouble()) {
    return value.toInt();
  }
  return null;
}

String? _safeIdentifier(Object? value) {
  final text = value is String ? value.trim() : null;
  return text != null && isSafeWorkAiIdentifier(text) ? text : null;
}

String? _safeOptionalIdentifier(Object? value) {
  if (value == null) return null;
  return _safeIdentifier(value);
}

String? _safeText(Object? value) {
  final text = value is String ? value.trim() : null;
  if (text == null || text.isEmpty || text.length > 240) return null;
  return _unsafeText.any((pattern) => pattern.hasMatch(text)) ? null : text;
}

String? _safeOptionalText(Object? value) {
  if (value == null) return null;
  return _safeText(value);
}

String? _safeStatus(Object? value) {
  final text = _safeText(value);
  return text != null && RegExp(r'^[a-z_]{2,64}$').hasMatch(text) ? text : null;
}

bool _isSafeSource(String value) {
  return value == 'work_ai_panel' || value == 'home_hotspot';
}

bool _isSafeSupplement(String? value) {
  return value == null || value.trim().isEmpty || _safeText(value) != null;
}

final _unsafeText = <RegExp>[
  RegExp(r'^file://', caseSensitive: false),
  RegExp(r'^[A-Za-z]:[\\/]'),
  RegExp(r'[\\/]Users[\\/]', caseSensitive: false),
  RegExp('workspace', caseSensitive: false),
  RegExp('provider', caseSensitive: false),
  RegExp('model.*key', caseSensitive: false),
  RegExp('token', caseSensitive: false),
  RegExp('secret', caseSensitive: false),
];
