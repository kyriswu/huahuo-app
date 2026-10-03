import 'package:flutter_test/flutter_test.dart';
import 'package:huahuo_editor/huahuo_editor.dart';
import 'package:huahuoai_app/features/ui_v3/data/creation_canvas_document_adapter.dart';
import 'package:huahuoai_app/features/ui_v3/domain/creation_canvas_draft.dart';
import 'package:huahuoai_app/features/ui_v3/domain/feed_item_models.dart';

void main() {
  test('round trips every Mobile draft field through the shared snapshot', () {
    final createdAt = DateTime.utc(2026, 7, 31, 8);
    final draft = CreationCanvasDraft(
      title: '跨端文档',
      markdown: '# 跨端文档\n',
      documentJson: '[{"insert":"跨端文档\\n"}]',
      documentFormatVersion: CreationCanvasDraft.currentDocumentFormatVersion,
      linkedMaterials: const <V3LinkedMaterialRef>[
        V3LinkedMaterialRef(
          id: 'meeting-1',
          source: V3MaterialSource.meeting,
          title: '会议材料',
          summary: '摘要',
        ),
      ],
      sourceTopicId: 'topic-1',
      sourceTitle: '来源选题',
      summaryMarkdown: '## 摘要',
      sproutMarkdown: '## 点火',
      aiAnnotations: <HuahuoAiAnnotation>[
        HuahuoAiAnnotation(
          id: 'annotation-1',
          stage: HuahuoNoteStage.raw,
          anchor: 'section-1',
          quote: '跨端文档',
          body: '补充一个事实',
          createdAt: createdAt,
        ),
      ],
      revision: 6,
      createdAt: createdAt,
      updatedAt: createdAt.add(const Duration(minutes: 3)),
    );

    final snapshot = CreationCanvasDocumentAdapter.snapshotFromDraft(
      id: 'document-1',
      draft: draft,
    )!;
    final restored = CreationCanvasDocumentAdapter.draftFromSnapshot(snapshot);

    expect(restored.title, draft.title);
    expect(restored.markdown, draft.markdown);
    expect(restored.documentJson, draft.documentJson);
    expect(restored.linkedMaterials.single.id, 'meeting-1');
    expect(restored.linkedMaterials.single.source, V3MaterialSource.meeting);
    expect(restored.linkedMaterials.single.summary, '摘要');
    expect(restored.sourceTopicId, 'topic-1');
    expect(restored.sourceTitle, '来源选题');
    expect(restored.revision, 6);
    expect(snapshot.summaryMarkdown, '## 摘要');
    expect(snapshot.sproutMarkdown, '## 点火');
    expect(restored.summaryMarkdown, '## 摘要');
    expect(restored.sproutMarkdown, '## 点火');
    expect(restored.aiAnnotations.single.id, 'annotation-1');
  });

  test('keeps legacy or unreadable Mobile drafts out of shared snapshots', () {
    final now = DateTime.utc(2026, 7, 31, 8);
    CreationCanvasDraft legacy({bool unreadable = false}) =>
        CreationCanvasDraft(
          title: '旧草稿',
          markdown: '仍可编辑',
          unreadableStructuredDocument: unreadable,
          revision: 1,
          createdAt: now,
          updatedAt: now,
        );

    expect(
      CreationCanvasDocumentAdapter.snapshotFromDraft(
        id: 'legacy',
        draft: legacy(),
      ),
      isNull,
    );
    expect(
      CreationCanvasDocumentAdapter.snapshotFromDraft(
        id: 'unreadable',
        draft: legacy(unreadable: true),
      ),
      isNull,
    );
  });

  test('rejects a shared material source unknown to Mobile', () {
    final now = DateTime.utc(2026, 7, 31, 8);
    final snapshot = HuahuoDocumentSnapshot(
      id: 'document-1',
      title: '未知来源',
      deltaJson: '[{"insert":"正文\\n"}]',
      linkedMaterials: <HuahuoLinkedMaterialRef>[
        HuahuoLinkedMaterialRef(
          id: 'material-1',
          source: 'future_source',
          title: '未来材料',
        ),
      ],
      revision: 1,
      createdAt: now,
      modifiedAt: now,
    );

    expect(
      () => CreationCanvasDocumentAdapter.draftFromSnapshot(snapshot),
      throwsFormatException,
    );
  });
}
