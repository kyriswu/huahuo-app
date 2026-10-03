import 'dart:convert';

import '../api/api_client.dart';
import '../api/api_envelope.dart';
import '../api/idempotency.dart';
import 'document_proposal_models.dart';

final class DocumentProposalClient {
  const DocumentProposalClient(this._api);

  final ApiClient _api;

  Future<ApiResult<DocumentProposalPageDto>> list(
    String workspaceId, {
    String? ownerKind,
    String? ownerId,
    String? state,
    String? cursor,
  }) => _api.request<DocumentProposalPageDto>(
    ApiRequestOptions<DocumentProposalPageDto>(
      endpointId: 'documentChangeProposals',
      pathParams: _workspacePath(workspaceId),
      query: <String, Object?>{
        if (ownerKind != null) 'ownerKind': _ownerKind(ownerKind),
        if (ownerId != null) 'ownerId': _safeId(ownerId, 'ownerId'),
        if (state != null) 'state': _state(state),
        'limit': 50,
        if (cursor != null) 'cursor': _cursor(cursor),
      },
      parseData: DocumentProposalPageDto.fromValue,
    ),
  );

  Future<ApiResult<DocumentProposalSnapshotDto>> createForCreation(
    String workspaceId, {
    required String creationId,
    required String rawPartRevisionId,
    required String instruction,
    required String idempotencyKey,
    String? threadId,
  }) {
    final id = _safeId(creationId, 'creationId');
    return _snapshotRequest(
      endpointId: 'createDocumentChangeProposal',
      workspaceId: workspaceId,
      body: <String, Object?>{
        'target': <String, Object?>{
          'ownerRef': <String, Object>{'kind': 'creation', 'id': id},
          'part': 'raw',
          'partRevisionId': _safeId(rawPartRevisionId, 'rawPartRevisionId'),
        },
        'instruction': _instruction(instruction),
        'agentProfileId': documentProposalAgentProfileId,
        'skillProfileIds': documentProposalSkillProfileIds,
        if (threadId != null) 'threadId': _safeId(threadId, 'threadId'),
      },
      idempotencyKey: idempotencyKey,
    );
  }

  Future<ApiResult<DocumentProposalSnapshotDto>> detail(
    String workspaceId,
    String proposalId,
  ) {
    final id = _safeId(proposalId, 'proposalId');
    return _snapshotRequest(
      endpointId: 'documentChangeProposal',
      workspaceId: workspaceId,
      proposalId: id,
    );
  }

  Future<ApiResult<DocumentProposalDiffPageDto>> diff(
    String workspaceId,
    String proposalId, {
    int? proposalVersion,
    String? cursor,
  }) {
    final id = _safeId(proposalId, 'proposalId');
    final version = proposalVersion == null
        ? null
        : _positive(proposalVersion, 'proposalVersion');
    return _api.request<DocumentProposalDiffPageDto>(
      ApiRequestOptions<DocumentProposalDiffPageDto>(
        endpointId: version == null
            ? 'documentChangeProposalDiff'
            : 'documentChangeProposalVersionDiff',
        pathParams: <String, Object>{
          ..._workspacePath(workspaceId),
          'proposalId': id,
          if (version != null) 'proposalVersion': version,
        },
        query: <String, Object?>{
          'limit': 50,
          if (cursor != null) 'cursor': _cursor(cursor),
        },
        parseData: (value) => DocumentProposalDiffPageDto.fromValue(
          value,
          expectedId: id,
          expectedVersion: version,
        ),
      ),
    );
  }

  Future<ApiResult<DocumentProposalCandidateChunkDto>> candidate(
    String workspaceId,
    String proposalId, {
    int? proposalVersion,
    String? cursor,
  }) {
    final id = _safeId(proposalId, 'proposalId');
    final version = proposalVersion == null
        ? null
        : _positive(proposalVersion, 'proposalVersion');
    return _api.request<DocumentProposalCandidateChunkDto>(
      ApiRequestOptions<DocumentProposalCandidateChunkDto>(
        endpointId: version == null
            ? 'documentChangeProposalCandidate'
            : 'documentChangeProposalVersionCandidate',
        pathParams: <String, Object>{
          ..._workspacePath(workspaceId),
          'proposalId': id,
          if (version != null) 'proposalVersion': version,
        },
        query: <String, Object?>{if (cursor != null) 'cursor': _cursor(cursor)},
        parseData: (value) => DocumentProposalCandidateChunkDto.fromValue(
          value,
          expectedId: id,
          expectedVersion: version,
        ),
      ),
    );
  }

  Future<ApiResult<List<DocumentProposalVersionDto>>> versions(
    String workspaceId,
    String proposalId,
  ) {
    final id = _safeId(proposalId, 'proposalId');
    return _api.request<List<DocumentProposalVersionDto>>(
      ApiRequestOptions<List<DocumentProposalVersionDto>>(
        endpointId: 'documentChangeProposalVersions',
        pathParams: {..._workspacePath(workspaceId), 'proposalId': id},
        parseData: (value) {
          final json = value is Map<String, Object?> ? value : null;
          if (json == null ||
              json.keys.any((key) => key != 'items') ||
              json['items'] is! List<Object?>) {
            throw const FormatException('Invalid Proposal version page');
          }
          final raw = json['items']! as List<Object?>;
          if (raw.length > 500) {
            throw const FormatException('Invalid Proposal version count');
          }
          return List.unmodifiable(
            raw.map(
              (item) =>
                  DocumentProposalVersionDto.fromValue(item, expectedId: id),
            ),
          );
        },
      ),
    );
  }

  Future<ApiResult<DocumentProposalSnapshotDto>> apply(
    String workspaceId,
    String proposalId, {
    required String etag,
    required String idempotencyKey,
  }) => _mutation(
    endpointId: 'applyDocumentChangeProposal',
    workspaceId: workspaceId,
    proposalId: proposalId,
    etag: etag,
    idempotencyKey: idempotencyKey,
  );

  Future<ApiResult<DocumentProposalSnapshotDto>> reject(
    String workspaceId,
    String proposalId, {
    required String etag,
    required String idempotencyKey,
    String reasonCode = 'user_declined',
  }) {
    if (!const {
      'user_declined',
      'superseded_by_user_edit',
    }.contains(reasonCode)) {
      throw ArgumentError.value(reasonCode, 'reasonCode');
    }
    return _mutation(
      endpointId: 'rejectDocumentChangeProposal',
      workspaceId: workspaceId,
      proposalId: proposalId,
      etag: etag,
      idempotencyKey: idempotencyKey,
      body: <String, Object>{'reasonCode': reasonCode},
    );
  }

  Future<ApiResult<DocumentProposalSnapshotDto>> cancel(
    String workspaceId,
    String proposalId, {
    required String etag,
    required String idempotencyKey,
  }) => _mutation(
    endpointId: 'cancelDocumentChangeProposal',
    workspaceId: workspaceId,
    proposalId: proposalId,
    etag: etag,
    idempotencyKey: idempotencyKey,
  );

  Future<ApiResult<DocumentProposalSnapshotDto>> rebase(
    String workspaceId,
    String proposalId, {
    required String etag,
    required String idempotencyKey,
  }) => _mutation(
    endpointId: 'rebaseDocumentChangeProposal',
    workspaceId: workspaceId,
    proposalId: proposalId,
    etag: etag,
    idempotencyKey: idempotencyKey,
    body: const <String, Object>{'strategy': 'auto'},
  );

  Future<ApiResult<DocumentProposalSnapshotDto>> revise(
    String workspaceId,
    String proposalId, {
    required int baseProposalVersion,
    required String instruction,
    required String etag,
    required String idempotencyKey,
    List<({String diffBundleId, String hunkId, String quotedText})>
        selectedHunks =
        const [],
  }) => _mutation(
    endpointId: 'reviseDocumentChangeProposal',
    workspaceId: workspaceId,
    proposalId: proposalId,
    etag: etag,
    idempotencyKey: idempotencyKey,
    body: <String, Object?>{
      'baseProposalVersion': _positive(
        baseProposalVersion,
        'baseProposalVersion',
      ),
      'instruction': _instruction(instruction),
      'selectedHunks': <Object?>[
        for (final hunk in selectedHunks)
          <String, Object>{
            'proposalVersion': baseProposalVersion,
            'diffBundleId': _safeId(hunk.diffBundleId, 'diffBundleId'),
            'hunkId': _safeId(hunk.hunkId, 'hunkId'),
            'quotedText': _quotedText(hunk.quotedText),
          },
      ],
      'agentProfileId': documentProposalAgentProfileId,
      'skillProfileIds': documentProposalSkillProfileIds,
    },
  );

  Future<ApiResult<DocumentProposalSnapshotDto>> _mutation({
    required String endpointId,
    required String workspaceId,
    required String proposalId,
    required String etag,
    required String idempotencyKey,
    Object? body,
  }) {
    final id = _safeId(proposalId, 'proposalId');
    return _snapshotRequest(
      endpointId: endpointId,
      workspaceId: workspaceId,
      proposalId: id,
      headers: <String, String>{'If-Match': _etag(etag, id)},
      body: body,
      idempotencyKey: idempotencyKey,
    );
  }

  Future<ApiResult<DocumentProposalSnapshotDto>> _snapshotRequest({
    required String endpointId,
    required String workspaceId,
    String? proposalId,
    Map<String, String> headers = const {},
    Object? body,
    String? idempotencyKey,
  }) async {
    final id = proposalId == null ? null : _safeId(proposalId, 'proposalId');
    final result = await _api.request<DocumentProposalDto>(
      ApiRequestOptions<DocumentProposalDto>(
        endpointId: endpointId,
        pathParams: <String, Object>{
          ..._workspacePath(workspaceId),
          if (id != null) 'proposalId': id,
        },
        headers: headers,
        body: body,
        idempotency: idempotencyKey == null
            ? null
            : IdempotencyRequestContext(
                explicitKey: _idempotency(idempotencyKey),
              ),
        parseData: (value) =>
            DocumentProposalDto.fromValue(value, expectedId: id),
      ),
    );
    final proposal = result.data;
    if (!result.ok || proposal == null) {
      return ApiResult.failure(
        error: result.error!,
        status: result.status,
        traceId: result.traceId,
        authExpired: result.authExpired,
        retryAfterSeconds: result.retryAfterSeconds,
        idempotencyStore: result.idempotencyStore,
        responseHeaders: result.responseHeaders,
      );
    }
    final etag = _header(result.responseHeaders, 'etag');
    if (etag == null) {
      return ApiResult.failure(
        error: AppFailure(
          code: 'DOCUMENT_PROPOSAL_ETAG_MISSING',
          category: AppFailureCategory.api,
          message: 'Proposal ETag is missing',
          userMessageKey: 'api.error.responseInvalid',
          recoveryActions: const ['retry'],
        ),
        status: result.status,
        traceId: result.traceId,
        idempotencyStore: result.idempotencyStore,
        responseHeaders: result.responseHeaders,
      );
    }
    try {
      _etag(etag, proposal.proposalId, expectedRowVersion: proposal.rowVersion);
    } on FormatException {
      return ApiResult.failure(
        error: AppFailure(
          code: 'DOCUMENT_PROPOSAL_ETAG_INVALID',
          category: AppFailureCategory.api,
          message: 'Proposal ETag is invalid',
          userMessageKey: 'api.error.responseInvalid',
          recoveryActions: const ['retry'],
        ),
        status: result.status,
        traceId: result.traceId,
        idempotencyStore: result.idempotencyStore,
        responseHeaders: result.responseHeaders,
      );
    }
    return ApiResult.success(
      data: DocumentProposalSnapshotDto(proposal: proposal, etag: etag),
      status: result.status!,
      traceId: result.traceId,
      idempotencyStore: result.idempotencyStore,
      responseHeaders: result.responseHeaders,
    );
  }
}

Map<String, Object> _workspacePath(String value) => <String, Object>{
  'workspaceId': _safeId(value, 'workspaceId'),
};

String _safeId(String value, String field) {
  final normalized = value.trim();
  if (normalized.isEmpty ||
      normalized.length > 200 ||
      !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(normalized)) {
    throw ArgumentError.value(value, field, 'invalid identifier');
  }
  return normalized;
}

String _ownerKind(String value) {
  const allowed = {
    'hnote',
    'creation',
    'book_section',
    'work',
    'profile_conclusion',
    'workspace_standard_file',
  };
  if (!allowed.contains(value)) throw ArgumentError.value(value, 'ownerKind');
  return value;
}

String _state(String value) {
  DocumentProposalStateDto.parse(value);
  return value;
}

int _positive(int value, String field) {
  if (value < 1) throw ArgumentError.value(value, field);
  return value;
}

String _cursor(String value) {
  final normalized = value.trim();
  if (normalized.isEmpty || normalized.length > 4096) {
    throw ArgumentError.value(value, 'cursor');
  }
  return normalized;
}

String _instruction(String value) {
  final normalized = value.trim();
  if (normalized.isEmpty ||
      utf8.encode(normalized).length > documentProposalInstructionMaxBytes) {
    throw ArgumentError.value(value, 'instruction');
  }
  return normalized;
}

String _quotedText(String value) {
  if (utf8.encode(value).length > documentProposalInstructionMaxBytes) {
    throw ArgumentError.value(value, 'quotedText');
  }
  return value;
}

String _idempotency(String value) {
  final normalized = value.trim();
  if (normalized.isEmpty || normalized.length > 200) {
    throw ArgumentError.value(value, 'idempotencyKey');
  }
  return normalized;
}

String _etag(String value, String proposalId, {int? expectedRowVersion}) {
  final normalized = value.trim();
  final versionPattern = expectedRowVersion?.toString() ?? '[1-9][0-9]*';
  if (!RegExp(
    '^"dcp:${RegExp.escape(proposalId)}:$versionPattern"\$',
  ).hasMatch(normalized)) {
    throw const FormatException('Invalid Proposal ETag');
  }
  return normalized;
}

String? _header(Map<String, String> headers, String name) {
  final normalized = name.toLowerCase();
  for (final entry in headers.entries) {
    if (entry.key.toLowerCase() == normalized &&
        entry.value.trim().isNotEmpty) {
      return entry.value.trim();
    }
  }
  return null;
}
