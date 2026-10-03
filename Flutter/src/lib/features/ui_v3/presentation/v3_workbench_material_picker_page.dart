import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/navigation/app_route_paths.dart';
import '../../../shared/theme/huahuo_v3_theme.dart';
import '../../../shared/ui_v3/v3_components.dart';
import '../../../shared/ui_v3/v3_text_editing.dart';
import '../../agent/application/mobile_agent_capability_controller.dart';
import '../../chat/domain/chat_models.dart';
import '../application/knowledge_library_controller.dart';
import '../application/workbench_generation_controller.dart';
import '../domain/feed_item_models.dart';
import '../domain/ui_v3_models.dart';

class V3WorkbenchMaterialPickerPage extends ConsumerStatefulWidget {
  const V3WorkbenchMaterialPickerPage({required this.purpose, super.key});

  final WorkbenchPurpose purpose;

  @override
  ConsumerState<V3WorkbenchMaterialPickerPage> createState() =>
      _V3WorkbenchMaterialPickerPageState();
}

class _V3WorkbenchMaterialPickerPageState
    extends ConsumerState<V3WorkbenchMaterialPickerPage> {
  bool _searchVisible = false;
  bool _handoffInProgress = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final controller = ref.read(workbenchGenerationControllerProvider);
      controller.startSelection(widget.purpose);
      unawaited(
        ref
            .read(mobileAgentCapabilityControllerProvider)
            .ensureFeature(_agentFeatureId),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(workbenchGenerationControllerProvider);
    final library = ref.watch(knowledgeLibraryControllerProvider);
    final capability = ref
        .watch(mobileAgentCapabilityControllerProvider)
        .accessFor(_agentFeatureId);
    final selectedNotes = <V3FeedItem>[
      for (final id in controller.selectedNoteIds)
        if (library.noteForId(id) case final note?) note,
    ];
    final selectedSourcesCanSynchronize =
        selectedNotes.length == controller.selectedCount &&
        selectedNotes.every((note) => !note.isReadOnly);
    final normalNotes = controller.normalNotes;
    final randomCandidates = normalNotes
        .where((note) => !note.isReadOnly)
        .toList(growable: false);
    final loading = library.loading && library.notes.isEmpty;
    final failed = library.loadErrorCode != null && library.notes.isEmpty;
    final empty = !loading && !failed && library.notes.isEmpty;

    return V3PageScaffold(
      title: widget.purpose.pickerTitle,
      subtitle: widget.purpose.pickerSubtitle,
      fallbackRoute: '/v3/workbench',
      trailing: IconButton(
        key: const ValueKey('workbench-asset-search-toggle'),
        tooltip: _searchVisible ? '关闭搜索' : '搜索资产',
        onPressed: () => setState(() {
          _searchVisible = !_searchVisible;
          if (!_searchVisible) {
            ref.read(workbenchGenerationControllerProvider).setQuery('');
          }
        }),
        icon: Icon(_searchVisible ? Icons.close_rounded : Icons.search_rounded),
      ),
      bottomBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '已选择 ${controller.selectedCount} 条笔记',
            style: TextStyle(color: HuahuoV3Theme.tokensOf(context).muted),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: V3OutlineButton(
                  key: const ValueKey('workbench-asset-random-select'),
                  label: '随机选择',
                  icon: Icons.shuffle_rounded,
                  enabled:
                      !loading &&
                      capability.isAvailable &&
                      randomCandidates.isNotEmpty,
                  onPressed: () => _selectRandomAssets(
                    context,
                    controller,
                    randomCandidates,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: V3PrimaryButton(
                  enabled:
                      controller.canGenerate &&
                      !loading &&
                      capability.isAvailable &&
                      selectedSourcesCanSynchronize &&
                      !_handoffInProgress,
                  busy: _handoffInProgress,
                  label: _handoffInProgress ? '正在打开...' : '上传',
                  onPressed: () => unawaited(
                    _openContextChat(context, controller, library, capability),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
      children: [
        if (!capability.isAvailable) ...[
          _PickerStateCard(
            title: _capabilityMessage(capability),
            actionLabel: '重新校验',
            onAction: () => unawaited(
              ref
                  .read(mobileAgentCapabilityControllerProvider)
                  .ensureFeature(_agentFeatureId, forceRefresh: true),
            ),
          ),
          const SizedBox(height: 16),
        ] else if (controller.selectedCount > 0 &&
            !selectedSourcesCanSynchronize) ...[
          const V3Card(child: Text('只可上传自己的资产；本地正文不会被直接发送。')),
          const SizedBox(height: 16),
        ],
        if (_searchVisible) ...[
          TextField(
            autofocus: true,
            contextMenuBuilder: V3TextEditing.buildContextMenu,
            onChanged: ref.read(workbenchGenerationControllerProvider).setQuery,
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search_rounded),
              hintText: '搜索资产标题或内容',
            ),
          ),
          const SizedBox(height: 16),
        ],
        if (loading)
          const Center(child: CircularProgressIndicator.adaptive())
        else if (failed)
          _PickerStateCard(
            title: '笔记加载失败',
            actionLabel: '重新加载',
            onAction: () =>
                ref.read(knowledgeLibraryControllerProvider).loadHotspots(),
          )
        else if (empty)
          _PickerStateCard(
            title: '记忆库还没有可用笔记',
            actionLabel: '前往 思想图谱',
            onAction: () => context.push(AppRoutePaths.home),
          )
        else ...[
          const V3SectionTitle('我的资产'),
          if (normalNotes.isEmpty)
            const V3Card(child: Text('当前筛选下没有普通笔记'))
          else
            for (var index = 0; index < normalNotes.length; index++) ...[
              _SelectableNoteRow(
                key: ValueKey<String>(
                  'workbench-selectable-asset-${normalNotes[index].id}',
                ),
                note: normalNotes[index],
                selected: controller.selectedNoteIds.contains(
                  normalNotes[index].id,
                ),
                onTap: () =>
                    _toggleNote(context, controller, normalNotes[index].id),
              ),
              if (index != normalNotes.length - 1)
                const Divider(height: 1, indent: 12),
            ],
        ],
      ],
    );
  }

  Future<void> _openContextChat(
    BuildContext context,
    WorkbenchGenerationController controller,
    KnowledgeLibraryController library,
    MobileAgentFeatureAccess capability,
  ) async {
    if (_handoffInProgress) return;
    if (!capability.isAvailable) {
      showV3Snack(context, _capabilityMessage(capability));
      return;
    }
    final selectedNotes = <V3FeedItem>[
      for (final id in controller.selectedNoteIds)
        if (library.noteForId(id) case final note?) note,
    ];
    if (selectedNotes.length != controller.selectedCount ||
        !selectedNotes.every((note) => !note.isReadOnly)) {
      showV3Snack(context, '只能上传自己的资产');
      return;
    }
    final skill = WorkbenchChatSkill.tryParse(widget.purpose.routeName);
    final chatContext = skill == null
        ? null
        : WorkbenchChatContext(
            skill: skill,
            materialIds: controller.selectedNoteIds,
          );
    if (chatContext == null || !chatContext.isUsable) {
      showV3Snack(context, '请先选择至少一条素材');
      return;
    }
    setState(() => _handoffInProgress = true);
    controller.consumeSelection();
    try {
      await context.push<void>(
        Uri(
          path: '/v3/feed/chat',
          queryParameters: <String, String>{
            'skill': chatContext.skill.routeValue,
            'materialIds': chatContext.materialIds.join(','),
            'analyzeAssets': '1',
          },
        ).toString(),
      );
    } finally {
      if (mounted) setState(() => _handoffInProgress = false);
    }
  }

  void _selectRandomAssets(
    BuildContext context,
    WorkbenchGenerationController controller,
    List<V3FeedItem> candidates,
  ) {
    if (candidates.isEmpty) {
      showV3Snack(context, '暂无可上传资产可供随机选择');
      return;
    }
    final random = Random();
    final shuffled = List<V3FeedItem>.of(candidates)..shuffle(random);
    final count =
        1 +
        random.nextInt(
          min(WorkbenchGenerationController.maxSelectedNotes, shuffled.length),
        );
    controller.replaceSelection(shuffled.take(count).map((note) => note.id));
    showV3Snack(context, '已随机选择 $count 条资产');
  }

  void _toggleNote(
    BuildContext context,
    WorkbenchGenerationController controller,
    String noteId,
  ) {
    if (controller.toggleNote(noteId)) return;
    showV3Snack(
      context,
      '每次最多选择 ${WorkbenchGenerationController.maxSelectedNotes} 条资产',
    );
  }

  String get _agentFeatureId => switch (widget.purpose) {
    WorkbenchPurpose.persona => 'workbench.persona',
    WorkbenchPurpose.lead => 'workbench.lead_content',
  };
}

String _capabilityMessage(MobileAgentFeatureAccess access) {
  if (access.status == MobileAgentFeatureStatus.loading ||
      access.status == MobileAgentFeatureStatus.idle) {
    return '正在校验当前账号的创作能力';
  }
  return switch (access.errorCode) {
    'AGENT_SESSION_REQUIRED' => '登录并选择工作空间后才能开始创作',
    'AGENT_WORKSPACE_RECOVERY_REQUIRED' => '工作区正在恢复，恢复完成后即可开始创作',
    'AGENT_WORKSPACE_CONTEXT_UNAVAILABLE' => '正在获取当前工作区，请稍后重试',
    'SKILL_SELECTION_NOT_CANDIDATE' ||
    'SKILL_INSTALLATION_REQUIRED' ||
    'SKILL_INSTALLATION_DISABLED' => '当前工作空间尚未启用该创作 Skill',
    _ => '当前创作能力不可用，请稍后重试',
  };
}

class _SelectableNoteRow extends StatelessWidget {
  const _SelectableNoteRow({
    super.key,
    required this.note,
    required this.selected,
    required this.onTap,
  });

  final V3FeedItem note;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final summary = note.summaryBody?.trim().isNotEmpty == true
        ? note.summaryBody!.trim()
        : note.rawBody.trim();
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (note.isHotspot) ...[
                          const Chip(
                            visualDensity: VisualDensity.compact,
                            label: Text('热点'),
                          ),
                          const SizedBox(width: 8),
                        ],
                        Expanded(
                          child: Text(
                            note.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 7),
                    Text(
                      summary,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: HuahuoV3Theme.tokensOf(context).muted,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${note.source.label} · ${_formatDate(note.updatedAt)}',
                      style: TextStyle(
                        fontSize: 12,
                        color: HuahuoV3Theme.tokensOf(context).muted,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Icon(
                selected ? Icons.check_circle_rounded : Icons.circle_outlined,
                color: selected
                    ? HuahuoV3Theme.tokensOf(context).ink
                    : HuahuoV3Theme.tokensOf(context).muted,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PickerStateCard extends StatelessWidget {
  const _PickerStateCard({
    required this.title,
    required this.actionLabel,
    required this.onAction,
  });

  final String title;
  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) => V3Card(
    child: Column(
      children: [
        Text(title),
        const SizedBox(height: 14),
        V3OutlineButton(label: actionLabel, onPressed: onAction),
      ],
    ),
  );
}

String _formatDate(DateTime value) =>
    '${value.year}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';
