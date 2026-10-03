import 'package:huahuo_foundation/huahuo_foundation.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:huahuo_product/huahuo_product.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

enum _RecordingContentView { transcript, minutes, summary }

final class DesktopRecordingLibraryWorkspace extends StatefulWidget {
  const DesktopRecordingLibraryWorkspace({
    required this.workspaceId,
    required this.repository,
    required this.onUploadAudio,
    this.initialRecordingId,
    super.key,
  });

  final String? workspaceId;
  final ProductRecordingsRepository repository;
  final VoidCallback onUploadAudio;
  final String? initialRecordingId;

  @override
  State<DesktopRecordingLibraryWorkspace> createState() =>
      _DesktopRecordingLibraryWorkspaceState();
}

final class _DesktopRecordingLibraryWorkspaceState
    extends State<DesktopRecordingLibraryWorkspace> {
  late ProductRecordingsController _controller;
  _RecordingContentView _contentView = _RecordingContentView.transcript;

  @override
  void initState() {
    super.initState();
    _createController();
  }

  @override
  void didUpdateWidget(DesktopRecordingLibraryWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.repository, widget.repository)) {
      _controller.removeListener(_changed);
      _controller.dispose();
      _createController();
      return;
    }
    if (oldWidget.workspaceId != widget.workspaceId) {
      unawaited(_bind());
    }
  }

  void _createController() {
    _controller = ProductRecordingsController(widget.repository)
      ..addListener(_changed);
    unawaited(_bind());
  }

  Future<void> _bind() async {
    await _controller.bindWorkspace(widget.workspaceId);
    final initial = widget.initialRecordingId?.trim();
    if (initial != null &&
        initial.isNotEmpty &&
        _controller.state.items.any((item) => item.id == initial)) {
      await _controller.select(initial);
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller.removeListener(_changed);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = _controller.state;
    return ColoredBox(
      key: const ValueKey<String>('desktop-recording-library'),
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        children: [
          _TopBar(
            loading: state.status == ProductRecordingsStatus.loading,
            onRefresh: _controller.reload,
            onUpload: widget.onUploadAudio,
          ),
          if (state.errorMessage != null && state.items.isNotEmpty)
            _InlineError(
              message: state.errorMessage!,
              onRetry: state.selectedId == null
                  ? _controller.reload
                  : () => _controller.select(state.selectedId!),
            ),
          Expanded(child: _body(state)),
        ],
      ),
    );
  }

  Widget _body(ProductRecordingsState state) {
    if (state.status == ProductRecordingsStatus.idle) {
      return const _CenteredState(
        icon: LucideIcons.lockKeyhole,
        title: 'Workspace 尚未就绪',
        detail: '登录并选择 Workspace 后查看云端录音。',
      );
    }
    if (state.status == ProductRecordingsStatus.loading &&
        state.items.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.status == ProductRecordingsStatus.failure &&
        state.items.isEmpty) {
      return _CenteredState(
        icon: LucideIcons.cloudOff,
        title: '录音文件库加载失败',
        detail: state.errorMessage ?? '暂时无法读取云端录音。',
        action: OutlinedButton.icon(
          key: const ValueKey<String>('recordings-retry'),
          onPressed: _controller.reload,
          icon: const Icon(LucideIcons.refreshCw, size: 16),
          label: const Text('重试'),
        ),
      );
    }
    if (state.items.isEmpty) {
      return _CenteredState(
        icon: LucideIcons.audioLines,
        title: '暂无云端录音',
        detail: '上传已有音频后，转写和整理状态会显示在这里。',
        action: FilledButton.icon(
          key: const ValueKey<String>('recordings-empty-upload'),
          onPressed: widget.onUploadAudio,
          icon: const Icon(LucideIcons.upload, size: 16),
          label: const Text('上传音频'),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 760;
        final list = _RecordingList(controller: _controller, state: state);
        final detail = _RecordingDetailPane(
          controller: _controller,
          state: state,
          contentView: _contentView,
          onContentViewChanged: (value) => setState(() => _contentView = value),
        );
        if (compact) {
          return state.selectedId == null
              ? list
              : Column(
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        key: const ValueKey<String>('recordings-back'),
                        onPressed: () => setState(() {
                          _controller.resetSelectionForView();
                        }),
                        icon: const Icon(LucideIcons.arrowLeft, size: 16),
                        label: const Text('录音列表'),
                      ),
                    ),
                    Expanded(child: detail),
                  ],
                );
        }
        return Row(
          children: [
            SizedBox(width: 310, child: list),
            VerticalDivider(width: 1, color: Theme.of(context).dividerColor),
            Expanded(child: detail),
          ],
        );
      },
    );
  }
}

final class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.loading,
    required this.onRefresh,
    required this.onUpload,
  });

  final bool loading;
  final VoidCallback onRefresh;
  final VoidCallback onUpload;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 52,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18),
      child: Row(
        children: [
          const Icon(LucideIcons.audioLines, size: 17),
          const SizedBox(width: 9),
          Text('录音文件库', style: Theme.of(context).textTheme.titleMedium),
          const Spacer(),
          IconButton(
            key: const ValueKey<String>('recordings-refresh'),
            tooltip: '刷新录音',
            onPressed: loading ? null : onRefresh,
            icon: loading
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(LucideIcons.refreshCw, size: 16),
          ),
          const SizedBox(width: 4),
          FilledButton.icon(
            key: const ValueKey<String>('recordings-upload'),
            onPressed: onUpload,
            icon: const Icon(LucideIcons.upload, size: 16),
            label: const Text('上传音频'),
          ),
        ],
      ),
    ),
  );
}

final class _RecordingList extends StatelessWidget {
  const _RecordingList({required this.controller, required this.state});

  final ProductRecordingsController controller;
  final ProductRecordingsState state;

  @override
  Widget build(BuildContext context) => ListView.separated(
    padding: const EdgeInsets.symmetric(vertical: 8),
    itemCount: state.items.length,
    separatorBuilder: (_, _) => const Divider(height: 1),
    itemBuilder: (context, index) {
      final item = state.items[index];
      final selected = item.id == state.selectedId;
      return Material(
        color: Colors.transparent,
        child: ListTile(
          key: ValueKey<String>('recording-item-${item.id}'),
          selected: selected,
          leading: Icon(
            item.requiresSpeakerLabels
                ? LucideIcons.userRoundPen
                : _statusIcon(item.transcriptStatus),
            size: 18,
          ),
          title: Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            _statusLabel(item.transcriptStatus),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: const Icon(LucideIcons.chevronRight, size: 15),
          onTap: () => controller.select(item.id),
        ),
      );
    },
  );
}

final class _RecordingDetailPane extends StatelessWidget {
  const _RecordingDetailPane({
    required this.controller,
    required this.state,
    required this.contentView,
    required this.onContentViewChanged,
  });

  final ProductRecordingsController controller;
  final ProductRecordingsState state;
  final _RecordingContentView contentView;
  final ValueChanged<_RecordingContentView> onContentViewChanged;

  @override
  Widget build(BuildContext context) {
    if (state.selectedId == null) {
      return const _CenteredState(
        icon: LucideIcons.panelRightOpen,
        title: '选择一条录音',
        detail: '查看完整转写、纲要、摘要和说话人状态。',
      );
    }
    if (state.detailStatus == ProductRecordingDetailStatus.loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.detailStatus == ProductRecordingDetailStatus.failure ||
        state.detail == null) {
      return _CenteredState(
        icon: LucideIcons.triangleAlert,
        title: '录音详情加载失败',
        detail: state.errorMessage ?? '暂时无法读取录音详情。',
        action: OutlinedButton.icon(
          key: const ValueKey<String>('recording-detail-retry'),
          onPressed: () => controller.select(state.selectedId!),
          icon: const Icon(LucideIcons.refreshCw, size: 16),
          label: const Text('重试'),
        ),
      );
    }
    final detail = state.detail!;
    final content = switch (contentView) {
      _RecordingContentView.transcript => detail.transcript,
      _RecordingContentView.minutes => detail.minutesMarkdown,
      _RecordingContentView.summary => detail.summary,
    };
    return ListView(
      key: const ValueKey<String>('recording-detail'),
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 40),
      children: [
        Text(
          detail.recording.title,
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _StatusChip(label: _statusLabel(detail.recording.transcriptStatus)),
            _StatusChip(
              label: '纲要 ${_statusLabel(detail.recording.minutesStatus)}',
            ),
            _StatusChip(
              label: '沉淀 ${_statusLabel(detail.recording.depositStatus)}',
            ),
          ],
        ),
        if (detail.asrTask?.progress case final progress?) ...[
          const SizedBox(height: 14),
          LinearProgressIndicator(value: progress / 100),
        ],
        const SizedBox(height: 22),
        SegmentedButton<_RecordingContentView>(
          key: const ValueKey<String>('recording-content-tabs'),
          segments: const [
            ButtonSegment(
              value: _RecordingContentView.transcript,
              icon: Icon(LucideIcons.text, size: 15),
              label: Text('转写'),
            ),
            ButtonSegment(
              value: _RecordingContentView.minutes,
              icon: Icon(LucideIcons.listTree, size: 15),
              label: Text('纲要'),
            ),
            ButtonSegment(
              value: _RecordingContentView.summary,
              icon: Icon(LucideIcons.sparkles, size: 15),
              label: Text('摘要'),
            ),
          ],
          selected: {contentView},
          onSelectionChanged: (values) => onContentViewChanged(values.single),
        ),
        const SizedBox(height: 16),
        SelectionArea(
          contextMenuBuilder: HuahuoTextEditing.buildSelectableContextMenu,
          child: SelectionArea(
            contextMenuBuilder: HuahuoTextEditing.buildSelectableContextMenu,
            child: HuahuoMarkdown(
              source: content?.trim().isNotEmpty == true
                  ? content!
                  : '该内容尚未生成。',
              key: const ValueKey<String>('recording-content'),
              contextMenuBuilder: HuahuoTextEditing.buildEditableContextMenu,
            ),
          ),
        ),
        if (state.speakerPanel case final panel?) ...[
          const SizedBox(height: 28),
          const Divider(),
          const SizedBox(height: 18),
          _SpeakerEditor(
            controller: controller,
            panel: panel,
            busy: state.busyAction != null,
          ),
        ],
        if (detail.retryActions.isNotEmpty) ...[
          const SizedBox(height: 28),
          Text('恢复操作', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final action in detail.retryActions)
                OutlinedButton.icon(
                  key: ValueKey<String>('recording-retry-${action.stage}'),
                  onPressed: state.busyAction == null
                      ? () => controller.retryStage(action.stage)
                      : null,
                  icon: const Icon(LucideIcons.rotateCcw, size: 15),
                  label: Text(action.title),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

final class _SpeakerEditor extends StatelessWidget {
  const _SpeakerEditor({
    required this.controller,
    required this.panel,
    required this.busy,
  });

  final ProductRecordingsController controller;
  final ProductSpeakerPanel panel;
  final bool busy;

  @override
  Widget build(BuildContext context) => RadioGroup<String>(
    groupValue: panel.selfSpeakerId,
    onChanged: (value) {
      if (!busy && value != null) controller.selectSelfSpeaker(value);
    },
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('说话人标注', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 6),
        Text(panel.reason ?? '为每位说话人命名，并选择哪一位是你。'),
        const SizedBox(height: 14),
        for (final speaker in panel.speakers) ...[
          Row(
            children: [
              Radio<String>(
                key: ValueKey<String>('speaker-self-${speaker.id}'),
                value: speaker.id,
                enabled: !busy,
              ),
              Expanded(
                child: TextFormField(
                  key: ValueKey<String>('speaker-name-${speaker.id}'),
                  contextMenuBuilder:
                      HuahuoTextEditing.buildEditableContextMenu,
                  initialValue:
                      panel.names[speaker.id] ??
                      speaker.currentName ??
                      speaker.displayName,
                  enabled: !busy,
                  maxLength: 80,
                  decoration: InputDecoration(
                    labelText: speaker.displayName,
                    helperText: speaker.samples.firstOrNull,
                    counterText: '',
                  ),
                  onChanged: (value) =>
                      controller.updateSpeakerName(speaker.id, value),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
        ],
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            OutlinedButton.icon(
              key: const ValueKey<String>('speaker-save-draft'),
              onPressed: busy ? null : controller.saveSpeakerDraft,
              icon: const Icon(LucideIcons.save, size: 15),
              label: const Text('保存草稿'),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              key: const ValueKey<String>('speaker-submit'),
              onPressed: busy || !panel.isComplete
                  ? null
                  : controller.submitSpeakerLabels,
              icon: const Icon(LucideIcons.check, size: 15),
              label: Text(busy ? '处理中' : '确认并继续'),
            ),
          ],
        ),
      ],
    ),
  );
}

final class _CenteredState extends StatelessWidget {
  const _CenteredState({
    required this.icon,
    required this.title,
    required this.detail,
    this.action,
  });

  final IconData icon;
  final String title;
  final String detail;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 380),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 30),
            const SizedBox(height: 14),
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(detail, textAlign: TextAlign.center),
            if (action != null) ...[const SizedBox(height: 18), action!],
          ],
        ),
      ),
    ),
  );
}

final class _InlineError extends StatelessWidget {
  const _InlineError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.errorContainer,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
      child: Row(
        children: [
          const Icon(LucideIcons.triangleAlert, size: 16),
          const SizedBox(width: 8),
          Expanded(child: Text(message)),
          TextButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    ),
  );
}

final class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(6),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Text(label, style: Theme.of(context).textTheme.labelMedium),
    ),
  );
}

IconData _statusIcon(String status) => switch (status) {
  'completed' || 'succeeded' => LucideIcons.circleCheck,
  'failed' || 'timeout' => LucideIcons.circleAlert,
  _ => LucideIcons.loaderCircle,
};

String _statusLabel(String status) => switch (status) {
  'not_started' => '未开始',
  'queued' || 'pending' || 'created' => '等待处理',
  'processing' || 'running' || 'asr_running' => '处理中',
  'speaker_label_pending' || 'speaker_labeling' || 'transcribed' => '待标注说话人',
  'completed' || 'succeeded' || 'deposited' => '已完成',
  'failed' => '失败',
  'timeout' => '超时',
  'cancelled' || 'canceled' => '已取消',
  _ => status,
};
