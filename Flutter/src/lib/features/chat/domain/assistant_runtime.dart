/// Provider-neutral lifecycle types for an assistant turn.
///
/// These types intentionally do not name an Agent, Bot, Workflow, vendor
/// event, or transport format. A remote adapter maps its wire contract into
/// this model before application code observes it.
enum AssistantRunStatus {
  resolving,
  planning,
  waitingForInput,
  queued,
  running,
  stopping,
  succeeded,
  failed,
  timedOut,
  cancelled,
  orphaned,
  unknown;

  bool get isTerminal => switch (this) {
    AssistantRunStatus.succeeded ||
    AssistantRunStatus.failed ||
    AssistantRunStatus.timedOut ||
    AssistantRunStatus.cancelled ||
    AssistantRunStatus.orphaned => true,
    _ => false,
  };
}

enum AssistantCompletionQuality {
  normal,
  degraded,
  fallback,
  cancelled,
  unknown,
}

enum AssistantStreamEventKind { update, gap, capacityUnavailable }

enum AssistantStreamEventType {
  draftDelta,
  toolInvocation,
  status,
  output,
  unknown,
}

final class AssistantOutputFile {
  const AssistantOutputFile({
    required this.resourceId,
    required this.fileName,
    required this.mimeType,
    required this.sizeBytes,
  });

  final String resourceId;
  final String fileName;
  final String mimeType;
  final int sizeBytes;
}

/// Provider-neutral projection of one public tool invocation. The shape is
/// intentionally limited to facts the app may render or reconcile.
final class AssistantToolTrace {
  const AssistantToolTrace({
    required this.invocationId,
    required this.toolName,
    required this.state,
    required this.createdAt,
    required this.outputFiles,
    this.outcome,
    this.completedAt,
    this.inputSummary = const <String, Object?>{},
  });

  final String invocationId;
  final String toolName;
  final String state;
  final String? outcome;
  final DateTime createdAt;
  final DateTime? completedAt;
  final List<AssistantOutputFile> outputFiles;
  final Map<String, Object?> inputSummary;
}

/// A provider-neutral public event. Gaps and capacity errors are represented
/// explicitly so the tracker can choose polling without parsing wire errors.
final class AssistantStreamEvent {
  const AssistantStreamEvent({
    required this.kind,
    this.type = AssistantStreamEventType.unknown,
    this.status,
    this.sequence,
    this.createdAt,
    this.deltaText,
    this.replace = false,
    this.invocationId,
    this.toolName,
    this.toolState,
    this.outcome,
    this.outputFiles = const <AssistantOutputFile>[],
    this.resumeAfterSequence,
    this.errorCode,
    this.retryable,
  });

  final AssistantStreamEventKind kind;
  final AssistantStreamEventType type;
  final AssistantRunStatus? status;
  final int? sequence;
  final DateTime? createdAt;
  final String? deltaText;
  final bool replace;
  final String? invocationId;
  final String? toolName;
  final String? toolState;
  final String? outcome;
  final List<AssistantOutputFile> outputFiles;
  final int? resumeAfterSequence;
  final String? errorCode;
  final bool? retryable;
}

/// Opaque handle for an accepted assistant turn.
///
/// The value is owned by the adapter. Application code must not infer a
/// provider-specific prefix or construct one from a vendor identifier.
final class AssistantRunHandle {
  const AssistantRunHandle(this.value);

  final String value;

  bool get isValid {
    final normalized = value.trim();
    return normalized.isNotEmpty && normalized.length <= 256;
  }
}

final class AssistantRunOutput {
  const AssistantRunOutput({required this.messageId, required this.text});

  final String messageId;
  final String text;
}

final class AssistantRunFailure {
  const AssistantRunFailure({required this.code, this.retryable = false});

  final String code;
  final bool retryable;
}

final class AssistantRunSnapshot {
  const AssistantRunSnapshot({
    required this.handle,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    this.workspaceId,
    this.conversationId,
    this.correlationId,
    this.output,
    this.failure,
    this.toolTrace = const <AssistantToolTrace>[],
    this.completionQuality = AssistantCompletionQuality.unknown,
  });

  final AssistantRunHandle handle;
  final AssistantRunStatus status;
  /// Optional tenant scope returned by adapters that can prove workspace
  /// ownership. It is never inferred from a provider run identifier.
  final String? workspaceId;
  final String? conversationId;

  /// Optional application correlation value used to bind a result to a
  /// submitted turn. It has no provider-specific meaning.
  final String? correlationId;
  final AssistantRunOutput? output;
  final AssistantRunFailure? failure;
  final List<AssistantToolTrace> toolTrace;
  final AssistantCompletionQuality completionQuality;
  final DateTime createdAt;
  final DateTime updatedAt;

  bool get isTerminal => status.isTerminal;

  bool get hasDurableOutput =>
      status == AssistantRunStatus.succeeded && output != null;
}

final class AssistantRuntimeRead<T> {
  const AssistantRuntimeRead._({
    this.data,
    this.errorCode,
    this.outcomeUnknown = false,
  });

  const AssistantRuntimeRead.success(T data) : this._(data: data);

  const AssistantRuntimeRead.failure(
    String errorCode, {
    bool outcomeUnknown = false,
  }) : this._(errorCode: errorCode, outcomeUnknown: outcomeUnknown);

  final T? data;
  final String? errorCode;
  final bool outcomeUnknown;

  bool get ok => data != null && errorCode == null;
}

final class AssistantRuntimeReadLease<T> {
  const AssistantRuntimeReadLease({required this.result, required this.cancel});

  final Future<AssistantRuntimeRead<T>> result;
  final void Function() cancel;
}

/// Application-facing read port for a long-running assistant turn.
abstract interface class AssistantRuntimePort {
  Future<AssistantRuntimeRead<AssistantRunSnapshot>> readRun({
    required AssistantRunHandle handle,
  });
}

/// Optional lifecycle-owned read capability. Implementations must cancel the
/// underlying request when the tracker is paused or disposed.
abstract interface class AssistantRuntimeReadLeasePort {
  AssistantRuntimeReadLease<AssistantRunSnapshot> leaseReadRun({
    required AssistantRunHandle handle,
  });
}

abstract interface class AssistantRuntimeStreamPort {
  Future<AssistantRuntimeRead<Stream<AssistantStreamEvent>>> streamEvents({
    required AssistantRunHandle handle,
    String? lastEventId,
  });
}

enum AssistantProgressEventType { draftDelta, status, output, unknown }

final class AssistantProgressEvent {
  const AssistantProgressEvent({
    required this.sequence,
    required this.type,
    this.runHandle,
    this.messageId,
    this.title,
    this.summary,
    this.deltaText,
    this.replace = false,
  });

  final int sequence;
  final AssistantProgressEventType type;
  final String? runHandle;
  final String? messageId;
  final String? title;
  final String? summary;
  final String? deltaText;
  final bool replace;
}

final class AssistantProgressPage {
  const AssistantProgressPage({
    required this.conversationId,
    required this.events,
    required this.nextSequence,
  });

  final String conversationId;
  final List<AssistantProgressEvent> events;
  final int nextSequence;
}

abstract interface class AssistantThreadProgressPort {
  Future<AssistantRuntimeRead<AssistantProgressPage>> readProgress({
    required String conversationId,
    required int afterSequence,
  });
}
