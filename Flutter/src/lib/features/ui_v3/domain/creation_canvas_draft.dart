import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:huahuo_editor/huahuo_editor.dart';

import 'feed_item_models.dart';
import 'script_draft_models.dart';

enum CreationCanvasHistoryCommitPhase {
  prepared,
  noteCommitted,
  historyCommitted,
}

enum CreationCanvasChatSubmissionPhase { prepared, submitting }

@immutable
final class CreationCanvasSaveSnapshot {
  CreationCanvasSaveSnapshot({
    required this.rawTitle,
    required String title,
    required String markdown,
    required String documentJson,
    required int documentRevision,
    required String sessionId,
    required DateTime createdAt,
    this.sourceTopicId,
    this.sourceTitle,
    this.entryIdentity,
    required Iterable<V3LinkedMaterialRef> linkedMaterials,
  }) : title = _requiredReceiptContent(title, 'title'),
       markdown = _requiredReceiptContent(markdown, 'markdown'),
       documentJson = _requiredReceiptContent(documentJson, 'documentJson'),
       documentRevision = _nonNegativeReceiptInt(
         documentRevision,
         'documentRevision',
       ),
       sessionId = _requiredReceiptText(sessionId, 'sessionId'),
       createdAt = createdAt.toUtc(),
       linkedMaterials = List<V3LinkedMaterialRef>.unmodifiable(
         linkedMaterials,
       );

  final String rawTitle;
  final String title;
  final String markdown;
  final String documentJson;
  final int documentRevision;
  final String sessionId;
  final DateTime createdAt;
  final String? sourceTopicId;
  final String? sourceTitle;
  final String? entryIdentity;
  final List<V3LinkedMaterialRef> linkedMaterials;

  List<Map<String, Object?>> get _materialsJson => [
    for (final material in linkedMaterials)
      <String, Object?>{
        'id': material.id,
        'source': material.source.name,
        'title': material.title,
        'summary': material.summary,
      },
  ];

  String hashForBound(String noteId) => scriptDraftContentHash(
    jsonEncode(<String, Object?>{
      'rawTitle': rawTitle,
      'title': title,
      'markdown': markdown,
      'documentJson': documentJson,
      'documentRevision': documentRevision,
      'sourceTopicId': sourceTopicId,
      'sourceTitle': sourceTitle,
      'entryIdentity': entryIdentity,
      'sessionId': sessionId,
      'boundNoteId': noteId,
      'linkedMaterials': _materialsJson,
    }),
  );

  Map<String, Object?> toJson() => {
    'version': 1,
    'rawTitle': rawTitle,
    'title': title,
    'markdown': markdown,
    'documentJson': documentJson,
    'documentRevision': documentRevision,
    'sessionId': sessionId,
    'createdAt': createdAt.toIso8601String(),
    'sourceTopicId': sourceTopicId,
    'sourceTitle': sourceTitle,
    'entryIdentity': entryIdentity,
    'linkedMaterials': _materialsJson,
  };

  factory CreationCanvasSaveSnapshot.fromJson(Map<String, Object?> json) {
    final materials = json['linkedMaterials'];
    if (json['version'] != 1 || materials is! List) {
      throw const FormatException('unsupported Canvas save snapshot');
    }
    return CreationCanvasSaveSnapshot(
      rawTitle: _receiptString(json, 'rawTitle'),
      title: _receiptString(json, 'title'),
      markdown: _receiptString(json, 'markdown'),
      documentJson: _receiptString(json, 'documentJson'),
      documentRevision: _receiptNonNegativeInt(json, 'documentRevision'),
      sessionId: _receiptString(json, 'sessionId'),
      createdAt: DateTime.parse(_receiptString(json, 'createdAt')),
      sourceTopicId: _receiptOptionalString(json, 'sourceTopicId'),
      sourceTitle: _receiptOptionalString(json, 'sourceTitle'),
      entryIdentity: _receiptOptionalString(json, 'entryIdentity'),
      linkedMaterials: materials.map((value) {
        if (value is! Map) {
          throw const FormatException('invalid Canvas save material');
        }
        final material = value.cast<String, Object?>();
        return V3LinkedMaterialRef(
          id: _receiptString(material, 'id'),
          source: V3MaterialSource.values.byName(
            _receiptString(material, 'source'),
          ),
          title: _receiptString(material, 'title'),
          summary: _receiptOptionalString(material, 'summary'),
        );
      }),
    );
  }
}

@immutable
final class CreationCanvasHistoryCommitReceipt {
  CreationCanvasHistoryCommitReceipt({
    this.phase = CreationCanvasHistoryCommitPhase.noteCommitted,
    required String historyId,
    required String noteId,
    required String noteFingerprint,
    required String editorSnapshotHash,
    String? baseNoteId,
    String? baseNoteFingerprint,
    this.snapshot,
  }) : historyId = _requiredReceiptText(historyId, 'historyId'),
       noteId = _requiredReceiptText(noteId, 'noteId'),
       noteFingerprint = _requiredReceiptText(
         noteFingerprint,
         'noteFingerprint',
       ),
       editorSnapshotHash = _requiredReceiptText(
         editorSnapshotHash,
         'editorSnapshotHash',
       ),
       baseNoteId = _optionalReceiptText(baseNoteId, 'baseNoteId'),
       baseNoteFingerprint = _optionalReceiptText(
         baseNoteFingerprint,
         'baseNoteFingerprint',
       ) {
    if (snapshot != null &&
        snapshot!.hashForBound(this.noteId) != this.editorSnapshotHash) {
      throw ArgumentError('Canvas save snapshot does not match receipt');
    }
    if ((this.baseNoteId == null) != (this.baseNoteFingerprint == null)) {
      throw ArgumentError(
        'baseNoteId and baseNoteFingerprint must both be present or absent',
      );
    }
    if (this.baseNoteId != null && this.baseNoteId != this.noteId) {
      throw ArgumentError.value(
        baseNoteId,
        'baseNoteId',
        'must identify the target Note',
      );
    }
  }

  final CreationCanvasHistoryCommitPhase phase;
  final String historyId;
  final String noteId;
  final String noteFingerprint;
  final String editorSnapshotHash;
  final String? baseNoteId;
  final String? baseNoteFingerprint;
  final CreationCanvasSaveSnapshot? snapshot;

  CreationCanvasHistoryCommitReceipt advanceTo(
    CreationCanvasHistoryCommitPhase next,
  ) {
    if (next.index < phase.index) {
      throw ArgumentError.value(next, 'next', 'must not move backwards');
    }
    return CreationCanvasHistoryCommitReceipt(
      phase: next,
      historyId: historyId,
      noteId: noteId,
      noteFingerprint: noteFingerprint,
      editorSnapshotHash: editorSnapshotHash,
      baseNoteId: baseNoteId,
      baseNoteFingerprint: baseNoteFingerprint,
      snapshot: snapshot,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'phase': phase.name,
    'historyId': historyId,
    'noteId': noteId,
    'noteFingerprint': noteFingerprint,
    'editorSnapshotHash': editorSnapshotHash,
    if (baseNoteId != null) 'baseNoteId': baseNoteId,
    if (baseNoteFingerprint != null) 'baseNoteFingerprint': baseNoteFingerprint,
    if (snapshot != null) 'snapshot': snapshot!.toJson(),
  };

  factory CreationCanvasHistoryCommitReceipt.fromJson(
    Map<String, Object?> json,
  ) => CreationCanvasHistoryCommitReceipt(
    phase: _historyCommitPhase(json['phase']),
    historyId: _receiptString(json, 'historyId'),
    noteId: _receiptString(json, 'noteId'),
    noteFingerprint: _receiptString(json, 'noteFingerprint'),
    editorSnapshotHash: _receiptString(json, 'editorSnapshotHash'),
    baseNoteId: _receiptOptionalString(json, 'baseNoteId'),
    baseNoteFingerprint: _receiptOptionalString(json, 'baseNoteFingerprint'),
    snapshot: json['snapshot'] == null
        ? null
        : CreationCanvasSaveSnapshot.fromJson(
            (json['snapshot'] as Map).cast<String, Object?>(),
          ),
  );
}

@immutable
final class CreationCanvasChatRewriteReceipt {
  CreationCanvasChatRewriteReceipt({
    String? threadId,
    required String userMessageId,
    String? createThreadIdempotencyKey,
    String? messageIdempotencyKey,
    this.submissionPhase = CreationCanvasChatSubmissionPhase.prepared,
    required int rangeStart,
    required int rangeEnd,
    required String sourceMarkdown,
    required String sourceHash,
    required String documentHash,
    required int documentRevision,
    required this.selectionScoped,
    String? agentRunId,
    String? assistantMessageId,
    String? requestText,
  }) : threadId = _optionalReceiptText(threadId, 'threadId'),
       userMessageId = _requiredReceiptText(userMessageId, 'userMessageId'),
       createThreadIdempotencyKey =
           _optionalReceiptText(
             createThreadIdempotencyKey,
             'createThreadIdempotencyKey',
           ) ??
           creationCanvasChatIdempotencyKey(
             operation: 'create-thread',
             userMessageId: userMessageId,
           ),
       messageIdempotencyKey =
           _optionalReceiptText(
             messageIdempotencyKey,
             'messageIdempotencyKey',
           ) ??
           creationCanvasChatIdempotencyKey(
             operation: 'send-message',
             userMessageId: userMessageId,
           ),
       rangeStart = _nonNegativeReceiptInt(rangeStart, 'rangeStart'),
       rangeEnd = _nonNegativeReceiptInt(rangeEnd, 'rangeEnd'),
       sourceMarkdown = _requiredReceiptContent(
         sourceMarkdown,
         'sourceMarkdown',
       ),
       sourceHash = _requiredReceiptText(sourceHash, 'sourceHash'),
       documentHash = _requiredReceiptText(documentHash, 'documentHash'),
       documentRevision = _nonNegativeReceiptInt(
         documentRevision,
         'documentRevision',
       ),
       agentRunId = _optionalReceiptText(agentRunId, 'agentRunId'),
       assistantMessageId = _optionalReceiptText(
         assistantMessageId,
         'assistantMessageId',
       ),
       requestText = _optionalReceiptContent(
         requestText,
         'requestText',
         maxLength: 4000,
       ) {
    if (this.rangeEnd < this.rangeStart) {
      throw ArgumentError.value(rangeEnd, 'rangeEnd', 'must follow rangeStart');
    }
    if (scriptDraftContentHash(this.sourceMarkdown) != this.sourceHash) {
      throw ArgumentError.value(
        sourceHash,
        'sourceHash',
        'does not match source',
      );
    }
    if ((this.agentRunId != null || this.assistantMessageId != null) &&
        this.threadId == null) {
      throw ArgumentError('Run and Assistant receipts require a Thread');
    }
  }

  final String? threadId;
  final String userMessageId;
  final String createThreadIdempotencyKey;
  final String messageIdempotencyKey;
  final CreationCanvasChatSubmissionPhase submissionPhase;
  final String? agentRunId;
  final String? assistantMessageId;
  final int rangeStart;
  final int rangeEnd;
  final String sourceMarkdown;
  final String sourceHash;
  final String documentHash;
  final int documentRevision;
  final bool selectionScoped;
  final String? requestText;

  CreationCanvasChatRewriteReceipt bindTurn({
    required String threadId,
    String? agentRunId,
  }) => CreationCanvasChatRewriteReceipt(
    threadId: threadId,
    userMessageId: userMessageId,
    createThreadIdempotencyKey: createThreadIdempotencyKey,
    messageIdempotencyKey: messageIdempotencyKey,
    submissionPhase: submissionPhase,
    agentRunId: agentRunId,
    assistantMessageId: assistantMessageId,
    rangeStart: rangeStart,
    rangeEnd: rangeEnd,
    sourceMarkdown: sourceMarkdown,
    sourceHash: sourceHash,
    documentHash: documentHash,
    documentRevision: documentRevision,
    selectionScoped: selectionScoped,
    requestText: requestText,
  );

  CreationCanvasChatRewriteReceipt bindAssistant(String messageId) =>
      CreationCanvasChatRewriteReceipt(
        threadId: threadId,
        userMessageId: userMessageId,
        createThreadIdempotencyKey: createThreadIdempotencyKey,
        messageIdempotencyKey: messageIdempotencyKey,
        submissionPhase: submissionPhase,
        agentRunId: agentRunId,
        assistantMessageId: messageId,
        rangeStart: rangeStart,
        rangeEnd: rangeEnd,
        sourceMarkdown: sourceMarkdown,
        sourceHash: sourceHash,
        documentHash: documentHash,
        documentRevision: documentRevision,
        selectionScoped: selectionScoped,
        requestText: requestText,
      );

  Map<String, Object?> toJson() => <String, Object?>{
    if (threadId != null) 'threadId': threadId,
    'userMessageId': userMessageId,
    'createThreadIdempotencyKey': createThreadIdempotencyKey,
    'messageIdempotencyKey': messageIdempotencyKey,
    'submissionPhase': submissionPhase.name,
    if (agentRunId != null) 'agentRunId': agentRunId,
    if (assistantMessageId != null) 'assistantMessageId': assistantMessageId,
    'rangeStart': rangeStart,
    'rangeEnd': rangeEnd,
    'sourceMarkdown': sourceMarkdown,
    'sourceHash': sourceHash,
    'documentHash': documentHash,
    'documentRevision': documentRevision,
    'selectionScoped': selectionScoped,
    if (requestText != null) 'requestText': requestText,
  };

  factory CreationCanvasChatRewriteReceipt.fromJson(
    Map<String, Object?> json,
  ) => CreationCanvasChatRewriteReceipt(
    threadId: _receiptOptionalString(json, 'threadId'),
    userMessageId: _receiptString(json, 'userMessageId'),
    createThreadIdempotencyKey: _receiptOptionalString(
      json,
      'createThreadIdempotencyKey',
    ),
    messageIdempotencyKey: _receiptOptionalString(
      json,
      'messageIdempotencyKey',
    ),
    submissionPhase: _chatSubmissionPhase(json['submissionPhase']),
    agentRunId: _receiptOptionalString(json, 'agentRunId'),
    assistantMessageId: _receiptOptionalString(json, 'assistantMessageId'),
    rangeStart: _receiptNonNegativeInt(json, 'rangeStart'),
    rangeEnd: _receiptNonNegativeInt(json, 'rangeEnd'),
    sourceMarkdown: _receiptString(json, 'sourceMarkdown'),
    sourceHash: _receiptString(json, 'sourceHash'),
    documentHash: _receiptString(json, 'documentHash'),
    documentRevision: _receiptNonNegativeInt(json, 'documentRevision'),
    selectionScoped: _receiptBool(json, 'selectionScoped'),
    requestText: _receiptOptionalString(json, 'requestText'),
  );
}

String creationCanvasChatIdempotencyKey({
  required String operation,
  required String userMessageId,
}) {
  final normalizedOperation = _requiredReceiptText(operation, 'operation');
  final normalizedMessageId = _requiredReceiptText(
    userMessageId,
    'userMessageId',
  );
  final digest = scriptDraftContentHash(
    'creation-canvas-chat|$normalizedOperation|$normalizedMessageId',
  );
  return 'canvas-chat-$normalizedOperation-$digest';
}

@immutable
final class CreationCanvasDraft {
  CreationCanvasDraft({
    required this.title,
    required this.markdown,
    required this.revision,
    required this.createdAt,
    required this.updatedAt,
    this.documentJson,
    this.documentFormatVersion = 0,
    this.unreadableStructuredDocument = false,
    Iterable<V3LinkedMaterialRef> linkedMaterials =
        const <V3LinkedMaterialRef>[],
    this.sourceTopicId,
    this.sourceTitle,
    this.sessionId,
    this.entryIdentity,
    this.scriptDraftReceipt,
    this.boundNoteId,
    this.boundAssetFingerprint,
    this.savedDraftCleanupPending = false,
    this.chatThreadId,
    this.historyCommitReceipt,
    Iterable<CreationCanvasChatRewriteReceipt> chatRewriteReceipts =
        const <CreationCanvasChatRewriteReceipt>[],
    this.unreadableSessionMetadata = false,
    this.synchronizedNoteId,
    this.summaryMarkdown,
    this.sproutMarkdown,
    Iterable<HuahuoAiAnnotation> aiAnnotations = const <HuahuoAiAnnotation>[],
  }) : linkedMaterials = List<V3LinkedMaterialRef>.unmodifiable(
         linkedMaterials,
       ),
       chatRewriteReceipts =
           List<CreationCanvasChatRewriteReceipt>.unmodifiable(
             chatRewriteReceipts,
           ),
       aiAnnotations = List<HuahuoAiAnnotation>.unmodifiable(aiAnnotations);

  final String title;
  final String markdown;
  final String? documentJson;
  final int documentFormatVersion;
  final bool unreadableStructuredDocument;
  final List<V3LinkedMaterialRef> linkedMaterials;
  final String? sourceTopicId;
  final String? sourceTitle;

  /// Recoverable Canvas session metadata. These fields are additive so old
  /// Markdown-only drafts remain readable.
  final String? sessionId;
  final String? entryIdentity;
  final ScriptDraftGenerationReceipt? scriptDraftReceipt;
  final String? boundNoteId;
  final String? boundAssetFingerprint;
  final bool savedDraftCleanupPending;
  final String? chatThreadId;
  final CreationCanvasHistoryCommitReceipt? historyCommitReceipt;
  final List<CreationCanvasChatRewriteReceipt> chatRewriteReceipts;

  /// Runtime-only fail-closed recovery signal; never written back to storage.
  final bool unreadableSessionMetadata;

  /// Legacy pre-save synchronization identity. New Canvas flows never write it.
  final String? synchronizedNoteId;
  final String? summaryMarkdown;
  final String? sproutMarkdown;
  final List<HuahuoAiAnnotation> aiAnnotations;
  final int revision;
  final DateTime createdAt;
  final DateTime updatedAt;

  CreationCanvasDraft copyWith({
    String? title,
    String? markdown,
    String? documentJson,
    int? documentFormatVersion,
    bool? unreadableStructuredDocument,
    Iterable<V3LinkedMaterialRef>? linkedMaterials,
    String? sourceTopicId,
    String? sourceTitle,
    String? sessionId,
    String? entryIdentity,
    ScriptDraftGenerationReceipt? scriptDraftReceipt,
    String? boundNoteId,
    String? boundAssetFingerprint,
    bool? savedDraftCleanupPending,
    String? chatThreadId,
    CreationCanvasHistoryCommitReceipt? historyCommitReceipt,
    Iterable<CreationCanvasChatRewriteReceipt>? chatRewriteReceipts,
    bool? unreadableSessionMetadata,
    String? synchronizedNoteId,
    String? summaryMarkdown,
    String? sproutMarkdown,
    Iterable<HuahuoAiAnnotation>? aiAnnotations,
    int? revision,
    DateTime? createdAt,
    DateTime? updatedAt,
    bool clearDocumentJson = false,
    bool clearSourceTopicId = false,
    bool clearSourceTitle = false,
    bool clearSessionId = false,
    bool clearEntryIdentity = false,
    bool clearScriptDraftReceipt = false,
    bool clearBoundNoteId = false,
    bool clearBoundAssetFingerprint = false,
    bool clearChatThreadId = false,
    bool clearHistoryCommitReceipt = false,
    bool clearSynchronizedNoteId = false,
    bool clearSummaryMarkdown = false,
    bool clearSproutMarkdown = false,
  }) {
    return CreationCanvasDraft(
      title: title ?? this.title,
      markdown: markdown ?? this.markdown,
      documentJson: clearDocumentJson
          ? null
          : documentJson ?? this.documentJson,
      documentFormatVersion: clearDocumentJson
          ? 0
          : documentFormatVersion ?? this.documentFormatVersion,
      unreadableStructuredDocument: clearDocumentJson
          ? false
          : unreadableStructuredDocument ?? this.unreadableStructuredDocument,
      linkedMaterials: linkedMaterials ?? this.linkedMaterials,
      sourceTopicId: clearSourceTopicId
          ? null
          : sourceTopicId ?? this.sourceTopicId,
      sourceTitle: clearSourceTitle ? null : sourceTitle ?? this.sourceTitle,
      sessionId: clearSessionId ? null : sessionId ?? this.sessionId,
      entryIdentity: clearEntryIdentity
          ? null
          : entryIdentity ?? this.entryIdentity,
      scriptDraftReceipt: clearScriptDraftReceipt
          ? null
          : scriptDraftReceipt ?? this.scriptDraftReceipt,
      boundNoteId: clearBoundNoteId ? null : boundNoteId ?? this.boundNoteId,
      boundAssetFingerprint: clearBoundAssetFingerprint
          ? null
          : boundAssetFingerprint ?? this.boundAssetFingerprint,
      savedDraftCleanupPending:
          savedDraftCleanupPending ?? this.savedDraftCleanupPending,
      chatThreadId: clearChatThreadId
          ? null
          : chatThreadId ?? this.chatThreadId,
      historyCommitReceipt: clearHistoryCommitReceipt
          ? null
          : historyCommitReceipt ?? this.historyCommitReceipt,
      chatRewriteReceipts: chatRewriteReceipts ?? this.chatRewriteReceipts,
      unreadableSessionMetadata:
          unreadableSessionMetadata ?? this.unreadableSessionMetadata,
      synchronizedNoteId: clearSynchronizedNoteId
          ? null
          : synchronizedNoteId ?? this.synchronizedNoteId,
      summaryMarkdown: clearSummaryMarkdown
          ? null
          : summaryMarkdown ?? this.summaryMarkdown,
      sproutMarkdown: clearSproutMarkdown
          ? null
          : sproutMarkdown ?? this.sproutMarkdown,
      aiAnnotations: aiAnnotations ?? this.aiAnnotations,
      revision: revision ?? this.revision,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  static const int currentDocumentFormatVersion = 1;
  static const int maxChatRewriteReceipts = 24;
}

String _requiredReceiptText(String value, String field) {
  final normalized = value.trim();
  if (normalized.isEmpty) {
    throw ArgumentError.value(value, field, 'must not be empty');
  }
  return normalized;
}

String _requiredReceiptContent(String value, String field) {
  if (value.trim().isEmpty) {
    throw ArgumentError.value(value, field, 'must not be blank');
  }
  return value;
}

String? _optionalReceiptText(String? value, String field) {
  if (value == null) return null;
  return _requiredReceiptText(value, field);
}

String? _optionalReceiptContent(
  String? value,
  String field, {
  required int maxLength,
}) {
  if (value == null) return null;
  final content = _requiredReceiptContent(value, field);
  if (content.length > maxLength) {
    throw ArgumentError.value(value, field, 'must not exceed $maxLength');
  }
  return content;
}

int _nonNegativeReceiptInt(int value, String field) {
  if (value < 0) throw ArgumentError.value(value, field, 'must be nonnegative');
  return value;
}

String _receiptString(Map<String, Object?> json, String field) {
  final value = json[field];
  if (value is! String) throw FormatException('$field must be a string');
  return value;
}

String? _receiptOptionalString(Map<String, Object?> json, String field) {
  final value = json[field];
  if (value == null) return null;
  if (value is! String) {
    throw FormatException('$field must be a string or null');
  }
  return value;
}

int _receiptNonNegativeInt(Map<String, Object?> json, String field) {
  final value = json[field];
  if (value is! int || value < 0) {
    throw FormatException('$field must be a nonnegative integer');
  }
  return value;
}

bool _receiptBool(Map<String, Object?> json, String field) {
  final value = json[field];
  if (value is! bool) throw FormatException('$field must be a boolean');
  return value;
}

CreationCanvasHistoryCommitPhase _historyCommitPhase(Object? value) {
  if (value == null) return CreationCanvasHistoryCommitPhase.noteCommitted;
  if (value is! String) {
    throw const FormatException('phase must be a string');
  }
  return switch (value.trim()) {
    'prepared' => CreationCanvasHistoryCommitPhase.prepared,
    'noteCommitted' => CreationCanvasHistoryCommitPhase.noteCommitted,
    'historyCommitted' => CreationCanvasHistoryCommitPhase.historyCommitted,
    _ => throw FormatException('unsupported History commit phase: $value'),
  };
}

CreationCanvasChatSubmissionPhase _chatSubmissionPhase(Object? value) {
  if (value == null) return CreationCanvasChatSubmissionPhase.submitting;
  if (value is! String) {
    throw const FormatException('submissionPhase must be a string');
  }
  return switch (value.trim()) {
    'prepared' => CreationCanvasChatSubmissionPhase.prepared,
    'submitting' => CreationCanvasChatSubmissionPhase.submitting,
    _ => throw FormatException('unsupported Chat submission phase: $value'),
  };
}
