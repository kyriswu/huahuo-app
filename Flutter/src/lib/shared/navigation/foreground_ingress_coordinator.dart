import 'dart:async';

import 'package:flutter/widgets.dart';

enum ForegroundIngressDecision { allow, cancel, busy }

/// Distinguishes a user decision from a concurrent request that must retry.
enum ForegroundIngressRequestResult { allow, cancel, busy }

typedef ForegroundIngressHandler =
    FutureOr<ForegroundIngressDecision> Function();
typedef ForegroundIngressActivePredicate = bool Function();

/// Tracks the root navigator well enough to distinguish a popup from a page.
///
/// A `PopupRoute` (for example a dialog or modal bottom sheet) should not let
/// an unsaved editor or active capture be silently covered. A newer
/// `PageRoute`, however, must make the older page ineligible so it cannot
/// intercept ingress intended for the visible screen.
class ForegroundIngressRouteObserver extends NavigatorObserver {
  final List<Route<dynamic>> _routeStack = <Route<dynamic>>[];

  /// Returns null until this observer has seen [route]'s navigator history.
  bool? isTopmostPageRoute(ModalRoute<dynamic> route) {
    if (!_routeStack.any((candidate) => identical(candidate, route))) {
      return null;
    }
    for (final candidate in _routeStack.reversed) {
      if (candidate is PageRoute<dynamic>) {
        return identical(candidate, route);
      }
    }
    return false;
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    if (previousRoute == null) {
      _routeStack
        ..clear()
        ..add(route);
      return;
    }
    _insertAbovePrevious(route, previousRoute);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPop(route, previousRoute);
    _routeStack.removeWhere((candidate) => identical(candidate, route));
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didRemove(route, previousRoute);
    _routeStack.removeWhere((candidate) => identical(candidate, route));
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    if (newRoute == null) return;
    final oldIndex = oldRoute == null
        ? -1
        : _routeStack.indexWhere((candidate) => identical(candidate, oldRoute));
    _routeStack.removeWhere((candidate) => identical(candidate, newRoute));
    if (oldIndex < 0) {
      _routeStack.add(newRoute);
      return;
    }
    _routeStack[oldIndex] = newRoute;
  }

  void _insertAbovePrevious(
    Route<dynamic> route,
    Route<dynamic> previousRoute,
  ) {
    _routeStack.removeWhere((candidate) => identical(candidate, route));
    final previousIndex = _routeStack.indexWhere(
      (candidate) => identical(candidate, previousRoute),
    );
    if (previousIndex < 0) {
      _routeStack.add(route);
      return;
    }
    _routeStack.insert(previousIndex + 1, route);
  }
}

/// Shared by the router and route guards; it observes only app navigation.
final foregroundIngressRouteObserver = ForegroundIngressRouteObserver();

/// Lets the currently visible route decide whether foreground ingress may push.
class ForegroundIngressCoordinator {
  final List<_ForegroundIngressRegistration> _registrations =
      <_ForegroundIngressRegistration>[];
  var _requestInFlight = false;
  Completer<void>? _requestSettled;

  VoidCallback register({
    required ForegroundIngressHandler onRequest,
    ForegroundIngressActivePredicate? isCurrent,
  }) {
    final registration = _ForegroundIngressRegistration(
      onRequest: onRequest,
      isCurrent: isCurrent ?? _alwaysCurrent,
    );
    _registrations.add(registration);
    return () {
      registration.disposed = true;
      _registrations.remove(registration);
    };
  }

  /// Resolves the current page decision without conflating busy and cancel.
  Future<ForegroundIngressRequestResult> requestNavigationResult() async {
    if (_requestInFlight) return ForegroundIngressRequestResult.busy;
    final registration = _currentRegistration();
    if (registration == null) return ForegroundIngressRequestResult.allow;

    _requestInFlight = true;
    final settled = Completer<void>();
    _requestSettled = settled;
    try {
      switch (await registration.onRequest()) {
        case ForegroundIngressDecision.allow:
          return ForegroundIngressRequestResult.allow;
        case ForegroundIngressDecision.cancel:
          return ForegroundIngressRequestResult.cancel;
        case ForegroundIngressDecision.busy:
          return ForegroundIngressRequestResult.busy;
      }
    } on Object {
      return ForegroundIngressRequestResult.cancel;
    } finally {
      _requestInFlight = false;
      if (identical(_requestSettled, settled)) {
        _requestSettled = null;
      }
      if (!settled.isCompleted) settled.complete();
    }
  }

  /// Compatibility helper for call sites that only need allow versus no-op.
  Future<bool> requestNavigation() async =>
      await requestNavigationResult() == ForegroundIngressRequestResult.allow;

  /// Completes after the active page confirmation has finished, if any.
  Future<void> waitUntilIdle() =>
      _requestSettled?.future ?? Future<void>.value();

  _ForegroundIngressRegistration? _currentRegistration() {
    for (final registration in _registrations.reversed) {
      if (registration.disposed) continue;
      try {
        if (registration.isCurrent()) return registration;
      } on Object {
        // A route being torn down cannot safely approve an ingress request.
      }
    }
    return null;
  }
}

bool _alwaysCurrent() => true;

class _ForegroundIngressRegistration {
  _ForegroundIngressRegistration({
    required this.onRequest,
    required this.isCurrent,
  });

  final ForegroundIngressHandler onRequest;
  final ForegroundIngressActivePredicate isCurrent;
  var disposed = false;
}

/// Makes the app-owned foreground ingress coordinator available to routes.
class ForegroundIngressScope extends InheritedWidget {
  const ForegroundIngressScope({
    required this.coordinator,
    required super.child,
    super.key,
  });

  final ForegroundIngressCoordinator coordinator;

  static ForegroundIngressCoordinator? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<ForegroundIngressScope>()
        ?.coordinator;
  }

  @override
  bool updateShouldNotify(ForegroundIngressScope oldWidget) {
    return !identical(coordinator, oldWidget.coordinator);
  }
}
