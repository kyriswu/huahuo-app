import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../app/navigation/app_route_paths.dart';
import '../../../shared/navigation/safe_navigation.dart';
import '../../../shared/theme/huahuo_v3_theme.dart';
import '../../../shared/ui_v3/v3_chat_mark.dart';
import '../../../shared/ui_v3/v3_components.dart';
import '../../../shared/ui_v3/v3_glass_foundations.dart';
import '../../../shared/ui_v3/v3_text_editing.dart';
import '../application/aggregation_agent_session_registry.dart';
import '../domain/ui_v3_models.dart';

class V3AggregationAgentChatPage extends ConsumerStatefulWidget {
  const V3AggregationAgentChatPage({required this.sessionId, super.key});

  final String sessionId;

  @override
  ConsumerState<V3AggregationAgentChatPage> createState() =>
      _V3AggregationAgentChatPageState();
}

class _V3AggregationAgentChatPageState
    extends ConsumerState<V3AggregationAgentChatPage> {
  final TextEditingController _input = TextEditingController();
  late final AggregationAgentSessionRegistry _registry;
  late final AggregationAgentSessionEntry? _entry;
  late final List<(bool, String)> _messages;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _registry = ref.read(aggregationAgentSessionRegistryProvider);
    _entry = _registry.read(widget.sessionId);
    _messages = switch (_entry) {
      final entry? => <(bool, String)>[(false, entry.session.openingMessage)],
      null => <(bool, String)>[],
    };
  }

  @override
  void dispose() {
    _input.dispose();
    if (_entry != null) _registry.remove(widget.sessionId);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final entry = _entry;
    if (entry == null) return const _AggregationAgentSessionUnavailablePage();

    final colors = HuahuoV3Theme.tokensOf(context);
    final session = entry.session;
    return Scaffold(
      backgroundColor: colors.canvas,
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        backgroundColor: colors.canvas,
        surfaceTintColor: Colors.transparent,
        leading: const V3NavigationBackButton(
          fallbackRoute: AppRoutePaths.home,
        ),
        titleSpacing: 0,
        title: Row(
          children: [
            const V3ChatMark(size: 30),
            const SizedBox(width: 10),
            Text('${session.kind.label} · 聊一聊'),
          ],
        ),
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.fromLTRB(18, 18, 18, 12),
                itemCount: _messages.length,
                itemBuilder: (context, index) {
                  final message = _messages[index];
                  return Align(
                    alignment: message.$1
                        ? Alignment.centerRight
                        : Alignment.centerLeft,
                    child: Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      constraints: const BoxConstraints(maxWidth: 300),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 11,
                      ),
                      decoration: BoxDecoration(
                        color: message.$1 ? colors.ink : colors.surface,
                        borderRadius: BorderRadius.circular(12),
                        border: message.$1
                            ? null
                            : Border.all(color: colors.line),
                      ),
                      child: Text(
                        message.$2,
                        style: TextStyle(
                          color: message.$1 ? colors.canvas : colors.text,
                          height: 1.45,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            AnimatedPadding(
              duration: V3MotionTokens.standard,
              curve: Curves.easeOutCubic,
              padding: EdgeInsets.fromLTRB(
                16,
                8,
                16,
                10 + MediaQuery.viewInsetsOf(context).bottom,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _input,
                      contextMenuBuilder: V3TextEditing.buildContextMenu,
                      enabled: !_sending,
                      minLines: 1,
                      maxLines: 4,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                      decoration: const InputDecoration(hintText: '继续聊一聊'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    tooltip: '发送',
                    onPressed: _sending ? null : _send,
                    icon: _sending
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(LucideIcons.arrowUp, size: 20),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _send() async {
    final entry = _entry;
    if (entry == null) return;
    final message = _input.text.trim();
    if (message.isEmpty || _sending) return;
    setState(() {
      _messages.add((true, message));
      _input.clear();
      _sending = true;
    });
    try {
      final response = await entry.port.reply(
        session: entry.session,
        message: message,
      );
      if (mounted) setState(() => _messages.add((false, response)));
    } catch (_) {
      if (mounted) showV3Snack(context, '回复失败，请重试');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }
}

class _AggregationAgentSessionUnavailablePage extends StatelessWidget {
  const _AggregationAgentSessionUnavailablePage();

  @override
  Widget build(BuildContext context) {
    final colors = HuahuoV3Theme.tokensOf(context);
    return Scaffold(
      backgroundColor: colors.canvas,
      appBar: AppBar(
        backgroundColor: colors.canvas,
        surfaceTintColor: Colors.transparent,
        leading: const V3NavigationBackButton(
          fallbackRoute: AppRoutePaths.home,
        ),
        title: const Text('聊一聊'),
      ),
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(LucideIcons.messageSquareWarning, color: colors.muted),
                const SizedBox(height: 14),
                Text(
                  '会话已失效',
                  style: TextStyle(
                    color: colors.text,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '请返回聚合结果后重新开启聊一聊。',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: colors.muted),
                ),
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: () => returnToPreviousRoute(
                    context,
                    fallbackRoute: AppRoutePaths.home,
                  ),
                  icon: const Icon(LucideIcons.arrowLeft, size: 18),
                  label: Text(
                    canReturnToPreviousRoute(context) ? '返回上一级' : '返回首页',
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
