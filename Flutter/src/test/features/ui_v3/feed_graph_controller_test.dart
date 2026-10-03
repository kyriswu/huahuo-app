import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/features/ui_v3/application/feed_graph_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_library_controller.dart';
import 'package:huahuoai_app/features/ui_v3/domain/feed_item_models.dart';
import 'package:huahuoai_app/features/ui_v3/domain/graph_snapshot.dart';
import 'package:huahuoai_app/features/ui_v3/domain/ui_v3_models.dart';

import 'graph_test_fixture.dart';

void main() {
  test('local graph exposes personal assets and subscribed snapshots only', () {
    final library = _depositedLibrary();
    final subscribedOriginal = library.notes.firstWhere(
      (note) => note.ownership == V3NoteOwnership.subscribed,
    );
    final subscribedSnapshot = library.depositSubscribedSnapshot(
      subscribedOriginal.id,
    );
    expect(subscribedSnapshot, isNotNull);
    final graph = FeedGraphController(library);

    final noteIds = library.allDepositedNotes.map((note) => note.id).toSet();
    expect(noteIds, isNotEmpty);
    expect(library.allDepositedNotes.every((note) => !note.isHotspot), isTrue);
    expect(graph.nodes, hasLength(noteIds.length + 1));
    final graphNoteIds = graph.nodes
        .where((node) => !node.center)
        .map((node) => node.id)
        .toSet();
    expect(graphNoteIds, noteIds);
    for (final node in graph.nodes.where((node) => !node.center)) {
      expect(library.noteForId(node.id), isNotNull);
    }
    expect(
      library.allDepositedNotes.map((note) => note.source).toSet(),
      isNot(contains(V3MaterialSource.hotspot)),
    );
    expect(
      library.allDepositedNotes.every(
        (note) => note.ownership == V3NoteOwnership.mine,
      ),
      isTrue,
    );
    expect(noteIds, contains(subscribedSnapshot!.id));
    expect(noteIds, isNot(contains(subscribedOriginal.id)));
    expect(graph.dataSource, FeedGraphDataSource.localDepositedAssets);
    expect(graph.usingRemoteSnapshot, isFalse);

    final membershipEdges = graph.edges
        .where((edge) => edge.kind == V3GraphRelationKind.membership)
        .toList();
    expect(membershipEdges, hasLength(noteIds.length));
    expect(graph.overviewEdges, same(graph.semanticEdges));
    expect(graph.layoutEdges.length, lessThan(graph.semanticEdges.length));
    final connectedNoteIds = <String>{};
    for (final edge in membershipEdges) {
      expect(edge.kind, V3GraphRelationKind.membership);
      expect(edge.sourceId, 'center');
      expect(noteIds, contains(edge.targetId));
      connectedNoteIds.add(edge.targetId);
    }
    expect(connectedNoteIds, noteIds);
    final semanticIds = <String>{};
    final semanticPairs = <String>{};
    var hasParallelRelations = false;
    for (final edge in graph.semanticEdges) {
      expect(semanticIds.add(edge.id), isTrue);
      final endpoints = <String>[edge.sourceId, edge.targetId]..sort();
      if (!semanticPairs.add(endpoints.join('\u0000'))) {
        hasParallelRelations = true;
      }
      if (edge.kind != V3GraphRelationKind.membership) {
        expect(noteIds, containsAll(endpoints));
      }
    }
    expect(hasParallelRelations, isTrue);
    final layoutPairs = <String>{};
    for (final edge in graph.layoutEdges) {
      expect(edge.isSelfLoop, isFalse);
      final endpoints = <String>[edge.sourceId, edge.targetId]..sort();
      expect(layoutPairs.add(endpoints.join('\u0000')), isTrue);
    }
    graph.dispose();
  });

  test(
    'graph exposes four stable semantic communities and deterministic cores',
    () {
      final library = _depositedLibrary();
      final graph = FeedGraphController(library);
      final noteIds = library.allDepositedNotes.map((note) => note.id).toSet();

      expect(graph.communities, hasLength(V3GraphCommunity.values.length));
      expect(
        graph.communities.every((snapshot) => snapshot.coreNodeId.isNotEmpty),
        isTrue,
      );
      expect(
        graph.communities.expand((snapshot) => snapshot.memberNodeIds).toSet(),
        noteIds,
      );
      for (final snapshot in graph.communities) {
        expect(snapshot.memberNodeIds, contains(snapshot.coreNodeId));
        expect(graph.roleForNode(snapshot.coreNodeId), V3GraphNodeRole.core);
        expect(graph.communityForNode(snapshot.coreNodeId), snapshot.community);
        for (final nodeId in snapshot.memberNodeIds) {
          expect(
            graph.roleForNode(nodeId),
            nodeId == snapshot.coreNodeId
                ? V3GraphNodeRole.core
                : V3GraphNodeRole.satellite,
          );
        }
      }
      expect(graph.roleForNode('center'), V3GraphNodeRole.center);

      final communities = graph.communities;
      final edges = graph.edges;
      final positions = <String, Offset>{
        for (final node in graph.nodes) node.id: graph.positionFor(node.id),
      };
      graph.selectNode(noteIds.first);
      expect(identical(graph.communities, communities), isTrue);
      expect(identical(graph.edges, edges), isTrue);
      expect(<String, Offset>{
        for (final node in graph.nodes) node.id: graph.positionFor(node.id),
      }, positions);
      graph.dispose();
    },
  );

  test('each natural signal becomes an independent stable semantic edge', () {
    final timestamp = DateTime.utc(2026, 7, 23);
    final library = _depositedLibrary(
      initialNotes: <V3FeedItem>[
        V3FeedItem(
          id: 'note-a',
          title: '笔记 A',
          source: V3MaterialSource.note,
          createdAt: timestamp,
          rawBody: 'A',
          contentLineId: 'line-1',
          contentLineName: '共同内容线',
          topics: const <String>['AI', '增长'],
          linkedMaterials: const <V3LinkedMaterialRef>[
            V3LinkedMaterialRef(
              id: 'note-b',
              source: V3MaterialSource.note,
              title: '笔记 B',
            ),
          ],
        ),
        V3FeedItem(
          id: 'note-b',
          title: '笔记 B',
          source: V3MaterialSource.note,
          createdAt: timestamp,
          rawBody: 'B',
          contentLineId: 'line-1',
          contentLineName: '共同内容线',
          topics: const <String>['AI', '增长'],
          linkedMaterials: const <V3LinkedMaterialRef>[
            V3LinkedMaterialRef(
              id: 'note-a',
              source: V3MaterialSource.note,
              title: '笔记 A',
            ),
          ],
        ),
      ],
    );
    final graph = FeedGraphController(library);
    final pair = graph.semanticEdges.where((edge) {
      return <String>{
            edge.sourceId,
            edge.targetId,
          }.containsAll(<String>{'note-a', 'note-b'}) &&
          edge.kind != V3GraphRelationKind.communityAffinity;
    }).toList();

    expect(
      pair.where((edge) => edge.kind == V3GraphRelationKind.linkedMaterial),
      hasLength(2),
    );
    expect(
      pair.where((edge) => edge.kind == V3GraphRelationKind.sharedContentLine),
      hasLength(1),
    );
    expect(
      pair.where((edge) => edge.kind == V3GraphRelationKind.sharedTopic),
      hasLength(2),
    );
    expect(pair.map((edge) => edge.id).toSet(), hasLength(pair.length));
    expect(
      graph.layoutEdges.where((edge) {
        return <String>{
          edge.sourceId,
          edge.targetId,
        }.containsAll(<String>{'note-a', 'note-b'});
      }),
      hasLength(1),
    );
    graph.dispose();
  });

  test('local focus, filters, and reset keep the complete graph in place', () {
    final library = _depositedLibrary();
    final graph = FeedGraphController(
      library,
      now: () => DateTime(2026, 7, 17, 12),
    );

    graph.selectNode(graphTestPrimaryNoteId);
    expect(graph.selectedNodeId, graphTestPrimaryNoteId);
    expect(graph.hasLocalFocus, isTrue);
    expect(graph.firstDegreeNodeIds, contains('center'));
    expect(graph.firstDegreeNodeIds, isNotEmpty);
    expect(
      graph.focusedNodeIds,
      containsAll([graphTestPrimaryNoteId, 'center']),
    );
    expect(graph.focusedEdges, same(graph.edges));

    graph.setFilter(V3GraphFilter.audio);
    expect(
      graph.nodeMatchesFilter(
        graph.nodes.firstWhere((node) => node.id == graphTestAudioNoteId),
      ),
      isTrue,
    );
    expect(
      graph.nodeMatchesFilter(
        graph.nodes.firstWhere((node) => node.id == graphTestPrimaryNoteId),
      ),
      isFalse,
    );

    library.upsertProcessedTranscription(
      id: 'aggregation-filter-test',
      title: '聚合测试笔记',
      rawBody: '用于验证聚合筛选。',
      outlineBody: '聚合筛选纲要',
    );
    library.depositContent('aggregation-filter-test');
    graph.setFilter(V3GraphFilter.aggregated);
    final aggregateNode = graph.nodes.firstWhere(
      (node) => node.id == 'aggregation-filter-test',
    );
    expect(aggregateNode.isAggregated, isTrue);
    expect(graph.nodeMatchesFilter(aggregateNode), isTrue);
    expect(graph.nodes, hasLength(library.allDepositedNotes.length + 1));

    graph.toggleSearch();
    graph.setSearchQuery('聚合测试');
    graph.resetView();
    expect(graph.selectedNodeId, isNull);
    expect(graph.hasLocalFocus, isFalse);
    expect(graph.activeFilter, V3GraphFilter.all);
    expect(graph.searchOpen, isFalse);
    expect(graph.searchQuery, isEmpty);
    expect(graph.nodes, hasLength(library.allDepositedNotes.length + 1));
    graph.dispose();
  });

  test('second-degree focus never expands through the universal center', () {
    final createdAt = DateTime.utc(2026, 7, 23);
    final library = _depositedLibrary(
      initialNotes: <V3FeedItem>[
        for (final entry in const <(String, V3MaterialSource)>[
          ('isolated-note', V3MaterialSource.note),
          ('isolated-link', V3MaterialSource.link),
          ('isolated-meeting', V3MaterialSource.meeting),
        ])
          V3FeedItem(
            id: entry.$1,
            title: entry.$1,
            source: entry.$2,
            createdAt: createdAt,
            rawBody: entry.$1,
            contentLineId: entry.$1,
            contentLineName: entry.$1,
            topics: <String>[entry.$1],
          ),
      ],
    );
    final graph = FeedGraphController(library)..selectNode('isolated-note');

    expect(graph.firstDegreeNodeIds, contains('center'));
    expect(graph.firstDegreeNodeIds.length, lessThanOrEqualTo(12));
    expect(graph.secondDegreeNodeIds.length, lessThanOrEqualTo(18));
    expect(graph.secondDegreeNodeIds, isEmpty);
    expect(
      graph.focusedNodeIds,
      containsAll(<String>['isolated-note', 'isolated-link', 'center']),
    );
    expect(graph.focusedNodeIds, isNot(contains('isolated-meeting')));
    graph.dispose();
  });

  test(
    'search covers topics and source labels with stable relevance ranking',
    () {
      final library = _depositedLibrary();
      final graph = FeedGraphController(library);

      graph.setSearchQuery('睡眠');
      expect(
        graph.searchResults.map((node) => node.id),
        contains(graphTestSearchNoteId),
      );
      expect(
        graph.searchResults.map((node) => node.id),
        isNot(contains(graphTestSubscriptionId)),
      );
      expect(graph.searchResults.first.id, graphTestSearchNoteId);

      graph.setSearchQuery('录音卡');
      expect(graph.searchResults, isNotEmpty);
      expect(
        graph.searchResults.every(
          (node) => node.source == V3MaterialSource.recordingCard,
        ),
        isTrue,
      );
      graph.dispose();
    },
  );

  test('search visibility follows the remote header contract', () {
    final library = _depositedLibrary();
    final graph = FeedGraphController(library);
    final expected = library.mineNotes.first;

    expect(graph.searchOpen, isFalse);

    graph.toggleSearch();
    graph.setSearchQuery(expected.title);

    expect(graph.searchOpen, isTrue);
    expect(graph.searchQuery, expected.title);
    expect(graph.searchResults.map((node) => node.id), contains(expected.id));

    graph.clearSearch();
    graph.clearSearch();

    expect(graph.searchOpen, isTrue);
    expect(graph.searchQuery, isEmpty);
    expect(graph.searchResults, isEmpty);

    graph.setSearchQuery(expected.title);
    graph.toggleSearch();

    expect(graph.searchOpen, isFalse);
    expect(graph.searchQuery, isEmpty);

    graph.toggleSearch();
    graph.setSearchQuery(expected.title);
    graph.closeSearch();
    graph.closeSearch();

    expect(graph.searchOpen, isFalse);
    expect(graph.searchQuery, isEmpty);
    graph.dispose();
  });

  test('beginning a drag anchors each rendered position before deltas', () {
    final library = _depositedLibrary();
    final graph = FeedGraphController(library);
    final cases = <({String nodeId, Offset rendered, Offset delta})>[
      (
        nodeId: library.mineNotes.first.id,

        rendered: const Offset(620, 310),
        delta: const Offset(12, -8),
      ),
      (
        nodeId: library.mineNotes.last.id,
        rendered: const Offset(175, 705),
        delta: const Offset(-15, 20),
      ),
    ];

    for (final testCase in cases) {
      graph.beginNodeDrag(testCase.nodeId, testCase.rendered);

      expect(graph.hasManualPosition(testCase.nodeId), isTrue);
      expect(graph.positionFor(testCase.nodeId), testCase.rendered);

      graph.moveNode(testCase.nodeId, testCase.delta);

      expect(
        graph.positionFor(testCase.nodeId),
        testCase.rendered + testCase.delta,
      );
    }
    graph.dispose();
  });

  test('anchoring an automatic position invalidates manual layout caching', () {
    final library = _depositedLibrary();
    final graph = FeedGraphController(library);
    final nodeId = library.mineNotes.first.id;
    final automaticPosition = graph.positionFor(nodeId);
    final initialRevision = graph.layoutRevision;

    graph.beginNodeDrag(nodeId, automaticPosition);

    expect(graph.hasManualPosition(nodeId), isTrue);
    expect(graph.positionFor(nodeId), automaticPosition);
    expect(graph.layoutRevision, greaterThan(initialRevision));
    graph.dispose();
  });

  test('recent metadata and weight expire against the injected clock', () {
    var now = DateTime(2026, 7, 17, 12);
    final library = _depositedLibrary(
      initialNotes: <V3FeedItem>[
        V3FeedItem(
          id: 'recency-boundary-note',
          title: '时效边界笔记',
          source: V3MaterialSource.note,
          createdAt: now.subtract(const Duration(days: 7)),
          rawBody: '用于验证最近状态跨过七天边界。',
        ),
      ],
    );
    final graph = FeedGraphController(library, now: () => now)
      ..setFilter(V3GraphFilter.recent);
    final initialRevision = graph.layoutRevision;
    final recentNode = graph.nodes.firstWhere(
      (node) => node.id == 'recency-boundary-note',
    );

    expect(recentNode.isRecent, isTrue);
    expect(graph.nodeMatchesFilter(recentNode), isTrue);

    now = now.add(const Duration(milliseconds: 1));
    final expiredNode = graph.nodes.firstWhere(
      (node) => node.id == 'recency-boundary-note',
    );

    expect(graph.layoutRevision, greaterThan(initialRevision));
    expect(expiredNode.isRecent, isFalse);
    expect(expiredNode.weight, lessThan(recentNode.weight));
    expect(graph.nodeMatchesFilter(expiredNode), isFalse);
    graph.dispose();
  });

  test('graph derivations stay cached until their owning state changes', () {
    final library = _depositedLibrary();
    final graph = FeedGraphController(library);

    final initialNodes = graph.nodes;
    final initialEdges = graph.edges;
    final initialRevision = graph.layoutRevision;
    expect(identical(graph.nodes, initialNodes), isTrue);
    expect(identical(graph.edges, initialEdges), isTrue);

    graph.selectNode(graphTestPrimaryNoteId);
    final firstDegree = graph.firstDegreeNodeIds;
    final secondDegree = graph.secondDegreeNodeIds;
    expect(identical(graph.firstDegreeNodeIds, firstDegree), isTrue);
    expect(identical(graph.secondDegreeNodeIds, secondDegree), isTrue);
    expect(identical(graph.nodes, initialNodes), isTrue);
    expect(graph.layoutRevision, initialRevision);

    graph.setSearchQuery('睡眠');
    final searchResults = graph.searchResults;
    expect(searchResults, isNotEmpty);
    expect(identical(graph.searchResults, searchResults), isTrue);

    const draggedPosition = Offset(600, 320);
    graph.beginNodeDrag(graphTestPrimaryNoteId, draggedPosition);
    expect(graph.layoutRevision, greaterThan(initialRevision));
    expect(graph.positionFor(graphTestPrimaryNoteId), draggedPosition);
    expect(
      graph.nodes
          .firstWhere((node) => node.id == graphTestPrimaryNoteId)
          .position,
      draggedPosition,
    );
    expect(identical(graph.edges, initialEdges), isTrue);
    expect(identical(graph.firstDegreeNodeIds, firstDegree), isTrue);
    expect(identical(graph.secondDegreeNodeIds, secondDegree), isTrue);
    expect(identical(graph.searchResults, searchResults), isTrue);

    graph.setSearchQuery('第一次被客户赶出办公室');
    final matchingSearchResults = graph.searchResults;
    const dragDelta = Offset(8, -4);
    graph.moveNode(graphTestPrimaryNoteId, dragDelta);
    final movedPosition = draggedPosition + dragDelta;
    expect(identical(graph.searchResults, matchingSearchResults), isFalse);
    expect(
      graph.searchResults
          .firstWhere((node) => node.id == graphTestPrimaryNoteId)
          .position,
      movedPosition,
    );

    final draggedNodes = graph.nodes;
    final draggedRevision = graph.layoutRevision;
    library.upsertProcessedTranscription(
      id: 'cache-invalidation-note',
      title: '缓存失效笔记',
      rawBody: '外部世界变化需要刷新图谱缓存。',
      outlineBody: '刷新节点和边。',
    );
    expect(graph.layoutRevision, greaterThan(draggedRevision));
    expect(identical(graph.nodes, draggedNodes), isFalse);
    expect(identical(graph.edges, initialEdges), isFalse);
    final autoDepositRevision = graph.layoutRevision;
    final autoDepositedNodes = graph.nodes;
    final autoDepositedEdges = graph.edges;
    library.depositContent('cache-invalidation-note');
    expect(graph.layoutRevision, autoDepositRevision);
    expect(identical(graph.nodes, autoDepositedNodes), isTrue);
    expect(identical(graph.edges, autoDepositedEdges), isTrue);
    graph.dispose();
  });

  test('new library notes preserve every existing absolute graph position', () {
    final library = _depositedLibrary();
    final graph = FeedGraphController(library);
    final before = <String, Offset>{
      for (final node in graph.nodes.where((node) => !node.center))
        node.id: graph.positionFor(node.id),
    };

    library.upsertProcessedTranscription(
      id: 'incremental-graph-note',
      title: '增量入库笔记',
      rawBody: '新增一条记录时，旧节点不应重新洗牌。',
      outlineBody: '只增加一个外围节点。',
    );

    expect(graph.nodes, hasLength(before.length + 2));
    expect(library.noteForId('incremental-graph-note'), isNotNull);
    expect(graph.nodeForId('incremental-graph-note'), isNotNull);
    final autoDepositRevision = graph.layoutRevision;
    final autoDepositedNodes = graph.nodes;
    library.depositContent('incremental-graph-note');
    expect(graph.nodes, hasLength(before.length + 2));
    expect(graph.layoutRevision, autoDepositRevision);
    expect(identical(graph.nodes, autoDepositedNodes), isTrue);
    expect(graph.nodeForId('incremental-graph-note'), isNotNull);
    expect(graph.positionFor('incremental-graph-note'), isNot(Offset.zero));
    for (final entry in before.entries) {
      expect(graph.positionFor(entry.key), entry.value, reason: entry.key);
    }
    graph.dispose();
  });

  test('rapid graph search evaluates only the final debounced query', () async {
    final library = _depositedLibrary();
    final graph = FeedGraphController(
      library,
      searchDebounce: const Duration(milliseconds: 20),
    );
    var notifications = 0;
    graph.addListener(() => notifications++);

    graph
      ..setSearchQuery('睡')
      ..setSearchQuery('睡眠改')
      ..setSearchQuery('睡眠');

    expect(graph.searchQuery, '睡眠');
    expect(graph.appliedSearchQuery, isEmpty);
    expect(graph.searchResults, isEmpty);
    expect(notifications, 0);

    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(graph.appliedSearchQuery, '睡眠');
    expect(
      graph.searchResults.map((node) => node.id),
      contains(graphTestSearchNoteId),
    );
    expect(notifications, 1);
    graph.dispose();
  });

  test('production constructor consumes only the graph read model', () {
    final library = _depositedLibrary();
    final graph = FeedGraphController.fromReadModel(library.graphReadModel);
    final before = graph.graphRevision;

    library.upsertProcessedTranscription(
      id: 'read-model-transcript',
      title: 'Read model transcript',
      rawBody: 'A deposited command updates the graph read model.',
      outlineBody: 'Graph query state remains isolated.',
    );

    expect(graph.graphRevision, greaterThan(before));
    expect(graph.nodeForId('read-model-transcript'), isNotNull);
    graph.dispose();
  });

  test('empty local graph follows authoritative source lifecycle', () async {
    final source = KnowledgeGraphReadModel(
      const <V3FeedItem>[],
      sourceState: KnowledgeGraphSourceState.loading,
    );
    final reload = Completer<bool>();
    var reloadCount = 0;
    final graph = FeedGraphController.fromReadModel(
      source,
      sourceReload: () {
        reloadCount += 1;
        source.replaceDepositedNotes(
          const <V3FeedItem>[],
          sourceState: KnowledgeGraphSourceState.loading,
        );
        return reload.future;
      },
    );
    addTearDown(graph.dispose);
    addTearDown(source.dispose);
    final topologyRevision = graph.graphRevision;

    expect(graph.loadingState, GraphLoadingState.loading);

    source.replaceDepositedNotes(
      const <V3FeedItem>[],
      sourceState: KnowledgeGraphSourceState.failure,
      sourceErrorCode: 'WORKSPACE_CONTENT_SYNC_FAILED',
    );

    expect(graph.loadingState, GraphLoadingState.failure);
    expect(graph.graphErrorCode, 'WORKSPACE_CONTENT_SYNC_FAILED');
    expect(graph.graphRevision, topologyRevision);

    final retry = graph.retryGraphLoad();
    expect(reloadCount, 1);
    expect(graph.loadingState, GraphLoadingState.loading);

    source.replaceDepositedNotes(
      const <V3FeedItem>[],
      sourceState: KnowledgeGraphSourceState.ready,
    );
    reload.complete(true);
    await retry;

    expect(graph.loadingState, GraphLoadingState.empty);
    expect(graph.graphErrorCode, isNull);
    expect(graph.graphRevision, topologyRevision);
  });

  test('cached graph keeps its topology while refresh failure is visible', () {
    final cachedNote = V3FeedItem(
      id: 'cached-note',
      title: '缓存笔记',
      source: V3MaterialSource.note,
      createdAt: DateTime.utc(2026, 8, 31),
      rawBody: '上次同步成功的内容。',
    );
    final source = KnowledgeGraphReadModel(<V3FeedItem>[
      cachedNote,
    ], sourceState: KnowledgeGraphSourceState.ready);
    final graph = FeedGraphController.fromReadModel(source);
    addTearDown(graph.dispose);
    addTearDown(source.dispose);
    final topologyRevision = graph.graphRevision;

    source.replaceDepositedNotes(
      <V3FeedItem>[cachedNote],
      sourceState: KnowledgeGraphSourceState.failure,
      sourceErrorCode: 'WORKSPACE_CONTENT_SYNC_FAILED',
    );

    expect(graph.loadingState, GraphLoadingState.failure);
    expect(graph.graphErrorCode, 'WORKSPACE_CONTENT_SYNC_FAILED');
    expect(graph.nodeForId(cachedNote.id), isNotNull);
    expect(graph.graphRevision, topologyRevision);
  });
}

KnowledgeLibraryController _depositedLibrary({
  Iterable<V3FeedItem>? initialNotes,
}) {
  final library = KnowledgeLibraryController(
    initialNotes: initialNotes ?? buildGraphTestNotes(),
  );
  for (final note in library.notes.where((note) => !note.isHotspot)) {
    library.depositContent(note.id);
  }
  return library;
}
