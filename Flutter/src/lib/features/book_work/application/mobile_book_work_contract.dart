import 'package:flutter/foundation.dart';

import '../../../core/api/api_client.dart';

enum MobileBookWorkResultStatus { success, unavailable, failure }

@immutable
final class MobileBookWorkResult<T> {
  const MobileBookWorkResult._({
    required this.status,
    this.data,
    this.errorCode,
    this.retryable = false,
  });

  const MobileBookWorkResult.success(T data)
    : this._(status: MobileBookWorkResultStatus.success, data: data);

  const MobileBookWorkResult.unavailable(String errorCode)
    : this._(
        status: MobileBookWorkResultStatus.unavailable,
        errorCode: errorCode,
      );

  const MobileBookWorkResult.failure(String errorCode, {bool retryable = false})
    : this._(
        status: MobileBookWorkResultStatus.failure,
        errorCode: errorCode,
        retryable: retryable,
      );

  final MobileBookWorkResultStatus status;
  final T? data;
  final String? errorCode;
  final bool retryable;

  bool get isSuccess => status == MobileBookWorkResultStatus.success;
  bool get isUnavailable => status == MobileBookWorkResultStatus.unavailable;
}

abstract interface class MobileBookWorkPort {
  Future<MobileBookWorkResult<SharedBook>> book(String workspaceId);

  Future<MobileBookWorkResult<SharedWorkPage>> works(
    String workspaceId, {
    String? cursor,
    int limit = 50,
  });

  Future<MobileBookWorkResult<SharedWork>> work(
    String workspaceId,
    String workId,
  );

  Future<MobileBookWorkResult<SharedManagedPartRevision>> bookSectionPart(
    String workspaceId,
    String sectionKey,
    String part, {
    required String partRevisionId,
  });

  Future<MobileBookWorkResult<SharedManagedPartRevision>> workPart(
    String workspaceId,
    String workId,
    String part, {
    required String partRevisionId,
  });

  Future<MobileBookWorkResult<SharedWorkspaceContentEvent>> completeWork(
    String workspaceId,
    String workId, {
    required String etag,
    required String idempotencyKey,
  });

  Future<MobileBookWorkResult<SharedWorkspaceContentEvent>> promoteWork(
    String workspaceId,
    String workId,
    SharedPromoteWorkRequest request, {
    required String etag,
    required String idempotencyKey,
  });
}

final class UnavailableMobileBookWorkPort implements MobileBookWorkPort {
  const UnavailableMobileBookWorkPort({
    this.code = 'BOOK_WORK_SERVICE_UNAVAILABLE',
  });

  final String code;

  MobileBookWorkResult<T> _unavailable<T>() =>
      MobileBookWorkResult<T>.unavailable(code);

  @override
  Future<MobileBookWorkResult<SharedBook>> book(String workspaceId) async =>
      _unavailable();

  @override
  Future<MobileBookWorkResult<SharedWorkPage>> works(
    String workspaceId, {
    String? cursor,
    int limit = 50,
  }) async => _unavailable();

  @override
  Future<MobileBookWorkResult<SharedWork>> work(
    String workspaceId,
    String workId,
  ) async => _unavailable();

  @override
  Future<MobileBookWorkResult<SharedManagedPartRevision>> bookSectionPart(
    String workspaceId,
    String sectionKey,
    String part, {
    required String partRevisionId,
  }) async => _unavailable();

  @override
  Future<MobileBookWorkResult<SharedManagedPartRevision>> workPart(
    String workspaceId,
    String workId,
    String part, {
    required String partRevisionId,
  }) async => _unavailable();

  @override
  Future<MobileBookWorkResult<SharedWorkspaceContentEvent>> completeWork(
    String workspaceId,
    String workId, {
    required String etag,
    required String idempotencyKey,
  }) async => _unavailable();

  @override
  Future<MobileBookWorkResult<SharedWorkspaceContentEvent>> promoteWork(
    String workspaceId,
    String workId,
    SharedPromoteWorkRequest request, {
    required String etag,
    required String idempotencyKey,
  }) async => _unavailable();
}
