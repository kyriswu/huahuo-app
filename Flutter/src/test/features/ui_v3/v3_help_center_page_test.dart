import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/app/bootstrap/app_providers.dart';
import 'package:huahuoai_app/core/auth/secure_token_store.dart';
import 'package:huahuoai_app/core/auth/session_store.dart';
import 'package:huahuoai_app/features/ui_v3/application/help_center_controller.dart';
import 'package:huahuoai_app/features/ui_v3/data/profile_capability_ports.dart';
import 'package:huahuoai_app/features/ui_v3/domain/help_center_models.dart';
import 'package:huahuoai_app/features/ui_v3/domain/v3_markdown_outline.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_help_center_page.dart';
import 'package:huahuoai_app/shared/theme/huahuo_v3_theme.dart';

void main() {
  testWidgets('home has four equal actions and searchable articles', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(375, 812);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await _pumpHelpHome(tester, textScale: 1.3);

    const keys = [
      'help-entry-manual',
      'help-entry-recording-card',
      'help-entry-customer-service',
      'help-upload-bug',
    ];
    final sizes = <Size>[];
    for (final key in keys) {
      final finder = find.byKey(ValueKey(key));
      expect(finder, findsOneWidget);
      sizes.add(tester.getSize(finder));
    }
    expect(sizes.map((size) => size.height).toSet(), hasLength(1));
    expect(sizes.map((size) => size.width).toSet(), hasLength(1));
    expect(find.byKey(const ValueKey('help-entry-features')), findsNothing);
    expect(find.text('上传 Bug').last, findsOneWidget);
    expect(find.textContaining('不上传截图'), findsOneWidget);

    await tester.ensureVisible(find.byKey(const ValueKey('help-search-input')));
    await tester.enterText(
      find.byKey(const ValueKey('help-search-input')),
      '声纹',
    );
    await tester.pump();
    expect(find.text('声纹管理'), findsOneWidget);
    expect(find.text('快速开始'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('article uses recursive shared outline and safe image fallback', (
    tester,
  ) async {
    final repository = _FakeHelpRepository();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [helpCenterRepositoryProvider.overrideWithValue(repository)],
        child: const MaterialApp(
          home: V3HelpArticlePage(articleId: 'software-getting-started'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('目录'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('help-outline-help-操作步骤')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey('help-outline-toggle-help-快速开始')),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('help-outline-help-操作步骤')), findsNothing);
    await tester.tap(
      find.byKey(const ValueKey('help-outline-toggle-help-快速开始')),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('help-outline-help-操作步骤')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('help-article-image-customer-service-qr')),
      findsOneWidget,
    );
    expect(find.text('HELP_IMAGE_MISSING'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('customer page renders only the verified QR content', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: V3CustomerServicePage()));
    await tester.pumpAndSettle();

    final frame = find.byKey(const ValueKey('help-customer-qr-frame'));
    expect(frame, findsOneWidget);
    expect(tester.getSize(frame), const Size(220, 220));
    expect(find.byType(Image), findsOneWidget);
    expect(find.textContaining('客服微信'), findsNothing);
    expect(find.textContaining('复制'), findsNothing);
    expect(find.byType(CircleAvatar), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('all six appearances use active semantic help colors', (
    tester,
  ) async {
    final appearances = <String, ThemeData>{
      'system': HuahuoV3Theme.light(),
      'light': HuahuoV3Theme.light(),
      'dark': HuahuoV3Theme.dark(),
      'mist-blue': HuahuoV3Theme.light(palette: HuahuoV3Palette.mistBlue),
      'pine-green': HuahuoV3Theme.light(palette: HuahuoV3Palette.pineGreen),
      'warm-gold': HuahuoV3Theme.light(palette: HuahuoV3Palette.warmGold),
    };

    for (final appearance in appearances.entries) {
      final colors = appearance.value.extension<HuahuoV3ThemeTokens>()!;
      await _pumpHelpHome(tester, theme: appearance.value);

      final manualSubtitle = find.text('2 篇离线说明');
      expect(find.textContaining('内容已随应用离线提供'), findsNothing);
      expect(
        DefaultTextStyle.of(tester.element(manualSubtitle)).style.color,
        colors.muted,
        reason: '${appearance.key} row subtitle must use muted token',
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: appearance.value,
          home: const V3CustomerServicePage(),
        ),
      );
      await tester.pumpAndSettle();
      final qrFrame = tester.widget<Container>(
        find.byKey(const ValueKey('help-customer-qr-frame')),
      );
      expect(
        qrFrame.color,
        Colors.white,
        reason: '${appearance.key} must preserve the QR quiet zone',
      );
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('Bug action is an explicit count-only Demo flow', (tester) async {
    await _pumpHelpHome(tester);

    await tester.tap(find.byKey(const ValueKey('help-upload-bug')));
    await tester.pumpAndSettle();
    expect(find.text('上传 Bug').last, findsOneWidget);
    expect(find.textContaining('不会上传真实截图'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('bug-report-description')),
      '短',
    );
    await tester.tap(find.text('提交'));
    await tester.pump();
    expect(find.text('请至少描述 5 个字符'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('bug-report-description')),
      '打开帮助页面后无法继续操作',
    );
    for (var index = 0; index < 3; index++) {
      await tester.tap(find.byKey(const ValueKey('bug-report-screenshot')));
      await tester.pump();
    }
    expect(find.text('已添加 3 / 3'), findsOneWidget);
    final screenshotButton = tester.widget<OutlinedButton>(
      find.ancestor(
        of: find.text('已添加 3 / 3'),
        matching: find.byType(OutlinedButton),
      ),
    );
    expect(screenshotButton.onPressed, isNull);

    await tester.tap(find.text('提交'));
    await tester.pumpAndSettle();
    expect(find.text('Bug 已提交'), findsOneWidget);
  });
}

Future<void> _pumpHelpHome(
  WidgetTester tester, {
  double textScale = 1,
  ThemeData? theme,
}) async {
  final sessionStore = SessionStore(
    secureTokenStore: SecureTokenStore(driver: _MemoryTokenDriver()),
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sessionStoreProvider.overrideWith((ref) => sessionStore),
        helpCenterRepositoryProvider.overrideWithValue(_FakeHelpRepository()),
        profileSupportPortProvider.overrideWith(
          (ref) => const ProfileSupportDemoPort(),
        ),
      ],
      child: MaterialApp(
        theme: theme,
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
          child: const V3HelpCenterPage(),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

final class _FakeHelpRepository implements HelpCenterRepository {
  _FakeHelpRepository() {
    final summaries = <HelpArticleSummary>[
      _summary(
        id: 'software-getting-started',
        title: '快速开始',
        summary: '了解主要功能和操作步骤',
        groupId: helpSoftwareGroupId,
        order: 0,
        tags: const ['功能介绍'],
      ),
      _summary(
        id: 'software-voiceprint',
        title: '声纹管理',
        summary: '从设置进入并管理声纹档案',
        groupId: helpSoftwareGroupId,
        order: 1,
        tags: const ['声纹'],
      ),
      _summary(
        id: 'recording-card-connect',
        title: '蓝牙连接',
        summary: '连接录音卡设备',
        groupId: helpRecordingCardGroupId,
        order: 0,
        tags: const ['蓝牙'],
      ),
    ];
    catalog = HelpCenterCatalog(
      schemaVersion: 1,
      contentVersion: '2026.07.24',
      locale: 'zh-CN',
      categories: const [
        HelpCenterCategory(
          id: helpSoftwareGroupId,
          title: '软件使用说明书',
          summary: '软件帮助',
          order: 0,
        ),
        HelpCenterCategory(
          id: helpRecordingCardGroupId,
          title: '录音卡使用指南',
          summary: '录音卡帮助',
          order: 1,
        ),
      ],
      articles: summaries,
      images: const [
        HelpImageAsset(
          id: 'customer-service-qr',
          assetPath: helpCustomerServiceQrAssetPath,
          alt: '客服二维码',
        ),
        HelpImageAsset(
          id: 'missing-diagram',
          assetPath: 'assets/help/zh-CN/images/missing-diagram.png',
          alt: '缺失示意图',
        ),
      ],
    );
    const markdown = '''
# 快速开始
## 操作步骤
正文内容
![二维码](asset:customer-service-qr)
![示意图](asset:missing-diagram)
''';
    articles = <String, HelpArticle>{
      'software-getting-started': HelpArticle(
        metadata: summaries[0],
        markdown: markdown,
        sections: parseV3MarkdownOutline(markdown, idPrefix: 'help'),
        images: catalog.images,
      ),
      'software-voiceprint': HelpArticle(
        metadata: summaries[1],
        markdown: '# 声纹管理\n从设置进入。',
        sections: parseV3MarkdownOutline('# 声纹管理', idPrefix: 'help'),
        images: const [],
      ),
      'recording-card-connect': HelpArticle(
        metadata: summaries[2],
        markdown: '# 蓝牙连接\n允许系统权限。',
        sections: parseV3MarkdownOutline('# 蓝牙连接', idPrefix: 'help'),
        images: const [],
      ),
    };
  }

  late final HelpCenterCatalog catalog;
  late final Map<String, HelpArticle> articles;

  @override
  Future<HelpCenterCatalog> loadCatalog() async => catalog;

  @override
  Future<HelpArticle> loadArticle(String articleId) async {
    final article = articles[articleId];
    if (article == null) {
      throw const HelpCenterLoadException('HELP_ARTICLE_NOT_FOUND');
    }
    return article;
  }
}

HelpArticleSummary _summary({
  required String id,
  required String title,
  required String summary,
  required String groupId,
  required int order,
  required List<String> tags,
}) {
  return HelpArticleSummary(
    id: id,
    title: title,
    summary: summary,
    groupId: groupId,
    order: order,
    assetPath: 'assets/help/zh-CN/articles/$id.md',
    tags: tags,
  );
}

final class _MemoryTokenDriver implements SecureTokenDriver {
  @override
  bool clear({required String service}) => true;

  @override
  SecureTokenCredential? read({required String service}) => null;

  @override
  bool write({
    required String service,
    required String username,
    required String password,
  }) => true;
}
