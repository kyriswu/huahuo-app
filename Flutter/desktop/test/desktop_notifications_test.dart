import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:huahuo_api/huahuo_api.dart';
import 'package:huahuo_desktop/features/notifications/application/desktop_notifications_controller.dart';
import 'package:huahuo_desktop/features/notifications/data/desktop_notifications_adapters.dart';
import 'package:huahuo_desktop/features/notifications/domain/desktop_notifications_port.dart';
import 'package:huahuo_desktop/shared/services/desktop_service_result.dart';

void main() {
  test(
    'remote desktop notification port preserves list and read contracts',
    () async {
      final transport = _QueueTransport(<ApiTransportResponse>[
        _success(<String, Object?>{
          'items': <Object?>[
            <String, Object?>{
              'notificationId': 'notice-1',
              'status': 'unread',
              'payload': <String, Object?>{
                'eventType': 'chat.completed',
                'scene': 'chat',
                'targetType': 'thread',
                'targetId': 'thread-1',
                'title': '创作已完成',
                'body': '查看聊天结果',
                'taskStatus': 'succeeded',
                'taskId': 'agent-run-1',
              },
            },
          ],
          'nextCursor': 'cursor-2',
        }),
        _success(<String, Object?>{
          'notificationId': 'notice-1',
          'status': 'read',
        }),
      ]);
      final port = RemoteDesktopNotificationsPort(_client(transport));

      final page = await port.listNotifications(cursor: 'cursor-1', limit: 20);
      final read = await port.markRead(
        notificationId: 'notice-1',
        idempotencyKey: 'desktop-notification-read-notice-1',
      );

      expect(page.isSuccess, isTrue);
      expect(page.data?.items.single.targetId, 'thread-1');
      expect(
        page.data?.items.single.taskStatus,
        DesktopNotificationTaskStatus.succeeded,
      );
      expect(page.data?.items.single.taskId, 'agent-run-1');
      expect(page.data?.nextCursor, 'cursor-2');
      expect(read.data?.status, DesktopNotificationStatus.read);
      expect(transport.requests.map((request) => request.url.path), <String>[
        '/api/v1/notifications',
        '/api/v1/notifications/notice-1/read',
      ]);
      expect(
        transport.requests.first.url.queryParameters['cursor'],
        'cursor-1',
      );
      expect(
        transport.requests.last.headers['X-Idempotency-Key'],
        'desktop-notification-read-notice-1',
      );
    },
  );

  test(
    'desktop notification controller pages and clears account state',
    () async {
      final port = _FakeNotificationsPort(<DesktopNotificationPage>[
        DesktopNotificationPage(
          items: <DesktopNotification>[_notice('notice-1')],
          nextCursor: 'cursor-2',
        ),
        DesktopNotificationPage(
          items: <DesktopNotification>[_notice('notice-2', read: true)],
        ),
      ]);
      final controller = DesktopNotificationsController(port);
      addTearDown(controller.dispose);

      controller.bindAccount('user-1');
      await controller.load();
      expect(controller.state.items, hasLength(1));
      expect(controller.state.nextCursor, 'cursor-2');

      expect(await controller.markRead(_notice('notice-1')), isTrue);
      expect(
        controller.state.items.single.status,
        DesktopNotificationStatus.read,
      );
      await controller.load(refresh: false);
      expect(
        controller.state.items.map((item) => item.notificationId),
        <String>['notice-1', 'notice-2'],
      );

      controller.clearAccount();
      expect(controller.state.items, isEmpty);
      expect(controller.state.nextCursor, isNull);
    },
  );

  test('desktop notification controller drops stale account results', () async {
    final port = _DeferredNotificationsPort();
    final controller = DesktopNotificationsController(port);
    addTearDown(controller.dispose);

    controller.bindAccount('user-1');
    final loading = controller.load();
    controller.bindAccount('user-2');
    port.complete(
      DesktopNotificationPage(
        items: <DesktopNotification>[_notice('notice-from-user-1')],
      ),
    );
    await loading;

    expect(controller.state.items, isEmpty);
    expect(controller.state.phase, DesktopNotificationsPhase.idle);
  });
}

DesktopNotification _notice(String id, {bool read = false}) =>
    DesktopNotification(
      notificationId: id,
      eventType: 'chat.completed',
      scene: 'chat',
      targetType: 'thread',
      targetId: 'thread-1',
      title: '创作已完成',
      body: '查看聊天结果',
      status: read
          ? DesktopNotificationStatus.read
          : DesktopNotificationStatus.unread,
    );

ApiClient _client(ApiTransport transport) => ApiClientFactory.create(
  baseUrl: Uri.parse('https://api.example.test'),
  runtime: const ApiClientRuntime(
    clientVersion: 'test',
    deviceId: 'desktop-test',
    platform: 'macos',
    locale: 'zh-CN',
    timeZone: 'Asia/Shanghai',
  ),
  transport: transport,
  getAccessToken: () => 'access-token',
);

ApiTransportResponse _success(Object data) => ApiTransportResponse(
  status: 200,
  body: <String, Object?>{'success': true, 'data': data},
);

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

final class _FakeNotificationsPort implements DesktopNotificationsPort {
  _FakeNotificationsPort(this.pages);

  final List<DesktopNotificationPage> pages;

  @override
  Future<DesktopServiceResult<DesktopNotificationPage>> listNotifications({
    String? cursor,
    int? limit,
  }) async =>
      DesktopServiceResult<DesktopNotificationPage>.success(pages.removeAt(0));

  @override
  Future<DesktopServiceResult<DesktopNotification>> markRead({
    required String notificationId,
    required String idempotencyKey,
  }) async => DesktopServiceResult<DesktopNotification>.success(
    _notice(notificationId, read: true),
  );
}

final class _DeferredNotificationsPort implements DesktopNotificationsPort {
  final Completer<DesktopServiceResult<DesktopNotificationPage>> _pending =
      Completer<DesktopServiceResult<DesktopNotificationPage>>();

  @override
  Future<DesktopServiceResult<DesktopNotificationPage>> listNotifications({
    String? cursor,
    int? limit,
  }) => _pending.future;

  void complete(DesktopNotificationPage page) {
    _pending.complete(
      DesktopServiceResult<DesktopNotificationPage>.success(page),
    );
  }

  @override
  Future<DesktopServiceResult<DesktopNotification>> markRead({
    required String notificationId,
    required String idempotencyKey,
  }) async => DesktopServiceResult<DesktopNotification>.success(
    _notice(notificationId, read: true),
  );
}
