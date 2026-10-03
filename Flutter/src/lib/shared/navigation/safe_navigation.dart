import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import 'foreground_ingress_coordinator.dart';

NavigatorState? _previousRouteNavigator(BuildContext context) {
  var navigator = Navigator.maybeOf(context);
  while (navigator != null) {
    if (navigator.canPop()) return navigator;
    navigator = navigator.context.findAncestorStateOfType<NavigatorState>();
  }
  return null;
}

bool canReturnToPreviousRoute(BuildContext context) =>
    _previousRouteNavigator(context) != null;

Future<void> returnToPreviousRoute<T>(
  BuildContext context, {
  String fallbackRoute = '/v3',
  T? result,
}) async {
  if (!context.mounted) return;
  if (!canReturnToPreviousRoute(context)) {
    GoRouter.maybeOf(context)?.go(fallbackRoute);
    return;
  }
  var navigator = Navigator.maybeOf(context);
  while (navigator != null) {
    if (!navigator.mounted) return;
    final parent = navigator.context.findAncestorStateOfType<NavigatorState>();
    if (await navigator.maybePop<T>(result)) return;
    if (!context.mounted) return;
    navigator = parent;
  }
}

List<RouteMatch> _activeRoutePages(GoRouter router) {
  final pages = <RouteMatch>[];
  void collectPages(List<RouteMatchBase> matches) {
    for (final match in matches) {
      if (match is ShellRouteMatch) {
        collectPages(match.matches);
      } else if (match is RouteMatch) {
        pages.add(match);
      }
    }
  }

  collectPages(router.routerDelegate.currentConfiguration.matches);
  return pages;
}

Future<bool> visitChildRoute(GoRouter router, String location) async {
  final originPages = _activeRoutePages(router);
  if (originPages.isEmpty) return false;
  final delegate = router.routerDelegate;
  final informationProvider = router.routeInformationProvider;
  final finished = Completer<bool>();
  ImperativeRouteMatch? currentChild;
  Object? submittedRequest;

  void synchronizeRoutes() {
    if (finished.isCompleted) return;
    final pages = _activeRoutePages(router);
    if (pages.length < originPages.length) {
      finished.complete(false);
      return;
    }
    for (var index = 0; index < originPages.length; index += 1) {
      if (pages[index] != originPages[index]) {
        finished.complete(false);
        return;
      }
    }
    if (pages.length > originPages.length) {
      final child = pages[originPages.length];
      if (child is ImperativeRouteMatch) {
        currentChild = child;
      } else {
        finished.complete(false);
      }
      return;
    }
    final child = currentChild;
    if (child != null) finished.complete(child.completer.isCompleted);
  }

  void cancelSupersededRequest() {
    if (!finished.isCompleted &&
        currentChild == null &&
        !identical(informationProvider.value.state, submittedRequest)) {
      finished.complete(false);
    }
  }

  delegate.addListener(synchronizeRoutes);
  try {
    unawaited(
      router
          .push<void>(location)
          .then<void>(
            (_) => synchronizeRoutes(),
            onError: (Object error, StackTrace stackTrace) {
              if (!finished.isCompleted) {
                finished.completeError(error, stackTrace);
              }
            },
          ),
    );
    submittedRequest = informationProvider.value.state;
    informationProvider.addListener(cancelSupersededRequest);
    synchronizeRoutes();
    return await finished.future;
  } finally {
    delegate.removeListener(synchronizeRoutes);
    informationProvider.removeListener(cancelSupersededRequest);
  }
}

enum IngressNavigationAction { replace, push }

IngressNavigationAction ingressNavigationAction({required bool coldStart}) =>
    coldStart ? IngressNavigationAction.replace : IngressNavigationAction.push;

Future<bool> requestIngressNavigation({
  required IngressNavigationAction action,
  ForegroundIngressCoordinator? foregroundIngressCoordinator,
}) async {
  return await requestIngressNavigationResult(
        action: action,
        foregroundIngressCoordinator: foregroundIngressCoordinator,
      ) ==
      ForegroundIngressRequestResult.allow;
}

Future<ForegroundIngressRequestResult> requestIngressNavigationResult({
  required IngressNavigationAction action,
  ForegroundIngressCoordinator? foregroundIngressCoordinator,
}) async {
  if (action == IngressNavigationAction.replace ||
      foregroundIngressCoordinator == null) {
    return ForegroundIngressRequestResult.allow;
  }
  return foregroundIngressCoordinator.requestNavigationResult();
}

Future<bool> navigateForIngress(
  GoRouter router, {
  required String location,
  required IngressNavigationAction action,
  ForegroundIngressCoordinator? foregroundIngressCoordinator,
}) async {
  final allowed = await requestIngressNavigation(
    action: action,
    foregroundIngressCoordinator: foregroundIngressCoordinator,
  );
  if (!allowed) return false;
  switch (action) {
    case IngressNavigationAction.replace:
      router.go(location);
      return true;
    case IngressNavigationAction.push:
      unawaited(router.push<void>(location));
      return true;
  }
}
