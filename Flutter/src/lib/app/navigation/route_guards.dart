import '../bootstrap/app_bootstrap_controller.dart';
import '../../core/auth/session_store.dart';
import 'app_route_paths.dart';

enum AppRouteKind {
  splash,
  restoreFailed,
  auth,
  workspaceRetry,
  onboarding,
  v3,
}

final class AppRouteDecision {
  const AppRouteDecision({
    required this.kind,
    required this.location,
    this.reason,
  });

  final AppRouteKind kind;
  final String location;
  final String? reason;
}

AppRouteDecision resolveAppRoute({
  required AppBootstrapState bootstrap,
  required SessionState session,
  bool onboardingDeferred = false,
  bool onboardingRunAccepted = false,
  bool startupJourneyPositioningHandled = false,
}) {
  if (bootstrap.status == AppBootstrapStatus.idle ||
      bootstrap.status == AppBootstrapStatus.restoring) {
    return const AppRouteDecision(
      kind: AppRouteKind.splash,
      location: '/splash',
      reason: 'bootstrap_restoring',
    );
  }
  if (bootstrap.status == AppBootstrapStatus.failed) {
    return AppRouteDecision(
      kind: AppRouteKind.restoreFailed,
      location: '/restore-failed',
      reason: bootstrap.errorCode,
    );
  }

  if (session.authState != SessionAuthState.authenticated) {
    return AppRouteDecision(
      kind: AppRouteKind.auth,
      location: '/auth',
      reason: session.authState == SessionAuthState.expired
          ? session.lastAuthErrorCode ?? 'token_expired'
          : 'anonymous',
    );
  }
  if (session.needsWorkspaceRetry ||
      session.workspaceStatus == SessionWorkspaceStatus.syncFailed) {
    return const AppRouteDecision(
      kind: AppRouteKind.workspaceRetry,
      location: '/workspace-retry',
      reason: 'workspace_sync_failed',
    );
  }
  if (session.workspaceStatus == SessionWorkspaceStatus.creating) {
    return const AppRouteDecision(
      kind: AppRouteKind.workspaceRetry,
      location: '/workspace-retry',
      reason: 'workspace_creating',
    );
  }
  if (session.requiresFirstLoginOnboarding &&
      !onboardingRunAccepted &&
      !startupJourneyPositioningHandled) {
    return const AppRouteDecision(
      kind: AppRouteKind.onboarding,
      location: '/onboarding',
      reason: 'onboarding_required',
    );
  }
  return const AppRouteDecision(
    kind: AppRouteKind.v3,
    location: '/v3',
    reason: 'authenticated',
  );
}

String? redirectForAppRoute({
  required String currentLocation,
  required AppBootstrapState bootstrap,
  required SessionState session,
  bool onboardingDeferred = false,
  bool onboardingRunAccepted = false,
  bool onboardingResumeRequested = false,
  bool startupJourneyBlocking = false,
  bool startupJourneyVoiceprintAllowed = false,
  bool startupJourneyPositioningRequired = false,
  bool startupJourneyPositioningHandled = false,
}) {
  final decision = resolveAppRoute(
    bootstrap: bootstrap,
    session: session,
    onboardingDeferred: onboardingDeferred,
    onboardingRunAccepted: onboardingRunAccepted,
    startupJourneyPositioningHandled: startupJourneyPositioningHandled,
  );
  final canResumeAcceptedOnboarding =
      session.requiresInitialPositioning && onboardingRunAccepted;
  if (decision.kind != AppRouteKind.splash &&
      decision.kind != AppRouteKind.restoreFailed &&
      isPublicHelpLocation(currentLocation)) {
    return null;
  }
  if (decision.kind == AppRouteKind.onboarding) {
    return currentLocation == '/onboarding' ? null : '/onboarding';
  }
  if (startupJourneyBlocking &&
      decision.kind != AppRouteKind.splash &&
      decision.kind != AppRouteKind.restoreFailed &&
      decision.kind != AppRouteKind.auth &&
      decision.kind != AppRouteKind.workspaceRetry) {
    if (startupJourneyPositioningRequired) {
      return currentLocation == '/onboarding' ? null : '/onboarding';
    }
    if (_isPositioningReadLocation(currentLocation) ||
        (currentLocation == '/onboarding' &&
            onboardingResumeRequested &&
            canResumeAcceptedOnboarding)) {
      return null;
    }
    if (currentLocation == AppRoutePaths.firstLaunchDeviceSetup) return null;
    if (startupJourneyVoiceprintAllowed &&
        currentLocation == '/v3/profile/voiceprint/enroll') {
      return null;
    }
    return AppRoutePaths.firstLaunchDeviceSetup;
  }
  if (decision.kind == AppRouteKind.v3 &&
      session.requiresInitialPositioning &&
      onboardingResumeRequested &&
      (startupJourneyPositioningHandled ||
          session.requiresFirstLoginOnboarding ||
          onboardingRunAccepted) &&
      currentLocation == '/onboarding') {
    return null;
  }
  if (decision.kind == AppRouteKind.v3 &&
      !session.requiresFirstLoginOnboarding &&
      !canResumeAcceptedOnboarding &&
      _isInitialPositioningRoute(currentLocation)) {
    return AppRoutePaths.home;
  }
  if (session.requiresInitialPositioning &&
      onboardingRunAccepted &&
      decision.kind == AppRouteKind.v3 &&
      _isAcceptedOnboardingTaskLocation(currentLocation)) {
    return null;
  }
  if (currentLocation == decision.location) {
    return null;
  }
  if (decision.kind == AppRouteKind.v3 && _isV3Location(currentLocation)) {
    return null;
  }
  return decision.location;
}

bool isPublicHelpLocation(String location) {
  return location == '/help' ||
      location.startsWith('/help/') ||
      location == '/legal/user-agreement' ||
      location == '/legal/privacy-policy';
}

bool _isV3Location(String location) {
  return location == '/v3' || location.startsWith('/v3/');
}

bool _isAcceptedOnboardingTaskLocation(String location) =>
    location == '/onboarding' ||
    location == '/v3/notifications' ||
    location == '/v3/positioning/progress';

bool _isInitialPositioningRoute(String location) => location == '/onboarding';

bool _isPositioningReadLocation(String location) => const <String>{
  '/v3/notifications',
  '/v3/positioning/progress',
  '/v3/profile/digital-twin',
  '/v3/workbench/deep-positioning',
}.contains(location);
