import 'dart:async';
import 'dart:convert';

import 'package:huahuo_api/huahuo_api.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../data/notification_api.dart';
import '../domain/notification_models.dart';

enum NotificationControllerStatus { idle, loading, ready, markingRead, failed }

final class NotificationControllerState {
  const NotificationControllerState({
    required this.status,
    this.items = const <AppNotification>[],
    this.nextCursor,
    this.pendingReadDeliveryKeys = const <String>{},
    this.pendingHandledIds = const <String>{},
    this.handledIds = const <String>{},
    this.pendingHandledTaskIds = const <String>{},
    this.handledTaskIds = const <String>{},
    this.pendingLocalReadIds = const <String>{},
    this.locallyReadIds = const <String>{},
    this.rejectedItemCount = 0,
    this.resolutionIsDemo = false,
    this.resolutionHydrated = true,
    this.lastErrorCode,
  });

  factory NotificationControllerState.initial({
    bool resolutionHydrated = true,
  }) {
    return NotificationControllerState(
      status: NotificationControllerStatus.idle,
      resolutionHydrated: resolutionHydrated,
    );
  }

  final NotificationControllerStatus status;
  final List<AppNotification> items;
  final String? nextCursor;
  final Set<String> pendingReadDeliveryKeys;
  final Set<String> pendingHandledIds;
  final Set<String> handledIds;
  final Set<String> pendingHandledTaskIds;
  final Set<String> handledTaskIds;
  final Set<String> pendingLocalReadIds;
  final Set<String> locallyReadIds;
  final int rejectedItemCount;
  final bool resolutionIsDemo;
  final bool resolutionHydrated;
  final String? lastErrorCode;

  bool get isLoading => status == NotificationControllerStatus.loading;
  bool isReadPending(AppNotification notification) {
    final deliveryKey = notificationDeliveryResolutionKey(notification);
    return pendingReadDeliveryKeys.contains(deliveryKey) ||
        pendingLocalReadIds.contains(deliveryKey);
  }

  List<AppNotification> get unresolvedItems =>
      List<AppNotification>.unmodifiable(
        items.where(
          (item) =>
              item.isUnresolved &&
              !handledIds.contains(notificationDeliveryResolutionKey(item)),
        ),
      );

  NotificationControllerState copyWith({
    NotificationControllerStatus? status,
    List<AppNotification>? items,
    String? nextCursor,
    Set<String>? pendingReadDeliveryKeys,
    Set<String>? pendingHandledIds,
    Set<String>? handledIds,
    Set<String>? pendingHandledTaskIds,
    Set<String>? handledTaskIds,
    Set<String>? pendingLocalReadIds,
    Set<String>? locallyReadIds,
    int? rejectedItemCount,
    bool? resolutionIsDemo,
    bool? resolutionHydrated,
    String? lastErrorCode,
    bool clearError = false,
    bool clearNextCursor = false,
  }) {
    return NotificationControllerState(
      status: status ?? this.status,
      items: items ?? this.items,
      nextCursor: clearNextCursor ? null : nextCursor ?? this.nextCursor,
      pendingReadDeliveryKeys:
          pendingReadDeliveryKeys ?? this.pendingReadDeliveryKeys,
      pendingHandledIds: pendingHandledIds ?? this.pendingHandledIds,
      handledIds: handledIds ?? this.handledIds,
      pendingHandledTaskIds:
          pendingHandledTaskIds ?? this.pendingHandledTaskIds,
      handledTaskIds: handledTaskIds ?? this.handledTaskIds,
      pendingLocalReadIds: pendingLocalReadIds ?? this.pendingLocalReadIds,
      locallyReadIds: locallyReadIds ?? this.locallyReadIds,
      rejectedItemCount: rejectedItemCount ?? this.rejectedItemCount,
      resolutionIsDemo: resolutionIsDemo ?? this.resolutionIsDemo,
      resolutionHydrated: resolutionHydrated ?? this.resolutionHydrated,
      lastErrorCode: clearError ? null : lastErrorCode ?? this.lastErrorCode,
    );
  }
}

final class NotificationController extends ChangeNotifier {
  NotificationController({
    required NotificationApiPort api,
    NotificationResolutionPort? resolution,
    this.cacheTtl = const Duration(minutes: 5),
    Duration Function()? cacheTtlResolver,
    DateTime Function()? now,
  }) : _api = api,
       _resolution = resolution ?? _SessionNotificationResolutionPort(),
       _cacheTtlResolver = cacheTtlResolver,
       _now = now ?? DateTime.now {
    _state = _stateWithResolution(_state, _loadResolutionSnapshot());
  }

  final NotificationApiPort _api;
  final NotificationResolutionPort _resolution;
  final DateTime Function() _now;
  final Duration cacheTtl;
  final Duration Function()? _cacheTtlResolver;
  final List<_NotificationLoadRequest> _pendingLoadRequests =
      <_NotificationLoadRequest>[];
  NotificationControllerState _state = NotificationControllerState.initial(
    resolutionHydrated: false,
  );
  Future<void>? _loadDrain;
  Future<void>? _cacheSaveDrain;
  bool _cacheSaveRequested = false;
  bool _disposed = false;

  NotificationControllerState get state => _state;

  Future<void> load({bool refresh = true, bool forceRemote = false}) {
    if (_disposed) return Future<void>.value();
    _enqueueLoadRequest(
      _NotificationLoadRequest(refresh: refresh, forceRemote: forceRemote),
    );
    final active = _loadDrain;
    if (active != null) return active;

    final completer = Completer<void>();
    _loadDrain = completer.future;
    unawaited(_drainLoadRequests(completer));
    return completer.future;
  }

  void _enqueueLoadRequest(_NotificationLoadRequest request) {
    final existingIndex = _pendingLoadRequests.indexWhere(
      (candidate) => candidate.refresh == request.refresh,
    );
    if (existingIndex < 0) {
      _pendingLoadRequests.add(request);
      return;
    }
    final existing = _pendingLoadRequests[existingIndex];
    if (request.forceRemote && !existing.forceRemote) {
      _pendingLoadRequests[existingIndex] = existing.copyWith(
        forceRemote: true,
      );
    }
  }

  Future<void> _drainLoadRequests(Completer<void> completer) async {
    try {
      while (!_disposed && _pendingLoadRequests.isNotEmpty) {
        final request = _pendingLoadRequests.removeAt(0);
        try {
          await _loadOnce(request);
        } catch (_) {
          _fail('NOTIFICATION_LOAD_FAILED');
        }
      }
    } finally {
      _loadDrain = null;
      if (!_disposed &&
          _state.status == NotificationControllerStatus.loading &&
          _state.pendingReadDeliveryKeys.isEmpty) {
        _set(
          _state.copyWith(
            status: _state.items.isEmpty && _state.lastErrorCode != null
                ? NotificationControllerStatus.failed
                : NotificationControllerStatus.ready,
          ),
        );
      }
      if (!completer.isCompleted) completer.complete();
    }
  }

  Future<void> _loadOnce(_NotificationLoadRequest request) async {
    final refresh = request.refresh;
    final forceRemote = request.forceRemote;
    if (!refresh && _state.nextCursor == null) return;
    final resolution = _loadResolutionSnapshot();
    final cache = _loadCachedPage();
    final now = _now().toUtc();
    final cacheIsFresh =
        cache != null &&
        !now.isBefore(cache.savedAt) &&
        now.difference(cache.savedAt) <= _effectiveCacheTtl;
    if (!forceRemote && cache != null && _state.items.isEmpty) {
      _set(_stateFromCache(cache, resolution));
    }
    if (refresh && cacheIsFresh && !forceRemote) return;
    _set(
      _stateWithResolution(
        _state.copyWith(
          status: NotificationControllerStatus.loading,
          clearError: true,
        ),
        resolution,
      ),
    );
    late final ApiResult<AppNotificationPage> result;
    try {
      result = await _api.listNotifications(
        cursor: refresh ? null : _state.nextCursor,
        limit: 100,
      );
    } catch (_) {
      if (!_disposed) {
        _applyLoadFailure(
          cache: cache,
          resolution: resolution,
          errorCode: 'NOTIFICATION_LOAD_FAILED',
        );
      }
      return;
    }
    if (_disposed) return;
    if (!result.ok || result.data == null) {
      _applyLoadFailure(
        cache: cache,
        resolution: resolution,
        errorCode: result.error?.code ?? 'NOTIFICATION_LOAD_FAILED',
      );
      return;
    }
    final page = result.data!;
    final currentById = <String, AppNotification>{
      if (cache != null)
        for (final item in cache.items) item.notificationId: item,
      for (final item in _state.items) item.notificationId: item,
    };
    final byId = <String, AppNotification>{
      if (!refresh)
        for (final item in _state.items) item.notificationId: item,
      for (final item in page.items)
        item.notificationId: switch (currentById[item.notificationId]) {
          final current? => _reconcileNotificationStatus(
            incoming: item,
            current: current,
          ),
          null => item,
        },
    };
    final items = byId.values.toList()
      ..sort((left, right) {
        final leftTime = left.inboxOccurredAt?.millisecondsSinceEpoch ?? 0;
        final rightTime = right.inboxOccurredAt?.millisecondsSinceEpoch ?? 0;
        return rightTime.compareTo(leftTime);
      });
    _set(
      _state.copyWith(
        status: _state.pendingReadDeliveryKeys.isEmpty
            ? NotificationControllerStatus.ready
            : NotificationControllerStatus.markingRead,
        items: List<AppNotification>.unmodifiable(items),
        nextCursor: page.nextCursor,
        clearNextCursor: page.nextCursor == null,
        rejectedItemCount: refresh
            ? page.rejectedItemCount
            : _state.rejectedItemCount + page.rejectedItemCount,
        handledIds: Set<String>.unmodifiable(<String>{
          ...resolution.handledIds,
          ..._state.handledIds,
        }),
        handledTaskIds: Set<String>.unmodifiable(<String>{
          ...resolution.handledTaskIds,
          ..._state.handledTaskIds,
        }),
        locallyReadIds: Set<String>.unmodifiable(<String>{
          ...resolution.locallyReadIds,
          ..._state.locallyReadIds,
        }),
        resolutionIsDemo: resolution.isDemo,
        resolutionHydrated: resolution.isHydrated || _state.resolutionHydrated,
        clearError: true,
      ),
    );
    if (refresh) await _saveLatestNotificationPage();
  }

  Duration get _effectiveCacheTtl {
    try {
      final resolved = _cacheTtlResolver?.call();
      if (resolved != null &&
          resolved > Duration.zero &&
          resolved <= const Duration(days: 1)) {
        return resolved;
      }
    } catch (_) {
      // A policy read failure must keep the existing offline cache usable.
    }
    return cacheTtl;
  }

  _NotificationResolutionSnapshot _loadResolutionSnapshot() {
    final handledIds = <String>{..._state.handledIds};
    final handledTaskIds = <String>{..._state.handledTaskIds};
    final locallyReadIds = <String>{..._state.locallyReadIds};
    var isHydrated = true;
    var isDemo = _state.resolutionIsDemo;
    try {
      handledIds.addAll(_resolution.loadHandledIds());
    } catch (_) {
      isHydrated = false;
    }
    try {
      locallyReadIds.addAll(_resolution.loadLocallyReadIds());
    } catch (_) {
      isHydrated = false;
    }
    final taskResolution = _resolution;
    if (taskResolution is TaskNotificationResolutionPort) {
      try {
        handledTaskIds.addAll(
          (taskResolution as TaskNotificationResolutionPort)
              .loadHandledTaskIds(),
        );
      } catch (_) {
        isHydrated = false;
      }
    }
    try {
      isDemo = _resolution.isDemo;
    } catch (_) {
      isHydrated = false;
    }
    final integrity = _resolution;
    if (integrity is NotificationResolutionIntegrityPort) {
      try {
        isHydrated =
            (integrity as NotificationResolutionIntegrityPort)
                .resolutionRecordsAreValid &&
            isHydrated;
      } catch (_) {
        isHydrated = false;
      }
    }
    return _NotificationResolutionSnapshot(
      handledIds: Set<String>.unmodifiable(handledIds),
      handledTaskIds: Set<String>.unmodifiable(handledTaskIds),
      locallyReadIds: Set<String>.unmodifiable(locallyReadIds),
      isDemo: isDemo,
      isHydrated: _state.resolutionHydrated || isHydrated,
    );
  }

  CachedNotificationPage? _loadCachedPage() {
    final resolution = _resolution;
    if (resolution is! NotificationPageCachePort) return null;
    try {
      return (resolution as NotificationPageCachePort).loadNotificationPage();
    } catch (_) {
      return null;
    }
  }

  NotificationControllerState _stateWithResolution(
    NotificationControllerState state,
    _NotificationResolutionSnapshot resolution,
  ) {
    return state.copyWith(
      handledIds: Set<String>.unmodifiable(<String>{
        ...state.handledIds,
        ...resolution.handledIds,
      }),
      handledTaskIds: Set<String>.unmodifiable(<String>{
        ...state.handledTaskIds,
        ...resolution.handledTaskIds,
      }),
      locallyReadIds: Set<String>.unmodifiable(<String>{
        ...state.locallyReadIds,
        ...resolution.locallyReadIds,
      }),
      resolutionIsDemo: resolution.isDemo,
      resolutionHydrated: state.resolutionHydrated || resolution.isHydrated,
    );
  }

  NotificationControllerState _stateFromCache(
    CachedNotificationPage cache,
    _NotificationResolutionSnapshot resolution, {
    NotificationControllerStatus status = NotificationControllerStatus.ready,
    String? errorCode,
  }) {
    return _stateWithResolution(
      _state.copyWith(
        status: status,
        items: cache.items,
        nextCursor: cache.nextCursor,
        clearNextCursor: cache.nextCursor == null,
        rejectedItemCount: cache.rejectedItemCount,
        lastErrorCode: errorCode,
        clearError: errorCode == null,
      ),
      resolution,
    );
  }

  void _applyLoadFailure({
    required CachedNotificationPage? cache,
    required _NotificationResolutionSnapshot resolution,
    required String errorCode,
  }) {
    if (_state.items.isEmpty && cache != null) {
      _set(
        _stateFromCache(
          cache,
          resolution,
          status: cache.items.isEmpty
              ? NotificationControllerStatus.failed
              : NotificationControllerStatus.ready,
          errorCode: errorCode,
        ),
      );
      return;
    }
    _fail(errorCode);
  }

  Future<bool> markHandled(AppNotification notification) async {
    if (!notification.canMarkHandled || _isTaskNotification(notification)) {
      return false;
    }
    return markHandledId(notificationDeliveryResolutionKey(notification));
  }

  /// Records that a terminal task's concrete result has rendered. This is
  /// deliberately separate from ordinary notification handling: queued and
  /// running tasks cannot disappear, while one stable public task key hides
  /// every terminal lifecycle delivery for this account.
  Future<bool> markTaskResultShown({
    required String taskId,
    Iterable<String> notificationIds = const <String>[],
  }) async {
    final resolutionKey = notificationTaskResolutionKey(taskId);
    if (resolutionKey == null) return false;
    if (_state.handledTaskIds.contains(resolutionKey)) return true;
    if (_state.pendingHandledTaskIds.contains(resolutionKey)) return false;
    final pending = <String>{..._state.pendingHandledTaskIds, resolutionKey};
    final safeNotificationIds = <String>{
      for (final notificationId in notificationIds)
        if (isSafeNotificationOpaqueIdentifier(notificationId)) notificationId,
    };
    final currentById = <String, AppNotification>{
      for (final item in _state.items) item.notificationId: item,
    };
    final deliveryResolutionKeys = <String>{
      for (final notificationId in safeNotificationIds)
        if (currentById[notificationId] case final notification?)
          if (notification.taskId == null || notification.taskId == taskId)
            notificationDeliveryResolutionKey(notification),
    };
    _set(
      _state.copyWith(
        pendingHandledTaskIds: Set<String>.unmodifiable(pending),
        clearError: true,
      ),
    );

    final taskResolution = _resolution is TaskNotificationResolutionPort
        ? _resolution as TaskNotificationResolutionPort
        : null;
    var saved = false;
    if (taskResolution != null) {
      try {
        saved = await taskResolution.markTaskHandled(resolutionKey);
      } catch (_) {
        saved = false;
      }
    }

    if (!saved) {
      final remainingPending = <String>{..._state.pendingHandledTaskIds}
        ..remove(resolutionKey);
      _set(
        _state.copyWith(
          pendingHandledTaskIds: Set<String>.unmodifiable(remainingPending),
          lastErrorCode: 'NOTIFICATION_TASK_RESULT_SAVE_FAILED',
        ),
      );
      return false;
    }

    // The task key is the durable commit. Revision-scoped delivery archives
    // are a compatibility aid for legacy rows that later omit `taskId`.
    final savedDeliveryResolutionKeys = <String>{};
    for (final deliveryResolutionKey in deliveryResolutionKeys) {
      try {
        if (await _resolution.markHandled(deliveryResolutionKey)) {
          savedDeliveryResolutionKeys.add(deliveryResolutionKey);
        }
      } catch (_) {
        // The committed task key remains authoritative for this account.
      }
    }
    final remainingPending = <String>{..._state.pendingHandledTaskIds}
      ..remove(resolutionKey);
    _set(
      _state.copyWith(
        status: NotificationControllerStatus.ready,
        pendingHandledTaskIds: Set<String>.unmodifiable(remainingPending),
        handledTaskIds: Set<String>.unmodifiable(<String>{
          ..._state.handledTaskIds,
          resolutionKey,
        }),
        handledIds: Set<String>.unmodifiable(<String>{
          ..._state.handledIds,
          ...savedDeliveryResolutionKeys,
        }),
        clearError: true,
      ),
    );
    return true;
  }

  bool _isTaskNotification(AppNotification notification) =>
      notification.taskId != null || notification.taskStatus != null;

  Future<bool> markHandledId(String notificationId) async {
    if (!isSafeNotificationIdentifier(notificationId)) return false;
    if (_state.handledIds.contains(notificationId) ||
        _state.pendingHandledIds.contains(notificationId)) {
      return false;
    }
    final pending = <String>{..._state.pendingHandledIds, notificationId};
    _set(
      _state.copyWith(
        pendingHandledIds: Set<String>.unmodifiable(pending),
        clearError: true,
      ),
    );
    var saved = false;
    try {
      saved = await _resolution.markHandled(notificationId);
    } catch (_) {
      saved = false;
    }
    final remainingPending = <String>{..._state.pendingHandledIds}
      ..remove(notificationId);
    if (!saved) {
      _set(
        _state.copyWith(
          pendingHandledIds: Set<String>.unmodifiable(remainingPending),
          lastErrorCode: 'NOTIFICATION_HANDLE_SAVE_FAILED',
        ),
      );
      return false;
    }
    _set(
      _state.copyWith(
        status: NotificationControllerStatus.ready,
        pendingHandledIds: Set<String>.unmodifiable(remainingPending),
        handledIds: Set<String>.unmodifiable(<String>{
          ..._state.handledIds,
          notificationId,
        }),
        clearError: true,
      ),
    );
    return true;
  }

  Future<bool> markLocalRead(String notificationId) async {
    if (!isSafeNotificationIdentifier(notificationId)) return false;
    if (_state.locallyReadIds.contains(notificationId)) return true;
    if (_state.pendingLocalReadIds.contains(notificationId)) return false;
    final pending = <String>{..._state.pendingLocalReadIds, notificationId};
    _set(
      _state.copyWith(
        pendingLocalReadIds: Set<String>.unmodifiable(pending),
        clearError: true,
      ),
    );
    var saved = false;
    try {
      saved = await _resolution.markLocallyRead(notificationId);
    } catch (_) {
      saved = false;
    }
    final remainingPending = <String>{..._state.pendingLocalReadIds}
      ..remove(notificationId);
    if (!saved) {
      _set(
        _state.copyWith(
          pendingLocalReadIds: Set<String>.unmodifiable(remainingPending),
          lastErrorCode: 'NOTIFICATION_LOCAL_READ_SAVE_FAILED',
        ),
      );
      return false;
    }
    final itemIndex = _state.items.indexWhere(
      (item) => notificationDeliveryResolutionKey(item) == notificationId,
    );
    List<AppNotification>? updatedItems;
    if (itemIndex >= 0 && _state.items[itemIndex].isUnread) {
      updatedItems = <AppNotification>[..._state.items];
      updatedItems[itemIndex] = updatedItems[itemIndex].copyWith(
        status: AppNotificationStatus.read,
      );
    }
    _set(
      _state.copyWith(
        items: updatedItems == null
            ? null
            : List<AppNotification>.unmodifiable(updatedItems),
        pendingLocalReadIds: Set<String>.unmodifiable(remainingPending),
        locallyReadIds: Set<String>.unmodifiable(<String>{
          ..._state.locallyReadIds,
          notificationId,
        }),
        clearError: true,
      ),
    );
    if (updatedItems != null) await _saveLatestNotificationPage();
    return true;
  }

  Future<bool> markRead(AppNotification notification) async {
    if (!notification.isUnread) return true;
    final requestDeliveryKey = notificationDeliveryResolutionKey(notification);
    if (notification.eventId != null) {
      return markLocalRead(requestDeliveryKey);
    }
    if (_state.pendingReadDeliveryKeys.contains(requestDeliveryKey)) {
      return false;
    }
    final pending = <String>{
      ..._state.pendingReadDeliveryKeys,
      requestDeliveryKey,
    };
    _set(
      _state.copyWith(
        status: _loadDrain == null
            ? NotificationControllerStatus.markingRead
            : NotificationControllerStatus.loading,
        pendingReadDeliveryKeys: Set<String>.unmodifiable(pending),
        clearError: true,
      ),
    );
    var succeeded = false;
    var shouldRefresh = false;
    var stateChanged = false;
    String? errorCode;
    List<AppNotification>? updatedItems;
    try {
      final result = await _api.markRead(
        notificationId: notification.notificationId,
        idempotency: IdempotencyRequestContext(
          explicitKey: 'idem-notification-read-$requestDeliveryKey',
        ),
      );
      final marked = result.data;
      if (!result.ok || marked == null) {
        errorCode = result.error?.code ?? 'NOTIFICATION_MARK_READ_FAILED';
      } else if (marked.notificationId != notification.notificationId ||
          marked.status == AppNotificationStatus.unread) {
        errorCode = 'NOTIFICATION_MARK_READ_RESPONSE_INVALID';
      } else {
        succeeded = true;
        final currentIndex = _state.items.indexWhere(
          (item) => item.notificationId == notification.notificationId,
        );
        if (currentIndex >= 0) {
          final current = _state.items[currentIndex];
          if (notificationDeliveryResolutionKey(current) !=
              requestDeliveryKey) {
            shouldRefresh = true;
          } else {
            final responseEventId = marked.eventId;
            final requestEventId = notification.eventId;
            final responseMatchesRequestEvent =
                marked.isReadReceipt ||
                responseEventId == null ||
                (requestEventId != null && responseEventId == requestEventId);
            if (!responseMatchesRequestEvent) {
              shouldRefresh = true;
            } else {
              updatedItems = <AppNotification>[..._state.items];
              updatedItems[currentIndex] = current.copyWith(
                status: marked.status,
              );
              stateChanged = true;
            }
          }
        }
      }
    } catch (_) {
      errorCode = 'NOTIFICATION_MARK_READ_FAILED';
    }

    final remainingPending = <String>{..._state.pendingReadDeliveryKeys}
      ..remove(requestDeliveryKey);
    final status = _loadDrain != null
        ? NotificationControllerStatus.loading
        : remainingPending.isNotEmpty
        ? NotificationControllerStatus.markingRead
        : errorCode == null
        ? NotificationControllerStatus.ready
        : NotificationControllerStatus.failed;
    _set(
      _state.copyWith(
        status: status,
        items: updatedItems == null
            ? null
            : List<AppNotification>.unmodifiable(updatedItems),
        pendingReadDeliveryKeys: Set<String>.unmodifiable(remainingPending),
        lastErrorCode: errorCode,
        clearError: errorCode == null,
      ),
    );

    if (stateChanged) await _saveLatestNotificationPage();
    if (succeeded) await markLocalRead(requestDeliveryKey);
    if (shouldRefresh && !_disposed) {
      unawaited(load(forceRemote: true));
    }
    return succeeded;
  }

  Future<void> _saveLatestNotificationPage() {
    final cachePort = _resolution is NotificationPageCachePort
        ? _resolution as NotificationPageCachePort
        : null;
    if (cachePort == null || _disposed) return Future<void>.value();
    _cacheSaveRequested = true;
    final active = _cacheSaveDrain;
    if (active != null) return active;

    final completer = Completer<void>();
    _cacheSaveDrain = completer.future;
    unawaited(_drainNotificationCacheSaves(cachePort, completer));
    return completer.future;
  }

  Future<void> _drainNotificationCacheSaves(
    NotificationPageCachePort cachePort,
    Completer<void> completer,
  ) async {
    try {
      while (!_disposed && _cacheSaveRequested) {
        _cacheSaveRequested = false;
        final page = AppNotificationPage(
          items: List<AppNotification>.unmodifiable(_state.items),
          nextCursor: _state.nextCursor,
          rejectedItemCount: _state.rejectedItemCount,
        );
        try {
          await cachePort.saveNotificationPage(page);
        } catch (_) {
          // Cache persistence never changes the authenticated server state.
        }
      }
    } finally {
      _cacheSaveDrain = null;
      if (!completer.isCompleted) completer.complete();
    }
  }

  void _fail(String errorCode) {
    final hasVisibleContent = _state.items.isNotEmpty;
    _set(
      _state.copyWith(
        // A cache-backed message center remains usable during an unavailable
        // refresh. Reserve failed state for the genuinely empty screen.
        status: hasVisibleContent
            ? NotificationControllerStatus.ready
            : NotificationControllerStatus.failed,
        lastErrorCode: errorCode,
      ),
    );
  }

  void _set(NotificationControllerState value) {
    if (_disposed) return;
    _state = value;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _cacheSaveRequested = false;
    super.dispose();
  }
}

final class _NotificationLoadRequest {
  const _NotificationLoadRequest({
    required this.refresh,
    required this.forceRemote,
  });

  final bool refresh;
  final bool forceRemote;

  _NotificationLoadRequest copyWith({bool? forceRemote}) {
    return _NotificationLoadRequest(
      refresh: refresh,
      forceRemote: forceRemote ?? this.forceRemote,
    );
  }
}

final class _NotificationResolutionSnapshot {
  const _NotificationResolutionSnapshot({
    required this.handledIds,
    required this.handledTaskIds,
    required this.locallyReadIds,
    required this.isDemo,
    required this.isHydrated,
  });

  final Set<String> handledIds;
  final Set<String> handledTaskIds;
  final Set<String> locallyReadIds;
  final bool isDemo;
  final bool isHydrated;
}

AppNotification _reconcileNotificationStatus({
  required AppNotification incoming,
  required AppNotification current,
}) {
  if (current.taskId != null &&
      current.taskId == incoming.taskId &&
      !preferTaskNotificationSnapshot(current: current, candidate: incoming)) {
    if (current.eventId != null &&
        current.eventId == incoming.eventId &&
        _notificationStatusRank(incoming.status) >
            _notificationStatusRank(current.status)) {
      return current.copyWith(status: incoming.status);
    }
    return current;
  }
  if (current.taskId != incoming.taskId) return incoming;
  if (_notificationStatusRank(incoming.status) >=
      _notificationStatusRank(current.status)) {
    return incoming;
  }
  if (!_isSameOrOlderNotificationDelivery(
    incoming: incoming,
    current: current,
  )) {
    return incoming;
  }
  return _mergeNotificationRevision(
    incoming,
    fallback: current,
  ).copyWith(status: current.status);
}

int _notificationStatusRank(AppNotificationStatus status) => switch (status) {
  AppNotificationStatus.unread => 0,
  AppNotificationStatus.read => 1,
  AppNotificationStatus.handled || AppNotificationStatus.expired => 2,
};

bool _isSameOrOlderNotificationDelivery({
  required AppNotification incoming,
  required AppNotification current,
}) {
  final incomingEventId = incoming.eventId;
  final currentEventId = current.eventId;
  if (incomingEventId != null && currentEventId != null) {
    return incomingEventId == currentEventId;
  }

  final incomingRevision = incoming.updatedAt ?? incoming.createdAt;
  final currentRevision = current.updatedAt ?? current.createdAt;
  if (incomingRevision != null && currentRevision != null) {
    return !incomingRevision.isAfter(currentRevision);
  }

  return incoming.eventType == current.eventType &&
      incoming.targetType == current.targetType &&
      incoming.targetId == current.targetId &&
      incoming.taskId == current.taskId;
}

AppNotification _mergeNotificationRevision(
  AppNotification notification, {
  required AppNotification fallback,
}) {
  return AppNotification(
    notificationId: notification.notificationId,
    eventType: notification.eventType,
    scene: notification.scene,
    targetType: notification.targetType,
    targetId: notification.targetId,
    title: notification.title,
    body: notification.body,
    status: notification.status,
    workspaceId: notification.workspaceId ?? fallback.workspaceId,
    taskStatus: notification.taskStatus,
    taskId: notification.taskId,
    eventId: notification.eventId ?? fallback.eventId,
    createdAt: notification.createdAt ?? fallback.createdAt,
    updatedAt: notification.updatedAt ?? fallback.updatedAt,
  );
}

String? notificationTaskResolutionKey(String taskId) {
  final normalized = taskId.trim();
  if (!isSafeNotificationTaskIdentifier(normalized)) return null;
  if (isSafeNotificationIdentifier(normalized)) return normalized;
  return 'task:${sha256.convert(utf8.encode(normalized))}';
}

String notificationDeliveryResolutionKey(AppNotification notification) {
  final revision =
      notification.eventId ??
      sha256
          .convert(
            utf8.encode(
              jsonEncode(<Object?>[
                notification.eventType,
                notification.scene,
                notification.targetType,
                notification.targetId,
                notification.workspaceId,
                notification.taskId,
                notification.taskStatus?.name,
                notification.createdAt?.toUtc().microsecondsSinceEpoch,
              ]),
            ),
          )
          .toString();
  final owner = notification.workspaceId;
  final digest = sha256.convert(
    utf8.encode(
      owner == null
          ? '${notification.notificationId}:$revision'
          : '$owner:${notification.notificationId}:$revision',
    ),
  );
  return 'delivery:$digest';
}

final class _SessionNotificationResolutionPort
    implements NotificationResolutionPort, TaskNotificationResolutionPort {
  final Set<String> _handledIds = <String>{};
  final Set<String> _handledTaskIds = <String>{};
  final Set<String> _locallyReadIds = <String>{};

  @override
  bool get isDemo => true;

  @override
  Set<String> loadHandledIds() => Set<String>.from(_handledIds);

  @override
  Set<String> loadHandledTaskIds() => Set<String>.from(_handledTaskIds);

  @override
  Set<String> loadLocallyReadIds() => Set<String>.from(_locallyReadIds);

  @override
  Future<bool> markHandled(String notificationId) async {
    if (!isSafeNotificationIdentifier(notificationId)) return false;
    _handledIds.add(notificationId);
    return true;
  }

  @override
  Future<bool> markTaskHandled(String taskId) async {
    if (!isSafeNotificationIdentifier(taskId)) return false;
    _handledTaskIds.add(taskId);
    return true;
  }

  @override
  Future<bool> markLocallyRead(String notificationId) async {
    if (!isSafeNotificationIdentifier(notificationId)) return false;
    _locallyReadIds.add(notificationId);
    return true;
  }
}
