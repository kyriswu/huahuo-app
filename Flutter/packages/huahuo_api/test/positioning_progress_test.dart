import 'package:huahuo_api/huahuo_api.dart';
import 'package:test/test.dart';

void main() {
  test('uses the latest valid fenced positioning progress block', () {
    final profile = parseLatestPositioningProgress('''
说明文字
```huahuo-positioning-progress
{"modules":[]}
```
```huahuo-positioning-progress
{
  "completedPercent": 65,
  "visibleSubject": "内容定位",
  "consultationState": {"mode":"deep", "expertJudgment":"已有核心判断"},
  "modules": [
    {"moduleId":"credible_self", "score":8, "weight":10, "state":"rich"}
  ]
}
```
''');

    expect(profile, isNotNull);
    expect(profile!.completedPercent, 65);
    expect(profile.visibleSubject, '内容定位');
    expect(profile.modules, hasLength(8));
    expect(profile.modules.first.percent, 80);
    expect(profile.consultationState.mode, 'deep');
  });

  test('keeps an in-progress dashboard when modules have not arrived yet', () {
    final profile = parseLatestPositioningProgress('''
```huahuo-positioning-progress
{"status":"collecting","visibleSubject":"人生体验"}
```
''');

    expect(profile, isNotNull);
    expect(profile!.status, 'collecting');
    expect(profile.visibleSubject, '人生体验');
    expect(profile.modules, hasLength(8));
    expect(profile.modules.every((module) => module.score == 0), isTrue);
  });

  test('parses and round-trips structured current-Profile progress', () {
    final profile = parsePositioningProgressPayload(<String, Object?>{
      'source': 'workspace_file',
      'available': true,
      'status': 'draft',
      'coldStartPercent': 100,
      'coldStartCompleted': true,
      'completedPercent': 65,
      'totalWeight': 100,
      'visibleSubject': '个人 IP 定位',
      'modules': <Object?>[
        <String, Object?>{
          'id': 'credible_self',
          'label': '人生体验',
          'weight': 10,
          'score': 8,
          'state': 'rich',
          'fullnessNote': '已有多段可信经历',
        },
      ],
      'nextFocus': <Object?>[
        <String, Object?>{'title': '补充典型案例', 'moduleId': 'credible_self'},
      ],
    });

    expect(profile, isNotNull);
    expect(profile!.completedPercent, 65);
    expect(profile.coldStartCompleted, isTrue);
    expect(profile.visibleSubject, '个人 IP 定位');
    expect(profile.modules.first.score, 8);
    expect(profile.modules.first.summary, '已有多段可信经历');
    expect(profile.nextFocus.single.title, '补充典型案例');

    final restored = parsePositioningProgressPayload(
      positioningProgressProfileToPayload(profile),
    );
    expect(restored?.completedPercent, 65);
    expect(restored?.modules.first.state, PositioningModuleState.rich);
    expect(restored?.nextFocus.single.moduleId, 'credible_self');
    expect(
      parsePositioningProgressPayload(<String, Object?>{
        'available': false,
        'completedPercent': 65,
      }),
      isNull,
    );
    expect(parsePositioningProgressPayload(const <String, Object?>{}), isNull);
  });

  test('strips both fenced and bare blocks without hiding normal markdown', () {
    final source = '''# 定位报告

```huahuo-positioning-progress
{"modules":[]}
```

结论

huahuo-positioning-progress {"modules":[]}
''';

    expect(stripPositioningProgressBlocks(source), '# 定位报告\n\n\n\n结论');
    expect(parseLatestPositioningProgress('没有进度块'), isNull);
  });

  test('strips formal report frontmatter and progress display metadata', () {
    final source = '''---
assetType: user_positioning_profile
schemaVersion: huahuo.positioning_profile.v1
scoringModel: positioning_coverage_v4
status: draft
completionPercent: 65
sourceRefs:
  - ../../../用户原始输入.md
lastUpdated: 2026-07-12
---

# 用户定位源文件

这是应当显示的中文报告正文。

```huahuo-positioning-progress
{"completedPercent":65,"modules":[]}
```''';

    final visible = stripPositioningReportMetadata(source);
    final adapted = stripPositioningReportFrontmatter(source);

    expect(visible, '# 用户定位源文件\n\n这是应当显示的中文报告正文。');
    expect(visible, isNot(contains('assetType')));
    expect(visible, isNot(contains('completedPercent')));
    expect(adapted, isNot(contains('assetType')));
    expect(adapted, contains('huahuo-positioning-progress'));
    expect(
      stripPositioningReportMetadata('# 普通报告\n\n---\n\n正文'),
      '# 普通报告\n\n---\n\n正文',
    );
  });
}
