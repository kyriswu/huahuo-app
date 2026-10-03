import 'endpoint_catalog.dart';
import 'domain_clients.dart';

enum ApiContractScope { formal, retained }

enum ApiOperationDisposition {
  wiredMobile,
  wiredDesktop,
  wiredBoth,
  contractOnly,
  blockedPublication,
  prohibited,
}

enum ApiResponseKind { jsonEnvelope, empty, binary, sse }

final class ApiContractOperation {
  const ApiContractOperation({
    required this.scope,
    required this.method,
    required this.path,
    required this.authority,
    required this.disposition,
    required this.responseKind,
  });

  final ApiContractScope scope;
  final HttpMethod method;
  final String path;
  final String authority;
  final ApiOperationDisposition disposition;
  final ApiResponseKind responseKind;

  String get key => '${method.value} $path';
}

final class AgentFeatureRoute {
  const AgentFeatureRoute({
    required this.featureId,
    required this.agentProfileId,
    this.skillProfileIds = const <String>[],
    this.requiresPublication = false,
    this.unavailableReason,
  });

  final String featureId;
  final String agentProfileId;

  @Deprecated('App routes must not select candidate Skills.')
  final List<String> skillProfileIds;
  final bool requiresPublication;
  final String? unavailableReason;
}

enum AgentFeatureAvailabilityStatus {
  available,
  featureUnknown,
  publicationBlocked,
  agentProfileUnavailable,
  skillNotCandidate,
  skillNotInstalled,
  skillDisabled,
  modelNotSelectable,
}

final class AgentFeatureAvailability {
  const AgentFeatureAvailability({
    required this.status,
    this.skillProfileIds = const <String>[],
    this.route,
    this.modelProfileId,
    this.blockingSkillProfileId,
  });

  final AgentFeatureRoute? route;
  final AgentFeatureAvailabilityStatus status;

  @Deprecated('The server selects Skills during Run admission.')
  final List<String> skillProfileIds;

  @Deprecated('The server selects Models during Run admission.')
  final String? modelProfileId;
  final String? blockingSkillProfileId;

  bool get isAvailable => status == AgentFeatureAvailabilityStatus.available;

  String? get reasonCode => switch (status) {
    AgentFeatureAvailabilityStatus.available => null,
    AgentFeatureAvailabilityStatus.featureUnknown =>
      'AGENT_FEATURE_ROUTE_UNKNOWN',
    AgentFeatureAvailabilityStatus.publicationBlocked =>
      route?.unavailableReason ?? 'AGENT_FEATURE_PUBLICATION_BLOCKED',
    AgentFeatureAvailabilityStatus.agentProfileUnavailable =>
      'AGENT_PROFILE_NOT_SELECTABLE',
    AgentFeatureAvailabilityStatus.skillNotCandidate =>
      'SKILL_SELECTION_NOT_CANDIDATE',
    AgentFeatureAvailabilityStatus.skillNotInstalled =>
      'SKILL_INSTALLATION_REQUIRED',
    AgentFeatureAvailabilityStatus.skillDisabled =>
      'SKILL_INSTALLATION_DISABLED',
    AgentFeatureAvailabilityStatus.modelNotSelectable =>
      'MODEL_PROFILE_NOT_SELECTABLE',
  };
}

abstract final class AgentFeatureAvailabilityResolver {
  static AgentFeatureAvailability resolveFeature({
    required String featureId,
    required AgentProfileCatalog profiles,
    Iterable<SkillProfileCatalogItem> skills =
        const <SkillProfileCatalogItem>[],
    Iterable<ModelProfileCatalogItem> models =
        const <ModelProfileCatalogItem>[],
    SharedSkillInstallationList installations =
        const SharedSkillInstallationList(items: <SharedSkillInstallation>[]),
    String? modelProfileId,
  }) {
    final route = AgentFeatureRoutes.forFeature(featureId);
    if (route == null) {
      return const AgentFeatureAvailability(
        status: AgentFeatureAvailabilityStatus.featureUnknown,
        skillProfileIds: <String>[],
      );
    }
    return resolve(
      route: route,
      profiles: profiles,
      skills: skills,
      models: models,
      installations: installations,
      modelProfileId: modelProfileId,
    );
  }

  static AgentFeatureAvailability resolve({
    required AgentFeatureRoute route,
    required AgentProfileCatalog profiles,
    Iterable<SkillProfileCatalogItem> skills =
        const <SkillProfileCatalogItem>[],
    Iterable<ModelProfileCatalogItem> models =
        const <ModelProfileCatalogItem>[],
    SharedSkillInstallationList installations =
        const SharedSkillInstallationList(items: <SharedSkillInstallation>[]),
    String? modelProfileId,
  }) {
    if (route.unavailableReason != null) {
      return AgentFeatureAvailability(
        route: route,
        status: AgentFeatureAvailabilityStatus.publicationBlocked,
      );
    }
    final profileAvailable = profiles.items.any(
      (item) => item.agentProfileId == route.agentProfileId,
    );
    if (!profileAvailable) {
      return AgentFeatureAvailability(
        route: route,
        status: AgentFeatureAvailabilityStatus.agentProfileUnavailable,
      );
    }
    return AgentFeatureAvailability(
      route: route,
      status: AgentFeatureAvailabilityStatus.available,
    );
  }
}

abstract final class AgentFeatureRoutes {
  static const all = <AgentFeatureRoute>[
    AgentFeatureRoute(
      featureId: 'chat.general',
      agentProfileId: 'self_media_creation_standard',
    ),
    AgentFeatureRoute(
      featureId: 'creation.free',
      agentProfileId: 'self_media_creation',
    ),
    AgentFeatureRoute(
      featureId: 'workbench.persona',
      agentProfileId: 'renshe_content',
    ),
    AgentFeatureRoute(
      featureId: 'workbench.lead_content',
      agentProfileId: 'huoke_content',
    ),
    AgentFeatureRoute(
      featureId: 'workbench.lead_strategy',
      agentProfileId: 'huoke_content',
    ),
    AgentFeatureRoute(
      featureId: 'note.sprout',
      agentProfileId: 'faya_germination',
    ),
    AgentFeatureRoute(featureId: 'visual.chat', agentProfileId: 'visual_chat'),
    AgentFeatureRoute(
      featureId: 'positioning.initial',
      agentProfileId: 'positioning_lv1',
    ),
    AgentFeatureRoute(
      featureId: 'deep_positioning',
      agentProfileId: 'positioning_lv2',
    ),
    AgentFeatureRoute(
      featureId: 'video_analysis',
      agentProfileId: 'video_analysis',
    ),
    AgentFeatureRoute(
      featureId: 'book.writing',
      agentProfileId: 'book_writing',
    ),
    AgentFeatureRoute(
      featureId: 'creation.deep_value',
      agentProfileId: 'self_media_creation',
    ),
    AgentFeatureRoute(
      featureId: 'creation.seed',
      agentProfileId: 'self_media_creation',
    ),
    AgentFeatureRoute(
      featureId: 'creation.deal',
      agentProfileId: 'self_media_creation',
    ),
    AgentFeatureRoute(
      featureId: 'creation.exposure',
      agentProfileId: 'self_media_creation',
    ),
    AgentFeatureRoute(
      featureId: 'canvas.demand_deepening',
      agentProfileId: 'self_media_creation',
    ),
    AgentFeatureRoute(
      featureId: 'canvas.differentiation_strengthening',
      agentProfileId: 'self_media_creation',
    ),
    AgentFeatureRoute(
      featureId: 'canvas.theory_elevation',
      agentProfileId: 'self_media_creation',
    ),
    AgentFeatureRoute(
      featureId: 'canvas.atomic_structure',
      agentProfileId: 'self_media_creation',
    ),
    AgentFeatureRoute(
      featureId: 'canvas.expansion',
      agentProfileId: 'self_media_creation',
    ),
    AgentFeatureRoute(
      featureId: 'canvas.shortening',
      agentProfileId: 'self_media_creation',
    ),
    AgentFeatureRoute(
      featureId: 'canvas.relationship_shift',
      agentProfileId: 'self_media_creation',
    ),
    AgentFeatureRoute(
      featureId: 'canvas.opening_labeling',
      agentProfileId: 'self_media_creation',
    ),
    AgentFeatureRoute(
      featureId: 'canvas.opening_defamiliarization',
      agentProfileId: 'self_media_creation',
    ),
    AgentFeatureRoute(
      featureId: 'canvas.memorable_line',
      agentProfileId: 'self_media_creation',
    ),
    AgentFeatureRoute(
      featureId: 'canvas.sales_planning',
      agentProfileId: 'self_media_creation',
    ),
    AgentFeatureRoute(
      featureId: 'canvas.risk_check',
      agentProfileId: 'self_media_creation',
    ),
    AgentFeatureRoute(
      featureId: 'canvas.scene_design',
      agentProfileId: 'self_media_creation',
    ),
    AgentFeatureRoute(
      featureId: 'canvas.spoken_visuals',
      agentProfileId: 'self_media_creation',
    ),
    AgentFeatureRoute(
      featureId: 'canvas.persona_insertion',
      agentProfileId: 'self_media_creation',
    ),
  ];

  static AgentFeatureRoute? forFeature(String featureId) {
    for (final route in all) {
      if (route.featureId == featureId) return route;
    }
    return null;
  }
}

abstract final class ApiContractManifest {
  static const docsCommit = '97e510c8b7e2a2e33cc4bbf809fa666e26983bd3';
  static const docsCatalog = 'products/huahuo-ai/05-api/02-endpoint-catalog.md';

  static final operations = List<ApiContractOperation>.unmodifiable(
    _rawOperations.trim().split('\n').map(_parseOperation),
  );

  static final prohibitedOperations = List<ApiContractOperation>.unmodifiable(
    operations.where(
      (operation) =>
          operation.disposition == ApiOperationDisposition.prohibited,
    ),
  );

  static const prohibitedEndpointIds = <String>{
    'workAiTopicOptions',
    'workAiMaterialCandidates',
    'createWorkAiTopicGeneration',
    'feedDepositSummary',
    'retryFeedDeposit',
  };

  static const retiredEndpointIds = <String>{
    'updateMyProfile',
    'myVoiceprint',
    'createMyVoiceprint',
    'deleteMyVoiceprint',
    'myVoiceprintTask',
    'onboardingContentLine',
    'contentLines',
    'createContentLine',
    'contentLineDetail',
    'setDefaultContentLine',
    'deactivateContentLine',
    'graphSnapshot',
    'videoAnalysisCreate',
    'videoAnalysisDetail',
    'linkImportCreate',
    'linkImportDetail',
    'memoryNotes',
    'memoryNoteDetail',
    'updateMemoryNote',
    'createMemoryNoteAppend',
    'memoryNoteAppends',
    'taskEvents',
  };

  static const retiredClientPaths = <String>{
    '/api/v1/content-lines',
    '/api/v1/content-lines/{contentLineId}',
    '/api/v1/content-lines/{contentLineId}/deactivate',
    '/api/v1/content-lines/{contentLineId}/set-default',
    '/api/v1/graphs/{graphId}',
    '/api/v1/link-imports',
    '/api/v1/link-imports/{taskId}',
    '/api/v1/me/voiceprint',
    '/api/v1/me/voiceprint/tasks/{taskId}',
    '/api/v1/memory-notes',
    '/api/v1/memory-notes/{noteId}',
    '/api/v1/memory-notes/{noteId}/appends',
    '/api/v1/onboarding/content-line',
    '/api/v1/tasks/{taskId}/events',
    '/api/v1/video-analyses',
    '/api/v1/video-analyses/{taskId}',
  };

  static bool isProhibitedEndpointId(String endpointId) =>
      prohibitedEndpointIds.contains(endpointId);

  static bool isRetiredEndpointId(String endpointId) =>
      retiredEndpointIds.contains(endpointId);

  static ApiContractOperation? find(HttpMethod method, String path) {
    for (final operation in operations) {
      if (operation.method == method && operation.path == path) {
        return operation;
      }
    }
    return null;
  }
}

ApiContractOperation _parseOperation(String row) {
  final fields = row.split('|');
  if (fields.length != 4) {
    throw StateError('Invalid API contract manifest row');
  }
  final scope = fields[0] == 'formal'
      ? ApiContractScope.formal
      : ApiContractScope.retained;
  final method = HttpMethod.values.singleWhere(
    (candidate) => candidate.value == fields[1],
  );
  final path = '/api/v1${fields[2]}';
  final key = '${method.value} $path';
  return ApiContractOperation(
    scope: scope,
    method: method,
    path: path,
    authority: 'API ${fields[3]}',
    disposition: _prohibitedOperationKeys.contains(key)
        ? ApiOperationDisposition.prohibited
        : _wiredBothOperationKeys.contains(key)
        ? ApiOperationDisposition.wiredBoth
        : _wiredMobileOperationKeys.contains(key)
        ? ApiOperationDisposition.wiredMobile
        : _wiredDesktopOperationKeys.contains(key)
        ? ApiOperationDisposition.wiredDesktop
        : ApiOperationDisposition.contractOnly,
    responseKind: path.endsWith('/events/stream')
        ? ApiResponseKind.sse
        : path.endsWith('/export') || path.endsWith('/subscription-assets')
        ? ApiResponseKind.binary
        : ApiResponseKind.jsonEnvelope,
  );
}

const _prohibitedOperationKeys = <String>{
  'GET /api/v1/work-ai/material-candidates',
  'GET /api/v1/work-ai/topic-generation/options',
  'POST /api/v1/work-ai/topic-generations',
  'GET /api/v1/feed-ai/messages/{messageId}/deposit-summary',
  'POST /api/v1/feed-ai/messages/{messageId}/retry-deposit',
};

const _wiredBothOperationKeys = <String>{
  'POST /api/v1/auth/login',
  'POST /api/v1/auth/refresh',
  'POST /api/v1/auth/sms-code',
  'GET /api/v1/me/status',
  'GET /api/v1/chat/threads',
  'POST /api/v1/chat/threads',
  'GET /api/v1/chat/threads/{threadId}',
  'POST /api/v1/chat/threads/{threadId}/messages',
  'POST /api/v1/agent/runs',
  'GET /api/v1/agent/runs/{agentRunId}',
  'GET /api/v1/agent-profiles',
  'GET /api/v1/agent-profiles/{agentProfileId}/skills',
  'GET /api/v1/agent-profiles/{agentProfileId}/models',
  'GET /api/v1/workspaces/{workspaceId}/skill-installations',
  'GET /api/v1/workspaces/{workspaceId}/content-snapshot',
  'GET /api/v1/workspaces/{workspaceId}/content-changes',
  'GET /api/v1/recording-card/device-binding',
  'POST /api/v1/workspaces/{workspaceId}/notes',
  'GET /api/v1/workspaces/{workspaceId}/notes/{noteId}',
  'PATCH /api/v1/workspaces/{workspaceId}/notes/{noteId}',
  'POST /api/v1/workspaces/{workspaceId}/search',
  'GET /api/v1/workspaces/{workspaceId}/book',
  'GET /api/v1/workspaces/{workspaceId}/book/sections/{sectionKey}/parts/{part}',
  'GET /api/v1/workspaces/{workspaceId}/work',
  'GET /api/v1/workspaces/{workspaceId}/work/{workId}',
  'POST /api/v1/workspaces/{workspaceId}/work/{workId}/complete',
  'GET /api/v1/workspaces/{workspaceId}/work/{workId}/parts/{part}',
  'POST /api/v1/workspaces/{workspaceId}/work/{workId}/promotions',
  'GET /api/v1/subscription/publications',
  'GET /api/v1/subscription/articles',
  'GET /api/v1/subscription/articles/{articleId}',
  'GET /api/v1/workspaces/{workspaceId}/subscription-library/publications',
  'PUT /api/v1/workspaces/{workspaceId}/subscription-library/publications/{publicationId}',
  'DELETE /api/v1/workspaces/{workspaceId}/subscription-library/publications/{publicationId}',
  'POST /api/v1/workspaces/{workspaceId}/subscription-articles/{articleId}/save-as-note',
  'GET /api/v1/membership',
  'GET /api/v1/account/credits',
  'GET /api/v1/runs/{runId}/usage',
};

const _wiredMobileOperationKeys = <String>{
  'POST /api/v1/recording-card/bind-challenge',
  'POST /api/v1/recording-card/bind',
  'POST /api/v1/recording-card/devices/{deviceId}/unbind',
  'POST /api/v1/workspaces/{workspaceId}/document-change-proposals',
  'GET /api/v1/workspaces/{workspaceId}/document-change-proposals/{proposalId}',
  'GET /api/v1/workspaces/{workspaceId}/document-change-proposals/{proposalId}/diff',
  'GET /api/v1/workspaces/{workspaceId}/document-change-proposals/{proposalId}/candidate',
  'POST /api/v1/workspaces/{workspaceId}/document-change-proposals/{proposalId}/apply',
  'POST /api/v1/workspaces/{workspaceId}/document-change-proposals/{proposalId}/reject',
  'POST /api/v1/workspaces/{workspaceId}/document-change-proposals/{proposalId}/cancel',
  'PUT /api/v1/me/timezone',
  'GET /api/v1/workspaces/current/profile',
  'GET /api/v1/app/config',
  'GET /api/v1/home',
  'POST /api/v1/analytics/events',
  'POST /api/v1/workspace/retry-create',
  'POST /api/v1/onboarding/creative-positioning',
  'POST /api/v1/media/upload-token',
  'POST /api/v1/media/uploads/{uploadId}/complete',
  'GET /api/v1/recording-card/files',
  'POST /api/v1/recording-card/devices/bind',
  'POST /api/v1/recording-card/files/sync',
  'POST /api/v1/recording-card/files/{cardFileId}/link-upload',
  'GET /api/v1/recordings',
  'POST /api/v1/recordings',
  'GET /api/v1/recordings/{recordingId}',
  'GET /api/v1/notifications',
  'POST /api/v1/notifications/{notificationId}/read',
  'POST /api/v1/notification-devices',
  'DELETE /api/v1/notification-devices/{deviceId}',
  'GET /api/v1/workspaces/{workspaceId}/notes',
  'POST /api/v1/workspaces/{workspaceId}/folders',
  'PATCH /api/v1/workspaces/{workspaceId}/folders/{folderId}',
  'DELETE /api/v1/workspaces/{workspaceId}/folders/{folderId}',
  'POST /api/v1/workspaces/{workspaceId}/folders/{folderId}/move',
  'POST /api/v1/workspaces/{workspaceId}/folders/{folderId}/restore',
  'POST /api/v1/workspaces/{workspaceId}/notes/batch-move',
  'GET /api/v1/subscription/articles/{articleId}/revisions/{articleRevisionId}',
  'GET /api/v1/subscription/articles/{articleId}/revisions/{articleRevisionId}/assets/{fileKey}',
  'GET /api/v1/workspaces/{workspaceId}/notes/{noteId}/subscription-assets',
  'GET /api/v1/billing/catalog',
  'POST /api/v1/billing/android/orders',
  'GET /api/v1/billing/orders/{orderId}',
  'POST /api/v1/billing/ios/purchases/verify',
  'GET /api/v1/billing/transactions',
};

const _wiredDesktopOperationKeys = <String>{
  'GET /api/v1/assets/overview',
  'GET /api/v1/assets/{assetType}/{assetId}',
  'GET /api/v1/assets/markdown',
  'POST /api/v1/assets/sync',
  'GET /api/v1/workspaces/{workspaceId}/folders',
  'GET /api/v1/workspaces/{workspaceId}/notes/{noteId}/parts/{part}',
  'GET /api/v1/workspaces/{workspaceId}/notes/{noteId}/relations',
  'DELETE /api/v1/workspaces/{workspaceId}/note-relations/{relationId}',
};

const _rawOperations = r'''
formal|GET|/agent/meta-workspaces|19
formal|POST|/agent/runs|19
formal|GET|/agent/runs/{agentRunId}|19
formal|GET|/agent/runs/{agentRunId}/events|19
formal|GET|/agent/runs/{agentRunId}/events/stream|19
formal|POST|/agent/runs/{agentRunId}/cancel|19
formal|GET|/recording-card/device-binding|19
formal|POST|/recording-card/bind-challenge|19
formal|POST|/recording-card/bind|19
formal|POST|/recording-card/devices/{deviceId}/unbind|19
formal|POST|/media/upload-token|19
formal|POST|/media/uploads/{uploadId}/complete|19
formal|POST|/chat/threads/{threadId}/messages|19
formal|GET|/agent-profiles|23
formal|GET|/agent-profiles/{agentProfileId}/skills|23
formal|GET|/agent-profiles/{agentProfileId}/models|23
formal|GET|/workspaces/{workspaceId}/skill-installations|23
formal|POST|/workspaces/{workspaceId}/skill-installations|23
formal|PATCH|/workspaces/{workspaceId}/skill-installations/{skillProfileId}|23
formal|DELETE|/workspaces/{workspaceId}/skill-installations/{skillProfileId}|23
formal|GET|/workspaces|21
formal|POST|/workspaces|21
formal|GET|/workspaces/{workspaceId}|21
formal|PATCH|/workspaces/{workspaceId}|21
formal|POST|/workspaces/{workspaceId}/set-default|21
formal|POST|/workspaces/{workspaceId}/disable|21
formal|POST|/workspaces/{workspaceId}/restore|21
formal|GET|/workspaces/{workspaceId}/storage-usage|21
formal|GET|/workspaces/{workspaceId}/content-snapshot|21
formal|GET|/workspaces/{workspaceId}/content-changes|21
formal|GET|/workspaces/{workspaceId}/folders|20
formal|POST|/workspaces/{workspaceId}/folders|20
formal|GET|/workspaces/{workspaceId}/folders/{folderId}|20
formal|PATCH|/workspaces/{workspaceId}/folders/{folderId}|20
formal|DELETE|/workspaces/{workspaceId}/folders/{folderId}|20
formal|POST|/workspaces/{workspaceId}/folders/{folderId}/move|20
formal|POST|/workspaces/{workspaceId}/folders/{folderId}/restore|20
formal|GET|/workspaces/{workspaceId}/notes|20
formal|POST|/workspaces/{workspaceId}/notes|20
formal|GET|/workspaces/{workspaceId}/notes/{noteId}|20
formal|PATCH|/workspaces/{workspaceId}/notes/{noteId}|20
formal|DELETE|/workspaces/{workspaceId}/notes/{noteId}|20
formal|GET|/workspaces/{workspaceId}/notes/{noteId}/parts/{part}|20
formal|POST|/workspaces/{workspaceId}/notes/{noteId}/restore|20
formal|GET|/workspaces/{workspaceId}/notes/{noteId}/export|20
formal|POST|/workspaces/{workspaceId}/note-imports|20
formal|GET|/workspaces/{workspaceId}/positioning|22
formal|PUT|/workspaces/{workspaceId}/positioning|22
formal|GET|/workspaces/{workspaceId}/positioning/revisions|22
formal|GET|/workspaces/{workspaceId}/profile-visual-assets|22
formal|POST|/workspaces/{workspaceId}/profile-visual-assets|22
formal|PATCH|/workspaces/{workspaceId}/profile-visual-assets/{visualAssetId}|22
formal|DELETE|/workspaces/{workspaceId}/profile-visual-assets/{visualAssetId}|22
formal|GET|/workspaces/{workspaceId}/fixed-assets|22
formal|GET|/workspaces/{workspaceId}/fixed-assets/{assetKind}|22
formal|PUT|/workspaces/{workspaceId}/fixed-assets/{assetKind}|22
formal|GET|/workspaces/{workspaceId}/fixed-assets/{assetKind}/revisions|22
formal|GET|/workspaces/{workspaceId}/creations|22
formal|POST|/workspaces/{workspaceId}/creations|22
formal|GET|/workspaces/{workspaceId}/creations/{creationId}|22
formal|PATCH|/workspaces/{workspaceId}/creations/{creationId}|22
formal|DELETE|/workspaces/{workspaceId}/creations/{creationId}|22
formal|POST|/workspaces/{workspaceId}/creations/{creationId}/restore|22
formal|GET|/workspaces/{workspaceId}/creations/{creationId}/parts/{part}|22
formal|PUT|/workspaces/{workspaceId}/creations/{creationId}/parts/{part}|22
formal|GET|/workspaces/{workspaceId}/creations/{creationId}/parts/{part}/revisions|22
formal|GET|/workspaces/{workspaceId}/content-navigation/{map}|22
formal|POST|/workspaces/{workspaceId}/search|22
formal|GET|/workspaces/{workspaceId}/notes/{noteId}/relations|22
formal|POST|/workspaces/{workspaceId}/notes/{noteId}/relations|22
formal|PATCH|/workspaces/{workspaceId}/note-relations/{relationId}|22
formal|DELETE|/workspaces/{workspaceId}/note-relations/{relationId}|22
formal|GET|/workspaces/{workspaceId}/book|24
formal|PUT|/workspaces/{workspaceId}/book|24
formal|GET|/workspaces/{workspaceId}/book/revisions|24
formal|GET|/workspaces/{workspaceId}/book/revisions/{bookRevisionId}|24
formal|POST|/workspaces/{workspaceId}/book/import|24
formal|GET|/workspaces/{workspaceId}/book/imports/{bookImportId}|24
formal|POST|/workspaces/{workspaceId}/book/sections|24
formal|GET|/workspaces/{workspaceId}/book/sections/{sectionKey}|24
formal|PATCH|/workspaces/{workspaceId}/book/sections/{sectionKey}|24
formal|DELETE|/workspaces/{workspaceId}/book/sections/{sectionKey}|24
formal|POST|/workspaces/{workspaceId}/book/sections/{sectionKey}/restore|24
formal|POST|/workspaces/{workspaceId}/book/sections/{sectionKey}/move|24
formal|GET|/workspaces/{workspaceId}/book/sections/{sectionKey}/parts/{part}|24
formal|PUT|/workspaces/{workspaceId}/book/sections/{sectionKey}/parts/{part}|24
formal|GET|/workspaces/{workspaceId}/book/sections/{sectionKey}/parts/{part}/revisions|24
formal|GET|/workspaces/{workspaceId}/book/export|24
formal|GET|/workspaces/{workspaceId}/work|24
formal|POST|/workspaces/{workspaceId}/work|24
formal|GET|/workspaces/{workspaceId}/work/{workId}|24
formal|PATCH|/workspaces/{workspaceId}/work/{workId}|24
formal|DELETE|/workspaces/{workspaceId}/work/{workId}|24
formal|POST|/workspaces/{workspaceId}/work/{workId}/restore|24
formal|POST|/workspaces/{workspaceId}/work/{workId}/complete|24
formal|GET|/workspaces/{workspaceId}/work/{workId}/parts/{part}|24
formal|PUT|/workspaces/{workspaceId}/work/{workId}/parts/{part}|24
formal|GET|/workspaces/{workspaceId}/work/{workId}/parts/{part}/revisions|24
formal|POST|/workspaces/{workspaceId}/work/{workId}/promotions|24
formal|GET|/subscription/publications|25
formal|GET|/subscription/publications/{publicationId}|25
formal|GET|/subscription/publications/{publicationId}/sections|25
formal|GET|/subscription/articles|25
formal|GET|/subscription/articles/{articleId}|25
formal|GET|/subscription/articles/{articleId}/revisions|25
formal|GET|/subscription/articles/{articleId}/revisions/{articleRevisionId}|25
formal|GET|/subscription/articles/{articleId}/revisions/{articleRevisionId}/assets/{fileKey}|25
formal|GET|/workspaces/{workspaceId}/subscription-library/publications|25
formal|PUT|/workspaces/{workspaceId}/subscription-library/publications/{publicationId}|25
formal|DELETE|/workspaces/{workspaceId}/subscription-library/publications/{publicationId}|25
formal|POST|/workspaces/{workspaceId}/subscription-articles/{articleId}/save-as-note|25
formal|GET|/workspaces/{workspaceId}/notes/{noteId}/subscription-assets|25
formal|GET|/membership|27
formal|GET|/account/credits|27
formal|GET|/runs/{runId}/usage|27
formal|GET|/billing/catalog|28
formal|POST|/billing/android/orders|28
formal|GET|/billing/orders/{orderId}|28
formal|POST|/billing/ios/purchases/verify|28
formal|GET|/billing/transactions|28
formal|POST|/billing/wechat/notify|28
formal|POST|/billing/alipay/notify|28
formal|POST|/billing/apple/notifications/v2|28
retained|POST|/agent/runs/{agentRunId}/confirm|14
retained|POST|/analytics/events|11
retained|GET|/app/config|11
retained|GET|/asr-tasks/{asrTaskId}|05
retained|POST|/asr-tasks/{asrTaskId}/retry|05
retained|GET|/assets/{assetType}/{assetId}|07
retained|PATCH|/assets/{assetType}/{assetId}|07
retained|GET|/assets/markdown|07
retained|GET|/assets/overview|07
retained|GET|/assets/recordings/{recordingId}|07
retained|POST|/assets/sync|07
retained|POST|/auth/login|03
retained|POST|/auth/refresh|03
retained|POST|/auth/sms-code|03
retained|GET|/chat/threads|06
retained|POST|/chat/threads|06
retained|GET|/chat/threads/{threadId}|06
retained|POST|/chat/threads/{threadId}/voice-messages|06
retained|POST|/chat/threads/{threadId}/workspace-switch|14
retained|GET|/feed-ai/messages/{messageId}/deposit-summary|06
retained|POST|/feed-ai/messages/{messageId}/retry-deposit|06
retained|GET|/home|04
retained|POST|/home/hotspot-suggestions/{suggestionId}/viewed|04
retained|GET|/me/status|03
retained|PUT|/me/timezone|03
retained|POST|/notification-devices|07
retained|DELETE|/notification-devices/{deviceId}|07
retained|GET|/notifications|07
retained|POST|/notifications/{notificationId}/read|07
retained|POST|/onboarding/creative-positioning|04
retained|GET|/profile|04
retained|POST|/profile|04
retained|GET|/profile/{creativePositioningId}|04
retained|POST|/profile/{creativePositioningId}/deactivate|04
retained|POST|/profile/{creativePositioningId}/set-default|04
retained|POST|/recording-card/devices/bind|05
retained|GET|/recording-card/files|05
retained|POST|/recording-card/files/{cardFileId}/link-upload|05
retained|POST|/recording-card/files/sync|05
retained|GET|/recordings|05
retained|POST|/recordings|05
retained|GET|/recordings/{recordingId}|05
retained|POST|/recordings/{recordingId}/retry|05
retained|POST|/recordings/{recordingId}/speaker-label-draft|05
retained|GET|/recordings/{recordingId}/speaker-label-panel|05
retained|POST|/recordings/{recordingId}/speaker-labels|05
retained|POST|/red-dots/clear|07
retained|GET|/tasks/{taskId}|06
retained|POST|/tasks/{taskId}/regenerate|06
retained|POST|/tasks/{taskId}/retry|06
retained|GET|/tasks/running|04
retained|GET|/work-ai/material-candidates|06
retained|GET|/work-ai/topic-generation/options|06
retained|POST|/work-ai/topic-generations|06
retained|POST|/workspace/retry-create|04
retained|POST|/workspaces/{workspaceId}/document-change-proposals|29
retained|GET|/workspaces/{workspaceId}/document-change-proposals|29
retained|GET|/workspaces/{workspaceId}/document-change-proposals/{proposalId}|29
retained|GET|/workspaces/{workspaceId}/document-change-proposals/{proposalId}/diff|29
retained|GET|/workspaces/{workspaceId}/document-change-proposals/{proposalId}/candidate|29
retained|POST|/workspaces/{workspaceId}/document-change-proposals/{proposalId}/apply|29
retained|POST|/workspaces/{workspaceId}/document-change-proposals/{proposalId}/reject|29
retained|POST|/workspaces/{workspaceId}/document-change-proposals/{proposalId}/cancel|29
retained|POST|/workspaces/{workspaceId}/document-change-proposals/{proposalId}/rebase|29
retained|GET|/workspaces/{workspaceId}/materials|15
retained|GET|/workspaces/{workspaceId}/materials/{materialId}|15
retained|GET|/workspaces/{workspaceId}/materials/{materialId}/jobs/{jobId}|15
retained|POST|/workspaces/{workspaceId}/materials/{materialId}/jobs/{jobId}/retry|15
retained|GET|/workspaces/{workspaceId}/materials/{materialId}/variants/{variant}|15
retained|GET|/workspaces/{workspaceId}/materials/{materialId}/variants/{variant}/revisions|15
retained|GET|/workspaces/{workspaceId}/note-folders|20
retained|POST|/workspaces/{workspaceId}/note-folders|20
retained|DELETE|/workspaces/{workspaceId}/note-folders/{folderId}|20
retained|PATCH|/workspaces/{workspaceId}/note-folders/{folderId}|20
retained|POST|/workspaces/{workspaceId}/note-ingestions|20
retained|DELETE|/workspaces/{workspaceId}/note-ingestions/{ingestionId}|20
retained|GET|/workspaces/{workspaceId}/note-ingestions/{ingestionId}|20
retained|POST|/workspaces/{workspaceId}/note-ingestions/{ingestionId}/promote|20
retained|POST|/workspaces/{workspaceId}/notes/{noteId}/generate|20
retained|PUT|/workspaces/{workspaceId}/notes/{noteId}/parts/{part}|20
retained|GET|/workspaces/{workspaceId}/notes/{noteId}/parts/{part}/revisions|20
retained|GET|/workspaces/{workspaceId}/notes/{noteId}/proposals/{proposalId}|20
retained|POST|/workspaces/{workspaceId}/notes/{noteId}/proposals/{proposalId}/apply|20
retained|POST|/workspaces/{workspaceId}/notes/{noteId}/proposals/{proposalId}/reject|20
retained|POST|/workspaces/{workspaceId}/notes/batch-move|20
retained|POST|/workspaces/{workspaceId}/notes/chat-excerpts|20
retained|POST|/workspaces/{workspaceId}/notes/manual|20
retained|GET|/workspaces/{workspaceId}/note-types|20
retained|POST|/workspaces/{workspaceId}/note-types|20
retained|PATCH|/workspaces/{workspaceId}/note-types/{noteTypeId}|20
retained|GET|/workspaces/current/profile|20
retained|GET|/workspaces/{workspaceId}/profile|20
''';
