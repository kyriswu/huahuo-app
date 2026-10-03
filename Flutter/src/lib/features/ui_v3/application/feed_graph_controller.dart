import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/ui_v3_mock_data.dart';
import '../data/graph_repository.dart';
import '../domain/feed_item_models.dart';
import '../domain/graph_snapshot.dart';
import '../domain/ui_v3_models.dart';
import 'knowledge_library_controller.dart';

final feedGraphControllerProvider =
    ChangeNotifierProvider.autoDispose<FeedGraphController>((ref) {
      final library = ref.watch(knowledgeLibraryControllerProvider.notifier);
      final controller = FeedGraphController.fromReadModel(
        library.graphReadModel,
        repository: ref.watch(graphRepositoryProvider),
        remoteGraphId: ref.watch(graphIdProvider),
        sourceReload: () =>
            library.synchronizeWorkspaceContent(forceSnapshot: true),
        searchDebounce: const Duration(milliseconds: 200),
      );
      return controller;
    });

enum FeedGraphDataSource { localDepositedAssets, remoteSnapshot }

final class FeedGraphController extends ChangeNotifier {
  static const _maximumFirstDegreeFocus = 12;
  static const _maximumSecondDegreeFocus = 18;

  FeedGraphController(
    KnowledgeLibraryController library, {
    DateTime Function()? now,
    GraphRepository? repository,
    String? remoteGraphId,
    Future<bool> Function()? sourceReload,
    Duration searchDebounce = Duration.zero,
  }) : this.fromReadModel(
         library.graphReadModel,
         now: now,
         repository: repository,
         remoteGraphId: remoteGraphId,
         sourceReload: sourceReload,
         searchDebounce: searchDebounce,
       );

  FeedGraphController.fromReadModel(
    this._graphReadModel, {
    DateTime Function()? now,
    this._repository,
    String? remoteGraphId,
    Future<bool> Function()? sourceReload,
    Duration searchDebounce = Duration.zero,
  }) : assert(!searchDebounce.isNegative),
       _now = now ?? DateTime.now,
       _remoteGraphId = _normalizedOptional(remoteGraphId),
       // ignore: prefer_initializing_formals
       _sourceReload = sourceReload,
       // ignore: prefer_initializing_formals
       _searchDebounce = searchDebounce {
    _graphReadModel.addListener(_handleLibraryChanged);
    _rebuildGraphSnapshot();
    if (canRefreshRemote) _loadingState = GraphLoadingState.loading;
  }

  final KnowledgeGraphReadModel _graphReadModel;
  final DateTime Function() _now;
  final GraphRepository? _repository;
  final String? _remoteGraphId;
  final Future<bool> Function()? _sourceReload;
  final Duration _searchDebounce;
  V3GraphCluster? _focusedCluster;
  String? _selectedNodeId;
  String? _selectedEdgeId;
  bool _showEdgeLabels = true;
  bool _showLegend = false;
  GraphLoadingState _loadingState = GraphLoadingState.idle;
  GraphSnapshot? _snapshot;
  String? _graphErrorCode;
  bool _isRefreshing = false;
  bool _usingRemoteSnapshot = false;
  bool _disposed = false;
  bool _remoteLoadAttempted = false;
  Future<void>? _refreshInFlight;
  int _loadGeneration = 0;
  int _graphRevision = 0;
  V3GraphFilter _activeFilter = V3GraphFilter.all;
  int _filterApplicationRevision = 0;
  final Set<String> _selectedEntityTypes = <String>{};
  bool _searchOpen = false;
  String _searchQuery = '';
  String _appliedSearchQuery = '';
  Timer? _searchDebounceTimer;
  final Set<String> _manuallyPositioned = <String>{};
  final Map<String, Offset> _positions = <String, Offset>{
    for (final node in v3GraphNodes) node.id: node.position,
  };
  List<V3GraphNode> _nodes = const <V3GraphNode>[];
  Map<String, V3GraphNode> _nodesById = const <String, V3GraphNode>{};
  Map<String, int> _nodeIndexById = const <String, int>{};
  List<V3GraphEdge> _semanticEdges = const <V3GraphEdge>[];
  List<V3GraphEdge> _layoutEdges = const <V3GraphEdge>[];
  List<V3GraphCommunitySnapshot> _communities =
      const <V3GraphCommunitySnapshot>[];
  Map<String, V3GraphNodeRole> _nodeRoles = const <String, V3GraphNodeRole>{};
  Map<String, Map<String, double>> _adjacencyWeights =
      const <String, Map<String, double>>{};
  Set<String> _firstDegreeNodeIds = const <String>{};
  Set<String> _secondDegreeNodeIds = const <String>{};
  Set<String> _focusedNodeIds = const <String>{};
  List<V3GraphNode> _searchResults = const <V3GraphNode>[];
  Set<String> _searchMatchNodeIds = const <String>{};
  DateTime? _nextRecencyExpiry;
  int _layoutRevision = 0;
  List<V3FeedItem> _localGraphNotes = const <V3FeedItem>[];

  V3GraphCluster? get focusedCluster => _focusedCluster;
  String? get selectedNodeId => _selectedNodeId;
  String? get selectedEdgeId => _selectedEdgeId;
  bool get hasLocalFocus => _selectedNodeId != null || _selectedEdgeId != null;
  bool get showEdgeLabels => _showEdgeLabels;
  bool get showLegend => _showLegend;
  GraphLoadingState get loadingState => _loadingState;
  GraphSnapshot? get snapshot => _snapshot;
  String? get graphErrorCode => _graphErrorCode;
  String? get errorMessage => _graphErrorCode;
  bool get isRefreshing => _isRefreshing;
  bool get canRefreshRemote => _repository != null && _remoteGraphId != null;
  FeedGraphDataSource get dataSource => _usingRemoteSnapshot
      ? FeedGraphDataSource.remoteSnapshot
      : FeedGraphDataSource.localDepositedAssets;
  bool get usingRemoteSnapshot =>
      dataSource == FeedGraphDataSource.remoteSnapshot;
  int get graphRevision => _graphRevision;
  V3GraphFilter get activeFilter => _activeFilter;
  V3GraphFilter get filter => _activeFilter;
  int get filterApplicationRevision => _filterApplicationRevision;
  Set<String> get selectedEntityTypes =>
      Set<String>.unmodifiable(_selectedEntityTypes);
  bool get searchOpen => _searchOpen;
  String get searchQuery => _searchQuery;
  String get appliedSearchQuery => _appliedSearchQuery;
  bool hasManualPosition(String id) => _manuallyPositioned.contains(id);
  int get layoutRevision => _layoutRevision;
  List<V3GraphNode> get nodes {
    _refreshRecencyIfExpired();
    return _nodes;
  }

  List<V3GraphEdge> get semanticEdges => _semanticEdges;
  List<V3GraphEdge> get layoutEdges => _layoutEdges;
  List<V3GraphEdge> get edges => _semanticEdges;
  List<V3GraphEdge> get overviewEdges => _semanticEdges;
  List<V3GraphCommunitySnapshot> get communities => _communities;
  V3GraphNodeRole roleForNode(String nodeId) =>
      _nodeRoles[nodeId] ?? V3GraphNodeRole.satellite;
  V3GraphCommunity? communityForNode(String nodeId) =>
      _nodesById[nodeId]?.cluster.community;
  Set<String> get firstDegreeNodeIds => _firstDegreeNodeIds;
  Set<String> get secondDegreeNodeIds => _secondDegreeNodeIds;

  List<V3GraphEdge> get focusedEdges {
    return _semanticEdges;
  }

  Set<String> get focusedNodeIds => _focusedNodeIds;
  List<V3GraphNode> get searchResults => _searchResults;

  int get searchMatchCount => _searchResults.length;

  Offset positionFor(String id) => _positions[id] ?? Offset.zero;
  V3GraphNode? nodeForId(String id) => _nodesById[id];
  V3GraphEdge? edgeForId(String id) {
    for (final edge in _semanticEdges) {
      if (edge.id == id) return edge;
    }
    return null;
  }

  void resetView() {
    final changed =
        _focusedCluster != null ||
        _selectedNodeId != null ||
        _selectedEdgeId != null ||
        _activeFilter != V3GraphFilter.all ||
        _selectedEntityTypes.isNotEmpty ||
        _searchOpen ||
        _searchQuery.isNotEmpty;
    if (!changed) return;
    _focusedCluster = null;
    _selectedNodeId = null;
    _selectedEdgeId = null;
    _activeFilter = V3GraphFilter.all;
    _selectedEntityTypes.clear();
    _searchOpen = false;
    _searchQuery = '';
    _appliedSearchQuery = '';
    _searchDebounceTimer?.cancel();
    _rebuildFocusCache();
    _rebuildSearchCache();
    notifyListeners();
  }

  void focusCluster(V3GraphCluster cluster) {
    _focusedCluster = _focusedCluster == cluster ? null : cluster;
    notifyListeners();
  }

  void selectNode(String? id) {
    final next = id == null || id == _centerNode.id
        ? null
        : _nodesById[id]?.center == false
        ? id
        : null;
    final edgeWasSelected = _selectedEdgeId != null;
    if (_selectedNodeId == next && !edgeWasSelected) return;
    _selectedNodeId = next;
    _selectedEdgeId = null;
    _rebuildFocusCache();
    notifyListeners();
  }

  void selectEdge(String? id) {
    final next = id != null && _semanticEdges.any((edge) => edge.id == id)
        ? id
        : null;
    final nodeWasSelected = _selectedNodeId != null;
    if (_selectedEdgeId == next && !nodeWasSelected) return;
    _selectedEdgeId = next;
    _selectedNodeId = null;
    _rebuildFocusCache();
    notifyListeners();
  }

  void clearSelection() {
    if (_selectedNodeId == null && _selectedEdgeId == null) return;
    _selectedNodeId = null;
    _selectedEdgeId = null;
    _rebuildFocusCache();
    notifyListeners();
  }

  void toggleEdgeLabels() {
    _showEdgeLabels = !_showEdgeLabels;
    notifyListeners();
  }

  void setShowEdgeLabels(bool value) {
    if (_showEdgeLabels == value) return;
    _showEdgeLabels = value;
    notifyListeners();
  }

  void toggleLegend() {
    _showLegend = !_showLegend;
    notifyListeners();
  }

  void setShowLegend(bool value) {
    if (_showLegend == value) return;
    _showLegend = value;
    notifyListeners();
  }

  void setGraphBuilding(bool value) {
    if (value) {
      if (_loadingState == GraphLoadingState.building) return;
      _loadingState = GraphLoadingState.building;
    } else if (!_applyLocalSourcePresentation(_graphReadModel.notes)) {
      return;
    }
    notifyListeners();
  }

  Future<void> refresh() => refreshGraph();

  Future<void> retryGraphLoad() => refreshGraph();

  Future<void> ensureRemoteGraphLoaded() {
    if (_disposed || !canRefreshRemote) {
      return Future<void>.value();
    }
    final active = _refreshInFlight;
    if (active != null) return active;
    if (_remoteLoadAttempted) return Future<void>.value();
    return refreshGraph();
  }

  Future<void> refreshGraph() {
    if (_disposed) return Future<void>.value();
    _remoteLoadAttempted = true;
    final active = _refreshInFlight;
    if (active != null) return active;
    late final Future<void> operation;
    operation = _refreshGraphOnce().whenComplete(() {
      if (identical(_refreshInFlight, operation)) {
        _refreshInFlight = null;
      }
    });
    _refreshInFlight = operation;
    return operation;
  }

  Future<void> _refreshGraphOnce() async {
    final repository = _repository;
    final graphId = _remoteGraphId;
    if (repository == null || graphId == null) {
      _usingRemoteSnapshot = false;
      _graphErrorCode = null;
      final reload = _sourceReload;
      if (reload != null) {
        _isRefreshing = _graphReadModel.notes.isNotEmpty;
        if (!_isRefreshing) _loadingState = GraphLoadingState.loading;
        notifyListeners();
        try {
          await reload();
        } on Object {
          if (_disposed) return;
          _isRefreshing = false;
          _loadingState = GraphLoadingState.failure;
          _graphErrorCode = 'WORKSPACE_CONTENT_SYNC_FAILED';
          notifyListeners();
          return;
        }
        if (_disposed) return;
      }
      if (!_sameLocalGraphNotes(_graphReadModel.notes)) {
        _rebuildGraphSnapshot();
      } else {
        _applyLocalSourcePresentation(_graphReadModel.notes);
      }
      notifyListeners();
      return;
    }

    final generation = ++_loadGeneration;
    _isRefreshing = true;
    _graphErrorCode = null;
    _loadingState = !_usingRemoteSnapshot
        ? GraphLoadingState.loading
        : _nodes.where((node) => !node.center).isEmpty
        ? GraphLoadingState.empty
        : GraphLoadingState.ready;
    notifyListeners();
    try {
      final next = await repository.loadGraph(graphId: graphId);
      if (_disposed || generation != _loadGeneration) return;
      final current = _snapshot;
      if (_usingRemoteSnapshot &&
          current != null &&
          next.graphId == current.graphId &&
          current.revision > 0 &&
          next.revision > 0 &&
          next.revision <= current.revision) {
        return;
      }
      _usingRemoteSnapshot = true;
      _applyRemoteSnapshot(next);
    } on GraphRepositoryException catch (error) {
      if (_disposed || generation != _loadGeneration) return;
      _graphErrorCode = error.code;
      _loadingState = GraphLoadingState.failure;
    } catch (_) {
      if (_disposed || generation != _loadGeneration) return;
      _graphErrorCode = 'GRAPH_SNAPSHOT_LOAD_FAILED';
      _loadingState = GraphLoadingState.failure;
    } finally {
      if (!_disposed && generation == _loadGeneration) {
        _isRefreshing = false;
        notifyListeners();
      }
    }
  }

  void setFilter(V3GraphFilter value) {
    if (_activeFilter == value) return;
    _activeFilter = value;
    notifyListeners();
  }

  void applyFilter(V3GraphFilter value) {
    _activeFilter = value;
    _filterApplicationRevision++;
    notifyListeners();
  }

  void toggleEntityTypeFilter(String entityType) {
    final normalized = entityType.trim();
    if (normalized.isEmpty) return;
    if (!_selectedEntityTypes.remove(normalized)) {
      _selectedEntityTypes.add(normalized);
    }
    notifyListeners();
  }

  void clearEntityTypeFilters() {
    if (_selectedEntityTypes.isEmpty) return;
    _selectedEntityTypes.clear();
    notifyListeners();
  }

  bool nodeMatchesEntityType(V3GraphNode node) =>
      node.center ||
      _selectedEntityTypes.isEmpty ||
      _selectedEntityTypes.contains(node.entityType);

  bool nodeMatchesFilter(V3GraphNode node) {
    if (node.center || _activeFilter == V3GraphFilter.all) return true;
    if (!node.materialSourceProvided) return false;
    return switch (_activeFilter) {
      V3GraphFilter.all => true,
      V3GraphFilter.audio => switch (node.source) {
        V3MaterialSource.meeting ||
        V3MaterialSource.internalRecording ||
        V3MaterialSource.monologue ||
        V3MaterialSource.recordingCard => true,
        _ => false,
      },
      V3GraphFilter.note => switch (node.source) {
        V3MaterialSource.note ||
        V3MaterialSource.chatExcerpt ||
        V3MaterialSource.topicCollision => true,
        _ => false,
      },
      V3GraphFilter.external => switch (node.source) {
        V3MaterialSource.link ||
        V3MaterialSource.documentImport ||
        V3MaterialSource.mediaImport ||
        V3MaterialSource.materialMigration ||
        V3MaterialSource.subscription ||
        V3MaterialSource.knowledgeSquare => true,
        _ => false,
      },
      V3GraphFilter.hotspot => node.isHotspot,
      V3GraphFilter.aggregated => node.isAggregated,
      V3GraphFilter.recent => _isRecentAt(node.updatedAt, _now()),
    };
  }

  void toggleSearch() {
    _searchOpen = !_searchOpen;
    if (!_searchOpen) {
      _searchDebounceTimer?.cancel();
      _searchQuery = '';
      _appliedSearchQuery = '';
      _rebuildSearchCache();
    }
    notifyListeners();
  }

  void closeSearch() {
    if (!_searchOpen && _searchQuery.isEmpty && _appliedSearchQuery.isEmpty) {
      return;
    }
    _searchDebounceTimer?.cancel();
    _searchOpen = false;
    _searchQuery = '';
    _appliedSearchQuery = '';
    _rebuildSearchCache();
    notifyListeners();
  }

  void clearSearch() {
    if (_searchQuery.isEmpty && _appliedSearchQuery.isEmpty) return;
    _searchDebounceTimer?.cancel();
    _searchQuery = '';
    _appliedSearchQuery = '';
    _rebuildSearchCache();
    notifyListeners();
  }

  void setSearchQuery(String value) {
    if (_searchQuery == value) return;
    _searchQuery = value;
    _searchDebounceTimer?.cancel();
    if (_normalized(value).isEmpty || _searchDebounce <= Duration.zero) {
      _applyPendingSearchQuery();
      notifyListeners();
      return;
    }
    _searchDebounceTimer = Timer(_searchDebounce, () {
      if (_disposed) return;
      _applyPendingSearchQuery();
      notifyListeners();
    });
  }

  bool matchesSearch(V3GraphNode node) {
    return _appliedSearchQuery.trim().isEmpty ||
        _searchMatchNodeIds.contains(node.id);
  }

  void moveNode(String id, Offset delta) {
    setNodePosition(id, positionFor(id) + delta);
  }

  void beginNodeDrag(String id, Offset renderedLogicalPosition) {
    setNodePosition(id, renderedLogicalPosition);
  }

  void setNodePosition(String id, Offset position) {
    final node = _nodesById[id];
    if (node == null || node.center) return;
    final next = Offset(
      position.dx.clamp(20, 880).toDouble(),
      position.dy.clamp(20, 840).toDouble(),
    );
    final positionChanged = _positions[id] != next;
    final becameManual = !_manuallyPositioned.contains(id);
    if (!positionChanged && !becameManual) return;
    _positions[id] = next;
    _manuallyPositioned.add(id);
    if (positionChanged) {
      _replaceCachedNodePosition(id, next);
    } else {
      _layoutRevision++;
    }
    notifyListeners();
  }

  void _handleLibraryChanged() {
    if (_usingRemoteSnapshot) return;
    final next = _graphReadModel.notes;
    if (_sameLocalGraphNotes(next)) {
      if (!_applyLocalSourcePresentation(next)) return;
    } else {
      _rebuildGraphSnapshot();
    }
    notifyListeners();
  }

  void _rebuildGraphSnapshot() {
    final notes = _graphReadModel.notes;
    _localGraphNotes = List<V3FeedItem>.unmodifiable(notes);
    final snapshotNow = _now();
    _syncPositions(notes);
    final preliminaryNodes = <V3GraphNode>[
      _centerNode,
      for (final note in notes)
        _nodeForNote(note, relationshipCount: 0, snapshotNow: snapshotNow),
    ];
    final preliminaryNodesById = <String, V3GraphNode>{
      for (final node in preliminaryNodes) node.id: node,
    };
    final naturalEdges = _deriveNaturalEdges(notes, preliminaryNodesById);
    final nextCommunities = _deriveCommunities(
      preliminaryNodes.where((node) => !node.center),
      naturalEdges,
    );
    final nextEdges = _deriveEdges(notes, nextCommunities, naturalEdges);
    final degree = <String, int>{};
    for (final edge in nextEdges) {
      degree.update(edge.sourceId, (value) => value + 1, ifAbsent: () => 1);
      degree.update(edge.targetId, (value) => value + 1, ifAbsent: () => 1);
    }
    final nextNodes = <V3GraphNode>[
      _centerNode,
      for (final note in notes)
        _nodeForNote(
          note,
          relationshipCount: degree[note.id] ?? 0,
          snapshotNow: snapshotNow,
        ),
    ];
    _nodes = List<V3GraphNode>.unmodifiable(nextNodes);
    _nodesById = Map<String, V3GraphNode>.unmodifiable(<String, V3GraphNode>{
      for (final node in nextNodes) node.id: node,
    });
    _retainAvailableEntityTypes(nextNodes);
    _nodeIndexById = Map<String, int>.unmodifiable(<String, int>{
      for (var index = 0; index < nextNodes.length; index++)
        nextNodes[index].id: index,
    });
    _semanticEdges = List<V3GraphEdge>.unmodifiable(nextEdges);
    _layoutEdges = buildGraphLayoutEdges(
      nextEdges,
      nodeIds: nextNodes.map((node) => node.id).toSet(),
    );
    _communities = List<V3GraphCommunitySnapshot>.unmodifiable(nextCommunities);
    _nodeRoles =
        Map<String, V3GraphNodeRole>.unmodifiable(<String, V3GraphNodeRole>{
          _centerNode.id: V3GraphNodeRole.center,
          for (final community in nextCommunities)
            for (final nodeId in community.memberNodeIds)
              nodeId: nodeId == community.coreNodeId
                  ? V3GraphNodeRole.core
                  : V3GraphNodeRole.satellite,
        });
    _adjacencyWeights = _buildAdjacencyWeights(nextEdges);
    if (_selectedNodeId != null && !_nodesById.containsKey(_selectedNodeId)) {
      _selectedNodeId = null;
    }
    if (_selectedEdgeId != null &&
        !_semanticEdges.any((edge) => edge.id == _selectedEdgeId)) {
      _selectedEdgeId = null;
    }
    _graphRevision++;
    _snapshot = GraphSnapshot(
      graphId: 'local-deposited-assets',
      nodes: nextNodes,
      edges: nextEdges,
      revision: _graphRevision,
      updatedAt: snapshotNow.toUtc(),
    );
    _applyLocalSourcePresentation(notes);
    _layoutRevision++;
    _rebuildFocusCache();
    _rebuildSearchCache();
    _updateRecencyDeadline(notes, snapshotNow);
  }

  bool _applyLocalSourcePresentation(List<V3FeedItem> notes) {
    final nextState = switch (_graphReadModel.sourceState) {
      KnowledgeGraphSourceState.failure => GraphLoadingState.failure,
      KnowledgeGraphSourceState.loading when notes.isEmpty =>
        GraphLoadingState.loading,
      _ when notes.isEmpty => GraphLoadingState.empty,
      _ => GraphLoadingState.ready,
    };
    final nextErrorCode = nextState == GraphLoadingState.failure
        ? _graphReadModel.sourceErrorCode ?? 'WORKSPACE_CONTENT_SYNC_FAILED'
        : null;
    final nextRefreshing =
        notes.isNotEmpty &&
        _graphReadModel.sourceState == KnowledgeGraphSourceState.loading;
    if (_loadingState == nextState &&
        _graphErrorCode == nextErrorCode &&
        _isRefreshing == nextRefreshing) {
      return false;
    }
    _loadingState = nextState;
    _graphErrorCode = nextErrorCode;
    _isRefreshing = nextRefreshing;
    return true;
  }

  bool _sameLocalGraphNotes(List<V3FeedItem> next) {
    if (_localGraphNotes.length != next.length) return false;
    for (var index = 0; index < next.length; index++) {
      if (!identical(_localGraphNotes[index], next[index])) return false;
    }
    return true;
  }

  void _applyRemoteSnapshot(GraphSnapshot snapshot) {
    final nextNodes = <V3GraphNode>[
      for (final node in snapshot.nodes)
        _copyNodeWithPosition(
          node,
          _manuallyPositioned.contains(node.id)
              ? (_positions[node.id] ?? node.position)
              : node.position,
        ),
    ];
    final nodeIds = nextNodes.map((node) => node.id).toSet();
    final nextEdges =
        snapshot.edges
            .where(
              (edge) =>
                  nodeIds.contains(edge.sourceId) &&
                  nodeIds.contains(edge.targetId),
            )
            .toList()
          ..sort(_compareEdgeIdentity);
    _positions
      ..removeWhere((id, _) => !nodeIds.contains(id))
      ..addAll(<String, Offset>{
        for (final node in nextNodes) node.id: node.position,
      });
    _manuallyPositioned.removeWhere((id) => !nodeIds.contains(id));
    final communities = _deriveCommunities(
      nextNodes.where((node) => !node.center),
      nextEdges,
    );
    _nodes = List<V3GraphNode>.unmodifiable(nextNodes);
    _nodesById = Map<String, V3GraphNode>.unmodifiable(<String, V3GraphNode>{
      for (final node in nextNodes) node.id: node,
    });
    _retainAvailableEntityTypes(nextNodes);
    _nodeIndexById = Map<String, int>.unmodifiable(<String, int>{
      for (var index = 0; index < nextNodes.length; index++)
        nextNodes[index].id: index,
    });
    _semanticEdges = List<V3GraphEdge>.unmodifiable(nextEdges);
    _layoutEdges = buildGraphLayoutEdges(nextEdges, nodeIds: nodeIds);
    _communities = List<V3GraphCommunitySnapshot>.unmodifiable(communities);
    _nodeRoles =
        Map<String, V3GraphNodeRole>.unmodifiable(<String, V3GraphNodeRole>{
          for (final node in nextNodes)
            if (node.center) node.id: V3GraphNodeRole.center,
          for (final community in communities)
            for (final nodeId in community.memberNodeIds)
              nodeId: nodeId == community.coreNodeId
                  ? V3GraphNodeRole.core
                  : V3GraphNodeRole.satellite,
        });
    _adjacencyWeights = _buildAdjacencyWeights(nextEdges);
    if (_selectedNodeId != null && !_nodesById.containsKey(_selectedNodeId)) {
      _selectedNodeId = null;
    }
    if (_selectedEdgeId != null &&
        !_semanticEdges.any((edge) => edge.id == _selectedEdgeId)) {
      _selectedEdgeId = null;
    }
    _graphRevision++;
    _snapshot = GraphSnapshot(
      graphId: snapshot.graphId,
      nodes: nextNodes,
      edges: nextEdges,
      revision: snapshot.revision,
      updatedAt: snapshot.updatedAt,
    );
    _loadingState = nextNodes.isEmpty
        ? GraphLoadingState.empty
        : GraphLoadingState.ready;
    _graphErrorCode = null;
    _layoutRevision++;
    _rebuildFocusCache();
    _rebuildSearchCache();
    _nextRecencyExpiry = null;
  }

  void _refreshRecencyIfExpired() {
    final expiry = _nextRecencyExpiry;
    if (expiry == null || !_now().isAfter(expiry)) return;
    _rebuildGraphSnapshot();
  }

  void _updateRecencyDeadline(List<V3FeedItem> notes, DateTime snapshotNow) {
    DateTime? nextExpiry;
    for (final note in notes) {
      final expiry = note.updatedAt.add(const Duration(days: 7));
      if (snapshotNow.isAfter(expiry)) continue;
      if (nextExpiry == null || expiry.isBefore(nextExpiry)) {
        nextExpiry = expiry;
      }
    }
    _nextRecencyExpiry = nextExpiry;
  }

  void _replaceCachedNodePosition(String id, Offset position) {
    final current = _nodesById[id];
    final index = _nodeIndexById[id];
    if (current == null || index == null || current.position == position) {
      return;
    }
    final replacement = _copyNodeWithPosition(current, position);
    final nextNodes = List<V3GraphNode>.of(_nodes)..[index] = replacement;
    _nodes = List<V3GraphNode>.unmodifiable(nextNodes);
    _nodesById = Map<String, V3GraphNode>.unmodifiable(<String, V3GraphNode>{
      ..._nodesById,
      id: replacement,
    });
    final searchIndex = _searchResults.indexWhere((node) => node.id == id);
    if (searchIndex != -1) {
      final nextSearchResults = List<V3GraphNode>.of(_searchResults)
        ..[searchIndex] = replacement;
      _searchResults = List<V3GraphNode>.unmodifiable(nextSearchResults);
    }
    _layoutRevision++;
  }

  void _rebuildFocusCache() {
    final selected = _selectedNodeId;
    if (selected == null) {
      _firstDegreeNodeIds = const <String>{};
      _secondDegreeNodeIds = const <String>{};
      _focusedNodeIds = const <String>{};
      return;
    }
    final rankedFirst = _rankedNeighborIds(selected);
    final first = <String>[
      if (rankedFirst.contains(_centerNode.id)) _centerNode.id,
      ...rankedFirst
          .where((id) => id != _centerNode.id)
          .take(
            _maximumFirstDegreeFocus -
                (rankedFirst.contains(_centerNode.id) ? 1 : 0),
          ),
    ];
    _firstDegreeNodeIds = Set<String>.unmodifiable(first);
    final scores = <String, double>{};
    for (final firstId in first) {
      if (firstId == _centerNode.id) continue;
      for (final entry
          in (_adjacencyWeights[firstId] ?? const <String, double>{}).entries) {
        final candidate = entry.key;
        if (candidate == selected || _firstDegreeNodeIds.contains(candidate)) {
          continue;
        }
        final score = entry.value * .8;
        if (score > (scores[candidate] ?? -1)) scores[candidate] = score;
      }
    }
    final rankedSecond = scores.keys.toList()
      ..sort((left, right) => _compareRankedNodeIds(left, right, scores));
    final second = rankedSecond.take(_maximumSecondDegreeFocus).toList();
    _secondDegreeNodeIds = Set<String>.unmodifiable(second);
    _focusedNodeIds = Set<String>.unmodifiable(<String>{
      selected,
      ..._firstDegreeNodeIds,
      ..._secondDegreeNodeIds,
    });
  }

  void _rebuildSearchCache() {
    final query = _normalized(_appliedSearchQuery);
    if (query.isEmpty) {
      _searchResults = const <V3GraphNode>[];
      _searchMatchNodeIds = const <String>{};
      return;
    }
    final result = _nodes
        .where((node) => !node.center && _searchScore(node, query) > 0)
        .toList();
    result.sort((left, right) {
      final score = _searchScore(
        right,
        query,
      ).compareTo(_searchScore(left, query));
      if (score != 0) return score;
      final updated = (right.updatedAt?.millisecondsSinceEpoch ?? 0).compareTo(
        left.updatedAt?.millisecondsSinceEpoch ?? 0,
      );
      if (updated != 0) return updated;
      return left.id.compareTo(right.id);
    });
    _searchResults = List<V3GraphNode>.unmodifiable(result);
    _searchMatchNodeIds = Set<String>.unmodifiable(
      result.map((node) => node.id),
    );
  }

  void _applyPendingSearchQuery() {
    _searchDebounceTimer = null;
    _appliedSearchQuery = _searchQuery;
    _rebuildSearchCache();
  }

  Map<String, Map<String, double>> _buildAdjacencyWeights(
    List<V3GraphEdge> edges,
  ) {
    final mutable = <String, Map<String, double>>{};
    for (final edge in edges) {
      if (edge.isSelfLoop) continue;
      void add(String source, String target) {
        final weights = mutable.putIfAbsent(source, () => <String, double>{});
        if (edge.weight > (weights[target] ?? -1)) {
          weights[target] = edge.weight;
        }
      }

      add(edge.sourceId, edge.targetId);
      add(edge.targetId, edge.sourceId);
    }
    return Map<String, Map<String, double>>.unmodifiable(
      <String, Map<String, double>>{
        for (final entry in mutable.entries)
          entry.key: Map<String, double>.unmodifiable(entry.value),
      },
    );
  }

  void _syncPositions(List<V3FeedItem> notes) {
    for (final note in notes) {
      _positions.putIfAbsent(note.id, () => _seedPositionFor(note.id));
    }
  }

  void _retainAvailableEntityTypes(Iterable<V3GraphNode> nodes) {
    final available = nodes
        .where((node) => !node.center)
        .map((node) => node.entityType)
        .toSet();
    _selectedEntityTypes.removeWhere((type) => !available.contains(type));
  }

  V3GraphNode get _centerNode => v3GraphNodes.firstWhere(
    (node) => node.center,
    orElse: () => const V3GraphNode(
      id: 'center',
      label: '内容大脑',
      cluster: V3GraphCluster.viewpoint,
      position: Offset(450, 430),
      summary: '记忆库中心',
      center: true,
    ),
  );

  V3GraphNode _nodeForNote(
    V3FeedItem note, {
    required int relationshipCount,
    required DateTime snapshotNow,
  }) {
    final seed = _seedNodeFor(note.id);
    final summary = note.summaryBody?.trim().isNotEmpty == true
        ? note.summaryBody!.trim()
        : note.rawBody.trim();
    final isRecent = _isRecentAt(note.updatedAt, snapshotNow);
    final isAggregated = note.id.startsWith('aggregation-');
    final cluster = seed?.cluster ?? _clusterForNote(note);
    final relationshipBoost = (relationshipCount * .04).clamp(0.0, .5);
    final stateBoost =
        (note.isHotspot ? .12 : 0) +
        (isAggregated ? .18 : 0) +
        (isRecent ? .08 : 0);
    final weight = ((seed?.weight ?? 1) + relationshipBoost + stateBoost)
        .clamp(.72, 1.8)
        .toDouble();
    return V3GraphNode(
      id: note.id,
      label: note.title,
      cluster: cluster,
      position: _positions[note.id] ?? _seedPositionFor(note.id),
      summary: summary,
      entityType: cluster.label,
      attributes: <String, Object?>{
        'source': note.source.name,
        'ownership': note.ownership.name,
      },
      labels: List<String>.unmodifiable(<String>[
        note.source.label,
        ...note.topics,
      ]),
      contentId: note.id,
      weight: weight,
      source: note.source,
      updatedAt: note.updatedAt,
      topics: List<String>.unmodifiable(note.topics),
      isHotspot: note.isHotspot,
      isAggregated: isAggregated,
      isRecent: isRecent,
    );
  }

  V3GraphNode? _seedNodeFor(String id) {
    for (final node in v3GraphNodes) {
      if (node.id == id && !node.center) return node;
    }
    return null;
  }

  List<V3GraphCommunitySnapshot> _deriveCommunities(
    Iterable<V3GraphNode> nodes,
    List<V3GraphEdge> naturalEdges,
  ) {
    final naturalDegree = <String, int>{};
    for (final edge in naturalEdges) {
      naturalDegree.update(
        edge.sourceId,
        (value) => value + 1,
        ifAbsent: () => 1,
      );
      naturalDegree.update(
        edge.targetId,
        (value) => value + 1,
        ifAbsent: () => 1,
      );
    }
    final groups = <V3GraphCommunity, List<V3GraphNode>>{
      for (final community in V3GraphCommunity.values)
        community: <V3GraphNode>[],
    };
    for (final node in nodes) {
      groups[node.cluster.community]!.add(node);
    }
    return <V3GraphCommunitySnapshot>[
      for (final community in V3GraphCommunity.values)
        () {
          final members = groups[community]!
            ..sort((left, right) {
              final degree = (naturalDegree[right.id] ?? 0).compareTo(
                naturalDegree[left.id] ?? 0,
              );
              if (degree != 0) return degree;
              final weight = right.weight.compareTo(left.weight);
              if (weight != 0) return weight;
              final updated = (right.updatedAt?.millisecondsSinceEpoch ?? 0)
                  .compareTo(left.updatedAt?.millisecondsSinceEpoch ?? 0);
              if (updated != 0) return updated;
              return left.id.compareTo(right.id);
            });
          final coreId = members.isEmpty ? '' : members.first.id;
          final memberIds = members.map((node) => node.id).toList()..sort();
          return V3GraphCommunitySnapshot(
            community: community,
            coreNodeId: coreId,
            memberNodeIds: List<String>.unmodifiable(memberIds),
          );
        }(),
    ];
  }

  List<V3GraphEdge> _deriveNaturalEdges(
    List<V3FeedItem> notes,
    Map<String, V3GraphNode> nodesById,
  ) {
    final candidates = <V3GraphEdge>[];
    final seenIds = <String>{};

    void add(V3GraphEdge edge) {
      if (seenIds.add(edge.id)) candidates.add(edge);
    }

    for (var leftIndex = 0; leftIndex < notes.length; leftIndex++) {
      final left = notes[leftIndex];
      if (!nodesById.containsKey(left.id)) continue;
      for (
        var rightIndex = leftIndex + 1;
        rightIndex < notes.length;
        rightIndex++
      ) {
        final right = notes[rightIndex];
        if (!nodesById.containsKey(right.id)) continue;
        final leftLinksRight = left.linkedMaterials.any(
          (ref) => ref.id == right.id,
        );
        final rightLinksLeft = right.linkedMaterials.any(
          (ref) => ref.id == left.id,
        );
        if (leftLinksRight) {
          add(
            V3GraphEdge(
              id: _localEdgeId(
                V3GraphRelationKind.linkedMaterial,
                left.id,
                right.id,
                'forward',
              ),
              sourceId: left.id,
              targetId: right.id,
              kind: V3GraphRelationKind.linkedMaterial,
              label: V3GraphRelationKind.linkedMaterial.label,
              fact: '${left.title} 引用了 ${right.title}',
              weight: .96,
              directed: true,
              createdAt: _laterDate(left.updatedAt, right.updatedAt),
            ),
          );
        }
        if (rightLinksLeft) {
          add(
            V3GraphEdge(
              id: _localEdgeId(
                V3GraphRelationKind.linkedMaterial,
                right.id,
                left.id,
                'forward',
              ),
              sourceId: right.id,
              targetId: left.id,
              kind: V3GraphRelationKind.linkedMaterial,
              label: V3GraphRelationKind.linkedMaterial.label,
              fact: '${right.title} 引用了 ${left.title}',
              weight: .96,
              directed: true,
              createdAt: _laterDate(left.updatedAt, right.updatedAt),
            ),
          );
        }
        final sameContentLine =
            left.contentLineId?.trim().isNotEmpty == true &&
            left.contentLineId == right.contentLineId;
        if (sameContentLine) {
          final contentLineId = left.contentLineId!.trim();
          add(
            V3GraphEdge(
              id: _localEdgeId(
                V3GraphRelationKind.sharedContentLine,
                left.id,
                right.id,
                contentLineId,
              ),
              sourceId: left.id,
              targetId: right.id,
              kind: V3GraphRelationKind.sharedContentLine,
              label: V3GraphRelationKind.sharedContentLine.label,
              fact: '同属内容线 ${left.contentLineName ?? contentLineId}',
              attributes: <String, Object?>{'contentLineId': contentLineId},
              weight: .84,
              createdAt: _laterDate(left.updatedAt, right.updatedAt),
            ),
          );
        }
        final leftTopics = <String, String>{
          for (final topic in left.topics)
            if (_normalized(topic).isNotEmpty) _normalized(topic): topic.trim(),
        };
        final rightTopics = <String>{
          for (final topic in right.topics)
            if (_normalized(topic).isNotEmpty) _normalized(topic),
        };
        final sharedTopics =
            leftTopics.keys.where(rightTopics.contains).toList()..sort();
        for (final normalizedTopic in sharedTopics) {
          final topic = leftTopics[normalizedTopic]!;
          add(
            V3GraphEdge(
              id: _localEdgeId(
                V3GraphRelationKind.sharedTopic,
                left.id,
                right.id,
                normalizedTopic,
              ),
              sourceId: left.id,
              targetId: right.id,
              kind: V3GraphRelationKind.sharedTopic,
              label: topic,
              fact: '共同主题：$topic',
              attributes: <String, Object?>{'topic': topic},
              weight: .66,
              createdAt: _laterDate(left.updatedAt, right.updatedAt),
            ),
          );
        }
      }
    }
    candidates.sort((left, right) {
      final weight = right.weight.compareTo(left.weight);
      if (weight != 0) return weight;
      return _compareEdgeIdentity(left, right);
    });
    return candidates;
  }

  List<V3GraphEdge> _deriveEdges(
    List<V3FeedItem> notes,
    List<V3GraphCommunitySnapshot> communities,
    List<V3GraphEdge> naturalEdges,
  ) {
    final centerId = _centerNode.id;
    final result = <V3GraphEdge>[
      for (final note in notes)
        V3GraphEdge(
          id: _localEdgeId(
            V3GraphRelationKind.membership,
            centerId,
            note.id,
            'knowledge',
          ),
          sourceId: centerId,
          targetId: note.id,
          kind: V3GraphRelationKind.membership,
          label: V3GraphRelationKind.membership.label,
          fact: '${note.title} 属于记忆库',
          weight: .24,
        ),
      for (final community in communities)
        if (community.coreNodeId.isNotEmpty)
          for (final nodeId in community.memberNodeIds)
            if (nodeId != community.coreNodeId)
              V3GraphEdge(
                id: _localEdgeId(
                  V3GraphRelationKind.communityAffinity,
                  community.coreNodeId,
                  nodeId,
                  community.community.name,
                ),
                sourceId: community.coreNodeId,
                targetId: nodeId,
                kind: V3GraphRelationKind.communityAffinity,
                label: V3GraphRelationKind.communityAffinity.label,
                attributes: <String, Object?>{
                  'community': community.community.name,
                },
                weight: .72,
              ),
      ...naturalEdges,
    ];
    final deduplicated = <String, V3GraphEdge>{};
    for (final edge in result) {
      deduplicated.putIfAbsent(edge.id, () => edge);
    }
    result
      ..clear()
      ..addAll(deduplicated.values);
    result.sort(_compareEdgeIdentity);
    return result;
  }

  List<String> _rankedNeighborIds(String nodeId) {
    final weights = _adjacencyWeights[nodeId] ?? const <String, double>{};
    final result = weights.keys.toList()
      ..sort((left, right) => _compareRankedNodeIds(left, right, weights));
    return result;
  }

  int _compareRankedNodeIds(
    String left,
    String right,
    Map<String, double> scores,
  ) {
    final score = (scores[right] ?? 0).compareTo(scores[left] ?? 0);
    if (score != 0) return score;
    final updated = (_nodesById[right]?.updatedAt?.millisecondsSinceEpoch ?? 0)
        .compareTo(_nodesById[left]?.updatedAt?.millisecondsSinceEpoch ?? 0);
    if (updated != 0) return updated;
    return left.compareTo(right);
  }

  int _searchScore(V3GraphNode node, String normalizedQuery) {
    if (normalizedQuery.isEmpty) return 1;
    final label = _normalized(node.label);
    var score = 0;
    if (label == normalizedQuery) {
      score = 120;
    } else if (label.startsWith(normalizedQuery)) {
      score = 100;
    } else if (label.contains(normalizedQuery)) {
      score = 80;
    }
    if (_normalized(node.summary).contains(normalizedQuery)) {
      score = score < 54 ? 54 : score;
    }
    if (node.topics.any((topic) => _normalized(topic) == normalizedQuery)) {
      score = score < 72 ? 72 : score;
    } else if (node.topics.any(
      (topic) => _normalized(topic).contains(normalizedQuery),
    )) {
      score = score < 64 ? 64 : score;
    }
    if (node.materialSourceProvided &&
        _normalized(node.source.label).contains(normalizedQuery)) {
      score = score < 46 ? 46 : score;
    }
    if (_normalized(node.cluster.label).contains(normalizedQuery)) {
      score = score < 36 ? 36 : score;
    }
    return score;
  }

  V3GraphCluster _clusterForNote(V3FeedItem note) {
    if (note.source == V3MaterialSource.note ||
        note.source == V3MaterialSource.chatExcerpt ||
        note.source == V3MaterialSource.topicCollision) {
      return switch (note.contentLineId) {
        'demo-line-daily-knowledge' ||
        'demo-line-money-desire' ||
        'demo-line-tools-consumption' => V3GraphCluster.method,
        'demo-line-expression' ||
        'demo-line-expression-observation' ||
        'demo-line-reading-culture' ||
        'demo-line-visual-expression' => V3GraphCluster.inspiration,
        'demo-line-midlife-restart' ||
        'demo-line-relationships' ||
        'demo-line-work-boundary' => V3GraphCluster.caseItem,
        'demo-line-city-observation' ||
        'demo-line-choice-cost' ||
        'demo-line-daily-life' ||
        'demo-line-space-observation' => V3GraphCluster.viewpoint,
        _ => V3GraphCluster.viewpoint,
      };
    }
    return _clusterForSource(note.source);
  }

  V3GraphCluster _clusterForSource(V3MaterialSource source) => switch (source) {
    V3MaterialSource.monologue => V3GraphCluster.inspiration,
    V3MaterialSource.documentImport ||
    V3MaterialSource.mediaImport ||
    V3MaterialSource.materialMigration ||
    V3MaterialSource.subscription ||
    V3MaterialSource.knowledgeSquare => V3GraphCluster.industry,
    V3MaterialSource.link || V3MaterialSource.hotspot => V3GraphCluster.trend,
    V3MaterialSource.meeting ||
    V3MaterialSource.internalRecording => V3GraphCluster.caseItem,
    V3MaterialSource.note ||
    V3MaterialSource.chatExcerpt ||
    V3MaterialSource.topicCollision ||
    V3MaterialSource.other => V3GraphCluster.viewpoint,
    V3MaterialSource.recordingCard => V3GraphCluster.method,
  };

  Offset _seedPositionFor(String id) {
    var hash = 0;
    for (final unit in id.codeUnits) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    return Offset(
      120 + (hash % 620).toDouble(),
      150 + ((hash ~/ 31) % 500).toDouble(),
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _loadGeneration++;
    _searchDebounceTimer?.cancel();
    _graphReadModel.removeListener(_handleLibraryChanged);
    super.dispose();
  }
}

int _compareEdgeIdentity(V3GraphEdge left, V3GraphEdge right) {
  final source = left.sourceId.compareTo(right.sourceId);
  if (source != 0) return source;
  final target = left.targetId.compareTo(right.targetId);
  if (target != 0) return target;
  final kind = left.kind.index.compareTo(right.kind.index);
  if (kind != 0) return kind;
  return left.id.compareTo(right.id);
}

List<V3GraphEdge> buildGraphLayoutEdges(
  Iterable<V3GraphEdge> semanticEdges, {
  Set<String>? nodeIds,
}) {
  final grouped = <String, List<V3GraphEdge>>{};
  for (final edge in semanticEdges) {
    if (edge.isSelfLoop ||
        (nodeIds != null &&
            (!nodeIds.contains(edge.sourceId) ||
                !nodeIds.contains(edge.targetId)))) {
      continue;
    }
    final endpoints = _orderedEndpoints(edge.sourceId, edge.targetId);
    final key = '${endpoints.$1}\u0000${endpoints.$2}';
    grouped.putIfAbsent(key, () => <V3GraphEdge>[]).add(edge);
  }
  final keys = grouped.keys.toList()..sort();
  return List<V3GraphEdge>.unmodifiable(<V3GraphEdge>[
    for (final key in keys)
      () {
        final group = grouped[key]!..sort(_compareEdgeIdentity);
        V3GraphEdge? representative;
        for (final edge in group) {
          if (edge.kind != V3GraphRelationKind.communityAffinity) continue;
          if (representative == null || edge.weight > representative.weight) {
            representative = edge;
          }
        }
        for (final edge in group) {
          if (representative != null) break;
          if (edge.kind == V3GraphRelationKind.membership) continue;
          if (representative == null || edge.weight > representative.weight) {
            representative = edge;
          }
        }
        representative ??= group.reduce(
          (left, right) => left.weight >= right.weight ? left : right,
        );
        final endpoints = _orderedEndpoints(
          representative.sourceId,
          representative.targetId,
        );
        return V3GraphEdge(
          id: 'layout-${_stableToken(key)}',
          sourceId: endpoints.$1,
          targetId: endpoints.$2,
          kind: representative.kind,
          label: representative.label,
          relationType: representative.relationType,
          attributes: <String, Object?>{
            'semanticEdgeIds': <String>[for (final edge in group) edge.id],
            'semanticEdgeCount': group.length,
          },
          weight: representative.weight,
        );
      }(),
  ]);
}

V3GraphNode _copyNodeWithPosition(V3GraphNode node, Offset position) {
  return V3GraphNode(
    id: node.id,
    label: node.label,
    cluster: node.cluster,
    position: position,
    summary: node.summary,
    entityType: node.entityType,
    attributes: node.attributes,
    labels: node.labels,
    contentId: node.contentId,
    weight: node.weight,
    center: node.center,
    source: node.source,
    materialSourceProvided: node.materialSourceProvided,
    updatedAt: node.updatedAt,
    topics: node.topics,
    isHotspot: node.isHotspot,
    isAggregated: node.isAggregated,
    isRecent: node.isRecent,
  );
}

String _localEdgeId(
  V3GraphRelationKind kind,
  String sourceId,
  String targetId,
  String discriminator,
) {
  final endpoints = kind == V3GraphRelationKind.linkedMaterial
      ? (sourceId, targetId)
      : _orderedEndpoints(sourceId, targetId);
  final seed =
      '${kind.name}\u0000${endpoints.$1}\u0000${endpoints.$2}'
      '\u0000$discriminator';
  return 'local-${kind.name}-${_stableToken(seed)}';
}

(String, String) _orderedEndpoints(String left, String right) =>
    left.compareTo(right) <= 0 ? (left, right) : (right, left);

String _stableToken(String input) {
  var hash = 0x811c9dc5;
  for (final unit in input.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}

DateTime _laterDate(DateTime left, DateTime right) =>
    left.isAfter(right) ? left : right;

String? _normalizedOptional(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}

String _normalized(String value) =>
    value.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();

bool _isRecentAt(DateTime? updatedAt, DateTime now) =>
    updatedAt != null && now.difference(updatedAt) <= const Duration(days: 7);
