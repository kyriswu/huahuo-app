import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/features/ui_v3/application/feed_graph_controller.dart';
import 'package:huahuoai_app/features/ui_v3/domain/ui_v3_models.dart';

void main() {
  test(
    'layout projection aggregates unordered pairs and removes self loops',
    () {
      final semantic = <V3GraphEdge>[
        _edge('reference-a-b', 'a', 'b', directed: true),
        _edge('topic-a-b', 'a', 'b'),
        _edge('reference-b-a', 'b', 'a', directed: true),
        _edge('self-a', 'a', 'a'),
        _edge('dangling', 'a', 'missing'),
        _edge('pair-b-c', 'b', 'c'),
      ];

      final layout = buildGraphLayoutEdges(
        semantic,
        nodeIds: <String>{'a', 'b', 'c'},
      );

      expect(layout, hasLength(2));
      final pair = layout.firstWhere(
        (edge) => edge.sourceId == 'a' && edge.targetId == 'b',
      );
      expect(pair.kind, V3GraphRelationKind.sharedTopic);
      expect(pair.directed, isFalse);
      expect(pair.isSelfLoop, isFalse);
      expect(pair.attributes['semanticEdgeCount'], 3);
      expect(pair.attributes['semanticEdgeIds'], [
        'reference-a-b',
        'topic-a-b',
        'reference-b-a',
      ]);
    },
  );

  test('layout edge IDs are stable across semantic input order', () {
    final forward = <V3GraphEdge>[
      _edge('edge-2', 'b', 'a'),
      _edge('edge-1', 'a', 'b'),
    ];
    final reverse = forward.reversed.toList();

    expect(
      buildGraphLayoutEdges(forward).single.id,
      buildGraphLayoutEdges(reverse).single.id,
    );
  });

  test('pure membership groups retain membership physics semantics', () {
    const membership = V3GraphEdge(
      id: 'membership-center-a',
      sourceId: 'center',
      targetId: 'a',
      kind: V3GraphRelationKind.membership,
      label: '属于',
      weight: .24,
    );

    final layout = buildGraphLayoutEdges(const <V3GraphEdge>[membership]);

    expect(layout.single.kind, V3GraphRelationKind.membership);
    expect(layout.single.weight, .24);
  });

  test('community affinity wins over stronger parallel natural signals', () {
    const edges = <V3GraphEdge>[
      V3GraphEdge(
        id: 'community-a-b',
        sourceId: 'a',
        targetId: 'b',
        kind: V3GraphRelationKind.communityAffinity,
        label: '语义关联',
        weight: .72,
      ),
      V3GraphEdge(
        id: 'reference-a-b',
        sourceId: 'a',
        targetId: 'b',
        kind: V3GraphRelationKind.linkedMaterial,
        label: '引用',
        weight: .99,
      ),
    ];

    final layout = buildGraphLayoutEdges(edges);

    expect(layout.single.kind, V3GraphRelationKind.communityAffinity);
    expect(layout.single.weight, .72);
  });
}

V3GraphEdge _edge(
  String id,
  String sourceId,
  String targetId, {
  bool directed = false,
}) {
  return V3GraphEdge(
    id: id,
    sourceId: sourceId,
    targetId: targetId,
    kind: V3GraphRelationKind.sharedTopic,
    label: '关系',
    weight: .7,
    directed: directed,
  );
}
