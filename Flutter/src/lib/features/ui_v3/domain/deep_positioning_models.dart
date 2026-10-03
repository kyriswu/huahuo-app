import 'package:flutter/foundation.dart';
import 'package:huahuo_api/huahuo_api.dart';

@immutable
final class DeepPositioningDraft {
  const DeepPositioningDraft({
    this.identity = '',
    this.industry = '',
    this.expertise = '',
    this.targetAudience = '',
    this.value = '',
    this.accountGoal = '',
    this.stories = '',
    this.commonExpressions = '',
  });

  final String identity;
  final String industry;
  final String expertise;
  final String targetAudience;
  final String value;
  final String accountGoal;
  final String stories;
  final String commonExpressions;

  bool get isValid =>
      identity.trim().isNotEmpty &&
      industry.trim().isNotEmpty &&
      expertise.trim().isNotEmpty &&
      targetAudience.trim().isNotEmpty &&
      value.trim().isNotEmpty &&
      accountGoal.trim().isNotEmpty;

  DeepPositioningDraft copyWith({
    String? identity,
    String? industry,
    String? expertise,
    String? targetAudience,
    String? value,
    String? accountGoal,
    String? stories,
    String? commonExpressions,
  }) => DeepPositioningDraft(
    identity: identity ?? this.identity,
    industry: industry ?? this.industry,
    expertise: expertise ?? this.expertise,
    targetAudience: targetAudience ?? this.targetAudience,
    value: value ?? this.value,
    accountGoal: accountGoal ?? this.accountGoal,
    stories: stories ?? this.stories,
    commonExpressions: commonExpressions ?? this.commonExpressions,
  );
}

@immutable
final class DeepPositioningResult {
  const DeepPositioningResult({
    required this.markdown,
    required this.savedAt,
    this.isDemo = false,
    this.initialCompletedAt,
    this.furtherCompletedAt,
    this.progress,
    this.serverPositioningStage,
    this.formalVerified = false,
    this.formalContentDigest,
  });

  final String markdown;
  final DateTime savedAt;
  final bool isDemo;
  final DateTime? initialCompletedAt;
  final DateTime? furtherCompletedAt;
  final PositioningProgressProfile? progress;
  final int? serverPositioningStage;
  final bool formalVerified;
  final String? formalContentDigest;

  int get positioningStage {
    final persistedStage = furtherCompletedAt != null
        ? 2
        : initialCompletedAt != null
        ? 1
        : 0;
    final serverStage = serverPositioningStage?.clamp(0, 2) ?? 0;
    return serverStage > persistedStage ? serverStage : persistedStage;
  }
}

enum PositioningReportOrigin {
  remote,
  verifiedCache,
  legacyCache,
  absent,
  unavailable,
}

@immutable
final class PositioningReportRead {
  const PositioningReportRead(this.origin, {this.report, this.errorCode});

  final PositioningReportOrigin origin;
  final DeepPositioningResult? report;
  final String? errorCode;

  bool get isRemote => origin == PositioningReportOrigin.remote;
  bool get provesCompletion =>
      isRemote || origin == PositioningReportOrigin.verifiedCache;
}

@immutable
final class DeepPositioningConversationEntry {
  const DeepPositioningConversationEntry({
    required this.text,
    required this.isAssistant,
  });

  final String text;
  final bool isAssistant;
}
