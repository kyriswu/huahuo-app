import 'package:huahuo_api/huahuo_api.dart';

enum AssetMarkdownFocus { overview, contentLine, recording, profile }

enum AssetSyncStatus { normal, syncing, syncFailed, empty }

final class AssetOverviewSummary {
  const AssetOverviewSummary({
    required this.recordingCount,
    required this.transcriptWordCount,
    required this.contentLineCount,
    required this.lifeEventCount,
    required this.expressionCount,
    required this.syncStatus,
    this.latestUpdatedAt,
  });

  final int recordingCount;
  final int transcriptWordCount;
  final int contentLineCount;
  final int lifeEventCount;
  final int expressionCount;
  final AssetSyncStatus syncStatus;
  final DateTime? latestUpdatedAt;
}

final class AssetContentLineBrief {
  const AssetContentLineBrief({
    required this.contentLineId,
    required this.name,
    this.industry,
  });

  final String contentLineId;
  final String name;
  final String? industry;
}

final class AssetMarkdownAnchor {
  const AssetMarkdownAnchor({
    required this.anchorId,
    required this.title,
    required this.level,
  });

  final String anchorId;
  final String title;
  final int level;
}

enum AssetMarkdownLinkTargetType {
  markdownAnchor,
  recordingDetail,
  contentLineDetail,
  assetPage,
}

final class AssetMarkdownLinkTarget {
  const AssetMarkdownLinkTarget._({
    required this.type,
    this.anchorId,
    this.recordingId,
    this.contentLineId,
    this.focus,
  });

  const AssetMarkdownLinkTarget.markdownAnchor(String anchorId)
    : this._(
        type: AssetMarkdownLinkTargetType.markdownAnchor,
        anchorId: anchorId,
      );

  const AssetMarkdownLinkTarget.recordingDetail(String recordingId)
    : this._(
        type: AssetMarkdownLinkTargetType.recordingDetail,
        recordingId: recordingId,
      );

  const AssetMarkdownLinkTarget.contentLineDetail(String contentLineId)
    : this._(
        type: AssetMarkdownLinkTargetType.contentLineDetail,
        contentLineId: contentLineId,
      );

  const AssetMarkdownLinkTarget.assetPage(AssetMarkdownFocus? focus)
    : this._(type: AssetMarkdownLinkTargetType.assetPage, focus: focus);

  final AssetMarkdownLinkTargetType type;
  final String? anchorId;
  final String? recordingId;
  final String? contentLineId;
  final AssetMarkdownFocus? focus;
}

final class AssetMarkdownLink {
  const AssetMarkdownLink({
    required this.linkId,
    required this.href,
    required this.label,
    required this.target,
  });

  final String linkId;
  final String href;
  final String label;
  final AssetMarkdownLinkTarget target;
}

final class PersonalAssetMarkdown {
  const PersonalAssetMarkdown({
    required this.documentId,
    required this.documentVersion,
    required this.title,
    required this.markdown,
    required this.renderedAt,
    required this.anchors,
    required this.links,
    required this.overview,
    required this.contentLines,
    required this.syncStatus,
    required this.stale,
    required this.retryable,
    this.latestUpdatedAt,
    this.latestSyncTaskId,
  });

  final String documentId;
  final int documentVersion;
  final String title;
  final String markdown;
  final DateTime renderedAt;
  final List<AssetMarkdownAnchor> anchors;
  final List<AssetMarkdownLink> links;
  final AssetOverviewSummary overview;
  final List<AssetContentLineBrief> contentLines;
  final AssetSyncStatus syncStatus;
  final bool stale;
  final bool retryable;
  final DateTime? latestUpdatedAt;
  final String? latestSyncTaskId;
}

enum EditableAssetType {
  contentLine,
  profileOverview,
  lifeEvent,
  viewpoint,
  expression,
  synonym,
}

final class AssetSourceReference {
  const AssetSourceReference({
    required this.sourceType,
    this.sourceId,
    this.title,
  });

  final String sourceType;
  final String? sourceId;
  final String? title;
}

final class StructuredAssetDetail {
  const StructuredAssetDetail({
    required this.assetType,
    required this.assetId,
    required this.asset,
    required this.editable,
    required this.baseVersion,
    required this.sourceReferences,
    required this.updatedAt,
  });

  final EditableAssetType assetType;
  final String assetId;
  final Map<String, Object?> asset;
  final bool editable;
  final int baseVersion;
  final List<AssetSourceReference> sourceReferences;
  final DateTime updatedAt;
}

/// A server-approved, structured asset update. Callers cannot use this type to
/// replace a rendered Markdown document or submit arbitrary asset fields.
final class EditableAssetPatch {
  const EditableAssetPatch({required this.assetType, required this.fields});

  final EditableAssetType assetType;
  final Map<String, Object?> fields;
}

final class AssetPatchResult {
  const AssetPatchResult({
    required this.assetType,
    required this.assetId,
    required this.newVersion,
    required this.asset,
  });

  final EditableAssetType assetType;
  final String assetId;
  final int newVersion;
  final Map<String, Object?> asset;
}

final class AssetSyncTask {
  const AssetSyncTask({required this.taskId, required this.status});

  final String taskId;
  final String status;
}

abstract interface class AssetApiPort {
  Future<ApiResult<PersonalAssetMarkdown>> getMarkdown({
    AssetMarkdownFocus? focus,
  });

  Future<ApiResult<StructuredAssetDetail>> getAssetDetail({
    required EditableAssetType assetType,
    required String assetId,
  });

  Future<ApiResult<AssetPatchResult>> patchAsset({
    required EditableAssetType assetType,
    required String assetId,
    required int baseVersion,
    required EditableAssetPatch patch,
    required IdempotencyRequestContext idempotency,
    SubmissionKeyStore idempotencyStore,
  });

  Future<ApiResult<AssetSyncTask>> syncAssets({
    required IdempotencyRequestContext idempotency,
    SubmissionKeyStore idempotencyStore,
  });
}

/// Builds a patch from the editable-field allowlist used by the backend.
/// Empty and unsafe values are discarded; a null result must not be submitted.
EditableAssetPatch? buildEditableAssetPatch(
  EditableAssetType assetType,
  Map<String, Object?> values,
) {
  final fields = <String, Object?>{};
  for (final key in _editableAssetFields[assetType]!) {
    final value = _normalizeEditableAssetField(key, values[key]);
    if (value != null) fields[key] = value;
  }
  if (fields.isEmpty) return null;
  return EditableAssetPatch(
    assetType: assetType,
    fields: Map<String, Object?>.unmodifiable(fields),
  );
}

List<String> editableAssetFieldKeys(EditableAssetType assetType) =>
    List<String>.unmodifiable(_editableAssetFields[assetType]!);

bool isEditableAssetPatchValid(EditableAssetPatch patch) {
  if (patch.fields.isEmpty) return false;
  final allowed = _editableAssetFields[patch.assetType]!;
  for (final entry in patch.fields.entries) {
    if (!allowed.contains(entry.key)) return false;
    final normalized = _normalizeEditableAssetField(entry.key, entry.value);
    if (normalized == null ||
        !_sameEditableAssetField(normalized, entry.value)) {
      return false;
    }
  }
  return true;
}

const _editableAssetFields = <EditableAssetType, List<String>>{
  EditableAssetType.contentLine: <String>[
    'name',
    'industry',
    'positioning',
    'targetAudience',
    'accountGoal',
    'tags',
    'status',
  ],
  EditableAssetType.profileOverview: <String>[
    'displayName',
    'identitySummary',
    'personalitySummary',
    'contentStyleSummary',
    'keyTags',
  ],
  EditableAssetType.lifeEvent: <String>[
    'eventTime',
    'displayTitle',
    'fullTitle',
    'summary',
    'content',
    'contentLineId',
    'importance',
    'tags',
    'visibility',
  ],
  EditableAssetType.viewpoint: <String>[
    'title',
    'content',
    'contentLineId',
    'importance',
    'tags',
    'visibility',
  ],
  EditableAssetType.expression: <String>[
    'text',
    'usageContext',
    'tags',
    'visibility',
  ],
  EditableAssetType.synonym: <String>[
    'canonical',
    'variants',
    'usageContext',
    'visibility',
  ],
};

const _editableListFields = <String>{'tags', 'keyTags', 'variants'};

Object? _normalizeEditableAssetField(String key, Object? value) {
  if (_editableListFields.contains(key)) {
    final values = switch (value) {
      String text => text.split(RegExp(r'[,，\n]')),
      List<Object?> items => items.whereType<String>(),
      _ => const <String>[],
    };
    final normalized = <String>[];
    for (final item in values) {
      final text = _safeEditableText(item, maximum: 240);
      if (text != null && !normalized.contains(text)) normalized.add(text);
      if (normalized.length == 20) break;
    }
    return normalized.isEmpty ? null : List<String>.unmodifiable(normalized);
  }
  return _safeEditableText(value, maximum: 2000);
}

bool _sameEditableAssetField(Object normalized, Object? original) {
  if (normalized is String && original is String) return normalized == original;
  if (normalized is List<String> && original is List) {
    return normalized.length == original.length &&
        normalized.asMap().entries.every(
          (entry) => original[entry.key] == entry.value,
        );
  }
  return false;
}

String? _safeEditableText(Object? value, {required int maximum}) {
  final text = value is String ? value.trim() : null;
  if (text == null || text.isEmpty || text.length > maximum) return null;
  return _unsafeEditableText.any((pattern) => pattern.hasMatch(text))
      ? null
      : text;
}

final _unsafeEditableText = <RegExp>[
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
