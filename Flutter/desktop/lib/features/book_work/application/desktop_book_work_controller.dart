import 'package:huahuo_api/huahuo_api.dart';

import '../../../shared/services/desktop_service_result.dart';
import '../domain/desktop_book_work_port.dart';

typedef DesktopBookWorkIdempotencyKeyFactory = String Function();

final class DesktopBookWorkController {
  factory DesktopBookWorkController(
    DesktopBookWorkPort port, {
    DesktopBookWorkIdempotencyKeyFactory? idempotencyKeyFactory,
  }) => DesktopBookWorkController._(port, idempotencyKeyFactory);

  DesktopBookWorkController._(this._port, this._idempotencyKeyFactory);

  static String sectionKeyForWorkId(String workId) {
    final normalized = workId.trim().toLowerCase().replaceAll(
      RegExp('[^a-z0-9_-]'),
      '_',
    );
    final suffix = normalized.isEmpty ? 'work' : normalized;
    final prefix = suffix.substring(0, suffix.length > 21 ? 21 : suffix.length);
    return 'w_${prefix}_${_stableWorkIdHash(workId)}';
  }

  final DesktopBookWorkPort _port;
  final DesktopBookWorkIdempotencyKeyFactory? _idempotencyKeyFactory;
  final Map<String, _PendingBookWorkMutation> _pendingMutations =
      <String, _PendingBookWorkMutation>{};

  String? _userId;
  String? _workspaceId;
  int _bindingGeneration = 0;
  int _idempotencySequence = 0;

  void bindAccount({required String userId, required String workspaceId}) {
    if (_userId == userId && _workspaceId == workspaceId) return;
    _userId = userId;
    _workspaceId = workspaceId;
    _bindingGeneration += 1;
    _pendingMutations.clear();
  }

  void clearAccount() {
    _userId = null;
    _workspaceId = null;
    _bindingGeneration += 1;
    _pendingMutations.clear();
  }

  void discardWorkMutations(String workId) {
    _pendingMutations
      ..remove('complete:$workId')
      ..remove('promote:$workId');
  }

  Future<DesktopServiceResult<SharedBook>> loadBook() async {
    final workspaceId = _workspaceId;
    if (workspaceId == null) return _accountRequired();
    final generation = _bindingGeneration;
    final result = await _port.loadBook(workspaceId);
    if (!_bindingIsCurrent(generation, workspaceId)) return _accountChanged();
    return result;
  }

  Future<DesktopServiceResult<List<SharedWork>>> loadAllWorks() async {
    final workspaceId = _workspaceId;
    if (workspaceId == null) return _accountRequired();
    final generation = _bindingGeneration;
    final worksById = <String, SharedWork>{};
    final seenCursors = <String>{};
    String? cursor;
    do {
      final page = await _port.loadWorks(
        workspaceId,
        cursor: cursor,
        limit: 100,
      );
      if (!_bindingIsCurrent(generation, workspaceId)) {
        return _accountChanged();
      }
      if (!page.isSuccess || page.data == null) {
        return _forwardFailure<SharedWorkPage, List<SharedWork>>(page);
      }
      for (final work in page.data!.items) {
        final existing = worksById[work.workId];
        if (existing != null && !_sameWorkSnapshot(existing, work)) {
          return const DesktopServiceResult<List<SharedWork>>.failure(
            code: 'DESKTOP_WORK_DUPLICATE_ID_CONFLICT',
            message: '创作历史分页返回了冲突的重复 Work',
          );
        }
        worksById[work.workId] = work;
      }
      cursor = page.data!.nextCursor;
      if (cursor != null && !seenCursors.add(cursor)) {
        return const DesktopServiceResult<List<SharedWork>>.failure(
          code: 'DESKTOP_WORK_CURSOR_REPEATED',
          message: '创作历史分页游标无效',
        );
      }
    } while (cursor != null);
    return DesktopServiceResult<List<SharedWork>>.success(
      List<SharedWork>.unmodifiable(worksById.values),
    );
  }

  Future<DesktopServiceResult<SharedWork>> loadWork(String workId) async {
    final workspaceId = _workspaceId;
    if (workspaceId == null) return _accountRequired();
    final generation = _bindingGeneration;
    final result = await _port.loadWork(workspaceId, workId);
    if (!_bindingIsCurrent(generation, workspaceId)) return _accountChanged();
    return result;
  }

  Future<DesktopServiceResult<SharedManagedPartRevision>> loadBookSectionPart({
    required SharedBookSection section,
    required String part,
  }) async {
    final workspaceId = _workspaceId;
    if (workspaceId == null) return _accountRequired();
    final generation = _bindingGeneration;
    final partRevisionId = section.currentPartRevisionIds[part];
    if (partRevisionId == null) {
      return const DesktopServiceResult<SharedManagedPartRevision>.unavailable(
        code: 'DESKTOP_BOOK_PART_UNAVAILABLE',
        message: '该章节尚无可读取的内容版本',
      );
    }
    final result = await _port.loadBookSectionPart(
      workspaceId,
      section.sectionKey,
      part,
      partRevisionId: partRevisionId,
    );
    if (!_bindingIsCurrent(generation, workspaceId)) return _accountChanged();
    final revision = result.data;
    if (result.isSuccess &&
        revision != null &&
        (revision.part != part || revision.partRevisionId != partRevisionId)) {
      return const DesktopServiceResult<SharedManagedPartRevision>.failure(
        code: 'DESKTOP_BOOK_PART_REVISION_MISMATCH',
        message: '服务未返回请求的典藏章节精确版本',
      );
    }
    return result;
  }

  Future<DesktopServiceResult<SharedManagedPartRevision>> loadWorkPart({
    required SharedWork work,
    required String part,
  }) async {
    final workspaceId = _workspaceId;
    if (workspaceId == null) return _accountRequired();
    final generation = _bindingGeneration;
    final head = _partHead(work.parts, part);
    final partRevisionId = head?.currentRevisionId;
    if (partRevisionId == null) {
      return const DesktopServiceResult<SharedManagedPartRevision>.unavailable(
        code: 'DESKTOP_WORK_PART_UNAVAILABLE',
        message: '该创作尚无可读取的内容版本',
      );
    }
    final result = await _port.loadWorkPart(
      workspaceId,
      work.workId,
      part,
      partRevisionId: partRevisionId,
    );
    if (!_bindingIsCurrent(generation, workspaceId)) return _accountChanged();
    final revision = result.data;
    if (result.isSuccess &&
        revision != null &&
        (revision.part != part || revision.partRevisionId != partRevisionId)) {
      return const DesktopServiceResult<SharedManagedPartRevision>.failure(
        code: 'DESKTOP_WORK_PART_REVISION_MISMATCH',
        message: '服务未返回请求的创作精确版本',
      );
    }
    return result;
  }

  Future<DesktopServiceResult<SharedWorkspaceContentEvent>> completeWork(
    SharedWork work,
  ) async {
    final workspaceId = _workspaceId;
    if (workspaceId == null) return _accountRequired();
    final generation = _bindingGeneration;
    const action = 'complete';
    final scope = '$action:${work.workId}';
    final intent = '$scope:${work.etag}';
    final pending = _mutationFor(scope: scope, intent: intent);
    if (pending == null) return _idempotencyConflict();
    final result = await _port.completeWork(
      workspaceId,
      work.workId,
      etag: work.etag,
      idempotencyKey: pending.idempotencyKey,
    );
    if (!_bindingIsCurrent(generation, workspaceId)) return _accountChanged();
    if (result.isSuccess && identical(_pendingMutations[scope], pending)) {
      _pendingMutations.remove(scope);
    }
    return result;
  }

  Future<DesktopServiceResult<SharedWorkspaceContentEvent>>
  promoteWorkToBookSection({
    required SharedWork work,
    required String part,
    required String sectionKey,
    required String title,
    String group = 'chapters',
  }) async {
    final workspaceId = _workspaceId;
    if (workspaceId == null) return _accountRequired();
    final generation = _bindingGeneration;
    final partRevisionId = _partHead(work.parts, part)?.currentRevisionId;
    if (partRevisionId == null) {
      return const DesktopServiceResult<
        SharedWorkspaceContentEvent
      >.unavailable(
        code: 'DESKTOP_WORK_PROMOTION_PART_UNAVAILABLE',
        message: '该创作没有可收录的精确内容版本',
      );
    }
    final request = SharedPromoteWorkRequest.bookSection(
      sourcePart: part,
      sourcePartRevisionId: partRevisionId,
      sectionKey: sectionKey,
      title: title,
      group: group,
    );
    final scope = 'promote:${work.workId}';
    final intent = <String>[
      scope,
      work.etag,
      part,
      partRevisionId,
      sectionKey,
      title,
      group,
    ].join(':');
    final pending = _mutationFor(scope: scope, intent: intent);
    if (pending == null) return _idempotencyConflict();
    final result = await _port.promoteWork(
      workspaceId,
      work.workId,
      request,
      etag: work.etag,
      idempotencyKey: pending.idempotencyKey,
    );
    if (!_bindingIsCurrent(generation, workspaceId)) return _accountChanged();
    if (result.isSuccess && identical(_pendingMutations[scope], pending)) {
      _pendingMutations.remove(scope);
    }
    return result;
  }

  _PendingBookWorkMutation? _mutationFor({
    required String scope,
    required String intent,
  }) {
    final existing = _pendingMutations[scope];
    if (existing != null) return existing.intent == intent ? existing : null;
    final pending = _PendingBookWorkMutation(
      intent: intent,
      idempotencyKey: _nextIdempotencyKey(),
    );
    _pendingMutations[scope] = pending;
    return pending;
  }

  SharedManagedPartHead? _partHead(
    Iterable<SharedManagedPartHead> parts,
    String part,
  ) {
    for (final head in parts) {
      if (head.part == part) return head;
    }
    return null;
  }

  bool _bindingIsCurrent(int generation, String workspaceId) =>
      generation == _bindingGeneration && _workspaceId == workspaceId;

  bool _sameWorkSnapshot(SharedWork left, SharedWork right) {
    if (left.title != right.title ||
        left.lifecycle != right.lifecycle ||
        left.metadataVersion != right.metadataVersion ||
        left.etag != right.etag ||
        left.parts.length != right.parts.length) {
      return false;
    }
    for (var index = 0; index < left.parts.length; index += 1) {
      final leftPart = left.parts[index];
      final rightPart = right.parts[index];
      if (leftPart.part != rightPart.part ||
          leftPart.status != rightPart.status ||
          leftPart.currentRevisionId != rightPart.currentRevisionId ||
          leftPart.revision != rightPart.revision) {
        return false;
      }
    }
    return true;
  }

  String _nextIdempotencyKey() {
    final custom = _idempotencyKeyFactory;
    if (custom != null) return custom();
    _idempotencySequence += 1;
    return 'desktop-book-work-'
        '${DateTime.now().toUtc().microsecondsSinceEpoch}-'
        '$_idempotencySequence';
  }

  DesktopServiceResult<T> _accountRequired<T>() =>
      DesktopServiceResult<T>.unavailable(
        code: 'DESKTOP_BOOK_WORK_ACCOUNT_REQUIRED',
        message: '请先登录并完成 Workspace 初始化',
      );

  DesktopServiceResult<T> _idempotencyConflict<T>() =>
      DesktopServiceResult<T>.failure(
        code: 'DESKTOP_BOOK_WORK_IDEMPOTENCY_CONFLICT',
        message: '待重试操作与当前内容版本不一致，请刷新后重试',
      );

  DesktopServiceResult<T> _accountChanged<T>() =>
      DesktopServiceResult<T>.failure(
        code: 'DESKTOP_BOOK_WORK_ACCOUNT_CHANGED',
        message: '账号或 Workspace 已变化，已忽略旧请求结果',
      );

  DesktopServiceResult<R> _forwardFailure<T, R>(
    DesktopServiceResult<T> source,
  ) {
    if (source.isUnavailable) {
      return DesktopServiceResult<R>.unavailable(
        code: source.code,
        message: source.message,
      );
    }
    return DesktopServiceResult<R>.failure(
      code: source.code,
      message: source.message,
      retryable: source.retryable,
    );
  }
}

final class _PendingBookWorkMutation {
  const _PendingBookWorkMutation({
    required this.intent,
    required this.idempotencyKey,
  });

  final String intent;
  final String idempotencyKey;
}

String _stableWorkIdHash(String value) {
  var hash = 0x811c9dc5;
  for (final codeUnit in value.codeUnits) {
    hash ^= codeUnit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}
