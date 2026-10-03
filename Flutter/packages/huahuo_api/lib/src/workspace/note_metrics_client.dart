import '../api/api_client.dart';
import '../api/api_envelope.dart';

const _noteMetricsSchemaVersion = 'huahuo.workspace_note_daily_metrics.v2';
const _newNoteCountMetricId = 'new_note_count';
const _maximumLimit = 366;
const _maximumCursorLength = 4096;

final class WorkspaceNoteMetricDay {
  const WorkspaceNoteMetricDay({
    required this.date,
    required this.count,
    required this.complete,
  });

  final String date;
  final int count;
  final bool complete;
}

final class WorkspaceNoteMetricsCoverage {
  const WorkspaceNoteMetricsCoverage({
    required this.startAt,
    required this.startDate,
    required this.completeFromDate,
    required this.currentDate,
    required this.historyComplete,
  });

  final DateTime startAt;
  final String startDate;
  final String completeFromDate;
  final String currentDate;
  final bool historyComplete;
}

final class WorkspaceNoteMetricsPage {
  const WorkspaceNoteMetricsPage({
    required this.schemaVersion,
    required this.metricId,
    required this.timezone,
    required this.asOf,
    required this.coverage,
    required this.days,
    required this.hasMore,
    required this.nextCursor,
  });

  final String schemaVersion;
  final String metricId;
  final String timezone;
  final DateTime asOf;
  final WorkspaceNoteMetricsCoverage coverage;
  final List<WorkspaceNoteMetricDay> days;
  final bool hasMore;
  final String nextCursor;
}

/// Public transport for server-owned, user-time-zone daily Note counts.
final class WorkspaceNoteMetricsClient {
  const WorkspaceNoteMetricsClient(this._api);

  final ApiClient _api;

  Future<ApiResult<WorkspaceNoteMetricsPage>> list({
    required String workspaceId,
    int limit = 31,
    String? cursor,
  }) {
    final normalizedWorkspaceId = _requiredIdentifier(
      workspaceId,
      'workspaceId',
    );
    final normalizedCursor = cursor?.trim();
    if (limit < 1 || limit > _maximumLimit) {
      throw ArgumentError.value(limit, 'limit', 'must be between 1 and 366');
    }
    if (normalizedCursor != null &&
        (normalizedCursor.isEmpty ||
            normalizedCursor.length > _maximumCursorLength)) {
      throw ArgumentError.value(
        cursor,
        'cursor',
        'must be a non-empty opaque cursor',
      );
    }
    return _api.request<WorkspaceNoteMetricsPage>(
      ApiRequestOptions<WorkspaceNoteMetricsPage>(
        endpointId: 'workspaceNoteMetrics',
        pathParams: <String, Object>{'workspaceId': normalizedWorkspaceId},
        query: <String, Object?>{
          'limit': limit,
          if (normalizedCursor != null) 'cursor': normalizedCursor,
        },
        parseData: (value) {
          final page = parseWorkspaceNoteMetricsPage(value);
          if (page == null) return null;
          if (normalizedCursor == null &&
              page.days.first.date != page.coverage.currentDate) {
            return null;
          }
          return page;
        },
      ),
    );
  }
}

WorkspaceNoteMetricsPage? parseWorkspaceNoteMetricsPage(Object? value) {
  final object = asObjectMap(value);
  if (object == null ||
      !_hasOnlyKeys(object, const <String>{
        'schemaVersion',
        'metricId',
        'timezone',
        'asOf',
        'coverage',
        'days',
        'hasMore',
        'nextCursor',
      })) {
    return null;
  }
  final schemaVersion = _text(object['schemaVersion']);
  final metricId = _text(object['metricId']);
  final timezone = _timezone(object['timezone']);
  final asOf = _dateTime(object['asOf']);
  final coverage = _coverage(object['coverage']);
  final days = _days(object['days']);
  final hasMore = object['hasMore'];
  final nextCursor = object['nextCursor'];
  if (schemaVersion == null ||
      metricId == null ||
      schemaVersion != _noteMetricsSchemaVersion ||
      metricId != _newNoteCountMetricId ||
      timezone == null ||
      asOf == null ||
      coverage == null ||
      days == null ||
      days.isEmpty ||
      hasMore is! bool ||
      nextCursor is! String ||
      nextCursor.length > _maximumCursorLength ||
      (hasMore && nextCursor.isEmpty) ||
      (!hasMore && nextCursor.isNotEmpty)) {
    return null;
  }
  if (!_validateDays(days, coverage) ||
      (hasMore && days.last.date == coverage.startDate) ||
      (!hasMore && days.last.date != coverage.startDate)) {
    return null;
  }
  return WorkspaceNoteMetricsPage(
    schemaVersion: schemaVersion,
    metricId: metricId,
    timezone: timezone,
    asOf: asOf,
    coverage: coverage,
    days: List<WorkspaceNoteMetricDay>.unmodifiable(days),
    hasMore: hasMore,
    nextCursor: nextCursor,
  );
}

WorkspaceNoteMetricsCoverage? _coverage(Object? value) {
  final object = asObjectMap(value);
  if (object == null ||
      !_hasOnlyKeys(object, const <String>{
        'startAt',
        'startDate',
        'completeFromDate',
        'currentDate',
        'historyComplete',
      })) {
    return null;
  }
  final startAt = _dateTime(object['startAt']);
  final startDate = _date(object['startDate']);
  final completeFromDate = _date(object['completeFromDate']);
  final currentDate = _date(object['currentDate']);
  final historyComplete = object['historyComplete'];
  if (startAt == null ||
      startDate == null ||
      completeFromDate == null ||
      currentDate == null ||
      historyComplete is! bool ||
      startDate.compareTo(completeFromDate) > 0 ||
      completeFromDate.compareTo(currentDate) > 0) {
    return null;
  }
  return WorkspaceNoteMetricsCoverage(
    startAt: startAt,
    startDate: startDate,
    completeFromDate: completeFromDate,
    currentDate: currentDate,
    historyComplete: historyComplete,
  );
}

List<WorkspaceNoteMetricDay>? _days(Object? value) {
  if (value is! List || value.length > _maximumLimit) return null;
  final days = <WorkspaceNoteMetricDay>[];
  for (final raw in value) {
    final object = asObjectMap(raw);
    if (object == null ||
        !_hasOnlyKeys(object, const <String>{'date', 'count', 'complete'})) {
      return null;
    }
    final date = _date(object['date']);
    final count = object['count'];
    final complete = object['complete'];
    if (date == null || count is! int || count < 0 || complete is! bool) {
      return null;
    }
    days.add(
      WorkspaceNoteMetricDay(date: date, count: count, complete: complete),
    );
  }
  return days;
}

bool _validateDays(
  List<WorkspaceNoteMetricDay> days,
  WorkspaceNoteMetricsCoverage coverage,
) {
  String? previous;
  final seen = <String>{};
  for (final day in days) {
    if (!seen.add(day.date) ||
        day.date.compareTo(coverage.startDate) < 0 ||
        day.date.compareTo(coverage.currentDate) > 0 ||
        (previous != null && !_isCalendarDayBefore(previous, day.date))) {
      return false;
    }
    final shouldBeComplete =
        day.date != coverage.currentDate &&
        (coverage.historyComplete ||
            day.date.compareTo(coverage.completeFromDate) >= 0);
    if (day.complete != shouldBeComplete) return false;
    previous = day.date;
  }
  return true;
}

String _requiredIdentifier(String value, String name) {
  final normalized = value.trim();
  if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,159}$').hasMatch(normalized)) {
    throw ArgumentError.value(value, name, 'must be a public identifier');
  }
  return normalized;
}

String? _text(Object? value) =>
    value is String && value.trim().isNotEmpty ? value.trim() : null;

String? _timezone(Object? value) {
  final timezone = _text(value);
  if (timezone == null ||
      (timezone != 'UTC' &&
          !RegExp(r'^[A-Za-z]+(?:/[A-Za-z0-9_+\-]+)+$').hasMatch(timezone))) {
    return null;
  }
  return timezone;
}

DateTime? _dateTime(Object? value) {
  final text = _text(value);
  return text == null ? null : DateTime.tryParse(text)?.toUtc();
}

String? _date(Object? value) {
  final text = _text(value);
  return text != null && _calendarDate(text) != null ? text : null;
}

bool _isCalendarDayBefore(String newer, String older) {
  final newerDate = _calendarDate(newer);
  final olderDate = _calendarDate(older);
  if (newerDate == null || olderDate == null) return false;
  return _dateText(newerDate.subtract(const Duration(days: 1))) ==
      _dateText(olderDate);
}

DateTime? _calendarDate(String value) {
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) return null;
  final year = int.tryParse(value.substring(0, 4));
  final month = int.tryParse(value.substring(5, 7));
  final day = int.tryParse(value.substring(8, 10));
  if (year == null || month == null || day == null) return null;
  final parsed = DateTime.utc(year, month, day);
  return parsed.year == year && parsed.month == month && parsed.day == day
      ? parsed
      : null;
}

String _dateText(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}';

bool _hasOnlyKeys(Map<String, Object?> object, Set<String> expected) =>
    object.length == expected.length && object.keys.every(expected.contains);
