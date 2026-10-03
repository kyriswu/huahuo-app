import 'package:flutter/foundation.dart';

import 'app_activity_coordinator.dart';

final class PageActivityLease extends ChangeNotifier {
  PageActivityLease({
    required AppActivityCoordinator activity,
    bool routeVisible = true,
    bool tabActive = true,
    bool covered = false,
  }) : _activity = activity,
       _routeVisible = routeVisible,
       _tabActive = tabActive,
       _covered = covered,
       _active =
           activity.state.isForeground &&
           routeVisible &&
           tabActive &&
           !covered {
    _activity.addListener(_handleAppActivity);
  }

  final AppActivityCoordinator _activity;
  bool _routeVisible;
  bool _tabActive;
  bool _covered;
  bool _active;
  bool _disposed = false;
  int _activationGeneration = 0;

  bool get active => _active;
  bool get routeVisible => _routeVisible;
  bool get tabActive => _tabActive;
  bool get covered => _covered;
  int get activationGeneration => _activationGeneration;

  void setRouteVisible(bool value) {
    if (_disposed || value == _routeVisible) return;
    _routeVisible = value;
    _recompute();
  }

  void setTabActive(bool value) {
    if (_disposed || value == _tabActive) return;
    _tabActive = value;
    _recompute();
  }

  void setCovered(bool value) {
    if (_disposed || value == _covered) return;
    _covered = value;
    _recompute();
  }

  void _handleAppActivity() => _recompute();

  void _recompute() {
    final next =
        _activity.state.isForeground &&
        _routeVisible &&
        _tabActive &&
        !_covered;
    if (next == _active) return;
    _active = next;
    if (next) _activationGeneration += 1;
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _activity.removeListener(_handleAppActivity);
    super.dispose();
  }
}
