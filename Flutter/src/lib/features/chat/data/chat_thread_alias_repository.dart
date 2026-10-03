import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../../core/database/app_preferences_dao.dart';
import '../../../core/database/user_metadata_dao.dart';
import '../domain/chat_models.dart';

const _conversationCacheThreadLimit = 50;
const _conversationCacheMessageThreadLimit = 5;
const _conversationCacheMessagesPerThreadLimit = 100;

final class ChatThreadAlias {
  const ChatThreadAlias({
    required this.scene,
    required this.threadId,
    required this.alias,
    required this.updatedAt,
  });

  final ChatScene scene;
  final String threadId;
  final String alias;
  final DateTime updatedAt;
}

/// Immutable, public display metadata for a daily recommendation thread.
final class ChatDailyTopicContext {
  const ChatDailyTopicContext({
    required this.scene,
    required this.threadId,
    required this.title,
    required this.updatedAt,
  });

  final ChatScene scene;
  final String threadId;
  final String title;
  final DateTime updatedAt;
}

final class OrdinaryChatThreadBinding {
  const OrdinaryChatThreadBinding({
    required this.workspaceScope,
    required this.scene,
    required this.entryPoint,
    required this.threadId,
    required this.boundAt,
    required this.lastOpenedAt,
  });

  final String workspaceScope;
  final ChatScene scene;
  final OrdinaryChatEntryPoint entryPoint;
  final String threadId;
  final DateTime boundAt;
  final DateTime lastOpenedAt;
}

/// Public, server-confirmed display data retained only to make the next chat
/// entry responsive. It intentionally has no request, authentication, or URL
/// fields.
final class CachedChatConversation {
  const CachedChatConversation({
    required this.savedAt,
    required this.threads,
    required this.messagesByThread,
    this.historySyncedAt,
    this.historyComplete = false,
    this.detailSyncedAtByThread = const <String, DateTime>{},
  });

  final DateTime savedAt;
  final List<ChatThread> threads;
  final Map<String, List<ChatMessage>> messagesByThread;
  final DateTime? historySyncedAt;
  final bool historyComplete;
  final Map<String, DateTime> detailSyncedAtByThread;
}

final class ChatThreadAliasRepository {
  ChatThreadAliasRepository({
    required UserMetadataDao dao,
    required AppPreferencesDao preferencesDao,
    required String userScope,
    String? workspaceScope,
  }) : // Public collaborator names intentionally omit private field prefixes.
       // ignore: prefer_initializing_formals
       _dao = dao,
       // ignore: prefer_initializing_formals
       _preferencesDao = preferencesDao,
       _userScope = _normalize(userScope, 'userScope'),
       _workspaceScope = workspaceScope == null
           ? null
           : _normalize(workspaceScope, 'workspaceScope'),
       _purposePreferenceKey = _purposeKey(userScope),
       _conversationCachePreferenceKey = _conversationCacheKey(userScope),
       _hiddenThreadsPreferenceKey = _hiddenThreadsKey(userScope),
       _agentProfilePreferenceKey = _agentProfileKey(userScope),
       _dailyTopicContextPreferenceKey = _dailyTopicContextKey(userScope),
       _threadAssetContextPreferenceKey = _threadAssetContextKey(userScope);

  final UserMetadataDao _dao;
  final AppPreferencesDao _preferencesDao;
  final String _userScope;
  final String? _workspaceScope;
  final String _purposePreferenceKey;
  final String _conversationCachePreferenceKey;
  final String _hiddenThreadsPreferenceKey;
  final String _agentProfilePreferenceKey;
  final String _dailyTopicContextPreferenceKey;
  final String _threadAssetContextPreferenceKey;

  String? get workspaceScope => _workspaceScope;

  List<ChatThreadAlias> loadAliases(ChatScene scene) {
    return List<ChatThreadAlias>.unmodifiable([
      for (final record in _dao.listChatThreadAliases(_userScope))
        if (_aliasFromRecord(record) case final alias?)
          if (alias.scene == scene) alias,
    ]);
  }

  String? aliasFor(ChatScene scene, String threadId) {
    for (final alias in loadAliases(scene)) {
      if (alias.threadId == threadId) return alias.alias;
    }
    return null;
  }

  void saveAlias({
    required ChatScene scene,
    required String threadId,
    required String alias,
    DateTime? updatedAt,
  }) {
    if (!isSafeChatIdentifier(threadId)) {
      throw ArgumentError.value(threadId, 'threadId', 'unsafe identifier');
    }
    final normalized = normalizeChatThreadAlias(alias);
    if (normalized == null) {
      throw ArgumentError.value(alias, 'alias', 'must contain 1-60 characters');
    }
    _dao.upsertChatThreadAlias(
      userScope: _userScope,
      scene: scene.apiValue,
      threadId: threadId,
      alias: normalized,
      updatedAt: (updatedAt ?? DateTime.now()).toUtc().toIso8601String(),
    );
  }

  void deleteAlias({required ChatScene scene, required String threadId}) {
    if (!isSafeChatIdentifier(threadId)) {
      throw ArgumentError.value(threadId, 'threadId', 'unsafe identifier');
    }
    _dao.deleteChatThreadAlias(
      userScope: _userScope,
      scene: scene.apiValue,
      threadId: threadId,
    );
  }

  List<OrdinaryChatThreadBinding> ordinaryThreadBindingsFor({
    required ChatScene scene,
    required OrdinaryChatEntryPoint entryPoint,
  }) {
    if (scene != ChatScene.feedAi) return const <OrdinaryChatThreadBinding>[];
    final workspaceScope = _workspaceScope;
    if (workspaceScope == null) return const <OrdinaryChatThreadBinding>[];
    final bindings =
        <OrdinaryChatThreadBinding>[
          for (final record in _dao.listChatEntryThreadBindings(
            userScope: _userScope,
            workspaceScope: workspaceScope,
          ))
            if (_ordinaryChatBindingFromRecord(record) case final binding?)
              if (binding.workspaceScope == workspaceScope &&
                  binding.scene == scene &&
                  binding.entryPoint == entryPoint)
                binding,
        ]..sort((left, right) {
          final openedOrder = right.lastOpenedAt.compareTo(left.lastOpenedAt);
          return openedOrder == 0
              ? left.threadId.compareTo(right.threadId)
              : openedOrder;
        });
    return List<OrdinaryChatThreadBinding>.unmodifiable(bindings);
  }

  void markOrdinaryThreadOpened({
    required ChatScene scene,
    required OrdinaryChatEntryPoint entryPoint,
    required String threadId,
    required String agentProfileId,
    DateTime? openedAt,
  }) {
    if (scene != ChatScene.feedAi) {
      throw ArgumentError.value(scene, 'scene', 'ordinary Chat uses feed_ai');
    }
    final id = threadId.trim();
    if (!isSafeChatIdentifier(id)) {
      throw ArgumentError.value(threadId, 'threadId', 'unsafe identifier');
    }
    if (agentProfileId.trim() != standardCreationChatAgentProfileId) {
      throw ArgumentError.value(
        agentProfileId,
        'agentProfileId',
        'ordinary Chat requires the standard public Agent Profile',
      );
    }
    final workspaceScope = _workspaceScope;
    if (workspaceScope == null) {
      throw StateError('ordinary Chat requires a ready Workspace scope');
    }
    var timestamp = (openedAt ?? DateTime.now()).toUtc();
    DateTime? boundAt;
    final existingBindings = ordinaryThreadBindingsFor(
      scene: scene,
      entryPoint: entryPoint,
    );
    for (final binding in existingBindings) {
      if (binding.threadId == id) {
        boundAt = binding.boundAt;
      }
      if (!timestamp.isAfter(binding.lastOpenedAt)) {
        timestamp = binding.lastOpenedAt.add(const Duration(microseconds: 1));
      }
    }
    _dao.upsertChatEntryThreadBinding(
      userScope: _userScope,
      workspaceScope: workspaceScope,
      scene: scene.apiValue,
      entryKind: entryPoint.kind.storageValue,
      entryId: entryPoint.entryId,
      threadId: id,
      agentProfileId: standardCreationChatAgentProfileId,
      boundAt: (boundAt ?? timestamp).toIso8601String(),
      lastOpenedAt: timestamp.toIso8601String(),
    );
  }

  void removeOrdinaryThreadBinding({
    required ChatScene scene,
    required OrdinaryChatEntryPoint entryPoint,
    required String threadId,
  }) {
    if (scene != ChatScene.feedAi || !isSafeChatIdentifier(threadId.trim())) {
      return;
    }
    final workspaceScope = _workspaceScope;
    if (workspaceScope == null) return;
    _dao.deleteChatEntryThreadBinding(
      userScope: _userScope,
      workspaceScope: workspaceScope,
      scene: scene.apiValue,
      entryKind: entryPoint.kind.storageValue,
      entryId: entryPoint.entryId,
      threadId: threadId.trim(),
    );
  }

  /// Hides a server thread only in this account's local history. The server
  /// record and any accepted Agent Run remain untouched.
  void hideThread({required ChatScene scene, required String threadId}) {
    if (!isSafeChatIdentifier(threadId)) {
      throw ArgumentError.value(threadId, 'threadId', 'unsafe identifier');
    }
    final payload = _loadHiddenThreadsPayload();
    final hidden = _mutableHiddenThreadEntries(payload);
    final key = scene.apiValue;
    final current = <String>{
      for (final value in hidden[key] ?? const <Object?>[])
        if (value is String && isSafeChatIdentifier(value.trim())) value.trim(),
    }..add(threadId);
    hidden[key] = current.toList(growable: false);
    payload
      ..['version'] = 1
      ..['hidden'] = hidden;
    _preferencesDao.upsertValue(
      preferenceKey: _hiddenThreadsPreferenceKey,
      value: jsonEncode(payload),
      updatedAt: DateTime.now().toUtc().toIso8601String(),
    );
  }

  void restoreThread({required ChatScene scene, required String threadId}) {
    if (!isSafeChatIdentifier(threadId)) {
      throw ArgumentError.value(threadId, 'threadId', 'unsafe identifier');
    }
    final payload = _loadHiddenThreadsPayload();
    final hidden = _mutableHiddenThreadEntries(payload);
    final key = scene.apiValue;
    final remaining = <String>[
      for (final value in hidden[key] ?? const <Object?>[])
        if (value is String &&
            isSafeChatIdentifier(value.trim()) &&
            value.trim() != threadId)
          value.trim(),
    ];
    if (remaining.isEmpty) {
      hidden.remove(key);
    } else {
      hidden[key] = remaining;
    }
    payload
      ..['version'] = 1
      ..['hidden'] = hidden;
    _preferencesDao.upsertValue(
      preferenceKey: _hiddenThreadsPreferenceKey,
      value: jsonEncode(payload),
      updatedAt: DateTime.now().toUtc().toIso8601String(),
    );
  }

  bool isThreadHidden({required ChatScene scene, required String threadId}) {
    if (!isSafeChatIdentifier(threadId)) return false;
    final hidden = _loadHiddenThreadsPayload()['hidden'];
    if (hidden is! Map) return false;
    final values = hidden[scene.apiValue];
    if (values is! List) return false;
    return values.any((value) => value is String && value.trim() == threadId);
  }

  /// Saves the public Profile that admitted this thread. It is local
  /// display/request provenance, never an internal Agent or Skill selection.
  void saveAgentProfile({
    required ChatScene scene,
    required String threadId,
    required String agentProfileId,
    DateTime? updatedAt,
  }) {
    if (!isSafeChatIdentifier(threadId)) {
      throw ArgumentError.value(threadId, 'threadId', 'unsafe identifier');
    }
    final profile = _safeAgentProfileId(agentProfileId);
    if (profile == null) {
      throw ArgumentError.value(
        agentProfileId,
        'agentProfileId',
        'unsafe public agent profile identifier',
      );
    }
    final payload = _loadAgentProfilePayload();
    final profiles = _mutableAgentProfileEntries(payload)
      ..[_agentProfileEntryKey(scene, threadId)] = profile;
    final savedAt = (updatedAt ?? DateTime.now()).toUtc().toIso8601String();
    payload
      ..['version'] = 1
      ..['profiles'] = profiles;
    _preferencesDao.upsertValue(
      preferenceKey: _agentProfilePreferenceKey,
      value: jsonEncode(payload),
      updatedAt: savedAt,
    );
  }

  String? agentProfileFor({
    required ChatScene scene,
    required String threadId,
  }) {
    if (!isSafeChatIdentifier(threadId)) return null;
    final profiles = _loadAgentProfilePayload()['profiles'];
    if (profiles is! Map) return null;
    return _safeAgentProfileId(
      profiles[_agentProfileEntryKey(scene, threadId)],
    );
  }

  /// The first public topic title attached to a thread remains stable. A
  /// later route cannot relabel a server-bound recommendation conversation.
  void saveDailyTopicContext({
    required ChatScene scene,
    required String threadId,
    required String title,
    DateTime? updatedAt,
  }) {
    if (!isSafeChatIdentifier(threadId)) {
      throw ArgumentError.value(threadId, 'threadId', 'unsafe identifier');
    }
    final normalizedTitle = _dailyTopicTitle(title);
    if (normalizedTitle == null) {
      throw ArgumentError.value(title, 'title', 'must be visible public text');
    }
    final payload = _loadDailyTopicContextPayload();
    final contexts = _mutableDailyTopicContextEntries(payload);
    final key = _dailyTopicContextEntryKey(scene, threadId);
    if (_dailyTopicContextFromValue(
          contexts[key],
          scene: scene,
          threadId: threadId,
        ) !=
        null) {
      return;
    }
    final savedAt = (updatedAt ?? DateTime.now()).toUtc().toIso8601String();
    contexts[key] = <String, Object?>{
      'title': normalizedTitle,
      'updatedAt': savedAt,
    };
    payload
      ..['version'] = 1
      ..['contexts'] = contexts;
    _preferencesDao.upsertValue(
      preferenceKey: _dailyTopicContextPreferenceKey,
      value: jsonEncode(payload),
      updatedAt: savedAt,
    );
  }

  ChatDailyTopicContext? dailyTopicContextFor({
    required ChatScene scene,
    required String threadId,
  }) {
    if (!isSafeChatIdentifier(threadId)) return null;
    final contexts = _loadDailyTopicContextPayload()['contexts'];
    if (contexts is! Map) return null;
    return _dailyTopicContextFromValue(
      contexts[_dailyTopicContextEntryKey(scene, threadId)],
      scene: scene,
      threadId: threadId,
    );
  }

  void saveThreadAssetReference({
    required ChatScene scene,
    required String threadId,
    required String assetId,
    DateTime? updatedAt,
  }) {
    if (!isSafeChatIdentifier(threadId)) {
      throw ArgumentError.value(threadId, 'threadId', 'unsafe identifier');
    }
    if (!isSafeChatIdentifier(assetId)) {
      throw ArgumentError.value(assetId, 'assetId', 'unsafe identifier');
    }
    final payload = _loadThreadAssetContextPayload();
    final bindings = _mutableThreadAssetContextEntries(payload);
    final savedAt = (updatedAt ?? DateTime.now()).toUtc().toIso8601String();
    bindings[_threadAssetContextEntryKey(scene, threadId)] = assetId;
    payload
      ..['version'] = 1
      ..['bindings'] = bindings;
    _preferencesDao.upsertValue(
      preferenceKey: _threadAssetContextPreferenceKey,
      value: jsonEncode(payload),
      updatedAt: savedAt,
    );
  }

  String? threadAssetReferenceFor({
    required ChatScene scene,
    required String threadId,
  }) {
    if (!isSafeChatIdentifier(threadId)) return null;
    final bindings = _loadThreadAssetContextPayload()['bindings'];
    if (bindings is! Map) return null;
    return _safeIdentifier(
      bindings[_threadAssetContextEntryKey(scene, threadId)],
    );
  }

  void removeThreadAssetReference({
    required ChatScene scene,
    required String threadId,
  }) {
    if (!isSafeChatIdentifier(threadId)) return;
    final payload = _loadThreadAssetContextPayload();
    final bindings = _mutableThreadAssetContextEntries(payload);
    if (bindings.remove(_threadAssetContextEntryKey(scene, threadId)) == null) {
      return;
    }
    final updatedAt = DateTime.now().toUtc().toIso8601String();
    payload
      ..['version'] = 1
      ..['bindings'] = bindings;
    _preferencesDao.upsertValue(
      preferenceKey: _threadAssetContextPreferenceKey,
      value: jsonEncode(payload),
      updatedAt: updatedAt,
    );
  }

  Set<String> threadIdsForPurpose({
    required ChatScene scene,
    required ChatConversationPurpose purpose,
  }) {
    if (purpose == ChatConversationPurpose.general) {
      return const <String>{};
    }
    final entry = _purposeEntry(scene, purpose);
    final ids = entry?['thread_ids'];
    if (ids is! List<Object?>) return const <String>{};
    return Set<String>.unmodifiable(<String>{
      for (final value in ids)
        if (value is String && isSafeChatIdentifier(value.trim())) value.trim(),
    });
  }

  bool isThreadAssignedToNonGeneralPurpose({
    required ChatScene scene,
    required String threadId,
  }) {
    if (!isSafeChatIdentifier(threadId)) return false;
    return ChatConversationPurpose.values
        .where((purpose) => purpose != ChatConversationPurpose.general)
        .any(
          (purpose) => threadIdsForPurpose(
            scene: scene,
            purpose: purpose,
          ).contains(threadId),
        );
  }

  String? recentThreadIdForPurpose({
    required ChatScene scene,
    required ChatConversationPurpose purpose,
  }) {
    final recent = _purposeEntry(scene, purpose)?['recent_thread_id'];
    if (recent is! String || !isSafeChatIdentifier(recent.trim())) return null;
    final normalized = recent.trim();
    if (purpose == ChatConversationPurpose.general) return normalized;
    return threadIdsForPurpose(
          scene: scene,
          purpose: purpose,
        ).contains(normalized)
        ? normalized
        : null;
  }

  void markThreadPurpose({
    required ChatScene scene,
    required String threadId,
    required ChatConversationPurpose purpose,
    DateTime? updatedAt,
  }) {
    if (!isSafeChatIdentifier(threadId)) {
      throw ArgumentError.value(threadId, 'threadId', 'unsafe identifier');
    }
    final payload = _loadPurposePayload();
    final purposes = _mutablePurposeEntries(payload);
    final key = _purposeEntryKey(scene, purpose);
    final existing = purposes[key];
    final ids = purpose == ChatConversationPurpose.general
        ? <String>[threadId]
        : <String>[
            threadId,
            if (existing is Map<String, dynamic> &&
                existing['thread_ids'] is List<Object?>)
              for (final value in existing['thread_ids']! as List<Object?>)
                if (value is String &&
                    isSafeChatIdentifier(value.trim()) &&
                    value.trim() != threadId)
                  value.trim(),
          ];
    final savedAt = (updatedAt ?? DateTime.now()).toUtc().toIso8601String();
    purposes[key] = <String, Object?>{
      'thread_ids': ids,
      'recent_thread_id': threadId,
      'updated_at': savedAt,
    };
    payload['version'] = 1;
    payload['purposes'] = purposes;
    _preferencesDao.upsertValue(
      preferenceKey: _purposePreferenceKey,
      value: jsonEncode(payload),
      updatedAt: savedAt,
    );
  }

  CachedChatConversation? loadConversationCache({
    required ChatScene scene,
    required ChatConversationPurpose purpose,
    String? agentProfileId,
  }) {
    final profile = _safeAgentProfileId(agentProfileId);
    if (agentProfileId != null && profile == null) return null;
    final raw = _preferencesDao.readValue(_conversationCachePreferenceKey);
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final root = Map<String, Object?>.from(decoded);
      final version = root['version'];
      if ((version != 1 && version != 2 && version != 3 && version != 4) ||
          root['conversations'] is! Map) {
        return null;
      }
      final conversations = Map<String, Object?>.from(
        root['conversations'] as Map,
      );
      final scopedKey = _conversationEntryKey(
        scene,
        purpose,
        agentProfileId: profile,
      );
      final legacyKey = _conversationEntryKey(scene, purpose);
      final hasScopedEntry = conversations.containsKey(scopedKey);
      final entry = hasScopedEntry
          ? conversations[scopedKey]
          : profile == null
          ? null
          : conversations[legacyKey];
      if (entry is! Map) return null;
      final migratingLegacyEntry = !hasScopedEntry && profile != null;
      final value = Map<String, Object?>.from(entry);
      final savedAt = _cacheDate(value['savedAt']);
      final rawThreads = value['threads'];
      final rawMessages = value['messages'];
      if (savedAt == null || rawThreads is! List || rawMessages is! Map) {
        return null;
      }
      final threads = <ChatThread>[];
      for (final rawThread in rawThreads) {
        var thread = _threadFromCache(rawThread);
        if (thread == null ||
            thread.scene != scene ||
            thread.purpose != purpose) {
          return null;
        }
        if (profile != null) {
          final threadProfile = _safeAgentProfileId(thread.agentProfileId);
          final isLegacyStandardThread =
              migratingLegacyEntry &&
              profile == standardCreationChatAgentProfileId &&
              purpose == ChatConversationPurpose.general &&
              threadProfile == null;
          if (threadProfile != profile && !isLegacyStandardThread) continue;
          if (isLegacyStandardThread) {
            thread = thread.copyWith(agentProfileId: profile);
          }
        }
        threads.add(thread);
      }
      final threadIds = <String>{for (final thread in threads) thread.threadId};
      final detailSyncedAtByThread = <String, DateTime>{};
      if (value['detailSyncedAt'] case final Map rawDetailSync) {
        for (final entry in rawDetailSync.entries) {
          final threadId = entry.key;
          final syncedAt = _cacheDate(entry.value);
          if (threadId is String &&
              threadIds.contains(threadId) &&
              syncedAt != null) {
            detailSyncedAtByThread[threadId] = syncedAt;
          }
        }
      }
      final messagesByThread = <String, List<ChatMessage>>{};
      for (final entry in Map<String, Object?>.from(rawMessages).entries) {
        if (!isSafeChatIdentifier(entry.key) || entry.value is! List) {
          return null;
        }
        final messages = <ChatMessage>[];
        for (final rawMessage in entry.value as List) {
          final message = _messageFromCache(rawMessage);
          if (message == null ||
              message.threadId != entry.key ||
              message.scene != scene) {
            return null;
          }
          messages.add(message);
        }
        if (threadIds.contains(entry.key)) {
          messagesByThread[entry.key] = List<ChatMessage>.unmodifiable(
            messages,
          );
        }
      }
      return CachedChatConversation(
        savedAt: savedAt,
        threads: List<ChatThread>.unmodifiable(threads),
        messagesByThread: Map<String, List<ChatMessage>>.unmodifiable(
          messagesByThread,
        ),
        historySyncedAt: _cacheDate(value['historySyncedAt']),
        historyComplete: value['historyComplete'] == true,
        detailSyncedAtByThread: Map<String, DateTime>.unmodifiable(
          detailSyncedAtByThread,
        ),
      );
    } catch (_) {
      return null;
    }
  }

  void saveConversationCache({
    required ChatScene scene,
    required ChatConversationPurpose purpose,
    String? agentProfileId,
    required Iterable<ChatThread> threads,
    required Map<String, List<ChatMessage>> messagesByThread,
    DateTime? historySyncedAt,
    bool historyComplete = false,
    Map<String, DateTime> detailSyncedAtByThread = const <String, DateTime>{},
    DateTime? savedAt,
  }) {
    try {
      final write = _prepareConversationCacheWrite(
        scene: scene,
        purpose: purpose,
        agentProfileId: agentProfileId,
        threads: threads,
        messagesByThread: messagesByThread,
        historySyncedAt: historySyncedAt,
        historyComplete: historyComplete,
        detailSyncedAtByThread: detailSyncedAtByThread,
        savedAt: savedAt,
      );
      if (write == null) return;
      _preferencesDao.upsertValue(
        preferenceKey: _conversationCachePreferenceKey,
        value: write.value,
        updatedAt: write.updatedAt,
      );
    } catch (_) {
      // A display cache must never prevent the authenticated conversation flow.
    }
  }

  Future<bool> saveConversationCacheDurably({
    required ChatScene scene,
    required ChatConversationPurpose purpose,
    String? agentProfileId,
    required Iterable<ChatThread> threads,
    required Map<String, List<ChatMessage>> messagesByThread,
    DateTime? historySyncedAt,
    bool historyComplete = false,
    Map<String, DateTime> detailSyncedAtByThread = const <String, DateTime>{},
    DateTime? savedAt,
  }) async {
    try {
      final write = _prepareConversationCacheWrite(
        scene: scene,
        purpose: purpose,
        agentProfileId: agentProfileId,
        threads: threads,
        messagesByThread: messagesByThread,
        historySyncedAt: historySyncedAt,
        historyComplete: historyComplete,
        detailSyncedAtByThread: detailSyncedAtByThread,
        savedAt: savedAt,
      );
      if (write == null) return false;
      await _preferencesDao.upsertValueDeferred(
        preferenceKey: _conversationCachePreferenceKey,
        value: write.value,
        updatedAt: write.updatedAt,
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  ({String value, String updatedAt})? _prepareConversationCacheWrite({
    required ChatScene scene,
    required ChatConversationPurpose purpose,
    String? agentProfileId,
    required Iterable<ChatThread> threads,
    required Map<String, List<ChatMessage>> messagesByThread,
    required DateTime? historySyncedAt,
    required bool historyComplete,
    required Map<String, DateTime> detailSyncedAtByThread,
    required DateTime? savedAt,
  }) {
    final profile = _safeAgentProfileId(agentProfileId);
    if (agentProfileId != null && profile == null) return null;
    final safeThreadsById = <String, ChatThread>{
      for (final thread in threads)
        if (isSafeChatIdentifier(thread.threadId) &&
            thread.scene == scene &&
            thread.purpose == purpose &&
            (profile == null ||
                _safeAgentProfileId(thread.agentProfileId) == profile))
          thread.threadId: _serverConfirmedThread(thread),
    };
    final orderedSafeThreads = safeThreadsById.values.toList()
      ..sort((left, right) {
        final updatedAtOrder = (right.updatedAt?.microsecondsSinceEpoch ?? 0)
            .compareTo(left.updatedAt?.microsecondsSinceEpoch ?? 0);
        return updatedAtOrder == 0
            ? left.threadId.compareTo(right.threadId)
            : updatedAtOrder;
      });
    final safeThreads = orderedSafeThreads
        .take(_conversationCacheThreadLimit)
        .toList(growable: false);
    final threadIds = <String>{
      for (final thread in safeThreads) thread.threadId,
    };
    final messageThreadIds = <String>{
      for (final thread in safeThreads.take(
        _conversationCacheMessageThreadLimit,
      ))
        thread.threadId,
    };
    final safeMessages = <String, List<ChatMessage>>{};
    for (final entry in messagesByThread.entries) {
      if (!messageThreadIds.contains(entry.key) ||
          !isSafeChatIdentifier(entry.key)) {
        continue;
      }
      final messages = <ChatMessage>[
        for (final message in entry.value)
          if (_isCacheableMessage(message, entry.key, scene))
            _cacheableMessage(message),
      ];
      if (messages.isNotEmpty) {
        final firstRetainedIndex =
            messages.length <= _conversationCacheMessagesPerThreadLimit
            ? 0
            : messages.length - _conversationCacheMessagesPerThreadLimit;
        safeMessages[entry.key] = List<ChatMessage>.unmodifiable(
          messages.sublist(firstRetainedIndex),
        );
      }
    }
    final root = _loadConversationCachePayload();
    final conversations = _mutableConversationEntries(root);
    final effectiveSavedAt = (savedAt ?? DateTime.now()).toUtc();
    conversations[_conversationEntryKey(
      scene,
      purpose,
      agentProfileId: profile,
    )] = <String, Object?>{
      'savedAt': effectiveSavedAt.toIso8601String(),
      'threads': safeThreads.map(_threadToCache).toList(growable: false),
      'messages': <String, Object?>{
        for (final entry in safeMessages.entries)
          entry.key: entry.value.map(_messageToCache).toList(growable: false),
      },
      if (historySyncedAt != null)
        'historySyncedAt': historySyncedAt.toUtc().toIso8601String(),
      'historyComplete': historyComplete,
      'detailSyncedAt': <String, String>{
        for (final entry in detailSyncedAtByThread.entries)
          if (threadIds.contains(entry.key))
            entry.key: entry.value.toUtc().toIso8601String(),
      },
    };
    root['version'] = 4;
    root['conversations'] = conversations;
    return (
      value: jsonEncode(root),
      updatedAt: effectiveSavedAt.toIso8601String(),
    );
  }

  Map<String, dynamic>? _purposeEntry(
    ChatScene scene,
    ChatConversationPurpose purpose,
  ) {
    final purposes = _loadPurposePayload()['purposes'];
    if (purposes is! Map<String, dynamic>) return null;
    final entry = purposes[_purposeEntryKey(scene, purpose)];
    return entry is Map<String, dynamic> ? entry : null;
  }

  Map<String, dynamic> _loadPurposePayload() {
    final raw = _preferencesDao.readValue(_purposePreferenceKey);
    if (raw == null) return <String, dynamic>{'version': 1};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic> && decoded['version'] == 1) {
        return Map<String, dynamic>.from(decoded);
      }
    } catch (_) {
      // Invalid local metadata is ignored; server chat data remains untouched.
    }
    return <String, dynamic>{'version': 1};
  }

  Map<String, dynamic> _loadConversationCachePayload() {
    final raw = _preferencesDao.readValue(_conversationCachePreferenceKey);
    if (raw == null) return <String, dynamic>{'version': 1};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map &&
          (decoded['version'] == 1 ||
              decoded['version'] == 2 ||
              decoded['version'] == 3 ||
              decoded['version'] == 4)) {
        return Map<String, dynamic>.from(decoded);
      }
    } catch (_) {
      // Invalid local data is ignored; the server remains authoritative.
    }
    return <String, dynamic>{'version': 1};
  }

  Map<String, dynamic> _loadHiddenThreadsPayload() {
    final raw = _preferencesDao.readValue(_hiddenThreadsPreferenceKey);
    if (raw == null) return <String, dynamic>{'version': 1};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic> && decoded['version'] == 1) {
        return Map<String, dynamic>.from(decoded);
      }
    } catch (_) {
      // Invalid local visibility state cannot affect server history.
    }
    return <String, dynamic>{'version': 1};
  }

  Map<String, dynamic> _loadAgentProfilePayload() {
    final raw = _preferencesDao.readValue(_agentProfilePreferenceKey);
    if (raw == null) return <String, dynamic>{'version': 1};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic> && decoded['version'] == 1) {
        return Map<String, dynamic>.from(decoded);
      }
    } catch (_) {
      // Invalid local provenance cannot alter a remote thread.
    }
    return <String, dynamic>{'version': 1};
  }

  Map<String, dynamic> _loadDailyTopicContextPayload() {
    final raw = _preferencesDao.readValue(_dailyTopicContextPreferenceKey);
    if (raw == null) return <String, dynamic>{'version': 1};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic> && decoded['version'] == 1) {
        return Map<String, dynamic>.from(decoded);
      }
    } catch (_) {
      // Invalid display metadata cannot alter the server thread.
    }
    return <String, dynamic>{'version': 1};
  }

  Map<String, dynamic> _loadThreadAssetContextPayload() {
    final raw = _preferencesDao.readValue(_threadAssetContextPreferenceKey);
    if (raw == null) return <String, dynamic>{'version': 1};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic> && decoded['version'] == 1) {
        return Map<String, dynamic>.from(decoded);
      }
    } catch (_) {
      // Invalid local context cannot affect the server conversation.
    }
    return <String, dynamic>{'version': 1};
  }
}

String? normalizeChatThreadAlias(String raw) {
  final value = raw.trim();
  final length = value.runes.length;
  return value.isEmpty || length > 60 ? null : value;
}

ChatThreadAlias? _aliasFromRecord(Map<String, Object?> record) {
  final scene = ChatScene.tryParse(record['scene']);
  final threadId = '${record['thread_id'] ?? ''}'.trim();
  final alias = normalizeChatThreadAlias('${record['alias'] ?? ''}');
  final updatedAt = DateTime.tryParse('${record['updated_at'] ?? ''}');
  if (scene == null ||
      !isSafeChatIdentifier(threadId) ||
      alias == null ||
      updatedAt == null) {
    return null;
  }
  return ChatThreadAlias(
    scene: scene,
    threadId: threadId,
    alias: alias,
    updatedAt: updatedAt,
  );
}

String _normalize(String value, String name) {
  final normalized = value.trim();
  if (normalized.isEmpty) {
    throw ArgumentError.value(value, name, 'must not be empty');
  }
  return normalized;
}

Map<String, dynamic> _mutablePurposeEntries(Map<String, dynamic> payload) {
  final raw = payload['purposes'];
  if (raw is! Map<String, dynamic>) return <String, dynamic>{};
  return <String, dynamic>{...raw};
}

Map<String, dynamic> _mutableConversationEntries(Map<String, dynamic> payload) {
  final raw = payload['conversations'];
  if (raw is! Map) return <String, dynamic>{};
  return <String, dynamic>{...raw};
}

Map<String, dynamic> _mutableHiddenThreadEntries(Map<String, dynamic> payload) {
  final raw = payload['hidden'];
  if (raw is! Map) return <String, dynamic>{};
  return <String, dynamic>{...raw};
}

Map<String, dynamic> _mutableAgentProfileEntries(Map<String, dynamic> payload) {
  final raw = payload['profiles'];
  if (raw is! Map) return <String, dynamic>{};
  return <String, dynamic>{...raw};
}

Map<String, dynamic> _mutableDailyTopicContextEntries(
  Map<String, dynamic> payload,
) {
  final raw = payload['contexts'];
  if (raw is! Map) return <String, dynamic>{};
  return <String, dynamic>{...raw};
}

Map<String, dynamic> _mutableThreadAssetContextEntries(
  Map<String, dynamic> payload,
) {
  final raw = payload['bindings'];
  if (raw is! Map) return <String, dynamic>{};
  return <String, dynamic>{...raw};
}

String _purposeEntryKey(ChatScene scene, ChatConversationPurpose purpose) =>
    '${scene.apiValue}/${purpose.routeValue}';

String _conversationEntryKey(
  ChatScene scene,
  ChatConversationPurpose purpose, {
  String? agentProfileId,
}) => <String>[
  scene.apiValue,
  purpose.routeValue,
  if (agentProfileId != null) agentProfileId,
].join('/');

String _purposeKey(String userScope) {
  final normalized = _normalize(userScope, 'userScope');
  final digest = sha256.convert(utf8.encode(normalized)).toString();
  return 'chat.purpose.v1.${digest.substring(0, 24)}';
}

String _conversationCacheKey(String userScope) {
  final normalized = _normalize(userScope, 'userScope');
  final digest = sha256.convert(utf8.encode(normalized)).toString();
  return 'chat.cache.v1.${digest.substring(0, 24)}';
}

String _hiddenThreadsKey(String userScope) {
  final normalized = _normalize(userScope, 'userScope');
  final digest = sha256.convert(utf8.encode(normalized)).toString();
  return 'chat.hidden.v1.${digest.substring(0, 24)}';
}

String _agentProfileKey(String userScope) {
  final normalized = _normalize(userScope, 'userScope');
  final digest = sha256.convert(utf8.encode(normalized)).toString();
  return 'chat.agent_profile.v1.${digest.substring(0, 24)}';
}

String _dailyTopicContextKey(String userScope) {
  final normalized = _normalize(userScope, 'userScope');
  final digest = sha256.convert(utf8.encode(normalized)).toString();
  return 'chat.daily_topic.v1.${digest.substring(0, 24)}';
}

String _threadAssetContextKey(String userScope) {
  final normalized = _normalize(userScope, 'userScope');
  final digest = sha256.convert(utf8.encode(normalized)).toString();
  return 'chat.thread_asset.v1.${digest.substring(0, 24)}';
}

String _agentProfileEntryKey(ChatScene scene, String threadId) =>
    '${scene.apiValue}/$threadId';

String _dailyTopicContextEntryKey(ChatScene scene, String threadId) =>
    '${scene.apiValue}/$threadId';

String _threadAssetContextEntryKey(ChatScene scene, String threadId) =>
    '${scene.apiValue}/$threadId';

ChatDailyTopicContext? _dailyTopicContextFromValue(
  Object? value, {
  required ChatScene scene,
  required String threadId,
}) {
  if (value is! Map) return null;
  final title = _dailyTopicTitle(value['title']);
  final updatedAt = DateTime.tryParse('${value['updatedAt'] ?? ''}')?.toUtc();
  if (title == null || updatedAt == null) return null;
  return ChatDailyTopicContext(
    scene: scene,
    threadId: threadId,
    title: title,
    updatedAt: updatedAt,
  );
}

OrdinaryChatThreadBinding? _ordinaryChatBindingFromRecord(
  Map<String, Object?> record,
) {
  if (record['scene'] != ChatScene.feedAi.apiValue ||
      record['agent_profile_id'] != standardCreationChatAgentProfileId) {
    return null;
  }
  final entryPoint = OrdinaryChatEntryPoint.tryParse(
    kind: record['entry_kind'],
    entryId: record['entry_id'],
  );
  final threadId = record['thread_id'];
  final workspaceScope = record['workspace_scope'];
  final boundAt = DateTime.tryParse('${record['bound_at'] ?? ''}')?.toUtc();
  final lastOpenedAt = DateTime.tryParse(
    '${record['last_opened_at'] ?? ''}',
  )?.toUtc();
  if (entryPoint == null ||
      workspaceScope is! String ||
      workspaceScope.trim().isEmpty ||
      threadId is! String ||
      !isSafeChatIdentifier(threadId.trim()) ||
      boundAt == null ||
      lastOpenedAt == null ||
      boundAt.isAfter(lastOpenedAt)) {
    return null;
  }
  return OrdinaryChatThreadBinding(
    workspaceScope: workspaceScope.trim(),
    scene: ChatScene.feedAi,
    entryPoint: entryPoint,
    threadId: threadId.trim(),
    boundAt: boundAt,
    lastOpenedAt: lastOpenedAt,
  );
}

String? _dailyTopicTitle(Object? value) {
  if (value is! String) return null;
  final normalized = value.trim();
  final length = normalized.runes.length;
  return normalized.isEmpty || length > 500 ? null : normalized;
}

ChatThread _serverConfirmedThread(ChatThread thread) => ChatThread(
  threadId: thread.threadId,
  scene: thread.scene,
  workspaceId: thread.workspaceId,
  title: thread.title,
  titleMode: thread.titleMode,
  titleVersion: thread.titleVersion,
  updatedAt: thread.updatedAt,
  firstUserMessageText: thread.firstUserMessageText,
  purpose: thread.purpose,
  agentProfileId: _safeAgentProfileId(thread.agentProfileId),
  activeRuns: List<ChatActiveRun>.unmodifiable(thread.activeRuns),
);

bool _isCacheableMessage(
  ChatMessage message,
  String threadId,
  ChatScene scene,
) =>
    message.threadId == threadId &&
    message.scene == scene &&
    (message.localDelivery == ChatLocalDeliveryState.server ||
        (message.role == ChatMessageRole.user &&
            (message.localDelivery == ChatLocalDeliveryState.pending ||
                message.localDelivery == ChatLocalDeliveryState.failed)));

ChatMessage _cacheableMessage(ChatMessage message) => ChatMessage(
  messageId: message.messageId,
  threadId: message.threadId,
  scene: message.scene,
  role: message.role,
  contentType: message.contentType,
  status: message.status,
  taskId: _safeIdentifier(message.taskId),
  agentRunId: _safeAgentRunId(message.agentRunId),
  textPreview: _safeMessageBody(message.textPreview),
  transcriptText: _safeMessageBody(message.transcriptText),
  imageAttachments: List<ChatImageAttachment>.unmodifiable([
    for (final attachment in message.imageAttachments)
      if (isSafeChatIdentifier(attachment.resourceId))
        ChatImageAttachment(
          resourceId: attachment.resourceId,
          displayName: _safeText(attachment.displayName, maximum: 160),
          mimeType: _safeMime(attachment.mimeType),
        ),
  ]),
  resourceAttachments: List<ChatResourceAttachment>.unmodifiable([
    for (final attachment in message.resourceAttachments)
      if (isSafeChatIdentifier(attachment.resourceId))
        ChatResourceAttachment(
          kind: attachment.kind,
          resourceId: attachment.resourceId,
          displayName: _safeResourceName(attachment.displayName),
          mimeType: _safeMime(attachment.mimeType),
          sizeBytes: _safeResourceSize(attachment.sizeBytes),
        ),
  ]),
  assetReferences: List<ChatAssetReference>.unmodifiable([
    for (final reference in message.assetReferences)
      if (reference.isValid)
        ChatAssetReference(
          assetId: reference.assetId,
          title: reference.title.trim(),
        ),
  ]),
  createdAt: message.createdAt,
  localDelivery: message.localDelivery,
  localFailureCanAbandon: message.localFailureCanAbandon,
);

Map<String, Object?> _threadToCache(ChatThread thread) => <String, Object?>{
  'threadId': thread.threadId,
  'scene': thread.scene.apiValue,
  if (_safeIdentifier(thread.workspaceId) case final workspaceId?)
    'workspaceId': workspaceId,
  'purpose': thread.purpose.apiValue,
  if (_safeText(thread.title, maximum: 160) case final title?) 'title': title,
  'titleMode': thread.titleMode.name,
  'titleVersion': thread.titleVersion,
  if (thread.updatedAt != null)
    'updatedAt': thread.updatedAt!.toUtc().toIso8601String(),
  if (_safeText(thread.firstUserMessageText, maximum: 160) case final first?)
    'firstUserMessageText': first,
  if (_safeAgentProfileId(thread.agentProfileId) case final profile?)
    'agentProfileId': profile,
  'activeRuns': [
    for (final run in thread.activeRuns)
      if (_isSafeRunStatus(run.status))
        <String, Object?>{'agentRunId': run.agentRunId, 'status': run.status},
  ],
};

ChatThread? _threadFromCache(Object? raw) {
  if (raw is! Map) return null;
  final value = Map<String, Object?>.from(raw);
  final threadId = _safeIdentifier(value['threadId']);
  final workspaceId = _safeIdentifier(value['workspaceId']);
  final scene = ChatScene.tryParse(value['scene']);
  final purpose = ChatConversationPurpose.tryParseApi(value['purpose']);
  final updatedAt = _cacheDate(value['updatedAt']);
  final activeRuns = _activeRunsFromCache(value['activeRuns']);
  final titleVersion = value['titleVersion'];
  if (threadId == null ||
      scene == null ||
      purpose == null ||
      activeRuns == null) {
    return null;
  }
  return ChatThread(
    threadId: threadId,
    scene: scene,
    workspaceId: workspaceId,
    title: _safeText(value['title'], maximum: 160),
    titleMode: switch (value['titleMode']) {
      'custom' => ChatThreadTitleMode.custom,
      _ => ChatThreadTitleMode.auto,
    },
    titleVersion: titleVersion is int && titleVersion > 0 ? titleVersion : 1,
    updatedAt: updatedAt,
    firstUserMessageText: _safeText(
      value['firstUserMessageText'],
      maximum: 160,
    ),
    purpose: purpose,
    agentProfileId: _safeAgentProfileId(value['agentProfileId']),
    activeRuns: activeRuns,
  );
}

Map<String, Object?> _messageToCache(ChatMessage message) => <String, Object?>{
  'messageId': message.messageId,
  'threadId': message.threadId,
  'scene': message.scene.apiValue,
  'role': message.role.apiValue,
  'contentType': message.contentType.apiValue,
  'status': _safeText(message.status, maximum: 80) ?? 'accepted',
  if (_safeIdentifier(message.taskId) case final taskId?) 'taskId': taskId,
  if (_safeAgentRunId(message.agentRunId) case final runId?)
    'agentRunId': runId,
  if (_safeMessageBody(message.textPreview) case final text?)
    'textPreview': text,
  if (_safeMessageBody(message.transcriptText) case final transcript?)
    'transcriptText': transcript,
  if (message.createdAt != null)
    'createdAt': message.createdAt!.toUtc().toIso8601String(),
  'localDelivery': message.localDelivery.name,
  if (message.localFailureCanAbandon) 'localFailureCanAbandon': true,
  'images': [
    for (final attachment in message.imageAttachments)
      if (isSafeChatIdentifier(attachment.resourceId))
        <String, Object?>{
          'resourceId': attachment.resourceId,
          if (_safeText(attachment.displayName, maximum: 160) case final name?)
            'displayName': name,
          if (_safeMime(attachment.mimeType) case final mime?) 'mimeType': mime,
        },
  ],
  'resources': [
    for (final attachment in message.resourceAttachments)
      if (isSafeChatIdentifier(attachment.resourceId))
        <String, Object?>{
          'kind': attachment.kind.apiValue,
          'resourceId': attachment.resourceId,
          if (_safeResourceName(attachment.displayName) case final name?)
            'displayName': name,
          if (_safeMime(attachment.mimeType) case final mime?) 'mimeType': mime,
          if (_safeResourceSize(attachment.sizeBytes) case final size?)
            'sizeBytes': size,
        },
  ],
  'assetReferences': [
    for (final reference in message.assetReferences)
      if (reference.isValid)
        <String, Object?>{
          'assetId': reference.assetId,
          'title': reference.title.trim(),
        },
  ],
};

ChatMessage? _messageFromCache(Object? raw) {
  if (raw is! Map) return null;
  final value = Map<String, Object?>.from(raw);
  final messageId = _safeIdentifier(value['messageId']);
  final threadId = _safeIdentifier(value['threadId']);
  final scene = ChatScene.tryParse(value['scene']);
  final role = ChatMessageRole.tryParse(value['role']);
  final contentType = ChatMessageContentType.tryParse(value['contentType']);
  final status = _safeText(value['status'], maximum: 80);
  final localDelivery = _localDeliveryFromCache(value['localDelivery']);
  final localFailureCanAbandon = value['localFailureCanAbandon'] == true;
  final createdAt = _cacheDate(value['createdAt']);
  final images = _imagesFromCache(value['images']);
  final resources = _resourcesFromCache(value['resources']);
  final assetReferences = _assetReferencesFromCache(value['assetReferences']);
  if (messageId == null ||
      threadId == null ||
      scene == null ||
      role == null ||
      contentType == null ||
      status == null ||
      images == null ||
      resources == null ||
      assetReferences == null ||
      localDelivery == null) {
    return null;
  }
  return ChatMessage(
    messageId: messageId,
    threadId: threadId,
    scene: scene,
    role: role,
    contentType: contentType,
    status: status,
    taskId: _safeIdentifier(value['taskId']),
    agentRunId: _safeAgentRunId(value['agentRunId']),
    textPreview: _safeMessageBody(value['textPreview']),
    transcriptText: _safeMessageBody(value['transcriptText']),
    imageAttachments: images,
    resourceAttachments: resources,
    assetReferences: assetReferences,
    createdAt: createdAt,
    localDelivery: localDelivery,
    localFailureCanAbandon:
        localDelivery == ChatLocalDeliveryState.failed &&
        localFailureCanAbandon,
  );
}

ChatLocalDeliveryState? _localDeliveryFromCache(Object? value) {
  // Version 1 cache payloads only contained server-delivered messages.
  if (value == null) return ChatLocalDeliveryState.server;
  return switch (value) {
    'server' => ChatLocalDeliveryState.server,
    'pending' => ChatLocalDeliveryState.pending,
    'failed' => ChatLocalDeliveryState.failed,
    _ => null,
  };
}

List<ChatActiveRun>? _activeRunsFromCache(Object? raw) {
  if (raw is! List) return null;
  final runs = <ChatActiveRun>[];
  for (final entry in raw) {
    if (entry is! Map) return null;
    final value = Map<String, Object?>.from(entry);
    final runId = _safeAgentRunId(value['agentRunId']);
    final status = _safeText(value['status'], maximum: 40);
    if (runId == null || status == null || !_isSafeRunStatus(status)) {
      return null;
    }
    runs.add(ChatActiveRun(agentRunId: runId, status: status));
  }
  return List<ChatActiveRun>.unmodifiable(runs);
}

List<ChatImageAttachment>? _imagesFromCache(Object? raw) {
  if (raw is! List) return null;
  final images = <ChatImageAttachment>[];
  for (final entry in raw) {
    if (entry is! Map) return null;
    final value = Map<String, Object?>.from(entry);
    final resourceId = _safeIdentifier(value['resourceId']);
    if (resourceId == null) return null;
    images.add(
      ChatImageAttachment(
        resourceId: resourceId,
        displayName: _safeText(value['displayName'], maximum: 160),
        mimeType: _safeMime(value['mimeType']),
      ),
    );
  }
  return List<ChatImageAttachment>.unmodifiable(images);
}

List<ChatResourceAttachment>? _resourcesFromCache(Object? raw) {
  if (raw == null) return const <ChatResourceAttachment>[];
  if (raw is! List) return null;
  final resources = <ChatResourceAttachment>[];
  for (final entry in raw) {
    if (entry is! Map) return null;
    final value = Map<String, Object?>.from(entry);
    final kind = ChatResourceAttachmentKind.tryParse(value['kind']);
    final resourceId = _safeIdentifier(value['resourceId']);
    if (kind == null || resourceId == null) return null;
    resources.add(
      ChatResourceAttachment(
        kind: kind,
        resourceId: resourceId,
        displayName: _safeResourceName(value['displayName']),
        mimeType: _safeMime(value['mimeType']),
        sizeBytes: _safeResourceSize(value['sizeBytes']),
      ),
    );
  }
  return List<ChatResourceAttachment>.unmodifiable(resources);
}

List<ChatAssetReference>? _assetReferencesFromCache(Object? raw) {
  if (raw == null) return const <ChatAssetReference>[];
  if (raw is! List) return null;
  final references = <ChatAssetReference>[];
  for (final entry in raw) {
    if (entry is! Map) return null;
    final value = Map<String, Object?>.from(entry);
    final assetId = _safeIdentifier(value['assetId']);
    final title = _safeText(value['title'], maximum: 160);
    if (assetId == null || title == null) return null;
    references.add(ChatAssetReference(assetId: assetId, title: title));
  }
  return List<ChatAssetReference>.unmodifiable(references);
}

String? _safeIdentifier(Object? value) {
  final text = value is String ? value.trim() : null;
  return text != null && isSafeChatIdentifier(text) ? text : null;
}

String? _safeAgentRunId(Object? value) {
  final text = value is String ? value.trim() : null;
  return text != null && isSafeAgentRunIdentifier(text) ? text : null;
}

String? _safeAgentProfileId(Object? value) {
  final text = value is String ? value.trim() : null;
  return text != null &&
          RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$').hasMatch(text)
      ? text
      : null;
}

String? _safeText(Object? value, {required int maximum}) {
  final text = value is String ? value.trim() : null;
  if (text == null || text.isEmpty || text.length > maximum) return null;
  return text;
}

String? _safeResourceName(Object? value) {
  final name = _safeText(value, maximum: 160);
  if (name == null ||
      name.contains('/') ||
      name.contains('\\') ||
      name.contains('..') ||
      name.codeUnits.any((unit) => unit < 32)) {
    return null;
  }
  return name;
}

int? _safeResourceSize(Object? value) =>
    value is int && value > 0 ? value : null;

String? _safeMessageBody(Object? value) {
  final text = value is String ? value.trim() : null;
  return text == null || text.isEmpty ? null : text;
}

String? _safeMime(Object? value) {
  final text = value is String ? value.trim().toLowerCase() : null;
  return text != null && RegExp(r'^[a-z0-9.+-]+/[a-z0-9.+-]+$').hasMatch(text)
      ? text
      : null;
}

DateTime? _cacheDate(Object? value) {
  final text = value is String ? value.trim() : null;
  if (text == null || text.length > 64) return null;
  return DateTime.tryParse(text)?.toUtc();
}

bool _isSafeRunStatus(String value) => const <String>{
  'resolving',
  'planning',
  'awaiting_confirmation',
  'queued',
  'running',
  'aborting',
  'succeeded',
  'failed',
  'timeout',
  'cancelled',
  'orphaned',
}.contains(value);
