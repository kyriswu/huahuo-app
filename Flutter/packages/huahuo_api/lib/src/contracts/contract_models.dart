import 'json_readers.dart';

export '../billing/account_usage_models.dart';

final class SharedSmsCodeReceipt {
  const SharedSmsCodeReceipt({
    required this.smsRequestId,
    required this.cooldownSeconds,
  });

  factory SharedSmsCodeReceipt.fromJson(Map<String, Object?> json) {
    return SharedSmsCodeReceipt(
      smsRequestId: requiredString(json, 'smsRequestId'),
      cooldownSeconds: requiredInt(json, 'cooldownSeconds'),
    );
  }

  final String smsRequestId;
  final int cooldownSeconds;
}

final class SharedUser {
  const SharedUser({required this.userId, this.displayName});

  factory SharedUser.fromJson(Map<String, Object?> json) {
    final userId = optionalString(json, 'userId') ?? optionalString(json, 'id');
    if (userId == null) {
      throw const FormatException('user.userId is required');
    }
    return SharedUser(
      userId: userId,
      displayName:
          optionalString(json, 'displayName') ?? optionalString(json, 'name'),
    );
  }

  final String userId;
  final String? displayName;
}

final class SharedAuthTokens {
  const SharedAuthTokens({
    required this.accessToken,
    required this.refreshToken,
    this.tokenType = 'Bearer',
    this.accessTokenExpiresAt,
    this.expiresIn,
    this.rotated,
  });

  factory SharedAuthTokens.fromJson(Map<String, Object?> json) {
    final tokenType = optionalString(json, 'tokenType') ?? 'Bearer';
    if (tokenType != 'Bearer') {
      throw FormatException('tokenType must be Bearer, got $tokenType');
    }
    return SharedAuthTokens(
      accessToken: requiredString(json, 'accessToken'),
      refreshToken: requiredString(json, 'refreshToken'),
      tokenType: tokenType,
      accessTokenExpiresAt: _optionalDateTime(json, 'accessTokenExpiresAt'),
      expiresIn: _optionalInt(json, 'expiresIn'),
      rotated: _optionalBool(json, 'rotated'),
    );
  }

  final String accessToken;
  final String refreshToken;
  final String tokenType;
  final DateTime? accessTokenExpiresAt;
  final int? expiresIn;
  final bool? rotated;
}

final class SharedAuthSession {
  const SharedAuthSession({
    required this.tokens,
    required this.user,
    required this.onboardingRequired,
    required this.workspaceStatus,
    this.workspaceId,
    this.defaultContentLineId,
  });

  factory SharedAuthSession.fromJson(Map<String, Object?> json) {
    final workspace = json['workspace'] == null
        ? null
        : requiredObject(json, 'workspace');
    final workspaceStatus = workspace == null
        ? requiredString(json, 'workspaceStatus')
        : requiredString(workspace, 'status');
    const allowedStatuses = <String>{'ready', 'creating', 'sync_failed'};
    if (!allowedStatuses.contains(workspaceStatus)) {
      throw FormatException('unsupported workspaceStatus: $workspaceStatus');
    }
    return SharedAuthSession(
      tokens: SharedAuthTokens.fromJson(json),
      user: SharedUser.fromJson(requiredObject(json, 'user')),
      onboardingRequired: requiredBool(json, 'onboardingRequired'),
      workspaceStatus: workspaceStatus,
      workspaceId: workspace == null
          ? optionalString(json, 'workspaceId')
          : optionalString(workspace, 'workspaceId'),
      defaultContentLineId: workspace == null
          ? optionalString(json, 'defaultContentLineId')
          : optionalString(workspace, 'defaultContentLineId'),
    );
  }

  final SharedAuthTokens tokens;
  final SharedUser user;
  final bool onboardingRequired;
  final String workspaceStatus;
  final String? workspaceId;
  final String? defaultContentLineId;
}

final class SharedWorkspaceSummary {
  const SharedWorkspaceSummary({
    required this.workspaceId,
    required this.displayName,
    required this.state,
    required this.isDefault,
    required this.etag,
  });

  factory SharedWorkspaceSummary.fromJson(Map<String, Object?> json) {
    return SharedWorkspaceSummary(
      workspaceId: requiredString(json, 'workspaceId'),
      displayName: requiredString(json, 'displayName'),
      state: requiredString(json, 'state'),
      isDefault: requiredBool(json, 'isDefault'),
      etag: requiredString(json, 'etag'),
    );
  }

  final String workspaceId;
  final String displayName;
  final String state;
  final bool isDefault;
  final String etag;
}

final class SharedWorkspacePage {
  const SharedWorkspacePage({required this.items});

  factory SharedWorkspacePage.fromJson(Map<String, Object?> json) {
    return SharedWorkspacePage(
      items: requiredObjectList(
        json,
        'items',
      ).map(SharedWorkspaceSummary.fromJson).toList(growable: false),
    );
  }

  final List<SharedWorkspaceSummary> items;
}

final class SharedWorkspaceBootstrapResult {
  const SharedWorkspaceBootstrapResult({
    required this.workspaceId,
    required this.state,
    required this.etag,
    required this.bootstrapReceiptId,
    required this.bootstrapContentCursor,
    required this.contentCursor,
  });

  factory SharedWorkspaceBootstrapResult.fromJson(Map<String, Object?> json) =>
      SharedWorkspaceBootstrapResult(
        workspaceId: requiredString(json, 'workspaceId'),
        state: requiredString(json, 'state'),
        etag: requiredString(json, 'etag'),
        bootstrapReceiptId: requiredString(json, 'bootstrapReceiptId'),
        bootstrapContentCursor: _requiredContentCursor(
          json,
          'bootstrapContentCursor',
        ),
        contentCursor: _requiredContentCursor(json, 'contentCursor'),
      );

  final String workspaceId;
  final String state;
  final String etag;
  final String bootstrapReceiptId;
  final String bootstrapContentCursor;
  final String contentCursor;
}

final class SharedWorkspaceDetail {
  const SharedWorkspaceDetail({
    required this.summary,
    required this.bootstrapReceiptId,
    required this.bootstrapContentCursor,
    required this.contentCursor,
  });

  factory SharedWorkspaceDetail.fromJson(Map<String, Object?> json) {
    return SharedWorkspaceDetail(
      summary: SharedWorkspaceSummary.fromJson(json),
      bootstrapReceiptId: requiredString(json, 'bootstrapReceiptId'),
      bootstrapContentCursor: _requiredContentCursor(
        json,
        'bootstrapContentCursor',
      ),
      contentCursor: _requiredContentCursor(json, 'contentCursor'),
    );
  }

  final SharedWorkspaceSummary summary;
  final String bootstrapReceiptId;
  final String bootstrapContentCursor;
  final String contentCursor;
}

final class SharedWorkspaceStorageUsage {
  const SharedWorkspaceStorageUsage({
    required this.currentContentBytes,
    required this.retainedHistoryBytes,
    required this.resourceBytes,
    required this.logicalTotalBytes,
    required this.formalProjectionBytes,
    required this.userLogicalTotalBytes,
    required this.limitBytes,
    required this.remainingBytes,
    required this.fileCountLimit,
    required this.measurementStatus,
    required this.unmeasuredObjectCount,
    required this.calculatedAt,
  });

  factory SharedWorkspaceStorageUsage.fromJson(Map<String, Object?> json) {
    final measurementStatus = requiredString(json, 'measurementStatus');
    if (measurementStatus != 'complete' && measurementStatus != 'partial') {
      throw FormatException(
        'unsupported workspace measurementStatus: $measurementStatus',
      );
    }
    return SharedWorkspaceStorageUsage(
      currentContentBytes: requiredNonNegativeInt(json, 'currentContentBytes'),
      retainedHistoryBytes: requiredNonNegativeInt(
        json,
        'retainedHistoryBytes',
      ),
      resourceBytes: requiredNonNegativeInt(json, 'resourceBytes'),
      logicalTotalBytes: requiredNonNegativeInt(json, 'logicalTotalBytes'),
      formalProjectionBytes: requiredNonNegativeInt(
        json,
        'formalProjectionBytes',
      ),
      userLogicalTotalBytes: requiredNonNegativeInt(
        json,
        'userLogicalTotalBytes',
      ),
      limitBytes: requiredNonNegativeInt(json, 'limitBytes'),
      remainingBytes: requiredNonNegativeInt(json, 'remainingBytes'),
      fileCountLimit: _requiredNullableNonNegativeInt(json, 'fileCountLimit'),
      measurementStatus: measurementStatus,
      unmeasuredObjectCount: requiredNonNegativeInt(
        json,
        'unmeasuredObjectCount',
      ),
      calculatedAt: requiredDateTime(json, 'calculatedAt'),
    );
  }

  final int currentContentBytes;
  final int retainedHistoryBytes;
  final int resourceBytes;
  final int logicalTotalBytes;
  final int formalProjectionBytes;
  final int userLogicalTotalBytes;
  final int limitBytes;
  final int remainingBytes;
  final int? fileCountLimit;
  final String measurementStatus;
  final int unmeasuredObjectCount;
  final DateTime calculatedAt;
}

final class SharedRecordingCardDeviceBindingResponse {
  const SharedRecordingCardDeviceBindingResponse({required this.binding});

  factory SharedRecordingCardDeviceBindingResponse.fromJson(
    Map<String, Object?> json,
  ) {
    if (!json.containsKey('binding')) {
      throw const FormatException('binding must be present');
    }
    final rawBinding = json['binding'];
    if (rawBinding == null) {
      return const SharedRecordingCardDeviceBindingResponse(binding: null);
    }
    if (rawBinding is! Map) {
      throw const FormatException('binding must be an object or null');
    }
    return SharedRecordingCardDeviceBindingResponse(
      binding: SharedRecordingCardDeviceBinding.fromJson(
        rawBinding.map((key, value) => MapEntry(key.toString(), value)),
      ),
    );
  }

  final SharedRecordingCardDeviceBinding? binding;
}

final class SharedRecordingCardDeviceBinding {
  const SharedRecordingCardDeviceBinding({
    required this.bindingId,
    required this.deviceId,
    required this.serialNumberMasked,
    required this.status,
    required this.bindingGeneration,
    required this.boundAt,
    this.displayName,
    this.modelCode,
    this.firmwareVersion,
  });

  factory SharedRecordingCardDeviceBinding.fromJson(
    Map<String, Object?> json,
  ) => SharedRecordingCardDeviceBinding(
    bindingId: requiredString(json, 'bindingId'),
    deviceId: requiredString(json, 'deviceId'),
    serialNumberMasked: requiredString(json, 'serialNumberMasked'),
    displayName:
        optionalString(json, 'displayName') ??
        optionalString(json, 'deviceName'),
    modelCode: optionalString(json, 'modelCode'),
    firmwareVersion: optionalString(json, 'firmwareVersion'),
    status: requiredString(json, 'status'),
    bindingGeneration: _requiredPositiveInt(json, 'bindingGeneration'),
    boundAt: requiredDateTime(json, 'boundAt'),
  );

  final String bindingId;
  final String deviceId;
  final String serialNumberMasked;
  final String? displayName;
  final String? modelCode;
  final String? firmwareVersion;
  final String status;
  final int bindingGeneration;
  final DateTime boundAt;
}

final class SharedRecordingCardSignaturePayload {
  const SharedRecordingCardSignaturePayload({
    required this.protocolVersion,
    required this.purpose,
    required this.challengeId,
    required this.nonce,
    required this.serialNumber,
    required this.tenantId,
    required this.userId,
    required this.expiresAt,
    required this.ownershipEpoch,
  });

  factory SharedRecordingCardSignaturePayload.fromJson(
    Map<String, Object?> json,
  ) {
    final protocolVersion = requiredString(json, 'protocolVersion');
    final purpose = requiredString(json, 'purpose');
    final expiresAt = requiredString(json, 'expiresAt');
    if (protocolVersion != 'recording-card-proof.v1' || purpose != 'bind') {
      throw const FormatException('unsupported recording-card proof payload');
    }
    if (DateTime.tryParse(expiresAt) == null) {
      throw const FormatException('invalid recording-card proof expiry');
    }
    return SharedRecordingCardSignaturePayload(
      protocolVersion: protocolVersion,
      purpose: purpose,
      challengeId: requiredString(json, 'challengeId'),
      nonce: requiredString(json, 'nonce'),
      serialNumber: requiredString(json, 'serialNumber'),
      tenantId: requiredString(json, 'tenantId'),
      userId: requiredString(json, 'userId'),
      expiresAt: expiresAt,
      ownershipEpoch: requiredNonNegativeInt(json, 'ownershipEpoch'),
    );
  }

  final String protocolVersion;
  final String purpose;
  final String challengeId;
  final String nonce;
  final String serialNumber;
  final String tenantId;
  final String userId;
  final String expiresAt;
  final int ownershipEpoch;

  Map<String, Object?> toJson() => <String, Object?>{
    'protocolVersion': protocolVersion,
    'purpose': purpose,
    'challengeId': challengeId,
    'nonce': nonce,
    'serialNumber': serialNumber,
    'tenantId': tenantId,
    'userId': userId,
    'expiresAt': expiresAt,
    'ownershipEpoch': ownershipEpoch,
  };
}

final class SharedRecordingCardBindChallenge {
  const SharedRecordingCardBindChallenge({
    required this.challengeId,
    required this.nonce,
    required this.expiresAt,
    required this.payload,
  });

  factory SharedRecordingCardBindChallenge.fromJson(Map<String, Object?> json) {
    final challengeId = requiredString(json, 'challengeId');
    final nonce = requiredString(json, 'nonce');
    final expiresAtText = requiredString(json, 'expiresAt');
    final expiresAt = DateTime.tryParse(expiresAtText);
    if (expiresAt == null) {
      throw const FormatException('invalid recording-card challenge expiry');
    }
    final payload = requiredObject(json, 'payload');
    final parsedPayload = SharedRecordingCardSignaturePayload.fromJson(payload);
    final payloadExpiry = DateTime.parse(parsedPayload.expiresAt);
    if (parsedPayload.challengeId != challengeId ||
        parsedPayload.nonce != nonce ||
        payloadExpiry.toUtc() != expiresAt.toUtc()) {
      throw const FormatException('recording-card challenge payload mismatch');
    }
    return SharedRecordingCardBindChallenge(
      challengeId: challengeId,
      nonce: nonce,
      expiresAt: expiresAt,
      payload: parsedPayload,
    );
  }

  final String challengeId;
  final String nonce;
  final DateTime expiresAt;
  final SharedRecordingCardSignaturePayload payload;
}

final class SharedRecordingCardAttestationProof {
  const SharedRecordingCardAttestationProof({
    required this.scheme,
    required this.keyId,
    required this.signature,
  });

  final String scheme;
  final String keyId;
  final String signature;

  Map<String, Object?> toJson() => <String, Object?>{
    'scheme': scheme,
    'keyId': keyId,
    'signature': signature,
  };
}

final class SharedRecordingCardBindResponse {
  const SharedRecordingCardBindResponse({
    required this.binding,
    required this.idempotent,
  });

  factory SharedRecordingCardBindResponse.fromJson(Map<String, Object?> json) =>
      SharedRecordingCardBindResponse(
        binding: SharedRecordingCardDeviceBinding.fromJson(
          requiredObject(json, 'binding'),
        ),
        idempotent: requiredBool(json, 'idempotent'),
      );

  final SharedRecordingCardDeviceBinding binding;
  final bool idempotent;
}

final class SharedRecordingCardUnbindResponse {
  const SharedRecordingCardUnbindResponse({
    required this.bindingId,
    required this.deviceId,
    required this.status,
    required this.bindingGeneration,
    required this.resetRequired,
    required this.idempotent,
  });

  factory SharedRecordingCardUnbindResponse.fromJson(
    Map<String, Object?> json,
  ) => SharedRecordingCardUnbindResponse(
    bindingId: requiredString(json, 'bindingId'),
    deviceId: requiredString(json, 'deviceId'),
    status: requiredString(json, 'status'),
    bindingGeneration: _requiredPositiveInt(json, 'bindingGeneration'),
    resetRequired: requiredBool(json, 'resetRequired'),
    idempotent: requiredBool(json, 'idempotent'),
  );

  final String bindingId;
  final String deviceId;
  final String status;
  final int bindingGeneration;
  final bool resetRequired;
  final bool idempotent;
}

final class SharedWorkspaceFolder {
  const SharedWorkspaceFolder({
    required this.folderId,
    required this.parentFolderId,
    required this.displayName,
    required this.normalizedName,
    required this.state,
    required this.currentRevisionId,
    required this.etag,
    required this.contentCursor,
    this.workspaceId,
    this.systemSeedKey,
  });

  factory SharedWorkspaceFolder.fromJson(Map<String, Object?> json) {
    return SharedWorkspaceFolder(
      folderId: requiredString(json, 'folderId'),
      workspaceId: optionalString(json, 'workspaceId'),
      parentFolderId: _requiredNullableString(json, 'parentFolderId'),
      displayName: requiredString(json, 'displayName'),
      normalizedName: requiredString(json, 'normalizedName'),
      systemSeedKey: optionalString(json, 'systemSeedKey'),
      state: requiredString(json, 'state'),
      currentRevisionId: requiredString(json, 'currentRevisionId'),
      etag: requiredString(json, 'etag'),
      contentCursor: _requiredContentCursor(json, 'contentCursor'),
    );
  }

  final String folderId;
  final String? workspaceId;
  final String? parentFolderId;
  final String displayName;
  final String normalizedName;
  final String? systemSeedKey;
  final String state;
  final String currentRevisionId;
  final String etag;
  final String contentCursor;
}

final class SharedWorkspaceFolderList {
  const SharedWorkspaceFolderList({required this.folders});

  factory SharedWorkspaceFolderList.fromJson(Map<String, Object?> json) {
    return SharedWorkspaceFolderList(
      folders: requiredObjectList(
        json,
        'folders',
      ).map(SharedWorkspaceFolder.fromJson).toList(growable: false),
    );
  }

  final List<SharedWorkspaceFolder> folders;
}

final class SharedRecursiveFolderMutationResult {
  const SharedRecursiveFolderMutationResult({
    required this.affectedObjectCount,
    required this.firstContentCursor,
    required this.contentCursor,
  });

  factory SharedRecursiveFolderMutationResult.fromJson(
    Map<String, Object?> json,
  ) {
    return SharedRecursiveFolderMutationResult(
      affectedObjectCount: requiredNonNegativeInt(json, 'affectedObjectCount'),
      firstContentCursor: _requiredContentCursor(json, 'firstContentCursor'),
      contentCursor: _requiredContentCursor(json, 'contentCursor'),
    );
  }

  final int affectedObjectCount;
  final String firstContentCursor;
  final String contentCursor;
}

final class SharedWorkspaceOwnerRef {
  const SharedWorkspaceOwnerRef({
    required this.workspaceId,
    required this.kind,
    required this.id,
  });

  factory SharedWorkspaceOwnerRef.fromJson(Map<String, Object?> json) {
    final kind = _requiredWorkspaceObjectKind(json, 'kind');
    return SharedWorkspaceOwnerRef(
      workspaceId: requiredString(json, 'workspaceId'),
      kind: kind,
      id: requiredString(json, 'id'),
    );
  }

  final String workspaceId;
  final String kind;
  final String id;
}

final class SharedWorkspaceResourceRef {
  const SharedWorkspaceResourceRef({
    required this.resourceId,
    required this.order,
    required this.usage,
    required this.sha256,
    required this.mimeType,
    this.anchor,
    this.alt,
  });

  factory SharedWorkspaceResourceRef.fromJson(Map<String, Object?> json) {
    return SharedWorkspaceResourceRef(
      resourceId: requiredString(json, 'resourceId'),
      order: requiredNonNegativeInt(json, 'order'),
      usage: requiredString(json, 'usage'),
      anchor: _requiredNullableString(json, 'anchor'),
      alt: _requiredNullableString(json, 'alt'),
      sha256: requiredString(json, 'sha256'),
      mimeType: requiredString(json, 'mimeType'),
    );
  }

  final String resourceId;
  final int order;
  final String usage;
  final String? anchor;
  final String? alt;
  final String sha256;
  final String mimeType;
}

final class SharedWorkspaceSnapshotObject {
  const SharedWorkspaceSnapshotObject({
    required this.ownerRef,
    required this.tombstone,
    required this.etag,
    required this.resourceRefs,
    this.revisionId,
    this.version,
  });

  factory SharedWorkspaceSnapshotObject.fromJson(Map<String, Object?> json) {
    _requireExactlyOneIdentityFamily(json);
    return SharedWorkspaceSnapshotObject(
      ownerRef: SharedWorkspaceOwnerRef.fromJson(
        requiredObject(json, 'ownerRef'),
      ),
      tombstone: requiredBool(json, 'tombstone'),
      etag: requiredString(json, 'etag'),
      resourceRefs: requiredObjectList(
        json,
        'resourceRefs',
      ).map(SharedWorkspaceResourceRef.fromJson).toList(growable: false),
      revisionId: optionalString(json, 'revisionId'),
      version: optionalNonNegativeInt(json, 'version'),
    );
  }

  final SharedWorkspaceOwnerRef ownerRef;
  final bool tombstone;
  final String etag;
  final List<SharedWorkspaceResourceRef> resourceRefs;
  final String? revisionId;
  final int? version;
}

final class SharedWorkspaceContentSnapshot {
  const SharedWorkspaceContentSnapshot({
    required this.snapshotId,
    required this.atCursor,
    required this.folders,
    required this.objects,
    required this.hasMore,
    required this.nextPageToken,
  });

  factory SharedWorkspaceContentSnapshot.fromJson(Map<String, Object?> json) {
    return SharedWorkspaceContentSnapshot(
      snapshotId: requiredString(json, 'snapshotId'),
      atCursor: _requiredContentCursor(json, 'atCursor'),
      folders: requiredObjectList(
        json,
        'folders',
      ).map(SharedWorkspaceFolder.fromJson).toList(growable: false),
      objects: requiredObjectList(
        json,
        'objects',
      ).map(SharedWorkspaceSnapshotObject.fromJson).toList(growable: false),
      hasMore: requiredBool(json, 'hasMore'),
      nextPageToken: _requiredNullableString(json, 'nextPageToken'),
    );
  }

  final String snapshotId;
  final String atCursor;
  final List<SharedWorkspaceFolder> folders;
  final List<SharedWorkspaceSnapshotObject> objects;
  final bool hasMore;
  final String? nextPageToken;
}

final class SharedWorkspaceResourcePinDelta {
  const SharedWorkspaceResourcePinDelta({
    required this.added,
    required this.released,
  });

  factory SharedWorkspaceResourcePinDelta.fromJson(Map<String, Object?> json) {
    return SharedWorkspaceResourcePinDelta(
      added: _requiredStringList(json, 'added'),
      released: _requiredStringList(json, 'released'),
    );
  }

  final List<String> added;
  final List<String> released;
}

final class SharedWorkspaceContentEvent {
  const SharedWorkspaceContentEvent({
    required this.eventId,
    required this.workspaceId,
    required this.cursor,
    required this.operationId,
    required this.occurredAt,
    required this.objectKind,
    required this.objectId,
    required this.changeType,
    required this.tombstone,
    required this.resourcePinDelta,
    this.revisionId,
    this.previousRevisionId,
    this.version,
    this.previousVersion,
  });

  factory SharedWorkspaceContentEvent.fromJson(Map<String, Object?> json) {
    _requireExactlyOneIdentityFamily(json, allowPrevious: true);
    return SharedWorkspaceContentEvent(
      eventId: requiredString(json, 'eventId'),
      workspaceId: requiredString(json, 'workspaceId'),
      cursor: _requiredContentCursor(json, 'cursor'),
      operationId: requiredString(json, 'operationId'),
      occurredAt: requiredDateTime(json, 'occurredAt'),
      objectKind: _requiredWorkspaceObjectKind(json, 'objectKind'),
      objectId: requiredString(json, 'objectId'),
      changeType: requiredString(json, 'changeType'),
      tombstone: requiredBool(json, 'tombstone'),
      resourcePinDelta: SharedWorkspaceResourcePinDelta.fromJson(
        requiredObject(json, 'resourcePinDelta'),
      ),
      revisionId: optionalString(json, 'revisionId'),
      previousRevisionId: optionalString(json, 'previousRevisionId'),
      version: optionalNonNegativeInt(json, 'version'),
      previousVersion: optionalNonNegativeInt(json, 'previousVersion'),
    );
  }

  final String eventId;
  final String workspaceId;
  final String cursor;
  final String operationId;
  final DateTime occurredAt;
  final String objectKind;
  final String objectId;
  final String changeType;
  final bool tombstone;
  final SharedWorkspaceResourcePinDelta resourcePinDelta;
  final String? revisionId;
  final String? previousRevisionId;
  final int? version;
  final int? previousVersion;
}

final class SharedWorkspaceContentEventPage {
  const SharedWorkspaceContentEventPage({
    required this.events,
    required this.nextAfter,
    required this.hasMore,
  });

  factory SharedWorkspaceContentEventPage.fromJson(Map<String, Object?> json) {
    return SharedWorkspaceContentEventPage(
      events: requiredObjectList(
        json,
        'events',
      ).map(SharedWorkspaceContentEvent.fromJson).toList(growable: false),
      nextAfter: _requiredContentCursor(json, 'nextAfter'),
      hasMore: requiredBool(json, 'hasMore'),
    );
  }

  final List<SharedWorkspaceContentEvent> events;
  final String nextAfter;
  final bool hasMore;
}

final class SharedAssetMarkdownAnchor {
  const SharedAssetMarkdownAnchor({
    required this.anchorId,
    required this.title,
    required this.level,
  });

  factory SharedAssetMarkdownAnchor.fromJson(Map<String, Object?> json) {
    final level = requiredInt(json, 'level');
    if (level < 1 || level > 3) {
      throw FormatException('anchor.level must be 1, 2, or 3, got $level');
    }
    return SharedAssetMarkdownAnchor(
      anchorId: requiredString(json, 'anchorId'),
      title: requiredString(json, 'title'),
      level: level,
    );
  }

  final String anchorId;
  final String title;
  final int level;
}

final class SharedAssetMarkdownDocument {
  const SharedAssetMarkdownDocument({
    required this.documentId,
    required this.documentVersion,
    required this.title,
    required this.markdown,
    required this.renderedAt,
    required this.locale,
    required this.anchors,
    required this.allowedMarkdown,
    this.sourceUpdatedAt,
  });

  factory SharedAssetMarkdownDocument.fromJson(Map<String, Object?> json) {
    final schemaVersion = requiredString(json, 'schemaVersion');
    if (schemaVersion != 'personal_assets.markdown.v1') {
      throw FormatException('unsupported asset schemaVersion: $schemaVersion');
    }
    final imagePolicy = requiredString(json, 'imagePolicy');
    if (imagePolicy != 'none') {
      throw FormatException('unsupported asset imagePolicy: $imagePolicy');
    }
    return SharedAssetMarkdownDocument(
      documentId: requiredString(json, 'documentId'),
      documentVersion: requiredInt(json, 'documentVersion'),
      title: requiredString(json, 'title'),
      markdown: requiredString(json, 'markdown', allowEmpty: true),
      renderedAt: requiredDateTime(json, 'renderedAt'),
      sourceUpdatedAt: _optionalDateTime(json, 'sourceUpdatedAt'),
      locale: requiredString(json, 'locale'),
      anchors: requiredObjectList(
        json,
        'anchors',
      ).map(SharedAssetMarkdownAnchor.fromJson).toList(growable: false),
      allowedMarkdown: _requiredStringList(json, 'allowedMarkdown'),
    );
  }

  final String documentId;
  final int documentVersion;
  final String title;
  final String markdown;
  final DateTime renderedAt;
  final DateTime? sourceUpdatedAt;
  final String locale;
  final List<SharedAssetMarkdownAnchor> anchors;
  final List<String> allowedMarkdown;
}

final class SharedHNotePart {
  const SharedHNotePart({
    required this.partRevisionId,
    required this.markdown,
    required this.contentHash,
  });

  factory SharedHNotePart.fromJson(Map<String, Object?> json) {
    return SharedHNotePart(
      partRevisionId: requiredString(json, 'partRevisionId'),
      markdown: _requiredAliasedString(
        json,
        primary: 'contentMarkdown',
        compatibility: 'markdown',
        allowEmpty: true,
      ),
      contentHash: _requiredAliasedString(
        json,
        primary: 'contentSha256',
        compatibility: 'contentHash',
      ),
    );
  }

  final String partRevisionId;
  final String markdown;
  final String contentHash;
}

final class SharedHNotePartView {
  const SharedHNotePartView({
    required this.noteId,
    required this.part,
    required this.partRevisionId,
    required this.markdown,
    required this.contentHash,
    required this.etag,
  });

  factory SharedHNotePartView.fromJson(Map<String, Object?> json) {
    final part = requiredString(json, 'part');
    if (!_hNoteParts.contains(part)) {
      throw FormatException('unsupported HNote part: $part');
    }
    return SharedHNotePartView(
      noteId: requiredString(json, 'noteId'),
      part: part,
      partRevisionId: requiredString(json, 'partRevisionId'),
      markdown: _requiredAliasedString(
        json,
        primary: 'contentMarkdown',
        compatibility: 'markdown',
        allowEmpty: true,
      ),
      contentHash: _requiredAliasedString(
        json,
        primary: 'contentSha256',
        compatibility: 'contentHash',
      ),
      etag: requiredString(json, 'etag'),
    );
  }

  final String noteId;
  final String part;
  final String partRevisionId;
  final String markdown;
  final String contentHash;
  final String etag;
}

final class SharedHNoteResourceInput {
  SharedHNoteResourceInput({
    required String resourceId,
    required String usage,
    this.anchor,
    this.alt,
  }) : resourceId = resourceId.trim(),
       usage = usage.trim() {
    _validateChatIdentifier(this.resourceId, 'resourceId');
    if (this.usage.isEmpty) {
      throw ArgumentError.value(usage, 'usage', 'Usage must not be empty');
    }
  }

  final String resourceId;
  final String usage;
  final String? anchor;
  final String? alt;

  Map<String, Object?> toJson() => <String, Object?>{
    'resourceId': resourceId,
    'usage': usage,
    if (anchor != null) 'anchor': anchor,
    if (alt != null) 'alt': alt,
  };
}

final class SharedHNoteResourceRef {
  const SharedHNoteResourceRef({
    required this.resourceId,
    required this.order,
    required this.usage,
    required this.sha256,
    required this.mimeType,
    this.anchor,
    this.alt,
  });

  factory SharedHNoteResourceRef.fromJson(Map<String, Object?> json) {
    return SharedHNoteResourceRef(
      resourceId: requiredString(json, 'resourceId'),
      order: requiredNonNegativeInt(json, 'order'),
      usage: requiredString(json, 'usage'),
      anchor: _nullableString(json, 'anchor'),
      alt: _nullableString(json, 'alt'),
      sha256: requiredString(json, 'sha256'),
      mimeType: requiredString(json, 'mimeType'),
    );
  }

  final String resourceId;
  final int order;
  final String usage;
  final String? anchor;
  final String? alt;
  final String sha256;
  final String mimeType;
}

final class SharedHNoteSourceRef {
  const SharedHNoteSourceRef({
    required this.kind,
    required this.id,
    this.revisionId,
  });

  factory SharedHNoteSourceRef.fromJson(Map<String, Object?> json) {
    return SharedHNoteSourceRef(
      kind: requiredString(json, 'kind'),
      id: requiredString(json, 'id'),
      revisionId: optionalString(json, 'revisionId'),
    );
  }

  final String kind;
  final String id;
  final String? revisionId;
}

final class SharedHNote {
  const SharedHNote({
    required this.noteId,
    required this.folderId,
    required this.title,
    required this.state,
    required this.noteRevisionId,
    required this.raw,
    required this.outline,
    required this.germination,
    required this.resourceRefs,
    required this.etag,
    required this.contentCursor,
    this.workspaceId,
    this.sourceKind,
    this.sourceRef,
    this.activeDerivedTasks,
    this.createdAt,
    this.updatedAt,
  });

  factory SharedHNote.fromJson(Map<String, Object?> json) {
    final parts = json['parts'] is Map ? requiredObject(json, 'parts') : null;
    final rawRevision = _hNotePartRevision(
      json,
      parts,
      directKey: 'rawPartRevisionId',
      part: 'raw',
    );
    final outlineRevision = _hNotePartRevision(
      json,
      parts,
      directKey: 'outlinePartRevisionId',
      part: 'outline',
      allowAbsent: true,
    );
    final germinationRevision = _hNotePartRevision(
      json,
      parts,
      directKey: 'germinationPartRevisionId',
      part: 'germination',
      allowAbsent: true,
    );
    final activeDerivedTasks = json.containsKey('activeDerivedTasks')
        ? requiredObjectList(
            json,
            'activeDerivedTasks',
          ).map(SharedHNoteDerivedTask.fromJson).toList(growable: false)
        : null;
    return SharedHNote(
      noteId: requiredString(json, 'noteId'),
      workspaceId: optionalString(json, 'workspaceId'),
      sourceKind: optionalString(json, 'sourceKind'),
      sourceRef: json['sourceRef'] == null
          ? null
          : SharedHNoteSourceRef.fromJson(requiredObject(json, 'sourceRef')),
      folderId: _nullableString(json, 'folderId'),
      title: requiredString(json, 'title'),
      state: requiredString(json, 'state'),
      noteRevisionId: requiredString(json, 'noteRevisionId'),
      raw: _hNotePart(parts, 'raw', rawRevision),
      outline: _hNotePart(parts, 'outline', outlineRevision, allowAbsent: true),
      germination: _hNotePart(
        parts,
        'germination',
        germinationRevision,
        allowAbsent: true,
      ),
      resourceRefs: requiredObjectList(
        json,
        'resourceRefs',
      ).map(SharedHNoteResourceRef.fromJson).toList(growable: false),
      etag: requiredString(json, 'etag'),
      contentCursor: _requiredContentCursor(json, 'contentCursor'),
      activeDerivedTasks: activeDerivedTasks == null
          ? null
          : List<SharedHNoteDerivedTask>.unmodifiable(activeDerivedTasks),
      createdAt: _optionalDateTime(json, 'createdAt'),
      updatedAt: _optionalDateTime(json, 'updatedAt'),
    );
  }

  final String noteId;
  final String? workspaceId;
  final String? sourceKind;
  final SharedHNoteSourceRef? sourceRef;
  final String? folderId;
  final String title;
  final String state;
  final String noteRevisionId;
  final SharedHNotePart raw;
  final SharedHNotePart outline;
  final SharedHNotePart germination;
  final List<SharedHNoteResourceRef> resourceRefs;
  final String etag;
  final String contentCursor;
  final List<SharedHNoteDerivedTask>? activeDerivedTasks;
  final DateTime? createdAt;
  final DateTime? updatedAt;
}

/// Public HNote-derived task state. This deliberately excludes Agent routing,
/// prompt, Runtime, and result content; it is safe for UI recovery only.
final class SharedHNoteDerivedTask {
  const SharedHNoteDerivedTask({
    required this.fileAgentRunId,
    required this.stage,
    required this.status,
    this.agentRunId,
  });

  factory SharedHNoteDerivedTask.fromJson(Map<String, Object?> json) {
    final stage = requiredString(json, 'stage');
    if (stage != 'outline' && stage != 'sprout') {
      throw FormatException('unsupported activeDerivedTasks stage: $stage');
    }
    final status = requiredString(json, 'status');
    if (!_publicHNoteDerivedTaskStatuses.contains(status)) {
      throw FormatException('unsupported activeDerivedTasks status: $status');
    }
    return SharedHNoteDerivedTask(
      fileAgentRunId: _requiredOpaqueTaskIdentifier(json, 'fileAgentRunId'),
      agentRunId: _optionalOpaqueTaskIdentifier(json, 'agentRunId'),
      stage: stage,
      status: status,
    );
  }

  final String fileAgentRunId;
  final String? agentRunId;
  final String stage;
  final String status;

  bool get isTerminal => _publicHNoteDerivedTerminalStatuses.contains(status);
}

SharedHNotePart _hNotePart(
  Map<String, Object?>? parts,
  String part,
  String revision, {
  bool allowAbsent = false,
}) {
  if (parts == null || (allowAbsent && !parts.containsKey(part))) {
    return SharedHNotePart(
      partRevisionId: revision,
      markdown: '',
      contentHash: '',
    );
  }
  return SharedHNotePart.fromJson(requiredObject(parts, part));
}

String _hNotePartRevision(
  Map<String, Object?> json,
  Map<String, Object?>? parts, {
  required String directKey,
  required String part,
  bool allowAbsent = false,
}) {
  if (json.containsKey(directKey)) {
    final direct = json[directKey];
    if (allowAbsent &&
        (direct == null || (direct is String && direct.trim().isEmpty))) {
      return '';
    }
    return requiredString(json, directKey);
  }
  if (parts == null || (allowAbsent && !parts.containsKey(part))) {
    if (allowAbsent) return '';
    throw FormatException('$directKey or parts.$part is required');
  }
  final partObject = requiredObject(parts, part);
  final nested = partObject['partRevisionId'];
  if (allowAbsent &&
      (nested == null || (nested is String && nested.trim().isEmpty))) {
    return '';
  }
  return requiredString(partObject, 'partRevisionId');
}

String _requiredAliasedString(
  Map<String, Object?> json, {
  required String primary,
  required String compatibility,
  bool allowEmpty = false,
}) {
  if (json.containsKey(primary)) {
    return requiredString(json, primary, allowEmpty: allowEmpty);
  }
  return requiredString(json, compatibility, allowEmpty: allowEmpty);
}

final class SharedHNoteMutationReceipt {
  const SharedHNoteMutationReceipt({
    required this.noteId,
    required this.noteRevisionId,
    required this.rawPartRevisionId,
    required this.outlinePartRevisionId,
    required this.germinationPartRevisionId,
    required this.etag,
    required this.contentCursor,
  });

  factory SharedHNoteMutationReceipt.fromJson(Map<String, Object?> json) {
    final parts = json['parts'] == null ? null : requiredObject(json, 'parts');
    return SharedHNoteMutationReceipt(
      noteId: requiredString(json, 'noteId'),
      noteRevisionId: requiredString(json, 'noteRevisionId'),
      rawPartRevisionId: _mutationPartRevisionId(
        json,
        parts,
        directKey: 'rawPartRevisionId',
        part: 'raw',
      ),
      outlinePartRevisionId: _mutationPartRevisionId(
        json,
        parts,
        directKey: 'outlinePartRevisionId',
        part: 'outline',
      ),
      germinationPartRevisionId: _mutationPartRevisionId(
        json,
        parts,
        directKey: 'germinationPartRevisionId',
        part: 'germination',
      ),
      etag: requiredString(json, 'etag'),
      contentCursor: _requiredContentCursor(json, 'contentCursor'),
    );
  }

  final String noteId;
  final String noteRevisionId;
  final String rawPartRevisionId;
  final String outlinePartRevisionId;
  final String germinationPartRevisionId;
  final String etag;
  final String contentCursor;
}

/// One optimistic-concurrency input accepted by Workspace HNote batch moves.
final class SharedHNoteBatchMoveInput {
  const SharedHNoteBatchMoveInput({required this.noteId, required this.etag});

  final String noteId;
  final String etag;

  Map<String, Object?> toJson() => <String, Object?>{
    'noteId': noteId,
    'etag': etag,
  };
}

/// The intentionally narrow per-Note result of a Workspace batch move.
final class SharedHNoteBatchMoveReceipt {
  const SharedHNoteBatchMoveReceipt({
    required this.noteId,
    required this.noteRevisionId,
    required this.etag,
    required this.contentCursor,
  });

  factory SharedHNoteBatchMoveReceipt.fromJson(Map<String, Object?> json) {
    return SharedHNoteBatchMoveReceipt(
      noteId: requiredString(json, 'noteId'),
      noteRevisionId: requiredString(json, 'noteRevisionId'),
      etag: requiredString(json, 'etag'),
      contentCursor: _requiredContentCursor(json, 'contentCursor'),
    );
  }

  final String noteId;
  final String noteRevisionId;
  final String etag;
  final String contentCursor;
}

final class SharedHNoteBatchMoveResult {
  const SharedHNoteBatchMoveResult({required this.notes});

  factory SharedHNoteBatchMoveResult.fromJson(Map<String, Object?> json) {
    return SharedHNoteBatchMoveResult(
      notes: requiredObjectList(
        json,
        'notes',
      ).map(SharedHNoteBatchMoveReceipt.fromJson).toList(growable: false),
    );
  }

  final List<SharedHNoteBatchMoveReceipt> notes;
}

String _mutationPartRevisionId(
  Map<String, Object?> json,
  Map<String, Object?>? parts, {
  required String directKey,
  required String part,
}) {
  final direct = optionalString(json, directKey);
  if (direct != null) return direct;
  if (parts == null) {
    throw FormatException('$directKey or parts.$part is required');
  }
  return _partRevisionId(parts, part);
}

final class SharedWorkspaceSearchRequest {
  SharedWorkspaceSearchRequest._({
    required String query,
    required this.mode,
    this.keywordAttemptId,
    Iterable<String> ownerKinds = const <String>[],
    Iterable<String> noteParts = const <String>[],
    Iterable<String> folderIds = const <String>[],
    Iterable<String> noteTypeIds = const <String>[],
    this.from,
    this.to,
    this.limit,
  }) : query = query.trim(),
       ownerKinds = _validatedSearchValues(
         ownerKinds,
         'ownerKinds',
         _searchOwnerKinds,
       ),
       noteParts = _validatedSearchValues(noteParts, 'noteParts', _hNoteParts),
       folderIds = _validatedRemoteIds(folderIds, 'folderIds'),
       noteTypeIds = _validatedRemoteIds(noteTypeIds, 'noteTypeIds') {
    if (this.query.isEmpty) {
      throw ArgumentError.value(query, 'query', 'Query must not be empty');
    }
    if (mode == 'semantic') {
      final receipt = keywordAttemptId?.trim();
      if (receipt == null || receipt.isEmpty) {
        throw ArgumentError.value(
          keywordAttemptId,
          'keywordAttemptId',
          'Semantic search requires a keyword-miss receipt',
        );
      }
    } else if (keywordAttemptId != null) {
      throw ArgumentError.value(
        keywordAttemptId,
        'keywordAttemptId',
        'Only semantic search accepts a keyword-miss receipt',
      );
    }
    if (from != null && to != null && from!.isAfter(to!)) {
      throw ArgumentError.value(from, 'from', 'Must not be after to');
    }
    if (limit != null && (limit! < 1 || limit! > 30)) {
      throw ArgumentError.value(
        limit,
        'limit',
        'Expected a value from 1 to 30',
      );
    }
  }

  factory SharedWorkspaceSearchRequest.keyword({
    required String query,
    Iterable<String> ownerKinds = const <String>[],
    Iterable<String> noteParts = const <String>[],
    Iterable<String> folderIds = const <String>[],
    Iterable<String> noteTypeIds = const <String>[],
    DateTime? from,
    DateTime? to,
    int? limit,
  }) => SharedWorkspaceSearchRequest._(
    query: query,
    mode: 'keyword',
    ownerKinds: ownerKinds,
    noteParts: noteParts,
    folderIds: folderIds,
    noteTypeIds: noteTypeIds,
    from: from,
    to: to,
    limit: limit,
  );

  factory SharedWorkspaceSearchRequest.semantic({
    required String query,
    required String keywordAttemptId,
    Iterable<String> ownerKinds = const <String>[],
    Iterable<String> noteParts = const <String>[],
    Iterable<String> folderIds = const <String>[],
    Iterable<String> noteTypeIds = const <String>[],
    DateTime? from,
    DateTime? to,
    int? limit,
  }) => SharedWorkspaceSearchRequest._(
    query: query,
    mode: 'semantic',
    keywordAttemptId: keywordAttemptId,
    ownerKinds: ownerKinds,
    noteParts: noteParts,
    folderIds: folderIds,
    noteTypeIds: noteTypeIds,
    from: from,
    to: to,
    limit: limit,
  );

  /// Legacy compatibility only. New Mobile/Desktop flows must use keyword or
  /// receipt-gated semantic search.
  factory SharedWorkspaceSearchRequest.hybrid({
    required String query,
    Iterable<String> ownerKinds = const <String>[],
    Iterable<String> noteParts = const <String>[],
    Iterable<String> folderIds = const <String>[],
    Iterable<String> noteTypeIds = const <String>[],
    DateTime? from,
    DateTime? to,
    int? limit,
  }) => SharedWorkspaceSearchRequest._(
    query: query,
    mode: 'hybrid',
    ownerKinds: ownerKinds,
    noteParts: noteParts,
    folderIds: folderIds,
    noteTypeIds: noteTypeIds,
    from: from,
    to: to,
    limit: limit,
  );

  factory SharedWorkspaceSearchRequest.hybridCompatibility({
    required String query,
    Iterable<String> ownerKinds = const <String>[],
    Iterable<String> noteParts = const <String>[],
    Iterable<String> folderIds = const <String>[],
    Iterable<String> noteTypeIds = const <String>[],
    DateTime? from,
    DateTime? to,
    int? limit,
  }) => SharedWorkspaceSearchRequest.hybrid(
    query: query,
    ownerKinds: ownerKinds,
    noteParts: noteParts,
    folderIds: folderIds,
    noteTypeIds: noteTypeIds,
    from: from,
    to: to,
    limit: limit,
  );

  final String query;
  final String mode;
  final String? keywordAttemptId;
  final List<String> ownerKinds;
  final List<String> noteParts;
  final List<String> folderIds;
  final List<String> noteTypeIds;
  final DateTime? from;
  final DateTime? to;
  final int? limit;

  Map<String, Object?> toJson() => <String, Object?>{
    'query': query,
    'mode': mode,
    if (keywordAttemptId != null) 'keywordAttemptId': keywordAttemptId,
    if (ownerKinds.isNotEmpty) 'ownerKinds': ownerKinds,
    if (noteParts.isNotEmpty) 'noteParts': noteParts,
    if (folderIds.isNotEmpty) 'folderIds': folderIds,
    if (noteTypeIds.isNotEmpty) 'noteTypeIds': noteTypeIds,
    if (from != null) 'from': from!.toUtc().toIso8601String(),
    if (to != null) 'to': to!.toUtc().toIso8601String(),
    if (limit != null) 'limit': limit,
  };
}

final class SharedWorkspaceSearchResult {
  const SharedWorkspaceSearchResult({
    required this.ownerRef,
    required this.revisionId,
    required this.path,
    required this.updatedAt,
    required this.matchMode,
    required this.score,
    required this.staleSource,
    this.part,
    this.title,
  });

  factory SharedWorkspaceSearchResult.fromJson(Map<String, Object?> json) {
    _rejectSearchSensitiveFields(json);
    final ownerRef = SharedWorkspaceOwnerRef.fromJson(
      requiredObject(json, 'ownerRef'),
    );
    if (!_searchOwnerKinds.contains(ownerRef.kind)) {
      throw FormatException(
        'unsupported searchable owner kind: ${ownerRef.kind}',
      );
    }
    final part = optionalString(json, 'part');
    if (part != null && !_hNoteParts.contains(part)) {
      throw FormatException('unsupported search result part: $part');
    }
    final matchMode = requiredString(json, 'matchMode');
    if (!_searchModes.contains(matchMode)) {
      throw FormatException('unsupported search matchMode: $matchMode');
    }
    return SharedWorkspaceSearchResult(
      ownerRef: ownerRef,
      revisionId: requiredString(json, 'revisionId'),
      part: part,
      path: _requiredLogicalManagedPath(json, 'path'),
      title: optionalString(json, 'title'),
      updatedAt: requiredDateTime(json, 'updatedAt'),
      matchMode: matchMode,
      score: _requiredFiniteNumber(json, 'score'),
      staleSource: _optionalBool(json, 'staleSource') ?? false,
    );
  }

  final SharedWorkspaceOwnerRef ownerRef;
  final String revisionId;
  final String? part;
  final String path;
  final String? title;
  final DateTime updatedAt;
  final String matchMode;
  final double score;
  final bool staleSource;
}

final class SharedWorkspaceSearchOutput {
  const SharedWorkspaceSearchOutput({
    required this.mode,
    required this.queryFingerprint,
    required this.keywordReadiness,
    required this.vectorReadiness,
    required this.contentCursor,
    required this.results,
    this.keywordAttemptId,
    this.vectorStatus,
  });

  factory SharedWorkspaceSearchOutput.fromJson(Map<String, Object?> json) {
    _rejectSearchSensitiveFields(json);
    final mode = requiredString(json, 'mode');
    if (!_searchModes.contains(mode)) {
      throw FormatException('unsupported search mode: $mode');
    }
    final keywordReadiness = requiredString(json, 'keywordReadiness');
    final vectorReadiness = requiredString(json, 'vectorReadiness');
    if (!_searchReadiness.contains(keywordReadiness) ||
        !_searchReadiness.contains(vectorReadiness)) {
      throw const FormatException('unsupported search readiness');
    }
    final vectorStatus = optionalString(json, 'vectorStatus');
    if (vectorStatus != null && !_vectorStatuses.contains(vectorStatus)) {
      throw FormatException('unsupported vectorStatus: $vectorStatus');
    }
    final results = requiredObjectList(
      json,
      'results',
    ).map(SharedWorkspaceSearchResult.fromJson).toList(growable: false);
    final keywordAttemptId = optionalString(json, 'keywordAttemptId');
    if (keywordAttemptId != null && mode == 'keyword' && results.isNotEmpty) {
      throw const FormatException(
        'non-empty keyword result cannot issue keywordAttemptId',
      );
    }
    return SharedWorkspaceSearchOutput(
      mode: mode,
      queryFingerprint: requiredString(json, 'queryFingerprint'),
      keywordReadiness: keywordReadiness,
      vectorReadiness: vectorReadiness,
      contentCursor: _requiredContentCursor(json, 'contentCursor'),
      keywordAttemptId: keywordAttemptId,
      vectorStatus: vectorStatus,
      results: results,
    );
  }

  final String mode;
  final String queryFingerprint;
  final String keywordReadiness;
  final String vectorReadiness;
  final String contentCursor;
  final String? keywordAttemptId;
  final String? vectorStatus;
  final List<SharedWorkspaceSearchResult> results;
}

final class SharedNotePartSourceRef {
  SharedNotePartSourceRef({
    required String noteId,
    required String part,
    required String partRevisionId,
  }) : noteId = noteId.trim(),
       part = part.trim(),
       partRevisionId = partRevisionId.trim() {
    _validateOpaqueInput(this.noteId, 'noteId');
    _validateNotePart(this.part, 'part');
    _validateOpaqueInput(this.partRevisionId, 'partRevisionId');
  }

  factory SharedNotePartSourceRef.fromJson(Map<String, Object?> json) {
    final part = requiredString(json, 'part');
    if (!_hNoteParts.contains(part)) {
      throw FormatException('unsupported Note part: $part');
    }
    return SharedNotePartSourceRef(
      noteId: requiredString(json, 'noteId'),
      part: part,
      partRevisionId: requiredString(json, 'partRevisionId'),
    );
  }

  final String noteId;
  final String part;
  final String partRevisionId;

  Map<String, Object?> toJson() => <String, Object?>{
    'noteId': noteId,
    'part': part,
    'partRevisionId': partRevisionId,
  };
}

final class SharedNotePartRevisionRef {
  SharedNotePartRevisionRef({
    required String part,
    required String partRevisionId,
  }) : part = part.trim(),
       partRevisionId = partRevisionId.trim() {
    _validateNotePart(this.part, 'part');
    _validateOpaqueInput(this.partRevisionId, 'partRevisionId');
  }

  final String part;
  final String partRevisionId;

  Map<String, Object?> toJson() => <String, Object?>{
    'part': part,
    'partRevisionId': partRevisionId,
  };
}

sealed class SharedNoteRelation {
  const SharedNoteRelation({
    required this.relationId,
    required this.relationType,
    required this.origin,
    required this.source,
    required this.target,
  });

  factory SharedNoteRelation.fromJson(Map<String, Object?> json) {
    final origin = requiredString(json, 'origin');
    return switch (origin) {
      'explicit' => SharedExplicitNoteRelation.fromJson(json),
      'automatic' => SharedAutomaticNoteRelation.fromJson(json),
      _ => throw FormatException('unsupported relation origin: $origin'),
    };
  }

  final String relationId;
  final String relationType;
  final String origin;
  final SharedNotePartSourceRef source;
  final SharedNotePartSourceRef target;
}

final class SharedExplicitNoteRelation extends SharedNoteRelation {
  const SharedExplicitNoteRelation({
    required super.relationId,
    required super.relationType,
    required super.source,
    required super.target,
    required this.rationale,
    required this.version,
    required this.etag,
  }) : super(origin: 'explicit');

  factory SharedExplicitNoteRelation.fromJson(Map<String, Object?> json) {
    final relationType = requiredString(json, 'relationType');
    if (!_explicitRelationTypes.contains(relationType)) {
      throw FormatException('unsupported explicit relationType: $relationType');
    }
    if (requiredString(json, 'origin') != 'explicit') {
      throw const FormatException('explicit relation origin is required');
    }
    return SharedExplicitNoteRelation(
      relationId: requiredString(json, 'relationId'),
      relationType: relationType,
      source: SharedNotePartSourceRef.fromJson(requiredObject(json, 'source')),
      target: SharedNotePartSourceRef.fromJson(requiredObject(json, 'target')),
      rationale: requiredString(json, 'rationale'),
      version: _requiredPositiveInt(json, 'version'),
      etag: requiredString(json, 'etag'),
    );
  }

  final String rationale;
  final int version;
  final String etag;
}

final class SharedAutomaticNoteRelation extends SharedNoteRelation {
  const SharedAutomaticNoteRelation({
    required super.relationId,
    required super.source,
    required super.target,
    required this.score,
    required this.embeddingVersion,
    required this.algorithmVersion,
  }) : super(relationType: 'similar', origin: 'automatic');

  factory SharedAutomaticNoteRelation.fromJson(Map<String, Object?> json) {
    if (requiredString(json, 'origin') != 'automatic' ||
        requiredString(json, 'relationType') != 'similar') {
      throw const FormatException('automatic relations must be similar');
    }
    return SharedAutomaticNoteRelation(
      relationId: requiredString(json, 'relationId'),
      source: SharedNotePartSourceRef.fromJson(requiredObject(json, 'source')),
      target: SharedNotePartSourceRef.fromJson(requiredObject(json, 'target')),
      score: _requiredFiniteNumber(json, 'score'),
      embeddingVersion: requiredString(json, 'embeddingVersion'),
      algorithmVersion: requiredString(json, 'algorithmVersion'),
    );
  }

  final double score;
  final String embeddingVersion;
  final String algorithmVersion;
}

final class SharedNoteRelationPage {
  const SharedNoteRelationPage({required this.items, this.nextCursor});

  factory SharedNoteRelationPage.fromJson(Map<String, Object?> json) =>
      SharedNoteRelationPage(
        items: requiredObjectList(
          json,
          'items',
        ).map(SharedNoteRelation.fromJson).toList(growable: false),
        nextCursor: optionalString(json, 'nextCursor'),
      );

  final List<SharedNoteRelation> items;
  final String? nextCursor;
}

final class SharedCreateExplicitNoteRelationRequest {
  SharedCreateExplicitNoteRelationRequest({
    required String relationType,
    required this.source,
    required this.target,
    required String rationale,
  }) : relationType = relationType.trim(),
       rationale = rationale.trim() {
    if (!_explicitRelationTypes.contains(this.relationType)) {
      throw ArgumentError.value(
        relationType,
        'relationType',
        'Only causal, supports, or contradicts may be explicit',
      );
    }
    if (this.rationale.isEmpty) {
      throw ArgumentError.value(rationale, 'rationale', 'Must not be empty');
    }
  }

  final String relationType;
  final SharedNotePartRevisionRef source;
  final SharedNotePartSourceRef target;
  final String rationale;

  Map<String, Object?> toJson() => <String, Object?>{
    'relationType': relationType,
    'source': source.toJson(),
    'target': target.toJson(),
    'rationale': rationale,
  };
}

final class SharedUpdateExplicitNoteRelationRequest {
  SharedUpdateExplicitNoteRelationRequest({
    String? relationType,
    this.target,
    String? rationale,
  }) : relationType = relationType?.trim(),
       rationale = rationale?.trim() {
    if (this.relationType != null &&
        !_explicitRelationTypes.contains(this.relationType)) {
      throw ArgumentError.value(relationType, 'relationType');
    }
    if (this.rationale != null && this.rationale!.isEmpty) {
      throw ArgumentError.value(rationale, 'rationale', 'Must not be empty');
    }
    if (this.relationType == null && target == null && this.rationale == null) {
      throw ArgumentError.value(
        null,
        'request',
        'At least one field is required',
      );
    }
  }

  final String? relationType;
  final SharedNotePartSourceRef? target;
  final String? rationale;

  Map<String, Object?> toJson() => <String, Object?>{
    if (relationType != null) 'relationType': relationType,
    if (target != null) 'target': target!.toJson(),
    if (rationale != null) 'rationale': rationale,
  };
}

final class SharedSubscriptionPage<T> {
  const SharedSubscriptionPage({required this.items, this.nextCursor});

  factory SharedSubscriptionPage.fromJson(
    Map<String, Object?> json,
    T Function(Map<String, Object?>) parseItem,
  ) {
    return SharedSubscriptionPage<T>(
      items: requiredObjectList(
        json,
        'items',
      ).map(parseItem).toList(growable: false),
      nextCursor: optionalString(json, 'nextCursor'),
    );
  }

  final List<T> items;
  final String? nextCursor;
}

final class SharedSubscriptionPublication {
  const SharedSubscriptionPublication({
    required this.publicationId,
    required this.title,
    required this.updatedAt,
    this.summary,
    this.coverResourceId,
    this.lifecycle,
    this.sectionCount,
    this.articleCount,
  });

  factory SharedSubscriptionPublication.fromJson(Map<String, Object?> json) {
    return SharedSubscriptionPublication(
      publicationId: requiredString(json, 'publicationId'),
      title: requiredString(json, 'title'),
      summary:
          optionalString(json, 'description') ??
          optionalString(json, 'summary'),
      coverResourceId: optionalString(json, 'coverResourceId'),
      lifecycle: optionalString(json, 'lifecycle'),
      sectionCount: _optionalSubscriptionCount(json, 'sectionCount'),
      articleCount: _optionalSubscriptionCount(json, 'articleCount'),
      updatedAt: requiredDateTime(json, 'updatedAt'),
    );
  }

  final String publicationId;
  final String title;
  final String? summary;
  final String? coverResourceId;
  final String? lifecycle;
  final int? sectionCount;
  final int? articleCount;
  final DateTime updatedAt;
}

final class SharedSubscriptionSection {
  const SharedSubscriptionSection({
    required this.sectionId,
    required this.publicationId,
    required this.title,
    required this.sortOrder,
    this.parentSectionId,
    this.lifecycle,
  });

  factory SharedSubscriptionSection.fromJson(Map<String, Object?> json) {
    return SharedSubscriptionSection(
      sectionId: requiredString(json, 'sectionId'),
      publicationId: requiredString(json, 'publicationId'),
      parentSectionId: optionalString(json, 'parentSectionId'),
      title: requiredString(json, 'title'),
      sortOrder: _requiredSubscriptionOrdinal(json),
      lifecycle: optionalString(json, 'lifecycle'),
    );
  }

  final String sectionId;
  final String publicationId;
  final String? parentSectionId;
  final String title;
  final int sortOrder;
  final String? lifecycle;
}

final class SharedSubscriptionArticle {
  const SharedSubscriptionArticle({
    required this.articleId,
    required this.publicationId,
    required this.currentArticleRevisionId,
    required this.title,
    this.sectionId,
    this.summary,
    this.author,
    this.publishedAt,
    this.lifecycle,
  });

  factory SharedSubscriptionArticle.fromJson(Map<String, Object?> json) {
    return SharedSubscriptionArticle(
      articleId: requiredString(json, 'articleId'),
      publicationId: requiredString(json, 'publicationId'),
      sectionId: optionalString(json, 'sectionId'),
      currentArticleRevisionId: requiredString(
        json,
        'currentArticleRevisionId',
      ),
      title: requiredString(json, 'title'),
      summary: optionalString(json, 'summary'),
      author: optionalString(json, 'author'),
      publishedAt: _optionalDateTime(json, 'publishedAt'),
      lifecycle: optionalString(json, 'lifecycle'),
    );
  }

  final String articleId;
  final String publicationId;
  final String? sectionId;
  final String currentArticleRevisionId;
  final String title;
  final String? summary;
  final String? author;
  final DateTime? publishedAt;
  final String? lifecycle;
}

final class SharedSubscriptionArticleRevision {
  const SharedSubscriptionArticleRevision({
    required this.articleId,
    required this.articleRevisionId,
    required this.title,
    required this.contentMarkdown,
    required this.assetRefs,
    this.publishedAt,
    this.contentSha256,
    this.etag,
  });

  factory SharedSubscriptionArticleRevision.fromJson(
    Map<String, Object?> json,
  ) {
    final contentSha256 = optionalString(json, 'contentSha256');
    final etag = optionalString(json, 'etag');
    if (contentSha256 == null && etag == null) {
      throw const FormatException(
        'Article revision requires contentSha256 or etag',
      );
    }
    final rawAssetRefs = json['assetRefs'];
    if (rawAssetRefs != null && rawAssetRefs is! List) {
      throw const FormatException('Article revision assetRefs must be a list');
    }
    return SharedSubscriptionArticleRevision(
      articleId: requiredString(json, 'articleId'),
      articleRevisionId: requiredString(json, 'articleRevisionId'),
      title: requiredString(json, 'title'),
      contentMarkdown: requiredString(
        json,
        'contentMarkdown',
        allowEmpty: true,
      ),
      publishedAt: json['publishedAt'] == null
          ? null
          : requiredDateTime(json, 'publishedAt'),
      contentSha256: contentSha256,
      etag: etag,
      assetRefs: List<SharedSubscriptionArticleAssetRef>.unmodifiable(
        (rawAssetRefs as List? ?? const <Object?>[]).map((value) {
          if (value is! Map) {
            throw const FormatException('Article revision assetRef is invalid');
          }
          return SharedSubscriptionArticleAssetRef.fromJson(
            value.map((key, item) => MapEntry(key.toString(), item)),
          );
        }),
      ),
    );
  }

  final String articleId;
  final String articleRevisionId;
  final String title;
  final String contentMarkdown;
  final DateTime? publishedAt;
  final String? contentSha256;
  final String? etag;
  final List<SharedSubscriptionArticleAssetRef> assetRefs;
}

final class SharedSubscriptionArticleAssetRef {
  const SharedSubscriptionArticleAssetRef({
    required this.fileKey,
    required this.logicalPath,
  });

  factory SharedSubscriptionArticleAssetRef.fromJson(
    Map<String, Object?> json,
  ) {
    return SharedSubscriptionArticleAssetRef(
      fileKey: requiredString(json, 'fileKey'),
      logicalPath: requiredString(json, 'logicalPath'),
    );
  }

  final String fileKey;
  final String logicalPath;
}

final class SharedSubscriptionLibraryPublication {
  const SharedSubscriptionLibraryPublication({
    required this.publication,
    required this.followedAt,
    required this.availability,
    this.unavailableReason,
  });

  factory SharedSubscriptionLibraryPublication.fromJson(
    Map<String, Object?> json,
  ) {
    final availability = requiredString(json, 'availability');
    final unavailableReason = optionalString(json, 'unavailableReason');
    if (availability == 'available') {
      if (unavailableReason != null) {
        throw const FormatException(
          'available library item cannot have unavailableReason',
        );
      }
    } else if (availability == 'unavailable') {
      if (!const <String>{
        'withdrawn',
        'held',
        'retired_source',
      }.contains(unavailableReason)) {
        throw const FormatException(
          'unavailable library item requires a supported reason',
        );
      }
    } else {
      throw FormatException('unsupported library availability: $availability');
    }
    return SharedSubscriptionLibraryPublication(
      publication: SharedSubscriptionPublication.fromJson(
        requiredObject(json, 'publication'),
      ),
      followedAt: requiredDateTime(json, 'followedAt'),
      availability: availability,
      unavailableReason: unavailableReason,
    );
  }

  final SharedSubscriptionPublication publication;
  final DateTime followedAt;
  final String availability;
  final String? unavailableReason;
}

final class SharedSubscriptionFollowResult {
  const SharedSubscriptionFollowResult({
    required this.workspaceId,
    required this.publicationId,
    required this.lifecycle,
    this.followedAt,
    this.unfollowedAt,
  });

  factory SharedSubscriptionFollowResult.fromJson(Map<String, Object?> json) {
    final lifecycle = requiredString(json, 'lifecycle');
    final followedAt = _optionalDateTime(json, 'followedAt');
    final unfollowedAt = _optionalDateTime(json, 'unfollowedAt');
    if (lifecycle == 'following') {
      if (followedAt == null || unfollowedAt != null) {
        throw const FormatException(
          'following result requires only followedAt',
        );
      }
    } else if (lifecycle == 'unfollowed') {
      if (unfollowedAt == null || followedAt != null) {
        throw const FormatException(
          'unfollowed result requires only unfollowedAt',
        );
      }
    } else {
      throw FormatException('unsupported follow lifecycle: $lifecycle');
    }
    return SharedSubscriptionFollowResult(
      workspaceId: requiredString(json, 'workspaceId'),
      publicationId: requiredString(json, 'publicationId'),
      lifecycle: lifecycle,
      followedAt: followedAt,
      unfollowedAt: unfollowedAt,
    );
  }

  final String workspaceId;
  final String publicationId;
  final String lifecycle;
  final DateTime? followedAt;
  final DateTime? unfollowedAt;
}

final class SharedSubscriptionSaveReceipt {
  const SharedSubscriptionSaveReceipt({
    required this.noteId,
    required this.noteRevisionId,
    required this.rawPartRevisionId,
    required this.outlinePartRevisionId,
    required this.germinationPartRevisionId,
    required this.articleId,
    required this.articleRevisionId,
    required this.created,
    required this.etag,
    required this.contentCursor,
  });

  factory SharedSubscriptionSaveReceipt.fromJson(Map<String, Object?> json) {
    final lifecycle = requiredString(json, 'lifecycle');
    if (lifecycle != 'live') {
      throw FormatException('unsupported saved-note lifecycle: $lifecycle');
    }
    return SharedSubscriptionSaveReceipt(
      noteId: requiredString(json, 'noteId'),
      noteRevisionId: requiredString(json, 'noteRevisionId'),
      rawPartRevisionId: requiredString(json, 'rawPartRevisionId'),
      outlinePartRevisionId: requiredString(json, 'outlinePartRevisionId'),
      germinationPartRevisionId: requiredString(
        json,
        'germinationPartRevisionId',
      ),
      articleId: requiredString(json, 'articleId'),
      articleRevisionId: requiredString(json, 'articleRevisionId'),
      created: requiredBool(json, 'created'),
      etag: requiredString(json, 'etag'),
      contentCursor: _requiredContentCursor(json, 'contentCursor'),
    );
  }

  final String noteId;
  final String noteRevisionId;
  final String rawPartRevisionId;
  final String outlinePartRevisionId;
  final String germinationPartRevisionId;
  final String articleId;
  final String articleRevisionId;
  final bool created;
  final String etag;
  final String contentCursor;
}

sealed class SharedAgentInputContent {
  const SharedAgentInputContent();

  String get identity;
  Map<String, Object?> toJson();
}

final class SharedAgentTextContent extends SharedAgentInputContent {
  SharedAgentTextContent({required String text}) : text = text {
    if (this.text.trim().isEmpty) {
      throw ArgumentError.value(text, 'text', 'Text must not be empty');
    }
  }

  final String text;

  @override
  String get identity => 'text:$text';

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'type': 'text',
    'text': text,
  };
}

final class SharedAgentResourceContent extends SharedAgentInputContent {
  SharedAgentResourceContent({
    required this.type,
    required this.resourceId,
    this.usage = 'reference',
  }) {
    if (type != 'image' && type != 'file') {
      throw ArgumentError.value(type, 'type', 'Expected image or file');
    }
    _validateChatIdentifier(resourceId, 'resourceId');
    if (usage != 'primary_input' && usage != 'reference') {
      throw ArgumentError.value(usage, 'usage', 'Unsupported resource usage');
    }
  }

  final String type;
  final String resourceId;
  final String usage;

  @override
  String get identity => 'resource:$type:$resourceId:$usage';

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'type': type,
    'source': <String, Object?>{'kind': 'resource', 'resourceId': resourceId},
    'usage': usage,
  };
}

final class SharedAgentWorkspaceDocumentContent
    extends SharedAgentInputContent {
  SharedAgentWorkspaceDocumentContent({
    required this.ownerKind,
    required this.ownerId,
    required this.part,
    required this.partRevisionId,
  }) {
    if (ownerKind != 'hnote') {
      throw ArgumentError.value(ownerKind, 'ownerKind', 'Expected hnote');
    }
    _validateChatIdentifier(ownerId, 'ownerId');
    _validateChatIdentifier(partRevisionId, 'partRevisionId');
    if (part != 'raw' && part != 'outline' && part != 'germination') {
      throw ArgumentError.value(part, 'part', 'Unsupported HNote part');
    }
  }

  final String ownerKind;
  final String ownerId;
  final String part;
  final String partRevisionId;

  @override
  String get identity =>
      'workspace_document:$ownerKind:$ownerId:$part:$partRevisionId';

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'type': 'workspace_document',
    'source': <String, Object?>{
      'kind': 'workspace_document',
      'ownerRef': <String, Object?>{'kind': ownerKind, 'id': ownerId},
      'part': part,
      'partRevisionId': partRevisionId,
    },
    'usage': 'reference',
  };
}

final class SharedAgentInput {
  SharedAgentInput({required Iterable<SharedAgentInputContent> content})
    : content = _normalizeAgentInput(content);

  final List<SharedAgentInputContent> content;

  Map<String, Object?> toJson() => <String, Object?>{
    'content': content.map((part) => part.toJson()).toList(growable: false),
  };
}

final class SharedChatThreadCreateRequest {
  const SharedChatThreadCreateRequest({
    this.workspaceId,
    this.scene,
    this.creativePositioningId,
  });

  final String? workspaceId;
  final String? scene;
  final String? creativePositioningId;

  Map<String, Object?> toJson() => <String, Object?>{
    if (workspaceId != null) 'workspaceId': workspaceId,
    if (scene != null) 'scene': scene,
    if (creativePositioningId != null)
      'creativePositioningId': creativePositioningId,
  };
}

final class SharedChatTextMessageRequest {
  SharedChatTextMessageRequest({
    required this.agentProfileId,
    String? modelProfileId,
    required Iterable<SharedAgentInputContent> content,
  }) : modelProfileId = modelProfileId?.trim(),
       content = List<SharedAgentInputContent>.unmodifiable(content) {
    if (agentProfileId.trim().isEmpty) {
      throw ArgumentError.value(
        agentProfileId,
        'agentProfileId',
        'Agent Profile must not be empty',
      );
    }
    if (this.modelProfileId case final modelProfileId?) {
      _validateChatIdentifier(modelProfileId, 'modelProfileId');
    }
    if (this.content.isEmpty || this.content.length > 256) {
      throw ArgumentError.value(
        content,
        'content',
        'Content must contain between 1 and 256 parts',
      );
    }
  }

  final String agentProfileId;
  final String? modelProfileId;
  final List<SharedAgentInputContent> content;

  Map<String, Object?> toJson() => <String, Object?>{
    'agentProfileId': agentProfileId,
    if (modelProfileId != null) 'modelProfileId': modelProfileId,
    'input': <String, Object?>{
      'content': content.map((part) => part.toJson()).toList(growable: false),
    },
  };
}

final class SharedChatResourceRef {
  const SharedChatResourceRef({required this.resourceId, required this.usage});

  Map<String, Object?> toJson() => <String, Object?>{
    'resourceId': resourceId,
    'usage': usage,
  };

  final String resourceId;
  final String usage;
}

final class SharedChatContext {
  const SharedChatContext({
    this.expectedMetaWorkspaceKey,
    this.attachments = const <SharedChatResourceRef>[],
  });

  Map<String, Object?> toRequestJson() {
    final seenResources = <String>{};
    for (final attachment in attachments) {
      if (attachment.usage != 'primary_input' &&
          attachment.usage != 'reference') {
        throw FormatException(
          'unsupported chat attachment usage: ${attachment.usage}',
        );
      }
      if (!seenResources.add(attachment.resourceId)) {
        throw FormatException(
          'duplicate chat resourceId: ${attachment.resourceId}',
        );
      }
    }
    return <String, Object?>{
      if (expectedMetaWorkspaceKey != null)
        'expectedMetaWorkspaceKey': expectedMetaWorkspaceKey,
      if (attachments.isNotEmpty)
        'attachments': attachments
            .map((attachment) => attachment.toJson())
            .toList(growable: false),
    };
  }

  final String? expectedMetaWorkspaceKey;
  final List<SharedChatResourceRef> attachments;
}

final class SharedChatContextReference {
  SharedChatContextReference({
    required String type,
    required String id,
    String? revision,
  }) : type = type,
       id = id,
       revision = revision {
    const allowedTypes = <String>{
      'memory_note',
      'feed_item',
      'material',
      'asset',
      'recording',
    };
    if (!allowedTypes.contains(type) ||
        !_chatIdentifier.hasMatch(id) ||
        (revision != null && !_chatIdentifier.hasMatch(revision))) {
      throw ArgumentError('Invalid chat context reference');
    }
  }

  final String type;
  final String id;
  final String? revision;

  Map<String, Object?> toJson() => <String, Object?>{
    'type': type,
    'id': id,
    if (revision != null) 'revision': revision,
  };
}

final class SharedChatContextEnvelope {
  SharedChatContextEnvelope({
    this.purpose = 'general',
    Iterable<SharedChatContextReference> references =
        const <SharedChatContextReference>[],
    this.includeAccountProfile = false,
  }) : references = _deduplicateChatReferences(references) {
    const allowedPurposes = <String>{
      'general',
      'deep_positioning',
      'persona',
      'lead',
      'visual_design',
      'video_analysis',
      'social_positioning',
      'masterpiece',
    };
    if (!allowedPurposes.contains(purpose)) {
      throw ArgumentError.value(purpose, 'purpose', 'Unsupported purpose');
    }
  }

  static const schemaVersion = 'huahuo.chat-context.v1';

  final String purpose;
  final List<SharedChatContextReference> references;
  final bool includeAccountProfile;

  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': schemaVersion,
    'purpose': purpose,
    'references': references
        .map((reference) => reference.toJson())
        .toList(growable: false),
    'includeAccountProfile': includeAccountProfile,
  };
}

final class SharedChatThread {
  const SharedChatThread({
    required this.threadId,
    required this.title,
    this.activeWorkspaceId,
    this.updatedAt,
  });

  factory SharedChatThread.fromJson(Map<String, Object?> json) {
    return SharedChatThread(
      threadId: requiredString(json, 'threadId'),
      title: optionalString(json, 'title') ?? '未命名会话',
      activeWorkspaceId: optionalString(json, 'activeWorkspaceId'),
      updatedAt: _optionalDateTime(json, 'updatedAt'),
    );
  }

  final String threadId;
  final String title;
  final String? activeWorkspaceId;
  final DateTime? updatedAt;
}

final class SharedChatMessage {
  const SharedChatMessage({
    required this.messageId,
    required this.threadId,
    required this.role,
    required this.text,
  });

  factory SharedChatMessage.fromJson(
    Map<String, Object?> json, {
    String? fallbackThreadId,
  }) {
    final messageId =
        optionalString(json, 'messageId') ?? optionalString(json, 'id');
    final threadId = optionalString(json, 'threadId') ?? fallbackThreadId;
    final role = requiredString(json, 'role');
    final text =
        optionalString(json, 'textPreview') ??
        optionalString(json, 'transcriptText') ??
        optionalString(json, 'content');
    if (messageId == null || threadId == null || text == null) {
      throw const FormatException('Invalid chat message');
    }
    if (role != 'user' && role != 'assistant' && role != 'system') {
      throw FormatException('Unsupported chat role: $role');
    }
    return SharedChatMessage(
      messageId: messageId,
      threadId: threadId,
      role: role,
      text: text,
    );
  }

  final String messageId;
  final String threadId;
  final String role;
  final String text;
}

final class SharedChatThreadPage {
  const SharedChatThreadPage({required this.items, this.nextCursor});

  factory SharedChatThreadPage.fromJson(Map<String, Object?> json) {
    final rawItems = json['items'] ?? json['threads'];
    if (rawItems is! List) {
      throw const FormatException('chat thread items must be a list');
    }
    return SharedChatThreadPage(
      items: rawItems
          .map((raw) {
            if (raw is! Map) throw const FormatException('Invalid chat thread');
            return SharedChatThread.fromJson(
              raw.map((key, value) => MapEntry(key.toString(), value)),
            );
          })
          .toList(growable: false),
      nextCursor: optionalString(json, 'nextCursor'),
    );
  }

  final List<SharedChatThread> items;
  final String? nextCursor;
}

final class SharedChatThreadDetail {
  const SharedChatThreadDetail({required this.thread, required this.messages});

  factory SharedChatThreadDetail.fromJson(Map<String, Object?> json) {
    final thread = SharedChatThread.fromJson(requiredObject(json, 'thread'));
    return SharedChatThreadDetail(
      thread: thread,
      messages: requiredObjectList(json, 'messages')
          .map(
            (message) => SharedChatMessage.fromJson(
              message,
              fallbackThreadId: thread.threadId,
            ),
          )
          .toList(growable: false),
    );
  }

  final SharedChatThread thread;
  final List<SharedChatMessage> messages;
}

final class SharedChatMutation {
  const SharedChatMutation({
    required this.userMessage,
    this.assistantMessage,
    this.taskId,
  });

  factory SharedChatMutation.fromJson(
    Map<String, Object?> json, {
    required String fallbackThreadId,
  }) {
    final rawUser = json['userMessage'] ?? json['message'];
    if (rawUser is! Map) {
      throw const FormatException('Chat mutation userMessage is required');
    }
    final user = SharedChatMessage.fromJson(
      rawUser.map((key, value) => MapEntry(key.toString(), value)),
      fallbackThreadId: fallbackThreadId,
    );
    final rawAssistant = json['assistantMessage'];
    if (rawAssistant != null && rawAssistant is! Map) {
      throw const FormatException('Invalid assistantMessage');
    }
    final assistantJson = rawAssistant is Map
        ? rawAssistant.map((key, value) => MapEntry(key.toString(), value))
        : null;
    return SharedChatMutation(
      userMessage: user,
      assistantMessage: assistantJson == null
          ? null
          : SharedChatMessage.fromJson(
              assistantJson,
              fallbackThreadId: fallbackThreadId,
            ),
      taskId: optionalString(json, 'taskId'),
    );
  }

  final SharedChatMessage userMessage;
  final SharedChatMessage? assistantMessage;
  final String? taskId;
}

final class SharedManagedResourceRef {
  SharedManagedResourceRef({
    required String resourceId,
    required String role,
    this.ordinal,
    String? caption,
  }) : resourceId = resourceId.trim(),
       role = role.trim(),
       caption = caption?.trim() {
    _validateOpaqueInput(this.resourceId, 'resourceId');
    _validateOpaqueInput(this.role, 'role');
    if (ordinal != null && ordinal! < 0) {
      throw ArgumentError.value(ordinal, 'ordinal', 'Must not be negative');
    }
    if (this.caption != null && this.caption!.isEmpty) {
      throw ArgumentError.value(caption, 'caption', 'Must not be empty');
    }
  }

  factory SharedManagedResourceRef.fromJson(Map<String, Object?> json) {
    _requireOnlyContractFields(json, const <String>{
      'resourceId',
      'role',
      'ordinal',
      'caption',
    }, 'ManagedResourceRef');
    return SharedManagedResourceRef(
      resourceId: requiredString(json, 'resourceId'),
      role: requiredString(json, 'role'),
      ordinal: optionalNonNegativeInt(json, 'ordinal'),
      caption: optionalString(json, 'caption'),
    );
  }

  final String resourceId;
  final String role;
  final int? ordinal;
  final String? caption;

  Map<String, Object?> toJson() => <String, Object?>{
    'resourceId': resourceId,
    'role': role,
    if (ordinal != null) 'ordinal': ordinal,
    if (caption != null) 'caption': caption,
  };
}

sealed class SharedManagedLineageRef {
  const SharedManagedLineageRef(this.kind);

  factory SharedManagedLineageRef.fromJson(Map<String, Object?> json) {
    return switch (requiredString(json, 'kind')) {
      'note_part' => SharedManagedNotePartLineageRef.fromJson(json),
      'work_part' => SharedManagedWorkPartLineageRef.fromJson(json),
      'run_output' => SharedManagedRunOutputLineageRef.fromJson(json),
      final kind => throw FormatException(
        'unsupported ManagedLineageRef kind: $kind',
      ),
    };
  }

  final String kind;

  Map<String, Object?> toJson();
}

final class SharedManagedNotePartLineageRef extends SharedManagedLineageRef {
  SharedManagedNotePartLineageRef({
    required String noteId,
    required String part,
    required String partRevisionId,
  }) : noteId = noteId.trim(),
       part = part.trim(),
       partRevisionId = partRevisionId.trim(),
       super('note_part') {
    _validateOpaqueInput(this.noteId, 'noteId');
    _validateNotePart(this.part, 'part');
    _validateOpaqueInput(this.partRevisionId, 'partRevisionId');
  }

  factory SharedManagedNotePartLineageRef.fromJson(Map<String, Object?> json) {
    _requireOnlyContractFields(json, const <String>{
      'kind',
      'noteId',
      'part',
      'partRevisionId',
    }, 'ManagedLineageRef.note_part');
    return SharedManagedNotePartLineageRef(
      noteId: requiredString(json, 'noteId'),
      part: _requiredBookPart(json, 'part'),
      partRevisionId: requiredString(json, 'partRevisionId'),
    );
  }

  final String noteId;
  final String part;
  final String partRevisionId;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'kind': kind,
    'noteId': noteId,
    'part': part,
    'partRevisionId': partRevisionId,
  };
}

final class SharedManagedWorkPartLineageRef extends SharedManagedLineageRef {
  SharedManagedWorkPartLineageRef({
    required String workId,
    required String part,
    required String partRevisionId,
  }) : workId = workId.trim(),
       part = part.trim(),
       partRevisionId = partRevisionId.trim(),
       super('work_part') {
    _validateOpaqueInput(this.workId, 'workId');
    _validateNotePart(this.part, 'part');
    _validateOpaqueInput(this.partRevisionId, 'partRevisionId');
  }

  factory SharedManagedWorkPartLineageRef.fromJson(Map<String, Object?> json) {
    _requireOnlyContractFields(json, const <String>{
      'kind',
      'workId',
      'part',
      'partRevisionId',
    }, 'ManagedLineageRef.work_part');
    return SharedManagedWorkPartLineageRef(
      workId: requiredString(json, 'workId'),
      part: _requiredBookPart(json, 'part'),
      partRevisionId: requiredString(json, 'partRevisionId'),
    );
  }

  final String workId;
  final String part;
  final String partRevisionId;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'kind': kind,
    'workId': workId,
    'part': part,
    'partRevisionId': partRevisionId,
  };
}

final class SharedManagedRunOutputLineageRef extends SharedManagedLineageRef {
  SharedManagedRunOutputLineageRef({
    required String runId,
    required String outputResourceId,
  }) : runId = runId.trim(),
       outputResourceId = outputResourceId.trim(),
       super('run_output') {
    _validateOpaqueInput(this.runId, 'runId');
    _validateOpaqueInput(this.outputResourceId, 'outputResourceId');
  }

  factory SharedManagedRunOutputLineageRef.fromJson(Map<String, Object?> json) {
    _requireOnlyContractFields(json, const <String>{
      'kind',
      'runId',
      'outputResourceId',
    }, 'ManagedLineageRef.run_output');
    return SharedManagedRunOutputLineageRef(
      runId: requiredString(json, 'runId'),
      outputResourceId: requiredString(json, 'outputResourceId'),
    );
  }

  final String runId;
  final String outputResourceId;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'kind': kind,
    'runId': runId,
    'outputResourceId': outputResourceId,
  };
}

sealed class SharedWorkLineageRef {
  const SharedWorkLineageRef({required this.ordinal, required this.kind});

  factory SharedWorkLineageRef.fromJson(Map<String, Object?> json) {
    return switch (requiredString(json, 'kind')) {
      'note_part_revision' => SharedWorkNotePartLineageRef.fromJson(json),
      'work_part_revision' => SharedWorkPartRevisionLineageRef.fromJson(json),
      'run_output_resource' => SharedWorkRunOutputLineageRef.fromJson(json),
      final kind => throw FormatException(
        'unsupported WorkLineageRef kind: $kind',
      ),
    };
  }

  final int ordinal;
  final String kind;

  Map<String, Object?> toJson();
}

final class SharedWorkNotePartLineageRef extends SharedWorkLineageRef {
  SharedWorkNotePartLineageRef({
    required int ordinal,
    required String noteId,
    required String part,
    required String partRevisionId,
  }) : noteId = noteId.trim(),
       part = part.trim(),
       partRevisionId = partRevisionId.trim(),
       super(ordinal: ordinal, kind: 'note_part_revision') {
    _validateOrdinal(ordinal, 'ordinal');
    _validateOpaqueInput(this.noteId, 'noteId');
    _validateNotePart(this.part, 'part');
    _validateOpaqueInput(this.partRevisionId, 'partRevisionId');
  }

  factory SharedWorkNotePartLineageRef.fromJson(Map<String, Object?> json) {
    _requireOnlyContractFields(json, const <String>{
      'ordinal',
      'kind',
      'noteId',
      'part',
      'partRevisionId',
    }, 'WorkLineageRef.note_part_revision');
    return SharedWorkNotePartLineageRef(
      ordinal: requiredNonNegativeInt(json, 'ordinal'),
      noteId: requiredString(json, 'noteId'),
      part: _requiredBookPart(json, 'part'),
      partRevisionId: requiredString(json, 'partRevisionId'),
    );
  }

  final String noteId;
  final String part;
  final String partRevisionId;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'ordinal': ordinal,
    'kind': kind,
    'noteId': noteId,
    'part': part,
    'partRevisionId': partRevisionId,
  };
}

final class SharedWorkPartRevisionLineageRef extends SharedWorkLineageRef {
  SharedWorkPartRevisionLineageRef({
    required int ordinal,
    required String sourceWorkId,
    required String part,
    required String partRevisionId,
  }) : sourceWorkId = sourceWorkId.trim(),
       part = part.trim(),
       partRevisionId = partRevisionId.trim(),
       super(ordinal: ordinal, kind: 'work_part_revision') {
    _validateOrdinal(ordinal, 'ordinal');
    _validateOpaqueInput(this.sourceWorkId, 'sourceWorkId');
    _validateNotePart(this.part, 'part');
    _validateOpaqueInput(this.partRevisionId, 'partRevisionId');
  }

  factory SharedWorkPartRevisionLineageRef.fromJson(Map<String, Object?> json) {
    _requireOnlyContractFields(json, const <String>{
      'ordinal',
      'kind',
      'sourceWorkId',
      'part',
      'partRevisionId',
    }, 'WorkLineageRef.work_part_revision');
    return SharedWorkPartRevisionLineageRef(
      ordinal: requiredNonNegativeInt(json, 'ordinal'),
      sourceWorkId: requiredString(json, 'sourceWorkId'),
      part: _requiredBookPart(json, 'part'),
      partRevisionId: requiredString(json, 'partRevisionId'),
    );
  }

  final String sourceWorkId;
  final String part;
  final String partRevisionId;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'ordinal': ordinal,
    'kind': kind,
    'sourceWorkId': sourceWorkId,
    'part': part,
    'partRevisionId': partRevisionId,
  };
}

final class SharedWorkRunOutputLineageRef extends SharedWorkLineageRef {
  SharedWorkRunOutputLineageRef({
    required int ordinal,
    required String runId,
    required String outputResourceId,
  }) : runId = runId.trim(),
       outputResourceId = outputResourceId.trim(),
       super(ordinal: ordinal, kind: 'run_output_resource') {
    _validateOrdinal(ordinal, 'ordinal');
    _validateOpaqueInput(this.runId, 'runId');
    _validateOpaqueInput(this.outputResourceId, 'outputResourceId');
  }

  factory SharedWorkRunOutputLineageRef.fromJson(Map<String, Object?> json) {
    _requireOnlyContractFields(json, const <String>{
      'ordinal',
      'kind',
      'runId',
      'outputResourceId',
    }, 'WorkLineageRef.run_output_resource');
    return SharedWorkRunOutputLineageRef(
      ordinal: requiredNonNegativeInt(json, 'ordinal'),
      runId: requiredString(json, 'runId'),
      outputResourceId: requiredString(json, 'outputResourceId'),
    );
  }

  final String runId;
  final String outputResourceId;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'ordinal': ordinal,
    'kind': kind,
    'runId': runId,
    'outputResourceId': outputResourceId,
  };
}

final class SharedManagedPartHead {
  const SharedManagedPartHead({
    required this.part,
    required this.status,
    this.currentRevisionId,
    this.revision,
  });

  factory SharedManagedPartHead.fromJson(Map<String, Object?> json) {
    _requireOnlyContractFields(json, const <String>{
      'part',
      'currentRevisionId',
      'revision',
      'status',
    }, 'ManagedHNotePartHead');
    final revisionId = optionalString(json, 'currentRevisionId');
    final revision = optionalNonNegativeInt(json, 'revision');
    if ((revisionId == null) != (revision == null)) {
      throw const FormatException(
        'currentRevisionId and revision must be present together',
      );
    }
    final status = requiredString(json, 'status');
    if (!_managedPartStatuses.contains(status)) {
      throw FormatException('unsupported managed part status: $status');
    }
    return SharedManagedPartHead(
      part: _requiredBookPart(json, 'part'),
      currentRevisionId: revisionId,
      revision: revision,
      status: status,
    );
  }

  final String part;
  final String? currentRevisionId;
  final int? revision;
  final String status;
}

final class SharedBookSectionSnapshot {
  const SharedBookSectionSnapshot({
    required this.sectionKey,
    required this.title,
    required this.group,
    required this.ordinal,
    required this.metadataVersion,
    required this.currentPartRevisionIds,
  });

  factory SharedBookSectionSnapshot.fromJson(Map<String, Object?> json) {
    _requireOnlyContractFields(json, const <String>{
      'sectionKey',
      'title',
      'group',
      'ordinal',
      'metadataVersion',
      'currentPartRevisionIds',
    }, 'BookSectionSnapshot');
    return SharedBookSectionSnapshot(
      sectionKey: _requiredBookSectionKey(json, 'sectionKey'),
      title: requiredString(json, 'title'),
      group: _requiredBookSectionGroup(json, 'group'),
      ordinal: requiredNonNegativeInt(json, 'ordinal'),
      metadataVersion: _requiredPositiveInt(json, 'metadataVersion'),
      currentPartRevisionIds: _parseBookPartRevisionMap(
        requiredObject(json, 'currentPartRevisionIds'),
      ),
    );
  }

  final String sectionKey;
  final String title;
  final String group;
  final int ordinal;
  final int metadataVersion;
  final Map<String, String> currentPartRevisionIds;
}

final class SharedBookRevision {
  const SharedBookRevision({
    required this.bookRevisionId,
    required this.revision,
    required this.title,
    required this.language,
    required this.status,
    required this.sectionOrderVersion,
    required this.sections,
    required this.createdAt,
    this.subtitle,
  });

  factory SharedBookRevision.fromJson(Map<String, Object?> json) {
    _requireOnlyContractFields(json, const <String>{
      'bookRevisionId',
      'revision',
      'title',
      'subtitle',
      'language',
      'status',
      'sectionOrderVersion',
      'sections',
      'createdAt',
    }, 'BookRevisionView');
    final status = requiredString(json, 'status');
    if (!_bookStatuses.contains(status)) {
      throw FormatException('unsupported Book status: $status');
    }
    final sections = requiredObjectList(
      json,
      'sections',
    ).map(SharedBookSectionSnapshot.fromJson).toList(growable: false);
    _validateBookSectionOrder(sections);
    return SharedBookRevision(
      bookRevisionId: requiredString(json, 'bookRevisionId'),
      revision: _requiredPositiveInt(json, 'revision'),
      title: requiredString(json, 'title'),
      subtitle: optionalString(json, 'subtitle'),
      language: requiredString(json, 'language'),
      status: status,
      sectionOrderVersion: _requiredPositiveInt(json, 'sectionOrderVersion'),
      sections: List<SharedBookSectionSnapshot>.unmodifiable(sections),
      createdAt: requiredDateTime(json, 'createdAt'),
    );
  }

  final String bookRevisionId;
  final int revision;
  final String title;
  final String? subtitle;
  final String language;
  final String status;
  final int sectionOrderVersion;
  final List<SharedBookSectionSnapshot> sections;
  final DateTime createdAt;
}

final class SharedBookSection {
  const SharedBookSection({
    required this.sectionKey,
    required this.title,
    required this.group,
    required this.ordinal,
    required this.metadataVersion,
    required this.currentPartRevisionIds,
    required this.parts,
    required this.sourceRefs,
    required this.resourceRefs,
    required this.etag,
  });

  factory SharedBookSection.fromJson(Map<String, Object?> json) {
    _requireOnlyContractFields(json, const <String>{
      'sectionKey',
      'title',
      'group',
      'ordinal',
      'metadataVersion',
      'currentPartRevisionIds',
      'parts',
      'sourceRefs',
      'resourceRefs',
      'etag',
    }, 'BookSectionView');
    final parts = requiredObjectList(
      json,
      'parts',
    ).map(SharedManagedPartHead.fromJson).toList(growable: false);
    _validateUniqueParts(parts);
    return SharedBookSection(
      sectionKey: _requiredBookSectionKey(json, 'sectionKey'),
      title: requiredString(json, 'title'),
      group: _requiredBookSectionGroup(json, 'group'),
      ordinal: requiredNonNegativeInt(json, 'ordinal'),
      metadataVersion: _requiredPositiveInt(json, 'metadataVersion'),
      currentPartRevisionIds: _parseBookPartRevisionMap(
        requiredObject(json, 'currentPartRevisionIds'),
      ),
      parts: List<SharedManagedPartHead>.unmodifiable(parts),
      sourceRefs: requiredObjectList(
        json,
        'sourceRefs',
      ).map(SharedManagedLineageRef.fromJson).toList(growable: false),
      resourceRefs: requiredObjectList(
        json,
        'resourceRefs',
      ).map(SharedManagedResourceRef.fromJson).toList(growable: false),
      etag: requiredString(json, 'etag'),
    );
  }

  final String sectionKey;
  final String title;
  final String group;
  final int ordinal;
  final int metadataVersion;
  final Map<String, String> currentPartRevisionIds;
  final List<SharedManagedPartHead> parts;
  final List<SharedManagedLineageRef> sourceRefs;
  final List<SharedManagedResourceRef> resourceRefs;
  final String etag;
}

final class SharedBook {
  const SharedBook({
    required this.bookId,
    required this.currentBookRevisionId,
    required this.current,
    required this.sections,
    required this.etag,
  });

  factory SharedBook.fromJson(Map<String, Object?> json) {
    _requireOnlyContractFields(json, const <String>{
      'bookId',
      'currentBookRevisionId',
      'current',
      'sections',
      'etag',
    }, 'BookView');
    final current = SharedBookRevision.fromJson(
      requiredObject(json, 'current'),
    );
    final currentBookRevisionId = requiredString(json, 'currentBookRevisionId');
    if (current.bookRevisionId != currentBookRevisionId) {
      throw const FormatException(
        'currentBookRevisionId must match current.bookRevisionId',
      );
    }
    final sections = requiredObjectList(
      json,
      'sections',
    ).map(SharedBookSection.fromJson).toList(growable: false);
    _validateBookSectionOrder(sections);
    if (!_sameBookSnapshot(current.sections, sections)) {
      throw const FormatException(
        'current Book revision must match current section snapshots',
      );
    }
    return SharedBook(
      bookId: requiredString(json, 'bookId'),
      currentBookRevisionId: currentBookRevisionId,
      current: current,
      sections: List<SharedBookSection>.unmodifiable(sections),
      etag: requiredString(json, 'etag'),
    );
  }

  final String bookId;
  final String currentBookRevisionId;
  final SharedBookRevision current;
  final List<SharedBookSection> sections;
  final String etag;
}

final class SharedBookRevisionPage {
  const SharedBookRevisionPage({required this.items, this.nextCursor});

  factory SharedBookRevisionPage.fromJson(Map<String, Object?> json) {
    _requireOnlyContractFields(json, const <String>{
      'items',
      'nextCursor',
    }, 'BookRevisionListResponse');
    return SharedBookRevisionPage(
      items: requiredObjectList(
        json,
        'items',
      ).map(SharedBookRevision.fromJson).toList(growable: false),
      nextCursor: optionalString(json, 'nextCursor'),
    );
  }

  final List<SharedBookRevision> items;
  final String? nextCursor;
}

final class SharedManagedPartRevision {
  const SharedManagedPartRevision({
    required this.part,
    required this.partRevisionId,
    required this.revision,
    required this.contentMarkdown,
    required this.contentHash,
    required this.sizeBytes,
    required this.sourceRefs,
    required this.createdAt,
    required this.etag,
    this.managedSourceRefs = const <SharedManagedLineageRef>[],
    this.previousPartRevisionId,
  });

  factory SharedManagedPartRevision.fromJson(Map<String, Object?> json) {
    _requireOnlyContractFields(json, const <String>{
      'part',
      'partRevisionId',
      'revision',
      'previousPartRevisionId',
      'contentMarkdown',
      'contentHash',
      'sizeBytes',
      'sourceRefs',
      'createdAt',
      'etag',
    }, 'HNotePartRevisionView');
    final references = requiredObjectList(json, 'sourceRefs');
    return SharedManagedPartRevision(
      part: _requiredBookPart(json, 'part'),
      partRevisionId: requiredString(json, 'partRevisionId'),
      revision: _requiredPositiveInt(json, 'revision'),
      previousPartRevisionId: optionalString(json, 'previousPartRevisionId'),
      contentMarkdown: requiredString(
        json,
        'contentMarkdown',
        allowEmpty: true,
      ),
      contentHash: requiredString(json, 'contentHash'),
      sizeBytes: requiredNonNegativeInt(json, 'sizeBytes'),
      sourceRefs: references
          .where((reference) => !reference.containsKey('kind'))
          .map(SharedNotePartSourceRef.fromJson)
          .toList(growable: false),
      managedSourceRefs: references
          .where((reference) => reference.containsKey('kind'))
          .map(SharedManagedLineageRef.fromJson)
          .toList(growable: false),
      createdAt: requiredDateTime(json, 'createdAt'),
      etag: requiredString(json, 'etag'),
    );
  }

  final String part;
  final String partRevisionId;
  final int revision;
  final String? previousPartRevisionId;
  final String contentMarkdown;
  final String contentHash;
  final int sizeBytes;
  final List<SharedNotePartSourceRef> sourceRefs;
  final List<SharedManagedLineageRef> managedSourceRefs;
  final DateTime createdAt;
  final String etag;
}

final class SharedManagedPartRevisionPage {
  const SharedManagedPartRevisionPage({required this.items, this.nextCursor});

  factory SharedManagedPartRevisionPage.fromJson(Map<String, Object?> json) {
    _requireOnlyContractFields(json, const <String>{
      'items',
      'nextCursor',
    }, 'HNotePartRevisionListResponse');
    return SharedManagedPartRevisionPage(
      items: requiredObjectList(
        json,
        'items',
      ).map(SharedManagedPartRevision.fromJson).toList(growable: false),
      nextCursor: optionalString(json, 'nextCursor'),
    );
  }

  final List<SharedManagedPartRevision> items;
  final String? nextCursor;
}

sealed class SharedBookImport {
  const SharedBookImport({
    required this.bookImportId,
    required this.status,
    required this.resourceId,
    required this.expectedBookRevisionId,
  });

  factory SharedBookImport.fromJson(Map<String, Object?> json) {
    return switch (requiredString(json, 'status')) {
      'validating' ||
      'ready' ||
      'applying' => SharedBookImportPending.fromJson(json),
      'succeeded' => SharedBookImportSucceeded.fromJson(json),
      'failed' => SharedBookImportFailed.fromJson(json),
      final status => throw FormatException(
        'unsupported Book import status: $status',
      ),
    };
  }

  final String bookImportId;
  final String status;
  final String resourceId;
  final String expectedBookRevisionId;
}

final class SharedBookImportPending extends SharedBookImport {
  const SharedBookImportPending({
    required super.bookImportId,
    required super.status,
    required super.resourceId,
    required super.expectedBookRevisionId,
  });

  factory SharedBookImportPending.fromJson(Map<String, Object?> json) {
    _requireOnlyContractFields(json, const <String>{
      'bookImportId',
      'status',
      'resourceId',
      'expectedBookRevisionId',
    }, 'BookImportPendingView');
    final status = requiredString(json, 'status');
    if (!_bookImportPendingStatuses.contains(status)) {
      throw FormatException('unsupported pending import status: $status');
    }
    return SharedBookImportPending(
      bookImportId: requiredString(json, 'bookImportId'),
      status: status,
      resourceId: requiredString(json, 'resourceId'),
      expectedBookRevisionId: requiredString(json, 'expectedBookRevisionId'),
    );
  }
}

final class SharedBookImportSucceeded extends SharedBookImport {
  const SharedBookImportSucceeded({
    required super.bookImportId,
    required super.resourceId,
    required super.expectedBookRevisionId,
    required this.resultBookRevisionId,
    required this.resultMutationReceipt,
  }) : super(status: 'succeeded');

  factory SharedBookImportSucceeded.fromJson(Map<String, Object?> json) {
    _requireOnlyContractFields(json, const <String>{
      'bookImportId',
      'status',
      'resourceId',
      'expectedBookRevisionId',
      'resultBookRevisionId',
      'resultMutationReceipt',
    }, 'BookImportSucceededView');
    final receipt = SharedWorkspaceContentEvent.fromJson(
      requiredObject(json, 'resultMutationReceipt'),
    );
    final resultBookRevisionId = requiredString(json, 'resultBookRevisionId');
    if (requiredString(json, 'status') != 'succeeded' ||
        receipt.objectKind != 'book' ||
        receipt.revisionId != resultBookRevisionId ||
        receipt.tombstone) {
      throw const FormatException('invalid succeeded Book import receipt');
    }
    return SharedBookImportSucceeded(
      bookImportId: requiredString(json, 'bookImportId'),
      resourceId: requiredString(json, 'resourceId'),
      expectedBookRevisionId: requiredString(json, 'expectedBookRevisionId'),
      resultBookRevisionId: resultBookRevisionId,
      resultMutationReceipt: receipt,
    );
  }

  final String resultBookRevisionId;
  final SharedWorkspaceContentEvent resultMutationReceipt;
}

final class SharedBookImportFailed extends SharedBookImport {
  const SharedBookImportFailed({
    required super.bookImportId,
    required super.resourceId,
    required super.expectedBookRevisionId,
    required this.errorCode,
  }) : super(status: 'failed');

  factory SharedBookImportFailed.fromJson(Map<String, Object?> json) {
    _requireOnlyContractFields(json, const <String>{
      'bookImportId',
      'status',
      'resourceId',
      'expectedBookRevisionId',
      'errorCode',
    }, 'BookImportFailedView');
    if (requiredString(json, 'status') != 'failed') {
      throw const FormatException('BookImportFailedView status must be failed');
    }
    return SharedBookImportFailed(
      bookImportId: requiredString(json, 'bookImportId'),
      resourceId: requiredString(json, 'resourceId'),
      expectedBookRevisionId: requiredString(json, 'expectedBookRevisionId'),
      errorCode: requiredString(json, 'errorCode'),
    );
  }

  final String errorCode;
}

final class SharedWork {
  const SharedWork({
    required this.workId,
    required this.title,
    required this.lifecycle,
    required this.metadataVersion,
    required this.lineageRefs,
    required this.resourceRefs,
    required this.parts,
    required this.etag,
  });

  factory SharedWork.fromJson(Map<String, Object?> json) {
    _requireOnlyContractFields(json, const <String>{
      'workId',
      'title',
      'lifecycle',
      'metadataVersion',
      'lineageRefs',
      'resourceRefs',
      'parts',
      'etag',
    }, 'WorkView');
    final lifecycle = requiredString(json, 'lifecycle');
    if (!_workLifecycles.contains(lifecycle)) {
      throw FormatException('unsupported Work lifecycle: $lifecycle');
    }
    final lineageRefs = requiredObjectList(
      json,
      'lineageRefs',
    ).map(SharedWorkLineageRef.fromJson).toList(growable: false);
    _validateWorkLineageSequence(lineageRefs, formatException: true);
    final parts = requiredObjectList(
      json,
      'parts',
    ).map(SharedManagedPartHead.fromJson).toList(growable: false);
    _validateUniqueParts(parts);
    return SharedWork(
      workId: requiredString(json, 'workId'),
      title: requiredString(json, 'title'),
      lifecycle: lifecycle,
      metadataVersion: _requiredPositiveInt(json, 'metadataVersion'),
      lineageRefs: List<SharedWorkLineageRef>.unmodifiable(lineageRefs),
      resourceRefs: requiredObjectList(
        json,
        'resourceRefs',
      ).map(SharedManagedResourceRef.fromJson).toList(growable: false),
      parts: List<SharedManagedPartHead>.unmodifiable(parts),
      etag: requiredString(json, 'etag'),
    );
  }

  final String workId;
  final String title;
  final String lifecycle;
  final int metadataVersion;
  final List<SharedWorkLineageRef> lineageRefs;
  final List<SharedManagedResourceRef> resourceRefs;
  final List<SharedManagedPartHead> parts;
  final String etag;
}

final class SharedWorkPage {
  const SharedWorkPage({required this.items, this.nextCursor});

  factory SharedWorkPage.fromJson(Map<String, Object?> json) {
    _requireOnlyContractFields(json, const <String>{
      'items',
      'nextCursor',
    }, 'WorkListResponse');
    return SharedWorkPage(
      items: requiredObjectList(
        json,
        'items',
      ).map(SharedWork.fromJson).toList(growable: false),
      nextCursor: optionalString(json, 'nextCursor'),
    );
  }

  final List<SharedWork> items;
  final String? nextCursor;
}

final class SharedUpdateBookRequest {
  SharedUpdateBookRequest({
    required String title,
    required String language,
    required String status,
    String? subtitle,
  }) : title = title.trim(),
       subtitle = subtitle?.trim(),
       language = language.trim(),
       status = status.trim() {
    _validateOpaqueInput(this.title, 'title');
    _validateOpaqueInput(this.language, 'language');
    if (!_bookStatuses.contains(this.status)) {
      throw ArgumentError.value(status, 'status', 'Unsupported Book status');
    }
    if (this.subtitle != null && this.subtitle!.isEmpty) {
      throw ArgumentError.value(subtitle, 'subtitle', 'Must not be empty');
    }
  }

  final String title;
  final String? subtitle;
  final String language;
  final String status;

  Map<String, Object?> toJson() => <String, Object?>{
    'title': title,
    if (subtitle != null) 'subtitle': subtitle,
    'language': language,
    'status': status,
  };
}

final class SharedCreateBookSectionRequest {
  SharedCreateBookSectionRequest({
    required String sectionKey,
    required String title,
    required String group,
    this.ordinal,
    Map<String, String>? parts,
    Iterable<SharedManagedLineageRef> sourceRefs =
        const <SharedManagedLineageRef>[],
    Iterable<SharedManagedResourceRef> resourceRefs =
        const <SharedManagedResourceRef>[],
  }) : sectionKey = sectionKey.trim(),
       title = title.trim(),
       group = group.trim(),
       parts = parts == null ? null : _validateBookPartsInput(parts),
       sourceRefs = List<SharedManagedLineageRef>.unmodifiable(sourceRefs),
       resourceRefs = List<SharedManagedResourceRef>.unmodifiable(
         resourceRefs,
       ) {
    _validateBookSectionKey(this.sectionKey, 'sectionKey');
    _validateOpaqueInput(this.title, 'title');
    _validateBookSectionGroup(this.group, 'group');
    if (ordinal != null) _validateOrdinal(ordinal!, 'ordinal');
  }

  final String sectionKey;
  final String title;
  final String group;
  final int? ordinal;
  final Map<String, String>? parts;
  final List<SharedManagedLineageRef> sourceRefs;
  final List<SharedManagedResourceRef> resourceRefs;

  Map<String, Object?> toJson() => <String, Object?>{
    'sectionKey': sectionKey,
    'title': title,
    'group': group,
    if (ordinal != null) 'ordinal': ordinal,
    if (parts != null) 'parts': parts,
    if (sourceRefs.isNotEmpty)
      'sourceRefs': sourceRefs.map((item) => item.toJson()).toList(),
    if (resourceRefs.isNotEmpty)
      'resourceRefs': resourceRefs.map((item) => item.toJson()).toList(),
  };
}

final class SharedUpdateBookSectionRequest {
  SharedUpdateBookSectionRequest({String? title, String? group, this.ordinal})
    : title = title?.trim(),
      group = group?.trim() {
    if (this.title == null && this.group == null && ordinal == null) {
      throw ArgumentError.value(
        null,
        'request',
        'At least one section field is required',
      );
    }
    if (this.title != null) _validateOpaqueInput(this.title!, 'title');
    if (this.group != null) _validateBookSectionGroup(this.group!, 'group');
    if (ordinal != null) _validateOrdinal(ordinal!, 'ordinal');
  }

  final String? title;
  final String? group;
  final int? ordinal;

  Map<String, Object?> toJson() => <String, Object?>{
    if (title != null) 'title': title,
    if (group != null) 'group': group,
    if (ordinal != null) 'ordinal': ordinal,
  };
}

final class SharedMoveBookSectionRequest {
  SharedMoveBookSectionRequest({
    required String targetGroup,
    required this.targetOrdinal,
    required String expectedBookRevisionId,
  }) : targetGroup = targetGroup.trim(),
       expectedBookRevisionId = expectedBookRevisionId.trim() {
    _validateBookSectionGroup(this.targetGroup, 'targetGroup');
    _validateOrdinal(targetOrdinal, 'targetOrdinal');
    _validateOpaqueInput(this.expectedBookRevisionId, 'expectedBookRevisionId');
  }

  final String targetGroup;
  final int targetOrdinal;
  final String expectedBookRevisionId;

  Map<String, Object?> toJson() => <String, Object?>{
    'targetGroup': targetGroup,
    'targetOrdinal': targetOrdinal,
    'expectedBookRevisionId': expectedBookRevisionId,
  };
}

final class SharedImportBookRequest {
  SharedImportBookRequest({
    required String resourceId,
    required String expectedBookRevisionId,
  }) : resourceId = resourceId.trim(),
       expectedBookRevisionId = expectedBookRevisionId.trim() {
    _validateOpaqueInput(this.resourceId, 'resourceId');
    _validateOpaqueInput(this.expectedBookRevisionId, 'expectedBookRevisionId');
  }

  final String resourceId;
  final String expectedBookRevisionId;

  Map<String, Object?> toJson() => <String, Object?>{
    'resourceId': resourceId,
    'expectedBookRevisionId': expectedBookRevisionId,
  };
}

final class SharedUpdateManagedPartRequest {
  SharedUpdateManagedPartRequest({
    required this.contentMarkdown,
    required String basePartRevisionId,
    Iterable<SharedNotePartSourceRef> sourceRefs =
        const <SharedNotePartSourceRef>[],
    Iterable<SharedManagedResourceRef> resourceRefs =
        const <SharedManagedResourceRef>[],
  }) : basePartRevisionId = basePartRevisionId.trim(),
       sourceRefs = List<SharedNotePartSourceRef>.unmodifiable(sourceRefs),
       resourceRefs = List<SharedManagedResourceRef>.unmodifiable(
         resourceRefs,
       ) {
    _validateOpaqueInput(this.basePartRevisionId, 'basePartRevisionId');
  }

  final String contentMarkdown;
  final String basePartRevisionId;
  final List<SharedNotePartSourceRef> sourceRefs;
  final List<SharedManagedResourceRef> resourceRefs;

  Map<String, Object?> toJson() => <String, Object?>{
    'contentMarkdown': contentMarkdown,
    'basePartRevisionId': basePartRevisionId,
    'sourceRefs': sourceRefs.map((item) => item.toJson()).toList(),
    if (resourceRefs.isNotEmpty)
      'resourceRefs': resourceRefs.map((item) => item.toJson()).toList(),
  };
}

final class SharedInitialWorkPart {
  SharedInitialWorkPart({required String part, required this.contentMarkdown})
    : part = part.trim() {
    _validateNotePart(this.part, 'part');
  }

  final String part;
  final String contentMarkdown;

  Map<String, Object?> toJson() => <String, Object?>{
    'part': part,
    'contentMarkdown': contentMarkdown,
  };
}

final class SharedCreateWorkRequest {
  SharedCreateWorkRequest({
    required String title,
    required Iterable<SharedWorkLineageRef> lineageRefs,
    this.initialPart,
    Iterable<SharedManagedResourceRef> resourceRefs =
        const <SharedManagedResourceRef>[],
  }) : title = title.trim(),
       lineageRefs = List<SharedWorkLineageRef>.unmodifiable(lineageRefs),
       resourceRefs = List<SharedManagedResourceRef>.unmodifiable(
         resourceRefs,
       ) {
    _validateOpaqueInput(this.title, 'title');
    _validateWorkLineageSequence(this.lineageRefs);
  }

  final String title;
  final SharedInitialWorkPart? initialPart;
  final List<SharedWorkLineageRef> lineageRefs;
  final List<SharedManagedResourceRef> resourceRefs;

  Map<String, Object?> toJson() => <String, Object?>{
    'title': title,
    if (initialPart != null) 'initialPart': initialPart!.toJson(),
    'lineageRefs': lineageRefs.map((item) => item.toJson()).toList(),
    if (resourceRefs.isNotEmpty)
      'resourceRefs': resourceRefs.map((item) => item.toJson()).toList(),
  };
}

final class SharedUpdateWorkRequest {
  SharedUpdateWorkRequest({
    String? title,
    Iterable<SharedManagedResourceRef>? resourceRefs,
  }) : title = title?.trim(),
       resourceRefs = resourceRefs == null
           ? null
           : List<SharedManagedResourceRef>.unmodifiable(resourceRefs) {
    if (this.title == null && this.resourceRefs == null) {
      throw ArgumentError.value(
        null,
        'request',
        'At least one Work field is required',
      );
    }
    if (this.title != null) _validateOpaqueInput(this.title!, 'title');
  }

  final String? title;
  final List<SharedManagedResourceRef>? resourceRefs;

  Map<String, Object?> toJson() => <String, Object?>{
    if (title != null) 'title': title,
    if (resourceRefs != null)
      'resourceRefs': resourceRefs!.map((item) => item.toJson()).toList(),
  };
}

final class SharedPromoteWorkRequest {
  SharedPromoteWorkRequest._({
    required this.target,
    required String sourcePart,
    required String sourcePartRevisionId,
    this.creationTitle,
    this.bookSectionKey,
    this.bookSectionTitle,
    this.bookSectionGroup,
  }) : sourcePart = sourcePart.trim(),
       sourcePartRevisionId = sourcePartRevisionId.trim() {
    _validateNotePart(this.sourcePart, 'sourcePart');
    _validateOpaqueInput(this.sourcePartRevisionId, 'sourcePartRevisionId');
  }

  factory SharedPromoteWorkRequest.creation({
    required String sourcePart,
    required String sourcePartRevisionId,
    required String title,
  }) {
    final normalizedTitle = title.trim();
    _validateOpaqueInput(normalizedTitle, 'title');
    return SharedPromoteWorkRequest._(
      target: 'creation',
      sourcePart: sourcePart,
      sourcePartRevisionId: sourcePartRevisionId,
      creationTitle: normalizedTitle,
    );
  }

  factory SharedPromoteWorkRequest.bookSection({
    required String sourcePart,
    required String sourcePartRevisionId,
    required String sectionKey,
    required String title,
    required String group,
  }) {
    final normalizedKey = sectionKey.trim();
    final normalizedTitle = title.trim();
    final normalizedGroup = group.trim();
    _validateBookSectionKey(normalizedKey, 'sectionKey');
    _validateOpaqueInput(normalizedTitle, 'title');
    _validateBookSectionGroup(normalizedGroup, 'group');
    return SharedPromoteWorkRequest._(
      target: 'book_section',
      sourcePart: sourcePart,
      sourcePartRevisionId: sourcePartRevisionId,
      bookSectionKey: normalizedKey,
      bookSectionTitle: normalizedTitle,
      bookSectionGroup: normalizedGroup,
    );
  }

  final String target;
  final String sourcePart;
  final String sourcePartRevisionId;
  final String? creationTitle;
  final String? bookSectionKey;
  final String? bookSectionTitle;
  final String? bookSectionGroup;

  Map<String, Object?> toJson() => <String, Object?>{
    'target': target,
    'sourcePart': sourcePart,
    'sourcePartRevisionId': sourcePartRevisionId,
    if (target == 'creation')
      'creation': <String, Object?>{'title': creationTitle},
    if (target == 'book_section')
      'bookSection': <String, Object?>{
        'sectionKey': bookSectionKey,
        'title': bookSectionTitle,
        'group': bookSectionGroup,
      },
  };
}

final _chatIdentifier = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$');

String _partRevisionId(Map<String, Object?> parts, String part) {
  return requiredString(requiredObject(parts, part), 'partRevisionId');
}

void _validateChatIdentifier(String value, String name) {
  if (!_chatIdentifier.hasMatch(value)) {
    throw ArgumentError.value(value, name, 'Invalid remote identifier');
  }
}

List<SharedAgentInputContent> _normalizeAgentInput(
  Iterable<SharedAgentInputContent> content,
) {
  final normalized = <SharedAgentInputContent>[];
  final seenReferences = <String>{};
  var textCount = 0;
  for (final part in content) {
    if (part is SharedAgentTextContent) {
      textCount += 1;
      normalized.add(part);
    } else if (seenReferences.add(part.identity)) {
      normalized.add(part);
    }
    if (normalized.length > 256) {
      throw ArgumentError.value(content, 'content', 'Maximum is 256');
    }
  }
  if (textCount == 0) {
    throw ArgumentError.value(
      content,
      'content',
      'At least one text part required',
    );
  }
  return List<SharedAgentInputContent>.unmodifiable(normalized);
}

List<SharedChatContextReference> _deduplicateChatReferences(
  Iterable<SharedChatContextReference> references,
) {
  final deduplicated = <String, SharedChatContextReference>{};
  for (final reference in references) {
    deduplicated.putIfAbsent(
      '${reference.type}:${reference.id}',
      () => reference,
    );
    if (deduplicated.length > 50) {
      throw ArgumentError.value(references, 'references', 'Maximum is 50');
    }
  }
  return List<SharedChatContextReference>.unmodifiable(deduplicated.values);
}

String _requiredOpaqueTaskIdentifier(Map<String, Object?> json, String key) {
  final value = requiredString(json, key);
  if (!_opaqueTaskIdentifierPattern.hasMatch(value)) {
    throw FormatException('$key is not a safe opaque task identifier');
  }
  return value;
}

String? _optionalOpaqueTaskIdentifier(Map<String, Object?> json, String key) {
  final value = optionalString(json, key);
  if (value == null) return null;
  if (!_opaqueTaskIdentifierPattern.hasMatch(value)) {
    throw FormatException('$key is not a safe opaque task identifier');
  }
  return value;
}

String? _nullableString(Map<String, Object?> json, String key) {
  if (!json.containsKey(key) || json[key] == null) return null;
  return requiredString(json, key, allowEmpty: true);
}

int? _optionalSubscriptionCount(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is int && value >= 0) return value;
  if (value is num &&
      value.isFinite &&
      value >= 0 &&
      value == value.truncateToDouble()) {
    return value.toInt();
  }
  if (value is String && RegExp(r'^(0|[1-9][0-9]*)$').hasMatch(value)) {
    final parsed = int.tryParse(value);
    if (parsed != null && parsed >= 0) return parsed;
  }
  final type = value.runtimeType.toString();
  throw FormatException('$key must be a non-negative integer ($type)');
}

int _requiredPositiveInt(Map<String, Object?> json, String key) {
  final value = requiredInt(json, key);
  if (value <= 0) throw FormatException('$key must be positive');
  return value;
}

double _requiredFiniteNumber(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! num || !value.isFinite) {
    throw FormatException('$key must be a finite number');
  }
  return value.toDouble();
}

int? _optionalInt(Map<String, Object?> json, String key) {
  if (!json.containsKey(key) || json[key] == null) return null;
  return requiredInt(json, key);
}

int? _requiredNullableNonNegativeInt(Map<String, Object?> json, String key) {
  if (!json.containsKey(key)) {
    throw FormatException('$key must be present');
  }
  if (json[key] == null) return null;
  return requiredNonNegativeInt(json, key);
}

int _requiredSubscriptionOrdinal(Map<String, Object?> json) {
  if (json.containsKey('ordinal')) {
    return requiredNonNegativeInt(json, 'ordinal');
  }
  return requiredNonNegativeInt(json, 'sortOrder');
}

bool? _optionalBool(Map<String, Object?> json, String key) {
  if (!json.containsKey(key) || json[key] == null) return null;
  return requiredBool(json, key);
}

DateTime? _optionalDateTime(Map<String, Object?> json, String key) {
  if (!json.containsKey(key) || json[key] == null) return null;
  return requiredDateTime(json, key);
}

List<String> _requiredStringList(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! List || value.any((item) => item is! String)) {
    throw FormatException('$key must be a string list');
  }
  return value.cast<String>().toList(growable: false);
}

String _requiredContentCursor(Map<String, Object?> json, String key) {
  final value = requiredString(json, key);
  if (!RegExp(r'^[0-9]+$').hasMatch(value)) {
    throw FormatException('$key must be an opaque decimal string');
  }
  return value;
}

String? _requiredNullableString(Map<String, Object?> json, String key) {
  if (!json.containsKey(key)) {
    throw FormatException('$key must be present');
  }
  final value = json[key];
  if (value == null) return null;
  return requiredString(json, key);
}

String _requiredLogicalManagedPath(Map<String, Object?> json, String key) {
  final value = requiredString(json, key);
  final uri = Uri.tryParse(value);
  final segments = value.split('/');
  if (value.startsWith('/') ||
      value.contains('\\') ||
      uri == null ||
      uri.hasScheme ||
      uri.hasAuthority ||
      segments.any((segment) => segment == '..' || segment == '.')) {
    throw FormatException('$key must be a logical managed-content path');
  }
  return value;
}

void _rejectSearchSensitiveFields(Map<String, Object?> json) {
  const forbidden = <String>{
    'query',
    'body',
    'content',
    'snippet',
    'summary',
    'excerpt',
    'evidence',
    'realPath',
    'absolutePath',
    'resourceKey',
    'objectKey',
    'signedUrl',
    'sessionKey',
    'runId',
    'vector',
    'embedding',
    'embeddingVersion',
    'embeddingModel',
    'paginationCursor',
  };
  final leaked = json.keys.where(forbidden.contains).toList(growable: false);
  if (leaked.isNotEmpty) {
    throw FormatException('search response exposes forbidden fields: $leaked');
  }
}

List<String> _validatedSearchValues(
  Iterable<String> values,
  String name,
  Set<String> allowed,
) {
  final result = <String>[];
  final seen = <String>{};
  for (final raw in values) {
    final value = raw.trim();
    if (!allowed.contains(value)) {
      throw ArgumentError.value(raw, name, 'Unsupported search filter');
    }
    if (seen.add(value)) result.add(value);
  }
  return List<String>.unmodifiable(result);
}

List<String> _validatedRemoteIds(Iterable<String> values, String name) {
  final result = <String>[];
  final seen = <String>{};
  for (final raw in values) {
    final value = raw.trim();
    if (value.isEmpty) {
      throw ArgumentError.value(raw, name, 'Value must not be empty');
    }
    if (seen.add(value)) result.add(value);
  }
  return List<String>.unmodifiable(result);
}

void _validateNotePart(String value, String name) {
  if (!_hNoteParts.contains(value)) {
    throw ArgumentError.value(value, name, 'Unsupported HNote part');
  }
}

void _validateOpaqueInput(String value, String name) {
  if (value.isEmpty) {
    throw ArgumentError.value(value, name, 'Value must not be empty');
  }
}

void _requireOnlyContractFields(
  Map<String, Object?> json,
  Set<String> allowed,
  String name,
) {
  final unknown = json.keys
      .where((key) => !allowed.contains(key))
      .toList(growable: false);
  if (unknown.isNotEmpty) {
    throw FormatException('$name contains unsupported fields: $unknown');
  }
}

String _requiredBookPart(Map<String, Object?> json, String key) {
  final value = requiredString(json, key);
  if (!_hNoteParts.contains(value)) {
    throw FormatException('unsupported HNote part: $value');
  }
  return value;
}

String _requiredBookSectionGroup(Map<String, Object?> json, String key) {
  final value = requiredString(json, key);
  if (!_bookSectionGroups.contains(value)) {
    throw FormatException('unsupported Book section group: $value');
  }
  return value;
}

String _requiredBookSectionKey(Map<String, Object?> json, String key) {
  final value = requiredString(json, key);
  if (!_bookSectionKeyPattern.hasMatch(value)) {
    throw FormatException('invalid Book section key: $value');
  }
  return value;
}

void _validateBookSectionGroup(String value, String name) {
  if (!_bookSectionGroups.contains(value)) {
    throw ArgumentError.value(value, name, 'Unsupported Book section group');
  }
}

void _validateBookSectionKey(String value, String name) {
  if (!_bookSectionKeyPattern.hasMatch(value)) {
    throw ArgumentError.value(value, name, 'Invalid Book section key');
  }
}

void _validateOrdinal(int value, String name) {
  if (value < 0) {
    throw ArgumentError.value(value, name, 'Must not be negative');
  }
}

Map<String, String> _parseBookPartRevisionMap(Map<String, Object?> json) {
  final result = <String, String>{};
  for (final entry in json.entries) {
    if (!_hNoteParts.contains(entry.key) ||
        entry.value is! String ||
        (entry.value! as String).trim().isEmpty) {
      throw FormatException(
        'currentPartRevisionIds contains an invalid ${entry.key} revision',
      );
    }
    result[entry.key] = entry.value! as String;
  }
  return Map<String, String>.unmodifiable(result);
}

Map<String, String> _validateBookPartsInput(Map<String, String> parts) {
  final result = <String, String>{};
  for (final entry in parts.entries) {
    _validateNotePart(entry.key, 'parts');
    result[entry.key] = entry.value;
  }
  return Map<String, String>.unmodifiable(result);
}

void _validateUniqueParts(Iterable<SharedManagedPartHead> parts) {
  final seen = <String>{};
  for (final part in parts) {
    if (!seen.add(part.part)) {
      throw FormatException('duplicate managed part: ${part.part}');
    }
  }
}

void _validateBookSectionOrder(Iterable<Object> sections) {
  var groupIndex = 0;
  final nextOrdinal = <String, int>{};
  final keys = <String>{};
  for (final section in sections) {
    final (key, group, ordinal) = switch (section) {
      SharedBookSectionSnapshot value => (
        value.sectionKey,
        value.group,
        value.ordinal,
      ),
      SharedBookSection value => (value.sectionKey, value.group, value.ordinal),
      _ => throw const FormatException('invalid Book section snapshot'),
    };
    if (!keys.add(key)) throw FormatException('duplicate section key: $key');
    final candidateGroupIndex = _bookSectionGroupOrder.indexOf(group);
    if (candidateGroupIndex < groupIndex) {
      throw const FormatException('Book sections are not group ordered');
    }
    groupIndex = candidateGroupIndex;
    final expected = nextOrdinal[group] ?? 0;
    if (ordinal != expected) {
      throw FormatException(
        'Book section ordinals for $group must be dense from zero',
      );
    }
    nextOrdinal[group] = expected + 1;
  }
}

bool _sameBookSnapshot(
  List<SharedBookSectionSnapshot> snapshots,
  List<SharedBookSection> sections,
) {
  if (snapshots.length != sections.length) return false;
  for (var index = 0; index < snapshots.length; index += 1) {
    final snapshot = snapshots[index];
    final section = sections[index];
    if (snapshot.sectionKey != section.sectionKey ||
        snapshot.title != section.title ||
        snapshot.group != section.group ||
        snapshot.ordinal != section.ordinal ||
        snapshot.metadataVersion != section.metadataVersion ||
        !_sameStringMap(
          snapshot.currentPartRevisionIds,
          section.currentPartRevisionIds,
        )) {
      return false;
    }
  }
  return true;
}

bool _sameStringMap(Map<String, String> left, Map<String, String> right) {
  if (left.length != right.length) return false;
  return left.entries.every((entry) => right[entry.key] == entry.value);
}

void _validateWorkLineageSequence(
  Iterable<SharedWorkLineageRef> refs, {
  bool formatException = false,
}) {
  var expected = 0;
  for (final ref in refs) {
    if (ref.ordinal != expected) {
      if (formatException) {
        throw const FormatException(
          'Work lineage ordinals must be dense and ordered from zero',
        );
      }
      throw ArgumentError.value(
        ref.ordinal,
        'lineageRefs',
        'Ordinals must be dense and ordered from zero',
      );
    }
    expected += 1;
  }
}

String _requiredWorkspaceObjectKind(Map<String, Object?> json, String key) {
  final value = requiredString(json, key);
  if (!_workspaceObjectKinds.contains(value)) {
    throw FormatException('unsupported $key: $value');
  }
  return value;
}

void _requireExactlyOneIdentityFamily(
  Map<String, Object?> json, {
  bool allowPrevious = false,
}) {
  final hasRevision = json.containsKey('revisionId');
  final hasVersion = json.containsKey('version');
  if (hasRevision == hasVersion) {
    throw const FormatException(
      'exactly one revisionId or version identity is required',
    );
  }
  if (hasRevision) {
    requiredString(json, 'revisionId');
    if (json.containsKey('previousVersion')) {
      throw const FormatException(
        'revision identity cannot include previousVersion',
      );
    }
    if (json.containsKey('previousRevisionId')) {
      if (!allowPrevious) {
        throw const FormatException(
          'snapshot identity cannot include previousRevisionId',
        );
      }
      requiredString(json, 'previousRevisionId');
    }
    return;
  }
  requiredNonNegativeInt(json, 'version');
  if (json.containsKey('previousRevisionId')) {
    throw const FormatException(
      'version identity cannot include previousRevisionId',
    );
  }
  if (json.containsKey('previousVersion')) {
    if (!allowPrevious) {
      throw const FormatException(
        'snapshot identity cannot include previousVersion',
      );
    }
    requiredNonNegativeInt(json, 'previousVersion');
  }
}

const _hNoteParts = <String>{'raw', 'outline', 'germination'};
const _publicHNoteDerivedTaskStatuses = <String>{
  'admitting',
  'retry_admitting',
  'retry_wait',
  'queued',
  'resolving',
  'planning',
  'running',
  'finalizing',
  'succeeded',
  'failed',
  'timeout',
  'cancelled',
  'conflict',
};
const _publicHNoteDerivedTerminalStatuses = <String>{
  'succeeded',
  'failed',
  'timeout',
  'cancelled',
  'conflict',
};
final _opaqueTaskIdentifierPattern = RegExp(
  r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,159}$',
);
const _bookSectionGroups = <String>{'front_matter', 'chapters', 'back_matter'};
const _bookSectionGroupOrder = <String>[
  'front_matter',
  'chapters',
  'back_matter',
];
final _bookSectionKeyPattern = RegExp(r'^[a-z][a-z0-9_-]{0,31}$');
const _bookStatuses = <String>{'draft', 'active', 'archived'};
const _bookImportPendingStatuses = <String>{'validating', 'ready', 'applying'};
const _managedPartStatuses = <String>{
  'pending',
  'current',
  'source_changed',
  'failed',
  'trashed',
};
const _workLifecycles = <String>{
  'draft',
  'active',
  'completed',
  'archived',
  'trashed',
};

const _searchModes = <String>{'keyword', 'semantic', 'hybrid'};
const _searchOwnerKinds = <String>{
  'hnote',
  'fixed_asset',
  'creation',
  'book_section',
  'work',
};
const _searchReadiness = <String>{'current', 'catching_up', 'unavailable'};
const _vectorStatuses = <String>{'current', 'unavailable'};
const _explicitRelationTypes = <String>{'causal', 'supports', 'contradicts'};
const _workspaceObjectKinds = <String>{
  'hnote',
  'folder',
  'fixed_asset',
  'creation',
  'book',
  'book_section',
  'work',
  'positioning',
  'profile_visual_asset',
  'note_relation',
};
