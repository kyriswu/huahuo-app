import 'package:flutter/material.dart';

import '../../../../shared/theme/huahuo_v3_theme.dart';
import '../../../../shared/ui_v3/v3_text_editing.dart';
import '../../../recordings/application/monologue_recording_controller.dart';
import '../../../transcription/application/live_transcript_controller.dart';
import '../../../transcription/domain/live_transcript.dart';

class V3MonologueTranscriptWindow extends StatefulWidget {
  const V3MonologueTranscriptWindow({
    required this.state,
    required this.sessionActive,
    this.liveTranscriptErrorCode,
    this.controller,
    this.transcriptText,
    this.editable = true,
    this.onChanged,
    this.flat = false,
    this.height = 146,
    super.key,
  });

  final LiveTranscriptState state;
  final bool sessionActive;
  final String? liveTranscriptErrorCode;
  final TextEditingController? controller;
  final String? transcriptText;
  final bool editable;
  final ValueChanged<String>? onChanged;
  final bool flat;
  final double? height;

  @override
  State<V3MonologueTranscriptWindow> createState() =>
      _V3MonologueTranscriptWindowState();
}

class _V3MonologueTranscriptWindowState
    extends State<V3MonologueTranscriptWindow> {
  final ScrollController _scrollController = ScrollController();
  late final TextEditingController _ownedController;
  bool _writingAutomaticText = false;
  bool _hasManualEdits = false;

  TextEditingController get _controller =>
      widget.controller ?? _ownedController;
  bool get _isControlled => widget.transcriptText != null;

  @override
  void initState() {
    super.initState();
    _ownedController = TextEditingController();
    _controller.addListener(_onTranscriptChanged);
    _applyAutomaticTranscriptAfterLayout();
    _followLatestAfterLayout();
  }

  @override
  void didUpdateWidget(covariant V3MonologueTranscriptWindow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      (oldWidget.controller ?? _ownedController).removeListener(
        _onTranscriptChanged,
      );
      _controller.addListener(_onTranscriptChanged);
    }
    final contentChanged =
        oldWidget.sessionActive != widget.sessionActive ||
        oldWidget.state.sentences != widget.state.sentences ||
        oldWidget.state.status != widget.state.status ||
        oldWidget.liveTranscriptErrorCode != widget.liveTranscriptErrorCode ||
        oldWidget.transcriptText != widget.transcriptText;
    if (!contentChanged) return;
    _applyAutomaticTranscriptAfterLayout();
    final shouldFollow =
        !_hasManualEdits &&
        (!_scrollController.hasClients ||
            _scrollController.position.maxScrollExtent -
                    _scrollController.position.pixels <=
                28);
    if (shouldFollow) _followLatestAfterLayout();
  }

  @override
  void dispose() {
    _controller.removeListener(_onTranscriptChanged);
    _ownedController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onTranscriptChanged() {
    if (_writingAutomaticText) return;
    if (!_isControlled) _hasManualEdits = true;
    widget.onChanged?.call(_controller.text);
  }

  void _applyAutomaticTranscriptAfterLayout() {
    if (!_isControlled && _hasManualEdits) return;
    final text =
        widget.transcriptText ??
        _monologueTranscriptPlainText(_visibleSentences());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          (!_isControlled && _hasManualEdits) ||
          _controller.text == text) {
        return;
      }
      _writingAutomaticText = true;
      _controller.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
      _writingAutomaticText = false;
    });
  }

  List<LiveTranscriptSentence> _visibleSentences() {
    final hasRetainedTranscript = widget.state.sentences.isNotEmpty;
    return widget.sessionActive || hasRetainedTranscript
        ? widget.state.sentences
        : const <LiveTranscriptSentence>[];
  }

  void _followLatestAfterLayout() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final sentences = _visibleSentences();
    final liveStartError = widget.liveTranscriptErrorCode;
    final exposeTranscript =
        sentences.isNotEmpty || widget.sessionActive || liveStartError != null;
    final status = liveStartError != null
        ? LiveTranscriptStatus.failed
        : exposeTranscript
        ? widget.state.status
        : LiveTranscriptStatus.idle;
    final presentation = _monologueTranscriptPresentation(
      status,
      colors: colors,
      liveStartErrorCode: liveStartError,
    );
    if (widget.flat) {
      return Semantics(
        key: const ValueKey<String>('monologue-transcript-window'),
        liveRegion: true,
        label: '实时转录，${presentation.statusLabel}',
        child: SizedBox(
          width: double.infinity,
          height: widget.height,
          child: Scrollbar(
            controller: _scrollController,
            child: TextField(
              key: const ValueKey<String>('monologue-transcript-editor'),
              controller: _controller,
              scrollController: _scrollController,
              contextMenuBuilder: V3TextEditing.buildContextMenu,
              readOnly: !widget.editable,
              showCursor: widget.editable,
              expands: true,
              minLines: null,
              maxLines: null,
              textAlignVertical: TextAlignVertical.top,
              keyboardType: TextInputType.multiline,
              cursorColor: const Color(0xffb87938),
              cursorWidth: 2,
              style: TextStyle(
                fontSize: 16,
                height: 1.65,
                fontWeight: FontWeight.w400,
                letterSpacing: 0,
                color: colors.text,
              ),
              decoration: InputDecoration(
                isDense: true,
                filled: true,
                fillColor: colors.surfaceMuted,
                contentPadding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: colors.line),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: colors.line),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: colors.primary, width: 1.4),
                ),
                hintText: (widget.transcriptText?.isEmpty ?? sentences.isEmpty)
                    ? presentation.emptyMessage
                    : null,
                hintStyle: TextStyle(
                  fontSize: 15,
                  height: 1.6,
                  fontWeight: FontWeight.w400,
                  color: colors.muted,
                ),
              ),
            ),
          ),
        ),
      );
    }
    return Semantics(
      key: const ValueKey<String>('monologue-transcript-window'),
      liveRegion: true,
      label: '实时转录，${presentation.statusLabel}',
      child: SizedBox(
        width: double.infinity,
        height: widget.height,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: colors.surfaceMuted,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: colors.line),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '实时转录',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            height: 1.2,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0,
                            color: colors.ink,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Icon(
                        presentation.icon,
                        size: 14,
                        color: presentation.color,
                      ),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          presentation.statusLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11.5,
                            height: 1.2,
                            fontWeight: FontWeight.w500,
                            letterSpacing: 0,
                            color: presentation.color,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 9),
                Expanded(
                  child: Scrollbar(
                    controller: _scrollController,
                    child: TextField(
                      key: const ValueKey<String>(
                        'monologue-transcript-editor',
                      ),
                      controller: _controller,
                      scrollController: _scrollController,
                      contextMenuBuilder: V3TextEditing.buildContextMenu,
                      readOnly: !widget.editable,
                      showCursor: widget.editable,
                      expands: true,
                      minLines: null,
                      maxLines: null,
                      textAlignVertical: TextAlignVertical.top,
                      keyboardType: TextInputType.multiline,
                      style: TextStyle(
                        fontSize: 14,
                        height: 1.5,
                        letterSpacing: 0,
                        color: colors.ink,
                      ),
                      decoration: InputDecoration(
                        isDense: true,
                        contentPadding: const EdgeInsets.only(right: 8),
                        border: InputBorder.none,
                        hintText:
                            (widget.transcriptText?.isEmpty ??
                                sentences.isEmpty)
                            ? presentation.emptyMessage
                            : null,
                        hintStyle: TextStyle(
                          fontSize: 14,
                          height: 1.5,
                          letterSpacing: 0,
                          color: colors.muted,
                        ),
                      ),
                    ),
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

bool monologueTranscriptSessionActive(MonologueRecordingState recording) {
  if (recording.isCaptureActive ||
      recording.hasNativeCapture ||
      recording.localItem != null) {
    return true;
  }
  return switch (recording.status) {
    MonologueRecordingStatus.stopping ||
    MonologueRecordingStatus.registeringLocal ||
    MonologueRecordingStatus.savingNote ||
    MonologueRecordingStatus.completed => true,
    MonologueRecordingStatus.failed =>
      recording.failureStage == MonologueFailureStage.liveTranscription ||
          recording.failureStage == MonologueFailureStage.nativeCapture ||
          recording.failureStage == MonologueFailureStage.nativeStop ||
          recording.failureStage == MonologueFailureStage.draftValidation ||
          recording.failureStage == MonologueFailureStage.localRegistration ||
          recording.failureStage == MonologueFailureStage.noteSave,
    _ => false,
  };
}

bool monologueFailureWasTranscribing(
  MonologueRecordingState? previous,
  MonologueRecordingState current,
) {
  if (current.transcriptText.trim().isNotEmpty) return true;
  return previous?.status == MonologueRecordingStatus.recording ||
      previous?.status == MonologueRecordingStatus.pausing ||
      previous?.status == MonologueRecordingStatus.paused ||
      previous?.status == MonologueRecordingStatus.resuming;
}

String monologueRecordingFailureMessage(
  MonologueFailureStage? stage,
  String errorCode,
) {
  final code = errorCode.toUpperCase();
  if (code.contains('STORAGE') || code.contains('DISK')) {
    return '录音保存失败，请检查存储空间后重试';
  }
  if (stage == MonologueFailureStage.liveTranscription) {
    return '实时转写已暂停，可修改已有文字后重试';
  }
  if (stage == MonologueFailureStage.noteSave || code.contains('NETWORK')) {
    return '独白笔记保存失败，请检查网络后重试';
  }
  if (code.contains('EMPTY') ||
      code.contains('INVALID') ||
      stage == MonologueFailureStage.draftValidation) {
    return '没有生成可用的录音文件，请重新录制';
  }
  return switch (stage) {
    MonologueFailureStage.nativeStart ||
    MonologueFailureStage.nativeCapture ||
    MonologueFailureStage.nativeStop => '录音未能正常完成，请重试或完成保存',
    MonologueFailureStage.localRegistration => '录音保存失败，请稍后重试',
    MonologueFailureStage.noteSave => '独白笔记保存失败，请稍后重试',
    _ => '独白处理失败，请稍后重试',
  };
}

final class _MonologueTranscriptPresentation {
  const _MonologueTranscriptPresentation({
    required this.statusLabel,
    required this.emptyMessage,
    required this.icon,
    required this.color,
  });

  final String statusLabel;
  final String emptyMessage;
  final IconData icon;
  final Color color;
}

_MonologueTranscriptPresentation _monologueTranscriptPresentation(
  LiveTranscriptStatus status, {
  required HuahuoV3ThemeTokens colors,
  String? liveStartErrorCode,
}) {
  if (liveStartErrorCode != null) {
    return _MonologueTranscriptPresentation(
      statusLabel: '转写暂停',
      emptyMessage: '实时转写暂时不可用，请重试后继续',
      icon: Icons.error_outline_rounded,
      color: colors.danger,
    );
  }
  return switch (status) {
    LiveTranscriptStatus.idle => _MonologueTranscriptPresentation(
      statusLabel: '待开始',
      emptyMessage: '开始独白后，文字会实时显示在这里',
      icon: Icons.mic_none_rounded,
      color: colors.muted,
    ),
    LiveTranscriptStatus.starting => _MonologueTranscriptPresentation(
      statusLabel: '连接中',
      emptyMessage: '正在连接实时转录...',
      icon: Icons.sync_rounded,
      color: colors.primary,
    ),
    LiveTranscriptStatus.transcribing => _MonologueTranscriptPresentation(
      statusLabel: '转录中',
      emptyMessage: '正在听写，识别结果会显示在这里',
      icon: Icons.graphic_eq_rounded,
      color: colors.success,
    ),
    LiveTranscriptStatus.stopping => _MonologueTranscriptPresentation(
      statusLabel: '整理中',
      emptyMessage: '正在整理本次实时转录...',
      icon: Icons.more_time_rounded,
      color: colors.primary,
    ),
    LiveTranscriptStatus.failed => _MonologueTranscriptPresentation(
      statusLabel: '转写暂停',
      emptyMessage: '实时转写暂时不可用，请重试后继续',
      icon: Icons.error_outline_rounded,
      color: colors.danger,
    ),
  };
}

String _monologueTranscriptPlainText(List<LiveTranscriptSentence> sentences) {
  return sentences
      .map((sentence) => '${_monologueSpeakerPrefix(sentence)}${sentence.text}')
      .join('\n');
}

String _monologueSpeakerPrefix(LiveTranscriptSentence sentence) {
  final displayName = sentence.speakerDisplayName?.trim();
  if (sentence.identifiesCurrentUser &&
      displayName != null &&
      displayName.isNotEmpty) {
    return '$displayName · ';
  }
  final speaker = sentence.anonymousSpeakerId;
  return speaker == null ? '' : '说话人 ${speaker + 1} · ';
}
