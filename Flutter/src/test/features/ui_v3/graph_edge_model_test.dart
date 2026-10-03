import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/features/ui_v3/domain/ui_v3_models.dart';

void main() {
  test('graph edge keeps stable explanatory metadata', () {
    final createdAt = DateTime.utc(2026, 7, 23, 8);
    final validAt = DateTime.utc(2026, 7, 24, 8);
    final edge = V3GraphEdge(
      id: 'edge-stable-1',
      sourceId: 'node-a',
      targetId: 'node-b',
      kind: V3GraphRelationKind.other,
      label: '支持',
      relationType: 'SUPPORTS',
      fact: '节点 A 支持节点 B',
      attributes: const <String, Object?>{'confidence': .91},
      episodes: const <String>['episode-1'],
      weight: .91,
      directed: true,
      createdAt: createdAt,
      validAt: validAt,
    );

    expect(edge.id, 'edge-stable-1');
    expect(edge.label, '支持');
    expect(edge.relationType, 'SUPPORTS');
    expect(edge.fact, contains('节点 A'));
    expect(edge.attributes['confidence'], .91);
    expect(edge.episodes, ['episode-1']);
    expect(edge.directed, isTrue);
    expect(edge.createdAt, createdAt);
    expect(edge.validAt, validAt);
    expect(edge.isSelfLoop, isFalse);
    expect(V3GraphRelationKind.other.label, '其他关系');
  });

  test('self loop is derived without changing relation identity', () {
    const edge = V3GraphEdge(
      id: 'edge-self',
      sourceId: 'node-a',
      targetId: 'node-a',
      kind: V3GraphRelationKind.sharedTopic,
      label: '反思',
    );

    expect(edge.isSelfLoop, isTrue);
    expect(edge.id, 'edge-self');
  });
}
