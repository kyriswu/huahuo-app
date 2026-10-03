import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/creation_canvas_history.dart';

// resident-provider: Preserves one replaceable history store across Canvas routes.
final creationCanvasHistoryPortProvider = Provider<CreationCanvasHistoryPort>(
  (ref) => InMemoryCreationCanvasHistoryPort(),
);

abstract interface class CreationCanvasHistoryPort {
  List<CreationCanvasHistoryEntry> list(String userScope);

  CreationCanvasHistoryEntry? find(String userScope, String historyId);

  Future<void> upsert(String userScope, CreationCanvasHistoryEntry entry);

  bool delete(String userScope, String historyId);
}

final class InMemoryCreationCanvasHistoryPort
    implements CreationCanvasHistoryPort {
  final Map<String, Map<String, CreationCanvasHistoryEntry>> _entries = {};

  @override
  List<CreationCanvasHistoryEntry> list(String userScope) {
    final scope = _scope(userScope);
    final result =
        _entries[scope]?.values.toList(growable: false) ??
        const <CreationCanvasHistoryEntry>[];
    if (result.length > 1) {
      result.sort((left, right) => right.updatedAt.compareTo(left.updatedAt));
    }
    return List<CreationCanvasHistoryEntry>.unmodifiable(result);
  }

  @override
  CreationCanvasHistoryEntry? find(String userScope, String historyId) {
    return _entries[_scope(userScope)]?[_id(historyId)];
  }

  @override
  Future<void> upsert(String userScope, CreationCanvasHistoryEntry entry) {
    final scope = _scope(userScope);
    final existing = _entries[scope]?[entry.id];
    if (existing != null && entry.updatedAt.isBefore(existing.updatedAt)) {
      return Future<void>.value();
    }
    (_entries[scope] ??= <String, CreationCanvasHistoryEntry>{})[entry.id] =
        entry;
    return Future<void>.value();
  }

  @override
  bool delete(String userScope, String historyId) {
    final scope = _scope(userScope);
    final removed = _entries[scope]?.remove(_id(historyId)) != null;
    if (_entries[scope]?.isEmpty ?? false) _entries.remove(scope);
    return removed;
  }
}

String _scope(String value) {
  final normalized = value.trim();
  if (normalized.isEmpty) {
    throw ArgumentError.value(value, 'userScope', 'must not be empty');
  }
  return normalized;
}

String _id(String value) {
  final normalized = value.trim();
  if (normalized.isEmpty) {
    throw ArgumentError.value(value, 'historyId', 'must not be empty');
  }
  return normalized;
}
