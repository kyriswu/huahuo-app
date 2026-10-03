import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_client.dart';
import '../domain/graph_snapshot.dart';

// resident-provider: Keeps the graph id value consistent across sibling route consumers.
final graphIdProvider = Provider<String?>((ref) {
  final value = const String.fromEnvironment('HUAHUO_GRAPH_ID').trim();
  return value.isEmpty ? null : value;
});

// resident-provider: Shares one account-scoped graph repository identity across dependent controllers.
final graphRepositoryProvider = Provider<GraphRepository?>((ref) => null);

abstract interface class GraphApiPort {
  Future<ApiResult<GraphSnapshot>> fetchGraph({required String graphId});
}

abstract interface class GraphRepository {
  Future<GraphSnapshot> loadGraph({required String graphId});
}

final class ApiGraphRepository implements GraphRepository {
  const ApiGraphRepository({required this.api});

  final GraphApiPort api;

  @override
  Future<GraphSnapshot> loadGraph({required String graphId}) async {
    final result = await api.fetchGraph(graphId: graphId);
    final snapshot = result.data;
    if (result.ok && snapshot != null) return snapshot;
    final failure = result.error;
    throw GraphRepositoryException(
      code: failure?.code ?? 'GRAPH_SNAPSHOT_MALFORMED',
      userMessageKey:
          failure?.userMessageKey ?? 'graph.error.snapshotMalformed',
      retryable: failure?.isRetryable ?? false,
    );
  }
}

final class GraphRepositoryException implements Exception {
  const GraphRepositoryException({
    required this.code,
    required this.userMessageKey,
    required this.retryable,
  });

  final String code;
  final String userMessageKey;
  final bool retryable;

  @override
  String toString() => 'GraphRepositoryException($code)';
}
