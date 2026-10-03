import '../../../core/api/api_client.dart';
import '../../../core/api/api_envelope.dart';
import '../../../core/api/idempotency.dart';
import '../domain/backend_contract_models.dart';

abstract interface class BackendContractApiPort {
  Future<ApiResult<BackendCommandAck>> updateMyProfile(
    ProfileUpdateContract update, {
    required IdempotencyRequestContext idempotency,
  });

  Future<ApiResult<BackendCommandAck>> retryWorkspaceCreate({
    required IdempotencyRequestContext idempotency,
  });

  Future<ApiResult<BackendContractPage<ContentLineContract>>> listContentLines({
    String? cursor,
  });

  Future<ApiResult<ContentLineContract>> createContentLine(
    ContentLineCreateContract request, {
    required IdempotencyRequestContext idempotency,
  });

  Future<ApiResult<ContentLineContract>> getContentLine(String contentLineId);

  Future<ApiResult<BackendCommandAck>> setDefaultContentLine(
    String contentLineId, {
    required IdempotencyRequestContext idempotency,
  });

  Future<ApiResult<BackendCommandAck>> deactivateContentLine(
    String contentLineId, {
    required IdempotencyRequestContext idempotency,
  });

  Future<ApiResult<BackendContractPage<TaskContract>>> listRunningTasks();

  Future<ApiResult<BackendCommandAck>> updateMemoryNote(
    String noteId,
    MemoryNoteUpdateContract update, {
    required IdempotencyRequestContext idempotency,
  });

  Future<ApiResult<MemoryNoteAppendContract>> createMemoryNoteAppend({
    required String noteId,
    required String source,
    required String title,
    String? referenceId,
    required IdempotencyRequestContext idempotency,
  });

  Future<ApiResult<BackendContractPage<MemoryNoteAppendContract>>>
  listMemoryNoteAppends(String noteId, {String? cursor});

  Future<ApiResult<BackendContractPage<RecordingCardFileContract>>>
  listRecordingCardFiles({String? cursor});

  Future<ApiResult<BackendCommandAck>> syncRecordingCardFiles({
    required String bindingId,
    required int bindingGeneration,
    required IdempotencyRequestContext idempotency,
  });

  Future<ApiResult<BackendCommandAck>> linkRecordingCardUpload({
    required String cardFileId,
    required String uploadId,
    required String resourceId,
    required String bindingId,
    required int bindingGeneration,
    required IdempotencyRequestContext idempotency,
  });

  Future<ApiResult<BackendContractPage<RecordingContract>>> listRecordings({
    String? cursor,
    int? limit,
  });

  Future<ApiResult<BackendContractPage<WorkAiMaterialCandidateContract>>>
  listWorkAiMaterialCandidates({required String purpose, String? cursor});

  Future<ApiResult<BackendContractPage<TaskEventContract>>> listTaskEvents(
    String taskId, {
    String? cursor,
  });

  Future<ApiResult<FeedDepositSummaryContract>> getFeedDepositSummary(
    String messageId,
  );

  Future<ApiResult<BackendCommandAck>> retryFeedDeposit(
    String messageId, {
    required IdempotencyRequestContext idempotency,
  });

  Future<ApiResult<AssetsOverviewContract>> getAssetsOverview();

  Future<ApiResult<RecordingAssetContract>> getRecordingAssetDetail(
    String recordingId,
  );

  Future<ApiResult<MembershipContract>> getMembership();

  Future<ApiResult<BackendCommandAck>> clearRedDots({
    required IdempotencyRequestContext idempotency,
  });

  Future<ApiResult<BackendCommandAck>> sendAnalyticsEvent(
    AnalyticsEventContract event,
  );
}

final class BackendContractApi implements BackendContractApiPort {
  const BackendContractApi({required ApiClient apiClient})
    : _apiClient = apiClient;

  final ApiClient _apiClient;

  static const contractReadyEndpointIds = <String>{
    'workspaceRetryCreate',
    'runningTasks',
    'recordingCardFiles',
    'syncRecordingCardFiles',
    'linkRecordingCardUpload',
    'recordings',
    'assetsOverview',
    'recordingAssetDetail',
    'membership',
    'clearRedDots',
    'analyticsEvents',
  };

  @override
  Future<ApiResult<BackendCommandAck>> updateMyProfile(
    ProfileUpdateContract update, {
    required IdempotencyRequestContext idempotency,
  }) {
    final body = update.toJson();
    return body == null
        ? _invalid('BACKEND_PROFILE_UPDATE_INVALID')
        : _unavailable('API_ENDPOINT_RETIRED');
  }

  @override
  Future<ApiResult<BackendCommandAck>> retryWorkspaceCreate({
    required IdempotencyRequestContext idempotency,
  }) => _command(
    'workspaceRetryCreate',
    body: const <String, Object?>{},
    idempotency: idempotency,
  );

  @override
  Future<ApiResult<BackendContractPage<ContentLineContract>>> listContentLines({
    String? cursor,
  }) => _unavailable('API_ENDPOINT_RETIRED');

  @override
  Future<ApiResult<ContentLineContract>> createContentLine(
    ContentLineCreateContract request, {
    required IdempotencyRequestContext idempotency,
  }) {
    final body = request.toJson();
    if (body == null) return _invalid('BACKEND_CONTENT_LINE_INVALID');
    return _unavailable('API_ENDPOINT_RETIRED');
  }

  @override
  Future<ApiResult<ContentLineContract>> getContentLine(String contentLineId) =>
      _safeId(contentLineId)
      ? _unavailable('API_ENDPOINT_RETIRED')
      : _invalid('BACKEND_CONTENT_LINE_ID_INVALID');

  @override
  Future<ApiResult<BackendCommandAck>> setDefaultContentLine(
    String contentLineId, {
    required IdempotencyRequestContext idempotency,
  }) => _safeId(contentLineId)
      ? _unavailable('API_ENDPOINT_RETIRED')
      : _invalid('BACKEND_CONTENT_LINE_ID_INVALID');

  @override
  Future<ApiResult<BackendCommandAck>> deactivateContentLine(
    String contentLineId, {
    required IdempotencyRequestContext idempotency,
  }) => _safeId(contentLineId)
      ? _unavailable('API_ENDPOINT_RETIRED')
      : _invalid('BACKEND_CONTENT_LINE_ID_INVALID');

  @override
  Future<ApiResult<BackendContractPage<TaskContract>>> listRunningTasks() =>
      _pageRequest('runningTasks', parser: _parseTask);

  @override
  Future<ApiResult<BackendCommandAck>> updateMemoryNote(
    String noteId,
    MemoryNoteUpdateContract update, {
    required IdempotencyRequestContext idempotency,
  }) {
    final body = update.toJson();
    if (!_safeId(noteId) || body == null) {
      return _invalid('BACKEND_MEMORY_NOTE_UPDATE_INVALID');
    }
    return _unavailable('API_ENDPOINT_RETIRED');
  }

  @override
  Future<ApiResult<MemoryNoteAppendContract>> createMemoryNoteAppend({
    required String noteId,
    required String source,
    required String title,
    String? referenceId,
    required IdempotencyRequestContext idempotency,
  }) {
    final normalizedTitle = title.trim();
    if (!_safeId(noteId) ||
        !_safeId(source) ||
        (referenceId != null && !_safeId(referenceId)) ||
        normalizedTitle.isEmpty ||
        normalizedTitle.length > 160 ||
        containsUnsafeBackendText(normalizedTitle)) {
      return _invalid('BACKEND_MEMORY_NOTE_APPEND_INVALID');
    }
    return _unavailable('API_ENDPOINT_RETIRED');
  }

  @override
  Future<ApiResult<BackendContractPage<MemoryNoteAppendContract>>>
  listMemoryNoteAppends(String noteId, {String? cursor}) => !_safeId(noteId)
      ? _invalid('BACKEND_MEMORY_NOTE_ID_INVALID')
      : _unavailable('API_ENDPOINT_RETIRED');

  @override
  Future<ApiResult<BackendContractPage<RecordingCardFileContract>>>
  listRecordingCardFiles({String? cursor}) => _pageRequest(
    'recordingCardFiles',
    parser: _parseRecordingCardFile,
    cursor: cursor,
  );

  @override
  Future<ApiResult<BackendCommandAck>> syncRecordingCardFiles({
    required String bindingId,
    required int bindingGeneration,
    required IdempotencyRequestContext idempotency,
  }) => !_safeId(bindingId) || bindingGeneration < 1
      ? _invalid('BACKEND_RECORDING_CARD_BINDING_FENCE_INVALID')
      : _command(
          'syncRecordingCardFiles',
          body: <String, Object?>{
            'bindingId': bindingId,
            'bindingGeneration': bindingGeneration,
          },
          idempotency: idempotency,
        );

  @override
  Future<ApiResult<BackendCommandAck>> linkRecordingCardUpload({
    required String cardFileId,
    required String uploadId,
    required String resourceId,
    required String bindingId,
    required int bindingGeneration,
    required IdempotencyRequestContext idempotency,
  }) =>
      !_safeId(cardFileId) ||
          !_safeId(uploadId) ||
          !_safeId(resourceId) ||
          !_safeId(bindingId) ||
          bindingGeneration < 1
      ? _invalid('BACKEND_RECORDING_CARD_UPLOAD_INVALID')
      : _command(
          'linkRecordingCardUpload',
          pathParams: <String, Object>{'cardFileId': cardFileId},
          body: <String, Object?>{
            'uploadId': uploadId,
            'resourceId': resourceId,
            'bindingId': bindingId,
            'bindingGeneration': bindingGeneration,
          },
          idempotency: idempotency,
        );

  @override
  Future<ApiResult<BackendContractPage<RecordingContract>>> listRecordings({
    String? cursor,
    int? limit,
  }) => limit != null && (limit < 1 || limit > 100)
      ? _invalid('BACKEND_RECORDING_LIMIT_INVALID')
      : _pageRequest(
          'recordings',
          parser: _parseRecording,
          cursor: cursor,
          query: <String, Object?>{if (limit != null) 'limit': limit},
        );

  @override
  Future<ApiResult<BackendContractPage<WorkAiMaterialCandidateContract>>>
  listWorkAiMaterialCandidates({required String purpose, String? cursor}) =>
      !_safeId(purpose)
      ? _invalid('BACKEND_WORK_AI_PURPOSE_INVALID')
      : _unavailable('API_ENDPOINT_PROHIBITED');

  @override
  Future<ApiResult<BackendContractPage<TaskEventContract>>> listTaskEvents(
    String taskId, {
    String? cursor,
  }) => !_safeId(taskId)
      ? _invalid('BACKEND_TASK_ID_INVALID')
      : _unavailable('API_ENDPOINT_RETIRED');

  @override
  Future<ApiResult<FeedDepositSummaryContract>> getFeedDepositSummary(
    String messageId,
  ) => !_safeId(messageId)
      ? _invalid('BACKEND_MESSAGE_ID_INVALID')
      : _unavailable('API_ENDPOINT_PROHIBITED');

  @override
  Future<ApiResult<BackendCommandAck>> retryFeedDeposit(
    String messageId, {
    required IdempotencyRequestContext idempotency,
  }) => _safeId(messageId)
      ? _unavailable('API_ENDPOINT_PROHIBITED')
      : _invalid('BACKEND_MESSAGE_ID_INVALID');

  @override
  Future<ApiResult<AssetsOverviewContract>> getAssetsOverview() =>
      _apiClient.request<AssetsOverviewContract>(
        const ApiRequestOptions<AssetsOverviewContract>(
          endpointId: 'assetsOverview',
          parseData: _parseAssetsOverview,
        ),
      );

  @override
  Future<ApiResult<RecordingAssetContract>> getRecordingAssetDetail(
    String recordingId,
  ) => !_safeId(recordingId)
      ? _invalid('BACKEND_RECORDING_ID_INVALID')
      : _apiClient.request<RecordingAssetContract>(
          ApiRequestOptions<RecordingAssetContract>(
            endpointId: 'recordingAssetDetail',
            pathParams: <String, Object>{'recordingId': recordingId},
            parseData: _parseRecordingAsset,
          ),
        );

  @override
  Future<ApiResult<MembershipContract>> getMembership() =>
      _apiClient.request<MembershipContract>(
        const ApiRequestOptions<MembershipContract>(
          endpointId: 'membership',
          parseData: _parseMembership,
        ),
      );

  @override
  Future<ApiResult<BackendCommandAck>> clearRedDots({
    required IdempotencyRequestContext idempotency,
  }) => _command(
    'clearRedDots',
    body: const <String, Object?>{},
    idempotency: idempotency,
  );

  @override
  Future<ApiResult<BackendCommandAck>> sendAnalyticsEvent(
    AnalyticsEventContract event,
  ) {
    final body = event.toJson();
    return body == null
        ? _invalid('BACKEND_ANALYTICS_EVENT_INVALID')
        : _apiClient.request<BackendCommandAck>(
            ApiRequestOptions<BackendCommandAck>(
              endpointId: 'analyticsEvents',
              body: body,
              parseData: _parseCommandAck,
            ),
          );
  }

  Future<ApiResult<BackendCommandAck>> _command(
    String endpointId, {
    Map<String, Object> pathParams = const <String, Object>{},
    Object? body,
    required IdempotencyRequestContext idempotency,
  }) => _apiClient.request<BackendCommandAck>(
    ApiRequestOptions<BackendCommandAck>(
      endpointId: endpointId,
      pathParams: pathParams,
      body: body,
      idempotency: idempotency,
      parseData: _parseCommandAck,
    ),
  );

  Future<ApiResult<BackendContractPage<T>>> _pageRequest<T>(
    String endpointId, {
    required T? Function(Object?) parser,
    Map<String, Object> pathParams = const <String, Object>{},
    Map<String, Object?> query = const <String, Object?>{},
    String? cursor,
  }) {
    if (cursor != null && !_safeId(cursor)) {
      return _invalid('BACKEND_CURSOR_INVALID');
    }
    return _apiClient.request<BackendContractPage<T>>(
      ApiRequestOptions<BackendContractPage<T>>(
        endpointId: endpointId,
        pathParams: pathParams,
        query: <String, Object?>{
          ...query,
          if (cursor != null) 'cursor': cursor,
        },
        parseData: (value) => _parsePage(value, parser),
      ),
    );
  }
}

BackendContractPage<T>? _parsePage<T>(
  Object? raw,
  T? Function(Object?) parser,
) {
  final page = parsePageResult(raw, parser);
  return page == null
      ? null
      : BackendContractPage<T>(
          items: List<T>.unmodifiable(page.items),
          nextCursor: page.nextCursor,
        );
}

BackendCommandAck? _parseCommandAck(Object? raw) {
  final object = asObjectMap(raw);
  if (object == null || object.isEmpty) return null;
  final ack = BackendCommandAck(
    resourceId: _optionalId(
      object['resourceId'] ?? object['id'] ?? object['taskId'],
    ),
    status: _safeText(object['status'], 80),
    revision: _nonNegativeInt(object['revision']),
    accepted: object['accepted'] is bool ? object['accepted']! as bool : null,
  );
  return ack.isMeaningful ? ack : null;
}

TaskContract? _parseTask(Object? raw) {
  final object = asObjectMap(raw);
  final id = _requiredId(object?['taskId'] ?? object?['id']);
  final status = _safeText(object?['status'], 80);
  return id == null || status == null
      ? null
      : TaskContract(
          id: id,
          status: status,
          title: _safeText(object?['title'], 160),
        );
}

RecordingCardFileContract? _parseRecordingCardFile(Object? raw) {
  final object = asObjectMap(raw);
  final id = _requiredId(object?['cardFileId'] ?? object?['id']);
  final name = _safeText(object?['name'], 240);
  final status = _safeText(object?['status'], 80);
  return id == null || name == null || status == null
      ? null
      : RecordingCardFileContract(
          id: id,
          name: name,
          status: status,
          recordingId: _optionalId(object?['recordingId']),
        );
}

RecordingContract? _parseRecording(Object? raw) {
  final object = asObjectMap(raw);
  final id = _requiredId(object?['recordingId'] ?? object?['id']);
  final transcriptStatus =
      _safeText(object?['transcriptStatus'], 80) ??
      _safeText(object?['status'], 80);
  return id == null || transcriptStatus == null
      ? null
      : RecordingContract(
          id: id,
          transcriptStatus: transcriptStatus,
          title: _safeText(object?['title'], 240),
        );
}

AssetsOverviewContract? _parseAssetsOverview(Object? raw) {
  final object = asObjectMap(raw);
  final total = _nonNegativeInt(object?['totalCount']);
  final recordings = _nonNegativeInt(object?['recordingCount']);
  return total == null || recordings == null
      ? null
      : AssetsOverviewContract(totalCount: total, recordingCount: recordings);
}

RecordingAssetContract? _parseRecordingAsset(Object? raw) {
  final object = asObjectMap(raw);
  final id = _requiredId(object?['recordingId'] ?? object?['id']);
  final status = _safeText(object?['status'], 80);
  return id == null || status == null
      ? null
      : RecordingAssetContract(
          id: id,
          status: status,
          title: _safeText(object?['title'], 240),
        );
}

MembershipContract? _parseMembership(Object? raw) {
  final object = asObjectMap(raw);
  final tier = _safeText(object?['tier'], 80);
  final status = _safeText(object?['status'], 80);
  return tier == null || status == null
      ? null
      : MembershipContract(
          tier: tier,
          status: status,
          expiresAt: object?['expiresAt'] == null
              ? null
              : _safeDate(object?['expiresAt']),
        );
}

Future<ApiResult<T>> _invalid<T>(String code) => Future<ApiResult<T>>.value(
  ApiResult<T>.failure(
    error: AppFailure(
      code: code,
      category: AppFailureCategory.api,
      message: 'Backend contract input is invalid',
      userMessageKey: 'backend.contract.$code',
      recoveryActions: const <String>['none'],
    ),
    idempotencyStore: SubmissionKeyStore.empty,
  ),
);

Future<ApiResult<T>> _unavailable<T>(String code) => Future<ApiResult<T>>.value(
  ApiResult<T>.failure(
    error: AppFailure(
      code: code,
      category: AppFailureCategory.api,
      message: 'Backend contract operation is not available',
      userMessageKey: 'backend.contract.$code',
      recoveryActions: const <String>['none'],
    ),
    idempotencyStore: SubmissionKeyStore.empty,
  ),
);

bool _safeId(String value) => isSafeBackendIdentifier(value.trim());

String? _requiredId(Object? value) => _optionalId(value);

String? _optionalId(Object? value) {
  final id = value is String ? value.trim() : null;
  return id != null && _safeId(id) ? id : null;
}

String? _safeText(Object? value, int maxLength) {
  final text = value is String ? value.trim() : null;
  return text == null ||
          text.isEmpty ||
          text.length > maxLength ||
          containsUnsafeBackendText(text)
      ? null
      : text;
}

int? _nonNegativeInt(Object? value) =>
    value is int && value >= 0 ? value : null;

DateTime? _safeDate(Object? value) {
  final text = value is String ? value : null;
  return text == null ? null : DateTime.tryParse(text)?.toUtc();
}
