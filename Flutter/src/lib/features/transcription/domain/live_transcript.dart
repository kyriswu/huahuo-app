import 'package:flutter/foundation.dart';

enum LiveSpeakerIdentityState {
  matched('matched'),
  unconfirmed('unconfirmed');

  const LiveSpeakerIdentityState(this.wireName);

  final String wireName;

  static LiveSpeakerIdentityState? tryParse(Object? value) {
    for (final state in values) {
      if (state.wireName == value) return state;
    }
    return null;
  }
}

@immutable
final class LiveSpeakerIdentity {
  LiveSpeakerIdentity({
    required this.anonymousSpeakerId,
    required this.state,
    String? profileId,
    String? displayName,
    this.score,
  }) : profileId = _safeIdentityValue(profileId, maxLength: 128),
       displayName = _safeIdentityValue(displayName, maxLength: 64) {
    if (anonymousSpeakerId < 0) {
      throw ArgumentError.value(
        anonymousSpeakerId,
        'anonymousSpeakerId',
        'must be non-negative',
      );
    }
    if (score != null && (!score!.isFinite || score! < 0 || score! > 100)) {
      throw ArgumentError.value(score, 'score', 'must be between 0 and 100');
    }
    if (state == LiveSpeakerIdentityState.matched && this.profileId == null) {
      throw ArgumentError('matched identity requires a profile id');
    }
    if (state == LiveSpeakerIdentityState.unconfirmed &&
        (this.profileId != null || this.displayName != null || score != null)) {
      throw ArgumentError('unconfirmed identity must remain anonymous');
    }
  }

  final int anonymousSpeakerId;
  final LiveSpeakerIdentityState state;
  final String? profileId;
  final String? displayName;
  final double? score;

  bool get matched => state == LiveSpeakerIdentityState.matched;
}

@immutable
final class LiveTranscriptSentence {
  LiveTranscriptSentence({
    required this.sentenceId,
    required String text,
    required this.stable,
    int? anonymousSpeakerId,
    this.startMs,
    this.endMs,
    this.speakerIdentityState,
    String? speakerProfileId,
    String? speakerDisplayName,
    this.speakerIdentityScore,
  }) : text = _validatedText(text),
       anonymousSpeakerId = _anonymousSpeakerId(anonymousSpeakerId),
       speakerProfileId = _safeIdentityValue(speakerProfileId, maxLength: 128),
       speakerDisplayName = _safeIdentityValue(
         speakerDisplayName,
         maxLength: 64,
       ) {
    if (sentenceId < 0) {
      throw ArgumentError.value(
        sentenceId,
        'sentenceId',
        'must be non-negative',
      );
    }
    if (startMs != null && startMs! < 0) {
      throw ArgumentError.value(startMs, 'startMs', 'must be non-negative');
    }
    if (endMs != null &&
        (endMs! < 0 || (startMs != null && endMs! < startMs!))) {
      throw ArgumentError.value(endMs, 'endMs', 'must follow startMs');
    }
    if (speakerIdentityScore != null &&
        (!speakerIdentityScore!.isFinite ||
            speakerIdentityScore! < 0 ||
            speakerIdentityScore! > 100)) {
      throw ArgumentError.value(
        speakerIdentityScore,
        'speakerIdentityScore',
        'must be between 0 and 100',
      );
    }
    final hasMatchedIdentity =
        speakerIdentityState == LiveSpeakerIdentityState.matched;
    if (hasMatchedIdentity &&
        (this.anonymousSpeakerId == null || this.speakerProfileId == null)) {
      throw ArgumentError('matched sentence identity is incomplete');
    }
    if (!hasMatchedIdentity &&
        (this.speakerProfileId != null ||
            this.speakerDisplayName != null ||
            speakerIdentityScore != null)) {
      throw ArgumentError('unmatched sentence cannot carry an identity');
    }
  }

  final int sentenceId;
  final String text;
  final int? anonymousSpeakerId;
  final bool stable;
  final int? startMs;
  final int? endMs;
  final LiveSpeakerIdentityState? speakerIdentityState;
  final String? speakerProfileId;
  final String? speakerDisplayName;
  final double? speakerIdentityScore;

  bool get identifiesCurrentUser =>
      speakerIdentityState == LiveSpeakerIdentityState.matched;

  LiveTranscriptSentence copyWith({
    String? text,
    int? anonymousSpeakerId,
    bool? stable,
    int? startMs,
    int? endMs,
    LiveSpeakerIdentityState? speakerIdentityState,
    String? speakerProfileId,
    String? speakerDisplayName,
    double? speakerIdentityScore,
    bool clearSpeaker = false,
    bool clearIdentity = false,
  }) {
    final shouldClearIdentity = clearIdentity || clearSpeaker;
    return LiveTranscriptSentence(
      sentenceId: sentenceId,
      text: text ?? this.text,
      anonymousSpeakerId: clearSpeaker
          ? null
          : anonymousSpeakerId ?? this.anonymousSpeakerId,
      stable: stable ?? this.stable,
      startMs: startMs ?? this.startMs,
      endMs: endMs ?? this.endMs,
      speakerIdentityState: shouldClearIdentity
          ? null
          : speakerIdentityState ?? this.speakerIdentityState,
      speakerProfileId: shouldClearIdentity
          ? null
          : speakerProfileId ?? this.speakerProfileId,
      speakerDisplayName: shouldClearIdentity
          ? null
          : speakerDisplayName ?? this.speakerDisplayName,
      speakerIdentityScore: shouldClearIdentity
          ? null
          : speakerIdentityScore ?? this.speakerIdentityScore,
    );
  }

  LiveTranscriptSentence applyIdentity(LiveSpeakerIdentity identity) {
    if (anonymousSpeakerId != identity.anonymousSpeakerId) return this;
    if (!identity.matched) return copyWith(clearIdentity: true);
    return copyWith(
      speakerIdentityState: identity.state,
      speakerProfileId: identity.profileId,
      speakerDisplayName: identity.displayName,
      speakerIdentityScore: identity.score,
    );
  }
}

LiveTranscriptSentence mergeLiveTranscriptSentence(
  LiveTranscriptSentence? current,
  LiveTranscriptSentence incoming,
) {
  if (current == null || current.sentenceId != incoming.sentenceId) {
    return incoming;
  }
  if (current.stable && !incoming.stable) return current;
  return incoming;
}

String _validatedText(String value) {
  final text = value.trim();
  if (text.isEmpty || text.length > 100000) {
    throw ArgumentError.value(value, 'text', 'must contain bounded text');
  }
  return text;
}

int? _anonymousSpeakerId(int? value) =>
    value == null || value < 0 ? null : value;

String? _safeIdentityValue(String? raw, {required int maxLength}) {
  final value = raw?.trim();
  if (value == null ||
      value.isEmpty ||
      value.length > maxLength ||
      value.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f)) {
    return null;
  }
  return value;
}
