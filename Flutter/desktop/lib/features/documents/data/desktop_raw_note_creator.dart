import 'dart:convert';

import 'package:huahuo_api/huahuo_api.dart';

import '../../../shared/services/desktop_service_result.dart';
import '../domain/desktop_raw_note_creator.dart';

/// Writes a short, user-authored capture as a raw HNote, then reads back the
/// server-owned representation before reporting success to the desktop UI.
final class RemoteDesktopRawNoteCreator implements DesktopRawNoteCreator {
  RemoteDesktopRawNoteCreator(ApiClient apiClient)
    : _workspace = WorkspaceContentClient(apiClient);

  static const _maximumBytes = 1024 * 1024;

  final WorkspaceContentClient _workspace;

  @override
  Future<DesktopServiceResult<DesktopCreatedRawNote>> createRawNote(
    DesktopRawNoteCreateRequest request,
  ) async {
    final workspaceId = request.workspaceId.trim();
    final title = request.title.trim();
    final rawMarkdown = request.rawMarkdown;
    final idempotencyKey = request.idempotencyKey.trim();
    if (!_identifier.hasMatch(workspaceId) ||
        !_isSafeTitle(title) ||
        rawMarkdown.trim().isEmpty ||
        utf8.encode(rawMarkdown).length > _maximumBytes ||
        !_idempotencyKey.hasMatch(idempotencyKey)) {
      return const DesktopServiceResult<DesktopCreatedRawNote>.failure(
        code: 'DESKTOP_RAW_NOTE_INPUT_INVALID',
        message: '文字资产内容或请求标识无效',
      );
    }
    try {
      final created = await _workspace.createNote(
        workspaceId,
        title: title,
        rawMarkdown: rawMarkdown,
        outlineMarkdown: '',
        germinationMarkdown: '',
        idempotencyKey: idempotencyKey,
      );
      if (!created.ok || created.data == null) {
        return _failure(
          created.error,
          fallbackCode: 'DESKTOP_RAW_NOTE_CREATE_FAILED',
          fallbackMessage: '保存文字资产失败',
        );
      }
      final readback = await _workspace.note(workspaceId, created.data!.noteId);
      if (!readback.ok || readback.data == null) {
        return _failure(
          readback.error,
          fallbackCode: 'DESKTOP_RAW_NOTE_READBACK_FAILED',
          fallbackMessage: '文字资产已保存，但暂时无法读取',
        );
      }
      final note = readback.data!;
      if (note.noteId != created.data!.noteId) {
        return const DesktopServiceResult<DesktopCreatedRawNote>.failure(
          code: 'DESKTOP_RAW_NOTE_READBACK_MISMATCH',
          message: '文字资产读取结果不匹配',
          retryable: true,
        );
      }
      return DesktopServiceResult<DesktopCreatedRawNote>.success(
        DesktopCreatedRawNote(
          noteId: note.noteId,
          title: note.title,
          rawMarkdown: note.raw.markdown,
        ),
      );
    } on ArgumentError {
      return const DesktopServiceResult<DesktopCreatedRawNote>.failure(
        code: 'DESKTOP_RAW_NOTE_REQUEST_INVALID',
        message: '文字资产请求无效',
      );
    } on FormatException {
      return const DesktopServiceResult<DesktopCreatedRawNote>.failure(
        code: 'DESKTOP_RAW_NOTE_RESPONSE_INVALID',
        message: '文字资产服务返回的数据无效',
      );
    } on Object {
      return const DesktopServiceResult<DesktopCreatedRawNote>.failure(
        code: 'DESKTOP_RAW_NOTE_CREATE_FAILED',
        message: '保存文字资产失败，请稍后重试',
        retryable: true,
      );
    }
  }
}

DesktopServiceResult<DesktopCreatedRawNote> _failure(
  AppFailure? failure, {
  required String fallbackCode,
  required String fallbackMessage,
}) => DesktopServiceResult<DesktopCreatedRawNote>.failure(
  code: failure?.code ?? fallbackCode,
  message: _safeMessage(failure?.message) ?? fallbackMessage,
  retryable: failure?.isRetryable ?? true,
);

bool _isSafeTitle(String value) =>
    value.isNotEmpty &&
    value.runes.length <= 80 &&
    !value.runes.any(_isControl);

String? _safeMessage(Object? value) {
  if (value is! String) return null;
  final text = value.trim();
  return text.isEmpty || text.runes.length > 280 || text.runes.any(_isControl)
      ? null
      : text;
}

bool _isControl(int rune) => rune <= 0x1f || (rune >= 0x7f && rune <= 0x9f);

final _identifier = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$');
final _idempotencyKey = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,255}$');
