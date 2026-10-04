import 'package:huahuo_api/huahuo_api.dart';

import '../domain/workspace_recovery.dart';

/// Owns the recoverable workspace-creation command.
final class WorkspaceRecoveryRepository {
  const WorkspaceRecoveryRepository({required ApiClient apiClient})
    : _apiClient = apiClient;

  final ApiClient _apiClient;

  Future<ApiResult<WorkspaceRetryAck>> retryCreate({
    required IdempotencyRequestContext idempotency,
  }) => _apiClient.request<WorkspaceRetryAck>(
    ApiRequestOptions<WorkspaceRetryAck>(
      endpointId: 'workspaceRetryCreate',
      body: <String, Object?>{},
      parseData: _parseWorkspaceRetryAck,
      idempotency: idempotency,
    ),
  );
}

WorkspaceRetryAck? _parseWorkspaceRetryAck(Object? raw) {
  final object = asObjectMap(raw);
  if (object == null || object.isEmpty) return null;
  final resourceId = _safeIdentifier(
    object['resourceId'] ?? object['id'] ?? object['taskId'],
  );
  final status = _safeText(object['status']);
  final revision = object['revision'] is int && object['revision']! as int >= 0
      ? object['revision']! as int
      : null;
  final accepted = object['accepted'] is bool
      ? object['accepted']! as bool
      : null;
  final ack = WorkspaceRetryAck(
    resourceId: resourceId,
    status: status,
    revision: revision,
    accepted: accepted,
  );
  return ack.isMeaningful ? ack : null;
}

String? _safeIdentifier(Object? value) {
  if (value is! String ||
      !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$').hasMatch(value)) {
    return null;
  }
  return value;
}

String? _safeText(Object? value) {
  if (value is! String) return null;
  final normalized = value.trim();
  return normalized.isEmpty || normalized.length > 80 ? null : normalized;
}
