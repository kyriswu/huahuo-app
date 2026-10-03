import 'dart:typed_data';

import 'package:huahuo_api/huahuo_api.dart';

import '../../../shared/services/desktop_service_result.dart';

abstract interface class DesktopBookWorkPort {
  Future<DesktopServiceResult<SharedBook>> loadBook(String workspaceId);

  Future<DesktopServiceResult<SharedWorkspaceContentEvent>> updateBook(
    String workspaceId,
    SharedUpdateBookRequest request, {
    required String etag,
    required String idempotencyKey,
  });

  Future<DesktopServiceResult<SharedBookRevisionPage>> loadBookRevisions(
    String workspaceId, {
    String? cursor,
    int? limit,
  });

  Future<DesktopServiceResult<SharedBookRevision>> loadBookRevision(
    String workspaceId,
    String bookRevisionId,
  );

  Future<DesktopServiceResult<SharedBookImportPending>> importBook(
    String workspaceId,
    SharedImportBookRequest request, {
    required String idempotencyKey,
  });

  Future<DesktopServiceResult<SharedBookImport>> loadBookImport(
    String workspaceId,
    String bookImportId,
  );

  Future<DesktopServiceResult<SharedWorkspaceContentEvent>> createBookSection(
    String workspaceId,
    SharedCreateBookSectionRequest request, {
    required String idempotencyKey,
  });

  Future<DesktopServiceResult<SharedBookSection>> loadBookSection(
    String workspaceId,
    String sectionKey,
  );

  Future<DesktopServiceResult<SharedWorkspaceContentEvent>> updateBookSection(
    String workspaceId,
    String sectionKey,
    SharedUpdateBookSectionRequest request, {
    required String etag,
    required String idempotencyKey,
  });

  Future<DesktopServiceResult<SharedWorkspaceContentEvent>> deleteBookSection(
    String workspaceId,
    String sectionKey, {
    required String etag,
    required String idempotencyKey,
  });

  Future<DesktopServiceResult<SharedWorkspaceContentEvent>> restoreBookSection(
    String workspaceId,
    String sectionKey, {
    required String etag,
    required String idempotencyKey,
  });

  Future<DesktopServiceResult<SharedWorkspaceContentEvent>> moveBookSection(
    String workspaceId,
    String sectionKey,
    SharedMoveBookSectionRequest request, {
    required String etag,
    required String idempotencyKey,
  });

  Future<DesktopServiceResult<SharedManagedPartRevision>> loadBookSectionPart(
    String workspaceId,
    String sectionKey,
    String part, {
    required String partRevisionId,
  });

  Future<DesktopServiceResult<SharedWorkspaceContentEvent>> putBookSectionPart(
    String workspaceId,
    String sectionKey,
    String part,
    SharedUpdateManagedPartRequest request, {
    required String etag,
    required String idempotencyKey,
  });

  Future<DesktopServiceResult<SharedManagedPartRevisionPage>>
  loadBookSectionPartRevisions(
    String workspaceId,
    String sectionKey,
    String part, {
    String? cursor,
    int? limit,
  });

  Future<DesktopServiceResult<Uint8List>> exportBook(
    String workspaceId, {
    String? bookRevisionId,
  });

  Future<DesktopServiceResult<SharedWorkPage>> loadWorks(
    String workspaceId, {
    String? cursor,
    int? limit,
  });

  Future<DesktopServiceResult<SharedWorkspaceContentEvent>> createWork(
    String workspaceId,
    SharedCreateWorkRequest request, {
    required String idempotencyKey,
  });

  Future<DesktopServiceResult<SharedWork>> loadWork(
    String workspaceId,
    String workId,
  );

  Future<DesktopServiceResult<SharedWorkspaceContentEvent>> updateWork(
    String workspaceId,
    String workId,
    SharedUpdateWorkRequest request, {
    required String etag,
    required String idempotencyKey,
  });

  Future<DesktopServiceResult<SharedWorkspaceContentEvent>> deleteWork(
    String workspaceId,
    String workId, {
    required String etag,
    required String idempotencyKey,
  });

  Future<DesktopServiceResult<SharedWorkspaceContentEvent>> restoreWork(
    String workspaceId,
    String workId, {
    required String etag,
    required String idempotencyKey,
  });

  Future<DesktopServiceResult<SharedWorkspaceContentEvent>> completeWork(
    String workspaceId,
    String workId, {
    required String etag,
    required String idempotencyKey,
  });

  Future<DesktopServiceResult<SharedManagedPartRevision>> loadWorkPart(
    String workspaceId,
    String workId,
    String part, {
    required String partRevisionId,
  });

  Future<DesktopServiceResult<SharedWorkspaceContentEvent>> putWorkPart(
    String workspaceId,
    String workId,
    String part,
    SharedUpdateManagedPartRequest request, {
    required String etag,
    required String idempotencyKey,
  });

  Future<DesktopServiceResult<SharedManagedPartRevisionPage>>
  loadWorkPartRevisions(
    String workspaceId,
    String workId,
    String part, {
    String? cursor,
    int? limit,
  });

  Future<DesktopServiceResult<SharedWorkspaceContentEvent>> promoteWork(
    String workspaceId,
    String workId,
    SharedPromoteWorkRequest request, {
    required String etag,
    required String idempotencyKey,
  });
}

final class UnavailableDesktopBookWorkPort implements DesktopBookWorkPort {
  const UnavailableDesktopBookWorkPort();

  DesktopServiceResult<T> _unavailable<T>() =>
      DesktopServiceResult<T>.unavailable(
        code: 'DESKTOP_BOOK_WORK_UNAVAILABLE',
        message: '典藏与创作历史服务尚未配置',
      );

  @override
  Future<DesktopServiceResult<SharedBook>> loadBook(String workspaceId) async =>
      _unavailable();

  @override
  Future<DesktopServiceResult<SharedWorkspaceContentEvent>> updateBook(
    String workspaceId,
    SharedUpdateBookRequest request, {
    required String etag,
    required String idempotencyKey,
  }) async => _unavailable();

  @override
  Future<DesktopServiceResult<SharedBookRevisionPage>> loadBookRevisions(
    String workspaceId, {
    String? cursor,
    int? limit,
  }) async => _unavailable();

  @override
  Future<DesktopServiceResult<SharedBookRevision>> loadBookRevision(
    String workspaceId,
    String bookRevisionId,
  ) async => _unavailable();

  @override
  Future<DesktopServiceResult<SharedBookImportPending>> importBook(
    String workspaceId,
    SharedImportBookRequest request, {
    required String idempotencyKey,
  }) async => _unavailable();

  @override
  Future<DesktopServiceResult<SharedBookImport>> loadBookImport(
    String workspaceId,
    String bookImportId,
  ) async => _unavailable();

  @override
  Future<DesktopServiceResult<SharedWorkspaceContentEvent>> createBookSection(
    String workspaceId,
    SharedCreateBookSectionRequest request, {
    required String idempotencyKey,
  }) async => _unavailable();

  @override
  Future<DesktopServiceResult<SharedBookSection>> loadBookSection(
    String workspaceId,
    String sectionKey,
  ) async => _unavailable();

  @override
  Future<DesktopServiceResult<SharedWorkspaceContentEvent>> updateBookSection(
    String workspaceId,
    String sectionKey,
    SharedUpdateBookSectionRequest request, {
    required String etag,
    required String idempotencyKey,
  }) async => _unavailable();

  @override
  Future<DesktopServiceResult<SharedWorkspaceContentEvent>> deleteBookSection(
    String workspaceId,
    String sectionKey, {
    required String etag,
    required String idempotencyKey,
  }) async => _unavailable();

  @override
  Future<DesktopServiceResult<SharedWorkspaceContentEvent>> restoreBookSection(
    String workspaceId,
    String sectionKey, {
    required String etag,
    required String idempotencyKey,
  }) async => _unavailable();

  @override
  Future<DesktopServiceResult<SharedWorkspaceContentEvent>> moveBookSection(
    String workspaceId,
    String sectionKey,
    SharedMoveBookSectionRequest request, {
    required String etag,
    required String idempotencyKey,
  }) async => _unavailable();

  @override
  Future<DesktopServiceResult<SharedManagedPartRevision>> loadBookSectionPart(
    String workspaceId,
    String sectionKey,
    String part, {
    required String partRevisionId,
  }) async => _unavailable();

  @override
  Future<DesktopServiceResult<SharedWorkspaceContentEvent>> putBookSectionPart(
    String workspaceId,
    String sectionKey,
    String part,
    SharedUpdateManagedPartRequest request, {
    required String etag,
    required String idempotencyKey,
  }) async => _unavailable();

  @override
  Future<DesktopServiceResult<SharedManagedPartRevisionPage>>
  loadBookSectionPartRevisions(
    String workspaceId,
    String sectionKey,
    String part, {
    String? cursor,
    int? limit,
  }) async => _unavailable();

  @override
  Future<DesktopServiceResult<Uint8List>> exportBook(
    String workspaceId, {
    String? bookRevisionId,
  }) async => _unavailable();

  @override
  Future<DesktopServiceResult<SharedWorkPage>> loadWorks(
    String workspaceId, {
    String? cursor,
    int? limit,
  }) async => _unavailable();

  @override
  Future<DesktopServiceResult<SharedWorkspaceContentEvent>> createWork(
    String workspaceId,
    SharedCreateWorkRequest request, {
    required String idempotencyKey,
  }) async => _unavailable();

  @override
  Future<DesktopServiceResult<SharedWork>> loadWork(
    String workspaceId,
    String workId,
  ) async => _unavailable();

  @override
  Future<DesktopServiceResult<SharedWorkspaceContentEvent>> updateWork(
    String workspaceId,
    String workId,
    SharedUpdateWorkRequest request, {
    required String etag,
    required String idempotencyKey,
  }) async => _unavailable();

  @override
  Future<DesktopServiceResult<SharedWorkspaceContentEvent>> deleteWork(
    String workspaceId,
    String workId, {
    required String etag,
    required String idempotencyKey,
  }) async => _unavailable();

  @override
  Future<DesktopServiceResult<SharedWorkspaceContentEvent>> restoreWork(
    String workspaceId,
    String workId, {
    required String etag,
    required String idempotencyKey,
  }) async => _unavailable();

  @override
  Future<DesktopServiceResult<SharedWorkspaceContentEvent>> completeWork(
    String workspaceId,
    String workId, {
    required String etag,
    required String idempotencyKey,
  }) async => _unavailable();

  @override
  Future<DesktopServiceResult<SharedManagedPartRevision>> loadWorkPart(
    String workspaceId,
    String workId,
    String part, {
    required String partRevisionId,
  }) async => _unavailable();

  @override
  Future<DesktopServiceResult<SharedWorkspaceContentEvent>> putWorkPart(
    String workspaceId,
    String workId,
    String part,
    SharedUpdateManagedPartRequest request, {
    required String etag,
    required String idempotencyKey,
  }) async => _unavailable();

  @override
  Future<DesktopServiceResult<SharedManagedPartRevisionPage>>
  loadWorkPartRevisions(
    String workspaceId,
    String workId,
    String part, {
    String? cursor,
    int? limit,
  }) async => _unavailable();

  @override
  Future<DesktopServiceResult<SharedWorkspaceContentEvent>> promoteWork(
    String workspaceId,
    String workId,
    SharedPromoteWorkRequest request, {
    required String etag,
    required String idempotencyKey,
  }) async => _unavailable();
}
