import '../domain/assistant_runtime.dart';

/// Owns cancellable reads of one assistant run without exposing transport
/// details to the page-facing controller.
final class ChatAssistantRunReader {
  ChatAssistantRunReader(this._runtime);

  final AssistantRuntimePort? _runtime;
  final Set<AssistantRuntimeReadLease<AssistantRunSnapshot>> _activeLeases =
      <AssistantRuntimeReadLease<AssistantRunSnapshot>>{};

  bool get isAvailable => _runtime != null;

  Future<AssistantRuntimeRead<AssistantRunSnapshot>> read(String runId) async {
    final runtime = _runtime;
    if (runtime == null) {
      return const AssistantRuntimeRead.failure(
        'CHAT_AGENT_RUN_STATUS_UNAVAILABLE',
      );
    }
    if (runtime is AssistantRuntimeReadLeasePort) {
      final leasePort = runtime as AssistantRuntimeReadLeasePort;
      final lease = leasePort.leaseReadRun(handle: AssistantRunHandle(runId));
      _activeLeases.add(lease);
      try {
        return await lease.result;
      } finally {
        _activeLeases.remove(lease);
      }
    }
    return runtime.readRun(handle: AssistantRunHandle(runId));
  }

  void cancelActiveReads() {
    final leases = _activeLeases.toList(growable: false);
    _activeLeases.clear();
    for (final lease in leases) {
      try {
        lease.cancel();
      } catch (_) {
        // Route teardown must not depend on adapter cancellation quality.
      }
    }
  }
}
