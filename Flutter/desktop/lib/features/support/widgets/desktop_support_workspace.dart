import 'dart:async';

import 'package:flutter/material.dart';
import 'package:huahuo_product/huahuo_product.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../shared/markdown/markdown_preview.dart';

const _customerServiceQrAsset =
    'assets/support/help/zh-CN/images/customer_service_qr.png';

enum _SupportSection { help, userAgreement, privacyPolicy }

class DesktopSupportWorkspace extends StatefulWidget {
  const DesktopSupportWorkspace({required this.repository, super.key});

  final ProductSupportRepository repository;

  @override
  State<DesktopSupportWorkspace> createState() =>
      _DesktopSupportWorkspaceState();
}

class _DesktopSupportWorkspaceState extends State<DesktopSupportWorkspace> {
  late ProductSupportController _controller;
  final TextEditingController _searchController = TextEditingController();
  _SupportSection _section = _SupportSection.help;
  String? _lastArticleId;

  @override
  void initState() {
    super.initState();
    _createController();
    unawaited(_controller.load());
  }

  @override
  void didUpdateWidget(covariant DesktopSupportWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.repository != widget.repository) {
      _controller.dispose();
      _createController();
      unawaited(_controller.load());
    }
  }

  void _createController() {
    _controller = ProductSupportController(widget.repository)
      ..addListener(_refresh);
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _searchController.dispose();
    _controller
      ..removeListener(_refresh)
      ..dispose();
    super.dispose();
  }

  Future<void> _selectSection(_SupportSection section) async {
    setState(() => _section = section);
    switch (section) {
      case _SupportSection.help:
        _controller.closeContent();
      case _SupportSection.userAgreement:
        await _controller.openLegal(ProductLegalDocumentKind.userAgreement);
      case _SupportSection.privacyPolicy:
        await _controller.openLegal(ProductLegalDocumentKind.privacyPolicy);
    }
  }

  Future<void> _openArticle(String articleId) async {
    _lastArticleId = articleId;
    await _controller.openArticle(articleId);
  }

  Future<void> _retryContent() async {
    switch (_section) {
      case _SupportSection.help:
        final articleId = _lastArticleId;
        if (articleId != null) await _controller.openArticle(articleId);
      case _SupportSection.userAgreement:
        await _controller.openLegal(ProductLegalDocumentKind.userAgreement);
      case _SupportSection.privacyPolicy:
        await _controller.openLegal(ProductLegalDocumentKind.privacyPolicy);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = _controller.state;
    final colors = Theme.of(context).colorScheme;
    return ColoredBox(
      key: const ValueKey<String>('desktop-support-workspace'),
      color: colors.surface,
      child: Column(
        children: [
          _SupportToolbar(
            section: _section,
            onSectionChanged: (value) => unawaited(_selectSection(value)),
            onRefresh: state.status == ProductSupportStatus.loading
                ? null
                : () => unawaited(_controller.load()),
            onCustomerService: _showCustomerService,
          ),
          const Divider(height: 1),
          Expanded(child: _buildBody(state)),
        ],
      ),
    );
  }

  Widget _buildBody(ProductSupportState state) {
    if (state.status == ProductSupportStatus.loading && state.catalog == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.status == ProductSupportStatus.failure && state.catalog == null) {
      return _SupportFailure(
        message: state.errorMessage ?? '帮助内容读取失败',
        canRetry: state.retryable,
        onRetry: () => unawaited(_controller.load()),
      );
    }
    if (_section != _SupportSection.help) return _buildReader(state);
    return LayoutBuilder(
      builder: (context, constraints) {
        final contentOpen = state.article != null || state.contentLoading;
        if (constraints.maxWidth < 760 && contentOpen) {
          return _buildReader(state, showBack: true);
        }
        final browser = _buildHelpBrowser(state);
        if (constraints.maxWidth < 760) return browser;
        return Row(
          children: [
            SizedBox(width: 380, child: browser),
            const VerticalDivider(width: 1),
            Expanded(
              child: contentOpen
                  ? _buildReader(state)
                  : const _SupportWelcome(),
            ),
          ],
        );
      },
    );
  }

  Widget _buildHelpBrowser(ProductSupportState state) {
    final catalog = state.catalog;
    if (catalog == null) return const SizedBox.shrink();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 10),
          child: SearchBar(
            key: const ValueKey<String>('support-search'),
            controller: _searchController,
            leading: const Icon(LucideIcons.search, size: 18),
            hintText: '搜索使用指南',
            onChanged: _controller.setQuery,
            trailing: [
              if (_searchController.text.isNotEmpty)
                IconButton(
                  tooltip: '清除搜索',
                  onPressed: () {
                    _searchController.clear();
                    _controller.setQuery('');
                  },
                  icon: const Icon(LucideIcons.x, size: 18),
                ),
            ],
          ),
        ),
        SizedBox(
          height: 44,
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 4),
            scrollDirection: Axis.horizontal,
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: FilterChip(
                  label: const Text('全部'),
                  selected: state.categoryId == null,
                  onSelected: (_) => _controller.selectCategory(null),
                ),
              ),
              for (final category in catalog.categories)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: FilterChip(
                    label: Text(category.title),
                    selected: state.categoryId == category.id,
                    onSelected: (_) => _controller.selectCategory(category.id),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: state.filteredArticles.isEmpty
              ? const Center(child: Text('没有匹配的帮助文章'))
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(10, 8, 10, 18),
                  itemCount: state.filteredArticles.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final article = state.filteredArticles[index];
                    return Material(
                      color: Colors.transparent,
                      child: ListTile(
                        key: ValueKey<String>('support-article-${article.id}'),
                        title: Text(article.title),
                        subtitle: Text(
                          article.summary,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: const Icon(
                          LucideIcons.chevronRight,
                          size: 18,
                        ),
                        onTap: () => unawaited(_openArticle(article.id)),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildReader(ProductSupportState state, {bool showBack = false}) {
    if (state.contentLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.errorMessage != null) {
      return _SupportFailure(
        message: state.errorMessage!,
        canRetry: state.retryable,
        onRetry: () => unawaited(_retryContent()),
        onBack: showBack ? _controller.closeContent : null,
      );
    }
    final article = state.article;
    final legal = state.legalDocument;
    final title = article?.metadata.title ?? legal?.title;
    final markdown = article?.markdown ?? legal?.markdown;
    if (title == null || markdown == null) {
      return const Center(child: Text('正在准备内容...'));
    }
    return Column(
      children: [
        if (showBack)
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: TextButton.icon(
                key: const ValueKey<String>('support-reader-back'),
                onPressed: _controller.closeContent,
                icon: const Icon(LucideIcons.arrowLeft, size: 16),
                label: const Text('帮助列表'),
              ),
            ),
          ),
        Expanded(
          child: MarkdownPreviewPane(
            source: MarkdownPreviewSource(title: title, markdown: markdown),
            preferences: MarkdownPreviewPreferences.defaults,
          ),
        ),
      ],
    );
  }

  Future<void> _showCustomerService() => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('联系客服'),
      content: SizedBox(
        width: 300,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset(
              _customerServiceQrAsset,
              key: const ValueKey<String>('support-customer-service-qr'),
              width: 220,
              height: 220,
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) => const SizedBox(
                width: 220,
                height: 220,
                child: Center(child: Text('客服二维码读取失败')),
              ),
            ),
            const SizedBox(height: 12),
            const Text('使用微信扫描二维码联系客服'),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
}

class _SupportToolbar extends StatelessWidget {
  const _SupportToolbar({
    required this.section,
    required this.onSectionChanged,
    required this.onRefresh,
    required this.onCustomerService,
  });

  final _SupportSection section;
  final ValueChanged<_SupportSection> onSectionChanged;
  final VoidCallback? onRefresh;
  final VoidCallback onCustomerService;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 62,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18),
      child: Row(
        children: [
          const Icon(LucideIcons.circleHelp, size: 18),
          const SizedBox(width: 10),
          Text('帮助中心', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(width: 20),
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SegmentedButton<_SupportSection>(
                  segments: const [
                    ButtonSegment(
                      value: _SupportSection.help,
                      label: Text('使用指南'),
                    ),
                    ButtonSegment(
                      value: _SupportSection.userAgreement,
                      label: Text('用户协议'),
                    ),
                    ButtonSegment(
                      value: _SupportSection.privacyPolicy,
                      label: Text('隐私政策'),
                    ),
                  ],
                  selected: {section},
                  onSelectionChanged: (value) => onSectionChanged(value.single),
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: '刷新帮助内容',
            onPressed: onRefresh,
            icon: const Icon(LucideIcons.rotateCw, size: 18),
          ),
          FilledButton.tonalIcon(
            key: const ValueKey<String>('support-customer-service'),
            onPressed: onCustomerService,
            icon: const Icon(LucideIcons.messageCircle, size: 16),
            label: const Text('联系客服'),
          ),
        ],
      ),
    ),
  );
}

class _SupportWelcome extends StatelessWidget {
  const _SupportWelcome();

  @override
  Widget build(BuildContext context) => const Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(LucideIcons.bookOpen, size: 34),
        SizedBox(height: 12),
        Text('选择一篇使用指南开始阅读'),
      ],
    ),
  );
}

class _SupportFailure extends StatelessWidget {
  const _SupportFailure({
    required this.message,
    required this.canRetry,
    required this.onRetry,
    this.onBack,
  });

  final String message;
  final bool canRetry;
  final VoidCallback onRetry;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(LucideIcons.triangleAlert, size: 30),
        const SizedBox(height: 12),
        Text(message),
        const SizedBox(height: 12),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (onBack != null)
              TextButton.icon(
                onPressed: onBack,
                icon: const Icon(LucideIcons.arrowLeft, size: 16),
                label: const Text('帮助列表'),
              ),
            if (canRetry)
              FilledButton.tonalIcon(
                key: const ValueKey<String>('support-retry'),
                onPressed: onRetry,
                icon: const Icon(LucideIcons.rotateCw, size: 16),
                label: const Text('重试'),
              ),
          ],
        ),
      ],
    ),
  );
}
