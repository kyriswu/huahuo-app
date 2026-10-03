import 'package:flutter/material.dart';

import '../../../shared/theme/huahuo_v3_theme.dart';
import '../../../shared/ui_v3/v3_components.dart';

enum V3FeedImportAction { link, document, media, recording }

class V3FeedMoreWaysSheet extends StatelessWidget {
  const V3FeedMoreWaysSheet({
    required this.onClose,
    required this.onSelected,
    super.key,
  });

  final VoidCallback onClose;
  final ValueChanged<V3FeedImportAction> onSelected;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return _V3NavigationSheetFrame(
      key: const ValueKey('feed-more-ways-sheet'),
      height: 383,
      title: '更多方式',
      showHandle: false,
      centerTitle: false,
      onClose: onClose,
      children: [
        _V3NavigationRow(
          icon: Icons.link_rounded,
          title: '粘贴链接',
          subtitle: '支持公众号、抖音、B站、小红书、小宇宙等链接',
          onTap: () => onSelected(V3FeedImportAction.link),
        ),
        _V3NavigationRow(
          icon: Icons.image_outlined,
          title: '导入本地文件',
          subtitle: '支持 PDF、Word、PPT、Excel、TXT、Markdown 等文件',
          onTap: () => onSelected(V3FeedImportAction.document),
        ),
        _V3NavigationRow(
          icon: Icons.audio_file_outlined,
          title: '导入录音音频',
          subtitle: '支持 MP3、M4A、WAV 录音文件',
          onTap: () => onSelected(V3FeedImportAction.media),
        ),
        _V3NavigationRow(
          icon: Icons.mic_none_rounded,
          title: '外录 / 内录',
          subtitle: '外录会议、谈话；内录直播、课程',
          showDivider: false,
          onTap: () => onSelected(V3FeedImportAction.recording),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.info_outline_rounded, size: 16, color: colors.muted),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  '内容由 AI 生成，请勿从事违法违规活动',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: colors.muted, fontSize: 11),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _V3NavigationSheetFrame extends StatelessWidget {
  const _V3NavigationSheetFrame({
    required this.height,
    required this.title,
    required this.onClose,
    required this.children,
    this.showHandle = true,
    this.centerTitle = true,
    super.key,
  });

  final double height;
  final String title;
  final VoidCallback onClose;
  final List<Widget> children;
  final bool showHandle;
  final bool centerTitle;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final effectiveHeight = constraints.maxHeight.isFinite
            ? height.clamp(0.0, constraints.maxHeight).toDouble()
            : height;
        return Container(
          height: effectiveHeight,
          decoration: BoxDecoration(
            color: colors.canvas,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
            border: Border.all(color: colors.line),
            boxShadow: const [
              BoxShadow(
                color: Color(0x1f1a1f26),
                blurRadius: 32,
                offset: Offset(0, -10),
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: SafeArea(
            top: false,
            child: Column(
              children: [
                SizedBox(height: showHandle ? 11 : 16),
                if (showHandle)
                  Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: colors.muted,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                SizedBox(
                  height: showHandle ? 72 : 44,
                  child: Stack(
                    children: [
                      if (centerTitle)
                        Center(
                          child: Text(
                            title,
                            style: TextStyle(
                              color: colors.ink,
                              fontSize: 18,
                              height: 1.45,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        )
                      else
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Padding(
                            padding: const EdgeInsets.only(left: 23),
                            child: Text(
                              title,
                              style: TextStyle(
                                color: colors.ink,
                                fontSize: 18,
                                height: 1.35,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ),
                      Positioned(
                        left: centerTitle ? 13 : null,
                        right: centerTitle ? null : 13,
                        top: centerTitle ? 12 : 0,
                        child: V3CloseButton(
                          onPressed: onClose,
                          color: colors.text,
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: centerTitle ? 23 : 24,
                      ),
                      child: Column(children: children),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _V3NavigationRow extends StatelessWidget {
  const _V3NavigationRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.showDivider = true,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return InkWell(
      onTap: onTap,
      child: SizedBox(
        height: 64,
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: colors.surfaceMuted,
                borderRadius: BorderRadius.circular(11),
              ),
              child: Icon(icon, size: 20, color: colors.ink),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  border: showDivider
                      ? Border(bottom: BorderSide(color: colors.line))
                      : null,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: TextStyle(
                              color: colors.ink,
                              fontSize: 15,
                              height: 1.35,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: colors.muted,
                              fontSize: 12,
                              height: 1.4,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      Icons.chevron_right_rounded,
                      size: 20,
                      color: colors.muted,
                    ),
                    const SizedBox(width: 4),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
