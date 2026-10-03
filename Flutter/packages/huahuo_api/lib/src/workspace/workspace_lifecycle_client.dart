import '../api/api_client.dart';
import '../api/api_contract_object.dart';
import '../api/request_parsing.dart';
import '../api/idempotency.dart';
import '../contracts/contract_models.dart';

final class WorkspaceLifecycleClient {
  const WorkspaceLifecycleClient(this._api);

  final ApiClient _api;

  Future<ApiResult<ApiContractObject>> currentProfile() =>
      _api.request<ApiContractObject>(
        ApiRequestOptions<ApiContractObject>(
          endpointId: 'currentWorkspaceProfile',
          parseData: parseApiObject,
        ),
      );

  Future<ApiResult<SharedWorkspacePage>> list() =>
      _api.request<SharedWorkspacePage>(
        ApiRequestOptions<SharedWorkspacePage>(
          endpointId: 'workspaces',
          parseData: (value) =>
              parseJsonModel(value, SharedWorkspacePage.fromJson),
        ),
      );

  Future<ApiResult<SharedWorkspaceBootstrapResult>> create({
    required String displayName,
    required bool setAsDefault,
    required String idempotencyKey,
  }) => _api.request<SharedWorkspaceBootstrapResult>(
    ApiRequestOptions<SharedWorkspaceBootstrapResult>(
      endpointId: 'createWorkspace',
      body: <String, Object?>{
        'displayName': requiredClientText(displayName, 'displayName'),
        'setAsDefault': setAsDefault,
      },
      idempotency: IdempotencyRequestContext(explicitKey: idempotencyKey),
      parseData: (value) =>
          parseJsonModel(value, SharedWorkspaceBootstrapResult.fromJson),
    ),
  );

  Future<ApiResult<SharedWorkspaceDetail>> detail(String workspaceId) =>
      _api.request<SharedWorkspaceDetail>(
        ApiRequestOptions<SharedWorkspaceDetail>(
          endpointId: 'workspaceDetail',
          pathParams: <String, Object>{'workspaceId': workspaceId},
          parseData: (value) =>
              parseJsonModel(value, SharedWorkspaceDetail.fromJson),
        ),
      );

  ApiRequestLease<ApiResult<SharedWorkspaceDetail>> leaseDetail(
    String workspaceId,
  ) => _api.leaseGet<SharedWorkspaceDetail>(
    ApiRequestOptions<SharedWorkspaceDetail>(
      endpointId: 'workspaceDetail',
      pathParams: <String, Object>{'workspaceId': workspaceId},
      parseData: (value) =>
          parseJsonModel(value, SharedWorkspaceDetail.fromJson),
    ),
  );

  Future<ApiResult<SharedWorkspaceStorageUsage>> storageUsage(
    String workspaceId,
  ) => _api.request<SharedWorkspaceStorageUsage>(
    ApiRequestOptions<SharedWorkspaceStorageUsage>(
      endpointId: 'workspaceStorageUsage',
      pathParams: <String, Object>{'workspaceId': workspaceId},
      parseData: (value) =>
          parseJsonModel(value, SharedWorkspaceStorageUsage.fromJson),
    ),
  );

  Future<ApiResult<SharedWorkspaceSummary>> update(
    String workspaceId, {
    required String displayName,
    required String etag,
    required String idempotencyKey,
  }) => _mutate(
    endpointId: 'updateWorkspace',
    workspaceId: workspaceId,
    etag: etag,
    idempotencyKey: idempotencyKey,
    body: <String, Object?>{
      'displayName': requiredClientText(displayName, 'displayName'),
    },
  );

  Future<ApiResult<SharedWorkspaceSummary>> setDefault(
    String workspaceId, {
    required String etag,
    required String idempotencyKey,
  }) => _mutate(
    endpointId: 'setDefaultWorkspace',
    workspaceId: workspaceId,
    etag: etag,
    idempotencyKey: idempotencyKey,
  );

  Future<ApiResult<SharedWorkspaceSummary>> disable(
    String workspaceId, {
    required String etag,
    required String idempotencyKey,
  }) => _mutate(
    endpointId: 'disableWorkspace',
    workspaceId: workspaceId,
    etag: etag,
    idempotencyKey: idempotencyKey,
  );

  Future<ApiResult<SharedWorkspaceSummary>> restore(
    String workspaceId, {
    required String etag,
    required String idempotencyKey,
  }) => _mutate(
    endpointId: 'restoreWorkspace',
    workspaceId: workspaceId,
    etag: etag,
    idempotencyKey: idempotencyKey,
  );

  Future<ApiResult<SharedWorkspaceSummary>> _mutate({
    required String endpointId,
    required String workspaceId,
    required String etag,
    required String idempotencyKey,
    Object? body,
  }) => _api.request<SharedWorkspaceSummary>(
    ApiRequestOptions<SharedWorkspaceSummary>(
      endpointId: endpointId,
      pathParams: <String, Object>{
        'workspaceId': requiredClientText(workspaceId, 'workspaceId'),
      },
      headers: ifMatchHeaders(etag),
      body: body,
      idempotency: IdempotencyRequestContext(explicitKey: idempotencyKey),
      parseData: (value) =>
          parseJsonModel(value, SharedWorkspaceSummary.fromJson),
    ),
  );
}
