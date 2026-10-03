enum ChatRunReconciliationPhase {
  awaitingReadback,
  reading,
  retryScheduled,
  recoveryRequired,
  settled,
}

final class ChatRunReconciliationSnapshot {
  const ChatRunReconciliationSnapshot({
    required this.phase,
    required this.failures,
    this.failureCode,
    this.retryAt,
  });

  final ChatRunReconciliationPhase phase;
  final int failures;
  final String? failureCode;
  final DateTime? retryAt;
}

final class ChatRunReconciliation {
  ChatRunReconciliation();

  static const maximumAutomaticFailures = 4;

  ChatRunReconciliationPhase _phase =
      ChatRunReconciliationPhase.awaitingReadback;
  int _failures = 0;
  String? _failureCode;
  DateTime? _retryAt;

  ChatRunReconciliationSnapshot get snapshot => ChatRunReconciliationSnapshot(
    phase: _phase,
    failures: _failures,
    failureCode: _failureCode,
    retryAt: _retryAt,
  );

  bool get canScheduleAutomatically =>
      _phase != ChatRunReconciliationPhase.recoveryRequired &&
      _phase != ChatRunReconciliationPhase.settled;

  bool beginAttempt(DateTime now, {bool userInitiated = false}) {
    if (_phase == ChatRunReconciliationPhase.reading ||
        _phase == ChatRunReconciliationPhase.settled) {
      return false;
    }
    if (userInitiated) {
      _failures = 0;
      _failureCode = null;
    } else if (!canScheduleAutomatically || (_retryAt?.isAfter(now) ?? false)) {
      return false;
    }
    _phase = ChatRunReconciliationPhase.reading;
    _retryAt = null;
    return true;
  }

  void fail({required String code, required DateTime retryAt}) {
    if (_phase != ChatRunReconciliationPhase.reading) return;
    _failures += 1;
    _failureCode = _safeFailureCode(code) ?? 'CHAT_RUN_READBACK_FAILED';
    if (_failures >= maximumAutomaticFailures) {
      _phase = ChatRunReconciliationPhase.recoveryRequired;
      _retryAt = null;
    } else {
      _phase = ChatRunReconciliationPhase.retryScheduled;
      _retryAt = retryAt.toUtc();
    }
  }

  void cancelAttempt() {
    if (_phase == ChatRunReconciliationPhase.reading) {
      _phase = ChatRunReconciliationPhase.awaitingReadback;
    }
  }

  void settle() {
    _phase = ChatRunReconciliationPhase.settled;
    _failureCode = null;
    _retryAt = null;
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'phase': _phase.name,
    'failures': _failures,
    if (_failureCode != null) 'failureCode': _failureCode,
    if (_retryAt != null) 'retryAt': _retryAt!.toIso8601String(),
  };

  factory ChatRunReconciliation.fromJson(Object? value) {
    final state = ChatRunReconciliation();
    if (value is! Map) return state;
    final failures = value['failures'];
    if (failures is int && failures >= 0) {
      state._failures = failures.clamp(0, maximumAutomaticFailures);
    }
    state._failureCode = _safeFailureCode(value['failureCode']);
    final retryAt = value['retryAt'];
    if (retryAt is String) state._retryAt = DateTime.tryParse(retryAt)?.toUtc();
    if (value['phase'] == ChatRunReconciliationPhase.recoveryRequired.name ||
        state._failures >= maximumAutomaticFailures) {
      state._phase = ChatRunReconciliationPhase.recoveryRequired;
      state._retryAt = null;
    } else if (value['phase'] ==
            ChatRunReconciliationPhase.retryScheduled.name &&
        state._retryAt != null) {
      state._phase = ChatRunReconciliationPhase.retryScheduled;
    } else {
      state._retryAt = null;
    }
    return state;
  }
}

String? _safeFailureCode(Object? value) =>
    value is String && RegExp(r'^[A-Z][A-Z0-9_]{0,127}$').hasMatch(value)
    ? value
    : null;
