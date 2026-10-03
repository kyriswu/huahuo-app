final class BackendContractPage<T> {
  const BackendContractPage({required this.items, this.nextCursor});

  final List<T> items;
  final String? nextCursor;
}

final class BackendCommandAck {
  const BackendCommandAck({
    this.resourceId,
    this.status,
    this.revision,
    this.accepted,
  });

  final String? resourceId;
  final String? status;
  final int? revision;
  final bool? accepted;

  bool get isMeaningful =>
      resourceId != null ||
      status != null ||
      revision != null ||
      accepted != null;
}

final class ContentLineContract {
  const ContentLineContract({
    required this.id,
    required this.name,
    required this.isDefault,
    required this.isActive,
    this.revision,
  });

  final String id;
  final String name;
  final bool isDefault;
  final bool isActive;
  final int? revision;
}

final class TaskContract {
  const TaskContract({required this.id, required this.status, this.title});

  final String id;
  final String status;
  final String? title;
}

final class TaskEventContract {
  const TaskEventContract({
    required this.id,
    required this.type,
    required this.createdAt,
  });

  final String id;
  final String type;
  final DateTime createdAt;
}

final class MemoryNoteAppendContract {
  const MemoryNoteAppendContract({
    required this.id,
    required this.noteId,
    required this.status,
    this.revision,
  });

  final String id;
  final String noteId;
  final String status;
  final int? revision;
}

final class RecordingCardFileContract {
  const RecordingCardFileContract({
    required this.id,
    required this.name,
    required this.status,
    this.recordingId,
  });

  final String id;
  final String name;
  final String status;
  final String? recordingId;
}

final class RecordingContract {
  const RecordingContract({
    required this.id,
    required this.transcriptStatus,
    this.title,
  });

  final String id;
  final String transcriptStatus;
  final String? title;

  String get status => transcriptStatus;
}

final class WorkAiMaterialCandidateContract {
  const WorkAiMaterialCandidateContract({
    required this.id,
    required this.title,
    required this.sourceType,
  });

  final String id;
  final String title;
  final String sourceType;
}

final class FeedDepositSummaryContract {
  const FeedDepositSummaryContract({
    required this.pendingCount,
    required this.failedCount,
  });

  final int pendingCount;
  final int failedCount;
}

final class AssetsOverviewContract {
  const AssetsOverviewContract({
    required this.totalCount,
    required this.recordingCount,
  });

  final int totalCount;
  final int recordingCount;
}

final class RecordingAssetContract {
  const RecordingAssetContract({
    required this.id,
    required this.status,
    this.title,
  });

  final String id;
  final String status;
  final String? title;
}

final class MembershipContract {
  const MembershipContract({
    required this.tier,
    required this.status,
    this.expiresAt,
  });

  final String tier;
  final String status;
  final DateTime? expiresAt;
}

final class ProfileUpdateContract {
  const ProfileUpdateContract({required this.displayName});

  final String displayName;

  Map<String, Object?>? toJson() {
    final name = displayName.trim();
    if (name.isEmpty || name.length > 60 || containsUnsafeBackendText(name)) {
      return null;
    }
    return <String, Object?>{'displayName': name};
  }
}

final class ContentLineCreateContract {
  const ContentLineCreateContract({required this.name, this.description});

  final String name;
  final String? description;

  Map<String, Object?>? toJson() {
    final normalizedName = name.trim();
    final normalizedDescription = description?.trim();
    if (normalizedName.isEmpty ||
        normalizedName.length > 80 ||
        containsUnsafeBackendText(normalizedName) ||
        (normalizedDescription != null &&
            (normalizedDescription.length > 500 ||
                containsUnsafeBackendText(normalizedDescription)))) {
      return null;
    }
    return <String, Object?>{
      'name': normalizedName,
      if (normalizedDescription?.isNotEmpty == true)
        'description': normalizedDescription,
    };
  }
}

final class MemoryNoteUpdateContract {
  const MemoryNoteUpdateContract({
    required this.title,
    required this.markdown,
    required this.baseRevision,
  });

  final String title;
  final String markdown;
  final int baseRevision;

  Map<String, Object?>? toJson() {
    final normalizedTitle = title.trim();
    final normalizedMarkdown = markdown.trim();
    if (normalizedTitle.isEmpty ||
        normalizedTitle.length > 160 ||
        normalizedMarkdown.isEmpty ||
        normalizedMarkdown.length > 100000 ||
        baseRevision < 0 ||
        containsUnsafeBackendText(normalizedTitle) ||
        containsUnsafeBackendText(normalizedMarkdown)) {
      return null;
    }
    return <String, Object?>{
      'title': normalizedTitle,
      'markdown': normalizedMarkdown,
      'baseRevision': baseRevision,
    };
  }
}

final class AnalyticsEventContract {
  AnalyticsEventContract({
    required this.eventId,
    required this.name,
    Map<String, Object?> properties = const <String, Object?>{},
  }) : properties = Map<String, Object?>.unmodifiable(properties);

  final String eventId;
  final String name;
  final Map<String, Object?> properties;

  Map<String, Object?>? toJson() {
    if (!isSafeBackendIdentifier(eventId) ||
        !isSafeBackendIdentifier(name) ||
        properties.length > 30) {
      return null;
    }
    for (final entry in properties.entries) {
      if (!isSafeBackendIdentifier(entry.key) ||
          !_isSafeAnalyticsScalar(entry.value)) {
        return null;
      }
    }
    return <String, Object?>{
      'eventId': eventId,
      'name': name,
      'properties': properties,
    };
  }
}

bool isSafeBackendIdentifier(String value) =>
    RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$').hasMatch(value);

bool containsUnsafeBackendText(String value) => <RegExp>[
  RegExp(r'file://', caseSensitive: false),
  RegExp(r'(^|\s)/(?:Users|home|private|var)/', caseSensitive: false),
  RegExp(
    r'https?://[^\s]*(?:token|signature|x-amz-[^=]*)=',
    caseSensitive: false,
  ),
  RegExp(r'(?:access|refresh)[_-]?token\s*[:=]', caseSensitive: false),
  RegExp(r'(?:secret|api[_-]?key)\s*[:=]', caseSensitive: false),
].any((pattern) => pattern.hasMatch(value));

bool _isSafeAnalyticsScalar(Object? value) {
  if (value == null || value is bool) return true;
  if (value is num) return value.isFinite;
  return value is String &&
      value.length <= 200 &&
      !containsUnsafeBackendText(value);
}
