import 'package:huahuo_api/huahuo_api.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'database_providers.dart';
import '../../core/api/scoped_read_cache.dart';
import '../../core/auth/session_store.dart';
import '../../features/agent/application/mobile_agent_capability_controller.dart';
import '../../features/chat/application/chat_controller.dart';
import '../../features/chat/application/chat_run_tracker.dart';
import '../../features/chat/application/chat_thread_progress_poller.dart';
import '../../features/chat/data/chat_api.dart';
import '../../features/chat/data/remote_project_assistant_runtime.dart';
import '../../features/chat/domain/assistant_runtime.dart';
import '../../features/chat/domain/chat_repository.dart';
import '../../features/chat/domain/chat_context.dart';
import '../../features/chat/domain/chat_models.dart';
import '../bootstrap/app_providers.dart';
import '../lifecycle/app_activity_coordinator.dart';
import '../runtime/runtime_provider_module.dart';

// resident-provider: Shares one chat api dependency for the full account session.
final chatRepositoryProvider = Provider<ChatRepository>((ref) {
  return RemoteProjectChatRepository(
    apiClient: ref.watch(apiClientProvider),
    agentFeatures: MobileChatAgentFeatureSelectionPort(
      ref.watch(mobileAgentCapabilityControllerProvider.notifier),
    ),
  );
});

// resident-provider: Shares one provider-neutral assistant runtime dependency
// for the full account session.
final remoteProjectAssistantRuntimeProvider =
    Provider<RemoteProjectAssistantRuntime>((ref) {
      return RemoteProjectAssistantRuntime(ref.watch(apiClientProvider));
    });

final assistantRuntimeProvider = Provider<AssistantRuntimePort>(
  (ref) => ref.watch(remoteProjectAssistantRuntimeProvider),
);

final assistantRuntimeStreamProvider = Provider<AssistantRuntimeStreamPort>(
  (ref) => ref.watch(remoteProjectAssistantRuntimeProvider),
);

final assistantThreadProgressProvider = Provider<AssistantThreadProgressPort>(
  (ref) => ref.watch(remoteProjectAssistantRuntimeProvider),
);

final class MobileChatAgentFeatureSelectionPort
    implements ChatAgentFeatureSelectionPort {
  const MobileChatAgentFeatureSelectionPort(this._controller);

  final MobileAgentCapabilityController _controller;

  @override
  Future<ApiResult<AgentFeatureAvailability>> resolveFeature(
    String featureId,
  ) async {
    final access = await _controller.ensureFeature(featureId);
    final availability = access.availability;
    if (availability != null) {
      return ApiResult<AgentFeatureAvailability>.success(
        data: availability,
        status: 200,
        idempotencyStore: SubmissionKeyStore.empty,
      );
    }
    return ApiResult<AgentFeatureAvailability>.failure(
      error: AppFailure(
        code: access.errorCode ?? 'CHAT_AGENT_CATALOG_UNAVAILABLE',
        category: AppFailureCategory.compatibility,
        message: 'Chat Agent capability is unavailable',
        userMessageKey: 'error.chat.agentUnavailable',
        recoveryActions: const <String>['retry'],
      ),
      idempotencyStore: SubmissionKeyStore.empty,
    );
  }
}

// resident-provider: Serializes Chat admission for the authenticated account.
final chatConversationAdmissionCoordinatorProvider =
    Provider<ChatConversationAdmissionCoordinator>((ref) {
      return ChatConversationAdmissionCoordinator(
        userScope: ref.watch(authenticatedUserDataScopeProvider),
      );
    });

final class ChatThreadRunState {
  ChatThreadRunState(
    Iterable<ChatRunActivity> activities, {
    this.latestCompletion,
  }) : activities = List<ChatRunActivity>.unmodifiable(activities);

  static final empty = ChatThreadRunState(const <ChatRunActivity>[]);

  final List<ChatRunActivity> activities;
  final ChatRunCompletion? latestCompletion;

  bool get isPending => activities.any((activity) => !activity.isTerminal);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ChatThreadRunState &&
          _sameActivities(activities, other.activities) &&
          _sameCompletion(latestCompletion, other.latestCompletion);

  @override
  int get hashCode => Object.hash(
    Object.hashAll(activities),
    _completionHash(latestCompletion),
  );
}

bool _sameActivities(List<ChatRunActivity> left, List<ChatRunActivity> right) {
  if (identical(left, right)) return true;
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

bool _sameCompletion(ChatRunCompletion? left, ChatRunCompletion? right) =>
    identical(left, right) ||
    left != null &&
        right != null &&
        left.agentRunId == right.agentRunId &&
        left.threadId == right.threadId &&
        left.scene == right.scene &&
        left.purpose == right.purpose &&
        left.status == right.status &&
        left.completionMode == right.completionMode &&
        left.assistantMessageId == right.assistantMessageId &&
        left.failureCode == right.failureCode;

int _completionHash(ChatRunCompletion? completion) => completion == null
    ? 0
    : Object.hash(
        completion.agentRunId,
        completion.threadId,
        completion.scene,
        completion.purpose,
        completion.status,
        completion.completionMode,
        completion.assistantMessageId,
        completion.failureCode,
      );

final chatThreadRunStateProvider = Provider.autoDispose
    .family<ChatThreadRunState, String>((ref, threadId) {
      final normalized = threadId.trim();
      if (!isSafeChatIdentifier(normalized)) return ChatThreadRunState.empty;
      return ref.watch(
        chatRunTrackerProvider.select((tracker) {
          final completion = tracker.lastCompletion;
          return ChatThreadRunState(
            tracker.activitiesForThread(normalized),
            latestCompletion: completion?.threadId == normalized
                ? completion
                : null,
          );
        }),
      );
    });

final chatRunActivityProvider = Provider.autoDispose
    .family<ChatRunActivity?, ({String threadId, String agentRunId})>((
      ref,
      key,
    ) {
      if (!isSafeChatIdentifier(key.threadId) ||
          !isSafeAgentRunIdentifier(key.agentRunId)) {
        return null;
      }
      return ref.watch(
        chatRunTrackerProvider.select(
          (tracker) => tracker.activityFor(
            threadId: key.threadId,
            agentRunId: key.agentRunId,
          ),
        ),
      );
    });

final creationCanvasChatControllerProvider =
    ChangeNotifierProvider.autoDispose<ChatController>((ref) {
      final route = AgentFeatureRoutes.forFeature('creation.free');
      if (route == null) {
        throw StateError('creation.free Agent route is unavailable');
      }
      return ChatController(
        api: ref.watch(chatRepositoryProvider),
        assistantRuntime: ref.watch(assistantRuntimeProvider),
        runTracker: ref.watch(chatRunTrackerProvider.notifier),
        scopedReadCache: _chatScopedReadCache(ref),
        scene: ChatScene.workAi,
        aliasRepository: ref.watch(chatThreadAliasRepositoryProvider),
        admissionCoordinator: ref.watch(
          chatConversationAdmissionCoordinatorProvider,
        ),
        workspaceReady: () => _isReadyWorkspace(ref),
        agentScope: ChatAgentScope.fixed(route.agentProfileId),
        userVisibleTextProjector: projectCreationCanvasChatUserPrompt,
        coalescedStreamingUi: _coalescedStreamingUi(ref),
        threadProgressPoller: _threadProgressPoller(ref),
        assistantProgress: ref.watch(assistantThreadProgressProvider),
      );
    });

ChatController createFeedAiChatController(
  Ref ref, {
  ChatConversationPurpose conversationPurpose = ChatConversationPurpose.general,
  String? initialAgentProfileId,
  bool bindAgentProfileFromThread = false,
  bool restoreRecentConversationOnCreate = false,
  bool browseAllAgentProfiles = false,
}) {
  final initialProfile = browseAllAgentProfiles
      ? null
      : knownPublicChatAgentProfileId(initialAgentProfileId) ??
            (conversationPurpose == ChatConversationPurpose.general
                ? standardCreationChatAgentProfileId
                : null);
  final controller = ChatController(
    api: ref.watch(chatRepositoryProvider),
    assistantRuntime: ref.watch(assistantRuntimeProvider),
    runTracker: ref.watch(chatRunTrackerProvider.notifier),
    scopedReadCache: _chatScopedReadCache(ref),
    scene: ChatScene.feedAi,
    aliasRepository: ref.watch(chatThreadAliasRepositoryProvider),
    admissionCoordinator: ref.watch(
      chatConversationAdmissionCoordinatorProvider,
    ),
    workspaceReady: () => _isReadyWorkspace(ref),
    conversationPurpose: conversationPurpose,
    agentScope: browseAllAgentProfiles
        ? const ChatAgentScope.allProfiles()
        : bindAgentProfileFromThread
        ? ChatAgentScope.threadBound(profileHint: initialAgentProfileId)
        : initialProfile == null
        ? null
        : ChatAgentScope.fixed(initialProfile),
    restoreRecentConversationOnCreate: restoreRecentConversationOnCreate,
    coalescedStreamingUi: _coalescedStreamingUi(ref),
    threadProgressPoller: _threadProgressPoller(ref),
    assistantProgress: ref.watch(assistantThreadProgressProvider),
  );
  return _bindConversationCacheLifecycle(ref, controller);
}

ChatController _bindConversationCacheLifecycle(
  Ref ref,
  ChatController controller,
) {
  ref.listen<AppVisibility>(
    appActivityCoordinatorProvider.select(
      (coordinator) => coordinator.state.visibility,
    ),
    (_, visibility) {
      if (visibility != AppVisibility.foreground) {
        controller.flushPendingConversationCache();
      }
    },
  );
  return controller;
}

final feedAiChatControllerProvider =
    ChangeNotifierProvider.autoDispose<ChatController>((ref) {
      return createFeedAiChatController(
        ref,
        restoreRecentConversationOnCreate: true,
      );
    });

ChatController createDeepPositioningChatController(
  Ref ref, {
  String? initialAgentProfileId,
  bool bindAgentProfileFromThread = false,
}) {
  final initialProfile = knownPublicChatAgentProfileId(initialAgentProfileId);
  final controller = ChatController(
    api: ref.watch(chatRepositoryProvider),
    assistantRuntime: ref.watch(assistantRuntimeProvider),
    runTracker: ref.watch(chatRunTrackerProvider.notifier),
    scopedReadCache: _chatScopedReadCache(ref),
    scene: ChatScene.feedAi,
    aliasRepository: ref.watch(chatThreadAliasRepositoryProvider),
    admissionCoordinator: ref.watch(
      chatConversationAdmissionCoordinatorProvider,
    ),
    workspaceReady: () => _isReadyWorkspace(ref),
    conversationPurpose: ChatConversationPurpose.deepPositioning,
    agentScope: bindAgentProfileFromThread
        ? ChatAgentScope.threadBound(profileHint: initialProfile)
        : initialProfile == null
        ? null
        : ChatAgentScope.fixed(initialProfile),
    coalescedStreamingUi: _coalescedStreamingUi(ref),
    threadProgressPoller: _threadProgressPoller(ref),
    assistantProgress: ref.watch(assistantThreadProgressProvider),
  );
  return _bindConversationCacheLifecycle(ref, controller);
}

final deepPositioningChatControllerProvider =
    ChangeNotifierProvider.autoDispose<ChatController>((ref) {
      return createDeepPositioningChatController(ref);
    });

ChatThreadProgressPoller _threadProgressPoller(Ref ref) =>
    ChatThreadProgressPoller(
      orchestrator: ref.read(taskOrchestratorProvider),
      activityMetrics: ref.read(runtimeActivityMetricsProvider),
    );

bool _isReadyWorkspace(Ref ref) {
  final state = ref.read(sessionStoreProvider).state;
  return state.authState == SessionAuthState.authenticated &&
      state.workspaceStatus == SessionWorkspaceStatus.ready &&
      state.workspace?.workspaceId?.trim().isNotEmpty == true;
}

bool _coalescedStreamingUi(Ref ref) => ref.watch(
  performanceFeatureFlagsProvider.select((flags) => flags.coalescedStreamingUi),
);

ScopedReadCache? _chatScopedReadCache(Ref ref) {
  final session = ref.read(sessionStoreProvider).state;
  final workspaceId = session.workspace?.workspaceId;
  final userScope = ref.read(authenticatedUserDataScopeProvider);
  if (session.authState != SessionAuthState.authenticated ||
      workspaceId == null ||
      workspaceId.trim().isEmpty ||
      userScope == 'anonymous') {
    return null;
  }
  return ScopedReadCache(
    dao: ref.read(appPreferencesDaoProvider),
    userScope: userScope,
    workspaceScope: workspaceId,
    fallbackTtl: ref.read(appCachePolicyProvider).cacheTtl,
  );
}
