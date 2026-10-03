import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../../core/database/app_preferences_dao.dart';

enum FirstLaunchJourneyPhase {
  notStarted,
  positioningRequired,
  voiceprintRequired,
  recordingCardRequired,
  chatRequired,
  completed,
}

enum FirstLaunchChatGuideStage {
  disabled,
  openChat,
  sendMessage,
  completed,
  skipped,
}

enum FirstLaunchStepStatus {
  pending,
  active,
  submitted,
  succeeded,
  deferred,
  failed,
}

final class FirstLaunchStepSnapshot {
  const FirstLaunchStepSnapshot({
    this.status = FirstLaunchStepStatus.pending,
    this.updatedAt,
    this.errorCode,
  });

  final FirstLaunchStepStatus status;
  final DateTime? updatedAt;
  final String? errorCode;

  bool get hasExited => switch (status) {
    FirstLaunchStepStatus.pending || FirstLaunchStepStatus.active => false,
    _ => true,
  };

  bool get isConsistent =>
      (status == FirstLaunchStepStatus.pending
          ? updatedAt == null
          : updatedAt != null) &&
      (errorCode == null ||
          (status == FirstLaunchStepStatus.failed &&
              RegExp(r'^[A-Z0-9_]{1,120}$').hasMatch(errorCode!)));

  Map<String, Object?> toJson() => {
    'status': status.name,
    if (updatedAt != null) 'updatedAt': updatedAt!.toUtc().toIso8601String(),
    if (errorCode != null) 'errorCode': errorCode,
  };
}

final class FirstLaunchDeviceSetupSnapshot {
  const FirstLaunchDeviceSetupSnapshot({
    this.positioning = const FirstLaunchStepSnapshot(),
    this.voiceprint = const FirstLaunchStepSnapshot(),
    this.recordingCard = const FirstLaunchStepSnapshot(),
    this.recordingCardSerial,
    this.chatGuide = FirstLaunchChatGuideStage.disabled,
  });

  final FirstLaunchStepSnapshot positioning;
  final FirstLaunchStepSnapshot voiceprint;
  final FirstLaunchStepSnapshot recordingCard;
  final String? recordingCardSerial;
  final FirstLaunchChatGuideStage chatGuide;

  bool get hasChatGuide => chatGuide != FirstLaunchChatGuideStage.disabled;
  bool get chatGuidePending =>
      chatGuide == FirstLaunchChatGuideStage.openChat ||
      chatGuide == FirstLaunchChatGuideStage.sendMessage;

  FirstLaunchJourneyPhase get phase {
    if (positioning.status == FirstLaunchStepStatus.pending) {
      return FirstLaunchJourneyPhase.notStarted;
    }
    if (!positioning.hasExited) {
      return FirstLaunchJourneyPhase.positioningRequired;
    }
    if (!voiceprint.hasExited) {
      return FirstLaunchJourneyPhase.voiceprintRequired;
    }
    if (!recordingCard.hasExited) {
      return FirstLaunchJourneyPhase.recordingCardRequired;
    }
    if (chatGuidePending) return FirstLaunchJourneyPhase.chatRequired;
    return FirstLaunchJourneyPhase.completed;
  }

  bool get hasStarted => positioning.status != FirstLaunchStepStatus.pending;
  bool get isComplete => phase == FirstLaunchJourneyPhase.completed;
  bool get needsPendingMessage => hasStarted && !isComplete;

  bool get isConsistent =>
      positioning.isConsistent &&
      voiceprint.isConsistent &&
      recordingCard.isConsistent &&
      (!hasChatGuide || hasStarted) &&
      (chatGuide == FirstLaunchChatGuideStage.disabled ||
          chatGuide == FirstLaunchChatGuideStage.openChat ||
          recordingCard.hasExited) &&
      voiceprint.status != FirstLaunchStepStatus.submitted &&
      recordingCard.status != FirstLaunchStepStatus.submitted &&
      (voiceprint.status == FirstLaunchStepStatus.pending ||
          positioning.hasExited) &&
      (recordingCard.status == FirstLaunchStepStatus.pending ||
          voiceprint.hasExited) &&
      (recordingCard.status == FirstLaunchStepStatus.succeeded
          ? recordingCardSerial != null &&
                normalizeFirstLaunchRecordingCardSerial(recordingCardSerial) ==
                    recordingCardSerial
          : recordingCardSerial == null);

  FirstLaunchDeviceSetupSnapshot copyWith({
    FirstLaunchStepSnapshot? positioning,
    FirstLaunchStepSnapshot? voiceprint,
    FirstLaunchStepSnapshot? recordingCard,
    String? recordingCardSerial,
    FirstLaunchChatGuideStage? chatGuide,
  }) => FirstLaunchDeviceSetupSnapshot(
    positioning: positioning ?? this.positioning,
    voiceprint: voiceprint ?? this.voiceprint,
    recordingCard: recordingCard ?? this.recordingCard,
    recordingCardSerial: recordingCardSerial ?? this.recordingCardSerial,
    chatGuide: chatGuide ?? this.chatGuide,
  );
}

final class FirstLaunchDeviceSetupRepository {
  FirstLaunchDeviceSetupRepository({
    required AppPreferencesDao dao,
    required String userScope,
  }) : _dao = dao,
       userScope = _normalizeUserScope(userScope),
       preferenceKey = _keyFor(userScope);

  final AppPreferencesDao _dao;
  final String userScope;
  final String preferenceKey;

  FirstLaunchDeviceSetupSnapshot load() {
    final encoded = _dao.readValue(preferenceKey);
    if (encoded == null) return const FirstLaunchDeviceSetupSnapshot();
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is! Map<String, dynamic>) return _recoverySnapshot();
      if (decoded['version'] == 2 || decoded['version'] == 3) {
        return _migrateLegacy(decoded);
      }
      if (decoded['version'] != 4 && decoded['version'] != 5) {
        return _recoverySnapshot();
      }
      final chatGuide = decoded['version'] == 4
          ? FirstLaunchChatGuideStage.disabled
          : FirstLaunchChatGuideStage.values
                .where((stage) => stage.name == decoded['chatGuide'])
                .firstOrNull;
      if (chatGuide == null) return _recoverySnapshot();
      final positioning = _readStep(decoded['positioning']);
      final voiceprint = _readStep(decoded['voiceprint']);
      final recordingCard = _readStep(decoded['recordingCard']);
      final serial = decoded['recordingCardSerial'];
      if (positioning == null ||
          voiceprint == null ||
          recordingCard == null ||
          (serial != null && serial is! String)) {
        return _recoverySnapshot();
      }
      final snapshot = FirstLaunchDeviceSetupSnapshot(
        positioning: positioning,
        voiceprint: voiceprint,
        recordingCard: recordingCard,
        recordingCardSerial: serial as String?,
        chatGuide: chatGuide,
      );
      return snapshot.isConsistent ? snapshot : _recoverySnapshot();
    } on Object {
      return _recoverySnapshot();
    }
  }

  bool save({
    required FirstLaunchDeviceSetupSnapshot snapshot,
    required DateTime updatedAt,
  }) {
    if (!snapshot.isConsistent) return false;
    try {
      final current = load();
      final guideForward =
          current.chatGuide == snapshot.chatGuide ||
          switch (current.chatGuide) {
            FirstLaunchChatGuideStage.disabled =>
              !current.hasStarted &&
                  snapshot.chatGuide == FirstLaunchChatGuideStage.openChat,
            FirstLaunchChatGuideStage.openChat =>
              snapshot.chatGuide == FirstLaunchChatGuideStage.sendMessage ||
                  snapshot.chatGuide == FirstLaunchChatGuideStage.skipped,
            FirstLaunchChatGuideStage.sendMessage =>
              snapshot.chatGuide == FirstLaunchChatGuideStage.completed ||
                  snapshot.chatGuide == FirstLaunchChatGuideStage.skipped,
            _ => false,
          };
      if (!guideForward ||
          !_isForwardStep(current.positioning, snapshot.positioning) ||
          !_isForwardStep(current.voiceprint, snapshot.voiceprint) ||
          !_isForwardStep(current.recordingCard, snapshot.recordingCard) ||
          (current.recordingCardSerial != null &&
              current.recordingCardSerial != snapshot.recordingCardSerial)) {
        return false;
      }
      _dao.upsertValue(
        preferenceKey: preferenceKey,
        value: jsonEncode({
          'version': 5,
          'chatGuide': snapshot.chatGuide.name,
          'positioning': snapshot.positioning.toJson(),
          'voiceprint': snapshot.voiceprint.toJson(),
          'recordingCard': snapshot.recordingCard.toJson(),
          if (snapshot.recordingCardSerial != null)
            'recordingCardSerial': snapshot.recordingCardSerial,
        }),
        updatedAt: updatedAt.toUtc().toIso8601String(),
      );
      return true;
    } on Object {
      return false;
    }
  }

  static String _keyFor(String userScope) {
    final digest = sha256.convert(utf8.encode(_normalizeUserScope(userScope)));
    return 'onboarding.first-launch-device-guide.v2.${digest.toString().substring(0, 24)}';
  }

  static String _normalizeUserScope(String value) {
    final normalized = value.trim();
    if (normalized.isEmpty || normalized == 'anonymous') {
      throw ArgumentError.value(value, 'userScope', 'requires an account');
    }
    return normalized;
  }
}

bool _isForwardStep(
  FirstLaunchStepSnapshot current,
  FirstLaunchStepSnapshot next,
) {
  if (current.status == next.status) {
    return current.updatedAt == next.updatedAt &&
        current.errorCode == next.errorCode;
  }
  if (current.updatedAt != null &&
      (next.updatedAt == null ||
          next.updatedAt!.isBefore(current.updatedAt!))) {
    return false;
  }
  return switch (current.status) {
    FirstLaunchStepStatus.pending =>
      next.status != FirstLaunchStepStatus.pending,
    FirstLaunchStepStatus.active => next.hasExited,
    FirstLaunchStepStatus.submitted =>
      next.status == FirstLaunchStepStatus.succeeded ||
          next.status == FirstLaunchStepStatus.failed,
    _ => false,
  };
}

FirstLaunchStepSnapshot? _readStep(Object? value) {
  if (value is! Map<String, dynamic>) return null;
  final status = FirstLaunchStepStatus.values
      .where((candidate) => candidate.name == value['status'])
      .firstOrNull;
  final updatedAt = _date(value['updatedAt']);
  final errorCode = value['errorCode'];
  if (status == null ||
      (value['updatedAt'] != null && updatedAt == null) ||
      (errorCode != null && errorCode is! String)) {
    return null;
  }
  final step = FirstLaunchStepSnapshot(
    status: status,
    updatedAt: updatedAt,
    errorCode: errorCode as String?,
  );
  return step.isConsistent ? step : null;
}

FirstLaunchDeviceSetupSnapshot _migrateLegacy(Map<String, dynamic> value) {
  if (value['version'] == 2) {
    if (value['autoPresentationClaimed'] == false &&
        value['voiceprintGuideViewed'] == false &&
        value['recordingCardGuideViewed'] == false) {
      return const FirstLaunchDeviceSetupSnapshot();
    }
    if (value['autoPresentationClaimed'] != true) return _recoverySnapshot();
    final at =
        _date(value['claimedAt']) ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    return FirstLaunchDeviceSetupSnapshot(
      positioning: FirstLaunchStepSnapshot(
        status: FirstLaunchStepStatus.deferred,
        updatedAt: at,
      ),
      voiceprint: FirstLaunchStepSnapshot(
        status: FirstLaunchStepStatus.active,
        updatedAt: at,
      ),
    );
  }
  final phase = value['phase'];
  if (phase == 'notStarted') {
    final hasMilestone = <String>[
      'startedAt',
      'reportNoticeAcknowledgedAt',
      'voiceprintCompletedAt',
      'recordingCardConnectedAt',
      'completedAt',
      'recordingCardSerial',
    ].any((key) => value[key] != null);
    return hasMilestone
        ? _recoverySnapshot()
        : const FirstLaunchDeviceSetupSnapshot();
  }
  final startedAt = _date(value['startedAt']);
  final noticeAt = _date(value['reportNoticeAcknowledgedAt']);
  final voiceprintAt = _date(value['voiceprintCompletedAt']);
  final cardAt = _date(value['recordingCardConnectedAt']);
  final completedAt = _date(value['completedAt']);
  final milestones = [startedAt, noticeAt, voiceprintAt, cardAt, completedAt];
  for (var index = 1; index < milestones.length; index++) {
    if (milestones[index] != null &&
        (milestones[index - 1] == null ||
            milestones[index]!.isBefore(milestones[index - 1]!))) {
      return _recoverySnapshot();
    }
  }
  final count = switch (phase) {
    'reportQueuedNotice' => 1,
    'voiceprintRequired' => 2,
    'recordingCardRequired' => 3,
    'recordingCardConnected' => 4,
    'completed' => 5,
    _ => 0,
  };
  if (count == 0 ||
      milestones.take(count).any((value) => value == null) ||
      milestones.skip(count).any((value) => value != null)) {
    return _recoverySnapshot();
  }
  final serial = value['recordingCardSerial'];
  if (count < 4 && serial != null) return _recoverySnapshot();
  if (count >= 4 &&
      (serial is! String ||
          normalizeFirstLaunchRecordingCardSerial(serial) != serial)) {
    return _recoverySnapshot();
  }
  return FirstLaunchDeviceSetupSnapshot(
    positioning: FirstLaunchStepSnapshot(
      status: FirstLaunchStepStatus.submitted,
      updatedAt: startedAt,
    ),
    voiceprint: FirstLaunchStepSnapshot(
      status: count >= 3
          ? FirstLaunchStepStatus.succeeded
          : FirstLaunchStepStatus.active,
      updatedAt: voiceprintAt ?? noticeAt ?? startedAt,
    ),
    recordingCard: count >= 3
        ? FirstLaunchStepSnapshot(
            status: count >= 4
                ? FirstLaunchStepStatus.succeeded
                : FirstLaunchStepStatus.active,
            updatedAt: cardAt ?? voiceprintAt,
          )
        : const FirstLaunchStepSnapshot(),
    recordingCardSerial: count >= 4 ? serial as String : null,
  );
}

FirstLaunchDeviceSetupSnapshot _recoverySnapshot() =>
    FirstLaunchDeviceSetupSnapshot(
      positioning: FirstLaunchStepSnapshot(
        status: FirstLaunchStepStatus.active,
        updatedAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      ),
    );

DateTime? _date(Object? value) => value is String && value.length <= 64
    ? DateTime.tryParse(value)?.toUtc()
    : null;

String? normalizeFirstLaunchRecordingCardSerial(String? value) {
  if (value == null) return null;
  final normalized = value.trim();
  if (normalized.isEmpty ||
      normalized.length > 96 ||
      normalized.contains(RegExp(r'[\u0000-\u001F\u007F]'))) {
    return null;
  }
  return normalized;
}
