import 'dart:ui';

import '../domain/feed_item_models.dart';
import '../domain/graph_snapshot.dart';
import '../domain/ui_v3_models.dart';

final class GraphSnapshotMapper {
  const GraphSnapshotMapper();

  GraphSnapshot? fromJson(Object? value, {String? fallbackGraphId}) {
    final outer = _asStringMap(value);
    if (outer == null) return null;
    final object = _asStringMap(outer['graph']) ?? outer;
    final graphId = _safeId(
      _read(object, 'graph_id', 'graphId', 'id') ?? fallbackGraphId,
    );
    final rawNodes = _asList(_read(object, 'nodes', 'entities'));
    final rawEdges = _asList(
      _read(object, 'edges', 'relationships', 'relations'),
    );
    if (graphId == null || rawNodes == null || rawEdges == null) return null;

    final nodes = <V3GraphNode>[];
    final nodeIds = <String>{};
    for (final rawNode in rawNodes.take(_maximumNodes)) {
      final node = _nodeFromJson(rawNode);
      if (node != null && nodeIds.add(node.id)) nodes.add(node);
    }

    final edges = <V3GraphEdge>[];
    final edgeIds = <String>{};
    for (final rawEdge in rawEdges.take(_maximumEdges)) {
      final edge = _edgeFromJson(rawEdge);
      if (edge == null ||
          !nodeIds.contains(edge.sourceId) ||
          !nodeIds.contains(edge.targetId) ||
          !edgeIds.add(edge.id)) {
        continue;
      }
      edges.add(edge);
    }

    return GraphSnapshot(
      graphId: graphId,
      nodes: nodes,
      edges: edges,
      revision: _safeRevision(_read(object, 'revision')),
      updatedAt:
          _safeDate(_read(object, 'updated_at', 'updatedAt')) ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    );
  }

  V3GraphNode? _nodeFromJson(Object? value) {
    final object = _asStringMap(value);
    if (object == null) return null;
    final id = _safeId(_read(object, 'id', 'uuid'));
    final label = _safeText(
      _read(object, 'label', 'name', 'title'),
      maximum: 240,
    );
    if (id == null || label == null) return null;
    final entityType = canonicalGraphEntityType(
      _safeText(
            _read(object, 'entity_type', 'entityType', 'type'),
            maximum: 80,
          ) ??
          'Entity',
    );
    final positionObject = _asStringMap(object['position']);
    final x = _safeDouble(positionObject?['x'] ?? object['x']);
    final y = _safeDouble(positionObject?['y'] ?? object['y']);
    final seededPosition = _seedPosition(id);
    final source = _materialSource(
      _read(object, 'source', 'material_source', 'materialSource'),
    );
    final updatedAt = _safeDate(_read(object, 'updated_at', 'updatedAt'));
    return V3GraphNode(
      id: id,
      label: label,
      cluster: _cluster(
        _read(object, 'cluster', 'community'),
        entityType: entityType,
      ),
      position: Offset(x ?? seededPosition.dx, y ?? seededPosition.dy),
      summary:
          _safeText(
            _read(object, 'summary', 'description'),
            maximum: 4000,
            allowEmpty: true,
          ) ??
          '',
      entityType: entityType,
      attributes: _safeMetadata(object['attributes']),
      labels: _safeStringList(object['labels'], maximumItems: 32),
      contentId: _safeId(_read(object, 'content_id', 'contentId')),
      weight: _safeWeight(object['weight']),
      center: _safeBool(object['center']) ?? false,
      source: source ?? V3MaterialSource.note,
      materialSourceProvided: source != null,
      updatedAt: updatedAt,
      topics: _safeStringList(object['topics'], maximumItems: 32),
      isHotspot:
          _safeBool(_read(object, 'is_hotspot', 'isHotspot')) ??
          source == V3MaterialSource.hotspot,
      isAggregated:
          _safeBool(_read(object, 'is_aggregated', 'isAggregated')) ?? false,
      isRecent: _safeBool(_read(object, 'is_recent', 'isRecent')) ?? false,
    );
  }

  V3GraphEdge? _edgeFromJson(Object? value) {
    final object = _asStringMap(value);
    if (object == null) return null;
    final id = _safeId(_read(object, 'id', 'uuid'));
    final sourceId = _safeId(_read(object, 'source_id', 'sourceId', 'source'));
    final targetId = _safeId(_read(object, 'target_id', 'targetId', 'target'));
    if (id == null || sourceId == null || targetId == null) return null;
    final rawKind = _read(object, 'kind', 'type', 'fact_type', 'factType');
    final kind = graphRelationKindFromWire(rawKind);
    return V3GraphEdge(
      id: id,
      sourceId: sourceId,
      targetId: targetId,
      kind: kind,
      label:
          _safeText(_read(object, 'label', 'name'), maximum: 160) ?? kind.label,
      relationType: _safeText(rawKind, maximum: 80),
      fact: _safeText(object['fact'], maximum: 4000, allowEmpty: true),
      attributes: _safeMetadata(object['attributes']),
      episodes: _safeStringList(object['episodes'], maximumItems: 100),
      weight: _safeWeight(object['weight']),
      directed: _safeBool(object['directed']) ?? false,
      createdAt: _safeDate(_read(object, 'created_at', 'createdAt')),
      validAt: _safeDate(_read(object, 'valid_at', 'validAt')),
    );
  }
}

V3GraphRelationKind graphRelationKindFromWire(Object? value) {
  final normalized = value is String
      ? value.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '')
      : '';
  return switch (normalized) {
    'membership' || 'belongs' || 'belongsto' => V3GraphRelationKind.membership,
    'communityaffinity' ||
    'semanticassociation' ||
    'affinity' => V3GraphRelationKind.communityAffinity,
    'linkedmaterial' ||
    'reference' ||
    'references' ||
    'citation' => V3GraphRelationKind.linkedMaterial,
    'sharedtopic' || 'topic' => V3GraphRelationKind.sharedTopic,
    'sharedcontentline' ||
    'contentline' => V3GraphRelationKind.sharedContentLine,
    _ => V3GraphRelationKind.other,
  };
}

String stableGraphToken(String input) {
  var hash = 0x811c9dc5;
  for (final unit in input.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}

const _maximumNodes = 10000;
const _maximumEdges = 50000;

Object? _read(
  Map<String, Object?> object,
  String first, [
  String? second,
  String? third,
  String? fourth,
]) {
  if (object.containsKey(first)) return object[first];
  if (second != null && object.containsKey(second)) return object[second];
  if (third != null && object.containsKey(third)) return object[third];
  if (fourth != null && object.containsKey(fourth)) return object[fourth];
  return null;
}

Map<String, Object?>? _asStringMap(Object? value) {
  if (value is! Map) return null;
  final result = <String, Object?>{};
  for (final entry in value.entries) {
    if (entry.key is! String) return null;
    result[entry.key as String] = entry.value;
  }
  return result;
}

List<Object?>? _asList(Object? value) =>
    value is List ? List<Object?>.of(value, growable: false) : null;

String? _safeId(Object? value) {
  final text = value is String ? value.trim() : null;
  if (text == null || text.isEmpty || text.length > 256) return null;
  if (RegExp(r'[\x00-\x1f\x7f]').hasMatch(text)) return null;
  return text;
}

String? _safeText(
  Object? value, {
  required int maximum,
  bool allowEmpty = false,
}) {
  final text = value is String ? value.trim() : null;
  if (text == null || text.length > maximum) return null;
  if (!allowEmpty && text.isEmpty) return null;
  if (RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]').hasMatch(text)) {
    return null;
  }
  return text;
}

DateTime? _safeDate(Object? value) {
  final text = value is String ? value.trim() : null;
  if (text == null || text.length > 64) return null;
  return DateTime.tryParse(text)?.toUtc();
}

double? _safeDouble(Object? value) {
  final number = value is num ? value.toDouble() : null;
  return number != null && number.isFinite ? number : null;
}

double _safeWeight(Object? value) =>
    (_safeDouble(value) ?? 1).clamp(.01, 10).toDouble();

int _safeRevision(Object? value) {
  final revision = value is int ? value : null;
  return revision != null && revision >= 0 ? revision : 0;
}

bool? _safeBool(Object? value) => switch (value) {
  bool flag => flag,
  0 => false,
  1 => true,
  'false' => false,
  'true' => true,
  _ => null,
};

List<String> _safeStringList(Object? value, {required int maximumItems}) {
  final raw = value is List ? value : const <Object?>[];
  final result = <String>[];
  final seen = <String>{};
  for (final item in raw.take(maximumItems)) {
    final text = _safeText(item, maximum: 160);
    if (text != null && seen.add(text)) result.add(text);
  }
  return List<String>.unmodifiable(result);
}

Map<String, Object?> _safeMetadata(Object? value) {
  final raw = _asStringMap(value);
  if (raw == null) return const <String, Object?>{};
  final result = <String, Object?>{};
  for (final entry in raw.entries.take(64)) {
    final key = _safeText(entry.key, maximum: 80);
    final safeValue = _safeJsonValue(entry.value, depth: 0);
    if (key != null && safeValue.accepted) result[key] = safeValue.value;
  }
  return Map<String, Object?>.unmodifiable(result);
}

({bool accepted, Object? value}) _safeJsonValue(
  Object? value, {
  required int depth,
}) {
  if (value == null || value is bool || value is String) {
    if (value is String && value.length > 2000) {
      return (accepted: false, value: null);
    }
    return (accepted: true, value: value);
  }
  if (value is num && value.isFinite) return (accepted: true, value: value);
  if (depth >= 3) return (accepted: false, value: null);
  if (value is List) {
    final result = <Object?>[];
    for (final item in value.take(64)) {
      final safe = _safeJsonValue(item, depth: depth + 1);
      if (safe.accepted) result.add(safe.value);
    }
    return (accepted: true, value: List<Object?>.unmodifiable(result));
  }
  final map = _asStringMap(value);
  if (map == null) return (accepted: false, value: null);
  final result = <String, Object?>{};
  for (final entry in map.entries.take(64)) {
    final key = _safeText(entry.key, maximum: 80);
    final safe = _safeJsonValue(entry.value, depth: depth + 1);
    if (key != null && safe.accepted) result[key] = safe.value;
  }
  return (accepted: true, value: Map<String, Object?>.unmodifiable(result));
}

Offset _seedPosition(String id) {
  final token = int.parse(stableGraphToken(id), radix: 16);
  return Offset(
    80 + (token % 740).toDouble(),
    90 + ((token ~/ 31) % 680).toDouble(),
  );
}

V3GraphCluster _cluster(Object? value, {required String entityType}) {
  return _clusterForEntityType(value) ??
      _clusterForEntityType(entityType) ??
      V3GraphCluster.viewpoint;
}

V3GraphCluster? _clusterForEntityType(Object? value) {
  if (value is! String || value.trim().isEmpty) return null;
  return switch (canonicalGraphEntityType(value)) {
    'Method' || '方法' => V3GraphCluster.method,
    'Inspiration' || '灵感' => V3GraphCluster.inspiration,
    'Case' ||
    'Project' ||
    'Product' ||
    '案例' ||
    '项目' ||
    '产品' => V3GraphCluster.caseItem,
    'Industry' ||
    'Person' ||
    'Organization' ||
    '行业' ||
    '人物' ||
    '组织' => V3GraphCluster.industry,
    'Trend' || 'Topic' || '趋势' || '主题' => V3GraphCluster.trend,
    'Viewpoint' || '观点' => V3GraphCluster.viewpoint,
    _ => null,
  };
}

V3MaterialSource? _materialSource(Object? value) {
  final normalized = value is String
      ? value.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '')
      : '';
  for (final source in V3MaterialSource.values) {
    final name = source.name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    if (name == normalized) return source;
  }
  return null;
}
