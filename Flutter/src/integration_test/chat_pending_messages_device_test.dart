import 'dart:io';

import 'package:huahuoai_app/app/di/auth_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/app/bootstrap/app_providers.dart';
import 'package:huahuoai_app/app/di/chat_providers.dart';
import 'package:huahuoai_app/app/navigation/app_router.dart';
import 'package:huahuoai_app/core/auth/session_store.dart';
import 'package:huahuoai_app/features/chat/domain/chat_models.dart';
import 'package:huahuoai_app/features/notifications/application/pending_message_projection.dart';
import 'package:huahuoai_app/features/recordings/application/monologue_recording_controller.dart';
import 'package:huahuoai_app/features/transcription/application/live_transcript_controller.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_capture_pages.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_chat_page.dart';
import 'package:huahuoai_app/main.dart' as app;
import 'package:integration_test/integration_test.dart';

const _enabled = bool.fromEnvironment('HUAHUO_CHAT_E2E', defaultValue: false);
const _phone = String.fromEnvironment('HUAHUO_CHAT_E2E_PHONE');
const _code = String.fromEnvironment('HUAHUO_CHAT_E2E_CODE');

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'simulator opens chat, consumes result, creates an asset, and starts Android monologue ASR',
    (tester) async {
      final container = await _launchAuthenticatedApp(tester);
      final chat = await _exerciseChat(tester, container, binding);
      await _verifyTerminalChatPendingIsConsumed(tester, container, chat);
      if (Platform.isAndroid) {
        await _exerciseAndroidMonologue(tester, container, binding);
      }
    },
    skip: !_enabled,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

Future<ProviderContainer> _launchAuthenticatedApp(WidgetTester tester) async {
  await app.main();
  await _pumpUntil(
    tester,
    () => find.byType(Scaffold).evaluate().isNotEmpty,
    timeout: const Duration(seconds: 20),
    reason: 'The application did not render a scaffold.',
  );
  final container = ProviderScope.containerOf(
    tester.element(find.byType(Scaffold).first),
  );
  if (container.read(sessionStoreProvider).state.authState !=
      SessionAuthState.authenticated) {
    expect(_phone, isNotEmpty, reason: 'HUAHUO_CHAT_E2E_PHONE is required.');
    expect(_code, isNotEmpty, reason: 'HUAHUO_CHAT_E2E_CODE is required.');
    final auth = container.read(authControllerProvider);
    auth.setPhone(_phone);
    await auth.sendSmsCode();
    expect(
      auth.state.smsRequestId,
      isNotNull,
      reason: auth.state.lastErrorCode,
    );
    auth.setCode(_code);
    auth.setAgreementAccepted(true);
    await auth.login();
  }
  await _pumpUntil(
    tester,
    () {
      final state = container.read(sessionStoreProvider).state;
      return state.authState == SessionAuthState.authenticated &&
          state.workspaceStatus == SessionWorkspaceStatus.ready;
    },
    timeout: const Duration(seconds: 45),
    reason: 'Authentication or workspace provisioning did not become ready.',
  );
  debugPrint('[ChatDeviceE2E] authenticated workspace=ready');
  return container;
}

Future<_ChatEvidence> _exerciseChat(
  WidgetTester tester,
  ProviderContainer root,
  IntegrationTestWidgetsFlutterBinding binding,
) async {
  root.read(appRouterProvider).go('/v3/feed/chat');
  await _pumpUntil(
    tester,
    () => find.byType(V3ChatPage).evaluate().isNotEmpty,
    timeout: const Duration(seconds: 20),
    reason: 'The chat page did not open.',
  );
  await tester.tap(find.byTooltip('新建会话'));
  await tester.pump(const Duration(milliseconds: 300));
  expect(tester.takeException(), isNull);

  final composer = find.byWidgetPredicate(
    (widget) =>
        widget is TextField && widget.decoration?.hintText == '输入你的问题或想法...',
  );
  expect(composer, findsOneWidget);
  await tester.tap(composer);
  await tester.enterText(composer, '模拟器回归：请只回复“已收到”。不要生成图片。');
  await tester.testTextInput.receiveAction(TextInputAction.send);
  await tester.pump(const Duration(milliseconds: 300));

  final chatContainer = ProviderScope.containerOf(
    tester.element(find.byType(V3ChatPage).last),
  );
  final controller = chatContainer.read(feedAiChatControllerProvider);
  ChatMessage? assistant;
  await _pumpUntil(
    tester,
    () {
      assistant = controller.state.messages
          .where(
            (message) =>
                message.role == ChatMessageRole.assistant &&
                message.visibleText?.trim().isNotEmpty == true,
          )
          .lastOrNull;
      return assistant != null;
    },
    timeout: const Duration(seconds: 150),
    reason: controller.state.lastErrorCode ?? 'No durable Assistant reply.',
  );
  expect(tester.takeException(), isNull);
  final threadId = controller.state.activeThreadId;
  expect(threadId, isNotNull);
  debugPrint('[ChatDeviceE2E] assistantReply=visible');
  await binding.takeScreenshot('chat_pending_messages_reply');

  final createAsset = find.byKey(
    ValueKey<String>('chat-create-note-${assistant!.messageId}'),
  );
  expect(createAsset, findsOneWidget);
  await tester.ensureVisible(createAsset);
  await tester.tap(createAsset);
  await _pumpUntil(
    tester,
    () => find.text('已保存到我的资产').evaluate().isNotEmpty,
    timeout: const Duration(seconds: 30),
    reason: 'Assistant reply asset creation did not complete.',
  );
  expect(tester.takeException(), isNull);
  debugPrint('[ChatDeviceE2E] assistantAsset=created');
  return _ChatEvidence(threadId: threadId!);
}

Future<void> _verifyTerminalChatPendingIsConsumed(
  WidgetTester tester,
  ProviderContainer root,
  _ChatEvidence chat,
) async {
  await Future<void>.delayed(const Duration(seconds: 3));
  await tester.pump();
  final pending = root
      .read(pendingMessageProjectionProvider)
      .items
      .where(
        (item) =>
            item.targetType == 'thread' &&
            item.targetId == chat.threadId &&
            item.isTerminalTask,
      )
      .toList(growable: false);
  expect(
    pending,
    isEmpty,
    reason: 'A terminal visible chat result remained in pending messages.',
  );
  debugPrint('[ChatDeviceE2E] terminalPending=consumed');
}

Future<void> _exerciseAndroidMonologue(
  WidgetTester tester,
  ProviderContainer root,
  IntegrationTestWidgetsFlutterBinding binding,
) async {
  root.read(appRouterProvider).go('/v3/feed/monologue');
  await _pumpUntil(
    tester,
    () => find.byType(V3MonologuePage).evaluate().isNotEmpty,
    timeout: const Duration(seconds: 20),
    reason: 'The monologue page did not open.',
  );
  await tester.tap(find.text('开始').last);
  final monologue = root.read(monologueRecordingControllerProvider);
  await _pumpUntil(
    tester,
    () =>
        monologue.state.isCaptureActive ||
        monologue.state.status == MonologueRecordingStatus.failed,
    timeout: const Duration(seconds: 25),
    reason: monologue.state.lastErrorCode ?? 'Monologue capture did not start.',
  );
  expect(
    monologue.state.isCaptureActive,
    isTrue,
    reason: monologue.state.lastErrorCode,
  );

  final liveTranscript = root.read(liveTranscriptControllerProvider);
  await _pumpUntil(
    tester,
    () {
      final status = liveTranscript.state.status;
      return status == LiveTranscriptStatus.transcribing ||
          status == LiveTranscriptStatus.failed;
    },
    timeout: const Duration(seconds: 45),
    reason: 'Realtime monologue transcription did not resolve.',
  );
  expect(
    liveTranscript.state.status,
    LiveTranscriptStatus.transcribing,
    reason: liveTranscript.state.lastErrorCode,
  );
  await binding.takeScreenshot('chat_pending_messages_android_monologue');
  expect(await monologue.cancel(), isTrue);
  debugPrint('[ChatDeviceE2E] androidMonologue=liveListeningThenCancelled');
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  required Duration timeout,
  required String reason,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await tester.pump();
  }
  expect(condition(), isTrue, reason: reason);
}

final class _ChatEvidence {
  const _ChatEvidence({required this.threadId});

  final String threadId;
}
