import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/features/chat/domain/chat_models.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_library_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_note_port.dart';
import 'package:huahuoai_app/features/ui_v3/application/subscription_port.dart';
import 'package:huahuoai_app/features/ui_v3/domain/feed_item_models.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_note_chat.dart';

void main() {
  test(
    'ordinary Note Chat route carries only the automatic source reference',
    () {
      final note = _note(id: 'referenced-note', title: '默认引用笔记');

      final uri = Uri.parse(v3NoteChatRoute(note));

      expect(uri.path, '/v3/feed/chat');
      expect(uri.queryParameters, <String, String>{'itemId': note.id});
      expect(uri.queryParameters.containsKey('presentation'), isFalse);
      expect(uri.queryParameters.containsKey('threadId'), isFalse);
      expect(uri.queryParameters.containsKey('autoSend'), isFalse);
    },
  );

  test('Note Chat expansion carries the active conversation and source', () {
    final note = _note(id: 'daily-topic-note', title: '每日推荐引用');

    final uri = Uri.parse(
      v3NoteChatRoute(
        note,
        threadId: 'note-thread',
        prompt: '继续讨论这篇内容',
        agentProfileId: 'self_media_creation_standard',
        expandFromSheet: true,
      ),
    );

    expect(uri.path, '/v3/feed/chat');
    expect(uri.queryParameters['itemId'], note.id);
    expect(uri.queryParameters['threadId'], 'note-thread');
    expect(uri.queryParameters['purpose'], 'general');
    expect(uri.queryParameters['prompt'], '继续讨论这篇内容');
    expect(
      uri.queryParameters['agentProfileId'],
      'self_media_creation_standard',
    );
    expect(uri.queryParameters['presentation'], 'sheet');
  });

  test('Note Chat expansion does not restore a removed source reference', () {
    final note = _note(id: 'asset-note', title: '已移除引用');

    final uri = Uri.parse(
      v3NoteChatRoute(
        note,
        includeItemReference: false,
        windowId: 'note-sheet-fresh-window',
        expandFromSheet: true,
      ),
    );

    expect(uri.queryParameters.containsKey('itemId'), isFalse);
    expect(uri.queryParameters['window'], 'note-sheet-fresh-window');
    expect(uri.queryParameters['presentation'], 'sheet');
  });

  test('Agent-assisted creation keeps collaborative auto-send prompts', () {
    const prompts = <WorkbenchChatSkill, String>{
      WorkbenchChatSkill.persona:
          '现在开始做选题。请先结合当前资料判断目前能推进到哪一步，再和我协作讨论，一起完成剩下的步骤。',
      WorkbenchChatSkill.lead:
          '现在开始做获客营销选题。请先结合当前资料判断目前能推进到哪一步，再和我协作讨论，一起完成剩下的步骤。',
    };
    for (final entry in prompts.entries) {
      expect(v3AgentCreationPrompt(entry.key), entry.value);
    }

    final note = _note(id: 'assisted-note', title: '明确目标资料');
    final uri = Uri.parse(
      v3AgentAssistedCreationRoute(
        item: note,
        selection: const V3NoteAgentCreationSelection(
          skill: WorkbenchChatSkill.persona,
        ),
      ),
    );
    expect(uri.queryParameters['entry'], 'agent-assisted-creation');
    expect(uri.queryParameters['skill'], 'persona');
    expect(uri.queryParameters['materialIds'], note.id);
    expect(uri.queryParameters['prompt'], prompts[WorkbenchChatSkill.persona]);
    expect(uri.queryParameters['autoSend'], '1');
  });

  test('Agent-assisted material preparation reuses one private copy', () async {
    final source = V3FeedItem(
      id: 'readonly-agent-source',
      title: '只读资料',
      source: V3MaterialSource.knowledgeSquare,
      ownership: V3NoteOwnership.knowledgeSquare,
      createdAt: _fixtureDate,
      rawBody: '需要先转换为私有 HNote。',
      articleRevisionId: 'generic-readonly-revision-1',
    );
    final notePort = _AgentCreationMaterialNotePort();
    final library = KnowledgeLibraryController(
      initialNotes: <V3FeedItem>[source],
      notePort: notePort,
    );

    final first = await prepareV3AgentCreationMaterial(
      library: library,
      item: source,
    );
    final second = await prepareV3AgentCreationMaterial(
      library: library,
      item: source,
    );

    expect(first, isNotNull);
    final firstId = first!.id;
    expect(first.ownership, V3NoteOwnership.mine);
    expect(first.copiedFromContentId, source.id);
    expect(first.remoteNoteId, 'remote-$firstId');
    expect(first.rawPartRevisionId, 'raw-$firstId-1');
    expect(second?.id, firstId);
    expect(notePort.requestedNoteIds, <String>[firstId]);
  });

  test(
    'Agent-assisted article preparation saves its exact version without following',
    () async {
      final article = V3FeedItem(
        id: 'remote-agent-article',
        title: '远程订阅文章',
        source: V3MaterialSource.subscription,
        ownership: V3NoteOwnership.subscribed,
        createdAt: _fixtureDate,
        rawBody: '精确版本正文。',
        publicationId: 'remote-agent-publication',
        articleId: 'remote-agent-article-id',
        articleRevisionId: 'remote-agent-revision-1',
      );
      final subscriptionPort = _AgentCreationSubscriptionPort(article);
      final library = KnowledgeLibraryController(
        initialNotes: const <V3FeedItem>[],
        subscriptionPort: subscriptionPort,
      );
      await library.reloadSubscriptions();
      final staleDetailItem = V3FeedItem(
        id: article.id,
        title: article.title,
        source: article.source,
        ownership: article.ownership,
        createdAt: article.createdAt,
        rawBody: article.rawBody,
      );

      final first = await prepareV3AgentCreationMaterial(
        library: library,
        item: staleDetailItem,
      );
      final second = await prepareV3AgentCreationMaterial(
        library: library,
        item: staleDetailItem,
      );

      expect(first?.id, 'saved-agent-article-note');
      expect(first?.articleRevisionId, article.articleRevisionId);
      expect(first?.rawPartRevisionId, 'saved-agent-article-raw-1');
      expect(second?.id, first?.id);
      expect(subscriptionPort.savedRevisionIds, <String>[
        'remote-agent-revision-1',
      ]);
      expect(subscriptionPort.followMutations, 0);
      expect(
        library.isRemotePublicationFollowed(article.publicationId!),
        isFalse,
      );
    },
  );

  testWidgets('Note Agent picker keeps only the two production choices', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: V3NoteAgentPickerSheet())),
    );

    expect(find.text('个人 IP 设计 Agent'), findsOneWidget);
    expect(find.text('获客营销选题 Agent'), findsOneWidget);
    expect(find.text('视觉设计 Agent'), findsNothing);
  });

  testWidgets('Note Agent flow immediately selects collaborative discussion', (
    tester,
  ) async {
    V3NoteAgentCreationSelection? selection;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => FilledButton(
              onPressed: () async {
                selection = await showV3NoteAgentCreationFlow(context);
              },
              child: const Text('开始辅助创作'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('开始辅助创作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('个人 IP 设计 Agent'));
    await tester.pumpAndSettle();

    expect(selection?.skill, WorkbenchChatSkill.persona);
    expect(find.text('选择创作方式'), findsNothing);
    expect(find.text('直接生成'), findsNothing);
    expect(find.text('协作讨论'), findsNothing);
  });
}

V3FeedItem _note({required String id, required String title}) => V3FeedItem(
  id: id,
  title: title,
  source: V3MaterialSource.note,
  createdAt: _fixtureDate,
  rawBody: '作为聊一聊的自动引用。',
);

final _fixtureDate = DateTime.utc(2026, 8, 25);

final class _AgentCreationMaterialNotePort implements KnowledgeNotePort {
  final requestedNoteIds = <String>[];

  @override
  Future<KnowledgeNotePortResult> updateNote(
    KnowledgeNoteUpdateRequest request,
  ) async {
    requestedNoteIds.add(request.noteId);
    return KnowledgeNotePortResult.success(
      V3FeedItem(
        id: request.noteId,
        title: request.draft.title,
        source: request.localNote?.source ?? V3MaterialSource.note,
        ownership: V3NoteOwnership.mine,
        copiedFromContentId: request.localNote?.copiedFromContentId,
        createdAt: request.localNote?.createdAt ?? _fixtureDate,
        rawBody: request.draft.rawBody,
        localRevision: request.localRevision,
        remoteRevision: 1,
        remoteNoteId: 'remote-${request.noteId}',
        noteRevisionId: 'note-${request.noteId}-1',
        rawPartRevisionId: 'raw-${request.noteId}-1',
        etag: 'etag-${request.noteId}-1',
        contentCursor: 'cursor-${request.noteId}-1',
      ),
    );
  }
}

final class _AgentCreationSubscriptionPort implements MobileSubscriptionPort {
  _AgentCreationSubscriptionPort(this.article);

  final V3FeedItem article;
  final List<String> savedRevisionIds = <String>[];
  int followMutations = 0;

  @override
  bool get isDemo => false;

  @override
  Future<MobileSubscriptionCatalogResult> loadCatalog() async =>
      MobileSubscriptionCatalogResult.success(<MobileSubscriptionPublication>[
        MobileSubscriptionPublication(
          publicationId: article.publicationId!,
          title: '测试出版物',
          sectionCount: 1,
          articleCount: 1,
          updatedAt: _fixtureDate,
          articles: <V3FeedItem>[article],
          followed: false,
          available: true,
        ),
      ]);

  @override
  Future<MobileSubscriptionActionResult> setPublicationFollowed({
    required String publicationId,
    required bool followed,
    required String actionId,
  }) async {
    followMutations += 1;
    return const MobileSubscriptionActionResult.success();
  }

  @override
  Future<MobileSubscriptionActionResult> loadArticle(
    V3FeedItem article,
  ) async => MobileSubscriptionActionResult.success(article);

  @override
  Future<MobileSubscriptionArticleAssetResult> loadArticleAsset({
    required V3FeedItem article,
    required V3SubscriptionArticleAssetRef asset,
  }) async => const MobileSubscriptionArticleAssetResult.unavailable(
    'SUBSCRIPTION_ASSET_NOT_AVAILABLE',
  );

  @override
  Future<MobileSubscriptionActionResult> saveArticleAsNote({
    required V3FeedItem article,
    required String actionId,
  }) async {
    savedRevisionIds.add(article.articleRevisionId!);
    return MobileSubscriptionActionResult.success(
      V3FeedItem(
        id: 'saved-agent-article-note',
        title: article.title,
        source: V3MaterialSource.note,
        ownership: V3NoteOwnership.mine,
        createdAt: article.createdAt,
        rawBody: article.rawBody,
        copiedFromContentId: article.id,
        publicationId: article.publicationId,
        articleId: article.articleId,
        articleRevisionId: article.articleRevisionId,
        remoteNoteId: 'saved-agent-article-note',
        noteRevisionId: 'saved-agent-article-note-revision-1',
        rawPartRevisionId: 'saved-agent-article-raw-1',
        remoteRevision: 1,
        syncState: NoteSyncState.synced,
      ),
    );
  }
}
