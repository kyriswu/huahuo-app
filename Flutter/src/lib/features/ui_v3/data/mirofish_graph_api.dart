import 'package:huahuo_api/huahuo_api.dart';
import '../domain/graph_snapshot.dart';
import 'graph_repository.dart';
import 'mirofish_graph_mapper.dart';

abstract interface class MiroFishGraphApiPort implements GraphApiPort {}

final class MiroFishGraphApi implements MiroFishGraphApiPort {
  const MiroFishGraphApi({
    required this.apiClient,
    this.mapper = const MiroFishGraphMapper(),
  });

  final ApiClient apiClient;
  final MiroFishGraphMapper mapper;

  @override
  Future<ApiResult<GraphSnapshot>> fetchGraph({required String graphId}) {
    final normalized = graphId.trim();
    if (!isSafeGraphIdentifier(normalized)) {
      return Future<ApiResult<GraphSnapshot>>.value(
        ApiResult<GraphSnapshot>.failure(
          error: const AppFailure(
            code: 'GRAPH_ID_INVALID',
            category: AppFailureCategory.api,
            message: 'Graph identifier is invalid',
            userMessageKey: 'graph.error.idInvalid',
          ),
          idempotencyStore: SubmissionKeyStore.empty,
        ),
      );
    }
    return apiClient.request<GraphSnapshot>(
      ApiRequestOptions<GraphSnapshot>(
        endpointId: 'contentNavigation',
        pathParams: <String, Object>{
          'workspaceId': normalized,
          'map': 'overview',
        },
        parseData: (value) =>
            mapper.fromContentNavigation(value, workspaceId: normalized),
      ),
    );
  }
}

bool isSafeGraphIdentifier(String value) =>
    RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$').hasMatch(value);
