import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/bootstrap/app_providers.dart';
import '../../../core/auth/session_store.dart';
import '../domain/feed_item_models.dart';
import 'automatic_outline_recovery_store.dart';
import 'note_file_agent_client.dart';

// resident-provider: Shares one account-scoped outline repository identity across dependent controllers.
final outlineRepositoryProvider = Provider<OutlineRepository>((ref) {
  try {
    final apiClient = ref.watch(apiClientProvider);
    final workspaceId = ref.watch(
      sessionStoreProvider.select((store) {
        final state = store.state;
        return state.authState == SessionAuthState.authenticated
            ? state.workspace?.workspaceId
            : null;
      }),
    );
    return FileAgentOutlineRepository(
      NoteFileAgentClient(apiClient: apiClient, workspaceId: () => workspaceId),
      recoveryStore: ref.watch(automaticOutlineRecoveryStoreProvider),
    );
  } on StateError catch (error) {
    if (error.message != 'DEVICE_IDENTITY_NOT_RESOLVED') rethrow;
    return const UnavailableOutlineRepository();
  }
});

abstract interface class OutlineRepository {
  Future<String> generate(V3FeedItem note, {required String operationId});
}

/// Optional production capability used by the foreground task tracker. Test
/// and legacy repositories may keep implementing [OutlineRepository] only.
abstract interface class AcceptedOutlineRunRepository {
  Future<NoteFileAgentRunSnapshot> submit(
    V3FeedItem note, {
    required String operationId,
    bool allowExistingAutomaticOutline = false,
  });
}

/// Replays an immutable automatic admission that was durably checkpointed
/// before its original POST. New admissions must continue to use
/// [AcceptedOutlineRunRepository.submit] and its mutable-head preflight.
abstract interface class AutomaticOutlineAdmissionReplayPort {
  Future<NoteFileAgentRunSnapshot> replayAutomaticAdmission(
    AutomaticOutlinePreparedAdmission admission,
  );
}

/// Keeps an accepted revision reservation alive until durable task tracking
/// has taken ownership of the Run.
abstract interface class OutlineAdmissionTrackingPort {
  void markOutlineAdmissionTracked(NoteFileAgentRunSnapshot accepted);
}

/// Exposes only the caller operation identity for an exact in-memory
/// reservation so a reconstructed route can finish durable tracker handoff.
abstract interface class PendingOutlineAdmissionPort {
  PendingOutlineAdmission? pendingOutlineAdmission(V3FeedItem note);

  String? pendingOutlineOperationId(V3FeedItem note);
}

final class PendingOutlineAdmission {
  const PendingOutlineAdmission({required this.operationId, this.accepted});

  final String operationId;
  final NoteFileAgentRunSnapshot? accepted;
}

final class OutlineGenerationException implements Exception {
  const OutlineGenerationException(
    this.code, {
    this.isRetryable = false,
    this.recoveryAdmission,
  });

  final String code;
  final bool isRetryable;
  final AutomaticOutlinePreparedAdmission? recoveryAdmission;
}

final class UnavailableOutlineRepository implements OutlineRepository {
  const UnavailableOutlineRepository();

  @override
  Future<String> generate(
    V3FeedItem note, {
    required String operationId,
  }) async =>
      throw const OutlineGenerationException('OUTLINE_BACKEND_UNAVAILABLE');
}

final class FileAgentOutlineRepository
    implements
        OutlineRepository,
        AcceptedOutlineRunRepository,
        AutomaticOutlineAdmissionReplayPort,
        OutlineAdmissionTrackingPort,
        PendingOutlineAdmissionPort {
  FileAgentOutlineRepository(
    this._fileAgent, {
    AutomaticOutlineRecoveryStorePort? recoveryStore,
  }) : // Public dependency names intentionally omit private field prefixes.
       // ignore: prefer_initializing_formals
       _recoveryStore = recoveryStore;

  final NoteFileAgentClient _fileAgent;
  final AutomaticOutlineRecoveryStorePort? _recoveryStore;
  final Map<(String, String, String), _OutlineAdmissionReservation>
  _outlineAdmissions =
      <(String, String, String), _OutlineAdmissionReservation>{};

  @override
  Future<String> generate(
    V3FeedItem note, {
    required String operationId,
  }) async {
    try {
      final result = await _fileAgent.run(
        await _requestFor(note, operationId: operationId),
      );
      return result.markdown;
    } on OutlineGenerationException {
      rethrow;
    } on NoteFileAgentException catch (error) {
      throw OutlineGenerationException(
        _mapFileAgentFailure(error.code),
        isRetryable: error.isRetryable,
      );
    }
  }

  @override
  Future<NoteFileAgentRunSnapshot> submit(
    V3FeedItem note, {
    required String operationId,
    bool allowExistingAutomaticOutline = false,
  }) async {
    final identity = _requestIdentityFor(note, operationId: operationId);
    final admissionKey = identity.admissionKey;
    final existing = _outlineAdmissions[admissionKey];
    if (existing != null) {
      if (existing.callerOperationId != identity.operationId) {
        throw const OutlineGenerationException(
          'OUTLINE_ADMISSION_OPERATION_CONFLICT',
          isRetryable: true,
        );
      }
      return _joinOrRetryAdmission(existing);
    }

    final reservation = _OutlineAdmissionReservation(
      admissionKey: admissionKey,
      callerOperationId: identity.operationId,
    );
    _outlineAdmissions[admissionKey] = reservation;
    return _joinOrRetryAdmission(
      reservation,
      note: note,
      allowExistingAutomaticOutline: allowExistingAutomaticOutline,
    );
  }

  Future<NoteFileAgentRunSnapshot> _joinOrRetryAdmission(
    _OutlineAdmissionReservation reservation, {
    V3FeedItem? note,
    bool allowExistingAutomaticOutline = false,
  }) {
    final accepted = reservation.accepted;
    if (accepted != null) {
      return Future<NoteFileAgentRunSnapshot>.value(accepted);
    }
    final settlement = reservation.settlement;
    if (settlement != null) return settlement;
    final inFlight = reservation.inFlight;
    if (inFlight != null) {
      final joined = _settleAdmission(reservation, inFlight);
      reservation.settlement = joined;
      return joined;
    }

    final retainedRequest = reservation.request;
    final attempt = retainedRequest != null
        ? _fileAgent.replaySubmit(
            retainedRequest,
            onDispatch: () => reservation.dispatchStarted = true,
          )
        : _prepareAndSubmitAdmission(
            reservation,
            note!,
            allowExistingAutomaticOutline: allowExistingAutomaticOutline,
          );
    reservation.inFlight = attempt;
    final joined = _settleAdmission(reservation, attempt);
    reservation.settlement = joined;
    return joined;
  }

  Future<NoteFileAgentRunSnapshot> _prepareAndSubmitAdmission(
    _OutlineAdmissionReservation reservation,
    V3FeedItem note, {
    required bool allowExistingAutomaticOutline,
  }) async {
    final request = await _requestFor(
      note,
      operationId: reservation.callerOperationId,
      allowExistingAutomaticOutline: allowExistingAutomaticOutline,
    );
    final recoveryStore = _recoveryStore;
    AutomaticOutlinePreparedAdmission? prepared;
    if (recoveryStore != null &&
        isAutomaticOutlineOperationId(reservation.callerOperationId)) {
      prepared = AutomaticOutlinePreparedAdmission(
        attemptId: automaticOutlineAttemptId(
          workspaceScope: recoveryStore.workspaceScope,
          remoteNoteId: request.noteId,
          inputRawRevisionId: request.inputPartRevisionId,
          targetOutlineRevisionId: request.targetPartRevisionId,
        ),
        localNoteId: note.id,
        operationId: reservation.callerOperationId,
        request: request,
        allowExistingAutomaticOutline: allowExistingAutomaticOutline,
        createdAt: DateTime.now().toUtc(),
      );
      if (!await recoveryStore.putPrepared(prepared)) {
        throw const OutlineGenerationException(
          'AUTO_OUTLINE_CHECKPOINT_SAVE_FAILED',
          isRetryable: true,
        );
      }
      reservation.prepared = prepared;
    }
    reservation.request = request;
    return _fileAgent.submit(
      request,
      onDispatch: () => reservation.dispatchStarted = true,
    );
  }

  Future<NoteFileAgentRunSnapshot> _settleAdmission(
    _OutlineAdmissionReservation reservation,
    Future<NoteFileAgentRunSnapshot> attempt,
  ) async {
    try {
      final accepted = await attempt;
      if (identical(reservation.inFlight, attempt)) {
        final prepared = reservation.prepared;
        final recoveryStore = _recoveryStore;
        if (prepared != null &&
            (recoveryStore == null ||
                !await recoveryStore.promoteAccepted(
                  admission: prepared,
                  accepted: accepted,
                ))) {
          throw const OutlineGenerationException(
            'AUTO_OUTLINE_CHECKPOINT_SAVE_FAILED',
            isRetryable: true,
          );
        }
        reservation
          ..inFlight = null
          ..settlement = null
          ..accepted = accepted;
      }
      return accepted;
    } on OutlineGenerationException catch (error) {
      _releaseAdmission(reservation, attempt);
      final prepared = reservation.prepared;
      if (error.recoveryAdmission != null || prepared == null) rethrow;
      throw OutlineGenerationException(
        error.code,
        isRetryable: error.isRetryable,
        recoveryAdmission: prepared,
      );
    } on NoteFileAgentException catch (error) {
      final retainsPreparedRequest =
          reservation.dispatchStarted &&
          error.isRetryable &&
          error.admissionDisposition !=
              NoteFileAgentAdmissionFailureDisposition.none;
      if (retainsPreparedRequest) {
        if (identical(reservation.inFlight, attempt)) {
          reservation.inFlight = null;
          try {
            if (error.admissionDisposition ==
                NoteFileAgentAdmissionFailureDisposition.retryWithFreshKey) {
              await _rotateBackendAdmissionKey(reservation);
            }
          } finally {
            reservation.settlement = null;
          }
        }
      } else {
        _releaseAdmission(reservation, attempt);
      }
      throw OutlineGenerationException(
        _mapFileAgentFailure(error.code),
        isRetryable: error.isRetryable,
        recoveryAdmission: reservation.prepared,
      );
    } on Object {
      if (reservation.dispatchStarted) {
        if (identical(reservation.inFlight, attempt)) {
          reservation.inFlight = null;
        }
        throw OutlineGenerationException(
          'OUTLINE_ADMISSION_RESPONSE_UNCERTAIN',
          isRetryable: true,
          recoveryAdmission: reservation.prepared,
        );
      }
      _releaseAdmission(reservation, attempt);
      rethrow;
    }
  }

  Future<void> _rotateBackendAdmissionKey(
    _OutlineAdmissionReservation reservation,
  ) async {
    final request = reservation.request;
    if (request == null) return;
    final prepared = reservation.prepared;
    final nextBackendAttempt =
        (prepared?.backendAdmissionAttempt ??
            reservation.backendAdmissionAttempt) +
        1;
    final retryKey =
        automaticOutlineRequestIdempotencyKey(
          reservation.callerOperationId,
          backendAdmissionAttempt: nextBackendAttempt,
        ) ??
        'outline-retry-v1-${sha256.convert(utf8.encode(jsonEncode(<Object>[reservation.callerOperationId, request.idempotencyKey, nextBackendAttempt]))).toString()}';
    final replacementRequest = _requestWithIdempotencyKey(request, retryKey);
    if (prepared != null) {
      final replacement = AutomaticOutlinePreparedAdmission(
        attemptId: prepared.attemptId,
        localNoteId: prepared.localNoteId,
        operationId: prepared.operationId,
        request: replacementRequest,
        allowExistingAutomaticOutline: prepared.allowExistingAutomaticOutline,
        createdAt: prepared.createdAt,
        backendAdmissionAttempt: nextBackendAttempt,
      );
      final recoveryStore = _recoveryStore;
      if (recoveryStore == null ||
          !await recoveryStore.replacePrepared(
            expected: prepared,
            replacement: replacement,
          )) {
        throw const OutlineGenerationException(
          'AUTO_OUTLINE_CHECKPOINT_SAVE_FAILED',
          isRetryable: true,
        );
      }
      reservation.prepared = replacement;
    }
    reservation
      ..backendAdmissionAttempt = nextBackendAttempt
      ..request = replacementRequest;
  }

  NoteFileAgentRequest _requestWithIdempotencyKey(
    NoteFileAgentRequest request,
    String idempotencyKey,
  ) => NoteFileAgentRequest(
    noteId: request.noteId,
    inputPart: request.inputPart,
    inputPartRevisionId: request.inputPartRevisionId,
    targetPart: request.targetPart,
    targetPartRevisionId: request.targetPartRevisionId,
    instruction: request.instruction,
    selector: request.selector,
    idempotencyKey: idempotencyKey,
    modelProfileId: request.modelProfileId,
  );

  void _releaseAdmission(
    _OutlineAdmissionReservation reservation,
    Future<NoteFileAgentRunSnapshot> attempt,
  ) {
    if (!identical(reservation.inFlight, attempt) ||
        !identical(_outlineAdmissions[reservation.admissionKey], reservation)) {
      return;
    }
    _outlineAdmissions.remove(reservation.admissionKey);
  }

  @override
  PendingOutlineAdmission? pendingOutlineAdmission(V3FeedItem note) {
    final noteId = _nonEmpty(note.remoteNoteId);
    final rawRevisionId = _nonEmpty(note.rawPartRevisionId);
    final targetRevisionId = _nonEmpty(note.outlinePartRevisionId);
    if (noteId == null || rawRevisionId == null) return null;
    if (targetRevisionId != null) {
      final exact =
          _outlineAdmissions[(noteId, rawRevisionId, targetRevisionId)];
      if (exact != null) {
        return PendingOutlineAdmission(
          operationId: exact.callerOperationId,
          accepted: exact.accepted,
        );
      }
    }
    final acceptedMatches = _outlineAdmissions.values.where(
      (reservation) =>
          reservation.admissionKey.$1 == noteId &&
          reservation.admissionKey.$2 == rawRevisionId &&
          reservation.accepted != null,
    );
    if (acceptedMatches.length != 1) return null;
    final recovered = acceptedMatches.single;
    return PendingOutlineAdmission(
      operationId: recovered.callerOperationId,
      accepted: recovered.accepted,
    );
  }

  @override
  String? pendingOutlineOperationId(V3FeedItem note) =>
      pendingOutlineAdmission(note)?.operationId;

  @override
  void markOutlineAdmissionTracked(NoteFileAgentRunSnapshot accepted) {
    final key = (
      accepted.noteId,
      accepted.inputPartRevisionId,
      accepted.targetPartRevisionId,
    );
    final reservation = _outlineAdmissions[key];
    if (reservation?.accepted?.fileAgentRunId != accepted.fileAgentRunId) {
      return;
    }
    _outlineAdmissions.remove(key);
  }

  @override
  Future<NoteFileAgentRunSnapshot> replayAutomaticAdmission(
    AutomaticOutlinePreparedAdmission admission,
  ) => _replayAutomaticAdmission(admission, allowImmediateFreshRetry: true);

  Future<NoteFileAgentRunSnapshot> _replayAutomaticAdmission(
    AutomaticOutlinePreparedAdmission admission, {
    required bool allowImmediateFreshRetry,
  }) async {
    if (!isAutomaticOutlineOperationId(admission.operationId) ||
        admission.accepted != null ||
        admission.request.idempotencyKey !=
            automaticOutlineRequestIdempotencyKey(
              admission.operationId,
              backendAdmissionAttempt: admission.backendAdmissionAttempt,
            ) ||
        admission.request.noteId != admission.remoteNoteId ||
        admission.request.inputPart != NoteFileAgentPart.raw ||
        admission.request.targetPart != NoteFileAgentPart.outline) {
      throw const OutlineGenerationException(
        'OUTLINE_RECOVERY_CHECKPOINT_INVALID',
      );
    }
    try {
      final accepted = await _fileAgent.replaySubmit(admission.request);
      final recoveryStore = _recoveryStore;
      if (recoveryStore != null &&
          !await recoveryStore.promoteAccepted(
            admission: admission,
            accepted: accepted,
          )) {
        throw const OutlineGenerationException(
          'AUTO_OUTLINE_CHECKPOINT_SAVE_FAILED',
          isRetryable: true,
        );
      }
      return accepted;
    } on OutlineGenerationException {
      rethrow;
    } on NoteFileAgentException catch (error) {
      final needsFreshKey =
          error.isFailedIdempotencyReceipt ||
          error.isRetryable &&
              error.admissionDisposition ==
                  NoteFileAgentAdmissionFailureDisposition.retryWithFreshKey;
      if (needsFreshKey) {
        if (error.isFailedIdempotencyReceipt) {
          try {
            await _verifyRecoveredAdmissionStillEligible(admission);
          } on OutlineGenerationException catch (verification) {
            throw OutlineGenerationException(
              verification.code,
              isRetryable: verification.isRetryable,
              recoveryAdmission: admission,
            );
          }
        }
        final replacement = _nextAutomaticOutlineAdmission(admission);
        final recoveryStore = _recoveryStore;
        if (replacement == null ||
            recoveryStore == null ||
            !await recoveryStore.replacePrepared(
              expected: admission,
              replacement: replacement,
            )) {
          throw const OutlineGenerationException(
            'AUTO_OUTLINE_CHECKPOINT_SAVE_FAILED',
            isRetryable: true,
          );
        }
        if (allowImmediateFreshRetry) {
          return _replayAutomaticAdmission(
            replacement,
            allowImmediateFreshRetry: false,
          );
        }
        throw OutlineGenerationException(
          _mapFileAgentFailure(error.code),
          isRetryable: true,
          recoveryAdmission: replacement,
        );
      }
      throw OutlineGenerationException(
        _mapFileAgentFailure(error.code),
        isRetryable: error.isRetryable,
        recoveryAdmission: admission,
      );
    }
  }

  Future<void> _verifyRecoveredAdmissionStillEligible(
    AutomaticOutlinePreparedAdmission admission,
  ) async {
    try {
      final head = await _fileAgent.readCurrentNote(admission.remoteNoteId);
      if (head.rawPartRevisionId != admission.inputRawRevisionId ||
          head.outlinePartRevisionId != admission.targetOutlineRevisionId) {
        throw const OutlineGenerationException(
          'OUTLINE_SOURCE_REVISION_CHANGED',
        );
      }
      final outline = await _fileAgent.readCurrentPart(
        admission.remoteNoteId,
        NoteFileAgentPart.outline,
      );
      if (outline.partRevisionId != admission.targetOutlineRevisionId) {
        throw const OutlineGenerationException(
          'OUTLINE_SOURCE_REVISION_CHANGED',
        );
      }
      if (outline.markdown.trim().isNotEmpty &&
          !admission.allowExistingAutomaticOutline) {
        throw const OutlineGenerationException('OUTLINE_ALREADY_EXISTS');
      }
    } on OutlineGenerationException {
      rethrow;
    } on NoteFileAgentException catch (error) {
      throw OutlineGenerationException(
        _mapFileAgentFailure(error.code),
        isRetryable: error.isRetryable,
      );
    }
  }

  Future<NoteFileAgentRequest> _requestFor(
    V3FeedItem note, {
    required String operationId,
    bool allowExistingAutomaticOutline = false,
  }) async {
    final identity = _requestIdentityFor(note, operationId: operationId);
    final noteId = identity.noteId;
    final rawRevisionId = identity.rawRevisionId;
    final targetRevisionId = identity.targetRevisionId;
    final head = await _fileAgent.readCurrentNote(noteId);
    if (head.rawPartRevisionId != rawRevisionId ||
        head.outlinePartRevisionId != targetRevisionId) {
      throw const OutlineGenerationException('OUTLINE_SOURCE_REVISION_CHANGED');
    }
    final currentOutline = await _fileAgent.readCurrentPart(
      noteId,
      NoteFileAgentPart.outline,
    );
    if (currentOutline.partRevisionId != targetRevisionId) {
      throw const OutlineGenerationException('OUTLINE_SOURCE_REVISION_CHANGED');
    }
    if (currentOutline.markdown.trim().isNotEmpty &&
        !allowExistingAutomaticOutline) {
      throw const OutlineGenerationException('OUTLINE_ALREADY_EXISTS');
    }
    return _requestFromIdentity(
      note,
      identity,
      authoritativeSourceKind: head.sourceKind,
    );
  }

  NoteFileAgentRequest _requestFromIdentity(
    V3FeedItem note,
    _OutlineRequestIdentity identity, {
    String? authoritativeSourceKind,
  }) {
    final importedMediaHandoff = _isImportedMediaOutlineOperation(
      identity.operationId,
    );
    final selector = importedMediaHandoff
        ? outlineSelectorForSource(V3MaterialSource.link)
        : authoritativeSourceKind == 'recording'
        ? outlineSelectorForSource(V3MaterialSource.recordingCard)
        : outlineSelectorForSource(note.source);
    final recordingStyle =
        selector.agentProfileId == 'recording_postprocess_agent';
    return NoteFileAgentRequest(
      noteId: identity.noteId,
      inputPart: NoteFileAgentPart.raw,
      inputPartRevisionId: identity.rawRevisionId,
      targetPart: NoteFileAgentPart.outline,
      targetPartRevisionId: identity.targetRevisionId,
      instruction: importedMediaHandoff
          ? _importedMediaOutlineInstruction
          : recordingStyle
          ? 'Create factual meeting minutes from this transcript. Preserve '
                'speaker attributions when present. Do not invent speakers, '
                'decisions, or facts.'
          : 'Create a faithful outline or minutes from the source. Do not '
                'invent a meeting, speakers, or facts.',
      selector: selector,
      idempotencyKey: importedMediaHandoff
          ? identity.operationId
          : 'detail-outline-${identity.operationId}',
    );
  }

  _OutlineRequestIdentity _requestIdentityFor(
    V3FeedItem note, {
    required String operationId,
  }) {
    final noteId = _nonEmpty(note.remoteNoteId);
    final rawRevisionId = _nonEmpty(note.rawPartRevisionId);
    if (note.syncState != NoteSyncState.synced ||
        noteId == null ||
        rawRevisionId == null) {
      throw const OutlineGenerationException(
        'OUTLINE_HNOTE_EXACT_REVISION_REQUIRED',
      );
    }
    if (note.rawBody.trim().isEmpty) {
      throw const OutlineGenerationException('OUTLINE_SOURCE_EMPTY');
    }
    final normalizedOperationId = _nonEmpty(operationId);
    if (normalizedOperationId == null) {
      throw const OutlineGenerationException('OUTLINE_OPERATION_REQUIRED');
    }
    final targetRevisionId = _nonEmpty(note.outlinePartRevisionId);
    if (targetRevisionId == null) {
      throw const OutlineGenerationException(
        'OUTLINE_TARGET_REVISION_REQUIRED',
      );
    }
    return _OutlineRequestIdentity(
      noteId: noteId,
      rawRevisionId: rawRevisionId,
      targetRevisionId: targetRevisionId,
      operationId: normalizedOperationId,
    );
  }
}

final class _OutlineRequestIdentity {
  const _OutlineRequestIdentity({
    required this.noteId,
    required this.rawRevisionId,
    required this.targetRevisionId,
    required this.operationId,
  });

  final String noteId;
  final String rawRevisionId;
  final String targetRevisionId;
  final String operationId;

  (String, String, String) get admissionKey =>
      (noteId, rawRevisionId, targetRevisionId);
}

final class _OutlineAdmissionReservation {
  _OutlineAdmissionReservation({
    required this.admissionKey,
    required this.callerOperationId,
  });

  final (String, String, String) admissionKey;
  final String callerOperationId;
  NoteFileAgentRequest? request;
  Future<NoteFileAgentRunSnapshot>? inFlight;
  Future<NoteFileAgentRunSnapshot>? settlement;
  NoteFileAgentRunSnapshot? accepted;
  AutomaticOutlinePreparedAdmission? prepared;
  int backendAdmissionAttempt = 0;
  bool dispatchStarted = false;
}

AutomaticOutlinePreparedAdmission? _nextAutomaticOutlineAdmission(
  AutomaticOutlinePreparedAdmission admission,
) {
  if (admission.accepted != null ||
      admission.backendAdmissionAttempt >= 10000) {
    return null;
  }
  final nextAttempt = admission.backendAdmissionAttempt + 1;
  final key = automaticOutlineRequestIdempotencyKey(
    admission.operationId,
    backendAdmissionAttempt: nextAttempt,
  );
  if (key == null) return null;
  final request = admission.request;
  return AutomaticOutlinePreparedAdmission(
    attemptId: admission.attemptId,
    localNoteId: admission.localNoteId,
    operationId: admission.operationId,
    request: NoteFileAgentRequest(
      noteId: request.noteId,
      inputPart: request.inputPart,
      inputPartRevisionId: request.inputPartRevisionId,
      targetPart: request.targetPart,
      targetPartRevisionId: request.targetPartRevisionId,
      instruction: request.instruction,
      selector: request.selector,
      idempotencyKey: key,
      modelProfileId: request.modelProfileId,
    ),
    allowExistingAutomaticOutline: admission.allowExistingAutomaticOutline,
    createdAt: admission.createdAt,
    backendAdmissionAttempt: nextAttempt,
  );
}

const _importedMediaOutlineInstruction =
    '请根据视频或音频的完整转写内容生成准确、清晰的中文纪要，保留关键事实、观点和结论。不添加原文没有的信息。';

bool _isImportedMediaOutlineOperation(String value) =>
    RegExp(r'^media-outline:ingestion_[A-Za-z0-9._-]{1,128}$').hasMatch(value);

NoteFileAgentSelector outlineSelectorForSource(V3MaterialSource source) =>
    switch (source) {
      V3MaterialSource.meeting ||
      V3MaterialSource.internalRecording ||
      V3MaterialSource.monologue ||
      V3MaterialSource.recordingCard => const NoteFileAgentSelector(
        agentProfileId: 'recording_postprocess_agent',
        skillProfileIds: <String>['meeting_minutes'],
      ),
      _ => const NoteFileAgentSelector(
        agentProfileId: 'general_minutes',
        skillProfileIds: <String>['general_minutes'],
      ),
    };

String _mapFileAgentFailure(String code) => switch (code) {
  'NOTE_FILE_AGENT_WORKSPACE_REQUIRED' => 'OUTLINE_WORKSPACE_REQUIRED',
  'NOTE_FILE_AGENT_SOURCE_REVISION_CHANGED' =>
    'OUTLINE_SOURCE_REVISION_CHANGED',
  'NOTE_FILE_AGENT_NOTE_READ_FAILED' ||
  'NOTE_FILE_AGENT_PART_READ_FAILED' ||
  'NOTE_FILE_AGENT_PART_RESPONSE_INVALID' ||
  'NOTE_FILE_AGENT_RUN_MISMATCH' => 'OUTLINE_SOURCE_READ_FAILED',
  'NOTE_FILE_AGENT_CREATE_FAILED' => 'OUTLINE_RUN_SUBMIT_FAILED',
  'NOTE_FILE_AGENT_ADMISSION_PENDING' ||
  'NOTE_FILE_AGENT_CREATE_RESPONSE_UNCERTAIN' =>
    'OUTLINE_ADMISSION_RESPONSE_UNCERTAIN',
  'AGENT_PROFILE_NOT_SELECTABLE' ||
  'SKILL_SELECTION_NOT_CANDIDATE' => 'OUTLINE_CAPABILITY_NOT_PUBLISHED',
  'NOTE_FILE_AGENT_POLL_FAILED' ||
  'NOTE_FILE_AGENT_POLL_TIMEOUT' => 'OUTLINE_RUN_POLL_FAILED',
  'NOTE_PART_VERSION_CONFLICT' ||
  'NOTE_FILE_AGENT_CONFLICT' => 'OUTLINE_WRITE_CONFLICT',
  'NOTE_FILE_AGENT_OUTPUT_EMPTY' ||
  'NOTE_FILE_AGENT_OUTPUT_REVISION_INVALID' ||
  'NOTE_FILE_AGENT_OUTPUT_REVISION_STALE' ||
  'NOTE_FILE_AGENT_SELECTOR_MISMATCH' => 'OUTLINE_RESULT_CONTRACT_INVALID',
  _ => code,
};

String? _nonEmpty(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}
