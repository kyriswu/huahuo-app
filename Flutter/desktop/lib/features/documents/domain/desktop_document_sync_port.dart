import 'package:huahuo_editor/huahuo_editor.dart';

import '../../../shared/services/desktop_service_result.dart';

enum DesktopDocumentSyncPhase { synced, queued, waitingForService, conflict }

final class DesktopDocumentSyncState {
  const DesktopDocumentSyncState({
    required this.phase,
    required this.pendingCount,
    this.serverRevision,
  });

  final DesktopDocumentSyncPhase phase;
  final int pendingCount;
  final String? serverRevision;
}

final class DesktopDocumentPullBatch {
  const DesktopDocumentPullBatch({
    required this.documents,
    required this.deletedDocumentIds,
    required this.contentCursor,
    required this.rebuiltFromSnapshot,
    required this.protectedPendingCount,
  });

  final List<HuahuoDocumentSnapshot> documents;
  final Set<String> deletedDocumentIds;
  final String contentCursor;
  final bool rebuiltFromSnapshot;
  final int protectedPendingCount;
}

typedef DesktopDocumentPullApplier =
    Future<void> Function(DesktopDocumentPullBatch batch);

final class DesktopDocumentRemoteReference {
  const DesktopDocumentRemoteReference({
    required this.noteId,
    required this.part,
    required this.partRevisionId,
    required this.localRevision,
  });

  final String noteId;
  final String part;
  final String partRevisionId;
  final int localRevision;
}

abstract interface class DesktopDocumentSyncPort {
  Future<void> bindAccount({
    required String userId,
    required String workspaceId,
  });

  Future<void> clearAccount();

  Future<DesktopDocumentRemoteReference?> remoteReferenceFor({
    required String localDocumentId,
    String part = 'raw',
  });

  Future<DesktopServiceResult<DesktopDocumentPullBatch>> pullRemote({
    required DesktopDocumentPullApplier apply,
  });

  Future<DesktopServiceResult<DesktopDocumentSyncState>> enqueue(
    HuahuoDocumentSnapshot snapshot,
  );

  Future<DesktopServiceResult<DesktopDocumentSyncState>> retryPending();
}
