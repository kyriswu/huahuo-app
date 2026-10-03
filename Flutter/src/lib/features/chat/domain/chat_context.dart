import 'dart:convert';

import 'package:crypto/crypto.dart';

const chatContextSchemaVersion = 'huahuo.chat-context.v1';
const chatLocalDraftAgentEnvelopeSchemaVersion =
    'huahuo.chat-local-draft-agent.v1';
const chatLocalDraftAgentEnvelopeMarker =
    '<<<huahuo.chat-local-draft-agent.v1>>>';
const creationCanvasChatScopeInstruction =
    '范围约束：只基于本轮附带的当前创作文档回答；不要搜索、读取、引用或比较 Workspace 中其他笔记、资产或资料。';

enum ChatContextPurpose {
  general('general'),
  deepPositioning('deep_positioning'),
  persona('persona'),
  lead('lead'),
  visualDesign('visual_design'),
  videoAnalysis('video_analysis'),
  socialPositioning('social_positioning'),
  masterpiece('masterpiece');

  const ChatContextPurpose(this.apiValue);

  final String apiValue;

  static ChatContextPurpose? tryParse(Object? value) {
    for (final purpose in values) {
      if (purpose.apiValue == value) return purpose;
    }
    return null;
  }
}

enum ChatContextReferenceType {
  memoryNote('memory_note'),
  feedItem('feed_item'),
  material('material'),
  file('file'),
  image('image'),
  asset('asset'),
  recording('recording');

  const ChatContextReferenceType(this.apiValue);

  final String apiValue;

  static ChatContextReferenceType? tryParse(Object? value) {
    for (final type in values) {
      if (type.apiValue == value) return type;
    }
    return null;
  }
}

final class ChatContextReference {
  const ChatContextReference({
    required this.type,
    required this.id,
    this.revision,
  });

  final ChatContextReferenceType type;
  final String id;
  final String? revision;

  bool get isValid =>
      isSafeChatContextIdentifier(id) &&
      (revision == null || isSafeChatContextIdentifier(revision!));

  Map<String, Object?> toJson() => <String, Object?>{
    'type': type.apiValue,
    'id': id,
    if (revision != null) 'revision': revision,
  };

  static ChatContextReference? tryParse(Object? raw) {
    final object = _asObjectMap(raw);
    final type = ChatContextReferenceType.tryParse(object?['type']);
    final id = object?['id'];
    final revision = object?['revision'];
    if (type == null ||
        id is! String ||
        (revision != null && revision is! String)) {
      return null;
    }
    final reference = ChatContextReference(
      type: type,
      id: id,
      revision: revision as String?,
    );
    return reference.isValid ? reference : null;
  }
}

final class ChatContextEntryPoint {
  const ChatContextEntryPoint({
    required this.surface,
    this.entityType,
    this.entityId,
  });

  final String surface;
  final String? entityType;
  final String? entityId;

  bool get isValid {
    if (!isSafeChatContextIdentifier(surface)) return false;
    if ((entityType == null) != (entityId == null)) return false;
    return entityType == null ||
        (isSafeChatContextIdentifier(entityType!) &&
            isSafeChatContextIdentifier(entityId!));
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'surface': surface,
    if (entityType != null) 'entityType': entityType,
    if (entityId != null) 'entityId': entityId,
  };
}

final class ChatLocalDraftSnapshot {
  const ChatLocalDraftSnapshot._({
    required this.kind,
    required this.content,
    required this.revision,
    required this.contentSha256,
  });

  static const maxContentLength = 12000;

  final String kind;
  final String content;
  final String revision;
  final String contentSha256;

  static ChatLocalDraftSnapshot? create({
    required String kind,
    required String content,
    required String revision,
  }) {
    final normalizedKind = kind.trim();
    final normalizedRevision = revision.trim();
    final normalizedContent = content.trim();
    if (!isSafeChatContextIdentifier(normalizedKind) ||
        !isSafeChatContextIdentifier(normalizedRevision) ||
        normalizedContent.isEmpty ||
        normalizedContent.length > maxContentLength ||
        containsUnsafeChatContext(normalizedContent)) {
      return null;
    }
    return ChatLocalDraftSnapshot._(
      kind: normalizedKind,
      content: normalizedContent,
      revision: normalizedRevision,
      contentSha256: sha256.convert(utf8.encode(normalizedContent)).toString(),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': kind,
    'content': content,
    'revision': revision,
    'contentSha256': contentSha256,
  };

  String toAgentTextPart() {
    final metadata = jsonEncode(<String, Object?>{
      'schemaVersion': chatLocalDraftAgentEnvelopeSchemaVersion,
      'usage': 'reference',
      'kind': kind,
      'revision': revision,
      'contentLength': content.length,
      'contentSha256': contentSha256,
    });
    return '$chatLocalDraftAgentEnvelopeMarker\n$metadata\n$content';
  }
}

/// Removes a validated local-draft Agent envelope from message/title read-back.
///
/// Full messages require exact metadata, length, and digest agreement. The
/// backend's single-line bounded title preview can retain only the marker and
/// a prefix of the schema metadata; that exact preview form is also recognized.
/// Other malformed or marker-like text is returned exactly as received.
String projectChatLocalDraftUserPrompt(String rawText) {
  var markerOffset = rawText.indexOf(chatLocalDraftAgentEnvelopeMarker);
  while (markerOffset >= 0) {
    final projected = _tryProjectChatLocalDraftEnvelope(
      rawText,
      markerOffset: markerOffset,
    );
    if (projected != null) return projected;
    markerOffset = rawText.indexOf(
      chatLocalDraftAgentEnvelopeMarker,
      markerOffset + chatLocalDraftAgentEnvelopeMarker.length,
    );
  }
  return rawText;
}

/// Projects the creation Canvas transport prompt to user-authored text only.
String projectCreationCanvasChatUserPrompt(String rawText) {
  final projected = projectChatLocalDraftUserPrompt(rawText);
  if (projected == creationCanvasChatScopeInstruction) return '';
  for (final separator in const <String>['\n\n', ' ']) {
    final prefix = '$creationCanvasChatScopeInstruction$separator';
    if (projected.startsWith(prefix)) {
      return projected.substring(prefix.length);
    }
  }
  return projected;
}

String? _tryProjectChatLocalDraftEnvelope(
  String rawText, {
  required int markerOffset,
}) {
  final metadataStart = markerOffset + chatLocalDraftAgentEnvelopeMarker.length;
  if (metadataStart >= rawText.length || rawText[metadataStart] != '\n') {
    return _projectCollapsedLocalDraftTitlePreview(
      rawText,
      markerOffset: markerOffset,
      metadataStart: metadataStart,
    );
  }
  final metadataEnd = rawText.indexOf('\n', metadataStart + 1);
  if (metadataEnd < 0) return null;

  Map<String, Object?>? metadata;
  try {
    metadata = _asObjectMap(
      jsonDecode(rawText.substring(metadataStart + 1, metadataEnd)),
    );
  } catch (_) {
    return null;
  }
  final kind = metadata?['kind'];
  final revision = metadata?['revision'];
  final contentLength = metadata?['contentLength'];
  final expectedDigest = metadata?['contentSha256'];
  if (metadata?['schemaVersion'] != chatLocalDraftAgentEnvelopeSchemaVersion ||
      metadata?['usage'] != 'reference' ||
      kind is! String ||
      revision is! String ||
      contentLength is! int ||
      expectedDigest is! String) {
    return null;
  }
  final body = rawText.substring(metadataEnd + 1);
  final snapshot = ChatLocalDraftSnapshot.create(
    kind: kind,
    content: body,
    revision: revision,
  );
  if (snapshot == null ||
      body.length != contentLength ||
      snapshot.content != body ||
      snapshot.contentSha256 != expectedDigest) {
    return null;
  }
  return rawText.substring(0, markerOffset).trim();
}

String? _projectCollapsedLocalDraftTitlePreview(
  String rawText, {
  required int markerOffset,
  required int metadataStart,
}) {
  if (metadataStart >= rawText.length) return null;
  final suffix = rawText.substring(metadataStart).trimLeft();
  if (suffix.isEmpty || suffix.contains('\n') || suffix.contains('\r')) {
    return null;
  }
  const schemaPrefix =
      '{"schemaVersion":"$chatLocalDraftAgentEnvelopeSchemaVersion"';
  if (!schemaPrefix.startsWith(suffix) && !suffix.startsWith(schemaPrefix)) {
    return null;
  }
  return rawText.substring(0, markerOffset).trim();
}

final class ChatContextEnvelope {
  ChatContextEnvelope._({
    required this.purpose,
    required this.references,
    required this.includeAccountProfile,
    this.contentLineId,
    this.entryPoint,
    this.localDraftSnapshot,
  });

  final String schemaVersion = chatContextSchemaVersion;
  final ChatContextPurpose purpose;
  final String? contentLineId;
  final ChatContextEntryPoint? entryPoint;
  final List<ChatContextReference> references;
  final bool includeAccountProfile;
  final ChatLocalDraftSnapshot? localDraftSnapshot;

  static ChatContextEnvelope? create({
    required ChatContextPurpose purpose,
    String? contentLineId,
    ChatContextEntryPoint? entryPoint,
    Iterable<ChatContextReference> references = const <ChatContextReference>[],
    bool includeAccountProfile = false,
    ChatLocalDraftSnapshot? localDraftSnapshot,
  }) {
    final normalizedContentLineId = contentLineId?.trim();
    if (normalizedContentLineId != null &&
        !isSafeChatContextIdentifier(normalizedContentLineId)) {
      return null;
    }
    if (entryPoint != null && !entryPoint.isValid) return null;
    final deduplicated = <String, ChatContextReference>{};
    for (final reference in references) {
      if (!reference.isValid) return null;
      deduplicated.putIfAbsent(
        '${reference.type.apiValue}:${reference.id}',
        () => reference,
      );
    }
    if (deduplicated.length > 50) return null;
    return ChatContextEnvelope._(
      purpose: purpose,
      contentLineId: normalizedContentLineId,
      entryPoint: entryPoint,
      references: List<ChatContextReference>.unmodifiable(deduplicated.values),
      includeAccountProfile: includeAccountProfile,
      localDraftSnapshot: localDraftSnapshot,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': schemaVersion,
    'purpose': purpose.apiValue,
    if (contentLineId != null) 'contentLineId': contentLineId,
    if (entryPoint != null) 'entryPoint': entryPoint!.toJson(),
    'references': <Object?>[
      for (final reference in references) reference.toJson(),
    ],
    'includeAccountProfile': includeAccountProfile,
    if (localDraftSnapshot != null)
      'localDraftSnapshot': localDraftSnapshot!.toJson(),
  };
}

final class ChatAcceptedContext {
  const ChatAcceptedContext({
    required this.purpose,
    required this.references,
    this.localDraftSha256,
  });

  final String schemaVersion = chatContextSchemaVersion;
  final ChatContextPurpose purpose;
  final List<ChatContextReference> references;
  final String? localDraftSha256;

  bool accepts(ChatContextEnvelope requested) {
    if (purpose != requested.purpose) return false;
    for (final expected in requested.references) {
      final accepted = references.any(
        (candidate) =>
            candidate.type == expected.type &&
            candidate.id == expected.id &&
            (expected.revision == null ||
                candidate.revision == expected.revision),
      );
      if (!accepted) return false;
    }
    final snapshot = requested.localDraftSnapshot;
    return snapshot == null || snapshot.contentSha256 == localDraftSha256;
  }

  static ChatAcceptedContext? tryParse(Object? raw) {
    final object = _asObjectMap(raw);
    if (object == null || object['schemaVersion'] != chatContextSchemaVersion) {
      return null;
    }
    final purpose = ChatContextPurpose.tryParse(object['purpose']);
    final rawReferences = object['references'];
    if (purpose == null || rawReferences is! List) return null;
    final references = <ChatContextReference>[];
    for (final rawReference in rawReferences) {
      final reference = ChatContextReference.tryParse(rawReference);
      if (reference == null) return null;
      references.add(reference);
    }
    final digest = object['localDraftSha256'];
    if (digest != null &&
        (digest is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(digest))) {
      return null;
    }
    return ChatAcceptedContext(
      purpose: purpose,
      references: List<ChatContextReference>.unmodifiable(references),
      localDraftSha256: digest as String?,
    );
  }
}

bool isSafeChatContextIdentifier(String value) =>
    RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$').hasMatch(value);

bool containsUnsafeChatContext(String value) => <RegExp>[
  RegExp(r'file://', caseSensitive: false),
  RegExp(r'(^|\s)/(?:Users|home|private|var)/', caseSensitive: false),
  RegExp(
    r'https?://[^\s]*(?:token|signature|x-amz-[^=]*)=',
    caseSensitive: false,
  ),
  RegExp(r'(?:access|refresh)[_-]?token\s*[:=]', caseSensitive: false),
  RegExp(r'(?:secret|api[_-]?key)\s*[:=]', caseSensitive: false),
].any((pattern) => pattern.hasMatch(value));

Map<String, Object?>? _asObjectMap(Object? value) {
  if (value is! Map) return null;
  final result = <String, Object?>{};
  for (final entry in value.entries) {
    if (entry.key is! String) return null;
    result[entry.key as String] = entry.value;
  }
  return result;
}
