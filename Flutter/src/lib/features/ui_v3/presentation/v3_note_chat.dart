import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../app/di/chat_providers.dart';
import '../../chat/application/voice_message_controller.dart';
import '../../chat/domain/chat_models.dart';
import '../../../shared/theme/huahuo_v3_theme.dart';
import '../../../shared/ui_v3/v3_components.dart';
import '../../../shared/ui_v3/v3_glass_foundations.dart';
import '../application/knowledge_library_controller.dart';
import '../application/knowledge_note_port.dart';
import '../application/subscription_port.dart';
import '../domain/feed_item_models.dart';
import 'v3_chat_page.dart'
    show
        V3ChatPage,
        V3ChatPresentation,
        V3ChatSheetExpansion,
        agentAssistedCreationChatEntryRouteValue;

Future<void> showV3NoteChatSheet({
  required BuildContext context,
  required V3FeedItem item,
  OrdinaryChatEntryPoint? ordinaryEntryPoint,
}) async {
  final effectiveEntryPoint =
      ordinaryEntryPoint ??
      OrdinaryChatEntryPoint.tryParse(
        kind: OrdinaryChatEntryKind.asset.storageValue,
        entryId: item.id,
      );
  if (effectiveEntryPoint == null) {
    showV3Snack(context, '资料标识无效，请刷新后重试');
    return;
  }
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: .12),
    elevation: 0,
    showDragHandle: false,
    sheetAnimationStyle: AnimationStyle(
      duration: V3MotionTokens.resolve(context, V3MotionTokens.emphasized),
      reverseDuration: V3MotionTokens.resolve(context, V3MotionTokens.standard),
    ),
    builder: (sheetContext) {
      final sheetHeight = MediaQuery.sizeOf(sheetContext).height * .87;
      return ProviderScope(
        overrides: <Override>[
          feedAiChatControllerProvider.overrideWith(createFeedAiChatController),
          feedAiVoiceMessageControllerProvider.overrideWith(
            createFeedAiVoiceMessageController,
          ),
        ],
        child: SizedBox(
          key: const ValueKey<String>('note-chat-sheet-surface'),
          height: sheetHeight,
          child: Material(
            color: HuahuoV3Theme.tokensOf(sheetContext).canvas,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
            clipBehavior: Clip.antiAlias,
            child: V3ChatPage(
              key: ValueKey<String>('note-chat-${item.id}'),
              feedItemId: item.id,
              ordinaryEntryPoint: effectiveEntryPoint,
              launchMode: ChatLaunchMode.fresh,
              presentation: V3ChatPresentation.noteSheet,
              onSheetClose: () => Navigator.of(sheetContext).pop(),
              onSheetExpand: (expansion) => _expandV3NoteChatSheet(
                launcherContext: context,
                sheetContext: sheetContext,
                item: item,
                ordinaryEntryPoint: effectiveEntryPoint,
                expansion: expansion,
              ),
            ),
          ),
        ),
      );
    },
  );
}

void _expandV3NoteChatSheet({
  required BuildContext launcherContext,
  required BuildContext sheetContext,
  required V3FeedItem item,
  required OrdinaryChatEntryPoint ordinaryEntryPoint,
  required V3ChatSheetExpansion expansion,
}) {
  Navigator.of(sheetContext).pop();
  if (!launcherContext.mounted) return;
  unawaited(
    launcherContext.push<void>(
      v3NoteChatRoute(
        item,
        ordinaryEntryPoint: ordinaryEntryPoint,
        threadId: expansion.threadId,
        prompt: expansion.draft,
        agentProfileId: expansion.agentProfileId,
        expandFromSheet: true,
        includeItemReference: expansion.includesSourceReference,
        windowId: expansion.threadId == null
            ? 'note-sheet-${DateTime.now().microsecondsSinceEpoch}'
            : null,
      ),
    ),
  );
}

String v3NoteChatRoute(
  V3FeedItem item, {
  OrdinaryChatEntryPoint? ordinaryEntryPoint,
  String? threadId,
  String? prompt,
  bool autoSend = false,
  String? agentProfileId,
  bool expandFromSheet = false,
  bool includeItemReference = true,
  String? windowId,
}) => Uri(
  path: '/v3/feed/chat',
  queryParameters: <String, String>{
    if (includeItemReference) 'itemId': item.id,
    if (ordinaryEntryPoint != null)
      'ordinaryEntryKind': ordinaryEntryPoint.kind.storageValue,
    if (ordinaryEntryPoint != null)
      'ordinaryEntryId': ordinaryEntryPoint.entryId,
    if (threadId != null) 'threadId': threadId,
    if (threadId != null) 'purpose': ChatConversationPurpose.general.routeValue,
    if (windowId != null) 'window': windowId,
    if (agentProfileId != null) 'agentProfileId': agentProfileId,
    if (prompt != null && prompt.trim().isNotEmpty) 'prompt': prompt.trim(),
    if (autoSend) 'autoSend': '1',
    if (expandFromSheet) 'presentation': 'sheet',
  },
).toString();

class V3NoteAgentPickerSheet extends StatelessWidget {
  const V3NoteAgentPickerSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final choices = <Widget>[
      const _AgentChoiceTile(
        skill: WorkbenchChatSkill.persona,
        icon: LucideIcons.userRound,
        title: '个人 IP 设计 Agent',
        subtitle: '使用这篇内容，帮你进行个人 IP 设计',
      ),
      Divider(height: 1, color: colors.line),
      const _AgentChoiceTile(
        skill: WorkbenchChatSkill.lead,
        icon: Icons.campaign_outlined,
        title: '获客营销选题 Agent',
        subtitle: '使用这篇内容，帮你生成获客营销选题',
      ),
    ];
    final compactHeight = MediaQuery.sizeOf(context).height < 400;
    return Material(
      color: colors.canvas,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
      clipBehavior: Clip.antiAlias,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                height: 44,
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '选择 Agent',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    V3CloseButton(onPressed: () => Navigator.pop(context)),
                  ],
                ),
              ),
              if (compactHeight)
                Flexible(
                  fit: FlexFit.loose,
                  child: SingleChildScrollView(
                    child: Column(children: choices),
                  ),
                )
              else
                ...choices,
            ],
          ),
        ),
      ),
    );
  }
}

@immutable
final class V3NoteAgentCreationSelection {
  const V3NoteAgentCreationSelection({required this.skill});

  final WorkbenchChatSkill skill;
}

Future<V3NoteAgentCreationSelection?> showV3NoteAgentCreationFlow(
  BuildContext context,
) async {
  final skill = await showModalBottomSheet<WorkbenchChatSkill>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: .12),
    builder: (_) => const V3NoteAgentPickerSheet(),
  );
  if (skill == null || !context.mounted) return null;
  return V3NoteAgentCreationSelection(skill: skill);
}

String v3AgentCreationPrompt(WorkbenchChatSkill skill) => switch (skill) {
  WorkbenchChatSkill.persona =>
    '现在开始做选题。请先结合当前资料判断目前能推进到哪一步，再和我协作讨论，一起完成剩下的步骤。',
  WorkbenchChatSkill.lead =>
    '现在开始做获客营销选题。请先结合当前资料判断目前能推进到哪一步，再和我协作讨论，一起完成剩下的步骤。',
  WorkbenchChatSkill.visualDesign =>
    '现在开始做视觉设计。请先结合当前资料判断目前能推进到哪一步，再和我协作讨论，一起完成剩下的步骤。',
  _ => '请先结合当前资料判断目前能推进到哪一步，再和我协作讨论，一起完成剩下的步骤。',
};

String v3AgentAssistedCreationRoute({
  required V3FeedItem item,
  required V3NoteAgentCreationSelection selection,
}) => Uri(
  path: '/v3/feed/chat',
  queryParameters: <String, String>{
    'entry': agentAssistedCreationChatEntryRouteValue,
    'skill': selection.skill.routeValue,
    'materialIds': item.id,
    'prompt': v3AgentCreationPrompt(selection.skill),
    'autoSend': '1',
  },
).toString();

Future<V3FeedItem?> prepareV3AgentCreationMaterial({
  required KnowledgeLibraryController library,
  required V3FeedItem item,
}) async {
  await library.restore();
  V3FeedItem? candidate = library.noteForId(item.id) ?? item;
  if (candidate.isReadOnly) {
    candidate = _existingV3AgentCreationCopy(library, candidate);
    if (candidate == null) {
      final current = library.noteForId(item.id) ?? item;
      if (current.articleId?.trim().isNotEmpty == true) {
        final saved = await library.saveRemoteSubscriptionArticle(current.id);
        if (saved.status != MobileSubscriptionResultStatus.success) return null;
        candidate = saved.item;
      } else {
        candidate = library.createEditableCopy(current.id);
      }
    }
  }
  if (candidate == null || candidate.isReadOnly) return null;
  var synchronized = candidate;

  for (var attempt = 0; attempt < 3; attempt++) {
    final current = library.noteForId(synchronized.id) ?? synchronized;
    if (_hasExactChatReference(current)) return current;
    final result = await library.syncNote(current.id);
    synchronized = result.note ?? library.noteForId(current.id) ?? current;
    if (_hasExactChatReference(synchronized)) return synchronized;
    if (result.outcome != KnowledgeNoteSyncOutcome.superseded) return null;
  }
  return null;
}

V3FeedItem? _existingV3AgentCreationCopy(
  KnowledgeLibraryController library,
  V3FeedItem source,
) {
  final requiresArticleRevision = source.articleId?.trim().isNotEmpty == true;
  final sourceRevision = source.articleRevisionId?.trim();
  V3FeedItem? fallback;
  for (final candidate in library.mineNotes) {
    if (candidate.copiedFromContentId != source.id) continue;
    if (requiresArticleRevision &&
        (sourceRevision == null ||
            sourceRevision.isEmpty ||
            candidate.articleRevisionId?.trim() != sourceRevision)) {
      continue;
    }
    if (_hasExactChatReference(candidate)) return candidate;
    fallback ??= candidate;
  }
  return fallback;
}

bool _hasExactChatReference(V3FeedItem item) {
  final noteId = item.remoteNoteId?.trim();
  final revision = item.rawPartRevisionId?.trim();
  return item.syncState == NoteSyncState.synced &&
      noteId != null &&
      revision != null &&
      isSafeChatIdentifier(noteId) &&
      isSafeChatIdentifier(revision);
}

class _AgentChoiceTile extends StatelessWidget {
  const _AgentChoiceTile({
    required this.skill,
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final WorkbenchChatSkill skill;
  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Semantics(
      button: true,
      label: title,
      child: InkWell(
        onTap: () => Navigator.pop(context, skill),
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          height: 60,
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: colors.surfaceMuted,
                  borderRadius: BorderRadius.circular(10),
                ),
                alignment: Alignment.center,
                child: Icon(icon, size: 20, color: colors.ink),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: colors.muted, fontSize: 13),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded, size: 22),
            ],
          ),
        ),
      ),
    );
  }
}
