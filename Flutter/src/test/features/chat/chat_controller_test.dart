import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/api/api_client.dart';
import 'package:huahuoai_app/core/api/api_envelope.dart';
import 'package:huahuoai_app/core/api/idempotency.dart';
import 'package:huahuoai_app/core/api/upload_client.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/database/app_preferences_dao.dart';
import 'package:huahuoai_app/core/database/database_worker.dart';
import 'package:huahuoai_app/core/database/database_write_queue.dart';
import 'package:huahuoai_app/core/database/user_metadata_dao.dart';
import 'package:huahuoai_app/features/chat/application/chat_controller.dart';
import 'package:huahuoai_app/features/chat/application/chat_controller_policies.dart';
import 'package:huahuoai_app/features/chat/application/chat_run_tracker.dart';
import 'package:huahuoai_app/features/chat/application/chat_run_reconciliation.dart';
import 'package:huahuoai_app/features/chat/domain/assistant_runtime.dart';
import 'package:huahuoai_app/features/chat/domain/chat_repository.dart';
import 'package:huahuoai_app/features/chat/data/chat_thread_alias_repository.dart';
import 'package:huahuoai_app/features/chat/domain/chat_context.dart';
import 'package:huahuoai_app/features/chat/domain/chat_models.dart';
import 'assistant_runtime_test_adapter.dart';

const _longPersonaReplyFinalQuestion = '要不要按照这个视觉参考设计直接生成图片？';

String _longPersonaReply({int length = 20561}) {
  return '人' * (length - _longPersonaReplyFinalQuestion.length) +
      _longPersonaReplyFinalQuestion;
}

void main() {
  group('ChatController', () {
    for (final completesDuringPoll in [false, true]) {
      test(
        'next turn cannot inherit a reconciled terminal Run (poll=$completesDuringPoll)',
        () async {
          const threadId = 'canvas-consecutive-thread';
          const firstRunId = 'canvas-consecutive-run-1';
          const secondRunId = 'canvas-consecutive-run-2';
          const assistantId = 'canvas-consecutive-assistant-1';
          final firstSettled = Completer<void>();
          final database = AppDatabase();
          final repository = ChatThreadAliasRepository(
            dao: UserMetadataDao(database),
            preferencesDao: AppPreferencesDao(database),
            userScope: 'canvas-consecutive-cache',
          );
          final tracker = _SseDraftChatRunTracker();
          final api = _FakeChatApi(
            createdThread: _thread(threadId),
            sendResults: [
              for (final turn in [1, 2])
                _success(
                  ChatTextMutation(
                    message: _message(
                      id: 'canvas-user-$turn',
                      threadId: threadId,
                      role: ChatMessageRole.user,
                      text: '第 $turn 轮',
                    ),
                    nextAction: ChatNextAction(
                      type: ChatNextActionType.pollAgentRun,
                      agentRunId: turn == 1 ? firstRunId : secondRunId,
                    ),
                  ),
                  SubmissionKeyStore.empty,
                ),
            ],
            details: {
              threadId: ChatThreadDetail(
                thread: _thread(threadId),
                messages: [
                  _message(
                    id: 'canvas-user-1',
                    threadId: threadId,
                    role: ChatMessageRole.user,
                    text: '第 1 轮',
                  ),
                  _message(
                    id: assistantId,
                    threadId: threadId,
                    role: ChatMessageRole.assistant,
                    text: '第一轮完成',
                    agentRunId: firstRunId,
                  ),
                ],
              ),
            },
          );
          final controller = ChatController(
            api: api,
            runTracker: tracker,
            aliasRepository: repository,
            assistantRuntime: legacyAssistantRuntime(
              _RunScopedAssistantRuntimeFixture(
                {
                  firstRunId: _agentRun(
                    agentRunId: firstRunId,
                    status: 'succeeded',
                    threadId: threadId,
                    assistantMessageId: assistantId,
                    completionMode: 'normal',
                  ),
                  secondRunId: _agentRun(
                    agentRunId: secondRunId,
                    status: 'running',
                    threadId: threadId,
                  ),
                },
                onRead: (runId) {
                  if (completesDuringPoll && runId == firstRunId) {
                    tracker.publishCompletion(
                      agentRunId: firstRunId,
                      threadId: threadId,
                      status: 'succeeded',
                      completionMode: 'normal',
                      assistantMessageId: assistantId,
                    );
                  }
                },
              ),
            ),
            scene: ChatScene.feedAi,
            taskPollInterval: Duration.zero,
            taskPollAttempts: 1,
          );
          addTearDown(controller.dispose);
          addTearDown(tracker.dispose);
          controller.addListener(() {
            if (!completesDuringPoll &&
                controller.state.turnState.phase ==
                    ChatTurnPhase.waitingForAssistant &&
                controller.state.turnState.agentRunId == firstRunId) {
              tracker.publishCompletion(
                agentRunId: firstRunId,
                threadId: threadId,
                status: 'succeeded',
                completionMode: 'normal',
                assistantMessageId: assistantId,
              );
            }
            if (controller.state.turnState.assistantMessageId == assistantId &&
                !firstSettled.isCompleted) {
              firstSettled.complete();
            }
          });
          expect(await controller.sendText('第 1 轮'), isTrue);
          await firstSettled.future;
          expect(
            repository
                .loadConversationCache(
                  scene: ChatScene.feedAi,
                  purpose: ChatConversationPurpose.general,
                )
                ?.messagesByThread[threadId]
                ?.last
                .messageId,
            assistantId,
          );
          expect(
            await controller.sendText(
              '第 2 轮',
              localMessageId: 'local-canvas-2',
            ),
            isTrue,
          );
          expect(controller.state.turnState.userMessageId, 'local-canvas-2');
          expect(controller.state.turnState.agentRunId, secondRunId);
          expect(controller.state.turnState.assistantMessageId, isNull);
          expect(
            controller.state.turnState.phase,
            ChatTurnPhase.waitingForAssistant,
          );
          expect(controller.state.lastErrorCode, isNull);
          expect(api.sentContents, ['第 1 轮', '第 2 轮']);
        },
      );
    }

    test('persists one account-scoped asset reference per thread', () {
      final database = AppDatabase();
      ChatThreadAliasRepository repository(String scope) =>
          ChatThreadAliasRepository(
            dao: UserMetadataDao(database),
            preferencesDao: AppPreferencesDao(database),
            userScope: scope,
          );
      final accountA = repository('thread-asset-account-a');
      accountA.saveThreadAssetReference(
        scene: ChatScene.feedAi,
        threadId: 'thread_1',
        assetId: 'local_note_1',
      );

      expect(
        repository('thread-asset-account-a').threadAssetReferenceFor(
          scene: ChatScene.feedAi,
          threadId: 'thread_1',
        ),
        'local_note_1',
      );
      expect(
        repository('thread-asset-account-a').threadAssetReferenceFor(
          scene: ChatScene.feedAi,
          threadId: 'thread_2',
        ),
        isNull,
      );
      expect(
        repository('thread-asset-account-b').threadAssetReferenceFor(
          scene: ChatScene.feedAi,
          threadId: 'thread_1',
        ),
        isNull,
      );

      accountA.removeThreadAssetReference(
        scene: ChatScene.feedAi,
        threadId: 'thread_1',
      );
      expect(
        repository('thread-asset-account-a').threadAssetReferenceFor(
          scene: ChatScene.feedAi,
          threadId: 'thread_1',
        ),
        isNull,
      );
    });

    test(
      'persists and orders ordinary threads independently for each entry',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'ordinary-chat-entry-',
        );
        addTearDown(() async {
          if (await root.exists()) await root.delete(recursive: true);
        });
        final store = LocalDatabaseSnapshotStore(
          file: File('${root.path}/local-db.json'),
        );
        final database = AppDatabase(snapshotStore: store);
        final dao = UserMetadataDao(database);
        ChatThreadAliasRepository repository(
          String scope, {
          String workspaceScope = 'ordinary-workspace-a',
        }) => ChatThreadAliasRepository(
          dao: UserMetadataDao(database),
          preferencesDao: AppPreferencesDao(database),
          userScope: scope,
          workspaceScope: workspaceScope,
        );
        final accountA = repository('ordinary-entry-account-a');
        final assetA = OrdinaryChatEntryPoint.asset('asset-a');
        final assetB = OrdinaryChatEntryPoint.asset('asset-b');
        final daily = OrdinaryChatEntryPoint.dailyRecommendation(
          recommendationId: 'recommendation:2026-09-09',
          topicId: 'topic-1',
        );

        accountA.markOrdinaryThreadOpened(
          scene: ChatScene.feedAi,
          entryPoint: assetA,
          threadId: 'asset-thread-1',
          agentProfileId: standardCreationChatAgentProfileId,
          openedAt: DateTime.utc(2026, 9, 9, 8),
        );
        accountA.markOrdinaryThreadOpened(
          scene: ChatScene.feedAi,
          entryPoint: assetA,
          threadId: 'asset-thread-2',
          agentProfileId: standardCreationChatAgentProfileId,
          openedAt: DateTime.utc(2026, 9, 9, 9),
        );
        accountA.markOrdinaryThreadOpened(
          scene: ChatScene.feedAi,
          entryPoint: assetA,
          threadId: 'asset-thread-1',
          agentProfileId: standardCreationChatAgentProfileId,
          openedAt: DateTime.utc(2026, 9, 9, 10),
        );
        accountA.markOrdinaryThreadOpened(
          scene: ChatScene.feedAi,
          entryPoint: assetB,
          threadId: 'asset-thread-1',
          agentProfileId: standardCreationChatAgentProfileId,
          openedAt: DateTime.utc(2026, 9, 9, 11),
        );
        accountA.markOrdinaryThreadOpened(
          scene: ChatScene.feedAi,
          entryPoint: daily,
          threadId: 'daily-thread-1',
          agentProfileId: standardCreationChatAgentProfileId,
          openedAt: DateTime.utc(2026, 9, 9, 12),
        );
        accountA.markOrdinaryThreadOpened(
          scene: ChatScene.feedAi,
          entryPoint: OrdinaryChatEntryPoint.thoughtGraph,
          threadId: 'thought-graph-thread-1',
          agentProfileId: standardCreationChatAgentProfileId,
          openedAt: DateTime.utc(2026, 9, 9, 13),
        );
        dao.upsertChatEntryThreadBinding(
          userScope: 'ordinary-entry-account-a',
          workspaceScope: 'ordinary-workspace-a',
          scene: ChatScene.feedAi.apiValue,
          entryKind: assetA.kind.storageValue,
          entryId: assetA.entryId,
          threadId: 'specialist-thread',
          agentProfileId: 'video_analysis',
          boundAt: DateTime.utc(2026, 9, 9, 14).toIso8601String(),
          lastOpenedAt: DateTime.utc(2026, 9, 9, 14).toIso8601String(),
        );

        final assetThreads = accountA.ordinaryThreadBindingsFor(
          scene: ChatScene.feedAi,
          entryPoint: assetA,
        );
        expect(assetThreads.map((binding) => binding.threadId), <String>[
          'asset-thread-1',
          'asset-thread-2',
        ]);
        expect(assetThreads.first.boundAt, DateTime.utc(2026, 9, 9, 8));
        expect(assetThreads.first.lastOpenedAt, DateTime.utc(2026, 9, 9, 10));
        accountA.markOrdinaryThreadOpened(
          scene: ChatScene.feedAi,
          entryPoint: assetA,
          threadId: 'asset-thread-2',
          agentProfileId: standardCreationChatAgentProfileId,
          openedAt: DateTime.utc(2026, 9, 9, 7),
        );
        final clockRollbackThreads = accountA.ordinaryThreadBindingsFor(
          scene: ChatScene.feedAi,
          entryPoint: assetA,
        );
        expect(
          clockRollbackThreads.map((binding) => binding.threadId),
          <String>['asset-thread-2', 'asset-thread-1'],
        );
        expect(
          clockRollbackThreads.first.lastOpenedAt,
          DateTime.utc(2026, 9, 9, 10).add(const Duration(microseconds: 1)),
        );
        expect(
          accountA
              .ordinaryThreadBindingsFor(
                scene: ChatScene.feedAi,
                entryPoint: assetB,
              )
              .single
              .threadId,
          'asset-thread-1',
        );
        expect(
          accountA
              .ordinaryThreadBindingsFor(
                scene: ChatScene.feedAi,
                entryPoint: daily,
              )
              .single
              .threadId,
          'daily-thread-1',
        );
        expect(
          accountA
              .ordinaryThreadBindingsFor(
                scene: ChatScene.feedAi,
                entryPoint: OrdinaryChatEntryPoint.thoughtGraph,
              )
              .single
              .threadId,
          'thought-graph-thread-1',
        );
        expect(
          repository('ordinary-entry-account-b').ordinaryThreadBindingsFor(
            scene: ChatScene.feedAi,
            entryPoint: assetA,
          ),
          isEmpty,
        );
        expect(
          repository(
            'ordinary-entry-account-a',
            workspaceScope: 'ordinary-workspace-b',
          ).ordinaryThreadBindingsFor(
            scene: ChatScene.feedAi,
            entryPoint: assetA,
          ),
          isEmpty,
        );
        expect(
          () => accountA.markOrdinaryThreadOpened(
            scene: ChatScene.workAi,
            entryPoint: assetA,
            threadId: 'wrong-scene-thread',
            agentProfileId: standardCreationChatAgentProfileId,
          ),
          throwsArgumentError,
        );
        expect(
          () => accountA.markOrdinaryThreadOpened(
            scene: ChatScene.feedAi,
            entryPoint: assetA,
            threadId: 'specialist-thread',
            agentProfileId: 'video_analysis',
          ),
          throwsArgumentError,
        );
        expect(
          OrdinaryChatEntryPoint.tryParse(
            kind: daily.kind.storageValue,
            entryId: daily.entryId,
          ),
          daily,
        );
        expect(
          OrdinaryChatEntryPoint.tryParse(
            kind: daily.kind.storageValue,
            entryId: 'ambiguous/daily/topic',
          ),
          isNull,
        );

        await database.flushPersistence();
        final reopenedDatabase = AppDatabase(snapshotStore: store);
        final reopened = ChatThreadAliasRepository(
          dao: UserMetadataDao(reopenedDatabase),
          preferencesDao: AppPreferencesDao(reopenedDatabase),
          userScope: 'ordinary-entry-account-a',
          workspaceScope: 'ordinary-workspace-a',
        );
        expect(
          reopened
              .ordinaryThreadBindingsFor(
                scene: ChatScene.feedAi,
                entryPoint: assetA,
              )
              .map((binding) => binding.threadId),
          <String>['asset-thread-2', 'asset-thread-1'],
        );
      },
    );

    test(
      'bounds conversation cache to recent threads and message timelines',
      () {
        final database = AppDatabase();
        final repository = ChatThreadAliasRepository(
          dao: UserMetadataDao(database),
          preferencesDao: AppPreferencesDao(database),
          userScope: 'bounded-conversation-cache-user',
        );
        final threads = List<ChatThread>.generate(
          55,
          (index) => _thread(
            'bounded-cache-thread-$index',
            updatedAt: DateTime.utc(2026, 9, 1).add(Duration(minutes: index)),
          ).copyWith(workspaceId: 'bounded-cache-workspace'),
        );
        final messagesByThread = <String, List<ChatMessage>>{
          for (var threadIndex = 0; threadIndex < threads.length; threadIndex++)
            threads[threadIndex].threadId: List<ChatMessage>.generate(
              threadIndex >= 50 ? 105 : 1,
              (messageIndex) => _message(
                id: 'bounded-cache-message-$threadIndex-$messageIndex',
                threadId: threads[threadIndex].threadId,
                role: ChatMessageRole.assistant,
                text: '缓存消息 $messageIndex',
              ),
            ),
        };

        repository.saveConversationCache(
          scene: ChatScene.feedAi,
          purpose: ChatConversationPurpose.general,
          threads: threads,
          messagesByThread: messagesByThread,
        );

        final cache = repository.loadConversationCache(
          scene: ChatScene.feedAi,
          purpose: ChatConversationPurpose.general,
        );
        expect(cache, isNotNull);
        expect(cache!.threads.map((thread) => thread.threadId), <String>[
          for (var index = 54; index >= 5; index--)
            'bounded-cache-thread-$index',
        ]);
        expect(
          cache.threads.map((thread) => thread.workspaceId).toSet(),
          <String?>{'bounded-cache-workspace'},
        );
        expect(
          cache.messagesByThread.keys,
          unorderedEquals(<String>[
            for (var index = 54; index >= 50; index--)
              'bounded-cache-thread-$index',
          ]),
        );
        for (var threadIndex = 50; threadIndex < 55; threadIndex++) {
          final messages =
              cache.messagesByThread['bounded-cache-thread-$threadIndex']!;
          expect(messages, hasLength(100));
          expect(
            messages.first.messageId,
            'bounded-cache-message-$threadIndex-5',
          );
          expect(
            messages.last.messageId,
            'bounded-cache-message-$threadIndex-104',
          );
        }

        final controller = ChatController(
          api: _FakeChatApi(),
          scene: ChatScene.feedAi,
          aliasRepository: repository,
        );
        addTearDown(controller.dispose);
        expect(controller.restoreCachedConversations(), isTrue);
        expect(controller.state.threads, hasLength(50));
      },
    );

    test(
      'silently retains runtime metadata cache when presentation refresh fails',
      () async {
        const threadId = 'runtime-metadata-thread-1';
        final invocation = SharedThreadRuntimeInvocation(
          schemaVersion: 'huahuo.thread-runtime-invocation.v1',
          threadId: threadId,
          agentRunId: 'runtime-metadata-run-1',
          status: 'running',
          agentProfileId: 'self_media_creation_standard',
          modelProfileId: 'model-profile-1',
          skillProfileIds: const <String>['skill-profile-1'],
          contentTypes: const <String>['text'],
          tools: const <SharedRuntimeTool>[],
          files: const <SharedRuntimeFile>[],
          progress: <SharedRuntimeProgress>[
            SharedRuntimeProgress(
              kind: 'plan',
              title: '整理资料',
              status: 'updated',
              createdAt: DateTime.utc(2026, 9, 1),
            ),
          ],
        );
        final api = _RuntimeMetadataChatApi(
          runtimeResults: <ApiConditionalResult<SharedThreadRuntimeInvocation>>[
            ApiConditionalResult<SharedThreadRuntimeInvocation>.fromApiResult(
              ApiResult<SharedThreadRuntimeInvocation>.success(
                data: invocation,
                status: 200,
                idempotencyStore: SubmissionKeyStore.empty,
                responseHeaders: const <String, String>{'ETag': '"runtime-1"'},
              ),
            ),
            ApiConditionalResult<SharedThreadRuntimeInvocation>.fromApiResult(
              _failure<SharedThreadRuntimeInvocation>(
                'CHAT_RUNTIME_REFRESH_FAILED',
              ),
            ),
            ApiConditionalResult<SharedThreadRuntimeInvocation>.fromApiResult(
              _failure<SharedThreadRuntimeInvocation>(
                'CHAT_RUNTIME_REFRESH_FAILED',
              ),
            ),
          ],
        );
        final controller = ChatController(api: api, scene: ChatScene.feedAi);
        addTearDown(controller.dispose);

        expect(await controller.readRuntimeInvocation(threadId), invocation);
        expect(controller.runtimeInvocationCacheRevision.value, 1);
        final statusBeforeRefresh = controller.state.status;
        final errorBeforeRefresh = controller.state.lastErrorCode;

        expect(
          await controller.readRuntimeInvocation(threadId, reportErrors: false),
          invocation,
        );
        expect(controller.state.status, statusBeforeRefresh);
        expect(controller.state.lastErrorCode, errorBeforeRefresh);
        expect(controller.runtimeInvocationCacheRevision.value, 1);

        expect(await controller.readRuntimeInvocation(threadId), invocation);
        expect(controller.state.status, ChatControllerStatus.failed);
        expect(controller.state.lastErrorCode, 'CHAT_RUNTIME_REFRESH_FAILED');
        expect(api.ifNoneMatches, <String?>[
          null,
          '"runtime-1"',
          '"runtime-1"',
        ]);
      },
    );

    test('loads runtime history across opaque cursor pages', () async {
      const threadId = 'runtime-history-thread-1';
      SharedThreadRuntimeInvocation invocation(String runId, int minute) =>
          SharedThreadRuntimeInvocation(
            schemaVersion: 'huahuo.thread-runtime-invocation.v1',
            threadId: threadId,
            agentRunId: runId,
            status: 'succeeded',
            agentProfileId: 'self_media_creation_standard',
            modelProfileId: 'model-profile-1',
            skillProfileIds: const <String>[],
            contentTypes: const <String>['text'],
            tools: const <SharedRuntimeTool>[],
            files: const <SharedRuntimeFile>[],
            createdAt: DateTime.utc(2026, 9, 2, 8, minute),
            completedAt: DateTime.utc(2026, 9, 2, 8, minute, 5),
          );

      final api = _RuntimeHistoryChatApi(
        <ApiConditionalResult<SharedThreadRuntimeInvocationPage>>[
          ApiConditionalResult<SharedThreadRuntimeInvocationPage>.fromApiResult(
            ApiResult<SharedThreadRuntimeInvocationPage>.success(
              data: SharedThreadRuntimeInvocationPage(
                items: <SharedThreadRuntimeInvocation>[
                  invocation('runtime-history-run-2', 2),
                ],
                nextCursor: 'opaque-page-2',
              ),
              status: 200,
              idempotencyStore: SubmissionKeyStore.empty,
              responseHeaders: const <String, String>{'ETag': '"history-1"'},
            ),
          ),
          ApiConditionalResult<SharedThreadRuntimeInvocationPage>.fromApiResult(
            ApiResult<SharedThreadRuntimeInvocationPage>.success(
              data: SharedThreadRuntimeInvocationPage(
                items: <SharedThreadRuntimeInvocation>[
                  invocation('runtime-history-run-1', 1),
                ],
              ),
              status: 200,
              idempotencyStore: SubmissionKeyStore.empty,
            ),
          ),
        ],
      );
      final controller = ChatController(api: api, scene: ChatScene.feedAi);
      addTearDown(controller.dispose);

      final history = await controller.readRuntimeInvocations(threadId);

      expect(history.map((item) => item.agentRunId), <String>[
        'runtime-history-run-2',
        'runtime-history-run-1',
      ]);
      expect(api.cursors, <String?>[null, 'opaque-page-2']);
      expect(api.limits, <int>[50, 50]);
    });

    test(
      'keeps the paged runtime window bounded without an aggregate ETag',
      () async {
        const threadId = 'runtime-history-window-thread-1';
        SharedThreadRuntimeInvocation invocation(int index) =>
            SharedThreadRuntimeInvocation(
              schemaVersion: 'huahuo.thread-runtime-invocation.v1',
              threadId: threadId,
              agentRunId: 'runtime-history-window-run-$index',
              status: 'succeeded',
              agentProfileId: 'self_media_creation_standard',
              modelProfileId: 'model-profile-1',
              skillProfileIds: const <String>[],
              contentTypes: const <String>['text'],
              tools: const <SharedRuntimeTool>[],
              files: const <SharedRuntimeFile>[],
              createdAt: DateTime.utc(
                2026,
                9,
                2,
              ).subtract(Duration(minutes: index)),
            );

        final results =
            <ApiConditionalResult<SharedThreadRuntimeInvocationPage>>[];
        void appendWindow(int start, String etag) {
          for (var pageIndex = 0; pageIndex < 4; pageIndex += 1) {
            final pageStart = start + pageIndex * 50;
            results.add(
              ApiConditionalResult<
                SharedThreadRuntimeInvocationPage
              >.fromApiResult(
                ApiResult<SharedThreadRuntimeInvocationPage>.success(
                  data: SharedThreadRuntimeInvocationPage(
                    items: <SharedThreadRuntimeInvocation>[
                      for (var offset = 0; offset < 50; offset += 1)
                        invocation(pageStart + offset),
                    ],
                    nextCursor: pageIndex == 3
                        ? 'beyond-window-$start'
                        : 'window-$start-page-${pageIndex + 2}',
                  ),
                  status: 200,
                  idempotencyStore: SubmissionKeyStore.empty,
                  responseHeaders: pageIndex == 0
                      ? <String, String>{'ETag': etag}
                      : const <String, String>{},
                ),
              ),
            );
          }
        }

        appendWindow(1, '"history-window-1"');
        appendWindow(0, '"history-window-2"');
        final api = _RuntimeHistoryChatApi(results);
        final controller = ChatController(api: api, scene: ChatScene.feedAi);
        addTearDown(controller.dispose);

        final first = await controller.readRuntimeInvocationHistory(threadId);
        final second = await controller.readRuntimeInvocationHistory(threadId);

        expect(first.items, hasLength(200));
        expect(first.isTruncated, isTrue);
        expect(second.items, hasLength(200));
        expect(second.isTruncated, isTrue);
        expect(
          second.items.map((item) => item.agentRunId),
          contains('runtime-history-window-run-0'),
        );
        expect(
          second.items.map((item) => item.agentRunId),
          isNot(contains('runtime-history-window-run-200')),
        );
        expect(api.ifNoneMatches, everyElement(isNull));
      },
    );

    test('retries runtime history after a continuation page fails', () async {
      const threadId = 'runtime-history-retry-thread-1';
      SharedThreadRuntimeInvocation invocation(String runId, int minute) =>
          SharedThreadRuntimeInvocation(
            schemaVersion: 'huahuo.thread-runtime-invocation.v1',
            threadId: threadId,
            agentRunId: runId,
            status: 'succeeded',
            agentProfileId: 'self_media_creation_standard',
            modelProfileId: 'model-profile-1',
            skillProfileIds: const <String>[],
            contentTypes: const <String>['text'],
            tools: const <SharedRuntimeTool>[],
            files: const <SharedRuntimeFile>[],
            createdAt: DateTime.utc(2026, 9, 2, 8, minute),
          );

      ApiConditionalResult<SharedThreadRuntimeInvocationPage> firstPage() =>
          ApiConditionalResult<SharedThreadRuntimeInvocationPage>.fromApiResult(
            ApiResult<SharedThreadRuntimeInvocationPage>.success(
              data: SharedThreadRuntimeInvocationPage(
                items: <SharedThreadRuntimeInvocation>[
                  invocation('runtime-history-retry-run-2', 2),
                ],
                nextCursor: 'retry-page-2',
              ),
              status: 200,
              idempotencyStore: SubmissionKeyStore.empty,
              responseHeaders: const <String, String>{
                'ETag': '"history-retry-1"',
              },
            ),
          );

      final api = _RuntimeHistoryChatApi(
        <ApiConditionalResult<SharedThreadRuntimeInvocationPage>>[
          firstPage(),
          ApiConditionalResult<SharedThreadRuntimeInvocationPage>.fromApiResult(
            _failure<SharedThreadRuntimeInvocationPage>(
              'CHAT_RUNTIME_CONTINUATION_TEMPORARY',
            ),
          ),
          firstPage(),
          ApiConditionalResult<SharedThreadRuntimeInvocationPage>.fromApiResult(
            ApiResult<SharedThreadRuntimeInvocationPage>.success(
              data: SharedThreadRuntimeInvocationPage(
                items: <SharedThreadRuntimeInvocation>[
                  invocation('runtime-history-retry-run-1', 1),
                ],
              ),
              status: 200,
              idempotencyStore: SubmissionKeyStore.empty,
            ),
          ),
          firstPage(),
          ApiConditionalResult<SharedThreadRuntimeInvocationPage>.fromApiResult(
            ApiResult<SharedThreadRuntimeInvocationPage>.success(
              data: SharedThreadRuntimeInvocationPage(
                items: <SharedThreadRuntimeInvocation>[
                  invocation('runtime-history-retry-run-1', 1),
                ],
              ),
              status: 200,
              idempotencyStore: SubmissionKeyStore.empty,
            ),
          ),
        ],
      );
      final controller = ChatController(api: api, scene: ChatScene.feedAi);
      addTearDown(controller.dispose);

      expect(
        (await controller.readRuntimeInvocations(
          threadId,
          reportErrors: false,
        )).map((item) => item.agentRunId),
        <String>['runtime-history-retry-run-2'],
      );
      expect(
        (await controller.readRuntimeInvocations(
          threadId,
        )).map((item) => item.agentRunId),
        <String>['runtime-history-retry-run-2', 'runtime-history-retry-run-1'],
      );
      expect(
        (await controller.readRuntimeInvocations(
          threadId,
        )).map((item) => item.agentRunId),
        <String>['runtime-history-retry-run-2', 'runtime-history-retry-run-1'],
      );
      expect(api.cursors, <String?>[
        null,
        'retry-page-2',
        null,
        'retry-page-2',
        null,
        'retry-page-2',
      ]);
      expect(api.ifNoneMatches, <String?>[null, null, null, null, null, null]);
    });

    test('loads the newest scene thread and server messages', () async {
      final api = _FakeChatApi(
        threads: <ChatThread>[
          _thread('older', updatedAt: DateTime.utc(2026, 7, 9)),
          _thread('newer', updatedAt: DateTime.utc(2026, 7, 10)),
        ],
        details: <String, ChatThreadDetail>{
          'newer': ChatThreadDetail(
            thread: _thread('newer').copyWith(scene: ChatScene.workAi),
            messages: <ChatMessage>[
              _message(
                id: 'assistant-1',
                threadId: 'newer',
                role: ChatMessageRole.assistant,
                text: '服务器已经整理出三条观点。',
              ).copyWith(scene: ChatScene.workAi),
            ],
          ),
        },
      );
      final controller = ChatController(api: api, scene: ChatScene.feedAi);

      await controller.loadThreads();

      expect(api.listPurposes, <ChatConversationPurpose>[
        ChatConversationPurpose.general,
      ]);
      expect(controller.state.status, ChatControllerStatus.ready);
      expect(controller.state.activeThreadId, 'newer');
      expect(controller.state.messages.single.visibleText, '服务器已经整理出三条观点。');
      expect(
        controller.state.threads
            .singleWhere((thread) => thread.threadId == 'newer')
            .scene,
        ChatScene.feedAi,
      );
      expect(controller.state.messages.single.scene, ChatScene.feedAi);
      expect(
        controller.state.messages.single.localDelivery,
        ChatLocalDeliveryState.server,
      );
      expect(api.detailCalls, <String>['newer']);
    });

    test('loads history without activating a prior conversation', () async {
      final api = _FakeChatApi(
        threads: <ChatThread>[
          _thread('older', updatedAt: DateTime.utc(2026, 7, 9)),
          _thread('newer', updatedAt: DateTime.utc(2026, 7, 10)),
        ],
      );
      final controller = ChatController(api: api, scene: ChatScene.feedAi);

      await controller.loadThreads(selectLatest: false);

      expect(controller.state.status, ChatControllerStatus.ready);
      expect(controller.state.activeThreadId, isNull);
      expect(controller.state.messages, isEmpty);
      expect(api.detailCalls, isEmpty);
    });

    test(
      'hydrates profile-less rows before selecting the newest matching Agent',
      () async {
        final newest = _thread(
          'profile-less-newest',
          updatedAt: DateTime.utc(2026, 8, 30, 12),
        );
        final matching = _thread(
          'profile-less-matching',
          updatedAt: DateTime.utc(2026, 8, 30, 11),
        );
        final api = _FakeChatApi(
          threads: <ChatThread>[matching, newest],
          details: <String, ChatThreadDetail>{
            newest.threadId: ChatThreadDetail(
              thread: newest.copyWith(agentProfileId: 'renshe_content'),
              messages: const <ChatMessage>[],
            ),
            matching.threadId: ChatThreadDetail(
              thread: matching.copyWith(agentProfileId: 'video_analysis'),
              messages: <ChatMessage>[
                _message(
                  id: 'matching-agent-history',
                  threadId: matching.threadId,
                  role: ChatMessageRole.assistant,
                  text: '最近一次视频分析历史',
                ),
              ],
            ),
          },
        );
        final controller = ChatController(
          api: api,
          scene: ChatScene.feedAi,
          initialAgentProfileId: 'video_analysis',
        );
        addTearDown(controller.dispose);

        await controller.loadThreads(refresh: true, authoritativeLatest: true);

        expect(controller.state.status, ChatControllerStatus.ready);
        expect(controller.state.activeThreadId, matching.threadId);
        expect(controller.state.messages.single.visibleText, '最近一次视频分析历史');
        expect(
          api.detailCalls,
          containsAllInOrder(<String>[newest.threadId, matching.threadId]),
        );
      },
    );

    test(
      'keeps cached conversation visible until authoritative latest resolves',
      () async {
        final database = AppDatabase();
        final repository = ChatThreadAliasRepository(
          dao: UserMetadataDao(database),
          preferencesDao: AppPreferencesDao(database),
          userScope: 'authoritative-latest-cache-user',
        );
        final cached = _thread(
          'cached-older-thread',
          updatedAt: DateTime.utc(2026, 8, 29),
          agentProfileId: standardCreationChatAgentProfileId,
        );
        final latest = _thread(
          'server-latest-thread',
          updatedAt: DateTime.utc(2026, 8, 30),
          agentProfileId: standardCreationChatAgentProfileId,
        );
        repository.saveConversationCache(
          scene: ChatScene.feedAi,
          purpose: ChatConversationPurpose.general,
          agentProfileId: standardCreationChatAgentProfileId,
          threads: <ChatThread>[cached],
          messagesByThread: <String, List<ChatMessage>>{
            cached.threadId: <ChatMessage>[
              _message(
                id: 'cached-older-message',
                threadId: cached.threadId,
                role: ChatMessageRole.assistant,
                text: '缓存中的旧会话',
              ),
            ],
          },
        );
        final list = Completer<ApiResult<ChatThreadPage>>();
        final api = _FakeChatApi(
          listThreadsHandler: (_, __) => list.future,
          details: <String, ChatThreadDetail>{
            latest.threadId: ChatThreadDetail(
              thread: latest,
              messages: <ChatMessage>[
                _message(
                  id: 'server-latest-message',
                  threadId: latest.threadId,
                  role: ChatMessageRole.assistant,
                  text: '服务端最新会话',
                ),
              ],
            ),
          },
        );
        final controller = ChatController(
          api: api,
          scene: ChatScene.feedAi,
          aliasRepository: repository,
          initialAgentProfileId: standardCreationChatAgentProfileId,
          restoreRecentConversationOnCreate: true,
        );
        addTearDown(controller.dispose);
        expect(controller.state.activeThreadId, cached.threadId);

        final refresh = controller.loadThreads(
          refresh: true,
          authoritativeLatest: true,
        );
        expect(controller.state.status, ChatControllerStatus.ready);
        expect(controller.state.messages.single.visibleText, '缓存中的旧会话');

        list.complete(
          _success(
            ChatThreadPage(items: <ChatThread>[latest]),
            SubmissionKeyStore.empty,
          ),
        );
        await refresh;

        expect(controller.state.activeThreadId, latest.threadId);
        expect(controller.state.messages.single.visibleText, '服务端最新会话');
      },
    );

    test(
      'skips an empty newest thread and restores the next valid conversation',
      () async {
        final newest = _thread(
          'newest-empty-thread',
          updatedAt: DateTime.utc(2026, 8, 31, 10),
        );
        final previous = _thread(
          'previous-valid-thread',
          updatedAt: DateTime.utc(2026, 8, 31, 9),
        );
        final api = _FakeChatApi(
          threads: <ChatThread>[previous, newest],
          details: <String, ChatThreadDetail>{
            newest.threadId: ChatThreadDetail(
              thread: newest,
              messages: const <ChatMessage>[],
            ),
            previous.threadId: ChatThreadDetail(
              thread: previous,
              messages: <ChatMessage>[
                _message(
                  id: 'previous-valid-assistant',
                  threadId: previous.threadId,
                  role: ChatMessageRole.assistant,
                  text: '这是最近一条有效会话。',
                ),
              ],
            ),
          },
        );
        final controller = ChatController(api: api, scene: ChatScene.feedAi);
        addTearDown(controller.dispose);

        await controller.loadThreads(refresh: true, authoritativeLatest: true);

        expect(api.detailCalls, <String>[newest.threadId, previous.threadId]);
        expect(controller.state.status, ChatControllerStatus.ready);
        expect(controller.state.activeThreadId, previous.threadId);
        expect(controller.state.messages.single.visibleText, '这是最近一条有效会话。');
      },
    );

    test(
      'keeps a recent-thread detail failure out of the empty state',
      () async {
        final newest = _thread(
          'unreadable-newest-thread',
          updatedAt: DateTime.utc(2026, 8, 31, 11),
        );
        final controller = ChatController(
          api: _FakeChatApi(threads: <ChatThread>[newest]),
          scene: ChatScene.feedAi,
        );
        addTearDown(controller.dispose);

        await controller.loadThreads(refresh: true, authoritativeLatest: true);

        expect(controller.state.status, ChatControllerStatus.failed);
        expect(controller.state.activeThreadId, newest.threadId);
        expect(controller.state.lastErrorCode, 'CHAT_THREAD_DETAIL_FAILED');
      },
    );

    test('does not restore latest over an explicit new conversation', () async {
      final current = _thread(
        'current-before-refresh',
        updatedAt: DateTime.utc(2026, 8, 29),
      );
      final latest = _thread(
        'latest-after-refresh',
        updatedAt: DateTime.utc(2026, 8, 30),
      );
      final refreshResult = Completer<ApiResult<ChatThreadPage>>();
      var listCalls = 0;
      final api = _FakeChatApi(
        listThreadsHandler: (_, __) {
          listCalls += 1;
          if (listCalls == 1) {
            return Future<ApiResult<ChatThreadPage>>.value(
              _success(
                ChatThreadPage(items: <ChatThread>[current]),
                SubmissionKeyStore.empty,
              ),
            );
          }
          return refreshResult.future;
        },
        details: <String, ChatThreadDetail>{
          current.threadId: ChatThreadDetail(
            thread: current,
            messages: <ChatMessage>[
              _message(
                id: 'current-before-refresh-message',
                threadId: current.threadId,
                role: ChatMessageRole.assistant,
                text: '当前会话',
              ),
            ],
          ),
          latest.threadId: ChatThreadDetail(
            thread: latest,
            messages: const <ChatMessage>[],
          ),
        },
      );
      final controller = ChatController(api: api, scene: ChatScene.feedAi);
      addTearDown(controller.dispose);
      await controller.loadThreads();
      expect(controller.state.activeThreadId, current.threadId);

      final refresh = controller.loadThreads(
        refresh: true,
        authoritativeLatest: true,
      );
      controller.startNewThread();
      refreshResult.complete(
        _success(
          ChatThreadPage(items: <ChatThread>[latest]),
          SubmissionKeyStore.empty,
        ),
      );
      await refresh;

      expect(controller.state.activeThreadId, isNull);
      expect(controller.state.messages, isEmpty);
    });

    test(
      'distinguishes confirmed empty history from discovery failure',
      () async {
        final empty = ChatController(
          api: _FakeChatApi(),
          scene: ChatScene.feedAi,
        );
        addTearDown(empty.dispose);
        await empty.loadThreads(refresh: true, authoritativeLatest: true);
        expect(empty.state.status, ChatControllerStatus.ready);
        expect(empty.state.activeThreadId, isNull);
        expect(empty.state.lastErrorCode, isNull);

        final failed = ChatController(
          api: _FakeChatApi(
            listThreadsHandler: (_, __) async =>
                _failure('CHAT_THREAD_LIST_FAILED'),
          ),
          scene: ChatScene.feedAi,
        );
        addTearDown(failed.dispose);
        await failed.loadThreads(refresh: true, authoritativeLatest: true);
        expect(failed.state.status, ChatControllerStatus.failed);
        expect(failed.state.activeThreadId, isNull);
        expect(failed.state.lastErrorCode, 'CHAT_THREAD_LIST_FAILED');
      },
    );

    test(
      'refreshes one cached row into all 126 ordinary threads across pages',
      () async {
        final threads = List<ChatThread>.generate(126, (index) {
          return _thread(
            'ordinary-$index',
            updatedAt: DateTime.utc(
              2026,
              8,
              26,
            ).subtract(Duration(minutes: index)),
            agentProfileId: standardCreationChatAgentProfileId,
          ).copyWith(firstUserMessageText: '问题 $index');
        });
        final firstCursor = threads[49].updatedAt!.toIso8601String();
        final secondCursor = threads[99].updatedAt!.toIso8601String();
        var invocation = 0;
        final api = _FakeChatApi(
          listThreadsHandler: (cursor, limit) async {
            invocation += 1;
            if (invocation == 1) {
              return _success(
                ChatThreadPage(items: <ChatThread>[threads.first]),
                SubmissionKeyStore.empty,
              );
            }
            final items = switch (cursor) {
              null => threads.sublist(0, 50),
              final value when value == firstCursor => threads.sublist(50, 100),
              final value when value == secondCursor => threads.sublist(100),
              _ => const <ChatThread>[],
            };
            return _success(
              ChatThreadPage(items: items),
              SubmissionKeyStore.empty,
            );
          },
        );
        final controller = ChatController(
          api: api,
          scene: ChatScene.feedAi,
          initialAgentProfileId: standardCreationChatAgentProfileId,
        );
        addTearDown(controller.dispose);

        await controller.loadThreads(selectLatest: false);
        expect(controller.historyThreads, hasLength(1));

        await controller.refreshCompleteHistory();

        expect(controller.historyThreads, hasLength(126));
        expect(controller.historyThreads.first.threadId, 'ordinary-0');
        expect(controller.historyThreads.last.threadId, 'ordinary-125');
        expect(api.listCursors, <String?>[
          null,
          null,
          firstCursor,
          secondCursor,
        ]);
        expect(controller.hasMoreHistory, isFalse);
        expect(controller.historyRefreshErrorCode, isNull);
      },
    );

    test(
      'hydrates missing Agent types before exposing ordinary history',
      () async {
        final ordinary = _thread(
          'ordinary-unclassified',
        ).copyWith(firstUserMessageText: '普通聊一聊');
        final specialist = _thread(
          'visual-unclassified',
        ).copyWith(firstUserMessageText: '视觉设计');
        final api = _FakeChatApi(
          threads: <ChatThread>[ordinary, specialist],
          details: <String, ChatThreadDetail>{
            ordinary.threadId: ChatThreadDetail(
              thread: ordinary.copyWith(
                agentProfileId: standardCreationChatAgentProfileId,
              ),
              messages: const <ChatMessage>[],
            ),
            specialist.threadId: ChatThreadDetail(
              thread: specialist.copyWith(agentProfileId: 'visual_chat'),
              messages: const <ChatMessage>[],
            ),
          },
        );
        final controller = ChatController(
          api: api,
          scene: ChatScene.feedAi,
          initialAgentProfileId: standardCreationChatAgentProfileId,
        );
        addTearDown(controller.dispose);

        await controller.refreshCompleteHistory();

        expect(
          controller.historyThreads.map((thread) => thread.threadId),
          <String>[ordinary.threadId],
        );
        expect(api.detailCalls.toSet(), <String>{
          ordinary.threadId,
          specialist.threadId,
        });
      },
    );

    test(
      'reuses a fresh complete history snapshot until an explicit refresh',
      () async {
        final database = AppDatabase();
        final repository = ChatThreadAliasRepository(
          dao: UserMetadataDao(database),
          preferencesDao: AppPreferencesDao(database),
          userScope: 'chat-fresh-complete-history-user',
        );
        var now = DateTime.utc(2026, 8, 30, 10);
        final thread = _thread(
          'fresh-history-thread',
          updatedAt: now,
          agentProfileId: standardCreationChatAgentProfileId,
        ).copyWith(firstUserMessageText: '缓存中的问题');
        repository.saveConversationCache(
          scene: ChatScene.feedAi,
          purpose: ChatConversationPurpose.general,
          agentProfileId: standardCreationChatAgentProfileId,
          threads: <ChatThread>[thread],
          messagesByThread: <String, List<ChatMessage>>{
            thread.threadId: <ChatMessage>[
              _message(
                id: 'fresh-history-message',
                threadId: thread.threadId,
                role: ChatMessageRole.assistant,
                text: '缓存立即显示',
              ),
            ],
          },
          historySyncedAt: now,
          historyComplete: true,
        );
        final api = _FakeChatApi(threads: <ChatThread>[thread]);
        final controller = ChatController(
          api: api,
          scene: ChatScene.feedAi,
          aliasRepository: repository,
          initialAgentProfileId: standardCreationChatAgentProfileId,
          now: () => now,
        );
        addTearDown(controller.dispose);

        expect(controller.restoreCachedConversations(), isTrue);
        now = now.add(const Duration(minutes: 4));
        await controller.refreshCompleteHistory();

        expect(api.listCalls, 0);
        expect(controller.historyThreads.single.threadId, thread.threadId);

        await controller.refreshCompleteHistory(force: true);

        expect(api.listCalls, 1);
      },
    );

    test(
      'shows cached messages while one stale detail refresh is coalesced',
      () async {
        final database = AppDatabase();
        final repository = ChatThreadAliasRepository(
          dao: UserMetadataDao(database),
          preferencesDao: AppPreferencesDao(database),
          userScope: 'chat-stale-detail-user',
        );
        var now = DateTime.utc(2026, 8, 30, 11);
        final thread = _thread(
          'stale-detail-thread',
          updatedAt: now,
          agentProfileId: standardCreationChatAgentProfileId,
        );
        repository.saveConversationCache(
          scene: ChatScene.feedAi,
          purpose: ChatConversationPurpose.general,
          agentProfileId: standardCreationChatAgentProfileId,
          threads: <ChatThread>[thread],
          messagesByThread: <String, List<ChatMessage>>{
            thread.threadId: <ChatMessage>[
              _message(
                id: 'cached-detail-message',
                threadId: thread.threadId,
                role: ChatMessageRole.assistant,
                text: '先显示缓存',
              ),
            ],
          },
          detailSyncedAtByThread: <String, DateTime>{thread.threadId: now},
        );
        final detail = Completer<ApiResult<ChatThreadDetail>>();
        final api = _FakeChatApi(
          detailCompleters: <String, Completer<ApiResult<ChatThreadDetail>>>{
            thread.threadId: detail,
          },
        );
        final controller = ChatController(
          api: api,
          scene: ChatScene.feedAi,
          aliasRepository: repository,
          initialAgentProfileId: standardCreationChatAgentProfileId,
          now: () => now,
        );
        addTearDown(controller.dispose);

        expect(controller.restoreCachedConversations(), isTrue);
        await controller.selectThread(thread.threadId);
        await controller.revalidateThreadIfStale(thread.threadId);
        expect(api.detailCalls, isEmpty);
        expect(controller.state.messages.single.visibleText, '先显示缓存');

        now = now.add(const Duration(minutes: 3));
        final first = controller.revalidateThreadIfStale(thread.threadId);
        final second = controller.revalidateThreadIfStale(thread.threadId);
        expect(api.detailCalls, <String>[thread.threadId]);
        expect(controller.state.messages.single.visibleText, '先显示缓存');

        detail.complete(
          _success(
            ChatThreadDetail(
              thread: thread,
              messages: <ChatMessage>[
                _message(
                  id: 'cached-detail-message',
                  threadId: thread.threadId,
                  role: ChatMessageRole.assistant,
                  text: '后台更新完成',
                ),
              ],
            ),
            SubmissionKeyStore.empty,
          ),
        );
        await Future.wait(<Future<void>>[first, second]);

        expect(api.detailCalls, <String>[thread.threadId]);
        expect(controller.state.messages.single.visibleText, '后台更新完成');
      },
    );

    test('sorts Agent-scoped history newest first', () async {
      final api = _FakeChatApi(
        threads: <ChatThread>[
          _thread(
            'video-older',
            updatedAt: DateTime.utc(2026, 8, 18, 8),
            agentProfileId: 'video_analysis',
          ),
          _thread(
            'standard-newest',
            updatedAt: DateTime.utc(2026, 8, 21, 12),
            agentProfileId: standardCreationChatAgentProfileId,
          ),
          _thread(
            'video-newest',
            updatedAt: DateTime.utc(2026, 8, 21, 10),
            agentProfileId: 'video_analysis',
          ),
          _thread(
            'video-middle',
            updatedAt: DateTime.utc(2026, 8, 20, 9),
            agentProfileId: 'video_analysis',
          ),
        ],
      );
      final controller = ChatController(
        api: api,
        scene: ChatScene.feedAi,
        initialAgentProfileId: 'video_analysis',
      );

      await controller.loadThreads(selectLatest: false);

      expect(
        controller.historyThreads.map((thread) => thread.threadId),
        <String>['video-newest', 'video-middle', 'video-older'],
      );
    });

    test('places a newly created timestamp-less thread first', () async {
      final activityAt = DateTime.utc(2026, 8, 22, 9, 30);
      final api = _FakeChatApi(
        threads: <ChatThread>[
          _thread('older', updatedAt: DateTime.utc(2026, 8, 21, 18)),
          _thread('newer', updatedAt: DateTime.utc(2026, 8, 22, 8)),
        ],
        createdThread: _thread('created-without-time'),
        sentMutation: ChatTextMutation(
          message: _message(
            id: 'created-first-user',
            threadId: 'created-without-time',
            role: ChatMessageRole.user,
          ),
        ),
      );
      final controller = ChatController(
        api: api,
        scene: ChatScene.feedAi,
        now: () => activityAt,
      );
      addTearDown(controller.dispose);

      await controller.loadThreads(selectLatest: false);
      expect(await controller.sendText('刚创建的会话'), isTrue);

      expect(
        controller.historyThreads.map((thread) => thread.threadId),
        <String>['created-without-time', 'newer', 'older'],
      );
      final created = controller.historyThreads.first;
      expect(created.updatedAt, activityAt);
      expect(created.firstUserMessageText, '刚创建的会话');
    });

    test(
      'foreground reconciliation remains eligible for an unanswered turn',
      () async {
        const threadId = 'unanswered-foreground-thread';
        const agentRunId = 'unanswered-foreground-run';
        final details = <String, ChatThreadDetail>{};
        final api = _FakeChatApi(
          createdThread: _thread(threadId),
          sentMutation: ChatTextMutation(
            message: _message(
              id: 'unanswered-user',
              threadId: threadId,
              role: ChatMessageRole.user,
            ),
            nextAction: const ChatNextAction(
              type: ChatNextActionType.pollAgentRun,
              agentRunId: agentRunId,
            ),
          ),
          details: details,
        );
        final controller = ChatController(
          api: api,
          assistantRuntime: legacyAssistantRuntime(
            _StableAssistantRuntimeFixture(
              _runSuccess(
                _agentRun(
                  agentRunId: agentRunId,
                  status: 'running',
                  threadId: threadId,
                ),
              ),
            ),
          ),
          runTracker: const _DetachingChatRunTracker(),
          scene: ChatScene.feedAi,
          taskPollInterval: Duration.zero,
        );
        addTearDown(controller.dispose);

        expect(await controller.sendText('切到后台后等待回复'), isTrue);
        await Future<void>.delayed(Duration.zero);
        expect(controller.shouldRefreshThreadOnForeground(threadId), isTrue);

        details[threadId] = ChatThreadDetail(
          thread: _thread(threadId),
          messages: <ChatMessage>[
            _message(
              id: 'unanswered-user',
              threadId: threadId,
              role: ChatMessageRole.user,
              text: '切到后台后等待回复',
            ),
            _message(
              id: 'foreground-assistant',
              threadId: threadId,
              role: ChatMessageRole.assistant,
              text: '后台完成的回复',
            ),
          ],
        );
        await controller.selectThread(threadId, forceRemote: true);

        expect(controller.shouldRefreshThreadOnForeground(threadId), isFalse);
        expect(controller.state.messages.last.visibleText, '后台完成的回复');
      },
    );

    test(
      'restores only the matching Agent history for a profile entry',
      () async {
        final database = AppDatabase();
        final repository = ChatThreadAliasRepository(
          dao: UserMetadataDao(database),
          preferencesDao: AppPreferencesDao(database),
          userScope: 'chat-agent-entry-cache-user',
        );
        final personaThread = _thread(
          'persona-history',
          updatedAt: DateTime.utc(2026, 8, 17, 9),
          agentProfileId: 'renshe_content',
        );
        final unrelatedThread = _thread(
          'newer-unrelated-history',
          updatedAt: DateTime.utc(2026, 8, 17, 10),
          agentProfileId: 'visual_chat',
        );
        repository.saveConversationCache(
          scene: ChatScene.feedAi,
          purpose: ChatConversationPurpose.general,
          threads: <ChatThread>[unrelatedThread, personaThread],
          messagesByThread: <String, List<ChatMessage>>{
            personaThread.threadId: <ChatMessage>[
              _message(
                id: 'persona-history-user',
                threadId: personaThread.threadId,
                role: ChatMessageRole.user,
                text: '个人 IP 历史消息',
              ),
            ],
            unrelatedThread.threadId: <ChatMessage>[
              _message(
                id: 'unrelated-history-user',
                threadId: unrelatedThread.threadId,
                role: ChatMessageRole.user,
                text: '无关的视觉设计历史',
              ),
            ],
          },
        );
        final api = _FakeChatApi();
        final personaController = ChatController(
          api: api,
          scene: ChatScene.feedAi,
          aliasRepository: repository,
          initialAgentProfileId: 'renshe_content',
        );

        expect(personaController.restoreCachedConversations(), isTrue);
        expect(
          personaController.historyThreads.map((thread) => thread.threadId),
          <String>[personaThread.threadId],
        );
        expect(await personaController.restoreRecentPurposeThread(), isTrue);
        expect(personaController.state.activeThreadId, personaThread.threadId);
        expect(
          personaController.state.messages.single.visibleText,
          '个人 IP 历史消息',
        );
        expect(api.listCalls, 0);
        expect(api.createCalls, 0);

        final missingProfileController = ChatController(
          api: api,
          scene: ChatScene.feedAi,
          aliasRepository: ChatThreadAliasRepository(
            dao: UserMetadataDao(database),
            preferencesDao: AppPreferencesDao(database),
            userScope: 'chat-agent-entry-cache-user',
          ),
          initialAgentProfileId: 'huoke_content',
        );
        expect(missingProfileController.restoreCachedConversations(), isFalse);
        expect(
          await missingProfileController.restoreRecentPurposeThread(),
          isFalse,
        );
        await missingProfileController.loadThreads();
        expect(missingProfileController.state.activeThreadId, isNull);
        expect(api.createCalls, 0);
      },
    );

    test('persists general Chat history in independent Agent scopes', () {
      final database = AppDatabase();
      final repository = ChatThreadAliasRepository(
        dao: UserMetadataDao(database),
        preferencesDao: AppPreferencesDao(database),
        userScope: 'chat-agent-scoped-cache-user',
      );
      final personaThread = _thread(
        'persona-scoped-history',
        agentProfileId: 'renshe_content',
      );
      final leadThread = _thread(
        'lead-scoped-history',
        agentProfileId: 'huoke_content',
      );

      repository.saveConversationCache(
        scene: ChatScene.feedAi,
        purpose: ChatConversationPurpose.general,
        agentProfileId: 'renshe_content',
        threads: <ChatThread>[personaThread, leadThread],
        messagesByThread: <String, List<ChatMessage>>{
          personaThread.threadId: <ChatMessage>[
            _message(
              id: 'persona-scoped-message',
              threadId: personaThread.threadId,
              role: ChatMessageRole.user,
            ),
          ],
          leadThread.threadId: <ChatMessage>[
            _message(
              id: 'lead-scoped-message',
              threadId: leadThread.threadId,
              role: ChatMessageRole.user,
            ),
          ],
        },
      );
      repository.saveConversationCache(
        scene: ChatScene.feedAi,
        purpose: ChatConversationPurpose.general,
        agentProfileId: 'huoke_content',
        threads: <ChatThread>[personaThread, leadThread],
        messagesByThread: <String, List<ChatMessage>>{},
      );

      final personaCache = repository.loadConversationCache(
        scene: ChatScene.feedAi,
        purpose: ChatConversationPurpose.general,
        agentProfileId: 'renshe_content',
      );
      final leadCache = repository.loadConversationCache(
        scene: ChatScene.feedAi,
        purpose: ChatConversationPurpose.general,
        agentProfileId: 'huoke_content',
      );

      expect(personaCache?.threads.map((thread) => thread.threadId), <String>[
        personaThread.threadId,
      ]);
      expect(personaCache?.messagesByThread.keys, <String>[
        personaThread.threadId,
      ]);
      expect(leadCache?.threads.map((thread) => thread.threadId), <String>[
        leadThread.threadId,
      ]);
      expect(leadCache?.messagesByThread, isEmpty);
    });

    test(
      'standard creation restores profile-less legacy ordinary history',
      () async {
        final database = AppDatabase();
        final repository = ChatThreadAliasRepository(
          dao: UserMetadataDao(database),
          preferencesDao: AppPreferencesDao(database),
          userScope: 'chat-standard-legacy-history-user',
        );
        final legacyThread = _thread(
          'legacy-ordinary-history',
          updatedAt: DateTime.utc(2026, 8, 18, 10),
        );
        repository.saveConversationCache(
          scene: ChatScene.feedAi,
          purpose: ChatConversationPurpose.general,
          threads: <ChatThread>[legacyThread],
          messagesByThread: <String, List<ChatMessage>>{
            legacyThread.threadId: <ChatMessage>[
              _message(
                id: 'legacy-ordinary-history-message',
                threadId: legacyThread.threadId,
                role: ChatMessageRole.assistant,
                text: '旧的普通历史也要继续显示。',
              ),
            ],
          },
        );
        final api = _FakeChatApi();
        final standardController = ChatController(
          api: api,
          scene: ChatScene.feedAi,
          aliasRepository: repository,
          initialAgentProfileId: standardCreationChatAgentProfileId,
        );

        expect(standardController.restoreCachedConversations(), isTrue);
        expect(await standardController.restoreRecentPurposeThread(), isTrue);
        expect(standardController.state.activeThreadId, legacyThread.threadId);
        expect(
          standardController.state.threads.single.agentProfileId,
          standardCreationChatAgentProfileId,
        );
        expect(
          standardController.state.messages.single.visibleText,
          '旧的普通历史也要继续显示。',
        );

        final personaController = ChatController(
          api: api,
          scene: ChatScene.feedAi,
          aliasRepository: ChatThreadAliasRepository(
            dao: UserMetadataDao(database),
            preferencesDao: AppPreferencesDao(database),
            userScope: 'chat-standard-legacy-history-user',
          ),
          initialAgentProfileId: 'renshe_content',
        );
        expect(personaController.restoreCachedConversations(), isFalse);
        expect(await personaController.restoreRecentPurposeThread(), isFalse);
        expect(api.createCalls, 0);
      },
    );

    test(
      'list refresh keeps an active historical thread despite profile mismatch',
      () async {
        final database = AppDatabase();
        final repository = ChatThreadAliasRepository(
          dao: UserMetadataDao(database),
          preferencesDao: AppPreferencesDao(database),
          userScope: 'chat-refresh-active-history-user',
        );
        final activeThread = _thread(
          'active-history-before-refresh',
          agentProfileId: standardCreationChatAgentProfileId,
        );
        repository.saveConversationCache(
          scene: ChatScene.feedAi,
          purpose: ChatConversationPurpose.general,
          threads: <ChatThread>[activeThread],
          messagesByThread: <String, List<ChatMessage>>{
            activeThread.threadId: <ChatMessage>[
              _message(
                id: 'active-history-message',
                threadId: activeThread.threadId,
                role: ChatMessageRole.assistant,
                text: '保持当前历史。',
              ),
            ],
          },
        );
        final api = _FakeChatApi(
          threads: <ChatThread>[
            _thread(
              'discovery-thread-after-refresh',
              agentProfileId: standardCreationChatAgentProfileId,
            ),
          ],
        );
        final controller = ChatController(
          api: api,
          scene: ChatScene.feedAi,
          aliasRepository: repository,
          initialAgentProfileId: standardCreationChatAgentProfileId,
        );

        expect(controller.restoreCachedConversations(), isTrue);
        await controller.selectThread(activeThread.threadId);
        await controller.loadThreads(refresh: true, selectLatest: false);

        expect(controller.state.activeThreadId, activeThread.threadId);
        expect(controller.state.messages.single.visibleText, '保持当前历史。');
      },
    );

    test(
      'creates a thread before first text send and adds no fabricated reply',
      () async {
        final api = _FakeChatApi(
          createdThread: _thread('created-1'),
          sentMutation: ChatTextMutation(
            message: _message(
              id: 'user-1',
              threadId: 'created-1',
              role: ChatMessageRole.user,
            ),
          ),
        );
        final controller = ChatController(api: api, scene: ChatScene.feedAi);

        final sent = await controller.sendText('请帮我整理这段访谈');

        expect(sent, isTrue);
        expect(api.createCalls, 1);
        expect(api.sentContents, <String>['请帮我整理这段访谈']);
        expect(controller.state.status, ChatControllerStatus.ready);
        expect(controller.state.activeThreadId, 'created-1');
        expect(controller.state.messages, hasLength(1));
        expect(controller.state.messages.single.role, ChatMessageRole.user);
        expect(controller.state.messages.single.visibleText, '请帮我整理这段访谈');
        expect(
          controller.state.messages.where(
            (message) => message.role == ChatMessageRole.assistant,
          ),
          isEmpty,
        );
      },
    );

    test(
      'creation Canvas first turn projects optimistic ack and title only',
      () async {
        final snapshot = ChatLocalDraftSnapshot.create(
          kind: 'creation_canvas',
          content: '这是一段尚未保存到资产的创作正文。',
          revision: 'canvas-revision-1',
        )!;
        const prompt = '请把这一段改得更口语化';
        const transportContent =
            '$creationCanvasChatScopeInstruction\n\n$prompt';
        final transportReadback =
            '$transportContent\n\n${snapshot.toAgentTextPart()}';
        final createThreadCompleter = Completer<ApiResult<ChatThread>>();
        final api = _FakeChatApi(
          createThreadCompleter: createThreadCompleter,
          sentMutation: ChatTextMutation(
            message: _message(
              id: 'creation-first-user',
              threadId: 'creation-first-thread',
              role: ChatMessageRole.user,
              text: transportReadback,
            ),
          ),
        );
        final controller = ChatController(
          api: api,
          scene: ChatScene.feedAi,
          userVisibleTextProjector: projectCreationCanvasChatUserPrompt,
        );
        final context = ChatContextEnvelope.create(
          purpose: ChatContextPurpose.general,
          localDraftSnapshot: snapshot,
        );

        final submission = controller.sendText(
          transportContent,
          context: context,
        );
        await Future<void>.delayed(Duration.zero);

        expect(controller.state.isSending, isTrue);
        expect(controller.state.activeThreadId, isNull);
        expect(controller.state.messages.single.visibleText, prompt);
        expect(
          controller.state.messages.single.localDelivery,
          ChatLocalDeliveryState.pending,
        );
        expect(api.sentContents, isEmpty);

        createThreadCompleter.complete(
          _success(_thread('creation-first-thread'), SubmissionKeyStore.empty),
        );

        expect(await submission, isTrue);

        expect(api.sentContents, <String>[transportContent]);
        expect(api.sentContexts.single?.localDraftSnapshot, same(snapshot));
        expect(controller.state.messages.single.visibleText, prompt);
        expect(controller.state.threads.single.displayTitle, prompt);
        expect(transportReadback, contains('这是一段尚未保存到资产的创作正文。'));
      },
    );

    test(
      'projects local-draft server readback in both message and thread title',
      () async {
        final snapshot = ChatLocalDraftSnapshot.create(
          kind: 'creation_canvas',
          content: '服务端回读时不能显示的正文。',
          revision: 'canvas-revision-2',
        )!;
        const prompt = '只分析这里的语气';
        final rawUserText =
            '$creationCanvasChatScopeInstruction\n\n$prompt\n\n'
            '${snapshot.toAgentTextPart()}';
        final collapsedTitle = rawUserText.replaceAll(RegExp(r'\s+'), ' ');
        final thread = ChatThread(
          threadId: 'creation-readback-thread',
          scene: ChatScene.feedAi,
          title: '新会话',
          firstUserMessageText: collapsedTitle.substring(0, 120),
        );
        final api = _FakeChatApi(
          threads: <ChatThread>[thread],
          details: <String, ChatThreadDetail>{
            thread.threadId: ChatThreadDetail(
              thread: thread,
              messages: <ChatMessage>[
                _message(
                  id: 'creation-readback-user',
                  threadId: thread.threadId,
                  role: ChatMessageRole.user,
                  text: rawUserText,
                ),
                _message(
                  id: 'creation-readback-assistant',
                  threadId: thread.threadId,
                  role: ChatMessageRole.assistant,
                  text: '语气分析结果',
                ),
              ],
            ),
          },
        );
        final controller = ChatController(
          api: api,
          scene: ChatScene.feedAi,
          userVisibleTextProjector: projectCreationCanvasChatUserPrompt,
        );

        await controller.loadThreads(refresh: true);

        expect(controller.state.activeThreadId, thread.threadId);
        expect(controller.state.messages.first.visibleText, prompt);
        expect(controller.state.threads.single.displayTitle, prompt);
        expect(
          controller.state.messages.every(
            (message) =>
                !(message.visibleText ?? '').contains('服务端回读时不能显示的正文。'),
          ),
          isTrue,
        );
      },
    );

    test(
      'creation Canvas ackless readback replaces its projected pending row',
      () async {
        const threadId = 'creation-ackless-thread';
        const agentRunId = 'creation-ackless-run';
        const prompt = '把第二段缩短一点';
        final snapshot = ChatLocalDraftSnapshot.create(
          kind: 'creation_canvas',
          content: '第一段正文。\n\n第二段需要缩短的正文。',
          revision: 'canvas-revision-ackless',
        )!;
        const transportContent =
            '$creationCanvasChatScopeInstruction\n\n$prompt';
        final rawReadback =
            '$transportContent\n\n${snapshot.toAgentTextPart()}';
        final api = _FakeChatApi(
          createdThread: _thread(threadId),
          sentMutation: const ChatTextMutation(
            nextAction: ChatNextAction(
              type: ChatNextActionType.pollAgentRun,
              agentRunId: agentRunId,
            ),
          ),
          details: <String, ChatThreadDetail>{
            threadId: ChatThreadDetail(
              thread: _thread(threadId),
              messages: <ChatMessage>[
                _message(
                  id: 'creation-ackless-user',
                  threadId: threadId,
                  role: ChatMessageRole.user,
                  text: rawReadback,
                ),
                _message(
                  id: 'creation-ackless-assistant',
                  threadId: threadId,
                  role: ChatMessageRole.assistant,
                  text: '已缩短第二段。',
                ),
              ],
            ),
          },
        );
        final controller = ChatController(
          api: api,
          assistantRuntime: legacyAssistantRuntime(
            _FakeAssistantRuntimeFixture(<ApiResult<AgentRunSnapshot>>[
              _runSuccess(
                _agentRun(
                  agentRunId: agentRunId,
                  status: 'succeeded',
                  threadId: threadId,
                  assistantMessageId: 'creation-ackless-assistant',
                  completionMode: 'normal',
                ),
              ),
            ]),
          ),
          scene: ChatScene.feedAi,
          userVisibleTextProjector: projectCreationCanvasChatUserPrompt,
          taskPollInterval: Duration.zero,
          taskPollAttempts: 1,
        );
        final context = ChatContextEnvelope.create(
          purpose: ChatContextPurpose.general,
          localDraftSnapshot: snapshot,
        );

        expect(
          await controller.sendText(transportContent, context: context),
          isTrue,
        );

        expect(api.sentContents, <String>[transportContent]);
        expect(api.sentContexts.single?.localDraftSnapshot, same(snapshot));
        final userMessages = controller.state.messages
            .where((message) => message.role == ChatMessageRole.user)
            .toList();
        expect(userMessages, hasLength(1));
        expect(userMessages.single.messageId, 'creation-ackless-user');
        expect(userMessages.single.visibleText, prompt);
        expect(controller.state.threads.single.displayTitle, prompt);
      },
    );

    test(
      'projects only automatic local-draft titles from thread lists',
      () async {
        final snapshot = ChatLocalDraftSnapshot.create(
          kind: 'creation_canvas',
          content: '列表没有完整消息时仍不能泄漏的正文。',
          revision: 'canvas-revision-list',
        )!;
        const prompt = '短问题';
        final rawTitle =
            '$creationCanvasChatScopeInstruction\n\n$prompt\n\n'
                    '${snapshot.toAgentTextPart()}'
                .replaceAll(RegExp(r'\s+'), ' ');
        final boundedTitle = rawTitle.substring(0, 120);
        final automatic = ChatThread(
          threadId: 'creation-list-auto',
          scene: ChatScene.feedAi,
          title: boundedTitle,
        );
        final custom = ChatThread(
          threadId: 'creation-list-custom',
          scene: ChatScene.feedAi,
          title: boundedTitle,
          titleMode: ChatThreadTitleMode.custom,
        );
        final controller = ChatController(
          api: _FakeChatApi(threads: <ChatThread>[automatic, custom]),
          scene: ChatScene.feedAi,
          userVisibleTextProjector: projectCreationCanvasChatUserPrompt,
        );

        await controller.loadThreads(refresh: true, selectLatest: false);

        final byId = <String, ChatThread>{
          for (final thread in controller.state.threads)
            thread.threadId: thread,
        };
        expect(byId[automatic.threadId]?.displayTitle, prompt);
        expect(byId[custom.threadId]?.displayTitle, boundedTitle);
      },
    );

    test('projects a raw local-draft conversation cache on restart', () async {
      final database = AppDatabase();
      final repository = ChatThreadAliasRepository(
        dao: UserMetadataDao(database),
        preferencesDao: AppPreferencesDao(database),
        userScope: 'creation-local-draft-cache-user',
      );
      final snapshot = ChatLocalDraftSnapshot.create(
        kind: 'creation_canvas',
        content: '旧缓存中的本地正文不能重新出现在聊天气泡。',
        revision: 'canvas-revision-3',
      )!;
      const prompt = '继续讨论标题';
      final rawUserText =
          '$creationCanvasChatScopeInstruction\n\n$prompt\n\n'
          '${snapshot.toAgentTextPart()}';
      final thread = ChatThread(
        threadId: 'creation-cached-thread',
        scene: ChatScene.feedAi,
        title: '新会话',
        firstUserMessageText: rawUserText,
      );
      repository.saveConversationCache(
        scene: ChatScene.feedAi,
        purpose: ChatConversationPurpose.general,
        threads: <ChatThread>[thread],
        messagesByThread: <String, List<ChatMessage>>{
          thread.threadId: <ChatMessage>[
            _message(
              id: 'creation-cached-user',
              threadId: thread.threadId,
              role: ChatMessageRole.user,
              text: rawUserText,
            ),
          ],
        },
      );
      final controller = ChatController(
        api: _FakeChatApi(),
        scene: ChatScene.feedAi,
        aliasRepository: repository,
        userVisibleTextProjector: projectCreationCanvasChatUserPrompt,
      );
      await controller.loadThreads();

      expect(controller.state.activeThreadId, thread.threadId);
      expect(controller.state.messages.single.visibleText, prompt);
      expect(controller.state.threads.single.displayTitle, prompt);

      final ordinaryController = ChatController(
        api: _FakeChatApi(),
        scene: ChatScene.feedAi,
        aliasRepository: repository,
      );
      await ordinaryController.loadThreads();
      expect(ordinaryController.state.messages.single.visibleText, rawUserText);
      expect(
        ordinaryController.state.threads.single.displayTitle,
        normalizeChatThreadFirstMessage(rawUserText),
      );
    });

    test(
      'shows the first user turn while thread creation is still pending',
      () async {
        final createThreadCompleter = Completer<ApiResult<ChatThread>>();
        final api = _FakeChatApi(
          createThreadCompleter: createThreadCompleter,
          sentMutation: ChatTextMutation(
            message: _message(
              id: 'user-first-visible',
              threadId: 'created-visible',
              role: ChatMessageRole.user,
              text: '首条消息立即显示',
            ),
          ),
        );
        final controller = ChatController(api: api, scene: ChatScene.feedAi);

        final submission = controller.sendText('首条消息立即显示');
        await Future<void>.delayed(Duration.zero);

        expect(controller.state.isSending, isTrue);
        expect(controller.state.activeThreadId, isNull);
        expect(controller.state.messages, hasLength(1));
        final provisional = controller.state.messages.single;
        expect(provisional.visibleText, '首条消息立即显示');
        expect(provisional.localDelivery, ChatLocalDeliveryState.pending);
        expect(api.sentContents, isEmpty);

        createThreadCompleter.complete(
          _success(_thread('created-visible'), SubmissionKeyStore.empty),
        );

        expect(await submission, isTrue);
        expect(controller.state.activeThreadId, 'created-visible');
        expect(
          controller.state.messages.single.messageId,
          'user-first-visible',
        );
        expect(controller.state.messages.single.threadId, 'created-visible');
        expect(controller.state.messages.single.visibleText, '首条消息立即显示');
      },
    );

    test(
      'persists source asset after its page closes during first thread creation',
      () async {
        final database = AppDatabase();
        final aliases = ChatThreadAliasRepository(
          dao: UserMetadataDao(database),
          preferencesDao: AppPreferencesDao(database),
          userScope: 'detached-first-thread-asset-user',
        );
        final createThreadCompleter = Completer<ApiResult<ChatThread>>();
        final api = _FakeChatApi(
          createThreadCompleter: createThreadCompleter,
          sentMutation: ChatTextMutation(
            message: _message(
              id: 'detached-source-user',
              threadId: 'detached-source-thread',
              role: ChatMessageRole.user,
              text: '关闭页面后仍应绑定来源笔记',
            ),
          ),
        );
        final controller = ChatController(
          api: api,
          scene: ChatScene.feedAi,
          aliasRepository: aliases,
        );

        final submission = controller.sendText(
          '关闭页面后仍应绑定来源笔记',
          conversationAssetId: 'detached-source-note',
        );
        await Future<void>.delayed(Duration.zero);
        controller.dispose();

        createThreadCompleter.complete(
          _success(_thread('detached-source-thread'), SubmissionKeyStore.empty),
        );

        expect(await submission, isTrue);
        expect(api.sentThreadIds, <String>['detached-source-thread']);
        expect(
          aliases.threadAssetReferenceFor(
            scene: ChatScene.feedAi,
            threadId: 'detached-source-thread',
          ),
          'detached-source-note',
        );
      },
    );

    test(
      'coalesces the same first asset admission across route controllers',
      () async {
        final database = AppDatabase();
        final aliases = ChatThreadAliasRepository(
          dao: UserMetadataDao(database),
          preferencesDao: AppPreferencesDao(database),
          userScope: 'coalesced-first-admission-user',
        );
        final coordinator = ChatConversationAdmissionCoordinator(
          userScope: 'coalesced-first-admission-user',
        );
        final createCompleter = Completer<ApiResult<ChatThread>>();
        final sendCompleter = Completer<ApiResult<ChatTextMutation>>();
        final api = _FakeChatApi(
          createThreadCompleter: createCompleter,
          textMutationCompleters: <Completer<ApiResult<ChatTextMutation>>>[
            sendCompleter,
          ],
        );
        ChatController controller() => ChatController(
          api: api,
          scene: ChatScene.feedAi,
          aliasRepository: aliases,
          admissionCoordinator: coordinator,
        );
        final first = controller();
        final replacement = controller();
        final conflicting = controller();
        addTearDown(replacement.dispose);
        addTearDown(conflicting.dispose);

        final firstSend = first.sendText(
          '整理这篇笔记',
          conversationAssetId: 'coalesced-note-1',
        );
        await Future<void>.delayed(Duration.zero);
        expect(api.createCalls, 1);
        first.dispose();

        final replacementSend = replacement.sendText(
          '整理这篇笔记',
          conversationAssetId: 'coalesced-note-1',
        );
        expect(
          await conflicting.sendText(
            '改成另一项任务',
            conversationAssetId: 'coalesced-note-1',
          ),
          isFalse,
        );
        expect(
          conflicting.state.lastErrorCode,
          'CHAT_CONVERSATION_ASSET_ADMISSION_CONFLICT',
        );
        expect(conflicting.state.messages, isEmpty);
        expect(api.createCalls, 1);

        createCompleter.complete(
          _success(_thread('coalesced-thread-1'), SubmissionKeyStore.empty),
        );
        await Future<void>.delayed(Duration.zero);
        expect(api.sentContents, <String>['整理这篇笔记']);
        sendCompleter.complete(
          _success(
            ChatTextMutation(
              message: _message(
                id: 'coalesced-user-1',
                threadId: 'coalesced-thread-1',
                role: ChatMessageRole.user,
                text: '整理这篇笔记',
              ),
            ),
            SubmissionKeyStore.empty,
          ),
        );

        expect(await firstSend, isTrue);
        expect(await replacementSend, isTrue);
        expect(api.createCalls, 1);
        expect(api.sentContents, hasLength(1));
        expect(replacement.state.activeThreadId, 'coalesced-thread-1');
        expect(replacement.state.messages.single.messageId, 'coalesced-user-1');
        expect(
          aliases.threadAssetReferenceFor(
            scene: ChatScene.feedAi,
            threadId: 'coalesced-thread-1',
          ),
          'coalesced-note-1',
        );
        expect(
          coordinator.snapshotFor(
            scene: ChatScene.feedAi,
            purpose: ChatConversationPurpose.general,
            conversationAssetId: 'coalesced-note-1',
          ),
          isNull,
        );
      },
    );

    test(
      'serializes one existing Thread across text and voice route controllers',
      () async {
        const threadId = 'shared-admission-thread-1';
        const agentRunId = 'shared-admission-run-1';
        final coordinator = ChatConversationAdmissionCoordinator(
          userScope: 'shared-admission-user',
        );
        final tracker = _AdmissionRunTracker();
        final sendCompleter = Completer<ApiResult<ChatTextMutation>>();
        final thread = _thread(threadId);
        final api = _FakeChatApi(
          threads: <ChatThread>[thread],
          details: <String, ChatThreadDetail>{
            threadId: ChatThreadDetail(
              thread: thread,
              messages: const <ChatMessage>[],
            ),
          },
          textMutationCompleters: <Completer<ApiResult<ChatTextMutation>>>[
            sendCompleter,
          ],
        );
        ChatController controller() => ChatController(
          api: api,
          scene: ChatScene.feedAi,
          admissionCoordinator: coordinator,
          runTracker: tracker,
        );
        final first = controller();
        final competingText = controller();
        final competingVoice = controller();
        addTearDown(first.dispose);
        addTearDown(competingText.dispose);
        addTearDown(competingVoice.dispose);
        for (final candidate in <ChatController>[
          first,
          competingText,
          competingVoice,
        ]) {
          await candidate.loadThreads(selectLatest: false);
          await candidate.selectThread(threadId, forceRemote: true);
        }

        final firstSubmission = first.sendText('第一轮正在提交');
        while (api.sentContents.isEmpty) {
          await Future<void>.delayed(Duration.zero);
        }

        expect(await competingText.sendText('不能并发提交第二轮'), isFalse);
        expect(
          competingText.state.lastErrorCode,
          'CHAT_THREAD_TURN_IN_PROGRESS',
        );
        expect(competingText.state.messages, isEmpty);
        expect(
          await competingVoice.sendVoiceResource(
            resource: _voiceResource(),
            durationSeconds: 6,
          ),
          isFalse,
        );
        expect(
          competingVoice.state.lastErrorCode,
          'CHAT_THREAD_TURN_IN_PROGRESS',
        );
        expect(api.voiceThreadIds, isEmpty);

        sendCompleter.complete(
          _success(
            ChatTextMutation(
              message: _message(
                id: 'shared-admission-user-1',
                threadId: threadId,
                role: ChatMessageRole.user,
                text: '第一轮正在提交',
              ),
              nextAction: const ChatNextAction(
                type: ChatNextActionType.pollAgentRun,
                agentRunId: agentRunId,
              ),
            ),
            SubmissionKeyStore.empty,
          ),
        );
        expect(await firstSubmission, isTrue);
        expect(tracker.isThreadPending(threadId), isTrue);

        expect(await competingText.sendText('Run 完成前仍不能提交'), isFalse);
        expect(
          competingText.state.lastErrorCode,
          'CHAT_THREAD_TURN_IN_PROGRESS',
        );
        expect(api.sentContents, <String>['第一轮正在提交']);
      },
    );

    test(
      'terminal recovery failure blocks text and voice without another POST',
      () async {
        const threadId = 'terminal-recovery-thread';
        final tracker = _AdmissionRunTracker(recoverySucceeds: false)
          ..terminalThreads.add(threadId);
        final thread = _thread(threadId);
        final api = _FakeChatApi(
          threads: [thread],
          details: {
            threadId: ChatThreadDetail(thread: thread, messages: const []),
          },
        );
        final coordinator = ChatConversationAdmissionCoordinator(
          userScope: 'recovery-account',
        );
        final text = ChatController(
          api: api,
          scene: ChatScene.feedAi,
          runTracker: tracker,
          admissionCoordinator: coordinator,
        );
        final voice = ChatController(
          api: api,
          scene: ChatScene.feedAi,
          runTracker: tracker,
          admissionCoordinator: coordinator,
        );
        addTearDown(text.dispose);
        addTearDown(voice.dispose);
        for (final controller in [text, voice]) {
          await controller.loadThreads(selectLatest: false);
          await controller.selectThread(threadId, forceRemote: true);
        }
        expect(await text.sendText('下一轮保留的输入'), isFalse);
        expect(text.state.lastErrorCode, 'CHAT_THREAD_RESULT_SYNC_FAILED');
        expect(text.state.messages, isEmpty);
        expect(
          await voice.sendVoiceResource(
            resource: _voiceResource(),
            durationSeconds: 6,
          ),
          isFalse,
        );
        expect(voice.state.lastErrorCode, 'CHAT_THREAD_RESULT_SYNC_FAILED');
        expect(api.sentContents, isEmpty);
        expect(api.voiceThreadIds, isEmpty);
        expect(tracker.recoveryCalls, [threadId, threadId]);
        expect(tracker.needsThreadReconciliation(threadId), isTrue);
      },
    );

    test(
      'terminal recovery keeps the admission lease until exactly one new send',
      () async {
        const threadId = 'terminal-recovery-thread';
        final gate = Completer<void>();
        final tracker = _AdmissionRunTracker(recoveryGate: gate.future)
          ..terminalThreads.add(threadId);
        final thread = _thread(threadId);
        final api = _FakeChatApi(
          threads: [thread],
          details: {
            threadId: ChatThreadDetail(thread: thread, messages: const []),
          },
          sentMutation: ChatTextMutation(
            message: _message(
              id: 'next-turn-user',
              threadId: threadId,
              role: ChatMessageRole.user,
              text: '恢复后只发送一次',
            ),
            nextAction: const ChatNextAction.none(),
          ),
        );
        final coordinator = ChatConversationAdmissionCoordinator(
          userScope: 'recovery-account',
        );
        final first = ChatController(
          api: api,
          scene: ChatScene.feedAi,
          runTracker: tracker,
          admissionCoordinator: coordinator,
        );
        final competing = ChatController(
          api: api,
          scene: ChatScene.feedAi,
          runTracker: tracker,
          admissionCoordinator: coordinator,
        );
        addTearDown(first.dispose);
        addTearDown(competing.dispose);
        for (final controller in [first, competing]) {
          await controller.loadThreads(selectLatest: false);
          await controller.selectThread(threadId, forceRemote: true);
        }
        final sending = first.sendText('恢复后只发送一次');
        while (tracker.recoveryCalls.isEmpty) {
          await Future<void>.delayed(Duration.zero);
        }
        expect(api.sentContents, isEmpty);
        expect(await competing.sendText('不应重复提交'), isFalse);
        expect(competing.state.lastErrorCode, 'CHAT_THREAD_TURN_IN_PROGRESS');
        expect(tracker.recoveryCalls, [threadId]);
        gate.complete();
        expect(await sending, isTrue);
        expect(api.sentContents, ['恢复后只发送一次']);
        expect(tracker.needsThreadReconciliation(threadId), isFalse);
      },
    );

    test(
      'reattaches a failed detached admission as an in-place retry',
      () async {
        final database = AppDatabase();
        final aliases = ChatThreadAliasRepository(
          dao: UserMetadataDao(database),
          preferencesDao: AppPreferencesDao(database),
          userScope: 'failed-first-admission-user',
        );
        final coordinator = ChatConversationAdmissionCoordinator(
          userScope: 'failed-first-admission-user',
        );
        final firstSendCompleter = Completer<ApiResult<ChatTextMutation>>();
        final retryCompleter = Completer<ApiResult<ChatTextMutation>>();
        final api = _FakeChatApi(
          createdThread: _thread('failed-admission-thread-1'),
          textMutationCompleters: <Completer<ApiResult<ChatTextMutation>>>[
            firstSendCompleter,
            retryCompleter,
          ],
        );
        ChatController controller() => ChatController(
          api: api,
          scene: ChatScene.feedAi,
          aliasRepository: aliases,
          admissionCoordinator: coordinator,
        );
        final owner = controller();
        final submission = owner.sendText(
          '失败后继续发送',
          conversationAssetId: 'failed-admission-note-1',
        );
        while (api.sentContents.isEmpty) {
          await Future<void>.delayed(Duration.zero);
        }
        owner.dispose();

        final replacement = controller();
        addTearDown(replacement.dispose);
        final attachment = replacement.attachConversationAssetAdmission(
          'failed-admission-note-1',
        );
        firstSendCompleter.complete(
          ApiResult<ChatTextMutation>.failure(
            error: const AppFailure(
              code: 'NETWORK_REQUEST_FAILED',
              category: AppFailureCategory.network,
              message: 'request failed',
              userMessageKey: 'error.network',
              isRetryable: true,
              recoveryActions: <String>['retry'],
            ),
            idempotencyStore: SubmissionKeyStore.empty,
          ),
        );

        expect(await submission, isFalse);
        expect(await attachment, isTrue);
        expect(replacement.state.status, ChatControllerStatus.failed);
        final failed = replacement.state.messages.single;
        expect(failed.localDelivery, ChatLocalDeliveryState.failed);
        expect(replacement.canRetryFailedTextMessage(failed.messageId), isTrue);

        final retry = replacement.retryFailedTextMessage(failed.messageId);
        await Future<void>.delayed(Duration.zero);
        expect(api.createCalls, 1);
        expect(api.sentContents, <String>['失败后继续发送', '失败后继续发送']);
        retryCompleter.complete(
          _success(
            ChatTextMutation(
              message: _message(
                id: 'retry-server-user-1',
                threadId: 'failed-admission-thread-1',
                role: ChatMessageRole.user,
                text: '失败后继续发送',
              ),
            ),
            SubmissionKeyStore.empty,
          ),
        );

        expect(await retry, isTrue);
        expect(replacement.state.messages.single.messageId, failed.messageId);
        expect(
          replacement.state.messages.single.localDelivery,
          ChatLocalDeliveryState.server,
        );
        expect(api.createCalls, 1);
      },
    );

    test('does not start local Run projection after owner disposal', () async {
      final database = AppDatabase();
      final aliases = ChatThreadAliasRepository(
        dao: UserMetadataDao(database),
        preferencesDao: AppPreferencesDao(database),
        userScope: 'disposed-admission-projection-user',
      );
      final coordinator = ChatConversationAdmissionCoordinator(
        userScope: 'disposed-admission-projection-user',
      );
      final sendCompleter = Completer<ApiResult<ChatTextMutation>>();
      final tracker = _SseDraftChatRunTracker();
      final api = _FakeChatApi(
        createdThread: _thread('disposed-admission-thread-1'),
        textMutationCompleters: <Completer<ApiResult<ChatTextMutation>>>[
          sendCompleter,
        ],
      );
      final controller = ChatController(
        api: api,
        scene: ChatScene.feedAi,
        aliasRepository: aliases,
        admissionCoordinator: coordinator,
        runTracker: tracker,
      );
      final submission = controller.sendText(
        '页面关闭后继续处理',
        conversationAssetId: 'disposed-admission-note-1',
      );
      while (api.sentContents.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      tracker.publish(
        agentRunId: 'disposed-admission-run-1',
        threadId: 'disposed-admission-thread-1',
        deltaText: '账号级草稿',
      );
      controller.dispose();
      sendCompleter.complete(
        _success(
          ChatTextMutation(
            message: _message(
              id: 'disposed-admission-user-1',
              threadId: 'disposed-admission-thread-1',
              role: ChatMessageRole.user,
            ),
            nextAction: const ChatNextAction(
              type: ChatNextActionType.pollAgentRun,
              agentRunId: 'disposed-admission-run-1',
            ),
          ),
          SubmissionKeyStore.empty,
        ),
      );

      expect(await submission, isTrue);
      expect(
        tracker.activityFor(
          threadId: 'disposed-admission-thread-1',
          agentRunId: 'disposed-admission-run-1',
        ),
        isNotNull,
      );
    });

    test(
      'keeps the first user turn visible when thread creation fails',
      () async {
        final controller = ChatController(
          api: _FakeChatApi(),
          scene: ChatScene.feedAi,
        );

        expect(await controller.sendText('创建失败也不能消失'), isFalse);

        expect(controller.state.activeThreadId, isNull);
        expect(controller.state.lastErrorCode, 'CHAT_CREATE_THREAD_FAILED');
        expect(controller.state.messages, hasLength(1));
        expect(controller.state.messages.single.visibleText, '创建失败也不能消失');
        expect(
          controller.state.messages.single.localDelivery,
          ChatLocalDeliveryState.failed,
        );
      },
    );

    test(
      'records send/reply times and names a new thread from first text',
      () async {
        final moments = <DateTime>[
          DateTime.utc(2026, 8, 1, 8),
          DateTime.utc(2026, 8, 1, 8, 0, 3),
        ];
        final api = _FakeChatApi(
          createdThread: _thread('created-time'),
          sentMutation: ChatTextMutation(
            message: _message(
              id: 'user-time',
              threadId: 'created-time',
              role: ChatMessageRole.user,
            ),
            assistantMessage: _message(
              id: 'assistant-time',
              threadId: 'created-time',
              role: ChatMessageRole.assistant,
              text: '服务端回答',
            ),
          ),
        );
        final controller = ChatController(
          api: api,
          scene: ChatScene.feedAi,
          now: () => moments.removeAt(0),
        );

        expect(await controller.sendText('   如何复盘这次沟通   '), isTrue);

        expect(
          controller.state.messages[0].createdAt,
          DateTime.utc(2026, 8, 1, 8),
        );
        expect(
          controller.state.messages[1].createdAt,
          DateTime.utc(2026, 8, 1, 8, 0, 3),
        );
        expect(controller.state.threads.single.displayTitle, '如何复盘这次沟通');
      },
    );

    test(
      'polls accepted text task until the server assistant arrives',
      () async {
        final api = _FakeChatApi(
          createdThread: _thread('created-poll'),
          sentMutation: ChatTextMutation(
            message: _message(
              id: 'user-poll',
              threadId: 'created-poll',
              role: ChatMessageRole.user,
            ),
            nextAction: const ChatNextAction(
              type: ChatNextActionType.pollTask,
              taskId: 'task-poll',
            ),
          ),
          details: <String, ChatThreadDetail>{
            'created-poll': ChatThreadDetail(
              thread: _thread('created-poll'),
              messages: <ChatMessage>[
                _message(
                  id: 'user-poll',
                  threadId: 'created-poll',
                  role: ChatMessageRole.user,
                  text: '请分析这段内容',
                ),
                _message(
                  id: 'assistant-poll',
                  threadId: 'created-poll',
                  role: ChatMessageRole.assistant,
                  text: '服务端异步回复',
                ),
              ],
            ),
          },
        );
        final controller = ChatController(
          api: api,
          scene: ChatScene.feedAi,
          taskPollInterval: Duration.zero,
          taskPollAttempts: 1,
        );

        expect(await controller.sendText('请分析这段内容'), isTrue);

        expect(api.detailCalls, <String>['created-poll']);
        expect(controller.state.status, ChatControllerStatus.ready);
        expect(controller.state.nextAction.type, ChatNextActionType.none);
        expect(controller.state.messages.last.visibleText, '服务端异步回复');
        expect(controller.state.messages.last.role, ChatMessageRole.assistant);
      },
    );

    test(
      'verifies a canonical agent run before reading its exact durable reply',
      () async {
        const threadId = 'created-agent-run';
        final api = _FakeChatApi(
          createdThread: _thread(threadId),
          sentMutation: ChatTextMutation(
            message: _message(
              id: 'user-agent-run',
              threadId: threadId,
              role: ChatMessageRole.user,
            ),
            assistantMessage: _message(
              id: 'unverified-projection',
              threadId: threadId,
              role: ChatMessageRole.assistant,
              text: '不能直接采用的响应投影',
            ),
            nextAction: const ChatNextAction(
              type: ChatNextActionType.pollAgentRun,
              agentRunId: 'agent-run-1',
            ),
          ),
          details: <String, ChatThreadDetail>{
            threadId: ChatThreadDetail(
              thread: _thread(threadId),
              messages: <ChatMessage>[
                _message(
                  id: 'user-agent-run',
                  threadId: threadId,
                  role: ChatMessageRole.user,
                  text: '标准异步对话',
                ),
                _message(
                  id: 'assistant-agent-run',
                  threadId: threadId,
                  role: ChatMessageRole.assistant,
                  text: '标准异步回复',
                ),
              ],
            ),
          },
        );
        final runs = _FakeAssistantRuntimeFixture(<ApiResult<AgentRunSnapshot>>[
          _runSuccess(_agentRun(status: 'running', threadId: threadId)),
          _runSuccess(
            _agentRun(
              status: 'succeeded',
              threadId: threadId,
              assistantMessageId: 'assistant-agent-run',
              completionMode: 'normal',
            ),
          ),
        ]);
        final controller = ChatController(
          api: api,
          assistantRuntime: legacyAssistantRuntime(runs),
          scene: ChatScene.feedAi,
          taskPollInterval: Duration.zero,
          taskPollAttempts: 2,
        );

        expect(await controller.sendText('标准异步对话'), isTrue);

        expect(runs.calls, <String>['agent-run-1', 'agent-run-1']);
        expect(api.detailCalls, <String>[threadId]);
        expect(controller.state.status, ChatControllerStatus.ready);
        expect(controller.state.lastErrorCode, isNull);
        expect(controller.state.nextAction.type, ChatNextActionType.none);
        expect(controller.state.messages.last.messageId, 'assistant-agent-run');
        expect(
          controller.state.messages.map((message) => message.messageId),
          isNot(contains('unverified-projection')),
        );
      },
    );

    test(
      'preserves fallback draft replacement and whitespace before readback',
      () async {
        const threadId = 'streaming-thread-1';
        const agentRunId = 'streaming-agent-run-1';
        final api = _ProgressChatApi(
          createdThread: _thread(threadId),
          details: <String, ChatThreadDetail>{},
          sentMutation: ChatTextMutation(
            message: _message(
              id: 'streaming-user-1',
              threadId: threadId,
              role: ChatMessageRole.user,
            ),
            nextAction: const ChatNextAction(
              type: ChatNextActionType.pollAgentRun,
              agentRunId: agentRunId,
            ),
          ),
          progressPages: <AssistantProgressPage>[
            const AssistantProgressPage(
              conversationId: threadId,
              nextSequence: 3,
              events: <AssistantProgressEvent>[
                AssistantProgressEvent(
                  sequence: 1,
                  type: AssistantProgressEventType.draftDelta,
                  runHandle: 'other-agent-run',
                  deltaText: '不应显示',
                ),
                AssistantProgressEvent(
                  sequence: 2,
                  type: AssistantProgressEventType.draftDelta,
                  runHandle: agentRunId,
                  deltaText: '第一段',
                ),
                AssistantProgressEvent(
                  sequence: 3,
                  type: AssistantProgressEventType.draftDelta,
                  runHandle: agentRunId,
                  deltaText: '\n  已修订 ',
                  replace: true,
                ),
              ],
            ),
          ],
        );
        final controller = ChatController(
          api: api,
          assistantProgress: api,
          assistantRuntime: legacyAssistantRuntime(
            _StableAssistantRuntimeFixture(
              _runSuccess(
                _agentRun(
                  agentRunId: agentRunId,
                  threadId: threadId,
                  status: 'running',
                ),
              ),
            ),
          ),
          runTracker: const _DetachingChatRunTracker(),
          scene: ChatScene.feedAi,
          taskPollInterval: const Duration(days: 1),
        );
        addTearDown(controller.dispose);

        expect(await controller.sendText('请分段回复'), isTrue);
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(const Duration(milliseconds: 220));

        final streamed = controller.state.messages.singleWhere(
          (message) => message.messageId == 'stream-$agentRunId',
        );
        expect(streamed.visibleText, '\n  已修订 ');
        expect(streamed.status, 'streaming');
        expect(api.progressAfterSequences, <int>[0]);

        api.details[threadId] = ChatThreadDetail(
          thread: _thread(threadId),
          messages: <ChatMessage>[
            _message(
              id: 'streaming-user-1',
              threadId: threadId,
              role: ChatMessageRole.user,
              text: '请分段回复',
            ),
            _message(
              id: 'streaming-assistant-1',
              threadId: threadId,
              role: ChatMessageRole.assistant,
              text: '服务端持久化的完整回复。',
              agentRunId: agentRunId,
            ),
          ],
        );
        await controller.selectThread(threadId, forceRemote: true);

        final assistants = controller.state.messages
            .where((message) => message.role == ChatMessageRole.assistant)
            .toList(growable: false);
        expect(assistants, hasLength(1));
        expect(assistants.single.messageId, 'streaming-assistant-1');
        expect(assistants.single.visibleText, '服务端持久化的完整回复。');
      },
    );

    test('flushes a queued Agent draft before controller disposal', () async {
      const threadId = 'dispose-streaming-thread-1';
      const agentRunId = 'dispose-streaming-agent-run-1';
      final tracker = _SseDraftChatRunTracker();
      final controller = ChatController(
        api: _FakeChatApi(
          createdThread: _thread(threadId),
          sentMutation: ChatTextMutation(
            message: _message(
              id: 'dispose-streaming-user-1',
              threadId: threadId,
              role: ChatMessageRole.user,
            ),
            nextAction: const ChatNextAction(
              type: ChatNextActionType.pollAgentRun,
              agentRunId: agentRunId,
            ),
          ),
        ),
        assistantRuntime: legacyAssistantRuntime(
          _StableAssistantRuntimeFixture(
            _runSuccess(
              _agentRun(
                agentRunId: agentRunId,
                threadId: threadId,
                status: 'running',
              ),
            ),
          ),
        ),
        runTracker: tracker,
        scene: ChatScene.feedAi,
        taskPollInterval: const Duration(days: 1),
      );
      try {
        expect(await controller.sendText('请保留正在展示的草稿'), isTrue);
        tracker.publish(
          agentRunId: agentRunId,
          threadId: threadId,
          deltaText: '尚未逐字展示的完整草稿',
          replace: true,
        );

        controller.dispose();

        expect(
          controller.state.messages
              .singleWhere(
                (message) => message.messageId == 'stream-$agentRunId',
              )
              .visibleText,
          '尚未逐字展示的完整草稿',
        );
      } finally {
        tracker.dispose();
      }
    });

    test(
      'renders matching Agent Run SSE draft deltas without thread polling',
      () async {
        const threadId = 'sse-streaming-thread-1';
        const agentRunId = 'sse-streaming-agent-run-1';
        late final _SseDraftChatRunTracker tracker;
        tracker = _SseDraftChatRunTracker(
          onTrack: (trackedRunId, trackedThreadId) => tracker.publish(
            agentRunId: trackedRunId,
            threadId: trackedThreadId,
            deltaText: '第一段',
            replace: true,
          ),
        );
        final api = _FakeChatApi(
          createdThread: _thread(threadId),
          sentMutation: ChatTextMutation(
            message: _message(
              id: 'sse-streaming-user-1',
              threadId: threadId,
              role: ChatMessageRole.user,
            ),
            nextAction: const ChatNextAction(
              type: ChatNextActionType.pollAgentRun,
              agentRunId: agentRunId,
            ),
          ),
        );
        final controller = ChatController(
          api: api,
          assistantRuntime: legacyAssistantRuntime(
            _StableAssistantRuntimeFixture(
              _runSuccess(
                _agentRun(
                  agentRunId: agentRunId,
                  threadId: threadId,
                  status: 'running',
                ),
              ),
            ),
          ),
          runTracker: tracker,
          scene: ChatScene.feedAi,
          taskPollInterval: const Duration(days: 1),
        );
        addTearDown(controller.dispose);
        addTearDown(tracker.dispose);

        expect(await controller.sendText('请通过 SSE 分段回复'), isTrue);
        await Future<void>.delayed(const Duration(milliseconds: 180));
        var controllerNotifications = 0;
        var draftNotifications = 0;
        final answerDraftSources = <ChatAssistantAnswerDraftSource>[];
        controller.addListener(() => controllerNotifications += 1);
        controller.agentProgressDrafts.addListener(
          () => draftNotifications += 1,
        );
        controller.assistantAnswerDrafts.addListener(() {
          final draft =
              controller.assistantAnswerDrafts.value['stream-$agentRunId'];
          if (draft != null) answerDraftSources.add(draft.source);
        });
        tracker.publish(
          agentRunId: 'other-agent-run',
          threadId: threadId,
          deltaText: '不应显示',
        );
        tracker.publish(
          agentRunId: agentRunId,
          threadId: threadId,
          deltaText: '第二段',
        );
        await Future<void>.delayed(const Duration(milliseconds: 220));

        final streamed = controller.state.messages.singleWhere(
          (message) => message.messageId == 'stream-$agentRunId',
        );
        expect(streamed.visibleText, '第一段第二段');
        expect(streamed.status, 'streaming');
        expect(draftNotifications, greaterThan(1));
        expect(
          controller
              .assistantAnswerDrafts
              .value['stream-$agentRunId']
              ?.targetText,
          '第一段第二段',
        );
        expect(answerDraftSources, isNotEmpty);
        expect(
          answerDraftSources,
          everyElement(ChatAssistantAnswerDraftSource.transportDelta),
        );
        expect(controllerNotifications, 0);
        expect(api.detailCalls, isEmpty);
      },
    );

    test(
      'thread events and SSE recover each other without duplicate chunks',
      () async {
        const threadId = 'dual-transport-thread-1';
        const agentRunId = 'dual-transport-agent-run-1';
        final tracker = _SseDraftChatRunTracker();
        final api = _ProgressChatApi(
          createdThread: _thread(threadId),
          sentMutation: ChatTextMutation(
            message: _message(
              id: 'dual-transport-user-1',
              threadId: threadId,
              role: ChatMessageRole.user,
            ),
            nextAction: const ChatNextAction(
              type: ChatNextActionType.pollAgentRun,
              agentRunId: agentRunId,
            ),
          ),
          progressPages: <AssistantProgressPage>[
            const AssistantProgressPage(
              conversationId: threadId,
              events: <AssistantProgressEvent>[
                AssistantProgressEvent(
                  sequence: 1,
                  type: AssistantProgressEventType.draftDelta,
                  runHandle: agentRunId,
                  deltaText: '第一段',
                  replace: true,
                ),
                AssistantProgressEvent(
                  sequence: 2,
                  type: AssistantProgressEventType.draftDelta,
                  runHandle: agentRunId,
                  deltaText: '第二段',
                ),
              ],
              nextSequence: 2,
            ),
            const AssistantProgressPage(
              conversationId: threadId,
              events: <AssistantProgressEvent>[
                AssistantProgressEvent(
                  sequence: 3,
                  type: AssistantProgressEventType.draftDelta,
                  runHandle: agentRunId,
                  deltaText: '第三段',
                ),
              ],
              nextSequence: 3,
            ),
          ],
        );
        final controller = ChatController(
          api: api,
          assistantProgress: api,
          assistantRuntime: legacyAssistantRuntime(
            _StableAssistantRuntimeFixture(
              _runSuccess(
                _agentRun(
                  agentRunId: agentRunId,
                  threadId: threadId,
                  status: 'running',
                ),
              ),
            ),
          ),
          runTracker: tracker,
          scene: ChatScene.feedAi,
          coalescedStreamingUi: false,
          taskPollInterval: const Duration(days: 1),
        );
        addTearDown(controller.dispose);
        addTearDown(tracker.dispose);

        expect(await controller.sendText('验证双通道恢复'), isTrue);
        await Future<void>.delayed(const Duration(milliseconds: 850));
        expect(
          controller.state.messages
              .singleWhere(
                (message) => message.messageId == 'stream-$agentRunId',
              )
              .visibleText,
          '第一段第二段',
        );

        tracker.publish(
          agentRunId: agentRunId,
          threadId: threadId,
          deltaText: '第一段第二段',
        );
        await Future<void>.delayed(Duration.zero);
        expect(
          controller.state.messages
              .singleWhere(
                (message) => message.messageId == 'stream-$agentRunId',
              )
              .visibleText,
          '第一段第二段',
        );

        await Future<void>.delayed(const Duration(milliseconds: 850));
        expect(api.progressAfterSequences, <int>[0, 2]);
        expect(
          controller.state.messages
              .singleWhere(
                (message) => message.messageId == 'stream-$agentRunId',
              )
              .visibleText,
          '第一段第二段第三段',
        );
      },
    );

    test('debounces draft cache writes and supports an explicit flush', () async {
      const threadId = 'sse-cache-thread-1';
      const agentRunId = 'sse-cache-agent-run-1';
      const userScope = 'sse-cache-user-1';
      final database = AppDatabase();
      final preferences = AppPreferencesDao(database);
      final repository = ChatThreadAliasRepository(
        dao: UserMetadataDao(database),
        preferencesDao: preferences,
        userScope: userScope,
      );
      final cacheKey =
          'chat.cache.v1.'
          '${sha256.convert(utf8.encode(userScope)).toString().substring(0, 24)}';
      final tracker = _SseDraftChatRunTracker();
      final api = _FakeChatApi(
        createdThread: _thread(threadId),
        sentMutation: ChatTextMutation(
          message: _message(
            id: 'sse-cache-user-message-1',
            threadId: threadId,
            role: ChatMessageRole.user,
          ),
          nextAction: const ChatNextAction(
            type: ChatNextActionType.pollAgentRun,
            agentRunId: agentRunId,
          ),
        ),
      );
      final controller = ChatController(
        api: api,
        assistantRuntime: legacyAssistantRuntime(
          _StableAssistantRuntimeFixture(
            _runSuccess(
              _agentRun(
                agentRunId: agentRunId,
                threadId: threadId,
                status: 'running',
              ),
            ),
          ),
        ),
        runTracker: tracker,
        scene: ChatScene.feedAi,
        aliasRepository: repository,
        taskPollInterval: const Duration(days: 1),
      );
      addTearDown(controller.dispose);
      addTearDown(tracker.dispose);

      expect(await controller.sendText('请分段回答'), isTrue);
      final acceptedSnapshot = preferences.readValue(cacheKey);
      expect(acceptedSnapshot, isNotNull);
      tracker.publish(
        agentRunId: agentRunId,
        threadId: threadId,
        deltaText: '第一段',
        replace: true,
      );
      tracker.publish(
        agentRunId: agentRunId,
        threadId: threadId,
        deltaText: '第二段',
      );

      expect(preferences.readValue(cacheKey), acceptedSnapshot);

      await Future<void>.delayed(const Duration(milliseconds: 650));
      final debouncedSnapshot = preferences.readValue(cacheKey);
      expect(debouncedSnapshot, isNot(acceptedSnapshot));

      tracker.publish(
        agentRunId: agentRunId,
        threadId: threadId,
        deltaText: '第三段',
      );
      expect(preferences.readValue(cacheKey), debouncedSnapshot);
      controller.flushPendingConversationCache();
      expect(preferences.readValue(cacheKey), isNot(debouncedSnapshot));
    });

    test(
      'rebinds a restored active Run before its next SSE draft delta',
      () async {
        const threadId = 'restored-streaming-thread-1';
        const agentRunId = 'restored-streaming-agent-run-1';
        final tracker = _SseDraftChatRunTracker(
          initialActivities: <ChatRunActivity>[
            ChatRunActivity(
              agentRunId: agentRunId,
              threadId: threadId,
              status: 'running',
              createdAt: DateTime.utc(2026, 8, 31, 12),
            ),
          ],
        );
        final thread = _thread(threadId);
        final controller = ChatController(
          api: _FakeChatApi(
            details: <String, ChatThreadDetail>{
              threadId: ChatThreadDetail(
                thread: thread,
                messages: <ChatMessage>[
                  _message(
                    id: 'restored-streaming-user-1',
                    threadId: threadId,
                    role: ChatMessageRole.user,
                    text: '进程重建前的问题',
                  ),
                ],
              ),
            },
          ),
          scene: ChatScene.feedAi,
          runTracker: tracker,
          coalescedStreamingUi: false,
        );
        addTearDown(controller.dispose);
        addTearDown(tracker.dispose);

        await controller.selectThread(threadId, forceRemote: true);
        tracker.publish(
          agentRunId: agentRunId,
          threadId: threadId,
          deltaText: '恢复后继续到达的分段',
          replace: true,
        );
        await Future<void>.delayed(Duration.zero);

        final streamed = controller.state.messages.singleWhere(
          (message) => message.messageId == 'stream-$agentRunId',
        );
        expect(streamed.visibleText, '恢复后继续到达的分段');
        expect(streamed.status, 'streaming');
      },
    );

    test('reattaches to the account assembled draft exactly once', () async {
      const threadId = 'detached-streaming-thread-1';
      const agentRunId = 'detached-streaming-agent-run-1';
      final tracker = _SseDraftChatRunTracker(
        initialActivities: <ChatRunActivity>[
          ChatRunActivity(
            agentRunId: agentRunId,
            threadId: threadId,
            status: 'running',
            createdAt: DateTime.utc(2026, 9, 2, 8),
          ),
        ],
      );
      tracker.publish(
        agentRunId: agentRunId,
        threadId: threadId,
        deltaText: '离页期间第一段',
        replace: true,
      );
      tracker.publish(
        agentRunId: agentRunId,
        threadId: threadId,
        deltaText: '和第二段',
      );
      final controller = ChatController(
        api: _FakeChatApi(
          details: <String, ChatThreadDetail>{
            threadId: ChatThreadDetail(
              thread: _thread(threadId),
              messages: <ChatMessage>[
                _message(
                  id: 'detached-streaming-user-1',
                  threadId: threadId,
                  role: ChatMessageRole.user,
                  text: '离开页面后继续回答',
                ),
              ],
            ),
          },
        ),
        scene: ChatScene.feedAi,
        runTracker: tracker,
        coalescedStreamingUi: false,
      );
      addTearDown(controller.dispose);
      addTearDown(tracker.dispose);

      await controller.selectThread(threadId, forceRemote: true);

      expect(
        controller.state.messages
            .singleWhere((message) => message.messageId == 'stream-$agentRunId')
            .visibleText,
        '离页期间第一段和第二段',
      );
      tracker.publish(
        agentRunId: agentRunId,
        threadId: threadId,
        deltaText: '以及第三段',
      );
      await Future<void>.delayed(Duration.zero);
      expect(
        controller.state.messages
            .singleWhere((message) => message.messageId == 'stream-$agentRunId')
            .visibleText,
        '离页期间第一段和第二段以及第三段',
      );
    });

    test(
      'thread switch restores a live draft and appends the next SSE once',
      () async {
        const activeThreadId = 'switch-live-thread-1';
        const otherThreadId = 'switch-other-thread-1';
        const agentRunId = 'switch-live-agent-run-1';
        final tracker = _SseDraftChatRunTracker(
          initialActivities: <ChatRunActivity>[
            ChatRunActivity(
              agentRunId: agentRunId,
              threadId: activeThreadId,
              status: 'running',
              createdAt: DateTime.utc(2026, 9, 1, 8),
            ),
          ],
        );
        final controller = ChatController(
          api: _FakeChatApi(
            details: <String, ChatThreadDetail>{
              activeThreadId: ChatThreadDetail(
                thread: _thread(activeThreadId),
                messages: <ChatMessage>[
                  _message(
                    id: 'switch-live-user-1',
                    threadId: activeThreadId,
                    role: ChatMessageRole.user,
                    text: '请继续分段回答',
                  ),
                ],
              ),
              otherThreadId: ChatThreadDetail(
                thread: _thread(otherThreadId),
                messages: <ChatMessage>[
                  _message(
                    id: 'switch-other-user-1',
                    threadId: otherThreadId,
                    role: ChatMessageRole.user,
                    text: '另一条会话',
                  ),
                ],
              ),
            },
          ),
          scene: ChatScene.feedAi,
          runTracker: tracker,
          coalescedStreamingUi: false,
        );
        addTearDown(controller.dispose);
        addTearDown(tracker.dispose);

        await controller.selectThread(activeThreadId, forceRemote: true);
        tracker.publish(
          agentRunId: agentRunId,
          threadId: activeThreadId,
          deltaText: '第一段',
          replace: true,
        );
        await Future<void>.delayed(Duration.zero);

        await controller.selectThread(otherThreadId, forceRemote: true);
        await controller.selectThread(activeThreadId);
        expect(
          controller.state.messages
              .singleWhere(
                (message) => message.messageId == 'stream-$agentRunId',
              )
              .visibleText,
          '第一段',
        );

        tracker.publish(
          agentRunId: agentRunId,
          threadId: activeThreadId,
          deltaText: '第二段',
        );
        await Future<void>.delayed(Duration.zero);

        final drafts = controller.state.messages
            .where((message) => message.messageId == 'stream-$agentRunId')
            .toList(growable: false);
        expect(drafts, hasLength(1));
        expect(drafts.single.visibleText, '第一段第二段');
      },
    );

    test(
      'inactive Thread SSE remains replayable after switching back',
      () async {
        const activeThreadId = 'inactive-sse-active-thread-1';
        const otherThreadId = 'inactive-sse-other-thread-1';
        const activeRunId = 'inactive-sse-active-run-1';
        const otherRunId = 'inactive-sse-other-run-1';
        final tracker = _SseDraftChatRunTracker(
          initialActivities: <ChatRunActivity>[
            ChatRunActivity(
              agentRunId: activeRunId,
              threadId: activeThreadId,
              status: 'running',
              createdAt: DateTime.utc(2026, 9, 1, 8),
            ),
            ChatRunActivity(
              agentRunId: otherRunId,
              threadId: otherThreadId,
              status: 'running',
              createdAt: DateTime.utc(2026, 9, 1, 9),
            ),
          ],
        );
        final controller = ChatController(
          api: _FakeChatApi(
            details: <String, ChatThreadDetail>{
              activeThreadId: ChatThreadDetail(
                thread: _thread(activeThreadId),
                messages: <ChatMessage>[
                  _message(
                    id: 'inactive-sse-active-user-1',
                    threadId: activeThreadId,
                    role: ChatMessageRole.user,
                  ),
                ],
              ),
              otherThreadId: ChatThreadDetail(
                thread: _thread(otherThreadId),
                messages: <ChatMessage>[
                  _message(
                    id: 'inactive-sse-other-user-1',
                    threadId: otherThreadId,
                    role: ChatMessageRole.user,
                  ),
                ],
              ),
            },
          ),
          scene: ChatScene.feedAi,
          runTracker: tracker,
          coalescedStreamingUi: false,
        );
        addTearDown(controller.dispose);
        addTearDown(tracker.dispose);

        await controller.selectThread(activeThreadId, forceRemote: true);
        tracker.publish(
          agentRunId: activeRunId,
          threadId: activeThreadId,
          deltaText: '第一段',
          replace: true,
        );
        await Future<void>.delayed(Duration.zero);

        await controller.selectThread(otherThreadId, forceRemote: true);
        tracker.publish(
          agentRunId: activeRunId,
          threadId: activeThreadId,
          deltaText: '第二段',
        );
        await Future<void>.delayed(Duration.zero);

        await controller.selectThread(activeThreadId);
        await Future<void>.delayed(Duration.zero);
        expect(
          controller.state.messages
              .singleWhere(
                (message) => message.messageId == 'stream-$activeRunId',
              )
              .visibleText,
          '第一段第二段',
        );
      },
    );

    test(
      'agentRunId-bound durable Assistant blocks a late SSE draft',
      () async {
        const threadId = 'task-id-terminal-thread-1';
        const agentRunId = 'task-id-terminal-run-1';
        final tracker = _SseDraftChatRunTracker(
          initialActivities: <ChatRunActivity>[
            ChatRunActivity(
              agentRunId: agentRunId,
              threadId: threadId,
              status: 'running',
              createdAt: DateTime.utc(2026, 9, 1, 10),
            ),
          ],
        );
        final api = _FakeChatApi(
          details: <String, ChatThreadDetail>{
            threadId: ChatThreadDetail(
              thread: _thread(threadId),
              messages: <ChatMessage>[
                _message(
                  id: 'task-id-terminal-user-1',
                  threadId: threadId,
                  role: ChatMessageRole.user,
                ),
              ],
            ),
          },
        );
        final controller = ChatController(
          api: api,
          scene: ChatScene.feedAi,
          runTracker: tracker,
          coalescedStreamingUi: false,
        );
        addTearDown(controller.dispose);
        addTearDown(tracker.dispose);

        await controller.selectThread(threadId, forceRemote: true);
        tracker.publish(
          agentRunId: agentRunId,
          threadId: threadId,
          deltaText: '尚未收口的草稿',
          replace: true,
        );
        await Future<void>.delayed(Duration.zero);

        api.details[threadId] = ChatThreadDetail(
          thread: _thread(threadId),
          messages: <ChatMessage>[
            _message(
              id: 'task-id-terminal-assistant-1',
              threadId: threadId,
              role: ChatMessageRole.assistant,
              text: '正式回答',
              taskId: 'public-task-distinct-from-agent-run',
              agentRunId: agentRunId,
            ),
          ],
        );
        await controller.selectThread(threadId, forceRemote: true);
        tracker.publish(
          agentRunId: agentRunId,
          threadId: threadId,
          deltaText: '迟到内容',
        );
        await Future<void>.delayed(Duration.zero);

        final assistants = controller.state.messages
            .where((message) => message.role == ChatMessageRole.assistant)
            .toList(growable: false);
        expect(assistants, hasLength(1));
        expect(assistants.single.messageId, 'task-id-terminal-assistant-1');
        expect(assistants.single.visibleText, '正式回答');
      },
    );

    test(
      'rebinds when checkpoint activity is restored after thread selection',
      () async {
        const threadId = 'delayed-restored-streaming-thread-1';
        const agentRunId = 'delayed-restored-streaming-agent-run-1';
        final tracker = _SseDraftChatRunTracker();
        final thread = _thread(threadId);
        final controller = ChatController(
          api: _FakeChatApi(
            details: <String, ChatThreadDetail>{
              threadId: ChatThreadDetail(
                thread: thread,
                messages: <ChatMessage>[
                  _message(
                    id: 'delayed-restored-streaming-user-1',
                    threadId: threadId,
                    role: ChatMessageRole.user,
                    text: 'checkpoint 恢复前的问题',
                  ),
                ],
              ),
            },
          ),
          scene: ChatScene.feedAi,
          runTracker: tracker,
          coalescedStreamingUi: false,
        );
        addTearDown(controller.dispose);
        addTearDown(tracker.dispose);

        await controller.selectThread(threadId, forceRemote: true);
        tracker.restoreActivity(
          ChatRunActivity(
            agentRunId: agentRunId,
            threadId: threadId,
            status: 'running',
            createdAt: DateTime.utc(2026, 8, 31, 12),
          ),
        );
        tracker.publish(
          agentRunId: agentRunId,
          threadId: threadId,
          deltaText: '延迟恢复后到达的分段',
          replace: true,
        );
        await Future<void>.delayed(Duration.zero);

        final streamed = controller.state.messages.singleWhere(
          (message) => message.messageId == 'stream-$agentRunId',
        );
        expect(streamed.visibleText, '延迟恢复后到达的分段');
        expect(streamed.status, 'streaming');
      },
    );

    test(
      'freezes failed terminal Agent Run draft projections in place',
      () async {
        for (final fixture in <({String status, String? completionMode})>[
          (status: 'failed', completionMode: null),
          (status: 'timeout', completionMode: null),
          (status: 'cancelled', completionMode: 'cancelled'),
        ]) {
          final threadId = 'terminal-draft-${fixture.status}';
          final agentRunId = 'terminal-draft-run-${fixture.status}';
          const frozenTarget =
              '这是已经由后端完整返回、但本地仍在逐字展示的一段较长临时回复；'
              '即使运行异常结束，也必须冻结完整接收内容，不能只留下屏幕当时显示的短前缀。';
          late final _SseDraftChatRunTracker tracker;
          tracker = _SseDraftChatRunTracker(
            onTrack: (trackedRunId, trackedThreadId) => tracker.publish(
              agentRunId: trackedRunId,
              threadId: trackedThreadId,
              deltaText: frozenTarget,
              replace: true,
            ),
          );
          final api = _FakeChatApi(
            createdThread: _thread(threadId),
            sentMutation: ChatTextMutation(
              message: _message(
                id: 'terminal-draft-user-${fixture.status}',
                threadId: threadId,
                role: ChatMessageRole.user,
              ),
              nextAction: ChatNextAction(
                type: ChatNextActionType.pollAgentRun,
                agentRunId: agentRunId,
              ),
            ),
          );
          final controller = ChatController(
            api: api,
            assistantRuntime: legacyAssistantRuntime(
              _StableAssistantRuntimeFixture(
                _runSuccess(
                  _agentRun(
                    agentRunId: agentRunId,
                    threadId: threadId,
                    status: 'running',
                  ),
                ),
              ),
            ),
            runTracker: tracker,
            scene: ChatScene.feedAi,
            taskPollInterval: const Duration(days: 1),
          );
          try {
            expect(await controller.sendText('请流式回答'), isTrue);
            await Future<void>.delayed(const Duration(milliseconds: 40));
            expect(
              controller.state.messages.any(
                (message) => message.messageId == 'stream-$agentRunId',
              ),
              isTrue,
            );
            final liveDraft =
                controller.assistantAnswerDrafts.value['stream-$agentRunId']!;
            expect(liveDraft.targetText, frozenTarget);
            expect(
              liveDraft.visibleText.length,
              lessThan(liveDraft.targetText.length),
            );

            tracker.publishCompletion(
              agentRunId: agentRunId,
              threadId: threadId,
              status: fixture.status,
              completionMode: fixture.completionMode,
            );
            for (
              var attempt = 0;
              attempt < 20 &&
                  controller.state.turnState.phase != ChatTurnPhase.failed;
              attempt += 1
            ) {
              await Future<void>.delayed(const Duration(milliseconds: 1));
            }

            final frozen = controller.state.messages.singleWhere(
              (message) => message.messageId == 'stream-$agentRunId',
            );
            expect(frozen.visibleText, frozenTarget);
            expect(frozen.status, 'streaming');
            expect(frozen.localDelivery, ChatLocalDeliveryState.pending);
            expect(
              controller.assistantAnswerDrafts.value,
              isNot(contains('stream-$agentRunId')),
            );
            expect(controller.state.turnState.phase, ChatTurnPhase.failed);
          } finally {
            controller.dispose();
            tracker.dispose();
          }
        }
      },
    );

    test(
      'restores a detached failed Run snapshot as a frozen exact row',
      () async {
        const threadId = 'detached-failed-draft-thread';
        const agentRunId = 'detached-failed-draft-run';
        final tracker = _SseDraftChatRunTracker();
        addTearDown(tracker.dispose);
        tracker.restoreActivity(
          ChatRunActivity(
            agentRunId: agentRunId,
            threadId: threadId,
            status: 'running',
            createdAt: DateTime.utc(2026, 9, 2, 8),
          ),
        );
        tracker.publish(
          agentRunId: agentRunId,
          threadId: threadId,
          deltaText: '切出页面前已经看到的回答',
          replace: true,
        );
        tracker.publishCompletion(
          agentRunId: agentRunId,
          threadId: threadId,
          status: 'failed',
        );
        final api = _FakeChatApi(
          details: <String, ChatThreadDetail>{
            threadId: ChatThreadDetail(
              thread: _thread(threadId),
              messages: <ChatMessage>[
                _message(
                  id: 'detached-failed-user',
                  threadId: threadId,
                  role: ChatMessageRole.user,
                  text: '页面切出后仍需完成',
                ),
              ],
            ),
          },
        );
        final controller = ChatController(
          api: api,
          runTracker: tracker,
          scene: ChatScene.feedAi,
          taskPollInterval: const Duration(days: 1),
        );
        addTearDown(controller.dispose);
        final publishedPhases = <ChatTurnPhase>[];
        controller.addListener(
          () => publishedPhases.add(controller.state.turnState.phase),
        );

        await controller.selectThread(threadId, forceRemote: true);
        await Future<void>.delayed(Duration.zero);

        final frozen = controller.state.messages.singleWhere(
          (message) => message.messageId == 'stream-$agentRunId',
        );
        expect(frozen.visibleText, '切出页面前已经看到的回答');
        expect(frozen.agentRunId, agentRunId);
        expect(controller.state.turnState.phase, ChatTurnPhase.failed);
        final firstFailure = publishedPhases.indexOf(ChatTurnPhase.failed);
        expect(firstFailure, greaterThanOrEqualTo(0));
        expect(
          publishedPhases.skip(firstFailure),
          everyElement(ChatTurnPhase.failed),
        );
      },
    );

    test(
      'converges a minimal agent-run receipt through thread read-back',
      () async {
        const threadId = 'minimal-agent-run';
        final api = _FakeChatApi(
          createdThread: _thread(threadId),
          sentMutation: const ChatTextMutation(
            nextAction: ChatNextAction(
              type: ChatNextActionType.pollAgentRun,
              agentRunId: 'minimal-agent-run-1',
            ),
          ),
          details: <String, ChatThreadDetail>{
            threadId: ChatThreadDetail(
              thread: _thread(threadId),
              messages: <ChatMessage>[
                _message(
                  id: 'minimal-user',
                  threadId: threadId,
                  role: ChatMessageRole.user,
                  text: '只返回 Run ID 的请求',
                ),
                _message(
                  id: 'minimal-assistant',
                  threadId: threadId,
                  role: ChatMessageRole.assistant,
                  text: '已经完成线程读回。',
                ),
              ],
            ),
          },
        );
        final runs = _FakeAssistantRuntimeFixture(<ApiResult<AgentRunSnapshot>>[
          _runSuccess(
            _agentRun(
              agentRunId: 'minimal-agent-run-1',
              status: 'succeeded',
              threadId: threadId,
              assistantMessageId: 'minimal-assistant',
              completionMode: 'normal',
            ),
          ),
        ]);
        final controller = ChatController(
          api: api,
          assistantRuntime: legacyAssistantRuntime(runs),
          scene: ChatScene.feedAi,
          taskPollInterval: Duration.zero,
          taskPollAttempts: 1,
        );

        expect(await controller.sendText('只返回 Run ID 的请求'), isTrue);
        expect(controller.state.status, ChatControllerStatus.ready);
        expect(controller.state.lastErrorCode, isNull);
        expect(
          controller.state.messages.map((message) => message.messageId),
          <String>['minimal-user', 'minimal-assistant'],
        );
        controller.dispose();
      },
    );

    test('forwards an accepted Agent Run to the global tracker', () async {
      const threadId = 'detached-run-thread';
      const agentRunId = 'agent_run_detached_1';
      final tracker = _FakeChatRunTracker();
      final controller = ChatController(
        api: _pendingAgentRunApi(
          threadId: threadId,
          agentRunId: agentRunId,
          assistantId: 'detached-assistant',
          assistantText: '已从服务端恢复回复。',
        ),
        assistantRuntime: legacyAssistantRuntime(
          _FakeAssistantRuntimeFixture(<ApiResult<AgentRunSnapshot>>[
            _runSuccess(
              _agentRun(
                agentRunId: agentRunId,
                status: 'succeeded',
                threadId: threadId,
                assistantMessageId: 'detached-assistant',
                completionMode: 'normal',
              ),
            ),
          ]),
        ),
        runTracker: tracker,
        scene: ChatScene.feedAi,
        taskPollInterval: Duration.zero,
        taskPollAttempts: 1,
      );

      expect(await controller.sendText('离开页面后继续处理'), isTrue);
      await Future<void>.delayed(Duration.zero);

      expect(tracker.calls, <
        ({
          String agentRunId,
          String threadId,
          ChatScene scene,
          ChatConversationPurpose purpose,
        })
      >[
        (
          agentRunId: agentRunId,
          threadId: threadId,
          scene: ChatScene.feedAi,
          purpose: ChatConversationPurpose.general,
        ),
      ]);
      expect(tracker.subjectCalls.last, (
        threadId: threadId,
        subjectTitle: '离开页面后继续处理',
      ));
      controller.dispose();
    });

    test(
      'starting a new thread cancels its Run read and ignores a late result',
      () async {
        const threadId = 'cancelled-route-thread';
        const agentRunId = 'cancelled-route-run';
        final runs = _CancellableAssistantRuntimeFixture();
        final controller = ChatController(
          api: _pendingAgentRunApi(threadId: threadId, agentRunId: agentRunId),
          assistantRuntime: legacyAssistantRuntime(runs),
          runTracker: const _DetachingChatRunTracker(),
          scene: ChatScene.feedAi,
          taskPollInterval: Duration.zero,
          taskPollAttempts: 1,
        );
        addTearDown(controller.dispose);

        expect(await controller.sendText('切换前的请求'), isTrue);
        await runs.started.future;

        controller.startNewThread();
        expect(runs.cancelCalls, 1);
        expect(controller.state.activeThreadId, isNull);

        runs.completeLate(
          _runSuccess(
            _agentRun(
              agentRunId: agentRunId,
              status: 'succeeded',
              threadId: threadId,
              assistantMessageId: 'late-assistant',
              completionMode: 'normal',
            ),
          ),
        );
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        expect(controller.state.activeThreadId, isNull);
        expect(controller.state.messages, isEmpty);
        expect(controller.state.agentRunStatus, isNull);
      },
    );

    test(
      'recreated controller reads the exact Assistant when the tracker settles',
      () async {
        const threadId = 'route-replaced-thread';
        const agentRunId = 'agent_run_route_replaced_1';
        const assistantId = 'assistant-route-replaced';
        final api = _pendingAgentRunApi(
          threadId: threadId,
          agentRunId: agentRunId,
        );
        final trackerRuns =
            _FakeAssistantRuntimeFixture(<ApiResult<AgentRunSnapshot>>[
              _runSuccess(
                _agentRun(
                  agentRunId: agentRunId,
                  status: 'running',
                  threadId: threadId,
                ),
              ),
              _runSuccess(
                _agentRun(
                  agentRunId: agentRunId,
                  status: 'succeeded',
                  threadId: threadId,
                  assistantMessageId: assistantId,
                  completionMode: 'normal',
                ),
              ),
            ]);
        final tracker = ChatRunTracker(
          assistantRuntime: legacyAssistantRuntime(trackerRuns),
          preferences: AppPreferencesDao(AppDatabase()),
          userScope: 'account-a',
          pollInterval: const Duration(days: 1),
        );
        addTearDown(tracker.dispose);
        await tracker.start();

        final first = ChatController(
          api: api,
          assistantRuntime: legacyAssistantRuntime(
            _StableAssistantRuntimeFixture(
              _runSuccess(
                _agentRun(
                  agentRunId: agentRunId,
                  status: 'running',
                  threadId: threadId,
                ),
              ),
            ),
          ),
          runTracker: tracker,
          scene: ChatScene.feedAi,
          taskPollInterval: Duration.zero,
        );
        expect(await first.sendText('路由替换后继续等待'), isTrue);
        await Future<void>.delayed(Duration.zero);
        expect(tracker.hasPendingRuns, isTrue);
        first.dispose();

        final reopened = ChatController(
          api: api,
          assistantRuntime: legacyAssistantRuntime(
            _StableAssistantRuntimeFixture(
              _runSuccess(
                _agentRun(
                  agentRunId: agentRunId,
                  status: 'running',
                  threadId: threadId,
                ),
              ),
            ),
          ),
          runTracker: tracker,
          scene: ChatScene.feedAi,
          taskPollInterval: Duration.zero,
        );
        addTearDown(reopened.dispose);
        await reopened.selectThread(threadId, forceRemote: true);
        expect(
          reopened.state.messages.where(
            (message) => message.role == ChatMessageRole.assistant,
          ),
          isEmpty,
        );

        api.details[threadId] = ChatThreadDetail(
          thread: _thread(threadId),
          messages: <ChatMessage>[
            _message(
              id: 'user-$threadId',
              threadId: threadId,
              role: ChatMessageRole.user,
              text: '路由替换后继续等待',
            ),
            _message(
              id: assistantId,
              threadId: threadId,
              role: ChatMessageRole.assistant,
              text: '服务端终态回复已回填。',
            ),
          ],
        );
        await tracker.refresh();
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        expect(tracker.hasPendingRuns, isFalse);
        expect(api.detailCalls, <String>[threadId, threadId]);
        expect(reopened.state.status, ChatControllerStatus.ready);
        expect(reopened.state.nextAction.type, ChatNextActionType.none);
        expect(reopened.state.messages.last.messageId, assistantId);
        expect(reopened.state.messages.last.visibleText, '服务端终态回复已回填。');
      },
    );

    test(
      'tracker read-back preserves degraded completion as a failure',
      () async {
        const threadId = 'tracker-degraded-thread';
        const agentRunId = 'agent_run_tracker_degraded_1';
        const assistantId = 'assistant-tracker-degraded';
        final api = _pendingAgentRunApi(
          threadId: threadId,
          agentRunId: agentRunId,
          assistantId: assistantId,
          assistantText: '服务端降级回复。',
        );
        final tracker = ChatRunTracker(
          assistantRuntime: legacyAssistantRuntime(
            _StableAssistantRuntimeFixture(
              _runSuccess(
                _agentRun(
                  agentRunId: agentRunId,
                  status: 'succeeded',
                  threadId: threadId,
                  assistantMessageId: assistantId,
                  completionMode: 'degraded',
                ),
              ),
            ),
          ),
          preferences: AppPreferencesDao(AppDatabase()),
          userScope: 'account-a',
          pollInterval: const Duration(days: 1),
        );
        addTearDown(tracker.dispose);
        await tracker.start();
        final controller = ChatController(
          api: api,
          runTracker: tracker,
          scene: ChatScene.feedAi,
          taskPollInterval: Duration.zero,
        );
        addTearDown(controller.dispose);
        await controller.selectThread(threadId, forceRemote: true);

        await tracker.track(
          agentRunId: agentRunId,
          threadId: threadId,
          scene: ChatScene.feedAi,
        );
        await Future<void>.delayed(const Duration(milliseconds: 2));

        expect(controller.state.status, ChatControllerStatus.failed);
        expect(controller.state.lastErrorCode, 'CHAT_AGENT_RUN_DEGRADED');
        expect(controller.state.messages.last.messageId, assistantId);
      },
    );

    test(
      'keeps public running activity while an account tracker owns terminal polling',
      () async {
        const threadId = 'tracker-owned-running-thread';
        const agentRunId = 'agent_run_tracker_owned_running_1';
        final preferences = AppPreferencesDao(AppDatabase());
        final tracker = ChatRunTracker(
          assistantRuntime: legacyAssistantRuntime(
            _StableAssistantRuntimeFixture(
              _runSuccess(
                _agentRun(
                  agentRunId: agentRunId,
                  status: 'running',
                  threadId: threadId,
                ),
              ),
            ),
          ),
          preferences: preferences,
          userScope: 'account-a',
          pollInterval: const Duration(days: 1),
        );
        addTearDown(tracker.dispose);
        await tracker.start();
        final localRunApi =
            _FakeAssistantRuntimeFixture(<ApiResult<AgentRunSnapshot>>[
              _runSuccess(
                _agentRun(
                  agentRunId: agentRunId,
                  status: 'running',
                  threadId: threadId,
                ),
              ),
            ]);
        final controller = ChatController(
          api: _pendingAgentRunApi(
            threadId: threadId,
            agentRunId: agentRunId,
            assistantId: 'later-assistant',
            assistantText: '稍后由全局追踪器回读。',
          ),
          assistantRuntime: legacyAssistantRuntime(localRunApi),
          runTracker: tracker,
          scene: ChatScene.feedAi,
          taskPollInterval: Duration.zero,
          taskPollAttempts: 1,
        );
        addTearDown(controller.dispose);

        expect(await controller.sendText('显示正在执行的公开动作'), isTrue);
        await Future<void>.delayed(Duration.zero);

        expect(controller.state.status, ChatControllerStatus.ready);
        expect(controller.state.agentRunStatus, 'running');
        expect(controller.state.lastErrorCode, isNull);
        expect(tracker.isThreadPending(threadId), isTrue);
      },
    );

    test(
      'publishes public Agent tool activity and clears it for a new turn',
      () async {
        const threadId = 'tool-trace-thread';
        const agentRunId = 'tool-trace-run';
        const assistantId = 'tool-trace-assistant';
        final api = _pendingAgentRunApi(
          threadId: threadId,
          agentRunId: agentRunId,
          assistantId: assistantId,
          assistantText: '已经完成资料分析。',
        );
        final startedTrace = AgentRunToolTrace(
          invocationId: 'invocation-search-1',
          toolName: 'workspace_search',
          state: 'started',
          createdAt: DateTime.utc(2026, 8, 11, 8),
          outputFiles: const <AgentRunOutputFile>[],
        );
        final finishedTrace = AgentRunToolTrace(
          invocationId: 'invocation-search-1',
          toolName: 'workspace_search',
          state: 'finished',
          outcome: 'succeeded',
          createdAt: DateTime.utc(2026, 8, 11, 8),
          completedAt: DateTime.utc(2026, 8, 11, 8, 0, 1),
          outputFiles: const <AgentRunOutputFile>[],
        );
        final controller = ChatController(
          api: api,
          assistantRuntime: legacyAssistantRuntime(
            _FakeAssistantRuntimeFixture(<ApiResult<AgentRunSnapshot>>[
              _runSuccess(
                _agentRun(
                  agentRunId: agentRunId,
                  status: 'running',
                  threadId: threadId,
                  toolTrace: <AgentRunToolTrace>[startedTrace],
                ),
              ),
              _runSuccess(
                _agentRun(
                  agentRunId: agentRunId,
                  status: 'succeeded',
                  threadId: threadId,
                  assistantMessageId: assistantId,
                  completionMode: 'normal',
                  toolTrace: <AgentRunToolTrace>[finishedTrace],
                ),
              ),
            ]),
          ),
          scene: ChatScene.feedAi,
          taskPollInterval: Duration.zero,
          taskPollAttempts: 2,
        );
        final observedActivity =
            <({String? status, List<AgentRunToolTrace> trace})>[];
        controller.addListener(() {
          if (controller.state.agentRunStatus != null) {
            observedActivity.add((
              status: controller.state.agentRunStatus,
              trace: controller.state.agentToolTrace,
            ));
          }
        });

        expect(await controller.sendText('分析工作区资料'), isTrue);

        expect(
          observedActivity,
          contains(
            isA<({String? status, List<AgentRunToolTrace> trace})>()
                .having((value) => value.status, 'status', 'running')
                .having(
                  (value) => value.trace.single.toolName,
                  'toolName',
                  'workspace_search',
                )
                .having(
                  (value) => value.trace.single.state,
                  'state',
                  'started',
                ),
          ),
        );
        expect(controller.state.agentRunStatus, 'succeeded');
        expect(controller.state.agentToolTrace.single.outcome, 'succeeded');

        controller.startNewThread();
        expect(controller.state.agentRunStatus, isNull);
        expect(controller.state.agentToolTrace, isEmpty);
        controller.dispose();
      },
    );

    test('keeps thread-only acceptance as compatibility read-back', () async {
      const threadId = 'created-thread-only';
      final api = _FakeChatApi(
        createdThread: _thread(threadId),
        sentMutation: ChatTextMutation(
          message: _message(
            id: 'user-thread-only',
            threadId: threadId,
            role: ChatMessageRole.user,
          ),
          nextAction: const ChatNextAction(type: ChatNextActionType.pollThread),
        ),
        details: <String, ChatThreadDetail>{
          threadId: ChatThreadDetail(
            thread: _thread(threadId),
            messages: <ChatMessage>[
              _message(
                id: 'assistant-thread-only',
                threadId: threadId,
                role: ChatMessageRole.assistant,
                text: '兼容异步回复',
              ),
            ],
          ),
        },
      );
      final controller = ChatController(
        api: api,
        scene: ChatScene.feedAi,
        taskPollInterval: Duration.zero,
        taskPollAttempts: 1,
      );

      expect(await controller.sendText('兼容异步对话'), isTrue);
      expect(controller.state.status, ChatControllerStatus.ready);
      expect(controller.state.messages.last.visibleText, '兼容异步回复');
    });

    test('does not report non-normal terminal completion as success', () async {
      final cases = <({String status, String mode, String code})>[
        (
          status: 'succeeded',
          mode: 'degraded',
          code: 'CHAT_AGENT_RUN_DEGRADED',
        ),
        (
          status: 'succeeded',
          mode: 'system_fallback',
          code: 'CHAT_AGENT_RUN_SYSTEM_FALLBACK',
        ),
        (
          status: 'cancelled',
          mode: 'cancelled',
          code: 'CHAT_AGENT_RUN_CANCELLED',
        ),
      ];

      for (var index = 0; index < cases.length; index += 1) {
        final testCase = cases[index];
        final threadId = 'terminal-mode-$index';
        final assistantId = 'terminal-assistant-$index';
        final api = _pendingAgentRunApi(
          threadId: threadId,
          agentRunId: 'terminal-run-$index',
          assistantId: assistantId,
          assistantText: testCase.mode == 'system_fallback'
              ? '服务器升级中，请稍后再试'
              : '非正常终态回复',
        );
        final controller = ChatController(
          api: api,
          assistantRuntime: legacyAssistantRuntime(
            _FakeAssistantRuntimeFixture(<ApiResult<AgentRunSnapshot>>[
              _runSuccess(
                _agentRun(
                  agentRunId: 'terminal-run-$index',
                  status: testCase.status,
                  threadId: threadId,
                  assistantMessageId: assistantId,
                  completionMode: testCase.mode,
                ),
              ),
            ]),
          ),
          scene: ChatScene.feedAi,
          taskPollInterval: Duration.zero,
          taskPollAttempts: 1,
        );

        expect(await controller.sendText('测试终态'), isTrue);
        expect(controller.state.status, ChatControllerStatus.failed);
        expect(controller.state.lastErrorCode, testCase.code);
        expect(controller.state.nextAction.type, ChatNextActionType.none);
        expect(controller.state.messages.last.messageId, assistantId);
        controller.dispose();
      }
    });

    test(
      'surfaces failed, timed-out, and orphaned runs without a fake reply',
      () async {
        for (final expectation in <(String status, String code)>[
          ('failed', 'CHAT_AGENT_RUN_FAILED'),
          ('timeout', 'CHAT_AGENT_RUN_TIMEOUT'),
          ('orphaned', 'CHAT_AGENT_RUN_ORPHANED'),
        ]) {
          final status = expectation.$1;
          final threadId = 'terminal-$status';
          final agentRunId = 'run-$status';
          final api = _pendingAgentRunApi(
            threadId: threadId,
            agentRunId: agentRunId,
          );
          final controller = ChatController(
            api: api,
            assistantRuntime: legacyAssistantRuntime(
              _FakeAssistantRuntimeFixture(<ApiResult<AgentRunSnapshot>>[
                _runSuccess(
                  _agentRun(
                    agentRunId: agentRunId,
                    status: status,
                    threadId: threadId,
                  ),
                ),
              ]),
            ),
            scene: ChatScene.feedAi,
            taskPollInterval: Duration.zero,
            taskPollAttempts: 1,
          );

          expect(await controller.sendText('测试失败终态'), isTrue);
          expect(controller.state.status, ChatControllerStatus.failed);
          expect(controller.state.lastErrorCode, expectation.$2);
          expect(
            controller.state.messages.where(
              (message) => message.role == ChatMessageRole.assistant,
            ),
            isEmpty,
          );
          if (status == 'orphaned') {
            expect(api.detailCalls, <String>[threadId]);
          }
          controller.dispose();
        }
      },
    );

    test('preserves a safe public terminal Run failure code', () async {
      const threadId = 'runtime-event-gap-thread';
      const agentRunId = 'agent_run_runtime_event_gap_1';
      final controller = ChatController(
        api: _pendingAgentRunApi(threadId: threadId, agentRunId: agentRunId),
        assistantRuntime: legacyAssistantRuntime(
          _FakeAssistantRuntimeFixture(<ApiResult<AgentRunSnapshot>>[
            _runSuccess(
              _agentRun(
                agentRunId: agentRunId,
                status: 'failed',
                threadId: threadId,
                completionMode: 'system_fallback',
                error: AgentRunPublicError(
                  code: 'RUNTIME_EVENT_GAP',
                  retryable: true,
                ),
              ),
            ),
          ]),
        ),
        scene: ChatScene.feedAi,
        taskPollInterval: Duration.zero,
        taskPollAttempts: 1,
      );

      expect(await controller.sendText('检查运行事件'), isTrue);
      expect(controller.state.status, ChatControllerStatus.failed);
      expect(controller.state.lastErrorCode, 'RUNTIME_EVENT_GAP');
      expect(
        controller.state.messages.where(
          (message) => message.role == ChatMessageRole.assistant,
        ),
        isEmpty,
      );
      controller.dispose();
    });

    test(
      'fails a Run that never reaches a terminal state within its budget',
      () async {
        const threadId = 'nonterminal-run-thread';
        const agentRunId = 'agent_run_nonterminal_budget_1';
        final controller = ChatController(
          api: _pendingAgentRunApi(threadId: threadId, agentRunId: agentRunId),
          assistantRuntime: legacyAssistantRuntime(
            _FakeAssistantRuntimeFixture(<ApiResult<AgentRunSnapshot>>[
              _runSuccess(
                _agentRun(
                  agentRunId: agentRunId,
                  status: 'running',
                  threadId: threadId,
                ),
              ),
            ]),
          ),
          scene: ChatScene.feedAi,
          taskPollInterval: Duration.zero,
          taskPollAttempts: 1,
        );

        expect(await controller.sendText('等待运行完成'), isTrue);
        expect(controller.state.status, ChatControllerStatus.failed);
        expect(controller.state.lastErrorCode, 'CHAT_AGENT_RUN_TIMEOUT');
        expect(
          controller.state.nextAction.type,
          ChatNextActionType.pollAgentRun,
        );
        controller.dispose();
      },
    );

    test(
      'retains poll action until the durable assistant can be read',
      () async {
        const threadId = 'delayed-assistant-thread';
        const agentRunId = 'delayed-assistant-run';
        const assistantId = 'delayed-assistant-message';
        final api = _pendingAgentRunApi(
          threadId: threadId,
          agentRunId: agentRunId,
        );
        final run = _agentRun(
          agentRunId: agentRunId,
          status: 'succeeded',
          threadId: threadId,
          assistantMessageId: assistantId,
          completionMode: 'normal',
        );
        final controller = ChatController(
          api: api,
          assistantRuntime: legacyAssistantRuntime(
            _FakeAssistantRuntimeFixture(<ApiResult<AgentRunSnapshot>>[
              _runSuccess(run),
              _runSuccess(run),
            ]),
          ),
          scene: ChatScene.feedAi,
          taskPollInterval: Duration.zero,
          taskPollAttempts: 1,
        );

        expect(await controller.sendText('等待持久回复'), isTrue);
        expect(controller.state.status, ChatControllerStatus.failed);
        expect(
          controller.state.lastErrorCode,
          'CHAT_AGENT_RUN_REPLY_NOT_PERSISTED',
        );
        expect(
          controller.state.nextAction.type,
          ChatNextActionType.pollAgentRun,
        );

        api.details[threadId] = ChatThreadDetail(
          thread: _thread(threadId),
          messages: <ChatMessage>[
            _message(
              id: assistantId,
              threadId: threadId,
              role: ChatMessageRole.assistant,
              text: '稍后完成的持久回复',
            ),
          ],
        );
        await controller.refreshPendingTask();

        expect(controller.state.status, ChatControllerStatus.ready);
        expect(controller.state.lastErrorCode, isNull);
        expect(controller.state.nextAction.type, ChatNextActionType.none);
        expect(controller.state.messages.last.messageId, assistantId);
      },
    );

    test(
      'keeps a tracker-owned accepted Run pending after a retryable poll error',
      () async {
        const threadId = 'detached-retry-thread';
        const agentRunId = 'detached-retry-run';
        const assistantId = 'detached-retry-assistant';
        final api = _pendingAgentRunApi(
          threadId: threadId,
          agentRunId: agentRunId,
          assistantId: assistantId,
          assistantText: '后台重试后持久化的回复',
        );
        final runApi =
            _FakeAssistantRuntimeFixture(<ApiResult<AgentRunSnapshot>>[
              _retryableFailure('RUNTIME_CAPACITY_UNAVAILABLE'),
              _runSuccess(
                _agentRun(
                  agentRunId: agentRunId,
                  status: 'succeeded',
                  threadId: threadId,
                  assistantMessageId: assistantId,
                  completionMode: 'normal',
                ),
              ),
            ]);
        final controller = ChatController(
          api: api,
          assistantRuntime: legacyAssistantRuntime(runApi),
          runTracker: const _DetachingChatRunTracker(),
          scene: ChatScene.feedAi,
          taskPollInterval: Duration.zero,
          taskPollAttempts: 1,
        );

        expect(await controller.sendText('只提交一次'), isTrue);
        await Future<void>.delayed(Duration.zero);

        expect(api.sentContents, <String>['只提交一次']);
        expect(controller.state.status, ChatControllerStatus.ready);
        expect(controller.state.lastErrorCode, isNull);
        expect(
          controller.state.nextAction.type,
          ChatNextActionType.pollAgentRun,
        );
        expect(
          controller.state.turnState.phase,
          ChatTurnPhase.waitingForAssistant,
        );
        expect(controller.state.canSubmitUserTurn, isFalse);
        expect(await controller.sendText('不能插入第二轮'), isFalse);
        expect(api.sentContents, <String>['只提交一次']);

        await controller.refreshPendingTask();

        expect(controller.state.status, ChatControllerStatus.ready);
        expect(controller.state.lastErrorCode, isNull);
        expect(controller.state.nextAction.type, ChatNextActionType.none);
        expect(controller.state.messages.last.messageId, assistantId);
        expect(controller.state.turnState.phase, ChatTurnPhase.settled);
        expect(controller.state.canSubmitUserTurn, isTrue);
        expect(api.sentContents, <String>['只提交一次']);
        controller.dispose();
      },
    );

    test(
      'active tracker-owned chat survives delayed terminal projection',
      () async {
        const threadId = 'android-delayed-projection-thread';
        const agentRunId = 'android-delayed-projection-run';
        const assistantId = 'android-delayed-projection-assistant';
        final terminalRun = _agentRun(
          agentRunId: agentRunId,
          status: 'succeeded',
          threadId: threadId,
          assistantMessageId: assistantId,
          completionMode: 'normal',
        );
        final api = _SequencedDetailChatApi(
          createdThread: _thread(threadId),
          sentMutation: ChatTextMutation(
            message: _message(
              id: 'android-delayed-user',
              threadId: threadId,
              role: ChatMessageRole.user,
            ),
            nextAction: const ChatNextAction(
              type: ChatNextActionType.pollAgentRun,
              agentRunId: agentRunId,
            ),
          ),
          detailResults: <ApiResult<ChatThreadDetail>>[
            _retryableFailure('NETWORK_REQUEST_FAILED'),
            _success(
              ChatThreadDetail(
                thread: _thread(threadId),
                messages: <ChatMessage>[
                  _message(
                    id: 'android-delayed-user',
                    threadId: threadId,
                    role: ChatMessageRole.user,
                    text: '引用笔记后的问题',
                  ),
                  _message(
                    id: assistantId,
                    threadId: threadId,
                    role: ChatMessageRole.assistant,
                    text: '后端已持久化的回答',
                    agentRunId: agentRunId,
                  ),
                ],
              ),
              SubmissionKeyStore.empty,
            ),
          ],
        );
        final controller = ChatController(
          api: api,
          assistantRuntime: legacyAssistantRuntime(
            _FakeAssistantRuntimeFixture(<ApiResult<AgentRunSnapshot>>[
              _runSuccess(
                _agentRun(
                  agentRunId: agentRunId,
                  status: 'running',
                  threadId: threadId,
                ),
              ),
              _runSuccess(terminalRun),
              _runSuccess(terminalRun),
            ]),
          ),
          runTracker: const _DetachingChatRunTracker(),
          scene: ChatScene.feedAi,
          taskPollInterval: const Duration(milliseconds: 1),
          taskPollAttempts: 8,
        );
        addTearDown(controller.dispose);

        expect(await controller.sendText('引用笔记后的问题'), isTrue);
        expect(controller.isAwaitingAssistantForThread(threadId), isTrue);
        await Future<void>.delayed(const Duration(milliseconds: 40));

        expect(api.sentContents, <String>['引用笔记后的问题']);
        expect(api.detailCalls, hasLength(2));
        expect(controller.state.lastErrorCode, isNull);
        expect(controller.isAwaitingAssistantForThread(threadId), isFalse);
        expect(controller.state.messages.last.messageId, assistantId);
        expect(controller.state.messages.last.visibleText, '后端已持久化的回答');
      },
    );

    test(
      'tracker-owned terminal Run waits for the durable Assistant projection',
      () async {
        const threadId = 'detached-projection-thread';
        const agentRunId = 'agent_run_detached_projection_1';
        const assistantId = 'detached-projection-assistant';
        final api = _pendingAgentRunApi(
          threadId: threadId,
          agentRunId: agentRunId,
        );
        final tracker = _SseDraftChatRunTracker();
        addTearDown(tracker.dispose);
        final terminalRun = _agentRun(
          agentRunId: agentRunId,
          status: 'succeeded',
          threadId: threadId,
          assistantMessageId: assistantId,
          completionMode: 'normal',
        );
        final controller = ChatController(
          api: api,
          assistantRuntime: legacyAssistantRuntime(
            _StableAssistantRuntimeFixture(_runSuccess(terminalRun)),
          ),
          runTracker: tracker,
          scene: ChatScene.feedAi,
          taskPollInterval: const Duration(days: 1),
          taskPollAttempts: 3,
        );
        addTearDown(controller.dispose);

        expect(await controller.sendText('只提交一次并等待投影'), isTrue);
        await Future<void>.delayed(Duration.zero);

        expect(api.sentContents, <String>['只提交一次并等待投影']);
        expect(controller.state.status, ChatControllerStatus.ready);
        expect(controller.state.lastErrorCode, isNull);
        expect(
          controller.state.nextAction.type,
          ChatNextActionType.pollAgentRun,
        );

        tracker.publish(
          agentRunId: agentRunId,
          threadId: threadId,
          deltaText: '仍在流式展示的完整草稿',
          replace: true,
        );
        await Future<void>.delayed(const Duration(milliseconds: 40));
        expect(
          controller.state.messages
              .singleWhere(
                (message) => message.messageId == 'stream-$agentRunId',
              )
              .visibleText,
          '仍在流式展示的完整草稿',
        );

        tracker.publishCompletion(
          agentRunId: agentRunId,
          threadId: threadId,
          status: 'succeeded',
          completionMode: 'normal',
          assistantMessageId: assistantId,
        );
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        expect(
          controller.state.messages
              .singleWhere(
                (message) => message.messageId == 'stream-$agentRunId',
              )
              .visibleText,
          '仍在流式展示的完整草稿',
        );

        api.details[threadId] = ChatThreadDetail(
          thread: _thread(threadId),
          messages: <ChatMessage>[
            _message(
              id: assistantId,
              threadId: threadId,
              role: ChatMessageRole.assistant,
              text: '服务端稍后完成的持久回复',
              agentRunId: agentRunId,
            ),
          ],
        );
        await controller.selectThread(threadId, forceRemote: true);

        expect(controller.state.status, ChatControllerStatus.ready);
        expect(controller.state.lastErrorCode, isNull);
        expect(controller.state.nextAction.type, ChatNextActionType.none);
        expect(
          controller.state.messages
              .where(
                (message) =>
                    message.role == ChatMessageRole.assistant &&
                    message.agentRunId == agentRunId,
              )
              .single
              .messageId,
          assistantId,
        );
        expect(api.sentContents, <String>['只提交一次并等待投影']);
      },
    );

    test(
      'terminal completion retires a provisional stream after canonical arrival',
      () async {
        const threadId = 'canonical-first-thread';
        const agentRunId = 'agent_run_canonical_first_1';
        const publicTaskId = 'public_task_canonical_first_1';
        const assistantId = 'canonical-first-assistant';
        final api = _pendingAgentRunApi(
          threadId: threadId,
          agentRunId: agentRunId,
        );
        final tracker = _SseDraftChatRunTracker();
        addTearDown(tracker.dispose);
        final controller = ChatController(
          api: api,
          runTracker: tracker,
          scene: ChatScene.feedAi,
          taskPollInterval: const Duration(days: 1),
        );
        addTearDown(controller.dispose);

        expect(await controller.sendText('先返回正式消息'), isTrue);
        tracker.publish(
          agentRunId: agentRunId,
          threadId: threadId,
          deltaText: '临时流式回答',
          replace: true,
        );
        await Future<void>.delayed(const Duration(milliseconds: 40));

        api.details[threadId] = ChatThreadDetail(
          thread: _thread(threadId),
          messages: <ChatMessage>[
            _message(
              id: assistantId,
              threadId: threadId,
              role: ChatMessageRole.assistant,
              text: '正式回答',
              taskId: publicTaskId,
            ),
          ],
        );
        await controller.selectThread(threadId, forceRemote: true);
        expect(
          controller.state.messages.map((message) => message.messageId),
          containsAll(<String>[assistantId, 'stream-$agentRunId']),
        );

        tracker.publishCompletion(
          agentRunId: agentRunId,
          threadId: threadId,
          status: 'succeeded',
          completionMode: 'normal',
          assistantMessageId: assistantId,
        );
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        expect(
          controller.state.messages
              .where((message) => message.role == ChatMessageRole.assistant)
              .map((message) => message.messageId),
          <String>[assistantId],
        );
        tracker.publish(
          agentRunId: agentRunId,
          threadId: threadId,
          deltaText: '不应恢复的迟到分片',
        );
        await Future<void>.delayed(const Duration(milliseconds: 40));
        expect(
          controller.state.messages.any(
            (message) => message.messageId == 'stream-$agentRunId',
          ),
          isFalse,
        );
      },
    );

    test(
      'purpose enrichment replays a previously rejected terminal completion',
      () async {
        const threadId = 'purpose-enrichment-thread';
        const agentRunId = 'agent_run_purpose_enrichment_1';
        const assistantId = 'assistant-purpose-enrichment-1';
        final api = _pendingAgentRunApi(
          threadId: threadId,
          agentRunId: agentRunId,
        );
        final tracker = _SseDraftChatRunTracker();
        addTearDown(tracker.dispose);
        final database = AppDatabase();
        final controller = ChatController(
          api: api,
          runTracker: tracker,
          scene: ChatScene.feedAi,
          aliasRepository: ChatThreadAliasRepository(
            dao: UserMetadataDao(database),
            preferencesDao: AppPreferencesDao(database),
            userScope: 'purpose-enrichment-account',
          ),
          conversationPurpose: ChatConversationPurpose.deepPositioning,
          taskPollInterval: Duration.zero,
        );
        addTearDown(controller.dispose);

        expect(
          await controller.sendText(
            '继续深度定位',
            context: ChatContextEnvelope.create(
              purpose: ChatContextPurpose.deepPositioning,
              includeAccountProfile: true,
            ),
          ),
          isTrue,
        );
        await Future<void>.delayed(Duration.zero);
        final detailCallsBeforeCompletion = api.detailCalls.length;
        tracker.publish(
          agentRunId: agentRunId,
          threadId: threadId,
          deltaText: '临时流式回答',
          replace: true,
        );
        await Future<void>.delayed(const Duration(milliseconds: 40));
        tracker.publishCompletion(
          agentRunId: agentRunId,
          threadId: threadId,
          status: 'succeeded',
          completionMode: 'normal',
          assistantMessageId: assistantId,
        );
        await Future<void>.delayed(Duration.zero);
        expect(api.detailCalls, hasLength(detailCallsBeforeCompletion));

        api.details[threadId] = ChatThreadDetail(
          thread: _thread(
            threadId,
          ).copyWith(purpose: ChatConversationPurpose.deepPositioning),
          messages: <ChatMessage>[
            _message(
              id: assistantId,
              threadId: threadId,
              role: ChatMessageRole.assistant,
              text: '正式定位回答',
              agentRunId: agentRunId,
            ),
          ],
        );
        tracker.publishCompletion(
          agentRunId: agentRunId,
          threadId: threadId,
          purpose: ChatConversationPurpose.deepPositioning,
          status: 'succeeded',
          completionMode: 'normal',
          assistantMessageId: assistantId,
        );
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        expect(api.detailCalls, hasLength(detailCallsBeforeCompletion + 1));
        expect(api.detailCalls.last, threadId);
        expect(
          controller.state.messages
              .where((message) => message.role == ChatMessageRole.assistant)
              .map((message) => message.messageId),
          <String>[assistantId],
        );
      },
    );

    test('rejects an agent run bound to another thread', () async {
      const threadId = 'expected-thread';
      final api = _pendingAgentRunApi(
        threadId: threadId,
        agentRunId: 'binding-run',
      );
      final controller = ChatController(
        api: api,
        assistantRuntime: legacyAssistantRuntime(
          _FakeAssistantRuntimeFixture(<ApiResult<AgentRunSnapshot>>[
            _runSuccess(
              _agentRun(
                agentRunId: 'binding-run',
                status: 'running',
                threadId: 'different-thread',
              ),
            ),
          ]),
        ),
        scene: ChatScene.feedAi,
        taskPollInterval: Duration.zero,
        taskPollAttempts: 1,
      );

      expect(await controller.sendText('不能串会话'), isTrue);
      expect(controller.state.status, ChatControllerStatus.failed);
      expect(controller.state.lastErrorCode, 'CHAT_AGENT_RUN_BINDING_INVALID');
      expect(api.detailCalls, isEmpty);
    });

    test(
      'hydrates missing history names without changing active messages',
      () async {
        final api = _FakeChatApi(
          threads: <ChatThread>[
            _thread('older', updatedAt: DateTime.utc(2026, 7, 9)),
            _thread('newer', updatedAt: DateTime.utc(2026, 7, 10)),
          ],
          details: <String, ChatThreadDetail>{
            'newer': ChatThreadDetail(
              thread: _thread('newer'),
              messages: <ChatMessage>[
                _message(
                  id: 'newer-user',
                  threadId: 'newer',
                  role: ChatMessageRole.user,
                  text: '讨论新品发布节奏',
                ),
              ],
            ),
            'older': ChatThreadDetail(
              thread: _thread('older'),
              messages: <ChatMessage>[
                _message(
                  id: 'older-user',
                  threadId: 'older',
                  role: ChatMessageRole.user,
                  text: '复盘老客户续约问题',
                ),
              ],
            ),
          },
        );
        final controller = ChatController(api: api, scene: ChatScene.feedAi);
        await controller.loadThreads();
        final activeMessages = controller.state.messages;

        await controller.hydrateThreadTitles();

        expect(controller.state.activeThreadId, 'newer');
        expect(identical(controller.state.messages, activeMessages), isFalse);
        expect(controller.state.messages, activeMessages);
        expect(
          controller.state.threads.map((thread) => thread.displayTitle),
          containsAll(<String>['讨论新品发布节奏', '复盘老客户续约问题']),
        );
        expect(api.detailCalls, <String>['newer', 'older']);
      },
    );

    test(
      'sends exact user text with a structured memory-note reference',
      () async {
        final api = _FakeChatApi(
          createdThread: _thread('created-1'),
          sentMutation: ChatTextMutation(
            message: _message(
              id: 'user-1',
              threadId: 'created-1',
              role: ChatMessageRole.user,
            ),
          ),
        );
        final controller = ChatController(api: api, scene: ChatScene.feedAi);

        final context = ChatContextEnvelope.create(
          purpose: ChatContextPurpose.general,
          references: const <ChatContextReference>[
            ChatContextReference(
              type: ChatContextReferenceType.memoryNote,
              id: 'note-1',
            ),
          ],
        );
        final sent = await controller.sendText(
          '下一步怎么做？',
          context: context,
          assetReferences: const <ChatAssetReference>[
            ChatAssetReference(assetId: 'note-1', title: '增长复盘'),
          ],
        );

        expect(sent, isTrue);
        expect(api.sentContents.single, '下一步怎么做？');
        expect(api.sentContexts.single?.references.single.id, 'note-1');
        expect(controller.state.messages.single.visibleText, '下一步怎么做？');
        expect(
          controller.state.messages.single.assetReferences.single.title,
          '增长复盘',
        );
      },
    );

    test(
      'server refresh preserves the asset bound to the matching user turn',
      () {
        final merged = ChatControllerPolicies.mergeServerAndLocalMessages(
          <ChatMessage>[
            _message(
              id: 'server-user-1',
              threadId: 'thread-1',
              role: ChatMessageRole.user,
              text: '帮我分析这份资料',
            ),
          ],
          <ChatMessage>[
            _message(
              id: 'local-user-1',
              threadId: 'thread-1',
              role: ChatMessageRole.user,
              text: '帮我分析这份资料',
            ).copyWith(
              localDelivery: ChatLocalDeliveryState.pending,
              assetReferences: const <ChatAssetReference>[
                ChatAssetReference(assetId: 'asset-1', title: '客户访谈'),
              ],
            ),
          ],
          'thread-1',
          ChatScene.feedAi,
        );

        final serverMessage = merged.singleWhere(
          (message) => message.messageId == 'server-user-1',
        );
        expect(serverMessage.assetReferences.single.title, '客户访谈');
      },
    );

    test('publishes a canonical user-before-Assistant timeline', () {
      final projected = ChatTurnStateMachine.normalizeTimeline(<ChatMessage>[
        _message(
          id: 'assistant-out-of-order',
          threadId: 'thread-1',
          role: ChatMessageRole.assistant,
          text: '回答',
        ).copyWith(createdAt: DateTime.utc(2026, 9, 2, 8, 0, 2)),
        _message(
          id: 'user-out-of-order',
          threadId: 'thread-1',
          role: ChatMessageRole.user,
          text: '问题',
        ).copyWith(createdAt: DateTime.utc(2026, 9, 2, 8)),
      ]);

      expect(projected.map((message) => message.messageId), <String>[
        'user-out-of-order',
        'assistant-out-of-order',
      ]);
      final turn = ChatTurnStateMachine.reduce(
        messages: projected,
        assistantExpected: false,
        terminalReadbackPending: false,
        turnFailed: false,
      );
      expect(turn.phase, ChatTurnPhase.settled);
      expect(turn.acceptsUserTurn, isTrue);
    });

    test('does not reopen an older failed user Turn', () async {
      final controller = ChatController(
        api: _FakeChatApi(),
        scene: ChatScene.feedAi,
      );
      addTearDown(controller.dispose);

      expect(await controller.sendText('第一条失败消息'), isFalse);
      final firstFailedId = controller.state.messages.single.messageId;
      expect(await controller.sendText('第二条失败消息'), isFalse);

      expect(controller.state.turnState.phase, ChatTurnPhase.failed);
      expect(controller.canRetryFailedTextMessage(firstFailedId), isFalse);
      expect(
        controller.canRetryFailedTextMessage(
          controller.state.messages.last.messageId,
        ),
        isTrue,
      );
    });

    test('taskId-only durable Assistant does not claim a Run draft', () {
      final merged = ChatControllerPolicies.mergeServerAndLocalMessages(
        <ChatMessage>[
          _message(
            id: 'assistant-final-1',
            threadId: 'thread-1',
            role: ChatMessageRole.assistant,
            text: '正式回答',
            taskId: 'run-compatible-1',
          ),
        ],
        <ChatMessage>[
          _message(
            id: 'stream-run-compatible-1',
            threadId: 'thread-1',
            role: ChatMessageRole.assistant,
            text: '回答草稿',
            status: 'streaming',
            agentRunId: 'run-compatible-1',
          ),
        ],
        'thread-1',
        ChatScene.feedAi,
      );

      expect(merged, hasLength(2));
      expect(
        merged.map((message) => message.messageId),
        containsAll(<String>['assistant-final-1', 'stream-run-compatible-1']),
      );
    });

    test(
      'binds a canonical Assistant to its exact Run and ignores another Run',
      () {
        final merged = ChatControllerPolicies.mergeServerAndLocalMessages(
          <ChatMessage>[
            _message(
              id: 'assistant-final-correlated',
              threadId: 'thread-1',
              role: ChatMessageRole.assistant,
              text: '正式回答',
              taskId: 'public-task-distinct-from-run',
            ),
          ],
          <ChatMessage>[
            _message(
              id: 'stream-exact-run',
              threadId: 'thread-1',
              role: ChatMessageRole.assistant,
              text: '流式草稿',
              status: 'streaming',
              agentRunId: 'exact-run',
            ),
          ],
          'thread-1',
          ChatScene.feedAi,
          terminalAssistantMessageIdsByRunId: const <String, String>{
            'exact-run': 'assistant-final-correlated',
          },
        );

        expect(merged, hasLength(1));
        expect(merged.single.messageId, 'assistant-final-correlated');
        expect(merged.single.taskId, 'public-task-distinct-from-run');
        expect(merged.single.agentRunId, 'exact-run');

        final ambiguous = ChatControllerPolicies.mergeServerAndLocalMessages(
          <ChatMessage>[
            _message(
              id: 'assistant-ambiguous',
              threadId: 'thread-1',
              role: ChatMessageRole.assistant,
              text: '不能猜测所属 Run',
            ),
          ],
          <ChatMessage>[
            _message(
              id: 'stream-run-a',
              threadId: 'thread-1',
              role: ChatMessageRole.assistant,
              status: 'streaming',
              agentRunId: 'run-a',
            ),
            _message(
              id: 'stream-run-b',
              threadId: 'thread-1',
              role: ChatMessageRole.assistant,
              status: 'streaming',
              agentRunId: 'run-b',
            ),
          ],
          'thread-1',
          ChatScene.feedAi,
          terminalAssistantMessageIdsByRunId: const <String, String>{
            'run-a': 'assistant-ambiguous',
            'run-b': 'assistant-ambiguous',
          },
        );
        expect(ambiguous, hasLength(3));
        expect(
          ambiguous
              .singleWhere(
                (message) => message.messageId == 'assistant-ambiguous',
              )
              .agentRunId,
          isNull,
        );

        final wrongRun = ChatTurnStateMachine.reduce(
          messages: <ChatMessage>[
            _message(
              id: 'latest-user',
              threadId: 'thread-1',
              role: ChatMessageRole.user,
              text: '最新问题',
            ),
            _message(
              id: 'another-run-answer',
              threadId: 'thread-1',
              role: ChatMessageRole.assistant,
              text: '属于另一轮的回答',
              agentRunId: 'another-run',
            ),
          ],
          assistantExpected: true,
          terminalReadbackPending: false,
          turnFailed: false,
          agentRunId: 'exact-run',
        );
        expect(wrongRun.phase, ChatTurnPhase.waitingForAssistant);
        expect(wrongRun.assistantMessageId, isNull);

        final exactRun = ChatTurnStateMachine.reduce(
          messages: <ChatMessage>[
            _message(
              id: 'latest-user',
              threadId: 'thread-1',
              role: ChatMessageRole.user,
              text: '最新问题',
            ),
            merged.single,
          ],
          assistantExpected: true,
          terminalReadbackPending: false,
          turnFailed: false,
          agentRunId: 'exact-run',
        );
        expect(exactRun.phase, ChatTurnPhase.settled);
        expect(exactRun.assistantMessageId, 'assistant-final-correlated');
      },
    );

    test('deduplicates a retried file-only turn on canonical refresh', () {
      const resource = ChatResourceAttachment(
        kind: ChatResourceAttachmentKind.file,
        resourceId: 'resource-retry-file-1',
        displayName: '复盘.pdf',
        mimeType: 'application/pdf',
        sizeBytes: 4096,
      );
      final merged = ChatControllerPolicies.mergeServerAndLocalMessages(
        <ChatMessage>[
          _message(
            id: 'canonical-file-user-1',
            threadId: 'thread-1',
            role: ChatMessageRole.user,
            resourceAttachments: const <ChatResourceAttachment>[resource],
          ),
        ],
        <ChatMessage>[
          _message(
            id: 'local-file-user-1',
            threadId: 'thread-1',
            role: ChatMessageRole.user,
            text: '已发送 1 项资料',
            resourceAttachments: const <ChatResourceAttachment>[resource],
          ),
        ],
        'thread-1',
        ChatScene.feedAi,
      );

      expect(merged, hasLength(1));
      expect(merged.single.messageId, 'canonical-file-user-1');
      expect(merged.single.resourceAttachments.single.displayName, '复盘.pdf');
    });

    test('submits a file-only turn with its optimistic resource row', () async {
      const resource = ChatResourceAttachment(
        kind: ChatResourceAttachmentKind.file,
        resourceId: 'resource-file-only-1',
        displayName: '访谈记录.pdf',
        mimeType: 'application/pdf',
        sizeBytes: 8192,
      );
      final api = _FakeChatApi(
        createdThread: _thread('created-file-1'),
        sentMutation: ChatTextMutation(
          message: _message(
            id: 'user-file-1',
            threadId: 'created-file-1',
            role: ChatMessageRole.user,
          ),
        ),
      );
      final controller = ChatController(api: api, scene: ChatScene.feedAi);
      final context = ChatContextEnvelope.create(
        purpose: ChatContextPurpose.general,
        references: const <ChatContextReference>[
          ChatContextReference(
            type: ChatContextReferenceType.file,
            id: 'resource-file-only-1',
          ),
        ],
      );

      expect(
        await controller.sendText(
          '',
          context: context,
          resourceAttachments: const <ChatResourceAttachment>[resource],
        ),
        isTrue,
      );
      expect(api.sentContents, <String>['']);
      final message = controller.state.messages.single;
      expect(message.visibleText, '已发送 1 项资料');
      expect(message.resourceAttachments.single.displayName, '访谈记录.pdf');
      expect(message.imageAttachments, isEmpty);
    });

    test(
      'submits an image-only turn and retains its Resource attachment',
      () async {
        final api = _FakeChatApi(
          createdThread: _thread('created-image-1'),
          sentMutation: ChatTextMutation(
            message: _message(
              id: 'user-image-1',
              threadId: 'created-image-1',
              role: ChatMessageRole.user,
            ),
          ),
        );
        final controller = ChatController(api: api, scene: ChatScene.feedAi);
        final context = ChatContextEnvelope.create(
          purpose: ChatContextPurpose.general,
          references: const <ChatContextReference>[
            ChatContextReference(
              type: ChatContextReferenceType.image,
              id: 'resource-image-1',
            ),
          ],
        );

        expect(await controller.sendText('', context: context), isTrue);
        expect(api.sentContents, <String>['']);
        expect(
          api.sentContexts.single?.references.single.type,
          ChatContextReferenceType.image,
        );
        expect(
          controller.state.messages.single.imageAttachments.single.resourceId,
          'resource-image-1',
        );
        expect(controller.state.messages.single.visibleText, '已发送 1 张图片');
      },
    );

    test('rejects an empty turn with only a local context reference', () async {
      final api = _FakeChatApi(createdThread: _thread('created-1'));
      final controller = ChatController(api: api, scene: ChatScene.feedAi);
      final context = ChatContextEnvelope.create(
        purpose: ChatContextPurpose.general,
        references: const <ChatContextReference>[
          ChatContextReference(
            type: ChatContextReferenceType.memoryNote,
            id: 'local-note-1',
          ),
        ],
      );

      expect(await controller.sendText('', context: context), isFalse);
      expect(api.createCalls, 0);
      expect(api.sentContents, isEmpty);
      expect(controller.state.lastErrorCode, 'CHAT_TEXT_INVALID');
    });

    test(
      'keeps a failed local message visible without reporting send success',
      () async {
        final api = _FakeChatApi(
          createdThread: _thread('created-1'),
          sendFailure: const AppFailure(
            code: 'NETWORK_REQUEST_FAILED',
            category: AppFailureCategory.network,
            message: 'network failed',
            userMessageKey: 'error.network.requestFailed',
            isRetryable: true,
          ),
        );
        final controller = ChatController(api: api, scene: ChatScene.feedAi);

        final sent = await controller.sendText('网络失败时不要伪造回答');

        expect(sent, isFalse);
        expect(controller.state.status, ChatControllerStatus.failed);
        expect(controller.state.lastErrorCode, 'NETWORK_REQUEST_FAILED');
        expect(controller.state.messages, hasLength(1));
        expect(
          controller.state.messages.single.localDelivery,
          ChatLocalDeliveryState.failed,
        );
        expect(
          controller.state.messages.where(
            (message) => message.role == ChatMessageRole.assistant,
          ),
          isEmpty,
        );
      },
    );

    test(
      'abandons only a text turn whose failure proves it was not accepted',
      () async {
        final uncertainController = ChatController(
          api: _FakeChatApi(
            createdThread: _thread('uncertain-send-thread'),
            sendResults: <ApiResult<ChatTextMutation>>[
              _retryableFailure<ChatTextMutation>('NETWORK_REQUEST_FAILED'),
            ],
          ),
          scene: ChatScene.feedAi,
        );
        addTearDown(uncertainController.dispose);

        expect(await uncertainController.sendText('结果不确定'), isFalse);
        final uncertainId = uncertainController.state.messages.single.messageId;
        expect(
          uncertainController.canRetryFailedTextMessage(uncertainId),
          isTrue,
        );
        expect(
          uncertainController.canAbandonFailedTextMessage(uncertainId),
          isFalse,
        );
        expect(
          await uncertainController.abandonFailedTextMessage(uncertainId),
          isFalse,
        );

        final database = AppDatabase();
        final repository = ChatThreadAliasRepository(
          dao: UserMetadataDao(database),
          preferencesDao: AppPreferencesDao(database),
          userScope: 'known-rejected-cache-user',
        );
        final rejectedController = ChatController(
          api: _FakeChatApi(
            createdThread: _thread('rejected-send-thread'),
            sendResults: <ApiResult<ChatTextMutation>>[
              _knownRejectedFailure<ChatTextMutation>('CHAT_REQUEST_REJECTED'),
            ],
          ),
          scene: ChatScene.feedAi,
          aliasRepository: repository,
        );

        expect(await rejectedController.sendText('明确拒绝'), isFalse);
        final rejectedId = rejectedController.state.messages.single.messageId;
        expect(
          rejectedController.canAbandonFailedTextMessage(rejectedId),
          isTrue,
        );
        rejectedController.flushPendingConversationCache();
        rejectedController.dispose();

        final reopenedController = ChatController(
          api: _FakeChatApi(),
          scene: ChatScene.feedAi,
          aliasRepository: repository,
        );
        addTearDown(reopenedController.dispose);
        expect(reopenedController.restoreCachedConversations(), isTrue);
        await reopenedController.selectThread('rejected-send-thread');

        expect(reopenedController.state.messages.single.messageId, rejectedId);
        expect(
          reopenedController.canAbandonFailedTextMessage(rejectedId),
          isTrue,
        );
        expect(
          await reopenedController.abandonFailedTextMessage(rejectedId),
          isTrue,
        );
        expect(reopenedController.state.messages, isEmpty);
        expect(reopenedController.state.turnState.phase, ChatTurnPhase.settled);
        expect(reopenedController.state.canSubmitUserTurn, isTrue);

        final afterRestart = ChatController(
          api: _FakeChatApi(),
          scene: ChatScene.feedAi,
          aliasRepository: repository,
        );
        addTearDown(afterRestart.dispose);
        expect(afterRestart.restoreCachedConversations(), isTrue);
        await afterRestart.selectThread('rejected-send-thread');
        expect(afterRestart.state.messages, isEmpty);
      },
    );

    test(
      'keeps a known-rejected turn when durable abandon persistence fails',
      () async {
        final database = AppDatabase();
        final queue = DatabaseWriteQueue();
        final repository = ChatThreadAliasRepository(
          dao: UserMetadataDao(database),
          preferencesDao: AppPreferencesDao(
            database,
            worker: const _FailingRecordWorker(),
            writeQueue: queue,
          ),
          userScope: 'failed-durable-abandon-user',
        );
        addTearDown(() async {
          try {
            await queue.dispose();
          } catch (_) {}
        });
        final controller = ChatController(
          api: _FakeChatApi(
            createdThread: _thread('failed-durable-abandon-thread'),
            sendResults: <ApiResult<ChatTextMutation>>[
              _knownRejectedFailure<ChatTextMutation>('CHAT_REQUEST_REJECTED'),
            ],
          ),
          scene: ChatScene.feedAi,
          aliasRepository: repository,
        );
        addTearDown(controller.dispose);

        expect(await controller.sendText('持久化失败时保留原消息'), isFalse);
        final failedId = controller.state.messages.single.messageId;
        controller.flushPendingConversationCache();

        expect(await controller.abandonFailedTextMessage(failedId), isFalse);
        expect(controller.state.messages.single.messageId, failedId);
        expect(controller.state.turnState.phase, ChatTurnPhase.failed);
        expect(controller.canAbandonFailedTextMessage(failedId), isTrue);
        expect(controller.canRetryFailedTextMessage(failedId), isTrue);

        final freshRepository = ChatThreadAliasRepository(
          dao: UserMetadataDao(database),
          preferencesDao: AppPreferencesDao(database),
          userScope: 'failed-durable-abandon-user',
        );
        final reopened = ChatController(
          api: _FakeChatApi(),
          scene: ChatScene.feedAi,
          aliasRepository: freshRepository,
        );
        addTearDown(reopened.dispose);
        expect(reopened.restoreCachedConversations(), isTrue);
        await reopened.selectThread('failed-durable-abandon-thread');
        expect(reopened.state.messages.single.messageId, failedId);
      },
    );

    test('latches retry and duplicate abandon during durable commit', () async {
      final database = AppDatabase();
      final queue = DatabaseWriteQueue();
      final worker = _GatedRecordWorker();
      final repository = ChatThreadAliasRepository(
        dao: UserMetadataDao(database),
        preferencesDao: AppPreferencesDao(
          database,
          worker: worker,
          writeQueue: queue,
        ),
        userScope: 'concurrent-durable-abandon-user',
      );
      addTearDown(() async {
        if (!worker.release.isCompleted) worker.release.complete();
        await queue.dispose();
      });
      final controller = ChatController(
        api: _FakeChatApi(
          createdThread: _thread('concurrent-durable-abandon-thread'),
          sendResults: <ApiResult<ChatTextMutation>>[
            _knownRejectedFailure<ChatTextMutation>('CHAT_REQUEST_REJECTED'),
          ],
        ),
        scene: ChatScene.feedAi,
        aliasRepository: repository,
      );
      addTearDown(controller.dispose);

      expect(await controller.sendText('结束期间不能重复操作'), isFalse);
      final failedId = controller.state.messages.single.messageId;
      controller.flushPendingConversationCache();
      final ending = controller.abandonFailedTextMessage(failedId);
      await worker.started.future;

      expect(controller.canRetryFailedTextMessage(failedId), isFalse);
      expect(controller.canAbandonFailedTextMessage(failedId), isFalse);
      expect(await controller.retryFailedTextMessage(failedId), isFalse);
      expect(await controller.abandonFailedTextMessage(failedId), isFalse);

      controller.startNewThread();
      worker.release.complete();
      expect(await ending, isTrue);
      expect(controller.state.activeThreadId, isNull);
      expect(controller.state.messages, isEmpty);
    });

    test('awaits caller checkpoint before text admission', () async {
      final checkpointStarted = Completer<void>();
      final checkpointRelease = Completer<bool>();
      final api = _FakeChatApi(
        createdThread: _thread('checkpoint-thread'),
        sentMutation: ChatTextMutation(
          message: _message(
            id: 'checkpoint-user',
            threadId: 'checkpoint-thread',
            role: ChatMessageRole.user,
          ),
        ),
      );
      final controller = ChatController(api: api, scene: ChatScene.feedAi);
      addTearDown(controller.dispose);

      final sending = controller.sendText(
        '先持久化 Thread 再发送',
        localMessageId: 'local-checkpoint-message',
        createThreadIdempotencyKey: 'canvas-create-key',
        messageIdempotencyKey: 'canvas-message-key',
        beforeMessageSubmit: (threadId) async {
          expect(threadId, 'checkpoint-thread');
          if (!checkpointStarted.isCompleted) checkpointStarted.complete();
          return checkpointRelease.future;
        },
      );
      await checkpointStarted.future;

      expect(api.createCalls, 1);
      expect(api.sentContents, isEmpty);
      expect(
        api.createdThreadIdempotencies.single.explicitKey,
        'canvas-create-key',
      );

      checkpointRelease.complete(true);
      expect(await sending, isTrue);
      expect(api.sentContents, <String>['先持久化 Thread 再发送']);
      expect(
        api.sentTextIdempotencies.single.explicitKey,
        'canvas-message-key',
      );
    });

    test('failed caller checkpoint never submits the message', () async {
      var checkpointCalls = 0;
      final api = _FakeChatApi(
        createdThread: _thread('failed-checkpoint-thread'),
        sentMutation: ChatTextMutation(
          message: _message(
            id: 'failed-checkpoint-user',
            threadId: 'failed-checkpoint-thread',
            role: ChatMessageRole.user,
          ),
        ),
      );
      final controller = ChatController(api: api, scene: ChatScene.feedAi);
      addTearDown(controller.dispose);

      expect(
        await controller.sendText(
          '不能越过失败的持久化检查点',
          localMessageId: 'local-failed-checkpoint-message',
          createThreadIdempotencyKey: 'failed-create-key',
          messageIdempotencyKey: 'failed-message-key',
          beforeMessageSubmit: (_) async {
            checkpointCalls += 1;
            return checkpointCalls > 1;
          },
        ),
        isFalse,
      );

      final failed = controller.state.messages.single;
      expect(api.sentContents, isEmpty);
      expect(failed.localDelivery, ChatLocalDeliveryState.failed);
      expect(controller.canAbandonFailedTextMessage(failed.messageId), isTrue);
      expect(controller.canRetryFailedTextMessage(failed.messageId), isTrue);

      expect(await controller.retryFailedTextMessage(failed.messageId), isTrue);
      expect(api.createCalls, 1);
      expect(api.sentContents, <String>['不能越过失败的持久化检查点']);
      expect(
        api.sentTextIdempotencies.single.explicitKey,
        'failed-message-key',
      );
    });

    test('recovers an orphaned cached pending text turn as failed', () async {
      final database = AppDatabase();
      final repository = ChatThreadAliasRepository(
        dao: UserMetadataDao(database),
        preferencesDao: AppPreferencesDao(database),
        userScope: 'orphaned-pending-cache-user',
      );
      final thread = _thread(
        'orphaned-pending-thread',
        updatedAt: DateTime.utc(2026, 9, 5),
      );
      final pending = _message(
        id: 'local-orphaned-pending-message',
        threadId: thread.threadId,
        role: ChatMessageRole.user,
        text: '进程退出前已受理的本地消息',
        status: 'pending',
      ).copyWith(localDelivery: ChatLocalDeliveryState.pending);
      repository.saveConversationCache(
        scene: ChatScene.feedAi,
        purpose: ChatConversationPurpose.general,
        threads: <ChatThread>[thread],
        messagesByThread: <String, List<ChatMessage>>{
          thread.threadId: <ChatMessage>[pending],
        },
      );
      final controller = ChatController(
        api: _FakeChatApi(),
        scene: ChatScene.feedAi,
        aliasRepository: repository,
      );
      addTearDown(controller.dispose);

      expect(controller.restoreCachedConversations(), isTrue);
      await controller.selectThread(thread.threadId);

      final recovered = controller.state.messages.single;
      expect(recovered.messageId, pending.messageId);
      expect(recovered.localDelivery, ChatLocalDeliveryState.failed);
      expect(controller.state.turnState.phase, ChatTurnPhase.failed);
      expect(
        controller.state.lastErrorCode,
        'CHAT_LOCAL_TURN_RECOVERY_REQUIRED',
      );
      expect(
        controller.canRetryFailedTextMessage(recovered.messageId),
        isFalse,
      );
      expect(
        controller.canAbandonFailedTextMessage(recovered.messageId),
        isFalse,
      );
      expect(
        controller.canAbandonFailedTextMessage(
          recovered.messageId,
          hasDurableNonAdmissionProof: true,
        ),
        isTrue,
      );
      expect(
        await controller.abandonFailedTextMessage(
          recovered.messageId,
          hasDurableNonAdmissionProof: true,
        ),
        isTrue,
      );
      expect(controller.state.messages, isEmpty);
      expect(controller.state.turnState.phase, ChatTurnPhase.settled);

      final afterRestart = ChatController(
        api: _FakeChatApi(),
        scene: ChatScene.feedAi,
        aliasRepository: repository,
      );
      addTearDown(afterRestart.dispose);
      expect(afterRestart.restoreCachedConversations(), isTrue);
      await afterRestart.selectThread(thread.threadId);
      expect(afterRestart.state.messages, isEmpty);
    });

    test(
      'retries a failed first text turn in place with its exact envelope',
      () async {
        const threadId = 'retry-first-text-thread';
        const contentLineId = 'retry-content-line-1';
        final api = _FakeChatApi(
          createdThread: _thread(threadId),
          sendResults: <ApiResult<ChatTextMutation>>[
            _retryableFailure<ChatTextMutation>('NETWORK_REQUEST_FAILED'),
            _success(
              ChatTextMutation(
                message: _message(
                  id: 'server-retry-user-1',
                  threadId: threadId,
                  role: ChatMessageRole.user,
                ),
              ),
              SubmissionKeyStore.empty,
            ),
          ],
        );
        final controller = ChatController(
          api: api,
          scene: ChatScene.feedAi,
          initialAgentProfileId: standardCreationChatAgentProfileId,
        );
        addTearDown(controller.dispose);
        final context = ChatContextEnvelope.create(
          purpose: ChatContextPurpose.general,
          contentLineId: contentLineId,
          references: const <ChatContextReference>[
            ChatContextReference(
              type: ChatContextReferenceType.image,
              id: 'retry-image-1',
            ),
            ChatContextReference(
              type: ChatContextReferenceType.material,
              id: 'retry-note-1',
              revision: 'retry-note-revision-1',
            ),
          ],
        )!;
        final assetReferences = <ChatAssetReference>[
          const ChatAssetReference(assetId: 'retry-note-1', title: '复盘资料'),
        ];
        final reservedMessageId = controller.reserveTextMessageId();

        expect(
          await controller.sendText(
            '请继续分析',
            contentLineId: contentLineId,
            context: context,
            assetReferences: assetReferences,
            localMessageId: reservedMessageId,
          ),
          isFalse,
        );
        final failed = controller.state.messages.single;
        final messageId = failed.messageId;
        expect(messageId, reservedMessageId);
        final createdAt = failed.createdAt;
        assetReferences.clear();
        final retryDeliveryStates = <ChatLocalDeliveryState>[];
        void observeRetryState() {
          final message = controller.state.messages
              .where((candidate) => candidate.messageId == messageId)
              .firstOrNull;
          if (message != null) retryDeliveryStates.add(message.localDelivery);
        }

        controller.addListener(observeRetryState);

        expect(controller.canRetryFailedTextMessage(messageId), isTrue);
        expect(await controller.retryFailedTextMessage(messageId), isTrue);
        controller.removeListener(observeRetryState);

        final retried = controller.state.messages.single;
        expect(retried.messageId, messageId);
        expect(retried.createdAt, createdAt);
        expect(retried.localDelivery, ChatLocalDeliveryState.server);
        expect(retried.imageAttachments.single.resourceId, 'retry-image-1');
        expect(retried.assetReferences.single.title, '复盘资料');
        expect(api.createCalls, 1);
        expect(api.sentContents, <String>['请继续分析', '请继续分析']);
        expect(api.sentContentLineIds, <String?>[contentLineId, contentLineId]);
        expect(api.sentAgentProfileIds, <String?>[
          standardCreationChatAgentProfileId,
          standardCreationChatAgentProfileId,
        ]);
        expect(identical(api.sentContexts[0], context), isTrue);
        expect(identical(api.sentContexts[0], api.sentContexts[1]), isTrue);
        expect(
          identical(api.sentTextIdempotencies[0], api.sentTextIdempotencies[1]),
          isTrue,
        );
        expect(api.sentTextIdempotencies.first.localDraftId, messageId);
        expect(api.sentTextIdempotencies.first.automaticRetry, isTrue);
        expect(
          retryDeliveryStates,
          containsAllInOrder(<ChatLocalDeliveryState>[
            ChatLocalDeliveryState.pending,
            ChatLocalDeliveryState.server,
          ]),
        );
        expect(controller.canRetryFailedTextMessage(messageId), isFalse);
      },
    );

    test('rejects malformed or reused caller-reserved message IDs', () async {
      const threadId = 'reserved-id-thread';
      final api = _FakeChatApi(
        createdThread: _thread(threadId),
        sendResults: <ApiResult<ChatTextMutation>>[
          _success(
            ChatTextMutation(
              message: _message(
                id: 'reserved-server-message',
                threadId: threadId,
                role: ChatMessageRole.user,
              ),
            ),
            SubmissionKeyStore.empty,
          ),
        ],
      );
      final controller = ChatController(api: api, scene: ChatScene.feedAi);
      addTearDown(controller.dispose);

      expect(
        await controller.sendText('无效 ID', localMessageId: 'not safe/id'),
        isFalse,
      );
      expect(api.createCalls, 0);

      final messageId = controller.reserveTextMessageId();
      expect(
        await controller.sendText('首次发送', localMessageId: messageId),
        isTrue,
      );
      expect(controller.state.messages.single.messageId, messageId);
      expect(
        await controller.sendText('重复发送', localMessageId: messageId),
        isFalse,
      );
      expect(api.sentContents, <String>['首次发送']);
    });

    test(
      'keeps the same failed text retry candidate after another failure',
      () async {
        const threadId = 'retry-fails-again-thread';
        final api = _FakeChatApi(
          createdThread: _thread(threadId),
          sendResults: <ApiResult<ChatTextMutation>>[
            _retryableFailure<ChatTextMutation>('NETWORK_REQUEST_FAILED'),
            _retryableFailure<ChatTextMutation>('NETWORK_REQUEST_FAILED'),
          ],
        );
        final controller = ChatController(api: api, scene: ChatScene.feedAi);
        addTearDown(controller.dispose);

        expect(await controller.sendText('失败后继续重试'), isFalse);
        final firstFailure = controller.state.messages.single;

        expect(
          await controller.retryFailedTextMessage(firstFailure.messageId),
          isFalse,
        );

        final secondFailure = controller.state.messages.single;
        expect(secondFailure.messageId, firstFailure.messageId);
        expect(secondFailure.createdAt, firstFailure.createdAt);
        expect(secondFailure.localDelivery, ChatLocalDeliveryState.failed);
        expect(controller.state.messages, hasLength(1));
        expect(
          controller.canRetryFailedTextMessage(firstFailure.messageId),
          isTrue,
        );
        expect(api.sentContents, <String>['失败后继续重试', '失败后继续重试']);
        expect(
          identical(api.sentTextIdempotencies[0], api.sentTextIdempotencies[1]),
          isTrue,
        );
      },
    );

    test('keeps at most twenty failed text retry envelopes', () async {
      final api = _FakeChatApi(
        createdThread: _thread('bounded-retry-thread'),
        sendFailure: const AppFailure(
          code: 'NETWORK_REQUEST_FAILED',
          category: AppFailureCategory.network,
          message: 'network failed',
          userMessageKey: 'error.network.requestFailed',
          isRetryable: true,
        ),
      );
      final controller = ChatController(api: api, scene: ChatScene.feedAi);
      addTearDown(controller.dispose);

      for (var index = 0; index < 21; index++) {
        expect(await controller.sendText('失败消息 $index'), isFalse);
      }

      expect(controller.state.messages, hasLength(21));
      for (final message in controller.state.messages.take(20)) {
        expect(
          controller.canRetryFailedTextMessage(message.messageId),
          isFalse,
        );
      }
      expect(
        controller.canRetryFailedTextMessage(
          controller.state.messages.last.messageId,
        ),
        isTrue,
      );
    });

    test(
      'submits a completed voice resource only to an active Feed AI thread',
      () async {
        final api = _FakeChatApi(
          threads: <ChatThread>[_thread('feed-1')],
          details: <String, ChatThreadDetail>{
            'feed-1': ChatThreadDetail(
              thread: _thread('feed-1'),
              messages: const <ChatMessage>[],
            ),
          },
          sentVoiceMutation: ChatVoiceMutation(
            message: _message(
              id: 'voice-1',
              threadId: 'feed-1',
              role: ChatMessageRole.user,
              contentType: ChatMessageContentType.voice,
            ),
          ),
        );
        final controller = ChatController(api: api, scene: ChatScene.feedAi);
        await controller.loadThreads();

        final sent = await controller.sendVoiceResource(
          resource: _voiceResource(),
          durationSeconds: 6,
        );

        expect(sent, isTrue);
        expect(api.createCalls, 0);
        expect(api.voiceThreadIds, <String>['feed-1']);
        expect(api.voiceResourceIds, <String>['resource-voice-1']);
        expect(api.voiceDurations, <int>[6]);
        expect(controller.state.status, ChatControllerStatus.ready);
        expect(controller.state.messages, hasLength(1));
        expect(
          controller.state.messages.single.contentType,
          ChatMessageContentType.voice,
        );
        expect(
          controller.state.messages.single.localDelivery,
          ChatLocalDeliveryState.server,
        );
      },
    );

    test(
      'creates a content-line thread before the first voice resource',
      () async {
        final api = _FakeChatApi(
          createdThread: _thread('created-1'),
          sentVoiceMutation: ChatVoiceMutation(
            message: _message(
              id: 'voice-1',
              threadId: 'created-1',
              role: ChatMessageRole.user,
              contentType: ChatMessageContentType.voice,
            ),
          ),
        );
        final controller = ChatController(api: api, scene: ChatScene.feedAi);

        final sent = await controller.sendVoiceResource(
          resource: _voiceResource(),
          durationSeconds: 6,
          contentLineId: 'line-1',
        );

        expect(sent, isTrue);
        expect(api.createCalls, 1);
        expect(api.createContentLineIds, <String?>['line-1']);
        expect(api.voiceThreadIds, <String>['created-1']);
        expect(api.voiceContentLineIds, <String?>['line-1']);
        expect(controller.state.activeThreadId, 'created-1');
      },
    );

    test(
      'rejects an active-thread resource from a non-voice upload scene',
      () async {
        final api = _FakeChatApi(
          threads: <ChatThread>[_thread('feed-1')],
          details: <String, ChatThreadDetail>{
            'feed-1': ChatThreadDetail(
              thread: _thread('feed-1'),
              messages: const <ChatMessage>[],
            ),
          },
        );
        final controller = ChatController(api: api, scene: ChatScene.feedAi);
        await controller.loadThreads();

        final sent = await controller.sendVoiceResource(
          resource: _voiceResource(sourceScene: 'raw_material'),
          durationSeconds: 6,
        );

        expect(sent, isFalse);
        expect(api.voiceThreadIds, isEmpty);
        expect(controller.state.lastErrorCode, 'CHAT_VOICE_RESOURCE_INVALID');
      },
    );

    test('keeps a failed pending voice message on an API failure', () async {
      final api = _FakeChatApi(
        threads: <ChatThread>[_thread('feed-1')],
        details: <String, ChatThreadDetail>{
          'feed-1': ChatThreadDetail(
            thread: _thread('feed-1'),
            messages: const <ChatMessage>[],
          ),
        },
        voiceSendFailure: const AppFailure(
          code: 'NETWORK_REQUEST_FAILED',
          category: AppFailureCategory.network,
          message: 'network failed',
          userMessageKey: 'error.network.requestFailed',
          isRetryable: true,
        ),
      );
      final controller = ChatController(api: api, scene: ChatScene.feedAi);
      await controller.loadThreads();

      final sent = await controller.sendVoiceResource(
        resource: _voiceResource(),
        durationSeconds: 6,
      );

      expect(sent, isFalse);
      expect(controller.state.status, ChatControllerStatus.failed);
      expect(controller.state.lastErrorCode, 'NETWORK_REQUEST_FAILED');
      expect(controller.state.messages, hasLength(1));
      expect(
        controller.state.messages.single.contentType,
        ChatMessageContentType.voice,
      );
      expect(
        controller.state.messages.single.localDelivery,
        ChatLocalDeliveryState.failed,
      );
      expect(
        controller.canRetryFailedTextMessage(
          controller.state.messages.single.messageId,
        ),
        isFalse,
      );
    });

    test(
      'keeps a failed pending voice message when the server response is invalid',
      () async {
        final api = _FakeChatApi(
          threads: <ChatThread>[_thread('feed-1')],
          details: <String, ChatThreadDetail>{
            'feed-1': ChatThreadDetail(
              thread: _thread('feed-1'),
              messages: const <ChatMessage>[],
            ),
          },
          sentVoiceMutation: ChatVoiceMutation(
            message: _message(
              id: 'wrong-type',
              threadId: 'feed-1',
              role: ChatMessageRole.user,
            ),
          ),
        );
        final controller = ChatController(api: api, scene: ChatScene.feedAi);
        await controller.loadThreads();

        final sent = await controller.sendVoiceResource(
          resource: _voiceResource(),
          durationSeconds: 6,
        );

        expect(sent, isFalse);
        expect(controller.state.status, ChatControllerStatus.failed);
        expect(
          controller.state.lastErrorCode,
          'CHAT_VOICE_MUTATION_RESPONSE_INVALID',
        );
        expect(controller.state.messages, hasLength(1));
        expect(
          controller.state.messages.single.contentType,
          ChatMessageContentType.voice,
        );
        expect(
          controller.state.messages.single.localDelivery,
          ChatLocalDeliveryState.failed,
        );
      },
    );

    test(
      'propagates active and renamed thread display titles to task metadata',
      () async {
        const threadId = 'named-active-thread';
        final thread = _thread(threadId).copyWith(
          title: '服务端会话',
          activeRuns: const <ChatActiveRun>[
            ChatActiveRun(agentRunId: 'named-active-run', status: 'running'),
          ],
        );
        final tracker = _FakeChatRunTracker();
        final api = _SuccessfulThreadMetadataChatApi(
          threads: <ChatThread>[thread],
          details: <String, ChatThreadDetail>{
            threadId: ChatThreadDetail(
              thread: thread,
              messages: const <ChatMessage>[],
            ),
          },
        );
        final controller = ChatController(
          api: api,
          scene: ChatScene.feedAi,
          runTracker: tracker,
        );
        addTearDown(controller.dispose);

        await controller.loadThreads();
        await Future<void>.delayed(Duration.zero);
        expect(
          tracker.subjectCalls,
          contains((threadId: threadId, subjectTitle: '服务端会话')),
        );
        expect(tracker.serverActiveCalls, isNotEmpty);
        expect(
          tracker.serverActiveCalls.every((call) => call.threadId == threadId),
          isTrue,
        );

        expect(controller.renameThread(threadId, '客户回访'), isTrue);
        await Future<void>.delayed(Duration.zero);
        expect(tracker.subjectCalls.last.subjectTitle, '客户回访');

        expect(controller.resetThreadName(threadId), isTrue);
        await Future<void>.delayed(Duration.zero);
        expect(tracker.subjectCalls.last.subjectTitle, '服务端会话');

        expect(await controller.renameThreadRemote(threadId, '年度复盘'), isTrue);
        await Future<void>.delayed(Duration.zero);
        expect(tracker.subjectCalls.last.subjectTitle, '年度复盘');
      },
    );

    test(
      'persists local aliases per user and restores the server title',
      () async {
        final database = AppDatabase();
        final dao = UserMetadataDao(database);
        final repository = ChatThreadAliasRepository(
          dao: dao,
          preferencesDao: AppPreferencesDao(database),
          userScope: 'chat-user-a',
        );
        final api = _FakeChatApi(
          threads: <ChatThread>[_thread('feed-1')],
          details: <String, ChatThreadDetail>{
            'feed-1': ChatThreadDetail(
              thread: _thread('feed-1'),
              messages: const <ChatMessage>[],
            ),
          },
        );
        final first = ChatController(
          api: api,
          scene: ChatScene.feedAi,
          aliasRepository: repository,
        );
        await first.loadThreads();

        expect(first.renameThread('feed-1', '  客户回访  '), isTrue);
        expect(first.state.threads.single.title, '会话 feed-1');
        expect(first.state.threads.single.displayTitle, '客户回访');

        final recovered = ChatController(
          api: api,
          scene: ChatScene.feedAi,
          aliasRepository: repository,
        );
        await recovered.loadThreads();
        expect(recovered.state.threads.single.displayTitle, '客户回访');

        final otherUser = ChatController(
          api: api,
          scene: ChatScene.feedAi,
          aliasRepository: ChatThreadAliasRepository(
            dao: dao,
            preferencesDao: AppPreferencesDao(database),
            userScope: 'chat-user-b',
          ),
        );
        await otherUser.loadThreads();
        expect(otherUser.state.threads.single.displayTitle, '会话 feed-1');

        expect(recovered.resetThreadName('feed-1'), isTrue);
        expect(recovered.state.threads.single.localAlias, isNull);
        expect(recovered.state.threads.single.displayTitle, '会话 feed-1');
      },
    );

    test(
      'persists deep-positioning thread purpose and restores safe history',
      () async {
        final database = AppDatabase();
        final dao = UserMetadataDao(database);
        final preferences = AppPreferencesDao(database);
        final repository = ChatThreadAliasRepository(
          dao: dao,
          preferencesDao: preferences,
          userScope: 'chat-user-a',
        );
        final api = _FakeChatApi(
          threads: <ChatThread>[
            _thread('positioning-1', updatedAt: DateTime.utc(2026, 7, 27)),
            _thread('general-1', updatedAt: DateTime.utc(2026, 7, 26)),
          ],
          details: <String, ChatThreadDetail>{
            'positioning-1': ChatThreadDetail(
              thread: _thread('positioning-1'),
              messages: <ChatMessage>[
                _message(
                  id: 'positioning-user-safe',
                  threadId: 'positioning-1',
                  role: ChatMessageRole.user,
                  text: '【深度定位对话】\n内部定位提示不可见\n\n用户回答：我擅长把复杂问题讲清楚',
                ),
                _message(
                  id: 'positioning-user-malformed',
                  threadId: 'positioning-1',
                  role: ChatMessageRole.user,
                  text: '【深度定位对话】内部提示缺少用户回答边界',
                ),
                _message(
                  id: 'positioning-assistant',
                  threadId: 'positioning-1',
                  role: ChatMessageRole.assistant,
                  text: '你最想服务哪一类人？',
                ),
              ],
            ),
            'general-1': ChatThreadDetail(
              thread: _thread('general-1'),
              messages: const <ChatMessage>[],
            ),
          },
          createdThread: _thread('positioning-1'),
          sentMutation: ChatTextMutation(
            message: _message(
              id: 'created-positioning-user',
              threadId: 'positioning-1',
              role: ChatMessageRole.user,
            ),
          ),
        );
        final first = ChatController(
          api: api,
          scene: ChatScene.feedAi,
          aliasRepository: repository,
          conversationPurpose: ChatConversationPurpose.deepPositioning,
        );

        expect(
          await first.sendText(
            '我擅长把复杂问题讲清楚',
            context: ChatContextEnvelope.create(
              purpose: ChatContextPurpose.deepPositioning,
              includeAccountProfile: true,
            ),
          ),
          isTrue,
        );
        expect(
          repository.recentThreadIdForPurpose(
            scene: ChatScene.feedAi,
            purpose: ChatConversationPurpose.deepPositioning,
          ),
          'positioning-1',
        );
        // Persist one canonical server projection before rebuilding the
        // controller. Reopening must render this local snapshot without
        // repeating the detail request.
        await first.selectThread('positioning-1', forceRemote: true);

        final ordinary = ChatController(
          api: api,
          scene: ChatScene.feedAi,
          aliasRepository: repository,
        );
        await ordinary.loadThreads();
        expect(
          ordinary.state.threads.map((thread) => thread.threadId),
          <String>['general-1'],
        );

        final listCallsBeforeRestore = api.listCalls;
        final recovered = ChatController(
          api: api,
          scene: ChatScene.feedAi,
          aliasRepository: ChatThreadAliasRepository(
            dao: dao,
            preferencesDao: AppPreferencesDao(database),
            userScope: 'chat-user-a',
          ),
          conversationPurpose: ChatConversationPurpose.deepPositioning,
        );
        expect(await recovered.restoreRecentPurposeThread(), isTrue);
        expect(api.listCalls, listCallsBeforeRestore);
        expect(recovered.state.activeThreadId, 'positioning-1');
        expect(
          recovered.state.messages.map((message) => message.visibleText),
          <String?>['我擅长把复杂问题讲清楚', '已提交一条定位回答', '你最想服务哪一类人？'],
        );
        expect(
          recovered.state.messages
              .map((message) => message.visibleText ?? '')
              .join('\n'),
          isNot(contains('内部定位提示不可见')),
        );

        final otherAccount = ChatController(
          api: api,
          scene: ChatScene.feedAi,
          aliasRepository: ChatThreadAliasRepository(
            dao: dao,
            preferencesDao: AppPreferencesDao(database),
            userScope: 'chat-user-b',
          ),
        );
        await otherAccount.loadThreads();
        expect(
          otherAccount.state.threads.map((thread) => thread.threadId),
          contains('positioning-1'),
        );
      },
    );

    test(
      'hydrates an explicit unmarked deep thread only after work-ai readback',
      () async {
        final database = AppDatabase();
        final repository = ChatThreadAliasRepository(
          dao: UserMetadataDao(database),
          preferencesDao: AppPreferencesDao(database),
          userScope: 'chat-explicit-deep-user',
        );
        const deepThreadId = 'deep-explicit-1';
        const generalThreadId = 'general-explicit-1';
        final api = _FakeChatApi(
          details: <String, ChatThreadDetail>{
            deepThreadId: const ChatThreadDetail(
              thread: ChatThread(
                threadId: deepThreadId,
                scene: ChatScene.workAi,
                title: '进一步定位',
              ),
              messages: <ChatMessage>[],
            ),
            generalThreadId: const ChatThreadDetail(
              thread: ChatThread(
                threadId: generalThreadId,
                scene: ChatScene.feedAi,
                title: '普通历史会话',
              ),
              messages: <ChatMessage>[],
            ),
          },
        );
        final controller = ChatController(
          api: api,
          scene: ChatScene.feedAi,
          aliasRepository: repository,
          conversationPurpose: ChatConversationPurpose.deepPositioning,
        );

        await controller.selectThread(deepThreadId, forceRemote: true);
        expect(controller.state.lastErrorCode, 'CHAT_THREAD_PURPOSE_MISMATCH');
        expect(api.detailCalls, isEmpty);

        await controller.selectThread(
          deepThreadId,
          forceRemote: true,
          allowUnassignedPurposeHydration: true,
        );
        expect(controller.state.status, ChatControllerStatus.ready);
        expect(controller.state.activeThreadId, deepThreadId);
        expect(
          repository.threadIdsForPurpose(
            scene: ChatScene.feedAi,
            purpose: ChatConversationPurpose.deepPositioning,
          ),
          contains(deepThreadId),
        );

        final rejected = ChatController(
          api: api,
          scene: ChatScene.feedAi,
          aliasRepository: repository,
          conversationPurpose: ChatConversationPurpose.deepPositioning,
        );
        await rejected.selectThread(
          generalThreadId,
          forceRemote: true,
          allowUnassignedPurposeHydration: true,
        );
        expect(rejected.state.activeThreadId, isNull);
        expect(rejected.state.status, ChatControllerStatus.failed);
        expect(rejected.state.lastErrorCode, 'CHAT_THREAD_SCENE_MISMATCH');
        expect(
          repository.threadIdsForPurpose(
            scene: ChatScene.feedAi,
            purpose: ChatConversationPurpose.deepPositioning,
          ),
          isNot(contains(generalThreadId)),
        );
      },
    );

    test(
      'restores a locked historical Agent when server projections omit it',
      () async {
        final database = AppDatabase();
        final repository = ChatThreadAliasRepository(
          dao: UserMetadataDao(database),
          preferencesDao: AppPreferencesDao(database),
          userScope: 'chat-agent-lock-user',
        );
        final thread = _thread('visual-history');
        final api = _FakeChatApi(
          threads: <ChatThread>[thread],
          createdThread: thread,
          details: <String, ChatThreadDetail>{
            thread.threadId: ChatThreadDetail(
              thread: thread,
              messages: const <ChatMessage>[],
            ),
          },
          sentMutation: ChatTextMutation(
            message: _message(
              id: 'visual-history-user',
              threadId: thread.threadId,
              role: ChatMessageRole.user,
            ),
          ),
        );
        final first = ChatController(
          api: api,
          scene: ChatScene.feedAi,
          aliasRepository: repository,
          initialAgentProfileId: 'renshe_content',
        );
        expect(await first.sendText('创建个人IP对话'), isTrue);
        expect(
          repository.agentProfileFor(
            scene: ChatScene.feedAi,
            threadId: thread.threadId,
          ),
          'renshe_content',
        );

        final reopened = ChatController(
          api: api,
          scene: ChatScene.feedAi,
          aliasRepository: ChatThreadAliasRepository(
            dao: UserMetadataDao(database),
            preferencesDao: AppPreferencesDao(database),
            userScope: 'chat-agent-lock-user',
          ),
          initialAgentProfileId: 'visual_chat',
        );
        await reopened.loadThreads(refresh: true, selectLatest: false);
        await reopened.selectThread(thread.threadId, forceRemote: true);

        expect(reopened.state.threads.single.agentProfileId, 'renshe_content');
        expect(reopened.activeAgentProfileId, 'renshe_content');
        expect(await reopened.sendText('继续分析'), isTrue);
        expect(api.sentAgentProfileIds, <String?>[
          'renshe_content',
          'renshe_content',
        ]);

        final otherAccount = ChatThreadAliasRepository(
          dao: UserMetadataDao(database),
          preferencesDao: AppPreferencesDao(database),
          userScope: 'chat-agent-lock-other-account',
        );
        expect(
          otherAccount.agentProfileFor(
            scene: ChatScene.feedAi,
            threadId: thread.threadId,
          ),
          isNull,
        );
      },
    );

    test(
      'thread-bound scope resolves once and keeps Agent history isolated',
      () async {
        final database = AppDatabase();
        final repository = ChatThreadAliasRepository(
          dao: UserMetadataDao(database),
          preferencesDao: AppPreferencesDao(database),
          userScope: 'chat-thread-bound-agent-user',
        );
        final ordinaryThread = _thread(
          'ordinary-cached-history',
          agentProfileId: standardCreationChatAgentProfileId,
        );
        final videoCachedThread = _thread(
          'video-cached-history',
          agentProfileId: 'video_analysis',
        );
        repository.saveConversationCache(
          scene: ChatScene.feedAi,
          purpose: ChatConversationPurpose.general,
          agentProfileId: standardCreationChatAgentProfileId,
          threads: <ChatThread>[ordinaryThread],
          messagesByThread: <String, List<ChatMessage>>{
            ordinaryThread.threadId: <ChatMessage>[
              _message(
                id: 'ordinary-cached-message',
                threadId: ordinaryThread.threadId,
                role: ChatMessageRole.assistant,
                text: '普通聊一聊历史',
              ),
            ],
          },
        );
        repository.saveConversationCache(
          scene: ChatScene.feedAi,
          purpose: ChatConversationPurpose.general,
          agentProfileId: 'video_analysis',
          threads: <ChatThread>[videoCachedThread],
          messagesByThread: <String, List<ChatMessage>>{
            videoCachedThread.threadId: <ChatMessage>[
              _message(
                id: 'video-cached-message',
                threadId: videoCachedThread.threadId,
                role: ChatMessageRole.assistant,
                text: '视频分析历史',
              ),
            ],
          },
        );

        final exactVideoThread = _thread(
          'video-exact-thread',
          agentProfileId: 'video_analysis',
        );
        final conflictingThread = _thread(
          'persona-conflicting-thread',
          agentProfileId: 'renshe_content',
        );
        final api = _FakeChatApi(
          details: <String, ChatThreadDetail>{
            exactVideoThread.threadId: ChatThreadDetail(
              thread: exactVideoThread,
              messages: <ChatMessage>[
                _message(
                  id: 'video-exact-message',
                  threadId: exactVideoThread.threadId,
                  role: ChatMessageRole.assistant,
                  text: '精确视频会话',
                ),
              ],
            ),
            conflictingThread.threadId: ChatThreadDetail(
              thread: conflictingThread,
              messages: const <ChatMessage>[],
            ),
          },
        );
        final controller = ChatController(
          api: api,
          scene: ChatScene.feedAi,
          aliasRepository: repository,
          agentScope: const ChatAgentScope.threadBound(),
        );
        addTearDown(controller.dispose);

        expect(controller.isAgentScopeResolved, isFalse);
        expect(controller.activeAgentProfileId, isNull);
        expect(controller.restoreCachedConversations(), isFalse);
        expect(controller.historyThreads, isEmpty);
        await controller.loadThreads(refresh: true);
        await controller.refreshCompleteHistory(force: true);
        expect(await controller.restoreRecentPurposeThread(), isFalse);
        expect(await controller.sendText('不应在 Profile 未解析时发送'), isFalse);
        expect(api.listCalls, 0);
        expect(api.createCalls, 0);

        await controller.selectThread(
          exactVideoThread.threadId,
          forceRemote: true,
        );

        expect(controller.isAgentScopeResolved, isTrue);
        expect(controller.activeAgentProfileId, 'video_analysis');
        expect(controller.state.activeThreadId, exactVideoThread.threadId);
        expect(controller.state.messages.single.visibleText, '精确视频会话');
        expect(
          controller.historyThreads.map((thread) => thread.threadId),
          containsAll(<String>[
            exactVideoThread.threadId,
            videoCachedThread.threadId,
          ]),
        );
        expect(
          controller.historyThreads.map((thread) => thread.threadId),
          isNot(contains(ordinaryThread.threadId)),
        );

        await controller.selectThread(
          conflictingThread.threadId,
          forceRemote: true,
        );

        expect(controller.activeAgentProfileId, 'video_analysis');
        expect(controller.state.activeThreadId, exactVideoThread.threadId);
        expect(
          controller.state.lastErrorCode,
          'CHAT_THREAD_AGENT_PROFILE_MISMATCH',
        );

        final ordinaryController = ChatController(
          api: api,
          scene: ChatScene.feedAi,
          aliasRepository: repository,
          agentScope: const ChatAgentScope.fixed(
            standardCreationChatAgentProfileId,
          ),
        );
        addTearDown(ordinaryController.dispose);
        expect(ordinaryController.restoreCachedConversations(), isTrue);
        expect(
          ordinaryController.historyThreads.map((thread) => thread.threadId),
          <String>[ordinaryThread.threadId],
        );
      },
    );

    test(
      'aggregate history hydrates and retains mixed Agent provenance',
      () async {
        final database = AppDatabase();
        final repository = ChatThreadAliasRepository(
          dao: UserMetadataDao(database),
          preferencesDao: AppPreferencesDao(database),
          userScope: 'aggregate-history-user',
        );
        const listedThreads = <ChatThread>[
          ChatThread(
            threadId: 'aggregate-ordinary',
            scene: ChatScene.feedAi,
            title: '普通会话',
          ),
          ChatThread(
            threadId: 'aggregate-persona',
            scene: ChatScene.feedAi,
            title: '个人 IP 会话',
          ),
          ChatThread(
            threadId: 'aggregate-lead',
            scene: ChatScene.feedAi,
            title: '获客会话',
          ),
        ];
        final api = _FakeChatApi(
          threads: listedThreads,
          sentMutation: ChatTextMutation(
            message: _message(
              id: 'aggregate-persona-next-user',
              threadId: 'aggregate-persona',
              role: ChatMessageRole.user,
            ),
          ),
          details: <String, ChatThreadDetail>{
            for (final thread in listedThreads)
              thread.threadId: ChatThreadDetail(
                thread: thread.copyWith(
                  agentProfileId: switch (thread.threadId) {
                    'aggregate-persona' => 'renshe_content',
                    'aggregate-lead' => 'huoke_content',
                    _ => standardCreationChatAgentProfileId,
                  },
                ),
                messages: const <ChatMessage>[],
              ),
          },
        );
        final aggregate = ChatController(
          api: api,
          scene: ChatScene.feedAi,
          aliasRepository: repository,
          agentScope: const ChatAgentScope.allProfiles(),
        );
        addTearDown(aggregate.dispose);

        await aggregate.refreshCompleteHistory(force: true);

        expect(
          aggregate.historyThreads.map((thread) => thread.sourceLabel).toSet(),
          <String>{'普通聊一聊', '个人 IP', '获客营销'},
        );
        expect(api.detailCalls.toSet(), <String>{
          'aggregate-ordinary',
          'aggregate-persona',
          'aggregate-lead',
        });

        await aggregate.selectThread('aggregate-persona', forceRemote: true);

        expect(aggregate.activeAgentProfileId, 'renshe_content');
        expect(
          aggregate.historyThreads.map((thread) => thread.sourceLabel).toSet(),
          <String>{'普通聊一聊', '个人 IP', '获客营销'},
        );
        expect(await aggregate.sendText('继续个人 IP 对话'), isTrue);
        expect(api.sentAgentProfileIds.last, 'renshe_content');

        final ordinary = ChatController(
          api: api,
          scene: ChatScene.feedAi,
          aliasRepository: repository,
          agentScope: const ChatAgentScope.fixed(
            standardCreationChatAgentProfileId,
          ),
        );
        addTearDown(ordinary.dispose);
        await ordinary.refreshCompleteHistory(force: true);
        expect(
          ordinary.historyThreads.map((thread) => thread.threadId),
          <String>['aggregate-ordinary'],
        );
      },
    );

    test(
      'hydrates a titled cross-device history Agent and keeps it for send',
      () async {
        final database = AppDatabase();
        final repository = ChatThreadAliasRepository(
          dao: UserMetadataDao(database),
          preferencesDao: AppPreferencesDao(database),
          userScope: 'cross-device-agent-user',
        );
        const threadId = 'cross-device-video-history';
        const listedThread = ChatThread(
          threadId: threadId,
          scene: ChatScene.feedAi,
          title: '视频复盘',
          firstUserMessageText: '继续分析这个视频',
        );
        final detailThread = listedThread.copyWith(
          agentProfileId: 'video_analysis',
        );
        final api = _FakeChatApi(
          threads: <ChatThread>[listedThread],
          details: <String, ChatThreadDetail>{
            threadId: ChatThreadDetail(
              thread: detailThread,
              messages: const <ChatMessage>[],
            ),
          },
          sentMutation: ChatTextMutation(
            message: _message(
              id: 'cross-device-video-user',
              threadId: threadId,
              role: ChatMessageRole.user,
            ),
          ),
        );
        final controller = ChatController(
          api: api,
          scene: ChatScene.feedAi,
          aliasRepository: repository,
          initialAgentProfileId: 'visual_chat',
        );

        await controller.loadThreads(refresh: true, selectLatest: false);
        expect(controller.state.threads.single.agentProfileId, isNull);

        await controller.hydrateThreadTitles();

        expect(
          controller.state.threads.single.agentProfileId,
          'video_analysis',
        );
        expect(
          repository.agentProfileFor(
            scene: ChatScene.feedAi,
            threadId: threadId,
          ),
          'video_analysis',
        );

        await controller.selectThread(threadId, forceRemote: true);
        expect(controller.activeAgentProfileId, 'video_analysis');
        expect(await controller.sendText('继续分析画面和声音'), isTrue);
        expect(api.sentAgentProfileIds, <String?>['video_analysis']);
      },
    );

    test('keeps daily-topic title scoped and immutable per chat thread', () {
      final database = AppDatabase();
      final repository = ChatThreadAliasRepository(
        dao: UserMetadataDao(database),
        preferencesDao: AppPreferencesDao(database),
        userScope: 'daily-topic-user-a',
      );

      repository.saveDailyTopicContext(
        scene: ChatScene.feedAi,
        threadId: 'daily-topic-thread',
        title: '第一条公开选题',
        updatedAt: DateTime.utc(2026, 8, 14, 9),
      );
      repository.saveDailyTopicContext(
        scene: ChatScene.feedAi,
        threadId: 'daily-topic-thread',
        title: '不应覆盖的标题',
        updatedAt: DateTime.utc(2026, 8, 14, 10),
      );

      expect(
        repository
            .dailyTopicContextFor(
              scene: ChatScene.feedAi,
              threadId: 'daily-topic-thread',
            )
            ?.title,
        '第一条公开选题',
      );
      final otherAccount = ChatThreadAliasRepository(
        dao: UserMetadataDao(database),
        preferencesDao: AppPreferencesDao(database),
        userScope: 'daily-topic-user-b',
      );
      expect(
        otherAccount.dailyTopicContextFor(
          scene: ChatScene.feedAi,
          threadId: 'daily-topic-thread',
        ),
        isNull,
      );
    });

    test(
      'keeps a recovered thread visible when a later list projection lags',
      () async {
        final database = AppDatabase();
        final repository =
            ChatThreadAliasRepository(
              dao: UserMetadataDao(database),
              preferencesDao: AppPreferencesDao(database),
              userScope: 'chat-recovery-user',
            )..markThreadPurpose(
              scene: ChatScene.feedAi,
              threadId: 'recovered-thread',
              purpose: ChatConversationPurpose.general,
            );
        final recoveredThread = _thread(
          'recovered-thread',
          updatedAt: DateTime.utc(2026, 8, 14, 9),
        );
        final api = _FakeChatApi(
          threads: <ChatThread>[
            _thread('stale-list-thread', updatedAt: DateTime.utc(2026, 8, 14)),
          ],
          details: <String, ChatThreadDetail>{
            'recovered-thread': ChatThreadDetail(
              thread: recoveredThread,
              messages: <ChatMessage>[
                _message(
                  id: 'recovered-user',
                  threadId: 'recovered-thread',
                  role: ChatMessageRole.user,
                  text: '请持续分析这份资料',
                ),
              ],
            ),
            'stale-list-thread': ChatThreadDetail(
              thread: _thread('stale-list-thread'),
              messages: const <ChatMessage>[],
            ),
          },
        );
        final controller = ChatController(
          api: api,
          scene: ChatScene.feedAi,
          aliasRepository: repository,
        );

        expect(await controller.restoreRecentPurposeThread(), isTrue);
        expect(controller.state.activeThreadId, 'recovered-thread');
        expect(controller.state.messages.single.visibleText, '请持续分析这份资料');

        await controller.loadThreads(refresh: true, selectLatest: false);

        expect(controller.state.activeThreadId, 'recovered-thread');
        expect(
          controller.state.threads.map((thread) => thread.threadId),
          containsAll(<String>['recovered-thread', 'stale-list-thread']),
        );
        expect(controller.state.messages.single.visibleText, '请持续分析这份资料');
      },
    );

    test(
      'keeps cached confirmed messages while a detail projection is empty',
      () async {
        final database = AppDatabase();
        final repository = ChatThreadAliasRepository(
          dao: UserMetadataDao(database),
          preferencesDao: AppPreferencesDao(database),
          userScope: 'chat-empty-detail-cache-user',
        );
        final thread = _thread(
          'cached-active-thread',
          updatedAt: DateTime.utc(2026, 8, 14, 10),
        );
        final api = _FakeChatApi(
          threads: <ChatThread>[thread],
          details: <String, ChatThreadDetail>{
            thread.threadId: ChatThreadDetail(
              thread: thread,
              messages: <ChatMessage>[
                _message(
                  id: 'cached-user',
                  threadId: thread.threadId,
                  role: ChatMessageRole.user,
                  text: '请继续分析这份资料',
                ),
                _message(
                  id: 'cached-assistant',
                  threadId: thread.threadId,
                  role: ChatMessageRole.assistant,
                  text: '我正在梳理资料中的重点。',
                ),
              ],
            ),
          },
        );
        final first = ChatController(
          api: api,
          scene: ChatScene.feedAi,
          aliasRepository: repository,
        );
        await first.loadThreads();

        api.details[thread.threadId] = ChatThreadDetail(
          thread: thread,
          messages: const <ChatMessage>[],
        );
        final restored = ChatController(
          api: api,
          scene: ChatScene.feedAi,
          aliasRepository: repository,
        );
        expect(restored.restoreCachedConversations(), isTrue);

        await restored.selectThread(thread.threadId, forceRemote: true);

        expect(
          restored.state.messages.map((message) => message.visibleText),
          <String?>['请继续分析这份资料', '我正在梳理资料中的重点。'],
        );

        api.details[thread.threadId] = ChatThreadDetail(
          thread: thread,
          messages: <ChatMessage>[
            _message(
              id: 'cached-user',
              threadId: thread.threadId,
              role: ChatMessageRole.user,
              text: '请继续分析这份资料',
            ),
            _message(
              id: 'cached-assistant',
              threadId: thread.threadId,
              role: ChatMessageRole.assistant,
              text: '资料已分析完成。',
            ),
          ],
        );
        await restored.selectThread(thread.threadId, forceRemote: true);

        expect(
          restored.state.messages.map((message) => message.visibleText),
          <String?>['请继续分析这份资料', '资料已分析完成。'],
        );
      },
    );

    test(
      'keeps cached history visible when a forced detail read fails',
      () async {
        final database = AppDatabase();
        final repository = ChatThreadAliasRepository(
          dao: UserMetadataDao(database),
          preferencesDao: AppPreferencesDao(database),
          userScope: 'chat-failed-detail-cache-user',
        );
        final thread = _thread('cached-failure-thread');
        final api = _FakeChatApi(
          threads: <ChatThread>[thread],
          details: <String, ChatThreadDetail>{
            thread.threadId: ChatThreadDetail(
              thread: thread,
              messages: <ChatMessage>[
                _message(
                  id: 'cached-failure-user',
                  threadId: thread.threadId,
                  role: ChatMessageRole.user,
                  text: '这条记录不能因刷新失败而消失',
                ),
              ],
            ),
          },
        );
        final first = ChatController(
          api: api,
          scene: ChatScene.feedAi,
          aliasRepository: repository,
        );
        await first.loadThreads();
        api.details.remove(thread.threadId);

        final restored = ChatController(
          api: api,
          scene: ChatScene.feedAi,
          aliasRepository: repository,
        );
        expect(restored.restoreCachedConversations(), isTrue);

        await restored.selectThread(thread.threadId, forceRemote: true);

        expect(restored.state.status, ChatControllerStatus.ready);
        expect(restored.state.activeThreadId, thread.threadId);
        expect(restored.state.lastErrorCode, 'CHAT_THREAD_DETAIL_FAILED');
        expect(restored.state.messages.single.visibleText, '这条记录不能因刷新失败而消失');
      },
    );

    test(
      'reports a silent cached detail failure for the exact thread',
      () async {
        final database = AppDatabase();
        final repository = ChatThreadAliasRepository(
          dao: UserMetadataDao(database),
          preferencesDao: AppPreferencesDao(database),
          userScope: 'chat-silent-detail-failure-user',
        );
        final thread = _thread('silent-failure-thread');
        final seedApi = _FakeChatApi(
          threads: <ChatThread>[thread],
          details: <String, ChatThreadDetail>{
            thread.threadId: ChatThreadDetail(
              thread: thread,
              messages: <ChatMessage>[
                _message(
                  id: 'silent-failure-user-message',
                  threadId: thread.threadId,
                  role: ChatMessageRole.user,
                  text: '保留本地缓存内容',
                ),
              ],
            ),
          },
        );
        final seedController = ChatController(
          api: seedApi,
          scene: ChatScene.feedAi,
          aliasRepository: repository,
        );
        addTearDown(seedController.dispose);
        await seedController.loadThreads();

        final missingDetail = Completer<ApiResult<ChatThreadDetail>>()
          ..complete(_failure<ChatThreadDetail>('NOT_FOUND'));
        final restored = ChatController(
          api: _FakeChatApi(
            detailCompleters: <String, Completer<ApiResult<ChatThreadDetail>>>{
              thread.threadId: missingDetail,
            },
          ),
          scene: ChatScene.feedAi,
          aliasRepository: repository,
        );
        addTearDown(restored.dispose);
        expect(restored.restoreCachedConversations(), isTrue);

        await restored.selectThread(thread.threadId);
        expect(
          restored.lastRemoteFailureCodeForThreadSelection(thread.threadId),
          isNull,
        );

        await restored.revalidateThreadIfStale(thread.threadId, force: true);

        expect(restored.state.status, ChatControllerStatus.ready);
        expect(restored.state.lastErrorCode, isNull);
        expect(restored.state.messages.single.visibleText, '保留本地缓存内容');
        expect(
          restored.lastRemoteFailureCodeForThreadSelection(thread.threadId),
          'NOT_FOUND',
        );
        expect(
          restored.lastRemoteFailureCodeForThreadSelection('another-thread'),
          isNull,
        );

        await restored.selectThread(thread.threadId);
        expect(
          restored.lastRemoteFailureCodeForThreadSelection(thread.threadId),
          isNull,
        );
      },
    );

    test(
      'reopens a durable cached history without listing or rereading it',
      () async {
        final database = AppDatabase();
        final repository = ChatThreadAliasRepository(
          dao: UserMetadataDao(database),
          preferencesDao: AppPreferencesDao(database),
          userScope: 'chat-durable-history-user',
        );
        final thread = _thread(
          'durable-history-thread',
          updatedAt: DateTime.utc(2026, 8, 1),
        );
        repository.saveConversationCache(
          scene: ChatScene.feedAi,
          purpose: ChatConversationPurpose.general,
          threads: <ChatThread>[thread],
          messagesByThread: <String, List<ChatMessage>>{
            thread.threadId: <ChatMessage>[
              _message(
                id: 'durable-history-user-message',
                threadId: thread.threadId,
                role: ChatMessageRole.user,
                text: '不要在切换应用后丢失这段历史。',
              ),
              _message(
                id: 'durable-history-assistant-message',
                threadId: thread.threadId,
                role: ChatMessageRole.assistant,
                text: '这段历史会从本地确认缓存中恢复。',
              ),
            ],
          },
          savedAt: DateTime.utc(2025, 1, 1),
        );
        final api = _FakeChatApi(
          threads: <ChatThread>[_thread('unrelated-server-thread')],
        );
        final controller = ChatController(
          api: api,
          scene: ChatScene.feedAi,
          aliasRepository: repository,
          now: () => DateTime.utc(2026, 8, 18),
        );

        await controller.loadThreads();

        expect(controller.state.activeThreadId, thread.threadId);
        expect(
          controller.state.messages.map((message) => message.visibleText),
          <String?>['不要在切换应用后丢失这段历史。', '这段历史会从本地确认缓存中恢复。'],
        );
        expect(api.listCalls, 0);
        expect(api.detailCalls, isEmpty);
        expect(
          repository.recentThreadIdForPurpose(
            scene: ChatScene.feedAi,
            purpose: ChatConversationPurpose.general,
          ),
          thread.threadId,
        );
      },
    );

    test(
      'hydrates one known thread when a legacy cache entry has no messages',
      () async {
        const userScope = 'chat-empty-history-entry-user';
        final database = AppDatabase();
        final preferences = AppPreferencesDao(database);
        final repository = ChatThreadAliasRepository(
          dao: UserMetadataDao(database),
          preferencesDao: preferences,
          userScope: userScope,
        );
        final thread = _thread(
          'empty-history-entry-thread',
          updatedAt: DateTime.utc(2026, 8, 18, 12),
        );
        repository.saveConversationCache(
          scene: ChatScene.feedAi,
          purpose: ChatConversationPurpose.general,
          threads: <ChatThread>[thread],
          messagesByThread: <String, List<ChatMessage>>{
            thread.threadId: <ChatMessage>[
              _message(
                id: 'obsolete-cached-message',
                threadId: thread.threadId,
                role: ChatMessageRole.user,
                text: '这条旧缓存会被清空。',
              ),
            ],
          },
        );
        final cacheKey =
            'chat.cache.v1.${sha256.convert(utf8.encode(userScope)).toString().substring(0, 24)}';
        final rawCache = jsonDecode(preferences.readValue(cacheKey)!) as Map;
        final conversations = rawCache['conversations'] as Map;
        final entry = conversations['feed_ai/general'] as Map;
        entry['messages'] = <String, Object?>{thread.threadId: <Object?>[]};
        preferences.upsertValue(
          preferenceKey: cacheKey,
          value: jsonEncode(rawCache),
          updatedAt: DateTime.utc(2026, 8, 18, 12, 1).toIso8601String(),
        );
        final api = _FakeChatApi(
          details: <String, ChatThreadDetail>{
            thread.threadId: ChatThreadDetail(
              thread: thread,
              messages: <ChatMessage>[
                _message(
                  id: 'server-history-message',
                  threadId: thread.threadId,
                  role: ChatMessageRole.assistant,
                  text: '准确线程详情已经回填。',
                ),
              ],
            ),
          },
        );
        final controller = ChatController(
          api: api,
          scene: ChatScene.feedAi,
          aliasRepository: repository,
        );

        expect(controller.restoreCachedConversations(), isTrue);
        await controller.selectThread(thread.threadId);

        expect(api.listCalls, 0);
        expect(api.detailCalls, <String>[thread.threadId]);
        expect(controller.state.activeThreadId, thread.threadId);
        expect(controller.state.messages.single.visibleText, '准确线程详情已经回填。');
      },
    );

    test(
      'recent recovery rehydrates an active ready thread with no messages',
      () async {
        final database = AppDatabase();
        final repository = ChatThreadAliasRepository(
          dao: UserMetadataDao(database),
          preferencesDao: AppPreferencesDao(database),
          userScope: 'chat-active-empty-history-user',
        );
        final thread = _thread(
          'active-empty-history-thread',
          updatedAt: DateTime.utc(2026, 8, 26, 9),
        );
        repository.saveConversationCache(
          scene: ChatScene.feedAi,
          purpose: ChatConversationPurpose.general,
          threads: <ChatThread>[thread],
          messagesByThread: const <String, List<ChatMessage>>{},
        );
        final details = <String, ChatThreadDetail>{
          thread.threadId: ChatThreadDetail(
            thread: thread,
            messages: <ChatMessage>[
              _message(
                id: 'active-empty-server-message',
                threadId: thread.threadId,
                role: ChatMessageRole.assistant,
                text: '最近会话已从服务端完整恢复。',
              ),
            ],
          ),
        };
        final api = _FakeChatApi(details: details);
        final controller = ChatController(
          api: api,
          scene: ChatScene.feedAi,
          aliasRepository: repository,
        );

        await controller.loadThreads();
        expect(controller.state.activeThreadId, thread.threadId);
        expect(controller.state.messages, isEmpty);
        expect(api.detailCalls, isEmpty);

        expect(await controller.restoreRecentPurposeThread(), isTrue);

        expect(api.detailCalls, <String>[thread.threadId]);
        expect(controller.state.activeThreadId, thread.threadId);
        expect(controller.state.messages.single.visibleText, '最近会话已从服务端完整恢复。');
      },
    );

    test(
      'recent cache recovery leaves an empty thread for history validation',
      () async {
        final database = AppDatabase();
        final repository = ChatThreadAliasRepository(
          dao: UserMetadataDao(database),
          preferencesDao: AppPreferencesDao(database),
          userScope: 'chat-authoritative-empty-history-user',
        );
        final thread = _thread(
          'authoritative-empty-history-thread',
          updatedAt: DateTime.utc(2026, 8, 26, 8),
        );
        repository.saveConversationCache(
          scene: ChatScene.feedAi,
          purpose: ChatConversationPurpose.general,
          threads: <ChatThread>[thread],
          messagesByThread: const <String, List<ChatMessage>>{},
        );
        final api = _FakeChatApi(
          details: <String, ChatThreadDetail>{
            thread.threadId: ChatThreadDetail(
              thread: thread,
              messages: const <ChatMessage>[],
            ),
          },
        );
        final controller = ChatController(
          api: api,
          scene: ChatScene.feedAi,
          aliasRepository: repository,
        );

        await controller.loadThreads();
        expect(await controller.restoreRecentPurposeThread(), isFalse);

        expect(api.detailCalls, <String>[thread.threadId]);
        expect(controller.state.status, ChatControllerStatus.ready);
        expect(controller.state.activeThreadId, thread.threadId);
        expect(controller.state.messages, isEmpty);
      },
    );

    test(
      'ignores a stale detail response after selecting another thread',
      () async {
        final firstDetail = Completer<ApiResult<ChatThreadDetail>>();
        final secondDetail = Completer<ApiResult<ChatThreadDetail>>();
        final firstThread = _thread('selection-first');
        final secondThread = _thread('selection-second');
        final api = _FakeChatApi(
          threads: <ChatThread>[firstThread, secondThread],
          detailCompleters: <String, Completer<ApiResult<ChatThreadDetail>>>{
            firstThread.threadId: firstDetail,
            secondThread.threadId: secondDetail,
          },
        );
        final controller = ChatController(api: api, scene: ChatScene.feedAi);
        await controller.loadThreads(selectLatest: false);

        final firstSelection = controller.selectThread(
          firstThread.threadId,
          forceRemote: true,
        );
        final secondSelection = controller.selectThread(
          secondThread.threadId,
          forceRemote: true,
        );
        secondDetail.complete(
          _success(
            ChatThreadDetail(
              thread: secondThread,
              messages: <ChatMessage>[
                _message(
                  id: 'selection-second-message',
                  threadId: secondThread.threadId,
                  role: ChatMessageRole.assistant,
                  text: '第二个线程保持选中',
                ),
              ],
            ),
            SubmissionKeyStore.empty,
          ),
        );
        await secondSelection;
        firstDetail.complete(
          _success(
            ChatThreadDetail(
              thread: firstThread,
              messages: <ChatMessage>[
                _message(
                  id: 'selection-first-message',
                  threadId: firstThread.threadId,
                  role: ChatMessageRole.assistant,
                  text: '过期响应不得覆盖当前线程',
                ),
              ],
            ),
            SubmissionKeyStore.empty,
          ),
        );
        await firstSelection;

        expect(controller.state.status, ChatControllerStatus.ready);
        expect(controller.state.activeThreadId, secondThread.threadId);
        expect(controller.state.messages.single.visibleText, '第二个线程保持选中');
      },
    );

    test(
      'restores a complete durable Assistant reply from the local cache',
      () async {
        final database = AppDatabase();
        final repository = ChatThreadAliasRepository(
          dao: UserMetadataDao(database),
          preferencesDao: AppPreferencesDao(database),
          userScope: 'chat-long-reply-cache-user',
        );
        final thread = _thread(
          'long-reply-cache-thread',
          updatedAt: DateTime.utc(2026, 8, 17, 8, 59, 28),
        );
        final reply = _longPersonaReply(length: 65537);
        final api = _FakeChatApi(
          threads: <ChatThread>[thread],
          details: <String, ChatThreadDetail>{
            thread.threadId: ChatThreadDetail(
              thread: thread,
              messages: <ChatMessage>[
                _message(
                  id: 'long-reply-user',
                  threadId: thread.threadId,
                  role: ChatMessageRole.user,
                  text: '请完成这次人设创作',
                ),
                _message(
                  id: 'long-reply-assistant',
                  threadId: thread.threadId,
                  role: ChatMessageRole.assistant,
                  text: reply,
                  resourceAttachments: const <ChatResourceAttachment>[
                    ChatResourceAttachment(
                      kind: ChatResourceAttachmentKind.file,
                      resourceId: 'resource-long-reply-report',
                      displayName: '完整报告.pdf',
                      mimeType: 'application/pdf',
                      sizeBytes: 4096,
                    ),
                  ],
                ),
              ],
            ),
          },
        );
        final first = ChatController(
          api: api,
          scene: ChatScene.feedAi,
          aliasRepository: repository,
        );
        await first.loadThreads();

        api.details[thread.threadId] = ChatThreadDetail(
          thread: thread,
          messages: const <ChatMessage>[],
        );
        final restored = ChatController(
          api: api,
          scene: ChatScene.feedAi,
          aliasRepository: repository,
        );
        expect(restored.restoreCachedConversations(), isTrue);

        await restored.selectThread(thread.threadId, forceRemote: true);

        final assistant = restored.state.messages.singleWhere(
          (message) => message.messageId == 'long-reply-assistant',
        );
        expect(assistant.visibleText, reply);
        expect(assistant.visibleText?.length, 65537);
        expect(assistant.visibleText, endsWith(_longPersonaReplyFinalQuestion));
        expect(assistant.resourceAttachments, hasLength(1));
        expect(
          assistant.resourceAttachments.single.resourceId,
          'resource-long-reply-report',
        );
        expect(assistant.resourceAttachments.single.displayName, '完整报告.pdf');
      },
    );

    test('rejects user text above 4000 before API calls', () async {
      final api = _FakeChatApi(createdThread: _thread('created-1'));
      final controller = ChatController(api: api, scene: ChatScene.feedAi);

      expect(await controller.sendText('a' * 4001), isFalse);
      expect(api.createCalls, 0);
      expect(api.sentContents, isEmpty);
      expect(controller.state.lastErrorCode, 'CHAT_TEXT_INVALID');
    });
  });
}

ChatThread _thread(String id, {DateTime? updatedAt, String? agentProfileId}) {
  return ChatThread(
    threadId: id,
    scene: ChatScene.feedAi,
    title: '会话 $id',
    updatedAt: updatedAt,
    agentProfileId: agentProfileId,
  );
}

ChatMessage _message({
  required String id,
  required String threadId,
  required ChatMessageRole role,
  ChatMessageContentType contentType = ChatMessageContentType.text,
  String? text,
  String? agentRunId,
  String? taskId,
  String status = 'sent',
  List<ChatResourceAttachment> resourceAttachments =
      const <ChatResourceAttachment>[],
}) {
  return ChatMessage(
    messageId: id,
    threadId: threadId,
    scene: ChatScene.feedAi,
    role: role,
    contentType: contentType,
    status: status,
    textPreview: text,
    agentRunId: agentRunId,
    taskId: taskId,
    resourceAttachments: resourceAttachments,
  );
}

ResourceIndex _voiceResource({String sourceScene = 'workspace_voice'}) {
  return ResourceIndex(
    resourceId: 'resource-voice-1',
    uploadId: 'upload-voice-1',
    sourceScene: sourceScene,
    mimeType: 'audio/mp4',
    sizeBytes: 4096,
    durationSeconds: 6,
  );
}

_FakeChatApi _pendingAgentRunApi({
  required String threadId,
  required String agentRunId,
  String? assistantId,
  String? assistantText,
}) {
  return _FakeChatApi(
    createdThread: _thread(threadId),
    sentMutation: ChatTextMutation(
      message: _message(
        id: 'user-$threadId',
        threadId: threadId,
        role: ChatMessageRole.user,
      ),
      nextAction: ChatNextAction(
        type: ChatNextActionType.pollAgentRun,
        agentRunId: agentRunId,
      ),
    ),
    details: <String, ChatThreadDetail>{
      threadId: ChatThreadDetail(
        thread: _thread(threadId),
        messages: <ChatMessage>[
          if (assistantId != null)
            _message(
              id: assistantId,
              threadId: threadId,
              role: ChatMessageRole.assistant,
              text: assistantText,
            ),
        ],
      ),
    },
  );
}

AgentRunSnapshot _agentRun({
  String agentRunId = 'agent-run-1',
  required String status,
  String? threadId,
  String? assistantMessageId,
  String? completionMode,
  AgentRunPublicError? error,
  List<AgentRunToolTrace> toolTrace = const <AgentRunToolTrace>[],
}) {
  return AgentRunSnapshot(
    agentRunId: agentRunId,
    workspaceId: 'workspace-1',
    threadId: threadId,
    status: status,
    workspaceVersion: 1,
    workspaceBindingVersion: 1,
    contextGeneration: 1,
    assistantMessageId: assistantMessageId,
    completionMode: completionMode,
    error: error,
    usage: const AgentRunUsage(
      measurementStatus: 'unavailable',
      inputTokens: null,
      outputTokens: null,
      imageCount: null,
      videoSeconds: null,
      accountedCredits: null,
      policyVersion: null,
    ),
    toolTrace: toolTrace,
    createdAt: DateTime.utc(2026, 8, 7, 8),
    updatedAt: DateTime.utc(2026, 8, 7, 8, 0, 2),
  );
}

ApiResult<AgentRunSnapshot> _runSuccess(AgentRunSnapshot run) {
  return ApiResult<AgentRunSnapshot>.success(
    data: run,
    status: 200,
    idempotencyStore: SubmissionKeyStore.empty,
  );
}

final class _RunScopedAssistantRuntimeFixture implements ProjectRunFixture {
  _RunScopedAssistantRuntimeFixture(this.runs, {required this.onRead});

  final Map<String, AgentRunSnapshot> runs;
  final void Function(String) onRead;

  @override
  Future<ApiResult<AgentRunSnapshot>> getRun({
    required String agentRunId,
  }) async {
    onRead(agentRunId);
    return _runSuccess(runs[agentRunId]!);
  }
}

final class _FakeAssistantRuntimeFixture implements ProjectRunFixture {
  _FakeAssistantRuntimeFixture(this._results);

  final List<ApiResult<AgentRunSnapshot>> _results;
  final calls = <String>[];

  @override
  Future<ApiResult<AgentRunSnapshot>> getRun({
    required String agentRunId,
  }) async {
    calls.add(agentRunId);
    if (_results.isEmpty) return _failure('CHAT_AGENT_RUN_POLL_FAILED');
    return _results.removeAt(0);
  }
}

final class _StableAssistantRuntimeFixture implements ProjectRunFixture {
  const _StableAssistantRuntimeFixture(this.result);

  final ApiResult<AgentRunSnapshot> result;

  @override
  Future<ApiResult<AgentRunSnapshot>> getRun({
    required String agentRunId,
  }) async => result;
}

final class _CancellableAssistantRuntimeFixture
    implements ProjectRunFixture, ProjectRunLeaseFixture {
  final Completer<void> started = Completer<void>();
  final Completer<ApiResult<AgentRunSnapshot>> _result =
      Completer<ApiResult<AgentRunSnapshot>>();
  int cancelCalls = 0;

  void completeLate(ApiResult<AgentRunSnapshot> result) {
    if (!_result.isCompleted) _result.complete(result);
  }

  @override
  Future<ApiResult<AgentRunSnapshot>> getRun({required String agentRunId}) =>
      _result.future;

  @override
  LegacyAssistantReadLease leaseGetRun({required String agentRunId}) {
    if (!started.isCompleted) started.complete();
    return LegacyAssistantReadLease(
      result: _result.future,
      cancel: () => cancelCalls += 1,
    );
  }
}

final class _FakeChatRunTracker
    implements
        ChatRunTrackingPort,
        ChatRunServerActiveRunTrackingPort,
        AgentTaskSubjectMetadataPort {
  final calls =
      <
        ({
          String agentRunId,
          String threadId,
          ChatScene scene,
          ChatConversationPurpose purpose,
        })
      >[];
  final subjectCalls = <({String threadId, String subjectTitle})>[];
  final serverActiveCalls =
      <({String threadId, ChatScene scene, List<ChatActiveRun> runs})>[];

  @override
  Future<void> track({
    required String agentRunId,
    required String threadId,
    required ChatScene scene,
    ChatConversationPurpose purpose = ChatConversationPurpose.general,
  }) async {
    calls.add((
      agentRunId: agentRunId,
      threadId: threadId,
      scene: scene,
      purpose: purpose,
    ));
  }

  @override
  Future<void> rememberChatThreadSubject({
    required String threadId,
    required String subjectTitle,
  }) async {
    subjectCalls.add((threadId: threadId, subjectTitle: subjectTitle));
  }

  @override
  Future<void> rememberKnowledgeAssetSubject({
    required String localNoteId,
    required String subjectTitle,
  }) async {}

  @override
  Future<void> trackServerActiveRuns({
    required String threadId,
    required ChatScene scene,
    required Iterable<ChatActiveRun> runs,
    ChatConversationPurpose purpose = ChatConversationPurpose.general,
  }) async {
    serverActiveCalls.add((
      threadId: threadId,
      scene: scene,
      runs: List<ChatActiveRun>.unmodifiable(runs),
    ));
  }
}

final class _AdmissionRunTracker
    implements
        ChatRunTrackingPort,
        ChatAcceptedRunTrackingPort,
        ChatRunLifecycleOwnerPort,
        ChatRunStatusPort,
        ChatRunReconciliationPort,
        ChatRunRecoveryPort {
  _AdmissionRunTracker({this.recoverySucceeds = true, this.recoveryGate});

  final bool recoverySucceeds;
  final Future<void>? recoveryGate;
  final Set<String> terminalThreads = <String>{};
  final List<String> recoveryCalls = <String>[];
  final Map<String, String> _threadIdByRunId = <String, String>{};

  @override
  ChatRunReconciliationSnapshot? reconciliationForThread(String threadId) =>
      terminalThreads.contains(threadId)
      ? const ChatRunReconciliationSnapshot(
          phase: ChatRunReconciliationPhase.recoveryRequired,
          failures: 4,
          failureCode: 'API_RESPONSE_INVALID',
        )
      : null;

  @override
  Future<bool> recoverThread(String threadId) async {
    recoveryCalls.add(threadId);
    await recoveryGate;
    if (!recoverySucceeds) return false;
    terminalThreads.remove(threadId);
    _threadIdByRunId.removeWhere((_, value) => value == threadId);
    return true;
  }

  @override
  bool get canTrackAcceptedRuns => true;

  @override
  Future<void> track({
    required String agentRunId,
    required String threadId,
    required ChatScene scene,
    ChatConversationPurpose purpose = ChatConversationPurpose.general,
  }) async {
    _threadIdByRunId[agentRunId] = threadId;
  }

  @override
  Future<void> trackAcceptedRun({
    required String agentRunId,
    required String? publicTaskId,
    required String threadId,
    required ChatScene scene,
    ChatConversationPurpose purpose = ChatConversationPurpose.general,
  }) => track(
    agentRunId: agentRunId,
    threadId: threadId,
    scene: scene,
    purpose: purpose,
  );

  @override
  bool isThreadPending(String threadId) =>
      _threadIdByRunId.values.contains(threadId) &&
      !terminalThreads.contains(threadId);

  @override
  bool needsThreadReconciliation(String threadId) =>
      isThreadPending(threadId) || terminalThreads.contains(threadId);

  @override
  bool hasTrackedThreadRun(String threadId, String agentRunId) =>
      _threadIdByRunId[agentRunId] == threadId;

  @override
  String? threadRunStatus(String threadId) =>
      isThreadPending(threadId) ? 'running' : null;

  @override
  List<AgentRunToolTrace> threadToolTrace(String threadId) =>
      const <AgentRunToolTrace>[];
}

class _FakeChatApi implements ChatRepository {
  _FakeChatApi({
    this.threads = const <ChatThread>[],
    this.details = const <String, ChatThreadDetail>{},
    this.detailCompleters =
        const <String, Completer<ApiResult<ChatThreadDetail>>>{},
    this.createdThread,
    this.createThreadCompleter,
    this.sentMutation,
    this.sentVoiceMutation,
    this.sendFailure,
    this.voiceSendFailure,
    this.listThreadsHandler,
    List<Completer<ApiResult<ChatTextMutation>>> textMutationCompleters =
        const <Completer<ApiResult<ChatTextMutation>>>[],
    List<ApiResult<ChatTextMutation>> sendResults =
        const <ApiResult<ChatTextMutation>>[],
  }) : textMutationCompleters = List<Completer<ApiResult<ChatTextMutation>>>.of(
         textMutationCompleters,
       ),
       sendResults = List<ApiResult<ChatTextMutation>>.of(sendResults);

  final List<ChatThread> threads;
  final Map<String, ChatThreadDetail> details;
  final Map<String, Completer<ApiResult<ChatThreadDetail>>> detailCompleters;
  final ChatThread? createdThread;
  final Completer<ApiResult<ChatThread>>? createThreadCompleter;
  final ChatTextMutation? sentMutation;
  final ChatVoiceMutation? sentVoiceMutation;
  final AppFailure? sendFailure;
  final AppFailure? voiceSendFailure;
  final List<Completer<ApiResult<ChatTextMutation>>> textMutationCompleters;
  final List<ApiResult<ChatTextMutation>> sendResults;
  final Future<ApiResult<ChatThreadPage>> Function(String? cursor, int? limit)?
  listThreadsHandler;
  final detailCalls = <String>[];
  final sentContents = <String>[];
  final sentThreadIds = <String>[];
  final sentContentLineIds = <String?>[];
  final sentAgentProfileIds = <String?>[];
  final sentContexts = <ChatContextEnvelope?>[];
  final sentTextIdempotencies = <IdempotencyRequestContext>[];
  final createdThreadIdempotencies = <IdempotencyRequestContext>[];
  final voiceThreadIds = <String>[];
  final voiceResourceIds = <String>[];
  final voiceDurations = <int>[];
  final createContentLineIds = <String?>[];
  final voiceContentLineIds = <String?>[];
  final listPurposes = <ChatConversationPurpose>[];
  final listCursors = <String?>[];
  int listCalls = 0;
  int createCalls = 0;

  @override
  Future<ApiResult<ChatThread>> createThread({
    required ChatScene scene,
    ChatConversationPurpose purpose = ChatConversationPurpose.general,
    String? contentLineId,
    required IdempotencyRequestContext idempotency,
    SubmissionKeyStore idempotencyStore = SubmissionKeyStore.empty,
  }) async {
    createCalls += 1;
    createContentLineIds.add(contentLineId);
    createdThreadIdempotencies.add(idempotency);
    if (createThreadCompleter case final completer?) {
      return completer.future;
    }
    final thread = createdThread;
    if (thread == null) {
      return _failure('CHAT_CREATE_THREAD_FAILED');
    }
    return _success(thread.copyWith(purpose: purpose), idempotencyStore);
  }

  @override
  Future<ApiResult<ChatThreadDetail>> getThreadDetail({
    required String threadId,
  }) async {
    detailCalls.add(threadId);
    final completer = detailCompleters[threadId];
    if (completer != null) return completer.future;
    final detail = details[threadId];
    return detail == null
        ? _failure('CHAT_THREAD_DETAIL_FAILED')
        : _success(detail, SubmissionKeyStore.empty);
  }

  @override
  Future<ApiResult<ChatThreadPage>> listThreads({
    required ChatScene scene,
    ChatConversationPurpose purpose = ChatConversationPurpose.general,
    String? cursor,
    int? limit,
  }) async {
    listCalls += 1;
    listPurposes.add(purpose);
    listCursors.add(cursor);
    final handler = listThreadsHandler;
    if (handler != null) return handler(cursor, limit);
    return _success(ChatThreadPage(items: threads), SubmissionKeyStore.empty);
  }

  @override
  Future<ApiResult<ChatTextMutation>> sendTextMessage({
    required String threadId,
    required ChatScene scene,
    required String content,
    String? contentLineId,
    ChatContextEnvelope? context,
    String? agentProfileId,
    required IdempotencyRequestContext idempotency,
    SubmissionKeyStore idempotencyStore = SubmissionKeyStore.empty,
  }) async {
    sentContents.add(content);
    sentThreadIds.add(threadId);
    sentContentLineIds.add(contentLineId);
    sentAgentProfileIds.add(agentProfileId);
    sentContexts.add(context);
    sentTextIdempotencies.add(idempotency);
    if (textMutationCompleters.isNotEmpty) {
      return textMutationCompleters.removeAt(0).future;
    }
    if (sendResults.isNotEmpty) return sendResults.removeAt(0);
    final failure = sendFailure;
    if (failure != null) {
      return ApiResult<ChatTextMutation>.failure(
        error: failure,
        idempotencyStore: idempotencyStore,
      );
    }
    final mutation = sentMutation;
    return mutation == null
        ? _failure('CHAT_SEND_FAILED')
        : _success(mutation, idempotencyStore);
  }

  @override
  Future<ApiResult<ChatVoiceMutation>> sendVoiceMessage({
    required String threadId,
    required ChatScene scene,
    required String audioResourceId,
    required int durationSeconds,
    String? contentLineId,
    ChatContextEnvelope? context,
    required IdempotencyRequestContext idempotency,
    SubmissionKeyStore idempotencyStore = SubmissionKeyStore.empty,
  }) async {
    voiceThreadIds.add(threadId);
    voiceResourceIds.add(audioResourceId);
    voiceDurations.add(durationSeconds);
    voiceContentLineIds.add(contentLineId);
    final failure = voiceSendFailure;
    if (failure != null) {
      return ApiResult<ChatVoiceMutation>.failure(
        error: failure,
        idempotencyStore: idempotencyStore,
      );
    }
    final mutation = sentVoiceMutation;
    return mutation == null
        ? _failure('CHAT_VOICE_SEND_FAILED')
        : _success(mutation, idempotencyStore);
  }
}

final class _ProgressChatApi extends _FakeChatApi
    implements AssistantThreadProgressPort {
  _ProgressChatApi({
    required super.createdThread,
    super.details = const <String, ChatThreadDetail>{},
    required super.sentMutation,
    required this.progressPages,
  });

  final List<AssistantProgressPage> progressPages;
  final progressAfterSequences = <int>[];

  @override
  Future<AssistantRuntimeRead<AssistantProgressPage>> readProgress({
    required String conversationId,
    required int afterSequence,
  }) async {
    progressAfterSequences.add(afterSequence);
    final page = progressPages.isEmpty
        ? AssistantProgressPage(
            conversationId: conversationId,
            events: const <AssistantProgressEvent>[],
            nextSequence: afterSequence,
          )
        : progressPages.removeAt(0);
    return AssistantRuntimeRead.success(page);
  }
}

final class _SequencedDetailChatApi extends _FakeChatApi {
  _SequencedDetailChatApi({
    required super.createdThread,
    required super.sentMutation,
    required List<ApiResult<ChatThreadDetail>> detailResults,
  }) : _detailResults = List<ApiResult<ChatThreadDetail>>.of(detailResults);

  final List<ApiResult<ChatThreadDetail>> _detailResults;

  @override
  Future<ApiResult<ChatThreadDetail>> getThreadDetail({
    required String threadId,
  }) async {
    detailCalls.add(threadId);
    if (_detailResults.isEmpty) {
      return _failure('CHAT_THREAD_DETAIL_FAILED');
    }
    return _detailResults.removeAt(0);
  }
}

final class _DetachingChatRunTracker
    implements ChatRunTrackingPort, ChatRunLifecycleOwnerPort {
  const _DetachingChatRunTracker();

  @override
  bool get canTrackAcceptedRuns => true;

  @override
  Future<void> track({
    required String agentRunId,
    required String threadId,
    required ChatScene scene,
    ChatConversationPurpose purpose = ChatConversationPurpose.general,
  }) async {}
}

final class _RuntimeMetadataChatApi extends _FakeChatApi
    implements ChatThreadMetadataPort {
  _RuntimeMetadataChatApi({required this.runtimeResults});

  final List<ApiConditionalResult<SharedThreadRuntimeInvocation>>
  runtimeResults;
  final List<String?> ifNoneMatches = <String?>[];

  @override
  Future<ApiConditionalResult<SharedThreadRuntimeInvocation>>
  latestThreadRuntimeInvocation({
    required String threadId,
    String? ifNoneMatch,
  }) async {
    ifNoneMatches.add(ifNoneMatch);
    return runtimeResults.removeAt(0);
  }

  @override
  Future<ApiResult<ChatThread>> updateThreadTitle({
    required String threadId,
    required ChatThreadTitleMode titleMode,
    String? title,
    required int expectedTitleVersion,
    required IdempotencyRequestContext idempotency,
    SubmissionKeyStore idempotencyStore = SubmissionKeyStore.empty,
  }) async => _failure<ChatThread>('CHAT_THREAD_TITLE_UPDATE_FAILED');
}

final class _SuccessfulThreadMetadataChatApi extends _FakeChatApi
    implements ChatThreadMetadataPort {
  _SuccessfulThreadMetadataChatApi({
    required super.threads,
    required super.details,
  });

  @override
  Future<ApiResult<ChatThread>> updateThreadTitle({
    required String threadId,
    required ChatThreadTitleMode titleMode,
    String? title,
    required int expectedTitleVersion,
    required IdempotencyRequestContext idempotency,
    SubmissionKeyStore idempotencyStore = SubmissionKeyStore.empty,
  }) async {
    final current = threads.singleWhere(
      (thread) => thread.threadId == threadId,
    );
    return _success(
      current.copyWith(
        title: titleMode == ChatThreadTitleMode.custom ? title : current.title,
        titleMode: titleMode,
        titleVersion: expectedTitleVersion + 1,
        clearLocalAlias: true,
      ),
      idempotencyStore,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _RuntimeHistoryChatApi extends _FakeChatApi
    implements ChatThreadRuntimeHistoryPort {
  _RuntimeHistoryChatApi(this.results);

  final List<ApiConditionalResult<SharedThreadRuntimeInvocationPage>> results;
  final List<String?> cursors = <String?>[];
  final List<int> limits = <int>[];
  final List<String?> ifNoneMatches = <String?>[];

  @override
  Future<ApiConditionalResult<SharedThreadRuntimeInvocationPage>>
  threadRuntimeInvocations({
    required String threadId,
    String? cursor,
    int limit = 20,
    String? ifNoneMatch,
  }) async {
    cursors.add(cursor);
    limits.add(limit);
    ifNoneMatches.add(ifNoneMatch);
    return results.removeAt(0);
  }
}

final class _SseDraftChatRunTracker extends ChangeNotifier
    implements
        ChatRunTrackingPort,
        ChatRunLifecycleOwnerPort,
        ChatRunActivityPort,
        ChatRunDraftDeltaSourcePort,
        ChatRunDraftSnapshotSourcePort,
        ChatRunCompletionSourcePort,
        ChatRunCompletionJournalPort {
  _SseDraftChatRunTracker({
    this.onTrack,
    Iterable<ChatRunActivity> initialActivities = const <ChatRunActivity>[],
  }) : _activities = <String, ChatRunActivity>{
         for (final activity in initialActivities)
           activity.agentRunId: activity,
       };

  int _sequence = 0;
  ChatRunDraftDelta? _lastDelta;
  int _completionSequence = 0;
  ChatRunCompletion? _lastCompletion;
  final Map<String, ChatRunCompletion> _completions =
      <String, ChatRunCompletion>{};
  final void Function(String agentRunId, String threadId)? onTrack;
  final Map<String, ChatRunActivity> _activities;
  final Map<String, ChatRunDraftSnapshot> _draftSnapshots =
      <String, ChatRunDraftSnapshot>{};

  @override
  bool get canTrackAcceptedRuns => true;

  @override
  int get draftDeltaSequence => _sequence;

  @override
  ChatRunDraftDelta? get lastDraftDelta => _lastDelta;

  @override
  ChatRunDraftSnapshot? draftSnapshotFor({
    required String threadId,
    required String agentRunId,
  }) {
    final snapshot = _draftSnapshots[agentRunId];
    return snapshot?.threadId == threadId ? snapshot : null;
  }

  @override
  int get completionSequence => _completionSequence;

  @override
  ChatRunCompletion? get lastCompletion => _lastCompletion;

  @override
  List<ChatRunCompletion> completionsForThread(String threadId) => _completions
      .values
      .where((completion) => completion.threadId == threadId)
      .toList(growable: false);

  @override
  ChatRunActivity? activityFor({
    required String threadId,
    required String agentRunId,
  }) {
    final activity = _activities[agentRunId];
    return activity?.threadId == threadId ? activity : null;
  }

  @override
  List<ChatRunActivity> activitiesForThread(String threadId) =>
      _activities.values
          .where((activity) => activity.threadId == threadId)
          .toList(growable: false)
        ..sort((left, right) => left.createdAt.compareTo(right.createdAt));

  void restoreActivity(ChatRunActivity activity) {
    _activities[activity.agentRunId] = activity;
    notifyListeners();
  }

  void publish({
    required String agentRunId,
    required String threadId,
    required String deltaText,
    bool replace = false,
  }) {
    _sequence += 1;
    final existing = _draftSnapshots[agentRunId];
    final text = replace ? deltaText : '${existing?.text ?? ''}$deltaText';
    _draftSnapshots[agentRunId] = ChatRunDraftSnapshot(
      agentRunId: agentRunId,
      threadId: threadId,
      scene: ChatScene.feedAi,
      purpose: ChatConversationPurpose.general,
      eventSequence: _sequence,
      text: text,
    );
    _lastDelta = ChatRunDraftDelta(
      agentRunId: agentRunId,
      threadId: threadId,
      scene: ChatScene.feedAi,
      purpose: ChatConversationPurpose.general,
      eventSequence: _sequence,
      deltaText: deltaText,
      replace: replace,
    );
    notifyListeners();
  }

  void publishCompletion({
    required String agentRunId,
    required String threadId,
    ChatConversationPurpose purpose = ChatConversationPurpose.general,
    required String status,
    String? completionMode,
    String? failureCode,
    String? assistantMessageId,
  }) {
    _completionSequence += 1;
    final completion = ChatRunCompletion(
      agentRunId: agentRunId,
      threadId: threadId,
      scene: ChatScene.feedAi,
      purpose: purpose,
      status: status,
      completionMode: completionMode,
      failureCode: failureCode,
      assistantMessageId: assistantMessageId,
    );
    _lastCompletion = completion;
    _completions[agentRunId] = completion;
    final activity = _activities[agentRunId];
    if (activity != null) {
      _activities[agentRunId] = ChatRunActivity(
        agentRunId: activity.agentRunId,
        threadId: activity.threadId,
        status: status,
        createdAt: activity.createdAt,
        completedAt: DateTime.utc(2026, 9, 2),
        toolTrace: activity.toolTrace,
      );
    }
    notifyListeners();
  }

  @override
  Future<void> track({
    required String agentRunId,
    required String threadId,
    required ChatScene scene,
    ChatConversationPurpose purpose = ChatConversationPurpose.general,
  }) async {
    _activities.putIfAbsent(
      agentRunId,
      () => ChatRunActivity(
        agentRunId: agentRunId,
        threadId: threadId,
        status: 'running',
        createdAt: DateTime.utc(2026, 8, 31),
      ),
    );
    onTrack?.call(agentRunId, threadId);
  }
}

ApiResult<T> _success<T>(T data, SubmissionKeyStore idempotencyStore) {
  return ApiResult<T>.success(
    data: data,
    status: 200,
    idempotencyStore: idempotencyStore,
  );
}

ApiResult<T> _failure<T>(String code) {
  return ApiResult<T>.failure(
    error: AppFailure(
      code: code,
      category: AppFailureCategory.api,
      message: 'failed',
      userMessageKey: 'chat.test.$code',
    ),
    idempotencyStore: SubmissionKeyStore.empty,
  );
}

ApiResult<T> _knownRejectedFailure<T>(String code) {
  return ApiResult<T>.failure(
    error: AppFailure(
      code: code,
      category: AppFailureCategory.api,
      message: 'known rejected failure',
      userMessageKey: 'chat.test.$code',
    ),
    status: 422,
    idempotencyStore: SubmissionKeyStore.empty,
  );
}

ApiResult<T> _retryableFailure<T>(String code) {
  return ApiResult<T>.failure(
    error: AppFailure(
      code: code,
      category: AppFailureCategory.api,
      message: 'retryable failure',
      userMessageKey: 'chat.test.$code',
      isRetryable: true,
      recoveryActions: const <String>['retry'],
    ),
    idempotencyStore: SubmissionKeyStore.empty,
  );
}

final class _FailingRecordWorker implements DatabaseRecordWorkerPort {
  const _FailingRecordWorker();

  @override
  bool get isDisposed => false;

  @override
  bool get isEnabled => true;

  @override
  Future<void> upsertRecord({
    required LocalTableName table,
    required String key,
    required LocalDatabaseRecord record,
  }) async => throw StateError('injected durable cache failure');

  @override
  Future<void> upsertRecordBatch({
    required LocalTableName table,
    required Map<String, LocalDatabaseRecord> records,
  }) async => throw StateError('injected durable cache failure');

  @override
  Future<bool> deleteRecord({
    required LocalTableName table,
    required String key,
  }) async => throw StateError('unexpected delete');

  @override
  Future<List<LocalDatabaseRecord>> listRecords(LocalTableName table) async =>
      const <LocalDatabaseRecord>[];
}

final class _GatedRecordWorker implements DatabaseRecordWorkerPort {
  final Completer<void> started = Completer<void>();
  final Completer<void> release = Completer<void>();

  @override
  bool get isDisposed => false;

  @override
  bool get isEnabled => true;

  @override
  Future<void> upsertRecord({
    required LocalTableName table,
    required String key,
    required LocalDatabaseRecord record,
  }) async {
    if (!started.isCompleted) started.complete();
    await release.future;
  }

  @override
  Future<void> upsertRecordBatch({
    required LocalTableName table,
    required Map<String, LocalDatabaseRecord> records,
  }) async {
    if (!started.isCompleted) started.complete();
    await release.future;
  }

  @override
  Future<bool> deleteRecord({
    required LocalTableName table,
    required String key,
  }) async => true;

  @override
  Future<List<LocalDatabaseRecord>> listRecords(LocalTableName table) async =>
      const <LocalDatabaseRecord>[];
}
