import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/navigation/safe_navigation.dart';
import '../../../app/bootstrap/app_providers.dart';
import '../../../core/native/native_file_port.dart';
import '../../../core/native/recording_card_native_port.dart';
import '../../../core/native/screen_capture_port.dart';
import '../../../core/native/voice_recorder_port.dart';
import '../../../shared/navigation/capture_leave_guard.dart';
import '../../../shared/theme/huahuo_v3_theme.dart';
import '../../../shared/ui_v3/v3_components.dart';
import '../../../shared/ui_v3/v3_liquid_glass.dart';
import '../../../shared/ui_v3/v3_overlays.dart';
import '../../../shared/ui_v3/v3_text_editing.dart';
import '../../ingestion/application/material_ingestion_coordinator.dart';
import '../../recordings/domain/recording_library.dart';
import '../application/knowledge_library_controller.dart';
import '../application/note_append_controller.dart';
import '../domain/feed_item_models.dart';

class V3NoteAppendPage extends ConsumerStatefulWidget {
  const V3NoteAppendPage({
    required this.targetNoteId,
    required this.source,
    super.key,
  });

  final String targetNoteId;
  final NoteAppendSource source;

  @override
  ConsumerState<V3NoteAppendPage> createState() => _V3NoteAppendPageState();
}

class _V3NoteAppendPageState extends ConsumerState<V3NoteAppendPage> {
  final TextEditingController _linkController = TextEditingController();
  final List<double> _levels = List<double>.filled(36, .08);
  _PreparedAppend? _prepared;
  StreamSubscription<VoiceLevelSample>? _levelSubscription;
  StreamSubscription<ScreenCaptureSnapshot>? _captureSubscription;
  String? _screenSessionId;
  ScreenCapturePort? _screenCapturePort;
  Timer? _voiceTimer;
  bool _busy = false;
  bool _pickerInFlight = false;
  bool _voiceRecording = false;
  bool _screenRecording = false;
  int _elapsedSeconds = 0;
  String? _errorCode;
  String? _recordingCardDownloadFileKey;
  String? _recordingCardDownloadTitle;

  bool get _isVoiceSource =>
      widget.source == NoteAppendSource.monologue ||
      widget.source == NoteAppendSource.meeting;

  bool get _isScreenSource =>
      widget.source == NoteAppendSource.internalRecording;

  @override
  void initState() {
    super.initState();
    if (_isScreenSource) {
      _screenCapturePort = ref.read(screenCapturePortProvider);
      _captureSubscription = _screenCapturePort!.events.listen(
        _applyCaptureSnapshot,
        onError: (_) => _setError('SCREEN_CAPTURE_EVENT_FAILED'),
      );
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final canAppend = ref
          .read(noteAppendControllerProvider)
          .canAppendTo(widget.targetNoteId);
      if (!canAppend) _setError('NOTE_APPEND_TARGET_NOT_EDITABLE');
    });
  }

  @override
  void dispose() {
    final sessionId = _screenSessionId;
    if (_screenRecording && sessionId != null) {
      unawaited(_screenCapturePort?.stopCapture(expectedSessionId: sessionId));
    }
    _linkController.dispose();
    _voiceTimer?.cancel();
    unawaited(_levelSubscription?.cancel());
    unawaited(_captureSubscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final library = ref.watch(knowledgeLibraryControllerProvider);
    final target = library.noteForId(widget.targetNoteId);
    final canAppend = target != null && !target.isReadOnly;
    final appendController = ref.watch(noteAppendControllerProvider);
    final recent = appendController.itemsFor(widget.targetNoteId);
    final active = recent.any(
      (item) =>
          item.status == NoteAppendStatus.uploading ||
          item.status == NoteAppendStatus.analyzing,
    );
    final disabled = _busy || _pickerInFlight || active || !canAppend;
    final residentTransferProgress =
        widget.source == NoteAppendSource.recordingCard
        ? ref
              .watch(recordingCardControllerProvider)
              .state
              .snapshot
              .transferProgress
        : null;
    final recordingCardTransferProgress =
        residentTransferProgress?.localFileKey == _recordingCardDownloadFileKey
        ? residentTransferProgress
        : null;

    final fallbackRoute =
        '/v3/feed/items/${Uri.encodeComponent(widget.targetNoteId)}';
    return CaptureLeaveGuard(
      state: _currentLeaveState(),
      fallbackRoute: fallbackRoute,
      onEndAndLeave: _endActiveCaptureForLeave,
      stateResolver: _currentLeaveState,
      child: Builder(
        builder: (guardContext) => V3PageScaffold(
          title: '追加${widget.source.label}',
          subtitle: target == null ? '目标笔记不可用' : '追加到「${target.title}」',
          centerTitle: true,
          fallbackRoute: fallbackRoute,
          onBack: () => unawaited(CaptureLeaveGuard.requestLeave(guardContext)),
          bottomBar: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 7, 20, 11),
              child: V3PrimaryButton(
                key: const ValueKey('note-append-primary-action'),
                label: _primaryLabel(active),
                icon: _primaryIcon,
                enabled: !disabled,
                onPressed: _runPrimaryAction,
              ),
            ),
          ),
          children: [
            _DemoNotice(source: widget.source),
            const SizedBox(height: 16),
            if (_isVoiceSource) _buildVoiceCapture(),
            if (_isScreenSource) _buildScreenCapture(),
            if (widget.source == NoteAppendSource.link) _buildLinkInput(),
            if (!_isVoiceSource &&
                !_isScreenSource &&
                widget.source != NoteAppendSource.link)
              _buildPickerSource(),
            if (_recordingCardDownloadFileKey != null) ...[
              const SizedBox(height: 14),
              _RecordingCardDownloadProgressCard(
                title: _recordingCardDownloadTitle ?? '录音卡文件',
                progress: recordingCardTransferProgress,
              ),
            ],
            if (_prepared != null) ...[
              const SizedBox(height: 18),
              const V3SectionTitle('待追加资料'),
              _PreparedMaterialCard(
                prepared: _prepared!,
                onClear: disabled
                    ? null
                    : () => setState(() => _prepared = null),
              ),
            ],
            if (_errorCode != null) ...[
              const SizedBox(height: 14),
              _ErrorCard(code: _errorCode!),
            ],
            if (active) ...[
              const SizedBox(height: 18),
              _AppendProgressCard(
                item: recent.firstWhere(
                  (item) =>
                      item.status == NoteAppendStatus.uploading ||
                      item.status == NoteAppendStatus.analyzing,
                ),
              ),
            ],
            const SizedBox(height: 100),
          ],
        ),
      ),
    );
  }

  CaptureLeaveState _currentLeaveState() {
    final processing = ref
        .read(noteAppendControllerProvider)
        .itemsFor(widget.targetNoteId)
        .any(
          (item) =>
              item.status == NoteAppendStatus.uploading ||
              item.status == NoteAppendStatus.analyzing,
        );
    return _appendLeaveState(
      captureActive: _voiceRecording || _screenRecording,
      captureTransitioning:
          _busy && _prepared == null && (_isVoiceSource || _isScreenSource),
      processing: processing,
    );
  }

  Widget _buildVoiceCapture() {
    return V3Card(
      key: const ValueKey('note-append-voice-capture'),
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                _voiceRecording ? Icons.mic_rounded : Icons.mic_none_rounded,
                color: _voiceRecording
                    ? const Color(0xFFB93636)
                    : HuahuoV3Theme.tokensOf(context).text,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _voiceRecording ? '正在采集真实麦克风声音' : '现场录制',
                  style: HuahuoV3Theme.listTitle,
                ),
              ),
              Text(
                _formatDuration(_elapsedSeconds),
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          SizedBox(
            height: 58,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                for (final value in _levels)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 1.2),
                      child: AnimatedContainer(
                        duration: V3MotionTokens.micro,
                        height: 4 + value * 48,
                        decoration: BoxDecoration(
                          color: _voiceRecording
                              ? HuahuoV3Theme.tokensOf(context).ink
                              : HuahuoV3Theme.tokensOf(context).line,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Text(
            _voiceRecording ? '完成后停止录制，再提交分析。' : '录音文件仅用于本次追加，不登记到本地录音库。',
            style: HuahuoV3Theme.meta.copyWith(
              color: HuahuoV3Theme.tokensOf(context).muted,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildScreenCapture() {
    return V3Card(
      key: const ValueKey('note-append-screen-capture'),
      padding: const EdgeInsets.all(18),
      child: Column(
        children: [
          V3LiquidGlassSurface(
            tone: _screenRecording ? V3GlassTone.warm : V3GlassTone.neutral,
            borderRadius: 35,
            child: SizedBox.square(
              dimension: 70,
              child: Icon(
                _screenRecording
                    ? Icons.stop_screen_share_rounded
                    : Icons.screen_share_rounded,
                size: 33,
                color: _screenRecording
                    ? const Color(0xFFC73B3B)
                    : HuahuoV3Theme.tokensOf(context).ink,
              ),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            _formatDuration(_elapsedSeconds),
            style: const TextStyle(
              fontSize: 30,
              fontWeight: FontWeight.w700,
              fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 5),
          Text(
            _screenRecording ? '系统正在跨应用录屏' : '系统授权后开始录屏，停止后再提交分析',
            textAlign: TextAlign.center,
            style: HuahuoV3Theme.body.copyWith(
              color: HuahuoV3Theme.tokensOf(context).muted,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLinkInput() {
    return V3Card(
      padding: const EdgeInsets.all(18),
      child: TextField(
        key: const ValueKey('note-append-link-input'),
        controller: _linkController,
        contextMenuBuilder: V3TextEditing.buildContextMenu,
        keyboardType: TextInputType.url,
        textInputAction: TextInputAction.done,
        autocorrect: false,
        decoration: InputDecoration(
          labelText: '网页链接',
          hintText: 'https://example.com/article',
          filled: true,
          fillColor: HuahuoV3Theme.tokensOf(context).surfaceMuted,
          prefixIcon: const Icon(Icons.link_rounded),
          suffixIcon: _linkController.text.isEmpty
              ? null
              : IconButton(
                  tooltip: '清空',
                  icon: const Icon(Icons.clear_rounded),
                  onPressed: () => setState(_linkController.clear),
                ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: BorderSide(
              color: HuahuoV3Theme.tokensOf(context).ink.withValues(alpha: .10),
            ),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: BorderSide(
              color: HuahuoV3Theme.tokensOf(context).ink.withValues(alpha: .12),
            ),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: BorderSide(
              color: HuahuoV3Theme.tokensOf(context).ink.withValues(alpha: .34),
              width: 1.2,
            ),
          ),
        ),
        onChanged: (_) => setState(() {
          _errorCode = null;
          _prepared = null;
        }),
        onSubmitted: (_) => _runPrimaryAction(),
      ),
    );
  }

  Widget _buildPickerSource() {
    final source = widget.source;
    return V3ListTileCard(
      key: const ValueKey('note-append-source-picker'),
      icon: _sourceIcon(source),
      title: _prepared == null ? '选择${source.label}' : '重新选择',
      subtitle: _pickerSubtitle(source),
      onTap: _busy || _pickerInFlight ? null : () => unawaited(_pickMaterial()),
    );
  }

  String _primaryLabel(bool active) {
    if (active) return '正在进行分析';
    if (_isVoiceSource && _prepared == null) {
      return _voiceRecording ? '停止录制' : '开始录制';
    }
    if (_isScreenSource && _prepared == null) {
      return _screenRecording ? '停止内录' : '开始内录';
    }
    if (widget.source == NoteAppendSource.link && _prepared == null) {
      return '校验链接并追加';
    }
    if (_prepared == null) return '选择${widget.source.label}';
    return '提交分析';
  }

  IconData get _primaryIcon {
    if (_isVoiceSource && _prepared == null) {
      return _voiceRecording ? Icons.stop_rounded : Icons.mic_rounded;
    }
    if (_isScreenSource && _prepared == null) {
      return _screenRecording ? Icons.stop_rounded : Icons.screen_share_rounded;
    }
    return _prepared == null ? _sourceIcon(widget.source) : Icons.add_rounded;
  }

  Future<void> _runPrimaryAction() async {
    if (_busy) return;
    if (_isVoiceSource && _prepared == null) {
      await (_voiceRecording ? _stopVoiceCapture() : _startVoiceCapture());
      return;
    }
    if (_isScreenSource && _prepared == null) {
      await (_screenRecording ? _stopScreenCapture() : _startScreenCapture());
      return;
    }
    if (widget.source == NoteAppendSource.link && _prepared == null) {
      final uri = normalizeMaterialUrl(_linkController.text);
      if (uri == null) {
        _setError('NOTE_APPEND_URL_INVALID');
        return;
      }
      setState(() {
        _prepared = _PreparedAppend(
          title: uri.host,
          referenceId: uri.toString(),
          detail: uri.toString(),
        );
        _errorCode = null;
      });
    }
    if (_prepared == null) {
      await _pickMaterial();
      return;
    }
    await _submit();
  }

  Future<void> _submit() async {
    final prepared = _prepared;
    if (prepared == null) return;
    setState(() {
      _busy = true;
      _errorCode = null;
    });
    final result = await ref
        .read(noteAppendControllerProvider)
        .submit(
          targetNoteId: widget.targetNoteId,
          source: widget.source,
          title: prepared.title,
          referenceId: prepared.referenceId,
        );
    if (!mounted) return;
    setState(() => _busy = false);
    if (result == null) {
      _setError('NOTE_APPEND_TARGET_NOT_EDITABLE');
      return;
    }
    if (result.status == NoteAppendStatus.failed) {
      _setError(result.errorCode ?? 'NOTE_APPEND_DEMO_SUBMISSION_FAILED');
      return;
    }
    showV3Snack(context, '资料已追加，本次会话内可见');
    unawaited(
      returnToPreviousRoute(
        context,
        fallbackRoute:
            '/v3/feed/items/${Uri.encodeComponent(widget.targetNoteId)}',
      ),
    );
  }

  Future<void> _pickMaterial() async {
    if (_busy || _pickerInFlight) return;
    setState(() {
      _pickerInFlight = true;
      _errorCode = null;
    });
    try {
      final prepared = switch (widget.source) {
        NoteAppendSource.phoneAudio => await _pickPhoneAudio(),
        NoteAppendSource.localRecording => await _pickLocalRecording(),
        NoteAppendSource.recordingCard => await _pickRecordingCardFile(),
        NoteAppendSource.document => await _pickDocument(),
        NoteAppendSource.media => await _pickMedia(),
        NoteAppendSource.relatedNote => await _pickRelatedNote(),
        _ => null,
      };
      if (!mounted) return;
      setState(() {
        if (prepared != null) _prepared = prepared;
        _pickerInFlight = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _pickerInFlight = false;
        _errorCode = 'NOTE_APPEND_SOURCE_SELECTION_FAILED';
      });
    }
  }

  Future<_PreparedAppend?> _pickPhoneAudio() async {
    final result = await ref.read(nativeFilePortProvider).pickAudioFiles();
    final files = result.value;
    if (!result.ok || files == null || files.isEmpty) {
      if (!result.cancelled &&
          result.error?.code != 'RECORDING_PICKER_CANCELLED') {
        _setError(result.error?.code ?? 'RECORDING_PICKER_EMPTY');
      }
      return null;
    }
    final file = files.first;
    return _PreparedAppend(
      title: file.displayName,
      referenceId: file.contentHash ?? file.pickerRef,
      detail: _bytes(file.sizeBytes),
    );
  }

  Future<_PreparedAppend?> _pickDocument() async {
    final result = await ref.read(nativeFilePortProvider).pickDocumentFiles();
    final files = result.value;
    if (!result.ok || files == null || files.isEmpty) {
      if (!result.cancelled &&
          result.error?.code != 'DOCUMENT_PICKER_CANCELLED') {
        _setError(result.error?.code ?? 'DOCUMENT_PICKER_EMPTY');
      }
      return null;
    }
    final file = files.first;
    return _PreparedAppend(
      title: file.displayName,
      referenceId: file.pickerRef,
      detail: _bytes(file.sizeBytes),
    );
  }

  Future<_PreparedAppend?> _pickMedia() async {
    final option =
        await showV3GlassBottomSheet<
          ({NativeMediaKind kind, NativeMediaSource source})
        >(
          context: context,
          isScrollControlled: true,
          builder: (sheetContext) => V3SheetScaffold(
            maxHeightFactor: .88,
            child: Flexible(
              child: ListView(
                key: const ValueKey('note-append-media-options'),
                shrinkWrap: true,
                padding: const EdgeInsets.only(top: 4, bottom: 6),
                children: [
                  const Text(
                    '选择相册资料',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 10),
                  for (final option in const [
                    (
                      kind: NativeMediaKind.image,
                      source: NativeMediaSource.gallery,
                    ),
                    (
                      kind: NativeMediaKind.video,
                      source: NativeMediaSource.gallery,
                    ),
                    (
                      kind: NativeMediaKind.image,
                      source: NativeMediaSource.camera,
                    ),
                    (
                      kind: NativeMediaKind.video,
                      source: NativeMediaSource.camera,
                    ),
                  ])
                    ListTile(
                      leading: Icon(
                        option.kind == NativeMediaKind.image
                            ? Icons.image_outlined
                            : Icons.videocam_outlined,
                      ),
                      title: Text(
                        '${option.source == NativeMediaSource.camera ? '拍摄' : '相册'}${option.kind == NativeMediaKind.image ? '图片' : '视频'}',
                      ),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => Navigator.of(sheetContext).pop(option),
                    ),
                ],
              ),
            ),
          ),
        );
    if (option == null || !mounted) return null;
    final result = await ref
        .read(nativeFilePortProvider)
        .pickMediaFiles(kind: option.kind, source: option.source);
    final files = result.value;
    if (!result.ok || files == null || files.isEmpty) {
      if (!result.cancelled && result.error?.code != 'MEDIA_PICKER_CANCELLED') {
        _setError(result.error?.code ?? 'MEDIA_PICKER_EMPTY');
      }
      return null;
    }
    final file = files.first;
    return _PreparedAppend(
      title: file.displayName,
      referenceId: file.pickerRef,
      detail:
          '${file.kind == NativeMediaKind.image ? '图片' : '视频'} · ${_bytes(file.sizeBytes)}',
    );
  }

  Future<_PreparedAppend?> _pickLocalRecording() async {
    final controller = ref.read(recordingLibraryControllerProvider);
    await controller.load();
    if (!mounted) return null;
    final candidates = controller.state.items
        .where(
          (item) =>
              item.status != RecordingLibraryStatus.recycled &&
              item.localFileState == RecordingLocalFileState.ready &&
              item.appPrivateUri != null,
        )
        .toList();
    final selected = await _showSearchPicker<RecordingLibraryItem>(
      title: '选择本地录音',
      items: candidates,
      label: (item) => item.displayName,
      subtitle: (item) =>
          '${_formatDuration(item.durationSeconds)} · ${_bytes(item.sizeBytes)}',
      icon: (_) => Icons.audio_file_outlined,
    );
    if (selected == null) return null;
    return _PreparedAppend(
      title: selected.displayName,
      referenceId: selected.contentHash ?? selected.appPrivateUri,
      detail:
          '${_formatDuration(selected.durationSeconds)} · ${_bytes(selected.sizeBytes)}',
    );
  }

  Future<_PreparedAppend?> _pickRecordingCardFile() async {
    final controller = ref.read(recordingCardControllerProvider);
    if (!controller.state.snapshot.deviceState.isOperationallyConnected) {
      _setError('RECORDING_CARD_NOT_CONNECTED');
      return null;
    }
    await controller.scanFiles();
    if (!mounted) return null;
    final selected = await _showSearchPicker<RecordingCardScannedFile>(
      title: '选择录音卡文件',
      items: controller.state.snapshot.files,
      label: (item) => item.deviceFilename,
      subtitle: (item) => item.appPrivateUri == null
          ? '${_bytes(item.sizeBytes ?? 0)} · 选择后蓝牙下载'
          : '${_bytes(item.sizeBytes ?? 0)} · 已在本地',
      icon: (item) => item.appPrivateUri == null
          ? Icons.bluetooth_rounded
          : Icons.download_done_rounded,
    );
    if (selected == null) return null;
    final local = selected;
    RecordingCardDownloadedFile? downloaded;
    if (local.appPrivateUri == null) {
      final downloadFileKey = local.localFileKey;
      setState(() {
        _recordingCardDownloadFileKey = downloadFileKey;
        _recordingCardDownloadTitle = local.deviceFilename;
        _errorCode = null;
      });
      try {
        final result = await controller.downloadFileResult(local);
        if (!mounted) return null;
        final receipt = result.value;
        if (!result.ok ||
            receipt == null ||
            receipt.localFileKey != downloadFileKey) {
          _setError(
            result.error?.code ??
                controller.state.lastErrorCode ??
                'RECORDING_CARD_DOWNLOAD_NOT_AVAILABLE',
          );
          return null;
        }
        downloaded = receipt;
      } finally {
        if (mounted && _recordingCardDownloadFileKey == downloadFileKey) {
          setState(() {
            _recordingCardDownloadFileKey = null;
            _recordingCardDownloadTitle = null;
          });
        }
      }
    }
    final localUri = downloaded?.appPrivateUri ?? local.appPrivateUri;
    return _PreparedAppend(
      title: downloaded?.displayName ?? local.deviceFilename,
      referenceId: downloaded?.contentHash ?? local.contentHash ?? localUri,
      detail:
          '${_bytes(downloaded?.sizeBytes ?? local.sizeBytes ?? 0)} · 录音卡文件',
    );
  }

  Future<_PreparedAppend?> _pickRelatedNote() async {
    final notes = ref
        .read(knowledgeLibraryControllerProvider)
        .notes
        .where((note) => note.id != widget.targetNoteId)
        .toList();
    final selected = await _showSearchPicker<V3FeedItem>(
      title: '关联已有笔记',
      items: notes,
      label: (item) => item.title,
      subtitle: (item) => '${item.source.label} · ${item.ownership.label}',
      icon: (_) => Icons.note_alt_outlined,
    );
    if (selected == null) {
      return null;
    }
    return _PreparedAppend(
      title: selected.title,
      referenceId: selected.id,
      detail: '${selected.source.label} · 已有笔记',
    );
  }

  Future<T?> _showSearchPicker<T>({
    required String title,
    required List<T> items,
    required String Function(T item) label,
    required String Function(T item) subtitle,
    required IconData Function(T item) icon,
  }) {
    return showV3GlassBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) {
        var query = '';
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final filtered = query.trim().isEmpty
                ? items
                : items
                      .where(
                        (item) => label(
                          item,
                        ).toLowerCase().contains(query.trim().toLowerCase()),
                      )
                      .toList();
            final mediaQuery = MediaQuery.of(context);
            final availableHeight =
                mediaQuery.size.height -
                mediaQuery.viewInsets.bottom -
                mediaQuery.padding.bottom;
            final compactKeyboard =
                mediaQuery.viewInsets.bottom > 0 && availableHeight < 260;
            final searchField = TextField(
              key: const ValueKey('note-append-search-picker-input'),
              contextMenuBuilder: V3TextEditing.buildContextMenu,
              decoration: InputDecoration(
                hintText: '搜索',
                prefixIcon: const Icon(Icons.search_rounded),
                isDense: compactKeyboard,
                constraints: compactKeyboard
                    ? const BoxConstraints.tightFor(height: 44)
                    : null,
                filled: true,
                fillColor: HuahuoV3Theme.tokensOf(sheetContext).surfaceMuted,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(18),
                  borderSide: BorderSide.none,
                ),
              ),
              onChanged: (value) => setSheetState(() => query = value),
            );
            return AnimatedPadding(
              key: const ValueKey('note-append-search-picker-keyboard-inset'),
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              padding: EdgeInsets.only(
                bottom: MediaQuery.viewInsetsOf(context).bottom,
              ),
              child: V3SheetScaffold(
                title: compactKeyboard ? null : title,
                showClose: !compactKeyboard,
                maxHeightFactor: compactKeyboard ? 1 : .68,
                child: Expanded(
                  child: Column(
                    children: [
                      if (compactKeyboard)
                        Row(
                          children: [
                            Expanded(child: searchField),
                            IconButton(
                              tooltip: '关闭',
                              constraints: const BoxConstraints.tightFor(
                                width: 44,
                                height: 44,
                              ),
                              onPressed: () => Navigator.of(sheetContext).pop(),
                              icon: const Icon(Icons.close_rounded),
                            ),
                          ],
                        )
                      else
                        searchField,
                      SizedBox(height: compactKeyboard ? 4 : 8),
                      Expanded(
                        child: filtered.isEmpty
                            ? const Center(child: Text('没有可选择的资料'))
                            : ListView.separated(
                                padding: const EdgeInsets.fromLTRB(0, 4, 0, 8),
                                itemCount: filtered.length,
                                separatorBuilder: (_, __) =>
                                    const SizedBox(height: 2),
                                itemBuilder: (context, index) {
                                  final item = filtered[index];
                                  return ListTile(
                                    leading: Icon(icon(item)),
                                    title: Text(
                                      label(item),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    subtitle: Text(subtitle(item), maxLines: 1),
                                    trailing: const Icon(
                                      Icons.chevron_right_rounded,
                                    ),
                                    onTap: () =>
                                        Navigator.of(sheetContext).pop(item),
                                  );
                                },
                              ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _startVoiceCapture() async {
    setState(() {
      _busy = true;
      _errorCode = null;
    });
    final recorder = ref.read(voiceRecorderPortProvider);
    var permission = await recorder.getMicrophonePermission();
    if (!permission.ok || permission.value == null) {
      if (mounted) {
        _finishWithError(
          permission.error?.code ?? 'VOICE_RECORDER_PERMISSION_UNAVAILABLE',
        );
      }
      return;
    }
    if (!permission.value!.granted && permission.value!.canAskAgain) {
      permission = await recorder.requestMicrophonePermission();
    }
    if (!permission.ok || permission.value?.granted != true) {
      if (mounted) {
        _finishWithError(
          permission.error?.code ?? 'VOICE_RECORDER_PERMISSION_DENIED',
        );
      }
      return;
    }
    final started = await recorder.startRecording(
      scene: widget.source == NoteAppendSource.meeting
          ? VoiceRecordingScene.meeting
          : VoiceRecordingScene.monologue,
    );
    if (!mounted) return;
    if (!started.ok || started.value == null) {
      _finishWithError(started.error?.code ?? 'VOICE_RECORDER_START_FAILED');
      return;
    }
    await _levelSubscription?.cancel();
    _levelSubscription = recorder.levelSamples.listen(_appendVoiceLevel);
    _voiceTimer?.cancel();
    _voiceTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      unawaited(_refreshVoiceState());
    });
    setState(() {
      _busy = false;
      _voiceRecording = true;
      _elapsedSeconds = started.value!.elapsedSeconds;
      _levels.fillRange(0, _levels.length, .08);
    });
  }

  Future<void> _refreshVoiceState() async {
    final result = await ref.read(voiceRecorderPortProvider).refreshState();
    if (!mounted || !result.ok || result.value == null) return;
    final session = result.value!.session;
    if (session == null) return;
    setState(() => _elapsedSeconds = session.elapsedSeconds);
  }

  void _appendVoiceLevel(VoiceLevelSample sample) {
    if (!mounted || !_voiceRecording) return;
    final value = (.68 * sample.average + .32 * sample.peak).clamp(.04, 1.0);
    setState(() {
      _levels
        ..removeAt(0)
        ..add(value);
    });
  }

  Future<bool> _stopVoiceCapture() async {
    setState(() => _busy = true);
    _voiceTimer?.cancel();
    await _levelSubscription?.cancel();
    _levelSubscription = null;
    final result = await ref.read(voiceRecorderPortProvider).stopRecording();
    if (!mounted) return false;
    if (!result.ok || result.value == null) {
      _finishWithError(result.error?.code ?? 'VOICE_RECORDER_STOP_FAILED');
      return false;
    }
    final draft = result.value!;
    setState(() {
      _busy = false;
      _voiceRecording = false;
      _elapsedSeconds = draft.durationSeconds;
      _prepared = _PreparedAppend(
        title:
            '${widget.source.label}录音 ${_formatDuration(draft.durationSeconds)}',
        referenceId: draft.appPrivateUri,
        detail:
            '${_formatDuration(draft.durationSeconds)} · ${_bytes(draft.sizeBytes)}',
      );
    });
    return true;
  }

  Future<void> _startScreenCapture() async {
    setState(() {
      _busy = true;
      _errorCode = null;
    });
    final port = ref.read(screenCapturePortProvider);
    final capability = await port.getCapability();
    if (!mounted) return;
    if (!capability.ok || capability.value?.supported != true) {
      _finishWithError(
        capability.error?.code ??
            capability.value?.reasonCode ??
            'SCREEN_CAPTURE_UNSUPPORTED',
      );
      return;
    }
    final random = Random.secure();
    final sessionId =
        'append-${List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
    _screenSessionId = sessionId;
    final result = await port.startCapture(sessionId: sessionId);
    if (!mounted) {
      unawaited(port.stopCapture(expectedSessionId: sessionId));
      return;
    }
    if (!result.ok || result.value == null) {
      _finishWithError(result.error?.code ?? 'SCREEN_CAPTURE_START_FAILED');
      return;
    }
    _applyCaptureSnapshot(result.value!);
    setState(() => _busy = false);
  }

  Future<bool> _stopScreenCapture() async {
    final sessionId = _screenSessionId;
    if (sessionId == null) return false;
    setState(() => _busy = true);
    final result = await ref
        .read(screenCapturePortProvider)
        .stopCapture(expectedSessionId: sessionId);
    if (!mounted) return false;
    if (!result.ok || result.value == null) {
      _finishWithError(result.error?.code ?? 'SCREEN_CAPTURE_STOP_FAILED');
      return false;
    }
    _applyCaptureSnapshot(result.value!);
    setState(() => _busy = false);
    return true;
  }

  Future<bool> _endActiveCaptureForLeave() async {
    if (_voiceRecording) return _stopVoiceCapture();
    if (_screenRecording) return _stopScreenCapture();
    return false;
  }

  void _applyCaptureSnapshot(ScreenCaptureSnapshot snapshot) {
    if (!mounted ||
        _screenSessionId == null ||
        snapshot.sessionId != _screenSessionId) {
      return;
    }
    final media = snapshot.media;
    setState(() {
      _screenRecording =
          snapshot.state == ScreenCaptureState.recording ||
          snapshot.state == ScreenCaptureState.starting ||
          snapshot.state == ScreenCaptureState.stopping;
      _elapsedSeconds = snapshot.elapsedSeconds;
      if (snapshot.state == ScreenCaptureState.failed) {
        _errorCode = snapshot.lastErrorCode ?? 'SCREEN_CAPTURE_FAILED';
      }
      if (media != null) {
        _screenRecording = false;
        _prepared = _PreparedAppend(
          title: '内录 ${_formatDuration(media.durationSeconds)}',
          referenceId: media.appPrivateUri,
          detail:
              '${_formatDuration(media.durationSeconds)} · ${_bytes(media.sizeBytes)}',
        );
      }
    });
  }

  void _finishWithError(String code) {
    setState(() {
      _busy = false;
      _voiceRecording = false;
      _screenRecording = false;
      _errorCode = code;
    });
  }

  void _setError(String code) {
    if (!mounted) return;
    setState(() => _errorCode = code);
  }

  String _pickerSubtitle(NoteAppendSource source) => switch (source) {
    NoteAppendSource.phoneAudio => '从系统文件中选择音频，真实校验文件',
    NoteAppendSource.localRecording => '从本地录音库选择可播放文件',
    NoteAppendSource.recordingCard => '扫描设备并在需要时通过蓝牙下载',
    NoteAppendSource.document => '从系统文件中选择文档',
    NoteAppendSource.media => '从相册选择或使用相机拍摄',
    NoteAppendSource.relatedNote => '从记忆库选择另一篇已有笔记',
    _ => '选择要追加的资料',
  };
}

CaptureLeaveState _appendLeaveState({
  required bool captureActive,
  required bool captureTransitioning,
  required bool processing,
}) {
  if (captureActive || captureTransitioning) {
    return CaptureLeaveState.capturing;
  }
  return processing ? CaptureLeaveState.processing : CaptureLeaveState.idle;
}

class _PreparedAppend {
  const _PreparedAppend({
    required this.title,
    required this.detail,
    this.referenceId,
  });

  final String title;
  final String detail;
  final String? referenceId;
}

class _DemoNotice extends StatelessWidget {
  const _DemoNotice({required this.source});

  final NoteAppendSource source;

  @override
  Widget build(BuildContext context) => V3Card(
    tone: V3GlassTone.warm,
    padding: const EdgeInsets.all(14),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          Icons.science_outlined,
          size: 20,
          color: HuahuoV3Theme.tokensOf(context).accent,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            '${source.label}采集和校验会真实执行；上传、分析及摘要更新仅在本次会话内保留，退出登录或重启后清除，不写入正式记忆库。',
            style: HuahuoV3Theme.meta.copyWith(
              color: HuahuoV3Theme.tokensOf(context).accent,
              height: 1.45,
            ),
          ),
        ),
      ],
    ),
  );
}

class _PreparedMaterialCard extends StatelessWidget {
  const _PreparedMaterialCard({required this.prepared, required this.onClear});

  final _PreparedAppend prepared;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) => V3Card(
    tone: V3GlassTone.cool,
    padding: const EdgeInsets.fromLTRB(15, 13, 8, 13),
    child: Row(
      children: [
        Icon(
          Icons.check_circle_rounded,
          color: HuahuoV3Theme.tokensOf(context).success,
        ),
        const SizedBox(width: 11),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                prepared.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: HuahuoV3Theme.listTitle,
              ),
              const SizedBox(height: 4),
              Text(
                prepared.detail,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: HuahuoV3Theme.meta.copyWith(
                  color: HuahuoV3Theme.tokensOf(context).muted,
                ),
              ),
            ],
          ),
        ),
        IconButton(
          tooltip: '移除',
          onPressed: onClear,
          icon: const Icon(Icons.close_rounded),
        ),
      ],
    ),
  );
}

class _AppendProgressCard extends StatelessWidget {
  const _AppendProgressCard({required this.item});

  final V3AppendMaterial item;

  @override
  Widget build(BuildContext context) => V3Card(
    tone: V3GlassTone.cool,
    padding: const EdgeInsets.all(14),
    child: Row(
      children: [
        const SizedBox(
          width: 21,
          height: 21,
          child: CircularProgressIndicator(strokeWidth: 2.2),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            item.status == NoteAppendStatus.uploading ? '上传中' : '分析中',
            style: HuahuoV3Theme.body.copyWith(fontWeight: FontWeight.w600),
          ),
        ),
      ],
    ),
  );
}

class _RecordingCardDownloadProgressCard extends StatelessWidget {
  const _RecordingCardDownloadProgressCard({
    required this.title,
    required this.progress,
  });

  final String title;
  final RecordingCardTransferProgress? progress;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final current = progress;
    return V3Card(
      key: const ValueKey('note-append-recording-card-download-progress'),
      tone: V3GlassTone.cool,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.bluetooth_rounded, color: colors.accent),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('正在通过蓝牙下载', style: HuahuoV3Theme.listTitle),
                    const SizedBox(height: 3),
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: HuahuoV3Theme.meta.copyWith(color: colors.muted),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          LinearProgressIndicator(value: current?.fraction),
          const SizedBox(height: 8),
          Text(
            current == null
                ? '正在建立传输连接'
                : _recordingCardTransferDetail(current),
            key: const ValueKey(
              'note-append-recording-card-download-progress-detail',
            ),
            style: HuahuoV3Theme.meta.copyWith(color: colors.muted),
          ),
        ],
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.code});

  final String code;

  @override
  Widget build(BuildContext context) => V3Card(
    tone: V3GlassTone.warm,
    padding: const EdgeInsets.all(14),
    child: Row(
      children: [
        Icon(
          Icons.error_outline_rounded,
          color: HuahuoV3Theme.tokensOf(context).danger,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            _errorMessage(code),
            style: HuahuoV3Theme.body.copyWith(
              color: HuahuoV3Theme.tokensOf(context).danger,
            ),
          ),
        ),
      ],
    ),
  );
}

IconData _sourceIcon(NoteAppendSource source) => switch (source) {
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

String _formatDuration(int seconds) {
  final safe = seconds < 0 ? 0 : seconds;
  final minutes = safe ~/ 60;
  final remainder = safe % 60;
  return '${minutes.toString().padLeft(2, '0')}:${remainder.toString().padLeft(2, '0')}';
}

String _bytes(int size) {
  if (size < 1024) return '$size B';
  if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
  return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
}

String _recordingCardTransferDetail(RecordingCardTransferProgress progress) {
  final totalBytes = progress.totalBytes;
  final bytesPerSecond = progress.bytesPerSecond;
  final eta =
      progress.estimatedRemainingSeconds ??
      (totalBytes != null && bytesPerSecond != null && bytesPerSecond > 0
          ? ((totalBytes - progress.receivedBytes).clamp(0, totalBytes) /
                    bytesPerSecond)
                .ceil()
          : null);
  final parts = <String>[
    totalBytes == null
        ? '已传输 ${_bytes(progress.receivedBytes)}'
        : '${_bytes(progress.receivedBytes)} / ${_bytes(totalBytes)}',
    if (bytesPerSecond != null && bytesPerSecond > 0)
      '${_bytes(bytesPerSecond.round())}/s',
    if (eta != null) '预计剩余 ${_transferEta(eta)}',
  ];
  return parts.join(' · ');
}

String _transferEta(int seconds) {
  if (seconds <= 0) return '即将完成';
  if (seconds < 60) return '$seconds 秒';
  final minutes = seconds ~/ 60;
  final remainder = seconds % 60;
  if (minutes < 60) {
    return remainder == 0 ? '$minutes 分钟' : '$minutes 分 $remainder 秒';
  }
  final hours = minutes ~/ 60;
  final remainingMinutes = minutes % 60;
  return remainingMinutes == 0 ? '$hours 小时' : '$hours 小时 $remainingMinutes 分';
}

String _errorMessage(String code) => switch (code) {
  'NOTE_APPEND_TARGET_NOT_EDITABLE' => '目标笔记不存在、已删除或当前不可编辑。',
  'NOTE_APPEND_URL_INVALID' => '请输入有效的 http 或 https 链接。',
  'RECORDING_CARD_NOT_CONNECTED' => '请先连接录音卡，再选择设备文件。',
  'VOICE_RECORDER_PERMISSION_DENIED' => '未获得麦克风权限，无法开始录制。',
  'SCREEN_CAPTURE_UNSUPPORTED' => '当前设备不支持跨应用内录。',
  _ => '操作未完成（$code），请重试。',
};
