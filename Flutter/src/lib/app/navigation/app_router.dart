// ignore_for_file: curly_braces_in_flow_control_structures

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../di/onboarding_providers.dart';
import '../bootstrap/app_providers.dart';
import '../../shared/navigation/foreground_ingress_coordinator.dart';
import '../../shared/theme/huahuo_v3_theme.dart';
import 'app_route_observer.dart';
import 'app_route_paths.dart';
import 'app_route_screens.dart';
import 'app_routes.dart';
import 'legacy_route_redirect.dart';
import 'pending_navigation_controller.dart';
import 'route_guards.dart';

export 'app_route_screens.dart';
export 'legacy_route_redirect.dart' show v3LocationForLegacyMainUri;

const appRouterRestorationScopeId = 'huahuo-router';

// resident-provider: Preserves the app router dependency identity across route changes.
final appRouterProvider = Provider<GoRouter>((ref) {
  final sessionStore = ref.read(sessionStoreProvider);
  final bootstrapController = ref.read(appBootstrapControllerProvider);
  final onboardingContinuation = ref.read(
    onboardingContinuationControllerProvider,
  );
  final firstLaunchDeviceSetup = ref.read(
    firstLaunchDeviceSetupControllerProvider,
  );
  final pendingNavigation = ref.read(pendingNavigationControllerProvider);
  const v3InitialRoute = String.fromEnvironment('HUAHUO_V3_INITIAL_ROUTE');

  final router = GoRouter(
    restorationScopeId: appRouterRestorationScopeId,
    extraCodec: appRouteExtraCodec,
    observers: <NavigatorObserver>[
      appRouteObserver,
      foregroundIngressRouteObserver,
    ],
    initialLocation: huahuoV3UiEnabled && huahuoV3DemoAuthBypassEnabled
        ? _safeV3InitialRoute(v3InitialRoute)
        : _safeV3GuardedInitialRoute(v3InitialRoute),
    refreshListenable: Listenable.merge([
      sessionStore,
      bootstrapController,
      onboardingContinuation,
      firstLaunchDeviceSetup,
      pendingNavigation,
    ]),
    redirect: (context, state) {
      if (huahuoV3UiEnabled) {
        final legacyLocation = v3LocationForLegacyMainUri(state.uri);
        if (legacyLocation != null) return legacyLocation;
        if (huahuoV3DemoAuthBypassEnabled && state.uri.path.startsWith('/v3')) {
          return null;
        }
      }
      final destination = redirectForAppRoute(
        currentLocation: state.uri.path,
        bootstrap: bootstrapController.state,
        session: sessionStore.state,
        onboardingDeferred: onboardingContinuation.isDeferredFor(
          sessionStore.state.user?.userId,
        ),
        onboardingRunAccepted: onboardingContinuation.hasRegisteredRunFor(
          sessionStore.state.user?.userId,
          sessionStore.state.workspace?.workspaceId,
        ),
        startupJourneyBlocking: firstLaunchDeviceSetup.requiresBlockingJourney,
        startupJourneyPositioningRequired:
            firstLaunchDeviceSetup.requiresPositioning,
        startupJourneyPositioningHandled:
            firstLaunchDeviceSetup.snapshot.positioning.hasExited,
        startupJourneyVoiceprintAllowed:
            firstLaunchDeviceSetup.allowsVoiceprintEnrollment,
        onboardingResumeRequested: state.uri.queryParameters['resume'] == '1',
      );
      if (shouldStagePendingNavigation(
        currentLocation: state.uri.toString(),
        redirectedLocation: destination,
      )) {
        pendingNavigation.stage(
          location: state.uri.toString(),
          reason: PendingNavigationReason.deepLink,
        );
      }
      return destination;
    },
    routes: buildAppRoutes(
      splashBuilder: (context, state) => const SplashScreen(),
      restoreFailedBuilder: (context, state) => const RestoreFailedScreen(),
      workspaceRetryBuilder: (context, state) => const WorkspaceStatusScreen(),
    ),
  );
  ref.onDispose(router.dispose);
  return router;
});

String _safeV3InitialRoute(String value) {
  final path = Uri.tryParse(value)?.path ?? '';
  if (value == AppRoutePaths.auth || isPublicHelpLocation(path)) {
    return value;
  }
  if (path == AppRoutePaths.home || path.startsWith('${AppRoutePaths.home}/')) {
    return value;
  }
  return AppRoutePaths.home;
}

String _safeV3GuardedInitialRoute(String value) {
  if (value == AppRoutePaths.auth ||
      isPublicHelpLocation(Uri.tryParse(value)?.path ?? '')) {
    return value;
  }
  return AppRoutePaths.splash;
}
