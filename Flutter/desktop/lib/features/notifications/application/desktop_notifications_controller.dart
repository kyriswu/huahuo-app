import 'package:flutter/foundation.dart';

import '../domain/desktop_notifications_port.dart';

enum DesktopNotificationsPhase { idle, loading, ready, failure }

final class DesktopNotificationsState {
  const DesktopNotificationsState({
    required this.phase,
    this.items = const <DesktopNotification>[],
    this.nextCursor,
    this.pendingReadIds = const <String>{},
    this.errorMessage,
  });

  final DesktopNotificationsPhase phase;
  final List<DesktopNotification> items;
  final String? nextCursor;
  final Set<String> pendingReadIds;
  final String? errorMessage;

  bool get isLoading => phase == DesktopNotificationsPhase.loading;

  DesktopNotificationsState copyWith({
    DesktopNotificationsPhase? phase,
    List<DesktopNotification>? items,
    String? nextCursor,
    Set<String>? pendingReadIds,
    String? errorMessage,
    bool clearNextCursor = false,
    bool clearError = false,
  }) => DesktopNotificationsState(
    phase: phase ?? this.phase,
    items: items ?? this.items,
    nextCursor: clearNextCursor ? null : nextCursor ?? this.nextCursor,
    pendingReadIds: pendingReadIds ?? this.pendingReadIds,
    errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
  );
}

final class DesktopNotificationsController extends ChangeNotifier {
  DesktopNotificationsController(this._port);

  final DesktopNotificationsPort _port;
  DesktopNotificationsState _state = const DesktopNotificationsState(
    phase: DesktopNotificationsPhase.idle,
  );
  String? _userId;
  int _accountScope = 0;
  bool _disposed = false;

  DesktopNotificationsState get state => _state;

  void bindAccount(String userId) {
    final normalized = userId.trim();
    if (!isSafeDesktopNotificationIdentifier(normalized)) {
      clearAccount();
      return;
    }
    if (_userId == normalized) return;
    _accountScope += 1;
    _userId = normalized;
    _set(
      const DesktopNotificationsState(phase: DesktopNotificationsPhase.idle),
    );
  }

  void clearAccount() {
    _accountScope += 1;
    _userId = null;
    _set(
      const DesktopNotificationsState(phase: DesktopNotificationsPhase.idle),
    );
  }

  Future<void> load({bool refresh = true}) async {
    if (_userId == null || _state.isLoading) return;
    final cursor = refresh ? null : _state.nextCursor;
    if (!refresh && cursor == null) return;
    _set(
      _state.copyWith(
        phase: DesktopNotificationsPhase.loading,
        clearError: true,
      ),
    );
    final accountScope = _accountScope;
    final result = await _port.listNotifications(cursor: cursor, limit: 40);
    if (accountScope != _accountScope || _userId == null) return;
    if (!result.isSuccess || result.data == null) {
      _set(
        _state.copyWith(
          phase: _state.items.isEmpty
              ? DesktopNotificationsPhase.failure
              : DesktopNotificationsPhase.ready,
          errorMessage: result.message,
        ),
      );
      return;
    }
    final items = refresh
        ? result.data!.items
        : _merge(_state.items, result.data!.items);
    _set(
      DesktopNotificationsState(
        phase: DesktopNotificationsPhase.ready,
        items: List<DesktopNotification>.unmodifiable(items),
        nextCursor: result.data!.nextCursor,
        pendingReadIds: _state.pendingReadIds,
      ),
    );
  }

  Future<bool> markRead(DesktopNotification item) async {
    if (!item.isUnread) return true;
    if (_userId == null ||
        _state.pendingReadIds.contains(item.notificationId)) {
      return false;
    }
    final pending = <String>{..._state.pendingReadIds, item.notificationId};
    _set(_state.copyWith(pendingReadIds: Set<String>.unmodifiable(pending)));
    final accountScope = _accountScope;
    final result = await _port.markRead(
      notificationId: item.notificationId,
      idempotencyKey: 'desktop-notification-read-${item.notificationId}',
    );
    if (accountScope != _accountScope || _userId == null) return false;
    pending.remove(item.notificationId);
    if (!result.isSuccess ||
        result.data?.notificationId != item.notificationId) {
      _set(
        _state.copyWith(
          phase: DesktopNotificationsPhase.ready,
          pendingReadIds: Set<String>.unmodifiable(pending),
          errorMessage: result.message.isEmpty ? '通知已读状态保存失败' : result.message,
        ),
      );
      return false;
    }
    final marked = result.data!;
    _set(
      _state.copyWith(
        phase: DesktopNotificationsPhase.ready,
        items: List<DesktopNotification>.unmodifiable(<DesktopNotification>[
          for (final current in _state.items)
            current.notificationId == marked.notificationId
                ? (marked.eventType == 'notification.read'
                      ? current.copyWith(status: marked.status)
                      : marked)
                : current,
        ]),
        pendingReadIds: Set<String>.unmodifiable(pending),
        clearError: true,
      ),
    );
    return true;
  }

  List<DesktopNotification> _merge(
    Iterable<DesktopNotification> current,
    Iterable<DesktopNotification> next,
  ) {
    final merged = <String, DesktopNotification>{
      for (final item in current) item.notificationId: item,
    };
    for (final item in next) {
      merged[item.notificationId] = item;
    }
    return List<DesktopNotification>.unmodifiable(merged.values);
  }

  void _set(DesktopNotificationsState next) {
    if (_disposed) return;
    _state = next;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
