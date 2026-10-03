import 'package:huahuo_api/huahuo_api.dart';

import '../../../shared/services/desktop_service_result.dart';
import '../domain/desktop_api_domains_port.dart';

final class RemoteDesktopApiDomains
    implements
        DesktopWorkspacePort,
        DesktopCatalogPort,
        DesktopSubscriptionPort,
        DesktopAccountUsagePort {
  RemoteDesktopApiDomains(ApiClient api)
    : _api = api,
      _workspace = WorkspaceContentClient(api),
      _catalog = AgentCatalogClient(api),
      _agentRuns = AgentRunClient(api),
      _subscription = SubscriptionClient(api),
      _account = AccountUsageClient(api);

  final ApiClient _api;
  final WorkspaceContentClient _workspace;
  final AgentCatalogClient _catalog;
  final AgentRunClient _agentRuns;
  final SubscriptionClient _subscription;
  final AccountUsageClient _account;

  @override
  Future<DesktopServiceResult<ApiContractObject>> loadContentSnapshot(
    String workspaceId,
  ) async => _toDesktop(await _workspace.snapshot(workspaceId));

  @override
  Future<DesktopServiceResult<ApiContractPage>> loadFolders(
    String workspaceId,
  ) async => _toDesktop(await _workspace.folders(workspaceId));

  @override
  Future<DesktopServiceResult<ApiContractObject>> loadContentNavigation(
    String workspaceId, {
    String map = 'overview',
  }) async => _toDesktop(await _workspace.contentNavigation(workspaceId, map));

  @override
  Future<DesktopServiceResult<SharedWorkspaceSearchOutput>> searchWorkspace(
    String workspaceId,
    SharedWorkspaceSearchRequest request,
  ) async => _toDesktop(
    await _workspace.workspaceSearch(workspaceId, request: request),
  );

  @override
  Future<DesktopServiceResult<SharedHNote>> loadNote(
    String workspaceId,
    String noteId, {
    required String revisionId,
  }) async => _toDesktop(
    await _workspace.note(workspaceId, noteId, revisionId: revisionId),
  );

  @override
  Future<DesktopServiceResult<SharedHNotePartView>> loadNotePart(
    String workspaceId,
    String noteId,
    String part, {
    required String partRevisionId,
  }) async => _toDesktop(
    await _workspace.notePart(
      workspaceId,
      noteId,
      part,
      partRevisionId: partRevisionId,
    ),
  );

  @override
  Future<DesktopServiceResult<SharedNoteRelationPage>> loadNoteRelations(
    String workspaceId,
    String noteId, {
    String? cursor,
    int? limit,
  }) async => _toDesktop(
    await _workspace.noteRelationPage(
      workspaceId,
      noteId,
      cursor: cursor,
      limit: limit,
    ),
  );

  @override
  Future<DesktopServiceResult<SharedWorkspaceContentEvent>> createNoteRelation(
    String workspaceId,
    String noteId,
    SharedCreateExplicitNoteRelationRequest request, {
    required String idempotencyKey,
  }) async => _toDesktop(
    await _workspace.createNoteRelation(
      workspaceId,
      noteId,
      request: request,
      idempotencyKey: idempotencyKey,
    ),
  );

  @override
  Future<DesktopServiceResult<SharedWorkspaceContentEvent>> updateNoteRelation(
    String workspaceId,
    String relationId,
    SharedUpdateExplicitNoteRelationRequest request, {
    required String etag,
    required String idempotencyKey,
  }) async => _toDesktop(
    await _workspace.updateNoteRelation(
      workspaceId,
      relationId,
      request: request,
      etag: etag,
      idempotencyKey: idempotencyKey,
    ),
  );

  @override
  Future<DesktopServiceResult<SharedWorkspaceContentEvent>> deleteNoteRelation(
    String workspaceId,
    String relationId, {
    required String etag,
    required String idempotencyKey,
  }) async => _toDesktop(
    await _workspace.deleteNoteRelation(
      workspaceId,
      relationId,
      etag: etag,
      idempotencyKey: idempotencyKey,
    ),
  );

  @override
  Future<DesktopServiceResult<AgentProfileCatalog>> loadProfiles() async =>
      _toDesktop(await _catalog.profiles());

  @override
  Future<DesktopServiceResult<List<SkillProfileCatalogItem>>> loadSkills(
    String agentProfileId,
  ) async => _toDesktop(await _catalog.skills(agentProfileId));

  @override
  Future<DesktopServiceResult<List<ModelProfileCatalogItem>>> loadModels(
    String agentProfileId,
  ) async => _toDesktop(await _catalog.models(agentProfileId));

  @override
  Future<DesktopServiceResult<SharedSkillInstallationList>> loadInstallations(
    String workspaceId,
  ) async => _toDesktop(await _catalog.installations(workspaceId));

  @override
  Future<DesktopServiceResult<AgentRunSnapshot>> createAgentRun(
    AgentRunRequest request, {
    required String idempotencyKey,
  }) async => _toDesktop(
    await _agentRuns.create(request, idempotencyKey: idempotencyKey),
  );

  @override
  Future<DesktopServiceResult<AgentRunSnapshot>> loadAgentRun(
    String agentRunId,
  ) async => _toDesktop(await _agentRuns.get(agentRunId));

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
  }) async => _toDesktop(
    await _api.request<DesktopNoteFileAgentRun>(
      ApiRequestOptions<DesktopNoteFileAgentRun>(
        endpointId: 'createWorkspaceNoteFileAgentRun',
        pathParams: <String, Object>{
          'workspaceId': workspaceId,
          'noteId': noteId,
        },
        body: <String, Object?>{
          'input': <String, Object?>{
            'part': inputPart,
            'partRevisionId': inputPartRevisionId,
          },
          'target': <String, Object?>{
            'part': targetPart,
            'partRevisionId': targetPartRevisionId,
          },
          'instruction': instruction,
          'agentProfileId': agentProfileId,
          'skillProfileIds': skillProfileIds,
        },
        idempotency: IdempotencyRequestContext(explicitKey: idempotencyKey),
        parseData: _parseNoteFileAgentRun,
      ),
    ),
  );

  @override
  Future<DesktopServiceResult<DesktopNoteFileAgentRun>> loadNoteFileAgentRun({
    required String workspaceId,
    required String noteId,
    required String fileAgentRunId,
  }) async => _toDesktop(
    await _api.request<DesktopNoteFileAgentRun>(
      ApiRequestOptions<DesktopNoteFileAgentRun>(
        endpointId: 'workspaceNoteFileAgentRun',
        pathParams: <String, Object>{
          'workspaceId': workspaceId,
          'noteId': noteId,
          'fileAgentRunId': fileAgentRunId,
        },
        parseData: _parseNoteFileAgentRun,
      ),
    ),
  );

  @override
  Future<
    DesktopServiceResult<SharedSubscriptionPage<SharedSubscriptionPublication>>
  >
  loadPublications({String? cursor, int? limit}) async => _toDesktop(
    await _subscription.publicationPage(cursor: cursor, limit: limit),
  );

  @override
  Future<DesktopServiceResult<SharedSubscriptionPublication>> loadPublication(
    String publicationId,
  ) async => _toDesktop(await _subscription.publication(publicationId));

  @override
  Future<
    DesktopServiceResult<SharedSubscriptionPage<SharedSubscriptionSection>>
  >
  loadSections(String publicationId, {String? cursor, int? limit}) async =>
      _toDesktop(
        await _subscription.sectionPage(
          publicationId,
          cursor: cursor,
          limit: limit,
        ),
      );

  @override
  Future<
    DesktopServiceResult<SharedSubscriptionPage<SharedSubscriptionArticle>>
  >
  loadArticles({
    required String publicationId,
    String? sectionId,
    String? cursor,
    int? limit,
  }) async => _toDesktop(
    await _subscription.articles(
      publicationId: publicationId,
      sectionId: sectionId,
      cursor: cursor,
      limit: limit,
    ),
  );

  @override
  Future<DesktopServiceResult<SharedSubscriptionArticleRevision>> loadArticle(
    String articleId,
  ) async => _toDesktop(await _subscription.article(articleId));

  @override
  Future<
    DesktopServiceResult<
      SharedSubscriptionPage<SharedSubscriptionArticleRevision>
    >
  >
  loadArticleRevisions(String articleId, {String? cursor, int? limit}) async =>
      _toDesktop(
        await _subscription.articleRevisionPage(
          articleId,
          cursor: cursor,
          limit: limit,
        ),
      );

  @override
  Future<DesktopServiceResult<SharedSubscriptionArticleRevision>>
  loadArticleRevision(String articleId, String articleRevisionId) async =>
      _toDesktop(
        await _subscription.articleRevision(articleId, articleRevisionId),
      );

  @override
  Future<
    DesktopServiceResult<
      SharedSubscriptionPage<SharedSubscriptionLibraryPublication>
    >
  >
  loadLibrary(String workspaceId, {String? cursor, int? limit}) async =>
      _toDesktop(
        await _subscription.libraryPage(
          workspaceId,
          cursor: cursor,
          limit: limit,
        ),
      );

  @override
  Future<DesktopServiceResult<SharedSubscriptionFollowResult>>
  followPublication(
    String workspaceId,
    String publicationId, {
    required String idempotencyKey,
  }) async => _toDesktop(
    await _subscription.followPublication(
      workspaceId,
      publicationId,
      idempotencyKey: idempotencyKey,
    ),
  );

  @override
  Future<DesktopServiceResult<SharedSubscriptionFollowResult>>
  unfollowPublication(
    String workspaceId,
    String publicationId, {
    required String idempotencyKey,
  }) async => _toDesktop(
    await _subscription.unfollowPublication(
      workspaceId,
      publicationId,
      idempotencyKey: idempotencyKey,
    ),
  );

  @override
  Future<DesktopServiceResult<SharedSubscriptionSaveReceipt>> saveArticleAsNote(
    String workspaceId,
    String articleId, {
    required String articleRevisionId,
    required String idempotencyKey,
  }) async => _toDesktop(
    await _subscription.saveArticleAsNote(
      workspaceId,
      articleId,
      articleRevisionId: articleRevisionId,
      idempotencyKey: idempotencyKey,
    ),
  );

  @override
  Future<DesktopServiceResult<SharedAccountMembershipResponse>>
  loadMembership() async => _toDesktop(await _account.membershipDetail());

  @override
  Future<DesktopServiceResult<SharedAccountCreditSummary>> loadCredits({
    String? cursor,
    int? limit,
  }) async =>
      _toDesktop(await _account.creditSummary(cursor: cursor, limit: limit));

  @override
  Future<DesktopServiceResult<SharedRunUsage>> loadRunUsage(
    String runId,
  ) async => _toDesktop(await _account.runUsageDetail(runId));
}

DesktopServiceResult<T> _toDesktop<T>(ApiResult<T> result) {
  final data = result.data;
  if (result.ok && data != null) {
    return DesktopServiceResult<T>.success(data);
  }
  final error = result.error;
  final code = error?.code ?? 'DESKTOP_API_RESPONSE_INVALID';
  if (code.endsWith('_UNAVAILABLE') ||
      code == 'API_ENDPOINT_PROHIBITED' ||
      code == 'API_ENDPOINT_RETIRED') {
    return DesktopServiceResult<T>.unavailable(
      code: code,
      message: error?.message ?? '服务当前不可用',
    );
  }
  return DesktopServiceResult<T>.failure(
    code: code,
    message: error?.message ?? 'API 响应无效',
    retryable: error?.isRetryable ?? false,
  );
}

DesktopNoteFileAgentRun? _parseNoteFileAgentRun(Object? value) {
  final root = asObjectMap(value);
  final run = asObjectMap(root?['fileAgentRun']) ?? root;
  if (run == null) return null;
  final input = asObjectMap(run['input']);
  final target = asObjectMap(run['target']);
  final selector = asObjectMap(run['selector']);
  final skills = selector?['skillProfileIds'];
  final failure = asObjectMap(run['failure']);
  if (input == null ||
      target == null ||
      selector == null ||
      skills is! List ||
      skills.any((value) => _nonEmptyDesktopString(value) == null)) {
    return null;
  }
  final fileAgentRunId = _nonEmptyDesktopString(run['fileAgentRunId']);
  final noteId = _nonEmptyDesktopString(run['noteId']);
  final status = _nonEmptyDesktopString(run['status']);
  final agentProfileId = _nonEmptyDesktopString(selector['agentProfileId']);
  final inputPart = _nonEmptyDesktopString(input['part']);
  final inputRevision = _nonEmptyDesktopString(input['partRevisionId']);
  final targetPart = _nonEmptyDesktopString(target['part']);
  final targetRevision = _nonEmptyDesktopString(target['partRevisionId']);
  if (fileAgentRunId == null ||
      noteId == null ||
      status == null ||
      agentProfileId == null ||
      inputPart == null ||
      inputRevision == null ||
      targetPart == null ||
      targetRevision == null) {
    return null;
  }
  return DesktopNoteFileAgentRun(
    fileAgentRunId: fileAgentRunId,
    noteId: noteId,
    status: status,
    agentProfileId: agentProfileId,
    skillProfileIds: List<String>.unmodifiable(
      skills.map((value) => (value as String).trim()),
    ),
    inputPart: inputPart,
    inputPartRevisionId: inputRevision,
    targetPart: targetPart,
    targetPartRevisionId: targetRevision,
    agentRunId: _nonEmptyDesktopString(run['agentRunId']),
    outputPartRevisionId: _nonEmptyDesktopString(run['outputPartRevisionId']),
    failureCode:
        _nonEmptyDesktopString(run['failureCode']) ??
        _nonEmptyDesktopString(failure?['code']),
  );
}

String? _nonEmptyDesktopString(Object? value) {
  if (value is! String) return null;
  final normalized = value.trim();
  return normalized.isEmpty ? null : normalized;
}
