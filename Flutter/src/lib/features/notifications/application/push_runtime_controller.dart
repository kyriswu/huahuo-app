import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/auth/session_store.dart';
import '../domain/push_message.dart';
import '../infrastructure/push_provider.dart';
import 'notification_controller.dart';
import 'push_navigation_controller.dart';
import 'push_registration_controller.dart';

final class PushRuntimeState {
  const PushRuntimeState({this.foregroundMessage, this.bannerId = 0});

  final PushMessage? foregroundMessage;
  final int bannerId;
}

final class PushRuntimeController extends ChangeNotifier {
  PushRuntimeController({
    required PushProvider provider,
    required NotificationController notifications,
    required PushNavigationController navigation,
    required PushRegistrationController registration,
    required SessionStore sessionStore,
  }) : _provider = provider,
       _notifications = notifications,
       _navigation = navigation,
       _registration = registration,
       _sessionStore = sessionStore {
    _accountUserId = _currentUserId;
    _sessionStore.addListener(_handleAccountChanged);
  }

  final PushProvider _provider;
  final NotificationController _notifications;
  final PushNavigationController _navigation;
  final PushRegistrationController _registration;
  final SessionStore _sessionStore;
  final _subscriptions = <StreamSubscription<Object?>>[];
  PushRuntimeState _state = const PushRuntimeState();
  bool _started = false;
  Future<void>? _startFuture;
  bool _startRequested = false;
  String? _accountUserId;
  var _accountGeneration = 0;
  bool _initialConsumed = false;
  bool _disposed = false;

  PushRuntimeState get state => _state;

  Future<void> start() {
    if (_disposed || !_provider.isConfigured || !_isAuthenticated) {
      return Future<void>.value();
    }
    _startRequested = true;
    final active = _startFuture;
    if (active != null) return active;
    final completer = Completer<void>();
    _startFuture = completer.future;
    unawaited(_drainStart(completer));
    return completer.future;
  }

  Future<void> _drainStart(Completer<void> completer) async {
    try {
      while (_startRequested && !_disposed && _isAuthenticated) {
        _startRequested = false;
        await _startOnce();
      }
    } finally {
      _startFuture = null;
      completer.complete();
    }
  }

  Future<void> _startOnce() async {
    if (!_started) {
      _started = true;
      _subscriptions.add(
        _provider.foregroundMessages.listen(_receiveForeground),
      );
      _subscriptions.add(
        _provider.openedMessages.listen(
          (result) => _receiveNavigation(result, PushReceiveType.opened),
        ),
      );
      _subscriptions.add(
        _provider.connections.listen((_) {
          if (!_disposed && _isAuthenticated) unawaited(start());
        }),
      );
    }
    final generation = _accountGeneration;
    final registration = _registration.synchronize();
    try {
      if (_initialConsumed) return;
      await _provider.initialize().timeout(const Duration(seconds: 15));
      if (_disposed ||
          generation != _accountGeneration ||
          !_isAuthenticated ||
          _initialConsumed ||
          !_provider.isConfigured) {
        return;
      }
      final initial = await _provider.getInitialMessage().timeout(
        const Duration(seconds: 15),
      );
      if (_disposed || generation != _accountGeneration || !_isAuthenticated) {
        return;
      }
      _initialConsumed = true;
      if (initial != null) {
        _receiveNavigation(initial, PushReceiveType.coldStart);
      }
    } catch (_) {
      return;
    } finally {
      await registration;
    }
  }

  void _receiveForeground(PushParseResult result) {
    if (_disposed || !_isAuthenticated) return;
    // A Push is authoritative invalidation, including an in-progress task
    // changing to a terminal state.
    unawaited(_notifications.load(forceRemote: true));
    if (result is! ValidPushMessage) return;
    _state = PushRuntimeState(
      foregroundMessage: result.message,
      bannerId: _state.bannerId + 1,
    );
    notifyListeners();
  }

  void _receiveNavigation(PushParseResult result, PushReceiveType receiveType) {
    if (_disposed || !_isAuthenticated) return;
    unawaited(_notifications.load(forceRemote: true));
    _navigation.receive(result, receiveType);
  }

  void openForeground(int bannerId) {
    if (!_isAuthenticated) return;
    final message = _state.foregroundMessage;
    if (message == null || bannerId != _state.bannerId) return;
    _navigation.openForeground(message);
    dismissForeground(bannerId);
  }

  void dismissForeground(int bannerId) {
    if (bannerId != _state.bannerId) return;
    _state = PushRuntimeState(bannerId: bannerId);
    notifyListeners();
  }

  Future<void> resume() => start();

  void clearForLogout() {
    if (_disposed) return;
    _accountGeneration += 1;
    _initialConsumed = true;
    _state = PushRuntimeState(bannerId: _state.bannerId);
    _navigation.clear();
    notifyListeners();
  }

  String? get _currentUserId =>
      _isAuthenticated ? _sessionStore.state.user?.userId : null;

  void _handleAccountChanged() {
    final next = _currentUserId;
    if (_accountUserId == next) return;
    if (_accountUserId != null) {
      clearForLogout();
    } else {
      _accountGeneration += 1;
    }
    _accountUserId = next;
    if (_startFuture != null && next != null) _startRequested = true;
  }

  bool get _isAuthenticated {
    final session = _sessionStore.state;
    return session.authState == SessionAuthState.authenticated &&
        session.user != null;
  }

  @override
  void dispose() {
    _disposed = true;
    _sessionStore.removeListener(_handleAccountChanged);
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    super.dispose();
  }
}
