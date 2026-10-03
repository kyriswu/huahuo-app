import 'dart:convert';
import 'dart:typed_data';

import '../api/api_envelope.dart';
import '../proposals/document_proposal_models.dart';

const digitalTwinSchema = 'huahuo.digital-twin.v1';

final class DigitalTwinLevelDto {
  const DigitalTwinLevelDto({
    required this.value,
    required this.name,
    required this.completionPercent,
    required this.scoringModel,
  });

  factory DigitalTwinLevelDto.fromValue(Object? value) {
    final json = _object(value, 'level');
    return DigitalTwinLevelDto(
      value: _range(json, 'value', 0, 5),
      name: _string(json, 'name'),
      completionPercent: _range(json, 'completionPercent', 0, 100),
      scoringModel: _string(json, 'scoringModel'),
    );
  }

  final int value;
  final String name;
  final int completionPercent;
  final String scoringModel;
}

final class DigitalTwinSourceDto {
  const DigitalTwinSourceDto({
    required this.sourceRefId,
    required this.sourceKind,
    this.noteId,
    this.part,
    this.partRevisionId,
    this.messageId,
  });

  factory DigitalTwinSourceDto.fromValue(Object? value) {
    final json = _object(value, 'source');
    return DigitalTwinSourceDto(
      sourceRefId: _id(json, 'sourceRefId'),
      sourceKind: _string(json, 'sourceKind'),
      noteId: _optionalId(json, 'noteId'),
      part: _optionalString(json, 'part'),
      partRevisionId: _optionalId(json, 'partRevisionId'),
      messageId: _optionalId(json, 'messageId'),
    );
  }

  final String sourceRefId;
  final String sourceKind;
  final String? noteId;
  final String? part;
  final String? partRevisionId;
  final String? messageId;
}

final class DigitalTwinConclusionDto {
  DigitalTwinConclusionDto({
    required this.conclusionId,
    required this.profileKind,
    required this.state,
    required this.revision,
    required this.markdown,
    required this.sourceReviewNeeded,
    required Iterable<DigitalTwinSourceDto> sources,
    this.updatedAt,
  }) : sources = List.unmodifiable(sources);

  factory DigitalTwinConclusionDto.fromValue(Object? value) {
    final json = _object(value, 'conclusion');
    return DigitalTwinConclusionDto(
      conclusionId: _id(json, 'conclusionId'),
      profileKind: _string(json, 'profileKind'),
      state: _string(json, 'state'),
      revision: _positive(json, 'revision'),
      markdown: _text(json, 'markdown', allowEmpty: true),
      sourceReviewNeeded: _boolean(json, 'sourceReviewNeeded'),
      sources: _list(json, 'sources', DigitalTwinSourceDto.fromValue),
      updatedAt: _optionalDate(json, 'updatedAt'),
    );
  }

  final String conclusionId;
  final String profileKind;
  final String state;
  final int revision;
  final String markdown;
  final bool sourceReviewNeeded;
  final List<DigitalTwinSourceDto> sources;
  final DateTime? updatedAt;
}

final class DigitalTwinFileDto {
  DigitalTwinFileDto({
    required this.id,
    required this.name,
    required this.exists,
    required this.markdown,
    required Iterable<DigitalTwinConclusionDto> conclusions,
    required this.pendingCount,
    required Iterable<String> pendingProposalIds,
  }) : conclusions = List.unmodifiable(conclusions),
       pendingProposalIds = List.unmodifiable(pendingProposalIds);

  factory DigitalTwinFileDto.fromValue(Object? value) {
    final json = _object(value, 'file');
    return DigitalTwinFileDto(
      id: _id(json, 'id', dotted: true),
      name: _string(json, 'name'),
      exists: _boolean(json, 'exists'),
      markdown: _optionalText(json, 'markdown') ?? '',
      conclusions: _list(
        json,
        'conclusions',
        DigitalTwinConclusionDto.fromValue,
      ),
      pendingCount: _nonNegative(json, 'pendingCount'),
      pendingProposalIds: _stringList(json, 'pendingProposalIds', ids: true),
    );
  }

  final String id;
  final String name;
  final bool exists;
  final String markdown;
  final List<DigitalTwinConclusionDto> conclusions;
  final int pendingCount;
  final List<String> pendingProposalIds;
}

final class DigitalTwinVersionDto {
  const DigitalTwinVersionDto({
    required this.versionId,
    required this.versionNumber,
    required this.label,
    required this.workspaceVersion,
    required this.completionPercent,
    required this.scoringModel,
    required this.createdAt,
    this.confirmationTaskId,
  });

  factory DigitalTwinVersionDto.fromValue(Object? value) {
    final json = _object(value, 'version');
    return DigitalTwinVersionDto(
      versionId: _id(json, 'versionId'),
      versionNumber: _nonNegative(json, 'versionNumber'),
      label: _string(json, 'label'),
      confirmationTaskId: _optionalId(json, 'confirmationTaskId'),
      workspaceVersion: _nonNegative(json, 'workspaceVersion'),
      completionPercent: _range(json, 'completionPercent', 0, 100),
      scoringModel: _string(json, 'scoringModel'),
      createdAt: _date(json, 'createdAt'),
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

final class DigitalTwinDraftItemDto {
  DigitalTwinDraftItemDto({
    required this.proposalId,
    required this.proposalVersion,
    required this.etag,
    required this.state,
    required Iterable<String> fileIds,
    this.hasChanges,
    this.failureCode,
  }) : fileIds = List.unmodifiable(fileIds);

  factory DigitalTwinDraftItemDto.fromValue(Object? value) {
    final json = _object(value, 'draft item');
    return DigitalTwinDraftItemDto(
      proposalId: _id(json, 'proposalId'),
      proposalVersion: _positive(json, 'proposalVersion'),
      etag: _etag(json, 'etag'),
      state: DocumentProposalStateDto.parse(_string(json, 'state')),
      fileIds: _stringList(json, 'fileIds', ids: true, dotted: true),
      hasChanges: _optionalBool(json, 'hasChanges'),
      failureCode: _optionalString(json, 'failureCode'),
    );
  }

  final String proposalId;
  final int proposalVersion;
  final String etag;
  final DocumentProposalStateDto state;
  final List<String> fileIds;
  final bool? hasChanges;
  final String? failureCode;
}

final class DigitalTwinDraftDto {
  DigitalTwinDraftDto({
    required this.draftId,
    required this.revision,
    required this.etag,
    required this.state,
    required this.internalItemCount,
    required Iterable<DigitalTwinDraftItemDto> items,
  }) : items = List.unmodifiable(items);

  factory DigitalTwinDraftDto.fromValue(Object? value) {
    final json = _object(value, 'active draft');
    final items = _list(json, 'items', DigitalTwinDraftItemDto.fromValue);
    final count = _nonNegative(json, 'internalItemCount');
    if (items.length != count) {
      throw const FormatException('Invalid active draft item count');
    }
    return DigitalTwinDraftDto(
      draftId: _id(json, 'draftId'),
      revision: _positive(json, 'revision'),
      etag: _hash(json, 'etag'),
      state: _string(json, 'state'),
      internalItemCount: count,
      items: items,
    );
  }

  final String draftId;
  final int revision;
  final String etag;
  final String state;
  final int internalItemCount;
  final List<DigitalTwinDraftItemDto> items;
}

final class DigitalTwinCurrentDto {
  DigitalTwinCurrentDto({
    required this.workspaceId,
    required this.agentProfileId,
    required this.state,
    required this.level,
    required this.pendingReviewCount,
    required this.pendingProposalCount,
    required Iterable<DigitalTwinFileDto> files,
    required this.updatedAt,
    this.activeDraft,
    this.currentVersion,
  }) : files = List.unmodifiable(files);

  factory DigitalTwinCurrentDto.fromValue(
    Object? value, {
    required String expectedWorkspaceId,
  }) {
    final json = _object(value, 'digital twin');
    if (_string(json, 'schemaVersion') != digitalTwinSchema ||
        _id(json, 'workspaceId') != expectedWorkspaceId) {
      throw const FormatException('Invalid Digital Twin identity');
    }
    final pendingProposals = _nonNegative(json, 'pendingProposalCount');
    final draft = json['activeDraft'] == null
        ? null
        : DigitalTwinDraftDto.fromValue(json['activeDraft']);
    if ((draft == null ? 0 : 1) != pendingProposals) {
      throw const FormatException('Invalid Digital Twin draft projection');
    }
    return DigitalTwinCurrentDto(
      workspaceId: expectedWorkspaceId,
      agentProfileId: _id(json, 'agentProfileId'),
      state: _string(json, 'state'),
      level: DigitalTwinLevelDto.fromValue(json['level']),
      pendingReviewCount: _nonNegative(json, 'pendingReviewCount'),
      pendingProposalCount: pendingProposals,
      activeDraft: draft,
      files: _list(json, 'files', DigitalTwinFileDto.fromValue),
      currentVersion: json['currentVersion'] == null
          ? null
          : DigitalTwinVersionDto.fromValue(json['currentVersion']),
      updatedAt: _date(json, 'updatedAt'),
    );
  }

  final String workspaceId;
  final String agentProfileId;
  final String state;
  final DigitalTwinLevelDto level;
  final int pendingReviewCount;
  final int pendingProposalCount;
  final DigitalTwinDraftDto? activeDraft;
  final List<DigitalTwinFileDto> files;
  final DigitalTwinVersionDto? currentVersion;
  final DateTime updatedAt;
}

final class DigitalTwinScheduleDto {
  const DigitalTwinScheduleDto({
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

  factory DigitalTwinScheduleDto.fromValue(Object? value) {
    final json = _object(value, 'schedule');
    return DigitalTwinScheduleDto(
      scheduleId: _optionalId(json, 'scheduleId'),
      enabled: _boolean(json, 'enabled'),
      intervalDays: _range(json, 'intervalDays', 1, 365),
      preferredLocalTime: _clock(json, 'preferredLocalTime'),
      timezone: _timezone(json, 'timezone'),
      instruction: _boundedText(json, 'instruction', 4000),
      sourceScope: _string(json, 'sourceScope'),
      nextRunAt: _optionalDate(json, 'nextRunAt'),
      lastFiredAt: _optionalDate(json, 'lastFiredAt'),
      version: _nonNegative(json, 'version'),
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
}

final class DigitalTwinConfirmationOutcomeDto {
  const DigitalTwinConfirmationOutcomeDto({
    required this.proposalId,
    required this.proposalVersion,
    this.state,
    this.failureCode,
  });

  factory DigitalTwinConfirmationOutcomeDto.fromValue(Object? value) {
    final json = _object(value, 'confirmation outcome');
    return DigitalTwinConfirmationOutcomeDto(
      proposalId: _id(json, 'proposalId'),
      proposalVersion: _positive(json, 'proposalVersion'),
      state: json['state'] == null
          ? null
          : DocumentProposalStateDto.parse(_string(json, 'state')),
      failureCode: _optionalString(json, 'failureCode'),
    );
  }

  final String proposalId;
  final int proposalVersion;
  final DocumentProposalStateDto? state;
  final String? failureCode;
}

final class DigitalTwinConfirmationDto {
  DigitalTwinConfirmationDto({
    required this.confirmationTaskId,
    required this.workspaceId,
    required this.state,
    required Iterable<DigitalTwinConfirmationOutcomeDto> outcomes,
    required this.appliedCount,
    required this.failedCount,
    this.version,
  }) : outcomes = List.unmodifiable(outcomes);

  factory DigitalTwinConfirmationDto.fromValue(
    Object? value, {
    required String expectedWorkspaceId,
  }) {
    final json = _object(value, 'confirmation');
    if (_id(json, 'workspaceId') != expectedWorkspaceId) {
      throw const FormatException('Invalid confirmation Workspace');
    }
    return DigitalTwinConfirmationDto(
      confirmationTaskId: _id(json, 'confirmationTaskId'),
      workspaceId: expectedWorkspaceId,
      state: _string(json, 'state'),
      outcomes: _list(
        json,
        'outcomes',
        DigitalTwinConfirmationOutcomeDto.fromValue,
      ),
      appliedCount: _nonNegative(json, 'appliedCount'),
      failedCount: _nonNegative(json, 'failedCount'),
      version: json['version'] == null
          ? null
          : DigitalTwinVersionDto.fromValue(json['version']),
    );
  }

  final String confirmationTaskId;
  final String workspaceId;
  final String state;
  final List<DigitalTwinConfirmationOutcomeDto> outcomes;
  final int appliedCount;
  final int failedCount;
  final DigitalTwinVersionDto? version;
  bool get isTerminal => state == 'report_ready';
}

final class DigitalTwinVersionDetailDto {
  const DigitalTwinVersionDetailDto({
    required this.version,
    required this.operationKey,
    required this.rendererVersion,
    required this.profileCount,
    required this.hasPositioning,
    required this.proposalResults,
  });

  factory DigitalTwinVersionDetailDto.fromValue(Object? value) {
    final json = _object(value, 'version detail');
    if (_string(json, 'schemaVersion') != 'huahuo.digital-twin-manifest.v1' ||
        json['profiles'] is! List<Object?>) {
      throw const FormatException('Invalid version manifest');
    }
    return DigitalTwinVersionDetailDto(
      version: DigitalTwinVersionDto.fromValue(json),
      operationKey: _string(json, 'operationKey'),
      rendererVersion: _string(json, 'rendererVersion'),
      profileCount: (json['profiles']! as List<Object?>).length,
      hasPositioning: json['positioning'] != null,
      proposalResults: _list(
        json,
        'proposalResults',
        DigitalTwinConfirmationOutcomeDto.fromValue,
      ),
    );
  }

  final DigitalTwinVersionDto version;
  final String operationKey;
  final String rendererVersion;
  final int profileCount;
  final bool hasPositioning;
  final List<DigitalTwinConfirmationOutcomeDto> proposalResults;
}

final class DigitalTwinFileComparisonDto {
  DigitalTwinFileComparisonDto({
    required this.id,
    required this.name,
    required this.summary,
    required Iterable<DocumentProposalDiffHunkDto> hunks,
  }) : hunks = List.unmodifiable(hunks);

  factory DigitalTwinFileComparisonDto.fromValue(Object? value) {
    final json = _object(value, 'file comparison');
    return DigitalTwinFileComparisonDto(
      id: _id(json, 'id', dotted: true),
      name: _string(json, 'name'),
      summary: DocumentProposalDiffSummaryDto.fromValue(json['summary']),
      hunks: _list(json, 'hunks', DocumentProposalDiffHunkDto.fromValue),
    );
  }

  final String id;
  final String name;
  final DocumentProposalDiffSummaryDto summary;
  final List<DocumentProposalDiffHunkDto> hunks;
}

final class DigitalTwinComparisonDto {
  DigitalTwinComparisonDto({
    required this.baseVersion,
    required this.version,
    required Iterable<DigitalTwinFileComparisonDto> files,
  }) : files = List.unmodifiable(files);

  factory DigitalTwinComparisonDto.fromValue(Object? value) {
    final json = _object(value, 'version comparison');
    return DigitalTwinComparisonDto(
      baseVersion: DigitalTwinVersionDto.fromValue(json['baseVersion']),
      version: DigitalTwinVersionDto.fromValue(json['version']),
      files: _list(json, 'files', DigitalTwinFileComparisonDto.fromValue),
    );
  }

  final DigitalTwinVersionDto baseVersion;
  final DigitalTwinVersionDto version;
  final List<DigitalTwinFileComparisonDto> files;
}

final class DigitalTwinRestoreDto {
  DigitalTwinRestoreDto({
    required this.taskId,
    required this.versionId,
    required this.state,
    required Iterable<String> proposalIds,
  }) : proposalIds = List.unmodifiable(proposalIds);

  factory DigitalTwinRestoreDto.fromValue(Object? value) {
    final json = _object(value, 'restore');
    return DigitalTwinRestoreDto(
      taskId: _id(json, 'taskId'),
      versionId: _id(json, 'versionId'),
      state: _string(json, 'state'),
      proposalIds: _stringList(json, 'proposalIds', ids: true),
    );
  }

  final String taskId;
  final String versionId;
  final String state;
  final List<String> proposalIds;
}

final class DigitalTwinArchiveDto {
  DigitalTwinArchiveDto(Uint8List bytes) : bytes = Uint8List.fromList(bytes);
  final Uint8List bytes;
}

Map<String, Object?> _object(Object? value, String label) {
  final json = asObjectMap(value);
  if (json == null) throw FormatException('Invalid Digital Twin $label');
  return json;
}

String _text(Map<String, Object?> json, String key, {bool allowEmpty = false}) {
  final value = json[key];
  if (value is! String || (!allowEmpty && value.trim().isEmpty)) {
    throw FormatException('Invalid Digital Twin $key');
  }
  return value;
}

String _string(Map<String, Object?> json, String key) =>
    _text(json, key).trim();
String? _optionalText(Map<String, Object?> json, String key) =>
    json[key] == null ? null : _text(json, key, allowEmpty: true);
String? _optionalString(Map<String, Object?> json, String key) =>
    json[key] == null ? null : _string(json, key);
String _boundedText(Map<String, Object?> json, String key, int maxBytes) {
  final value = _string(json, key);
  if (utf8.encode(value).length > maxBytes) {
    throw FormatException('Invalid $key');
  }
  return value;
}

String _id(Map<String, Object?> json, String key, {bool dotted = false}) {
  final value = _string(json, key);
  final pattern = dotted ? r'^[A-Za-z0-9_.-]+$' : r'^[A-Za-z0-9_-]+$';
  if (value.length > 512 || !RegExp(pattern).hasMatch(value)) {
    throw FormatException('Invalid Digital Twin $key');
  }
  return value;
}

String? _optionalId(Map<String, Object?> json, String key) =>
    json[key] == null ? null : _id(json, key);
String _hash(Map<String, Object?> json, String key) {
  final value = _string(json, key);
  if (!RegExp(r'^sha256:[a-f0-9]{64}$').hasMatch(value)) {
    throw FormatException('Invalid Digital Twin $key');
  }
  return value;
}

String _etag(Map<String, Object?> json, String key) {
  final value = _string(json, key);
  if (!RegExp(r'^"dcp:[A-Za-z0-9_-]+:[1-9][0-9]*"$').hasMatch(value)) {
    throw FormatException('Invalid Digital Twin $key');
  }
  return value;
}

int _nonNegative(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! int || value < 0) throw FormatException('Invalid $key');
  return value;
}

int _positive(Map<String, Object?> json, String key) {
  final value = _nonNegative(json, key);
  if (value == 0) throw FormatException('Invalid $key');
  return value;
}

int _range(Map<String, Object?> json, String key, int min, int max) {
  final value = _nonNegative(json, key);
  if (value < min || value > max) throw FormatException('Invalid $key');
  return value;
}

bool _boolean(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! bool) throw FormatException('Invalid $key');
  return value;
}

bool? _optionalBool(Map<String, Object?> json, String key) =>
    json[key] == null ? null : _boolean(json, key);
DateTime _date(Map<String, Object?> json, String key) {
  final value = DateTime.tryParse(_string(json, key));
  if (value == null) throw FormatException('Invalid $key');
  return value;
}

DateTime? _optionalDate(Map<String, Object?> json, String key) =>
    json[key] == null ? null : _date(json, key);
String _clock(Map<String, Object?> json, String key) {
  final value = _string(json, key);
  if (!RegExp(r'^(?:[01][0-9]|2[0-3]):[0-5][0-9]$').hasMatch(value)) {
    throw FormatException('Invalid $key');
  }
  return value;
}

String _timezone(Map<String, Object?> json, String key) {
  final value = _string(json, key);
  if (value != 'UTC' &&
      !RegExp(r'^[A-Za-z]+(?:/[A-Za-z0-9_+\-]+)+$').hasMatch(value)) {
    throw FormatException('Invalid $key');
  }
  return value;
}

List<T> _list<T>(
  Map<String, Object?> json,
  String key,
  T Function(Object?) parse,
) {
  final value = json[key];
  if (value is! List<Object?> || value.length > 500) {
    throw FormatException('Invalid $key');
  }
  return List.unmodifiable(value.map(parse));
}

List<String> _stringList(
  Map<String, Object?> json,
  String key, {
  bool ids = false,
  bool dotted = false,
}) => _list(json, key, (value) {
  final item = <String, Object?>{'value': value};
  return ids ? _id(item, 'value', dotted: dotted) : _string(item, 'value');
});
