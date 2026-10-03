part of 'v3_digital_twin_page.dart';

const _twinPurple = Color(0xFFB88CFF);
const _twinSheet = Color(0xFF1C1B1E);
const _twinInk = Color(0xFFF4F0F8);
const _twinMuted = Color(0xFF9791A0);
const _twinRail = Color(0xFF352944);

TextStyle _twinText(
  double size, {
  Color color = _twinInk,
  FontWeight weight = FontWeight.w400,
  double height = 1.65,
}) => TextStyle(
  fontFamily: 'Noto Sans SC',
  fontSize: size,
  color: color,
  fontWeight: weight,
  height: height,
  letterSpacing: 0,
);

ThemeData _twinTheme(BuildContext context) {
  final base = HuahuoV3Theme.fromTokens(
    brightness: Brightness.dark,
    tokens: HuahuoV3Theme.darkTokens.copyWith(
      canvas: const Color(0xFF0D0B11),
      surface: _twinSheet,
      surfaceMuted: _twinRail,
      ink: _twinInk,
      text: const Color(0xFFDAD4E0),
      muted: _twinMuted,
      accent: _twinPurple,
      primary: _twinPurple,
      onPrimary: const Color(0xFF1B1321),
      line: const Color(0xFF343139),
    ),
  );
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: 'Noto Sans SC'),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        textStyle: const TextStyle(
          fontFamily: 'Noto Sans SC',
          fontSize: 12,
          fontWeight: FontWeight.w500,
        ),
        shape: const StadiumBorder(),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: _twinPurple,
        textStyle: _twinText(12),
      ),
    ),
    dividerColor: const Color(0xFF343139),
  );
}

String _twinFileName(DigitalTwinLogicalFile file) =>
    file.name.endsWith('.md') ? file.name : '${file.name}.md';

class _CompactRevisionSheet extends ConsumerStatefulWidget {
  const _CompactRevisionSheet({
    required this.controller,
    required this.mutationLocked,
    required this.revisionController,
    required this.expanded,
    required this.onRevise,
    required this.onReject,
    required this.onRegenerate,
    required this.onConfirm,
    required this.onReport,
  });

  final DigitalTwinController controller;
  final bool mutationLocked;
  final TextEditingController revisionController;
  final bool expanded;
  final Future<void> Function() onRevise;
  final Future<void> Function() onReject;
  final Future<void> Function() onRegenerate;
  final Future<void> Function() onConfirm;
  final Future<void> Function(DigitalTwinVersion) onReport;

  @override
  ConsumerState<_CompactRevisionSheet> createState() =>
      _CompactRevisionSheetState();
}

class _CompactRevisionSheetState extends ConsumerState<_CompactRevisionSheet>
    with AppActivityRouteAware<_CompactRevisionSheet>, WidgetsBindingObserver {
  final _scroll = ScrollController();
  final Object _pollingOwner = Object();
  late bool _fullscreen;
  String? _openFileId;
  bool _showCitations = false;
  bool _showFiles = true;
  bool _confirmationRequested = false;
  DigitalTwinConfirmation? _confirmedReport;
  bool get _confirmedHere => _confirmedReport != null;
  bool _confirmingLocally = false;
  String? _previousCompletedConfirmationId;
  VoiceMessageController? _voice;
  late final String _voiceOwner =
      'digital-twin-revision-${identityHashCode(this)}';
  String _voicePrefix = '';
  String? _voiceError;
  String? _contextError;

  DigitalTwinController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _fullscreen = widget.expanded;
    _showFiles = !controller.revisionEvents.any(
      (event) => controller.state.reviews.any(
        (review) => review.snapshot.proposal.proposalId == event.proposalId,
      ),
    );
    controller.setPollingRouteActive(activityRouteCanRun, owner: _pollingOwner);
    if (widget.expanded) _openFileId = controller.state.selectedFileId;
    WidgetsBinding.instance.addObserver(this);
    widget.revisionController.addListener(_inputChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(controller.prepareReviewDetails());
    });
  }

  void _inputChanged() {
    if (mounted) setState(() {});
  }

  @override
  void onActivityRouteBecameActive() =>
      controller.setPollingRouteActive(true, owner: _pollingOwner);

  @override
  void onActivityRouteBecameInactive() {
    controller.setPollingRouteActive(false, owner: _pollingOwner);
    _endVoice();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _endVoice();
  }

  void _endVoice() {
    final voice = _voice;
    if (voice != null && voice.state.belongsToLiveTranscript(_voiceOwner)) {
      unawaited(voice.endCaptureForLeave(owner: _voiceOwner));
    }
  }

  @override
  void dispose() {
    controller.setPollingRouteActive(false, owner: _pollingOwner);
    WidgetsBinding.instance.removeObserver(this);
    widget.revisionController.removeListener(_inputChanged);
    _voice?.removeListener(_voiceChanged);
    _endVoice();
    _scroll.dispose();
    super.dispose();
  }

  void _voiceChanged() {
    if (!mounted ||
        _voice?.state.belongsToLiveTranscript(_voiceOwner) != true) {
      return;
    }
    final voice = _voice!.state;
    if (voice.liveTranscriptText.trim().isNotEmpty) {
      final text = '$_voicePrefix${voice.liveTranscriptText}';
      widget.revisionController.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
    }
    setState(() => _voiceError = voice.lastErrorCode);
  }

  Future<void> _toggleVoice() async {
    if (_voice == null) {
      _voice = ref.read(feedAiVoiceMessageControllerProvider);
      _voice!.addListener(_voiceChanged);
    }
    final voice = _voice!;
    if (voice.state.isBusy) return;
    if (voice.state.isCaptureActive) {
      if (!voice.state.belongsToLiveTranscript(_voiceOwner)) {
        setState(() => _voiceError = '麦克风正在被其他会话使用');
        return;
      }
      await voice.stopAndTranscribe(owner: _voiceOwner);
      _voiceChanged();
    } else {
      _voicePrefix = widget.revisionController.text;
      final started = await voice.startLiveTranscription(owner: _voiceOwner);
      if (!mounted) {
        _endVoice();
      } else if (!started) {
        setState(() => _voiceError = voice.state.lastErrorCode ?? '无法开始语音输入');
      }
    }
  }

  Future<void> _confirm() async {
    _endVoice();
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _previousCompletedConfirmationId = controller.hasPendingConfirmation
          ? null
          : controller.state.confirmation?.confirmationTaskId;
      _confirmationRequested = true;
      _confirmingLocally = true;
    });
    try {
      await widget.onConfirm();
      if (!mounted) return;
      final state = controller.state;
      final report =
          state.confirmation?.confirmationTaskId ==
              _previousCompletedConfirmationId
          ? null
          : state.confirmation;
      setState(() {
        final verified =
            report?.state == 'report_ready' &&
            report!.appliedCount > 0 &&
            report.version != null &&
            state.errorCode == null &&
            state.versions.any(
              (version) => version.versionId == report.version!.versionId,
            );
        _confirmedReport = verified ? report : null;
      });
    } finally {
      if (mounted) setState(() => _confirmingLocally = false);
    }
  }

  Future<void> _send() async {
    _endVoice();
    setState(() {
      _showFiles = false;
      _showCitations = false;
    });
    await widget.onRevise();
    if (mounted &&
        controller.state.errorCode == null &&
        !controller.hasPendingEdits) {
      setState(() => _showCitations = false);
    }
  }

  Future<void> _context() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: _twinSheet,
      showDragHandle: false,
      builder: (sheetContext) => Theme(
        data: _twinTheme(context),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: const Icon(
                    Icons.format_quote_rounded,
                    color: _twinPurple,
                  ),
                  title: Text('引用文件修改', style: _twinText(14)),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    setState(() {
                      _showCitations = false;
                      _showFiles = true;
                      _openFileId ??= controller.state.selectedFileId;
                    });
                  },
                ),
                ListTile(
                  leading: const Icon(
                    Icons.attach_file_rounded,
                    color: _twinPurple,
                  ),
                  title: Text('添加文本附件', style: _twinText(14)),
                  subtitle: Text(
                    'Markdown / TXT，作为本次修订的补充上下文',
                    style: _twinText(11, color: _twinMuted),
                  ),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    unawaited(_attachText());
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.notes_rounded, color: _twinPurple),
                  title: Text('添加文字上下文', style: _twinText(14)),
                  subtitle: Text(
                    '作为本次修改要求发送，不改变原始来源',
                    style: _twinText(11, color: _twinMuted),
                  ),
                  onTap: () async {
                    Navigator.pop(sheetContext);
                    final input = TextEditingController();
                    final text = await showDialog<String>(
                      context: context,
                      builder: (dialogContext) => AlertDialog(
                        backgroundColor: _twinSheet,
                        title: Text('添加文字上下文', style: _twinText(18)),
                        content: TextField(
                          controller: input,
                          contextMenuBuilder: V3TextEditing.buildContextMenu,
                          autofocus: true,
                          minLines: 3,
                          maxLines: 7,
                          style: _twinText(13),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(dialogContext),
                            child: const Text('取消'),
                          ),
                          TextButton(
                            onPressed: () =>
                                Navigator.pop(dialogContext, input.text.trim()),
                            child: const Text('添加'),
                          ),
                        ],
                      ),
                    );
                    await Future<void>.delayed(
                      const Duration(milliseconds: 300),
                    );
                    input.dispose();
                    if (mounted && text != null && text.isNotEmpty) {
                      _appendContext('补充上下文', text);
                    }
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _appendContext(String title, String text) {
    final current = widget.revisionController.text;
    final combined = '$current${current.isEmpty ? '' : '\n'}$title：\n$text';
    if (utf8.encode(combined).length > documentProposalInstructionMaxBytes) {
      setState(() => _contextError = '补充内容过长，请缩短至 32 KB 内；原输入未改变。');
      return;
    }
    widget.revisionController.value = TextEditingValue(
      text: combined,
      selection: TextSelection.collapsed(offset: combined.length),
    );
    setState(() => _contextError = null);
  }

  Future<void> _attachText() async {
    try {
      final result = await ref.read(nativeFilePortProvider).pickDocumentFiles();
      if (!mounted) return;
      if (!result.ok) {
        setState(() => _contextError = '未能读取附件，请重试。原输入已保留。');
        return;
      }
      final files = result.value ?? const <PickedDocumentFile>[];
      final parts = <String>[];
      for (final file in files) {
        if (!const {'md', 'txt'}.contains(file.fileExtension) ||
            file.sourcePath == null) {
          setState(
            () => _contextError = '修订上下文仅支持 Markdown / TXT；其他格式请先导入为笔记。',
          );
          return;
        }
        if (file.sizeBytes > documentProposalInstructionMaxBytes) {
          setState(() => _contextError = '附件超过 32 KB，请选取需要讨论的段落。');
          return;
        }
        final bytes = await File(file.sourcePath!)
            .openRead(0, documentProposalInstructionMaxBytes + 1)
            .fold<List<int>>([], (bytes, chunk) => bytes..addAll(chunk));
        if (!mounted) return;
        if (bytes.length > documentProposalInstructionMaxBytes) {
          setState(() => _contextError = '附件超过 32 KB，原输入未改变。');
          return;
        }
        parts.add('${file.displayName}\n${utf8.decode(bytes)}');
      }
      if (parts.isNotEmpty) _appendContext('附件上下文', parts.join('\n\n'));
    } catch (_) {
      if (mounted) {
        setState(() => _contextError = '无法读取 UTF-8 文本附件，请重新选择；原输入已保留。');
      }
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final state = controller.state;
      final report =
          _confirmedReport ??
          (_confirmingLocally &&
                  state.confirmation?.confirmationTaskId ==
                      _previousCompletedConfirmationId
              ? null
              : state.confirmation);
      final locked =
          widget.mutationLocked ||
          controller.hasUnresolvedMutation ||
          state.isBusy;
      final canConfirm = controller.hasPendingConfirmation
          ? !state.isBusy
          : !locked &&
                state.readyProposalCount > 0 &&
                widget.revisionController.text.trim().isEmpty &&
                _voice?.state.isCaptureActive != true &&
                state.reviews.every(
                  (review) =>
                      review.snapshot.proposal.state !=
                          DocumentProposalState.ready ||
                      review.detailsUsable,
                );
      final processing =
          _confirmingLocally ||
          state.phase == DigitalTwinControllerPhase.confirming;
      final showReport = _confirmedHere || processing;
      final files =
          state.current?.files
              .where(
                (file) => file.pendingProposalIds.any(
                  (id) => state.reviews.any(
                    (review) => review.snapshot.proposal.proposalId == id,
                  ),
                ),
              )
              .toList() ??
          <DigitalTwinLogicalFile>[];
      final events = controller.revisionEvents
          .where(
            (event) => state.reviews.any(
              (review) =>
                  review.snapshot.proposal.proposalId == event.proposalId,
            ),
          )
          .toList();
      final updatedReviewIds = <String>{};
      try {
        for (final review in state.reviews) {
          if (controller.hasRevisionEvidence(review))
            updatedReviewIds.add(review.snapshot.proposal.proposalId);
        }
      } catch (_) {}
      final citations = <(DigitalTwinProposalReview, DocumentProposalDiffHunk)>[
        for (final review in state.reviews)
          if (review.detailsUsable && review.isViewingCurrent)
            for (final hunk in review.diff)
              if (review.selectedHunkIds.contains(hunk.hunkId)) (review, hunk),
      ];
      final hasConversation = events.isNotEmpty || _showCitations;
      final preferredHeight = _confirmedHere
          ? 374.0
          : showReport
          ? 414.0
          : hasConversation
          ? 486.0
          : _openFileId != null
          ? 586.0
          : 414.0;
      final media = MediaQuery.of(context);
      final available = math.max(
        0.0,
        media.size.height - media.viewInsets.bottom - media.padding.top,
      );
      final scaledHeight =
          preferredHeight + math.max(0, media.textScaler.scale(13) - 13) * 12;
      return Theme(
        data: _twinTheme(context),
        child: AnimatedPadding(
          padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
          duration: const Duration(milliseconds: 200),
          child: AnimatedContainer(
            key: const ValueKey('digital-twin-revision-surface'),
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeOutCubic,
            height: _fullscreen ? available : math.min(scaledHeight, available),
            decoration: BoxDecoration(
              color: _openFileId == null && !hasConversation && !showReport
                  ? const Color(0xFF1A1A1A)
                  : _twinSheet,
              borderRadius: BorderRadius.vertical(
                top: Radius.circular(_fullscreen ? 0 : 24),
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
                        onPressed: () => Navigator.pop(context),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _confirmedHere
                              ? '版本已确认'
                              : processing
                              ? '确认当前版本'
                              : '数字孪生修订',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: _twinText(18, weight: FontWeight.w500),
                        ),
                      ),
                      _TwinIconAction(
                        icon: _fullscreen
                            ? Icons.close_fullscreen_rounded
                            : Icons.open_in_full_rounded,
                        label: _fullscreen ? '收起' : '展开',
                        onPressed: () =>
                            setState(() => _fullscreen = !_fullscreen),
                      ),
                      SizedBox(
                        width: 120,
                        height: 34,
                        child: FilledButton(
                          key: const ValueKey('digital-twin-confirm'),
                          style: FilledButton.styleFrom(
                            backgroundColor: _twinPurple,
                            foregroundColor: const Color(0xFF1B1321),
                            disabledBackgroundColor: _twinRail,
                            disabledForegroundColor: _twinMuted,
                            padding: EdgeInsets.zero,
                            textStyle: _twinText(12, weight: FontWeight.w500),
                          ),
                          onPressed: !showReport && canConfirm
                              ? _confirm
                              : null,
                          child: Text(
                            _confirmedHere
                                ? '已确认'
                                : processing
                                ? '校验中'
                                : controller.hasPendingConfirmation
                                ? '继续核验'
                                : '确认当前版本',
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView(
                    key: const PageStorageKey('digital-twin-revision-scroll'),
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                    children: [
                      if (showReport)
                        _TwinConfirmationProgress(
                          confirmed: _confirmedHere,
                          remainingCount:
                              <String>{
                                ...?state.current?.activeProposalIds,
                                for (final file
                                    in state.current?.files ??
                                        <DigitalTwinLogicalFile>[])
                                  ...file.pendingProposalIds,
                              }.difference({
                                for (final result
                                    in report?.outcomes ??
                                        <DigitalTwinConfirmationOutcome>[])
                                  if (result.state ==
                                      DocumentProposalState.applied)
                                    result.proposalId,
                              }).length,
                          referencesSaved:
                              controller.hasPendingConfirmation ||
                              _confirmedHere,
                          confirmation: report,
                          onReport: report?.version == null
                              ? null
                              : () => widget.onReport(report!.version!),
                          onClose: () => Navigator.pop(context),
                        )
                      else ...[
                        if (state.readyProposalCount >
                            digitalTwinConfirmationBatchLimit)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: Text(
                              '当前有 ${state.readyProposalCount} 份可确认候选。本次最多确认 $digitalTwinConfirmationBatchLimit 份，其余保留待处理。',
                              key: const ValueKey(
                                'digital-twin-confirmation-batch-notice',
                              ),
                              style: _twinText(11, color: _compactTwinWarm),
                            ),
                          ),
                        if ((state.current?.activeProposalIds.length ?? 0) >=
                            50)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: Text(
                              '服务端候选概览最多返回 50 份。更早已入队的资料请通过材料记录逐项查看，此处不代表全部候选。',
                              style: _twinText(11, color: _compactTwinWarm),
                            ),
                          ),
                        if (!hasConversation) ...[
                          _TwinAgentMessage(
                            text:
                                '我发现 ${files.length} 份文件有更新${state.reviews.every((review) => review.detailsLoaded) ? '，共 ${state.reviews.fold<int>(0, (total, review) => total + review.diff.length)} 项' : ''}。逐份查看，或直接告诉我保留和删去哪些内容。',
                          ),
                          const SizedBox(height: 14),
                        ],
                        if (state.errorCode != null ||
                            controller.hasPendingEdits ||
                            (_confirmationRequested &&
                                !_confirmedHere &&
                                !processing))
                          _TwinRetryNotice(
                            text: controller.hasPendingEdits
                                ? '修改要求已保存，结果待核验'
                                : controller.hasPendingConfirmation
                                ? '确认已受理，结果待核验'
                                : '暂未完成操作，原候选与修订记录已保留',
                            detail: state.errorCode,
                            onRetry: state.isBusy
                                ? null
                                : () => controller.hasPendingConfirmation
                                      ? _confirm()
                                      : controller.load(),
                          ),
                        if (hasConversation) ...[
                          for (final event in events)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 16),
                              child: event.isUser
                                  ? _userMessage(event, files)
                                  : _TwinAgentMessage(text: event.text),
                            ),
                          if (state.phase ==
                              DigitalTwinControllerPhase.revising)
                            const _TwinAgentMessage(
                              text: '正在整理新的修改。来源文件和原文位置会随本次修订保留。',
                              working: true,
                            ),
                          if (_showCitations && citations.isNotEmpty) ...[
                            const _TwinAgentMessage(
                              text: '已引用以下修改。你可以直接告诉我希望怎样改。',
                            ),
                            const SizedBox(height: 16),
                            for (final citation in citations)
                              _TwinDiffEvidence(
                                title: _citationName(
                                  citation.$1,
                                  citation.$2,
                                  files,
                                ),
                                hunk: citation.$2,
                              ),
                          ],
                          if (!_showFiles && !_showCitations && !state.isBusy)
                            for (final review in state.reviews.where(
                              (review) =>
                                  review.detailsUsable &&
                                  review.isViewingCurrent &&
                                  review.snapshot.proposal.state ==
                                      DocumentProposalState.ready,
                            ))
                              for (final hunk in review.diff)
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    34,
                                    8,
                                    0,
                                    12,
                                  ),
                                  child: _TwinDiffEvidence(
                                    title: _citationName(review, hunk, files),
                                    hunk: hunk,
                                    updated: updatedReviewIds.contains(
                                      review.snapshot.proposal.proposalId,
                                    ),
                                  ),
                                ),
                          if (!_showFiles && !_showCitations && !state.isBusy)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              child: Text(
                                '还要继续修改，还是确认当前版本？',
                                style: _twinText(11, color: _twinMuted),
                              ),
                            ),
                          TextButton.icon(
                            onPressed: () => setState(() {
                              _showFiles = true;
                              _showCitations = false;
                              _openFileId ??= state.selectedFileId;
                            }),
                            icon: const Icon(
                              Icons.folder_open_rounded,
                              size: 16,
                            ),
                            label: const Text('查看文件与当前草稿'),
                          ),
                        ],
                        if (!_showCitations && (_showFiles || !hasConversation))
                          for (final file in files) _file(file, state, locked),
                        if (files.isEmpty && !state.isBusy)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 20),
                            child: Text(
                              '当前没有待审核候选。可返回查看材料处理进度。',
                              style: _twinText(12, color: _twinMuted),
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
                if (!showReport) ...[
                  if (_contextError != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Text(
                        _contextError!,
                        style: _twinText(11, color: _compactTwinWarm),
                      ),
                    ),
                  if (_voiceError != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Text(
                        '语音输入未完成：$_voiceError；已有文字已保留。',
                        style: _twinText(11, color: _compactTwinWarm),
                      ),
                    ),
                  _TwinRevisionComposer(
                    controller: widget.revisionController,
                    enabled: !locked && state.canRevise,
                    citation: citations.isEmpty
                        ? null
                        : citations.length == 1
                        ? _citationName(
                            citations.first.$1,
                            citations.first.$2,
                            files,
                          )
                        : '已引用 ${citations.length} 项修改',
                    onClearCitation: () async {
                      final previous = controller.state.selectedProposalId;
                      for (final citation in citations) {
                        await controller.selectProposal(
                          citation.$1.snapshot.proposal.proposalId,
                        );
                        if (controller.state.selectedReview?.selectedHunkIds
                                .contains(citation.$2.hunkId) ==
                            true) {
                          controller.toggleHunk(citation.$2.hunkId);
                        }
                      }
                      if (previous != null) {
                        await controller.selectProposal(previous);
                      }
                      if (mounted) setState(() => _showCitations = false);
                    },
                    onSend: _send,
                    onAdd: _context,
                    onVoice: _toggleVoice,
                    recording:
                        _voice?.state.belongsToLiveTranscript(_voiceOwner) ==
                            true &&
                        _voice!.state.isCaptureActive,
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    },
  );

  Widget _userMessage(
    DigitalTwinRevisionEvent event,
    List<DigitalTwinLogicalFile> files,
  ) {
    String? citation;
    try {
      final command = controller.revisionCommandForEvent(event);
      if (command != null && command.selectedHunks.isNotEmpty) {
        final file = files
            .where((file) => file.pendingProposalIds.contains(event.proposalId))
            .firstOrNull;
        citation =
            '引用：${file == null ? '原始候选' : _twinFileName(file)} / ${command.selectedHunks.length} 项修改';
      }
    } catch (_) {
      citation = '原始引用暂时无法读取，修改要求仍已保留';
    }
    return _TwinUserMessage(text: event.text, citation: citation);
  }

  String _citationName(
    DigitalTwinProposalReview review,
    DocumentProposalDiffHunk hunk,
    List<DigitalTwinLogicalFile> files,
  ) {
    final file =
        files
            .where(
              (file) =>
                  file.id == _openFileId &&
                  file.pendingProposalIds.contains(
                    review.snapshot.proposal.proposalId,
                  ),
            )
            .firstOrNull ??
        files
            .where(
              (file) => file.pendingProposalIds.contains(
                review.snapshot.proposal.proposalId,
              ),
            )
            .firstOrNull;
    return '${file == null ? '候选文件' : _twinFileName(file)} / 第 ${review.diff.indexOf(hunk) + 1} 项修改';
  }

  Widget _file(
    DigitalTwinLogicalFile file,
    DigitalTwinControllerState state,
    bool locked,
  ) {
    final reviews = state.reviews
        .where(
          (review) => file.pendingProposalIds.contains(
            review.snapshot.proposal.proposalId,
          ),
        )
        .toList();
    final opened = _openFileId == file.id;
    final loaded = reviews.every((review) => review.detailsLoaded);
    final count = reviews.fold<int>(
      0,
      (total, review) => total + review.diff.length,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          key: ValueKey('digital-twin-revision-file-${file.id}'),
          onTap: () async {
            setState(() => _openFileId = opened ? null : file.id);
            if (!opened) {
              for (final review in reviews) {
                await controller.selectProposal(
                  review.snapshot.proposal.proposalId,
                );
              }
            }
          },
          child: Container(
            constraints: const BoxConstraints(minHeight: 46),
            child: Row(
              children: [
                Icon(
                  _fileIcon(file.id),
                  size: 18,
                  color: opened ? _twinPurple : _twinInk,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    _twinFileName(file),
                    style: _twinText(14, weight: FontWeight.w500),
                  ),
                ),
                Text(
                  loaded ? '$count 项' : '${reviews.length} 份候选',
                  style: _twinText(11, color: _twinMuted),
                ),
                const SizedBox(width: 20),
                Icon(
                  opened
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                  size: 18,
                  color: _twinMuted,
                ),
                const SizedBox(width: 8),
              ],
            ),
          ),
        ),
        const Padding(
          padding: EdgeInsets.only(left: 34),
          child: Divider(height: 1, color: Color(0x55343434)),
        ),
        if (opened)
          for (final review in reviews) _review(file, review, locked),
      ],
    );
  }

  Widget _review(
    DigitalTwinLogicalFile file,
    DigitalTwinProposalReview review,
    bool locked,
  ) {
    final proposal = review.snapshot.proposal;
    final canQuote =
        !locked &&
        review.detailsUsable &&
        review.isViewingCurrent &&
        proposal.state == DocumentProposalState.ready;
    return Padding(
      padding: const EdgeInsets.only(left: 34, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (review.loadingDetails)
            const LinearProgressIndicator(color: _twinPurple),
          if (review.errorCode != null)
            _TwinRetryNotice(
              text: '无法读取此候选',
              detail: review.errorCode,
              onRetry: () =>
                  controller.retryProposalDetails(proposal.proposalId),
            ),
          Row(
            children: [
              Expanded(
                child: Text(
                  '候选 v${review.visibleVersion} · ${_proposalStateLabel(proposal.state)}',
                  style: _twinText(10, color: _twinMuted),
                ),
              ),
              if (review.versions.length > 1)
                PopupMenuButton<int>(
                  enabled: !locked && !review.loadingDetails,
                  tooltip: '候选修订版本',
                  icon: const Icon(
                    Icons.history_rounded,
                    size: 18,
                    color: _twinMuted,
                  ),
                  onSelected: (version) => controller.inspectProposalVersion(
                    proposal.proposalId,
                    version,
                  ),
                  itemBuilder: (_) => [
                    for (final version in review.versions)
                      PopupMenuItem(
                        value: version.proposalVersion,
                        child: Text('候选 v${version.proposalVersion}'),
                      ),
                  ],
                ),
              TextButton(
                onPressed: canQuote && review.diff.isNotEmpty
                    ? () async {
                        await controller.selectProposal(proposal.proposalId);
                        for (final hunk in review.diff) {
                          if (!controller.state.selectedReview!.selectedHunkIds
                              .contains(hunk.hunkId)) {
                            controller.toggleHunk(hunk.hunkId);
                          }
                        }
                        if (mounted) setState(() => _showCitations = true);
                      }
                    : null,
                child: const Text('+ 全部选中'),
              ),
            ],
          ),
          if (!review.isViewingCurrent)
            TextButton(
              onPressed: () => controller.inspectProposalVersion(
                proposal.proposalId,
                proposal.proposalVersion,
              ),
              child: const Text('正在查看历史候选 · 返回当前版本'),
            ),
          for (var index = 0; index < review.diff.length; index++)
            _TwinDiffEvidence(
              title: '第 ${index + 1} 项修改',
              hunk: review.diff[index],
              onQuote: canQuote
                  ? () async {
                      await controller.selectProposal(proposal.proposalId);
                      if (!controller.state.selectedReview!.selectedHunkIds
                          .contains(review.diff[index].hunkId)) {
                        controller.toggleHunk(review.diff[index].hunkId);
                      }
                      if (mounted) setState(() => _showCitations = true);
                    }
                  : null,
            ),
          if (review.detailsLoaded && review.diff.isEmpty)
            Text('此候选没有待应用变化', style: _twinText(12, color: _twinMuted)),
          Wrap(
            spacing: 12,
            children: [
              if (review.candidateMarkdown != null)
                TextButton(
                  onPressed: () => _twinOpenText(
                    context,
                    '${_twinFileName(file)} · 候选 v${review.visibleVersion}',
                    review.candidateMarkdown!,
                  ),
                  child: const Text('查看候选全文'),
                ),
              if (!locked && stateCanRegenerate(proposal.state))
                TextButton(
                  onPressed: () async {
                    await controller.selectProposal(proposal.proposalId);
                    await widget.onRegenerate();
                  },
                  child: const Text('重新生成'),
                ),
              if (!locked &&
                  const {
                    DocumentProposalState.ready,
                    DocumentProposalState.stale,
                    DocumentProposalState.applyFailed,
                  }.contains(proposal.state))
                TextButton(
                  onPressed: () async {
                    await controller.selectProposal(proposal.proposalId);
                    await widget.onReject();
                  },
                  child: const Text('不采用此候选'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

bool stateCanRegenerate(DocumentProposalState state) => const {
  DocumentProposalState.generationFailed,
  DocumentProposalState.stale,
  DocumentProposalState.applyFailed,
}.contains(state);

class _TwinIconAction extends StatelessWidget {
  const _TwinIconAction({
    required this.icon,
    required this.label,
    required this.onPressed,
  });
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: label,
    onPressed: onPressed,
    icon: Icon(icon, size: 22, color: const Color(0xFFDAD4E0)),
    padding: EdgeInsets.zero,
    constraints: const BoxConstraints.tightFor(width: 44, height: 44),
  );
}

class _TwinAgentMessage extends StatelessWidget {
  const _TwinAgentMessage({required this.text, this.working = false});
  final String text;
  final bool working;
  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Container(
        margin: const EdgeInsets.only(top: 4),
        width: 30,
        height: 30,
        decoration: const BoxDecoration(
          color: _twinRail,
          shape: BoxShape.circle,
        ),
        child: working
            ? const Padding(
                padding: EdgeInsets.all(8),
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: _twinPurple,
                ),
              )
            : const Icon(
                Icons.auto_awesome_rounded,
                color: _twinPurple,
                size: 16,
              ),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: SelectableText(
          text,
          contextMenuBuilder: V3TextEditing.buildContextMenu,
          style: _twinText(13, color: const Color(0xFFE7E7E5), height: 20 / 13),
        ),
      ),
    ],
  );
}

class _TwinUserMessage extends StatelessWidget {
  const _TwinUserMessage({required this.text, this.citation});
  final String text;
  final String? citation;
  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerRight,
    child: Container(
      constraints: BoxConstraints(
        maxWidth: math.min(296, MediaQuery.sizeOf(context).width - 64),
      ),
      width: math.min(296, MediaQuery.sizeOf(context).width - 64),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF2B2333),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (citation != null) ...[
            Text(citation!, style: _twinText(10, color: _twinMuted)),
            const SizedBox(height: 8),
          ],
          SelectableText(
            text,
            contextMenuBuilder: V3TextEditing.buildContextMenu,
            style: _twinText(12, height: 20 / 12),
          ),
        ],
      ),
    ),
  );
}

class _TwinDiffEvidence extends StatelessWidget {
  const _TwinDiffEvidence({
    required this.title,
    required this.hunk,
    this.onQuote,
    this.updated = false,
  });
  final String title;
  final DocumentProposalDiffHunk hunk;
  final bool updated;
  final VoidCallback? onQuote;
  @override
  Widget build(BuildContext context) {
    final before = hunk.changes
        .where((change) => change.op == 'delete')
        .map((change) => change.text)
        .join('\n');
    final after = hunk.changes
        .where((change) => change.op == 'insert')
        .map((change) => change.text)
        .join('\n');
    final kind = before.isEmpty
        ? '新增'
        : after.isEmpty
        ? '删除'
        : '改写';
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.only(left: 12, bottom: 10),
      decoration: const BoxDecoration(
        border: Border(
          left: BorderSide(color: Color(0xCCB88CFF), width: 2),
          bottom: BorderSide(color: Color(0xFF343139)),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: _twinText(11, weight: FontWeight.w500),
                ),
              ),
              Text(
                updated ? '已更新' : kind,
                style: _twinText(
                  10,
                  color: updated ? const Color(0xFF79D3A7) : _compactTwinWarm,
                ),
              ),
              if (onQuote != null)
                TextButton(onPressed: onQuote, child: const Text('+ 选中')),
            ],
          ),
          if (before.isNotEmpty)
            SelectableText(
              '${after.isEmpty ? '−' : '原文：'} $before',
              contextMenuBuilder: V3TextEditing.buildContextMenu,
              style: _twinText(11, color: _twinMuted, height: 20 / 11),
            ),
          if (after.isNotEmpty)
            SelectableText(
              '${before.isEmpty ? '+' : '改为：'} $after',
              contextMenuBuilder: V3TextEditing.buildContextMenu,
              style: _twinText(
                11,
                color: const Color(0xFFDAD4E0),
                height: 20 / 11,
              ),
            ),
          Text(
            '原文 L${hunk.oldStart} · 候选 L${hunk.newStart}',
            style: _twinText(10, color: _twinMuted),
          ),
        ],
      ),
    );
  }
}

class _TwinRevisionComposer extends StatelessWidget {
  const _TwinRevisionComposer({
    required this.controller,
    required this.enabled,
    required this.onSend,
    required this.onAdd,
    required this.onVoice,
    required this.recording,
    required this.onClearCitation,
    this.citation,
  });
  final TextEditingController controller;
  final bool enabled;
  final VoidCallback onSend;
  final VoidCallback onAdd;
  final VoidCallback onVoice;
  final VoidCallback onClearCitation;
  final bool recording;
  final String? citation;
  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey('digital-twin-revision-composer'),
    margin: EdgeInsets.fromLTRB(
      24,
      8,
      24,
      math.max(30, MediaQuery.paddingOf(context).bottom),
    ),
    padding: const EdgeInsets.all(6),
    decoration: BoxDecoration(
      color: const Color(0xFF1F1D22),
      border: Border.all(color: const Color(0xFF3A363F)),
      borderRadius: BorderRadius.circular(citation == null ? 27 : 20),
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (citation != null) ...[
          Container(
            constraints: const BoxConstraints(minHeight: 32),
            decoration: BoxDecoration(
              color: _twinRail,
              borderRadius: BorderRadius.circular(8),
            ),
            padding: const EdgeInsets.only(left: 8),
            child: Row(
              children: [
                const Icon(
                  Icons.format_quote_rounded,
                  size: 15,
                  color: _twinPurple,
                ),
                const SizedBox(width: 6),
                Expanded(child: Text(citation!, style: _twinText(10))),
                IconButton(
                  tooltip: '清除引用',
                  onPressed: enabled ? onClearCitation : null,
                  constraints: const BoxConstraints.tightFor(
                    width: 32,
                    height: 32,
                  ),
                  padding: EdgeInsets.zero,
                  icon: const Icon(
                    Icons.close_rounded,
                    size: 14,
                    color: _twinMuted,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
        ],
        Row(
          children: [
            _action(
              Icons.add_rounded,
              '添加上下文',
              enabled && !recording ? onAdd : null,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: V3CenteredInput(
                key: const ValueKey('digital-twin-revision-input-target'),
                minHeight: 40,
                enabled: enabled && !recording,
                builder: (focusNode) => TextField(
                  key: const ValueKey('digital-twin-revision-input'),
                  controller: controller,
                  focusNode: focusNode,
                  contextMenuBuilder: V3TextEditing.buildContextMenu,
                  readOnly: !enabled || recording,
                  style: _twinText(12),
                  minLines: 1,
                  maxLines: 4,
                  decoration: V3TextEditing.inlineDecoration.copyWith(
                    hintText: recording ? '正在听，点击麦克风结束…' : '输入你的修改意见…',
                    hintStyle: _twinText(12, color: const Color(0xFF7E7885)),
                  ),
                  textInputAction: TextInputAction.newline,
                ),
              ),
            ),
            const SizedBox(width: 8),
            _action(
              recording ? Icons.stop_rounded : Icons.mic_none_rounded,
              recording ? '结束语音输入' : '语音输入',
              enabled || recording ? onVoice : null,
            ),
            const SizedBox(width: 8),
            ValueListenableBuilder(
              valueListenable: controller,
              builder: (context, value, _) => _action(
                Icons.arrow_upward_rounded,
                '提交修订',
                enabled && value.text.trim().isNotEmpty && !recording
                    ? onSend
                    : null,
                send: true,
              ),
            ),
          ],
        ),
      ],
    ),
  );

  Widget _action(
    IconData icon,
    String label,
    VoidCallback? onPressed, {
    bool send = false,
  }) => SizedBox(
    width: 40,
    height: 40,
    child: IconButton(
      key: send ? const ValueKey('digital-twin-revise-submit') : null,
      tooltip: label,
      onPressed: onPressed,
      padding: EdgeInsets.zero,
      style: IconButton.styleFrom(
        shape: const CircleBorder(),
        backgroundColor: send ? _twinPurple : const Color(0xFF2B282F),
        disabledBackgroundColor: send ? _twinRail : const Color(0xFF2B282F),
      ),
      icon: Icon(
        icon,
        size: send ? 20 : 22,
        color: send ? const Color(0xFF18111D) : const Color(0xFFDAD4E0),
      ),
    ),
  );
}

class _TwinRetryNotice extends StatelessWidget {
  const _TwinRetryNotice({
    required this.text,
    required this.onRetry,
    this.detail,
  });
  final String text;
  final String? detail;
  final VoidCallback? onRetry;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(text, style: _twinText(12, color: _compactTwinWarm)),
        if (detail != null)
          Text(detail!, style: _twinText(10, color: _twinMuted)),
        TextButton.icon(
          onPressed: onRetry,
          icon: const Icon(Icons.refresh_rounded, size: 16),
          label: const Text('重新核验'),
        ),
      ],
    ),
  );
}

class _TwinConfirmationProgress extends StatelessWidget {
  const _TwinConfirmationProgress({
    required this.confirmed,
    required this.referencesSaved,
    required this.remainingCount,
    required this.confirmation,
    required this.onReport,
    required this.onClose,
  });
  final bool confirmed;
  final bool referencesSaved;
  final int remainingCount;
  final DigitalTwinConfirmation? confirmation;
  final VoidCallback? onReport;
  final VoidCallback onClose;
  @override
  Widget build(BuildContext context) {
    final settled =
        confirmed &&
        confirmation?.state == 'report_ready' &&
        confirmation?.version != null;
    final partial = settled && (confirmation?.failedCount ?? 0) > 0;
    final applied = confirmation?.appliedCount ?? 0;
    if (!settled) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _TwinAgentMessage(text: '我正在校验这次修订，完成后会生成报告并写入新的数字孪生版本。'),
          const SizedBox(height: 24),
          _progressRow(
            applied > 0 ? '修改已合并' : '正在合并修改',
            applied > 0 ? '$applied 份候选已写入，正在核验正式版本' : '等待服务端确认本次修改',
            applied > 0,
          ),
          _progressRow(
            referencesSaved ? '引用关系已保留' : '正在保存引用关系',
            '来源文件与原文位置可追溯',
            referencesSaved,
          ),
          _progressRow('修订报告生成中', '报告与正式版本完成核验后进入粒子汇聚状态', false),
        ],
      );
    }
    return Column(
      children: [
        const SizedBox(height: 16),
        Container(
          width: 60,
          height: 60,
          decoration: const BoxDecoration(
            color: _twinRail,
            shape: BoxShape.circle,
          ),
          child: confirmed
              ? Icon(
                  partial ? Icons.info_outline_rounded : Icons.check_rounded,
                  size: 28,
                  color: _twinPurple,
                )
              : const Padding(
                  padding: EdgeInsets.all(19),
                  child: CircularProgressIndicator(
                    color: _twinPurple,
                    strokeWidth: 2,
                  ),
                ),
        ),
        const SizedBox(height: 20),
        Text(
          confirmed
              ? '$applied 份候选已写入当前版本'
              : applied > 0
              ? '正在核验本次修订报告'
              : '正在确认当前版本',
          textAlign: TextAlign.center,
          style: _twinText(15, weight: FontWeight.w500),
        ),
        const SizedBox(height: 12),
        Text(
          confirmed
              ? partial
                    ? '${confirmation!.failedCount} 份候选未完成，仍需返回处理。已生效内容与报告均已保留。'
                    : '修订报告已保存，当前版本已完成核验。'
              : '正在校验文件修改、引用关系与正式版本。\n离开页面不会丢失已提交的确认。',
          textAlign: TextAlign.center,
          style: _twinText(11, color: _twinMuted, height: 23 / 11),
        ),
        const SizedBox(height: 20),
        if (confirmed) ...[
          if (remainingCount > 0)
            Text(
              '仍有 $remainingCount 份候选待处理，未包含在本次确认中。',
              key: const ValueKey('digital-twin-confirmation-remaining'),
              style: _twinText(11, color: _compactTwinWarm),
            ),
          TextButton.icon(
            onPressed: onReport,
            icon: const Icon(Icons.description_outlined, size: 18),
            label: const Text('查看本次修订报告'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: _twinRail,
              foregroundColor: const Color(0xFFDAD4E0),
              minimumSize: const Size(310, 40),
            ),
            onPressed: onClose,
            child: Text(partial || remainingCount > 0 ? '返回处理剩余候选' : '返回数字孪生'),
          ),
        ] else
          Text('等待服务端报告与正式版本完成', style: _twinText(11, color: _twinMuted)),
      ],
    );
  }

  Widget _progressRow(String title, String detail, bool complete) => Padding(
    padding: const EdgeInsets.fromLTRB(8, 8, 0, 12),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 14,
          height: 14,
          child: complete
              ? const Icon(
                  Icons.check_circle_outline_rounded,
                  size: 14,
                  color: Color(0xFF79D3A7),
                )
              : const CircularProgressIndicator(
                  strokeWidth: 1.5,
                  color: _twinPurple,
                ),
        ),
        const SizedBox(width: 18),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: _twinText(12)),
              const SizedBox(height: 8),
              Text(detail, style: _twinText(10, color: _twinMuted)),
            ],
          ),
        ),
      ],
    ),
  );
}
