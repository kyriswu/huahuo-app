enum DigitalTwinMaterialStatus {
  awaitingConfirmation,
  waitingSource,
  submitting,
  generating,
  awaitingVersionVerification,
  reviewReady,
  noChanges,
  partialFailure,
  failed,
  completed,
  removed,
}

const digitalTwinMaterialProfileKinds = <String>[
  'user_profile',
  'viewpoints_and_methods',
  'language_and_expression',
];

final class DigitalTwinMaterialSource {
  const DigitalTwinMaterialSource({
    required this.workspaceId,
    required this.noteId,
    required this.rawPartRevisionId,
    required this.title,
  });

  final String workspaceId;
  final String noteId;
  final String rawPartRevisionId;
  final String title;

  Map<String, Object?> toJson() => {
    'workspaceId': workspaceId,
    'noteId': noteId,
    'rawPartRevisionId': rawPartRevisionId,
    'title': title,
  };

  factory DigitalTwinMaterialSource.fromJson(Map<String, Object?> value) =>
      DigitalTwinMaterialSource(
        workspaceId: value['workspaceId']! as String,
        noteId: value['noteId']! as String,
        rawPartRevisionId: value['rawPartRevisionId']! as String,
        title: value['title']! as String,
      );
}

final class DigitalTwinMaterial {
  DigitalTwinMaterial({
    required this.id,
    required this.referenceKind,
    required this.referenceId,
    required this.title,
    required this.createdAt,
    this.status = DigitalTwinMaterialStatus.awaitingConfirmation,
    this.source,
    Map<String, String> proposalIds = const {},
    this.confirmationId,
    this.versionId,
    this.errorCode,
    Map<String, String> confirmedVersions = const {},
    Set<String> confirmationTaskIds = const {},
  }) : proposalIds = Map.unmodifiable(proposalIds),
       confirmedVersions = Map.unmodifiable(confirmedVersions),
       confirmationTaskIds = Set.unmodifiable(confirmationTaskIds);

  final String id;
  final String referenceKind;
  final String referenceId;
  final String title;
  final DateTime createdAt;
  final DigitalTwinMaterialStatus status;
  final DigitalTwinMaterialSource? source;
  final Map<String, String> proposalIds;
  final String? confirmationId;
  final String? versionId;
  final String? errorCode;
  final Map<String, String> confirmedVersions;
  final Set<String> confirmationTaskIds;

  bool get isTerminal => const {
    DigitalTwinMaterialStatus.completed,
    DigitalTwinMaterialStatus.removed,
    DigitalTwinMaterialStatus.noChanges,
  }.contains(status);

  bool get canSubmit =>
      !isTerminal &&
      confirmationId == null &&
      proposalIds.length < digitalTwinMaterialProfileKinds.length;

  bool get canRemove =>
      proposalIds.isEmpty &&
      source == null &&
      const {
        DigitalTwinMaterialStatus.awaitingConfirmation,
        DigitalTwinMaterialStatus.waitingSource,
        DigitalTwinMaterialStatus.failed,
      }.contains(status);

  DigitalTwinMaterial copyWith({
    DigitalTwinMaterialStatus? status,
    DigitalTwinMaterialSource? source,
    Map<String, String>? proposalIds,
    String? confirmationId,
    String? versionId,
    String? errorCode,
    bool clearError = false,
    bool clearConfirmation = false,
    Map<String, String>? confirmedVersions,
    Set<String>? confirmationTaskIds,
  }) => DigitalTwinMaterial(
    id: id,
    referenceKind: referenceKind,
    referenceId: referenceId,
    title: source?.title ?? title,
    createdAt: createdAt,
    status: status ?? this.status,
    source: source ?? this.source,
    proposalIds: proposalIds ?? this.proposalIds,
    confirmationId: clearConfirmation
        ? null
        : confirmationId ?? this.confirmationId,
    versionId: versionId ?? this.versionId,
    errorCode: clearError ? null : errorCode ?? this.errorCode,
    confirmedVersions: confirmedVersions ?? this.confirmedVersions,
    confirmationTaskIds: confirmationTaskIds ?? this.confirmationTaskIds,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'referenceKind': referenceKind,
    'referenceId': referenceId,
    'title': title,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'status': status.name,
    'frozenSource': source?.toJson(),
    'proposalIds': proposalIds,
    'confirmationId': confirmationId,
    'versionId': versionId,
    'errorCode': errorCode,
    'confirmedVersions': confirmedVersions,
    'confirmationTaskIds': confirmationTaskIds.toList(),
  };

  factory DigitalTwinMaterial.fromJson(Map<String, Object?> value) =>
      DigitalTwinMaterial(
        id: value['id']! as String,
        referenceKind: value['referenceKind']! as String,
        referenceId: value['referenceId']! as String,
        title: value['title']! as String,
        createdAt: DateTime.parse(value['createdAt']! as String),
        status: DigitalTwinMaterialStatus.values.byName(
          value['status']! as String,
        ),
        source: value['frozenSource'] is Map
            ? DigitalTwinMaterialSource.fromJson(
                Map<String, Object?>.from(value['frozenSource']! as Map),
              )
            : null,
        proposalIds: Map<String, String>.from(value['proposalIds']! as Map),
        confirmationId: value['confirmationId'] as String?,
        versionId: value['versionId'] as String?,
        errorCode: value['errorCode'] as String?,
        confirmedVersions: Map<String, String>.from(
          value['confirmedVersions'] as Map? ?? const {},
        ),
        confirmationTaskIds: Set<String>.from(
          value['confirmationTaskIds'] as List? ?? const [],
        ),
      );
}

final class DigitalTwinRevisionEvent {
  const DigitalTwinRevisionEvent({
    required this.proposalId,
    required this.text,
    required this.isUser,
    this.eventId,
  });

  final String proposalId;
  final String text;
  final bool isUser;
  final String? eventId;

  Map<String, Object?> toJson() => {
    'proposalId': proposalId,
    'text': text,
    'isUser': isUser,
    'eventId': eventId,
  };

  factory DigitalTwinRevisionEvent.fromJson(Map<String, Object?> value) =>
      DigitalTwinRevisionEvent(
        proposalId: value['proposalId']! as String,
        text: value['text']! as String,
        isUser: value['isUser']! as bool,
        eventId: value['eventId'] as String?,
      );
}
