import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/feed_aggregation_repository.dart';
import '../domain/ui_v3_models.dart';

// resident-provider: Preserves the aggregation agent session registry dependency identity across route changes.
final aggregationAgentSessionRegistryProvider =
    Provider<AggregationAgentSessionRegistry>((ref) {
      final registry = AggregationAgentSessionRegistry();
      ref.onDispose(registry.clear);
      return registry;
    });

@immutable
final class AggregationAgentSessionEntry {
  const AggregationAgentSessionEntry({
    required this.session,
    required this.port,
    required this.registeredAt,
  });

  final AggregationAgentSession session;
  final AggregationAgentPort port;
  final DateTime registeredAt;
}

/// Keeps prepared aggregation-agent context available only while this app run
/// retains the corresponding pushed route.
final class AggregationAgentSessionRegistry {
  AggregationAgentSessionRegistry({
    Duration retention = const Duration(minutes: 30),
    DateTime Function()? clock,
  }) : assert(!retention.isNegative),
       _retention = retention,
       _clock = clock ?? DateTime.now;

  final Duration _retention;
  final DateTime Function() _clock;
  final Map<String, AggregationAgentSessionEntry> _entries =
      <String, AggregationAgentSessionEntry>{};

  @visibleForTesting
  int get entryCount => _entries.length;

  void register({
    required AggregationAgentSession session,
    required AggregationAgentPort port,
  }) {
    final sessionId = _normalizedSessionId(session.id);
    if (sessionId == null) {
      throw ArgumentError.value(session.id, 'session.id', 'must not be empty');
    }
    final now = _now();
    _purgeExpired(now);
    _entries[sessionId] = AggregationAgentSessionEntry(
      session: session,
      port: port,
      registeredAt: now,
    );
  }

  AggregationAgentSessionEntry? read(String sessionId) {
    final normalized = _normalizedSessionId(sessionId);
    if (normalized == null) return null;
    _purgeExpired(_now());
    return _entries[normalized];
  }

  bool remove(String sessionId) {
    final normalized = _normalizedSessionId(sessionId);
    if (normalized == null) return false;
    return _entries.remove(normalized) != null;
  }

  int clearExpired() {
    final before = _entries.length;
    _purgeExpired(_now());
    return before - _entries.length;
  }

  void clear() => _entries.clear();

  DateTime _now() => _clock().toUtc();

  void _purgeExpired(DateTime now) {
    _entries.removeWhere(
      (_, entry) => now.difference(entry.registeredAt) >= _retention,
    );
  }

  static String? _normalizedSessionId(String value) {
    final normalized = value.trim();
    return normalized.isEmpty ? null : normalized;
  }
}
