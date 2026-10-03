import 'package:flutter/material.dart';

import '../../../shared/theme/huahuo_v3_theme.dart';
import '../../../shared/ui_v3/v3_text_editing.dart';
import '../../../shared/ui_v3/v3_long_running_task_notice.dart';
import '../application/masterpiece_generation_controller.dart';

class MasterpieceGenerationPanel extends StatelessWidget {
  const MasterpieceGenerationPanel({
    required this.controller,
    required this.onRefresh,
    super.key,
  });

  final MasterpieceGenerationController controller;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    final intent = controller.intent;
    final locked = !controller.unlocked;
    return SingleChildScrollView(
      key: const ValueKey('masterpiece-generation-panel'),
      padding: const EdgeInsets.symmetric(vertical: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (locked)
            _MasterpieceLockCard(controller: controller, onRefresh: onRefresh)
          else ...[
            const Icon(Icons.auto_awesome_outlined, size: 44),
            const SizedBox(height: 20),
            Text(
              '代表作已解锁',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 16),
          ],
          if (intent != null) ...[
            Text('本次写作引用 ${intent.sources.length} 篇固定版本笔记。生成正文正式收录并确认后，才能编辑。'),
            if (intent.runId != null)
              SelectableText(
                '任务编号：${intent.runId}',
                contextMenuBuilder: V3TextEditing.buildContextMenu,
                style: Theme.of(context).textTheme.bodySmall,
              ),
          ],
          if (!locked || intent != null) ...[
            const SizedBox(height: 16),
            Text(
              controller.statusMessage,
              key: const ValueKey('masterpiece-generation-status'),
            ),
          ],
          if (controller.errorCode != null) ...[
            const SizedBox(height: 8),
            SelectableText(
              '状态说明：${controller.errorCode}',
              contextMenuBuilder: V3TextEditing.buildContextMenu,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          const SizedBox(height: 16),
          if (controller.busy && !locked) const LinearProgressIndicator(),
          if (intent?.runId != null &&
              intent?.cancelRequested != true &&
              (intent?.stage == MasterpieceGenerationStage.running ||
                  intent?.stage == MasterpieceGenerationStage.publishing ||
                  intent?.stage == MasterpieceGenerationStage.accepted)) ...[
            const SizedBox(height: 12),
            const V3LongRunningTaskNotice(),
          ],
          if (!locked &&
              !controller.busy &&
              (intent != null && !intent.canDiscard ||
                  controller.errorCode ==
                      'MASTERPIECE_GENERATION_STORAGE_FAILED'))
            FilledButton(
              key: const ValueKey('masterpiece-generation-resume'),
              onPressed: controller.retry,
              child: Text(switch (intent?.stage) {
                MasterpieceGenerationStage.submitting ||
                MasterpieceGenerationStage.uncertain => '重试同一次生成请求',
                MasterpieceGenerationStage.publishing => '重试同一次收录',
                MasterpieceGenerationStage.accepted => '重新确认云端正文',
                _ => '继续查询与恢复',
              }),
            ),
          if (controller.canRestart)
            FilledButton(
              key: const ValueKey('masterpiece-generation-restart'),
              onPressed: () async {
                if (await confirmMasterpieceGeneration(context) &&
                    context.mounted) {
                  await controller.requestGeneration();
                }
              },
              child: const Text('请求云端生成'),
            ),
          if (controller.canCancel)
            TextButton(
              onPressed: () async {
                if (await _confirm(
                      context,
                      '取消本次生成？',
                      '需要等待云端确认。已经发生的模型调用不会因此撤回。',
                    ) &&
                    context.mounted) {
                  await controller.cancel();
                }
              },
              child: const Text('取消本次生成'),
            ),
          if (intent?.markdown != null)
            OutlinedButton.icon(
              onPressed: () => V3TextEditing.copy(context, intent!.markdown!),
              icon: const Icon(Icons.copy_outlined),
              label: const Text('复制生成正文'),
            ),
          if (!locked &&
              intent?.stage == MasterpieceGenerationStage.generated &&
              controller.errorCode != 'MASTERPIECE_BOOK_CHANGED' &&
              intent?.cancelRequested != true)
            FilledButton(
              onPressed: controller.busy ? null : controller.retry,
              child: const Text('重试收录生成正文'),
            ),
          if (controller.canDismiss)
            TextButton(
              onPressed: () async {
                if (await _confirm(
                      context,
                      '结束本次生成？',
                      '不会修改云端已有章节。未收录的生成正文将不再保留，请先复制备份；之后可以手动新建章节。',
                    ) &&
                    context.mounted) {
                  await controller.dismiss();
                }
              },
              child: const Text('结束本次生成，保留云端正文'),
            ),
        ],
      ),
    );
  }
}

class _MasterpieceLockCard extends StatelessWidget {
  const _MasterpieceLockCard({
    required this.controller,
    required this.onRefresh,
  });

  final MasterpieceGenerationController controller;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final verified = controller.eligibilityVerified;
    final count = controller.record.noteCount.clamp(0, masterpieceUnlockCount);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          key: const ValueKey('masterpiece-locked-card'),
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
          decoration: BoxDecoration(
            color: colors.surfaceMuted.withValues(alpha: .62),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: colors.line.withValues(alpha: .68)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: SizedBox.square(
                  dimension: 132,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Icon(
                        Icons.menu_book_rounded,
                        key: const ValueKey('masterpiece-locked-book'),
                        size: 94,
                        color: colors.ink.withValues(alpha: .18),
                      ),
                      Positioned(
                        right: 10,
                        bottom: 4,
                        child: Container(
                          width: 46,
                          height: 46,
                          decoration: BoxDecoration(
                            color: colors.surface,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: colors.line),
                          ),
                          child: Icon(
                            Icons.lock_rounded,
                            color: colors.muted,
                            size: 24,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                '沉淀积累到 100 篇笔记后解锁',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: colors.ink,
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 18),
              if (verified) ...[
                Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: '$count',
                        style: TextStyle(
                          color: colors.ink,
                          fontSize: 30,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      TextSpan(
                        text: ' / $masterpieceUnlockCount 篇',
                        style: TextStyle(color: colors.muted, fontSize: 14),
                      ),
                    ],
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    key: const ValueKey('masterpiece-unlock-progress'),
                    value: count / masterpieceUnlockCount,
                    minHeight: 7,
                    backgroundColor: colors.line.withValues(alpha: .55),
                    color: colors.accent,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  '还需沉淀 ${masterpieceUnlockCount - count} 篇笔记',
                  key: const ValueKey('masterpiece-lock-progress'),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: colors.muted, fontSize: 13),
                ),
              ] else
                Text(
                  controller.statusMessage,
                  key: const ValueKey('masterpiece-eligibility-status'),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: colors.muted, height: 1.5),
                ),
              const SizedBox(height: 18),
              OutlinedButton.icon(
                onPressed: controller.busy ? null : onRefresh,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('重新核对云端笔记', textAlign: TextAlign.center),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: colors.line.withValues(alpha: .68)),
          ),
          child: Column(
            children: [
              const _MasterpieceLockInfoRow(
                icon: Icons.article_outlined,
                title: '什么是代表作',
                detail: '把持续沉淀的知识，整理成属于你的作品。',
              ),
              Divider(height: 1, indent: 48, color: colors.line),
              const _MasterpieceLockInfoRow(
                icon: Icons.shield_outlined,
                title: '解锁条件',
                detail: '当前云端有效笔记达到 100 篇，重复笔记只计一次。',
              ),
              Divider(height: 1, indent: 48, color: colors.line),
              const _MasterpieceLockInfoRow(
                icon: Icons.auto_stories_outlined,
                title: '解锁后可获得',
                detail: '生成首稿、编辑章节，继续积累你的代表作。',
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _MasterpieceLockInfoRow extends StatelessWidget {
  const _MasterpieceLockInfoRow({
    required this.icon,
    required this.title,
    required this.detail,
  });
  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: colors.ink, size: 20),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: colors.ink,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  detail,
                  style: TextStyle(
                    color: colors.muted,
                    fontSize: 12.5,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

Future<bool> confirmMasterpieceGeneration(BuildContext context) => _confirm(
  context,
  '请求生成代表作新篇章？',
  '将选取最多 100 篇已同步笔记请求云端写作，可能消耗账号额度。生成结果只新增章节，不覆盖已有内容。',
);

Future<bool> _confirm(
  BuildContext context,
  String title,
  String message,
) async =>
    await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: HuahuoV3Theme.tokensOf(dialogContext).surface,
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('确认'),
          ),
        ],
      ),
    ) ??
    false;
