import 'package:huahuoai_app/shared/markdown/v3_markdown.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/bootstrap/app_providers.dart';
import '../../../core/auth/session_store.dart';
import '../../../shared/theme/huahuo_v3_theme.dart';
import '../../../shared/ui_v3/v3_components.dart';
import '../../../shared/ui_v3/v3_glass_foundations.dart';
import '../../../shared/ui_v3/v3_overlays.dart';
import '../../../shared/ui_v3/v3_text_editing.dart';
import '../application/help_center_controller.dart';
import '../domain/help_center_models.dart';
import '../domain/profile_capability_models.dart';
import '../domain/v3_markdown_outline.dart';

class V3HelpCenterPage extends ConsumerStatefulWidget {
  const V3HelpCenterPage({super.key});

  @override
  ConsumerState<V3HelpCenterPage> createState() => _V3HelpCenterPageState();
}

class _V3HelpCenterPageState extends ConsumerState<V3HelpCenterPage> {
  final GlobalKey _articleListKey = GlobalKey();
  final TextEditingController _searchController = TextEditingController();
  String _query = '';
  String? _selectedGroupId;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final catalog = ref.watch(helpCenterCatalogProvider);
    return V3PageScaffold(
      title: '帮助与反馈',
      fallbackRoute: _fallbackRoute(ref),
      children: [
        catalog.when(
          loading: () => const _HelpLoadingState(),
          error: (error, _) => _HelpErrorState(
            code: _helpErrorCode(error),
            onRetry: () => ref.invalidate(helpCenterCatalogProvider),
          ),
          data: _buildCatalog,
        ),
      ],
    );
  }

  Widget _buildCatalog(HelpCenterCatalog catalog) {
    final visibleArticles = catalog.articles
        .where((article) {
          final groupMatches =
              _selectedGroupId == null || article.groupId == _selectedGroupId;
          return groupMatches && article.matches(_query);
        })
        .toList(growable: false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _HelpEntryList(
          softwareCount: catalog.articlesFor(helpSoftwareGroupId).length,
          recordingCardCount: catalog
              .articlesFor(helpRecordingCardGroupId)
              .length,
          onSoftware: () => _selectGroup(helpSoftwareGroupId),
          onRecordingCard: () => _selectGroup(helpRecordingCardGroupId),
          onCustomerService: () => context.push('/help/customer-service'),
          onBug: _showBugReportDemo,
        ),
        const SizedBox(height: 20),
        Container(key: _articleListKey, child: const V3SectionTitle('查找帮助')),
        const SizedBox(height: 10),
        TextField(
          key: const ValueKey('help-search-input'),
          controller: _searchController,
          contextMenuBuilder: V3TextEditing.buildContextMenu,
          onChanged: (value) => setState(() => _query = value),
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: '搜索功能或问题',
            prefixIcon: const Icon(Icons.search_rounded),
            suffixIcon: _query.isEmpty
                ? null
                : IconButton(
                    key: const ValueKey('help-search-clear'),
                    tooltip: '清除搜索',
                    onPressed: () {
                      FocusManager.instance.primaryFocus?.unfocus();
                      _searchController.clear();
                      setState(() => _query = '');
                    },
                    icon: const Icon(Icons.close_rounded),
                  ),
          ),
        ),
        const SizedBox(height: 10),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              ChoiceChip(
                key: const ValueKey('help-group-all'),
                label: const Text('全部'),
                selected: _selectedGroupId == null,
                onSelected: (_) => setState(() => _selectedGroupId = null),
              ),
              for (final category in catalog.categories) ...[
                const SizedBox(width: 8),
                ChoiceChip(
                  key: ValueKey('help-group-${category.id}'),
                  label: Text(category.title),
                  selected: _selectedGroupId == category.id,
                  onSelected: (_) =>
                      setState(() => _selectedGroupId = category.id),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        if (visibleArticles.isEmpty)
          const _HelpEmptyState()
        else
          V3GroupedList(
            children: [
              for (final article in visibleArticles)
                _HelpArticleRow(
                  article: article,
                  category: catalog.categoryFor(article.groupId),
                  onTap: () => context.push('/help/article/${article.id}'),
                ),
            ],
          ),
      ],
    );
  }

  void _selectGroup(String groupId) {
    setState(() {
      _selectedGroupId = groupId;
      _query = '';
    });
    _searchController.clear();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = _articleListKey.currentContext;
      if (target != null) {
        Scrollable.ensureVisible(
          target,
          duration: V3MotionTokens.pageTravel,
          curve: Curves.easeOutCubic,
          alignment: .08,
        );
      }
    });
  }

  Future<void> _showBugReportDemo() async {
    final request = await showDialog<ProfileBugReportRequest>(
      context: context,
      builder: (context) => const _HelpBugReportDialog(),
    );
    if (!mounted || request == null) return;
    final result = await ref
        .read(helpCenterSupportControllerProvider)
        .submitBug(request);
    if (!mounted) return;
    showV3Snack(
      context,
      result.ok
          ? 'Bug 已提交'
          : '提交失败：${result.errorCode ?? 'PROFILE_BUG_SUBMIT_FAILED'}',
    );
  }
}

class V3HelpArticlePage extends ConsumerStatefulWidget {
  const V3HelpArticlePage({required this.articleId, super.key});

  final String articleId;

  @override
  ConsumerState<V3HelpArticlePage> createState() => _V3HelpArticlePageState();
}

class _V3HelpArticlePageState extends ConsumerState<V3HelpArticlePage> {
  final ScrollController _scrollController = ScrollController();
  final Map<int, GlobalKey> _headingKeys = <int, GlobalKey>{};

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final article = ref.watch(helpArticleProvider(widget.articleId));
    return article.when(
      loading: () => const V3PageScaffold(
        title: '帮助文章',
        fallbackRoute: '/help',
        children: [_HelpLoadingState()],
      ),
      error: (error, _) => V3PageScaffold(
        title: '帮助文章',
        fallbackRoute: '/help',
        children: [
          _HelpErrorState(
            code: _helpErrorCode(error),
            onRetry: () =>
                ref.invalidate(helpArticleProvider(widget.articleId)),
          ),
        ],
      ),
      data: _buildArticle,
    );
  }

  Widget _buildArticle(HelpArticle article) {
    final colors = HuahuoV3Theme.tokensOf(context);
    _headingKeys.removeWhere(
      (line, _) => !article.flattenedSections.any(
        (section) => section.lineIndex == line,
      ),
    );
    for (final section in article.flattenedSections) {
      _headingKeys.putIfAbsent(section.lineIndex, GlobalKey.new);
    }
    return V3PageScaffold(
      title: article.metadata.title,
      fallbackRoute: '/help',
      scrollController: _scrollController,
      children: [
        Text(
          article.metadata.summary,
          style: TextStyle(color: colors.muted, fontSize: 14, height: 1.5),
        ),
        if (article.sections.isNotEmpty) ...[
          const SizedBox(height: 16),
          _HelpArticleDirectory(
            sections: article.sections,
            onOpen: _scrollToSection,
          ),
        ],
        const SizedBox(height: 20),
        Divider(height: 1, color: colors.line),
        const SizedBox(height: 20),
        _HelpMarkdownBody(article: article, headingKeysByLine: _headingKeys),
      ],
    );
  }

  void _scrollToSection(V3MarkdownOutlineNode section) {
    final target = _headingKeys[section.lineIndex]?.currentContext;
    if (target == null) return;
    Scrollable.ensureVisible(
      target,
      duration: V3MotionTokens.settled,
      curve: Curves.easeOutCubic,
      alignment: .06,
    );
  }
}

class V3CustomerServicePage extends StatelessWidget {
  const V3CustomerServicePage({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return V3PageScaffold(
      title: '联系客服',
      fallbackRoute: '/help',
      children: [
        Center(
          child: Semantics(
            label: '客服二维码',
            image: true,
            child: Container(
              key: const ValueKey('help-customer-qr-frame'),
              width: 220,
              height: 220,
              padding: const EdgeInsets.all(18),
              color: Colors.white,
              child: Image.asset(
                helpCustomerServiceQrAssetPath,
                fit: BoxFit.contain,
                filterQuality: FilterQuality.none,
                errorBuilder: (context, error, stackTrace) => Center(
                  child: Text(
                    '客服二维码资源待更新',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: HuahuoV3Theme.contrastingForeground(
                        colors.muted,
                        background: Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _HelpEntryList extends StatelessWidget {
  const _HelpEntryList({
    required this.softwareCount,
    required this.recordingCardCount,
    required this.onSoftware,
    required this.onRecordingCard,
    required this.onCustomerService,
    required this.onBug,
  });

  final int softwareCount;
  final int recordingCardCount;
  final VoidCallback onSoftware;
  final VoidCallback onRecordingCard;
  final VoidCallback onCustomerService;
  final VoidCallback onBug;

  @override
  Widget build(BuildContext context) => V3GroupedList(
    children: [
      _HelpHomeEntry(
        key: const ValueKey('help-entry-manual'),
        icon: Icons.menu_book_outlined,
        title: '软件使用说明书',
        subtitle: '$softwareCount 篇离线说明',
        onTap: onSoftware,
      ),
      _HelpHomeEntry(
        key: const ValueKey('help-entry-recording-card'),
        icon: Icons.mic_none_rounded,
        title: '录音卡使用指南',
        subtitle: '$recordingCardCount 篇操作说明',
        onTap: onRecordingCard,
      ),
      _HelpHomeEntry(
        key: const ValueKey('help-entry-customer-service'),
        icon: Icons.headset_mic_outlined,
        title: '联系客服',
        subtitle: '查看客服二维码',
        onTap: onCustomerService,
      ),
      _HelpHomeEntry(
        key: const ValueKey('help-upload-bug'),
        icon: Icons.bug_report_outlined,
        title: '上传 Bug',
        subtitle: '不上传截图',
        onTap: onBug,
      ),
    ],
  );
}

class _HelpHomeEntry extends StatelessWidget {
  const _HelpHomeEntry({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    super.key,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return V3GroupedListTile(
      leading: Icon(icon),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: onTap,
    );
  }
}

class _HelpArticleRow extends StatelessWidget {
  const _HelpArticleRow({
    required this.article,
    required this.category,
    required this.onTap,
  });

  final HelpArticleSummary article;
  final HelpCenterCategory? category;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return V3GroupedListTile(
      onTap: onTap,
      leading: Icon(
        article.groupId == helpRecordingCardGroupId
            ? Icons.mic_none_rounded
            : Icons.description_outlined,
      ),
      title: Text(article.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${category?.title ?? '帮助'} · ${article.summary}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: const Icon(Icons.chevron_right_rounded),
    );
  }
}

class _HelpArticleDirectory extends StatefulWidget {
  const _HelpArticleDirectory({required this.sections, required this.onOpen});

  final List<V3MarkdownOutlineNode> sections;
  final ValueChanged<V3MarkdownOutlineNode> onOpen;

  @override
  State<_HelpArticleDirectory> createState() => _HelpArticleDirectoryState();
}

class _HelpArticleDirectoryState extends State<_HelpArticleDirectory> {
  late final Set<String> _expanded = <String>{
    for (final section in widget.sections)
      if (section.children.isNotEmpty) section.id,
  };

  @override
  Widget build(BuildContext context) => V3Card(
    glass: false,
    padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(8, 0, 8, 6),
          child: Text('目录', style: TextStyle(fontWeight: FontWeight.w700)),
        ),
        for (final section in widget.sections) _buildSection(section, depth: 0),
      ],
    ),
  );

  Widget _buildSection(V3MarkdownOutlineNode section, {required int depth}) {
    final expanded = _expanded.contains(section.id);
    return Column(
      key: ValueKey('help-outline-${section.id}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.only(left: depth * 14.0),
          child: Row(
            children: [
              if (section.children.isNotEmpty)
                IconButton(
                  key: ValueKey('help-outline-toggle-${section.id}'),
                  tooltip: expanded
                      ? '收起${section.title}'
                      : '展开${section.title}',
                  constraints: const BoxConstraints.tightFor(
                    width: 44,
                    height: 44,
                  ),
                  onPressed: () => setState(() {
                    if (expanded) {
                      _expanded.remove(section.id);
                    } else {
                      _expanded.add(section.id);
                    }
                  }),
                  icon: V3DisclosureChevron(expanded: expanded, size: 19),
                )
              else
                const SizedBox(width: 44, height: 44),
              Expanded(
                child: InkWell(
                  onTap: () => widget.onOpen(section),
                  borderRadius: BorderRadius.circular(6),
                  child: SizedBox(
                    height: 44,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        section.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: section.level == 1
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        if (expanded)
          for (final child in section.children)
            _buildSection(child, depth: depth + 1),
      ],
    );
  }
}

class _HelpMarkdownBody extends StatelessWidget {
  const _HelpMarkdownBody({
    required this.article,
    required this.headingKeysByLine,
  });

  final HelpArticle article;
  final Map<int, GlobalKey> headingKeysByLine;

  @override
  Widget build(BuildContext context) => V3AssistantReplyMarkdown(
    source: article.markdown,
    headingKeysByLine: headingKeysByLine,
    imageBuilder: (context, alt, source) {
      final match = _helpAssetImageSourcePattern.firstMatch(source);
      if (match == null) return null;
      final image = article.imageFor(match.group(1)!);
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Semantics(
          label: image?.alt ?? '帮助图片',
          image: true,
          child: image == null
              ? const _HelpInlineImageError()
              : Image.asset(
                  image.assetPath,
                  key: ValueKey('help-article-image-${image.id}'),
                  fit: BoxFit.contain,
                  errorBuilder: (context, error, stackTrace) =>
                      const _HelpInlineImageError(),
                ),
        ),
      );
    },
  );
}

class _HelpInlineImageError extends StatelessWidget {
  const _HelpInlineImageError();

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return SizedBox(
      height: 96,
      child: Center(
        child: Text(
          'HELP_IMAGE_MISSING',
          style: TextStyle(color: colors.muted, fontSize: 12),
        ),
      ),
    );
  }
}

final _helpAssetImageSourcePattern = RegExp(r'^asset:([a-z][a-z0-9-]{1,63})$');

class _HelpBugReportDialog extends StatefulWidget {
  const _HelpBugReportDialog();

  @override
  State<_HelpBugReportDialog> createState() => _HelpBugReportDialogState();
}

class _HelpBugReportDialogState extends State<_HelpBugReportDialog> {
  final TextEditingController _description = TextEditingController();
  int _screenshotCount = 0;
  bool _includeDiagnostics = true;
  String? _error;

  @override
  void dispose() {
    _description.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return V3GlassDialogFrame(
      title: '上传 Bug',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '不会上传真实截图或发送服务器工单。',
            style: TextStyle(color: colors.muted, fontSize: 12.5),
          ),
          const SizedBox(height: 10),
          TextField(
            key: const ValueKey('bug-report-description'),
            controller: _description,
            contextMenuBuilder: V3TextEditing.buildContextMenu,
            autofocus: true,
            minLines: 3,
            maxLines: 5,
            maxLength: 500,
            decoration: InputDecoration(labelText: '问题描述', errorText: _error),
            onChanged: (_) => setState(() => _error = null),
          ),
          OutlinedButton.icon(
            key: const ValueKey('bug-report-screenshot'),
            onPressed: _screenshotCount >= 3
                ? null
                : () => setState(() => _screenshotCount += 1),
            icon: const Icon(Icons.add_photo_alternate_outlined),
            label: Text(
              _screenshotCount == 0
                  ? '添加截图槽（最多 3 个）'
                  : '已添加 $_screenshotCount / 3',
            ),
          ),
          if (_screenshotCount > 0) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (var index = 0; index < _screenshotCount; index++)
                  Semantics(
                    label: '移除第 ${index + 1} 个截图槽',
                    button: true,
                    child: InkWell(
                      key: ValueKey('bug-report-remove-screenshot-$index'),
                      onTap: () => setState(() => _screenshotCount -= 1),
                      borderRadius: BorderRadius.circular(6),
                      child: Container(
                        width: 52,
                        height: 52,
                        decoration: BoxDecoration(
                          color: colors.surfaceMuted,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Icon(Icons.close_rounded, size: 20),
                      ),
                    ),
                  ),
              ],
            ),
          ],
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: _includeDiagnostics,
            title: const Text('附加脱敏诊断信息'),
            onChanged: (value) =>
                setState(() => _includeDiagnostics = value ?? false),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('提交')),
      ],
    );
  }

  void _submit() {
    final description = _description.text.trim();
    if (description.runes.length < 5) {
      setState(() => _error = '请至少描述 5 个字符');
      return;
    }
    Navigator.of(context).pop(
      ProfileBugReportRequest(
        description: description,
        screenshotCount: _screenshotCount,
        includeDiagnostics: _includeDiagnostics,
      ),
    );
  }
}

class _HelpLoadingState extends StatelessWidget {
  const _HelpLoadingState();

  @override
  Widget build(BuildContext context) => const SizedBox(
    height: 180,
    child: Center(
      child: SizedBox.square(
        dimension: 24,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
    ),
  );
}

class _HelpErrorState extends StatelessWidget {
  const _HelpErrorState({required this.code, required this.onRetry});

  final String code;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return V3Card(
      glass: false,
      child: Column(
        children: [
          const Icon(Icons.error_outline_rounded, size: 30),
          const SizedBox(height: 10),
          const Text(
            '离线帮助内容暂时无法读取',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(code, style: TextStyle(color: colors.muted, fontSize: 12)),
          const SizedBox(height: 12),
          V3OutlineButton(label: '重试', onPressed: onRetry),
        ],
      ),
    );
  }
}

class _HelpEmptyState extends StatelessWidget {
  const _HelpEmptyState();

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32),
      child: Center(
        child: Text('没有找到匹配的帮助内容', style: TextStyle(color: colors.muted)),
      ),
    );
  }
}

String _fallbackRoute(WidgetRef ref) {
  final session = ref.watch(sessionStoreProvider).state;
  return session.authState == SessionAuthState.authenticated ? '/v3' : '/auth';
}

String _helpErrorCode(Object error) =>
    error is HelpCenterLoadException ? error.code : 'HELP_CONTENT_UNAVAILABLE';
