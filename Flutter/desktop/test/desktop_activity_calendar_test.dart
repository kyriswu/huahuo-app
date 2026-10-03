import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuo_api/huahuo_api.dart';
import 'package:huahuo_desktop/features/calendar/application/desktop_activity_calendar_controller.dart';
import 'package:huahuo_desktop/features/calendar/domain/desktop_activity_calendar_port.dart';
import 'package:huahuo_desktop/features/calendar/widgets/desktop_activity_calendar_workspace.dart';
import 'package:huahuo_desktop/shared/services/desktop_service_result.dart';

void main() {
  test('loads, selects, and appends calendar pages', () async {
    final port = _QueueCalendarPort(<Future<_CalendarResult> Function()>[
      () async => DesktopServiceResult<WorkspaceNoteMetricsPage>.success(
        _page(
          days: const <WorkspaceNoteMetricDay>[
            WorkspaceNoteMetricDay(
              date: '2026-09-03',
              count: 4,
              complete: false,
            ),
            WorkspaceNoteMetricDay(
              date: '2026-09-02',
              count: 2,
              complete: true,
            ),
          ],
          hasMore: true,
          nextCursor: 'older-1',
        ),
      ),
      () async => DesktopServiceResult<WorkspaceNoteMetricsPage>.success(
        _page(
          days: const <WorkspaceNoteMetricDay>[
            WorkspaceNoteMetricDay(
              date: '2026-09-01',
              count: 1,
              complete: true,
            ),
          ],
        ),
      ),
    ]);
    final controller = DesktopActivityCalendarController(port);
    addTearDown(controller.dispose);

    await controller.bindWorkspace('workspace-a');

    expect(controller.state.status, DesktopActivityCalendarStatus.ready);
    expect(controller.state.selectedDate, '2026-09-03');
    expect(controller.state.hasMore, isTrue);
    controller.selectDate('2026-09-02');
    await controller.loadOlder();

    expect(port.requests, <_CalendarRequest>[
      const _CalendarRequest('workspace-a', null),
      const _CalendarRequest('workspace-a', 'older-1'),
    ]);
    expect(controller.state.days.map((day) => day.date), <String>[
      '2026-09-03',
      '2026-09-02',
      '2026-09-01',
    ]);
    expect(controller.state.selectedDate, '2026-09-02');
    expect(controller.state.hasMore, isFalse);
  });

  test('exposes failure and retries against the same Workspace', () async {
    final port = _QueueCalendarPort(<Future<_CalendarResult> Function()>[
      () async => const DesktopServiceResult<WorkspaceNoteMetricsPage>.failure(
        code: 'OFFLINE',
        message: '网络不可用',
        retryable: true,
      ),
      () async =>
          DesktopServiceResult<WorkspaceNoteMetricsPage>.success(_page()),
    ]);
    final controller = DesktopActivityCalendarController(port);
    addTearDown(controller.dispose);

    await controller.bindWorkspace('workspace-a');
    expect(controller.state.status, DesktopActivityCalendarStatus.failure);
    expect(controller.state.errorMessage, '网络不可用');

    await controller.reload();
    expect(controller.state.status, DesktopActivityCalendarStatus.ready);
    expect(port.requests, hasLength(2));
  });

  test('ignores a stale page after Workspace replacement', () async {
    final first = Completer<_CalendarResult>();
    final second = Completer<_CalendarResult>();
    final port = _WorkspaceCalendarPort(<String, Completer<_CalendarResult>>{
      'workspace-a': first,
      'workspace-b': second,
    });
    final controller = DesktopActivityCalendarController(port);
    addTearDown(controller.dispose);

    final firstLoad = controller.bindWorkspace('workspace-a');
    final secondLoad = controller.bindWorkspace('workspace-b');
    second.complete(
      DesktopServiceResult<WorkspaceNoteMetricsPage>.success(
        _page(date: '2026-09-02', count: 7),
      ),
    );
    await secondLoad;
    first.complete(
      DesktopServiceResult<WorkspaceNoteMetricsPage>.success(
        _page(date: '2026-09-03', count: 99),
      ),
    );
    await firstLoad;

    expect(controller.state.days.single.date, '2026-09-02');
    expect(controller.state.days.single.count, 7);
  });

  testWidgets('day selection and older-page controls are interactive', (
    tester,
  ) async {
    final port = _QueueCalendarPort(<Future<_CalendarResult> Function()>[
      () async => DesktopServiceResult<WorkspaceNoteMetricsPage>.success(
        _page(
          days: const <WorkspaceNoteMetricDay>[
            WorkspaceNoteMetricDay(
              date: '2026-09-03',
              count: 4,
              complete: false,
            ),
            WorkspaceNoteMetricDay(
              date: '2026-09-02',
              count: 2,
              complete: true,
            ),
          ],
          hasMore: true,
          nextCursor: 'older-1',
        ),
      ),
      () async => DesktopServiceResult<WorkspaceNoteMetricsPage>.success(
        _page(date: '2026-09-01', count: 1),
      ),
    ]);
    final controller = DesktopActivityCalendarController(port);
    addTearDown(controller.dispose);
    await controller.bindWorkspace('workspace-a');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DesktopActivityCalendarWorkspace(controller: controller),
        ),
      ),
    );

    expect(find.text('2026-09-03 新增 4 条笔记 · 数据仍在更新'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey<String>('activity-calendar-day-2026-09-02')),
    );
    await tester.pump();
    expect(find.text('2026-09-02 新增 2 条笔记'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('activity-calendar-load-more')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('activity-calendar-day-2026-09-01')),
      findsOneWidget,
    );
  });
}

typedef _CalendarResult = DesktopServiceResult<WorkspaceNoteMetricsPage>;

final class _CalendarRequest {
  const _CalendarRequest(this.workspaceId, this.cursor);

  final String workspaceId;
  final String? cursor;

  @override
  bool operator ==(Object other) =>
      other is _CalendarRequest &&
      other.workspaceId == workspaceId &&
      other.cursor == cursor;

  @override
  int get hashCode => Object.hash(workspaceId, cursor);
}

final class _QueueCalendarPort implements DesktopActivityCalendarPort {
  _QueueCalendarPort(this._responses);

  final List<Future<_CalendarResult> Function()> _responses;
  final List<_CalendarRequest> requests = <_CalendarRequest>[];

  @override
  Future<_CalendarResult> loadPage({
    required String workspaceId,
    int limit = 42,
    String? cursor,
  }) {
    requests.add(_CalendarRequest(workspaceId, cursor));
    return _responses.removeAt(0)();
  }
}

final class _WorkspaceCalendarPort implements DesktopActivityCalendarPort {
  const _WorkspaceCalendarPort(this._responses);

  final Map<String, Completer<_CalendarResult>> _responses;

  @override
  Future<_CalendarResult> loadPage({
    required String workspaceId,
    int limit = 42,
    String? cursor,
  }) => _responses[workspaceId]!.future;
}

WorkspaceNoteMetricsPage _page({
  String date = '2026-09-03',
  int count = 3,
  List<WorkspaceNoteMetricDay>? days,
  bool hasMore = false,
  String nextCursor = '',
}) {
  final values =
      days ??
      <WorkspaceNoteMetricDay>[
        WorkspaceNoteMetricDay(date: date, count: count, complete: true),
      ];
  return WorkspaceNoteMetricsPage(
    schemaVersion: 'huahuo.workspace_note_daily_metrics.v2',
    metricId: 'new_note_count',
    timezone: 'Asia/Shanghai',
    asOf: DateTime.utc(2026, 9, 3),
    coverage: WorkspaceNoteMetricsCoverage(
      startAt: DateTime.utc(2026, 9, 1),
      startDate: values.last.date,
      completeFromDate: values.last.date,
      currentDate: values.first.date,
      historyComplete: !hasMore,
    ),
    days: values,
    hasMore: hasMore,
    nextCursor: nextCursor,
  );
}
