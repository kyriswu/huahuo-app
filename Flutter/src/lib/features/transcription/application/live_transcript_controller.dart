import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/live_transcription_api.dart';
import '../data/tencent_live_asr_port.dart';
import '../domain/live_transcript.dart';

enum LiveTranscriptStatus { idle, starting, transcribing, stopping, failed }

@immutable
final class LiveTranscriptState {
  const LiveTranscriptState({
    required this.status,
    this.sentences = const <LiveTranscriptSentence>[],
    this.owner,
    this.attemptId,
    this.lastErrorCode,
  }) : assert((owner == null) == (attemptId == null));

  const LiveTranscriptState.idle({
    this.sentences = const <LiveTranscriptSentence>[],
  }) : status = LiveTranscriptStatus.idle,
       owner = null,
       attemptId = null,
       lastErrorCode = null;

  final LiveTranscriptStatus status;
  final List<LiveTranscriptSentence> sentences;
  final String? owner;
  final int? attemptId;
  final String? lastErrorCode;

  List<LiveTranscriptSentence> get stableSentences =>
      List<LiveTranscriptSentence>.unmodifiable(
        sentences.where((sentence) => sentence.stable),
      );

  bool belongsTo(String candidateOwner, {int? candidateAttemptId}) {
    final normalized = _normalizeOwner(candidateOwner);
    return normalized != null &&
        owner == normalized &&
        (candidateAttemptId == null || attemptId == candidateAttemptId);
  }
}

typedef LiveTranscriptReconnectDelay = Future<void> Function(Duration duration);
typedef ActiveVoiceprintProfileId = String? Function();
typedef VoiceprintProfileDisplayName = String? Function(String profileId);

final class LiveTranscriptController extends ChangeNotifier {
  LiveTranscriptController({
    required this.credentialPort,
    required this.asrPort,
    LiveTranscriptionSessionCompletionPort? sessionCompletionPort,
    DateTime Function()? now,
    LiveTranscriptReconnectDelay? reconnectDelay,
    this._activeVoiceprintProfileId,
    this._profileDisplayNameResolver,
    this.maxReconnectAttempts = 2,
  }) : sessionCompletionPort =
           sessionCompletionPort ?? _completionPortFor(credentialPort),
       _now = now ?? DateTime.now,
       _reconnectDelay = reconnectDelay ?? Future<void>.delayed;

  final LiveTranscriptionCredentialPort credentialPort;
  final TencentLiveAsrPort asrPort;
  final LiveTranscriptionSessionCompletionPort? sessionCompletionPort;
  final DateTime Function() _now;
  final LiveTranscriptReconnectDelay _reconnectDelay;
  final ActiveVoiceprintProfileId? _activeVoiceprintProfileId;
  final VoiceprintProfileDisplayName? _profileDisplayNameResolver;
  final int maxReconnectAttempts;

  static LiveTranscriptionSessionCompletionPort? _completionPortFor(
    LiveTranscriptionCredentialPort credentialPort,
  ) {
    if (credentialPort is LiveTranscriptionSessionCompletionPort) {
      return credentialPort as LiveTranscriptionSessionCompletionPort;
    }
    return null;
  }

  LiveTranscriptState _state = const LiveTranscriptState.idle();
  final Map<int, LiveTranscriptSentence> _sentences =
      <int, LiveTranscriptSentence>{};
  final Map<int, LiveSpeakerIdentity> _speakerIdentities =
      <int, LiveSpeakerIdentity>{};
  StreamSubscription<LiveTranscriptSentence>? _eventSubscription;
  StreamSubscription<LiveSpeakerIdentity>? _identitySubscription;
  int? _activeConnectGeneration;
  int _transportGeneration = 0;
  int _attemptSequence = 0;
  int _reconnectAttempts = 0;
  bool _reconnectInFlight = false;
  bool _disposed = false;
  String? _activeOwner;
  int? _activeAttemptId;
  String? _activeSessionId;
  String? _lastTransportErrorCode;

  LiveTranscriptState get state => _state;

  Future<bool> start({required String owner}) async {
    final normalizedOwner = _normalizeOwner(owner);
    if (kDebugMode) {
      debugPrint(
        '[LiveTranscript] stage=start_requested status=${_state.status.name}',
      );
    }
    if (normalizedOwner == null ||
        _disposed ||
        _activeConnectGeneration != null ||
        _state.status == LiveTranscriptStatus.starting ||
        _state.status == LiveTranscriptStatus.transcribing ||
        _state.status == LiveTranscriptStatus.stopping) {
      if (kDebugMode) {
        debugPrint(
          '[LiveTranscript] stage=start_rejected status=${_state.status.name} '
          'disposed=$_disposed connectActive=${_activeConnectGeneration != null}',
        );
      }
      return false;
    }

    final attemptId = ++_attemptSequence;
    final generation = ++_transportGeneration;
    _activeOwner = normalizedOwner;
    _activeAttemptId = attemptId;
    _sentences.clear();
    _speakerIdentities.clear();
    _reconnectAttempts = 0;
    _reconnectInFlight = false;
    _lastTransportErrorCode = null;
    _setAttemptState(LiveTranscriptStatus.starting);

    await _cancelEvents();
    if (!_isCurrentAttempt(normalizedOwner, attemptId, generation) ||
        _state.status != LiveTranscriptStatus.starting) {
      return false;
    }
    return _openSession(
      generation,
      owner: normalizedOwner,
      attemptId: attemptId,
    );
  }

  Future<bool> stop({required String owner, int? attemptId}) async {
    final normalizedOwner = _normalizeOwner(owner);
    final activeAttemptId = _activeAttemptId;
    if (normalizedOwner == null ||
        activeAttemptId == null ||
        normalizedOwner != _activeOwner ||
        (attemptId != null && attemptId != activeAttemptId) ||
        _disposed ||
        _state.status == LiveTranscriptStatus.idle ||
        _state.status == LiveTranscriptStatus.stopping) {
      return false;
    }

    final preserveFinalEvents =
        _state.status == LiveTranscriptStatus.transcribing;
    final generation = preserveFinalEvents
        ? _transportGeneration
        : ++_transportGeneration;
    _setAttemptState(LiveTranscriptStatus.stopping);

    late final LiveAsrOperationResult result;
    if (preserveFinalEvents) {
      final stopped = await _invokeStop();
      await Future<void>.delayed(Duration.zero);
      await _cancelEvents();
      final released = await _invokeRelease();
      result = stopped.ok ? released : stopped;
    } else {
      await _cancelEvents();
      result = await _invokeRelease();
    }
    _completeActiveSession();
    if (_disposed ||
        _activeOwner != normalizedOwner ||
        _activeAttemptId != activeAttemptId ||
        generation != _transportGeneration ||
        _state.status != LiveTranscriptStatus.stopping) {
      return false;
    }

    _transportGeneration += 1;
    if (!result.ok) {
      _setTerminalFailure(
        result,
        owner: normalizedOwner,
        attemptId: activeAttemptId,
      );
      return false;
    }
    _activeOwner = null;
    _activeAttemptId = null;
    _set(LiveTranscriptState.idle(sentences: _orderedSentences()));
    return true;
  }

  bool abandonOwnedStoppingAttempt({
    required String owner,
    required int attemptId,
  }) {
    final normalizedOwner = _normalizeOwner(owner);
    if (normalizedOwner == null ||
        _disposed ||
        _state.status != LiveTranscriptStatus.stopping ||
        _activeOwner != normalizedOwner ||
        _activeAttemptId != attemptId) {
      return false;
    }

    _transportGeneration += 1;
    _activeConnectGeneration = null;
    _reconnectAttempts = 0;
    _reconnectInFlight = false;
    _lastTransportErrorCode = null;
    _activeOwner = null;
    _activeAttemptId = null;
    _completeActiveSession();
    final sentences = _orderedSentences();
    _set(LiveTranscriptState.idle(sentences: sentences));
    unawaited(_cancelEvents());
    unawaited(_invokeRelease());
    return true;
  }

  Future<bool> _openSession(
    int generation, {
    required String owner,
    required int attemptId,
  }) async {
    LiveAsrSessionCredential? credential;
    var credentialRequestOk = false;
    var credentialErrorCode = 'ASR_CREDENTIAL_REQUEST_FAILED';
    try {
      final result = await credentialPort.requestSessionCredential(
        voiceprintProfileId: _resolvedActiveVoiceprintProfileId(),
      );
      credential = result.data;
      credentialRequestOk = result.ok && credential != null;
      credentialErrorCode = result.error?.code ?? credentialErrorCode;
    } catch (_) {
      credentialRequestOk = false;
    }
    if (!_canOpenSession(owner, attemptId, generation)) {
      if (credential != null) {
        unawaited(_completeSession(credential.sessionId));
      }
      return false;
    }
    if (!credentialRequestOk || credential == null) {
      _fail(credentialErrorCode, owner: owner, attemptId: attemptId);
      return false;
    }
    if (credential.expiresWithin(Duration.zero, now: _now())) {
      unawaited(_completeSession(credential.sessionId));
      _fail('ASR_CREDENTIAL_EXPIRED', owner: owner, attemptId: attemptId);
      return false;
    }

    _activeSessionId = credential.sessionId;
    final sentenceIdOffset = _nextSentenceIdOffset();
    final speakerIdOffset = _nextSpeakerIdOffset();
    _speakerIdentities.clear();
    _subscribeToEvents(
      generation,
      owner: owner,
      attemptId: attemptId,
      sentenceIdOffset: sentenceIdOffset,
      speakerIdOffset: speakerIdOffset,
    );
    _activeConnectGeneration = generation;
    LiveAsrOperationResult connected;
    try {
      connected = await asrPort.connect(credential);
    } catch (_) {
      connected = const LiveAsrOperationResult.failure(
        'TENCENT_LIVE_ASR_START_FAILED',
      );
    }

    final ownsConnectAttempt = _activeConnectGeneration == generation;
    if (!_canOpenSession(owner, attemptId, generation)) {
      if (ownsConnectAttempt) {
        await _invokeRelease();
        if (_activeConnectGeneration == generation) {
          _activeConnectGeneration = null;
        }
      }
      _completeActiveSession();
      return false;
    }
    if (ownsConnectAttempt) _activeConnectGeneration = null;
    if (!connected.ok) {
      await _cancelEvents();
      await _stopAndRelease();
      _completeActiveSession();
      if (!_canOpenSession(owner, attemptId, generation)) return false;
      _setTerminalFailure(connected, owner: owner, attemptId: attemptId);
      return false;
    }
    _setAttemptState(LiveTranscriptStatus.transcribing);
    return true;
  }

  void _subscribeToEvents(
    int generation, {
    required String owner,
    required int attemptId,
    required int sentenceIdOffset,
    required int speakerIdOffset,
  }) {
    unawaited(_eventSubscription?.cancel() ?? Future<void>.value());
    unawaited(_identitySubscription?.cancel() ?? Future<void>.value());
    _eventSubscription = asrPort.events.listen(
      (sentence) {
        if (!_acceptsSessionEvents(owner, attemptId, generation)) return;
        final scopedSentence = _scopeSentence(
          sentence,
          sentenceIdOffset: sentenceIdOffset,
          speakerIdOffset: speakerIdOffset,
        );
        _lastTransportErrorCode = null;
        final identity = scopedSentence.anonymousSpeakerId == null
            ? null
            : _speakerIdentities[scopedSentence.anonymousSpeakerId!];
        final enriched = identity == null
            ? scopedSentence
            : scopedSentence.applyIdentity(identity);
        _sentences[scopedSentence.sentenceId] = mergeLiveTranscriptSentence(
          _sentences[scopedSentence.sentenceId],
          enriched,
        );
        _setAttemptState(_state.status);
      },
      onError: (Object error, StackTrace __) {
        _handleTransportLoss(
          generation,
          owner: owner,
          attemptId: attemptId,
          errorCode: _safeTransportErrorCode(error),
        );
      },
      onDone: () =>
          _handleTransportLoss(generation, owner: owner, attemptId: attemptId),
    );
    _identitySubscription = asrPort.identityEvents.listen(
      (identity) {
        if (!_acceptsSessionEvents(owner, attemptId, generation)) return;
        final resolved = _resolveIdentityDisplayName(
          _scopeIdentity(identity, speakerIdOffset),
        );
        _speakerIdentities[resolved.anonymousSpeakerId] = resolved;
        for (final entry in _sentences.entries.toList(growable: false)) {
          if (entry.value.anonymousSpeakerId == resolved.anonymousSpeakerId) {
            _sentences[entry.key] = entry.value.applyIdentity(resolved);
          }
        }
        _setAttemptState(_state.status);
      },
      onError: (Object error, StackTrace __) {
        _handleTransportLoss(
          generation,
          owner: owner,
          attemptId: attemptId,
          errorCode: _safeTransportErrorCode(error),
        );
      },
    );
  }

  bool _acceptsSessionEvents(String owner, int attemptId, int generation) {
    if (!_isCurrentAttempt(owner, attemptId, generation)) return false;
    return _state.status == LiveTranscriptStatus.starting ||
        _state.status == LiveTranscriptStatus.transcribing ||
        _state.status == LiveTranscriptStatus.stopping;
  }

  void _handleTransportLoss(
    int generation, {
    required String owner,
    required int attemptId,
    String? errorCode,
  }) {
    if (!_isTranscribingAttempt(owner, attemptId, generation) ||
        _reconnectInFlight) {
      return;
    }
    if (errorCode != null) _lastTransportErrorCode = errorCode;
    final terminalCode = _lastTransportErrorCode;
    if (terminalCode != null && !_isRetryableTransportError(terminalCode)) {
      unawaited(
        _failAfterTransportLoss(
          generation,
          owner: owner,
          attemptId: attemptId,
          errorCode: terminalCode,
        ),
      );
      return;
    }
    if (_reconnectAttempts >= maxReconnectAttempts) {
      unawaited(
        _failAfterTransportLoss(
          generation,
          owner: owner,
          attemptId: attemptId,
          errorCode: terminalCode,
        ),
      );
      return;
    }
    unawaited(
      _performReconnect(generation, owner: owner, attemptId: attemptId),
    );
  }

  Future<bool> _performReconnect(
    int sourceGeneration, {
    required String owner,
    required int attemptId,
  }) async {
    if (!_isTranscribingAttempt(owner, attemptId, sourceGeneration) ||
        _reconnectInFlight ||
        _reconnectAttempts >= maxReconnectAttempts) {
      return false;
    }
    _reconnectInFlight = true;
    _reconnectAttempts += 1;
    final generation = ++_transportGeneration;
    try {
      await _cancelEvents();
      await _stopAndRelease();
      _completeActiveSession();
      if (!_isTranscribingAttempt(owner, attemptId, generation)) return false;
      await _reconnectDelay(Duration(milliseconds: 250 * _reconnectAttempts));
      if (!_isTranscribingAttempt(owner, attemptId, generation)) return false;
      return _openSession(generation, owner: owner, attemptId: attemptId);
    } finally {
      _reconnectInFlight = false;
    }
  }

  Future<void> _failAfterTransportLoss(
    int generation, {
    required String owner,
    required int attemptId,
    String? errorCode,
  }) async {
    if (!_isTranscribingAttempt(owner, attemptId, generation)) return;
    final nextGeneration = ++_transportGeneration;
    await _cancelEvents();
    await _stopAndRelease();
    _completeActiveSession();
    if (!_isTranscribingAttempt(owner, attemptId, nextGeneration)) return;
    _fail(
      errorCode ?? 'LIVE_ASR_RECONNECT_EXHAUSTED',
      owner: owner,
      attemptId: attemptId,
    );
  }

  bool _canOpenSession(String owner, int attemptId, int generation) {
    if (!_isCurrentAttempt(owner, attemptId, generation)) return false;
    return _state.status == LiveTranscriptStatus.starting ||
        _state.status == LiveTranscriptStatus.transcribing;
  }

  bool _isTranscribingAttempt(String owner, int attemptId, int generation) =>
      _isCurrentAttempt(owner, attemptId, generation) &&
      _state.status == LiveTranscriptStatus.transcribing;

  bool _isCurrentAttempt(String owner, int attemptId, int generation) =>
      !_disposed &&
      _activeOwner == owner &&
      _activeAttemptId == attemptId &&
      _transportGeneration == generation;

  Future<LiveAsrOperationResult> _stopAndRelease() async {
    final stopped = await _invokeStop();
    final released = await _invokeRelease();
    if (!stopped.ok) return stopped;
    return released;
  }

  Future<LiveAsrOperationResult> _invokeStop() async {
    try {
      return await asrPort.stop();
    } catch (_) {
      return const LiveAsrOperationResult.failure(
        'TENCENT_LIVE_ASR_STOP_FAILED',
      );
    }
  }

  Future<LiveAsrOperationResult> _invokeRelease() async {
    try {
      return await asrPort.release();
    } catch (_) {
      return const LiveAsrOperationResult.failure(
        'TENCENT_LIVE_ASR_RELEASE_FAILED',
      );
    }
  }

  void _completeActiveSession() {
    final sessionId = _activeSessionId;
    _activeSessionId = null;
    if (sessionId == null) return;
    unawaited(_completeSession(sessionId));
  }

  Future<void> _completeSession(String sessionId) async {
    final completion = sessionCompletionPort;
    if (completion == null) return;
    try {
      await completion.completeSession(sessionId);
    } catch (_) {
      // Completion is best-effort cleanup. It must not discard local text.
    }
  }

  Future<void> _cancelEvents() async {
    final subscription = _eventSubscription;
    _eventSubscription = null;
    final identitySubscription = _identitySubscription;
    _identitySubscription = null;
    await Future.wait<void>([
      subscription?.cancel() ?? Future<void>.value(),
      identitySubscription?.cancel() ?? Future<void>.value(),
    ]);
  }

  String? _resolvedActiveVoiceprintProfileId() {
    try {
      final value = _activeVoiceprintProfileId?.call()?.trim();
      if (value == null || value.isEmpty) return null;
      return RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$').hasMatch(value)
          ? value
          : null;
    } catch (_) {
      return null;
    }
  }

  LiveSpeakerIdentity _resolveIdentityDisplayName(
    LiveSpeakerIdentity identity,
  ) {
    if (!identity.matched) return identity;
    final profileId = identity.profileId;
    if (profileId == null) return identity;
    String? displayName;
    try {
      displayName = _profileDisplayNameResolver?.call(profileId);
    } catch (_) {
      displayName = null;
    }
    return LiveSpeakerIdentity(
      anonymousSpeakerId: identity.anonymousSpeakerId,
      state: identity.state,
      profileId: profileId,
      displayName: displayName,
      score: identity.score,
    );
  }

  int _nextSentenceIdOffset() {
    if (_sentences.isEmpty) return 0;
    return _sentences.keys.reduce(
          (left, right) => left > right ? left : right,
        ) +
        1;
  }

  int _nextSpeakerIdOffset() {
    var maximum = -1;
    for (final sentence in _sentences.values) {
      final speaker = sentence.anonymousSpeakerId;
      if (speaker != null && speaker > maximum) maximum = speaker;
    }
    return maximum + 1;
  }

  LiveTranscriptSentence _scopeSentence(
    LiveTranscriptSentence sentence, {
    required int sentenceIdOffset,
    required int speakerIdOffset,
  }) {
    final speaker = sentence.anonymousSpeakerId;
    return LiveTranscriptSentence(
      sentenceId: sentenceIdOffset + sentence.sentenceId,
      text: sentence.text,
      stable: sentence.stable,
      anonymousSpeakerId: speaker == null ? null : speakerIdOffset + speaker,
      startMs: sentence.startMs,
      endMs: sentence.endMs,
    );
  }

  LiveSpeakerIdentity _scopeIdentity(
    LiveSpeakerIdentity identity,
    int speakerIdOffset,
  ) {
    return LiveSpeakerIdentity(
      anonymousSpeakerId: speakerIdOffset + identity.anonymousSpeakerId,
      state: identity.state,
      profileId: identity.profileId,
      displayName: identity.displayName,
      score: identity.score,
    );
  }

  List<LiveTranscriptSentence> _orderedSentences() {
    final values = _sentences.values.toList()
      ..sort((left, right) => left.sentenceId.compareTo(right.sentenceId));
    return List<LiveTranscriptSentence>.unmodifiable(values);
  }

  void _setTerminalFailure(
    LiveAsrOperationResult result, {
    required String owner,
    required int attemptId,
  }) {
    _fail(
      result.errorCode ?? 'LIVE_ASR_OPERATION_FAILED',
      owner: owner,
      attemptId: attemptId,
    );
  }

  void _fail(String code, {required String owner, required int attemptId}) {
    if (_activeOwner != owner || _activeAttemptId != attemptId) return;
    _set(
      LiveTranscriptState(
        status: LiveTranscriptStatus.failed,
        sentences: _orderedSentences(),
        owner: owner,
        attemptId: attemptId,
        lastErrorCode: code,
      ),
    );
  }

  void _setAttemptState(LiveTranscriptStatus status) {
    final owner = _activeOwner;
    final attemptId = _activeAttemptId;
    if (owner == null || attemptId == null) return;
    _set(
      LiveTranscriptState(
        status: status,
        sentences: _orderedSentences(),
        owner: owner,
        attemptId: attemptId,
      ),
    );
  }

  void _set(LiveTranscriptState value) {
    if (_disposed) return;
    _state = value;
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _transportGeneration += 1;
    final subscription = _eventSubscription;
    _eventSubscription = null;
    final identitySubscription = _identitySubscription;
    _identitySubscription = null;
    unawaited(subscription?.cancel() ?? Future<void>.value());
    unawaited(identitySubscription?.cancel() ?? Future<void>.value());
    unawaited(_stopReleaseAndComplete());
    super.dispose();
  }

  Future<void> _stopReleaseAndComplete() async {
    await _stopAndRelease();
    _completeActiveSession();
  }
}

String? _normalizeOwner(String value) {
  final owner = value.trim();
  if (owner.isEmpty || owner.length > 128) return null;
  for (final unit in owner.codeUnits) {
    if (unit < 0x21 || unit == 0x7f) return null;
  }
  return owner;
}

String? _safeTransportErrorCode(Object error) {
  final value = error is String ? error.trim() : '';
  return RegExp(r'^TENCENT_LIVE_ASR_[A-Z0-9_]{3,80}$').hasMatch(value)
      ? value
      : null;
}

bool _isRetryableTransportError(String code) =>
    code == 'TENCENT_LIVE_ASR_NETWORK_FAILED' ||
    code == 'TENCENT_LIVE_ASR_TIMEOUT' ||
    code == 'TENCENT_LIVE_ASR_PROVIDER_UNAVAILABLE' ||
    code == 'TENCENT_LIVE_ASR_PROVIDER_COMPLETED' ||
    code == 'TENCENT_LIVE_ASR_NATIVE_EVENT_FAILED';
