import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../shared/theme/huahuo_v3_theme.dart';
import '../../../shared/ui_v3/v3_components.dart';
import '../../../shared/ui_v3/v3_liquid_glass.dart';
import '../application/feed_graph_controller.dart';
import '../application/knowledge_library_controller.dart';
import '../domain/ui_v3_models.dart';
import 'v3_graph_node_action_card.dart';
import 'v3_graph_node_detail_sheet.dart';
import 'v3_interactive_graph.dart';

class V3GraphFullscreenPage extends ConsumerWidget {
  const V3GraphFullscreenPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = HuahuoV3Theme.tokensOf(context);
    final selectedContentId = ref.watch(
      feedGraphControllerProvider.select(
        (controller) => controller.selectedNodeId == null
            ? null
            : controller.nodeForId(controller.selectedNodeId!)?.contentId ??
                  controller.selectedNodeId,
      ),
    );
    final selectedNote = ref.watch(
      knowledgeNoteProvider(selectedContentId ?? ''),
    );

    return V3GlassHomeScope(
      child: Scaffold(
        key: const ValueKey('graph-fullscreen-page'),
        backgroundColor: colors.canvas,
        body: SizedBox.expand(
          child: ColoredBox(
            color: colors.canvas,
            child: Stack(
              children: [
                Positioned.fill(
                  child: V3InteractiveGraph(
                    aggregated: true,
                    fullscreen: true,
                    height: double.infinity,
                    onCanvasTap: () =>
                        ref.read(feedGraphControllerProvider).clearSelection(),
                    onNodeTap: (node) => _selectNode(context, ref, node),
                    onSelectedNodeTap: (node) =>
                        _openSelectedNode(context, ref, node),
                    onNodeLongPress: (node) => _selectNode(context, ref, node),
                    onCreateContent: () => context.push('/v3/feed/note'),
                  ),
                ),
                const SafeArea(
                  bottom: false,
                  child: V3PageTopBar(title: '知识图谱', fallbackRoute: '/v3/feed'),
                ),
                if (selectedNote != null)
                  Positioned(
                    left: 22,
                    right: 22,
                    bottom: 0,
                    child: SafeArea(
                      top: false,
                      minimum: const EdgeInsets.only(bottom: 12),
                      child: V3GraphNodeActionCard(
                        key: ValueKey(
                          'graph-fullscreen-node-card-${selectedNote.id}',
                        ),
                        note: selectedNote,
                        onView: () => context.push(
                          '/v3/feed/items/${Uri.encodeComponent(selectedNote.id)}',
                        ),
                        onChat: () => context.push(
                          '/v3/feed/chat?itemId=${Uri.encodeQueryComponent(selectedNote.id)}',
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _selectNode(BuildContext context, WidgetRef ref, V3GraphNode node) {
    final graph = ref.read(feedGraphControllerProvider);
    graph.selectNode(node.center ? null : node.id);
    if (node.center || _localContentId(ref, node) != null) return;
    unawaited(
      showV3GraphNodeDetailSheet(
        context: context,
        node: node,
        edges: graph.semanticEdges,
        nodesById: <String, V3GraphNode>{
          for (final candidate in graph.nodes) candidate.id: candidate,
        },
      ),
    );
  }

  void _openSelectedNode(
    BuildContext context,
    WidgetRef ref,
    V3GraphNode node,
  ) {
    final contentId = _localContentId(ref, node);
    if (contentId != null) {
      context.push('/v3/feed/items/${Uri.encodeComponent(contentId)}');
      return;
    }
    _selectNode(context, ref, node);
  }

  String? _localContentId(WidgetRef ref, V3GraphNode node) {
    final contentId = node.contentId ?? node.id;
    return ref.read(knowledgeLibraryControllerProvider).noteForId(contentId) ==
            null
        ? null
        : contentId;
  }
}
