import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_client.dart';
import 'mobile_book_work_contract.dart';

typedef MobileBookWorkIdempotencyKeyFactory = String Function();

// resident-provider: Shares one mobile book work port dependency for the full account session.
final mobileBookWorkPortProvider = Provider<MobileBookWorkPort>((ref) {
  return const UnavailableMobileBookWorkPort();
});

// resident-provider: Keeps the mobile book work identity value consistent across sibling route consumers.
final mobileBookWorkIdentityProvider = Provider<MobileBookWorkIdentity>((ref) {
  return const MobileBookWorkIdentity.anonymous();
});

// resident-provider: Preserves the mobile book work controller state machine across route transitions.
final mobileBookWorkControllerProvider =
    ChangeNotifierProvider<MobileBookWorkController>((ref) {
      final controller = MobileBookWorkController(
        ref.watch(mobileBookWorkPortProvider),
      );
      controller.bindIdentity(ref.watch(mobileBookWorkIdentityProvider));
      return controller;
    });

@immutable
final class MobileBookWorkIdentity {
  const MobileBookWorkIdentity({
    required this.userId,
    required this.workspaceId,
  });

  const MobileBookWorkIdentity.anonymous() : userId = null, workspaceId = null;

  final String? userId;
  final String? workspaceId;

  bool get isReady =>
      userId?.trim().isNotEmpty == true &&
      workspaceId?.trim().isNotEmpty == true;

  String get bindingKey => isReady ? '$userId\u0000$workspaceId' : 'anonymous';
}

enum MobileBookWorkStatus { idle, loading, ready, unavailable, failure }

final class MobileBookWorkController extends ChangeNotifier {
  factory MobileBookWorkController(
    MobileBookWorkPort port, {
    MobileBookWorkIdempotencyKeyFactory? idempotencyKeyFactory,
  }) => MobileBookWorkController._(port, idempotencyKeyFactory);

  MobileBookWorkController._(this._port, this._idempotencyKeyFactory);

  final MobileBookWorkPort _port;
  final MobileBookWorkIdempotencyKeyFactory? _idempotencyKeyFactory;
  final Map<String, _PendingMobileBookWorkMutation> _pendingMutations =
      <String, _PendingMobileBookWorkMutation>{};
  final Set<String> _mutatingWorks = <String>{};

  MobileBookWorkIdentity _identity = const MobileBookWorkIdentity.anonymous();
  MobileBookWorkStatus _status = MobileBookWorkStatus.idle;
  SharedBook? _book;
  List<SharedWork> _works = const <SharedWork>[];
  SharedWork? _selectedWork;
  String? _errorCode;
  int _bindingGeneration = 0;
  int _selectionGeneration = 0;
  bool _disposed = false;

  MobileBookWorkIdentity get identity => _identity;
  MobileBookWorkStatus get status => _status;
  SharedBook? get book => _book;
  List<SharedWork> get works => _works;
  SharedWork? get selectedWork => _selectedWork;
  String? get errorCode => _errorCode;
  bool get loading => _status == MobileBookWorkStatus.loading;
  bool isMutating(String workId) => _mutatingWorks.contains(workId);

  void clearSelection() {
    if (_selectedWork == null) return;
    _selectionGeneration += 1;
    _selectedWork = null;
    _notify();
  }

  void bindIdentity(MobileBookWorkIdentity identity) {
    if (_identity.bindingKey == identity.bindingKey) return;
    _identity = identity;
    _bindingGeneration += 1;
    _selectionGeneration += 1;
    _pendingMutations.clear();
    _mutatingWorks.clear();
    _book = null;
    _works = const <SharedWork>[];
    _selectedWork = null;
    _errorCode = null;
    _status = MobileBookWorkStatus.idle;
    _notify();
  }

  Future<void> load() async {
    final binding = _captureBinding();
    if (binding == null) {
      _setUnavailable('BOOK_WORK_ACCOUNT_REQUIRED');
      return;
    }
    _status = MobileBookWorkStatus.loading;
    _errorCode = null;
    _notify();

    final bookResult = await _request(() => _port.book(binding.workspaceId));
    if (!_bindingIsCurrent(binding)) return;
    if (!bookResult.isSuccess || bookResult.data == null) {
      _applyFailure(bookResult);
      return;
    }

    final worksById = <String, SharedWork>{};
    final seenCursors = <String>{};
    String? cursor;
    do {
      final page = await _request(
        () => _port.works(binding.workspaceId, cursor: cursor, limit: 50),
      );
      if (!_bindingIsCurrent(binding)) return;
      if (!page.isSuccess || page.data == null) {
        _applyFailure(page);
        return;
      }
      for (final work in page.data!.items) {
        final previous = worksById[work.workId];
        if (previous != null && !_sameWork(previous, work)) {
          _setFailure('BOOK_WORK_DUPLICATE_ID_CONFLICT');
          return;
        }
        worksById[work.workId] = work;
      }
      cursor = _nonEmpty(page.data!.nextCursor);
      if (cursor != null && !seenCursors.add(cursor)) {
        _setFailure('BOOK_WORK_CURSOR_REPEATED');
        return;
      }
    } while (cursor != null);

    _book = bookResult.data;
    _works = List<SharedWork>.unmodifiable(worksById.values);
    final selectedId = _selectedWork?.workId;
    _selectedWork = selectedId == null ? null : worksById[selectedId];
    _status = MobileBookWorkStatus.ready;
    _errorCode = null;
    _notify();
  }

  Future<MobileBookWorkResult<SharedWork>> selectWork(String workId) async {
    final binding = _captureBinding();
    if (binding == null) return _accountRequired();
    final selectionGeneration = ++_selectionGeneration;
    final result = await _request(
      () => _port.work(binding.workspaceId, workId),
    );
    if (!_bindingIsCurrent(binding)) return _accountChanged();
    if (selectionGeneration != _selectionGeneration) {
      return const MobileBookWorkResult<SharedWork>.failure(
        'BOOK_WORK_SELECTION_SUPERSEDED',
      );
    }
    final work = result.data;
    if (result.isSuccess && work != null && work.workId == workId) {
      _selectedWork = work;
      _errorCode = null;
      _notify();
      return result;
    }
    if (result.isSuccess) {
      return const MobileBookWorkResult<SharedWork>.failure(
        'BOOK_WORK_DETAIL_MISMATCH',
      );
    }
    _errorCode = result.errorCode;
    _notify();
    return result;
  }

  Future<MobileBookWorkResult<SharedManagedPartRevision>> openBookPart({
    required SharedBookSection section,
    required String part,
  }) async {
    final binding = _captureBinding();
    if (binding == null) return _accountRequired();
    final revisionId = section.currentPartRevisionIds[part];
    if (revisionId == null) {
      return const MobileBookWorkResult<SharedManagedPartRevision>.unavailable(
        'BOOK_SECTION_PART_UNAVAILABLE',
      );
    }
    final result = await _request(
      () => _port.bookSectionPart(
        binding.workspaceId,
        section.sectionKey,
        part,
        partRevisionId: revisionId,
      ),
    );
    if (!_bindingIsCurrent(binding)) return _accountChanged();
    final revision = result.data;
    if (result.isSuccess &&
        revision != null &&
        (revision.part != part || revision.partRevisionId != revisionId)) {
      return const MobileBookWorkResult<SharedManagedPartRevision>.failure(
        'BOOK_SECTION_PART_REVISION_MISMATCH',
      );
    }
    return result;
  }

  Future<MobileBookWorkResult<SharedManagedPartRevision>> openWorkPart({
    required SharedWork work,
    required String part,
  }) async {
    final binding = _captureBinding();
    if (binding == null) return _accountRequired();
    final revisionId = _partHead(work.parts, part)?.currentRevisionId;
    if (revisionId == null) {
      return const MobileBookWorkResult<SharedManagedPartRevision>.unavailable(
        'WORK_PART_UNAVAILABLE',
      );
    }
    final result = await _request(
      () => _port.workPart(
        binding.workspaceId,
        work.workId,
        part,
        partRevisionId: revisionId,
      ),
    );
    if (!_bindingIsCurrent(binding)) return _accountChanged();
    final revision = result.data;
    if (result.isSuccess &&
        revision != null &&
        (revision.part != part || revision.partRevisionId != revisionId)) {
      return const MobileBookWorkResult<SharedManagedPartRevision>.failure(
        'WORK_PART_REVISION_MISMATCH',
      );
    }
    return result;
  }

  Future<MobileBookWorkResult<SharedWorkspaceContentEvent>> completeWork(
    SharedWork work,
  ) async {
    final binding = _captureBinding();
    if (binding == null) return _accountRequired();
    final scope = 'complete:${work.workId}';
    final pending = _mutationFor(scope, jsonEncode([scope, work.etag]));
    if (pending == null) return _idempotencyConflict();
    if (!_mutatingWorks.add(work.workId)) return _mutationInProgress();
    _notify();
    final result = await _request(
      () => _port.completeWork(
        binding.workspaceId,
        work.workId,
        etag: work.etag,
        idempotencyKey: pending.idempotencyKey,
      ),
    );
    if (!_bindingIsCurrent(binding)) return _accountChanged();
    _mutatingWorks.remove(work.workId);
    if (result.isSuccess && identical(_pendingMutations[scope], pending)) {
      _pendingMutations.remove(scope);
    }
    _errorCode = result.isSuccess ? null : result.errorCode;
    _notify();
    return result;
  }

  Future<MobileBookWorkResult<SharedWorkspaceContentEvent>> promoteToBook(
    SharedWork work, {
    String part = 'raw',
  }) async {
    final binding = _captureBinding();
    if (binding == null) return _accountRequired();
    final revisionId = _partHead(work.parts, part)?.currentRevisionId;
    if (revisionId == null) {
      return const MobileBookWorkResult<
        SharedWorkspaceContentEvent
      >.unavailable('WORK_PROMOTION_PART_UNAVAILABLE');
    }
    final sectionKey = _sectionKeyFor(work.workId);
    final request = SharedPromoteWorkRequest.bookSection(
      sourcePart: part,
      sourcePartRevisionId: revisionId,
      sectionKey: sectionKey,
      title: work.title,
      group: 'chapters',
    );
    final scope = 'promote:${work.workId}';
    final intent = jsonEncode(<String>[
      scope,
      work.etag,
      part,
      revisionId,
      sectionKey,
      work.title,
    ]);
    final pending = _mutationFor(scope, intent);
    if (pending == null) return _idempotencyConflict();
    if (!_mutatingWorks.add(work.workId)) return _mutationInProgress();
    _notify();
    final result = await _request(
      () => _port.promoteWork(
        binding.workspaceId,
        work.workId,
        request,
        etag: work.etag,
        idempotencyKey: pending.idempotencyKey,
      ),
    );
    if (!_bindingIsCurrent(binding)) return _accountChanged();
    _mutatingWorks.remove(work.workId);
    if (result.isSuccess && identical(_pendingMutations[scope], pending)) {
      _pendingMutations.remove(scope);
    }
    _errorCode = result.isSuccess ? null : result.errorCode;
    _notify();
    return result;
  }

  void discardWorkMutations(String workId) {
    _pendingMutations
      ..remove('complete:$workId')
      ..remove('promote:$workId');
  }

  _MobileBookWorkBinding? _captureBinding() {
    if (!_identity.isReady) return null;
    return _MobileBookWorkBinding(
      generation: _bindingGeneration,
      workspaceId: _identity.workspaceId!.trim(),
    );
  }

  bool _bindingIsCurrent(_MobileBookWorkBinding binding) =>
      !_disposed &&
      binding.generation == _bindingGeneration &&
      _identity.workspaceId?.trim() == binding.workspaceId;

  _PendingMobileBookWorkMutation? _mutationFor(String scope, String intent) {
    final existing = _pendingMutations[scope];
    if (existing != null) return existing.intent == intent ? existing : null;
    final pending = _PendingMobileBookWorkMutation(
      intent: intent,
      idempotencyKey: _nextIdempotencyKey(intent),
    );
    _pendingMutations[scope] = pending;
    return pending;
  }

  String _nextIdempotencyKey(String intent) {
    final custom = _idempotencyKeyFactory;
    if (custom != null) return custom();
    final identity = jsonEncode([_identity.bindingKey, intent]);
    return 'mobile-book-work-${sha256.convert(utf8.encode(identity))}';
  }

  Future<MobileBookWorkResult<T>> _request<T>(
    Future<MobileBookWorkResult<T>> Function() call,
  ) async {
    try {
      return await call();
    } on Object {
      return MobileBookWorkResult<T>.failure(
        'BOOK_WORK_PORT_EXCEPTION',
        retryable: true,
      );
    }
  }

  void _applyFailure<T>(MobileBookWorkResult<T> result) {
    if (result.isUnavailable) {
      _setUnavailable(result.errorCode ?? 'BOOK_WORK_SERVICE_UNAVAILABLE');
    } else {
      _setFailure(result.errorCode ?? 'BOOK_WORK_REQUEST_FAILED');
    }
  }

  void _setUnavailable(String code) {
    _status = MobileBookWorkStatus.unavailable;
    _errorCode = code;
    _notify();
  }

  void _setFailure(String code) {
    _status = MobileBookWorkStatus.failure;
    _errorCode = code;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
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

bool _sameWork(SharedWork left, SharedWork right) {
  if (left.title != right.title ||
      left.lifecycle != right.lifecycle ||
      left.metadataVersion != right.metadataVersion ||
      left.etag != right.etag ||
      left.parts.length != right.parts.length) {
    return false;
  }
  for (var index = 0; index < left.parts.length; index += 1) {
    final a = left.parts[index];
    final b = right.parts[index];
    if (a.part != b.part ||
        a.status != b.status ||
        a.currentRevisionId != b.currentRevisionId ||
        a.revision != b.revision) {
      return false;
    }
  }
  return true;
}

String _sectionKeyFor(String workId) {
  final normalized = workId.trim().toLowerCase().replaceAll(
    RegExp('[^a-z0-9_-]'),
    '_',
  );
  final suffix = normalized.isEmpty ? 'work' : normalized;
  final prefix = suffix.substring(0, suffix.length > 21 ? 21 : suffix.length);
  return 'w_${prefix}_${_stableHash(workId)}';
}

String _stableHash(String value) {
  var hash = 0x811c9dc5;
  for (final codeUnit in value.codeUnits) {
    hash ^= codeUnit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}

String? _nonEmpty(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}

MobileBookWorkResult<T> _accountRequired<T>() =>
    MobileBookWorkResult<T>.unavailable('BOOK_WORK_ACCOUNT_REQUIRED');

MobileBookWorkResult<T> _accountChanged<T>() =>
    MobileBookWorkResult<T>.failure('BOOK_WORK_ACCOUNT_CHANGED');

MobileBookWorkResult<T> _idempotencyConflict<T>() =>
    MobileBookWorkResult<T>.failure('BOOK_WORK_IDEMPOTENCY_CONFLICT');

MobileBookWorkResult<T> _mutationInProgress<T>() =>
    MobileBookWorkResult<T>.failure('BOOK_WORK_MUTATION_IN_PROGRESS');

final class _MobileBookWorkBinding {
  const _MobileBookWorkBinding({
    required this.generation,
    required this.workspaceId,
  });

  final int generation;
  final String workspaceId;
}

final class _PendingMobileBookWorkMutation {
  const _PendingMobileBookWorkMutation({
    required this.intent,
    required this.idempotencyKey,
  });

  final String intent;
  final String idempotencyKey;
}
