import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/features/ui_v3/application/feed_graph_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_library_controller.dart';
import 'package:huahuoai_app/features/ui_v3/data/graph_repository.dart';
import 'package:huahuoai_app/features/ui_v3/domain/feed_item_models.dart';
import 'package:huahuoai_app/features/ui_v3/domain/graph_snapshot.dart';
import 'package:huahuoai_app/features/ui_v3/domain/ui_v3_models.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_interactive_graph.dart';
import 'package:huahuoai_app/shared/theme/huahuo_v3_theme.dart';
import 'package:integration_test/integration_test.dart';

const _overviewScreenshot = 'graph_sphere_01_overview_actual';
const _rotatedScreenshot = 'graph_sphere_02_rotated_actual';
const _zoomedScreenshot = 'graph_sphere_03_zoomed_actual';
const _selectedScreenshot = 'graph_sphere_04_selected_actual';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('captures spherical graph rotation, zoom and selection', (
    tester,
  ) async {
    final fixture = _SphereGraphFixture.build();
    final library = KnowledgeLibraryController(initialNotes: const []);
    final graph = FeedGraphController(
      library,
      repository: _FixtureGraphRepository(fixture.snapshot),
      remoteGraphId: fixture.snapshot.graphId,
    );
    await graph.refreshGraph();

    expect(graph.loadingState, GraphLoadingState.ready);
    expect(graph.nodes, hasLength(_SphereGraphFixture.nodeCount));
    expect(graph.semanticEdges, hasLength(fixture.edges.length));
    expect(
      graph.nodes.every(
        (node) =>
            node.attributes['depositStatus'] == 'deposited' &&
            node.attributes['ownership'] == 'mine',
      ),
      isTrue,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          knowledgeLibraryControllerProvider.overrideWith((ref) => library),
          feedGraphControllerProvider.overrideWith((ref) => graph),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: HuahuoV3Theme.light(),
          home: const _SphereGraphFixturePage(),
        ),
      ),
    );
    await _pumpFrames(tester, 72);

    final viewerFinder = find.byKey(
      const ValueKey('feed-graph-interactive-viewer'),
    );
    expect(viewerFinder, findsOneWidget);
    final initialViewer = tester.widget<InteractiveViewer>(viewerFinder);
    final initialScale = initialViewer.transformationController!.value
        .getMaxScaleOnAxis();
    final overview = await _capture(binding, tester, _overviewScreenshot);

    await _rotateSphere(tester, viewerFinder);
    final rotated = await _capture(binding, tester, _rotatedScreenshot);
    expect(
      listEquals(overview, rotated),
      isFalse,
      reason: 'A visible sphere rotation must change the rendered frame.',
    );

    await _zoomSphere(tester, viewerFinder);
    final zoomedViewer = tester.widget<InteractiveViewer>(viewerFinder);
    final zoomedScale = zoomedViewer.transformationController!.value
        .getMaxScaleOnAxis();
    expect(zoomedScale, greaterThan(initialScale * 1.22));
    expect(zoomedScale, lessThanOrEqualTo(3.01));
    final zoomed = await _capture(binding, tester, _zoomedScreenshot);
    expect(
      listEquals(rotated, zoomed),
      isFalse,
      reason: 'A visible sphere zoom must change the rendered frame.',
    );

    final selectedNodeId = _firstVisibleNodeId(tester);
    expect(selectedNodeId, isNotNull);
    await tester.tap(
      find.byKey(ValueKey<String>(selectedNodeId!)).hitTestable(),
    );
    await _pumpFrames(tester, 10);
    expect(graph.selectedNodeId, selectedNodeId);
    await _capture(binding, tester, _selectedScreenshot);
  });
}

class _SphereGraphFixturePage extends StatelessWidget {
  const _SphereGraphFixturePage();

  @override
  Widget build(BuildContext context) => const Scaffold(
    body: SafeArea(
      child: SizedBox.expand(
        child: V3InteractiveGraph(
          aggregated: true,
          fullscreen: true,
          height: double.infinity,
        ),
      ),
    ),
  );
}

Future<void> _rotateSphere(WidgetTester tester, Finder viewerFinder) async {
  final bounds = tester.getRect(viewerFinder);
  final start = Offset(
    bounds.left + bounds.width * .18,
    bounds.top + bounds.height * .38,
  );
  final gesture = await tester.startGesture(start, pointer: 21);
  for (var step = 1; step <= 8; step++) {
    await gesture.moveTo(start + Offset(step * 13, step * -4.5));
    await tester.pump(const Duration(milliseconds: 24));
  }
  await gesture.up();
  await _pumpFrames(tester, 18);
}

Future<void> _zoomSphere(WidgetTester tester, Finder viewerFinder) async {
  final bounds = tester.getRect(viewerFinder);
  final center = bounds.center + const Offset(0, 20);
  const initialDistance = 30.0;
  final first = await tester.startGesture(
    center - const Offset(initialDistance, 0),
    pointer: 31,
  );
  final second = await tester.startGesture(
    center + const Offset(initialDistance, 0),
    pointer: 32,
  );
  await tester.pump(const Duration(milliseconds: 32));
  for (var step = 1; step <= 7; step++) {
    final distance = initialDistance + step * 10;
    await first.moveTo(center - Offset(distance, 0));
    await second.moveTo(center + Offset(distance, 0));
    await tester.pump(const Duration(milliseconds: 28));
  }
  await first.up();
  await second.up();
  await _pumpFrames(tester, 18);
}

String? _firstVisibleNodeId(WidgetTester tester) {
  for (var index = 0; index < _SphereGraphFixture.nodeCount; index++) {
    final id = 'sphere-asset-$index';
    if (find.byKey(ValueKey<String>(id)).hitTestable().evaluate().isNotEmpty) {
      return id;
    }
  }
  return null;
}

Future<List<int>> _capture(
  IntegrationTestWidgetsFlutterBinding binding,
  WidgetTester tester,
  String name,
) async {
  await _pumpFrames(tester, 12);
  final bytes = await binding.takeScreenshot(name);
  expect(bytes, isNotEmpty, reason: name);
  return bytes;
}

Future<void> _pumpFrames(WidgetTester tester, int count) async {
  for (var frame = 0; frame < count; frame++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

final class _FixtureGraphRepository implements GraphRepository {
  const _FixtureGraphRepository(this.snapshot);

  final GraphSnapshot snapshot;

  @override
  Future<GraphSnapshot> loadGraph({required String graphId}) async => snapshot;
}

final class _SphereGraphFixture {
  const _SphereGraphFixture({
    required this.snapshot,
    required this.nodes,
    required this.edges,
  });

  static const nodeCount = 500;
  static const _goldenAngle = math.pi * (3 - 2.23606797749979);

  factory _SphereGraphFixture.build() {
    final points = List<_SpherePoint>.generate(nodeCount, (index) {
      final normalized = (index + .5) / nodeCount;
      final y = 1 - 2 * normalized;
      final ringRadius = math.sqrt(math.max(0, 1 - y * y));
      final theta = index * _goldenAngle + math.sin(index * .71) * .075;
      final irregularRadius =
          .91 + math.sin(index * 1.37) * .065 + math.cos(index * .43) * .035;
      return _SpherePoint(
        x: math.cos(theta) * ringRadius * irregularRadius,
        y: y * irregularRadius,
        z: math.sin(theta) * ringRadius * irregularRadius,
      );
    }, growable: false);

    const entityTypes = <String>['观点', '组织', '方法', '案例', '灵感', '趋势'];
    const sources = <V3MaterialSource>[
      V3MaterialSource.note,
      V3MaterialSource.meeting,
      V3MaterialSource.link,
      V3MaterialSource.recordingCard,
      V3MaterialSource.documentImport,
    ];
    final nodes = List<V3GraphNode>.generate(nodeCount, (index) {
      final point = points[index];
      final perspective = 1 + point.z * .1;
      return V3GraphNode(
        id: 'sphere-asset-$index',
        label: '球体资产 ${index + 1}',
        cluster: V3GraphCluster.values[index % V3GraphCluster.values.length],
        position: Offset(
          450 + point.x * 350 * perspective,
          430 + point.y * 350 * perspective,
        ),
        summary: '仅用于球体图谱模拟器验收的已沉淀资产 ${index + 1}。',
        entityType: entityTypes[index % entityTypes.length],
        attributes: <String, Object?>{
          'ownership': 'mine',
          'depositStatus': 'deposited',
          'fixture': 'sphere-screenshot',
          'sphereX': point.x,
          'sphereY': point.y,
          'sphereZ': point.z,
        },
        labels: const <String>['已沉淀', '球体验收'],
        contentId: 'sphere-content-$index',
        weight: 1 + ((index * 17) % 11) * .08,
        source: sources[index % sources.length],
        updatedAt: DateTime.utc(2026, 7, 25, 8).add(Duration(minutes: index)),
        topics: <String>['球体主题 ${index % 8 + 1}', '内部资产'],
        isRecent: index < 8,
      );
    }, growable: false);

    final edgeKeys = <String>{};
    final edges = <V3GraphEdge>[];
    for (var source = 0; source < nodeCount; source++) {
      final neighbours =
          <int>[
            for (var target = 0; target < nodeCount; target++)
              if (target != source) target,
          ]..sort((left, right) {
            final leftDistance = points[source].distanceSquaredTo(points[left]);
            final rightDistance = points[source].distanceSquaredTo(
              points[right],
            );
            final distance = leftDistance.compareTo(rightDistance);
            return distance != 0 ? distance : left.compareTo(right);
          });
      for (final target in neighbours.take(3)) {
        final low = math.min(source, target);
        final high = math.max(source, target);
        final key = '$low-$high';
        if (!edgeKeys.add(key)) continue;
        final kind = V3GraphRelationKind
            .values[(source + target) % V3GraphRelationKind.values.length];
        edges.add(
          V3GraphEdge(
            id: 'sphere-edge-$key',
            sourceId: 'sphere-asset-$low',
            targetId: 'sphere-asset-$high',
            kind: kind,
            label: kind.label,
            fact: '两项已沉淀资产具有稳定的${kind.label}关系。',
            attributes: const <String, Object?>{'fixture': 'sphere-screenshot'},
            weight: .82 + ((low + high) % 5) * .07,
          ),
        );
      }
    }

    return _SphereGraphFixture(
      snapshot: GraphSnapshot(
        graphId: 'sphere-screenshot-$nodeCount-${edges.length}',
        nodes: nodes,
        edges: edges,
        revision: 20260725,
        updatedAt: DateTime.utc(2026, 7, 25, 9),
      ),
      nodes: List<V3GraphNode>.unmodifiable(nodes),
      edges: List<V3GraphEdge>.unmodifiable(edges),
    );
  }

  final GraphSnapshot snapshot;
  final List<V3GraphNode> nodes;
  final List<V3GraphEdge> edges;
}

final class _SpherePoint {
  const _SpherePoint({required this.x, required this.y, required this.z});

  final double x;
  final double y;
  final double z;

  double distanceSquaredTo(_SpherePoint other) {
    final dx = x - other.x;
    final dy = y - other.y;
    final dz = z - other.z;
    return dx * dx + dy * dy + dz * dz;
  }
}
