import 'package:huahuo_api/huahuo_api.dart';

Map<String, Object?> runtimeInvocationPayload(
  SharedThreadRuntimeInvocation invocation,
) => <String, Object?>{
  'schemaVersion': invocation.schemaVersion,
  'threadId': invocation.threadId,
  'agentRunId': invocation.agentRunId,
  'status': invocation.status,
  if (invocation.createdAt != null)
    'createdAt': invocation.createdAt!.toUtc().toIso8601String(),
  if (invocation.completedAt != null)
    'completedAt': invocation.completedAt!.toUtc().toIso8601String(),
  'selection': <String, Object?>{
    'agentProfileId': invocation.agentProfileId,
    'modelProfileId': invocation.modelProfileId,
    'skillProfileIds': invocation.skillProfileIds,
  },
  'requestSummary': <String, Object?>{'contentTypes': invocation.contentTypes},
  'tools': <Map<String, Object?>>[
    for (final tool in invocation.tools)
      <String, Object?>{
        'toolName': tool.name,
        'status': tool.state,
        if (tool.invocationId != null) 'invocationId': tool.invocationId,
        if (tool.durationMs != null) 'durationMs': tool.durationMs,
        if (tool.createdAt != null)
          'createdAt': tool.createdAt!.toUtc().toIso8601String(),
        if (tool.inputSummary.isNotEmpty) 'inputSummary': tool.inputSummary,
        if (tool.outputSummary.isNotEmpty) 'outputSummary': tool.outputSummary,
      },
  ],
  'progress': <Map<String, Object?>>[
    for (final progress in invocation.progress)
      <String, Object?>{
        'kind': progress.kind,
        'title': progress.title,
        'status': progress.status,
        if (progress.summary != null) 'summary': progress.summary,
        'createdAt': progress.createdAt.toUtc().toIso8601String(),
      },
  ],
  'files': <Map<String, Object?>>[
    for (final file in invocation.files)
      <String, Object?>{
        'fileName': file.name,
        if (file.mimeType != null) 'mimeType': file.mimeType,
        if (file.sizeBytes != null) 'sizeBytes': file.sizeBytes,
      },
  ],
};
