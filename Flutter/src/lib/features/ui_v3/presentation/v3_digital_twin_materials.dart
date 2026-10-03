part of 'v3_digital_twin_page.dart';

extension _DigitalTwinMaterials on _V3DigitalTwinPageState {
  Widget _materialQueueButton() => Consumer(
    builder: (context, ref, _) {
      final queue = ref.watch(digitalTwinMaterialControllerProvider);
      final visibleProposalIds = _controller.state.reviews
          .map((review) => review.snapshot.proposal.proposalId)
          .toSet();
      final active = queue.items
          .where(
            (item) =>
                !item.isTerminal &&
                !(item.status == DigitalTwinMaterialStatus.reviewReady &&
                    item.proposalIds.values.every(visibleProposalIds.contains)),
          )
          .toList();
      if (active.isEmpty && queue.errorCode == null) {
        return const SizedBox.shrink();
      }
      final pending = active
          .where(
            (item) =>
                item.status == DigitalTwinMaterialStatus.awaitingConfirmation,
          )
          .length;
      final working = active
          .where(
            (item) => const {
              DigitalTwinMaterialStatus.submitting,
              DigitalTwinMaterialStatus.generating,
              DigitalTwinMaterialStatus.waitingSource,
            }.contains(item.status),
          )
          .length;
      final label = pending > 0
          ? '$pending 份资料待确认'
          : working > 0
          ? '$working 份材料处理中'
          : '${active.length} 份材料待审核';
      return Padding(
        padding: const EdgeInsets.fromLTRB(22, 8, 22, 12),
        child: FilledButton(
          key: const ValueKey('digital-twin-material-queue'),
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF30243F),
            foregroundColor: const Color(0xFFF7F1FF),
            minimumSize: const Size(double.infinity, 52),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          onPressed: _showMaterialQueue,
          child: Row(
            children: [
              const Icon(
                Icons.auto_awesome_rounded,
                color: Color(0xFFFF9B89),
                size: 20,
              ),
              Expanded(
                child: Text(
                  queue.errorCode == null ? label : '材料状态待核验',
                  textAlign: TextAlign.center,
                ),
              ),
              const Icon(Icons.arrow_forward_rounded, size: 19),
            ],
          ),
        ),
      );
    },
  );

  Future<void> _showMaterialQueue({String? focusMaterialId}) async {
    unawaited(_materials.refresh());
    final selected = _materials.items
        .where(
          (item) =>
              item.status == DigitalTwinMaterialStatus.awaitingConfirmation,
        )
        .map((item) => item.id)
        .toSet();
    var fullscreen = focusMaterialId != null;
    String? expandedItem = focusMaterialId;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: .56),
      builder: (sheetContext) => _TwinMaterialSheetActivity(
        child: StatefulBuilder(
          builder: (context, updateSheet) => Consumer(
            builder: (context, ref, _) {
              final queue = ref.watch(digitalTwinMaterialControllerProvider);
              final items = queue.items
                  .where(
                    (item) => item.status != DigitalTwinMaterialStatus.removed,
                  )
                  .toList();
              final pending = items
                  .where(
                    (item) =>
                        item.status ==
                            DigitalTwinMaterialStatus.awaitingConfirmation &&
                        selected.contains(item.id),
                  )
                  .toList();
              final media = MediaQuery.of(context);
              final available = media.size.height - media.padding.top;
              return Theme(
                data: _twinTheme(context),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 280),
                  height: fullscreen
                      ? available
                      : math.min(
                          414 + (expandedItem == null ? 0 : 120),
                          available,
                        ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1A1A1A),
                    borderRadius: BorderRadius.vertical(
                      top: Radius.circular(fullscreen ? 0 : 24),
                    ),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 12, 20, 6),
                        child: Row(
                          children: [
                            _TwinIconAction(
                              icon: Icons.close_rounded,
                              label: '关闭',
                              onPressed: () => Navigator.pop(sheetContext),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                '资料待确认',
                                style: _twinText(18, weight: FontWeight.w500),
                              ),
                            ),
                            _TwinIconAction(
                              icon: fullscreen
                                  ? Icons.close_fullscreen_rounded
                                  : Icons.open_in_full_rounded,
                              label: fullscreen ? '收起' : '展开',
                              onPressed: () =>
                                  updateSheet(() => fullscreen = !fullscreen),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: ListView(
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          children: [
                            const _TwinAgentMessage(
                              text: '选择要纳入的资料。开始蒸馏后会生成可审阅的文件修改，不会直接改动正式版本。',
                            ),
                            const SizedBox(height: 14),
                            if (items.any(
                              (item) => const {
                                DigitalTwinMaterialStatus.waitingSource,
                                DigitalTwinMaterialStatus.submitting,
                                DigitalTwinMaterialStatus.generating,
                                DigitalTwinMaterialStatus
                                    .awaitingVersionVerification,
                              }.contains(item.status),
                            )) ...[
                              V3LongRunningTaskNotice(
                                onReturn: () =>
                                    Navigator.of(sheetContext).pop(),
                              ),
                              const SizedBox(height: 14),
                            ],
                            if (queue.isSubmitting)
                              const LinearProgressIndicator(color: _twinPurple),
                            if (queue.errorCode != null ||
                                queue.observationPaused)
                              _TwinRetryNotice(
                                text:
                                    queue.errorCode ==
                                        'DIGITAL_TWIN_QUEUE_SAVE_FAILED'
                                    ? '本地材料状态保存失败，原任务已保留，请重试保存'
                                    : '材料状态待核验，原任务已保留',
                                detail: queue.errorCode == null
                                    ? null
                                    : _materialErrorText(queue.errorCode!),
                                onRetry: queue.isSubmitting
                                    ? null
                                    : queue.refresh,
                              ),
                            if (items.isEmpty)
                              Text(
                                '暂无排队资料，可从笔记或导入入口加入。',
                                style: _twinText(12, color: _twinMuted),
                              ),
                            for (final item in items) ...[
                              InkWell(
                                key: ValueKey(
                                  'digital-twin-queue-item-${item.referenceId}',
                                ),
                                onTap: () => updateSheet(
                                  () => expandedItem = expandedItem == item.id
                                      ? null
                                      : item.id,
                                ),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 10,
                                  ),
                                  decoration: const BoxDecoration(
                                    border: Border(
                                      bottom: BorderSide(
                                        color: Color(0x55343434),
                                      ),
                                    ),
                                  ),
                                  child: Row(
                                    children: [
                                      if (item.status ==
                                          DigitalTwinMaterialStatus
                                              .awaitingConfirmation)
                                        SizedBox(
                                          width: 28,
                                          height: 32,
                                          child: Checkbox(
                                            value: selected.contains(item.id),
                                            activeColor: _twinPurple,
                                            onChanged: queue.isSubmitting
                                                ? null
                                                : (checked) => updateSheet(() {
                                                    checked == true
                                                        ? selected.add(item.id)
                                                        : selected.remove(
                                                            item.id,
                                                          );
                                                  }),
                                          ),
                                        )
                                      else
                                        Icon(
                                          item.status ==
                                                  DigitalTwinMaterialStatus
                                                      .completed
                                              ? Icons
                                                    .check_circle_outline_rounded
                                              : Icons.description_outlined,
                                          size: 18,
                                          color: _twinPurple,
                                        ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              item.title,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: _twinText(
                                                14,
                                                weight: FontWeight.w500,
                                              ),
                                            ),
                                            Text(
                                              _materialStatusText(item),
                                              style: _twinText(
                                                10,
                                                color: _twinMuted,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Icon(
                                        expandedItem == item.id
                                            ? Icons.expand_less_rounded
                                            : Icons.expand_more_rounded,
                                        size: 18,
                                        color: _twinMuted,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              if (expandedItem == item.id)
                                Padding(
                                  padding: const EdgeInsets.only(
                                    left: 34,
                                    top: 6,
                                    bottom: 6,
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      if (item.errorCode != null)
                                        Text(
                                          _materialErrorText(item.errorCode!),
                                          style: _twinText(
                                            10,
                                            color: _compactTwinWarm,
                                          ),
                                        ),
                                      Wrap(
                                        spacing: 8,
                                        children: [
                                          TextButton(
                                            onPressed: () {
                                              Navigator.pop(sheetContext);
                                              _openMaterialSource(item);
                                            },
                                            child: const Text('查看来源'),
                                          ),
                                          if (item.canRemove)
                                            TextButton(
                                              onPressed: queue.isSubmitting
                                                  ? null
                                                  : () => queue.remove(item.id),
                                              child: const Text('移出队列'),
                                            ),
                                          if (item.proposalIds.isNotEmpty)
                                            TextButton(
                                              onPressed: () {
                                                Navigator.pop(sheetContext);
                                                unawaited(
                                                  _openMaterialReview(item),
                                                );
                                              },
                                              child: const Text('查看文件修改'),
                                            ),
                                          if (item.canSubmit &&
                                              item.status !=
                                                  DigitalTwinMaterialStatus
                                                      .awaitingConfirmation)
                                            TextButton(
                                              onPressed: queue.isSubmitting
                                                  ? null
                                                  : () => _approveMaterials([
                                                      item.id,
                                                    ]),
                                              child: const Text('继续处理'),
                                            ),
                                          if (item.versionId != null)
                                            TextButton(
                                              onPressed: () async {
                                                Navigator.pop(sheetContext);
                                                if (await _controller
                                                        .inspectVersion(
                                                          item.versionId!,
                                                        ) &&
                                                    mounted) {
                                                  await _openHistoryVersion(
                                                    _controller,
                                                    _controller
                                                        .state
                                                        .versionDetail!
                                                        .version,
                                                  );
                                                }
                                              },
                                              child: const Text('查看正式版本'),
                                            ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                            ],
                          ],
                        ),
                      ),
                      Padding(
                        padding: EdgeInsets.fromLTRB(
                          24,
                          12,
                          24,
                          math.max(16, media.padding.bottom),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (pending.isNotEmpty)
                              SizedBox(
                                height: 44,
                                child: FilledButton(
                                  key: const ValueKey(
                                    'digital-twin-material-approve',
                                  ),
                                  style: FilledButton.styleFrom(
                                    backgroundColor: _twinPurple,
                                    foregroundColor: const Color(0xFF1B1321),
                                    textStyle: _twinText(13),
                                  ),
                                  onPressed: queue.isSubmitting
                                      ? null
                                      : () => _approveMaterials(
                                          pending
                                              .map((item) => item.id)
                                              .toList(),
                                        ),
                                  child: Text('开始蒸馏 · ${pending.length} 份资料'),
                                ),
                              ),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                TextButton(
                                  onPressed: queue.isSubmitting
                                      ? null
                                      : () async {
                                          await queue.refresh();
                                          if (mounted) {
                                            queue.resumeObservation();
                                          }
                                        },
                                  child: const Text('刷新进度'),
                                ),
                                TextButton(
                                  onPressed: () {
                                    Navigator.pop(sheetContext);
                                    unawaited(_showMaterials());
                                  },
                                  child: const Text('上传处理记录'),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Future<void> _approveMaterials(List<String> ids) async {
    final frozen = List<String>.unmodifiable(ids);
    await _materials.submit(frozen);
    if (!mounted) return;
    await _materials.refresh();
    await _controller.load();
  }

  Future<void> _openMaterialReview(DigitalTwinMaterial item) async {
    final loaded = await _controller.load(
      importSource: null,
      reviewProposalIds: item.proposalIds.values.toList(),
      confirmationTaskId: item.confirmationId,
    );
    if (!mounted) return;
    if (!loaded) {
      _message('候选状态暂不可用，原任务已保留，请刷新核验');
      return;
    }
    await _showRevisionSheet(
      _controller,
      expanded: false,
      preserveScope: true,
      mutationLocked: false,
    );
    await _materials.refresh();
  }

  void _openMaterialSource(DigitalTwinMaterial item) {
    final noteId =
        item.source?.noteId ??
        (item.referenceKind == 'note' ? item.referenceId : null);
    if (noteId != null) {
      context.push(AppRoutePaths.feedItem(noteId));
    } else if (item.referenceKind == 'recording_job') {
      context.push(AppRoutePaths.transcriptionJob(item.referenceId));
    } else {
      context.push(AppRoutePaths.linkImportForDraft(item.referenceId));
    }
  }
}

class _TwinMaterialSheetActivity extends ConsumerStatefulWidget {
  const _TwinMaterialSheetActivity({required this.child});
  final Widget child;

  @override
  ConsumerState<_TwinMaterialSheetActivity> createState() =>
      _TwinMaterialSheetActivityState();
}

class _TwinMaterialSheetActivityState
    extends ConsumerState<_TwinMaterialSheetActivity>
    with AppActivityRouteAware<_TwinMaterialSheetActivity> {
  final _pollingOwner = Object();
  late DigitalTwinMaterialController _queue;

  @override
  void initState() {
    super.initState();
    _queue = ref.read(digitalTwinMaterialControllerProvider);
    _queue.setActive(activityRouteCanRun, owner: _pollingOwner);
    ref.listenManual(digitalTwinMaterialControllerProvider, (previous, next) {
      if (identical(_queue, next)) return;
      _queue.setActive(false, owner: _pollingOwner);
      _queue = next;
      _queue.setActive(activityRouteCanRun, owner: _pollingOwner);
    });
  }

  @override
  void onActivityRouteBecameActive() =>
      _queue.setActive(true, owner: _pollingOwner);

  @override
  void onActivityRouteBecameInactive() =>
      _queue.setActive(false, owner: _pollingOwner);

  @override
  void dispose() {
    _queue.setActive(false, owner: _pollingOwner);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

String _materialErrorText(String code) => switch (code) {
  'DOCUMENT_GENERATION_FAILED' => '蒸馏候选生成失败，原材料已保留，可查看候选后重新生成。',
  'DOCUMENT_CANDIDATE_TARGET_MISSED' ||
  'DOCUMENT_CANDIDATE_INVALID' => '蒸馏候选未通过校验，原材料已保留，可查看候选后重新生成。',
  'DIGITAL_TWIN_QUEUE_SAVE_FAILED' => '本地材料状态保存失败，原任务已保留，请重新核验。',
  _ => '蒸馏处理暂未完成，原材料和已受理任务已保留，请重新核验。',
};

String _materialStatusText(DigitalTwinMaterial item) => switch (item.status) {
  DigitalTwinMaterialStatus.awaitingConfirmation => '待确认材料 · 尚未提交服务端',
  DigitalTwinMaterialStatus.waitingSource => '等待原笔记同步或转写完成 · 可继续查询',
  DigitalTwinMaterialStatus.submitting =>
    '正在提交 · 已受理 ${item.proposalIds.length}/3 个目标',
  DigitalTwinMaterialStatus.generating => '候选生成或正式版本核验中 · 尚未完成',
  DigitalTwinMaterialStatus.awaitingVersionVerification =>
    '候选已应用 · 正式版本证据待核验，可继续查询',
  DigitalTwinMaterialStatus.reviewReady => '候选待审核 · 查看新增和改写内容',
  DigitalTwinMaterialStatus.noChanges => '本次无待应用变化 · 查看候选结果',
  DigitalTwinMaterialStatus.partialFailure => '部分未完成 · 已受理候选保留，可逐项处理',
  DigitalTwinMaterialStatus.failed => '处理未完成 · 原请求保留，请核验后继续',
  DigitalTwinMaterialStatus.completed => '已形成正式版本',
  DigitalTwinMaterialStatus.removed => '已移出待确认队列',
};
