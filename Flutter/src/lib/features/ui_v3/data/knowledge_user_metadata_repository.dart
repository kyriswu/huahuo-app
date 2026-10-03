import 'dart:convert';

import '../../../core/database/user_metadata_dao.dart';
import '../domain/knowledge_library_models.dart';

final class KnowledgeUserMetadataRepository {
  KnowledgeUserMetadataRepository({
    required UserMetadataDao dao,
    required String userScope,
  }) : _dao = dao,
       _userScope = _normalizeRequired(userScope, 'userScope');

  static const cardDisplayPreferenceKey = 'knowledge_card_display_mode';

  final UserMetadataDao _dao;
  final String _userScope;

  String get userScope => _userScope;

  Map<String, List<String>> loadTagOverrides() {
    final result = <String, List<String>>{};
    for (final record in _dao.listKnowledgeItemUserMetadata(_userScope)) {
      final contentId = '${record['content_id'] ?? ''}'.trim();
      final rawTags = record['custom_tags_json'];
      if (contentId.isEmpty || rawTags is! String) continue;
      try {
        final decoded = jsonDecode(rawTags);
        if (decoded is! List || decoded.any((value) => value is! String)) {
          continue;
        }
        final tags = normalizeKnowledgeTags(decoded.cast<String>());
        if (tags.isNotEmpty) result[contentId] = tags;
      } on FormatException {
        continue;
      } on ArgumentError {
        continue;
      }
    }
    return Map<String, List<String>>.unmodifiable(result);
  }

  void saveTagOverride({
    required String contentId,
    required Iterable<String> tags,
    DateTime? updatedAt,
  }) {
    final id = _normalizeRequired(contentId, 'contentId');
    final normalized = normalizeKnowledgeTags(tags);
    if (normalized.isEmpty) {
      _dao.deleteKnowledgeItemUserMetadata(
        userScope: _userScope,
        contentId: id,
      );
      return;
    }
    _dao.upsertKnowledgeItemUserMetadata(
      userScope: _userScope,
      contentId: id,
      customTagsJson: jsonEncode(normalized),
      updatedAt: (updatedAt ?? DateTime.now()).toUtc().toIso8601String(),
    );
  }

  KnowledgeCardDisplayMode loadCardDisplayMode() {
    for (final record in _dao.listKnowledgeViewPreferences(_userScope)) {
      if (record['preference_key'] != cardDisplayPreferenceKey) continue;
      final rawMode = record['card_mode'];
      if (rawMode is! String) return KnowledgeCardDisplayMode.expanded;
      for (final mode in KnowledgeCardDisplayMode.values) {
        if (mode.name == rawMode) return mode;
      }
      return KnowledgeCardDisplayMode.expanded;
    }
    return KnowledgeCardDisplayMode.expanded;
  }

  void saveCardDisplayMode(
    KnowledgeCardDisplayMode mode, {
    DateTime? updatedAt,
  }) {
    _dao.upsertKnowledgeViewPreference(
      userScope: _userScope,
      preferenceKey: cardDisplayPreferenceKey,
      cardMode: mode.name,
      updatedAt: (updatedAt ?? DateTime.now()).toUtc().toIso8601String(),
    );
  }
}

List<String> normalizeKnowledgeTags(Iterable<String> values) {
  final result = <String>[];
  final seen = <String>{};
  for (final raw in values) {
    final value = raw.trim();
    final length = value.runes.length;
    if (value.isEmpty || length > 24) {
      throw ArgumentError.value(raw, 'tags', 'must contain 1-24 characters');
    }
    if (seen.add(value.toLowerCase())) result.add(value);
  }
  if (result.length > 20) {
    throw ArgumentError.value(values, 'tags', 'must contain at most 20 tags');
  }
  return List<String>.unmodifiable(result);
}

String _normalizeRequired(String value, String name) {
  final normalized = value.trim();
  if (normalized.isEmpty) {
    throw ArgumentError.value(value, name, 'must not be empty');
  }
  return normalized;
}
