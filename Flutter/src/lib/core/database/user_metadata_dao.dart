import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'app_database.dart';

/// Metadata-only storage for user-owned voiceprint names and chat aliases.
final class UserMetadataDao {
  UserMetadataDao(this._database);

  final AppDatabase _database;

  List<LocalDatabaseRecord> listVoiceprintProfiles(String userScope) {
    return _listScoped(LocalTableName.voiceprintProfiles, userScope);
  }

  void upsertVoiceprintProfile({
    required String userScope,
    required String profileId,
    required String name,
    required String enrolledAt,
    required String updatedAt,
    required bool isDemo,
  }) {
    final scope = _normalize(userScope, 'userScope');
    final id = _normalize(profileId, 'profileId');
    _database.upsertRecord(
      LocalTableName.voiceprintProfiles,
      'voiceprint:${_encode(scope)}:${_encode(id)}',
      <String, Object?>{
        'user_scope': scope,
        'profile_id': id,
        'name': name,
        'enrolled_at': enrolledAt,
        'updated_at': updatedAt,
        'is_demo': isDemo,
      },
    );
  }

  bool deleteVoiceprintProfile({
    required String userScope,
    required String profileId,
  }) {
    final scope = _normalize(userScope, 'userScope');
    final id = _normalize(profileId, 'profileId');
    return _database.deleteRecord(
      LocalTableName.voiceprintProfiles,
      'voiceprint:${_encode(scope)}:${_encode(id)}',
    );
  }

  List<LocalDatabaseRecord> listChatThreadAliases(String userScope) {
    return _listScoped(LocalTableName.chatThreadAliases, userScope);
  }

  void upsertChatThreadAlias({
    required String userScope,
    required String scene,
    required String threadId,
    required String alias,
    required String updatedAt,
  }) {
    final scope = _normalize(userScope, 'userScope');
    final normalizedScene = _normalize(scene, 'scene');
    final id = _normalize(threadId, 'threadId');
    _database.upsertRecord(
      LocalTableName.chatThreadAliases,
      'chat-alias:${_encode(scope)}:${_encode(normalizedScene)}:${_encode(id)}',
      <String, Object?>{
        'user_scope': scope,
        'scene': normalizedScene,
        'thread_id': id,
        'alias': alias,
        'updated_at': updatedAt,
      },
    );
  }

  bool deleteChatThreadAlias({
    required String userScope,
    required String scene,
    required String threadId,
  }) {
    final scope = _normalize(userScope, 'userScope');
    final normalizedScene = _normalize(scene, 'scene');
    final id = _normalize(threadId, 'threadId');
    return _database.deleteRecord(
      LocalTableName.chatThreadAliases,
      'chat-alias:${_encode(scope)}:${_encode(normalizedScene)}:${_encode(id)}',
    );
  }

  List<LocalDatabaseRecord> listChatEntryThreadBindings({
    required String userScope,
    required String workspaceScope,
  }) {
    final workspace = _normalize(workspaceScope, 'workspaceScope');
    return List<LocalDatabaseRecord>.unmodifiable(
      _listScoped(
        LocalTableName.chatEntryThreadBindings,
        userScope,
      ).where((record) => record['workspace_scope'] == workspace),
    );
  }

  void upsertChatEntryThreadBinding({
    required String userScope,
    required String workspaceScope,
    required String scene,
    required String entryKind,
    required String entryId,
    required String threadId,
    required String agentProfileId,
    required String boundAt,
    required String lastOpenedAt,
  }) {
    final scope = _normalize(userScope, 'userScope');
    final workspace = _normalize(workspaceScope, 'workspaceScope');
    final normalizedScene = _normalize(scene, 'scene');
    final kind = _normalize(entryKind, 'entryKind');
    final entry = _normalize(entryId, 'entryId');
    final thread = _normalize(threadId, 'threadId');
    _database.upsertRecord(
      LocalTableName.chatEntryThreadBindings,
      _chatEntryBindingRecordKey(
        userScope: scope,
        workspaceScope: workspace,
        scene: normalizedScene,
        entryKind: kind,
        entryId: entry,
        threadId: thread,
      ),
      <String, Object?>{
        'user_scope': scope,
        'workspace_scope': workspace,
        'scene': normalizedScene,
        'entry_kind': kind,
        'entry_id': entry,
        'thread_id': thread,
        'agent_profile_id': _normalize(agentProfileId, 'agentProfileId'),
        'bound_at': _normalize(boundAt, 'boundAt'),
        'last_opened_at': _normalize(lastOpenedAt, 'lastOpenedAt'),
      },
    );
  }

  bool deleteChatEntryThreadBinding({
    required String userScope,
    required String workspaceScope,
    required String scene,
    required String entryKind,
    required String entryId,
    required String threadId,
  }) {
    final scope = _normalize(userScope, 'userScope');
    final workspace = _normalize(workspaceScope, 'workspaceScope');
    final normalizedScene = _normalize(scene, 'scene');
    final kind = _normalize(entryKind, 'entryKind');
    final entry = _normalize(entryId, 'entryId');
    final thread = _normalize(threadId, 'threadId');
    return _database.deleteRecord(
      LocalTableName.chatEntryThreadBindings,
      _chatEntryBindingRecordKey(
        userScope: scope,
        workspaceScope: workspace,
        scene: normalizedScene,
        entryKind: kind,
        entryId: entry,
        threadId: thread,
      ),
    );
  }

  List<LocalDatabaseRecord> listKnowledgeItemUserMetadata(String userScope) {
    return _listScoped(LocalTableName.knowledgeItemUserMetadata, userScope);
  }

  void upsertKnowledgeItemUserMetadata({
    required String userScope,
    required String contentId,
    required String customTagsJson,
    required String updatedAt,
  }) {
    final scope = _normalize(userScope, 'userScope');
    final id = _normalize(contentId, 'contentId');
    _database.upsertRecord(
      LocalTableName.knowledgeItemUserMetadata,
      'knowledge-item:${_encode(scope)}:${_encode(id)}',
      <String, Object?>{
        'user_scope': scope,
        'content_id': id,
        'custom_tags_json': customTagsJson,
        'updated_at': updatedAt,
      },
    );
  }

  bool deleteKnowledgeItemUserMetadata({
    required String userScope,
    required String contentId,
  }) {
    final scope = _normalize(userScope, 'userScope');
    final id = _normalize(contentId, 'contentId');
    return _database.deleteRecord(
      LocalTableName.knowledgeItemUserMetadata,
      'knowledge-item:${_encode(scope)}:${_encode(id)}',
    );
  }

  List<LocalDatabaseRecord> listKnowledgeViewPreferences(String userScope) {
    return _listScoped(LocalTableName.knowledgeViewPreferences, userScope);
  }

  void upsertKnowledgeViewPreference({
    required String userScope,
    required String preferenceKey,
    required String cardMode,
    required String updatedAt,
  }) {
    final scope = _normalize(userScope, 'userScope');
    final key = _normalize(preferenceKey, 'preferenceKey');
    _database.upsertRecord(
      LocalTableName.knowledgeViewPreferences,
      'knowledge-view:${_encode(scope)}:${_encode(key)}',
      <String, Object?>{
        'user_scope': scope,
        'preference_key': key,
        'card_mode': cardMode,
        'updated_at': updatedAt,
      },
    );
  }

  List<LocalDatabaseRecord> _listScoped(
    LocalTableName table,
    String userScope,
  ) {
    final scope = _normalize(userScope, 'userScope');
    return List<LocalDatabaseRecord>.unmodifiable(
      _database
          .listRecords<LocalDatabaseRecord>(table)
          .where((record) => record['user_scope'] == scope),
    );
  }
}

String _normalize(String value, String name) {
  final normalized = value.trim();
  if (normalized.isEmpty) {
    throw ArgumentError.value(value, name, 'must not be empty');
  }
  return normalized;
}

String _encode(String value) =>
    base64Url.encode(utf8.encode(value)).replaceAll('=', '');

String _chatEntryBindingRecordKey({
  required String userScope,
  required String workspaceScope,
  required String scene,
  required String entryKind,
  required String entryId,
  required String threadId,
}) {
  final identity = jsonEncode(<String>[
    userScope,
    workspaceScope,
    scene,
    entryKind,
    entryId,
    threadId,
  ]);
  return 'chat-entry:${sha256.convert(utf8.encode(identity))}';
}
