import 'package:flutter/foundation.dart';

import 'feed_item_models.dart';

enum KnowledgeExportFormat { markdown, pdf, archive }

extension KnowledgeExportFormatX on KnowledgeExportFormat {
  String get extension => switch (this) {
    KnowledgeExportFormat.markdown => 'md',
    KnowledgeExportFormat.pdf => 'pdf',
    KnowledgeExportFormat.archive => 'zip',
  };

  String get mimeType => switch (this) {
    KnowledgeExportFormat.markdown => 'text/markdown',
    KnowledgeExportFormat.pdf => 'application/pdf',
    KnowledgeExportFormat.archive => 'application/zip',
  };

  String get label => switch (this) {
    KnowledgeExportFormat.markdown => 'Markdown',
    KnowledgeExportFormat.pdf => 'PDF',
    KnowledgeExportFormat.archive => 'ZIP',
  };
}

@immutable
final class KnowledgeExportDocument {
  KnowledgeExportDocument({
    required String title,
    required String sourceLabel,
    required this.updatedAt,
    Iterable<String> tags = const <String>[],
    Iterable<String> attachmentDisplayNames = const <String>[],
    String rawBody = '',
    String summaryBody = '',
    String sproutBody = '',
    String? publicUrl,
    String? documentId,
    int? revision,
  }) : title = _boundedLine(_redactPrivateLocators(title), 120, '未命名知识'),
       sourceLabel = _boundedLine(
         _redactPrivateLocators(sourceLabel),
         80,
         '其他',
       ),
       tags = List<String>.unmodifiable(_normalizedTags(tags)),
       attachmentDisplayNames = List<String>.unmodifiable(
         _normalizedAttachmentNames(attachmentDisplayNames),
       ),
       rawBody = _redactPrivateLocators(rawBody).trim(),
       summaryBody = _redactPrivateLocators(summaryBody).trim(),
       sproutBody = _redactPrivateLocators(sproutBody).trim(),
       publicUrl = _validatedPublicUrl(publicUrl),
       documentId = _validatedDocumentId(documentId),
       revision = revision != null && revision >= 0 ? revision : null;

  factory KnowledgeExportDocument.fromNote(
    V3FeedItem note, {
    required String sourceLabel,
    List<String>? effectiveTags,
    String? publicUrl,
  }) {
    final sproutReport = note.sproutReport?.markdown.trim();
    final sproutTopic = note.sproutTopic?.trim();
    return KnowledgeExportDocument(
      title: note.title,
      sourceLabel: sourceLabel.trim().isEmpty ? note.source.label : sourceLabel,
      updatedAt: note.updatedAt,
      tags: effectiveTags ?? note.topics,
      attachmentDisplayNames: note.mediaAttachments.map(
        (attachment) => attachment.displayName,
      ),
      rawBody: note.rawBody,
      summaryBody: note.summaryBody ?? '',
      sproutBody: sproutReport?.isNotEmpty == true
          ? sproutReport!
          : sproutTopic ?? '',
      publicUrl: publicUrl,
      documentId: note.id,
      revision: note.updatedAt.toUtc().microsecondsSinceEpoch,
    );
  }

  final String title;
  final String sourceLabel;
  final DateTime updatedAt;
  final List<String> tags;
  final List<String> attachmentDisplayNames;
  final String rawBody;
  final String summaryBody;
  final String sproutBody;
  final String? publicUrl;
  final String? documentId;
  final int? revision;
}

@immutable
final class KnowledgeSharePayload {
  const KnowledgeSharePayload._({required this.text, this.publicUrl});

  factory KnowledgeSharePayload.fromNote(
    V3FeedItem note, {
    required String sourceLabel,
    List<String>? effectiveTags,
    String? publicUrl,
  }) {
    return KnowledgeSharePayload.fromDocument(
      KnowledgeExportDocument.fromNote(
        note,
        sourceLabel: sourceLabel,
        effectiveTags: effectiveTags,
        publicUrl: publicUrl,
      ),
    );
  }

  factory KnowledgeSharePayload.fromDocument(KnowledgeExportDocument document) {
    final preferredExcerpt = document.summaryBody.isNotEmpty
        ? document.summaryBody
        : document.rawBody;
    final excerpt = _boundedText(
      preferredExcerpt.replaceAll(RegExp(r'\s+'), ' ').trim(),
      600,
    );
    final lines = <String>[
      document.title,
      '来源：${document.sourceLabel}',
      if (excerpt.isNotEmpty) excerpt,
      if (document.publicUrl case final url?) url,
    ];
    return KnowledgeSharePayload._(
      text: _redactPrivateLocators(lines.join('\n\n')).trim(),
      publicUrl: document.publicUrl,
    );
  }

  final String text;
  final String? publicUrl;
}

@immutable
final class PreparedKnowledgeExport {
  const PreparedKnowledgeExport({
    required this.opaqueExportRef,
    required this.displayName,
    required this.mimeType,
    required this.sizeBytes,
    required this.format,
  });

  final String opaqueExportRef;
  final String displayName;
  final String mimeType;
  final int sizeBytes;
  final KnowledgeExportFormat format;
}

@immutable
final class KnowledgeExportFailure {
  const KnowledgeExportFailure({required this.code, required this.message});

  final String code;
  final String message;
}

@immutable
final class KnowledgeExportResult<T> {
  const KnowledgeExportResult._({required this.ok, this.value, this.error});

  factory KnowledgeExportResult.success(T value) =>
      KnowledgeExportResult<T>._(ok: true, value: value);

  factory KnowledgeExportResult.failure(KnowledgeExportFailure error) =>
      KnowledgeExportResult<T>._(ok: false, error: error);

  final bool ok;
  final T? value;
  final KnowledgeExportFailure? error;
}

Iterable<String> _normalizedTags(Iterable<String> values) sync* {
  final seen = <String>{};
  for (final value in values) {
    final cleaned = _boundedLine(_redactPrivateLocators(value), 24, '');
    final key = cleaned.toLowerCase();
    if (cleaned.isNotEmpty && seen.add(key)) yield cleaned;
  }
}

Iterable<String> _normalizedAttachmentNames(Iterable<String> values) sync* {
  final seen = <String>{};
  for (final value in values) {
    final candidate = value.trim();
    if (candidate.isEmpty ||
        candidate.contains('/') ||
        candidate.contains('\\') ||
        _containsPrivateLocator(candidate)) {
      continue;
    }
    final cleaned = _boundedLine(candidate, 96, '');
    final key = cleaned.toLowerCase();
    if (cleaned.isNotEmpty && seen.add(key)) yield cleaned;
  }
}

String _boundedLine(String value, int maxRunes, String fallback) {
  final normalized = value.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (normalized.isEmpty) return fallback;
  return _boundedText(normalized, maxRunes);
}

String _boundedText(String value, int maxRunes) {
  final runes = value.runes.toList(growable: false);
  if (runes.length <= maxRunes) return value;
  return '${String.fromCharCodes(runes.take(maxRunes - 1))}…';
}

String? _validatedPublicUrl(String? value) {
  final text = value?.trim();
  if (text == null || text.isEmpty || text.length > 2048) return null;
  final uri = Uri.tryParse(text);
  if (uri == null ||
      !uri.isAbsolute ||
      (uri.scheme.toLowerCase() != 'http' &&
          uri.scheme.toLowerCase() != 'https') ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    return null;
  }
  return uri.toString();
}

String? _validatedDocumentId(String? value) {
  final text = value?.trim();
  if (text == null ||
      !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,159}$').hasMatch(text)) {
    return null;
  }
  return text;
}

bool _containsPrivateLocator(String value) {
  return _privateLocatorPattern.hasMatch(value);
}

String _redactPrivateLocators(String value) {
  return value.replaceAll(_privateLocatorPattern, '[已隐藏私有路径]');
}

final RegExp _privateLocatorPattern = RegExp(
  r'(?:(?:file|app-private(?:-export)?):/{1,3}|/(?:Users|private/var|var/mobile|data/user|data/data)/|[A-Za-z]:\\)[^\s\]\[<>()]+',
  caseSensitive: false,
);
