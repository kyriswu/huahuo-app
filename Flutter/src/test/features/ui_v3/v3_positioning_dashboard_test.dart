import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuo_api/huahuo_api.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_positioning_dashboard.dart';
import 'package:huahuoai_app/shared/theme/huahuo_v3_theme.dart';

void main() {
  final profile = parseLatestPositioningProgress('''
说明文字
```huahuo-positioning-progress
{
  "completedPercent": 72,
  "visibleSubject": "内容定位",
  "consultationState": {"expertJudgment":"已形成清晰的内容判断"},
  "modules": [
    {"moduleId":"credible_self", "score":8, "weight":10, "state":"rich"}
  ]
}
```
''')!;

  testWidgets('renders a compact dashboard rather than raw progress JSON', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: HuahuoV3Theme.light(),
        home: Scaffold(
          body: V3PositioningDashboard(profile: profile, compact: true),
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey('positioning-dashboard-compact')),
      findsOneWidget,
    );
    expect(find.text('内容定位'), findsOneWidget);
    expect(find.text('8/10'), findsOneWidget);
    expect(find.textContaining('"completedPercent"'), findsNothing);
  });

  testWidgets('full dashboard contains all eight module summaries', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: HuahuoV3Theme.dark(),
        home: Scaffold(body: V3PositioningDashboard(profile: profile)),
      ),
    );

    expect(
      find.byKey(const ValueKey('positioning-dashboard-full')),
      findsOneWidget,
    );
    expect(find.text('人生体验'), findsWidgets);
    expect(find.text('可调动的影像资源'), findsWidgets);
    expect(find.text('证据：待补充真实证据'), findsWidgets);
  });

  testWidgets('shared report prefers structured progress and hides metadata', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: HuahuoV3Theme.light(),
        home: Scaffold(
          body: V3PositioningReportContent(
            progress: profile,
            markdown: '''---
assetType: huahuo.positioning_profile.v1
---
# 基础定位报告

面向本地创业者讲真实经营经验。''',
          ),
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey('positioning-dashboard-compact')),
      findsOneWidget,
    );
    expect(find.text('内容定位'), findsOneWidget);
    expect(find.text('基础定位报告'), findsOneWidget);
    expect(find.textContaining('assetType'), findsNothing);
  });

  testWidgets('shared report can disable legacy Markdown progress fallback', (
    tester,
  ) async {
    const markdown = '''# 基础定位报告

可见正文。

```huahuo-positioning-progress
{"completedPercent":72,"visibleSubject":"旧定位进度"}
```''';
    Widget report({required bool allowFallback}) => MaterialApp(
      theme: HuahuoV3Theme.light(),
      home: Scaffold(
        body: V3PositioningReportContent(
          markdown: markdown,
          allowMarkdownProgressFallback: allowFallback,
        ),
      ),
    );

    await tester.pumpWidget(report(allowFallback: false));
    expect(
      find.byKey(const ValueKey('positioning-dashboard-compact')),
      findsNothing,
    );
    expect(find.text('可见正文。'), findsOneWidget);
    expect(find.textContaining('completedPercent'), findsNothing);

    await tester.pumpWidget(report(allowFallback: true));
    expect(
      find.byKey(const ValueKey('positioning-dashboard-compact')),
      findsOneWidget,
    );
    expect(find.text('旧定位进度'), findsOneWidget);
  });
}
