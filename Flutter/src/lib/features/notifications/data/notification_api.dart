import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../../core/api/api_client.dart';
import '../../../core/api/api_envelope.dart';
import '../../../core/api/idempotency.dart';
import '../../../core/database/app_preferences_dao.dart';
import '../domain/notification_models.dart';

abstract interface class NotificationApiPort {
  Future<ApiResult<AppNotificationPage>> listNotifications({
    String? cursor,
    int? limit,
  });

  Future<ApiResult<AppNotification>> markRead({
    required String notificationId,
    required IdempotencyRequestContext idempotency,
    SubmissionKeyStore idempotencyStore,
  });
}

final class UnavailableNotificationApi implements NotificationApiPort {
  const UnavailableNotificationApi();

  @override
  Future<ApiResult<AppNotificationPage>> listNotifications({
    String? cursor,
    int? limit,
  }) async {
    return ApiResult<AppNotificationPage>.failure(
      error: _notReadyFailure(),
      idempotencyStore: SubmissionKeyStore.empty,
    );
  }

  @override
  Future<ApiResult<AppNotification>> markRead({
    required String notificationId,
    required IdempotencyRequestContext idempotency,
    SubmissionKeyStore idempotencyStore = SubmissionKeyStore.empty,
  }) async {
    return ApiResult<AppNotification>.failure(
      error: _notReadyFailure(),
      idempotencyStore: idempotencyStore,
    );
  }

  AppFailure _notReadyFailure() => const AppFailure(
    code: 'NOTIFICATION_SERVICE_NOT_READY',
    category: AppFailureCategory.compatibility,
    message: 'Notification dependencies are still bootstrapping.',
    userMessageKey: 'notificationServiceNotReady',
    isRetryable: true,
    recoveryActions: <String>['retry'],
  );
}

abstract interface class NotificationResolutionPort {
  bool get isDemo;
  Set<String> loadHandledIds();
  Set<String> loadLocallyReadIds();
  Future<bool> markHandled(String notificationId);
  Future<bool> markLocallyRead(String notificationId);
}

/// Keeps task-result acknowledgement separate from delivery notification
/// handling. A task can emit several lifecycle rows, but one viewed terminal
/// result should hide only that task for the active account.
abstract interface class TaskNotificationResolutionPort {
  Set<String> loadHandledTaskIds();

  Future<bool> markTaskHandled(String taskId);
}

/// Reports whether every present durable resolution record was decoded in
/// full. Ports without durable storage do not need to implement this.
abstract interface class NotificationResolutionIntegrityPort {
  bool get resolutionRecordsAreValid;
}

final class CachedNotificationPage {
  const CachedNotificationPage({
    required this.items,
    required this.nextCursor,
    required this.savedAt,
    this.rejectedItemCount = 0,
  }) : assert(rejectedItemCount >= 0);

  final List<AppNotification> items;
  final String? nextCursor;
  final DateTime savedAt;
  final int rejectedItemCount;
}

abstract interface class NotificationPageCachePort {
  CachedNotificationPage? loadNotificationPage();

  Future<void> saveNotificationPage(AppNotificationPage page);
}

final class PersistentNotificationResolutionPort
    implements
        NotificationResolutionPort,
        NotificationPageCachePort,
        TaskNotificationResolutionPort,
        NotificationResolutionIntegrityPort {
  PersistentNotificationResolutionPort({
    required AppPreferencesDao dao,
    required String userScope,
    DateTime Function()? now,
  }) : // Public argument names intentionally omit private field prefixes.
       // ignore: prefer_initializing_formals
       _dao = dao,
       _now = now ?? DateTime.now,
       _handledPreferenceKey =
           'notification-handled-${sha256.convert(utf8.encode(userScope)).toString().substring(0, 24)}',
       _readPreferenceKey =
           'notification-local-read-${sha256.convert(utf8.encode(userScope)).toString().substring(0, 24)}',
       _handledTaskPreferenceKey =
           'notification-handled-task-${sha256.convert(utf8.encode(userScope)).toString().substring(0, 24)}',
       _pagePreferenceKey =
           'notification-page-${sha256.convert(utf8.encode(userScope)).toString().substring(0, 24)}';

  final AppPreferencesDao _dao;
  final DateTime Function() _now;
  final String _handledPreferenceKey;
  final String _readPreferenceKey;
  final String _handledTaskPreferenceKey;
  final String _pagePreferenceKey;

  @override
  bool get isDemo => true;

  @override
  Set<String> loadHandledIds() => _loadIds(_handledPreferenceKey);

  @override
  Set<String> loadLocallyReadIds() => _loadIds(_readPreferenceKey);

  @override
  Set<String> loadHandledTaskIds() => _loadIds(_handledTaskPreferenceKey);

  @override
  bool get resolutionRecordsAreValid {
    for (final key in <String>[
      _handledPreferenceKey,
      _readPreferenceKey,
      _handledTaskPreferenceKey,
    ]) {
      if (!_readIds(key).isValid) return false;
    }
    return true;
  }

  Set<String> _loadIds(String key) => _readIds(key).ids;

  ({Set<String> ids, bool isValid}) _readIds(String key) {
    final encoded = _dao.readValue(key);
    if (encoded == null) return (ids: <String>{}, isValid: true);
    Object? decoded;
    try {
      decoded = jsonDecode(encoded);
    } catch (_) {
      return (ids: <String>{}, isValid: false);
    }
    if (decoded is! List) return (ids: <String>{}, isValid: false);
    final ids = <String>{};
    var isValid = true;
    for (final value in decoded) {
      if (value is String && isSafeNotificationIdentifier(value)) {
        ids.add(value);
      } else {
        isValid = false;
      }
    }
    return (ids: ids, isValid: isValid);
  }

  @override
  Future<bool> markHandled(String notificationId) async {
    return _persistId(
      key: _handledPreferenceKey,
      current: loadHandledIds(),
      notificationId: notificationId,
    );
  }

  @override
  Future<bool> markLocallyRead(String notificationId) async {
    return _persistId(
      key: _readPreferenceKey,
      current: loadLocallyReadIds(),
      notificationId: notificationId,
    );
  }

  @override
  Future<bool> markTaskHandled(String taskId) async {
    return _persistId(
      key: _handledTaskPreferenceKey,
      current: loadHandledTaskIds(),
      notificationId: taskId,
    );
  }

  @override
  CachedNotificationPage? loadNotificationPage() {
    final raw = _dao.readValue(_pagePreferenceKey);
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map || decoded['items'] is! List) return null;
      final savedAt = decoded['savedAt'];
      final parsedSavedAt = savedAt is String
          ? DateTime.tryParse(savedAt)?.toUtc()
          : null;
      if (parsedSavedAt == null) return null;
      final items = <AppNotification>[];
      for (final item in decoded['items'] as List) {
        final parsed = _notificationFromCache(item);
        if (parsed == null) return null;
        items.add(parsed);
      }
      final cursor = decoded['nextCursor'];
      if (cursor != null &&
          (cursor is! String || !isSafeNotificationIdentifier(cursor))) {
        return null;
      }
      final rawRejectedItemCount = decoded['rejectedItemCount'];
      final rejectedItemCount = rawRejectedItemCount == null
          ? 0
          : rawRejectedItemCount is int &&
                rawRejectedItemCount >= 0 &&
                rawRejectedItemCount <= 10000
          ? rawRejectedItemCount
          : null;
      if (rejectedItemCount == null) return null;
      return CachedNotificationPage(
        items: List<AppNotification>.unmodifiable(items),
        nextCursor: cursor as String?,
        savedAt: parsedSavedAt,
        rejectedItemCount: rejectedItemCount,
      );
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> saveNotificationPage(AppNotificationPage page) async {
    final savedAt = _now().toUtc();
    _dao.upsertValue(
      preferenceKey: _pagePreferenceKey,
      value: jsonEncode(<String, Object?>{
        'savedAt': savedAt.toIso8601String(),
        'nextCursor': page.nextCursor,
        'rejectedItemCount': page.rejectedItemCount,
        'items': page.items.map(_notificationToCache).toList(growable: false),
      }),
      updatedAt: savedAt.toIso8601String(),
    );
  }

  Future<bool> _persistId({
    required String key,
    required Set<String> current,
    required String notificationId,
  }) async {
    if (!isSafeNotificationIdentifier(notificationId)) return false;
    final values = current..add(notificationId);
    try {
      _dao.upsertValue(
        preferenceKey: key,
        value: jsonEncode(values.toList()..sort()),
        updatedAt: _now().toUtc().toIso8601String(),
      );
      return true;
    } catch (_) {
      return false;
    }
  }
}

Map<String, Object?> _notificationToCache(
  AppNotification item,
) => <String, Object?>{
  'notificationId': item.notificationId,
  'eventType': item.eventType,
  'scene': item.scene,
  'targetType': item.targetType,
  'targetId': item.targetId,
  'title': item.title,
  'body': item.body,
  'status': item.status.name,
  if (item.workspaceId != null) 'workspaceId': item.workspaceId,
  if (item.taskStatus != null) 'taskStatus': item.taskStatus!.name,
  if (item.taskId != null) 'taskId': item.taskId,
  if (item.eventId != null) 'eventId': item.eventId,
  if (item.createdAt != null) 'createdAt': item.createdAt!.toIso8601String(),
  if (item.updatedAt != null) 'updatedAt': item.updatedAt!.toIso8601String(),
};

AppNotification? _notificationFromCache(Object? value) {
  if (value is! Map) return null;
  final map = Map<String, Object?>.from(value);
  final notificationId = map['notificationId'];
  final eventType = map['eventType'];
  final scene = map['scene'];
  final targetType = map['targetType'];
  final targetId = map['targetId'];
  final title = map['title'];
  final body = map['body'];
  final status = _parseStatus(map['status']);
  final workspaceId = _safeOptionalOpaqueIdentifier(map['workspaceId']);
  final taskStatus = AppNotificationTaskStatus.tryParse(map['taskStatus']);
  final taskId = _safeOptionalTaskIdentifier(map['taskId']);
  final eventId = _safeOptionalOpaqueIdentifier(map['eventId']);
  final createdAt = map['createdAt'];
  final updatedAt = map['updatedAt'];
  if (notificationId is! String ||
      eventType is! String ||
      scene is! String ||
      targetType is! String ||
      targetId is! String ||
      title is! String ||
      body is! String ||
      status == null ||
      (map['workspaceId'] != null && workspaceId == null) ||
      (map['taskStatus'] != null && taskStatus == null) ||
      (map['taskId'] != null && taskId == null) ||
      (map['eventId'] != null && eventId == null) ||
      !isSafeNotificationOpaqueIdentifier(notificationId) ||
      _safeTag(eventType) == null ||
      _safeTag(scene) == null ||
      _safeTag(targetType) == null ||
      !isSafeNotificationOpaqueIdentifier(targetId) ||
      _safeDisplayText(title, maximum: 160) == null ||
      _safeDisplayText(body, maximum: 1000) == null) {
    return null;
  }
  final parsedCreatedAt = createdAt == null
      ? null
      : createdAt is String
      ? _safeDate(createdAt)
      : null;
  if (createdAt != null && parsedCreatedAt == null) return null;
  final parsedUpdatedAt = updatedAt == null
      ? null
      : updatedAt is String
      ? _safeDate(updatedAt)
      : null;
  if (updatedAt != null && parsedUpdatedAt == null) return null;
  return AppNotification(
    notificationId: notificationId,
    eventType: eventType,
    scene: scene,
    targetType: targetType,
    targetId: targetId,
    title: title,
    body: body,
    status: status,
    workspaceId: workspaceId,
    taskStatus: taskStatus,
    taskId: taskId,
    eventId: eventId,
    createdAt: parsedCreatedAt,
    updatedAt: parsedUpdatedAt,
  );
}

final class NotificationApi implements NotificationApiPort {
  const NotificationApi({required ApiClient apiClient, String? workspaceId})
    : // Public argument names intentionally omit private field prefixes.
      // ignore: prefer_initializing_formals
      _apiClient = apiClient,
      // ignore: prefer_initializing_formals
      _workspaceId = workspaceId;

  final ApiClient _apiClient;
  final String? _workspaceId;
  NotificationClient get _notificationClient => NotificationClient(_apiClient);

  @override
  Future<ApiResult<AppNotificationPage>> listNotifications({
    String? cursor,
    int? limit,
  }) {
    if (cursor != null && !isSafeNotificationIdentifier(cursor)) {
      return Future<ApiResult<AppNotificationPage>>.value(
        _invalidResult<AppNotificationPage>('NOTIFICATION_CURSOR_INVALID'),
      );
    }
    if (limit != null && (limit < 1 || limit > 100)) {
      return Future<ApiResult<AppNotificationPage>>.value(
        _invalidResult<AppNotificationPage>('NOTIFICATION_LIST_LIMIT_INVALID'),
      );
    }
    return _notificationClient.list<AppNotificationPage>(
      cursor: cursor,
      limit: limit,
      parseData: (value) {
        final page = parseAppNotificationPage(value);
        final workspaceId = _safeOptionalOpaqueIdentifier(_workspaceId);
        if (page == null || workspaceId == null) return page;
        return AppNotificationPage(
          items: List<AppNotification>.unmodifiable(
            page.items.where(
              (item) =>
                  item.workspaceId == workspaceId ||
                  isAccountLevelNotificationCompatibility(item),
            ),
          ),
          nextCursor: page.nextCursor,
          rejectedItemCount: page.rejectedItemCount,
        );
      },
    );
  }

  @override
  Future<ApiResult<AppNotification>> markRead({
    required String notificationId,
    required IdempotencyRequestContext idempotency,
    SubmissionKeyStore idempotencyStore = SubmissionKeyStore.empty,
  }) {
    if (!isSafeNotificationOpaqueIdentifier(notificationId)) {
      return Future<ApiResult<AppNotification>>.value(
        _invalidResult<AppNotification>('NOTIFICATION_ID_INVALID'),
      );
    }
    return _notificationClient.markRead<AppNotification>(
      notificationId: notificationId,
      idempotency: idempotency,
      idempotencyStore: idempotencyStore,
      parseData: parseMarkReadNotification,
    );
  }
}

AppNotification? parseMarkReadNotification(Object? value) {
  final object = asObjectMap(value);
  if (object == null) return null;
  final nested = object['notification'];
  if (nested != null) return parseAppNotification(nested);
  final hasNotificationContent =
      object.containsKey('eventType') ||
      object.containsKey('targetType') ||
      object.containsKey('payload');
  if (!hasNotificationContent) return _parseReadReceipt(object);
  return parseAppNotification(object) ?? _parseReadReceipt(object);
}

AppNotification? _parseReadReceipt(Map<String, Object?> object) {
  final notificationId = _safeOptionalOpaqueIdentifier(
    object['notificationId'],
  );
  final status = _parseStatus(object['status']);
  if (notificationId == null || status != AppNotificationStatus.read) {
    return null;
  }
  return AppNotification.readReceipt(
    notificationId: notificationId,
    status: AppNotificationStatus.read,
  );
}

AppNotificationPage? parseAppNotificationPage(Object? value) {
  final object = asObjectMap(value);
  if (object == null) return null;
  final rawItems = object['items'] ?? object['notifications'];
  if (rawItems is! List) return null;
  final items = <AppNotification>[];
  var rejectedItemCount = 0;
  for (final rawItem in rawItems) {
    final item = parseAppNotification(rawItem);
    if (item == null) {
      rejectedItemCount += 1;
      continue;
    }
    items.add(item);
  }
  final nextCursor = _safeOptionalIdentifier(object['nextCursor']);
  if (object['nextCursor'] != null && nextCursor == null) return null;
  return AppNotificationPage(
    items: List<AppNotification>.unmodifiable(items),
    nextCursor: nextCursor,
    rejectedItemCount: rejectedItemCount,
  );
}

AppNotification? parseAppNotification(Object? value) {
  final object = asObjectMap(value);
  if (object == null) return null;
  final rawPayload = object['payload'];
  final parsedPayload = asObjectMap(rawPayload);
  if (rawPayload != null && parsedPayload == null) return null;
  final payload = parsedPayload ?? const <String, Object?>{};
  Object? field(String name) => object[name] ?? payload[name];
  // Older notification rows did not expose an event type. Retain them as
  // passive notifications while preferring the canonical public field.
  final eventType = _safeTag(field('eventType')) ?? 'system.legacy';
  final notificationId = _safeOptionalOpaqueIdentifier(
    object['notificationId'],
  );
  if (notificationId == null) return null;
  final target = _parseNotificationTarget(
    object: object,
    payload: payload,
    eventType: eventType,
    notificationId: notificationId,
  );
  final targetType = target.targetType;
  final targetId = target.targetId;
  final scene =
      _safeTag(field('scene')) ??
      _sceneForTargetType(targetType) ??
      _sceneForEvent(eventType);
  final rawTitle = field('title');
  final parsedTitle = _safeDisplayText(rawTitle, maximum: 160);
  final rawBody = field('body');
  final parsedBody = _safeDisplayText(rawBody, maximum: 1000);
  final rawSummary = field('summary');
  final parsedSummary = _safeDisplayText(rawSummary, maximum: 1000);
  final title = parsedTitle ?? _notificationFallbackTitle(eventType);
  final body =
      parsedBody ??
      parsedSummary ??
      _notificationFallbackBody(eventType) ??
      title;
  final status = _parseStatus(object['status']);
  final taskStatus = AppNotificationTaskStatus.tryParse(field('taskStatus'));
  final taskId = _safeOptionalTaskIdentifier(field('taskId'));
  final workspace = _notificationWorkspaceId(object, payload);
  if (!workspace.isValid) return null;
  if (field('taskStatus') != null && taskStatus == null) return null;
  if (field('taskId') != null && taskId == null) return null;
  if (scene == null || status == null) {
    return null;
  }
  final createdAt = _safeDate(object['createdAt']);
  if (object['createdAt'] != null && createdAt == null) return null;
  final eventId = _safeOptionalOpaqueIdentifier(object['eventId']);
  if (object['eventId'] != null && eventId == null) return null;
  final updatedAt = _safeDate(object['updatedAt']);
  if (object['updatedAt'] != null && updatedAt == null) return null;
  return AppNotification(
    notificationId: notificationId,
    eventType: eventType,
    scene: scene,
    targetType: targetType,
    targetId: targetId,
    title: title,
    body: body,
    status: status,
    workspaceId: workspace.value,
    taskStatus: taskStatus,
    taskId: taskId,
    eventId: eventId,
    createdAt: createdAt,
    updatedAt: updatedAt,
  );
}

({bool isValid, String? value}) _notificationWorkspaceId(
  Map<String, Object?> object,
  Map<String, Object?> payload,
) {
  final hasRoot =
      object.containsKey('workspaceId') && object['workspaceId'] != null;
  final hasPayload =
      payload.containsKey('workspaceId') && payload['workspaceId'] != null;
  final root = hasRoot
      ? _safeOptionalOpaqueIdentifier(object['workspaceId'])
      : null;
  final nested = hasPayload
      ? _safeOptionalOpaqueIdentifier(payload['workspaceId'])
      : null;
  if ((hasRoot && root == null) ||
      (hasPayload && nested == null) ||
      (root != null && nested != null && root != nested)) {
    return (isValid: false, value: null);
  }
  return (isValid: true, value: root ?? nested);
}

({String targetType, String targetId}) _parseNotificationTarget({
  required Map<String, Object?> object,
  required Map<String, Object?> payload,
  required String eventType,
  required String notificationId,
}) {
  ({String targetType, String targetId}) generic() =>
      (targetType: 'notification', targetId: notificationId);

  final hasRootTarget =
      object.containsKey('targetType') || object.containsKey('targetId');
  final hasDatabaseNullRootTarget =
      object.containsKey('targetType') &&
      object.containsKey('targetId') &&
      _isBlankString(object['targetType']) &&
      _isBlankString(object['targetId']);
  if (hasRootTarget && !hasDatabaseNullRootTarget) {
    final targetType = _safeTag(object['targetType']);
    final targetId = _safeOptionalOpaqueIdentifier(object['targetId']);
    return targetType == null || targetId == null
        ? generic()
        : (targetType: targetType, targetId: targetId);
  }

  final hasPayloadTarget =
      payload.containsKey('targetType') || payload.containsKey('targetId');
  if (hasPayloadTarget) {
    final targetType = _safeTag(payload['targetType']);
    final targetId = _safeOptionalOpaqueIdentifier(payload['targetId']);
    return targetType == null || targetId == null
        ? generic()
        : (targetType: targetType, targetId: targetId);
  }

  final targetId = _eventTargetId(eventType, payload);
  if (targetId == null) return generic();
  return (targetType: _targetTypeForEvent(eventType), targetId: targetId);
}

bool _isBlankString(Object? value) => value is String && value.trim().isEmpty;

String _targetTypeForEvent(String eventType) => switch (eventType) {
  'recording.deposit.succeeded' => 'recording',
  'hotspot_suggestion' => 'hotspot_suggestion',
  'topic_recommendation.ready' => 'topic_recommendation',
  _ => 'notification',
};

String _notificationFallbackTitle(String eventType) => switch (eventType) {
  'topic_recommendation.ready' => '每日推荐已生成',
  _ => '新消息',
};

String? _notificationFallbackBody(String eventType) => switch (eventType) {
  'topic_recommendation.ready' => '今天的推荐内容已经准备好。',
  _ => null,
};

String? _sceneForEvent(String eventType) => switch (eventType) {
  'recording.deposit.succeeded' => 'recording',
  'hotspot_suggestion' => 'feed',
  'topic_recommendation.ready' => 'work_ai',
  _ => 'notification',
};

String? _eventTargetId(String eventType, Map<String, Object?> payload) =>
    switch (eventType) {
      'recording.deposit.succeeded' => _safeOptionalOpaqueIdentifier(
        payload['recordingId'],
      ),
      'hotspot_suggestion' => _safeOptionalOpaqueIdentifier(
        payload['suggestionId'],
      ),
      'topic_recommendation.ready' => _safeOptionalOpaqueIdentifier(
        payload['recommendationId'],
      ),
      _ => null,
    };

String? _sceneForTargetType(String? targetType) => switch (targetType) {
  'thread' => 'chat',
  'recording' => 'recording',
  'note' => 'asset',
  'asset' => 'asset',
  'task' => 'work_ai',
  'hotspot_suggestion' => 'feed',
  'topic_recommendation' => 'work_ai',
  'notification' => 'notification',
  _ => null,
};

ApiResult<T> _invalidResult<T>(String code) {
  return ApiResult<T>.failure(
    error: AppFailure(
      code: code,
      category: AppFailureCategory.api,
      message: 'Notification request is invalid',
      userMessageKey: 'notification.error.$code',
    ),
    idempotencyStore: SubmissionKeyStore.empty,
  );
}

AppNotificationStatus? _parseStatus(Object? value) {
  return switch (value) {
    'unread' => AppNotificationStatus.unread,
    'read' => AppNotificationStatus.read,
    'handled' => AppNotificationStatus.handled,
    'expired' => AppNotificationStatus.expired,
    _ => null,
  };
}

String? _safeOptionalIdentifier(Object? value) {
  final text = value is String ? value.trim() : null;
  return text != null && isSafeNotificationIdentifier(text) ? text : null;
}

String? _safeOptionalOpaqueIdentifier(Object? value) {
  final text = value is String ? value.trim() : null;
  return text != null && isSafeNotificationOpaqueIdentifier(text) ? text : null;
}

String? _safeOptionalTaskIdentifier(Object? value) {
  final text = value is String ? value.trim() : null;
  return text != null && isSafeNotificationTaskIdentifier(text) ? text : null;
}

String? _safeTag(Object? value) {
  final text = value is String ? value.trim() : null;
  return text != null && RegExp(r'^[a-z][a-z0-9_.-]{0,63}$').hasMatch(text)
      ? text
      : null;
}

String? _safeDisplayText(Object? value, {required int maximum}) {
  final text = value is String ? value.trim() : null;
  if (text == null || text.isEmpty || text.length > maximum) return null;
  return _unsafeText.hasMatch(text) ? null : text;
}

DateTime? _safeDate(Object? value) {
  final text = value is String ? value.trim() : null;
  if (text == null || text.length > 64) return null;
  return DateTime.tryParse(text)?.toUtc();
}

final _unsafeText = RegExp(
  r'file://|/home/|access-token|refresh-token|provider.*key|runtime:',
  caseSensitive: false,
);
