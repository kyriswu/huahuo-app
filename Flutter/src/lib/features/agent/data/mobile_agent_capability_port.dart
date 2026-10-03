import '../../../core/api/api_client.dart';
import '../../../core/api/api_envelope.dart';
import '../../../core/api/idempotency.dart';

abstract interface class MobileAgentCapabilityPort {
  Future<ApiResult<AgentProfileCatalog>> profiles();

  Future<ApiResult<List<SkillProfileCatalogItem>>> skills(
    String agentProfileId,
  );

  Future<ApiResult<List<ModelProfileCatalogItem>>> models(
    String agentProfileId,
  );

  Future<ApiResult<SharedSkillInstallationList>> installations(
    String workspaceId,
  );

  Future<ApiResult<AgentRunSnapshot>> createRun(
    AgentRunRequest request, {
    required String idempotencyKey,
  });

  Future<ApiResult<AgentRunSnapshot>> run(String agentRunId);

  Future<ApiResult<SharedRunUsage>> runUsage(String agentRunId);
}

abstract interface class MobileAgentRunCancellationPort {
  Future<ApiResult<AgentRunSnapshot>> cancelRun(
    String agentRunId, {
    required String idempotencyKey,
  });
}

final class RemoteMobileAgentCapabilityPort
    implements MobileAgentCapabilityPort, MobileAgentRunCancellationPort {
  RemoteMobileAgentCapabilityPort(ApiClient apiClient)
    : _catalog = AgentCatalogClient(apiClient),
      _runs = AgentRunClient(apiClient),
      _usage = AccountUsageClient(apiClient);

  final AgentCatalogClient _catalog;
  final AgentRunClient _runs;
  final AccountUsageClient _usage;

  @override
  Future<ApiResult<AgentProfileCatalog>> profiles() => _catalog.profiles();

  @override
  Future<ApiResult<List<SkillProfileCatalogItem>>> skills(
    String agentProfileId,
  ) => _catalog.skills(agentProfileId);

  @override
  Future<ApiResult<List<ModelProfileCatalogItem>>> models(
    String agentProfileId,
  ) => _catalog.models(agentProfileId);

  @override
  Future<ApiResult<SharedSkillInstallationList>> installations(
    String workspaceId,
  ) => _catalog.installations(workspaceId);

  @override
  Future<ApiResult<AgentRunSnapshot>> createRun(
    AgentRunRequest request, {
    required String idempotencyKey,
  }) => _runs.create(request, idempotencyKey: idempotencyKey);

  @override
  Future<ApiResult<AgentRunSnapshot>> run(String agentRunId) =>
      _runs.get(agentRunId);

  @override
  Future<ApiResult<AgentRunSnapshot>> cancelRun(
    String agentRunId, {
    required String idempotencyKey,
  }) => _runs.cancel(agentRunId, idempotencyKey: idempotencyKey);

  @override
  Future<ApiResult<SharedRunUsage>> runUsage(String agentRunId) =>
      _usage.runUsageDetail(agentRunId);
}

final class UnavailableMobileAgentCapabilityPort
    implements MobileAgentCapabilityPort {
  const UnavailableMobileAgentCapabilityPort();

  @override
  Future<ApiResult<AgentProfileCatalog>> profiles() =>
      _unavailable<AgentProfileCatalog>();

  @override
  Future<ApiResult<List<SkillProfileCatalogItem>>> skills(
    String agentProfileId,
  ) => _unavailable<List<SkillProfileCatalogItem>>();

  @override
  Future<ApiResult<List<ModelProfileCatalogItem>>> models(
    String agentProfileId,
  ) => _unavailable<List<ModelProfileCatalogItem>>();

  @override
  Future<ApiResult<SharedSkillInstallationList>> installations(
    String workspaceId,
  ) => _unavailable<SharedSkillInstallationList>();

  @override
  Future<ApiResult<AgentRunSnapshot>> createRun(
    AgentRunRequest request, {
    required String idempotencyKey,
  }) => _unavailable<AgentRunSnapshot>();

  @override
  Future<ApiResult<AgentRunSnapshot>> run(String agentRunId) =>
      _unavailable<AgentRunSnapshot>();

  @override
  Future<ApiResult<SharedRunUsage>> runUsage(String agentRunId) =>
      _unavailable<SharedRunUsage>();
}

Future<ApiResult<T>> _unavailable<T>() async => ApiResult<T>.failure(
  error: const AppFailure(
    code: 'AGENT_RUNTIME_UNAVAILABLE',
    category: AppFailureCategory.compatibility,
    message: 'Mobile Agent runtime is unavailable',
    userMessageKey: 'error.agent.runtimeUnavailable',
    recoveryActions: <String>['retry'],
  ),
  idempotencyStore: SubmissionKeyStore.empty,
);
