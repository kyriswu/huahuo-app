// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';

import 'package:huahuo_api/huahuo_api.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'knowledge_library_controller.dart';

enum MobileNoteRelationType { causal, supports, contradicts, similar }

enum MobileNoteRelationOrigin { explicit, automatic }

enum MobileNoteRelationStatus {
  idle,
  loading,
  loaded,
  loadingMore,
  unavailable,
  failure,
}

enum MobileNoteRelationOperationStatus {
  success,
  conflict,
  unavailable,
  failure,
}

@immutable
final class MobileNotePartRef {
  const MobileNotePartRef({
    required this.noteId,
    required this.part,
    required this.partRevisionId,
  });

  final String noteId;
  final String part;
  final String partRevisionId;
}

@immutable
final class MobileNoteRelation {
  const MobileNoteRelation({
    required this.relationId,
    required this.type,
    required this.origin,
    required this.source,
    required this.target,
    this.rationale,
    this.score,
    this.version,
    this.etag,
  });

  final String relationId;
  final MobileNoteRelationType type;
  final MobileNoteRelationOrigin origin;
  final MobileNotePartRef source;
  final MobileNotePartRef target;
  final String? rationale;
  final double? score;
  final int? version;
  final String? etag;

  bool get isMutable =>
      origin == MobileNoteRelationOrigin.explicit &&
      type != MobileNoteRelationType.similar &&
      version != null &&
      etag != null;
}

@immutable
final class MobileNoteRelationPageResult {
  const MobileNoteRelationPageResult._({
    required this.status,
    this.items = const <MobileNoteRelation>[],
    this.nextCursor,
    this.errorCode,
  });

  const MobileNoteRelationPageResult.success(
    List<MobileNoteRelation> items, {
    String? nextCursor,
  }) : this._(
         status: MobileNoteRelationOperationStatus.success,
         items: items,
         nextCursor: nextCursor,
       );

  const MobileNoteRelationPageResult.unavailable(String errorCode)
    : this._(
        status: MobileNoteRelationOperationStatus.unavailable,
        errorCode: errorCode,
      );

  const MobileNoteRelationPageResult.failure(String errorCode)
    : this._(
        status: MobileNoteRelationOperationStatus.failure,
        errorCode: errorCode,
      );

  final MobileNoteRelationOperationStatus status;
  final List<MobileNoteRelation> items;
  final String? nextCursor;
  final String? errorCode;
}

@immutable
final class MobileNoteRelationMutationResult {
  const MobileNoteRelationMutationResult._({
    required this.status,
    this.errorCode,
  });

  const MobileNoteRelationMutationResult.success()
    : this._(status: MobileNoteRelationOperationStatus.success);

  const MobileNoteRelationMutationResult.conflict([String? errorCode])
    : this._(
        status: MobileNoteRelationOperationStatus.conflict,
        errorCode: errorCode ?? 'NOTE_RELATION_VERSION_CONFLICT',
      );

  const MobileNoteRelationMutationResult.unavailable(String errorCode)
    : this._(
        status: MobileNoteRelationOperationStatus.unavailable,
        errorCode: errorCode,
      );

  const MobileNoteRelationMutationResult.failure(String errorCode)
    : this._(
        status: MobileNoteRelationOperationStatus.failure,
        errorCode: errorCode,
      );

  final MobileNoteRelationOperationStatus status;
  final String? errorCode;
}

abstract interface class MobileNoteRelationPort {
  Future<MobileNoteRelationPageResult> loadPage({
    required String noteId,
    String? cursor,
  });

  Future<MobileNoteRelationMutationResult> create({
    required String noteId,
    required MobileNoteRelationType type,
    required MobileNotePartRef source,
    required MobileNotePartRef target,
    required String rationale,
    required String actionId,
  });

  Future<MobileNoteRelationMutationResult> update({
    required MobileNoteRelation relation,
    MobileNoteRelationType? type,
    MobileNotePartRef? target,
    String? rationale,
    required String actionId,
  });

  Future<MobileNoteRelationMutationResult> delete({
    required MobileNoteRelation relation,
    required String actionId,
  });
}

final class UnavailableMobileNoteRelationPort
    implements MobileNoteRelationPort {
  const UnavailableMobileNoteRelationPort();

  MobileNoteRelationMutationResult get _unavailable =>
      const MobileNoteRelationMutationResult.unavailable(
        'NOTE_RELATION_SERVICE_UNAVAILABLE',
      );

  @override
  Future<MobileNoteRelationMutationResult> create({
    required String noteId,
    required MobileNoteRelationType type,
    required MobileNotePartRef source,
    required MobileNotePartRef target,
    required String rationale,
    required String actionId,
  }) async => _unavailable;

  @override
  Future<MobileNoteRelationMutationResult> delete({
    required MobileNoteRelation relation,
    required String actionId,
  }) async => _unavailable;

  @override
  Future<MobileNoteRelationPageResult> loadPage({
    required String noteId,
    String? cursor,
  }) async => const MobileNoteRelationPageResult.unavailable(
    'NOTE_RELATION_SERVICE_UNAVAILABLE',
  );

  @override
  Future<MobileNoteRelationMutationResult> update({
    required MobileNoteRelation relation,
    MobileNoteRelationType? type,
    MobileNotePartRef? target,
    String? rationale,
    required String actionId,
  }) async => _unavailable;
}

final class RemoteMobileNoteRelationPort implements MobileNoteRelationPort {
  factory RemoteMobileNoteRelationPort({
    required ApiClient apiClient,
    required String? Function() workspaceId,
  }) => RemoteMobileNoteRelationPort._(
    client: WorkspaceContentClient(apiClient),
    workspaceId: workspaceId,
  );

  const RemoteMobileNoteRelationPort._({
    required WorkspaceContentClient client,
    required String? Function() workspaceId,
  }) : _client = client,
       _workspaceId = workspaceId;

  final WorkspaceContentClient _client;
  final String? Function() _workspaceId;

  @override
  Future<MobileNoteRelationPageResult> loadPage({
    required String noteId,
    String? cursor,
  }) async {
    final workspaceId = _activeWorkspaceId();
    if (workspaceId == null) return _relationPageUnavailable();
    try {
      final response = await _client.noteRelationPage(
        workspaceId,
        noteId,
        cursor: cursor,
        limit: 50,
      );
      final page = response.data;
      if (!response.ok || page == null) return _relationPageFailure(response);
      return MobileNoteRelationPageResult.success(
        List<MobileNoteRelation>.unmodifiable(page.items.map(_mapRelation)),
        nextCursor: page.nextCursor,
      );
    } on FormatException {
      return const MobileNoteRelationPageResult.failure(
        'NOTE_RELATION_RESPONSE_INVALID',
      );
    } on Object {
      return const MobileNoteRelationPageResult.failure(
        'NOTE_RELATION_LOAD_FAILED',
      );
    }
  }

  @override
  Future<MobileNoteRelationMutationResult> create({
    required String noteId,
    required MobileNoteRelationType type,
    required MobileNotePartRef source,
    required MobileNotePartRef target,
    required String rationale,
    required String actionId,
  }) async {
    final workspaceId = _activeWorkspaceId();
    if (workspaceId == null) return _relationUnavailable();
    try {
      final response = await _client.createNoteRelation(
        workspaceId,
        noteId,
        request: SharedCreateExplicitNoteRelationRequest(
          relationType: type.name,
          source: SharedNotePartRevisionRef(
            part: source.part,
            partRevisionId: source.partRevisionId,
          ),
          target: _sharedPartRef(target),
          rationale: rationale,
        ),
        idempotencyKey: _relationIdempotencyKey(workspaceId, actionId),
      );
      return _validateReceipt(response, workspaceId: workspaceId);
    } on ArgumentError {
      return const MobileNoteRelationMutationResult.failure(
        'NOTE_RELATION_INPUT_INVALID',
      );
    } on Object {
      return const MobileNoteRelationMutationResult.failure(
        'NOTE_RELATION_CREATE_FAILED',
      );
    }
  }

  @override
  Future<MobileNoteRelationMutationResult> update({
    required MobileNoteRelation relation,
    MobileNoteRelationType? type,
    MobileNotePartRef? target,
    String? rationale,
    required String actionId,
  }) async {
    final workspaceId = _activeWorkspaceId();
    if (workspaceId == null) return _relationUnavailable();
    final etag = _nonEmpty(relation.etag);
    if (!relation.isMutable || etag == null) {
      return const MobileNoteRelationMutationResult.failure(
        'NOTE_RELATION_IMMUTABLE',
      );
    }
    try {
      final response = await _client.updateNoteRelation(
        workspaceId,
        relation.relationId,
        request: SharedUpdateExplicitNoteRelationRequest(
          relationType: type?.name,
          target: target == null ? null : _sharedPartRef(target),
          rationale: rationale,
        ),
        etag: etag,
        idempotencyKey: _relationIdempotencyKey(workspaceId, actionId),
      );
      return _validateReceipt(
        response,
        workspaceId: workspaceId,
        expectedRelationId: relation.relationId,
      );
    } on ArgumentError {
      return const MobileNoteRelationMutationResult.failure(
        'NOTE_RELATION_INPUT_INVALID',
      );
    } on Object {
      return const MobileNoteRelationMutationResult.failure(
        'NOTE_RELATION_UPDATE_FAILED',
      );
    }
  }

  @override
  Future<MobileNoteRelationMutationResult> delete({
    required MobileNoteRelation relation,
    required String actionId,
  }) async {
    final workspaceId = _activeWorkspaceId();
    if (workspaceId == null) return _relationUnavailable();
    final etag = _nonEmpty(relation.etag);
    if (!relation.isMutable || etag == null) {
      return const MobileNoteRelationMutationResult.failure(
        'NOTE_RELATION_IMMUTABLE',
      );
    }
    try {
      final response = await _client.deleteNoteRelation(
        workspaceId,
        relation.relationId,
        etag: etag,
        idempotencyKey: _relationIdempotencyKey(workspaceId, actionId),
      );
      return _validateReceipt(
        response,
        workspaceId: workspaceId,
        expectedRelationId: relation.relationId,
      );
    } on Object {
      return const MobileNoteRelationMutationResult.failure(
        'NOTE_RELATION_DELETE_FAILED',
      );
    }
  }

  String? _activeWorkspaceId() {
    final normalized = _workspaceId()?.trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }
}

@immutable
final class MobileNoteRelationBinding {
  const MobileNoteRelationBinding({
    required this.noteId,
    required this.sourcePartRevisionId,
  });

  final String? noteId;
  final String? sourcePartRevisionId;

  @override
  bool operator ==(Object other) =>
      other is MobileNoteRelationBinding &&
      other.noteId == noteId &&
      other.sourcePartRevisionId == sourcePartRevisionId;

  @override
  int get hashCode => Object.hash(noteId, sourcePartRevisionId);
}

// resident-provider: Shares one mobile note relation port dependency for the full account session.
final mobileNoteRelationPortProvider = Provider<MobileNoteRelationPort>((ref) {
  return const UnavailableMobileNoteRelationPort();
});

final noteRelationControllerProvider = ChangeNotifierProvider.autoDispose
    .family<NoteRelationController, String>((ref, localNoteId) {
      final binding = ref.watch(
        knowledgeLibraryControllerProvider.select((controller) {
          final note = controller.noteForId(localNoteId);
          return MobileNoteRelationBinding(
            noteId: note?.remoteNoteId,
            sourcePartRevisionId: note?.rawPartRevisionId,
          );
        }),
      );
      final controller = NoteRelationController(
        binding: () => binding,
        port: ref.watch(mobileNoteRelationPortProvider),
      );
      unawaited(controller.load());
      return controller;
    });

final class NoteRelationController extends ChangeNotifier {
  NoteRelationController({
    required MobileNoteRelationBinding Function() binding,
    required MobileNoteRelationPort port,
  }) : _binding = binding,
       _port = port;

  final MobileNoteRelationBinding Function() _binding;
  final MobileNoteRelationPort _port;
  final List<MobileNoteRelation> _relations = <MobileNoteRelation>[];
  final Set<String> _seenCursors = <String>{};
  final Set<String> _operationsInFlight = <String>{};
  final Map<String, String> _pendingActionIds = <String, String>{};
  int _actionSequence = 0;
  int _loadSequence = 0;
  MobileNoteRelationStatus _status = MobileNoteRelationStatus.idle;
  String? _nextCursor;
  String? _errorCode;
  String? _conflictRelationId;
  bool _disposed = false;

  MobileNoteRelationStatus get status => _status;
  List<MobileNoteRelation> get relations =>
      List<MobileNoteRelation>.unmodifiable(_relations);
  String? get errorCode => _errorCode;
  String? get conflictRelationId => _conflictRelationId;
  bool get hasMore => _nextCursor != null;
  bool isOperationInFlight(String key) => _operationsInFlight.contains(key);

  Future<void> load() async {
    if (_disposed) return;
    final sequence = ++_loadSequence;
    _relations.clear();
    _seenCursors.clear();
    _nextCursor = null;
    await _loadPage(reset: true, sequence: sequence);
  }

  Future<void> loadMore() async {
    if (_disposed ||
        _nextCursor == null ||
        _status == MobileNoteRelationStatus.loadingMore) {
      return;
    }
    await _loadPage(reset: false, sequence: _loadSequence);
  }

  Future<MobileNoteRelationMutationResult> create({
    required MobileNoteRelationType type,
    required MobileNotePartRef target,
    required String rationale,
  }) async {
    final binding = _binding();
    final noteId = _nonEmpty(binding.noteId);
    final sourceRevision = _nonEmpty(binding.sourcePartRevisionId);
    final normalizedRationale = rationale.trim();
    if (noteId == null || sourceRevision == null) return _contextUnavailable();
    if (!_isExplicitType(type) ||
        target.noteId.trim().isEmpty ||
        normalizedRationale.isEmpty) {
      return const MobileNoteRelationMutationResult.failure(
        'NOTE_RELATION_INPUT_INVALID',
      );
    }
    final intent =
        'create:$noteId:$sourceRevision:${type.name}:${target.noteId}:'
        '${target.part}:${target.partRevisionId}:$normalizedRationale';
    return _runMutation(intent, () {
      return _port.create(
        noteId: noteId,
        type: type,
        source: MobileNotePartRef(
          noteId: noteId,
          part: 'raw',
          partRevisionId: sourceRevision,
        ),
        target: target,
        rationale: normalizedRationale,
        actionId: _actionId(intent),
      );
    });
  }

  Future<MobileNoteRelationMutationResult> update({
    required String relationId,
    MobileNoteRelationType? type,
    MobileNotePartRef? target,
    String? rationale,
  }) async {
    final relation = _findRelation(relationId);
    if (relation == null || !relation.isMutable) {
      return const MobileNoteRelationMutationResult.failure(
        'NOTE_RELATION_IMMUTABLE',
      );
    }
    if (type != null && !_isExplicitType(type)) {
      return const MobileNoteRelationMutationResult.failure(
        'NOTE_RELATION_TYPE_INVALID',
      );
    }
    final normalizedRationale = rationale?.trim();
    if (normalizedRationale != null && normalizedRationale.isEmpty) {
      return const MobileNoteRelationMutationResult.failure(
        'NOTE_RELATION_INPUT_INVALID',
      );
    }
    final intent =
        'update:${relation.relationId}:${relation.etag}:${type?.name ?? ''}:'
        '${target?.noteId ?? ''}:${target?.partRevisionId ?? ''}:'
        '${normalizedRationale ?? ''}';
    return _runMutation(intent, () {
      return _port.update(
        relation: relation,
        type: type,
        target: target,
        rationale: normalizedRationale,
        actionId: _actionId(intent),
      );
    }, conflictRelationId: relation.relationId);
  }

  Future<MobileNoteRelationMutationResult> delete(String relationId) async {
    final relation = _findRelation(relationId);
    if (relation == null || !relation.isMutable) {
      return const MobileNoteRelationMutationResult.failure(
        'NOTE_RELATION_IMMUTABLE',
      );
    }
    final intent = 'delete:${relation.relationId}:${relation.etag}';
    return _runMutation(intent, () {
      return _port.delete(relation: relation, actionId: _actionId(intent));
    }, conflictRelationId: relation.relationId);
  }

  Future<void> _loadPage({required bool reset, required int sequence}) async {
    final noteId = _nonEmpty(_binding().noteId);
    if (noteId == null) {
      _status = MobileNoteRelationStatus.unavailable;
      _errorCode = 'NOTE_RELATION_NOTE_NOT_SYNCED';
      notifyListeners();
      return;
    }
    _status = reset
        ? MobileNoteRelationStatus.loading
        : MobileNoteRelationStatus.loadingMore;
    _errorCode = null;
    notifyListeners();
    MobileNoteRelationPageResult result;
    try {
      result = await _port.loadPage(noteId: noteId, cursor: _nextCursor);
    } on Object {
      result = const MobileNoteRelationPageResult.failure(
        'NOTE_RELATION_LOAD_FAILED',
      );
    }
    if (_disposed || sequence != _loadSequence) return;
    if (result.status != MobileNoteRelationOperationStatus.success) {
      _status = result.status == MobileNoteRelationOperationStatus.unavailable
          ? MobileNoteRelationStatus.unavailable
          : MobileNoteRelationStatus.failure;
      _errorCode = result.errorCode ?? 'NOTE_RELATION_LOAD_FAILED';
      notifyListeners();
      return;
    }
    final next = _nonEmpty(result.nextCursor);
    if (next != null && !_seenCursors.add(next)) {
      _status = MobileNoteRelationStatus.failure;
      _errorCode = 'NOTE_RELATION_CURSOR_INVALID';
      notifyListeners();
      return;
    }
    final existing = <String>{for (final item in _relations) item.relationId};
    for (final item in result.items) {
      if (existing.add(item.relationId)) _relations.add(item);
    }
    _nextCursor = next;
    _status = MobileNoteRelationStatus.loaded;
    _errorCode = null;
    notifyListeners();
  }

  Future<MobileNoteRelationMutationResult> _runMutation(
    String intent,
    Future<MobileNoteRelationMutationResult> Function() operation, {
    String? conflictRelationId,
  }) async {
    if (_disposed) {
      return const MobileNoteRelationMutationResult.failure(
        'NOTE_RELATION_CONTROLLER_DISPOSED',
      );
    }
    if (!_operationsInFlight.add(intent)) {
      return const MobileNoteRelationMutationResult.failure(
        'NOTE_RELATION_OPERATION_IN_PROGRESS',
      );
    }
    notifyListeners();
    MobileNoteRelationMutationResult result;
    try {
      result = await operation();
    } on Object {
      result = const MobileNoteRelationMutationResult.failure(
        'NOTE_RELATION_OPERATION_FAILED',
      );
    }
    _operationsInFlight.remove(intent);
    if (_disposed) return result;
    if (result.status == MobileNoteRelationOperationStatus.success) {
      _pendingActionIds.remove(intent);
      _conflictRelationId = null;
      await load();
    } else if (result.status == MobileNoteRelationOperationStatus.conflict) {
      _conflictRelationId = conflictRelationId;
    }
    notifyListeners();
    return result;
  }

  String _actionId(String intent) {
    return _pendingActionIds.putIfAbsent(intent, () {
      _actionSequence += 1;
      return 'note-relation:${DateTime.now().toUtc().microsecondsSinceEpoch}:'
          '$_actionSequence';
    });
  }

  MobileNoteRelation? _findRelation(String relationId) {
    for (final relation in _relations) {
      if (relation.relationId == relationId) return relation;
    }
    return null;
  }

  @override
  void dispose() {
    _disposed = true;
    _loadSequence += 1;
    super.dispose();
  }
}

bool _isExplicitType(MobileNoteRelationType value) =>
    value != MobileNoteRelationType.similar;

MobileNoteRelationMutationResult _contextUnavailable() =>
    const MobileNoteRelationMutationResult.unavailable(
      'NOTE_RELATION_NOTE_NOT_SYNCED',
    );

String? _nonEmpty(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}

MobileNoteRelation _mapRelation(SharedNoteRelation relation) {
  if (relation case final SharedExplicitNoteRelation explicit) {
    return MobileNoteRelation(
      relationId: explicit.relationId,
      type: _relationType(explicit.relationType),
      origin: MobileNoteRelationOrigin.explicit,
      source: _mobilePartRef(explicit.source),
      target: _mobilePartRef(explicit.target),
      rationale: explicit.rationale,
      version: explicit.version,
      etag: explicit.etag,
    );
  }
  final automatic = relation as SharedAutomaticNoteRelation;
  return MobileNoteRelation(
    relationId: automatic.relationId,
    type: MobileNoteRelationType.similar,
    origin: MobileNoteRelationOrigin.automatic,
    source: _mobilePartRef(automatic.source),
    target: _mobilePartRef(automatic.target),
    score: automatic.score,
  );
}

MobileNoteRelationType _relationType(String value) => switch (value) {
  'causal' => MobileNoteRelationType.causal,
  'supports' => MobileNoteRelationType.supports,
  'contradicts' => MobileNoteRelationType.contradicts,
  _ => throw const FormatException('Unsupported relation type'),
};

MobileNotePartRef _mobilePartRef(SharedNotePartSourceRef value) =>
    MobileNotePartRef(
      noteId: value.noteId,
      part: value.part,
      partRevisionId: value.partRevisionId,
    );

SharedNotePartSourceRef _sharedPartRef(MobileNotePartRef value) =>
    SharedNotePartSourceRef(
      noteId: value.noteId,
      part: value.part,
      partRevisionId: value.partRevisionId,
    );

MobileNoteRelationPageResult _relationPageUnavailable() =>
    const MobileNoteRelationPageResult.unavailable(
      'WORKSPACE_CONTEXT_UNAVAILABLE',
    );

MobileNoteRelationMutationResult _relationUnavailable() =>
    const MobileNoteRelationMutationResult.unavailable(
      'WORKSPACE_CONTEXT_UNAVAILABLE',
    );

MobileNoteRelationPageResult _relationPageFailure(ApiResult<Object?> result) {
  final code = result.error?.code ?? 'NOTE_RELATION_LOAD_FAILED';
  return _isRelationUnavailable(code)
      ? MobileNoteRelationPageResult.unavailable(code)
      : MobileNoteRelationPageResult.failure(code);
}

MobileNoteRelationMutationResult _validateReceipt(
  ApiResult<SharedWorkspaceContentEvent> result, {
  required String workspaceId,
  String? expectedRelationId,
}) {
  if (result.status == 412 || result.error?.code == 'PRECONDITION_FAILED') {
    return MobileNoteRelationMutationResult.conflict(result.error?.code);
  }
  final event = result.data;
  if (!result.ok || event == null) {
    final code = result.error?.code ?? 'NOTE_RELATION_OPERATION_FAILED';
    return _isRelationUnavailable(code)
        ? MobileNoteRelationMutationResult.unavailable(code)
        : MobileNoteRelationMutationResult.failure(code);
  }
  if (event.workspaceId != workspaceId ||
      event.objectKind != 'note_relation' ||
      event.version == null ||
      (expectedRelationId != null && event.objectId != expectedRelationId)) {
    return const MobileNoteRelationMutationResult.failure(
      'NOTE_RELATION_RECEIPT_INVALID',
    );
  }
  return const MobileNoteRelationMutationResult.success();
}

bool _isRelationUnavailable(String code) =>
    code == 'WORKSPACE_CONTEXT_UNAVAILABLE' ||
    code == 'API_BASE_URL_UNCONFIGURED' ||
    code.endsWith('_UNAVAILABLE');

String _relationIdempotencyKey(String workspaceId, String actionId) {
  final digest = sha256.convert(
    utf8.encode('mobile-note-relation:$workspaceId:$actionId'),
  );
  return 'mobile-note-relation-$digest';
}
