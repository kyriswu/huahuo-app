import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app/navigation/app_route_paths.dart';
import '../../../shared/theme/huahuo_v3_theme.dart';
import '../../../shared/ui_v3/v3_components.dart';
import '../../../shared/ui_v3/v3_long_running_task_notice.dart';
import '../../../shared/ui_v3/v3_glass_foundations.dart';
import '../../recordings/application/recording_batch_transcription_controller.dart';
import '../../recordings/application/recording_upload_controller.dart';
import '../../recordings/domain/recording_batch_transcription.dart';

class V3BatchTranscriptionPage extends StatefulWidget {
  const V3BatchTranscriptionPage({
    required this.batchId,
    required this.controller,
    this.focusItemId,
    this.uploadController,
    super.key,
  });

  final String batchId;
  final String? focusItemId;
  final RecordingBatchTranscriptionController controller;
  final RecordingUploadController? uploadController;

  @override
  State<V3BatchTranscriptionPage> createState() =>
      _V3BatchTranscriptionPageState();
}

class _V3BatchTranscriptionPageState extends State<V3BatchTranscriptionPage> {
  final _scrollController = ScrollController();
  final Map<String, GlobalKey> _itemKeys = <String, GlobalKey>{};
  String? _focusedOnce;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge(<Listenable>[
        widget.controller,
        if (widget.uploadController != null) widget.uploadController!,
      ]),
      builder: (context, child) {
        final batch = widget.controller.state.batchFor(widget.batchId);
        if (batch == null) return _buildMissingBatch();
        _scheduleFocus(batch);
        return _buildBatch(batch);
      },
    );
  }

  Widget _buildMissingBatch() {
    final colors = HuahuoV3Theme.tokensOf(context);
    return V3PageScaffold(
      title: '批量转写',
      centerTitle: true,
      fallbackRoute: '/v3/notifications',
      scrollController: _scrollController,
      showScrollbar: true,
      children: [
        const SizedBox(height: 80),
        Icon(Icons.find_in_page_outlined, size: 42, color: colors.muted),
        const SizedBox(height: 16),
        const Text(
          '未找到这组转写任务',
          key: ValueKey('transcription-batch-not-found'),
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        Text(
          '任务可能属于其他账号，或本地记录已不可用。',
          textAlign: TextAlign.center,
          style: TextStyle(color: colors.muted),
        ),
      ],
    );
  }

  Widget _buildBatch(RecordingBatchTranscriptionSnapshot batch) {
    final counts = batch.counts;
    final settled = counts.settled;
    final fraction = counts.total == 0 ? 0.0 : settled / counts.total;
    final primary = batch.primaryItem;
    return V3PageScaffold(
      title: batch.status == RecordingBatchTranscriptionStatus.active
          ? '批量转写'
          : '批量转写结果',
      centerTitle: true,
      fallbackRoute: '/v3/notifications',
      scrollController: _scrollController,
      showScrollbar: true,
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 30),
      children: [
        _BatchSummaryCard(batch: batch, settled: settled, fraction: fraction),
        if (batch.status == RecordingBatchTranscriptionStatus.active) ...[
          const SizedBox(height: 12),
          const V3LongRunningTaskNotice(fallbackRoute: '/v3/notifications'),
        ],
        if (primary?.hasAccessibleAsset == true) ...[
          const SizedBox(height: 12),
          _PrimaryResultCard(
            item: primary!,
            batchActive:
                batch.status == RecordingBatchTranscriptionStatus.active,
            onOpen: () => _openResult(primary),
          ),
        ],
        const SizedBox(height: 22),
        const V3SectionTitle('录音文件'),
        V3GroupedList(
          key: const ValueKey('transcription-batch-item-list'),
          variant: V3CardVariant.flat,
          radius: 0,
          dividerIndent: 60,
          children: [
            for (final item in batch.items)
              _BatchTranscriptionItemRow(
                key: _keyForItem(item.itemId),
                item: item,
                primary: item.itemId == batch.primaryItemId,
                focused: item.itemId == widget.focusItemId,
                uploadProgress: _objectUploadProgressFor(item),
                onRetry:
                    item.status ==
                            RecordingBatchTranscriptionItemStatus.timedOut ||
                        (item.status ==
                                RecordingBatchTranscriptionItemStatus.failed &&
                            item.retryable)
                    ? () => unawaited(_retryItem(item))
                    : null,
                onOpenResult: item.hasAccessibleAsset
                    ? () => _openResult(item)
                    : null,
              ),
          ],
        ),
      ],
    );
  }

  GlobalKey _keyForItem(String itemId) =>
      _itemKeys.putIfAbsent(itemId, GlobalKey.new);

  RecordingObjectUploadProgress? _objectUploadProgressFor(
    RecordingBatchTranscriptionItem item,
  ) {
    final usesObjectUploadProgress =
        item.status == RecordingBatchTranscriptionItemStatus.submitting ||
        (item.status == RecordingBatchTranscriptionItemStatus.processing &&
            item.phase == RecordingBatchTranscriptionPhase.uploading);
    if (!usesObjectUploadProgress) return null;
    return widget.uploadController?.state.progressForDraft(item.jobId);
  }

  void _scheduleFocus(RecordingBatchTranscriptionSnapshot batch) {
    final itemId = widget.focusItemId?.trim();
    if (itemId == null ||
        itemId.isEmpty ||
        _focusedOnce == itemId ||
        batch.itemFor(itemId) == null) {
      return;
    }
    _focusedOnce = itemId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final itemContext = _itemKeys[itemId]?.currentContext;
      if (!mounted || itemContext == null) return;
      Scrollable.ensureVisible(
        itemContext,
        alignment: .18,
        duration: V3MotionTokens.pageTravel,
        curve: Curves.easeOutCubic,
      );
    });
  }

  Future<void> _retryItem(RecordingBatchTranscriptionItem item) async {
    final accepted = await widget.controller.retryItem(
      batchId: widget.batchId,
      itemId: item.itemId,
    );
    if (!mounted) return;
    showV3Snack(context, accepted ? '已重新开始处理' : '当前状态无法重试');
  }

  void _openResult(RecordingBatchTranscriptionItem item) {
    final noteId = item.noteId?.trim();
    if (noteId == null || noteId.isEmpty) return;
    context.push(AppRoutePaths.feedItem(noteId));
  }
}

class _BatchSummaryCard extends StatelessWidget {
  const _BatchSummaryCard({
    required this.batch,
    required this.settled,
    required this.fraction,
  });

  final RecordingBatchTranscriptionSnapshot batch;
  final int settled;
  final double fraction;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final counts = batch.counts;
    final statusText = switch (batch.status) {
      RecordingBatchTranscriptionStatus.active =>
        counts.completed == 0
            ? '${counts.total} 个录音文件正在转写'
            : '${counts.completed} 个已完成，${counts.active} 个处理中',
      RecordingBatchTranscriptionStatus.completed => '全部录音已完成转写',
      RecordingBatchTranscriptionStatus.completedWithIssues =>
        '${counts.completed} 个完成，${counts.failed + counts.timedOut} 个需要处理',
    };
    return V3Card(
      key: const ValueKey('transcription-batch-summary'),
      variant: V3CardVariant.outlined,
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  statusText,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Text(
                '$settled/${counts.total}',
                key: const ValueKey('transcription-batch-count'),
                style: TextStyle(
                  color: colors.primary,
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          LinearProgressIndicator(
            key: const ValueKey('transcription-batch-progress'),
            value: fraction.clamp(0, 1),
            minHeight: 6,
            borderRadius: BorderRadius.circular(3),
            color: colors.primary,
            backgroundColor: colors.line,
          ),
        ],
      ),
    );
  }
}

class _PrimaryResultCard extends StatelessWidget {
  const _PrimaryResultCard({
    required this.item,
    required this.batchActive,
    required this.onOpen,
  });

  final RecordingBatchTranscriptionItem item;
  final bool batchActive;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return V3Card(
      key: const ValueKey('transcription-batch-primary-result'),
      variant: V3CardVariant.outlined,
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
      child: Row(
        children: [
          Icon(Icons.description_outlined, color: colors.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '首项结果已生成',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Text(
                  batchActive ? '其他录音仍在后台处理' : item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: colors.muted, fontSize: 12),
                ),
              ],
            ),
          ),
          TextButton(
            key: const ValueKey('transcription-batch-open-primary-result'),
            onPressed: onOpen,
            child: const Text('查看结果'),
          ),
        ],
      ),
    );
  }
}

class _BatchTranscriptionItemRow extends StatelessWidget {
  const _BatchTranscriptionItemRow({
    required this.item,
    required this.primary,
    required this.focused,
    required this.uploadProgress,
    required this.onRetry,
    required this.onOpenResult,
    super.key,
  });

  final RecordingBatchTranscriptionItem item;
  final bool primary;
  final bool focused;
  final RecordingObjectUploadProgress? uploadProgress;
  final VoidCallback? onRetry;
  final VoidCallback? onOpenResult;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final statusColor = _itemStatusColor(item, colors);
    return Container(
      key: ValueKey('transcription-batch-item-${item.itemId}'),
      color: focused
          ? HuahuoV3Theme.semanticSurface(colors.primary, colors.surface)
          : Colors.transparent,
      padding: const EdgeInsets.all(15),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 34,
                height: 34,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: .12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  _itemStatusIcon(item),
                  size: 19,
                  color: statusColor,
                ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            item.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                        if (primary) ...[
                          const SizedBox(width: 8),
                          Text(
                            '首项',
                            style: TextStyle(
                              color: colors.primary,
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      _itemStatusLabel(item),
                      key: ValueKey(
                        'transcription-batch-item-status-${item.itemId}',
                      ),
                      style: TextStyle(
                        color: statusColor,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (uploadProgress != null && uploadProgress!.totalBytes > 0) ...[
            const SizedBox(height: 12),
            LinearProgressIndicator(
              key: ValueKey(
                'transcription-batch-item-upload-progress-${item.itemId}',
              ),
              value: (uploadProgress!.bytesSent / uploadProgress!.totalBytes)
                  .clamp(0.0, 1.0)
                  .toDouble(),
              minHeight: 4,
              borderRadius: BorderRadius.circular(2),
              color: colors.primary,
              backgroundColor: colors.line,
            ),
            const SizedBox(height: 7),
            Text(
              _objectUploadProgressLabel(uploadProgress!),
              key: ValueKey(
                'transcription-batch-item-upload-details-${item.itemId}',
              ),
              style: TextStyle(color: colors.muted, fontSize: 12),
            ),
          ] else if (item.status.isActive && item.progress != null) ...[
            const SizedBox(height: 12),
            LinearProgressIndicator(
              value: item.progress! / 100,
              minHeight: 4,
              borderRadius: BorderRadius.circular(2),
              color: colors.primary,
              backgroundColor: colors.line,
            ),
          ],
          if (item.waitingReason != null) ...[
            const SizedBox(height: 8),
            Text(
              _waitingReasonLabel(item.waitingReason!),
              style: TextStyle(color: colors.muted, fontSize: 12),
            ),
          ],
          if (item.status == RecordingBatchTranscriptionItemStatus.failed ||
              item.status ==
                  RecordingBatchTranscriptionItemStatus.timedOut) ...[
            const SizedBox(height: 8),
            Text(
              _itemFailureSummary(item),
              key: ValueKey('transcription-batch-item-error-${item.itemId}'),
              style: TextStyle(color: colors.muted, fontSize: 12),
            ),
          ],
          if (item.outlineStatus != RecordingBatchOutlineStatus.notStarted) ...[
            const SizedBox(height: 8),
            Text(
              _outlineStatusLabel(item.outlineStatus),
              style: TextStyle(color: colors.muted, fontSize: 12),
            ),
          ],
          if (onRetry != null || onOpenResult != null) ...[
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (onRetry != null)
                  TextButton.icon(
                    key: ValueKey(
                      'transcription-batch-item-retry-${item.itemId}',
                    ),
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh_rounded, size: 17),
                    label: Text(
                      item.status ==
                              RecordingBatchTranscriptionItemStatus.timedOut
                          ? '继续观察'
                          : '重试',
                    ),
                  ),
                if (onOpenResult != null)
                  TextButton.icon(
                    key: ValueKey(
                      'transcription-batch-item-result-${item.itemId}',
                    ),
                    onPressed: onOpenResult,
                    icon: const Icon(Icons.open_in_new_rounded, size: 17),
                    label: const Text('查看结果'),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

String _objectUploadProgressLabel(RecordingObjectUploadProgress progress) {
  final rate = progress.bytesPerSecond > 0
      ? '${_formatUploadBytes(progress.bytesPerSecond.round())}/s'
      : '--/s';
  final eta = progress.estimatedRemainingSeconds == null
      ? '--'
      : _formatUploadEta(progress.estimatedRemainingSeconds!);
  return '${_formatUploadBytes(progress.bytesSent)} / '
      '${_formatUploadBytes(progress.totalBytes)} · $rate · 剩余 $eta';
}

String _formatUploadBytes(int bytes) {
  const units = <String>['B', 'KB', 'MB', 'GB'];
  var value = bytes < 0 ? 0.0 : bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit += 1;
  }
  final precision = unit == 0 || value >= 100 ? 0 : 1;
  return '${value.toStringAsFixed(precision)} ${units[unit]}';
}

String _formatUploadEta(int seconds) {
  final safeSeconds = seconds < 0 ? 0 : seconds;
  if (safeSeconds < 60) return '${safeSeconds}s';
  final minutes = safeSeconds ~/ 60;
  final remainingSeconds = safeSeconds % 60;
  if (minutes < 60) return '${minutes}m ${remainingSeconds}s';
  return '${minutes ~/ 60}h ${minutes % 60}m';
}

String _itemStatusLabel(RecordingBatchTranscriptionItem item) {
  return switch (item.status) {
    RecordingBatchTranscriptionItemStatus.pending =>
      switch (item.waitingReason) {
        RecordingBatchWaitingReason.networkRequired => '等待网络',
        RecordingBatchWaitingReason.remoteVerificationRequired => '等待核验已有任务',
        RecordingBatchWaitingReason.accountScopeChanged => '等待返回当前账号',
        null => '等待处理',
      },
    RecordingBatchTranscriptionItemStatus.submitting => '正在上传',
    RecordingBatchTranscriptionItemStatus.processing => switch (item.phase) {
      RecordingBatchTranscriptionPhase.uploading => '正在上传',
      RecordingBatchTranscriptionPhase.transcribing => '正在转写',
      RecordingBatchTranscriptionPhase.storingAsset => '正在生成资产',
      RecordingBatchTranscriptionPhase.assetReady => '资产已生成',
      null => '正在处理',
    },
    RecordingBatchTranscriptionItemStatus.completed => '已完成',
    RecordingBatchTranscriptionItemStatus.failed =>
      item.isUnavailable ? '文件不可用' : '处理失败',
    RecordingBatchTranscriptionItemStatus.timedOut => '等待超时，需要关注',
    RecordingBatchTranscriptionItemStatus.skipped => '已转写，已跳过',
  };
}

IconData _itemStatusIcon(RecordingBatchTranscriptionItem item) {
  return switch (item.status) {
    RecordingBatchTranscriptionItemStatus.pending => Icons.schedule_rounded,
    RecordingBatchTranscriptionItemStatus.submitting =>
      Icons.cloud_upload_outlined,
    RecordingBatchTranscriptionItemStatus.processing =>
      Icons.graphic_eq_rounded,
    RecordingBatchTranscriptionItemStatus.completed => Icons.check_rounded,
    RecordingBatchTranscriptionItemStatus.failed => Icons.error_outline_rounded,
    RecordingBatchTranscriptionItemStatus.timedOut => Icons.timer_off_outlined,
    RecordingBatchTranscriptionItemStatus.skipped => Icons.done_all_rounded,
  };
}

Color _itemStatusColor(
  RecordingBatchTranscriptionItem item,
  HuahuoV3ThemeTokens colors,
) {
  return switch (item.status) {
    RecordingBatchTranscriptionItemStatus.completed ||
    RecordingBatchTranscriptionItemStatus.skipped => colors.success,
    RecordingBatchTranscriptionItemStatus.failed => colors.danger,
    RecordingBatchTranscriptionItemStatus.timedOut => colors.accent,
    RecordingBatchTranscriptionItemStatus.pending => colors.muted,
    RecordingBatchTranscriptionItemStatus.submitting ||
    RecordingBatchTranscriptionItemStatus.processing => colors.primary,
  };
}

String _waitingReasonLabel(RecordingBatchWaitingReason reason) {
  return switch (reason) {
    RecordingBatchWaitingReason.networkRequired => '网络恢复后会继续核验，不会重复上传',
    RecordingBatchWaitingReason.remoteVerificationRequired =>
      '正在确认已有远端录音，不会创建重复任务',
    RecordingBatchWaitingReason.accountScopeChanged => '切回发起任务的账号后可继续查看',
  };
}

String _itemFailureSummary(RecordingBatchTranscriptionItem item) {
  if (item.status == RecordingBatchTranscriptionItemStatus.timedOut) {
    return '等待服务响应超时，可继续观察';
  }
  return switch (item.failureCategory) {
    RecordingBatchFailureCategory.unavailable => '本地录音文件不可读取',
    RecordingBatchFailureCategory.upload => '录音上传失败，请重试',
    RecordingBatchFailureCategory.transcription => '录音转写失败，请重试',
    RecordingBatchFailureCategory.assetStorage => '转写完成，但资产保存失败',
    RecordingBatchFailureCategory.authorization => '当前账号无权继续处理',
    RecordingBatchFailureCategory.persistence => '本地任务记录保存失败',
    RecordingBatchFailureCategory.remote => '服务状态暂时无法确认',
    RecordingBatchFailureCategory.unknown || null => '处理失败，请重试',
  };
}

String _outlineStatusLabel(RecordingBatchOutlineStatus status) {
  return switch (status) {
    RecordingBatchOutlineStatus.notStarted => '',
    RecordingBatchOutlineStatus.generating => '纲要正在后台生成',
    RecordingBatchOutlineStatus.completed => '纲要已生成',
    RecordingBatchOutlineStatus.failed => '纲要生成失败，转写结果仍可查看',
  };
}
