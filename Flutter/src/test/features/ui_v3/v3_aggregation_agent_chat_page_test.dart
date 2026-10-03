import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/features/ui_v3/application/aggregation_agent_session_registry.dart';
import 'package:huahuoai_app/features/ui_v3/data/feed_aggregation_repository.dart';
import 'package:huahuoai_app/features/ui_v3/domain/ui_v3_models.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_aggregation_agent_chat_page.dart';

void main() {
  testWidgets('renders a visible return state for an expired route session', (
    tester,
  ) async {
    final registry = AggregationAgentSessionRegistry();

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          aggregationAgentSessionRegistryProvider.overrideWithValue(registry),
        ],
        child: const MaterialApp(
          home: V3AggregationAgentChatPage(sessionId: 'missing-session'),
        ),
      ),
    );

    expect(find.text('会话已失效'), findsOneWidget);
    expect(find.text('请返回聚合结果后重新开启聊一聊。'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '返回首页'), findsOneWidget);
  });

  testWidgets('uses its registered session and preserves async replies', (
    tester,
  ) async {
    final registry = AggregationAgentSessionRegistry();
    const session = AggregationAgentSession(
      id: 'prepared-session',
      kind: AggregationAgentKind.lead,
      materialIds: <String>['one', 'two', 'three', 'four', 'hotspot'],
      openingMessage: '我们先梳理受众路径。',
    );
    registry.register(session: session, port: const _PageReplyPort());

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          aggregationAgentSessionRegistryProvider.overrideWithValue(registry),
        ],
        child: MaterialApp(
          home: V3AggregationAgentChatPage(sessionId: session.id),
        ),
      ),
    );

    expect(find.text('获客 · 聊一聊'), findsOneWidget);
    expect(find.text('已带入 5 份聚合材料'), findsNothing);
    expect(find.text('我们先梳理受众路径。'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '如何承接咨询');
    await tester.tap(find.byTooltip('发送'));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('如何承接咨询'), findsOneWidget);
    expect(find.text('回复：如何承接咨询'), findsOneWidget);
  });
}

final class _PageReplyPort implements AggregationAgentPort {
  const _PageReplyPort();

  @override
  Future<AggregationAgentSession> prepare(
    AggregationAgentLaunchRequest request,
  ) async => throw UnimplementedError();

  @override
  Future<String> reply({
    required AggregationAgentSession session,
    required String message,
  }) async => '回复：$message';
}
