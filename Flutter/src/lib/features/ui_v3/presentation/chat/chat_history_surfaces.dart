import 'package:flutter/material.dart';

import '../../../../shared/theme/huahuo_v3_theme.dart';
import '../../../../shared/ui_v3/v3_components.dart';
import '../../../../shared/ui_v3/v3_text_editing.dart';
import '../../../chat/domain/chat_models.dart';

class V3ChatHistorySurface extends StatefulWidget {
  const V3ChatHistorySurface({
    required this.threads,
    required this.loading,
    required this.onBack,
    required this.onNewConversation,
    required this.onSelect,
    required this.onMore,
    this.syncing = false,
    this.isRouteEntry = false,
    this.hasMore = false,
    this.errorCode,
    this.onRetry,
    this.onLoadMore,
    super.key,
  });

  final List<ChatThread> threads;
  final bool loading;
  final bool syncing;
  final bool isRouteEntry;
  final bool hasMore;
  final String? errorCode;
  final VoidCallback onBack;
  final VoidCallback onNewConversation;
  final VoidCallback? onRetry;
  final VoidCallback? onLoadMore;
  final ValueChanged<ChatThread> onSelect;
  final ValueChanged<ChatThread> onMore;

  @override
  State<V3ChatHistorySurface> createState() => _V3ChatHistorySurfaceState();
}

class _V3ChatHistorySurfaceState extends State<V3ChatHistorySurface> {
  final _queryController = TextEditingController();
  var _query = '';

  @override
  void dispose() {
    _queryController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final query = _query.trim().toLowerCase();
    final visibleThreads = widget.threads
        .where(
          (thread) =>
              query.isEmpty ||
              thread.displayTitle.toLowerCase().contains(query) ||
              thread.sourceLabel.toLowerCase().contains(query),
        )
        .toList(growable: false);
    return PopScope(
      canPop: widget.isRouteEntry,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) widget.onBack();
      },
      child: Scaffold(
        backgroundColor: colors.canvas,
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 20, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  height: 48,
                  child: Row(
                    children: [
                      V3NavigationBackButton(
                        key: const ValueKey('chat-history-back'),
                        tooltip: '返回',
                        onPressed: widget.onBack,
                      ),
                      const SizedBox(width: 2),
                      const Expanded(
                        child: Text(
                          '对话记录',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      SizedBox.square(
                        dimension: HuahuoControlSize.iconComfortable,
                        child: IconButton(
                          key: const ValueKey('chat-history-new'),
                          tooltip: '新建会话',
                          color: colors.accent,
                          onPressed: widget.onNewConversation,
                          icon: const Icon(Icons.add_rounded, size: 23),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  height: 44,
                  child: TextField(
                    key: const ValueKey('chat-history-search'),
                    controller: _queryController,
                    contextMenuBuilder: V3TextEditing.buildContextMenu,
                    onChanged: (value) => setState(() => _query = value),
                    decoration: InputDecoration(
                      hintText: '搜索记录或 Agent',
                      prefixIcon: const Icon(Icons.search_rounded, size: 21),
                      filled: true,
                      fillColor: colors.surfaceMuted,
                      contentPadding: const EdgeInsets.symmetric(vertical: 10),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: colors.line),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: colors.line),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  query.isEmpty ? '最近' : '搜索结果 · ${visibleThreads.length} 条',
                  style: TextStyle(color: colors.muted, fontSize: 13),
                ),
                if (widget.syncing) ...[
                  const SizedBox(height: 8),
                  const LinearProgressIndicator(
                    key: ValueKey('chat-history-syncing'),
                    minHeight: 2,
                  ),
                ] else if (widget.errorCode != null) ...[
                  const SizedBox(height: 4),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      key: const ValueKey('chat-history-retry'),
                      onPressed: widget.onRetry,
                      icon: const Icon(Icons.refresh_rounded, size: 17),
                      label: const Text('历史同步未完成，重试'),
                    ),
                  ),
                ] else if (widget.hasMore) ...[
                  const SizedBox(height: 4),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      key: const ValueKey('chat-history-load-more'),
                      onPressed: widget.onLoadMore,
                      child: const Text('加载更多'),
                    ),
                  ),
                ],
                const SizedBox(height: 10),
                Expanded(
                  child: widget.loading
                      ? const Center(
                          child: CircularProgressIndicator.adaptive(),
                        )
                      : visibleThreads.isEmpty
                      ? Center(
                          child: Text(
                            query.isEmpty ? '暂无历史对话' : '没有匹配的对话',
                            style: TextStyle(color: colors.muted),
                          ),
                        )
                      : ListView.separated(
                          padding: EdgeInsets.zero,
                          itemCount: visibleThreads.length,
                          separatorBuilder: (_, __) => Divider(
                            height: 1,
                            indent: 14,
                            color: colors.line,
                          ),
                          itemBuilder: (context, index) {
                            final thread = visibleThreads[index];
                            return Material(
                              key: ValueKey(
                                'chat-history-row-${thread.threadId}',
                              ),
                              type: MaterialType.transparency,
                              child: InkWell(
                                onTap: () => widget.onSelect(thread),
                                child: Container(
                                  height: 76,
                                  padding: const EdgeInsets.fromLTRB(
                                    14,
                                    10,
                                    0,
                                    9,
                                  ),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              thread.displayTitle,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                fontSize: 15,
                                                fontWeight: FontWeight.w500,
                                              ),
                                            ),
                                            const Spacer(),
                                            Row(
                                              children: [
                                                Container(
                                                  key: ValueKey(
                                                    'chat-history-source-${thread.threadId}',
                                                  ),
                                                  padding:
                                                      const EdgeInsets.symmetric(
                                                        horizontal: 7,
                                                        vertical: 3,
                                                      ),
                                                  decoration: BoxDecoration(
                                                    color: colors.accent
                                                        .withValues(alpha: .08),
                                                    border: Border.all(
                                                      color: colors.accent
                                                          .withValues(
                                                            alpha: .42,
                                                          ),
                                                    ),
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          6,
                                                        ),
                                                  ),
                                                  child: Text(
                                                    thread.sourceLabel,
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: TextStyle(
                                                      color: colors.accent,
                                                      fontSize: 11,
                                                      fontWeight:
                                                          FontWeight.w600,
                                                    ),
                                                  ),
                                                ),
                                                const SizedBox(width: 8),
                                                Expanded(
                                                  child: Text(
                                                    _m05HistoryTime(
                                                      thread.updatedAt,
                                                    ),
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    textAlign: TextAlign.end,
                                                    style: TextStyle(
                                                      color: colors.muted,
                                                      fontSize: 12,
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ],
                                        ),
                                      ),
                                      SizedBox.square(
                                        dimension:
                                            HuahuoControlSize.iconComfortable,
                                        child: IconButton(
                                          key: ValueKey(
                                            'chat-history-more-${thread.threadId}',
                                          ),
                                          tooltip: '对话操作',
                                          onPressed: () =>
                                              widget.onMore(thread),
                                          icon: const Icon(
                                            Icons.more_vert_rounded,
                                            size: 20,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String _m05HistoryTime(DateTime? value) {
  if (value == null) return '刚刚';
  final local = value.toLocal();
  final now = DateTime.now();
  final valueDay = DateTime(local.year, local.month, local.day);
  final today = DateTime(now.year, now.month, now.day);
  final time =
      '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}';
  if (valueDay == today) {
    final age = now.difference(local);
    return !age.isNegative && age <= const Duration(minutes: 5)
        ? '刚刚'
        : '今天 $time';
  }
  if (valueDay == today.subtract(const Duration(days: 1))) return '昨天 $time';
  return '${local.month} 月 ${local.day} 日';
}
