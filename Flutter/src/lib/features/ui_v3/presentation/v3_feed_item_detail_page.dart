import 'package:huahuo_foundation/huahuo_foundation.dart'
    show HuahuoMarkdownBlock, HuahuoMarkdownDocument;
import 'package:huahuoai_app/shared/markdown/v3_markdown.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../app/bootstrap/app_providers.dart';
import '../../../shared/navigation/safe_navigation.dart';
import '../../../app/lifecycle/app_activity_coordinator.dart';
import '../../../app/navigation/app_route_observer.dart';
import '../../../app/navigation/app_route_paths.dart';
import '../../../core/api/api_envelope.dart';
import '../../chat/application/resource_image_reader.dart';
import '../../notifications/application/pending_message_projection.dart';
import '../../../shared/theme/huahuo_v3_theme.dart';
import '../../../shared/ui_v3/v3_components.dart';
import '../../../shared/ui_v3/v3_long_running_task_notice.dart';
import '../../../shared/ui_v3/v3_glass_foundations.dart';
import '../../../shared/ui_v3/v3_overlays.dart';
import '../../../shared/ui_v3/v3_text_editing.dart';
import '../application/feed_aggregation_controller.dart';
import '../application/automatic_outline_coordinator.dart';
import '../application/feed_item_detail_controller.dart';
import '../application/knowledge_library_controller.dart';
import '../application/knowledge_note_port.dart';
import '../application/note_append_controller.dart';
import '../application/profile_hub_controller.dart';
import '../application/subscription_port.dart';
import '../domain/feed_item_models.dart';
import '../domain/knowledge_note_outline.dart';
import '../domain/knowledge_export_models.dart';
import '../domain/ui_v3_models.dart';
import 'note/note_detail_surface.dart';
import 'v3_deposit_picker.dart';
import 'v3_knowledge_local_surfaces.dart'
    show showV3KnowledgeNoteDeleteConfirmation;
import 'v3_knowledge_remote_detail.dart'
    show showV3KnowledgeDepositSuccessSheet;
import 'v3_note_chat.dart';

class V3FeedItemDetailPage extends ConsumerStatefulWidget {
  const V3FeedItemDetailPage({
    required this.itemId,
    this.initialStage = V3ContentStage.raw,
    this.initialSectionId,
    super.key,
  });

  final String itemId;
  final V3ContentStage initialStage;
  final String? initialSectionId;

  @override
  ConsumerState<V3FeedItemDetailPage> createState() =>
      _V3FeedItemDetailPageState();
}

class _V3FeedItemDetailPageState extends ConsumerState<V3FeedItemDetailPage>
    with RouteAware {
  static const int _maximumDerivedReceiptEvaluations = 3;
  static const Duration _derivedReceiptRetryBaseDelay = Duration(seconds: 1);

  late final PageController _pageController;
  late final V3ContentStage _initialStage;
  late FeedItemDetailController _detailController;
  PageRoute<dynamic>? _observedRoute;
  bool _routeVisible = true;
  late bool _appForeground;
  String? _sectionCacheKey;
  String? _resolvedSectionId;
  int? _resolvedSectionLine;
  GlobalKey? _resolvedSectionKey;
  bool _sectionScrollScheduled = false;
  final Set<({String key, int generation})> _derivedReceiptEvaluationsInFlight =
      <({String key, int generation})>{};
  Timer? _derivedReceiptRetryTimer;
  String? _derivedReceiptRetryKey;
  int _derivedReceiptEvaluationCount = 0;
  int _derivedReceiptRetryGeneration = 0;
  bool _preparingAgentCreation = false;
  bool _sharingNote = false;
  String? _scheduledRecordingReceiptKey;
  String? _acknowledgedRecordingReceiptKey;

  @override
  void initState() {
    super.initState();
    _detailController = ref.read(
      feedItemDetailControllerProvider(widget.itemId),
    );
    ref.listenManual<FeedItemDetailController>(
      feedItemDetailControllerProvider(widget.itemId),
      (_, next) {
        if (identical(_detailController, next)) return;
        _detailController.setRecordingPollingRouteActive(false);
        _resetDerivedReceiptRetryBudget();
        _detailController = next;
        _syncRecordingPollingActivity();
      },
    );
    _appForeground = ref
        .read(appActivityCoordinatorProvider)
        .state
        .isForeground;
    ref.listenManual<bool>(
      appActivityCoordinatorProvider.select(
        (coordinator) => coordinator.state.isForeground,
      ),
      (_, foreground) {
        _appForeground = foreground;
        _syncRecordingPollingActivity();
        if (foreground) {
          _resetDerivedReceiptRetryBudget();
          _refreshDerivedPartsOnForeground();
        } else {
          _cancelDerivedReceiptRetry();
        }
      },
    );
    ref.listenManual<String>(
      pendingMessageProjectionProvider.select(
        (projection) => pendingMessageRemoteResultRevision(projection.items),
      ),
      (previous, next) {
        if (next.isEmpty || next == previous) return;
        final controller = _detailController;
        final projection = ref.read(pendingMessageProjectionProvider);
        if (!_hasLateRemoteResultForCurrentView(projection, controller)) {
          return;
        }
        _resetDerivedReceiptRetryBudget();
        unawaited(_refreshDerivedPartsAndAcknowledge(controller));
      },
    );
    _initialStage = widget.initialStage;
    _pageController = PageController(initialPage: _initialStage.index);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final controller = _detailController;
      if (_usesExternalKnowledgeReader(controller.item)) return;
      controller.setRecordingPollingRouteActive(
        _routeVisible && _appForeground,
      );
      controller.selectStage(_initialStage);
      unawaited(controller.refreshDerivedParts());
    });
  }

  void _syncRecordingPollingActivity() {
    _detailController.setRecordingPollingRouteActive(
      _routeVisible && _appForeground,
    );
  }

  void _refreshDerivedPartsOnForeground() {
    if (!_routeVisible || !_appForeground || !mounted) return;
    final controller = _detailController;
    if (_usesExternalKnowledgeReader(controller.item)) return;
    unawaited(_refreshDerivedPartsAndAcknowledge(controller));
  }

  Future<void> _refreshDerivedPartsAndAcknowledge(
    FeedItemDetailController controller,
  ) async {
    await controller.refreshDerivedParts();
    if (!mounted ||
        !_routeVisible ||
        !_appForeground ||
        !identical(controller, _detailController) ||
        _usesExternalKnowledgeReader(controller.item)) {
      return;
    }
    _acknowledgeVisibleResults(controller, controller.item);
  }

  @override
  void dispose() {
    _routeVisible = false;
    _cancelDerivedReceiptRetry();
    _syncRecordingPollingActivity();
    if (_observedRoute != null) appRouteObserver.unsubscribe(this);
    _pageController.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is! PageRoute<dynamic> || identical(route, _observedRoute)) {
      return;
    }
    if (_observedRoute != null) appRouteObserver.unsubscribe(this);
    _observedRoute = route;
    _routeVisible = route.isCurrent;
    _syncRecordingPollingActivity();
    appRouteObserver.subscribe(this, route);
  }

  @override
  void didPushNext() {
    _routeVisible = false;
    _cancelDerivedReceiptRetry();
    _syncRecordingPollingActivity();
  }

  @override
  void didPopNext() {
    _routeVisible = true;
    _resetDerivedReceiptRetryBudget();
    _syncRecordingPollingActivity();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_routeVisible) return;
      final controller = _detailController;
      if (_usesExternalKnowledgeReader(controller.item)) return;
      unawaited(_refreshDerivedPartsAndAcknowledge(controller));
    });
  }

  @override
  void didPop() {
    _routeVisible = false;
    _cancelDerivedReceiptRetry();
    _syncRecordingPollingActivity();
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(
      feedItemDetailControllerProvider(widget.itemId),
    );
    if (!controller.hasAuthoritativeItem) {
      return _UnavailableFeedItemDetail(onBack: _leaveDetail);
    }
    final resourceImageCache = ref.watch(resourceImageCacheProvider);
    final item = controller.item;
    final canOpenFreeCreation =
        AssetCanvasSeed.tryFromItem(item: item, stage: controller.stage) !=
        null;
    final usesExternalReader = _usesExternalKnowledgeReader(item);
    final subtitle = <String>[
      item.source.label,
      _formatDate(item.createdAt),
    ].join(' · ');
    if (!usesExternalReader) {
      _acknowledgeVisibleResults(controller, item);
      _prepareInitialSection(item);
    }
    final appends = ref
        .watch(noteAppendControllerProvider)
        .itemsFor(widget.itemId);
    if (usesExternalReader) {
      return _ExternalKnowledgeReaderPage(
        item: item,
        onDeposit: () => _showDepositPicker(item.id),
        onAssistant: () => _showAgentSelector(item),
        onFreeCreation: canOpenFreeCreation ? _openFreeCreation : null,
      );
    }
    final automaticOutline = ref.watch(
      automaticOutlineCoordinatorProvider.select(
        (coordinator) => coordinator.tasks
            .where(
              (task) =>
                  task.localNoteId == item.id &&
                  (task.remoteNoteId == null ||
                      task.remoteNoteId == item.remoteNoteId) &&
                  (task.inputRawRevisionId == null ||
                      task.inputRawRevisionId == item.rawPartRevisionId) &&
                  (task.targetOutlineRevisionId == null ||
                      task.targetOutlineRevisionId ==
                          item.outlinePartRevisionId),
            )
            .firstOrNull,
      ),
    );
    return NoteDetailSurface(
      title: item.title,
      subtitle: subtitle,
      stage: controller.stage,
      onBack: _leaveDetail,
      onMore: _showMoreActions,
      onSelectStage: (stage) {
        controller.selectStage(stage);
        _pageController.animateToPage(
          stage.index,
          duration: V3MotionTokens.emphasized,
          curve: Curves.easeOutCubic,
        );
      },
      pageController: _pageController,
      onPageChanged: (index) =>
          controller.selectStage(V3ContentStage.values[index]),
      bottomBar: NoteDetailCreationDock(
        readOnly: item.isReadOnly,
        onChat: () => _openReferencedChat(item),
        onAssistant: () => _showAgentSelector(item),
        onFreeCreation: canOpenFreeCreation ? _openFreeCreation : null,
      ),
      pages: <Widget>[
        _RawStage(
          item: item,
          appends: appends,
          headingKeysByLine: _headingKeysFor(V3ContentStage.raw),
          resourceImageCache: resourceImageCache,
          onRetryAppend: (id) =>
              unawaited(ref.read(noteAppendControllerProvider).retry(id)),
        ),
        _SummaryStage(
          item: item,
          appends: appends,
          taskStatus: controller.outlineTaskStatus,
          automaticOutline: automaticOutline,
          toolTrace: controller.outlineToolTrace,
          failureMessage: controller.outlineFailureMessage,
          onGenerate: _startOutline,
          onRetry: _retryOutline,
          usesBackendRecordingOutline: controller.usesBackendRecordingOutline,
          canGenerate: controller.canGenerateOutline,
          canRetry: controller.canRetryOutline,
          headingKeysByLine: _headingKeysFor(V3ContentStage.summary),
        ),
        _SproutStage(
          item: item,
          taskStatus: controller.sproutTaskStatus,
          toolTrace: controller.sproutToolTrace,
          failureMessage: controller.sproutFailureMessage,
          onGenerate: _startSprout,
          onRetry: _retrySprout,
          canRetry: !item.isReadOnly,
          headingKeysByLine: _headingKeysFor(V3ContentStage.sprout),
        ),
      ],
    );
  }

  void _acknowledgeVisibleDerivedResult(
    FeedItemDetailController controller,
    V3FeedItem item,
  ) {
    if (!controller.hasAuthoritativeItem ||
        _usesExternalKnowledgeReader(item)) {
      return;
    }
    final visibleStage = controller.stage;
    if (!_hasRenderedStageResult(controller, visibleStage)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_routeVisible || !_appForeground) return;
      final currentController = _detailController;
      final currentItem = currentController.item;
      if (currentItem.id != item.id ||
          !currentController.hasAuthoritativeItem ||
          _usesExternalKnowledgeReader(currentItem) ||
          currentController.stage != visibleStage ||
          !_hasRenderedStageResult(currentController, visibleStage)) {
        return;
      }
      unawaited(_commitVisibleDerivedResult(currentController, visibleStage));
    });
  }

  void _acknowledgeVisibleResults(
    FeedItemDetailController controller,
    V3FeedItem item,
  ) {
    _acknowledgeVisibleRecordingResult(controller, item);
    _acknowledgeVisibleDerivedResult(controller, item);
  }

  void _acknowledgeVisibleRecordingResult(
    FeedItemDetailController controller,
    V3FeedItem item,
  ) {
    if (!_hasRenderedCanonicalRecordingRaw(controller, item)) return;
    final recordingId = item.recordingId!.trim();
    final rawPartRevisionId = item.rawPartRevisionId!.trim();
    final key = '${item.id}|$recordingId|$rawPartRevisionId';
    if (_scheduledRecordingReceiptKey == key ||
        _acknowledgedRecordingReceiptKey == key) {
      return;
    }
    _scheduledRecordingReceiptKey = key;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(
        _commitVisibleRecordingResult(
          controller: controller,
          key: key,
          recordingId: recordingId,
          rawPartRevisionId: rawPartRevisionId,
        ),
      );
    });
  }

  Future<void> _commitVisibleRecordingResult({
    required FeedItemDetailController controller,
    required String key,
    required String recordingId,
    required String rawPartRevisionId,
  }) async {
    try {
      if (!mounted ||
          !_routeVisible ||
          !_appForeground ||
          !identical(controller, _detailController)) {
        return;
      }
      final item = controller.item;
      if (!_hasRenderedCanonicalRecordingRaw(controller, item) ||
          item.recordingId?.trim() != recordingId ||
          item.rawPartRevisionId?.trim() != rawPartRevisionId ||
          '${item.id}|$recordingId|$rawPartRevisionId' != key) {
        return;
      }
      final acknowledged = await ref
          .read(pendingMessageActionsProvider)
          .acknowledgeResultShown(
            targetType: 'recording',
            targetId: recordingId,
            stage: 'recording_processing',
          );
      if (acknowledged) _acknowledgedRecordingReceiptKey = key;
    } finally {
      if (_scheduledRecordingReceiptKey == key) {
        _scheduledRecordingReceiptKey = null;
      }
    }
  }

  Future<void> _commitVisibleDerivedResult(
    FeedItemDetailController controller,
    V3ContentStage visibleStage,
  ) async {
    if (!mounted ||
        !_routeVisible ||
        !_appForeground ||
        !identical(controller, _detailController)) {
      return;
    }
    final item = controller.item;
    if (!controller.hasAuthoritativeItem ||
        _usesExternalKnowledgeReader(item) ||
        controller.stage != visibleStage ||
        !_hasRenderedStageResult(controller, visibleStage)) {
      return;
    }
    final pendingStage = switch (visibleStage) {
      V3ContentStage.raw => 'raw',
      V3ContentStage.summary => 'outline',
      V3ContentStage.sprout => 'sprout',
    };
    final projection = ref.read(pendingMessageProjectionProvider);
    final candidateTaskIds = <String>{
      for (final message in projection.items)
        if (message.isTerminalTask &&
            message.state == PendingMessageState.succeeded &&
            message.targetType == 'asset' &&
            message.targetId == item.id &&
            message.stage == pendingStage) ...<String>{
          if (message.taskId?.trim() case final taskId? when taskId.isNotEmpty)
            taskId,
          for (final alias in message.taskResultAliasIds)
            if (alias.trim().isNotEmpty) alias.trim(),
        },
    };
    final aggregationTaskIds = <String>{};
    if (visibleStage == V3ContentStage.raw) {
      final aggregation = ref.read(feedAggregationControllerProvider);
      aggregationTaskIds.addAll(
        aggregation
            .completedTaskIdsForNote(item.id)
            .intersection(candidateTaskIds),
      );
    }
    final partRevision = controller.resultPartRevision(visibleStage);
    if (candidateTaskIds.isNotEmpty &&
        (partRevision != null || aggregationTaskIds.isNotEmpty)) {
      final evaluationKey = <String>[
        item.id,
        visibleStage.name,
        partRevision ?? '',
        ...candidateTaskIds.toList()..sort(),
      ].join('|');
      if (_derivedReceiptRetryKey != evaluationKey) {
        _resetDerivedReceiptRetryBudget();
        _derivedReceiptRetryKey = evaluationKey;
      }
      if (_derivedReceiptEvaluationCount >= _maximumDerivedReceiptEvaluations) {
        return;
      }
      final evaluationGeneration = _derivedReceiptRetryGeneration;
      final evaluationIdentity = (
        key: evaluationKey,
        generation: evaluationGeneration,
      );
      if (_derivedReceiptEvaluationsInFlight.add(evaluationIdentity)) {
        _cancelDerivedReceiptRetry();
        _derivedReceiptEvaluationCount += 1;
        var receiptCommitted = false;
        try {
          final derivedTaskIds = candidateTaskIds.difference(
            aggregationTaskIds,
          );
          final verifiedTaskIds = <String>{...aggregationTaskIds};
          if (partRevision != null && derivedTaskIds.isNotEmpty) {
            verifiedTaskIds.addAll(
              await controller.verifiedResultTaskIds(
                stage: visibleStage,
                candidateTaskIds: derivedTaskIds,
              ),
            );
          }
          if (!mounted ||
              !_routeVisible ||
              !_appForeground ||
              !identical(controller, _detailController) ||
              controller.stage != visibleStage ||
              controller.resultPartRevision(visibleStage) != partRevision ||
              _usesExternalKnowledgeReader(controller.item) ||
              !_hasRenderedStageResult(controller, visibleStage)) {
            return;
          }
          if (verifiedTaskIds.isNotEmpty) {
            receiptCommitted = await ref
                .read(pendingMessageActionsProvider)
                .acknowledgeResultShown(
                  targetType: 'asset',
                  targetId: controller.item.id,
                  stage: pendingStage,
                  matchingTaskIds: verifiedTaskIds,
                  durableSucceededTaskIds: verifiedTaskIds,
                );
          }
        } catch (_) {
          // Keep the message and use the bounded visible-state retry below.
        } finally {
          _derivedReceiptEvaluationsInFlight.remove(evaluationIdentity);
        }
        if (_derivedReceiptRetryGeneration != evaluationGeneration ||
            _derivedReceiptRetryKey != evaluationKey) {
          return;
        }
        if (receiptCommitted) {
          _resetDerivedReceiptRetryBudget();
        } else {
          _scheduleDerivedReceiptRetry(
            evaluationKey: evaluationKey,
            evaluationGeneration: evaluationGeneration,
            controller: controller,
            visibleStage: visibleStage,
          );
        }
      }
    }
  }

  void _scheduleDerivedReceiptRetry({
    required String evaluationKey,
    required int evaluationGeneration,
    required FeedItemDetailController controller,
    required V3ContentStage visibleStage,
  }) {
    if (!mounted ||
        !_routeVisible ||
        !_appForeground ||
        _derivedReceiptRetryKey != evaluationKey ||
        _derivedReceiptRetryGeneration != evaluationGeneration ||
        _derivedReceiptEvaluationCount >= _maximumDerivedReceiptEvaluations) {
      return;
    }
    final multiplier = 1 << (_derivedReceiptEvaluationCount - 1);
    final delay = _derivedReceiptRetryBaseDelay * multiplier;
    _derivedReceiptRetryTimer = Timer(delay, () {
      _derivedReceiptRetryTimer = null;
      if (!mounted ||
          !_routeVisible ||
          !_appForeground ||
          _derivedReceiptRetryKey != evaluationKey ||
          _derivedReceiptRetryGeneration != evaluationGeneration ||
          !identical(controller, _detailController) ||
          controller.stage != visibleStage) {
        return;
      }
      unawaited(_commitVisibleDerivedResult(controller, visibleStage));
    });
  }

  void _cancelDerivedReceiptRetry() {
    _derivedReceiptRetryTimer?.cancel();
    _derivedReceiptRetryTimer = null;
  }

  void _resetDerivedReceiptRetryBudget() {
    _cancelDerivedReceiptRetry();
    _derivedReceiptRetryGeneration += 1;
    _derivedReceiptRetryKey = null;
    _derivedReceiptEvaluationCount = 0;
  }

  bool _hasRenderedStageResult(
    FeedItemDetailController controller,
    V3ContentStage stage,
  ) {
    final item = controller.item;
    return switch (stage) {
      V3ContentStage.raw => item.rawBody.trim().isNotEmpty,
      V3ContentStage.summary =>
        item.summaryBody?.trim().isNotEmpty == true &&
            (!item.usesBackendRecordingOutline ||
                controller.outlineTaskStatus == V3DerivedTaskStatus.succeeded),
      V3ContentStage.sprout =>
        item.sproutReport?.markdown.trim().isNotEmpty == true,
    };
  }

  bool _hasRenderedCanonicalRecordingRaw(
    FeedItemDetailController controller,
    V3FeedItem item,
  ) {
    return controller.hasAuthoritativeItem &&
        controller.stage == V3ContentStage.raw &&
        item.rawBody.trim().isNotEmpty &&
        item.recordingId?.trim().isNotEmpty == true &&
        item.remoteNoteId?.trim().isNotEmpty == true &&
        item.rawPartRevisionId?.trim().isNotEmpty == true &&
        item.syncState == NoteSyncState.synced;
  }

  bool _hasLateRemoteResultForCurrentView(
    PendingMessageProjection projection,
    FeedItemDetailController controller,
  ) {
    if (!controller.hasAuthoritativeItem ||
        _usesExternalKnowledgeReader(controller.item)) {
      return false;
    }
    final item = controller.item;
    final assetStage = switch (controller.stage) {
      V3ContentStage.raw => 'raw',
      V3ContentStage.summary => 'outline',
      V3ContentStage.sprout => 'sprout',
    };
    return projection.items.any((message) {
      if (message.source != PendingMessageSource.remote ||
          !message.isTerminalTask ||
          message.state != PendingMessageState.succeeded) {
        return false;
      }
      if (message.targetType == 'asset' &&
          message.targetId == item.id &&
          message.stage == assetStage) {
        return true;
      }
      if (controller.stage == V3ContentStage.raw &&
          message.targetType == 'recording' &&
          message.targetId == item.recordingId?.trim() &&
          message.stage == 'recording_processing') {
        return true;
      }
      return false;
    });
  }

  void _prepareInitialSection(V3FeedItem item) {
    final sectionId = widget.initialSectionId?.trim();
    if (sectionId == null || sectionId.isEmpty) return;
    final cacheKey =
        '${item.id}|${item.updatedAt.microsecondsSinceEpoch}|${item.sproutReport?.id ?? ''}|${_initialStage.name}|$sectionId';
    if (_sectionCacheKey == cacheKey) return;
    _sectionCacheKey = cacheKey;
    _resolvedSectionId = null;
    _resolvedSectionLine = null;
    _resolvedSectionKey = null;
    _sectionScrollScheduled = false;
    final outline = V3KnowledgeNoteOutline.fromNote(item);
    final outlineStage = V3KnowledgeOutlineStage.values.firstWhere(
      (stage) => stage.contentStage == _initialStage,
    );
    for (final heading in outline.stage(outlineStage).flattenedHeadings) {
      if (heading.sectionId != sectionId) continue;
      _resolvedSectionId = sectionId;
      _resolvedSectionLine = heading.lineIndex;
      _resolvedSectionKey = GlobalKey(debugLabel: 'detail-section-$sectionId');
      _scheduleInitialSectionScroll();
      break;
    }
  }

  Map<int, GlobalKey>? _headingKeysFor(V3ContentStage stage) {
    if (stage != _initialStage ||
        _resolvedSectionLine == null ||
        _resolvedSectionKey == null) {
      return null;
    }
    return <int, GlobalKey>{_resolvedSectionLine!: _resolvedSectionKey!};
  }

  void _scheduleInitialSectionScroll() {
    if (_sectionScrollScheduled) return;
    _sectionScrollScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToInitialSection(0);
    });
  }

  void _scrollToInitialSection(int attempt) {
    if (!mounted || _resolvedSectionId == null) return;
    final targetContext = _resolvedSectionKey?.currentContext;
    if (targetContext == null) {
      if (attempt < 3) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _scrollToInitialSection(attempt + 1);
        });
      }
      return;
    }
    Scrollable.ensureVisible(
      targetContext,
      alignment: 0.08,
      duration: V3MotionTokens.emphasized,
      curve: Curves.easeOutCubic,
    );
  }

  void _startSprout() {
    unawaited(
      ref.read(feedItemDetailControllerProvider(widget.itemId)).startSprout(),
    );
    _pageController.animateToPage(
      V3ContentStage.sprout.index,
      duration: V3MotionTokens.emphasized,
      curve: Curves.easeOutCubic,
    );
  }

  void _startOutline() {
    unawaited(
      ref.read(feedItemDetailControllerProvider(widget.itemId)).startOutline(),
    );
    _pageController.animateToPage(
      V3ContentStage.summary.index,
      duration: V3MotionTokens.emphasized,
      curve: Curves.easeOutCubic,
    );
  }

  void _retryOutline() {
    unawaited(
      ref.read(feedItemDetailControllerProvider(widget.itemId)).retryOutline(),
    );
    _pageController.animateToPage(
      V3ContentStage.summary.index,
      duration: V3MotionTokens.emphasized,
      curve: Curves.easeOutCubic,
    );
  }

  void _retrySprout() {
    unawaited(
      ref.read(feedItemDetailControllerProvider(widget.itemId)).retrySprout(),
    );
    _pageController.animateToPage(
      V3ContentStage.sprout.index,
      duration: V3MotionTokens.emphasized,
      curve: Curves.easeOutCubic,
    );
  }

  void _leaveDetail() {
    unawaited(returnToPreviousRoute(context, fallbackRoute: '/v3/feed'));
  }

  Future<void> _openReferencedChat(V3FeedItem item) async {
    await showV3NoteChatSheet(context: context, item: item);
  }

  Future<void> _showAgentSelector(V3FeedItem item) async {
    if (_preparingAgentCreation) return;
    final selection = await showV3NoteAgentCreationFlow(context);
    if (!mounted || selection == null) return;
    setState(() => _preparingAgentCreation = true);
    try {
      final reference = await prepareV3AgentCreationMaterial(
        library: ref.read(knowledgeLibraryControllerProvider),
        item: item,
      );
      if (!mounted) return;
      if (reference == null) {
        showV3Snack(context, '资料暂时无法同步到我的资产，请稍后重试');
        return;
      }
      context.push(
        v3AgentAssistedCreationRoute(item: reference, selection: selection),
      );
    } finally {
      if (mounted) setState(() => _preparingAgentCreation = false);
    }
  }

  void _openFreeCreation() {
    final controller = ref.read(
      feedItemDetailControllerProvider(widget.itemId),
    );
    if (!controller.hasAuthoritativeItem) {
      showV3Snack(context, '当前资料尚未准备完成，请稍后重试');
      return;
    }
    final seed = AssetCanvasSeed.tryFromItem(
      item: controller.item,
      stage: controller.stage,
    );
    if (seed == null) {
      showV3Snack(context, '当前${controller.stage.label}内容尚未准备完成');
      return;
    }
    context.push(
      AppRoutePaths.canvasForAsset(seed.assetId),
      extra: seed.withInitialSourceMode(
        AssetCanvasInitialSourceMode.generateTranscript,
      ),
    );
  }

  void _showMoreActions() {
    final item = ref.read(feedItemDetailControllerProvider(widget.itemId)).item;
    final inLibrary =
        ref.read(knowledgeLibraryControllerProvider).noteForId(item.id) != null;
    if (!inLibrary) {
      showV3Snack(context, '该笔记已不存在');
      return;
    }
    final canManage = _canManageNote(item);
    showV3GlassBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) {
        final colors = HuahuoV3Theme.tokensOf(sheetContext);
        return V3SheetScaffold(
          title: '更多操作',
          showClose: true,
          maxHeightFactor: .78,
          child: Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.only(bottom: 8),
              children: [
                ListTile(
                  key: const ValueKey('note-more-distill'),
                  leading: const Icon(Icons.psychology_alt_outlined),
                  title: const Text('蒸馏到数字孪生'),
                  subtitle: const Text('学习观点、方法与人生故事'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    unawaited(
                      showV3DistillationFlow(
                        context: context,
                        ref: ref,
                        noteId: item.id,
                      ),
                    );
                  },
                ),
                ListTile(
                  key: const ValueKey('note-more-share'),
                  leading: const Icon(Icons.share_outlined),
                  title: const Text('分享笔记'),
                  subtitle: const Text('以 Markdown（.md）文件分享'),
                  onTap: _sharingNote
                      ? null
                      : () {
                          Navigator.pop(sheetContext);
                          unawaited(_shareNote(item));
                        },
                ),
                ListTile(
                  key: const ValueKey('note-more-move'),
                  leading: const Icon(Icons.folder_outlined),
                  title: const Text('移动到文件夹'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _showDepositPicker(item.id);
                  },
                ),
                if (canManage)
                  ListTile(
                    key: const ValueKey('note-more-delete'),
                    leading: Icon(
                      Icons.delete_outline_rounded,
                      color: colors.danger,
                    ),
                    title: Text('删除笔记', style: TextStyle(color: colors.danger)),
                    onTap: () {
                      Navigator.pop(sheetContext);
                      _confirmDelete(item);
                    },
                  )
                else
                  const ListTile(
                    leading: Icon(Icons.lock_outline_rounded),
                    title: Text('该资料为只读内容'),
                    subtitle: Text('订阅和知识世界内容不能在本地编辑或删除。'),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _shareNote(V3FeedItem item) async {
    if (_sharingNote) return;
    final library = ref.read(knowledgeLibraryControllerProvider);
    final service = ref.read(knowledgeDocumentExportServiceProvider);
    final sharePort = ref.read(nativePreparedDocumentSharePortProvider);
    final userScope = ref.read(authenticatedUserDataScopeProvider);
    PreparedKnowledgeExport? prepared;
    var handedOff = false;
    setState(() => _sharingNote = true);
    showV3Snack(context, '正在生成 Markdown 文件');
    try {
      if (!item.isReadOnly) {
        await library.refreshRemoteDerivedParts(item.id);
      }
      if (!mounted ||
          ref.read(authenticatedUserDataScopeProvider) != userScope) {
        return;
      }
      final currentItem = library.noteForId(item.id);
      if (currentItem == null) {
        showV3Snack(context, '笔记已不可用，无法分享');
        return;
      }
      final result = await service.prepare(
        KnowledgeExportDocument.fromNote(
          currentItem,
          sourceLabel: currentItem.source.label,
          effectiveTags: library.effectiveTags(currentItem),
          publicUrl: currentItem.publicUrl,
        ),
        KnowledgeExportFormat.markdown,
      );
      prepared = result.value;
      if (!mounted ||
          ref.read(authenticatedUserDataScopeProvider) != userScope) {
        return;
      }
      if (!result.ok || prepared == null) {
        showV3Snack(context, 'Markdown 文件生成失败，请重试');
        return;
      }
      if (library.noteForId(item.id) == null) {
        showV3Snack(context, '笔记已不可用，无法分享');
        return;
      }
      final shared = await sharePort.sharePreparedKnowledgeExport(
        opaqueExportRef: prepared.opaqueExportRef,
        displayName: prepared.displayName,
        mimeType: prepared.mimeType,
      );
      handedOff = shared.ok && shared.value == true;
      if (!mounted ||
          ref.read(authenticatedUserDataScopeProvider) != userScope) {
        return;
      }
      showV3Snack(
        context,
        !shared.ok
            ? '文件分享失败，请重试'
            : handedOff
            ? '已打开 Markdown 文件分享'
            : '已取消分享',
      );
    } catch (_) {
      if (mounted &&
          ref.read(authenticatedUserDataScopeProvider) == userScope) {
        showV3Snack(context, '文件分享失败，请重试');
      }
    } finally {
      if (prepared != null && !handedOff) await service.discard(prepared);
      if (mounted) setState(() => _sharingNote = false);
    }
  }

  Future<void> _showDepositPicker(String contentId) async {
    final library = ref.read(knowledgeLibraryControllerProvider);
    final item = library.noteForId(contentId);
    final isSquareAuthor =
        item?.ownership == V3NoteOwnership.knowledgeSquare ||
        item?.source == V3MaterialSource.knowledgeSquare;
    final record = await showV3DepositPicker(
      context,
      contentId: contentId,
      enableDistillation: isSquareAuthor,
    );
    if (!mounted || record == null || item == null) return;
    await showV3KnowledgeDepositSuccessSheet(
      context,
      article: item,
      depositedNoteId: record.contentId,
    );
  }

  Future<void> _confirmDelete(V3FeedItem item) async {
    final confirmed = await showV3KnowledgeNoteDeleteConfirmation(
      context,
      item,
    );
    if (!confirmed || !mounted) return;

    final library = ref.read(knowledgeLibraryControllerProvider);
    final result = await library.deleteNoteDurably(item.id);
    if (result.outcome != KnowledgeNoteDeleteOutcome.deleted) {
      if (mounted) showV3Snack(context, '删除未完成，笔记仍保留，请重试');
      return;
    }
    ref.read(profileHubControllerProvider).removeActivitiesForNote(item.id);
    if (!mounted) return;
    await returnToPreviousRoute(
      context,
      result: item.id,
      fallbackRoute: AppRoutePaths.home,
    );
  }
}

bool _canManageNote(V3FeedItem item) => !item.isReadOnly;

bool _usesExternalKnowledgeReader(V3FeedItem item) =>
    item.ownership == V3NoteOwnership.subscribed ||
    item.ownership == V3NoteOwnership.knowledgeSquare;

class _UnavailableFeedItemDetail extends StatelessWidget {
  const _UnavailableFeedItemDetail({required this.onBack});

  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            SizedBox(
              height: 56,
              child: Align(
                alignment: Alignment.centerLeft,
                child: V3NavigationBackButton(
                  key: const ValueKey('detail-unavailable-back'),
                  tooltip: '返回',
                  onPressed: onBack,
                ),
              ),
            ),
            Expanded(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.sync_rounded, size: 32, color: colors.muted),
                      const SizedBox(height: 12),
                      const Text(
                        '资料正在同步',
                        key: ValueKey('detail-authoritative-unavailable'),
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '暂未取得这条资料，消息会保留在通知中心。',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: colors.muted,
                          fontSize: 13,
                          height: 1.45,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RawStage extends StatelessWidget {
  const _RawStage({
    required this.item,
    required this.appends,
    required this.onRetryAppend,
    required this.resourceImageCache,
    this.headingKeysByLine,
  });
  final V3FeedItem item;
  final List<V3AppendMaterial> appends;
  final ValueChanged<String> onRetryAppend;
  final ResourceImageReader resourceImageCache;
  final Map<int, GlobalKey>? headingKeysByLine;

  @override
  Widget build(BuildContext context) {
    final rawProjection = item.isLinkImportSource
        ? projectV3UrlImportRawContent(item.rawBody)
        : (markdown: item.rawBody, sourceUrl: null);
    final display = _stageMarkdownContent(
      rawProjection.markdown,
      V3ContentStage.raw,
      headingKeysByLine,
    );
    final referencedAssetPaths = _markdownImageAssetPaths(display.source);
    final leadAssets = item.subscriptionArticleAssets
        .where((asset) => !referencedAssetPaths.contains(asset.logicalPath))
        .toList(growable: false);
    final sourceUri =
        _safeExternalSourceUri(item.publicUrl) ??
        _safeExternalSourceUri(rawProjection.sourceUrl);
    final canVirtualizeTranscript =
        item.isRecordingSource &&
        headingKeysByLine == null &&
        item.mediaAttachments.isEmpty &&
        item.remoteMediaAttachments.isEmpty &&
        leadAssets.isEmpty;
    if (canVirtualizeTranscript) {
      return _VirtualizedRecordingRawStage(
        source: display.source,
        sourceUri: sourceUri,
        appends: appends,
        onRetryAppend: onRetryAppend,
      );
    }
    const bodySliverKey = ValueKey('detail-raw-body-sliver');
    final startsAtBody = headingKeysByLine != null;
    return CustomScrollView(
      center: startsAtBody ? bodySliverKey : null,
      slivers: [
        SliverToBoxAdapter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (sourceUri case final sourceUri?) ...[
                _SourceLinkCard(source: sourceUri),
                const SizedBox(height: 14),
              ],
              for (final attachment in item.mediaAttachments) ...[
                _MediaAttachmentCard(attachment: attachment),
                const SizedBox(height: 14),
              ],
            ],
          ),
        ),
        SliverList.builder(
          itemCount: item.remoteMediaAttachments.length,
          itemBuilder: (context, index) {
            final attachment =
                item.remoteMediaAttachments[startsAtBody
                    ? item.remoteMediaAttachments.length - index - 1
                    : index];
            return Padding(
              key: ValueKey('remote-image-${attachment.resourceId}'),
              padding: const EdgeInsets.only(bottom: 14),
              child: _RemoteMediaAttachmentCard(
                attachment: attachment,
                resourceImageCache: resourceImageCache,
              ),
            );
          },
        ),
        SliverPadding(
          key: bodySliverKey,
          padding: const EdgeInsets.only(bottom: 24),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (leadAssets.isNotEmpty) ...[
                  for (var index = 0; index < leadAssets.length; index++) ...[
                    _SubscriptionArticleMarkdownImage(
                      item: item,
                      logicalPath: leadAssets[index].logicalPath,
                      alt: '文章配图 ${index + 1}',
                      hideWhenUnavailable: true,
                    ),
                    const SizedBox(height: 12),
                  ],
                ],
                if (item.isHotspot && item.rawBody.trim().isEmpty)
                  const _StageEmpty(
                    title: '暂无原始材料',
                    message: '该热点笔记根据当前热点整理生成，默认从纲要开始。',
                  )
                else
                  V3AssistantReplyMarkdown(
                    key: const ValueKey('detail-raw-content'),
                    source: display.source,
                    headingKeysByLine: display.headingKeys,
                    imageBuilder: (context, alt, source) {
                      final logicalPath = _subscriptionImagePathForMarkdown(
                        item,
                        source,
                      );
                      return logicalPath == null
                          ? null
                          : _SubscriptionArticleMarkdownImage(
                              item: item,
                              logicalPath: logicalPath,
                              alt: alt,
                            );
                    },
                  ),
                if (appends.isNotEmpty) ...[
                  const SizedBox(height: 18),
                  const Text(
                    '追加资料',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 10),
                  for (final append in appends) ...[
                    _AppendTimelineItem(
                      item: append,
                      onRetry: append.status == NoteAppendStatus.failed
                          ? () => onRetryAppend(append.id)
                          : null,
                    ),
                    const SizedBox(height: 9),
                  ],
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _VirtualizedRecordingRawStage extends StatefulWidget {
  const _VirtualizedRecordingRawStage({
    required this.source,
    required this.sourceUri,
    required this.appends,
    required this.onRetryAppend,
  });

  final String source;
  final Uri? sourceUri;
  final List<V3AppendMaterial> appends;
  final ValueChanged<String> onRetryAppend;

  @override
  State<_VirtualizedRecordingRawStage> createState() =>
      _VirtualizedRecordingRawStageState();
}

class _VirtualizedRecordingRawStageState
    extends State<_VirtualizedRecordingRawStage> {
  String? _sourceCacheKey;
  List<HuahuoMarkdownBlock> _blocks = const [];

  @override
  Widget build(BuildContext context) {
    _refreshBlocks();
    final prefix = <Widget>[
      if (widget.sourceUri case final sourceUri?) ...[
        _SourceLinkCard(source: sourceUri),
        const SizedBox(height: 14),
      ],
    ];
    final tail = <Widget>[
      if (widget.appends.isNotEmpty) ...[
        const SizedBox(height: 18),
        const Text(
          '追加资料',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 10),
        for (final append in widget.appends) ...[
          _AppendTimelineItem(
            item: append,
            onRetry: append.status == NoteAppendStatus.failed
                ? () => widget.onRetryAppend(append.id)
                : null,
          ),
          const SizedBox(height: 9),
        ],
      ],
      const SizedBox(height: 24),
    ];
    final transcriptStart = prefix.length;
    final tailStart = transcriptStart + _blocks.length;
    return SelectionArea(
      contextMenuBuilder: V3TextEditing.buildSelectionContextMenu,
      child: ListView.builder(
        key: const PageStorageKey<String>('detail-recording-raw-list'),
        padding: EdgeInsets.zero,
        // ignore: deprecated_member_use
        cacheExtent: 960,
        itemCount: prefix.length + _blocks.length + tail.length,
        itemBuilder: (context, index) {
          if (index < transcriptStart) return prefix[index];
          if (index >= tailStart) return tail[index - tailStart];
          final block = _blocks[index - transcriptStart];
          return RepaintBoundary(
            child: Padding(
              key: ValueKey<String>('detail-recording-raw-block-$index'),
              padding: const EdgeInsets.only(bottom: 9),
              child: V3AssistantReplyMarkdown.block(block),
            ),
          );
        },
      ),
    );
  }

  void _refreshBlocks() {
    final sourceKey = widget.source;
    if (_sourceCacheKey == sourceKey) return;
    _sourceCacheKey = sourceKey;
    try {
      _blocks = HuahuoMarkdownDocument.parse(
        sourceKey.trim().isEmpty ? '暂无可展示的原始转写内容。' : sourceKey,
      ).blocks;
    } on FormatException {
      _blocks = HuahuoMarkdownDocument.parse('内容过长或结构过于复杂，暂时无法预览。').blocks;
    }
  }
}

class _ExternalKnowledgeReaderPage extends StatelessWidget {
  const _ExternalKnowledgeReaderPage({
    required this.item,
    required this.onDeposit,
    required this.onAssistant,
    required this.onFreeCreation,
  });

  final V3FeedItem item;
  final VoidCallback onDeposit;
  final VoidCallback onAssistant;
  final VoidCallback? onFreeCreation;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final canvas = colors.canvas;
    final channelName = item.publicationId?.trim().isNotEmpty == true
        ? _externalPublicationLabel(item)
        : item.source.label;
    final category = item.source == V3MaterialSource.subscription
        ? '深度文章'
        : '资讯';
    final preview = _externalBodyFirstParagraph(item.rawBody);
    final coreJudgment = _externalCoreJudgment(item.rawBody);
    return ColoredBox(
      color: canvas,
      child: Scaffold(
        backgroundColor: canvas,
        body: SafeArea(
          child: Column(
            children: [
              const V3PageTopBar(
                title: '文章详情',
                fallbackRoute: '/v3/profile/knowledge?tab=square',
                actions: <Widget>[],
                height: 52,
              ),
              Expanded(
                child: ListView(
                  key: const ValueKey('detail-external-reader'),
                  padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
                  children: [
                    Row(
                      children: [
                        ClipOval(
                          child: Image.asset(
                            'assets/images/knowledge_today_ai.png',
                            width: 34,
                            height: 34,
                            fit: BoxFit.cover,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                channelName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              Text(
                                category,
                                style: TextStyle(
                                  color: colors.accent,
                                  fontSize: 10,
                                ),
                              ),
                            ],
                          ),
                        ),
                        DecoratedBox(
                          decoration: BoxDecoration(
                            color: HuahuoV3Theme.semanticSurface(
                              colors.accent,
                              colors.surface,
                            ),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 6,
                            ),
                            child: Text(
                              item.ownership == V3NoteOwnership.subscribed
                                  ? '已订阅'
                                  : '知识广场',
                              style: TextStyle(
                                color: colors.accent,
                                fontSize: 11,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 22),
                    Text(
                      item.title,
                      style: TextStyle(
                        color: colors.ink,
                        fontSize: 24,
                        height: 1.42,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${item.author?.trim().isNotEmpty == true ? item.author : '花火编辑部'}  ·  ${_formatDate(item.createdAt)}  ·  阅读约 5 分钟',
                      style: TextStyle(color: colors.muted, fontSize: 11),
                    ),
                    const SizedBox(height: 16),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: Image.asset(
                        _externalArticleImage(item),
                        height: 214,
                        width: double.infinity,
                        fit: BoxFit.cover,
                      ),
                    ),
                    if (preview.isNotEmpty) ...[
                      const SizedBox(height: 20),
                      Text(
                        preview,
                        style: TextStyle(
                          color: colors.ink,
                          fontSize: 16,
                          height: 1.75,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    _ExternalKnowledgeReadContent(item: item),
                    if (coreJudgment.isNotEmpty)
                      DecoratedBox(
                        decoration: BoxDecoration(
                          color: colors.surfaceMuted,
                          borderRadius: BorderRadius.circular(6),
                          border: Border(
                            left: BorderSide(color: colors.accent, width: 2),
                          ),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(14),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '核心判断',
                                style: TextStyle(
                                  color: colors.accent,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                coreJudgment,
                                style: const TextStyle(
                                  fontSize: 13.5,
                                  height: 1.65,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    const SizedBox(height: 18),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                child: SizedBox(
                  height: 48,
                  child: Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          key: const ValueKey('external-article-deposit'),
                          onPressed: onDeposit,
                          style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                          ),
                          icon: const Icon(Icons.add_rounded, size: 20),
                          label: const Text('沉淀到笔记'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          key: const ValueKey('external-article-agent'),
                          onPressed: onAssistant,
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                          ),
                          icon: const Icon(
                            Icons.auto_awesome_rounded,
                            size: 20,
                          ),
                          label: const Text('Agent 辅助创作'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (onFreeCreation != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                  child: SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      key: const ValueKey<String>(
                        'external-article-free-creation',
                      ),
                      onPressed: onFreeCreation,
                      icon: const Icon(Icons.edit_note_rounded),
                      label: const Text('Agent 自由创作 · 创建副本'),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

String _externalPublicationLabel(V3FeedItem item) {
  final id = item.publicationId?.trim() ?? '';
  if (id.toLowerCase().contains('culture')) return '中国文化';
  if (id.toLowerCase().contains('law')) return '法治观察';
  return 'AI 深度';
}

String _externalBodyFirstParagraph(String source) {
  for (final line in source.split('\n')) {
    final value = line.replaceFirst(RegExp(r'^#+\s*'), '').trim();
    if (value.isNotEmpty && !value.startsWith('![')) return value;
  }
  return '';
}

String _externalArticleImage(V3FeedItem item) {
  final text = '${item.title} ${item.publicationId ?? ''}'.toLowerCase();
  if (text.contains('agent') || text.contains('交付')) {
    return 'assets/images/knowledge_channel_business.png';
  }
  if (text.contains('文化') || text.contains('城市')) {
    return 'assets/images/knowledge_today_city.png';
  }
  return 'assets/images/knowledge_article_claude.png';
}

class _ExternalKnowledgeReadContent extends StatelessWidget {
  const _ExternalKnowledgeReadContent({required this.item});

  final V3FeedItem item;

  @override
  Widget build(BuildContext context) {
    final display = _stageMarkdownContent(
      _externalKnowledgeBody(item),
      V3ContentStage.raw,
      null,
    );
    final referencedAssetPaths = _markdownImageAssetPaths(display.source);
    final leadAssets = item.subscriptionArticleAssets
        .where((asset) => !referencedAssetPaths.contains(asset.logicalPath))
        .toList(growable: false);
    return Padding(
      key: const ValueKey('detail-external-read-content'),
      padding: const EdgeInsets.only(top: 4, bottom: 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (leadAssets.isNotEmpty)
            for (var index = 0; index < leadAssets.length; index++) ...[
              _SubscriptionArticleMarkdownImage(
                item: item,
                logicalPath: leadAssets[index].logicalPath,
                alt: '文章配图 ${index + 1}',
                hideWhenUnavailable: true,
              ),
              const SizedBox(height: 12),
            ],
          V3AssistantReplyMarkdown(
            key: const ValueKey('detail-external-read-body'),
            source: display.source,
            imageBuilder: (context, alt, source) {
              final logicalPath = _subscriptionImagePathForMarkdown(
                item,
                source,
              );
              return logicalPath == null
                  ? null
                  : _SubscriptionArticleMarkdownImage(
                      item: item,
                      logicalPath: logicalPath,
                      alt: alt,
                    );
            },
          ),
        ],
      ),
    );
  }
}

String _externalKnowledgeBody(V3FeedItem item) {
  final lines = item.rawBody.split('\n');
  var removedLead = false;
  var inCoreJudgment = false;
  final remainder = <String>[];
  for (final line in lines) {
    final value = line.replaceFirst(RegExp(r'^#+\s*'), '').trim();
    if (value == '核心判断') {
      inCoreJudgment = true;
      continue;
    }
    if (inCoreJudgment) {
      if (RegExp(r'^#+\s+').hasMatch(line)) {
        inCoreJudgment = false;
      } else {
        continue;
      }
    }
    if (!removedLead && value.isNotEmpty && !value.startsWith('![')) {
      removedLead = true;
      continue;
    }
    remainder.add(line);
  }
  return remainder.join('\n').trimLeft();
}

String _externalCoreJudgment(String source) {
  final result = <String>[];
  var collecting = false;
  for (final line in source.split('\n')) {
    final value = line.replaceFirst(RegExp(r'^#+\s*'), '').trim();
    if (value == '核心判断') {
      collecting = true;
      continue;
    }
    if (collecting && RegExp(r'^#+\s+').hasMatch(line)) break;
    if (collecting && value.isNotEmpty) result.add(value);
  }
  return result.join('\n');
}

Uri? _safeExternalSourceUri(String? value) {
  final normalized = normalizeV3PublicSourceUrl(value);
  return normalized == null ? null : Uri.parse(normalized);
}

class _SourceLinkCard extends StatelessWidget {
  const _SourceLinkCard({required this.source});

  final Uri source;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: const ValueKey('detail-source-link'),
        borderRadius: BorderRadius.circular(8),
        onTap: () async {
          final opened = await launchUrl(
            source,
            mode: LaunchMode.externalApplication,
          );
          if (!opened && context.mounted) {
            showV3Snack(context, '暂时无法打开来源链接');
          }
        },
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: colors.surface.withValues(alpha: .62),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: colors.line),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(13, 11, 10, 11),
            child: Row(
              children: [
                Icon(Icons.link_rounded, color: colors.primary, size: 19),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    source.toString(),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.primary,
                      decoration: TextDecoration.underline,
                      decorationColor: colors.primary,
                      height: 1.35,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Icon(Icons.open_in_new_rounded, color: colors.muted, size: 18),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String? _subscriptionImagePathForMarkdown(V3FeedItem item, String source) {
  final logicalPath = source.trim();
  for (final asset in item.subscriptionArticleAssets) {
    if (asset.logicalPath == logicalPath) return logicalPath;
  }
  if (item.isSavedSubscriptionNote &&
      isV3SubscriptionNoteAssetPath(logicalPath)) {
    return logicalPath;
  }
  return null;
}

Set<String> _markdownImageAssetPaths(String markdown) =>
    RegExp(
          r'^\s*!\[[^\]\r\n]*\]\(([^)\s]+)(?:\s+"[^"]*")?\)\s*$',
          multiLine: true,
        )
        .allMatches(markdown)
        .map((match) => (match.group(1) ?? '').trim())
        .where((path) => path.isNotEmpty)
        .toSet();

class _SubscriptionArticleMarkdownImage extends ConsumerStatefulWidget {
  const _SubscriptionArticleMarkdownImage({
    required this.item,
    required this.logicalPath,
    required this.alt,
    this.hideWhenUnavailable = false,
  });

  final V3FeedItem item;
  final String logicalPath;
  final String alt;
  final bool hideWhenUnavailable;

  @override
  ConsumerState<_SubscriptionArticleMarkdownImage> createState() =>
      _SubscriptionArticleMarkdownImageState();
}

class _SubscriptionArticleMarkdownImageState
    extends ConsumerState<_SubscriptionArticleMarkdownImage> {
  late Future<MobileSubscriptionArticleAssetResult> _asset;

  @override
  void initState() {
    super.initState();
    _asset = _loadAsset();
  }

  @override
  void didUpdateWidget(covariant _SubscriptionArticleMarkdownImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.id != widget.item.id ||
        oldWidget.item.remoteNoteId != widget.item.remoteNoteId ||
        oldWidget.item.rawPartRevisionId != widget.item.rawPartRevisionId ||
        oldWidget.item.articleRevisionId != widget.item.articleRevisionId ||
        oldWidget.logicalPath != widget.logicalPath) {
      _asset = _loadAsset();
    }
  }

  Future<MobileSubscriptionArticleAssetResult> _loadAsset() {
    return ref
        .read(knowledgeLibraryControllerProvider)
        .loadRemoteSubscriptionArticleAsset(widget.item.id, widget.logicalPath);
  }

  @override
  Widget build(BuildContext context) {
    final label = widget.alt.isEmpty ? '文章图片' : widget.alt;
    return Padding(
      key: ValueKey(
        'subscription-article-image-${widget.item.id}-'
        '${widget.logicalPath}',
      ),
      padding: const EdgeInsets.only(bottom: 12),
      child: FutureBuilder<MobileSubscriptionArticleAssetResult>(
        future: _asset,
        builder: (context, snapshot) {
          final loaded = snapshot.data?.asset;
          if (snapshot.connectionState != ConnectionState.done) {
            return const SizedBox(
              height: 180,
              child: Center(child: CircularProgressIndicator()),
            );
          }
          if (snapshot.data?.status != MobileSubscriptionResultStatus.success ||
              loaded == null) {
            return widget.hideWhenUnavailable
                ? const SizedBox.shrink()
                : _SubscriptionArticleImageUnavailable(label: label);
          }
          return LayoutBuilder(
            builder: (context, constraints) => Image.memory(
              loaded.bytes,
              fit: BoxFit.contain,
              cacheWidth: constraints.maxWidth.isFinite
                  ? (constraints.maxWidth *
                            MediaQuery.devicePixelRatioOf(context))
                        .ceil()
                        .clamp(1, 4096)
                        .toInt()
                  : null,
              semanticLabel: label,
              errorBuilder: (_, __, ___) => widget.hideWhenUnavailable
                  ? const SizedBox.shrink()
                  : _SubscriptionArticleImageUnavailable(label: label),
            ),
          );
        },
      ),
    );
  }
}

class _SubscriptionArticleImageUnavailable extends StatelessWidget {
  const _SubscriptionArticleImageUnavailable({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return SizedBox(
      height: 120,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.broken_image_outlined, color: colors.muted),
            const SizedBox(height: 6),
            Text(label, style: TextStyle(color: colors.muted, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

class _SummaryStage extends StatelessWidget {
  const _SummaryStage({
    required this.item,
    required this.appends,
    required this.taskStatus,
    this.toolTrace = const <AgentRunToolTrace>[],
    this.failureMessage,
    required this.onGenerate,
    required this.onRetry,
    required this.usesBackendRecordingOutline,
    required this.canGenerate,
    required this.canRetry,
    this.headingKeysByLine,
    this.automaticOutline,
  });
  final V3FeedItem item;
  final List<V3AppendMaterial> appends;
  final V3DerivedTaskStatus taskStatus;
  final List<AgentRunToolTrace> toolTrace;
  final String? failureMessage;
  final VoidCallback onGenerate;
  final VoidCallback onRetry;
  final bool usesBackendRecordingOutline;
  final bool canGenerate;
  final bool canRetry;
  final Map<int, GlobalKey>? headingKeysByLine;
  final AutomaticOutlineTaskSnapshot? automaticOutline;

  @override
  Widget build(BuildContext context) {
    final summary = item.summaryBody;
    final demoSummaries = appends
        .where(
          (append) =>
              append.status == NoteAppendStatus.completed &&
              append.summary?.trim().isNotEmpty == true,
        )
        .toList();
    final hasOutlineContent =
        summary?.trim().isNotEmpty == true || demoSummaries.isNotEmpty;
    final admission = automaticOutline;
    if (!usesBackendRecordingOutline &&
        taskStatus != V3DerivedTaskStatus.running &&
        admission != null) {
      if (!admission.isTerminal) {
        return _DerivedTaskActivity(
          title: admission.statusLabel,
          message: admission.statusMessage,
        );
      }
      if (!hasOutlineContent) {
        return _GenerationFailureState(
          title: admission.statusLabel,
          message: admission.statusMessage,
          actionKey: const ValueKey('detail-retry-outline'),
          onRetry: canRetry ? onRetry : null,
        );
      }
    }
    if (taskStatus == V3DerivedTaskStatus.running ||
        (taskStatus == V3DerivedTaskStatus.failed && !hasOutlineContent)) {
      return switch (taskStatus) {
        V3DerivedTaskStatus.running => _DerivedTaskActivity(
          title: '正在生成纲要',
          message: usesBackendRecordingOutline
              ? '正在梳理录音内容与结构，请稍候。'
              : '正在梳理原始内容与结构，请稍候。',
          toolTrace: toolTrace,
        ),
        V3DerivedTaskStatus.failed => _GenerationFailureState(
          title: '纲要生成失败',
          message: failureMessage ?? '生成过程中遇到问题，请稍后重试。',
          actionKey: const ValueKey('detail-retry-outline'),
          onRetry: canRetry ? onRetry : null,
        ),
        _ => const SizedBox.shrink(),
      };
    }
    if (!hasOutlineContent) {
      return switch (taskStatus) {
        V3DerivedTaskStatus.idle when usesBackendRecordingOutline =>
          const _DerivedTaskActivity(
            title: '正在生成纲要',
            message: '正在梳理录音内容与结构，请稍候。',
          ),
        V3DerivedTaskStatus.idle => _GenerationEmptyState(
          icon: Icons.format_list_bulleted_rounded,
          title: '尚未生成纲要',
          message: '将从当前原始内容生成纲要并保存到云端。',
          actionLabel: '生成纲要',
          actionKey: const ValueKey('detail-generate-outline'),
          onGenerate: canGenerate ? onGenerate : null,
        ),
        _ => const _StageEmpty(title: '纲要状态同步中', message: '等待服务返回最终纲要。'),
      };
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (taskStatus == V3DerivedTaskStatus.failed) ...[
            _GenerationFailureNotice(
              message: failureMessage ?? '本次更新没有完成，当前显示的是已保存纲要。',
              actionKey: const ValueKey('detail-retry-outline'),
              onRetry: canRetry ? onRetry : null,
            ),
            const SizedBox(height: 18),
          ],
          if (demoSummaries.isNotEmpty) ...[
            const Text('追加摘要', style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 9),
            for (final append in demoSummaries) ...[
              Text(
                '${append.source.label}：${append.summary!}',
                style: const TextStyle(fontSize: 14, height: 1.45),
              ),
              if (append != demoSummaries.last) const SizedBox(height: 7),
            ],
            const SizedBox(height: 8),
            Text(
              '仅当前会话可见，未写入正式笔记。',
              style: TextStyle(
                color: HuahuoV3Theme.tokensOf(context).muted,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 14),
            Divider(color: Theme.of(context).dividerColor),
            const SizedBox(height: 14),
          ],
          if (summary != null)
            _NoteGeneratedContent(
              key: const ValueKey('detail-summary-content'),
              item: item,
              stage: V3KnowledgeOutlineStage.summary,
              headingKeysByLine: headingKeysByLine,
            )
          else
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 28),
              child: _GenerationEmptyState(
                icon: Icons.format_list_bulleted_rounded,
                title: '尚未生成纲要',
                message: '将从当前原始内容生成纲要并保存到云端。',
                actionLabel: '生成纲要',
                actionKey: const ValueKey('detail-generate-outline'),
                onGenerate: canGenerate ? onGenerate : null,
              ),
            ),
        ],
      ),
    );
  }
}

class _SproutStage extends StatelessWidget {
  const _SproutStage({
    required this.item,
    required this.taskStatus,
    this.toolTrace = const <AgentRunToolTrace>[],
    required this.onGenerate,
    required this.onRetry,
    required this.canRetry,
    this.failureMessage,
    this.headingKeysByLine,
  });
  final V3FeedItem item;
  final V3DerivedTaskStatus taskStatus;
  final List<AgentRunToolTrace> toolTrace;
  final VoidCallback onGenerate;
  final VoidCallback onRetry;
  final bool canRetry;
  final String? failureMessage;
  final Map<int, GlobalKey>? headingKeysByLine;

  @override
  Widget build(BuildContext context) {
    return switch (taskStatus) {
      V3DerivedTaskStatus.idle => _GenerationEmptyState(
        icon: Icons.local_fire_department_outlined,
        title: '尚未生成深度洞察',
        message: '将基于当前笔记生成深度洞察并保存到云端。',
        actionLabel: '生成深度洞察',
        actionKey: const ValueKey('detail-generate-sprout'),
        onGenerate: item.isReadOnly ? null : onGenerate,
      ),
      V3DerivedTaskStatus.failed => _GenerationFailureState(
        title: '深度洞察生成失败',
        message: failureMessage ?? '生成过程中遇到问题，请稍后重试。',
        actionKey: const ValueKey('detail-retry-sprout'),
        onRetry: canRetry ? onRetry : null,
      ),
      V3DerivedTaskStatus.running => _DerivedTaskActivity(
        title: '正在生成深度洞察',
        message: '正在提炼可继续创作的火花，请稍候。',
        toolTrace: toolTrace,
      ),
      V3DerivedTaskStatus.succeeded => SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: 24),
        child: _NoteGeneratedContent(
          key: const ValueKey('detail-sprout-content'),
          item: item,
          stage: V3KnowledgeOutlineStage.sprout,
          headingKeysByLine: headingKeysByLine,
        ),
      ),
    };
  }
}

class _NoteGeneratedContent extends StatelessWidget {
  const _NoteGeneratedContent({
    required this.item,
    required this.stage,
    this.headingKeysByLine,
    super.key,
  });

  final V3FeedItem item;
  final V3KnowledgeOutlineStage stage;
  final Map<int, GlobalKey>? headingKeysByLine;

  @override
  Widget build(BuildContext context) {
    final section = V3KnowledgeNoteOutline.fromNote(item).stage(stage);
    final display = _stageMarkdownContent(
      section.source,
      stage.contentStage,
      headingKeysByLine,
    );
    return V3AssistantReplyMarkdown(
      source: display.source,
      headingKeysByLine: display.headingKeys,
    );
  }
}

class _StageEmpty extends StatelessWidget {
  const _StageEmpty({required this.title, required this.message});
  final String title;
  final String message;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 26),
    child: Column(
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 7),
        Text(
          message,
          textAlign: TextAlign.center,
          style: TextStyle(color: HuahuoV3Theme.tokensOf(context).muted),
        ),
      ],
    ),
  );
}

class _GenerationEmptyState extends StatelessWidget {
  const _GenerationEmptyState({
    required this.icon,
    required this.title,
    required this.message,
    required this.actionLabel,
    required this.actionKey,
    required this.onGenerate,
  });

  final IconData icon;
  final String title;
  final String message;
  final String actionLabel;
  final Key actionKey;
  final VoidCallback? onGenerate;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Center(
      child: Transform.translate(
        offset: const Offset(0, -14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Icon(icon, size: 38, color: colors.ink),
            const SizedBox(height: 20),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: colors.muted, fontSize: 14, height: 1.45),
            ),
            if (onGenerate != null) ...[
              const SizedBox(height: 32),
              _GenerationActionButton(
                key: actionKey,
                label: actionLabel,
                onPressed: onGenerate!,
                primary: true,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _GenerationFailureState extends StatelessWidget {
  const _GenerationFailureState({
    required this.title,
    required this.message,
    required this.actionKey,
    required this.onRetry,
  });

  final String title;
  final String message;
  final Key actionKey;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Center(
      child: Transform.translate(
        offset: const Offset(0, -13),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: colors.danger.withValues(alpha: .10),
              ),
              alignment: Alignment.center,
              child: Icon(
                Icons.error_outline_rounded,
                color: colors.danger,
                size: 24,
              ),
            ),
            const SizedBox(height: 13),
            Text(
              title,
              style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: colors.muted, fontSize: 14, height: 1.45),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 39),
              SizedBox(
                width: 156,
                child: _GenerationActionButton(
                  key: actionKey,
                  label: '重新生成',
                  onPressed: onRetry!,
                  icon: Icons.refresh_rounded,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _GenerationFailureNotice extends StatelessWidget {
  const _GenerationFailureNotice({
    required this.message,
    required this.actionKey,
    required this.onRetry,
  });

  final String message;
  final Key actionKey;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
      decoration: BoxDecoration(
        color: colors.danger.withValues(alpha: .06),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.danger.withValues(alpha: .18)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
              Icons.error_outline_rounded,
              color: colors.danger,
              size: 20,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '纲要更新失败',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(
                  message,
                  style: TextStyle(
                    color: colors.muted,
                    fontSize: 13,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
          if (onRetry != null) ...[
            const SizedBox(width: 6),
            IconButton(
              key: actionKey,
              tooltip: '重新生成纲要',
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded),
              color: colors.ink,
            ),
          ],
        ],
      ),
    );
  }
}

class _GenerationActionButton extends StatelessWidget {
  const _GenerationActionButton({
    required this.label,
    required this.onPressed,
    this.icon,
    this.primary = false,
    super.key,
  });

  final String label;
  final VoidCallback onPressed;
  final IconData? icon;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return SizedBox(
      height: 50,
      child: Material(
        color: primary ? colors.ink : colors.surfaceMuted,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (icon != null) ...[
                Icon(
                  icon,
                  size: 19,
                  color: primary ? colors.canvas : colors.ink,
                ),
                const SizedBox(width: 8),
              ],
              Text(
                label,
                style: TextStyle(
                  color: primary ? colors.canvas : colors.ink,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DerivedTaskActivity extends StatelessWidget {
  const _DerivedTaskActivity({
    required this.title,
    required this.message,
    this.toolTrace = const <AgentRunToolTrace>[],
  });

  final String title;
  final String message;
  final List<AgentRunToolTrace> toolTrace;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final latestTool = _latestDerivedToolTrace(toolTrace);
    return Semantics(
      label: latestTool == null
          ? '$title，正在后台处理'
          : '$title，${_derivedToolLabel(latestTool.toolName)}，'
                '${_derivedToolStateLabel(latestTool)}',
      child: Center(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox.square(
                    dimension: 24,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.4,
                      color: colors.ink,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                message,
                textAlign: TextAlign.center,
                style: TextStyle(color: colors.muted, fontSize: 14),
              ),
              if (latestTool != null) ...[
                const SizedBox(height: 10),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _derivedToolIcon(latestTool.toolName),
                      size: 15,
                      color: colors.muted,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '${_derivedToolLabel(latestTool.toolName)} · '
                      '${_derivedToolStateLabel(latestTool)}',
                      style: TextStyle(color: colors.muted, fontSize: 12),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 12),
              const _GenerationSkeleton(),
              const SizedBox(height: 12),
              const V3LongRunningTaskNotice(),
            ],
          ),
        ),
      ),
    );
  }
}

AgentRunToolTrace? _latestDerivedToolTrace(List<AgentRunToolTrace> traces) {
  AgentRunToolTrace? latest;
  for (final trace in traces) {
    if (latest == null || trace.createdAt.isAfter(latest.createdAt)) {
      latest = trace;
    }
  }
  return latest;
}

String _derivedToolLabel(String toolName) => switch (toolName) {
  'edit' => '编辑内容',
  'read' => '读取资料',
  'workspace_list' => '查看工作区',
  'workspace_search' => '检索工作区',
  'write' => '整理并写入内容',
  'image_analysis' => '分析图片',
  'image_generation' => '生成图片',
  'video_analysis' => '分析视频',
  'huahuo_hotspot_query' => '检索热点',
  _ => '执行工具',
};

IconData _derivedToolIcon(String toolName) => switch (toolName) {
  'edit' => LucideIcons.pencil,
  'read' => LucideIcons.fileText,
  'workspace_list' => LucideIcons.folderOpen,
  'workspace_search' => LucideIcons.search,
  'write' => LucideIcons.filePenLine,
  'image_analysis' => LucideIcons.image,
  'image_generation' => LucideIcons.images,
  'video_analysis' => LucideIcons.video,
  'huahuo_hotspot_query' => LucideIcons.flame,
  _ => LucideIcons.loaderCircle,
};

String _derivedToolStateLabel(AgentRunToolTrace trace) => switch (trace.state) {
  'started' => '进行中',
  'finished' when trace.outcome == 'failed' => '未完成',
  'finished' => '已完成',
  'rejected' => '未执行',
  _ => '进行中',
};

class _GenerationSkeleton extends StatelessWidget {
  const _GenerationSkeleton();

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    const widths = <double>[104, 326, 308, 326, 288, 214];
    return Container(
      height: 130,
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          for (final width in widths)
            Container(
              width: width,
              height: 6,
              decoration: BoxDecoration(
                color: colors.line.withValues(alpha: .72),
                borderRadius: BorderRadius.circular(999),
              ),
            ),
        ],
      ),
    );
  }
}

({String source, Map<int, GlobalKey>? headingKeys}) _stageMarkdownContent(
  String source,
  V3ContentStage stage,
  Map<int, GlobalKey>? headingKeys,
) {
  final lines = source.split(RegExp(r'\r?\n'));
  final firstContentLine = lines.indexWhere((line) => line.trim().isNotEmpty);
  if (firstContentLine < 0) {
    return (source: source, headingKeys: headingKeys);
  }
  final normalized = lines[firstContentLine]
      .trim()
      .replaceFirst(RegExp(r'^#{1,3}\s*'), '')
      .replaceFirst(RegExp(r'[：:]$'), '')
      .trim();
  final duplicateHeadings = switch (stage) {
    V3ContentStage.raw => const <String>{'原始', '原始内容', '笔记原始内容', '原始材料'},
    V3ContentStage.summary => const <String>{
      '纲要',
      '内容纲要',
      '笔记纲要',
      '摘要',
      '内容摘要',
    },
    V3ContentStage.sprout => const <String>{
      '点火',
      '点火内容',
      '点火报告',
      '深度洞察',
      '深度洞察内容',
      '深度洞察报告',
    },
  };
  if (!duplicateHeadings.contains(normalized)) {
    return (source: source, headingKeys: headingKeys);
  }
  lines.removeAt(firstContentLine);
  final remappedKeys = headingKeys == null
      ? null
      : <int, GlobalKey>{
          for (final entry in headingKeys.entries)
            if (entry.key != firstContentLine)
              (entry.key > firstContentLine ? entry.key - 1 : entry.key):
                  entry.value,
        };
  return (source: lines.join('\n'), headingKeys: remappedKeys);
}

class _AppendTimelineItem extends StatelessWidget {
  const _AppendTimelineItem({required this.item, this.onRetry});

  final V3AppendMaterial item;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final color = switch (item.status) {
      NoteAppendStatus.completed => colors.success,
      NoteAppendStatus.failed => colors.danger,
      _ => colors.accent,
    };
    final label = switch (item.status) {
      NoteAppendStatus.uploading => '上传中',
      NoteAppendStatus.analyzing => '分析中',
      NoteAppendStatus.completed => '已完成',
      NoteAppendStatus.failed => '追加失败',
    };
    return V3Card(
      glass: false,
      radius: 8,
      padding: const EdgeInsets.all(13),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: color.withValues(alpha: .09),
              shape: BoxShape.circle,
            ),
            child: Icon(_appendSourceIcon(item.source), color: color, size: 18),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      label,
                      style: TextStyle(
                        color: color,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '${item.source.label} · ${_formatAppendTime(item.addedAt)}',
                  style: TextStyle(color: colors.muted, fontSize: 12),
                ),
                if (item.summary != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    item.summary!,
                    style: const TextStyle(fontSize: 13, height: 1.4),
                  ),
                ],
                if (onRetry != null) ...[
                  const SizedBox(height: 5),
                  TextButton.icon(
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh_rounded, size: 17),
                    label: Text('重试 ${item.errorCode ?? ''}'),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

IconData _appendSourceIcon(NoteAppendSource source) => switch (source) {
  NoteAppendSource.monologue => Icons.mic_none_rounded,
  NoteAppendSource.meeting => Icons.groups_outlined,
  NoteAppendSource.internalRecording => Icons.screen_share_outlined,
  NoteAppendSource.link => Icons.link_rounded,
  NoteAppendSource.phoneAudio => Icons.audio_file_outlined,
  NoteAppendSource.localRecording => Icons.library_music_outlined,
  NoteAppendSource.recordingCard => Icons.memory_rounded,
  NoteAppendSource.document => Icons.description_outlined,
  NoteAppendSource.media => Icons.photo_library_outlined,
  NoteAppendSource.relatedNote => Icons.note_alt_outlined,
};

String _formatAppendTime(DateTime value) {
  final local = value.toLocal();
  return '${local.month}月${local.day}日 '
      '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}';
}

class _MediaAttachmentCard extends StatelessWidget {
  const _MediaAttachmentCard({required this.attachment});

  final V3MediaAttachment attachment;

  @override
  Widget build(BuildContext context) {
    if (attachment.kind == V3MediaAttachmentKind.image) {
      final file = File(attachment.privatePath);
      return V3Card(
        padding: EdgeInsets.zero,
        child: LayoutBuilder(
          builder: (context, constraints) => ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.file(
              file,
              fit: BoxFit.cover,
              cacheWidth: constraints.maxWidth.isFinite
                  ? (constraints.maxWidth *
                            MediaQuery.devicePixelRatioOf(context))
                        .ceil()
                        .clamp(1, 4096)
                        .toInt()
                  : null,
              errorBuilder: (_, __, ___) => const SizedBox(
                height: 120,
                child: Center(child: Icon(Icons.broken_image_outlined)),
              ),
            ),
          ),
        ),
      );
    }
    return V3Card(
      child: Row(
        children: [
          const Icon(Icons.videocam_outlined),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              attachment.displayName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          Text(
            _formatAttachmentSize(attachment.sizeBytes),
            style: TextStyle(
              color: HuahuoV3Theme.tokensOf(context).muted,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

class _RemoteMediaAttachmentCard extends StatefulWidget {
  const _RemoteMediaAttachmentCard({
    required this.attachment,
    required this.resourceImageCache,
  });

  final V3RemoteMediaAttachment attachment;
  final ResourceImageReader resourceImageCache;

  @override
  State<_RemoteMediaAttachmentCard> createState() =>
      _RemoteMediaAttachmentCardState();
}

class _RemoteMediaAttachmentCardState
    extends State<_RemoteMediaAttachmentCard> {
  static const _loadingPlaceholder = SizedBox(
    height: 160,
    child: Center(
      child: SizedBox.square(
        dimension: 24,
        child: CircularProgressIndicator.adaptive(strokeWidth: 2),
      ),
    ),
  );

  late Future<CachedResourceImage> _image;

  @override
  void initState() {
    super.initState();
    _image = widget.resourceImageCache.load(widget.attachment.resourceId);
  }

  @override
  void didUpdateWidget(covariant _RemoteMediaAttachmentCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.attachment.resourceId != widget.attachment.resourceId ||
        !identical(oldWidget.resourceImageCache, widget.resourceImageCache)) {
      _image = widget.resourceImageCache.load(widget.attachment.resourceId);
    }
  }

  void _retry() {
    setState(() {
      _image = widget.resourceImageCache.load(widget.attachment.resourceId);
    });
  }

  @override
  Widget build(BuildContext context) {
    return V3Card(
      padding: EdgeInsets.zero,
      child: FutureBuilder<CachedResourceImage>(
        key: ObjectKey(_image),
        future: _image,
        builder: (context, snapshot) {
          final image = snapshot.data;
          if (image != null) {
            return LayoutBuilder(
              builder: (context, constraints) => ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.memory(
                  image.bytes,
                  fit: BoxFit.cover,
                  frameBuilder:
                      (context, child, frame, wasSynchronouslyLoaded) =>
                          wasSynchronouslyLoaded || frame != null
                          ? child
                          : _loadingPlaceholder,
                  cacheWidth: constraints.maxWidth.isFinite
                      ? (constraints.maxWidth *
                                MediaQuery.devicePixelRatioOf(context))
                            .ceil()
                            .clamp(1, 4096)
                            .toInt()
                      : null,
                  errorBuilder: (_, __, ___) => const SizedBox(
                    height: 120,
                    child: Center(child: Icon(Icons.broken_image_outlined)),
                  ),
                ),
              ),
            );
          }
          if (snapshot.connectionState != ConnectionState.done) {
            return _loadingPlaceholder;
          }
          return SizedBox(
            height: 120,
            child: Center(
              child: TextButton.icon(
                onPressed: _retry,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('重新加载图片'),
              ),
            ),
          );
        },
      ),
    );
  }
}

String _formatAttachmentSize(int bytes) {
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

String _formatDate(DateTime value) => '${value.month}月${value.day}日';
