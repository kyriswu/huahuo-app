import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/api/api_client.dart';
import 'package:huahuoai_app/core/api/api_envelope.dart';
import 'package:huahuoai_app/core/api/idempotency.dart';
import 'package:huahuoai_app/features/transcription/application/live_transcript_controller.dart';
import 'package:huahuoai_app/features/transcription/data/live_transcription_api.dart';
import 'package:huahuoai_app/features/transcription/data/tencent_live_asr_port.dart';
import 'package:huahuoai_app/features/transcription/domain/live_transcript.dart';
import 'package:huahuoai_app/features/transcription/presentation/live_transcription_failure_dialog.dart';

void main() {
  test(
    'failure recovery classification matches native recovery boundaries',
    () {
      const retryable = <String>[
        'REALTIME_ASR_SESSION_UNAVAILABLE',
        'ASR_PROVIDER_FAILED',
        'ASR_PROVIDER_RATE_LIMITED',
        'ASR_TIMEOUT',
        'TENCENT_LIVE_ASR_AUDIO_SOURCE_START_FAILED',
        'TENCENT_LIVE_ASR_AUDIO_SOURCE_TIMEOUT',
        'TENCENT_LIVE_ASR_PROVIDER_RATE_LIMITED',
        'TENCENT_LIVE_ASR_PROVIDER_UNAVAILABLE',
        'TENCENT_LIVE_ASR_MICROPHONE_BUSY',
        'TENCENT_LIVE_ASR_SHARED_PCM_UNAVAILABLE',
        'TENCENT_LIVE_ASR_RECOGNITION_FAILED',
        'TENCENT_LIVE_ASR_WRITE_FAILED',
        'TENCENT_LIVE_ASR_SESSION_SUPERSEDED',
        'VOICE_RECORDER_BUSY',
        'VOICE_RECORDER_PERMISSION_REQUEST_FAILED',
        'VOICE_RECORDER_PERMISSION_REQUEST_TIMEOUT',
      ];
      const terminal = <String>[
        'REALTIME_ASR_SESSION_CONFLICT',
        'ASR_PROVIDER_AUTH_FAILED',
        'TENCENT_LIVE_ASR_REQUEST_INVALID',
        'TENCENT_LIVE_ASR_SDK_UNAVAILABLE',
        'TENCENT_LIVE_ASR_EVENT_INVALID',
        'TENCENT_LIVE_ASR_PROVIDER_REJECTED',
        'TENCENT_LIVE_ASR_PROVIDER_AUTH_FAILED',
        'TENCENT_LIVE_ASR_PROVIDER_REQUEST_INVALID',
        'TENCENT_LIVE_ASR_PROVIDER_NOT_ENABLED',
        'TENCENT_LIVE_ASR_PROVIDER_QUOTA_EXHAUSTED',
        'TENCENT_LIVE_ASR_PROVIDER_SUSPENDED',
        'TENCENT_LIVE_ASR_PROVIDER_AUDIO_INVALID',
        'TENCENT_LIVE_ASR_PROVIDER_REGION_RESTRICTED',
        'AUTH_SESSION_EXPIRED',
        'CHAT_LIVE_TRANSCRIPT_OWNER_INVALID',
        'TENCENT_LIVE_ASR_STOP_FAILED',
        'TENCENT_LIVE_ASR_RELEASE_FAILED',
      ];

      for (final code in retryable) {
        expect(isLiveTranscriptionRetryableError(code), isTrue, reason: code);
      }
      for (final code in terminal) {
        expect(isLiveTranscriptionRetryableError(code), isFalse, reason: code);
      }
      expect(
        isLiveTranscriptionPermissionError(
          ' voice_recorder_permission_denied ',
        ),
        isTrue,
      );
    },
  );

  const providerDialogCases = <String, (String, bool)>{
    'PROVIDER_REJECTED': ('实时转写服务未能处理本次请求，请联系支持。', false),
    'PROVIDER_AUTH_FAILED': ('实时转写服务鉴权失败，请联系支持。', false),
    'PROVIDER_REQUEST_INVALID': ('实时转写请求参数不兼容，请联系支持。', false),
    'PROVIDER_NOT_ENABLED': ('实时转写服务尚未开通，请联系支持。', false),
    'PROVIDER_QUOTA_EXHAUSTED': ('实时转写服务额度已用尽，请联系支持。', false),
    'PROVIDER_SUSPENDED': ('实时转写服务已暂停，请联系支持。', false),
    'PROVIDER_AUDIO_INVALID': ('实时转写音频格式不兼容，请联系支持。', false),
    'PROVIDER_RATE_LIMITED': ('实时转写服务繁忙，请稍后重试。', true),
    'AUDIO_SOURCE_TIMEOUT': ('实时转写未能持续收到音频，请重新开始。', true),
    'PROVIDER_UNAVAILABLE': ('实时转写服务暂时异常，请稍后重试。', true),
    'PROVIDER_REGION_RESTRICTED': ('当前网络出口所在地区不支持此转写服务，请检查代理设置或联系支持。', false),
  };
  for (final entry in providerDialogCases.entries) {
    testWidgets('provider dialog explains ${entry.key}', (tester) async {
      LiveTranscriptionFailureDialogAction? action;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  action = await showLiveTranscriptionFailureDialog(
                    context: context,
                    errorCode: 'TENCENT_LIVE_ASR_${entry.key}',
                  );
                },
                child: const Text('show failure'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('show failure'));
      await tester.pumpAndSettle();
      expect(find.text('${entry.value.$1}已识别的文字会保留。'), findsOneWidget);
      expect(find.text('实时转写服务授权不可用，已识别的文字会保留。'), findsNothing);
      expect(find.text('重试'), entry.value.$2 ? findsOneWidget : findsNothing);
      await tester.tap(find.text(entry.value.$2 ? '重试' : '关闭'));
      await tester.pumpAndSettle();
      expect(
        action,
        entry.value.$2
            ? LiveTranscriptionFailureDialogAction.retry
            : LiveTranscriptionFailureDialogAction.dismiss,
      );
    });
  }

  test('failure dialog gate claims one presentation per attempt', () {
    final gate = LiveTranscriptionFailureDialogGate()..beginAttempt();

    expect(gate.claim(owner: 'chat:1', attemptId: 7), isTrue);
    gate.release();
    expect(gate.claim(owner: 'chat:1', attemptId: 7), isFalse);
    expect(gate.claim(owner: 'chat:1', attemptId: 8), isTrue);
    gate.release();

    final recordingGate = LiveTranscriptionFailureDialogGate()..beginAttempt();
    expect(
      recordingGate.claim(owner: 'monologue-recording', attemptId: null),
      isTrue,
    );
    recordingGate.release();
    expect(
      recordingGate.claim(owner: 'monologue-recording', attemptId: null),
      isFalse,
    );
    recordingGate.beginAttempt();
    expect(
      recordingGate.claim(owner: 'monologue-recording', attemptId: null),
      isTrue,
    );
  });

  test('publishes five-state lifecycle and retains text after stop', () async {
    final credentialPort = _CredentialPort();
    final asrPort = _AsrPort();
    final controller = _controller(credentialPort, asrPort);

    final starting = controller.start(owner: 'chat:1');
    expect(controller.state.status, LiveTranscriptStatus.starting);
    expect(controller.state.owner, 'chat:1');
    expect(controller.state.attemptId, 1);
    expect(await starting, isTrue);
    expect(controller.state.status, LiveTranscriptStatus.transcribing);

    asrPort.add(_sentence(2, '第二句临时'));
    asrPort.add(_sentence(1, '第一句'));
    asrPort.add(_sentence(2, '第二句稳定', stable: true, speakerId: 3));
    asrPort.add(_sentence(2, '不应覆盖', speakerId: 4));
    await pumpEventQueue(times: 2);

    expect(
      controller.state.sentences.map((sentence) => sentence.sentenceId),
      <int>[1, 2],
    );
    expect(controller.state.sentences.last.text, '第二句稳定');
    expect(controller.state.sentences.last.anonymousSpeakerId, 3);
    expect(controller.state.stableSentences, hasLength(1));

    final stopping = controller.stop(owner: 'chat:1', attemptId: 1);
    expect(controller.state.status, LiveTranscriptStatus.stopping);
    expect(await stopping, isTrue);
    expect(controller.state.status, LiveTranscriptStatus.idle);
    expect(controller.state.owner, isNull);
    expect(controller.state.attemptId, isNull);
    expect(controller.state.sentences.last.text, '第二句稳定');
    expect(asrPort.stopCalls, 1);
    expect(asrPort.releaseCalls, 1);
    expect(credentialPort.completedSessionIds, <String>['live-session-1']);

    controller.dispose();
    await asrPort.close();
  });

  test(
    'foreign and stale stop requests cannot affect active attempt',
    () async {
      final asrPort = _AsrPort();
      final controller = _controller(_CredentialPort(), asrPort);

      expect(await controller.start(owner: 'canvas:7'), isTrue);
      final attemptId = controller.state.attemptId!;
      expect(
        controller.state.belongsTo('canvas:7', candidateAttemptId: attemptId),
        isTrue,
      );
      expect(await controller.stop(owner: 'chat:1'), isFalse);
      expect(
        await controller.stop(owner: 'canvas:7', attemptId: attemptId + 1),
        isFalse,
      );
      expect(controller.state.status, LiveTranscriptStatus.transcribing);
      expect(asrPort.stopCalls, 0);
      expect(asrPort.releaseCalls, 0);

      expect(
        await controller.stop(owner: 'canvas:7', attemptId: attemptId),
        isTrue,
      );
      controller.dispose();
      await asrPort.close();
    },
  );

  test(
    'owner can abandon an exact stopping attempt after its deadline',
    () async {
      final stopGate = Completer<LiveAsrOperationResult>();
      final credentialPort = _CredentialPort();
      final asrPort = _AsrPort(stopGate: stopGate);
      final controller = _controller(credentialPort, asrPort);

      expect(await controller.start(owner: 'monologue:deadline'), isTrue);
      asrPort.add(_sentence(0, '已经识别的文字', stable: true));
      await pumpEventQueue(times: 2);
      final attemptId = controller.state.attemptId!;
      final stopping = controller.stop(
        owner: 'monologue:deadline',
        attemptId: attemptId,
      );
      expect(controller.state.status, LiveTranscriptStatus.stopping);

      expect(
        controller.abandonOwnedStoppingAttempt(
          owner: 'foreign-owner',
          attemptId: attemptId,
        ),
        isFalse,
      );
      expect(
        controller.abandonOwnedStoppingAttempt(
          owner: 'monologue:deadline',
          attemptId: attemptId,
        ),
        isTrue,
      );
      expect(controller.state.status, LiveTranscriptStatus.idle);
      expect(controller.state.sentences.single.text, '已经识别的文字');
      await pumpEventQueue(times: 2);
      expect(asrPort.releaseCalls, 1);
      expect(credentialPort.completedSessionIds, <String>['live-session-1']);

      stopGate.complete(const LiveAsrOperationResult.success());
      expect(await stopping, isFalse);
      expect(controller.state.status, LiveTranscriptStatus.idle);
      expect(controller.state.sentences.single.text, '已经识别的文字');

      controller.dispose();
      await asrPort.close();
    },
  );

  test('new attempt clears prior text and allocates a new id', () async {
    final asrPort = _AsrPort();
    final controller = _controller(_CredentialPort(), asrPort);

    expect(await controller.start(owner: 'chat:1'), isTrue);
    asrPort.add(_sentence(0, '上一轮转录', stable: true));
    await pumpEventQueue(times: 2);
    expect(await controller.stop(owner: 'chat:1', attemptId: 1), isTrue);

    final restarting = controller.start(owner: 'monologue:2');
    expect(controller.state.status, LiveTranscriptStatus.starting);
    expect(controller.state.owner, 'monologue:2');
    expect(controller.state.attemptId, 2);
    expect(controller.state.sentences, isEmpty);
    expect(await restarting, isTrue);

    await controller.stop(owner: 'monologue:2', attemptId: 2);
    controller.dispose();
    await asrPort.close();
  });

  test(
    'automatic reconnect stays transcribing and isolates provider ids',
    () async {
      final credentialPort = _CredentialPort();
      final asrPort = _AsrPort();
      final controller = _controller(
        credentialPort,
        asrPort,
        activeVoiceprintProfileId: () => 'vp_self',
        profileDisplayNameResolver: (profileId) => switch (profileId) {
          'vp_self' => '我的声纹',
          'vp_other' => '第二声纹',
          _ => null,
        },
      );

      expect(await controller.start(owner: 'monologue:1'), isTrue);
      asrPort.add(_sentence(0, '第一会话', stable: true, speakerId: 0));
      asrPort.addIdentity(
        LiveSpeakerIdentity(
          anonymousSpeakerId: 0,
          state: LiveSpeakerIdentityState.matched,
          profileId: 'vp_self',
          score: 88,
        ),
      );
      await pumpEventQueue(times: 2);

      asrPort.addError('TENCENT_LIVE_ASR_NETWORK_FAILED');
      expect(controller.state.status, LiveTranscriptStatus.transcribing);
      await pumpEventQueue(times: 8);
      expect(controller.state.status, LiveTranscriptStatus.transcribing);
      expect(controller.state.owner, 'monologue:1');
      expect(controller.state.attemptId, 1);
      expect(credentialPort.calls, 2);
      expect(asrPort.connectedSessionIds, <String>[
        'live-session-1',
        'live-session-2',
      ]);

      asrPort.add(_sentence(0, '第二会话', stable: true, speakerId: 0));
      asrPort.addIdentity(
        LiveSpeakerIdentity(
          anonymousSpeakerId: 0,
          state: LiveSpeakerIdentityState.matched,
          profileId: 'vp_other',
        ),
      );
      await pumpEventQueue(times: 2);
      expect(
        controller.state.sentences.map((sentence) => sentence.sentenceId),
        <int>[0, 1],
      );
      expect(
        controller.state.sentences.map(
          (sentence) => sentence.speakerDisplayName,
        ),
        <String?>['我的声纹', '第二声纹'],
      );
      expect(credentialPort.completedSessionIds, contains('live-session-1'));

      await controller.stop(owner: 'monologue:1', attemptId: 1);
      controller.dispose();
      await asrPort.close();
    },
  );

  for (final errorCode in <String>[
    'TENCENT_LIVE_ASR_NETWORK_FAILED',
    'TENCENT_LIVE_ASR_PROVIDER_UNAVAILABLE',
  ]) {
    test('$errorCode retains text and cause after reconnect budget', () async {
      final credentialPort = _CredentialPort();
      final asrPort = _AsrPort();
      final controller = _controller(
        credentialPort,
        asrPort,
        maxReconnectAttempts: 1,
      );

      expect(await controller.start(owner: 'chat:1'), isTrue);
      asrPort.add(_sentence(0, '保留原有文字', stable: true));
      asrPort.addError(errorCode);
      await pumpEventQueue(times: 8);
      expect(controller.state.status, LiveTranscriptStatus.transcribing);
      expect(credentialPort.calls, 2);
      expect(asrPort.connectedSessionIds, <String>[
        'live-session-1',
        'live-session-2',
      ]);
      expect(credentialPort.completedSessionIds, contains('live-session-1'));

      asrPort.addError(errorCode);
      await pumpEventQueue(times: 8);
      expect(controller.state.status, LiveTranscriptStatus.failed);
      expect(controller.state.owner, 'chat:1');
      expect(controller.state.attemptId, 1);
      expect(controller.state.lastErrorCode, errorCode);
      expect(controller.state.sentences.single.text, '保留原有文字');
      expect(credentialPort.calls, 2);

      controller.dispose();
      await asrPort.close();
    });
  }

  test('non-transient provider failures do not automatically retry', () async {
    for (final category in providerDialogCases.keys.where(
      (category) => category != 'PROVIDER_UNAVAILABLE',
    )) {
      final credentialPort = _CredentialPort();
      final asrPort = _AsrPort();
      final controller = _controller(credentialPort, asrPort);
      final errorCode = 'TENCENT_LIVE_ASR_$category';

      expect(await controller.start(owner: 'chat:1'), isTrue);
      asrPort.add(_sentence(0, '保留原有文字', stable: true));
      asrPort.addError(errorCode);
      await pumpEventQueue(times: 8);

      expect(controller.state.status, LiveTranscriptStatus.failed);
      expect(controller.state.lastErrorCode, errorCode);
      expect(controller.state.sentences.single.text, '保留原有文字');
      expect(credentialPort.calls, 1);
      expect(credentialPort.completedSessionIds, <String>['live-session-1']);
      controller.dispose();
      await asrPort.close();
    }
  });

  test('provider completion reconnects with a fresh credential', () async {
    final credentialPort = _CredentialPort();
    final asrPort = _AsrPort();
    final controller = _controller(credentialPort, asrPort);

    expect(await controller.start(owner: 'chat:1'), isTrue);
    asrPort.addError('TENCENT_LIVE_ASR_PROVIDER_COMPLETED');
    expect(controller.state.status, LiveTranscriptStatus.transcribing);
    await pumpEventQueue(times: 8);

    expect(controller.state.status, LiveTranscriptStatus.transcribing);
    expect(controller.state.owner, 'chat:1');
    expect(controller.state.attemptId, 1);
    expect(credentialPort.calls, 2);
    expect(asrPort.connectedSessionIds, <String>[
      'live-session-1',
      'live-session-2',
    ]);
    expect(credentialPort.completedSessionIds, contains('live-session-1'));

    await controller.stop(owner: 'chat:1', attemptId: 1);
    controller.dispose();
    await asrPort.close();
  });

  test('stop invalidates a pending credential request', () async {
    final credentialGate = Completer<void>();
    final credentialPort = _CredentialPort(requestGate: credentialGate);
    final asrPort = _AsrPort();
    final controller = _controller(credentialPort, asrPort);

    final starting = controller.start(owner: 'chat:1');
    await pumpEventQueue(times: 1);
    expect(controller.state.status, LiveTranscriptStatus.starting);
    expect(await controller.stop(owner: 'chat:1', attemptId: 1), isTrue);
    expect(controller.state.status, LiveTranscriptStatus.idle);

    credentialGate.complete();
    expect(await starting, isFalse);
    expect(asrPort.connectCalls, 0);
    expect(asrPort.releaseCalls, 1);
    expect(credentialPort.completedSessionIds, <String>['live-session-1']);

    controller.dispose();
    await asrPort.close();
  });

  test(
    'late provider readiness is released and cannot revive stopped attempt',
    () async {
      final connectGate = Completer<void>();
      final asrPort = _AsrPort(
        connectGate: connectGate,
        sentenceOnConnect: _sentence(0, '迟到内容', speakerId: 0),
      );
      final controller = _controller(_CredentialPort(), asrPort);

      final starting = controller.start(owner: 'chat:1');
      await pumpEventQueue(times: 2);
      expect(controller.state.status, LiveTranscriptStatus.starting);
      expect(await controller.stop(owner: 'chat:1', attemptId: 1), isTrue);
      expect(controller.state.status, LiveTranscriptStatus.idle);
      expect(await controller.start(owner: 'canvas:2'), isFalse);

      connectGate.complete();
      expect(await starting, isFalse);
      expect(controller.state.status, LiveTranscriptStatus.idle);
      expect(controller.state.sentences, isEmpty);
      expect(asrPort.releaseCalls, 2);

      controller.dispose();
      await asrPort.close();
    },
  );

  test(
    'accepts transcript and identity emitted immediately before ready',
    () async {
      final asrPort = _AsrPort(
        sentenceOnConnect: _sentence(0, '首句', stable: true, speakerId: 0),
        identityOnConnect: LiveSpeakerIdentity(
          anonymousSpeakerId: 0,
          state: LiveSpeakerIdentityState.matched,
          profileId: 'vp_self',
          displayName: 'opaque-profile-reference',
        ),
      );
      final controller = _controller(
        _CredentialPort(),
        asrPort,
        profileDisplayNameResolver: (profileId) =>
            profileId == 'vp_self' ? '我的声纹' : null,
      );

      expect(await controller.start(owner: 'chat:1'), isTrue);
      expect(controller.state.status, LiveTranscriptStatus.transcribing);
      expect(controller.state.sentences.single.text, '首句');
      expect(controller.state.sentences.single.speakerDisplayName, '我的声纹');

      await controller.stop(owner: 'chat:1', attemptId: 1);
      controller.dispose();
      await asrPort.close();
    },
  );

  test('keeps final transcript and identity emitted while stopping', () async {
    final asrPort = _AsrPort(
      sentenceOnStop: _sentence(4, '停止前最终句', stable: true, speakerId: 2),
      identityOnStop: LiveSpeakerIdentity(
        anonymousSpeakerId: 2,
        state: LiveSpeakerIdentityState.matched,
        profileId: 'vp_self',
      ),
    );
    final controller = _controller(
      _CredentialPort(),
      asrPort,
      profileDisplayNameResolver: (profileId) =>
          profileId == 'vp_self' ? '我的声纹' : null,
    );

    expect(await controller.start(owner: 'monologue:1'), isTrue);
    expect(await controller.stop(owner: 'monologue:1', attemptId: 1), isTrue);
    expect(controller.state.status, LiveTranscriptStatus.idle);
    expect(controller.state.sentences.single.text, '停止前最终句');
    expect(controller.state.sentences.single.speakerDisplayName, '我的声纹');

    controller.dispose();
    await asrPort.close();
  });

  test('native and backend capability failures share failed state', () async {
    final sdkPort = _AsrPort(
      connectResult: const LiveAsrOperationResult.sdkUnavailable(),
    );
    final sdkController = _controller(_CredentialPort(), sdkPort);
    expect(await sdkController.start(owner: 'chat:1'), isFalse);
    expect(sdkController.state.status, LiveTranscriptStatus.failed);
    expect(
      sdkController.state.lastErrorCode,
      'TENCENT_LIVE_ASR_SDK_UNAVAILABLE',
    );
    sdkController.dispose();
    await sdkPort.close();

    final backendAsr = _AsrPort();
    final backendController = _controller(
      _CredentialPort(failureCode: 'LIVE_ASR_BACKEND_NOT_READY'),
      backendAsr,
    );
    expect(await backendController.start(owner: 'chat:2'), isFalse);
    expect(backendController.state.status, LiveTranscriptStatus.failed);
    expect(backendController.state.lastErrorCode, 'LIVE_ASR_BACKEND_NOT_READY');
    expect(backendAsr.connectCalls, 0);
    backendController.dispose();
    await backendAsr.close();
  });

  test('credential exception cannot leave an attempt stuck starting', () async {
    final asrPort = _AsrPort();
    final controller = _controller(
      _CredentialPort(throwOnRequest: true),
      asrPort,
    );

    expect(await controller.start(owner: 'chat:1'), isFalse);
    expect(controller.state.status, LiveTranscriptStatus.failed);
    expect(controller.state.lastErrorCode, 'ASR_CREDENTIAL_REQUEST_FAILED');
    expect(asrPort.connectCalls, 0);

    controller.dispose();
    await asrPort.close();
  });
}

LiveTranscriptController _controller(
  _CredentialPort credentialPort,
  _AsrPort asrPort, {
  ActiveVoiceprintProfileId? activeVoiceprintProfileId,
  VoiceprintProfileDisplayName? profileDisplayNameResolver,
  int maxReconnectAttempts = 2,
}) {
  return LiveTranscriptController(
    credentialPort: credentialPort,
    asrPort: asrPort,
    now: () => DateTime.utc(2026, 7, 24, 12),
    reconnectDelay: (_) async {},
    activeVoiceprintProfileId: activeVoiceprintProfileId,
    profileDisplayNameResolver: profileDisplayNameResolver,
    maxReconnectAttempts: maxReconnectAttempts,
  );
}

LiveTranscriptSentence _sentence(
  int id,
  String text, {
  bool stable = false,
  int? speakerId,
}) {
  return LiveTranscriptSentence(
    sentenceId: id,
    text: text,
    stable: stable,
    anonymousSpeakerId: speakerId,
  );
}

final class _CredentialPort
    implements
        LiveTranscriptionCredentialPort,
        LiveTranscriptionSessionCompletionPort {
  _CredentialPort({
    this.requestGate,
    this.failureCode,
    this.throwOnRequest = false,
  });

  final Completer<void>? requestGate;
  final String? failureCode;
  final bool throwOnRequest;
  int calls = 0;
  final List<String?> requestedProfileIds = <String?>[];
  final List<String> completedSessionIds = <String>[];

  @override
  Future<void> completeSession(String sessionId) async {
    completedSessionIds.add(sessionId);
  }

  @override
  Future<ApiResult<LiveAsrSessionCredential>> requestSessionCredential({
    String? voiceprintProfileId,
  }) async {
    calls += 1;
    requestedProfileIds.add(voiceprintProfileId);
    await requestGate?.future;
    if (throwOnRequest) throw StateError('redacted credential failure');
    final failureCode = this.failureCode;
    if (failureCode != null) {
      return ApiResult<LiveAsrSessionCredential>.failure(
        error: AppFailure(
          code: failureCode,
          category: AppFailureCategory.compatibility,
          message: 'backend not ready',
          userMessageKey: 'liveTranscription.error.$failureCode',
        ),
        idempotencyStore: SubmissionKeyStore.empty,
      );
    }
    return ApiResult<LiveAsrSessionCredential>.success(
      data: LiveAsrSessionCredential(
        sessionId: 'live-session-$calls',
        appId: 123456789,
        projectId: 0,
        tmpSecretId: 'tmp-secret-id',
        tmpSecretKey: 'tmp-secret-key',
        token: 'tmp-token',
        expiresAt: DateTime.utc(2026, 7, 24, 12, 15),
      ),
      status: 200,
      idempotencyStore: SubmissionKeyStore.empty,
    );
  }
}

final class _AsrPort implements TencentLiveAsrPort, LiveSpeakerIdentitySource {
  _AsrPort({
    this.connectResult = const LiveAsrOperationResult.success(),
    this.sentenceOnConnect,
    this.identityOnConnect,
    this.sentenceOnStop,
    this.identityOnStop,
    this.connectGate,
    this.stopGate,
  });

  final LiveAsrOperationResult connectResult;
  final LiveTranscriptSentence? sentenceOnConnect;
  final LiveSpeakerIdentity? identityOnConnect;
  final LiveTranscriptSentence? sentenceOnStop;
  final LiveSpeakerIdentity? identityOnStop;
  final Completer<void>? connectGate;
  final Completer<LiveAsrOperationResult>? stopGate;
  final StreamController<LiveTranscriptSentence> _events =
      StreamController<LiveTranscriptSentence>.broadcast(sync: true);
  final StreamController<LiveSpeakerIdentity> _identities =
      StreamController<LiveSpeakerIdentity>.broadcast(sync: true);
  int connectCalls = 0;
  int stopCalls = 0;
  int releaseCalls = 0;
  final List<String> connectedSessionIds = <String>[];

  @override
  Stream<LiveTranscriptSentence> get events => _events.stream;

  @override
  Stream<LiveSpeakerIdentity> get speakerIdentities => _identities.stream;

  void add(LiveTranscriptSentence sentence) => _events.add(sentence);
  void addError(String code) => _events.addError(code);
  void addIdentity(LiveSpeakerIdentity identity) => _identities.add(identity);

  @override
  Future<LiveAsrOperationResult> connect(
    LiveAsrSessionCredential credential,
  ) async {
    connectCalls += 1;
    connectedSessionIds.add(credential.sessionId);
    await connectGate?.future;
    final sentence = sentenceOnConnect;
    if (sentence != null) _events.add(sentence);
    final identity = identityOnConnect;
    if (identity != null) _identities.add(identity);
    return connectResult;
  }

  @override
  Future<LiveAsrOperationResult> release() async {
    releaseCalls += 1;
    return const LiveAsrOperationResult.success();
  }

  @override
  Future<LiveAsrOperationResult> stop() async {
    stopCalls += 1;
    final sentence = sentenceOnStop;
    if (sentence != null) _events.add(sentence);
    final identity = identityOnStop;
    if (identity != null) _identities.add(identity);
    final gate = stopGate;
    if (gate != null) return gate.future;
    return const LiveAsrOperationResult.success();
  }

  Future<void> close() async {
    await Future.wait<void>([_events.close(), _identities.close()]);
  }
}
