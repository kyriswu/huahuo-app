import 'dart:convert';

import 'package:huahuo_api/huahuo_api.dart';

import '../../../shared/services/desktop_service_result.dart';
import '../domain/desktop_chat_port.dart';

final class DesktopCreatedChatNote {
  const DesktopCreatedChatNote({
    required this.noteId,
    required this.title,
    required this.note,
  });

  final String noteId;
  final String title;
  final SharedHNote note;
}

abstract interface class DesktopChatNoteCreator {
  Future<DesktopServiceResult<DesktopCreatedChatNote>> create({
    required String workspaceId,
    required DesktopChatMessage assistantMessage,
  });
}

final class UnavailableDesktopChatNoteCreator
    implements DesktopChatNoteCreator {
  const UnavailableDesktopChatNoteCreator();

  @override
  Future<DesktopServiceResult<DesktopCreatedChatNote>> create({
    required String workspaceId,
    required DesktopChatMessage assistantMessage,
  }) async => const DesktopServiceResult<DesktopCreatedChatNote>.unavailable(
    code: 'DESKTOP_CHAT_NOTE_UNAVAILABLE',
    message: '当前未配置创建资产服务',
  );
}

/// Creates the formal HNote directly so generated Resource references remain
/// atomic. The existing Chat-excerpt API cannot carry those references.
final class RemoteDesktopChatNoteCreator implements DesktopChatNoteCreator {
  RemoteDesktopChatNoteCreator(ApiClient apiClient)
    : _workspace = WorkspaceContentClient(apiClient);

  final WorkspaceContentClient _workspace;
  final Map<String, Future<DesktopServiceResult<DesktopCreatedChatNote>>>
  _inflight = <String, Future<DesktopServiceResult<DesktopCreatedChatNote>>>{};

  @override
  Future<DesktopServiceResult<DesktopCreatedChatNote>> create({
    required String workspaceId,
    required DesktopChatMessage assistantMessage,
  }) {
    final messageId = assistantMessage.messageId.trim();
    final workspace = workspaceId.trim();
    if (!_safeIdentifier.hasMatch(workspace) ||
        !_safeIdentifier.hasMatch(messageId) ||
        assistantMessage.role != 'assistant') {
      return Future<DesktopServiceResult<DesktopCreatedChatNote>>.value(
        const DesktopServiceResult<DesktopCreatedChatNote>.failure(
          code: 'DESKTOP_CHAT_NOTE_INPUT_INVALID',
          message: '当前回复不能创建为资产',
        ),
      );
    }
    final existing = _inflight[messageId];
    if (existing != null) return existing;
    final operation = _create(
      workspaceId: workspace,
      assistantMessage: assistantMessage,
    );
    _inflight[messageId] = operation;
    operation.whenComplete(() {
      if (_inflight[messageId] == operation) _inflight.remove(messageId);
    }).ignore();
    return operation;
  }

  Future<DesktopServiceResult<DesktopCreatedChatNote>> _create({
    required String workspaceId,
    required DesktopChatMessage assistantMessage,
  }) async {
    final resources = _resourceReferences(assistantMessage);
    if (resources == null) {
      return const DesktopServiceResult<DesktopCreatedChatNote>.failure(
        code: 'DESKTOP_CHAT_NOTE_IMAGE_REFERENCE_INVALID',
        message: '回复中的图片资源无效，未创建资产',
      );
    }
    final title = desktopChatNoteTitle(assistantMessage.text);
    try {
      final created = await _workspace.createNote(
        workspaceId,
        title: title,
        rawMarkdown: assistantMessage.text,
        outlineMarkdown: '',
        germinationMarkdown: '',
        resourceRefs: resources,
        idempotencyKey: _idempotencyKey(assistantMessage.messageId),
      );
      if (!created.ok || created.data == null) {
        return DesktopServiceResult<DesktopCreatedChatNote>.failure(
          code: created.error?.code ?? 'DESKTOP_CHAT_NOTE_CREATE_FAILED',
          message: created.error?.message ?? '创建资产失败',
          retryable: created.error?.isRetryable ?? false,
        );
      }
      final note = await _workspace.note(workspaceId, created.data!.noteId);
      if (!note.ok || note.data == null) {
        return DesktopServiceResult<DesktopCreatedChatNote>.failure(
          code: note.error?.code ?? 'DESKTOP_CHAT_NOTE_READBACK_FAILED',
          message: note.error?.message ?? '资产已提交，但读取结果失败',
          retryable: note.error?.isRetryable ?? true,
        );
      }
      return DesktopServiceResult<DesktopCreatedChatNote>.success(
        DesktopCreatedChatNote(
          noteId: note.data!.noteId,
          title: note.data!.title,
          note: note.data!,
        ),
      );
    } on ArgumentError {
      return const DesktopServiceResult<DesktopCreatedChatNote>.failure(
        code: 'DESKTOP_CHAT_NOTE_REQUEST_INVALID',
        message: '创建资产请求无效',
      );
    } on FormatException {
      return const DesktopServiceResult<DesktopCreatedChatNote>.failure(
        code: 'DESKTOP_CHAT_NOTE_RESPONSE_INVALID',
        message: '资产服务返回的数据无效',
      );
    } on Object {
      return const DesktopServiceResult<DesktopCreatedChatNote>.failure(
        code: 'DESKTOP_CHAT_NOTE_CREATE_FAILED',
        message: '创建资产失败',
        retryable: true,
      );
    }
  }

  List<SharedHNoteResourceInput>? _resourceReferences(
    DesktopChatMessage message,
  ) {
    final unique = <String>{};
    final refs = <SharedHNoteResourceInput>[];
    for (final attachment in message.imageAttachments) {
      final resourceId = attachment.resourceId.trim();
      if (!_safeIdentifier.hasMatch(resourceId) || !unique.add(resourceId)) {
        if (!_safeIdentifier.hasMatch(resourceId)) return null;
        continue;
      }
      try {
        refs.add(
          SharedHNoteResourceInput(
            resourceId: resourceId,
            usage: 'inline_image',
            anchor: 'assistant-image-${refs.length + 1}',
            alt: _safeAlt(attachment.displayName),
          ),
        );
      } on ArgumentError {
        return null;
      }
    }
    return List<SharedHNoteResourceInput>.unmodifiable(refs);
  }
}

String desktopChatNoteTitle(String markdown) {
  for (final raw in markdown.split(RegExp(r'\r?\n'))) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    final heading = RegExp(r'^#{1,6}\s+(.+?)\s*#*$').firstMatch(line);
    final title = (heading?.group(1) ?? line)
        .replaceAll(RegExp(r'^[*_`\[\]()>.\-\s]+'), '')
        .replaceAll(RegExp(r'[*_`]+$'), '')
        .trim();
    if (title.isNotEmpty) return _truncateRunes(title, 80);
  }
  return 'AI 回复';
}

String _idempotencyKey(String messageId) =>
    'desktop-chat-note-${base64Url.encode(utf8.encode(messageId)).replaceAll('=', '')}';

String? _safeAlt(String? value) {
  final trimmed = value?.trim();
  if (trimmed == null ||
      trimmed.isEmpty ||
      trimmed.contains('/') ||
      trimmed.contains('\\') ||
      trimmed.contains('..') ||
      trimmed.codeUnits.any((unit) => unit < 32)) {
    return null;
  }
  return _truncateRunes(trimmed, 160);
}

String _truncateRunes(String value, int maximum) {
  final runes = value.runes.toList(growable: false);
  return runes.length <= maximum
      ? value
      : String.fromCharCodes(runes.take(maximum));
}

final _safeIdentifier = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$');
