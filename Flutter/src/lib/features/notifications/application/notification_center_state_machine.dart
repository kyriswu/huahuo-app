import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'notification_destination_registry.dart';
import 'pending_message_projection.dart';

enum NotificationCenterFilter { ongoing, finished }

enum NotificationCenterGroup { ongoing, finished }

enum NotificationRetention {
  sourceControlled,
  destinationOrManualArchive,
  manualArchive,
}

enum NotificationCenterOperation { idle, markingRead, opening, archiving }

typedef NotificationCenterAttention = ({bool hasProcessing, int unreadCount});

final class NotificationCenterBulkDeleteResult {
  const NotificationCenterBulkDeleteResult({
    required this.total,
    required this.succeeded,
  });

  final int total;
  final int succeeded;

  int get failed => total - succeeded;
  bool get isComplete => failed == 0;
}

final class NotificationCenterPolicy {
  const NotificationCenterPolicy({
    required this.group,
    required this.retention,
    required this.statusLabel,
    required this.badgeEligible,
    required this.readable,
    required this.archivable,
    required this.autoArchiveAfterDestination,
  });

  final NotificationCenterGroup group;
  final NotificationRetention retention;
  final String statusLabel;
  final bool badgeEligible;
  final bool readable;
  final bool archivable;
  final bool autoArchiveAfterDestination;

  bool countsTowardBadge(PendingMessage item) => badgeEligible && item.isUnread;

  bool canMarkRead(PendingMessage item) =>
      readable && item.isUnread && !item.isBusy;

  bool canArchive(PendingMessage item) =>
      archivable &&
      !item.isUnread &&
      !item.isBusy &&
      item.archiveScope != PendingMessageArchiveScope.unavailable;

  bool get shouldAutoArchiveAfterDestination => autoArchiveAfterDestination;
}

final class NotificationCenterPolicyRegistry {
  const NotificationCenterPolicyRegistry();

  static const _processing = NotificationCenterPolicy(
    group: NotificationCenterGroup.ongoing,
    retention: NotificationRetention.sourceControlled,
    statusLabel: '进行中',
    badgeEligible: false,
    readable: false,
    archivable: false,
    autoArchiveAfterDestination: false,
  );

  static const _businessActionRequired = NotificationCenterPolicy(
    group: NotificationCenterGroup.ongoing,
    retention: NotificationRetention.sourceControlled,
    statusLabel: '待处理',
    badgeEligible: true,
    readable: true,
    archivable: false,
    autoArchiveAfterDestination: false,
  );

  static const _remoteActionRequired = NotificationCenterPolicy(
    group: NotificationCenterGroup.ongoing,
    retention: NotificationRetention.manualArchive,
    statusLabel: '待处理',
    badgeEligible: true,
    readable: true,
    archivable: true,
    autoArchiveAfterDestination: false,
  );

  static const _succeededTask = NotificationCenterPolicy(
    group: NotificationCenterGroup.finished,
    retention: NotificationRetention.destinationOrManualArchive,
    statusLabel: '已完成',
    badgeEligible: true,
    readable: true,
    archivable: true,
    autoArchiveAfterDestination: true,
  );

  static const _succeededNotification = NotificationCenterPolicy(
    group: NotificationCenterGroup.finished,
    retention: NotificationRetention.manualArchive,
    statusLabel: '已完成',
    badgeEligible: true,
    readable: true,
    archivable: true,
    autoArchiveAfterDestination: false,
  );

  static const _failed = NotificationCenterPolicy(
    group: NotificationCenterGroup.finished,
    retention: NotificationRetention.manualArchive,
    statusLabel: '失败',
    badgeEligible: true,
    readable: true,
    archivable: true,
    autoArchiveAfterDestination: false,
  );

  static const _informational = NotificationCenterPolicy(
    group: NotificationCenterGroup.finished,
    retention: NotificationRetention.manualArchive,
    statusLabel: '通知',
    badgeEligible: true,
    readable: true,
    archivable: true,
    autoArchiveAfterDestination: false,
  );

  NotificationCenterPolicy classify(PendingMessage item) {
    if (item.state == PendingMessageState.actionRequired) {
      return _isBusinessOwnedAction(item)
          ? _businessActionRequired
          : _remoteActionRequired;
    }
    if (item.state == PendingMessageState.succeeded &&
        item.isTask &&
        !_hasExactTaskResultDestination(item)) {
      return _succeededNotification;
    }
    if (item.state == PendingMessageState.succeeded && !item.isTask) {
      return _succeededNotification;
    }
    return classifyState(item.state);
  }

  NotificationCenterPolicy classifyState(PendingMessageState state) =>
      switch (state) {
        PendingMessageState.processing => _processing,
        PendingMessageState.actionRequired => _businessActionRequired,
        PendingMessageState.succeeded => _succeededTask,
        PendingMessageState.failed => _failed,
        PendingMessageState.informational => _informational,
      };

  String statusLabel(PendingMessage item) => classify(item).statusLabel;

  NotificationCenterGroup group(PendingMessage item) => classify(item).group;

  NotificationRetention retention(PendingMessage item) =>
      classify(item).retention;

  bool countsTowardBadge(PendingMessage item) =>
      classify(item).countsTowardBadge(item);

  bool canMarkRead(PendingMessage item) => classify(item).canMarkRead(item);

  bool canArchive(PendingMessage item) => classify(item).canArchive(item);

  bool shouldAutoArchiveAfterDestination(PendingMessage item) =>
      classify(item).shouldAutoArchiveAfterDestination;

  bool includes(NotificationCenterFilter filter, PendingMessage item) =>
      switch (filter) {
        NotificationCenterFilter.ongoing =>
          group(item) == NotificationCenterGroup.ongoing,
        NotificationCenterFilter.finished =>
          group(item) == NotificationCenterGroup.finished,
      };

  bool admits(PendingMessage item) {
    if (item.id.trim().isEmpty ||
        item.id.length > 512 ||
        item.title.trim().isEmpty ||
        item.body.trim().isEmpty) {
      return false;
    }
    if (item.isRemote &&
        (item.remoteNotificationId?.trim().isEmpty != false ||
            item.remoteDeliveryResolutionKey?.trim().isEmpty != false)) {
      return false;
    }
    final hasSafeRoute = _isSafeInAppRoute(item.route);
    if ((!item.isRemote || item.isTask) && !hasSafeRoute) return false;
    return switch (item.state) {
      PendingMessageState.processing =>
        hasSafeRoute &&
            item.archiveScope == PendingMessageArchiveScope.unavailable,
      PendingMessageState.actionRequired =>
        hasSafeRoute || (!item.isTask && item.isRemote),
      PendingMessageState.informational => item.isRemote,
      PendingMessageState.succeeded || PendingMessageState.failed => true,
    };
  }

  List<PendingMessage> canonicalItems(Iterable<PendingMessage> items) {
    final deduplicated = <PendingMessage>[];
    final deliveryIndices = <String, int>{};
    for (final item in items) {
      if (!admits(item)) continue;
      final identity = pendingMessagePresentationIdentity(item);
      final existingIndex = deliveryIndices[identity];
      if (existingIndex == null) {
        deliveryIndices[identity] = deduplicated.length;
        deduplicated.add(item);
        continue;
      }
      deduplicated[existingIndex] = _mergeExactDelivery(
        item,
        deduplicated[existingIndex],
      );
    }

    final result = <PendingMessage>[];
    final recordingIndices = <String, int>{};
    for (final item in deduplicated) {
      final recordingKey = pendingMessageLogicalGroupKey(item);
      if (recordingKey == null) {
        result.add(item);
        continue;
      }
      final existingIndex = recordingIndices[recordingKey];
      if (existingIndex == null) {
        recordingIndices[recordingKey] = result.length;
        result.add(item);
        continue;
      }
      result[existingIndex] = _mergeRecordingRows(item, result[existingIndex]);
    }
    result.sort(_compareByEventTime);
    return List<PendingMessage>.unmodifiable(result);
  }

  List<PendingMessage> filter(
    Iterable<PendingMessage> items,
    NotificationCenterFilter filter,
  ) => List<PendingMessage>.unmodifiable(
    canonicalItems(items).where((item) => includes(filter, item)),
  );

  NotificationCenterAttention attention(Iterable<PendingMessage> items) {
    final canonical = canonicalItems(items);
    return (
      hasProcessing: canonical.any(
        (item) => item.state == PendingMessageState.processing,
      ),
      unreadCount: canonical.where(countsTowardBadge).length,
    );
  }

  int badgeCount(Iterable<PendingMessage> items) =>
      attention(items).unreadCount;

  int readDeletableCount(Iterable<PendingMessage> items) => canonicalItems(
    items,
  ).where((item) => !item.isUnread && canArchive(item)).length;

  bool _isBusinessOwnedAction(PendingMessage item) =>
      item.source == PendingMessageSource.onboarding ||
      item.source == PendingMessageSource.firstLaunchDeviceSetup;

  bool _hasExactTaskResultDestination(PendingMessage item) {
    final route = item.route;
    final targetType = item.targetType;
    final targetId = item.targetId;
    if (route == null || targetType == null || targetId == null) return false;
    return notificationDestinationRegistry.isExactResultDestination(
      location: route,
      targetType: targetType,
      targetId: targetId,
      stage: item.stage,
    );
  }

  bool _isSafeInAppRoute(String? route) {
    if (route == null) return false;
    final uri = Uri.tryParse(route);
    return uri != null &&
        !uri.hasScheme &&
        !uri.hasAuthority &&
        uri.path.startsWith('/') &&
        uri.pathSegments.isNotEmpty;
  }

  PendingMessage _mergeExactDelivery(
    PendingMessage candidate,
    PendingMessage current,
  ) {
    final chronological = _compareByEventTime(candidate, current) <= 0
        ? candidate
        : current;
    final isUnread = candidate.isUnread && current.isUnread;
    final preferred = candidate.isUnread == current.isUnread
        ? chronological
        : candidate.isUnread
        ? current
        : candidate;
    final isOpening = candidate.isOpening || current.isOpening;
    final isResolving = candidate.isResolving || current.isResolving;
    if (preferred.isUnread == isUnread &&
        preferred.isOpening == isOpening &&
        preferred.isResolving == isResolving) {
      return preferred;
    }
    return preferred.copyWith(
      isUnread: isUnread,
      isOpening: isOpening,
      isResolving: isResolving,
    );
  }

  PendingMessage _mergeRecordingRows(
    PendingMessage candidate,
    PendingMessage current,
  ) {
    final preferred = _preferRecordingRow(candidate, current)
        ? candidate
        : current;
    return _mergeAttentionFacts(preferred, candidate, current);
  }

  PendingMessage _mergeAttentionFacts(
    PendingMessage preferred,
    PendingMessage candidate,
    PendingMessage current,
  ) {
    final isUnread = candidate.isUnread || current.isUnread;
    final isOpening = candidate.isOpening || current.isOpening;
    final isResolving = candidate.isResolving || current.isResolving;
    if (preferred.isUnread == isUnread &&
        preferred.isOpening == isOpening &&
        preferred.isResolving == isResolving) {
      return preferred;
    }
    return preferred.copyWith(
      isUnread: isUnread,
      isOpening: isOpening,
      isResolving: isResolving,
    );
  }

  int _compareByEventTime(PendingMessage left, PendingMessage right) {
    final leftTime = left.createdAt?.microsecondsSinceEpoch ?? 0;
    final rightTime = right.createdAt?.microsecondsSinceEpoch ?? 0;
    final byTime = rightTime.compareTo(leftTime);
    if (byTime != 0) return byTime;
    return pendingMessagePresentationIdentity(
      left,
    ).compareTo(pendingMessagePresentationIdentity(right));
  }

  bool _preferRecordingRow(PendingMessage candidate, PendingMessage current) {
    final candidateSucceeded = candidate.state == PendingMessageState.succeeded;
    final currentSucceeded = current.state == PendingMessageState.succeeded;
    if (candidateSucceeded != currentSucceeded) return candidateSucceeded;
    final candidateTime = candidate.createdAt?.millisecondsSinceEpoch ?? 0;
    final currentTime = current.createdAt?.millisecondsSinceEpoch ?? 0;
    if (candidateTime != currentTime) return candidateTime > currentTime;
    final candidatePriority = _recordingStatePriority(candidate.state);
    final currentPriority = _recordingStatePriority(current.state);
    if (candidatePriority != currentPriority) {
      return candidatePriority > currentPriority;
    }
    if (candidate.isRemote != current.isRemote) return candidate.isRemote;
    return false;
  }

  int _recordingStatePriority(PendingMessageState state) => switch (state) {
    PendingMessageState.succeeded => 5,
    PendingMessageState.failed => 4,
    PendingMessageState.actionRequired => 3,
    PendingMessageState.processing => 2,
    PendingMessageState.informational => 1,
  };
}

// resident-provider: Keeps app-shell notification attention stable across route changes.
final notificationCenterAttentionProvider =
    Provider<NotificationCenterAttention>((ref) {
      const policies = NotificationCenterPolicyRegistry();
      return ref.watch(
        pendingMessageProjectionProvider.select(
          (projection) => policies.attention(projection.items),
        ),
      );
    });

abstract interface class NotificationCenterActionPort {
  Future<bool> markRead(PendingMessage item);

  Future<PendingMessageMarkAllReadResult> markAllRead();

  Future<bool> markOpened(PendingMessage item);

  Future<bool> markHandled(PendingMessage item);
}

final class _PendingMessageActionAdapter
    implements NotificationCenterActionPort {
  const _PendingMessageActionAdapter(this._delegate);

  final PendingMessageActions _delegate;

  @override
  Future<bool> markRead(PendingMessage item) => _delegate.markRead(item);

  @override
  Future<PendingMessageMarkAllReadResult> markAllRead() =>
      _delegate.markAllRead();

  @override
  Future<bool> markOpened(PendingMessage item) => _delegate.markOpened(item);

  @override
  Future<bool> markHandled(PendingMessage item) => _delegate.markHandled(item);
}

final notificationCenterControllerProvider =
    ChangeNotifierProvider<NotificationCenterController>((ref) {
      return NotificationCenterController(
        actions: ref.watch(pendingMessageActionsProvider),
      );
    });

final class NotificationCenterController extends ChangeNotifier {
  NotificationCenterController({
    required PendingMessageActions actions,
    NotificationCenterPolicyRegistry policies =
        const NotificationCenterPolicyRegistry(),
  }) : this._(_PendingMessageActionAdapter(actions), policies);

  @visibleForTesting
  factory NotificationCenterController.withActions({
    required NotificationCenterActionPort actions,
    NotificationCenterPolicyRegistry policies =
        const NotificationCenterPolicyRegistry(),
  }) => NotificationCenterController._(actions, policies);

  NotificationCenterController._(this._actions, this._policies);

  static const markReadFailed = 'NOTIFICATION_CENTER_MARK_READ_FAILED';
  static const markAllReadFailed = 'NOTIFICATION_CENTER_MARK_ALL_READ_FAILED';
  static const markAllReadPartial = 'NOTIFICATION_CENTER_MARK_ALL_READ_PARTIAL';
  static const deleteReadFailed = 'NOTIFICATION_CENTER_DELETE_READ_FAILED';
  static const deleteReadPartial = 'NOTIFICATION_CENTER_DELETE_READ_PARTIAL';
  static const openFailed = 'NOTIFICATION_CENTER_OPEN_FAILED';
  static const archiveFailed = 'NOTIFICATION_CENTER_ARCHIVE_FAILED';

  final NotificationCenterActionPort _actions;
  final NotificationCenterPolicyRegistry _policies;
  final Set<String> _markingReadIds = <String>{};
  final Set<String> _openingIds = <String>{};
  final Set<String> _archivingIds = <String>{};

  NotificationCenterFilter _filter = NotificationCenterFilter.ongoing;
  bool _bulkReadBusy = false;
  bool _bulkDeleteBusy = false;
  String? _lastError;
  bool _disposed = false;

  NotificationCenterFilter get filter => _filter;
  bool get bulkReadBusy => _bulkReadBusy;
  bool get bulkDeleteBusy => _bulkDeleteBusy;
  bool get hasBulkOperation => _bulkReadBusy || _bulkDeleteBusy;
  String? get lastError => _lastError;
  String? get lastErrorCode => _lastError;
  NotificationCenterPolicyRegistry get policies => _policies;
  Set<String> get markingReadIds => Set<String>.unmodifiable(_markingReadIds);
  Set<String> get openingIds => Set<String>.unmodifiable(_openingIds);
  Set<String> get archivingIds => Set<String>.unmodifiable(_archivingIds);

  List<PendingMessage> visibleItems(Iterable<PendingMessage> displayItems) =>
      List<PendingMessage>.unmodifiable(
        displayItems.where((item) => _policies.includes(_filter, item)),
      );

  int badgeCount(Iterable<PendingMessage> displayItems) =>
      displayItems.where(_policies.countsTowardBadge).length;

  int readDeletableCount(Iterable<PendingMessage> displayItems) => displayItems
      .where((item) => !item.isUnread && _policies.canArchive(item))
      .length;

  List<PendingMessage> displayItems(Iterable<PendingMessage> items) =>
      _policies.canonicalItems(items);

  NotificationCenterOperation operationFor(PendingMessage item) {
    return _operationForKey(_operationKey(item));
  }

  NotificationCenterOperation _operationForKey(String operationKey) {
    if (_markingReadIds.contains(operationKey)) {
      return NotificationCenterOperation.markingRead;
    }
    if (_openingIds.contains(operationKey)) {
      return NotificationCenterOperation.opening;
    }
    if (_archivingIds.contains(operationKey)) {
      return NotificationCenterOperation.archiving;
    }
    return NotificationCenterOperation.idle;
  }

  bool isBusy(PendingMessage item) =>
      hasBulkOperation ||
      operationFor(item) != NotificationCenterOperation.idle;

  bool get hasItemOperation => _hasItemOperation;

  void setFilter(NotificationCenterFilter value) {
    if (_filter == value) return;
    _filter = value;
    _notify();
  }

  void clearError() {
    if (_lastError == null) return;
    _lastError = null;
    _notify();
  }

  Future<bool> markRead(PendingMessage item) {
    if (!_policies.canMarkRead(item)) return Future<bool>.value(false);
    return _runItemOperation(
      item: item,
      operation: NotificationCenterOperation.markingRead,
      failureCode: markReadFailed,
      action: () => _actions.markRead(item),
    );
  }

  Future<PendingMessageMarkAllReadResult?> markAllRead() async {
    if (hasBulkOperation || _hasItemOperation) return null;
    _bulkReadBusy = true;
    _lastError = null;
    _notify();
    try {
      final result = await _actions.markAllRead();
      if (result.failed > 0) _lastError = markAllReadPartial;
      return result;
    } catch (_) {
      _lastError = markAllReadFailed;
      return null;
    } finally {
      _bulkReadBusy = false;
      _notify();
    }
  }

  Future<NotificationCenterBulkDeleteResult?> deleteRead(
    Iterable<PendingMessage> items,
  ) async {
    if (hasBulkOperation || _hasItemOperation) return null;
    final candidates = _policies
        .canonicalItems(items)
        .where((item) => !item.isUnread && _policies.canArchive(item))
        .toList(growable: false);
    if (candidates.isEmpty) {
      return const NotificationCenterBulkDeleteResult(total: 0, succeeded: 0);
    }
    _bulkDeleteBusy = true;
    _lastError = null;
    _notify();
    var succeeded = 0;
    try {
      for (final item in candidates) {
        try {
          if (await _actions.markHandled(item)) succeeded += 1;
        } catch (_) {
          // Continue so one failed local receipt cannot block unrelated rows.
        }
      }
      final result = NotificationCenterBulkDeleteResult(
        total: candidates.length,
        succeeded: succeeded,
      );
      if (!result.isComplete) _lastError = deleteReadPartial;
      return result;
    } catch (_) {
      _lastError = deleteReadFailed;
      return null;
    } finally {
      _bulkDeleteBusy = false;
      _notify();
    }
  }

  Future<bool> markOpened(PendingMessage item) => _runItemOperation(
    item: item,
    operation: NotificationCenterOperation.opening,
    failureCode: openFailed,
    action: () => _actions.markOpened(item),
  );

  Future<bool> archive(PendingMessage item) {
    if (!_policies.canArchive(item)) return Future<bool>.value(false);
    return _markHandled(item);
  }

  Future<bool> archiveAfterDestinationVisible(PendingMessage item) {
    if (!_policies.shouldAutoArchiveAfterDestination(item)) {
      return Future<bool>.value(false);
    }
    return _markHandled(item);
  }

  Future<bool> markHandled(PendingMessage item) {
    final policy = _policies.classify(item);
    if (!policy.canArchive(item) && !policy.shouldAutoArchiveAfterDestination) {
      return Future<bool>.value(false);
    }
    return _markHandled(item);
  }

  Future<bool> _markHandled(PendingMessage item) => _runItemOperation(
    item: item,
    operation: NotificationCenterOperation.archiving,
    failureCode: archiveFailed,
    action: () => _actions.markHandled(item),
  );

  Future<bool> _runItemOperation({
    required PendingMessage item,
    required NotificationCenterOperation operation,
    required String failureCode,
    required Future<bool> Function() action,
  }) async {
    final operations = _operationsFor(operation);
    final operationKey = _operationKey(item);
    if (hasBulkOperation ||
        _operationForKey(operationKey) != NotificationCenterOperation.idle) {
      return false;
    }
    operations.add(operationKey);
    _lastError = null;
    _notify();
    try {
      final succeeded = await action();
      if (!succeeded) _lastError = failureCode;
      return succeeded;
    } catch (_) {
      _lastError = failureCode;
      return false;
    } finally {
      operations.remove(operationKey);
      _notify();
    }
  }

  String _operationKey(PendingMessage item) =>
      pendingMessagePresentationIdentity(item);

  Set<String> _operationsFor(NotificationCenterOperation operation) =>
      switch (operation) {
        NotificationCenterOperation.markingRead => _markingReadIds,
        NotificationCenterOperation.opening => _openingIds,
        NotificationCenterOperation.archiving => _archivingIds,
        NotificationCenterOperation.idle => throw ArgumentError.value(
          operation,
          'operation',
          'Idle is not an executable operation.',
        ),
      };

  bool get _hasItemOperation =>
      _markingReadIds.isNotEmpty ||
      _openingIds.isNotEmpty ||
      _archivingIds.isNotEmpty;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
