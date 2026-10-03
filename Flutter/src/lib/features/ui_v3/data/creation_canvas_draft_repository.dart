import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:huahuo_editor/huahuo_editor.dart';

import '../../../core/database/creation_canvas_draft_dao.dart';
import '../application/canvas_autosave_coordinator.dart';
import 'creation_canvas_document_adapter.dart';
import '../domain/creation_canvas_draft.dart';
import '../domain/feed_item_models.dart';
import '../domain/script_draft_models.dart';

final class CreationCanvasDraftRepository extends ChangeNotifier
    implements CreationCanvasDraftStore {
  factory CreationCanvasDraftRepository({
    required CreationCanvasDraftDao dao,
    required String userScope,
  }) {
    return CreationCanvasDraftRepository._(
      dao,
      _normalizeRequired(userScope, 'userScope'),
    );
  }

  CreationCanvasDraftRepository._(this._dao, this._userScope);

  final CreationCanvasDraftDao _dao;
  final String _userScope;
  bool _disposed = false;

  void _publishChange() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  @override
  String get userScope => _userScope;

  @override
  CreationCanvasDraft? load() {
    final record = _dao.load(_userScope);
    if (record == null) return null;
    final title = record['title'];
    final markdown = record['markdown'];
    final document = _recoverDocument(
      record['document_json'],
      record['document_format_version'],
    );
    final linkedMaterials = _decodeLinkedMaterials(
      record['linked_materials_json'],
    );
    final sharedMetadata = _decodeSharedMetadata(
      record['shared_metadata_json'],
    );
    final rawSourceTopicId = record['source_topic_id'];
    final rawSourceTitle = record['source_title'];
    final revision = record['revision'];
    final createdAt = DateTime.tryParse('${record['created_at'] ?? ''}');
    final updatedAt = DateTime.tryParse('${record['updated_at'] ?? ''}');
    if (title is! String ||
        markdown is! String ||
        revision is! int ||
        revision < 0 ||
        (rawSourceTopicId != null && rawSourceTopicId is! String) ||
        (rawSourceTitle != null && rawSourceTitle is! String) ||
        createdAt == null ||
        updatedAt == null ||
        updatedAt.isBefore(createdAt)) {
      return null;
    }
    return CreationCanvasDraft(
      title: title,
      markdown: markdown,
      documentJson: document.json,
      documentFormatVersion: document.version,
      unreadableStructuredDocument: document.unreadable,
      linkedMaterials: linkedMaterials,
      sourceTopicId: _optionalString(rawSourceTopicId),
      sourceTitle: _optionalString(rawSourceTitle),
      sessionId: sharedMetadata.sessionId,
      entryIdentity: sharedMetadata.entryIdentity,
      scriptDraftReceipt: sharedMetadata.scriptDraftReceipt,
      boundNoteId:
          sharedMetadata.boundNoteId ?? sharedMetadata.synchronizedNoteId,
      boundAssetFingerprint: sharedMetadata.boundAssetFingerprint,
      savedDraftCleanupPending: sharedMetadata.savedDraftCleanupPending,
      chatThreadId: sharedMetadata.chatThreadId,
      historyCommitReceipt: sharedMetadata.historyCommitReceipt,
      chatRewriteReceipts: sharedMetadata.chatRewriteReceipts,
      unreadableSessionMetadata: sharedMetadata.unreadable,
      synchronizedNoteId: sharedMetadata.synchronizedNoteId,
      summaryMarkdown: sharedMetadata.summaryMarkdown,
      sproutMarkdown: sharedMetadata.sproutMarkdown,
      aiAnnotations: sharedMetadata.aiAnnotations,
      revision: revision,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }

  @override
  void upsert(CreationCanvasDraft draft) {
    final prepared = _prepareDraft(draft);
    _dao.upsert(
      userScope: _userScope,
      title: draft.title,
      markdown: draft.markdown,
      documentJson: prepared.documentJson,
      documentFormatVersion: draft.documentFormatVersion,
      linkedMaterialsJson: prepared.linkedMaterialsJson,
      sharedMetadataJson: prepared.sharedMetadataJson,
      sourceTopicId: prepared.sourceTopicId,
      sourceTitle: prepared.sourceTitle,
      revision: draft.revision,
      createdAt: draft.createdAt.toUtc().toIso8601String(),
      updatedAt: draft.updatedAt.toUtc().toIso8601String(),
    );
    _publishChange();
  }

  @override
  Future<void> upsertDeferred(CreationCanvasDraft draft) async {
    final prepared = _prepareDraft(draft);
    await _dao.upsertDeferred(
      userScope: _userScope,
      title: draft.title,
      markdown: draft.markdown,
      documentJson: prepared.documentJson,
      documentFormatVersion: draft.documentFormatVersion,
      linkedMaterialsJson: prepared.linkedMaterialsJson,
      sharedMetadataJson: prepared.sharedMetadataJson,
      sourceTopicId: prepared.sourceTopicId,
      sourceTitle: prepared.sourceTitle,
      revision: draft.revision,
      createdAt: draft.createdAt.toUtc().toIso8601String(),
      updatedAt: draft.updatedAt.toUtc().toIso8601String(),
    );
    _publishChange();
  }

  ({
    String? documentJson,
    String linkedMaterialsJson,
    String? sharedMetadataJson,
    String? sourceTopicId,
    String? sourceTitle,
  })
  _prepareDraft(CreationCanvasDraft draft) {
    if (draft.revision < 0) {
      throw ArgumentError.value(
        draft.revision,
        'draft.revision',
        'must not be negative',
      );
    }
    if (draft.updatedAt.isBefore(draft.createdAt)) {
      throw ArgumentError.value(
        draft.updatedAt,
        'draft.updatedAt',
        'must not be before draft.createdAt',
      );
    }
    _validateSessionMetadataForWrite(draft);
    final documentJson = _validateDocumentForWrite(
      draft.documentJson,
      draft.documentFormatVersion,
    );
    final sharedSnapshot = CreationCanvasDocumentAdapter.snapshotFromDraft(
      id: 'mobile-draft',
      draft: draft,
    );
    if (documentJson != null && sharedSnapshot == null) {
      throw ArgumentError.value(
        draft.documentJson,
        'draft.documentJson',
        'must map to a readable shared document snapshot',
      );
    }
    return (
      documentJson: sharedSnapshot?.deltaJson ?? documentJson,
      linkedMaterialsJson: _encodeLinkedMaterials(draft.linkedMaterials),
      sharedMetadataJson: _encodeSharedMetadata(draft),
      sourceTopicId: _normalizeOptional(draft.sourceTopicId),
      sourceTitle: _normalizeOptional(draft.sourceTitle),
    );
  }

  @override
  bool clear() {
    final cleared = _dao.clear(_userScope);
    if (cleared) _publishChange();
    return cleared;
  }

  @override
  Future<bool> clearDeferred() async {
    final cleared = await _dao.clearDeferred(_userScope);
    if (cleared) _publishChange();
    return cleared;
  }
}

String? _encodeSharedMetadata(CreationCanvasDraft draft) {
  if (draft.summaryMarkdown == null &&
      draft.sproutMarkdown == null &&
      draft.sessionId == null &&
      draft.entryIdentity == null &&
      draft.scriptDraftReceipt == null &&
      draft.boundNoteId == null &&
      draft.boundAssetFingerprint == null &&
      !draft.savedDraftCleanupPending &&
      draft.chatThreadId == null &&
      draft.historyCommitReceipt == null &&
      draft.chatRewriteReceipts.isEmpty &&
      draft.synchronizedNoteId == null &&
      draft.aiAnnotations.isEmpty) {
    return null;
  }
  return jsonEncode(<String, Object?>{
    'formatVersion': 5,
    'summaryMarkdown': draft.summaryMarkdown,
    'sproutMarkdown': draft.sproutMarkdown,
    'sessionId': _normalizeOptional(draft.sessionId),
    'entryIdentity': _normalizeOptional(draft.entryIdentity),
    if (draft.scriptDraftReceipt != null)
      'scriptDraftReceipt': draft.scriptDraftReceipt!.toJson(),
    'boundNoteId': _normalizeOptional(draft.boundNoteId),
    'boundAssetFingerprint': _normalizeOptional(draft.boundAssetFingerprint),
    if (draft.savedDraftCleanupPending) 'savedDraftCleanupPending': true,
    'chatThreadId': _normalizeOptional(draft.chatThreadId),
    if (draft.historyCommitReceipt != null)
      'historyCommitReceipt': draft.historyCommitReceipt!.toJson(),
    if (draft.chatRewriteReceipts.isNotEmpty)
      'chatRewriteReceipts': <Map<String, Object?>>[
        for (final receipt in _boundedChatReceipts(draft.chatRewriteReceipts))
          receipt.toJson(),
      ],
    'aiAnnotations': draft.aiAnnotations
        .map((annotation) => annotation.toJson())
        .toList(growable: false),
  });
}

({
  String? summaryMarkdown,
  String? sproutMarkdown,
  String? sessionId,
  String? entryIdentity,
  ScriptDraftGenerationReceipt? scriptDraftReceipt,
  String? boundNoteId,
  String? boundAssetFingerprint,
  bool savedDraftCleanupPending,
  String? chatThreadId,
  CreationCanvasHistoryCommitReceipt? historyCommitReceipt,
  List<CreationCanvasChatRewriteReceipt> chatRewriteReceipts,
  String? synchronizedNoteId,
  List<HuahuoAiAnnotation> aiAnnotations,
  bool unreadable,
})
_decodeSharedMetadata(Object? value) {
  const empty = (
    summaryMarkdown: null,
    sproutMarkdown: null,
    sessionId: null,
    entryIdentity: null,
    scriptDraftReceipt: null,
    boundNoteId: null,
    boundAssetFingerprint: null,
    savedDraftCleanupPending: false,
    chatThreadId: null,
    historyCommitReceipt: null,
    chatRewriteReceipts: <CreationCanvasChatRewriteReceipt>[],
    synchronizedNoteId: null,
    aiAnnotations: <HuahuoAiAnnotation>[],
    unreadable: false,
  );
  if (value == null || value is String && value.trim().isEmpty) return empty;
  if (value is! String) return _unreadableSharedMetadata;
  try {
    final decoded = jsonDecode(value);
    if (decoded is! Map<String, Object?> ||
        (decoded['formatVersion'] != 1 &&
            decoded['formatVersion'] != 2 &&
            decoded['formatVersion'] != 3 &&
            decoded['formatVersion'] != 4 &&
            decoded['formatVersion'] != 5)) {
      return _unreadableSharedMetadata;
    }
    final summary = decoded['summaryMarkdown'];
    final sprout = decoded['sproutMarkdown'];
    final synchronizedNoteId = decoded['synchronizedNoteId'];
    final version = decoded['formatVersion'];
    final hasSessionMetadata =
        version == 2 || version == 3 || version == 4 || version == 5;
    final sessionId = hasSessionMetadata ? decoded['sessionId'] : null;
    final entryIdentity = hasSessionMetadata ? decoded['entryIdentity'] : null;
    final boundNoteId = hasSessionMetadata ? decoded['boundNoteId'] : null;
    final boundAssetFingerprint = version == 3 || version == 4 || version == 5
        ? decoded['boundAssetFingerprint']
        : null;
    final rawSavedDraftCleanupPending = version == 4 || version == 5
        ? decoded['savedDraftCleanupPending']
        : null;
    final savedDraftCleanupPending = rawSavedDraftCleanupPending == true;
    final chatThreadId = hasSessionMetadata ? decoded['chatThreadId'] : null;
    final rawHistoryCommitReceipt = version == 5
        ? decoded['historyCommitReceipt']
        : null;
    final rawChatRewriteReceipts = version == 5
        ? decoded['chatRewriteReceipts']
        : null;
    final rawAnnotations = decoded['aiAnnotations'];
    if ((summary != null && summary is! String) ||
        (sprout != null && sprout is! String) ||
        (synchronizedNoteId != null && synchronizedNoteId is! String) ||
        (sessionId != null && sessionId is! String) ||
        (entryIdentity != null && entryIdentity is! String) ||
        (boundNoteId != null && boundNoteId is! String) ||
        (boundAssetFingerprint != null && boundAssetFingerprint is! String) ||
        (chatThreadId != null && chatThreadId is! String) ||
        (rawSavedDraftCleanupPending != null &&
            rawSavedDraftCleanupPending is! bool) ||
        (rawHistoryCommitReceipt != null && rawHistoryCommitReceipt is! Map) ||
        (rawChatRewriteReceipts != null && rawChatRewriteReceipts is! List)) {
      return _unreadableSharedMetadata;
    }
    final annotations = <HuahuoAiAnnotation>[];
    if (rawAnnotations is List<Object?>) {
      for (final raw in rawAnnotations) {
        if (raw is! Map<String, Object?>) continue;
        try {
          annotations.add(HuahuoAiAnnotation.fromJson(raw));
        } on Object {
          // Optional annotations must not hide a valid recoverable draft.
        }
      }
    }
    ScriptDraftGenerationReceipt? scriptDraftReceipt;
    final rawReceipt = hasSessionMetadata
        ? decoded['scriptDraftReceipt']
        : null;
    if (rawReceipt is Map) {
      try {
        scriptDraftReceipt = ScriptDraftGenerationReceipt.fromJson(
          rawReceipt.cast<String, Object?>(),
        );
      } on Object {
        return _unreadableSharedMetadata;
      }
    } else if (rawReceipt != null) {
      return _unreadableSharedMetadata;
    }
    CreationCanvasHistoryCommitReceipt? historyCommitReceipt;
    if (rawHistoryCommitReceipt is Map) {
      historyCommitReceipt = CreationCanvasHistoryCommitReceipt.fromJson(
        rawHistoryCommitReceipt.cast<String, Object?>(),
      );
    }
    final chatRewriteReceipts = <CreationCanvasChatRewriteReceipt>[];
    if (rawChatRewriteReceipts is List) {
      for (final raw in rawChatRewriteReceipts) {
        if (raw is! Map) return _unreadableSharedMetadata;
        chatRewriteReceipts.add(
          CreationCanvasChatRewriteReceipt.fromJson(
            raw.cast<String, Object?>(),
          ),
        );
      }
      if (chatRewriteReceipts.length >
          CreationCanvasDraft.maxChatRewriteReceipts) {
        return _unreadableSharedMetadata;
      }
    }
    final normalizedSessionId = _optionalString(sessionId);
    final normalizedBoundNoteId = _optionalString(boundNoteId);
    final normalizedSynchronizedNoteId = _optionalString(synchronizedNoteId);
    final normalizedBoundAssetFingerprint = _optionalString(
      boundAssetFingerprint,
    );
    final normalizedChatThreadId = _optionalString(chatThreadId);
    if (!_sessionMetadataIsConsistent(
      sessionId: normalizedSessionId,
      boundNoteId: normalizedBoundNoteId ?? normalizedSynchronizedNoteId,
      boundAssetFingerprint: normalizedBoundAssetFingerprint,
      savedDraftCleanupPending: savedDraftCleanupPending,
      chatThreadId: normalizedChatThreadId,
      historyCommitReceipt: historyCommitReceipt,
      chatRewriteReceipts: chatRewriteReceipts,
    )) {
      return _unreadableSharedMetadata;
    }
    return (
      summaryMarkdown: _optionalString(summary),
      sproutMarkdown: _optionalString(sprout),
      sessionId: normalizedSessionId,
      entryIdentity: _optionalString(entryIdentity),
      scriptDraftReceipt: scriptDraftReceipt,
      boundNoteId: normalizedBoundNoteId,
      boundAssetFingerprint: normalizedBoundAssetFingerprint,
      savedDraftCleanupPending: savedDraftCleanupPending,
      chatThreadId: normalizedChatThreadId,
      historyCommitReceipt: historyCommitReceipt,
      chatRewriteReceipts: List<CreationCanvasChatRewriteReceipt>.unmodifiable(
        chatRewriteReceipts,
      ),
      synchronizedNoteId: normalizedSynchronizedNoteId,
      aiAnnotations: List<HuahuoAiAnnotation>.unmodifiable(annotations),
      unreadable: false,
    );
  } on Object {
    return _unreadableSharedMetadata;
  }
}

const _unreadableSharedMetadata = (
  summaryMarkdown: null,
  sproutMarkdown: null,
  sessionId: null,
  entryIdentity: null,
  scriptDraftReceipt: null,
  boundNoteId: null,
  boundAssetFingerprint: null,
  savedDraftCleanupPending: false,
  chatThreadId: null,
  historyCommitReceipt: null,
  chatRewriteReceipts: <CreationCanvasChatRewriteReceipt>[],
  synchronizedNoteId: null,
  aiAnnotations: <HuahuoAiAnnotation>[],
  unreadable: true,
);

Iterable<CreationCanvasChatRewriteReceipt> _boundedChatReceipts(
  List<CreationCanvasChatRewriteReceipt> receipts,
) {
  final overflow = receipts.length - CreationCanvasDraft.maxChatRewriteReceipts;
  return overflow <= 0 ? receipts : receipts.skip(overflow);
}

void _validateSessionMetadataForWrite(CreationCanvasDraft draft) {
  if (draft.unreadableSessionMetadata ||
      !_sessionMetadataIsConsistent(
        sessionId: _normalizeOptional(draft.sessionId),
        boundNoteId: _normalizeOptional(draft.boundNoteId),
        boundAssetFingerprint: _normalizeOptional(draft.boundAssetFingerprint),
        savedDraftCleanupPending: draft.savedDraftCleanupPending,
        chatThreadId: _normalizeOptional(draft.chatThreadId),
        historyCommitReceipt: draft.historyCommitReceipt,
        chatRewriteReceipts: draft.chatRewriteReceipts,
      )) {
    throw ArgumentError.value(
      draft,
      'draft',
      'contains contradictory or unreadable Canvas session metadata',
    );
  }
}

bool _sessionMetadataIsConsistent({
  required String? sessionId,
  required String? boundNoteId,
  required String? boundAssetFingerprint,
  required bool savedDraftCleanupPending,
  required String? chatThreadId,
  required CreationCanvasHistoryCommitReceipt? historyCommitReceipt,
  required List<CreationCanvasChatRewriteReceipt> chatRewriteReceipts,
}) {
  if (boundAssetFingerprint != null && boundNoteId == null) return false;
  if (savedDraftCleanupPending &&
      (sessionId == null ||
          boundNoteId == null ||
          historyCommitReceipt != null)) {
    return false;
  }
  if (historyCommitReceipt != null) {
    if (sessionId == null || savedDraftCleanupPending) return false;
    final snapshot = historyCommitReceipt.snapshot;
    if (snapshot != null && snapshot.sessionId != sessionId) return false;
    switch (historyCommitReceipt.phase) {
      case CreationCanvasHistoryCommitPhase.prepared:
        if (boundNoteId != historyCommitReceipt.baseNoteId ||
            boundAssetFingerprint != historyCommitReceipt.baseNoteFingerprint) {
          return false;
        }
      case CreationCanvasHistoryCommitPhase.noteCommitted ||
          CreationCanvasHistoryCommitPhase.historyCommitted:
        if (boundNoteId != historyCommitReceipt.noteId ||
            boundAssetFingerprint != historyCommitReceipt.noteFingerprint) {
          return false;
        }
    }
  }
  if (chatRewriteReceipts.length > CreationCanvasDraft.maxChatRewriteReceipts) {
    return false;
  }
  if (chatRewriteReceipts.isNotEmpty && sessionId == null) return false;
  final assistantMessageIds = <String>{};
  final userMessageIds = <String>{};
  CreationCanvasChatRewriteReceipt? pending;
  for (final receipt in chatRewriteReceipts) {
    if (!userMessageIds.add(receipt.userMessageId)) return false;
    final assistantMessageId = receipt.assistantMessageId;
    if (assistantMessageId == null) {
      if (pending != null) return false;
      pending = receipt;
      if (receipt.threadId == null && receipt.requestText == null) return false;
      continue;
    }
    if (receipt.threadId == null) return false;
    if (!assistantMessageIds.add(assistantMessageId)) return false;
  }
  if (pending?.threadId != null && pending!.threadId != chatThreadId) {
    return false;
  }
  return true;
}

({String? json, int version, bool unreadable}) _recoverDocument(
  Object? rawJson,
  Object? rawVersion,
) {
  if (rawJson is! String || rawJson.trim().isEmpty) {
    return (json: null, version: 0, unreadable: false);
  }
  if (rawVersion is! int ||
      rawVersion != CreationCanvasDraft.currentDocumentFormatVersion ||
      !_isStructuredJson(rawJson)) {
    return (json: null, version: 0, unreadable: true);
  }
  return (json: rawJson, version: rawVersion, unreadable: false);
}

String? _validateDocumentForWrite(String? value, int version) {
  if (value == null) {
    if (version != 0) {
      throw ArgumentError.value(
        version,
        'draft.documentFormatVersion',
        'must be zero when documentJson is absent',
      );
    }
    return null;
  }
  if (version != CreationCanvasDraft.currentDocumentFormatVersion) {
    throw ArgumentError.value(
      version,
      'draft.documentFormatVersion',
      'must be the currently supported version when documentJson is present',
    );
  }
  if (!_isStructuredJson(value)) {
    throw ArgumentError.value(
      value,
      'draft.documentJson',
      'must be a JSON object or array',
    );
  }
  return value;
}

bool _isStructuredJson(String value) {
  try {
    final decoded = jsonDecode(value);
    return decoded is List<Object?> || decoded is Map<String, Object?>;
  } on FormatException {
    return false;
  }
}

String _encodeLinkedMaterials(Iterable<V3LinkedMaterialRef> materials) {
  return jsonEncode(<Map<String, Object?>>[
    for (final material in materials)
      <String, Object?>{
        'id': _normalizeRequired(material.id, 'linkedMaterial.id'),
        'source': material.source.name,
        'title': _normalizeRequired(material.title, 'linkedMaterial.title'),
        if (_normalizeOptional(material.summary) case final summary?)
          'summary': summary,
      },
  ]);
}

List<V3LinkedMaterialRef> _decodeLinkedMaterials(Object? value) {
  if (value is! String) return const <V3LinkedMaterialRef>[];
  try {
    final decoded = jsonDecode(value);
    if (decoded is! List<Object?>) return const <V3LinkedMaterialRef>[];
    final materials = <V3LinkedMaterialRef>[];
    for (final entry in decoded) {
      if (entry is! Map<String, Object?>) continue;
      final id = _optionalString(entry['id']);
      final title = _optionalString(entry['title']);
      final sourceName = entry['source'];
      if (id == null || title == null || sourceName is! String) continue;
      V3MaterialSource? source;
      for (final candidate in V3MaterialSource.values) {
        if (candidate.name == sourceName) {
          source = candidate;
          break;
        }
      }
      if (source == null) continue;
      materials.add(
        V3LinkedMaterialRef(
          id: id,
          source: source,
          title: title,
          summary: _optionalString(entry['summary']),
        ),
      );
    }
    return List<V3LinkedMaterialRef>.unmodifiable(materials);
  } on FormatException {
    return const <V3LinkedMaterialRef>[];
  }
}

String _normalizeRequired(String value, String name) {
  final normalized = value.trim();
  if (normalized.isEmpty) {
    throw ArgumentError.value(value, name, 'must not be empty');
  }
  return normalized;
}

String? _normalizeOptional(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}

String? _optionalString(Object? value) {
  if (value == null) return null;
  if (value is! String) return null;
  return _normalizeOptional(value);
}
