import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/features/notifications/application/notification_center_state_machine.dart';
import 'package:huahuoai_app/features/notifications/application/pending_message_projection.dart';
import 'package:huahuoai_app/features/recordings/application/recording_upload_controller.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_notifications_page.dart';

import '../../support/figma_golden_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(loadFigmaGoldenFonts);

  testWidgets('shows counts, lifecycle labels, and basic read controls', (
    tester,
  ) async {
    _setPhoneViewport(tester);
    var closeCalls = 0;
    var markAllCalls = 0;
    var markReadCalls = 0;
    PendingMessage? opened;
    await tester.pumpWidget(
      MaterialApp(
        theme: figmaGoldenTheme(),
        home: _SurfaceHarness(
          items: _messages,
          onClose: () => closeCalls += 1,
          onMarkAllRead: () => markAllCalls += 1,
          onMarkRead: (_) => markReadCalls += 1,
          onOpen: (item) => opened = item,
        ),
      ),
    );

    expect(find.text('消息通知'), findsOneWidget);
    expect(find.text('3 条未读 · 2 条正在进行中'), findsOneWidget);
    expect(find.text('全部 4'), findsNothing);
    expect(find.text('正在进行中 2'), findsOneWidget);
    expect(find.text('已完成 2'), findsOneWidget);
    expect(find.text('进行中'), findsOneWidget);
    expect(find.text('待处理'), findsOneWidget);
    expect(find.text('生成结果'), findsNothing);
    expect(find.text('处理失败'), findsNothing);

    await tester.tap(find.text('已完成 2'));
    await tester.pump();
    expect(find.text('已完成'), findsOneWidget);
    expect(find.text('失败'), findsOneWidget);
    expect(find.byTooltip('没有可删除的已读消息'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('notification-archive-failed')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('notification-archive-succeeded')),
      findsNothing,
    );

    await tester.tap(find.byTooltip('全部已读'));
    await tester.tap(
      find.byKey(const ValueKey('notification-mark-read-failed')),
    );
    await tester.tap(
      find.byKey(const ValueKey('notification-message-succeeded')),
    );
    await tester.tap(find.byTooltip('关闭'));

    expect(markAllCalls, 1);
    expect(markReadCalls, 1);
    expect(opened?.id, 'succeeded');
    expect(closeCalls, 1);
  });

  testWidgets('segmented filters expose ongoing and finished groups', (
    tester,
  ) async {
    _setPhoneViewport(tester);
    await tester.pumpWidget(
      MaterialApp(
        theme: figmaGoldenTheme(),
        home: const _SurfaceHarness(items: _messages),
      ),
    );

    expect(find.text('全部 4'), findsNothing);
    expect(find.text('正在进行中 2'), findsOneWidget);
    expect(find.text('已完成 2'), findsOneWidget);
    expect(find.text('后台任务'), findsOneWidget);
    expect(find.text('完成定位'), findsOneWidget);
    expect(find.text('生成结果'), findsNothing);

    await tester.tap(find.text('已完成 2'));
    await tester.pump();
    expect(find.text('后台任务'), findsNothing);
    expect(find.text('生成结果'), findsOneWidget);
    expect(find.text('处理失败'), findsOneWidget);
  });

  testWidgets(
    'recording upload row shows bytes, rate, and ETA only with evidence',
    (tester) async {
      _setPhoneViewport(tester);
      await tester.pumpWidget(
        MaterialApp(
          theme: figmaGoldenTheme(),
          home: const _SurfaceHarness(
            items: <PendingMessage>[
              PendingMessage(
                id: 'recording-uploading',
                source: PendingMessageSource.recordingTranscription,
                scene: 'recording',
                title: '访谈录音',
                body: '正在上传录音文件。',
                state: PendingMessageState.processing,
                isUnread: false,
                isDemo: false,
                isOpening: false,
                isResolving: false,
                isTask: true,
                route: '/v3/feed/transcription-jobs/recording-uploading',
                recordingUploadProgress: RecordingObjectUploadProgress(
                  draftId: 'draft-uploading',
                  bytesSent: 1048576,
                  totalBytes: 4194304,
                  bytesPerSecond: 524288,
                  estimatedRemainingSeconds: 6,
                ),
              ),
              PendingMessage(
                id: 'recording-transcribing',
                source: PendingMessageSource.recordingTranscription,
                scene: 'recording',
                title: '另一段录音',
                body: '正在转写并保存到我的资产。',
                state: PendingMessageState.processing,
                isUnread: false,
                isDemo: false,
                isOpening: false,
                isResolving: false,
                isTask: true,
                route: '/v3/feed/transcription-jobs/recording-transcribing',
              ),
            ],
          ),
        ),
      );

      expect(find.text('1.0 MB / 4.0 MB\n512 KB/s · 预计剩余 6s'), findsOneWidget);
      expect(
        find.byKey(
          const ValueKey('notification-upload-progress-recording-uploading'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const ValueKey('notification-upload-progress-recording-transcribing'),
        ),
        findsNothing,
      );
    },
  );

  testWidgets('external recording timer row remains tappable', (tester) async {
    _setPhoneViewport(tester);
    PendingMessage? opened;
    const item = PendingMessage(
      id: 'external-recording-active',
      source: PendingMessageSource.recordingTranscription,
      scene: 'external_recording',
      title: '外录进行中',
      body: '正在录音 · 00:02:05，点击返回录音界面。',
      state: PendingMessageState.processing,
      isUnread: false,
      isDemo: false,
      isOpening: false,
      isResolving: false,
      isTask: true,
      route: '/v3/feed/meeting',
      targetType: 'external_recording',
      targetId: 'external-session-1',
      canMarkHandled: false,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: figmaGoldenTheme(),
        home: _SurfaceHarness(
          items: const <PendingMessage>[item],
          onOpen: (message) => opened = message,
        ),
      ),
    );

    expect(find.text('正在录音 · 00:02:05，点击返回录音界面。'), findsOneWidget);
    expect(
      find.byKey(
        const ValueKey('notification-archive-external-recording-active'),
      ),
      findsNothing,
    );
    await tester.tap(
      find.byKey(
        const ValueKey('notification-message-external-recording-active'),
      ),
    );
    expect(opened?.route, '/v3/feed/meeting');
  });

  testWidgets('only policy-approved rows expose clear controls', (
    tester,
  ) async {
    _setPhoneViewport(tester);
    final archivedIds = <String>[];
    final items = <PendingMessage>[
      for (final item in _messages)
        item.id == 'failed' || item.id == 'succeeded'
            ? item.copyWith(isUnread: false)
            : item,
    ];
    await tester.pumpWidget(
      MaterialApp(
        theme: figmaGoldenTheme(),
        home: _SurfaceHarness(
          items: items,
          onArchive: (item) {
            archivedIds.add(item.id);
            return true;
          },
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey('notification-dismiss-processing')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('notification-mark-read-processing')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('notification-archive-processing')),
      findsNothing,
    );
    await tester.tap(find.text('已完成 2'));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('notification-archive-failed')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('notification-archive-failed')));
    await tester.pumpAndSettle();
    expect(archivedIds, <String>['failed']);
    expect(find.text('处理失败'), findsNothing);

    final succeededMessage = _messages.singleWhere(
      (item) => item.id == 'succeeded',
    );
    final succeededIdentity = pendingMessagePresentationIdentity(
      succeededMessage,
    );
    final succeeded = find.byKey(
      ValueKey('notification-dismiss-$succeededIdentity'),
    );
    expect(succeeded, findsOneWidget);
    await tester.drag(succeeded, const Offset(-360, 0));
    await tester.pumpAndSettle();
    expect(archivedIds, <String>['failed', 'succeeded']);
  });

  testWidgets('delete-read is separate and only enables for read history', (
    tester,
  ) async {
    _setPhoneViewport(tester);
    var deleteCalls = 0;
    const items = <PendingMessage>[
      PendingMessage(
        id: 'read-history',
        source: PendingMessageSource.remote,
        scene: 'notification',
        title: '已读历史',
        body: '可以批量删除。',
        state: PendingMessageState.informational,
        isUnread: false,
        isDemo: false,
        isOpening: false,
        isResolving: false,
        remoteNotificationId: 'read-history',
        remoteDeliveryResolutionKey: 'delivery:read-history',
      ),
      PendingMessage(
        id: 'unread-history',
        source: PendingMessageSource.remote,
        scene: 'notification',
        title: '未读消息',
        body: '不能被删除已读操作处理。',
        state: PendingMessageState.informational,
        isUnread: true,
        isDemo: false,
        isOpening: false,
        isResolving: false,
        remoteNotificationId: 'unread-history',
        remoteDeliveryResolutionKey: 'delivery:unread-history',
      ),
      PendingMessage(
        id: 'active-task',
        source: PendingMessageSource.agentTask,
        scene: 'chat',
        title: '进行中',
        body: '不能删除。',
        state: PendingMessageState.processing,
        isUnread: false,
        isDemo: false,
        isOpening: false,
        isResolving: false,
        route: '/v3/feed/chat?threadId=active-thread',
        taskId: 'active-task',
        isTask: true,
      ),
    ];
    await tester.pumpWidget(
      MaterialApp(
        theme: figmaGoldenTheme(),
        home: _SurfaceHarness(
          items: items,
          onDeleteRead: () => deleteCalls += 1,
        ),
      ),
    );

    expect(find.byTooltip('删除已读'), findsOneWidget);
    await tester.tap(find.byTooltip('删除已读'));
    expect(deleteCalls, 1);
    expect(find.text('进行中'), findsWidgets);
    expect(find.text('未读消息'), findsNothing);

    await tester.tap(find.text('已完成 2'));
    await tester.pump();
    expect(find.text('未读消息'), findsOneWidget);

    await tester.pumpWidget(
      MaterialApp(
        theme: figmaGoldenTheme(),
        home: _SurfaceHarness(
          items: items,
          deleteReadBusy: true,
          onDeleteRead: () => deleteCalls += 1,
        ),
      ),
    );
    expect(
      find.byKey(const ValueKey('notifications-delete-read')),
      findsNothing,
    );
    await tester.tap(
      find.byKey(const ValueKey('notification-message-unread-history')),
    );
    expect(deleteCalls, 1);
  });

  testWidgets('reused remote ids keep delivery-revision row identity', (
    tester,
  ) async {
    _setPhoneViewport(tester);
    await tester.pumpWidget(
      MaterialApp(
        theme: figmaGoldenTheme(),
        home: const _SurfaceHarness(
          initialFilter: NotificationCenterFilter.finished,
          items: <PendingMessage>[
            PendingMessage(
              id: 'reused-notification',
              source: PendingMessageSource.remote,
              scene: 'notification',
              title: '第一次投递',
              body: '旧修订',
              state: PendingMessageState.informational,
              isUnread: false,
              isDemo: false,
              isOpening: false,
              isResolving: false,
              remoteNotificationId: 'reused-notification',
              remoteDeliveryResolutionKey: 'delivery-revision-a',
            ),
            PendingMessage(
              id: 'reused-notification',
              source: PendingMessageSource.remote,
              scene: 'notification',
              title: '第二次投递',
              body: '新修订',
              state: PendingMessageState.informational,
              isUnread: false,
              isDemo: false,
              isOpening: false,
              isResolving: false,
              remoteNotificationId: 'reused-notification',
              remoteDeliveryResolutionKey: 'delivery-revision-b',
            ),
          ],
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey('notification-dismiss-delivery-revision-a')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('notification-dismiss-delivery-revision-b')),
      findsOneWidget,
    );
  });

  testWidgets('empty filters have deterministic copy', (tester) async {
    _setPhoneViewport(tester);
    await tester.pumpWidget(
      MaterialApp(
        theme: figmaGoldenTheme(),
        home: const _SurfaceHarness(items: <PendingMessage>[]),
      ),
    );

    expect(find.text('暂无正在进行中的消息'), findsOneWidget);
    expect(find.byTooltip('没有未读消息'), findsOneWidget);
    expect(find.text('全部 0'), findsNothing);
    await tester.tap(find.text('已完成 0'));
    await tester.pump();
    expect(find.text('暂无已完成的消息'), findsOneWidget);
  });

  testWidgets('bulk-read busy state is non-interactive', (tester) async {
    _setPhoneViewport(tester);
    var calls = 0;
    var openCalls = 0;
    var markReadCalls = 0;
    var archiveCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: figmaGoldenTheme(),
        home: _SurfaceHarness(
          items: _messages,
          initialFilter: NotificationCenterFilter.finished,
          markAllReadBusy: true,
          onMarkAllRead: () => calls += 1,
          onOpen: (_) => openCalls += 1,
          onMarkRead: (_) => markReadCalls += 1,
          onArchive: (_) {
            archiveCalls += 1;
            return true;
          },
        ),
      ),
    );

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(
      find.byKey(const ValueKey('notifications-mark-all-read')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('notification-dismiss-failed')),
      findsNothing,
    );
    await tester.tap(
      find.byKey(const ValueKey('notification-message-succeeded')),
    );
    await tester.tap(
      find.byKey(const ValueKey('notification-mark-read-failed')),
    );
    expect(calls, 0);
    expect(openCalls, 0);
    expect(markReadCalls, 0);
    expect(archiveCalls, 0);
  });

  testWidgets('route-less history has no false open affordance', (
    tester,
  ) async {
    _setPhoneViewport(tester);
    var openCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: figmaGoldenTheme(),
        home: _SurfaceHarness(
          initialFilter: NotificationCenterFilter.finished,
          items: const <PendingMessage>[
            PendingMessage(
              id: 'route-less',
              source: PendingMessageSource.remote,
              scene: 'notification',
              title: '系统消息',
              body: '这条历史没有安全目标。',
              state: PendingMessageState.informational,
              isUnread: false,
              isDemo: false,
              isOpening: false,
              isResolving: false,
              remoteNotificationId: 'route-less',
              remoteDeliveryResolutionKey: 'delivery:route-less',
            ),
          ],
          onOpen: (_) => openCalls += 1,
        ),
      ),
    );

    final row = tester.widget<InkWell>(
      find.byKey(const ValueKey('notification-message-route-less')),
    );
    expect(row.onTap, isNull);
    expect(
      find.byKey(const ValueKey('notification-mark-read-route-less')),
      findsNothing,
    );
    expect(openCalls, 0);
  });

  testWidgets('keeps cached rows visible with a refresh error', (tester) async {
    _setPhoneViewport(tester);
    var retryCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: figmaGoldenTheme(),
        home: _SurfaceHarness(
          items: _messages,
          initialFilter: NotificationCenterFilter.finished,
          errorCode: 'NETWORK_UNAVAILABLE',
          onRetry: () => retryCalls += 1,
        ),
      ),
    );

    expect(find.text('生成结果'), findsOneWidget);
    expect(find.text('网络不可用，请检查连接后重试'), findsOneWidget);
    await tester.tap(find.text('重试'));
    expect(retryCalls, 1);
  });

  testWidgets('landscape viewport bounds the notification sheet', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(568, 320)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: figmaGoldenTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.3)),
          child: child!,
        ),
        home: const _SurfaceHarness(items: _messages),
      ),
    );

    final sheet = find.byKey(const ValueKey('notifications-sheet'));
    expect(sheet, findsOneWidget);
    final rect = tester.getRect(sheet);
    expect(rect.top, greaterThanOrEqualTo(0));
    expect(rect.bottom, lessThanOrEqualTo(320));
    expect(find.byTooltip('关闭').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

class _SurfaceHarness extends StatefulWidget {
  const _SurfaceHarness({
    required this.items,
    this.initialFilter = NotificationCenterFilter.ongoing,
    this.markAllReadBusy = false,
    this.deleteReadBusy = false,
    this.errorCode,
    this.onClose,
    this.onMarkAllRead,
    this.onDeleteRead,
    this.onMarkRead,
    this.onOpen,
    this.onArchive,
    this.onRetry,
  });

  final List<PendingMessage> items;
  final NotificationCenterFilter initialFilter;
  final bool markAllReadBusy;
  final bool deleteReadBusy;
  final String? errorCode;
  final VoidCallback? onClose;
  final VoidCallback? onMarkAllRead;
  final VoidCallback? onDeleteRead;
  final ValueChanged<PendingMessage>? onMarkRead;
  final ValueChanged<PendingMessage>? onOpen;
  final bool Function(PendingMessage)? onArchive;
  final VoidCallback? onRetry;

  @override
  State<_SurfaceHarness> createState() => _SurfaceHarnessState();
}

class _SurfaceHarnessState extends State<_SurfaceHarness> {
  static const _policies = NotificationCenterPolicyRegistry();
  late List<PendingMessage> _items;
  late NotificationCenterFilter _filter;

  @override
  void initState() {
    super.initState();
    _items = List<PendingMessage>.of(widget.items);
    _filter = widget.initialFilter;
  }

  @override
  Widget build(BuildContext context) {
    return V3NotificationsSurface(
      items: _items,
      visibleItems: _policies.filter(_items, _filter),
      filter: _filter,
      policies: _policies,
      unreadCount: _policies.badgeCount(_items),
      isLoading: false,
      errorCode: widget.errorCode,
      markAllReadBusy: widget.markAllReadBusy,
      deleteReadBusy: widget.deleteReadBusy,
      readDeleteCount: _policies.readDeletableCount(_items),
      interactionsDisabled: widget.markAllReadBusy || widget.deleteReadBusy,
      operationFor: (_) => NotificationCenterOperation.idle,
      onClose: widget.onClose ?? () {},
      onFilterChanged: (value) => setState(() => _filter = value),
      onMarkAllRead: widget.onMarkAllRead,
      onDeleteRead: widget.onDeleteRead,
      onRetry: widget.onRetry ?? () {},
      onRefresh: () async {},
      onItemTap: widget.onOpen ?? (_) {},
      onMarkRead: widget.onMarkRead ?? (_) {},
      onArchive: (item) async {
        final success = widget.onArchive?.call(item) ?? true;
        if (success) setState(() => _items.remove(item));
        return success;
      },
    );
  }
}

void _setPhoneViewport(WidgetTester tester) {
  tester.view
    ..physicalSize = const Size(402, 874)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

const _messages = <PendingMessage>[
  PendingMessage(
    id: 'processing',
    source: PendingMessageSource.agentTask,
    scene: 'work_ai',
    title: '后台任务',
    body: '正在生成内容',
    state: PendingMessageState.processing,
    isUnread: false,
    isDemo: false,
    isOpening: false,
    isResolving: false,
    route: '/v3/workbench/tasks/task-1',
    taskId: 'task-1',
    isTask: true,
  ),
  PendingMessage(
    id: 'action-required',
    source: PendingMessageSource.onboarding,
    scene: 'onboarding',
    title: '完成定位',
    body: '继续填写基础定位',
    state: PendingMessageState.actionRequired,
    isUnread: true,
    isDemo: false,
    isOpening: false,
    isResolving: false,
    route: '/onboarding?resume=1',
    canMarkHandled: false,
  ),
  PendingMessage(
    id: 'succeeded',
    source: PendingMessageSource.agentTask,
    scene: 'feed_ai',
    title: '生成结果',
    body: '结果已经写入资产',
    state: PendingMessageState.succeeded,
    isUnread: true,
    isDemo: false,
    isOpening: false,
    isResolving: false,
    route: '/v3/feed/items/note-1',
    taskId: 'task-2',
    isTask: true,
  ),
  PendingMessage(
    id: 'failed',
    source: PendingMessageSource.recordingTranscription,
    scene: 'recording',
    title: '处理失败',
    body: '可打开详情后重试',
    state: PendingMessageState.failed,
    isUnread: true,
    isDemo: false,
    isOpening: false,
    isResolving: false,
    route: '/v3/feed/transcription-done/recording-1',
    taskId: 'task-3',
    isTask: true,
  ),
];
