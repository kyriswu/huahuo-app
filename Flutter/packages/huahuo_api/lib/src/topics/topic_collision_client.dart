import '../api/api_client.dart';
import '../api/api_envelope.dart';
import '../api/idempotency.dart';

const _topicCollisionTerminalStatuses = <String>{
  'succeeded',
  'failed',
  'dead_letter',
};

const topicCollisionStatuses = <String>{
  'queued',
  'leased',
  'admitting',
  'running',
  'retry_wait',
  ..._topicCollisionTerminalStatuses,
};

final class TopicCollisionSource {
  const TopicCollisionSource({required this.inputRef, this.title});

  factory TopicCollisionSource.fromJson(Map<String, Object?> json) {
    return TopicCollisionSource(
      inputRef: _requiredId(json, 'inputRef'),
      title: _optionalText(json, 'title', maxLength: 500),
    );
  }

  final String inputRef;
  final String? title;
}

final class TopicCollisionRun {
  const TopicCollisionRun({
    required this.topicCollisionRunId,
    required this.status,
    required this.selectedNoteCount,
    this.sources = const <TopicCollisionSource>[],
    this.workspaceId,
    this.stage = '',
    this.attempt = 0,
    this.maxAttempts = 3,
    this.retryable = false,
    this.failureStage,
    this.outputNoteId,
    this.outputPartRevisionId,
    this.outputHash,
    this.failureCode,
  });

  factory TopicCollisionRun.fromJson(Map<String, Object?> json) {
    final count = json['selectedNoteCount'];
    final status = _requiredText(json, 'status');
    final outputNoteId = _optionalId(json, 'outputNoteId');
    final attempt = json['attempt'];
    final maxAttempts = json['maxAttempts'];
    if (count is! int ||
        count != 4 ||
        attempt is! int ||
        attempt < 0 ||
        maxAttempts is! int ||
        maxAttempts < 1 ||
        attempt > maxAttempts ||
        json['retryable'] is! bool ||
        !topicCollisionStatuses.contains(status) ||
        (status == 'succeeded' && outputNoteId == null)) {
      throw const FormatException('topic collision run is invalid');
    }
    return TopicCollisionRun(
      topicCollisionRunId: _requiredId(json, 'topicCollisionRunId'),
      status: status,
      selectedNoteCount: 4,
      workspaceId: _requiredId(json, 'workspaceId'),
      stage: _requiredText(json, 'stage', maxLength: 128),
      attempt: attempt,
      maxAttempts: maxAttempts,
      retryable: json['retryable']! as bool,
      failureStage: _optionalText(json, 'failureStage', maxLength: 128),
      outputNoteId: outputNoteId,
      failureCode: _optionalText(json, 'failureCode', maxLength: 128),
    );
  }

  final String topicCollisionRunId;
  final String? workspaceId;
  final String stage;
  final int attempt;
  final int maxAttempts;
  final bool retryable;
  final String? failureStage;
  final String status;
  final int selectedNoteCount;
  final List<TopicCollisionSource> sources;
  final String? outputNoteId;
  final String? outputPartRevisionId;
  final String? outputHash;
  final String? failureCode;

  bool get isTerminal => _topicCollisionTerminalStatuses.contains(status);
  bool get isSuccessful => status == 'succeeded';

  Map<String, Object?> toJson() => <String, Object?>{
    'topicCollisionRunId': topicCollisionRunId,
    'workspaceId': workspaceId,
    'status': status,
    'stage': stage,
    'selectedNoteCount': selectedNoteCount,
    'attempt': attempt,
    'maxAttempts': maxAttempts,
    'retryable': retryable,
    if (outputNoteId != null) 'outputNoteId': outputNoteId,
    if (failureCode != null) 'failureCode': failureCode,
    if (failureStage != null) 'failureStage': failureStage,
  };
}

/// Production client for the server-owned four-note topic collision Run.
final class TopicCollisionClient {
  const TopicCollisionClient(this._api);

  final ApiClient _api;

  Future<ApiResult<TopicCollisionRun>> submit(
    String workspaceId, {
    required List<String> noteIds,
    required String idempotencyKey,
  }) => _api.request<TopicCollisionRun>(
    ApiRequestOptions<TopicCollisionRun>(
      endpointId: 'createNoteTopicCollisionRun',
      pathParams: <String, Object>{'workspaceId': _id(workspaceId)},
      body: <String, Object?>{'noteIds': _noteIds(noteIds)},
      idempotency: IdempotencyRequestContext(explicitKey: idempotencyKey),
      parseData: _parseRun,
    ),
  );

  Future<ApiResult<TopicCollisionRun>> get(String workspaceId, String runId) =>
      _api.request<TopicCollisionRun>(
        ApiRequestOptions<TopicCollisionRun>(
          endpointId: 'noteTopicCollisionRun',
          pathParams: <String, Object>{
            'workspaceId': _id(workspaceId),
            'topicCollisionRunId': _id(runId),
          },
          parseData: _parseRun,
        ),
      );
}

List<String> _noteIds(List<String> values) {
  final ids = values.map(_id).toList(growable: false);
  if (ids.length != 4 || ids.toSet().length != 4) {
    throw ArgumentError.value(
      values,
      'noteIds',
      'requires four unique HNote IDs',
    );
  }
  return List<String>.unmodifiable(ids);
}

TopicCollisionRun? _parseRun(Object? value) {
  final root = asObjectMap(value);
  final run = root == null
      ? null
      : asObjectMap(root['topicCollisionRun']) ?? root;
  return run == null ? null : TopicCollisionRun.fromJson(run);
}

String _id(String value) {
  final normalized = value.trim();
  if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,255}$').hasMatch(normalized)) {
    throw ArgumentError.value(value, 'id', 'must be a public opaque id');
  }
  return normalized;
}

String _requiredId(Map<String, Object?> json, String key) =>
    _responseId(_requiredText(json, key));

String? _optionalId(Map<String, Object?> json, String key) {
  final value = _optionalText(json, key);
  return value == null ? null : _responseId(value);
}

String _responseId(String value) {
  if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,255}$').hasMatch(value)) {
    throw const FormatException('Invalid public response identity');
  }
  return value;
}

String _requiredText(
  Map<String, Object?> json,
  String key, {
  int maxLength = 1024,
}) {
  final value = _optionalText(json, key, maxLength: maxLength);
  if (value == null) throw FormatException('$key is required');
  return value;
}

String? _optionalText(
  Map<String, Object?> json,
  String key, {
  int maxLength = 1024,
}) {
  final value = json[key];
  if (value == null) return null;
  if (value is! String) throw FormatException('$key must be text');
  final normalized = value.trim();
  if (normalized.isEmpty || normalized.length > maxLength) {
    throw FormatException('$key is invalid');
  }
  return normalized;
}
