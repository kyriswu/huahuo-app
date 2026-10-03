import '../api/api_envelope.dart';

const documentProposalInstructionMaxBytes = 32 * 1024;
const documentProposalCandidateMaxBytes = 8 * 1024 * 1024;
const documentProposalAgentProfileId = 'self_media_creation';
const documentProposalSkillProfileIds = <String>['self_media_creation_advisor'];

enum DocumentProposalStateDto {
  generating,
  ready,
  applying,
  applied,
  rejected,
  stale,
  generationFailed,
  applyFailed;

  static DocumentProposalStateDto parse(String value) => switch (value) {
    'generating' => generating,
    'ready' => ready,
    'applying' => applying,
    'applied' => applied,
    'rejected' => rejected,
    'stale' => stale,
    'generation_failed' => generationFailed,
    'apply_failed' => applyFailed,
    _ => throw const FormatException('Invalid Proposal state'),
  };
}

final class DocumentProposalDto {
  const DocumentProposalDto({
    required this.proposalId,
    required this.proposalVersion,
    required this.rowVersion,
    required this.state,
    required this.ownerKind,
    required this.ownerId,
    required this.part,
    required this.basePartRevisionId,
    required this.baseHash,
    required this.candidateAvailable,
    required this.createdAt,
    required this.updatedAt,
    this.hasChanges,
    this.failureCode,
    this.failureRetryable,
    this.appliedPartRevisionId,
    this.appliedOwnerRevisionId,
    this.runId,
    this.runState,
  });

  factory DocumentProposalDto.fromValue(Object? value, {String? expectedId}) {
    final json = _object(value, 'Proposal');
    _only(json, const {
      'proposalId',
      'proposalVersion',
      'rowVersion',
      'state',
      'generationStage',
      'target',
      'run',
      'candidateAvailable',
      'hasChanges',
      'failure',
      'applied',
      'links',
      'createdAt',
      'updatedAt',
      'readyAt',
      'appliedAt',
    });
    final id = _id(json, 'proposalId');
    if (expectedId != null && id != expectedId) {
      throw const FormatException('Proposal identity mismatch');
    }
    final target = _object(json['target'], 'Proposal target');
    _only(target, const {
      'ownerRef',
      'part',
      'basePartRevisionId',
      'baseHash',
      'metadata',
    });
    final owner = _object(target['ownerRef'], 'Proposal owner');
    _only(owner, const {'kind', 'id'});
    final ownerKind = _string(owner, 'kind');
    if (!const {
      'hnote',
      'creation',
      'book_section',
      'work',
      'profile_conclusion',
      'workspace_standard_file',
    }.contains(ownerKind)) {
      throw const FormatException('Invalid Proposal owner kind');
    }
    final part = _string(target, 'part');
    if (!const {'raw', 'outline', 'germination'}.contains(part)) {
      throw const FormatException('Invalid Proposal part');
    }
    final run = _object(json['run'], 'Proposal run');
    _only(run, const {'bindingState', 'runId', 'state'});
    final links = _object(json['links'], 'Proposal links');
    _only(links, const {'self', 'runEvents', 'diff', 'candidate'});
    _path(links, 'self');
    final failure = json['failure'] == null
        ? null
        : _object(json['failure'], 'Proposal failure');
    if (failure != null) {
      _only(failure, const {'code', 'retryable', 'stage'});
    }
    final applied = json['applied'] == null
        ? null
        : _object(json['applied'], 'Proposal applied revision');
    if (applied != null) {
      _only(applied, const {'ownerRevisionId', 'partRevisionId', 'hash'});
    }
    return DocumentProposalDto(
      proposalId: id,
      proposalVersion: _positive(json, 'proposalVersion'),
      rowVersion: _positive(json, 'rowVersion'),
      state: DocumentProposalStateDto.parse(_string(json, 'state')),
      ownerKind: ownerKind,
      ownerId: _ownerId(owner, ownerKind),
      part: part,
      basePartRevisionId: _id(target, 'basePartRevisionId'),
      baseHash: _hash(target, 'baseHash'),
      candidateAvailable: _boolean(json, 'candidateAvailable'),
      hasChanges: _optionalBool(json, 'hasChanges'),
      failureCode: failure == null ? null : _string(failure, 'code'),
      failureRetryable: failure == null ? null : _boolean(failure, 'retryable'),
      appliedPartRevisionId: applied == null
          ? null
          : _id(applied, 'partRevisionId'),
      appliedOwnerRevisionId: applied == null
          ? null
          : _id(applied, 'ownerRevisionId'),
      runId: _optionalId(run, 'runId'),
      runState: _optionalString(run, 'state'),
      createdAt: _date(json, 'createdAt'),
      updatedAt: _date(json, 'updatedAt'),
    );
  }

  final String proposalId;
  final int proposalVersion;
  final int rowVersion;
  final DocumentProposalStateDto state;
  final String ownerKind;
  final String ownerId;
  final String part;
  final String basePartRevisionId;
  final String baseHash;
  final bool candidateAvailable;
  final bool? hasChanges;
  final String? failureCode;
  final bool? failureRetryable;
  final String? appliedPartRevisionId;
  final String? appliedOwnerRevisionId;
  final String? runId;
  final String? runState;
  final DateTime createdAt;
  final DateTime updatedAt;
}

final class DocumentProposalSnapshotDto {
  const DocumentProposalSnapshotDto({
    required this.proposal,
    required this.etag,
  });

  final DocumentProposalDto proposal;
  final String etag;
}

final class DocumentProposalPageDto {
  DocumentProposalPageDto({
    required Iterable<DocumentProposalDto> items,
    this.nextCursor,
  }) : items = List.unmodifiable(items);

  factory DocumentProposalPageDto.fromValue(Object? value) {
    final json = _object(value, 'Proposal page');
    _only(json, const {'items', 'nextCursor'});
    final raw = json['items'];
    if (raw is! List<Object?> || raw.length > 50) {
      throw const FormatException('Invalid Proposal page items');
    }
    final items = raw.map(DocumentProposalDto.fromValue).toList();
    if (items.map((item) => item.proposalId).toSet().length != items.length) {
      throw const FormatException('Duplicate Proposal identity');
    }
    return DocumentProposalPageDto(
      items: items,
      nextCursor: _cursor(json, 'nextCursor'),
    );
  }

  final List<DocumentProposalDto> items;
  final String? nextCursor;
}

final class DocumentProposalDiffChangeDto {
  const DocumentProposalDiffChangeDto({
    required this.operation,
    required this.text,
  });

  factory DocumentProposalDiffChangeDto.fromValue(Object? value) {
    final json = _object(value, 'Proposal diff change');
    _only(json, const {'op', 'text'});
    final operation = _string(json, 'op');
    if (operation != 'insert' && operation != 'delete') {
      throw const FormatException('Invalid Proposal diff operation');
    }
    return DocumentProposalDiffChangeDto(
      operation: operation,
      text: _text(json, 'text', allowEmpty: true),
    );
  }

  final String operation;
  final String text;
}

final class DocumentProposalDiffHunkDto {
  DocumentProposalDiffHunkDto({
    required this.hunkId,
    required this.oldStart,
    required this.oldLines,
    required this.newStart,
    required this.newLines,
    required Iterable<DocumentProposalDiffChangeDto> changes,
  }) : changes = List.unmodifiable(changes);

  factory DocumentProposalDiffHunkDto.fromValue(Object? value) {
    final json = _object(value, 'Proposal diff hunk');
    _only(json, const {
      'hunkId',
      'oldStart',
      'oldLines',
      'newStart',
      'newLines',
      'changes',
    });
    final raw = json['changes'];
    if (raw is! List<Object?> || raw.length > 1000) {
      throw const FormatException('Invalid Proposal diff changes');
    }
    return DocumentProposalDiffHunkDto(
      hunkId: _id(json, 'hunkId'),
      oldStart: _nonNegative(json, 'oldStart'),
      oldLines: _nonNegative(json, 'oldLines'),
      newStart: _nonNegative(json, 'newStart'),
      newLines: _nonNegative(json, 'newLines'),
      changes: raw.map(DocumentProposalDiffChangeDto.fromValue),
    );
  }

  final String hunkId;
  final int oldStart;
  final int oldLines;
  final int newStart;
  final int newLines;
  final List<DocumentProposalDiffChangeDto> changes;
}

final class DocumentProposalDiffSummaryDto {
  const DocumentProposalDiffSummaryDto({
    required this.hunks,
    required this.insertedLines,
    required this.deletedLines,
    required this.changedLines,
    required this.hasChanges,
  });

  factory DocumentProposalDiffSummaryDto.fromValue(Object? value) {
    final json = _object(value, 'Proposal diff summary');
    _only(json, const {
      'hunks',
      'insertedLines',
      'deletedLines',
      'changedLines',
      'hasChanges',
    });
    return DocumentProposalDiffSummaryDto(
      hunks: _nonNegative(json, 'hunks'),
      insertedLines: _nonNegative(json, 'insertedLines'),
      deletedLines: _nonNegative(json, 'deletedLines'),
      changedLines: _nonNegative(json, 'changedLines'),
      hasChanges: _boolean(json, 'hasChanges'),
    );
  }

  final int hunks;
  final int insertedLines;
  final int deletedLines;
  final int changedLines;
  final bool hasChanges;
}

final class DocumentProposalDiffPageDto {
  DocumentProposalDiffPageDto({
    required this.proposalId,
    required this.proposalVersion,
    required this.summary,
    required Iterable<DocumentProposalDiffHunkDto> items,
    this.nextCursor,
  }) : items = List.unmodifiable(items);

  factory DocumentProposalDiffPageDto.fromValue(
    Object? value, {
    required String expectedId,
    int? expectedVersion,
  }) {
    final json = _object(value, 'Proposal diff page');
    _only(json, const {
      'schema',
      'proposalId',
      'proposalVersion',
      'base',
      'candidate',
      'algorithm',
      'summary',
      'items',
      'nextCursor',
    });
    if (_string(json, 'schema') != 'huahuo.document-diff.v1' ||
        _id(json, 'proposalId') != expectedId) {
      throw const FormatException('Invalid Proposal diff identity');
    }
    final version = _positive(json, 'proposalVersion');
    if (expectedVersion != null && version != expectedVersion) {
      throw const FormatException('Invalid Proposal diff version');
    }
    final base = _object(json['base'], 'Proposal diff base');
    _only(base, const {'partRevisionId', 'hash'});
    _id(base, 'partRevisionId');
    _hash(base, 'hash');
    final candidate = _object(json['candidate'], 'Proposal diff candidate');
    _only(candidate, const {'hash', 'sizeBytes'});
    _hash(candidate, 'hash');
    _nonNegative(candidate, 'sizeBytes');
    final algorithm = _object(json['algorithm'], 'Proposal diff algorithm');
    _only(algorithm, const {'name', 'version', 'granularity', 'fallbackUsed'});
    _string(algorithm, 'name');
    _string(algorithm, 'version');
    _string(algorithm, 'granularity');
    _boolean(algorithm, 'fallbackUsed');
    final raw = json['items'];
    if (raw is! List<Object?> || raw.length > 50) {
      throw const FormatException('Invalid Proposal diff items');
    }
    return DocumentProposalDiffPageDto(
      proposalId: expectedId,
      proposalVersion: version,
      summary: DocumentProposalDiffSummaryDto.fromValue(json['summary']),
      items: raw.map(DocumentProposalDiffHunkDto.fromValue),
      nextCursor: _cursor(json, 'nextCursor'),
    );
  }

  final String proposalId;
  final int proposalVersion;
  final DocumentProposalDiffSummaryDto summary;
  final List<DocumentProposalDiffHunkDto> items;
  final String? nextCursor;
}

final class DocumentProposalCandidateChunkDto {
  const DocumentProposalCandidateChunkDto({
    required this.proposalId,
    required this.proposalVersion,
    required this.candidateHash,
    required this.offsetBytes,
    required this.text,
    this.nextCursor,
  });

  factory DocumentProposalCandidateChunkDto.fromValue(
    Object? value, {
    required String expectedId,
    int? expectedVersion,
  }) {
    final json = _object(value, 'Proposal candidate');
    _only(json, const {
      'schema',
      'proposalId',
      'proposalVersion',
      'candidateHash',
      'offsetBytes',
      'text',
      'nextCursor',
    });
    final version = _positive(json, 'proposalVersion');
    if (_string(json, 'schema') != 'huahuo.document-candidate-chunk.v1' ||
        _id(json, 'proposalId') != expectedId ||
        (expectedVersion != null && version != expectedVersion)) {
      throw const FormatException('Invalid Proposal candidate identity');
    }
    return DocumentProposalCandidateChunkDto(
      proposalId: expectedId,
      proposalVersion: version,
      candidateHash: _hash(json, 'candidateHash'),
      offsetBytes: _nonNegative(json, 'offsetBytes'),
      text: _text(json, 'text', allowEmpty: true),
      nextCursor: _cursor(json, 'nextCursor'),
    );
  }

  final String proposalId;
  final int proposalVersion;
  final String candidateHash;
  final int offsetBytes;
  final String text;
  final String? nextCursor;
}

final class DocumentProposalVersionDto {
  const DocumentProposalVersionDto({
    required this.proposalId,
    required this.proposalVersion,
    required this.baseHash,
    required this.createdAt,
    this.candidateHash,
    this.candidateSizeBytes,
    this.diffBundleId,
    this.agentRunId,
  });

  factory DocumentProposalVersionDto.fromValue(
    Object? value, {
    required String expectedId,
  }) {
    final json = _object(value, 'Proposal version');
    _only(json, const {
      'proposalId',
      'proposalVersion',
      'baseHash',
      'candidateHash',
      'candidateSizeBytes',
      'diffBundleId',
      'agentRunId',
      'createdAt',
      'links',
    });
    if (_id(json, 'proposalId') != expectedId) {
      throw const FormatException('Invalid Proposal version identity');
    }
    final links = _object(json['links'], 'Proposal version links');
    _only(links, const {'self', 'runEvents', 'diff', 'candidate'});
    _path(links, 'self');
    return DocumentProposalVersionDto(
      proposalId: expectedId,
      proposalVersion: _positive(json, 'proposalVersion'),
      baseHash: _hash(json, 'baseHash'),
      candidateHash: _optionalHash(json, 'candidateHash'),
      candidateSizeBytes: _optionalNonNegative(json, 'candidateSizeBytes'),
      diffBundleId: _optionalId(json, 'diffBundleId'),
      agentRunId: _optionalId(json, 'agentRunId'),
      createdAt: _date(json, 'createdAt'),
    );
  }

  final String proposalId;
  final int proposalVersion;
  final String baseHash;
  final String? candidateHash;
  final int? candidateSizeBytes;
  final String? diffBundleId;
  final String? agentRunId;
  final DateTime createdAt;
}

Map<String, Object?> _object(Object? value, String label) {
  final json = asObjectMap(value);
  if (json == null) throw FormatException('Invalid $label');
  return json;
}

void _only(Map<String, Object?> json, Set<String> allowed) {
  if (json.keys.any((key) => !allowed.contains(key))) {
    throw const FormatException('Unexpected Proposal field');
  }
}

String _text(Map<String, Object?> json, String key, {bool allowEmpty = false}) {
  final value = json[key];
  if (value is! String || (!allowEmpty && value.trim().isEmpty)) {
    throw FormatException('Invalid $key');
  }
  return value;
}

String _string(Map<String, Object?> json, String key) =>
    _text(json, key).trim();

String _id(Map<String, Object?> json, String key) =>
    _idFromPath(_string(json, key), key);

String _idFromPath(String value, String key) {
  if (value.length > 200 || !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value)) {
    throw FormatException('Invalid $key');
  }
  return value;
}

String _ownerId(Map<String, Object?> json, String kind) {
  final value = _string(json, 'id');
  final pattern = kind == 'workspace_standard_file'
      ? RegExp(r'^[A-Za-z0-9_.-]+$')
      : RegExp(r'^[A-Za-z0-9_-]+$');
  if (value.length > 200 || !pattern.hasMatch(value)) {
    throw const FormatException('Invalid Proposal owner ID');
  }
  return value;
}

String _path(Map<String, Object?> json, String key) => _string(json, key);

String _hash(Map<String, Object?> json, String key) {
  final value = _string(json, key).toLowerCase();
  if (!RegExp(r'^sha256:[a-f0-9]{64}$').hasMatch(value)) {
    throw FormatException('Invalid $key');
  }
  return value;
}

String? _optionalHash(Map<String, Object?> json, String key) =>
    json[key] == null ? null : _hash(json, key);

String? _optionalString(Map<String, Object?> json, String key) =>
    json[key] == null ? null : _string(json, key);

String? _optionalId(Map<String, Object?> json, String key) =>
    json[key] == null ? null : _id(json, key);

bool _boolean(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! bool) throw FormatException('Invalid $key');
  return value;
}

bool? _optionalBool(Map<String, Object?> json, String key) =>
    json[key] == null ? null : _boolean(json, key);

int _positive(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! int || value < 1) throw FormatException('Invalid $key');
  return value;
}

int _nonNegative(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! int || value < 0) throw FormatException('Invalid $key');
  return value;
}

int? _optionalNonNegative(Map<String, Object?> json, String key) =>
    json[key] == null ? null : _nonNegative(json, key);

String? _cursor(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! String || value.trim().isEmpty || value.length > 4096) {
    throw FormatException('Invalid $key');
  }
  return value;
}

DateTime _date(Map<String, Object?> json, String key) {
  final value = json[key];
  final parsed = value is String ? DateTime.tryParse(value)?.toUtc() : null;
  if (parsed == null) throw FormatException('Invalid $key');
  return parsed;
}
