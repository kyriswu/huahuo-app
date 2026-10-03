import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../../../core/api/api_envelope.dart';
import '../../../core/database/app_preferences_dao.dart';
import '../../../core/database/database_worker.dart';
import '../../../core/database/database_write_queue.dart';
import '../../../core/database/diagnostic_log_dao.dart';
import '../../../core/diagnostics/diagnostic_logger.dart';
import '../../../core/performance/runtime_activity_metrics.dart';
import '../../../core/tasking/orchestrated_poller.dart';
import '../../../core/tasking/task_orchestrator.dart';
import '../../recordings/data/recording_api.dart';
import '../../ui_v3/data/note_file_agent_client.dart';
import '../domain/assistant_runtime.dart';
import '../domain/chat_models.dart';
import 'chat_run_reconciliation.dart';

abstract interface class ChatRunTrackingPort {
  Future<void> track({
    required String agentRunId,
    required String threadId,
    required ChatScene scene,
    ChatConversationPurpose purpose = ChatConversationPurpose.general,
  });
}

/// Optional capability for an accepted Run whose public task identity differs
/// from the Agent Run identity used by the runtime transport.
abstract interface class ChatAcceptedRunTrackingPort {
  Future<void> trackAcceptedRun({
    required String agentRunId,
    required String? publicTaskId,
    required String threadId,
    required ChatScene scene,
    ChatConversationPurpose purpose = ChatConversationPurpose.general,
  });
}

/// Optional capability for server-advertised work that originated on another
/// device or before this process was started.
abstract interface class ChatRunServerActiveRunTrackingPort {
  Future<void> trackServerActiveRuns({
    required String threadId,
    required ChatScene scene,
    required Iterable<ChatActiveRun> runs,
    ChatConversationPurpose purpose = ChatConversationPurpose.general,
  });
}

/// Optional presentation metadata for exact account-owned tasks.
///
/// Subject titles never participate in task identity or reconciliation. They
/// are persisted only so the message center can name work after route disposal
/// or process recreation.
abstract interface class AgentTaskSubjectMetadataPort {
  Future<void> rememberChatThreadSubject({
    required String threadId,
    required String subjectTitle,
  });

  Future<void> rememberKnowledgeAssetSubject({
    required String localNoteId,
    required String subjectTitle,
  });
}

abstract interface class AgentTaskSubjectLookupPort {
  int get taskSubjectRevision;

  String? chatThreadSubject(String threadId);

  String? knowledgeAssetSubject(String localNoteId);
}

abstract interface class ChatRunStatusPort {
  bool isThreadPending(String threadId);

  /// Whether this tracker has observed the given run in the active account.
  /// This lets a stale server thread snapshot stop showing progress after the
  /// durable Run has already reached a terminal status.
  bool hasTrackedThreadRun(String threadId, String agentRunId);

  String? threadRunStatus(String threadId);

  List<AgentRunToolTrace> threadToolTrace(String threadId);
}

/// Distinguishes durable reply reconciliation from visible in-progress work.
abstract interface class ChatRunReconciliationPort {
  bool needsThreadReconciliation(String threadId);
}

abstract interface class ChatRunRecoveryPort {
  ChatRunReconciliationSnapshot? reconciliationForThread(String threadId);

  Future<bool> recoverThread(String threadId);
}

/// Optional exact-run lookup for presentation that must never borrow a
/// different pending Run's status from the same thread.
abstract interface class ChatRunActivityPort {
  ChatRunActivity? activityFor({
    required String threadId,
    required String agentRunId,
  });

  List<ChatRunActivity> activitiesForThread(String threadId);
}

/// Tracker-local read projection. The neutral snapshot is the only lifecycle
/// contract; [legacyToolTrace] exists solely to preserve object identity for
/// older in-process adapters until their tests migrate to neutral traces.
final class _TrackerRunRead {
  const _TrackerRunRead(this.snapshot, this.legacyToolTrace);

  final AssistantRunSnapshot snapshot;
  final List<AgentRunToolTrace> legacyToolTrace;
}

@immutable
final class ChatRunActivity {
  ChatRunActivity({
    required this.agentRunId,
    required this.threadId,
    required this.status,
    required this.createdAt,
    this.completedAt,
    Iterable<AgentRunToolTrace> toolTrace = const <AgentRunToolTrace>[],
  }) : toolTrace = List<AgentRunToolTrace>.unmodifiable(toolTrace);

  final String agentRunId;
  final String threadId;
  final String status;
  final DateTime createdAt;
  final DateTime? completedAt;
  final List<AgentRunToolTrace> toolTrace;

  bool get isTerminal => _isTerminalTaskStatus(status);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ChatRunActivity &&
          agentRunId == other.agentRunId &&
          threadId == other.threadId &&
          status == other.status &&
          createdAt == other.createdAt &&
          completedAt == other.completedAt &&
          _sameToolTrace(toolTrace, other.toolTrace);

  @override
  int get hashCode => Object.hash(
    agentRunId,
    threadId,
    status,
    createdAt,
    completedAt,
    Object.hashAll(
      toolTrace.map(
        (trace) => Object.hash(
          trace.invocationId,
          trace.toolName,
          trace.state,
          trace.outcome,
          trace.completedAt,
          trace.outputFiles.length,
        ),
      ),
    ),
  );
}

/// Marks the global tracker that may own lifecycle polling after an accepted
/// Run for the current account.
abstract interface class ChatRunLifecycleOwnerPort {
  bool get canTrackAcceptedRuns;
}

/// Exposes the latest terminal Chat Run without making its lifecycle a page
/// concern. Implementations are also expected to be [Listenable].
abstract interface class ChatRunCompletionSourcePort {
  int get completionSequence;

  ChatRunCompletion? get lastCompletion;
}

/// Account-owned terminal hand-off for observers that attach after more than
/// one Run has completed.
abstract interface class ChatRunCompletionJournalPort {
  List<ChatRunCompletion> completionsForThread(String threadId);
}

/// Emits only public, ephemeral Assistant text deltas from an active Agent Run
/// SSE stream. The account-level Run ledger intentionally never stores text.
abstract interface class ChatRunDraftDeltaSourcePort {
  int get draftDeltaSequence;

  ChatRunDraftDelta? get lastDraftDelta;
}

/// Exact, memory-only draft recovery for a controller that attaches after the
/// account tracker has already consumed one or more SSE fragments.
abstract interface class ChatRunDraftSnapshotSourcePort {
  ChatRunDraftSnapshot? draftSnapshotFor({
    required String threadId,
    required String agentRunId,
  });
}

final class ChatRunDraftSnapshot {
  const ChatRunDraftSnapshot({
    required this.agentRunId,
    required this.threadId,
    required this.scene,
    required this.purpose,
    required this.eventSequence,
    required this.text,
    this.state = ChatRunDraftState.streaming,
  });

  final String agentRunId;
  final String threadId;
  final ChatScene scene;
  final ChatConversationPurpose purpose;
  final int eventSequence;
  final String text;
  final ChatRunDraftState state;
}

enum ChatRunDraftState { streaming, awaitingRecovery, settled }

final class ChatRunDraftDelta {
  const ChatRunDraftDelta({
    required this.agentRunId,
    required this.threadId,
    required this.scene,
    required this.purpose,
    required this.eventSequence,
    required this.deltaText,
    this.replace = false,
  });

  final String agentRunId;
  final String threadId;
  final ChatScene scene;
  final ChatConversationPurpose purpose;
  final int eventSequence;
  final String deltaText;
  final bool replace;
}

abstract interface class DerivedPartRunTrackingPort {
  Future<void> trackDerivedPart({
    required String fileAgentRunId,
    String? agentRunId,
    String? status,
    String? inputPartRevisionId,
    String? targetPartRevisionId,
    String? operationId,
    required String localNoteId,
    required String remoteNoteId,
    required NoteFileAgentPart targetPart,
  });

  bool isDerivedPartPending(String localNoteId, NoteFileAgentPart targetPart);

  String? derivedPartStatus(String localNoteId, NoteFileAgentPart targetPart);

  List<AgentRunToolTrace> derivedPartToolTrace(
    String localNoteId,
    NoteFileAgentPart targetPart,
  );

  DerivedPartRunCompletion? get lastDerivedCompletion;
}

abstract interface class DerivedPartResultVerificationPort {
  Future<String?> verifySucceededDerivedOutputRevision({
    required String fileAgentRunId,
    required String remoteNoteId,
    required NoteFileAgentPart targetPart,
  });
}

abstract interface class RecordingOutlineRunTrackingPort {
  Future<void> trackRecordingOutline({
    required String recordingId,
    required String localNoteId,
    required String remoteNoteId,
    bool restart = false,
    String? expectedPublicTaskId,
    String? supersededPublicTaskId,
  });

  bool isRecordingOutlinePending(String localNoteId);

  String? recordingOutlineStatus(String localNoteId);

  bool acceptsRecordingOutlineTask(String localNoteId, String? publicTaskId);

  RecordingOutlineRunCompletion? get lastRecordingOutlineCompletion;
}

extension DerivedPartRunTrackingReadX on DerivedPartRunTrackingPort {
  String? derivedOutlineStatus(String localNoteId) =>
      derivedPartStatus(localNoteId, NoteFileAgentPart.outline);

  String? derivedGerminationStatus(String localNoteId) =>
      derivedPartStatus(localNoteId, NoteFileAgentPart.germination);
}

/// A bounded public task record used by the message center when a foreground
/// task reaches terminal state before the server notification Outbox arrives.
final class AgentTaskLedgerEntry {
  const AgentTaskLedgerEntry._({
    required this.taskId,
    required this.kind,
    required this.status,
    required this.createdAt,
    this.threadId,
    this.scene,
    this.purpose,
    this.localNoteId,
    this.targetPart,
    this.failureCode,
    this.publicTaskId,
    this.agentRunId,
    this.outputPartRevisionId,
    this.remoteNoteId,
    this.recordingId,
    this.subjectTitle,
    this.inputPartRevisionId,
    this.targetPartRevisionId,
    this.operationId,
  });

  factory AgentTaskLedgerEntry.chat({
    required String taskId,
    required String threadId,
    required ChatScene scene,
    ChatConversationPurpose purpose = ChatConversationPurpose.general,
    required String status,
    required DateTime createdAt,
    String? failureCode,
    String? publicTaskId,
    String? subjectTitle,
  }) => AgentTaskLedgerEntry._(
    taskId: taskId,
    kind: 'chat',
    threadId: threadId,
    scene: scene,
    purpose: purpose,
    status: status,
    createdAt: createdAt,
    failureCode: failureCode,
    publicTaskId: publicTaskId,
    subjectTitle: _safeTaskSubjectTitle(subjectTitle),
  );

  factory AgentTaskLedgerEntry.derivedPart({
    required String taskId,
    required String localNoteId,
    required NoteFileAgentPart targetPart,
    required String status,
    required DateTime createdAt,
    String? failureCode,
    String? outputPartRevisionId,
    String? remoteNoteId,
    String? subjectTitle,
    String? inputPartRevisionId,
    String? targetPartRevisionId,
    String? operationId,
    String? agentRunId,
  }) => AgentTaskLedgerEntry._(
    taskId: taskId,
    kind: 'derived_part',
    localNoteId: localNoteId,
    targetPart: targetPart,
    status: status,
    createdAt: createdAt,
    failureCode: failureCode,
    outputPartRevisionId: outputPartRevisionId,
    remoteNoteId: remoteNoteId,
    subjectTitle: _safeTaskSubjectTitle(subjectTitle),
    inputPartRevisionId: inputPartRevisionId,
    targetPartRevisionId: targetPartRevisionId,
    operationId: operationId,
    agentRunId: _safeOptionalAgentRunId(agentRunId),
  );

  factory AgentTaskLedgerEntry.recordingOutline({
    required String taskId,
    required String recordingId,
    required String localNoteId,
    required String remoteNoteId,
    required String status,
    required DateTime createdAt,
    String? publicTaskId,
    String? failureCode,
    String? outputPartRevisionId,
    String? subjectTitle,
  }) => AgentTaskLedgerEntry._(
    taskId: taskId,
    kind: 'recording_outline',
    publicTaskId: publicTaskId,
    localNoteId: localNoteId,
    remoteNoteId: remoteNoteId,
    recordingId: recordingId,
    targetPart: NoteFileAgentPart.outline,
    status: status,
    createdAt: createdAt,
    failureCode: failureCode,
    outputPartRevisionId: outputPartRevisionId,
    subjectTitle: _safeTaskSubjectTitle(subjectTitle),
  );

  final String taskId;
  final String kind;
  final String? threadId;
  final ChatScene? scene;
  final ChatConversationPurpose? purpose;
  final String? localNoteId;
  final NoteFileAgentPart? targetPart;
  final String status;
  final DateTime createdAt;
  final String? failureCode;
  final String? publicTaskId;
  final String? agentRunId;
  final String? outputPartRevisionId;
  final String? remoteNoteId;
  final String? recordingId;
  final String? subjectTitle;
  final String? inputPartRevisionId;
  final String? targetPartRevisionId;
  final String? operationId;

  bool get isTerminal => _isTerminalTaskStatus(status);

  List<String> get resultTaskIds => <String>{
    taskId,
    if (publicTaskId != null) publicTaskId!,
    if (agentRunId != null) agentRunId!,
  }.toList(growable: false);
}

abstract interface class AgentTaskLedgerPort {
  List<AgentTaskLedgerEntry> get taskLedger;
}

/// One notification-boundary patch for the public task ledger. A consumer that
/// misses a sequence must rebuild from [AgentTaskLedgerPort.taskLedger].
final class AgentTaskLedgerDelta {
  AgentTaskLedgerDelta({
    required Iterable<AgentTaskLedgerEntry> upserts,
    required Iterable<String> removedTaskIds,
    this.reset = false,
  }) : upserts = Map<String, AgentTaskLedgerEntry>.unmodifiable(
         <String, AgentTaskLedgerEntry>{
           for (final entry in upserts) entry.taskId: entry,
         },
       ),
       removedTaskIds = Set<String>.unmodifiable(removedTaskIds);

  final Map<String, AgentTaskLedgerEntry> upserts;
  final Set<String> removedTaskIds;
  final bool reset;
}

abstract interface class AgentTaskLedgerDeltaSourcePort {
  int get taskLedgerDeltaSequence;

  AgentTaskLedgerDelta? get lastTaskLedgerDelta;
}

final class ChatRunCheckpointPersistence {
  ChatRunCheckpointPersistence({
    required ChatRunCheckpointWorkerPort worker,
    required DatabaseWriteQueue writeQueue,
  }) : // Public parameter names intentionally differ from private storage.
       // ignore: prefer_initializing_formals
       _worker = worker,
       // ignore: prefer_initializing_formals
       _writeQueue = writeQueue;

  final ChatRunCheckpointWorkerPort _worker;
  final DatabaseWriteQueue _writeQueue;
  final Map<String, Map<String, String>> _persistedByScope =
      <String, Map<String, String>>{};
  final Map<String, int> _scopeMutationRevisions = <String, int>{};
  final Map<String, Future<void>> _replaceTailsByScope =
      <String, Future<void>>{};

  bool get isEnabled =>
      _worker.isEnabled && !_worker.isDisposed && !_writeQueue.isDisposed;

  Future<List<ChatRunCheckpoint>> load(String userScope) async {
    if (!isEnabled) return const <ChatRunCheckpoint>[];
    final mutationRevision = _scopeMutationRevisions[userScope] ?? 0;
    final checkpoints = await _worker.listChatRunCheckpoints(userScope);
    if ((_scopeMutationRevisions[userScope] ?? 0) == mutationRevision) {
      _persistedByScope[userScope] = <String, String>{
        for (final checkpoint in checkpoints)
          checkpoint.runId: _checkpointSignature(checkpoint),
      };
    }
    return checkpoints;
  }

  Future<void> replace({
    required String userScope,
    required Iterable<ChatRunCheckpoint> checkpoints,
    required FutureOr<void> Function() legacyFallback,
  }) => _enqueueReplacement(
    userScope: userScope,
    checkpoints: checkpoints,
    legacyFallback: legacyFallback,
    alwaysCommitLegacy: false,
  );

  Future<void> _enqueueReplacement({
    required String userScope,
    required Iterable<ChatRunCheckpoint> checkpoints,
    required FutureOr<void> Function() legacyFallback,
    required bool alwaysCommitLegacy,
  }) {
    _scopeMutationRevisions[userScope] =
        (_scopeMutationRevisions[userScope] ?? 0) + 1;
    final desired = <String, ChatRunCheckpoint>{
      for (final checkpoint in checkpoints) checkpoint.runId: checkpoint,
    };
    final previous = _replaceTailsByScope[userScope] ?? Future<void>.value();
    final write = previous.then<void>(
      (_) => _replaceNow(
        userScope: userScope,
        desired: desired,
        legacyFallback: legacyFallback,
        alwaysCommitLegacy: alwaysCommitLegacy,
      ),
      onError: (Object _, StackTrace __) => _replaceNow(
        userScope: userScope,
        desired: desired,
        legacyFallback: legacyFallback,
        alwaysCommitLegacy: alwaysCommitLegacy,
      ),
    );
    _replaceTailsByScope[userScope] = write;
    return write;
  }

  Future<void> _replaceNow({
    required String userScope,
    required Map<String, ChatRunCheckpoint> desired,
    required FutureOr<void> Function() legacyFallback,
    required bool alwaysCommitLegacy,
  }) async {
    if (!isEnabled) {
      await legacyFallback();
      return;
    }
    final scopeKey = sha256
        .convert(utf8.encode(userScope))
        .toString()
        .substring(0, 24);
    var workerFailed = false;
    try {
      await _writeQueue.enqueue(
        key: 'chat-checkpoints:$scopeKey',
        operationLabel: 'checkpoint_diff',
        table: 'chat_run_checkpoints',
        reason: 'run_checkpoint',
        callerFeature: 'chat',
        rows: desired.length,
        operation: () async {
          try {
            var persisted = _persistedByScope[userScope];
            if (persisted == null) {
              final stored = await _worker.listChatRunCheckpoints(userScope);
              persisted = <String, String>{
                for (final checkpoint in stored)
                  checkpoint.runId: _checkpointSignature(checkpoint),
              };
            }
            final next = <String, String>{};
            final upserts = <ChatRunCheckpoint>[];
            for (final entry in desired.entries) {
              final signature = _checkpointSignature(entry.value);
              next[entry.key] = signature;
              if (persisted[entry.key] == signature) continue;
              upserts.add(entry.value);
            }
            final deletions = <String>[
              for (final runId in persisted.keys)
                if (!desired.containsKey(runId)) runId,
            ];
            if (upserts.isNotEmpty || deletions.isNotEmpty) {
              await _worker.applyChatRunCheckpointChanges(
                userScope: userScope,
                upserts: upserts,
                deletions: deletions,
              );
            }
            _persistedByScope[userScope] = next;
          } catch (_) {
            workerFailed = true;
          }
        },
      );
    } catch (_) {
      workerFailed = true;
    }
    if (workerFailed || alwaysCommitLegacy) await legacyFallback();
  }

  Future<void> clear({
    required String userScope,
    required FutureOr<void> Function() legacyFallback,
  }) => _enqueueReplacement(
    userScope: userScope,
    checkpoints: const <ChatRunCheckpoint>[],
    legacyFallback: legacyFallback,
    alwaysCommitLegacy: true,
  );

  Future<void> flush() async {
    await Future.wait<void>(_replaceTailsByScope.values);
    await _writeQueue.flush();
  }

  String _checkpointSignature(ChatRunCheckpoint checkpoint) =>
      jsonEncode(<String, Object?>{
        'runId': checkpoint.runId,
        'kind': checkpoint.kind.wireName,
        'role': checkpoint.role.wireName,
        'status': checkpoint.status,
        'eventSequence': checkpoint.eventSequence,
        'threadId': checkpoint.threadId,
        'scene': checkpoint.scene,
        'purpose': checkpoint.purpose,
        'localNoteId': checkpoint.localNoteId,
        'targetPart': checkpoint.targetPart,
        'failureCode': checkpoint.failureCode,
        'createdAt': checkpoint.createdAt.toUtc().toIso8601String(),
        'publicState': checkpoint.publicState,
      });
}

final class ChatRunCompletion {
  const ChatRunCompletion({
    required this.agentRunId,
    required this.threadId,
    required this.scene,
    this.purpose = ChatConversationPurpose.general,
    required this.status,
    this.completionMode,
    this.assistantMessageId,
    this.failureCode,
    this.completedAt,
  });

  final String agentRunId;
  final String threadId;
  final ChatScene scene;
  final ChatConversationPurpose purpose;
  final String status;
  final String? completionMode;
  final String? assistantMessageId;
  final String? failureCode;
  final DateTime? completedAt;
}

final class DerivedPartRunCompletion {
  const DerivedPartRunCompletion({
    required this.fileAgentRunId,
    this.agentRunId,
    required this.localNoteId,
    required this.remoteNoteId,
    required this.targetPart,
    required this.status,
    this.outputPartRevisionId,
    this.failureCode,
    this.subjectTitle,
    this.inputPartRevisionId,
    this.targetPartRevisionId,
    this.operationId,
  });

  final String fileAgentRunId;
  final String? agentRunId;
  final String localNoteId;
  final String remoteNoteId;
  final NoteFileAgentPart targetPart;
  final String status;
  final String? outputPartRevisionId;
  final String? failureCode;
  final String? subjectTitle;
  final String? inputPartRevisionId;
  final String? targetPartRevisionId;
  final String? operationId;
}

final class RecordingOutlineRunCompletion {
  const RecordingOutlineRunCompletion({
    required this.trackingTaskId,
    required this.recordingId,
    required this.localNoteId,
    required this.remoteNoteId,
    required this.status,
    this.publicTaskId,
    this.outputPartRevisionId,
    this.failureCode,
    this.subjectTitle,
  });

  final String trackingTaskId;
  final String recordingId;
  final String localNoteId;
  final String remoteNoteId;
  final String status;
  final String? publicTaskId;
  final String? outputPartRevisionId;
  final String? failureCode;
  final String? subjectTitle;
}

final class ChatRunTracker extends ChangeNotifier
    implements
        ChatRunTrackingPort,
        ChatAcceptedRunTrackingPort,
        ChatRunServerActiveRunTrackingPort,
        AgentTaskSubjectMetadataPort,
        AgentTaskSubjectLookupPort,
        ChatRunStatusPort,
        ChatRunReconciliationPort,
        ChatRunRecoveryPort,
        ChatRunActivityPort,
        ChatRunLifecycleOwnerPort,
        ChatRunCompletionSourcePort,
        ChatRunCompletionJournalPort,
        ChatRunDraftDeltaSourcePort,
        ChatRunDraftSnapshotSourcePort,
        DerivedPartRunTrackingPort,
        DerivedPartResultVerificationPort,
        RecordingOutlineRunTrackingPort,
        AgentTaskLedgerPort,
        AgentTaskLedgerDeltaSourcePort {
  ChatRunTracker({
    required AssistantRuntimePort assistantRuntime,
    AssistantRuntimeStreamPort? assistantRuntimeStream,
    NoteFileAgentRunStatusPort? fileAgentRuns,
    RecordingApiPort? recordingApi,
    required AppPreferencesDao preferences,
    required String userScope,
    ChatRunCheckpointPersistence? checkpointPersistence,
    this.diagnosticLogger,
    this.pollInterval = const Duration(seconds: 3),
    this.eventStreamReconnectDelay = const Duration(seconds: 1),
    this.eventStreamSilentTimeout = const Duration(seconds: 20),
    this.fallbackMaximumDelay = const Duration(seconds: 30),
    this.checkpointInterval = const Duration(milliseconds: 750),
    this.draftEventInterval = const Duration(milliseconds: 50),
    Future<void> Function()? onTerminal,
    Future<bool> Function(DerivedPartRunCompletion completion)?
    onDerivedPartTerminal,
    Future<bool> Function(RecordingOutlineRunCompletion completion)?
    onRecordingOutlineTerminal,
    DateTime Function()? now,
    double Function()? randomDouble,
    void Function()? onCheckpointPersisted,
    RuntimeActivityMetrics? runtimeActivityMetrics,
    TaskOrchestrator? taskOrchestrator,
    this.chatSseAuthoritative = true,
  }) : // The public argument names intentionally differ from private fields.
       // ignore: prefer_initializing_formals
       _assistantRuntime = assistantRuntime,
       _assistantRuntimeStream =
           assistantRuntimeStream ??
           (assistantRuntime is AssistantRuntimeStreamPort
               ? assistantRuntime as AssistantRuntimeStreamPort
               : null),
       // ignore: prefer_initializing_formals
       _fileAgentRuns = fileAgentRuns,
       // ignore: prefer_initializing_formals
       _recordingApi = recordingApi,
       // ignore: prefer_initializing_formals
       _preferences = preferences,
       // ignore: prefer_initializing_formals
       _checkpointPersistence = checkpointPersistence,
       // ignore: prefer_initializing_formals
       _userScope = userScope,
       // ignore: prefer_initializing_formals
       _onTerminal = onTerminal,
       // ignore: prefer_initializing_formals
       _onDerivedPartTerminal = onDerivedPartTerminal,
       // ignore: prefer_initializing_formals
       _onRecordingOutlineTerminal = onRecordingOutlineTerminal,
       _now = now ?? DateTime.now,
       _randomDouble = randomDouble ?? _defaultRandomDouble,
       // ignore: prefer_initializing_formals
       _onCheckpointPersisted = onCheckpointPersisted,
       // ignore: prefer_initializing_formals
       _runtimeActivityMetrics = runtimeActivityMetrics,
       // ignore: prefer_initializing_formals
       _taskOrchestrator = taskOrchestrator;

  final AssistantRuntimePort _assistantRuntime;
  final AssistantRuntimeStreamPort? _assistantRuntimeStream;
  final NoteFileAgentRunStatusPort? _fileAgentRuns;
  final RecordingApiPort? _recordingApi;
  final AppPreferencesDao _preferences;
  final ChatRunCheckpointPersistence? _checkpointPersistence;
  final DiagnosticLogger? diagnosticLogger;
  final String _userScope;
  final Future<void> Function()? _onTerminal;
  final Future<bool> Function(DerivedPartRunCompletion completion)?
  _onDerivedPartTerminal;
  final Future<bool> Function(RecordingOutlineRunCompletion completion)?
  _onRecordingOutlineTerminal;
  final Duration pollInterval;
  final Duration eventStreamReconnectDelay;
  final Duration eventStreamSilentTimeout;
  final Duration fallbackMaximumDelay;
  final Duration checkpointInterval;
  final Duration draftEventInterval;
  final bool chatSseAuthoritative;
  final DateTime Function() _now;
  final double Function() _randomDouble;
  final void Function()? _onCheckpointPersisted;
  final RuntimeActivityMetrics? _runtimeActivityMetrics;
  final TaskOrchestrator? _taskOrchestrator;
  final Map<String, _TrackedChatRun> _pending = <String, _TrackedChatRun>{};
  final Map<String, String> _settledChatThreadByRunId = <String, String>{};
  final Map<String, ChatRunActivity> _settledChatActivitiesByRunId =
      <String, ChatRunActivity>{};
  final Map<String, ChatRunDraftSnapshot> _settledChatDraftSnapshotsByRunId =
      <String, ChatRunDraftSnapshot>{};
  final Map<String, ChatRunCompletion> _chatCompletionJournal =
      <String, ChatRunCompletion>{};
  final Set<String> _settledDerivedFileRunIds = <String>{};
  final Map<String, _TrackedDerivedPartRun> _pendingDerived =
      <String, _TrackedDerivedPartRun>{};
  final Set<String> _settledRecordingOutlineTaskIds = <String>{};
  final Map<String, _TrackedRecordingOutlineRun> _pendingRecordingOutlines =
      <String, _TrackedRecordingOutlineRun>{};
  final Map<String, AgentTaskLedgerEntry> _taskLedger =
      <String, AgentTaskLedgerEntry>{};
  final Map<String, String> _chatSubjectTitlesByThreadId = <String, String>{};
  final Map<String, String> _assetSubjectTitlesByLocalNoteId =
      <String, String>{};
  final Map<String, AgentTaskLedgerEntry> _queuedTaskLedgerUpserts =
      <String, AgentTaskLedgerEntry>{};
  final Set<String> _queuedTaskLedgerRemovals = <String>{};
  final Map<String, StreamSubscription<AssistantStreamEvent>> _eventStreams =
      <String, StreamSubscription<AssistantStreamEvent>>{};
  final Set<String> _eventStreamOpening = <String>{};
  final Map<String, int> _eventStreamOpenTokens = <String, int>{};
  final Map<String, Timer> _eventStreamReconnectTimers = <String, Timer>{};
  final Map<String, int> _eventStreamReconnectAttempts = <String, int>{};
  final Map<String, Timer> _eventStreamSilentTimers = <String, Timer>{};
  final Set<String> _healthyEventStreams = <String>{};
  final Map<String, Timer> _runFallbackTimers = <String, Timer>{};
  final Map<String, int> _runFallbackAttempts = <String, int>{};
  final Set<String> _runFallbackInFlight = <String>{};
  final Set<AssistantRuntimeReadLease<AssistantRunSnapshot>>
  _activeAssistantReads = <AssistantRuntimeReadLease<AssistantRunSnapshot>>{};
  final Map<String, Future<void>> _chatRunReads = <String, Future<void>>{};
  int _chatReadGeneration = 0;
  final Map<String, _PendingDraftDelta> _pendingDraftDeltas =
      <String, _PendingDraftDelta>{};
  final Map<String, Timer> _draftEventTimers = <String, Timer>{};

  OrchestratedPoller? _chatSnapshotPoller;
  OrchestratedPoller? _derivedPoller;
  Timer? _checkpointTimer;
  bool _checkpointDirty = false;
  bool _started = false;
  bool _foreground = false;
  bool _polling = false;
  bool _derivedRepollRequested = false;
  bool _derivedRepollScheduled = false;
  bool _disposed = false;
  bool _accountCleared = false;
  bool _initialRestoreCompleted = false;
  bool _initialRestoreResetPublished = false;
  Future<void>? _initialRestoreFuture;
  int _initialRestoreGeneration = 0;
  int _checkpointStateRevision = 0;
  int _eventStreamOpenTokenSequence = 0;
  int _completionSequence = 0;
  int _taskSubjectRevision = 0;
  ChatRunCompletion? _lastCompletion;
  int _draftDeltaSequence = 0;
  ChatRunDraftDelta? _lastDraftDelta;
  DerivedPartRunCompletion? _lastDerivedCompletion;
  RecordingOutlineRunCompletion? _lastRecordingOutlineCompletion;
  int _taskLedgerDeltaSequence = 0;
  AgentTaskLedgerDelta? _lastTaskLedgerDelta;
  bool _taskLedgerResetQueued = false;

  @override
  int get completionSequence => _completionSequence;

  @override
  ChatRunCompletion? get lastCompletion => _lastCompletion;

  @override
  int get draftDeltaSequence => _draftDeltaSequence;

  @override
  ChatRunDraftDelta? get lastDraftDelta => _lastDraftDelta;

  @override
  ChatRunDraftSnapshot? draftSnapshotFor({
    required String threadId,
    required String agentRunId,
  }) {
    final run = _pending[agentRunId];
    if (run != null && run.threadId == threadId && run.draftText.isNotEmpty) {
      return ChatRunDraftSnapshot(
        agentRunId: run.agentRunId,
        threadId: run.threadId,
        scene: run.scene,
        purpose: run.purpose,
        eventSequence: run.draftSequence,
        text: run.draftText,
        state: run.draftState,
      );
    }
    final settled = _settledChatDraftSnapshotsByRunId[agentRunId];
    return settled?.threadId == threadId ? settled : null;
  }

  @override
  List<ChatRunCompletion> completionsForThread(String threadId) {
    final completions =
        _chatCompletionJournal.values
            .where((completion) => completion.threadId == threadId)
            .toList(growable: false)
          ..sort((left, right) {
            final byCompletion = (left.completedAt ?? DateTime.utc(1970))
                .compareTo(right.completedAt ?? DateTime.utc(1970));
            return byCompletion != 0
                ? byCompletion
                : left.agentRunId.compareTo(right.agentRunId);
          });
    return List<ChatRunCompletion>.unmodifiable(completions);
  }

  @override
  DerivedPartRunCompletion? get lastDerivedCompletion => _lastDerivedCompletion;
  @override
  RecordingOutlineRunCompletion? get lastRecordingOutlineCompletion =>
      _lastRecordingOutlineCompletion;
  @override
  int get taskLedgerDeltaSequence => _taskLedgerDeltaSequence;
  @override
  AgentTaskLedgerDelta? get lastTaskLedgerDelta => _lastTaskLedgerDelta;
  bool get hasPendingRuns =>
      _pending.isNotEmpty ||
      _pendingDerived.isNotEmpty ||
      _pendingRecordingOutlines.isNotEmpty;

  @override
  List<AgentTaskLedgerEntry> get taskLedger {
    final entries = <AgentTaskLedgerEntry>[
      for (final run in _pending.values)
        if (!_taskLedger.containsKey(run.agentRunId))
          AgentTaskLedgerEntry.chat(
            taskId: run.agentRunId,
            publicTaskId: run.publicTaskId,
            threadId: run.threadId,
            scene: run.scene,
            purpose: run.purpose,
            status: run.status,
            createdAt: run.createdAt,
            subjectTitle: run.subjectTitle,
          ),
      for (final run in _pendingDerived.values)
        if (!_taskLedger.containsKey(run.fileAgentRunId))
          AgentTaskLedgerEntry.derivedPart(
            taskId: run.fileAgentRunId,
            agentRunId: run.agentRunId,
            localNoteId: run.localNoteId,
            remoteNoteId: run.remoteNoteId,
            targetPart: run.targetPart,
            status: run.status,
            createdAt: run.createdAt,
            outputPartRevisionId: run.outputPartRevisionId,
            subjectTitle: run.subjectTitle,
            inputPartRevisionId: run.inputPartRevisionId,
            targetPartRevisionId: run.targetPartRevisionId,
            operationId: run.operationId,
          ),
      for (final run in _pendingRecordingOutlines.values)
        if (!_taskLedger.containsKey(run.trackingTaskId))
          _recordingOutlineLedgerEntry(run),
      ..._taskLedger.values,
    ]..sort((left, right) => right.createdAt.compareTo(left.createdAt));
    return List<AgentTaskLedgerEntry>.unmodifiable(entries);
  }

  @override
  void notifyListeners() {
    if (_taskLedgerResetQueued ||
        _queuedTaskLedgerUpserts.isNotEmpty ||
        _queuedTaskLedgerRemovals.isNotEmpty) {
      _lastTaskLedgerDelta = AgentTaskLedgerDelta(
        upserts: _queuedTaskLedgerUpserts.values,
        removedTaskIds: _queuedTaskLedgerRemovals,
        reset: _taskLedgerResetQueued,
      );
      _taskLedgerDeltaSequence += 1;
      _queuedTaskLedgerUpserts.clear();
      _queuedTaskLedgerRemovals.clear();
      _taskLedgerResetQueued = false;
    }
    super.notifyListeners();
  }

  @override
  bool get canTrackAcceptedRuns =>
      !_disposed &&
      !_accountCleared &&
      _userScope != 'anonymous' &&
      _initialRestoreCompleted;

  @override
  int get taskSubjectRevision => _taskSubjectRevision;

  @override
  String? chatThreadSubject(String threadId) =>
      _chatSubjectTitlesByThreadId[threadId.trim()];

  @override
  String? knowledgeAssetSubject(String localNoteId) =>
      _assetSubjectTitlesByLocalNoteId[localNoteId.trim()];

  @override
  Future<void> rememberChatThreadSubject({
    required String threadId,
    required String subjectTitle,
  }) async {
    final normalizedThreadId = threadId.trim();
    final normalizedTitle = _safeTaskSubjectTitle(subjectTitle);
    if (!isSafeChatIdentifier(normalizedThreadId) || normalizedTitle == null) {
      return;
    }
    final subjectChanged = _rememberBoundedSubject(
      _chatSubjectTitlesByThreadId,
      normalizedThreadId,
      normalizedTitle,
    );
    if (!await _restoreBeforeEnrollment() ||
        _chatSubjectTitlesByThreadId[normalizedThreadId] != normalizedTitle) {
      return;
    }

    var changed = false;
    for (final run in _pending.values) {
      if (run.threadId != normalizedThreadId ||
          run.subjectTitle == normalizedTitle) {
        continue;
      }
      run.subjectTitle = normalizedTitle;
      _queueTaskLedgerUpsert(_chatLedgerEntry(run));
      changed = true;
    }
    for (final entry in _taskLedger.values.toList(growable: false)) {
      if (entry.kind != 'chat' ||
          entry.threadId != normalizedThreadId ||
          entry.subjectTitle == normalizedTitle) {
        continue;
      }
      final enriched = _taskLedgerEntryWithSubject(entry, normalizedTitle);
      _taskLedger[entry.taskId] = enriched;
      _queueTaskLedgerUpsert(enriched);
      changed = true;
    }
    if (!changed && !subjectChanged) return;
    if (subjectChanged) _taskSubjectRevision += 1;
    _persist();
    if (!_disposed) notifyListeners();
  }

  @override
  Future<void> rememberKnowledgeAssetSubject({
    required String localNoteId,
    required String subjectTitle,
  }) async {
    final normalizedNoteId = localNoteId.trim();
    final normalizedTitle = _safeTaskSubjectTitle(subjectTitle);
    if (!_isSafeTaskIdentifier(normalizedNoteId) || normalizedTitle == null) {
      return;
    }
    final subjectChanged = _rememberBoundedSubject(
      _assetSubjectTitlesByLocalNoteId,
      normalizedNoteId,
      normalizedTitle,
    );
    if (!await _restoreBeforeEnrollment() ||
        _assetSubjectTitlesByLocalNoteId[normalizedNoteId] != normalizedTitle) {
      return;
    }

    var changed = false;
    for (final run in _pendingDerived.values) {
      if (run.localNoteId != normalizedNoteId ||
          run.subjectTitle == normalizedTitle) {
        continue;
      }
      run.subjectTitle = normalizedTitle;
      run.mutationGeneration += 1;
      _queueTaskLedgerUpsert(_derivedLedgerEntry(run));
      changed = true;
    }
    for (final run in _pendingRecordingOutlines.values) {
      if (run.localNoteId != normalizedNoteId ||
          run.subjectTitle == normalizedTitle) {
        continue;
      }
      run.subjectTitle = normalizedTitle;
      _queueTaskLedgerUpsert(_recordingOutlineLedgerEntry(run));
      changed = true;
    }
    for (final entry in _taskLedger.values.toList(growable: false)) {
      if (entry.localNoteId != normalizedNoteId ||
          entry.subjectTitle == normalizedTitle ||
          (entry.kind != 'derived_part' && entry.kind != 'recording_outline')) {
        continue;
      }
      final enriched = _taskLedgerEntryWithSubject(entry, normalizedTitle);
      _taskLedger[entry.taskId] = enriched;
      _queueTaskLedgerUpsert(enriched);
      changed = true;
    }
    if (!changed && !subjectChanged) return;
    if (subjectChanged) _taskSubjectRevision += 1;
    _persist();
    notifyListeners();
  }

  @override
  bool isThreadPending(String threadId) =>
      _pending.values.any((run) => run.threadId == threadId && !run.isTerminal);

  @override
  bool needsThreadReconciliation(String threadId) =>
      _pending.values.any((run) => run.threadId == threadId);

  @override
  ChatRunReconciliationSnapshot? reconciliationForThread(String threadId) {
    for (final tracked in _pending.values) {
      if (tracked.threadId == threadId && tracked.isTerminal) {
        return tracked.reconciliation!.snapshot;
      }
    }
    return null;
  }

  @override
  Future<bool> recoverThread(String threadId) async {
    if (_disposed ||
        !_started ||
        !_foreground ||
        !isSafeChatIdentifier(threadId)) {
      return false;
    }
    final generation = _chatReadGeneration;
    final candidates = _pending.values
        .where((tracked) => tracked.threadId == threadId && tracked.isTerminal)
        .toList(growable: false);
    for (final tracked in candidates) {
      _runFallbackTimers.remove(tracked.agentRunId)?.cancel();
      await _pollChatRun(tracked, userInitiated: true);
      if (_disposed || !_foreground || generation != _chatReadGeneration) {
        return false;
      }
      if (_pending[tracked.agentRunId] == tracked) {
        _scheduleRunFallback(tracked);
      }
    }
    return !needsThreadReconciliation(threadId);
  }

  @override
  bool hasTrackedThreadRun(String threadId, String agentRunId) =>
      (_pending.containsKey(agentRunId) &&
          _pending[agentRunId]?.threadId == threadId) ||
      _settledChatThreadByRunId[agentRunId] == threadId ||
      _terminalChatLedgerEntry(agentRunId)?.threadId == threadId;

  @override
  String? threadRunStatus(String threadId) {
    for (final run in _pending.values) {
      if (run.threadId == threadId && !run.isTerminal) return run.status;
    }
    return null;
  }

  @override
  List<AgentRunToolTrace> threadToolTrace(String threadId) {
    for (final run in _pending.values) {
      if (run.threadId == threadId && !run.isTerminal) {
        return List<AgentRunToolTrace>.unmodifiable(run.toolTrace);
      }
    }
    return const <AgentRunToolTrace>[];
  }

  @override
  ChatRunActivity? activityFor({
    required String threadId,
    required String agentRunId,
  }) {
    final run = _pending[agentRunId];
    if (run != null && run.threadId == threadId) return _activityOf(run);
    final settled = _settledChatActivitiesByRunId[agentRunId];
    if (settled != null && settled.threadId == threadId) return settled;
    final ledger = _terminalChatLedgerEntry(agentRunId);
    if (ledger == null || ledger.threadId != threadId) return null;
    return ChatRunActivity(
      agentRunId: agentRunId,
      threadId: threadId,
      status: ledger.status,
      createdAt: ledger.createdAt,
      completedAt: ledger.createdAt,
    );
  }

  @override
  List<ChatRunActivity> activitiesForThread(String threadId) {
    final activitiesByRun = <String, ChatRunActivity>{
      for (final entry in _taskLedger.values)
        if (entry.kind == 'chat' &&
            entry.isTerminal &&
            entry.threadId == threadId)
          entry.taskId: ChatRunActivity(
            agentRunId: entry.taskId,
            threadId: threadId,
            status: entry.status,
            createdAt: entry.createdAt,
            completedAt: entry.createdAt,
          ),
      for (final activity in _settledChatActivitiesByRunId.values)
        if (activity.threadId == threadId) activity.agentRunId: activity,
      for (final run in _pending.values)
        if (run.threadId == threadId) run.agentRunId: _activityOf(run),
    };
    final activities = activitiesByRun.values.toList(growable: false)
      ..sort((left, right) => left.createdAt.compareTo(right.createdAt));
    return List<ChatRunActivity>.unmodifiable(activities);
  }

  @override
  bool isDerivedPartPending(String localNoteId, NoteFileAgentPart targetPart) =>
      _pendingDerived.values.any(
        (run) =>
            run.localNoteId == localNoteId &&
            run.targetPart == targetPart &&
            !_isTerminalTaskStatus(run.status),
      );

  @override
  String? derivedPartStatus(String localNoteId, NoteFileAgentPart targetPart) {
    for (final run in _pendingDerived.values) {
      if (run.localNoteId == localNoteId && run.targetPart == targetPart) {
        return run.status;
      }
    }
    return null;
  }

  @override
  List<AgentRunToolTrace> derivedPartToolTrace(
    String localNoteId,
    NoteFileAgentPart targetPart,
  ) {
    for (final run in _pendingDerived.values) {
      if (run.localNoteId == localNoteId && run.targetPart == targetPart) {
        return List<AgentRunToolTrace>.unmodifiable(run.toolTrace);
      }
    }
    return const <AgentRunToolTrace>[];
  }

  @override
  bool isRecordingOutlinePending(String localNoteId) =>
      _pendingRecordingOutlines.values.any(
        (run) =>
            run.localNoteId == localNoteId &&
            !_isTerminalTaskStatus(run.status),
      );

  @override
  String? recordingOutlineStatus(String localNoteId) {
    for (final run in _pendingRecordingOutlines.values) {
      if (run.localNoteId == localNoteId) return run.status;
    }
    return null;
  }

  @override
  bool acceptsRecordingOutlineTask(String localNoteId, String? publicTaskId) {
    for (final run in _pendingRecordingOutlines.values) {
      if (run.localNoteId == localNoteId) {
        return run.acceptsPublicTaskId(
          _safeOptionalTaskIdentifier(publicTaskId),
        );
      }
    }
    return true;
  }

  @override
  Future<String?> verifySucceededDerivedOutputRevision({
    required String fileAgentRunId,
    required String remoteNoteId,
    required NoteFileAgentPart targetPart,
  }) async {
    final fileAgentRuns = _fileAgentRuns;
    if (_disposed ||
        !_foreground ||
        fileAgentRuns == null ||
        !_isSafeTaskIdentifier(fileAgentRunId) ||
        !_isSafeTaskIdentifier(remoteNoteId)) {
      return null;
    }
    try {
      final run = await fileAgentRuns.getRun(
        noteId: remoteNoteId,
        fileAgentRunId: fileAgentRunId,
      );
      if (_disposed ||
          !_foreground ||
          run.fileAgentRunId != fileAgentRunId ||
          run.noteId != remoteNoteId ||
          run.targetPart != targetPart ||
          !run.isSuccessful) {
        return null;
      }
      final outputRevision = run.outputPartRevisionId?.trim();
      return outputRevision != null && _isSafeTaskIdentifier(outputRevision)
          ? outputRevision
          : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> start() async {
    if (_disposed || _accountCleared || _userScope == 'anonymous') return;
    _foreground = true;
    _started = true;
    final restoreGeneration = _initialRestoreGeneration;
    await _ensureInitialStateRestored();
    if (_disposed ||
        _accountCleared ||
        !_started ||
        !_initialRestoreCompleted ||
        restoreGeneration != _initialRestoreGeneration) {
      return;
    }
    if (!_initialRestoreResetPublished) {
      _initialRestoreResetPublished = true;
      if (_pending.isNotEmpty ||
          _pendingDerived.isNotEmpty ||
          _pendingRecordingOutlines.isNotEmpty ||
          _taskLedger.isNotEmpty) {
        _queueTaskLedgerReset();
        notifyListeners();
      }
    }
    _ensurePolling();
    _startPendingEventStreams();
  }

  Future<void> resume() => start();

  Future<void> refresh() async {
    for (final tracked in List<_TrackedChatRun>.of(_pending.values)) {
      await _pollChatRun(tracked, userInitiated: true);
    }
    await _poll(chatRunIds: const <String>{});
    for (final tracked in _pending.values) {
      if (tracked.isTerminal) _scheduleRunFallback(tracked);
    }
  }

  Future<void> flushCheckpointPersistence() =>
      _checkpointPersistence?.flush() ?? Future<void>.value();

  void pause() {
    _chatReadGeneration += 1;
    _chatRunReads.clear();
    _derivedRepollRequested = false;
    for (final tracked in _pending.values) {
      tracked.reconciliation?.cancelAttempt();
    }
    _flushAllPendingDraftDeltas();
    _flushCheckpoint(legacyBackup: true);
    _foreground = false;
    _cancelActiveRunReads();
    _stopTimer();
    _cancelAllEventStreams();
    _cancelAllRunFallbacks();
    _clearAllRunRuntimeMetrics();
  }

  void _stopTimer() {
    _chatSnapshotPoller?.stop();
    _derivedPoller?.stop();
  }

  Future<AssistantRuntimeRead<_TrackerRunRead>> _readAssistantRun(
    String agentRunId,
  ) async {
    if (_assistantRuntime is AssistantRuntimeReadLeasePort) {
      final leasePort = _assistantRuntime as AssistantRuntimeReadLeasePort;
      final lease = leasePort.leaseReadRun(
        handle: AssistantRunHandle(agentRunId),
      );
      _activeAssistantReads.add(lease);
      try {
        return _wrapAssistantRead(await lease.result);
      } finally {
        _activeAssistantReads.remove(lease);
      }
    }
    return _wrapAssistantRead(
      await _assistantRuntime.readRun(handle: AssistantRunHandle(agentRunId)),
    );
  }

  void _cancelActiveRunReads() {
    final assistantLeases = _activeAssistantReads.toList(growable: false);
    _activeAssistantReads.clear();
    for (final lease in assistantLeases) {
      try {
        lease.cancel();
      } catch (_) {
        // Owner teardown must not depend on an adapter's cancellation quality.
      }
    }
  }

  String _runMetricOwner(String agentRunId) {
    return 'chat_run_${_runStableDigest(agentRunId, length: 12)}';
  }

  String _runFallbackTaskKey(String agentRunId) =>
      'chat.run-fallback.${_runStableDigest(agentRunId)}';

  String _runStableDigest(String agentRunId, {int length = 16}) => sha256
      .convert(utf8.encode(agentRunId.trim()))
      .toString()
      .substring(0, length);

  void _cancelRunFallbackTask(String agentRunId) {
    _taskOrchestrator?.cancel(
      _runFallbackTaskKey(agentRunId),
      reason: 'chat-run-fallback-cancelled',
    );
  }

  void _setRunSseMetric(String agentRunId, RuntimeSseState state) {
    _runtimeActivityMetrics?.setSseState(_runMetricOwner(agentRunId), state);
  }

  void _setRunFallbackMetric(String agentRunId) {
    final owner = _runMetricOwner(agentRunId);
    _runtimeActivityMetrics
      ?..setPollerActive(owner)
      ..setSseState(owner, RuntimeSseState.fallbackPolling);
  }

  void _removeRunFallbackMetric(String agentRunId) {
    _runtimeActivityMetrics?.removePoller(_runMetricOwner(agentRunId));
  }

  void _clearRunRuntimeMetrics(String agentRunId) {
    final owner = _runMetricOwner(agentRunId);
    _runtimeActivityMetrics
      ?..removePoller(owner)
      ..removeSseState(owner);
  }

  void _clearAllRunRuntimeMetrics() {
    for (final agentRunId in <String>{
      ..._pending.keys,
      ..._eventStreamOpening,
      ..._eventStreams.keys,
      ..._runFallbackTimers.keys,
      ..._runFallbackInFlight,
    }) {
      _clearRunRuntimeMetrics(agentRunId);
    }
  }

  @override
  Future<void> track({
    required String agentRunId,
    required String threadId,
    required ChatScene scene,
    ChatConversationPurpose purpose = ChatConversationPurpose.general,
  }) => _trackChatRun(
    agentRunId: agentRunId,
    threadId: threadId,
    scene: scene,
    purpose: purpose,
  );

  @override
  Future<void> trackAcceptedRun({
    required String agentRunId,
    required String? publicTaskId,
    required String threadId,
    required ChatScene scene,
    ChatConversationPurpose purpose = ChatConversationPurpose.general,
  }) => _trackChatRun(
    agentRunId: agentRunId,
    publicTaskId: publicTaskId,
    threadId: threadId,
    scene: scene,
    purpose: purpose,
  );

  Future<void> _trackChatRun({
    required String agentRunId,
    String? publicTaskId,
    required String threadId,
    required ChatScene scene,
    required ChatConversationPurpose purpose,
  }) async {
    if (_disposed ||
        _accountCleared ||
        _userScope == 'anonymous' ||
        !isSafeAgentRunIdentifier(agentRunId) ||
        !isSafeChatIdentifier(threadId)) {
      return;
    }
    if (!await _restoreBeforeEnrollment()) return;
    final normalizedPublicTaskId = publicTaskId?.trim();
    final safePublicTaskId =
        normalizedPublicTaskId != null &&
            _isSafeTaskIdentifier(normalizedPublicTaskId)
        ? normalizedPublicTaskId
        : null;
    final subjectTitle = _chatSubjectTitlesByThreadId[threadId];
    final terminalEnrollment = _reconcileTerminalChatEnrollment(
      agentRunId: agentRunId,
      publicTaskId: safePublicTaskId,
      threadId: threadId,
      scene: scene,
      purpose: purpose,
      subjectTitle: subjectTitle,
    );
    if (terminalEnrollment.authoritative) {
      final durableTerminal = _taskLedger[agentRunId];
      await _persistDurably();
      if (_disposed ||
          _accountCleared ||
          !identical(_taskLedger[agentRunId], durableTerminal)) {
        return;
      }
      if (terminalEnrollment.changed) notifyListeners();
      return;
    }
    final existing = _pending[agentRunId];
    if (existing != null) {
      if (existing.threadId != threadId || existing.scene != scene) return;
      if (safePublicTaskId != null &&
          existing.publicTaskId != null &&
          existing.publicTaskId != safePublicTaskId) {
        return;
      }
      var changed = false;
      if (existing.publicTaskId == null && safePublicTaskId != null) {
        existing.publicTaskId = safePublicTaskId;
        changed = true;
      }
      if (_shouldUpgradePurpose(existing.purpose, purpose)) {
        existing.purpose = purpose;
        changed = true;
      }
      if (subjectTitle != null && existing.subjectTitle != subjectTitle) {
        existing.subjectTitle = subjectTitle;
        changed = true;
      }
      if (changed) _queueTaskLedgerUpsert(_chatLedgerEntry(existing));
      await _persistDurably();
      if (_disposed ||
          _accountCleared ||
          !identical(_pending[agentRunId], existing)) {
        return;
      }
      if (changed) notifyListeners();
      if (_foreground) unawaited(_openAgentRunEventStream(existing));
      return;
    }
    _settledChatThreadByRunId.remove(agentRunId);
    final tracked = _TrackedChatRun(
      agentRunId: agentRunId,
      publicTaskId: safePublicTaskId,
      threadId: threadId,
      scene: scene,
      purpose: purpose,
      subjectTitle: subjectTitle,
    );
    _pending[agentRunId] = tracked;
    _queueTaskLedgerUpsert(_chatLedgerEntry(tracked));
    await _persistDurably();
    if (_disposed ||
        _accountCleared ||
        !identical(_pending[agentRunId], tracked)) {
      return;
    }
    if (_started && _foreground) _ensurePolling();
    notifyListeners();
    if (_foreground) unawaited(_openAgentRunEventStream(tracked));
  }

  @override
  Future<void> trackServerActiveRuns({
    required String threadId,
    required ChatScene scene,
    required Iterable<ChatActiveRun> runs,
    ChatConversationPurpose purpose = ChatConversationPurpose.general,
  }) async {
    if (_disposed ||
        _accountCleared ||
        _userScope == 'anonymous' ||
        !isSafeChatIdentifier(threadId)) {
      return;
    }
    if (!await _restoreBeforeEnrollment()) return;
    final subjectTitle = _chatSubjectTitlesByThreadId[threadId];
    var changed = false;
    final changedRuns = <_TrackedChatRun>[];
    for (final run in runs) {
      if (run.isTerminal || !isSafeAgentRunIdentifier(run.agentRunId)) {
        continue;
      }
      final terminalEnrollment = _reconcileTerminalChatEnrollment(
        agentRunId: run.agentRunId,
        threadId: threadId,
        scene: scene,
        purpose: purpose,
        subjectTitle: subjectTitle,
      );
      if (terminalEnrollment.authoritative) {
        changed = terminalEnrollment.changed || changed;
        continue;
      }
      if (_settledChatThreadByRunId[run.agentRunId] == threadId) {
        continue;
      }
      final existing = _pending[run.agentRunId];
      if (existing != null) {
        if (existing.threadId != threadId || existing.scene != scene) continue;
        if (_shouldUpgradePurpose(existing.purpose, purpose)) {
          existing.purpose = purpose;
          changed = true;
          changedRuns.add(existing);
        }
        if (!existing.isTerminal && existing.status != run.status) {
          existing.status = run.status;
          changed = true;
          if (!changedRuns.contains(existing)) changedRuns.add(existing);
        }
        if (subjectTitle != null && existing.subjectTitle != subjectTitle) {
          existing.subjectTitle = subjectTitle;
          changed = true;
          if (!changedRuns.contains(existing)) changedRuns.add(existing);
        }
        continue;
      }
      final tracked = _TrackedChatRun(
        agentRunId: run.agentRunId,
        threadId: threadId,
        scene: scene,
        purpose: purpose,
        status: run.status,
        subjectTitle: subjectTitle,
      );
      _pending[run.agentRunId] = tracked;
      changedRuns.add(tracked);
      changed = true;
    }
    if (!changed) return;
    for (final run in changedRuns) {
      _queueTaskLedgerUpsert(_chatLedgerEntry(run));
    }
    _persist();
    if (_started && _foreground) _ensurePolling();
    notifyListeners();
    if (_foreground) _startPendingEventStreams();
  }

  @override
  Future<void> trackDerivedPart({
    required String fileAgentRunId,
    String? agentRunId,
    String? status,
    String? inputPartRevisionId,
    String? targetPartRevisionId,
    String? operationId,
    required String localNoteId,
    required String remoteNoteId,
    required NoteFileAgentPart targetPart,
  }) async {
    if (_disposed ||
        _accountCleared ||
        _userScope == 'anonymous' ||
        !_isSafeTaskIdentifier(fileAgentRunId) ||
        !_isSafeTaskIdentifier(localNoteId) ||
        !_isSafeTaskIdentifier(remoteNoteId)) {
      return;
    }
    if (!await _restoreBeforeEnrollment()) return;
    final normalizedInputPartRevisionId = _safeOptionalTaskIdentifier(
      inputPartRevisionId,
    );
    final normalizedTargetPartRevisionId = _safeOptionalTaskIdentifier(
      targetPartRevisionId,
    );
    final normalizedOperationId = _safeOptionalTaskIdentifier(operationId);
    final normalizedAgentRunId = _safeOptionalAgentRunId(agentRunId);
    if ((inputPartRevisionId != null &&
            normalizedInputPartRevisionId == null) ||
        (targetPartRevisionId != null &&
            normalizedTargetPartRevisionId == null) ||
        (operationId != null && normalizedOperationId == null) ||
        (agentRunId != null && normalizedAgentRunId == null)) {
      return;
    }
    final subjectTitle = _assetSubjectTitlesByLocalNoteId[localNoteId];
    final terminalEnrollment = _reconcileTerminalDerivedEnrollment(
      fileAgentRunId: fileAgentRunId,
      localNoteId: localNoteId,
      remoteNoteId: remoteNoteId,
      targetPart: targetPart,
      subjectTitle: subjectTitle,
      inputPartRevisionId: normalizedInputPartRevisionId,
      targetPartRevisionId: normalizedTargetPartRevisionId,
      operationId: normalizedOperationId,
      agentRunId: normalizedAgentRunId,
    );
    if (terminalEnrollment.authoritative) {
      final durableTerminal = _taskLedger[fileAgentRunId];
      await _persistDurably();
      if (_disposed ||
          _accountCleared ||
          !identical(_taskLedger[fileAgentRunId], durableTerminal)) {
        return;
      }
      if (terminalEnrollment.changed) {
        notifyListeners();
      }
      return;
    }
    if (_settledDerivedFileRunIds.contains(fileAgentRunId)) return;
    final receivedStatus = _safeDerivedTaskStatus(status);
    final normalizedStatus =
        targetPart == NoteFileAgentPart.outline && receivedStatus == 'succeeded'
        ? 'finalizing'
        : receivedStatus;
    if (status != null && normalizedStatus == null) return;
    final existing = _pendingDerived[fileAgentRunId];
    if (existing != null) {
      if (existing.localNoteId != localNoteId ||
          existing.remoteNoteId != remoteNoteId ||
          existing.targetPart != targetPart ||
          (normalizedInputPartRevisionId != null &&
              existing.inputPartRevisionId != null &&
              existing.inputPartRevisionId != normalizedInputPartRevisionId) ||
          (normalizedTargetPartRevisionId != null &&
              existing.targetPartRevisionId != null &&
              existing.targetPartRevisionId !=
                  normalizedTargetPartRevisionId) ||
          (normalizedOperationId != null &&
              existing.operationId != null &&
              existing.operationId != normalizedOperationId)) {
        return;
      }
      var changed = false;
      final conflictingAgentAttempt =
          normalizedAgentRunId != null &&
          existing.agentRunId != null &&
          existing.agentRunId != normalizedAgentRunId;
      final agentAttemptLearned =
          normalizedAgentRunId != null && existing.agentRunId == null;
      if (conflictingAgentAttempt) {
        existing.mutationGeneration += 1;
        _requestImmediateDerivedPoll();
      } else if (agentAttemptLearned) {
        existing.agentRunId = normalizedAgentRunId;
        existing.toolTrace = const <AgentRunToolTrace>[];
        changed = true;
      }
      if (normalizedStatus != null &&
          !conflictingAgentAttempt &&
          _shouldAdvanceDerivedStatus(existing.status, normalizedStatus)) {
        existing.status = normalizedStatus;
        changed = true;
      }
      if (existing.inputPartRevisionId == null &&
          normalizedInputPartRevisionId != null) {
        existing.inputPartRevisionId = normalizedInputPartRevisionId;
        changed = true;
      }
      if (existing.targetPartRevisionId == null &&
          normalizedTargetPartRevisionId != null) {
        existing.targetPartRevisionId = normalizedTargetPartRevisionId;
        changed = true;
      }
      if (existing.operationId == null && normalizedOperationId != null) {
        existing.operationId = normalizedOperationId;
        changed = true;
      }
      if (subjectTitle != null && existing.subjectTitle != subjectTitle) {
        existing.subjectTitle = subjectTitle;
        changed = true;
      }
      if (changed) existing.mutationGeneration += 1;
      final enrollmentGeneration = existing.mutationGeneration;
      if (changed) _queueTaskLedgerUpsert(_derivedLedgerEntry(existing));
      await _persistDurably();
      if (_disposed ||
          _accountCleared ||
          !identical(_pendingDerived[fileAgentRunId], existing) ||
          existing.mutationGeneration != enrollmentGeneration) {
        return;
      }
      if (_started && _foreground) _ensurePolling();
      if (changed) notifyListeners();
      if (_foreground) {
        _requestImmediateDerivedPoll();
      }
      return;
    }
    final tracked = _TrackedDerivedPartRun(
      fileAgentRunId: fileAgentRunId,
      agentRunId: normalizedAgentRunId,
      localNoteId: localNoteId,
      remoteNoteId: remoteNoteId,
      targetPart: targetPart,
      status: normalizedStatus ?? 'queued',
      subjectTitle: subjectTitle,
      inputPartRevisionId: normalizedInputPartRevisionId,
      targetPartRevisionId: normalizedTargetPartRevisionId,
      operationId: normalizedOperationId,
    );
    _pendingDerived[fileAgentRunId] = tracked;
    _queueTaskLedgerUpsert(_derivedLedgerEntry(tracked));
    await _persistDurably();
    if (_disposed ||
        _accountCleared ||
        !identical(_pendingDerived[fileAgentRunId], tracked)) {
      return;
    }
    if (_started && _foreground) _ensurePolling();
    notifyListeners();
    if (_foreground) {
      _requestImmediateDerivedPoll();
    }
  }

  @override
  Future<void> trackRecordingOutline({
    required String recordingId,
    required String localNoteId,
    required String remoteNoteId,
    bool restart = false,
    String? expectedPublicTaskId,
    String? supersededPublicTaskId,
  }) async {
    final normalizedExpectedPublicTaskId = _safeOptionalTaskIdentifier(
      expectedPublicTaskId,
    );
    final normalizedSupersededPublicTaskId = _safeOptionalTaskIdentifier(
      supersededPublicTaskId,
    );
    if (_disposed ||
        _accountCleared ||
        _userScope == 'anonymous' ||
        _recordingApi == null ||
        !_isSafeTaskIdentifier(recordingId) ||
        !_isSafeTaskIdentifier(localNoteId) ||
        !_isSafeTaskIdentifier(remoteNoteId) ||
        (expectedPublicTaskId != null &&
            normalizedExpectedPublicTaskId == null) ||
        (supersededPublicTaskId != null &&
            normalizedSupersededPublicTaskId == null) ||
        (normalizedExpectedPublicTaskId != null &&
            normalizedExpectedPublicTaskId ==
                normalizedSupersededPublicTaskId)) {
      return;
    }
    if (!await _restoreBeforeEnrollment()) return;
    final trackingTaskId = _recordingOutlineTrackingTaskId(recordingId);
    final subjectTitle = _assetSubjectTitlesByLocalNoteId[localNoteId];
    final terminal = _taskLedger[trackingTaskId];
    if (terminal != null) {
      final sameLifecycle =
          terminal.kind == 'recording_outline' &&
          terminal.recordingId == recordingId &&
          terminal.localNoteId == localNoteId &&
          terminal.remoteNoteId == remoteNoteId;
      if (!sameLifecycle || !restart || terminal.status == 'succeeded') return;
      _taskLedger.remove(trackingTaskId);
      _settledRecordingOutlineTaskIds.remove(trackingTaskId);
      _queueTaskLedgerRemoval(trackingTaskId);
    } else if (_settledRecordingOutlineTaskIds.contains(trackingTaskId) &&
        !restart) {
      return;
    }

    final existing = _pendingRecordingOutlines[trackingTaskId];
    if (existing != null) {
      if (existing.recordingId != recordingId ||
          existing.localNoteId != localNoteId ||
          existing.remoteNoteId != remoteNoteId) {
        return;
      }
      if (!restart) {
        if (subjectTitle != null && existing.subjectTitle != subjectTitle) {
          existing.subjectTitle = subjectTitle;
          _queueTaskLedgerUpsert(_recordingOutlineLedgerEntry(existing));
          _persist();
          notifyListeners();
        }
        return;
      }
      existing
        ..status = 'queued'
        ..publicTaskId = null
        ..outputPartRevisionId = null
        ..expectedPublicTaskId = normalizedExpectedPublicTaskId
        ..supersededPublicTaskId = normalizedSupersededPublicTaskId
        ..subjectTitle = subjectTitle ?? existing.subjectTitle;
      _queueTaskLedgerUpsert(_recordingOutlineLedgerEntry(existing));
      _persist();
      if (_started && _foreground) _ensurePolling();
      notifyListeners();
      if (_foreground) {
        unawaited(_poll(chatRunIds: const <String>{}, includeDerived: true));
      }
      return;
    }

    final tracked = _TrackedRecordingOutlineRun(
      trackingTaskId: trackingTaskId,
      recordingId: recordingId,
      localNoteId: localNoteId,
      remoteNoteId: remoteNoteId,
      expectedPublicTaskId: normalizedExpectedPublicTaskId,
      supersededPublicTaskId: normalizedSupersededPublicTaskId,
      subjectTitle: subjectTitle,
    );
    _pendingRecordingOutlines[trackingTaskId] = tracked;
    _queueTaskLedgerUpsert(_recordingOutlineLedgerEntry(tracked));
    _persist();
    if (_started && _foreground) _ensurePolling();
    notifyListeners();
    if (_foreground) {
      unawaited(_poll(chatRunIds: const <String>{}, includeDerived: true));
    }
  }

  void clearForLogout() {
    _accountCleared = true;
    _initialRestoreGeneration += 1;
    _initialRestoreCompleted = true;
    _initialRestoreResetPublished = true;
    pause();
    _checkpointTimer?.cancel();
    _checkpointTimer = null;
    _checkpointDirty = false;
    _started = false;
    _derivedRepollRequested = false;
    _pending.clear();
    _settledChatThreadByRunId.clear();
    _settledChatActivitiesByRunId.clear();
    _settledChatDraftSnapshotsByRunId.clear();
    _chatCompletionJournal.clear();
    _settledDerivedFileRunIds.clear();
    _pendingDerived.clear();
    _settledRecordingOutlineTaskIds.clear();
    _pendingRecordingOutlines.clear();
    _taskLedger.clear();
    _chatSubjectTitlesByThreadId.clear();
    _assetSubjectTitlesByLocalNoteId.clear();
    _taskSubjectRevision += 1;
    _checkpointStateRevision += 1;
    _queueTaskLedgerReset();
    _lastCompletion = null;
    _lastDraftDelta = null;
    _lastDerivedCompletion = null;
    _lastRecordingOutlineCompletion = null;
    final tombstone = _legacyCheckpointSnapshot();
    try {
      _writeLegacyCheckpoint(tombstone);
    } catch (_) {
      // Session teardown must remain safe when local storage is unavailable.
    }
    final persistence = _checkpointPersistence;
    if (persistence != null && persistence.isEnabled) {
      unawaited(
        persistence
            .clear(
              userScope: _userScope,
              legacyFallback: () => _writeLegacyCheckpointDurably(tombstone),
            )
            .catchError((Object _) {}),
      );
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> _poll({
    Set<String>? chatRunIds,
    bool includeDerived = true,
    bool enrichmentOnly = false,
  }) async {
    if (_disposed || !_started || !_foreground) return;
    for (final tracked in List<_TrackedChatRun>.of(_pending.values)) {
      if (chatRunIds != null && !chatRunIds.contains(tracked.agentRunId)) {
        continue;
      }
      final healthy = _healthyEventStreams.contains(tracked.agentRunId);
      if (enrichmentOnly && (tracked.isTerminal || !healthy)) continue;
      if (chatRunIds != null && healthy) continue;
      if (_disposed || !_started || !_foreground) return;
      await _pollChatRun(tracked);
    }
    if (includeDerived && !_polling) {
      _polling = true;
      try {
        for (final tracked in List<_TrackedDerivedPartRun>.of(
          _pendingDerived.values,
        )) {
          if (_disposed || !_started || !_foreground) return;
          await _pollDerivedPart(tracked);
        }
        for (final tracked in List<_TrackedRecordingOutlineRun>.of(
          _pendingRecordingOutlines.values,
        )) {
          if (_disposed || !_started || !_foreground) return;
          await _pollRecordingOutline(tracked);
        }
      } finally {
        _polling = false;
        _scheduleRequestedDerivedPoll();
      }
    }
    if (!_hasHealthyChatSnapshots) _chatSnapshotPoller?.stop();
    if (_pendingDerived.isEmpty && _pendingRecordingOutlines.isEmpty) {
      _derivedPoller?.stop();
    }
  }

  Future<void> _pollChatRun(
    _TrackedChatRun tracked, {
    bool userInitiated = false,
  }) {
    if (_disposed ||
        !_foreground ||
        !_started ||
        _pending[tracked.agentRunId] != tracked) {
      return Future<void>.value();
    }
    final existing = _chatRunReads[tracked.agentRunId];
    if (existing != null) return existing;
    final reconciliation = tracked.reconciliation;
    if (reconciliation != null &&
        !reconciliation.beginAttempt(
          _now().toUtc(),
          userInitiated: userInitiated,
        )) {
      return Future<void>.value();
    }
    final generation = _chatReadGeneration;
    late final Future<void> read;
    read = _readAndApplyChatRun(tracked, generation).whenComplete(() {
      if (identical(_chatRunReads[tracked.agentRunId], read)) {
        _chatRunReads.remove(tracked.agentRunId);
      }
    });
    _chatRunReads[tracked.agentRunId] = read;
    return read;
  }

  Future<void> _readAndApplyChatRun(
    _TrackedChatRun tracked,
    int generation,
  ) async {
    bool ownsRead() =>
        !_disposed &&
        _started &&
        _foreground &&
        generation == _chatReadGeneration &&
        _pending[tracked.agentRunId] == tracked;
    try {
      final result = await _readAssistantRun(tracked.agentRunId);
      if (!ownsRead()) return;
      final read = result.data;
      final run = read?.snapshot;
      if (!result.ok || read == null || run == null) {
        _recordChatReadbackFailure(
          tracked,
          result.errorCode ?? 'CHAT_RUN_READBACK_FAILED',
        );
        return;
      }
      if (run.handle.value != tracked.agentRunId ||
          (run.conversationId != null &&
              run.conversationId != tracked.threadId)) {
        _recordChatReadbackFailure(
          tracked,
          'CHAT_RUN_READBACK_IDENTITY_MISMATCH',
        );
        return;
      }
      if (tracked.isTerminal &&
          (!run.isTerminal ||
              tracked.status != _assistantStatusValue(run.status))) {
        _recordChatReadbackFailure(
          tracked,
          'CHAT_RUN_TERMINAL_STATUS_MISMATCH',
        );
        return;
      }
      final authoritativeCreatedAt = run.createdAt.toUtc();
      final nextStatus = _mergePolledChatRunStatus(
        current: tracked.status,
        candidate: _assistantStatusValue(run.status),
        hasStreamAuthority: tracked.lastStreamSequence > 0,
      );
      final nextToolTrace = _mergeMonotonicToolTrace(
        tracked.toolTrace,
        read.legacyToolTrace,
      );
      final ledgerChanged =
          tracked.status != nextStatus ||
          tracked.createdAt != authoritativeCreatedAt;
      final changed =
          ledgerChanged || !_sameToolTrace(tracked.toolTrace, nextToolTrace);
      tracked
        ..status = nextStatus
        ..createdAt = authoritativeCreatedAt
        ..toolTrace = nextToolTrace;
      if (!run.isTerminal) {
        if (changed) {
          if (ledgerChanged) _queueTaskLedgerUpsert(_chatLedgerEntry(tracked));
          _persist();
          notifyListeners();
        }
        return;
      }
      final hadReadbackFailure =
          (tracked.reconciliation?.snapshot.failures ?? 0) > 0;
      tracked.reconciliation!.settle();
      _flushPendingDraftDelta(tracked.agentRunId, notify: false);
      _rememberSettledActivity(tracked, completedAt: run.updatedAt.toUtc());
      _pending.remove(tracked.agentRunId);
      _cancelAgentRunEventStream(tracked.agentRunId);
      _rememberSettledRun(tracked.agentRunId, tracked.threadId);
      _publishChatRunCompletion(
        tracked,
        status: tracked.status,
        completionMode: _assistantCompletionModeValue(run.completionQuality),
        assistantMessageId: run.output?.messageId,
        failureCode: _agentRunFailureCode(run),
        completedAt: run.updatedAt.toUtc(),
      );
      if (hadReadbackFailure) _logChatReadbackState(tracked);
      notifyListeners();
      final onTerminal = _onTerminal;
      if (onTerminal != null) unawaited(_refreshNotifications(onTerminal));
    } on Object catch (error) {
      if (!ownsRead()) return;
      _recordChatReadbackFailure(
        tracked,
        error is FormatException
            ? 'API_RESPONSE_INVALID'
            : 'CHAT_RUN_READBACK_FAILED',
      );
    }
  }

  void _recordChatReadbackFailure(_TrackedChatRun tracked, String code) {
    final reconciliation = tracked.reconciliation;
    if (reconciliation == null) return;
    final now = _now().toUtc();
    if (reconciliation.snapshot.phase != ChatRunReconciliationPhase.reading &&
        !reconciliation.beginAttempt(now)) {
      return;
    }
    final delay = _retryDelay(pollInterval, reconciliation.snapshot.failures);
    reconciliation.fail(code: code, retryAt: now.add(delay));
    if (!reconciliation.canScheduleAutomatically) {
      _runFallbackTimers.remove(tracked.agentRunId)?.cancel();
      _removeRunFallbackMetric(tracked.agentRunId);
    }
    _forceCheckpoint();
    _logChatReadbackState(tracked);
    notifyListeners();
  }

  void _logChatReadbackState(_TrackedChatRun tracked) {
    final snapshot = tracked.reconciliation?.snapshot;
    if (snapshot == null) return;
    try {
      diagnosticLogger?.log(
        DiagnosticLogInput(
          category: tracked.scene == ChatScene.feedAi
              ? DiagnosticCategory.feedAi
              : DiagnosticCategory.workAi,
          severity: snapshot.phase == ChatRunReconciliationPhase.settled
              ? DiagnosticSeverity.info
              : DiagnosticSeverity.warning,
          safeSummary: 'Chat Run terminal readback state changed',
          correlationId: tracked.agentRunId,
          metadata: <String, Object?>{
            'phase': snapshot.phase.name,
            'run_status': tracked.status,
            'attempts': snapshot.failures,
            'max_attempts': ChatRunReconciliation.maximumAutomaticFailures,
            if (snapshot.failureCode != null)
              'error_code': snapshot.failureCode,
          },
        ),
      );
    } catch (_) {}
  }

  void _publishChatRunCompletion(
    _TrackedChatRun tracked, {
    required String status,
    String? completionMode,
    String? assistantMessageId,
    String? failureCode,
    DateTime? completedAt,
  }) {
    final completion = ChatRunCompletion(
      agentRunId: tracked.agentRunId,
      threadId: tracked.threadId,
      scene: tracked.scene,
      purpose: tracked.purpose,
      status: status,
      completionMode: completionMode,
      assistantMessageId: assistantMessageId,
      failureCode: failureCode,
      completedAt: completedAt?.toUtc() ?? _now().toUtc(),
    );
    final firstPublication = !tracked.terminalCompletionPublished;
    tracked.terminalCompletionPublished = true;
    _lastCompletion = completion;
    _chatCompletionJournal.remove(completion.agentRunId);
    _chatCompletionJournal[completion.agentRunId] = completion;
    const maximumCompletions = 100;
    while (_chatCompletionJournal.length > maximumCompletions) {
      _chatCompletionJournal.remove(_chatCompletionJournal.keys.first);
    }
    _rememberTaskLedger(
      AgentTaskLedgerEntry.chat(
        taskId: tracked.agentRunId,
        publicTaskId: tracked.publicTaskId,
        threadId: tracked.threadId,
        scene: tracked.scene,
        purpose: tracked.purpose,
        status: status,
        createdAt: _now().toUtc(),
        failureCode: failureCode,
        subjectTitle: tracked.subjectTitle,
      ),
    );
    if (firstPublication) _completionSequence += 1;
  }

  void _ensurePolling() {
    _ensureChatSnapshotPolling();
    _ensureDerivedPolling();
  }

  bool get _hasHealthyChatSnapshots => _pending.values.any(
    (tracked) =>
        !tracked.isTerminal &&
        _healthyEventStreams.contains(tracked.agentRunId),
  );

  void _ensureChatSnapshotPolling() {
    if (!_foreground ||
        !_hasHealthyChatSnapshots ||
        _chatSnapshotPoller?.isRunning == true) {
      return;
    }
    final orchestrator = _taskOrchestrator;
    if (orchestrator == null) return;
    _chatSnapshotPoller ??= OrchestratedPoller(
      orchestrator: orchestrator,
      // performance-rfc: unified-network-pollers
      spec: TaskSpec(
        key: 'chat.run-snapshot.account',
        owner: 'chat.run-snapshot',
        priority: TaskPriority.userVisible,
        resources: const <TaskResource>{TaskResource.network},
        foregroundOnly: true,
        replaceExisting: true,
        retryable: true,
        deadline: const Duration(seconds: 15),
      ),
      interval: pollInterval,
      maxBackoff: pollInterval > fallbackMaximumDelay
          ? pollInterval
          : fallbackMaximumDelay,
      activityMetrics: _runtimeActivityMetrics,
      poll: (_) async {
        if (_disposed || !_foreground || !_hasHealthyChatSnapshots) {
          return false;
        }
        await _poll(includeDerived: false, enrichmentOnly: true);
        return !_disposed && _foreground && _hasHealthyChatSnapshots;
      },
    );
    _chatSnapshotPoller!.start();
  }

  void _ensureDerivedPolling() {
    if (!_foreground ||
        (_pendingDerived.isEmpty && _pendingRecordingOutlines.isEmpty) ||
        _derivedPoller?.isRunning == true) {
      return;
    }
    final orchestrator = _taskOrchestrator;
    if (orchestrator == null) {
      unawaited(_poll(chatRunIds: const <String>{}, includeDerived: true));
      return;
    }
    _derivedPoller ??= OrchestratedPoller(
      orchestrator: orchestrator,
      // performance-rfc: unified-network-pollers
      spec: TaskSpec(
        key: 'chat.derived-status.account',
        owner: 'chat.derived-status',
        priority: TaskPriority.foregroundDeferred,
        resources: const <TaskResource>{TaskResource.network},
        foregroundOnly: true,
        replaceExisting: true,
        retryable: true,
        deadline: const Duration(seconds: 15),
      ),
      interval: pollInterval,
      maxBackoff: pollInterval > fallbackMaximumDelay
          ? pollInterval
          : fallbackMaximumDelay,
      activityMetrics: _runtimeActivityMetrics,
      poll: (_) async {
        if (_disposed ||
            !_foreground ||
            (_pendingDerived.isEmpty && _pendingRecordingOutlines.isEmpty)) {
          return false;
        }
        await _poll(chatRunIds: const <String>{}, includeDerived: true);
        return !_disposed &&
            _foreground &&
            (_pendingDerived.isNotEmpty ||
                _pendingRecordingOutlines.isNotEmpty);
      },
    );
    _derivedPoller!.start();
  }

  void _startPendingEventStreams() {
    if (!_foreground || _disposed) return;
    for (final tracked in _pending.values) {
      unawaited(_openAgentRunEventStream(tracked));
    }
  }

  Future<void> _openAgentRunEventStream(_TrackedChatRun tracked) async {
    _eventStreamReconnectTimers.remove(tracked.agentRunId)?.cancel();
    if (tracked.isTerminal) {
      _scheduleRunFallback(tracked, immediate: true);
      return;
    }
    if (_disposed ||
        !_foreground ||
        !_started ||
        _pending[tracked.agentRunId] != tracked ||
        _eventStreams.containsKey(tracked.agentRunId) ||
        !_eventStreamOpening.add(tracked.agentRunId)) {
      return;
    }
    final openToken = ++_eventStreamOpenTokenSequence;
    _eventStreamOpenTokens[tracked.agentRunId] = openToken;
    bool ownsOpen() => _eventStreamOpenTokens[tracked.agentRunId] == openToken;
    if (!_runFallbackTimers.containsKey(tracked.agentRunId) &&
        !_runFallbackInFlight.contains(tracked.agentRunId)) {
      _setRunSseMetric(tracked.agentRunId, RuntimeSseState.connecting);
    }
    try {
      if (!chatSseAuthoritative) {
        _scheduleRunFallback(tracked, immediate: true);
        return;
      }
      final lastEventId = tracked.lastStreamSequence == 0
          ? null
          : tracked.lastStreamSequence.toString();
      final streamPort = _assistantRuntimeStream;
      if (streamPort == null) {
        _scheduleRunFallback(tracked, immediate: true);
        return;
      }
      final result = await streamPort.streamEvents(
        handle: AssistantRunHandle(tracked.agentRunId),
        lastEventId: lastEventId,
      );
      if (!result.ok || result.data == null) {
        _chatRunSseDebug(
          'open-failed',
          agentRunId: tracked.agentRunId,
          code: result.errorCode,
        );
        if (ownsOpen() &&
            !_disposed &&
            _foreground &&
            _pending[tracked.agentRunId] == tracked) {
          _markEventStreamUnhealthy(tracked.agentRunId);
          _scheduleRunFallback(tracked, immediate: true);
          _scheduleAgentRunEventStreamReconnect(tracked);
        }
        return;
      }
      _chatRunSseDebug('opened', agentRunId: tracked.agentRunId);
      late final StreamSubscription<AssistantStreamEvent> subscription;
      subscription = result.data!.listen(
        (event) {
          if (ownsOpen()) {
            _applyAgentRunStreamEvent(tracked.agentRunId, event);
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          _chatRunSseDebug(
            'stream-error',
            agentRunId: tracked.agentRunId,
            errorType: error.runtimeType.toString(),
          );
          _handleAgentRunEventStreamUnavailable(tracked, subscription);
        },
        onDone: () {
          _chatRunSseDebug('closed', agentRunId: tracked.agentRunId);
          _handleAgentRunEventStreamUnavailable(tracked, subscription);
        },
        cancelOnError: true,
      );
      if (!ownsOpen() ||
          _disposed ||
          !_foreground ||
          _pending[tracked.agentRunId] != tracked) {
        await subscription.cancel();
        return;
      }
      _eventStreams[tracked.agentRunId] = subscription;
      _markEventStreamHealthy(tracked);
    } catch (error) {
      _chatRunSseDebug(
        'open-error',
        agentRunId: tracked.agentRunId,
        errorType: error.runtimeType.toString(),
      );
      if (ownsOpen() &&
          !_disposed &&
          _foreground &&
          _pending[tracked.agentRunId] == tracked) {
        _markEventStreamUnhealthy(tracked.agentRunId);
        _scheduleRunFallback(tracked, immediate: true);
        _scheduleAgentRunEventStreamReconnect(tracked);
      }
    } finally {
      if (ownsOpen()) {
        _eventStreamOpening.remove(tracked.agentRunId);
      }
    }
  }

  void _applyAgentRunStreamEvent(
    String agentRunId,
    AssistantStreamEvent event,
  ) {
    if (_disposed || !_foreground) return;
    final tracked = _pending[agentRunId];
    if (tracked == null) return;
    _armEventStreamSilentTimeout(tracked);
    if (event.kind != AssistantStreamEventKind.update) {
      if (event.kind == AssistantStreamEventKind.gap) {
        final resumeAfter = event.resumeAfterSequence;
        if (resumeAfter != null && resumeAfter > tracked.lastStreamSequence) {
          _freezeDraftAfterGap(tracked, resumeAfter);
          notifyListeners();
        }
        _forceCheckpoint();
        final subscription = _eventStreams[agentRunId];
        if (subscription != null) {
          _handleAgentRunEventStreamUnavailable(tracked, subscription);
        } else {
          _markEventStreamUnhealthy(agentRunId);
          _scheduleRunFallback(tracked, immediate: true);
          _scheduleAgentRunEventStreamReconnect(tracked);
        }
      }
      return;
    }
    final sequence = event.sequence;
    final createdAt = event.createdAt;
    final status = event.status;
    if (sequence == null || createdAt == null || status == null) return;
    if (sequence <= tracked.lastStreamSequence) return;
    final hasPriorStreamEvent = tracked.lastStreamSequence > 0;
    tracked.lastStreamSequence = sequence;
    if (event.type != AssistantStreamEventType.draftDelta) {
      _chatRunSseDebug(
        'event',
        agentRunId: agentRunId,
        eventType: event.type.name,
        sequence: sequence,
      );
    }
    var changed = false;
    // The public sequence is the only durable SSE checkpoint. Persist it even
    // when this event has no presentation change, otherwise app recreation
    // would reopen from zero and replay previously delivered draft deltas.
    var requiresPersistence = true;
    final nextStatus = _mergeStreamChatRunStatus(
      current: tracked.status,
      candidate: _assistantStatusValue(status),
      hasPriorStreamEvent: hasPriorStreamEvent,
    );
    if (tracked.status != nextStatus) {
      tracked.status = nextStatus;
      _queueTaskLedgerUpsert(_chatLedgerEntry(tracked));
      changed = true;
      requiresPersistence = true;
    }
    if (event.invocationId != null &&
        event.toolName != null &&
        event.toolState != null) {
      final nextTrace = AgentRunToolTrace(
        invocationId: event.invocationId!,
        toolName: event.toolName!,
        state: event.toolState!,
        outcome: event.outcome,
        createdAt: createdAt,
        completedAt: event.toolState == 'finished' ? createdAt : null,
        outputFiles: event.outputFiles
            .map(
              (file) => AgentRunOutputFile(
                resourceId: file.resourceId,
                fileName: file.fileName,
                mimeType: file.mimeType,
                sizeBytes: file.sizeBytes,
              ),
            )
            .toList(growable: false),
      );
      final normalized = _mergeMonotonicToolTrace(
        tracked.toolTrace,
        <AgentRunToolTrace>[nextTrace],
      );
      if (!_sameToolTrace(tracked.toolTrace, normalized)) {
        tracked.toolTrace = normalized;
        changed = true;
        requiresPersistence = true;
      }
    }
    final deltaText = event.deltaText;
    if (event.type == AssistantStreamEventType.draftDelta &&
        deltaText != null &&
        deltaText.isNotEmpty &&
        (tracked.draftState != ChatRunDraftState.awaitingRecovery ||
            event.replace)) {
      _queueDraftDelta(
        tracked,
        eventSequence: sequence,
        deltaText: deltaText,
        replace: event.replace,
      );
    }
    final statusValue = _assistantStatusValue(status);
    final terminal = _isTerminalTaskStatus(statusValue);
    if (terminal && _flushPendingDraftDelta(agentRunId, notify: false)) {
      changed = true;
    }
    if (terminal) {
      _rememberSettledActivity(tracked, completedAt: createdAt);
    }
    final provisionalFailureCode = terminal
        ? _provisionalTerminalFailureCode(statusValue)
        : null;
    if (provisionalFailureCode != null) {
      _publishChatRunCompletion(
        tracked,
        status: statusValue,
        failureCode: provisionalFailureCode,
        completedAt: createdAt,
      );
      changed = true;
    }
    if (requiresPersistence) _scheduleCheckpoint();
    if (terminal) _flushCheckpoint();
    if (changed) notifyListeners();
    if (terminal) {
      _cancelAgentRunEventStream(agentRunId);
      _scheduleRunFallback(tracked, immediate: true);
    }
  }

  void _cancelAgentRunEventStream(String agentRunId) {
    _eventStreamOpening.remove(agentRunId);
    _eventStreamOpenTokens.remove(agentRunId);
    _eventStreamReconnectTimers.remove(agentRunId)?.cancel();
    _eventStreamReconnectAttempts.remove(agentRunId);
    _markEventStreamUnhealthy(agentRunId);
    _runFallbackTimers.remove(agentRunId)?.cancel();
    _runFallbackAttempts.remove(agentRunId);
    _cancelRunFallbackTask(agentRunId);
    final subscription = _eventStreams.remove(agentRunId);
    if (subscription != null) unawaited(subscription.cancel());
    _clearRunRuntimeMetrics(agentRunId);
  }

  void _cancelAllEventStreams() {
    _eventStreamOpening.clear();
    _eventStreamOpenTokens.clear();
    final reconnectTimers = _eventStreamReconnectTimers.values.toList(
      growable: false,
    );
    _eventStreamReconnectTimers.clear();
    for (final timer in reconnectTimers) {
      timer.cancel();
    }
    for (final timer in _eventStreamSilentTimers.values) {
      timer.cancel();
    }
    _eventStreamSilentTimers.clear();
    _healthyEventStreams.clear();
    _eventStreamReconnectAttempts.clear();
    for (final subscription in _eventStreams.values) {
      unawaited(subscription.cancel());
    }
    _eventStreams.clear();
  }

  void _markEventStreamHealthy(_TrackedChatRun tracked) {
    final agentRunId = tracked.agentRunId;
    _healthyEventStreams.add(agentRunId);
    _runFallbackTimers.remove(agentRunId)?.cancel();
    _runFallbackAttempts.remove(agentRunId);
    _cancelRunFallbackTask(agentRunId);
    _eventStreamReconnectAttempts.remove(agentRunId);
    _removeRunFallbackMetric(agentRunId);
    _setRunSseMetric(agentRunId, RuntimeSseState.healthy);
    _armEventStreamSilentTimeout(tracked);
    _ensureChatSnapshotPolling();
  }

  void _markEventStreamUnhealthy(String agentRunId) {
    _healthyEventStreams.remove(agentRunId);
    if (!_hasHealthyChatSnapshots) _chatSnapshotPoller?.stop();
    _eventStreamSilentTimers.remove(agentRunId)?.cancel();
    final tracked = _pending[agentRunId];
    if (_disposed || !_foreground || tracked == null || tracked.isTerminal) {
      _clearRunRuntimeMetrics(agentRunId);
    } else {
      _setRunSseMetric(agentRunId, RuntimeSseState.failed);
    }
  }

  void _armEventStreamSilentTimeout(_TrackedChatRun tracked) {
    if (!_healthyEventStreams.contains(tracked.agentRunId) ||
        eventStreamSilentTimeout < Duration.zero) {
      return;
    }
    _eventStreamSilentTimers.remove(tracked.agentRunId)?.cancel();
    _eventStreamSilentTimers[tracked.agentRunId] = Timer(
      eventStreamSilentTimeout,
      () {
        _eventStreamSilentTimers.remove(tracked.agentRunId);
        final subscription = _eventStreams[tracked.agentRunId];
        if (subscription != null) {
          _handleAgentRunEventStreamUnavailable(tracked, subscription);
        }
      },
    );
  }

  void _handleAgentRunEventStreamUnavailable(
    _TrackedChatRun tracked,
    StreamSubscription<AssistantStreamEvent> subscription,
  ) {
    if (!identical(_eventStreams[tracked.agentRunId], subscription)) return;
    _eventStreams.remove(tracked.agentRunId);
    unawaited(subscription.cancel());
    _markEventStreamUnhealthy(tracked.agentRunId);
    if (_disposed ||
        !_foreground ||
        _pending[tracked.agentRunId] != tracked ||
        tracked.isTerminal) {
      return;
    }
    _scheduleRunFallback(tracked, immediate: true);
    _scheduleAgentRunEventStreamReconnect(tracked);
  }

  void _scheduleRunFallback(_TrackedChatRun tracked, {bool immediate = false}) {
    if (_disposed ||
        !_foreground ||
        !_started ||
        _pending[tracked.agentRunId] != tracked ||
        _healthyEventStreams.contains(tracked.agentRunId) ||
        tracked.reconciliation?.canScheduleAutomatically == false) {
      return;
    }
    _setRunFallbackMetric(tracked.agentRunId);
    if (immediate) {
      _runFallbackTimers.remove(tracked.agentRunId)?.cancel();
    } else if (_runFallbackTimers.containsKey(tracked.agentRunId)) {
      return;
    }
    final attempt = _runFallbackAttempts[tracked.agentRunId] ?? 0;
    final retryAt = tracked.reconciliation?.snapshot.retryAt;
    if (retryAt != null && retryAt.isAfter(_now().toUtc())) {
      _runFallbackTimers[tracked.agentRunId] = Timer(
        retryAt.difference(_now().toUtc()),
        () async {
          _runFallbackTimers.remove(tracked.agentRunId);
          await _runFallbackPoll(tracked, attempt: attempt, immediate: false);
        },
      );
      return;
    }
    if (immediate) {
      unawaited(_runFallbackPoll(tracked, attempt: attempt, immediate: true));
      return;
    }
    final delay = _retryDelay(pollInterval, attempt);
    _runFallbackTimers[tracked.agentRunId] = Timer(delay, () async {
      _runFallbackTimers.remove(tracked.agentRunId);
      await _runFallbackPoll(tracked, attempt: attempt, immediate: false);
    });
  }

  Future<void> _runFallbackPoll(
    _TrackedChatRun tracked, {
    required int attempt,
    required bool immediate,
  }) async {
    if (_disposed ||
        !_foreground ||
        _pending[tracked.agentRunId] != tracked ||
        _healthyEventStreams.contains(tracked.agentRunId)) {
      _removeRunFallbackMetric(tracked.agentRunId);
      return;
    }
    if (tracked.reconciliation?.canScheduleAutomatically == false) return;
    if (!_runFallbackInFlight.add(tracked.agentRunId)) return;
    final generation = _chatReadGeneration;
    _setRunFallbackMetric(tracked.agentRunId);
    try {
      final orchestrator = _taskOrchestrator;
      if (orchestrator == null) {
        await _poll(
          chatRunIds: <String>{tracked.agentRunId},
          includeDerived: false,
        );
      } else {
        // performance-rfc: unified-network-pollers
        final spec = TaskSpec(
          key: _runFallbackTaskKey(tracked.agentRunId),
          owner: 'chat.run-fallback',
          priority: TaskPriority.userVisible,
          resources: const <TaskResource>{TaskResource.network},
          foregroundOnly: true,
          replaceExisting: true,
          retryable: true,
          deadline: const Duration(seconds: 15),
        );
        await orchestrator.schedule<void>(spec, (token) async {
          token.throwIfCancelled();
          if (_disposed ||
              !_foreground ||
              _pending[tracked.agentRunId] != tracked ||
              _healthyEventStreams.contains(tracked.agentRunId)) {
            return;
          }
          await _poll(
            chatRunIds: <String>{tracked.agentRunId},
            includeDerived: false,
          );
        });
      }
    } catch (_) {
      // A thrown transport error is retried by the same bounded fallback.
    } finally {
      if (generation == _chatReadGeneration) {
        _runFallbackInFlight.remove(tracked.agentRunId);
      }
    }
    if (generation != _chatReadGeneration) return;
    if (_disposed ||
        !_foreground ||
        _pending[tracked.agentRunId] != tracked ||
        _healthyEventStreams.contains(tracked.agentRunId)) {
      _removeRunFallbackMetric(tracked.agentRunId);
      return;
    }
    _runFallbackAttempts[tracked.agentRunId] = immediate
        ? attempt
        : attempt + 1;
    _scheduleRunFallback(tracked);
  }

  void _cancelAllRunFallbacks() {
    final agentRunIds = <String>{
      ..._runFallbackTimers.keys,
      ..._runFallbackInFlight,
    };
    for (final timer in _runFallbackTimers.values) {
      timer.cancel();
    }
    _runFallbackTimers.clear();
    _runFallbackAttempts.clear();
    _runFallbackInFlight.clear();
    for (final agentRunId in agentRunIds) {
      _cancelRunFallbackTask(agentRunId);
      _removeRunFallbackMetric(agentRunId);
    }
  }

  void _scheduleAgentRunEventStreamReconnect(_TrackedChatRun tracked) {
    if (_disposed ||
        !_foreground ||
        !_started ||
        tracked.isTerminal ||
        _pending[tracked.agentRunId] != tracked ||
        _eventStreamReconnectTimers.containsKey(tracked.agentRunId)) {
      return;
    }
    final attempt = _eventStreamReconnectAttempts[tracked.agentRunId] ?? 0;
    _eventStreamReconnectAttempts[tracked.agentRunId] = attempt + 1;
    _eventStreamReconnectTimers[tracked.agentRunId] = Timer(
      _retryDelay(eventStreamReconnectDelay, attempt),
      () {
        _eventStreamReconnectTimers.remove(tracked.agentRunId);
        unawaited(_openAgentRunEventStream(tracked));
      },
    );
  }

  Duration _retryDelay(Duration base, int attempt) {
    if (base <= Duration.zero) return Duration.zero;
    final maximum = fallbackMaximumDelay <= Duration.zero
        ? base
        : fallbackMaximumDelay;
    var microseconds = base.inMicroseconds > maximum.inMicroseconds
        ? maximum.inMicroseconds
        : base.inMicroseconds;
    for (
      var index = 0;
      index < attempt && microseconds < maximum.inMicroseconds;
      index += 1
    ) {
      final doubled = microseconds * 2;
      microseconds = doubled > maximum.inMicroseconds
          ? maximum.inMicroseconds
          : doubled;
    }
    final sample = _randomDouble().clamp(0.0, 1.0).toDouble();
    final jittered = (microseconds * (0.8 + sample * 0.4)).round();
    return Duration(
      microseconds: jittered > maximum.inMicroseconds
          ? maximum.inMicroseconds
          : jittered,
    );
  }

  void _queueDraftDelta(
    _TrackedChatRun tracked, {
    required int eventSequence,
    required String deltaText,
    required bool replace,
  }) {
    tracked
      ..draftText = replace ? deltaText : '${tracked.draftText}$deltaText'
      ..draftSequence = eventSequence
      ..draftState = ChatRunDraftState.streaming;
    final existing = _pendingDraftDeltas[tracked.agentRunId];
    if (existing == null || replace) {
      _pendingDraftDeltas[tracked.agentRunId] = _PendingDraftDelta(
        tracked: tracked,
        eventSequence: eventSequence,
        deltaText: deltaText,
        replace: replace,
      );
    } else {
      existing.append(eventSequence: eventSequence, deltaText: deltaText);
    }
    if (draftEventInterval <= Duration.zero) {
      _flushPendingDraftDelta(tracked.agentRunId);
      return;
    }
    _draftEventTimers[tracked.agentRunId] ??= Timer(
      draftEventInterval,
      () => _flushPendingDraftDelta(tracked.agentRunId),
    );
  }

  bool _flushPendingDraftDelta(String agentRunId, {bool notify = true}) {
    _draftEventTimers.remove(agentRunId)?.cancel();
    final pending = _pendingDraftDeltas.remove(agentRunId);
    if (pending == null) return false;
    final tracked = pending.tracked;
    if (_pending[agentRunId] != tracked) return false;
    _lastDraftDelta = ChatRunDraftDelta(
      agentRunId: tracked.agentRunId,
      threadId: tracked.threadId,
      scene: tracked.scene,
      purpose: tracked.purpose,
      eventSequence: pending.eventSequence,
      deltaText: pending.deltaText,
      replace: pending.replace,
    );
    _draftDeltaSequence += 1;
    if (notify && !_disposed) notifyListeners();
    return true;
  }

  void _flushAllPendingDraftDeltas({bool notify = true}) {
    for (final agentRunId in _pendingDraftDeltas.keys.toList(growable: false)) {
      _flushPendingDraftDelta(agentRunId, notify: notify);
    }
  }

  void _freezeDraftAfterGap(_TrackedChatRun tracked, int resumeAfterSequence) {
    _flushPendingDraftDelta(tracked.agentRunId, notify: false);
    tracked
      ..draftState = ChatRunDraftState.awaitingRecovery
      ..lastStreamSequence = resumeAfterSequence;
  }

  Future<bool> _restoreBeforeEnrollment() async {
    if (_disposed || _accountCleared || _userScope == 'anonymous') return false;
    final restoreGeneration = _initialRestoreGeneration;
    await _ensureInitialStateRestored();
    return !_disposed &&
        !_accountCleared &&
        _initialRestoreCompleted &&
        restoreGeneration == _initialRestoreGeneration;
  }

  Future<void> _ensureInitialStateRestored() {
    if (_initialRestoreCompleted ||
        _disposed ||
        _accountCleared ||
        _userScope == 'anonymous') {
      return Future<void>.value();
    }
    return _initialRestoreFuture ??= _restoreInitialState(
      _initialRestoreGeneration,
    );
  }

  Future<void> _restoreInitialState(int restoreGeneration) async {
    _restoreLegacy();
    if (_checkpointPersistence?.isEnabled == true &&
        !await _restoreWorker(restoreGeneration)) {
      if (!_disposed &&
          !_accountCleared &&
          restoreGeneration == _initialRestoreGeneration) {
        _initialRestoreFuture = null;
      }
      return;
    }
    if (_disposed ||
        _accountCleared ||
        restoreGeneration != _initialRestoreGeneration) {
      return;
    }
    _normalizeTerminalLedgerAuthority();
    _initialRestoreCompleted = true;
  }

  void _restoreLegacy() {
    final raw = _preferences.readValue(_preferenceKey);
    if (raw == null) return;
    try {
      final decoded = jsonDecode(raw);
      // Version 1 stored the active entries directly as a list.
      final active = decoded is List
          ? decoded
          : decoded is Map
          ? decoded['active']
          : null;
      if (active is! List) return;
      for (final value in active) {
        final chat = _TrackedChatRun.fromJson(value);
        if (chat != null) {
          _pending.putIfAbsent(chat.agentRunId, () => chat);
          continue;
        }
        final derived = _TrackedDerivedPartRun.fromJson(value);
        if (derived != null) {
          _pendingDerived.putIfAbsent(derived.fileAgentRunId, () => derived);
          continue;
        }
        final recordingOutline = _TrackedRecordingOutlineRun.fromJson(value);
        if (recordingOutline != null) {
          _pendingRecordingOutlines.putIfAbsent(
            recordingOutline.trackingTaskId,
            () => recordingOutline,
          );
        }
      }
      final ledger = decoded is Map ? decoded['ledger'] : null;
      if (ledger is List) {
        for (final value in ledger) {
          final entry = _taskLedgerEntryFromJson(value);
          if (entry == null) continue;
          _taskLedger.putIfAbsent(entry.taskId, () => entry);
          final completion = _chatRunCompletionFromLedgerState(value, entry);
          if (completion != null) {
            _rememberRestoredChatCompletion(completion);
          }
        }
      }
      if (decoded is Map) {
        final restoredSubjects =
            _restoreSubjectIndex(
              decoded['chatSubjects'],
              _chatSubjectTitlesByThreadId,
              isSafeChatIdentifier,
            ) |
            _restoreSubjectIndex(
              decoded['assetSubjects'],
              _assetSubjectTitlesByLocalNoteId,
              _isSafeTaskIdentifier,
            );
        if (restoredSubjects) _taskSubjectRevision += 1;
      }
    } catch (_) {}
  }

  Future<bool> _restoreWorker(int restoreGeneration) async {
    final persistence = _checkpointPersistence;
    if (persistence == null || !persistence.isEnabled) return true;
    final restoreRevision = _checkpointStateRevision;
    late final List<ChatRunCheckpoint> checkpoints;
    try {
      checkpoints = await persistence.load(_userScope);
    } catch (_) {
      return false;
    }

    if (_disposed ||
        _accountCleared ||
        restoreGeneration != _initialRestoreGeneration) {
      return false;
    }
    final pending = <String, _TrackedChatRun>{};
    final pendingDerived = <String, _TrackedDerivedPartRun>{};
    final pendingRecordingOutlines = <String, _TrackedRecordingOutlineRun>{};
    final ledger = <String, AgentTaskLedgerEntry>{};
    final ledgerCompletions = <String, ChatRunCompletion?>{};
    final workerUpdatedAtById = <String, DateTime>{};
    final legacyUpdatedAt = _legacyCheckpointUpdatedAt();
    for (final checkpoint in checkpoints) {
      if (legacyUpdatedAt != null &&
          !checkpoint.updatedAt.isAfter(legacyUpdatedAt)) {
        continue;
      }
      final previousUpdatedAt = workerUpdatedAtById[checkpoint.runId];
      if (previousUpdatedAt != null &&
          !checkpoint.updatedAt.isAfter(previousUpdatedAt)) {
        continue;
      }
      final state = checkpoint.publicState;
      if (state.isEmpty) continue;
      if (checkpoint.role == ChatRunCheckpointRole.ledger) {
        final entry = _taskLedgerEntryFromJson(state);
        if (entry == null ||
            entry.taskId != checkpoint.runId ||
            entry.status != checkpoint.status) {
          continue;
        }
        pending.remove(entry.taskId);
        pendingDerived.remove(entry.taskId);
        pendingRecordingOutlines.remove(entry.taskId);
        ledger[entry.taskId] = entry;
        ledgerCompletions[entry.taskId] = _chatRunCompletionFromLedgerState(
          state,
          entry,
        );
        workerUpdatedAtById[entry.taskId] = checkpoint.updatedAt;
        continue;
      }
      if (checkpoint.kind == ChatRunCheckpointKind.chat) {
        final run = _TrackedChatRun.fromJson(state);
        if (run == null ||
            run.agentRunId != checkpoint.runId ||
            run.status != checkpoint.status) {
          continue;
        }
        pendingDerived.remove(run.agentRunId);
        pendingRecordingOutlines.remove(run.agentRunId);
        ledger.remove(run.agentRunId);
        ledgerCompletions.remove(run.agentRunId);
        pending[run.agentRunId] = run;
        workerUpdatedAtById[run.agentRunId] = checkpoint.updatedAt;
      } else {
        final recordingOutline = _TrackedRecordingOutlineRun.fromJson(state);
        if (recordingOutline != null &&
            recordingOutline.trackingTaskId == checkpoint.runId &&
            recordingOutline.status == checkpoint.status) {
          pending.remove(recordingOutline.trackingTaskId);
          pendingDerived.remove(recordingOutline.trackingTaskId);
          ledger.remove(recordingOutline.trackingTaskId);
          ledgerCompletions.remove(recordingOutline.trackingTaskId);
          pendingRecordingOutlines[recordingOutline.trackingTaskId] =
              recordingOutline;
          workerUpdatedAtById[recordingOutline.trackingTaskId] =
              checkpoint.updatedAt;
          continue;
        }
        final run = _TrackedDerivedPartRun.fromJson(state);
        if (run == null ||
            run.fileAgentRunId != checkpoint.runId ||
            run.status != checkpoint.status) {
          continue;
        }
        pending.remove(run.fileAgentRunId);
        pendingRecordingOutlines.remove(run.fileAgentRunId);
        ledger.remove(run.fileAgentRunId);
        ledgerCompletions.remove(run.fileAgentRunId);
        pendingDerived[run.fileAgentRunId] = run;
        workerUpdatedAtById[run.fileAgentRunId] = checkpoint.updatedAt;
      }
    }
    if (pending.isEmpty &&
        pendingDerived.isEmpty &&
        pendingRecordingOutlines.isEmpty &&
        ledger.isEmpty) {
      return true;
    }
    final restoreRacedWithLiveMutation =
        _checkpointStateRevision != restoreRevision;
    if (restoreRacedWithLiveMutation) {
      for (final entry in pending.entries) {
        if (!_pending.containsKey(entry.key) &&
            !_pendingDerived.containsKey(entry.key) &&
            !_pendingRecordingOutlines.containsKey(entry.key) &&
            !_taskLedger.containsKey(entry.key)) {
          _pending[entry.key] = entry.value;
        }
      }
      for (final entry in pendingDerived.entries) {
        if (!_pending.containsKey(entry.key) &&
            !_pendingDerived.containsKey(entry.key) &&
            !_pendingRecordingOutlines.containsKey(entry.key) &&
            !_taskLedger.containsKey(entry.key)) {
          _pendingDerived[entry.key] = entry.value;
        }
      }
      for (final entry in pendingRecordingOutlines.entries) {
        if (!_pending.containsKey(entry.key) &&
            !_pendingDerived.containsKey(entry.key) &&
            !_pendingRecordingOutlines.containsKey(entry.key) &&
            !_taskLedger.containsKey(entry.key)) {
          _pendingRecordingOutlines[entry.key] = entry.value;
        }
      }
      for (final entry in ledger.entries) {
        if (_taskLedger.containsKey(entry.key)) continue;
        _pending.remove(entry.key);
        _pendingDerived.remove(entry.key);
        _pendingRecordingOutlines.remove(entry.key);
        _taskLedger[entry.key] = entry.value;
        _replaceRestoredChatCompletion(entry.key, ledgerCompletions[entry.key]);
      }
      return true;
    }
    for (final entry in pending.entries) {
      if (_taskLedger.containsKey(entry.key)) continue;
      _pendingDerived.remove(entry.key);
      _pendingRecordingOutlines.remove(entry.key);
      _pending[entry.key] = entry.value;
    }
    for (final entry in pendingDerived.entries) {
      if (_taskLedger.containsKey(entry.key)) continue;
      _pending.remove(entry.key);
      _pendingRecordingOutlines.remove(entry.key);
      _pendingDerived[entry.key] = entry.value;
    }
    for (final entry in pendingRecordingOutlines.entries) {
      if (_taskLedger.containsKey(entry.key)) continue;
      _pending.remove(entry.key);
      _pendingDerived.remove(entry.key);
      _pendingRecordingOutlines[entry.key] = entry.value;
    }
    for (final entry in ledger.entries) {
      _pending.remove(entry.key);
      _pendingDerived.remove(entry.key);
      _pendingRecordingOutlines.remove(entry.key);
      _taskLedger[entry.key] = entry.value;
      _replaceRestoredChatCompletion(entry.key, ledgerCompletions[entry.key]);
    }
    return true;
  }

  void _normalizeTerminalLedgerAuthority() {
    for (final entry in _taskLedger.values) {
      if (!entry.isTerminal) continue;
      final removedChat = _pending.remove(entry.taskId);
      _pendingDerived.remove(entry.taskId);
      _pendingRecordingOutlines.remove(entry.taskId);
      if (removedChat != null) {
        _cancelAgentRunEventStream(entry.taskId);
      }
      if (entry.kind == 'chat') {
        final threadId = entry.threadId;
        if (threadId != null) {
          if (removedChat != null) {
            removedChat.status = entry.status;
            _rememberSettledActivity(removedChat, completedAt: entry.createdAt);
          } else {
            _rememberSettledRun(entry.taskId, threadId);
          }
        }
      } else if (entry.kind == 'derived_part') {
        _rememberSettledDerivedRun(entry.taskId);
      } else if (entry.kind == 'recording_outline') {
        _settledRecordingOutlineTaskIds.add(entry.taskId);
      }
    }
    if (_chatCompletionJournal.isNotEmpty) {
      _lastCompletion = _chatCompletionJournal.values.reduce(
        (current, candidate) =>
            (candidate.completedAt ?? DateTime.fromMillisecondsSinceEpoch(0))
                .isAfter(
                  current.completedAt ?? DateTime.fromMillisecondsSinceEpoch(0),
                )
            ? candidate
            : current,
      );
      if (_completionSequence == 0) _completionSequence = 1;
    }
  }

  void _rememberRestoredChatCompletion(ChatRunCompletion completion) {
    _chatCompletionJournal.remove(completion.agentRunId);
    _chatCompletionJournal[completion.agentRunId] = completion;
    const maximum = 100;
    while (_chatCompletionJournal.length > maximum) {
      _chatCompletionJournal.remove(_chatCompletionJournal.keys.first);
    }
  }

  void _replaceRestoredChatCompletion(
    String taskId,
    ChatRunCompletion? completion,
  ) {
    _chatCompletionJournal.remove(taskId);
    if (completion != null) _rememberRestoredChatCompletion(completion);
  }

  void _scheduleCheckpoint() {
    _checkpointStateRevision += 1;
    _checkpointDirty = true;
    if (checkpointInterval <= Duration.zero) {
      _flushCheckpoint();
      return;
    }
    _checkpointTimer ??= Timer(checkpointInterval, () => _flushCheckpoint());
  }

  void _forceCheckpoint() {
    _checkpointDirty = true;
    _flushCheckpoint(legacyBackup: true);
  }

  void _flushCheckpoint({bool legacyBackup = false}) {
    _checkpointTimer?.cancel();
    _checkpointTimer = null;
    if (!_checkpointDirty) return;
    _checkpointDirty = false;
    _persist(legacyBackup: legacyBackup);
  }

  void _persist({bool legacyBackup = true}) {
    _checkpointStateRevision += 1;
    try {
      final snapshot = _legacyCheckpointSnapshot();
      final persistence = _checkpointPersistence;
      if (persistence == null || !persistence.isEnabled) {
        _writeLegacyCheckpoint(snapshot);
        _onCheckpointPersisted?.call();
        return;
      }
      if (legacyBackup) {
        _writeLegacyCheckpoint(snapshot);
        _onCheckpointPersisted?.call();
      }
      final write = persistence.replace(
        userScope: _userScope,
        checkpoints: _workerCheckpoints(
          DateTime.parse(snapshot.updatedAt).toUtc(),
        ),
        legacyFallback: () => _writeLegacyCheckpointDurably(snapshot),
      );
      if (legacyBackup) {
        unawaited(write.catchError((Object _) {}));
      } else {
        unawaited(
          write
              .then<void>((_) => _onCheckpointPersisted?.call())
              .catchError((Object _) {}),
        );
      }
    } catch (_) {}
  }

  Future<void> _persistDurably() async {
    _checkpointStateRevision += 1;
    final snapshot = _legacyCheckpointSnapshot();
    final persistence = _checkpointPersistence;
    if (persistence == null || !persistence.isEnabled) {
      await _writeLegacyCheckpointDurably(snapshot);
    } else {
      await persistence.replace(
        userScope: _userScope,
        checkpoints: _workerCheckpoints(
          DateTime.parse(snapshot.updatedAt).toUtc(),
        ),
        legacyFallback: () => _writeLegacyCheckpointDurably(snapshot),
      );
    }
    try {
      _onCheckpointPersisted?.call();
    } catch (_) {
      // A diagnostic callback cannot invalidate an already durable checkpoint.
    }
  }

  ({String value, String updatedAt}) _legacyCheckpointSnapshot() {
    final updatedAt = _now().toUtc().toIso8601String();
    return (
      value: jsonEncode(<String, Object?>{
        'version': 4,
        'active': <Map<String, Object?>>[
          ..._pending.values.map((value) => value.toJson()),
          ..._pendingDerived.values.map((value) => value.toJson()),
          ..._pendingRecordingOutlines.values.map((value) => value.toJson()),
        ],
        'ledger': _taskLedger.values
            .map(_taskLedgerCheckpointState)
            .toList(growable: false),
        if (_chatSubjectTitlesByThreadId.isNotEmpty)
          'chatSubjects': _chatSubjectTitlesByThreadId,
        if (_assetSubjectTitlesByLocalNoteId.isNotEmpty)
          'assetSubjects': _assetSubjectTitlesByLocalNoteId,
      }),
      updatedAt: updatedAt,
    );
  }

  void _writeLegacyCheckpoint(({String value, String updatedAt}) snapshot) {
    _preferences.upsertValue(
      preferenceKey: _preferenceKey,
      value: snapshot.value,
      updatedAt: snapshot.updatedAt,
    );
  }

  Future<void> _writeLegacyCheckpointDurably(
    ({String value, String updatedAt}) snapshot,
  ) => _preferences.upsertValueDeferred(
    preferenceKey: _preferenceKey,
    value: snapshot.value,
    updatedAt: snapshot.updatedAt,
  );

  DateTime? _legacyCheckpointUpdatedAt() {
    try {
      for (final record in _preferences.listPreferences()) {
        if (record['preference_key'] != _preferenceKey) continue;
        return DateTime.tryParse('${record['updated_at'] ?? ''}')?.toUtc();
      }
    } catch (_) {}
    return null;
  }

  List<ChatRunCheckpoint> _workerCheckpoints(DateTime updatedAt) {
    return <ChatRunCheckpoint>[
      for (final run in _pending.values)
        ChatRunCheckpoint(
          userScope: _userScope,
          runId: run.agentRunId,
          kind: ChatRunCheckpointKind.chat,
          role: ChatRunCheckpointRole.active,
          status: run.status,
          eventSequence: run.lastStreamSequence,
          threadId: run.threadId,
          scene: run.scene.apiValue,
          purpose: run.purpose.apiValue,
          createdAt: run.createdAt,
          updatedAt: updatedAt,
          publicState: run.toJson(),
        ),
      for (final run in _pendingDerived.values)
        ChatRunCheckpoint(
          userScope: _userScope,
          runId: run.fileAgentRunId,
          kind: ChatRunCheckpointKind.derived,
          role: ChatRunCheckpointRole.active,
          status: run.status,
          eventSequence: 0,
          localNoteId: run.localNoteId,
          targetPart: run.targetPart.wireName,
          createdAt: run.createdAt,
          updatedAt: updatedAt,
          publicState: run.toJson(),
        ),
      for (final run in _pendingRecordingOutlines.values)
        ChatRunCheckpoint(
          userScope: _userScope,
          runId: run.trackingTaskId,
          kind: ChatRunCheckpointKind.derived,
          role: ChatRunCheckpointRole.active,
          status: run.status,
          eventSequence: 0,
          localNoteId: run.localNoteId,
          targetPart: NoteFileAgentPart.outline.wireName,
          createdAt: run.createdAt,
          updatedAt: updatedAt,
          publicState: run.toJson(),
        ),
      for (final entry in _taskLedger.values)
        ChatRunCheckpoint(
          userScope: _userScope,
          runId: entry.taskId,
          kind: entry.kind == 'chat'
              ? ChatRunCheckpointKind.chat
              : ChatRunCheckpointKind.derived,
          role: ChatRunCheckpointRole.ledger,
          status: entry.status,
          eventSequence: 0,
          threadId: entry.threadId,
          scene: entry.scene?.apiValue,
          purpose: entry.purpose?.apiValue,
          localNoteId: entry.localNoteId,
          targetPart: entry.targetPart?.wireName,
          failureCode: entry.failureCode,
          createdAt: entry.createdAt,
          updatedAt: updatedAt,
          publicState: _taskLedgerCheckpointState(entry),
        ),
    ];
  }

  Map<String, Object?> _taskLedgerCheckpointState(AgentTaskLedgerEntry entry) {
    final state = _taskLedgerEntryToJson(entry);
    final completion = _chatCompletionJournal[entry.taskId];
    if (completion != null &&
        entry.kind == 'chat' &&
        completion.threadId == entry.threadId &&
        completion.scene == entry.scene &&
        completion.purpose == entry.purpose &&
        completion.status == entry.status) {
      state['completion'] = _chatRunCompletionToJson(completion);
    }
    return state;
  }

  Future<void> _refreshNotifications(Future<void> Function() onTerminal) async {
    try {
      await onTerminal();
    } catch (_) {
      // Notification retrieval must not discard a terminal Run completion.
    }
  }

  Future<void> _pollDerivedPart(_TrackedDerivedPartRun tracked) async {
    final fileAgentRuns = _fileAgentRuns;
    if (fileAgentRuns == null) return;
    final fileReadGeneration = tracked.mutationGeneration;
    try {
      final fileRun = await fileAgentRuns.getRun(
        noteId: tracked.remoteNoteId,
        fileAgentRunId: tracked.fileAgentRunId,
      );
      if (_disposed || !_started || !_foreground) return;
      if (_pendingDerived[tracked.fileAgentRunId] != tracked) return;
      if (tracked.mutationGeneration != fileReadGeneration) {
        _requestImmediateDerivedPoll();
        return;
      }
      if (fileRun.noteId != tracked.remoteNoteId ||
          fileRun.fileAgentRunId != tracked.fileAgentRunId ||
          (fileRun.targetPart != null &&
              fileRun.targetPart != tracked.targetPart)) {
        return;
      }
      var changed = false;
      var attemptStateChanged = false;
      final agentAttemptChanged =
          fileRun.agentRunId != null &&
          tracked.agentRunId != fileRun.agentRunId;
      if (agentAttemptChanged) {
        tracked.agentRunId = fileRun.agentRunId;
        tracked.toolTrace = const <AgentRunToolTrace>[];
        changed = true;
        attemptStateChanged = true;
      }
      if (fileRun.outputPartRevisionId != null) {
        if (tracked.outputPartRevisionId != null &&
            tracked.outputPartRevisionId != fileRun.outputPartRevisionId) {
          return;
        }
        if (tracked.outputPartRevisionId == null) {
          tracked.outputPartRevisionId = fileRun.outputPartRevisionId;
          changed = true;
          attemptStateChanged = true;
        }
      }
      final nextStatus =
          tracked.targetPart == NoteFileAgentPart.outline &&
              fileRun.isSuccessful
          ? 'finalizing'
          : fileRun.status;
      if (agentAttemptChanged ||
          _shouldAdvanceDerivedStatus(tracked.status, nextStatus)) {
        tracked.status = nextStatus;
        changed = true;
        attemptStateChanged = true;
      }
      if (attemptStateChanged) tracked.mutationGeneration += 1;
      final agentRunId = tracked.agentRunId;
      if (agentRunId != null) {
        final agentReadGeneration = tracked.mutationGeneration;
        try {
          final agentResult = await _readAssistantRun(agentRunId);
          if (_disposed || !_started || !_foreground) return;
          if (_pendingDerived[tracked.fileAgentRunId] != tracked) return;
          if (tracked.agentRunId != agentRunId ||
              tracked.mutationGeneration != agentReadGeneration) {
            _requestImmediateDerivedPoll();
            return;
          }
          final agentRead = agentResult.data;
          final agentRun = agentRead?.snapshot;
          if (agentResult.ok &&
              agentRead != null &&
              agentRun != null &&
              agentRun.handle.value == agentRunId &&
              !_sameToolTrace(tracked.toolTrace, agentRead.legacyToolTrace)) {
            tracked.toolTrace = agentRead.legacyToolTrace;
            tracked.mutationGeneration += 1;
            changed = true;
          }
        } catch (_) {
          // File-Agent status remains authoritative for durable part writeback.
        }
      }
      if (!fileRun.isTerminal) {
        if (changed) {
          _queueTaskLedgerUpsert(_derivedLedgerEntry(tracked));
          _persist();
          notifyListeners();
        }
        return;
      }
      if (fileRun.isSuccessful && tracked.outputPartRevisionId == null) {
        if (changed) {
          _queueTaskLedgerUpsert(_derivedLedgerEntry(tracked));
          _persist();
          notifyListeners();
        }
        return;
      }
      final completion = DerivedPartRunCompletion(
        fileAgentRunId: tracked.fileAgentRunId,
        agentRunId: tracked.agentRunId,
        localNoteId: tracked.localNoteId,
        remoteNoteId: tracked.remoteNoteId,
        targetPart: tracked.targetPart,
        status: fileRun.status,
        outputPartRevisionId: tracked.outputPartRevisionId,
        failureCode: fileRun.failureCode,
        subjectTitle: tracked.subjectTitle,
        inputPartRevisionId: tracked.inputPartRevisionId,
        targetPartRevisionId: tracked.targetPartRevisionId,
        operationId: tracked.operationId,
      );
      final onDerivedTerminal = _onDerivedPartTerminal;
      if (fileRun.isSuccessful) {
        if (tracked.status != 'finalizing') {
          tracked.status = 'finalizing';
          tracked.mutationGeneration += 1;
        }
        _queueTaskLedgerUpsert(_derivedLedgerEntry(tracked));
        _persist();
        notifyListeners();
        final terminalGeneration = tracked.mutationGeneration;
        final refreshed = onDerivedTerminal == null
            ? true
            : await _refreshDerivedPart(onDerivedTerminal, completion);
        final sameLifecycle = identical(
          _pendingDerived[tracked.fileAgentRunId],
          tracked,
        );
        if (_disposed ||
            _accountCleared ||
            !_started ||
            !_foreground ||
            !sameLifecycle ||
            tracked.mutationGeneration != terminalGeneration ||
            !refreshed) {
          if (sameLifecycle &&
              tracked.mutationGeneration != terminalGeneration) {
            _requestImmediateDerivedPoll();
          }
          return;
        }
      } else if (onDerivedTerminal != null) {
        // Failure is also durable product state. Persist its safe terminal
        // marker so an asset cannot remain indefinitely "running" after the
        // page that submitted it has been disposed.
        final terminalGeneration = tracked.mutationGeneration;
        final refreshed = await _refreshDerivedPart(
          onDerivedTerminal,
          completion,
        );
        final sameLifecycle = identical(
          _pendingDerived[tracked.fileAgentRunId],
          tracked,
        );
        if (_disposed ||
            _accountCleared ||
            !_started ||
            !_foreground ||
            !sameLifecycle ||
            tracked.mutationGeneration != terminalGeneration ||
            !refreshed) {
          if (sameLifecycle &&
              tracked.mutationGeneration != terminalGeneration) {
            _requestImmediateDerivedPoll();
          }
          return;
        }
      }
      _pendingDerived.remove(tracked.fileAgentRunId);
      _rememberSettledDerivedRun(tracked.fileAgentRunId);
      _persist();
      _lastDerivedCompletion = completion;
      _rememberTaskLedger(
        AgentTaskLedgerEntry.derivedPart(
          taskId: completion.fileAgentRunId,
          agentRunId: completion.agentRunId,
          localNoteId: completion.localNoteId,
          remoteNoteId: completion.remoteNoteId,
          targetPart: completion.targetPart,
          status: completion.status,
          createdAt: _now().toUtc(),
          failureCode: completion.failureCode,
          outputPartRevisionId: completion.outputPartRevisionId,
          subjectTitle: completion.subjectTitle,
          inputPartRevisionId: completion.inputPartRevisionId,
          targetPartRevisionId: completion.targetPartRevisionId,
          operationId: completion.operationId,
        ),
      );
      _completionSequence += 1;
      notifyListeners();
      final onTerminal = _onTerminal;
      if (onTerminal != null) unawaited(_refreshNotifications(onTerminal));
    } on NoteFileAgentException {
      // Retain the task for the next foreground poll. A transient API failure
      // must not turn an accepted server operation into a local failure.
    } catch (_) {
      // Keep the persisted binding until a valid terminal projection arrives.
    }
  }

  Future<bool> _refreshDerivedPart(
    Future<bool> Function(DerivedPartRunCompletion completion) callback,
    DerivedPartRunCompletion completion,
  ) async {
    try {
      return await callback(completion);
    } catch (_) {
      // Keep finalizing until a valid readback verifies the server writeback.
      return false;
    }
  }

  void _requestImmediateDerivedPoll() {
    if (_disposed ||
        _accountCleared ||
        !_started ||
        !_foreground ||
        _pendingDerived.isEmpty) {
      return;
    }
    _derivedRepollRequested = true;
    _scheduleRequestedDerivedPoll();
  }

  void _scheduleRequestedDerivedPoll() {
    if (!_derivedRepollRequested ||
        _derivedRepollScheduled ||
        _polling ||
        _disposed ||
        _accountCleared ||
        !_started ||
        !_foreground ||
        _pendingDerived.isEmpty) {
      return;
    }
    _derivedRepollScheduled = true;
    scheduleMicrotask(() {
      _derivedRepollScheduled = false;
      if (!_derivedRepollRequested ||
          _disposed ||
          _accountCleared ||
          !_started ||
          !_foreground ||
          _pendingDerived.isEmpty) {
        return;
      }
      _derivedRepollRequested = false;
      unawaited(_poll(chatRunIds: const <String>{}, includeDerived: true));
    });
  }

  Future<void> _pollRecordingOutline(
    _TrackedRecordingOutlineRun tracked,
  ) async {
    final recordingApi = _recordingApi;
    if (recordingApi == null) return;
    try {
      final result = await recordingApi.getRecordingDetail(tracked.recordingId);
      if (_disposed || !_started || !_foreground) return;
      if (_pendingRecordingOutlines[tracked.trackingTaskId] != tracked) return;
      final detail = result.data;
      if (!result.ok ||
          detail == null ||
          detail.recording.recordingId != tracked.recordingId) {
        return;
      }

      final previousPublicTaskId = tracked.publicTaskId;
      final previousOutputRevision = tracked.outputPartRevisionId;
      final previousStatus = tracked.status;
      final publicTaskId = _safeOptionalTaskIdentifier(
        detail.noteOutlineTask?.taskId,
      );
      if (!tracked.acceptsPublicTaskId(publicTaskId)) return;
      if (tracked.supersededPublicTaskId != null) {
        tracked
          ..expectedPublicTaskId = publicTaskId
          ..supersededPublicTaskId = null;
      }
      if (publicTaskId != null) {
        tracked.publicTaskId = publicTaskId;
      }
      final candidateStatus = _recordingOutlinePublicStatus(detail);
      final expectedRevision = detail.noteRef?.outlinePartRevisionId?.trim();
      if (candidateStatus == 'succeeded' &&
          expectedRevision != null &&
          expectedRevision.isNotEmpty &&
          _isSafeTaskIdentifier(expectedRevision)) {
        tracked.outputPartRevisionId = expectedRevision;
      }

      if (!_isTerminalTaskStatus(candidateStatus)) {
        if (_shouldAdvanceDerivedStatus(tracked.status, candidateStatus)) {
          tracked.status = candidateStatus;
        }
        if (tracked.status != previousStatus ||
            tracked.publicTaskId != previousPublicTaskId ||
            tracked.outputPartRevisionId != previousOutputRevision) {
          _queueTaskLedgerUpsert(_recordingOutlineLedgerEntry(tracked));
          _persist();
          notifyListeners();
        }
        return;
      }

      final completion = RecordingOutlineRunCompletion(
        trackingTaskId: tracked.trackingTaskId,
        publicTaskId: tracked.publicTaskId,
        recordingId: tracked.recordingId,
        localNoteId: tracked.localNoteId,
        remoteNoteId: tracked.remoteNoteId,
        status: candidateStatus,
        outputPartRevisionId: tracked.outputPartRevisionId,
        failureCode: _recordingOutlineFailureCode(detail),
        subjectTitle: tracked.subjectTitle,
      );
      if (candidateStatus == 'succeeded') {
        if (detail.noteRef?.noteId.trim() != tracked.remoteNoteId ||
            tracked.outputPartRevisionId == null) {
          return;
        }
        tracked.status = 'finalizing';
        _queueTaskLedgerUpsert(_recordingOutlineLedgerEntry(tracked));
        _persist();
        notifyListeners();
        final verifier = _onRecordingOutlineTerminal;
        final verified = verifier == null
            ? false
            : await _refreshRecordingOutline(verifier, completion);
        if (_disposed ||
            !_started ||
            !_foreground ||
            _pendingRecordingOutlines[tracked.trackingTaskId] != tracked ||
            tracked.publicTaskId != completion.publicTaskId ||
            !tracked.acceptsPublicTaskId(completion.publicTaskId) ||
            !verified) {
          return;
        }
      }

      _pendingRecordingOutlines.remove(tracked.trackingTaskId);
      _rememberSettledRecordingOutlineRun(tracked.trackingTaskId);
      _lastRecordingOutlineCompletion = completion;
      _rememberTaskLedger(
        AgentTaskLedgerEntry.recordingOutline(
          taskId: completion.trackingTaskId,
          publicTaskId: completion.publicTaskId,
          recordingId: completion.recordingId,
          localNoteId: completion.localNoteId,
          remoteNoteId: completion.remoteNoteId,
          status: completion.status,
          createdAt: _now().toUtc(),
          failureCode: completion.failureCode,
          outputPartRevisionId: completion.outputPartRevisionId,
          subjectTitle: completion.subjectTitle,
        ),
      );
      _completionSequence += 1;
      notifyListeners();
      final onTerminal = _onTerminal;
      if (onTerminal != null) unawaited(_refreshNotifications(onTerminal));
    } catch (_) {
      // Keep the public binding for the next foreground read.
    }
  }

  Future<bool> _refreshRecordingOutline(
    Future<bool> Function(RecordingOutlineRunCompletion completion) callback,
    RecordingOutlineRunCompletion completion,
  ) async {
    try {
      return await callback(completion);
    } catch (_) {
      return false;
    }
  }

  String get _preferenceKey {
    final scope = sha256.convert(utf8.encode(_userScope)).toString();
    return 'chat-run-pending-${scope.substring(0, 24)}';
  }

  void _rememberSettledRun(String agentRunId, String threadId) {
    _settledChatThreadByRunId[agentRunId] = threadId;
    const maximum = 200;
    while (_settledChatThreadByRunId.length > maximum) {
      _settledChatThreadByRunId.remove(_settledChatThreadByRunId.keys.first);
    }
  }

  ChatRunActivity _activityOf(_TrackedChatRun run, {DateTime? completedAt}) =>
      ChatRunActivity(
        agentRunId: run.agentRunId,
        threadId: run.threadId,
        status: run.status,
        createdAt: run.createdAt,
        completedAt: completedAt,
        toolTrace: run.toolTrace,
      );

  void _rememberSettledActivity(_TrackedChatRun run, {DateTime? completedAt}) {
    if (!run.isTerminal) return;
    run.draftState = ChatRunDraftState.settled;
    _rememberSettledRun(run.agentRunId, run.threadId);
    _rememberSettledDraft(run);
    _settledChatActivitiesByRunId.remove(run.agentRunId);
    _settledChatActivitiesByRunId[run.agentRunId] = _activityOf(
      run,
      completedAt: completedAt ?? _now().toUtc(),
    );
    const maximum = 100;
    while (_settledChatActivitiesByRunId.length > maximum) {
      _settledChatActivitiesByRunId.remove(
        _settledChatActivitiesByRunId.keys.first,
      );
    }
  }

  void _rememberSettledDraft(_TrackedChatRun run) {
    if (run.draftText.isEmpty) return;
    _settledChatDraftSnapshotsByRunId.remove(run.agentRunId);
    _settledChatDraftSnapshotsByRunId[run.agentRunId] = ChatRunDraftSnapshot(
      agentRunId: run.agentRunId,
      threadId: run.threadId,
      scene: run.scene,
      purpose: run.purpose,
      eventSequence: run.draftSequence,
      text: run.draftText,
      state: ChatRunDraftState.settled,
    );
    const maximum = 100;
    while (_settledChatDraftSnapshotsByRunId.length > maximum) {
      _settledChatDraftSnapshotsByRunId.remove(
        _settledChatDraftSnapshotsByRunId.keys.first,
      );
    }
  }

  void _rememberSettledDerivedRun(String fileAgentRunId) {
    _settledDerivedFileRunIds.add(fileAgentRunId);
    const maximum = 200;
    while (_settledDerivedFileRunIds.length > maximum) {
      _settledDerivedFileRunIds.remove(_settledDerivedFileRunIds.first);
    }
  }

  void _rememberSettledRecordingOutlineRun(String trackingTaskId) {
    _settledRecordingOutlineTaskIds.add(trackingTaskId);
    const maximum = 200;
    while (_settledRecordingOutlineTaskIds.length > maximum) {
      _settledRecordingOutlineTaskIds.remove(
        _settledRecordingOutlineTaskIds.first,
      );
    }
  }

  AgentTaskLedgerEntry? _terminalChatLedgerEntry(String agentRunId) {
    final entry = _taskLedger[agentRunId];
    return entry != null && entry.kind == 'chat' && entry.isTerminal
        ? entry
        : null;
  }

  ({bool authoritative, bool changed}) _reconcileTerminalChatEnrollment({
    required String agentRunId,
    String? publicTaskId,
    required String threadId,
    required ChatScene scene,
    required ChatConversationPurpose purpose,
    String? subjectTitle,
  }) {
    final terminal = _terminalChatLedgerEntry(agentRunId);
    if (terminal == null) return (authoritative: false, changed: false);

    final terminalThreadId = terminal.threadId;
    if (terminalThreadId != null) {
      _rememberSettledRun(agentRunId, terminalThreadId);
    }
    final removed = _pending.remove(agentRunId);
    var changed = removed != null;
    if (removed != null) {
      removed.status = terminal.status;
      _rememberSettledActivity(removed, completedAt: terminal.createdAt);
    }
    if (changed) {
      _cancelAgentRunEventStream(agentRunId);
    }

    final sameLifecycle =
        terminal.threadId == threadId && terminal.scene == scene;
    final aliasConflicts =
        publicTaskId != null &&
        terminal.publicTaskId != null &&
        terminal.publicTaskId != publicTaskId;
    if (!sameLifecycle || aliasConflicts) {
      if (changed) _queueTaskLedgerUpsert(terminal);
      return (authoritative: true, changed: changed);
    }

    final currentPurpose = terminal.purpose ?? ChatConversationPurpose.general;
    final nextPublicTaskId = terminal.publicTaskId ?? publicTaskId;
    final purposeChanges = _shouldUpgradePurpose(currentPurpose, purpose);
    final aliasChanges = nextPublicTaskId != terminal.publicTaskId;
    final nextSubjectTitle = subjectTitle ?? terminal.subjectTitle;
    final subjectChanges = nextSubjectTitle != terminal.subjectTitle;
    if (!purposeChanges && !aliasChanges && !subjectChanges) {
      if (changed) _queueTaskLedgerUpsert(terminal);
      return (authoritative: true, changed: changed);
    }

    final nextPurpose = purposeChanges ? purpose : currentPurpose;
    final enriched = AgentTaskLedgerEntry.chat(
      taskId: terminal.taskId,
      publicTaskId: nextPublicTaskId,
      threadId: threadId,
      scene: scene,
      purpose: nextPurpose,
      status: terminal.status,
      createdAt: terminal.createdAt,
      failureCode: terminal.failureCode,
      subjectTitle: nextSubjectTitle,
    );
    _taskLedger[agentRunId] = enriched;
    final completion = _chatCompletionJournal[agentRunId];
    if (purposeChanges &&
        completion != null &&
        completion.threadId == terminal.threadId &&
        completion.scene == terminal.scene &&
        completion.status == terminal.status &&
        _shouldUpgradePurpose(completion.purpose, nextPurpose)) {
      final enrichedCompletion = ChatRunCompletion(
        agentRunId: completion.agentRunId,
        threadId: completion.threadId,
        scene: completion.scene,
        purpose: nextPurpose,
        status: completion.status,
        completionMode: completion.completionMode,
        assistantMessageId: completion.assistantMessageId,
        failureCode: completion.failureCode,
        completedAt: completion.completedAt,
      );
      _chatCompletionJournal[agentRunId] = enrichedCompletion;
      if (_lastCompletion?.agentRunId == agentRunId) {
        _lastCompletion = enrichedCompletion;
        _completionSequence += 1;
      }
    }
    _queueTaskLedgerUpsert(enriched);
    changed = true;
    return (authoritative: true, changed: changed);
  }

  ({bool authoritative, bool changed}) _reconcileTerminalDerivedEnrollment({
    required String fileAgentRunId,
    required String localNoteId,
    required String remoteNoteId,
    required NoteFileAgentPart targetPart,
    String? subjectTitle,
    String? inputPartRevisionId,
    String? targetPartRevisionId,
    String? operationId,
    String? agentRunId,
  }) {
    final terminal = _taskLedger[fileAgentRunId];
    if (terminal == null ||
        terminal.kind != 'derived_part' ||
        !terminal.isTerminal) {
      return (authoritative: false, changed: false);
    }

    _rememberSettledDerivedRun(fileAgentRunId);
    var changed = _pendingDerived.remove(fileAgentRunId) != null;
    final sameLifecycle =
        terminal.localNoteId == localNoteId &&
        terminal.targetPart == targetPart &&
        (terminal.remoteNoteId == null ||
            terminal.remoteNoteId == remoteNoteId) &&
        (inputPartRevisionId == null ||
            terminal.inputPartRevisionId == null ||
            terminal.inputPartRevisionId == inputPartRevisionId) &&
        (targetPartRevisionId == null ||
            terminal.targetPartRevisionId == null ||
            terminal.targetPartRevisionId == targetPartRevisionId) &&
        (operationId == null ||
            terminal.operationId == null ||
            terminal.operationId == operationId) &&
        (agentRunId == null ||
            terminal.agentRunId == null ||
            terminal.agentRunId == agentRunId);
    if (!sameLifecycle) {
      if (changed) _queueTaskLedgerUpsert(terminal);
      return (authoritative: true, changed: changed);
    }
    final nextRemoteNoteId = terminal.remoteNoteId ?? remoteNoteId;
    final nextSubjectTitle = subjectTitle ?? terminal.subjectTitle;
    final nextInputPartRevisionId =
        terminal.inputPartRevisionId ?? inputPartRevisionId;
    final nextTargetPartRevisionId =
        terminal.targetPartRevisionId ?? targetPartRevisionId;
    final nextOperationId = terminal.operationId ?? operationId;
    final nextAgentRunId = terminal.agentRunId ?? agentRunId;
    if (nextRemoteNoteId == terminal.remoteNoteId &&
        nextSubjectTitle == terminal.subjectTitle &&
        nextInputPartRevisionId == terminal.inputPartRevisionId &&
        nextTargetPartRevisionId == terminal.targetPartRevisionId &&
        nextOperationId == terminal.operationId &&
        nextAgentRunId == terminal.agentRunId) {
      if (changed) _queueTaskLedgerUpsert(terminal);
      return (authoritative: true, changed: changed);
    }

    final enriched = AgentTaskLedgerEntry.derivedPart(
      taskId: terminal.taskId,
      agentRunId: nextAgentRunId,
      localNoteId: localNoteId,
      remoteNoteId: nextRemoteNoteId,
      targetPart: targetPart,
      status: terminal.status,
      createdAt: terminal.createdAt,
      failureCode: terminal.failureCode,
      outputPartRevisionId: terminal.outputPartRevisionId,
      subjectTitle: nextSubjectTitle,
      inputPartRevisionId: nextInputPartRevisionId,
      targetPartRevisionId: nextTargetPartRevisionId,
      operationId: nextOperationId,
    );
    _taskLedger[fileAgentRunId] = enriched;
    _queueTaskLedgerUpsert(enriched);
    changed = true;
    return (authoritative: true, changed: changed);
  }

  AgentTaskLedgerEntry _chatLedgerEntry(_TrackedChatRun run) =>
      AgentTaskLedgerEntry.chat(
        taskId: run.agentRunId,
        publicTaskId: run.publicTaskId,
        threadId: run.threadId,
        scene: run.scene,
        purpose: run.purpose,
        status: run.status,
        createdAt: run.createdAt,
        subjectTitle: run.subjectTitle,
      );

  AgentTaskLedgerEntry _derivedLedgerEntry(_TrackedDerivedPartRun run) =>
      AgentTaskLedgerEntry.derivedPart(
        taskId: run.fileAgentRunId,
        agentRunId: run.agentRunId,
        localNoteId: run.localNoteId,
        remoteNoteId: run.remoteNoteId,
        targetPart: run.targetPart,
        status: run.status,
        createdAt: run.createdAt,
        outputPartRevisionId: run.outputPartRevisionId,
        subjectTitle: run.subjectTitle,
        inputPartRevisionId: run.inputPartRevisionId,
        targetPartRevisionId: run.targetPartRevisionId,
        operationId: run.operationId,
      );

  AgentTaskLedgerEntry _recordingOutlineLedgerEntry(
    _TrackedRecordingOutlineRun run,
  ) => AgentTaskLedgerEntry.recordingOutline(
    taskId: run.trackingTaskId,
    publicTaskId: run.publicTaskId,
    recordingId: run.recordingId,
    localNoteId: run.localNoteId,
    remoteNoteId: run.remoteNoteId,
    status: run.status,
    createdAt: run.createdAt,
    outputPartRevisionId: run.outputPartRevisionId,
    subjectTitle: run.subjectTitle,
  );

  AgentTaskLedgerEntry _taskLedgerEntryWithSubject(
    AgentTaskLedgerEntry entry,
    String subjectTitle,
  ) => switch (entry.kind) {
    'chat' => AgentTaskLedgerEntry.chat(
      taskId: entry.taskId,
      publicTaskId: entry.publicTaskId,
      threadId: entry.threadId!,
      scene: entry.scene!,
      purpose: entry.purpose ?? ChatConversationPurpose.general,
      status: entry.status,
      createdAt: entry.createdAt,
      failureCode: entry.failureCode,
      subjectTitle: subjectTitle,
    ),
    'derived_part' => AgentTaskLedgerEntry.derivedPart(
      taskId: entry.taskId,
      agentRunId: entry.agentRunId,
      localNoteId: entry.localNoteId!,
      remoteNoteId: entry.remoteNoteId,
      targetPart: entry.targetPart!,
      status: entry.status,
      createdAt: entry.createdAt,
      failureCode: entry.failureCode,
      outputPartRevisionId: entry.outputPartRevisionId,
      subjectTitle: subjectTitle,
      inputPartRevisionId: entry.inputPartRevisionId,
      targetPartRevisionId: entry.targetPartRevisionId,
      operationId: entry.operationId,
    ),
    'recording_outline' => AgentTaskLedgerEntry.recordingOutline(
      taskId: entry.taskId,
      publicTaskId: entry.publicTaskId,
      recordingId: entry.recordingId!,
      localNoteId: entry.localNoteId!,
      remoteNoteId: entry.remoteNoteId!,
      status: entry.status,
      createdAt: entry.createdAt,
      failureCode: entry.failureCode,
      outputPartRevisionId: entry.outputPartRevisionId,
      subjectTitle: subjectTitle,
    ),
    _ => entry,
  };

  void _queueTaskLedgerUpsert(AgentTaskLedgerEntry entry) {
    _queuedTaskLedgerRemovals.remove(entry.taskId);
    _queuedTaskLedgerUpserts[entry.taskId] = entry;
  }

  void _queueTaskLedgerRemoval(String taskId) {
    _queuedTaskLedgerUpserts.remove(taskId);
    _queuedTaskLedgerRemovals.add(taskId);
  }

  void _queueTaskLedgerReset() {
    _taskLedgerResetQueued = true;
    _queuedTaskLedgerUpserts.clear();
    _queuedTaskLedgerRemovals.clear();
  }

  void _rememberTaskLedger(AgentTaskLedgerEntry entry) {
    if (!entry.isTerminal) return;
    _taskLedger[entry.taskId] = entry;
    _queueTaskLedgerUpsert(entry);
    const maximum = 100;
    while (_taskLedger.length > maximum) {
      final removedTaskId = _taskLedger.keys.first;
      _taskLedger.remove(removedTaskId);
      _queueTaskLedgerRemoval(removedTaskId);
    }
    _persist();
  }

  @override
  void dispose() {
    _disposed = true;
    _derivedRepollRequested = false;
    _initialRestoreGeneration += 1;
    pause();
    _chatSnapshotPoller?.dispose();
    _chatSnapshotPoller = null;
    _derivedPoller?.dispose();
    _derivedPoller = null;
    _cancelAllEventStreams();
    super.dispose();
  }
}

final class _PendingDraftDelta {
  _PendingDraftDelta({
    required this.tracked,
    required this.eventSequence,
    required String deltaText,
    required this.replace,
  }) : _deltaText = StringBuffer(deltaText);

  final _TrackedChatRun tracked;
  int eventSequence;
  final StringBuffer _deltaText;
  final bool replace;

  String get deltaText => _deltaText.toString();

  void append({required int eventSequence, required String deltaText}) {
    this.eventSequence = eventSequence;
    _deltaText.write(deltaText);
  }
}

final class _TrackedChatRun {
  _TrackedChatRun({
    required this.agentRunId,
    this.publicTaskId,
    required this.threadId,
    required this.scene,
    this.purpose = ChatConversationPurpose.general,
    this.status = 'queued',
    this.subjectTitle,
    DateTime? createdAt,
    List<AgentRunToolTrace> toolTrace = const <AgentRunToolTrace>[],
  }) : createdAt = (createdAt ?? DateTime.now()).toUtc(),
       toolTrace = List<AgentRunToolTrace>.unmodifiable(toolTrace);

  final String agentRunId;
  String? publicTaskId;
  final String threadId;
  final ChatScene scene;
  ChatConversationPurpose purpose;
  String status;
  String? subjectTitle;
  DateTime createdAt;
  List<AgentRunToolTrace> toolTrace;
  int lastStreamSequence = 0;
  int draftSequence = 0;
  String draftText = '';
  ChatRunDraftState draftState = ChatRunDraftState.streaming;
  bool terminalCompletionPublished = false;
  ChatRunReconciliation? _reconciliation;

  ChatRunReconciliation? get reconciliation =>
      isTerminal ? _reconciliation ??= ChatRunReconciliation() : null;

  bool get isTerminal => _isTerminalTaskStatus(status);

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': 'chat',
    'agentRunId': agentRunId,
    if (publicTaskId != null) 'publicTaskId': publicTaskId,
    'threadId': threadId,
    'scene': scene.apiValue,
    'purpose': purpose.apiValue,
    'status': status,
    if (subjectTitle != null) 'subjectTitle': subjectTitle,
    'createdAt': createdAt.toIso8601String(),
    'toolTrace': _toolTraceToJson(toolTrace),
    if (isTerminal) 'reconciliation': reconciliation!.toJson(),
    if (_isSafePersistedStreamSequence(lastStreamSequence))
      'lastStreamSequence': lastStreamSequence,
  };

  static _TrackedChatRun? fromJson(Object? value) {
    if (value is! Map) return null;
    final agentRunId = value['agentRunId'];
    final publicTaskId = value['publicTaskId'];
    final threadId = value['threadId'];
    final scene = ChatScene.tryParse(value['scene']);
    final rawPurpose = value['purpose'];
    final purpose = rawPurpose == null
        ? ChatConversationPurpose.general
        : ChatConversationPurpose.tryParseApi(rawPurpose);
    final status = value['status'];
    final subjectTitle = _safeTaskSubjectTitle(value['subjectTitle']);
    final createdAt = value['createdAt'];
    final toolTrace = _toolTraceFromJson(value['toolTrace']);
    final lastStreamSequence = _safePersistedStreamSequence(
      value['lastStreamSequence'],
    );
    if (agentRunId is! String ||
        threadId is! String ||
        scene == null ||
        purpose == null ||
        (status != null && status is! String) ||
        (createdAt != null && _safeTraceDate(createdAt) == null) ||
        toolTrace == null ||
        !isSafeAgentRunIdentifier(agentRunId) ||
        (publicTaskId != null &&
            (publicTaskId is! String ||
                !_isSafeTaskIdentifier(publicTaskId))) ||
        !isSafeChatIdentifier(threadId)) {
      return null;
    }
    final tracked = _TrackedChatRun(
      agentRunId: agentRunId,
      publicTaskId: publicTaskId as String?,
      threadId: threadId,
      scene: scene,
      purpose: purpose,
      status: status is String && _publicTrackedRunStatuses.contains(status)
          ? status
          : 'queued',
      subjectTitle: subjectTitle,
      createdAt: createdAt == null
          ? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true)
          : _safeTraceDate(createdAt),
      toolTrace: toolTrace,
    );
    tracked.lastStreamSequence = lastStreamSequence;
    if (tracked.isTerminal) {
      tracked._reconciliation = ChatRunReconciliation.fromJson(
        value['reconciliation'],
      );
    }
    return tracked;
  }
}

const _maxPersistedAgentRunEventSequence = 9223372036854775807;

bool _isSafePersistedStreamSequence(int value) =>
    value > 0 && value <= _maxPersistedAgentRunEventSequence;

int _safePersistedStreamSequence(Object? value) =>
    value is int && _isSafePersistedStreamSequence(value) ? value : 0;

void _chatRunSseDebug(
  String stage, {
  required String agentRunId,
  int? status,
  String? code,
  String? errorType,
  String? eventType,
  int? sequence,
  int? deltaLength,
}) {
  if (!kDebugMode) return;
  debugPrint(
    '[AgentRunSSE] stage=$stage run=$agentRunId '
    'status=${status ?? '-'} code=${code ?? '-'} '
    'error=${errorType ?? '-'} event=${eventType ?? '-'} '
    'sequence=${sequence ?? '-'} deltaLength=${deltaLength ?? '-'}',
  );
}

const _publicTrackedRunStatuses = <String>{
  'admitting',
  'resolving',
  'planning',
  'awaiting_confirmation',
  'queued',
  'running',
  'finalizing',
  'aborting',
  'succeeded',
  'failed',
  'timeout',
  'cancelled',
  'conflict',
  'orphaned',
};

bool _shouldUpgradePurpose(
  ChatConversationPurpose current,
  ChatConversationPurpose candidate,
) =>
    current == ChatConversationPurpose.general &&
    candidate == ChatConversationPurpose.deepPositioning;

const _publicDerivedTaskStatuses = <String>{
  'admitting',
  'retry_wait',
  'retry_admitting',
  'queued',
  'resolving',
  'planning',
  'running',
  'finalizing',
  'succeeded',
  'failed',
  'timeout',
  'cancelled',
  'conflict',
};

String? _safeDerivedTaskStatus(String? value) {
  final normalized = value?.trim().toLowerCase();
  if (normalized == null || normalized.isEmpty) return null;
  return _publicDerivedTaskStatuses.contains(normalized) ? normalized : null;
}

bool _shouldAdvanceDerivedStatus(String current, String candidate) {
  if (current == candidate) return false;
  if (_derivedTaskStatusRank(current) == 6) return false;
  if (current == 'retry_wait' ||
      current == 'retry_admitting' ||
      candidate == 'retry_wait' ||
      candidate == 'retry_admitting') {
    return true;
  }
  return _derivedTaskStatusRank(candidate) > _derivedTaskStatusRank(current);
}

int _derivedTaskStatusRank(String status) => switch (status) {
  'admitting' => 0,
  'retry_wait' => 1,
  'retry_admitting' => 2,
  'queued' => 1,
  'resolving' => 2,
  'planning' => 3,
  'running' => 4,
  'finalizing' => 5,
  'succeeded' || 'failed' || 'timeout' || 'cancelled' || 'conflict' => 6,
  _ => -1,
};

final class _TrackedDerivedPartRun {
  _TrackedDerivedPartRun({
    required this.fileAgentRunId,
    this.agentRunId,
    required this.localNoteId,
    required this.remoteNoteId,
    required this.targetPart,
    this.status = 'queued',
    this.outputPartRevisionId,
    this.subjectTitle,
    this.inputPartRevisionId,
    this.targetPartRevisionId,
    this.operationId,
    DateTime? createdAt,
    List<AgentRunToolTrace> toolTrace = const <AgentRunToolTrace>[],
  }) : createdAt = (createdAt ?? DateTime.now()).toUtc(),
       toolTrace = List<AgentRunToolTrace>.unmodifiable(toolTrace);

  final String fileAgentRunId;
  String? agentRunId;
  final String localNoteId;
  final String remoteNoteId;
  final NoteFileAgentPart targetPart;
  String status;
  String? outputPartRevisionId;
  String? subjectTitle;
  String? inputPartRevisionId;
  String? targetPartRevisionId;
  String? operationId;
  final DateTime createdAt;
  List<AgentRunToolTrace> toolTrace;
  int mutationGeneration = 0;

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': 'derived_part',
    'fileAgentRunId': fileAgentRunId,
    if (agentRunId != null) 'agentRunId': agentRunId,
    'localNoteId': localNoteId,
    'remoteNoteId': remoteNoteId,
    'targetPart': targetPart.wireName,
    'status': status,
    if (outputPartRevisionId != null)
      'outputPartRevisionId': outputPartRevisionId,
    if (subjectTitle != null) 'subjectTitle': subjectTitle,
    if (inputPartRevisionId != null) 'inputPartRevisionId': inputPartRevisionId,
    if (targetPartRevisionId != null)
      'targetPartRevisionId': targetPartRevisionId,
    if (operationId != null) 'operationId': operationId,
    'createdAt': createdAt.toIso8601String(),
    'toolTrace': _toolTraceToJson(toolTrace),
  };

  static _TrackedDerivedPartRun? fromJson(Object? value) {
    if (value is! Map || value['kind'] != 'derived_part') return null;
    final fileAgentRunId = value['fileAgentRunId'];
    final agentRunId = value['agentRunId'];
    final localNoteId = value['localNoteId'];
    final remoteNoteId = value['remoteNoteId'];
    final targetPart = _noteFileAgentPartFromWire(value['targetPart']);
    final status = value['status'];
    final outputPartRevisionId = value['outputPartRevisionId'];
    final subjectTitle = _safeTaskSubjectTitle(value['subjectTitle']);
    final inputPartRevisionId = value['inputPartRevisionId'];
    final targetPartRevisionId = value['targetPartRevisionId'];
    final operationId = value['operationId'];
    final createdAt = value['createdAt'];
    final toolTrace = _toolTraceFromJson(value['toolTrace']);
    if (fileAgentRunId is! String ||
        localNoteId is! String ||
        remoteNoteId is! String ||
        targetPart == null ||
        status is! String ||
        (createdAt != null && _safeTraceDate(createdAt) == null) ||
        _safeDerivedTaskStatus(status) == null ||
        (outputPartRevisionId != null &&
            (outputPartRevisionId is! String ||
                !_isSafeTaskIdentifier(outputPartRevisionId))) ||
        (inputPartRevisionId != null &&
            (inputPartRevisionId is! String ||
                !_isSafeTaskIdentifier(inputPartRevisionId))) ||
        (targetPartRevisionId != null &&
            (targetPartRevisionId is! String ||
                !_isSafeTaskIdentifier(targetPartRevisionId))) ||
        (operationId != null &&
            (operationId is! String || !_isSafeTaskIdentifier(operationId))) ||
        toolTrace == null ||
        !_isSafeTaskIdentifier(fileAgentRunId) ||
        (agentRunId != null &&
            (agentRunId is! String || !isSafeAgentRunIdentifier(agentRunId))) ||
        !_isSafeTaskIdentifier(localNoteId) ||
        !_isSafeTaskIdentifier(remoteNoteId)) {
      return null;
    }
    return _TrackedDerivedPartRun(
      fileAgentRunId: fileAgentRunId,
      agentRunId: agentRunId is String ? agentRunId : null,
      localNoteId: localNoteId,
      remoteNoteId: remoteNoteId,
      targetPart: targetPart,
      status: _safeDerivedTaskStatus(status)!,
      outputPartRevisionId: outputPartRevisionId is String
          ? outputPartRevisionId
          : null,
      subjectTitle: subjectTitle,
      inputPartRevisionId: inputPartRevisionId as String?,
      targetPartRevisionId: targetPartRevisionId as String?,
      operationId: operationId as String?,
      createdAt: createdAt == null
          ? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true)
          : _safeTraceDate(createdAt),
      toolTrace: toolTrace,
    );
  }
}

final class _TrackedRecordingOutlineRun {
  _TrackedRecordingOutlineRun({
    required this.trackingTaskId,
    required this.recordingId,
    required this.localNoteId,
    required this.remoteNoteId,
    this.status = 'queued',
    this.publicTaskId,
    this.outputPartRevisionId,
    this.expectedPublicTaskId,
    this.supersededPublicTaskId,
    this.subjectTitle,
    DateTime? createdAt,
  }) : createdAt = (createdAt ?? DateTime.now()).toUtc();

  final String trackingTaskId;
  final String recordingId;
  final String localNoteId;
  final String remoteNoteId;
  String status;
  String? publicTaskId;
  String? outputPartRevisionId;
  String? expectedPublicTaskId;
  String? supersededPublicTaskId;
  String? subjectTitle;
  final DateTime createdAt;

  bool acceptsPublicTaskId(String? candidatePublicTaskId) {
    final expected = expectedPublicTaskId;
    if (expected != null) return candidatePublicTaskId == expected;
    final superseded = supersededPublicTaskId;
    if (superseded != null) {
      return candidatePublicTaskId != null &&
          candidatePublicTaskId != superseded;
    }
    return true;
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': 'recording_outline',
    'trackingTaskId': trackingTaskId,
    'recordingId': recordingId,
    'localNoteId': localNoteId,
    'remoteNoteId': remoteNoteId,
    'status': status,
    if (publicTaskId != null) 'publicTaskId': publicTaskId,
    if (outputPartRevisionId != null)
      'outputPartRevisionId': outputPartRevisionId,
    if (expectedPublicTaskId != null)
      'expectedPublicTaskId': expectedPublicTaskId,
    if (supersededPublicTaskId != null)
      'supersededPublicTaskId': supersededPublicTaskId,
    if (subjectTitle != null) 'subjectTitle': subjectTitle,
    'createdAt': createdAt.toIso8601String(),
  };

  static _TrackedRecordingOutlineRun? fromJson(Object? value) {
    if (value is! Map || value['kind'] != 'recording_outline') return null;
    final trackingTaskId = value['trackingTaskId'];
    final recordingId = value['recordingId'];
    final localNoteId = value['localNoteId'];
    final remoteNoteId = value['remoteNoteId'];
    final status = value['status'];
    final publicTaskId = value['publicTaskId'];
    final outputPartRevisionId = value['outputPartRevisionId'];
    final rawExpectedPublicTaskId = value['expectedPublicTaskId'];
    final expectedPublicTaskId = rawExpectedPublicTaskId is String
        ? _safeOptionalTaskIdentifier(rawExpectedPublicTaskId)
        : null;
    final rawSupersededPublicTaskId = value['supersededPublicTaskId'];
    final supersededPublicTaskId = rawSupersededPublicTaskId is String
        ? _safeOptionalTaskIdentifier(rawSupersededPublicTaskId)
        : null;
    final subjectTitle = _safeTaskSubjectTitle(value['subjectTitle']);
    final createdAt = _safeTraceDate(value['createdAt']);
    if (trackingTaskId is! String ||
        recordingId is! String ||
        localNoteId is! String ||
        remoteNoteId is! String ||
        status is! String ||
        createdAt == null ||
        !_isSafeTaskIdentifier(trackingTaskId) ||
        !_isSafeTaskIdentifier(recordingId) ||
        !_isSafeTaskIdentifier(localNoteId) ||
        !_isSafeTaskIdentifier(remoteNoteId) ||
        _safeDerivedTaskStatus(status) == null ||
        (publicTaskId != null &&
            (publicTaskId is! String ||
                !_isSafeTaskIdentifier(publicTaskId))) ||
        (outputPartRevisionId != null &&
            (outputPartRevisionId is! String ||
                !_isSafeTaskIdentifier(outputPartRevisionId))) ||
        (rawExpectedPublicTaskId != null && expectedPublicTaskId == null) ||
        (rawSupersededPublicTaskId != null && supersededPublicTaskId == null) ||
        (expectedPublicTaskId != null &&
            expectedPublicTaskId == supersededPublicTaskId) ||
        (expectedPublicTaskId != null &&
            publicTaskId != null &&
            expectedPublicTaskId != publicTaskId) ||
        (supersededPublicTaskId != null && publicTaskId != null)) {
      return null;
    }
    return _TrackedRecordingOutlineRun(
      trackingTaskId: trackingTaskId,
      recordingId: recordingId,
      localNoteId: localNoteId,
      remoteNoteId: remoteNoteId,
      status: _safeDerivedTaskStatus(status)!,
      publicTaskId: publicTaskId as String?,
      outputPartRevisionId: outputPartRevisionId as String?,
      expectedPublicTaskId: expectedPublicTaskId,
      supersededPublicTaskId: supersededPublicTaskId,
      subjectTitle: subjectTitle,
      createdAt: createdAt,
    );
  }
}

String _recordingOutlineTrackingTaskId(String recordingId) {
  final digest = sha256.convert(utf8.encode(recordingId)).toString();
  return 'recording-outline:${digest.substring(0, 24)}';
}

String _recordingOutlinePublicStatus(RecordingDetail detail) {
  final task = detail.noteOutlineTask;
  if (task?.status == RecordingNoteOutlineTaskStatus.queued) return 'queued';
  if (task?.status == RecordingNoteOutlineTaskStatus.running) return 'running';
  if (task?.status == RecordingNoteOutlineTaskStatus.succeeded) {
    final revision = detail.noteRef?.outlinePartRevisionId?.trim();
    return revision != null && revision.isNotEmpty ? 'succeeded' : 'running';
  }
  if (task?.status == RecordingNoteOutlineTaskStatus.timeout) return 'timeout';
  if (task?.status == RecordingNoteOutlineTaskStatus.cancelled ||
      task?.status == RecordingNoteOutlineTaskStatus.ignored) {
    return 'cancelled';
  }
  if (task?.status == RecordingNoteOutlineTaskStatus.failed ||
      task?.status == RecordingNoteOutlineTaskStatus.deadLetter ||
      detail.hasOutlineFailure) {
    return 'failed';
  }
  return 'running';
}

String? _recordingOutlineFailureCode(RecordingDetail detail) {
  return detail.outlineFailureCode;
}

NoteFileAgentPart? _noteFileAgentPartFromWire(Object? value) => switch (value) {
  'raw' => NoteFileAgentPart.raw,
  'outline' => NoteFileAgentPart.outline,
  'germination' => NoteFileAgentPart.germination,
  _ => null,
};

bool _isSafeTaskIdentifier(String value) =>
    RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,159}$').hasMatch(value.trim());

String? _safeOptionalTaskIdentifier(String? value) {
  final normalized = value?.trim();
  if (normalized == null ||
      normalized.isEmpty ||
      !_isSafeTaskIdentifier(normalized)) {
    return null;
  }
  return normalized;
}

String? _safeTaskSubjectTitle(Object? value) {
  if (value is! String) return null;
  final normalized = value
      .replaceAll(RegExp(r'[\x00-\x1F\x7F]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (normalized.isEmpty) return null;
  return String.fromCharCodes(normalized.runes.take(160));
}

bool _rememberBoundedSubject(
  Map<String, String> subjects,
  String identity,
  String title,
) {
  if (subjects[identity] == title) return false;
  subjects.remove(identity);
  subjects[identity] = title;
  const maximum = 240;
  while (subjects.length > maximum) {
    subjects.remove(subjects.keys.first);
  }
  return true;
}

bool _restoreSubjectIndex(
  Object? value,
  Map<String, String> subjects,
  bool Function(String value) acceptsIdentity,
) {
  if (value is! Map || value.length > 240) return false;
  var changed = false;
  for (final entry in value.entries) {
    final identity = entry.key;
    final title = _safeTaskSubjectTitle(entry.value);
    if (identity is! String || !acceptsIdentity(identity) || title == null) {
      continue;
    }
    if (subjects.containsKey(identity)) continue;
    subjects[identity] = title;
    changed = true;
  }
  return changed;
}

String? _safeOptionalAgentRunId(String? value) {
  final normalized = value?.trim();
  if (normalized == null || normalized.isEmpty) return null;
  return isSafeAgentRunIdentifier(normalized) ? normalized : null;
}

List<Map<String, Object?>> _toolTraceToJson(List<AgentRunToolTrace> traces) =>
    <Map<String, Object?>>[
      for (final trace in traces)
        if (_isSafePublicToolTrace(trace))
          <String, Object?>{
            'invocationId': trace.invocationId,
            'toolName': trace.toolName,
            'state': trace.state,
            if (trace.outcome != null) 'outcome': trace.outcome,
            'createdAt': trace.createdAt.toUtc().toIso8601String(),
            if (trace.completedAt != null)
              'completedAt': trace.completedAt!.toUtc().toIso8601String(),
            'outputFiles': <Map<String, Object?>>[
              for (final file in trace.outputFiles)
                if (_isSafePublicOutputFile(file))
                  <String, Object?>{
                    'resourceId': file.resourceId,
                    'fileName': file.fileName,
                    'mimeType': file.mimeType,
                    'sizeBytes': file.sizeBytes,
                  },
            ],
          },
    ];

List<AgentRunToolTrace>? _toolTraceFromJson(Object? value) {
  if (value == null) return const <AgentRunToolTrace>[];
  if (value is! List || value.length > 80) return null;
  final traces = <AgentRunToolTrace>[];
  for (final raw in value) {
    if (raw is! Map) return null;
    final object = Map<String, Object?>.from(raw);
    final invocationId = _safeTraceIdentifier(object['invocationId']);
    final toolName = _safeToolName(object['toolName']);
    final state = _safeToolState(object['state']);
    final outcome = _safeToolOutcome(object['outcome']);
    final createdAt = _safeTraceDate(object['createdAt']);
    final completedAt = object['completedAt'] == null
        ? null
        : _safeTraceDate(object['completedAt']);
    final outputFiles = _outputFilesFromJson(object['outputFiles']);
    if (invocationId == null ||
        toolName == null ||
        state == null ||
        (object['outcome'] != null && outcome == null) ||
        createdAt == null ||
        (object['completedAt'] != null && completedAt == null) ||
        outputFiles == null) {
      return null;
    }
    traces.add(
      AgentRunToolTrace(
        invocationId: invocationId,
        toolName: toolName,
        state: state,
        outcome: outcome,
        createdAt: createdAt,
        completedAt: completedAt,
        outputFiles: outputFiles,
      ),
    );
  }
  return List<AgentRunToolTrace>.unmodifiable(traces);
}

List<AgentRunOutputFile>? _outputFilesFromJson(Object? value) {
  if (value is! List || value.length > 20) return null;
  final files = <AgentRunOutputFile>[];
  for (final raw in value) {
    if (raw is! Map) return null;
    final object = Map<String, Object?>.from(raw);
    final resourceId = _safeTraceIdentifier(object['resourceId']);
    final fileName = _safeDisplayLabel(object['fileName'], maximum: 160);
    final mimeType = _safeMimeType(object['mimeType']);
    final sizeBytes = object['sizeBytes'];
    if (resourceId == null ||
        fileName == null ||
        mimeType == null ||
        sizeBytes is! num ||
        sizeBytes < 0 ||
        sizeBytes > 1024 * 1024 * 1024) {
      return null;
    }
    files.add(
      AgentRunOutputFile(
        resourceId: resourceId,
        fileName: fileName,
        mimeType: mimeType,
        sizeBytes: sizeBytes.toInt(),
      ),
    );
  }
  return List<AgentRunOutputFile>.unmodifiable(files);
}

bool _isSafePublicToolTrace(AgentRunToolTrace trace) =>
    _safeTraceIdentifier(trace.invocationId) != null &&
    _safeToolName(trace.toolName) != null &&
    _safeToolState(trace.state) != null &&
    (trace.outcome == null || _safeToolOutcome(trace.outcome) != null) &&
    trace.outputFiles.every(_isSafePublicOutputFile);

bool _isSafePublicOutputFile(AgentRunOutputFile file) =>
    _safeTraceIdentifier(file.resourceId) != null &&
    _safeDisplayLabel(file.fileName, maximum: 160) != null &&
    _safeMimeType(file.mimeType) != null &&
    file.sizeBytes >= 0 &&
    file.sizeBytes <= 1024 * 1024 * 1024;

String? _safeTraceIdentifier(Object? value) {
  final text = value is String ? value.trim() : null;
  return text != null &&
          RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,159}$').hasMatch(text)
      ? text
      : null;
}

String? _safeDisplayLabel(Object? value, {required int maximum}) {
  final text = value is String ? value.trim() : null;
  if (text == null || text.isEmpty || text.length > maximum) return null;
  return RegExp(r'[\x00-\x1F\x7F]').hasMatch(text) ? null : text;
}

DateTime? _safeTraceDate(Object? value) {
  final text = value is String ? value.trim() : null;
  if (text == null || text.length > 64) return null;
  return DateTime.tryParse(text)?.toUtc();
}

String? _safeMimeType(Object? value) {
  final text = value is String ? value.trim().toLowerCase() : null;
  return text != null && RegExp(r'^[a-z0-9.+-]+/[a-z0-9.+-]+$').hasMatch(text)
      ? text
      : null;
}

String? _safeToolName(Object? value) {
  final text = value is String ? value.trim() : null;
  return const <String>{
        'read',
        'workspace_list',
        'workspace_search',
        'write',
        'image_analysis',
        'image_generation',
        'video_analysis',
        'huahuo_hotspot_query',
      }.contains(text)
      ? text
      : null;
}

String? _safeToolState(Object? value) {
  final text = value is String ? value.trim() : null;
  return const <String>{'started', 'finished', 'rejected'}.contains(text)
      ? text
      : null;
}

String? _safeToolOutcome(Object? value) {
  final text = value is String ? value.trim() : null;
  return const <String>{'succeeded', 'failed'}.contains(text) ? text : null;
}

bool _sameToolTrace(
  List<AgentRunToolTrace> left,
  List<AgentRunToolTrace> right,
) {
  if (identical(left, right)) return true;
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index += 1) {
    final a = left[index];
    final b = right[index];
    if (a.invocationId != b.invocationId ||
        a.toolName != b.toolName ||
        a.state != b.state ||
        a.outcome != b.outcome ||
        a.completedAt != b.completedAt ||
        a.outputFiles.length != b.outputFiles.length) {
      return false;
    }
  }
  return true;
}

String _mergePolledChatRunStatus({
  required String current,
  required String candidate,
  required bool hasStreamAuthority,
}) {
  if (_isTerminalTaskStatus(current)) return current;
  if (_isTerminalTaskStatus(candidate) || !hasStreamAuthority) return candidate;
  return _chatRunStatusRank(candidate) < _chatRunStatusRank(current)
      ? current
      : candidate;
}

String _mergeStreamChatRunStatus({
  required String current,
  required String candidate,
  required bool hasPriorStreamEvent,
}) {
  if (_isTerminalTaskStatus(current)) return current;
  if (_isTerminalTaskStatus(candidate) || !hasPriorStreamEvent) {
    return candidate;
  }
  return _chatRunStatusRank(candidate) < _chatRunStatusRank(current)
      ? current
      : candidate;
}

int _chatRunStatusRank(String status) => switch (status) {
  'admitting' => 0,
  'resolving' => 1,
  'planning' => 2,
  'awaiting_confirmation' => 3,
  'queued' => 4,
  'running' => 5,
  'finalizing' => 6,
  'aborting' => 7,
  'succeeded' ||
  'failed' ||
  'timeout' ||
  'cancelled' ||
  'conflict' ||
  'orphaned' => 8,
  _ => -1,
};

List<AgentRunToolTrace> _mergeMonotonicToolTrace(
  List<AgentRunToolTrace> current,
  List<AgentRunToolTrace> candidate,
) {
  if (candidate.isEmpty) return current;
  final merged = List<AgentRunToolTrace>.of(current);
  for (final next in candidate) {
    final index = merged.indexWhere(
      (trace) => trace.invocationId == next.invocationId,
    );
    if (index < 0) {
      merged.add(next);
      continue;
    }
    final existing = merged[index];
    if (existing.toolName != next.toolName) continue;
    final existingRank = _toolTraceStateRank(existing.state);
    final nextRank = _toolTraceStateRank(next.state);
    if (nextRank < existingRank ||
        (nextRank == existingRank && next.state != existing.state)) {
      continue;
    }
    if (nextRank > existingRank) {
      merged[index] = _mergeToolTraceFacts(
        existing: existing,
        supplement: next,
        lifecycle: next,
      );
      continue;
    }
    merged[index] = _mergeToolTraceFacts(
      existing: existing,
      supplement: next,
      lifecycle: existing,
    );
  }
  return List<AgentRunToolTrace>.unmodifiable(merged);
}

AgentRunToolTrace _mergeToolTraceFacts({
  required AgentRunToolTrace existing,
  required AgentRunToolTrace supplement,
  required AgentRunToolTrace lifecycle,
}) {
  final outputFilesById = <String, AgentRunOutputFile>{
    for (final output in existing.outputFiles) output.resourceId: output,
  };
  for (final output in supplement.outputFiles) {
    outputFilesById.putIfAbsent(output.resourceId, () => output);
  }
  final inputSummary = <String, Object?>{...existing.inputSummary};
  for (final entry in supplement.inputSummary.entries) {
    inputSummary.putIfAbsent(entry.key, () => entry.value);
  }
  final lifecycleIsExisting = identical(lifecycle, existing);
  return AgentRunToolTrace(
    invocationId: existing.invocationId,
    toolName: existing.toolName,
    state: lifecycle.state,
    outcome:
        lifecycle.outcome ??
        (lifecycleIsExisting ? supplement.outcome : existing.outcome),
    createdAt: existing.createdAt,
    completedAt:
        lifecycle.completedAt ??
        (lifecycleIsExisting ? supplement.completedAt : existing.completedAt),
    outputFiles: List<AgentRunOutputFile>.unmodifiable(outputFilesById.values),
    inputSummary: Map<String, Object?>.unmodifiable(inputSummary),
  );
}

int _toolTraceStateRank(String state) => switch (state) {
  'started' => 0,
  'finished' || 'rejected' => 1,
  _ => -1,
};

String _assistantStatusValue(AssistantRunStatus status) => switch (status) {
  AssistantRunStatus.resolving => 'resolving',
  AssistantRunStatus.planning => 'planning',
  AssistantRunStatus.waitingForInput => 'awaiting_confirmation',
  AssistantRunStatus.queued => 'queued',
  AssistantRunStatus.running => 'running',
  AssistantRunStatus.stopping => 'aborting',
  AssistantRunStatus.succeeded => 'succeeded',
  AssistantRunStatus.failed => 'failed',
  AssistantRunStatus.timedOut => 'timeout',
  AssistantRunStatus.cancelled => 'cancelled',
  AssistantRunStatus.orphaned => 'orphaned',
  AssistantRunStatus.unknown => 'unknown',
};

bool _isTerminalTaskStatus(String status) => const <String>{
  'succeeded',
  'failed',
  'timeout',
  'cancelled',
  'conflict',
  'orphaned',
}.contains(status);

String? _provisionalTerminalFailureCode(String status) => switch (status) {
  'failed' => 'CHAT_AGENT_RUN_FAILED',
  'timeout' => 'CHAT_AGENT_RUN_TIMEOUT',
  'cancelled' => 'CHAT_AGENT_RUN_CANCELLED',
  'orphaned' => 'CHAT_AGENT_RUN_ORPHANED',
  'conflict' => 'CHAT_AGENT_RUN_RESULT_INVALID',
  _ => null,
};

String? _agentRunFailureCode(AssistantRunSnapshot run) {
  final status = _assistantStatusValue(run.status);
  if (status == 'failed') {
    final code = run.failure?.code.trim();
    return code != null && _isSafeTaskIdentifier(code) ? code : null;
  }
  return switch (status) {
    'timeout' => 'CHAT_AGENT_RUN_TIMEOUT',
    'cancelled' => 'CHAT_AGENT_RUN_CANCELLED',
    'orphaned' => 'CHAT_AGENT_RUN_ORPHANED',
    _ => null,
  };
}

String? _assistantCompletionModeValue(AssistantCompletionQuality quality) =>
    switch (quality) {
      AssistantCompletionQuality.normal => 'normal',
      AssistantCompletionQuality.degraded => 'degraded',
      AssistantCompletionQuality.fallback => 'system_fallback',
      AssistantCompletionQuality.cancelled => 'cancelled',
      AssistantCompletionQuality.unknown => null,
    };

AssistantRuntimeRead<_TrackerRunRead> _wrapAssistantRead(
  AssistantRuntimeRead<AssistantRunSnapshot> result,
) {
  final snapshot = result.data;
  if (!result.ok || snapshot == null) {
    return AssistantRuntimeRead<_TrackerRunRead>.failure(
      result.errorCode ?? 'ASSISTANT_RUN_READ_FAILED',
      outcomeUnknown: result.outcomeUnknown,
    );
  }
  return AssistantRuntimeRead.success(
    _TrackerRunRead(snapshot, _assistantToolTraceToLegacy(snapshot.toolTrace)),
  );
}

List<AgentRunToolTrace> _assistantToolTraceToLegacy(
  Iterable<AssistantToolTrace> traces,
) => traces
    .map(
      (trace) => AgentRunToolTrace(
        invocationId: trace.invocationId,
        toolName: trace.toolName,
        state: trace.state,
        outcome: trace.outcome,
        createdAt: trace.createdAt,
        completedAt: trace.completedAt,
        outputFiles: trace.outputFiles
            .map(
              (file) => AgentRunOutputFile(
                resourceId: file.resourceId,
                fileName: file.fileName,
                mimeType: file.mimeType,
                sizeBytes: file.sizeBytes,
              ),
            )
            .toList(growable: false),
        inputSummary: trace.inputSummary,
      ),
    )
    .toList(growable: false);

const Set<String> _publicChatRunCompletionModes = <String>{
  'normal',
  'degraded',
  'system_fallback',
  'cancelled',
};

Map<String, Object?> _chatRunCompletionToJson(ChatRunCompletion completion) =>
    <String, Object?>{
      'agentRunId': completion.agentRunId,
      'threadId': completion.threadId,
      'scene': completion.scene.apiValue,
      'purpose': completion.purpose.apiValue,
      'status': completion.status,
      if (completion.completionMode != null)
        'completionMode': completion.completionMode,
      if (completion.assistantMessageId != null)
        'assistantMessageId': completion.assistantMessageId,
      if (completion.failureCode != null) 'failureCode': completion.failureCode,
      if (completion.completedAt != null)
        'completedAt': completion.completedAt!.toUtc().toIso8601String(),
    };

ChatRunCompletion? _chatRunCompletionFromLedgerState(
  Object? value,
  AgentTaskLedgerEntry entry,
) {
  if (entry.kind != 'chat' || value is! Map) return null;
  final raw = value['completion'];
  if (raw is! Map || raw.keys.any((key) => key is! String)) return null;
  final item = Map<String, Object?>.from(raw);
  if (item.keys.any(
    (key) => !const <String>{
      'agentRunId',
      'threadId',
      'scene',
      'purpose',
      'status',
      'completionMode',
      'assistantMessageId',
      'failureCode',
      'completedAt',
    }.contains(key),
  )) {
    return null;
  }
  final agentRunId = item['agentRunId'];
  final threadId = item['threadId'];
  final scene = ChatScene.tryParse(item['scene']);
  final purpose = ChatConversationPurpose.tryParseApi(item['purpose']);
  final status = item['status'];
  final completionMode = item['completionMode'];
  final assistantMessageId = item['assistantMessageId'];
  final failureCode = item['failureCode'];
  final completedAt = _safeTraceDate(item['completedAt']);
  if (agentRunId is! String ||
      threadId is! String ||
      scene == null ||
      purpose == null ||
      status is! String ||
      completedAt == null ||
      agentRunId != entry.taskId ||
      threadId != entry.threadId ||
      scene != entry.scene ||
      purpose != entry.purpose ||
      status != entry.status ||
      !isSafeAgentRunIdentifier(agentRunId) ||
      !isSafeChatIdentifier(threadId) ||
      !_isTerminalTaskStatus(status) ||
      (completionMode != null &&
          (completionMode is! String ||
              !_publicChatRunCompletionModes.contains(completionMode))) ||
      (assistantMessageId != null &&
          (assistantMessageId is! String ||
              !isSafeChatIdentifier(assistantMessageId))) ||
      (failureCode != null &&
          (failureCode is! String || !_isSafeTaskIdentifier(failureCode))) ||
      (status == 'succeeded' &&
          (completionMode == null || assistantMessageId == null))) {
    return null;
  }
  return ChatRunCompletion(
    agentRunId: agentRunId,
    threadId: threadId,
    scene: scene,
    purpose: purpose,
    status: status,
    completionMode: completionMode as String?,
    assistantMessageId: assistantMessageId as String?,
    failureCode: failureCode as String?,
    completedAt: completedAt,
  );
}

Map<String, Object?> _taskLedgerEntryToJson(AgentTaskLedgerEntry entry) =>
    <String, Object?>{
      'kind': entry.kind,
      'taskId': entry.taskId,
      if (entry.publicTaskId != null) 'publicTaskId': entry.publicTaskId,
      if (entry.agentRunId != null) 'agentRunId': entry.agentRunId,
      'status': entry.status,
      'createdAt': entry.createdAt.toUtc().toIso8601String(),
      if (entry.threadId != null) 'threadId': entry.threadId,
      if (entry.scene != null) 'scene': entry.scene!.apiValue,
      if (entry.purpose != null) 'purpose': entry.purpose!.apiValue,
      if (entry.localNoteId != null) 'localNoteId': entry.localNoteId,
      if (entry.remoteNoteId != null) 'remoteNoteId': entry.remoteNoteId,
      if (entry.recordingId != null) 'recordingId': entry.recordingId,
      if (entry.targetPart != null) 'targetPart': entry.targetPart!.wireName,
      if (entry.failureCode != null) 'failureCode': entry.failureCode,
      if (entry.outputPartRevisionId != null)
        'outputPartRevisionId': entry.outputPartRevisionId,
      if (entry.subjectTitle != null) 'subjectTitle': entry.subjectTitle,
      if (entry.inputPartRevisionId != null)
        'inputPartRevisionId': entry.inputPartRevisionId,
      if (entry.targetPartRevisionId != null)
        'targetPartRevisionId': entry.targetPartRevisionId,
      if (entry.operationId != null) 'operationId': entry.operationId,
    };

AgentTaskLedgerEntry? _taskLedgerEntryFromJson(Object? value) {
  if (value is! Map) return null;
  final item = Map<String, Object?>.from(value);
  final kind = item['kind'];
  final taskId = item['taskId'];
  final status = item['status'];
  final createdAt = _safeTraceDate(item['createdAt']);
  final failureCode = item['failureCode'];
  final publicTaskId = item['publicTaskId'];
  final agentRunId = item['agentRunId'];
  final outputPartRevisionId = item['outputPartRevisionId'];
  final remoteNoteId = item['remoteNoteId'];
  final recordingId = item['recordingId'];
  final subjectTitle = _safeTaskSubjectTitle(item['subjectTitle']);
  final inputPartRevisionId = item['inputPartRevisionId'];
  final targetPartRevisionId = item['targetPartRevisionId'];
  final operationId = item['operationId'];
  final rawPurpose = item['purpose'];
  final purpose = rawPurpose == null
      ? ChatConversationPurpose.general
      : ChatConversationPurpose.tryParseApi(rawPurpose);
  if (kind is! String ||
      taskId is! String ||
      status is! String ||
      createdAt == null ||
      purpose == null ||
      !_isSafeTaskIdentifier(taskId) ||
      !_isTerminalTaskStatus(status) ||
      (publicTaskId != null &&
          (publicTaskId is! String || !_isSafeTaskIdentifier(publicTaskId))) ||
      (agentRunId != null &&
          (agentRunId is! String || !isSafeAgentRunIdentifier(agentRunId))) ||
      (outputPartRevisionId != null &&
          (outputPartRevisionId is! String ||
              !_isSafeTaskIdentifier(outputPartRevisionId))) ||
      (remoteNoteId != null &&
          (remoteNoteId is! String || !_isSafeTaskIdentifier(remoteNoteId))) ||
      (recordingId != null &&
          (recordingId is! String || !_isSafeTaskIdentifier(recordingId))) ||
      (inputPartRevisionId != null &&
          (inputPartRevisionId is! String ||
              !_isSafeTaskIdentifier(inputPartRevisionId))) ||
      (targetPartRevisionId != null &&
          (targetPartRevisionId is! String ||
              !_isSafeTaskIdentifier(targetPartRevisionId))) ||
      (operationId != null &&
          (operationId is! String || !_isSafeTaskIdentifier(operationId))) ||
      (failureCode != null &&
          (failureCode is! String || !_isSafeTaskIdentifier(failureCode)))) {
    return null;
  }
  if (kind == 'chat') {
    final threadId = item['threadId'];
    final scene = ChatScene.tryParse(item['scene']);
    if (threadId is! String ||
        !isSafeChatIdentifier(threadId) ||
        scene == null) {
      return null;
    }
    return AgentTaskLedgerEntry.chat(
      taskId: taskId,
      publicTaskId: publicTaskId as String?,
      threadId: threadId,
      scene: scene,
      purpose: purpose,
      status: status,
      createdAt: createdAt,
      failureCode: failureCode as String?,
      subjectTitle: subjectTitle,
    );
  }
  if (kind == 'derived_part') {
    final localNoteId = item['localNoteId'];
    final targetPart = _noteFileAgentPartFromWire(item['targetPart']);
    if (localNoteId is! String ||
        !_isSafeTaskIdentifier(localNoteId) ||
        targetPart == null) {
      return null;
    }
    return AgentTaskLedgerEntry.derivedPart(
      taskId: taskId,
      agentRunId: agentRunId as String?,
      localNoteId: localNoteId,
      remoteNoteId: remoteNoteId as String?,
      targetPart: targetPart,
      status: status,
      createdAt: createdAt,
      failureCode: failureCode as String?,
      outputPartRevisionId: outputPartRevisionId as String?,
      subjectTitle: subjectTitle,
      inputPartRevisionId: inputPartRevisionId as String?,
      targetPartRevisionId: targetPartRevisionId as String?,
      operationId: operationId as String?,
    );
  }
  if (kind == 'recording_outline') {
    final localNoteId = item['localNoteId'];
    final targetPart = _noteFileAgentPartFromWire(item['targetPart']);
    if (recordingId is! String ||
        localNoteId is! String ||
        remoteNoteId is! String ||
        !_isSafeTaskIdentifier(recordingId) ||
        !_isSafeTaskIdentifier(localNoteId) ||
        !_isSafeTaskIdentifier(remoteNoteId) ||
        targetPart != NoteFileAgentPart.outline) {
      return null;
    }
    return AgentTaskLedgerEntry.recordingOutline(
      taskId: taskId,
      publicTaskId: publicTaskId as String?,
      recordingId: recordingId,
      localNoteId: localNoteId,
      remoteNoteId: remoteNoteId,
      status: status,
      createdAt: createdAt,
      failureCode: failureCode as String?,
      outputPartRevisionId: outputPartRevisionId as String?,
      subjectTitle: subjectTitle,
    );
  }
  return null;
}

final Random _chatRunRetryRandom = Random();

double _defaultRandomDouble() => _chatRunRetryRandom.nextDouble();
