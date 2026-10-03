import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/database/profile_workspace_dao.dart';
import 'package:huahuoai_app/features/ui_v3/application/profile_workspace_controller.dart';
import 'package:huahuoai_app/features/ui_v3/data/profile_workspace_repository.dart';
import 'package:huahuoai_app/features/ui_v3/domain/profile_workspace_models.dart';

void main() {
  test('profile workspace persists todo and hub position by account', () {
    final database = AppDatabase();
    final dao = ProfileWorkspaceDao(database);
    final repositoryA = ProfileWorkspaceRepository(
      dao: dao,
      userScope: 'user:a',
    );
    final repositoryB = ProfileWorkspaceRepository(
      dao: dao,
      userScope: 'user:b',
    );
    final controller = ProfileWorkspaceController(repository: repositoryA)
      ..restore();

    final todo = controller.createTodo(
      '完成资产整理',
      dueAt: DateTime(2026, 7, 21, 23, 59),
    );
    expect(todo, isNotNull);
    expect(controller.setTodoCompleted(todo!.id, true), isTrue);
    expect(
      controller.saveHubPosition(const ProfileHubPosition(x: .2, y: .8)),
      isTrue,
    );

    final restored = ProfileWorkspaceController(repository: repositoryA)
      ..restore();
    expect(restored.todos.single.isCompleted, isTrue);
    expect(restored.hubPosition?.x, closeTo(.2, .0001));
    expect(restored.hubPosition?.y, closeTo(.8, .0001));

    final isolated = ProfileWorkspaceController(repository: repositoryB)
      ..restore();
    expect(isolated.todos, isEmpty);
    expect(isolated.hubPosition, isNull);
  });

  test('growth uses immutable unique-deposit thresholds only', () {
    final controller = ProfileWorkspaceController();
    final progress = controller.growthProgress(
      personalContentCount: 999,
      explicitDepositCount: 12,
      completedCreationCount: 999,
    );

    expect(progress.totalPoints, 12);
    expect(progress.level, 5);
    expect(progress.pointsInLevel, 0);
    expect(progress.pointsToNextLevel, 10);
    expect(progress.levelSpan, 10);
    expect(progress.fraction, 0);

    final max = controller.growthProgress(
      personalContentCount: 0,
      explicitDepositCount: 92,
      completedCreationCount: 0,
    );
    expect(max.level, 10);
    expect(max.pointsToNextLevel, 0);
    expect(max.fraction, 1);
  });

  test('todo lifecycle is collision-free ordered and persisted', () {
    final database = AppDatabase();
    final repository = ProfileWorkspaceRepository(
      dao: ProfileWorkspaceDao(database),
      userScope: 'user:todo-lifecycle',
    );
    var now = DateTime(2026, 7, 24, 9);
    final controller = ProfileWorkspaceController(
      repository: repository,
      now: () => now,
    )..restore();

    final first = controller.createTodo('  整理经历资产  ');
    final second = controller.createTodo(
      '补充洞察标签',
      dueAt: DateTime(2026, 7, 23, 23, 59),
    );

    expect(first, isNotNull);
    expect(second, isNotNull);
    expect(first!.id, isNot(second!.id));
    expect(controller.todos.map((todo) => todo.id).toSet(), hasLength(2));
    expect(controller.todos.first.id, second.id);
    expect(second.isOverdueAt(now), isTrue);
    expect(controller.createTodo(List<String>.filled(61, '字').join()), isNull);
    expect(controller.createTodo('   '), isNull);

    now = DateTime(2026, 7, 24, 10);
    expect(
      controller.updateTodo(
        first.id,
        title: '整理表达倾向',
        dueAt: DateTime(2026, 7, 25, 18),
      ),
      isTrue,
    );
    expect(controller.setTodoCompleted(second.id, true), isTrue);
    expect(controller.todos.last.id, second.id);
    expect(controller.todos.last.isOverdueAt(now), isFalse);
    expect(controller.setTodoCompleted(second.id, false), isTrue);
    expect(controller.todos.first.id, second.id);
    expect(controller.todos.first.isOverdueAt(now), isTrue);

    final restored = ProfileWorkspaceController(repository: repository)
      ..restore();
    expect(restored.todos, hasLength(2));
    expect(restored.todos.first.id, second.id);
    expect(restored.todos.last.title, '整理表达倾向');

    expect(restored.deleteTodo(second.id), isTrue);
    expect(restored.deleteTodo('missing-todo'), isFalse);
    final afterDelete = ProfileWorkspaceController(repository: repository)
      ..restore();
    expect(afterDelete.todos.single.id, first.id);
  });

  test('masterpiece settings and due windows persist by account', () {
    final database = AppDatabase();
    final repository = ProfileWorkspaceRepository(
      dao: ProfileWorkspaceDao(database),
      userScope: 'user:masterpiece',
    );
    var now = DateTime(2026, 7, 1, 9);
    final controller = ProfileWorkspaceController(
      repository: repository,
      now: () => now,
    )..restore();

    expect(controller.masterpiece.isVisible, isTrue);
    expect(controller.masterpiece.cadence, MasterpieceCadence.weekly);
    expect(
      controller.saveMasterpieceDocument(
        markdown: '# 我的代表作\n\n完整正文',
        includedNoteIds: const <String>['note-a', 'note-b'],
      ),
      isTrue,
    );
    expect(
      controller.setMasterpieceCadence(MasterpieceCadence.monthly),
      isTrue,
    );
    now = DateTime(2026, 7, 31, 8, 59);
    expect(controller.masterpieceRefreshDue(), isFalse);
    now = DateTime(2026, 7, 31, 9);
    expect(controller.masterpieceRefreshDue(), isTrue);
    expect(controller.setMasterpieceVisible(false), isTrue);

    final restored = ProfileWorkspaceController(
      repository: repository,
      now: () => now,
    )..restore();
    expect(restored.masterpiece.isVisible, isFalse);
    expect(restored.masterpiece.cadence, MasterpieceCadence.monthly);
    expect(restored.masterpiece.markdown, contains('完整正文'));
    expect(restored.masterpiece.includedNoteIds, <String>['note-a', 'note-b']);
  });

  test('retired daily masterpiece cadence migrates and writes back weekly', () {
    final database = AppDatabase();
    final dao = ProfileWorkspaceDao(database);
    dao.upsertViewPreference(
      userScope: 'user:legacy-cadence',
      preferenceKey: 'profile-masterpiece-workspace',
      value: jsonEncode(<String, Object?>{
        'isVisible': true,
        'cadence': 'daily',
        'markdown': '# 旧代表作',
      }),
      updatedAt: DateTime(2026, 7, 1).toUtc().toIso8601String(),
    );
    final repository = ProfileWorkspaceRepository(
      dao: dao,
      userScope: 'user:legacy-cadence',
    );

    expect(repository.loadMasterpiece().cadence, MasterpieceCadence.weekly);
    final stored = dao
        .listViewPreferences('user:legacy-cadence')
        .singleWhere(
          (record) =>
              record['preference_key'] == 'profile-masterpiece-workspace',
        );
    expect(jsonDecode('${stored['card_mode']}')['cadence'], 'weekly');
  });
}
