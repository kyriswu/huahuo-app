import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/di/onboarding_providers.dart';
import '../../../app/bootstrap/app_providers.dart';
import '../../../app/navigation/app_route_paths.dart';
import '../../../app/runtime/runtime_provider_module.dart';
import '../../../core/auth/session_store.dart';
import '../../../core/storage/upload_draft_store.dart';
import '../../../core/tasking/task_orchestrator.dart';
import '../../book_work/application/masterpiece_providers.dart';
import '../../book_work/domain/masterpiece_generation.dart';
import '../../chat/application/chat_run_tracker.dart';
import '../../chat/domain/chat_models.dart';
import '../../onboarding/data/onboarding_progress_repository.dart';
import '../../onboarding/data/first_launch_device_setup_repository.dart';
import '../../ingestion/application/internal_recording_controller.dart';
import '../../ingestion/application/meeting_capture_controller.dart';
import '../../ingestion/domain/material_ingestion.dart';
import '../../recordings/application/recording_processing_tracker.dart';
import '../../recordings/application/recording_upload_controller.dart';
import '../../recordings/domain/recording_batch_transcription.dart';
import '../../recordings/domain/recording_library.dart';
import '../../ui_v3/application/automatic_outline_coordinator.dart';
import '../../ui_v3/application/feed_aggregation_controller.dart';
import '../../ui_v3/application/knowledge_library_controller.dart';
import '../../ui_v3/application/v3_document_import_controller.dart';
import '../../ui_v3/application/workbench_generation_controller.dart';
import '../../ui_v3/domain/ui_v3_models.dart';
import '../../ui_v3/data/note_file_agent_client.dart';
import '../../ui_v3/data/v3_document_import_store.dart';
import '../../ui_v3/domain/feed_item_models.dart';
import '../../ui_v3/domain/creation_canvas_draft.dart';
import '../../ui_v3/domain/script_draft_models.dart';
import '../../ui_v3/domain/digital_twin_material.dart';
import '../domain/notification_models.dart';
import 'notification_destination_registry.dart';
import 'notification_controller.dart';
import 'recording_transcription_message_projection.dart';

enum PendingMessageSource {
  remote,
  agentTask,
  onboarding,
  firstLaunchDeviceSetup,
  aggregation,
  sprout,
  materialIngestion,
  documentImport,
  recordingTranscription,
  canvasGeneration,
  masterpieceGeneration,
  workbenchGeneration,
  digitalTwinMaterial,
}

enum PendingMessageState {
  processing,
  actionRequired,
  succeeded,
  failed,
  informational;

  bool get isTerminal => switch (this) {
    PendingMessageState.succeeded || PendingMessageState.failed => true,
    _ => false,
  };
}

enum PendingMessageArchiveScope { unavailable, deliveryRevision, taskResult }

final class PendingMessage {
  const PendingMessage({
    required this.id,
    required this.source,
    required this.scene,
    required this.title,
    required this.body,
    required this.state,
    required this.isUnread,
    required this.isDemo,
    required this.isOpening,
    required this.isResolving,
    this.createdAt,
    this.route,
    this.replaceRoute = false,
    this.canMarkHandled = true,
    this.remoteNotificationId,
    this.remoteDeliveryResolutionKey,
    this.taskId,
    this.targetType,
    this.targetId,
    this.stage,
    this.isTask = false,
    this.errorCode,
    this.eventType,
    this.linkedDeliveryResolutionKey,
    this.taskResultAliasIds = const <String>[],
    this.recordingUploadProgress,
  });

  final String id;
  final PendingMessageSource source;
  final String scene;
  final String title;
  final String body;
  final PendingMessageState state;
  final bool isUnread;
  final bool isDemo;
  final bool isOpening;
  final bool isResolving;
  final DateTime? createdAt;
  final String? route;
  final bool replaceRoute;
  final bool canMarkHandled;
  final String? remoteNotificationId;
  final String? remoteDeliveryResolutionKey;
  final String? taskId;
  final String? targetType;
  final String? targetId;
  final String? stage;
  final bool isTask;
  final String? errorCode;
  final String? eventType;
  final String? linkedDeliveryResolutionKey;
  final List<String> taskResultAliasIds;
  final RecordingObjectUploadProgress? recordingUploadProgress;

  bool get isRemote => source == PendingMessageSource.remote;
  bool get isBusy => isOpening || isResolving;
  bool get hasUnreadAttention =>
      isUnread && state != PendingMessageState.processing;
  bool get isTerminalTask => isTask && state.isTerminal;

  PendingMessageArchiveScope get archiveScope {
    if (state == PendingMessageState.processing) {
      return PendingMessageArchiveScope.unavailable;
    }
    if (isTask && state == PendingMessageState.succeeded) {
      return PendingMessageArchiveScope.taskResult;
    }
    if (canMarkHandled || (isTask && state == PendingMessageState.failed)) {
      return PendingMessageArchiveScope.deliveryRevision;
    }
    return PendingMessageArchiveScope.unavailable;
  }

  /// A terminal task needs an explicit result acknowledgement rather than an
  /// ordinary notification completion mutation. Local task projections that
  /// do not have a public Run ID use their stable card ID for that record.
  bool get hasTerminalTaskCompletionAction => isTerminalTask;

  bool get hasServerTaskResolution =>
      _pendingMessageTaskResultIds(this).isNotEmpty;

  /// Terminal task cards keep their destination on the card tap and reserve
  /// the only visible text action for explicit completion.
  bool get shouldShowOpenAction => !isTerminalTask;

  /// Ordinary completed notifications retain their existing explicit handler.
  /// Tasks only become handleable after they reach a terminal state.
  bool get shouldShowHandledAction =>
      !isUnread &&
      !isBusy &&
      (isTerminalTask ||
          (!isTask &&
              state != PendingMessageState.processing &&
              canMarkHandled));

  PendingMessage copyWith({
    bool? isUnread,
    bool? isOpening,
    bool? isResolving,
  }) {
    return PendingMessage(
      id: id,
      source: source,
      scene: scene,
      title: title,
      body: body,
      state: state,
      isUnread: isUnread ?? this.isUnread,
      isDemo: isDemo,
      isOpening: isOpening ?? this.isOpening,
      isResolving: isResolving ?? this.isResolving,
      createdAt: createdAt,
      route: route,
      replaceRoute: replaceRoute,
      canMarkHandled: canMarkHandled,
      remoteNotificationId: remoteNotificationId,
      remoteDeliveryResolutionKey: remoteDeliveryResolutionKey,
      taskId: taskId,
      targetType: targetType,
      targetId: targetId,
      stage: stage,
      isTask: isTask,
      errorCode: errorCode,
      eventType: eventType,
      linkedDeliveryResolutionKey: linkedDeliveryResolutionKey,
      taskResultAliasIds: taskResultAliasIds,
      recordingUploadProgress: recordingUploadProgress,
    );
  }
}

String? pendingMessageLogicalGroupKey(PendingMessage item) {
  final targetId = item.targetId?.trim();
  if (item.targetType != 'recording' ||
      targetId == null ||
      targetId.isEmpty ||
      (item.source != PendingMessageSource.recordingTranscription &&
          item.eventType != 'recording.deposit.succeeded' &&
          !_isFocusedRecordingBatchRoute(item.route))) {
    return null;
  }
  return 'recording:$targetId';
}

bool _isFocusedRecordingBatchRoute(String? route) {
  if (route == null) return false;
  final uri = Uri.tryParse(route);
  if (uri == null ||
      uri.pathSegments.length != 4 ||
      uri.pathSegments[0] != 'v3' ||
      uri.pathSegments[1] != 'feed' ||
      uri.pathSegments[2] != 'transcription-batches' ||
      uri.pathSegments[3].trim().isEmpty) {
    return false;
  }
  return uri.queryParameters['focusItem']?.trim().isNotEmpty == true;
}

String pendingMessageLocalDeliveryResolutionKey(PendingMessage item) {
  if (!_usesVersionedLocalDeliveryIdentity(item)) return item.id;
  return _pendingMessageDeliveryResolutionKey(
    id: item.id,
    taskId: item.taskId,
    state: item.state,
    errorCode: item.errorCode,
  );
}

@visibleForTesting
Set<String> pendingMessageLocalDeliveryResolutionKeys(PendingMessage item) {
  final current = pendingMessageLocalDeliveryResolutionKey(item);
  if (!_usesVersionedLocalDeliveryIdentity(item)) return <String>{current};
  return <String>{
    current,
    _legacyPendingMessageDeliveryResolutionKey(
      id: item.id,
      taskId: item.taskId,
      state: item.state,
      createdAt: item.createdAt,
      errorCode: item.errorCode,
    ),
    if (item.isTask && item.state == PendingMessageState.succeeded)
      for (final taskId in _pendingMessageTaskResultIds(item))
        _succeededTaskReadKey(taskId),
  };
}

String _succeededTaskReadKey(String taskId) =>
    _pendingMessageDeliveryResolutionKey(
      id: 'task-result-read',
      taskId: taskId,
      state: PendingMessageState.succeeded,
      errorCode: null,
    );

bool _usesVersionedLocalDeliveryIdentity(PendingMessage item) =>
    item.isTask ||
    const <PendingMessageSource>{
      PendingMessageSource.workbenchGeneration,
      PendingMessageSource.canvasGeneration,
      PendingMessageSource.masterpieceGeneration,
      PendingMessageSource.digitalTwinMaterial,
    }.contains(item.source);

String pendingMessagePresentationIdentity(PendingMessage item) =>
    item.remoteDeliveryResolutionKey ??
    (item.isRemote ? item.id : pendingMessageLocalDeliveryResolutionKey(item));

List<String> _pendingMessageTaskResultIds(PendingMessage item) {
  final ids = <String>{
    if (item.taskId case final taskId?
        when notificationTaskResolutionKey(taskId) != null)
      taskId,
    for (final alias in item.taskResultAliasIds)
      if (notificationTaskResolutionKey(alias) != null) alias,
  };
  return ids.toList(growable: false);
}

List<String> _pendingMessageCanonicalTaskResultIds(PendingMessage item) {
  final aliases = <String>{
    for (final alias in item.taskResultAliasIds)
      if (notificationTaskResolutionKey(alias) != null) alias,
  };
  if (aliases.isNotEmpty) return aliases.toList(growable: false);
  final taskId = item.taskId;
  return taskId != null && notificationTaskResolutionKey(taskId) != null
      ? <String>[taskId]
      : const <String>[];
}

String _pendingMessageDeliveryResolutionKey({
  required String id,
  required String? taskId,
  required PendingMessageState state,
  required String? errorCode,
}) {
  final digest = sha256.convert(
    utf8.encode(jsonEncode(<Object?>[id, taskId, state.name, errorCode])),
  );
  return 'local-delivery:$digest';
}

String _legacyPendingMessageDeliveryResolutionKey({
  required String id,
  required String? taskId,
  required PendingMessageState state,
  required DateTime? createdAt,
  required String? errorCode,
}) {
  final digest = sha256.convert(
    utf8.encode(
      jsonEncode(<Object?>[
        id,
        taskId,
        state.name,
        createdAt?.toUtc().microsecondsSinceEpoch,
        errorCode,
      ]),
    ),
  );
  return 'local-delivery:$digest';
}

({DateTime createdAt, PendingMessageState state, String resolutionKey})?
_agentTaskDeliveryAlias(AgentTaskLedgerEntry task) {
  if (!task.isTerminal) return null;
  final failed = task.status != 'succeeded';
  final state = failed
      ? PendingMessageState.failed
      : PendingMessageState.succeeded;
  return (
    createdAt: task.createdAt,
    state: state,
    resolutionKey: _pendingMessageDeliveryResolutionKey(
      id: localPendingMessageId(
        PendingMessageSource.agentTask,
        'ledger:${task.taskId}',
      ),
      taskId: task.taskId,
      state: state,
      errorCode: failed ? task.failureCode ?? task.status : null,
    ),
  );
}

PendingMessage? _applyLocalResolutionState(
  PendingMessage item,
  NotificationControllerState notifications,
) {
  final deliveryKeys = pendingMessageLocalDeliveryResolutionKeys(item);
  final taskResolutionKeys = <String>[
    for (final taskId in _pendingMessageCanonicalTaskResultIds(item))
      notificationTaskResolutionKey(taskId)!,
  ];
  final archived = switch (item.archiveScope) {
    PendingMessageArchiveScope.unavailable => false,
    PendingMessageArchiveScope.deliveryRevision => deliveryKeys.any(
      notifications.handledIds.contains,
    ),
    PendingMessageArchiveScope.taskResult =>
      taskResolutionKeys.isEmpty
          ? deliveryKeys.any(notifications.handledIds.contains)
          : taskResolutionKeys.any(notifications.handledTaskIds.contains),
  };
  if (archived) return null;

  final isResolving = switch (item.archiveScope) {
    PendingMessageArchiveScope.unavailable => false,
    PendingMessageArchiveScope.deliveryRevision => deliveryKeys.any(
      notifications.pendingHandledIds.contains,
    ),
    PendingMessageArchiveScope.taskResult =>
      taskResolutionKeys.isEmpty
          ? deliveryKeys.any(notifications.pendingHandledIds.contains)
          : taskResolutionKeys.any(
              notifications.pendingHandledTaskIds.contains,
            ),
  };
  return item.copyWith(
    isUnread:
        notifications.resolutionHydrated &&
        item.state != PendingMessageState.processing &&
        !deliveryKeys.any(notifications.locallyReadIds.contains),
    isOpening: deliveryKeys.any(notifications.pendingLocalReadIds.contains),
    isResolving: isResolving,
  );
}

final class PendingMessageProjection {
  const PendingMessageProjection({
    required this.items,
    required this.isLoading,
    required this.resolutionIsDemo,
    this.remoteErrorCode,
    this.nextCursor,
  });

  final List<PendingMessage> items;
  final bool isLoading;
  final bool resolutionIsDemo;
  final String? remoteErrorCode;
  final String? nextCursor;

  int get unreadCount {
    final logicalGroups = <String>{};
    var count = 0;
    for (final item in items.where((item) => item.hasUnreadAttention)) {
      final groupKey = pendingMessageLogicalGroupKey(item);
      if (groupKey == null || logicalGroups.add(groupKey)) count += 1;
    }
    return count;
  }

  int get unresolvedCount => unreadCount;
  bool get hasDemoItems => items.any((item) => item.isDemo);
}

String pendingMessageRemoteResultRevision(Iterable<PendingMessage> items) {
  final facts = <String>[
    for (final item in items)
      if (item.source == PendingMessageSource.remote &&
          item.remoteNotificationId != null &&
          item.isTerminalTask)
        jsonEncode(<Object?>[
          item.remoteNotificationId,
          item.remoteDeliveryResolutionKey,
          item.taskId,
          item.targetType,
          item.targetId,
          item.stage,
          item.state.name,
        ]),
  ]..sort();
  if (facts.isEmpty) return '';
  return sha256.convert(utf8.encode(jsonEncode(facts))).toString();
}

typedef PendingMessageChatResultEvidence = ({
  Set<String> matchingTaskIds,
  Set<String> durableSucceededTaskIds,
});

PendingMessageChatResultEvidence pendingMessageChatResultEvidence({
  required String threadId,
  required Iterable<ChatMessage> messages,
  required Iterable<AgentTaskLedgerEntry> taskLedger,
  required Iterable<PendingMessage> pendingMessages,
  String? visibleFailedTaskId,
}) {
  final ledgerByIdentity = <String, AgentTaskLedgerEntry>{};
  for (final entry in taskLedger) {
    if (entry.kind != 'chat' || entry.threadId != threadId) continue;
    for (final identity in entry.resultTaskIds) {
      final current = ledgerByIdentity[identity];
      if (current == null || entry.createdAt.isAfter(current.createdAt)) {
        ledgerByIdentity[identity] = entry;
      }
    }
  }

  final remoteStateByTaskId = <String, PendingMessageState>{};
  for (final item in pendingMessages) {
    final taskId = item.taskId?.trim();
    if (item.source != PendingMessageSource.remote ||
        !item.isTerminalTask ||
        item.targetType != 'thread' ||
        item.targetId != threadId ||
        taskId == null ||
        taskId.isEmpty) {
      continue;
    }
    remoteStateByTaskId[taskId] = item.state;
  }

  final visibleIdentities = <String>{};
  for (final message in messages) {
    if (message.threadId != threadId ||
        message.role != ChatMessageRole.assistant ||
        !message.hasVisibleContent ||
        message.status == 'streaming' ||
        message.localDelivery != ChatLocalDeliveryState.server) {
      continue;
    }
    visibleIdentities.addAll(<String>{
      if (message.agentRunId?.trim() case final identity?
          when identity.isNotEmpty)
        identity,
      if (message.taskId?.trim() case final identity? when identity.isNotEmpty)
        identity,
    });
  }

  final evidenceByTaskId = <String, PendingMessageState>{};
  for (final identity in visibleIdentities) {
    final ledger = ledgerByIdentity[identity];
    if (ledger == null || !ledger.isTerminal) continue;
    final state = ledger.status == 'succeeded'
        ? PendingMessageState.succeeded
        : PendingMessageState.failed;
    for (final resultTaskId in ledger.resultTaskIds) {
      evidenceByTaskId[resultTaskId] = state;
    }
  }
  // An exact unresolved server delivery is newer public evidence for its own
  // identity and therefore wins over a conflicting local ledger snapshot.
  for (final identity in visibleIdentities) {
    final remoteState = remoteStateByTaskId[identity];
    if (remoteState != null) evidenceByTaskId[identity] = remoteState;
  }

  final succeeded = <String>{
    for (final entry in evidenceByTaskId.entries)
      if (entry.value == PendingMessageState.succeeded) entry.key,
  };
  final failed = <String>{
    for (final entry in evidenceByTaskId.entries)
      if (entry.value == PendingMessageState.failed) entry.key,
  };
  final durableSucceeded = <String>{...succeeded};
  for (final ledger in ledgerByIdentity.values.toSet()) {
    final publicTaskId = ledger.publicTaskId;
    if (ledger.status != 'succeeded' ||
        publicTaskId == null ||
        publicTaskId == ledger.taskId) {
      continue;
    }
    durableSucceeded.remove(ledger.taskId);
    if (!succeeded.contains(publicTaskId)) {
      durableSucceeded.remove(publicTaskId);
    }
  }

  final failedTaskId = visibleFailedTaskId?.trim();
  if (failedTaskId != null && failedTaskId.isNotEmpty) {
    final ledger = ledgerByIdentity[failedTaskId];
    if (ledger != null && ledger.isTerminal && ledger.status != 'succeeded') {
      failed.addAll(ledger.resultTaskIds);
    } else if (remoteStateByTaskId[failedTaskId] ==
        PendingMessageState.failed) {
      failed.add(failedTaskId);
    }
  }

  return (
    matchingTaskIds: Set<String>.unmodifiable(<String>{
      ...succeeded,
      ...failed,
    }),
    durableSucceededTaskIds: Set<String>.unmodifiable(durableSucceeded),
  );
}

@visibleForTesting
String pendingMessageTaskRevision(Iterable<AgentTaskLedgerEntry> entries) {
  final facts = <String>[
    for (final entry in entries)
      jsonEncode(<Object?>[
        entry.taskId,
        entry.publicTaskId,
        entry.kind,
        entry.status,
        entry.createdAt.toUtc().microsecondsSinceEpoch,
        entry.threadId,
        entry.scene?.apiValue,
        entry.purpose?.apiValue,
        entry.localNoteId,
        entry.remoteNoteId,
        entry.targetPart?.name,
        entry.recordingId,
        entry.failureCode,
        entry.outputPartRevisionId,
        entry.subjectTitle,
        entry.inputPartRevisionId,
        entry.targetPartRevisionId,
        entry.operationId,
      ]),
  ]..sort();
  return sha256.convert(utf8.encode(jsonEncode(facts))).toString();
}

@visibleForTesting
String pendingMessageKnowledgeRevision(
  KnowledgeLibraryController knowledge, {
  Set<String> activeDerivedNoteIds = const <String>{},
  String? aggregationGeneratedNoteId,
}) {
  final facts = <String>[];
  for (final note in knowledge.notes) {
    final sproutSubmission = knowledge.sproutSubmissionFor(note.id);
    final activeTasks = <String>[
      for (final task in note.activeDerivedTasks)
        if (!task.isTerminal)
          jsonEncode(<Object?>[
            task.fileAgentRunId,
            task.stage.wireValue,
            task.status,
          ]),
    ]..sort();
    final legacySproutPending = switch (note.sproutStatus) {
      V3SproutTaskStatus.queued ||
      V3SproutTaskStatus.running ||
      V3SproutTaskStatus.failed => true,
      _ => false,
    };
    final isAggregationResult = note.id == aggregationGeneratedNoteId;
    if (activeTasks.isEmpty &&
        !legacySproutPending &&
        sproutSubmission == null &&
        !activeDerivedNoteIds.contains(note.id) &&
        !activeDerivedNoteIds.contains(note.remoteNoteId?.trim()) &&
        !isAggregationResult) {
      continue;
    }
    facts.add(
      jsonEncode(<Object?>[
        'note',
        note.id,
        note.title,
        note.updatedAt.toUtc().microsecondsSinceEpoch,
        note.sproutStatus.name,
        note.sproutError,
        if (sproutSubmission != null) ...<Object?>[
          sproutSubmission.operationId,
          sproutSubmission.status.name,
          sproutSubmission.errorCode,
          sproutSubmission.startedAt.toUtc().microsecondsSinceEpoch,
        ],
        activeTasks,
        isAggregationResult,
        if (isAggregationResult) note.createdAt.toUtc().microsecondsSinceEpoch,
      ]),
    );
  }
  facts.sort();
  return sha256.convert(utf8.encode(jsonEncode(facts))).toString();
}

@visibleForTesting
String pendingMessageAggregationRevision(FeedAggregationController value) {
  return jsonEncode([
    for (final notice in value.taskNotices)
      [
        notice.reference,
        notice.runId,
        notice.phase.name,
        notice.title,
        notice.message,
        notice.errorCode,
        notice.createdAt.toUtc().microsecondsSinceEpoch,
        notice.note?.id,
        notice.note?.title,
        notice.isCurrent,
      ],
  ]);
}

// resident-provider: Preserves the pending message projection reducer dependency identity across route changes.
final _pendingMessageProjectionReducerProvider =
    Provider<PendingMessageProjectionReducer>(
      (ref) => PendingMessageProjectionReducer(),
    );

@visibleForTesting
final class PendingMessageProjectionReducer {
  PendingMessageProjection? _projection;
  Object? _nonTaskRevision;
  int _taskDeltaSequence = -1;
  int fullRebuildCount = 0;
  int incrementallyVisitedTaskEntries = 0;

  PendingMessageProjection project({
    bool incrementalEnabled = true,
    String? activeWorkspaceId,
    required Object nonTaskRevision,
    required int taskDeltaSequence,
    required AgentTaskLedgerDelta? taskDelta,
    required NotificationControllerState notifications,
    required String? acceptedOnboardingRunId,
    required PendingMessageProjection Function() rebuild,
  }) {
    final current = _projection;
    if (!incrementalEnabled) {
      final rebuilt = rebuild();
      _projection = rebuilt;
      _nonTaskRevision = nonTaskRevision;
      _taskDeltaSequence = taskDeltaSequence;
      fullRebuildCount += 1;
      return rebuilt;
    }
    final isContiguous = taskDeltaSequence == _taskDeltaSequence + 1;
    final remoteTaskIds = notifications.items
        .where(
          (notification) => _notificationCanBindToWorkspace(
            notification,
            activeWorkspaceId: activeWorkspaceId,
          ),
        )
        .map(_notificationTaskKey)
        .whereType<String>()
        .toSet();
    final canPatch =
        current != null &&
        _nonTaskRevision == nonTaskRevision &&
        isContiguous &&
        taskDelta != null &&
        !taskDelta.reset &&
        (taskDelta.removedTaskIds.isEmpty || remoteTaskIds.isEmpty) &&
        taskDelta.upserts.values.every(
          (entry) =>
              entry.kind == 'chat' &&
              !entry.isTerminal &&
              !entry.resultTaskIds.any(remoteTaskIds.contains),
        );
    if (!canPatch) {
      final rebuilt = rebuild();
      _projection = rebuilt;
      _nonTaskRevision = nonTaskRevision;
      _taskDeltaSequence = taskDeltaSequence;
      fullRebuildCount += 1;
      return rebuilt;
    }

    final changedTaskIds = <String>{
      ...taskDelta.removedTaskIds,
      ...taskDelta.upserts.keys,
    };
    incrementallyVisitedTaskEntries += changedTaskIds.length;
    final items = <PendingMessage>[
      for (final item in current.items)
        if (item.source != PendingMessageSource.agentTask ||
            item.taskId == null ||
            !changedTaskIds.contains(item.taskId))
          item,
    ];
    for (final entry in taskDelta.upserts.values) {
      final projected = _agentTaskPendingMessage(
        entry,
        notifications: notifications,
        remoteTaskIds: remoteTaskIds,
        acceptedOnboardingRunId: acceptedOnboardingRunId,
      );
      if (projected != null) items.add(projected);
    }
    _sortPendingMessages(items);
    final next = PendingMessageProjection(
      items: List<PendingMessage>.unmodifiable(items),
      isLoading: current.isLoading,
      resolutionIsDemo: current.resolutionIsDemo,
      remoteErrorCode: current.remoteErrorCode,
      nextCursor: current.nextCursor,
    );
    _projection = next;
    _taskDeltaSequence = taskDeltaSequence;
    return next;
  }
}

// resident-provider: Preserves the pending message badge count dependency identity across route changes.
final pendingMessageBadgeCountProvider = Provider<int>((ref) {
  return ref.watch(
    pendingMessageProjectionProvider.select(
      (projection) => projection.unreadCount,
    ),
  );
});

// resident-provider: Tracks only Knowledge assets that can change an unresolved message destination.
final pendingMessageKnowledgeRevisionProvider = Provider<String>((ref) {
  final notifications = ref.watch(notificationControllerProvider).state;
  final activeWorkspaceId = ref.watch(
    sessionStoreProvider.select((store) => readyWorkspaceId(store.state)),
  );
  ref.watch(
    chatRunTrackerProvider.select((tracker) => tracker.taskLedgerDeltaSequence),
  );
  final taskTracker = ref.read(chatRunTrackerProvider);
  final taskBoundNoteIds = <String>{
    for (final task in taskTracker.taskLedger)
      if (task.localNoteId != null) task.localNoteId!,
    for (final task in taskTracker.taskLedger)
      if (task.remoteNoteId != null) task.remoteNoteId!,
    for (final notification in notifications.unresolvedItems)
      if (_notificationTargetType(notification) == 'asset' &&
          _notificationCanBindToWorkspace(
            notification,
            activeWorkspaceId: activeWorkspaceId,
          ) &&
          notification.targetId.trim().isNotEmpty)
        notification.targetId.trim(),
  };
  return ref.watch(
    knowledgeLibraryControllerProvider.select(
      (knowledge) => pendingMessageKnowledgeRevision(
        knowledge,
        activeDerivedNoteIds: taskBoundNoteIds,
      ),
    ),
  );
});

// resident-provider: Preserves the pending message projection dependency identity across route changes.
final pendingMessageProjectionProvider = Provider<PendingMessageProjection>((
  ref,
) {
  final notifications = ref.watch(notificationControllerProvider).state;
  final aggregationRevision = ref.watch(
    feedAggregationControllerProvider.select(pendingMessageAggregationRevision),
  );
  final aggregation = ref.read(feedAggregationControllerProvider);
  final taskDeltaSequence = ref.watch(
    chatRunTrackerProvider.select((tracker) => tracker.taskLedgerDeltaSequence),
  );
  final taskSubjectRevision = ref.watch(
    chatRunTrackerProvider.select((tracker) => tracker.taskSubjectRevision),
  );
  final taskTracker = ref.read(chatRunTrackerProvider);
  final knowledgeRevision = ref.watch(pendingMessageKnowledgeRevisionProvider);
  final knowledge = ref.read(knowledgeLibraryControllerProvider);
  final session = ref.watch(sessionStoreProvider).state;
  final continuation = ref.watch(onboardingContinuationControllerProvider);
  final firstLaunchDeviceSetup = ref.watch(
    firstLaunchDeviceSetupControllerProvider,
  );
  final userId = session.user?.userId;
  final continuationSnapshot = continuation.snapshotFor(userId);
  final acceptedRun = continuationSnapshot.acceptedRun;
  final shouldProjectAcceptedRun = shouldProjectAcceptedOnboardingRun(
    session: session,
    acceptedRun: acceptedRun,
  );
  final projectedAcceptedRun = shouldProjectAcceptedRun ? acceptedRun : null;
  final onboardingReminderRequired =
      session.requiresInitialPositioning &&
      (continuation.isDeferredFor(userId) ||
          firstLaunchDeviceSetup.snapshot.positioning.status ==
              FirstLaunchStepStatus.failed ||
          firstLaunchDeviceSetup.snapshot.positioning.status ==
              FirstLaunchStepStatus.deferred);
  final ingestionDrafts = ref.watch(pendingMaterialIngestionDraftsProvider);
  final documentImport = ref.watch(pendingDocumentImportStateProvider);
  final automaticOutlineTasks = ref.watch(
    automaticOutlineCoordinatorProvider.select(
      (coordinator) => coordinator.tasks,
    ),
  );
  final twinMaterials = ref.watch(pendingDigitalTwinMaterialsProvider);
  final workbenchTasks = ref.watch(pendingWorkbenchGenerationProvider);
  final canvasDraft = ref.watch(pendingCanvasGenerationDraftProvider);
  final masterpieceGeneration = ref.watch(pendingMasterpieceGenerationProvider);
  final recordingUpload = ref.watch(pendingRecordingUploadStateProvider);
  final recordingProcessing = ref.watch(
    pendingRecordingProcessingStateProvider,
  );
  final internalRecording = ref.watch(
    internalRecordingControllerProvider.select(
      (controller) => controller.state,
    ),
  );
  final meetingCapture = ref.watch(
    meetingCaptureControllerProvider.select((controller) => controller.state),
  );
  final recordingBatches = ref.watch(
    recordingBatchTranscriptionControllerProvider.select(
      (controller) => controller.state.batches,
    ),
  );
  final firstLaunchDeviceSetupPending =
      firstLaunchDeviceSetup.requiresBlockingJourney;
  final nonTaskRevision = (
    notifications,
    aggregationRevision,
    knowledgeRevision,
    session,
    onboardingReminderRequired,
    continuationSnapshot.deferredAt,
    projectedAcceptedRun?.agentRunId,
    projectedAcceptedRun?.lifecycle,
    projectedAcceptedRun?.failureCode,
    projectedAcceptedRun?.workspaceId,
    projectedAcceptedRun?.attemptId,
    projectedAcceptedRun?.registrationErrorCode,
    firstLaunchDeviceSetupPending,
    ingestionDrafts,
    documentImport,
    automaticOutlineTasks,
    taskSubjectRevision,
    canvasDraft,
    workbenchTasks,
    twinMaterials,
    masterpieceGeneration,
    recordingUpload,
    recordingProcessing,
    internalRecording,
    meetingCapture,
    recordingBatches,
  );
  PendingMessageProjection rebuild() => buildPendingMessageProjection(
    notifications: notifications,
    aggregation: aggregation,
    knowledge: knowledge,
    taskTracker: taskTracker,
    taskLedger: taskTracker.taskLedger,
    ingestionDrafts: ingestionDrafts,
    documentImport: documentImport,
    automaticOutlineTasks: automaticOutlineTasks,
    canvasDraft: canvasDraft,
    workbenchTasks: workbenchTasks,
    twinMaterials: twinMaterials,
    masterpieceGeneration: masterpieceGeneration,
    masterpieceWorkspaceId: session.workspace?.workspaceId,
    activeWorkspaceId: readyWorkspaceId(session),
    recordingUpload: recordingUpload,
    recordingProcessing: recordingProcessing,
    internalRecording: internalRecording,
    meetingCapture: meetingCapture,
    recordingBatches: recordingBatches,
    firstLoginOnboardingEligible:
        session.isFirstLoginSessionEligible ||
        firstLaunchDeviceSetup.snapshot.hasStarted,
    onboardingReminderRequired: onboardingReminderRequired,
    onboardingReminderKey: userId ?? 'unavailable',
    onboardingDeferredAt: continuationSnapshot.deferredAt,
    acceptedOnboardingRun: projectedAcceptedRun,
    firstLaunchDeviceSetupPending: firstLaunchDeviceSetupPending,
    firstLaunchDeviceSetupKey: userId ?? 'unavailable',
  );
  final incrementalProjectionEnabled = ref.watch(
    performanceFeatureFlagsProvider.select(
      (flags) => flags.incrementalProjectionEnabled,
    ),
  );
  return ref
      .read(_pendingMessageProjectionReducerProvider)
      .project(
        incrementalEnabled: incrementalProjectionEnabled,
        activeWorkspaceId: readyWorkspaceId(session),
        nonTaskRevision: nonTaskRevision,
        taskDeltaSequence: taskDeltaSequence,
        taskDelta: taskTracker.lastTaskLedgerDelta,
        notifications: notifications,
        acceptedOnboardingRunId: projectedAcceptedRun?.agentRunId,
        rebuild: rebuild,
      );
});

final pendingWorkbenchGenerationProvider =
    Provider<List<WorkbenchGenerationTask>>((ref) {
      try {
        final controller = ref.watch(
          workbenchGenerationControllerProvider.notifier,
        );
        ref.watch(
          workbenchGenerationControllerProvider.select(
            (value) => value.taskRevision,
          ),
        );
        return controller.tasks;
      } on StateError {
        return const [];
      }
    });

final pendingDigitalTwinMaterialsProvider = Provider<List<DigitalTwinMaterial>>(
  (ref) {
    try {
      return ref.watch(digitalTwinMaterialControllerProvider).items;
    } on StateError {
      return const [];
    }
  },
);

final pendingCanvasGenerationDraftProvider = Provider<CreationCanvasDraft?>((
  ref,
) {
  try {
    final repository = ref.watch(creationCanvasDraftRepositoryProvider);
    if (repository is Listenable) {
      final listenable = repository as Listenable;
      void changed() => ref.invalidateSelf();
      listenable.addListener(changed);
      ref.onDispose(() => listenable.removeListener(changed));
    }
    return repository.load();
  } on StateError {
    return null;
  }
});

final pendingMasterpieceGenerationProvider =
    Provider<MasterpieceGenerationRecord?>((ref) {
      try {
        return ref.watch(masterpieceGenerationStoreProvider)?.read();
      } on StateError {
        return null;
      } on FormatException {
        return null;
      } on TypeError {
        return null;
      }
    });

bool shouldProjectAcceptedOnboardingRun({
  required SessionState session,
  required OnboardingAcceptedRun? acceptedRun,
}) {
  return session.authState == SessionAuthState.authenticated &&
      (session.requiresInitialPositioning ||
          acceptedRun?.lifecycle == OnboardingAcceptedRunLifecycle.succeeded);
}

// resident-provider: Preserves the pending material ingestion drafts dependency identity across route changes.
final pendingMaterialIngestionDraftsProvider =
    Provider<List<MaterialIngestionDraft>>((ref) {
      try {
        ref.watch(resolvedDeviceIdProvider);
        return ref.watch(materialIngestionCoordinatorProvider).drafts;
      } on StateError {
        return const <MaterialIngestionDraft>[];
      }
    });

// resident-provider: Keeps the pending document import state value consistent across sibling route consumers.
final pendingDocumentImportStateProvider = Provider<V3DocumentImportState>((
  ref,
) {
  try {
    final state = ref.watch(v3DocumentImportControllerProvider).state;
    final acceptedTasks = ref
        .read(v3DocumentImportStoreProvider)
        .listTasks()
        .where((task) => task.acceptedForImport)
        .toList(growable: false);
    return state.copyWith(durableTasks: acceptedTasks);
  } on StateError {
    return const V3DocumentImportState.initial();
  }
});

// resident-provider: Keeps the pending recording upload state value consistent across sibling route consumers.
final pendingRecordingUploadStateProvider = Provider<RecordingUploadState>((
  ref,
) {
  try {
    ref.watch(resolvedDeviceIdProvider);
    return ref.watch(recordingUploadControllerProvider).state;
  } on StateError {
    return RecordingUploadState.initial();
  }
});

// resident-provider: Keeps the pending recording processing state value consistent across sibling route consumers.
final pendingRecordingProcessingStateProvider =
    Provider<RecordingProcessingState>((ref) {
      try {
        ref.watch(resolvedDeviceIdProvider);
        return ref.watch(recordingProcessingTrackerProvider).state;
      } on StateError {
        return RecordingProcessingState.initial();
      }
    });

// resident-provider: Preserves the pending message actions dependency identity across route changes.
final pendingMessageActionsProvider = Provider<PendingMessageActions>((ref) {
  return PendingMessageActions(
    ref.watch(notificationControllerProvider.notifier),
    items: () => ref.read(pendingMessageProjectionProvider).items,
  );
});

const _deployedCursorlessNotificationWindowSize = 50;

final class PendingMessageMarkAllReadResult {
  const PendingMessageMarkAllReadResult({
    required this.total,
    required this.succeeded,
    this.fullyEnumerated = true,
  });

  final int total;
  final int succeeded;
  final bool fullyEnumerated;

  int get failed => total - succeeded;
  bool get isComplete => failed == 0 && fullyEnumerated;
}

final class PendingMessageActions {
  PendingMessageActions(this._notifications, {required this.items});

  final NotificationController _notifications;
  final List<PendingMessage> Function() items;
  final Map<({String targetType, String targetId, String? stage}), Future<bool>>
  _targetRefreshes =
      <({String targetType, String targetId, String? stage}), Future<bool>>{};
  final Map<String, Future<bool>> _taskResultSettlements =
      <String, Future<bool>>{};

  Future<bool> markRead(PendingMessage item) async {
    final results = await Future.wait<bool>(
      _logicalMembers(item).map(_markOneReadSafely),
    );
    return results.isNotEmpty && results.every((result) => result);
  }

  Future<bool> _markOneRead(PendingMessage item) async {
    if (item.isTask && item.state == PendingMessageState.succeeded) {
      for (final taskId in _pendingMessageCanonicalTaskResultIds(item)) {
        if (!await _notifications.markLocalRead(
          _succeededTaskReadKey(taskId),
        )) {
          return false;
        }
      }
    }
    final linkedKey = item.linkedDeliveryResolutionKey;
    if (linkedKey != null && !await _notifications.markLocalRead(linkedKey)) {
      return false;
    }
    if (!item.isUnread) return true;
    final remoteId = item.remoteNotificationId;
    if (remoteId == null) {
      return _notifications.markLocalRead(
        pendingMessageLocalDeliveryResolutionKey(item),
      );
    }
    for (final notification in _notifications.state.items) {
      if (notification.notificationId == remoteId &&
          notificationDeliveryResolutionKey(notification) ==
              item.remoteDeliveryResolutionKey) {
        return _notifications.markRead(notification);
      }
    }
    return false;
  }

  Future<bool> _markOneReadSafely(PendingMessage item) async {
    try {
      return await _markOneRead(item);
    } catch (_) {
      return false;
    }
  }

  Future<PendingMessageMarkAllReadResult> markAllRead({
    int maxPages = 20,
    int batchSize = 4,
  }) async {
    assert(batchSize > 0);
    final seenCursors = <String>{};
    var fullyEnumerated = true;
    var firstPageRefreshed = false;
    try {
      await _notifications.load(refresh: true, forceRemote: true);
      firstPageRefreshed = _notifications.state.lastErrorCode == null;
    } catch (_) {
      firstPageRefreshed = false;
    }
    if (!firstPageRefreshed) fullyEnumerated = false;
    for (var page = 0; firstPageRefreshed && page < maxPages; page += 1) {
      final cursor = _notifications.state.nextCursor;
      if (cursor == null || cursor.isEmpty || !seenCursors.add(cursor)) break;
      final before = _notifications.state.items.length;
      try {
        await _notifications.load(refresh: false, forceRemote: true);
      } catch (_) {
        fullyEnumerated = false;
        break;
      }
      if (_notifications.state.lastErrorCode != null) {
        fullyEnumerated = false;
        break;
      }
      if (_notifications.state.items.length <= before &&
          _notifications.state.nextCursor == cursor) {
        fullyEnumerated = false;
        break;
      }
    }
    if (_notifications.state.nextCursor != null ||
        _notifications.state.rejectedItemCount > 0 ||
        (_notifications.state.nextCursor == null &&
            _notifications.state.items.length >=
                _deployedCursorlessNotificationWindowSize)) {
      fullyEnumerated = false;
    }

    final unread = _logicalRepresentatives(
      items().where((item) => item.hasUnreadAttention),
    );
    var succeeded = 0;
    final safeBatchSize = batchSize < 1 ? 1 : batchSize;
    for (var offset = 0; offset < unread.length; offset += safeBatchSize) {
      final proposedEnd = offset + safeBatchSize;
      final end = proposedEnd < unread.length ? proposedEnd : unread.length;
      final results = await Future.wait<bool>(
        unread.sublist(offset, end).map(_markReadSafely),
      );
      succeeded += results.where((result) => result).length;
    }
    return PendingMessageMarkAllReadResult(
      total: unread.length,
      succeeded: succeeded,
      fullyEnumerated: fullyEnumerated,
    );
  }

  Future<bool> _markReadSafely(PendingMessage item) async {
    try {
      return await markRead(item);
    } catch (_) {
      return false;
    }
  }

  Future<bool> markHandled(PendingMessage item) async {
    final members = _logicalMembers(item);
    var attempted = false;
    var allSaved = true;
    final allowTaskResultArchive = item.state == PendingMessageState.succeeded;

    final recordingResultKey = item.state == PendingMessageState.succeeded
        ? pendingMessageLogicalGroupKey(item)
        : null;
    if (recordingResultKey != null) {
      attempted = true;
      final saved = await _notifications.markTaskResultShown(
        taskId: recordingResultKey,
        notificationIds: members
            .where((member) => member.state == PendingMessageState.succeeded)
            .map((member) => member.remoteNotificationId)
            .whereType<String>(),
      );
      if (!saved) return false;
    }

    for (final member in members) {
      if (member.archiveScope == PendingMessageArchiveScope.unavailable) {
        continue;
      }
      if (!allowTaskResultArchive &&
          member.archiveScope == PendingMessageArchiveScope.taskResult) {
        continue;
      }
      attempted = true;
      if (!await _markOneHandled(member)) allSaved = false;
    }
    return attempted && allSaved;
  }

  Future<bool> _markOneHandled(PendingMessage item) async {
    final handled = switch (item.archiveScope) {
      PendingMessageArchiveScope.unavailable => Future<bool>.value(false),
      PendingMessageArchiveScope.deliveryRevision =>
        _markDeliveryRevisionHandled(item),
      PendingMessageArchiveScope.taskResult =>
        item.hasServerTaskResolution
            ? _markTaskResultHandled(item)
            : _notifications.markHandledId(
                pendingMessageLocalDeliveryResolutionKey(item),
              ),
    };
    final saved = await handled;
    if (saved) unawaited(markRead(item));
    return saved;
  }

  Future<bool> _markTaskResultHandled(PendingMessage item) async {
    var savedAny = false;
    var allSaved = true;
    for (final taskId in _pendingMessageCanonicalTaskResultIds(item)) {
      savedAny = true;
      final saved = await _notifications.markTaskResultShown(
        taskId: taskId,
        notificationIds: items()
            .where(
              (candidate) =>
                  candidate.archiveScope ==
                      PendingMessageArchiveScope.taskResult &&
                  _pendingMessageTaskResultIds(candidate).contains(taskId),
            )
            .map((candidate) => candidate.remoteNotificationId)
            .whereType<String>(),
      );
      if (!saved) allSaved = false;
    }
    return savedAny && allSaved;
  }

  Future<bool> _markDeliveryRevisionHandled(PendingMessage item) async {
    final linkedKey = item.linkedDeliveryResolutionKey;
    if (linkedKey != null &&
        !_notifications.state.handledIds.contains(linkedKey)) {
      if (!await _notifications.markHandledId(linkedKey)) return false;
    }
    final remoteId = item.remoteNotificationId;
    if (remoteId == null) {
      return _notifications.markHandledId(
        pendingMessageLocalDeliveryResolutionKey(item),
      );
    }
    for (final notification in _notifications.state.items) {
      if (notification.notificationId == remoteId &&
          notificationDeliveryResolutionKey(notification) ==
              item.remoteDeliveryResolutionKey) {
        return _notifications.markHandledId(
          notificationDeliveryResolutionKey(notification),
        );
      }
    }
    return false;
  }

  List<PendingMessage> _logicalMembers(PendingMessage item) {
    final groupKey = pendingMessageLogicalGroupKey(item);
    if (groupKey == null) return <PendingMessage>[item];
    final members = items()
        .where(
          (candidate) => pendingMessageLogicalGroupKey(candidate) == groupKey,
        )
        .toList(growable: false);
    return members.isEmpty ? <PendingMessage>[item] : members;
  }

  List<PendingMessage> _logicalRepresentatives(
    Iterable<PendingMessage> candidates,
  ) {
    final result = <PendingMessage>[];
    final seenGroups = <String>{};
    for (final candidate in candidates) {
      final groupKey = pendingMessageLogicalGroupKey(candidate);
      if (groupKey == null || seenGroups.add(groupKey)) result.add(candidate);
    }
    return result;
  }

  /// Opening a settled row changes attention only. Result acknowledgement and
  /// archive remain owned by the exact destination.
  Future<bool> markOpened(PendingMessage item) async {
    if (item.state == PendingMessageState.processing) return true;
    unawaited(markRead(item));
    return true;
  }

  Future<bool> markAllHandled(Iterable<PendingMessage> items) async {
    final snapshot = List<PendingMessage>.of(items);
    var allSaved = true;
    for (final item in snapshot) {
      if (item.isUnread) continue;
      if (item.state == PendingMessageState.processing) continue;
      if (item.isTask) continue;
      if (!item.canMarkHandled) continue;
      if (!await markHandled(item)) allSaved = false;
    }
    return allSaved;
  }

  /// Called by a destination only after it has rendered the actual terminal
  /// result or a retryable failure. Navigation alone is intentionally not
  /// enough evidence to remove a task from the message center.
  Future<bool> acknowledgeResultShown({
    required String targetType,
    required String targetId,
    String? stage,
    Iterable<String>? matchingTaskIds,
    Iterable<String> durableSucceededTaskIds = const <String>[],
  }) async {
    final safeMatchingTaskIds = matchingTaskIds == null
        ? null
        : _validatedTaskIds(matchingTaskIds);
    if (targetType == 'asset' &&
        const <String>{'raw', 'outline', 'sprout'}.contains(stage) &&
        (safeMatchingTaskIds == null || safeMatchingTaskIds.isEmpty)) {
      return false;
    }
    final receiptTaskIds = _validatedTaskIds(durableSucceededTaskIds);
    if (safeMatchingTaskIds != null) {
      receiptTaskIds.retainWhere(safeMatchingTaskIds.contains);
    }
    final destinationTaskId = _destinationTaskResolutionKey(
      targetType: targetType,
      targetId: targetId,
      stage: stage,
    );
    if (destinationTaskId != null) receiptTaskIds.add(destinationTaskId);

    final snapshot = items();
    final snapshotResult = await _acknowledgeSnapshot(
      snapshot,
      targetType: targetType,
      targetId: targetId,
      stage: stage,
      matchingTaskIds: safeMatchingTaskIds,
      receiptTaskIds: receiptTaskIds,
    );
    if (snapshotResult.attempted) return snapshotResult.succeeded;

    // A result can become visible before its notification Outbox delivery
    // reaches this device. Callers for one target share only the remote read;
    // each caller still applies its own exact task evidence afterwards.
    final refreshKey = (
      targetType: targetType,
      targetId: targetId,
      stage: stage,
    );
    if (!await _refreshTarget(refreshKey)) return false;
    return _acknowledgeRefreshedTarget(
      targetType: targetType,
      targetId: targetId,
      stage: stage,
      matchingTaskIds: safeMatchingTaskIds,
      receiptTaskIds: receiptTaskIds,
    );
  }

  Future<bool> _refreshTarget(
    ({String targetType, String targetId, String? stage}) key,
  ) {
    final existing = _targetRefreshes[key];
    if (existing != null) return existing;

    final completer = Completer<bool>();
    final future = completer.future;
    _targetRefreshes[key] = future;
    unawaited(_performTargetRefresh(key, future, completer));
    return future;
  }

  Future<void> _performTargetRefresh(
    ({String targetType, String targetId, String? stage}) key,
    Future<bool> future,
    Completer<bool> completer,
  ) async {
    var refreshed = false;
    try {
      await _notifications.load(forceRemote: true);
      refreshed = _notifications.state.lastErrorCode == null;
    } catch (_) {
      refreshed = false;
    } finally {
      completer.complete(refreshed);
      if (identical(_targetRefreshes[key], future)) {
        _targetRefreshes.remove(key);
      }
    }
  }

  Future<bool> _persistTaskResultShown({
    required String taskId,
    required Iterable<String> notificationIds,
  }) {
    final existing = _taskResultSettlements[taskId];
    if (existing != null) return existing;

    final completer = Completer<bool>();
    final future = completer.future;
    _taskResultSettlements[taskId] = future;
    unawaited(
      _performTaskResultSettlement(
        taskId: taskId,
        notificationIds: notificationIds,
        future: future,
        completer: completer,
      ),
    );
    return future;
  }

  Future<void> _performTaskResultSettlement({
    required String taskId,
    required Iterable<String> notificationIds,
    required Future<bool> future,
    required Completer<bool> completer,
  }) async {
    var saved = false;
    try {
      saved = await _notifications.markTaskResultShown(
        taskId: taskId,
        notificationIds: notificationIds,
      );
    } catch (_) {
      saved = false;
    } finally {
      completer.complete(saved);
      if (identical(_taskResultSettlements[taskId], future)) {
        _taskResultSettlements.remove(taskId);
      }
    }
  }

  /// The projection provider depends on the notification controller. Calling
  /// its captured reader after a controller refresh can race Riverpod's
  /// provider rebuild. The only missing data in this branch is remote, so use
  /// the controller's durable notification state directly.
  Future<bool> _acknowledgeRefreshedTarget({
    required String targetType,
    required String targetId,
    required String? stage,
    required Set<String>? matchingTaskIds,
    required Set<String> receiptTaskIds,
  }) async {
    final terminalByTask = <String, List<AppNotification>>{};
    final readOnlyNotifications = <AppNotification>[];
    for (final notification in _notifications.state.unresolvedItems) {
      if (_notificationTargetType(notification) != targetType ||
          notification.targetId != targetId) {
        continue;
      }
      if (_notificationResultStage(notification) != stage) continue;
      final taskKey = _notificationTaskKey(notification);
      if (matchingTaskIds != null) {
        if (taskKey == null || !matchingTaskIds.contains(taskKey)) continue;
      }
      if (taskKey == null) {
        if (_remotePendingMessageState(notification) !=
            PendingMessageState.processing) {
          readOnlyNotifications.add(notification);
        }
        continue;
      }
      final state = _remotePendingMessageState(notification);
      if (state == PendingMessageState.succeeded) {
        if (matchingTaskIds != null && !receiptTaskIds.contains(taskKey)) {
          continue;
        }
        terminalByTask
            .putIfAbsent(taskKey, () => <AppNotification>[])
            .add(notification);
      } else {
        if (state != PendingMessageState.processing) {
          readOnlyNotifications.add(notification);
        }
      }
    }

    final taskIds = _requiresDeliveredSucceededTaskRow(targetType, stage)
        ? terminalByTask.keys.toSet()
        : <String>{...receiptTaskIds, ...terminalByTask.keys};
    var allTaskResolutionsSaved = true;
    for (final taskId in taskIds) {
      final notifications = terminalByTask[taskId] ?? const <AppNotification>[];
      final saved = await _persistTaskResultShown(
        taskId: taskId,
        notificationIds: notifications.map(
          (notification) => notification.notificationId,
        ),
      );
      if (!saved) {
        allTaskResolutionsSaved = false;
        continue;
      }
      for (final notification in notifications) {
        unawaited(_notifications.markRead(notification));
      }
    }

    var allReadOnlySaved = true;
    for (final notification in readOnlyNotifications) {
      if (!await _notifications.markRead(notification)) {
        allReadOnlySaved = false;
      }
    }
    if (taskIds.isNotEmpty) return allTaskResolutionsSaved;
    return readOnlyNotifications.isNotEmpty && allReadOnlySaved;
  }

  Future<({bool attempted, bool succeeded})> _acknowledgeSnapshot(
    List<PendingMessage> snapshot, {
    required String targetType,
    required String targetId,
    required String? stage,
    required Set<String>? matchingTaskIds,
    required Set<String> receiptTaskIds,
  }) async {
    bool matchesTarget(PendingMessage item) =>
        item.targetType == targetType &&
        item.targetId == targetId &&
        item.stage == stage;
    bool matchesTaskEvidence(PendingMessage item) {
      if (matchingTaskIds == null) return true;
      return _pendingMessageTaskResultIds(item).any(matchingTaskIds.contains);
    }

    bool hasSucceededTaskEvidence(PendingMessage item) {
      if (matchingTaskIds == null) return true;
      return _pendingMessageTaskResultIds(item).any(receiptTaskIds.contains);
    }

    final terminalByTask = <String, List<PendingMessage>>{};
    for (final item in snapshot) {
      if (!matchesTarget(item) ||
          !matchesTaskEvidence(item) ||
          !hasSucceededTaskEvidence(item) ||
          !item.isTerminalTask ||
          item.state != PendingMessageState.succeeded) {
        continue;
      }
      final evidencedTaskIds = matchingTaskIds == null
          ? _pendingMessageCanonicalTaskResultIds(item)
          : _pendingMessageCanonicalTaskResultIds(
              item,
            ).where(receiptTaskIds.contains).toList(growable: false);
      for (final taskId in evidencedTaskIds) {
        terminalByTask.putIfAbsent(taskId, () => <PendingMessage>[]).add(item);
      }
    }

    final taskIds = _requiresDeliveredSucceededTaskRow(targetType, stage)
        ? terminalByTask.keys.toSet()
        : <String>{...receiptTaskIds, ...terminalByTask.keys};
    var allTaskResolutionsSaved = true;
    for (final taskId in taskIds) {
      final relatedNotificationIds = snapshot
          .where(
            (candidate) =>
                candidate.isTerminalTask &&
                _pendingMessageTaskResultIds(candidate).contains(taskId),
          )
          .map((candidate) => candidate.remoteNotificationId)
          .whereType<String>();
      final saved = await _persistTaskResultShown(
        taskId: taskId,
        notificationIds: relatedNotificationIds,
      );
      if (!saved) {
        allTaskResolutionsSaved = false;
        continue;
      }
      for (final item in terminalByTask[taskId] ?? const <PendingMessage>[]) {
        unawaited(markRead(item));
      }
    }

    final readOnlyItems = snapshot.where(
      (item) =>
          matchesTarget(item) &&
          matchesTaskEvidence(item) &&
          item.state != PendingMessageState.processing &&
          !(item.isTerminalTask && item.state == PendingMessageState.succeeded),
    );
    var readOnlyAttempted = false;
    var allReadOnlySaved = true;
    for (final item in readOnlyItems) {
      readOnlyAttempted = true;
      if (!await markRead(item)) allReadOnlySaved = false;
    }
    if (taskIds.isNotEmpty) {
      return (attempted: true, succeeded: allTaskResolutionsSaved);
    }
    return (
      attempted: readOnlyAttempted,
      succeeded: readOnlyAttempted && allReadOnlySaved,
    );
  }
}

Set<String> _validatedTaskIds(Iterable<String> taskIds) {
  final result = <String>{};
  for (final value in taskIds) {
    final taskId = value.trim();
    if (notificationTaskResolutionKey(taskId) != null) result.add(taskId);
  }
  return result;
}

bool _requiresDeliveredSucceededTaskRow(String targetType, String? stage) =>
    targetType == 'asset' &&
    const <String>{'raw', 'outline', 'sprout'}.contains(stage);

String? _destinationTaskResolutionKey({
  required String targetType,
  required String targetId,
  required String? stage,
}) {
  final candidate = switch ((targetType, stage)) {
    ('recording', 'recording_processing') => 'recording:$targetId',
    ('task', null) || ('positioning_report', 'report') => targetId,
    _ => null,
  };
  return candidate != null && notificationTaskResolutionKey(candidate) != null
      ? candidate
      : null;
}

String pendingMessageOpenActionLabel(PendingMessage item) {
  if (item.state == PendingMessageState.processing) return '查看进度';
  if (item.state == PendingMessageState.failed &&
      (item.targetType == 'thread' || item.isTask)) {
    return '查看失败详情';
  }
  if (item.targetType == 'thread') return '查看回复';
  if (item.isTask) return '查看结果';
  if (item.targetType == 'first_launch_device_setup') return '继续设置';
  if (item.scene == 'onboarding') return '继续定位';
  return '打开';
}

bool canClearPendingMessages(Iterable<PendingMessage> items) => items.any(
  (item) =>
      !item.isUnread &&
      item.state != PendingMessageState.processing &&
      !item.isTask &&
      item.canMarkHandled,
);

bool _containsTaskResolution(Set<String> keys, String? taskId) {
  if (taskId == null) return false;
  final resolutionKey = notificationTaskResolutionKey(taskId);
  return resolutionKey != null && keys.contains(resolutionKey);
}

bool agentTaskNeedsUserInput(AgentTaskLedgerEntry task) => const {
  'awaiting_confirmation',
  'awaiting_input',
  'waiting_for_user',
  'requires_action',
}.contains(task.status);

PendingMessage? _agentTaskPendingMessage(
  AgentTaskLedgerEntry task, {
  required NotificationControllerState notifications,
  required Set<String> remoteTaskIds,
  required String? acceptedOnboardingRunId,
  String? assetTitle,
}) {
  if (task.kind == 'chat' && task.taskId == acceptedOnboardingRunId) {
    return null;
  }
  if (task.resultTaskIds.any(remoteTaskIds.contains)) return null;

  final terminalFailure = task.isTerminal && task.status != 'succeeded';
  final messageState = agentTaskNeedsUserInput(task)
      ? PendingMessageState.actionRequired
      : task.isTerminal
      ? terminalFailure
            ? PendingMessageState.failed
            : PendingMessageState.succeeded
      : PendingMessageState.processing;
  final stage = task.targetPart;
  final isChat = task.kind == 'chat';
  final isRecordingOutline = task.kind == 'recording_outline';
  final derivedLabel = stage == NoteFileAgentPart.outline ? '纲要' : '深度洞察';
  final normalizedAssetTitle =
      _nonEmptyText(assetTitle) ?? _nonEmptyText(task.subjectTitle);
  final normalizedChatTitle = _nonEmptyText(task.subjectTitle);
  final namedDerivedTitle =
      normalizedAssetTitle == null || normalizedAssetTitle.isEmpty
      ? null
      : '《$normalizedAssetTitle》$derivedLabel';
  final title = agentTaskNeedsUserInput(task)
      ? isChat && normalizedChatTitle != null
            ? '《$normalizedChatTitle》等待你确认'
            : namedDerivedTitle != null
            ? '$namedDerivedTitle等待你确认'
            : '任务等待你确认'
      : isChat
      ? normalizedChatTitle == null
            ? terminalFailure
                  ? '聊一聊任务未完成'
                  : task.isTerminal
                  ? '聊一聊已完成'
                  : '聊一聊正在处理'
            : terminalFailure
            ? '《$normalizedChatTitle》回复未完成'
            : task.isTerminal
            ? '《$normalizedChatTitle》回复已完成'
            : '《$normalizedChatTitle》正在回复'
      : namedDerivedTitle != null
      ? task.isTerminal
            ? '$namedDerivedTitle${terminalFailure ? '未完成' : '已完成'}'
            : '$namedDerivedTitle正在生成'
      : '$derivedLabel任务${terminalFailure
            ? '未完成'
            : task.isTerminal
            ? '已完成'
            : '正在处理'}';
  final body = agentTaskNeedsUserInput(task)
      ? '请打开原会话补充信息或确认，任务不会在等待输入时自动完成。'
      : isChat
      ? terminalFailure
            ? 'AI 回复未能完成，可打开对应会话查看状态后重试。'
            : task.isTerminal
            ? 'AI 回复已写入会话，可打开查看。'
            : 'Agent 正在分析，离开页面后会继续在前台同步。'
      : terminalFailure
      ? _derivedTaskFailureBody(task, isRecordingOutline: isRecordingOutline)
      : task.isTerminal
      ? '结果已写入资产，可打开查看。'
      : isRecordingOutline
      ? '录音纲要将在后台继续生成，完成后可从消息查看。'
      : stage == NoteFileAgentPart.germination
      ? '深度洞察任务进行中，关闭页面后仍会继续。'
      : namedDerivedTitle != null
      ? '正在使用 Agent 生成纲要。'
      : '纲要任务进行中，关闭页面后仍会继续。';
  final route = isChat
      ? task.threadId == null
            ? null
            : _chatThreadRoute(task.threadId!, purpose: task.purpose)
      : task.localNoteId == null || stage == null
      ? null
      : '/v3/feed/items/${Uri.encodeComponent(task.localNoteId!)}?stage=${stage == NoteFileAgentPart.outline ? 'summary' : 'sprout'}';
  final id = localPendingMessageId(
    PendingMessageSource.agentTask,
    'ledger:${task.taskId}',
  );
  return _applyLocalResolutionState(
    PendingMessage(
      id: id,
      source: PendingMessageSource.agentTask,
      scene: isChat
          ? 'chat'
          : stage == NoteFileAgentPart.outline
          ? 'outline'
          : 'sprout',
      title: title,
      body: body,
      state: messageState,
      isUnread: false,
      isDemo: false,
      isOpening: false,
      isResolving: false,
      createdAt: task.createdAt,
      route: route,
      canMarkHandled: false,
      taskId: task.taskId,
      taskResultAliasIds: <String>[
        for (final taskId in task.resultTaskIds)
          if (taskId != task.taskId) taskId,
      ],
      targetType: isChat ? 'thread' : 'asset',
      targetId: isChat ? task.threadId : task.localNoteId,
      stage: isChat
          ? null
          : stage == NoteFileAgentPart.outline
          ? 'outline'
          : 'sprout',
      isTask: true,
      errorCode: terminalFailure ? task.failureCode ?? task.status : null,
    ),
    notifications,
  );
}

String _derivedTaskFailureBody(
  AgentTaskLedgerEntry task, {
  required bool isRecordingOutline,
}) {
  if (isRecordingOutline && task.failureCode == 'WORKSPACE_NOT_READY') {
    return '工作空间尚未准备完成，原始转写已保留。请打开笔记详情稍后重试。';
  }
  return '原始资产已保留，可打开对应阶段重新生成。';
}

PendingMessageProjection buildPendingMessageProjection({
  required NotificationControllerState notifications,
  required FeedAggregationController aggregation,
  required KnowledgeLibraryController knowledge,
  DerivedPartRunTrackingPort? taskTracker,
  List<AgentTaskLedgerEntry>? taskLedger,
  required List<MaterialIngestionDraft> ingestionDrafts,
  required V3DocumentImportState documentImport,
  List<AutomaticOutlineTaskSnapshot> automaticOutlineTasks = const [],
  CreationCanvasDraft? canvasDraft,
  List<WorkbenchGenerationTask> workbenchTasks = const [],
  List<DigitalTwinMaterial> twinMaterials = const [],
  MasterpieceGenerationRecord? masterpieceGeneration,
  String? masterpieceWorkspaceId,
  String? activeWorkspaceId,
  required RecordingUploadState recordingUpload,
  RecordingProcessingState? recordingProcessing,
  InternalRecordingState? internalRecording,
  MeetingCaptureState? meetingCapture,
  List<RecordingBatchTranscriptionSnapshot> recordingBatches =
      const <RecordingBatchTranscriptionSnapshot>[],
  bool firstLoginOnboardingEligible = false,
  bool onboardingReminderRequired = false,
  String onboardingReminderKey = 'current-user',
  DateTime? onboardingDeferredAt,
  OnboardingAcceptedRun? acceptedOnboardingRun,
  bool firstLaunchDeviceSetupPending = false,
  String firstLaunchDeviceSetupKey = 'current-user',
}) {
  final items = <PendingMessage>[];
  final acceptedRun = acceptedOnboardingRun;
  final processing = recordingProcessing ?? RecordingProcessingState.initial();
  final retainedBatchRemoteIds = retainedRecordingBatchRemoteIds(
    recordingBatches,
  );
  final retainedBatchJobIds = retainedRecordingBatchJobIds(recordingBatches);
  final retainedBatchItems = _retainedRecordingBatchItems(recordingBatches);

  void addLocal({
    required PendingMessageSource source,
    required String taskKey,
    required String scene,
    required String title,
    required String body,
    required PendingMessageState state,
    required bool isDemo,
    DateTime? createdAt,
    String? route,
    bool replaceRoute = false,
    bool canMarkHandled = true,
    String? taskId,
    String? targetType,
    String? targetId,
    String? stage,
    bool isTask = false,
    String? errorCode,
    String? eventType,
    RecordingObjectUploadProgress? recordingUploadProgress,
  }) {
    final id = localPendingMessageId(source, taskKey);
    final resolved = _applyLocalResolutionState(
      PendingMessage(
        id: id,
        source: source,
        scene: scene,
        title: title,
        body: body,
        state: state,
        isUnread: false,
        isDemo: isDemo,
        isOpening: false,
        isResolving: false,
        createdAt: createdAt,
        route: route,
        replaceRoute: replaceRoute,
        canMarkHandled: !isTask && canMarkHandled,
        taskId: taskId,
        targetType: targetType,
        targetId: targetId,
        stage: stage,
        isTask: isTask,
        errorCode: errorCode,
        eventType: eventType,
        recordingUploadProgress: recordingUploadProgress,
      ),
      notifications,
    );
    if (resolved != null) items.add(resolved);
  }

  for (final material in twinMaterials) {
    if (material.status == DigitalTwinMaterialStatus.awaitingConfirmation ||
        material.status == DigitalTwinMaterialStatus.removed) {
      continue;
    }
    final state = switch (material.status) {
      DigitalTwinMaterialStatus.completed ||
      DigitalTwinMaterialStatus.noChanges => PendingMessageState.succeeded,
      DigitalTwinMaterialStatus.failed ||
      DigitalTwinMaterialStatus.partialFailure => PendingMessageState.failed,
      DigitalTwinMaterialStatus.reviewReady =>
        PendingMessageState.actionRequired,
      _ => PendingMessageState.processing,
    };
    addLocal(
      source: PendingMessageSource.digitalTwinMaterial,
      taskKey: material.id,
      scene: '数字孪生',
      title: material.title,
      body: switch (state) {
        PendingMessageState.succeeded => '材料处理已完成，打开查看核验结果。',
        PendingMessageState.failed => '部分处理未完成，打开原材料查看原因。',
        PendingMessageState.actionRequired => '候选内容已生成，请打开确认；尚未修改正式版本。',
        _ => '材料任务已保留，可先浏览其他页面，打开这里查询进度和结果。',
      },
      state: state,
      isDemo: false,
      createdAt: material.createdAt,
      canMarkHandled: state != PendingMessageState.processing,
      route: Uri(
        path: AppRoutePaths.digitalTwin,
        queryParameters: {'materialId': material.id},
      ).toString(),
      targetType: 'digital_twin_material',
      targetId: material.id,
      stage: material.status.name,
      errorCode: material.errorCode,
    );
  }

  for (final task in workbenchTasks) {
    final purpose = task.purpose;
    final subject = _noteCollectionSubject(task.notes);
    final state = switch (task.status) {
      WorkbenchGenerationTaskStatus.succeeded => PendingMessageState.succeeded,
      WorkbenchGenerationTaskStatus.failed => PendingMessageState.failed,
      WorkbenchGenerationTaskStatus.awaitingResult =>
        PendingMessageState.actionRequired,
      WorkbenchGenerationTaskStatus.processing =>
        PendingMessageState.processing,
    };
    addLocal(
      source: PendingMessageSource.workbenchGeneration,
      taskKey: task.id,
      scene: '创作空间',
      title:
          '$subject · ${switch (state) {
            PendingMessageState.succeeded => purpose.resultTitle,
            PendingMessageState.failed => '${purpose.resultTitle}生成未完成',
            PendingMessageState.actionRequired => '${purpose.resultTitle}结果待确认',
            _ => purpose.generatingTitle,
          }}',
      body: switch (state) {
        PendingMessageState.failed => '生成未完成，打开查看原因并重试。',
        PendingMessageState.actionRequired => '本轮查询已暂停，打开继续查询同一任务，尚不能确认云端结果。',
        _ => '可先浏览其他页面，稍后打开这里查看生成进度或结果。',
      },
      state: state,
      isDemo: false,
      createdAt: task.startedAt,
      canMarkHandled: state != PendingMessageState.processing,
      route: Uri(
        path: state == PendingMessageState.succeeded
            ? AppRoutePaths.workbenchGenerated(purpose.routeName)
            : AppRoutePaths.workbenchGenerating(purpose.routeName),
        queryParameters: {'operationId': task.id},
      ).toString(),
      targetType: 'workbench_generation',
      targetId: task.id,
      errorCode: task.errorCode,
    );
  }

  final canvasReceipt = canvasDraft?.scriptDraftReceipt;
  if (canvasReceipt != null &&
      canvasReceipt.agentRunId != null &&
      canvasDraft?.sessionId?.isNotEmpty == true &&
      canvasReceipt.phase != ScriptDraftGenerationPhase.cancelled) {
    final canvasState = switch (canvasReceipt.phase) {
      ScriptDraftGenerationPhase.ready => PendingMessageState.succeeded,
      ScriptDraftGenerationPhase.failed => PendingMessageState.failed,
      _ => PendingMessageState.processing,
    };
    addLocal(
      source: PendingMessageSource.canvasGeneration,
      taskKey: canvasReceipt.messageIdempotencyKey,
      scene: '自由创作',
      title: switch (canvasState) {
        PendingMessageState.succeeded => '《${canvasDraft!.title}》初稿已生成',
        PendingMessageState.failed => '《${canvasDraft!.title}》初稿生成需要处理',
        _ => '《${canvasDraft!.title}》初稿正在生成',
      },
      body: switch (canvasState) {
        PendingMessageState.succeeded => '打开自由创作查看并编辑生成的初稿。',
        PendingMessageState.failed => '打开原生成会话查看原因并重试。',
        _ => '可以先浏览其他页面，打开这里继续查询原任务的进度和结果。',
      },
      state: canvasState,
      isDemo: false,
      createdAt: canvasReceipt.updatedAt,
      canMarkHandled: canvasState != PendingMessageState.processing,
      route: Uri(
        path: AppRoutePaths.canvas,
        queryParameters: {
          'recoverySessionId': canvasDraft.sessionId!,
          'recoveryRunId': canvasReceipt.agentRunId!,
        },
      ).toString(),
      targetType: 'canvas_generation',
      targetId: canvasDraft.sessionId,
      stage: canvasReceipt.phase.storageValue,
      errorCode: canvasReceipt.failureCode,
    );
  }
  final masterpiece = masterpieceGeneration;
  final intent = masterpiece?.intent;
  if (masterpiece != null && (intent != null || masterpiece.published)) {
    final state = switch (intent?.stage) {
      MasterpieceGenerationStage.failed ||
      MasterpieceGenerationStage.cancelled => PendingMessageState.failed,
      MasterpieceGenerationStage.generated ||
      MasterpieceGenerationStage.awaitingInput ||
      MasterpieceGenerationStage.uncertain ||
      MasterpieceGenerationStage.submitting =>
        PendingMessageState.actionRequired,
      null => PendingMessageState.succeeded,
      _ => PendingMessageState.processing,
    };
    addLocal(
      source: PendingMessageSource.masterpieceGeneration,
      taskKey: '${masterpieceWorkspaceId ?? 'current'}:${masterpiece.attempt}',
      scene: '代表作',
      title:
          '《${_nonEmptyText(intent?.title) ?? '当前代表作'}》${switch (state) {
            PendingMessageState.succeeded => '代表作已更新',
            PendingMessageState.failed => intent?.stage == MasterpieceGenerationStage.cancelled ? '本次代表作生成已取消' : '代表作生成未完成',
            PendingMessageState.actionRequired => '代表作生成需要确认',
            _ => intent?.cancelRequested == true ? '正在确认取消代表作生成' : '代表作正在生成或收录',
          }}',
      body: '打开代表作查看原任务进度、确认生成内容或处理失败。',
      state: state,
      isDemo: false,
      canMarkHandled: state != PendingMessageState.processing,
      route: AppRoutePaths.homeForMode(AppRoutePaths.masterpieceMode),
      targetType: 'masterpiece',
      targetId: masterpieceWorkspaceId,
      stage: intent?.stage.name ?? 'completed',
    );
  }

  bool durableRecordingJobIsProjected(String? jobId) =>
      jobId != null &&
      (recordingUpload.activeDraft?.draftId == jobId ||
          recordingUpload.activeUploadDraftsById.containsKey(jobId) ||
          processing.tasks.any((task) => task.draft.draftId == jobId));

  final externalJobProjected = durableRecordingJobIsProjected(
    meetingCapture?.transcriptionJobId,
  );
  final externalJobId = meetingCapture?.transcriptionJobId?.trim();
  final externalCaptureOwnsUndurableUploadFailure =
      meetingCapture?.projectsActiveMessage == true &&
      !externalJobProjected &&
      externalJobId != null &&
      externalJobId.isNotEmpty &&
      recordingUpload.status == RecordingFileJobStatus.failed &&
      recordingUpload.lastErrorCode != null &&
      recordingUpload.lastErrorJobId == externalJobId;
  if (meetingCapture?.projectsActiveMessage == true && !externalJobProjected) {
    final activeRecording = meetingCapture!;
    final correlationId = activeRecording.correlationId?.trim();
    final failed = activeRecording.status == MeetingCaptureStatus.failed;
    final controlError = !failed && activeRecording.lastErrorCode != null;
    final preparing =
        activeRecording.status == MeetingCaptureStatus.checkingPermission ||
        activeRecording.status == MeetingCaptureStatus.starting;
    final paused = activeRecording.status == MeetingCaptureStatus.paused;
    final saving =
        activeRecording.status == MeetingCaptureStatus.stopping ||
        activeRecording.status == MeetingCaptureStatus.registeringLocal ||
        activeRecording.status == MeetingCaptureStatus.uploading;
    addLocal(
      source: PendingMessageSource.recordingTranscription,
      taskKey:
          'external-active:${correlationId?.isNotEmpty == true ? correlationId : 'starting'}',
      scene: 'external_recording',
      title: failed
          ? '外录需要处理'
          : controlError
          ? '外录操作未完成'
          : preparing
          ? '外录正在准备'
          : paused
          ? '外录已暂停'
          : saving
          ? '外录正在保存'
          : '外录进行中',
      body: failed
          ? '外录未能继续，点击返回录音界面查看并处理。'
          : controlError
          ? '已录制 · ${_recordingDuration(activeRecording.elapsedSeconds)}，录音会话仍在，点击返回处理。'
          : activeRecording.status == MeetingCaptureStatus.checkingPermission
          ? '正在确认麦克风权限，点击返回录音界面。'
          : activeRecording.status == MeetingCaptureStatus.starting
          ? '正在启动麦克风录音，点击返回录音界面。'
          : activeRecording.status == MeetingCaptureStatus.recording
          ? '正在录音 · ${_recordingDuration(activeRecording.elapsedSeconds)}，点击返回录音界面。'
          : paused
          ? '已录制 · ${_recordingDuration(activeRecording.elapsedSeconds)}，点击返回继续录音。'
          : activeRecording.status == MeetingCaptureStatus.stopping
          ? '正在结束录音，点击返回查看进度。'
          : activeRecording.status == MeetingCaptureStatus.registeringLocal
          ? '正在保存录音文件，点击返回查看进度。'
          : '正在提交录音处理任务，点击返回查看进度。',
      state: failed || controlError
          ? PendingMessageState.actionRequired
          : PendingMessageState.processing,
      isDemo: false,
      createdAt: activeRecording.startedAt,
      route: AppRoutePaths.meetingCapture,
      canMarkHandled: false,
      taskId: correlationId,
      targetType: 'external_recording',
      targetId: correlationId,
      stage: activeRecording.status.name,
      isTask: true,
      errorCode: activeRecording.lastErrorCode,
    );
  }

  final internalJobProjected = durableRecordingJobIsProjected(
    internalRecording?.transcriptionJobId,
  );
  if (internalRecording?.projectsActiveMessage == true &&
      !internalJobProjected) {
    final activeRecording = internalRecording!;
    final sessionId = activeRecording.sessionId?.trim();
    final preparing =
        activeRecording.status == InternalRecordingStatus.awaitingConsent ||
        activeRecording.status == InternalRecordingStatus.starting;
    final failed = activeRecording.status == InternalRecordingStatus.failed;
    final processing =
        activeRecording.isProcessing ||
        activeRecording.status == InternalRecordingStatus.stopping;
    addLocal(
      source: PendingMessageSource.recordingTranscription,
      taskKey:
          'internal-active:${sessionId?.isNotEmpty == true ? sessionId : 'starting'}',
      scene: 'internal_recording',
      title: failed
          ? '内录需要处理'
          : preparing
          ? '等待录屏授权'
          : processing
          ? '内录正在处理'
          : '内录进行中',
      body: failed
          ? '录屏文件已保留，点击返回重试音频处理。'
          : activeRecording.status == InternalRecordingStatus.importingMedia
          ? '正在导入录屏视频，随后分离音频并转写。'
          : preparing
          ? '请在系统界面同意录屏，或返回取消。'
          : processing
          ? '正在结束录屏、分离并保存音频，点击查看进度。'
          : '正在录屏 · ${_recordingDuration(activeRecording.elapsedSeconds)}，点击返回结束并转写。',
      state: PendingMessageState.processing,
      isDemo: false,
      createdAt: activeRecording.startedAt,
      route: AppRoutePaths.internalRecording,
      canMarkHandled: false,
      taskId: sessionId,
      targetType: 'internal_recording',
      targetId: sessionId,
      isTask: true,
    );
  }

  if (firstLoginOnboardingEligible &&
      onboardingReminderRequired &&
      acceptedRun == null) {
    addLocal(
      source: PendingMessageSource.onboarding,
      taskKey: onboardingReminderKey,
      scene: 'onboarding',
      title: '完成基础定位',
      body: '继续填写你的业务现状和内容方向，完成后这条提醒会自动消失。',
      state: PendingMessageState.actionRequired,
      isDemo: false,
      createdAt: onboardingDeferredAt,
      route: '/onboarding?resume=1',
      canMarkHandled: false,
    );
  }

  if (firstLaunchDeviceSetupPending) {
    addLocal(
      source: PendingMessageSource.firstLaunchDeviceSetup,
      taskKey: '$firstLaunchDeviceSetupKey:install-local',
      scene: 'device_setup',
      title: '继续完成启动设置',
      body: '先完成必填基础定位，报告将在后台生成；声纹和录音卡可稍后设置。',
      state: PendingMessageState.actionRequired,
      isDemo: false,
      route: '/v3/onboarding/device-setup',
      canMarkHandled: false,
      targetType: 'first_launch_device_setup',
    );
  }

  final projectedTaskLedger =
      taskLedger ??
      (taskTracker is AgentTaskLedgerPort
          ? (taskTracker as AgentTaskLedgerPort).taskLedger
          : const <AgentTaskLedgerEntry>[]);
  final notesByAnyId = <String, V3FeedItem>{};
  for (final note in knowledge.notes) {
    notesByAnyId[note.id] = note;
    final remoteNoteId = _nonEmptyText(note.remoteNoteId);
    if (remoteNoteId != null) notesByAnyId[remoteNoteId] = note;
  }
  final ledgerByTaskIdentity = <String, AgentTaskLedgerEntry>{};
  for (final task in projectedTaskLedger) {
    for (final identity in task.resultTaskIds) {
      final current = ledgerByTaskIdentity[identity];
      if (current == null || task.createdAt.isAfter(current.createdAt)) {
        ledgerByTaskIdentity[identity] = task;
      }
    }
  }

  final reconciledTasks = _reconcileTaskNotificationSources(
    notifications.items,
    projectedTaskLedger,
    activeWorkspaceId: activeWorkspaceId,
  );
  for (final notification in reconciledTasks.deliveries) {
    if (!_notificationIsVisibleInWorkspace(
      notification,
      activeWorkspaceId: activeWorkspaceId,
    )) {
      continue;
    }
    final canBindWorkspace = _notificationCanBindToWorkspace(
      notification,
      activeWorkspaceId: activeWorkspaceId,
    );
    final isAccountLevelDailyTopic =
        !canBindWorkspace &&
        isAccountLevelNotificationCompatibility(notification);
    final taskStatus = notification.taskStatus;
    final taskKey = canBindWorkspace
        ? _notificationTaskKey(notification)
        : null;
    final candidateLedgerTask = taskKey == null
        ? null
        : ledgerByTaskIdentity[taskKey];
    final ledgerBinding = candidateLedgerTask == null
        ? null
        : _verifiedLedgerNotificationBinding(notification, candidateLedgerTask);
    final ledgerTask = ledgerBinding?.task;
    final resultTaskKey =
        ledgerTask?.publicTaskId ?? ledgerTask?.taskId ?? taskKey;
    final isTask = taskKey != null;
    final state = _remotePendingMessageState(notification);
    final batchItem =
        canBindWorkspace &&
            notification.targetType == 'recording' &&
            _notificationTaskStage(notification) != 'outline'
        ? retainedBatchItems[notification.targetId.trim()]
        : null;
    if (batchItem != null &&
        batchItem.batch.status == RecordingBatchTranscriptionStatus.active &&
        state == PendingMessageState.processing) {
      continue;
    }
    final taskAlias = ledgerTask == null
        ? null
        : _agentTaskDeliveryAlias(ledgerTask);
    final linkedDeliveryResolutionKey =
        taskAlias != null && taskAlias.state == state
        ? taskAlias.resolutionKey
        : null;
    final destination =
        !isAccountLevelDailyTopic &&
            (canBindWorkspace ||
                !_notificationTargetsWorkspaceResource(notification))
        ? notificationDestinationRegistry.forNotification(notification)
        : null;
    final normalizedTargetType = _notificationTargetType(notification);
    final notificationNote = canBindWorkspace && normalizedTargetType == 'asset'
        ? notesByAnyId[notification.targetId.trim()]
        : null;
    final canonicalNote = ledgerBinding?.localNoteId == null
        ? notificationNote
        : notesByAnyId[ledgerBinding!.localNoteId!];
    final canonicalAssetId = ledgerBinding?.localNoteId ?? canonicalNote?.id;
    final resultStage = isTask
        ? ledgerBinding?.resultStage ?? _notificationResultStage(notification)
        : null;
    final canonicalAssetRouteStage =
        resultStage ??
        (!isTask ? _notificationExplicitTaskStage(notification) : null);
    final canonicalAssetRoute = canonicalAssetId == null
        ? null
        : AppRoutePaths.feedItem(
            canonicalAssetId,
            stage: switch (canonicalAssetRouteStage) {
              'outline' => 'summary',
              'sprout' => 'sprout',
              _ => null,
            },
          );
    final route = isAccountLevelDailyTopic
        ? AppRoutePaths.workbench
        : canonicalAssetRoute ??
              _serverRecordingNotificationRoute(
                batchItem: batchItem,
                state: state,
                fallback: destination?.location,
              );
    final subjectTitle =
        _nonEmptyText(canonicalNote?.title) ??
        _nonEmptyText(ledgerTask?.subjectTitle) ??
        (canBindWorkspace &&
                normalizedTargetType == 'thread' &&
                taskTracker is AgentTaskSubjectLookupPort
            ? _nonEmptyText(
                (taskTracker as AgentTaskSubjectLookupPort).chatThreadSubject(
                  notification.targetId,
                ),
              )
            : null) ??
        _nonEmptyText(batchItem?.item.title);
    final resolvesAsTaskResult =
        isTask && state == PendingMessageState.succeeded;
    if (resolvesAsTaskResult &&
        _containsTaskResolution(notifications.handledTaskIds, resultTaskKey)) {
      continue;
    }
    final deliveryResolutionKey = notificationDeliveryResolutionKey(
      notification,
    );
    if (notifications.handledIds.contains(deliveryResolutionKey) ||
        (state == PendingMessageState.failed &&
            linkedDeliveryResolutionKey != null &&
            notifications.handledIds.contains(linkedDeliveryResolutionKey))) {
      continue;
    }
    final linkedIsRead =
        (linkedDeliveryResolutionKey != null &&
            notifications.locallyReadIds.contains(
              linkedDeliveryResolutionKey,
            )) ||
        (resolvesAsTaskResult &&
            <String>{taskKey, if (resultTaskKey != null) resultTaskKey}.any(
              (identity) => notifications.locallyReadIds.contains(
                _succeededTaskReadKey(identity),
              ),
            ));
    final linkedReadIsPending =
        linkedDeliveryResolutionKey != null &&
        notifications.pendingLocalReadIds.contains(linkedDeliveryResolutionKey);
    final linkedArchiveIsPending =
        linkedDeliveryResolutionKey != null &&
        notifications.pendingHandledIds.contains(linkedDeliveryResolutionKey);
    final canMarkHandled = !isTask
        ? notification.canMarkHandled
        : state != PendingMessageState.processing &&
              state != PendingMessageState.succeeded &&
              notification.canMarkHandled;
    final isUnread =
        notifications.resolutionHydrated &&
        state != PendingMessageState.processing &&
        notification.isUnread &&
        !notifications.locallyReadIds.contains(deliveryResolutionKey) &&
        !linkedIsRead;
    items.add(
      PendingMessage(
        id: notification.notificationId,
        source: PendingMessageSource.remote,
        scene: notification.scene,
        title: isAccountLevelDailyTopic
            ? '每日推荐已生成'
            : _remoteTaskTitle(
                notification: notification,
                state: state,
                stage: canonicalAssetRouteStage,
                subjectTitle: subjectTitle,
                ledgerTask: ledgerTask,
              ),
        body: isAccountLevelDailyTopic ? '今天的推荐内容已经准备好。' : notification.body,
        state: state,
        isUnread: isUnread,
        isDemo: false,
        isOpening:
            notifications.isReadPending(notification) || linkedReadIsPending,
        isResolving: resolvesAsTaskResult
            ? _containsTaskResolution(
                notifications.pendingHandledTaskIds,
                resultTaskKey,
              )
            : notifications.pendingHandledIds.contains(deliveryResolutionKey) ||
                  linkedArchiveIsPending,
        createdAt: isUnread
            ? notification.inboxOccurredAt
            : notification.createdAt ?? notification.updatedAt,
        route: route,
        replaceRoute:
            !isAccountLevelDailyTopic &&
            (notification.targetType == 'hotspot_suggestion' ||
                notification.targetType == 'task'),
        remoteNotificationId: notification.notificationId,
        remoteDeliveryResolutionKey: deliveryResolutionKey,
        canMarkHandled: canMarkHandled,
        taskId: taskKey,
        taskResultAliasIds: <String>[
          if (resultTaskKey != null && resultTaskKey != taskKey) resultTaskKey,
        ],
        targetType: canBindWorkspace ? normalizedTargetType : 'notification',
        targetId: canBindWorkspace
            ? canonicalAssetId ?? notification.targetId
            : notification.notificationId,
        stage: resultStage,
        isTask: isTask,
        errorCode:
            taskStatus?.isTerminal == true &&
                taskStatus != AppNotificationTaskStatus.succeeded
            ? taskStatus!.name
            : null,
        eventType: notification.eventType,
        linkedDeliveryResolutionKey: linkedDeliveryResolutionKey,
      ),
    );
  }

  final remoteTaskIds = reconciledTasks.remoteTaskIds;
  final noteTitlesById = <String, String>{
    for (final entry in notesByAnyId.entries) entry.key: entry.value.title,
  };
  final ledgerDerivedTaskIds = <String>{
    for (final task in projectedTaskLedger)
      if (task.kind == 'derived_part') task.taskId,
  };
  final ledgerDerivedParts = <(String, NoteFileAgentPart)>{
    for (final task in projectedTaskLedger)
      if (task.kind == 'derived_part' &&
          task.localNoteId != null &&
          task.targetPart != null)
        (task.localNoteId!, task.targetPart!),
  };
  final pendingLedgerDerivedParts = <(String, NoteFileAgentPart)>{
    for (final task in projectedTaskLedger)
      if (task.kind == 'derived_part' &&
          !task.isTerminal &&
          task.localNoteId != null &&
          task.targetPart != null)
        (task.localNoteId!, task.targetPart!),
  };
  final recordingOutlineLedgerNoteIds = <String>{
    for (final task in projectedTaskLedger)
      if (task.kind == 'recording_outline' && task.localNoteId != null)
        task.localNoteId!,
  };
  if (acceptedRun != null) {
    final lifecycle = acceptedRun.lifecycle;
    final succeeded = lifecycle == OnboardingAcceptedRunLifecycle.succeeded;
    final failed = lifecycle == OnboardingAcceptedRunLifecycle.failed;
    final finalizing = lifecycle == OnboardingAcceptedRunLifecycle.finalizing;
    final registering =
        !acceptedRun.isBackendRegistered && !acceptedRun.isTerminal;
    addLocal(
      source: PendingMessageSource.onboarding,
      taskKey: 'positioning:${acceptedRun.agentRunId}',
      scene: 'onboarding',
      title: failed
          ? '基础定位生成失败'
          : registering
          ? '基础定位提交待确认'
          : succeeded
          ? '基础定位报告已生成'
          : finalizing
          ? '基础定位正在写入资料'
          : '基础定位正在生成',
      body: failed
          ? '报告未能完成，可返回基础定位后重新生成。'
          : registering
          ? '消息回执已保留，后台接管尚未确认，请保持应用开启并确认提交。'
          : succeeded
          ? '你的第一份定位报告已经准备好，打开后可直接查看。'
          : finalizing
          ? '报告已生成，正在写入定位资料和内容方向。'
          : '正在整理定位模块与内容方向，可随时查看进度。',
      state: failed
          ? PendingMessageState.failed
          : succeeded
          ? PendingMessageState.succeeded
          : PendingMessageState.processing,
      isDemo: false,
      route:
          '/v3/workbench/deep-positioning?focus=report&taskId=${Uri.encodeComponent(acceptedRun.agentRunId)}',
      canMarkHandled: false,
      taskId: acceptedRun.agentRunId,
      targetType: 'positioning_report',
      targetId: acceptedRun.agentRunId,
      stage: 'report',
      isTask: true,
      errorCode: failed ? acceptedRun.failureCode : null,
    );
  }
  for (final task in automaticOutlineTasks) {
    final ledgerOwnsAttempt = projectedTaskLedger.any(
      (entry) =>
          entry.kind == 'derived_part' &&
          entry.targetPart == NoteFileAgentPart.outline &&
          entry.remoteNoteId == task.remoteNoteId &&
          entry.operationId == task.operationId &&
          entry.inputPartRevisionId == task.inputRawRevisionId &&
          entry.targetPartRevisionId == task.targetOutlineRevisionId,
    );
    if (ledgerOwnsAttempt) continue;
    final failed = task.phase == AutomaticOutlinePhase.failed;
    addLocal(
      source: PendingMessageSource.agentTask,
      taskKey: 'automatic-outline:${task.attemptId}',
      scene: 'outline',
      title: '《${task.subjectTitle}》${task.statusLabel}',
      body: task.statusMessage,
      state: failed
          ? PendingMessageState.failed
          : PendingMessageState.processing,
      isDemo: false,
      createdAt: task.createdAt,
      route: AppRoutePaths.feedItem(task.localNoteId, stage: 'summary'),
      canMarkHandled: failed,
      taskId: task.attemptId,
      targetType: 'asset',
      targetId: task.localNoteId,
      stage: 'outline',
      isTask: true,
      errorCode: failed ? task.errorCode : null,
    );
  }
  for (final task in projectedTaskLedger) {
    final projected = _agentTaskPendingMessage(
      task,
      notifications: notifications,
      remoteTaskIds: remoteTaskIds,
      acceptedOnboardingRunId: acceptedRun?.agentRunId,
      assetTitle: task.localNoteId == null
          ? task.remoteNoteId == null
                ? null
                : noteTitlesById[task.remoteNoteId!]
          : noteTitlesById[task.localNoteId!] ??
                (task.remoteNoteId == null
                    ? null
                    : noteTitlesById[task.remoteNoteId!]),
    );
    if (projected != null) items.add(projected);
  }

  for (final notice in aggregation.taskNotices) {
    final completed =
        notice.phase == FeedAggregationPhase.succeeded && notice.note != null;
    final failed = notice.phase == FeedAggregationPhase.failed;
    final attention =
        notice.phase == FeedAggregationPhase.blocked ||
        notice.phase == FeedAggregationPhase.submissionUncertain;
    addLocal(
      source: PendingMessageSource.aggregation,
      taskKey: notice.reference,
      scene: 'feed_ai',
      title: completed
          ? '《${notice.note!.title}》聚合已完成'
          : '${_noteCollectionSubject(notice.sources)} · ${notice.title}',
      body: completed ? '《${notice.note!.title}》已经生成。' : notice.message,
      state: completed
          ? PendingMessageState.succeeded
          : failed
          ? PendingMessageState.failed
          : attention
          ? PendingMessageState.actionRequired
          : PendingMessageState.processing,
      isDemo: false,
      createdAt: notice.createdAt,
      route: completed
          ? '/v3/feed/items/${Uri.encodeComponent(notice.note!.id)}?stage=raw'
          : Uri(
              path: '/v3/feed/aggregation',
              queryParameters: {'taskId': notice.reference},
            ).toString(),
      canMarkHandled: false,
      taskId: notice.runId ?? notice.reference,
      targetType: completed ? 'asset' : 'topic_collision',
      targetId: completed ? notice.note!.id : notice.runId ?? notice.reference,
      stage: completed ? 'raw' : null,
      isTask: true,
      errorCode: notice.errorCode,
    );
  }

  for (final note in knowledge.notes) {
    final sproutSubmission = knowledge.sproutSubmissionFor(note.id);
    final hasCanonicalSproutLedger = ledgerDerivedParts.contains((
      note.id,
      NoteFileAgentPart.germination,
    ));
    final serverTasksByStage = <V3DerivedTaskStage, V3ActiveDerivedTask>{};
    for (final task in note.activeDerivedTasks) {
      if (!task.isTerminal) {
        serverTasksByStage.putIfAbsent(task.stage, () => task);
      }
    }
    var hasActiveDerivedSproutTask = false;
    for (final entry in <(V3DerivedTaskStage, NoteFileAgentPart)>[
      (V3DerivedTaskStage.outline, NoteFileAgentPart.outline),
      (V3DerivedTaskStage.sprout, NoteFileAgentPart.germination),
    ]) {
      if (entry.$1 == V3DerivedTaskStage.outline &&
          recordingOutlineLedgerNoteIds.contains(note.id)) {
        continue;
      }
      final serverTask = serverTasksByStage[entry.$1];
      final hasCanonicalPendingLedger = pendingLedgerDerivedParts.contains((
        note.id,
        entry.$2,
      ));
      final serverTaskAlreadyInLedger =
          serverTask != null &&
          ledgerDerivedTaskIds.contains(serverTask.fileAgentRunId);
      if (hasCanonicalPendingLedger || serverTaskAlreadyInLedger) {
        if (entry.$1 == V3DerivedTaskStage.sprout) {
          hasActiveDerivedSproutTask = true;
        }
        continue;
      }
      final localStatus = taskTracker?.derivedPartStatus(note.id, entry.$2);
      final status = localStatus ?? serverTask?.status;
      if (status == null || _isDerivedTerminalStatus(status)) continue;
      if (entry.$1 == V3DerivedTaskStage.sprout) {
        hasActiveDerivedSproutTask = true;
      }
      _addDerivedTaskMessage(
        addLocal: addLocal,
        note: note,
        stage: entry.$1,
        status: status,
        taskKey:
            serverTask?.fileAgentRunId ?? '${note.id}:${entry.$1.wireValue}',
        taskId: serverTask?.fileAgentRunId,
      );
    }
    if (!hasActiveDerivedSproutTask && sproutSubmission != null) {
      final failed = sproutSubmission.status == V3SproutTaskStatus.failed;
      addLocal(
        source: PendingMessageSource.sprout,
        taskKey: sproutSubmission.operationId,
        scene: 'sprout',
        title: '《${note.title}》深度洞察',
        body: failed ? '深度洞察任务失败，可打开笔记重试。' : '深度洞察任务进行中。',
        state: failed
            ? PendingMessageState.failed
            : PendingMessageState.processing,
        isDemo: false,
        createdAt: sproutSubmission.startedAt,
        route: '/v3/feed/items/${Uri.encodeComponent(note.id)}?stage=sprout',
        isTask: true,
        taskId: sproutSubmission.operationId,
        targetType: 'asset',
        targetId: note.id,
        stage: 'sprout',
        errorCode: failed ? sproutSubmission.errorCode : null,
      );
      continue;
    }
    final status = note.sproutStatus;
    if (!hasActiveDerivedSproutTask &&
        !hasCanonicalSproutLedger &&
        (status == V3SproutTaskStatus.queued ||
            status == V3SproutTaskStatus.running ||
            status == V3SproutTaskStatus.failed)) {
      addLocal(
        source: PendingMessageSource.sprout,
        taskKey: '${note.id}:legacy-sprout',
        scene: 'sprout',
        title: '《${note.title}》深度洞察',
        body: status == V3SproutTaskStatus.failed
            ? (note.sproutError ?? '深度洞察任务失败，可打开笔记重试。')
            : status == V3SproutTaskStatus.queued
            ? '深度洞察任务正在等待处理。'
            : '正在从原始内容生成新的洞察。',
        state: status == V3SproutTaskStatus.failed
            ? PendingMessageState.failed
            : PendingMessageState.processing,
        isDemo: true,
        createdAt: note.updatedAt,
        route: '/v3/feed/items/${Uri.encodeComponent(note.id)}?stage=sprout',
        isTask: true,
        errorCode: status == V3SproutTaskStatus.failed
            ? 'SPROUT_GENERATION_FAILED'
            : null,
      );
    }
  }

  for (final draft in ingestionDrafts) {
    if (draft.source != MaterialIngestionSource.link ||
        draft.status == MaterialIngestionStatus.completed ||
        draft.status == MaterialIngestionStatus.cancelled) {
      continue;
    }
    final failed = draft.status == MaterialIngestionStatus.failed;
    addLocal(
      source: PendingMessageSource.materialIngestion,
      taskKey: draft.id,
      scene: draft.source.wireName,
      title: '${draft.source.label} · ${draft.title}',
      body: failed ? '处理失败，可打开来源页面查看并重试。' : _ingestionStatusLabel(draft.status),
      state: failed
          ? PendingMessageState.failed
          : PendingMessageState.processing,
      isDemo: false,
      createdAt: draft.updatedAt,
      route: _ingestionRoute(draft),
      taskId: draft.remoteTaskId,
      targetType: 'asset',
      targetId: draft.noteId,
      isTask: true,
      errorCode: draft.lastErrorCode,
    );
  }

  for (final task in documentImport.durableTasks) {
    if (!task.acceptedForImport) continue;
    final rawFailed =
        task.status == V3DocumentImportTaskStatus.failed && task.needsRawImport;
    if (task.rawAssetCreated) {
      if (task.hasPendingOutline) {
        addLocal(
          source: PendingMessageSource.documentImport,
          taskKey:
              '${task.id}:outline:${task.outlineFileAgentRunId ?? 'pending'}',
          scene: 'document_outline',
          title: '《${task.displayName}》纲要',
          body: '原始资料已沉淀，正在使用 Agent 生成纲要。',
          state: PendingMessageState.processing,
          isDemo: false,
          createdAt: task.updatedAt,
          route: task.noteId == null
              ? AppRoutePaths.documentImportForTask(task.id)
              : AppRoutePaths.feedItem(task.noteId!, stage: 'summary'),
          taskId: task.outlineFileAgentRunId,
          targetType: 'asset',
          targetId: task.noteId ?? task.remoteNoteId,
          stage: 'outline',
          isTask: true,
        );
      } else if (task.hasFailedOutline) {
        addLocal(
          source: PendingMessageSource.documentImport,
          taskKey: '${task.id}:outline:failed',
          scene: 'document_outline',
          title: '《${task.displayName}》纲要生成失败',
          body: '原始资料已保留，可重新生成纲要。',
          state: PendingMessageState.failed,
          isDemo: false,
          createdAt: task.updatedAt,
          route: task.noteId == null
              ? AppRoutePaths.documentImportForTask(task.id)
              : AppRoutePaths.feedItem(task.noteId!, stage: 'summary'),
          taskId: task.outlineFileAgentRunId,
          targetType: 'asset',
          targetId: task.noteId ?? task.remoteNoteId,
          stage: 'outline',
          isTask: true,
          errorCode: task.outlineErrorCode,
        );
      }
      continue;
    }
    addLocal(
      source: PendingMessageSource.documentImport,
      taskKey: task.id,
      scene: 'document',
      title: '导入 · ${task.displayName}',
      body: rawFailed ? '文档处理失败，可打开导入页重试。' : '文档正在复制、解析并沉淀。',
      state: rawFailed
          ? PendingMessageState.failed
          : PendingMessageState.processing,
      isDemo: false,
      createdAt: task.updatedAt,
      route: AppRoutePaths.documentImportForTask(task.id),
      targetType: 'asset',
      targetId: task.noteId ?? task.remoteNoteId,
      isTask: true,
      errorCode: rawFailed ? task.lastErrorCode : null,
    );
  }

  for (final message in projectRecordingTranscriptionMessages(
    recordingBatches,
  )) {
    final batchUploadProgress =
        message.kind ==
            RecordingTranscriptionProjectedMessageKind.batchAggregate
        ? _recordingBatchUploadProgress(
            recordingBatches,
            batchId: message.targetId,
            recordingUpload: recordingUpload,
          )
        : null;
    addLocal(
      source: PendingMessageSource.recordingTranscription,
      taskKey: message.taskKey,
      scene: 'recording',
      title: message.title,
      body: message.body,
      state: switch (message.state) {
        RecordingTranscriptionProjectedMessageState.processing =>
          PendingMessageState.processing,
        RecordingTranscriptionProjectedMessageState.succeeded =>
          PendingMessageState.succeeded,
        RecordingTranscriptionProjectedMessageState.failed =>
          PendingMessageState.failed,
      },
      isDemo: false,
      createdAt: message.createdAt,
      route: message.route,
      taskId: message.taskId,
      targetType: message.targetType,
      targetId: message.targetId,
      stage: message.stage,
      isTask: true,
      errorCode: message.errorCode,
      eventType: switch (message.kind) {
        RecordingTranscriptionProjectedMessageKind.batchAggregate =>
          'recording.batch.updated',
        RecordingTranscriptionProjectedMessageKind.transcriptionCompleted =>
          'recording.transcription.completed',
        RecordingTranscriptionProjectedMessageKind.transcriptionFailed =>
          'recording.transcription.failed',
        RecordingTranscriptionProjectedMessageKind.transcriptionTimedOut =>
          'recording.transcription.timeout',
        RecordingTranscriptionProjectedMessageKind.outlineCompleted =>
          'recording.outline.completed',
        RecordingTranscriptionProjectedMessageKind.outlineFailed =>
          'recording.outline.failed',
      },
      recordingUploadProgress: batchUploadProgress,
    );
  }

  void addRecordingUploadMessage({
    required UploadDraft? draft,
    required RecordingFileJobStatus? status,
    String? errorCode,
  }) {
    final failed = status == RecordingFileJobStatus.failed;
    final key = draft?.draftId ?? errorCode ?? 'active-recording-upload';
    final recordingId = draft?.recordingId;
    addLocal(
      source: PendingMessageSource.recordingTranscription,
      taskKey: key,
      scene: 'recording',
      title: draft?.title ?? draft?.fileName ?? '录音上传与转写',
      body: failed ? '录音处理失败，可打开录音库重试。' : _recordingUploadStatusLabel(status),
      state: failed
          ? PendingMessageState.failed
          : PendingMessageState.processing,
      isDemo: false,
      createdAt: draft?.updatedAt,
      route: draft == null
          ? '/v3/recording-card?tab=local&focus=library'
          : AppRoutePaths.transcriptionJob(
              draft.draftId,
              source: draft.entrySource,
              destination: 'raw',
            ),
      taskId: draft?.asrTaskId,
      targetType: recordingId == null ? 'recording_library' : 'recording',
      targetId: recordingId,
      isTask: true,
      errorCode: errorCode ?? draft?.lastErrorCode,
      recordingUploadProgress:
          !failed && status == RecordingFileJobStatus.uploading && draft != null
          ? recordingUpload.progressForDraft(draft.draftId)
          : null,
    );
  }

  final activeUploadDrafts =
      recordingUpload.activeUploadDraftsById.values
          .where((draft) => !draft.isTerminal)
          .toList(growable: false)
        ..sort((left, right) => right.updatedAt.compareTo(left.updatedAt));
  final activeUploadDraftIds = <String>{
    for (final draft in activeUploadDrafts) draft.draftId,
  };
  for (final draft in activeUploadDrafts) {
    if (retainedBatchJobIds.contains(draft.draftId)) continue;
    addRecordingUploadMessage(
      draft: draft,
      status: RecordingFileJobStatus.uploading,
    );
  }

  final uploadDraft = recordingUpload.activeDraft;
  final uploadStatus = recordingUpload.status;
  final shouldProjectUpload =
      !externalCaptureOwnsUndurableUploadFailure &&
      !activeUploadDraftIds.contains(uploadDraft?.draftId) &&
      !retainedBatchJobIds.contains(uploadDraft?.draftId) &&
      (uploadStatus == RecordingFileJobStatus.failed ||
          (uploadDraft != null &&
              !uploadDraft.isTerminal &&
              (uploadStatus == RecordingFileJobStatus.uploading ||
                  (uploadStatus == RecordingFileJobStatus.processing &&
                      uploadDraft.recordingId?.trim().isNotEmpty != true))));
  if (shouldProjectUpload) {
    addRecordingUploadMessage(
      draft: uploadDraft,
      status: uploadStatus,
      errorCode: recordingUpload.lastErrorCode,
    );
  }

  for (final task in processing.tasks) {
    final draft = task.draft;
    final recordingId = draft.recordingId;
    if (recordingId == null || recordingId.trim().isEmpty) continue;
    if (retainedBatchRemoteIds.contains(recordingId.trim())) continue;
    final appTaskState = task.appTaskProjection.state;
    final state = switch (appTaskState) {
      AppTaskQueued() ||
      AppTaskRunning() ||
      AppTaskWaitingRemote() ||
      AppTaskPaused() => PendingMessageState.processing,
      AppTaskSucceeded() => PendingMessageState.succeeded,
      AppTaskFailed() || AppTaskCancelled() => PendingMessageState.failed,
    };
    final body = switch (task.phase) {
      RecordingProcessingPhase.transcribing ||
      RecordingProcessingPhase.storingCloudNote => '正在转写并保存到我的资产。',
      RecordingProcessingPhase.completed => '转写完成，结果已保存到我的资产。',
      RecordingProcessingPhase.failed => '转写并保存到我的资产失败。',
    };
    addLocal(
      source: PendingMessageSource.recordingTranscription,
      taskKey: draft.draftId,
      scene: 'recording',
      title: draft.title ?? draft.fileName,
      body: body,
      state: state,
      isDemo: false,
      createdAt: task.updatedAt,
      route: AppRoutePaths.transcriptionDetail(recordingId, destination: 'raw'),
      taskId: draft.asrTaskId,
      targetType: 'recording',
      targetId: recordingId,
      stage: 'recording_processing',
      isTask: true,
      errorCode: switch (appTaskState) {
        AppTaskFailed(:final errorCategory) => errorCategory,
        _ => task.errorCode,
      },
    );
  }

  _sortPendingMessages(items);
  return PendingMessageProjection(
    items: List<PendingMessage>.unmodifiable(items),
    isLoading: notifications.isLoading,
    resolutionIsDemo: notifications.resolutionIsDemo,
    remoteErrorCode: notifications.lastErrorCode,
    nextCursor: notifications.nextCursor,
  );
}

RecordingObjectUploadProgress? _recordingBatchUploadProgress(
  Iterable<RecordingBatchTranscriptionSnapshot> batches, {
  required String batchId,
  required RecordingUploadState recordingUpload,
}) {
  RecordingBatchTranscriptionSnapshot? target;
  for (final batch in batches) {
    if (batch.batchId == batchId) {
      target = batch;
      break;
    }
  }
  if (target == null ||
      target.status != RecordingBatchTranscriptionStatus.active) {
    return null;
  }

  var bytesSent = 0;
  var totalBytes = 0;
  var bytesPerSecond = 0.0;
  var matched = false;
  for (final item in target.items) {
    if (item.status != RecordingBatchTranscriptionItemStatus.submitting ||
        item.phase != RecordingBatchTranscriptionPhase.uploading) {
      continue;
    }
    final progress = recordingUpload.progressForDraft(item.jobId);
    if (progress == null) continue;
    matched = true;
    final safeTotal = progress.totalBytes < 0 ? 0 : progress.totalBytes;
    bytesSent += progress.bytesSent.clamp(0, safeTotal).toInt();
    totalBytes += safeTotal;
    if (progress.bytesPerSecond > 0) {
      bytesPerSecond += progress.bytesPerSecond;
    }
  }
  if (!matched) return null;
  final remainingBytes = (totalBytes - bytesSent).clamp(0, totalBytes).toInt();
  return RecordingObjectUploadProgress(
    draftId: 'batch:$batchId',
    bytesSent: bytesSent,
    totalBytes: totalBytes,
    bytesPerSecond: bytesPerSecond,
    estimatedRemainingSeconds: bytesPerSecond > 0
        ? (remainingBytes / bytesPerSecond).ceil()
        : null,
  );
}

void _sortPendingMessages(List<PendingMessage> items) {
  items.sort((left, right) {
    final leftTime = left.createdAt?.millisecondsSinceEpoch ?? 0;
    final rightTime = right.createdAt?.millisecondsSinceEpoch ?? 0;
    final byTime = rightTime.compareTo(leftTime);
    return byTime != 0 ? byTime : left.id.compareTo(right.id);
  });
}

void _addDerivedTaskMessage({
  required void Function({
    required PendingMessageSource source,
    required String taskKey,
    required String scene,
    required String title,
    required String body,
    required PendingMessageState state,
    required bool isDemo,
    DateTime? createdAt,
    String? route,
    bool replaceRoute,
    bool canMarkHandled,
    String? taskId,
    String? targetType,
    String? targetId,
    String? stage,
    bool isTask,
    String? errorCode,
  })
  addLocal,
  required V3FeedItem note,
  required V3DerivedTaskStage stage,
  required String status,
  required String taskKey,
  String? taskId,
}) {
  final label = stage.label;
  addLocal(
    source: PendingMessageSource.sprout,
    taskKey: 'derived:$taskKey',
    scene: stage.wireValue,
    title: '《${note.title}》$label',
    body: switch (status) {
      'admitting' || 'queued' => '$label任务正在排队。',
      'finalizing' => '$label已生成，正在写入资产。',
      _ => '正在使用 Agent 生成$label。',
    },
    state: PendingMessageState.processing,
    isDemo: false,
    createdAt: note.updatedAt,
    route:
        '/v3/feed/items/${Uri.encodeComponent(note.id)}?stage=${stage == V3DerivedTaskStage.outline ? 'summary' : 'sprout'}',
    canMarkHandled: false,
    taskId: taskId,
    targetType: taskId == null ? null : 'asset',
    targetId: taskId == null ? null : note.id,
    stage: taskId == null ? null : stage.wireValue,
    isTask: true,
  );
}

bool _isDerivedTerminalStatus(String status) => const <String>{
  'succeeded',
  'failed',
  'timeout',
  'cancelled',
  'conflict',
}.contains(status);

String localPendingMessageId(PendingMessageSource source, String taskKey) {
  final digest = sha256.convert(utf8.encode(taskKey)).toString();
  return 'local:${source.name}:$digest';
}

String? _notificationTaskKey(AppNotification notification) {
  if (notification.taskId == null && notification.taskStatus == null) {
    if (notification.eventType == 'recording.deposit.succeeded' &&
        notification.targetType == 'recording' &&
        isSafeNotificationOpaqueIdentifier(notification.targetId)) {
      return 'recording:${notification.targetId}';
    }
    return null;
  }
  // Older public rows without a task ID resolve only the event revision that
  // was actually rendered. A merge may reuse the notification row for a newer
  // event, which must remain independently visible.
  return notification.taskId ?? notificationDeliveryResolutionKey(notification);
}

PendingMessageState _remotePendingMessageState(AppNotification notification) {
  final taskStatus = notification.taskStatus;
  if (taskStatus != null) {
    if (taskStatus == AppNotificationTaskStatus.succeeded) {
      return PendingMessageState.succeeded;
    }
    return taskStatus.isTerminal
        ? PendingMessageState.failed
        : PendingMessageState.processing;
  }

  final tokens = '${notification.scene}.${notification.eventType}'
      .toLowerCase()
      .split(RegExp(r'[^a-z0-9]+'))
      .where((token) => token.isNotEmpty)
      .toSet();
  if (tokens.contains('quota') ||
      tokens.contains('insufficient') ||
      (tokens.contains('action') && tokens.contains('required'))) {
    return PendingMessageState.actionRequired;
  }
  if (tokens.any(
    const <String>{
      'failed',
      'failure',
      'timeout',
      'conflict',
      'error',
      'cancelled',
      'canceled',
    }.contains,
  )) {
    return PendingMessageState.failed;
  }
  if (tokens.any(
    const <String>{
      'succeeded',
      'success',
      'completed',
      'finished',
      'ready',
      'deposited',
    }.contains,
  )) {
    return PendingMessageState.succeeded;
  }
  if (tokens.any(
    const <String>{
      'admitting',
      'queued',
      'resolving',
      'planning',
      'running',
      'processing',
      'generating',
      'finalizing',
      'retrying',
      'waiting',
    }.contains,
  )) {
    return PendingMessageState.processing;
  }
  return PendingMessageState.informational;
}

({List<AppNotification> deliveries, Set<String> remoteTaskIds})
_reconcileTaskNotificationSources(
  Iterable<AppNotification> notifications,
  Iterable<AgentTaskLedgerEntry> ledger, {
  String? activeWorkspaceId,
}) {
  final ledgerByIdentity = <String, AgentTaskLedgerEntry>{};
  for (final task in ledger) {
    for (final identity in task.resultTaskIds) {
      final current = ledgerByIdentity[identity];
      if (current == null || task.createdAt.isAfter(current.createdAt)) {
        ledgerByIdentity[identity] = task;
      }
    }
  }
  final deliveries = <AppNotification>[];
  final remoteByTask = <String, AppNotification>{};
  for (final notification in notifications) {
    if (!_notificationIsVisibleInWorkspace(
      notification,
      activeWorkspaceId: activeWorkspaceId,
    )) {
      continue;
    }
    final identity =
        _notificationCanBindToWorkspace(
          notification,
          activeWorkspaceId: activeWorkspaceId,
        )
        ? _notificationTaskKey(notification)
        : null;
    if (identity == null) {
      if (notification.isUnresolved) deliveries.add(notification);
      continue;
    }
    final candidateTask = ledgerByIdentity[identity];
    final binding = candidateTask == null
        ? null
        : _verifiedLedgerNotificationBinding(notification, candidateTask);
    final key = binding == null
        ? 'remote:$identity'
        : 'ledger:${binding.task.taskId}';
    final current = remoteByTask[key];
    if (current == null ||
        preferTaskNotificationSnapshot(
          current: current,
          candidate: notification,
        )) {
      remoteByTask[key] = notification;
    }
  }
  final remoteTaskIds = <String>{};
  for (final notification in remoteByTask.values) {
    final identity = _notificationTaskKey(notification)!;
    final candidateTask = ledgerByIdentity[identity];
    final binding = candidateTask == null
        ? null
        : _verifiedLedgerNotificationBinding(notification, candidateTask);
    final task = binding?.task;
    final state = _remotePendingMessageState(notification);
    final remoteIsTerminal =
        state == PendingMessageState.succeeded ||
        state == PendingMessageState.failed;
    if (task != null && !remoteIsTerminal) {
      if (task.status == 'succeeded' || agentTaskNeedsUserInput(task)) continue;
      if (task.isTerminal) {
        final eventTime = notification.updatedAt ?? notification.createdAt;
        final isNewRetry =
            notification.eventId != null &&
            eventTime != null &&
            eventTime.isAfter(task.createdAt);
        if (!isNewRetry) continue;
      }
    }
    if (task != null) remoteTaskIds.addAll(task.resultTaskIds);
    if (notification.isUnresolved) deliveries.add(notification);
  }
  return (deliveries: deliveries, remoteTaskIds: remoteTaskIds);
}

bool _notificationIsVisibleInWorkspace(
  AppNotification notification, {
  required String? activeWorkspaceId,
}) {
  final active = _nonEmptyText(activeWorkspaceId);
  final owner = _nonEmptyText(notification.workspaceId);
  return active == null ||
      owner == active ||
      owner == null && isAccountLevelNotificationCompatibility(notification);
}

bool _notificationCanBindToWorkspace(
  AppNotification notification, {
  required String? activeWorkspaceId,
}) {
  final active = _nonEmptyText(activeWorkspaceId);
  if (active == null) return true;
  return _nonEmptyText(notification.workspaceId) == active;
}

bool _notificationTargetsWorkspaceResource(AppNotification notification) =>
    const <String>{
      'asset',
      'thread',
      'recording',
      'task',
    }.contains(_notificationTargetType(notification));

typedef _VerifiedLedgerNotificationBinding = ({
  AgentTaskLedgerEntry task,
  String? localNoteId,
  String? resultStage,
});

_VerifiedLedgerNotificationBinding? _verifiedLedgerNotificationBinding(
  AppNotification notification,
  AgentTaskLedgerEntry task,
) {
  final taskIdentity = _notificationTaskKey(notification);
  if (taskIdentity == null || !task.resultTaskIds.contains(taskIdentity)) {
    return null;
  }
  final targetType = _notificationTargetType(notification);
  final targetId = notification.targetId.trim();
  final explicitStage = _notificationExplicitTaskStage(notification);
  if (task.kind == 'chat') {
    final threadId = task.threadId?.trim();
    if (targetType != 'thread' ||
        threadId == null ||
        threadId.isEmpty ||
        targetId != threadId ||
        explicitStage != null) {
      return null;
    }
    return (task: task, localNoteId: null, resultStage: null);
  }
  if (task.kind != 'derived_part' && task.kind != 'recording_outline') {
    return null;
  }
  final localNoteId = task.localNoteId?.trim();
  final remoteNoteId = task.remoteNoteId?.trim();
  final resultStage = switch (task.targetPart) {
    NoteFileAgentPart.raw => 'raw',
    NoteFileAgentPart.outline => 'outline',
    NoteFileAgentPart.germination => 'sprout',
    null => null,
  };
  if (targetType != 'asset' ||
      localNoteId == null ||
      localNoteId.isEmpty ||
      resultStage == null ||
      (targetId != localNoteId &&
          (remoteNoteId == null ||
              remoteNoteId.isEmpty ||
              targetId != remoteNoteId)) ||
      (explicitStage != null && explicitStage != resultStage)) {
    return null;
  }
  return (task: task, localNoteId: localNoteId, resultStage: resultStage);
}

typedef _RetainedRecordingBatchItem = ({
  RecordingBatchTranscriptionSnapshot batch,
  RecordingBatchTranscriptionItem item,
});

Map<String, _RetainedRecordingBatchItem> _retainedRecordingBatchItems(
  Iterable<RecordingBatchTranscriptionSnapshot> batches,
) {
  final retained = batches.toList(growable: false)
    ..sort((left, right) {
      final leftActive =
          left.status == RecordingBatchTranscriptionStatus.active;
      final rightActive =
          right.status == RecordingBatchTranscriptionStatus.active;
      if (leftActive != rightActive) return leftActive ? -1 : 1;
      final updated = right.updatedAt.compareTo(left.updatedAt);
      if (updated != 0) return updated;
      final created = right.createdAt.compareTo(left.createdAt);
      return created != 0 ? created : left.batchId.compareTo(right.batchId);
    });
  final result = <String, _RetainedRecordingBatchItem>{};
  for (final batch in retained) {
    for (final item in batch.items) {
      final remoteRecordingId = item.remoteRecordingId?.trim();
      if (remoteRecordingId == null || remoteRecordingId.isEmpty) continue;
      result.putIfAbsent(remoteRecordingId, () => (batch: batch, item: item));
    }
  }
  return result;
}

String? _serverRecordingNotificationRoute({
  required _RetainedRecordingBatchItem? batchItem,
  required PendingMessageState state,
  required String? fallback,
}) {
  if (batchItem == null) return fallback;
  final itemStatus = batchItem.item.status;
  final needsBatchRoute =
      (batchItem.batch.status == RecordingBatchTranscriptionStatus.active &&
          (state == PendingMessageState.succeeded ||
              state == PendingMessageState.failed)) ||
      itemStatus == RecordingBatchTranscriptionItemStatus.failed ||
      itemStatus == RecordingBatchTranscriptionItemStatus.timedOut;
  if (!needsBatchRoute) return fallback;
  return AppRoutePaths.transcriptionBatch(
    batchItem.batch.batchId,
    focusItem: batchItem.item.itemId,
  );
}

String _notificationTargetType(AppNotification notification) =>
    switch (notification.targetType) {
      'note' || 'hnote' || 'asset' => 'asset',
      'thread' => 'thread',
      _ => notification.targetType,
    };

String? _notificationExplicitTaskStage(AppNotification notification) {
  final signal = '${notification.scene}.${notification.eventType}'
      .toLowerCase();
  if (notification.eventType == 'recording.deposit.succeeded' &&
      notification.targetType == 'recording') {
    return 'recording_processing';
  }
  if (signal.contains('germination') || signal.contains('sprout')) {
    return 'sprout';
  }
  if (signal.contains('outline') || signal.contains('minutes')) {
    return 'outline';
  }
  final tokens = signal
      .split(RegExp(r'[^a-z0-9]+'))
      .where((token) => token.isNotEmpty);
  if (tokens.contains('raw')) return 'raw';
  return null;
}

String? _notificationTaskStage(AppNotification notification) {
  final explicitStage = _notificationExplicitTaskStage(notification);
  if (explicitStage != null) return explicitStage;
  if (notification.targetType == 'note' || notification.targetType == 'hnote') {
    return 'raw';
  }
  return null;
}

String? _notificationResultStage(AppNotification notification) =>
    notificationDestinationRegistry
        .forNotification(notification)
        ?.stage
        ?.receiptValue ??
    _notificationTaskStage(notification);

String _remoteTaskTitle({
  required AppNotification notification,
  required PendingMessageState state,
  required String? stage,
  required String? subjectTitle,
  required AgentTaskLedgerEntry? ledgerTask,
}) {
  final subject = _nonEmptyText(subjectTitle);
  final tasklessNamedDerivedResult =
      _notificationTaskKey(notification) == null &&
      _notificationTargetType(notification) == 'asset' &&
      (stage == 'outline' || stage == 'sprout') &&
      (state == PendingMessageState.succeeded ||
          state == PendingMessageState.failed);
  final tasklessNamedChatLifecycle =
      _notificationTaskKey(notification) == null &&
      _isTrustedChatLifecycleNotification(notification);
  if (subject == null ||
      (_notificationTaskKey(notification) == null &&
          !tasklessNamedDerivedResult &&
          !tasklessNamedChatLifecycle)) {
    return notification.title;
  }
  final suffix = switch (state) {
    PendingMessageState.processing => '正在处理',
    PendingMessageState.actionRequired => '等待确认',
    PendingMessageState.succeeded => '已完成',
    PendingMessageState.failed => '未完成',
    PendingMessageState.informational => '有新进展',
  };
  if (ledgerTask?.kind == 'chat' || notification.targetType == 'thread') {
    return switch (state) {
      PendingMessageState.processing => '《$subject》正在回复',
      PendingMessageState.actionRequired => '《$subject》回复等待确认',
      PendingMessageState.succeeded => '《$subject》回复已完成',
      PendingMessageState.failed => '《$subject》回复未完成',
      PendingMessageState.informational => '《$subject》回复有新进展',
    };
  }
  return switch (stage) {
    'outline' =>
      '《$subject》纲要${state == PendingMessageState.processing ? '正在生成' : suffix}',
    'sprout' =>
      '《$subject》深度洞察${state == PendingMessageState.processing ? '正在生成' : suffix}',
    'recording_processing' => '《$subject》转写$suffix',
    _ => '《$subject》$suffix',
  };
}

bool _isTrustedChatLifecycleNotification(AppNotification notification) {
  if (_notificationTargetType(notification) != 'thread' ||
      !isSafeNotificationOpaqueIdentifier(notification.targetId)) {
    return false;
  }
  final tokens = '${notification.scene}.${notification.eventType}'
      .toLowerCase()
      .split(RegExp(r'[^a-z0-9]+'))
      .where((token) => token.isNotEmpty)
      .toSet();
  final hasChatOrigin =
      tokens.contains('chat') ||
      (tokens.contains('agent') && tokens.contains('run'));
  final hasLifecycleState = tokens.any(
    const <String>{
      'admitting',
      'queued',
      'resolving',
      'planning',
      'running',
      'processing',
      'generating',
      'finalizing',
      'retrying',
      'waiting',
      'action',
      'required',
      'succeeded',
      'success',
      'completed',
      'finished',
      'ready',
      'failed',
      'failure',
      'timeout',
      'conflict',
      'error',
      'cancelled',
      'canceled',
      'progress',
    }.contains,
  );
  return hasChatOrigin && hasLifecycleState;
}

String _noteCollectionSubject(Iterable<V3FeedItem> notes) {
  final titles = <String>[
    for (final note in notes)
      if (_nonEmptyText(note.title) case final title?) title,
  ]..sort();
  if (titles.isEmpty) return '当前资产';
  if (titles.length == 1) return '《${titles.first}》';
  return '《${titles.first}》等 ${titles.length} 篇';
}

String? _nonEmptyText(String? value) {
  final normalized = value?.trim();
  if (normalized == null || normalized.isEmpty) return null;
  return String.fromCharCodes(normalized.runes.take(160));
}

String _chatThreadRoute(String threadId, {ChatConversationPurpose? purpose}) {
  return Uri(
    path: '/v3/feed/chat',
    queryParameters: <String, String>{
      'threadId': threadId,
      if (purpose != null) 'purpose': purpose.routeValue,
    },
  ).toString();
}

String _ingestionRoute(MaterialIngestionDraft draft) =>
    AppRoutePaths.linkImportForDraft(draft.id);

String _ingestionStatusLabel(MaterialIngestionStatus status) =>
    switch (status) {
      MaterialIngestionStatus.draft => '资料已保存，等待提交。',
      MaterialIngestionStatus.uploading => '正在上传私有资料。',
      MaterialIngestionStatus.submitting => '正在创建分析任务。',
      MaterialIngestionStatus.queued => '分析任务正在排队。',
      MaterialIngestionStatus.analyzing => '正在分析并生成笔记。',
      MaterialIngestionStatus.completed => '处理完成。',
      MaterialIngestionStatus.failed => '处理失败。',
      MaterialIngestionStatus.cancelled => '任务已取消。',
    };

String _recordingUploadStatusLabel(RecordingFileJobStatus? status) =>
    switch (status) {
      RecordingFileJobStatus.uploading => '正在上传录音文件。',
      RecordingFileJobStatus.processing => '正在等待转写结果。',
      RecordingFileJobStatus.ready => '录音转写已写入笔记。',
      RecordingFileJobStatus.failed => '录音处理失败。',
      null => '等待处理。',
    };

String _recordingDuration(int elapsedSeconds) {
  final safeSeconds = elapsedSeconds < 0 ? 0 : elapsedSeconds;
  final hours = safeSeconds ~/ 3600;
  final minutes = (safeSeconds % 3600) ~/ 60;
  final seconds = safeSeconds % 60;
  return '${hours.toString().padLeft(2, '0')}:'
      '${minutes.toString().padLeft(2, '0')}:'
      '${seconds.toString().padLeft(2, '0')}';
}
