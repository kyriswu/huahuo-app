import '../../../shared/services/desktop_service_result.dart';

final class DesktopRawNoteCreateRequest {
  const DesktopRawNoteCreateRequest({
    required this.workspaceId,
    required this.title,
    required this.rawMarkdown,
    required this.idempotencyKey,
  });

  final String workspaceId;
  final String title;
  final String rawMarkdown;
  final String idempotencyKey;
}

final class DesktopCreatedRawNote {
  const DesktopCreatedRawNote({
    required this.noteId,
    required this.title,
    required this.rawMarkdown,
  });

  final String noteId;
  final String title;
  final String rawMarkdown;
}

/// Creates a canonical raw HNote from a short desktop text capture.
abstract interface class DesktopRawNoteCreator {
  Future<DesktopServiceResult<DesktopCreatedRawNote>> createRawNote(
    DesktopRawNoteCreateRequest request,
  );
}

final class UnavailableDesktopRawNoteCreator implements DesktopRawNoteCreator {
  const UnavailableDesktopRawNoteCreator();

  @override
  Future<DesktopServiceResult<DesktopCreatedRawNote>> createRawNote(
    DesktopRawNoteCreateRequest request,
  ) async => const DesktopServiceResult<DesktopCreatedRawNote>.unavailable(
    code: 'DESKTOP_RAW_NOTE_UNAVAILABLE',
    message: '文字资产服务暂不可用',
  );
}
