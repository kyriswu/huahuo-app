enum HttpMethod {
  get('GET'),
  post('POST'),
  put('PUT'),
  patch('PATCH'),
  delete('DELETE');

  const HttpMethod(this.value);

  final String value;
}

enum EndpointAuthPolicy { required, optional, none }

enum EndpointIdempotencyPolicy { required, recommended, forbidden }

/// Every callable GET declares whether a platform may retain its response.
/// The shared catalog never owns cache storage or account scope.
enum EndpointReadCachePolicy {
  conditional,
  incremental,
  networkFirst,
  prohibited,
}

enum BackendIntegrationStatus { connected, contractReady, localOnly, deferred }

enum EndpointResponseMode {
  strictEnvelope,
  legacyCompatible,
  empty,
  binary,
  sse,
}

enum BackendCapability {
  app,
  auth,
  profile,
  voiceprint,
  workspace,
  contentLines,
  graph,
  tasks,
  media,
  ingestion,
  knowledge,
  recordingCard,
  recordings,
  chat,
  workAi,
  feed,
  assets,
  membership,
  notifications,
  analytics,
  agent,
  subscription,
  book,
  account,
  billing,
}

final class EndpointDefinition {
  EndpointDefinition({
    required this.id,
    required this.method,
    required this.pathTemplate,
    required this.auth,
    required this.idempotency,
    BackendCapability? capability,
    this.contractVersion = 'v1',
    BackendIntegrationStatus? integrationStatus,
    EndpointResponseMode responseMode = EndpointResponseMode.strictEnvelope,
    this.docsAuthority =
        'Docs 97e510c8 products/huahuo-ai/05-api retained App operation',
    String? responseType,
    String? idempotencyHeaderName,
    EndpointReadCachePolicy? readCachePolicy,
  }) : responseMode = responseMode,
       responseType = responseType ?? _responseTypeForMode(responseMode),
       capability = capability ?? _capabilityForEndpoint(id),
       idempotencyHeaderName =
           idempotencyHeaderName ??
           ((_formalWorkspaceEndpointIds.contains(id) ||
                   _billingEndpointIds.contains(id))
               ? 'Idempotency-Key'
               : 'X-Idempotency-Key'),
       integrationStatus =
           integrationStatus ??
           (_contractReadyEndpointIds.contains(id)
               ? BackendIntegrationStatus.contractReady
               : _deferredEndpointIds.contains(id)
               ? BackendIntegrationStatus.deferred
               : BackendIntegrationStatus.connected),
       readCachePolicy =
           readCachePolicy ??
           (method == HttpMethod.get
               ? EndpointReadCachePolicy.networkFirst
               : EndpointReadCachePolicy.prohibited);

  final String id;
  final HttpMethod method;
  final String pathTemplate;
  final EndpointAuthPolicy auth;
  final EndpointIdempotencyPolicy idempotency;
  final String idempotencyHeaderName;
  final BackendCapability capability;
  final String contractVersion;
  final BackendIntegrationStatus integrationStatus;
  final EndpointResponseMode responseMode;
  final String docsAuthority;
  final String responseType;
  final EndpointReadCachePolicy readCachePolicy;

  bool get isStreaming => responseMode == EndpointResponseMode.sse;
}

final class ResolvedEndpoint {
  const ResolvedEndpoint({required this.definition, required this.path});

  final EndpointDefinition definition;
  final String path;

  String get id => definition.id;
  HttpMethod get method => definition.method;
  EndpointAuthPolicy get auth => definition.auth;
  EndpointIdempotencyPolicy get idempotency => definition.idempotency;
  String get idempotencyHeaderName => definition.idempotencyHeaderName;
  BackendCapability get capability => definition.capability;
  String get contractVersion => definition.contractVersion;
  BackendIntegrationStatus get integrationStatus =>
      definition.integrationStatus;
  EndpointResponseMode get responseMode => definition.responseMode;
  String get docsAuthority => definition.docsAuthority;
  String get responseType => definition.responseType;
  EndpointReadCachePolicy get readCachePolicy => definition.readCachePolicy;
  bool get isStreaming => definition.isStreaming;
}

typedef EndpointPathParams = Map<String, Object>;

final class EndpointCatalog {
  const EndpointCatalog._();

  static final definitions = <String, EndpointDefinition>{
    'appConfig': EndpointDefinition(
      id: 'appConfig',
      method: HttpMethod.get,
      pathTemplate: '/api/v1/app/config',
      auth: EndpointAuthPolicy.optional,
      idempotency: EndpointIdempotencyPolicy.forbidden,
    ),
    'authSmsCode': EndpointDefinition(
      id: 'authSmsCode',
      method: HttpMethod.post,
      pathTemplate: '/api/v1/auth/sms-code',
      auth: EndpointAuthPolicy.none,
      idempotency: EndpointIdempotencyPolicy.recommended,
      responseMode: EndpointResponseMode.legacyCompatible,
    ),
    'authLogin': EndpointDefinition(
      id: 'authLogin',
      method: HttpMethod.post,
      pathTemplate: '/api/v1/auth/login',
      auth: EndpointAuthPolicy.none,
      idempotency: EndpointIdempotencyPolicy.recommended,
    ),
    'authRefresh': EndpointDefinition(
      id: 'authRefresh',
      method: HttpMethod.post,
      pathTemplate: '/api/v1/auth/refresh',
      auth: EndpointAuthPolicy.none,
      idempotency: EndpointIdempotencyPolicy.forbidden,
    ),
    'meStatus': EndpointDefinition(
      id: 'meStatus',
      method: HttpMethod.get,
      pathTemplate: '/api/v1/me/status',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.forbidden,
    ),
    'meProfile': EndpointDefinition(
      id: 'meProfile',
      method: HttpMethod.get,
      pathTemplate: '/api/v1/me/profile',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.forbidden,
      responseMode: EndpointResponseMode.legacyCompatible,
      capability: BackendCapability.profile,
      docsAuthority: 'Backend deployed authenticated user profile contract',
    ),
    'updateMeProfile': EndpointDefinition(
      id: 'updateMeProfile',
      method: HttpMethod.patch,
      pathTemplate: '/api/v1/me/profile',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.required,
      idempotencyHeaderName: 'X-Idempotency-Key',
      responseMode: EndpointResponseMode.legacyCompatible,
      capability: BackendCapability.profile,
      docsAuthority: 'Backend deployed authenticated user profile contract',
    ),
    'updateMeTimezone': EndpointDefinition(
      id: 'updateMeTimezone',
      method: HttpMethod.put,
      pathTemplate: '/api/v1/me/timezone',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.required,
      idempotencyHeaderName: 'X-Idempotency-Key',
      capability: BackendCapability.auth,
      docsAuthority: 'API 03 authenticated user time-zone mutation',
    ),
    'home': EndpointDefinition(
      id: 'home',
      method: HttpMethod.get,
      pathTemplate: '/api/v1/home',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.forbidden,
      capability: BackendCapability.app,
    ),
    'markHotspotSuggestionViewed': EndpointDefinition(
      id: 'markHotspotSuggestionViewed',
      method: HttpMethod.post,
      pathTemplate: '/api/v1/home/hotspot-suggestions/{suggestionId}/viewed',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.required,
      capability: BackendCapability.app,
      integrationStatus: BackendIntegrationStatus.contractReady,
      docsAuthority: 'Retained API 04 contract; no current mobile owner',
    ),
    'onboardingCreativePositioning': EndpointDefinition(
      id: 'onboardingCreativePositioning',
      method: HttpMethod.post,
      pathTemplate: '/api/v1/onboarding/creative-positioning',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.required,
      capability: BackendCapability.profile,
    ),
    'createWorkspaceInitialPositioningAttempt': EndpointDefinition(
      id: 'createWorkspaceInitialPositioningAttempt',
      method: HttpMethod.post,
      pathTemplate:
          '/api/v1/workspaces/{workspaceId}/initial-positioning/attempts',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.required,
      capability: BackendCapability.profile,
      docsAuthority: 'Deployed server-managed Position LV1 finalization',
    ),
    'currentWorkspaceInitialPositioning': EndpointDefinition(
      id: 'currentWorkspaceInitialPositioning',
      method: HttpMethod.get,
      pathTemplate:
          '/api/v1/workspaces/{workspaceId}/initial-positioning/current',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.forbidden,
      capability: BackendCapability.profile,
      readCachePolicy: EndpointReadCachePolicy.networkFirst,
      docsAuthority: 'Deployed server-managed Position LV1 finalization',
    ),
    'creativePositionings': EndpointDefinition(
      id: 'creativePositionings',
      method: HttpMethod.get,
      pathTemplate: '/api/v1/creative-positionings',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.forbidden,
      capability: BackendCapability.profile,
      docsAuthority: 'Deployed canonical creative-positioning list',
    ),
    'currentWorkspaceProfile': EndpointDefinition(
      id: 'currentWorkspaceProfile',
      method: HttpMethod.get,
      pathTemplate: '/api/v1/workspaces/current/profile',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.forbidden,
      capability: BackendCapability.profile,
      integrationStatus: BackendIntegrationStatus.connected,
      docsAuthority: 'Deployed Position LV1 current Workspace Profile snapshot',
    ),
    'workspaceRetryCreate': EndpointDefinition(
      id: 'workspaceRetryCreate',
      method: HttpMethod.post,
      pathTemplate: '/api/v1/workspace/retry-create',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.required,
    ),
    'workspaces': EndpointDefinition(
      id: 'workspaces',
      method: HttpMethod.get,
      pathTemplate: '/api/v1/workspaces',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.forbidden,
      capability: BackendCapability.workspace,
    ),
    'createWorkspace': EndpointDefinition(
      id: 'createWorkspace',
      method: HttpMethod.post,
      pathTemplate: '/api/v1/workspaces',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.required,
      idempotencyHeaderName: 'X-Idempotency-Key',
      capability: BackendCapability.workspace,
    ),
    'workspaceDetail': EndpointDefinition(
      id: 'workspaceDetail',
      method: HttpMethod.get,
      pathTemplate: '/api/v1/workspaces/{workspaceId}',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.forbidden,
      capability: BackendCapability.workspace,
    ),
    'updateWorkspace': EndpointDefinition(
      id: 'updateWorkspace',
      method: HttpMethod.patch,
      pathTemplate: '/api/v1/workspaces/{workspaceId}',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.required,
      idempotencyHeaderName: 'X-Idempotency-Key',
      capability: BackendCapability.workspace,
    ),
    'setDefaultWorkspace': EndpointDefinition(
      id: 'setDefaultWorkspace',
      method: HttpMethod.post,
      pathTemplate: '/api/v1/workspaces/{workspaceId}/set-default',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.required,
      idempotencyHeaderName: 'X-Idempotency-Key',
      capability: BackendCapability.workspace,
    ),
    'disableWorkspace': EndpointDefinition(
      id: 'disableWorkspace',
      method: HttpMethod.post,
      pathTemplate: '/api/v1/workspaces/{workspaceId}/disable',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.required,
      idempotencyHeaderName: 'X-Idempotency-Key',
      capability: BackendCapability.workspace,
    ),
    'restoreWorkspace': EndpointDefinition(
      id: 'restoreWorkspace',
      method: HttpMethod.post,
      pathTemplate: '/api/v1/workspaces/{workspaceId}/restore',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.required,
      idempotencyHeaderName: 'X-Idempotency-Key',
      capability: BackendCapability.workspace,
    ),
    'workspaceStorageUsage': EndpointDefinition(
      id: 'workspaceStorageUsage',
      method: HttpMethod.get,
      pathTemplate: '/api/v1/workspaces/{workspaceId}/storage-usage',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.forbidden,
      capability: BackendCapability.workspace,
    ),
    'workspaceNotes': EndpointDefinition(
      id: 'workspaceNotes',
      method: HttpMethod.get,
      pathTemplate: '/api/v1/workspaces/{workspaceId}/notes',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.forbidden,
      capability: BackendCapability.knowledge,
    ),
    'dailyTopicRecommendations': EndpointDefinition(
      id: 'dailyTopicRecommendations',
      method: HttpMethod.get,
      pathTemplate: '/api/v1/workspaces/{workspaceId}/topic-recommendations',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.forbidden,
      capability: BackendCapability.workAi,
      docsAuthority: 'Production Daily Topic Recommendation contract',
    ),
    'dailyTopicRecommendation': EndpointDefinition(
      id: 'dailyTopicRecommendation',
      method: HttpMethod.get,
      pathTemplate:
          '/api/v1/workspaces/{workspaceId}/topic-recommendations/{recommendationId}',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.forbidden,
      capability: BackendCapability.workAi,
      docsAuthority: 'Production Daily Topic Recommendation contract',
    ),
    'readDailyTopicRecommendation': EndpointDefinition(
      id: 'readDailyTopicRecommendation',
      method: HttpMethod.post,
      pathTemplate:
          '/api/v1/workspaces/{workspaceId}/topic-recommendations/{recommendationId}/read',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.required,
      idempotencyHeaderName: 'X-Idempotency-Key',
      capability: BackendCapability.workAi,
      docsAuthority: 'Production Daily Topic Recommendation contract',
    ),
    'dismissDailyTopicRecommendation': EndpointDefinition(
      id: 'dismissDailyTopicRecommendation',
      method: HttpMethod.post,
      pathTemplate:
          '/api/v1/workspaces/{workspaceId}/topic-recommendations/{recommendationId}/dismiss',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.required,
      idempotencyHeaderName: 'X-Idempotency-Key',
      capability: BackendCapability.workAi,
      docsAuthority: 'Production Daily Topic Recommendation contract',
    ),
    'useDailyTopicRecommendation': EndpointDefinition(
      id: 'useDailyTopicRecommendation',
      method: HttpMethod.post,
      pathTemplate:
          '/api/v1/workspaces/{workspaceId}/topic-recommendations/{recommendationId}/use',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.required,
      idempotencyHeaderName: 'X-Idempotency-Key',
      capability: BackendCapability.workAi,
      docsAuthority: 'Production Daily Topic Recommendation contract',
    ),
    'createNoteTopicCollisionRun': EndpointDefinition(
      id: 'createNoteTopicCollisionRun',
      method: HttpMethod.post,
      pathTemplate:
          '/api/v1/workspaces/{workspaceId}/note-topic-collision-runs',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.required,
      idempotencyHeaderName: 'X-Idempotency-Key',
      capability: BackendCapability.workAi,
      docsAuthority: 'Production topic-file smoke contract',
    ),
    'noteTopicCollisionRun': EndpointDefinition(
      id: 'noteTopicCollisionRun',
      method: HttpMethod.get,
      pathTemplate:
          '/api/v1/workspaces/{workspaceId}/note-topic-collision-runs/{topicCollisionRunId}',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.forbidden,
      capability: BackendCapability.workAi,
      docsAuthority: 'Production topic-file smoke contract',
    ),
    'createWorkspaceNoteIngestion': EndpointDefinition(
      id: 'createWorkspaceNoteIngestion',
      method: HttpMethod.post,
      pathTemplate: '/api/v1/workspaces/{workspaceId}/note-ingestions',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.required,
      idempotencyHeaderName: 'X-Idempotency-Key',
      capability: BackendCapability.knowledge,
      docsAuthority: 'Docs API 20 Workspace Note ingestion transport',
    ),
    'workspaceNoteIngestion': EndpointDefinition(
      id: 'workspaceNoteIngestion',
      method: HttpMethod.get,
      pathTemplate:
          '/api/v1/workspaces/{workspaceId}/note-ingestions/{ingestionId}',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.forbidden,
      capability: BackendCapability.knowledge,
      docsAuthority: 'Docs API 20 Workspace Note ingestion transport',
    ),
    'workspaceNoteIngestionMediaPreview': EndpointDefinition(
      id: 'workspaceNoteIngestionMediaPreview',
      method: HttpMethod.get,
      pathTemplate:
          '/api/v1/workspaces/{workspaceId}/note-ingestions/{ingestionId}/media-preview',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.forbidden,
      capability: BackendCapability.knowledge,
      docsAuthority: 'Deployed Workspace Note URL media-preview contract',
      readCachePolicy: EndpointReadCachePolicy.prohibited,
    ),
    'promoteWorkspaceNoteIngestion': EndpointDefinition(
      id: 'promoteWorkspaceNoteIngestion',
      method: HttpMethod.post,
      pathTemplate:
          '/api/v1/workspaces/{workspaceId}/note-ingestions/{ingestionId}/promote',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.required,
      idempotencyHeaderName: 'X-Idempotency-Key',
      capability: BackendCapability.knowledge,
      docsAuthority: 'Docs API 20 Workspace Note ingestion transport',
    ),
    'createWorkspaceManualNote': EndpointDefinition(
      id: 'createWorkspaceManualNote',
      method: HttpMethod.post,
      pathTemplate: '/api/v1/workspaces/{workspaceId}/notes/manual',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.required,
      idempotencyHeaderName: 'X-Idempotency-Key',
      capability: BackendCapability.knowledge,
    ),
    'createWorkspaceNote': EndpointDefinition(
      id: 'createWorkspaceNote',
      method: HttpMethod.post,
      pathTemplate: '/api/v1/workspaces/{workspaceId}/notes',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.required,
      idempotencyHeaderName: 'X-Idempotency-Key',
      capability: BackendCapability.knowledge,
    ),
    'workspaceNoteDetail': EndpointDefinition(
      id: 'workspaceNoteDetail',
      method: HttpMethod.get,
      pathTemplate: '/api/v1/workspaces/{workspaceId}/notes/{noteId}',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.forbidden,
      capability: BackendCapability.knowledge,
    ),
    'createWorkspaceNoteFileAgentRun': EndpointDefinition(
      id: 'createWorkspaceNoteFileAgentRun',
      method: HttpMethod.post,
      pathTemplate:
          '/api/v1/workspaces/{workspaceId}/notes/{noteId}/file-agent-runs',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.required,
      idempotencyHeaderName: 'X-Idempotency-Key',
      capability: BackendCapability.knowledge,
      docsAuthority: 'Backend deployed Workspace Note File Agent contract',
    ),
    'workspaceNoteFileAgentRun': EndpointDefinition(
      id: 'workspaceNoteFileAgentRun',
      method: HttpMethod.get,
      pathTemplate:
          '/api/v1/workspaces/{workspaceId}/notes/{noteId}/file-agent-runs/{fileAgentRunId}',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.forbidden,
      capability: BackendCapability.knowledge,
      docsAuthority: 'Backend deployed Workspace Note File Agent contract',
    ),
    'updateWorkspaceNote': EndpointDefinition(
      id: 'updateWorkspaceNote',
      method: HttpMethod.patch,
      pathTemplate: '/api/v1/workspaces/{workspaceId}/notes/{noteId}',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.required,
      idempotencyHeaderName: 'X-Idempotency-Key',
      capability: BackendCapability.knowledge,
    ),
    'runningTasks': EndpointDefinition(
      id: 'runningTasks',
      method: HttpMethod.get,
      pathTemplate: '/api/v1/tasks/running',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.forbidden,
    ),
    'mediaUploadToken': EndpointDefinition(
      id: 'mediaUploadToken',
      method: HttpMethod.post,
      pathTemplate: '/api/v1/media/upload-token',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.required,
    ),
    'mediaUploadComplete': EndpointDefinition(
      id: 'mediaUploadComplete',
      method: HttpMethod.post,
      pathTemplate: '/api/v1/media/uploads/{uploadId}/complete',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.required,
    ),
    'mediaResourcePlayback': EndpointDefinition(
      id: 'mediaResourcePlayback',
      method: HttpMethod.get,
      pathTemplate: '/api/v1/media/resources/{resourceId}/playback',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.forbidden,
      capability: BackendCapability.media,
      docsAuthority: 'Backend deployed media Resource playback contract',
    ),
    'deleteWorkspaceMediaResource': EndpointDefinition(
      id: 'deleteWorkspaceMediaResource',
      method: HttpMethod.delete,
      pathTemplate:
          '/api/v1/workspaces/{workspaceId}/media/resources/{resourceId}',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.required,
      idempotencyHeaderName: 'X-Idempotency-Key',
      capability: BackendCapability.media,
      docsAuthority: 'Backend Workspace media Resource deletion contract',
    ),
    'workspaceNoteMetrics': EndpointDefinition(
      id: 'workspaceNoteMetrics',
      method: HttpMethod.get,
      pathTemplate: '/api/v1/workspaces/{workspaceId}/note-metrics',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.forbidden,
      capability: BackendCapability.knowledge,
      docsAuthority: 'Backend Workspace daily Note metrics v2 contract',
    ),
    'bindRecordingCardDevice': EndpointDefinition(
      id: 'bindRecordingCardDevice',
      method: HttpMethod.post,
      pathTemplate: '/api/v1/recording-card/devices/bind',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.required,
      integrationStatus: BackendIntegrationStatus.contractReady,
      docsAuthority:
          'Retained API 05 direct-bind contract; formal ownership uses proof',
    ),
    'recordingCardDeviceBinding': EndpointDefinition(
      id: 'recordingCardDeviceBinding',
      method: HttpMethod.get,
      pathTemplate: '/api/v1/recording-card/device-binding',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.forbidden,
      capability: BackendCapability.recordingCard,
      docsAuthority:
          '测试脚本/run-streaming-sn-workspace-smoke.ps1 cloud binding read',
    ),
    'recordingCardBindChallenge': EndpointDefinition(
      id: 'recordingCardBindChallenge',
      method: HttpMethod.post,
      pathTemplate: '/api/v1/recording-card/bind-challenge',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.forbidden,
      capability: BackendCapability.recordingCard,
      docsAuthority: 'Backend Recording Card Ownership v1 contract',
    ),
    'bindRecordingCardOwnership': EndpointDefinition(
      id: 'bindRecordingCardOwnership',
      method: HttpMethod.post,
      pathTemplate: '/api/v1/recording-card/bind',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.required,
      idempotencyHeaderName: 'X-Idempotency-Key',
      capability: BackendCapability.recordingCard,
      docsAuthority: 'Backend Recording Card Ownership v1 contract',
    ),
    'unbindRecordingCardOwnership': EndpointDefinition(
      id: 'unbindRecordingCardOwnership',
      method: HttpMethod.post,
      pathTemplate: '/api/v1/recording-card/devices/{deviceId}/unbind',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.required,
      idempotencyHeaderName: 'X-Idempotency-Key',
      capability: BackendCapability.recordingCard,
      docsAuthority: 'Backend Recording Card Ownership v1 contract',
    ),
    'recordingCardFiles': EndpointDefinition(
      id: 'recordingCardFiles',
      method: HttpMethod.get,
      pathTemplate: '/api/v1/recording-card/files',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.forbidden,
    ),
    'syncRecordingCardFiles': EndpointDefinition(
      id: 'syncRecordingCardFiles',
      method: HttpMethod.post,
      pathTemplate: '/api/v1/recording-card/files/sync',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.required,
    ),
    'linkRecordingCardUpload': EndpointDefinition(
      id: 'linkRecordingCardUpload',
      method: HttpMethod.post,
      pathTemplate: '/api/v1/recording-card/files/{cardFileId}/link-upload',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.required,
    ),
    'createRecording': EndpointDefinition(
      id: 'createRecording',
      method: HttpMethod.post,
      pathTemplate: '/api/v1/recordings',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.required,
    ),
    'recordings': EndpointDefinition(
      id: 'recordings',
      method: HttpMethod.get,
      pathTemplate: '/api/v1/recordings',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.forbidden,
    ),
    'recordingDetail': EndpointDefinition(
      id: 'recordingDetail',
      method: HttpMethod.get,
      pathTemplate: '/api/v1/recordings/{recordingId}',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.forbidden,
    ),
    'speakerLabelPanel': EndpointDefinition(
      id: 'speakerLabelPanel',
      method: HttpMethod.get,
      pathTemplate: '/api/v1/recordings/{recordingId}/speaker-label-panel',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.forbidden,
    ),
    'saveSpeakerLabelDraft': EndpointDefinition(
      id: 'saveSpeakerLabelDraft',
      method: HttpMethod.post,
      pathTemplate: '/api/v1/recordings/{recordingId}/speaker-label-draft',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.required,
    ),
    'submitSpeakerLabels': EndpointDefinition(
      id: 'submitSpeakerLabels',
      method: HttpMethod.post,
      pathTemplate: '/api/v1/recordings/{recordingId}/speaker-labels',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.required,
    ),
    'retryRecording': EndpointDefinition(
      id: 'retryRecording',
      method: HttpMethod.post,
      pathTemplate: '/api/v1/recordings/{recordingId}/retry',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.required,
    ),
    'asrTask': EndpointDefinition(
      id: 'asrTask',
      method: HttpMethod.get,
      pathTemplate: '/api/v1/asr-tasks/{asrTaskId}',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.forbidden,
    ),
    'retryAsrTask': EndpointDefinition(
      id: 'retryAsrTask',
      method: HttpMethod.post,
      pathTemplate: '/api/v1/asr-tasks/{asrTaskId}/retry',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.required,
    ),
    'chatThreads': EndpointDefinition(
      id: 'chatThreads',
      method: HttpMethod.get,
      pathTemplate: '/api/v1/chat/threads',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.forbidden,
      readCachePolicy: EndpointReadCachePolicy.conditional,
    ),
    'createChatThread': EndpointDefinition(
      id: 'createChatThread',
      method: HttpMethod.post,
      pathTemplate: '/api/v1/chat/threads',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.required,
    ),
    'chatThreadDetail': EndpointDefinition(
      id: 'chatThreadDetail',
      method: HttpMethod.get,
      pathTemplate: '/api/v1/chat/threads/{threadId}',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.forbidden,
      readCachePolicy: EndpointReadCachePolicy.conditional,
    ),
    'chatThreadEvents': EndpointDefinition(
      id: 'chatThreadEvents',
      method: HttpMethod.get,
      pathTemplate: '/api/v1/chat/threads/{threadId}/events',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.forbidden,
      capability: BackendCapability.chat,
      readCachePolicy: EndpointReadCachePolicy.incremental,
      docsAuthority: 'Positioning thread runtime trace smoke contract',
    ),
    'updateChatThreadMetadata': EndpointDefinition(
      id: 'updateChatThreadMetadata',
      method: HttpMethod.patch,
      pathTemplate: '/api/v1/chat/threads/{threadId}',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.required,
      capability: BackendCapability.chat,
      docsAuthority: 'Positioning thread runtime trace smoke contract',
    ),
    'chatThreadRuntimeInvocations': EndpointDefinition(
      id: 'chatThreadRuntimeInvocations',
      method: HttpMethod.get,
      pathTemplate: '/api/v1/chat/threads/{threadId}/runtime-invocations',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.forbidden,
      capability: BackendCapability.chat,
      readCachePolicy: EndpointReadCachePolicy.conditional,
      docsAuthority: 'Thread runtime invocation history contract',
    ),
    'chatThreadRuntimeInvocation': EndpointDefinition(
      id: 'chatThreadRuntimeInvocation',
      method: HttpMethod.get,
      pathTemplate:
          '/api/v1/chat/threads/{threadId}/runtime-invocations/latest',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.forbidden,
      capability: BackendCapability.chat,
      readCachePolicy: EndpointReadCachePolicy.conditional,
      docsAuthority: 'Positioning thread runtime trace smoke contract',
    ),
    'workspacePositioningProgress': EndpointDefinition(
      id: 'workspacePositioningProgress',
      method: HttpMethod.get,
      pathTemplate: '/api/v1/workspaces/{workspaceId}/positioning/progress',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.forbidden,
      capability: BackendCapability.profile,
      readCachePolicy: EndpointReadCachePolicy.conditional,
      docsAuthority: 'Positioning thread runtime trace smoke contract',
    ),
    'sendChatMessage': EndpointDefinition(
      id: 'sendChatMessage',
      method: HttpMethod.post,
      pathTemplate: '/api/v1/chat/threads/{threadId}/messages',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.required,
    ),
    'sendVoiceMessage': EndpointDefinition(
      id: 'sendVoiceMessage',
      method: HttpMethod.post,
      pathTemplate: '/api/v1/chat/threads/{threadId}/voice-messages',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.required,
    ),
    'taskDetail': EndpointDefinition(
      id: 'taskDetail',
      method: HttpMethod.get,
      pathTemplate: '/api/v1/tasks/{taskId}',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.forbidden,
    ),
    'retryTask': EndpointDefinition(
      id: 'retryTask',
      method: HttpMethod.post,
      pathTemplate: '/api/v1/tasks/{taskId}/retry',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.required,
    ),
    'regenerateTask': EndpointDefinition(
      id: 'regenerateTask',
      method: HttpMethod.post,
      pathTemplate: '/api/v1/tasks/{taskId}/regenerate',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.required,
    ),
    'assetsOverview': EndpointDefinition(
      id: 'assetsOverview',
      method: HttpMethod.get,
      pathTemplate: '/api/v1/assets/overview',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.forbidden,
    ),
    'assetsMarkdown': EndpointDefinition(
      id: 'assetsMarkdown',
      method: HttpMethod.get,
      pathTemplate: '/api/v1/assets/markdown',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.forbidden,
    ),
    'recordingAssetDetail': EndpointDefinition(
      id: 'recordingAssetDetail',
      method: HttpMethod.get,
      pathTemplate: '/api/v1/assets/recordings/{recordingId}',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.forbidden,
    ),
    'assetDetail': EndpointDefinition(
      id: 'assetDetail',
      method: HttpMethod.get,
      pathTemplate: '/api/v1/assets/{assetType}/{assetId}',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.forbidden,
    ),
    'patchAsset': EndpointDefinition(
      id: 'patchAsset',
      method: HttpMethod.patch,
      pathTemplate: '/api/v1/assets/{assetType}/{assetId}',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.required,
    ),
    'syncAssets': EndpointDefinition(
      id: 'syncAssets',
      method: HttpMethod.post,
      pathTemplate: '/api/v1/assets/sync',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.required,
    ),
    'membership': EndpointDefinition(
      id: 'membership',
      method: HttpMethod.get,
      pathTemplate: '/api/v1/membership',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.forbidden,
    ),
    'billingCatalog': EndpointDefinition(
      id: 'billingCatalog',
      method: HttpMethod.get,
      pathTemplate: '/api/v1/billing/catalog',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.forbidden,
      docsAuthority: 'Docs 97e510c8 API 28',
    ),
    'createAndroidBillingOrder': EndpointDefinition(
      id: 'createAndroidBillingOrder',
      method: HttpMethod.post,
      pathTemplate: '/api/v1/billing/android/orders',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.required,
      docsAuthority: 'Docs 97e510c8 API 28',
    ),
    'billingOrder': EndpointDefinition(
      id: 'billingOrder',
      method: HttpMethod.get,
      pathTemplate: '/api/v1/billing/orders/{orderId}',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.forbidden,
      docsAuthority: 'Docs 97e510c8 API 28',
    ),
    'verifyIOSBillingPurchase': EndpointDefinition(
      id: 'verifyIOSBillingPurchase',
      method: HttpMethod.post,
      pathTemplate: '/api/v1/billing/ios/purchases/verify',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.required,
      docsAuthority: 'Docs 97e510c8 API 28',
    ),
    'billingTransactions': EndpointDefinition(
      id: 'billingTransactions',
      method: HttpMethod.get,
      pathTemplate: '/api/v1/billing/transactions',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.forbidden,
      docsAuthority: 'Docs 97e510c8 API 28',
    ),
    'notifications': EndpointDefinition(
      id: 'notifications',
      method: HttpMethod.get,
      pathTemplate: '/api/v1/notifications',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.forbidden,
    ),
    'markNotificationRead': EndpointDefinition(
      id: 'markNotificationRead',
      method: HttpMethod.post,
      pathTemplate: '/api/v1/notifications/{notificationId}/read',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.required,
    ),
    'clearRedDots': EndpointDefinition(
      id: 'clearRedDots',
      method: HttpMethod.post,
      pathTemplate: '/api/v1/red-dots/clear',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.required,
    ),
    'registerNotificationDevice': EndpointDefinition(
      id: 'registerNotificationDevice',
      method: HttpMethod.post,
      pathTemplate: '/api/v1/notification-devices',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.required,
    ),
    'unregisterNotificationDevice': EndpointDefinition(
      id: 'unregisterNotificationDevice',
      method: HttpMethod.delete,
      pathTemplate: '/api/v1/notification-devices/{deviceId}',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.required,
    ),
    'analyticsEvents': EndpointDefinition(
      id: 'analyticsEvents',
      method: HttpMethod.post,
      pathTemplate: '/api/v1/analytics/events',
      auth: EndpointAuthPolicy.optional,
      idempotency: EndpointIdempotencyPolicy.forbidden,
    ),
    'createDocumentChangeProposal': EndpointDefinition(
      id: 'createDocumentChangeProposal',
      method: HttpMethod.post,
      pathTemplate:
          '/api/v1/workspaces/{workspaceId}/document-change-proposals',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.required,
      idempotencyHeaderName: 'X-Idempotency-Key',
      capability: BackendCapability.knowledge,
      integrationStatus: BackendIntegrationStatus.connected,
      docsAuthority: 'Backend deployed document change proposal contract',
    ),
    'documentChangeProposals': EndpointDefinition(
      id: 'documentChangeProposals',
      method: HttpMethod.get,
      pathTemplate:
          '/api/v1/workspaces/{workspaceId}/document-change-proposals',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.forbidden,
      capability: BackendCapability.knowledge,
      integrationStatus: BackendIntegrationStatus.connected,
      docsAuthority: 'Backend deployed document change proposal contract',
    ),
    'documentChangeProposal': EndpointDefinition(
      id: 'documentChangeProposal',
      method: HttpMethod.get,
      pathTemplate:
          '/api/v1/workspaces/{workspaceId}/document-change-proposals/{proposalId}',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.forbidden,
      capability: BackendCapability.knowledge,
      integrationStatus: BackendIntegrationStatus.connected,
      docsAuthority: 'Backend deployed document change proposal contract',
    ),
    'documentChangeProposalDiff': EndpointDefinition(
      id: 'documentChangeProposalDiff',
      method: HttpMethod.get,
      pathTemplate:
          '/api/v1/workspaces/{workspaceId}/document-change-proposals/{proposalId}/diff',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.forbidden,
      capability: BackendCapability.knowledge,
      integrationStatus: BackendIntegrationStatus.connected,
      docsAuthority: 'Backend deployed document change proposal contract',
    ),
    'documentChangeProposalCandidate': EndpointDefinition(
      id: 'documentChangeProposalCandidate',
      method: HttpMethod.get,
      pathTemplate:
          '/api/v1/workspaces/{workspaceId}/document-change-proposals/{proposalId}/candidate',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.forbidden,
      capability: BackendCapability.knowledge,
      integrationStatus: BackendIntegrationStatus.connected,
      docsAuthority: 'Backend deployed document change proposal contract',
    ),
    'applyDocumentChangeProposal': EndpointDefinition(
      id: 'applyDocumentChangeProposal',
      method: HttpMethod.post,
      pathTemplate:
          '/api/v1/workspaces/{workspaceId}/document-change-proposals/{proposalId}/apply',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.required,
      idempotencyHeaderName: 'X-Idempotency-Key',
      capability: BackendCapability.knowledge,
      integrationStatus: BackendIntegrationStatus.connected,
      docsAuthority: 'Backend deployed document change proposal contract',
    ),
    'rejectDocumentChangeProposal': EndpointDefinition(
      id: 'rejectDocumentChangeProposal',
      method: HttpMethod.post,
      pathTemplate:
          '/api/v1/workspaces/{workspaceId}/document-change-proposals/{proposalId}/reject',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.required,
      idempotencyHeaderName: 'X-Idempotency-Key',
      capability: BackendCapability.knowledge,
      integrationStatus: BackendIntegrationStatus.connected,
      docsAuthority: 'Backend deployed document change proposal contract',
    ),
    'cancelDocumentChangeProposal': EndpointDefinition(
      id: 'cancelDocumentChangeProposal',
      method: HttpMethod.post,
      pathTemplate:
          '/api/v1/workspaces/{workspaceId}/document-change-proposals/{proposalId}/cancel',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.required,
      idempotencyHeaderName: 'X-Idempotency-Key',
      capability: BackendCapability.knowledge,
      integrationStatus: BackendIntegrationStatus.connected,
      docsAuthority: 'Backend deployed document change proposal contract',
    ),
    'rebaseDocumentChangeProposal': EndpointDefinition(
      id: 'rebaseDocumentChangeProposal',
      method: HttpMethod.post,
      pathTemplate:
          '/api/v1/workspaces/{workspaceId}/document-change-proposals/{proposalId}/rebase',
      auth: EndpointAuthPolicy.required,
      idempotency: EndpointIdempotencyPolicy.required,
      idempotencyHeaderName: 'X-Idempotency-Key',
      capability: BackendCapability.knowledge,
      integrationStatus: BackendIntegrationStatus.connected,
      docsAuthority: 'Backend deployed document change proposal contract',
    ),
    ..._additionalDocsDefinitions,
  };

  static EndpointDefinition byId(String id) {
    final definition = definitions[id];
    if (definition == null) {
      throw ArgumentError.value(id, 'id', 'Unknown endpoint id');
    }
    return definition;
  }

  static ResolvedEndpoint resolve(
    String id, {
    EndpointPathParams pathParams = const <String, Object>{},
  }) {
    final definition = byId(id);
    return ResolvedEndpoint(
      definition: definition,
      path: buildEndpointPath(definition.pathTemplate, pathParams),
    );
  }

  static List<EndpointDefinition> listDefinitions() =>
      List<EndpointDefinition>.unmodifiable(definitions.values);
}

final _additionalDocsDefinitions = Map<String, EndpointDefinition>.fromEntries(
  _additionalDocsEndpointRows.trim().split('\n').map((row) {
    final definition = _definitionFromDocsRow(row);
    return MapEntry(definition.id, definition);
  }),
);

EndpointDefinition _definitionFromDocsRow(String row) {
  final fields = row.split('|');
  if (fields.length != 5) {
    throw StateError('Invalid additional Docs endpoint row');
  }
  final method = HttpMethod.values.singleWhere(
    (candidate) => candidate.value == fields[1],
  );
  final capability = BackendCapability.values.singleWhere(
    (candidate) => candidate.name == fields[3],
  );
  final responseMode = switch (fields[4]) {
    'binary' => EndpointResponseMode.binary,
    'sse' => EndpointResponseMode.sse,
    'empty' => EndpointResponseMode.empty,
    _ => EndpointResponseMode.strictEnvelope,
  };
  return EndpointDefinition(
    id: fields[0],
    method: method,
    pathTemplate: fields[2],
    auth: EndpointAuthPolicy.required,
    idempotency: method == HttpMethod.get || fields[0] == 'workspaceSearch'
        ? EndpointIdempotencyPolicy.forbidden
        : EndpointIdempotencyPolicy.required,
    idempotencyHeaderName:
        capability == BackendCapability.book ||
            fields[2].contains('/subscription') ||
            const <String>{
              'createAgentRun',
              'cancelAgentRun',
              'installSkill',
              'updateSkillInstallation',
              'deleteSkillInstallation',
              'createNoteRelation',
              'updateNoteRelation',
              'deleteNoteRelation',
              'createWorkspaceProfileVisualAsset',
              'createWorkspaceFolder',
              'updateWorkspaceFolder',
              'moveWorkspaceFolder',
              'deleteWorkspaceFolder',
              'restoreWorkspaceFolder',
              'batchMoveWorkspaceNotes',
              'putWorkspaceNotePart',
              'deleteWorkspaceNote',
              'restoreWorkspaceNote',
              'createWorkspaceCreation',
              'updateWorkspaceCreation',
              'deleteWorkspaceCreation',
              'restoreWorkspaceCreation',
              'putWorkspaceCreationPart',
              'reviseDocumentChangeProposal',
              'putDigitalTwinSchedule',
              'createDigitalTwinConfirmation',
              'restoreDigitalTwinVersion',
            }.contains(fields[0])
        ? 'X-Idempotency-Key'
        : 'Idempotency-Key',
    capability: capability,
    integrationStatus: _connectedDocsEndpointIds.contains(fields[0])
        ? BackendIntegrationStatus.connected
        : BackendIntegrationStatus.contractReady,
    responseMode: responseMode,
    docsAuthority: _docsAuthorityForPath(fields[2]),
  );
}

const _connectedDocsEndpointIds = <String>{
  'digitalTwin',
  'digitalTwinSchedule',
  'putDigitalTwinSchedule',
  'createDigitalTwinConfirmation',
  'digitalTwinConfirmation',
  'digitalTwinVersions',
  'digitalTwinVersion',
  'digitalTwinVersionPreview',
  'digitalTwinVersionCompare',
  'downloadDigitalTwinVersion',
  'restoreDigitalTwinVersion',
  'documentChangeProposalVersions',
  'documentChangeProposalVersionDiff',
  'documentChangeProposalVersionCandidate',
  'reviseDocumentChangeProposal',
};

String _responseTypeForMode(EndpointResponseMode mode) => switch (mode) {
  EndpointResponseMode.empty => 'empty',
  EndpointResponseMode.binary => 'binary',
  EndpointResponseMode.sse => 'AgentRunEventStream',
  _ => 'ApiEnvelope',
};

String _docsAuthorityForPath(String path) {
  if (path.startsWith('/api/v1/agent-profiles') ||
      path.contains('/skill-installations')) {
    return 'Docs 97e510c8 API 23';
  }
  if (path.startsWith('/api/v1/agent/')) return 'Docs 97e510c8 API 19';
  if (path.contains('/book') || RegExp(r'/work(?:/|$)').hasMatch(path)) {
    return 'Docs 97e510c8 API 24';
  }
  if (path.contains('/subscription')) return 'Docs 97e510c8 API 25';
  if (path == '/api/v1/account/credits' || path.contains('/usage')) {
    return 'Docs 97e510c8 API 27';
  }
  if (path.contains('/folders') || path.contains('/notes')) {
    return 'Docs 97e510c8 API 20';
  }
  if (path.contains('/content-snapshot') || path.contains('/content-changes')) {
    return 'Docs 97e510c8 API 21';
  }
  return 'Docs 97e510c8 API 22';
}

const _additionalDocsEndpointRows = r'''
agentMetaWorkspaces|GET|/api/v1/agent/meta-workspaces|agent|json
createAgentRun|POST|/api/v1/agent/runs|agent|json
agentRunDetail|GET|/api/v1/agent/runs/{agentRunId}|agent|json
agentRunEvents|GET|/api/v1/agent/runs/{agentRunId}/events|agent|json
agentRunEventStream|GET|/api/v1/agent/runs/{agentRunId}/events/stream|agent|sse
cancelAgentRun|POST|/api/v1/agent/runs/{agentRunId}/cancel|agent|json
confirmAgentRun|POST|/api/v1/agent/runs/{agentRunId}/confirm|agent|json
agentProfiles|GET|/api/v1/agent-profiles|agent|json
agentProfileSkills|GET|/api/v1/agent-profiles/{agentProfileId}/skills|agent|json
agentProfileModels|GET|/api/v1/agent-profiles/{agentProfileId}/models|agent|json
skillInstallations|GET|/api/v1/workspaces/{workspaceId}/skill-installations|agent|json
installSkill|POST|/api/v1/workspaces/{workspaceId}/skill-installations|agent|json
updateSkillInstallation|PATCH|/api/v1/workspaces/{workspaceId}/skill-installations/{skillProfileId}|agent|json
deleteSkillInstallation|DELETE|/api/v1/workspaces/{workspaceId}/skill-installations/{skillProfileId}|agent|empty
workspaceContentSnapshot|GET|/api/v1/workspaces/{workspaceId}/content-snapshot|workspace|json
workspaceContentChanges|GET|/api/v1/workspaces/{workspaceId}/content-changes|workspace|json
workspaceFolders|GET|/api/v1/workspaces/{workspaceId}/folders|knowledge|json
createWorkspaceFolder|POST|/api/v1/workspaces/{workspaceId}/folders|knowledge|json
workspaceFolderDetail|GET|/api/v1/workspaces/{workspaceId}/folders/{folderId}|knowledge|json
updateWorkspaceFolder|PATCH|/api/v1/workspaces/{workspaceId}/folders/{folderId}|knowledge|json
deleteWorkspaceFolder|DELETE|/api/v1/workspaces/{workspaceId}/folders/{folderId}|knowledge|json
moveWorkspaceFolder|POST|/api/v1/workspaces/{workspaceId}/folders/{folderId}/move|knowledge|json
restoreWorkspaceFolder|POST|/api/v1/workspaces/{workspaceId}/folders/{folderId}/restore|knowledge|json
batchMoveWorkspaceNotes|POST|/api/v1/workspaces/{workspaceId}/notes/batch-move|knowledge|json
workspaceNotePart|GET|/api/v1/workspaces/{workspaceId}/notes/{noteId}/parts/{part}|knowledge|json
putWorkspaceNotePart|PUT|/api/v1/workspaces/{workspaceId}/notes/{noteId}/parts/{part}|knowledge|json
deleteWorkspaceNote|DELETE|/api/v1/workspaces/{workspaceId}/notes/{noteId}|knowledge|json
restoreWorkspaceNote|POST|/api/v1/workspaces/{workspaceId}/notes/{noteId}/restore|knowledge|json
exportWorkspaceNote|GET|/api/v1/workspaces/{workspaceId}/notes/{noteId}/export|knowledge|binary
createNoteImport|POST|/api/v1/workspaces/{workspaceId}/note-imports|knowledge|json
workspacePositioning|GET|/api/v1/workspaces/{workspaceId}/positioning|assets|json
putWorkspacePositioning|PUT|/api/v1/workspaces/{workspaceId}/positioning|assets|json
workspacePositioningRevisions|GET|/api/v1/workspaces/{workspaceId}/positioning/revisions|assets|json
digitalTwin|GET|/api/v1/workspaces/{workspaceId}/digital-twin|assets|json
digitalTwinSchedule|GET|/api/v1/workspaces/{workspaceId}/digital-twin/schedule|assets|json
putDigitalTwinSchedule|PUT|/api/v1/workspaces/{workspaceId}/digital-twin/schedule|assets|json
createDigitalTwinConfirmation|POST|/api/v1/workspaces/{workspaceId}/digital-twin/confirmations|assets|json
digitalTwinConfirmation|GET|/api/v1/workspaces/{workspaceId}/digital-twin/confirmations/{confirmationTaskId}|assets|json
digitalTwinVersions|GET|/api/v1/workspaces/{workspaceId}/digital-twin/versions|assets|json
digitalTwinVersion|GET|/api/v1/workspaces/{workspaceId}/digital-twin/versions/{versionId}|assets|json
digitalTwinVersionPreview|GET|/api/v1/workspaces/{workspaceId}/digital-twin/versions/{versionId}/preview|assets|json
digitalTwinVersionCompare|GET|/api/v1/workspaces/{workspaceId}/digital-twin/versions/{versionId}/compare|assets|json
downloadDigitalTwinVersion|GET|/api/v1/workspaces/{workspaceId}/digital-twin/versions/{versionId}/download|assets|binary
restoreDigitalTwinVersion|POST|/api/v1/workspaces/{workspaceId}/digital-twin/versions/{versionId}/restore|assets|json
documentChangeProposalVersions|GET|/api/v1/workspaces/{workspaceId}/document-change-proposals/{proposalId}/versions|knowledge|json
documentChangeProposalVersionDiff|GET|/api/v1/workspaces/{workspaceId}/document-change-proposals/{proposalId}/versions/{proposalVersion}/diff|knowledge|json
documentChangeProposalVersionCandidate|GET|/api/v1/workspaces/{workspaceId}/document-change-proposals/{proposalId}/versions/{proposalVersion}/candidate|knowledge|json
reviseDocumentChangeProposal|POST|/api/v1/workspaces/{workspaceId}/document-change-proposals/{proposalId}/revise|knowledge|json
workspaceProfileVisualAssets|GET|/api/v1/workspaces/{workspaceId}/profile-visual-assets|assets|json
createWorkspaceProfileVisualAsset|POST|/api/v1/workspaces/{workspaceId}/profile-visual-assets|assets|json
workspaceCreations|GET|/api/v1/workspaces/{workspaceId}/creations|assets|json
createWorkspaceCreation|POST|/api/v1/workspaces/{workspaceId}/creations|assets|json
workspaceCreationDetail|GET|/api/v1/workspaces/{workspaceId}/creations/{creationId}|assets|json
updateWorkspaceCreation|PATCH|/api/v1/workspaces/{workspaceId}/creations/{creationId}|assets|json
deleteWorkspaceCreation|DELETE|/api/v1/workspaces/{workspaceId}/creations/{creationId}|assets|json
restoreWorkspaceCreation|POST|/api/v1/workspaces/{workspaceId}/creations/{creationId}/restore|assets|json
workspaceCreationPart|GET|/api/v1/workspaces/{workspaceId}/creations/{creationId}/parts/{part}|assets|json
putWorkspaceCreationPart|PUT|/api/v1/workspaces/{workspaceId}/creations/{creationId}/parts/{part}|assets|json
workspaceCreationPartRevisions|GET|/api/v1/workspaces/{workspaceId}/creations/{creationId}/parts/{part}/revisions|assets|json
contentNavigation|GET|/api/v1/workspaces/{workspaceId}/content-navigation/{map}|assets|json
workspaceSearch|POST|/api/v1/workspaces/{workspaceId}/search|assets|json
noteRelations|GET|/api/v1/workspaces/{workspaceId}/notes/{noteId}/relations|assets|json
createNoteRelation|POST|/api/v1/workspaces/{workspaceId}/notes/{noteId}/relations|assets|json
updateNoteRelation|PATCH|/api/v1/workspaces/{workspaceId}/note-relations/{relationId}|assets|json
deleteNoteRelation|DELETE|/api/v1/workspaces/{workspaceId}/note-relations/{relationId}|assets|json
workspaceBook|GET|/api/v1/workspaces/{workspaceId}/book|book|json
putWorkspaceBook|PUT|/api/v1/workspaces/{workspaceId}/book|book|json
workspaceBookRevisions|GET|/api/v1/workspaces/{workspaceId}/book/revisions|book|json
workspaceBookRevision|GET|/api/v1/workspaces/{workspaceId}/book/revisions/{bookRevisionId}|book|json
importWorkspaceBook|POST|/api/v1/workspaces/{workspaceId}/book/import|book|json
workspaceBookImport|GET|/api/v1/workspaces/{workspaceId}/book/imports/{bookImportId}|book|json
workspaceBookSections|POST|/api/v1/workspaces/{workspaceId}/book/sections|book|json
workspaceBookSection|GET|/api/v1/workspaces/{workspaceId}/book/sections/{sectionKey}|book|json
updateWorkspaceBookSection|PATCH|/api/v1/workspaces/{workspaceId}/book/sections/{sectionKey}|book|json
deleteWorkspaceBookSection|DELETE|/api/v1/workspaces/{workspaceId}/book/sections/{sectionKey}|book|json
restoreWorkspaceBookSection|POST|/api/v1/workspaces/{workspaceId}/book/sections/{sectionKey}/restore|book|json
moveWorkspaceBookSection|POST|/api/v1/workspaces/{workspaceId}/book/sections/{sectionKey}/move|book|json
workspaceBookSectionPart|GET|/api/v1/workspaces/{workspaceId}/book/sections/{sectionKey}/parts/{part}|book|json
putWorkspaceBookSectionPart|PUT|/api/v1/workspaces/{workspaceId}/book/sections/{sectionKey}/parts/{part}|book|json
workspaceBookSectionPartRevisions|GET|/api/v1/workspaces/{workspaceId}/book/sections/{sectionKey}/parts/{part}/revisions|book|json
exportWorkspaceBook|GET|/api/v1/workspaces/{workspaceId}/book/export|book|binary
workspaceWorkItems|GET|/api/v1/workspaces/{workspaceId}/work|book|json
createWorkspaceWork|POST|/api/v1/workspaces/{workspaceId}/work|book|json
workspaceWorkDetail|GET|/api/v1/workspaces/{workspaceId}/work/{workId}|book|json
updateWorkspaceWork|PATCH|/api/v1/workspaces/{workspaceId}/work/{workId}|book|json
deleteWorkspaceWork|DELETE|/api/v1/workspaces/{workspaceId}/work/{workId}|book|json
restoreWorkspaceWork|POST|/api/v1/workspaces/{workspaceId}/work/{workId}/restore|book|json
completeWorkspaceWork|POST|/api/v1/workspaces/{workspaceId}/work/{workId}/complete|book|json
workspaceWorkPart|GET|/api/v1/workspaces/{workspaceId}/work/{workId}/parts/{part}|book|json
putWorkspaceWorkPart|PUT|/api/v1/workspaces/{workspaceId}/work/{workId}/parts/{part}|book|json
workspaceWorkPartRevisions|GET|/api/v1/workspaces/{workspaceId}/work/{workId}/parts/{part}/revisions|book|json
promoteWorkspaceWork|POST|/api/v1/workspaces/{workspaceId}/work/{workId}/promotions|book|json
subscriptionPublications|GET|/api/v1/subscription/publications|subscription|json
subscriptionPublicationDetail|GET|/api/v1/subscription/publications/{publicationId}|subscription|json
subscriptionPublicationSections|GET|/api/v1/subscription/publications/{publicationId}/sections|subscription|json
subscriptionArticles|GET|/api/v1/subscription/articles|subscription|json
subscriptionArticleDetail|GET|/api/v1/subscription/articles/{articleId}|subscription|json
subscriptionArticleRevisions|GET|/api/v1/subscription/articles/{articleId}/revisions|subscription|json
subscriptionArticleRevisionDetail|GET|/api/v1/subscription/articles/{articleId}/revisions/{articleRevisionId}|subscription|json
subscriptionArticleRevisionAsset|GET|/api/v1/subscription/articles/{articleId}/revisions/{articleRevisionId}/assets/{fileKey}|subscription|binary
subscriptionNoteAsset|GET|/api/v1/workspaces/{workspaceId}/notes/{noteId}/subscription-assets|subscription|binary
subscriptionLibrary|GET|/api/v1/workspaces/{workspaceId}/subscription-library/publications|subscription|json
followSubscriptionPublication|PUT|/api/v1/workspaces/{workspaceId}/subscription-library/publications/{publicationId}|subscription|json
unfollowSubscriptionPublication|DELETE|/api/v1/workspaces/{workspaceId}/subscription-library/publications/{publicationId}|subscription|json
saveSubscriptionArticleAsNote|POST|/api/v1/workspaces/{workspaceId}/subscription-articles/{articleId}/save-as-note|subscription|json
accountCredits|GET|/api/v1/account/credits|account|json
runUsage|GET|/api/v1/runs/{runId}/usage|account|json
''';

String buildEndpointPath(
  String pathTemplate, [
  EndpointPathParams params = const <String, Object>{},
]) {
  final path = pathTemplate.replaceAllMapped(_pathParameterPattern, (match) {
    final key = match.group(1)!;
    final value = params[key];
    if (value == null || value.toString().isEmpty) {
      throw ArgumentError('Missing endpoint path parameter: $key');
    }
    return Uri.encodeComponent(value.toString());
  });

  if (_pathParameterPattern.hasMatch(path)) {
    throw ArgumentError('Unresolved endpoint path template: $pathTemplate');
  }
  return path;
}

List<String> assertEndpointPolicy(EndpointDefinition endpoint) {
  final issues = <String>[];
  if (endpoint.method == HttpMethod.get &&
      endpoint.idempotency != EndpointIdempotencyPolicy.forbidden) {
    issues.add('${endpoint.id}: GET endpoints must not require request keys');
  }
  if (endpoint.id == 'analyticsEvents' &&
      endpoint.idempotency != EndpointIdempotencyPolicy.forbidden) {
    issues.add(
      'analyticsEvents: eventId handles dedupe; request key is forbidden',
    );
  }
  final isMutating =
      endpoint.method == HttpMethod.post ||
      endpoint.method == HttpMethod.put ||
      endpoint.method == HttpMethod.patch ||
      endpoint.method == HttpMethod.delete;
  if (isMutating &&
      endpoint.id != 'analyticsEvents' &&
      endpoint.id != 'workspaceSearch' &&
      endpoint.id != 'recordingCardBindChallenge' &&
      endpoint.auth != EndpointAuthPolicy.none &&
      endpoint.idempotency == EndpointIdempotencyPolicy.forbidden) {
    issues.add(
      '${endpoint.id}: mutating authenticated endpoint should declare key policy',
    );
  }
  return issues;
}

final _pathParameterPattern = RegExp(r'\{([A-Za-z0-9_]+)\}');

const _contractReadyEndpointIds = <String>{
  'workspaceRetryCreate',
  'runningTasks',
  'recordingCardDeviceBinding',
  'recordingCardBindChallenge',
  'bindRecordingCardOwnership',
  'unbindRecordingCardOwnership',
  'recordingCardFiles',
  'syncRecordingCardFiles',
  'linkRecordingCardUpload',
  'recordings',
  'assetsOverview',
  'recordingAssetDetail',
  'membership',
  'clearRedDots',
  'analyticsEvents',
  'billingCatalog',
  'createAndroidBillingOrder',
  'billingOrder',
  'verifyIOSBillingPurchase',
  'billingTransactions',
};

const _billingEndpointIds = <String>{
  'createAndroidBillingOrder',
  'verifyIOSBillingPurchase',
};

const _deferredEndpointIds = <String>{
  'workspaces',
  'createWorkspace',
  'workspaceDetail',
  'updateWorkspace',
  'setDefaultWorkspace',
  'disableWorkspace',
  'restoreWorkspace',
  'workspaceStorageUsage',
  'workspaceNotes',
  'createWorkspaceNote',
  'workspaceNoteDetail',
  'updateWorkspaceNote',
};

const _formalWorkspaceEndpointIds = <String>{
  'workspaces',
  'createWorkspace',
  'workspaceDetail',
  'updateWorkspace',
  'setDefaultWorkspace',
  'disableWorkspace',
  'restoreWorkspace',
  'workspaceStorageUsage',
  'workspaceNotes',
  'createWorkspaceNote',
  'workspaceNoteDetail',
  'updateWorkspaceNote',
};

BackendCapability _capabilityForEndpoint(String id) {
  if (id == 'appConfig') return BackendCapability.app;
  if (id.startsWith('auth') || id == 'meStatus') {
    return BackendCapability.auth;
  }
  if (id.startsWith('workspace') || id.startsWith('onboarding')) {
    return BackendCapability.workspace;
  }
  if (id.toLowerCase().contains('contentline')) {
    return BackendCapability.contentLines;
  }
  if (id.toLowerCase().contains('graph')) return BackendCapability.graph;
  if (id.toLowerCase().contains('task')) return BackendCapability.tasks;
  if (id.startsWith('media')) return BackendCapability.media;
  if (id.startsWith('videoAnalysis') || id.startsWith('linkImport')) {
    return BackendCapability.ingestion;
  }
  if (id.toLowerCase().contains('memorynote')) {
    return BackendCapability.knowledge;
  }
  if (id.toLowerCase().contains('recordingcard')) {
    return BackendCapability.recordingCard;
  }
  if (id.toLowerCase().contains('recording') ||
      id.toLowerCase().contains('speakerlabel') ||
      id.startsWith('asr')) {
    return BackendCapability.recordings;
  }
  if (id.toLowerCase().contains('chat') || id == 'sendVoiceMessage') {
    return BackendCapability.chat;
  }
  if (id.startsWith('workAi') || id.contains('WorkAi')) {
    return BackendCapability.workAi;
  }
  if (id.toLowerCase().contains('feed')) return BackendCapability.feed;
  if (id.toLowerCase().contains('asset')) return BackendCapability.assets;
  if (id == 'membership') return BackendCapability.membership;
  if (id.toLowerCase().contains('billing')) return BackendCapability.billing;
  if (id.toLowerCase().contains('notification') || id == 'clearRedDots') {
    return BackendCapability.notifications;
  }
  if (id == 'analyticsEvents') return BackendCapability.analytics;
  throw ArgumentError.value(id, 'id', 'Endpoint capability is not classified');
}
