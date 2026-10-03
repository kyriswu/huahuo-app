part of 'v3_digital_twin_page.dart';

String _twinChangeSummary(List<DocumentProposalDiffHunk> hunks) {
  var added = 0;
  var rewritten = 0;
  var deleted = 0;
  for (final hunk in hunks) {
    final hasBefore = hunk.changes.any((change) => change.op == 'delete');
    final hasAfter = hunk.changes.any((change) => change.op == 'insert');
    if (hasBefore && hasAfter) {
      rewritten += 1;
    } else if (hasAfter) {
      added += 1;
    } else if (hasBefore) {
      deleted += 1;
    }
  }
  return [
    if (added > 0) '新增 $added 项',
    if (rewritten > 0) '改写 $rewritten 项',
    if (deleted > 0) '删除 $deleted 项',
  ].join('，');
}

Future<void> _twinOpenText(
  BuildContext context,
  String title,
  String markdown,
) => Navigator.of(context).push<void>(
  MaterialPageRoute(
    builder: (_) => _TwinDocumentPage(title: title, markdown: markdown),
  ),
);

class _TwinDocumentPage extends StatelessWidget {
  const _TwinDocumentPage({required this.title, required this.markdown});
  final String title;
  final String markdown;
  @override
  Widget build(BuildContext context) => _TwinScreen(
    title: title,
    child: ListView(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 32),
      children: [
        SelectionArea(
          contextMenuBuilder: V3TextEditing.buildSelectionContextMenu,
          child: V3AssistantReplyMarkdown(
            source: markdown.trim().isEmpty ? '此版本尚未沉淀内容' : markdown,
            markdownKey: const ValueKey(
              'digital-twin-positioning-report-markdown',
            ),
          ),
        ),
      ],
    ),
  );
}

class _TwinScreen extends StatelessWidget {
  const _TwinScreen({required this.title, required this.child, this.trailing});
  final String title;
  final Widget child;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => Theme(
    data: _twinTheme(context),
    child: Scaffold(
      backgroundColor: const Color(0xFF0D0B11),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 6, 10, 12),
              child: Row(
                children: [
                  _TwinIconAction(
                    icon: Icons.arrow_back_rounded,
                    label: '返回',
                    onPressed: () => Navigator.pop(context),
                  ),
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: _twinText(17, weight: FontWeight.w500),
                    ),
                  ),
                  trailing ?? const SizedBox(width: 44),
                ],
              ),
            ),
            Expanded(child: child),
          ],
        ),
      ),
    ),
  );
}

class _TwinHistoryPage extends StatelessWidget {
  const _TwinHistoryPage({required this.controller, required this.onOpen});
  final DigitalTwinController controller;
  final ValueChanged<DigitalTwinVersion> onOpen;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final state = controller.state;
      final versions = [...state.versions]
        ..sort(
          (first, second) =>
              second.versionNumber.compareTo(first.versionNumber),
        );
      return _TwinScreen(
        title: '修订记录',
        child: RefreshIndicator(
          color: _twinPurple,
          onRefresh: () async {
            await controller.load();
          },
          child: ListView(
            key: const ValueKey('digital-twin-version-history'),
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(20, 6, 20, 24),
            children: [
              if (state.errorCode != null)
                _TwinRetryNotice(
                  text: '修订记录暂时无法更新，保留上次记录',
                  detail: state.errorCode,
                  onRetry: state.isBusy ? null : controller.load,
                ),
              if (versions.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 80),
                  child: Text(
                    state.isBusy ? '正在读取修订记录…' : '还没有可查看的修订版本',
                    textAlign: TextAlign.center,
                    style: _twinText(13, color: _twinMuted),
                  ),
                ),
              if (versions.length >= 100)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Text(
                    '当前接口最多返回最近 100 个修订版本，更早记录未在此列表中加载。',
                    style: _twinText(11, color: _twinMuted),
                  ),
                ),
              for (final version in versions)
                InkWell(
                  key: ValueKey('digital-twin-history-${version.versionId}'),
                  onTap: () => onOpen(version),
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 14),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    constraints: const BoxConstraints(minHeight: 104),
                    decoration: const BoxDecoration(
                      border: Border(
                        bottom: BorderSide(color: Color(0xFF343139)),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                version.label,
                                style: _twinText(15, weight: FontWeight.w500),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Text(
                              _dateTimeLabel(version.createdAt),
                              style: _twinText(10, color: _twinMuted),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            if (state.current?.currentVersion?.versionId ==
                                version.versionId) ...[
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 9,
                                  vertical: 3,
                                ),
                                decoration: BoxDecoration(
                                  color: _twinRail,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Text(
                                  '当前使用',
                                  style: _twinText(10, color: _twinPurple),
                                ),
                              ),
                              const SizedBox(width: 12),
                            ],
                            Expanded(
                              child: Text(
                                'v${version.versionNumber} · ${version.confirmationTaskId == null ? '正式版本快照' : '修订已确认'}',
                                style: _twinText(
                                  12,
                                  color: const Color(0xFFDAD4E0),
                                ),
                              ),
                            ),
                            const Icon(
                              Icons.chevron_right_rounded,
                              size: 18,
                              color: _twinMuted,
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '查看文件修改、修订报告与版本内容',
                          style: _twinText(10, color: _twinMuted),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    },
  );
}

class _TwinHistoryDetail extends StatefulWidget {
  const _TwinHistoryDetail({
    required this.controller,
    required this.version,
    required this.onPull,
    required this.onRestore,
  });
  final DigitalTwinController controller;
  final DigitalTwinVersion version;
  final VoidCallback onPull;
  final VoidCallback onRestore;
  @override
  State<_TwinHistoryDetail> createState() => _TwinHistoryDetailState();
}

class _TwinHistoryDetailState extends State<_TwinHistoryDetail> {
  DigitalTwinVersionDetail? _detail;
  DigitalTwinVersionComparison? _comparison;
  List<DigitalTwinLogicalFile> _files = const [];
  bool _loading = true;
  bool _showAllFiles = false;
  List<DigitalTwinRevisionRecord> _records = const [];
  String? _archiveError;
  String? _error;
  bool get _hasPrevious => widget.controller.state.versions.any(
    (version) => version.versionNumber < widget.version.versionNumber,
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_load());
    });
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final controller = widget.controller;
    final loaded = await controller.inspectVersion(widget.version.versionId);
    if (!mounted) return;
    if (!loaded ||
        controller.state.versionDetail?.version.versionId !=
            widget.version.versionId) {
      setState(() {
        _loading = false;
        _error = controller.state.errorCode ?? '版本读取未完成，请重试';
      });
      return;
    }
    final detail = controller.state.versionDetail!;
    final files = List<DigitalTwinLogicalFile>.unmodifiable(
      controller.state.previewFiles,
    );
    DigitalTwinVersionComparison? comparison;
    if (_hasPrevious) {
      final compared = await controller.compareVersion(
        widget.version.versionId,
      );
      if (!mounted) return;
      if (compared &&
          controller.state.comparison?.version.versionId ==
              widget.version.versionId) {
        comparison = controller.state.comparison;
      } else {
        _error = controller.state.errorCode ?? '版本差分读取未完成';
      }
    } else if (widget.version.versionNumber > 0) {
      _error = '当前历史列表未包含前一版本，无法比较。此版本原文仍可查看。';
    }
    try {
      _records = controller.revisionRecordsForVersion(detail);
      _archiveError = null;
    } catch (_) {
      _archiveError = '本机修订对话暂时无法读取，服务端版本与差分仍可查看。';
    }
    setState(() {
      _detail = detail;
      _files = files;
      _comparison = comparison;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final changes = _comparison?.files
        .where((file) => file.summary.hasChanges)
        .toList();
    final changeCount = changes?.fold<int>(
      0,
      (total, file) => total + file.hunks.length,
    );
    return _TwinScreen(
      title: '${widget.version.label} · 修订详情',
      trailing: PopupMenuButton<_VersionAction>(
        tooltip: '版本操作',
        icon: const Icon(Icons.more_horiz_rounded, color: _twinMuted),
        onSelected: (action) {
          switch (action) {
            case _VersionAction.pull:
              widget.onPull();
            case _VersionAction.restore:
              widget.onRestore();
            case _VersionAction.preview:
            case _VersionAction.compare:
              break;
          }
        },
        itemBuilder: (_) => [
          const PopupMenuItem(value: _VersionAction.pull, child: Text('导出此版本')),
          PopupMenuItem(
            value: _VersionAction.restore,
            enabled: widget.controller.canRestoreVersion,
            child: const Text('基于此版本生成恢复候选'),
          ),
        ],
      ),
      child: _loading
          ? const Center(child: CircularProgressIndicator(color: _twinPurple))
          : ListView(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
              children: [
                Text(
                  '已确认 · ${_dateTimeLabel(widget.version.createdAt)}',
                  style: _twinText(11, color: _twinMuted),
                ),
                const SizedBox(height: 24),
                Text(
                  changeCount == null
                      ? '版本 v${widget.version.versionNumber}'
                      : '本次写入 $changeCount 项更新',
                  style: _twinText(18, weight: FontWeight.w500),
                ),
                const SizedBox(height: 14),
                Text(
                  changes == null
                      ? '查看此版本的正式文件、确认结果与原始记录。'
                      : '对 ${changes.length} 份文件进行了修订。下方展示与前一正式版本的原始差分。',
                  style: _twinText(
                    12,
                    color: const Color(0xFFDAD4E0),
                    height: 23 / 12,
                  ),
                ),
                if (_error != null)
                  _TwinRetryNotice(
                    text: '部分内容暂时无法读取',
                    detail: _error,
                    onRetry: _load,
                  ),
                const SizedBox(height: 30),
                for (final file in _files)
                  if ((_showAllFiles || changes == null)
                      ? file.exists
                      : changes.any((change) => change.id == file.id))
                    _fileRow(
                      file,
                      changes
                          ?.where((change) => change.id == file.id)
                          .firstOrNull,
                    ),
                if (_detail != null) ...[
                  if (changes != null)
                    TextButton(
                      onPressed: () =>
                          setState(() => _showAllFiles = !_showAllFiles),
                      child: Text(_showAllFiles ? '只看本次修改文件' : '查看此版本全部文件'),
                    ),
                  const SizedBox(height: 24),
                  _TwinReportLink(
                    label: '查看本次修订报告',
                    onTap: () => Navigator.of(context).push<void>(
                      MaterialPageRoute(
                        builder: (_) => _TwinVersionReport(
                          detail: _detail!,
                          comparison: _comparison,
                          comparisonUnavailable:
                              widget.version.versionNumber > 0 &&
                              _comparison == null,
                          records: _records,
                          archiveError: _archiveError,
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
    );
  }

  Widget _fileRow(
    DigitalTwinLogicalFile file,
    DigitalTwinFileComparison? changes,
  ) => InkWell(
    onTap: () => _twinOpenText(
      context,
      '${_twinFileName(file)} · v${widget.version.versionNumber}',
      file.markdown,
    ),
    child: Container(
      constraints: const BoxConstraints(minHeight: 106),
      padding: const EdgeInsets.symmetric(vertical: 16),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xFF343139))),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(_fileIcon(file.id), size: 18, color: _twinPurple),
          const SizedBox(width: 18),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _twinFileName(file),
                  style: _twinText(14, weight: FontWeight.w500),
                ),
                const SizedBox(height: 8),
                Text(
                  changes == null
                      ? (_comparison == null ? '查看此版本原文' : '本次未修改')
                      : _twinChangeSummary(changes.hunks),
                  style: _twinText(11, color: _twinMuted),
                ),
              ],
            ),
          ),
          Text(
            changes == null ? '' : '${changes.hunks.length} 项',
            style: _twinText(11, color: _twinMuted),
          ),
          const SizedBox(width: 8),
          const Icon(Icons.chevron_right_rounded, size: 18, color: _twinMuted),
        ],
      ),
    ),
  );
}

class _TwinVersionReport extends StatelessWidget {
  const _TwinVersionReport({
    required this.detail,
    required this.comparison,
    required this.comparisonUnavailable,
    required this.records,
    this.archiveError,
  });
  final DigitalTwinVersionDetail detail;
  final DigitalTwinVersionComparison? comparison;
  final bool comparisonUnavailable;
  final List<DigitalTwinRevisionRecord> records;
  final String? archiveError;
  @override
  Widget build(BuildContext context) => _TwinScreen(
    title: '修订报告 · v${detail.version.versionNumber}',
    child: ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
      children: [
        Text(
          detail.version.label,
          style: _twinText(20, weight: FontWeight.w500),
        ),
        Text(
          _dateTimeLabel(detail.version.createdAt),
          style: _twinText(11, color: _twinMuted),
        ),
        const SizedBox(height: 20),
        SelectableText(
          '版本：${detail.version.versionId}\n确认任务：${detail.version.confirmationTaskId ?? '版本快照'}',
          contextMenuBuilder: V3TextEditing.buildContextMenu,
          style: _twinText(11, color: _twinMuted),
        ),
        const SizedBox(height: 20),
        Text('服务端确认结果', style: _twinText(15, weight: FontWeight.w500)),
        for (final result in detail.proposalResults)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: SelectableText(
              '${result.proposalId} · 候选 v${result.proposalVersion}\n${result.state == null ? '状态待核验' : _proposalStateLabel(result.state!)}${result.failureCode == null ? '' : ' · ${result.failureCode}'}',
              contextMenuBuilder: V3TextEditing.buildContextMenu,
              style: _twinText(12),
            ),
          ),
        if (detail.proposalResults.isEmpty)
          Text('此版本没有关联候选确认记录', style: _twinText(12, color: _twinMuted)),
        const SizedBox(height: 20),
        Text('文件原始差分', style: _twinText(15, weight: FontWeight.w500)),
        if (comparisonUnavailable)
          Text(
            '差分读取未完成，请返回详情重新核验。',
            style: _twinText(12, color: _compactTwinWarm),
          )
        else if (comparison == null)
          Text('初始快照没有前一版本可供比较。', style: _twinText(12, color: _twinMuted))
        else ...[
          Text(
            'v${comparison!.baseVersion.versionNumber} → v${detail.version.versionNumber}',
            style: _twinText(11, color: _twinMuted),
          ),
          for (final file in comparison!.files.where(
            (file) => file.summary.hasChanges,
          )) ...[
            const SizedBox(height: 20),
            Text(
              '${file.name}.md',
              style: _twinText(14, weight: FontWeight.w500),
            ),
            const SizedBox(height: 10),
            for (var index = 0; index < file.hunks.length; index++)
              _TwinDiffEvidence(
                title: '第 ${index + 1} 项修改',
                hunk: file.hunks[index],
              ),
          ],
        ],
        const SizedBox(height: 24),
        Text('本机保留的相关修订对话', style: _twinText(15, weight: FontWeight.w500)),
        Text(
          archiveError ??
              (records.isEmpty
                  ? '本机没有此版本的修订对话记录。正式内容与差分以服务端版本为准。'
                  : '仅展示此版本形成之前、与已确认候选匹配的本机修订记录。'),
          style: _twinText(10, color: _twinMuted),
        ),
        for (final record in records) ...[
          const SizedBox(height: 14),
          Text(
            '候选 v${record.command.proposal.proposal.proposalVersion} → v${record.command.receipt!.proposal.proposalVersion}',
            style: _twinText(10, color: _twinMuted),
          ),
          for (final quote in record.command.selectedHunks)
            Container(
              margin: const EdgeInsets.symmetric(vertical: 8),
              padding: const EdgeInsets.all(12),
              decoration: const BoxDecoration(
                color: _twinRail,
                border: Border(left: BorderSide(color: _twinPurple, width: 2)),
              ),
              child: SelectableText(
                '引用 ${quote.hunkId} · v${quote.proposalVersion}\n${quote.quotedText}',
                contextMenuBuilder: V3TextEditing.buildContextMenu,
                style: _twinText(11),
              ),
            ),
          _TwinUserMessage(text: record.command.instruction),
          if (record.result != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: _TwinAgentMessage(text: record.result!),
            ),
        ],
      ],
    ),
  );
}

class _TwinReportLink extends StatelessWidget {
  const _TwinReportLink({required this.label, required this.onTap});
  final String label;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(12),
    child: Container(
      constraints: const BoxConstraints(minHeight: 52),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: _twinRail,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          const Icon(Icons.description_outlined, size: 19, color: _twinPurple),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: _twinText(13, color: const Color(0xFFDAD4E0)),
            ),
          ),
          const Icon(Icons.chevron_right_rounded, size: 19, color: _twinMuted),
        ],
      ),
    ),
  );
}
