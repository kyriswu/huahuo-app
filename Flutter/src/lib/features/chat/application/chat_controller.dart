import 'dart:async';
import 'dart:convert';

import 'package:huahuo_api/huahuo_api.dart';
import 'package:flutter/foundation.dart';

import '../../../core/api/scoped_read_cache.dart';
import 'chat_controller_policies.dart';
import 'chat_controller_state.dart';
import 'chat_assistant_run_reader.dart';
import 'chat_runtime_invocation_mapper.dart';
import 'chat_stream_reveal_buffer.dart';
import 'chat_thread_progress_poller.dart';
import 'chat_run_tracker.dart';
import 'chat_turn_state_machine.dart';
import '../domain/assistant_runtime.dart';
import '../domain/chat_repository.dart';
import '../data/chat_thread_alias_repository.dart';
import '../domain/chat_context.dart';
import '../domain/chat_models.dart';

export 'chat_controller_state.dart';
export 'chat_turn_state_machine.dart';

bool _workspaceAlwaysReady() => true;

typedef ChatUserVisibleTextProjector = String Function(String transportText);
typedef ChatBeforeTextMessageSubmit = Future<bool> Function(String threadId);
typedef ChatTextMessageKnownRejected = Future<void> Function();

enum _AgentProgressTransport { agentRunSse, threadEvents }

typedef _AgentProgressBatchReader =
    Future<ChatThreadProgressBatch?> Function({
      required String threadId,
      required String runHandle,
      required int afterSequence,
    });

final class _ControllerRunProjection {
  const _ControllerRunProjection({
    required this.agentRunId,
    required this.status,
    required this.isTerminal,
    required this.updatedAt,
    required this.assistantToolTrace,
    this.threadId,
    this.assistantMessageId,
    this.terminalFailureCode,
  });

  final String agentRunId;
  final String? threadId;
  final String status;
  final bool isTerminal;
  final String? assistantMessageId;
  final String? terminalFailureCode;
  final DateTime updatedAt;
  final List<AssistantToolTrace> assistantToolTrace;
}

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

enum ChatAssistantAnswerDraftSource { transportDelta, localReveal }

@immutable
final class ChatAssistantAnswerDraft {
  const ChatAssistantAnswerDraft({
    required this.visibleText,
    required this.targetText,
    required this.source,
  });

  /// The locally paced prefix suitable for painting in the message row.
  final String visibleText;

  /// The latest complete app-safe answer text received from transport.
  final String targetText;

  final ChatAssistantAnswerDraftSource source;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ChatAssistantAnswerDraft &&
          visibleText == other.visibleText &&
          targetText == other.targetText &&
          source == other.source;

  @override
  int get hashCode => Object.hash(visibleText, targetText, source);
}

@immutable
final class ChatRuntimeInvocationHistorySnapshot {
  const ChatRuntimeInvocationHistorySnapshot({
    required this.items,
    required this.isSettled,
    this.isTruncated = false,
    this.errorCode,
  });

  final List<SharedThreadRuntimeInvocation> items;
  final bool isSettled;
  final bool isTruncated;
  final String? errorCode;
}

@immutable
final class _ValidatedTextSubmission {
  const _ValidatedTextSubmission({
    required this.messageId,
    required this.content,
    required this.pendingContent,
    required this.contentLineId,
    required this.context,
    required this.imageAttachments,
    required this.resourceAttachments,
    required this.assetReferences,
    required this.conversationAssetId,
    required this.agentProfileId,
    required this.createThreadIdempotency,
    required this.messageIdempotencyKey,
    required this.beforeMessageSubmit,
    required this.onMessageKnownRejected,
    this.threadId,
    this.sendIdempotency,
  });

  final String messageId;
  final String content;
  final String pendingContent;
  final String? contentLineId;
  final ChatContextEnvelope context;
  final List<ChatImageAttachment> imageAttachments;
  final List<ChatResourceAttachment> resourceAttachments;
  final List<ChatAssetReference> assetReferences;
  final String? conversationAssetId;
  final String? agentProfileId;
  final IdempotencyRequestContext createThreadIdempotency;
  final String? messageIdempotencyKey;
  final ChatBeforeTextMessageSubmit? beforeMessageSubmit;
  final ChatTextMessageKnownRejected? onMessageKnownRejected;
  final String? threadId;
  final IdempotencyRequestContext? sendIdempotency;

  _ValidatedTextSubmission bindToThread(
    String threadId,
    IdempotencyRequestContext sendIdempotency,
  ) {
    return _ValidatedTextSubmission(
      messageId: messageId,
      content: content,
      pendingContent: pendingContent,
      contentLineId: contentLineId,
      context: context,
      imageAttachments: imageAttachments,
      resourceAttachments: resourceAttachments,
      assetReferences: assetReferences,
      conversationAssetId: conversationAssetId,
      agentProfileId: agentProfileId,
      createThreadIdempotency: createThreadIdempotency,
      messageIdempotencyKey: messageIdempotencyKey,
      beforeMessageSubmit: beforeMessageSubmit,
      onMessageKnownRejected: onMessageKnownRejected,
      threadId: threadId,
      sendIdempotency: sendIdempotency,
    );
  }
}

enum ChatFirstConversationAdmissionPhase { pending, accepted, failed }

/// App-safe lifecycle metadata for one account-owned first conversation turn.
@immutable
final class ChatFirstConversationAdmissionSnapshot {
  const ChatFirstConversationAdmissionSnapshot({
    required this.phase,
    required this.conversationAssetId,
    this.threadId,
    this.errorCode,
  });

  final ChatFirstConversationAdmissionPhase phase;
  final String conversationAssetId;
  final String? threadId;
  final String? errorCode;
}

/// Coordinates account-owned conversation admission beyond route lifetimes.
final class ChatConversationAdmissionCoordinator {
  ChatConversationAdmissionCoordinator({required String userScope})
    : _userScope = userScope.trim().isEmpty ? 'anonymous' : userScope.trim();

  static const _retainedFailureLimit = 20;

  final String _userScope;
  final Map<_FirstConversationAdmissionKey, _FirstConversationAdmissionEntry>
  _entries =
      <_FirstConversationAdmissionKey, _FirstConversationAdmissionEntry>{};
  final Map<_ThreadTurnAdmissionKey, Object> _threadTurnAdmissions =
      <_ThreadTurnAdmissionKey, Object>{};

  ChatFirstConversationAdmissionSnapshot? snapshotFor({
    required ChatScene scene,
    required ChatConversationPurpose purpose,
    required String conversationAssetId,
  }) {
    if (!isSafeChatIdentifier(conversationAssetId)) return null;
    return _entries[_key(scene, purpose, conversationAssetId)]?.snapshot;
  }

  _FirstConversationAdmissionEntry? _entryFor({
    required ChatScene scene,
    required ChatConversationPurpose purpose,
    required String conversationAssetId,
  }) => _entries[_key(scene, purpose, conversationAssetId)];

  _FirstConversationAdmissionClaim _claim({
    required ChatScene scene,
    required ChatConversationPurpose purpose,
    required String conversationAssetId,
    required String fingerprint,
    required _ValidatedTextSubmission submission,
    required ChatMessage pending,
    required bool preserveMessageId,
    required Future<_FirstConversationAdmissionResult> Function() operation,
  }) {
    final key = _key(scene, purpose, conversationAssetId);
    final existing = _entries[key];
    if (existing != null) {
      return _FirstConversationAdmissionClaim(
        entry: existing,
        disposition: existing.fingerprint == fingerprint
            ? _FirstConversationAdmissionDisposition.joined
            : _FirstConversationAdmissionDisposition.conflict,
      );
    }
    final entry = _FirstConversationAdmissionEntry(
      key: key,
      fingerprint: fingerprint,
      submission: submission,
      pending: pending,
      preserveMessageId: preserveMessageId,
    );
    _entries[key] = entry;
    unawaited(_run(entry, operation));
    return _FirstConversationAdmissionClaim(
      entry: entry,
      disposition: _FirstConversationAdmissionDisposition.owner,
    );
  }

  void _forgetFailed({
    required ChatScene scene,
    required ChatConversationPurpose purpose,
    required String conversationAssetId,
  }) {
    final key = _key(scene, purpose, conversationAssetId);
    final entry = _entries[key];
    if (entry?.result?.accepted == false) _entries.remove(key);
  }

  bool _canDiscardFailed({
    required ChatScene scene,
    required ChatConversationPurpose purpose,
    required String conversationAssetId,
  }) =>
      _entries[_key(scene, purpose, conversationAssetId)]?.result?.accepted ==
      false;

  bool _discardFailed({
    required ChatScene scene,
    required ChatConversationPurpose purpose,
    required String conversationAssetId,
  }) {
    final key = _key(scene, purpose, conversationAssetId);
    final entry = _entries[key];
    if (entry?.result?.accepted != false) return false;
    _entries.remove(key);
    return true;
  }

  Future<void> _run(
    _FirstConversationAdmissionEntry entry,
    Future<_FirstConversationAdmissionResult> Function() operation,
  ) async {
    late final _FirstConversationAdmissionResult result;
    try {
      result = await operation();
    } catch (_) {
      result = _FirstConversationAdmissionResult(
        accepted: false,
        preserveMessageId: entry.preserveMessageId,
        submission: entry.submission,
        pending: entry.pending,
        errorCode: 'CHAT_SEND_FAILED',
        idempotencyStore: SubmissionKeyStore.empty,
      );
    }
    entry.result = result;
    entry.completer.complete(result);
    if (result.accepted) {
      if (identical(_entries[entry.key], entry)) _entries.remove(entry.key);
      return;
    }
    _trimRetainedFailures();
  }

  void _trimRetainedFailures() {
    final failures = _entries.entries
        .where((entry) => entry.value.result?.accepted == false)
        .toList(growable: false);
    final removeCount = failures.length - _retainedFailureLimit;
    for (var index = 0; index < removeCount; index += 1) {
      _entries.remove(failures[index].key);
    }
  }

  _FirstConversationAdmissionKey _key(
    ChatScene scene,
    ChatConversationPurpose purpose,
    String conversationAssetId,
  ) => _FirstConversationAdmissionKey(
    userScope: _userScope,
    scene: scene,
    purpose: purpose,
    conversationAssetId: conversationAssetId,
  );

  _ThreadTurnAdmissionLease? _tryAcquireThreadTurn({
    required ChatScene scene,
    required ChatConversationPurpose purpose,
    required String threadId,
  }) {
    if (!isSafeChatIdentifier(threadId)) return null;
    final key = _ThreadTurnAdmissionKey(
      userScope: _userScope,
      scene: scene,
      purpose: purpose,
      threadId: threadId,
    );
    if (_threadTurnAdmissions.containsKey(key)) return null;
    final token = Object();
    _threadTurnAdmissions[key] = token;
    return _ThreadTurnAdmissionLease(key: key, token: token);
  }

  void _releaseThreadTurn(_ThreadTurnAdmissionLease lease) {
    if (identical(_threadTurnAdmissions[lease.key], lease.token)) {
      _threadTurnAdmissions.remove(lease.key);
    }
  }
}

@immutable
final class _FirstConversationAdmissionKey {
  const _FirstConversationAdmissionKey({
    required this.userScope,
    required this.scene,
    required this.purpose,
    required this.conversationAssetId,
  });

  final String userScope;
  final ChatScene scene;
  final ChatConversationPurpose purpose;
  final String conversationAssetId;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _FirstConversationAdmissionKey &&
          userScope == other.userScope &&
          scene == other.scene &&
          purpose == other.purpose &&
          conversationAssetId == other.conversationAssetId;

  @override
  int get hashCode =>
      Object.hash(userScope, scene, purpose, conversationAssetId);
}

@immutable
final class _ThreadTurnAdmissionKey {
  const _ThreadTurnAdmissionKey({
    required this.userScope,
    required this.scene,
    required this.purpose,
    required this.threadId,
  });

  final String userScope;
  final ChatScene scene;
  final ChatConversationPurpose purpose;
  final String threadId;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _ThreadTurnAdmissionKey &&
          userScope == other.userScope &&
          scene == other.scene &&
          purpose == other.purpose &&
          threadId == other.threadId;

  @override
  int get hashCode => Object.hash(userScope, scene, purpose, threadId);
}

final class _ThreadTurnAdmissionLease {
  const _ThreadTurnAdmissionLease({required this.key, required this.token});

  final _ThreadTurnAdmissionKey key;
  final Object token;
}

enum _FirstConversationAdmissionDisposition { owner, joined, conflict }

final class _FirstConversationAdmissionClaim {
  const _FirstConversationAdmissionClaim({
    required this.entry,
    required this.disposition,
  });

  final _FirstConversationAdmissionEntry entry;
  final _FirstConversationAdmissionDisposition disposition;
}

final class _FirstConversationAdmissionEntry {
  _FirstConversationAdmissionEntry({
    required this.key,
    required this.fingerprint,
    required this.submission,
    required this.pending,
    required this.preserveMessageId,
  });

  final _FirstConversationAdmissionKey key;
  final String fingerprint;
  final _ValidatedTextSubmission submission;
  final ChatMessage pending;
  final bool preserveMessageId;
  final Completer<_FirstConversationAdmissionResult> completer =
      Completer<_FirstConversationAdmissionResult>();
  _FirstConversationAdmissionResult? result;

  Future<_FirstConversationAdmissionResult> get future => completer.future;

  ChatFirstConversationAdmissionSnapshot get snapshot {
    final settled = result;
    return ChatFirstConversationAdmissionSnapshot(
      phase: settled == null
          ? ChatFirstConversationAdmissionPhase.pending
          : settled.accepted
          ? ChatFirstConversationAdmissionPhase.accepted
          : ChatFirstConversationAdmissionPhase.failed,
      conversationAssetId: key.conversationAssetId,
      threadId: settled?.thread?.threadId,
      errorCode: settled?.errorCode,
    );
  }
}

final class _FirstConversationAdmissionResult {
  const _FirstConversationAdmissionResult({
    required this.accepted,
    required this.preserveMessageId,
    required this.submission,
    required this.pending,
    required this.idempotencyStore,
    this.thread,
    this.mutation,
    this.errorCode,
    this.failedTurnIsAbandonable = false,
  });

  final bool accepted;
  final bool preserveMessageId;
  final _ValidatedTextSubmission submission;
  final ChatMessage pending;
  final SubmissionKeyStore idempotencyStore;
  final ChatThread? thread;
  final ChatTextMutation? mutation;
  final String? errorCode;
  final bool failedTurnIsAbandonable;
}

final class _FirstConversationAdmissionCapture {
  _FirstConversationAdmissionCapture({
    required this.submission,
    required this.pending,
    required this.preserveMessageId,
  });

  _ValidatedTextSubmission submission;
  ChatMessage pending;
  final bool preserveMessageId;
  ChatThread? thread;
  ChatTextMutation? mutation;
  String? errorCode;
  bool failedTurnIsAbandonable = false;

  _FirstConversationAdmissionResult result({
    required bool accepted,
    required SubmissionKeyStore idempotencyStore,
  }) => _FirstConversationAdmissionResult(
    accepted: accepted,
    preserveMessageId: preserveMessageId,
    submission: submission,
    pending: pending,
    thread: thread,
    mutation: mutation,
    errorCode: accepted ? null : errorCode ?? 'CHAT_SEND_FAILED',
    failedTurnIsAbandonable: !accepted && failedTurnIsAbandonable,
    idempotencyStore: idempotencyStore,
  );
}

final class ChatController extends ChangeNotifier {
  static const _agentProgressSsePreference = Duration(milliseconds: 800);
  static const _conversationCacheWriteDebounce = Duration(milliseconds: 600);
  static const _failedTextRetryLimit = 20;
  static const _historyFreshness = Duration(minutes: 5);
  static const _threadDetailFreshness = Duration(minutes: 2);

  ChatController({
    required ChatRepository api,
    AssistantRuntimePort? assistantRuntime,
    required ChatScene scene,
    ChatThreadAliasRepository? aliasRepository,
    ChatConversationAdmissionCoordinator? admissionCoordinator,
    ChatRunTrackingPort? runTracker,
    ScopedReadCache? scopedReadCache,
    bool Function()? workspaceReady,
    ChatConversationPurpose conversationPurpose =
        ChatConversationPurpose.general,
    ChatAgentScope? agentScope,
    String? initialAgentProfileId,
    bool restoreRecentConversationOnCreate = false,
    DateTime Function()? now,
    ChatThreadProgressPoller? threadProgressPoller,
    AssistantThreadProgressPort? assistantProgress,
    ChatUserVisibleTextProjector? userVisibleTextProjector,
    this.coalescedStreamingUi = true,
    this.taskPollInterval = const Duration(seconds: 2),
    this.taskPollAttempts = 180,
  }) : // Public collaborator names intentionally omit private field prefixes.
       // ignore: prefer_initializing_formals
       _api = api,
       // ignore: prefer_initializing_formals
       // ignore: prefer_initializing_formals
       _aliasRepository = aliasRepository,
       // ignore: prefer_initializing_formals
       _admissionCoordinator = admissionCoordinator,
       // ignore: prefer_initializing_formals
       _runTracker = runTracker,
       // ignore: prefer_initializing_formals
       _scopedReadCache = scopedReadCache,
       _workspaceReady = workspaceReady ?? _workspaceAlwaysReady,
       // ignore: prefer_initializing_formals
       _conversationPurpose = conversationPurpose,
       // ignore: prefer_initializing_formals
       _agentScope = agentScope,
       // ignore: prefer_initializing_formals
       _initialAgentProfileId = initialAgentProfileId,
       // ignore: prefer_initializing_formals
       _now = now,
       // ignore: prefer_initializing_formals
       _threadProgressPoller = threadProgressPoller,
       // ignore: prefer_initializing_formals
       _assistantProgress = assistantProgress,
       // ignore: prefer_initializing_formals
       _userVisibleTextProjector = userVisibleTextProjector,
       _state = ChatControllerState.initial(scene),
       _assistantRunReader = ChatAssistantRunReader(assistantRuntime) {
    if (kDebugMode) {
      debugPrint(
        '[ChatState] controller=create id=${identityHashCode(this)} '
        'scene=${scene.apiValue} purpose=${conversationPurpose.routeValue}',
      );
    }
    if (runTracker is Listenable) {
      final listenable = runTracker as Listenable;
      _runTrackerListenable = listenable;
      if (runTracker is ChatRunCompletionSourcePort) {
        _runCompletionSource = runTracker as ChatRunCompletionSourcePort;
      }
      if (runTracker is ChatRunCompletionJournalPort) {
        _runCompletionJournal = runTracker as ChatRunCompletionJournalPort;
      }
      if (runTracker is ChatRunDraftDeltaSourcePort) {
        _runDraftDeltaSource = runTracker as ChatRunDraftDeltaSourcePort;
      }
      if (runTracker is ChatRunDraftSnapshotSourcePort) {
        _runDraftSnapshotSource = runTracker as ChatRunDraftSnapshotSourcePort;
      }
      if (_runCompletionSource != null ||
          _runCompletionJournal != null ||
          _runDraftDeltaSource != null) {
        listenable.addListener(_captureRunTrackerUpdate);
        _captureRunTrackerUpdate();
      }
    }
    if (restoreRecentConversationOnCreate) {
      _restoreInitialCachedConversation();
    }
  }

  final ChatRepository _api;
  final ChatAssistantRunReader _assistantRunReader;
  final ChatThreadAliasRepository? _aliasRepository;
  final ChatConversationAdmissionCoordinator? _admissionCoordinator;
  final ChatRunTrackingPort? _runTracker;
  final ScopedReadCache? _scopedReadCache;
  final bool Function() _workspaceReady;
  final ChatConversationPurpose _conversationPurpose;
  final ChatAgentScope? _agentScope;
  final String? _initialAgentProfileId;
  String? _boundThreadAgentProfileId;
  final DateTime Function()? _now;
  final ChatThreadProgressPoller? _threadProgressPoller;
  final AssistantThreadProgressPort? _assistantProgress;
  final ChatUserVisibleTextProjector? _userVisibleTextProjector;
  final bool coalescedStreamingUi;
  final Duration taskPollInterval;
  final int taskPollAttempts;
  ChatControllerState _state;
  SubmissionKeyStore _idempotencyStore = SubmissionKeyStore.empty;
  int _localMessageCounter = 0;
  bool _disposed = false;
  bool _threadMetadataHydrationFailed = false;
  Future<void>? _threadMetadataHydrationFuture;
  bool _historyRefreshInFlight = false;
  bool _historyHasMore = false;
  String? _historyContinuationCursor;
  String? _historyRefreshErrorCode;
  DateTime? _historySyncedAt;
  bool _historySnapshotComplete = false;
  int? _pollingTaskGeneration;
  bool get _isPollingTask =>
      _pollingTaskGeneration == _threadSelectionGeneration;
  bool _isTerminalReadbackInFlight = false;
  final Set<String> _restoredConversationCacheScopes = <String>{};
  int _threadSelectionGeneration = 0;
  String? _lastThreadSelectionRemoteFailureThreadId;
  String? _lastThreadSelectionRemoteFailureCode;
  ChatRunCompletionSourcePort? _runCompletionSource;
  ChatRunCompletionJournalPort? _runCompletionJournal;
  ChatRunDraftDeltaSourcePort? _runDraftDeltaSource;
  ChatRunDraftSnapshotSourcePort? _runDraftSnapshotSource;
  Listenable? _runTrackerListenable;
  int _observedRunCompletionSequence = 0;
  int _observedRunDraftDeltaSequence = 0;
  final Set<String> _observedRunCompletionKeys = <String>{};
  Timer? _terminalReadbackTimer;
  Timer? _taskPollDelayTimer;
  Completer<void>? _taskPollDelayCompleter;
  Timer? _agentProgressFallbackTimer;
  Timer? _conversationCachePersistTimer;
  bool _conversationCachePersistPending = false;
  _AgentProgressTransport? _agentProgressTransport;
  bool _agentProgressReadInFlight = false;
  String? _agentProgressThreadId;
  String? _agentProgressRunId;
  int _agentProgressSequence = 0;
  int _agentProgressSseSequence = 0;
  final Map<String, ChatStreamRevealBuffer> _agentProgressRevealBuffers =
      <String, ChatStreamRevealBuffer>{};
  final ValueNotifier<Map<String, String>> _agentProgressDrafts =
      ValueNotifier<Map<String, String>>(const <String, String>{});
  final ValueNotifier<Map<String, ChatAssistantAnswerDraft>>
  _assistantAnswerDrafts = ValueNotifier<Map<String, ChatAssistantAnswerDraft>>(
    const <String, ChatAssistantAnswerDraft>{},
  );
  final Map<String, ChatRunCompletion> _unreconciledRunCompletions =
      <String, ChatRunCompletion>{};
  final Map<String, int> _terminalReadbackAttempts = <String, int>{};
  final Set<String> _threadMetadataHydrationAttempted = <String>{};
  final Map<String, List<ChatMessage>> _cachedMessagesByThread =
      <String, List<ChatMessage>>{};
  final Map<String, _ValidatedTextSubmission> _textSubmissionEnvelopes =
      <String, _ValidatedTextSubmission>{};
  final Set<String> _abandonableFailedTextMessageIds = <String>{};
  final Set<String> _failedTextAbandonInFlight = <String>{};
  bool _conversationCacheCommitInFlight = false;
  final Map<String, DateTime> _threadDetailSyncedAt = <String, DateTime>{};
  final Map<String, Future<void>> _threadDetailRefreshes =
      <String, Future<void>>{};
  final Map<String, SharedThreadRuntimeInvocation> _runtimeInvocationCache =
      <String, SharedThreadRuntimeInvocation>{};
  final Map<String, String> _runtimeInvocationEtags = <String, String>{};
  final Map<String, List<SharedThreadRuntimeInvocation>>
  _runtimeInvocationHistoryCache =
      <String, List<SharedThreadRuntimeInvocation>>{};
  final Map<String, bool> _runtimeInvocationHistoryTruncated = <String, bool>{};
  final Map<String, int> _runtimeInvocationHistoryGenerations = <String, int>{};
  final Map<String, Future<ChatRuntimeInvocationHistorySnapshot>>
  _runtimeInvocationHistoryReads =
      <String, Future<ChatRuntimeInvocationHistorySnapshot>>{};
  final ValueNotifier<int> _runtimeInvocationCacheRevision = ValueNotifier<int>(
    0,
  );
  ChatControllerState get state => _state;
  bool get isRefreshingHistory => _historyRefreshInFlight;
  bool get hasMoreHistory => _historyHasMore;
  String? get historyRefreshErrorCode => _historyRefreshErrorCode;

  /// App-safe Assistant answer drafts, including transport and local reveal
  /// provenance, isolated from structural controller notifications.
  ValueListenable<Map<String, ChatAssistantAnswerDraft>>
  get assistantAnswerDrafts => _assistantAnswerDrafts;

  /// Compatibility projection for surfaces that only consume visible text.
  @Deprecated('Use assistantAnswerDrafts for explicit answer semantics.')
  ValueListenable<Map<String, String>> get agentProgressDrafts =>
      _agentProgressDrafts;

  /// Flushes a pending debounced cache snapshot before app backgrounding.
  void flushPendingConversationCache() {
    if (_conversationCachePersistPending) _persistConversationCache();
  }

  List<ChatThread> get historyThreads {
    if (_isThreadAgentScopeUnresolved) return const <ChatThread>[];
    final requestedProfile = _agentProfileFilterId;
    return ChatControllerPolicies.sortThreads(
      requestedProfile == null
          ? _state.threads
          : _state.threads.where(
              (thread) => _agentProfileForThread(thread) == requestedProfile,
            ),
    );
  }

  String? get activeAgentProfileId => _effectiveAgentProfileId;

  bool get isAgentScopeResolved => !_isThreadAgentScopeUnresolved;

  bool isThreadPending(ChatThread thread) {
    final tracker = _runTracker;
    if (tracker is ChatRunStatusPort) {
      final statusTracker = tracker! as ChatRunStatusPort;
      if (statusTracker.isThreadPending(thread.threadId)) return true;
      // Once a globally tracked Run finishes, the retained list snapshot must
      // not keep its stale `running` status alive until the next list refresh.
      return thread.activeRuns.any(
        (run) =>
            !run.isTerminal &&
            !statusTracker.hasTrackedThreadRun(thread.threadId, run.agentRunId),
      );
    }
    return thread.activeRuns.any((run) => !run.isTerminal);
  }

  /// The current history API has no collection version or message delta cursor.
  /// Refresh only work that still needs an authoritative Assistant readback.
  bool shouldRefreshThreadOnForeground(String threadId) {
    if (!isSafeChatIdentifier(threadId)) return false;
    final tracker = _runTracker;
    if (tracker is ChatRunReconciliationPort) {
      final reconciliationTracker = tracker! as ChatRunReconciliationPort;
      if (reconciliationTracker.needsThreadReconciliation(threadId)) {
        return true;
      }
    }
    final thread = _state.threads
        .where((candidate) => candidate.threadId == threadId)
        .firstOrNull;
    if (thread != null && isThreadPending(thread)) return true;
    return _state.activeThreadId == threadId &&
        ChatControllerPolicies.hasUnansweredUserTurn(_state.messages);
  }

  bool isAwaitingAssistantForThread(String threadId) {
    if (!isSafeChatIdentifier(threadId)) return false;
    if (_hasPendingTerminalReadback(threadId)) return true;
    final tracker = _runTracker;
    if (tracker is ChatRunReconciliationPort) {
      final reconciliation = tracker as ChatRunReconciliationPort;
      if (reconciliation.needsThreadReconciliation(threadId)) return true;
    }
    if (tracker is ChatRunStatusPort) {
      final status = tracker as ChatRunStatusPort;
      if (status.isThreadPending(threadId)) return true;
    }
    return _state.activeThreadId == threadId &&
        _state.status != ChatControllerStatus.failed &&
        (_state.isSending ||
            ChatControllerPolicies.awaitsAssistant(_state.nextAction));
  }

  bool _hasAccountThreadTurnInProgress(String threadId) {
    final tracker = _runTracker;
    if (tracker is ChatRunStatusPort &&
        (tracker as ChatRunStatusPort).isThreadPending(threadId)) {
      return true;
    }
    return tracker is ChatRunReconciliationPort &&
        (tracker as ChatRunReconciliationPort).needsThreadReconciliation(
          threadId,
        );
  }

  FutureOr<String?> _accountThreadTurnAdmissionError(String threadId) {
    final tracker = _runTracker;
    if (tracker is ChatRunRecoveryPort) {
      final recovery = tracker as ChatRunRecoveryPort;
      if (recovery.reconciliationForThread(threadId) != null) {
        return _recoverAccountThreadTurn(recovery, threadId);
      }
    }
    return _hasAccountThreadTurnInProgress(threadId)
        ? 'CHAT_THREAD_TURN_IN_PROGRESS'
        : null;
  }

  Future<String?> _recoverAccountThreadTurn(
    ChatRunRecoveryPort recovery,
    String threadId,
  ) async {
    try {
      if (!await recovery.recoverThread(threadId)) {
        return 'CHAT_THREAD_RESULT_SYNC_FAILED';
      }
    } catch (_) {
      return 'CHAT_THREAD_RESULT_SYNC_FAILED';
    }
    return _hasAccountThreadTurnInProgress(threadId)
        ? 'CHAT_THREAD_TURN_IN_PROGRESS'
        : null;
  }

  /// Restores account-scoped display snapshots before the first network
  /// request. A cached local user turn is retained only until the durable
  /// server thread projection can replace it.
  bool restoreCachedConversations() {
    if (_isThreadAgentScopeUnresolved) return false;
    final profile = _conversationCacheAgentProfileId;
    final cacheScopeKey = profile ?? '<all-profiles>';
    if (!_restoredConversationCacheScopes.add(cacheScopeKey)) {
      return _state.threads.isNotEmpty;
    }
    final repository = _aliasRepository;
    if (repository == null) return false;
    try {
      final cache = repository.loadConversationCache(
        scene: _state.scene,
        purpose: _conversationPurpose,
        agentProfileId: profile,
      );
      if (cache == null) return false;
      final cachedMessages = <String, List<ChatMessage>>{
        for (final entry in cache.messagesByThread.entries)
          entry.key: _projectMessagesForPurpose(entry.value),
      };
      final threads = ChatControllerPolicies.sortThreads(
        _overlayLocalAliases(
          _visibleThreadsForPurpose(
            _withStoredAgentProfiles(
              cache.threads.map((thread) {
                if (normalizeChatThreadFirstMessage(
                      thread.firstUserMessageText,
                    ) !=
                    null) {
                  return thread;
                }
                final firstUserMessage =
                    ChatControllerPolicies.firstUserMessageText(
                      cachedMessages[thread.threadId] ?? const <ChatMessage>[],
                    );
                return firstUserMessage == null
                    ? thread
                    : thread.copyWith(firstUserMessageText: firstUserMessage);
              }),
              adoptLegacyStandardProfile: true,
            ),
          ),
        ),
      );
      var mergedThreads = threads;
      for (final existingThread in _state.threads) {
        mergedThreads = ChatControllerPolicies.upsertThread(
          mergedThreads,
          existingThread,
        );
      }
      _cachedMessagesByThread.addAll(cachedMessages);
      _historySyncedAt = cache.historySyncedAt;
      _historySnapshotComplete = cache.historyComplete;
      _threadDetailSyncedAt
        ..clear()
        ..addAll(cache.detailSyncedAtByThread);
      _trackServerActiveRuns(threads);
      if (threads.isEmpty) return false;
      _update(
        _state.copyWith(
          status: ChatControllerStatus.ready,
          threads: mergedThreads,
          clearError: true,
        ),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  void _restoreInitialCachedConversation() {
    if (!restoreCachedConversations()) return;
    final repository = _aliasRepository;
    if (repository == null) return;
    final threadId = _agentProfileFilterId == null
        ? repository.recentThreadIdForPurpose(
            scene: _state.scene,
            purpose: _conversationPurpose,
          )
        : _latestThreadIdForEffectiveAgentProfile(_state.threads);
    if (threadId == null ||
        repository.isThreadHidden(scene: _state.scene, threadId: threadId) ||
        !_threadMatchesPurpose(threadId) ||
        !_threadMatchesEffectiveAgentProfile(threadId) ||
        _cachedMessagesByThread[threadId]?.isNotEmpty != true) {
      return;
    }
    _activateCachedThread(threadId);
  }

  Future<void> loadThreads({
    bool refresh = false,
    bool selectLatest = true,
    bool authoritativeLatest = false,
  }) async {
    if (_state.isLoading || _state.isSending || _isThreadAgentScopeUnresolved) {
      return;
    }
    if (refresh) _threadMetadataHydrationAttempted.clear();
    restoreCachedConversations();
    // The chat backend has no versioned collection or message-delta read. A
    // local server-confirmed projection is therefore the only safe normal
    // foreground source; a time-based full list read cannot prove freshness.
    if (!refresh && _state.threads.isNotEmpty) {
      final activeThreadId = _state.activeThreadId;
      final cachedThreadId =
          activeThreadId != null &&
              _threadMatchesEffectiveAgentProfile(activeThreadId)
          ? activeThreadId
          : (selectLatest
                ? _latestThreadIdForEffectiveAgentProfile(_state.threads)
                : null);
      if (cachedThreadId != null) {
        _activateCachedThread(cachedThreadId);
        _persistCurrentPurpose(cachedThreadId);
        return;
      }
    }
    final hasCachedConversation =
        _state.activeThreadId != null && _state.messages.isNotEmpty;
    _update(
      _state.copyWith(
        status: hasCachedConversation
            ? ChatControllerStatus.ready
            : ChatControllerStatus.loading,
        clearError: true,
      ),
    );
    final requestGeneration = _threadSelectionGeneration;
    final activeThreadIdAtRequest = _state.activeThreadId;
    final messagesAtRequest = List<ChatMessage>.of(_state.messages);
    final result = await _api.listThreads(
      scene: _state.scene,
      purpose: _conversationPurpose,
      limit: refresh ? 50 : 20,
    );
    if (!_isUnchangedThreadDiscovery(
      requestGeneration: requestGeneration,
      activeThreadId: activeThreadIdAtRequest,
      messages: messagesAtRequest,
    )) {
      return;
    }
    if (!result.ok || result.data == null) {
      _publishThreadDiscoveryFailure(
        result.error?.code ?? 'CHAT_THREAD_LIST_FAILED',
      );
      return;
    }
    _idempotencyStore = result.idempotencyStore;
    late List<ChatThread> threads;
    try {
      threads = ChatControllerPolicies.sortThreads(
        _overlayLocalAliases(
          _visibleThreadsForPurpose(
            _withStoredAgentProfiles(result.data!.items),
          ),
        ),
      );
    } catch (_) {
      _publishThreadDiscoveryFailure('CHAT_THREAD_LOCAL_METADATA_LOAD_FAILED');
      return;
    }
    final hydration = selectLatest
        ? await _hydrateThreadsForInitialProfileSelection(
            threads,
            requestGeneration,
          )
        : (threads: threads, failed: false);
    if (hydration == null ||
        !_isUnchangedThreadDiscovery(
          requestGeneration: requestGeneration,
          activeThreadId: activeThreadIdAtRequest,
          messages: messagesAtRequest,
        )) {
      return;
    }
    if (hydration.failed) {
      _publishThreadDiscoveryFailure('CHAT_THREAD_METADATA_LOAD_FAILED');
      return;
    }
    threads = hydration.threads;
    _trackServerActiveRuns(threads);
    // A Workspace-scoped list is discovery data. It must not replace an
    // explicit owner-scoped historical thread merely because that thread is
    // absent from the current Workspace's list page.
    final activeThreadId = _state.activeThreadId;
    final latestThreadId = selectLatest
        ? _latestThreadIdForEffectiveAgentProfile(threads)
        : null;
    final replacesCachedSelection = authoritativeLatest && selectLatest;
    final selectedThreadId = replacesCachedSelection
        ? latestThreadId
        : activeThreadId ?? latestThreadId;
    final selectionChanged = selectedThreadId != activeThreadId;
    if (selectionChanged) {
      _cancelActiveAgentRunReads();
      _stopAgentProgressProjection();
    }
    final visibleThreads = replacesCachedSelection
        ? threads
        : _mergeListedThreadsWithActiveRecovery(threads);
    _update(
      _state.copyWith(
        status: ChatControllerStatus.ready,
        threads: visibleThreads,
        activeThreadId: selectedThreadId,
        clearActiveThreadId: selectedThreadId == null,
        messages: selectionChanged ? const <ChatMessage>[] : _state.messages,
        nextCursor: result.data!.nextCursor,
        clearNextCursor: result.data!.nextCursor == null,
        clearAgentActivity: true,
        clearError: true,
      ),
    );
    _persistConversationCache();
    if (selectedThreadId != null) {
      if (replacesCachedSelection) {
        await _restoreLatestValidThread(threads);
      } else {
        await selectThread(selectedThreadId, forceRemote: true);
      }
    }
  }

  Future<void> _restoreLatestValidThread(List<ChatThread> threads) async {
    final requestedProfile = _agentProfileFilterId;
    final candidates = <ChatThread>[
      for (final thread in threads)
        if (requestedProfile == null ||
            _agentProfileForThread(thread) == null ||
            _agentProfileForThread(thread) == requestedProfile)
          thread,
    ];
    for (final candidate in candidates) {
      await selectThread(candidate.threadId, forceRemote: true);
      if (_disposed ||
          _state.status != ChatControllerStatus.ready ||
          _state.activeThreadId != candidate.threadId) {
        return;
      }
      if (!_threadMatchesEffectiveAgentProfile(candidate.threadId)) continue;
      final selected = _state.threads
          .where((thread) => thread.threadId == candidate.threadId)
          .firstOrNull;
      if (_state.messages.isNotEmpty ||
          (selected != null && isThreadPending(selected)) ||
          _hasPendingTerminalReadback(candidate.threadId)) {
        return;
      }
    }
    if (!_disposed && _state.status == ChatControllerStatus.ready) {
      startNewThread();
    }
  }

  bool _isUnchangedThreadDiscovery({
    required int requestGeneration,
    required String? activeThreadId,
    required List<ChatMessage> messages,
  }) =>
      !_disposed &&
      !_state.isSending &&
      requestGeneration == _threadSelectionGeneration &&
      activeThreadId == _state.activeThreadId &&
      listEquals(messages, _state.messages);

  void _publishThreadDiscoveryFailure(String code) {
    final hasCachedProjection =
        _state.activeThreadId != null ||
        _state.messages.isNotEmpty ||
        _state.threads.isNotEmpty;
    _update(
      _state.copyWith(
        status: hasCachedProjection
            ? ChatControllerStatus.ready
            : ChatControllerStatus.failed,
        lastErrorCode: code,
      ),
    );
  }

  Future<({List<ChatThread> threads, bool failed})?>
  _hydrateThreadsForInitialProfileSelection(
    List<ChatThread> initialThreads,
    int requestGeneration,
  ) async {
    final requestedProfile = _agentProfileFilterId;
    if (requestedProfile == null || initialThreads.isEmpty) {
      return (threads: initialThreads, failed: false);
    }
    final threads = initialThreads.toList();
    for (var offset = 0; offset < threads.length; offset += 6) {
      final end = offset + 6 < threads.length ? offset + 6 : threads.length;
      final candidateIndexes = <int>[
        for (var index = offset; index < end; index += 1)
          if (_agentProfileForThread(threads[index]) == null) index,
      ];
      final hydrated = await Future.wait(<Future<ChatThread?>>[
        for (final index in candidateIndexes)
          _loadThreadMetadata(threads[index].threadId),
      ]);
      if (_disposed || requestGeneration != _threadSelectionGeneration) {
        return null;
      }
      final failedIndexes = <int>{};
      for (var index = 0; index < candidateIndexes.length; index += 1) {
        final threadIndex = candidateIndexes[index];
        final metadata = hydrated[index];
        if (metadata == null) {
          failedIndexes.add(threadIndex);
          continue;
        }
        final thread = threads[threadIndex];
        threads[threadIndex] = _withStoredAgentProfile(
          _withLocalAlias(
            thread.copyWith(
              firstUserMessageText:
                  normalizeChatThreadFirstMessage(
                        thread.firstUserMessageText,
                      ) !=
                      null
                  ? thread.firstUserMessageText
                  : metadata.firstUserMessageText,
              agentProfileId: thread.agentProfileId ?? metadata.agentProfileId,
            ),
          ),
          adoptLegacyStandardProfile: _usesStandardCreationAsOrdinaryProfile,
        );
      }
      for (var index = offset; index < end; index += 1) {
        if (_agentProfileForThread(threads[index]) != requestedProfile) {
          continue;
        }
        return (
          threads: List<ChatThread>.unmodifiable(threads),
          failed: failedIndexes.any((failedIndex) => failedIndex < index),
        );
      }
      if (failedIndexes.isNotEmpty) {
        return (threads: List<ChatThread>.unmodifiable(threads), failed: true);
      }
    }
    return (threads: List<ChatThread>.unmodifiable(threads), failed: false);
  }

  Future<void> refreshCompleteHistory({
    bool loadMore = false,
    bool force = false,
  }) async {
    if (_historyRefreshInFlight ||
        _state.isSending ||
        _disposed ||
        _isThreadAgentScopeUnresolved) {
      return;
    }
    if (loadMore && _historyContinuationCursor == null) return;
    restoreCachedConversations();
    if (!loadMore &&
        !force &&
        _historySnapshotComplete &&
        _state.threads.isNotEmpty &&
        _isFresh(_historySyncedAt, _historyFreshness)) {
      return;
    }
    if (!loadMore) {
      _threadMetadataHydrationAttempted.clear();
      _historyContinuationCursor = null;
      _historyHasMore = false;
    }
    final requestGeneration = _threadSelectionGeneration;
    final collected = <String, ChatThread>{
      if (loadMore)
        for (final thread in _state.threads) thread.threadId: thread,
    };
    var cursor = loadMore ? _historyContinuationCursor : null;
    final seenCursors = <String>{if (cursor != null) cursor};
    var exhausted = false;
    var pages = 0;
    String? errorCode;
    _historyRefreshInFlight = true;
    _historyRefreshErrorCode = null;
    notifyListeners();
    try {
      while (pages < 20) {
        final result = await _api.listThreads(
          scene: _state.scene,
          purpose: _conversationPurpose,
          cursor: cursor,
          limit: 50,
        );
        if (requestGeneration != _threadSelectionGeneration || _disposed) {
          return;
        }
        if (!result.ok || result.data == null) {
          errorCode = result.error?.code ?? 'CHAT_THREAD_LIST_FAILED';
          break;
        }
        _idempotencyStore = result.idempotencyStore;
        pages += 1;
        final page = result.data!;
        final before = collected.length;
        for (final thread in page.items) {
          collected.putIfAbsent(thread.threadId, () => thread);
        }
        if (page.items.isEmpty || page.items.length < 50) {
          cursor = null;
          exhausted = true;
          break;
        }
        final nextCursor = _nextHistoryCursor(page);
        if (nextCursor == null ||
            !seenCursors.add(nextCursor) ||
            collected.length == before) {
          cursor = null;
          errorCode = 'CHAT_HISTORY_CURSOR_STALLED';
          break;
        }
        cursor = nextCursor;
      }

      if (collected.isNotEmpty || (exhausted && !loadMore)) {
        late final List<ChatThread> threads;
        try {
          threads = _mergeListedThreadsWithActiveRecovery(
            ChatControllerPolicies.sortThreads(
              _overlayLocalAliases(
                _visibleThreadsForPurpose(
                  _withStoredAgentProfiles(collected.values),
                ),
              ),
            ),
          );
        } catch (_) {
          errorCode = 'CHAT_THREAD_LOCAL_METADATA_LOAD_FAILED';
          threads = _state.threads;
        }
        _trackServerActiveRuns(threads);
        _update(
          _state.copyWith(
            status: ChatControllerStatus.ready,
            threads: threads,
            nextCursor: cursor,
            clearNextCursor: cursor == null,
            clearError: true,
          ),
        );
        await hydrateThreadTitles();
        if (_threadMetadataHydrationFailed) {
          errorCode ??= 'CHAT_THREAD_METADATA_LOAD_FAILED';
        }
        if (exhausted && errorCode == null) {
          _historySyncedAt = _nowUtc();
          _historySnapshotComplete = true;
        }
        _persistConversationCache();
      } else if (errorCode != null && _state.threads.isEmpty) {
        _update(
          _state.copyWith(
            status: ChatControllerStatus.failed,
            lastErrorCode: errorCode,
          ),
        );
      }

      _historyContinuationCursor = cursor;
      _historyHasMore = !exhausted && cursor != null;
      _historyRefreshErrorCode = errorCode;
    } finally {
      _historyRefreshInFlight = false;
      if (!_disposed) notifyListeners();
    }
  }

  String? _nextHistoryCursor(ChatThreadPage page) {
    final explicit = page.nextCursor?.trim();
    if (explicit != null && explicit.isNotEmpty) return explicit;
    DateTime? oldest;
    for (final thread in page.items) {
      final updatedAt = thread.updatedAt;
      if (updatedAt != null && (oldest == null || updatedAt.isBefore(oldest))) {
        oldest = updatedAt;
      }
    }
    return oldest?.toUtc().toIso8601String();
  }

  Future<bool> restoreRecentPurposeThread() async {
    if (_state.isLoading || _state.isSending || _isThreadAgentScopeUnresolved) {
      return false;
    }
    final repository = _aliasRepository;
    if (repository == null) {
      if (_conversationPurpose == ChatConversationPurpose.general) {
        return false;
      }
      _fail('CHAT_THREAD_PURPOSE_STORAGE_UNAVAILABLE');
      return false;
    }
    String? threadId;
    try {
      final activeThreadId = _state.activeThreadId;
      if (activeThreadId != null &&
          _state.status == ChatControllerStatus.ready &&
          _threadMatchesPurpose(activeThreadId) &&
          _threadMatchesEffectiveAgentProfile(activeThreadId)) {
        if (_state.messages.isNotEmpty ||
            _hasPendingTerminalReadback(activeThreadId)) {
          return true;
        }
        await selectThread(activeThreadId, forceRemote: true);
        return _state.status == ChatControllerStatus.ready &&
            _state.activeThreadId == activeThreadId &&
            (_state.messages.isNotEmpty ||
                isAwaitingAssistantForThread(activeThreadId));
      }
      threadId = _agentProfileFilterId == null
          ? repository.recentThreadIdForPurpose(
              scene: _state.scene,
              purpose: _conversationPurpose,
            )
          : _latestThreadIdForEffectiveAgentProfile(_state.threads);
    } catch (_) {
      _fail('CHAT_THREAD_PURPOSE_LOAD_FAILED');
      return false;
    }
    if (threadId == null ||
        repository.isThreadHidden(scene: _state.scene, threadId: threadId)) {
      return false;
    }
    await selectThread(threadId);
    return _state.status == ChatControllerStatus.ready &&
        _state.activeThreadId == threadId &&
        (_state.messages.isNotEmpty || isAwaitingAssistantForThread(threadId));
  }

  Future<void> selectThread(
    String threadId, {
    bool forceRemote = false,
    bool allowUnassignedPurposeHydration = false,
    bool silentRemoteFailure = false,
  }) async {
    _lastThreadSelectionRemoteFailureThreadId = null;
    _lastThreadSelectionRemoteFailureCode = null;
    if (_state.isSending) return;
    if (!isSafeChatIdentifier(threadId)) {
      _fail('CHAT_THREAD_ID_INVALID');
      return;
    }
    final mayHydrateUnassignedPurpose =
        allowUnassignedPurposeHydration &&
        forceRemote &&
        _conversationPurpose != ChatConversationPurpose.general;
    if (!_threadMatchesPurpose(threadId) && !mayHydrateUnassignedPurpose) {
      _fail('CHAT_THREAD_PURPOSE_MISMATCH');
      return;
    }
    final previousSelection = _state;
    final previousThreadId = previousSelection.activeThreadId;
    if (previousThreadId != null && previousThreadId != threadId) {
      _stopAgentProgressProjection(previousThreadId);
      _rememberServerMessages(previousThreadId, _state.messages);
      _persistConversationCache();
      _cancelActiveAgentRunReads();
    }
    final requestGeneration = ++_threadSelectionGeneration;
    try {
      _aliasRepository?.restoreThread(scene: _state.scene, threadId: threadId);
    } catch (_) {
      // Visibility metadata must not block an authenticated thread readback.
    }
    restoreCachedConversations();
    final cachedMessages = _cachedMessagesByThread[threadId];
    final hasCachedThread =
        !mayHydrateUnassignedPurpose &&
        cachedMessages != null &&
        cachedMessages.isNotEmpty &&
        _state.threads.any((thread) => thread.threadId == threadId);
    if (hasCachedThread) {
      _activateCachedThread(threadId);
    }
    if (!forceRemote &&
        !_hasPendingTerminalReadback(threadId) &&
        hasCachedThread) {
      if (!_persistCurrentPurpose(threadId)) return;
      return;
    }
    if (!hasCachedThread) {
      _update(
        _state.copyWith(
          status: ChatControllerStatus.loading,
          activeThreadId: mayHydrateUnassignedPurpose
              ? _state.activeThreadId
              : threadId,
          messages: mayHydrateUnassignedPurpose
              ? _state.messages
              : cachedMessages ?? _state.messages,
          clearError: true,
        ),
      );
    }
    _threadMetadataHydrationAttempted.add(threadId);
    final result = await _api.getThreadDetail(threadId: threadId);
    if (!_isCurrentThreadSelection(requestGeneration)) return;
    if (!result.ok || result.data == null) {
      final failureCode = result.error?.code ?? 'CHAT_THREAD_DETAIL_FAILED';
      _lastThreadSelectionRemoteFailureThreadId = threadId;
      _lastThreadSelectionRemoteFailureCode = failureCode;
      if (hasCachedThread) {
        _activateCachedThread(
          threadId,
          lastErrorCode: silentRemoteFailure ? null : failureCode,
        );
        return;
      }
      _rejectThreadSelection(previousSelection, failureCode);
      return;
    }
    final serverDetail = result.data!;
    var detail = ChatThreadDetail(
      thread: _withStoredAgentProfile(
        serverDetail.thread.copyWith(
          scene: _state.scene,
          agentProfileId:
              serverDetail.thread.agentProfileId ??
              _knownThreadAgentProfile(threadId),
          firstUserMessageText:
              serverDetail.thread.firstUserMessageText ??
              ChatControllerPolicies.firstUserMessageText(
                serverDetail.messages,
              ),
        ),
        adoptLegacyStandardProfile: _usesStandardCreationAsOrdinaryProfile,
      ),
      messages: List<ChatMessage>.unmodifiable(
        serverDetail.messages.map(
          (message) => message.copyWith(scene: _state.scene),
        ),
      ),
    );
    if (detail.thread.threadId != threadId ||
        (detail.thread.purpose != _conversationPurpose &&
            !_isLegacyPurposeAssignment(detail.thread) &&
            !_matchesUnassignedPurposeHydration(
              serverDetail.thread,
              allowed: mayHydrateUnassignedPurpose,
            ))) {
      _lastThreadSelectionRemoteFailureThreadId = threadId;
      _lastThreadSelectionRemoteFailureCode = 'CHAT_THREAD_SCENE_MISMATCH';
      _rejectThreadSelection(previousSelection, 'CHAT_THREAD_SCENE_MISMATCH');
      return;
    }
    if (!_bindOrVerifyThreadAgentProfile(detail.thread)) {
      final failureCode =
          _state.lastErrorCode ?? 'CHAT_THREAD_AGENT_PROFILE_MISMATCH';
      _lastThreadSelectionRemoteFailureThreadId = threadId;
      _lastThreadSelectionRemoteFailureCode = failureCode;
      _rejectThreadSelection(previousSelection, failureCode);
      return;
    }
    restoreCachedConversations();
    final effectiveProfile = _effectiveAgentProfileId;
    if (detail.thread.agentProfileId?.trim().isNotEmpty != true &&
        effectiveProfile != null) {
      detail = ChatThreadDetail(
        thread: detail.thread.copyWith(agentProfileId: effectiveProfile),
        messages: detail.messages,
      );
    }
    _idempotencyStore = result.idempotencyStore;
    _trackServerActiveRuns(<ChatThread>[detail.thread]);
    final terminalAssistantMessageIds = _terminalAssistantMessageIdsForThread(
      threadId,
    );
    final messages = ChatControllerPolicies.mergeServerAndLocalMessages(
      _projectMessagesForPurpose(detail.messages),
      _cachedMessagesByThread[threadId] ?? _state.messages,
      threadId,
      _state.scene,
      terminalAssistantMessageIdsByRunId: terminalAssistantMessageIds,
    );
    final streamedRunId = _agentProgressRunId;
    if (_agentProgressThreadId == threadId &&
        streamedRunId != null &&
        detail.messages.any(
          (message) =>
              message.role == ChatMessageRole.assistant &&
              (message.agentRunId == streamedRunId ||
                  message.messageId ==
                      terminalAssistantMessageIds[streamedRunId]),
        )) {
      _stopAgentProgressProjection(threadId);
    }
    if (!_persistCurrentPurpose(threadId)) return;
    _update(
      _state.copyWith(
        status: ChatControllerStatus.ready,
        activeThreadId: threadId,
        threads: ChatControllerPolicies.upsertThread(
          _state.threads,
          _withLocalAlias(detail.thread),
        ),
        messages: messages,
        nextAction: const ChatNextAction.none(),
        clearAgentActivity: true,
        clearError: true,
      ),
    );
    _resumeAgentProgressProjection(threadId);
    _discardReconciledRunCompletions(threadId, messages);
    _rememberServerMessages(threadId, _state.messages);
    _threadDetailSyncedAt[threadId] = _nowUtc();
    _persistConversationCache();
    _scheduleTerminalReadback();
  }

  String? lastRemoteFailureCodeForThreadSelection(String threadId) {
    if (_lastThreadSelectionRemoteFailureThreadId != threadId) return null;
    return _lastThreadSelectionRemoteFailureCode;
  }

  Future<void> revalidateThreadIfStale(String threadId, {bool force = false}) {
    if (_disposed || _state.activeThreadId != threadId) {
      return Future<void>.value();
    }
    if (!force &&
        !shouldRefreshThreadOnForeground(threadId) &&
        _isFresh(_threadDetailSyncedAt[threadId], _threadDetailFreshness)) {
      return Future<void>.value();
    }
    final active = _threadDetailRefreshes[threadId];
    if (active != null) return active;
    late final Future<void> operation;
    operation =
        selectThread(
          threadId,
          forceRemote: true,
          silentRemoteFailure: true,
        ).whenComplete(() {
          if (identical(_threadDetailRefreshes[threadId], operation)) {
            _threadDetailRefreshes.remove(threadId);
          }
        });
    _threadDetailRefreshes[threadId] = operation;
    return operation;
  }

  Future<void> hydrateThreadTitles() {
    if (_disposed) return Future<void>.value();
    final active = _threadMetadataHydrationFuture;
    if (active != null) return active;
    final future = _hydrateThreadTitles();
    _threadMetadataHydrationFuture = future;
    return future.whenComplete(() {
      if (identical(_threadMetadataHydrationFuture, future)) {
        _threadMetadataHydrationFuture = null;
      }
    });
  }

  Future<void> _hydrateThreadTitles() async {
    _threadMetadataHydrationFailed = false;
    final metadataById = <String, ChatThread>{};
    while (!_disposed) {
      final candidates = <String>[
        for (final thread in _state.threads)
          if (!_threadMetadataHydrationAttempted.contains(thread.threadId) &&
              (normalizeChatThreadFirstMessage(thread.firstUserMessageText) ==
                      null ||
                  thread.agentProfileId?.trim().isNotEmpty != true))
            thread.threadId,
      ];
      if (candidates.isEmpty) break;
      for (var offset = 0; offset < candidates.length; offset += 6) {
        final end = offset + 6 < candidates.length
            ? offset + 6
            : candidates.length;
        final hydrated = await Future.wait(<Future<ChatThread?>>[
          for (final threadId in candidates.sublist(offset, end))
            _loadThreadMetadata(threadId),
        ]);
        if (_disposed) return;
        for (final thread in hydrated) {
          if (thread == null) {
            _threadMetadataHydrationFailed = true;
          } else {
            metadataById[thread.threadId] = thread;
          }
        }
      }
    }
    if (metadataById.isEmpty) return;
    final threads = <ChatThread>[
      for (final thread in _state.threads)
        if (metadataById[thread.threadId] case final metadata?)
          _withStoredAgentProfile(
            _withLocalAlias(
              thread.copyWith(
                firstUserMessageText:
                    normalizeChatThreadFirstMessage(
                          thread.firstUserMessageText,
                        ) !=
                        null
                    ? thread.firstUserMessageText
                    : metadata.firstUserMessageText,
                agentProfileId:
                    thread.agentProfileId ??
                    metadata.agentProfileId ??
                    (_usesStandardCreationAsOrdinaryProfile
                        ? standardCreationChatAgentProfileId
                        : null),
              ),
            ),
          )
        else
          thread,
    ];
    _update(_state.copyWith(threads: threads));
    final activeThreadId = _state.activeThreadId;
    if (activeThreadId != null) {
      for (final thread in threads) {
        if (thread.threadId == activeThreadId) {
          if (!_bindOrVerifyThreadAgentProfile(thread)) return;
          break;
        }
      }
    }
    _persistConversationCache();
  }

  Future<ChatThread?> _loadThreadMetadata(String threadId) async {
    try {
      _threadMetadataHydrationAttempted.add(threadId);
      final result = await _api.getThreadDetail(threadId: threadId);
      final detail = result.data;
      if (!result.ok || detail == null || detail.thread.threadId != threadId) {
        return null;
      }
      final title = normalizeChatThreadFirstMessage(
        detail.thread.firstUserMessageText ??
            ChatControllerPolicies.firstUserMessageText(detail.messages),
      );
      return detail.thread.copyWith(firstUserMessageText: title);
    } catch (_) {
      return null;
    }
  }

  void startNewThread() {
    if (_state.isSending) return;
    _cancelActiveAgentRunReads();
    _stopAgentProgressProjection();
    _textSubmissionEnvelopes.clear();
    _abandonableFailedTextMessageIds.clear();
    _threadSelectionGeneration += 1;
    if (_agentScope?.bindsFromThread != true) {
      _boundThreadAgentProfileId = null;
    }
    _update(
      _state.copyWith(
        status: ChatControllerStatus.ready,
        messages: const <ChatMessage>[],
        clearActiveThreadId: true,
        nextAction: const ChatNextAction.none(),
        clearAgentActivity: true,
        clearError: true,
      ),
    );
  }

  bool _isCurrentThreadSelection(int generation) =>
      !_disposed && _threadSelectionGeneration == generation;

  String? threadAliasError(String rawAlias) {
    return normalizeChatThreadAlias(rawAlias) == null ? '请输入 1-60 个字符' : null;
  }

  Future<bool> renameThreadRemote(String threadId, String rawTitle) =>
      _updateRemoteThreadTitle(threadId, rawTitle, ChatThreadTitleMode.custom);

  Future<bool> resetThreadNameRemote(String threadId) =>
      _updateRemoteThreadTitle(threadId, null, ChatThreadTitleMode.auto);

  Future<bool> _updateRemoteThreadTitle(
    String threadId,
    String? rawTitle,
    ChatThreadTitleMode titleMode,
  ) async {
    final index = _state.threads.indexWhere(
      (item) => item.threadId == threadId,
    );
    final title = rawTitle?.trim();
    if (!isSafeChatIdentifier(threadId) ||
        index < 0 ||
        (titleMode == ChatThreadTitleMode.custom &&
            threadAliasError(title ?? '') != null)) {
      _fail('CHAT_THREAD_TITLE_INVALID');
      return false;
    }
    final current = _state.threads[index];
    final metadata = _api;
    if (metadata is! ChatThreadMetadataPort) {
      _fail('CHAT_THREAD_METADATA_UNAVAILABLE');
      return false;
    }
    final metadataPort = metadata as ChatThreadMetadataPort;
    final result = await metadataPort.updateThreadTitle(
      threadId: threadId,
      titleMode: titleMode,
      title: title,
      expectedTitleVersion: current.titleVersion,
      idempotency: IdempotencyRequestContext(
        operation: 'chat.thread.title.${titleMode.name}',
        businessEntityId: threadId,
        localDraftId: '${current.titleVersion}:${title ?? 'auto'}',
        automaticRetry: true,
      ),
      idempotencyStore: _idempotencyStore,
    );
    _idempotencyStore = result.idempotencyStore;
    if (!result.ok || result.data == null) {
      if (result.error?.code == 'THREAD_TITLE_VERSION_CONFLICT') {
        await selectThread(threadId, forceRemote: true);
      }
      _fail(result.error?.code ?? 'CHAT_THREAD_TITLE_UPDATE_FAILED');
      return false;
    }
    final updated = result.data!;
    if (updated.threadId != threadId) {
      _fail('CHAT_THREAD_TITLE_RESPONSE_INVALID');
      return false;
    }
    try {
      _aliasRepository?.deleteAlias(scene: _state.scene, threadId: threadId);
    } catch (_) {
      // The cloud mutation is already authoritative; a stale display alias
      // must not turn a successful rename into an apparent failure.
    }
    final merged = current.copyWith(
      title: updated.title,
      titleMode: updated.titleMode,
      titleVersion: updated.titleVersion,
      clearLocalAlias: true,
    );
    _update(
      _state.copyWith(
        status: ChatControllerStatus.ready,
        threads: ChatControllerPolicies.upsertThread(_state.threads, merged),
        clearError: true,
      ),
    );
    unawaited(
      _rememberThreadTaskSubject(threadId, subjectTitle: merged.displayTitle),
    );
    _persistConversationCache();
    return true;
  }

  SharedThreadRuntimeInvocation? cachedRuntimeInvocation(String threadId) =>
      _runtimeInvocationCache[threadId];

  ValueListenable<int> get runtimeInvocationCacheRevision =>
      _runtimeInvocationCacheRevision;

  void _invalidateRuntimeInvocation(String threadId) {
    final removedInvocation = _runtimeInvocationCache.remove(threadId) != null;
    final removedEtag = _runtimeInvocationEtags.remove(threadId) != null;
    _runtimeInvocationHistoryTruncated.remove(threadId);
    _runtimeInvocationHistoryReads.remove(threadId);
    _runtimeInvocationHistoryGenerations[threadId] =
        (_runtimeInvocationHistoryGenerations[threadId] ?? 0) + 1;
    _scopedReadCache?.invalidate('chatThreadRuntimeInvocation', threadId);
    if (removedInvocation || removedEtag) {
      _notifyRuntimeInvocationCacheChanged();
    }
  }

  Future<SharedThreadRuntimeInvocation?> readRuntimeInvocation(
    String threadId, {
    bool reportErrors = true,
  }) async {
    if (!isSafeChatIdentifier(threadId)) return null;
    final cachedEntry = _scopedReadCache?.readFallback(
      'chatThreadRuntimeInvocation',
      threadId,
    );
    if (!_runtimeInvocationCache.containsKey(threadId) && cachedEntry != null) {
      final cached = parseSharedThreadRuntimeInvocation(cachedEntry.payload);
      if (cached != null && cached.threadId == threadId) {
        _runtimeInvocationCache[threadId] = cached;
        _notifyRuntimeInvocationCacheChanged();
        final cachedEtag = cachedEntry.etag;
        if (cachedEtag != null && cachedEtag.isNotEmpty) {
          _runtimeInvocationEtags[threadId] = cachedEtag;
        }
      }
    }
    final metadata = _api;
    if (metadata is! ChatThreadMetadataPort) {
      if (reportErrors) _fail('CHAT_THREAD_METADATA_UNAVAILABLE');
      return null;
    }
    final metadataPort = metadata as ChatThreadMetadataPort;
    var result = await metadataPort.latestThreadRuntimeInvocation(
      threadId: threadId,
      ifNoneMatch: _runtimeInvocationEtags[threadId],
    );
    if (result.isNotModified &&
        !_runtimeInvocationCache.containsKey(threadId)) {
      result = await metadataPort.latestThreadRuntimeInvocation(
        threadId: threadId,
      );
    }
    if (result.isNotModified) return _runtimeInvocationCache[threadId];
    if (!result.ok || result.data == null) {
      if (reportErrors) {
        _fail(result.error?.code ?? 'CHAT_RUNTIME_INVOCATION_READ_FAILED');
      }
      return _runtimeInvocationCache[threadId];
    }
    final invocation = result.data!;
    if (invocation.threadId != threadId) {
      if (reportErrors) _fail('CHAT_RUNTIME_INVOCATION_RESPONSE_INVALID');
      return _runtimeInvocationCache[threadId];
    }
    _runtimeInvocationCache[threadId] = invocation;
    _notifyRuntimeInvocationCacheChanged();
    final etag = result.etag;
    if (etag != null && etag.isNotEmpty) {
      _runtimeInvocationEtags[threadId] = etag;
    }
    _scopedReadCache?.write(
      'chatThreadRuntimeInvocation',
      threadId,
      etag: _runtimeInvocationEtags[threadId],
      payload: runtimeInvocationPayload(invocation),
    );
    return invocation;
  }

  List<SharedThreadRuntimeInvocation> cachedRuntimeInvocations(
    String threadId,
  ) =>
      _runtimeInvocationHistoryCache[threadId] ??
      const <SharedThreadRuntimeInvocation>[];

  Future<List<SharedThreadRuntimeInvocation>> readRuntimeInvocations(
    String threadId, {
    bool reportErrors = true,
  }) async {
    final snapshot = await readRuntimeInvocationHistory(
      threadId,
      reportErrors: reportErrors,
    );
    return snapshot.items;
  }

  Future<ChatRuntimeInvocationHistorySnapshot> readRuntimeInvocationHistory(
    String threadId, {
    bool reportErrors = true,
  }) async {
    if (!isSafeChatIdentifier(threadId)) {
      const code = 'CHAT_THREAD_ID_INVALID';
      if (reportErrors) _fail(code);
      return const ChatRuntimeInvocationHistorySnapshot(
        items: <SharedThreadRuntimeInvocation>[],
        isSettled: false,
        errorCode: code,
      );
    }
    final snapshot = await _coalescedRuntimeInvocationHistoryRead(threadId);
    if (reportErrors && !snapshot.isSettled && snapshot.errorCode != null) {
      _fail(snapshot.errorCode!);
    }
    return snapshot;
  }

  Future<ChatRuntimeInvocationHistorySnapshot>
  _coalescedRuntimeInvocationHistoryRead(String threadId) async {
    final existing = _runtimeInvocationHistoryReads[threadId];
    if (existing != null) return existing;
    final generation = _runtimeInvocationHistoryGenerations[threadId] ?? 0;
    final read = _fetchRuntimeInvocationHistory(threadId, generation);
    _runtimeInvocationHistoryReads[threadId] = read;
    try {
      return await read;
    } finally {
      if (identical(_runtimeInvocationHistoryReads[threadId], read)) {
        _runtimeInvocationHistoryReads.remove(threadId);
      }
    }
  }

  Future<ChatRuntimeInvocationHistorySnapshot> _fetchRuntimeInvocationHistory(
    String threadId,
    int generation,
  ) async {
    final history = _api;
    if (history is! ChatThreadRuntimeHistoryPort) {
      return ChatRuntimeInvocationHistorySnapshot(
        items: cachedRuntimeInvocations(threadId),
        isSettled: false,
        errorCode: 'CHAT_RUNTIME_INVOCATION_HISTORY_UNAVAILABLE',
      );
    }
    final historyPort = history as ChatThreadRuntimeHistoryPort;
    var first = await historyPort.threadRuntimeInvocations(
      threadId: threadId,
      limit: 50,
    );
    if (first.isNotModified) {
      first = await historyPort.threadRuntimeInvocations(
        threadId: threadId,
        limit: 50,
      );
    }
    if (first.isNotModified) {
      return ChatRuntimeInvocationHistorySnapshot(
        items: cachedRuntimeInvocations(threadId),
        isSettled: false,
        errorCode: 'CHAT_RUNTIME_INVOCATION_HISTORY_RESPONSE_INVALID',
      );
    }
    final firstPage = first.data;
    if (!first.ok || firstPage == null) {
      return ChatRuntimeInvocationHistorySnapshot(
        items: cachedRuntimeInvocations(threadId),
        isSettled: false,
        errorCode:
            first.error?.code ?? 'CHAT_RUNTIME_INVOCATION_HISTORY_READ_FAILED',
      );
    }

    final fetched = <SharedThreadRuntimeInvocation>[...firstPage.items];
    var cursor = firstPage.nextCursor;
    var complete = cursor == null;
    final seenCursors = <String>{if (cursor != null) cursor};
    String? continuationErrorCode;
    for (var pageIndex = 1; cursor != null && pageIndex < 4; pageIndex += 1) {
      final pageResult = await historyPort.threadRuntimeInvocations(
        threadId: threadId,
        cursor: cursor,
        limit: 50,
      );
      final page = pageResult.data;
      if (!pageResult.ok || page == null) {
        continuationErrorCode =
            pageResult.error?.code ??
            'CHAT_RUNTIME_INVOCATION_HISTORY_READ_FAILED';
        break;
      }
      fetched.addAll(page.items);
      final nextCursor = page.nextCursor;
      if (nextCursor != null && !seenCursors.add(nextCursor)) {
        continuationErrorCode =
            'CHAT_RUNTIME_INVOCATION_HISTORY_CURSOR_STALLED';
        break;
      }
      cursor = nextCursor;
      complete = cursor == null;
    }
    final fetchedByRunId = <String, SharedThreadRuntimeInvocation>{};
    for (final invocation in fetched) {
      if (invocation.threadId == threadId) {
        fetchedByRunId.putIfAbsent(invocation.agentRunId, () => invocation);
      }
    }
    final byRunId = <String, SharedThreadRuntimeInvocation>{
      if (continuationErrorCode != null)
        for (final invocation in cachedRuntimeInvocations(threadId))
          invocation.agentRunId: invocation,
      ...fetchedByRunId,
    };
    final ordered = byRunId.values.toList(growable: false)
      ..sort((left, right) {
        final byCreated = (right.createdAt ?? DateTime.utc(1970)).compareTo(
          left.createdAt ?? DateTime.utc(1970),
        );
        return byCreated != 0
            ? byCreated
            : right.agentRunId.compareTo(left.agentRunId);
      });
    final invocations = List<SharedThreadRuntimeInvocation>.unmodifiable(
      ordered.take(200),
    );
    if ((_runtimeInvocationHistoryGenerations[threadId] ?? 0) != generation) {
      return ChatRuntimeInvocationHistorySnapshot(
        items: cachedRuntimeInvocations(threadId),
        isSettled: false,
      );
    }
    _runtimeInvocationHistoryCache[threadId] = invocations;
    final settled = continuationErrorCode == null;
    if (settled) {
      _runtimeInvocationHistoryTruncated[threadId] = !complete;
    } else {
      _runtimeInvocationHistoryTruncated.remove(threadId);
    }
    _notifyRuntimeInvocationCacheChanged();
    return ChatRuntimeInvocationHistorySnapshot(
      items: invocations,
      isSettled: settled,
      isTruncated: settled && !complete,
      errorCode: continuationErrorCode,
    );
  }

  void _notifyRuntimeInvocationCacheChanged() {
    if (_disposed) return;
    _runtimeInvocationCacheRevision.value += 1;
  }

  bool renameThread(String threadId, String rawAlias) {
    final alias = normalizeChatThreadAlias(rawAlias);
    if (!isSafeChatIdentifier(threadId) || alias == null) {
      _fail('CHAT_THREAD_ALIAS_INVALID');
      return false;
    }
    final index = _state.threads.indexWhere(
      (thread) => thread.threadId == threadId && thread.scene == _state.scene,
    );
    if (index < 0) {
      _fail('CHAT_THREAD_NOT_FOUND');
      return false;
    }
    try {
      _aliasRepository?.saveAlias(
        scene: _state.scene,
        threadId: threadId,
        alias: alias,
      );
    } catch (_) {
      _fail('CHAT_THREAD_ALIAS_SAVE_FAILED');
      return false;
    }
    _update(
      _state.copyWith(
        status: ChatControllerStatus.ready,
        threads: <ChatThread>[
          for (final thread in _state.threads)
            if (thread.threadId == threadId)
              thread.copyWith(localAlias: alias)
            else
              thread,
        ],
        clearError: true,
      ),
    );
    unawaited(_rememberThreadTaskSubject(threadId, subjectTitle: alias));
    _persistConversationCache();
    return true;
  }

  Future<void> refreshPendingTask() async {
    final action = _state.nextAction;
    final threadId = _state.activeThreadId;
    if (threadId == null || !ChatControllerPolicies.awaitsAssistant(action)) {
      return;
    }
    await _pollPendingTask(
      threadId: threadId,
      action: action,
      attempts: 1,
      immediate: true,
    );
  }

  Future<void> _pollPendingTask({
    required String threadId,
    required ChatNextAction action,
    required int attempts,
    bool immediate = false,
    String? pendingMessageId,
    String? pendingText,
  }) async {
    if (_isPollingTask || _disposed || attempts <= 0) {
      if (!_disposed && _state.activeThreadId == threadId) {
        _update(_state.copyWith(status: ChatControllerStatus.ready));
      }
      return;
    }
    final pollGeneration = _threadSelectionGeneration;
    _pollingTaskGeneration = pollGeneration;
    bool ownsPoll() =>
        _isCurrentThreadSelection(pollGeneration) &&
        _state.activeThreadId == threadId;
    final existingAssistantIds = <String>{
      for (final message in _state.messages)
        if (message.role == ChatMessageRole.assistant) message.messageId,
    };
    String? lastPollErrorCode;
    var lastPollFailureRetryable = false;
    String? expectedAssistantMessageId;
    String? terminalFailureCode;
    var orphanedThreadReadBack = false;
    var exhaustedPollAttempts = false;
    final trackerOwnsLifecycle = _canDetachAcceptedRun(action);
    try {
      for (var attempt = 0; attempt < attempts; attempt += 1) {
        if (!ownsPoll()) return;
        if (!immediate || attempt > 0) {
          await _waitForTaskPollDelay();
        }
        if (!ownsPoll()) return;

        if (action.type == ChatNextActionType.pollAgentRun) {
          final agentRunId = action.agentRunId;
          if (agentRunId == null || !_assistantRunReader.isAvailable) {
            _finishPendingRunFailure(
              threadId,
              'CHAT_AGENT_RUN_STATUS_UNAVAILABLE',
              clearAction: false,
            );
            return;
          }
          final runResult = await _assistantRunReader.read(agentRunId);
          if (!ownsPoll()) return;
          if (!runResult.ok || runResult.data == null) {
            lastPollErrorCode =
                runResult.errorCode ?? 'CHAT_AGENT_RUN_POLL_FAILED';
            lastPollFailureRetryable = runResult.outcomeUnknown;
            ChatControllerPolicies.debugPollFailure(
              action,
              lastPollErrorCode,
              null,
            );
            continue;
          }
          final run = _projectAssistantRun(runResult.data!);
          if (run.agentRunId != agentRunId ||
              (run.threadId != null && run.threadId != threadId)) {
            _finishPendingRunFailure(
              threadId,
              'CHAT_AGENT_RUN_BINDING_INVALID',
            );
            return;
          }
          lastPollErrorCode = null;
          lastPollFailureRetryable = false;
          _update(
            _state.copyWith(
              status: ChatControllerStatus.sending,
              agentRunStatus: run.status,
              assistantToolTrace: run.assistantToolTrace,
              clearError: true,
            ),
          );
          if (!run.isTerminal) continue;

          _stopAgentProgressProjection(threadId);
          terminalFailureCode = run.terminalFailureCode;
          expectedAssistantMessageId = run.assistantMessageId;
          if (terminalFailureCode != null) {
            _freezeAgentProgressMessage(
              threadId: threadId,
              agentRunId: agentRunId,
              completedAt: run.updatedAt,
            );
          }
          if (expectedAssistantMessageId == null) {
            if (run.status == 'orphaned') {
              orphanedThreadReadBack = true;
            } else {
              _finishPendingRunFailure(
                threadId,
                terminalFailureCode ?? 'CHAT_AGENT_RUN_RESULT_INVALID',
              );
              return;
            }
          }
        }

        final result = await _api.getThreadDetail(threadId: threadId);
        if (!ownsPoll()) return;
        if (!result.ok || result.data == null) {
          lastPollErrorCode = result.error?.code ?? 'CHAT_THREAD_DETAIL_FAILED';
          lastPollFailureRetryable = result.error?.isRetryable ?? true;
          ChatControllerPolicies.debugPollFailure(
            action,
            lastPollErrorCode,
            result.error,
          );
          continue;
        }
        final serverDetail = result.data!;
        if (serverDetail.thread.threadId != threadId) {
          lastPollErrorCode = 'CHAT_THREAD_DETAIL_RESPONSE_INVALID';
          lastPollFailureRetryable = false;
          continue;
        }
        final serverMessages = _projectMessagesForPurpose(
          serverDetail.messages.map(
            (message) => message.copyWith(scene: _state.scene),
          ),
        );
        final hasExpectedAssistant = expectedAssistantMessageId == null
            ? serverMessages.any(
                (message) =>
                    message.role == ChatMessageRole.assistant &&
                    !existingAssistantIds.contains(message.messageId),
              )
            : serverMessages.any(
                (message) =>
                    message.role == ChatMessageRole.assistant &&
                    message.messageId == expectedAssistantMessageId &&
                    !existingAssistantIds.contains(message.messageId),
              );
        final mergedMessages =
            ChatControllerPolicies.mergeServerAndLocalMessages(
              serverMessages,
              _state.messages,
              threadId,
              _state.scene,
              terminalAssistantMessageIdsByRunId: <String, String>{
                ..._terminalAssistantMessageIdsForThread(threadId),
                if (action.agentRunId != null &&
                    expectedAssistantMessageId != null)
                  action.agentRunId!: expectedAssistantMessageId,
              },
            );
        final projectedPendingText = pendingText == null
            ? null
            : _projectUserVisibleText(pendingText).trim();
        final hasDurablePendingText =
            projectedPendingText != null &&
            serverMessages.any(
              (message) =>
                  message.role == ChatMessageRole.user &&
                  message.visibleText?.trim() == projectedPendingText,
            );
        final messages = pendingMessageId != null && hasDurablePendingText
            ? List<ChatMessage>.unmodifiable(<ChatMessage>[
                for (final message in mergedMessages)
                  if (message.messageId != pendingMessageId) message,
              ])
            : mergedMessages;
        _idempotencyStore = result.idempotencyStore;
        lastPollErrorCode = null;
        lastPollFailureRetryable = false;
        _update(
          _state.copyWith(
            status: orphanedThreadReadBack
                ? ChatControllerStatus.failed
                : hasExpectedAssistant
                ? terminalFailureCode == null
                      ? ChatControllerStatus.ready
                      : ChatControllerStatus.failed
                : ChatControllerStatus.sending,
            threads: ChatControllerPolicies.upsertThread(
              _state.threads,
              _withLocalAlias(
                serverDetail.thread.copyWith(
                  scene: _state.scene,
                  purpose: _conversationPurpose,
                  firstUserMessageText:
                      serverDetail.thread.firstUserMessageText ??
                      ChatControllerPolicies.firstUserMessageText(
                        serverMessages,
                      ),
                ),
              ),
            ),
            messages: messages,
            nextAction: hasExpectedAssistant || orphanedThreadReadBack
                ? const ChatNextAction.none()
                : action,
            lastErrorCode: hasExpectedAssistant || orphanedThreadReadBack
                ? terminalFailureCode
                : null,
            clearError:
                !(hasExpectedAssistant || orphanedThreadReadBack) ||
                terminalFailureCode == null,
          ),
        );
        if (hasExpectedAssistant || orphanedThreadReadBack) {
          if (ownsPoll()) {
            _persistConversationCache();
          }
          return;
        }
      }
      exhaustedPollAttempts = true;
    } finally {
      if (_pollingTaskGeneration == pollGeneration) {
        _pollingTaskGeneration = null;
      }
      if (ownsPoll() &&
          ChatControllerPolicies.awaitsAssistant(_state.nextAction) &&
          !(_state.status == ChatControllerStatus.failed &&
              _state.lastErrorCode != null)) {
        final unresolvedTerminalReply = expectedAssistantMessageId != null;
        final trackerWillReconcile =
            trackerOwnsLifecycle &&
            terminalFailureCode == null &&
            ((lastPollErrorCode != null && lastPollFailureRetryable) ||
                (lastPollErrorCode == null && unresolvedTerminalReply));
        final runTimedOut =
            exhaustedPollAttempts &&
            action.type == ChatNextActionType.pollAgentRun &&
            !trackerOwnsLifecycle &&
            lastPollErrorCode == null &&
            !unresolvedTerminalReply;
        _update(
          _state.copyWith(
            status: trackerWillReconcile
                ? ChatControllerStatus.ready
                : lastPollErrorCode != null ||
                      unresolvedTerminalReply ||
                      runTimedOut
                ? ChatControllerStatus.failed
                : ChatControllerStatus.ready,
            lastErrorCode: trackerWillReconcile
                ? null
                : lastPollErrorCode ??
                      (unresolvedTerminalReply
                          ? 'CHAT_AGENT_RUN_REPLY_NOT_PERSISTED'
                          : runTimedOut
                          ? 'CHAT_AGENT_RUN_TIMEOUT'
                          : null),
            clearError:
                trackerWillReconcile ||
                lastPollErrorCode == null &&
                    !unresolvedTerminalReply &&
                    !runTimedOut,
          ),
        );
      }
      _scheduleTerminalReadback();
    }
  }

  _ControllerRunProjection _projectAssistantRun(AssistantRunSnapshot run) {
    return _ControllerRunProjection(
      agentRunId: run.handle.value,
      threadId: run.conversationId,
      status: _assistantStatusValue(run.status),
      isTerminal: run.isTerminal,
      assistantMessageId: run.output?.messageId,
      terminalFailureCode:
          ChatControllerPolicies.assistantRunTerminalFailureCode(run),
      updatedAt: run.updatedAt,
      assistantToolTrace: List<AssistantToolTrace>.unmodifiable(run.toolTrace),
    );
  }

  void _cancelActiveAgentRunReads() {
    _assistantRunReader.cancelActiveReads();
  }

  void _finishPendingRunFailure(
    String threadId,
    String code, {
    bool clearAction = true,
  }) {
    if (_disposed || _state.activeThreadId != threadId) return;
    _update(
      _state.copyWith(
        status: ChatControllerStatus.failed,
        nextAction: clearAction ? const ChatNextAction.none() : null,
        lastErrorCode: code,
      ),
    );
  }

  Future<void> _waitForTaskPollDelay() {
    if (taskPollInterval <= Duration.zero) return Future<void>.value();
    final completer = Completer<void>();
    _taskPollDelayCompleter = completer;
    _taskPollDelayTimer = Timer(taskPollInterval, () {
      _taskPollDelayTimer = null;
      if (identical(_taskPollDelayCompleter, completer)) {
        _taskPollDelayCompleter = null;
      }
      if (!completer.isCompleted) completer.complete();
    });
    return completer.future;
  }

  void _cancelTaskPollDelay() {
    _taskPollDelayTimer?.cancel();
    _taskPollDelayTimer = null;
    final completer = _taskPollDelayCompleter;
    _taskPollDelayCompleter = null;
    if (completer != null && !completer.isCompleted) completer.complete();
  }

  bool resetThreadName(String threadId) {
    if (!isSafeChatIdentifier(threadId)) {
      _fail('CHAT_THREAD_ID_INVALID');
      return false;
    }
    final index = _state.threads.indexWhere(
      (thread) => thread.threadId == threadId && thread.scene == _state.scene,
    );
    if (index < 0) {
      _fail('CHAT_THREAD_NOT_FOUND');
      return false;
    }
    try {
      _aliasRepository?.deleteAlias(scene: _state.scene, threadId: threadId);
    } catch (_) {
      _fail('CHAT_THREAD_ALIAS_DELETE_FAILED');
      return false;
    }
    _update(
      _state.copyWith(
        status: ChatControllerStatus.ready,
        threads: <ChatThread>[
          for (final thread in _state.threads)
            if (thread.threadId == threadId)
              thread.copyWith(clearLocalAlias: true)
            else
              thread,
        ],
        clearError: true,
      ),
    );
    final resetTitle = _state.threads
        .where((thread) => thread.threadId == threadId)
        .firstOrNull
        ?.displayTitle;
    if (resetTitle != null) {
      unawaited(_rememberThreadTaskSubject(threadId, subjectTitle: resetTitle));
    }
    return true;
  }

  bool hideThread(String threadId) {
    if (!isSafeChatIdentifier(threadId)) {
      _fail('CHAT_THREAD_ID_INVALID');
      return false;
    }
    final thread = _state.threads
        .where((candidate) => candidate.threadId == threadId)
        .firstOrNull;
    if (thread == null) {
      _fail('CHAT_THREAD_NOT_FOUND');
      return false;
    }
    try {
      _aliasRepository?.hideThread(scene: _state.scene, threadId: threadId);
    } catch (_) {
      _fail('CHAT_THREAD_HIDE_FAILED');
      return false;
    }
    final remaining = <ChatThread>[
      for (final candidate in _state.threads)
        if (candidate.threadId != threadId) candidate,
    ];
    final activeHidden = _state.activeThreadId == threadId;
    if (activeHidden) {
      _cancelActiveAgentRunReads();
    }
    _cachedMessagesByThread.remove(threadId);
    _update(
      _state.copyWith(
        status: ChatControllerStatus.ready,
        threads: remaining,
        messages: activeHidden ? const <ChatMessage>[] : null,
        clearActiveThreadId: activeHidden,
        nextAction: activeHidden ? const ChatNextAction.none() : null,
        clearAgentActivity: activeHidden,
        clearError: true,
      ),
    );
    _persistConversationCache();
    return true;
  }

  bool restoreHiddenThread(String threadId) {
    if (!isSafeChatIdentifier(threadId)) return false;
    try {
      _aliasRepository?.restoreThread(scene: _state.scene, threadId: threadId);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Observes an already-admitted first turn without issuing another request.
  Future<bool> attachConversationAssetAdmission(
    String conversationAssetId,
  ) async {
    if (_disposed ||
        !isSafeChatIdentifier(conversationAssetId) ||
        _state.activeThreadId != null) {
      return false;
    }
    final entry = _admissionCoordinator?._entryFor(
      scene: _state.scene,
      purpose: _conversationPurpose,
      conversationAssetId: conversationAssetId,
    );
    if (entry == null) return false;
    _projectObservedAdmissionPending(entry);
    _applyObservedAdmissionResult(await entry.future);
    return true;
  }

  /// Abandons only a settled failed first turn; pending work is never cancelled.
  bool discardFailedConversationAssetAdmission(String conversationAssetId) {
    if (!isSafeChatIdentifier(conversationAssetId)) return false;
    return _admissionCoordinator?._discardFailed(
          scene: _state.scene,
          purpose: _conversationPurpose,
          conversationAssetId: conversationAssetId,
        ) ??
        false;
  }

  String reserveTextMessageId() {
    final createdAt = _nowUtc();
    _localMessageCounter += 1;
    return 'local-${createdAt.microsecondsSinceEpoch}-$_localMessageCounter';
  }

  Future<bool> sendText(
    String rawContent, {
    String? contentLineId,
    ChatContextEnvelope? context,
    List<ChatResourceAttachment> resourceAttachments =
        const <ChatResourceAttachment>[],
    List<ChatAssetReference> assetReferences = const <ChatAssetReference>[],
    String? conversationAssetId,
    String? localMessageId,
    bool recoverFailedLocalMessage = false,
    String? createThreadIdempotencyKey,
    String? messageIdempotencyKey,
    ChatBeforeTextMessageSubmit? beforeMessageSubmit,
    ChatTextMessageKnownRejected? onMessageKnownRejected,
  }) async {
    if (activeAgentProfileId == 'positioning_lv1') {
      _fail('BASIC_POSITIONING_USE_ONBOARDING');
      return false;
    }
    if (!_workspaceReady()) {
      _fail('WORKSPACE_NOT_READY');
      return false;
    }
    if (_isThreadAgentScopeUnresolved) {
      _fail('CHAT_THREAD_AGENT_PROFILE_UNRESOLVED');
      return false;
    }
    final content = rawContent.trim();
    final outgoingContext =
        context ??
        ChatContextEnvelope.create(
          purpose: _conversationPurpose.contextPurpose,
          contentLineId: contentLineId,
          entryPoint: const ChatContextEntryPoint(surface: 'chat'),
          includeAccountProfile: true,
        );
    if (outgoingContext == null ||
        (content.isEmpty && !_hasCanonicalInputReference(outgoingContext)) ||
        content.length > ChatControllerPolicies.maxTextLength) {
      _fail('CHAT_TEXT_INVALID');
      return false;
    }
    if (contentLineId != null && !isSafeChatIdentifier(contentLineId)) {
      _fail('CHAT_CONTENT_LINE_ID_INVALID');
      return false;
    }
    if (assetReferences.any((reference) => !reference.isValid)) {
      _fail('CHAT_ASSET_REFERENCE_INVALID');
      return false;
    }
    if (conversationAssetId != null &&
        !isSafeChatIdentifier(conversationAssetId)) {
      _fail('CHAT_CONVERSATION_ASSET_ID_INVALID');
      return false;
    }
    final normalizedCreateThreadKey = createThreadIdempotencyKey?.trim();
    final normalizedMessageKey = messageIdempotencyKey?.trim();
    if ((createThreadIdempotencyKey != null &&
            (normalizedCreateThreadKey == null ||
                !isSafeChatIdentifier(normalizedCreateThreadKey))) ||
        (messageIdempotencyKey != null &&
            (normalizedMessageKey == null ||
                !isSafeChatIdentifier(normalizedMessageKey)))) {
      _fail('CHAT_IDEMPOTENCY_KEY_INVALID');
      return false;
    }
    final reservedMessageId = localMessageId?.trim();
    final existingReservedMessage = reservedMessageId == null
        ? null
        : _state.messages
              .where((message) => message.messageId == reservedMessageId)
              .firstOrNull;
    final recoversFailedMessage =
        recoverFailedLocalMessage &&
        reservedMessageId != null &&
        !_textSubmissionEnvelopes.containsKey(reservedMessageId) &&
        _state.turnState.phase == ChatTurnPhase.failed &&
        _state.turnState.userMessageId == reservedMessageId &&
        existingReservedMessage?.role == ChatMessageRole.user &&
        existingReservedMessage?.contentType == ChatMessageContentType.text &&
        existingReservedMessage?.localDelivery ==
            ChatLocalDeliveryState.failed &&
        (_state.activeThreadId == null ||
            existingReservedMessage?.threadId == _state.activeThreadId);
    if (reservedMessageId != null &&
        (!isSafeChatIdentifier(reservedMessageId) ||
            _textSubmissionEnvelopes.containsKey(reservedMessageId) ||
            (existingReservedMessage != null && !recoversFailedMessage))) {
      _fail('CHAT_LOCAL_MESSAGE_ID_INVALID');
      return false;
    }
    if (resourceAttachments.any(
      (attachment) =>
          !_isValidOutgoingResourceAttachment(attachment, outgoingContext),
    )) {
      _fail('CHAT_RESOURCE_ATTACHMENT_INVALID');
      return false;
    }
    if (!_state.canSubmitUserTurn) return false;

    final pendingImages =
        List<ChatImageAttachment>.unmodifiable(<ChatImageAttachment>[
          for (final reference in outgoingContext.references)
            if (reference.type == ChatContextReferenceType.image)
              ChatImageAttachment(resourceId: reference.id),
        ]);
    final pendingAssetReferences = List<ChatAssetReference>.unmodifiable(
      assetReferences,
    );
    final pendingResourceAttachments =
        List<ChatResourceAttachment>.unmodifiable(resourceAttachments);
    final pendingContent = content.isEmpty
        ? pendingImages.isNotEmpty
              ? '已发送 ${pendingImages.length} 张图片'
              : '已发送 ${outgoingContext.references.length} 项资料'
        : content;
    final firstAdmissionFingerprint = conversationAssetId == null
        ? null
        : _firstConversationAdmissionFingerprint(
            content: content,
            contentLineId: contentLineId,
            context: outgoingContext,
            imageAttachments: pendingImages,
            resourceAttachments: pendingResourceAttachments,
            assetReferences: pendingAssetReferences,
            agentProfileId: activeAgentProfileId,
          );
    if (conversationAssetId != null && _state.activeThreadId == null) {
      final existing = _admissionCoordinator?._entryFor(
        scene: _state.scene,
        purpose: _conversationPurpose,
        conversationAssetId: conversationAssetId,
      );
      if (existing != null) {
        if (existing.fingerprint != firstAdmissionFingerprint) {
          _fail('CHAT_CONVERSATION_ASSET_ADMISSION_CONFLICT');
          return false;
        }
        _projectObservedAdmissionPending(existing);
        return _applyObservedAdmissionResult(await existing.future);
      }
    }
    var pending = recoversFailedMessage
        ? existingReservedMessage!.copyWith(
            status: 'pending',
            textPreview: _projectUserVisibleText(pendingContent),
            imageAttachments: pendingImages,
            resourceAttachments: pendingResourceAttachments,
            assetReferences: pendingAssetReferences,
            localDelivery: ChatLocalDeliveryState.pending,
            localFailureCanAbandon: false,
          )
        : _pendingMessage(
            _state.activeThreadId,
            _projectUserVisibleText(pendingContent),
            messageId: reservedMessageId,
            imageAttachments: pendingImages,
            resourceAttachments: pendingResourceAttachments,
            assetReferences: pendingAssetReferences,
          );
    final submission = _ValidatedTextSubmission(
      messageId: pending.messageId,
      content: content,
      pendingContent: pendingContent,
      contentLineId: contentLineId,
      context: outgoingContext,
      imageAttachments: pendingImages,
      resourceAttachments: pendingResourceAttachments,
      assetReferences: pendingAssetReferences,
      conversationAssetId: conversationAssetId,
      agentProfileId: activeAgentProfileId,
      createThreadIdempotency: IdempotencyRequestContext(
        explicitKey: normalizedCreateThreadKey,
        operation: 'chat.${_state.scene.apiValue}.create_thread',
        businessEntityId: contentLineId ?? _state.scene.apiValue,
        localDraftId: pending.messageId,
        scene: _state.scene.apiValue,
        automaticRetry: true,
      ),
      messageIdempotencyKey: normalizedMessageKey,
      beforeMessageSubmit: beforeMessageSubmit,
      onMessageKnownRejected: onMessageKnownRejected,
    );
    _abandonableFailedTextMessageIds.remove(pending.messageId);
    _rememberTextSubmission(submission);
    _threadSelectionGeneration += 1;
    _update(
      _state.copyWith(
        status: ChatControllerStatus.sending,
        messages: <ChatMessage>[
          for (final message in _state.messages)
            if (message.messageId != pending.messageId) message,
          pending,
        ],
        clearAgentActivity: true,
        clearError: true,
      ),
    );
    return _submitValidatedText(
      submission,
      pending,
      preserveMessageId: reservedMessageId != null,
    );
  }

  bool canRetryFailedTextMessage(String messageId) {
    if (_disposed ||
        _state.isSending ||
        _state.isLoading ||
        _failedTextAbandonInFlight.contains(messageId)) {
      return false;
    }
    if (_state.turnState.phase != ChatTurnPhase.failed ||
        _state.turnState.userMessageId != messageId) {
      return false;
    }
    final submission = _textSubmissionEnvelopes[messageId];
    if (submission == null) return false;
    final message = _state.messages
        .where((candidate) => candidate.messageId == messageId)
        .firstOrNull;
    if (message == null ||
        message.role != ChatMessageRole.user ||
        message.contentType != ChatMessageContentType.text ||
        message.localDelivery != ChatLocalDeliveryState.failed) {
      return false;
    }
    final threadId = submission.threadId;
    return threadId == null ||
        (_state.activeThreadId == threadId && message.threadId == threadId);
  }

  bool canAbandonFailedTextMessage(
    String messageId, {
    bool hasDurableNonAdmissionProof = false,
  }) {
    if (_disposed ||
        _state.isSending ||
        _state.isLoading ||
        _failedTextAbandonInFlight.contains(messageId)) {
      return false;
    }
    if (_state.turnState.phase != ChatTurnPhase.failed ||
        _state.turnState.userMessageId != messageId) {
      return false;
    }
    final message = _state.messages
        .where((candidate) => candidate.messageId == messageId)
        .firstOrNull;
    return message?.role == ChatMessageRole.user &&
        message?.contentType == ChatMessageContentType.text &&
        message?.localDelivery == ChatLocalDeliveryState.failed &&
        (message?.localFailureCanAbandon == true ||
            hasDurableNonAdmissionProof);
  }

  Future<bool> abandonFailedTextMessage(
    String messageId, {
    bool hasDurableNonAdmissionProof = false,
  }) async {
    if (!canAbandonFailedTextMessage(
      messageId,
      hasDurableNonAdmissionProof: hasDurableNonAdmissionProof,
    )) {
      return false;
    }
    _failedTextAbandonInFlight.add(messageId);
    try {
      final submission = _textSubmissionEnvelopes[messageId];
      final conversationAssetId = submission?.conversationAssetId;
      final coordinator = _admissionCoordinator;
      if (conversationAssetId != null &&
          coordinator != null &&
          !coordinator._canDiscardFailed(
            scene: _state.scene,
            purpose: _conversationPurpose,
            conversationAssetId: conversationAssetId,
          )) {
        return false;
      }

      final retainedMessages = List<ChatMessage>.unmodifiable(<ChatMessage>[
        for (final message in _state.messages)
          if (message.messageId != messageId) message,
      ]);
      final activeThreadId = _state.activeThreadId;
      final retainedMessagesByThread = <String, List<ChatMessage>>{
        for (final entry in _cachedMessagesByThread.entries)
          entry.key: entry.value,
        if (activeThreadId != null) activeThreadId: retainedMessages,
      };
      final repository = _aliasRepository;
      if (repository != null) {
        _conversationCachePersistTimer?.cancel();
        _conversationCachePersistTimer = null;
        _conversationCachePersistPending = false;
        _conversationCacheCommitInFlight = true;
        final persisted = await repository.saveConversationCacheDurably(
          scene: _state.scene,
          purpose: _conversationPurpose,
          agentProfileId: _conversationCacheAgentProfileId,
          threads: _state.threads,
          messagesByThread: retainedMessagesByThread,
          historySyncedAt: _historySyncedAt,
          historyComplete: _historySnapshotComplete,
          detailSyncedAtByThread: _threadDetailSyncedAt,
          savedAt: _nowUtc(),
        );
        _conversationCacheCommitInFlight = false;
        if (!persisted) {
          if (_conversationCachePersistPending) _persistConversationCache();
          return false;
        }
      }

      if (conversationAssetId != null && coordinator != null) {
        coordinator._discardFailed(
          scene: _state.scene,
          purpose: _conversationPurpose,
          conversationAssetId: conversationAssetId,
        );
      }
      if (activeThreadId != null) {
        _cachedMessagesByThread[activeThreadId] = retainedMessages;
      }
      _textSubmissionEnvelopes.remove(messageId);
      _abandonableFailedTextMessageIds.remove(messageId);
      final stillOwnsVisibleTurn =
          _state.activeThreadId == activeThreadId &&
          _state.turnState.phase == ChatTurnPhase.failed &&
          _state.turnState.userMessageId == messageId &&
          _state.messages.any((message) => message.messageId == messageId);
      if (stillOwnsVisibleTurn) {
        _update(
          _state.copyWith(
            status: ChatControllerStatus.ready,
            messages: retainedMessages,
            nextAction: const ChatNextAction.none(),
            clearAgentActivity: true,
            clearError: true,
          ),
        );
      }
      if (repository == null) {
        _persistConversationCache();
      } else if (_conversationCachePersistPending) {
        _persistConversationCache();
      }
      return true;
    } finally {
      _conversationCacheCommitInFlight = false;
      _failedTextAbandonInFlight.remove(messageId);
    }
  }

  Future<bool> retryFailedTextMessage(String messageId) async {
    if (!canRetryFailedTextMessage(messageId)) return false;
    _threadSelectionGeneration += 1;
    _abandonableFailedTextMessageIds.remove(messageId);
    final submission = _textSubmissionEnvelopes[messageId]!;
    final conversationAssetId = submission.conversationAssetId;
    if (conversationAssetId != null) {
      _admissionCoordinator?._forgetFailed(
        scene: _state.scene,
        purpose: _conversationPurpose,
        conversationAssetId: conversationAssetId,
      );
    }
    final failed = _state.messages
        .where((message) => message.messageId == messageId)
        .first;
    final pending = failed.copyWith(
      status: 'pending',
      textPreview: _projectUserVisibleText(submission.pendingContent),
      imageAttachments: submission.imageAttachments,
      resourceAttachments: submission.resourceAttachments,
      assetReferences: submission.assetReferences,
      localDelivery: ChatLocalDeliveryState.pending,
      localFailureCanAbandon: false,
    );
    _update(
      _state.copyWith(
        status: ChatControllerStatus.sending,
        messages: <ChatMessage>[
          for (final message in _state.messages)
            if (message.messageId == messageId) pending else message,
        ],
        clearAgentActivity: true,
        clearError: true,
      ),
    );
    _persistConversationCache();
    return _submitValidatedText(submission, pending, preserveMessageId: true);
  }

  Future<bool> _submitValidatedText(
    _ValidatedTextSubmission submission,
    ChatMessage pending, {
    required bool preserveMessageId,
  }) async {
    final conversationAssetId = submission.conversationAssetId;
    final coordinator = _admissionCoordinator;
    if (coordinator != null &&
        conversationAssetId != null &&
        submission.threadId == null &&
        _state.activeThreadId == null) {
      final fingerprint = _firstConversationAdmissionFingerprint(
        content: submission.content,
        contentLineId: submission.contentLineId,
        context: submission.context,
        imageAttachments: submission.imageAttachments,
        resourceAttachments: submission.resourceAttachments,
        assetReferences: submission.assetReferences,
        agentProfileId: submission.agentProfileId,
      );
      final capture = _FirstConversationAdmissionCapture(
        submission: submission,
        pending: pending,
        preserveMessageId: preserveMessageId,
      );
      final claim = coordinator._claim(
        scene: _state.scene,
        purpose: _conversationPurpose,
        conversationAssetId: conversationAssetId,
        fingerprint: fingerprint,
        submission: submission,
        pending: pending,
        preserveMessageId: preserveMessageId,
        operation: () async {
          var accepted = false;
          try {
            accepted = await _submitValidatedTextUncoordinated(
              submission,
              pending,
              preserveMessageId: preserveMessageId,
              admissionCapture: capture,
            );
          } catch (_) {
            capture.errorCode ??= 'CHAT_SEND_FAILED';
            capture.failedTurnIsAbandonable = false;
            _replacePendingWithFailed(
              capture.pending,
              capture.errorCode!,
              safeToAbandon: false,
            );
          }
          return capture.result(
            accepted: accepted,
            idempotencyStore: _idempotencyStore,
          );
        },
      );
      if (claim.disposition ==
          _FirstConversationAdmissionDisposition.conflict) {
        _removeRejectedOptimisticMessage(pending.messageId);
        _fail('CHAT_CONVERSATION_ASSET_ADMISSION_CONFLICT');
        return false;
      }
      if (claim.disposition == _FirstConversationAdmissionDisposition.joined) {
        _removeRejectedOptimisticMessage(pending.messageId);
        _projectObservedAdmissionPending(claim.entry);
        return _applyObservedAdmissionResult(await claim.entry.future);
      }
      return (await claim.entry.future).accepted;
    }
    return _submitValidatedTextUncoordinated(
      submission,
      pending,
      preserveMessageId: preserveMessageId,
    );
  }

  Future<bool> _submitValidatedTextUncoordinated(
    _ValidatedTextSubmission submission,
    ChatMessage pending, {
    required bool preserveMessageId,
    _FirstConversationAdmissionCapture? admissionCapture,
  }) async {
    final threadId = await _ensureActiveThread(
      contentLineId: submission.contentLineId,
      provisionalMessageId: pending.messageId,
      idempotency: submission.createThreadIdempotency,
      admissionCapture: admissionCapture,
    );
    if (threadId == null) {
      admissionCapture?.errorCode ??=
          _state.lastErrorCode ?? 'CHAT_CREATE_THREAD_FAILED';
      _replacePendingWithFailed(
        pending,
        _state.lastErrorCode ?? 'CHAT_CREATE_THREAD_FAILED',
        safeToAbandon: admissionCapture?.failedTurnIsAbandonable,
      );
      return false;
    }
    final coordinator = _admissionCoordinator;
    final threadTurnLease = coordinator?._tryAcquireThreadTurn(
      scene: _state.scene,
      purpose: _conversationPurpose,
      threadId: threadId,
    );
    if (coordinator != null && threadTurnLease == null) {
      admissionCapture?.errorCode = 'CHAT_THREAD_TURN_IN_PROGRESS';
      _removeRejectedOptimisticMessage(pending.messageId);
      _fail('CHAT_THREAD_TURN_IN_PROGRESS');
      return false;
    }
    try {
      final admission = _accountThreadTurnAdmissionError(threadId);
      final admissionError = admission is Future<String?>
          ? await admission
          : admission;
      if (admission is Future<String?> &&
          admissionCapture == null &&
          (_disposed || _state.activeThreadId != threadId)) {
        return false;
      }
      if (admissionError != null) {
        admissionCapture?.errorCode = admissionError;
        _removeRejectedOptimisticMessage(pending.messageId);
        _fail(admissionError);
        return false;
      }
      if (pending.threadId != threadId) {
        pending = pending.copyWith(threadId: threadId);
        admissionCapture?.pending = pending;
      }
      final sendIdempotency =
          submission.sendIdempotency ??
          IdempotencyRequestContext(
            explicitKey: submission.messageIdempotencyKey,
            operation: 'chat.${_state.scene.apiValue}.send_text',
            businessEntityId: threadId,
            localDraftId: pending.messageId,
            scene: _state.scene.apiValue,
            automaticRetry: true,
          );
      submission = submission.bindToThread(threadId, sendIdempotency);
      admissionCapture?.submission = submission;
      _rememberTextSubmission(submission);
      final bindingError = _persistConversationAssetReference(
        threadId,
        submission.conversationAssetId,
      );
      if (bindingError != null) {
        admissionCapture?.errorCode = bindingError;
        if (admissionCapture != null) {
          admissionCapture.failedTurnIsAbandonable = true;
        }
        _replacePendingWithFailed(pending, bindingError, safeToAbandon: true);
        return false;
      }
      final checkpoint = submission.beforeMessageSubmit;
      if (checkpoint != null) {
        var checkpointed = false;
        try {
          checkpointed = await checkpoint(threadId);
        } catch (_) {
          checkpointed = false;
        }
        if (!checkpointed) {
          const errorCode = 'CHAT_TEXT_ADMISSION_CHECKPOINT_FAILED';
          admissionCapture?.errorCode = errorCode;
          if (admissionCapture != null) {
            admissionCapture.failedTurnIsAbandonable = true;
          }
          _replacePendingWithFailed(pending, errorCode, safeToAbandon: true);
          return false;
        }
      }
      // Persist the optimistic turn before awaiting transport. A page can be
      // rebuilt while the server is admitting the message, and the durable
      // cache is the only local proof of the user's accepted intent until the
      // thread detail catches up.
      _persistConversationCache();
      final result = await _api.sendTextMessage(
        threadId: threadId,
        scene: _state.scene,
        content: submission.content,
        contentLineId: submission.contentLineId,
        context: submission.context,
        agentProfileId: submission.agentProfileId,
        idempotency: sendIdempotency,
        idempotencyStore: _idempotencyStore,
      );
      _idempotencyStore = result.idempotencyStore;
      ChatControllerPolicies.debugTransport('text-submit', result);
      if (!result.ok || result.data == null) {
        final safelyRejected =
            chatTextSubmissionFailureDisposition(result) ==
            ChatSubmissionFailureDisposition.knownRejected;
        if (safelyRejected) {
          await _notifyTextMessageKnownRejected(submission);
        }
        admissionCapture?.errorCode = result.error?.code ?? 'CHAT_SEND_FAILED';
        if (admissionCapture != null) {
          admissionCapture.failedTurnIsAbandonable = safelyRejected;
        }
        _replacePendingWithFailed(
          pending,
          result.error?.code ?? 'CHAT_SEND_FAILED',
          safeToAbandon: safelyRejected,
        );
        return false;
      }

      final mutation = result.data!;
      _invalidateRuntimeInvocation(threadId);
      ChatControllerPolicies.debugAcceptedAgentRun(mutation.nextAction);
      _lockAgentProfileForThread(threadId);
      final acknowledgedMessage = mutation.message;
      if (acknowledgedMessage != null &&
          (acknowledgedMessage.threadId != threadId ||
              acknowledgedMessage.scene != _state.scene ||
              acknowledgedMessage.role != ChatMessageRole.user)) {
        admissionCapture?.errorCode = 'CHAT_MUTATION_RESPONSE_INVALID';
        if (admissionCapture != null) {
          admissionCapture.failedTurnIsAbandonable = false;
        }
        _replacePendingWithFailed(
          pending,
          'CHAT_MUTATION_RESPONSE_INVALID',
          safeToAbandon: false,
        );
        return false;
      }
      admissionCapture?.mutation = mutation;
      final receivedAt = _nowUtc();
      final serverMessage = acknowledgedMessage?.copyWith(
        messageId: preserveMessageId ? pending.messageId : null,
        textPreview: _projectUserVisibleText(
          submission.content.isNotEmpty
              ? submission.content
              : acknowledgedMessage.visibleText?.trim().isNotEmpty == true
              ? acknowledgedMessage.visibleText!
              : submission.pendingContent,
        ),
        imageAttachments: acknowledgedMessage.imageAttachments.isEmpty
            ? pending.imageAttachments
            : acknowledgedMessage.imageAttachments,
        resourceAttachments: acknowledgedMessage.resourceAttachments.isEmpty
            ? pending.resourceAttachments
            : acknowledgedMessage.resourceAttachments,
        assetReferences: acknowledgedMessage.assetReferences.isEmpty
            ? pending.assetReferences
            : acknowledgedMessage.assetReferences,
        createdAt: acknowledgedMessage.createdAt ?? pending.createdAt,
        localDelivery: ChatLocalDeliveryState.server,
      );
      final assistant =
          ChatControllerPolicies.awaitsAssistant(mutation.nextAction)
          ? null
          : mutation.assistantMessage?.copyWith(
              createdAt: mutation.assistantMessage?.createdAt ?? receivedAt,
            );
      final messages = <ChatMessage>[
        for (final message in _state.messages)
          if (message.messageId == pending.messageId && serverMessage != null)
            serverMessage
          else
            message,
        if (assistant != null) assistant,
      ];
      _textSubmissionEnvelopes.remove(pending.messageId);
      _abandonableFailedTextMessageIds.remove(pending.messageId);
      _update(
        _state.copyWith(
          status: _canDetachAcceptedRun(mutation.nextAction)
              ? ChatControllerStatus.ready
              : ChatControllerPolicies.awaitsAssistant(mutation.nextAction)
              ? ChatControllerStatus.sending
              : ChatControllerStatus.ready,
          threads: ChatControllerPolicies.withFirstUserMessage(
            _state.threads,
            threadId,
            _projectUserVisibleText(submission.pendingContent),
            updatedAt:
                serverMessage?.createdAt ?? pending.createdAt ?? receivedAt,
          ),
          messages: ChatControllerPolicies.dedupeMessages(messages),
          nextAction: mutation.nextAction,
          clearError: true,
        ),
      );
      _persistConversationCache();
      _startAgentProgressProjection(threadId, mutation.nextAction);
      await _trackAcceptedRun(threadId, mutation.nextAction);
      if (ChatControllerPolicies.awaitsAssistant(mutation.nextAction)) {
        final poll = _pollPendingTask(
          threadId: threadId,
          action: mutation.nextAction,
          attempts:
              _canDetachAcceptedRun(mutation.nextAction) &&
                  taskPollInterval <= Duration.zero
              ? 1
              : taskPollAttempts,
          pendingMessageId: acknowledgedMessage == null
              ? pending.messageId
              : null,
          pendingText:
              acknowledgedMessage == null && submission.content.isNotEmpty
              ? submission.content
              : null,
        );
        if (_canDetachAcceptedRun(mutation.nextAction)) {
          unawaited(poll);
        } else {
          await poll;
        }
      }
      return true;
    } finally {
      if (threadTurnLease != null) {
        coordinator?._releaseThreadTurn(threadTurnLease);
      }
    }
  }

  void _rememberTextSubmission(_ValidatedTextSubmission submission) {
    _textSubmissionEnvelopes
      ..remove(submission.messageId)
      ..[submission.messageId] = submission;
    while (_textSubmissionEnvelopes.length > _failedTextRetryLimit) {
      final evictedMessageId = _textSubmissionEnvelopes.keys.first;
      _textSubmissionEnvelopes.remove(evictedMessageId);
      _abandonableFailedTextMessageIds.remove(evictedMessageId);
    }
  }

  String _firstConversationAdmissionFingerprint({
    required String content,
    required String? contentLineId,
    required ChatContextEnvelope context,
    required List<ChatImageAttachment> imageAttachments,
    required List<ChatResourceAttachment> resourceAttachments,
    required List<ChatAssetReference> assetReferences,
    required String? agentProfileId,
  }) => jsonEncode(<String, Object?>{
    'content': content,
    'contentLineId': contentLineId,
    'context': context.toJson(),
    'images': <Object?>[
      for (final attachment in imageAttachments)
        <String, Object?>{
          'resourceId': attachment.resourceId,
          'displayName': attachment.displayName,
          'mimeType': attachment.mimeType,
        },
    ],
    'resources': <Object?>[
      for (final attachment in resourceAttachments)
        <String, Object?>{
          'kind': attachment.kind.apiValue,
          'resourceId': attachment.resourceId,
          'displayName': attachment.displayName,
          'mimeType': attachment.mimeType,
          'sizeBytes': attachment.sizeBytes,
        },
    ],
    'assets': <Object?>[
      for (final reference in assetReferences)
        <String, Object?>{
          'assetId': reference.assetId,
          'title': reference.title,
        },
    ],
    'agentProfileId': agentProfileId,
  });

  void _removeRejectedOptimisticMessage(String messageId) {
    _textSubmissionEnvelopes.remove(messageId);
    _abandonableFailedTextMessageIds.remove(messageId);
    _update(
      _state.copyWith(
        messages: <ChatMessage>[
          for (final message in _state.messages)
            if (message.messageId != messageId) message,
        ],
      ),
    );
  }

  void _projectObservedAdmissionPending(
    _FirstConversationAdmissionEntry entry,
  ) {
    if (_disposed || _state.activeThreadId != null) return;
    final pending = _projectMessagesForPurpose(<ChatMessage>[
      entry.pending,
    ]).single;
    _update(
      _state.copyWith(
        status: ChatControllerStatus.sending,
        messages: <ChatMessage>[pending],
        nextAction: const ChatNextAction.none(),
        clearAgentActivity: true,
        clearError: true,
      ),
    );
    _rememberTextSubmission(entry.submission);
  }

  bool _applyObservedAdmissionResult(_FirstConversationAdmissionResult result) {
    if (_disposed) return result.accepted;
    _idempotencyStore = result.idempotencyStore;
    final thread = result.thread;
    if (thread == null) {
      _rememberTextSubmission(result.submission);
      _replacePendingWithFailed(
        result.pending,
        result.errorCode ?? 'CHAT_CREATE_THREAD_FAILED',
        safeToAbandon: result.failedTurnIsAbandonable,
      );
      return false;
    }
    final activeThreadId = _state.activeThreadId;
    if (activeThreadId != null && activeThreadId != thread.threadId) {
      return result.accepted;
    }
    final boundPending = result.pending.threadId == thread.threadId
        ? result.pending
        : result.pending.copyWith(threadId: thread.threadId);
    final pending = _projectMessagesForPurpose(<ChatMessage>[
      boundPending,
    ]).single;
    _update(
      _state.copyWith(
        status: ChatControllerStatus.sending,
        activeThreadId: thread.threadId,
        threads: ChatControllerPolicies.upsertThread(
          _state.threads,
          _withLocalAlias(thread),
        ),
        messages: <ChatMessage>[pending],
        nextAction: const ChatNextAction.none(),
        clearAgentActivity: true,
        clearError: true,
      ),
    );
    _rememberTextSubmission(result.submission);
    if (!result.accepted) {
      _replacePendingWithFailed(
        pending,
        result.errorCode ?? 'CHAT_SEND_FAILED',
        safeToAbandon: result.failedTurnIsAbandonable,
      );
      return false;
    }
    final mutation = result.mutation;
    if (mutation == null) {
      _replacePendingWithFailed(
        pending,
        'CHAT_MUTATION_RESPONSE_INVALID',
        safeToAbandon: false,
      );
      return false;
    }
    _invalidateRuntimeInvocation(thread.threadId);
    _lockAgentProfileForThread(thread.threadId);
    final acknowledgedMessage = mutation.message;
    final receivedAt = _nowUtc();
    final serverMessage = acknowledgedMessage?.copyWith(
      messageId: result.preserveMessageId ? pending.messageId : null,
      textPreview: _projectUserVisibleText(
        result.submission.content.isNotEmpty
            ? result.submission.content
            : acknowledgedMessage.visibleText?.trim().isNotEmpty == true
            ? acknowledgedMessage.visibleText!
            : result.submission.pendingContent,
      ),
      imageAttachments: acknowledgedMessage.imageAttachments.isEmpty
          ? pending.imageAttachments
          : acknowledgedMessage.imageAttachments,
      resourceAttachments: acknowledgedMessage.resourceAttachments.isEmpty
          ? pending.resourceAttachments
          : acknowledgedMessage.resourceAttachments,
      assetReferences: acknowledgedMessage.assetReferences.isEmpty
          ? pending.assetReferences
          : acknowledgedMessage.assetReferences,
      createdAt: acknowledgedMessage.createdAt ?? pending.createdAt,
      localDelivery: ChatLocalDeliveryState.server,
    );
    final assistant =
        ChatControllerPolicies.awaitsAssistant(mutation.nextAction)
        ? null
        : mutation.assistantMessage?.copyWith(
            createdAt: mutation.assistantMessage?.createdAt ?? receivedAt,
          );
    _textSubmissionEnvelopes.remove(pending.messageId);
    _abandonableFailedTextMessageIds.remove(pending.messageId);
    _update(
      _state.copyWith(
        status: _canDetachAcceptedRun(mutation.nextAction)
            ? ChatControllerStatus.ready
            : ChatControllerPolicies.awaitsAssistant(mutation.nextAction)
            ? ChatControllerStatus.sending
            : ChatControllerStatus.ready,
        threads: ChatControllerPolicies.withFirstUserMessage(
          _state.threads,
          thread.threadId,
          _projectUserVisibleText(result.submission.pendingContent),
          updatedAt:
              serverMessage?.createdAt ?? pending.createdAt ?? receivedAt,
        ),
        messages: ChatControllerPolicies.dedupeMessages(<ChatMessage>[
          serverMessage ?? pending,
          if (assistant != null) assistant,
        ]),
        nextAction: mutation.nextAction,
        clearError: true,
      ),
    );
    _persistConversationCache();
    _startAgentProgressProjection(thread.threadId, mutation.nextAction);
    return true;
  }

  bool _hasCanonicalInputReference(ChatContextEnvelope context) =>
      context.references.any(
        (reference) =>
            (reference.type == ChatContextReferenceType.material &&
                reference.revision != null) ||
            reference.type == ChatContextReferenceType.file ||
            reference.type == ChatContextReferenceType.image,
      );

  bool _isValidOutgoingResourceAttachment(
    ChatResourceAttachment attachment,
    ChatContextEnvelope context,
  ) {
    if (!isSafeChatIdentifier(attachment.resourceId) ||
        (attachment.kind != ChatResourceAttachmentKind.file &&
            attachment.kind != ChatResourceAttachmentKind.video)) {
      return false;
    }
    final displayName = attachment.displayName?.trim();
    if (displayName != null &&
        (displayName.isEmpty || displayName.length > 255)) {
      return false;
    }
    final mimeType = attachment.mimeType?.trim();
    if (mimeType != null && (mimeType.isEmpty || mimeType.length > 127)) {
      return false;
    }
    final sizeBytes = attachment.sizeBytes;
    if (sizeBytes != null && sizeBytes <= 0) return false;
    return context.references.any(
      (reference) =>
          reference.type == ChatContextReferenceType.file &&
          reference.id == attachment.resourceId,
    );
  }

  Future<bool> sendVoiceResource({
    required ResourceIndex resource,
    required int durationSeconds,
    String? contentLineId,
    ChatContextEnvelope? context,
  }) async {
    if (activeAgentProfileId == 'positioning_lv1') {
      _fail('BASIC_POSITIONING_USE_ONBOARDING');
      return false;
    }
    if (!_workspaceReady()) {
      _fail('WORKSPACE_NOT_READY');
      return false;
    }
    if (_isThreadAgentScopeUnresolved) {
      _fail('CHAT_THREAD_AGENT_PROFILE_UNRESOLVED');
      return false;
    }
    if (_state.scene != ChatScene.feedAi) {
      _fail('CHAT_VOICE_SCENE_UNSUPPORTED');
      return false;
    }
    if (!_state.canSubmitUserTurn) return false;
    if (contentLineId != null && !isSafeChatIdentifier(contentLineId)) {
      _fail('CHAT_CONTENT_LINE_ID_INVALID');
      return false;
    }
    if (!isSafeChatIdentifier(resource.resourceId) ||
        resource.sourceScene != 'workspace_voice' ||
        resource.sizeBytes <= 0 ||
        !ChatControllerPolicies.isAudioMimeType(resource.mimeType)) {
      _fail('CHAT_VOICE_RESOURCE_INVALID');
      return false;
    }
    if (durationSeconds < 1 ||
        durationSeconds > ChatControllerPolicies.maxVoiceDurationSeconds) {
      _fail('CHAT_VOICE_DURATION_INVALID');
      return false;
    }

    _update(
      _state.copyWith(
        status: ChatControllerStatus.sending,
        clearAgentActivity: true,
        clearError: true,
      ),
    );
    final threadId = await _ensureActiveThread(contentLineId: contentLineId);
    if (threadId == null) return false;

    final coordinator = _admissionCoordinator;
    final threadTurnLease = coordinator?._tryAcquireThreadTurn(
      scene: _state.scene,
      purpose: _conversationPurpose,
      threadId: threadId,
    );
    if (coordinator != null && threadTurnLease == null) {
      _fail('CHAT_THREAD_TURN_IN_PROGRESS');
      return false;
    }
    try {
      final admission = _accountThreadTurnAdmissionError(threadId);
      final admissionError = admission is Future<String?>
          ? await admission
          : admission;
      if (admission is Future<String?> &&
          (_disposed || _state.activeThreadId != threadId)) {
        return false;
      }
      if (admissionError != null) {
        _fail(admissionError);
        return false;
      }

      final pending = _pendingVoiceMessage(threadId);
      _update(
        _state.copyWith(
          status: ChatControllerStatus.sending,
          messages: <ChatMessage>[..._state.messages, pending],
          clearError: true,
        ),
      );
      _persistConversationCache();
      final result = await _api.sendVoiceMessage(
        threadId: threadId,
        scene: _state.scene,
        audioResourceId: resource.resourceId,
        durationSeconds: durationSeconds,
        contentLineId: contentLineId,
        context:
            context ??
            ChatContextEnvelope.create(
              purpose: _conversationPurpose.contextPurpose,
              contentLineId: contentLineId,
              entryPoint: const ChatContextEntryPoint(surface: 'voice_chat'),
              includeAccountProfile: true,
            ),
        idempotency: IdempotencyRequestContext(
          operation: 'chat.${_state.scene.apiValue}.send_voice',
          businessEntityId: threadId,
          localDraftId: pending.messageId,
          scene: _state.scene.apiValue,
        ),
        idempotencyStore: _idempotencyStore,
      );
      _idempotencyStore = result.idempotencyStore;
      ChatControllerPolicies.debugTransport('voice-submit', result);
      if (!result.ok || result.data == null) {
        _replacePendingWithFailed(
          pending,
          result.error?.code ?? 'CHAT_VOICE_SEND_FAILED',
        );
        return false;
      }

      final mutation = result.data!;
      _invalidateRuntimeInvocation(threadId);
      final assistant = mutation.assistantMessage;
      if (mutation.message.threadId != threadId ||
          mutation.message.scene != _state.scene ||
          mutation.message.role != ChatMessageRole.user ||
          mutation.message.contentType != ChatMessageContentType.voice ||
          (assistant != null &&
              (assistant.threadId != threadId ||
                  assistant.scene != _state.scene ||
                  assistant.role != ChatMessageRole.assistant))) {
        _replacePendingWithFailed(
          pending,
          'CHAT_VOICE_MUTATION_RESPONSE_INVALID',
        );
        return false;
      }
      final receivedAt = _nowUtc();
      final serverMessage = mutation.message.copyWith(
        createdAt: mutation.message.createdAt ?? pending.createdAt,
        localDelivery: ChatLocalDeliveryState.server,
      );
      final serverAssistant =
          ChatControllerPolicies.awaitsAssistant(mutation.nextAction)
          ? null
          : assistant?.copyWith(createdAt: assistant.createdAt ?? receivedAt);
      final messages = <ChatMessage>[
        for (final message in _state.messages)
          if (message.messageId == pending.messageId)
            serverMessage
          else
            message,
        if (serverAssistant != null) serverAssistant,
      ];
      _update(
        _state.copyWith(
          status: _canDetachAcceptedRun(mutation.nextAction)
              ? ChatControllerStatus.ready
              : ChatControllerPolicies.awaitsAssistant(mutation.nextAction)
              ? ChatControllerStatus.sending
              : ChatControllerStatus.ready,
          threads: ChatControllerPolicies.withFirstUserMessage(
            _state.threads,
            threadId,
            mutation.message.visibleText ?? '语音消息',
            updatedAt:
                serverMessage.createdAt ?? pending.createdAt ?? receivedAt,
          ),
          messages: ChatControllerPolicies.dedupeMessages(messages),
          nextAction: mutation.nextAction,
          clearError: true,
        ),
      );
      _persistConversationCache();
      _startAgentProgressProjection(threadId, mutation.nextAction);
      await _trackAcceptedRun(threadId, mutation.nextAction);
      if (ChatControllerPolicies.awaitsAssistant(mutation.nextAction)) {
        final poll = _pollPendingTask(
          threadId: threadId,
          action: mutation.nextAction,
          attempts:
              _canDetachAcceptedRun(mutation.nextAction) &&
                  taskPollInterval <= Duration.zero
              ? 1
              : taskPollAttempts,
        );
        if (_canDetachAcceptedRun(mutation.nextAction)) {
          unawaited(poll);
        } else {
          await poll;
        }
      }
      return true;
    } finally {
      if (threadTurnLease != null) {
        coordinator?._releaseThreadTurn(threadTurnLease);
      }
    }
  }

  Future<String?> _ensureActiveThread({
    String? contentLineId,
    String? provisionalMessageId,
    IdempotencyRequestContext? idempotency,
    _FirstConversationAdmissionCapture? admissionCapture,
  }) async {
    if (!_workspaceReady()) {
      admissionCapture?.errorCode = 'WORKSPACE_NOT_READY';
      if (admissionCapture != null) {
        admissionCapture.failedTurnIsAbandonable = true;
      }
      _setFailedTextMessageAbandonable(provisionalMessageId, true);
      _fail('WORKSPACE_NOT_READY');
      return null;
    }
    final activeThreadId = _state.activeThreadId;
    if (activeThreadId != null) return activeThreadId;
    final result = await _api.createThread(
      scene: _state.scene,
      purpose: _conversationPurpose,
      contentLineId: contentLineId,
      idempotency:
          idempotency ??
          IdempotencyRequestContext(
            operation: 'chat.${_state.scene.apiValue}.create_thread',
            businessEntityId: contentLineId ?? _state.scene.apiValue,
            scene: _state.scene.apiValue,
          ),
      idempotencyStore: _idempotencyStore,
    );
    _idempotencyStore = result.idempotencyStore;
    ChatControllerPolicies.debugTransport('thread-create', result);
    if (!result.ok || result.data == null) {
      admissionCapture?.errorCode =
          result.error?.code ?? 'CHAT_CREATE_THREAD_FAILED';
      if (admissionCapture != null) {
        admissionCapture.failedTurnIsAbandonable = true;
      }
      // The Thread outcome can be ambiguous, but this controller has not yet
      // invoked the message endpoint, so the provisional message is known
      // unsent and may be ended locally.
      _setFailedTextMessageAbandonable(provisionalMessageId, true);
      _update(
        _state.copyWith(
          status: ChatControllerStatus.failed,
          lastErrorCode: result.error?.code ?? 'CHAT_CREATE_THREAD_FAILED',
        ),
      );
      return null;
    }
    final thread = result.data!;
    if (thread.scene != _state.scene ||
        thread.purpose != _conversationPurpose ||
        !isSafeChatIdentifier(thread.threadId)) {
      admissionCapture?.errorCode = 'CHAT_CREATE_THREAD_RESPONSE_INVALID';
      if (admissionCapture != null) {
        admissionCapture.failedTurnIsAbandonable = true;
      }
      _setFailedTextMessageAbandonable(provisionalMessageId, true);
      _fail('CHAT_CREATE_THREAD_RESPONSE_INVALID');
      return null;
    }
    if (!_persistCurrentPurpose(thread.threadId)) {
      admissionCapture?.errorCode =
          _state.lastErrorCode ?? 'CHAT_THREAD_PURPOSE_SAVE_FAILED';
      if (admissionCapture != null) {
        admissionCapture.failedTurnIsAbandonable = true;
      }
      _setFailedTextMessageAbandonable(provisionalMessageId, true);
      return null;
    }
    final provisionalCreatedAt = _state.messages
        .where((message) => message.messageId == provisionalMessageId)
        .firstOrNull
        ?.createdAt;
    final locallyTimestampedThread = thread.copyWith(
      updatedAt: thread.updatedAt ?? provisionalCreatedAt ?? _nowUtc(),
      agentProfileId: activeAgentProfileId,
    );
    admissionCapture?.thread = locallyTimestampedThread;
    _update(
      _state.copyWith(
        status: ChatControllerStatus.sending,
        activeThreadId: thread.threadId,
        threads: ChatControllerPolicies.upsertThread(
          _state.threads,
          _withLocalAlias(locallyTimestampedThread),
        ),
        messages: <ChatMessage>[
          for (final message in _state.messages)
            if (message.messageId == provisionalMessageId)
              message.copyWith(threadId: thread.threadId)
            else
              message,
        ],
        clearError: true,
      ),
    );
    _persistConversationCache();
    return thread.threadId;
  }

  ChatMessage _pendingMessage(
    String? threadId,
    String content, {
    String? messageId,
    List<ChatImageAttachment> imageAttachments = const <ChatImageAttachment>[],
    List<ChatResourceAttachment> resourceAttachments =
        const <ChatResourceAttachment>[],
    List<ChatAssetReference> assetReferences = const <ChatAssetReference>[],
  }) {
    final createdAt = _nowUtc();
    final resolvedMessageId = messageId ?? reserveTextMessageId();
    return ChatMessage(
      messageId: resolvedMessageId,
      threadId: threadId ?? 'local-pending-$resolvedMessageId',
      scene: _state.scene,
      role: ChatMessageRole.user,
      contentType: ChatMessageContentType.text,
      status: 'pending',
      textPreview: content,
      imageAttachments: imageAttachments,
      resourceAttachments: resourceAttachments,
      assetReferences: assetReferences,
      createdAt: createdAt,
      localDelivery: ChatLocalDeliveryState.pending,
    );
  }

  ChatMessage _pendingVoiceMessage(String threadId) {
    _localMessageCounter += 1;
    final createdAt = _nowUtc();
    return ChatMessage(
      messageId:
          'local-${createdAt.microsecondsSinceEpoch}-$_localMessageCounter',
      threadId: threadId,
      scene: _state.scene,
      role: ChatMessageRole.user,
      contentType: ChatMessageContentType.voice,
      status: 'pending',
      createdAt: createdAt,
      localDelivery: ChatLocalDeliveryState.pending,
    );
  }

  void _setFailedTextMessageAbandonable(String? messageId, bool value) {
    if (messageId == null) return;
    if (value) {
      _abandonableFailedTextMessageIds.add(messageId);
    } else {
      _abandonableFailedTextMessageIds.remove(messageId);
    }
  }

  Future<void> _notifyTextMessageKnownRejected(
    _ValidatedTextSubmission submission,
  ) async {
    final callback = submission.onMessageKnownRejected;
    if (callback == null) return;
    try {
      await callback();
    } catch (_) {
      // Delivery certainty remains valid even if caller-owned recovery storage
      // is temporarily unavailable.
    }
  }

  void _replacePendingWithFailed(
    ChatMessage pending,
    String errorCode, {
    bool? safeToAbandon,
  }) {
    var resolvedSafeToAbandon = false;
    if (pending.contentType == ChatMessageContentType.text) {
      if (safeToAbandon != null) {
        _setFailedTextMessageAbandonable(pending.messageId, safeToAbandon);
      }
      resolvedSafeToAbandon =
          safeToAbandon ??
          _abandonableFailedTextMessageIds.contains(pending.messageId);
    }
    final failed = pending.copyWith(
      status: 'failed',
      localDelivery: ChatLocalDeliveryState.failed,
      localFailureCanAbandon: resolvedSafeToAbandon,
    );
    _abandonableFailedTextMessageIds.remove(pending.messageId);
    _update(
      _state.copyWith(
        status: ChatControllerStatus.failed,
        messages: <ChatMessage>[
          for (final message in _state.messages)
            if (message.messageId == pending.messageId) failed else message,
        ],
        lastErrorCode: errorCode,
      ),
    );
    _persistConversationCache();
  }

  void _fail(String code) {
    _update(
      _state.copyWith(status: ChatControllerStatus.failed, lastErrorCode: code),
    );
  }

  void _rejectThreadSelection(
    ChatControllerState previousSelection,
    String code,
  ) {
    _update(
      ChatControllerState(
        scene: _state.scene,
        status: ChatControllerStatus.failed,
        threads: _state.threads,
        messages: previousSelection.messages,
        activeThreadId: previousSelection.activeThreadId,
        nextCursor: _state.nextCursor,
        nextAction: previousSelection.nextAction,
        agentRunStatus: previousSelection.agentRunStatus,
        assistantToolTrace: previousSelection.assistantToolTrace,
        turnState: previousSelection.turnState,
        lastErrorCode: code,
      ),
    );
    final previousThreadId = previousSelection.activeThreadId;
    if (previousThreadId != null) {
      _resumeAgentProgressProjection(previousThreadId);
    }
  }

  DateTime _nowUtc() => (_now ?? DateTime.now)().toUtc();

  Future<void> _trackAcceptedRun(String threadId, ChatNextAction action) async {
    if (action.type != ChatNextActionType.pollAgentRun) return;
    final agentRunId = action.agentRunId;
    if (agentRunId == null) return;
    final tracker = _runTracker;
    await _rememberThreadTaskSubject(threadId);
    if (tracker is ChatAcceptedRunTrackingPort) {
      final acceptedTracker = tracker as ChatAcceptedRunTrackingPort;
      await acceptedTracker.trackAcceptedRun(
        agentRunId: agentRunId,
        publicTaskId: action.taskId,
        threadId: threadId,
        scene: _state.scene,
        purpose: _conversationPurpose,
      );
      return;
    }
    await (tracker?.track(
          agentRunId: agentRunId,
          threadId: threadId,
          scene: _state.scene,
          purpose: _conversationPurpose,
        ) ??
        Future<void>.value());
  }

  void _startAgentProgressProjection(String threadId, ChatNextAction action) {
    if (_disposed) return;
    final agentRunId = action.agentRunId;
    if (action.type != ChatNextActionType.pollAgentRun ||
        agentRunId == null ||
        !isSafeChatIdentifier(threadId)) {
      return;
    }
    _stopAgentProgressProjection();
    _agentProgressThreadId = threadId;
    _agentProgressRunId = agentRunId;
    _agentProgressSequence = 0;
    _agentProgressSseSequence = 0;
    final snapshot = _runDraftSnapshotSource?.draftSnapshotFor(
      threadId: threadId,
      agentRunId: agentRunId,
    );
    if (snapshot != null &&
        snapshot.scene == _state.scene &&
        snapshot.purpose == _conversationPurpose) {
      _agentProgressSseSequence = snapshot.eventSequence;
      _agentProgressTransport = _AgentProgressTransport.agentRunSse;
      _appendAgentProgressDelta(
        threadId,
        agentRunId,
        snapshot.text,
        replace: true,
      );
    }
    if (_runDraftDeltaSource != null) {
      final hasRetainedDraft =
          snapshot != null ||
          _state.messages.any(
            (message) => message.messageId == 'stream-$agentRunId',
          );
      _captureLatestRunDraftDelta(allowReplay: !hasRetainedDraft);
      if (_agentProgressTransport == null) {
        _agentProgressFallbackTimer = Timer(
          _agentProgressSsePreference,
          () => _startThreadProgressFallback(threadId, agentRunId),
        );
      } else if (snapshot != null) {
        _armAgentProgressFallback(threadId, agentRunId);
      }
      return;
    }
    _startThreadProgressFallback(threadId, agentRunId);
  }

  void _startThreadProgressFallback(String threadId, String agentRunId) {
    if (_disposed ||
        _agentProgressThreadId != threadId ||
        _agentProgressRunId != agentRunId ||
        _state.activeThreadId != threadId ||
        _agentProgressTransport == _AgentProgressTransport.agentRunSse) {
      return;
    }
    final assistantProgress = _assistantProgress;
    if (assistantProgress == null) return;
    final poller = _threadProgressPoller;
    if (poller == null) {
      unawaited(_readAssistantAgentProgress(assistantProgress));
      return;
    }
    poller.start(
      threadId: threadId,
      agentRunId: agentRunId,
      attempt: () async {
        if (!_canPollAgentProgress(threadId, agentRunId)) return false;
        await _readAssistantAgentProgress(assistantProgress);
        return _canPollAgentProgress(threadId, agentRunId);
      },
    );
  }

  void _armAgentProgressFallback(String threadId, String agentRunId) {
    _agentProgressFallbackTimer?.cancel();
    _agentProgressFallbackTimer = Timer(_agentProgressSsePreference, () {
      _agentProgressFallbackTimer = null;
      if (_disposed ||
          _agentProgressThreadId != threadId ||
          _agentProgressRunId != agentRunId ||
          _state.activeThreadId != threadId ||
          _agentProgressTransport != _AgentProgressTransport.agentRunSse) {
        return;
      }
      _agentProgressTransport = null;
      _startThreadProgressFallback(threadId, agentRunId);
    });
  }

  bool _canPollAgentProgress(String threadId, String agentRunId) =>
      !_disposed &&
      _agentProgressThreadId == threadId &&
      _agentProgressRunId == agentRunId &&
      _state.activeThreadId == threadId &&
      _agentProgressTransport != _AgentProgressTransport.agentRunSse;

  Future<void> _readAssistantAgentProgress(
    AssistantThreadProgressPort progress,
  ) async {
    return _readProgressBatch(({
      required String threadId,
      required String runHandle,
      required int afterSequence,
    }) {
      return readAssistantThreadProgress(
        progress: progress,
        conversationId: threadId,
        runHandle: AssistantRunHandle(runHandle),
        afterSequence: afterSequence,
      );
    });
  }

  Future<void> _readProgressBatch(_AgentProgressBatchReader readBatch) async {
    if (_disposed ||
        _agentProgressReadInFlight ||
        _agentProgressThreadId == null ||
        _agentProgressRunId == null) {
      return;
    }
    final threadId = _agentProgressThreadId!;
    final agentRunId = _agentProgressRunId!;
    if (_state.activeThreadId != threadId) {
      _stopAgentProgressProjection();
      return;
    }
    final afterSequence = _agentProgressSequence;
    _agentProgressReadInFlight = true;
    try {
      final batch = await readBatch(
        threadId: threadId,
        runHandle: agentRunId,
        afterSequence: afterSequence,
      );
      if (_disposed ||
          _agentProgressThreadId != threadId ||
          _agentProgressRunId != agentRunId ||
          _state.activeThreadId != threadId) {
        return;
      }
      if (batch == null ||
          _agentProgressTransport == _AgentProgressTransport.agentRunSse) {
        return;
      }
      _agentProgressSequence = batch.nextSequence;
      _applyAgentProgressBatch(threadId, agentRunId, batch.deltas);
      if (batch.deltas.isNotEmpty) _scheduleConversationCachePersist();
    } finally {
      _agentProgressReadInFlight = false;
    }
  }

  void _applyAgentProgressBatch(
    String threadId,
    String agentRunId,
    List<ChatThreadProgressDelta> deltas,
  ) {
    if (deltas.isEmpty) return;
    final previousTransport = _agentProgressTransport;
    _agentProgressTransport = _AgentProgressTransport.threadEvents;

    final lastReplacement = deltas.lastIndexWhere((delta) => delta.replace);
    if (lastReplacement >= 0) {
      final target = StringBuffer(deltas[lastReplacement].text);
      for (final delta in deltas.skip(lastReplacement + 1)) {
        target.write(delta.text);
      }
      _appendAgentProgressDelta(
        threadId,
        agentRunId,
        target.toString(),
        replace: true,
      );
      return;
    }

    final incoming = deltas.map((delta) => delta.text).join();
    final delta = previousTransport == _AgentProgressTransport.agentRunSse
        ? _unseenCrossTransportSuffix(
            _agentProgressRevealBuffers[agentRunId]?.targetText ?? '',
            incoming,
          )
        : incoming;
    if (delta.isNotEmpty) {
      _appendAgentProgressDelta(threadId, agentRunId, delta);
    }
  }

  void _appendAgentProgressDelta(
    String threadId,
    String agentRunId,
    String delta, {
    bool replace = false,
  }) {
    final existing = _agentProgressRevealBuffers[agentRunId];
    if (existing != null) {
      existing.ingest(delta, replace: replace);
      _publishAssistantAnswerDraft(
        threadId: threadId,
        agentRunId: agentRunId,
        visibleText: existing.visibleText,
        targetText: existing.targetText,
        source: ChatAssistantAnswerDraftSource.transportDelta,
      );
      _storeAgentProgressTarget(
        threadId: threadId,
        agentRunId: agentRunId,
        text: existing.targetText,
      );
      return;
    }
    final messageId = 'stream-$agentRunId';
    final existingIndex = _state.messages.indexWhere(
      (message) => message.messageId == messageId,
    );
    final initialText = existingIndex < 0
        ? ''
        : _state.messages[existingIndex].visibleText ?? '';
    late final ChatStreamRevealBuffer buffer;
    buffer = ChatStreamRevealBuffer(
      initialText: initialText,
      coalesceUpdates: coalescedStreamingUi,
      onReveal: (text) {
        if (_disposed || _agentProgressRevealBuffers[agentRunId] != buffer) {
          return;
        }
        _publishAssistantAnswerDraft(
          threadId: threadId,
          agentRunId: agentRunId,
          visibleText: text,
          targetText: buffer.targetText,
          source: ChatAssistantAnswerDraftSource.transportDelta,
        );
      },
    );
    _agentProgressRevealBuffers[agentRunId] = buffer;
    buffer.ingest(delta, replace: replace);
    _publishAssistantAnswerDraft(
      threadId: threadId,
      agentRunId: agentRunId,
      visibleText: buffer.visibleText,
      targetText: buffer.targetText,
      source: ChatAssistantAnswerDraftSource.transportDelta,
    );
    _storeAgentProgressTarget(
      threadId: threadId,
      agentRunId: agentRunId,
      text: buffer.targetText,
    );
  }

  void _publishAssistantAnswerDraft({
    required String threadId,
    required String agentRunId,
    required String visibleText,
    required String targetText,
    required ChatAssistantAnswerDraftSource source,
  }) {
    if (_disposed ||
        _state.activeThreadId != threadId ||
        _agentProgressThreadId != threadId ||
        _agentProgressRunId != agentRunId) {
      return;
    }
    final messageId = 'stream-$agentRunId';
    final answerDraft = ChatAssistantAnswerDraft(
      visibleText: visibleText,
      targetText: targetText,
      source: source,
    );
    final currentAnswers = _assistantAnswerDrafts.value;
    if (currentAnswers[messageId] != answerDraft) {
      _assistantAnswerDrafts.value =
          Map<String, ChatAssistantAnswerDraft>.unmodifiable(
            <String, ChatAssistantAnswerDraft>{
              ...currentAnswers,
              messageId: answerDraft,
            },
          );
    }
    _publishAgentProgressDraft(messageId, visibleText);
  }

  void _storeAgentProgressTarget({
    required String threadId,
    required String agentRunId,
    required String text,
  }) {
    if (_disposed ||
        _state.activeThreadId != threadId ||
        _agentProgressThreadId != threadId ||
        _agentProgressRunId != agentRunId ||
        _state.turnState.userMessageId == null) {
      return;
    }
    final messageId = 'stream-$agentRunId';
    final existingIndex = _state.messages.indexWhere(
      (message) => message.messageId == messageId,
    );
    if (existingIndex < 0 && text.isEmpty) return;
    if (existingIndex >= 0 &&
        _state.messages[existingIndex].visibleText == text) {
      return;
    }
    final message = ChatMessage(
      messageId: messageId,
      threadId: threadId,
      scene: _state.scene,
      role: ChatMessageRole.assistant,
      contentType: ChatMessageContentType.text,
      status: 'streaming',
      agentRunId: agentRunId,
      textPreview: text,
      createdAt: existingIndex < 0
          ? _nowUtc()
          : _state.messages[existingIndex].createdAt,
      localDelivery: ChatLocalDeliveryState.pending,
    );
    final nextState = _state.copyWith(
      messages: <ChatMessage>[
        for (var index = 0; index < _state.messages.length; index += 1)
          if (index == existingIndex) message else _state.messages[index],
        if (existingIndex < 0) message,
      ],
    );
    if (existingIndex < 0) {
      _update(nextState);
    } else {
      // Transport targets remain queryable for persistence and terminal
      // reconciliation without rebuilding the page for every server chunk.
      _state = nextState;
    }
  }

  void _publishAgentProgressDraft(String messageId, String text) {
    final current = _agentProgressDrafts.value;
    if (current[messageId] == text) return;
    _agentProgressDrafts.value = Map<String, String>.unmodifiable(
      <String, String>{...current, messageId: text},
    );
  }

  void _retainActiveAgentProgressDrafts(List<ChatMessage> messages) {
    final activeIds = <String>{
      for (final message in messages)
        if (message.role == ChatMessageRole.assistant &&
            message.status == 'streaming')
          message.messageId,
    };
    final currentAnswers = _assistantAnswerDrafts.value;
    final retainedAnswers = <String, ChatAssistantAnswerDraft>{
      for (final entry in currentAnswers.entries)
        if (activeIds.contains(entry.key)) entry.key: entry.value,
    };
    if (retainedAnswers.length != currentAnswers.length) {
      _assistantAnswerDrafts.value =
          Map<String, ChatAssistantAnswerDraft>.unmodifiable(retainedAnswers);
    }
    final currentLegacy = _agentProgressDrafts.value;
    final retainedLegacy = <String, String>{
      for (final entry in currentLegacy.entries)
        if (activeIds.contains(entry.key)) entry.key: entry.value,
    };
    if (retainedLegacy.length != currentLegacy.length) {
      _agentProgressDrafts.value = Map<String, String>.unmodifiable(
        retainedLegacy,
      );
    }
  }

  void _stopAgentProgressProjection([String? expectedThreadId]) {
    if (expectedThreadId != null &&
        _agentProgressThreadId != expectedThreadId) {
      return;
    }
    _threadProgressPoller?.stop();
    _agentProgressFallbackTimer?.cancel();
    _agentProgressFallbackTimer = null;
    final agentRunId = _agentProgressRunId;
    if (agentRunId != null) {
      final buffer = _agentProgressRevealBuffers[agentRunId];
      if (buffer != null) {
        buffer.flush();
        _agentProgressRevealBuffers.remove(agentRunId);
        buffer.dispose();
        _persistConversationCache();
      }
    }
    _agentProgressTransport = null;
    _agentProgressThreadId = null;
    _agentProgressRunId = null;
    _agentProgressSequence = 0;
    _agentProgressSseSequence = 0;
  }

  void _captureRunTrackerUpdate() {
    final activeThreadId = _state.activeThreadId;
    if (activeThreadId != null) {
      _resumeAgentProgressProjection(activeThreadId);
    }
    _captureLatestRunDraftDelta();
    if (_runCompletionJournal == null) {
      _captureLatestRunCompletion();
    }
  }

  void _captureLatestRunDraftDelta({bool allowReplay = false}) {
    if (_disposed) return;
    final source = _runDraftDeltaSource;
    if (source == null) {
      return;
    }
    final sequenceChanged =
        source.draftDeltaSequence != _observedRunDraftDeltaSequence;
    if (!allowReplay && !sequenceChanged) return;
    final delta = source.lastDraftDelta;
    if (delta == null ||
        delta.scene != _state.scene ||
        delta.purpose != _conversationPurpose ||
        _state.activeThreadId != delta.threadId ||
        _agentProgressThreadId != delta.threadId ||
        _agentProgressRunId != delta.agentRunId) {
      return;
    }
    if (sequenceChanged) {
      _observedRunDraftDeltaSequence = source.draftDeltaSequence;
    }
    if (delta.eventSequence <= _agentProgressSseSequence) return;
    _agentProgressSseSequence = delta.eventSequence;
    final previousTransport = _agentProgressTransport;
    _agentProgressTransport = _AgentProgressTransport.agentRunSse;
    _agentProgressFallbackTimer?.cancel();
    _threadProgressPoller?.stop();
    final deltaText =
        previousTransport == _AgentProgressTransport.threadEvents &&
            !delta.replace
        ? _unseenCrossTransportSuffix(
            _agentProgressRevealBuffers[delta.agentRunId]?.targetText ?? '',
            delta.deltaText,
          )
        : delta.deltaText;
    if (delta.replace || deltaText.isNotEmpty) {
      _appendAgentProgressDelta(
        delta.threadId,
        delta.agentRunId,
        deltaText,
        replace: delta.replace,
      );
    }
    _armAgentProgressFallback(delta.threadId, delta.agentRunId);
    _scheduleConversationCachePersist();
  }

  void _captureLatestRunCompletion() {
    if (_disposed) return;
    final source = _runCompletionSource;
    if (source == null ||
        source.completionSequence == _observedRunCompletionSequence) {
      return;
    }
    _observedRunCompletionSequence = source.completionSequence;
    final completion = source.lastCompletion;
    if (completion != null && _isCompletionRelevantToCurrentTurn(completion)) {
      _captureRunCompletion(completion);
    }
  }

  void _captureJournalCompletions(String threadId) {
    final journal = _runCompletionJournal;
    if (_disposed || journal == null || _state.activeThreadId != threadId) {
      return;
    }
    final completions = journal.completionsForThread(threadId);
    for (final completion in completions.reversed) {
      if (!_isCompletionRelevantToCurrentTurn(completion)) continue;
      final observationKey = _completionObservationKey(completion);
      if (_observedRunCompletionKeys.contains(observationKey)) continue;
      if (_captureRunCompletion(completion)) {
        _observedRunCompletionKeys.add(observationKey);
        return;
      }
    }
  }

  bool _isCompletionRelevantToCurrentTurn(ChatRunCompletion completion) {
    final boundRunId = _boundAgentRunIdForCurrentTurn(completion.threadId);
    if (boundRunId != null && boundRunId != completion.agentRunId) {
      return false;
    }
    final tracker = _runTracker;
    if (boundRunId == null && tracker is ChatRunActivityPort) {
      final boundary = _latestCurrentTurnActivity(
        (tracker as ChatRunActivityPort).activitiesForThread(
          completion.threadId,
        ),
        const <String>{},
      );
      if (boundary != null && boundary.agentRunId != completion.agentRunId) {
        return false;
      }
    }
    final completedAt = completion.completedAt;
    final latestUserAt = _state.messages.reversed
        .where((message) => message.role == ChatMessageRole.user)
        .map((message) => message.createdAt)
        .whereType<DateTime>()
        .firstOrNull;
    if (completedAt != null &&
        latestUserAt != null &&
        completedAt.isBefore(latestUserAt)) {
      return false;
    }
    final tail = _state.messages.lastOrNull;
    if (tail != null &&
        tail.role == ChatMessageRole.assistant &&
        !_messageMatchesCompletion(tail, completion)) {
      return false;
    }
    return true;
  }

  bool _captureRunCompletion(ChatRunCompletion completion) {
    final failureCode = ChatControllerPolicies.chatRunCompletionFailureCode(
      completion,
    );
    if (completion.scene != _state.scene ||
        completion.purpose != _conversationPurpose ||
        _state.activeThreadId != completion.threadId) {
      return false;
    }
    if (_agentProgressThreadId == completion.threadId &&
        _agentProgressRunId == completion.agentRunId) {
      _stopAgentProgressProjection(completion.threadId);
    }
    if (failureCode == null && _hasDurableAssistantForCompletion(completion)) {
      _removeAgentProgressMessage(
        threadId: completion.threadId,
        agentRunId: completion.agentRunId,
      );
      _unreconciledRunCompletions.remove(completion.agentRunId);
      _terminalReadbackAttempts.remove(completion.agentRunId);
      return true;
    }
    if (failureCode != null) {
      _freezeAgentProgressMessage(
        threadId: completion.threadId,
        agentRunId: completion.agentRunId,
        completedAt: completion.completedAt,
      );
    }
    _unreconciledRunCompletions[completion.agentRunId] = completion;
    _terminalReadbackAttempts.putIfAbsent(completion.agentRunId, () => 0);
    ChatControllerPolicies.debugTerminalReadback('queued', completion);
    if (_state.activeThreadId == completion.threadId) {
      final ownsCurrentAction =
          _state.nextAction.type == ChatNextActionType.pollAgentRun &&
          _state.nextAction.agentRunId == completion.agentRunId;
      _update(
        failureCode == null
            ? _state.copyWith()
            : _state.copyWith(
                status: ChatControllerStatus.failed,
                nextAction: ownsCurrentAction
                    ? const ChatNextAction.none()
                    : _state.nextAction,
                clearAgentActivity: ownsCurrentAction,
                lastErrorCode: failureCode,
              ),
      );
    }
    _scheduleTerminalReadback();
    return true;
  }

  bool _hasDurableAssistantForCompletion(ChatRunCompletion completion) =>
      _state.messages.any(
        (message) =>
            message.role == ChatMessageRole.assistant &&
            !ChatControllerPolicies.isAgentProgressMessage(message) &&
            _messageMatchesCompletion(message, completion),
      );

  bool _messageMatchesCompletion(
    ChatMessage message,
    ChatRunCompletion completion,
  ) {
    if (message.agentRunId == completion.agentRunId) {
      return true;
    }
    final assistantMessageId = completion.assistantMessageId;
    return assistantMessageId != null &&
        message.messageId == assistantMessageId;
  }

  Map<String, String> _terminalAssistantMessageIdsForThread(String threadId) {
    final result = <String, String>{};
    final journal = _runCompletionJournal;
    if (journal != null) {
      for (final completion in journal.completionsForThread(threadId)) {
        final assistantMessageId = completion.assistantMessageId?.trim();
        if (assistantMessageId != null && assistantMessageId.isNotEmpty) {
          result[completion.agentRunId] = assistantMessageId;
        }
      }
    }
    for (final completion in _unreconciledRunCompletions.values) {
      final assistantMessageId = completion.assistantMessageId?.trim();
      if (completion.threadId == threadId &&
          assistantMessageId != null &&
          assistantMessageId.isNotEmpty) {
        result[completion.agentRunId] = assistantMessageId;
      }
    }
    return Map<String, String>.unmodifiable(result);
  }

  String _completionObservationKey(ChatRunCompletion completion) => <String?>[
    completion.agentRunId,
    completion.status,
    completion.completionMode,
    completion.assistantMessageId,
    completion.failureCode,
  ].map((part) => part ?? '').join('|');

  void _removeAgentProgressMessage({
    required String threadId,
    required String agentRunId,
  }) {
    _agentProgressRevealBuffers.remove(agentRunId)?.dispose();
    final messageId = 'stream-$agentRunId';
    final nextMessages = _state.messages
        .where(
          (message) =>
              message.messageId != messageId || message.threadId != threadId,
        )
        .toList(growable: false);
    if (nextMessages.length == _state.messages.length) return;
    _update(_state.copyWith(messages: nextMessages));
    _persistConversationCache();
  }

  void _freezeAgentProgressMessage({
    required String threadId,
    required String agentRunId,
    DateTime? completedAt,
  }) {
    _agentProgressRevealBuffers.remove(agentRunId)?.dispose();
    final messageId = 'stream-$agentRunId';
    final existingIndex = _state.messages.indexWhere(
      (message) =>
          message.messageId == messageId && message.threadId == threadId,
    );
    final existing = existingIndex < 0 ? null : _state.messages[existingIndex];
    final controllerDraft = _assistantAnswerDrafts.value[messageId]?.targetText;
    final snapshot = _runDraftSnapshotSource?.draftSnapshotFor(
      threadId: threadId,
      agentRunId: agentRunId,
    );
    final snapshotText =
        snapshot != null &&
            snapshot.scene == _state.scene &&
            snapshot.purpose == _conversationPurpose
        ? snapshot.text
        : null;
    final text = <String?>[controllerDraft, snapshotText, existing?.visibleText]
        .whereType<String>()
        .firstWhere((candidate) => candidate.isNotEmpty, orElse: () => '');
    if (text.isEmpty) return;
    final frozen =
        existing?.copyWith(textPreview: text) ??
        ChatMessage(
          messageId: messageId,
          threadId: threadId,
          scene: _state.scene,
          role: ChatMessageRole.assistant,
          contentType: ChatMessageContentType.text,
          status: 'streaming',
          agentRunId: agentRunId,
          textPreview: text,
          createdAt: completedAt ?? _nowUtc(),
          localDelivery: ChatLocalDeliveryState.pending,
        );
    if (existing == null || existing.visibleText != text) {
      _update(
        _state.copyWith(
          messages: <ChatMessage>[
            for (var index = 0; index < _state.messages.length; index += 1)
              if (index == existingIndex) frozen else _state.messages[index],
            if (existingIndex < 0) frozen,
          ],
        ),
      );
    }
    _discardAgentProgressDraft(messageId);
  }

  void _discardAgentProgressDraft(String messageId) {
    final currentAnswers = _assistantAnswerDrafts.value;
    if (currentAnswers.containsKey(messageId)) {
      _assistantAnswerDrafts.value =
          Map<String, ChatAssistantAnswerDraft>.unmodifiable(
            <String, ChatAssistantAnswerDraft>{
              for (final entry in currentAnswers.entries)
                if (entry.key != messageId) entry.key: entry.value,
            },
          );
    }
    final currentLegacy = _agentProgressDrafts.value;
    if (currentLegacy.containsKey(messageId)) {
      _agentProgressDrafts.value =
          Map<String, String>.unmodifiable(<String, String>{
            for (final entry in currentLegacy.entries)
              if (entry.key != messageId) entry.key: entry.value,
          });
    }
  }

  bool _hasPendingTerminalReadback(String threadId) =>
      _unreconciledRunCompletions.values.any(
        (completion) => completion.threadId == threadId,
      );

  void _scheduleTerminalReadback({Duration delay = Duration.zero}) {
    if (_disposed ||
        _isTerminalReadbackInFlight ||
        _terminalReadbackTimer != null) {
      return;
    }
    final activeThreadId = _state.activeThreadId;
    if (activeThreadId == null ||
        !_hasPendingTerminalReadback(activeThreadId)) {
      return;
    }
    final busy = _state.isLoading || _state.isSending || _isPollingTask;
    final effectiveDelay = busy && delay <= Duration.zero
        ? const Duration(milliseconds: 1)
        : delay;
    if (effectiveDelay <= Duration.zero) {
      scheduleMicrotask(() => unawaited(_drainTerminalReadback()));
      return;
    }
    _terminalReadbackTimer = Timer(effectiveDelay, () {
      _terminalReadbackTimer = null;
      unawaited(_drainTerminalReadback());
    });
  }

  Future<void> _drainTerminalReadback() async {
    if (_disposed || _isTerminalReadbackInFlight) return;
    final threadId = _state.activeThreadId;
    if (threadId == null) return;
    final completion = _unreconciledRunCompletions.values
        .where((candidate) => candidate.threadId == threadId)
        .firstOrNull;
    if (completion == null) return;
    if (_state.isLoading || _state.isSending || _isPollingTask) {
      _scheduleTerminalReadback(delay: taskPollInterval);
      return;
    }

    _isTerminalReadbackInFlight = true;
    final previousAction = _state.nextAction;
    final previousRunStatus = _state.agentRunStatus;
    final previousAssistantToolTrace = _state.assistantToolTrace;
    final preservesUnrelatedAction =
        ChatControllerPolicies.awaitsAssistant(previousAction) &&
        !(previousAction.type == ChatNextActionType.pollAgentRun &&
            previousAction.agentRunId == completion.agentRunId);
    try {
      ChatControllerPolicies.debugTerminalReadback('request', completion);
      final readback = selectThread(
        threadId,
        forceRemote: true,
        silentRemoteFailure: true,
      );
      final readbackGeneration = _threadSelectionGeneration;
      await readback;
      if (!_isCurrentThreadSelection(readbackGeneration) ||
          _state.activeThreadId != threadId) {
        return;
      }
      if (!_unreconciledRunCompletions.containsKey(completion.agentRunId)) {
        if (preservesUnrelatedAction) {
          _update(
            _state.copyWith(
              status: ChatControllerStatus.ready,
              nextAction: previousAction,
              agentRunStatus: previousRunStatus,
              assistantToolTrace: previousAssistantToolTrace,
              clearError: true,
            ),
          );
        }
        return;
      }

      final terminalFailureCode =
          ChatControllerPolicies.chatRunCompletionFailureCode(completion);
      if (terminalFailureCode != null) {
        ChatControllerPolicies.debugTerminalReadback(
          'terminal-failure',
          completion,
          code: terminalFailureCode,
        );
        _unreconciledRunCompletions.remove(completion.agentRunId);
        _terminalReadbackAttempts.remove(completion.agentRunId);
        _update(
          _state.copyWith(
            status: ChatControllerStatus.failed,
            nextAction: preservesUnrelatedAction
                ? previousAction
                : const ChatNextAction.none(),
            clearAgentActivity: !preservesUnrelatedAction,
            lastErrorCode: terminalFailureCode,
          ),
        );
        return;
      }

      final attempts =
          (_terminalReadbackAttempts[completion.agentRunId] ?? 0) + 1;
      _terminalReadbackAttempts[completion.agentRunId] = attempts;
      if (attempts >= taskPollAttempts) {
        ChatControllerPolicies.debugTerminalReadback(
          'reply-missing',
          completion,
          attempt: attempts,
          code: 'CHAT_AGENT_RUN_REPLY_NOT_PERSISTED',
        );
        _unreconciledRunCompletions.remove(completion.agentRunId);
        _terminalReadbackAttempts.remove(completion.agentRunId);
        _update(
          _state.copyWith(
            status: ChatControllerStatus.failed,
            nextAction: preservesUnrelatedAction
                ? previousAction
                : const ChatNextAction.none(),
            lastErrorCode: 'CHAT_AGENT_RUN_REPLY_NOT_PERSISTED',
          ),
        );
        return;
      }

      ChatControllerPolicies.debugTerminalReadback(
        'retry',
        completion,
        attempt: attempts,
      );
      _update(
        _state.copyWith(
          status: ChatControllerStatus.ready,
          nextAction: preservesUnrelatedAction
              ? previousAction
              : ChatNextAction(
                  type: ChatNextActionType.pollAgentRun,
                  agentRunId: completion.agentRunId,
                ),
          agentRunStatus: completion.status,
          clearError: true,
        ),
      );
    } finally {
      _isTerminalReadbackInFlight = false;
      if (!_disposed &&
          _unreconciledRunCompletions.containsKey(completion.agentRunId)) {
        _scheduleTerminalReadback(delay: taskPollInterval);
      } else {
        _scheduleTerminalReadback();
      }
    }
  }

  void _discardReconciledRunCompletions(
    String threadId,
    Iterable<ChatMessage> messages,
  ) {
    final messageList = messages.toList(growable: false);
    final reconciled = <String>[];
    for (final entry in _unreconciledRunCompletions.entries) {
      final completion = entry.value;
      if (completion.threadId != threadId ||
          ChatControllerPolicies.chatRunCompletionFailureCode(completion) !=
              null) {
        continue;
      }
      final expectedAssistantId = completion.assistantMessageId;
      final hasExpectedAssistant = messageList.any(
        (message) =>
            message.role == ChatMessageRole.assistant &&
            message.status != 'streaming' &&
            message.localDelivery != ChatLocalDeliveryState.pending &&
            !ChatControllerPolicies.isAgentProgressMessage(message) &&
            (expectedAssistantId == null
                ? message.agentRunId == completion.agentRunId
                : message.messageId == expectedAssistantId),
      );
      if (hasExpectedAssistant) {
        ChatControllerPolicies.debugTerminalReadback('reconciled', completion);
        reconciled.add(entry.key);
      }
    }
    for (final agentRunId in reconciled) {
      _unreconciledRunCompletions.remove(agentRunId);
      _terminalReadbackAttempts.remove(agentRunId);
    }
  }

  void _trackServerActiveRuns(Iterable<ChatThread> threads) {
    final tracker = _runTracker;
    if (tracker == null) return;
    for (final thread in threads) {
      unawaited(_trackServerThreadTasks(tracker, thread));
    }
  }

  Future<void> _trackServerThreadTasks(
    ChatRunTrackingPort tracker,
    ChatThread thread,
  ) async {
    await _rememberThreadTaskSubject(
      thread.threadId,
      subjectTitle: thread.displayTitle,
    );
    if (thread.activeRuns.isEmpty ||
        tracker is! ChatRunServerActiveRunTrackingPort) {
      return;
    }
    final activeRunTracker = tracker as ChatRunServerActiveRunTrackingPort;
    await activeRunTracker.trackServerActiveRuns(
      threadId: thread.threadId,
      scene: _state.scene,
      runs: thread.activeRuns,
      purpose: _conversationPurpose,
    );
  }

  Future<void> _rememberThreadTaskSubject(
    String threadId, {
    String? subjectTitle,
  }) async {
    final tracker = _runTracker;
    if (tracker is! AgentTaskSubjectMetadataPort) return;
    final subjectTracker = tracker as AgentTaskSubjectMetadataPort;
    final title =
        subjectTitle ??
        _state.threads
            .where((thread) => thread.threadId == threadId)
            .firstOrNull
            ?.displayTitle;
    if (title == null || title.trim().isEmpty) return;
    try {
      await subjectTracker.rememberChatThreadSubject(
        threadId: threadId,
        subjectTitle: title,
      );
    } catch (_) {
      // Presentation metadata must never prevent Run lifecycle enrollment.
    }
  }

  void _resumeAgentProgressProjection(String threadId) {
    if (_disposed || _state.activeThreadId != threadId) return;
    _captureJournalCompletions(threadId);
    final durableRunIds = <String>{};
    for (final message in _state.messages) {
      final runId = message.agentRunId?.trim();
      if (message.role == ChatMessageRole.assistant &&
          !ChatControllerPolicies.isAgentProgressMessage(message) &&
          runId != null &&
          runId.isNotEmpty) {
        durableRunIds.add(runId);
      }
    }
    String? agentRunId;
    var trackerHasCurrentTurnBoundary = false;
    final tracker = _runTracker;
    if (tracker is ChatRunActivityPort) {
      final activities = (tracker as ChatRunActivityPort).activitiesForThread(
        threadId,
      );
      final boundRunId = _boundAgentRunIdForCurrentTurn(threadId);
      final boundActivity = boundRunId == null
          ? null
          : activities
                .where((activity) => activity.agentRunId == boundRunId)
                .firstOrNull;
      if (boundRunId != null) {
        trackerHasCurrentTurnBoundary = true;
        if (!durableRunIds.contains(boundRunId) &&
            (boundActivity == null ||
                !boundActivity.isTerminal ||
                _canResumeTerminalDraft(threadId, boundActivity))) {
          agentRunId = boundRunId;
        }
      } else {
        final boundary = _latestCurrentTurnActivity(activities, durableRunIds);
        trackerHasCurrentTurnBoundary = boundary != null;
        if (boundary != null &&
            (!boundary.isTerminal ||
                _canResumeTerminalDraft(threadId, boundary))) {
          agentRunId = boundary.agentRunId;
        }
      }
    }
    if (agentRunId == null && !trackerHasCurrentTurnBoundary) {
      final thread = _state.threads
          .where((candidate) => candidate.threadId == threadId)
          .firstOrNull;
      if (thread != null) {
        final activeRuns =
            thread.activeRuns
                .where((run) => !run.isTerminal)
                .toList(growable: false)
              ..sort(
                (left, right) => left.agentRunId.compareTo(right.agentRunId),
              );
        final boundRunId = _boundAgentRunIdForCurrentTurn(threadId);
        final orderedCandidates = boundRunId == null
            ? activeRuns.reversed
            : <ChatActiveRun>[
                ...activeRuns.where((run) => run.agentRunId == boundRunId),
                ...activeRuns.reversed.where(
                  (run) => run.agentRunId != boundRunId,
                ),
              ];
        for (final run in orderedCandidates) {
          final tracked = tracker is ChatRunActivityPort
              ? (tracker as ChatRunActivityPort).activityFor(
                  threadId: threadId,
                  agentRunId: run.agentRunId,
                )
              : null;
          if (tracked?.isTerminal != true &&
              !durableRunIds.contains(run.agentRunId)) {
            agentRunId = run.agentRunId;
            break;
          }
        }
      }
    }
    if (agentRunId == null ||
        (_agentProgressThreadId == threadId &&
            _agentProgressRunId == agentRunId)) {
      return;
    }
    _startAgentProgressProjection(
      threadId,
      ChatNextAction(
        type: ChatNextActionType.pollAgentRun,
        agentRunId: agentRunId,
      ),
    );
  }

  String? _boundAgentRunIdForCurrentTurn(String threadId) {
    if (_state.activeThreadId != threadId) return null;
    final action = _state.nextAction;
    final actionRunId = action.agentRunId;
    if (action.type == ChatNextActionType.pollAgentRun && actionRunId != null) {
      return actionRunId;
    }
    return _state.turnState.agentRunId;
  }

  ChatRunActivity? _latestCurrentTurnActivity(
    Iterable<ChatRunActivity> activities,
    Set<String> durableRunIds,
  ) {
    final latestUserAt = _state.messages.reversed
        .where((message) => message.role == ChatMessageRole.user)
        .map((message) => message.createdAt?.toUtc())
        .whereType<DateTime>()
        .firstOrNull;
    final candidates =
        activities
            .where(
              (activity) =>
                  !durableRunIds.contains(activity.agentRunId) &&
                  (latestUserAt == null ||
                      !activity.createdAt.toUtc().isBefore(latestUserAt)),
            )
            .toList(growable: false)
          ..sort((left, right) {
            final timeOrder = left.createdAt.toUtc().compareTo(
              right.createdAt.toUtc(),
            );
            return timeOrder != 0
                ? timeOrder
                : left.agentRunId.compareTo(right.agentRunId);
          });
    return candidates.lastOrNull;
  }

  bool _canResumeTerminalDraft(String threadId, ChatRunActivity activity) {
    if (activity.status != 'succeeded' ||
        !ChatControllerPolicies.hasUnansweredUserTurn(_state.messages)) {
      return false;
    }
    final tracker = _runTracker;
    final trackerNeedsReadback =
        tracker is ChatRunReconciliationPort &&
        (tracker as ChatRunReconciliationPort).needsThreadReconciliation(
          threadId,
        );
    if (!trackerNeedsReadback &&
        !_unreconciledRunCompletions.containsKey(activity.agentRunId)) {
      return false;
    }
    final snapshot = _runDraftSnapshotSource?.draftSnapshotFor(
      threadId: threadId,
      agentRunId: activity.agentRunId,
    );
    return snapshot != null &&
        snapshot.scene == _state.scene &&
        snapshot.purpose == _conversationPurpose &&
        snapshot.text.isNotEmpty;
  }

  void _activateCachedThread(String threadId, {String? lastErrorCode}) {
    final cachedThread = _state.threads
        .where((thread) => thread.threadId == threadId)
        .firstOrNull;
    if (cachedThread == null) return;
    if (!_bindOrVerifyThreadAgentProfile(cachedThread)) return;
    _trackServerActiveRuns(<ChatThread>[cachedThread]);
    final originalCachedMessages =
        _cachedMessagesByThread[threadId] ?? const <ChatMessage>[];
    final recoveredOrphanedSubmission = originalCachedMessages.any(
      (message) =>
          message.role == ChatMessageRole.user &&
          message.localDelivery == ChatLocalDeliveryState.pending,
    );
    final cachedMessages = <ChatMessage>[
      for (final message in originalCachedMessages)
        if (message.role == ChatMessageRole.user &&
            message.localDelivery == ChatLocalDeliveryState.pending)
          message.copyWith(
            status: 'failed',
            localDelivery: ChatLocalDeliveryState.failed,
            localFailureCanAbandon: false,
          )
        else
          message,
    ];
    _cachedMessagesByThread[threadId] = List<ChatMessage>.unmodifiable(
      cachedMessages,
    );
    final resolvedErrorCode =
        lastErrorCode ??
        (recoveredOrphanedSubmission
            ? 'CHAT_LOCAL_TURN_RECOVERY_REQUIRED'
            : null);
    _update(
      _state.copyWith(
        status: ChatControllerStatus.ready,
        activeThreadId: threadId,
        messages: cachedMessages,
        nextAction: const ChatNextAction.none(),
        clearAgentActivity: true,
        lastErrorCode: resolvedErrorCode,
        clearError: resolvedErrorCode == null,
      ),
    );
    _resumeAgentProgressProjection(threadId);
    _discardReconciledRunCompletions(threadId, _state.messages);
    _scheduleTerminalReadback();
    if (recoveredOrphanedSubmission) _persistConversationCache();
  }

  void _rememberServerMessages(
    String threadId,
    Iterable<ChatMessage> messages,
  ) {
    _cachedMessagesByThread[threadId] = List<ChatMessage>.unmodifiable([
      for (final message in messages)
        if (_isPersistableLocalMessage(message) ||
            ChatControllerPolicies.isAgentProgressMessage(message))
          message.copyWith(scene: _state.scene),
    ]);
  }

  void _persistConversationCache() {
    _conversationCachePersistTimer?.cancel();
    _conversationCachePersistTimer = null;
    if (_conversationCacheCommitInFlight) {
      _conversationCachePersistPending = true;
      return;
    }
    _conversationCachePersistPending = false;
    final repository = _aliasRepository;
    if (repository == null || _disposed || _isThreadAgentScopeUnresolved) {
      return;
    }
    final activeThreadId = _state.activeThreadId;
    if (activeThreadId != null) {
      _rememberServerMessages(activeThreadId, _state.messages);
    }
    try {
      final savedAt = _nowUtc();
      repository.saveConversationCache(
        scene: _state.scene,
        purpose: _conversationPurpose,
        agentProfileId: _conversationCacheAgentProfileId,
        threads: _state.threads,
        messagesByThread: _cachedMessagesByThread,
        historySyncedAt: _historySyncedAt,
        historyComplete: _historySnapshotComplete,
        detailSyncedAtByThread: _threadDetailSyncedAt,
        savedAt: savedAt,
      );
    } catch (_) {
      // A local display cache must never interrupt an accepted chat turn.
    }
  }

  void _scheduleConversationCachePersist() {
    if (_aliasRepository == null || _disposed) return;
    _conversationCachePersistPending = true;
    _conversationCachePersistTimer?.cancel();
    _conversationCachePersistTimer = Timer(
      _conversationCacheWriteDebounce,
      _persistConversationCache,
    );
  }

  bool _isFresh(DateTime? syncedAt, Duration freshness) {
    if (syncedAt == null) return false;
    final age = _nowUtc().difference(syncedAt.toUtc());
    return !age.isNegative && age <= freshness;
  }

  bool _canDetachAcceptedRun(ChatNextAction action) =>
      action.type == ChatNextActionType.pollAgentRun &&
      _runTracker is ChatRunLifecycleOwnerPort &&
      (_runTracker! as ChatRunLifecycleOwnerPort).canTrackAcceptedRuns;

  Iterable<ChatThread> _visibleThreadsForPurpose(Iterable<ChatThread> threads) {
    final repository = _aliasRepository;
    return threads.where((thread) {
      if (repository?.isThreadHidden(
            scene: _state.scene,
            threadId: thread.threadId,
          ) ==
          true) {
        return false;
      }
      if (thread.purpose == _conversationPurpose) {
        if (_conversationPurpose != ChatConversationPurpose.general ||
            repository == null) {
          return true;
        }
        return !repository.isThreadAssignedToNonGeneralPurpose(
          scene: _state.scene,
          threadId: thread.threadId,
        );
      }
      if (thread.purpose != ChatConversationPurpose.general ||
          repository == null ||
          _conversationPurpose == ChatConversationPurpose.general) {
        return false;
      }
      return repository
          .threadIdsForPurpose(
            scene: _state.scene,
            purpose: _conversationPurpose,
          )
          .contains(thread.threadId);
    });
  }

  bool _bindOrVerifyThreadAgentProfile(ChatThread thread) {
    final serverProfile = _normalizedAgentProfileId(thread.agentProfileId);
    final storedProfile = _normalizedAgentProfileId(
      _aliasRepository?.agentProfileFor(
        scene: _state.scene,
        threadId: thread.threadId,
      ),
    );
    final profileHint = _normalizedAgentProfileId(_agentScope?.profileHint);
    final legacyInitialProfile = _normalizedAgentProfileId(
      _initialAgentProfileId,
    );
    final resolvedProfile =
        serverProfile ??
        storedProfile ??
        profileHint ??
        legacyInitialProfile ??
        (_conversationPurpose == ChatConversationPurpose.general
            ? standardCreationChatAgentProfileId
            : null);

    final fixedProfile = _normalizedAgentProfileId(_agentScope?.fixedProfileId);
    if (fixedProfile != null) {
      if (serverProfile != null && serverProfile != fixedProfile) {
        _fail('CHAT_THREAD_AGENT_PROFILE_MISMATCH');
        return false;
      }
      _rememberThreadAgentProfile(thread.threadId, fixedProfile);
      return true;
    }

    if (_agentScope?.bindsFromThread == true) {
      if (resolvedProfile == null) {
        _fail('CHAT_THREAD_AGENT_PROFILE_UNRESOLVED');
        return false;
      }
      final boundProfile = _boundThreadAgentProfileId;
      if (boundProfile != null && boundProfile != resolvedProfile) {
        _fail('CHAT_THREAD_AGENT_PROFILE_MISMATCH');
        return false;
      }
      _boundThreadAgentProfileId = resolvedProfile;
      _rememberThreadAgentProfile(thread.threadId, resolvedProfile);
      return true;
    }

    _boundThreadAgentProfileId = resolvedProfile;
    if (resolvedProfile != null) {
      _rememberThreadAgentProfile(thread.threadId, resolvedProfile);
    }
    return true;
  }

  void _lockAgentProfileForThread(String threadId) {
    final profile = activeAgentProfileId;
    if (profile == null || profile.isEmpty) return;
    _boundThreadAgentProfileId = profile;
    _rememberThreadAgentProfile(threadId, profile);
    _update(
      _state.copyWith(
        threads: <ChatThread>[
          for (final thread in _state.threads)
            if (thread.threadId == threadId)
              thread.copyWith(agentProfileId: profile)
            else
              thread,
        ],
      ),
    );
  }

  String? _knownThreadAgentProfile(String threadId) {
    for (final thread in _state.threads) {
      if (thread.threadId != threadId) continue;
      final profile = thread.agentProfileId?.trim();
      if (profile != null && profile.isNotEmpty) return profile;
    }
    return _aliasRepository?.agentProfileFor(
      scene: _state.scene,
      threadId: threadId,
    );
  }

  Iterable<ChatThread> _withStoredAgentProfiles(
    Iterable<ChatThread> threads, {
    bool adoptLegacyStandardProfile = false,
  }) sync* {
    for (final thread in threads) {
      yield _withStoredAgentProfile(
        thread,
        adoptLegacyStandardProfile: adoptLegacyStandardProfile,
      );
    }
  }

  ChatThread _withStoredAgentProfile(
    ChatThread thread, {
    bool adoptLegacyStandardProfile = false,
  }) {
    thread = _projectThreadForDisplay(thread);
    final profile = thread.agentProfileId?.trim();
    if (profile != null && profile.isNotEmpty) {
      _rememberThreadAgentProfile(thread.threadId, profile);
      return thread.copyWith(agentProfileId: profile);
    }
    final stored = _aliasRepository?.agentProfileFor(
      scene: _state.scene,
      threadId: thread.threadId,
    );
    if (stored != null) return thread.copyWith(agentProfileId: stored);
    return adoptLegacyStandardProfile && _usesStandardCreationAsOrdinaryProfile
        ? thread.copyWith(agentProfileId: standardCreationChatAgentProfileId)
        : thread;
  }

  void _rememberThreadAgentProfile(String threadId, String profile) {
    if (!isSafeChatIdentifier(threadId) || profile.trim().isEmpty) return;
    try {
      _aliasRepository?.saveAgentProfile(
        scene: _state.scene,
        threadId: threadId,
        agentProfileId: profile,
      );
    } catch (_) {
      // Local provenance cannot interrupt a server-confirmed thread.
    }
  }

  String? get _effectiveAgentProfileId {
    final fixedProfile = _normalizedAgentProfileId(_agentScope?.fixedProfileId);
    if (fixedProfile != null) return fixedProfile;
    final boundProfile = _normalizedAgentProfileId(_boundThreadAgentProfileId);
    if (boundProfile != null) return boundProfile;
    if (_agentScope?.bindsFromThread == true) return null;
    return _normalizedAgentProfileId(_initialAgentProfileId);
  }

  bool get _isAggregateAgentHistoryScope =>
      _agentScope?.includesAllProfiles == true ||
      (_conversationPurpose == ChatConversationPurpose.general &&
          _agentScope == null &&
          _normalizedAgentProfileId(_initialAgentProfileId) == null);

  String? get _agentProfileFilterId =>
      _isAggregateAgentHistoryScope ? null : _effectiveAgentProfileId;

  String? get _conversationCacheAgentProfileId => _agentProfileFilterId;

  bool get _isThreadAgentScopeUnresolved =>
      _agentScope?.bindsFromThread == true &&
      _boundThreadAgentProfileId == null;

  String? _normalizedAgentProfileId(String? value) {
    final profile = value?.trim();
    return profile == null || profile.isEmpty ? null : profile;
  }

  bool get _usesStandardCreationAsOrdinaryProfile =>
      _conversationPurpose == ChatConversationPurpose.general &&
      !_isAggregateAgentHistoryScope &&
      _effectiveAgentProfileId == standardCreationChatAgentProfileId;

  String? _agentProfileForThread(ChatThread thread) {
    final profile = thread.agentProfileId?.trim();
    if (profile != null && profile.isNotEmpty) return profile;
    final stored = _aliasRepository?.agentProfileFor(
      scene: _state.scene,
      threadId: thread.threadId,
    );
    return stored;
  }

  bool _threadMatchesEffectiveAgentProfile(String threadId) {
    final requestedProfile = _agentProfileFilterId;
    if (_isThreadAgentScopeUnresolved) return false;
    if (requestedProfile == null) return true;
    final thread = _state.threads
        .where((candidate) => candidate.threadId == threadId)
        .firstOrNull;
    final profile = thread == null
        ? _aliasRepository?.agentProfileFor(
            scene: _state.scene,
            threadId: threadId,
          )
        : _agentProfileForThread(thread);
    return profile == requestedProfile;
  }

  String? _latestThreadIdForEffectiveAgentProfile(
    Iterable<ChatThread> threads,
  ) {
    final requestedProfile = _agentProfileFilterId;
    if (_isThreadAgentScopeUnresolved) return null;
    if (requestedProfile == null) return threads.firstOrNull?.threadId;
    for (final thread in threads) {
      if (_agentProfileForThread(thread) == requestedProfile) {
        return thread.threadId;
      }
    }
    return null;
  }

  bool _threadMatchesPurpose(String threadId) {
    ChatThread? thread;
    for (final candidate in _state.threads) {
      if (candidate.threadId == threadId) {
        thread = candidate;
        break;
      }
    }
    if (thread?.purpose == _conversationPurpose) return true;
    final repository = _aliasRepository;
    if (repository == null) {
      return _conversationPurpose == ChatConversationPurpose.general;
    }
    try {
      if (_conversationPurpose == ChatConversationPurpose.general) {
        return !repository.isThreadAssignedToNonGeneralPurpose(
          scene: _state.scene,
          threadId: threadId,
        );
      }
      return repository
          .threadIdsForPurpose(
            scene: _state.scene,
            purpose: _conversationPurpose,
          )
          .contains(threadId);
    } catch (_) {
      return false;
    }
  }

  bool _isLegacyPurposeAssignment(ChatThread thread) {
    if (thread.purpose != ChatConversationPurpose.general ||
        _conversationPurpose == ChatConversationPurpose.general) {
      return false;
    }
    final repository = _aliasRepository;
    return repository != null &&
        repository
            .threadIdsForPurpose(
              scene: _state.scene,
              purpose: _conversationPurpose,
            )
            .contains(thread.threadId);
  }

  bool _matchesUnassignedPurposeHydration(
    ChatThread serverThread, {
    required bool allowed,
  }) {
    if (!allowed) return false;
    return serverThread.scene.apiValue == _conversationPurpose.historyScene;
  }

  bool _persistCurrentPurpose(String threadId) {
    final repository = _aliasRepository;
    if (repository == null) {
      if (_conversationPurpose == ChatConversationPurpose.general) return true;
      _fail('CHAT_THREAD_PURPOSE_STORAGE_UNAVAILABLE');
      return false;
    }
    try {
      repository.markThreadPurpose(
        scene: _state.scene,
        threadId: threadId,
        purpose: _conversationPurpose,
      );
      return true;
    } catch (_) {
      _fail('CHAT_THREAD_PURPOSE_SAVE_FAILED');
      return false;
    }
  }

  String? _persistConversationAssetReference(String threadId, String? assetId) {
    if (assetId == null) return null;
    final repository = _aliasRepository;
    if (repository == null) {
      return 'CHAT_THREAD_ASSET_STORAGE_UNAVAILABLE';
    }
    try {
      final existing = repository.threadAssetReferenceFor(
        scene: _state.scene,
        threadId: threadId,
      );
      if (existing != null && existing != assetId) {
        return 'CHAT_THREAD_ASSET_REFERENCE_CONFLICT';
      }
      repository.saveThreadAssetReference(
        scene: _state.scene,
        threadId: threadId,
        assetId: assetId,
      );
      return null;
    } catch (_) {
      return 'CHAT_THREAD_ASSET_REFERENCE_SAVE_FAILED';
    }
  }

  bool _isPersistableLocalMessage(ChatMessage message) =>
      message.localDelivery == ChatLocalDeliveryState.server ||
      (message.role == ChatMessageRole.user &&
          (message.localDelivery == ChatLocalDeliveryState.pending ||
              message.localDelivery == ChatLocalDeliveryState.failed));

  List<ChatThread> _mergeListedThreadsWithActiveRecovery(
    List<ChatThread> listedThreads,
  ) {
    final activeThreadId = _state.activeThreadId;
    if (activeThreadId == null ||
        listedThreads.any((thread) => thread.threadId == activeThreadId)) {
      return listedThreads;
    }
    final activeThread = _state.threads
        .where((thread) => thread.threadId == activeThreadId)
        .firstOrNull;
    if (activeThread == null ||
        _aliasRepository?.isThreadHidden(
              scene: _state.scene,
              threadId: activeThreadId,
            ) ==
            true) {
      return listedThreads;
    }
    return ChatControllerPolicies.upsertThread(listedThreads, activeThread);
  }

  List<ChatMessage> _projectMessagesForPurpose(Iterable<ChatMessage> messages) {
    return List<ChatMessage>.unmodifiable(
      messages.map((message) {
        if (message.role != ChatMessageRole.user ||
            message.contentType != ChatMessageContentType.text) {
          return message;
        }
        final raw = message.visibleText?.trim();
        if (raw == null || raw.isEmpty) return message;
        var visible = _projectUserVisibleText(raw);
        if (_conversationPurpose != ChatConversationPurpose.deepPositioning) {
          return visible == raw
              ? message
              : message.copyWith(textPreview: visible);
        }
        visible = ChatControllerPolicies.deepPositioningDisplayContent(visible);
        return message.copyWith(textPreview: visible);
      }),
    );
  }

  String _projectUserVisibleText(String text) =>
      _userVisibleTextProjector?.call(text) ?? text;

  ChatThread _projectThreadForDisplay(ChatThread thread) {
    if (_userVisibleTextProjector == null) return thread;
    final rawFirstMessage = thread.firstUserMessageText;
    final rawTitle = thread.title;
    final firstMessage = rawFirstMessage == null
        ? null
        : _projectUserVisibleText(rawFirstMessage);
    final title =
        thread.titleMode == ChatThreadTitleMode.auto && rawTitle != null
        ? _projectUserVisibleText(rawTitle)
        : rawTitle;
    if (firstMessage == rawFirstMessage && title == rawTitle) return thread;
    return thread.copyWith(firstUserMessageText: firstMessage, title: title);
  }

  Iterable<ChatThread> _overlayLocalAliases(Iterable<ChatThread> threads) {
    final repository = _aliasRepository;
    if (repository == null) return threads;
    final aliases = <String, String>{
      for (final alias in repository.loadAliases(_state.scene))
        alias.threadId: alias.alias,
    };
    return threads.map(
      (thread) => _projectThreadForDisplay(
        thread.copyWith(localAlias: aliases[thread.threadId]),
      ),
    );
  }

  ChatThread _withLocalAlias(ChatThread thread) {
    thread = _projectThreadForDisplay(thread);
    final alias = _aliasRepository?.aliasFor(_state.scene, thread.threadId);
    return alias == null
        ? thread.copyWith(clearLocalAlias: true)
        : thread.copyWith(localAlias: alias);
  }

  void _update(ChatControllerState next) {
    if (_disposed) return;
    final normalizedMessages = ChatTurnStateMachine.normalizeTimeline(
      next.messages,
    );
    final activeThreadId = next.activeThreadId;
    if (activeThreadId != null) {
      _discardReconciledRunCompletions(activeThreadId, normalizedMessages);
    }
    final terminalCompletion = activeThreadId == null
        ? null
        : _unreconciledRunCompletions.values
              .where((completion) => completion.threadId == activeThreadId)
              .firstOrNull;
    final terminalFailureCode = terminalCompletion == null
        ? null
        : ChatControllerPolicies.chatRunCompletionFailureCode(
            terminalCompletion,
          );
    final effectiveNext = terminalFailureCode == null
        ? next
        : next.copyWith(
            status: ChatControllerStatus.failed,
            lastErrorCode: terminalFailureCode,
          );
    final actionRunId = effectiveNext.nextAction.agentRunId;
    final projectionRunId = _agentProgressThreadId == activeThreadId
        ? _agentProgressRunId
        : null;
    final turnState = ChatTurnStateMachine.reduce(
      messages: normalizedMessages,
      assistantExpected: _assistantExpectedFor(effectiveNext),
      terminalReadbackPending: terminalCompletion != null,
      turnFailed: effectiveNext.status == ChatControllerStatus.failed,
      agentRunId:
          terminalCompletion?.agentRunId ?? actionRunId ?? projectionRunId,
    );
    final normalizedNext = effectiveNext.copyWith(
      messages: normalizedMessages,
      turnState: turnState,
    );
    if (_state.activeThreadId != normalizedNext.activeThreadId) {
      _textSubmissionEnvelopes.clear();
      _abandonableFailedTextMessageIds.clear();
    }
    if (kDebugMode &&
        (_state.activeThreadId != normalizedNext.activeThreadId ||
            _state.messages.length != normalizedNext.messages.length ||
            _state.turnState.phase != normalizedNext.turnState.phase)) {
      debugPrint(
        '[ChatState] active=${_state.activeThreadId ?? '-'}'
        '->${normalizedNext.activeThreadId ?? '-'} '
        'messages=${_state.messages.length}->${normalizedNext.messages.length} '
        'status=${normalizedNext.status.name} '
        'turn=${_state.turnState.phase.name}'
        '->${normalizedNext.turnState.phase.name}',
      );
    }
    _state = normalizedNext;
    _retainActiveAgentProgressDrafts(normalizedNext.messages);
    notifyListeners();
  }

  bool _assistantExpectedFor(ChatControllerState next) {
    final threadId = next.activeThreadId;
    if (ChatControllerPolicies.awaitsAssistant(next.nextAction)) return true;
    if (threadId == null) return false;
    if (_agentProgressThreadId == threadId && _agentProgressRunId != null) {
      return true;
    }
    final thread = next.threads
        .where((candidate) => candidate.threadId == threadId)
        .firstOrNull;
    if (thread?.activeRuns.any((run) => !run.isTerminal) == true) return true;
    final tracker = _runTracker;
    return tracker is ChatRunStatusPort &&
        (tracker as ChatRunStatusPort).isThreadPending(threadId);
  }

  @override
  void dispose() {
    if (_disposed) return;
    if (kDebugMode) {
      debugPrint('[ChatState] controller=dispose id=${identityHashCode(this)}');
    }
    _terminalReadbackTimer?.cancel();
    _cancelTaskPollDelay();
    _cancelActiveAgentRunReads();
    _stopAgentProgressProjection();
    flushPendingConversationCache();
    _threadProgressPoller?.dispose();
    _textSubmissionEnvelopes.clear();
    _abandonableFailedTextMessageIds.clear();
    _disposed = true;
    _runTrackerListenable?.removeListener(_captureRunTrackerUpdate);
    _runtimeInvocationCacheRevision.dispose();
    _assistantAnswerDrafts.dispose();
    _agentProgressDrafts.dispose();
    super.dispose();
  }
}

int _suffixPrefixOverlap(String current, String incoming) {
  final maximum = current.length < incoming.length
      ? current.length
      : incoming.length;
  for (var length = maximum; length > 0; length -= 1) {
    final currentStart = current.length - length;
    var matches = true;
    for (var offset = 0; offset < length; offset += 1) {
      if (current.codeUnitAt(currentStart + offset) !=
          incoming.codeUnitAt(offset)) {
        matches = false;
        break;
      }
    }
    if (matches) return length;
  }
  return 0;
}

String _unseenCrossTransportSuffix(String current, String incoming) {
  if (incoming.isEmpty || current.contains(incoming)) return '';
  return incoming.substring(_suffixPrefixOverlap(current, incoming));
}
