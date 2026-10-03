// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_client.dart';
import '../domain/feed_item_models.dart';
import 'knowledge_library_controller.dart';
import 'knowledge_note_port.dart';

enum MobileWorkspaceSearchStatus {
  demo,
  idle,
  debouncing,
  loading,
  success,
  unavailable,
  failure,
}

enum MobileWorkspaceSearchResultStatus { success, unavailable, failure }

@immutable
final class MobileWorkspaceSearchResult {
  const MobileWorkspaceSearchResult._({
    required this.status,
    this.notes = const <V3FeedItem>[],
    this.contentCursor,
    this.errorCode,
  });

  const MobileWorkspaceSearchResult.success(
    List<V3FeedItem> notes, {
    required String contentCursor,
  }) : this._(
         status: MobileWorkspaceSearchResultStatus.success,
         notes: notes,
         contentCursor: contentCursor,
       );

  const MobileWorkspaceSearchResult.unavailable(String errorCode)
    : this._(
        status: MobileWorkspaceSearchResultStatus.unavailable,
        errorCode: errorCode,
      );

  const MobileWorkspaceSearchResult.failure(String errorCode)
    : this._(
        status: MobileWorkspaceSearchResultStatus.failure,
        errorCode: errorCode,
      );

  final MobileWorkspaceSearchResultStatus status;
  final List<V3FeedItem> notes;
  final String? contentCursor;
  final String? errorCode;
}

abstract interface class MobileWorkspaceSearchPort {
  bool get isDemo;

  Future<MobileWorkspaceSearchResult> searchKeyword({
    required String query,
    required int limit,
  });
}

final class DemoMobileWorkspaceSearchPort implements MobileWorkspaceSearchPort {
  const DemoMobileWorkspaceSearchPort();

  @override
  bool get isDemo => true;

  @override
  Future<MobileWorkspaceSearchResult> searchKeyword({
    required String query,
    required int limit,
  }) async => const MobileWorkspaceSearchResult.unavailable(
    'WORKSPACE_SEARCH_DEMO_ONLY',
  );
}

final class RemoteMobileWorkspaceSearchPort
    implements MobileWorkspaceSearchPort {
  factory RemoteMobileWorkspaceSearchPort({
    required ApiClient apiClient,
    required String? Function() workspaceId,
  }) => RemoteMobileWorkspaceSearchPort._(
    client: WorkspaceContentClient(apiClient),
    workspaceId: workspaceId,
  );

  const RemoteMobileWorkspaceSearchPort._({
    required WorkspaceContentClient client,
    required String? Function() workspaceId,
  }) : _client = client,
       _workspaceId = workspaceId;

  final WorkspaceContentClient _client;
  final String? Function() _workspaceId;

  @override
  bool get isDemo => false;

  @override
  Future<MobileWorkspaceSearchResult> searchKeyword({
    required String query,
    required int limit,
  }) async {
    final workspaceId = _activeWorkspaceId();
    if (workspaceId == null) {
      return const MobileWorkspaceSearchResult.unavailable(
        'WORKSPACE_CONTEXT_UNAVAILABLE',
      );
    }
    try {
      final response = await _client.search(
        workspaceId,
        request: SharedWorkspaceSearchRequest.keyword(
          query: query,
          ownerKinds: const <String>['hnote'],
          noteParts: const <String>['raw'],
          limit: limit.clamp(1, 30),
        ),
      );
      final output = response.data;
      if (!response.ok || output == null) return _searchFailure(response);
      if (output.mode != 'keyword') {
        return const MobileWorkspaceSearchResult.failure(
          'WORKSPACE_SEARCH_RESPONSE_INVALID',
        );
      }
      if (output.keywordReadiness == 'unavailable') {
        return const MobileWorkspaceSearchResult.unavailable(
          'WORKSPACE_KEYWORD_SEARCH_UNAVAILABLE',
        );
      }
      final notes = <V3FeedItem>[];
      final seen = <String>{};
      for (final match in output.results) {
        if (match.ownerRef.workspaceId != workspaceId ||
            match.ownerRef.kind != 'hnote') {
          return const MobileWorkspaceSearchResult.failure(
            'WORKSPACE_SEARCH_OWNER_INVALID',
          );
        }
        if (!seen.add('${match.ownerRef.id}:${match.revisionId}')) continue;
        if (match.part != 'raw') {
          return const MobileWorkspaceSearchResult.failure(
            'WORKSPACE_SEARCH_PART_INVALID',
          );
        }
        if (match.staleSource) {
          return const MobileWorkspaceSearchResult.failure(
            'WORKSPACE_SEARCH_SOURCE_STALE',
          );
        }
        final exact = await _client.note(
          workspaceId,
          match.ownerRef.id,
          revisionId: match.revisionId,
        );
        final note = exact.data;
        if (!exact.ok || note == null) return _searchFailure(exact);
        if (note.noteId != match.ownerRef.id ||
            note.workspaceId != workspaceId) {
          return const MobileWorkspaceSearchResult.failure(
            'WORKSPACE_SEARCH_OWNER_INVALID',
          );
        }
        if (note.noteRevisionId != match.revisionId) {
          return const MobileWorkspaceSearchResult.failure(
            'WORKSPACE_SEARCH_REVISION_MISMATCH',
          );
        }
        final complete = await _hydrateExactHNote(workspaceId, note);
        notes.add(
          mapRemoteHNoteToFeedItem(
            complete,
            localId: complete.noteId,
            legacyRemoteRevision: 0,
            fallback: V3FeedItem(
              id: complete.noteId,
              title: match.title ?? complete.title,
              source: V3MaterialSource.note,
              createdAt: match.updatedAt,
              updatedAt: match.updatedAt,
              rawBody: complete.raw.markdown,
            ),
          ),
        );
      }
      return MobileWorkspaceSearchResult.success(
        List<V3FeedItem>.unmodifiable(notes),
        contentCursor: output.contentCursor,
      );
    } on _WorkspaceSearchPartFailure catch (failure) {
      return _searchFailureCode(failure.code);
    } on ArgumentError {
      return const MobileWorkspaceSearchResult.failure(
        'WORKSPACE_SEARCH_INPUT_INVALID',
      );
    } on FormatException {
      return const MobileWorkspaceSearchResult.failure(
        'WORKSPACE_SEARCH_RESPONSE_INVALID',
      );
    } on Object {
      return const MobileWorkspaceSearchResult.failure(
        'WORKSPACE_SEARCH_FAILED',
      );
    }
  }

  Future<SharedHNote> _hydrateExactHNote(String workspaceId, SharedHNote note) {
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
              throw _WorkspaceSearchPartFailure(
                response.error?.code ?? 'WORKSPACE_SEARCH_FAILED',
              );
            }
            return view;
          },
    );
  }

  String? _activeWorkspaceId() {
    final normalized = _workspaceId()?.trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }
}

final class _WorkspaceSearchPartFailure implements Exception {
  const _WorkspaceSearchPartFailure(this.code);

  final String code;
}

// resident-provider: Shares one mobile workspace search port dependency for the full account session.
final mobileWorkspaceSearchPortProvider = Provider<MobileWorkspaceSearchPort>((
  ref,
) {
  return const DemoMobileWorkspaceSearchPort();
});

// resident-provider: Preserves the workspace search controller state machine across route transitions.
final workspaceSearchControllerProvider =
    ChangeNotifierProvider<WorkspaceSearchController>((ref) {
      return WorkspaceSearchController(
        port: ref.watch(mobileWorkspaceSearchPortProvider),
        library: ref.read(knowledgeLibraryControllerProvider),
      );
    });

final class WorkspaceSearchController extends ChangeNotifier {
  WorkspaceSearchController({
    required MobileWorkspaceSearchPort port,
    KnowledgeLibraryController? library,
    Duration debounce = const Duration(milliseconds: 350),
  }) : _port = port,
       _library = library,
       _debounce = debounce,
       _status = port.isDemo
           ? MobileWorkspaceSearchStatus.demo
           : MobileWorkspaceSearchStatus.idle;

  final MobileWorkspaceSearchPort _port;
  final KnowledgeLibraryController? _library;
  final Duration _debounce;
  Timer? _timer;
  int _sequence = 0;
  String _query = '';
  MobileWorkspaceSearchStatus _status;
  List<V3FeedItem> _results = const <V3FeedItem>[];
  String? _contentCursor;
  String? _errorCode;
  bool _disposed = false;

  MobileWorkspaceSearchStatus get status => _status;
  String get query => _query;
  List<V3FeedItem> get results => List<V3FeedItem>.unmodifiable(_results);
  String? get contentCursor => _contentCursor;
  String? get errorCode => _errorCode;
  bool get isRemote => _status != MobileWorkspaceSearchStatus.demo;

  void setQuery(String value) {
    final normalized = _normalizeQuery(value);
    if (_query == normalized &&
        _status != MobileWorkspaceSearchStatus.failure &&
        _status != MobileWorkspaceSearchStatus.unavailable) {
      return;
    }
    _query = normalized;
    _timer?.cancel();
    _sequence += 1;
    if (_port.isDemo) {
      _status = MobileWorkspaceSearchStatus.demo;
      notifyListeners();
      return;
    }
    if (normalized.isEmpty) {
      _status = MobileWorkspaceSearchStatus.idle;
      _results = const <V3FeedItem>[];
      _contentCursor = null;
      _errorCode = null;
      notifyListeners();
      return;
    }
    _status = MobileWorkspaceSearchStatus.debouncing;
    _errorCode = null;
    notifyListeners();
    final sequence = _sequence;
    _timer = Timer(_debounce, () {
      unawaited(_run(normalized, sequence));
    });
  }

  Future<void> retry() async {
    if (_query.isEmpty || _port.isDemo) return;
    _timer?.cancel();
    _sequence += 1;
    await _run(_query, _sequence);
  }

  Future<void> searchNow(String value) async {
    final normalized = _normalizeQuery(value);
    _timer?.cancel();
    _query = normalized;
    _sequence += 1;
    if (normalized.isEmpty || _port.isDemo) {
      setQuery(normalized);
      return;
    }
    await _run(normalized, _sequence);
  }

  Future<void> _run(String query, int sequence) async {
    if (_disposed || sequence != _sequence) return;
    _status = MobileWorkspaceSearchStatus.loading;
    _errorCode = null;
    notifyListeners();
    MobileWorkspaceSearchResult result;
    try {
      result = await _port.searchKeyword(query: query, limit: 30);
    } on Object {
      result = const MobileWorkspaceSearchResult.failure(
        'WORKSPACE_SEARCH_FAILED',
      );
    }
    if (_disposed || sequence != _sequence || query != _query) return;
    if (result.status != MobileWorkspaceSearchResultStatus.success) {
      _status = result.status == MobileWorkspaceSearchResultStatus.unavailable
          ? MobileWorkspaceSearchStatus.unavailable
          : MobileWorkspaceSearchStatus.failure;
      _results = const <V3FeedItem>[];
      _contentCursor = null;
      _errorCode = result.errorCode ?? 'WORKSPACE_SEARCH_FAILED';
      notifyListeners();
      return;
    }
    _results = List<V3FeedItem>.unmodifiable(
      _library == null
          ? result.notes
          : result.notes.map(_library.mergeRemoteNote),
    );
    _contentCursor = result.contentCursor;
    _errorCode = null;
    _status = MobileWorkspaceSearchStatus.success;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}

String _normalizeQuery(String value) =>
    value.trim().replaceAll(RegExp(r'\s+'), ' ');

MobileWorkspaceSearchResult _searchFailure(ApiResult<Object?> result) {
  return _searchFailureCode(result.error?.code ?? 'WORKSPACE_SEARCH_FAILED');
}

MobileWorkspaceSearchResult _searchFailureCode(String code) {
  return _isUnavailableCode(code)
      ? MobileWorkspaceSearchResult.unavailable(code)
      : MobileWorkspaceSearchResult.failure(code);
}

bool _isUnavailableCode(String code) =>
    code == 'WORKSPACE_CONTEXT_UNAVAILABLE' ||
    code == 'API_BASE_URL_UNCONFIGURED' ||
    code.endsWith('_UNAVAILABLE');
