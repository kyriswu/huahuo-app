import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/features/ui_v3/domain/feed_item_models.dart';
import 'package:huahuoai_app/features/ui_v3/domain/knowledge_note_outline.dart';
import 'package:huahuoai_app/features/ui_v3/domain/v3_markdown_outline.dart';

void main() {
  test('derives stable H1-H6 trees, ranges, and ignores fenced headings', () {
    final note = V3FeedItem(
      id: 'outline-note',
      title: '层级笔记',
      source: V3MaterialSource.note,
      createdAt: DateTime(2026, 7, 18),
      rawBody: '''
# 主题
正文
## 证据
### 细节
#### 深层
###### 叶级
最终正文
## 证据
```md
# 不是标题
```
# 结论
''',
      summaryBody: '# 摘要\n结论内容',
      sproutStatus: V3SproutTaskStatus.succeeded,
      sproutReport: V3SproutReport(
        id: 'report-1',
        noteId: 'outline-note',
        title: '深度洞察报告',
        markdown: '# 方向\n## 下一步',
        generatedAt: DateTime(2026, 7, 18, 1),
      ),
    );

    final first = V3KnowledgeNoteOutline.fromNote(note);
    final second = V3KnowledgeNoteOutline.fromNote(note);
    final raw = first.stage(V3KnowledgeOutlineStage.raw);

    expect(raw.headings.first, isA<V3MarkdownOutlineNode>());
    expect(raw.headings.map((heading) => heading.title), ['主题', '结论']);
    expect(raw.headings.first.children.map((heading) => heading.title), [
      '证据',
      '证据',
    ]);
    expect(raw.headings.first.children.first.children.single.title, '细节');
    final leaf = raw
        .headings
        .first
        .children
        .first
        .children
        .single
        .children
        .single
        .children
        .single;
    expect(leaf.level, 6);
    expect(leaf.directMarkdown, '最终正文');
    expect(leaf.sectionEndLineIndex, greaterThan(leaf.lineIndex));
    expect(raw.headings.first.directMarkdown, '正文');
    expect(raw.headings.first.sectionMarkdown, contains('###### 叶级'));
    expect(raw.flattenedHeadings.map((heading) => heading.sectionId), [
      'raw-主题',
      'raw-证据',
      'raw-细节',
      'raw-深层',
      'raw-叶级',
      'raw-证据-2',
      'raw-结论',
    ]);
    expect(
      second
          .stage(V3KnowledgeOutlineStage.raw)
          .flattenedHeadings
          .map((heading) => heading.sectionId),
      raw.flattenedHeadings.map((heading) => heading.sectionId),
    );
    expect(
      first.stage(V3KnowledgeOutlineStage.sprout).headings.single.sectionId,
      'sprout-方向',
    );
  });

  test('provides heading-free previews and honest stage states', () {
    final note = V3FeedItem(
      id: 'plain-note',
      title: '无标题笔记',
      source: V3MaterialSource.note,
      createdAt: DateTime(2026, 7, 18),
      rawBody: '第一行\n\n第二行   继续',
      summaryError: 'service unavailable',
      sproutStatus: V3SproutTaskStatus.failed,
      sproutError: 'timeout',
    );

    final outline = V3KnowledgeNoteOutline.fromNote(note);
    final raw = outline.stage(V3KnowledgeOutlineStage.raw);

    expect(raw.headings, isEmpty);
    expect(raw.preview, '第一行 第二行 继续');
    expect(outline.stage(V3KnowledgeOutlineStage.summary).stateLabel, '纲要生成失败');
    expect(
      outline.stage(V3KnowledgeOutlineStage.sprout).stateLabel,
      '深度洞察生成失败',
    );
  });

  test('defers and caches heading parsing per stage', () {
    final parsedStages = <V3KnowledgeOutlineStage>[];
    final previewStages = <V3KnowledgeOutlineStage>[];
    final note = V3FeedItem(
      id: 'lazy-note',
      title: '惰性标题',
      source: V3MaterialSource.note,
      createdAt: DateTime(2026, 7, 18),
      rawBody: '# 原始标题',
      summaryBody: '# 纲要标题',
      sproutStatus: V3SproutTaskStatus.succeeded,
      sproutTopic: '# 点火标题',
    );

    final outline = V3KnowledgeNoteOutline.fromNote(
      note,
      onHeadingsParsed: parsedStages.add,
      onPreviewDerived: previewStages.add,
    );
    expect(parsedStages, isEmpty);
    expect(previewStages, isEmpty);

    final raw = outline.stage(V3KnowledgeOutlineStage.raw);
    expect(raw.stateLabel, '原始内容');
    expect(previewStages, isEmpty);
    expect(raw.preview, '原始标题');
    expect(raw.preview, '原始标题');
    expect(previewStages, [V3KnowledgeOutlineStage.raw]);
    expect(parsedStages, isEmpty);

    expect(raw.headings.single.title, '原始标题');
    expect(raw.headings.single.title, '原始标题');
    expect(parsedStages, [V3KnowledgeOutlineStage.raw]);

    expect(
      outline.stage(V3KnowledgeOutlineStage.summary).headings.single.title,
      '纲要标题',
    );
    expect(parsedStages, [
      V3KnowledgeOutlineStage.raw,
      V3KnowledgeOutlineStage.summary,
    ]);
  });
}
