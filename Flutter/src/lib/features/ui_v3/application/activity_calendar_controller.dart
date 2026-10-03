import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

// resident-provider: Preserves the activity calendar controller state machine across route transitions.
final activityCalendarControllerProvider =
    ChangeNotifierProvider<ActivityCalendarController>(
      (ref) => ActivityCalendarController(),
    );

final class ActivityCalendarController extends ChangeNotifier {
  ActivityCalendarController({DateTime? now}) {
    final value = now ?? DateTime.now();
    _today = DateTime(value.year, value.month, value.day);
    _month = DateTime(value.year, value.month);
    _selectedDay = DateTime(value.year, value.month, value.day);
  }

  late final DateTime _today;
  late DateTime _month;
  late DateTime _selectedDay;

  DateTime get month => _month;
  DateTime get selectedDay => _selectedDay;
  DateTime get today => _today;
  bool get canGoNext => _month.isBefore(DateTime(_today.year, _today.month));

  void previousMonth() {
    _moveMonth(-1);
  }

  void nextMonth() {
    if (!canGoNext) return;
    _moveMonth(1);
  }

  void _moveMonth(int offset) {
    final next = DateTime(_month.year, _month.month + offset);
    if (next.isAfter(DateTime(_today.year, _today.month))) return;
    final lastDay = DateTime(next.year, next.month + 1, 0).day;
    _month = next;
    final candidate = DateTime(
      next.year,
      next.month,
      _selectedDay.day.clamp(1, lastDay),
    );
    _selectedDay = candidate.isAfter(_today) ? _today : candidate;
    notifyListeners();
  }

  void selectDay(DateTime day) {
    final normalized = DateTime(day.year, day.month, day.day);
    final selected = normalized.isAfter(_today) ? _today : normalized;
    _month = DateTime(selected.year, selected.month);
    _selectedDay = selected;
    notifyListeners();
  }

  void selectToday() {
    _month = DateTime(_today.year, _today.month);
    _selectedDay = _today;
    notifyListeners();
  }
}
