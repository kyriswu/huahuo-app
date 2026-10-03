import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:huahuo_api/huahuo_api.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/database/app_preferences_dao.dart';
import 'package:huahuoai_app/features/ui_v3/application/daily_topic_controller.dart';

void main() {
  test(
    'daily topics use an account and Workspace-scoped fresh cache',
    () async {
      final database = AppDatabase();
      final port = _DailyTopicPort();
      var workspaceId = 'workspace_1';
      final first = DailyTopicController(
        port: port,
        preferences: AppPreferencesDao(database),
        userScope: 'user_1',
        workspaceId: () => workspaceId,
        workspaceReady: () => true,
        cacheTtl: () => const Duration(minutes: 5),
        now: () => DateTime.utc(2026, 8, 14, 12),
      );

      await first.initialize();

      expect(first.state.recommendation?.recommendationId, 'daily_1');
      expect(port.listCalls, 1);

      final cached = DailyTopicController(
        port: port,
        preferences: AppPreferencesDao(database),
        userScope: 'user_1',
        workspaceId: () => workspaceId,
        workspaceReady: () => true,
        cacheTtl: () => const Duration(minutes: 5),
        now: () => DateTime.utc(2026, 8, 14, 12, 1),
      );
      await cached.initialize();

      expect(cached.state.fromCache, isTrue);
      expect(port.listCalls, 1);
      final cachedSources =
          cached.state.recommendation!.topics.single.sourceRefs;
      expect(cachedSources.first, isA<DailyTopicHotspotSourceRef>());
      expect(
        (cachedSources.first as DailyTopicHotspotSourceRef).sourceUrl,
        'https://example.test/hotspot/1',
      );
      expect(cachedSources.last, isA<DailyTopicWorkspaceNoteSourceRef>());
      expect(
        (cachedSources.last as DailyTopicWorkspaceNoteSourceRef).noteId,
        'workspace_note_1',
      );
      final cachedTopic = cached.state.recommendation!.topics.single;
      expect(cachedTopic.primarySupply, 'method');
      expect(cachedTopic.positioningMode, 'applied');
      expect(cachedTopic.audience, '需要稳定选题的创作者');
      expect(cachedTopic.contentPromise, '你可以借这条素材讲清选题判断方法');
      expect(cachedTopic.reasonMarkdown, '这条选题要讲：素材判断比追逐数量更重要。');
      expect(
        cachedTopic.writingSketchMarkdown,
        '你可以这样写：1.摆素材 2.提问题 3.讲判断 4.给行动。',
      );

      workspaceId = 'workspace_2';
      final otherWorkspace = DailyTopicController(
        port: port,
        preferences: AppPreferencesDao(database),
        userScope: 'user_1',
        workspaceId: () => workspaceId,
        workspaceReady: () => true,
        cacheTtl: () => const Duration(minutes: 5),
        now: () => DateTime.utc(2026, 8, 14, 12, 1),
      );
      await otherWorkspace.initialize();

      expect(port.listCalls, 2);
      workspaceId = 'workspace_1';
      final otherAccount = DailyTopicController(
        port: port,
        preferences: AppPreferencesDao(database),
        userScope: 'user_2',
        workspaceId: () => workspaceId,
        workspaceReady: () => true,
        cacheTtl: () => const Duration(minutes: 5),
        now: () => DateTime.utc(2026, 8, 14, 12, 1),
      );
      await otherAccount.initialize();

      expect(port.listCalls, 3);
      first.dispose();
      cached.dispose();
      otherWorkspace.dispose();
      otherAccount.dispose();
    },
  );

  test('Workspace not ready does not query recommendations', () async {
    final port = _DailyTopicPort();
    final controller = DailyTopicController(
      port: port,
      preferences: AppPreferencesDao(AppDatabase()),
      userScope: 'user_1',
      workspaceId: () => 'workspace_1',
      workspaceReady: () => false,
      cacheTtl: () => const Duration(minutes: 5),
    );

    await controller.initialize();

    expect(controller.state.status, DailyTopicLoadStatus.workspacePending);
    expect(controller.state.errorCode, 'WORKSPACE_NOT_READY');
    expect(port.listCalls, 0);
    controller.dispose();
  });

  test('a waiting controller loads once Workspace becomes ready', () async {
    final port = _DailyTopicPort();
    var ready = false;
    final controller = DailyTopicController(
      port: port,
      preferences: AppPreferencesDao(AppDatabase()),
      userScope: 'user_1',
      workspaceId: () => 'workspace_1',
      workspaceReady: () => ready,
      cacheTtl: () => const Duration(minutes: 5),
    );

    await controller.initialize();
    expect(controller.state.status, DailyTopicLoadStatus.workspacePending);
    expect(port.listCalls, 0);

    ready = true;
    await controller.load(force: true);

    expect(controller.state.status, DailyTopicLoadStatus.ready);
    expect(controller.state.recommendation?.recommendationId, 'daily_1');
    expect(port.listCalls, 1);
    controller.dispose();
  });

  test('an unexpired cache is refreshed after the local day changes', () async {
    final database = AppDatabase();
    final port = _DailyTopicPort();
    var now = DateTime(2026, 8, 14, 23, 58);
    final first = DailyTopicController(
      port: port,
      preferences: AppPreferencesDao(database),
      userScope: 'user_1',
      workspaceId: () => 'workspace_1',
      workspaceReady: () => true,
      cacheTtl: () => const Duration(days: 1),
      now: () => now,
    );

    await first.initialize();
    first.dispose();
    now = DateTime(2026, 8, 15, 0, 1);

    final nextDay = DailyTopicController(
      port: port,
      preferences: AppPreferencesDao(database),
      userScope: 'user_1',
      workspaceId: () => 'workspace_1',
      workspaceReady: () => true,
      cacheTtl: () => const Duration(days: 1),
      now: () => now,
    );
    await nextDay.initialize();

    expect(port.listCalls, 2);
    expect(nextDay.state.fromCache, isFalse);
    nextDay.dispose();
  });

  test(
    'coalesces ordinary refreshes and latches a user refresh in flight',
    () async {
      final gate = Completer<void>();
      final port = _DailyTopicPort()..listGate = gate;
      final controller = DailyTopicController(
        port: port,
        preferences: AppPreferencesDao(AppDatabase()),
        userScope: 'user_1',
        workspaceId: () => 'workspace_1',
        workspaceReady: () => true,
        cacheTtl: () => const Duration(minutes: 5),
      );

      final initialization = controller.initialize();
      await Future<void>.delayed(Duration.zero);
      final foreground = controller.refresh(
        DailyTopicRefreshTrigger.foregroundCheck,
      );
      final userRequested = controller.refresh(
        DailyTopicRefreshTrigger.userRequested,
      );
      expect(port.listCalls, 1);

      gate.complete();
      await Future.wait(<Future<void>>[
        initialization,
        foreground,
        userRequested,
      ]);

      expect(port.listCalls, 2);
      expect(controller.state.status, DailyTopicLoadStatus.ready);
      controller.dispose();
    },
  );

  test(
    're-reads once on an ETag conflict before using a recommendation',
    () async {
      final port = _DailyTopicPort()..failFirstReadMutation = true;
      final controller = DailyTopicController(
        port: port,
        preferences: AppPreferencesDao(AppDatabase()),
        userScope: 'user_1',
        workspaceId: () => 'workspace_1',
        workspaceReady: () => true,
        cacheTtl: () => const Duration(minutes: 5),
      );

      await controller.initialize();
      final opened = await controller.open('daily_1');
      final used = await controller.use(
        recommendationId: 'daily_1',
        topicId: 'topic_1',
      );

      expect(opened?.readAt, isNotNull);
      expect(port.markReadCalls, 2);
      expect(port.getCalls, 2);
      expect(used?.threadId, 'thread_1');
      controller.dispose();
    },
  );

  test(
    'dismiss invalidates the scoped cache and reloads the ready list',
    () async {
      final port = _DailyTopicPort();
      final controller = DailyTopicController(
        port: port,
        preferences: AppPreferencesDao(AppDatabase()),
        userScope: 'user_1',
        workspaceId: () => 'workspace_1',
        workspaceReady: () => true,
        cacheTtl: () => const Duration(minutes: 5),
      );

      await controller.initialize();
      final recommendation = controller.state.recommendation;
      expect(recommendation, isNotNull);

      final dismissed = await controller.dismiss(recommendation!);

      expect(dismissed, isTrue);
      expect(port.dismissCalls, 1);
      expect(port.listCalls, 2);
      expect(controller.state.recommendation, isNull);
      controller.dispose();
    },
  );

  test(
    're-reads once on an ETag conflict before dismissing a recommendation',
    () async {
      final port = _DailyTopicPort()..failFirstDismissMutation = true;
      final controller = DailyTopicController(
        port: port,
        preferences: AppPreferencesDao(AppDatabase()),
        userScope: 'user_1',
        workspaceId: () => 'workspace_1',
        workspaceReady: () => true,
        cacheTtl: () => const Duration(minutes: 5),
      );

      await controller.initialize();
      final dismissed = await controller.dismiss(
        controller.state.recommendation!,
      );

      expect(dismissed, isTrue);
      expect(port.dismissCalls, 2);
      expect(port.getCalls, 1);
      expect(controller.state.recommendation, isNull);
      controller.dispose();
    },
  );
}

final class _DailyTopicPort implements DailyTopicPort {
  int listCalls = 0;
  int getCalls = 0;
  int markReadCalls = 0;
  int dismissCalls = 0;
  bool failFirstReadMutation = false;
  bool failFirstDismissMutation = false;
  bool dismissed = false;
  Completer<void>? listGate;

  @override
  Future<ApiResult<DailyTopicRecommendationPage>> list(
    String workspaceId,
  ) async {
    listCalls += 1;
    await listGate?.future;
    return _success(
      DailyTopicRecommendationPage(
        items: dismissed
            ? const <DailyTopicRecommendation>[]
            : <DailyTopicRecommendation>[_recommendation(workspaceId)],
      ),
    );
  }

  @override
  Future<ApiResult<DailyTopicRecommendation>> get(
    String workspaceId,
    String recommendationId,
  ) async {
    getCalls += 1;
    return _success(_recommendation(workspaceId));
  }

  @override
  Future<ApiResult<DailyTopicRecommendation>> markRead(
    String workspaceId,
    String recommendationId, {
    required String etag,
    required String idempotencyKey,
  }) async {
    markReadCalls += 1;
    if (failFirstReadMutation && markReadCalls == 1) {
      return _failure('PRECONDITION_FAILED', status: 412);
    }
    return _success(_recommendation(workspaceId, read: true));
  }

  @override
  Future<ApiResult<DailyTopicRecommendation>> dismiss(
    String workspaceId,
    String recommendationId, {
    required String etag,
    required String idempotencyKey,
  }) async {
    dismissCalls += 1;
    if (failFirstDismissMutation && dismissCalls == 1) {
      return _failure('PRECONDITION_FAILED', status: 412);
    }
    dismissed = true;
    return _success(_recommendation(workspaceId));
  }

  @override
  Future<ApiResult<DailyTopicUseResult>> use(
    String workspaceId,
    String recommendationId, {
    String? topicId,
    required String idempotencyKey,
  }) async => _success(
    DailyTopicUseResult(
      recommendationId: recommendationId,
      threadId: 'thread_1',
      topicId: topicId,
    ),
  );
}

DailyTopicRecommendation _recommendation(
  String workspaceId, {
  bool read = false,
}) => DailyTopicRecommendation.fromJson(<String, Object?>{
  'recommendationId': 'daily_1',
  'workspaceId': workspaceId,
  'businessDate': '2026-08-14',
  'recommendationKind': 'daily_topic_report',
  'status': 'ready',
  'title': '今日选题',
  'summaryMarkdown': '摘要',
  'etag': '"daily_1"',
  if (read) 'readAt': '2026-08-14T12:00:00Z',
  'topics': <Object?>[
    <String, Object?>{
      'topicId': 'topic_1',
      'title': '内容方向',
      'briefMarkdown': '从热点形成一条具体内容方向。',
      'primarySupply': 'method',
      'positioningMode': 'applied',
      'audience': '需要稳定选题的创作者',
      'contentPromise': '你可以借这条素材讲清选题判断方法',
      'reasonMarkdown': '这条选题要讲：素材判断比追逐数量更重要。',
      'writingSketchMarkdown': '你可以这样写：1.摆素材 2.提问题 3.讲判断 4.给行动。',
      'sourceRefs': <Object?>[
        <String, Object?>{
          'kind': 'daily_hotspot',
          'hotspotId': 'hotspot_1',
          'sourceUrl': 'https://example.test/hotspot/1',
        },
        <String, Object?>{
          'kind': 'workspace_note',
          'noteId': 'workspace_note_1',
          'label': '来源：工作区笔记',
        },
      ],
    },
  ],
});

ApiResult<T> _success<T>(T data) => ApiResult<T>.success(
  data: data,
  status: 200,
  idempotencyStore: SubmissionKeyStore.empty,
);

ApiResult<T> _failure<T>(String code, {required int status}) =>
    ApiResult<T>.failure(
      error: AppFailure(
        code: code,
        category: AppFailureCategory.api,
        message: code,
        userMessageKey: 'error.dailyTopic.$code',
      ),
      status: status,
      idempotencyStore: SubmissionKeyStore.empty,
    );
