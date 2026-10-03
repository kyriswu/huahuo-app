import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:huahuo_api/huahuo_api.dart';

import '../domain/desktop_activity_calendar_port.dart';

enum DesktopActivityCalendarStatus { idle, loading, ready, failure }

final class DesktopActivityCalendarState {
  DesktopActivityCalendarState({
    required this.status,
    List<WorkspaceNoteMetricDay> days = const <WorkspaceNoteMetricDay>[],
    this.timezone,
    this.coverage,
    this.hasMore = false,
    this.nextCursor,
    this.selectedDate,
    this.loadingMore = false,
    this.errorMessage,
  }) : days = UnmodifiableListView(days);

  factory DesktopActivityCalendarState.initial() =>
      DesktopActivityCalendarState(status: DesktopActivityCalendarStatus.idle);

  final DesktopActivityCalendarStatus status;
  final List<WorkspaceNoteMetricDay> days;
  final String? timezone;
  final WorkspaceNoteMetricsCoverage? coverage;
  final bool hasMore;
  final String? nextCursor;
  final String? selectedDate;
  final bool loadingMore;
  final String? errorMessage;

  WorkspaceNoteMetricDay? get selectedDay {
    for (final day in days) {
      if (day.date == selectedDate) return day;
    }
    return null;
  }

  DesktopActivityCalendarState copyWith({
    DesktopActivityCalendarStatus? status,
    List<WorkspaceNoteMetricDay>? days,
    String? timezone,
    WorkspaceNoteMetricsCoverage? coverage,
    bool? hasMore,
    String? nextCursor,
    String? selectedDate,
    bool? loadingMore,
    String? errorMessage,
    bool clearError = false,
  }) => DesktopActivityCalendarState(
    status: status ?? this.status,
    days: days ?? this.days,
    timezone: timezone ?? this.timezone,
    coverage: coverage ?? this.coverage,
    hasMore: hasMore ?? this.hasMore,
    nextCursor: nextCursor ?? this.nextCursor,
    selectedDate: selectedDate ?? this.selectedDate,
    loadingMore: loadingMore ?? this.loadingMore,
    errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
  );
}

final class DesktopActivityCalendarController extends ChangeNotifier {
  DesktopActivityCalendarController(this._port);

  final DesktopActivityCalendarPort _port;
  DesktopActivityCalendarState _state = DesktopActivityCalendarState.initial();
  String? _workspaceId;
  int _generation = 0;

  DesktopActivityCalendarState get state => _state;

  Future<void> bindWorkspace(String? workspaceId) async {
    final normalized = workspaceId?.trim();
    if (normalized == _workspaceId) return;
    _workspaceId = normalized == null || normalized.isEmpty ? null : normalized;
    _generation++;
    _state = DesktopActivityCalendarState.initial();
    notifyListeners();
    if (_workspaceId != null) await reload();
  }

  Future<void> reload() => _load(append: false);

  Future<void> loadOlder() async {
    if (!_state.hasMore || _state.loadingMore) return;
    await _load(append: true);
  }

  void selectDate(String date) {
    if (_state.days.every((day) => day.date != date) ||
        _state.selectedDate == date) {
      return;
    }
    _state = _state.copyWith(selectedDate: date);
    notifyListeners();
  }

  Future<void> _load({required bool append}) async {
    final workspaceId = _workspaceId;
    if (workspaceId == null) return;
    final generation = _generation;
    if (append) {
      _state = _state.copyWith(loadingMore: true, clearError: true);
    } else {
      _state = DesktopActivityCalendarState(
        status: DesktopActivityCalendarStatus.loading,
      );
    }
    notifyListeners();
    final result = await _port.loadPage(
      workspaceId: workspaceId,
      cursor: append ? _state.nextCursor : null,
    );
    if (generation != _generation || workspaceId != _workspaceId) return;
    final page = result.data;
    if (!result.isSuccess || page == null) {
      _state = append
          ? _state.copyWith(loadingMore: false, errorMessage: result.message)
          : DesktopActivityCalendarState(
              status: DesktopActivityCalendarStatus.failure,
              errorMessage: result.message,
            );
      notifyListeners();
      return;
    }
    final byDate = <String, WorkspaceNoteMetricDay>{
      if (append)
        for (final day in _state.days) day.date: day,
      for (final day in page.days) day.date: day,
    };
    final days = byDate.values.toList(growable: false)
      ..sort((left, right) => right.date.compareTo(left.date));
    _state = DesktopActivityCalendarState(
      status: DesktopActivityCalendarStatus.ready,
      days: days,
      timezone: page.timezone,
      coverage: page.coverage,
      hasMore: page.hasMore,
      nextCursor: page.nextCursor.isEmpty ? null : page.nextCursor,
      selectedDate: _state.selectedDate ?? days.firstOrNull?.date,
    );
    notifyListeners();
  }
}
