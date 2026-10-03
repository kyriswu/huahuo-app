import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

enum ScriptDraftSourceKind {
  dailyRecommendation('daily_recommendation'),
  asset('asset');

  const ScriptDraftSourceKind(this.apiValue);

  final String apiValue;

  static ScriptDraftSourceKind fromJson(Object? value) {
    for (final candidate in values) {
      if (candidate.apiValue == value) return candidate;
    }
    throw const FormatException('Unsupported script draft source kind');
  }
}

enum ScriptDraftAssetPart {
  raw('raw'),
  outline('outline'),
  germination('germination');

  const ScriptDraftAssetPart(this.apiValue);

  final String apiValue;

  static ScriptDraftAssetPart fromJson(Object? value) {
    for (final candidate in values) {
      if (candidate.apiValue == value) return candidate;
    }
    throw const FormatException('Unsupported script draft asset part');
  }
}

@immutable
final class ScriptDraftSourceSnapshot {
  ScriptDraftSourceSnapshot({
    required this.kind,
    required String sourceId,
    required String title,
    required String content,
    required this.capturedAt,
    this.assetPart,
    String? partRevisionId,
    String? contentHash,
  }) : sourceId = _requiredText(sourceId, 'sourceId', maxLength: 256),
       title = _requiredText(title, 'title', maxLength: 500),
       content = _requiredText(content, 'content', maxLength: 200000),
       partRevisionId = _optionalText(
         partRevisionId,
         'partRevisionId',
         maxLength: 256,
       ),
       contentHash = contentHash ?? scriptDraftContentHash(content) {
    if ((kind == ScriptDraftSourceKind.asset) != (assetPart != null)) {
      throw ArgumentError(
        'Asset sources require one asset part; daily topics forbid it',
      );
    }
    if (this.contentHash != scriptDraftContentHash(this.content)) {
      throw ArgumentError.value(
        contentHash,
        'contentHash',
        'Content hash does not match source content',
      );
    }
  }

  factory ScriptDraftSourceSnapshot.fromJson(Map<String, Object?> json) {
    final rawAssetPart = json['assetPart'];
    try {
      return ScriptDraftSourceSnapshot(
        kind: ScriptDraftSourceKind.fromJson(json['kind']),
        sourceId: _jsonString(json, 'sourceId'),
        title: _jsonString(json, 'title'),
        content: _jsonString(json, 'content'),
        assetPart: rawAssetPart == null
            ? null
            : ScriptDraftAssetPart.fromJson(rawAssetPart),
        partRevisionId: _jsonOptionalString(json, 'partRevisionId'),
        contentHash: _jsonString(json, 'contentHash'),
        capturedAt: _jsonDateTime(json, 'capturedAt'),
      );
    } on ArgumentError catch (error) {
      throw FormatException('Invalid script draft source: $error');
    }
  }

  final ScriptDraftSourceKind kind;
  final String sourceId;
  final String title;
  final String content;
  final ScriptDraftAssetPart? assetPart;
  final String? partRevisionId;
  final String contentHash;
  final DateTime capturedAt;

  String get identity => jsonEncode(<String, Object?>{
    'kind': kind.apiValue,
    'sourceId': sourceId,
    'assetPart': assetPart?.apiValue,
    'partRevisionId': partRevisionId,
    'contentHash': contentHash,
  });

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': kind.apiValue,
    'sourceId': sourceId,
    'title': title,
    'content': content,
    if (assetPart != null) 'assetPart': assetPart!.apiValue,
    if (partRevisionId != null) 'partRevisionId': partRevisionId,
    'contentHash': contentHash,
    'capturedAt': capturedAt.toUtc().toIso8601String(),
  };
}

@immutable
final class ScriptDraftRequest {
  const ScriptDraftRequest({required this.source});

  static const agentProfileId = 'script_draft';
  static const modelProfileId = 'deepseek-v4-flash-vision';

  final ScriptDraftSourceSnapshot source;

  String get prompt {
    final sourceLabel = switch (source.kind) {
      ScriptDraftSourceKind.dailyRecommendation => '选题方向',
      ScriptDraftSourceKind.asset => switch (source.assetPart!) {
        ScriptDraftAssetPart.raw => '资产原文',
        ScriptDraftAssetPart.outline => '资产大纲',
        ScriptDraftAssetPart.germination => '资产深度洞察内容',
      },
    };
    return '请直接根据下面的$sourceLabel，生成一篇可以继续编辑的中文口播逐字稿。'
        '不要调用工具，不要解释过程，直接输出约500到700字的成稿，语言自然、具体、有节奏，'
        '不要虚构数据或研究结论。\n\n'
        '标题：${source.title}\n\n'
        '$sourceLabel：\n${source.content}';
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'agentProfileId': agentProfileId,
    'modelProfileId': modelProfileId,
    'input': <String, Object?>{
      'content': <Map<String, Object?>>[
        <String, Object?>{'type': 'text', 'text': prompt},
      ],
    },
  };
}

enum ScriptDraftGenerationPhase {
  idle('idle'),
  resolving('resolving'),
  creatingThread('creating_thread'),
  submitting('submitting'),
  streaming('streaming'),
  ready('ready'),
  failed('failed'),
  cancelled('cancelled');

  const ScriptDraftGenerationPhase(this.storageValue);

  final String storageValue;

  static ScriptDraftGenerationPhase fromJson(Object? value) {
    for (final candidate in values) {
      if (candidate.storageValue == value) return candidate;
    }
    throw const FormatException('Unsupported script draft generation phase');
  }
}

@immutable
final class ScriptDraftGenerationReceipt {
  ScriptDraftGenerationReceipt({
    required String sessionId,
    required this.source,
    required String createThreadIdempotencyKey,
    required String messageIdempotencyKey,
    required String cancelIdempotencyKey,
    required this.phase,
    required this.updatedAt,
    this.threadId,
    this.agentRunId,
    this.afterSequence = 0,
    this.partialMarkdown = '',
    this.partialIsComplete = true,
    this.finalMarkdown,
    this.failureCode,
    this.failureRetryable = false,
  }) : sessionId = _requiredText(sessionId, 'sessionId', maxLength: 240),
       createThreadIdempotencyKey = _requiredText(
         createThreadIdempotencyKey,
         'createThreadIdempotencyKey',
         maxLength: 240,
       ),
       messageIdempotencyKey = _requiredText(
         messageIdempotencyKey,
         'messageIdempotencyKey',
         maxLength: 240,
       ),
       cancelIdempotencyKey = _requiredText(
         cancelIdempotencyKey,
         'cancelIdempotencyKey',
         maxLength: 240,
       ) {
    _validate();
  }

  factory ScriptDraftGenerationReceipt.fromJson(Map<String, Object?> json) {
    if (json['schemaVersion'] != schemaVersion) {
      throw const FormatException('Unsupported script draft receipt version');
    }
    final sourceJson = json['source'];
    if (sourceJson is! Map) {
      throw const FormatException('Script draft receipt source is required');
    }
    try {
      return ScriptDraftGenerationReceipt(
        sessionId: _jsonString(json, 'sessionId'),
        source: ScriptDraftSourceSnapshot.fromJson(
          sourceJson.cast<String, Object?>(),
        ),
        createThreadIdempotencyKey: _jsonString(
          json,
          'createThreadIdempotencyKey',
        ),
        messageIdempotencyKey: _jsonString(json, 'messageIdempotencyKey'),
        cancelIdempotencyKey: _jsonString(json, 'cancelIdempotencyKey'),
        phase: ScriptDraftGenerationPhase.fromJson(json['phase']),
        threadId: _jsonOptionalString(json, 'threadId'),
        agentRunId: _jsonOptionalString(json, 'agentRunId'),
        afterSequence: _jsonNonNegativeInt(json, 'afterSequence'),
        partialMarkdown: _jsonString(json, 'partialMarkdown'),
        partialIsComplete: _jsonBool(json, 'partialIsComplete'),
        finalMarkdown: _jsonOptionalString(json, 'finalMarkdown'),
        failureCode: _jsonOptionalString(json, 'failureCode'),
        failureRetryable: _jsonBool(json, 'failureRetryable'),
        updatedAt: _jsonDateTime(json, 'updatedAt'),
      );
    } on ArgumentError catch (error) {
      throw FormatException('Invalid script draft receipt: $error');
    }
  }

  static const int schemaVersion = 1;

  final String sessionId;
  final ScriptDraftSourceSnapshot source;
  final String createThreadIdempotencyKey;
  final String messageIdempotencyKey;
  final String cancelIdempotencyKey;
  final ScriptDraftGenerationPhase phase;
  final String? threadId;
  final String? agentRunId;
  final int afterSequence;
  final String partialMarkdown;
  final bool partialIsComplete;
  final String? finalMarkdown;
  final String? failureCode;
  final bool failureRetryable;
  final DateTime updatedAt;

  bool get hasAuthoritativeResult =>
      phase == ScriptDraftGenerationPhase.ready &&
      finalMarkdown?.trim().isNotEmpty == true;

  bool matchesSource(ScriptDraftSourceSnapshot candidate) =>
      source.identity == candidate.identity;

  ScriptDraftGenerationReceipt copyWith({
    ScriptDraftGenerationPhase? phase,
    Object? threadId = _unset,
    Object? agentRunId = _unset,
    int? afterSequence,
    String? partialMarkdown,
    bool? partialIsComplete,
    Object? finalMarkdown = _unset,
    Object? failureCode = _unset,
    bool? failureRetryable,
    DateTime? updatedAt,
  }) {
    return ScriptDraftGenerationReceipt(
      sessionId: sessionId,
      source: source,
      createThreadIdempotencyKey: createThreadIdempotencyKey,
      messageIdempotencyKey: messageIdempotencyKey,
      cancelIdempotencyKey: cancelIdempotencyKey,
      phase: phase ?? this.phase,
      threadId: identical(threadId, _unset)
          ? this.threadId
          : threadId as String?,
      agentRunId: identical(agentRunId, _unset)
          ? this.agentRunId
          : agentRunId as String?,
      afterSequence: afterSequence ?? this.afterSequence,
      partialMarkdown: partialMarkdown ?? this.partialMarkdown,
      partialIsComplete: partialIsComplete ?? this.partialIsComplete,
      finalMarkdown: identical(finalMarkdown, _unset)
          ? this.finalMarkdown
          : finalMarkdown as String?,
      failureCode: identical(failureCode, _unset)
          ? this.failureCode
          : failureCode as String?,
      failureRetryable: failureRetryable ?? this.failureRetryable,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': schemaVersion,
    'sessionId': sessionId,
    'source': source.toJson(),
    'createThreadIdempotencyKey': createThreadIdempotencyKey,
    'messageIdempotencyKey': messageIdempotencyKey,
    'cancelIdempotencyKey': cancelIdempotencyKey,
    'phase': phase.storageValue,
    if (threadId != null) 'threadId': threadId,
    if (agentRunId != null) 'agentRunId': agentRunId,
    'afterSequence': afterSequence,
    'partialMarkdown': partialMarkdown,
    'partialIsComplete': partialIsComplete,
    if (finalMarkdown != null) 'finalMarkdown': finalMarkdown,
    if (failureCode != null) 'failureCode': failureCode,
    'failureRetryable': failureRetryable,
    'updatedAt': updatedAt.toUtc().toIso8601String(),
  };

  void _validate() {
    if (phase == ScriptDraftGenerationPhase.idle) {
      throw ArgumentError('Idle is not a persistable generation phase');
    }
    if (afterSequence < 0) {
      throw ArgumentError.value(
        afterSequence,
        'afterSequence',
        'Sequence must not be negative',
      );
    }
    _optionalText(threadId, 'threadId', maxLength: 256);
    _optionalText(agentRunId, 'agentRunId', maxLength: 256);
    final needsThread = switch (phase) {
      ScriptDraftGenerationPhase.submitting ||
      ScriptDraftGenerationPhase.streaming ||
      ScriptDraftGenerationPhase.ready => true,
      _ => false,
    };
    final needsRun = switch (phase) {
      ScriptDraftGenerationPhase.streaming ||
      ScriptDraftGenerationPhase.ready => true,
      _ => false,
    };
    if (needsThread && threadId == null) {
      throw ArgumentError('Phase ${phase.name} requires a Thread');
    }
    if (needsRun && agentRunId == null) {
      throw ArgumentError('Phase ${phase.name} requires an AgentRun');
    }
    if (agentRunId != null && threadId == null) {
      throw ArgumentError('An AgentRun receipt requires its Thread');
    }
    if (phase == ScriptDraftGenerationPhase.ready) {
      if (finalMarkdown?.trim().isEmpty != false) {
        throw ArgumentError('A ready receipt requires nonempty final Markdown');
      }
    } else if (finalMarkdown != null) {
      throw ArgumentError('Only a ready receipt may contain final Markdown');
    }
    if (phase == ScriptDraftGenerationPhase.failed) {
      _requiredText(failureCode ?? '', 'failureCode', maxLength: 160);
    } else if (failureCode != null || failureRetryable) {
      throw ArgumentError('Failure metadata requires the failed phase');
    }
  }
}

String scriptDraftContentHash(String value) =>
    sha256.convert(utf8.encode(value)).toString();

const Object _unset = Object();

String _requiredText(String value, String field, {required int maxLength}) {
  final trimmed = value.trim();
  if (trimmed.isEmpty || trimmed.length > maxLength) {
    throw ArgumentError.value(value, field, 'Must contain 1-$maxLength chars');
  }
  return value;
}

String? _optionalText(String? value, String field, {required int maxLength}) {
  if (value == null) return null;
  return _requiredText(value, field, maxLength: maxLength);
}

String _jsonString(Map<String, Object?> json, String field) {
  final value = json[field];
  if (value is String) return value;
  throw FormatException('$field must be a string');
}

String? _jsonOptionalString(Map<String, Object?> json, String field) {
  final value = json[field];
  if (value == null) return null;
  if (value is String) return value;
  throw FormatException('$field must be a string or null');
}

bool _jsonBool(Map<String, Object?> json, String field) {
  final value = json[field];
  if (value is bool) return value;
  throw FormatException('$field must be a bool');
}

int _jsonNonNegativeInt(Map<String, Object?> json, String field) {
  final value = json[field];
  if (value is int && value >= 0) return value;
  throw FormatException('$field must be a nonnegative integer');
}

DateTime _jsonDateTime(Map<String, Object?> json, String field) {
  final value = _jsonString(json, field);
  final parsed = DateTime.tryParse(value);
  if (parsed == null) throw FormatException('$field must be an ISO timestamp');
  return parsed;
}
