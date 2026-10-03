import 'dart:async';

import 'package:flutter/material.dart';

import '../ui_v3/v3_components.dart';
import 'foreground_ingress_coordinator.dart';
import 'safe_navigation.dart';

enum CaptureLeaveState { idle, capturing, processing }

typedef CaptureLeaveEndCallback = FutureOr<bool> Function();
typedef CaptureLeaveStateResolver = CaptureLeaveState Function();

/// Completion handlers may auto-navigate only while their capture page shows.
bool isCurrentCaptureRoute(BuildContext context) =>
    ModalRoute.of(context)?.isCurrent ?? false;

/// Owns the user-visible exit decision for a recording/capture route.
class CaptureLeaveGuard extends StatefulWidget {
  const CaptureLeaveGuard({
    required this.state,
    required this.fallbackRoute,
    required this.child,
    this.onEndAndLeave,
    this.stateResolver,
    super.key,
  });

  final CaptureLeaveState state;
  final String fallbackRoute;
  final CaptureLeaveEndCallback? onEndAndLeave;
  final CaptureLeaveStateResolver? stateResolver;
  final Widget child;

  /// Requests the same exit flow used for a platform/system back gesture.
  static Future<void> requestLeave(BuildContext context) {
    final guard = context.findAncestorStateOfType<_CaptureLeaveGuardState>();
    return guard?.requestLeave() ?? Future<void>.value();
  }

  @override
  State<CaptureLeaveGuard> createState() => _CaptureLeaveGuardState();
}

class _CaptureLeaveGuardState extends State<CaptureLeaveGuard> {
  ForegroundIngressCoordinator? _ingressCoordinator;
  VoidCallback? _unregisterIngress;
  bool _dialogOpen = false;
  bool _leaving = false;
  bool _allowPop = false;
  Completer<void>? _activeLeaveFlow;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final coordinator = ForegroundIngressScope.maybeOf(context);
    if (identical(coordinator, _ingressCoordinator)) return;

    _unregisterIngress?.call();
    _unregisterIngress = null;
    _ingressCoordinator = coordinator;
    if (coordinator == null) return;
    _unregisterIngress = coordinator.register(
      onRequest: _requestForegroundIngress,
      isCurrent: _isCurrentRoute,
    );
  }

  @override
  void dispose() {
    _unregisterIngress?.call();
    super.dispose();
  }

  Future<void> requestLeave() async {
    if (_dialogOpen || _leaving || _allowPop) return;
    final leaveFlow = Completer<void>();
    _activeLeaveFlow = leaveFlow;
    try {
      if (_captureState != CaptureLeaveState.capturing) {
        await _leave();
        return;
      }

      if (await _confirmEndCapture()) await _leave();
    } finally {
      if (identical(_activeLeaveFlow, leaveFlow)) {
        _activeLeaveFlow = null;
      }
      if (!leaveFlow.isCompleted) leaveFlow.complete();
    }
  }

  Future<ForegroundIngressDecision> _requestForegroundIngress() async {
    if (_dialogOpen || _leaving || _allowPop || _activeLeaveFlow != null) {
      await _waitForActiveLeaveFlow();
      return ForegroundIngressDecision.busy;
    }
    if (_captureState != CaptureLeaveState.capturing) {
      return ForegroundIngressDecision.allow;
    }
    return await _confirmEndCapture()
        ? ForegroundIngressDecision.allow
        : ForegroundIngressDecision.cancel;
  }

  Future<bool> _confirmEndCapture() async {
    if (_dialogOpen || _leaving) return false;
    _dialogOpen = true;
    try {
      final shouldEnd = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => V3GlassDialog(
          title: '正在录制',
          message: '离开当前页面将结束本次录制。',
          cancelLabel: '继续录制',
          primaryLabel: '结束并离开',
          onCancel: () => Navigator.of(dialogContext).pop(false),
          onPrimary: () => Navigator.of(dialogContext).pop(true),
        ),
      );
      if (!mounted || shouldEnd != true) return false;

      final endCapture = widget.onEndAndLeave;
      if (endCapture == null) return false;
      _leaving = true;
      try {
        return await endCapture();
      } finally {
        if (mounted) _leaving = false;
      }
    } finally {
      if (mounted) _dialogOpen = false;
    }
  }

  Future<void> _leave() async {
    if (!mounted || _allowPop || _leaving) return;
    _leaving = true;
    try {
      setState(() => _allowPop = true);
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;

      await returnToPreviousRoute(context, fallbackRoute: widget.fallbackRoute);
    } finally {
      if (mounted) _leaving = false;
    }
  }

  Future<void> _waitForActiveLeaveFlow() async {
    final leaveFlow = _activeLeaveFlow;
    if (leaveFlow != null) {
      await leaveFlow.future;
      return;
    }
    await WidgetsBinding.instance.endOfFrame;
  }

  bool _isCurrentRoute() {
    if (!mounted) return false;
    final route = ModalRoute.of(context);
    if (route == null) return false;
    return foregroundIngressRouteObserver.isTopmostPageRoute(route) ??
        route.isCurrent;
  }

  CaptureLeaveState get _captureState {
    try {
      return widget.stateResolver?.call() ?? widget.state;
    } on Object {
      // A failed resolver must not allow an active capture to be covered.
      return CaptureLeaveState.capturing;
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope<Object?>(
      canPop: _allowPop,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || _allowPop) return;
        unawaited(requestLeave());
      },
      child: widget.child,
    );
  }
}
