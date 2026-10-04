import 'dart:async';
import 'dart:convert';

import 'package:huahuo_api/huahuo_api.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/di/diagnostics_providers.dart';
import '../../../app/bootstrap/app_providers.dart';
import '../../../core/database/diagnostic_log_dao.dart';
import '../../../core/diagnostics/diagnostic_logger.dart';
import '../../ui_v3/application/knowledge_library_controller.dart';
import '../../ui_v3/application/knowledge_note_port.dart';
import '../../ui_v3/domain/feed_item_models.dart';
import '../domain/chat_models.dart';

enum ChatAssistantNoteCreateStatus { success, unavailable, failure }

final class ChatAssistantNoteCreateResult {
  const ChatAssistantNoteCreateResult._({
    required this.status,
    this.note,
    this.errorCode,
  });

  const ChatAssistantNoteCreateResult.success(V3FeedItem note)
    : this._(status: ChatAssistantNoteCreateStatus.success, note: note);

  const ChatAssistantNoteCreateResult.unavailable(String errorCode)
    : this._(
        status: ChatAssistantNoteCreateStatus.unavailable,
        errorCode: errorCode,
      );

  const ChatAssistantNoteCreateResult.failure(String errorCode)
    : this._(
        status: ChatAssistantNoteCreateStatus.failure,
        errorCode: errorCode,
      );

  final ChatAssistantNoteCreateStatus status;
  final V3FeedItem? note;
  final String? errorCode;

  bool get isSuccess => status == ChatAssistantNoteCreateStatus.success;
}

// resident-provider: Preserves the chat assistant note creator dependency identity across route changes.
final chatAssistantNoteCreatorProvider = Provider<ChatAssistantNoteCreator>((
  ref,
) {
  return ChatAssistantNoteCreator(
    client: WorkspaceContentClient(ref.watch(apiClientProvider)),
    workspaceId: () =>
        ref.read(sessionStoreProvider).state.workspace?.workspaceId,
    library: ref.read(knowledgeLibraryControllerProvider),
    diagnosticLogger: ref.watch(diagnosticLoggerProvider),
  );
});

/// Converts a durable Assistant projection into one formal HNote. The server
/// validates all Resource ownership atomically, so this class never retries by
/// silently dropping generated images.
final class ChatAssistantNoteCreator {
  ChatAssistantNoteCreator({
    required WorkspaceContentClient client,
    required String? Function() workspaceId,
    required KnowledgeLibraryController library,
    DiagnosticLogger? diagnosticLogger,
  }) : _client = client,
       _workspaceId = workspaceId,
       _library = library,
       _diagnosticLogger = diagnosticLogger;

  final WorkspaceContentClient _client;
  final String? Function() _workspaceId;
  final KnowledgeLibraryController _library;
  final DiagnosticLogger? _diagnosticLogger;
  final Map<String, Future<ChatAssistantNoteCreateResult>> _inFlight =
      <String, Future<ChatAssistantNoteCreateResult>>{};

  Future<ChatAssistantNoteCreateResult> create(
    ChatMessage message, {
    String? folderId,
  }) {
    final messageId = message.messageId.trim();
    if (message.role != ChatMessageRole.assistant ||
        message.localDelivery != ChatLocalDeliveryState.server ||
        messageId.isEmpty) {
      return Future<ChatAssistantNoteCreateResult>.value(
        _failure('CHAT_ASSISTANT_MESSAGE_INVALID'),
      );
    }
    final normalizedFolderId = folderId?.trim();
    final existing = _inFlight[messageId];
    if (existing != null) return existing;
    final operation = _create(
      message,
      folderId: normalizedFolderId == null || normalizedFolderId.isEmpty
          ? null
          : normalizedFolderId,
    );
    _inFlight[messageId] = operation;
    unawaited(operation.whenComplete(() => _inFlight.remove(messageId)));
    return operation;
  }

  Future<ChatAssistantNoteCreateResult> _create(
    ChatMessage message, {
    required String? folderId,
  }) async {
    final workspaceId = _workspaceId()?.trim();
    if (workspaceId == null || workspaceId.isEmpty) {
      return _unavailable('WORKSPACE_CONTEXT_UNAVAILABLE');
    }
    final resourceRefs = _resourceRefs(message);
    if (resourceRefs == null) {
      return _failure('CHAT_ASSISTANT_IMAGE_REFERENCE_INVALID');
    }
    final markdown = message.visibleText ?? '';
    final title = titleForAssistantMarkdown(markdown);
    final idempotencyKey = _idempotencyKey(message.messageId);
    try {
      final created = await _client.createNote(
        workspaceId,
        title: title,
        folderId: folderId,
        rawMarkdown: markdown,
        outlineMarkdown: '',
        germinationMarkdown: '',
        resourceRefs: resourceRefs,
        idempotencyKey: idempotencyKey,
      );
      if (!created.ok || created.data == null) {
        return _failure(
          created.error?.code ?? 'CHAT_ASSISTANT_NOTE_CREATE_FAILED',
          fallback: 'CHAT_ASSISTANT_NOTE_CREATE_FAILED',
        );
      }
      final receipt = created.data!;
      final detail = await _client.note(workspaceId, receipt.noteId);
      if (!detail.ok || detail.data == null) {
        return _failure(
          detail.error?.code ?? 'CHAT_ASSISTANT_NOTE_READBACK_FAILED',
          fallback: 'CHAT_ASSISTANT_NOTE_READBACK_FAILED',
        );
      }
      final complete = await _hydrateCanonicalNote(workspaceId, detail.data!);
      final remote = mapRemoteHNoteToFeedItem(
        complete,
        localId: receipt.noteId,
        legacyRemoteRevision: 0,
      );
      final createdNote = _library.mergeRemoteNote(remote);
      return ChatAssistantNoteCreateResult.success(
        _library.noteForId(createdNote.id) ?? createdNote,
      );
    } on _AssistantNoteReadbackFailure catch (failure) {
      return _failure(
        failure.code,
        fallback: 'CHAT_ASSISTANT_NOTE_READBACK_FAILED',
      );
    } on ArgumentError {
      return _failure('CHAT_ASSISTANT_NOTE_REQUEST_INVALID');
    } on FormatException {
      return _failure('CHAT_ASSISTANT_NOTE_RESPONSE_INVALID');
    } on Object {
      return _failure('CHAT_ASSISTANT_NOTE_CREATE_FAILED');
    }
  }

  Future<SharedHNote> _hydrateCanonicalNote(
    String workspaceId,
    SharedHNote note,
  ) {
    return hydrateWorkspaceHNoteParts(
      note,
      readPart:
          ({
            required String noteId,
            required String part,
            required String partRevisionId,
          }) async {
            final response = await _client.notePart(
              workspaceId,
              noteId,
              part,
              partRevisionId: partRevisionId,
            );
            final view = response.data;
            if (!response.ok || view == null) {
              throw _AssistantNoteReadbackFailure(
                response.error?.code ?? 'CHAT_ASSISTANT_NOTE_READBACK_FAILED',
              );
            }
            return view;
          },
    );
  }

  ChatAssistantNoteCreateResult _unavailable(String errorCode) {
    final safeCode = _safeAssistantAssetErrorCode(
      errorCode,
      fallback: 'CHAT_ASSISTANT_NOTE_UNAVAILABLE',
    );
    _logFailure(safeCode, severity: DiagnosticSeverity.warning);
    return ChatAssistantNoteCreateResult.unavailable(safeCode);
  }

  ChatAssistantNoteCreateResult _failure(
    String errorCode, {
    String fallback = 'CHAT_ASSISTANT_NOTE_CREATE_FAILED',
  }) {
    final safeCode = _safeAssistantAssetErrorCode(
      errorCode,
      fallback: fallback,
    );
    _logFailure(safeCode, severity: DiagnosticSeverity.error);
    return ChatAssistantNoteCreateResult.failure(safeCode);
  }

  void _logFailure(String errorCode, {required DiagnosticSeverity severity}) {
    try {
      _diagnosticLogger?.log(
        DiagnosticLogInput(
          category: DiagnosticCategory.assets,
          severity: severity,
          safeSummary: 'Assistant reply asset creation failed',
          metadata: <String, Object?>{'errorCode': errorCode},
        ),
      );
    } on Object {
      // Diagnostics must not change a formal HNote mutation outcome.
    }
  }

  List<SharedHNoteResourceInput>? _resourceRefs(ChatMessage message) {
    final unique = <String>{};
    final refs = <SharedHNoteResourceInput>[];
    for (var index = 0; index < message.imageAttachments.length; index += 1) {
      final attachment = message.imageAttachments[index];
      final resourceId = attachment.resourceId.trim();
      if (resourceId.isEmpty) return null;
      if (!unique.add(resourceId)) continue;
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

final class _AssistantNoteReadbackFailure implements Exception {
  const _AssistantNoteReadbackFailure(this.code);

  final String code;
}

String _safeAssistantAssetErrorCode(String value, {required String fallback}) {
  final code = value.trim();
  return RegExp(r'^[A-Z][A-Z0-9_]{2,79}$').hasMatch(code) ? code : fallback;
}

String titleForAssistantMarkdown(String markdown) {
  for (final source in markdown.split(RegExp(r'\r?\n'))) {
    final line = source.trim();
    if (line.isEmpty) continue;
    final heading = RegExp(r'^#{1,6}\s+(.+?)\s*#*$').firstMatch(line);
    final title = (heading?.group(1) ?? line)
        .replaceAll(RegExp(r'^[*_`\[\]()>\-\s]+'), '')
        .replaceAll(RegExp(r'[*_`]+$'), '')
        .trim();
    if (title.isEmpty) continue;
    return _truncateRunes(title, 80);
  }
  return 'AI 回复';
}

String _idempotencyKey(String messageId) {
  final digest = sha256.convert(utf8.encode(messageId.trim())).toString();
  return 'chat-assistant-note-${digest.substring(0, 48)}';
}

String? _safeAlt(String? value) {
  final trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;
  return _truncateRunes(trimmed, 160);
}

String _truncateRunes(String value, int maximum) {
  final runes = value.runes.toList(growable: false);
  if (runes.length <= maximum) return value;
  return String.fromCharCodes(runes.take(maximum));
}
