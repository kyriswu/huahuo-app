import 'dart:async';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:huahuo_api/huahuo_api.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/database/app_preferences_dao.dart';
import 'package:huahuoai_app/core/performance/runtime_activity_metrics.dart';
import 'package:huahuoai_app/core/tasking/task_orchestrator.dart';
import 'package:huahuoai_app/features/ui_v3/application/feed_aggregation_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_library_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_note_port.dart';
import 'package:huahuoai_app/features/ui_v3/application/profile_hub_controller.dart';
import 'package:huahuoai_app/features/ui_v3/data/feed_aggregation_repository.dart';
import 'package:huahuoai_app/features/ui_v3/domain/feed_item_models.dart';
import 'package:huahuoai_app/features/ui_v3/domain/ui_v3_models.dart';

void main() {
  test(
    'selects four normal notes plus a separate hotspot and writes result',
    () async {
      final notes = [for (var i = 0; i < 5; i++) _normal(i), _hotspot()];
      final library = _libraryWithDepositedNormals(notes);
      final controller = FeedAggregationController(
        library: library,
        profileHub: ProfileHubController(referenceDay: DateTime(2026, 7, 13)),
        repository: const FeedAggregationMockRepository(delay: Duration.zero),
      );

      expect(controller.startSelection(), isTrue);
      expect(controller.selectedNoteIds, hasLength(4));
      expect(controller.selectedNoteIds, isNot(contains(_hotspot().id)));
      expect(controller.hotspotNoteId, _hotspot().id);

      final removed = controller.selectedNoteIds.first;
      controller.toggleNormalNote(removed);
      expect(controller.canConfirm, isFalse);
      final replacement = notes
          .where((note) => !note.isHotspot)
          .firstWhere((note) => !controller.selectedNoteIds.contains(note.id));
      controller.toggleNormalNote(replacement.id);
      expect(controller.canConfirm, isTrue);

      final generated = await controller.confirm();
      expect(generated, isNotNull);
      expect(generated!.rawBody, contains('# 结合热点'));
      expect(generated.rawBody, contains('# 排列组合'));
      expect(generated.rawBody, contains('# 大师升级'));
      expect(generated.linkedMaterials, hasLength(5));
      expect(library.noteForId(generated.id)?.id, generated.id);
      expect(controller.generatedNote?.id, generated.id);
      final request = controller.agentRequestFor(AggregationAgentKind.persona);
      expect(request?.noteIds, hasLength(4));
      expect(request?.hotspotId, _hotspot().id);
    },
  );

  test('fewer than four deposited assets cannot aggregate', () {
    final controller = FeedAggregationController(
      library: _libraryWithDepositedNormals([
        _normal(0),
        _normal(1),
        _normal(2),
        _hotspot(),
      ]),
      profileHub: ProfileHubController(referenceDay: DateTime(2026, 7, 13)),
      repository: const FeedAggregationMockRepository(delay: Duration.zero),
    );
    expect(controller.startSelection(), isFalse);
    expect(controller.errorCode, 'AGGREGATION_NOT_ENOUGH_DEPOSITED_ASSETS');
  });

  test('selection excludes previous aggregation outputs', () {
    final notes = <V3FeedItem>[
      for (var index = 0; index < 4; index++) _normal(index),
      V3FeedItem(
        id: 'aggregation-old-result',
        title: '历史聚合',
        source: V3MaterialSource.note,
        createdAt: DateTime(2026, 7, 12),
        rawBody: '旧内容',
      ),
      _hotspot(),
    ];
    final controller = FeedAggregationController(
      library: _libraryWithDepositedNormals(notes),
      profileHub: ProfileHubController(referenceDay: DateTime(2026, 7, 13)),
      repository: const FeedAggregationMockRepository(delay: Duration.zero),
    );
    addTearDown(controller.dispose);

    expect(controller.startSelection(), isTrue);
    expect(controller.selectedNoteIds, hasLength(4));
    expect(
      controller.selectedNoteIds,
      isNot(contains('aggregation-old-result')),
    );
  });

  test('owned notes auto-deposit while subscribed originals are rejected', () {
    final notes = [
      for (var i = 0; i < 6; i++) _normal(i),
      _subscription(),
      _hotspot(),
    ];
    final library = KnowledgeLibraryController(initialNotes: notes);
    expect(library.isDeposited('normal-5'), isTrue);
    expect(library.isSubscribed('subscription-original'), isTrue);
    expect(library.isDeposited('subscription-original'), isFalse);
    final controller = FeedAggregationController(
      library: library,
      profileHub: ProfileHubController(referenceDay: DateTime(2026, 7, 13)),
      repository: const FeedAggregationMockRepository(delay: Duration.zero),
    );

    expect(controller.startSelection(), isTrue);
    final before = controller.selectedNoteIds;
    controller.toggleNormalNote('subscription-original');

    expect(controller.selectedNoteIds, before);
    expect(
      controller.normalNotes.map((note) => note.id),
      isNot(contains('subscription-original')),
    );
  });

  test('repository wait does not broadcast visual timer progress', () async {
    final notes = [for (var i = 0; i < 5; i++) _normal(i), _hotspot()];
    final repository = _GatedAggregationRepository();
    final controller = FeedAggregationController(
      library: _libraryWithDepositedNormals(notes),
      profileHub: ProfileHubController(referenceDay: DateTime(2026, 7, 13)),
      repository: repository,
    );
    addTearDown(controller.dispose);
    expect(controller.startSelection(), isTrue);
    final progressNotifications = <double>[];
    controller.addListener(
      () => progressNotifications.add(controller.progress),
    );

    final pending = controller.confirm();
    await Future<void>.delayed(const Duration(milliseconds: 140));

    expect(controller.status, FeedAggregationStatus.backgroundPending);
    expect(controller.progress, 1);
    expect(progressNotifications, [0, 1]);

    repository.release.complete();
    expect(await pending, isNotNull);
    expect(controller.status, FeedAggregationStatus.succeeded);
    expect(controller.progress, 1);
    expect(progressNotifications, [0, 1, 1]);
  });

  test(
    'session agent keeps five materials and returns kind-specific replies',
    () async {
      const port = SessionAggregationAgentMockPort(delay: Duration.zero);
      final session = await port.prepare(
        AggregationAgentLaunchRequest(
          kind: AggregationAgentKind.visual,
          noteIds: const ['a', 'b', 'c', 'd'],
          hotspotId: 'hotspot',
        ),
      );

      expect(session.materialIds, ['a', 'b', 'c', 'd', 'hotspot']);
      expect(session.kind, AggregationAgentKind.visual);
      expect(
        await port.reply(session: session, message: '设计一张封面'),
        contains('主视觉'),
      );
    },
  );

  test(
    'production selection previews and reshuffles four synchronized notes',
    () {
      final notes = <V3FeedItem>[
        for (var index = 0; index < 7; index += 1)
          V3FeedItem(
            id: 'production-preview-$index',
            remoteNoteId: 'remote-preview-$index',
            remoteSourceKind: 'manual',
            rawPartRevisionId: 'raw-preview-$index',
            title: '生产候选 $index',
            source: V3MaterialSource.note,
            createdAt: DateTime.utc(2026, 8, 20 + index),
            rawBody: '正文 $index',
          ),
      ];
      final library = _libraryWithDepositedNormals(notes);
      final controller = FeedAggregationController(
        library: library,
        profileHub: ProfileHubController(referenceDay: DateTime(2026, 8, 29)),
        repository: const UnavailableFeedAggregationRepository(),
        topicCollisionRuns: _SequenceTopicCollisionRunPort(
          accepted: _collisionRun('running'),
          snapshots: const <TopicCollisionRun>[],
        ),
        preferences: AppPreferencesDao(AppDatabase()),
        workspaceId: () => 'workspace-production-preview',
        workspaceReady: () => true,
        random: Random(19),
      );
      addTearDown(controller.dispose);

      expect(controller.startSelection(), isTrue);
      final first = controller.selectedNoteIds;
      expect(first, hasLength(4));
      expect(controller.canReshuffle, isTrue);

      controller.reshuffle();

      expect(controller.selectedNoteIds, hasLength(4));
      expect(controller.selectedNoteIds, isNot(first));
      expect(controller.status, FeedAggregationStatus.selecting);
    },
  );

  test(
    'production collision keeps server-frozen sources and reads the output HNote',
    () async {
      final database = AppDatabase();
      final output = _collisionOutput();
      final library = KnowledgeLibraryController(
        initialNotes: [for (var index = 0; index < 4; index++) _normal(index)],
        includeDemoFixtures: false,
        notePort: _CollisionOutputNotePort(<V3FeedItem>[output]),
      );
      final runs = _SequenceTopicCollisionRunPort(
        accepted: _collisionRun('running'),
        snapshots: <TopicCollisionRun>[
          _collisionRun('succeeded', outputNoteId: output.remoteNoteId),
        ],
      );
      final controller = FeedAggregationController(
        library: library,
        profileHub: ProfileHubController(referenceDay: DateTime(2026, 8, 14)),
        repository: const UnavailableFeedAggregationRepository(),
        topicCollisionRuns: runs,
        preferences: AppPreferencesDao(database),
        userScope: 'production-user',
        workspaceId: () => 'workspace-production',
        workspaceReady: () => true,
      );
      addTearDown(controller.dispose);
      _attachPollingRuntime(controller);

      expect(controller.startSelection(), isTrue);
      expect(await controller.confirm(), isNull);
      await _settleProductionRun();

      expect(runs.submitWorkspaceIds, <String>['workspace-production']);
      expect(controller.status, FeedAggregationStatus.succeeded);
      expect(controller.generatedNote?.remoteNoteId, output.remoteNoteId);
      expect(
        controller.selectedNoteIds,
        unorderedEquals(<String>[
          'normal-0',
          'normal-1',
          'normal-2',
          'normal-3',
        ]),
      );
      expect(controller.productionRun?.sources, isEmpty);
      expect(controller.selectedNotes, hasLength(4));
      expect(
        library.notes.map((note) => note.remoteNoteId),
        contains(output.remoteNoteId),
      );
    },
  );

  test(
    'production collision failure never creates a local replacement',
    () async {
      final library = KnowledgeLibraryController(
        initialNotes: [for (var index = 0; index < 4; index++) _normal(index)],
        includeDemoFixtures: false,
        notePort: const _CollisionOutputNotePort(<V3FeedItem>[]),
      );
      final controller = FeedAggregationController(
        library: library,
        profileHub: ProfileHubController(referenceDay: DateTime(2026, 8, 14)),
        repository: const UnavailableFeedAggregationRepository(),
        topicCollisionRuns: _SequenceTopicCollisionRunPort(
          accepted: _collisionRun('running'),
          snapshots: <TopicCollisionRun>[
            _collisionRun(
              'failed',
              failureCode: 'TOPIC_COLLISION_MODEL_FAILED',
            ),
          ],
        ),
        preferences: AppPreferencesDao(AppDatabase()),
        workspaceId: () => 'workspace-production',
        workspaceReady: () => true,
      );
      addTearDown(controller.dispose);
      _attachPollingRuntime(controller);

      expect(controller.startSelection(), isTrue);
      await controller.confirm();
      await _settleProductionRun();

      expect(controller.status, FeedAggregationStatus.failed);
      expect(controller.errorCode, 'TOPIC_COLLISION_MODEL_FAILED');
      expect(controller.generatedNote, isNull);
      expect(
        library.notes.where(
          (note) => note.remoteNoteId == 'collision-output-note',
        ),
        isEmpty,
      );
    },
  );

  test('production polling pause and resume are idempotent', () async {
    final runs = _SequenceTopicCollisionRunPort(
      accepted: _collisionRun('running'),
      snapshots: const <TopicCollisionRun>[],
    );
    final controller = FeedAggregationController(
      library: KnowledgeLibraryController(
        initialNotes: [for (var index = 0; index < 4; index++) _normal(index)],
        includeDemoFixtures: false,
      ),
      profileHub: ProfileHubController(referenceDay: DateTime(2026, 8, 31)),
      repository: const UnavailableFeedAggregationRepository(),
      topicCollisionRuns: runs,
      preferences: AppPreferencesDao(AppDatabase()),
      workspaceId: () => 'workspace-lifecycle',
      workspaceReady: () => true,
      productionPollInterval: const Duration(milliseconds: 5),
    );
    addTearDown(controller.dispose);
    final activityMetrics = _attachPollingRuntime(controller);

    expect(controller.startSelection(), isTrue);
    await controller.confirm();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(runs.getCalls, greaterThan(0));

    controller.pauseProductionPolling();
    controller.pauseProductionPolling();
    await _settleProductionRun();
    final pausedCalls = runs.getCalls;
    await Future<void>.delayed(const Duration(milliseconds: 25));

    expect(runs.getCalls, pausedCalls);
    expect(controller.status, FeedAggregationStatus.backgroundPending);
    expect(controller.productionRun?.topicCollisionRunId, 'topic-collision-1');
    expect(activityMetrics.current.activePollers, 0);

    controller.resumeProductionPolling();
    controller.resumeProductionPolling();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(runs.getCalls, greaterThan(pausedCalls));
    expect(activityMetrics.current.activePollers, 1);

    controller.pauseProductionPolling();
    controller.pauseProductionPolling();
    await _settleProductionRun();
    final repausedCalls = runs.getCalls;
    await Future<void>.delayed(const Duration(milliseconds: 25));
    expect(runs.getCalls, repausedCalls);
  });

  test(
    'production collision restores an accepted Run for the same account',
    () async {
      final database = AppDatabase();
      final output = _collisionOutput();
      final runs = _SequenceTopicCollisionRunPort(
        accepted: _collisionRun('running'),
        snapshots: <TopicCollisionRun>[
          _collisionRun('running'),
          _collisionRun('succeeded', outputNoteId: output.remoteNoteId),
        ],
      );
      final first = FeedAggregationController(
        library: KnowledgeLibraryController(
          initialNotes: [
            for (var index = 0; index < 4; index++) _normal(index),
          ],
          includeDemoFixtures: false,
          notePort: const _CollisionOutputNotePort(<V3FeedItem>[]),
        ),
        profileHub: ProfileHubController(referenceDay: DateTime(2026, 8, 14)),
        repository: const UnavailableFeedAggregationRepository(),
        topicCollisionRuns: runs,
        preferences: AppPreferencesDao(database),
        userScope: 'restored-user',
        workspaceId: () => 'workspace-restored',
        workspaceReady: () => true,
      );
      _attachPollingRuntime(first);
      expect(first.startSelection(), isTrue);
      await first.confirm();
      await _settleProductionRun();
      expect(first.status, FeedAggregationStatus.backgroundPending);
      first.dispose();

      final restored = FeedAggregationController(
        library: KnowledgeLibraryController(
          initialNotes: [
            for (var index = 0; index < 4; index++) _normal(index),
          ],
          includeDemoFixtures: false,
          notePort: _CollisionOutputNotePort(<V3FeedItem>[output]),
        ),
        profileHub: ProfileHubController(referenceDay: DateTime(2026, 8, 14)),
        repository: const UnavailableFeedAggregationRepository(),
        topicCollisionRuns: runs,
        preferences: AppPreferencesDao(database),
        userScope: 'restored-user',
        workspaceId: () => 'workspace-restored',
        workspaceReady: () => true,
      );
      addTearDown(restored.dispose);
      _attachPollingRuntime(restored);
      await _settleProductionRun();

      expect(restored.status, FeedAggregationStatus.succeeded);
      expect(restored.generatedNote?.remoteNoteId, output.remoteNoteId);
      expect(restored.taskId, 'topic-collision-1');
    },
  );

  test('production collision restores after Workspace becomes ready', () async {
    final database = AppDatabase();
    final output = _collisionOutput();
    final runs = _SequenceTopicCollisionRunPort(
      accepted: _collisionRun('running'),
      snapshots: <TopicCollisionRun>[
        _collisionRun('running'),
        _collisionRun('succeeded', outputNoteId: output.remoteNoteId),
      ],
    );
    final firstLibrary = KnowledgeLibraryController(
      initialNotes: [for (var index = 0; index < 4; index++) _normal(index)],
      includeDemoFixtures: false,
    );
    addTearDown(firstLibrary.dispose);
    final first = FeedAggregationController(
      library: firstLibrary,
      profileHub: ProfileHubController(referenceDay: DateTime(2026, 8, 14)),
      repository: const UnavailableFeedAggregationRepository(),
      topicCollisionRuns: runs,
      preferences: AppPreferencesDao(database),
      userScope: 'deferred-workspace-user',
      workspaceId: () => 'workspace-deferred',
      workspaceReady: () => true,
    );
    _attachPollingRuntime(first);

    expect(first.startSelection(), isTrue);
    await first.confirm();
    await _settleProductionRun();
    expect(first.status, FeedAggregationStatus.backgroundPending);
    first.dispose();

    var workspaceReady = false;
    final restoredLibrary = KnowledgeLibraryController(
      initialNotes: [for (var index = 0; index < 4; index++) _normal(index)],
      includeDemoFixtures: false,
      notePort: _CollisionOutputNotePort(<V3FeedItem>[output]),
    );
    addTearDown(restoredLibrary.dispose);
    final restored = FeedAggregationController(
      library: restoredLibrary,
      profileHub: ProfileHubController(referenceDay: DateTime(2026, 8, 14)),
      repository: const UnavailableFeedAggregationRepository(),
      topicCollisionRuns: runs,
      preferences: AppPreferencesDao(database),
      userScope: 'deferred-workspace-user',
      workspaceId: () => 'workspace-deferred',
      workspaceReady: () => workspaceReady,
    );
    addTearDown(restored.dispose);
    _attachPollingRuntime(restored);

    await _settleProductionRun();
    expect(restored.status, FeedAggregationStatus.idle);

    workspaceReady = true;
    restored.resumeProductionPolling();
    await _settleProductionRun();

    expect(restored.status, FeedAggregationStatus.succeeded);
    expect(restored.generatedNote?.remoteNoteId, output.remoteNoteId);
  });
}

RuntimeActivityMetrics _attachPollingRuntime(
  FeedAggregationController controller,
) {
  final orchestrator = TaskOrchestrator();
  final activityMetrics = RuntimeActivityMetrics();
  addTearDown(() {
    controller.dispose();
    orchestrator.dispose();
    activityMetrics.dispose();
  });
  controller.attachPollingRuntime(
    orchestrator: orchestrator,
    activityMetrics: activityMetrics,
  );
  return activityMetrics;
}

KnowledgeLibraryController _libraryWithDepositedNormals(
  List<V3FeedItem> notes,
) {
  final library = KnowledgeLibraryController(initialNotes: notes);
  for (final note in notes.where((note) => !note.isHotspot)) {
    library.depositContent(note.id);
  }
  return library;
}

V3FeedItem _normal(int index) => V3FeedItem(
  id: 'normal-$index',
  remoteNoteId: 'remote-$index',
  remoteSourceKind: 'manual',
  rawPartRevisionId: 'raw-$index',
  title: '普通笔记 $index',
  source: V3MaterialSource.note,
  createdAt: DateTime(2026, 7, 10 + index),
  rawBody: '普通笔记正文 $index',
  summaryBody: '普通笔记纲要 $index',
);

V3FeedItem _hotspot() => V3FeedItem(
  id: 'hotspot-test',
  title: '当前热点',
  source: V3MaterialSource.hotspot,
  ownership: V3NoteOwnership.hotspot,
  createdAt: DateTime(2026, 7, 13),
  rawBody: '',
  summaryBody: '热点纲要',
);

V3FeedItem _subscription() => V3FeedItem(
  id: 'subscription-original',
  title: '订阅原文',
  source: V3MaterialSource.subscription,
  ownership: V3NoteOwnership.subscribed,
  createdAt: DateTime(2026, 7, 13),
  rawBody: '订阅作者的原始内容',
);

final class _GatedAggregationRepository implements FeedAggregationRepository {
  final Completer<void> release = Completer<void>();

  @override
  Future<V3FeedItem> aggregate({
    required List<V3FeedItem> normalNotes,
    required V3FeedItem hotspotNote,
  }) async {
    await release.future;
    return const FeedAggregationMockRepository(
      delay: Duration.zero,
    ).aggregate(normalNotes: normalNotes, hotspotNote: hotspotNote);
  }
}

Future<void> _settleProductionRun() async {
  for (var index = 0; index < 6; index += 1) {
    await Future<void>.delayed(Duration.zero);
  }
}

V3FeedItem _collisionOutput() => V3FeedItem(
  id: 'collision-local-output',
  remoteNoteId: 'collision-output-note',
  title: '服务端聚合结果',
  source: V3MaterialSource.note,
  createdAt: DateTime.utc(2026, 8, 14),
  rawBody: '# 服务端聚合结果\n\n这是一份正式 HNote。',
);

TopicCollisionRun _collisionRun(
  String status, {
  String? outputNoteId,
  String? failureCode,
}) => TopicCollisionRun(
  topicCollisionRunId: 'topic-collision-1',
  status: status,
  selectedNoteCount: 4,
  workspaceId: 'workspace-production',
  stage: status,
  outputNoteId: outputNoteId,
  failureCode: failureCode,
);

final class _SequenceTopicCollisionRunPort implements TopicCollisionRunPort {
  _SequenceTopicCollisionRunPort({
    required this.accepted,
    required List<TopicCollisionRun> snapshots,
  }) : _snapshots = List<TopicCollisionRun>.of(snapshots);

  final TopicCollisionRun accepted;
  final List<TopicCollisionRun> _snapshots;
  final List<String> submitWorkspaceIds = <String>[];
  int getCalls = 0;

  @override
  Future<ApiResult<TopicCollisionRun>> submit(
    String workspaceId, {
    required List<String> noteIds,
    required String idempotencyKey,
  }) async {
    expect(noteIds, hasLength(4));
    submitWorkspaceIds.add(workspaceId);
    return _topicCollisionSuccess(
      TopicCollisionRun.fromJson({
        ...accepted.toJson(),
        'workspaceId': workspaceId,
      }),
    );
  }

  @override
  Future<ApiResult<TopicCollisionRun>> get(
    String workspaceId,
    String runId,
  ) async {
    getCalls += 1;
    final snapshot = _snapshots.isEmpty ? accepted : _snapshots.removeAt(0);
    return _topicCollisionSuccess(
      TopicCollisionRun.fromJson({
        ...snapshot.toJson(),
        'workspaceId': workspaceId,
      }),
    );
  }
}

final class _CollisionOutputNotePort
    implements KnowledgeNotePort, KnowledgeNoteRemoteListPort {
  const _CollisionOutputNotePort(this.notes);

  final List<V3FeedItem> notes;

  @override
  Future<KnowledgeNoteRemoteLoadResult> loadNotes() async =>
      KnowledgeNoteRemoteLoadResult.success(notes);

  @override
  Future<KnowledgeNotePortResult> updateNote(
    KnowledgeNoteUpdateRequest request,
  ) async => const KnowledgeNotePortResult.unavailable();
}

ApiResult<T> _topicCollisionSuccess<T>(T data) => ApiResult<T>.success(
  data: data,
  status: 200,
  idempotencyStore: SubmissionKeyStore.empty,
);
