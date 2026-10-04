import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/features/chat/application/chat_assistant_run_reader.dart';
import 'package:huahuoai_app/features/chat/domain/assistant_runtime.dart';

void main() {
  test(
    'completed reads release leases and preserve failure semantics',
    () async {
      final runtime = _LeasedRuntime();
      final reader = ChatAssistantRunReader(runtime);
      final result = reader.read('completed');
      const failure = AssistantRuntimeRead<AssistantRunSnapshot>.failure(
        'UNKNOWN_OUTCOME',
        outcomeUnknown: true,
      );
      runtime.pending['completed']!.complete(failure);
      expect(await result, same(failure));
      reader.cancelActiveReads();
      expect(runtime.cancelled, isEmpty);
    },
  );

  test('all pending leases cancel once even when one adapter throws', () async {
    final runtime = _LeasedRuntime()..throwOnCancel = 'first';
    final reader = ChatAssistantRunReader(runtime);
    final first = reader.read('first');
    final second = reader.read('second');
    reader.cancelActiveReads();
    reader.cancelActiveReads();
    expect(runtime.cancelled, ['first', 'second']);
    final next = reader.read('next');
    // Late completion of the old reads must not release the new lease.
    runtime.pending['first']!.complete(_cancelled);
    runtime.pending['second']!.complete(_cancelled);
    await Future.wait([first, second]);
    reader.cancelActiveReads();
    expect(runtime.cancelled, ['first', 'second', 'next']);
    runtime.pending['next']!.complete(_cancelled);
    await next;
  });

  test('failed futures release leases without swallowing the error', () async {
    final runtime = _LeasedRuntime();
    final reader = ChatAssistantRunReader(runtime);
    final read = reader.read('failed');
    final expected = expectLater(read, throwsStateError);
    runtime.pending['failed']!.completeError(StateError('adapter failed'));
    await expected;
    reader.cancelActiveReads();
    expect(runtime.cancelled, isEmpty);
  });

  test(
    'read-only runtime and unavailable runtime preserve their results',
    () async {
      final unavailable = ChatAssistantRunReader(null);
      expect(unavailable.isAvailable, isFalse);
      expect(
        (await unavailable.read('run')).errorCode,
        'CHAT_AGENT_RUN_STATUS_UNAVAILABLE',
      );
      final runtime = _ReadOnlyRuntime();
      final reader = ChatAssistantRunReader(runtime);
      expect(reader.isAvailable, isTrue);
      expect(await reader.read('run'), same(_cancelled));
      reader.cancelActiveReads();
      expect(runtime.handle?.value, 'run');
    },
  );
}

const _cancelled = AssistantRuntimeRead<AssistantRunSnapshot>.failure(
  'CANCELLED',
);

class _ReadOnlyRuntime implements AssistantRuntimePort {
  AssistantRunHandle? handle;

  @override
  Future<AssistantRuntimeRead<AssistantRunSnapshot>> readRun({
    required AssistantRunHandle handle,
  }) async {
    this.handle = handle;
    return _cancelled;
  }
}

class _LeasedRuntime
    implements AssistantRuntimePort, AssistantRuntimeReadLeasePort {
  final pending =
      <String, Completer<AssistantRuntimeRead<AssistantRunSnapshot>>>{};
  final cancelled = <String>[];
  String? throwOnCancel;

  @override
  Future<AssistantRuntimeRead<AssistantRunSnapshot>> readRun({
    required AssistantRunHandle handle,
  }) => throw StateError('Must use the available lease capability');

  @override
  AssistantRuntimeReadLease<AssistantRunSnapshot> leaseReadRun({
    required AssistantRunHandle handle,
  }) {
    final completer = Completer<AssistantRuntimeRead<AssistantRunSnapshot>>();
    pending[handle.value] = completer;
    return AssistantRuntimeReadLease(
      result: completer.future,
      cancel: () {
        cancelled.add(handle.value);
        if (throwOnCancel == handle.value) throw StateError('cancel failed');
      },
    );
  }
}
