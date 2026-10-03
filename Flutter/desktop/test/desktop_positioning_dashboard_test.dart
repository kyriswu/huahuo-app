import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuo_api/huahuo_api.dart';
import 'package:huahuo_desktop/features/positioning/presentation/desktop_positioning_dashboard.dart';

void main() {
  PositioningProgressProfile profile() => parseLatestPositioningProgress('''
```huahuo-positioning-progress
{
  "completedPercent": 64,
  "visibleSubject": "个人表达定位",
  "consultationState": {"expertJudgment": "已经具备可验证的表达线索"},
  "modules": [
    {"moduleId":"credible_self", "score":8, "weight":10, "state":"rich"}
  ]
}
```
''')!;

  testWidgets('renders public module score cards without raw JSON', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DesktopPositioningDashboard(profile: profile(), compact: true),
        ),
      ),
    );

    expect(
      find.byKey(
        const ValueKey<String>('desktop-positioning-dashboard-compact'),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(
        const ValueKey<String>('desktop-positioning-module-credible_self'),
      ),
      findsOneWidget,
    );
    expect(find.textContaining('"completedPercent"'), findsNothing);
  });

  testWidgets('shows evidence, gaps, and next steps in the full report', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: DesktopPositioningDashboard(profile: profile())),
      ),
    );

    expect(
      find.byKey(const ValueKey<String>('desktop-positioning-dashboard-full')),
      findsOneWidget,
    );
    expect(find.text('证据：待补充真实证据'), findsWidgets);
    expect(find.text('缺口：暂未列出'), findsWidgets);
  });
}
