import 'package:huahuoai_app/shared/markdown/v3_markdown.dart';
import 'package:flutter/material.dart';

import '../../../shared/theme/huahuo_v3_theme.dart';
import '../../../shared/ui_v3/v3_chat_mark.dart';
import '../../../shared/ui_v3/v3_liquid_glass.dart';
import '../domain/feed_item_models.dart';

class V3GraphNodeActionCard extends StatelessWidget {
  const V3GraphNodeActionCard({
    required this.note,
    required this.onView,
    required this.onChat,
    super.key,
  });

  final V3FeedItem note;
  final VoidCallback onView;
  final VoidCallback onChat;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final summary = note.summaryBody?.trim().isNotEmpty == true
        ? note.summaryBody!.trim()
        : note.rawBody.trim();
    return V3LiquidGlassSurface(
      style: V3GlassSurfaceStyle.dock,
      borderRadius: 18,
      padding: EdgeInsets.zero,
      child: Material(
        type: MaterialType.transparency,
        borderRadius: BorderRadius.circular(18),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 11, 14, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    note.source.label,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: colors.muted,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    note.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  _GraphMarkdownPreview(
                    source: summary.isEmpty ? '暂无纲要' : summary,
                    color: colors.muted,
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: colors.line),
            SizedBox(
              height: 46,
              child: Row(
                children: [
                  Expanded(
                    child: _NodeAction(
                      label: '查看',
                      icon: const Icon(Icons.visibility_outlined, size: 17),
                      onTap: onView,
                    ),
                  ),
                  Container(width: 1, height: 22, color: colors.line),
                  Expanded(
                    child: _NodeAction(
                      label: '聊一聊',
                      icon: const V3ChatMark(size: 20),
                      onTap: onChat,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GraphMarkdownPreview extends StatelessWidget {
  const _GraphMarkdownPreview({required this.source, required this.color});

  final String source;
  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 53,
    child: ClipRect(
      child: SingleChildScrollView(
        physics: const NeverScrollableScrollPhysics(),
        child: V3AssistantReplyMarkdown(source: source),
      ),
    ),
  );
}

class _NodeAction extends StatelessWidget {
  const _NodeAction({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final Widget icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      excludeSemantics: true,
      label: label,
      child: InkWell(
        onTap: onTap,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            icon,
            const SizedBox(width: 6),
            Text(
              label,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
            ),
          ],
        ),
      ),
    );
  }
}
