import 'package:huahuo_api/huahuo_api.dart';

import '../../../shared/services/desktop_service_result.dart';
import '../domain/desktop_activity_calendar_port.dart';

final class RemoteDesktopActivityCalendarPort
    implements DesktopActivityCalendarPort {
  RemoteDesktopActivityCalendarPort(ApiClient api)
    : _client = WorkspaceNoteMetricsClient(api);

  final WorkspaceNoteMetricsClient _client;

  @override
  Future<DesktopServiceResult<WorkspaceNoteMetricsPage>> loadPage({
    required String workspaceId,
    int limit = 42,
    String? cursor,
  }) async {
    final result = await _client.list(
      workspaceId: workspaceId,
      limit: limit,
      cursor: cursor,
    );
    final page = result.data;
    if (result.ok && page != null) {
      return DesktopServiceResult<WorkspaceNoteMetricsPage>.success(page);
    }
    final failure = result.error;
    return DesktopServiceResult<WorkspaceNoteMetricsPage>.failure(
      code: failure?.code ?? 'ACTIVITY_CALENDAR_LOAD_FAILED',
      message: _safeMessage(failure?.message) ?? '活动日历读取失败',
      retryable: failure?.isRetryable ?? true,
    );
  }
}

String? _safeMessage(String? value) {
  final text = value?.trim();
  if (text == null ||
      text.isEmpty ||
      text.runes.length > 200 ||
      text.runes.any((rune) => rune <= 0x1f || rune == 0x7f)) {
    return null;
  }
  return text;
}
