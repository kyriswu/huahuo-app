import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../domain/desktop_chat_port.dart';
import '../domain/desktop_chat_recovery_models.dart';

export '../domain/desktop_chat_recovery_models.dart';

/// Account/workspace-scoped cache for public desktop Chat recovery state.
final class LocalDesktopChatRecoveryStore implements DesktopChatRecoveryStore {
  LocalDesktopChatRecoveryStore({
    Future<Directory> Function()? supportDirectory,
  }) : _supportDirectory = supportDirectory ?? getApplicationSupportDirectory;

  static const _schemaVersion = 1;
  final Future<Directory> Function() _supportDirectory;

  @override
  Future<DesktopChatSessionSnapshot> load({
    required String userId,
    required String workspaceId,
  }) async {
    final file = await _fileFor(userId: userId, workspaceId: workspaceId);
    try {
      if (!await file.exists()) return const DesktopChatSessionSnapshot.empty();
      final decoded = jsonDecode(await file.readAsString());
      final root = decoded is Map ? _asMap(decoded) : null;
      if (root == null || root['schemaVersion'] != _schemaVersion) {
        return const DesktopChatSessionSnapshot.empty();
      }
      return _decodeSnapshot(root) ?? const DesktopChatSessionSnapshot.empty();
    } on Object {
      return const DesktopChatSessionSnapshot.empty();
    }
  }

  @override
  Future<void> save({
    required String userId,
    required String workspaceId,
    required DesktopChatSessionSnapshot snapshot,
  }) async {
    final file = await _fileFor(userId: userId, workspaceId: workspaceId);
    final directory = file.parent;
    if (!await directory.exists()) await directory.create(recursive: true);
    final pending = File('${file.path}.part');
    if (await pending.exists()) await pending.delete();
    await pending.writeAsString(
      jsonEncode(<String, Object?>{
        'schemaVersion': _schemaVersion,
        ..._encodeSnapshot(snapshot),
      }),
      flush: true,
    );
    if (await file.exists()) await file.delete();
    await pending.rename(file.path);
  }

  @override
  Future<void> clear({
    required String userId,
    required String workspaceId,
  }) async {
    final file = await _fileFor(userId: userId, workspaceId: workspaceId);
    if (await file.exists()) await file.delete();
  }

  Future<File> _fileFor({
    required String userId,
    required String workspaceId,
  }) async {
    final normalizedUser = _safeIdentifier(userId);
    final normalizedWorkspace = _safeIdentifier(workspaceId);
    if (normalizedUser == null || normalizedWorkspace == null) {
      throw ArgumentError('Desktop Chat recovery scope is invalid');
    }
    final support = await _supportDirectory();
    final scope = base64Url
        .encode(utf8.encode('$normalizedUser|$normalizedWorkspace'))
        .replaceAll('=', '');
    return File(
      '${support.path}${Platform.pathSeparator}chat-recovery-$scope.json',
    );
  }
}

Map<String, Object?> _encodeSnapshot(DesktopChatSessionSnapshot snapshot) =>
    <String, Object?>{
      'activeThreadId': snapshot.activeThreadId,
      'threads': <Object?>[
        for (final thread in snapshot.threads) _encodeThread(thread),
      ],
      'messagesByThread': <String, Object?>{
        for (final entry in snapshot.messagesByThread.entries)
          entry.key: <Object?>[
            for (final message in entry.value) _encodeMessage(message),
          ],
      },
      'tasks': <Object?>[for (final task in snapshot.tasks) _encodeTask(task)],
    };

Map<String, Object?> _encodeThread(
  DesktopChatThread thread,
) => <String, Object?>{
  'threadId': thread.threadId,
  'title': thread.title,
  'updatedAt': thread.updatedAt?.toUtc().toIso8601String(),
  if (thread.agentProfileId != null) 'agentProfileId': thread.agentProfileId,
  'activeRuns': <Object?>[
    for (final run in thread.activeRuns)
      <String, Object?>{'agentRunId': run.agentRunId, 'status': run.status},
  ],
};

Map<String, Object?> _encodeMessage(DesktopChatMessage message) =>
    <String, Object?>{
      'messageId': message.messageId,
      'threadId': message.threadId,
      'role': message.role,
      'text': message.text,
      'imageAttachments': <Object?>[
        for (final attachment in message.imageAttachments)
          <String, Object?>{
            'resourceId': attachment.resourceId,
            if (attachment.displayName != null)
              'displayName': attachment.displayName,
            if (attachment.mimeType != null) 'mimeType': attachment.mimeType,
          },
      ],
    };

Map<String, Object?> _encodeTask(DesktopChatPendingTask task) =>
    <String, Object?>{
      'taskKey': task.taskKey,
      'lifecycle': task.lifecycle.wireValue,
      'createdAt': task.createdAt.toUtc().toIso8601String(),
      'updatedAt': task.updatedAt.toUtc().toIso8601String(),
      if (task.errorCode != null) 'errorCode': task.errorCode,
      'acceptedReply': _encodeReply(task.acceptedReply),
    };

Map<String, Object?> _encodeReply(DesktopChatReply reply) => <String, Object?>{
  'userMessage': _encodeMessage(reply.userMessage),
  if (reply.assistantMessage != null)
    'assistantMessage': _encodeMessage(reply.assistantMessage!),
  if (reply.taskId != null) 'taskId': reply.taskId,
  if (reply.agentRunId != null) 'agentRunId': reply.agentRunId,
  if (reply.completionMode != null) 'completionMode': reply.completionMode,
};

DesktopChatSessionSnapshot? _decodeSnapshot(Map<String, Object?> root) {
  final rawThreads = root['threads'];
  final rawMessages = root['messagesByThread'];
  final rawTasks = root['tasks'];
  if (rawThreads is! List || rawMessages is! Map || rawTasks is! List) {
    return null;
  }
  final threads = <DesktopChatThread>[];
  final threadIds = <String>{};
  for (final value in rawThreads) {
    final thread = _decodeThread(_asMap(value));
    if (thread == null || !threadIds.add(thread.threadId)) return null;
    threads.add(thread);
  }
  final messagesByThread = <String, List<DesktopChatMessage>>{};
  for (final entry in rawMessages.entries) {
    final threadId = _safeIdentifier(entry.key);
    final messages = entry.value;
    if (threadId == null ||
        messages is! List ||
        !threadIds.contains(threadId)) {
      return null;
    }
    final decoded = <DesktopChatMessage>[];
    final messageIds = <String>{};
    for (final value in messages) {
      final message = _decodeMessage(_asMap(value), threadId);
      if (message == null || !messageIds.add(message.messageId)) return null;
      decoded.add(message);
    }
    messagesByThread[threadId] = decoded;
  }
  final tasks = <DesktopChatPendingTask>[];
  final taskKeys = <String>{};
  for (final value in rawTasks) {
    final task = _decodeTask(_asMap(value));
    if (task == null || !taskKeys.add(task.taskKey)) return null;
    if (!threadIds.contains(task.threadId)) return null;
    tasks.add(task);
  }
  final activeThreadId = root['activeThreadId'] == null
      ? null
      : _safeIdentifier(root['activeThreadId']);
  if (root['activeThreadId'] != null &&
      (activeThreadId == null || !threadIds.contains(activeThreadId))) {
    return null;
  }
  return DesktopChatSessionSnapshot(
    threads: threads,
    messagesByThread: messagesByThread,
    activeThreadId: activeThreadId,
    tasks: tasks,
  );
}

DesktopChatThread? _decodeThread(Map<String, Object?>? value) {
  if (value == null) return null;
  final threadId = _safeIdentifier(value['threadId']);
  final title = _safeText(value['title'], maximum: 240);
  if (threadId == null || title == null) return null;
  final rawUpdatedAt = value['updatedAt'];
  final updatedAt = rawUpdatedAt == null
      ? null
      : DateTime.tryParse(rawUpdatedAt.toString())?.toUtc();
  if (rawUpdatedAt != null && updatedAt == null) return null;
  final agentProfileId = value['agentProfileId'] == null
      ? null
      : _safeIdentifier(value['agentProfileId']);
  if (value['agentProfileId'] != null && agentProfileId == null) return null;
  final rawRuns = value['activeRuns'];
  if (rawRuns != null && rawRuns is! List) return null;
  final runValues = rawRuns is List ? rawRuns : const <Object?>[];
  final runs = <DesktopChatActiveRun>[];
  final runIds = <String>{};
  for (final raw in runValues) {
    final run = _asMap(raw);
    final runId = _safeIdentifier(run?['agentRunId']);
    final status = _safeTaskStatus(run?['status']);
    if (runId == null || status == null || !runIds.add(runId)) return null;
    runs.add(DesktopChatActiveRun(agentRunId: runId, status: status));
  }
  return DesktopChatThread(
    threadId: threadId,
    title: title,
    updatedAt: updatedAt,
    agentProfileId: agentProfileId,
    activeRuns: runs,
  );
}

DesktopChatMessage? _decodeMessage(
  Map<String, Object?>? value,
  String expectedThreadId,
) {
  if (value == null) return null;
  final messageId = _safeIdentifier(value['messageId']);
  final threadId = _safeIdentifier(value['threadId']);
  final role = value['role'];
  final text = _safeMessageText(value['text']);
  final images = _decodeImageAttachments(value['imageAttachments']);
  if (messageId == null ||
      threadId == null ||
      threadId != expectedThreadId ||
      role is! String ||
      !const <String>{'user', 'assistant', 'system'}.contains(role) ||
      text == null ||
      images == null ||
      (text.trim().isEmpty && images.isEmpty)) {
    return null;
  }
  return DesktopChatMessage(
    messageId: messageId,
    threadId: threadId,
    role: role,
    text: text,
    imageAttachments: images,
  );
}

List<DesktopChatImageAttachment>? _decodeImageAttachments(Object? value) {
  if (value == null) return const <DesktopChatImageAttachment>[];
  if (value is! List) return null;
  final attachments = <DesktopChatImageAttachment>[];
  final resourceIds = <String>{};
  for (final raw in value) {
    final entry = _asMap(raw);
    final resourceId = _safeIdentifier(entry?['resourceId']);
    final displayName = entry?['displayName'] == null
        ? null
        : _safeImageDisplayName(entry?['displayName']);
    final mimeType = entry?['mimeType'] == null
        ? null
        : _safeImageMime(entry?['mimeType']);
    if (entry == null ||
        resourceId == null ||
        !resourceIds.add(resourceId) ||
        (entry.containsKey('displayName') && displayName == null) ||
        (entry.containsKey('mimeType') && mimeType == null)) {
      return null;
    }
    attachments.add(
      DesktopChatImageAttachment(
        resourceId: resourceId,
        displayName: displayName,
        mimeType: mimeType,
      ),
    );
  }
  return List<DesktopChatImageAttachment>.unmodifiable(attachments);
}

DesktopChatPendingTask? _decodeTask(Map<String, Object?>? value) {
  if (value == null) return null;
  final taskKey = _safeIdentifier(value['taskKey']);
  final lifecycle = DesktopChatTaskLifecycle.tryParse(value['lifecycle']);
  final createdAt = DateTime.tryParse(
    value['createdAt']?.toString() ?? '',
  )?.toUtc();
  final updatedAt = DateTime.tryParse(
    value['updatedAt']?.toString() ?? '',
  )?.toUtc();
  final acceptedReply = _decodeReply(_asMap(value['acceptedReply']));
  final errorCode = value['errorCode'] == null
      ? null
      : _safeText(value['errorCode'], maximum: 160);
  if (taskKey == null ||
      lifecycle == null ||
      createdAt == null ||
      updatedAt == null ||
      acceptedReply == null ||
      (value['errorCode'] != null && errorCode == null)) {
    return null;
  }
  return DesktopChatPendingTask(
    taskKey: taskKey,
    acceptedReply: acceptedReply,
    lifecycle: lifecycle,
    createdAt: createdAt,
    updatedAt: updatedAt,
    errorCode: errorCode,
  );
}

DesktopChatReply? _decodeReply(Map<String, Object?>? value) {
  if (value == null) return null;
  final user = _decodeMessage(
    _asMap(value['userMessage']),
    _safeIdentifier(_asMap(value['userMessage'])?['threadId']) ?? '',
  );
  if (user == null || user.role != 'user') return null;
  final assistantRaw = value['assistantMessage'];
  final assistant = assistantRaw == null
      ? null
      : _decodeMessage(_asMap(assistantRaw), user.threadId);
  if (assistantRaw != null &&
      (assistant == null || assistant.role != 'assistant')) {
    return null;
  }
  final taskId = value['taskId'] == null
      ? null
      : _safeIdentifier(value['taskId']);
  final agentRunId = value['agentRunId'] == null
      ? null
      : _safeIdentifier(value['agentRunId']);
  final completionMode = value['completionMode'];
  if ((value['taskId'] != null && taskId == null) ||
      (value['agentRunId'] != null && agentRunId == null) ||
      (completionMode != null &&
          (completionMode is! String || completionMode.length > 64))) {
    return null;
  }
  return DesktopChatReply(
    userMessage: user,
    assistantMessage: assistant,
    taskId: taskId,
    agentRunId: agentRunId,
    completionMode: completionMode as String?,
  );
}

Map<String, Object?>? _asMap(Object? value) {
  if (value is! Map) return null;
  final map = <String, Object?>{};
  for (final entry in value.entries) {
    if (entry.key is! String) return null;
    map[entry.key as String] = entry.value;
  }
  return map;
}

String? _safeIdentifier(Object? value) {
  final text = value is String ? value.trim() : null;
  if (text == null || !_safeId.hasMatch(text)) return null;
  return text;
}

String? _safeText(Object? value, {required int maximum}) {
  final text = value is String ? value : null;
  if (text == null || text.trim().isEmpty || text.length > maximum) return null;
  return text;
}

String? _safeMessageText(Object? value) {
  final text = value is String ? value : null;
  if (text == null || text.length > 120000) return null;
  return text;
}

String? _safeImageMime(Object? value) {
  final mime = value is String ? value.trim().toLowerCase() : null;
  return const <String>{
        'image/png',
        'image/jpeg',
        'image/jpg',
        'image/gif',
        'image/webp',
      }.contains(mime)
      ? mime
      : null;
}

String? _safeImageDisplayName(Object? value) {
  if (value is! String) return null;
  final name = value.trim();
  if (name.isEmpty ||
      name.length > 160 ||
      name.contains('/') ||
      name.contains('\\') ||
      name.contains('..') ||
      name.codeUnits.any((unit) => unit < 32)) {
    return null;
  }
  return name;
}

String? _safeTaskStatus(Object? value) {
  final text = value is String ? value.trim() : null;
  if (text == null || text.isEmpty || text.length > 64) return null;
  return text;
}

final _safeId = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$');
