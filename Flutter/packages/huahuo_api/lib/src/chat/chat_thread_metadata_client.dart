import '../api/api_client.dart';
import '../api/api_envelope.dart';
import '../api/idempotency.dart';

enum SharedChatThreadTitleMode { auto, custom }

const int _maximumRuntimeInvocationPageSize = 50;
const int _maximumRuntimeInvocationCursorLength = 1024;
const int _maximumRuntimeToolReceiptsPerRun = 800;

final class SharedThreadRuntimeInvocationPage {
  const SharedThreadRuntimeInvocationPage({
    required this.items,
    this.nextCursor,
  });

  final List<SharedThreadRuntimeInvocation> items;
  final String? nextCursor;
}

final class SharedChatThreadMetadata {
  const SharedChatThreadMetadata({
    required this.threadId,
    required this.title,
    required this.titleMode,
    required this.titleVersion,
  });

  final String threadId;
  final String title;
  final SharedChatThreadTitleMode titleMode;
  final int titleVersion;
}

final class SharedThreadRuntimeInvocation {
  const SharedThreadRuntimeInvocation({
    required this.schemaVersion,
    required this.threadId,
    required this.agentRunId,
    required this.status,
    required this.agentProfileId,
    required this.modelProfileId,
    required this.skillProfileIds,
    required this.contentTypes,
    required this.tools,
    required this.files,
    this.dispatchId,
    this.agentReleaseVersion,
    this.skillReleaseVersions = const <String>[],
    this.attachmentCount = 0,
    this.workspaceDocumentCount = 0,
    this.creativePositioningId,
    this.createdAt,
    this.completedAt,
    this.progress = const <SharedRuntimeProgress>[],
  });

  final String schemaVersion;
  final String threadId;
  final String agentRunId;
  final String? dispatchId;
  final String status;
  final String agentProfileId;
  final String? agentReleaseVersion;
  final String modelProfileId;
  final List<String> skillProfileIds;
  final List<String> skillReleaseVersions;
  final List<SharedRuntimeTool> tools;
  final List<SharedRuntimeFile> files;
  final List<String> contentTypes;
  final int attachmentCount;
  final int workspaceDocumentCount;
  final String? creativePositioningId;
  final DateTime? createdAt;
  final DateTime? completedAt;
  final List<SharedRuntimeProgress> progress;
}

final class SharedRuntimeTool {
  const SharedRuntimeTool({
    required this.name,
    required this.state,
    this.invocationId,
    this.durationMs,
    this.createdAt,
    this.inputSummary = const <String, Object?>{},
    this.outputSummary = const <String, Object?>{},
  });

  final String name;
  final String state;
  final String? invocationId;
  final int? durationMs;
  final DateTime? createdAt;
  final Map<String, Object?> inputSummary;
  final Map<String, Object?> outputSummary;
}

final class SharedRuntimeProgress {
  const SharedRuntimeProgress({
    required this.kind,
    required this.title,
    required this.status,
    required this.createdAt,
    this.summary,
  });

  final String kind;
  final String title;
  final String status;
  final String? summary;
  final DateTime createdAt;
}

final class SharedRuntimeFile {
  const SharedRuntimeFile({
    required this.name,
    this.ordinal,
    this.category,
    this.mimeType,
    this.sizeBytes,
    this.editable,
  });

  final String name;
  final int? ordinal;
  final String? category;
  final String? mimeType;
  final int? sizeBytes;
  final bool? editable;
}

final class ChatThreadMetadataClient {
  const ChatThreadMetadataClient(this._api);
  final ApiClient _api;

  Future<ApiResult<SharedChatThreadMetadata>> updateTitle({
    required String threadId,
    required SharedChatThreadTitleMode titleMode,
    String? title,
    required int expectedTitleVersion,
    required IdempotencyRequestContext idempotency,
    SubmissionKeyStore idempotencyStore = SubmissionKeyStore.empty,
  }) => _api.request<SharedChatThreadMetadata>(
    ApiRequestOptions<SharedChatThreadMetadata>(
      endpointId: 'updateChatThreadMetadata',
      pathParams: <String, Object>{'threadId': threadId},
      body: <String, Object?>{
        'titleMode': titleMode.name,
        if (titleMode == SharedChatThreadTitleMode.custom)
          'title': title?.trim(),
        'expectedTitleVersion': expectedTitleVersion,
      },
      idempotency: idempotency,
      idempotencyStore: idempotencyStore,
      parseData: parseSharedChatThreadMetadata,
    ),
  );

  Future<ApiConditionalResult<SharedThreadRuntimeInvocation>> latestInvocation({
    required String threadId,
    String? ifNoneMatch,
  }) => _api.requestConditional<SharedThreadRuntimeInvocation>(
    ApiRequestOptions<SharedThreadRuntimeInvocation>(
      endpointId: 'chatThreadRuntimeInvocation',
      pathParams: <String, Object>{'threadId': threadId},
      headers: <String, String>{
        if (ifNoneMatch?.trim().isNotEmpty == true)
          'If-None-Match': ifNoneMatch!.trim(),
      },
      parseData: parseSharedThreadRuntimeInvocation,
    ),
  );

  Future<ApiConditionalResult<SharedThreadRuntimeInvocationPage>>
  listInvocations({
    required String threadId,
    String? cursor,
    int limit = 20,
    String? ifNoneMatch,
  }) {
    final normalizedThreadId = _safeRuntimeIdentifier(threadId);
    if (normalizedThreadId == null) {
      throw ArgumentError.value(
        threadId,
        'threadId',
        'must be a non-empty public identifier',
      );
    }
    if (limit < 1 || limit > _maximumRuntimeInvocationPageSize) {
      throw ArgumentError.value(limit, 'limit', 'must be between 1 and 50');
    }
    final normalizedCursor = cursor?.trim();
    if (normalizedCursor != null &&
        (normalizedCursor.isEmpty ||
            normalizedCursor.length > _maximumRuntimeInvocationCursorLength)) {
      throw ArgumentError.value(
        cursor,
        'cursor',
        'must be a non-empty opaque cursor of at most 1024 characters',
      );
    }
    final etag = ifNoneMatch?.trim();
    return _api.requestConditional<SharedThreadRuntimeInvocationPage>(
      ApiRequestOptions<SharedThreadRuntimeInvocationPage>(
        endpointId: 'chatThreadRuntimeInvocations',
        pathParams: <String, Object>{'threadId': normalizedThreadId},
        query: <String, Object?>{
          'limit': limit,
          if (normalizedCursor != null) 'cursor': normalizedCursor,
        },
        headers: <String, String>{
          if (etag?.isNotEmpty == true) 'If-None-Match': etag!,
        },
        parseData: (value) {
          final page = parseSharedThreadRuntimeInvocationPage(value);
          if (page == null ||
              page.items.any((item) => item.threadId != normalizedThreadId)) {
            return null;
          }
          return page;
        },
      ),
    );
  }
}

SharedChatThreadMetadata? parseSharedChatThreadMetadata(Object? value) {
  final root = value is Map ? Map<String, Object?>.from(value) : null;
  final object = root?['thread'] is Map
      ? Map<String, Object?>.from(root!['thread'] as Map)
      : root;
  if (object == null) return null;
  final id = _safeIdentifier(object['threadId'] ?? object['id']);
  final title = _safeText(object['title']);
  final mode = switch (object['titleMode']) {
    'auto' => SharedChatThreadTitleMode.auto,
    'custom' => SharedChatThreadTitleMode.custom,
    _ => null,
  };
  final version = object['titleVersion'];
  if (id == null ||
      title == null ||
      mode == null ||
      version is! int ||
      version < 1) {
    return null;
  }
  return SharedChatThreadMetadata(
    threadId: id,
    title: title,
    titleMode: mode,
    titleVersion: version,
  );
}

SharedThreadRuntimeInvocationPage? parseSharedThreadRuntimeInvocationPage(
  Object? value,
) {
  final object = asObjectMap(value);
  if (object == null ||
      !_hasOnlyKeys(object, const <String>{'items', 'nextCursor'})) {
    return null;
  }
  final rawItems = object['items'];
  if (rawItems is! List ||
      rawItems.length > _maximumRuntimeInvocationPageSize) {
    return null;
  }
  final rawCursor = object['nextCursor'];
  final nextCursor = rawCursor == null ? null : _safeOpaqueCursor(rawCursor);
  if (rawCursor != null && nextCursor == null ||
      nextCursor != null && rawItems.isEmpty) {
    return null;
  }

  final items = <SharedThreadRuntimeInvocation>[];
  final runIds = <String>{};
  String? threadId;
  SharedThreadRuntimeInvocation? previous;
  for (final raw in rawItems) {
    final item = parseSharedThreadRuntimeInvocation(raw, strict: true);
    if (item == null || !runIds.add(item.agentRunId)) return null;
    threadId ??= item.threadId;
    if (item.threadId != threadId ||
        previous != null && !_isRuntimeInvocationAfter(previous, item)) {
      return null;
    }
    items.add(item);
    previous = item;
  }
  return SharedThreadRuntimeInvocationPage(
    items: List<SharedThreadRuntimeInvocation>.unmodifiable(items),
    nextCursor: nextCursor,
  );
}

SharedThreadRuntimeInvocation? parseSharedThreadRuntimeInvocation(
  Object? value, {
  bool strict = false,
}) {
  final object = asObjectMap(value);
  if (object == null) return null;
  final selection = asObjectMap(object['selection']);
  final summary = asObjectMap(object['requestSummary']);
  if (selection == null ||
      summary == null ||
      _safeText(object['schemaVersion']) !=
          'huahuo.thread-runtime-invocation.v1') {
    return null;
  }
  if (strict && !_isCanonicalRuntimeInvocation(object, selection, summary)) {
    return null;
  }
  final skills = _safeStringList(selection['skillProfileIds']);
  final skillReleases = strict
      ? _safeStringList(selection['skillReleaseVersions'])
      : _safeOptionalStringList(selection['skillReleaseVersions']);
  final types = _safeStringList(summary['contentTypes'], maximum: 16);
  final tools = _safeTools(object['tools'], strict: strict);
  final files = _safeFiles(object['files'], strict: strict);
  final progress = _safeProgress(object['progress'], strict: strict);
  final identifier = strict ? _safeRuntimeIdentifier : _safeIdentifier;
  final threadId = identifier(object['threadId']);
  final runId = identifier(object['agentRunId']);
  final dispatchId = _safeRuntimeIdentifier(object['dispatchId']);
  final status = _safeText(object['status']);
  final agent = identifier(selection['agentProfileId']);
  final rawModel = selection['modelProfileId'];
  final model = rawModel == null && strict ? '' : identifier(rawModel);
  final agentRelease = _safeRuntimeIdentifier(selection['agentReleaseVersion']);
  final createdAt = _safeDateTime(object['createdAt']);
  final completedAt = _safeDateTime(object['completedAt']);
  final attachmentCount = summary['attachmentCount'];
  final workspaceDocumentCount = summary['workspaceDocumentCount'];
  final rawPositioningId = summary['creativePositioningId'];
  final positioningId = _safeRuntimeIdentifier(rawPositioningId);
  if (threadId == null ||
      runId == null ||
      status == null ||
      agent == null ||
      model == null ||
      skills == null ||
      skillReleases == null ||
      types == null ||
      tools == null ||
      files == null ||
      progress == null ||
      (strict &&
          (dispatchId == null ||
              !_runtimeInvocationStatuses.contains(status) ||
              createdAt == null ||
              (object.containsKey('completedAt') && completedAt == null) ||
              (completedAt != null && completedAt.isBefore(createdAt)) ||
              agentRelease == null &&
                  selection.containsKey('agentReleaseVersion') ||
              rawModel != null && model.isEmpty ||
              skillReleases.length != skills.length ||
              types.any(
                (type) => !_runtimeInvocationContentTypes.contains(type),
              ) ||
              attachmentCount is! int ||
              attachmentCount < 0 ||
              workspaceDocumentCount is! int ||
              workspaceDocumentCount < 0 ||
              rawPositioningId != null && positioningId == null))) {
    return null;
  }
  return SharedThreadRuntimeInvocation(
    schemaVersion: 'huahuo.thread-runtime-invocation.v1',
    threadId: threadId,
    agentRunId: runId,
    dispatchId: dispatchId,
    status: status,
    agentProfileId: agent,
    agentReleaseVersion: agentRelease,
    modelProfileId: model,
    skillProfileIds: List<String>.unmodifiable(skills),
    skillReleaseVersions: List<String>.unmodifiable(skillReleases),
    contentTypes: List<String>.unmodifiable(types),
    tools: List<SharedRuntimeTool>.unmodifiable(tools),
    files: List<SharedRuntimeFile>.unmodifiable(files),
    attachmentCount: attachmentCount is int ? attachmentCount : 0,
    workspaceDocumentCount: workspaceDocumentCount is int
        ? workspaceDocumentCount
        : 0,
    creativePositioningId: positioningId,
    createdAt: createdAt,
    completedAt: completedAt,
    progress: List<SharedRuntimeProgress>.unmodifiable(progress),
  );
}

List<SharedRuntimeTool>? _safeTools(Object? value, {bool strict = false}) {
  if (value is! List || value.length > _maximumRuntimeToolReceiptsPerRun) {
    return null;
  }
  final items = <SharedRuntimeTool>[];
  for (final raw in value) {
    final item = asObjectMap(raw);
    if (item == null) return null;
    if (strict &&
        (!_hasOnlyKeys(item, const <String>{
              'invocationId',
              'toolName',
              'status',
              'durationMs',
              'inputSummary',
              'outputSummary',
              'createdAt',
            }) ||
            !_strictRuntimeSummary(item['inputSummary']) ||
            !_strictRuntimeSummary(item['outputSummary']))) {
      return null;
    }
    final name = strict
        ? _safeRuntimeIdentifier(item['toolName'])
        : _safeText(item['toolName'] ?? item['name'] ?? item['toolId']);
    final state = _safeText(item['status'] ?? item['state']);
    final invocationId = _safeRuntimeIdentifier(item['invocationId']);
    final duration = item['durationMs'];
    final createdAt = _safeDateTime(item['createdAt']);
    if (name == null ||
        strict &&
            (!_runtimeToolNames.contains(name) ||
                invocationId == null ||
                state == null ||
                !_runtimeToolStatuses.contains(state) ||
                createdAt == null ||
                duration != null && (duration is! int || duration < 0))) {
      return null;
    }
    items.add(
      SharedRuntimeTool(
        name: name,
        state: state ?? 'unknown',
        invocationId: invocationId,
        durationMs: duration is int && duration >= 0 ? duration : null,
        createdAt: createdAt,
        inputSummary: _safeRuntimeSummary(item['inputSummary']),
        outputSummary: _safeRuntimeSummary(item['outputSummary']),
      ),
    );
  }
  return items;
}

List<SharedRuntimeProgress>? _safeProgress(
  Object? value, {
  bool strict = false,
}) {
  if (value == null) return <SharedRuntimeProgress>[];
  if (value is! List) return null;
  final items = <SharedRuntimeProgress>[];
  for (final raw in value) {
    final item = asObjectMap(raw);
    if (item == null) {
      if (strict) return null;
      continue;
    }
    if (strict &&
        !_hasOnlyKeys(item, const <String>{
          'kind',
          'title',
          'status',
          'summary',
          'createdAt',
        })) {
      return null;
    }
    final kind = _safeText(item['kind']);
    final title = _safeText(item['title']);
    final status = _safeText(item['status']);
    final createdAt = _safeDateTime(item['createdAt']);
    if ((kind != 'plan' && kind != 'item') ||
        title == null ||
        (status != 'started' &&
            status != 'updated' &&
            status != 'completed' &&
            status != 'failed') ||
        createdAt == null) {
      if (strict) return null;
      continue;
    }
    items.add(
      SharedRuntimeProgress(
        kind: kind!,
        title: title,
        status: status!,
        summary: _safeText(item['summary']),
        createdAt: createdAt,
      ),
    );
  }
  return items;
}

Map<String, Object?> _safeRuntimeSummary(Object? value) {
  if (value is! Map || value.length > 24) return const <String, Object?>{};
  final source = Map<String, Object?>.from(value);
  final result = <String, Object?>{};
  for (final entry in source.entries) {
    final key = entry.key;
    final raw = entry.value;
    if (_runtimeSummaryNumberFields.contains(key)) {
      if (raw is int && raw >= 0) result[key] = raw;
      continue;
    }
    if (_runtimeSummaryPathFields.contains(key)) {
      final path = _safeRuntimeLogicalPath(raw);
      if (path != null) result[key] = path;
      continue;
    }
    if (_runtimeSummaryTextFields.contains(key)) {
      final text = _safeText(raw);
      if (text != null) result[key] = text;
      continue;
    }
    if (_runtimeSummaryListFields.contains(key)) {
      final values = _safeStringList(raw, maximum: 32);
      if (values != null) result[key] = List<String>.unmodifiable(values);
      continue;
    }
    if (_runtimeSummaryUnboundedListFields.contains(key)) {
      final values = _safeStringList(raw);
      if (values != null) result[key] = List<String>.unmodifiable(values);
    }
  }
  return Map<String, Object?>.unmodifiable(result);
}

const Set<String> _runtimeSummaryNumberFields = <String>{
  'offset',
  'limit',
  'depth',
  'contentBytes',
  'attachmentCount',
  'count',
  'rankCount',
  'outputFileCount',
  'totalSizeBytes',
};

const Set<String> _runtimeSummaryTextFields = <String>{
  'query',
  'timeRange',
  'operation',
  'instructionSummary',
  'promptSummary',
  'aspectRatio',
  'action',
  'date',
};

const Set<String> _runtimeSummaryPathFields = <String>{
  'logicalTarget',
  'logicalDirectory',
  'logicalScope',
};

const Set<String> _runtimeSummaryListFields = <String>{
  'keywords',
  'redactedFields',
  'truncatedFields',
};

const Set<String> _runtimeSummaryUnboundedListFields = <String>{'mediaTypes'};

List<SharedRuntimeFile>? _safeFiles(Object? value, {bool strict = false}) {
  if (value is! List) return null;
  final items = <SharedRuntimeFile>[];
  for (final raw in value) {
    final item = asObjectMap(raw);
    if (item == null) return null;
    if (strict &&
        !_hasOnlyKeys(item, const <String>{
          'ordinal',
          'category',
          'mediaType',
          'sizeBytes',
          'editable',
        })) {
      return null;
    }
    final category = _safeText(item['category']);
    final name = _safeText(
      item['fileName'] ??
          item['name'] ??
          item['fileId'] ??
          item['resourceId'] ??
          category,
    );
    final mime = _safeText(item['mediaType'] ?? item['mimeType']);
    final size = item['sizeBytes'];
    final ordinal = item['ordinal'];
    final editable = item['editable'];
    if (name == null ||
        size != null && (size is! int || size < 0) ||
        strict &&
            (ordinal is! int ||
                ordinal != items.length ||
                category == null ||
                !_runtimeFileCategories.contains(category) ||
                size is! int ||
                editable is! bool ||
                item.containsKey('mediaType') && mime == null)) {
      return null;
    }
    items.add(
      SharedRuntimeFile(
        name: name,
        ordinal: ordinal is int ? ordinal : null,
        category: category,
        mimeType: mime,
        sizeBytes: size as int?,
        editable: editable is bool ? editable : null,
      ),
    );
  }
  return items;
}

List<String>? _safeStringList(Object? value, {int? maximum}) {
  if (value is! List || maximum != null && value.length > maximum) return null;
  final items = <String>[];
  for (final raw in value) {
    final item = _safeText(raw);
    if (item == null) return null;
    items.add(item);
  }
  return items;
}

List<String>? _safeOptionalStringList(Object? value, {int? maximum}) =>
    value == null ? <String>[] : _safeStringList(value, maximum: maximum);

String? _safeOpaqueCursor(Object? value) {
  if (value is! String ||
      value.isEmpty ||
      value != value.trim() ||
      value.length > _maximumRuntimeInvocationCursorLength) {
    return null;
  }
  return value;
}

bool _isRuntimeInvocationAfter(
  SharedThreadRuntimeInvocation previous,
  SharedThreadRuntimeInvocation current,
) {
  final previousCreatedAt = previous.createdAt!;
  final currentCreatedAt = current.createdAt!;
  if (previousCreatedAt.isAfter(currentCreatedAt)) return true;
  if (previousCreatedAt.isBefore(currentCreatedAt)) return false;
  return previous.agentRunId.compareTo(current.agentRunId) > 0;
}

bool _isCanonicalRuntimeInvocation(
  Map<String, Object?> object,
  Map<String, Object?> selection,
  Map<String, Object?> summary,
) {
  return _hasOnlyKeys(object, const <String>{
        'schemaVersion',
        'threadId',
        'agentRunId',
        'dispatchId',
        'status',
        'createdAt',
        'completedAt',
        'selection',
        'requestSummary',
        'files',
        'tools',
        'progress',
      }) &&
      _hasOnlyKeys(selection, const <String>{
        'agentProfileId',
        'agentReleaseVersion',
        'skillProfileIds',
        'skillReleaseVersions',
        'modelProfileId',
      }) &&
      _hasOnlyKeys(summary, const <String>{
        'contentTypes',
        'attachmentCount',
        'workspaceDocumentCount',
        'creativePositioningId',
      }) &&
      object.containsKey('dispatchId') &&
      object.containsKey('createdAt') &&
      object.containsKey('files') &&
      object.containsKey('tools') &&
      selection.containsKey('agentProfileId') &&
      selection.containsKey('skillProfileIds') &&
      selection.containsKey('skillReleaseVersions') &&
      summary.containsKey('contentTypes') &&
      summary.containsKey('attachmentCount') &&
      summary.containsKey('workspaceDocumentCount');
}

bool _strictRuntimeSummary(Object? value) {
  if (value == null) return true;
  final object = asObjectMap(value);
  if (object == null || object.length > 24) return false;
  for (final entry in object.entries) {
    if (_runtimeSummaryNumberFields.contains(entry.key)) {
      if (entry.value is! int || (entry.value! as int) < 0) return false;
      continue;
    }
    if (_runtimeSummaryPathFields.contains(entry.key)) {
      if (_safeRuntimeLogicalPath(entry.value) == null) return false;
      continue;
    }
    if (_runtimeSummaryTextFields.contains(entry.key)) {
      if (_safeText(entry.value) == null) return false;
      continue;
    }
    if (_runtimeSummaryListFields.contains(entry.key)) {
      if (_safeStringList(entry.value, maximum: 32) == null) return false;
      continue;
    }
    if (_runtimeSummaryUnboundedListFields.contains(entry.key)) {
      if (_safeStringList(entry.value) == null) return false;
      continue;
    }
    return false;
  }
  return true;
}

bool _hasOnlyKeys(Map<String, Object?> object, Set<String> allowed) =>
    object.keys.every(allowed.contains);

const Set<String> _runtimeInvocationStatuses = <String>{
  'created',
  'sent',
  'submit_unknown',
  'retry_same_host',
  'accepted',
  'materializing',
  'running',
  'finalizing',
  'recovering',
  'succeeded',
  'failed',
  'timeout',
  'aborted',
  'rejected',
  'orphaned',
};

const Set<String> _runtimeInvocationContentTypes = <String>{
  'text',
  'image',
  'file',
  'workspace_document',
  'audio',
  'video',
};

const Set<String> _runtimeToolNames = <String>{
  'edit',
  'read',
  'workspace_list',
  'workspace_search',
  'write',
  'image_analysis',
  'image_generation',
  'video_analysis',
  'huahuo_hotspot_query',
};

const Set<String> _runtimeToolStatuses = <String>{
  'started',
  'succeeded',
  'failed',
  'rejected',
};

const Set<String> _runtimeFileCategories = <String>{
  'workspace',
  'runtime_input',
  'attachment',
  'workspace_document',
  'agent',
  'skill',
  'knowledge',
  'meta',
  'other',
};

String? _safeIdentifier(Object? value) {
  final text = _safeText(value);
  return text != null &&
          RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,159}$').hasMatch(text)
      ? text
      : null;
}

String? _safeRuntimeIdentifier(Object? value) {
  final text = _safeText(value);
  return text != null &&
          RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,255}$').hasMatch(text)
      ? text
      : null;
}

DateTime? _safeDateTime(Object? value) {
  if (value is! String) return null;
  return DateTime.tryParse(value)?.toUtc();
}

String? _safeText(Object? value) {
  if (value is! String) return null;
  final normalized = value.trim();
  return normalized.isEmpty || normalized.length > 512 ? null : normalized;
}

String? _safeRuntimeLogicalPath(Object? value) {
  if (value is! String) return null;
  final normalized = value.trim().replaceAll('\\', '/');
  final lower = normalized.toLowerCase();
  if (normalized.isEmpty ||
      normalized.length > 4096 ||
      normalized.contains(RegExp(r'[\x00\r\n]')) ||
      normalized.startsWith('/') ||
      normalized.startsWith('~/') ||
      RegExp(r'^[A-Za-z]:/').hasMatch(normalized) ||
      lower.contains('://') ||
      normalized.split('/').contains('..')) {
    return null;
  }
  return normalized;
}
