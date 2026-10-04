import 'package:huahuo_api/huahuo_api.dart';
import '../application/mobile_book_work_contract.dart';

export '../application/mobile_book_work_contract.dart';

final class RemoteMobileBookWorkPort implements MobileBookWorkPort {
  RemoteMobileBookWorkPort(ApiClient apiClient)
    : _client = BookWorkClient(apiClient);

  final BookWorkClient _client;

  @override
  Future<MobileBookWorkResult<SharedBook>> book(String workspaceId) async =>
      _toMobile(await _client.bookDetail(workspaceId));

  @override
  Future<MobileBookWorkResult<SharedWorkPage>> works(
    String workspaceId, {
    String? cursor,
    int limit = 50,
  }) async {
    if (cursor != null) {
      return const MobileBookWorkResult.failure(
        'BOOK_WORK_PAGINATION_UNSUPPORTED',
      );
    }
    return _toMobile(await _client.workPage(workspaceId));
  }

  @override
  Future<MobileBookWorkResult<SharedWork>> work(
    String workspaceId,
    String workId,
  ) async => _toMobile(await _client.workDetail(workspaceId, workId));

  @override
  Future<MobileBookWorkResult<SharedManagedPartRevision>> bookSectionPart(
    String workspaceId,
    String sectionKey,
    String part, {
    required String partRevisionId,
  }) async => _toMobile(
    await _client.bookSectionPart(
      workspaceId,
      sectionKey,
      part,
      partRevisionId: partRevisionId,
    ),
  );

  @override
  Future<MobileBookWorkResult<SharedManagedPartRevision>> workPart(
    String workspaceId,
    String workId,
    String part, {
    required String partRevisionId,
  }) async => _toMobile(
    await _client.workPart(
      workspaceId,
      workId,
      part,
      partRevisionId: partRevisionId,
    ),
  );

  @override
  Future<MobileBookWorkResult<SharedWorkspaceContentEvent>> completeWork(
    String workspaceId,
    String workId, {
    required String etag,
    required String idempotencyKey,
  }) async => _toMobile(
    await _client.completeWork(
      workspaceId,
      workId,
      etag: etag,
      idempotencyKey: idempotencyKey,
    ),
  );

  @override
  Future<MobileBookWorkResult<SharedWorkspaceContentEvent>> promoteWork(
    String workspaceId,
    String workId,
    SharedPromoteWorkRequest request, {
    required String etag,
    required String idempotencyKey,
  }) async => _toMobile(
    await _client.promoteWork(
      workspaceId,
      workId,
      request: request,
      etag: etag,
      idempotencyKey: idempotencyKey,
    ),
  );
}

MobileBookWorkResult<T> _toMobile<T>(ApiResult<T> result) {
  final data = result.data;
  if (result.ok && data != null) return MobileBookWorkResult<T>.success(data);
  final failure = result.error;
  final code = failure?.code ?? 'BOOK_WORK_REQUEST_FAILED';
  if (failure?.category == AppFailureCategory.auth ||
      failure?.category == AppFailureCategory.compatibility ||
      code == 'API_BASE_URL_UNCONFIGURED') {
    return MobileBookWorkResult<T>.unavailable(code);
  }
  return MobileBookWorkResult<T>.failure(
    code,
    retryable: failure?.isRetryable ?? false,
  );
}
