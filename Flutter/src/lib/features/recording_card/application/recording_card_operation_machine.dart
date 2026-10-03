import 'package:flutter/foundation.dart';

enum RecordingCardOperationKind {
  discovery,
  connection,
  connectionReconciliation,
  deviceRefresh,
  recordingControl,
  directoryRefresh,
  bluetoothTransfer,
  wifiTransfer,
  fileDeletion,
  deviceConfiguration,
  accountBinding,
  disconnect,
  unbind,
}

enum RecordingCardOperationOrigin { user, automatic }

enum RecordingCardOperationPhase {
  idle,
  running,
  cancelling,
  cancelled,
  succeeded,
  failed,
  interrupted,
}

@immutable
final class RecordingCardOperationLease {
  const RecordingCardOperationLease({
    required this.generation,
    required this.kind,
    required this.origin,
    required this.connectionRevision,
  });

  final int generation;
  final RecordingCardOperationKind kind;
  final RecordingCardOperationOrigin origin;
  final int connectionRevision;
}

@immutable
final class RecordingCardOperationState {
  const RecordingCardOperationState({
    required this.phase,
    required this.generation,
    this.kind,
    this.origin,
    this.connectionRevision,
    this.errorCode,
    this.blockedKind,
    this.blockedOrigin,
    this.blockCode,
  });

  const RecordingCardOperationState.idle()
    : this(phase: RecordingCardOperationPhase.idle, generation: 0);

  final RecordingCardOperationPhase phase;
  final int generation;
  final RecordingCardOperationKind? kind;
  final RecordingCardOperationOrigin? origin;
  final int? connectionRevision;
  final String? errorCode;
  final RecordingCardOperationKind? blockedKind;
  final RecordingCardOperationOrigin? blockedOrigin;
  final String? blockCode;

  bool get isActive =>
      phase == RecordingCardOperationPhase.running ||
      phase == RecordingCardOperationPhase.cancelling;

  bool get hasTerminalOutcome => switch (phase) {
    RecordingCardOperationPhase.cancelled ||
    RecordingCardOperationPhase.succeeded ||
    RecordingCardOperationPhase.failed ||
    RecordingCardOperationPhase.interrupted => true,
    _ => false,
  };

  bool get hasBlockedIntent => blockCode != null;

  RecordingCardOperationState withBlock({
    required RecordingCardOperationKind kind,
    required RecordingCardOperationOrigin origin,
    required String code,
  }) {
    return RecordingCardOperationState(
      phase: phase,
      generation: generation,
      kind: this.kind,
      origin: this.origin,
      connectionRevision: connectionRevision,
      errorCode: errorCode,
      blockedKind: kind,
      blockedOrigin: origin,
      blockCode: code,
    );
  }
}

@immutable
final class RecordingCardOperationAdmission {
  const RecordingCardOperationAdmission._({
    required this.state,
    this.lease,
    this.failureCode,
  });

  factory RecordingCardOperationAdmission.admitted({
    required RecordingCardOperationState state,
    required RecordingCardOperationLease lease,
  }) {
    return RecordingCardOperationAdmission._(state: state, lease: lease);
  }

  factory RecordingCardOperationAdmission.blocked({
    required RecordingCardOperationState state,
    required String failureCode,
  }) {
    return RecordingCardOperationAdmission._(
      state: state,
      failureCode: failureCode,
    );
  }

  final RecordingCardOperationState state;
  final RecordingCardOperationLease? lease;
  final String? failureCode;

  bool get admitted => lease != null;
  bool get deferred => failureCode == recordingCardOperationDeferredCode;
}

const recordingCardOperationBusyCode = 'RECORDING_CARD_OPERATION_BUSY';
const recordingCardOperationDeferredCode = 'RECORDING_CARD_OPERATION_DEFERRED';
const recordingCardOperationSessionChangedCode =
    'RECORDING_CARD_OPERATION_SESSION_CHANGED';

final class RecordingCardOperationMachine {
  RecordingCardOperationState _state = const RecordingCardOperationState.idle();
  int _generation = 0;

  RecordingCardOperationState get state => _state;

  RecordingCardOperationAdmission begin({
    required RecordingCardOperationKind kind,
    required RecordingCardOperationOrigin origin,
    required int connectionRevision,
  }) {
    if (_state.isActive) {
      final code = origin == RecordingCardOperationOrigin.automatic
          ? recordingCardOperationDeferredCode
          : recordingCardOperationBusyCode;
      _state = _state.withBlock(kind: kind, origin: origin, code: code);
      return RecordingCardOperationAdmission.blocked(
        state: _state,
        failureCode: code,
      );
    }
    final lease = RecordingCardOperationLease(
      generation: ++_generation,
      kind: kind,
      origin: origin,
      connectionRevision: connectionRevision,
    );
    _state = RecordingCardOperationState(
      phase: RecordingCardOperationPhase.running,
      generation: lease.generation,
      kind: kind,
      origin: origin,
      connectionRevision: connectionRevision,
    );
    return RecordingCardOperationAdmission.admitted(
      state: _state,
      lease: lease,
    );
  }

  RecordingCardOperationAdmission block({
    required RecordingCardOperationKind kind,
    required RecordingCardOperationOrigin origin,
  }) {
    final code = origin == RecordingCardOperationOrigin.automatic
        ? recordingCardOperationDeferredCode
        : recordingCardOperationBusyCode;
    _state = _state.withBlock(kind: kind, origin: origin, code: code);
    return RecordingCardOperationAdmission.blocked(
      state: _state,
      failureCode: code,
    );
  }

  RecordingCardOperationAdmission supersede({
    required RecordingCardOperationKind kind,
    required RecordingCardOperationOrigin origin,
    required int connectionRevision,
  }) {
    if (!_state.isActive) {
      return begin(
        kind: kind,
        origin: origin,
        connectionRevision: connectionRevision,
      );
    }
    final lease = RecordingCardOperationLease(
      generation: ++_generation,
      kind: kind,
      origin: origin,
      connectionRevision: connectionRevision,
    );
    _state = RecordingCardOperationState(
      phase: RecordingCardOperationPhase.running,
      generation: lease.generation,
      kind: kind,
      origin: origin,
      connectionRevision: connectionRevision,
    );
    return RecordingCardOperationAdmission.admitted(
      state: _state,
      lease: lease,
    );
  }

  bool owns(RecordingCardOperationLease? lease) {
    return lease != null &&
        _state.isActive &&
        lease.generation == _state.generation &&
        lease.kind == _state.kind &&
        lease.connectionRevision == _state.connectionRevision;
  }

  bool requestCancellation(RecordingCardOperationLease lease) {
    if (!owns(lease)) return false;
    _state = RecordingCardOperationState(
      phase: RecordingCardOperationPhase.cancelling,
      generation: _state.generation,
      kind: _state.kind,
      origin: _state.origin,
      connectionRevision: _state.connectionRevision,
      blockedKind: _state.blockedKind,
      blockedOrigin: _state.blockedOrigin,
      blockCode: _state.blockCode,
    );
    return true;
  }

  bool cancel(RecordingCardOperationLease lease, {String? errorCode}) =>
      _settle(
        lease,
        RecordingCardOperationPhase.cancelled,
        errorCode: errorCode,
      );

  bool rejectCancellation(RecordingCardOperationLease lease) {
    if (!owns(lease) ||
        _state.phase != RecordingCardOperationPhase.cancelling) {
      return false;
    }
    _state = RecordingCardOperationState(
      phase: RecordingCardOperationPhase.running,
      generation: _state.generation,
      kind: _state.kind,
      origin: _state.origin,
      connectionRevision: _state.connectionRevision,
      blockedKind: _state.blockedKind,
      blockedOrigin: _state.blockedOrigin,
      blockCode: _state.blockCode,
    );
    return true;
  }

  bool succeed(RecordingCardOperationLease lease) =>
      _settle(lease, RecordingCardOperationPhase.succeeded);

  bool fail(RecordingCardOperationLease lease, String errorCode) =>
      _settle(lease, RecordingCardOperationPhase.failed, errorCode: errorCode);

  bool interrupt(
    RecordingCardOperationLease lease, {
    String errorCode = recordingCardOperationSessionChangedCode,
  }) => _settle(
    lease,
    RecordingCardOperationPhase.interrupted,
    errorCode: errorCode,
  );

  bool interruptForConnectionRevision(int connectionRevision) {
    if (!_state.isActive ||
        _state.connectionRevision == null ||
        _state.connectionRevision == connectionRevision) {
      return false;
    }
    _state = RecordingCardOperationState(
      phase: RecordingCardOperationPhase.interrupted,
      generation: _state.generation,
      kind: _state.kind,
      origin: _state.origin,
      connectionRevision: _state.connectionRevision,
      errorCode: recordingCardOperationSessionChangedCode,
      blockedKind: _state.blockedKind,
      blockedOrigin: _state.blockedOrigin,
      blockCode: _state.blockCode,
    );
    return true;
  }

  void reset() {
    _generation += 1;
    _state = RecordingCardOperationState(
      phase: RecordingCardOperationPhase.idle,
      generation: _generation,
    );
  }

  bool _settle(
    RecordingCardOperationLease lease,
    RecordingCardOperationPhase phase, {
    String? errorCode,
  }) {
    if (!owns(lease)) return false;
    _state = RecordingCardOperationState(
      phase: phase,
      generation: _state.generation,
      kind: _state.kind,
      origin: _state.origin,
      connectionRevision: _state.connectionRevision,
      errorCode: errorCode,
      blockedKind: _state.blockedKind,
      blockedOrigin: _state.blockedOrigin,
      blockCode: _state.blockCode,
    );
    return true;
  }
}
