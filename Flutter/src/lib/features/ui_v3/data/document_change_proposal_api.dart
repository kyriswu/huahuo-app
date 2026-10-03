import 'dart:convert';

import '../../../core/api/api_client.dart'
    hide
        documentProposalAgentProfileId,
        documentProposalInstructionMaxBytes,
        documentProposalSkillProfileIds;
import '../../../core/api/idempotency.dart'
    hide
        documentProposalAgentProfileId,
        documentProposalInstructionMaxBytes,
        documentProposalSkillProfileIds;
import '../domain/document_change_proposal_models.dart';

export '../domain/document_change_proposal_models.dart';

abstract interface class DocumentChangeProposalApiPort {
  Future<DocumentChangeProposalSnapshot> create(
    DocumentProposalCreateRequest request,
  );

  Future<DocumentChangeProposalSnapshot> get(String proposalId);

  Future<DocumentProposalDiffPage> getDiff({
    required String proposalId,
    String? cursor,
  });

  Future<DocumentProposalCandidateChunk> getCandidate({
    required String proposalId,
    String? cursor,
  });

  Future<DocumentChangeProposalSnapshot> apply({
    required String proposalId,
    required String etag,
    required String idempotencyKey,
  });

  Future<DocumentChangeProposalSnapshot> reject({
    required String proposalId,
    required String etag,
    required String idempotencyKey,
  });

  Future<DocumentChangeProposalSnapshot> cancel({
    required String proposalId,
    required String etag,
    required String idempotencyKey,
  });
}

final class RemoteDocumentChangeProposalApi
    implements DocumentChangeProposalApiPort {
  RemoteDocumentChangeProposalApi({
    required ApiClient apiClient,
    required String? Function() workspaceId,
  }) : _apiClient = apiClient,
       _workspaceId = workspaceId;

  final ApiClient _apiClient;
  final String? Function() _workspaceId;

  @override
  Future<DocumentChangeProposalSnapshot> create(
    DocumentProposalCreateRequest request,
  ) async {
    _validateCreateRequest(request);
    final result = await _apiClient.request<DocumentChangeProposal>(
      ApiRequestOptions<DocumentChangeProposal>(
        endpointId: 'createDocumentChangeProposal',
        pathParams: <String, Object>{'workspaceId': _workspaceIdOrThrow()},
        body: <String, Object?>{
          'target': <String, Object?>{
            'ownerRef': <String, Object>{'kind': 'hnote', 'id': request.noteId},
            'part': 'raw',
            'partRevisionId': request.rawPartRevisionId,
          },
          'instruction': request.instruction.trim(),
          'agentProfileId': documentProposalAgentProfileId,
          'skillProfileIds': documentProposalSkillProfileIds,
          if (_optionalId(request.threadId) case final threadId?)
            'threadId': threadId,
        },
        idempotency: IdempotencyRequestContext(
          explicitKey: request.idempotencyKey,
        ),
        parseData: DocumentChangeProposal.fromValue,
      ),
    );
    return _snapshotFromResult(result, 'DOCUMENT_PROPOSAL_CREATE_FAILED');
  }

  @override
  Future<DocumentChangeProposalSnapshot> get(String proposalId) async {
    final result = await _apiClient.request<DocumentChangeProposal>(
      ApiRequestOptions<DocumentChangeProposal>(
        endpointId: 'documentChangeProposal',
        pathParams: <String, Object>{
          'workspaceId': _workspaceIdOrThrow(),
          'proposalId': _requireId(proposalId, 'proposalId'),
        },
        parseData: DocumentChangeProposal.fromValue,
      ),
    );
    return _snapshotFromResult(result, 'DOCUMENT_PROPOSAL_READ_FAILED');
  }

  @override
  Future<DocumentProposalDiffPage> getDiff({
    required String proposalId,
    String? cursor,
  }) async {
    final result = await _apiClient.request<DocumentProposalDiffPage>(
      ApiRequestOptions<DocumentProposalDiffPage>(
        endpointId: 'documentChangeProposalDiff',
        pathParams: <String, Object>{
          'workspaceId': _workspaceIdOrThrow(),
          'proposalId': _requireId(proposalId, 'proposalId'),
        },
        query: <String, Object?>{
          'limit': 50,
          if (_optionalCursorValue(cursor) case final value?) 'cursor': value,
        },
        parseData: DocumentProposalDiffPage.fromValue,
      ),
    );
    return _dataOrThrow(result, 'DOCUMENT_PROPOSAL_DIFF_FAILED');
  }

  @override
  Future<DocumentProposalCandidateChunk> getCandidate({
    required String proposalId,
    String? cursor,
  }) async {
    final result = await _apiClient.request<DocumentProposalCandidateChunk>(
      ApiRequestOptions<DocumentProposalCandidateChunk>(
        endpointId: 'documentChangeProposalCandidate',
        pathParams: <String, Object>{
          'workspaceId': _workspaceIdOrThrow(),
          'proposalId': _requireId(proposalId, 'proposalId'),
        },
        query: <String, Object?>{
          if (_optionalCursorValue(cursor) case final value?) 'cursor': value,
        },
        parseData: DocumentProposalCandidateChunk.fromValue,
      ),
    );
    return _dataOrThrow(result, 'DOCUMENT_PROPOSAL_CANDIDATE_FAILED');
  }

  @override
  Future<DocumentChangeProposalSnapshot> apply({
    required String proposalId,
    required String etag,
    required String idempotencyKey,
  }) => _mutate(
    endpointId: 'applyDocumentChangeProposal',
    proposalId: proposalId,
    etag: etag,
    idempotencyKey: idempotencyKey,
  );

  @override
  Future<DocumentChangeProposalSnapshot> reject({
    required String proposalId,
    required String etag,
    required String idempotencyKey,
  }) => _mutate(
    endpointId: 'rejectDocumentChangeProposal',
    proposalId: proposalId,
    etag: etag,
    idempotencyKey: idempotencyKey,
    body: const <String, Object>{'reasonCode': 'user_declined'},
  );

  @override
  Future<DocumentChangeProposalSnapshot> cancel({
    required String proposalId,
    required String etag,
    required String idempotencyKey,
  }) => _mutate(
    endpointId: 'cancelDocumentChangeProposal',
    proposalId: proposalId,
    etag: etag,
    idempotencyKey: idempotencyKey,
  );

  Future<DocumentChangeProposalSnapshot> _mutate({
    required String endpointId,
    required String proposalId,
    required String etag,
    required String idempotencyKey,
    Object? body,
  }) async {
    final normalizedProposalId = _requireId(proposalId, 'proposalId');
    if (!_isStrongProposalEtag(etag, normalizedProposalId)) {
      throw const DocumentChangeProposalException(
        'DOCUMENT_PROPOSAL_ETAG_REQUIRED',
      );
    }
    if (_optionalId(idempotencyKey) == null) {
      throw const DocumentChangeProposalException('IDEMPOTENCY_KEY_REQUIRED');
    }
    final result = await _apiClient.request<DocumentChangeProposal>(
      ApiRequestOptions<DocumentChangeProposal>(
        endpointId: endpointId,
        pathParams: <String, Object>{
          'workspaceId': _workspaceIdOrThrow(),
          'proposalId': normalizedProposalId,
        },
        headers: <String, String>{'If-Match': etag},
        body: body,
        idempotency: IdempotencyRequestContext(explicitKey: idempotencyKey),
        parseData: DocumentChangeProposal.fromValue,
      ),
    );
    return _snapshotFromResult(result, 'DOCUMENT_PROPOSAL_MUTATION_FAILED');
  }

  DocumentChangeProposalSnapshot _snapshotFromResult(
    ApiResult<DocumentChangeProposal> result,
    String fallback,
  ) {
    final proposal = _dataOrThrow(result, fallback);
    final etag = _headerValue(result.responseHeaders, 'etag');
    if (!_isStrongProposalEtag(etag, proposal.proposalId)) {
      throw const DocumentChangeProposalException(
        'DOCUMENT_PROPOSAL_ETAG_MISSING',
      );
    }
    return DocumentChangeProposalSnapshot(proposal: proposal, etag: etag!);
  }

  T _dataOrThrow<T>(ApiResult<T> result, String fallback) {
    if (!result.ok || result.data == null) {
      throw DocumentChangeProposalException(result.error?.code ?? fallback);
    }
    return result.data!;
  }

  String _workspaceIdOrThrow() {
    final value = _optionalId(_workspaceId());
    if (value == null) {
      throw const DocumentChangeProposalException(
        'WORKSPACE_CONTEXT_UNAVAILABLE',
      );
    }
    return value;
  }
}

void _validateCreateRequest(DocumentProposalCreateRequest request) {
  if (_optionalId(request.noteId) == null ||
      _optionalId(request.rawPartRevisionId) == null ||
      _optionalId(request.idempotencyKey) == null) {
    throw const DocumentChangeProposalException(
      'DOCUMENT_PROPOSAL_REQUEST_INVALID',
    );
  }
  final instruction = request.instruction.trim();
  if (instruction.isEmpty ||
      utf8.encode(instruction).length > documentProposalInstructionMaxBytes) {
    throw const DocumentChangeProposalException(
      'DOCUMENT_PROPOSAL_INSTRUCTION_INVALID',
    );
  }
}

String _requireId(String value, String field) {
  final normalized = _optionalId(value);
  if (normalized == null) throw FormatException('$field is invalid');
  return normalized;
}

String? _optionalId(String? value) {
  final normalized = value?.trim();
  if (normalized == null || normalized.isEmpty || normalized.length > 128) {
    return null;
  }
  return RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(normalized) ? normalized : null;
}

String? _optionalCursorValue(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty || normalized.length > 4096
      ? null
      : normalized;
}

String? _headerValue(Map<String, String> headers, String name) {
  for (final entry in headers.entries) {
    if (entry.key.toLowerCase() == name.toLowerCase()) {
      return entry.value.trim();
    }
  }
  return null;
}

bool _isStrongProposalEtag(String? value, String proposalId) {
  if (value == null || value.startsWith('W/')) return false;
  return RegExp(
    '^"dcp:${RegExp.escape(proposalId)}:[1-9][0-9]*"'
    r'$',
  ).hasMatch(value);
}
