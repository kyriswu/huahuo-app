import '../../../shared/services/desktop_service_result.dart';

final class DesktopChatThread {
  const DesktopChatThread({
    required this.threadId,
    required this.title,
    this.updatedAt,
    this.agentProfileId,
    this.activeRuns = const <DesktopChatActiveRun>[],
  });

  final String threadId;
  final String title;
  final DateTime? updatedAt;
  final String? agentProfileId;
  final List<DesktopChatActiveRun> activeRuns;
}

final class DesktopChatActiveRun {
  const DesktopChatActiveRun({required this.agentRunId, required this.status});

  final String agentRunId;
  final String status;

  bool get isTerminal => const <String>{
    'succeeded',
    'failed',
    'timeout',
    'cancelled',
    'orphaned',
  }.contains(status);
}

final class DesktopChatMessage {
  const DesktopChatMessage({
    required this.messageId,
    required this.threadId,
    required this.role,
    required this.text,
    this.imageAttachments = const <DesktopChatImageAttachment>[],
  });

  final String messageId;
  final String threadId;
  final String role;
  final String text;
  final List<DesktopChatImageAttachment> imageAttachments;
}

/// Public image Resource metadata from a durable Chat projection. The image
/// bytes and transient playback address are resolved separately by the scoped
/// cache so this model stays safe to persist with a conversation.
final class DesktopChatImageAttachment {
  const DesktopChatImageAttachment({
    required this.resourceId,
    this.displayName,
    this.mimeType,
  });

  final String resourceId;
  final String? displayName;
  final String? mimeType;
}

final class DesktopChatThreadPage {
  const DesktopChatThreadPage({required this.items, this.nextCursor});

  final List<DesktopChatThread> items;
  final String? nextCursor;
}

final class DesktopChatThreadDetail {
  const DesktopChatThreadDetail({required this.thread, required this.messages});

  final DesktopChatThread thread;
  final List<DesktopChatMessage> messages;
}

final class DesktopChatReply {
  const DesktopChatReply({
    required this.userMessage,
    this.assistantMessage,
    this.taskId,
    this.agentRunId,
    this.completionMode,
  });

  final DesktopChatMessage userMessage;
  final DesktopChatMessage? assistantMessage;
  final String? taskId;
  final String? agentRunId;
  final String? completionMode;
}

final class DesktopChatContextReference {
  DesktopChatContextReference.workspaceDocument({
    required this.ownerId,
    required this.part,
    required this.partRevisionId,
  }) : resourceType = null,
       resourceId = null {
    if (!_safeIdentifier.hasMatch(ownerId!) ||
        !_safeIdentifier.hasMatch(partRevisionId!) ||
        (part != 'raw' && part != 'outline' && part != 'germination')) {
      throw ArgumentError('Invalid Desktop chat context reference');
    }
  }

  DesktopChatContextReference.resource({
    required this.resourceType,
    required this.resourceId,
  }) : ownerId = null,
       part = null,
       partRevisionId = null {
    if ((resourceType != 'image' && resourceType != 'file') ||
        !_safeIdentifier.hasMatch(resourceId!)) {
      throw ArgumentError('Invalid Desktop chat resource reference');
    }
  }

  static final _safeIdentifier = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$');

  final String? ownerId;
  final String? part;
  final String? partRevisionId;
  final String? resourceType;
  final String? resourceId;

  String get identity => ownerId == null
      ? 'resource:$resourceType:$resourceId'
      : 'workspace:$ownerId:$part:$partRevisionId';
}

abstract interface class DesktopChatPort {
  Future<DesktopServiceResult<DesktopChatThreadPage>> listThreads({
    String? cursor,
    int limit = 30,
  });

  Future<DesktopServiceResult<DesktopChatThread>> createThread();

  Future<DesktopServiceResult<DesktopChatThreadDetail>> getThreadDetail(
    String threadId,
  );

  Future<DesktopServiceResult<DesktopChatReply>> sendText({
    required String threadId,
    required String content,
    String? agentProfileId,
    Iterable<DesktopChatContextReference> references =
        const <DesktopChatContextReference>[],
  });
}

/// Optional production capability for submitting a public Chat turn without
/// tying its Agent Run lifetime to the current page.
abstract interface class DesktopChatAsyncSubmissionPort {
  Future<DesktopServiceResult<DesktopChatReply>> sendAcceptedText({
    required String threadId,
    required String content,
    String? agentProfileId,
    Iterable<DesktopChatContextReference> references =
        const <DesktopChatContextReference>[],
  });
}

/// Optional production capability for resolving an already accepted public
/// Chat Run/task binding in a foreground task tracker.
abstract interface class DesktopChatTaskResolutionPort {
  Future<DesktopServiceResult<DesktopChatReply>> resolveAcceptedReply(
    DesktopChatReply accepted,
  );
}

abstract interface class DesktopDemoChatPort implements DesktopChatPort {}
