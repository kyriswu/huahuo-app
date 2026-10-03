import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../lifecycle/app_activity_coordinator.dart';

final RouteObserver<PageRoute<dynamic>> appRouteObserver =
    RouteObserver<PageRoute<dynamic>>();

/// Shared foreground-and-current-route gate for page-scoped work.
mixin AppActivityRouteAware<T extends ConsumerStatefulWidget>
    on ConsumerState<T>
    implements RouteAware {
  PageRoute<dynamic>? _activityPageRoute;
  ModalRoute<dynamic>? _activityModalRoute;
  bool _activityRouteVisible = true;
  late bool _activityForeground;
  late bool _activitySignalActive;

  @protected
  bool get activityRouteCanRun =>
      mounted &&
      _activityForeground &&
      _activityRouteVisible &&
      (_activityModalRoute?.isCurrent ?? true);

  @protected
  void onActivityRouteBecameActive();

  @protected
  void onActivityRouteBecameInactive() {}

  @override
  @mustCallSuper
  void initState() {
    super.initState();
    _activityForeground = ref
        .read(appActivityCoordinatorProvider)
        .state
        .isForeground;
    _activitySignalActive = activityRouteCanRun;
    ref.listenManual<bool>(
      appActivityCoordinatorProvider.select(
        (coordinator) => coordinator.state.isForeground,
      ),
      (previous, next) {
        _activityForeground = next;
        _syncActivityRouteSignal();
      },
    );
  }

  @override
  @mustCallSuper
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (identical(route, _activityModalRoute)) {
      if (activityRouteCanRun && !_activitySignalActive) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _syncActivityRouteSignal();
        });
      } else {
        _syncActivityRouteSignal();
      }
      return;
    }
    final previousPage = _activityPageRoute;
    if (previousPage != null) appRouteObserver.unsubscribe(this);
    _activityModalRoute = route;
    _activityPageRoute = route is PageRoute<dynamic> ? route : null;
    _activityRouteVisible = route?.isCurrent ?? true;
    _syncActivityRouteSignal();
    final page = _activityPageRoute;
    if (page != null) appRouteObserver.subscribe(this, page);
  }

  @override
  void didPush() => _setActivityRouteVisible(true);

  @override
  void didPushNext() => _setActivityRouteVisible(false);

  @override
  void didPop() => _setActivityRouteVisible(false);

  @override
  void didPopNext() => _setActivityRouteVisible(true);

  void _setActivityRouteVisible(bool visible) {
    _activityRouteVisible = visible;
    _syncActivityRouteSignal();
  }

  void _syncActivityRouteSignal() {
    final isActive = activityRouteCanRun;
    if (_activitySignalActive == isActive) return;
    _activitySignalActive = isActive;
    if (isActive) {
      onActivityRouteBecameActive();
    } else {
      onActivityRouteBecameInactive();
    }
  }

  @override
  @mustCallSuper
  void dispose() {
    final page = _activityPageRoute;
    if (page != null) appRouteObserver.unsubscribe(this);
    _activityPageRoute = null;
    _activityModalRoute = null;
    _activityRouteVisible = false;
    super.dispose();
  }
}
