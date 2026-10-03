import 'package:flutter/material.dart';

import '../../../shared/ui_v3/v3_components.dart';

enum LiveTranscriptionFailureDialogAction { dismiss, retry, openSettings }

enum LiveTranscriptionFailureContext { realtime, recording }

final class LiveTranscriptionFailureDialogGate {
  final Set<String> _presentedAttempts = <String>{};
  int _requestSequence = 0;
  int _activeRequestId = 0;
  bool _dialogOpen = false;

  void beginAttempt() {
    _activeRequestId = ++_requestSequence;
  }

  bool claim({required String owner, int? attemptId}) {
    if (_dialogOpen) return false;
    final normalizedOwner = owner.trim();
    if (normalizedOwner.isEmpty) return false;
    final key = attemptId == null
        ? '$normalizedOwner:request:$_activeRequestId'
        : '$normalizedOwner:attempt:$attemptId';
    if (!_presentedAttempts.add(key)) return false;
    _dialogOpen = true;
    return true;
  }

  void release() {
    _dialogOpen = false;
  }
}

bool isLiveTranscriptionPermissionError(String? errorCode) =>
    switch (errorCode?.trim().toUpperCase()) {
      'VOICE_RECORDER_PERMISSION_DENIED' ||
      'VOICE_RECORDER_PERMISSION_BLOCKED' ||
      'VOICE_RECORDER_PERMISSION_NOT_GRANTED' => true,
      _ => false,
    };

bool isLiveTranscriptionRetryableError(String? errorCode) {
  final normalized = errorCode?.trim().toUpperCase();
  if (normalized == null || normalized.isEmpty) return false;
  if (isLiveTranscriptionPermissionError(normalized)) return false;
  return normalized == 'ASR_PROVIDER_FAILED' ||
      normalized == 'ASR_PROVIDER_RATE_LIMITED' ||
      normalized == 'ASR_TIMEOUT' ||
      normalized == 'REALTIME_ASR_SESSION_UNAVAILABLE' ||
      normalized == 'ASR_CREDENTIAL_EXPIRED' ||
      normalized == 'ASR_CREDENTIAL_REQUEST_FAILED' ||
      normalized == 'AUTH_TOKEN_READ_FAILED' ||
      normalized == 'LIVE_ASR_SESSION_NETWORK_FAILED' ||
      normalized == 'LIVE_ASR_SESSION_RATE_LIMITED' ||
      normalized == 'LIVE_ASR_SESSION_REQUEST_FAILED' ||
      normalized == 'LIVE_ASR_SESSION_SERVER_UNAVAILABLE' ||
      normalized == 'LIVE_ASR_RECONNECT_EXHAUSTED' ||
      normalized == 'TENCENT_LIVE_ASR_AUDIO_SOURCE_NOT_READY' ||
      normalized == 'TENCENT_LIVE_ASR_AUDIO_SOURCE_START_FAILED' ||
      normalized == 'TENCENT_LIVE_ASR_AUDIO_SOURCE_TIMEOUT' ||
      normalized == 'TENCENT_LIVE_ASR_FLOW_START_TIMEOUT' ||
      normalized == 'TENCENT_LIVE_ASR_MICROPHONE_BUSY' ||
      normalized == 'TENCENT_LIVE_ASR_NATIVE_EVENT_FAILED' ||
      normalized == 'TENCENT_LIVE_ASR_NETWORK_FAILED' ||
      normalized == 'TENCENT_LIVE_ASR_PROVIDER_RATE_LIMITED' ||
      normalized == 'TENCENT_LIVE_ASR_PROVIDER_UNAVAILABLE' ||
      normalized == 'TENCENT_LIVE_ASR_RECOGNITION_FAILED' ||
      normalized == 'TENCENT_LIVE_ASR_SESSION_BUSY' ||
      normalized == 'TENCENT_LIVE_ASR_SESSION_SUPERSEDED' ||
      normalized == 'TENCENT_LIVE_ASR_SHARED_PCM_UNAVAILABLE' ||
      normalized == 'TENCENT_LIVE_ASR_START_FAILED' ||
      normalized == 'TENCENT_LIVE_ASR_START_PREREQUISITES_TIMEOUT' ||
      normalized == 'TENCENT_LIVE_ASR_START_TIMEOUT' ||
      normalized == 'TENCENT_LIVE_ASR_TIMEOUT' ||
      normalized == 'TENCENT_LIVE_ASR_TRANSPORT_TIMEOUT' ||
      normalized == 'TENCENT_LIVE_ASR_WRITE_FAILED' ||
      normalized == 'VOICE_RECORDER_AUDIO_INTERRUPTED' ||
      normalized == 'VOICE_RECORDER_BUSY' ||
      normalized == 'VOICE_RECORDER_CAPTURE_ENDED' ||
      normalized == 'VOICE_RECORDER_FOREGROUND_SERVICE_FAILED' ||
      normalized == 'VOICE_RECORDER_PCM_CAPTURE_FAILED' ||
      normalized == 'VOICE_RECORDER_PERMISSION_REQUEST_FAILED' ||
      normalized == 'VOICE_RECORDER_PERMISSION_REQUEST_TIMEOUT' ||
      normalized == 'VOICE_RECORDER_START_FAILED' ||
      normalized == 'VOICE_RECORDER_STATE_REFRESH_FAILED' ||
      normalized == 'VOICE_TRANSCRIPTION_FAILED' ||
      normalized == 'CHAT_LIVE_TRANSCRIPT_START_FAILED';
}

Future<LiveTranscriptionFailureDialogAction>
showLiveTranscriptionFailureDialog({
  required BuildContext context,
  required String errorCode,
  bool wasTranscribing = false,
  LiveTranscriptionFailureContext failureContext =
      LiveTranscriptionFailureContext.realtime,
}) async {
  final route = ModalRoute.of(context);
  if (route != null && !route.isCurrent) {
    return LiveTranscriptionFailureDialogAction.dismiss;
  }
  final permissionError = isLiveTranscriptionPermissionError(errorCode);
  final retryable = isLiveTranscriptionRetryableError(errorCode);
  final recordingFailure =
      failureContext == LiveTranscriptionFailureContext.recording;
  final action = await showDialog<LiveTranscriptionFailureDialogAction>(
    context: context,
    builder: (dialogContext) => V3GlassDialog(
      title: permissionError
          ? '需要麦克风权限'
          : recordingFailure
          ? '录音启动失败'
          : wasTranscribing
          ? '实时转写已停止'
          : '实时转写启动失败',
      message: permissionError
          ? '请在系统设置中允许使用麦克风，然后重新开始。'
          : recordingFailure
          ? _recordingFailureMessage(errorCode)
          : _failureMessage(errorCode),
      primaryLabel: permissionError
          ? '去设置'
          : retryable
          ? '重试'
          : '关闭',
      onPrimary: () => Navigator.of(dialogContext).pop(
        permissionError
            ? LiveTranscriptionFailureDialogAction.openSettings
            : retryable
            ? LiveTranscriptionFailureDialogAction.retry
            : LiveTranscriptionFailureDialogAction.dismiss,
      ),
      showCancel: permissionError || retryable,
      onCancel: () => Navigator.of(
        dialogContext,
      ).pop(LiveTranscriptionFailureDialogAction.dismiss),
    ),
  );
  return action ?? LiveTranscriptionFailureDialogAction.dismiss;
}

String _recordingFailureMessage(String errorCode) {
  final normalized = errorCode.trim().toUpperCase();
  if (normalized == 'VOICE_RECORDER_START_FAILED' ||
      normalized == 'VOICE_RECORDER_AUDIO_INTERRUPTED' ||
      normalized == 'VOICE_RECORDER_CAPTURE_ENDED') {
    return '麦克风录音未能启动，请稍后重试。';
  }
  if (normalized == 'VOICE_RECORDER_PCM_CAPTURE_FAILED' ||
      normalized == 'VOICE_RECORDER_STATE_REFRESH_FAILED') {
    return '麦克风音频暂时不可用，请稍后重试。';
  }
  if (isLiveTranscriptionRetryableError(normalized)) {
    return '录音暂时未能启动，请稍后重试。';
  }
  return '当前设备无法使用麦克风录音，请关闭后继续。';
}

String _failureMessage(String errorCode) {
  final normalized = errorCode.trim().toUpperCase();
  final providerMessage = switch (normalized) {
    'TENCENT_LIVE_ASR_PROVIDER_AUTH_FAILED' => '实时转写服务鉴权失败，请联系支持。',
    'TENCENT_LIVE_ASR_PROVIDER_REQUEST_INVALID' => '实时转写请求参数不兼容，请联系支持。',
    'TENCENT_LIVE_ASR_PROVIDER_NOT_ENABLED' => '实时转写服务尚未开通，请联系支持。',
    'TENCENT_LIVE_ASR_PROVIDER_QUOTA_EXHAUSTED' => '实时转写服务额度已用尽，请联系支持。',
    'TENCENT_LIVE_ASR_PROVIDER_SUSPENDED' => '实时转写服务已暂停，请联系支持。',
    'TENCENT_LIVE_ASR_PROVIDER_RATE_LIMITED' => '实时转写服务繁忙，请稍后重试。',
    'TENCENT_LIVE_ASR_PROVIDER_AUDIO_INVALID' => '实时转写音频格式不兼容，请联系支持。',
    'TENCENT_LIVE_ASR_AUDIO_SOURCE_TIMEOUT' => '实时转写未能持续收到音频，请重新开始。',
    'TENCENT_LIVE_ASR_PROVIDER_UNAVAILABLE' => '实时转写服务暂时异常，请稍后重试。',
    'TENCENT_LIVE_ASR_PROVIDER_REGION_RESTRICTED' =>
      '当前网络出口所在地区不支持此转写服务，请检查代理设置或联系支持。',
    'TENCENT_LIVE_ASR_PROVIDER_REJECTED' => '实时转写服务未能处理本次请求，请联系支持。',
    _ => null,
  };
  if (providerMessage != null) {
    return '$providerMessage已识别的文字会保留。';
  }
  if (normalized == 'TENCENT_LIVE_ASR_SDK_UNAVAILABLE' ||
      normalized == 'LIVE_ASR_BACKEND_NOT_READY' ||
      normalized == 'CHAT_LIVE_TRANSCRIPT_UNAVAILABLE') {
    return '当前版本暂不支持实时转写，已识别的文字会保留。';
  }
  if (normalized == 'AUTH_SESSION_EXPIRED') {
    return '登录状态已失效，请重新登录后使用实时转写。已识别的文字会保留。';
  }
  if (normalized == 'TENCENT_LIVE_ASR_REQUEST_INVALID' ||
      normalized == 'TENCENT_LIVE_ASR_EVENT_INVALID' ||
      normalized == 'LIVE_ASR_SESSION_RESPONSE_INVALID' ||
      normalized == 'LIVE_ASR_VOICEPRINT_PROFILE_INVALID' ||
      normalized == 'CHAT_LIVE_TRANSCRIPT_OWNER_INVALID') {
    return '当前请求无法启动实时转写，请关闭后重新进入。已识别的文字会保留。';
  }
  if (normalized == 'LIVE_ASR_SESSION_NETWORK_FAILED' ||
      normalized == 'TENCENT_LIVE_ASR_NETWORK_FAILED') {
    return '当前无法连接实时转写服务，请确认网络状态后重试。已识别的文字会保留。';
  }
  if (normalized == 'TENCENT_LIVE_ASR_START_TIMEOUT' ||
      normalized == 'TENCENT_LIVE_ASR_TIMEOUT' ||
      normalized == 'TENCENT_LIVE_ASR_TRANSPORT_TIMEOUT' ||
      normalized == 'TENCENT_LIVE_ASR_FLOW_START_TIMEOUT') {
    return '连接实时转写服务超时，请稍后重试。已识别的文字会保留。';
  }
  if (normalized == 'TENCENT_LIVE_ASR_AUDIO_SOURCE_NOT_READY') {
    return '麦克风音频未能启动，请稍后重试。已识别的文字会保留。';
  }
  if (normalized == 'TENCENT_LIVE_ASR_START_PREREQUISITES_TIMEOUT') {
    return '实时转写启动未完成，请稍后重试。已识别的文字会保留。';
  }
  if (normalized.contains('CREDENTIAL') || normalized.contains('AUTH')) {
    return isLiveTranscriptionRetryableError(normalized)
        ? '实时转写服务授权暂时不可用，请稍后重试。已识别的文字会保留。'
        : '实时转写服务授权不可用，已识别的文字会保留。';
  }
  if (normalized.contains('RECONNECT')) {
    return '实时转写连接已中断，请稍后重试。已识别的文字会保留。';
  }
  return isLiveTranscriptionRetryableError(normalized)
      ? '实时转写暂时不可用，请稍后重试。已识别的文字会保留。'
      : '实时转写暂不可用，已识别的文字会保留。';
}
