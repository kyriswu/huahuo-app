import 'dart:typed_data';

import 'package:huahuo_api/huahuo_api.dart';

import '../../../shared/services/desktop_service_result.dart';
import '../domain/desktop_book_work_port.dart';

final class RemoteDesktopBookWorkPort implements DesktopBookWorkPort {
  RemoteDesktopBookWorkPort(ApiClient api) : _client = BookWorkClient(api);

  final BookWorkClient _client;

  @override
  Future<DesktopServiceResult<SharedBook>> loadBook(String workspaceId) async =>
      _toDesktop(await _client.bookDetail(workspaceId));

  @override
  Future<DesktopServiceResult<SharedWorkspaceContentEvent>> updateBook(
    String workspaceId,
    SharedUpdateBookRequest request, {
    required String etag,
    required String idempotencyKey,
  }) async => _toDesktop(
    await _client.updateBook(
      workspaceId,
      request: request,
      etag: etag,
      idempotencyKey: idempotencyKey,
    ),
  );

  @override
  Future<DesktopServiceResult<SharedBookRevisionPage>> loadBookRevisions(
    String workspaceId, {
    String? cursor,
    int? limit,
  }) async => _toDesktop(
    await _client.bookRevisions(workspaceId, cursor: cursor, limit: limit),
  );

  @override
  Future<DesktopServiceResult<SharedBookRevision>> loadBookRevision(
    String workspaceId,
    String bookRevisionId,
  ) async =>
      _toDesktop(await _client.bookRevision(workspaceId, bookRevisionId));

  @override
  Future<DesktopServiceResult<SharedBookImportPending>> importBook(
    String workspaceId,
    SharedImportBookRequest request, {
    required String idempotencyKey,
  }) async => _toDesktop(
    await _client.importBook(
      workspaceId,
      request: request,
      idempotencyKey: idempotencyKey,
    ),
  );

  @override
  Future<DesktopServiceResult<SharedBookImport>> loadBookImport(
    String workspaceId,
    String bookImportId,
  ) async => _toDesktop(await _client.bookImport(workspaceId, bookImportId));

  @override
  Future<DesktopServiceResult<SharedWorkspaceContentEvent>> createBookSection(
    String workspaceId,
    SharedCreateBookSectionRequest request, {
    required String idempotencyKey,
  }) async => _toDesktop(
    await _client.createBookSection(
      workspaceId,
      request: request,
      idempotencyKey: idempotencyKey,
    ),
  );

  @override
  Future<DesktopServiceResult<SharedBookSection>> loadBookSection(
    String workspaceId,
    String sectionKey,
  ) async => _toDesktop(await _client.bookSection(workspaceId, sectionKey));

  @override
  Future<DesktopServiceResult<SharedWorkspaceContentEvent>> updateBookSection(
    String workspaceId,
    String sectionKey,
    SharedUpdateBookSectionRequest request, {
    required String etag,
    required String idempotencyKey,
  }) async => _toDesktop(
    await _client.updateBookSection(
      workspaceId,
      sectionKey,
      request: request,
      etag: etag,
      idempotencyKey: idempotencyKey,
    ),
  );

  @override
  Future<DesktopServiceResult<SharedWorkspaceContentEvent>> deleteBookSection(
    String workspaceId,
    String sectionKey, {
    required String etag,
    required String idempotencyKey,
  }) async => _toDesktop(
    await _client.deleteBookSection(
      workspaceId,
      sectionKey,
      etag: etag,
      idempotencyKey: idempotencyKey,
    ),
  );

  @override
  Future<DesktopServiceResult<SharedWorkspaceContentEvent>> restoreBookSection(
    String workspaceId,
    String sectionKey, {
    required String etag,
    required String idempotencyKey,
  }) async => _toDesktop(
    await _client.restoreBookSection(
      workspaceId,
      sectionKey,
      etag: etag,
      idempotencyKey: idempotencyKey,
    ),
  );

  @override
  Future<DesktopServiceResult<SharedWorkspaceContentEvent>> moveBookSection(
    String workspaceId,
    String sectionKey,
    SharedMoveBookSectionRequest request, {
    required String etag,
    required String idempotencyKey,
  }) async => _toDesktop(
    await _client.moveBookSection(
      workspaceId,
      sectionKey,
      request: request,
      sectionEtag: etag,
      idempotencyKey: idempotencyKey,
    ),
  );

  @override
  Future<DesktopServiceResult<SharedManagedPartRevision>> loadBookSectionPart(
    String workspaceId,
    String sectionKey,
    String part, {
    required String partRevisionId,
  }) async => _toDesktop(
    await _client.bookSectionPart(
      workspaceId,
      sectionKey,
      part,
      partRevisionId: partRevisionId,
    ),
  );

  @override
  Future<DesktopServiceResult<SharedWorkspaceContentEvent>> putBookSectionPart(
    String workspaceId,
    String sectionKey,
    String part,
    SharedUpdateManagedPartRequest request, {
    required String etag,
    required String idempotencyKey,
  }) async => _toDesktop(
    await _client.putBookSectionPart(
      workspaceId,
      sectionKey,
      part,
      request: request,
      etag: etag,
      idempotencyKey: idempotencyKey,
    ),
  );

  @override
  Future<DesktopServiceResult<SharedManagedPartRevisionPage>>
  loadBookSectionPartRevisions(
    String workspaceId,
    String sectionKey,
    String part, {
    String? cursor,
    int? limit,
  }) async => _toDesktop(
    await _client.bookSectionPartRevisions(
      workspaceId,
      sectionKey,
      part,
      cursor: cursor,
      limit: limit,
    ),
  );

  @override
  Future<DesktopServiceResult<Uint8List>> exportBook(
    String workspaceId, {
    String? bookRevisionId,
  }) async => _toDesktop(
    await _client.exportBook(workspaceId, bookRevisionId: bookRevisionId),
  );

  @override
  Future<DesktopServiceResult<SharedWorkPage>> loadWorks(
    String workspaceId, {
    String? cursor,
    int? limit,
  }) async => _toDesktop(
    await _client.workPage(workspaceId, cursor: cursor, limit: limit),
  );

  @override
  Future<DesktopServiceResult<SharedWorkspaceContentEvent>> createWork(
    String workspaceId,
    SharedCreateWorkRequest request, {
    required String idempotencyKey,
  }) async => _toDesktop(
    await _client.createWork(
      workspaceId,
      request: request,
      idempotencyKey: idempotencyKey,
    ),
  );

  @override
  Future<DesktopServiceResult<SharedWork>> loadWork(
    String workspaceId,
    String workId,
  ) async => _toDesktop(await _client.workDetail(workspaceId, workId));

  @override
  Future<DesktopServiceResult<SharedWorkspaceContentEvent>> updateWork(
    String workspaceId,
    String workId,
    SharedUpdateWorkRequest request, {
    required String etag,
    required String idempotencyKey,
  }) async => _toDesktop(
    await _client.updateWork(
      workspaceId,
      workId,
      request: request,
      etag: etag,
      idempotencyKey: idempotencyKey,
    ),
  );

  @override
  Future<DesktopServiceResult<SharedWorkspaceContentEvent>> deleteWork(
    String workspaceId,
    String workId, {
    required String etag,
    required String idempotencyKey,
  }) async => _toDesktop(
    await _client.deleteWork(
      workspaceId,
      workId,
      etag: etag,
      idempotencyKey: idempotencyKey,
    ),
  );

  @override
  Future<DesktopServiceResult<SharedWorkspaceContentEvent>> restoreWork(
    String workspaceId,
    String workId, {
    required String etag,
    required String idempotencyKey,
  }) async => _toDesktop(
    await _client.restoreWork(
      workspaceId,
      workId,
      etag: etag,
      idempotencyKey: idempotencyKey,
    ),
  );

  @override
  Future<DesktopServiceResult<SharedWorkspaceContentEvent>> completeWork(
    String workspaceId,
    String workId, {
    required String etag,
    required String idempotencyKey,
  }) async => _toDesktop(
    await _client.completeWork(
      workspaceId,
      workId,
      etag: etag,
      idempotencyKey: idempotencyKey,
    ),
  );

  @override
  Future<DesktopServiceResult<SharedManagedPartRevision>> loadWorkPart(
    String workspaceId,
    String workId,
    String part, {
    required String partRevisionId,
  }) async => _toDesktop(
    await _client.workPart(
      workspaceId,
      workId,
      part,
      partRevisionId: partRevisionId,
    ),
  );

  @override
  Future<DesktopServiceResult<SharedWorkspaceContentEvent>> putWorkPart(
    String workspaceId,
    String workId,
    String part,
    SharedUpdateManagedPartRequest request, {
    required String etag,
    required String idempotencyKey,
  }) async => _toDesktop(
    await _client.putWorkPart(
      workspaceId,
      workId,
      part,
      request: request,
      etag: etag,
      idempotencyKey: idempotencyKey,
    ),
  );

  @override
  Future<DesktopServiceResult<SharedManagedPartRevisionPage>>
  loadWorkPartRevisions(
    String workspaceId,
    String workId,
    String part, {
    String? cursor,
    int? limit,
  }) async => _toDesktop(
    await _client.workPartRevisions(
      workspaceId,
      workId,
      part,
      cursor: cursor,
      limit: limit,
    ),
  );

  @override
  Future<DesktopServiceResult<SharedWorkspaceContentEvent>> promoteWork(
    String workspaceId,
    String workId,
    SharedPromoteWorkRequest request, {
    required String etag,
    required String idempotencyKey,
  }) async => _toDesktop(
    await _client.promoteWork(
      workspaceId,
      workId,
      request: request,
      etag: etag,
      idempotencyKey: idempotencyKey,
    ),
  );
}

DesktopServiceResult<T> _toDesktop<T>(ApiResult<T> result) {
  final data = result.data;
  if (result.ok && data != null) {
    return DesktopServiceResult<T>.success(data);
  }
  final error = result.error;
  final code = error?.code ?? 'DESKTOP_BOOK_WORK_RESPONSE_INVALID';
  if (code.endsWith('_UNAVAILABLE') ||
      code == 'API_ENDPOINT_PROHIBITED' ||
      code == 'API_ENDPOINT_RETIRED') {
    return DesktopServiceResult<T>.unavailable(
      code: code,
      message: error?.message ?? '典藏与创作历史服务当前不可用',
    );
  }
  return DesktopServiceResult<T>.failure(
    code: code,
    message: error?.message ?? '典藏与创作历史响应无效',
    retryable: error?.isRetryable ?? false,
  );
}
