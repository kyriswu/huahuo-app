import '../../../core/api/api_client.dart';
import 'note_file_agent_client.dart';

const _fayaInstruction =
    'Read the source faithfully and grow one genuinely new, well-supported '
    'viewpoint from it. Write the complete Markdown result to the germination '
    'file.';

final class FayaGerminationRequest {
  const FayaGerminationRequest({
    required this.noteId,
    required this.expectedRawPartRevisionId,
    required this.operationId,
  });

  final String noteId;
  final String expectedRawPartRevisionId;
  final String operationId;
}

final class FayaGerminationResult {
  const FayaGerminationResult({
    required this.markdown,
    required this.fileAgentRunId,
    required this.agentRunId,
    required this.agentProfileId,
    required this.sourcePartRevisionId,
    required this.germinationPartRevisionId,
  });

  final String markdown;
  final String fileAgentRunId;
  final String agentRunId;
  final String agentProfileId;
  final String sourcePartRevisionId;
  final String germinationPartRevisionId;
}

final class AcceptedFayaGerminationRun {
  const AcceptedFayaGerminationRun({
    required this.run,
    required this.agentProfileId,
  });

  final NoteFileAgentRunSnapshot run;
  final String agentProfileId;
}

final class FayaGerminationException implements Exception {
  const FayaGerminationException(this.code);

  final String code;

  @override
  String toString() => 'FayaGerminationException($code)';
}

/// Executes the server-owned Faya File-Agent writeback flow.
final class FayaGerminationClient {
  FayaGerminationClient({
    required ApiClient apiClient,
    required String? Function() workspaceId,
    Duration pollInterval = const Duration(seconds: 3),
    int maxPollAttempts = 200,
    Future<void> Function(Duration)? delay,
  }) : _fileAgent = NoteFileAgentClient(
         apiClient: apiClient,
         workspaceId: workspaceId,
         pollInterval: pollInterval,
         maxPollAttempts: maxPollAttempts,
         delay: delay,
       );

  final NoteFileAgentClient _fileAgent;

  Future<AcceptedFayaGerminationRun> submit(
    FayaGerminationRequest request,
  ) async {
    try {
      final fileRequest = await _fileRequest(request);
      final run = await _fileAgent.submit(fileRequest);
      return AcceptedFayaGerminationRun(
        run: run,
        agentProfileId: fileRequest.selector.agentProfileId,
      );
    } on FayaGerminationException {
      rethrow;
    } on NoteFileAgentException catch (error) {
      throw FayaGerminationException(_mapFileAgentFailure(error.code));
    }
  }

  Future<FayaGerminationResult> generate(FayaGerminationRequest request) async {
    try {
      final result = await _fileAgent.run(await _fileRequest(request));
      return FayaGerminationResult(
        markdown: result.markdown,
        fileAgentRunId: result.fileAgentRunId,
        agentRunId: result.agentRunId,
        agentProfileId: result.selector.agentProfileId,
        sourcePartRevisionId: result.inputPartRevisionId,
        germinationPartRevisionId: result.outputPartRevisionId,
      );
    } on FayaGerminationException {
      rethrow;
    } on NoteFileAgentException catch (error) {
      throw FayaGerminationException(_mapFileAgentFailure(error.code));
    }
  }

  Future<NoteFileAgentRequest> _fileRequest(
    FayaGerminationRequest request,
  ) async {
    final noteId = _required(request.noteId, 'FAYA_SOURCE_NOTE_REQUIRED');
    final expectedRaw = _required(
      request.expectedRawPartRevisionId,
      'FAYA_SOURCE_REVISION_REQUIRED',
    );
    final operationId = _required(
      request.operationId,
      'FAYA_OPERATION_REQUIRED',
    );
    final head = await _fileAgent.readCurrentNote(noteId);
    if (head.rawPartRevisionId != expectedRaw) {
      throw const FayaGerminationException('FAYA_SOURCE_REVISION_CHANGED');
    }
    final raw = await _fileAgent.readCurrentPart(noteId, NoteFileAgentPart.raw);
    if (raw.partRevisionId != expectedRaw) {
      throw const FayaGerminationException('FAYA_SOURCE_REVISION_CHANGED');
    }
    if (raw.markdown.trim().isEmpty) {
      throw const FayaGerminationException('FAYA_SOURCE_NOTE_EMPTY');
    }
    return NoteFileAgentRequest(
      noteId: noteId,
      inputPart: NoteFileAgentPart.raw,
      inputPartRevisionId: expectedRaw,
      targetPart: NoteFileAgentPart.germination,
      targetPartRevisionId: head.germinationPartRevisionId,
      instruction: _fayaInstruction,
      selector: const NoteFileAgentSelector(
        agentProfileId: 'faya_germination',
        skillProfileIds: <String>['viewpoint_germination'],
      ),
      idempotencyKey: 'faya-germination-$operationId',
    );
  }
}

String _required(String value, String code) =>
    value.trim().isEmpty ? throw FayaGerminationException(code) : value.trim();

String _mapFileAgentFailure(String code) => switch (code) {
  'NOTE_FILE_AGENT_WORKSPACE_REQUIRED' => 'FAYA_WORKSPACE_REQUIRED',
  'NOTE_FILE_AGENT_SOURCE_REVISION_CHANGED' => 'FAYA_SOURCE_REVISION_CHANGED',
  'NOTE_FILE_AGENT_NOTE_READ_FAILED' ||
  'NOTE_FILE_AGENT_PART_READ_FAILED' ||
  'NOTE_FILE_AGENT_PART_RESPONSE_INVALID' ||
  'NOTE_FILE_AGENT_RUN_MISMATCH' => 'FAYA_SOURCE_READ_FAILED',
  'NOTE_FILE_AGENT_CREATE_FAILED' ||
  'AGENT_PROFILE_NOT_SELECTABLE' ||
  'SKILL_SELECTION_NOT_CANDIDATE' => 'FAYA_RUN_SUBMIT_FAILED',
  'NOTE_FILE_AGENT_POLL_FAILED' ||
  'NOTE_FILE_AGENT_POLL_TIMEOUT' => 'FAYA_RUN_POLL_FAILED',
  'NOTE_PART_VERSION_CONFLICT' ||
  'NOTE_FILE_AGENT_CONFLICT' => 'FAYA_GERMINATION_CONFLICT',
  'NOTE_FILE_AGENT_OUTLINE_CHANGED' => 'FAYA_OUTLINE_CHANGED',
  'NOTE_FILE_AGENT_OUTPUT_EMPTY' ||
  'NOTE_FILE_AGENT_OUTPUT_REVISION_INVALID' ||
  'NOTE_FILE_AGENT_OUTPUT_REVISION_STALE' ||
  'NOTE_FILE_AGENT_SELECTOR_MISMATCH' => 'FAYA_RESULT_CONTRACT_INVALID',
  _ => code,
};
