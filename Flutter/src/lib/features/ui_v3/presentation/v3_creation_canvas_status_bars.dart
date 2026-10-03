import 'package:flutter/material.dart';

import '../../../shared/theme/huahuo_v3_theme.dart';
import '../../chat/application/voice_message_controller.dart';
import '../domain/canvas_ai_models.dart';

final class V3CanvasVoiceStatusBar extends StatelessWidget {
  const V3CanvasVoiceStatusBar({
    required this.state,
    required this.noSpeech,
    super.key,
  });

  final VoiceMessageState state;
  final bool noSpeech;

  @override
  Widget build(BuildContext context) {
    final tokens = HuahuoV3Theme.tokensOf(context);
    final active = state.isCaptureActive || state.isBusy;
    final hasTranscript = state.liveTranscriptText.trim().isNotEmpty;
    final label = noSpeech
        ? '没有听清，点麦克风重试'
        : state.status == VoiceMessageControllerStatus.checkingPermission
        ? '正在确认麦克风权限…'
        : state.status == VoiceMessageControllerStatus.starting
        ? '正在启动语音转写…'
        : state.isBusy
        ? '正在结束录音并确认转写…'
        : state.status == VoiceMessageControllerStatus.paused
        ? '语音输入已暂停'
        : state.lastErrorCode != null
        ? '语音转写未完成，请重试'
        : active && hasTranscript
        ? '正在转写，可继续说'
        : active
        ? '正在听… 请开始说话'
        : hasTranscript
        ? '语音已转为文字'
        : '点麦克风开始语音转写';
    return Container(
      key: const ValueKey<String>('canvas-voice-status'),
      margin: const EdgeInsets.fromLTRB(20, 4, 20, 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: active
            ? tokens.accent.withValues(alpha: .08)
            : tokens.surfaceMuted,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(
            active ? Icons.mic_rounded : Icons.mic_none_rounded,
            size: 18,
            color: active ? tokens.accent : tokens.muted,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: active ? tokens.accent : tokens.text,
                fontSize: 12.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

final class V3CanvasAiRunningBar extends StatelessWidget {
  const V3CanvasAiRunningBar({
    required this.action,
    required this.onCancel,
    super.key,
  });

  final CanvasAiAction? action;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final tokens = HuahuoV3Theme.tokensOf(context);
    return Container(
      key: const ValueKey<String>('canvas-ai-running'),
      constraints: const BoxConstraints(minHeight: 44),
      margin: const EdgeInsets.fromLTRB(18, 6, 18, 8),
      padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
      decoration: BoxDecoration(
        color: tokens.canvas,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: tokens.line),
        boxShadow: const [
          BoxShadow(
            color: Color(0x14000000),
            blurRadius: 14,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          SizedBox(
            width: 3,
            height: 28,
            child: ColoredBox(color: tokens.accent),
          ),
          const SizedBox(width: 8),
          const SizedBox.square(
            dimension: 14,
            child: CircularProgressIndicator.adaptive(strokeWidth: 2),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              action == null ? '正在思考中…' : '已使用「${action!.label}」功能，正在思考中…',
              style: TextStyle(color: tokens.text, fontSize: 12.5, height: 1.3),
            ),
          ),
          IconButton(
            key: const ValueKey<String>('canvas-ai-cancel'),
            tooltip: '取消生成',
            onPressed: onCancel,
            icon: const Icon(Icons.close_rounded, size: 17),
          ),
        ],
      ),
    );
  }
}
