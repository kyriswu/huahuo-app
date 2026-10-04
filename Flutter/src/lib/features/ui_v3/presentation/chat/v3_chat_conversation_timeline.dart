import 'package:huahuo_api/huahuo_api.dart';
import 'package:huahuoai_app/shared/markdown/v3_markdown.dart';
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../app/di/chat_providers.dart';
import '../../../../shared/theme/huahuo_v3_theme.dart';
import '../../../../shared/ui_v3/v3_chat_mark.dart';
import '../../../../shared/ui_v3/v3_components.dart';
import '../../../../shared/ui_v3/v3_text_editing.dart';
import '../../../chat/application/chat_controller.dart';
import '../../../chat/application/chat_run_tracker.dart';
import '../../../chat/application/chat_stream_reveal_buffer.dart';
import '../../../chat/domain/assistant_runtime.dart';
import '../../../chat/domain/chat_models.dart';
import '../v3_chat_execution_process.dart' show V3AgentRunGlyph;
import '../v3_positioning_dashboard.dart';

typedef V3ChatImageAttachmentsBuilder =
    Widget Function(
      BuildContext context,
      List<ChatImageAttachment> attachments,
      bool generatedByAssistant,
    );
typedef V3ChatResourceAttachmentsBuilder =
    Widget Function(
      BuildContext context,
      List<ChatResourceAttachment> attachments,
    );
typedef V3ChatCreateNoteActionResolver =
    Future<void> Function()? Function(ChatMessage message);
typedef V3ChatRuntimeInvocationReader =
    Future<ChatRuntimeInvocationHistorySnapshot> Function(String threadId);
typedef V3ChatRetryMessageActionResolver =
    VoidCallback? Function(ChatMessage message);

class V3ChatConversationTimeline extends ConsumerStatefulWidget {
  const V3ChatConversationTimeline({
    required this.threadId,
    required this.messages,
    required this.fallbackRunStatuses,
    required this.fallbackToolRunId,
    required this.fallbackToolTrace,
    required this.isSending,
    required this.isThreadPending,
    required this.assistantAnswerDrafts,
    required this.imageAttachmentsBuilder,
    required this.resourceAttachmentsBuilder,
    required this.isCreatingNote,
    required this.createNoteActionFor,
    required this.onStreamingRebuild,
    required this.onRunRebuild,
    this.runtimeInvocationReader,
    this.retryFailedMessageActionFor,
    this.suppressStandaloneActivity = false,
    this.digitalTwinStyle = false,
    super.key,
  });

  final String? threadId;
  final List<ChatMessage> messages;
  final Map<String, String?> fallbackRunStatuses;
  final String? fallbackToolRunId;
  final List<AssistantToolTrace> fallbackToolTrace;
  final bool isSending;
  final bool Function() isThreadPending;
  final ValueListenable<Map<String, ChatAssistantAnswerDraft>>
  assistantAnswerDrafts;
  final V3ChatImageAttachmentsBuilder imageAttachmentsBuilder;
  final V3ChatResourceAttachmentsBuilder resourceAttachmentsBuilder;
  final bool Function(ChatMessage message) isCreatingNote;
  final V3ChatCreateNoteActionResolver createNoteActionFor;
  final VoidCallback onStreamingRebuild;
  final VoidCallback onRunRebuild;
  final V3ChatRuntimeInvocationReader? runtimeInvocationReader;
  final V3ChatRetryMessageActionResolver? retryFailedMessageActionFor;
  final bool suppressStandaloneActivity;
  final bool digitalTwinStyle;

  @override
  ConsumerState<V3ChatConversationTimeline> createState() =>
      _V3ChatConversationTimelineState();
}

class _V3ChatConversationTimelineState
    extends ConsumerState<V3ChatConversationTimeline> {
  static const _maxRunSnapshots = 12;

  late Set<String> _knownDurableAssistantIds;
  final Set<String> _newDurableAssistantIds = <String>{};
  final Set<String> _completedLocalRevealIds = <String>{};
  final Set<String> _liveLocalRevealIds = <String>{};
  final Set<String> _runsWithDraft = <String>{};
  final Set<String> _observedActiveRunIds = <String>{};
  final Map<String, _RunPresentation> _runSnapshots =
      <String, _RunPresentation>{};
  Set<String> _activeRunIds = const <String>{};
  Timer? _runtimeRefreshTimer;
  bool _runtimeRefreshSyncScheduled = false;
  Map<String, SharedThreadRuntimeInvocation> _runtimeInvocationsByRunId =
      const <String, SharedThreadRuntimeInvocation>{};
  Set<String> _runtimeFinalizationRunIds = const <String>{};
  bool _runtimeHistoryLoaded = false;
  bool _runtimeReadInFlight = false;
  int _runtimeRefreshFailures = 0;

  @override
  void initState() {
    super.initState();
    _knownDurableAssistantIds = _durableAssistantIds(widget.messages);
    _rememberDraftRuns(widget.messages);
    _syncRuntimeRefreshTimer();
  }

  @override
  void didUpdateWidget(covariant V3ChatConversationTimeline oldWidget) {
    super.didUpdateWidget(oldWidget);
    final threadChanged = oldWidget.threadId != widget.threadId;
    if (threadChanged) {
      _runSnapshots.clear();
      _runsWithDraft.clear();
      _observedActiveRunIds.clear();
      _newDurableAssistantIds.clear();
      _completedLocalRevealIds.clear();
      _liveLocalRevealIds.clear();
      _runtimeInvocationsByRunId =
          const <String, SharedThreadRuntimeInvocation>{};
      _runtimeFinalizationRunIds = const <String>{};
      _runtimeHistoryLoaded = false;
      _runtimeRefreshFailures = 0;
      _activeRunIds = const <String>{};
    }
    if (!threadChanged) _rememberDraftRuns(oldWidget.messages);
    _rememberDraftRuns(widget.messages);
    final current = _durableAssistantIds(widget.messages);
    if (!threadChanged) {
      final added = current.difference(_knownDurableAssistantIds);
      _newDurableAssistantIds.addAll(added);
      for (final message in widget.messages) {
        if (!added.contains(message.messageId)) continue;
        final runId = _messageRunIdentity(message);
        if (runId != null && _observedActiveRunIds.contains(runId)) {
          _liveLocalRevealIds.add(message.messageId);
        }
      }
    }
    _newDurableAssistantIds.removeWhere((id) => !current.contains(id));
    _completedLocalRevealIds.removeWhere((id) => !current.contains(id));
    _liveLocalRevealIds.removeWhere((id) => !current.contains(id));
    _knownDurableAssistantIds = current;
    if (threadChanged ||
        (oldWidget.runtimeInvocationReader == null) !=
            (widget.runtimeInvocationReader == null)) {
      if (!threadChanged) _runtimeHistoryLoaded = false;
      _syncRuntimeRefreshTimer();
    }
  }

  @override
  void dispose() {
    _runtimeRefreshTimer?.cancel();
    super.dispose();
  }

  void _syncRuntimeRefreshTimer() {
    final shouldRefresh =
        widget.threadId != null &&
        widget.runtimeInvocationReader != null &&
        (!_runtimeHistoryLoaded ||
            _activeRunIds.isNotEmpty ||
            _runtimeFinalizationRunIds.isNotEmpty);
    if (!shouldRefresh) {
      _runtimeRefreshTimer?.cancel();
      _runtimeRefreshTimer = null;
      return;
    }
    _runtimeRefreshTimer ??= Timer(_runtimeRefreshDelay, () {
      _runtimeRefreshTimer = null;
      unawaited(
        _refreshRuntimeInvocations().whenComplete(() {
          if (mounted) _syncRuntimeRefreshTimer();
        }),
      );
    });
  }

  Duration get _runtimeRefreshDelay {
    if (_runtimeHistoryLoaded || _runtimeRefreshFailures <= 1) {
      return const Duration(seconds: 1);
    }
    const retrySeconds = <int>[1, 2, 4, 8, 16, 30];
    final index = (_runtimeRefreshFailures - 1).clamp(
      0,
      retrySeconds.length - 1,
    );
    return Duration(seconds: retrySeconds[index]);
  }

  void _scheduleRuntimeRefreshSync() {
    if (_runtimeRefreshSyncScheduled) return;
    _runtimeRefreshSyncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runtimeRefreshSyncScheduled = false;
      if (mounted) _syncRuntimeRefreshTimer();
    });
  }

  Future<void> _refreshRuntimeInvocations() async {
    final threadId = widget.threadId;
    final reader = widget.runtimeInvocationReader;
    if (threadId == null ||
        reader == null ||
        (_runtimeHistoryLoaded &&
            _activeRunIds.isEmpty &&
            _runtimeFinalizationRunIds.isEmpty) ||
        _runtimeReadInFlight) {
      return;
    }
    _runtimeReadInFlight = true;
    try {
      final snapshot = await reader(threadId);
      if (!mounted || widget.threadId != threadId) return;
      final invocations = <String, SharedThreadRuntimeInvocation>{
        for (final invocation in snapshot.items)
          if (invocation.threadId == threadId)
            invocation.agentRunId: invocation,
      };
      final loaded = snapshot.isSettled;
      _runtimeRefreshFailures = loaded ? 0 : _runtimeRefreshFailures + 1;
      if (_runtimeHistoryLoaded == loaded &&
          _sameRuntimeInvocationMap(_runtimeInvocationsByRunId, invocations)) {
        return;
      }
      setState(() {
        _runtimeHistoryLoaded = loaded;
        _runtimeInvocationsByRunId = invocations;
      });
    } catch (_) {
      // Runtime observability is optional and must never replace Chat state.
      _runtimeRefreshFailures += 1;
    } finally {
      _runtimeReadInFlight = false;
    }
  }

  Set<String> _durableAssistantIds(List<ChatMessage> messages) => <String>{
    for (final message in messages)
      if (message.role == ChatMessageRole.assistant &&
          !_isProgressMessage(message))
        message.messageId,
  };

  void _rememberDraftRuns(List<ChatMessage> messages) {
    for (final message in messages) {
      if (!_isProgressMessage(message) ||
          message.visibleText?.isNotEmpty != true) {
        continue;
      }
      final runId = _messageRunIdentity(message);
      if (runId != null) _runsWithDraft.add(runId);
    }
  }

  void _rememberRunSnapshots(Iterable<_RunPresentation> presentations) {
    for (final presentation in presentations) {
      _runSnapshots.remove(presentation.runKey);
      _runSnapshots[presentation.runKey] = presentation;
    }
    while (_runSnapshots.length > _maxRunSnapshots) {
      _runSnapshots.remove(_runSnapshots.keys.first);
    }
  }

  @override
  Widget build(BuildContext context) {
    final threadId = widget.threadId;
    final threadPending = widget.isThreadPending();
    final runState = threadId == null
        ? ChatThreadRunState.empty
        : ref.watch(chatThreadRunStateProvider(threadId));
    final trackedRunIds = <String>{
      for (final activity in runState.activities) activity.agentRunId,
    };
    final presentations = <String, _RunPresentation>{..._runSnapshots};
    for (final activity in runState.activities) {
      final existing = presentations[activity.agentRunId];
      presentations[activity.agentRunId] = existing == null
          ? _RunPresentation.fromActivity(activity)
          : existing.mergeActivity(activity);
    }
    if (threadPending || widget.isSending) {
      for (final entry in widget.fallbackRunStatuses.entries) {
        final runId = entry.key;
        if (trackedRunIds.contains(runId) ||
            !_isVisibleRunStatus(entry.value)) {
          continue;
        }
        final existing = presentations[runId];
        if (existing?.isTerminal == true) continue;
        final latestTools = runId == widget.fallbackToolRunId
            ? _safeToolReceipts(widget.fallbackToolTrace)
            : const <_SafeToolReceipt>[];
        final mergedTools = <String, _SafeToolReceipt>{
          for (final tool in existing?.toolTrace ?? const <_SafeToolReceipt>[])
            tool.identity: tool,
          for (final tool in latestTools) tool.identity: tool,
        };
        presentations[runId] = _RunPresentation(
          runKey: runId,
          runStatus: entry.value,
          startedAt: existing?.startedAt ?? DateTime.now().toUtc(),
          completedAt: existing?.completedAt,
          toolTrace: List<_SafeToolReceipt>.unmodifiable(mergedTools.values),
          progress: existing?.progress ?? const <_SafeProgressReceipt>[],
          runtimeHydrated: existing?.runtimeHydrated ?? false,
          runtimeTerminalHydrated: existing?.runtimeTerminalHydrated ?? false,
        );
      }
    }

    final completion = runState.latestCompletion;
    if (completion != null) {
      presentations[completion.agentRunId] = _RunPresentation.fromCompletion(
        completion,
        existing: presentations[completion.agentRunId],
      );
    }

    final durableRunIds = <String>{};
    for (final message in widget.messages) {
      final runId = _messageRunIdentity(message);
      if (message.role == ChatMessageRole.assistant &&
          !_isProgressMessage(message) &&
          runId != null) {
        durableRunIds.add(runId);
      }
    }
    for (final invocation in _runtimeInvocationsByRunId.values) {
      final presentation = presentations[invocation.agentRunId];
      if (invocation.threadId != threadId) continue;
      presentations[invocation.agentRunId] = presentation == null
          ? _RunPresentation.fromRuntime(invocation)
          : presentation.mergeRuntime(invocation);
    }
    for (final message in widget.messages) {
      final runId = _messageRunIdentity(message);
      final presentation = runId == null ? null : presentations[runId];
      if (message.role != ChatMessageRole.assistant ||
          _isProgressMessage(message) ||
          presentation == null) {
        continue;
      }
      presentations[runId!] = presentation.asTerminal(
        completedAt: message.createdAt,
      );
    }
    final nextRuntimeFinalizationRunIds = <String>{};
    for (final presentation in presentations.values) {
      final invocation = _runtimeInvocationsByRunId[presentation.runKey];
      if (presentation.isTerminal &&
          !presentation.runtimeTerminalHydrated &&
          invocation != null &&
          _isVisibleRunStatus(invocation.status)) {
        nextRuntimeFinalizationRunIds.add(presentation.runKey);
      }
    }
    final runtimeFinalizationChanged = !setEquals(
      _runtimeFinalizationRunIds,
      nextRuntimeFinalizationRunIds,
    );
    if (runtimeFinalizationChanged) {
      _runtimeFinalizationRunIds = nextRuntimeFinalizationRunIds;
    }
    final mutableRunId = _selectMutableRunId(
      presentations.values,
      preferredRunId: widget.fallbackToolRunId,
    );
    _observedActiveRunIds.addAll(
      presentations.values
          .where((presentation) => !presentation.isTerminal)
          .map((presentation) => presentation.runKey),
    );
    _rememberRunSnapshots(presentations.values);
    final nextActiveRunIds = <String>{
      for (final presentation in presentations.values)
        if (!presentation.isTerminal) presentation.runKey,
    };
    final activeRunsChanged = !setEquals(_activeRunIds, nextActiveRunIds);
    if (activeRunsChanged) {
      final needsTerminalRefresh =
          _activeRunIds.isNotEmpty && nextActiveRunIds.isEmpty;
      final runtimeAlreadyTerminal = _activeRunIds.every((runId) {
        final invocation = _runtimeInvocationsByRunId[runId];
        return invocation != null && !_isVisibleRunStatus(invocation.status);
      });
      _activeRunIds = nextActiveRunIds;
      if (needsTerminalRefresh && !runtimeAlreadyTerminal) {
        _runtimeHistoryLoaded = false;
      }
    }
    if (activeRunsChanged || runtimeFinalizationChanged) {
      _scheduleRuntimeRefreshSync();
    }
    if (presentations.isNotEmpty) widget.onRunRebuild();
    final consumedRunIds = <String>{};
    final turns = <Widget>[];
    for (final message in widget.messages) {
      if (message.role == ChatMessageRole.user) {
        turns.add(_buildUserTurn(message));
        continue;
      }

      final progress = _isProgressMessage(message);
      final runId = _messageRunIdentity(message);
      if (progress && runId != null && durableRunIds.contains(runId)) {
        continue;
      }
      if (runId != null) consumedRunIds.add(runId);
      final run = runId == null ? null : presentations[runId];
      turns.add(
        _buildAssistantTurn(
          message: message,
          run: run,
          progress: progress,
          mutableRunId: mutableRunId,
        ),
      );
    }

    if (!widget.suppressStandaloneActivity) {
      for (final run in presentations.values) {
        if (consumedRunIds.contains(run.runKey) ||
            (!run.isTerminal && run.runKey != mutableRunId) ||
            (run.isTerminal && !_observedActiveRunIds.contains(run.runKey))) {
          continue;
        }
        turns.add(_buildAssistantTurn(run: run, mutableRunId: mutableRunId));
      }
    }

    return SliverList.list(
      children: <Widget>[
        for (final turn in turns) ...[turn, const SizedBox(height: 22)],
      ],
    );
  }

  Widget _buildUserTurn(ChatMessage message) {
    final text = _messageText(message);
    return V3ChatUserTurn(
      digitalTwinStyle: widget.digitalTwinStyle,
      key: ValueKey<String>('chat-user-turn-${message.messageId}'),
      message: message,
      text: text,
      imageAttachmentsBuilder: widget.imageAttachmentsBuilder,
      resourceAttachmentsBuilder: widget.resourceAttachmentsBuilder,
      onCopy: () => V3TextEditing.copy(context, text),
      onRetry: widget.retryFailedMessageActionFor?.call(message),
    );
  }

  Widget _buildAssistantTurn({
    ChatMessage? message,
    _RunPresentation? run,
    bool progress = false,
    String? mutableRunId,
  }) {
    final messageId = message?.messageId;
    final runKey = run?.runKey ?? _messageRunIdentity(message!) ?? messageId!;
    final terminalAt = run?.isTerminal == true ? message?.createdAt : null;
    final draftKey = run?.runKey ?? _messageRunIdentity(message!) ?? messageId!;
    final shouldLocalReveal =
        message != null &&
        !progress &&
        _newDurableAssistantIds.contains(messageId) &&
        _liveLocalRevealIds.contains(messageId) &&
        !_completedLocalRevealIds.contains(messageId) &&
        !_runsWithDraft.contains(draftKey);
    return _V3ChatAssistantTurn(
      digitalTwinStyle: widget.digitalTwinStyle,
      key: ValueKey<String>('chat-assistant-turn-$runKey'),
      runKey: runKey,
      message: message,
      runStatus: run?.runStatus,
      toolTrace: run?.toolTrace ?? const <_SafeToolReceipt>[],
      progress: run?.progress ?? const <_SafeProgressReceipt>[],
      startedAt: run?.startedAt ?? (progress ? message?.createdAt : null),
      terminalAt: run?.completedAt ?? terminalAt,
      processTerminal: run?.isTerminal == true,
      showProcess:
          run?.isTerminal == true ||
          run?.runKey == mutableRunId ||
          (run == null && progress),
      progressMessage: progress,
      localReveal: shouldLocalReveal,
      assistantAnswerDrafts: widget.assistantAnswerDrafts,
      imageAttachmentsBuilder: widget.imageAttachmentsBuilder,
      resourceAttachmentsBuilder: widget.resourceAttachmentsBuilder,
      isCreatingNote: message != null && widget.isCreatingNote(message),
      onCreateNote: message == null
          ? null
          : widget.createNoteActionFor(message),
      onStreamingRebuild: widget.onStreamingRebuild,
      onLocalRevealCompleted: messageId == null
          ? null
          : () {
              _newDurableAssistantIds.remove(messageId);
              _liveLocalRevealIds.remove(messageId);
              _completedLocalRevealIds.add(messageId);
            },
    );
  }
}

class V3ChatUserTurn extends StatelessWidget {
  const V3ChatUserTurn({
    required this.message,
    required this.text,
    required this.imageAttachmentsBuilder,
    required this.resourceAttachmentsBuilder,
    required this.onCopy,
    this.onRetry,
    this.digitalTwinStyle = false,
    super.key,
  });

  final ChatMessage message;
  final String text;
  final V3ChatImageAttachmentsBuilder imageAttachmentsBuilder;
  final V3ChatResourceAttachmentsBuilder resourceAttachmentsBuilder;
  final VoidCallback onCopy;
  final VoidCallback? onRetry;
  final bool digitalTwinStyle;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final eventTime = _formatChatMessageTime(message.createdAt);
    final deliveryText = switch (message.localDelivery) {
      ChatLocalDeliveryState.server => null,
      ChatLocalDeliveryState.pending => '发送中',
      ChatLocalDeliveryState.failed => '发送失败',
    };
    final metadata = <String>[
      eventTime == null ? '发送时间未知' : '发送于 $eventTime',
      if (deliveryText != null) deliveryText,
    ].join(' · ');
    return Align(
      alignment: Alignment.centerRight,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: digitalTwinStyle ? 296 : 358),
        child: Container(
          key: ValueKey<String>('chat-user-glass-${message.messageId}'),
          decoration: BoxDecoration(
            color: digitalTwinStyle
                ? const Color(0xFF2B2333)
                : colors.surfaceMuted,
            borderRadius: BorderRadius.circular(digitalTwinStyle ? 10 : 12),
            boxShadow: digitalTwinStyle
                ? []
                : [
                    BoxShadow(
                      color: colors.ink.withValues(alpha: .035),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
          ),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: digitalTwinStyle ? 12 : 18,
              vertical: digitalTwinStyle ? 10 : 14,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final reference in message.assetReferences) ...[
                  _V3ChatUserAssetReferenceCard(reference: reference),
                  const SizedBox(height: 8),
                ],
                if (text.isNotEmpty)
                  SelectionArea(
                    key: ValueKey<String>(
                      'chat-user-selection-${message.messageId}',
                    ),
                    contextMenuBuilder: V3TextEditing.buildSelectionContextMenu,
                    child: Text(
                      text,
                      style: TextStyle(
                        color: colors.text,
                        fontFamily: digitalTwinStyle ? 'Noto Sans SC' : null,
                        fontSize: digitalTwinStyle ? 12 : 15,
                        height: digitalTwinStyle ? 20 / 12 : 1.35,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                  ),
                if (message.imageAttachments.isNotEmpty) ...[
                  if (text.isNotEmpty) const SizedBox(height: 10),
                  imageAttachmentsBuilder(
                    context,
                    message.imageAttachments,
                    false,
                  ),
                ],
                if (message.resourceAttachments.isNotEmpty) ...[
                  if (text.isNotEmpty || message.imageAttachments.isNotEmpty)
                    const SizedBox(height: 10),
                  resourceAttachmentsBuilder(
                    context,
                    message.resourceAttachments,
                  ),
                ],
                const SizedBox(height: 6),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (message.localDelivery ==
                        ChatLocalDeliveryState.pending) ...[
                      SizedBox.square(
                        key: const ValueKey<String>(
                          'chat-pending-send-progress',
                        ),
                        dimension: 13,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.8,
                          color: colors.primary,
                        ),
                      ),
                      const SizedBox(width: 6),
                    ],
                    Expanded(
                      child: Text(
                        metadata,
                        style: TextStyle(
                          color: colors.muted,
                          fontSize: 11,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                    ),
                    if (message.localDelivery ==
                            ChatLocalDeliveryState.failed &&
                        onRetry != null)
                      TextButton.icon(
                        key: ValueKey<String>(
                          'chat-retry-send-${message.messageId}',
                        ),
                        onPressed: onRetry,
                        icon: const Icon(LucideIcons.rotateCcw, size: 14),
                        label: const Text('重试'),
                        style: TextButton.styleFrom(
                          minimumSize: const Size(64, 32),
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          visualDensity: VisualDensity.compact,
                          textStyle: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    if (text.isNotEmpty)
                      IconButton(
                        tooltip: '复制消息',
                        visualDensity: VisualDensity.compact,
                        constraints: const BoxConstraints.tightFor(
                          width: 32,
                          height: 32,
                        ),
                        icon: Icon(
                          Icons.content_copy_outlined,
                          size: 16,
                          color: colors.muted,
                        ),
                        onPressed: onCopy,
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _V3ChatAssistantTurn extends StatelessWidget {
  const _V3ChatAssistantTurn({
    required this.runKey,
    required this.message,
    required this.runStatus,
    required this.toolTrace,
    required this.progress,
    required this.startedAt,
    required this.terminalAt,
    required this.processTerminal,
    required this.showProcess,
    required this.progressMessage,
    required this.localReveal,
    required this.assistantAnswerDrafts,
    required this.imageAttachmentsBuilder,
    required this.resourceAttachmentsBuilder,
    required this.isCreatingNote,
    required this.onStreamingRebuild,
    required this.onLocalRevealCompleted,
    this.onCreateNote,
    this.digitalTwinStyle = false,
    super.key,
  });

  final String runKey;
  final ChatMessage? message;
  final String? runStatus;
  final List<_SafeToolReceipt> toolTrace;
  final List<_SafeProgressReceipt> progress;
  final DateTime? startedAt;
  final DateTime? terminalAt;
  final bool processTerminal;
  final bool showProcess;
  final bool progressMessage;
  final bool localReveal;
  final ValueListenable<Map<String, ChatAssistantAnswerDraft>>
  assistantAnswerDrafts;
  final V3ChatImageAttachmentsBuilder imageAttachmentsBuilder;
  final V3ChatResourceAttachmentsBuilder resourceAttachmentsBuilder;
  final bool isCreatingNote;
  final VoidCallback onStreamingRebuild;
  final VoidCallback? onLocalRevealCompleted;
  final Future<void> Function()? onCreateNote;
  final bool digitalTwinStyle;

  @override
  Widget build(BuildContext context) {
    final message = this.message;
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: digitalTwinStyle
                  ? Container(
                      width: 30,
                      height: 30,
                      decoration: const BoxDecoration(
                        color: Color(0xFF352944),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.auto_awesome_rounded,
                        size: 16,
                        color: Color(0xFFB88CFF),
                      ),
                    )
                  : const V3ChatMark(size: 36),
            ),
            SizedBox(width: digitalTwinStyle ? 12 : 10),
            Expanded(
              child: Padding(
                key: ValueKey<String>('chat-assistant-content-$runKey'),
                padding: const EdgeInsets.only(right: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (showProcess) ...[
                      _V3ChatProcessCard(
                        runKey: runKey,
                        runStatus: runStatus,
                        toolTrace: toolTrace,
                        progress: progress,
                        startedAt: startedAt,
                        terminalAt: terminalAt,
                        terminal: processTerminal,
                      ),
                      if (message != null) const SizedBox(height: 12),
                    ],
                    if (message != null)
                      _V3ChatAssistantMessageBody(
                        message: message,
                        bodyStyle: digitalTwinStyle
                            ? const TextStyle(
                                fontFamily: 'Noto Sans SC',
                                fontSize: 13,
                                height: 20 / 13,
                              )
                            : null,
                        progressMessage: progressMessage,
                        localReveal: localReveal,
                        assistantAnswerDrafts: assistantAnswerDrafts,
                        imageAttachmentsBuilder: imageAttachmentsBuilder,
                        resourceAttachmentsBuilder: resourceAttachmentsBuilder,
                        isCreatingNote: isCreatingNote,
                        onCreateNote: onCreateNote,
                        onStreamingRebuild: onStreamingRebuild,
                        onLocalRevealCompleted: onLocalRevealCompleted,
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _V3ChatAssistantMessageBody extends StatelessWidget {
  const _V3ChatAssistantMessageBody({
    this.bodyStyle,
    required this.message,
    required this.progressMessage,
    required this.localReveal,
    required this.assistantAnswerDrafts,
    required this.imageAttachmentsBuilder,
    required this.resourceAttachmentsBuilder,
    required this.isCreatingNote,
    required this.onCreateNote,
    required this.onStreamingRebuild,
    required this.onLocalRevealCompleted,
  });

  final ChatMessage message;
  final TextStyle? bodyStyle;
  final bool progressMessage;
  final bool localReveal;
  final ValueListenable<Map<String, ChatAssistantAnswerDraft>>
  assistantAnswerDrafts;
  final V3ChatImageAttachmentsBuilder imageAttachmentsBuilder;
  final V3ChatResourceAttachmentsBuilder resourceAttachmentsBuilder;
  final bool isCreatingNote;
  final Future<void> Function()? onCreateNote;
  final VoidCallback onStreamingRebuild;
  final VoidCallback? onLocalRevealCompleted;

  @override
  Widget build(BuildContext context) {
    if (progressMessage) {
      return SelectionArea(
        key: ValueKey<String>('chat-assistant-selection-${message.messageId}'),
        contextMenuBuilder: V3TextEditing.buildSelectionContextMenu,
        child: _V3ChatAnswerDraftText(
          bodyStyle: bodyStyle,
          key: ValueKey<String>('chat-assistant-draft-${message.messageId}'),
          message: message,
          drafts: assistantAnswerDrafts,
          onDraftChanged: onStreamingRebuild,
        ),
      );
    }

    final tokens = HuahuoV3Theme.tokensOf(context);
    final text = _messageText(message);
    final positioningProgress = parseLatestPositioningProgress(text);
    final visibleMarkdown = positioningProgress == null
        ? text
        : stripPositioningProgressBlocks(text);
    final eventTime = _formatChatMessageTime(message.createdAt);
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (positioningProgress != null) ...[
          V3PositioningDashboard(profile: positioningProgress, compact: true),
          if (visibleMarkdown.isNotEmpty) const SizedBox(height: 10),
        ],
        if (visibleMarkdown.isNotEmpty)
          SelectionArea(
            key: ValueKey<String>(
              'chat-assistant-selection-${message.messageId}',
            ),
            contextMenuBuilder: V3TextEditing.buildSelectionContextMenu,
            child: localReveal && !reduceMotion
                ? _V3LocalRevealAssistantText(
                    bodyStyle: bodyStyle,
                    key: ValueKey<String>(
                      'chat-assistant-local-reveal-${message.messageId}',
                    ),
                    source: visibleMarkdown,
                    onReveal: onStreamingRebuild,
                    onCompleted: onLocalRevealCompleted,
                  )
                : V3AssistantReplyMarkdown(
                    bodyStyle: bodyStyle,
                    unifiedSelection: true,
                    markdownKey: ValueKey<String>(
                      'chat-assistant-markdown-${message.messageId}',
                    ),
                    source: visibleMarkdown,
                  ),
          ),
        if (message.imageAttachments.isNotEmpty) ...[
          if (visibleMarkdown.isNotEmpty) const SizedBox(height: 10),
          imageAttachmentsBuilder(context, message.imageAttachments, true),
        ],
        if (message.resourceAttachments.isNotEmpty) ...[
          if (visibleMarkdown.isNotEmpty || message.imageAttachments.isNotEmpty)
            const SizedBox(height: 10),
          resourceAttachmentsBuilder(context, message.resourceAttachments),
        ],
        const SizedBox(height: 3),
        Row(
          children: [
            Expanded(
              child: Text(
                eventTime == null ? '回复时间未知' : '回复于 $eventTime',
                style: TextStyle(
                  fontSize: 11,
                  height: 16 / 11,
                  color: tokens.muted,
                ),
              ),
            ),
            if (visibleMarkdown.isNotEmpty)
              V3AssistantResponseAction(
                key: ValueKey<String>('chat-copy-${message.messageId}'),
                width: 50,
                tooltip: '复制消息',
                icon: Icons.content_copy_outlined,
                label: '复制',
                onPressed: () => V3TextEditing.copy(context, visibleMarkdown),
              ),
            if (onCreateNote != null &&
                (visibleMarkdown.isNotEmpty ||
                    message.imageAttachments.isNotEmpty))
              V3AssistantResponseAction(
                key: ValueKey<String>('chat-create-note-${message.messageId}'),
                width: 50,
                tooltip: '保存为笔记',
                icon: Icons.bookmark_add_outlined,
                label: '保存',
                busy: isCreatingNote,
                onPressed: isCreatingNote
                    ? null
                    : () => unawaited(onCreateNote!()),
              ),
          ],
        ),
      ],
    );
  }
}

class _V3ChatAnswerDraftText extends StatefulWidget {
  const _V3ChatAnswerDraftText({
    this.bodyStyle,
    required this.message,
    required this.drafts,
    required this.onDraftChanged,
    super.key,
  });

  final ChatMessage message;
  final TextStyle? bodyStyle;
  final ValueListenable<Map<String, ChatAssistantAnswerDraft>> drafts;
  final VoidCallback onDraftChanged;

  @override
  State<_V3ChatAnswerDraftText> createState() => _V3ChatAnswerDraftTextState();
}

class _V3ChatAnswerDraftTextState extends State<_V3ChatAnswerDraftText> {
  @override
  void initState() {
    super.initState();
    widget.drafts.addListener(_handleDraftChanged);
  }

  @override
  void didUpdateWidget(covariant _V3ChatAnswerDraftText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.drafts == widget.drafts) return;
    oldWidget.drafts.removeListener(_handleDraftChanged);
    widget.drafts.addListener(_handleDraftChanged);
  }

  void _handleDraftChanged() => widget.onDraftChanged();

  @override
  void dispose() {
    widget.drafts.removeListener(_handleDraftChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<Map<String, ChatAssistantAnswerDraft>>(
        valueListenable: widget.drafts,
        builder: (context, drafts, _) => V3StreamingAssistantReplyText(
          bodyStyle: widget.bodyStyle,
          source:
              drafts[widget.message.messageId]?.visibleText ??
              _messageText(widget.message),
        ),
      );
}

class _V3ChatProcessCard extends StatefulWidget {
  const _V3ChatProcessCard({
    required this.runKey,
    required this.runStatus,
    required this.toolTrace,
    required this.progress,
    required this.startedAt,
    required this.terminalAt,
    required this.terminal,
  });

  final String runKey;
  final String? runStatus;
  final List<_SafeToolReceipt> toolTrace;
  final List<_SafeProgressReceipt> progress;
  final DateTime? startedAt;
  final DateTime? terminalAt;
  final bool terminal;

  @override
  State<_V3ChatProcessCard> createState() => _V3ChatProcessCardState();
}

class _V3ChatProcessCardState extends State<_V3ChatProcessCard> {
  Timer? _timer;
  late bool _expanded;

  @override
  void initState() {
    super.initState();
    _expanded = !widget.terminal;
    _syncTimer();
  }

  @override
  void didUpdateWidget(covariant _V3ChatProcessCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.terminal && widget.terminal) _expanded = false;
    if (oldWidget.terminal && !widget.terminal) _expanded = true;
    _syncTimer();
  }

  void _syncTimer() {
    if (widget.terminal || widget.startedAt == null) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    _timer ??= Timer(const Duration(seconds: 1), () {
      _timer = null;
      if (!mounted) return;
      setState(() {});
      _syncTimer();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = HuahuoV3Theme.tokensOf(context);
    final elapsed = _elapsedSeconds(
      widget.startedAt,
      widget.terminal ? widget.terminalAt : null,
    );
    final terminalLabel = switch (widget.runStatus) {
      'succeeded' => '已完成',
      'failed' || 'conflict' || 'orphaned' => '处理失败',
      'timeout' => '处理超时',
      'cancelled' || 'aborted' => '已停止',
      'rejected' => '未能开始处理',
      _ => '处理已结束',
    };
    final terminalSucceeded = widget.runStatus == 'succeeded';
    final activeTool = _activeTool(widget.toolTrace);
    final statusLabel = activeTool == null
        ? _runStatusLabel(widget.runStatus)
        : '正在调用工具';
    final header = Row(
      children: [
        if (!widget.terminal) ...[
          V3AgentRunGlyph(
            key: const ValueKey<String>('chat-assistant-thinking-progress'),
            color: tokens.accent,
          ),
          const SizedBox(width: 8),
        ] else ...[
          Icon(
            terminalSucceeded ? LucideIcons.check : LucideIcons.x,
            size: 14,
            color: terminalSucceeded ? tokens.success : tokens.danger,
          ),
          const SizedBox(width: 8),
        ],
        Expanded(
          child: Text(
            widget.terminal
                ? '$terminalLabel · 用时 ${_elapsedLabel(elapsed)}'
                : statusLabel,
            style: TextStyle(
              color: widget.terminal && !terminalSucceeded
                  ? tokens.danger
                  : widget.terminal
                  ? tokens.muted
                  : tokens.ink,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        if (!widget.terminal)
          Text(
            '已用时 ${_elapsedLabel(elapsed)}',
            key: const ValueKey<String>('chat-assistant-thinking-elapsed'),
            style: TextStyle(
              color: tokens.muted,
              fontSize: 11,
              fontWeight: FontWeight.w500,
            ),
          )
        else
          V3DisclosureChevron(
            expanded: _expanded,
            size: 15,
            color: tokens.muted,
          ),
      ],
    );
    var sourceOrder = 0;
    final receipts = <({DateTime? createdAt, int order, Widget row})>[
      for (final item in widget.progress)
        (
          createdAt: item.createdAt,
          order: sourceOrder++,
          row: Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: _V3ChatProgressReceiptRow(progress: item),
          ),
        ),
      for (final tool in widget.toolTrace)
        (
          createdAt: tool.createdAt,
          order: sourceOrder++,
          row: Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: _V3ChatToolTraceRow(tool: tool),
          ),
        ),
    ]..sort(_compareProcessReceipts);
    final visibleReceipts = receipts.length <= 6
        ? receipts
        : receipts.sublist(receipts.length - 6);
    final details = <Widget>[
      if (widget.terminal &&
          widget.toolTrace.isEmpty &&
          widget.progress.isEmpty)
        Text(
          _runStatusLabel(widget.runStatus),
          style: TextStyle(color: tokens.muted, fontSize: 11, height: 1.4),
        ),
      for (final receipt in visibleReceipts) receipt.row,
    ];
    return Container(
      key: const ValueKey<String>('chat-assistant-thinking-bubble'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: tokens.surfaceMuted,
        borderRadius: BorderRadius.circular(HuahuoRadius.compact),
        border: Border.all(color: tokens.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.terminal)
            InkWell(
              key: const ValueKey<String>('chat-assistant-thinking-toggle'),
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: header,
              ),
            )
          else
            header,
          if (_expanded && details.isNotEmpty) ...[
            const SizedBox(height: 8),
            Divider(height: 1, color: tokens.line),
            const SizedBox(height: 7),
            ...details,
          ],
        ],
      ),
    );
  }
}

class _V3ChatToolTraceRow extends StatelessWidget {
  const _V3ChatToolTraceRow({required this.tool});

  final _SafeToolReceipt tool;

  @override
  Widget build(BuildContext context) {
    final tokens = HuahuoV3Theme.tokensOf(context);
    final active = tool.isActive;
    final failed = tool.state == 'rejected' || tool.outcome == 'failed';
    final color = active
        ? tokens.accent
        : failed
        ? tokens.danger
        : tokens.success;
    final stateLabel = active
        ? '进行中'
        : tool.state == 'rejected'
        ? '未执行'
        : failed
        ? '未完成'
        : '已完成';
    return Row(
      key: active
          ? const ValueKey<String>('chat-assistant-tool-progress')
          : null,
      children: [
        Icon(
          active
              ? _toolIcon(tool.toolName)
              : failed
              ? LucideIcons.x
              : LucideIcons.check,
          size: 13,
          color: color,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            _toolLabel(tool.toolName),
            style: TextStyle(
              color: active ? tokens.ink : tokens.muted,
              fontSize: 12,
              fontWeight: active ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ),
        Text(
          stateLabel,
          style: TextStyle(
            color: color,
            fontSize: 11,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}

class _V3ChatProgressReceiptRow extends StatelessWidget {
  const _V3ChatProgressReceiptRow({required this.progress});

  final _SafeProgressReceipt progress;

  @override
  Widget build(BuildContext context) {
    final tokens = HuahuoV3Theme.tokensOf(context);
    final active = progress.isActive;
    final failed = progress.isFailed;
    final color = active
        ? tokens.accent
        : failed
        ? tokens.danger
        : tokens.muted;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(
            active
                ? LucideIcons.loaderCircle
                : failed
                ? LucideIcons.x
                : LucideIcons.check,
            size: 13,
            color: color,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text.rich(
            TextSpan(
              text: progress.title,
              children: [
                if (progress.summary case final summary?)
                  TextSpan(text: '\n$summary'),
              ],
            ),
            style: TextStyle(
              color: failed
                  ? tokens.danger
                  : active
                  ? tokens.ink
                  : tokens.muted,
              fontSize: 11,
              height: 1.4,
              fontWeight: FontWeight.w400,
            ),
          ),
        ),
      ],
    );
  }
}

class _V3LocalRevealAssistantText extends StatefulWidget {
  const _V3LocalRevealAssistantText({
    this.bodyStyle,
    required this.source,
    required this.onReveal,
    required this.onCompleted,
    super.key,
  });

  final String source;
  final TextStyle? bodyStyle;
  final VoidCallback onReveal;
  final VoidCallback? onCompleted;

  @override
  State<_V3LocalRevealAssistantText> createState() =>
      _V3LocalRevealAssistantTextState();
}

class _V3LocalRevealAssistantTextState
    extends State<_V3LocalRevealAssistantText> {
  late ChatStreamRevealBuffer _buffer;
  late ChatAssistantAnswerDraft _draft;
  bool _completionReported = false;

  @override
  void initState() {
    super.initState();
    _startReveal();
  }

  @override
  void didUpdateWidget(covariant _V3LocalRevealAssistantText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source == widget.source) return;
    _buffer.dispose();
    _completionReported = false;
    _startReveal();
  }

  void _startReveal() {
    _draft = ChatAssistantAnswerDraft(
      visibleText: '',
      targetText: widget.source,
      source: ChatAssistantAnswerDraftSource.localReveal,
    );
    _buffer = ChatStreamRevealBuffer(
      onReveal: (text) {
        if (!mounted) return;
        setState(() {
          _draft = ChatAssistantAnswerDraft(
            visibleText: text,
            targetText: widget.source,
            source: ChatAssistantAnswerDraftSource.localReveal,
          );
        });
        widget.onReveal();
        if (text == widget.source && !_completionReported) {
          _completionReported = true;
          widget.onCompleted?.call();
        }
      },
    );
    _buffer.ingest(widget.source, replace: true);
  }

  @override
  void dispose() {
    _buffer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_draft.visibleText == widget.source) {
      return V3AssistantReplyMarkdown(
        source: widget.source,
        bodyStyle: widget.bodyStyle,
        unifiedSelection: true,
      );
    }
    return V3StreamingAssistantReplyText(
      source: _draft.visibleText,
      bodyStyle: widget.bodyStyle,
    );
  }
}

class _V3ChatUserAssetReferenceCard extends StatelessWidget {
  const _V3ChatUserAssetReferenceCard({required this.reference});

  final ChatAssetReference reference;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Container(
      key: ValueKey<String>('chat-message-asset-${reference.assetId}'),
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 9),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.line),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.description_outlined, size: 18, color: colors.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '引用资产',
                  style: TextStyle(color: colors.muted, fontSize: 11),
                ),
                const SizedBox(height: 2),
                Text(
                  reference.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.text,
                    fontSize: 13,
                    height: 1.3,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

@immutable
final class _RunPresentation {
  const _RunPresentation({
    required this.runKey,
    required this.runStatus,
    required this.toolTrace,
    this.progress = const <_SafeProgressReceipt>[],
    this.startedAt,
    this.completedAt,
    this.isTerminal = false,
    this.runtimeHydrated = false,
    this.runtimeTerminalHydrated = false,
  });

  factory _RunPresentation.fromActivity(ChatRunActivity activity) =>
      _RunPresentation(
        runKey: activity.agentRunId,
        runStatus: activity.status,
        toolTrace: _safeLegacyToolReceipts(activity.toolTrace),
        startedAt: activity.createdAt,
        completedAt: activity.completedAt,
        isTerminal: activity.isTerminal,
      );

  factory _RunPresentation.fromRuntime(
    SharedThreadRuntimeInvocation invocation,
  ) {
    final terminal = !_isVisibleRunStatus(invocation.status);
    return _RunPresentation(
      runKey: invocation.agentRunId,
      runStatus: invocation.status,
      toolTrace: <_SafeToolReceipt>[
        for (var index = 0; index < invocation.tools.length; index += 1)
          _SafeToolReceipt.fromRuntime(invocation.tools[index], index),
      ],
      progress: _safeProgressReceipts(invocation.progress),
      startedAt: invocation.createdAt,
      completedAt: invocation.completedAt,
      isTerminal: terminal,
      runtimeHydrated: true,
      runtimeTerminalHydrated: terminal,
    );
  }

  factory _RunPresentation.fromCompletion(
    ChatRunCompletion completion, {
    _RunPresentation? existing,
  }) => _RunPresentation(
    runKey: completion.agentRunId,
    runStatus: _completionPresentationStatus(completion),
    toolTrace: existing?.toolTrace ?? const <_SafeToolReceipt>[],
    progress: existing?.progress ?? const <_SafeProgressReceipt>[],
    startedAt: existing?.startedAt,
    completedAt: existing?.completedAt ?? DateTime.now().toUtc(),
    isTerminal: true,
    runtimeHydrated: existing?.runtimeHydrated ?? false,
    runtimeTerminalHydrated: existing?.runtimeTerminalHydrated ?? false,
  );

  final String runKey;
  final String? runStatus;
  final List<_SafeToolReceipt> toolTrace;
  final List<_SafeProgressReceipt> progress;
  final DateTime? startedAt;
  final DateTime? completedAt;
  final bool isTerminal;
  final bool runtimeHydrated;
  final bool runtimeTerminalHydrated;

  _RunPresentation mergeActivity(ChatRunActivity activity) {
    if (isTerminal) return this;
    final mergedTools = <String, _SafeToolReceipt>{
      for (final tool in toolTrace)
        if (tool.fromRuntime) tool.identity: tool,
      for (final tool in _safeLegacyToolReceipts(activity.toolTrace))
        tool.identity: tool,
    };
    return _RunPresentation(
      runKey: runKey,
      runStatus: activity.status,
      toolTrace: List<_SafeToolReceipt>.unmodifiable(mergedTools.values),
      progress: progress,
      startedAt: activity.createdAt,
      completedAt: activity.completedAt ?? completedAt,
      isTerminal: activity.isTerminal,
      runtimeHydrated: runtimeHydrated,
      runtimeTerminalHydrated: runtimeTerminalHydrated,
    );
  }

  _RunPresentation mergeRuntime(SharedThreadRuntimeInvocation invocation) {
    if (isTerminal && runtimeTerminalHydrated) return this;
    final invocationTerminal = !_isVisibleRunStatus(invocation.status);
    final mergedTools = <String, _SafeToolReceipt>{
      for (final tool in toolTrace)
        if (!tool.fromRuntime) tool.identity: tool,
    };
    for (var index = 0; index < invocation.tools.length; index += 1) {
      final receipt = _SafeToolReceipt.fromRuntime(
        invocation.tools[index],
        index,
      );
      mergedTools[receipt.identity] = receipt;
    }
    return _RunPresentation(
      runKey: runKey,
      runStatus: isTerminal ? runStatus : invocation.status,
      toolTrace: List<_SafeToolReceipt>.unmodifiable(mergedTools.values),
      progress: _safeProgressReceipts(invocation.progress),
      startedAt: invocation.createdAt ?? startedAt,
      completedAt: invocation.completedAt ?? completedAt,
      isTerminal: isTerminal || invocationTerminal,
      runtimeHydrated: true,
      runtimeTerminalHydrated: runtimeTerminalHydrated || invocationTerminal,
    );
  }

  _RunPresentation asTerminal({DateTime? completedAt}) => _RunPresentation(
    runKey: runKey,
    runStatus: isTerminal ? runStatus : 'succeeded',
    toolTrace: toolTrace,
    progress: progress,
    startedAt: startedAt,
    completedAt: this.completedAt ?? completedAt,
    isTerminal: true,
    runtimeHydrated: runtimeHydrated,
    runtimeTerminalHydrated: runtimeTerminalHydrated,
  );
}

String? _selectMutableRunId(
  Iterable<_RunPresentation> presentations, {
  String? preferredRunId,
}) {
  final candidates = presentations.toList(growable: false);
  if (candidates.isEmpty) return null;
  final preferred = preferredRunId == null
      ? null
      : candidates
            .where((presentation) => presentation.runKey == preferredRunId)
            .firstOrNull;
  if (preferred != null) {
    return preferred.isTerminal ? null : preferredRunId;
  }
  if (preferredRunId != null) return null;
  candidates.sort((left, right) {
    final leftStartedAt = left.startedAt;
    final rightStartedAt = right.startedAt;
    if (leftStartedAt != null && rightStartedAt != null) {
      final timeOrder = leftStartedAt.toUtc().compareTo(rightStartedAt.toUtc());
      if (timeOrder != 0) return timeOrder;
    } else if (leftStartedAt != null) {
      return 1;
    } else if (rightStartedAt != null) {
      return -1;
    }
    return left.runKey.compareTo(right.runKey);
  });
  final latest = candidates.last;
  return latest.isTerminal ? null : latest.runKey;
}

String _completionPresentationStatus(ChatRunCompletion completion) {
  if (completion.status != 'succeeded') return completion.status;
  return switch (completion.completionMode) {
    'cancelled' => 'cancelled',
    'degraded' || 'system_fallback' => 'failed',
    _ => completion.status,
  };
}

@immutable
final class _SafeToolReceipt {
  const _SafeToolReceipt({
    required this.identity,
    required this.toolName,
    required this.state,
    required this.createdAt,
    required this.fromRuntime,
    this.outcome,
  });

  factory _SafeToolReceipt.fromTrace(AssistantToolTrace trace) =>
      _SafeToolReceipt(
        identity: trace.invocationId,
        toolName: trace.toolName,
        state: trace.state,
        createdAt: trace.createdAt,
        fromRuntime: false,
        outcome: trace.outcome,
      );

  factory _SafeToolReceipt.fromRuntime(SharedRuntimeTool tool, int index) =>
      _SafeToolReceipt(
        identity: tool.invocationId ?? 'runtime-${tool.name}-$index',
        toolName: tool.name,
        state: tool.state,
        createdAt: tool.createdAt,
        fromRuntime: true,
        outcome: tool.state == 'failed' ? 'failed' : null,
      );

  final String identity;
  final String toolName;
  final String state;
  final DateTime? createdAt;
  final bool fromRuntime;
  final String? outcome;

  bool get isActive =>
      state == 'started' || state == 'running' || state == 'updated';
}

@immutable
final class _SafeProgressReceipt {
  const _SafeProgressReceipt({
    required this.title,
    required this.status,
    required this.createdAt,
    this.summary,
  });

  final String title;
  final String status;
  final DateTime createdAt;
  final String? summary;

  bool get isActive =>
      status == 'started' ||
      status == 'running' ||
      status == 'pending' ||
      status == 'updated';

  bool get isFailed => status == 'failed';
}

List<_SafeToolReceipt> _safeToolReceipts(Iterable<AssistantToolTrace> traces) =>
    List<_SafeToolReceipt>.unmodifiable(traces.map(_SafeToolReceipt.fromTrace));

List<_SafeToolReceipt> _safeLegacyToolReceipts(
  Iterable<AgentRunToolTrace> traces,
) => List<_SafeToolReceipt>.unmodifiable(
  traces.map(
    (trace) => _SafeToolReceipt(
      identity: trace.invocationId,
      toolName: trace.toolName,
      state: trace.state,
      createdAt: trace.createdAt,
      fromRuntime: false,
      outcome: trace.outcome,
    ),
  ),
);

List<_SafeProgressReceipt> _safeProgressReceipts(
  List<SharedRuntimeProgress> progress,
) => List<_SafeProgressReceipt>.unmodifiable(
  progress
      .where((item) => item.title.trim().isNotEmpty)
      .map(
        (item) => _SafeProgressReceipt(
          title: item.title.trim(),
          status: item.status,
          createdAt: item.createdAt,
          summary: switch (item.summary?.trim()) {
            final summary? when summary.isNotEmpty => summary,
            _ => null,
          },
        ),
      ),
);

int _compareProcessReceipts(
  ({DateTime? createdAt, int order, Widget row}) left,
  ({DateTime? createdAt, int order, Widget row}) right,
) {
  final leftTime = left.createdAt;
  final rightTime = right.createdAt;
  if (leftTime != null && rightTime != null) {
    final timestampOrder = leftTime.compareTo(rightTime);
    if (timestampOrder != 0) return timestampOrder;
  } else if (leftTime != null) {
    return -1;
  } else if (rightTime != null) {
    return 1;
  }
  return left.order.compareTo(right.order);
}

String? _messageRunIdentity(ChatMessage message) {
  final agentRunId = message.agentRunId?.trim();
  return agentRunId == null || agentRunId.isEmpty ? null : agentRunId;
}

bool _sameRuntimeInvocationMap(
  Map<String, SharedThreadRuntimeInvocation> left,
  Map<String, SharedThreadRuntimeInvocation> right,
) {
  if (identical(left, right)) return true;
  if (left.length != right.length) return false;
  for (final entry in left.entries) {
    if (!identical(right[entry.key], entry.value)) return false;
  }
  return true;
}

bool _isProgressMessage(ChatMessage message) =>
    message.role == ChatMessageRole.assistant &&
    message.status == 'streaming' &&
    message.messageId.startsWith('stream-');

bool _isVisibleRunStatus(String? status) =>
    status == null ||
    !const <String>{
      'succeeded',
      'failed',
      'timeout',
      'cancelled',
      'aborted',
      'rejected',
      'conflict',
      'orphaned',
    }.contains(status);

String _messageText(ChatMessage message) =>
    message.visibleText ??
    (message.contentType == ChatMessageContentType.voice
        ? '语音消息'
        : message.imageAttachments.isNotEmpty ||
              message.resourceAttachments.isNotEmpty
        ? ''
        : '消息内容不可用');

String? _formatChatMessageTime(DateTime? createdAt) {
  if (createdAt == null) return null;
  final local = createdAt.toLocal();
  final now = DateTime.now();
  final hour = local.hour.toString().padLeft(2, '0');
  final minute = local.minute.toString().padLeft(2, '0');
  final time = '$hour:$minute';
  if (local.year == now.year &&
      local.month == now.month &&
      local.day == now.day) {
    return '今天 $time';
  }
  final month = local.month.toString().padLeft(2, '0');
  final day = local.day.toString().padLeft(2, '0');
  return '$month-$day $time';
}

int _elapsedSeconds(DateTime? startedAt, DateTime? terminalAt) {
  if (startedAt == null) return 0;
  return (terminalAt ?? DateTime.now())
      .toUtc()
      .difference(startedAt.toUtc())
      .inSeconds
      .clamp(0, 1 << 30)
      .toInt();
}

String _elapsedLabel(int elapsedSeconds) {
  final minutes = elapsedSeconds ~/ 60;
  final seconds = elapsedSeconds % 60;
  return '${minutes.toString().padLeft(2, '0')}:'
      '${seconds.toString().padLeft(2, '0')}';
}

String _runStatusLabel(String? status) => switch (status) {
  'resolving' => '正在理解你的问题',
  'planning' => '正在规划回答',
  'awaiting_confirmation' => '等待你的确认',
  'queued' => '正在准备',
  'running' => '正在处理',
  'aborting' => '正在停止',
  'succeeded' => '回答已生成',
  'failed' => '处理未完成',
  'timeout' => '处理超时',
  'cancelled' || 'aborted' => '已停止',
  'rejected' => '未能开始处理',
  'conflict' => '状态冲突',
  'orphaned' => '状态已恢复',
  _ => '正在处理',
};

_SafeToolReceipt? _activeTool(List<_SafeToolReceipt> traces) {
  for (final trace in traces.reversed) {
    if (trace.isActive) return trace;
  }
  return null;
}

String _toolLabel(String toolName) => switch (toolName) {
  'edit' => '编辑内容',
  'read' => '读取资料',
  'workspace_list' => '查看工作区',
  'workspace_search' => '检索工作区',
  'write' => '整理并写入内容',
  'image_analysis' => '分析图片',
  'image_generation' => '生成图片',
  'video_analysis' => '分析视频',
  'huahuo_hotspot_query' => '检索热点',
  _ => '执行工具',
};

IconData _toolIcon(String toolName) => switch (toolName) {
  'edit' => LucideIcons.pencil,
  'read' => LucideIcons.fileText,
  'workspace_list' => LucideIcons.folderOpen,
  'workspace_search' => LucideIcons.search,
  'write' => LucideIcons.filePenLine,
  'image_analysis' => LucideIcons.image,
  'image_generation' => LucideIcons.images,
  'video_analysis' => LucideIcons.video,
  'huahuo_hotspot_query' => LucideIcons.flame,
  _ => LucideIcons.loaderCircle,
};
