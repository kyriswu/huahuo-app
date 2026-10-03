import 'package:huahuoai_app/shared/markdown/v3_markdown.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_client.dart';
import '../../../shared/ui_v3/v3_components.dart';
import '../../../shared/ui_v3/v3_text_editing.dart';
import '../application/mobile_book_work_contract.dart';
import '../application/mobile_book_work_controller.dart';

Future<void> showMobileBookWorkSheet(BuildContext context) {
  return showV3GlassBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showHandle: false,
    builder: (context) => const FractionallySizedBox(
      heightFactor: .9,
      child: MobileBookWorkSheet(),
    ),
  );
}

class MobileBookWorkSheet extends ConsumerStatefulWidget {
  const MobileBookWorkSheet({super.key});

  @override
  ConsumerState<MobileBookWorkSheet> createState() =>
      _MobileBookWorkSheetState();
}

class _MobileBookWorkSheetState extends ConsumerState<MobileBookWorkSheet> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final controller = ref.read(mobileBookWorkControllerProvider);
      if (controller.status == MobileBookWorkStatus.idle) controller.load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(mobileBookWorkControllerProvider);
    return DefaultTabController(
      length: 2,
      child: Material(
        key: const ValueKey<String>('mobile-book-work-sheet'),
        color: Theme.of(context).colorScheme.surface,
        child: Column(
          children: [
            const SizedBox(height: 8),
            Container(
              width: 38,
              height: 4,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            SizedBox(
              height: 52,
              child: Row(
                children: [
                  const SizedBox(width: 16),
                  const Icon(Icons.menu_book_rounded, size: 20),
                  const SizedBox(width: 9),
                  const Expanded(
                    child: Text(
                      '典藏与创作',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    key: const ValueKey<String>('mobile-book-work-refresh'),
                    tooltip: '刷新',
                    onPressed: controller.loading
                        ? null
                        : () {
                            final selected = controller.selectedWork;
                            if (selected != null) {
                              controller.discardWorkMutations(selected.workId);
                            }
                            controller.load();
                          },
                    icon: const Icon(Icons.refresh_rounded),
                  ),
                  V3CloseButton(onPressed: () => Navigator.of(context).pop()),
                  const SizedBox(width: 4),
                ],
              ),
            ),
            const TabBar(
              tabs: [
                Tab(text: '典藏长文'),
                Tab(text: '创作历史'),
              ],
            ),
            Expanded(child: _buildContent(controller)),
          ],
        ),
      ),
    );
  }

  Widget _buildContent(MobileBookWorkController controller) {
    switch (controller.status) {
      case MobileBookWorkStatus.idle:
      case MobileBookWorkStatus.loading:
        return const Center(
          key: ValueKey<String>('mobile-book-work-loading'),
          child: CircularProgressIndicator(),
        );
      case MobileBookWorkStatus.unavailable:
      case MobileBookWorkStatus.failure:
        return _BookWorkFailure(
          key: const ValueKey<String>('mobile-book-work-error'),
          message: _errorMessage(controller.errorCode),
          onRetry: controller.load,
        );
      case MobileBookWorkStatus.ready:
        return TabBarView(
          children: [_buildBook(controller), _buildWorks(controller)],
        );
    }
  }

  Widget _buildBook(MobileBookWorkController controller) {
    final book = controller.book;
    if (book == null || book.sections.isEmpty) {
      return const Center(
        key: ValueKey<String>('mobile-book-empty'),
        child: Text('典藏长文尚无章节'),
      );
    }
    return ListView.separated(
      key: const ValueKey<String>('mobile-book-sections'),
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 28),
      itemCount: book.sections.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final section = book.sections[index];
        final readable = section.parts
            .where((part) => part.currentRevisionId != null)
            .toList(growable: false);
        return Padding(
          key: ValueKey<String>('mobile-book-section-${section.sectionKey}'),
          padding: const EdgeInsets.symmetric(vertical: 15),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    '${section.ordinal + 1}'.padLeft(2, '0'),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      section.title,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Text(
                    _groupLabel(section.group),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
              if (readable.isNotEmpty) ...[
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final head in readable)
                      OutlinedButton(
                        key: ValueKey<String>(
                          'mobile-book-section-${section.sectionKey}-${head.part}',
                        ),
                        onPressed: () =>
                            _openBookPart(controller, section, head.part),
                        child: Text(_partLabel(head.part)),
                      ),
                  ],
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _buildWorks(MobileBookWorkController controller) {
    final selected = controller.selectedWork;
    if (selected != null) return _buildWorkDetail(controller, selected);
    if (controller.works.isEmpty) {
      return const Center(
        key: ValueKey<String>('mobile-work-empty'),
        child: Text('暂无创作历史'),
      );
    }
    return ListView.separated(
      key: const ValueKey<String>('mobile-work-list'),
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: controller.works.length,
      separatorBuilder: (_, __) => const Divider(height: 1, indent: 18),
      itemBuilder: (context, index) {
        final work = controller.works[index];
        return ListTile(
          key: ValueKey<String>('mobile-work-${work.workId}'),
          title: Text(work.title),
          subtitle: Text(_lifecycleLabel(work.lifecycle)),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => controller.selectWork(work.workId),
        );
      },
    );
  }

  Widget _buildWorkDetail(
    MobileBookWorkController controller,
    SharedWork work,
  ) {
    final mutating = controller.isMutating(work.workId);
    final hasRaw = work.parts.any(
      (head) => head.part == 'raw' && head.currentRevisionId != null,
    );
    return ListView(
      key: ValueKey<String>('mobile-work-detail-${work.workId}'),
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 28),
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: V3NavigationBackButton(
            key: const ValueKey<String>('mobile-work-detail-back'),
            tooltip: '返回创作历史',
            onPressed: () => _returnToWorkList(controller),
          ),
        ),
        Text(
          work.title,
          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 6),
        Text(
          _lifecycleLabel(work.lifecycle),
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 20),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final head in work.parts)
              OutlinedButton(
                key: ValueKey<String>(
                  'mobile-work-${work.workId}-${head.part}',
                ),
                onPressed: head.currentRevisionId == null
                    ? null
                    : () => _openWorkPart(controller, work, head.part),
                child: Text(_partLabel(head.part)),
              ),
          ],
        ),
        const SizedBox(height: 28),
        FilledButton.icon(
          key: const ValueKey<String>('mobile-work-complete'),
          onPressed: work.lifecycle == 'active' && !mutating
              ? () => _completeWork(controller, work)
              : null,
          icon: const Icon(Icons.check_circle_outline_rounded),
          label: Text(mutating ? '提交中' : '完成创作'),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          key: const ValueKey<String>('mobile-work-promote'),
          onPressed: hasRaw && !mutating
              ? () => _promoteWork(controller, work)
              : null,
          icon: const Icon(Icons.library_add_outlined),
          label: Text(mutating ? '提交中' : '收录到典藏长文'),
        ),
        if (controller.errorCode != null) ...[
          const SizedBox(height: 12),
          Text(
            _errorMessage(controller.errorCode),
            key: const ValueKey<String>('mobile-work-action-error'),
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
      ],
    );
  }

  void _returnToWorkList(MobileBookWorkController controller) {
    final selected = controller.selectedWork;
    if (selected == null) return;
    controller.discardWorkMutations(selected.workId);
    controller.clearSelection();
  }

  Future<void> _openBookPart(
    MobileBookWorkController controller,
    SharedBookSection section,
    String part,
  ) async {
    final result = await controller.openBookPart(section: section, part: part);
    if (!mounted) return;
    await _showPart(
      title: '${section.title} · ${_partLabel(part)}',
      result: result,
    );
  }

  Future<void> _openWorkPart(
    MobileBookWorkController controller,
    SharedWork work,
    String part,
  ) async {
    final result = await controller.openWorkPart(work: work, part: part);
    if (!mounted) return;
    await _showPart(
      title: '${work.title} · ${_partLabel(part)}',
      result: result,
    );
  }

  Future<void> _showPart({
    required String title,
    required MobileBookWorkResult<SharedManagedPartRevision> result,
  }) async {
    final revision = result.data;
    if (!result.isSuccess || revision == null) {
      _showMessage(_errorMessage(result.errorCode));
      return;
    }
    await showV3GlassBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => FractionallySizedBox(
        heightFactor: .84,
        child: Material(
          key: const ValueKey<String>('mobile-book-work-part-preview'),
          color: Theme.of(context).colorScheme.surface,
          child: Column(
            children: [
              ListTile(
                title: Text(title),
                subtitle: Text('版本 ${revision.revision}'),
                trailing: V3CloseButton(
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(22, 20, 22, 32),
                  child: SelectionArea(
                    contextMenuBuilder: V3TextEditing.buildSelectionContextMenu,
                    child: V3AssistantReplyMarkdown(
                      source: revision.contentMarkdown,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _completeWork(
    MobileBookWorkController controller,
    SharedWork work,
  ) async {
    final result = await controller.completeWork(work);
    if (!mounted) return;
    if (!result.isSuccess) {
      _showMessage(_errorMessage(result.errorCode));
      return;
    }
    _showMessage('创作已完成');
    await controller.load();
  }

  Future<void> _promoteWork(
    MobileBookWorkController controller,
    SharedWork work,
  ) async {
    final result = await controller.promoteToBook(work);
    if (!mounted) return;
    if (!result.isSuccess) {
      _showMessage(_errorMessage(result.errorCode));
      return;
    }
    _showMessage('已收录到典藏长文');
    await controller.load();
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

final class _BookWorkFailure extends StatelessWidget {
  const _BookWorkFailure({
    required this.message,
    required this.onRetry,
    super.key,
  });

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 14),
            TextButton.icon(
              key: const ValueKey<String>('mobile-book-work-retry'),
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}

String _partLabel(String part) => switch (part) {
  'raw' => '正文',
  'outline' => '纲要',
  'germination' => '发芽',
  _ => part,
};

String _groupLabel(String group) => switch (group) {
  'front_matter' => '前言',
  'chapters' => '正文',
  'back_matter' => '附录',
  _ => group,
};

String _lifecycleLabel(String lifecycle) => switch (lifecycle) {
  'active' => '进行中',
  'completed' => '已完成',
  'deleted' => '已删除',
  _ => lifecycle,
};

String _errorMessage(String? code) => switch (code) {
  'BOOK_WORK_ACCOUNT_REQUIRED' => '登录并完成 Workspace 初始化后可查看',
  'BOOK_WORK_ACCOUNT_CHANGED' => '账号已变化，请重新打开',
  'BOOK_WORK_CURSOR_REPEATED' ||
  'BOOK_WORK_DUPLICATE_ID_CONFLICT' => '创作历史分页数据异常，请稍后重试',
  'HTTP_409' || 'HTTP_412' || 'PRECONDITION_FAILED' => '内容版本已变化，请刷新后重试',
  'BOOK_WORK_SERVICE_UNAVAILABLE' ||
  'API_BASE_URL_UNCONFIGURED' => '典藏与创作服务暂不可用',
  null => '请求失败，请稍后重试',
  _ => '请求失败（$code）',
};
