import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/features/ui_v3/data/graph_snapshot_mapper.dart';
import 'package:huahuoai_app/features/ui_v3/domain/feed_item_models.dart';
import 'package:huahuoai_app/features/ui_v3/domain/ui_v3_models.dart';

void main() {
  test(
    'neutral mapper preserves multi edges, self loops, and node metadata',
    () {
      const mapper = GraphSnapshotMapper();
      final snapshot = mapper.fromJson(<String, Object?>{
        'graph_id': 'graph-001',
        'revision': 12,
        'updated_at': '2026-07-23T10:00:00Z',
        'nodes': <Object?>[
          <String, Object?>{
            'id': 'node-1',
            'label': 'AI 创业',
            'entity_type': 'Topic',
            'summary': '知识节点',
            'labels': <String>['Topic', 'Trend'],
            'attributes': <String, Object?>{'source_count': 4},
            'content_id': 'note-1',
            'source': 'link',
            'x': 120,
            'y': 180,
          },
          <String, Object?>{'id': 'node-2', 'label': '业务验证'},
          <String, Object?>{'id': 'node-2', 'label': '重复节点'},
          <String, Object?>{'id': '', 'label': '损坏节点'},
        ],
        'edges': <Object?>[
          _edgeJson('edge-1', 'node-1', 'node-2', 'REFERENCE'),
          _edgeJson('edge-2', 'node-1', 'node-2', 'SHARED_TOPIC'),
          _edgeJson('edge-self', 'node-1', 'node-1', 'REFLECTS'),
          _edgeJson('edge-dangling', 'node-1', 'missing', 'REFERENCE'),
          _edgeJson('edge-1', 'node-2', 'node-1', 'REFERENCE'),
        ],
      });

      expect(snapshot, isNotNull);
      expect(snapshot!.graphId, 'graph-001');
      expect(snapshot.revision, 12);
      expect(snapshot.nodes, hasLength(2));
      expect(snapshot.edges.map((edge) => edge.id), [
        'edge-1',
        'edge-2',
        'edge-self',
      ]);
      final node = snapshot.nodes.first;
      expect(node.entityType, 'Topic');
      expect(node.labels, ['Topic', 'Trend']);
      expect(node.attributes['source_count'], 4);
      expect(node.contentId, 'note-1');
      expect(node.materialSourceProvided, isTrue);
      expect(node.source, V3MaterialSource.link);
      expect(snapshot.nodes.last.materialSourceProvided, isFalse);
      expect(node.position.dx, 120);
      expect(snapshot.edges.last.isSelfLoop, isTrue);
      expect(snapshot.edges.last.kind, V3GraphRelationKind.other);
      expect(snapshot.edges.last.relationType, 'REFLECTS');
    },
  );

  test('entity types canonicalize and infer Chinese clusters', () {
    const mapper = GraphSnapshotMapper();
    final cases = <(String, String, V3GraphCluster)>[
      ('人物', '人物', V3GraphCluster.industry),
      ('组织', '组织', V3GraphCluster.industry),
      ('项目', '项目', V3GraphCluster.caseItem),
      ('观点', '观点', V3GraphCluster.viewpoint),
      ('方法', '方法', V3GraphCluster.method),
      ('案例', '案例', V3GraphCluster.caseItem),
      ('PERSON', 'Person', V3GraphCluster.industry),
      ('organization', 'Organization', V3GraphCluster.industry),
      ('proJect', 'Project', V3GraphCluster.caseItem),
      ('TOPIC', 'Topic', V3GraphCluster.trend),
      ('研究  领域', '研究 领域', V3GraphCluster.viewpoint),
    ];
    final snapshot = mapper.fromJson(<String, Object?>{
      'graph_id': 'entity-types',
      'nodes': <Object?>[
        for (var index = 0; index < cases.length; index++)
          <String, Object?>{
            'id': 'node-$index',
            'label': '节点 $index',
            'entity_type': cases[index].$1,
          },
      ],
      'edges': <Object?>[],
    });

    expect(snapshot, isNotNull);
    for (var index = 0; index < cases.length; index++) {
      expect(snapshot!.nodes[index].entityType, cases[index].$2);
      expect(snapshot.nodes[index].cluster, cases[index].$3);
      expect(snapshot.nodes[index].materialSourceProvided, isFalse);
    }
    expect(canonicalGraphEntityType(' Person '), 'Person');
    expect(canonicalGraphEntityType('person'), 'Person');
    expect(canonicalGraphEntityType('未知类型'), '未知类型');
    expect(canonicalGraphEntityType('另一个未知类型'), '另一个未知类型');
  });

  test('unrecognized explicit cluster falls back to the entity type', () {
    const mapper = GraphSnapshotMapper();
    final snapshot = mapper.fromJson(<String, Object?>{
      'graph_id': 'cluster-fallback',
      'nodes': <Object?>[
        <String, Object?>{
          'id': 'method',
          'label': '方法节点',
          'entity_type': '方法',
          'cluster': '后端自定义分组',
        },
      ],
      'edges': <Object?>[],
    });

    expect(snapshot!.nodes.single.cluster, V3GraphCluster.method);
  });

  test('malformed top-level payload is rejected without throwing', () {
    const mapper = GraphSnapshotMapper();

    expect(mapper.fromJson(null), isNull);
    expect(
      mapper.fromJson(<String, Object?>{'graph_id': 'missing-lists'}),
      isNull,
    );
  });
}

Map<String, Object?> _edgeJson(
  String id,
  String source,
  String target,
  String kind,
) {
  return <String, Object?>{
    'id': id,
    'source_id': source,
    'target_id': target,
    'kind': kind,
    'label': kind,
    'directed': true,
  };
}
