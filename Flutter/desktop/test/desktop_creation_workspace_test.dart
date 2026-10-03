import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuo_desktop/features/creations/widgets/desktop_creation_workspace.dart';
import 'package:huahuo_product/huahuo_product.dart';

void main() {
  Future<void> pumpWorkspace(
    WidgetTester tester,
    _Repository repository, {
    Size size = const Size(1100, 760),
    void Function(ProductCreationDocument)? onProposal,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DesktopCreationWorkspace(
            workspaceId: 'workspace-1',
            repository: repository,
            onOpenProposals: onProposal ?? (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('selects, edits, saves, opens versions and proposal handoff', (
    tester,
  ) async {
    final repository = _Repository()..documents['creation-1'] = _document();
    ProductCreationDocument? proposed;
    await pumpWorkspace(
      tester,
      repository,
      onProposal: (document) => proposed = document,
    );

    await tester.tap(find.byKey(const ValueKey('creation-item-creation-1')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('creation-title')),
      '更新标题',
    );
    await tester.enterText(
      find.byKey(const ValueKey('creation-markdown')),
      '# 更新正文',
    );
    await tester.tap(find.byKey(const ValueKey('creation-save')));
    await tester.pumpAndSettle();

    expect(repository.documents['creation-1']?.summary.title, '更新标题');
    expect(repository.documents['creation-1']?.rawMarkdown, '# 更新正文');
    await tester.tap(find.byKey(const ValueKey('creation-proposals')));
    expect(proposed?.summary.id, 'creation-1');

    await tester.tap(find.byKey(const ValueKey('creation-versions')));
    await tester.pumpAndSettle();
    expect(find.text('正文版本'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('creation-revision-raw-2')),
      findsOneWidget,
    );
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
  });

  testWidgets('creates, deletes, filters trash, and restores', (tester) async {
    final repository = _Repository()..documents['creation-1'] = _document();
    await pumpWorkspace(tester, repository);

    await tester.tap(find.byKey(const ValueKey('creation-create')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('creation-new-title')),
      '桌面新稿',
    );
    await tester.enterText(
      find.byKey(const ValueKey('creation-new-content')),
      '# 新稿',
    );
    await tester.tap(find.byKey(const ValueKey('creation-new-confirm')));
    await tester.pumpAndSettle();
    expect(repository.documents.values.last.summary.title, '桌面新稿');

    await tester.tap(find.byKey(const ValueKey('creation-delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('creation-delete-confirm')));
    await tester.pumpAndSettle();
    expect(repository.documents.values.last.summary.isTrashed, isTrue);

    await tester.tap(find.text('回收站'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('桌面新稿'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('creation-restore')));
    await tester.pumpAndSettle();
    expect(repository.documents.values.last.summary.isTrashed, isFalse);
  });

  testWidgets('compact editor returns to list', (tester) async {
    final repository = _Repository()..documents['creation-1'] = _document();
    await pumpWorkspace(tester, repository, size: const Size(700, 680));

    await tester.tap(find.byKey(const ValueKey('creation-item-creation-1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('creation-back')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('creation-back')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('creation-item-creation-1')),
      findsOneWidget,
    );
  });

  testWidgets('shows load failure and retries', (tester) async {
    final repository = _Repository()..failListCount = 1;
    await pumpWorkspace(tester, repository);

    expect(find.text('创作历史加载失败'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('creation-retry')));
    await tester.pumpAndSettle();
    expect(find.text('第一篇'), findsOneWidget);
  });
}

final class _Repository implements ProductCreationsRepository {
  final Map<String, ProductCreationDocument> documents = {};
  var failListCount = 0;
  var _sequence = 1;

  @override
  Future<ProductResult<List<ProductCreationSummary>>> list(
    String workspaceId,
  ) async {
    if (failListCount > 0) {
      failListCount--;
      return const ProductResult.failure(
        code: 'OFFLINE',
        message: '网络不可用',
        retryable: true,
      );
    }
    documents.putIfAbsent('creation-1', _document);
    return ProductResult.success(
      documents.values.map((item) => item.summary).toList(),
    );
  }

  @override
  Future<ProductResult<ProductCreationDocument>> document(
    String workspaceId,
    String creationId,
  ) async => ProductResult.success(documents[creationId]!);

  @override
  Future<ProductResult<ProductCreationDocument>> create({
    required String workspaceId,
    required String title,
    required String rawMarkdown,
    required String idempotencyKey,
  }) async {
    _sequence++;
    final id = 'creation-$_sequence';
    final created = _document(
      id: id,
      title: title,
      markdown: rawMarkdown,
      revision: 1,
    );
    documents[id] = created;
    return ProductResult.success(created);
  }

  @override
  Future<ProductResult<ProductCreationDocument>> save({
    required String workspaceId,
    required ProductCreationDocument current,
    required String title,
    required String rawMarkdown,
    required String titleIdempotencyKey,
    required String contentIdempotencyKey,
  }) async {
    final saved = _document(
      id: current.summary.id,
      title: title,
      markdown: rawMarkdown,
      revision: current.summary.revision + 1,
    );
    documents[current.summary.id] = saved;
    return ProductResult.success(saved);
  }

  @override
  Future<ProductResult<void>> delete({
    required String workspaceId,
    required ProductCreationSummary creation,
    required String idempotencyKey,
  }) async {
    final current = documents[creation.id]!;
    documents[creation.id] = _document(
      id: creation.id,
      title: creation.title,
      markdown: current.rawMarkdown,
      lifecycle: 'trashed',
      revision: creation.revision + 1,
    );
    return const ProductResult.success(null);
  }

  @override
  Future<ProductResult<void>> restore({
    required String workspaceId,
    required ProductCreationSummary creation,
    required String idempotencyKey,
  }) async {
    final current = documents[creation.id]!;
    documents[creation.id] = _document(
      id: creation.id,
      title: creation.title,
      markdown: current.rawMarkdown,
      revision: creation.revision + 1,
    );
    return const ProductResult.success(null);
  }

  @override
  Future<ProductResult<List<ProductCreationRevision>>> revisions({
    required String workspaceId,
    required String creationId,
  }) async => ProductResult.success([
    ProductCreationRevision(
      id: 'raw-2',
      revision: 2,
      markdown: '# 第二稿',
      createdAt: DateTime.utc(2026, 9, 3),
    ),
    ProductCreationRevision(
      id: 'raw-1',
      revision: 1,
      markdown: '# 初稿',
      createdAt: DateTime.utc(2026, 9, 2),
    ),
  ]);
}

ProductCreationDocument _document({
  String id = 'creation-1',
  String title = '第一篇',
  String markdown = '# 初稿',
  String lifecycle = 'active',
  int revision = 1,
}) => ProductCreationDocument(
  summary: ProductCreationSummary(
    id: id,
    title: title,
    lifecycle: lifecycle,
    revisionId: '$id-revision-$revision',
    revision: revision,
    partRevisionIds: {'raw': '$id-raw-$revision'},
    etag: 'etag-$revision',
  ),
  rawMarkdown: markdown,
  rawPartRevisionId: '$id-raw-$revision',
  rawPartEtag: 'part-etag-$revision',
);
