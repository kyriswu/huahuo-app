import 'package:huahuo_api/huahuo_api.dart';

abstract interface class NoteMetricsRepository {
  Future<WorkspaceNoteMetricsPage> load({required int limit, String? cursor});
}

final class NoteMetricsException implements Exception {
  const NoteMetricsException(this.code);

  final String code;
}

final class RemoteNoteMetricsRepository implements NoteMetricsRepository {
  RemoteNoteMetricsRepository({
    required ApiClient apiClient,
    required String? Function() workspaceId,
  }) : _client = WorkspaceNoteMetricsClient(apiClient),
       // ignore: prefer_initializing_formals
       _workspaceId = workspaceId;

  final WorkspaceNoteMetricsClient _client;
  final String? Function() _workspaceId;

  @override
  Future<WorkspaceNoteMetricsPage> load({
    required int limit,
    String? cursor,
  }) async {
    final workspaceId = _workspaceId()?.trim();
    if (workspaceId == null || workspaceId.isEmpty) {
      throw const NoteMetricsException('NOTE_METRICS_WORKSPACE_UNAVAILABLE');
    }
    final result = await _client.list(
      workspaceId: workspaceId,
      limit: limit,
      cursor: cursor,
    );
    final page = result.data;
    if (!result.ok || page == null) {
      throw NoteMetricsException(
        result.error?.code ?? 'NOTE_METRICS_REMOTE_LOAD_FAILED',
      );
    }
    return page;
  }
}

final class UnavailableNoteMetricsRepository implements NoteMetricsRepository {
  const UnavailableNoteMetricsRepository();

  @override
  Future<WorkspaceNoteMetricsPage> load({required int limit, String? cursor}) =>
      Future<WorkspaceNoteMetricsPage>.error(
        const NoteMetricsException('NOTE_METRICS_REPOSITORY_UNAVAILABLE'),
      );
}
