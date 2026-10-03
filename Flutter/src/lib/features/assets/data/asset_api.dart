import '../../../core/api/api_client.dart';
import '../../../core/api/api_envelope.dart';
import '../../../core/api/idempotency.dart';
import '../domain/asset_models.dart';

export '../domain/asset_models.dart';

final class AssetMarkdownReadLease {
  AssetMarkdownReadLease({
    required this.result,
    required void Function() cancel,
  }) : _cancel = cancel;

  final Future<ApiResult<PersonalAssetMarkdown>> result;
  final void Function() _cancel;
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _cancel();
  }
}

abstract interface class CancellableAssetApiPort {
  AssetMarkdownReadLease leaseMarkdown({AssetMarkdownFocus? focus});
}

final class AssetApi implements AssetApiPort, CancellableAssetApiPort {
  const AssetApi({required ApiClient apiClient}) : _apiClient = apiClient;

  final ApiClient _apiClient;

  @override
  Future<ApiResult<PersonalAssetMarkdown>> getMarkdown({
    AssetMarkdownFocus? focus,
  }) => leaseMarkdown(focus: focus).result;

  @override
  AssetMarkdownReadLease leaseMarkdown({AssetMarkdownFocus? focus}) {
    final lease = _apiClient.leaseGet<PersonalAssetMarkdown>(
      ApiRequestOptions<PersonalAssetMarkdown>(
        endpointId: 'assetsMarkdown',
        query: <String, Object?>{
          if (focus != null) 'focus': _focusValue(focus),
        },
        parseData: parsePersonalAssetMarkdown,
      ),
    );
    return AssetMarkdownReadLease(result: lease.result, cancel: lease.cancel);
  }

  @override
  Future<ApiResult<StructuredAssetDetail>> getAssetDetail({
    required EditableAssetType assetType,
    required String assetId,
  }) {
    if (!isSafeAssetIdentifier(assetId)) {
      return Future<ApiResult<StructuredAssetDetail>>.value(
        _invalid<StructuredAssetDetail>('ASSET_ID_INVALID'),
      );
    }
    return _apiClient.request<StructuredAssetDetail>(
      ApiRequestOptions<StructuredAssetDetail>(
        endpointId: 'assetDetail',
        pathParams: <String, Object>{
          'assetType': _editableAssetTypeValue(assetType),
          'assetId': assetId,
        },
        parseData: parseStructuredAssetDetail,
      ),
    );
  }

  @override
  Future<ApiResult<AssetPatchResult>> patchAsset({
    required EditableAssetType assetType,
    required String assetId,
    required int baseVersion,
    required EditableAssetPatch patch,
    required IdempotencyRequestContext idempotency,
    SubmissionKeyStore idempotencyStore = SubmissionKeyStore.empty,
  }) {
    if (!isSafeAssetIdentifier(assetId) ||
        baseVersion < 0 ||
        patch.assetType != assetType ||
        !isEditableAssetPatchValid(patch)) {
      return Future<ApiResult<AssetPatchResult>>.value(
        _invalid<AssetPatchResult>('ASSET_PATCH_INPUT_INVALID'),
      );
    }
    return _apiClient.request<AssetPatchResult>(
      ApiRequestOptions<AssetPatchResult>(
        endpointId: 'patchAsset',
        pathParams: <String, Object>{
          'assetType': _editableAssetTypeValue(assetType),
          'assetId': assetId,
        },
        body: <String, Object?>{
          'baseVersion': baseVersion,
          'patch': <String, Object?>{
            'assetType': _editableAssetTypeValue(patch.assetType),
            'fields': patch.fields,
          },
        },
        idempotency: idempotency,
        idempotencyStore: idempotencyStore,
        parseData: parseAssetPatchResult,
      ),
    );
  }

  @override
  Future<ApiResult<AssetSyncTask>> syncAssets({
    required IdempotencyRequestContext idempotency,
    SubmissionKeyStore idempotencyStore = SubmissionKeyStore.empty,
  }) {
    return _apiClient.request<AssetSyncTask>(
      ApiRequestOptions<AssetSyncTask>(
        endpointId: 'syncAssets',
        body: const <String, Object?>{},
        idempotency: idempotency,
        idempotencyStore: idempotencyStore,
        parseData: parseAssetSyncTask,
      ),
    );
  }
}

PersonalAssetMarkdown? parsePersonalAssetMarkdown(Object? value) {
  final root = asObjectMap(value);
  final document = root == null ? null : asObjectMap(root['document']);
  final overview = root == null ? null : _parseOverview(root['overview']);
  final sync = root == null ? null : asObjectMap(root['sync']);
  if (root == null || document == null || overview == null || sync == null) {
    return null;
  }
  if (document['schemaVersion'] != 'personal_assets.markdown.v1' ||
      document['locale'] != 'zh-CN' ||
      document['imagePolicy'] != 'none') {
    return null;
  }
  final documentId = _safeIdentifier(document['documentId']);
  final version = _positiveInt(document['documentVersion']);
  final title = _safeText(document['title'], maximum: 240);
  final markdown = _safeMarkdown(document['markdown']);
  final renderedAt = _safeDate(document['renderedAt']);
  final anchors = _parseAnchors(document['anchors']);
  final links = _parseLinks(document['links']);
  final contentLines = _parseContentLines(root['contentLines']);
  final syncStatus = _syncStatus(sync['status']);
  final stale = sync['stale'];
  final retryable = sync['retryable'];
  if (documentId == null ||
      version == null ||
      title == null ||
      markdown == null ||
      renderedAt == null ||
      anchors == null ||
      links == null ||
      contentLines == null ||
      syncStatus == null ||
      stale is! bool ||
      retryable is! bool ||
      !_hasOnlySupportedMarkdown(document['allowedMarkdown'])) {
    return null;
  }
  return PersonalAssetMarkdown(
    documentId: documentId,
    documentVersion: version,
    title: title,
    markdown: markdown,
    renderedAt: renderedAt,
    anchors: List<AssetMarkdownAnchor>.unmodifiable(anchors),
    links: List<AssetMarkdownLink>.unmodifiable(links),
    overview: overview,
    contentLines: List<AssetContentLineBrief>.unmodifiable(contentLines),
    syncStatus: syncStatus,
    stale: stale,
    retryable: retryable,
    latestUpdatedAt: _safeOptionalDate(sync['latestUpdatedAt']),
    latestSyncTaskId: _safeOptionalIdentifier(sync['latestSyncTaskId']),
  );
}

StructuredAssetDetail? parseStructuredAssetDetail(Object? value) {
  final root = asObjectMap(value);
  if (root == null) return null;
  final type = _editableAssetType(root['assetType']);
  final assetId = _safeIdentifier(root['assetId']);
  final asset = _parseAssetFields(root['asset']);
  final editable = root['editable'];
  final version = _nonNegativeInt(root['baseVersion']);
  final sourceReferences = _parseSourceReferences(root['sourceRefs']);
  final updatedAt = _safeDate(root['updatedAt']);
  if (type == null ||
      assetId == null ||
      asset == null ||
      editable is! bool ||
      version == null ||
      sourceReferences == null ||
      updatedAt == null) {
    return null;
  }
  return StructuredAssetDetail(
    assetType: type,
    assetId: assetId,
    asset: Map<String, Object?>.unmodifiable(asset),
    editable: editable,
    baseVersion: version,
    sourceReferences: List<AssetSourceReference>.unmodifiable(sourceReferences),
    updatedAt: updatedAt,
  );
}

AssetPatchResult? parseAssetPatchResult(Object? value) {
  final root = asObjectMap(value);
  if (root == null) return null;
  final type = _editableAssetType(root['assetType']);
  final assetId = _safeIdentifier(root['assetId']);
  final newVersion = _nonNegativeInt(root['newVersion']);
  final asset = _parseAssetFields(root['asset']);
  if (type == null || assetId == null || newVersion == null || asset == null) {
    return null;
  }
  return AssetPatchResult(
    assetType: type,
    assetId: assetId,
    newVersion: newVersion,
    asset: Map<String, Object?>.unmodifiable(asset),
  );
}

AssetSyncTask? parseAssetSyncTask(Object? value) {
  final root = asObjectMap(value);
  final taskId = root == null ? null : _safeIdentifier(root['taskId']);
  final status = root == null ? null : root['status'];
  if (taskId == null || (status != 'queued' && status != 'running')) {
    return null;
  }
  return AssetSyncTask(taskId: taskId, status: status as String);
}

bool isSafeAssetIdentifier(String value) {
  return RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$').hasMatch(value);
}

String _focusValue(AssetMarkdownFocus value) => switch (value) {
  AssetMarkdownFocus.overview => 'overview',
  AssetMarkdownFocus.contentLine => 'content_line',
  AssetMarkdownFocus.recording => 'recording',
  AssetMarkdownFocus.profile => 'profile',
};

String _editableAssetTypeValue(EditableAssetType value) => switch (value) {
  EditableAssetType.contentLine => 'content_line',
  EditableAssetType.profileOverview => 'profile_overview',
  EditableAssetType.lifeEvent => 'life_event',
  EditableAssetType.viewpoint => 'viewpoint',
  EditableAssetType.expression => 'expression',
  EditableAssetType.synonym => 'synonym',
};

EditableAssetType? _editableAssetType(Object? value) => switch (value) {
  'content_line' => EditableAssetType.contentLine,
  'profile_overview' => EditableAssetType.profileOverview,
  'life_event' => EditableAssetType.lifeEvent,
  'viewpoint' => EditableAssetType.viewpoint,
  'expression' => EditableAssetType.expression,
  'synonym' => EditableAssetType.synonym,
  _ => null,
};

AssetOverviewSummary? _parseOverview(Object? value) {
  final map = asObjectMap(value);
  if (map == null) return null;
  final recordingCount = _nonNegativeInt(map['recordingCount']);
  final transcriptWordCount = _nonNegativeInt(map['transcriptWordCount']);
  final contentLineCount = _nonNegativeInt(map['contentLineCount']);
  final lifeEventCount = _nonNegativeInt(map['lifeEventCount']);
  final expressionCount = _nonNegativeInt(map['expressionCount']);
  final syncStatus = _syncStatus(map['syncStatus']);
  if (recordingCount == null ||
      transcriptWordCount == null ||
      contentLineCount == null ||
      lifeEventCount == null ||
      expressionCount == null ||
      syncStatus == null) {
    return null;
  }
  return AssetOverviewSummary(
    recordingCount: recordingCount,
    transcriptWordCount: transcriptWordCount,
    contentLineCount: contentLineCount,
    lifeEventCount: lifeEventCount,
    expressionCount: expressionCount,
    syncStatus: syncStatus,
    latestUpdatedAt: _safeOptionalDate(map['latestUpdatedAt']),
  );
}

List<AssetContentLineBrief>? _parseContentLines(Object? value) {
  if (value is! List) return null;
  final output = <AssetContentLineBrief>[];
  for (final raw in value) {
    final map = asObjectMap(raw);
    final id = map == null ? null : _safeIdentifier(map['contentLineId']);
    final name = map == null ? null : _safeText(map['name'], maximum: 240);
    if (id == null || name == null) return null;
    final industry = _safeOptionalText(map!['industry'], maximum: 120);
    output.add(
      AssetContentLineBrief(contentLineId: id, name: name, industry: industry),
    );
  }
  return output;
}

List<AssetMarkdownAnchor>? _parseAnchors(Object? value) {
  if (value is! List) return null;
  final output = <AssetMarkdownAnchor>[];
  for (final raw in value) {
    final map = asObjectMap(raw);
    final id = map == null ? null : _safeIdentifier(map['anchorId']);
    final title = map == null ? null : _safeText(map['title'], maximum: 240);
    final level = map == null ? null : map['level'];
    if (id == null ||
        title == null ||
        level is! int ||
        level < 1 ||
        level > 3) {
      return null;
    }
    output.add(AssetMarkdownAnchor(anchorId: id, title: title, level: level));
  }
  return output;
}

List<AssetMarkdownLink>? _parseLinks(Object? value) {
  if (value is! List) return null;
  final output = <AssetMarkdownLink>[];
  for (final raw in value) {
    final map = asObjectMap(raw);
    final linkId = map == null ? null : _safeIdentifier(map['linkId']);
    final hrefValue = map == null ? null : map['href'];
    final href = hrefValue is String ? hrefValue : null;
    final label = map == null ? null : _safeText(map['label'], maximum: 240);
    final target = map == null ? null : _parseLinkTarget(map['target']);
    if (linkId == null ||
        href != 'huahuo://asset-link/$linkId' ||
        label == null ||
        target == null) {
      return null;
    }
    output.add(
      AssetMarkdownLink(
        linkId: linkId,
        href: href!,
        label: label,
        target: target,
      ),
    );
  }
  return output;
}

AssetMarkdownLinkTarget? _parseLinkTarget(Object? value) {
  final map = asObjectMap(value);
  if (map == null) return null;
  switch (map['type']) {
    case 'markdown_anchor':
      final id = _safeIdentifier(map['anchorId']);
      return id == null ? null : AssetMarkdownLinkTarget.markdownAnchor(id);
    case 'recording_detail':
      final id = _safeIdentifier(map['recordingId']);
      return id == null ? null : AssetMarkdownLinkTarget.recordingDetail(id);
    case 'content_line_detail':
      final id = _safeIdentifier(map['contentLineId']);
      return id == null ? null : AssetMarkdownLinkTarget.contentLineDetail(id);
    case 'asset_page':
      final focus = _focusFromWire(map['focus']);
      return map['focus'] == null || focus != null
          ? AssetMarkdownLinkTarget.assetPage(focus)
          : null;
  }
  return null;
}

List<AssetSourceReference>? _parseSourceReferences(Object? value) {
  if (value is! List) return null;
  final output = <AssetSourceReference>[];
  for (final raw in value) {
    final map = asObjectMap(raw);
    final type = map == null ? null : map['sourceType'];
    if (type != 'recording' &&
        type != 'feed_ai' &&
        type != 'manual' &&
        type != 'admin') {
      return null;
    }
    output.add(
      AssetSourceReference(
        sourceType: type as String,
        sourceId: _safeOptionalIdentifier(map!['sourceId']),
        title: _safeOptionalText(map['title'], maximum: 240),
      ),
    );
  }
  return output;
}

Map<String, Object?>? _parseAssetFields(Object? value) {
  final map = asObjectMap(value);
  if (map == null) return null;
  final output = <String, Object?>{};
  for (final entry in map.entries) {
    if (!RegExp(r'^[A-Za-z][A-Za-z0-9_]{0,63}$').hasMatch(entry.key) ||
        _unsafeText.any((pattern) => pattern.hasMatch(entry.key))) {
      return null;
    }
    final field = _parseAssetField(entry.value);
    if (field == null && entry.value != null) return null;
    output[entry.key] = field;
  }
  return output;
}

Object? _parseAssetField(Object? value) {
  if (value == null || value is bool) return value;
  if (value is num && value.isFinite) return value;
  if (value is String) return _safeText(value, maximum: 4000);
  if (value is List) {
    final values = <String>[];
    for (final item in value) {
      final text = _safeText(item, maximum: 240);
      if (text == null) return null;
      values.add(text);
    }
    return List<String>.unmodifiable(values);
  }
  return null;
}

AssetSyncStatus? _syncStatus(Object? value) => switch (value) {
  'normal' => AssetSyncStatus.normal,
  'syncing' => AssetSyncStatus.syncing,
  'sync_failed' => AssetSyncStatus.syncFailed,
  'empty' => AssetSyncStatus.empty,
  _ => null,
};

AssetMarkdownFocus? _focusFromWire(Object? value) => switch (value) {
  'overview' => AssetMarkdownFocus.overview,
  'content_line' => AssetMarkdownFocus.contentLine,
  'recording' => AssetMarkdownFocus.recording,
  'profile' => AssetMarkdownFocus.profile,
  _ => null,
};

bool _hasOnlySupportedMarkdown(Object? value) {
  if (value is! List || value.isEmpty) return false;
  const supported = <String>{
    'heading',
    'paragraph',
    'unordered_list',
    'ordered_list',
    'blockquote',
    'table',
    'emphasis',
    'strong',
    'inline_code',
    'code_block',
  };
  return value.every((item) => item is String && supported.contains(item));
}

int? _nonNegativeInt(Object? value) {
  if (value is int && value >= 0) return value;
  if (value is num && value >= 0 && value == value.roundToDouble()) {
    return value.toInt();
  }
  return null;
}

int? _positiveInt(Object? value) {
  final number = _nonNegativeInt(value);
  return number != null && number > 0 ? number : null;
}

String? _safeIdentifier(Object? value) {
  final text = value is String ? value.trim() : null;
  return text != null && isSafeAssetIdentifier(text) ? text : null;
}

String? _safeOptionalIdentifier(Object? value) {
  return value == null ? null : _safeIdentifier(value);
}

String? _safeText(Object? value, {required int maximum}) {
  final text = value is String ? value.trim() : null;
  if (text == null || text.isEmpty || text.length > maximum) return null;
  return _unsafeText.any((pattern) => pattern.hasMatch(text)) ? null : text;
}

String? _safeOptionalText(Object? value, {required int maximum}) {
  return value == null ? null : _safeText(value, maximum: maximum);
}

String? _safeMarkdown(Object? value) {
  final text = value is String ? value.replaceAll('\r\n', '\n').trim() : null;
  if (text == null || text.length > 120000) return null;
  return _unsafeMarkdown.any((pattern) => pattern.hasMatch(text)) ? null : text;
}

DateTime? _safeDate(Object? value) {
  final text = value is String ? value.trim() : null;
  if (text == null || text.length > 64) return null;
  return DateTime.tryParse(text)?.toUtc();
}

DateTime? _safeOptionalDate(Object? value) {
  return value == null ? null : _safeDate(value);
}

ApiResult<T> _invalid<T>(String code) {
  return ApiResult<T>.failure(
    error: AppFailure(
      code: code,
      category: AppFailureCategory.api,
      message: 'Asset API input is invalid',
      userMessageKey: 'assets.api.error.$code',
    ),
    idempotencyStore: SubmissionKeyStore.empty,
  );
}

final _unsafeText = <RegExp>[
  RegExp(r'^file://', caseSensitive: false),
  RegExp(r'^[A-Za-z]:[\\/]'),
  RegExp(r'[\\/]Users[\\/]', caseSensitive: false),
  RegExp('workspace', caseSensitive: false),
  RegExp('runtime', caseSensitive: false),
  RegExp('provider', caseSensitive: false),
  RegExp('model.*key', caseSensitive: false),
  RegExp('token', caseSensitive: false),
  RegExp('secret', caseSensitive: false),
];

final _unsafeMarkdown = <RegExp>[
  ..._unsafeText,
  RegExp(r'<\s*(script|iframe|html|img)\b', caseSensitive: false),
  RegExp(r'!\[[^\]]*\]\s*\(', caseSensitive: false),
  RegExp(r'\bhttps?://', caseSensitive: false),
  RegExp(r'\bfile://', caseSensitive: false),
];
