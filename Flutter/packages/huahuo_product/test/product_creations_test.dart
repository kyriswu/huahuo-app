import 'dart:async';

import 'package:huahuo_product/huahuo_product.dart';
import 'package:test/test.dart';

void main() {
  test('loads empty, selects a draft, and orders revisions', () async {
    final repository = _Repository()
      ..lists.addAll([
        Future.value(const ProductResult.success(<ProductCreationSummary>[])),
        Future.value(ProductResult.success([_summary()])),
      ])
      ..documents.add(Future.value(ProductResult.success(_document())))
      ..revisionResults.add(
        ProductResult.success([_revision(1), _revision(3), _revision(2)]),
      );
    final controller = ProductCreationsController(repository);
    addTearDown(controller.dispose);

    await controller.bindWorkspace('workspace-1');
    expect(controller.state.status, ProductCreationsStatus.empty);
    await controller.reload();
    await controller.select('creation-1');
    controller.updateTitle('更新标题');
    controller.updateMarkdown('# 更新内容');
    await controller.loadRevisions();

    expect(controller.state.isDirty, isTrue);
    expect(controller.state.revisions.map((item) => item.revision), [3, 2, 1]);
    controller.discardEdits();
    expect(controller.state.isDirty, isFalse);
  });

  test('contains failures and suppresses stale Workspace loads', () async {
    final first = Completer<ProductResult<List<ProductCreationSummary>>>();
    final second = Completer<ProductResult<List<ProductCreationSummary>>>();
    final third = Completer<ProductResult<List<ProductCreationSummary>>>();
    final repository = _Repository()
      ..lists.addAll([first.future, second.future, third.future]);
    final controller = ProductCreationsController(repository);
    addTearDown(controller.dispose);

    final initial = controller.bindWorkspace('workspace-1');
    final newer = controller.reload();
    second.complete(ProductResult.success([_summary(title: '新响应')]));
    await newer;
    first.complete(ProductResult.success([_summary(title: '旧响应')]));
    await initial;
    expect(controller.state.items.single.title, '新响应');

    final replacement = controller.bindWorkspace('workspace-2');
    controller.reset();
    third.complete(ProductResult.success([_summary(title: '失效响应')]));
    await replacement;
    expect(controller.state.status, ProductCreationsStatus.idle);

    repository.lists.add(Future.error(StateError('transport')));
    await controller.bindWorkspace('workspace-3');
    expect(controller.state.errorCode, 'PRODUCT_CREATIONS_UNEXPECTED');
    expect(controller.state.retryable, isTrue);
  });

  test('create and save retries reuse stable intent keys', () async {
    final repository = _Repository()
      ..lists.add(Future.value(const ProductResult.success([])))
      ..createResults.addAll([
        const ProductResult.failure(
          code: 'OFFLINE',
          message: '网络不可用',
          retryable: true,
        ),
        ProductResult.success(_document()),
      ])
      ..saveResults.addAll([
        const ProductResult.failure(
          code: 'OFFLINE',
          message: '网络不可用',
          retryable: true,
        ),
        ProductResult.success(
          _document(title: '新标题', markdown: '# 新内容', revision: 2),
        ),
      ]);
    var sequence = 0;
    final controller = ProductCreationsController(
      repository,
      keyFactory: (action) => 'key-${++sequence}',
    );
    addTearDown(controller.dispose);
    await controller.bindWorkspace('workspace-1');

    expect(await controller.create(title: '第一篇'), isFalse);
    expect(await controller.create(title: '第一篇'), isTrue);
    expect(repository.createKeys, ['key-1', 'key-1']);

    controller.updateTitle('新标题');
    controller.updateMarkdown('# 新内容');
    expect(await controller.save(), isFalse);
    expect(await controller.save(), isTrue);
    expect(repository.titleKeys, ['key-2', 'key-2']);
    expect(repository.contentKeys, ['key-3', 'key-3']);
    expect(controller.state.document?.summary.revision, 2);
    expect(controller.state.isDirty, isFalse);
  });

  test('delete and restore refresh authoritative lifecycle state', () async {
    final active = _summary();
    final trashed = _summary(lifecycle: 'trashed', revision: 2);
    final repository = _Repository()
      ..lists.addAll([
        Future.value(ProductResult.success([active])),
        Future.value(ProductResult.success([trashed])),
        Future.value(ProductResult.success([active])),
      ])
      ..documents.addAll([
        Future.value(ProductResult.success(_document())),
        Future.value(
          ProductResult.success(_document(lifecycle: 'trashed', revision: 2)),
        ),
      ])
      ..deleteResults.add(const ProductResult.success(null))
      ..restoreResults.add(const ProductResult.success(null));
    final controller = ProductCreationsController(
      repository,
      keyFactory: (action) => 'key-$action',
    );
    addTearDown(controller.dispose);

    await controller.bindWorkspace('workspace-1');
    await controller.select('creation-1');
    expect(await controller.deleteSelected(), isTrue);
    expect(controller.state.items.single.isTrashed, isTrue);
    expect(controller.state.selectedId, isNull);

    await controller.select('creation-1');
    expect(await controller.restoreSelected(), isTrue);
    expect(controller.state.items.single.isTrashed, isFalse);
    expect(repository.deleteKeys.single, contains('delete'));
    expect(repository.restoreKeys.single, contains('restore'));
  });
}

ProductCreationSummary _summary({
  String title = '第一篇',
  String lifecycle = 'active',
  int revision = 1,
}) => ProductCreationSummary(
  id: 'creation-1',
  title: title,
  lifecycle: lifecycle,
  revisionId: 'creation-revision-$revision',
  revision: revision,
  partRevisionIds: {'raw': 'raw-$revision'},
  etag: 'etag-$revision',
);

ProductCreationDocument _document({
  String title = '第一篇',
  String markdown = '# 初稿',
  String lifecycle = 'active',
  int revision = 1,
}) => ProductCreationDocument(
  summary: _summary(title: title, lifecycle: lifecycle, revision: revision),
  rawMarkdown: markdown,
  rawPartRevisionId: 'raw-$revision',
  rawPartEtag: 'raw-etag-$revision',
);

ProductCreationRevision _revision(int revision) => ProductCreationRevision(
  id: 'raw-$revision',
  revision: revision,
  markdown: '# 版本 $revision',
  createdAt: DateTime.utc(2026, 9, revision),
);

final class _Repository implements ProductCreationsRepository {
  final lists = <Future<ProductResult<List<ProductCreationSummary>>>>[];
  final documents = <Future<ProductResult<ProductCreationDocument>>>[];
  final createResults = <ProductResult<ProductCreationDocument>>[];
  final saveResults = <ProductResult<ProductCreationDocument>>[];
  final deleteResults = <ProductResult<void>>[];
  final restoreResults = <ProductResult<void>>[];
  final revisionResults = <ProductResult<List<ProductCreationRevision>>>[];
  final createKeys = <String>[];
  final titleKeys = <String>[];
  final contentKeys = <String>[];
  final deleteKeys = <String>[];
  final restoreKeys = <String>[];

  @override
  Future<ProductResult<ProductCreationDocument>> create({
    required String workspaceId,
    required String title,
    required String rawMarkdown,
    required String idempotencyKey,
  }) async {
    createKeys.add(idempotencyKey);
    return createResults.removeAt(0);
  }

  @override
  Future<ProductResult<void>> delete({
    required String workspaceId,
    required ProductCreationSummary creation,
    required String idempotencyKey,
  }) async {
    deleteKeys.add(idempotencyKey);
    return deleteResults.removeAt(0);
  }

  @override
  Future<ProductResult<ProductCreationDocument>> document(
    String workspaceId,
    String creationId,
  ) => documents.removeAt(0);

  @override
  Future<ProductResult<List<ProductCreationSummary>>> list(
    String workspaceId,
  ) => lists.removeAt(0);

  @override
  Future<ProductResult<void>> restore({
    required String workspaceId,
    required ProductCreationSummary creation,
    required String idempotencyKey,
  }) async {
    restoreKeys.add(idempotencyKey);
    return restoreResults.removeAt(0);
  }

  @override
  Future<ProductResult<List<ProductCreationRevision>>> revisions({
    required String workspaceId,
    required String creationId,
  }) async => revisionResults.removeAt(0);

  @override
  Future<ProductResult<ProductCreationDocument>> save({
    required String workspaceId,
    required ProductCreationDocument current,
    required String title,
    required String rawMarkdown,
    required String titleIdempotencyKey,
    required String contentIdempotencyKey,
  }) async {
    titleKeys.add(titleIdempotencyKey);
    contentKeys.add(contentIdempotencyKey);
    return saveResults.removeAt(0);
  }
}
