import 'package:flutter/foundation.dart';

import '../data/first_launch_device_setup_repository.dart';

final class FirstLaunchDeviceSetupController extends ChangeNotifier {
  FirstLaunchDeviceSetupController({
    required FirstLaunchDeviceSetupRepository repository,
    DateTime Function()? now,
  }) : _repositoryForUser = null,
       _repository = repository,
       _activeUserId = repository.userScope,
       _now = now ?? DateTime.now,
       _snapshot = repository.load();

  FirstLaunchDeviceSetupController.accountScoped({
    required FirstLaunchDeviceSetupRepository Function(String userScope)
    repositoryForUser,
    DateTime Function()? now,
  }) : _repositoryForUser = repositoryForUser,
       _now = now ?? DateTime.now;

  final FirstLaunchDeviceSetupRepository Function(String)? _repositoryForUser;
  final DateTime Function() _now;
  FirstLaunchDeviceSetupRepository? _repository;
  String? _activeUserId;
  int _accountRevision = 0;
  bool _disposed = false;
  FirstLaunchDeviceSetupSnapshot _snapshot =
      const FirstLaunchDeviceSetupSnapshot();

  FirstLaunchDeviceSetupSnapshot get snapshot => _snapshot;
  int get accountRevision => _accountRevision;
  FirstLaunchJourneyPhase get phase => _snapshot.phase;
  bool get requiresBlockingJourney =>
      _snapshot.needsPendingMessage &&
      phase != FirstLaunchJourneyPhase.chatRequired;
  bool get requiresChatGuide => phase == FirstLaunchJourneyPhase.chatRequired;
  bool get allowsHome => requiresChatGuide || _snapshot.isComplete;
  bool get requiresPositioning =>
      phase == FirstLaunchJourneyPhase.positioningRequired;
  bool get allowsVoiceprintEnrollment =>
      phase == FirstLaunchJourneyPhase.voiceprintRequired;

  bool syncAccount({
    required String? userId,
    bool positioningRequired = false,
    bool initialPositioningAccepted = false,
    FirstLaunchStepStatus positioningResult = FirstLaunchStepStatus.submitted,
  }) {
    if (_disposed) return false;
    final normalized = userId?.trim();
    final account = normalized == null || normalized.isEmpty
        ? null
        : normalized;
    if (_activeUserId != account) {
      _accountRevision++;
      _activeUserId = account;
      _repository = account == null ? null : _repositoryForUser?.call(account);
      _snapshot = _repository?.load() ?? const FirstLaunchDeviceSetupSnapshot();
      notifyListeners();
    }
    if (account == null || _repository == null) return false;
    if (!_snapshot.hasStarted) {
      if (!positioningRequired) return true;
      if (!beginPositioning(includeChatGuide: true)) return false;
    }
    if (initialPositioningAccepted) {
      return finishPositioning(positioningResult);
    }
    return true;
  }

  bool beginPositioning({bool includeChatGuide = false}) {
    if (_snapshot.hasStarted) return true;
    return _save(
      _snapshot.copyWith(
        positioning: _step(FirstLaunchStepStatus.active),
        chatGuide: includeChatGuide
            ? FirstLaunchChatGuideStage.openChat
            : FirstLaunchChatGuideStage.disabled,
      ),
    );
  }

  bool finishPositioning(
    FirstLaunchStepStatus outcome, {
    int? expectedAccountRevision,
    String? errorCode,
  }) {
    if (!_accepts(expectedAccountRevision) || !_isExit(outcome)) {
      return false;
    }
    final current = _snapshot.positioning;
    if (current.hasExited) {
      if ((current.status == FirstLaunchStepStatus.submitted &&
              outcome == FirstLaunchStepStatus.succeeded) ||
          ((current.status == FirstLaunchStepStatus.deferred ||
                  current.status == FirstLaunchStepStatus.failed) &&
              (outcome == FirstLaunchStepStatus.submitted ||
                  outcome == FirstLaunchStepStatus.succeeded))) {
        return _save(
          _snapshot.copyWith(
            positioning: _step(
              outcome,
              previous: current,
              errorCode: errorCode,
            ),
          ),
        );
      }
      return true;
    }
    return _save(
      _snapshot.copyWith(
        positioning: _step(outcome, previous: current, errorCode: errorCode),
        voiceprint: _step(FirstLaunchStepStatus.active),
      ),
    );
  }

  bool finishVoiceprint(
    FirstLaunchStepStatus outcome, {
    int? expectedAccountRevision,
    String? errorCode,
  }) {
    if (!_accepts(expectedAccountRevision) ||
        !_isExit(outcome) ||
        outcome == FirstLaunchStepStatus.submitted) {
      return false;
    }
    if (_snapshot.voiceprint.hasExited) return true;
    if (!allowsVoiceprintEnrollment) return false;
    return _save(
      _snapshot.copyWith(
        voiceprint: _step(
          outcome,
          previous: _snapshot.voiceprint,
          errorCode: errorCode,
        ),
        recordingCard: _step(FirstLaunchStepStatus.active),
      ),
    );
  }

  bool finishRecordingCard(
    FirstLaunchStepStatus outcome, {
    int? expectedAccountRevision,
    String? serialNumber,
    String? errorCode,
  }) {
    if (!_accepts(expectedAccountRevision) ||
        !_isExit(outcome) ||
        outcome == FirstLaunchStepStatus.submitted) {
      return false;
    }
    if (_snapshot.recordingCard.hasExited) return true;
    if (phase != FirstLaunchJourneyPhase.recordingCardRequired) return false;
    final serial = normalizeFirstLaunchRecordingCardSerial(serialNumber);
    if (outcome == FirstLaunchStepStatus.succeeded && serial == null) {
      return false;
    }
    return _save(
      _snapshot.copyWith(
        recordingCard: _step(
          outcome,
          previous: _snapshot.recordingCard,
          errorCode: errorCode,
        ),
        recordingCardSerial: outcome == FirstLaunchStepStatus.succeeded
            ? serial
            : null,
      ),
    );
  }

  bool openChatGuide({required int expectedAccountRevision}) {
    if (!_accepts(expectedAccountRevision) || !requiresChatGuide) return false;
    if (_snapshot.chatGuide == FirstLaunchChatGuideStage.sendMessage) {
      return true;
    }
    return _save(
      _snapshot.copyWith(chatGuide: FirstLaunchChatGuideStage.sendMessage),
    );
  }

  bool completeChatGuide({required int expectedAccountRevision}) {
    if (!_accepts(expectedAccountRevision)) return false;
    if (_snapshot.chatGuide == FirstLaunchChatGuideStage.completed) return true;
    if (!requiresChatGuide ||
        _snapshot.chatGuide != FirstLaunchChatGuideStage.sendMessage) {
      return false;
    }
    return _save(
      _snapshot.copyWith(chatGuide: FirstLaunchChatGuideStage.completed),
    );
  }

  bool skipChatGuide() {
    if (!_accepts(null) || !requiresChatGuide) return false;
    return _save(
      _snapshot.copyWith(chatGuide: FirstLaunchChatGuideStage.skipped),
    );
  }

  bool _accepts(int? expected) =>
      !_disposed &&
      _repository != null &&
      (expected == null || expected == _accountRevision);

  bool _isExit(FirstLaunchStepStatus status) => switch (status) {
    FirstLaunchStepStatus.pending || FirstLaunchStepStatus.active => false,
    _ => true,
  };

  FirstLaunchStepSnapshot _step(
    FirstLaunchStepStatus status, {
    FirstLaunchStepSnapshot? previous,
    String? errorCode,
  }) {
    final now = _now().toUtc();
    final previousAt = previous?.updatedAt;
    return FirstLaunchStepSnapshot(
      status: status,
      updatedAt: previousAt != null && now.isBefore(previousAt)
          ? previousAt
          : now,
      errorCode: status == FirstLaunchStepStatus.failed && errorCode != null
          ? (RegExp(r'^[A-Z0-9_]{1,120}$').hasMatch(errorCode)
                ? errorCode
                : 'STARTUP_STEP_FAILED')
          : null,
    );
  }

  bool _save(FirstLaunchDeviceSetupSnapshot next) {
    if (_disposed ||
        _repository?.save(snapshot: next, updatedAt: _now()) != true) {
      return false;
    }
    _snapshot = next;
    notifyListeners();
    return true;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
