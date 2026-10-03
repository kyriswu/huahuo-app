import 'dart:async';

import 'package:flutter/material.dart';

import 'foreground_ingress_coordinator.dart';
import 'safe_navigation.dart';

typedef UnsavedChangesConfirmation =
    FutureOr<bool> Function(BuildContext context);
typedef UnsavedChangesStateResolver = bool Function();

/// Owns route exit mechanics while the editor owns its cleanup and copy.
class UnsavedChangesGuard extends StatefulWidget {
  const UnsavedChangesGuard({
    required this.hasUnsavedChanges,
    required this.isLeaveBlocked,
    required this.fallbackRoute,
    required this.onConfirmLeave,
    required this.child,
    this.hasUnsavedChangesNow,
    this.isLeaveBlockedNow,
    this.onConfirmForegroundIngress,
    this.onLeaveBlocked,
    this.enableLeadingEdgeSwipeLeave = false,
    super.key,
  });

  final bool hasUnsavedChanges;
  final bool isLeaveBlocked;
  final String fallbackRoute;
  final UnsavedChangesConfirmation onConfirmLeave;
  final UnsavedChangesStateResolver? hasUnsavedChangesNow;
  final UnsavedChangesStateResolver? isLeaveBlockedNow;
  final UnsavedChangesConfirmation? onConfirmForegroundIngress;
  final VoidCallback? onLeaveBlocked;
  final bool enableLeadingEdgeSwipeLeave;
  final Widget child;

  static Future<void> requestLeave(BuildContext context) {
    final guard = context.findAncestorStateOfType<_UnsavedChangesGuardState>();
    return guard?.requestLeave() ?? Future<void>.value();
  }

  @override
  State<UnsavedChangesGuard> createState() => _UnsavedChangesGuardState();
}

class _UnsavedChangesGuardState extends State<UnsavedChangesGuard> {
  ForegroundIngressCoordinator? _ingressCoordinator;
  VoidCallback? _unregisterIngress;
  var _requestInProgress = false;
  var _leaving = false;
  var _allowPop = false;
  int? _leadingEdgePointer;
  Offset? _leadingEdgeStart;
  Offset? _leadingEdgeLatest;
  var _leadingEdgeDirection = 1.0;

  static const _leadingEdgeWidth = 24.0;
  static const _leadingEdgeCommitDistance = 72.0;

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
    if (_requestInProgress || _leaving) return;
    if (_isLeaveBlocked) {
      widget.onLeaveBlocked?.call();
      return;
    }
    if (_allowPop || !_hasUnsavedChanges) {
      await _leave();
      return;
    }

    _requestInProgress = true;
    try {
      final approved = await widget.onConfirmLeave(context);
      if (!mounted || !approved) return;
      await _leave();
    } finally {
      if (mounted) _requestInProgress = false;
    }
  }

  Future<ForegroundIngressDecision> _requestForegroundIngress() async {
    if (_requestInProgress || _leaving) {
      return ForegroundIngressDecision.cancel;
    }
    if (_isLeaveBlocked) {
      widget.onLeaveBlocked?.call();
      return ForegroundIngressDecision.cancel;
    }
    if (_allowPop || !_hasUnsavedChanges) {
      return ForegroundIngressDecision.allow;
    }

    final confirm = widget.onConfirmForegroundIngress;
    if (confirm == null) return ForegroundIngressDecision.cancel;
    _requestInProgress = true;
    try {
      final approved = await confirm(context);
      return approved
          ? ForegroundIngressDecision.allow
          : ForegroundIngressDecision.cancel;
    } finally {
      if (mounted) _requestInProgress = false;
    }
  }

  Future<void> _leave() async {
    if (!mounted || _allowPop) return;
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

  bool _isCurrentRoute() {
    if (!mounted) return false;
    final route = ModalRoute.of(context);
    if (route == null) return false;
    return foregroundIngressRouteObserver.isTopmostPageRoute(route) ??
        route.isCurrent;
  }

  bool get _hasUnsavedChanges => _resolveCurrentState(
    widget.hasUnsavedChangesNow,
    fallback: widget.hasUnsavedChanges,
  );

  bool get _isLeaveBlocked => _resolveCurrentState(
    widget.isLeaveBlockedNow,
    fallback: widget.isLeaveBlocked,
  );

  bool _resolveCurrentState(
    UnsavedChangesStateResolver? resolver, {
    required bool fallback,
  }) {
    try {
      return resolver?.call() ?? fallback;
    } on Object {
      // A failing page resolver must not silently discard user work.
      return true;
    }
  }

  void _handleLeadingEdgePointerDown(PointerDownEvent event) {
    if (!widget.enableLeadingEdgeSwipeLeave ||
        Theme.of(context).platform != TargetPlatform.iOS ||
        _leadingEdgePointer != null ||
        _requestInProgress ||
        _leaving ||
        (!_hasUnsavedChanges && !_isLeaveBlocked)) {
      return;
    }
    final width = MediaQuery.sizeOf(context).width;
    final isLeftToRight = Directionality.of(context) == TextDirection.ltr;
    final startsAtLeadingEdge = isLeftToRight
        ? event.position.dx <= _leadingEdgeWidth
        : event.position.dx >= width - _leadingEdgeWidth;
    if (!startsAtLeadingEdge) return;
    _leadingEdgePointer = event.pointer;
    _leadingEdgeStart = event.position;
    _leadingEdgeLatest = event.position;
    _leadingEdgeDirection = isLeftToRight ? 1 : -1;
  }

  void _handleLeadingEdgePointerMove(PointerMoveEvent event) {
    if (_leadingEdgePointer != event.pointer) return;
    _leadingEdgeLatest = event.position;
  }

  void _handleLeadingEdgePointerUp(PointerUpEvent event) {
    if (_leadingEdgePointer != event.pointer) return;
    final start = _leadingEdgeStart;
    final latest = _leadingEdgeLatest ?? event.position;
    _resetLeadingEdgePointer();
    if (start == null) return;
    final horizontal = (latest.dx - start.dx) * _leadingEdgeDirection;
    final vertical = (latest.dy - start.dy).abs();
    if (horizontal >= _leadingEdgeCommitDistance &&
        horizontal > vertical * 1.5) {
      unawaited(requestLeave());
    }
  }

  void _handleLeadingEdgePointerCancel(PointerCancelEvent event) {
    if (_leadingEdgePointer == event.pointer) _resetLeadingEdgePointer();
  }

  void _resetLeadingEdgePointer() {
    _leadingEdgePointer = null;
    _leadingEdgeStart = null;
    _leadingEdgeLatest = null;
  }

  @override
  Widget build(BuildContext context) {
    final guardedChild = PopScope<Object?>(
      canPop:
          _allowPop ||
          (widget.enableLeadingEdgeSwipeLeave &&
              !_isLeaveBlocked &&
              !_hasUnsavedChanges),
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || _allowPop) return;
        unawaited(requestLeave());
      },
      child: widget.child,
    );
    if (!widget.enableLeadingEdgeSwipeLeave) return guardedChild;
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _handleLeadingEdgePointerDown,
      onPointerMove: _handleLeadingEdgePointerMove,
      onPointerUp: _handleLeadingEdgePointerUp,
      onPointerCancel: _handleLeadingEdgePointerCancel,
      child: guardedChild,
    );
  }
}
