import '../api/api_client.dart';
import '../api/api_envelope.dart';
import '../api/idempotency.dart';

final class WorkspacePositioningProgress {
  const WorkspacePositioningProgress({
    required this.schemaVersion,
    required this.source,
    required this.projectionVersion,
    required this.status,
    required this.validationStatus,
    required this.completedPercent,
    required this.coldStartPercent,
    required this.coldStartCompleted,
    required this.modules,
    required this.nextFocus,
    required this.updatedFiles,
    this.lastUpdated,
  });

  final String schemaVersion;
  final String source;
  final int projectionVersion;
  final String status;
  final String validationStatus;
  final int completedPercent;
  final int coldStartPercent;
  final bool coldStartCompleted;
  final List<WorkspacePositioningModule> modules;
  final List<WorkspacePositioningFocus> nextFocus;
  final List<String> updatedFiles;
  final DateTime? lastUpdated;
}

final class WorkspacePositioningModule {
  const WorkspacePositioningModule({
    required this.id,
    required this.label,
    required this.weight,
    required this.score,
    required this.state,
    required this.summary,
  });

  final String id;
  final String label;
  final int weight;
  final int score;
  final String state;
  final String summary;
}

final class WorkspacePositioningFocus {
  const WorkspacePositioningFocus({
    required this.title,
    required this.detail,
    this.moduleId,
  });

  final String title;
  final String detail;
  final String? moduleId;
}

/// Pure transport for the Workspace-file positioning projection.
final class PositioningProgressClient {
  const PositioningProgressClient(this._api);

  final ApiClient _api;

  Future<ApiConditionalResult<WorkspacePositioningProgress>> read({
    required String workspaceId,
    String? ifNoneMatch,
  }) {
    final normalizedWorkspaceId = _identifier(workspaceId);
    if (normalizedWorkspaceId == null) {
      return Future<ApiConditionalResult<WorkspacePositioningProgress>>.value(
        ApiConditionalResult<WorkspacePositioningProgress>.fromApiResult(
          ApiResult<WorkspacePositioningProgress>.failure(
            error: const AppFailure(
              code: 'WORKSPACE_ID_INVALID',
              category: AppFailureCategory.api,
              message: 'Workspace identifier is invalid',
              userMessageKey: 'error.api.responseInvalid',
              recoveryActions: <String>['none'],
            ),
            idempotencyStore: SubmissionKeyStore.empty,
          ),
        ),
      );
    }
    final etag = ifNoneMatch?.trim();
    return _api.requestConditional<WorkspacePositioningProgress>(
      ApiRequestOptions<WorkspacePositioningProgress>(
        endpointId: 'workspacePositioningProgress',
        pathParams: <String, Object>{'workspaceId': normalizedWorkspaceId},
        headers: <String, String>{
          if (etag != null && etag.isNotEmpty) 'If-None-Match': etag,
        },
        parseData: parseWorkspacePositioningProgress,
      ),
    );
  }
}

WorkspacePositioningProgress? parseWorkspacePositioningProgress(Object? value) {
  if (value is! Map) return null;
  final object = Map<String, Object?>.from(value);
  final schemaVersion = _text(object['schemaVersion']);
  final source = _text(object['source']);
  final available = object['available'];
  final projectionVersion = _positiveInt(object['projectionVersion']);
  final completedPercent = _percent(object['completedPercent']);
  final coldStartPercent = _percent(object['coldStartPercent']);
  final coldStartCompleted = object['coldStartCompleted'];
  if (schemaVersion != 'huahuo.positioning-progress.v1' ||
      source != 'workspace_file' ||
      available != true ||
      projectionVersion == null ||
      completedPercent == null ||
      coldStartPercent == null ||
      coldStartCompleted is! bool) {
    return null;
  }
  final modules = _modules(object['modules']);
  if (modules == null || modules.isEmpty) return null;
  final focus = _focus(object['nextFocus']);
  final updatedFiles = _texts(object['updatedFiles'], maximum: 12);
  if (focus == null || updatedFiles == null) return null;
  final updatedRaw = _text(object['lastUpdated']);
  final updatedAt = updatedRaw == null
      ? null
      : DateTime.tryParse(updatedRaw)?.toUtc();
  if (updatedRaw != null && updatedAt == null) return null;
  return WorkspacePositioningProgress(
    schemaVersion: schemaVersion!,
    source: source!,
    projectionVersion: projectionVersion,
    status: _text(object['status']) ?? 'draft',
    validationStatus: _text(object['validationStatus']) ?? 'unknown',
    completedPercent: completedPercent,
    coldStartPercent: coldStartPercent,
    coldStartCompleted: coldStartCompleted,
    modules: List<WorkspacePositioningModule>.unmodifiable(modules),
    nextFocus: List<WorkspacePositioningFocus>.unmodifiable(focus),
    updatedFiles: List<String>.unmodifiable(updatedFiles),
    lastUpdated: updatedAt,
  );
}

List<WorkspacePositioningModule>? _modules(Object? value) {
  if (value is! List || value.length > 32) return null;
  final result = <WorkspacePositioningModule>[];
  for (final raw in value) {
    if (raw is! Map) return null;
    final item = Map<String, Object?>.from(raw);
    final id = _identifier(item['id'] ?? item['moduleId']);
    final label = _text(item['label'] ?? item['moduleLabel'] ?? item['name']);
    final weight = _positiveInt(item['weight']) ?? 100;
    final score = _moduleScore(item, weight);
    final state = _text(item['state']) ?? 'unknown';
    if (id == null || label == null || score == null || score > weight) {
      return null;
    }
    result.add(
      WorkspacePositioningModule(
        id: id,
        label: label,
        weight: weight,
        score: score,
        state: state,
        summary: _text(item['summary'] ?? item['fullnessNote']) ?? '',
      ),
    );
  }
  return result;
}

int? _moduleScore(Map<String, Object?> item, int weight) {
  final direct = _nonNegativeInt(item['score']);
  if (direct != null) return direct;
  final percent = _percent(item['completedPercent'] ?? item['percent']);
  return percent == null ? 0 : (weight * percent / 100).round();
}

List<WorkspacePositioningFocus>? _focus(Object? value) {
  if (value == null) return const <WorkspacePositioningFocus>[];
  if (value is! List || value.length > 20) return null;
  final result = <WorkspacePositioningFocus>[];
  for (final raw in value) {
    if (raw is! Map) return null;
    final item = Map<String, Object?>.from(raw);
    final title = _text(item['title']);
    if (title == null) return null;
    result.add(
      WorkspacePositioningFocus(
        title: title,
        detail: _text(item['detail']) ?? '',
        moduleId: _identifier(item['moduleId']),
      ),
    );
  }
  return result;
}

List<String>? _texts(Object? value, {required int maximum}) {
  if (value == null) return const <String>[];
  if (value is! List || value.length > maximum) return null;
  final result = <String>[];
  for (final item in value) {
    final text = _text(item);
    if (text == null) return null;
    result.add(text);
  }
  return result;
}

String? _identifier(Object? value) {
  final text = _text(value);
  if (text == null ||
      !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,159}$').hasMatch(text))
    return null;
  return text;
}

String? _text(Object? value) {
  if (value is! String) return null;
  final normalized = value.trim();
  return normalized.isEmpty || normalized.length > 1200 ? null : normalized;
}

int? _positiveInt(Object? value) =>
    value is int && value > 0 && value <= 1000000 ? value : null;
int? _nonNegativeInt(Object? value) =>
    value is int && value >= 0 && value <= 1000000 ? value : null;
int? _percent(Object? value) =>
    value is int && value >= 0 && value <= 100 ? value : null;
