import '../domain/graph_snapshot.dart';
import 'graph_snapshot_mapper.dart';

final class MiroFishGraphMapper {
  const MiroFishGraphMapper({
    this.snapshotMapper = const GraphSnapshotMapper(),
  });

  final GraphSnapshotMapper snapshotMapper;

  GraphSnapshot? fromContentNavigation(
    Object? value, {
    required String workspaceId,
  }) {
    final object = _asMap(value);
    final items = _asList(object?['items']);
    final map = object?['map'];
    final cursor = object?['contentCursor'];
    if (object == null ||
        items == null ||
        map != 'overview' ||
        cursor is! String) {
      return null;
    }
    final nodes = <Object?>[];
    final nodeIdByPath = <String, String>{};
    for (final raw in items) {
      final item = _asMap(raw);
      final owner = _asMap(item?['ownerRef']);
      final kind = _safeNavigationText(owner?['kind']);
      final ownerId = _safeNavigationText(owner?['id']);
      final path = _safeLogicalPath(item?['path']);
      final title = _safeNavigationText(item?['title']) ?? _pathTitle(path);
      final revisionId = _safeNavigationText(item?['revisionId']);
      final version = item?['version'];
      if (kind == null ||
          ownerId == null ||
          path == null ||
          title == null ||
          (revisionId == null && version is! int) ||
          (revisionId != null && version != null)) {
        return null;
      }
      final nodeId = '$kind:$ownerId';
      if (nodeIdByPath.containsKey(path)) return null;
      nodeIdByPath[path] = nodeId;
      nodes.add(<String, Object?>{
        'id': nodeId,
        'label': title,
        'entity_type': kind,
        'summary': path,
        'content_id': ownerId,
        'attributes': <String, Object?>{
          'logicalPath': path,
          if (revisionId != null) 'revisionId': revisionId,
          if (version is int) 'version': version,
        },
      });
    }
    final edges = <Object?>[];
    for (final entry in nodeIdByPath.entries) {
      final parentPath = _parentLogicalPath(entry.key);
      final parentId = parentPath == null ? null : nodeIdByPath[parentPath];
      if (parentId == null || parentId == entry.value) continue;
      edges.add(<String, Object?>{
        'id': 'navigation-${stableGraphToken('$parentId\u0000${entry.value}')}',
        'source_id': parentId,
        'target_id': entry.value,
        'kind': 'membership',
        'label': '包含',
        'directed': true,
      });
    }
    return snapshotMapper.fromJson(<String, Object?>{
      'graph_id': 'workspace:$workspaceId:$map',
      'revision': int.tryParse(cursor) ?? 0,
      'updated_at': DateTime.fromMillisecondsSinceEpoch(
        0,
        isUtc: true,
      ).toIso8601String(),
      'nodes': nodes,
      'edges': edges,
    }, fallbackGraphId: 'workspace:$workspaceId:$map');
  }

  GraphSnapshot? fromJson(Object? value, {String? fallbackGraphId}) {
    final outer = _asMap(value);
    if (outer == null) return null;
    final graph = _asMap(outer['graph']) ?? outer;
    if (!_usesMiroFishFields(graph)) {
      return snapshotMapper.fromJson(value, fallbackGraphId: fallbackGraphId);
    }
    final rawNodes = _asList(graph['entities'] ?? graph['nodes']);
    final rawEdges = _asList(
      graph['facts'] ?? graph['relationships'] ?? graph['edges'],
    );
    if (rawNodes == null || rawEdges == null) return null;

    final nodes = <Object?>[];
    for (final value in rawNodes) {
      final node = _asMap(value);
      if (node == null) continue;
      final labels = _stringList(node['labels']);
      nodes.add(<String, Object?>{
        'id': node['uuid'] ?? node['id'],
        'label': node['name'] ?? node['label'],
        'entity_type':
            node['entity_type'] ??
            node['entityType'] ??
            (labels.isEmpty ? 'Entity' : labels.first),
        'summary': node['summary'] ?? node['description'] ?? '',
        'labels': labels,
        'attributes': node['attributes'] ?? const <String, Object?>{},
        'position': node['position'],
        'x': node['x'],
        'y': node['y'],
        'content_id': node['content_id'] ?? node['contentId'],
        'cluster': node['cluster'],
        'weight': node['weight'],
        'updated_at': node['updated_at'] ?? node['updatedAt'],
      });
    }

    final edges = <Object?>[];
    for (final value in rawEdges) {
      final edge = _asMap(value);
      if (edge == null) continue;
      final source =
          edge['source_node_uuid'] ??
          edge['sourceNodeUuid'] ??
          edge['source_id'] ??
          edge['sourceId'];
      final target =
          edge['target_node_uuid'] ??
          edge['targetNodeUuid'] ??
          edge['target_id'] ??
          edge['targetId'];
      final type = edge['fact_type'] ?? edge['factType'] ?? edge['kind'];
      final label = edge['name'] ?? edge['label'] ?? type;
      final suppliedId = edge['uuid'] ?? edge['id'];
      final derivedId = source is String && target is String
          ? 'edge-${stableGraphToken('$source\u0000$target\u0000$type\u0000${edge['fact']}')}'
          : null;
      edges.add(<String, Object?>{
        'id': suppliedId ?? derivedId,
        'source_id': source,
        'target_id': target,
        'kind': type,
        'label': label,
        'fact': edge['fact'],
        'attributes': edge['attributes'] ?? const <String, Object?>{},
        'episodes': edge['episodes'] ?? const <Object?>[],
        'weight': edge['weight'],
        'directed': edge['directed'] ?? true,
        'created_at': edge['created_at'] ?? edge['createdAt'],
        'valid_at': edge['valid_at'] ?? edge['validAt'],
      });
    }

    return snapshotMapper.fromJson(<String, Object?>{
      'graph_id':
          graph['graph_id'] ??
          graph['graphId'] ??
          graph['graph_uuid'] ??
          graph['uuid'] ??
          graph['id'] ??
          fallbackGraphId,
      'revision': graph['revision'] ?? 0,
      'updated_at':
          graph['updated_at'] ??
          graph['updatedAt'] ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true).toIso8601String(),
      'nodes': nodes,
      'edges': edges,
    }, fallbackGraphId: fallbackGraphId);
  }
}

bool _usesMiroFishFields(Map<String, Object?> graph) {
  if (graph.containsKey('entities') || graph.containsKey('facts')) return true;
  final edges = _asList(graph['relationships'] ?? graph['edges']);
  return edges?.any((value) {
        final edge = _asMap(value);
        return edge?.containsKey('source_node_uuid') == true ||
            edge?.containsKey('sourceNodeUuid') == true;
      }) ??
      false;
}

Map<String, Object?>? _asMap(Object? value) {
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

List<String> _stringList(Object? value) => value is List
    ? value
          .whereType<String>()
          .map((item) => item.trim())
          .where((item) => item.isNotEmpty)
          .toList()
    : value is String && value.trim().isNotEmpty
    ? <String>[value.trim()]
    : const <String>[];

String? _safeNavigationText(Object? value) {
  final text = value is String ? value.trim() : null;
  if (text == null || text.isEmpty || text.length > 512) return null;
  return RegExp(r'[\x00-\x1f\x7f]').hasMatch(text) ? null : text;
}

String? _safeLogicalPath(Object? value) {
  final path = _safeNavigationText(value);
  if (path == null ||
      path.startsWith('/') ||
      path.contains('\\') ||
      path.split('/').any((segment) => segment.isEmpty || segment == '..')) {
    return null;
  }
  return path;
}

String? _pathTitle(String? path) {
  if (path == null) return null;
  final segment = path.split('/').last.trim();
  return segment.isEmpty ? null : segment;
}

String? _parentLogicalPath(String path) {
  final separator = path.lastIndexOf('/');
  return separator <= 0 ? null : path.substring(0, separator);
}
