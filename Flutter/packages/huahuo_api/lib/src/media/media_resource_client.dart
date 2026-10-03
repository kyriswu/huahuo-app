import '../api/api_client.dart';
import '../api/api_envelope.dart';
import '../api/idempotency.dart';

const _deleteStatuses = <String>{'deleted', 'delete_pending'};

final class MediaResourceDeleteReceipt {
  const MediaResourceDeleteReceipt({
    required this.resourceId,
    required this.workspaceId,
    required this.status,
  });

  final String resourceId;
  final String workspaceId;
  final String status;

  bool get blocksFurtherUse => true;
}

/// Public transport for an owner-scoped Workspace media Resource deletion.
final class MediaResourceClient {
  const MediaResourceClient(this._api);

  final ApiClient _api;

  Future<ApiResult<MediaResourceDeleteReceipt>> delete({
    required String workspaceId,
    required String resourceId,
    required String idempotencyKey,
  }) {
    final normalizedWorkspaceId = _identifier(workspaceId, 'workspaceId');
    final normalizedResourceId = _identifier(resourceId, 'resourceId');
    final normalizedKey = idempotencyKey.trim();
    if (normalizedKey.isEmpty || normalizedKey.length > 255) {
      throw ArgumentError.value(
        idempotencyKey,
        'idempotencyKey',
        'must be a non-empty request key',
      );
    }
    return _api.request<MediaResourceDeleteReceipt>(
      ApiRequestOptions<MediaResourceDeleteReceipt>(
        endpointId: 'deleteWorkspaceMediaResource',
        pathParams: <String, Object>{
          'workspaceId': normalizedWorkspaceId,
          'resourceId': normalizedResourceId,
        },
        idempotency: IdempotencyRequestContext(explicitKey: normalizedKey),
        parseData: (value) => parseMediaResourceDeleteReceipt(
          value,
          workspaceId: normalizedWorkspaceId,
          resourceId: normalizedResourceId,
        ),
      ),
    );
  }
}

MediaResourceDeleteReceipt? parseMediaResourceDeleteReceipt(
  Object? value, {
  required String workspaceId,
  required String resourceId,
}) {
  final object = asObjectMap(value);
  if (object == null ||
      object.length != 3 ||
      !object.keys.every(
        const <String>{'resourceId', 'workspaceId', 'status'}.contains,
      )) {
    return null;
  }
  final responseResourceId = _text(object['resourceId']);
  final responseWorkspaceId = _text(object['workspaceId']);
  final status = _text(object['status']);
  if (responseResourceId == null ||
      responseWorkspaceId == null ||
      responseResourceId != resourceId ||
      responseWorkspaceId != workspaceId ||
      status == null ||
      !_deleteStatuses.contains(status)) {
    return null;
  }
  return MediaResourceDeleteReceipt(
    resourceId: responseResourceId,
    workspaceId: responseWorkspaceId,
    status: status,
  );
}

String _identifier(String value, String name) {
  final normalized = value.trim();
  if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,159}$').hasMatch(normalized)) {
    throw ArgumentError.value(value, name, 'must be a public identifier');
  }
  return normalized;
}

String? _text(Object? value) =>
    value is String && value.trim().isNotEmpty ? value.trim() : null;
