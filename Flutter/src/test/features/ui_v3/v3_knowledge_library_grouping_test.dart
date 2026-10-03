import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/database/v3_deposit_dao.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_library_controller.dart';
import 'package:huahuoai_app/features/ui_v3/data/v3_deposit_repository.dart';
import 'package:huahuoai_app/features/ui_v3/domain/feed_item_models.dart';
import 'package:huahuoai_app/features/ui_v3/domain/knowledge_library_models.dart';

void main() {
  test('groups the unified note set in all four supported ways', () {
    final controller = KnowledgeLibraryController(
      depositRepository: V3DepositRepository(
        dao: V3DepositDao(AppDatabase()),
        userScope: 'grouping-user',
      ),
      initialNotes: [
        V3FeedItem(
          id: 'mine',
          title: '我的案例',
          source: V3MaterialSource.meeting,
          createdAt: DateTime(2026, 7, 10),
          rawBody: '正文',
          contentLineId: 'line-1',
          contentLineName: '账号定位',
          folderId: 'legacy-folder',
          folderName: '旧文件夹',
        ),
        V3FeedItem(
          id: 'hot',
          title: '热点',
          source: V3MaterialSource.hotspot,
          ownership: V3NoteOwnership.hotspot,
          createdAt: DateTime(2026, 7, 13),
          rawBody: '',
          summaryBody: '热点纲要',
        ),
      ],
    );
    final folder = controller.createDepositFolder('客户案例')!;
    expect(controller.depositContent('mine', folderId: folder.id), isNotNull);

    controller.setDepositGrouping(V3KnowledgeGrouping.source);
    expect(controller.groupedDepositNotes.keys, ['会议']);
    controller.setDepositGrouping(V3KnowledgeGrouping.contentLine);
    expect(controller.groupedDepositNotes.keys, contains('账号定位'));
    controller.setDepositGrouping(V3KnowledgeGrouping.folder);
    expect(controller.groupedDepositNotes.keys, contains('客户案例'));
    expect(controller.groupedDepositNotes.keys, isNot(contains('旧文件夹')));
    controller.setDepositGrouping(V3KnowledgeGrouping.ownership);
    expect(controller.groupedDepositNotes.keys, ['我的内容']);
    expect(controller.graphNotes.map((note) => note.id), ['mine']);
    expect(
      controller.assignToDepositFolder(contentId: 'hot', folderId: folder.id),
      isFalse,
    );
    expect(controller.deleteNote('hot'), isNull);
  });
}
