import 'package:flutter_test/flutter_test.dart';
import 'package:huahuo_foundation/huahuo_foundation.dart';

void main() {
  ({HuahuoMarkdownTable? table, String normalized}) parse(String source) {
    final normalized = HuahuoMarkdownTableNormalizer.normalize(source);
    final lines = normalized.split('\n');
    for (var index = 0; index < lines.length; index += 1) {
      final table = HuahuoMarkdownTableNormalizer.at(lines, index);
      if (table != null) return (table: table, normalized: normalized);
    }
    return (table: null, normalized: normalized);
  }

  test('parses standard and borderless pipe tables', () {
    final standard = parse('''
| 类别 | 新增 |
| --- | ---: |
| 知识 | 3 |
''');
    final borderless = parse('''
类别 | 新增
--- | ---
知识 | 3
''');

    expect(standard.table?.headers, <String>['类别', '新增']);
    expect(standard.table?.rows, <List<String>>[
      <String>['知识', '3'],
    ], reason: standard.normalized);
    expect(borderless.table?.headers, <String>['类别', '新增']);
  });

  test('recovers a separator joined to the first streamed data row', () {
    final table = parse('''
| 类别 | 新增 | 合并 |
| --- | ---: | ---: || 知识 | 3 | 0 |
''');

    expect(table.table?.headers, <String>['类别', '新增', '合并']);
    expect(table.table?.rows, <List<String>>[
      <String>['知识', '3', '0'],
    ], reason: table.normalized);
  });

  test('parses tab, stacked header, and split streamed rows', () {
    final tab = parse('''
类别\t新增\t合并
知识\t3\t0
''');
    final stackedHeader = parse('''
| 类别
| 新增 | 合并 |
| --- | --- |
| 知识 | 3 | 0 |
''');
    final splitRow = parse('''
| 类别 | 新增 | 合并 |
| --- | --- | --- |
知识
3
0
''');

    expect(tab.table?.rows.single, <String>[
      '知识',
      '3',
      '0',
    ], reason: tab.normalized);
    expect(stackedHeader.table?.headers, <String>[
      '类别',
      '新增',
      '合并',
    ], reason: stackedHeader.normalized);
    expect(splitRow.table?.rows.single, <String>['知识', '3', '0']);
  });

  test('keeps an adjacent two-column Tab table separate', () {
    final normalized = HuahuoMarkdownTableNormalizer.normalize('''
| 阶段 | 负责人 |
| --- | --- |
| 调研 | 小周 |
名称\t状态
方案 A\t已完成
''');
    final lines = normalized.split('\n');
    final first = HuahuoMarkdownTableNormalizer.at(lines, 0);
    final second = HuahuoMarkdownTableNormalizer.at(lines, first!.nextIndex);

    expect(first.headers, <String>['阶段', '负责人']);
    expect(first.rows, <List<String>>[
      <String>['调研', '小周'],
    ]);
    expect(second?.headers, <String>['名称', '状态']);
    expect(second?.rows, <List<String>>[
      <String>['方案 A', '已完成'],
    ]);
  });

  test('parses the deployed stacked outline-statistics table', () {
    final table = parse('''
| 类别
| 识别 | 新增 | 合并更新 | 未写入 |
| --- | ---: | ---: | ---: | ---: |
| 经历
| 0 | 0 | 0 | 0 |
| 知识
| 3 | 3 | 0 | 0 |
''');

    expect(table.table?.headers, <String>[
      '类别',
      '识别',
      '新增',
      '合并更新',
      '未写入',
    ], reason: table.normalized);
    expect(table.table?.rows, <List<String>>[
      <String>['经历', '0', '0', '0', '0'],
      <String>['知识', '3', '3', '0', '0'],
    ], reason: table.normalized);
  });

  test('stops before a fenced code block', () {
    final normalized = HuahuoMarkdownTableNormalizer.normalize('''
| 阶段 | 负责人 |
| --- | --- |
| 调研 | 小周 |
```
final answer = 42;
```
''');
    final lines = normalized.split('\n');
    final table = HuahuoMarkdownTableNormalizer.at(lines, 0);

    expect(table?.rows, <List<String>>[
      <String>['调研', '小周'],
    ]);
    expect(lines[table!.nextIndex], '```');
  });

  test('parses a separatorless streamed table only with two full rows', () {
    final table = parse('''
类别 | 新增
知识 | 3
观点 | 2
''');
    expect(table.table?.headers, <String>['类别', '新增']);
    expect(table.table?.rows, <List<String>>[
      <String>['知识', '3'],
      <String>['观点', '2'],
    ]);
  });
}
