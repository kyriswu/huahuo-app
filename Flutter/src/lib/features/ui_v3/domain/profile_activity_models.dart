import 'package:flutter/foundation.dart';

enum V3ProfileActivityType {
  raw,
  summary,
  sprout,
  conversation,
  creation,
  upload,
}

extension V3ProfileActivityTypeX on V3ProfileActivityType {
  String get label => switch (this) {
    V3ProfileActivityType.raw => '原始材料',
    V3ProfileActivityType.summary => '纲要',
    V3ProfileActivityType.sprout => '深度洞察',
    V3ProfileActivityType.conversation => '对话',
    V3ProfileActivityType.creation => '创作',
    V3ProfileActivityType.upload => '上传',
  };
}

@immutable
final class V3ProfileActivity {
  const V3ProfileActivity({
    required this.id,
    required this.occurredAt,
    required this.type,
    required this.title,
    this.feedItemId,
    this.route,
  });

  final String id;
  final DateTime occurredAt;
  final V3ProfileActivityType type;
  final String title;
  final String? feedItemId;
  final String? route;
}

int v3HeatLevelForActivityCount(int count) {
  if (count <= 0) return 0;
  if (count == 1) return 1;
  if (count <= 3) return 2;
  if (count <= 6) return 3;
  return 4;
}

DateTime v3StartOfNaturalWeek(DateTime day) {
  final date = DateTime(day.year, day.month, day.day);
  return date.subtract(Duration(days: date.weekday - DateTime.monday));
}

List<DateTime> v3TrailingNaturalWeekStarts({
  required DateTime referenceDay,
  int weekCount = 10,
}) {
  if (weekCount <= 0) return const <DateTime>[];
  final lastWeekStart = v3StartOfNaturalWeek(referenceDay);
  return List<DateTime>.generate(
    weekCount,
    (index) =>
        lastWeekStart.subtract(Duration(days: 7 * (weekCount - 1 - index))),
  );
}
