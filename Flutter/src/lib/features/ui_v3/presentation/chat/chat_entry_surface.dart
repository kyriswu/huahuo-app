import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../../shared/theme/huahuo_v3_theme.dart';
import '../../../../shared/ui_v3/v3_chat_mark.dart';
import '../../../../shared/ui_v3/v3_onboarding_spotlight.dart';
import 'chat_entry_figma_spec.dart';

class ChatEntryHeaderActions extends StatelessWidget {
  const ChatEntryHeaderActions({
    required this.onHistory,
    required this.onNewConversation,
    this.enabled = true,
    this.historyEnabled = true,
    this.newConversationEnabled = true,
    super.key,
  });

  final VoidCallback onHistory;
  final VoidCallback onNewConversation;
  final bool enabled;
  final bool historyEnabled;
  final bool newConversationEnabled;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return SizedBox(
      width: 82,
      height: 40,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surface.withValues(alpha: .96),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: colors.line),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: colors.ink.withValues(alpha: .08),
              blurRadius: 7,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            Expanded(
              child: IconButton(
                key: const ValueKey<String>('chat-entry-new-conversation'),
                tooltip: '新建会话',
                padding: EdgeInsets.zero,
                onPressed: enabled && newConversationEnabled
                    ? onNewConversation
                    : null,
                icon: Icon(
                  LucideIcons.messageSquarePlus,
                  size: 20,
                  color: enabled && newConversationEnabled
                      ? colors.ink
                      : colors.muted,
                ),
              ),
            ),
            SizedBox(
              width: 1,
              height: 20,
              child: ColoredBox(color: colors.line),
            ),
            Expanded(
              child: IconButton(
                key: const ValueKey<String>('chat-entry-history'),
                tooltip: '会话列表',
                padding: EdgeInsets.zero,
                onPressed: enabled && historyEnabled ? onHistory : null,
                icon: Icon(
                  LucideIcons.history,
                  size: 20,
                  color: enabled && historyEnabled ? colors.ink : colors.muted,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ChatEntrySurface extends StatefulWidget {
  const ChatEntrySurface({
    required this.onSuggestion,
    this.enabled = true,
    this.greeting = ChatEntryFigmaSpec.greeting,
    this.supportingCopy = ChatEntryFigmaSpec.supportingCopy,
    this.suggestionSets = ChatEntryFigmaSpec.suggestionSets,
    this.showIntro = true,
    this.emptyStateLabel,
    this.helpLabel,
    this.onHelp,
    this.showStartupGuide = false,
    this.onSkipStartupGuide,
    super.key,
  }) : assert((helpLabel == null) == (onHelp == null)),
       assert(!showStartupGuide || onSkipStartupGuide != null);

  final ValueChanged<ChatEntrySuggestionSpec> onSuggestion;
  final bool enabled;
  final String greeting;
  final String supportingCopy;
  final List<List<ChatEntrySuggestionSpec>> suggestionSets;
  final bool showIntro;
  final String? emptyStateLabel;
  final String? helpLabel;
  final VoidCallback? onHelp;
  final bool showStartupGuide;
  final VoidCallback? onSkipStartupGuide;

  @override
  State<ChatEntrySurface> createState() => _ChatEntrySurfaceState();
}

class _ChatEntrySurfaceState extends State<ChatEntrySurface> {
  int _suggestionSetIndex = 0;
  final int _startupSuggestionSeed = math.Random().nextInt(1 << 30);

  void _rotateSuggestions() {
    if (!widget.enabled) return;
    setState(() {
      _suggestionSetIndex =
          (_suggestionSetIndex + 1) % widget.suggestionSets.length;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final suggestions = widget
        .suggestionSets[_suggestionSetIndex % widget.suggestionSets.length];
    final startupSuggestions = suggestions
        .where(
          (suggestion) => suggestion.kind == ChatEntrySuggestionKind.prompt,
        )
        .toList(growable: false);
    final startupSuggestion = startupSuggestions.isEmpty
        ? null
        : startupSuggestions[_startupSuggestionSeed %
              startupSuggestions.length];
    final helpColor = Theme.of(context).brightness == Brightness.dark
        ? const Color(0xFF79A9EF)
        : const Color(0xFF2E6EC7);
    return Column(
      key: const ValueKey<String>('chat-entry-surface'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.showIntro) ...[
          const SizedBox(height: 10),
          Text(
            widget.greeting,
            style: TextStyle(
              color: colors.ink,
              fontSize: 16,
              height: 1.25,
              fontWeight: FontWeight.w500,
              letterSpacing: 0,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            widget.supportingCopy,
            style: TextStyle(
              color: colors.muted,
              fontSize: 13,
              height: 1.35,
              fontWeight: FontWeight.w400,
              letterSpacing: 0,
            ),
          ),
          const SizedBox(height: 36),
        ] else
          const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: Text(
                ChatEntryFigmaSpec.sectionTitle,
                style: TextStyle(
                  color: colors.ink,
                  fontSize: 18,
                  height: 1.25,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0,
                ),
              ),
            ),
            TextButton.icon(
              key: const ValueKey<String>('chat-entry-refresh-suggestions'),
              onPressed: widget.enabled ? _rotateSuggestions : null,
              style: TextButton.styleFrom(
                foregroundColor: colors.muted,
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                minimumSize: const Size(72, 36),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text(
                ChatEntryFigmaSpec.refreshLabel,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w400,
                  letterSpacing: 0,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        for (final suggestion in suggestions) ...[
          V3OnboardingSpotlight(
            visible:
                widget.showStartupGuide &&
                widget.enabled &&
                identical(suggestion, startupSuggestion),
            step: 2,
            revealTarget: true,
            title: '选一个问题，开始第一次创作',
            message: '点这条「猜你想问」，就会发送给花火并收到回复。之后也可以直接说出需求，让它帮你继续创作、调整或润色。',
            onSkip: widget.onSkipStartupGuide ?? () {},
            child: _ChatEntrySuggestionTile(
              suggestion: suggestion,
              enabled: widget.enabled,
              onTap: () => widget.onSuggestion(suggestion),
            ),
          ),
          if (!identical(suggestion, suggestions.last))
            const SizedBox(height: 12),
        ],
        if (widget.onHelp case final onHelp?) ...[
          const SizedBox(height: 10),
          SizedBox(
            height: 36,
            child: TextButton(
              key: const ValueKey<String>('chat-visual-reference-help'),
              onPressed: widget.enabled ? onHelp : null,
              style: TextButton.styleFrom(
                foregroundColor: helpColor,
                disabledForegroundColor: colors.muted,
                padding: EdgeInsets.zero,
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(LucideIcons.info, size: 20),
                  const SizedBox(width: 6),
                  Text(
                    widget.helpLabel!,
                    style: const TextStyle(
                      fontSize: 14,
                      height: 1.4,
                      fontWeight: FontWeight.w500,
                      letterSpacing: 0,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
        if (widget.emptyStateLabel case final label?) ...[
          SizedBox(height: widget.onHelp == null ? 62 : 16),
          const Center(child: V3ChatMark(size: 56)),
          const SizedBox(height: 12),
          Center(
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: colors.muted,
                fontSize: 13,
                height: 1.4,
                fontWeight: FontWeight.w400,
                letterSpacing: 0,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _ChatEntrySuggestionTile extends StatelessWidget {
  const _ChatEntrySuggestionTile({
    required this.suggestion,
    required this.enabled,
    required this.onTap,
  });

  final ChatEntrySuggestionSpec suggestion;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Material(
      color: colors.surfaceMuted,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        key: ValueKey<String>('chat-entry-suggestion-${suggestion.kind.name}'),
        borderRadius: BorderRadius.circular(8),
        onTap: enabled ? onTap : null,
        child: SizedBox(
          height: 54,
          child: Padding(
            padding: const EdgeInsets.only(left: 16, right: 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    suggestion.label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: enabled ? colors.text : colors.muted,
                      fontSize: 15,
                      height: 1.3,
                      fontWeight: FontWeight.w400,
                      letterSpacing: 0,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  Icons.chevron_right_rounded,
                  size: 22,
                  color: colors.muted,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
