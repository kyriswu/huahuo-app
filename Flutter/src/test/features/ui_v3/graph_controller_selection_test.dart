import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/features/ui_v3/application/feed_graph_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_library_controller.dart';
import 'package:huahuoai_app/features/ui_v3/data/graph_repository.dart';
import 'package:huahuoai_app/features/ui_v3/domain/feed_item_models.dart';
import 'package:huahuoai_app/features/ui_v3/domain/graph_snapshot.dart';
import 'package:huahuoai_app/features/ui_v3/domain/ui_v3_models.dart';

void main() {
  test('knowledge query changes do not rebuild the deposited graph', () {
    final note = V3FeedItem(
      id: 'graph-note',
      title: 'Graph note',
      source: V3MaterialSource.note,
      createdAt: DateTime.utc(2026, 8, 31, 9),
      rawBody: 'Graph body',
    );
    final library = KnowledgeLibraryController(
      includeDemoFixtures: false,
      initialNotes: <V3FeedItem>[note],
    );
    final graph = FeedGraphController(library);
    addTearDown(graph.dispose);
    addTearDown(library.dispose);
    var graphNotifications = 0;
    graph.addListener(() => graphNotifications += 1);

    library.setQuery('unrelated presentation query');
    expect(graphNotifications, 0);

    library.updateNote(note.copyWith(title: 'Updated graph note'));
    expect(graphNotifications, greaterThan(0));
    expect(graph.nodeForId('graph-note')?.label, 'Updated graph note');
  });

  test('node and edge selection plus legend filters are mutually coherent', () {
    final library = KnowledgeLibraryController();
    for (final note in library.notes.where((note) => !note.isHotspot)) {
      library.depositContent(note.id);
    }
    final graph = FeedGraphController(library);
    final node = graph.nodes.firstWhere((node) => !node.center);
    final edge = graph.semanticEdges.firstWhere(
      (edge) => edge.sourceId == node.id || edge.targetId == node.id,
    );

    graph.selectNode(node.id);
    expect(graph.selectedNodeId, node.id);
    expect(graph.selectedEdgeId, isNull);
    expect(graph.nodeForId(node.id), same(node));

    graph.selectEdge(edge.id);
    expect(graph.selectedNodeId, isNull);
    expect(graph.selectedEdgeId, edge.id);
    expect(graph.edgeForId(edge.id), same(edge));

    graph.toggleEdgeLabels();
    graph.toggleLegend();
    expect(graph.showEdgeLabels, isFalse);
    expect(graph.showLegend, isTrue);

    graph.toggleEntityTypeFilter(node.entityType);
    expect(graph.selectedEntityTypes, {node.entityType});
    expect(graph.nodeMatchesEntityType(node), isTrue);
    const unmatched = V3GraphNode(
      id: 'other',
      label: 'Other',
      cluster: V3GraphCluster.viewpoint,
      position: Offset.zero,
      summary: '',
      entityType: 'Different',
    );
    expect(graph.nodeMatchesEntityType(unmatched), isFalse);

    graph.resetView();
    expect(graph.selectedNodeId, isNull);
    expect(graph.selectedEdgeId, isNull);
    expect(graph.selectedEntityTypes, isEmpty);
    graph.dispose();
  });

  test(
    'remote load is admitted once and concurrent refreshes are coalesced',
    () async {
      final repository = _QueueGraphRepository();
      final graph = FeedGraphController(
        KnowledgeLibraryController(),
        repository: repository,
        remoteGraphId: 'remote-graph',
      );
      final localSnapshot = graph.snapshot;
      expect(graph.dataSource, FeedGraphDataSource.localDepositedAssets);
      expect(graph.usingRemoteSnapshot, isFalse);
      final firstRefresh = graph.ensureRemoteGraphLoaded();

      expect(graph.isRefreshing, isTrue);
      expect(graph.loadingState, GraphLoadingState.loading);
      expect(graph.snapshot, same(localSnapshot));

      final secondRefresh = graph.refreshGraph();
      expect(secondRefresh, same(firstRefresh));
      expect(repository.requests, hasLength(1));
      repository.requests.single.complete(_remoteSnapshot('remote-graph', 1));
      await Future.wait(<Future<void>>[firstRefresh, secondRefresh]);

      expect(graph.isRefreshing, isFalse);
      expect(graph.loadingState, GraphLoadingState.ready);
      expect(graph.snapshot!.graphId, 'remote-graph');
      expect(graph.snapshot!.revision, 1);
      expect(graph.dataSource, FeedGraphDataSource.remoteSnapshot);
      expect(graph.usingRemoteSnapshot, isTrue);
      expect(graph.graphRevision, greaterThan(0));

      await graph.ensureRemoteGraphLoaded();
      expect(repository.requests, hasLength(1));

      final laterRefresh = graph.refreshGraph();
      expect(repository.requests, hasLength(2));
      repository.requests.last.complete(_remoteSnapshot('remote-graph', 2));
      await laterRefresh;
      expect(graph.snapshot!.revision, 2);
      graph.dispose();
    },
  );

  test(
    'empty local fallback shows loading until first remote response',
    () async {
      final repository = _QueueGraphRepository();
      final graph = FeedGraphController(
        KnowledgeLibraryController(initialNotes: const <V3FeedItem>[]),
        repository: repository,
        remoteGraphId: 'remote-graph',
      );

      expect(graph.nodes.where((node) => !node.center), isEmpty);
      expect(graph.loadingState, GraphLoadingState.loading);
      final refresh = graph.refreshGraph();
      expect(graph.loadingState, GraphLoadingState.loading);
      repository.requests.single.complete(_remoteSnapshot('remote-graph', 1));
      await refresh;
      expect(graph.loadingState, GraphLoadingState.ready);
      graph.dispose();
    },
  );

  test('remote failure preserves graph data and exposes retry state', () async {
    final repository = _QueueGraphRepository();
    final graph = FeedGraphController(
      KnowledgeLibraryController(),
      repository: repository,
      remoteGraphId: 'remote-graph',
    );
    final localNodes = graph.nodes;
    final refresh = graph.refreshGraph();
    repository.requests.single.completeError(
      const GraphRepositoryException(
        code: 'GRAPH_OFFLINE',
        userMessageKey: 'graph.error.offline',
        retryable: true,
      ),
    );
    await refresh;

    expect(graph.nodes, same(localNodes));
    expect(graph.isRefreshing, isFalse);
    expect(graph.loadingState, GraphLoadingState.failure);
    expect(graph.graphErrorCode, 'GRAPH_OFFLINE');
    expect(graph.dataSource, FeedGraphDataSource.localDepositedAssets);

    final retry = graph.retryGraphLoad();
    expect(graph.isRefreshing, isTrue);
    expect(graph.loadingState, GraphLoadingState.loading);
    repository.requests.last.complete(_remoteSnapshot('recovered', 3));
    await retry;
    expect(graph.snapshot!.graphId, 'recovered');
    expect(graph.graphErrorCode, isNull);
    graph.dispose();
  });

  test(
    'same graph revisions only move forward after remote acceptance',
    () async {
      final repository = _QueueGraphRepository();
      final graph = FeedGraphController(
        KnowledgeLibraryController(),
        repository: repository,
        remoteGraphId: 'remote-graph',
      );

      final first = graph.refreshGraph();
      repository.requests.single.complete(_remoteSnapshot('remote-graph', 5));
      await first;
      final accepted = graph.snapshot;
      final acceptedGraphRevision = graph.graphRevision;

      final duplicate = graph.refreshGraph();
      expect(graph.loadingState, GraphLoadingState.ready);
      repository.requests.last.complete(_remoteSnapshot('remote-graph', 5));
      await duplicate;
      expect(graph.snapshot, same(accepted));
      expect(graph.graphRevision, acceptedGraphRevision);

      final stale = graph.refreshGraph();
      repository.requests.last.complete(_remoteSnapshot('remote-graph', 4));
      await stale;
      expect(graph.snapshot, same(accepted));
      expect(graph.graphRevision, acceptedGraphRevision);

      final newer = graph.refreshGraph();
      repository.requests.last.complete(_remoteSnapshot('remote-graph', 6));
      await newer;
      expect(graph.snapshot!.revision, 6);
      expect(graph.graphRevision, greaterThan(acceptedGraphRevision));
      graph.dispose();
    },
  );

  test('revisionless MiroFish snapshots remain refreshable', () async {
    final repository = _QueueGraphRepository();
    final graph = FeedGraphController(
      KnowledgeLibraryController(initialNotes: const <V3FeedItem>[]),
      repository: repository,
      remoteGraphId: 'mirofish-graph',
    );

    final first = graph.refreshGraph();
    repository.requests.single.complete(_revisionlessSnapshot('first-node'));
    await first;
    expect(graph.nodeForId('first-node'), isNotNull);

    final second = graph.refreshGraph();
    repository.requests.last.complete(_revisionlessSnapshot('second-node'));
    await second;
    expect(graph.nodeForId('first-node'), isNull);
    final sourceLessNode = graph.nodeForId('second-node')!;
    expect(sourceLessNode.materialSourceProvided, isFalse);
    graph.setFilter(V3GraphFilter.note);
    expect(graph.nodeMatchesFilter(sourceLessNode), isFalse);
    graph.dispose();
  });
}

final class _QueueGraphRepository implements GraphRepository {
  final List<Completer<GraphSnapshot>> requests = <Completer<GraphSnapshot>>[];

  @override
  Future<GraphSnapshot> loadGraph({required String graphId}) {
    final request = Completer<GraphSnapshot>();
    requests.add(request);
    return request.future;
  }
}

GraphSnapshot _remoteSnapshot(String graphId, int revision) {
  return GraphSnapshot(
    graphId: graphId,
    revision: revision,
    updatedAt: DateTime.utc(2026, 7, 23),
    nodes: const <V3GraphNode>[
      V3GraphNode(
        id: 'remote-a',
        label: 'Remote A',
        cluster: V3GraphCluster.viewpoint,
        position: Offset(120, 180),
        summary: 'A',
        entityType: 'Person',
      ),
      V3GraphNode(
        id: 'remote-b',
        label: 'Remote B',
        cluster: V3GraphCluster.industry,
        position: Offset(280, 320),
        summary: 'B',
        entityType: 'Organization',
      ),
    ],
    edges: const <V3GraphEdge>[
      V3GraphEdge(
        id: 'remote-edge',
        sourceId: 'remote-a',
        targetId: 'remote-b',
        kind: V3GraphRelationKind.other,
        label: '任职于',
        directed: true,
      ),
    ],
  );
}

GraphSnapshot _revisionlessSnapshot(String nodeId) => GraphSnapshot(
  graphId: 'mirofish-graph',
  revision: 0,
  updatedAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
  nodes: <V3GraphNode>[
    V3GraphNode(
      id: nodeId,
      label: nodeId,
      cluster: V3GraphCluster.viewpoint,
      position: const Offset(120, 180),
      summary: nodeId,
      entityType: 'Topic',
      materialSourceProvided: false,
    ),
  ],
  edges: const <V3GraphEdge>[],
);
