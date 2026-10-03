import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/database/user_metadata_dao.dart';
import 'package:huahuoai_app/features/ui_v3/data/knowledge_user_metadata_repository.dart';
import 'package:huahuoai_app/features/ui_v3/domain/knowledge_library_models.dart';

void main() {
  test('tag overrides and card mode round-trip per account', () {
    final database = AppDatabase();
    KnowledgeUserMetadataRepository repositoryFor(String scope) {
      return KnowledgeUserMetadataRepository(
        dao: UserMetadataDao(database),
        userScope: scope,
      );
    }

    final accountA = repositoryFor('account-a');
    accountA.saveTagOverride(
      contentId: 'note-1',
      tags: const <String>[' AI ', 'ai', '产品'],
      updatedAt: DateTime.utc(2026, 7, 19),
    );
    accountA.saveCardDisplayMode(
      KnowledgeCardDisplayMode.compact,
      updatedAt: DateTime.utc(2026, 7, 19),
    );

    final restoredA = repositoryFor('account-a');
    expect(restoredA.loadTagOverrides()['note-1'], ['AI', '产品']);
    expect(restoredA.loadCardDisplayMode(), KnowledgeCardDisplayMode.compact);

    final accountB = repositoryFor('account-b');
    expect(accountB.loadTagOverrides(), isEmpty);
    expect(accountB.loadCardDisplayMode(), KnowledgeCardDisplayMode.expanded);
    accountB.saveTagOverride(contentId: 'note-1', tags: const ['另一个账号']);
    expect(accountA.loadTagOverrides()['note-1'], ['AI', '产品']);

    accountA.saveTagOverride(contentId: 'note-1', tags: const []);
    expect(accountA.loadTagOverrides(), isEmpty);
    expect(accountB.loadTagOverrides()['note-1'], ['另一个账号']);
  });

  test('normalization rejects invalid count and length', () {
    expect(normalizeKnowledgeTags(const <String>['A', 'a']), ['A']);
    expect(
      () => normalizeKnowledgeTags(const <String>['']),
      throwsArgumentError,
    );
    expect(
      () =>
          normalizeKnowledgeTags(<String>[List<String>.filled(25, 'x').join()]),
      throwsArgumentError,
    );
    expect(
      () => normalizeKnowledgeTags(
        List<String>.generate(21, (index) => 'tag-$index'),
      ),
      throwsArgumentError,
    );
  });

  test('malformed metadata rows are ignored', () {
    final database = AppDatabase();
    database.upsertRecord(
      LocalTableName.knowledgeItemUserMetadata,
      'malformed',
      const <String, Object?>{
        'user_scope': 'account-a',
        'content_id': 'note-bad',
        'custom_tags_json': '{bad-json',
      },
    );
    database.upsertRecord(
      LocalTableName.knowledgeViewPreferences,
      'malformed-mode',
      const <String, Object?>{
        'user_scope': 'account-a',
        'preference_key':
            KnowledgeUserMetadataRepository.cardDisplayPreferenceKey,
        'card_mode': 'huge',
      },
    );
    final repository = KnowledgeUserMetadataRepository(
      dao: UserMetadataDao(database),
      userScope: 'account-a',
    );

    expect(repository.loadTagOverrides(), isEmpty);
    expect(repository.loadCardDisplayMode(), KnowledgeCardDisplayMode.expanded);
  });
}
