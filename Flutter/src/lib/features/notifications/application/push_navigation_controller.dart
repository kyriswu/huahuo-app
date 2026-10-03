import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../domain/notification_models.dart';
import '../domain/push_message.dart';
import 'notification_destination_registry.dart';

typedef RecordingPushBatchContext = ({String batchId, String itemId});
typedef RecordingPushBatchContextResolver =
    RecordingPushBatchContext? Function(String remoteRecordingId);

final class PushNavigationCommand {
  const PushNavigationCommand({
    required this.id,
    required this.location,
    required this.receiveType,
    this.notificationId,
    this.eventId,
    this.transportFingerprint,
  });

  final String id;
  final String location;
  final PushReceiveType receiveType;
  final String? notificationId;
  final String? eventId;
  final String? transportFingerprint;

  bool matchesDelivery(AppNotification notification) {
    final revision = eventId;
    return revision != null &&
        notificationId == notification.notificationId &&
        revision == notification.eventId;
  }
}

final class PushNavigationController extends ChangeNotifier {
  PushNavigationController({this.recordingBatchContextResolver});

  final RecordingPushBatchContextResolver? recordingBatchContextResolver;
  PushNavigationCommand? _pendingCommand;
  final _seen = HashSet<String>();
  final _seenOrder = Queue<String>();
  var _invalidSequence = 0;
  var _foregroundSequence = 0;
  var _legacySequence = 0;

  PushNavigationCommand? get pendingCommand => _pendingCommand;

  void receive(PushParseResult result, PushReceiveType receiveType) {
    if (receiveType == PushReceiveType.foreground) return;
    if (result is ValidPushMessage) {
      final fingerprint = result.message.fingerprint;
      final commandId = _commandIdForDelivery(
        fingerprint: fingerprint,
        eventId: result.message.eventId,
      );
      if (commandId == null) return;
      _pendingCommand = PushNavigationCommand(
        id: commandId,
        location: _locationFor(result.message),
        receiveType: receiveType,
        notificationId: result.message.notificationId,
        eventId: result.message.eventId,
        transportFingerprint: result.message.eventId == null
            ? null
            : fingerprint,
      );
      notifyListeners();
      return;
    }
    if (result is InboxPushMessage) {
      final fingerprint = 'inbox:${result.fingerprint}';
      final commandId = _commandIdForDelivery(
        fingerprint: fingerprint,
        eventId: result.eventId,
      );
      if (commandId == null) return;
      _pendingCommand = PushNavigationCommand(
        id: commandId,
        location: '/v3/notifications',
        receiveType: receiveType,
        notificationId: result.notificationId,
        eventId: result.eventId,
        transportFingerprint: result.eventId == null ? null : fingerprint,
      );
      notifyListeners();
      return;
    }
    if (_pendingCommand?.id.startsWith('invalid-push-') ?? false) return;
    _invalidSequence += 1;
    _pendingCommand = PushNavigationCommand(
      id: 'invalid-push-$_invalidSequence',
      location: '/v3/notifications',
      receiveType: receiveType,
    );
    notifyListeners();
  }

  bool _remember(String fingerprint) {
    if (!_seen.add(fingerprint)) return false;
    _seenOrder.addLast(fingerprint);
    while (_seenOrder.length > 64) {
      _seen.remove(_seenOrder.removeFirst());
    }
    return true;
  }

  String? _commandIdForDelivery({
    required String fingerprint,
    required String? eventId,
  }) {
    if (eventId != null) return _remember(fingerprint) ? fingerprint : null;
    final prefix = 'legacy:$fingerprint:';
    if (_pendingCommand?.id.startsWith(prefix) ?? false) return null;
    _legacySequence += 1;
    return '$prefix$_legacySequence';
  }

  void openForeground(PushMessage message) {
    _foregroundSequence += 1;
    _pendingCommand = PushNavigationCommand(
      id: 'foreground:${message.fingerprint}:$_foregroundSequence',
      location: _locationFor(message),
      receiveType: PushReceiveType.foreground,
      notificationId: message.notificationId,
      eventId: message.eventId,
    );
    notifyListeners();
  }

  void consume(String commandId) {
    if (_pendingCommand?.id != commandId) return;
    _pendingCommand = null;
    notifyListeners();
  }

  void reject(String commandId) {
    final command = _pendingCommand;
    if (command == null || command.id != commandId) return;
    final fingerprint = command.transportFingerprint;
    if (fingerprint != null) {
      _seen.remove(fingerprint);
      _seenOrder.remove(fingerprint);
    }
    _pendingCommand = null;
    notifyListeners();
  }

  void clear() {
    _pendingCommand = null;
    _seen.clear();
    _seenOrder.clear();
    notifyListeners();
  }

  String _locationFor(PushMessage message) {
    if (message.eventId == null || message.targetType != 'recording') {
      return pushLocation(message);
    }
    final resolver = recordingBatchContextResolver;
    if (resolver == null) return pushLocation(message);
    try {
      final context = resolver(message.targetId);
      if (context == null) return pushLocation(message);
      return notificationDestinationRegistry
              .forRecordingBatch(context.batchId, focusItemId: context.itemId)
              ?.location ??
          pushLocation(message);
    } on Object {
      return pushLocation(message);
    }
  }
}

String pushLocation(PushMessage message) {
  if (message.eventId == null) return '/v3/notifications';
  return notificationDestinationRegistry.forPush(message)?.location ??
      '/v3/notifications';
}

bool isPushForChatThread(PushMessage message, String? threadId) {
  final activeThreadId = threadId?.trim();
  return activeThreadId != null &&
      activeThreadId.isNotEmpty &&
      message.scene == 'chat' &&
      message.targetType == 'thread' &&
      message.targetId == activeThreadId;
}
