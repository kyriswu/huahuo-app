import '../api/api_client.dart';
import '../api/api_envelope.dart';
import '../api/idempotency.dart';

const _dailyTopicKind = 'daily_topic_report';
const _dailyTopicStatuses = <String>{'ready', 'dismissed', 'expired'};
const _dailyTopicPrimarySupplies = <String>{
  'information',
  'method',
  'viewpoint',
  'story',
};
const _dailyTopicPositioningModes = <String>{'applied', 'direct'};

enum DailyTopicSourceKind {
  dailyHotspot('daily_hotspot'),
  workspaceNote('workspace_note');

  const DailyTopicSourceKind(this.wireValue);

  final String wireValue;
}

sealed class DailyTopicSourceRef {
  const DailyTopicSourceRef({this.label});

  factory DailyTopicSourceRef.fromJson(Map<String, Object?> json) {
    final label = _optionalText(json, 'label', maxLength: 500);
    return switch (_requiredText(json, 'kind')) {
      'daily_hotspot' => _dailyHotspotSourceRef(json, label),
      'workspace_note' => _workspaceNoteSourceRef(json, label),
      _ => throw const FormatException('daily topic source kind is invalid'),
    };
  }

  final String? label;

  DailyTopicSourceKind get kind;
  String get sourceId;
  Map<String, Object?> toJson();
}

final class DailyTopicHotspotSourceRef extends DailyTopicSourceRef {
  const DailyTopicHotspotSourceRef({
    required this.hotspotId,
    this.sourceUrl,
    super.label,
  });

  final String hotspotId;
  final String? sourceUrl;

  @override
  DailyTopicSourceKind get kind => DailyTopicSourceKind.dailyHotspot;

  @override
  String get sourceId => hotspotId;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'kind': kind.wireValue,
    'hotspotId': hotspotId,
    if (sourceUrl != null) 'sourceUrl': sourceUrl,
    if (label != null) 'label': label,
  };
}

final class DailyTopicWorkspaceNoteSourceRef extends DailyTopicSourceRef {
  const DailyTopicWorkspaceNoteSourceRef({required this.noteId, super.label});

  final String noteId;

  @override
  DailyTopicSourceKind get kind => DailyTopicSourceKind.workspaceNote;

  @override
  String get sourceId => noteId;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'kind': kind.wireValue,
    'noteId': noteId,
    if (label != null) 'label': label,
  };
}

DailyTopicHotspotSourceRef _dailyHotspotSourceRef(
  Map<String, Object?> json,
  String? label,
) {
  if (json.containsKey('noteId')) {
    throw const FormatException('daily topic source identity is mixed');
  }
  return DailyTopicHotspotSourceRef(
    hotspotId: _requiredId(json, 'hotspotId'),
    sourceUrl: _optionalHttpUrl(json, 'sourceUrl'),
    label: label,
  );
}

DailyTopicWorkspaceNoteSourceRef _workspaceNoteSourceRef(
  Map<String, Object?> json,
  String? label,
) {
  if (json.containsKey('hotspotId') || json.containsKey('sourceUrl')) {
    throw const FormatException('daily topic source identity is mixed');
  }
  return DailyTopicWorkspaceNoteSourceRef(
    noteId: _requiredId(json, 'noteId'),
    label: label,
  );
}

final class DailyTopicItem {
  const DailyTopicItem({
    required this.topicId,
    required this.title,
    required this.briefMarkdown,
    required this.sourceRefs,
    this.primarySupply,
    this.positioningMode,
    this.audience,
    this.contentPromise,
    this.reasonMarkdown,
    this.writingSketchMarkdown,
  });

  factory DailyTopicItem.fromJson(Map<String, Object?> json) {
    final primarySupply = _optionalText(json, 'primarySupply');
    final positioningMode = _optionalText(json, 'positioningMode');
    if ((primarySupply != null &&
            !_dailyTopicPrimarySupplies.contains(primarySupply)) ||
        (positioningMode != null &&
            !_dailyTopicPositioningModes.contains(positioningMode))) {
      throw const FormatException('daily topic classification is invalid');
    }
    final rawSources = json['sourceRefs'];
    if (rawSources is! List || rawSources.isEmpty) {
      throw const FormatException('daily topic source refs are invalid');
    }
    final sources = <DailyTopicSourceRef>[];
    for (final raw in rawSources) {
      final object = asObjectMap(raw);
      if (object == null) {
        throw const FormatException('daily topic source ref is invalid');
      }
      sources.add(DailyTopicSourceRef.fromJson(object));
    }
    return DailyTopicItem(
      topicId: _requiredId(json, 'topicId'),
      title: _requiredText(json, 'title', maxLength: 500),
      briefMarkdown: _requiredText(json, 'briefMarkdown', maxLength: 32000),
      sourceRefs: List<DailyTopicSourceRef>.unmodifiable(sources),
      primarySupply: primarySupply,
      positioningMode: positioningMode,
      audience: _optionalText(json, 'audience', maxLength: 32000),
      contentPromise: _optionalText(json, 'contentPromise', maxLength: 32000),
      reasonMarkdown: _optionalText(json, 'reasonMarkdown', maxLength: 32000),
      writingSketchMarkdown: _optionalText(
        json,
        'writingSketchMarkdown',
        maxLength: 32000,
      ),
    );
  }

  final String topicId;
  final String title;
  final String briefMarkdown;
  final List<DailyTopicSourceRef> sourceRefs;
  final String? primarySupply;
  final String? positioningMode;
  final String? audience;
  final String? contentPromise;
  final String? reasonMarkdown;
  final String? writingSketchMarkdown;

  Map<String, Object?> toJson() => <String, Object?>{
    'topicId': topicId,
    'title': title,
    'briefMarkdown': briefMarkdown,
    if (primarySupply != null) 'primarySupply': primarySupply,
    if (positioningMode != null) 'positioningMode': positioningMode,
    if (audience != null) 'audience': audience,
    if (contentPromise != null) 'contentPromise': contentPromise,
    if (reasonMarkdown != null) 'reasonMarkdown': reasonMarkdown,
    if (writingSketchMarkdown != null)
      'writingSketchMarkdown': writingSketchMarkdown,
    'sourceRefs': <Object?>[for (final source in sourceRefs) source.toJson()],
  };
}

final class DailyTopicRecommendation {
  const DailyTopicRecommendation({
    required this.recommendationId,
    required this.workspaceId,
    required this.businessDate,
    required this.recommendationKind,
    required this.status,
    required this.title,
    required this.summaryMarkdown,
    required this.topics,
    required this.etag,
    this.generatedAt,
    this.readAt,
    this.dismissedAt,
    this.expiresAt,
  });

  factory DailyTopicRecommendation.fromJson(Map<String, Object?> json) {
    final kind = _requiredText(json, 'recommendationKind');
    final status = _requiredText(json, 'status');
    final businessDate = _requiredText(json, 'businessDate', maxLength: 10);
    if (kind != _dailyTopicKind ||
        !_dailyTopicStatuses.contains(status) ||
        !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(businessDate)) {
      throw const FormatException('daily topic recommendation is invalid');
    }
    final rawTopics = json['topics'];
    if (rawTopics is! List) {
      throw const FormatException('daily topic topics are invalid');
    }
    final topics = <DailyTopicItem>[];
    final seen = <String>{};
    for (final raw in rawTopics) {
      final object = asObjectMap(raw);
      if (object == null) {
        throw const FormatException('daily topic item is invalid');
      }
      final topic = DailyTopicItem.fromJson(object);
      if (!seen.add(topic.topicId)) {
        throw const FormatException('daily topic id is duplicated');
      }
      topics.add(topic);
    }
    return DailyTopicRecommendation(
      recommendationId: _requiredId(json, 'recommendationId'),
      workspaceId: _requiredId(json, 'workspaceId'),
      businessDate: businessDate,
      recommendationKind: kind,
      status: status,
      title: _requiredText(json, 'title', maxLength: 500),
      summaryMarkdown: _requiredText(json, 'summaryMarkdown', maxLength: 32000),
      topics: List<DailyTopicItem>.unmodifiable(topics),
      etag: _requiredText(json, 'etag', maxLength: 512),
      generatedAt: _optionalDate(json, 'generatedAt'),
      readAt: _optionalDate(json, 'readAt'),
      dismissedAt: _optionalDate(json, 'dismissedAt'),
      expiresAt: _optionalDate(json, 'expiresAt'),
    );
  }

  final String recommendationId;
  final String workspaceId;
  final String businessDate;
  final String recommendationKind;
  final String status;
  final String title;
  final String summaryMarkdown;
  final List<DailyTopicItem> topics;
  final String etag;
  final DateTime? generatedAt;
  final DateTime? readAt;
  final DateTime? dismissedAt;
  final DateTime? expiresAt;

  bool get isReady => status == 'ready';
}

final class DailyTopicRecommendationPage {
  const DailyTopicRecommendationPage({required this.items, this.nextCursor});

  factory DailyTopicRecommendationPage.fromJson(Map<String, Object?> json) {
    final rawItems = json['items'];
    if (rawItems is! List) {
      throw const FormatException('daily topic recommendation page is invalid');
    }
    final items = <DailyTopicRecommendation>[];
    for (final raw in rawItems) {
      final object = asObjectMap(raw);
      if (object == null) {
        throw const FormatException('daily topic recommendation is invalid');
      }
      items.add(DailyTopicRecommendation.fromJson(object));
    }
    final cursor = json['nextCursor'];
    if (cursor != null && (cursor is! String || cursor.length > 512)) {
      throw const FormatException(
        'daily topic recommendation cursor is invalid',
      );
    }
    return DailyTopicRecommendationPage(
      items: List<DailyTopicRecommendation>.unmodifiable(items),
      nextCursor: cursor as String?,
    );
  }

  final List<DailyTopicRecommendation> items;
  final String? nextCursor;
}

final class DailyTopicUseResult {
  const DailyTopicUseResult({
    required this.recommendationId,
    required this.threadId,
    this.topicId,
  });

  factory DailyTopicUseResult.fromJson(Map<String, Object?> json) {
    final threadId = _requiredId(json, 'threadId');
    final target = asObjectMap(json['navigationTarget']);
    if (target != null &&
        (target['type'] != 'work_ai_thread' ||
            target['threadId'] != threadId)) {
      throw const FormatException('daily topic navigation target is invalid');
    }
    return DailyTopicUseResult(
      recommendationId: _requiredId(json, 'recommendationId'),
      threadId: threadId,
      topicId: _optionalId(json, 'topicId'),
    );
  }

  final String recommendationId;
  final String threadId;
  final String? topicId;
}

/// Public App client for server-generated Workspace daily topic recommendations.
final class DailyTopicRecommendationClient {
  const DailyTopicRecommendationClient(this._api);

  final ApiClient _api;

  Future<ApiResult<DailyTopicRecommendationPage>> list(
    String workspaceId, {
    String status = 'ready',
    String? cursor,
    int limit = 100,
  }) {
    if (!_dailyTopicStatuses.contains(status) || limit < 1 || limit > 100) {
      throw ArgumentError.value(status, 'status', 'must be a public status');
    }
    return _api.request<DailyTopicRecommendationPage>(
      ApiRequestOptions<DailyTopicRecommendationPage>(
        endpointId: 'dailyTopicRecommendations',
        pathParams: <String, Object>{'workspaceId': _id(workspaceId)},
        query: <String, Object?>{
          'status': status,
          'limit': limit,
          if (cursor != null) 'cursor': _id(cursor),
        },
        parseData: (value) {
          final object = asObjectMap(value);
          return object == null
              ? null
              : DailyTopicRecommendationPage.fromJson(object);
        },
      ),
    );
  }

  Future<ApiResult<DailyTopicRecommendation>> get(
    String workspaceId,
    String recommendationId,
  ) => _api.request<DailyTopicRecommendation>(
    ApiRequestOptions<DailyTopicRecommendation>(
      endpointId: 'dailyTopicRecommendation',
      pathParams: <String, Object>{
        'workspaceId': _id(workspaceId),
        'recommendationId': _id(recommendationId),
      },
      parseData: (value) {
        final object = asObjectMap(value);
        return object == null
            ? null
            : DailyTopicRecommendation.fromJson(object);
      },
    ),
  );

  Future<ApiResult<DailyTopicRecommendation>> markRead(
    String workspaceId,
    String recommendationId, {
    required String etag,
    required String idempotencyKey,
  }) => _mutate(
    endpointId: 'readDailyTopicRecommendation',
    workspaceId: workspaceId,
    recommendationId: recommendationId,
    etag: etag,
    idempotencyKey: idempotencyKey,
  );

  Future<ApiResult<DailyTopicRecommendation>> dismiss(
    String workspaceId,
    String recommendationId, {
    required String etag,
    required String idempotencyKey,
  }) => _mutate(
    endpointId: 'dismissDailyTopicRecommendation',
    workspaceId: workspaceId,
    recommendationId: recommendationId,
    etag: etag,
    idempotencyKey: idempotencyKey,
  );

  Future<ApiResult<DailyTopicUseResult>> use(
    String workspaceId,
    String recommendationId, {
    String? topicId,
    required String idempotencyKey,
  }) => _api.request<DailyTopicUseResult>(
    ApiRequestOptions<DailyTopicUseResult>(
      endpointId: 'useDailyTopicRecommendation',
      pathParams: <String, Object>{
        'workspaceId': _id(workspaceId),
        'recommendationId': _id(recommendationId),
      },
      body: <String, Object?>{if (topicId != null) 'topicId': _id(topicId)},
      idempotency: IdempotencyRequestContext(explicitKey: idempotencyKey),
      parseData: (value) {
        final object = asObjectMap(value);
        return object == null ? null : DailyTopicUseResult.fromJson(object);
      },
    ),
  );

  Future<ApiResult<DailyTopicRecommendation>> _mutate({
    required String endpointId,
    required String workspaceId,
    required String recommendationId,
    required String etag,
    required String idempotencyKey,
  }) {
    final normalizedEtag = etag.trim();
    if (normalizedEtag.isEmpty || normalizedEtag.length > 512) {
      throw ArgumentError.value(etag, 'etag', 'must be a response ETag');
    }
    return _api.request<DailyTopicRecommendation>(
      ApiRequestOptions<DailyTopicRecommendation>(
        endpointId: endpointId,
        pathParams: <String, Object>{
          'workspaceId': _id(workspaceId),
          'recommendationId': _id(recommendationId),
        },
        headers: <String, String>{'If-Match': normalizedEtag},
        body: const <String, Object?>{},
        idempotency: IdempotencyRequestContext(explicitKey: idempotencyKey),
        parseData: (value) {
          final object = asObjectMap(value);
          final recommendation = object == null
              ? null
              : asObjectMap(object['recommendation']);
          return recommendation == null
              ? null
              : DailyTopicRecommendation.fromJson(recommendation);
        },
      ),
    );
  }
}

String _id(String value) {
  final normalized = value.trim();
  if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,255}$').hasMatch(normalized)) {
    throw ArgumentError.value(value, 'id', 'must be a public opaque id');
  }
  return normalized;
}

String _requiredId(Map<String, Object?> json, String key) =>
    _id(_requiredText(json, key));

String? _optionalId(Map<String, Object?> json, String key) {
  final value = _optionalText(json, key);
  return value == null ? null : _id(value);
}

String _requiredText(
  Map<String, Object?> json,
  String key, {
  int maxLength = 1024,
}) {
  final value = _optionalText(json, key, maxLength: maxLength);
  if (value == null) throw FormatException('$key is required');
  return value;
}

String? _optionalText(
  Map<String, Object?> json,
  String key, {
  int maxLength = 1024,
}) {
  final value = json[key];
  if (value == null) return null;
  if (value is! String) throw FormatException('$key must be text');
  final normalized = value.trim();
  if (normalized.isEmpty || normalized.length > maxLength) {
    throw FormatException('$key is invalid');
  }
  return normalized;
}

String? _optionalHttpUrl(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! String || value != value.trim() || value.length > 4096) {
    throw FormatException('$key is invalid');
  }
  final parsed = Uri.tryParse(value);
  if (parsed == null ||
      !parsed.hasAuthority ||
      (parsed.scheme != 'http' && parsed.scheme != 'https')) {
    throw FormatException('$key is invalid');
  }
  return value;
}

DateTime? _optionalDate(Map<String, Object?> json, String key) {
  final value = _optionalText(json, key, maxLength: 64);
  if (value == null) return null;
  final parsed = DateTime.tryParse(value);
  if (parsed == null) throw FormatException('$key is invalid');
  return parsed.toUtc();
}
