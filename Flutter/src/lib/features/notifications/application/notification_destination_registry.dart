import '../../chat/domain/chat_models.dart';
import '../domain/notification_models.dart';
import '../domain/push_message.dart';

enum NotificationDestinationKind {
  recording,
  recordingBatch,
  thread,
  note,
  asset,
  task,
  hotspotSuggestion,
  topicRecommendation,
  graph,
  onboarding,
  positioningProgress,
  positioningReport,
  deviceSetup,
}

enum NotificationDestinationStage {
  raw(routeValue: null, receiptValue: 'raw'),
  outline(routeValue: 'summary', receiptValue: 'outline'),
  sprout(routeValue: 'sprout', receiptValue: 'sprout'),
  report(routeValue: 'report', receiptValue: 'report');

  const NotificationDestinationStage({
    required this.routeValue,
    required this.receiptValue,
  });

  final String? routeValue;
  final String? receiptValue;
}

enum NotificationDestinationPurpose {
  general('general'),
  deepPositioning('deep-positioning');

  const NotificationDestinationPurpose(this.routeValue);

  final String routeValue;
}

final class NotificationDestination {
  const NotificationDestination({
    required this.kind,
    required this.uri,
    required this.targetType,
    this.targetId,
    this.stage,
    this.purpose,
    this.focusItemId,
  });

  final NotificationDestinationKind kind;
  final Uri uri;
  final String targetType;
  final String? targetId;
  final NotificationDestinationStage? stage;
  final NotificationDestinationPurpose? purpose;
  final String? focusItemId;

  String get location => uri.toString();
}

final class NotificationDestinationReceipt {
  const NotificationDestinationReceipt({
    required this.kind,
    required this.committedUri,
    required this.targetType,
    this.targetId,
    this.stage,
    this.purpose,
    this.focusItemId,
  });

  final NotificationDestinationKind kind;
  final Uri committedUri;
  final String targetType;
  final String? targetId;
  final NotificationDestinationStage? stage;
  final NotificationDestinationPurpose? purpose;
  final String? focusItemId;

  String? get stageValue => stage?.receiptValue;
}

const notificationDestinationRegistry = NotificationDestinationRegistry();

final class NotificationDestinationRegistry {
  const NotificationDestinationRegistry();

  bool isExactResultDestination({
    required String location,
    required String targetType,
    required String targetId,
    String? stage,
  }) {
    final uri = Uri.tryParse(location);
    if (uri == null) return false;
    final receipt = receiptForCommittedUri(uri);
    if (receipt == null ||
        receipt.targetType != targetType ||
        receipt.targetId != targetId) {
      return false;
    }
    if (stage == null) return true;
    if (targetType == 'recording' && stage == 'recording_processing') {
      return true;
    }
    return receipt.stageValue == stage;
  }

  NotificationDestination? forNotification(AppNotification notification) {
    return resolve(
      scene: notification.scene,
      eventType: notification.eventType,
      targetType: notification.targetType,
      targetId: notification.targetId,
    );
  }

  NotificationDestination? forPush(PushMessage message) {
    return resolve(
      scene: message.scene,
      eventType: message.eventType,
      targetType: message.targetType,
      targetId: message.targetId,
    );
  }

  NotificationDestination? forRecordingBatch(
    String batchId, {
    String? focusItemId,
  }) {
    final normalizedBatchId = batchId.trim();
    final normalizedFocus = focusItemId?.trim();
    if (!isSafeNotificationOpaqueIdentifier(normalizedBatchId) ||
        (normalizedFocus != null &&
            normalizedFocus.isNotEmpty &&
            !isSafeNotificationOpaqueIdentifier(normalizedFocus))) {
      return null;
    }
    final focus = normalizedFocus == null || normalizedFocus.isEmpty
        ? null
        : normalizedFocus;
    return NotificationDestination(
      kind: NotificationDestinationKind.recordingBatch,
      uri: _identifierPath(
        '/v3/feed/transcription-batches',
        normalizedBatchId,
        queryParameters: focus == null
            ? null
            : <String, String>{'focusItem': focus},
      ),
      targetType: 'recording_batch',
      targetId: normalizedBatchId,
      focusItemId: focus,
    );
  }

  /// Resolves a Recording Push against the retained local batch index. The
  /// caller supplies that account-scoped lookup result; absent active batch
  /// evidence the established single-recording route remains authoritative.
  NotificationDestination? forRecordingWithBatchContext({
    required String recordingId,
    String? activeBatchId,
    String? focusItemId,
  }) {
    final batchId = activeBatchId?.trim();
    if (batchId != null && batchId.isNotEmpty) {
      return forRecordingBatch(batchId, focusItemId: focusItemId);
    }
    return resolve(
      scene: 'recording',
      eventType: 'recording.deposit.succeeded',
      targetType: 'recording',
      targetId: recordingId,
    );
  }

  NotificationDestination? resolve({
    required String scene,
    required String eventType,
    required String targetType,
    required String targetId,
  }) {
    final normalizedScene = _safeSignal(scene);
    final normalizedEventType = _safeSignal(eventType);
    final normalizedTargetType = _safeSignal(targetType);
    final normalizedTargetId = targetId.trim();
    if (normalizedScene == null ||
        normalizedEventType == null ||
        normalizedTargetType == null ||
        !_isSafeTargetId(normalizedTargetType, normalizedTargetId)) {
      return null;
    }

    final signal = '$normalizedScene.$normalizedEventType'.replaceAll('-', '_');
    return switch (normalizedTargetType) {
      'recording' => NotificationDestination(
        kind: NotificationDestinationKind.recording,
        uri: _identifierPath(
          '/v3/feed/transcription-done',
          normalizedTargetId,
          queryParameters: const <String, String>{'destination': 'raw'},
        ),
        targetType: 'recording',
        targetId: normalizedTargetId,
      ),
      'recording_batch' => forRecordingBatch(normalizedTargetId),
      'thread' => _threadDestination(normalizedTargetId, signal),
      'note' || 'hnote' => _noteDestination(normalizedTargetId, signal),
      'asset' => NotificationDestination(
        kind: NotificationDestinationKind.asset,
        uri: _route('/v3/assets', const <String, String>{'focus': 'overview'}),
        targetType: 'asset',
        targetId: normalizedTargetId,
      ),
      'task' => NotificationDestination(
        kind: NotificationDestinationKind.task,
        uri: _identifierPath('/v3/workbench/tasks', normalizedTargetId),
        targetType: 'task',
        targetId: normalizedTargetId,
      ),
      'hotspot_suggestion' => NotificationDestination(
        kind: NotificationDestinationKind.hotspotSuggestion,
        uri: Uri.parse('/v3/feed'),
        targetType: 'hotspot_suggestion',
        targetId: normalizedTargetId,
      ),
      'topic_recommendation' => NotificationDestination(
        kind: NotificationDestinationKind.topicRecommendation,
        uri: _identifierPath(
          '/v3/workbench/recommendations',
          normalizedTargetId,
        ),
        targetType: 'topic_recommendation',
        targetId: normalizedTargetId,
      ),
      'graph' => NotificationDestination(
        kind: NotificationDestinationKind.graph,
        uri: Uri.parse('/v3/feed/graph'),
        targetType: 'graph',
        targetId: normalizedTargetId,
      ),
      'onboarding' => NotificationDestination(
        kind: NotificationDestinationKind.onboarding,
        uri: _route('/onboarding', const <String, String>{'resume': '1'}),
        targetType: 'onboarding',
        targetId: normalizedTargetId,
      ),
      'positioning_progress' || 'positioning_report' => NotificationDestination(
        kind: NotificationDestinationKind.positioningReport,
        uri: _route('/v3/workbench/deep-positioning', <String, String>{
          'focus': 'report',
          'taskId': normalizedTargetId,
        }),
        targetType: 'positioning_report',
        targetId: normalizedTargetId,
        stage: NotificationDestinationStage.report,
      ),
      'device_setup' || 'first_launch_device_setup' => NotificationDestination(
        kind: NotificationDestinationKind.deviceSetup,
        uri: Uri.parse('/v3/onboarding/device-setup'),
        targetType: 'first_launch_device_setup',
        targetId: normalizedTargetId,
      ),
      _ => null,
    };
  }

  NotificationDestinationReceipt? receiptForCommittedUri(Uri uri) {
    if (!_isSafeCommittedUri(uri)) return null;

    final segments = uri.pathSegments;
    if (_matches(segments, const <String>['v3', 'feed', 'chat'])) {
      final threadId = _singleQueryValue(uri, 'threadId');
      if (threadId == null || !isSafeChatIdentifier(threadId)) {
        return null;
      }
      if (!_hasAtMostOneQueryValue(uri, 'purpose')) return null;
      final purposeValue = _singleQueryValue(uri, 'purpose');
      final purpose = switch (purposeValue) {
        'general' => NotificationDestinationPurpose.general,
        'deep-positioning' => NotificationDestinationPurpose.deepPositioning,
        _ => null,
      };
      if (purpose == null) return null;
      return NotificationDestinationReceipt(
        kind: NotificationDestinationKind.thread,
        committedUri: uri,
        targetType: 'thread',
        targetId: threadId,
        purpose: purpose,
      );
    }

    if (_hasPrefix(segments, const <String>[
      'v3',
      'feed',
      'transcription-done',
    ])) {
      final recordingId = segments[3];
      if (!isSafeNotificationOpaqueIdentifier(recordingId)) return null;
      return NotificationDestinationReceipt(
        kind: NotificationDestinationKind.recording,
        committedUri: uri,
        targetType: 'recording',
        targetId: recordingId,
      );
    }

    if (_hasPrefix(segments, const <String>[
      'v3',
      'feed',
      'transcription-batches',
    ])) {
      final batchId = segments[3];
      final focusItemId = _singleQueryValue(uri, 'focusItem');
      if (!isSafeNotificationOpaqueIdentifier(batchId) ||
          !_recordingBatchQueryIsSafe(uri) ||
          (focusItemId != null &&
              !isSafeNotificationOpaqueIdentifier(focusItemId))) {
        return null;
      }
      return NotificationDestinationReceipt(
        kind: NotificationDestinationKind.recordingBatch,
        committedUri: uri,
        targetType: 'recording_batch',
        targetId: batchId,
        focusItemId: focusItemId,
      );
    }

    if (_hasPrefix(segments, const <String>['v3', 'feed', 'items'])) {
      final noteId = segments[3];
      if (!isSafeNotificationOpaqueIdentifier(noteId)) return null;
      if (!_hasAtMostOneQueryValue(uri, 'stage')) return null;
      final stageValue = _singleQueryValue(uri, 'stage');
      final stage = switch (stageValue) {
        null || 'raw' => NotificationDestinationStage.raw,
        'summary' => NotificationDestinationStage.outline,
        'sprout' => NotificationDestinationStage.sprout,
        _ => null,
      };
      if (stage == null) return null;
      return NotificationDestinationReceipt(
        kind: NotificationDestinationKind.note,
        committedUri: uri,
        targetType: 'asset',
        targetId: noteId,
        stage: stage,
      );
    }

    if (_hasPrefix(segments, const <String>['v3', 'workbench', 'tasks'])) {
      final taskId = segments[3];
      if (!isSafeNotificationTaskIdentifier(taskId)) return null;
      return NotificationDestinationReceipt(
        kind: NotificationDestinationKind.task,
        committedUri: uri,
        targetType: 'task',
        targetId: taskId,
      );
    }

    if (_matches(segments, const <String>['v3', 'profile', 'digital-twin'])) {
      final file = _singleQueryValue(uri, 'file');
      final focus = _singleQueryValue(uri, 'focus');
      final taskId = _singleQueryValue(uri, 'taskId');
      if (!_digitalTwinPositioningReportQueryIsSafe(uri) ||
          file != 'social_positioning' ||
          focus != 'report' ||
          taskId == null ||
          !isSafeNotificationTaskIdentifier(taskId)) {
        return null;
      }
      return NotificationDestinationReceipt(
        kind: NotificationDestinationKind.positioningReport,
        committedUri: uri,
        targetType: 'positioning_report',
        targetId: taskId,
        stage: NotificationDestinationStage.report,
      );
    }

    if (_matches(segments, const <String>[
      'v3',
      'workbench',
      'deep-positioning',
    ])) {
      final focus = _singleQueryValue(uri, 'focus');
      final taskId = _singleQueryValue(uri, 'taskId');
      if (focus != 'report' ||
          taskId == null ||
          !isSafeNotificationTaskIdentifier(taskId)) {
        return null;
      }
      return NotificationDestinationReceipt(
        kind: NotificationDestinationKind.positioningReport,
        committedUri: uri,
        targetType: 'positioning_report',
        targetId: taskId,
        stage: NotificationDestinationStage.report,
      );
    }

    if (_hasPrefix(segments, const <String>[
      'v3',
      'workbench',
      'recommendations',
    ])) {
      final recommendationId = segments[3];
      if (!isSafeNotificationOpaqueIdentifier(recommendationId)) return null;
      return NotificationDestinationReceipt(
        kind: NotificationDestinationKind.topicRecommendation,
        committedUri: uri,
        targetType: 'topic_recommendation',
        targetId: recommendationId,
      );
    }

    if (_matches(segments, const <String>['v3', 'assets']) &&
        _assetsOverviewQueryIsSafe(uri)) {
      return NotificationDestinationReceipt(
        kind: NotificationDestinationKind.asset,
        committedUri: uri,
        targetType: 'asset',
      );
    }

    if (_matches(segments, const <String>['v3', 'feed', 'graph'])) {
      return NotificationDestinationReceipt(
        kind: NotificationDestinationKind.graph,
        committedUri: uri,
        targetType: 'graph',
      );
    }

    if (_matches(segments, const <String>['onboarding'])) {
      return NotificationDestinationReceipt(
        kind: NotificationDestinationKind.onboarding,
        committedUri: uri,
        targetType: 'onboarding',
      );
    }

    if (_matches(segments, const <String>['v3', 'positioning', 'progress'])) {
      return NotificationDestinationReceipt(
        kind: NotificationDestinationKind.positioningProgress,
        committedUri: uri,
        targetType: 'positioning_report',
      );
    }

    if (_matches(segments, const <String>[
      'v3',
      'onboarding',
      'device-setup',
    ])) {
      return NotificationDestinationReceipt(
        kind: NotificationDestinationKind.deviceSetup,
        committedUri: uri,
        targetType: 'first_launch_device_setup',
      );
    }

    return null;
  }

  NotificationDestination _threadDestination(String threadId, String signal) {
    final isDeepPositioning =
        signal.contains('deep_positioning') ||
        signal.contains('positioning_lv2') ||
        signal.contains('social_positioning');
    final purpose = isDeepPositioning
        ? NotificationDestinationPurpose.deepPositioning
        : NotificationDestinationPurpose.general;
    return NotificationDestination(
      kind: NotificationDestinationKind.thread,
      uri: _route('/v3/feed/chat', <String, String>{
        'threadId': threadId,
        'purpose': purpose.routeValue,
      }),
      targetType: 'thread',
      targetId: threadId,
      purpose: purpose,
    );
  }

  NotificationDestination _noteDestination(String noteId, String signal) {
    final stage = signal.contains('germination') || signal.contains('sprout')
        ? NotificationDestinationStage.sprout
        : signal.contains('outline') || signal.contains('minutes')
        ? NotificationDestinationStage.outline
        : NotificationDestinationStage.raw;
    return NotificationDestination(
      kind: NotificationDestinationKind.note,
      uri: _identifierPath(
        '/v3/feed/items',
        noteId,
        queryParameters: switch (stage.routeValue) {
          final routeValue? => <String, String>{'stage': routeValue},
          null => null,
        },
      ),
      targetType: 'asset',
      targetId: noteId,
      stage: stage,
    );
  }
}

String? _safeSignal(String value) {
  final normalized = value.trim().toLowerCase();
  return RegExp(r'^[a-z][a-z0-9_.-]{0,127}$').hasMatch(normalized)
      ? normalized
      : null;
}

bool _isSafeTargetId(String targetType, String targetId) {
  return switch (targetType) {
    'thread' => isSafeChatIdentifier(targetId),
    'task' ||
    'positioning_progress' ||
    'positioning_report' => isSafeNotificationTaskIdentifier(targetId),
    _ => isSafeNotificationOpaqueIdentifier(targetId),
  };
}

Uri _identifierPath(
  String basePath,
  String identifier, {
  Map<String, String>? queryParameters,
}) {
  return _route(
    '$basePath/${Uri.encodeComponent(identifier)}',
    queryParameters,
  );
}

Uri _route(String path, [Map<String, String>? queryParameters]) {
  if (queryParameters == null || queryParameters.isEmpty) {
    return Uri.parse(path);
  }
  final query = Uri(queryParameters: queryParameters).query;
  return Uri.parse('$path?$query');
}

bool _isSafeCommittedUri(Uri uri) {
  return !uri.hasScheme &&
      !uri.hasAuthority &&
      uri.fragment.isEmpty &&
      uri.path.startsWith('/');
}

bool _matches(List<String> actual, List<String> expected) {
  if (actual.length != expected.length) return false;
  for (var index = 0; index < expected.length; index += 1) {
    if (actual[index] != expected[index]) return false;
  }
  return true;
}

bool _hasPrefix(List<String> actual, List<String> prefix) {
  return actual.length == prefix.length + 1 &&
      _matches(actual.take(prefix.length).toList(), prefix);
}

String? _singleQueryValue(Uri uri, String name) {
  final values = uri.queryParametersAll[name];
  return values?.length == 1 ? values!.single : null;
}

bool _hasAtMostOneQueryValue(Uri uri, String name) {
  return (uri.queryParametersAll[name]?.length ?? 0) <= 1;
}

bool _assetsOverviewQueryIsSafe(Uri uri) {
  final focusValues = uri.queryParametersAll['focus'];
  if (focusValues != null &&
      (focusValues.length != 1 || focusValues.single != 'overview')) {
    return false;
  }
  return !uri.queryParameters.containsKey('label');
}

bool _recordingBatchQueryIsSafe(Uri uri) {
  if (uri.queryParametersAll.keys.any((key) => key != 'focusItem')) {
    return false;
  }
  return _hasAtMostOneQueryValue(uri, 'focusItem');
}

bool _digitalTwinPositioningReportQueryIsSafe(Uri uri) {
  const allowed = <String>{'file', 'focus', 'taskId'};
  if (uri.queryParametersAll.keys.any((key) => !allowed.contains(key))) {
    return false;
  }
  return allowed.every((key) => _singleQueryValue(uri, key) != null);
}
