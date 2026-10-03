import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/bootstrap/asset_projection_cache_scope.dart';
import '../../../app/navigation/app_route_observer.dart';
import '../../../app/runtime/runtime_provider_module.dart';
import '../../../core/api/api_client.dart';
import '../../../core/tasking/orchestrated_poller.dart';
import '../../../core/tasking/task_orchestrator.dart';
import '../../../shared/theme/huahuo_v3_theme.dart';
import '../../../shared/ui_v3/v3_components.dart';
import '../../../shared/ui_v3/v3_glass_foundations.dart';
import '../../../shared/ui_v3/v3_overlays.dart';
import '../../../shared/ui_v3/v3_text_editing.dart';
import '../../assets/application/assets_controller.dart';

enum _AssetMenuAction { sync, refresh }

class V3AssetsPage extends ConsumerStatefulWidget {
  const V3AssetsPage({this.focus, super.key});

  final AssetMarkdownFocus? focus;

  @override
  ConsumerState<V3AssetsPage> createState() => _V3AssetsPageState();
}

class _V3AssetsPageState extends ConsumerState<V3AssetsPage>
    with AppActivityRouteAware<V3AssetsPage> {
  final _scrollController = ScrollController();
  final _anchorKeys = <String, GlobalKey>{};
  AssetsRequestOwner _requestOwner = AssetsRequestOwner();
  OrchestratedPoller? _liveRefreshPoller;
  bool _hasLiveAssetWork = false;
  bool _liveRefreshInFlight = false;
  AssetsController? _liveRefreshController;
  AssetsController? _syncController;
  bool _queuedRefresh = false;
  bool _queuedRefreshForce = false;
  bool _queuedRefreshInvalidatesCache = false;

  @override
  void initState() {
    super.initState();
    ref.listenManual<AssetProjectionFreshness>(
      assetProjectionFreshnessProvider,
      (previous, next) {
        if (previous == null || previous.revision == next.revision) return;
        _configureLiveRefresh(next.hasActiveWork);
        unawaited(_reloadAssets(force: true, invalidateCache: true));
      },
    );
    ref.listenManual<AssetsController>(assetsControllerProvider, (
      previous,
      next,
    ) {
      if (previous == null || identical(previous, next)) return;
      unawaited(_reloadAssets(force: true));
    });
    final hasLiveWork = ref
        .read(assetProjectionFreshnessProvider)
        .hasActiveWork;
    _configureLiveRefresh(hasLiveWork);
    Future<void>.microtask(() => _reloadAssets(force: hasLiveWork));
  }

  @override
  void dispose() {
    _liveRefreshPoller?.dispose();
    _cancelOwnedRefresh();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void onActivityRouteBecameActive() {
    final ownerWasInactive = !_requestOwner.isActive;
    if (ownerWasInactive) _requestOwner = AssetsRequestOwner();
    if (_hasLiveAssetWork) {
      _startLiveRefresh(immediate: ownerWasInactive);
    } else if (ownerWasInactive) {
      unawaited(_reloadAssets(force: false));
    }
  }

  @override
  void onActivityRouteBecameInactive() {
    _liveRefreshPoller?.stop();
    _cancelOwnedRefresh();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(assetsControllerProvider).state;
    final controller = ref.read(assetsControllerProvider);
    final document = state.document;
    return V3PageScaffold(
      title: '个人资产',
      centerTitle: true,
      scrollController: _scrollController,
      showScrollbar: true,
      trailing: IconButton(
        tooltip: '资产操作',
        icon: const Icon(Icons.more_horiz_rounded),
        onPressed: () async {
          final action = await showV3ActionSheet<_AssetMenuAction>(
            context: context,
            title: '资产操作',
            items: <V3ActionSheetItem<_AssetMenuAction>>[
              V3ActionSheetItem(
                value: _AssetMenuAction.sync,
                icon: Icons.sync_rounded,
                label: '同步资产',
                enabled: !state.isSyncing,
              ),
              V3ActionSheetItem(
                value: _AssetMenuAction.refresh,
                icon: Icons.refresh_rounded,
                label: '刷新资产',
                enabled: !state.isLoading,
              ),
            ],
          );
          if (action != null && context.mounted) {
            _handleMenuAction(context, controller, action);
          }
        },
      ),
      children: [
        if (document != null) ...[
          _OverviewCard(document: document),
          const SizedBox(height: 12),
          if (document.stale ||
              document.syncStatus == AssetSyncStatus.syncFailed)
            _SyncStatusCard(
              document: document,
              syncing: state.isSyncing,
              onSync: document.retryable && !state.isSyncing
                  ? () => _sync(context, controller)
                  : null,
            ),
          if (document.stale ||
              document.syncStatus == AssetSyncStatus.syncFailed)
            const SizedBox(height: 12),
          if (document.anchors.isNotEmpty) ...[
            _AnchorStrip(anchors: document.anchors, onTap: _scrollToAnchor),
            const SizedBox(height: 12),
          ],
          _SafeMarkdownDocument(document: document, anchorKeys: _anchorKeys),
          if (document.links.isNotEmpty) ...[
            const SizedBox(height: 12),
            _AssetLinksCard(
              links: document.links,
              onTap: (link) => _openLink(context, link),
            ),
          ],
          if (document.contentLines.isNotEmpty) ...[
            const SizedBox(height: 12),
            _ContentLinesCard(
              lines: document.contentLines,
              onTap: (line) => context.push(
                '/v3/assets/content-line/${Uri.encodeComponent(line.contentLineId)}',
              ),
            ),
          ],
          const SizedBox(height: 24),
        ] else if (state.isLoading) ...[
          const SizedBox(height: 72),
          const Center(child: CircularProgressIndicator()),
        ] else ...[
          _AssetsFailure(
            code: state.errorCode,
            onRetry: () =>
                unawaited(_reloadAssets(force: true, invalidateCache: true)),
          ),
        ],
        if (document != null && state.errorCode != null) ...[
          const SizedBox(height: 12),
          _InlineError(code: state.errorCode!),
        ],
      ],
    );
  }

  Future<void> _sync(BuildContext context, AssetsController controller) async {
    if (!_requestOwner.isActive) _requestOwner = AssetsRequestOwner();
    _syncController = controller;
    try {
      final task = await controller.sync(requestOwner: _requestOwner);
      if (!context.mounted || task == null) return;
      showV3Snack(context, '资产同步任务 ${task.status}');
    } finally {
      if (identical(_syncController, controller)) _syncController = null;
    }
  }

  void _configureLiveRefresh(bool hasLiveWork) {
    _hasLiveAssetWork = hasLiveWork;
    if (hasLiveWork) {
      _startLiveRefresh();
    } else {
      _liveRefreshPoller?.stop();
    }
  }

  void _startLiveRefresh({bool immediate = false}) {
    if (!activityRouteCanRun) return;
    _liveRefreshPoller ??= OrchestratedPoller(
      orchestrator: ref.read(taskOrchestratorProvider),
      // performance-rfc: unified-network-pollers
      spec: TaskSpec(
        key: 'assets.live-refresh.account',
        owner: 'assets.live-refresh',
        priority: TaskPriority.foregroundDeferred,
        resources: const <TaskResource>{TaskResource.network},
        foregroundOnly: true,
        replaceExisting: true,
        retryable: true,
        deadline: const Duration(seconds: 15),
      ),
      interval: const Duration(seconds: 10),
      maxBackoff: const Duration(seconds: 30),
      activityMetrics: ref.read(runtimeActivityMetricsProvider),
      poll: (_) async {
        if (!mounted || !_hasLiveAssetWork || !activityRouteCanRun) {
          return false;
        }
        await _reloadAssets(force: true);
        return mounted && _hasLiveAssetWork && activityRouteCanRun;
      },
    );
    _liveRefreshPoller!.start(immediate: immediate);
  }

  Future<void> _reloadAssets({
    required bool force,
    bool invalidateCache = false,
  }) async {
    if (!activityRouteCanRun) return;
    if (_liveRefreshInFlight) {
      _queuedRefresh = true;
      _queuedRefreshForce = _queuedRefreshForce || force;
      _queuedRefreshInvalidatesCache =
          _queuedRefreshInvalidatesCache || invalidateCache;
      if (force || invalidateCache) {
        _liveRefreshController?.supersedePendingLoads(owner: _requestOwner);
      }
      return;
    }
    _liveRefreshInFlight = true;
    final controller = ref.read(assetsControllerProvider);
    _liveRefreshController = controller;
    try {
      await controller.load(
        focus: widget.focus,
        force: force,
        invalidateCache: invalidateCache,
        requestOwner: _requestOwner,
      );
    } finally {
      _liveRefreshInFlight = false;
      _liveRefreshController = null;
      if (mounted && _queuedRefresh) {
        final queuedForce = _queuedRefreshForce;
        final queuedInvalidatesCache = _queuedRefreshInvalidatesCache;
        _queuedRefresh = false;
        _queuedRefreshForce = false;
        _queuedRefreshInvalidatesCache = false;
        unawaited(
          _reloadAssets(
            force: queuedForce,
            invalidateCache: queuedInvalidatesCache,
          ),
        );
      }
    }
  }

  void _cancelOwnedRefresh() {
    final owner = _requestOwner;
    owner.deactivate();
    _queuedRefresh = false;
    _queuedRefreshForce = false;
    _queuedRefreshInvalidatesCache = false;
    _liveRefreshController?.cancelPendingLoadsForOwner(owner);
    _syncController?.cancelPendingLoadsForOwner(owner);
  }

  void _handleMenuAction(
    BuildContext context,
    AssetsController controller,
    _AssetMenuAction action,
  ) {
    switch (action) {
      case _AssetMenuAction.sync:
        _sync(context, controller);
        return;
      case _AssetMenuAction.refresh:
        unawaited(_reloadAssets(force: true, invalidateCache: true));
        return;
    }
  }

  void _scrollToAnchor(String anchorId) {
    final anchor = _anchorKeys[anchorId]?.currentContext;
    if (anchor == null) return;
    Scrollable.ensureVisible(
      anchor,
      duration: V3MotionTokens.emphasized,
      curve: Curves.easeOutCubic,
    );
  }

  void _openLink(BuildContext context, AssetMarkdownLink link) {
    switch (link.target.type) {
      case AssetMarkdownLinkTargetType.markdownAnchor:
        final anchorId = link.target.anchorId;
        if (anchorId != null) _scrollToAnchor(anchorId);
        return;
      case AssetMarkdownLinkTargetType.recordingDetail:
        final recordingId = link.target.recordingId;
        if (recordingId != null) {
          context.push(
            '/v3/feed/transcription-done/${Uri.encodeComponent(recordingId)}',
          );
        }
        return;
      case AssetMarkdownLinkTargetType.contentLineDetail:
        final contentLineId = link.target.contentLineId;
        if (contentLineId != null) {
          context.push(
            '/v3/assets/content-line/${Uri.encodeComponent(contentLineId)}',
          );
        }
        return;
      case AssetMarkdownLinkTargetType.assetPage:
        final focus = link.target.focus;
        final query = focus == null ? '' : '?focus=${_focusWire(focus)}';
        context.push('/v3/assets$query');
        return;
    }
  }
}

class V3StructuredAssetDetailPage extends ConsumerStatefulWidget {
  const V3StructuredAssetDetailPage({
    required this.assetType,
    required this.assetId,
    super.key,
  });

  final EditableAssetType assetType;
  final String assetId;

  @override
  ConsumerState<V3StructuredAssetDetailPage> createState() =>
      _V3StructuredAssetDetailPageState();
}

class _V3StructuredAssetDetailPageState
    extends ConsumerState<V3StructuredAssetDetailPage> {
  final _scrollController = ScrollController();
  late Future<ApiResult<StructuredAssetDetail>> _request;

  @override
  void initState() {
    super.initState();
    _request = _load();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<ApiResult<StructuredAssetDetail>> _load() {
    return ref
        .read(assetsControllerProvider)
        .loadDetail(assetType: widget.assetType, assetId: widget.assetId);
  }

  Future<void> _edit(StructuredAssetDetail detail) async {
    final updated = await showV3GlassBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => _StructuredAssetEditSheet(
        detail: detail,
        onSave: (patch) => ref
            .read(assetsControllerProvider)
            .patchDetail(detail: detail, patch: patch),
      ),
    );
    if (!mounted || updated != true) return;
    final assets = ref.read(assetsControllerProvider);
    assets.invalidateCachedDocuments();
    unawaited(assets.load(force: true));
    setState(() {
      _request = _load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final fallbackRoute = widget.assetType == EditableAssetType.viewpoint
        ? '/v3/feed'
        : '/v3/assets';
    return V3PageScaffold(
      title: '资产详情',
      centerTitle: true,
      fallbackRoute: fallbackRoute,
      backBehavior: V3BackBehavior.fallbackOnly,
      scrollController: _scrollController,
      showScrollbar: true,
      trailing: IconButton(
        tooltip: '刷新资产详情',
        onPressed: () => setState(() {
          _request = _load();
        }),
        icon: const Icon(Icons.refresh_rounded),
      ),
      children: [
        FutureBuilder<ApiResult<StructuredAssetDetail>>(
          future: _request,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Padding(
                padding: EdgeInsets.only(top: 72),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            final result = snapshot.data;
            final detail = result?.data;
            if (result == null || !result.ok || detail == null) {
              return _AssetsFailure(
                code: result?.error?.code,
                onRetry: () => setState(() {
                  _request = _load();
                }),
              );
            }
            return _StructuredAssetBody(
              detail: detail,
              onEdit: detail.editable ? () => _edit(detail) : null,
            );
          },
        ),
      ],
    );
  }
}

class _OverviewCard extends StatelessWidget {
  const _OverviewCard({required this.document});

  final PersonalAssetMarkdown document;

  @override
  Widget build(BuildContext context) {
    final overview = document.overview;
    return V3Card(
      radius: 16,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            document.title,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _Metric(label: '录音', value: overview.recordingCount),
              ),
              Expanded(
                child: _Metric(
                  label: '转写字数',
                  value: overview.transcriptWordCount,
                ),
              ),
              Expanded(
                child: _Metric(label: '内容线', value: overview.contentLineCount),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});

  final String label;
  final int value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$value',
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 3),
        Text(
          label,
          style: TextStyle(
            color: HuahuoV3Theme.tokensOf(context).muted,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class _SyncStatusCard extends StatelessWidget {
  const _SyncStatusCard({
    required this.document,
    required this.syncing,
    required this.onSync,
  });

  final PersonalAssetMarkdown document;
  final bool syncing;
  final VoidCallback? onSync;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final failed = document.syncStatus == AssetSyncStatus.syncFailed;
    return Material(
      color: HuahuoV3Theme.semanticSurface(
        failed ? colors.danger : colors.success,
        colors.surface,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: failed ? colors.danger.withValues(alpha: .7) : colors.line,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 9, 7, 9),
        child: Row(
          children: [
            Icon(
              failed ? Icons.cloud_off_outlined : Icons.sync_outlined,
              size: 19,
              color: failed ? colors.danger : colors.success,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                failed ? '资产同步未完成，当前显示上次可用内容' : '资产正在由服务端同步',
                style: TextStyle(color: colors.text, fontSize: 13.5),
              ),
            ),
            IconButton(
              tooltip: '重新同步资产',
              onPressed: onSync,
              icon: syncing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.sync, size: 20),
            ),
          ],
        ),
      ),
    );
  }
}

class _AnchorStrip extends StatelessWidget {
  const _AnchorStrip({required this.anchors, required this.onTap});

  final List<AssetMarkdownAnchor> anchors;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final anchor in anchors) ...[
            ActionChip(
              label: Text(anchor.title),
              onPressed: () => onTap(anchor.anchorId),
            ),
            const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }
}

class _SafeMarkdownDocument extends StatelessWidget {
  const _SafeMarkdownDocument({
    required this.document,
    required this.anchorKeys,
  });

  final PersonalAssetMarkdown document;
  final Map<String, GlobalKey> anchorKeys;

  @override
  Widget build(BuildContext context) {
    final anchorsByTitle = <String, String>{
      for (final anchor in document.anchors) anchor.title: anchor.anchorId,
    };
    final lines = document.markdown.split('\n');
    return V3Card(
      radius: 16,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final rawLine in lines)
            if (rawLine.trim().isNotEmpty)
              _MarkdownLine(
                line: rawLine,
                anchorKey: _anchorKeyFor(rawLine, anchorsByTitle),
              ),
        ],
      ),
    );
  }

  GlobalKey? _anchorKeyFor(String line, Map<String, String> anchorsByTitle) {
    final trimmed = line.trimLeft();
    if (!trimmed.startsWith('#')) return null;
    final heading = trimmed.replaceFirst(RegExp(r'^#{1,3}\s+'), '').trim();
    final anchorId = anchorsByTitle[heading];
    return anchorId == null
        ? null
        : anchorKeys.putIfAbsent(anchorId, GlobalKey.new);
  }
}

class _MarkdownLine extends StatelessWidget {
  const _MarkdownLine({required this.line, this.anchorKey});

  final String line;
  final GlobalKey? anchorKey;

  @override
  Widget build(BuildContext context) {
    final trimmed = line.trim();
    final heading = RegExp(r'^(#{1,3})\s+(.+)$').firstMatch(trimmed);
    final bullet = RegExp(r'^([-*]|\d+\.)\s+(.+)$').firstMatch(trimmed);
    final isQuote = trimmed.startsWith('> ');
    final text =
        heading?.group(2) ??
        bullet?.group(2) ??
        (isQuote ? trimmed.substring(2) : trimmed);
    final fontSize = switch (heading?.group(1)?.length) {
      1 => 22.0,
      2 => 19.0,
      3 => 17.0,
      _ => 15.0,
    };
    final weight = heading == null ? FontWeight.w500 : FontWeight.w800;
    return Padding(
      key: anchorKey,
      padding: EdgeInsets.only(
        top: heading == null ? 0 : 8,
        bottom: heading == null ? 9 : 10,
        left: bullet == null ? (isQuote ? 10 : 0) : 14,
      ),
      child: Text(
        bullet == null ? text : '• $text',
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: weight,
          height: 1.45,
          color: isQuote
              ? HuahuoV3Theme.tokensOf(context).muted
              : HuahuoV3Theme.tokensOf(context).text,
        ),
      ),
    );
  }
}

class _AssetLinksCard extends StatelessWidget {
  const _AssetLinksCard({required this.links, required this.onTap});

  final List<AssetMarkdownLink> links;
  final ValueChanged<AssetMarkdownLink> onTap;

  @override
  Widget build(BuildContext context) {
    return V3Card(
      radius: 16,
      padding: const EdgeInsets.fromLTRB(16, 13, 10, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '关联内容',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 5),
          for (final link in links)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(link.label),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => onTap(link),
            ),
        ],
      ),
    );
  }
}

class _ContentLinesCard extends StatelessWidget {
  const _ContentLinesCard({required this.lines, required this.onTap});

  final List<AssetContentLineBrief> lines;
  final ValueChanged<AssetContentLineBrief> onTap;

  @override
  Widget build(BuildContext context) {
    return V3Card(
      radius: 16,
      padding: const EdgeInsets.fromLTRB(16, 13, 10, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '内容线',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 5),
          for (final line in lines)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(line.name),
              subtitle: line.industry == null ? null : Text(line.industry!),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => onTap(line),
            ),
        ],
      ),
    );
  }
}

class _StructuredAssetBody extends StatelessWidget {
  const _StructuredAssetBody({required this.detail, this.onEdit});

  final StructuredAssetDetail detail;
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        V3Card(
          radius: 16,
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (onEdit != null) ...[
                Align(
                  alignment: Alignment.centerRight,
                  child: IconButton(
                    tooltip: '编辑资产',
                    onPressed: onEdit,
                    icon: const Icon(Icons.edit_outlined),
                  ),
                ),
              ],
              for (final entry in detail.asset.entries) ...[
                Text(
                  _labelForField(entry.key),
                  style: TextStyle(
                    fontSize: 12,
                    color: HuahuoV3Theme.tokensOf(context).muted,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _formatAssetField(entry.value),
                  style: const TextStyle(fontSize: 16, height: 1.4),
                ),
                const SizedBox(height: 14),
              ],
            ],
          ),
        ),
        if (detail.sourceReferences.isNotEmpty) ...[
          const SizedBox(height: 12),
          V3Card(
            radius: 16,
            padding: const EdgeInsets.fromLTRB(16, 13, 10, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '来源',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 5),
                for (final source in detail.sourceReferences)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(source.title ?? source.sourceType),
                    subtitle: Text(source.sourceType),
                    trailing:
                        source.sourceType == 'recording' &&
                            source.sourceId != null
                        ? const Icon(Icons.chevron_right_rounded)
                        : null,
                    onTap:
                        source.sourceType == 'recording' &&
                            source.sourceId != null
                        ? () => context.push(
                            '/v3/feed/transcription-done/${Uri.encodeComponent(source.sourceId!)}',
                          )
                        : null,
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _StructuredAssetEditSheet extends StatefulWidget {
  const _StructuredAssetEditSheet({required this.detail, required this.onSave});

  final StructuredAssetDetail detail;
  final Future<ApiResult<AssetPatchResult>> Function(EditableAssetPatch patch)
  onSave;

  @override
  State<_StructuredAssetEditSheet> createState() =>
      _StructuredAssetEditSheetState();
}

class _StructuredAssetEditSheetState extends State<_StructuredAssetEditSheet> {
  late final List<String> _fields;
  late final Map<String, TextEditingController> _controllers;
  bool _submitting = false;
  String? _errorCode;

  @override
  void initState() {
    super.initState();
    _fields = editableAssetFieldKeys(widget.detail.assetType);
    _controllers = <String, TextEditingController>{
      for (final field in _fields)
        field: TextEditingController(
          text: _editableAssetFieldText(widget.detail.asset[field]),
        ),
    };
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    final patch = buildEditableAssetPatch(
      widget.detail.assetType,
      <String, Object?>{
        for (final entry in _controllers.entries) entry.key: entry.value.text,
      },
    );
    if (patch == null) {
      setState(() => _errorCode = 'ASSET_PATCH_EMPTY');
      return;
    }

    setState(() {
      _submitting = true;
      _errorCode = null;
    });
    final result = await widget.onSave(patch);
    if (!mounted) return;
    final saved = result.data;
    if (!result.ok ||
        saved == null ||
        saved.assetType != widget.detail.assetType ||
        saved.assetId != widget.detail.assetId) {
      setState(() {
        _submitting = false;
        _errorCode = result.error?.code ?? 'ASSET_PATCH_RESPONSE_INVALID';
      });
      return;
    }
    Navigator.of(context).pop(true);
  }

  Widget _buildField(int index) {
    final field = _fields[index];
    final multiline = _isLongAssetField(field);
    return TextField(
      controller: _controllers[field],
      contextMenuBuilder: V3TextEditing.buildContextMenu,
      enabled: !_submitting,
      minLines: multiline ? 3 : 1,
      maxLines: multiline ? 5 : 1,
      textInputAction: index + 1 == _fields.length || multiline
          ? TextInputAction.done
          : TextInputAction.next,
      decoration: InputDecoration(
        labelText: _labelForField(field),
        hintText: multiline ? '填写结构化字段' : null,
        border: const OutlineInputBorder(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final bottomInset = mediaQuery.viewInsets.bottom;
    final keyboardVisible = bottomInset > 0;
    const glassSheetHandleExtent = 20.0;
    final availableHeight =
        (mediaQuery.size.height -
                bottomInset -
                mediaQuery.viewPadding.top -
                mediaQuery.padding.bottom -
                glassSheetHandleExtent)
            .clamp(0.0, mediaQuery.size.height)
            .toDouble();
    final portraitHeight = mediaQuery.size.height * .76;
    final sheetHeight = keyboardVisible
        ? availableHeight
        : portraitHeight.clamp(0.0, availableHeight).toDouble();
    return AnimatedPadding(
      padding: EdgeInsets.only(bottom: bottomInset),
      duration: V3MotionTokens.resolve(context, V3MotionTokens.standard),
      curve: Curves.easeOutCubic,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: sheetHeight),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: ListView(
                    key: const ValueKey('structured-asset-edit-scroll'),
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.onDrag,
                    padding: EdgeInsets.zero,
                    children: [
                      const Text(
                        '编辑资产',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '版本 ${widget.detail.baseVersion}',
                        style: TextStyle(
                          color: HuahuoV3Theme.tokensOf(context).muted,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: 14),
                      for (var index = 0; index < _fields.length; index++) ...[
                        if (index > 0) const SizedBox(height: 12),
                        _buildField(index),
                      ],
                      if (_errorCode != null) ...[
                        const SizedBox(height: 10),
                        Text(
                          _errorCode == 'WORKSPACE_VERSION_CONFLICT'
                              ? '资产已被更新，请关闭后刷新详情再编辑。'
                              : '保存失败：$_errorCode',
                          style: TextStyle(
                            color: HuahuoV3Theme.tokensOf(context).danger,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _submitting ? null : _submit,
                    icon: _submitting
                        ? SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: HuahuoV3Theme.tokensOf(context).onPrimary,
                            ),
                          )
                        : const Icon(Icons.save_outlined),
                    label: const Text('保存'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AssetsFailure extends StatelessWidget {
  const _AssetsFailure({required this.code, required this.onRetry});

  final String? code;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 72),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_outlined, size: 34),
            const SizedBox(height: 10),
            Text('资产暂时不可用${code == null ? '' : ' ($code)'}'),
            const SizedBox(height: 10),
            IconButton(
              tooltip: '重试',
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
      ),
    );
  }
}

class _InlineError extends StatelessWidget {
  const _InlineError({required this.code});

  final String code;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Text(
      '刷新失败：$code',
      style: TextStyle(color: colors.danger, fontSize: 13),
    );
  }
}

String _focusWire(AssetMarkdownFocus focus) => switch (focus) {
  AssetMarkdownFocus.overview => 'overview',
  AssetMarkdownFocus.contentLine => 'content_line',
  AssetMarkdownFocus.recording => 'recording',
  AssetMarkdownFocus.profile => 'profile',
};

String _labelForField(String key) {
  return key
      .replaceAllMapped(
        RegExp(r'([a-z0-9])([A-Z])'),
        (match) => '${match.group(1)} ${match.group(2)}',
      )
      .replaceAll('_', ' ');
}

String _formatAssetField(Object? value) {
  return switch (value) {
    null => '-',
    List<String> values => values.join('、'),
    _ => '$value',
  };
}

String _editableAssetFieldText(Object? value) {
  return switch (value) {
    String text => text,
    List<String> values => values.join(', '),
    _ => '',
  };
}

bool _isLongAssetField(String field) => <String>{
  'identitySummary',
  'personalitySummary',
  'contentStyleSummary',
  'positioning',
  'targetAudience',
  'accountGoal',
  'fullTitle',
  'summary',
  'content',
  'usageContext',
}.contains(field);
