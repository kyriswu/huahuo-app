import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../shared/navigation/safe_navigation.dart';
import '../application/feed_aggregation_controller.dart';
import '../domain/ui_v3_models.dart';
import 'v3_feed_aggregation_surfaces.dart';

class V3FeedAggregationTaskPage extends ConsumerStatefulWidget {
  const V3FeedAggregationTaskPage({
    required this.taskId,
    this.startNew = false,
    super.key,
  });
  final String taskId;
  final bool startNew;
  static const newTaskRoute = '/v3/feed/aggregation/new';
  static String routeFor(String taskId) => Uri(
    path: '/v3/feed/aggregation',
    queryParameters: {'taskId': taskId},
  ).toString();
  @override
  ConsumerState<V3FeedAggregationTaskPage> createState() =>
      _V3FeedAggregationTaskPageState();
}

class _V3FeedAggregationTaskPageState
    extends ConsumerState<V3FeedAggregationTaskPage> {
  FeedAggregationController? _selectionOwner;
  final Object _selectionIdentity = Object();
  bool _selectionBusy = false;
  bool _newBlocked = false;

  @override
  void initState() {
    super.initState();
    if (widget.startNew) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && ModalRoute.of(context)?.isCurrent == true) {
          _prepareSelection();
        }
      });
    }
  }

  void _back() {
    _selectionOwner?.cancelSelection(owner: _selectionIdentity);
    unawaited(returnToPreviousRoute(context, fallbackRoute: '/v3/feed'));
  }

  bool _owns(FeedAggregationController controller) =>
      mounted &&
      identical(ref.read(feedAggregationControllerProvider), controller);

  @override
  void dispose() {
    _releaseSelectionAfterNavigation();
    super.dispose();
  }

  void _releaseSelectionAfterNavigation() {
    final owner = _selectionOwner;
    if (owner != null) {
      scheduleMicrotask(() => owner.cancelSelection(owner: _selectionIdentity));
    }
  }

  Future<void> _prepareSelection() async {
    final owner = ref.read(feedAggregationControllerProvider);
    if (_selectionBusy) return;
    if (owner.hasUnresolvedTask) {
      setState(() {
        _newBlocked = owner.taskNotices.any((notice) => notice.isCurrent);
        if (!_newBlocked) _selectionOwner = owner;
      });
      return;
    }
    setState(() {
      _selectionOwner = owner;
      _selectionBusy = true;
      _newBlocked = false;
    });
    try {
      final prepared = await owner.prepareSelection(owner: _selectionIdentity);
      if (!mounted ||
          !_owns(owner) ||
          ModalRoute.of(context)?.isCurrent != true) {
        owner.cancelSelection(owner: _selectionIdentity);
        return;
      }
      if (!prepared) return;
      final accepted = await showV3FeedAggregationSelection(
        context,
        owner,
        selectionOwner: _selectionIdentity,
      );
      if (!mounted ||
          !_owns(owner) ||
          ModalRoute.of(context)?.isCurrent != true) {
        owner.cancelSelection(owner: _selectionIdentity);
        return;
      }
      if (!accepted) {
        if (owner.status == FeedAggregationStatus.selecting) {
          owner.cancelSelection(owner: _selectionIdentity);
          _back();
        }
        return;
      }
      final submission = owner.confirm();
      final reference = owner.taskId;
      if (reference != null) {
        context.replace(V3FeedAggregationTaskPage.routeFor(reference));
      }
      await submission;
    } finally {
      if (mounted) setState(() => _selectionBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(feedAggregationControllerProvider);
    final notice = widget.startNew
        ? null
        : controller.noticeForReference(widget.taskId);
    final ownsSelection =
        widget.startNew &&
        (_selectionOwner == null || identical(_selectionOwner, controller));
    final matches = widget.startNew
        ? ownsSelection && !_newBlocked
        : notice != null;
    final current =
        !widget.startNew && controller.matchesTaskReference(widget.taskId);
    final note = notice?.note;
    final canResume = (current || ownsSelection) && controller.canResumeTask;
    final canSelectAgain =
        !controller.hasUnresolvedTask &&
        !_selectionBusy &&
        (widget.startNew ||
            notice?.phase == FeedAggregationPhase.failed ||
            notice?.phase == FeedAggregationPhase.succeeded);
    return PopScope<Object?>(
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) _releaseSelectionAfterNavigation();
      },
      child: Scaffold(
        body: SafeArea(
          child: !matches
              ? V3FeedAggregationProgressSurface(
                  sourceCount: 0,
                  showSkeleton: false,
                  statusTitle: _newBlocked ? '已有聚合任务' : '无法打开该聚合任务',
                  statusMessage: _newBlocked
                      ? '请返回消息查看原任务，不会重复创建聚合。'
                      : '任务记录或账号已变化，请返回消息列表查看。不会打开或创建其他任务。',
                  referenceId: widget.taskId.isEmpty ? null : widget.taskId,
                  onBack: _back,
                )
              : note != null && notice?.phase == FeedAggregationPhase.succeeded
              ? V3FeedAggregationResultSurface(
                  sources: notice!.sources,
                  generatedNote: note,
                  headline: note.title,
                  onBack: _back,
                  onSave: () => context.push(
                    '/v3/feed/items/${Uri.encodeComponent(note.id)}?stage=raw',
                  ),
                  onReshuffle: () =>
                      context.push(V3FeedAggregationTaskPage.newTaskRoute),
                )
              : V3FeedAggregationProgressSurface(
                  sourceCount: widget.startNew
                      ? controller.selectedNotes.length
                      : notice!.sourceCount,
                  failed: widget.startNew
                      ? controller.status == FeedAggregationStatus.failed
                      : notice!.phase == FeedAggregationPhase.failed,
                  statusTitle:
                      widget.startNew &&
                          (_selectionOwner == null ||
                              controller.status == FeedAggregationStatus.idle)
                      ? '准备选择聚合来源'
                      : widget.startNew
                      ? controller.taskTitle
                      : notice!.title,
                  statusMessage:
                      widget.startNew &&
                          (_selectionOwner == null ||
                              controller.status == FeedAggregationStatus.idle)
                      ? '核对四篇有效笔记后再确认，尚未提交聚合。'
                      : widget.startNew
                      ? controller.taskMessage
                      : notice!.message,
                  referenceId: widget.startNew
                      ? null
                      : notice!.runId ?? notice.reference,
                  showSkeleton:
                      !widget.startNew &&
                      notice!.phase != FeedAggregationPhase.blocked &&
                      notice.phase !=
                          FeedAggregationPhase.submissionUncertain &&
                      notice.phase != FeedAggregationPhase.failed,
                  retryLabel: canResume ? controller.recoveryLabel : '重新选择笔记',
                  onBack: _back,
                  onLeave:
                      (current || ownsSelection) && controller.hasUnresolvedTask
                      ? _back
                      : null,
                  onRetry: canResume
                      ? controller.resumeTask
                      : canSelectAgain
                      ? widget.startNew
                            ? _prepareSelection
                            : () => context.push(
                                V3FeedAggregationTaskPage.newTaskRoute,
                              )
                      : null,
                ),
        ),
      ),
    );
  }
}

Future<bool> showV3FeedAggregationSelection(
  BuildContext context,
  FeedAggregationController owner, {
  Object? selectionOwner,
}) async {
  final accepted = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: false,
    backgroundColor: Colors.transparent,
    barrierColor: const Color(0x2e000000),
    builder: (sheetContext) => Consumer(
      builder: (context, ref, _) {
        final current = ref.watch(feedAggregationControllerProvider);
        final owns =
            identical(current, owner) &&
            (selectionOwner == null || owner.ownsSelection(selectionOwner));
        ref.listen(
          feedAggregationControllerProvider.select(
            (controller) => (
              controller: controller,
              status: controller.status,
              owns:
                  selectionOwner == null ||
                  controller.ownsSelection(selectionOwner),
            ),
          ),
          (_, next) {
            if (identical(next.controller, owner) &&
                next.owns &&
                next.status == FeedAggregationStatus.selecting) {
              return;
            }
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!sheetContext.mounted) return;
              final route = ModalRoute.of(sheetContext);
              if (route == null || !route.isActive) return;
              if (route.isCurrent) {
                Navigator.of(sheetContext).pop(false);
              } else {
                Navigator.of(sheetContext).removeRoute(route, false);
              }
            });
          },
        );
        return V3FeedAggregationSelectionSheet(
          key: const ValueKey('aggregation-selection'),
          notes: owns ? owner.selectedNotes : const [],
          canReshuffle: owns && owner.canReshuffle,
          canStart: owns && owner.canConfirm,
          onClose: () => Navigator.of(sheetContext).pop(false),
          onReshuffle: () {
            if (identical(ref.read(feedAggregationControllerProvider), owner) &&
                (selectionOwner == null ||
                    owner.ownsSelection(selectionOwner))) {
              owner.reshuffle();
            }
          },
          onStart: () {
            if (identical(ref.read(feedAggregationControllerProvider), owner) &&
                (selectionOwner == null ||
                    owner.ownsSelection(selectionOwner)) &&
                owner.canConfirm) {
              Navigator.of(sheetContext).pop(true);
            }
          },
        );
      },
    ),
  );
  return accepted == true;
}
