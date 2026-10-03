import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:huahuo_api/huahuo_api.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/database/app_preferences_dao.dart';
import 'package:huahuoai_app/features/ui_v3/application/deep_positioning_controller.dart';
import 'package:huahuoai_app/features/ui_v3/data/deep_positioning_repository.dart';

void main() {
  test(
    'presentation refresh drains an old read before loading the ready report',
    () async {
      final oldReport = DeepPositioningResult(
        markdown: '## 旧缓存报告',
        savedAt: DateTime.utc(2026, 8, 1),
      );
      final currentReport = DeepPositioningResult(
        markdown: '## 当前 Run 报告',
        savedAt: DateTime.utc(2026, 9, 2),
      );
      final repository = _QueuedRefreshRepository(oldReport);
      final controller = DeepPositioningController(repository);
      addTearDown(controller.dispose);

      expect(repository.refreshCalls, 1);
      final presentationRefresh = controller.refreshForReportPresentation();
      await Future<void>.delayed(Duration.zero);
      expect(repository.refreshCalls, 1);

      repository.completeNext(oldReport);
      await Future<void>.delayed(Duration.zero);
      expect(repository.refreshCalls, 2);
      expect(controller.result?.markdown, contains('旧缓存报告'));

      repository.completeNext(currentReport);
      expect(await presentationRefresh, isTrue);
      expect(controller.result?.markdown, contains('当前 Run 报告'));
    },
  );

  test(
    'requires six positioning fields and produces the four-part summary',
    () async {
      final controller = DeepPositioningController(
        const DeepPositioningMockRepository(delay: Duration.zero),
      );
      expect(controller.canSubmit, isFalse);
      expect(controller.isDemo, isTrue);
      controller
        ..updateIdentity('品牌咨询顾问')
        ..updateIndustry('企业服务')
        ..updateExpertise('内容定位与增长')
        ..updateTargetAudience('创业者')
        ..updateValue('建立可信内容体系')
        ..updateAccountGoal('获得咨询');
      expect(controller.canSubmit, isTrue);
      expect(await controller.save(), isTrue);
      expect(controller.result!.markdown, contains('## 账号定位'));
      expect(controller.result!.markdown, contains('## 服务对象'));
      expect(controller.result!.markdown, contains('## 核心价值'));
      expect(controller.result!.markdown, contains('## 内容方向'));
    },
  );

  test(
    'persistent demo report restores by account and isolates accounts',
    () async {
      final database = AppDatabase();
      final dao = AppPreferencesDao(database);
      final savedAt = DateTime.utc(2026, 7, 26, 9, 30);
      final repository = PersistentDeepPositioningMockRepository(
        dao: dao,
        userScope: 'positioning-user-a',
        now: () => savedAt,
        delay: Duration.zero,
      );
      const draft = DeepPositioningDraft(
        identity: '内容顾问',
        industry: '企业服务',
        expertise: '内容增长',
        targetAudience: '创业者',
        value: '建立可信表达',
        accountGoal: '获得咨询',
      );

      final saved = await repository.save(draft);
      final restored = PersistentDeepPositioningMockRepository(
        dao: dao,
        userScope: 'positioning-user-a',
        delay: Duration.zero,
      ).load();
      final isolated = PersistentDeepPositioningMockRepository(
        dao: dao,
        userScope: 'positioning-user-b',
        delay: Duration.zero,
      ).load();

      expect(saved.isDemo, isTrue);
      expect(restored, isNotNull);
      expect(restored!.markdown, saved.markdown);
      expect(restored.savedAt, savedAt);
      expect(restored.isDemo, isTrue);
      expect(isolated, isNull);
    },
  );

  test(
    'verified onboarding report is persisted by account and immediately visible',
    () async {
      final database = AppDatabase();
      final savedAt = DateTime.utc(2026, 8, 11, 10, 30);
      final repository = PersistentDeepPositioningRepository(
        dao: AppPreferencesDao(database),
        userScope: 'formal-positioning-user-a',
      );
      final controller = DeepPositioningController(repository);
      addTearDown(controller.dispose);

      expect(
        await controller.saveInitialReport(
          markdown: '## 基础定位报告\n\n完整的 Agent 结论。',
          savedAt: savedAt,
        ),
        isTrue,
      );
      expect(controller.result?.markdown, contains('完整的 Agent 结论。'));
      expect(controller.result?.isDemo, isFalse);
      expect(controller.result?.initialCompletedAt, savedAt);

      final restored = PersistentDeepPositioningRepository(
        dao: AppPreferencesDao(database),
        userScope: 'formal-positioning-user-a',
      ).load();
      final isolated = PersistentDeepPositioningRepository(
        dao: AppPreferencesDao(database),
        userScope: 'formal-positioning-user-b',
      ).load();
      expect(restored?.markdown, '## 基础定位报告\n\n完整的 Agent 结论。');
      expect(isolated, isNull);
    },
  );

  test(
    'remote formal report replaces stale Markdown and completes positioning',
    () async {
      final database = AppDatabase();
      final remote = _PositioningRemote(
        DeepPositioningResult(
          markdown: '''---
assetType: user_positioning_profile
schemaVersion: huahuo.positioning_profile.v1
sourceRefs:
  - ../../../用户原始输入.md
---

服务端草稿定位报告。

```huahuo-positioning-progress
{"completedPercent":65,"modules":[]}
```''',
          savedAt: DateTime.utc(2026, 8, 11, 11),
          progress: parsePositioningProgressPayload(<String, Object?>{
            'available': true,
            'coldStartPercent': 100,
            'coldStartCompleted': true,
            'completedPercent': 65,
            'modules': <Object?>[
              <String, Object?>{
                'id': 'credible_self',
                'score': 8,
                'weight': 10,
                'state': 'rich',
              },
            ],
          }),
        ),
      );
      final repository = PersistentDeepPositioningRepository(
        dao: AppPreferencesDao(database),
        userScope: 'profile-fallback-user',
        remote: remote,
      );

      final recovered = await repository.refresh();
      expect(recovered?.markdown, startsWith('服务端草稿定位报告。'));
      expect(recovered?.markdown, contains('huahuo-positioning-progress'));
      expect(recovered?.markdown, isNot(contains('assetType')));
      expect(recovered?.markdown, isNot(contains('../../../')));
      expect(recovered?.positioningStage, 1);
      expect(recovered?.progress?.completedPercent, 65);
      expect(repository.load()?.progress?.modules.first.score, 8);
      expect(repository.load()?.markdown, recovered?.markdown);
      expect(remote.calls, 1);

      final localAt = DateTime.utc(2026, 8, 11, 12);
      await repository.saveInitialReport(
        markdown: '完整 Lv1 定位报告。',
        savedAt: localAt,
      );
      remote.result = DeepPositioningResult(
        markdown: '服务端最新定位报告。',
        savedAt: DateTime.utc(2026, 8, 11, 13),
      );
      final refreshed = await repository.refresh();
      expect(refreshed?.markdown, '服务端最新定位报告。');
      expect(repository.load()?.markdown, '服务端最新定位报告。');
      expect(refreshed?.positioningStage, 1);
      expect(repository.load()?.positioningStage, 1);
      expect(remote.calls, 2);
    },
  );

  test('current Profile retains structured progress and server stage', () {
    final fallback = DateTime.utc(2026, 8, 18, 8);
    final draft = workspaceProfilePositioningReport(const <String, Object?>{
      'positioning': '## 旅行策展人\n\n当前定位草稿。',
      'updatedAt': '2026-08-18T07:47:40Z',
      'basicPositioningCompleted': false,
      'positioningStatus': 'in_progress',
      'positioningProgress': <String, Object?>{
        'available': true,
        'coldStartPercent': 100,
        'coldStartCompleted': false,
        'completedPercent': 65,
        'status': 'draft',
        'visibleSubject': '旅行内容定位',
        'modules': <Object?>[
          <String, Object?>{
            'id': 'credible_self',
            'label': '人生体验',
            'weight': 10,
            'score': 7,
            'state': 'rich',
          },
        ],
      },
    }, fallback: fallback);
    expect(draft?.markdown, contains('旅行策展人'));
    expect(draft?.savedAt, DateTime.utc(2026, 8, 18, 7, 47, 40));
    expect(draft?.initialCompletedAt, DateTime.utc(2026, 8, 18, 7, 47, 40));
    expect(draft?.positioningStage, 1);
    expect(draft?.progress?.completedPercent, 65);
    expect(draft?.progress?.visibleSubject, '旅行内容定位');
    expect(draft?.progress?.modules.first.score, 7);

    final completed = workspaceProfilePositioningReport(const <String, Object?>{
      'positioning': '## 正式基础定位报告',
      'basicPositioningCompleted': true,
      'positioningProgress': <String, Object?>{
        'available': true,
        'coldStartPercent': 100,
        'coldStartCompleted': true,
        'completedPercent': 100,
        'consultingCompleted': true,
        'modules': <Object?>[],
      },
    }, fallback: fallback);
    expect(completed?.initialCompletedAt, fallback);
    expect(completed?.positioningStage, 2);
  });

  test('application seed fills only an empty positioning report', () async {
    final database = AppDatabase();
    final dao = AppPreferencesDao(database);
    final seeded = PersistentDeepPositioningMockRepository(
      dao: dao,
      userScope: 'seeded-positioning-user',
      seedResult: v3DemoPersonPositioningResult,
      now: () => DateTime.utc(2026, 7, 29, 10),
      delay: Duration.zero,
    );

    expect(seeded.load()?.markdown, contains('老周不劝你'));
    expect(seeded.load()?.markdown, contains('不替你做决定'));
    expect(seeded.load()?.positioningStage, 2);

    const turns = <DeepPositioningConversationEntry>[
      DeepPositioningConversationEntry(
        text: '我想把真实的中年选择讲得更清楚。',
        isAssistant: false,
      ),
    ];
    final replacement = await seeded.saveConversation(turns, further: true);
    final restored = PersistentDeepPositioningMockRepository(
      dao: dao,
      userScope: 'seeded-positioning-user',
      seedResult: v3DemoPersonPositioningResult,
      delay: Duration.zero,
    ).load();

    expect(restored?.markdown, replacement.markdown);
    expect(restored?.markdown, isNot(contains('# 老周不劝你｜当前定位报告')));
    expect(restored?.positioningStage, 2);
  });

  test(
    'conversation turns create a bounded persistent progress report',
    () async {
      final database = AppDatabase();
      final repository = PersistentDeepPositioningMockRepository(
        dao: AppPreferencesDao(database),
        userScope: 'conversation-user',
        now: () => DateTime.utc(2026, 7, 27, 9),
        delay: Duration.zero,
      );
      final controller = DeepPositioningController(repository);
      addTearDown(controller.dispose);

      final saved = await controller
          .saveConversation(const <DeepPositioningConversationEntry>[
            DeepPositioningConversationEntry(
              text: '我希望把制造业数字化经验讲给中小企业管理者。',
              isAssistant: false,
            ),
            DeepPositioningConversationEntry(
              text: '下一步可以从你亲历的一个转型节点开始追问。',
              isAssistant: true,
            ),
          ]);

      expect(saved, isTrue);
      expect(controller.result!.isDemo, isTrue);
      expect(controller.result!.markdown, contains('## 当前定位线索'));
      expect(controller.result!.markdown, contains('制造业数字化经验'));
      expect(controller.result!.markdown, contains('AI 定位进展'));
      expect(repository.load()!.markdown, controller.result!.markdown);
    },
  );

  test(
    'initial and further positioning complete on separate sessions',
    () async {
      final database = AppDatabase();
      var now = DateTime.utc(2026, 7, 27, 9);
      final repository = PersistentDeepPositioningMockRepository(
        dao: AppPreferencesDao(database),
        userScope: 'positioning-stages',
        now: () => now,
        delay: Duration.zero,
      );
      const turns = <DeepPositioningConversationEntry>[
        DeepPositioningConversationEntry(text: '我的经历', isAssistant: false),
      ];

      final initial = await repository.saveConversation(turns);
      expect(initial.positioningStage, 1);
      expect(initial.initialCompletedAt, now);
      expect(initial.furtherCompletedAt, isNull);

      now = DateTime.utc(2026, 7, 27, 10);
      final sameSession = await repository.saveConversation(turns);
      expect(sameSession.positioningStage, 1);
      expect(sameSession.furtherCompletedAt, isNull);

      now = DateTime.utc(2026, 7, 28, 9);
      final further = await repository.saveConversation(turns, further: true);
      expect(further.positioningStage, 2);
      expect(further.initialCompletedAt, initial.initialCompletedAt);
      expect(further.furtherCompletedAt, now);
    },
  );
}

final class _PositioningRemote implements DeepPositioningRemotePort {
  _PositioningRemote(this.result);

  DeepPositioningResult? result;
  var calls = 0;

  @override
  Future<DeepPositioningResult?> loadReport() async {
    calls += 1;
    return result;
  }
}

final class _QueuedRefreshRepository
    implements DeepPositioningRepository, PositioningReportReadPort {
  _QueuedRefreshRepository(this.cached);

  final DeepPositioningResult cached;
  @override
  Future<PositioningReportRead> readReport() async => PositioningReportRead(
    PositioningReportOrigin.remote,
    report: await refresh(),
  );
  final List<Completer<DeepPositioningResult?>> _pending =
      <Completer<DeepPositioningResult?>>[];
  int refreshCalls = 0;

  void completeNext(DeepPositioningResult? result) {
    _pending.removeAt(0).complete(result);
  }

  @override
  bool get isDemo => false;

  @override
  DeepPositioningResult? load() => cached;

  @override
  Future<DeepPositioningResult?> refresh() {
    refreshCalls += 1;
    final completer = Completer<DeepPositioningResult?>();
    _pending.add(completer);
    return completer.future;
  }

  @override
  Future<DeepPositioningResult> saveInitialReport({
    required String markdown,
    required DateTime savedAt,
  }) => throw UnimplementedError();

  @override
  Future<DeepPositioningResult> save(DeepPositioningDraft draft) =>
      throw UnimplementedError();

  @override
  Future<DeepPositioningResult> saveConversation(
    List<DeepPositioningConversationEntry> entries, {
    bool further = false,
  }) => throw UnimplementedError();
}
