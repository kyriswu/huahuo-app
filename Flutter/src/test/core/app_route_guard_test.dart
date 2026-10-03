import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/app/bootstrap/app_bootstrap_controller.dart';
import 'package:huahuoai_app/app/navigation/app_route_paths.dart';
import 'package:huahuoai_app/app/navigation/route_guards.dart';
import 'package:huahuoai_app/core/auth/session_store.dart';

void main() {
  test('persisted positioning exit admits next step without a fake Run', () {
    final session = _authenticated(
      onboardingRequired: true,
      firstLoginThisSession: true,
    );
    expect(
      redirectForAppRoute(
        currentLocation: AppRoutePaths.home,
        bootstrap: const AppBootstrapState.ready(),
        session: session,
        startupJourneyPositioningHandled: true,
        startupJourneyBlocking: true,
      ),
      AppRoutePaths.firstLaunchDeviceSetup,
    );
    expect(
      redirectForAppRoute(
        currentLocation: '/v3/profile/voiceprint/enroll',
        bootstrap: const AppBootstrapState.ready(),
        session: session,
        startupJourneyPositioningHandled: true,
        startupJourneyBlocking: true,
        startupJourneyVoiceprintAllowed: true,
      ),
      isNull,
    );
  });
  test('device guidance permits accepted reports and explicit retry only', () {
    final session = _authenticated(
      onboardingRequired: true,
      firstLoginThisSession: true,
    );
    for (final location in [
      '/v3/profile/digital-twin',
      '/v3/positioning/progress',
      '/v3/workbench/deep-positioning',
      '/v3/notifications',
      '/onboarding',
    ]) {
      expect(
        redirectForAppRoute(
          currentLocation: location,
          bootstrap: const AppBootstrapState.ready(),
          session: session,
          onboardingRunAccepted: true,
          onboardingResumeRequested: location == '/onboarding',
          startupJourneyBlocking: true,
          startupJourneyPositioningHandled: true,
          startupJourneyVoiceprintAllowed: true,
        ),
        isNull,
        reason: location,
      );
      expect(
        redirectForAppRoute(
          currentLocation: location,
          bootstrap: const AppBootstrapState.ready(),
          session: session,
          startupJourneyBlocking: true,
        ),
        location == '/onboarding' ? isNull : '/onboarding',
      );
    }
    expect(
      redirectForAppRoute(
        currentLocation: '/v3/feed/chat',
        bootstrap: const AppBootstrapState.ready(),
        session: session,
        onboardingRunAccepted: true,
        startupJourneyBlocking: true,
        startupJourneyPositioningHandled: true,
      ),
      AppRoutePaths.firstLaunchDeviceSetup,
    );
  });

  test('persisted positioning step resumes on a returning session', () {
    expect(
      redirectForAppRoute(
        currentLocation: '/v3',
        bootstrap: const AppBootstrapState.ready(),
        session: _authenticated(onboardingRequired: true),
        startupJourneyBlocking: true,
        startupJourneyPositioningRequired: true,
      ),
      '/onboarding',
    );
  });

  test(
    'accepted background failure does not replay completed device steps',
    () {
      final session = _authenticated(
        onboardingRequired: true,
        firstLoginThisSession: true,
      );
      expect(
        redirectForAppRoute(
          currentLocation: '/onboarding',
          bootstrap: const AppBootstrapState.ready(),
          session: session,
          startupJourneyPositioningHandled: true,
          onboardingRunAccepted: true,
          startupJourneyBlocking: true,
        ),
        AppRoutePaths.firstLaunchDeviceSetup,
      );
      expect(
        redirectForAppRoute(
          currentLocation: '/v3',
          bootstrap: const AppBootstrapState.ready(),
          session: session,
          startupJourneyPositioningHandled: true,
          onboardingRunAccepted: true,
        ),
        isNull,
      );
    },
  );

  test(
    'explicit positioning retry after restart does not replay completed device guidance',
    () {
      expect(
        redirectForAppRoute(
          currentLocation: '/onboarding',
          bootstrap: const AppBootstrapState.ready(),
          session: _authenticated(onboardingRequired: true),
          startupJourneyPositioningHandled: true,
          onboardingResumeRequested: true,
        ),
        isNull,
      );
    },
  );

  group('route guards', () {
    test('restoring routes to splash', () {
      final decision = resolveAppRoute(
        bootstrap: const AppBootstrapState.restoring(),
        session: SessionState.anonymous(),
      );

      expect(decision.kind, AppRouteKind.splash);
      expect(decision.location, '/splash');
    });

    test('anonymous routes to auth after bootstrap ready', () {
      final decision = resolveAppRoute(
        bootstrap: const AppBootstrapState.ready(),
        session: SessionState.anonymous(),
      );

      expect(decision.kind, AppRouteKind.auth);
      expect(decision.location, '/auth');
    });

    test('bootstrap failed routes to restore failed before session route', () {
      final decision = resolveAppRoute(
        bootstrap: const AppBootstrapState.failed('SESSION_RESTORE_FAILED'),
        session: _authenticated(),
      );

      expect(decision.kind, AppRouteKind.restoreFailed);
      expect(decision.location, '/restore-failed');
      expect(decision.reason, 'SESSION_RESTORE_FAILED');
    });

    test('expired session routes to auth with safe reason', () {
      final decision = resolveAppRoute(
        bootstrap: const AppBootstrapState.ready(),
        session: SessionState.anonymous().copyWith(
          authState: SessionAuthState.expired,
          lastAuthErrorCode: 'AUTH_SESSION_EXPIRED',
        ),
      );

      expect(decision.kind, AppRouteKind.auth);
      expect(decision.location, '/auth');
      expect(decision.reason, 'AUTH_SESSION_EXPIRED');
    });

    test('workspace sync failure routes to workspace retry', () {
      final decision = resolveAppRoute(
        bootstrap: const AppBootstrapState.ready(),
        session: _authenticated(
          workspaceStatus: SessionWorkspaceStatus.syncFailed,
        ),
      );

      expect(decision.kind, AppRouteKind.workspaceRetry);
      expect(decision.location, '/workspace-retry');
    });

    test('workspace creation stays outside onboarding and main routes', () {
      final decision = resolveAppRoute(
        bootstrap: const AppBootstrapState.ready(),
        session: _authenticated(
          onboardingRequired: true,
          workspaceStatus: SessionWorkspaceStatus.creating,
        ),
      );

      expect(decision.kind, AppRouteKind.workspaceRetry);
      expect(decision.location, '/workspace-retry');
      expect(decision.reason, 'workspace_creating');
    });

    test('onboarding required enters the card flow before deferral', () {
      final session = _authenticated(
        onboardingRequired: true,
        firstLoginThisSession: true,
      );
      final decision = resolveAppRoute(
        bootstrap: const AppBootstrapState.ready(),
        session: session,
      );
      final reminderRedirect = redirectForAppRoute(
        currentLocation: '/onboarding',
        bootstrap: const AppBootstrapState.ready(),
        session: session,
      );

      expect(decision.kind, AppRouteKind.onboarding);
      expect(decision.location, '/onboarding');
      expect(reminderRedirect, isNull);
    });

    test('local defer cannot bypass required positioning', () {
      final session = _authenticated(
        onboardingRequired: true,
        firstLoginThisSession: true,
      );
      final decision = resolveAppRoute(
        bootstrap: const AppBootstrapState.ready(),
        session: session,
        onboardingDeferred: true,
      );
      expect(decision.kind, AppRouteKind.onboarding);
      expect(decision.location, '/onboarding');
    });

    test(
      'accepted positioning Run admits V3 while report finalization runs',
      () {
        final session = _authenticated(onboardingRequired: true);
        final decision = resolveAppRoute(
          bootstrap: const AppBootstrapState.ready(),
          session: session,
          onboardingRunAccepted: true,
        );
        final progressRedirect = redirectForAppRoute(
          currentLocation: '/v3/positioning/progress',
          bootstrap: const AppBootstrapState.ready(),
          session: session,
          onboardingRunAccepted: true,
        );
        final onboardingRedirect = redirectForAppRoute(
          currentLocation: '/onboarding',
          bootstrap: const AppBootstrapState.ready(),
          session: session,
          onboardingRunAccepted: true,
        );
        final notificationsRedirect = redirectForAppRoute(
          currentLocation: AppRoutePaths.notifications,
          bootstrap: const AppBootstrapState.ready(),
          session: session,
          onboardingRunAccepted: true,
        );

        expect(decision.kind, AppRouteKind.v3);
        expect(decision.location, '/v3');
        expect(progressRedirect, isNull);
        expect(onboardingRedirect, isNull);
        expect(notificationsRedirect, isNull);
      },
    );

    test('completed positioning redirects stale accepted routes to V3', () {
      final session = _authenticated(
        onboardingRequired: true,
        basicPositioningCompleted: true,
      );

      expect(
        redirectForAppRoute(
          currentLocation: '/onboarding',
          bootstrap: const AppBootstrapState.ready(),
          session: session,
          onboardingRunAccepted: true,
        ),
        '/v3',
      );
      expect(
        redirectForAppRoute(
          currentLocation: '/v3/positioning/progress',
          bootstrap: const AppBootstrapState.ready(),
          session: session,
          onboardingRunAccepted: true,
        ),
        isNull,
      );
    });

    test(
      'startup journey blocks ordinary routes and admits only voice enrollment',
      () {
        final guideRedirect = redirectForAppRoute(
          currentLocation: AppRoutePaths.firstLaunchDeviceSetup,
          bootstrap: const AppBootstrapState.ready(),
          session: _authenticated(
            onboardingRequired: true,
            firstLoginThisSession: true,
          ),
          startupJourneyBlocking: true,
          onboardingRunAccepted: true,
        );
        final homeRedirect = redirectForAppRoute(
          currentLocation: AppRoutePaths.home,
          bootstrap: const AppBootstrapState.ready(),
          session: _authenticated(firstLoginThisSession: true),
          startupJourneyBlocking: true,
        );
        final voiceprintRedirect = redirectForAppRoute(
          currentLocation: '/v3/profile/voiceprint/enroll',
          bootstrap: const AppBootstrapState.ready(),
          session: _authenticated(firstLoginThisSession: true),
          startupJourneyBlocking: true,
          startupJourneyVoiceprintAllowed: true,
        );

        expect(guideRedirect, isNull);
        expect(homeRedirect, AppRoutePaths.firstLaunchDeviceSetup);
        expect(voiceprintRedirect, isNull);
      },
    );

    test('startup journey preserves the exact public help allowlist', () {
      final session = _authenticated(firstLoginThisSession: true);
      for (final location in const <String>[
        '/help',
        '/help/article/software-getting-started',
        '/legal/user-agreement',
        '/legal/privacy-policy',
      ]) {
        expect(
          redirectForAppRoute(
            currentLocation: location,
            bootstrap: const AppBootstrapState.ready(),
            session: session,
            startupJourneyBlocking: true,
          ),
          isNull,
          reason: location,
        );
      }
      for (final location in const <String>['/helpful', '/legal/other']) {
        expect(
          redirectForAppRoute(
            currentLocation: location,
            bootstrap: const AppBootstrapState.ready(),
            session: session,
            startupJourneyBlocking: true,
          ),
          AppRoutePaths.firstLaunchDeviceSetup,
          reason: location,
        );
      }
    });

    test(
      'explicit pending-message intent reopens a deferred positioning draft',
      () {
        final deferredSession = _authenticated(
          onboardingRequired: true,
          firstLoginThisSession: true,
        );
        final resumed = redirectForAppRoute(
          currentLocation: '/onboarding',
          bootstrap: const AppBootstrapState.ready(),
          session: deferredSession,
          onboardingDeferred: true,
          onboardingResumeRequested: true,
        );
        final ordinaryOpen = redirectForAppRoute(
          currentLocation: '/onboarding',
          bootstrap: const AppBootstrapState.ready(),
          session: deferredSession,
          onboardingDeferred: true,
        );
        final completed = redirectForAppRoute(
          currentLocation: '/onboarding',
          bootstrap: const AppBootstrapState.ready(),
          session: _authenticated(),
          onboardingDeferred: true,
          onboardingResumeRequested: true,
        );

        expect(resumed, isNull);
        expect(ordinaryOpen, isNull);
        expect(completed, '/v3');
      },
    );

    test('workspace guard keeps priority over deferred onboarding', () {
      final decision = resolveAppRoute(
        bootstrap: const AppBootstrapState.ready(),
        session: _authenticated(
          onboardingRequired: true,
          workspaceStatus: SessionWorkspaceStatus.syncFailed,
        ),
        onboardingDeferred: true,
      );

      expect(decision.kind, AppRouteKind.workspaceRetry);
    });

    test('ready authenticated session routes to V3 shell', () {
      final decision = resolveAppRoute(
        bootstrap: const AppBootstrapState.ready(),
        session: _authenticated(),
      );

      expect(decision.kind, AppRouteKind.v3);
      expect(decision.location, '/v3');
    });

    test('existing account never auto-enters first-login onboarding', () {
      final session = _authenticated(onboardingRequired: true);

      final decision = resolveAppRoute(
        bootstrap: const AppBootstrapState.ready(),
        session: session,
      );
      final staleOnboarding = redirectForAppRoute(
        currentLocation: '/onboarding',
        bootstrap: const AppBootstrapState.ready(),
        session: session,
        onboardingDeferred: true,
        onboardingResumeRequested: true,
      );
      final restoredJourney = redirectForAppRoute(
        currentLocation: AppRoutePaths.home,
        bootstrap: const AppBootstrapState.ready(),
        session: session,
        startupJourneyBlocking: true,
      );

      expect(decision.kind, AppRouteKind.v3);
      expect(staleOnboarding, AppRoutePaths.home);
      expect(restoredJourney, AppRoutePaths.firstLaunchDeviceSetup);
    });

    test('incomplete positioning is not evidence of a new account', () {
      for (final firstLogin in [false, true]) {
        final session =
            _authenticated(
              onboardingRequired: true,
              basicPositioningCompleted: false,
              firstLoginThisSession: firstLogin,
            ).copyWith(
              onboardingDecisionIsAuthoritative: true,
              positioningStatus: SessionPositioningStatus.inProgress,
            );
        expect(session.requiresInitialPositioning, isTrue);
        expect(
          resolveAppRoute(
            bootstrap: const AppBootstrapState.ready(),
            session: session,
            onboardingDeferred: true,
          ).kind,
          firstLogin ? AppRouteKind.onboarding : AppRouteKind.v3,
        );
        for (final path in const [
          '/v3',
          '/v3/notifications',
          '/v3/profile/digital-twin',
        ]) {
          expect(
            redirectForAppRoute(
              currentLocation: path,
              bootstrap: const AppBootstrapState.ready(),
              session: session,
              onboardingDeferred: true,
            ),
            firstLogin ? '/onboarding' : isNull,
            reason: 'firstLogin=$firstLogin path=$path',
          );
        }
      }
    });

    test('existing account can still resume an accepted positioning run', () {
      final session = _authenticated(onboardingRequired: true);

      expect(
        redirectForAppRoute(
          currentLocation: '/v3/positioning/progress',
          bootstrap: const AppBootstrapState.ready(),
          session: session,
          onboardingRunAccepted: true,
        ),
        isNull,
      );
    });

    test('completed session leaves a stale onboarding location', () {
      final redirect = redirectForAppRoute(
        currentLocation: '/onboarding',
        bootstrap: const AppBootstrapState.ready(),
        session: _authenticated(),
      );

      expect(redirect, '/v3');
    });

    test('authenticated V3 descendants stay inside V3 route tree', () {
      final redirect = redirectForAppRoute(
        currentLocation: '/v3/feed',
        bootstrap: const AppBootstrapState.ready(),
        session: _authenticated(),
      );

      expect(redirect, isNull);
    });

    test(
      'anonymous and expired sessions can open exact public help routes',
      () {
        final anonymous = redirectForAppRoute(
          currentLocation: '/help',
          bootstrap: const AppBootstrapState.ready(),
          session: SessionState.anonymous(),
        );
        final expired = redirectForAppRoute(
          currentLocation: '/help/article/software-getting-started',
          bootstrap: const AppBootstrapState.ready(),
          session: SessionState.anonymous().copyWith(
            authState: SessionAuthState.expired,
            lastAuthErrorCode: 'AUTH_SESSION_EXPIRED',
          ),
        );

        expect(anonymous, isNull);
        expect(expired, isNull);
      },
    );

    test('anonymous sessions can open only the exact public legal routes', () {
      for (final location in const <String>[
        '/legal/user-agreement',
        '/legal/privacy-policy',
      ]) {
        expect(
          redirectForAppRoute(
            currentLocation: location,
            bootstrap: const AppBootstrapState.ready(),
            session: SessionState.anonymous(),
          ),
          isNull,
        );
      }
      for (final location in const <String>[
        '/legal',
        '/legal/other',
        '/legalese',
      ]) {
        expect(
          redirectForAppRoute(
            currentLocation: location,
            bootstrap: const AppBootstrapState.ready(),
            session: SessionState.anonymous(),
          ),
          '/auth',
        );
      }
    });

    test('public help allowlist rejects lookalike prefixes', () {
      final redirect = redirectForAppRoute(
        currentLocation: '/helpful',
        bootstrap: const AppBootstrapState.ready(),
        session: SessionState.anonymous(),
      );

      expect(redirect, '/auth');
    });

    test('bootstrap state keeps priority over public help', () {
      final restoring = redirectForAppRoute(
        currentLocation: '/help',
        bootstrap: const AppBootstrapState.restoring(),
        session: SessionState.anonymous(),
      );
      final failed = redirectForAppRoute(
        currentLocation: '/help/customer-service',
        bootstrap: const AppBootstrapState.failed('RESTORE_FAILED'),
        session: SessionState.anonymous(),
      );

      expect(restoring, '/splash');
      expect(failed, '/restore-failed');
    });
  });
}

SessionState _authenticated({
  bool onboardingRequired = false,
  bool firstLoginThisSession = false,
  bool? basicPositioningCompleted,
  SessionWorkspaceStatus workspaceStatus = SessionWorkspaceStatus.ready,
}) {
  return SessionState(
    authState: SessionAuthState.authenticated,
    firstLoginThisSession: firstLoginThisSession,
    onboardingRequired: onboardingRequired,
    needsWorkspaceRetry: workspaceStatus == SessionWorkspaceStatus.syncFailed,
    runningTaskCount: 0,
    recoveryHints: const SessionRecoveryHints(),
    user: const SessionUser(userId: 'user-1', maskedPhoneNumber: '138****8000'),
    workspaceStatus: workspaceStatus,
    workspace: SessionWorkspace(status: workspaceStatus),
    basicPositioningCompleted: basicPositioningCompleted,
  );
}
