import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:huahuo_api/huahuo_api.dart';
import 'package:huahuoai_app/app/bootstrap/app_providers.dart';
import 'package:huahuoai_app/core/auth/secure_token_store.dart';
import 'package:huahuoai_app/core/auth/session_store.dart';
import 'package:huahuoai_app/features/agent/application/mobile_agent_capability_controller.dart';
import 'package:huahuoai_app/features/agent/data/mobile_agent_capability_port.dart';

List<Override> mobileAgentReadyTestOverrides() => <Override>[
  sessionStoreProvider.overrideWith((ref) => _readySessionStore()),
  mobileAgentCapabilityPortProvider.overrideWithValue(
    const MobileAgentReadyTestPort(),
  ),
  mobileAgentRuntimeIdentityProvider.overrideWithValue(
    const MobileAgentRuntimeIdentity(
      userId: 'test-user',
      workspaceId: 'test-workspace',
      locale: 'zh-CN',
      timezone: 'Asia/Shanghai',
    ),
  ),
];

SessionStore _readySessionStore() => SessionStore(
  secureTokenStore: const SecureTokenStore(driver: _NoopSecureTokenDriver()),
  initialState: SessionState.anonymous().copyWith(
    authState: SessionAuthState.authenticated,
    user: const SessionUser(
      userId: 'test-user',
      maskedPhoneNumber: '138****8000',
    ),
    workspaceStatus: SessionWorkspaceStatus.ready,
    workspace: const SessionWorkspace(
      status: SessionWorkspaceStatus.ready,
      workspaceId: 'test-workspace',
    ),
  ),
);

final class _NoopSecureTokenDriver implements SecureTokenDriver {
  const _NoopSecureTokenDriver();

  @override
  SecureTokenCredential? read({required String service}) => null;

  @override
  bool write({
    required String service,
    required String username,
    required String password,
  }) => true;

  @override
  bool clear({required String service}) => true;
}

final class MobileAgentReadyTestPort implements MobileAgentCapabilityPort {
  const MobileAgentReadyTestPort({
    this.finalAnswer = '测试 Agent 已完成',
    this.outputFiles = const <AgentRunOutputFile>[],
  });

  final String finalAnswer;
  final List<AgentRunOutputFile> outputFiles;

  @override
  Future<ApiResult<AgentProfileCatalog>> profiles() async {
    final profiles = <String>{
      for (final route in AgentFeatureRoutes.all) route.agentProfileId,
    };
    return _ok(
      AgentProfileCatalog(
        catalogVersion: 'test-catalog-v1',
        items: <AgentProfileCatalogItem>[
          for (final id in profiles)
            AgentProfileCatalogItem(agentProfileId: id, displayName: id),
        ],
      ),
    );
  }

  @override
  Future<ApiResult<List<SkillProfileCatalogItem>>> skills(
    String agentProfileId,
  ) async {
    final skillIds = <String>{
      for (final route in AgentFeatureRoutes.all)
        if (route.agentProfileId == agentProfileId) ...route.skillProfileIds,
    };
    return _ok(<SkillProfileCatalogItem>[
      for (final id in skillIds)
        SkillProfileCatalogItem(
          skillProfileId: id,
          displayName: id,
          installation: 'enabled',
        ),
    ]);
  }

  @override
  Future<ApiResult<List<ModelProfileCatalogItem>>> models(
    String agentProfileId,
  ) async => _ok(const <ModelProfileCatalogItem>[
    ModelProfileCatalogItem(
      modelProfileId: 'model-test',
      displayName: 'Test model',
    ),
  ]);

  @override
  Future<ApiResult<SharedSkillInstallationList>> installations(
    String workspaceId,
  ) async {
    final skillIds = <String>{
      for (final route in AgentFeatureRoutes.all) ...route.skillProfileIds,
    };
    return _ok(
      SharedSkillInstallationList(
        items: <SharedSkillInstallation>[
          for (final id in skillIds)
            SharedSkillInstallation(
              skillProfileId: id,
              state: 'enabled',
              installMode: 'system_managed',
              installedAt: DateTime.utc(2026, 8, 1),
              updatedAt: DateTime.utc(2026, 8, 7),
            ),
        ],
      ),
    );
  }

  @override
  Future<ApiResult<AgentRunSnapshot>> createRun(
    AgentRunRequest request, {
    required String idempotencyKey,
  }) async => _ok(
    _terminalRun(request, finalAnswer: finalAnswer, outputFiles: outputFiles),
  );

  @override
  Future<ApiResult<AgentRunSnapshot>> run(String agentRunId) async => _ok(
    _terminalRun(null, finalAnswer: finalAnswer, outputFiles: outputFiles),
  );

  @override
  Future<ApiResult<SharedRunUsage>> runUsage(String agentRunId) async => _ok(
    const SharedRunUsage(
      runId: 'test-agent-run',
      policyVersion: 'credit-policy-v1',
      rawInputTokens: 10,
      rawOutputTokens: 20,
      accountedCredits: 30,
      settlementStatus: 'settled',
      assistantResultPersisted: true,
      measurements: <SharedRunUsageMeasurement>[],
    ),
  );
}

ApiResult<T> _ok<T>(T data) => ApiResult<T>.success(
  data: data,
  status: 200,
  idempotencyStore: SubmissionKeyStore.empty,
);

AgentRunSnapshot _terminalRun(
  AgentRunRequest? request, {
  required String finalAnswer,
  required List<AgentRunOutputFile> outputFiles,
}) => AgentRunSnapshot.fromValue(<String, Object?>{
  'agentRunId': 'test-agent-run',
  'workspaceId': request?.workspaceId ?? 'test-workspace',
  if (request?.threadId != null) 'threadId': request!.threadId,
  'status': 'succeeded',
  'workspaceVersion': 1,
  'workspaceBindingVersion': 1,
  'contextGeneration': 1,
  'result': <String, Object?>{
    'finalAnswer': finalAnswer,
    'assistantMessageId': 'test-assistant-message',
    'completionMode': 'normal',
  },
  'assistantMessageId': 'test-assistant-message',
  'completionMode': 'normal',
  'usage': const <String, Object?>{
    'measurementStatus': 'measured',
    'inputTokens': 10,
    'outputTokens': 20,
    'imageCount': null,
    'videoSeconds': null,
    'accountedCredits': 30,
    'policyVersion': 'credits-v1',
  },
  'toolTrace': <Object?>[
    if (outputFiles.isNotEmpty)
      <String, Object?>{
        'invocationId': 'test-output-file',
        'toolName': 'write',
        'state': 'finished',
        'outcome': 'succeeded',
        'createdAt': '2026-08-07T10:00:00Z',
        'completedAt': '2026-08-07T10:00:01Z',
        'outputFiles': <Object?>[
          for (final output in outputFiles)
            <String, Object?>{
              'resourceId': output.resourceId,
              'fileName': output.fileName,
              'mimeType': output.mimeType,
              'sizeBytes': output.sizeBytes,
            },
        ],
      },
  ],
  'createdAt': '2026-08-07T10:00:00Z',
  'updatedAt': '2026-08-07T10:00:01Z',
});
