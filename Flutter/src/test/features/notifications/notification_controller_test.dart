import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/api/api_client.dart';
import 'package:huahuoai_app/core/api/idempotency.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/database/app_preferences_dao.dart';
import 'package:huahuoai_app/features/notifications/application/notification_controller.dart';
import 'package:huahuoai_app/features/notifications/data/notification_api.dart';
import 'package:huahuoai_app/features/notifications/domain/notification_models.dart';

void main() {
  for (final restoreFromCache in [false, true]) {
    test(
      'task success survives stale delivery cache=$restoreFromCache',
      () async {
        final now = DateTime.utc(2026, 9, 13);
        final succeeded = AppNotification(
          notificationId: 'task-row',
          eventId: 'success-event',
          eventType: 'agent_run.succeeded',
          scene: 'chat',
          targetType: 'thread',
          targetId: 'thread-1',
          title: '结果已完成',
          body: '真实结果',
          status: AppNotificationStatus.read,
          taskStatus: AppNotificationTaskStatus.succeeded,
          taskId: 'task-1',
          createdAt: now,
          updatedAt: now.add(const Duration(minutes: 1)),
        );
        final api = _MutableNotificationApi(succeeded);
        final controller = NotificationController(
          api: api,
          resolution: restoreFromCache
              ? _CachedResolutionPort(
                  CachedNotificationPage(
                    items: [succeeded],
                    nextCursor: null,
                    savedAt: now,
                  ),
                )
              : null,
        );
        addTearDown(controller.dispose);
        if (!restoreFromCache) await controller.load(forceRemote: true);
        api.notification = AppNotification(
          notificationId: 'task-row',
          eventId: 'delayed-running-event',
          eventType: 'agent_run.running',
          scene: 'chat',
          targetType: 'thread',
          targetId: 'thread-1',
          title: '还在进行中',
          body: '旧状态',
          status: AppNotificationStatus.unread,
          taskStatus: AppNotificationTaskStatus.running,
          taskId: 'task-1',
          createdAt: now,
          updatedAt: now.add(const Duration(minutes: 2)),
        );
        await controller.load(forceRemote: true);
        expect(
          controller.state.items.single.taskStatus,
          AppNotificationTaskStatus.succeeded,
        );
        expect(controller.state.items.single.title, '结果已完成');
        expect(controller.state.items.single.isUnread, isFalse);
        expect(controller.state.items.single.eventId, 'success-event');
      },
    );
  }

  test(
    'failure retries and reused rows remain independent task facts',
    () async {
      final now = DateTime.utc(2026, 9, 13);
      AppNotification snapshot(
        String taskId,
        String eventId,
        AppNotificationTaskStatus taskStatus,
        int minute, {
        AppNotificationStatus status = AppNotificationStatus.unread,
      }) => AppNotification(
        notificationId: 'reused-row',
        eventId: eventId,
        eventType: 'agent_run.${taskStatus.name}',
        scene: 'chat',
        targetType: 'thread',
        targetId: 'thread-1',
        title: taskId,
        body: taskStatus.name,
        status: status,
        taskStatus: taskStatus,
        taskId: taskId,
        createdAt: now,
        updatedAt: now.add(Duration(minutes: minute)),
      );
      final api = _MutableNotificationApi(
        snapshot(
          'task-1',
          'failure',
          AppNotificationTaskStatus.failed,
          1,
          status: AppNotificationStatus.read,
        ),
      );
      final controller = NotificationController(api: api);
      addTearDown(controller.dispose);
      await controller.load(forceRemote: true);
      api.notification = snapshot(
        'task-1',
        'retry',
        AppNotificationTaskStatus.running,
        2,
      );
      await controller.load(forceRemote: true);
      expect(
        controller.state.items.single.taskStatus,
        AppNotificationTaskStatus.running,
      );
      expect(controller.state.items.single.isUnread, isTrue);
      api.notification = snapshot(
        'task-1',
        'done',
        AppNotificationTaskStatus.succeeded,
        3,
        status: AppNotificationStatus.read,
      );
      await controller.load(forceRemote: true);
      api.notification = snapshot(
        'task-2',
        'new-attempt',
        AppNotificationTaskStatus.running,
        4,
      );
      await controller.load(forceRemote: true);
      expect(controller.state.items.single.taskId, 'task-2');
      expect(
        controller.state.items.single.taskStatus,
        AppNotificationTaskStatus.running,
      );
      expect(controller.state.items.single.isUnread, isTrue);
    },
  );

  test('exhausted pagination does not request the first page again', () async {
    final api = _ControlledNotificationApi();
    final controller = NotificationController(api: api);
    addTearDown(controller.dispose);
    final initial = controller.load();
    api.completeList(0, <AppNotification>[_unread]);
    await initial;
    await controller.load(refresh: false);
    expect(api.listCalls, hasLength(1));
  });

  test('a future-dated cache cannot suppress the remote refresh', () async {
    final api = _ControlledNotificationApi();
    final controller = NotificationController(
      api: api,
      now: () => DateTime.utc(2026, 9, 5),
      resolution: _CachedResolutionPort(
        CachedNotificationPage(
          items: <AppNotification>[_unread],
          nextCursor: null,
          rejectedItemCount: 0,
          savedAt: DateTime.utc(2026, 9, 6),
        ),
      ),
    );
    addTearDown(controller.dispose);
    final pending = controller.load();
    expect(api.listCalls, hasLength(1));
    api.completeList(0, <AppNotification>[_unread]);
    await pending;
  });

  group('NotificationApi', () {
    test(
      'loads notifications and marks an item read through fixed endpoints',
      () async {
        final transport = _QueueTransport(<ApiTransportResponse>[
          const ApiTransportResponse(
            status: 200,
            body: <String, Object?>{
              'success': true,
              'data': <String, Object?>{
                'items': <Object?>[
                  <String, Object?>{
                    'notificationId': 'notice-1',
                    'scene': 'recording',
                    'targetType': 'recording',
                    'targetId': 'recording-1',
                    'title': '转写完成',
                    'body': '客户访谈已经可以查看。',
                    'status': 'unread',
                    'createdAt': '2026-07-12T08:00:00Z',
                  },
                ],
                'nextCursor': 'cursor-2',
              },
            },
          ),
          const ApiTransportResponse(
            status: 200,
            body: <String, Object?>{
              'success': true,
              'data': <String, Object?>{
                'notification': <String, Object?>{
                  'notificationId': 'notice-1',
                  'scene': 'recording',
                  'targetType': 'recording',
                  'targetId': 'recording-1',
                  'title': '转写完成',
                  'body': '客户访谈已经可以查看。',
                  'status': 'read',
                  'createdAt': '2026-07-12T08:00:00Z',
                },
                'redDotState': <Object?>[],
              },
            },
          ),
        ]);
        final api = NotificationApi(apiClient: _apiClient(transport));

        final listed = await api.listNotifications(limit: 20);
        final marked = await api.markRead(
          notificationId: 'notice-1',
          idempotency: const IdempotencyRequestContext(
            explicitKey: 'idem-notification-read-notice-1',
          ),
        );

        expect(listed.ok, isTrue);
        expect(listed.data?.items.single.isUnread, isTrue);
        expect(listed.data?.nextCursor, 'cursor-2');
        expect(marked.data?.status, AppNotificationStatus.read);
        expect(transport.requests[0].url.path, '/api/v1/notifications');
        expect(transport.requests[0].url.queryParameters['limit'], '20');
        expect(
          transport.requests[1].url.path,
          '/api/v1/notifications/notice-1/read',
        );
        expect(
          transport.requests[1].headers['X-Idempotency-Key'],
          'idem-notification-read-notice-1',
        );
      },
    );

    test('accepts the deployed direct mark-read receipt', () async {
      final transport = _QueueTransport(<ApiTransportResponse>[
        const ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'data': <String, Object?>{
              'notificationId': 'notice-direct-read-1',
              'status': 'read',
            },
          },
        ),
      ]);

      final result = await NotificationApi(apiClient: _apiClient(transport))
          .markRead(
            notificationId: 'notice-direct-read-1',
            idempotency: const IdempotencyRequestContext(
              explicitKey: 'idem-notification-read-notice-direct-read-1',
            ),
          );

      expect(result.ok, isTrue);
      expect(result.data?.isReadReceipt, isTrue);
      expect(result.data?.notificationId, 'notice-direct-read-1');
      expect(result.data?.status, AppNotificationStatus.read);
    });

    test('replaces unsafe display fields with product-owned copy', () async {
      final transport = _QueueTransport(<ApiTransportResponse>[
        const ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'data': <String, Object?>{
              'items': <Object?>[
                <String, Object?>{
                  'notificationId': 'notice-1',
                  'scene': 'recording',
                  'targetType': 'recording',
                  'targetId': 'recording-1',
                  'title': 'file:///private/internal.log',
                  'body': 'runtime: internal execution detail',
                  'status': 'unread',
                },
              ],
            },
          },
        ),
      ]);

      final result = await NotificationApi(
        apiClient: _apiClient(transport),
      ).listNotifications();

      expect(result.ok, isTrue);
      expect(result.data?.items, hasLength(1));
      expect(result.data?.items.single.title, '新消息');
      expect(result.data?.items.single.body, '新消息');
      expect(result.data?.items.single.title, isNot(contains('file://')));
      expect(result.data?.items.single.body, isNot(contains('runtime:')));
    });

    test('isolates a structurally malformed row from the page', () async {
      final transport = _QueueTransport(<ApiTransportResponse>[
        const ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'data': <String, Object?>{
              'items': <Object?>[
                <String, Object?>{
                  'notificationId': 'notice-malformed',
                  'status': 'unread',
                  'payload': 'not-an-object',
                },
                <String, Object?>{
                  'notificationId': 'notice-valid',
                  'scene': 'recording',
                  'targetType': 'recording',
                  'targetId': 'recording-valid',
                  'title': '转写完成',
                  'body': '已可查看转写结果。',
                  'status': 'unread',
                },
              ],
            },
          },
        ),
      ]);

      final result = await NotificationApi(
        apiClient: _apiClient(transport),
      ).listNotifications();

      expect(result.ok, isTrue);
      expect(result.data?.items.map((item) => item.notificationId), <String>[
        'notice-valid',
      ]);
      expect(result.data?.rejectedItemCount, 1);
      expect(
        parseAppNotification(<String, Object?>{
          'notificationId': 'notice-malformed',
          'status': 'unread',
          'payload': 'not-an-object',
        }),
        isNull,
      );
    });

    test('keeps a row but removes an invalid business destination', () {
      final notification = parseAppNotification(<String, Object?>{
        'notificationId': 'notice-thread-without-target',
        'eventType': 'agent_run.succeeded',
        'scene': 'chat',
        'targetType': 'thread',
        'status': 'unread',
        'title': '回复已完成',
        'body': '可以查看最新回复。',
      });

      expect(notification, isNotNull);
      expect(notification?.targetType, 'notification');
      expect(notification?.targetId, 'notice-thread-without-target');
      expect(notification?.scene, 'chat');
    });

    test('keeps target provenance atomic across root and payload fields', () {
      final partialRoot = parseAppNotification(<String, Object?>{
        'notificationId': 'notice-partial-root',
        'eventType': 'hotspot_suggestion',
        'scene': 'chat',
        'targetType': 'thread',
        'targetId': '',
        'status': 'unread',
        'payload': <String, Object?>{
          'suggestionId': 'stale-suggestion-1',
          'title': '热点建议已生成',
          'body': '可以查看新的内容方向。',
        },
      });
      final explicitNullRoot = parseAppNotification(<String, Object?>{
        'notificationId': 'notice-null-root',
        'eventType': 'agent_run.succeeded',
        'targetType': null,
        'targetId': null,
        'status': 'unread',
        'payload': <String, Object?>{
          'scene': 'chat',
          'targetType': 'thread',
          'targetId': 'stale-thread-1',
          'title': '回复已完成',
          'body': '可以查看最新回复。',
        },
      });

      expect(partialRoot?.targetType, 'notification');
      expect(partialRoot?.targetId, 'notice-partial-root');
      expect(explicitNullRoot?.targetType, 'notification');
      expect(explicitNullRoot?.targetId, 'notice-null-root');
    });

    test('keeps ordinary workspace prose as display content', () {
      final notification = parseAppNotification(<String, Object?>{
        'notificationId': 'notice-workspace-1',
        'scene': 'notification',
        'targetType': 'notification',
        'targetId': 'notice-workspace-1',
        'title': 'Workspace 周报已生成',
        'body': '可以在 workspace 中查看本周的客户访谈。',
        'status': 'unread',
      });

      expect(notification?.title, 'Workspace 周报已生成');
      expect(notification?.body, '可以在 workspace 中查看本周的客户访谈。');
    });

    test('parses the nested public contract and retains legacy rows', () {
      final current = parseAppNotification(<String, Object?>{
        'notificationId': 'notice-chat-1',
        'status': 'unread',
        'createdAt': '2026-08-13T08:00:00Z',
        'payload': <String, Object?>{
          'eventType': 'agent_run.succeeded',
          'scene': 'chat',
          'targetType': 'thread',
          'targetId': 'thread-1',
          'title': '回复已完成',
          'body': '可以继续查看会话。',
        },
      });
      final legacy = parseAppNotification(<String, Object?>{
        'notificationId': 'notice-recording-1',
        'status': 'read',
        'targetType': 'recording',
        'targetId': 'recording-1',
        'title': '转写完成',
        'body': '可以查看结果。',
      });

      expect(current?.eventType, 'agent_run.succeeded');
      expect(current?.scene, 'chat');
      expect(current?.targetType, 'thread');
      expect(legacy?.eventType, 'system.legacy');
      expect(legacy?.scene, 'recording');
    });

    test(
      'retains Workspace provenance and rejects contradictory ownership',
      () {
        final root = parseAppNotification(<String, Object?>{
          'notificationId': 'notice-workspace-root',
          'workspaceId': 'workspace-a',
          'eventType': 'agent_run.succeeded',
          'scene': 'chat',
          'targetType': 'thread',
          'targetId': 'thread-a',
          'title': '回复已完成',
          'body': '可以查看回复。',
          'status': 'unread',
        });
        final nested = parseAppNotification(<String, Object?>{
          'notificationId': 'notice-workspace-payload',
          'status': 'unread',
          'payload': <String, Object?>{
            'workspaceId': 'workspace-b',
            'eventType': 'agent_run.running',
            'scene': 'chat',
            'targetType': 'thread',
            'targetId': 'thread-b',
            'title': '正在回复',
            'body': '回复仍在生成。',
          },
        });
        final contradictory = parseAppNotification(<String, Object?>{
          'notificationId': 'notice-workspace-conflict',
          'workspaceId': 'workspace-a',
          'status': 'unread',
          'payload': <String, Object?>{
            'workspaceId': 'workspace-b',
            'eventType': 'agent_run.running',
            'scene': 'chat',
            'targetType': 'thread',
            'targetId': 'thread-b',
            'title': '正在回复',
            'body': '回复仍在生成。',
          },
        });

        expect(root?.workspaceId, 'workspace-a');
        expect(nested?.workspaceId, 'workspace-b');
        expect(contradictory, isNull);
      },
    );

    test(
      'keeps exact Workspace rows and the account-level daily notice',
      () async {
        Map<String, Object?> row(String id, {String? workspaceId}) =>
            <String, Object?>{
              'notificationId': id,
              if (workspaceId != null) 'workspaceId': workspaceId,
              'eventType': 'agent_run.succeeded',
              'scene': 'chat',
              'targetType': 'thread',
              'targetId': 'thread-$id',
              'title': '回复已完成',
              'body': '可以查看回复。',
              'status': 'unread',
            };
        final transport = _QueueTransport(<ApiTransportResponse>[
          ApiTransportResponse(
            status: 200,
            body: <String, Object?>{
              'success': true,
              'data': <String, Object?>{
                'items': <Object?>[
                  row('matching', workspaceId: 'workspace-a'),
                  row('foreign', workspaceId: 'workspace-b'),
                  row('legacy'),
                  <String, Object?>{
                    'notificationId': 'daily-topic',
                    'eventType': 'topic_recommendation.ready',
                    'scene': 'work_ai',
                    'targetType': 'topic_recommendation',
                    'targetId': 'recommendation-1',
                    'status': 'unread',
                  },
                  <String, Object?>{
                    'notificationId': 'legacy-hotspot',
                    'eventType': 'hotspot_suggestion',
                    'scene': 'feed',
                    'targetType': 'hotspot_suggestion',
                    'targetId': 'suggestion-1',
                    'title': '其他工作区热点',
                    'body': '不应显示。',
                    'status': 'unread',
                  },
                ],
              },
            },
          ),
        ]);

        final result = await NotificationApi(
          apiClient: _apiClient(transport),
          workspaceId: 'workspace-a',
        ).listNotifications();

        expect(result.data?.items.map((item) => item.notificationId), <String>[
          'matching',
          'daily-topic',
        ]);
      },
    );

    test('Workspace provenance survives the local page cache', () async {
      final preferences = AppPreferencesDao(AppDatabase());
      final cache = PersistentNotificationResolutionPort(
        dao: preferences,
        userScope: 'account-a\u0000workspace-a',
      );
      await cache.saveNotificationPage(
        const AppNotificationPage(
          items: <AppNotification>[
            AppNotification(
              notificationId: 'notice-cached-workspace',
              workspaceId: 'workspace-a',
              eventType: 'agent_run.succeeded',
              scene: 'chat',
              targetType: 'thread',
              targetId: 'thread-a',
              title: '回复已完成',
              body: '可以查看回复。',
              status: AppNotificationStatus.unread,
            ),
          ],
        ),
      );

      expect(
        cache.loadNotificationPage()?.items.single.workspaceId,
        'workspace-a',
      );
      expect(
        PersistentNotificationResolutionPort(
          dao: preferences,
          userScope: 'account-a\u0000workspace-b',
        ).loadNotificationPage(),
        isNull,
      );
    });

    test(
      'supplies display copy for a deployed topic recommendation payload',
      () {
        final notification = parseAppNotification(<String, Object?>{
          'notificationId': 'notice-topic-1',
          'eventId': 'event-topic-1',
          'status': 'unread',
          'payload': <String, Object?>{
            'eventType': 'topic_recommendation.ready',
            'recommendationId': 'recommendation-1',
          },
        });

        expect(notification, isNotNull);
        expect(notification?.scene, 'work_ai');
        expect(notification?.targetType, 'topic_recommendation');
        expect(notification?.targetId, 'recommendation-1');
        expect(notification?.title, '每日推荐已生成');
        expect(notification?.body, '今天的推荐内容已经准备好。');
      },
    );

    test('retains and marks read production hotspot identifiers', () async {
      final notificationId = _identifierOfLength('notification_', 215);
      final eventId = _identifierOfLength('event_', 132);
      final suggestionId = _identifierOfLength('hotspot_suggestion_', 132);
      final transport = _QueueTransport(<ApiTransportResponse>[
        ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'data': <String, Object?>{
              'items': <Object?>[
                <String, Object?>{
                  'notificationId': notificationId,
                  'eventId': eventId,
                  'eventType': 'hotspot_suggestion',
                  'targetType': '',
                  'targetId': '',
                  'status': 'unread',
                  'payload': <String, Object?>{
                    'suggestionId': suggestionId,
                    'title': '热点建议已生成',
                    'body': '可以查看新的内容方向。',
                  },
                },
              ],
            },
          },
        ),
        ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'data': <String, Object?>{
              'notificationId': notificationId,
              'status': 'read',
            },
          },
        ),
      ]);
      final api = NotificationApi(apiClient: _apiClient(transport));

      final listed = await api.listNotifications();
      final notification = listed.data?.items.single;
      final marked = await api.markRead(
        notificationId: notificationId,
        idempotency: const IdempotencyRequestContext(
          explicitKey: 'idem-hotspot-notification-read',
        ),
      );

      expect(notification?.notificationId, notificationId);
      expect(notification?.eventId, eventId);
      expect(notification?.targetType, 'hotspot_suggestion');
      expect(notification?.targetId, suggestionId);
      expect(marked.data?.notificationId, notificationId);
      expect(marked.data?.status, AppNotificationStatus.read);
      expect(
        transport.requests[1].url.path,
        '/api/v1/notifications/$notificationId/read',
      );
      expect(
        parseAppNotification(<String, Object?>{
          'notificationId': _identifierOfLength('notification_', 513),
          'status': 'unread',
        }),
        isNull,
      );
    });

    test('accepts production-length task ids within the dedicated bound', () {
      final taskId = _identifierOfLength('agent_run_', 140);
      Map<String, Object?> payload(String candidate) => <String, Object?>{
        'notificationId': 'notice-long-task-1',
        'status': 'unread',
        'payload': <String, Object?>{
          'eventType': 'agent_run.succeeded',
          'scene': 'chat',
          'targetType': 'thread',
          'targetId': 'thread-1',
          'title': '回复已完成',
          'body': '可以查看回复。',
          'taskStatus': 'succeeded',
          'taskId': candidate,
        },
      };

      expect(parseAppNotification(payload(taskId))?.taskId, taskId);
      expect(
        parseAppNotification(payload(_identifierOfLength('agent_run_', 513))),
        isNull,
      );
    });

    test(
      'bootstrap-unavailable adapter fails closed without mock data',
      () async {
        const api = UnavailableNotificationApi();
        const store = SubmissionKeyStore.empty;

        final listed = await api.listNotifications();
        final marked = await api.markRead(
          notificationId: 'notice-1',
          idempotency: const IdempotencyRequestContext(
            explicitKey: 'idem-notification-read-notice-1',
          ),
          idempotencyStore: store,
        );

        expect(listed.ok, isFalse);
        expect(listed.data, isNull);
        expect(listed.error?.code, 'NOTIFICATION_SERVICE_NOT_READY');
        expect(listed.error?.isRetryable, isTrue);
        expect(marked.ok, isFalse);
        expect(marked.data, isNull);
        expect(marked.idempotencyStore, same(store));
      },
    );
  });

  group('NotificationController', () {
    test('hydrates durable resolution before its first observable state', () {
      final api = _ControlledNotificationApi();
      final resolution = _TaskResolutionPort()
        ..handledIds.add('delivery:handled-before-build')
        ..locallyReadIds.add('delivery:read-before-build')
        ..handledTaskIds.add('task-before-build');
      final controller = NotificationController(
        api: api,
        resolution: resolution,
      );
      addTearDown(controller.dispose);

      expect(controller.state.resolutionHydrated, isTrue);
      expect(
        controller.state.handledIds,
        contains('delivery:handled-before-build'),
      );
      expect(
        controller.state.locallyReadIds,
        contains('delivery:read-before-build'),
      );
      expect(controller.state.handledTaskIds, contains('task-before-build'));
      expect(controller.state.resolutionIsDemo, isTrue);
      expect(api.listCalls, isEmpty);
    });

    test(
      'upserts the server mark-read mutation without local success fallback',
      () async {
        final api = _FakeNotificationApi();
        final controller = NotificationController(api: api);
        addTearDown(controller.dispose);

        await controller.load();
        final item = controller.state.items.single;
        expect(await controller.markRead(item), isTrue);

        expect(
          controller.state.items.single.status,
          AppNotificationStatus.read,
        );
        expect(api.markReadIds, <String>['notice-1']);
        expect(controller.state.lastErrorCode, isNull);
      },
    );

    test(
      'merges a sparse read receipt without losing notification metadata',
      () async {
        final controller = NotificationController(
          api: _ReadReceiptNotificationApi(),
        );
        addTearDown(controller.dispose);

        await controller.load();
        final original = controller.state.items.single;

        expect(await controller.markRead(original), isTrue);

        final updated = controller.state.items.single;
        expect(updated.status, AppNotificationStatus.read);
        expect(updated.isReadReceipt, isFalse);
        expect(updated.eventType, original.eventType);
        expect(updated.scene, original.scene);
        expect(updated.targetType, original.targetType);
        expect(updated.targetId, original.targetId);
        expect(updated.title, original.title);
        expect(updated.body, original.body);
      },
    );

    test('read remains unresolved until handled is persisted', () async {
      final api = _FakeNotificationApi();
      final resolution = _FakeResolutionPort();
      final controller = NotificationController(
        api: api,
        resolution: resolution,
      );
      addTearDown(controller.dispose);

      await controller.load();
      final item = controller.state.items.single;
      expect(await controller.markRead(item), isTrue);
      expect(controller.state.unresolvedItems, hasLength(1));

      final readItem = controller.state.items.single;
      expect(await controller.markHandled(readItem), isTrue);
      expect(controller.state.unresolvedItems, isEmpty);
      expect(resolution.handledIds, <String>{
        notificationDeliveryResolutionKey(readItem),
      });
      expect(controller.state.items.single.status, AppNotificationStatus.read);
    });

    test('a new event revision reopens a reused notification row', () async {
      final api = _MutableNotificationApi(
        const AppNotification(
          notificationId: 'notice-reused',
          eventId: 'event-1',
          eventType: 'topic_recommendation.ready',
          scene: 'recommendation',
          targetType: 'topic_recommendation',
          targetId: 'topic-1',
          title: '第一版推荐',
          body: '第一版内容已经生成。',
          status: AppNotificationStatus.unread,
        ),
      );
      final resolution = _FakeResolutionPort();
      final controller = NotificationController(
        api: api,
        resolution: resolution,
      );
      addTearDown(controller.dispose);

      await controller.load(forceRemote: true);
      expect(
        await controller.markHandled(controller.state.items.single),
        isTrue,
      );
      expect(controller.state.unresolvedItems, isEmpty);

      api.notification = const AppNotification(
        notificationId: 'notice-reused',
        eventId: 'event-2',
        eventType: 'topic_recommendation.ready',
        scene: 'recommendation',
        targetType: 'topic_recommendation',
        targetId: 'topic-1',
        title: '第二版推荐',
        body: '同一聚合行收到了新的业务事件。',
        status: AppNotificationStatus.unread,
      );
      await controller.load(refresh: true, forceRemote: true);

      expect(controller.state.unresolvedItems, hasLength(1));
      expect(controller.state.unresolvedItems.single.eventId, 'event-2');
    });

    test(
      'keeps versioned reads off the unversioned backend mutation',
      () async {
        final api = _FakeNotificationApi();
        final controller = NotificationController(api: api);
        addTearDown(controller.dispose);
        const firstRevision = AppNotification(
          notificationId: 'notice-1',
          eventId: 'event-1',
          eventType: 'recording.completed',
          scene: 'recording',
          targetType: 'recording',
          targetId: 'recording-1',
          title: '第一版转写完成',
          body: '第一版结果可以查看。',
          status: AppNotificationStatus.unread,
        );
        const secondRevision = AppNotification(
          notificationId: 'notice-1',
          eventId: 'event-2',
          eventType: 'recording.completed',
          scene: 'recording',
          targetType: 'recording',
          targetId: 'recording-1',
          title: '第二版转写完成',
          body: '聚合行已经承载新的业务事件。',
          status: AppNotificationStatus.unread,
        );

        expect(await controller.markRead(firstRevision), isTrue);
        expect(await controller.markRead(secondRevision), isTrue);
        expect(await controller.markRead(firstRevision), isTrue);

        final firstKey = notificationDeliveryResolutionKey(firstRevision);
        final secondKey = notificationDeliveryResolutionKey(secondRevision);
        expect(api.markReadKeys, isEmpty);
        expect(controller.state.locallyReadIds, <String>{firstKey, secondKey});
      },
    );

    test(
      'a local read receipt cannot mark a newer row revision read',
      () async {
        const firstRevision = AppNotification(
          notificationId: 'notice-read-race',
          eventId: 'event-read-race-1',
          eventType: 'topic_recommendation.ready',
          scene: 'recommendation',
          targetType: 'topic_recommendation',
          targetId: 'topic-read-race-1',
          title: '第一版推荐',
          body: '第一版内容已经生成。',
          status: AppNotificationStatus.unread,
        );
        const secondRevision = AppNotification(
          notificationId: 'notice-read-race',
          eventId: 'event-read-race-2',
          eventType: 'topic_recommendation.ready',
          scene: 'recommendation',
          targetType: 'topic_recommendation',
          targetId: 'topic-read-race-2',
          title: '第二版推荐',
          body: '同一消息行已经承载新的业务事件。',
          status: AppNotificationStatus.unread,
        );
        final api = _RevisionReadRaceNotificationApi(firstRevision);
        final controller = NotificationController(api: api);
        addTearDown(controller.dispose);
        await controller.load(forceRemote: true);

        expect(await controller.markRead(firstRevision), isTrue);
        final firstKey = notificationDeliveryResolutionKey(firstRevision);
        expect(controller.state.locallyReadIds, <String>{firstKey});
        expect(api.markReadCalls, 0);

        api.notification = secondRevision;
        await controller.load(forceRemote: true);
        expect(controller.state.items.single.eventId, secondRevision.eventId);
        expect(controller.state.items.single.isUnread, isTrue);
        expect(controller.state.isReadPending(secondRevision), isFalse);

        final secondKey = notificationDeliveryResolutionKey(secondRevision);
        expect(controller.state.locallyReadIds, isNot(contains(secondKey)));
        expect(await controller.markRead(secondRevision), isTrue);
        expect(controller.state.locallyReadIds, <String>{firstKey, secondKey});
        expect(controller.state.items.single.eventId, secondRevision.eventId);
        expect(
          controller.state.items.single.status,
          AppNotificationStatus.read,
        );
        expect(api.markReadCalls, 0);
      },
    );

    test('a replayed event keeps its cached read state and old time', () async {
      final createdAt = DateTime.utc(2026, 9, 1, 8);
      final api = _MutableNotificationApi(
        AppNotification(
          notificationId: 'notice-replayed',
          eventId: 'event-replayed',
          eventType: 'topic_recommendation.ready',
          scene: 'work_ai',
          targetType: 'topic_recommendation',
          targetId: 'recommendation-replayed',
          title: '同一条推荐',
          body: '同一事件不能重复提醒。',
          status: AppNotificationStatus.unread,
          createdAt: createdAt,
          updatedAt: createdAt,
        ),
      );
      final controller = NotificationController(api: api);
      addTearDown(controller.dispose);

      await controller.load(forceRemote: true);
      expect(await controller.markRead(controller.state.items.single), isTrue);
      expect(controller.state.items.single.status, AppNotificationStatus.read);

      api.notification = AppNotification(
        notificationId: 'notice-replayed',
        eventId: 'event-replayed',
        eventType: 'topic_recommendation.ready',
        scene: 'work_ai',
        targetType: 'topic_recommendation',
        targetId: 'recommendation-replayed',
        title: '同一条推荐',
        body: '后端重复投递了同一事件。',
        status: AppNotificationStatus.unread,
        createdAt: createdAt,
        updatedAt: DateTime.utc(2026, 9, 10, 8),
      );
      await controller.load(forceRemote: true);

      expect(controller.state.items.single.status, AppNotificationStatus.read);
      expect(controller.state.items.single.inboxOccurredAt, createdAt);
    });

    test('a thrown read request clears only its delivery busy key', () async {
      final api = _RevisionReadRaceNotificationApi(_unread);
      final controller = NotificationController(api: api);
      addTearDown(controller.dispose);
      await controller.load(forceRemote: true);

      final read = controller.markRead(controller.state.items.single);
      final deliveryKey = notificationDeliveryResolutionKey(_unread);
      expect(controller.state.pendingReadDeliveryKeys, <String>{deliveryKey});

      api.failRead(_unread);

      expect(await read, isFalse);
      expect(controller.state.pendingReadDeliveryKeys, isEmpty);
      expect(controller.state.lastErrorCode, 'NOTIFICATION_MARK_READ_FAILED');
      expect(controller.state.items.single.isUnread, isTrue);
    });

    test('sorts merged unread events without promoting read history', () async {
      final api = _ControlledNotificationApi();
      final controller = NotificationController(api: api);
      addTearDown(controller.dispose);
      final olderUpdatedLater = AppNotification(
        notificationId: 'notice-old',
        eventType: 'recording.completed',
        scene: 'recording',
        targetType: 'recording',
        targetId: 'recording-old',
        title: '较早消息',
        body: '这条消息后来被标记为已读。',
        status: AppNotificationStatus.read,
        createdAt: DateTime.utc(2026, 9, 2, 8),
        updatedAt: DateTime.utc(2026, 9, 2, 12),
      );
      final newerCreatedEarlierUpdate = AppNotification(
        notificationId: 'notice-new',
        eventType: 'recording.completed',
        scene: 'recording',
        targetType: 'recording',
        targetId: 'recording-new',
        title: '较新消息',
        body: '创建时间决定它排在前面。',
        status: AppNotificationStatus.unread,
        createdAt: DateTime.utc(2026, 9, 2, 10),
        updatedAt: DateTime.utc(2026, 9, 2, 10),
      );
      final legacyUpdatedOnly = AppNotification(
        notificationId: 'notice-legacy',
        eventType: 'system.legacy',
        scene: 'notification',
        targetType: 'notification',
        targetId: 'notice-legacy',
        title: '旧协议消息',
        body: '缺少创建时间时才使用更新时间。',
        status: AppNotificationStatus.unread,
        updatedAt: DateTime.utc(2026, 9, 2, 9),
      );
      final reusedForNewEvent = AppNotification(
        notificationId: 'notice-reused',
        eventType: 'topic_recommendation.ready',
        scene: 'work_ai',
        targetType: 'topic_recommendation',
        targetId: 'recommendation-new',
        title: '复用行的新事件',
        body: '当前事件更新时间决定它排在前面。',
        status: AppNotificationStatus.unread,
        eventId: 'event-new',
        createdAt: DateTime.utc(2026, 9, 1),
        updatedAt: DateTime.utc(2026, 9, 2, 13),
      );

      final load = controller.load(forceRemote: true);
      api.completeList(0, <AppNotification>[
        olderUpdatedLater,
        newerCreatedEarlierUpdate,
        legacyUpdatedOnly,
        reusedForNewEvent,
      ]);
      await load;

      expect(
        controller.state.items.map((item) => item.notificationId),
        <String>['notice-reused', 'notice-new', 'notice-legacy', 'notice-old'],
      );
    });

    test('coalesces invalidations received during an active refresh', () async {
      final api = _ControlledNotificationApi();
      final controller = NotificationController(api: api);
      addTearDown(controller.dispose);

      final initial = controller.load(forceRemote: true);
      expect(api.listCalls, hasLength(1));
      final firstInvalidation = controller.load(forceRemote: true);
      final secondInvalidation = controller.load(forceRemote: true);
      expect(identical(initial, firstInvalidation), isTrue);
      expect(identical(initial, secondInvalidation), isTrue);

      api.completeList(0, const <AppNotification>[_unread]);
      await Future<void>.delayed(Duration.zero);
      expect(api.listCalls, hasLength(2));
      api.completeList(1, const <AppNotification>[_unread]);
      await Future.wait(<Future<void>>[
        initial,
        firstInvalidation,
        secondInvalidation,
      ]);

      expect(api.listCalls, hasLength(2));
      expect(api.listLimits, everyElement(100));
    });

    test('a stale list response cannot undo a confirmed read', () async {
      final api = _ControlledNotificationApi(readResponse: _newerRead);
      final controller = NotificationController(api: api);
      addTearDown(controller.dispose);

      final initial = controller.load(forceRemote: true);
      api.completeList(0, <AppNotification>[_olderUnread]);
      await initial;

      final refresh = controller.load(forceRemote: true);
      expect(api.listCalls, hasLength(2));
      expect(await controller.markRead(controller.state.items.single), isTrue);
      api.completeList(1, <AppNotification>[_olderUnread]);
      await refresh;

      expect(controller.state.items.single.status, AppNotificationStatus.read);
    });

    test(
      'load drain settles after a read completes during cache save',
      () async {
        final firstSaveGate = Completer<void>();
        final resolution = _CachedResolutionPort(
          CachedNotificationPage(
            items: <AppNotification>[_olderUnread],
            nextCursor: null,
            savedAt: DateTime.utc(2026, 9, 1),
          ),
          firstSaveGate: firstSaveGate,
        );
        final api = _ControlledNotificationApi(readResponse: _newerRead);
        final controller = NotificationController(
          api: api,
          resolution: resolution,
        );
        addTearDown(controller.dispose);

        final load = controller.load(forceRemote: true);
        api.completeList(0, <AppNotification>[_olderUnread]);
        await Future<void>.delayed(Duration.zero);
        expect(resolution.saveCalls, 1);

        final read = controller.markRead(controller.state.items.single);
        expect(controller.state.status, NotificationControllerStatus.loading);

        firstSaveGate.complete();
        expect(await read, isTrue);
        await load;
        expect(controller.state.status, NotificationControllerStatus.ready);
        expect(controller.state.pendingReadDeliveryKeys, isEmpty);
        expect(resolution.saveCalls, 2);
        expect(
          resolution.savedPages.last.items.single.status,
          AppNotificationStatus.read,
        );
      },
    );

    test('local read remains unresolved and persists independently', () async {
      final resolution = _FakeResolutionPort();
      final controller = NotificationController(
        api: _FakeNotificationApi(),
        resolution: resolution,
      );
      addTearDown(controller.dispose);

      await controller.load();
      const localId = 'local:documentImport:task-1';
      expect(await controller.markLocalRead(localId), isTrue);
      expect(controller.state.locallyReadIds, contains(localId));
      expect(controller.state.handledIds, isNot(contains(localId)));
      expect(await controller.markHandledId(localId), isTrue);
      expect(controller.state.handledIds, contains(localId));
    });

    test(
      'concurrent handled writes preserve siblings and catch persistence errors',
      () async {
        final resolution = _ControlledResolutionPort();
        final controller = NotificationController(
          api: _FakeNotificationApi(),
          resolution: resolution,
        );
        addTearDown(controller.dispose);

        final first = controller.markHandledId('handled-a');
        final second = controller.markHandledId('handled-b');
        expect(controller.state.pendingHandledIds, <String>{
          'handled-a',
          'handled-b',
        });

        resolution.completeHandled('handled-a');
        expect(await first, isTrue);
        expect(controller.state.pendingHandledIds, <String>{'handled-b'});
        expect(controller.state.handledIds, <String>{'handled-a'});

        resolution.failHandled('handled-b');
        expect(await second, isFalse);
        expect(controller.state.pendingHandledIds, isEmpty);
        expect(controller.state.handledIds, <String>{'handled-a'});
        expect(
          controller.state.lastErrorCode,
          'NOTIFICATION_HANDLE_SAVE_FAILED',
        );
      },
    );

    test(
      'concurrent local reads preserve siblings and catch persistence errors',
      () async {
        final resolution = _ControlledResolutionPort();
        final controller = NotificationController(
          api: _FakeNotificationApi(),
          resolution: resolution,
        );
        addTearDown(controller.dispose);

        final first = controller.markLocalRead('local-a');
        final second = controller.markLocalRead('local-b');
        expect(controller.state.pendingLocalReadIds, <String>{
          'local-a',
          'local-b',
        });

        resolution.completeLocalRead('local-a');
        expect(await first, isTrue);
        expect(controller.state.pendingLocalReadIds, <String>{'local-b'});
        expect(controller.state.locallyReadIds, <String>{'local-a'});

        resolution.failLocalRead('local-b');
        expect(await second, isFalse);
        expect(controller.state.pendingLocalReadIds, isEmpty);
        expect(controller.state.locallyReadIds, <String>{'local-a'});
        expect(
          controller.state.lastErrorCode,
          'NOTIFICATION_LOCAL_READ_SAVE_FAILED',
        );
      },
    );

    test(
      'persists a terminal task acknowledgement separately from manual rows',
      () async {
        final resolution = _TaskResolutionPort();
        final controller = NotificationController(
          api: _FakeNotificationApi(),
          resolution: resolution,
        );
        addTearDown(controller.dispose);

        await controller.load();
        expect(
          await controller.markTaskResultShown(
            taskId: 'agent-run-1',
            notificationIds: const <String>['notice-1'],
          ),
          isTrue,
        );

        expect(controller.state.handledTaskIds, contains('agent-run-1'));
        final deliveryKey = notificationDeliveryResolutionKey(
          controller.state.items.single,
        );
        expect(controller.state.handledIds, contains(deliveryKey));
        expect(controller.state.handledIds, isNot(contains('notice-1')));
        expect(resolution.handledIds, contains(deliveryKey));
        expect(resolution.handledTaskIds, contains('agent-run-1'));
      },
    );

    test(
      'keeps a terminal acknowledgement visible when persistence fails',
      () async {
        final resolution = _RetryableTaskResolutionPort();
        final controller = NotificationController(
          api: _FakeNotificationApi(),
          resolution: resolution,
        );
        addTearDown(controller.dispose);

        await controller.load();
        expect(
          await controller.markTaskResultShown(
            taskId: 'agent-run-offline-1',
            notificationIds: const <String>['notice-1'],
          ),
          isFalse,
        );

        expect(controller.state.handledTaskIds, isEmpty);
        expect(controller.state.handledIds, isEmpty);
        expect(controller.state.pendingHandledTaskIds, isEmpty);
        expect(resolution.handledIds, isEmpty);
        expect(
          controller.state.lastErrorCode,
          'NOTIFICATION_TASK_RESULT_SAVE_FAILED',
        );

        resolution.succeeds = true;
        expect(
          await controller.markTaskResultShown(
            taskId: 'agent-run-offline-1',
            notificationIds: const <String>['notice-1'],
          ),
          isTrue,
        );
        expect(
          controller.state.handledTaskIds,
          contains('agent-run-offline-1'),
        );
        expect(
          controller.state.handledIds,
          contains(
            notificationDeliveryResolutionKey(controller.state.items.single),
          ),
        );
      },
    );

    test(
      'stale task receipt cannot archive a reused notification row',
      () async {
        const firstTask = AppNotification(
          notificationId: 'notice-reused-task-row',
          eventId: 'event-task-a',
          eventType: 'agent.run.succeeded',
          scene: 'chat',
          targetType: 'thread',
          targetId: 'thread-a',
          title: '任务 A 已完成',
          body: '任务 A 的结果已经生成。',
          status: AppNotificationStatus.unread,
          taskId: 'task-a',
          taskStatus: AppNotificationTaskStatus.succeeded,
        );
        const replacementTask = AppNotification(
          notificationId: 'notice-reused-task-row',
          eventId: 'event-task-b',
          eventType: 'agent.run.started',
          scene: 'chat',
          targetType: 'thread',
          targetId: 'thread-b',
          title: '任务 B 处理中',
          body: '任务 B 仍在运行。',
          status: AppNotificationStatus.unread,
          taskId: 'task-b',
          taskStatus: AppNotificationTaskStatus.running,
        );
        final api = _MutableNotificationApi(firstTask);
        final resolution = _TaskResolutionPort();
        final controller = NotificationController(
          api: api,
          resolution: resolution,
        );
        addTearDown(controller.dispose);

        await controller.load();
        api.notification = replacementTask;
        await controller.load(forceRemote: true);
        final replacementDeliveryKey = notificationDeliveryResolutionKey(
          controller.state.items.single,
        );

        expect(
          await controller.markTaskResultShown(
            taskId: 'task-a',
            notificationIds: const <String>['notice-reused-task-row'],
          ),
          isTrue,
        );

        expect(controller.state.handledTaskIds, contains('task-a'));
        expect(
          controller.state.handledIds,
          isNot(contains(replacementDeliveryKey)),
        );
        expect(resolution.handledIds, isNot(contains(replacementDeliveryKey)));
        expect(controller.state.items.single.taskId, 'task-b');
      },
    );

    test(
      'persists and restores a production-length task acknowledgement',
      () async {
        final database = AppDatabase();
        final preferences = AppPreferencesDao(database);
        final taskId = _identifierOfLength('note_file_agent_run_', 140);
        final resolutionKey = notificationTaskResolutionKey(taskId);
        expect(resolutionKey, startsWith('task:'));
        expect(resolutionKey, hasLength(69));
        final resolution = PersistentNotificationResolutionPort(
          dao: preferences,
          userScope: 'account-long-task',
        );
        final controller = NotificationController(
          api: const UnavailableNotificationApi(),
          resolution: resolution,
        );
        addTearDown(controller.dispose);

        expect(await controller.markTaskResultShown(taskId: taskId), isTrue);
        expect(controller.state.handledTaskIds, contains(resolutionKey));
        expect(resolution.loadHandledTaskIds(), contains(resolutionKey));

        final restored = NotificationController(
          api: const UnavailableNotificationApi(),
          resolution: PersistentNotificationResolutionPort(
            dao: preferences,
            userScope: 'account-long-task',
          ),
        );
        addTearDown(restored.dispose);
        expect(restored.state.handledTaskIds, contains(resolutionKey));
      },
    );

    test('malformed persistent receipts fail closed during cold hydration', () {
      final database = AppDatabase();
      final preferences = AppPreferencesDao(database);
      const userScope = 'account-corrupt-receipts';
      final scopeDigest = sha256
          .convert(utf8.encode(userScope))
          .toString()
          .substring(0, 24);
      preferences.upsertValue(
        preferenceKey: 'notification-handled-$scopeDigest',
        value: jsonEncode(const <String>['delivery:recoverable']),
        updatedAt: DateTime.utc(2026, 9, 12).toIso8601String(),
      );
      preferences.upsertValue(
        preferenceKey: 'notification-handled-task-$scopeDigest',
        value: '["task:recoverable", 7]',
        updatedAt: DateTime.utc(2026, 9, 12).toIso8601String(),
      );
      final resolution = PersistentNotificationResolutionPort(
        dao: preferences,
        userScope: userScope,
      );
      final controller = NotificationController(
        api: const UnavailableNotificationApi(),
        resolution: resolution,
      );
      addTearDown(controller.dispose);

      expect(resolution.resolutionRecordsAreValid, isFalse);
      expect(controller.state.resolutionHydrated, isFalse);
      expect(controller.state.handledIds, contains('delivery:recoverable'));
      expect(controller.state.handledTaskIds, contains('task:recoverable'));
    });

    test(
      'forced refresh never publishes a stale cache before success',
      () async {
        final api = _ControlledNotificationApi();
        final cache = _CachedResolutionPort(
          CachedNotificationPage(
            items: const <AppNotification>[_unread],
            nextCursor: 'cursor-1',
            savedAt: DateTime.utc(2026, 8, 13),
          ),
        );
        final controller = NotificationController(
          api: api,
          resolution: cache,
          now: () => DateTime.utc(2026, 8, 13, 1),
        );
        addTearDown(controller.dispose);

        final load = controller.load(forceRemote: true);

        expect(controller.state.status, NotificationControllerStatus.loading);
        expect(controller.state.items, isEmpty);
        api.completeList(0, const <AppNotification>[]);
        await load;
        expect(controller.state.status, NotificationControllerStatus.ready);
        expect(controller.state.items, isEmpty);
        expect(controller.state.lastErrorCode, isNull);
      },
    );

    test('keeps a cached page visible when a refresh fails', () async {
      final cache = _CachedResolutionPort(
        CachedNotificationPage(
          items: const <AppNotification>[_unread],
          nextCursor: 'cursor-1',
          savedAt: DateTime.utc(2026, 8, 13),
        ),
      );
      final controller = NotificationController(
        api: const _FailingNotificationApi(),
        resolution: cache,
        now: () => DateTime.utc(2026, 8, 13, 1),
      );
      addTearDown(controller.dispose);

      final load = controller.load(forceRemote: true);

      expect(controller.state.status, NotificationControllerStatus.loading);
      expect(controller.state.items, isEmpty);
      await load;

      expect(controller.state.status, NotificationControllerStatus.ready);
      expect(controller.state.items, const <AppNotification>[_unread]);
      expect(controller.state.lastErrorCode, 'NOTIFICATION_LOAD_FAILED');
    });

    test('a thrown refresh uses the same cached offline fallback', () async {
      final cache = _CachedResolutionPort(
        CachedNotificationPage(
          items: const <AppNotification>[_unread],
          nextCursor: 'cursor-1',
          savedAt: DateTime.utc(2026, 8, 13),
        ),
      );
      final controller = NotificationController(
        api: const _ThrowingNotificationApi(),
        resolution: cache,
        now: () => DateTime.utc(2026, 8, 13, 1),
      );
      addTearDown(controller.dispose);

      await controller.load(forceRemote: true);

      expect(controller.state.status, NotificationControllerStatus.ready);
      expect(controller.state.items, const <AppNotification>[_unread]);
      expect(controller.state.lastErrorCode, 'NOTIFICATION_LOAD_FAILED');
    });

    test('overlapping read receipts settle the latest pending set', () async {
      final api = _ConcurrentNotificationApi();
      final controller = NotificationController(api: api);
      addTearDown(controller.dispose);
      await controller.load();

      final first = controller.markRead(controller.state.items[0]);
      final second = controller.markRead(controller.state.items[1]);
      final firstKey = notificationDeliveryResolutionKey(
        controller.state.items[0],
      );
      final secondKey = notificationDeliveryResolutionKey(
        controller.state.items[1],
      );
      expect(controller.state.pendingReadDeliveryKeys, <String>{
        firstKey,
        secondKey,
      });

      api.complete('notice-2');
      expect(await second, isTrue);
      expect(controller.state.pendingReadDeliveryKeys, <String>{firstKey});

      api.complete('notice-1');
      expect(await first, isTrue);
      expect(controller.state.pendingReadDeliveryKeys, isEmpty);
      expect(controller.state.items.every((item) => !item.isUnread), isTrue);
    });
  });
}

ApiClient _apiClient(ApiTransport transport) {
  return ApiClient(
    config: ApiClientConfig(
      baseUrl: Uri.parse('https://api.example.test'),
      clientVersion: 'test',
      deviceId: 'device-1',
      platform: 'ios',
      locale: 'zh-CN',
      getAccessToken: () async => 'access-token',
    ),
    transport: transport,
  );
}

final class _QueueTransport implements ApiTransport {
  _QueueTransport(this._responses);

  final List<ApiTransportResponse> _responses;
  final requests = <ApiTransportRequest>[];

  @override
  Future<ApiTransportResponse> send(ApiTransportRequest request) async {
    requests.add(request);
    return _responses.removeAt(0);
  }
}

final class _FakeNotificationApi implements NotificationApiPort {
  final markReadIds = <String>[];
  final markReadKeys = <String>[];

  @override
  Future<ApiResult<AppNotificationPage>> listNotifications({
    String? cursor,
    int? limit,
  }) async {
    return ApiResult<AppNotificationPage>.success(
      data: const AppNotificationPage(items: <AppNotification>[_unread]),
      status: 200,
      idempotencyStore: SubmissionKeyStore.empty,
    );
  }

  @override
  Future<ApiResult<AppNotification>> markRead({
    required String notificationId,
    required IdempotencyRequestContext idempotency,
    SubmissionKeyStore idempotencyStore = SubmissionKeyStore.empty,
  }) async {
    markReadIds.add(notificationId);
    markReadKeys.add(idempotency.explicitKey ?? '');
    return ApiResult<AppNotification>.success(
      data: AppNotification(
        notificationId: _unread.notificationId,
        eventType: _unread.eventType,
        scene: _unread.scene,
        targetType: _unread.targetType,
        targetId: _unread.targetId,
        title: _unread.title,
        body: _unread.body,
        status: AppNotificationStatus.read,
      ),
      status: 200,
      idempotencyStore: idempotencyStore,
    );
  }
}

final class _MutableNotificationApi implements NotificationApiPort {
  _MutableNotificationApi(this.notification);

  AppNotification notification;

  @override
  Future<ApiResult<AppNotificationPage>> listNotifications({
    String? cursor,
    int? limit,
  }) async => ApiResult<AppNotificationPage>.success(
    data: AppNotificationPage(items: <AppNotification>[notification]),
    status: 200,
    idempotencyStore: SubmissionKeyStore.empty,
  );

  @override
  Future<ApiResult<AppNotification>> markRead({
    required String notificationId,
    required IdempotencyRequestContext idempotency,
    SubmissionKeyStore idempotencyStore = SubmissionKeyStore.empty,
  }) async => ApiResult<AppNotification>.success(
    data: notification,
    status: 200,
    idempotencyStore: idempotencyStore,
  );
}

final class _ControlledNotificationApi implements NotificationApiPort {
  _ControlledNotificationApi({this.readResponse = _unread});

  final AppNotification readResponse;
  final listCalls = <Completer<ApiResult<AppNotificationPage>>>[];
  final listLimits = <int?>[];

  @override
  Future<ApiResult<AppNotificationPage>> listNotifications({
    String? cursor,
    int? limit,
  }) {
    final call = Completer<ApiResult<AppNotificationPage>>();
    listCalls.add(call);
    listLimits.add(limit);
    return call.future;
  }

  void completeList(int index, List<AppNotification> items) {
    listCalls[index].complete(
      ApiResult<AppNotificationPage>.success(
        data: AppNotificationPage(items: items),
        status: 200,
        idempotencyStore: SubmissionKeyStore.empty,
      ),
    );
  }

  @override
  Future<ApiResult<AppNotification>> markRead({
    required String notificationId,
    required IdempotencyRequestContext idempotency,
    SubmissionKeyStore idempotencyStore = SubmissionKeyStore.empty,
  }) async => ApiResult<AppNotification>.success(
    data: readResponse.copyWith(status: AppNotificationStatus.read),
    status: 200,
    idempotencyStore: idempotencyStore,
  );
}

final class _ReadReceiptNotificationApi implements NotificationApiPort {
  @override
  Future<ApiResult<AppNotificationPage>> listNotifications({
    String? cursor,
    int? limit,
  }) async => ApiResult<AppNotificationPage>.success(
    data: const AppNotificationPage(items: <AppNotification>[_unread]),
    status: 200,
    idempotencyStore: SubmissionKeyStore.empty,
  );

  @override
  Future<ApiResult<AppNotification>> markRead({
    required String notificationId,
    required IdempotencyRequestContext idempotency,
    SubmissionKeyStore idempotencyStore = SubmissionKeyStore.empty,
  }) async => ApiResult<AppNotification>.success(
    data: AppNotification.readReceipt(
      notificationId: notificationId,
      status: AppNotificationStatus.read,
    ),
    status: 200,
    idempotencyStore: idempotencyStore,
  );
}

final class _ConcurrentNotificationApi implements NotificationApiPort {
  final Map<String, Completer<ApiResult<AppNotification>>> _pending =
      <String, Completer<ApiResult<AppNotification>>>{};

  @override
  Future<ApiResult<AppNotificationPage>> listNotifications({
    String? cursor,
    int? limit,
  }) async => ApiResult<AppNotificationPage>.success(
    data: const AppNotificationPage(
      items: <AppNotification>[
        _unread,
        AppNotification(
          notificationId: 'notice-2',
          eventType: 'recording.completed',
          scene: 'recording',
          targetType: 'recording',
          targetId: 'recording-2',
          title: '第二条转写完成',
          body: '第二条录音已经可以查看。',
          status: AppNotificationStatus.unread,
        ),
      ],
    ),
    status: 200,
    idempotencyStore: SubmissionKeyStore.empty,
  );

  @override
  Future<ApiResult<AppNotification>> markRead({
    required String notificationId,
    required IdempotencyRequestContext idempotency,
    SubmissionKeyStore idempotencyStore = SubmissionKeyStore.empty,
  }) {
    final completer = Completer<ApiResult<AppNotification>>();
    _pending[notificationId] = completer;
    return completer.future;
  }

  void complete(String notificationId) {
    _pending
        .remove(notificationId)!
        .complete(
          ApiResult<AppNotification>.success(
            data: AppNotification.readReceipt(
              notificationId: notificationId,
              status: AppNotificationStatus.read,
            ),
            status: 200,
            idempotencyStore: SubmissionKeyStore.empty,
          ),
        );
  }
}

final class _RevisionReadRaceNotificationApi implements NotificationApiPort {
  _RevisionReadRaceNotificationApi(this.notification);

  AppNotification notification;
  int listCalls = 0;
  int markReadCalls = 0;
  final Map<String, Completer<ApiResult<AppNotification>>> _pending =
      <String, Completer<ApiResult<AppNotification>>>{};

  @override
  Future<ApiResult<AppNotificationPage>> listNotifications({
    String? cursor,
    int? limit,
  }) async {
    listCalls += 1;
    return ApiResult<AppNotificationPage>.success(
      data: AppNotificationPage(items: <AppNotification>[notification]),
      status: 200,
      idempotencyStore: SubmissionKeyStore.empty,
    );
  }

  @override
  Future<ApiResult<AppNotification>> markRead({
    required String notificationId,
    required IdempotencyRequestContext idempotency,
    SubmissionKeyStore idempotencyStore = SubmissionKeyStore.empty,
  }) {
    markReadCalls += 1;
    final key = idempotency.explicitKey!;
    final completer = Completer<ApiResult<AppNotification>>();
    _pending[key] = completer;
    return completer.future;
  }

  void completeRead(AppNotification value) {
    _take(value).complete(
      ApiResult<AppNotification>.success(
        data: AppNotification.readReceipt(
          notificationId: value.notificationId,
          status: AppNotificationStatus.read,
        ),
        status: 200,
        idempotencyStore: SubmissionKeyStore.empty,
      ),
    );
  }

  void failRead(AppNotification value) {
    _take(value).completeError(StateError('mark read failed'));
  }

  Completer<ApiResult<AppNotification>> _take(AppNotification value) {
    final deliveryKey = notificationDeliveryResolutionKey(value);
    return _pending.remove('idem-notification-read-$deliveryKey')!;
  }
}

class _FakeResolutionPort implements NotificationResolutionPort {
  final Set<String> handledIds = <String>{};
  final Set<String> locallyReadIds = <String>{};

  @override
  bool get isDemo => true;

  @override
  Set<String> loadHandledIds() => Set<String>.from(handledIds);

  @override
  Set<String> loadLocallyReadIds() => Set<String>.from(locallyReadIds);

  @override
  Future<bool> markHandled(String notificationId) async {
    handledIds.add(notificationId);
    return true;
  }

  @override
  Future<bool> markLocallyRead(String notificationId) async {
    locallyReadIds.add(notificationId);
    return true;
  }
}

final class _ControlledResolutionPort implements NotificationResolutionPort {
  final Set<String> handledIds = <String>{};
  final Set<String> locallyReadIds = <String>{};
  final Map<String, Completer<bool>> _pendingHandled =
      <String, Completer<bool>>{};
  final Map<String, Completer<bool>> _pendingLocalRead =
      <String, Completer<bool>>{};

  @override
  bool get isDemo => true;

  @override
  Set<String> loadHandledIds() => Set<String>.from(handledIds);

  @override
  Set<String> loadLocallyReadIds() => Set<String>.from(locallyReadIds);

  @override
  Future<bool> markHandled(String notificationId) {
    final completer = Completer<bool>();
    _pendingHandled[notificationId] = completer;
    return completer.future;
  }

  @override
  Future<bool> markLocallyRead(String notificationId) {
    final completer = Completer<bool>();
    _pendingLocalRead[notificationId] = completer;
    return completer.future;
  }

  void completeHandled(String notificationId) {
    handledIds.add(notificationId);
    _pendingHandled.remove(notificationId)!.complete(true);
  }

  void failHandled(String notificationId) {
    _pendingHandled
        .remove(notificationId)!
        .completeError(StateError('handled persistence failed'));
  }

  void completeLocalRead(String notificationId) {
    locallyReadIds.add(notificationId);
    _pendingLocalRead.remove(notificationId)!.complete(true);
  }

  void failLocalRead(String notificationId) {
    _pendingLocalRead
        .remove(notificationId)!
        .completeError(StateError('local-read persistence failed'));
  }
}

final class _CachedResolutionPort
    implements NotificationResolutionPort, NotificationPageCachePort {
  _CachedResolutionPort(this.page, {this.firstSaveGate});

  final CachedNotificationPage page;
  final Completer<void>? firstSaveGate;
  final Set<String> _handledIds = <String>{};
  final Set<String> _locallyReadIds = <String>{};
  final List<AppNotificationPage> savedPages = <AppNotificationPage>[];
  int saveCalls = 0;

  @override
  bool get isDemo => true;

  @override
  Set<String> loadHandledIds() => Set<String>.from(_handledIds);

  @override
  Set<String> loadLocallyReadIds() => Set<String>.from(_locallyReadIds);

  @override
  Future<bool> markHandled(String notificationId) async {
    _handledIds.add(notificationId);
    return true;
  }

  @override
  Future<bool> markLocallyRead(String notificationId) async {
    _locallyReadIds.add(notificationId);
    return true;
  }

  @override
  CachedNotificationPage? loadNotificationPage() => page;

  @override
  Future<void> saveNotificationPage(AppNotificationPage page) async {
    saveCalls += 1;
    savedPages.add(page);
    if (saveCalls == 1) await firstSaveGate?.future;
  }
}

final class _TaskResolutionPort extends _FakeResolutionPort
    implements TaskNotificationResolutionPort {
  final Set<String> handledTaskIds = <String>{};

  @override
  Set<String> loadHandledTaskIds() => Set<String>.from(handledTaskIds);

  @override
  Future<bool> markTaskHandled(String taskId) async {
    handledTaskIds.add(taskId);
    return true;
  }
}

final class _RetryableTaskResolutionPort extends _FakeResolutionPort
    implements TaskNotificationResolutionPort {
  bool succeeds = false;
  final Set<String> handledTaskIds = <String>{};

  @override
  Set<String> loadHandledTaskIds() => Set<String>.from(handledTaskIds);

  @override
  Future<bool> markTaskHandled(String taskId) async {
    if (!succeeds) return false;
    handledTaskIds.add(taskId);
    return true;
  }
}

final class _FailingNotificationApi implements NotificationApiPort {
  const _FailingNotificationApi();

  @override
  Future<ApiResult<AppNotificationPage>> listNotifications({
    String? cursor,
    int? limit,
  }) async => ApiResult<AppNotificationPage>.failure(
    error: const AppFailure(
      code: 'NOTIFICATION_LOAD_FAILED',
      category: AppFailureCategory.network,
      message: 'offline',
      userMessageKey: 'notification.offline',
    ),
    idempotencyStore: SubmissionKeyStore.empty,
  );

  @override
  Future<ApiResult<AppNotification>> markRead({
    required String notificationId,
    required IdempotencyRequestContext idempotency,
    SubmissionKeyStore idempotencyStore = SubmissionKeyStore.empty,
  }) async => ApiResult<AppNotification>.failure(
    error: const AppFailure(
      code: 'NOTIFICATION_LOAD_FAILED',
      category: AppFailureCategory.network,
      message: 'offline',
      userMessageKey: 'notification.offline',
    ),
    idempotencyStore: idempotencyStore,
  );
}

final class _ThrowingNotificationApi implements NotificationApiPort {
  const _ThrowingNotificationApi();

  @override
  Future<ApiResult<AppNotificationPage>> listNotifications({
    String? cursor,
    int? limit,
  }) => throw StateError('transport failed before an API result existed');

  @override
  Future<ApiResult<AppNotification>> markRead({
    required String notificationId,
    required IdempotencyRequestContext idempotency,
    SubmissionKeyStore idempotencyStore = SubmissionKeyStore.empty,
  }) => throw UnsupportedError('No read mutation in load coverage');
}

const _unread = AppNotification(
  notificationId: 'notice-1',
  eventType: 'recording.completed',
  scene: 'recording',
  targetType: 'recording',
  targetId: 'recording-1',
  title: '转写完成',
  body: '客户访谈已经可以查看。',
  status: AppNotificationStatus.unread,
);

final _olderUnread = AppNotification(
  notificationId: 'notice-race-1',
  eventType: 'recording.completed',
  scene: 'recording',
  targetType: 'recording',
  targetId: 'recording-race-1',
  title: '转写完成',
  body: '旧列表响应中的未读状态。',
  status: AppNotificationStatus.unread,
  updatedAt: DateTime.utc(2026, 9, 2, 8),
);

final _newerRead = AppNotification(
  notificationId: 'notice-race-1',
  eventType: 'recording.completed',
  scene: 'recording',
  targetType: 'recording',
  targetId: 'recording-race-1',
  title: '转写完成',
  body: '已读响应已经更新这条通知。',
  status: AppNotificationStatus.read,
  updatedAt: DateTime.utc(2026, 9, 2, 9),
);

String _identifierOfLength(String prefix, int length) =>
    '$prefix${List<String>.filled(length - prefix.length, 'a').join()}';
