import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

enum AppVisibility { foreground, inactive, background }

enum AppPowerClass { normal, lowPower, thermalLimited }

@immutable
final class AppActivityState {
  const AppActivityState({
    required this.visibility,
    required this.route,
    required this.activeTab,
    required this.powerClass,
    required this.networkAvailable,
    required this.foregroundGeneration,
    required this.memoryPressureRevision,
    required this.viewMetricsRevision,
    required this.reduceMotion,
    bool? canRunForegroundWork,
  }) : canRunForegroundWork =
           canRunForegroundWork ?? visibility == AppVisibility.foreground;

  factory AppActivityState.initial(
    AppLifecycleState? lifecycleState, {
    bool reduceMotion = false,
  }) {
    final visibility = _visibilityFor(lifecycleState);
    return AppActivityState(
      visibility: visibility,
      route: '/',
      activeTab: '',
      powerClass: AppPowerClass.normal,
      networkAvailable: true,
      foregroundGeneration: visibility == AppVisibility.foreground ? 1 : 0,
      memoryPressureRevision: 0,
      viewMetricsRevision: 0,
      reduceMotion: reduceMotion,
    );
  }

  final AppVisibility visibility;
  final String route;
  final String activeTab;
  final AppPowerClass powerClass;
  final bool networkAvailable;
  final int foregroundGeneration;
  final int memoryPressureRevision;
  final int viewMetricsRevision;
  final bool reduceMotion;
  final bool canRunForegroundWork;

  bool get isForeground => visibility == AppVisibility.foreground;
  bool get isBackground => visibility == AppVisibility.background;

  AppActivityState copyWith({
    AppVisibility? visibility,
    String? route,
    String? activeTab,
    AppPowerClass? powerClass,
    bool? networkAvailable,
    int? foregroundGeneration,
    int? memoryPressureRevision,
    int? viewMetricsRevision,
    bool? reduceMotion,
    bool? canRunForegroundWork,
  }) => AppActivityState(
    visibility: visibility ?? this.visibility,
    route: route ?? this.route,
    activeTab: activeTab ?? this.activeTab,
    powerClass: powerClass ?? this.powerClass,
    networkAvailable: networkAvailable ?? this.networkAvailable,
    foregroundGeneration: foregroundGeneration ?? this.foregroundGeneration,
    memoryPressureRevision:
        memoryPressureRevision ?? this.memoryPressureRevision,
    viewMetricsRevision: viewMetricsRevision ?? this.viewMetricsRevision,
    reduceMotion: reduceMotion ?? this.reduceMotion,
    canRunForegroundWork: canRunForegroundWork ?? this.canRunForegroundWork,
  );

  @override
  bool operator ==(Object other) =>
      other is AppActivityState &&
      visibility == other.visibility &&
      route == other.route &&
      activeTab == other.activeTab &&
      powerClass == other.powerClass &&
      networkAvailable == other.networkAvailable &&
      foregroundGeneration == other.foregroundGeneration &&
      memoryPressureRevision == other.memoryPressureRevision &&
      viewMetricsRevision == other.viewMetricsRevision &&
      reduceMotion == other.reduceMotion &&
      canRunForegroundWork == other.canRunForegroundWork;

  @override
  int get hashCode => Object.hash(
    visibility,
    route,
    activeTab,
    powerClass,
    networkAvailable,
    foregroundGeneration,
    memoryPressureRevision,
    viewMetricsRevision,
    reduceMotion,
    canRunForegroundWork,
  );
}

// resident-provider: Preserves the app activity coordinator dependency identity across route changes.
final appActivityCoordinatorProvider =
    ChangeNotifierProvider<AppActivityCoordinator>((ref) {
      final binding = WidgetsFlutterBinding.ensureInitialized();
      final coordinator = AppActivityCoordinator(binding: binding)..attach();
      ref.onDispose(coordinator.dispose);
      return coordinator;
    });

/// The application-wide low-frequency source for lifecycle and attention.
final class AppActivityCoordinator extends ChangeNotifier
    with WidgetsBindingObserver {
  AppActivityCoordinator({WidgetsBinding? binding})
    : _binding = binding ?? WidgetsBinding.instance,
      _state = AppActivityState.initial(
        (binding ?? WidgetsBinding.instance).lifecycleState,
        reduceMotion: (binding ?? WidgetsBinding.instance)
            .platformDispatcher
            .accessibilityFeatures
            .disableAnimations,
      );

  final WidgetsBinding _binding;
  AppActivityState _state;
  bool _attached = false;
  bool _disposed = false;

  AppActivityState get state => _state;
  bool get attached => _attached;

  void attach() {
    if (_attached || _disposed) return;
    _attached = true;
    _binding.addObserver(this);
  }

  void detach() {
    if (!_attached) return;
    _attached = false;
    _binding.removeObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    updateLifecycle(state);
  }

  @visibleForTesting
  void updateLifecycle(AppLifecycleState state) {
    final visibility = _visibilityFor(state);
    if (visibility == _state.visibility) return;
    final canRunForegroundWork = switch (visibility) {
      AppVisibility.foreground => true,
      AppVisibility.inactive => _state.canRunForegroundWork,
      AppVisibility.background => false,
    };
    final resumedAfterSuspension =
        visibility == AppVisibility.foreground && !_state.canRunForegroundWork;
    _replace(
      _state.copyWith(
        visibility: visibility,
        foregroundGeneration: resumedAfterSuspension
            ? _state.foregroundGeneration + 1
            : _state.foregroundGeneration,
        canRunForegroundWork: canRunForegroundWork,
      ),
    );
  }

  void updateRoute(String route) {
    final normalized = _canonicalRoute(route);
    if (normalized == _state.route) return;
    _replace(_state.copyWith(route: normalized));
  }

  void updateActiveTab(String tab) {
    final normalized = tab.trim();
    if (normalized == _state.activeTab) return;
    _replace(_state.copyWith(activeTab: normalized));
  }

  void updatePowerClass(AppPowerClass powerClass) {
    if (powerClass == _state.powerClass) return;
    _replace(_state.copyWith(powerClass: powerClass));
  }

  void updateNetworkAvailability(bool available) {
    if (available == _state.networkAvailable) return;
    _replace(_state.copyWith(networkAvailable: available));
  }

  @override
  void didHaveMemoryPressure() {
    _replace(
      _state.copyWith(
        memoryPressureRevision: _state.memoryPressureRevision + 1,
      ),
    );
  }

  @override
  void didChangeMetrics() {
    _replace(
      _state.copyWith(viewMetricsRevision: _state.viewMetricsRevision + 1),
    );
  }

  @override
  void didChangeAccessibilityFeatures() {
    updateReduceMotion(
      _binding.platformDispatcher.accessibilityFeatures.disableAnimations,
    );
  }

  @visibleForTesting
  void updateReduceMotion(bool reduceMotion) {
    if (reduceMotion == _state.reduceMotion) return;
    _replace(_state.copyWith(reduceMotion: reduceMotion));
  }

  void _replace(AppActivityState next) {
    if (_disposed || next == _state) return;
    _state = next;
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    detach();
    super.dispose();
  }
}

AppVisibility _visibilityFor(AppLifecycleState? state) => switch (state) {
  AppLifecycleState.resumed || null => AppVisibility.foreground,
  AppLifecycleState.inactive => AppVisibility.inactive,
  AppLifecycleState.paused ||
  AppLifecycleState.hidden ||
  AppLifecycleState.detached => AppVisibility.background,
};

String _canonicalRoute(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) return '/';
  final query = trimmed.indexOf('?');
  final fragment = trimmed.indexOf('#');
  final end = <int>[if (query >= 0) query, if (fragment >= 0) fragment]
      .fold<int>(
        trimmed.length,
        (value, candidate) => candidate < value ? candidate : value,
      );
  final route = trimmed.substring(0, end);
  return route.startsWith('/') ? route : '/$route';
}
