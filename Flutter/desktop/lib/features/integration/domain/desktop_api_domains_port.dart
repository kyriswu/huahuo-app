import 'package:huahuo_api/huahuo_api.dart';

import '../../../shared/services/desktop_service_result.dart';

final class DesktopNoteFileAgentRun {
  const DesktopNoteFileAgentRun({
    required this.fileAgentRunId,
    required this.noteId,
    required this.status,
    required this.agentProfileId,
    required this.skillProfileIds,
    required this.inputPart,
    required this.inputPartRevisionId,
    required this.targetPart,
    required this.targetPartRevisionId,
    this.agentRunId,
    this.outputPartRevisionId,
    this.failureCode,
  });

  final String fileAgentRunId;
  final String noteId;
  final String status;
  final String agentProfileId;
  final List<String> skillProfileIds;
  final String inputPart;
  final String inputPartRevisionId;
  final String targetPart;
  final String targetPartRevisionId;
  final String? agentRunId;
  final String? outputPartRevisionId;
  final String? failureCode;

  bool get isTerminal => const <String>{
    'succeeded',
    'failed',
    'timeout',
    'cancelled',
    'conflict',
  }.contains(status);
}

abstract interface class DesktopWorkspacePort {
  Future<DesktopServiceResult<ApiContractObject>> loadContentSnapshot(
    String workspaceId,
  );

  Future<DesktopServiceResult<ApiContractPage>> loadFolders(String workspaceId);

  Future<DesktopServiceResult<ApiContractObject>> loadContentNavigation(
    String workspaceId, {
    String map = 'overview',
  });

  Future<DesktopServiceResult<SharedWorkspaceSearchOutput>> searchWorkspace(
    String workspaceId,
    SharedWorkspaceSearchRequest request,
  );

  Future<DesktopServiceResult<SharedHNote>> loadNote(
    String workspaceId,
    String noteId, {
    required String revisionId,
  });

  Future<DesktopServiceResult<SharedHNotePartView>> loadNotePart(
    String workspaceId,
    String noteId,
    String part, {
    required String partRevisionId,
  });

  Future<DesktopServiceResult<SharedNoteRelationPage>> loadNoteRelations(
    String workspaceId,
    String noteId, {
    String? cursor,
    int? limit,
  });

  Future<DesktopServiceResult<SharedWorkspaceContentEvent>> createNoteRelation(
    String workspaceId,
    String noteId,
    SharedCreateExplicitNoteRelationRequest request, {
    required String idempotencyKey,
  });

  Future<DesktopServiceResult<SharedWorkspaceContentEvent>> updateNoteRelation(
    String workspaceId,
    String relationId,
    SharedUpdateExplicitNoteRelationRequest request, {
    required String etag,
    required String idempotencyKey,
  });

  Future<DesktopServiceResult<SharedWorkspaceContentEvent>> deleteNoteRelation(
    String workspaceId,
    String relationId, {
    required String etag,
    required String idempotencyKey,
  });
}

abstract interface class DesktopCatalogPort {
  Future<DesktopServiceResult<AgentProfileCatalog>> loadProfiles();

  Future<DesktopServiceResult<List<SkillProfileCatalogItem>>> loadSkills(
    String agentProfileId,
  );

  Future<DesktopServiceResult<List<ModelProfileCatalogItem>>> loadModels(
    String agentProfileId,
  );

  Future<DesktopServiceResult<SharedSkillInstallationList>> loadInstallations(
    String workspaceId,
  );

  Future<DesktopServiceResult<AgentRunSnapshot>> createAgentRun(
    AgentRunRequest request, {
    required String idempotencyKey,
  });

  Future<DesktopServiceResult<AgentRunSnapshot>> loadAgentRun(
    String agentRunId,
  );

  Future<DesktopServiceResult<DesktopNoteFileAgentRun>> createNoteFileAgentRun({
    required String workspaceId,
    required String noteId,
    required String inputPart,
    required String inputPartRevisionId,
    required String targetPart,
    required String targetPartRevisionId,
    required String instruction,
    required String agentProfileId,
    required List<String> skillProfileIds,
    required String idempotencyKey,
  });

  Future<DesktopServiceResult<DesktopNoteFileAgentRun>> loadNoteFileAgentRun({
    required String workspaceId,
    required String noteId,
    required String fileAgentRunId,
  });
}

abstract interface class DesktopSubscriptionPort {
  Future<
    DesktopServiceResult<SharedSubscriptionPage<SharedSubscriptionPublication>>
  >
  loadPublications({String? cursor, int? limit});

  Future<DesktopServiceResult<SharedSubscriptionPublication>> loadPublication(
    String publicationId,
  );

  Future<
    DesktopServiceResult<SharedSubscriptionPage<SharedSubscriptionSection>>
  >
  loadSections(String publicationId, {String? cursor, int? limit});

  Future<
    DesktopServiceResult<SharedSubscriptionPage<SharedSubscriptionArticle>>
  >
  loadArticles({
    required String publicationId,
    String? sectionId,
    String? cursor,
    int? limit,
  });

  Future<DesktopServiceResult<SharedSubscriptionArticleRevision>> loadArticle(
    String articleId,
  );

  Future<
    DesktopServiceResult<
      SharedSubscriptionPage<SharedSubscriptionArticleRevision>
    >
  >
  loadArticleRevisions(String articleId, {String? cursor, int? limit});

  Future<DesktopServiceResult<SharedSubscriptionArticleRevision>>
  loadArticleRevision(String articleId, String articleRevisionId);

  Future<
    DesktopServiceResult<
      SharedSubscriptionPage<SharedSubscriptionLibraryPublication>
    >
  >
  loadLibrary(String workspaceId, {String? cursor, int? limit});

  Future<DesktopServiceResult<SharedSubscriptionFollowResult>>
  followPublication(
    String workspaceId,
    String publicationId, {
    required String idempotencyKey,
  });

  Future<DesktopServiceResult<SharedSubscriptionFollowResult>>
  unfollowPublication(
    String workspaceId,
    String publicationId, {
    required String idempotencyKey,
  });

  Future<DesktopServiceResult<SharedSubscriptionSaveReceipt>> saveArticleAsNote(
    String workspaceId,
    String articleId, {
    required String articleRevisionId,
    required String idempotencyKey,
  });
}

abstract interface class DesktopAccountUsagePort {
  Future<DesktopServiceResult<SharedAccountMembershipResponse>>
  loadMembership();

  Future<DesktopServiceResult<SharedAccountCreditSummary>> loadCredits({
    String? cursor,
    int? limit,
  });

  Future<DesktopServiceResult<SharedRunUsage>> loadRunUsage(String runId);
}

final class UnavailableDesktopApiDomains
    implements
        DesktopWorkspacePort,
        DesktopCatalogPort,
        DesktopSubscriptionPort,
        DesktopAccountUsagePort {
  const UnavailableDesktopApiDomains();

  static const _result = DesktopServiceResult<ApiContractObject>.unavailable(
    code: 'DESKTOP_API_DOMAINS_UNAVAILABLE',
    message: 'API 服务尚未配置',
  );

  @override
  Future<DesktopServiceResult<ApiContractObject>> loadContentSnapshot(
    String workspaceId,
  ) async => _result;

  @override
  Future<DesktopServiceResult<ApiContractPage>> loadFolders(
    String workspaceId,
  ) async => const DesktopServiceResult<ApiContractPage>.unavailable(
    code: 'DESKTOP_WORKSPACE_UNAVAILABLE',
    message: 'Workspace 服务尚未配置',
  );

  @override
  Future<DesktopServiceResult<ApiContractObject>> loadContentNavigation(
    String workspaceId, {
    String map = 'overview',
  }) async => _result;

  @override
  Future<DesktopServiceResult<SharedWorkspaceSearchOutput>> searchWorkspace(
    String workspaceId,
    SharedWorkspaceSearchRequest request,
  ) async => _workspaceUnavailable();

  @override
  Future<DesktopServiceResult<SharedHNote>> loadNote(
    String workspaceId,
    String noteId, {
    required String revisionId,
  }) async => _workspaceUnavailable();

  @override
  Future<DesktopServiceResult<SharedHNotePartView>> loadNotePart(
    String workspaceId,
    String noteId,
    String part, {
    required String partRevisionId,
  }) async => _workspaceUnavailable();

  @override
  Future<DesktopServiceResult<SharedNoteRelationPage>> loadNoteRelations(
    String workspaceId,
    String noteId, {
    String? cursor,
    int? limit,
  }) async => _workspaceUnavailable();

  @override
  Future<DesktopServiceResult<SharedWorkspaceContentEvent>> createNoteRelation(
    String workspaceId,
    String noteId,
    SharedCreateExplicitNoteRelationRequest request, {
    required String idempotencyKey,
  }) async => _workspaceUnavailable();

  @override
  Future<DesktopServiceResult<SharedWorkspaceContentEvent>> updateNoteRelation(
    String workspaceId,
    String relationId,
    SharedUpdateExplicitNoteRelationRequest request, {
    required String etag,
    required String idempotencyKey,
  }) async => _workspaceUnavailable();

  @override
  Future<DesktopServiceResult<SharedWorkspaceContentEvent>> deleteNoteRelation(
    String workspaceId,
    String relationId, {
    required String etag,
    required String idempotencyKey,
  }) async => _workspaceUnavailable();

  @override
  Future<DesktopServiceResult<AgentProfileCatalog>> loadProfiles() async =>
      const DesktopServiceResult<AgentProfileCatalog>.unavailable(
        code: 'DESKTOP_CATALOG_UNAVAILABLE',
        message: 'Agent Catalog 尚未配置',
      );

  @override
  Future<DesktopServiceResult<List<SkillProfileCatalogItem>>> loadSkills(
    String agentProfileId,
  ) async =>
      const DesktopServiceResult<List<SkillProfileCatalogItem>>.unavailable(
        code: 'DESKTOP_CATALOG_UNAVAILABLE',
        message: 'Agent Catalog 尚未配置',
      );

  @override
  Future<DesktopServiceResult<List<ModelProfileCatalogItem>>> loadModels(
    String agentProfileId,
  ) async =>
      const DesktopServiceResult<List<ModelProfileCatalogItem>>.unavailable(
        code: 'DESKTOP_CATALOG_UNAVAILABLE',
        message: 'Agent Catalog 尚未配置',
      );

  @override
  Future<DesktopServiceResult<SharedSkillInstallationList>> loadInstallations(
    String workspaceId,
  ) async =>
      const DesktopServiceResult<SharedSkillInstallationList>.unavailable(
        code: 'DESKTOP_CATALOG_UNAVAILABLE',
        message: 'Skill 安装目录尚未配置',
      );

  @override
  Future<DesktopServiceResult<AgentRunSnapshot>> createAgentRun(
    AgentRunRequest request, {
    required String idempotencyKey,
  }) async => const DesktopServiceResult<AgentRunSnapshot>.unavailable(
    code: 'DESKTOP_AGENT_RUN_UNAVAILABLE',
    message: 'AgentRun 服务尚未配置',
  );

  @override
  Future<DesktopServiceResult<AgentRunSnapshot>> loadAgentRun(
    String agentRunId,
  ) async => const DesktopServiceResult<AgentRunSnapshot>.unavailable(
    code: 'DESKTOP_AGENT_RUN_UNAVAILABLE',
    message: 'AgentRun 服务尚未配置',
  );

  @override
  Future<DesktopServiceResult<DesktopNoteFileAgentRun>> createNoteFileAgentRun({
    required String workspaceId,
    required String noteId,
    required String inputPart,
    required String inputPartRevisionId,
    required String targetPart,
    required String targetPartRevisionId,
    required String instruction,
    required String agentProfileId,
    required List<String> skillProfileIds,
    required String idempotencyKey,
  }) async => const DesktopServiceResult<DesktopNoteFileAgentRun>.unavailable(
    code: 'DESKTOP_NOTE_FILE_AGENT_UNAVAILABLE',
    message: '笔记 Agent 服务尚未配置',
  );

  @override
  Future<DesktopServiceResult<DesktopNoteFileAgentRun>> loadNoteFileAgentRun({
    required String workspaceId,
    required String noteId,
    required String fileAgentRunId,
  }) async => const DesktopServiceResult<DesktopNoteFileAgentRun>.unavailable(
    code: 'DESKTOP_NOTE_FILE_AGENT_UNAVAILABLE',
    message: '笔记 Agent 服务尚未配置',
  );

  @override
  Future<
    DesktopServiceResult<SharedSubscriptionPage<SharedSubscriptionPublication>>
  >
  loadPublications({String? cursor, int? limit}) async =>
      _subscriptionUnavailable();

  @override
  Future<DesktopServiceResult<SharedSubscriptionPublication>> loadPublication(
    String publicationId,
  ) async => _subscriptionUnavailable();

  @override
  Future<
    DesktopServiceResult<SharedSubscriptionPage<SharedSubscriptionSection>>
  >
  loadSections(String publicationId, {String? cursor, int? limit}) async =>
      _subscriptionUnavailable();

  @override
  Future<
    DesktopServiceResult<SharedSubscriptionPage<SharedSubscriptionArticle>>
  >
  loadArticles({
    required String publicationId,
    String? sectionId,
    String? cursor,
    int? limit,
  }) async => _subscriptionUnavailable();

  @override
  Future<DesktopServiceResult<SharedSubscriptionArticleRevision>> loadArticle(
    String articleId,
  ) async => _subscriptionUnavailable();

  @override
  Future<
    DesktopServiceResult<
      SharedSubscriptionPage<SharedSubscriptionArticleRevision>
    >
  >
  loadArticleRevisions(String articleId, {String? cursor, int? limit}) async =>
      _subscriptionUnavailable();

  @override
  Future<DesktopServiceResult<SharedSubscriptionArticleRevision>>
  loadArticleRevision(String articleId, String articleRevisionId) async =>
      _subscriptionUnavailable();

  @override
  Future<
    DesktopServiceResult<
      SharedSubscriptionPage<SharedSubscriptionLibraryPublication>
    >
  >
  loadLibrary(String workspaceId, {String? cursor, int? limit}) async =>
      _subscriptionUnavailable();

  @override
  Future<DesktopServiceResult<SharedSubscriptionFollowResult>>
  followPublication(
    String workspaceId,
    String publicationId, {
    required String idempotencyKey,
  }) async => _subscriptionUnavailable();

  @override
  Future<DesktopServiceResult<SharedSubscriptionFollowResult>>
  unfollowPublication(
    String workspaceId,
    String publicationId, {
    required String idempotencyKey,
  }) async => _subscriptionUnavailable();

  @override
  Future<DesktopServiceResult<SharedSubscriptionSaveReceipt>> saveArticleAsNote(
    String workspaceId,
    String articleId, {
    required String articleRevisionId,
    required String idempotencyKey,
  }) async => _subscriptionUnavailable();

  @override
  Future<DesktopServiceResult<SharedAccountMembershipResponse>>
  loadMembership() async => _accountUnavailable();

  @override
  Future<DesktopServiceResult<SharedAccountCreditSummary>> loadCredits({
    String? cursor,
    int? limit,
  }) async => _accountUnavailable();

  @override
  Future<DesktopServiceResult<SharedRunUsage>> loadRunUsage(
    String runId,
  ) async => _accountUnavailable();

  DesktopServiceResult<T> _workspaceUnavailable<T>() =>
      DesktopServiceResult<T>.unavailable(
        code: 'DESKTOP_WORKSPACE_UNAVAILABLE',
        message: 'Workspace 服务尚未配置',
      );

  DesktopServiceResult<T> _accountUnavailable<T>() =>
      DesktopServiceResult<T>.unavailable(
        code: 'DESKTOP_ACCOUNT_USAGE_UNAVAILABLE',
        message: '会员与额度服务尚未配置',
      );

  DesktopServiceResult<T> _subscriptionUnavailable<T>() =>
      DesktopServiceResult<T>.unavailable(
        code: 'DESKTOP_SUBSCRIPTION_UNAVAILABLE',
        message: '订阅服务尚未配置',
      );
}
