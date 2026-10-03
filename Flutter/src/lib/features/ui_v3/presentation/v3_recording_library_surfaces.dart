import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/native/recording_card_native_port.dart';
import '../../../shared/theme/huahuo_v3_theme.dart';
import '../../../shared/ui_v3/v3_components.dart';
import '../../../shared/ui_v3/v3_liquid_glass.dart';
import '../../../shared/ui_v3/v3_overlays.dart';
import '../../recording_card/application/recording_card_controller.dart';
import '../../recording_card/application/recording_card_quick_wifi_coordinator.dart';
import '../../recording_card/domain/recording_card_auto_sync.dart';
import '../../recording_card/domain/recording_card_sync_ledger.dart';
import '../../recordings/application/recording_playback_controller.dart';
import '../../recordings/domain/recording_library.dart';

class V3RecordingPlaybackPanel extends StatefulWidget {
  const V3RecordingPlaybackPanel({
    required this.controller,
    required this.availabilityLabel,
    required this.transcriptionLabel,
    required this.onToggle,
    required this.onSeek,
    required this.onRate,
    required this.onClose,
    required this.onMore,
    super.key,
  });

  final RecordingPlaybackController controller;
  final String availabilityLabel;
  final String transcriptionLabel;
  final VoidCallback onToggle;
  final Future<void> Function(Duration) onSeek;
  final ValueChanged<double> onRate;
  final VoidCallback onClose;
  final ValueChanged<BuildContext> onMore;

  @override
  State<V3RecordingPlaybackPanel> createState() =>
      _V3RecordingPlaybackPanelState();
}

class _V3RecordingPlaybackPanelState extends State<V3RecordingPlaybackPanel> {
  double? _dragPositionMilliseconds;

  RecordingPlaybackState get state => widget.controller.state;

  @override
  void didUpdateWidget(covariant V3RecordingPlaybackPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller.state.recordingId != state.recordingId ||
        !state.canSeek) {
      _dragPositionMilliseconds = null;
    }
  }

  void _seekBy(Duration delta) {
    final duration = state.duration;
    final target = state.position + delta;
    unawaited(
      widget.onSeek(
        target < Duration.zero
            ? Duration.zero
            : target > duration
            ? duration
            : target,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) => _buildPlayer(context),
    );
  }

  Widget _buildPlayer(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final duration = state.duration;
    final max = duration.inMilliseconds > 0
        ? duration.inMilliseconds.toDouble()
        : 1.0;
    final position =
        (_dragPositionMilliseconds ?? state.position.inMilliseconds.toDouble())
            .clamp(0.0, max)
            .toDouble();
    final loading = state.status == RecordingPlaybackControllerStatus.loading;
    final failed = state.status == RecordingPlaybackControllerStatus.failed;
    final item = state.item;
    return Semantics(
      container: true,
      label: '${item?.displayName ?? '录音播放'}，${widget.transcriptionLabel}',
      child: AnimatedContainer(
        duration: V3MotionTokens.resolve(context, V3MotionTokens.quick),
        padding: const EdgeInsets.fromLTRB(14, 12, 10, 10),
        decoration: BoxDecoration(
          color: colors.surfaceMuted,
          border: Border(bottom: BorderSide(color: colors.line)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(Icons.graphic_eq_rounded, color: colors.accent),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item?.displayName ?? '录音播放',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${_displayDateTime(item?.createdAt)} · '
                        '${item == null ? '录音文件' : _displaySourceLabel(item.source)} · '
                        '${widget.transcriptionLabel} · ${widget.availabilityLabel}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colors.muted,
                          fontSize: 11.5,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: '收起播放器',
                  onPressed: widget.onClose,
                  icon: const Icon(Icons.keyboard_arrow_up_rounded),
                ),
              ],
            ),
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
              ),
              child: Slider(
                key: const ValueKey('recording-playback-scrubber'),
                value: position,
                max: max,
                onChangeStart: state.canSeek
                    ? (value) =>
                          setState(() => _dragPositionMilliseconds = value)
                    : null,
                onChanged: state.canSeek
                    ? (value) =>
                          setState(() => _dragPositionMilliseconds = value)
                    : null,
                onChangeEnd: state.canSeek
                    ? (value) async {
                        await widget.onSeek(
                          Duration(milliseconds: value.round()),
                        );
                        if (mounted) {
                          setState(() => _dragPositionMilliseconds = null);
                        }
                      }
                    : null,
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  Text(
                    _formatDuration(Duration(milliseconds: position.round())),
                    style: TextStyle(color: colors.muted, fontSize: 12),
                  ),
                  const Spacer(),
                  Text(
                    '-${_formatDuration(duration - Duration(milliseconds: position.round()))}',
                    style: TextStyle(color: colors.muted, fontSize: 12),
                  ),
                ],
              ),
            ),
            if (failed) ...[
              const SizedBox(height: 5),
              Text(
                '播放失败：${state.lastErrorCode ?? 'RECORDING_PLAYBACK_FAILED'}',
                style: TextStyle(
                  color: colors.danger,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
            const SizedBox(height: 4),
            Row(
              children: [
                TextButton(
                  onPressed: () async {
                    const rates = <double>[1.0, 1.25, 1.5, 2.0];
                    final rate = await showV3ActionSheet<double>(
                      context: context,
                      title: '播放速度',
                      items: <V3ActionSheetItem<double>>[
                        for (final option in rates)
                          V3ActionSheetItem(
                            value: option,
                            icon: Icons.speed_rounded,
                            label:
                                '${option == option.roundToDouble() ? option.toInt() : option}x',
                            selected: state.rate == option,
                          ),
                      ],
                    );
                    if (rate != null) widget.onRate(rate);
                  },
                  child: Text(
                    '${state.rate == state.rate.roundToDouble() ? state.rate.toInt() : state.rate}x',
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
                const Spacer(),
                IconButton(
                  tooltip: '后退 10 秒',
                  onPressed: state.canSeek
                      ? () => _seekBy(const Duration(seconds: -10))
                      : null,
                  icon: const Icon(Icons.replay_10_rounded),
                ),
                IconButton.filled(
                  tooltip: state.isPlaying ? '暂停' : '播放',
                  onPressed: loading ? null : widget.onToggle,
                  style: IconButton.styleFrom(
                    backgroundColor: colors.primary,
                    foregroundColor: colors.onPrimary,
                    disabledBackgroundColor: colors.line,
                    disabledForegroundColor: colors.muted,
                  ),
                  icon: loading
                      ? SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: colors.muted,
                          ),
                        )
                      : Icon(
                          state.isPlaying
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                        ),
                ),
                IconButton(
                  tooltip: '前进 10 秒',
                  onPressed: state.canSeek
                      ? () => _seekBy(const Duration(seconds: 10))
                      : null,
                  icon: const Icon(Icons.forward_10_rounded),
                ),
                const Spacer(),
                Builder(
                  builder: (buttonContext) => IconButton(
                    key: ValueKey(
                      'recording-player-more-${state.recordingId ?? 'unknown'}',
                    ),
                    tooltip: '录音操作',
                    onPressed: () => widget.onMore(buttonContext),
                    icon: const Icon(Icons.more_horiz_rounded),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class V3RecordingUploadProgressPanel extends StatelessWidget {
  const V3RecordingUploadProgressPanel({
    required this.title,
    required this.status,
    this.bytesSent = 0,
    this.totalBytes = 0,
    this.bytesPerSecond = 0,
    this.estimatedRemainingSeconds,
    super.key,
  });

  final String title;
  final RecordingFileJobStatus? status;
  final int bytesSent;
  final int totalBytes;
  final double bytesPerSecond;
  final int? estimatedRemainingSeconds;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final phase = _uploadTranscriptionPhaseLabel(status);
    final hasByteProgress = totalBytes > 0;
    final safeBytesSent = bytesSent.clamp(0, totalBytes).toInt();
    final fraction = hasByteProgress ? safeBytesSent / totalBytes : null;
    final progressDetails = <String>[
      if (hasByteProgress)
        '${_formatBytes(safeBytesSent)} / ${_formatBytes(totalBytes)}',
      if (hasByteProgress && bytesPerSecond > 0)
        '${_formatBytes(bytesPerSecond.round())}/s',
      if (hasByteProgress && estimatedRemainingSeconds != null)
        '剩余 ${_displayBatchEta(estimatedRemainingSeconds!)}',
    ].join(' · ');
    return Semantics(
      liveRegion: true,
      label:
          '正在上传并创建转写任务：$phase'
          '${progressDetails.isEmpty ? '' : '，$progressDetails'}',
      child: V3Card(
        key: const ValueKey('recording-upload-transcription-progress'),
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 11),
        radius: 16,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  Icons.cloud_upload_outlined,
                  size: 20,
                  color: colors.primary,
                ),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    '正在上传并创建转写任务',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: colors.muted),
            ),
            const SizedBox(height: 9),
            LinearProgressIndicator(
              key: const ValueKey('recording-upload-transcription-indicator'),
              value: fraction,
              minHeight: 5,
              color: colors.primary,
              backgroundColor: colors.line,
            ),
            const SizedBox(height: 7),
            Text(
              phase,
              key: const ValueKey('recording-upload-transcription-phase'),
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: colors.text,
              ),
            ),
            if (progressDetails.isNotEmpty) ...[
              const SizedBox(height: 3),
              Text(
                progressDetails,
                key: const ValueKey(
                  'recording-upload-transcription-progress-detail',
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11.5, color: colors.muted),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

String _uploadTranscriptionPhaseLabel(RecordingFileJobStatus? status) {
  return switch (status) {
    null || RecordingFileJobStatus.uploading => '正在上传录音',
    RecordingFileJobStatus.processing => '服务端正在转写',
    RecordingFileJobStatus.ready => '转写结果已就绪',
    RecordingFileJobStatus.failed => '录音处理失败',
  };
}

class V3WifiBatchProgressPanel extends StatelessWidget {
  const V3WifiBatchProgressPanel({
    required this.batch,
    required this.bytesPerSecond,
    required this.actionBusy,
    required this.onStart,
    required this.onPause,
    required this.onResume,
    required this.onRetryFailed,
    required this.onCancel,
    required this.onDismiss,
    super.key,
  });

  final RecordingCardWifiBatchSnapshot batch;
  final double bytesPerSecond;
  final bool actionBusy;
  final VoidCallback onStart;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final VoidCallback onRetryFailed;
  final VoidCallback onCancel;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final ready = batch.state == RecordingCardWifiBatchState.queued;
    final failed = batch.state == RecordingCardWifiBatchState.failed;
    final paused = batch.state == RecordingCardWifiBatchState.paused;
    final completed = batch.state == RecordingCardWifiBatchState.completed;
    final cancelled = batch.state == RecordingCardWifiBatchState.cancelled;
    final bluetoothHandoff = recordingCardWifiBatchIsBluetoothHandoff(batch);
    final bluetoothResumeFailure =
        recordingCardWifiBatchIsBluetoothResumeFailure(batch);
    final stopping =
        batch.operationPhase == RecordingCardWifiOperationPhase.stopping;
    final transferring =
        batch.state == RecordingCardWifiBatchState.transferring;
    final verifying = batch.state == RecordingCardWifiBatchState.verifying;
    final registering = batch.state == RecordingCardWifiBatchState.registering;
    final reconciling = batch.state == RecordingCardWifiBatchState.reconciling;
    final itemName = batch.currentItem?.file.deviceFilename ?? '等待传输';
    final currentName = bluetoothHandoff
        ? '正在恢复蓝牙并继续同步'
        : bluetoothResumeFailure
        ? '蓝牙续传失败，等待继续'
        : stopping
        ? '正在结束同步任务'
        : ready
        ? '发现 ${batch.totalCount} 条未同步录音'
        : failed
        ? _wifiBatchFailureTitle(batch)
        : paused
        ? '已暂停：$itemName'
        : completed
        ? 'Wi-Fi 传输已完成'
        : cancelled
        ? 'Wi-Fi 传输已取消'
        : verifying
        ? '正在校验：$itemName'
        : registering
        ? '正在入库：$itemName'
        : reconciling
        ? '正在恢复蓝牙并复核目录'
        : '正在传输：$itemName';
    final effectiveRate = batch.bytesPerSecond ?? bytesPerSecond;
    final rateReady =
        transferring &&
        batch.rateSampleCount >= 2 &&
        effectiveRate > 0 &&
        batch.currentFileEstimatedRemainingSeconds != null &&
        batch.aggregateEstimatedRemainingSeconds != null;
    final currentTotalBytes = batch.currentItem?.effectiveSizeBytes ?? 0;
    final currentReceivedBytes = batch.receivedBytes.clamp(
      0,
      currentTotalBytes,
    );
    final currentProgress = currentTotalBytes <= 0
        ? null
        : currentReceivedBytes / currentTotalBytes;
    final currentProgressPercent = currentProgress == null
        ? null
        : (currentProgress * 100).round().clamp(0, 100);
    final showResume = paused;
    final registeredCount = batch.items
        .where(
          (item) =>
              item.state == RecordingCardWifiBatchItemState.completed ||
              item.state == RecordingCardWifiBatchItemState.skipped,
        )
        .length;
    final showsSettlementCounts = paused || failed || completed || cancelled;
    final phaseCountText = registering
        ? '已入库 $registeredCount/${batch.totalCount} 条'
        : showsSettlementCounts
        ? '已同步 ${batch.completedCount} 条 · 未同步 ${batch.remainingCount} 条'
        : '已传输 ${batch.completedCount}/${batch.totalCount} 条';
    final progress = _wifiBatchProgressValue(batch);
    final progressPercent = progress == null
        ? null
        : (progress * 100).round().clamp(0, 100);
    final stateLabel = bluetoothHandoff
        ? '蓝牙恢复续传'
        : bluetoothResumeFailure
        ? '蓝牙续传待重试'
        : switch (batch.operationPhase) {
            RecordingCardWifiOperationPhase.recovering => '正在恢复核验',
            RecordingCardWifiOperationPhase.preparingHotspot => '正在打开录音卡热点',
            RecordingCardWifiOperationPhase.joiningHotspot => '正在连接录音卡热点',
            RecordingCardWifiOperationPhase.stopping => '正在结束本批',
            RecordingCardWifiOperationPhase.idle => _wifiBatchStateLabel(
              batch.state,
            ),
          };
    final stateSummary = ready
        ? '${batch.totalCount} 条待同步'
        : progressPercent == null || batch.isTerminal
        ? stateLabel
        : '$stateLabel · $progressPercent%';
    final surfaceColor = switch (batch.state) {
      RecordingCardWifiBatchState.paused => Color.alphaBlend(
        const Color(0xFFA06F28).withValues(alpha: .12),
        colors.surface,
      ),
      RecordingCardWifiBatchState.completed => Color.alphaBlend(
        colors.success.withValues(alpha: .10),
        colors.surface,
      ),
      RecordingCardWifiBatchState.failed => Color.alphaBlend(
        colors.danger.withValues(alpha: .10),
        colors.surface,
      ),
      RecordingCardWifiBatchState.queued => colors.surfaceMuted,
      _ => Color.alphaBlend(
        const Color(0xFF2E6EC7).withValues(alpha: .09),
        colors.surface,
      ),
    };
    final showRetry = failed;

    return V3Card(
      key: const ValueKey('recording-card-wifi-batch-progress'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      radius: 12,
      glass: false,
      variant: V3CardVariant.outlined,
      color: surfaceColor,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 112),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 44),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '录音卡文件同步',
                          style: TextStyle(
                            fontSize: 14.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          stateSummary,
                          style: TextStyle(
                            color: colors.muted,
                            fontSize: 11.5,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (ready)
                    SizedBox(
                      width: 132,
                      height: 44,
                      child: Row(
                        children: [
                          SizedBox.square(
                            dimension: 44,
                            child: IconButton.outlined(
                              key: const ValueKey(
                                'recording-card-wifi-batch-cancel',
                              ),
                              tooltip: '结束同步任务',
                              onPressed: actionBusy || !batch.canFinish
                                  ? null
                                  : onCancel,
                              icon: const Icon(
                                Icons.stop_circle_outlined,
                                size: 20,
                              ),
                              color: colors.danger,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: FilledButton.icon(
                              key: const ValueKey(
                                'recording-card-wifi-batch-start',
                              ),
                              onPressed: actionBusy || !batch.canContinue
                                  ? null
                                  : onStart,
                              icon: const Icon(
                                Icons.play_arrow_rounded,
                                size: 18,
                              ),
                              label: const Text('开始'),
                              style: _wifiBatchPrimaryActionStyle(colors),
                            ),
                          ),
                        ],
                      ),
                    )
                  else if (showResume)
                    SizedBox(
                      width: 132,
                      height: 44,
                      child: Row(
                        children: [
                          SizedBox.square(
                            dimension: 44,
                            child: IconButton.outlined(
                              key: const ValueKey(
                                'recording-card-wifi-batch-cancel',
                              ),
                              tooltip: '结束同步任务',
                              onPressed: actionBusy || !batch.canFinish
                                  ? null
                                  : onCancel,
                              icon: const Icon(
                                Icons.stop_circle_outlined,
                                size: 20,
                              ),
                              color: colors.danger,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: FilledButton.icon(
                              key: const ValueKey(
                                'recording-card-wifi-batch-resume',
                              ),
                              onPressed: actionBusy || !batch.canContinue
                                  ? null
                                  : onResume,
                              icon: actionBusy
                                  ? const SizedBox.square(
                                      dimension: 14,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(
                                      Icons.play_arrow_rounded,
                                      size: 18,
                                    ),
                              label: const Text('继续'),
                              style: _wifiBatchPrimaryActionStyle(colors),
                            ),
                          ),
                        ],
                      ),
                    )
                  else if (bluetoothHandoff)
                    SizedBox.square(
                      dimension: 44,
                      child: IconButton.outlined(
                        key: const ValueKey('recording-card-wifi-batch-cancel'),
                        tooltip: '结束同步任务',
                        onPressed: actionBusy ? null : onCancel,
                        icon: const Icon(Icons.stop_circle_outlined, size: 20),
                        color: colors.danger,
                      ),
                    )
                  else if (stopping)
                    const SizedBox.square(
                      dimension: 44,
                      child: Center(
                        child: SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    )
                  else if (batch.isActive)
                    SizedBox(
                      width: 84,
                      height: 44,
                      child: FilledButton.icon(
                        key: const ValueKey('recording-card-wifi-batch-pause'),
                        onPressed: actionBusy ? null : onPause,
                        icon: actionBusy
                            ? const SizedBox.square(
                                dimension: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.pause_rounded, size: 18),
                        label: const Text('暂停'),
                        style: _wifiBatchPrimaryActionStyle(colors),
                      ),
                    )
                  else if (showRetry)
                    SizedBox(
                      width: 84,
                      height: 44,
                      child: FilledButton.icon(
                        key: const ValueKey(
                          'recording-card-wifi-batch-retry-failed',
                        ),
                        onPressed: actionBusy ? null : onRetryFailed,
                        style: _wifiBatchPrimaryActionStyle(
                          colors,
                          danger: true,
                        ),
                        icon: actionBusy
                            ? const SizedBox.square(
                                dimension: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.refresh_rounded, size: 18),
                        label: const Text('重试'),
                      ),
                    ),
                ],
              ),
            ),
            Text(
              currentName,
              key: const ValueKey('recording-card-wifi-batch-current'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12.5, color: colors.muted),
            ),
            const SizedBox(height: 4),
            LinearProgressIndicator(
              value: progress,
              minHeight: 6,
              borderRadius: BorderRadius.circular(3),
              color: failed ? colors.danger : colors.primary,
              backgroundColor: colors.line,
            ),
            const SizedBox(height: 4),
            Text(
              ready
                  ? '预计 ${_formatBytes(batch.totalBytes)} · 使用 Wi-Fi 快速同步'
                  : '$phaseCountText · '
                        '${_formatBytes(batch.aggregateReceivedBytes)} / ${_formatBytes(batch.totalBytes)}',
              key: const ValueKey('recording-card-wifi-batch-total-progress'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11.5, color: colors.text),
            ),
            const SizedBox(height: 2),
            Text(
              ready
                  ? '同步过程中可随时暂停'
                  : paused
                  ? '已完成文件已保留，可从 ${progressPercent ?? 0}% 继续'
                  : failed
                  ? '已完成文件已保留，可从 ${progressPercent ?? 0}% 重试'
                  : transferring
                  ? rateReady
                        ? '${_formatBytes(effectiveRate.round())}/s · '
                              '当前 ${currentProgressPercent ?? 0}% / '
                              '${_displayBatchEta(batch.currentFileEstimatedRemainingSeconds!)} · '
                              '整批 ${_displayBatchEta(batch.aggregateEstimatedRemainingSeconds!)}'
                        : '当前 ${currentProgressPercent ?? 0}% · 正在测算'
                  : verifying
                  ? '正在校验文件完整性'
                  : registering
                  ? '正在登记本地录音'
                  : reconciling
                  ? '正在恢复蓝牙并复核同步结果'
                  : stateLabel,
              key: const ValueKey('recording-card-wifi-batch-rate'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: colors.muted),
            ),
            if (ready || batch.isActive) ...[
              const SizedBox(height: 8),
              const _WifiTransferStayNotice(),
            ],
          ],
        ),
      ),
    );
  }
}

class _WifiTransferStayNotice extends StatelessWidget {
  const _WifiTransferStayNotice();

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Row(
      key: const ValueKey('recording-card-wifi-stay-notice'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.info_outline_rounded, size: 17, color: colors.primary),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            'Wi-Fi 传输过程中请勿离开当前页面，离开后传输会断开。',
            style: TextStyle(
              color: colors.text,
              fontSize: 12,
              height: 1.4,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
    );
  }
}

class V3QuickWifiPreparationPanel extends StatelessWidget {
  const V3QuickWifiPreparationPanel({
    required this.state,
    required this.onRetry,
    super.key,
  });

  final RecordingCardQuickWifiState state;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final failed = state.phase == RecordingCardQuickWifiPhase.failed;
    final phaseLabel = switch (state.phase) {
      RecordingCardQuickWifiPhase.preparingHandoff => '正在切换传输方式',
      RecordingCardQuickWifiPhase.refreshingDirectory => '正在刷新文件目录',
      RecordingCardQuickWifiPhase.persistingPlan => '正在保存传输计划',
      RecordingCardQuickWifiPhase.completed => '同步与文件核验已完成',
      RecordingCardQuickWifiPhase.failed => '快速传输等待重试',
      _ => '正在准备 Wi-Fi 快速传输',
    };
    return V3Card(
      key: const ValueKey('recording-card-wifi-batch-progress'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      radius: 8,
      glass: false,
      variant: V3CardVariant.outlined,
      color: failed
          ? Color.alphaBlend(
              colors.danger.withValues(alpha: .10),
              colors.surface,
            )
          : colors.surfaceMuted,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 92),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '录音卡文件同步',
                        style: TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        phaseLabel,
                        key: const ValueKey(
                          'recording-card-quick-wifi-preparation-phase',
                        ),
                        style: TextStyle(
                          color: failed ? colors.danger : colors.muted,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
                if (failed && state.canRetry)
                  FilledButton.icon(
                    key: const ValueKey(
                      'recording-card-quick-wifi-preparation-retry',
                    ),
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    label: const Text('重试'),
                    style: _wifiBatchPrimaryActionStyle(colors, danger: true),
                  )
                else if (failed)
                  Icon(
                    Icons.error_outline_rounded,
                    color: colors.danger,
                    size: 22,
                  )
                else
                  const SizedBox.square(
                    dimension: 22,
                    child: CircularProgressIndicator(strokeWidth: 2.4),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            LinearProgressIndicator(
              value: failed ? 0 : null,
              minHeight: 5,
              borderRadius: BorderRadius.circular(3),
              color: failed ? colors.danger : colors.primary,
              backgroundColor: colors.line,
            ),
            if (state.targetCount > 0) ...[
              const SizedBox(height: 5),
              Text(
                '待同步 ${state.targetCount} 条录音',
                style: TextStyle(fontSize: 11, color: colors.muted),
              ),
            ],
            if (state.isPreparing) ...[
              const SizedBox(height: 8),
              const _WifiTransferStayNotice(),
            ],
          ],
        ),
      ),
    );
  }
}

ButtonStyle _wifiBatchPrimaryActionStyle(
  HuahuoV3ThemeTokens colors, {
  bool danger = false,
}) {
  return FilledButton.styleFrom(
    minimumSize: const Size(84, 44),
    padding: const EdgeInsets.symmetric(horizontal: 10),
    backgroundColor: danger ? colors.danger : colors.primary,
    foregroundColor: colors.onPrimary,
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    textStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
  );
}

class V3RecordingDeviceStateBanner extends StatelessWidget {
  const V3RecordingDeviceStateBanner({
    required this.title,
    required this.subtitle,
    required this.actionLabel,
    required this.onAction,
    this.danger = false,
    this.refreshing = false,
    super.key,
  });

  final String title;
  final String subtitle;
  final String actionLabel;
  final VoidCallback onAction;
  final bool danger;
  final bool refreshing;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final accent = danger ? colors.danger : colors.primary;
    return V3Card(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      radius: 12,
      glass: false,
      color: colors.surfaceMuted,
      child: SizedBox(
        height: 46,
        child: Row(
          children: [
            SizedBox.square(
              dimension: 28,
              child: refreshing
                  ? CircularProgressIndicator(strokeWidth: 2.5, color: accent)
                  : Icon(Icons.battery_alert_rounded, color: accent, size: 24),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: colors.muted, fontSize: 11.5),
                  ),
                ],
              ),
            ),
            TextButton(onPressed: onAction, child: Text(actionLabel)),
          ],
        ),
      ),
    );
  }
}

class V3RecordingAutoSyncPanel extends StatelessWidget {
  const V3RecordingAutoSyncPanel({
    required this.state,
    required this.unsyncedCount,
    required this.progress,
    required this.onStart,
    required this.onPause,
    required this.onContinue,
    required this.onRetry,
    this.uploadBytesSent = 0,
    this.uploadTotalBytes = 0,
    this.uploadBytesPerSecond = 0,
    this.uploadEstimatedRemainingSeconds,
    this.quickWifiEnabled = false,
    this.onQuickWifiTransfer,
    super.key,
  }) : assert(onQuickWifiTransfer != null || !quickWifiEnabled);

  final RecordingCardAutoSyncState state;
  final int unsyncedCount;
  final RecordingCardTransferProgress? progress;
  final VoidCallback onStart;
  final VoidCallback onPause;
  final VoidCallback onContinue;
  final VoidCallback onRetry;
  final int uploadBytesSent;
  final int uploadTotalBytes;
  final double uploadBytesPerSecond;
  final int? uploadEstimatedRemainingSeconds;
  final bool quickWifiEnabled;
  final VoidCallback? onQuickWifiTransfer;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final enabled = state.preferences.autoSyncEnabled;
    final paused = state.status == RecordingCardAutoSyncStatus.paused;
    final pausing = state.status == RecordingCardAutoSyncStatus.pausing;
    final finalizing =
        state.status == RecordingCardAutoSyncStatus.verifying ||
        state.status == RecordingCardAutoSyncStatus.committing;
    final failed = state.status == RecordingCardAutoSyncStatus.failed;
    final transferring =
        state.status == RecordingCardAutoSyncStatus.scanning ||
        state.status == RecordingCardAutoSyncStatus.downloading;
    final transcribing =
        state.status == RecordingCardAutoSyncStatus.transcribing;
    final hasUploadProgress = transcribing && uploadTotalBytes > 0;
    final safeUploadBytes = hasUploadProgress
        ? uploadBytesSent.clamp(0, uploadTotalBytes).toInt()
        : 0;
    final prerequisiteWait = _autoSyncPrerequisiteWait(state.waitingReason);
    final waiting =
        prerequisiteWait != null ||
        state.status == RecordingCardAutoSyncStatus.waitingForDevice ||
        state.status == RecordingCardAutoSyncStatus.waitingForRecording ||
        state.status == RecordingCardAutoSyncStatus.waitingForRetry ||
        state.status == RecordingCardAutoSyncStatus.waitingForTransfer;
    RecordingCardAutoSyncTask? activeTask;
    for (final task in state.tasks) {
      if (task.taskId == state.activeTaskId) {
        activeTask = task;
        break;
      }
    }
    final activeProgress =
        activeTask != null &&
            progress?.localFileKey == activeTask.localFileKey &&
            progress?.transport != RecordingCardTransferTransport.wifi &&
            progress?.phase != RecordingCardTransferPhase.completed &&
            progress?.phase != RecordingCardTransferPhase.cancelled &&
            progress?.phase != RecordingCardTransferPhase.failed
        ? progress
        : null;
    final nativeFraction =
        state.status == RecordingCardAutoSyncStatus.downloading
        ? activeProgress?.fraction
        : null;
    final uploadFraction = hasUploadProgress
        ? safeUploadBytes / uploadTotalBytes
        : null;
    final fraction = transcribing
        ? uploadFraction
        : nativeFraction?.clamp(0.0, 1.0);
    final percent = fraction == null ? null : (fraction * 100).round();
    final progressReceivedBytes = activeProgress?.receivedBytes;
    final progressTotalBytes = activeProgress?.totalBytes;
    final progressParts = <String>[
      if (transcribing)
        '文件已同步'
      else
        '待同步 $unsyncedCount 条${percent == null ? '' : ' · 当前 $percent%'}',
      if (hasUploadProgress)
        '${_formatBytes(safeUploadBytes)} / ${_formatBytes(uploadTotalBytes)}'
      else if (progressReceivedBytes != null &&
          progressTotalBytes != null &&
          progressTotalBytes > 0)
        '${_formatBytes(progressReceivedBytes)} / ${_formatBytes(progressTotalBytes)}',
      if (hasUploadProgress && uploadBytesPerSecond > 0)
        '${_formatBytes(uploadBytesPerSecond.round())}/s'
      else if (transferring && (activeProgress?.bytesPerSecond ?? 0) > 0)
        '${_formatBytes(activeProgress!.bytesPerSecond!.round())}/s',
      if (hasUploadProgress && uploadEstimatedRemainingSeconds != null)
        '剩余 ${_displayBatchEta(uploadEstimatedRemainingSeconds!)}'
      else if (transferring &&
          activeProgress?.estimatedRemainingSeconds != null)
        '剩余 ${_displayBatchEta(activeProgress!.estimatedRemainingSeconds!)}',
    ];
    final statusText = pausing
        ? '正在暂停同步'
        : finalizing
        ? state.status == RecordingCardAutoSyncStatus.verifying
              ? '正在核验录音文件'
              : '正在保存同步记录'
        : transcribing
        ? '文件已同步，正在转写'
        : !enabled
        ? '待同步 $unsyncedCount 条'
        : prerequisiteWait != null
        ? prerequisiteWait.$1
        : paused
        ? '已暂停${percent == null ? '' : ' · $percent%'}'
        : failed
        ? '同步中断${percent == null ? '' : ' · $percent%'}'
        : transferring
        ? '同步中${percent == null ? '' : ' · $percent%'}'
        : switch (state.status) {
            RecordingCardAutoSyncStatus.transcribing => '文件已同步，正在提交转写',
            RecordingCardAutoSyncStatus.waitingForRecording => '录音结束后自动继续',
            RecordingCardAutoSyncStatus.waitingForTransfer => '等待当前传输完成',
            RecordingCardAutoSyncStatus.waitingForDevice => '等待录音卡连接',
            RecordingCardAutoSyncStatus.waitingForRetry => '等待自动重试',
            _ => '待同步 $unsyncedCount 条',
          };
    final transcribingTaskCount = state.tasks
        .where(
          (task) => task.state == RecordingCardAutoSyncTaskState.transcribing,
        )
        .length;
    final currentTaskText = pausing
        ? '等待当前传输安全结束'
        : finalizing
        ? '完成确认前，请勿关闭应用'
        : paused
        ? '同步已暂停：${activeTask?.deviceFilename ?? '未完成录音'}'
        : state.status == RecordingCardAutoSyncStatus.waitingForRetry
        ? '暂时未能同步，稍后继续未完成文件'
        : prerequisiteWait != null
        ? prerequisiteWait.$2
        : failed
        ? '连接中断，未完成文件等待重试'
        : transcribing
        ? '$transcribingTaskCount 个录音正在上传或转写'
        : activeTask != null
        ? '正在同步：${activeTask.deviceFilename}'
        : transferring
        ? '正在读取录音卡文件'
        : '发现 $unsyncedCount 条未同步录音';
    final progressText = progressParts.join(' · ');
    final supportText = transcribing
        ? '文件已同步，可正常使用录音卡'
        : prerequisiteWait != null
        ? prerequisiteWait.$3
        : paused
        ? '继续同步后，录音卡暂不可进行其他操作'
        : failed
        ? '点击重试后，录音卡暂不可进行其他操作'
        : '同步期间录音卡暂不可录音、传输或删除文件';
    final background = failed
        ? Color.alphaBlend(colors.danger.withValues(alpha: .08), colors.surface)
        : paused
        ? colors.warmGlass.fallback
        : transferring
        ? colors.coolGlass.fallback
        : colors.surfaceMuted;
    final border = paused
        ? colors.warmGlass.rim
        : transferring
        ? colors.coolGlass.rim
        : colors.line;
    final accent = failed ? colors.danger : colors.accent;
    final (VoidCallback?, IconData?, String?) action = pausing || finalizing
        ? (null, null, null)
        : !enabled
        ? (onStart, Icons.play_arrow_rounded, '开始')
        : prerequisiteWait != null
        ? (onRetry, Icons.refresh_rounded, '重试')
        : paused
        ? (onContinue, Icons.play_arrow_rounded, '继续')
        : failed
        ? (onRetry, Icons.refresh_rounded, '重试')
        : transferring ||
              waiting ||
              (transcribing && state.pendingFileSyncCount > 0)
        ? (onPause, Icons.pause_rounded, '暂停')
        : transcribing
        ? (null, null, null)
        : (onStart, Icons.play_arrow_rounded, '开始');
    return Material(
      key: const ValueKey('recording-card-auto-sync-progress'),
      color: background,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: border),
      ),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 128),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 44),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            '录音卡文件同步',
                            style: TextStyle(
                              fontSize: 14.5,
                              fontWeight: FontWeight.w500,
                              height: 1,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            statusText,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: failed ? colors.danger : accent,
                              fontSize: 11.5,
                              fontWeight: FontWeight.w500,
                              height: 1,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (action.$1 != null)
                      _RecordingSyncAction(
                        onPressed: action.$1!,
                        icon: action.$2!,
                        label: action.$3!,
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              ConstrainedBox(
                key: const ValueKey('recording-auto-sync-current-task-line'),
                constraints: const BoxConstraints(minHeight: 16),
                child: Text(
                  currentTaskText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.text,
                    fontSize: 12.5,
                    height: 1,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              LinearProgressIndicator(
                value: transferring || transcribing || finalizing || pausing
                    ? fraction
                    : fraction ?? 0,
                minHeight: 6,
                borderRadius: BorderRadius.circular(3),
                color: accent,
                backgroundColor: border.withValues(alpha: paused ? .28 : 1),
              ),
              const SizedBox(height: 4),
              ConstrainedBox(
                key: const ValueKey('recording-auto-sync-progress-line'),
                constraints: const BoxConstraints(minHeight: 14),
                child: Text(
                  progressText,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.text,
                    fontSize: 11.5,
                    height: 1,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              ConstrainedBox(
                key: const ValueKey('recording-auto-sync-support-line'),
                constraints: const BoxConstraints(minHeight: 14),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        supportText,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colors.muted,
                          fontSize: 11,
                          height: 1,
                        ),
                      ),
                    ),
                    if (onQuickWifiTransfer != null) ...[
                      const SizedBox(width: 8),
                      TextButton.icon(
                        key: const ValueKey(
                          'recording-card-quick-wifi-transfer',
                        ),
                        onPressed: quickWifiEnabled
                            ? onQuickWifiTransfer
                            : null,
                        style: TextButton.styleFrom(
                          foregroundColor: colors.accent,
                          disabledForegroundColor: colors.muted,
                          minimumSize: const Size(0, 24),
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          visualDensity: VisualDensity.compact,
                        ),
                        icon: const Icon(Icons.wifi_rounded, size: 15),
                        label: const Text(
                          '快速传输',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                            height: 1,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

(String, String, String)? _autoSyncPrerequisiteWait(
  RecordingCardSyncWaitingReason? reason,
) => switch (reason) {
  RecordingCardSyncWaitingReason.persistenceRequired => (
    '等待同步记录恢复',
    '同步记录尚未完成保存',
    '恢复本地存储后点击重试',
  ),
  RecordingCardSyncWaitingReason.networkRequired => (
    '等待网络恢复',
    '网络不可用，已保留同步进度',
    '网络恢复后点击重试',
  ),
  RecordingCardSyncWaitingReason.permissionRequired => (
    '等待录音卡权限',
    '蓝牙或无线局域网权限未开启',
    '开启权限后点击重试',
  ),
  RecordingCardSyncWaitingReason.storageInsufficient => (
    '等待本地存储空间',
    '本地空间不足，已保留同步进度',
    '释放空间后点击重试',
  ),
  _ => null,
};

class _RecordingSyncAction extends StatelessWidget {
  const _RecordingSyncAction({
    required this.onPressed,
    required this.icon,
    required this.label,
  });

  final VoidCallback onPressed;
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return SizedBox(
      width: 84,
      height: 44,
      child: Material(
        color: colors.primary,
        borderRadius: BorderRadius.circular(10),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 18, color: colors.onPrimary),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  color: colors.onPrimary,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                  height: 1,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

enum V3WifiTransferFlowResult { completed, cancelled, failed }

enum _WifiTransferFlowPhase {
  preparingHandoff,
  refreshingDirectory,
  persistingPlan,
  recovering,
  stopping,
  openingHotspot,
  joiningHotspot,
  transferring,
  verifying,
  registering,
  reconciling,
  paused,
  completed,
  failed,
  cancelled,
}

enum _WifiTransferStepState {
  pending,
  active,
  paused,
  completed,
  failed,
  cancelled,
}

class V3WifiTransferFlowSheet extends StatefulWidget {
  const V3WifiTransferFlowSheet({
    required this.controller,
    this.batchId,
    this.quickWifiCoordinator,
    this.quickWifiRequestId,
    this.onReady,
    this.onCompleted,
    super.key,
  }) : assert(
         batchId != null ||
             (quickWifiCoordinator != null && quickWifiRequestId != null),
       );

  final RecordingCardController controller;
  final String? batchId;
  final RecordingCardQuickWifiCoordinator? quickWifiCoordinator;
  final String? quickWifiRequestId;
  final VoidCallback? onReady;
  final VoidCallback? onCompleted;

  @override
  State<V3WifiTransferFlowSheet> createState() =>
      V3WifiTransferFlowSheetState();
}

class V3WifiTransferFlowSheetState extends State<V3WifiTransferFlowSheet> {
  bool _completionReported = false;
  late String? _quickWifiRequestId;

  RecordingCardQuickWifiState? get _quickState {
    final state = widget.quickWifiCoordinator?.state;
    return state?.requestId == _quickWifiRequestId ? state : null;
  }

  RecordingCardWifiBatchSnapshot? get _batch {
    final batch = widget.controller.state.wifiBatch;
    final expectedBatchId = _quickState?.batchId ?? widget.batchId;
    return batch?.batchId == expectedBatchId ? batch : null;
  }

  @override
  void initState() {
    super.initState();
    _quickWifiRequestId = widget.quickWifiRequestId;
    widget.controller.addListener(_handleControllerChanged);
    widget.quickWifiCoordinator?.addListener(_handleQuickWifiChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.onReady?.call();
      _reportDurableCompletion();
    });
  }

  @override
  void didUpdateWidget(covariant V3WifiTransferFlowSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.controller, widget.controller) &&
        oldWidget.batchId == widget.batchId &&
        identical(
          oldWidget.quickWifiCoordinator,
          widget.quickWifiCoordinator,
        ) &&
        oldWidget.quickWifiRequestId == widget.quickWifiRequestId) {
      return;
    }
    oldWidget.controller.removeListener(_handleControllerChanged);
    oldWidget.quickWifiCoordinator?.removeListener(_handleQuickWifiChanged);
    _quickWifiRequestId = widget.quickWifiRequestId;
    _completionReported = false;
    widget.controller.addListener(_handleControllerChanged);
    widget.quickWifiCoordinator?.addListener(_handleQuickWifiChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _reportDurableCompletion();
    });
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleControllerChanged);
    widget.quickWifiCoordinator?.removeListener(_handleQuickWifiChanged);
    super.dispose();
  }

  void _handleControllerChanged() {
    if (!mounted) return;
    _reportDurableCompletion();
  }

  void _handleQuickWifiChanged() {
    if (!mounted) return;
    setState(() {});
    _reportDurableCompletion();
  }

  void _reportDurableCompletion() {
    if (_completionReported) return;
    final completed =
        _batch?.state == RecordingCardWifiBatchState.completed ||
        _quickState?.phase == RecordingCardQuickWifiPhase.completed;
    if (!completed) {
      return;
    }
    _completionReported = true;
    widget.onCompleted?.call();
  }

  Future<void> _retry() async {
    final batch = _batch;
    if (batch == null) {
      final requestId = _quickWifiRequestId;
      if (requestId != null && _quickState?.canRetry == true) {
        await widget.quickWifiCoordinator?.retry(requestId);
      }
      return;
    }
    final coordinator = widget.quickWifiCoordinator;
    if (coordinator != null) {
      final action = batch.canRetryFailed
          ? RecordingCardQuickWifiExistingAction.retryFailed
          : batch.state == RecordingCardWifiBatchState.queued
          ? RecordingCardQuickWifiExistingAction.start
          : RecordingCardQuickWifiExistingAction.resume;
      final requestId = coordinator.beginExistingBatch(batch, action);
      if (mounted) setState(() => _quickWifiRequestId = requestId);
      await coordinator.execute(requestId);
      return;
    }
    if (batch.canContinue) {
      await widget.controller.resumeWifiBatch();
    } else if (batch.canRetryFailed) {
      await widget.controller.retryFailedWifiBatch();
    }
  }

  Future<void> _cancel() async {
    if (!(_batch?.canFinish ?? false)) return;
    await widget.controller.cancelWifiBatch();
    if (!mounted) return;
    final batch = _batch;
    if (batch?.state == RecordingCardWifiBatchState.cancelled) {
      Navigator.of(context).pop(V3WifiTransferFlowResult.cancelled);
    } else if (batch?.state == RecordingCardWifiBatchState.completed &&
        batch?.remainingCount == 0) {
      Navigator.of(context).pop(V3WifiTransferFlowResult.completed);
    }
  }

  _WifiTransferStepState _stepState(
    int index,
    RecordingCardWifiBatchSnapshot? batch,
    _WifiTransferFlowPhase phase,
  ) {
    if (phase == _WifiTransferFlowPhase.preparingHandoff ||
        phase == _WifiTransferFlowPhase.refreshingDirectory ||
        phase == _WifiTransferFlowPhase.persistingPlan) {
      return _WifiTransferStepState.pending;
    }
    if (phase == _WifiTransferFlowPhase.failed) {
      final failed = _wifiBatchFailureStep(
        batch,
        fallbackCode: widget.controller.state.lastErrorCode,
      );
      if (index < failed) return _WifiTransferStepState.completed;
      if (index == failed) return _WifiTransferStepState.failed;
      return _WifiTransferStepState.pending;
    }
    if (phase == _WifiTransferFlowPhase.paused) {
      final pausedStep = _wifiBatchFailureStep(batch);
      if (index < pausedStep) return _WifiTransferStepState.completed;
      return index == pausedStep
          ? _WifiTransferStepState.paused
          : _WifiTransferStepState.pending;
    }
    if (phase == _WifiTransferFlowPhase.cancelled) {
      if (index < 2) return _WifiTransferStepState.completed;
      return index == 2
          ? _WifiTransferStepState.cancelled
          : _WifiTransferStepState.pending;
    }
    if (phase == _WifiTransferFlowPhase.completed) {
      return _WifiTransferStepState.completed;
    }
    if (phase == _WifiTransferFlowPhase.stopping) {
      return _WifiTransferStepState.pending;
    }
    if (phase == _WifiTransferFlowPhase.openingHotspot ||
        phase == _WifiTransferFlowPhase.recovering) {
      return index == 0
          ? _WifiTransferStepState.active
          : _WifiTransferStepState.pending;
    }
    if (phase == _WifiTransferFlowPhase.joiningHotspot) {
      if (index == 0) return _WifiTransferStepState.completed;
      return index == 1
          ? _WifiTransferStepState.active
          : _WifiTransferStepState.pending;
    }
    if (index < 2) return _WifiTransferStepState.completed;
    final settling =
        phase == _WifiTransferFlowPhase.verifying ||
        phase == _WifiTransferFlowPhase.registering ||
        phase == _WifiTransferFlowPhase.reconciling;
    if (index == 2) {
      return settling
          ? _WifiTransferStepState.completed
          : _WifiTransferStepState.active;
    }
    return settling
        ? _WifiTransferStepState.active
        : _WifiTransferStepState.pending;
  }

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, child) {
        final batch = _batch;
        final quickState = _quickState;
        final visiblePhase = _visiblePhase(batch, quickState);
        final visibleErrorCode =
            visiblePhase == _WifiTransferFlowPhase.failed ||
                visiblePhase == _WifiTransferFlowPhase.paused
            ? _wifiBatchPrimaryFailureCode(
                batch,
                fallbackCode:
                    quickState?.failureCode ??
                    widget.controller.state.lastErrorCode,
              )
            : null;
        final currentItem = batch?.currentItem;
        final currentTotalBytes = currentItem?.effectiveSizeBytes ?? 0;
        final currentReceivedBytes = (batch?.receivedBytes ?? 0).clamp(
          0,
          currentTotalBytes,
        );
        final currentProgress = currentTotalBytes <= 0
            ? null
            : currentReceivedBytes / currentTotalBytes;
        final rateReady =
            batch?.state == RecordingCardWifiBatchState.transferring &&
            (batch?.rateSampleCount ?? 0) >= 2 &&
            (batch?.bytesPerSecond ?? 0) > 0 &&
            batch?.currentFileEstimatedRemainingSeconds != null &&
            batch?.aggregateEstimatedRemainingSeconds != null;
        final availableHeight = MediaQuery.sizeOf(context).height * .72;
        final sheetHeight = availableHeight < 430.0 ? availableHeight : 430.0;
        return SizedBox(
          key: const ValueKey('recording-card-wifi-flow-sheet'),
          height: sheetHeight,
          child: SafeArea(
            top: false,
            minimum: const EdgeInsets.only(bottom: 18),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(22, 18, 22, 0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Wi-Fi 快速传输',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
                  ),
                  if (!const {
                    _WifiTransferFlowPhase.stopping,
                    _WifiTransferFlowPhase.paused,
                    _WifiTransferFlowPhase.completed,
                    _WifiTransferFlowPhase.failed,
                    _WifiTransferFlowPhase.cancelled,
                  }.contains(visiblePhase)) ...[
                    const SizedBox(height: 12),
                    const _WifiTransferStayNotice(),
                  ],
                  const SizedBox(height: 18),
                  if (batch == null && quickState != null) ...[
                    Text(
                      _quickWifiPreparationLabel(quickState.phase),
                      key: const ValueKey(
                        'recording-card-wifi-flow-preparation',
                      ),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: visiblePhase == _WifiTransferFlowPhase.failed
                            ? colors.danger
                            : colors.muted,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  _WifiTransferStep(
                    key: const ValueKey(
                      'recording-card-wifi-step-open-hotspot',
                    ),
                    icon: Icons.wifi_tethering_rounded,
                    label: visiblePhase == _WifiTransferFlowPhase.recovering
                        ? '核验上次传输'
                        : '打开热点',
                    state: _stepState(0, batch, visiblePhase),
                  ),
                  _WifiTransferStep(
                    key: const ValueKey(
                      'recording-card-wifi-step-connect-hotspot',
                    ),
                    icon: Icons.wifi_rounded,
                    label: '连接热点',
                    state: _stepState(1, batch, visiblePhase),
                  ),
                  _WifiTransferStep(
                    key: const ValueKey('recording-card-wifi-step-transfer'),
                    icon: Icons.swap_vert_rounded,
                    label: '开始传输',
                    state: _stepState(2, batch, visiblePhase),
                  ),
                  _WifiTransferStep(
                    key: const ValueKey('recording-card-wifi-step-finished'),
                    icon: Icons.task_alt_rounded,
                    label: visiblePhase == _WifiTransferFlowPhase.reconciling
                        ? '恢复连接并核验'
                        : '校验并入库',
                    state: _stepState(3, batch, visiblePhase),
                  ),
                  const SizedBox(height: 12),
                  if (visiblePhase == _WifiTransferFlowPhase.joiningHotspot)
                    const _WifiFlowNotice(
                      icon: Icons.shield_outlined,
                      text: '系统可能询问本地网络访问或加入热点，请点击“允许”或“加入”。',
                    ),
                  if (batch != null &&
                      (visiblePhase == _WifiTransferFlowPhase.transferring ||
                          visiblePhase == _WifiTransferFlowPhase.verifying ||
                          visiblePhase == _WifiTransferFlowPhase.registering ||
                          visiblePhase == _WifiTransferFlowPhase.reconciling ||
                          visiblePhase == _WifiTransferFlowPhase.paused ||
                          visiblePhase == _WifiTransferFlowPhase.completed ||
                          visiblePhase == _WifiTransferFlowPhase.failed ||
                          visiblePhase ==
                              _WifiTransferFlowPhase.cancelled)) ...[
                    const SizedBox(height: 14),
                    LinearProgressIndicator(
                      key: const ValueKey('recording-card-wifi-flow-progress'),
                      value: _wifiBatchProgressValue(batch),
                      minHeight: 5,
                      borderRadius: BorderRadius.circular(3),
                      color: colors.primary,
                      backgroundColor: colors.line,
                    ),
                    const SizedBox(height: 7),
                    Text(
                      '已同步 ${batch.completedCount} 条 · '
                      '未同步 ${batch.remainingCount} 条 · '
                      '${_formatBytes(batch.aggregateReceivedBytes)} / '
                      '${_formatBytes(batch.totalBytes)}',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: colors.muted, fontSize: 12),
                    ),
                    if (visiblePhase ==
                        _WifiTransferFlowPhase.transferring) ...[
                      const SizedBox(height: 7),
                      Text(
                        currentItem == null
                            ? '正在准备当前文件'
                            : '${currentItem.file.deviceFilename} · '
                                  '${_formatBytes(currentReceivedBytes)} / '
                                  '${_formatBytes(currentTotalBytes)}'
                                  '${currentProgress == null ? '' : ' · ${(currentProgress * 100).round().clamp(0, 100)}%'}',
                        key: const ValueKey(
                          'recording-card-wifi-flow-current-file',
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: colors.text, fontSize: 11.5),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        rateReady
                            ? '${_formatBytes(batch.bytesPerSecond!.round())}/s · '
                                  '当前剩余 ${_displayBatchEta(batch.currentFileEstimatedRemainingSeconds!)} · '
                                  '整批剩余 ${_displayBatchEta(batch.aggregateEstimatedRemainingSeconds!)}'
                            : '正在测算',
                        key: const ValueKey('recording-card-wifi-flow-rate'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: colors.muted, fontSize: 11.5),
                      ),
                    ] else if (visiblePhase ==
                            _WifiTransferFlowPhase.verifying ||
                        visiblePhase == _WifiTransferFlowPhase.registering ||
                        visiblePhase == _WifiTransferFlowPhase.reconciling) ...[
                      const SizedBox(height: 5),
                      Text(
                        _wifiSettlingLabel(visiblePhase),
                        key: const ValueKey(
                          'recording-card-wifi-flow-settling',
                        ),
                        textAlign: TextAlign.center,
                        style: TextStyle(color: colors.muted, fontSize: 11.5),
                      ),
                    ],
                  ],
                  if (visibleErrorCode != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      _wifiFlowFailureMessage(visibleErrorCode, batch: batch),
                      key: const ValueKey('recording-card-wifi-flow-error'),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: colors.danger,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                  const SizedBox(height: 18),
                  _buildActions(visiblePhase, batch),
                  if (batch != null && !batch.isTerminal)
                    TextButton(
                      key: const ValueKey('recording-card-wifi-flow-later'),
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('稍后查看'),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  _WifiTransferFlowPhase _visiblePhase(
    RecordingCardWifiBatchSnapshot? batch,
    RecordingCardQuickWifiState? quickState,
  ) {
    if (batch == null) {
      return switch (quickState?.phase) {
        RecordingCardQuickWifiPhase.preparingHandoff =>
          _WifiTransferFlowPhase.preparingHandoff,
        RecordingCardQuickWifiPhase.refreshingDirectory =>
          _WifiTransferFlowPhase.refreshingDirectory,
        RecordingCardQuickWifiPhase.persistingPlan =>
          _WifiTransferFlowPhase.persistingPlan,
        RecordingCardQuickWifiPhase.openingHotspot =>
          _WifiTransferFlowPhase.openingHotspot,
        RecordingCardQuickWifiPhase.joiningHotspot =>
          _WifiTransferFlowPhase.joiningHotspot,
        RecordingCardQuickWifiPhase.transferring =>
          _WifiTransferFlowPhase.transferring,
        RecordingCardQuickWifiPhase.verifying =>
          _WifiTransferFlowPhase.verifying,
        RecordingCardQuickWifiPhase.registering =>
          _WifiTransferFlowPhase.registering,
        RecordingCardQuickWifiPhase.reconciling =>
          _WifiTransferFlowPhase.reconciling,
        RecordingCardQuickWifiPhase.stopping => _WifiTransferFlowPhase.stopping,
        RecordingCardQuickWifiPhase.paused => _WifiTransferFlowPhase.paused,
        RecordingCardQuickWifiPhase.completed =>
          _WifiTransferFlowPhase.completed,
        RecordingCardQuickWifiPhase.failed => _WifiTransferFlowPhase.failed,
        RecordingCardQuickWifiPhase.cancelled ||
        RecordingCardQuickWifiPhase.idle ||
        null => _WifiTransferFlowPhase.cancelled,
      };
    }
    return switch (batch.operationPhase) {
      RecordingCardWifiOperationPhase.recovering =>
        _WifiTransferFlowPhase.recovering,
      RecordingCardWifiOperationPhase.preparingHotspot =>
        _WifiTransferFlowPhase.openingHotspot,
      RecordingCardWifiOperationPhase.joiningHotspot =>
        _WifiTransferFlowPhase.joiningHotspot,
      RecordingCardWifiOperationPhase.stopping =>
        _WifiTransferFlowPhase.stopping,
      RecordingCardWifiOperationPhase.idle => switch (batch.state) {
        RecordingCardWifiBatchState.queued =>
          _WifiTransferFlowPhase.openingHotspot,
        RecordingCardWifiBatchState.awaitingHotspot =>
          _WifiTransferFlowPhase.joiningHotspot,
        RecordingCardWifiBatchState.openingSession ||
        RecordingCardWifiBatchState.transferring =>
          _WifiTransferFlowPhase.transferring,
        RecordingCardWifiBatchState.verifying =>
          _WifiTransferFlowPhase.verifying,
        RecordingCardWifiBatchState.registering =>
          _WifiTransferFlowPhase.registering,
        RecordingCardWifiBatchState.reconciling =>
          _WifiTransferFlowPhase.reconciling,
        RecordingCardWifiBatchState.paused => _WifiTransferFlowPhase.paused,
        RecordingCardWifiBatchState.completed =>
          _WifiTransferFlowPhase.completed,
        RecordingCardWifiBatchState.failed => _WifiTransferFlowPhase.failed,
        RecordingCardWifiBatchState.cancelled =>
          _WifiTransferFlowPhase.cancelled,
      },
    };
  }

  Widget _buildActions(
    _WifiTransferFlowPhase phase,
    RecordingCardWifiBatchSnapshot? batch,
  ) {
    if (batch == null) {
      if (phase == _WifiTransferFlowPhase.failed) {
        if (_quickState?.canRetry != true) {
          return OutlinedButton(
            key: const ValueKey('recording-card-wifi-flow-preparation-close'),
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('稍后处理'),
          );
        }
        return Row(
          children: [
            Expanded(
              child: OutlinedButton(
                key: const ValueKey(
                  'recording-card-wifi-flow-preparation-close',
                ),
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('稍后处理'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton.icon(
                key: const ValueKey(
                  'recording-card-wifi-flow-preparation-retry',
                ),
                onPressed: _retry,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('重试'),
              ),
            ),
          ],
        );
      }
      if (phase == _WifiTransferFlowPhase.completed) {
        return FilledButton(
          key: const ValueKey('recording-card-wifi-flow-done'),
          onPressed: () =>
              Navigator.of(context).pop(V3WifiTransferFlowResult.completed),
          child: const Text('完成'),
        );
      }
      return OutlinedButton(
        key: const ValueKey('recording-card-wifi-flow-later'),
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('稍后查看'),
      );
    }
    if (batch.state == RecordingCardWifiBatchState.cancelled) {
      return OutlinedButton(
        key: const ValueKey('recording-card-wifi-flow-cancelled-close'),
        onPressed: () =>
            Navigator.of(context).pop(V3WifiTransferFlowResult.cancelled),
        child: const Text('关闭'),
      );
    }
    if (batch.state == RecordingCardWifiBatchState.completed &&
        batch.remainingCount == 0) {
      return FilledButton(
        key: const ValueKey('recording-card-wifi-flow-done'),
        onPressed: batch.isBusy
            ? null
            : () =>
                  Navigator.of(context).pop(V3WifiTransferFlowResult.completed),
        child: Text(batch.isBusy ? '正在恢复连接' : '完成'),
      );
    }
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            key: ValueKey(
              batch.state == RecordingCardWifiBatchState.paused
                  ? 'recording-card-wifi-flow-paused-stop'
                  : 'recording-card-wifi-flow-stop',
            ),
            onPressed: batch.canFinish ? _cancel : null,
            icon: const Icon(Icons.stop_circle_outlined),
            label: Text(
              phase == _WifiTransferFlowPhase.stopping ? '正在结束' : '结束本批',
            ),
          ),
        ),
        if (batch.canContinue || batch.canRetryFailed) ...[
          const SizedBox(width: 10),
          Expanded(
            child: FilledButton.icon(
              key: ValueKey(
                batch.canRetryFailed
                    ? 'recording-card-wifi-flow-retry'
                    : 'recording-card-wifi-flow-resume',
              ),
              onPressed: _retry,
              icon: const Icon(Icons.play_arrow_rounded),
              label: Text(batch.canRetryFailed ? '重试失败项' : '继续'),
            ),
          ),
        ],
      ],
    );
  }
}

String _quickWifiPreparationLabel(RecordingCardQuickWifiPhase phase) {
  return switch (phase) {
    RecordingCardQuickWifiPhase.preparingHandoff => '正在停止当前蓝牙传输',
    RecordingCardQuickWifiPhase.refreshingDirectory => '正在刷新文件目录',
    RecordingCardQuickWifiPhase.persistingPlan => '正在保存传输计划',
    RecordingCardQuickWifiPhase.completed => '同步与文件核验已完成',
    RecordingCardQuickWifiPhase.failed => '快速传输未能开始',
    RecordingCardQuickWifiPhase.cancelled => '快速传输已结束',
    _ => '正在准备 Wi-Fi 快速传输',
  };
}

String _wifiSettlingLabel(_WifiTransferFlowPhase phase) {
  return switch (phase) {
    _WifiTransferFlowPhase.verifying => '正在校验当前文件',
    _WifiTransferFlowPhase.registering => '正在保存到录音文件库',
    _WifiTransferFlowPhase.reconciling => '正在恢复蓝牙并复核文件目录',
    _ => '',
  };
}

class _WifiTransferStep extends StatelessWidget {
  const _WifiTransferStep({
    required this.icon,
    required this.label,
    required this.state,
    super.key,
  });

  final IconData icon;
  final String label;
  final _WifiTransferStepState state;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return SizedBox(
      height: 50,
      child: Row(
        children: [
          Icon(icon, size: 22, color: colors.ink),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
            ),
          ),
          _WifiTransferStepIndicator(state: state),
        ],
      ),
    );
  }
}

class _WifiTransferStepIndicator extends StatelessWidget {
  const _WifiTransferStepIndicator({required this.state});

  final _WifiTransferStepState state;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return SizedBox.square(
      dimension: 22,
      child: switch (state) {
        _WifiTransferStepState.active => CircularProgressIndicator(
          strokeWidth: 2,
          color: colors.primary,
        ),
        _WifiTransferStepState.completed => DecoratedBox(
          decoration: BoxDecoration(
            color: colors.primary,
            shape: BoxShape.circle,
          ),
          child: Icon(Icons.check_rounded, color: colors.onPrimary, size: 15),
        ),
        _WifiTransferStepState.failed => Icon(
          Icons.error_rounded,
          color: colors.danger,
          size: 22,
        ),
        _WifiTransferStepState.paused => const Icon(
          Icons.pause_circle_outline_rounded,
          color: Color(0xFFA06F28),
          size: 22,
        ),
        _WifiTransferStepState.cancelled => Icon(
          Icons.cancel_outlined,
          color: colors.muted,
          size: 22,
        ),
        _WifiTransferStepState.pending => DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: colors.line, width: 1.5),
          ),
        ),
      },
    );
  }
}

class _WifiFlowNotice extends StatelessWidget {
  const _WifiFlowNotice({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 17, color: colors.muted),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: TextStyle(color: colors.muted, fontSize: 12, height: 1.4),
          ),
        ),
      ],
    );
  }
}

class V3RecordingLeadingControl extends StatelessWidget {
  const V3RecordingLeadingControl({
    required this.batchMode,
    required this.selected,
    this.icon = Icons.play_arrow_rounded,
    this.enabled = true,
    super.key,
  });

  final bool batchMode;
  final bool selected;
  final IconData icon;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return V3LiquidGlassSurface(
      borderRadius: 17,
      tone: selected ? V3GlassTone.warm : V3GlassTone.neutral,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: selected ? colors.primary.withValues(alpha: .88) : null,
          shape: BoxShape.circle,
        ),
        child: SizedBox.square(
          dimension: 34,
          child: Icon(
            batchMode
                ? (selected
                      ? Icons.check_rounded
                      : Icons.radio_button_unchecked_rounded)
                : icon,
            size: 20,
            color: selected
                ? colors.onPrimary
                : enabled
                ? colors.ink
                : colors.muted,
          ),
        ),
      ),
    );
  }
}

String _wifiBatchStateLabel(RecordingCardWifiBatchState state) {
  return switch (state) {
    RecordingCardWifiBatchState.queued => '等待中',
    RecordingCardWifiBatchState.awaitingHotspot => '等待连接热点',
    RecordingCardWifiBatchState.openingSession => '正在建立连接',
    RecordingCardWifiBatchState.transferring => '传输中',
    RecordingCardWifiBatchState.verifying => '已传输',
    RecordingCardWifiBatchState.registering => '正在入库',
    RecordingCardWifiBatchState.reconciling => '正在恢复蓝牙并复核',
    RecordingCardWifiBatchState.paused => '已暂停',
    RecordingCardWifiBatchState.completed => '已完成',
    RecordingCardWifiBatchState.failed => '同步失败',
    RecordingCardWifiBatchState.cancelled => '已取消',
  };
}

double? _wifiBatchProgressValue(RecordingCardWifiBatchSnapshot batch) {
  if (batch.state == RecordingCardWifiBatchState.completed) return 1;
  if (batch.isActive) return batch.fraction;
  final byteProgress = batch.fraction;
  if (byteProgress != null) return byteProgress;
  if (batch.totalCount <= 0) return 0;
  return (batch.completedCount / batch.totalCount).clamp(0, 1).toDouble();
}

String? _wifiBatchPrimaryFailureCode(
  RecordingCardWifiBatchSnapshot? batch, {
  String? fallbackCode,
}) {
  final candidates = <String?>[
    batch?.failureCode,
    ...?batch?.items.map((item) => item.errorCode),
    fallbackCode,
  ];
  for (final candidate in candidates) {
    final normalized = candidate?.trim();
    if (normalized != null && normalized.isNotEmpty) return normalized;
  }
  return null;
}

int _wifiBatchFailureStep(
  RecordingCardWifiBatchSnapshot? batch, {
  String? fallbackCode,
}) {
  if (batch?.state == RecordingCardWifiBatchState.registering ||
      batch?.state == RecordingCardWifiBatchState.reconciling) {
    return 3;
  }
  final code =
      _wifiBatchPrimaryFailureCode(
        batch,
        fallbackCode: fallbackCode,
      )?.toUpperCase() ??
      '';
  if (code.contains('PREPARE') ||
      code.contains('HOTSPOT') ||
      code.contains('CREDENTIAL')) {
    return 0;
  }
  if (code.contains('NETWORK_JOIN') ||
      code.contains('WIFI_JOIN') ||
      code.contains('LOCAL_NETWORK') ||
      code.contains('PERMISSION')) {
    return 1;
  }
  if (code.contains('BLE_RECOVERY') || code.contains('BLE_RECONNECT')) {
    return 3;
  }
  return recordingCardFailureStage(code) == RecordingCardFailureStage.storage
      ? 3
      : 2;
}

String? recordingCardWifiRecoveryMessage(String? errorCode) => switch (errorCode
    ?.toUpperCase()) {
  'RECORDING_CARD_WIFI_PROCESS_INTERRUPTED' => '上次传输中断，已完成文件会保留；点“继续”重新连接录音卡热点',
  'RECORDING_CARD_WIFI_BACKGROUND_EXPIRED' => '系统后台运行时间已用完；回到应用后点“继续”恢复传输',
  'RECORDING_CARD_WIFI_NETWORK_LOST' ||
  'RECORDING_CARD_WIFI_SESSION_UNAVAILABLE' ||
  'RECORDING_CARD_WIFI_SESSION_INTERRUPTED' => '录音卡 Wi-Fi 连接已中断；点“继续”重新开启并加入热点',
  'RECORDING_CARD_WIFI_UNLOCK_REQUIRED' => '请解锁手机后继续，已完成文件不会重复下载',
  'RECORDING_CARD_WIFI_LOCAL_RECOVERY_FAILED' => '本地文件暂时无法核验，请解锁并检查可用存储后继续',
  'RECORDING_CARD_WIFI_BATCH_RECORD_INVALID' => '上次传输记录不完整，无法安全续传；请结束本批后重新选择文件',
  'RECORDING_CARD_WIFI_RECOVERY_FAILED' => '恢复未完成，已完成文件会保留；可继续重试或结束本批',
  'RECORDING_CARD_RECORDING_ACTIVE' => '录音卡正在录音；请等待录音结束后继续传输',
  _ => null,
};

String _wifiFlowFailureMessage(
  String errorCode, {
  RecordingCardWifiBatchSnapshot? batch,
}) {
  final recoveryMessage = recordingCardWifiRecoveryMessage(errorCode);
  if (recoveryMessage != null) return recoveryMessage;
  if (batch != null &&
      _wifiBatchPrimaryFailureCode(batch)?.toUpperCase() ==
          errorCode.toUpperCase()) {
    return _wifiBatchFailureTitle(batch);
  }
  final code = errorCode.toUpperCase();
  if (code.contains('PERMISSION') || code.contains('DENIED')) {
    return '请在系统设置中允许本地网络权限后重试';
  }
  if (code.contains('PREPARE') ||
      code.contains('HOTSPOT') ||
      code.contains('CREDENTIAL')) {
    return '未能开启录音卡热点，请重试';
  }
  if (code.contains('NETWORK') ||
      code.contains('WIFI') ||
      code.contains('DISCONNECT') ||
      code.contains('TIMEOUT')) {
    return '未能连接录音卡 Wi-Fi，请检查连接后重试';
  }
  return switch (recordingCardFailureStage(code)) {
    RecordingCardFailureStage.storage => '文件已传输，但保存到本地失败，请重试',
    RecordingCardFailureStage.verification => '文件校验未通过，请重新传输',
    _ => 'Wi-Fi 快速传输未完成，请重试',
  };
}

String _wifiBatchFailureTitle(RecordingCardWifiBatchSnapshot batch) {
  final recoveryMessage = recordingCardWifiRecoveryMessage(batch.failureCode);
  if (recoveryMessage != null) return recoveryMessage;
  final codes = <String>[
    ?batch.failureCode?.trim().toUpperCase(),
    ...batch.items
        .map((item) => item.errorCode?.trim().toUpperCase())
        .whereType<String>(),
  ].where((code) => code.isNotEmpty);
  bool containsAny(Iterable<String> markers) {
    return codes.any((code) => markers.any(code.contains));
  }

  if (containsAny(const <String>[
    'LOCAL_LIBRARY',
    'LOCAL_STORAGE',
    'STORAGE_FULL',
    'DISK',
    'LOCAL_FILE_METADATA',
    'LEDGER',
    'BATCH_CHECKPOINT',
    'BATCH_PERSIST',
    'BATCH_DISMISS',
    'REGISTRATION',
  ])) {
    return '本地保存未完成';
  }
  if (containsAny(const <String>[
    'HASH',
    'VERIFICATION',
    'FORMAT_MISMATCH',
    'DOWNLOAD_INCOMPLETE',
    'CORRUPT',
  ])) {
    return '文件校验失败';
  }
  if (containsAny(const <String>['IDENTITY_RECOVERY_REQUIRED'])) {
    return '请连接原录音卡继续';
  }
  if (containsAny(const <String>[
    'DIRECTORY_CHANGED',
    'CATALOG_CHANGED',
    'FILE_NOT_FOUND',
    'IDENTITY_MISMATCH',
    'SELECTION_STALE',
  ])) {
    return '录音卡文件已变化';
  }
  if (containsAny(const <String>['PERMISSION', 'DENIED'])) {
    return 'Wi-Fi 权限未开启';
  }
  if (containsAny(const <String>['BLE_RECONNECT', 'BLE_RECOVERY'])) {
    return '蓝牙连接恢复失败';
  }
  if (containsAny(const <String>[
    'WIFI_NETWORK',
    'WIFI_JOIN',
    'WIFI_SESSION',
    'WIFI_PREPARE',
    'WIFI_UNAVAILABLE',
    'DISCONNECT',
    'CONNECTION_TIMEOUT',
    'READ_FAILED',
  ])) {
    return 'Wi-Fi 连接失败';
  }
  return '部分文件同步失败';
}

String _displayBatchEta(int seconds) {
  if (seconds < 60) return '${seconds}s';
  final minutes = seconds ~/ 60;
  final remainingSeconds = seconds % 60;
  if (minutes < 60) return '${minutes}m ${remainingSeconds}s';
  final hours = minutes ~/ 60;
  final remainingMinutes = minutes % 60;
  return '${hours}h ${remainingMinutes}m';
}

String _displaySourceLabel(RecordingLibrarySource source) {
  return switch (source) {
    RecordingLibrarySource.localImport => '来源：本地导入',
    RecordingLibrarySource.microphone => '来源：独白',
    RecordingLibrarySource.device => '来源：录音卡',
  };
}

String _displayDateTime(DateTime? date) {
  if (date == null) return '时间未知';
  String two(int value) => value.toString().padLeft(2, '0');
  return '${date.year}-${two(date.month)}-${two(date.day)} '
      '${two(date.hour)}:${two(date.minute)}:${two(date.second)}';
}

String _formatDuration(Duration duration) {
  final seconds = duration.isNegative ? 0 : duration.inSeconds;
  final hours = seconds ~/ 3600;
  final minutes = (seconds % 3600) ~/ 60;
  final rest = seconds % 60;
  String two(int value) => value.toString().padLeft(2, '0');
  return hours > 0
      ? '${two(hours)}:${two(minutes)}:${two(rest)}'
      : '${two(minutes)}:${two(rest)}';
}

String _formatBytes(int bytes) {
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
