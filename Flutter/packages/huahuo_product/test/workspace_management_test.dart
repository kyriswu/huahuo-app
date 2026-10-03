import 'dart:async';

import 'package:huahuo_product/huahuo_product.dart';
import 'package:test/test.dart';

void main() {
  test('reload exposes empty, failure, and retry states', () async {
    final repository = _WorkspaceRepository()
      ..listResults.addAll(<Future<ProductResult<List<ProductWorkspace>>>>[
        Future.value(
          const ProductResult<List<ProductWorkspace>>.success(
            <ProductWorkspace>[],
          ),
        ),
        Future.value(
          const ProductResult<List<ProductWorkspace>>.failure(
            code: 'OFFLINE',
            message: '网络不可用',
            retryable: true,
          ),
        ),
        Future.value(
          ProductResult<List<ProductWorkspace>>.success(<ProductWorkspace>[
            _workspace('ws-1'),
          ]),
        ),
      ]);
    final controller = WorkspaceManagementController(repository);
    addTearDown(controller.dispose);

    await controller.reload();
    expect(controller.state.status, WorkspaceManagementStatus.empty);
    await controller.reload();
    expect(controller.state.status, WorkspaceManagementStatus.failure);
    expect(controller.state.retryable, isTrue);
    await controller.reload();
    expect(controller.state.status, WorkspaceManagementStatus.ready);
  });

  test('create retry reuses its key and reloads after success', () async {
    final repository = _WorkspaceRepository()
      ..createResults.addAll(<ProductResult<ProductWorkspaceBootstrap>>[
        const ProductResult<ProductWorkspaceBootstrap>.failure(
          code: 'TEMPORARY',
          message: '稍后重试',
          retryable: true,
        ),
        const ProductResult<ProductWorkspaceBootstrap>.success(
          ProductWorkspaceBootstrap(
            workspaceId: 'ws-2',
            state: 'ready',
            etag: '"ws-2"',
            bootstrapReceiptId: 'receipt-2',
            bootstrapContentCursor: '1',
            contentCursor: '1',
          ),
        ),
      ])
      ..listResults.add(
        Future.value(
          ProductResult<List<ProductWorkspace>>.success(<ProductWorkspace>[
            _workspace('ws-2', isDefault: true),
          ]),
        ),
      );
    final keys = <String>[];
    final controller = WorkspaceManagementController(
      repository,
      keyFactory: (operation, entityId) {
        final key = 'key-${keys.length + 1}';
        keys.add(key);
        return key;
      },
    );
    addTearDown(controller.dispose);

    expect(await controller.create(displayName: '工作空间'), isFalse);
    expect(await controller.create(displayName: '工作空间'), isTrue);

    expect(repository.createKeys, <String>['key-1', 'key-1']);
    expect(keys, <String>['key-1']);
    expect(controller.state.workspaces.single.workspaceId, 'ws-2');
  });

  test(
    'mutations forward current ETags and update immutable list state',
    () async {
      final repository = _WorkspaceRepository();
      final controller = WorkspaceManagementController(
        repository,
        keyFactory: (operation, entityId) => 'key-$operation',
      );
      addTearDown(controller.dispose);
      repository.listResults.add(
        Future.value(
          ProductResult<List<ProductWorkspace>>.success(<ProductWorkspace>[
            _workspace('ws-1', isDefault: true),
            _workspace('ws-2'),
          ]),
        ),
      );
      await controller.reload();

      expect(await controller.rename('ws-2', '团队空间'), isTrue);
      expect(await controller.setDefault('ws-2'), isTrue);
      expect(controller.state.workspace('ws-1')?.isDefault, isFalse);
      expect(controller.state.workspace('ws-2')?.isDefault, isTrue);
      expect(await controller.disable('ws-2'), isTrue);
      expect(controller.state.workspace('ws-2')?.state, 'disabled');
      expect(await controller.restore('ws-2'), isTrue);
      expect(controller.state.workspace('ws-2')?.state, 'ready');
      expect(repository.mutationEtags.first, '"ws-2-v1"');
      expect(repository.mutationEtags, hasLength(4));
    },
  );

  test('reset suppresses a stale list response', () async {
    final pending = Completer<ProductResult<List<ProductWorkspace>>>();
    final repository = _WorkspaceRepository()..listResults.add(pending.future);
    final controller = WorkspaceManagementController(repository);
    addTearDown(controller.dispose);

    final load = controller.reload();
    controller.reset();
    pending.complete(
      ProductResult<List<ProductWorkspace>>.success(<ProductWorkspace>[
        _workspace('stale'),
      ]),
    );
    await load;

    expect(controller.state.status, WorkspaceManagementStatus.idle);
    expect(controller.state.workspaces, isEmpty);
  });

  test('a newer reload wins within the same account generation', () async {
    final first = Completer<ProductResult<List<ProductWorkspace>>>();
    final second = Completer<ProductResult<List<ProductWorkspace>>>();
    final repository = _WorkspaceRepository()
      ..listResults.addAll(<Future<ProductResult<List<ProductWorkspace>>>>[
        first.future,
        second.future,
      ]);
    final controller = WorkspaceManagementController(repository);
    addTearDown(controller.dispose);

    final firstLoad = controller.reload();
    final secondLoad = controller.reload();
    second.complete(
      ProductResult<List<ProductWorkspace>>.success(<ProductWorkspace>[
        _workspace('newer'),
      ]),
    );
    await secondLoad;
    first.complete(
      ProductResult<List<ProductWorkspace>>.success(<ProductWorkspace>[
        _workspace('older'),
      ]),
    );
    await firstLoad;

    expect(controller.state.workspaces.single.workspaceId, 'newer');
  });
}

ProductWorkspace _workspace(
  String id, {
  String state = 'ready',
  bool isDefault = false,
  String? name,
  String? etag,
}) => ProductWorkspace(
  workspaceId: id,
  displayName: name ?? id,
  state: state,
  isDefault: isDefault,
  etag: etag ?? '"$id-v1"',
);

final class _WorkspaceRepository implements WorkspaceManagementRepository {
  final List<Future<ProductResult<List<ProductWorkspace>>>> listResults =
      <Future<ProductResult<List<ProductWorkspace>>>>[];
  final List<ProductResult<ProductWorkspaceBootstrap>> createResults =
      <ProductResult<ProductWorkspaceBootstrap>>[];
  final List<String> createKeys = <String>[];
  final List<String> mutationEtags = <String>[];

  @override
  Future<ProductResult<List<ProductWorkspace>>> list() =>
      listResults.removeAt(0);

  @override
  Future<ProductResult<ProductWorkspaceBootstrap>> create({
    required String displayName,
    required bool setAsDefault,
    required String idempotencyKey,
  }) async {
    createKeys.add(idempotencyKey);
    return createResults.removeAt(0);
  }

  @override
  Future<ProductResult<ProductWorkspace>> rename({
    required String workspaceId,
    required String displayName,
    required String etag,
    required String idempotencyKey,
  }) async {
    mutationEtags.add(etag);
    return ProductResult<ProductWorkspace>.success(
      _workspace(workspaceId, name: displayName, etag: '"$workspaceId-v2"'),
    );
  }

  @override
  Future<ProductResult<ProductWorkspace>> setDefault({
    required String workspaceId,
    required String etag,
    required String idempotencyKey,
  }) async {
    mutationEtags.add(etag);
    return ProductResult<ProductWorkspace>.success(
      _workspace(workspaceId, isDefault: true, etag: '"$workspaceId-v3"'),
    );
  }

  @override
  Future<ProductResult<ProductWorkspace>> disable({
    required String workspaceId,
    required String etag,
    required String idempotencyKey,
  }) async {
    mutationEtags.add(etag);
    return ProductResult<ProductWorkspace>.success(
      _workspace(workspaceId, state: 'disabled', etag: '"$workspaceId-v4"'),
    );
  }

  @override
  Future<ProductResult<ProductWorkspace>> restore({
    required String workspaceId,
    required String etag,
    required String idempotencyKey,
  }) async {
    mutationEtags.add(etag);
    return ProductResult<ProductWorkspace>.success(
      _workspace(workspaceId, etag: '"$workspaceId-v5"'),
    );
  }
}
