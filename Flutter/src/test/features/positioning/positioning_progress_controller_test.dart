import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:huahuo_api/huahuo_api.dart';
import 'package:huahuoai_app/core/api/scoped_read_cache.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/database/app_preferences_dao.dart';
import 'package:huahuoai_app/core/tasking/task_orchestrator.dart';
import 'package:huahuoai_app/features/positioning/application/positioning_progress_controller.dart';
import 'package:huahuoai_app/features/positioning/data/positioning_progress_repository.dart';

void main() {
  test(
    'cached coverage is stale and conditional confirmation preserves ETag',
    () async {
      final fixture = _Fixture()..seed();
      expect(fixture.repository.readCached()?.isStale, isTrue);
      final result = fixture.repository.refresh(isCurrent: () => true);
      await Future<void>.delayed(Duration.zero);
      expect(fixture.transport.requests.single.headers['If-None-Match'], 'old');
      fixture.transport.pending.single.complete(_notModified);
      final coverage = await result;
      expect(coverage?.completedPercent, 45);
      expect(coverage?.isStale, isFalse);
    },
  );

  test(
    '304 without usable cache is unavailable, never successful coverage',
    () async {
      final fixture = _Fixture();
      expect(fixture.repository.readCached(), isNull);
      final result = fixture.repository.refresh(isCurrent: () => true);
      final expectation = expectLater(result, throwsStateError);
      await Future<void>.delayed(Duration.zero);
      fixture.transport.pending.single.complete(_notModified);
      await expectation;
      expect(fixture.cached(), isNull);
    },
  );

  for (final validation in ['valid', 'last_known_good']) {
    test('200 cache roundtrip and 304 retain $validation semantics', () async {
      final fixture = _Fixture();
      final result = fixture.repository.refresh(isCurrent: () => true);
      await Future<void>.delayed(Duration.zero);
      final payload = {..._payload, 'validationStatus': validation};
      fixture.transport.pending.single.complete(_success(payload));
      expect((await result)?.isStale, validation == 'last_known_good');
      expect(fixture.cached()?.payload, payload);
      expect(fixture.cached()?.etag, 'new');
      final restored = fixture.newRepository();
      expect(restored.readCached()?.isStale, isTrue);
      final confirmed = restored.refresh(isCurrent: () => true);
      await Future<void>.delayed(Duration.zero);
      expect(fixture.transport.requests.last.headers['If-None-Match'], 'new');
      fixture.transport.pending.last.complete(_notModified);
      expect((await confirmed)?.isStale, validation == 'last_known_good');
    });
  }

  testWidgets('failure preserves coverage and marks it stale', (tester) async {
    final fixture = _Fixture()..seed();
    final tasks = TaskOrchestrator();
    final controller = fixture.controller(tasks);
    addTearDown(() {
      controller.dispose();
      tasks.dispose();
    });
    controller.setActivity(visible: true, taskActive: true);
    await tester.pump();
    fixture.transport.pending.single.complete(_notModified);
    await tester.pump();
    expect(controller.coverage?.isStale, isFalse);
    controller.refresh();
    await tester.pump();
    fixture.transport.pending.last.complete(
      const ApiTransportResponse(status: 503, body: null),
    );
    await tester.pump();
    expect(controller.coverage?.completedPercent, 45);
    expect(controller.coverage?.isStale, isTrue);
    expect(fixture.cached()?.etag, 'old');
    controller.dispose();
  });

  for (final reason in [
    'hidden',
    'terminal',
    'scope',
    'dispose',
    'background',
  ]) {
    for (final fails in [false, true]) {
      testWidgets(
        '$reason discards late ${fails ? 'failure' : 'success'} and stops polling',
        (tester) async {
          final fixture = _Fixture()..seed();
          final tasks = TaskOrchestrator();
          var current = true;
          final controller = fixture.controller(
            tasks,
            isCurrent: () => current,
          );
          var notifications = 0;
          controller.addListener(() => notifications++);
          controller.setActivity(visible: true, taskActive: true);
          controller.setActivity(visible: true, taskActive: true);
          await tester.pump();
          expect(fixture.transport.requests, hasLength(1));
          switch (reason) {
            case 'hidden':
              controller.setActivity(visible: false, taskActive: true);
            case 'terminal':
              controller.setActivity(visible: true, taskActive: false);
            case 'scope':
              current = false;
            case 'dispose':
              controller.dispose();
            case 'background':
              tasks.setForeground(false);
          }
          fixture.transport.pending.single.complete(
            fails
                ? const ApiTransportResponse(status: 503, body: null)
                : _success({..._payload, 'completedPercent': 80}),
          );
          await tester.pump();
          await tester.pump(const Duration(minutes: 1));
          expect(notifications, 0);
          expect(controller.coverage?.completedPercent, 45);
          expect(fixture.cached()?.etag, 'old');
          expect(fixture.transport.requests, hasLength(1));
          controller.dispose();
          tasks.dispose();
        },
      );
    }
  }

  testWidgets('deadline rejects a late response without writing cache', (
    tester,
  ) async {
    final fixture = _Fixture()..seed();
    final tasks = TaskOrchestrator();
    final controller = fixture.controller(tasks);
    var notifications = 0;
    controller.addListener(() => notifications++);
    controller.setActivity(visible: true, taskActive: true);
    await tester.pump();
    await tester.pump(const Duration(seconds: 16));
    fixture.transport.pending.single.complete(
      _success({..._payload, 'completedPercent': 80}),
    );
    await tester.pump();
    expect(notifications, 0);
    expect(controller.coverage?.completedPercent, 45);
    expect(fixture.cached()?.etag, 'old');
    controller.dispose();
    tasks.dispose();
  });

  testWidgets('resume ignores prior generation and accepts current read', (
    tester,
  ) async {
    final fixture = _Fixture()..seed();
    final tasks = TaskOrchestrator();
    final controller = fixture.controller(tasks);
    controller.setActivity(visible: true, taskActive: true);
    await tester.pump();
    controller.setActivity(visible: false, taskActive: true);
    fixture.transport.pending.single.complete(
      _success({..._payload, 'completedPercent': 80}),
    );
    await tester.pump();
    expect(fixture.cached()?.etag, 'old');
    controller.setActivity(visible: true, taskActive: true);
    await tester.pump();
    fixture.transport.pending.last.complete(
      _success({..._payload, 'completedPercent': 60}),
    );
    await tester.pump();
    expect(controller.coverage?.completedPercent, 60);
    expect(fixture.cached()?.payload['completedPercent'], 60);
    controller.dispose();
    tasks.dispose();
  });
}

final class _Fixture {
  _Fixture() {
    cache = ScopedReadCache(
      dao: AppPreferencesDao(AppDatabase()),
      userScope: 'user_1',
      workspaceScope: 'workspace_1',
    );
    client = PositioningProgressClient(
      ApiClient(
        config: ApiClientConfig(
          baseUrl: Uri.parse('https://api.example.test'),
          clientVersion: 'test',
          deviceId: 'test-device',
          platform: 'test',
          locale: 'zh-CN',
          getAccessToken: () => 'token',
        ),
        transport: transport,
      ),
    );
    repository = newRepository();
  }

  final transport = _Transport();
  late final ScopedReadCache cache;
  late final PositioningProgressClient client;
  late final RemotePositioningProgressRepository repository;

  RemotePositioningProgressRepository newRepository() =>
      RemotePositioningProgressRepository(
        client: () => client,
        cache: cache,
        workspaceId: 'workspace_1',
      );

  void seed() => cache.write(
    'workspacePositioningProgress',
    'workspace_1',
    etag: 'old',
    payload: _payload,
  );
  ScopedReadCacheEntry? cached() =>
      cache.read('workspacePositioningProgress', 'workspace_1');

  PositioningProgressController controller(
    TaskOrchestrator tasks, {
    bool Function()? isCurrent,
  }) => PositioningProgressController(
    repository: repository,
    orchestrator: tasks,
    userScope: 'user_1',
    workspaceId: 'workspace_1',
    isCurrentScope: isCurrent ?? () => true,
  );
}

final class _Transport implements ApiTransport {
  final requests = <ApiTransportRequest>[];
  final pending = <Completer<ApiTransportResponse>>[];

  @override
  Future<ApiTransportResponse> send(ApiTransportRequest request) {
    requests.add(request);
    final result = Completer<ApiTransportResponse>();
    pending.add(result);
    return result.future;
  }
}

const _notModified = ApiTransportResponse(status: 304, body: null);
ApiTransportResponse _success(Map<String, Object?> payload) =>
    ApiTransportResponse(
      status: 200,
      headers: const {'ETag': 'new'},
      body: {'success': true, 'data': payload},
    );

const _payload = <String, Object?>{
  'schemaVersion': 'huahuo.positioning-progress.v1',
  'source': 'workspace_file',
  'available': true,
  'projectionVersion': 4,
  'status': 'forming',
  'validationStatus': 'valid',
  'completedPercent': 45,
  'coldStartPercent': 100,
  'coldStartCompleted': true,
  'modules': [
    {
      'id': 'credible_self',
      'label': '人生体验',
      'weight': 10,
      'score': 5,
      'state': 'forming',
      'summary': '',
    },
  ],
  'nextFocus': <Object?>[],
  'updatedFiles': <Object?>[],
  'lastUpdated': null,
};
