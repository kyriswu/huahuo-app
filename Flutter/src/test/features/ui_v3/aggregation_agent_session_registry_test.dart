import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/features/ui_v3/application/aggregation_agent_session_registry.dart';
import 'package:huahuoai_app/features/ui_v3/data/feed_aggregation_repository.dart';
import 'package:huahuoai_app/features/ui_v3/domain/ui_v3_models.dart';

void main() {
  test('registers, reads, and removes opaque aggregation-agent sessions', () {
    final registry = AggregationAgentSessionRegistry();
    const port = _RegistryReplyPort();
    const session = AggregationAgentSession(
      id: 'session-1',
      kind: AggregationAgentKind.persona,
      materialIds: <String>['note-a', 'note-b', 'note-c', 'note-d', 'hotspot'],
      openingMessage: '开始整理人设材料。',
    );

    registry.register(session: session, port: port);

    final entry = registry.read(' session-1 ');
    expect(entry?.session, same(session));
    expect(entry?.port, same(port));
    expect(registry.remove('session-1'), isTrue);
    expect(registry.read('session-1'), isNull);
    expect(registry.entryCount, 0);
  });

  test('purges an expired aggregation-agent session before route lookup', () {
    var now = DateTime.utc(2026, 8, 12, 10);
    final registry = AggregationAgentSessionRegistry(
      retention: const Duration(minutes: 5),
      clock: () => now,
    );
    const session = AggregationAgentSession(
      id: 'session-expired',
      kind: AggregationAgentKind.visual,
      materialIds: <String>['a', 'b', 'c', 'd', 'hotspot'],
      openingMessage: '开始整理视觉材料。',
    );

    registry.register(session: session, port: const _RegistryReplyPort());
    now = now.add(const Duration(minutes: 5));

    expect(registry.read(session.id), isNull);
    expect(registry.entryCount, 0);
  });
}

final class _RegistryReplyPort implements AggregationAgentPort {
  const _RegistryReplyPort();

  @override
  Future<AggregationAgentSession> prepare(
    AggregationAgentLaunchRequest request,
  ) async => throw UnimplementedError();

  @override
  Future<String> reply({
    required AggregationAgentSession session,
    required String message,
  }) async => '已收到：$message';
}
