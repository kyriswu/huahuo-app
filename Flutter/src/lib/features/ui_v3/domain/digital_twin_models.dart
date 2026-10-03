import '../../../core/api/api_envelope.dart';
import 'document_change_proposal_models.dart';

const digitalTwinAgentProfileId = 'data_body';

final class DigitalTwinImportSource {
  const DigitalTwinImportSource({
    required this.importTaskId,
    required this.taskId,
    required this.resourceId,
    required this.noteId,
    required this.title,
    this.confirmationTaskId,
  });

  final String importTaskId;
  final String taskId;
  final String resourceId;
  final String noteId;
  final String title;
  final String? confirmationTaskId;
}

final class DigitalTwinDistillationTask {
  const DigitalTwinDistillationTask({
    required this.taskId,
    required this.status,
    this.failureCode,
  });

  factory DigitalTwinDistillationTask.fromValue(Object? value) {
    final envelope = _object(value, 'task');
    final task = asObjectMap(envelope['task']) ?? envelope;
    return DigitalTwinDistillationTask(
      taskId: _string(task, 'taskId'),
      status: _string(task, 'status'),
      failureCode: asNonEmptyString(asObjectMap(task['errorSummary'])?['code']),
    );
  }

  final String taskId;
  final String status;
  final String? failureCode;
  bool get isFailed => const {
    'failed',
    'timeout',
    'dead_letter',
    'cancelled',
    'aborted',
    'rejected',
    'orphaned',
  }.contains(status);
}

final class DigitalTwinApiException implements Exception {
  const DigitalTwinApiException(this.code);

  final String code;

  @override
  String toString() => 'DigitalTwinApiException($code)';
}

final class DigitalTwinLevel {
  const DigitalTwinLevel({
    required this.value,
    required this.name,
    required this.completionPercent,
    required this.scoringModel,
  });

  factory DigitalTwinLevel.fromValue(Object? value) {
    final object = _object(value, 'level');
    return DigitalTwinLevel(
      value: _intInRange(object, 'value', 0, 5),
      name: _string(object, 'name'),
      completionPercent: _intInRange(object, 'completionPercent', 0, 100),
      scoringModel: _string(object, 'scoringModel'),
    );
  }

  final int value;
  final String name;
  final int completionPercent;
  final String scoringModel;
}

final class DigitalTwinSourceRef {
  const DigitalTwinSourceRef({
    required this.sourceRefId,
    required this.sourceKind,
    this.noteId,
    this.part,
    this.partRevisionId,
    this.messageId,
  });

  factory DigitalTwinSourceRef.fromValue(Object? value) {
    final object = _object(value, 'source');
    return DigitalTwinSourceRef(
      sourceRefId: _string(object, 'sourceRefId'),
      sourceKind: _string(object, 'sourceKind'),
      noteId: _optionalString(object, 'noteId'),
      part: _optionalString(object, 'part'),
      partRevisionId: _optionalString(object, 'partRevisionId'),
      messageId: _optionalString(object, 'messageId'),
    );
  }

  final String sourceRefId;
  final String sourceKind;
  final String? noteId;
  final String? part;
  final String? partRevisionId;
  final String? messageId;
}

final class DigitalTwinConclusion {
  const DigitalTwinConclusion({
    required this.conclusionId,
    required this.profileKind,
    required this.state,
    required this.revision,
    required this.markdown,
    required this.sourceReviewNeeded,
    required this.sources,
    this.updatedAt,
  });

  factory DigitalTwinConclusion.fromValue(Object? value) {
    final object = _object(value, 'conclusion');
    return DigitalTwinConclusion(
      conclusionId: _string(object, 'conclusionId'),
      profileKind: _string(object, 'profileKind'),
      state: _string(object, 'state'),
      revision: _positiveInt(object, 'revision'),
      markdown: _string(object, 'markdown', allowEmpty: true),
      sourceReviewNeeded: _bool(object, 'sourceReviewNeeded'),
      sources: _list(object, 'sources', DigitalTwinSourceRef.fromValue),
      updatedAt: _optionalDate(object, 'updatedAt'),
    );
  }

  final String conclusionId;
  final String profileKind;
  final String state;
  final int revision;
  final String markdown;
  final bool sourceReviewNeeded;
  final List<DigitalTwinSourceRef> sources;
  final DateTime? updatedAt;
}

final class DigitalTwinLogicalFile {
  const DigitalTwinLogicalFile({
    required this.id,
    required this.name,
    required this.exists,
    required this.markdown,
    required this.conclusions,
    required this.pendingCount,
    required this.pendingProposalIds,
  });

  factory DigitalTwinLogicalFile.fromValue(Object? value) {
    final object = _object(value, 'file');
    return DigitalTwinLogicalFile(
      id: _string(object, 'id'),
      name: _string(object, 'name'),
      exists: _bool(object, 'exists'),
      markdown: _optionalString(object, 'markdown') ?? '',
      conclusions: _list(
        object,
        'conclusions',
        DigitalTwinConclusion.fromValue,
      ),
      pendingCount: _nonNegativeInt(object, 'pendingCount'),
      pendingProposalIds: _stringList(object, 'pendingProposalIds'),
    );
  }

  final String id;
  final String name;
  final bool exists;
  final String markdown;
  final List<DigitalTwinConclusion> conclusions;
  final int pendingCount;
  final List<String> pendingProposalIds;

  int get sourceCount => conclusions.fold<int>(
    0,
    (sum, conclusion) => sum + conclusion.sources.length,
  );
}

final class DigitalTwinVersion {
  const DigitalTwinVersion({
    required this.versionId,
    required this.versionNumber,
    required this.label,
    required this.workspaceVersion,
    required this.completionPercent,
    required this.scoringModel,
    required this.createdAt,
    this.confirmationTaskId,
  });

  factory DigitalTwinVersion.fromValue(Object? value) {
    final object = _object(value, 'version');
    return DigitalTwinVersion(
      versionId: _string(object, 'versionId'),
      versionNumber: _nonNegativeInt(object, 'versionNumber'),
      label: _string(object, 'label'),
      confirmationTaskId: _optionalString(object, 'confirmationTaskId'),
      workspaceVersion: _nonNegativeInt(object, 'workspaceVersion'),
      completionPercent: _intInRange(object, 'completionPercent', 0, 100),
      scoringModel: _string(object, 'scoringModel'),
      createdAt: _date(object, 'createdAt'),
    );
  }

  final String versionId;
  final int versionNumber;
  final String label;
  final String? confirmationTaskId;
  final int workspaceVersion;
  final int completionPercent;
  final String scoringModel;
  final DateTime createdAt;
}

final class DigitalTwinCurrent {
  const DigitalTwinCurrent({
    required this.workspaceId,
    required this.agentProfileId,
    required this.state,
    required this.level,
    required this.pendingReviewCount,
    required this.pendingProposalCount,
    required this.files,
    required this.updatedAt,
    this.currentVersion,
    this.activeProposalIds = const [],
  });

  factory DigitalTwinCurrent.fromValue(Object? value) {
    final object = _object(value, 'digital twin');
    if (_string(object, 'schemaVersion') != 'huahuo.digital-twin.v1') {
      throw const FormatException('digital twin schema is invalid');
    }
    return DigitalTwinCurrent(
      workspaceId: _string(object, 'workspaceId'),
      agentProfileId: _string(object, 'agentProfileId'),
      state: _string(object, 'state'),
      level: DigitalTwinLevel.fromValue(object['level']),
      pendingReviewCount: _nonNegativeInt(object, 'pendingReviewCount'),
      pendingProposalCount: _nonNegativeInt(object, 'pendingProposalCount'),
      activeProposalIds: object['activeDraft'] is Map
          ? [
              for (final item in _list(
                _object(object['activeDraft'], 'activeDraft'),
                'items',
                (value) => _object(value, 'draft item'),
              ))
                _string(item, 'proposalId'),
            ]
          : const [],
      files: _list(object, 'files', DigitalTwinLogicalFile.fromValue),
      currentVersion: object['currentVersion'] == null
          ? null
          : DigitalTwinVersion.fromValue(object['currentVersion']),
      updatedAt: _date(object, 'updatedAt'),
    );
  }

  final String workspaceId;
  final String agentProfileId;
  final String state;
  final DigitalTwinLevel level;
  final int pendingReviewCount;
  final int pendingProposalCount;
  final List<String> activeProposalIds;
  final List<DigitalTwinLogicalFile> files;
  final DigitalTwinVersion? currentVersion;
  final DateTime updatedAt;
}

final class DigitalTwinScheduleDraft {
  const DigitalTwinScheduleDraft({
    required this.enabled,
    required this.intervalDays,
    required this.preferredLocalTime,
    required this.timezone,
    required this.instruction,
  });

  final bool enabled;
  final int intervalDays;
  final String preferredLocalTime;
  final String timezone;
  final String instruction;
}

final class DigitalTwinSchedule {
  const DigitalTwinSchedule({
    required this.enabled,
    required this.intervalDays,
    required this.preferredLocalTime,
    required this.timezone,
    required this.instruction,
    required this.sourceScope,
    required this.version,
    this.scheduleId,
    this.nextRunAt,
    this.lastFiredAt,
  });

  factory DigitalTwinSchedule.fromValue(Object? value) {
    final object = _object(value, 'schedule');
    return DigitalTwinSchedule(
      scheduleId: _optionalString(object, 'scheduleId'),
      enabled: _bool(object, 'enabled'),
      intervalDays: _intInRange(object, 'intervalDays', 1, 365),
      preferredLocalTime: _string(object, 'preferredLocalTime'),
      timezone: _string(object, 'timezone'),
      instruction: _string(object, 'instruction'),
      sourceScope: _string(object, 'sourceScope'),
      nextRunAt: _optionalDate(object, 'nextRunAt'),
      lastFiredAt: _optionalDate(object, 'lastFiredAt'),
      version: _nonNegativeInt(object, 'version'),
    );
  }

  final String? scheduleId;
  final bool enabled;
  final int intervalDays;
  final String preferredLocalTime;
  final String timezone;
  final String instruction;
  final String sourceScope;
  final DateTime? nextRunAt;
  final DateTime? lastFiredAt;
  final int version;

  DigitalTwinScheduleDraft get draft => DigitalTwinScheduleDraft(
    enabled: enabled,
    intervalDays: intervalDays,
    preferredLocalTime: preferredLocalTime,
    timezone: timezone,
    instruction: instruction,
  );
}

final class DigitalTwinProposalVersion {
  const DigitalTwinProposalVersion({
    required this.proposalId,
    required this.proposalVersion,
    required this.baseHash,
    required this.createdAt,
    this.candidateHash,
    this.diffBundleId,
    this.agentRunId,
  });

  factory DigitalTwinProposalVersion.fromValue(Object? value) {
    final object = _object(value, 'proposal version');
    return DigitalTwinProposalVersion(
      proposalId: _string(object, 'proposalId'),
      proposalVersion: _positiveInt(object, 'proposalVersion'),
      baseHash: _string(object, 'baseHash'),
      candidateHash: _optionalString(object, 'candidateHash'),
      diffBundleId: _optionalString(object, 'diffBundleId'),
      agentRunId: _optionalString(object, 'agentRunId'),
      createdAt: _date(object, 'createdAt'),
    );
  }

  final String proposalId;
  final int proposalVersion;
  final String baseHash;
  final String? candidateHash;
  final String? diffBundleId;
  final String? agentRunId;
  final DateTime createdAt;
}

final class DigitalTwinSelectedHunk {
  const DigitalTwinSelectedHunk({
    required this.proposalVersion,
    required this.diffBundleId,
    required this.hunkId,
    required this.quotedText,
  });

  final int proposalVersion;
  final String diffBundleId;
  final String hunkId;
  final String quotedText;
}

final class DigitalTwinConfirmationOutcome {
  const DigitalTwinConfirmationOutcome({
    required this.proposalId,
    required this.proposalVersion,
    this.state,
    this.failureCode,
  });

  factory DigitalTwinConfirmationOutcome.fromValue(Object? value) {
    final object = _object(value, 'confirmation outcome');
    final stateWire = _optionalString(object, 'state');
    return DigitalTwinConfirmationOutcome(
      proposalId: _string(object, 'proposalId'),
      proposalVersion: _positiveInt(object, 'proposalVersion'),
      state: stateWire == null
          ? null
          : DocumentProposalState.fromWire(stateWire),
      failureCode: _optionalString(object, 'failureCode'),
    );
  }

  final String proposalId;
  final int proposalVersion;
  final DocumentProposalState? state;
  final String? failureCode;
}

final class DigitalTwinConfirmation {
  const DigitalTwinConfirmation({
    required this.confirmationTaskId,
    required this.state,
    required this.outcomes,
    required this.appliedCount,
    required this.failedCount,
    this.version,
  });

  factory DigitalTwinConfirmation.fromValue(Object? value) {
    final object = _object(value, 'confirmation');
    return DigitalTwinConfirmation(
      confirmationTaskId: _string(object, 'confirmationTaskId'),
      state: _string(object, 'state'),
      outcomes: _list(
        object,
        'outcomes',
        DigitalTwinConfirmationOutcome.fromValue,
      ),
      appliedCount: _nonNegativeInt(object, 'appliedCount'),
      failedCount: _nonNegativeInt(object, 'failedCount'),
      version: object['version'] == null
          ? null
          : DigitalTwinVersion.fromValue(object['version']),
    );
  }

  final String confirmationTaskId;
  final String state;
  final List<DigitalTwinConfirmationOutcome> outcomes;
  final int appliedCount;
  final int failedCount;
  final DigitalTwinVersion? version;

  bool get isTerminal =>
      const {'report_ready', 'failed', 'cancelled'}.contains(state);
}

final class DigitalTwinVersionDetail {
  const DigitalTwinVersionDetail({
    required this.version,
    required this.operationKey,
    required this.rendererVersion,
    required this.profileCount,
    required this.hasPositioning,
    required this.proposalResults,
  });

  factory DigitalTwinVersionDetail.fromValue(Object? value) {
    final object = _object(value, 'version detail');
    final profiles = object['profiles'];
    if (profiles is! List) {
      throw const FormatException('version profiles are invalid');
    }
    return DigitalTwinVersionDetail(
      version: DigitalTwinVersion.fromValue(object),
      operationKey: _string(object, 'operationKey'),
      rendererVersion: _string(object, 'rendererVersion'),
      profileCount: profiles.length,
      hasPositioning: object['positioning'] != null,
      proposalResults: _list(
        object,
        'proposalResults',
        DigitalTwinConfirmationOutcome.fromValue,
      ),
    );
  }

  final DigitalTwinVersion version;
  final String operationKey;
  final String rendererVersion;
  final int profileCount;
  final bool hasPositioning;
  final List<DigitalTwinConfirmationOutcome> proposalResults;
}

final class DigitalTwinFileComparison {
  const DigitalTwinFileComparison({
    required this.id,
    required this.name,
    required this.summary,
    required this.hunks,
  });

  factory DigitalTwinFileComparison.fromValue(Object? value) {
    final object = _object(value, 'file comparison');
    return DigitalTwinFileComparison(
      id: _string(object, 'id'),
      name: _string(object, 'name'),
      summary: DocumentProposalDiffSummary.fromValue(object['summary']),
      hunks: _list(object, 'hunks', DocumentProposalDiffHunk.fromValue),
    );
  }

  final String id;
  final String name;
  final DocumentProposalDiffSummary summary;
  final List<DocumentProposalDiffHunk> hunks;
}

final class DigitalTwinVersionComparison {
  const DigitalTwinVersionComparison({
    required this.baseVersion,
    required this.version,
    required this.files,
  });

  factory DigitalTwinVersionComparison.fromValue(Object? value) {
    final object = _object(value, 'version comparison');
    return DigitalTwinVersionComparison(
      baseVersion: DigitalTwinVersion.fromValue(object['baseVersion']),
      version: DigitalTwinVersion.fromValue(object['version']),
      files: _list(object, 'files', DigitalTwinFileComparison.fromValue),
    );
  }

  final DigitalTwinVersion baseVersion;
  final DigitalTwinVersion version;
  final List<DigitalTwinFileComparison> files;
}

final class DigitalTwinRestore {
  const DigitalTwinRestore({
    required this.taskId,
    required this.versionId,
    required this.state,
    required this.proposalIds,
  });

  factory DigitalTwinRestore.fromValue(Object? value) {
    final object = _object(value, 'restore');
    return DigitalTwinRestore(
      taskId: _string(object, 'taskId'),
      versionId: _string(object, 'versionId'),
      state: _string(object, 'state'),
      proposalIds: _stringList(object, 'proposalIds'),
    );
  }

  final String taskId;
  final String versionId;
  final String state;
  final List<String> proposalIds;
}

Map<String, Object?> _object(Object? value, String field) {
  final object = asObjectMap(value);
  if (object == null) throw FormatException('$field is invalid');
  return object;
}

List<T> _list<T>(
  Map<String, Object?> object,
  String field,
  T Function(Object?) parser,
) => _valueList(object[field], parser, field: field);

List<T> _valueList<T>(
  Object? value,
  T Function(Object?) parser, {
  String field = 'items',
}) {
  if (value is! List) throw FormatException('$field is invalid');
  return List<T>.unmodifiable(value.map(parser));
}

List<String> _stringList(Map<String, Object?> object, String field) => _list(
  object,
  field,
  (value) => value is String && value.trim().isNotEmpty
      ? value.trim()
      : throw FormatException('$field is invalid'),
);

String _string(
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

String? _optionalString(Map<String, Object?> object, String field) {
  final value = object[field];
  if (value == null) return null;
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('$field is invalid');
  }
  return value.trim();
}

int _nonNegativeInt(Map<String, Object?> object, String field) {
  final value = object[field];
  if (value is! int || value < 0) throw FormatException('$field is invalid');
  return value;
}

int _positiveInt(Map<String, Object?> object, String field) {
  final value = object[field];
  if (value is! int || value < 1) throw FormatException('$field is invalid');
  return value;
}

int _intInRange(
  Map<String, Object?> object,
  String field,
  int minimum,
  int maximum,
) {
  final value = object[field];
  if (value is! int || value < minimum || value > maximum) {
    throw FormatException('$field is invalid');
  }
  return value;
}

bool _bool(Map<String, Object?> object, String field) {
  final value = object[field];
  if (value is! bool) throw FormatException('$field is invalid');
  return value;
}

DateTime _date(Map<String, Object?> object, String field) {
  final parsed = DateTime.tryParse(_string(object, field));
  if (parsed == null) throw FormatException('$field is invalid');
  return parsed;
}

DateTime? _optionalDate(Map<String, Object?> object, String field) {
  final value = object[field];
  if (value == null) return null;
  final parsed = value is String ? DateTime.tryParse(value) : null;
  if (parsed == null) throw FormatException('$field is invalid');
  return parsed;
}
