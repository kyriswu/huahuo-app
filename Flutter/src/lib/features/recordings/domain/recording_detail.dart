enum RecordingRemoteStatus {
  queued,
  uploading,
  uploaded,
  processing,
  asrRunning,
  speakerLabelPending,
  generatingMinutes,
  generatingSummary,
  depositing,
  deposited,
  completed,
  failed,
  timeout,
  cancelled,
}

final class RecordingAsset {
  const RecordingAsset({
    required this.recordingId,
    required this.title,
    required this.status,
    this.asrTaskId,
    this.noteId,
    this.contentLineId,
    this.recordedAt,
    this.transcriptStatus,
    this.speakerLabelStatus,
    this.minutesStatus,
    this.summaryStatus,
    this.depositStatus,
  });

  final String recordingId;
  final String title;
  final RecordingRemoteStatus status;
  final String? asrTaskId;
  final String? noteId;
  final String? contentLineId;
  final DateTime? recordedAt;
  final String? transcriptStatus;
  final String? speakerLabelStatus;
  final String? minutesStatus;
  final String? summaryStatus;
  final String? depositStatus;

  bool get isTerminal => _isTerminal(status);
}

final class RecordingNoteRef {
  const RecordingNoteRef({
    required this.noteId,
    required this.rawPartRevisionId,
    required this.outlinePartRevisionId,
  });

  final String noteId;
  final String rawPartRevisionId;
  final String? outlinePartRevisionId;
}

final class RecordingMinutesDocument {
  const RecordingMinutesDocument({
    required this.title,
    required this.overview,
    this.participants = const <RecordingMinutesParticipant>[],
    this.sections = const <RecordingMinutesSection>[],
    this.decisions = const <String>[],
    this.actionItems = const <RecordingMinutesActionItem>[],
    this.quoteHighlights = const <RecordingMinutesQuoteHighlight>[],
    this.openQuestions = const <String>[],
  });

  final String title;
  final String overview;
  final List<RecordingMinutesParticipant> participants;
  final List<RecordingMinutesSection> sections;
  final List<String> decisions;
  final List<RecordingMinutesActionItem> actionItems;
  final List<RecordingMinutesQuoteHighlight> quoteHighlights;
  final List<String> openQuestions;
}

final class RecordingMinutesParticipant {
  const RecordingMinutesParticipant({required this.displayName, this.role});

  final String displayName;
  final String? role;
}

final class RecordingMinutesSection {
  const RecordingMinutesSection({
    required this.heading,
    required this.summary,
    this.points = const <String>[],
  });

  final String heading;
  final String summary;
  final List<String> points;
}

final class RecordingMinutesActionItem {
  const RecordingMinutesActionItem({
    required this.content,
    this.ownerName,
    this.dueDate,
    this.status,
  });

  final String content;
  final String? ownerName;
  final String? dueDate;
  final String? status;
}

final class RecordingMinutesQuoteHighlight {
  const RecordingMinutesQuoteHighlight({
    required this.text,
    this.speakerName,
    this.reason,
  });

  final String text;
  final String? speakerName;
  final String? reason;
}

final class AsrTaskSnapshot {
  const AsrTaskSnapshot({
    required this.asrTaskId,
    required this.status,
    this.progress,
    this.message,
    this.version,
  });

  final String asrTaskId;
  final RecordingRemoteStatus status;
  final int? progress;
  final String? message;
  final int? version;

  bool get isTerminal => _isTerminal(status);
}

enum RecordingNoteOutlineTaskStatus {
  queued,
  running,
  succeeded,
  failed,
  timeout,
  deadLetter,
  ignored,
  cancelled,
}

/// The one server-owned post-summary receipt that has no aggregate status.
///
/// Other `subTasks` are intentionally not exposed: their payloads are worker
/// internals, while this receipt is needed to keep the automatic Note outline
/// observable after aggregate minutes and summary have already succeeded.
final class RecordingNoteOutlineTask {
  const RecordingNoteOutlineTask({
    required this.taskId,
    required this.status,
    this.failureCode,
  });

  final String taskId;
  final RecordingNoteOutlineTaskStatus status;
  final String? failureCode;

  bool get isActive =>
      status == RecordingNoteOutlineTaskStatus.queued ||
      status == RecordingNoteOutlineTaskStatus.running;

  bool get isSuccessful => status == RecordingNoteOutlineTaskStatus.succeeded;

  bool get isTerminal => !isActive;

  bool get isFailure =>
      status == RecordingNoteOutlineTaskStatus.failed ||
      status == RecordingNoteOutlineTaskStatus.timeout ||
      status == RecordingNoteOutlineTaskStatus.deadLetter ||
      status == RecordingNoteOutlineTaskStatus.ignored ||
      status == RecordingNoteOutlineTaskStatus.cancelled;
}

final class RecordingDetail {
  const RecordingDetail({
    required this.recording,
    this.asrTask,
    this.noteRef,
    this.finalTranscript,
    this.finalTranscriptConfirmed,
    this.minutes,
    this.minutesMarkdown,
    this.summary,
    this.noteOutlineTask,
    this.hasSubTaskSnapshot = false,
    this.retryActions = const <RecordingRetryAction>[],
  });

  final RecordingAsset recording;
  final AsrTaskSnapshot? asrTask;
  final RecordingNoteRef? noteRef;
  final String? finalTranscript;
  final bool? finalTranscriptConfirmed;
  final RecordingMinutesDocument? minutes;
  final String? minutesMarkdown;
  final String? summary;
  final RecordingNoteOutlineTask? noteOutlineTask;
  final bool hasSubTaskSnapshot;
  final List<RecordingRetryAction> retryActions;

  bool get isTerminal =>
      recording.isTerminal || _isFailureOrCancelled(asrTask?.status);

  bool get hasFinalTranscriptFact {
    final transcript = finalTranscript?.trim();
    return transcript != null &&
        transcript.isNotEmpty &&
        (finalTranscriptConfirmed ??
            _recordingHasFinalTranscriptFact(recording));
  }

  bool get hasGeneratedOutline =>
      minutes != null || minutesMarkdown?.trim().isNotEmpty == true;

  String? get canonicalNoteId {
    final noteId = noteRef?.noteId.trim();
    return noteId == null || noteId.isEmpty ? null : noteId;
  }

  bool get hasCloudAsset {
    final rawPartRevisionId = noteRef?.rawPartRevisionId.trim();
    return hasFinalTranscriptFact &&
        canonicalNoteId != null &&
        rawPartRevisionId != null &&
        rawPartRevisionId.isNotEmpty;
  }

  RecordingRemoteStatus? get rawTerminalFailureStatus {
    if (hasCloudAsset) return null;
    for (final status in <RecordingRemoteStatus?>[
      _tryParseRemoteStatus(recording.transcriptStatus),
      asrTask?.status,
      _tryParseRemoteStatus(recording.depositStatus),
    ]) {
      if (_isFailureOrCancelled(status)) return status;
    }
    if (!_isFailureOrCancelled(recording.status) ||
        _hasExplicitDerivedFailure) {
      return null;
    }
    return recording.status;
  }

  bool get hasCloudOutline {
    final outlinePartRevisionId = noteRef?.outlinePartRevisionId?.trim();
    if (!hasCloudAsset ||
        hasOutlineFailure ||
        outlinePartRevisionId == null ||
        outlinePartRevisionId.isEmpty) {
      return false;
    }
    return !hasSubTaskSnapshot || noteOutlineTask?.isSuccessful == true;
  }

  bool get hasCompletedProcessing => hasCloudOutline;

  bool get isTranscriptionSuccessful => hasFinalTranscriptFact;

  bool get hasOutlineFailure =>
      (hasFinalTranscriptFact && _isFailureOrCancelled(recording.status)) ||
      _isFailureOrCancelled(_tryParseRemoteStatus(recording.minutesStatus)) ||
      _isFailureOrCancelled(_tryParseRemoteStatus(recording.summaryStatus)) ||
      noteOutlineTask?.isFailure == true ||
      _hasAllowedPostprocessRetryAction;

  String? get outlineFailureCode {
    final task = noteOutlineTask;
    if (task?.isFailure == true) {
      final code = task?.failureCode?.trim();
      if (code != null && code.isNotEmpty) return code;
    }
    return switch (task?.status) {
      RecordingNoteOutlineTaskStatus.timeout => 'RECORDING_OUTLINE_TIMEOUT',
      RecordingNoteOutlineTaskStatus.deadLetter =>
        'RECORDING_OUTLINE_DEAD_LETTER',
      RecordingNoteOutlineTaskStatus.cancelled => 'RECORDING_OUTLINE_CANCELLED',
      RecordingNoteOutlineTaskStatus.ignored => 'RECORDING_OUTLINE_IGNORED',
      RecordingNoteOutlineTaskStatus.failed => 'RECORDING_OUTLINE_FAILED',
      _ when hasOutlineFailure => 'RECORDING_OUTLINE_FAILED',
      _ => null,
    };
  }

  bool get canRetryOutline => _hasAllowedPostprocessRetryAction;

  List<RecordingRetryAction> get effectiveRetryActions {
    final stages = <String>{};
    final effective = <RecordingRetryAction>[];
    for (final action in retryActions) {
      final stage = action.stage.trim();
      if (!action.allowed || stage.isEmpty || !stages.add(stage)) continue;
      // A newer canonical receipt wins over a retained failed subtask row.
      if (stage == 'recording_note_outline' &&
          (noteOutlineTask?.isActive == true ||
              noteOutlineTask?.isSuccessful == true)) {
        continue;
      }
      effective.add(action);
    }
    return List<RecordingRetryAction>.unmodifiable(effective);
  }

  bool isRetryAllowed(String rawStage) {
    final stage = rawStage.trim();
    return stage.isNotEmpty &&
        effectiveRetryActions.any((action) => action.stage.trim() == stage);
  }

  bool get _hasAllowedPostprocessRetryAction =>
      effectiveRetryActions.any((action) => action.stage.trim() != 'asr');

  bool get _hasExplicitDerivedFailure =>
      _isFailureOrCancelled(_tryParseRemoteStatus(recording.minutesStatus)) ||
      _isFailureOrCancelled(_tryParseRemoteStatus(recording.summaryStatus)) ||
      noteOutlineTask?.isFailure == true ||
      effectiveRetryActions.any((action) {
        final stage = action.stage.trim();
        return stage != 'asr' &&
            stage != 'recording_deposit' &&
            stage != 'workspace_write';
      });

  bool get shouldStopPolling {
    if (hasCloudAsset) return true;
    if (rawTerminalFailureStatus != null) return true;
    if (noteOutlineTask?.isActive == true) return false;
    if (hasFinalTranscriptFact) return false;
    return isTerminal;
  }
}

final class RecordingRetryAction {
  const RecordingRetryAction({
    required this.stage,
    required this.title,
    required this.allowed,
  });

  final String stage;
  final String title;
  final bool allowed;
}

RecordingRemoteStatus? _tryParseRemoteStatus(Object? value) {
  final text = _normalizedStatus(value);
  switch (text) {
    case 'queued':
    case 'pending':
    case 'created':
    case 'waiting':
      return RecordingRemoteStatus.queued;
    case 'uploading':
      return RecordingRemoteStatus.uploading;
    case 'uploaded':
      return RecordingRemoteStatus.uploaded;
    case 'processing':
    case 'running':
      return RecordingRemoteStatus.processing;
    case 'asr_running':
    case 'asr_pending':
    case 'transcribing':
    case 'transcription_running':
      return RecordingRemoteStatus.asrRunning;
    case 'speaker_label_pending':
    case 'speaker_labeling':
    case 'labeling':
    case 'transcribed':
      return RecordingRemoteStatus.speakerLabelPending;
    case 'generating_minutes':
    case 'minutes_generation':
    case 'minutes_generating':
    case 'speaker_confirmed':
    case 'final_transcript_generated':
      return RecordingRemoteStatus.generatingMinutes;
    case 'generating_summary':
    case 'summary_generation':
    case 'summary_generating':
      return RecordingRemoteStatus.generatingSummary;
    case 'depositing':
    case 'recording_deposit':
    case 'workspace_write':
      return RecordingRemoteStatus.depositing;
    case 'deposited':
      return RecordingRemoteStatus.deposited;
    case 'completed':
    case 'succeeded':
    case 'success':
    case 'done':
    case 'finished':
      return RecordingRemoteStatus.completed;
    case 'failed':
    case 'error':
    case 'asr_failed':
      return RecordingRemoteStatus.failed;
    case 'timeout':
    case 'timed_out':
      return RecordingRemoteStatus.timeout;
    case 'cancelled':
    case 'canceled':
      return RecordingRemoteStatus.cancelled;
    default:
      return null;
  }
}

String _normalizedStatus(Object? value) {
  return value is String
      ? value.trim().toLowerCase().replaceAll('-', '_').replaceAll(' ', '_')
      : '';
}

bool _isCompletedStatus(String value) {
  return value == 'completed' ||
      value == 'succeeded' ||
      value == 'success' ||
      value == 'done' ||
      value == 'finished' ||
      value == 'deposited';
}

bool _isFailureOrCancelled(RecordingRemoteStatus? status) {
  return status == RecordingRemoteStatus.failed ||
      status == RecordingRemoteStatus.timeout ||
      status == RecordingRemoteStatus.cancelled;
}

bool _isTerminal(RecordingRemoteStatus status) {
  return status == RecordingRemoteStatus.completed ||
      status == RecordingRemoteStatus.deposited ||
      status == RecordingRemoteStatus.failed ||
      status == RecordingRemoteStatus.timeout ||
      status == RecordingRemoteStatus.cancelled;
}

bool _recordingHasFinalTranscriptFact(RecordingAsset recording) {
  final transcriptStatus = recording.transcriptStatus;
  if (transcriptStatus != null) {
    return transcriptStatus == 'final_transcript_generated' ||
        _isCompletedStatus(transcriptStatus);
  }
  return recording.status == RecordingRemoteStatus.completed ||
      recording.status == RecordingRemoteStatus.deposited;
}
