import 'package:huahuo_api/huahuo_api.dart';

const documentProposalInstructionMaxBytes = 32 * 1024;
const documentProposalCandidateMaxBytes = 8 * 1024 * 1024;
const documentProposalAgentProfileId = 'self_media_creation';
const documentProposalSkillProfileIds = <String>['self_media_creation_advisor'];
const _documentProposalSchema = 'huahuo.document-diff.v1';
const _documentCandidateSchema = 'huahuo.document-candidate-chunk.v1';
const _documentProposalStates = <String>{
  'generating',
  'ready',
  'applying',
  'applied',
  'rejected',
  'stale',
  'generation_failed',
  'apply_failed',
};

enum DocumentProposalState {
  generating,
  ready,
  applying,
  applied,
  rejected,
  stale,
  generationFailed,
  applyFailed;

  static DocumentProposalState? fromWire(String value) => switch (value) {
    'generating' => generating,
    'ready' => ready,
    'applying' => applying,
    'applied' => applied,
    'rejected' => rejected,
    'stale' => stale,
    'generation_failed' => generationFailed,
    'apply_failed' => applyFailed,
    _ => null,
  };
}

final class DocumentChangeProposalException implements Exception {
  const DocumentChangeProposalException(this.code);

  final String code;

  @override
  String toString() => 'DocumentChangeProposalException($code)';
}

final class DocumentProposalCreateRequest {
  const DocumentProposalCreateRequest({
    required this.noteId,
    required this.rawPartRevisionId,
    required this.instruction,
    required this.idempotencyKey,
    this.threadId,
  });

  final String noteId;
  final String rawPartRevisionId;
  final String instruction;
  final String idempotencyKey;
  final String? threadId;
}

final class DocumentChangeProposal {
  const DocumentChangeProposal({
    required this.proposalId,
    required this.proposalVersion,
    required this.rowVersion,
    required this.state,
    required this.noteId,
    required this.rawPartRevisionId,
    required this.candidateAvailable,
    this.ownerKind = 'hnote',
    this.hasChanges,
    this.sourceNoteIds = const <String>{},
    this.ownerMetadata = const <String, Object?>{},
    this.failureCode,
    this.appliedPartRevisionId,
    this.appliedOwnerRevisionId,
    this.profileKind,
    this.runId,
    this.runState,
    this.createdAt,
  });

  factory DocumentChangeProposal.fromValue(Object? value) {
    final object = _requiredObject(value, 'proposal');
    final proposalId = _requiredId(object, 'proposalId');
    final stateWire = _requiredString(object, 'state');
    if (!_documentProposalStates.contains(stateWire)) {
      throw const FormatException('proposal state is invalid');
    }
    final state = DocumentProposalState.fromWire(stateWire);
    if (state == null) throw const FormatException('proposal state is invalid');
    final target = _requiredObject(object['target'], 'target');
    final ownerRef = _requiredObject(target['ownerRef'], 'ownerRef');
    final ownerKind = _requiredString(ownerRef, 'kind');
    if (!const <String>{
          'hnote',
          'profile_conclusion',
          'workspace_standard_file',
        }.contains(ownerKind) ||
        _requiredString(target, 'part') != 'raw') {
      throw const FormatException('proposal target is invalid');
    }
    final metadata = asObjectMap(target['metadata']);
    final run = asObjectMap(object['run']);
    final failure = object['failure'];
    final applied = object['applied'];
    return DocumentChangeProposal(
      proposalId: proposalId,
      proposalVersion: _requiredPositiveInt(object, 'proposalVersion'),
      rowVersion: _requiredPositiveInt(object, 'rowVersion'),
      state: state,
      ownerKind: ownerKind,
      noteId: ownerKind == 'hnote'
          ? _requiredId(ownerRef, 'id')
          : _requiredString(ownerRef, 'id'),
      rawPartRevisionId: _requiredId(target, 'basePartRevisionId'),
      candidateAvailable: _requiredBool(object, 'candidateAvailable'),
      hasChanges: _optionalBool(object, 'hasChanges'),
      ownerMetadata: Map<String, Object?>.unmodifiable(metadata ?? const {}),
      sourceNoteIds: Set<String>.unmodifiable(<String>{
        for (final source in metadata?['sourceRefs'] as List? ?? const [])
          if (asNonEmptyString(asObjectMap(source)?['noteId'])
              case final noteId?)
            noteId,
      }),
      failureCode: failure == null
          ? null
          : _requiredString(_requiredObject(failure, 'failure'), 'code'),
      appliedPartRevisionId: applied == null
          ? null
          : _requiredId(_requiredObject(applied, 'applied'), 'partRevisionId'),
      appliedOwnerRevisionId: applied == null
          ? null
          : _requiredId(_requiredObject(applied, 'applied'), 'ownerRevisionId'),
      profileKind: metadata == null
          ? null
          : asNonEmptyString(metadata['profileKind']),
      runId: run == null ? null : asNonEmptyString(run['runId']),
      runState: run == null ? null : asNonEmptyString(run['state']),
      createdAt: DateTime.tryParse(
        asNonEmptyString(object['createdAt']) ?? '',
      )?.toUtc(),
    );
  }

  final String proposalId;
  final int proposalVersion;
  final DateTime? createdAt;
  final int rowVersion;
  final DocumentProposalState state;
  final String ownerKind;
  final String noteId;
  final String rawPartRevisionId;
  final bool candidateAvailable;
  final bool? hasChanges;
  final Set<String> sourceNoteIds;
  final Map<String, Object?> ownerMetadata;
  final String? failureCode;
  final String? appliedPartRevisionId;
  final String? appliedOwnerRevisionId;
  final String? profileKind;
  final String? runId;
  final String? runState;
}

final class DocumentChangeProposalSnapshot {
  const DocumentChangeProposalSnapshot({
    required this.proposal,
    required this.etag,
  });

  final DocumentChangeProposal proposal;
  final String etag;
}

final class DocumentProposalDiffChange {
  const DocumentProposalDiffChange({required this.op, required this.text});

  factory DocumentProposalDiffChange.fromValue(Object? value) {
    final object = _requiredObject(value, 'diff change');
    final op = _requiredString(object, 'op');
    if (op != 'insert' && op != 'delete') {
      throw const FormatException('diff operation is invalid');
    }
    return DocumentProposalDiffChange(
      op: op,
      text: _requiredString(object, 'text', allowEmpty: true),
    );
  }

  final String op;
  final String text;
}

final class DocumentProposalDiffHunk {
  const DocumentProposalDiffHunk({
    required this.hunkId,
    required this.oldStart,
    required this.oldLines,
    required this.newStart,
    required this.newLines,
    required this.changes,
  });

  factory DocumentProposalDiffHunk.fromValue(Object? value) {
    final object = _requiredObject(value, 'diff hunk');
    final rawChanges = object['changes'];
    if (rawChanges is! List) {
      throw const FormatException('diff hunk changes are invalid');
    }
    return DocumentProposalDiffHunk(
      hunkId: _requiredId(object, 'hunkId'),
      oldStart: _requiredNonNegativeInt(object, 'oldStart'),
      oldLines: _requiredNonNegativeInt(object, 'oldLines'),
      newStart: _requiredNonNegativeInt(object, 'newStart'),
      newLines: _requiredNonNegativeInt(object, 'newLines'),
      changes: List<DocumentProposalDiffChange>.unmodifiable(
        rawChanges.map(DocumentProposalDiffChange.fromValue),
      ),
    );
  }

  final String hunkId;
  final int oldStart;
  final int oldLines;
  final int newStart;
  final int newLines;
  final List<DocumentProposalDiffChange> changes;
}

final class DocumentProposalDiffSummary {
  const DocumentProposalDiffSummary({
    required this.hunks,
    required this.insertedLines,
    required this.deletedLines,
    required this.changedLines,
    required this.hasChanges,
  });

  factory DocumentProposalDiffSummary.fromValue(Object? value) {
    final object = _requiredObject(value, 'diff summary');
    return DocumentProposalDiffSummary(
      hunks: _requiredNonNegativeInt(object, 'hunks'),
      insertedLines: _requiredNonNegativeInt(object, 'insertedLines'),
      deletedLines: _requiredNonNegativeInt(object, 'deletedLines'),
      changedLines: _requiredNonNegativeInt(object, 'changedLines'),
      hasChanges: _requiredBool(object, 'hasChanges'),
    );
  }

  final int hunks;
  final int insertedLines;
  final int deletedLines;
  final int changedLines;
  final bool hasChanges;
}

final class DocumentProposalDiffPage {
  const DocumentProposalDiffPage({
    required this.proposalId,
    required this.proposalVersion,
    required this.summary,
    required this.items,
    this.nextCursor,
  });

  factory DocumentProposalDiffPage.fromValue(Object? value) {
    final object = _requiredObject(value, 'diff page');
    if (_requiredString(object, 'schema') != _documentProposalSchema) {
      throw const FormatException('diff schema is invalid');
    }
    final rawItems = object['items'];
    if (rawItems is! List) {
      throw const FormatException('diff items are invalid');
    }
    return DocumentProposalDiffPage(
      proposalId: _requiredId(object, 'proposalId'),
      proposalVersion: _requiredPositiveInt(object, 'proposalVersion'),
      summary: DocumentProposalDiffSummary.fromValue(object['summary']),
      items: List<DocumentProposalDiffHunk>.unmodifiable(
        rawItems.map(DocumentProposalDiffHunk.fromValue),
      ),
      nextCursor: _optionalCursor(object, 'nextCursor'),
    );
  }

  final String proposalId;
  final int proposalVersion;
  final DocumentProposalDiffSummary summary;
  final List<DocumentProposalDiffHunk> items;
  final String? nextCursor;
}

final class DocumentProposalCandidateChunk {
  const DocumentProposalCandidateChunk({
    required this.proposalId,
    required this.proposalVersion,
    required this.candidateHash,
    required this.offsetBytes,
    required this.text,
    this.nextCursor,
  });

  factory DocumentProposalCandidateChunk.fromValue(Object? value) {
    final object = _requiredObject(value, 'candidate chunk');
    if (_requiredString(object, 'schema') != _documentCandidateSchema) {
      throw const FormatException('candidate schema is invalid');
    }
    return DocumentProposalCandidateChunk(
      proposalId: _requiredId(object, 'proposalId'),
      proposalVersion: _requiredPositiveInt(object, 'proposalVersion'),
      candidateHash: _requiredString(object, 'candidateHash'),
      offsetBytes: _requiredNonNegativeInt(object, 'offsetBytes'),
      text: _requiredString(object, 'text', allowEmpty: true),
      nextCursor: _optionalCursor(object, 'nextCursor'),
    );
  }

  final String proposalId;
  final int proposalVersion;
  final String candidateHash;
  final int offsetBytes;
  final String text;
  final String? nextCursor;
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

String? _optionalCursor(Map<String, Object?> object, String field) {
  final value = object[field];
  if (value == null) return null;
  if (value is! String || _optionalCursorValue(value) == null) {
    throw FormatException('$field is invalid');
  }
  return value;
}

Map<String, Object?> _requiredObject(Object? value, String field) {
  final object = asObjectMap(value);
  if (object == null) throw FormatException('$field is invalid');
  return object;
}

String _requiredString(
  Map<String, Object?> object,
  String field, {
  bool allowEmpty = false,
}) {
  final value = object[field];
  if (value is! String || (!allowEmpty && value.trim().isEmpty)) {
    throw FormatException('$field is invalid');
  }
  return value;
}

String _requiredId(Map<String, Object?> object, String field) =>
    _requireId(_requiredString(object, field), field);

int _requiredPositiveInt(Map<String, Object?> object, String field) {
  final value = object[field];
  if (value is! int || value < 1) throw FormatException('$field is invalid');
  return value;
}

int _requiredNonNegativeInt(Map<String, Object?> object, String field) {
  final value = object[field];
  if (value is! int || value < 0) throw FormatException('$field is invalid');
  return value;
}

bool _requiredBool(Map<String, Object?> object, String field) {
  final value = object[field];
  if (value is! bool) throw FormatException('$field is invalid');
  return value;
}

bool? _optionalBool(Map<String, Object?> object, String field) {
  final value = object[field];
  if (value == null) return null;
  if (value is! bool) throw FormatException('$field is invalid');
  return value;
}
