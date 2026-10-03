import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/features/ui_v3/data/help_center_repository.dart';
import 'package:huahuoai_app/features/ui_v3/domain/help_center_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'loads ordered catalog, safe local image and shared outline once',
    () async {
      final bundle = _MapAssetBundle({
        helpCenterManifestAssetPath: _manifest(
          images: const [
            {
              'id': 'diagram',
              'assetPath': 'assets/help/zh-CN/images/diagram.png',
              'alt': '操作示意图',
            },
          ],
        ),
        'assets/help/zh-CN/articles/software-test.md': '''
# 总览
## 第一步
```md
# 代码中的标题
```
### 细节
#### 深入
##### 验证
###### 叶级
叶级正文
![本地示意](asset:diagram)
''',
        'assets/help/zh-CN/images/diagram.png': 'fake-png-bytes',
      });
      final repository = AssetHelpCenterRepository(bundle: bundle);

      final firstCatalog = await repository.loadCatalog();
      final secondCatalog = await repository.loadCatalog();
      final firstArticle = await repository.loadArticle('software-test');
      final secondArticle = await repository.loadArticle('software-test');

      expect(identical(firstCatalog, secondCatalog), isTrue);
      expect(identical(firstArticle, secondArticle), isTrue);
      expect(firstCatalog.categories.single.id, helpSoftwareGroupId);
      expect(firstArticle.sections.single.title, '总览');
      expect(firstArticle.sections.single.children.single.title, '第一步');
      expect(
        firstArticle.sections.single.children.single.children.single.title,
        '细节',
      );
      final leaf = firstArticle
          .sections
          .single
          .children
          .single
          .children
          .single
          .children
          .single
          .children
          .single
          .children
          .single;
      expect(leaf.level, 6);
      expect(leaf.directMarkdown, contains('叶级正文'));
      expect(
        firstArticle.sections.single.sectionMarkdown,
        contains('###### 叶级'),
      );
      expect(leaf.sectionEndLineIndex, greaterThan(leaf.lineIndex));
      expect(
        firstArticle.flattenedSections.map((section) => section.title),
        isNot(contains('代码中的标题')),
      );
      expect(firstArticle.imageFor('diagram')?.alt, '操作示意图');
      expect(bundle.loadCounts[helpCenterManifestAssetPath], 1);
      expect(
        bundle.loadCounts['assets/help/zh-CN/articles/software-test.md'],
        1,
      );
      expect(bundle.loadCounts['assets/help/zh-CN/images/diagram.png'], 1);
    },
  );

  test(
    'rejects manifest traversal, duplicate IDs and unknown groups',
    () async {
      final unsafePath = _manifest(
        articleOverrides: const {
          'assetPath': 'assets/help/zh-CN/articles/../secret.md',
        },
      );
      final duplicate = jsonEncode({
        ...(jsonDecode(_manifest()) as Map<String, Object?>),
        'articles': [_articleRow(), _articleRow()],
      });
      final unknownGroup = _manifest(
        articleOverrides: const {'group': 'missingGroup'},
      );

      for (final raw in [unsafePath, duplicate, unknownGroup]) {
        final repository = AssetHelpCenterRepository(
          bundle: _MapAssetBundle({helpCenterManifestAssetPath: raw}),
        );
        await expectLater(
          repository.loadCatalog(),
          throwsA(_helpError('HELP_MANIFEST_INVALID')),
        );
      }
    },
  );

  test('rejects unsafe Markdown and undeclared or remote images', () async {
    for (final source in [
      '# 标题\n<script>bad</script>',
      '# 标题\n![远程](https://example.invalid/image.png)',
      '# 标题\n![未声明](asset:missing-image)',
      '# 标题\nfile:private-recording',
      '# 标题\n\u202E隐藏方向',
    ]) {
      final repository = _repositoryWithArticle(source);
      await expectLater(
        repository.loadArticle('software-test'),
        throwsA(_helpError('HELP_ARTICLE_UNSAFE')),
      );
    }
  });

  test('reports a declared but missing local image explicitly', () async {
    final repository = AssetHelpCenterRepository(
      bundle: _MapAssetBundle({
        helpCenterManifestAssetPath: _manifest(
          images: const [
            {
              'id': 'diagram',
              'assetPath': 'assets/help/zh-CN/images/diagram.png',
              'alt': '示意图',
            },
          ],
        ),
        'assets/help/zh-CN/articles/software-test.md':
            '# 标题\n![示意](asset:diagram)',
      }),
    );

    await expectLater(
      repository.loadArticle('software-test'),
      throwsA(_helpError('HELP_IMAGE_MISSING')),
    );
  });

  test('rejects oversized article content with a stable code', () async {
    final repository = _repositoryWithArticle(
      List<String>.filled(128 * 1024, '文').join(),
    );

    await expectLater(
      repository.loadArticle('software-test'),
      throwsA(_helpError('HELP_ARTICLE_TOO_LARGE')),
    );
  });

  test(
    'packaged catalog contains 12 software and 7 recording-card guides',
    () async {
      final repository = AssetHelpCenterRepository();
      final catalog = await repository.loadCatalog();

      expect(catalog.articlesFor(helpSoftwareGroupId), hasLength(12));
      expect(catalog.articlesFor(helpRecordingCardGroupId), hasLength(7));
      expect(catalog.imageFor('customer-service-qr'), isNotNull);
      expect(
        catalog.articles
            .singleWhere((article) => article.id == 'software-creation')
            .matches('视觉设计'),
        isTrue,
      );
      expect(
        catalog.articles
            .singleWhere((article) => article.id == 'software-free-creation')
            .matches('深度洞察'),
        isTrue,
      );
      final articles = await Future.wait(
        catalog.articles.map((article) => repository.loadArticle(article.id)),
      );
      expect(articles, hasLength(19));
      expect(articles.every((article) => article.sections.isNotEmpty), isTrue);
    },
  );
}

AssetHelpCenterRepository _repositoryWithArticle(String source) {
  return AssetHelpCenterRepository(
    bundle: _MapAssetBundle({
      helpCenterManifestAssetPath: _manifest(),
      'assets/help/zh-CN/articles/software-test.md': source,
    }),
  );
}

Matcher _helpError(String code) =>
    isA<HelpCenterLoadException>().having((error) => error.code, 'code', code);

String _manifest({
  List<Map<String, Object?>> images = const [],
  Map<String, Object?> articleOverrides = const {},
}) {
  return jsonEncode({
    'schemaVersion': 1,
    'contentVersion': '2026.07.24',
    'locale': 'zh-CN',
    'groups': [
      {
        'id': helpSoftwareGroupId,
        'title': '软件说明',
        'summary': '离线软件说明',
        'order': 0,
      },
    ],
    'images': images,
    'articles': [_articleRow(overrides: articleOverrides)],
  });
}

Map<String, Object?> _articleRow({Map<String, Object?> overrides = const {}}) {
  return {
    'id': 'software-test',
    'title': '测试文章',
    'summary': '测试摘要',
    'group': helpSoftwareGroupId,
    'order': 0,
    'assetPath': 'assets/help/zh-CN/articles/software-test.md',
    'tags': ['测试'],
    ...overrides,
  };
}

final class _MapAssetBundle extends CachingAssetBundle {
  _MapAssetBundle(this.assets);

  final Map<String, String> assets;
  final Map<String, int> loadCounts = <String, int>{};

  @override
  Future<ByteData> load(String key) async {
    loadCounts.update(key, (count) => count + 1, ifAbsent: () => 1);
    final value = assets[key];
    if (value == null) throw StateError('Missing test asset: $key');
    return ByteData.sublistView(Uint8List.fromList(utf8.encode(value)));
  }

  @override
  Future<String> loadString(String key, {bool cache = true}) async {
    loadCounts.update(key, (count) => count + 1, ifAbsent: () => 1);
    final value = assets[key];
    if (value == null) throw StateError('Missing test asset: $key');
    return value;
  }
}
