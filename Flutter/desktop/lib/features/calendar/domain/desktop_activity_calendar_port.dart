import 'package:huahuo_api/huahuo_api.dart';

import '../../../shared/services/desktop_service_result.dart';

abstract interface class DesktopActivityCalendarPort {
  Future<DesktopServiceResult<WorkspaceNoteMetricsPage>> loadPage({
    required String workspaceId,
    int limit = 42,
    String? cursor,
  });
}

final class UnavailableDesktopActivityCalendarPort
    implements DesktopActivityCalendarPort {
  const UnavailableDesktopActivityCalendarPort();

  @override
  Future<DesktopServiceResult<WorkspaceNoteMetricsPage>> loadPage({
    required String workspaceId,
    int limit = 42,
    String? cursor,
  }) async => const DesktopServiceResult<WorkspaceNoteMetricsPage>.unavailable(
    code: 'DESKTOP_ACTIVITY_CALENDAR_UNAVAILABLE',
    message: '活动日历服务尚未配置',
  );
}
