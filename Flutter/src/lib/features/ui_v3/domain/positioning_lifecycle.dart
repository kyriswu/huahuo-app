import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'document_change_proposal_models.dart';

const positioningReportOwner = 'workspace.user.profile.user_positioning';

bool isPositioningProposal(DocumentChangeProposal proposal) =>
    proposal.ownerKind == 'workspace_standard_file' &&
    proposal.noteId == positioningReportOwner;

String? positioningProposalSourceRunId(DocumentChangeProposal proposal) {
  if (!isPositioningProposal(proposal)) return null;
  final sourceRunId = proposal.ownerMetadata['sourceRunId'];
  if (sourceRunId is! String || sourceRunId.trim().isEmpty) return null;
  return sourceRunId.trim();
}

enum InitialPositioningAccess {
  checking,
  notStarted,
  running,
  recovering,
  completed,
  retryableFailure,
  unavailable,
}

enum PositioningUpdateStage {
  waitingForRun,
  waitingForCandidate,
  applying,
  awaitingReadback,
  updated,
  noChanges,
  retryableFailure,
  blocked,
}

final class PositioningUpdateCheckpoint {
  const PositioningUpdateCheckpoint({
    required this.runId,
    required this.createdAt,
    this.stage = PositioningUpdateStage.waitingForRun,
    this.proposalId,
    this.proposalVersion,
    this.etag,
    this.idempotencyKey,
    this.contentHash,
    this.errorCode,
  });

  final String runId;
  final DateTime createdAt;
  final PositioningUpdateStage stage;
  final String? proposalId;
  final int? proposalVersion;
  final String? etag;
  final String? idempotencyKey;
  final String? contentHash;
  final String? errorCode;

  bool get terminal => const {
    PositioningUpdateStage.updated,
    PositioningUpdateStage.noChanges,
    PositioningUpdateStage.blocked,
  }.contains(stage);

  PositioningUpdateCheckpoint advance(
    PositioningUpdateStage next, {
    String? proposalId,
    int? proposalVersion,
    String? etag,
    String? idempotencyKey,
    String? contentHash,
    String? errorCode,
  }) => PositioningUpdateCheckpoint(
    runId: runId,
    createdAt: createdAt,
    stage: next,
    proposalId: proposalId ?? this.proposalId,
    proposalVersion: proposalVersion ?? this.proposalVersion,
    etag: etag ?? this.etag,
    idempotencyKey: idempotencyKey ?? this.idempotencyKey,
    contentHash: contentHash ?? this.contentHash,
    errorCode: errorCode,
  );

  Map<String, Object?> toJson() => {
    'runId': runId,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'stage': stage.name,
    'proposalId': proposalId,
    'proposalVersion': proposalVersion,
    'etag': etag,
    'idempotencyKey': idempotencyKey,
    'contentHash': contentHash,
    'errorCode': errorCode,
  };

  factory PositioningUpdateCheckpoint.fromJson(Map<String, dynamic> value) =>
      PositioningUpdateCheckpoint(
        runId: value['runId'] as String,
        createdAt: DateTime.parse(value['createdAt'] as String),
        stage: PositioningUpdateStage.values.byName(value['stage'] as String),
        proposalId: value['proposalId'] as String?,
        proposalVersion: value['proposalVersion'] as int?,
        etag: value['etag'] as String?,
        idempotencyKey: value['idempotencyKey'] as String?,
        contentHash: value['contentHash'] as String?,
        errorCode: value['errorCode'] as String?,
      );
}

String positioningDigest(String value) =>
    sha256.convert(utf8.encode(value)).toString();

String positioningContentDigest(String markdown) =>
    positioningDigest(markdown.replaceAll('\r\n', '\n').trim());

abstract interface class PositioningUpdateStore {
  List<PositioningUpdateCheckpoint> load();
  Future<void> save(List<PositioningUpdateCheckpoint> checkpoints);
}

abstract interface class PositioningCompletionStore {
  bool get basicCompleted;
  Future<void> recordBasicCompletion();
}

abstract interface class PositioningUpdatePort {
  Future<DocumentChangeProposalSnapshot?> latest();
  Future<DocumentChangeProposalSnapshot> get(String proposalId);
  Future<String> candidateDigest(DocumentChangeProposal proposal);
  Future<DocumentChangeProposalSnapshot> apply(
    PositioningUpdateCheckpoint checkpoint,
  );
  Future<String> runStatus(String runId);
  Future<bool> verifySource(DocumentChangeProposal proposal);
}
