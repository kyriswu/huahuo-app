import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/ui_v3_mock_data.dart';
import '../domain/profile_activity_models.dart';

// resident-provider: Preserves the profile hub controller state machine across route transitions.
final profileHubControllerProvider =
    ChangeNotifierProvider<ProfileHubController>(
      (ref) => ProfileHubController(),
    );

final class ProfileHubController extends ChangeNotifier {
  ProfileHubController({DateTime? referenceDay})
    : _activities = _seedActivities(referenceDay ?? DateTime.now());

  String get displayName => '内容使用者';
  String get membershipLabel => '未开通会员';

  final List<V3ProfileActivity> _activities;

  List<V3ProfileActivity> get activities =>
      List<V3ProfileActivity>.unmodifiable(_activities);

  int activityCountFor(DateTime day) => _activities
      .where((activity) => _sameDay(activity.occurredAt, day))
      .length;

  void recordActivity(V3ProfileActivity activity) {
    final existingIndex = _activities.indexWhere(
      (existing) => existing.id == activity.id,
    );
    if (existingIndex == -1) {
      _activities.add(activity);
    } else {
      _activities[existingIndex] = activity;
    }
    _activities.sort((a, b) => b.occurredAt.compareTo(a.occurredAt));
    notifyListeners();
  }

  int removeActivitiesForNote(String feedItemId) {
    final normalizedId = feedItemId.trim();
    if (normalizedId.isEmpty) return 0;
    final initialCount = _activities.length;
    _activities.removeWhere((activity) => activity.feedItemId == normalizedId);
    final removedCount = initialCount - _activities.length;
    if (removedCount > 0) notifyListeners();
    return removedCount;
  }

  static List<V3ProfileActivity> _seedActivities(DateTime referenceDay) {
    const activityCountsByWeek = <List<int>>[
      <int>[0, 0, 0, 0, 0, 0, 0],
      <int>[1, 0, 0, 0, 0, 0, 0],
      <int>[0, 2, 0, 0, 0, 0, 0],
      <int>[0, 0, 4, 0, 0, 0, 0],
      <int>[0, 0, 0, 7, 0, 0, 0],
      <int>[0, 1, 0, 2, 0, 0, 0],
      <int>[0, 0, 0, 0, 4, 0, 0],
      <int>[0, 0, 0, 0, 0, 7, 0],
      <int>[1, 0, 2, 0, 4, 0, 0],
      <int>[0, 1, 0, 0, 0, 0, 7],
    ];
    final weeks = v3TrailingNaturalWeekStarts(referenceDay: referenceDay);
    final lastRecordedDay = DateTime(
      referenceDay.year,
      referenceDay.month,
      referenceDay.day,
    );
    final activities = <V3ProfileActivity>[];

    for (var weekIndex = 0; weekIndex < weeks.length; weekIndex++) {
      final counts = activityCountsByWeek[weekIndex];
      for (var weekdayIndex = 0; weekdayIndex < counts.length; weekdayIndex++) {
        final day = weeks[weekIndex].add(Duration(days: weekdayIndex));
        if (day.isAfter(lastRecordedDay)) continue;
        for (
          var eventIndex = 0;
          eventIndex < counts[weekdayIndex];
          eventIndex++
        ) {
          final sequence = weekIndex * 7 + weekdayIndex + eventIndex;
          final note = v3KnowledgeNotes[sequence % v3KnowledgeNotes.length];
          activities.add(
            V3ProfileActivity(
              id: 'profile-heatmap-$weekIndex-$weekdayIndex-$eventIndex',
              occurredAt: day.add(Duration(hours: 9 + eventIndex)),
              type: V3ProfileActivityType
                  .values[sequence % V3ProfileActivityType.values.length],
              title: note.title,
              feedItemId: note.id,
              route: '/v3/feed/items/${Uri.encodeComponent(note.id)}',
            ),
          );
        }
      }
    }
    activities.sort((a, b) => b.occurredAt.compareTo(a.occurredAt));
    return activities;
  }

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}
