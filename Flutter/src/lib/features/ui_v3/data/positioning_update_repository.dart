import 'dart:convert';

import 'package:huahuo_api/huahuo_api.dart'
    hide documentProposalCandidateMaxBytes;
import '../../../core/database/app_preferences_dao.dart';
import '../../chat/domain/assistant_runtime.dart';
import '../../chat/domain/chat_repository.dart';
import '../../chat/domain/chat_models.dart';
import '../domain/positioning_lifecycle.dart';
import 'document_change_proposal_api.dart';

final class PreferencePositioningUpdateStore
    implements PositioningUpdateStore, PositioningCompletionStore {
  PreferencePositioningUpdateStore(this.dao, String scope)
    : key = 'positioning.op.${positioningDigest(scope)}';

  final AppPreferencesDao dao;
  final String key;

  @override
  bool get basicCompleted =>
      dao.readValue(key.replaceFirst('positioning.op.', 'positioning.ok.')) ==
      'verified-completion-v1';

  @override
  Future<void> recordBasicCompletion() => dao.upsertValueDeferred(
    preferenceKey: key.replaceFirst('positioning.op.', 'positioning.ok.'),
    value: 'verified-completion-v1',
    updatedAt: DateTime.now().toUtc().toIso8601String(),
  );

  @override
  List<PositioningUpdateCheckpoint> load() {
    final raw = dao.readValue(key);
    if (raw == null) return [];
    return (jsonDecode(raw) as List)
        .map(
          (entry) => PositioningUpdateCheckpoint.fromJson(
            entry as Map<String, dynamic>,
          ),
        )
        .toList();
  }

  @override
  Future<void> save(List<PositioningUpdateCheckpoint> checkpoints) =>
      dao.upsertValueDeferred(
        preferenceKey: key,
        value: jsonEncode(checkpoints.map((entry) => entry.toJson()).toList()),
        updatedAt: DateTime.now().toUtc().toIso8601String(),
      );
}

final class RemotePositioningUpdateRepository implements PositioningUpdatePort {
  RemotePositioningUpdateRepository({
    required this.api,
    required this.workspaceId,
    required this.isCurrent,
    required this.assistantRuntime,
    required this.chats,
  }) : proposals = RemoteDocumentChangeProposalApi(
         apiClient: api,
         workspaceId: () {
           if (!isCurrent())
             throw const DocumentChangeProposalException(
               'POSITIONING_SCOPE_CHANGED',
             );
           return workspaceId;
         },
       );

  final ApiClient api;
  final String workspaceId;
  final bool Function() isCurrent;
  final AssistantRuntimePort assistantRuntime;
  final ChatRepository chats;
  final DocumentChangeProposalApiPort proposals;

  void _check() {
    if (!isCurrent())
      throw const DocumentChangeProposalException('POSITIONING_SCOPE_CHANGED');
  }

  @override
  Future<DocumentChangeProposalSnapshot?> latest() async {
    _check();
    final response = await api.request<Map<String, Object?>>(
      ApiRequestOptions<Map<String, Object?>>(
        endpointId: 'documentChangeProposals',
        pathParams: {'workspaceId': workspaceId},
        query: {
          'ownerKind': 'workspace_standard_file',
          'ownerId': positioningReportOwner,
          'limit': 1,
        },
        parseData: (value) => Map<String, Object?>.from(value as Map),
      ),
    );
    _check();
    if (!response.ok || response.data == null)
      throw DocumentChangeProposalException(
        response.error?.code ?? 'POSITIONING_PROPOSALS_UNAVAILABLE',
      );
    final items = response.data!['items'] as List;
    if (items.isEmpty) return null;
    final latest = DocumentChangeProposal.fromValue(items.first);
    if (!isPositioningProposal(latest))
      throw const DocumentChangeProposalException('POSITIONING_OWNER_MISMATCH');
    return get(latest.proposalId);
  }

  @override
  Future<DocumentChangeProposalSnapshot> get(String proposalId) async {
    _check();
    final result = await proposals.get(proposalId);
    _check();
    if (!isPositioningProposal(result.proposal))
      throw const DocumentChangeProposalException('POSITIONING_OWNER_MISMATCH');
    return result;
  }

  @override
  Future<String> runStatus(String runId) async {
    _check();
    final response = await assistantRuntime.readRun(
      handle: AssistantRunHandle(runId),
    );
    _check();
    final run = response.data;
    if (!response.ok || run == null)
      throw DocumentChangeProposalException(
        response.errorCode ?? 'POSITIONING_RUN_UNAVAILABLE',
      );
    if (run.workspaceId != workspaceId || run.handle.value != runId)
      throw const DocumentChangeProposalException('POSITIONING_SCOPE_MISMATCH');
    return run.status.name;
  }

  @override
  Future<bool> verifySource(DocumentChangeProposal proposal) async {
    final runId = positioningProposalSourceRunId(proposal);
    if (runId == null) return false;
    _check();
    final response = await assistantRuntime.readRun(
      handle: AssistantRunHandle(runId),
    );
    _check();
    final run = response.data;
    if (!response.ok || run == null)
      throw DocumentChangeProposalException(
        response.errorCode ?? 'POSITIONING_RUN_UNAVAILABLE',
      );
    if (run.handle.value != runId ||
        run.workspaceId != workspaceId ||
        run.status != AssistantRunStatus.succeeded ||
        run.completionQuality != AssistantCompletionQuality.normal ||
        run.conversationId == null)
      return false;
    final detail = await chats.getThreadDetail(threadId: run.conversationId!);
    _check();
    if (!detail.ok || detail.data == null)
      throw DocumentChangeProposalException(
        detail.error?.code ?? 'POSITIONING_THREAD_UNAVAILABLE',
      );
    final thread = detail.data!.thread;
    return thread.threadId == run.conversationId &&
        thread.workspaceId == workspaceId &&
        thread.scene == ChatScene.workAi &&
        const {
          'positioning_lv1',
          'positioning_lv2',
        }.contains(thread.agentProfileId);
  }

  @override
  Future<String> candidateDigest(DocumentChangeProposal proposal) async {
    final text = StringBuffer();
    final cursors = <String>{};
    String? cursor;
    String? hash;
    var offset = 0;
    do {
      _check();
      final chunk = await proposals.getCandidate(
        proposalId: proposal.proposalId,
        cursor: cursor,
      );
      _check();
      hash ??= chunk.candidateHash;
      if (chunk.proposalId != proposal.proposalId ||
          chunk.proposalVersion != proposal.proposalVersion ||
          chunk.candidateHash != hash ||
          chunk.offsetBytes != offset)
        throw const DocumentChangeProposalException(
          'POSITIONING_CANDIDATE_CHANGED',
        );
      offset += utf8.encode(chunk.text).length;
      if (offset > documentProposalCandidateMaxBytes)
        throw const DocumentChangeProposalException(
          'POSITIONING_CANDIDATE_TOO_LARGE',
        );
      text.write(chunk.text);
      cursor = chunk.nextCursor;
      if (cursor != null && (!cursors.add(cursor) || cursors.length > 512))
        throw const DocumentChangeProposalException(
          'POSITIONING_CANDIDATE_CURSOR_INVALID',
        );
    } while (cursor != null);
    final content = text.toString();
    if (hash != 'sha256:${positioningDigest(content)}')
      throw const DocumentChangeProposalException(
        'POSITIONING_CANDIDATE_HASH_INVALID',
      );
    return positioningContentDigest(content);
  }

  @override
  Future<DocumentChangeProposalSnapshot> apply(
    PositioningUpdateCheckpoint checkpoint,
  ) async {
    _check();
    final response = await proposals.apply(
      proposalId: checkpoint.proposalId!,
      etag: checkpoint.etag!,
      idempotencyKey: checkpoint.idempotencyKey!,
    );
    _check();
    return response;
  }
}
