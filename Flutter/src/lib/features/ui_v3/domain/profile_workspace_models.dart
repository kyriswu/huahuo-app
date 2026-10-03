import 'package:flutter/foundation.dart';

@immutable
final class ProfileTodo {
  const ProfileTodo({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    this.dueAt,
    this.completedAt,
  });

  final String id;
  final String title;
  final DateTime? dueAt;
  final DateTime? completedAt;
  final DateTime createdAt;
  final DateTime updatedAt;

  bool get isCompleted => completedAt != null;

  bool isOverdueAt(DateTime now) =>
      !isCompleted && dueAt != null && dueAt!.isBefore(now);

  ProfileTodo copyWith({
    String? title,
    DateTime? dueAt,
    DateTime? completedAt,
    DateTime? updatedAt,
    bool clearDueAt = false,
    bool clearCompletedAt = false,
  }) => ProfileTodo(
    id: id,
    title: title ?? this.title,
    dueAt: clearDueAt ? null : dueAt ?? this.dueAt,
    completedAt: clearCompletedAt ? null : completedAt ?? this.completedAt,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
}

@immutable
final class UsageSession {
  const UsageSession({
    required this.id,
    required this.startedAt,
    required this.lastSeenAt,
  });

  final String id;
  final DateTime startedAt;
  final DateTime lastSeenAt;

  UsageSession copyWith({DateTime? lastSeenAt}) => UsageSession(
    id: id,
    startedAt: startedAt,
    lastSeenAt: lastSeenAt ?? this.lastSeenAt,
  );
}

@immutable
final class WeeklyUsagePoint {
  const WeeklyUsagePoint({
    required this.weekStart,
    required this.activeDays,
    required this.sessionCount,
  });

  final DateTime weekStart;
  final int activeDays;
  final int sessionCount;
}

@immutable
final class ProfileHubPosition {
  const ProfileHubPosition({required double x, required double y})
    : x = x < 0 ? 0 : (x > 1 ? 1 : x),
      y = y < 0 ? 0 : (y > 1 ? 1 : y);

  final double x;
  final double y;
}

enum MasterpieceCadence {
  weekly(days: 7, label: '周更'),
  monthly(days: 30, label: '月更');

  const MasterpieceCadence({required this.days, required this.label});

  final int days;
  final String label;

  static MasterpieceCadence fromName(String? name) {
    if (name == 'daily') return MasterpieceCadence.weekly;
    for (final cadence in values) {
      if (cadence.name == name) return cadence;
    }
    return MasterpieceCadence.weekly;
  }
}

@immutable
final class MasterpieceWorkspaceState {
  const MasterpieceWorkspaceState({
    this.isVisible = true,
    this.cadence = MasterpieceCadence.weekly,
    this.markdown,
    this.generatedAt,
    this.includedNoteIds = const <String>[],
    this.isDepositedAsAsset = false,
  });

  final bool isVisible;
  final MasterpieceCadence cadence;
  final String? markdown;
  final DateTime? generatedAt;
  final List<String> includedNoteIds;
  final bool isDepositedAsAsset;

  bool isDueAt(DateTime now) {
    final generated = generatedAt;
    if (generated == null || markdown == null || markdown!.trim().isEmpty) {
      return true;
    }
    return !now.isBefore(generated.add(Duration(days: cadence.days)));
  }

  MasterpieceWorkspaceState copyWith({
    bool? isVisible,
    MasterpieceCadence? cadence,
    String? markdown,
    DateTime? generatedAt,
    List<String>? includedNoteIds,
    bool? isDepositedAsAsset,
    bool clearMarkdown = false,
  }) => MasterpieceWorkspaceState(
    isVisible: isVisible ?? this.isVisible,
    cadence: cadence ?? this.cadence,
    markdown: clearMarkdown ? null : markdown ?? this.markdown,
    generatedAt: clearMarkdown ? null : generatedAt ?? this.generatedAt,
    includedNoteIds: List<String>.unmodifiable(
      includedNoteIds ?? this.includedNoteIds,
    ),
    isDepositedAsAsset: isDepositedAsAsset ?? this.isDepositedAsAsset,
  );
}

@immutable
final class GrowthProgress {
  const GrowthProgress({
    required this.level,
    required this.totalPoints,
    required this.pointsInLevel,
    required this.pointsToNextLevel,
    required this.levelSpan,
  });

  final int level;
  final int totalPoints;
  final int pointsInLevel;
  final int pointsToNextLevel;
  final int levelSpan;

  double get fraction => level >= 10 || levelSpan <= 0
      ? 1
      : (pointsInLevel / levelSpan).clamp(0, 1);
}

const growthDepositThresholds = <int>[0, 5, 12, 22, 35, 51, 70, 92];

GrowthProgress calculateGrowthProgress({
  required int personalContentCount,
  required int explicitDepositCount,
  required int completedCreationCount,
  int positioningStage = 2,
}) {
  final deposits = explicitDepositCount.clamp(0, 1 << 30);
  final stage = positioningStage.clamp(0, 2);
  if (stage < 2) {
    return GrowthProgress(
      level: stage + 1,
      totalPoints: deposits,
      pointsInLevel: 0,
      pointsToNextLevel: 1,
      levelSpan: 1,
    );
  }
  var level = 3;
  for (var index = 1; index < growthDepositThresholds.length; index++) {
    if (deposits < growthDepositThresholds[index]) break;
    level = index + 3;
  }
  final thresholdIndex = level - 3;
  final currentThreshold = growthDepositThresholds[thresholdIndex];
  final nextThreshold = level >= 10
      ? currentThreshold
      : growthDepositThresholds[thresholdIndex + 1];
  final levelSpan = level >= 10 ? 0 : nextThreshold - currentThreshold;
  final pointsInLevel = level >= 10 ? 0 : deposits - currentThreshold;
  return GrowthProgress(
    level: level,
    totalPoints: deposits,
    pointsInLevel: pointsInLevel,
    pointsToNextLevel: level >= 10 ? 0 : nextThreshold - deposits,
    levelSpan: levelSpan,
  );
}
