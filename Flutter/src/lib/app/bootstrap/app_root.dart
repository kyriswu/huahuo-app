import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../di/billing_providers.dart';
import '../di/onboarding_providers.dart';
import '../../core/auth/session_store.dart';
import '../../features/notifications/application/push_navigation_controller.dart';
import '../../features/notifications/application/push_runtime_controller.dart';
import '../../features/notifications/domain/push_message.dart';
import '../../features/onboarding/application/content_line_onboarding_controller.dart';
import '../../features/onboarding/application/first_launch_device_setup_controller.dart';
import '../../features/onboarding/application/initial_positioning_task_coordinator.dart';
import '../../features/settings/application/app_appearance_controller.dart';
import '../../features/ui_v3/application/knowledge_library_controller.dart';
import '../../features/ui_v3/application/knowledge_document_export_service.dart';
import '../../shared/ui_v3/v3_components.dart';
import '../../shared/ui_v3/v3_glass_foundations.dart';
import '../../shared/navigation/foreground_ingress_coordinator.dart';
import '../../shared/navigation/safe_navigation.dart';
import '../lifecycle/app_activity_coordinator.dart';
import '../navigation/app_router.dart';
import '../navigation/app_route_paths.dart';
import '../navigation/pending_navigation_controller.dart';
import '../navigation/route_guards.dart';
import '../runtime/runtime_provider_module.dart';
import '../performance/performance_policy.dart';
import '../product/mobile_feature_registry.dart';
import 'app_providers.dart';
import 'app_visual_root.dart';
import 'foreground_resume_coordinator.dart';

class AppRoot extends ConsumerStatefulWidget {
  const AppRoot({super.key});

  @override
  ConsumerState<AppRoot> createState() => _AppRootState();
}

class _AppRootState extends ConsumerState<AppRoot> {
  StreamSubscription<void>? _incomingSubscription;
  _IncomingNavigationMode? _pendingIncomingNavigation;
  bool _handlingIncomingMaterial = false;
  Completer<void>? _incomingMaterialHandlingSettled;
  var _incomingIngressRetryScheduled = false;
  var _incomingIngressRetryQueued = false;
  String? _scheduledPushCommandId;
  String? _rejectedPushCommandId;
  var _pushIngressRetryScheduled = false;
  String? _scheduledPendingLocation;
  late final AppActivityCoordinator _activityCoordinator;
  late final ForegroundResumeCoordinator _foregroundResumeCoordinator;
  late final AppPerformanceRuntime _performanceRuntime;
  late final GoRouter _activityRouter;
  var _routeActivitySyncScheduled = false;
  var _handledMemoryPressureRevision = 0;
  var _firstFrameRendered = false;
  AppLifecycleState _lifecycleState = AppLifecycleState.detached;
  final _scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();
  final _foregroundIngressCoordinator = ForegroundIngressCoordinator();

  @override
  void initState() {
    super.initState();
    ref.read(mobileFeatureRegistryProvider);
    _activityCoordinator = ref.read(appActivityCoordinatorProvider)
      ..addListener(_handleActivityChanged);
    _handledMemoryPressureRevision =
        _activityCoordinator.state.memoryPressureRevision;
    _foregroundResumeCoordinator = ForegroundResumeCoordinator(
      activity: _activityCoordinator,
      orchestrator: ref.read(taskOrchestratorProvider),
      readSession: _readForegroundResumeSession,
      activateRecordingCard: () {
        ref.read(recordingCardAutoSyncCoordinatorProvider);
      },
      resumeRecordingCard: ({required refreshDirectory}) async {
        final controller = ref.read(recordingCardControllerProvider);
        final autoSync = ref.read(recordingCardAutoSyncCoordinatorProvider);
        final successfulRevisionBefore =
            controller.successfulFileRefreshRevision;
        final hadObjectiveWait = autoSync.hasObjectivePrerequisiteWait;
        await controller.reconcileWifiBatch();
        await controller.reconcileConnectionState(
          refreshDirectory: refreshDirectory,
        );
        autoSync.resume(
          requestDeviceSync:
              hadObjectiveWait ||
              (!refreshDirectory &&
                  controller.successfulFileRefreshRevision ==
                      successfulRevisionBefore),
        );
      },
      synchronizeWorkspace: () => ref
          .read(knowledgeLibraryControllerProvider)
          .synchronizeWorkspaceContent(),
      recoverPendingOrder: () =>
          ref.read(billingControllerProvider).recoverPendingOrder(),
      resolvePositioning: _resolveInitialPositioningLifecycle,
      awaitDeferredFrame: () => WidgetsBinding.instance.endOfFrame,
    );
    _performanceRuntime = ref.read(appPerformanceRuntimeProvider);
    _activityRouter = ref.read(appRouterProvider);
    _activityRouter.routeInformationProvider.addListener(
      _scheduleRouteActivitySync,
    );
    _scheduleRouteActivitySync();
    _syncLifecycleProjection();
    _installRuntimeListeners();
    _applyMediaQuality(ref.read(performancePolicyProvider));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _firstFrameRendered = true;
      _performanceRuntime.markFirstFrame();
      _syncRouteActivity();
      ref.read(billingControllerProvider);
      _foregroundResumeCoordinator.start();
      _schedulePushNavigation(
        ref.read(pushNavigationControllerProvider).pendingCommand,
      );
      _schedulePendingNavigation();
    });
    _incomingSubscription = ref
        .read(incomingMaterialPortProvider)
        .pendingMaterials
        .listen((_) => unawaited(_handleIncomingMaterial()), onError: (_) {});
  }

  @override
  void dispose() {
    _activityRouter.routeInformationProvider.removeListener(
      _scheduleRouteActivitySync,
    );
    _activityCoordinator.removeListener(_handleActivityChanged);
    _foregroundResumeCoordinator.dispose();
    unawaited(_incomingSubscription?.cancel());
    super.dispose();
  }

  void _syncRouteActivity() {
    final path = _activityRouter.routeInformationProvider.value.uri.path;
    _activityCoordinator.updateRoute(path);
    _activityCoordinator.updateActiveTab(_tabForRoute(path));
    if (_firstFrameRendered && path != AppRoutePaths.splash) {
      _performanceRuntime.markFirstInteractive();
    }
  }

  void _scheduleRouteActivitySync() {
    if (_routeActivitySyncScheduled || !mounted) return;
    _routeActivitySyncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _routeActivitySyncScheduled = false;
      if (!mounted) return;
      _syncRouteActivity();
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  void _installRuntimeListeners() {
    ref.listenManual<InitialPositioningTaskCoordinator>(
      initialPositioningTaskCoordinatorProvider.notifier,
      (_, next) {
        _foregroundResumeCoordinator.positioningChanged();
      },
    );
    ref.listenManual<PerformancePolicy>(performancePolicyProvider, (_, next) {
      _applyMediaQuality(next);
    });
    ref.listenManual<PushRuntimeState>(
      pushRuntimeControllerProvider.select((controller) => controller.state),
      (previous, next) {
        final message = next.foregroundMessage;
        if (message == null || previous?.bannerId == next.bannerId) return;
        if (_isCurrentChatThread(message)) return;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final bannerContext = _scaffoldMessengerKey.currentContext;
          if (!mounted || bannerContext == null) return;
          showV3Snack(
            bannerContext,
            '${message.title}\n${message.body}',
            actionLabel: '查看',
            duration: V3FeedbackTimingTokens.importantSnack,
            onAction: () => ref
                .read(pushRuntimeControllerProvider)
                .openForeground(next.bannerId),
          );
        });
        WidgetsBinding.instance.scheduleFrame();
      },
    );
    ref.listenManual<PushNavigationCommand?>(
      pushNavigationControllerProvider.select(
        (controller) => controller.pendingCommand,
      ),
      (_, command) => _schedulePushNavigation(command),
    );
    ref.listenManual(
      appBootstrapControllerProvider.select((controller) => controller.state),
      (_, __) => _scheduleGuardedIngress(),
    );
    ref.listenManual<SessionAuthState>(
      sessionStoreProvider.select((store) => store.state.authState),
      (previous, next) {
        _foregroundResumeCoordinator.sessionChanged();
        if (next == SessionAuthState.authenticated) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            unawaited(_resumeDeferredIngressAfterAuthentication());
          });
          WidgetsBinding.instance.scheduleFrame();
        }
      },
    );
    ref.listenManual<SessionState>(
      sessionStoreProvider.select((store) => store.state),
      (_, __) => _scheduleGuardedIngress(),
    );
    ref.listenManual<PendingNavigation?>(
      pendingNavigationControllerProvider.select(
        (controller) => controller.pending,
      ),
      (_, __) => _schedulePendingNavigation(),
    );
    ref.listenManual<OnboardingContinuationController>(
      onboardingContinuationControllerProvider,
      (_, __) => _scheduleGuardedIngress(),
    );
    ref.listenManual<FirstLaunchDeviceSetupController>(
      firstLaunchDeviceSetupControllerProvider,
      (_, __) => _scheduleGuardedIngress(),
    );
  }

  void _scheduleGuardedIngress() {
    _schedulePushNavigation(
      ref.read(pushNavigationControllerProvider).pendingCommand,
    );
    _schedulePendingNavigation();
  }

  bool get _startupJourneyBlocking => ref
      .read(firstLaunchDeviceSetupControllerProvider)
      .requiresBlockingJourney;

  void _handleActivityChanged() {
    final memoryRevision = _activityCoordinator.state.memoryPressureRevision;
    if (memoryRevision != _handledMemoryPressureRevision) {
      _handledMemoryPressureRevision = memoryRevision;
      _releaseMediaMemory();
    }
    _syncLifecycleProjection();
  }

  void _applyMediaQuality(PerformancePolicy policy) {
    final decodedImages = PaintingBinding.instance.imageCache;
    switch (policy.visualQuality) {
      case AppVisualQuality.high:
        decodedImages.maximumSize = 96;
        decodedImages.maximumSizeBytes = 48 * 1024 * 1024;
      case AppVisualQuality.balanced:
        decodedImages.maximumSize = 72;
        decodedImages.maximumSizeBytes = 32 * 1024 * 1024;
      case AppVisualQuality.constrained:
        decodedImages.maximumSize = 48;
        decodedImages.maximumSizeBytes = 20 * 1024 * 1024;
    }
    final session = ref.read(sessionStoreProvider).state;
    if (session.authState != SessionAuthState.authenticated ||
        session.workspaceStatus != SessionWorkspaceStatus.ready ||
        session.user == null ||
        session.workspace?.workspaceId?.trim().isEmpty != false) {
      return;
    }
    ref.read(resourceImageCacheProvider).setMemoryLimitBytes(
      switch (policy.visualQuality) {
        AppVisualQuality.high => 32 * 1024 * 1024,
        AppVisualQuality.balanced => 20 * 1024 * 1024,
        AppVisualQuality.constrained => 12 * 1024 * 1024,
      },
    );
  }

  void _releaseMediaMemory() {
    final decodedImages = PaintingBinding.instance.imageCache;
    decodedImages
      ..clear()
      ..clearLiveImages();
    final session = ref.read(sessionStoreProvider).state;
    if (session.authState == SessionAuthState.authenticated &&
        session.workspaceStatus == SessionWorkspaceStatus.ready &&
        session.user != null &&
        session.workspace?.workspaceId?.trim().isNotEmpty == true) {
      ref.read(resourceImageCacheProvider).clearMemory();
    }
    final exportService = ref.read(knowledgeDocumentExportServiceProvider);
    if (exportService case final FileKnowledgeDocumentExportService service) {
      service.releaseMemory();
    }
  }

  void _syncLifecycleProjection() {
    _lifecycleState = switch (_activityCoordinator.state.visibility) {
      AppVisibility.foreground => AppLifecycleState.resumed,
      AppVisibility.inactive => AppLifecycleState.inactive,
      AppVisibility.background => AppLifecycleState.paused,
    };
  }

  ForegroundResumeSession _readForegroundResumeSession() {
    final session = ref.read(sessionStoreProvider).state;
    final authenticated =
        session.authState == SessionAuthState.authenticated &&
        session.user != null;
    return ForegroundResumeSession(
      authenticated: authenticated,
      workspaceReady:
          authenticated &&
          session.workspaceStatus == SessionWorkspaceStatus.ready,
    );
  }

  InitialPositioningLifecycle _resolveInitialPositioningLifecycle() {
    final coordinator = ref.read(
      initialPositioningTaskCoordinatorProvider.notifier,
    );
    return InitialPositioningLifecycle(
      identity: coordinator,
      start: coordinator.start,
      resume: coordinator.resume,
      pause: coordinator.pause,
    );
  }

  Future<void> _handleIncomingMaterial() async {
    if (!mounted || _handlingIncomingMaterial) return;
    final mode = _pendingIncomingNavigation ?? _incomingNavigationMode;
    final session = ref.read(sessionStoreProvider).state;
    if (session.authState != SessionAuthState.authenticated ||
        session.user == null) {
      _pendingIncomingNavigation = mode;
      ref
          .read(pendingNavigationControllerProvider)
          .stage(
            location: AppRoutePaths.documentImport,
            reason: PendingNavigationReason.externalShare,
          );
      return;
    }
    _handlingIncomingMaterial = true;
    final handlingSettled = Completer<void>();
    _incomingMaterialHandlingSettled = handlingSettled;
    var ingressResult = ForegroundIngressRequestResult.cancel;
    try {
      ingressResult = await _navigateIncomingMaterial(mode);
      if (!mounted) return;
      if (ingressResult != ForegroundIngressRequestResult.allow) {
        _pendingIncomingNavigation = mode;
      } else {
        _consumeDeferredIncomingMaterialNavigation();
        _pendingIncomingNavigation = null;
      }
    } finally {
      _handlingIncomingMaterial = false;
      if (identical(_incomingMaterialHandlingSettled, handlingSettled)) {
        _incomingMaterialHandlingSettled = null;
      }
      if (!handlingSettled.isCompleted) handlingSettled.complete();
    }
    if (mounted && ingressResult == ForegroundIngressRequestResult.busy) {
      _rescheduleIncomingMaterialAfterIngressSettles();
    }
  }

  void _consumeDeferredIncomingMaterialNavigation() {
    final controller = ref.read(pendingNavigationControllerProvider);
    final pending = controller.pending;
    if (pending?.location != AppRoutePaths.documentImport ||
        pending?.reason != PendingNavigationReason.externalShare) {
      return;
    }
    controller.consume();
  }

  @override
  Widget build(BuildContext context) {
    ref.read(runtimeActivityMetricsProvider).recordRebuild('app_root');
    ref.watch(recordingCardAutoSyncCoordinatorProvider);
    ref.watch(recordingCardQuickWifiCoordinatorProvider);
    final router = ref.watch(appRouterProvider);
    final appearance = ref.watch(appAppearanceControllerProvider);
    return AppVisualRoot(
      router: router,
      appearancePreset: appearance.preset,
      themeMode: appearance.themeMode,
      textSizeFactor: appearance.textSizePreset.factor,
      glassOpacityPercent: appearance.glassOpacityPercent,
      scaffoldMessengerKey: _scaffoldMessengerKey,
      foregroundIngressCoordinator: _foregroundIngressCoordinator,
      activityMetrics: _performanceRuntime.activity,
    );
  }

  void _schedulePushNavigation(PushNavigationCommand? command) {
    if (command == null) {
      _rejectedPushCommandId = null;
      return;
    }
    if (_rejectedPushCommandId != null &&
        _rejectedPushCommandId != command.id) {
      _rejectedPushCommandId = null;
    }
    if (_scheduledPushCommandId == command.id ||
        _rejectedPushCommandId == command.id) {
      return;
    }
    final decision = resolveAppRoute(
      bootstrap: ref.read(appBootstrapControllerProvider).state,
      session: ref.read(sessionStoreProvider).state,
      onboardingDeferred: _isOnboardingDeferred(),
      onboardingRunAccepted: _hasAcceptedOnboardingRun(),
      startupJourneyPositioningHandled: ref
          .read(firstLaunchDeviceSetupControllerProvider)
          .snapshot
          .positioning
          .hasExited,
    );
    if (decision.kind != AppRouteKind.v3 || _startupJourneyBlocking) return;
    _scheduledPushCommandId = command.id;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_navigatePushCommand(command));
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  Future<void> _navigatePushCommand(PushNavigationCommand command) async {
    if (!mounted) return;
    final action = ingressNavigationAction(
      coldStart: command.receiveType == PushReceiveType.coldStart,
    );
    final ingressResult = await requestIngressNavigationResult(
      action: action,
      foregroundIngressCoordinator: _foregroundIngressCoordinator,
    );
    if (!mounted) return;
    if (ingressResult == ForegroundIngressRequestResult.cancel) {
      _rejectedPushCommandId = command.id;
      ref.read(pushNavigationControllerProvider).reject(command.id);
      _clearScheduledPushCommand(command);
      return;
    }
    if (ingressResult == ForegroundIngressRequestResult.busy) {
      _clearScheduledPushCommand(command);
      _rescheduleLatestPushAfterIngressSettles();
      return;
    }

    final pending = ref.read(pushNavigationControllerProvider).pendingCommand;
    final currentDecision = resolveAppRoute(
      bootstrap: ref.read(appBootstrapControllerProvider).state,
      session: ref.read(sessionStoreProvider).state,
      onboardingDeferred: _isOnboardingDeferred(),
      onboardingRunAccepted: _hasAcceptedOnboardingRun(),
      startupJourneyPositioningHandled: ref
          .read(firstLaunchDeviceSetupControllerProvider)
          .snapshot
          .positioning
          .hasExited,
    );
    if (pending?.id != command.id ||
        (currentDecision.kind != AppRouteKind.v3 || _startupJourneyBlocking)) {
      _clearScheduledPushCommand(command);
      return;
    }
    final navigated = await navigateForIngress(
      ref.read(appRouterProvider),
      location: command.location,
      action: action,
    );
    if (navigated) {
      ref.read(pushNavigationControllerProvider).consume(command.id);
      unawaited(_reconcileOpenedPushNotification(command));
    }
    _clearScheduledPushCommand(command);
  }

  void _clearScheduledPushCommand(PushNavigationCommand command) {
    if (_scheduledPushCommandId == command.id) {
      _scheduledPushCommandId = null;
    }
  }

  Future<void> _reconcileOpenedPushNotification(
    PushNavigationCommand command,
  ) async {
    if (command.notificationId == null || command.eventId == null) return;
    final controller = ref.read(notificationControllerProvider);
    await controller.load(forceRemote: true);
    for (final notification in controller.state.items) {
      if (command.matchesDelivery(notification)) {
        await controller.markRead(notification);
        return;
      }
    }
  }

  void _rescheduleLatestPushAfterIngressSettles() {
    if (_pushIngressRetryScheduled) return;
    _pushIngressRetryScheduled = true;
    unawaited(_resumeLatestPushAfterIngressSettles());
  }

  Future<void> _resumeLatestPushAfterIngressSettles() async {
    try {
      await _foregroundIngressCoordinator.waitUntilIdle();
      if (!mounted) return;
      await _waitForForegroundIngressRouteCommit();
      if (!mounted) return;
      _pushIngressRetryScheduled = false;
      _schedulePushNavigation(
        ref.read(pushNavigationControllerProvider).pendingCommand,
      );
    } finally {
      _pushIngressRetryScheduled = false;
    }
  }

  void _rescheduleIncomingMaterialAfterIngressSettles() {
    _incomingIngressRetryQueued = true;
    if (_incomingIngressRetryScheduled) return;
    _incomingIngressRetryScheduled = true;
    unawaited(_resumeIncomingMaterialAfterIngressSettles());
  }

  Future<void> _resumeIncomingMaterialAfterIngressSettles() async {
    try {
      while (mounted && _incomingIngressRetryQueued) {
        _incomingIngressRetryQueued = false;
        await _foregroundIngressCoordinator.waitUntilIdle();
        if (!mounted) return;
        await _waitForForegroundIngressRouteCommit();
        if (!mounted) return;
        final handlingSettled = _incomingMaterialHandlingSettled;
        if (handlingSettled != null) {
          await handlingSettled.future;
          if (!mounted || _pendingIncomingNavigation == null) return;
          continue;
        }
        if (_pendingIncomingNavigation == null) return;
        await _handleIncomingMaterial();
      }
    } finally {
      _incomingIngressRetryScheduled = false;
      if (mounted && _incomingIngressRetryQueued) {
        _rescheduleIncomingMaterialAfterIngressSettles();
      }
    }
  }

  Future<void> _waitForForegroundIngressRouteCommit() {
    // Manual provider listeners do not dirty the widget tree. Request the
    // commit frame explicitly so a busy ingress retry cannot wait forever.
    WidgetsBinding.instance.scheduleFrame();
    return WidgetsBinding.instance.endOfFrame;
  }

  bool _isCurrentChatThread(PushMessage message) {
    final route = ref
        .read(appRouterProvider)
        .routeInformationProvider
        .value
        .uri;
    if (route.path != '/v3/feed/chat') return false;
    return isPushForChatThread(
      message,
      ref.read(foregroundChatThreadIdProvider),
    );
  }

  _IncomingNavigationMode get _incomingNavigationMode {
    return _firstFrameRendered && _lifecycleState == AppLifecycleState.resumed
        ? _IncomingNavigationMode.foreground
        : _IncomingNavigationMode.coldStart;
  }

  Future<ForegroundIngressRequestResult> _navigateIncomingMaterial(
    _IncomingNavigationMode mode,
  ) async {
    final router = ref.read(appRouterProvider);
    if (router.routeInformationProvider.value.uri.path ==
        AppRoutePaths.documentImport) {
      return ForegroundIngressRequestResult.allow;
    }
    final action = ingressNavigationAction(
      coldStart: mode == _IncomingNavigationMode.coldStart,
    );
    final ingressResult = await requestIngressNavigationResult(
      action: action,
      foregroundIngressCoordinator: _foregroundIngressCoordinator,
    );
    if (ingressResult != ForegroundIngressRequestResult.allow) {
      return ingressResult;
    }
    final navigated = await navigateForIngress(
      router,
      location: AppRoutePaths.documentImport,
      action: action,
    );
    return navigated
        ? ForegroundIngressRequestResult.allow
        : ForegroundIngressRequestResult.cancel;
  }

  Future<void> _resumeDeferredIngressAfterAuthentication() async {
    if (_pendingIncomingNavigation != null) {
      await _handleIncomingMaterial();
    }
    if (mounted) _schedulePendingNavigation();
  }

  void _schedulePendingNavigation() {
    final pending = ref.read(pendingNavigationControllerProvider).pending;
    if (pending == null || _scheduledPendingLocation == pending.location) {
      return;
    }
    if (pending.reason == PendingNavigationReason.externalShare &&
        (_pendingIncomingNavigation != null || _handlingIncomingMaterial)) {
      return;
    }
    final decision = resolveAppRoute(
      bootstrap: ref.read(appBootstrapControllerProvider).state,
      session: ref.read(sessionStoreProvider).state,
      onboardingDeferred: _isOnboardingDeferred(),
      onboardingRunAccepted: _hasAcceptedOnboardingRun(),
      startupJourneyPositioningHandled: ref
          .read(firstLaunchDeviceSetupControllerProvider)
          .snapshot
          .positioning
          .hasExited,
    );
    if (decision.kind != AppRouteKind.v3 || _startupJourneyBlocking) return;
    _scheduledPendingLocation = pending.location;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final controller = ref.read(pendingNavigationControllerProvider);
      final current = controller.pending;
      final currentDecision = resolveAppRoute(
        bootstrap: ref.read(appBootstrapControllerProvider).state,
        session: ref.read(sessionStoreProvider).state,
        onboardingDeferred: _isOnboardingDeferred(),
        onboardingRunAccepted: _hasAcceptedOnboardingRun(),
        startupJourneyPositioningHandled: ref
            .read(firstLaunchDeviceSetupControllerProvider)
            .snapshot
            .positioning
            .hasExited,
      );
      if (current?.location != pending.location ||
          (currentDecision.kind != AppRouteKind.v3 ||
              _startupJourneyBlocking)) {
        _scheduledPendingLocation = null;
        return;
      }
      final destination = controller.consume();
      if (destination != null) {
        ref.read(appRouterProvider).go(destination.location);
      }
      _scheduledPendingLocation = null;
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  bool _isOnboardingDeferred() {
    final session = ref.read(sessionStoreProvider).state;
    return ref
        .read(onboardingContinuationControllerProvider)
        .isDeferredFor(session.user?.userId);
  }

  bool _hasAcceptedOnboardingRun() {
    final session = ref.read(sessionStoreProvider).state;
    return ref
        .read(onboardingContinuationControllerProvider)
        .hasActiveAcceptedRunFor(session.user?.userId);
  }
}

enum _IncomingNavigationMode { coldStart, foreground }

String _tabForRoute(String route) {
  final segments = Uri(path: route).pathSegments;
  if (segments.isEmpty) return 'root';
  if (segments.first == 'v3' && segments.length > 1) return segments[1];
  return segments.first;
}
