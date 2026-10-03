import 'dart:async';

import 'package:huahuo_api/huahuo_api.dart';
import 'package:huahuoai_app/features/chat/domain/assistant_runtime.dart';

final class LegacyAssistantReadLease {
  const LegacyAssistantReadLease({required this.result, required this.cancel});

  final Future<ApiResult<AgentRunSnapshot>> result;
  final void Function() cancel;
}

/// Wire fixtures are confined to tests; application collaborators consume the
/// neutral runtime. Capabilities are explicit so polling-only fixtures never
/// trigger a reconnect loop and unexpected fixture errors fail the test.
abstract interface class ProjectRunFixture {
  Future<ApiResult<AgentRunSnapshot>> getRun({required String agentRunId});
}

abstract interface class ProjectRunLeaseFixture {
  LegacyAssistantReadLease leaseGetRun({required String agentRunId});
}

abstract interface class ProjectRunStreamFixture {
  Future<ApiResult<Stream<ApiServerSentEvent<AgentRunStreamPayload>>>>
  streamEvents({required String agentRunId, String? lastEventId});
}

class LegacyAssistantRuntimeAdapter implements AssistantRuntimePort {
  LegacyAssistantRuntimeAdapter(this._source);

  final ProjectRunFixture _source;

  @override
  Future<AssistantRuntimeRead<AssistantRunSnapshot>> readRun({
    required AssistantRunHandle handle,
  }) async => _mapResult(await _source.getRun(agentRunId: handle.value));

  static AssistantRuntimeRead<AssistantRunSnapshot> _mapResult(
    ApiResult<AgentRunSnapshot> result,
  ) {
    final run = result.data;
    if (!result.ok || run == null) {
      return AssistantRuntimeRead<AssistantRunSnapshot>.failure(
        result.error?.code ?? 'TEST_ASSISTANT_RUNTIME_READ_FAILED',
        outcomeUnknown:
            result.status == null ||
            result.status == 408 ||
            result.status == 429 ||
            (result.status ?? 0) >= 500 ||
            result.error?.category == AppFailureCategory.network,
      );
    }
    return AssistantRuntimeRead.success(_mapSnapshot(run));
  }

  static AssistantRunSnapshot _mapSnapshot(AgentRunSnapshot run) =>
      AssistantRunSnapshot(
        handle: AssistantRunHandle(run.agentRunId),
        workspaceId: run.workspaceId,
        conversationId: run.threadId,
        correlationId: run.taskId,
        status: _status(run.status),
        output: run.assistantMessageId == null
            ? null
            : AssistantRunOutput(
                messageId: run.assistantMessageId!,
                text: run.result?.finalAnswer ?? '',
              ),
        failure: run.error == null
            ? null
            : AssistantRunFailure(
                code: run.error!.code,
                retryable: run.error!.retryable ?? false,
              ),
        toolTrace: run.toolTrace.map(_tool).toList(growable: false),
        completionQuality: switch (run.completionMode) {
          'normal' => AssistantCompletionQuality.normal,
          'degraded' => AssistantCompletionQuality.degraded,
          'system_fallback' => AssistantCompletionQuality.fallback,
          'cancelled' => AssistantCompletionQuality.cancelled,
          _ => AssistantCompletionQuality.unknown,
        },
        createdAt: run.createdAt,
        updatedAt: run.updatedAt,
      );

  static AssistantRunStatus _status(String value) => switch (value) {
    'resolving' => AssistantRunStatus.resolving,
    'planning' => AssistantRunStatus.planning,
    'awaiting_confirmation' => AssistantRunStatus.waitingForInput,
    'queued' => AssistantRunStatus.queued,
    'running' => AssistantRunStatus.running,
    'aborting' => AssistantRunStatus.stopping,
    'succeeded' => AssistantRunStatus.succeeded,
    'failed' => AssistantRunStatus.failed,
    'timeout' => AssistantRunStatus.timedOut,
    'cancelled' => AssistantRunStatus.cancelled,
    'orphaned' => AssistantRunStatus.orphaned,
    _ => AssistantRunStatus.unknown,
  };

  static AssistantToolTrace _tool(AgentRunToolTrace trace) =>
      AssistantToolTrace(
        invocationId: trace.invocationId,
        toolName: trace.toolName,
        state: trace.state,
        outcome: trace.outcome,
        createdAt: trace.createdAt,
        completedAt: trace.completedAt,
        outputFiles: trace.outputFiles
            .map(
              (file) => AssistantOutputFile(
                resourceId: file.resourceId,
                fileName: file.fileName,
                mimeType: file.mimeType,
                sizeBytes: file.sizeBytes,
              ),
            )
            .toList(growable: false),
        inputSummary: trace.inputSummary,
      );

  static Stream<AssistantStreamEvent> _mapStream(
    Stream<ApiServerSentEvent<AgentRunStreamPayload>> source,
  ) async* {
    await for (final event in source) {
      final payload = event.data;
      final item = payload?.item;
      if (payload?.kind == AgentRunStreamPayloadKind.gap) {
        yield AssistantStreamEvent(
          kind: AssistantStreamEventKind.gap,
          resumeAfterSequence: payload?.resumeAfterSequence,
          errorCode: payload?.errorCode,
          retryable: payload?.retryable,
        );
      } else if (payload?.kind == AgentRunStreamPayloadKind.capacityError) {
        yield AssistantStreamEvent(
          kind: AssistantStreamEventKind.capacityUnavailable,
          errorCode: payload?.errorCode,
          retryable: payload?.retryable,
        );
      } else if (item != null) {
        final data = item.data;
        yield AssistantStreamEvent(
          kind: AssistantStreamEventKind.update,
          type: switch (item.eventType) {
            'draft_delta' => AssistantStreamEventType.draftDelta,
            'tool_invocation' => AssistantStreamEventType.toolInvocation,
            'status' => AssistantStreamEventType.status,
            'output' => AssistantStreamEventType.output,
            _ => AssistantStreamEventType.unknown,
          },
          status: _status(item.status),
          sequence: item.sequence,
          createdAt: item.createdAt,
          deltaText: data?.deltaText,
          replace: data?.replace == true,
          invocationId: data?.invocationId,
          toolName: data?.toolName,
          toolState: data?.state,
          outcome: data?.outcome,
          outputFiles:
              data?.outputFiles
                  .map(
                    (file) => AssistantOutputFile(
                      resourceId: file.resourceId,
                      fileName: file.fileName,
                      mimeType: file.mimeType,
                      sizeBytes: file.sizeBytes,
                    ),
                  )
                  .toList(growable: false) ??
              const <AssistantOutputFile>[],
        );
      }
    }
  }
}

mixin _LeaseCapability on LegacyAssistantRuntimeAdapter
    implements AssistantRuntimeReadLeasePort {
  @override
  AssistantRuntimeReadLease<AssistantRunSnapshot> leaseReadRun({
    required AssistantRunHandle handle,
  }) {
    final lease = (_source as ProjectRunLeaseFixture).leaseGetRun(
      agentRunId: handle.value,
    );
    return AssistantRuntimeReadLease(
      result: lease.result.then(LegacyAssistantRuntimeAdapter._mapResult),
      cancel: lease.cancel,
    );
  }
}

mixin _StreamCapability on LegacyAssistantRuntimeAdapter
    implements AssistantRuntimeStreamPort {
  @override
  Future<AssistantRuntimeRead<Stream<AssistantStreamEvent>>> streamEvents({
    required AssistantRunHandle handle,
    String? lastEventId,
  }) async {
    final result = await (_source as ProjectRunStreamFixture).streamEvents(
      agentRunId: handle.value,
      lastEventId: lastEventId,
    );
    final source = result.data;
    if (!result.ok || source == null) {
      return AssistantRuntimeRead.failure(
        result.error?.code ?? 'TEST_ASSISTANT_RUNTIME_STREAM_FAILED',
        outcomeUnknown:
            result.status == null ||
            result.status == 408 ||
            result.status == 429 ||
            (result.status ?? 0) >= 500 ||
            result.error?.category == AppFailureCategory.network,
      );
    }
    return AssistantRuntimeRead.success(
      LegacyAssistantRuntimeAdapter._mapStream(source),
    );
  }
}

final class _LeasedRuntime extends LegacyAssistantRuntimeAdapter
    with _LeaseCapability {
  _LeasedRuntime(super.source);
}

final class _StreamingRuntime extends LegacyAssistantRuntimeAdapter
    with _StreamCapability {
  _StreamingRuntime(super.source);
}

final class _LeasedStreamingRuntime extends LegacyAssistantRuntimeAdapter
    with _LeaseCapability, _StreamCapability {
  _LeasedStreamingRuntime(super.source);
}

AssistantRuntimePort legacyAssistantRuntime(ProjectRunFixture source) {
  if (source is ProjectRunLeaseFixture && source is ProjectRunStreamFixture) {
    return _LeasedStreamingRuntime(source);
  }
  if (source is ProjectRunLeaseFixture) return _LeasedRuntime(source);
  if (source is ProjectRunStreamFixture) return _StreamingRuntime(source);
  return LegacyAssistantRuntimeAdapter(source);
}

AssistantToolTrace assistantToolTraceFromLegacy(AgentRunToolTrace trace) =>
    LegacyAssistantRuntimeAdapter._tool(trace);

List<AssistantToolTrace> assistantToolTracesFromLegacy(
  Iterable<AgentRunToolTrace> traces,
) => traces.map(assistantToolTraceFromLegacy).toList(growable: false);
