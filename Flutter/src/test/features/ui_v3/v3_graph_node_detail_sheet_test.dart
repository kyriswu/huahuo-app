import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/features/ui_v3/domain/ui_v3_models.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_graph_node_detail_sheet.dart';

void main() {
  testWidgets('remote entity detail shows safe metadata and relationships', (
    tester,
  ) async {
    final node = V3GraphNode(
      id: 'entity-a',
      label: 'AI 创业',
      cluster: V3GraphCluster.viewpoint,
      position: Offset.zero,
      summary: '关于 AI 创业机会的知识实体。',
      entityType: '主题',
      labels: const ['趋势'],
      topics: const ['创业'],
      attributes: const {'来源数量': 4, 'private_path': '/private/entity.json'},
      updatedAt: DateTime.utc(2026, 7, 23, 10),
    );
    const other = V3GraphNode(
      id: 'entity-b',
      label: '商业模式',
      cluster: V3GraphCluster.method,
      position: Offset(100, 0),
      summary: '方法实体',
      entityType: '方法',
    );
    const edge = V3GraphEdge(
      id: 'edge-a-b',
      sourceId: 'entity-a',
      targetId: 'entity-b',
      kind: V3GraphRelationKind.linkedMaterial,
      label: '引用',
      directed: true,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showV3GraphNodeDetailSheet(
                context: context,
                node: node,
                edges: const [edge],
                nodesById: {'entity-a': node, 'entity-b': other},
              ),
              child: const Text('打开实体'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开实体'));
    await tester.pumpAndSettle();
    expect(find.text('AI 创业'), findsOne);
    expect(find.text('主题 · 笔记'), findsOne);
    expect(find.text('关于 AI 创业机会的知识实体。'), findsOne);
    expect(find.text('/private/entity.json'), findsNothing);

    await tester.drag(
      find.byKey(const ValueKey('feed-graph-node-detail-sheet')),
      const Offset(0, -420),
    );
    await tester.pumpAndSettle();
    expect(find.text('1 个'), findsOne);
    expect(find.text('引用 · 商业模式'), findsOne);
  });
}
