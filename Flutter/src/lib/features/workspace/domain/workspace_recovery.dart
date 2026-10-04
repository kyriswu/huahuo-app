final class WorkspaceRetryAck {
  const WorkspaceRetryAck({
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
