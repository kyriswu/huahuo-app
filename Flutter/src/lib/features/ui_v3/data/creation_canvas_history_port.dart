import 'dart:convert';

import '../../../core/database/creation_canvas_history_dao.dart';
import '../application/creation_canvas_history_port.dart';
import '../domain/creation_canvas_history.dart';
import '../domain/feed_item_models.dart';

export '../application/creation_canvas_history_port.dart'
    show
        CreationCanvasHistoryPort,
        InMemoryCreationCanvasHistoryPort,
        creationCanvasHistoryPortProvider;

final class DatabaseCreationCanvasHistoryPort
    implements CreationCanvasHistoryPort {
  DatabaseCreationCanvasHistoryPort(this._dao);

  final CreationCanvasHistoryDao _dao;

  @override
  List<CreationCanvasHistoryEntry> list(String userScope) {
    final entries = <CreationCanvasHistoryEntry>[
      for (final record in _dao.list(_scope(userScope)))
        if (_entryFromRecord(record) case final entry?) entry,
    ]..sort((left, right) => right.updatedAt.compareTo(left.updatedAt));
    return List<CreationCanvasHistoryEntry>.unmodifiable(entries);
  }

  @override
  CreationCanvasHistoryEntry? find(String userScope, String historyId) {
    final record = _dao.find(_scope(userScope), _id(historyId));
    return record == null ? null : _entryFromRecord(record);
  }

  @override
  Future<void> upsert(
    String userScope,
    CreationCanvasHistoryEntry entry,
  ) async {
    _dao.upsert(
      userScope: _scope(userScope),
      historyId: entry.id,
      noteId: entry.noteId,
      title: entry.title,
      markdown: entry.markdown,
      documentJson: entry.documentJson,
      documentFormatVersion: entry.documentFormatVersion,
      revision: entry.revision,
      linkedMaterialsJson: jsonEncode(<Map<String, Object?>>[
        for (final material in entry.linkedMaterials)
          <String, Object?>{
            'id': material.id,
            'source': material.source.name,
            'title': material.title,
            'summary': material.summary,
          },
      ]),
      sourceTopicId: entry.sourceTopicId,
      sourceTitle: entry.sourceTitle,
      createdAt: entry.createdAt.toUtc().toIso8601String(),
      updatedAt: entry.updatedAt.toUtc().toIso8601String(),
    );
    await _dao.flushPersistence();
  }

  @override
  bool delete(String userScope, String historyId) {
    return _dao.delete(_scope(userScope), _id(historyId));
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

CreationCanvasHistoryEntry? _entryFromRecord(Map<String, Object?> record) {
  try {
    final id = _recordString(record['history_id']);
    final noteId = _recordString(record['note_id']);
    final title = _recordString(record['title']);
    final documentJson = _recordString(record['document_json']);
    final documentFormatVersion = _recordInt(record['document_format_version']);
    final revision = _recordInt(record['revision']) ?? 0;
    final createdAt = _recordDate(record['created_at']);
    final updatedAt = _recordDate(record['updated_at']);
    if (id == null ||
        noteId == null ||
        title == null ||
        documentJson == null ||
        documentFormatVersion == null ||
        createdAt == null ||
        updatedAt == null) {
      return null;
    }
    return CreationCanvasHistoryEntry(
      id: id,
      noteId: noteId,
      title: title,
      markdown: '${record['markdown'] ?? ''}',
      documentJson: documentJson,
      documentFormatVersion: documentFormatVersion,
      revision: revision,
      linkedMaterials: _linkedMaterials(record['linked_materials_json']),
      sourceTopicId: _recordString(record['source_topic_id']),
      sourceTitle: _recordString(record['source_title']),
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  } catch (_) {
    return null;
  }
}

List<V3LinkedMaterialRef> _linkedMaterials(Object? raw) {
  if (raw is! String || raw.trim().isEmpty) return const [];
  final decoded = jsonDecode(raw);
  if (decoded is! List) return const [];
  final result = <V3LinkedMaterialRef>[];
  for (final item in decoded) {
    if (item is! Map) continue;
    final id = _recordString(item['id']);
    final title = _recordString(item['title']);
    final sourceName = _recordString(item['source']);
    if (id == null || title == null || sourceName == null) continue;
    V3MaterialSource? source;
    for (final candidate in V3MaterialSource.values) {
      if (candidate.name == sourceName) source = candidate;
    }
    if (source == null) continue;
    result.add(
      V3LinkedMaterialRef(
        id: id,
        source: source,
        title: title,
        summary: _recordString(item['summary']),
      ),
    );
  }
  return List<V3LinkedMaterialRef>.unmodifiable(result);
}

String? _recordString(Object? value) {
  final normalized = '${value ?? ''}'.trim();
  return normalized.isEmpty ? null : normalized;
}

int? _recordInt(Object? value) =>
    value is int ? value : int.tryParse('${value ?? ''}');

DateTime? _recordDate(Object? value) =>
    DateTime.tryParse('${value ?? ''}')?.toUtc();
