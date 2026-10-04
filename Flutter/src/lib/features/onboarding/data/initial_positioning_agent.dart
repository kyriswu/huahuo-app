import 'package:huahuo_api/huahuo_api.dart';
import '../../chat/domain/chat_repository.dart';
import '../../chat/data/chat_thread_alias_repository.dart';
import '../../chat/domain/assistant_runtime.dart';
import '../../chat/domain/chat_context.dart';
import '../../chat/domain/chat_models.dart';

final class InitialPositioningRunReceipt {
  const InitialPositioningRunReceipt({
    required this.threadId,
    required this.agentRunId,
    required this.taskId,
    required this.messageId,
    required this.status,
  });

  final String threadId;
  final String agentRunId;
  final String taskId;
  final String messageId;
  final String status;
}

final class InitialPositioningProfileConclusion {
  const InitialPositioningProfileConclusion({
    required this.profileKind,
    required this.markdown,
  });

  final String profileKind;
  final String markdown;
}

final class InitialPositioningProfile {
  const InitialPositioningProfile({
    required this.workspaceId,
    required this.overview,
    required this.selfDescription,
    required this.positioning,
    required this.conclusions,
    this.positioningProgress,
  });

  final String workspaceId;
  final String overview;
  final String selfDescription;
  final String positioning;
  final List<InitialPositioningProfileConclusion> conclusions;
  final PositioningProgressProfile? positioningProgress;

  List<InitialPositioningProfileConclusion> get displayConclusions {
    final visible = <InitialPositioningProfileConclusion>[];
    if (positioning.trim().isNotEmpty) {
      visible.add(
        InitialPositioningProfileConclusion(
          profileKind: '定位档案',
          markdown: positioning,
        ),
      );
    }
    if (overview.trim().isNotEmpty) {
      visible.add(
        InitialPositioningProfileConclusion(
          profileKind: '用户概览',
          markdown: overview,
        ),
      );
    }
    if (selfDescription.trim().isNotEmpty) {
      visible.add(
        InitialPositioningProfileConclusion(
          profileKind: '自我描述',
          markdown: selfDescription,
        ),
      );
    }
    for (final conclusion in conclusions) {
      if (!visible.any((item) => item.markdown == conclusion.markdown)) {
        visible.add(conclusion);
      }
    }
    return List<InitialPositioningProfileConclusion>.unmodifiable(visible);
  }
}

final class InitialPositioningProfileRead {
  const InitialPositioningProfileRead._({this.profile, this.errorCode});

  factory InitialPositioningProfileRead.success(
    InitialPositioningProfile profile,
  ) => InitialPositioningProfileRead._(profile: profile);

  factory InitialPositioningProfileRead.failure(String errorCode) =>
      InitialPositioningProfileRead._(errorCode: errorCode);

  final InitialPositioningProfile? profile;
  final String? errorCode;

  bool get ok => profile != null;
}

abstract interface class InitialPositioningProfilePort {
  Future<ApiResult<ApiContractObject>> getCurrentProfile();
}

final class InitialPositioningProfileApi
    implements InitialPositioningProfilePort {
  const InitialPositioningProfileApi({
    required WorkspaceLifecycleClient workspaceClient,
  }) : _workspaceClient = workspaceClient;

  final WorkspaceLifecycleClient _workspaceClient;

  @override
  Future<ApiResult<ApiContractObject>> getCurrentProfile() =>
      _workspaceClient.currentProfile();
}

final class InitialPositioningAgentResult {
  const InitialPositioningAgentResult({
    required this.threadId,
    required this.report,
    required this.receipt,
    this.savedProfile,
    this.profileErrorCode,
  });

  final String threadId;
  final String report;
  final InitialPositioningRunReceipt receipt;
  final InitialPositioningProfile? savedProfile;
  final String? profileErrorCode;
}

final class InitialPositioningAgentSubmission {
  const InitialPositioningAgentSubmission._({this.data, this.errorCode});

  factory InitialPositioningAgentSubmission.success(
    InitialPositioningAgentResult data,
  ) => InitialPositioningAgentSubmission._(data: data);

  factory InitialPositioningAgentSubmission.failure(String errorCode) =>
      InitialPositioningAgentSubmission._(errorCode: errorCode);

  final InitialPositioningAgentResult? data;
  final String? errorCode;

  bool get ok => data != null;
}

abstract interface class InitialPositioningAgentPort {
  Future<InitialPositioningAgentSubmission> submit(String prompt);

  Future<InitialPositioningProfileRead> readSavedProfile();
}

final class InitialPositioningAgentAcceptance {
  const InitialPositioningAgentAcceptance._({this.receipt, this.errorCode});

  factory InitialPositioningAgentAcceptance.success(
    InitialPositioningRunReceipt receipt,
  ) => InitialPositioningAgentAcceptance._(receipt: receipt);

  factory InitialPositioningAgentAcceptance.failure(String errorCode) =>
      InitialPositioningAgentAcceptance._(errorCode: errorCode);

  final InitialPositioningRunReceipt? receipt;
  final String? errorCode;
  bool get ok => receipt != null;
}

/// Optional fast path used when the page should leave after public Run
/// acceptance while the account-wide tracker owns later polling.
abstract interface class InitialPositioningAgentAcceptedRunPort {
  Future<InitialPositioningAgentAcceptance> start(String prompt);

  Future<InitialPositioningAgentSubmission> completeAccepted(
    InitialPositioningRunReceipt receipt,
  );
}

bool _workspaceAlwaysReady() => true;

/// Runs the onboarding-only Position LV1 public protocol without exposing a
/// chat screen. This adapter intentionally owns the stricter run/readback
/// limits rather than inheriting the general chat conversation policy.
final class InitialPositioningAgent
    implements
        InitialPositioningAgentPort,
        InitialPositioningAgentAcceptedRunPort {
  InitialPositioningAgent({
    required ChatRepository chatRepository,
    required AssistantRuntimePort assistantRuntime,
    required ChatThreadAliasRepository threadAliasRepository,
    required InitialPositioningProfilePort profileApi,
    bool Function()? workspaceReady,
    DateTime Function()? now,
    Future<void> Function(Duration)? delay,
    this.pollAttempts = _initialPositioningMaxPollAttempts,
    this.pollInterval = const Duration(seconds: 2),
    this.threadReadbackRetries = _initialPositioningThreadReadbackRetries,
    this.threadReadbackInterval = const Duration(seconds: 1),
  }) : _chatRepository = chatRepository,
       _assistantRuntime = assistantRuntime,
       _threadAliasRepository = threadAliasRepository,
       _profileApi = profileApi,
       _workspaceReady = workspaceReady ?? _workspaceAlwaysReady,
       _now = now ?? DateTime.now,
       _delay = delay ?? _defaultDelay {
    if (pollAttempts < 1 || threadReadbackRetries < 0) {
      throw ArgumentError('Position LV1 polling limits must be valid');
    }
  }

  final ChatRepository _chatRepository;
  final AssistantRuntimePort _assistantRuntime;
  final ChatThreadAliasRepository _threadAliasRepository;
  final InitialPositioningProfilePort _profileApi;
  final bool Function() _workspaceReady;
  final DateTime Function() _now;
  final Future<void> Function(Duration) _delay;
  final int pollAttempts;
  final Duration pollInterval;
  final int threadReadbackRetries;
  final Duration threadReadbackInterval;
  int _submissionCounter = 0;

  @override
  Future<InitialPositioningAgentSubmission> submit(String prompt) async {
    final accepted = await start(prompt);
    final receipt = accepted.receipt;
    if (!accepted.ok || receipt == null) {
      return InitialPositioningAgentSubmission.failure(
        accepted.errorCode ?? 'ONBOARDING_AGENT_SEND_FAILED',
      );
    }
    return _completeAfterTerminal(receipt, waitForTerminal: true);
  }

  @override
  Future<InitialPositioningAgentAcceptance> start(String prompt) async {
    if (!_workspaceReady()) {
      return InitialPositioningAgentAcceptance.failure('WORKSPACE_NOT_READY');
    }
    final trimmed = prompt.trim();
    if (trimmed.isEmpty) {
      return InitialPositioningAgentAcceptance.failure(
        'ONBOARDING_AGENT_PROMPT_INVALID',
      );
    }

    final requestSuffix = _nextRequestSuffix();
    var idempotencyStore = SubmissionKeyStore.empty;
    final created = await _chatRepository.createThread(
      scene: ChatScene.workAi,
      purpose: ChatConversationPurpose.deepPositioning,
      idempotency: IdempotencyRequestContext(
        explicitKey: 'positioning-thread-$requestSuffix',
      ),
      idempotencyStore: idempotencyStore,
    );
    idempotencyStore = created.idempotencyStore;
    final thread = created.data;
    if (!created.ok || thread == null) {
      return InitialPositioningAgentAcceptance.failure(
        created.error?.code ?? 'ONBOARDING_THREAD_CREATE_FAILED',
      );
    }
    if (!isSafeChatIdentifier(thread.threadId)) {
      return InitialPositioningAgentAcceptance.failure(
        'ONBOARDING_THREAD_RECEIPT_INVALID',
      );
    }
    try {
      _threadAliasRepository.markThreadPurpose(
        scene: ChatScene.workAi,
        threadId: thread.threadId,
        purpose: ChatConversationPurpose.deepPositioning,
      );
    } catch (_) {
      return InitialPositioningAgentAcceptance.failure(
        'ONBOARDING_THREAD_LOCAL_METADATA_SAVE_FAILED',
      );
    }

    final submitted = await _chatRepository.sendTextMessage(
      threadId: thread.threadId,
      scene: ChatScene.workAi,
      content: trimmed,
      context: ChatContextEnvelope.create(
        purpose: ChatContextPurpose.deepPositioning,
        entryPoint: const ChatContextEntryPoint(surface: 'onboarding_card'),
        includeAccountProfile: true,
      ),
      agentProfileId: 'positioning_lv1',
      idempotency: IdempotencyRequestContext(
        explicitKey: 'positioning-message-$requestSuffix',
      ),
      idempotencyStore: idempotencyStore,
    );
    final mutation = submitted.data;
    if (!submitted.ok || mutation == null) {
      return InitialPositioningAgentAcceptance.failure(
        submitted.error?.code ?? 'ONBOARDING_AGENT_SEND_FAILED',
      );
    }

    final receipt = _receiptFromMutation(mutation, thread.threadId);
    if (receipt == null) {
      return InitialPositioningAgentAcceptance.failure(
        'ONBOARDING_AGENT_RECEIPT_INVALID',
      );
    }

    return InitialPositioningAgentAcceptance.success(receipt);
  }

  @override
  Future<InitialPositioningAgentSubmission> completeAccepted(
    InitialPositioningRunReceipt receipt,
  ) => _completeAfterTerminal(receipt, waitForTerminal: false);

  Future<InitialPositioningAgentSubmission> _completeAfterTerminal(
    InitialPositioningRunReceipt receipt, {
    required bool waitForTerminal,
  }) async {
    final terminal = waitForTerminal
        ? await _waitForTerminalRun(receipt)
        : await _readTerminalRunOnce(receipt);
    if (terminal.run == null) {
      return InitialPositioningAgentSubmission.failure(
        terminal.errorCode ?? 'ONBOARDING_AGENT_RUN_TIMEOUT',
      );
    }

    final reportRead = await _readDurableReport(
      receipt: receipt,
      run: terminal.run!,
    );
    if (reportRead.report == null) {
      return InitialPositioningAgentSubmission.failure(
        reportRead.errorCode ?? 'ONBOARDING_AGENT_REPORT_UNAVAILABLE',
      );
    }

    final profileRead = await readSavedProfile();
    return InitialPositioningAgentSubmission.success(
      InitialPositioningAgentResult(
        threadId: receipt.threadId,
        report: reportRead.report!,
        receipt: receipt,
        savedProfile: profileRead.profile,
        profileErrorCode: profileRead.errorCode,
      ),
    );
  }

  Future<_TerminalRunRead> _readTerminalRunOnce(
    InitialPositioningRunReceipt receipt,
  ) async {
    final result = await _assistantRuntime.readRun(
      handle: AssistantRunHandle(receipt.agentRunId),
    );
    final run = result.data;
    if (!result.ok || run == null) {
      return _TerminalRunRead.failure(
        result.errorCode ?? 'ONBOARDING_AGENT_RUN_POLL_FAILED',
      );
    }
    if (run.handle.value != receipt.agentRunId ||
        (run.conversationId != null &&
            run.conversationId != receipt.threadId) ||
        (run.correlationId != null && run.correlationId != receipt.taskId)) {
      return const _TerminalRunRead.failure(
        'ONBOARDING_AGENT_RUN_BINDING_INVALID',
      );
    }
    if (!run.isTerminal) {
      return const _TerminalRunRead.failure('ONBOARDING_AGENT_RUN_IN_PROGRESS');
    }
    final errorCode = _terminalRunErrorCode(run);
    return errorCode == null
        ? _TerminalRunRead.success(run)
        : _TerminalRunRead.failure(errorCode);
  }

  @override
  Future<InitialPositioningProfileRead> readSavedProfile() async {
    final result = await _profileApi.getCurrentProfile();
    if (!result.ok || result.data == null) {
      return InitialPositioningProfileRead.failure(
        result.error?.code ?? 'ONBOARDING_PROFILE_READ_FAILED',
      );
    }
    final profile = _profileFromSnapshot(result.data!);
    return profile == null
        ? InitialPositioningProfileRead.failure(
            'ONBOARDING_PROFILE_RESPONSE_INVALID',
          )
        : InitialPositioningProfileRead.success(profile);
  }

  Future<_TerminalRunRead> _waitForTerminalRun(
    InitialPositioningRunReceipt receipt,
  ) async {
    String? lastPollErrorCode;
    for (var attempt = 0; attempt < pollAttempts; attempt += 1) {
      await _delay(pollInterval);
      final result = await _assistantRuntime.readRun(
        handle: AssistantRunHandle(receipt.agentRunId),
      );
      final run = result.data;
      if (!result.ok || run == null) {
        lastPollErrorCode =
            result.errorCode ?? 'ONBOARDING_AGENT_RUN_POLL_FAILED';
        continue;
      }
      lastPollErrorCode = null;
      if (run.handle.value != receipt.agentRunId ||
          (run.conversationId != null &&
              run.conversationId != receipt.threadId) ||
          (run.correlationId != null && run.correlationId != receipt.taskId)) {
        return const _TerminalRunRead.failure(
          'ONBOARDING_AGENT_RUN_BINDING_INVALID',
        );
      }
      if (!run.isTerminal) continue;
      final errorCode = _terminalRunErrorCode(run);
      return errorCode == null
          ? _TerminalRunRead.success(run)
          : _TerminalRunRead.failure(errorCode);
    }
    return _TerminalRunRead.failure(
      lastPollErrorCode ?? 'ONBOARDING_AGENT_RUN_TIMEOUT',
    );
  }

  Future<_DurableReportRead> _readDurableReport({
    required InitialPositioningRunReceipt receipt,
    required AssistantRunSnapshot run,
  }) async {
    String? lastReadErrorCode;
    for (var attempt = 0; attempt <= threadReadbackRetries; attempt += 1) {
      if (attempt > 0) await _delay(threadReadbackInterval);
      final result = await _chatRepository.getThreadDetail(
        threadId: receipt.threadId,
      );
      final detail = result.data;
      if (!result.ok || detail == null) {
        lastReadErrorCode =
            result.error?.code ?? 'ONBOARDING_THREAD_READBACK_FAILED';
        continue;
      }
      if (detail.thread.threadId != receipt.threadId) {
        lastReadErrorCode = 'ONBOARDING_THREAD_READBACK_INVALID';
        continue;
      }
      final assistant = _findAssistantReport(
        detail.messages,
        receipt: receipt,
        expectedMessageId: run.output?.messageId,
      );
      final report = _durablePositioningReport(assistant?.visibleText ?? '');
      if (report != null && report.isNotEmpty) {
        return _DurableReportRead.success(report);
      }
    }
    return _DurableReportRead.failure(
      lastReadErrorCode ?? 'ONBOARDING_AGENT_REPORT_UNAVAILABLE',
    );
  }

  ChatMessage? _findAssistantReport(
    Iterable<ChatMessage> messages, {
    required InitialPositioningRunReceipt receipt,
    required String? expectedMessageId,
  }) {
    final assistants = <ChatMessage>[
      for (final message in messages)
        if (message.role == ChatMessageRole.assistant &&
            (message.visibleText?.trim().isNotEmpty ?? false))
          message,
    ];
    ChatMessage? firstWhere(bool Function(ChatMessage message) test) {
      for (final message in assistants) {
        if (test(message)) return message;
      }
      return null;
    }

    return (expectedMessageId == null
            ? null
            : firstWhere(
                (message) => message.messageId == expectedMessageId,
              )) ??
        firstWhere((message) => message.agentRunId == receipt.agentRunId) ??
        firstWhere((message) => message.taskId == receipt.taskId) ??
        (assistants.isEmpty ? null : assistants.last);
  }

  InitialPositioningRunReceipt? _receiptFromMutation(
    ChatTextMutation mutation,
    String expectedThreadId,
  ) {
    final agentRunId = mutation.nextAction.agentRunId;
    final taskId = mutation.nextAction.taskId;
    final messageId = mutation.receiptMessageId ?? mutation.message?.messageId;
    final status = mutation.receiptStatus?.trim();
    final receiptThreadId = mutation.receiptThreadId;
    if (agentRunId == null ||
        !agentRunId.startsWith('agent_run_') ||
        !isSafeAgentRunIdentifier(agentRunId) ||
        taskId == null ||
        !isSafeChatIdentifier(taskId) ||
        messageId == null ||
        !isSafeChatIdentifier(messageId) ||
        status == null ||
        status.isEmpty ||
        receiptThreadId == null ||
        !isSafeChatIdentifier(receiptThreadId) ||
        (mutation.message != null &&
            mutation.message!.messageId != messageId) ||
        receiptThreadId != expectedThreadId) {
      return null;
    }
    return InitialPositioningRunReceipt(
      threadId: receiptThreadId,
      agentRunId: agentRunId,
      taskId: taskId,
      messageId: messageId,
      status: status,
    );
  }

  String _nextRequestSuffix() {
    _submissionCounter += 1;
    return '${_now().toUtc().microsecondsSinceEpoch}-$_submissionCounter';
  }
}

final class _TerminalRunRead {
  const _TerminalRunRead.success(this.run) : errorCode = null;

  const _TerminalRunRead.failure(this.errorCode) : run = null;

  final AssistantRunSnapshot? run;
  final String? errorCode;
}

final class _DurableReportRead {
  const _DurableReportRead.success(this.report) : errorCode = null;

  const _DurableReportRead.failure(this.errorCode) : report = null;

  final String? report;
  final String? errorCode;
}

String? _terminalRunErrorCode(AssistantRunSnapshot run) {
  switch (run.status) {
    case AssistantRunStatus.failed:
      return run.failure?.code ?? 'ONBOARDING_AGENT_RUN_FAILED';
    case AssistantRunStatus.timedOut:
      return 'ONBOARDING_AGENT_RUN_TIMEOUT';
    case AssistantRunStatus.cancelled:
      return 'ONBOARDING_AGENT_RUN_CANCELLED';
    case AssistantRunStatus.orphaned:
      return 'ONBOARDING_AGENT_RUN_ORPHANED';
    case AssistantRunStatus.succeeded:
      if (run.failure != null) return run.failure!.code;
      return switch (run.completionQuality) {
        AssistantCompletionQuality.normal => null,
        AssistantCompletionQuality.degraded => 'ONBOARDING_AGENT_RUN_DEGRADED',
        AssistantCompletionQuality.fallback =>
          'ONBOARDING_AGENT_RUN_SYSTEM_FALLBACK',
        AssistantCompletionQuality.cancelled =>
          'ONBOARDING_AGENT_RUN_CANCELLED',
        AssistantCompletionQuality.unknown =>
          'ONBOARDING_AGENT_RUN_RESULT_INVALID',
      };
    case AssistantRunStatus.resolving ||
        AssistantRunStatus.planning ||
        AssistantRunStatus.waitingForInput ||
        AssistantRunStatus.queued ||
        AssistantRunStatus.running ||
        AssistantRunStatus.stopping ||
        AssistantRunStatus.unknown:
      return 'ONBOARDING_AGENT_RUN_RESULT_INVALID';
  }
}

final RegExp _positioningProgressSidecar = RegExp(
  r'^[ \t]*```[ \t]*huahuo-positioning-progress[ \t]*\r?\n.*?^[ \t]*```[ \t]*(?:\r?\n|$)',
  multiLine: true,
  dotAll: true,
);

String? _durablePositioningReport(String source) {
  final durable = source.trim();
  final visible = durable.replaceAll(_positioningProgressSidecar, '').trim();
  return visible.isEmpty ? null : durable;
}

InitialPositioningProfile? _profileFromSnapshot(ApiContractObject snapshot) {
  final fields = snapshot.fields;
  final workspaceId = _safeProfileIdentifier(fields['workspaceId']);
  if (workspaceId == null) return null;
  final conclusions = <InitialPositioningProfileConclusion>[];
  final rawConclusions = fields['conclusions'];
  if (rawConclusions is List) {
    for (final raw in rawConclusions) {
      final conclusion = asObjectMap(raw);
      if (conclusion == null) continue;
      final markdown = _safeProfileText(conclusion['markdown']);
      if (markdown == null) continue;
      conclusions.add(
        InitialPositioningProfileConclusion(
          profileKind: _safeProfileText(conclusion['profileKind']) ?? '正式资料',
          markdown: markdown,
        ),
      );
    }
  }
  return InitialPositioningProfile(
    workspaceId: workspaceId,
    overview: _safeProfileText(fields['overview']) ?? '',
    selfDescription: _safeProfileText(fields['selfDescription']) ?? '',
    positioning: _safeProfileText(fields['positioning']) ?? '',
    positioningProgress: parsePositioningProgressPayload(
      fields['positioningProgress'],
    ),
    conclusions: List<InitialPositioningProfileConclusion>.unmodifiable(
      conclusions,
    ),
  );
}

String? _safeProfileIdentifier(Object? value) {
  final text = value is String ? value.trim() : null;
  return text != null && isSafeChatIdentifier(text) ? text : null;
}

String? _safeProfileText(Object? value) {
  final text = value is String ? value.trim() : null;
  return text == null || text.length > _maxProfileTextLength ? null : text;
}

Future<void> _defaultDelay(Duration duration) => Future<void>.delayed(duration);

const _initialPositioningMaxPollAttempts = 180;
const _initialPositioningThreadReadbackRetries = 10;
const _maxProfileTextLength = 24000;
