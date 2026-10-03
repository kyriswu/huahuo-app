import 'digital_twin_models.dart';
import 'document_change_proposal_models.dart';

final class DigitalTwinConfirmationCommand {
  DigitalTwinConfirmationCommand({
    required this.idempotencyKey,
    required List<DocumentChangeProposalSnapshot> proposals,
    this.source,
  }) : proposals = List.unmodifiable(proposals);

  final String idempotencyKey;
  final List<DocumentChangeProposalSnapshot> proposals;
  final DigitalTwinImportSource? source;

  List<String> get proposalIds =>
      proposals.map((entry) => entry.proposal.proposalId).toList();

  Map<String, Object?> toJson() => {
    'idempotencyKey': idempotencyKey,
    'proposals': proposals.map(_snapshotToJson).toList(),
    if (source case final value?)
      'source': {
        'importTaskId': value.importTaskId,
        'taskId': value.taskId,
        'resourceId': value.resourceId,
        'noteId': value.noteId,
        'title': value.title,
        'confirmationTaskId': value.confirmationTaskId,
      },
  };

  factory DigitalTwinConfirmationCommand.fromJson(Map<String, Object?> value) {
    final source = value['source'] as Map?;
    return DigitalTwinConfirmationCommand(
      idempotencyKey: value['idempotencyKey']! as String,
      proposals: [
        for (final entry in value['proposals']! as List)
          _snapshotFromJson(Map<String, Object?>.from(entry as Map)),
      ],
      source: source == null
          ? null
          : DigitalTwinImportSource(
              importTaskId: source['importTaskId']! as String,
              taskId: source['taskId']! as String,
              resourceId: source['resourceId']! as String,
              noteId: source['noteId']! as String,
              title: source['title']! as String,
              confirmationTaskId: source['confirmationTaskId'] as String?,
            ),
    );
  }
}

enum DigitalTwinProposalOperation { revise, regenerate }

final class DigitalTwinRestoreCommand {
  const DigitalTwinRestoreCommand({
    required this.versionId,
    required this.idempotencyKey,
    this.receipt,
  });

  final String versionId;
  final String idempotencyKey;
  final DigitalTwinRestore? receipt;

  DigitalTwinRestoreCommand withReceipt(DigitalTwinRestore value) =>
      DigitalTwinRestoreCommand(
        versionId: versionId,
        idempotencyKey: idempotencyKey,
        receipt: value,
      );

  Map<String, Object?> toJson() => {
    'versionId': versionId,
    'idempotencyKey': idempotencyKey,
    if (receipt case final value?)
      'receipt': {
        'taskId': value.taskId,
        'versionId': value.versionId,
        'state': value.state,
        'proposalIds': value.proposalIds,
      },
  };

  factory DigitalTwinRestoreCommand.fromJson(Map<String, Object?> value) =>
      DigitalTwinRestoreCommand(
        versionId: value['versionId']! as String,
        idempotencyKey: value['idempotencyKey']! as String,
        receipt: value['receipt'] == null
            ? null
            : DigitalTwinRestore.fromValue(value['receipt']),
      );
}

final class DigitalTwinRevisionRecord {
  const DigitalTwinRevisionRecord({
    required this.command,
    required this.state,
    this.result,
  });
  final DigitalTwinProposalCommand command;
  final String state;
  final String? result;
}

final class DigitalTwinProposalCommand {
  DigitalTwinProposalCommand({
    required this.idempotencyKey,
    required this.operation,
    required this.proposal,
    required this.instruction,
    List<DigitalTwinSelectedHunk> selectedHunks = const [],
    this.receipt,
    this.preparedBody,
  }) : selectedHunks = List.unmodifiable(selectedHunks);

  final String idempotencyKey;
  final DigitalTwinProposalOperation operation;
  final DocumentChangeProposalSnapshot proposal;
  final String instruction;
  final List<DigitalTwinSelectedHunk> selectedHunks;
  final DocumentChangeProposalSnapshot? receipt;
  final Map<String, Object?>? preparedBody;

  String get currentProposalId =>
      receipt?.proposal.proposalId ?? proposal.proposal.proposalId;

  DigitalTwinProposalCommand withReceipt(
    DocumentChangeProposalSnapshot value,
  ) => DigitalTwinProposalCommand(
    idempotencyKey: idempotencyKey,
    operation: operation,
    proposal: proposal,
    instruction: instruction,
    selectedHunks: selectedHunks,
    receipt: value,
    preparedBody: preparedBody,
  );

  DigitalTwinProposalCommand withPreparedBody(Map<String, Object?> value) =>
      DigitalTwinProposalCommand(
        idempotencyKey: idempotencyKey,
        operation: operation,
        proposal: proposal,
        instruction: instruction,
        selectedHunks: selectedHunks,
        receipt: receipt,
        preparedBody: Map.unmodifiable(value),
      );

  Map<String, Object?> toJson() => {
    'idempotencyKey': idempotencyKey,
    'operation': operation.name,
    'proposal': _snapshotToJson(proposal),
    'instruction': instruction,
    'preparedBody': preparedBody,
    'selectedHunks': [
      for (final hunk in selectedHunks)
        {
          'proposalVersion': hunk.proposalVersion,
          'diffBundleId': hunk.diffBundleId,
          'hunkId': hunk.hunkId,
          'quotedText': hunk.quotedText,
        },
    ],
    if (receipt case final value?) 'receipt': _snapshotToJson(value),
  };

  factory DigitalTwinProposalCommand.fromJson(Map<String, Object?> value) =>
      DigitalTwinProposalCommand(
        idempotencyKey: value['idempotencyKey']! as String,
        operation: DigitalTwinProposalOperation.values.byName(
          value['operation']! as String,
        ),
        proposal: _snapshotFromJson(
          Map<String, Object?>.from(value['proposal']! as Map),
        ),
        instruction: value['instruction']! as String,
        preparedBody: value['preparedBody'] is Map
            ? Map<String, Object?>.from(value['preparedBody']! as Map)
            : null,
        selectedHunks: [
          for (final entry in value['selectedHunks']! as List)
            DigitalTwinSelectedHunk(
              proposalVersion: (entry as Map)['proposalVersion']! as int,
              diffBundleId: entry['diffBundleId']! as String,
              hunkId: entry['hunkId']! as String,
              quotedText: entry['quotedText']! as String,
            ),
        ],
        receipt: value['receipt'] is Map
            ? _snapshotFromJson(
                Map<String, Object?>.from(value['receipt']! as Map),
              )
            : null,
      );
}

Map<String, Object?> digitalTwinConfirmationToJson(
  DigitalTwinConfirmation value,
) => {
  'confirmationTaskId': value.confirmationTaskId,
  'state': value.state,
  'appliedCount': value.appliedCount,
  'failedCount': value.failedCount,
  'outcomes': [
    for (final outcome in value.outcomes)
      {
        'proposalId': outcome.proposalId,
        'proposalVersion': outcome.proposalVersion,
        if (outcome.state case final state?)
          'state': switch (state) {
            DocumentProposalState.generationFailed => 'generation_failed',
            DocumentProposalState.applyFailed => 'apply_failed',
            _ => state.name,
          },
        if (outcome.failureCode case final code?) 'failureCode': code,
      },
  ],
  if (value.version case final version?)
    'version': {
      'versionId': version.versionId,
      'versionNumber': version.versionNumber,
      'label': version.label,
      'workspaceVersion': version.workspaceVersion,
      'completionPercent': version.completionPercent,
      'scoringModel': version.scoringModel,
      'createdAt': version.createdAt.toUtc().toIso8601String(),
      if (version.confirmationTaskId case final id?) 'confirmationTaskId': id,
    },
};

String digitalTwinAppliedEvidenceKey(String proposalId, int version) =>
    '$proposalId:$version';

Map<String, Object?> _snapshotToJson(DocumentChangeProposalSnapshot snapshot) {
  final proposal = snapshot.proposal;
  return {
    'etag': snapshot.etag,
    'proposalId': proposal.proposalId,
    'proposalVersion': proposal.proposalVersion,
    'rowVersion': proposal.rowVersion,
    'state': proposal.state.name,
    'ownerKind': proposal.ownerKind,
    'noteId': proposal.noteId,
    'rawPartRevisionId': proposal.rawPartRevisionId,
    'candidateAvailable': proposal.candidateAvailable,
    'hasChanges': proposal.hasChanges,
    'sourceNoteIds': proposal.sourceNoteIds.toList(),
    'ownerMetadata': proposal.ownerMetadata,
    'failureCode': proposal.failureCode,
    'appliedPartRevisionId': proposal.appliedPartRevisionId,
    'appliedOwnerRevisionId': proposal.appliedOwnerRevisionId,
    'profileKind': proposal.profileKind,
    'runId': proposal.runId,
    'runState': proposal.runState,
  };
}

DocumentChangeProposalSnapshot _snapshotFromJson(Map<String, Object?> value) =>
    DocumentChangeProposalSnapshot(
      etag: value['etag']! as String,
      proposal: DocumentChangeProposal(
        proposalId: value['proposalId']! as String,
        proposalVersion: value['proposalVersion']! as int,
        rowVersion: value['rowVersion']! as int,
        state: DocumentProposalState.values.byName(value['state']! as String),
        ownerKind: value['ownerKind']! as String,
        noteId: value['noteId']! as String,
        rawPartRevisionId: value['rawPartRevisionId']! as String,
        candidateAvailable: value['candidateAvailable']! as bool,
        hasChanges: value['hasChanges'] as bool?,
        sourceNoteIds: Set<String>.from(value['sourceNoteIds']! as List),
        ownerMetadata: Map<String, Object?>.from(
          value['ownerMetadata']! as Map,
        ),
        failureCode: value['failureCode'] as String?,
        appliedPartRevisionId: value['appliedPartRevisionId'] as String?,
        appliedOwnerRevisionId: value['appliedOwnerRevisionId'] as String?,
        profileKind: value['profileKind'] as String?,
        runId: value['runId'] as String?,
        runState: value['runState'] as String?,
      ),
    );
