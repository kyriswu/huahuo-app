import 'dart:async';

import 'package:flutter/services.dart';

enum HomeWidgetRecordingState { disconnected, idle, recording, paused }

final class HomeWidgetRecordingActionBinding {
  HomeWidgetRecordingActionBinding({this.token, this.deviceFingerprint});

  final String? token;
  final String? deviceFingerprint;
  int _consumedRevision = 0;

  bool authorizes(String? candidate, int? revision, DateTime now) {
    if (token == null ||
        candidate != token ||
        deviceFingerprint == null ||
        revision == null ||
        revision <= _consumedRevision) {
      return false;
    }
    final age = now.millisecondsSinceEpoch - revision;
    return age >= 0 && age < const Duration(minutes: 30).inMilliseconds;
  }

  bool claim(String? candidate, int? revision, DateTime now) {
    if (!authorizes(candidate, revision, now)) return false;
    _consumedRevision = revision!;
    return true;
  }
}

final class HomeWidgetSnapshot {
  factory HomeWidgetSnapshot({
    required bool isAuthenticated,
    required int personalContentCount,
    required int depositedContentCount,
    required int level,
    required int pointsInLevel,
    required HomeWidgetRecordingState recordingState,
    required DateTime updatedAt,
    required int levelSpan,
    String? recordingActionToken,
    int? recordingCardBatteryPercent,
    int recordingElapsedSeconds = 0,
  }) {
    final authenticated = isAuthenticated;
    final connected =
        authenticated &&
        recordingState != HomeWidgetRecordingState.disconnected;
    final normalizedLevel = authenticated ? _bounded(level, 1, 10) : 1;
    final normalizedSpan = !authenticated
        ? 1
        : normalizedLevel == 10
        ? 0
        : _bounded(levelSpan, 1, 1000000);
    return HomeWidgetSnapshot._(
      isAuthenticated: authenticated,
      personalContentCount: authenticated
          ? _bounded(personalContentCount, 0, 1000000)
          : 0,
      depositedContentCount: authenticated
          ? _bounded(depositedContentCount, 0, 1000000)
          : 0,
      level: normalizedLevel,
      levelSpan: normalizedSpan,
      pointsInLevel: authenticated
          ? _bounded(pointsInLevel, 0, normalizedSpan)
          : 0,
      recordingActionToken:
          connected &&
              recordingActionToken != null &&
              RegExp(r'^[a-f0-9]{64}$').hasMatch(recordingActionToken)
          ? recordingActionToken
          : null,
      recordingState: connected
          ? recordingState
          : HomeWidgetRecordingState.disconnected,
      recordingCardBatteryPercent:
          connected && recordingCardBatteryPercent != null
          ? _bounded(recordingCardBatteryPercent, 0, 100)
          : null,
      recordingElapsedSeconds:
          connected && recordingState != HomeWidgetRecordingState.idle
          ? _bounded(recordingElapsedSeconds, 0, 86400000)
          : 0,
      updatedAt: updatedAt.toUtc(),
    );
  }

  const HomeWidgetSnapshot._({
    required this.isAuthenticated,
    required this.personalContentCount,
    required this.depositedContentCount,
    required this.level,
    required this.pointsInLevel,
    required this.levelSpan,
    required this.recordingActionToken,
    required this.recordingState,
    required this.recordingElapsedSeconds,
    required this.updatedAt,
    this.recordingCardBatteryPercent,
  });

  final bool isAuthenticated;
  final int personalContentCount;
  final int depositedContentCount;
  final int level;
  final int pointsInLevel;
  final int levelSpan;
  final String? recordingActionToken;
  final HomeWidgetRecordingState recordingState;
  final int recordingElapsedSeconds;
  final int? recordingCardBatteryPercent;
  final DateTime updatedAt;

  Map<String, Object> toChannelMap() => <String, Object>{
    'schemaVersion': 3,
    'isAuthenticated': isAuthenticated,
    'personalContentCount': personalContentCount,
    'depositedContentCount': depositedContentCount,
    'level': level,
    'pointsInLevel': pointsInLevel,
    'levelSpan': levelSpan,
    if (recordingActionToken case final token?) 'recordingActionToken': token,
    'recordingState': recordingState.name,
    'recordingElapsedSeconds': recordingElapsedSeconds,
    if (recordingCardBatteryPercent case final battery?)
      'recordingCardBatteryPercent': battery,
    'updatedAtEpochMs': updatedAt.millisecondsSinceEpoch,
  };

  @override
  bool operator ==(Object other) =>
      other is HomeWidgetSnapshot &&
      other.isAuthenticated == isAuthenticated &&
      other.personalContentCount == personalContentCount &&
      other.depositedContentCount == depositedContentCount &&
      other.level == level &&
      other.pointsInLevel == pointsInLevel &&
      other.levelSpan == levelSpan &&
      other.recordingActionToken == recordingActionToken &&
      other.recordingState == recordingState &&
      other.recordingElapsedSeconds == recordingElapsedSeconds &&
      other.recordingCardBatteryPercent == recordingCardBatteryPercent;

  @override
  int get hashCode => Object.hash(
    isAuthenticated,
    personalContentCount,
    depositedContentCount,
    level,
    pointsInLevel,
    levelSpan,
    recordingActionToken,
    recordingState,
    recordingElapsedSeconds,
    recordingCardBatteryPercent,
  );
}

abstract interface class HomeWidgetPort {
  Future<bool> update(HomeWidgetSnapshot snapshot);
}

final class MethodChannelHomeWidgetPort implements HomeWidgetPort {
  MethodChannelHomeWidgetPort({
    MethodChannel? channel,
    this.timeout = const Duration(seconds: 5),
  }) : _channel = channel ?? const MethodChannel(_channelName);

  static const _channelName = 'huahuoai/home_widgets';

  final MethodChannel _channel;
  final Duration timeout;

  @override
  Future<bool> update(HomeWidgetSnapshot snapshot) async {
    try {
      return await _channel
              .invokeMethod<bool>('updateSnapshot', snapshot.toChannelMap())
              .timeout(timeout) ==
          true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    } on TimeoutException {
      return false;
    }
  }
}

int _bounded(int value, int minimum, int maximum) =>
    value < minimum ? minimum : (value > maximum ? maximum : value);
