import 'dart:typed_data';

import '../contracts/contract_models.dart';
import 'api_client.dart';
import 'api_contract_object.dart';
import 'api_envelope.dart';
import 'idempotency.dart';
import 'request_parsing.dart';

export '../billing/account_usage_client.dart';
export '../workspace/workspace_lifecycle_client.dart';
export 'api_contract_object.dart';

final class AgentProfileIcon {
  const AgentProfileIcon({this.resourceId});

  factory AgentProfileIcon.fromValue(Object? value) {
    final object = ApiContractObject.fromValue(value);
    _requireOnlyFields(object.fields, const <String>{'resourceId'}, 'icon');
    return AgentProfileIcon(
      resourceId: _optionalSafeResourceId(object.fields, 'resourceId'),
    );
  }

  final String? resourceId;
}

final class AgentProfileCatalogItem {
  const AgentProfileCatalogItem({
    required this.agentProfileId,
    required this.displayName,
    this.description,
    this.icon,
  });

  factory AgentProfileCatalogItem.fromValue(Object? value) {
    final object = ApiContractObject.fromValue(value);
    _requireOnlyFields(object.fields, const <String>{
      'agentProfileId',
      'displayName',
      'description',
      'icon',
    }, 'AgentProfileCatalogItem');
    return AgentProfileCatalogItem(
      agentProfileId: object.requireString('agentProfileId'),
      displayName: object.requireString('displayName'),
      description: object.optionalString('description'),
      icon: object.fields['icon'] == null
          ? null
          : AgentProfileIcon.fromValue(object.fields['icon']),
    );
  }

  final String agentProfileId;
  final String displayName;
  final String? description;
  final AgentProfileIcon? icon;
}

final class SkillProfileCatalogItem {
  const SkillProfileCatalogItem({
    required this.skillProfileId,
    required this.displayName,
    required this.installation,
    this.description,
  });

  factory SkillProfileCatalogItem.fromValue(Object? value) {
    final object = ApiContractObject.fromValue(value);
    _requireOnlyFields(object.fields, const <String>{
      'skillProfileId',
      'displayName',
      'description',
      'installation',
    }, 'SkillProfileCatalogItem');
    final installation = object.requireString('installation');
    const allowed = <String>{'not_installed', 'enabled', 'disabled'};
    if (!allowed.contains(installation)) {
      throw FormatException('Unsupported installation: $installation');
    }
    return SkillProfileCatalogItem(
      skillProfileId: object.requireString('skillProfileId'),
      displayName: object.requireString('displayName'),
      installation: installation,
      description: object.optionalString('description'),
    );
  }

  final String skillProfileId;
  final String displayName;
  final String installation;
  final String? description;
}

final class ModelProfileCatalogItem {
  const ModelProfileCatalogItem({
    required this.modelProfileId,
    required this.displayName,
    this.description,
  });

  factory ModelProfileCatalogItem.fromValue(Object? value) {
    final object = ApiContractObject.fromValue(value);
    _requireOnlyFields(object.fields, const <String>{
      'modelProfileId',
      'displayName',
      'description',
    }, 'ModelProfileCatalogItem');
    return ModelProfileCatalogItem(
      modelProfileId: object.requireString('modelProfileId'),
      displayName: object.requireString('displayName'),
      description: object.optionalString('description'),
    );
  }

  final String modelProfileId;
  final String displayName;
  final String? description;
}

final class AgentProfileCatalog {
  const AgentProfileCatalog({
    required this.catalogVersion,
    required this.items,
  });

  factory AgentProfileCatalog.fromValue(Object? value) {
    final object = ApiContractObject.fromValue(value);
    _requireOnlyFields(object.fields, const <String>{
      'catalogVersion',
      'items',
    }, 'AgentProfileCatalogResponse');
    final rawItems = object.fields['items'];
    if (rawItems is! List) {
      throw const FormatException('items must be a list');
    }
    return AgentProfileCatalog(
      catalogVersion: object.requireString('catalogVersion'),
      items: List<AgentProfileCatalogItem>.unmodifiable(
        rawItems.map(AgentProfileCatalogItem.fromValue),
      ),
    );
  }

  final String catalogVersion;
  final List<AgentProfileCatalogItem> items;
}

final class SharedSkillInstallation {
  const SharedSkillInstallation({
    required this.skillProfileId,
    required this.state,
    required this.installMode,
    required this.installedAt,
    required this.updatedAt,
  });

  factory SharedSkillInstallation.fromValue(Object? value) {
    final object = ApiContractObject.fromValue(value);
    _requireOnlyFields(object.fields, const <String>{
      'skillProfileId',
      'state',
      'installMode',
      'installedAt',
      'updatedAt',
    }, 'SkillInstallation');
    final state = object.requireString('state');
    final installMode = object.requireString('installMode');
    _requireAllowed(state, const <String>{'enabled', 'disabled'}, 'state');
    _requireAllowed(installMode, const <String>{
      'user_managed',
      'system_managed',
    }, 'installMode');
    return SharedSkillInstallation(
      skillProfileId: object.requireString('skillProfileId'),
      state: state,
      installMode: installMode,
      installedAt: _requiredDateTime(object.fields, 'installedAt'),
      updatedAt: _requiredDateTime(object.fields, 'updatedAt'),
    );
  }

  final String skillProfileId;
  final String state;
  final String installMode;
  final DateTime installedAt;
  final DateTime updatedAt;

  bool get isEnabled => state == 'enabled';
  bool get isUserManaged => installMode == 'user_managed';
}

final class SharedSkillInstallationList {
  const SharedSkillInstallationList({required this.items});

  factory SharedSkillInstallationList.fromValue(Object? value) {
    final object = ApiContractObject.fromValue(value);
    _requireOnlyFields(object.fields, const <String>{
      'items',
    }, 'SkillInstallationListResponse');
    final items = object.fields['items'];
    if (items is! List) {
      throw const FormatException('items must be a list');
    }
    return SharedSkillInstallationList(
      items: List<SharedSkillInstallation>.unmodifiable(
        items.map(SharedSkillInstallation.fromValue),
      ),
    ).._validateUniqueIds();
  }

  final List<SharedSkillInstallation> items;

  void _validateUniqueIds() {
    final ids = items.map((item) => item.skillProfileId).toSet();
    if (ids.length != items.length) {
      throw const FormatException('Skill installations must be unique');
    }
  }
}

final class AgentRunRequest {
  AgentRunRequest({
    required String agentProfileId,
    required this.input,
    Iterable<String> skillProfileIds = const <String>[],
    String? modelProfileId,
    this.threadId,
    this.workspaceId,
    this.locale,
    this.timezone,
  }) : agentProfileId = _catalogId(agentProfileId, 'agentProfileId'),
       modelProfileId = modelProfileId == null
           ? null
           : _catalogId(modelProfileId, 'modelProfileId'),
       skillProfileIds = _normalizedCatalogIds(
         skillProfileIds,
         'skillProfileIds',
       ) {
    if (threadId != null) _publicId(threadId!, 'threadId');
    if (workspaceId != null) _publicId(workspaceId!, 'workspaceId');
  }

  final String agentProfileId;
  final List<String> skillProfileIds;
  final String? modelProfileId;
  final String? threadId;
  final String? workspaceId;
  final String? locale;
  final String? timezone;
  final SharedAgentInput input;

  Map<String, Object?> toJson() => <String, Object?>{
    if (threadId != null) 'threadId': threadId,
    if (workspaceId != null) 'workspaceId': workspaceId,
    'agentProfileId': agentProfileId,
    if (skillProfileIds.isNotEmpty) 'skillProfileIds': skillProfileIds,
    if (modelProfileId != null) 'modelProfileId': modelProfileId,
    if (locale != null || timezone != null)
      'clientContext': <String, Object?>{
        if (locale != null) 'locale': locale,
        if (timezone != null) 'timezone': timezone,
      },
    'input': input.toJson(),
  };
}

const _agentRunStatuses = <String>{
  'resolving',
  'planning',
  'awaiting_confirmation',
  'queued',
  'running',
  'aborting',
  'succeeded',
  'failed',
  'timeout',
  'cancelled',
  'orphaned',
};

const _agentRunCompletionModes = <String>{
  'normal',
  'degraded',
  'system_fallback',
  'cancelled',
};

const _agentRunToolNames = <String>{
  'read',
  'workspace_list',
  'workspace_search',
  'write',
  'image_analysis',
  'image_generation',
  'video_analysis',
  'huahuo_hotspot_query',
};

const _agentRunToolInputSummaryFields = <String, Set<String>>{
  'read': <String>{'logicalTarget', 'offset', 'limit'},
  'workspace_list': <String>{'logicalDirectory', 'depth', 'limit'},
  'workspace_search': <String>{'query', 'logicalScope', 'limit', 'timeRange'},
  'write': <String>{'logicalTarget', 'operation', 'contentBytes'},
  'image_analysis': <String>{'attachmentCount', 'instructionSummary'},
  'image_generation': <String>{'promptSummary', 'count', 'aspectRatio'},
  'video_analysis': <String>{'attachmentCount', 'instructionSummary'},
  'huahuo_hotspot_query': <String>{
    'keywords',
    'timeRange',
    'limit',
    'action',
    'date',
    'rankCount',
  },
};

const _agentRunToolInputSummaryNumberFields = <String>{
  'offset',
  'limit',
  'depth',
  'contentBytes',
  'attachmentCount',
  'count',
  'rankCount',
};

const _agentRunToolInputSummaryListFields = <String>{
  'keywords',
  'redactedFields',
  'truncatedFields',
};

const _agentRunToolInputSummaryPathFields = <String>{
  'logicalTarget',
  'logicalDirectory',
  'logicalScope',
};

const _agentRunToolStates = <String>{'started', 'finished', 'rejected'};
const _agentRunToolOutcomes = <String>{'succeeded', 'failed'};

final class AgentRunUsage {
  const AgentRunUsage({
    required this.measurementStatus,
    required this.inputTokens,
    required this.outputTokens,
    required this.imageCount,
    required this.videoSeconds,
    required this.accountedCredits,
    required this.policyVersion,
  });

  factory AgentRunUsage.fromValue(Object? value) {
    final object = ApiContractObject.fromValue(value);
    _requireOnlyFields(object.fields, const <String>{
      'measurementStatus',
      'inputTokens',
      'outputTokens',
      'imageCount',
      'videoSeconds',
      'accountedCredits',
      'policyVersion',
    }, 'AgentRunUsage');
    final measurementStatus = object.requireString('measurementStatus');
    if (!const <String>{
      'pending',
      'measured',
      'unavailable',
    }.contains(measurementStatus)) {
      throw FormatException(
        'Unsupported measurementStatus: $measurementStatus',
      );
    }
    final usage = AgentRunUsage(
      measurementStatus: measurementStatus,
      inputTokens: _requiredNullableInt(object.fields, 'inputTokens'),
      outputTokens: _requiredNullableInt(object.fields, 'outputTokens'),
      imageCount: _requiredNullableInt(object.fields, 'imageCount'),
      videoSeconds: _requiredNullableNumber(object.fields, 'videoSeconds'),
      accountedCredits: _requiredNullableInt(object.fields, 'accountedCredits'),
      policyVersion: _requiredNullableString(object.fields, 'policyVersion'),
    );
    if (measurementStatus == 'measured' &&
        (usage.accountedCredits == null || usage.policyVersion == null)) {
      throw const FormatException(
        'Measured usage requires accountedCredits and policyVersion',
      );
    }
    if (measurementStatus == 'unavailable' &&
        <Object?>[
          usage.inputTokens,
          usage.outputTokens,
          usage.imageCount,
          usage.videoSeconds,
          usage.accountedCredits,
          usage.policyVersion,
        ].any((value) => value != null)) {
      throw const FormatException(
        'Unavailable usage cannot contain measured values',
      );
    }
    return usage;
  }

  final String measurementStatus;
  final int? inputTokens;
  final int? outputTokens;
  final int? imageCount;
  final num? videoSeconds;
  final int? accountedCredits;
  final String? policyVersion;
}

final class AgentRunResult {
  const AgentRunResult({
    required this.finalAnswer,
    required this.assistantMessageId,
    required this.completionMode,
  });

  factory AgentRunResult.fromValue(Object? value) {
    final object = ApiContractObject.fromValue(value);
    final completionMode = object.requireString('completionMode');
    _requireAllowed(completionMode, _agentRunCompletionModes, 'completionMode');
    return AgentRunResult(
      finalAnswer: object.requireString('finalAnswer'),
      assistantMessageId: object.requireString('assistantMessageId'),
      completionMode: completionMode,
    );
  }

  final String finalAnswer;
  final String assistantMessageId;
  final String completionMode;
}

final class AgentRunPublicRouting {
  const AgentRunPublicRouting({required this.state});

  factory AgentRunPublicRouting.fromValue(Object? value) {
    final object = ApiContractObject.fromValue(value);
    _requireOnlyFields(object.fields, const <String>{'state'}, 'routing');
    final state = object.requireString('state');
    _requireAllowed(state, const <String>{
      'planning',
      'clarification_required',
      'selected',
    }, 'routing.state');
    return AgentRunPublicRouting(state: state);
  }

  final String state;
}

final class AgentRunPublicClarification {
  const AgentRunPublicClarification({
    required this.kind,
    required this.userMessage,
  });

  factory AgentRunPublicClarification.fromValue(Object? value) {
    final object = ApiContractObject.fromValue(value);
    _requireOnlyFields(object.fields, const <String>{
      'kind',
      'userMessage',
    }, 'clarification');
    final kind = object.requireString('kind');
    _requireAllowed(kind, const <String>{
      'select_meta_workspace',
      'provide_required_input',
      'clarify_intent',
    }, 'clarification.kind');
    return AgentRunPublicClarification(
      kind: kind,
      userMessage: object.requireString('userMessage'),
    );
  }

  final String kind;
  final String userMessage;
}

final class AgentRunPublicError {
  AgentRunPublicError({required this.code, this.retryable})
    : fields = Map<String, Object?>.unmodifiable(<String, Object?>{
        'code': code,
        if (retryable != null) 'retryable': retryable,
      });

  factory AgentRunPublicError.fromValue(Object? value) {
    final object = ApiContractObject.fromValue(value);
    _requireOnlyFields(object.fields, const <String>{
      'code',
      'retryable',
    }, 'error');
    return AgentRunPublicError(
      code: object.requireString('code'),
      retryable: _optionalBool(object.fields, 'retryable'),
    );
  }

  final String code;
  final bool? retryable;

  // Compatibility projection for existing consumers while retaining a closed
  // parser for the documented public error shape.
  final Map<String, Object?> fields;
}

final class AgentRunOutputFile {
  const AgentRunOutputFile({
    required this.resourceId,
    required this.fileName,
    required this.mimeType,
    required this.sizeBytes,
  });

  factory AgentRunOutputFile.fromValue(Object? value) {
    final object = ApiContractObject.fromValue(value);
    _requireOnlyFields(object.fields, const <String>{
      'resourceId',
      'fileName',
      'mimeType',
      'sizeBytes',
    }, 'AgentRunOutputFile');
    return AgentRunOutputFile(
      resourceId: object.requireString('resourceId'),
      fileName: object.requireString('fileName'),
      mimeType: object.requireString('mimeType'),
      sizeBytes: _requiredNonNegativeInt(object.fields, 'sizeBytes'),
    );
  }

  final String resourceId;
  final String fileName;
  final String mimeType;
  final int sizeBytes;
}

final class AgentRunToolTrace {
  const AgentRunToolTrace({
    required this.invocationId,
    required this.toolName,
    required this.state,
    required this.createdAt,
    required this.outputFiles,
    this.outcome,
    this.completedAt,
    this.inputSummary = const <String, Object?>{},
  });

  factory AgentRunToolTrace.fromValue(Object? value) {
    final object = ApiContractObject.fromValue(value);
    _requireOnlyFields(object.fields, const <String>{
      'invocationId',
      'toolName',
      'state',
      'outcome',
      'createdAt',
      'completedAt',
      'outputFiles',
      'inputSummary',
    }, 'AgentRunToolTrace');
    final toolName = object.requireString('toolName');
    _requireAllowed(toolName, _agentRunToolNames, 'toolName');
    final state = object.requireString('state');
    _requireAllowed(state, _agentRunToolStates, 'state');
    final outcome = object.optionalString('outcome');
    if (outcome != null) {
      _requireAllowed(outcome, _agentRunToolOutcomes, 'outcome');
    }
    final rawOutputFiles = object.fields['outputFiles'];
    if (rawOutputFiles != null && rawOutputFiles is! List) {
      throw const FormatException('outputFiles must be a list');
    }
    return AgentRunToolTrace(
      invocationId: object.requireString('invocationId'),
      toolName: toolName,
      state: state,
      outcome: outcome,
      createdAt: _requiredDateTime(object.fields, 'createdAt'),
      completedAt: _optionalDateTime(object.fields, 'completedAt'),
      outputFiles: List<AgentRunOutputFile>.unmodifiable(
        (rawOutputFiles as List? ?? const <Object?>[]).map(
          AgentRunOutputFile.fromValue,
        ),
      ),
      inputSummary: _parseAgentRunToolInputSummary(
        object.fields['inputSummary'],
        toolName,
      ),
    );
  }

  final String invocationId;
  final String toolName;
  final String state;
  final String? outcome;
  final DateTime createdAt;
  final DateTime? completedAt;
  final List<AgentRunOutputFile> outputFiles;
  final Map<String, Object?> inputSummary;
}

final class AgentRunSnapshot {
  const AgentRunSnapshot({
    required this.agentRunId,
    required this.workspaceId,
    required this.status,
    required this.workspaceVersion,
    required this.workspaceBindingVersion,
    required this.contextGeneration,
    required this.usage,
    required this.toolTrace,
    required this.createdAt,
    required this.updatedAt,
    this.threadId,
    this.taskId,
    this.routingMode,
    this.sourceSurface,
    this.routing,
    this.clarification,
    this.result,
    this.error,
    this.assistantMessageId,
    this.completionMode,
  });

  factory AgentRunSnapshot.fromValue(Object? value) {
    final envelopeObject = ApiContractObject.fromValue(value);
    final rawRun = envelopeObject.fields['run'];
    final object = rawRun == null
        ? envelopeObject
        : ApiContractObject.fromValue(rawRun);
    _requireOnlyFields(object.fields, const <String>{
      'agentRunId',
      'workspaceId',
      'threadId',
      'taskId',
      'status',
      'routingMode',
      'sourceSurface',
      'workspaceVersion',
      'workspaceBindingVersion',
      'contextGeneration',
      'routing',
      'clarification',
      'result',
      'error',
      'assistantMessageId',
      'completionMode',
      'usage',
      'toolTrace',
      'createdAt',
      'updatedAt',
    }, 'PublicAgentRun');
    final status = object.requireString('status');
    _requireAllowed(status, _agentRunStatuses, 'status');
    final result = object.fields['result'] == null
        ? null
        : AgentRunResult.fromValue(object.fields['result']);
    final topLevelAssistantMessageId = object.optionalString(
      'assistantMessageId',
    );
    final topLevelCompletionMode = object.optionalString('completionMode');
    if (topLevelCompletionMode != null) {
      _requireAllowed(
        topLevelCompletionMode,
        _agentRunCompletionModes,
        'completionMode',
      );
    }
    if (result != null &&
        ((topLevelAssistantMessageId != null &&
                topLevelAssistantMessageId != result.assistantMessageId) ||
            (topLevelCompletionMode != null &&
                topLevelCompletionMode != result.completionMode))) {
      throw const FormatException(
        'Top-level terminal fields must match the durable result',
      );
    }
    final assistantMessageId =
        topLevelAssistantMessageId ?? result?.assistantMessageId;
    final completionMode = topLevelCompletionMode ?? result?.completionMode;
    if (status == 'succeeded' &&
        (assistantMessageId == null || completionMode == null)) {
      throw const FormatException(
        'A succeeded AgentRun requires a durable assistant result',
      );
    }
    final rawToolTrace = object.fields['toolTrace'];
    if (rawToolTrace != null && rawToolTrace is! List) {
      throw const FormatException('toolTrace must be a list');
    }
    return AgentRunSnapshot(
      agentRunId: object.requireString('agentRunId'),
      workspaceId: object.requireString('workspaceId'),
      threadId: object.optionalString('threadId'),
      taskId: object.optionalString('taskId'),
      routingMode: object.optionalString('routingMode'),
      sourceSurface: object.optionalString('sourceSurface'),
      status: status,
      workspaceVersion: _requiredNonNegativeInt(
        object.fields,
        'workspaceVersion',
      ),
      workspaceBindingVersion: _requiredNonNegativeInt(
        object.fields,
        'workspaceBindingVersion',
      ),
      contextGeneration: _requiredNonNegativeInt(
        object.fields,
        'contextGeneration',
      ),
      routing: object.fields['routing'] == null
          ? null
          : AgentRunPublicRouting.fromValue(object.fields['routing']),
      clarification: object.fields['clarification'] == null
          ? null
          : AgentRunPublicClarification.fromValue(
              object.fields['clarification'],
            ),
      result: result,
      error: object.fields['error'] == null
          ? null
          : AgentRunPublicError.fromValue(object.fields['error']),
      assistantMessageId: assistantMessageId,
      completionMode: completionMode,
      usage: AgentRunUsage.fromValue(object.fields['usage']),
      toolTrace: List<AgentRunToolTrace>.unmodifiable(
        (rawToolTrace as List? ?? const <Object?>[]).map(
          AgentRunToolTrace.fromValue,
        ),
      ),
      createdAt: _requiredDateTime(object.fields, 'createdAt'),
      updatedAt: _requiredDateTime(object.fields, 'updatedAt'),
    );
  }

  factory AgentRunSnapshot.fromCreateValue(Object? value) {
    final object = ApiContractObject.fromValue(value);
    final run = AgentRunSnapshot.fromValue(object.fields['run']);
    final nextAction = ApiContractObject.fromValue(object.fields['nextAction']);
    if (nextAction.requireString('type') != 'poll_agent_run' ||
        nextAction.requireString('agentRunId') != run.agentRunId ||
        _requiredNonNegativeInt(nextAction.fields, 'afterSequence') != 0) {
      throw const FormatException('Invalid AgentRun poll action');
    }
    return run;
  }

  final String agentRunId;
  final String workspaceId;
  final String? threadId;
  final String? taskId;
  final String? routingMode;
  final String? sourceSurface;
  final String status;
  final int workspaceVersion;
  final int workspaceBindingVersion;
  final int contextGeneration;
  final AgentRunPublicRouting? routing;
  final AgentRunPublicClarification? clarification;
  final AgentRunResult? result;
  final AgentRunPublicError? error;
  final String? assistantMessageId;
  final String? completionMode;
  final AgentRunUsage usage;
  final List<AgentRunToolTrace> toolTrace;
  final DateTime createdAt;
  final DateTime updatedAt;

  List<AgentRunOutputFile> get outputFiles =>
      List<AgentRunOutputFile>.unmodifiable(
        toolTrace.expand((trace) => trace.outputFiles),
      );

  bool get isTerminal => const <String>{
    'succeeded',
    'failed',
    'timeout',
    'cancelled',
    'orphaned',
  }.contains(status);

  bool get hasDurableAssistantResult =>
      status == 'succeeded' && assistantMessageId != null;

  bool get isSuccessful =>
      hasDurableAssistantResult && completionMode == 'normal';

  bool get isDegraded =>
      hasDurableAssistantResult && completionMode == 'degraded';

  bool get isSystemFallback =>
      hasDurableAssistantResult && completionMode == 'system_fallback';
}

final class AgentRunEventItem {
  const AgentRunEventItem({
    required this.sequence,
    required this.eventType,
    required this.status,
    required this.createdAt,
    this.data,
  });

  factory AgentRunEventItem.fromValue(Object? value) {
    final object = ApiContractObject.fromValue(value);
    _requireOnlyFields(object.fields, const <String>{
      'sequence',
      'eventType',
      'status',
      'data',
      'createdAt',
    }, 'AgentRunEventItem');
    final status = object.requireString('status');
    _requireAllowed(status, _agentRunStatuses, 'status');
    return AgentRunEventItem(
      sequence: _requiredNonNegativeInt(object.fields, 'sequence'),
      eventType: object.requireString('eventType'),
      status: status,
      data: object.fields['data'] == null
          ? null
          : AgentRunEventData.fromValue(object.fields['data']),
      createdAt: _requiredDateTime(object.fields, 'createdAt'),
    );
  }

  final int sequence;
  final String eventType;
  final String status;
  final AgentRunEventData? data;
  final DateTime createdAt;
}

final class AgentRunEventData {
  AgentRunEventData._({
    required this.fields,
    this.status,
    this.stage,
    this.deltaText,
    this.replace,
    this.invocationId,
    this.toolName,
    this.state,
    this.outcome,
    this.outputFiles = const <AgentRunOutputFile>[],
    this.usage,
    this.assistantMessageId,
    this.completionMode,
  });

  factory AgentRunEventData.fromValue(Object? value) {
    final object = ApiContractObject.fromValue(value);
    _requireOnlyFields(object.fields, const <String>{
      'status',
      'stage',
      'invocationId',
      'toolName',
      'state',
      'outcome',
      'outputFiles',
      'usage',
      'assistantMessageId',
      'completionMode',
      'deltaText',
      'replace',
    }, 'AgentRunEventData');
    final status = object.optionalString('status');
    if (status != null) _requireAllowed(status, _agentRunStatuses, 'status');
    final toolName = object.optionalString('toolName');
    if (toolName != null) {
      _requireAllowed(toolName, _agentRunToolNames, 'toolName');
    }
    final state = object.optionalString('state');
    if (state != null) _requireAllowed(state, _agentRunToolStates, 'state');
    final outcome = object.optionalString('outcome');
    if (outcome != null) {
      _requireAllowed(outcome, _agentRunToolOutcomes, 'outcome');
    }
    final completionMode = object.optionalString('completionMode');
    if (completionMode != null) {
      _requireAllowed(
        completionMode,
        _agentRunCompletionModes,
        'completionMode',
      );
    }
    final rawOutputFiles = object.fields['outputFiles'];
    if (rawOutputFiles != null && rawOutputFiles is! List) {
      throw const FormatException('outputFiles must be a list');
    }
    return AgentRunEventData._(
      fields: Map<String, Object?>.unmodifiable(object.fields),
      status: status,
      stage: object.optionalString('stage'),
      deltaText: object.optionalString('deltaText'),
      replace: _optionalBool(object.fields, 'replace'),
      invocationId: object.optionalString('invocationId'),
      toolName: toolName,
      state: state,
      outcome: outcome,
      outputFiles: List<AgentRunOutputFile>.unmodifiable(
        (rawOutputFiles as List? ?? const <Object?>[]).map(
          AgentRunOutputFile.fromValue,
        ),
      ),
      usage: object.fields['usage'] == null
          ? null
          : AgentRunUsage.fromValue(object.fields['usage']),
      assistantMessageId: object.optionalString('assistantMessageId'),
      completionMode: completionMode,
    );
  }

  final Map<String, Object?> fields;
  final String? status;
  final String? stage;
  final String? deltaText;
  final bool? replace;
  final String? invocationId;
  final String? toolName;
  final String? state;
  final String? outcome;
  final List<AgentRunOutputFile> outputFiles;
  final AgentRunUsage? usage;
  final String? assistantMessageId;
  final String? completionMode;
}

final class AgentRunEventPage {
  const AgentRunEventPage({
    required this.items,
    required this.nextAfterSequence,
    required this.hasMore,
    required this.oldestAvailableSequence,
    required this.latestSequence,
    required this.gap,
    this.terminalSequence,
  });

  factory AgentRunEventPage.fromValue(Object? value) {
    final object = ApiContractObject.fromValue(value);
    final rawItems = object.fields['items'];
    if (rawItems is! List) {
      throw const FormatException('items must be a list');
    }
    return AgentRunEventPage(
      items: List<AgentRunEventItem>.unmodifiable(
        rawItems.map(AgentRunEventItem.fromValue),
      ),
      nextAfterSequence: _requiredNonNegativeInt(
        object.fields,
        'nextAfterSequence',
      ),
      hasMore: _requiredBool(object.fields, 'hasMore'),
      oldestAvailableSequence: _requiredNonNegativeInt(
        object.fields,
        'oldestAvailableSequence',
      ),
      latestSequence: _requiredNonNegativeInt(object.fields, 'latestSequence'),
      terminalSequence: _nullableInt(object.fields, 'terminalSequence'),
      gap: _requiredBool(object.fields, 'gap'),
    );
  }

  final List<AgentRunEventItem> items;
  final int nextAfterSequence;
  final bool hasMore;
  final int oldestAvailableSequence;
  final int latestSequence;
  final int? terminalSequence;
  final bool gap;
}

enum AgentRunStreamPayloadKind { event, gap, capacityError }

final class AgentRunStreamPayload {
  const AgentRunStreamPayload._({
    required this.kind,
    this.item,
    this.errorCode,
    this.retryable,
    this.oldestAvailableSequence,
    this.latestSequence,
    this.resumeAfterSequence,
  });

  factory AgentRunStreamPayload.fromValue(Object? value) {
    final object = ApiContractObject.fromValue(value);
    if (object.fields.containsKey('sequence')) {
      return AgentRunStreamPayload._(
        kind: AgentRunStreamPayloadKind.event,
        item: AgentRunEventItem.fromValue(value),
      );
    }
    final error = ApiContractObject.fromValue(object.fields['error']);
    final code = error.requireString('code');
    final retryable = _requiredBool(error.fields, 'retryable');
    if (code == 'RUNTIME_EVENT_GAP' && !retryable) {
      return AgentRunStreamPayload._(
        kind: AgentRunStreamPayloadKind.gap,
        errorCode: code,
        retryable: false,
        oldestAvailableSequence: _requiredNonNegativeInt(
          error.fields,
          'oldestAvailableSequence',
        ),
        latestSequence: _requiredNonNegativeInt(error.fields, 'latestSequence'),
        resumeAfterSequence: _requiredNonNegativeInt(
          error.fields,
          'resumeAfterSequence',
        ),
      );
    }
    if (code == 'RUNTIME_CAPACITY_UNAVAILABLE' && retryable) {
      return const AgentRunStreamPayload._(
        kind: AgentRunStreamPayloadKind.capacityError,
        errorCode: 'RUNTIME_CAPACITY_UNAVAILABLE',
        retryable: true,
      );
    }
    throw FormatException('Unsupported AgentRun stream error: $code');
  }

  final AgentRunStreamPayloadKind kind;
  final AgentRunEventItem? item;
  final String? errorCode;
  final bool? retryable;
  final int? oldestAvailableSequence;
  final int? latestSequence;
  final int? resumeAfterSequence;
}

final class RecordingCardBindingClient {
  const RecordingCardBindingClient(this._api);

  final ApiClient _api;

  Future<ApiResult<SharedRecordingCardDeviceBindingResponse>>
  currentBinding() => _api.request<SharedRecordingCardDeviceBindingResponse>(
    ApiRequestOptions<SharedRecordingCardDeviceBindingResponse>(
      endpointId: 'recordingCardDeviceBinding',
      parseData: (value) => parseJsonModel(
        value,
        SharedRecordingCardDeviceBindingResponse.fromJson,
      ),
    ),
  );

  Future<ApiResult<SharedRecordingCardBindChallenge>> createBindChallenge(
    String serialNumber,
  ) => _api.request<SharedRecordingCardBindChallenge>(
    ApiRequestOptions<SharedRecordingCardBindChallenge>(
      endpointId: 'recordingCardBindChallenge',
      body: <String, Object?>{'serialNumber': serialNumber.trim()},
      parseData: (value) =>
          parseJsonModel(value, SharedRecordingCardBindChallenge.fromJson),
    ),
  );

  Future<ApiResult<SharedRecordingCardBindResponse>> bind({
    required String serialNumber,
    required String idempotencyKey,
    String? displayName,
  }) => _api.request<SharedRecordingCardBindResponse>(
    ApiRequestOptions<SharedRecordingCardBindResponse>(
      endpointId: 'bindRecordingCardOwnership',
      body: <String, Object?>{
        'serialNumber': serialNumber.trim(),
        if (displayName != null && displayName.trim().isNotEmpty)
          'displayName': displayName.trim(),
      },
      idempotency: IdempotencyRequestContext(explicitKey: idempotencyKey),
      parseData: (value) =>
          parseJsonModel(value, SharedRecordingCardBindResponse.fromJson),
    ),
  );

  Future<ApiResult<SharedRecordingCardUnbindResponse>> unbind({
    required String deviceId,
    required String bindingId,
    required String idempotencyKey,
  }) => _api.request<SharedRecordingCardUnbindResponse>(
    ApiRequestOptions<SharedRecordingCardUnbindResponse>(
      endpointId: 'unbindRecordingCardOwnership',
      pathParams: <String, Object>{'deviceId': deviceId.trim()},
      body: <String, Object?>{'bindingId': bindingId.trim()},
      idempotency: IdempotencyRequestContext(explicitKey: idempotencyKey),
      parseData: (value) =>
          parseJsonModel(value, SharedRecordingCardUnbindResponse.fromJson),
    ),
  );
}

final class WorkspaceContentClient {
  const WorkspaceContentClient(this._api);

  final ApiClient _api;

  Future<ApiResult<ApiContractObject>> snapshot(String workspaceId) =>
      _object('workspaceContentSnapshot', workspaceId);

  Future<ApiResult<SharedWorkspaceContentSnapshot>> contentSnapshot(
    String workspaceId, {
    String? pageToken,
  }) => _api.request<SharedWorkspaceContentSnapshot>(
    ApiRequestOptions<SharedWorkspaceContentSnapshot>(
      endpointId: 'workspaceContentSnapshot',
      pathParams: <String, Object>{'workspaceId': workspaceId},
      query: <String, Object?>{'pageToken': pageToken},
      parseData: (value) =>
          parseJsonModel(value, SharedWorkspaceContentSnapshot.fromJson),
    ),
  );

  Future<ApiConditionalResult<SharedWorkspaceContentSnapshot>>
  conditionalContentSnapshot(
    String workspaceId, {
    String? pageToken,
    String? ifNoneMatch,
  }) {
    final etag = ifNoneMatch?.trim();
    return _api.requestConditional<SharedWorkspaceContentSnapshot>(
      ApiRequestOptions<SharedWorkspaceContentSnapshot>(
        endpointId: 'workspaceContentSnapshot',
        pathParams: <String, Object>{'workspaceId': workspaceId},
        query: <String, Object?>{'pageToken': pageToken},
        headers: <String, String>{
          if (etag != null && etag.isNotEmpty) 'If-None-Match': etag,
        },
        parseData: (value) =>
            parseJsonModel(value, SharedWorkspaceContentSnapshot.fromJson),
      ),
    );
  }

  ApiRequestLease<ApiConditionalResult<SharedWorkspaceContentSnapshot>>
  leaseConditionalContentSnapshot(
    String workspaceId, {
    String? pageToken,
    String? ifNoneMatch,
  }) {
    final etag = ifNoneMatch?.trim();
    return _api.leaseConditionalGet<SharedWorkspaceContentSnapshot>(
      ApiRequestOptions<SharedWorkspaceContentSnapshot>(
        endpointId: 'workspaceContentSnapshot',
        pathParams: <String, Object>{'workspaceId': workspaceId},
        query: <String, Object?>{'pageToken': pageToken},
        headers: <String, String>{
          if (etag != null && etag.isNotEmpty) 'If-None-Match': etag,
        },
        parseData: (value) =>
            parseJsonModel(value, SharedWorkspaceContentSnapshot.fromJson),
      ),
    );
  }

  Future<ApiResult<SharedWorkspaceContentEventPage>> changes(
    String workspaceId, {
    required String after,
    int? limit,
  }) {
    _validateContentCursorArgument(after, 'after');
    return _api.request<SharedWorkspaceContentEventPage>(
      ApiRequestOptions<SharedWorkspaceContentEventPage>(
        endpointId: 'workspaceContentChanges',
        pathParams: <String, Object>{'workspaceId': workspaceId},
        query: <String, Object?>{
          'after': after,
          if (limit != null) 'limit': limit,
        },
        parseData: (value) =>
            parseJsonModel(value, SharedWorkspaceContentEventPage.fromJson),
      ),
    );
  }

  ApiRequestLease<ApiResult<SharedWorkspaceContentEventPage>> leaseChanges(
    String workspaceId, {
    required String after,
    int? limit,
  }) {
    _validateContentCursorArgument(after, 'after');
    return _api.leaseGet<SharedWorkspaceContentEventPage>(
      ApiRequestOptions<SharedWorkspaceContentEventPage>(
        endpointId: 'workspaceContentChanges',
        pathParams: <String, Object>{'workspaceId': workspaceId},
        query: <String, Object?>{
          'after': after,
          if (limit != null) 'limit': limit,
        },
        parseData: (value) =>
            parseJsonModel(value, SharedWorkspaceContentEventPage.fromJson),
      ),
    );
  }

  Future<ApiResult<ApiContractPage>> folders(String workspaceId) =>
      _page('workspaceFolders', workspaceId, itemsKey: 'folders');

  Future<ApiResult<SharedWorkspaceFolderList>> folderList(String workspaceId) =>
      _api.request<SharedWorkspaceFolderList>(
        ApiRequestOptions<SharedWorkspaceFolderList>(
          endpointId: 'workspaceFolders',
          pathParams: <String, Object>{'workspaceId': workspaceId},
          parseData: (value) =>
              parseJsonModel(value, SharedWorkspaceFolderList.fromJson),
        ),
      );

  Future<ApiResult<SharedWorkspaceFolder>> folder(
    String workspaceId,
    String folderId, {
    String? revisionId,
  }) => _api.request<SharedWorkspaceFolder>(
    ApiRequestOptions<SharedWorkspaceFolder>(
      endpointId: 'workspaceFolderDetail',
      pathParams: <String, Object>{
        'workspaceId': workspaceId,
        'folderId': folderId,
      },
      query: <String, Object?>{'revisionId': revisionId},
      parseData: (value) =>
          parseJsonModel(value, SharedWorkspaceFolder.fromJson),
    ),
  );

  ApiRequestLease<ApiResult<SharedWorkspaceFolder>> leaseFolder(
    String workspaceId,
    String folderId, {
    String? revisionId,
  }) => _api.leaseGet<SharedWorkspaceFolder>(
    ApiRequestOptions<SharedWorkspaceFolder>(
      endpointId: 'workspaceFolderDetail',
      pathParams: <String, Object>{
        'workspaceId': workspaceId,
        'folderId': folderId,
      },
      query: <String, Object?>{'revisionId': revisionId},
      parseData: (value) =>
          parseJsonModel(value, SharedWorkspaceFolder.fromJson),
    ),
  );

  Future<ApiResult<ApiContractPage>> notes(
    String workspaceId, {
    String? cursor,
  }) => _page(
    'workspaceNotes',
    workspaceId,
    query: <String, Object?>{'cursor': cursor},
  );

  Future<ApiResult<SharedHNote>> note(
    String workspaceId,
    String noteId, {
    String? revisionId,
  }) => _api.request<SharedHNote>(
    ApiRequestOptions<SharedHNote>(
      endpointId: 'workspaceNoteDetail',
      pathParams: <String, Object>{
        'workspaceId': workspaceId,
        'noteId': noteId,
      },
      query: <String, Object?>{'revisionId': revisionId},
      parseData: (value) {
        final object = asObjectMap(value);
        return object == null ? null : SharedHNote.fromJson(object);
      },
    ),
  );

  ApiRequestLease<ApiResult<SharedHNote>> leaseNote(
    String workspaceId,
    String noteId, {
    String? revisionId,
  }) => _api.leaseGet<SharedHNote>(
    ApiRequestOptions<SharedHNote>(
      endpointId: 'workspaceNoteDetail',
      pathParams: <String, Object>{
        'workspaceId': workspaceId,
        'noteId': noteId,
      },
      query: <String, Object?>{'revisionId': revisionId},
      parseData: (value) {
        final object = asObjectMap(value);
        return object == null ? null : SharedHNote.fromJson(object);
      },
    ),
  );

  Future<ApiResult<ApiContractObject>> legacyNote(
    String workspaceId,
    String noteId, {
    String? revisionId,
  }) => _api.request<ApiContractObject>(
    ApiRequestOptions<ApiContractObject>(
      endpointId: 'workspaceNoteDetail',
      pathParams: <String, Object>{
        'workspaceId': workspaceId,
        'noteId': noteId,
      },
      query: <String, Object?>{'revisionId': revisionId},
      parseData: parseApiObject,
    ),
  );

  Future<ApiResult<SharedHNotePartView>> notePart(
    String workspaceId,
    String noteId,
    String part, {
    String? partRevisionId,
  }) {
    _validateHNotePart(part);
    return _api.request<SharedHNotePartView>(
      ApiRequestOptions<SharedHNotePartView>(
        endpointId: 'workspaceNotePart',
        pathParams: <String, Object>{
          'workspaceId': workspaceId,
          'noteId': noteId,
          'part': part,
        },
        query: <String, Object?>{'partRevisionId': partRevisionId},
        parseData: (value) =>
            parseJsonModel(value, SharedHNotePartView.fromJson),
      ),
    );
  }

  ApiRequestLease<ApiResult<SharedHNotePartView>> leaseNotePart(
    String workspaceId,
    String noteId,
    String part, {
    String? partRevisionId,
  }) {
    _validateHNotePart(part);
    return _api.leaseGet<SharedHNotePartView>(
      ApiRequestOptions<SharedHNotePartView>(
        endpointId: 'workspaceNotePart',
        pathParams: <String, Object>{
          'workspaceId': workspaceId,
          'noteId': noteId,
          'part': part,
        },
        query: <String, Object?>{'partRevisionId': partRevisionId},
        parseData: (value) =>
            parseJsonModel(value, SharedHNotePartView.fromJson),
      ),
    );
  }

  Future<ApiResult<ApiContractObject>> legacyRawNotePart(
    String workspaceId,
    String noteId, {
    String? partRevisionId,
  }) => _api.request<ApiContractObject>(
    ApiRequestOptions<ApiContractObject>(
      endpointId: 'workspaceNotePart',
      pathParams: <String, Object>{
        'workspaceId': workspaceId,
        'noteId': noteId,
        'part': 'raw',
      },
      query: <String, Object?>{'partRevisionId': partRevisionId},
      parseData: parseApiObject,
    ),
  );

  Future<ApiResult<ApiContractObject>> contentNavigation(
    String workspaceId,
    String map,
  ) => _api.request<ApiContractObject>(
    ApiRequestOptions<ApiContractObject>(
      endpointId: 'contentNavigation',
      pathParams: <String, Object>{'workspaceId': workspaceId, 'map': map},
      parseData: parseApiObject,
    ),
  );

  Future<ApiResult<SharedWorkspaceSearchOutput>> workspaceSearch(
    String workspaceId, {
    required SharedWorkspaceSearchRequest request,
  }) => _api.request<SharedWorkspaceSearchOutput>(
    ApiRequestOptions<SharedWorkspaceSearchOutput>(
      endpointId: 'workspaceSearch',
      pathParams: <String, Object>{'workspaceId': workspaceId},
      body: request.toJson(),
      parseData: (value) =>
          parseJsonModel(value, SharedWorkspaceSearchOutput.fromJson),
    ),
  );

  Future<ApiResult<SharedWorkspaceSearchOutput>> search(
    String workspaceId, {
    required SharedWorkspaceSearchRequest request,
  }) => workspaceSearch(workspaceId, request: request);

  Future<ApiResult<SharedNoteRelationPage>> noteRelationPage(
    String workspaceId,
    String noteId, {
    String? cursor,
    int? limit,
  }) => _api.request<SharedNoteRelationPage>(
    ApiRequestOptions<SharedNoteRelationPage>(
      endpointId: 'noteRelations',
      pathParams: <String, Object>{
        'workspaceId': requiredClientText(workspaceId, 'workspaceId'),
        'noteId': requiredClientText(noteId, 'noteId'),
      },
      query: <String, Object?>{
        'cursor': cursor,
        if (limit != null) 'limit': boundedPageLimit(limit),
      },
      parseData: (value) =>
          parseJsonModel(value, SharedNoteRelationPage.fromJson),
    ),
  );

  Future<ApiResult<SharedWorkspaceContentEvent>> createNoteRelation(
    String workspaceId,
    String noteId, {
    required SharedCreateExplicitNoteRelationRequest request,
    required String idempotencyKey,
  }) => _noteRelationMutation(
    endpointId: 'createNoteRelation',
    workspaceId: workspaceId,
    noteId: noteId,
    body: request.toJson(),
    idempotencyKey: idempotencyKey,
  );

  Future<ApiResult<SharedWorkspaceContentEvent>> updateNoteRelation(
    String workspaceId,
    String relationId, {
    required SharedUpdateExplicitNoteRelationRequest request,
    required String etag,
    required String idempotencyKey,
  }) => _noteRelationMutation(
    endpointId: 'updateNoteRelation',
    workspaceId: workspaceId,
    relationId: relationId,
    body: request.toJson(),
    etag: etag,
    idempotencyKey: idempotencyKey,
  );

  Future<ApiResult<SharedWorkspaceContentEvent>> deleteNoteRelation(
    String workspaceId,
    String relationId, {
    required String etag,
    required String idempotencyKey,
  }) => _noteRelationMutation(
    endpointId: 'deleteNoteRelation',
    workspaceId: workspaceId,
    relationId: relationId,
    etag: etag,
    idempotencyKey: idempotencyKey,
  );

  Future<ApiResult<SharedWorkspaceFolder>> createFolder(
    String workspaceId, {
    required String displayName,
    String? parentFolderId,
    required String idempotencyKey,
  }) => _api.request<SharedWorkspaceFolder>(
    ApiRequestOptions<SharedWorkspaceFolder>(
      endpointId: 'createWorkspaceFolder',
      pathParams: <String, Object>{'workspaceId': workspaceId},
      body: <String, Object?>{
        'displayName': requiredClientText(displayName, 'displayName'),
        'parentFolderId': parentFolderId,
      },
      idempotency: IdempotencyRequestContext(explicitKey: idempotencyKey),
      parseData: (value) =>
          parseJsonModel(value, SharedWorkspaceFolder.fromJson),
    ),
  );

  Future<ApiResult<SharedWorkspaceFolder>> updateFolder(
    String workspaceId,
    String folderId, {
    required String displayName,
    required String etag,
    required String idempotencyKey,
  }) => _folderMutation<SharedWorkspaceFolder>(
    endpointId: 'updateWorkspaceFolder',
    workspaceId: workspaceId,
    folderId: folderId,
    etag: etag,
    idempotencyKey: idempotencyKey,
    body: <String, Object?>{
      'displayName': requiredClientText(displayName, 'displayName'),
    },
    parse: SharedWorkspaceFolder.fromJson,
  );

  Future<ApiResult<SharedWorkspaceContentEvent>> moveFolder(
    String workspaceId,
    String folderId, {
    required String? parentFolderId,
    required String etag,
    required String idempotencyKey,
  }) => _folderMutation<SharedWorkspaceContentEvent>(
    endpointId: 'moveWorkspaceFolder',
    workspaceId: workspaceId,
    folderId: folderId,
    etag: etag,
    idempotencyKey: idempotencyKey,
    body: <String, Object?>{'parentFolderId': parentFolderId},
    parse: SharedWorkspaceContentEvent.fromJson,
  );

  Future<ApiResult<SharedRecursiveFolderMutationResult>> deleteFolder(
    String workspaceId,
    String folderId, {
    required String etag,
    required String idempotencyKey,
  }) => _folderMutation<SharedRecursiveFolderMutationResult>(
    endpointId: 'deleteWorkspaceFolder',
    workspaceId: workspaceId,
    folderId: folderId,
    etag: etag,
    idempotencyKey: idempotencyKey,
    parse: SharedRecursiveFolderMutationResult.fromJson,
  );

  Future<ApiResult<SharedRecursiveFolderMutationResult>> restoreFolder(
    String workspaceId,
    String folderId, {
    String? parentFolderId,
    bool overrideParentFolder = false,
    required String etag,
    required String idempotencyKey,
  }) => _folderMutation<SharedRecursiveFolderMutationResult>(
    endpointId: 'restoreWorkspaceFolder',
    workspaceId: workspaceId,
    folderId: folderId,
    etag: etag,
    idempotencyKey: idempotencyKey,
    body: <String, Object?>{
      if (overrideParentFolder) 'parentFolderId': parentFolderId,
    },
    parse: SharedRecursiveFolderMutationResult.fromJson,
  );

  Future<ApiResult<SharedHNoteBatchMoveResult>> batchMoveNotes(
    String workspaceId, {
    required String? folderId,
    required Iterable<SharedHNoteBatchMoveInput> notes,
    required String idempotencyKey,
  }) {
    final normalizedNotes = _validatedBatchMoveNotes(notes);
    return _api.request<SharedHNoteBatchMoveResult>(
      ApiRequestOptions<SharedHNoteBatchMoveResult>(
        endpointId: 'batchMoveWorkspaceNotes',
        pathParams: <String, Object>{'workspaceId': workspaceId},
        body: <String, Object?>{
          'folderId': folderId,
          'notes': <Object?>[for (final note in normalizedNotes) note.toJson()],
        },
        idempotency: IdempotencyRequestContext(explicitKey: idempotencyKey),
        parseData: (value) =>
            parseJsonModel(value, SharedHNoteBatchMoveResult.fromJson),
      ),
    );
  }

  Future<ApiResult<SharedHNote>> createNote(
    String workspaceId, {
    required String title,
    String? folderId,
    required String rawMarkdown,
    required String outlineMarkdown,
    required String germinationMarkdown,
    Iterable<SharedHNoteResourceInput> resourceRefs =
        const <SharedHNoteResourceInput>[],
    required String idempotencyKey,
  }) => _api.request<SharedHNote>(
    ApiRequestOptions<SharedHNote>(
      endpointId: 'createWorkspaceNote',
      pathParams: <String, Object>{'workspaceId': workspaceId},
      body: <String, Object?>{
        'title': requiredClientText(title, 'title'),
        'sourceKind': 'manual',
        'folderId': folderId,
        'parts': <String, Object?>{
          'raw': rawMarkdown,
          'outline': outlineMarkdown,
          'germination': germinationMarkdown,
        },
        'resourceRefs': <Object?>[
          for (final resourceRef in resourceRefs) resourceRef.toJson(),
        ],
      },
      idempotency: IdempotencyRequestContext(explicitKey: idempotencyKey),
      parseData: (value) =>
          _parseWorkspaceHNoteMutation(value, workspaceId: workspaceId),
    ),
  );

  Future<ApiResult<ApiContractObject>> createManualNote(
    String workspaceId, {
    required String title,
    required String contentMarkdown,
    required String idempotencyKey,
  }) => _api.request<ApiContractObject>(
    ApiRequestOptions<ApiContractObject>(
      endpointId: 'createWorkspaceManualNote',
      pathParams: <String, Object>{'workspaceId': workspaceId},
      body: <String, Object?>{
        'title': requiredClientText(title, 'title'),
        'contentMarkdown': requiredClientText(
          contentMarkdown,
          'contentMarkdown',
        ),
      },
      idempotency: IdempotencyRequestContext(explicitKey: idempotencyKey),
      parseData: parseApiObject,
    ),
  );

  Future<ApiResult<ApiContractObject>> updateLegacyNoteMetadata(
    String workspaceId,
    String noteId, {
    required String title,
    required String etag,
    required String idempotencyKey,
  }) => _api.request<ApiContractObject>(
    ApiRequestOptions<ApiContractObject>(
      endpointId: 'updateWorkspaceNote',
      pathParams: <String, Object>{
        'workspaceId': workspaceId,
        'noteId': noteId,
      },
      headers: ifMatchHeaders(etag),
      body: <String, Object?>{'title': requiredClientText(title, 'title')},
      idempotency: IdempotencyRequestContext(explicitKey: idempotencyKey),
      parseData: parseApiObject,
    ),
  );

  Future<ApiResult<ApiContractObject>> updateLegacyRawNotePart(
    String workspaceId,
    String noteId, {
    required String contentMarkdown,
    required String basePartRevisionId,
    required String etag,
    required String idempotencyKey,
  }) => _api.request<ApiContractObject>(
    ApiRequestOptions<ApiContractObject>(
      endpointId: 'putWorkspaceNotePart',
      pathParams: <String, Object>{
        'workspaceId': workspaceId,
        'noteId': noteId,
        'part': 'raw',
      },
      headers: ifMatchHeaders(etag),
      body: <String, Object?>{
        'contentMarkdown': requiredClientText(
          contentMarkdown,
          'contentMarkdown',
        ),
        'basePartRevisionId': requiredClientText(
          basePartRevisionId,
          'basePartRevisionId',
        ),
      },
      idempotency: IdempotencyRequestContext(explicitKey: idempotencyKey),
      parseData: parseApiObject,
    ),
  );

  Future<ApiResult<SharedHNote>> updateNote(
    String workspaceId,
    String noteId, {
    String? title,
    String? folderId,
    bool updateFolder = false,
    Map<String, String>? parts,
    List<SharedHNoteResourceInput>? resourceRefs,
    required String etag,
    required String idempotencyKey,
  }) {
    final body = <String, Object?>{
      if (title != null) 'title': requiredClientText(title, 'title'),
      if (updateFolder) 'folderId': folderId,
      if (parts != null) 'parts': _validateHNoteParts(parts),
      if (resourceRefs != null)
        'resourceRefs': <Object?>[
          for (final resourceRef in resourceRefs) resourceRef.toJson(),
        ],
    };
    if (body.isEmpty) {
      throw ArgumentError('At least one HNote field must be updated');
    }
    return _noteMutation(
      endpointId: 'updateWorkspaceNote',
      workspaceId: workspaceId,
      noteId: noteId,
      etag: etag,
      idempotencyKey: idempotencyKey,
      body: body,
    );
  }

  Future<ApiResult<SharedWorkspaceContentEvent>> deleteNote(
    String workspaceId,
    String noteId, {
    required String etag,
    required String idempotencyKey,
  }) => _api.request<SharedWorkspaceContentEvent>(
    ApiRequestOptions<SharedWorkspaceContentEvent>(
      endpointId: 'deleteWorkspaceNote',
      pathParams: <String, Object>{
        'workspaceId': workspaceId,
        'noteId': noteId,
      },
      headers: ifMatchHeaders(etag),
      idempotency: IdempotencyRequestContext(explicitKey: idempotencyKey),
      parseData: (value) => _parseHNoteTombstoneEvent(
        value,
        workspaceId: workspaceId,
        noteId: noteId,
      ),
    ),
  );

  Future<ApiResult<SharedHNote>> restoreNote(
    String workspaceId,
    String noteId, {
    required String etag,
    required String idempotencyKey,
  }) => _api.request<SharedHNote>(
    ApiRequestOptions<SharedHNote>(
      endpointId: 'restoreWorkspaceNote',
      pathParams: <String, Object>{
        'workspaceId': workspaceId,
        'noteId': noteId,
      },
      body: const <String, Object?>{},
      headers: <String, String>{'If-Match': etag},
      idempotency: IdempotencyRequestContext(explicitKey: idempotencyKey),
      parseData: (value) => _parseWorkspaceHNoteMutation(
        value,
        workspaceId: workspaceId,
        expectedNoteId: noteId,
      ),
    ),
  );

  Future<ApiResult<SharedHNote>> putNotePart(
    String workspaceId,
    String noteId,
    String part, {
    required String markdown,
    required String basePartRevisionId,
    required String etag,
    required String idempotencyKey,
  }) {
    _validateHNotePart(part);
    return _api.request<SharedHNote>(
      ApiRequestOptions<SharedHNote>(
        endpointId: 'putWorkspaceNotePart',
        pathParams: <String, Object>{
          'workspaceId': workspaceId,
          'noteId': noteId,
          'part': part,
        },
        headers: ifMatchHeaders(etag),
        body: <String, Object?>{
          'contentMarkdown': markdown,
          'basePartRevisionId': basePartRevisionId,
        },
        idempotency: IdempotencyRequestContext(explicitKey: idempotencyKey),
        parseData: (value) => _parseWorkspaceHNoteMutation(
          value,
          workspaceId: workspaceId,
          expectedNoteId: noteId,
        ),
      ),
    );
  }

  Future<ApiResult<T>> _folderMutation<T>({
    required String endpointId,
    required String workspaceId,
    required String folderId,
    required String etag,
    required String idempotencyKey,
    Map<String, Object?>? body,
    required T Function(Map<String, Object?>) parse,
  }) => _api.request<T>(
    ApiRequestOptions<T>(
      endpointId: endpointId,
      pathParams: <String, Object>{
        'workspaceId': workspaceId,
        'folderId': folderId,
      },
      headers: ifMatchHeaders(etag),
      body: body,
      idempotency: IdempotencyRequestContext(explicitKey: idempotencyKey),
      parseData: (value) => parseJsonModel(value, parse),
    ),
  );

  Future<ApiResult<SharedHNote>> _noteMutation({
    required String endpointId,
    required String workspaceId,
    required String noteId,
    required String etag,
    required String idempotencyKey,
    Map<String, Object?>? body,
  }) => _api.request<SharedHNote>(
    ApiRequestOptions<SharedHNote>(
      endpointId: endpointId,
      pathParams: <String, Object>{
        'workspaceId': workspaceId,
        'noteId': noteId,
      },
      headers: ifMatchHeaders(etag),
      body: body,
      idempotency: IdempotencyRequestContext(explicitKey: idempotencyKey),
      parseData: (value) => _parseWorkspaceHNoteMutation(
        value,
        workspaceId: workspaceId,
        expectedNoteId: noteId,
      ),
    ),
  );

  Future<ApiResult<ApiContractObject>> _object(
    String endpointId,
    String workspaceId,
  ) => _api.request<ApiContractObject>(
    ApiRequestOptions<ApiContractObject>(
      endpointId: endpointId,
      pathParams: <String, Object>{'workspaceId': workspaceId},
      parseData: parseApiObject,
    ),
  );

  Future<ApiResult<ApiContractPage>> _page(
    String endpointId,
    String workspaceId, {
    Map<String, Object?> query = const <String, Object?>{},
    String itemsKey = 'items',
  }) => _api.request<ApiContractPage>(
    ApiRequestOptions<ApiContractPage>(
      endpointId: endpointId,
      pathParams: <String, Object>{'workspaceId': workspaceId},
      query: query,
      parseData: (value) =>
          ApiContractPage.fromValue(value, itemsKey: itemsKey),
    ),
  );

  Future<ApiResult<SharedWorkspaceContentEvent>> _noteRelationMutation({
    required String endpointId,
    required String workspaceId,
    String? noteId,
    String? relationId,
    Map<String, Object?>? body,
    String? etag,
    required String idempotencyKey,
  }) => _api.request<SharedWorkspaceContentEvent>(
    ApiRequestOptions<SharedWorkspaceContentEvent>(
      endpointId: endpointId,
      pathParams: <String, Object>{
        'workspaceId': requiredClientText(workspaceId, 'workspaceId'),
        if (noteId != null) 'noteId': requiredClientText(noteId, 'noteId'),
        if (relationId != null)
          'relationId': requiredClientText(relationId, 'relationId'),
      },
      body: body,
      headers: etag == null ? const <String, String>{} : ifMatchHeaders(etag),
      idempotency: IdempotencyRequestContext(explicitKey: idempotencyKey),
      parseData: (value) {
        final event = parseJsonModel(
          value,
          SharedWorkspaceContentEvent.fromJson,
        );
        if (event == null) return null;
        if (event.objectKind != 'note_relation' ||
            event.version == null ||
            event.revisionId != null ||
            event.resourcePinDelta.added.isNotEmpty ||
            event.resourcePinDelta.released.isNotEmpty) {
          throw const FormatException('invalid Note-relation mutation receipt');
        }
        if (relationId != null && event.objectId != relationId) {
          throw const FormatException('relation receipt objectId mismatch');
        }
        return event;
      },
    ),
  );
}

final class AgentCatalogClient {
  const AgentCatalogClient(this._api);

  final ApiClient _api;

  Future<ApiResult<AgentProfileCatalog>> profiles() =>
      _api.request<AgentProfileCatalog>(
        ApiRequestOptions<AgentProfileCatalog>(
          endpointId: 'agentProfiles',
          parseData: AgentProfileCatalog.fromValue,
        ),
      );

  Future<ApiResult<List<SkillProfileCatalogItem>>> skills(
    String agentProfileId,
  ) => _api.request<List<SkillProfileCatalogItem>>(
    ApiRequestOptions<List<SkillProfileCatalogItem>>(
      endpointId: 'agentProfileSkills',
      pathParams: <String, Object>{
        'agentProfileId': _catalogId(agentProfileId, 'agentProfileId'),
      },
      parseData: (value) =>
          _parseCatalogItems(value, SkillProfileCatalogItem.fromValue),
    ),
  );

  Future<ApiResult<List<ModelProfileCatalogItem>>> models(
    String agentProfileId,
  ) => _api.request<List<ModelProfileCatalogItem>>(
    ApiRequestOptions<List<ModelProfileCatalogItem>>(
      endpointId: 'agentProfileModels',
      pathParams: <String, Object>{
        'agentProfileId': _catalogId(agentProfileId, 'agentProfileId'),
      },
      parseData: (value) =>
          _parseCatalogItems(value, ModelProfileCatalogItem.fromValue),
    ),
  );

  Future<ApiResult<SharedSkillInstallationList>> installations(
    String workspaceId,
  ) => _api.request<SharedSkillInstallationList>(
    ApiRequestOptions<SharedSkillInstallationList>(
      endpointId: 'skillInstallations',
      pathParams: <String, Object>{
        'workspaceId': requiredClientText(workspaceId, 'workspaceId'),
      },
      parseData: SharedSkillInstallationList.fromValue,
    ),
  );

  Future<ApiResult<SharedSkillInstallation>> installSkill(
    String workspaceId,
    String skillProfileId, {
    required String idempotencyKey,
  }) => _installationMutation(
    endpointId: 'installSkill',
    workspaceId: workspaceId,
    skillProfileId: skillProfileId,
    body: <String, Object?>{
      'skillProfileId': _catalogId(skillProfileId, 'skillProfileId'),
    },
    idempotencyKey: idempotencyKey,
  );

  Future<ApiResult<SharedSkillInstallation>> updateSkillInstallation(
    String workspaceId,
    String skillProfileId, {
    required String state,
    required String idempotencyKey,
  }) {
    if (!const <String>{'enabled', 'disabled'}.contains(state)) {
      throw ArgumentError.value(
        state,
        'state',
        'Unsupported installation state',
      );
    }
    return _installationMutation(
      endpointId: 'updateSkillInstallation',
      workspaceId: workspaceId,
      skillProfileId: skillProfileId,
      body: <String, Object?>{'state': state},
      idempotencyKey: idempotencyKey,
    );
  }

  Future<ApiResult<bool>> deleteSkillInstallation(
    String workspaceId,
    String skillProfileId, {
    required String idempotencyKey,
  }) => _api.request<bool>(
    ApiRequestOptions<bool>(
      endpointId: 'deleteSkillInstallation',
      pathParams: <String, Object>{
        'workspaceId': requiredClientText(workspaceId, 'workspaceId'),
        'skillProfileId': _catalogId(skillProfileId, 'skillProfileId'),
      },
      idempotency: IdempotencyRequestContext(explicitKey: idempotencyKey),
      parseData: (_) => true,
    ),
  );

  Future<ApiResult<SharedSkillInstallation>> _installationMutation({
    required String endpointId,
    required String workspaceId,
    required String skillProfileId,
    required Map<String, Object?> body,
    required String idempotencyKey,
  }) => _api.request<SharedSkillInstallation>(
    ApiRequestOptions<SharedSkillInstallation>(
      endpointId: endpointId,
      pathParams: <String, Object>{
        'workspaceId': requiredClientText(workspaceId, 'workspaceId'),
        if (endpointId != 'installSkill')
          'skillProfileId': _catalogId(skillProfileId, 'skillProfileId'),
      },
      body: body,
      idempotency: IdempotencyRequestContext(explicitKey: idempotencyKey),
      parseData: (value) {
        final installation = SharedSkillInstallation.fromValue(value);
        final expectedSkillProfileId = _catalogId(
          skillProfileId,
          'skillProfileId',
        );
        if (installation.skillProfileId != expectedSkillProfileId) {
          throw const FormatException(
            'Skill installation response ID does not match request',
          );
        }
        if (endpointId == 'installSkill' &&
            (installation.state != 'enabled' ||
                installation.installMode != 'user_managed')) {
          throw const FormatException(
            'Installed Skill must be enabled and user-managed',
          );
        }
        final requestedState = body['state'];
        if (requestedState != null && installation.state != requestedState) {
          throw const FormatException(
            'Skill installation response state does not match request',
          );
        }
        return installation;
      },
    ),
  );
}

final class SharedChatFacadeClient {
  const SharedChatFacadeClient(this._api);

  final ApiClient _api;

  Future<ApiResult<T>> createThread<T>({
    required SharedChatThreadCreateRequest request,
    required IdempotencyRequestContext idempotency,
    SubmissionKeyStore idempotencyStore = SubmissionKeyStore.empty,
    required DataParser<T> parseData,
  }) => _api.request<T>(
    ApiRequestOptions<T>(
      endpointId: 'createChatThread',
      body: request.toJson(),
      idempotency: idempotency,
      idempotencyStore: idempotencyStore,
      parseData: parseData,
    ),
  );

  Future<ApiResult<T>> sendTextMessage<T>({
    required String threadId,
    required SharedChatTextMessageRequest request,
    required IdempotencyRequestContext idempotency,
    SubmissionKeyStore idempotencyStore = SubmissionKeyStore.empty,
    required DataParser<T> parseData,
  }) => _api.request<T>(
    ApiRequestOptions<T>(
      endpointId: 'sendChatMessage',
      pathParams: <String, Object>{'threadId': threadId},
      body: request.toJson(),
      idempotency: idempotency,
      idempotencyStore: idempotencyStore,
      parseData: parseData,
    ),
  );

  Future<ApiResult<T>> getThreadDetail<T>({
    required String threadId,
    required DataParser<T> parseData,
  }) => _api.request<T>(
    ApiRequestOptions<T>(
      endpointId: 'chatThreadDetail',
      pathParams: <String, Object>{'threadId': threadId},
      parseData: parseData,
    ),
  );
}

final class AgentRunClient {
  const AgentRunClient(this._api);

  final ApiClient _api;

  Future<ApiResult<AgentRunSnapshot>> create(
    AgentRunRequest request, {
    required String idempotencyKey,
  }) => _api.request<AgentRunSnapshot>(
    ApiRequestOptions<AgentRunSnapshot>(
      endpointId: 'createAgentRun',
      body: request.toJson(),
      idempotency: IdempotencyRequestContext(explicitKey: idempotencyKey),
      parseData: AgentRunSnapshot.fromCreateValue,
    ),
  );

  Future<ApiResult<AgentRunSnapshot>> get(String agentRunId) =>
      _api.request<AgentRunSnapshot>(
        ApiRequestOptions<AgentRunSnapshot>(
          endpointId: 'agentRunDetail',
          pathParams: <String, Object>{'agentRunId': agentRunId},
          parseData: AgentRunSnapshot.fromValue,
        ),
      );

  Future<ApiResult<AgentRunSnapshot>> cancel(
    String agentRunId, {
    required String idempotencyKey,
  }) => _api.request<AgentRunSnapshot>(
    ApiRequestOptions<AgentRunSnapshot>(
      endpointId: 'cancelAgentRun',
      pathParams: <String, Object>{'agentRunId': agentRunId},
      body: const <String, Object?>{'reason': 'user_cancelled'},
      idempotency: IdempotencyRequestContext(explicitKey: idempotencyKey),
      parseData: AgentRunSnapshot.fromValue,
    ),
  );

  ApiRequestLease<ApiResult<AgentRunSnapshot>> leaseGet(String agentRunId) =>
      _api.leaseGet<AgentRunSnapshot>(
        ApiRequestOptions<AgentRunSnapshot>(
          endpointId: 'agentRunDetail',
          pathParams: <String, Object>{'agentRunId': agentRunId},
          parseData: AgentRunSnapshot.fromValue,
        ),
      );

  Future<ApiResult<AgentRunEventPage>> events(
    String agentRunId, {
    int? afterSequence,
  }) => _api.request<AgentRunEventPage>(
    ApiRequestOptions<AgentRunEventPage>(
      endpointId: 'agentRunEvents',
      pathParams: <String, Object>{'agentRunId': agentRunId},
      query: <String, Object?>{'afterSequence': afterSequence},
      parseData: AgentRunEventPage.fromValue,
    ),
  );

  ApiRequestLease<ApiResult<AgentRunEventPage>> leaseEvents(
    String agentRunId, {
    int? afterSequence,
  }) => _api.leaseGet<AgentRunEventPage>(
    ApiRequestOptions<AgentRunEventPage>(
      endpointId: 'agentRunEvents',
      pathParams: <String, Object>{'agentRunId': agentRunId},
      query: <String, Object?>{'afterSequence': afterSequence},
      parseData: AgentRunEventPage.fromValue,
    ),
  );

  Future<ApiResult<Stream<ApiServerSentEvent<AgentRunStreamPayload>>>>
  eventStream(String agentRunId, {String? lastEventId}) =>
      _api.openEventStream<AgentRunStreamPayload>(
        ApiStreamRequestOptions<AgentRunStreamPayload>(
          endpointId: 'agentRunEventStream',
          pathParams: <String, Object>{'agentRunId': agentRunId},
          query: <String, Object?>{
            'afterSequence': int.tryParse(lastEventId ?? '') ?? 0,
          },
          headers: <String, String>{
            if (lastEventId != null) 'Last-Event-ID': lastEventId,
          },
          parseData: AgentRunStreamPayload.fromValue,
        ),
      );
}

final class SubscriptionClient {
  const SubscriptionClient(this._api);

  final ApiClient _api;

  Future<ApiResult<ApiContractPage>> publications({String? cursor}) =>
      _globalPage('subscriptionPublications', cursor: cursor);

  Future<ApiResult<SharedSubscriptionPage<SharedSubscriptionPublication>>>
  publicationPage({String? cursor, int? limit}) =>
      _subscriptionPage<SharedSubscriptionPublication>(
        endpointId: 'subscriptionPublications',
        cursor: cursor,
        limit: limit,
        parseItem: SharedSubscriptionPublication.fromJson,
      );

  Future<ApiResult<SharedSubscriptionPublication>> publication(
    String publicationId,
  ) => _api.request<SharedSubscriptionPublication>(
    ApiRequestOptions<SharedSubscriptionPublication>(
      endpointId: 'subscriptionPublicationDetail',
      pathParams: <String, Object>{'publicationId': publicationId},
      parseData: (value) =>
          parseJsonModel(value, SharedSubscriptionPublication.fromJson),
    ),
  );

  Future<ApiResult<SharedSubscriptionPage<SharedSubscriptionSection>>>
  sectionPage(String publicationId, {String? cursor, int? limit}) =>
      _subscriptionPage<SharedSubscriptionSection>(
        endpointId: 'subscriptionPublicationSections',
        pathParams: <String, Object>{'publicationId': publicationId},
        cursor: cursor,
        limit: limit,
        parseItem: SharedSubscriptionSection.fromJson,
      );

  Future<ApiResult<SharedSubscriptionPage<SharedSubscriptionArticle>>>
  articles({
    required String publicationId,
    String? sectionId,
    String? cursor,
    int? limit,
  }) => _subscriptionPage<SharedSubscriptionArticle>(
    endpointId: 'subscriptionArticles',
    query: <String, Object?>{
      'publicationId': _publicId(publicationId, 'publicationId'),
      if (sectionId != null) 'sectionId': _publicId(sectionId, 'sectionId'),
    },
    cursor: cursor,
    limit: limit,
    parseItem: SharedSubscriptionArticle.fromJson,
  );

  Future<ApiResult<SharedSubscriptionPage<SharedSubscriptionArticle>>>
  globalArticlePage({String? cursor, int? limit}) =>
      _subscriptionPage<SharedSubscriptionArticle>(
        endpointId: 'subscriptionArticles',
        cursor: cursor,
        limit: limit,
        parseItem: SharedSubscriptionArticle.fromJson,
      );

  Future<ApiResult<SharedSubscriptionArticleRevision>> article(
    String articleId,
  ) => _api.request<SharedSubscriptionArticleRevision>(
    ApiRequestOptions<SharedSubscriptionArticleRevision>(
      endpointId: 'subscriptionArticleDetail',
      pathParams: <String, Object>{'articleId': articleId},
      parseData: (value) =>
          parseJsonModel(value, SharedSubscriptionArticleRevision.fromJson),
    ),
  );

  Future<ApiResult<SharedSubscriptionPage<SharedSubscriptionArticleRevision>>>
  articleRevisionPage(String articleId, {String? cursor, int? limit}) =>
      _subscriptionPage<SharedSubscriptionArticleRevision>(
        endpointId: 'subscriptionArticleRevisions',
        pathParams: <String, Object>{'articleId': articleId},
        cursor: cursor,
        limit: limit,
        parseItem: SharedSubscriptionArticleRevision.fromJson,
      );

  Future<ApiResult<SharedSubscriptionArticleRevision>> articleRevision(
    String articleId,
    String articleRevisionId,
  ) => _api.request<SharedSubscriptionArticleRevision>(
    ApiRequestOptions<SharedSubscriptionArticleRevision>(
      endpointId: 'subscriptionArticleRevisionDetail',
      pathParams: <String, Object>{
        'articleId': articleId,
        'articleRevisionId': articleRevisionId,
      },
      parseData: (value) =>
          parseJsonModel(value, SharedSubscriptionArticleRevision.fromJson),
    ),
  );

  Future<ApiResult<Uint8List>> articleRevisionAsset(
    String articleId,
    String articleRevisionId,
    String fileKey,
  ) => _api.request<Uint8List>(
    ApiRequestOptions<Uint8List>(
      endpointId: 'subscriptionArticleRevisionAsset',
      pathParams: <String, Object>{
        'articleId': _publicId(articleId, 'articleId'),
        'articleRevisionId': _publicId(articleRevisionId, 'articleRevisionId'),
        'fileKey': _publicId(fileKey, 'fileKey'),
      },
      parseData: (value) => value is Uint8List ? value : null,
    ),
  );

  Future<ApiResult<Uint8List>> savedNoteAsset(
    String workspaceId,
    String noteId, {
    required String logicalPath,
  }) => _api.request<Uint8List>(
    ApiRequestOptions<Uint8List>(
      endpointId: 'subscriptionNoteAsset',
      pathParams: <String, Object>{
        'workspaceId': _catalogId(workspaceId, 'workspaceId'),
        'noteId': _catalogId(noteId, 'noteId'),
      },
      query: <String, Object?>{'logicalPath': logicalPath},
      parseData: (value) => value is Uint8List ? value : null,
    ),
  );

  Future<ApiResult<ApiContractPage>> library(
    String workspaceId, {
    String? cursor,
  }) => _api.request<ApiContractPage>(
    ApiRequestOptions<ApiContractPage>(
      endpointId: 'subscriptionLibrary',
      pathParams: <String, Object>{'workspaceId': workspaceId},
      query: <String, Object?>{'cursor': cursor},
      parseData: ApiContractPage.fromValue,
    ),
  );

  Future<
    ApiResult<SharedSubscriptionPage<SharedSubscriptionLibraryPublication>>
  >
  libraryPage(String workspaceId, {String? cursor, int? limit}) =>
      _subscriptionPage<SharedSubscriptionLibraryPublication>(
        endpointId: 'subscriptionLibrary',
        pathParams: <String, Object>{'workspaceId': workspaceId},
        cursor: cursor,
        limit: limit,
        parseItem: SharedSubscriptionLibraryPublication.fromJson,
      );

  Future<ApiResult<SharedSubscriptionFollowResult>> followPublication(
    String workspaceId,
    String publicationId, {
    required String idempotencyKey,
  }) => _followMutation(
    endpointId: 'followSubscriptionPublication',
    workspaceId: workspaceId,
    publicationId: publicationId,
    idempotencyKey: idempotencyKey,
  );

  Future<ApiResult<SharedSubscriptionFollowResult>> unfollowPublication(
    String workspaceId,
    String publicationId, {
    required String idempotencyKey,
  }) => _followMutation(
    endpointId: 'unfollowSubscriptionPublication',
    workspaceId: workspaceId,
    publicationId: publicationId,
    idempotencyKey: idempotencyKey,
  );

  Future<ApiResult<SharedSubscriptionSaveReceipt>> saveArticleAsNote(
    String workspaceId,
    String articleId, {
    required String articleRevisionId,
    required String idempotencyKey,
  }) => _api.request<SharedSubscriptionSaveReceipt>(
    ApiRequestOptions<SharedSubscriptionSaveReceipt>(
      endpointId: 'saveSubscriptionArticleAsNote',
      pathParams: <String, Object>{
        'workspaceId': workspaceId,
        'articleId': articleId,
      },
      body: <String, Object?>{
        'articleRevisionId': _publicId(articleRevisionId, 'articleRevisionId'),
      },
      idempotency: IdempotencyRequestContext(explicitKey: idempotencyKey),
      parseData: (value) =>
          parseJsonModel(value, SharedSubscriptionSaveReceipt.fromJson),
    ),
  );

  Future<ApiResult<SharedSubscriptionPage<T>>> _subscriptionPage<T>({
    required String endpointId,
    Map<String, Object> pathParams = const <String, Object>{},
    Map<String, Object?> query = const <String, Object?>{},
    String? cursor,
    int? limit,
    required T Function(Map<String, Object?>) parseItem,
  }) {
    final pageQuery = <String, Object?>{
      ...query,
      if (cursor != null) 'cursor': requiredClientText(cursor, 'cursor'),
      if (limit != null) 'limit': boundedPageLimit(limit),
    };
    return _api.request<SharedSubscriptionPage<T>>(
      ApiRequestOptions<SharedSubscriptionPage<T>>(
        endpointId: endpointId,
        pathParams: pathParams,
        query: pageQuery,
        parseData: (value) {
          final object = asObjectMap(value);
          return object == null
              ? null
              : SharedSubscriptionPage<T>.fromJson(object, parseItem);
        },
      ),
    );
  }

  Future<ApiResult<SharedSubscriptionFollowResult>> _followMutation({
    required String endpointId,
    required String workspaceId,
    required String publicationId,
    required String idempotencyKey,
  }) => _api.request<SharedSubscriptionFollowResult>(
    ApiRequestOptions<SharedSubscriptionFollowResult>(
      endpointId: endpointId,
      pathParams: <String, Object>{
        'workspaceId': workspaceId,
        'publicationId': publicationId,
      },
      idempotency: IdempotencyRequestContext(explicitKey: idempotencyKey),
      parseData: (value) =>
          parseJsonModel(value, SharedSubscriptionFollowResult.fromJson),
    ),
  );

  Future<ApiResult<ApiContractPage>> _globalPage(
    String endpointId, {
    String? cursor,
  }) => _api.request<ApiContractPage>(
    ApiRequestOptions<ApiContractPage>(
      endpointId: endpointId,
      query: <String, Object?>{'cursor': cursor},
      parseData: ApiContractPage.fromValue,
    ),
  );
}

final class BookWorkClient {
  const BookWorkClient(this._api);

  final ApiClient _api;

  /// Compatibility read facade. New code should use [bookDetail].
  Future<ApiResult<ApiContractObject>> book(String workspaceId) =>
      _workspaceObject('workspaceBook', workspaceId);

  Future<ApiResult<SharedBook>> bookDetail(String workspaceId) =>
      _api.request<SharedBook>(
        ApiRequestOptions<SharedBook>(
          endpointId: 'workspaceBook',
          pathParams: _workspacePath(workspaceId),
          parseData: (value) => parseJsonModel(value, SharedBook.fromJson),
        ),
      );

  Future<ApiResult<SharedWorkspaceContentEvent>> updateBook(
    String workspaceId, {
    required SharedUpdateBookRequest request,
    required String etag,
    required String idempotencyKey,
  }) => _receiptMutation(
    endpointId: 'putWorkspaceBook',
    workspaceId: workspaceId,
    objectKind: 'book',
    requireRevision: true,
    body: request.toJson(),
    etag: etag,
    idempotencyKey: idempotencyKey,
  );

  Future<ApiResult<SharedBookRevisionPage>> bookRevisions(
    String workspaceId, {
    String? cursor,
    int? limit,
  }) => _api.request<SharedBookRevisionPage>(
    ApiRequestOptions<SharedBookRevisionPage>(
      endpointId: 'workspaceBookRevisions',
      pathParams: _workspacePath(workspaceId),
      query: _pageQuery(cursor: cursor, limit: limit),
      parseData: (value) =>
          parseJsonModel(value, SharedBookRevisionPage.fromJson),
    ),
  );

  Future<ApiResult<SharedBookRevision>> bookRevision(
    String workspaceId,
    String bookRevisionId,
  ) {
    final expectedId = requiredClientText(bookRevisionId, 'bookRevisionId');
    return _api.request<SharedBookRevision>(
      ApiRequestOptions<SharedBookRevision>(
        endpointId: 'workspaceBookRevision',
        pathParams: <String, Object>{
          ..._workspacePath(workspaceId),
          'bookRevisionId': expectedId,
        },
        parseData: (value) {
          final object = asObjectMap(value);
          if (object == null) return null;
          final revision = SharedBookRevision.fromJson(object);
          if (revision.bookRevisionId != expectedId) {
            throw const FormatException(
              'Book revision response does not match requested revision',
            );
          }
          return revision;
        },
      ),
    );
  }

  Future<ApiResult<SharedBookImportPending>> importBook(
    String workspaceId, {
    required SharedImportBookRequest request,
    required String idempotencyKey,
  }) async {
    final result = await _api.request<SharedBookImportPending>(
      ApiRequestOptions<SharedBookImportPending>(
        endpointId: 'importWorkspaceBook',
        pathParams: _workspacePath(workspaceId),
        body: request.toJson(),
        idempotency: IdempotencyRequestContext(explicitKey: idempotencyKey),
        parseData: (value) {
          final object = asObjectMap(value);
          return object == null
              ? null
              : SharedBookImportPending.fromJson(object);
        },
      ),
    );
    if (result.ok && result.status != 202) {
      return _invalidApi24Result(
        result,
        const FormatException('Book import admission must return HTTP 202'),
      );
    }
    return result;
  }

  Future<ApiResult<SharedBookImport>> bookImport(
    String workspaceId,
    String bookImportId,
  ) {
    final expectedId = requiredClientText(bookImportId, 'bookImportId');
    return _api.request<SharedBookImport>(
      ApiRequestOptions<SharedBookImport>(
        endpointId: 'workspaceBookImport',
        pathParams: <String, Object>{
          ..._workspacePath(workspaceId),
          'bookImportId': expectedId,
        },
        parseData: (value) {
          final object = asObjectMap(value);
          if (object == null) return null;
          final imported = SharedBookImport.fromJson(object);
          if (imported.bookImportId != expectedId) {
            throw const FormatException(
              'Book import response does not match requested import',
            );
          }
          if (imported is SharedBookImportSucceeded &&
              imported.resultMutationReceipt.workspaceId != workspaceId) {
            throw const FormatException(
              'Book import receipt does not match requested Workspace',
            );
          }
          return imported;
        },
      ),
    );
  }

  Future<ApiResult<SharedWorkspaceContentEvent>> createBookSection(
    String workspaceId, {
    required SharedCreateBookSectionRequest request,
    required String idempotencyKey,
  }) => _receiptMutation(
    endpointId: 'workspaceBookSections',
    workspaceId: workspaceId,
    objectKind: 'book_section',
    requireRevision: false,
    body: request.toJson(),
    idempotencyKey: idempotencyKey,
  );

  Future<ApiResult<SharedBookSection>> bookSection(
    String workspaceId,
    String sectionKey,
  ) {
    final expectedKey = _clientBookSectionKey(sectionKey);
    return _api.request<SharedBookSection>(
      ApiRequestOptions<SharedBookSection>(
        endpointId: 'workspaceBookSection',
        pathParams: _bookSectionPath(workspaceId, expectedKey),
        parseData: (value) {
          final object = asObjectMap(value);
          if (object == null) return null;
          final section = SharedBookSection.fromJson(object);
          if (section.sectionKey != expectedKey) {
            throw const FormatException(
              'Book section response does not match requested section',
            );
          }
          return section;
        },
      ),
    );
  }

  Future<ApiResult<SharedWorkspaceContentEvent>> updateBookSection(
    String workspaceId,
    String sectionKey, {
    required SharedUpdateBookSectionRequest request,
    required String etag,
    required String idempotencyKey,
  }) => _bookSectionMutation(
    endpointId: 'updateWorkspaceBookSection',
    workspaceId: workspaceId,
    sectionKey: sectionKey,
    body: request.toJson(),
    etag: etag,
    idempotencyKey: idempotencyKey,
  );

  Future<ApiResult<SharedWorkspaceContentEvent>> deleteBookSection(
    String workspaceId,
    String sectionKey, {
    required String etag,
    required String idempotencyKey,
  }) => _bookSectionMutation(
    endpointId: 'deleteWorkspaceBookSection',
    workspaceId: workspaceId,
    sectionKey: sectionKey,
    etag: etag,
    idempotencyKey: idempotencyKey,
  );

  Future<ApiResult<SharedWorkspaceContentEvent>> restoreBookSection(
    String workspaceId,
    String sectionKey, {
    required String etag,
    required String idempotencyKey,
  }) => _bookSectionMutation(
    endpointId: 'restoreWorkspaceBookSection',
    workspaceId: workspaceId,
    sectionKey: sectionKey,
    etag: etag,
    idempotencyKey: idempotencyKey,
  );

  Future<ApiResult<SharedWorkspaceContentEvent>> moveBookSection(
    String workspaceId,
    String sectionKey, {
    required SharedMoveBookSectionRequest request,
    required String sectionEtag,
    required String idempotencyKey,
  }) => _bookSectionMutation(
    endpointId: 'moveWorkspaceBookSection',
    workspaceId: workspaceId,
    sectionKey: sectionKey,
    body: request.toJson(),
    etag: sectionEtag,
    idempotencyKey: idempotencyKey,
  );

  Future<ApiResult<SharedManagedPartRevision>> bookSectionPart(
    String workspaceId,
    String sectionKey,
    String part, {
    String? partRevisionId,
  }) => _readPart(
    endpointId: 'workspaceBookSectionPart',
    historyEndpointId: 'workspaceBookSectionPartRevisions',
    pathParams: <String, Object>{
      ..._bookSectionPath(workspaceId, _clientBookSectionKey(sectionKey)),
      'part': _clientBookPart(part),
    },
    expectedPart: part,
    partRevisionId: partRevisionId,
  );

  Future<ApiResult<SharedWorkspaceContentEvent>> putBookSectionPart(
    String workspaceId,
    String sectionKey,
    String part, {
    required SharedUpdateManagedPartRequest request,
    required String etag,
    required String idempotencyKey,
  }) {
    final expectedKey = _clientBookSectionKey(sectionKey);
    final expectedPart = _clientBookPart(part);
    return _receiptMutation(
      endpointId: 'putWorkspaceBookSectionPart',
      workspaceId: workspaceId,
      objectKind: 'book_section',
      requireRevision: true,
      pathParams: <String, Object>{
        'sectionKey': expectedKey,
        'part': expectedPart,
      },
      body: request.toJson(),
      etag: etag,
      idempotencyKey: idempotencyKey,
    );
  }

  Future<ApiResult<SharedManagedPartRevisionPage>> bookSectionPartRevisions(
    String workspaceId,
    String sectionKey,
    String part, {
    String? cursor,
    int? limit,
  }) => _partRevisionPage(
    endpointId: 'workspaceBookSectionPartRevisions',
    workspaceId: workspaceId,
    expectedPart: part,
    pathParams: <String, Object>{
      'sectionKey': _clientBookSectionKey(sectionKey),
      'part': _clientBookPart(part),
    },
    cursor: cursor,
    limit: limit,
  );

  Future<ApiResult<Uint8List>> exportBook(
    String workspaceId, {
    String? bookRevisionId,
  }) async {
    final result = await _api.request<Uint8List>(
      ApiRequestOptions<Uint8List>(
        endpointId: 'exportWorkspaceBook',
        pathParams: _workspacePath(workspaceId),
        query: <String, Object?>{
          if (bookRevisionId != null)
            'bookRevisionId': requiredClientText(
              bookRevisionId,
              'bookRevisionId',
            ),
        },
        parseData: (value) => value is Uint8List ? value : null,
      ),
    );
    if (!result.ok) return result;
    final contentType = _responseHeader(result.responseHeaders, 'content-type');
    final etag = _responseHeader(result.responseHeaders, 'etag');
    final packageEtag = _responseHeader(
      result.responseHeaders,
      'x-package-etag',
    );
    if (contentType?.split(';').first.trim().toLowerCase() !=
            'application/zip' ||
        etag == null ||
        etag.isEmpty ||
        packageEtag == null ||
        packageEtag != etag) {
      return _invalidApi24Result(
        result,
        const FormatException(
          'Book export requires application/zip and matching package ETags',
        ),
      );
    }
    return result;
  }

  /// Compatibility read facade. New code should use [workPage].
  Future<ApiResult<ApiContractPage>> workItems(
    String workspaceId, {
    String? cursor,
  }) => _api.request<ApiContractPage>(
    ApiRequestOptions<ApiContractPage>(
      endpointId: 'workspaceWorkItems',
      pathParams: <String, Object>{'workspaceId': workspaceId},
      query: <String, Object?>{'cursor': cursor},
      parseData: ApiContractPage.fromValue,
    ),
  );

  Future<ApiResult<SharedWorkPage>> workPage(
    String workspaceId, {
    String? cursor,
    int? limit,
  }) => _api.request<SharedWorkPage>(
    ApiRequestOptions<SharedWorkPage>(
      endpointId: 'workspaceWorkItems',
      pathParams: _workspacePath(workspaceId),
      query: _pageQuery(cursor: cursor, limit: limit),
      parseData: (value) => parseJsonModel(value, SharedWorkPage.fromJson),
    ),
  );

  Future<ApiResult<SharedWorkspaceContentEvent>> createWork(
    String workspaceId, {
    required SharedCreateWorkRequest request,
    required String idempotencyKey,
  }) => _receiptMutation(
    endpointId: 'createWorkspaceWork',
    workspaceId: workspaceId,
    objectKind: 'work',
    requireRevision: false,
    body: request.toJson(),
    idempotencyKey: idempotencyKey,
  );

  /// Compatibility read facade. New code should use [workDetail].
  Future<ApiResult<ApiContractObject>> work(
    String workspaceId,
    String workId,
  ) => _api.request<ApiContractObject>(
    ApiRequestOptions<ApiContractObject>(
      endpointId: 'workspaceWorkDetail',
      pathParams: <String, Object>{
        'workspaceId': workspaceId,
        'workId': workId,
      },
      parseData: parseApiObject,
    ),
  );

  Future<ApiResult<SharedWork>> workDetail(String workspaceId, String workId) {
    final expectedId = requiredClientText(workId, 'workId');
    return _api.request<SharedWork>(
      ApiRequestOptions<SharedWork>(
        endpointId: 'workspaceWorkDetail',
        pathParams: <String, Object>{
          ..._workspacePath(workspaceId),
          'workId': expectedId,
        },
        parseData: (value) {
          final object = asObjectMap(value);
          if (object == null) return null;
          final work = SharedWork.fromJson(object);
          if (work.workId != expectedId) {
            throw const FormatException(
              'Work response does not match requested Work',
            );
          }
          return work;
        },
      ),
    );
  }

  Future<ApiResult<SharedWorkspaceContentEvent>> updateWork(
    String workspaceId,
    String workId, {
    required SharedUpdateWorkRequest request,
    required String etag,
    required String idempotencyKey,
  }) => _workMutation(
    endpointId: 'updateWorkspaceWork',
    workspaceId: workspaceId,
    workId: workId,
    body: request.toJson(),
    etag: etag,
    idempotencyKey: idempotencyKey,
  );

  Future<ApiResult<SharedWorkspaceContentEvent>> deleteWork(
    String workspaceId,
    String workId, {
    required String etag,
    required String idempotencyKey,
  }) => _workMutation(
    endpointId: 'deleteWorkspaceWork',
    workspaceId: workspaceId,
    workId: workId,
    etag: etag,
    idempotencyKey: idempotencyKey,
  );

  Future<ApiResult<SharedWorkspaceContentEvent>> restoreWork(
    String workspaceId,
    String workId, {
    required String etag,
    required String idempotencyKey,
  }) => _workMutation(
    endpointId: 'restoreWorkspaceWork',
    workspaceId: workspaceId,
    workId: workId,
    etag: etag,
    idempotencyKey: idempotencyKey,
  );

  Future<ApiResult<SharedWorkspaceContentEvent>> completeWork(
    String workspaceId,
    String workId, {
    required String etag,
    required String idempotencyKey,
  }) => _workMutation(
    endpointId: 'completeWorkspaceWork',
    workspaceId: workspaceId,
    workId: workId,
    etag: etag,
    idempotencyKey: idempotencyKey,
  );

  Future<ApiResult<SharedManagedPartRevision>> workPart(
    String workspaceId,
    String workId,
    String part, {
    String? partRevisionId,
  }) => _readPart(
    endpointId: 'workspaceWorkPart',
    historyEndpointId: 'workspaceWorkPartRevisions',
    pathParams: <String, Object>{
      ..._workspacePath(workspaceId),
      'workId': requiredClientText(workId, 'workId'),
      'part': _clientBookPart(part),
    },
    expectedPart: part,
    partRevisionId: partRevisionId,
  );

  Future<ApiResult<SharedWorkspaceContentEvent>> putWorkPart(
    String workspaceId,
    String workId,
    String part, {
    required SharedUpdateManagedPartRequest request,
    required String etag,
    required String idempotencyKey,
  }) {
    final expectedWorkId = requiredClientText(workId, 'workId');
    final expectedPart = _clientBookPart(part);
    return _receiptMutation(
      endpointId: 'putWorkspaceWorkPart',
      workspaceId: workspaceId,
      objectKind: 'work',
      expectedObjectId: expectedWorkId,
      requireRevision: true,
      pathParams: <String, Object>{
        'workId': expectedWorkId,
        'part': expectedPart,
      },
      body: request.toJson(),
      etag: etag,
      idempotencyKey: idempotencyKey,
    );
  }

  Future<ApiResult<SharedManagedPartRevisionPage>> workPartRevisions(
    String workspaceId,
    String workId,
    String part, {
    String? cursor,
    int? limit,
  }) => _partRevisionPage(
    endpointId: 'workspaceWorkPartRevisions',
    workspaceId: workspaceId,
    expectedPart: part,
    pathParams: <String, Object>{
      'workId': requiredClientText(workId, 'workId'),
      'part': _clientBookPart(part),
    },
    cursor: cursor,
    limit: limit,
  );

  Future<ApiResult<SharedWorkspaceContentEvent>> promoteWork(
    String workspaceId,
    String workId, {
    required SharedPromoteWorkRequest request,
    required String etag,
    required String idempotencyKey,
  }) {
    final expectedWorkId = requiredClientText(workId, 'workId');
    return _api.request<SharedWorkspaceContentEvent>(
      ApiRequestOptions<SharedWorkspaceContentEvent>(
        endpointId: 'promoteWorkspaceWork',
        pathParams: <String, Object>{
          ..._workspacePath(workspaceId),
          'workId': expectedWorkId,
        },
        headers: ifMatchHeaders(etag),
        body: request.toJson(),
        idempotency: IdempotencyRequestContext(explicitKey: idempotencyKey),
        parseData: (value) => _parseApi24Receipt(
          value,
          workspaceId: workspaceId,
          objectKind: request.target == 'creation'
              ? 'creation'
              : 'book_section',
          requireRevision: request.target == 'creation',
        ),
      ),
    );
  }

  Future<ApiResult<ApiContractObject>> _workspaceObject(
    String endpointId,
    String workspaceId,
  ) => _api.request<ApiContractObject>(
    ApiRequestOptions<ApiContractObject>(
      endpointId: endpointId,
      pathParams: <String, Object>{'workspaceId': workspaceId},
      parseData: parseApiObject,
    ),
  );

  Future<ApiResult<SharedWorkspaceContentEvent>> _bookSectionMutation({
    required String endpointId,
    required String workspaceId,
    required String sectionKey,
    required String etag,
    required String idempotencyKey,
    Map<String, Object?>? body,
  }) {
    final expectedKey = _clientBookSectionKey(sectionKey);
    return _receiptMutation(
      endpointId: endpointId,
      workspaceId: workspaceId,
      objectKind: 'book_section',
      requireRevision: false,
      pathParams: <String, Object>{'sectionKey': expectedKey},
      body: body,
      etag: etag,
      idempotencyKey: idempotencyKey,
    );
  }

  Future<ApiResult<SharedWorkspaceContentEvent>> _workMutation({
    required String endpointId,
    required String workspaceId,
    required String workId,
    required String etag,
    required String idempotencyKey,
    Map<String, Object?>? body,
  }) {
    final expectedWorkId = requiredClientText(workId, 'workId');
    return _receiptMutation(
      endpointId: endpointId,
      workspaceId: workspaceId,
      objectKind: 'work',
      expectedObjectId: expectedWorkId,
      requireRevision: false,
      pathParams: <String, Object>{'workId': expectedWorkId},
      body: body,
      etag: etag,
      idempotencyKey: idempotencyKey,
    );
  }

  Future<ApiResult<SharedWorkspaceContentEvent>> _receiptMutation({
    required String endpointId,
    required String workspaceId,
    required String objectKind,
    required bool requireRevision,
    String? expectedObjectId,
    Map<String, Object> pathParams = const <String, Object>{},
    Map<String, Object?>? body,
    String? etag,
    required String idempotencyKey,
  }) => _api.request<SharedWorkspaceContentEvent>(
    ApiRequestOptions<SharedWorkspaceContentEvent>(
      endpointId: endpointId,
      pathParams: <String, Object>{
        ..._workspacePath(workspaceId),
        ...pathParams,
      },
      headers: etag == null ? const <String, String>{} : ifMatchHeaders(etag),
      body: body,
      idempotency: IdempotencyRequestContext(explicitKey: idempotencyKey),
      parseData: (value) => _parseApi24Receipt(
        value,
        workspaceId: workspaceId,
        objectKind: objectKind,
        expectedObjectId: expectedObjectId,
        requireRevision: requireRevision,
      ),
    ),
  );

  Future<ApiResult<SharedManagedPartRevision>> _readPart({
    required String endpointId,
    required String historyEndpointId,
    required Map<String, Object> pathParams,
    required String expectedPart,
    String? partRevisionId,
  }) async {
    final normalizedPart = _clientBookPart(expectedPart);
    final normalizedRevisionId = partRevisionId == null
        ? null
        : requiredClientText(partRevisionId, 'partRevisionId');
    final current = await _api.request<SharedManagedPartRevision>(
      ApiRequestOptions<SharedManagedPartRevision>(
        endpointId: endpointId,
        pathParams: pathParams,
        parseData: (value) {
          final object = asObjectMap(value);
          if (object == null) return null;
          final revision = SharedManagedPartRevision.fromJson(object);
          if (revision.part != normalizedPart) {
            throw const FormatException(
              'Part response does not match requested part',
            );
          }
          return revision;
        },
      ),
    );
    if (!current.ok ||
        normalizedRevisionId == null ||
        current.data?.partRevisionId == normalizedRevisionId) {
      return current;
    }
    return _api.request<SharedManagedPartRevision>(
      ApiRequestOptions<SharedManagedPartRevision>(
        endpointId: historyEndpointId,
        pathParams: pathParams,
        parseData: (value) {
          final object = asObjectMap(value);
          if (object == null) return null;
          final page = SharedManagedPartRevisionPage.fromJson(object);
          if (page.items.any((item) => item.part != normalizedPart)) {
            throw const FormatException('Part history contains another part');
          }
          for (final revision in page.items) {
            if (revision.partRevisionId == normalizedRevisionId) {
              return revision;
            }
          }
          throw const FormatException('Requested part revision is unavailable');
        },
      ),
    );
  }

  Future<ApiResult<SharedManagedPartRevisionPage>> _partRevisionPage({
    required String endpointId,
    required String workspaceId,
    required Map<String, Object> pathParams,
    required String expectedPart,
    String? cursor,
    int? limit,
  }) => _api.request<SharedManagedPartRevisionPage>(
    ApiRequestOptions<SharedManagedPartRevisionPage>(
      endpointId: endpointId,
      pathParams: <String, Object>{
        ..._workspacePath(workspaceId),
        ...pathParams,
      },
      query: _pageQuery(cursor: cursor, limit: limit),
      parseData: (value) {
        final object = asObjectMap(value);
        if (object == null) return null;
        final page = SharedManagedPartRevisionPage.fromJson(object);
        final normalizedPart = _clientBookPart(expectedPart);
        if (page.items.any((item) => item.part != normalizedPart)) {
          throw const FormatException(
            'Part revision page contains a different HNote part',
          );
        }
        return page;
      },
    ),
  );
}

Map<String, Object> _workspacePath(String workspaceId) => <String, Object>{
  'workspaceId': requiredClientText(workspaceId, 'workspaceId'),
};

Map<String, Object> _bookSectionPath(String workspaceId, String sectionKey) =>
    <String, Object>{..._workspacePath(workspaceId), 'sectionKey': sectionKey};

Map<String, Object?> _pageQuery({String? cursor, int? limit}) =>
    <String, Object?>{
      if (cursor != null) 'cursor': requiredClientText(cursor, 'cursor'),
      if (limit != null) 'limit': boundedPageLimit(limit),
    };

String _clientBookSectionKey(String sectionKey) {
  final value = requiredClientText(sectionKey, 'sectionKey');
  if (!RegExp(r'^[a-z][a-z0-9_-]{0,31}$').hasMatch(value)) {
    throw ArgumentError.value(
      sectionKey,
      'sectionKey',
      'Expected [a-z][a-z0-9_-]{0,31}',
    );
  }
  return value;
}

String _clientBookPart(String part) {
  final value = requiredClientText(part, 'part');
  _validateHNotePart(value);
  return value;
}

SharedWorkspaceContentEvent? _parseApi24Receipt(
  Object? value, {
  required String workspaceId,
  required String objectKind,
  String? expectedObjectId,
  required bool requireRevision,
}) {
  final object = asObjectMap(value);
  if (object == null) return null;
  final receipt = SharedWorkspaceContentEvent.fromJson(object);
  if (receipt.workspaceId != workspaceId ||
      receipt.objectKind != objectKind ||
      (expectedObjectId != null && receipt.objectId != expectedObjectId)) {
    throw const FormatException(
      'Content receipt does not match the requested API 24 owner',
    );
  }
  if ((requireRevision &&
          (receipt.revisionId == null || receipt.version != null)) ||
      (!requireRevision &&
          (receipt.version == null || receipt.revisionId != null))) {
    throw const FormatException(
      'Content receipt uses the wrong API 24 identity family',
    );
  }
  return receipt;
}

SharedHNote? _parseWorkspaceHNoteMutation(
  Object? value, {
  required String workspaceId,
  String? expectedNoteId,
}) {
  final object = asObjectMap(value);
  if (object == null) return null;
  final note = SharedHNote.fromJson(object);
  if (note.workspaceId != workspaceId ||
      (expectedNoteId != null && note.noteId != expectedNoteId)) {
    throw const FormatException(
      'HNote mutation response does not match the requested Workspace owner',
    );
  }
  return note;
}

SharedWorkspaceContentEvent? _parseHNoteTombstoneEvent(
  Object? value, {
  required String workspaceId,
  required String noteId,
}) {
  final object = asObjectMap(value);
  if (object == null) return null;
  final event = SharedWorkspaceContentEvent.fromJson(object);
  if (event.workspaceId != workspaceId ||
      event.objectKind != 'hnote' ||
      event.objectId != noteId ||
      event.changeType != 'tombstoned' ||
      !event.tombstone ||
      event.revisionId == null ||
      event.revisionId!.trim().isEmpty) {
    throw const FormatException(
      'HNote tombstone response does not match the requested mutation',
    );
  }
  return event;
}

String? _responseHeader(Map<String, String> headers, String name) {
  final expected = name.toLowerCase();
  for (final entry in headers.entries) {
    if (entry.key.toLowerCase() == expected) return entry.value.trim();
  }
  return null;
}

ApiResult<T> _invalidApi24Result<T>(
  ApiResult<T> result,
  FormatException cause,
) => ApiResult<T>.failure(
  error: AppFailure(
    code: 'API_RESPONSE_INVALID',
    category: AppFailureCategory.api,
    message: 'API response does not match the documented contract',
    userMessageKey: 'error.api.responseInvalid',
    recoveryActions: const <String>['none'],
    metadata: const <String, Object?>{'authority': 'Docs 97e510c8 API 24'},
    cause: cause,
  ),
  status: result.status,
  traceId: result.traceId,
  idempotencyStore: result.idempotencyStore,
  responseHeaders: result.responseHeaders,
);

void _validateContentCursorArgument(String value, String name) {
  if (!RegExp(r'^[0-9]+$').hasMatch(value)) {
    throw ArgumentError.value(value, name, 'Expected a decimal-string cursor');
  }
}

void _validateHNotePart(String part) {
  if (!const <String>{'raw', 'outline', 'germination'}.contains(part)) {
    throw ArgumentError.value(part, 'part', 'Unsupported HNote part');
  }
}

Map<String, Object?> _validateHNoteParts(Map<String, String> parts) {
  if (parts.isEmpty) {
    throw ArgumentError.value(parts, 'parts', 'Parts must not be empty');
  }
  final result = <String, Object?>{};
  for (final entry in parts.entries) {
    _validateHNotePart(entry.key);
    result[entry.key] = entry.value;
  }
  return Map<String, Object?>.unmodifiable(result);
}

List<SharedHNoteBatchMoveInput> _validatedBatchMoveNotes(
  Iterable<SharedHNoteBatchMoveInput> notes,
) {
  final result = <SharedHNoteBatchMoveInput>[];
  final noteIds = <String>{};
  for (final item in notes) {
    final noteId = requiredClientText(item.noteId, 'notes.noteId');
    final etag = requiredClientText(item.etag, 'notes.etag');
    if (!noteIds.add(noteId)) {
      throw ArgumentError.value(notes, 'notes', 'Note IDs must be unique');
    }
    result.add(SharedHNoteBatchMoveInput(noteId: noteId, etag: etag));
  }
  if (result.isEmpty || result.length > 200) {
    throw ArgumentError.value(notes, 'notes', 'Expected one to 200 Notes');
  }
  return List<SharedHNoteBatchMoveInput>.unmodifiable(result);
}

List<T> _parseCatalogItems<T>(Object? value, T Function(Object?) parser) {
  final object = asObjectMap(value);
  final items = object?['items'];
  if (items is! List) throw const FormatException('items must be a list');
  return List<T>.unmodifiable(items.map(parser));
}

String _publicId(String value, String name) {
  final normalized = value.trim();
  if (normalized.isEmpty ||
      !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]*$').hasMatch(normalized)) {
    throw ArgumentError.value(value, name, 'Invalid public identifier');
  }
  return normalized;
}

String _catalogId(String value, String name) {
  final normalized = value.trim();
  if (normalized.isEmpty) {
    throw ArgumentError.value(value, name, 'Catalog ID must not be empty');
  }
  return normalized;
}

String? _optionalSafeResourceId(Map<String, Object?> fields, String name) {
  final value = fields[name];
  if (value == null) return null;
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('$name must be a non-empty string when present');
  }
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.hasScheme ||
      uri.hasAuthority ||
      value.startsWith('/') ||
      value.contains('\\')) {
    throw FormatException('$name must be an opaque Resource ID');
  }
  return value;
}

List<String> _normalizedCatalogIds(Iterable<String> values, String name) {
  final normalized =
      values.map((value) => _catalogId(value, name)).toSet().toList()..sort();
  return List<String>.unmodifiable(normalized);
}

void _requireAllowed(String value, Set<String> allowed, String name) {
  if (!allowed.contains(value)) {
    throw FormatException('Unsupported $name: $value');
  }
}

Map<String, Object?> _parseAgentRunToolInputSummary(
  Object? value,
  String toolName,
) {
  if (value == null) return const <String, Object?>{};
  final object = ApiContractObject.fromValue(value);
  final toolFields =
      _agentRunToolInputSummaryFields[toolName] ?? const <String>{};
  final allowed = <String>{...toolFields, 'redactedFields', 'truncatedFields'};
  _requireOnlyFields(object.fields, allowed, 'AgentRunToolTrace.inputSummary');
  final result = <String, Object?>{};
  for (final entry in object.fields.entries) {
    final field = entry.key;
    final fieldValue = entry.value;
    if (_agentRunToolInputSummaryNumberFields.contains(field)) {
      if (fieldValue is! int || fieldValue < 0) {
        throw FormatException(
          'AgentRunToolTrace.inputSummary.$field must be a non-negative integer',
        );
      }
      result[field] = fieldValue;
      continue;
    }
    if (_agentRunToolInputSummaryListFields.contains(field)) {
      if (fieldValue is! List ||
          fieldValue.length > 32 ||
          fieldValue.any((item) => item is! String || item.trim().isEmpty)) {
        throw FormatException(
          'AgentRunToolTrace.inputSummary.$field must be a bounded string list',
        );
      }
      final items = fieldValue.cast<String>();
      if (field == 'keywords') {
        if (items.any((item) => item.length > 512)) {
          throw const FormatException(
            'AgentRunToolTrace.inputSummary.keywords contains oversized text',
          );
        }
      } else if (items.any((item) => !toolFields.contains(item))) {
        throw FormatException(
          'AgentRunToolTrace.inputSummary.$field names an unsupported field',
        );
      }
      result[field] = List<String>.unmodifiable(items);
      continue;
    }
    final maxLength = _agentRunToolInputSummaryPathFields.contains(field)
        ? 4096
        : 512;
    if (fieldValue is! String ||
        fieldValue.trim().isEmpty ||
        fieldValue.length > maxLength) {
      throw FormatException(
        'AgentRunToolTrace.inputSummary.$field must be bounded public text',
      );
    }
    result[field] = fieldValue;
  }
  return Map<String, Object?>.unmodifiable(result);
}

int _requiredNonNegativeInt(Map<String, Object?> fields, String name) {
  final value = fields[name];
  if (value is! int || value < 0) {
    throw FormatException('$name must be a non-negative integer');
  }
  return value;
}

int? _nullableInt(Map<String, Object?> fields, String name) {
  final value = fields[name];
  if (value == null) return null;
  if (value is! int || value < 0) {
    throw FormatException('$name must be a non-negative integer when present');
  }
  return value;
}

int? _requiredNullableInt(Map<String, Object?> fields, String name) {
  if (!fields.containsKey(name)) {
    throw FormatException('$name is required');
  }
  return _nullableInt(fields, name);
}

num? _requiredNullableNumber(Map<String, Object?> fields, String name) {
  if (!fields.containsKey(name)) {
    throw FormatException('$name is required');
  }
  final value = fields[name];
  if (value == null) return null;
  if (value is! num || !value.isFinite || value < 0) {
    throw FormatException(
      '$name must be a finite non-negative number when present',
    );
  }
  return value;
}

bool _requiredBool(Map<String, Object?> fields, String name) {
  final value = fields[name];
  if (value is! bool) throw FormatException('$name must be a boolean');
  return value;
}

bool? _optionalBool(Map<String, Object?> fields, String name) {
  if (!fields.containsKey(name) || fields[name] == null) return null;
  return _requiredBool(fields, name);
}

void _requireOnlyFields(
  Map<String, Object?> fields,
  Set<String> allowed,
  String name,
) {
  final unknown = fields.keys
      .where((key) => !allowed.contains(key))
      .toList(growable: false);
  if (unknown.isNotEmpty) {
    throw FormatException('$name contains unsupported fields: $unknown');
  }
}

String? _nullableString(Map<String, Object?> fields, String name) {
  final value = fields[name];
  if (value == null) return null;
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('$name must be a non-empty string when present');
  }
  return value;
}

String? _requiredNullableString(Map<String, Object?> fields, String name) {
  if (!fields.containsKey(name)) {
    throw FormatException('$name is required');
  }
  return _nullableString(fields, name);
}

DateTime _requiredDateTime(Map<String, Object?> fields, String name) {
  final value = _nullableString(fields, name);
  if (value == null) throw FormatException('$name is required');
  return DateTime.parse(value);
}

DateTime? _optionalDateTime(Map<String, Object?> fields, String name) {
  final value = _nullableString(fields, name);
  return value == null ? null : DateTime.parse(value);
}
