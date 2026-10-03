import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/features/ui_v3/data/mirofish_graph_mapper.dart';
import 'package:huahuoai_app/features/ui_v3/domain/ui_v3_models.dart';

void main() {
  test('content navigation maps logical hierarchy into graph nodes', () {
    const mapper = MiroFishGraphMapper();
    final snapshot = mapper.fromContentNavigation(<String, Object?>{
      'map': 'overview',
      'contentCursor': '42',
      'items': <Object?>[
        <String, Object?>{
          'ownerRef': <String, Object?>{'kind': 'book', 'id': 'book_1'},
          'path': 'book',
          'title': '我的典藏',
          'version': 3,
        },
        <String, Object?>{
          'ownerRef': <String, Object?>{
            'kind': 'book_section',
            'id': 'section_1',
          },
          'path': 'book/section-one',
          'title': '第一章',
          'revisionId': 'section_rev_1',
        },
      ],
    }, workspaceId: 'ws_1');

    expect(snapshot, isNotNull);
    expect(snapshot!.graphId, 'workspace:ws_1:overview');
    expect(snapshot.revision, 42);
    expect(snapshot.nodes, hasLength(2));
    expect(snapshot.edges.single.kind, V3GraphRelationKind.membership);
    expect(snapshot.nodes.last.attributes['logicalPath'], 'book/section-one');
  });

  test('content navigation rejects physical or traversal paths', () {
    const mapper = MiroFishGraphMapper();

    final snapshot = mapper.fromContentNavigation(<String, Object?>{
      'map': 'overview',
      'contentCursor': '1',
      'items': <Object?>[
        <String, Object?>{
          'ownerRef': <String, Object?>{'kind': 'hnote', 'id': 'note_1'},
          'path': '../private/note',
          'title': 'unsafe',
          'revisionId': 'rev_1',
        },
      ],
    }, workspaceId: 'ws_1');

    expect(snapshot, isNull);
  });

  test('MiroFish fields map into the neutral graph contract', () {
    const mapper = MiroFishGraphMapper();
    final snapshot = mapper.fromJson(<String, Object?>{
      'graph_uuid': 'miro-graph',
      'revision': 7,
      'entities': <Object?>[
        <String, Object?>{
          'uuid': 'entity-a',
          'name': '创业者',
          'labels': <String>['PERSON', 'Founder'],
          'attributes': <String, Object?>{'role': 'founder'},
        },
        <String, Object?>{
          'uuid': 'entity-b',
          'name': '产品',
          'labels': <String>['Product'],
        },
        <String, Object?>{
          'uuid': 'entity-c',
          'name': '落地项目',
          'labels': <String>['项目'],
        },
      ],
      'facts': <Object?>[
        <String, Object?>{
          'uuid': 'fact-1',
          'source_node_uuid': 'entity-a',
          'target_node_uuid': 'entity-b',
          'fact_type': 'CREATES',
          'name': '创建',
          'fact': '创业者创建产品',
          'episodes': <String>['episode-9'],
          'directed': true,
        },
        <String, Object?>{
          'source_node_uuid': 'entity-b',
          'target_node_uuid': 'entity-b',
          'fact_type': 'ITERATES',
          'fact': '产品持续迭代',
        },
      ],
    }, fallbackGraphId: 'fallback');

    expect(snapshot, isNotNull);
    expect(snapshot!.graphId, 'miro-graph');
    expect(snapshot.nodes.first.entityType, 'Person');
    expect(snapshot.nodes.first.labels, ['PERSON', 'Founder']);
    expect(snapshot.nodes[2].entityType, '项目');
    expect(snapshot.nodes[2].cluster, V3GraphCluster.caseItem);
    expect(snapshot.edges, hasLength(2));
    expect(snapshot.edges.first.id, 'fact-1');
    expect(snapshot.edges.first.label, '创建');
    expect(snapshot.edges.first.fact, '创业者创建产品');
    expect(snapshot.edges.first.episodes, ['episode-9']);
    expect(snapshot.edges.first.kind, V3GraphRelationKind.other);
    expect(snapshot.edges.first.relationType, 'CREATES');
    expect(snapshot.edges.last.id, startsWith('edge-'));
    expect(snapshot.edges.last.isSelfLoop, isTrue);
  });

  test('fallback edge identity is deterministic', () {
    const mapper = MiroFishGraphMapper();
    final payload = <String, Object?>{
      'entities': <Object?>[
        <String, Object?>{'uuid': 'a', 'name': 'A'},
        <String, Object?>{'uuid': 'b', 'name': 'B'},
      ],
      'facts': <Object?>[
        <String, Object?>{
          'source_node_uuid': 'a',
          'target_node_uuid': 'b',
          'fact_type': 'KNOWS',
          'fact': 'A knows B',
        },
      ],
    };

    expect(
      mapper.fromJson(payload, fallbackGraphId: 'g')!.edges.single.id,
      mapper.fromJson(payload, fallbackGraphId: 'g')!.edges.single.id,
    );
  });

  test('relationships collection with MiroFish endpoints is adapted', () {
    const mapper = MiroFishGraphMapper();
    final snapshot = mapper.fromJson(<String, Object?>{
      'entities': <Object?>[
        <String, Object?>{'uuid': 'a', 'name': 'A'},
        <String, Object?>{'uuid': 'b', 'name': 'B'},
      ],
      'relationships': <Object?>[
        <String, Object?>{
          'uuid': 'relationship-1',
          'source_node_uuid': 'a',
          'target_node_uuid': 'b',
          'name': '关联',
        },
      ],
    }, fallbackGraphId: 'g');

    expect(snapshot!.edges.single.id, 'relationship-1');
    expect(snapshot.edges.single.sourceId, 'a');
    expect(snapshot.edges.single.targetId, 'b');
  });
}
