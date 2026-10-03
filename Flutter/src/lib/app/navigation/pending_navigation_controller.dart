import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_route_paths.dart';

enum PendingNavigationReason {
  deepLink,
  pushNotification,
  externalShare,
  authentication,
}

final class PendingNavigation {
  const PendingNavigation({
    required this.location,
    required this.reason,
    required this.createdAt,
  });

  final String location;
  final PendingNavigationReason reason;
  final DateTime createdAt;
}

// resident-provider: Preserves the pending navigation controller state machine across route transitions.
final pendingNavigationControllerProvider =
    ChangeNotifierProvider<PendingNavigationController>((ref) {
      return PendingNavigationController();
    });

final class PendingNavigationController extends ChangeNotifier {
  PendingNavigation? _pending;

  PendingNavigation? get pending => _pending;

  bool stage({
    required String location,
    required PendingNavigationReason reason,
    DateTime? createdAt,
  }) {
    final normalized = _validatedLocation(location);
    if (normalized == null) return false;
    final next = PendingNavigation(
      location: normalized,
      reason: reason,
      createdAt: (createdAt ?? DateTime.now()).toUtc(),
    );
    if (_pending?.location == next.location &&
        _pending?.reason == next.reason) {
      return true;
    }
    _pending = next;
    notifyListeners();
    return true;
  }

  PendingNavigation? consume() {
    final value = _pending;
    if (value == null) return null;
    _pending = null;
    notifyListeners();
    return value;
  }

  void clear() {
    if (_pending == null) return;
    _pending = null;
    notifyListeners();
  }

  static String? _validatedLocation(String value) {
    final normalized = value.trim();
    if (normalized.isEmpty || normalized.length > 2048) return null;
    if (!AppRoutePaths.isV3Location(normalized)) return null;
    return normalized;
  }
}

bool shouldStagePendingNavigation({
  required String currentLocation,
  required String? redirectedLocation,
}) {
  if (redirectedLocation == null ||
      !AppRoutePaths.isV3Location(currentLocation)) {
    return false;
  }
  return !AppRoutePaths.isV3Location(redirectedLocation);
}
