import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuo_desktop/features/workspaces/widgets/desktop_workspace_management_workspace.dart';
import 'package:huahuo_product/huahuo_product.dart';

void main() {
  testWidgets('create and rename controls execute shared commands', (
    tester,
  ) async {
    final repository = _WorkspaceRepository(<ProductWorkspace>[
      _workspace('ws-1', name: '个人空间', isDefault: true),
      _workspace('ws-2', name: '团队空间'),
    ]);
    final controller = WorkspaceManagementController(
      repository,
      keyFactory: (operation, entityId) => 'key-$operation',
    );
    addTearDown(controller.dispose);
    await controller.reload();
    final switched = <String>[];
    await _pump(tester, controller, switched);

    await tester.tap(
      find.byKey(const ValueKey<String>('workspace-rename-ws-2')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('workspace-rename-name')),
      '品牌团队',
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('workspace-rename-confirm')),
    );
    await tester.pumpAndSettle();
    expect(repository.renameNames, <String>['品牌团队']);
    expect(find.text('品牌团队'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('workspace-create')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('workspace-create-name')),
      '新项目',
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('workspace-create-confirm')),
    );
    await tester.pumpAndSettle();
    expect(repository.createNames, <String>['新项目']);
    expect(find.text('新项目'), findsOneWidget);
    expect(switched, <String>['ws-3']);
  });

  testWidgets('switch, disable, and restore update the visible list', (
    tester,
  ) async {
    final repository = _WorkspaceRepository(<ProductWorkspace>[
      _workspace('ws-1', name: '个人空间', isDefault: true),
      _workspace('ws-2', name: '团队空间'),
    ]);
    final controller = WorkspaceManagementController(
      repository,
      keyFactory: (operation, entityId) => 'key-$operation',
    );
    addTearDown(controller.dispose);
    await controller.reload();
    final switched = <String>[];
    await _pump(tester, controller, switched);

    await tester.tap(
      find.byKey(const ValueKey<String>('workspace-default-ws-2')),
    );
    await tester.pumpAndSettle();
    expect(switched, <String>['ws-2']);

    await tester.tap(
      find.byKey(const ValueKey<String>('workspace-disable-ws-1')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('workspace-disable-confirm')),
    );
    await tester.pumpAndSettle();
    expect(repository.disabled, <String>['ws-1']);
    expect(
      find.byKey(const ValueKey<String>('workspace-restore-ws-1')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('workspace-restore-ws-1')),
    );
    await tester.pumpAndSettle();
    expect(repository.restored, <String>['ws-1']);
    expect(
      find.byKey(const ValueKey<String>('workspace-disable-ws-1')),
      findsOneWidget,
    );
  });

  testWidgets('failure page retries and busy mutation disables row controls', (
    tester,
  ) async {
    final repository = _WorkspaceRepository(<ProductWorkspace>[
      _workspace('ws-1', isDefault: true),
      _workspace('ws-2'),
    ])..failNextList = true;
    final controller = WorkspaceManagementController(
      repository,
      keyFactory: (operation, entityId) => 'key-$operation',
    );
    addTearDown(controller.dispose);
    await controller.reload();
    await _pump(tester, controller, <String>[]);

    expect(find.text('测试网络失败'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('workspace-retry')));
    await tester.pumpAndSettle();
    expect(find.text('ws-2'), findsOneWidget);

    repository.pendingDefault = Completer<ProductResult<ProductWorkspace>>();
    await tester.tap(
      find.byKey(const ValueKey<String>('workspace-default-ws-2')),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('workspace-default-ws-2')),
      findsNothing,
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    repository.pendingDefault!.complete(
      ProductResult<ProductWorkspace>.success(
        _workspace('ws-2', isDefault: true, etag: '"ws-2-v2"'),
      ),
    );
    await tester.pumpAndSettle();
    expect(repository.defaulted, <String>['ws-2']);
  });
}

Future<void> _pump(
  WidgetTester tester,
  WorkspaceManagementController controller,
  List<String> switched,
) async {
  tester.view.physicalSize = const Size(1000, 700);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: DesktopWorkspaceManagementWorkspace(
          controller: controller,
          onDefaultWorkspaceChanged: (workspaceId) async {
            switched.add(workspaceId);
          },
        ),
      ),
    ),
  );
}

ProductWorkspace _workspace(
  String id, {
  String? name,
  String state = 'ready',
  bool isDefault = false,
  String? etag,
}) => ProductWorkspace(
  workspaceId: id,
  displayName: name ?? id,
  state: state,
  isDefault: isDefault,
  etag: etag ?? '"$id-v1"',
);

final class _WorkspaceRepository implements WorkspaceManagementRepository {
  _WorkspaceRepository(List<ProductWorkspace> workspaces)
    : _workspaces = List<ProductWorkspace>.of(workspaces);

  List<ProductWorkspace> _workspaces;
  bool failNextList = false;
  Completer<ProductResult<ProductWorkspace>>? pendingDefault;
  final List<String> createNames = <String>[];
  final List<String> renameNames = <String>[];
  final List<String> defaulted = <String>[];
  final List<String> disabled = <String>[];
  final List<String> restored = <String>[];

  @override
  Future<ProductResult<List<ProductWorkspace>>> list() async {
    if (failNextList) {
      failNextList = false;
      return const ProductResult<List<ProductWorkspace>>.failure(
        code: 'OFFLINE',
        message: '测试网络失败',
        retryable: true,
      );
    }
    return ProductResult<List<ProductWorkspace>>.success(
      List<ProductWorkspace>.of(_workspaces),
    );
  }

  @override
  Future<ProductResult<ProductWorkspaceBootstrap>> create({
    required String displayName,
    required bool setAsDefault,
    required String idempotencyKey,
  }) async {
    createNames.add(displayName);
    if (setAsDefault) {
      _workspaces = <ProductWorkspace>[
        for (final workspace in _workspaces)
          workspace.copyWith(isDefault: false),
      ];
    }
    final id = 'ws-${_workspaces.length + 1}';
    _workspaces.add(_workspace(id, name: displayName, isDefault: setAsDefault));
    return ProductResult<ProductWorkspaceBootstrap>.success(
      ProductWorkspaceBootstrap(
        workspaceId: id,
        state: 'ready',
        etag: '"$id-v1"',
        bootstrapReceiptId: 'receipt-$id',
        bootstrapContentCursor: '1',
        contentCursor: '1',
      ),
    );
  }

  @override
  Future<ProductResult<ProductWorkspace>> rename({
    required String workspaceId,
    required String displayName,
    required String etag,
    required String idempotencyKey,
  }) async {
    renameNames.add(displayName);
    final current = _byId(workspaceId);
    final updated = _workspace(
      workspaceId,
      name: displayName,
      state: current.state,
      isDefault: current.isDefault,
      etag: '"$workspaceId-v2"',
    );
    _replace(updated);
    return ProductResult<ProductWorkspace>.success(updated);
  }

  @override
  Future<ProductResult<ProductWorkspace>> setDefault({
    required String workspaceId,
    required String etag,
    required String idempotencyKey,
  }) async {
    defaulted.add(workspaceId);
    final pending = pendingDefault;
    if (pending != null) return pending.future;
    _workspaces = <ProductWorkspace>[
      for (final workspace in _workspaces)
        workspace.copyWith(isDefault: workspace.workspaceId == workspaceId),
    ];
    return ProductResult<ProductWorkspace>.success(_byId(workspaceId));
  }

  @override
  Future<ProductResult<ProductWorkspace>> disable({
    required String workspaceId,
    required String etag,
    required String idempotencyKey,
  }) async {
    disabled.add(workspaceId);
    final current = _byId(workspaceId);
    final updated = _workspace(
      workspaceId,
      name: current.displayName,
      state: 'disabled',
      etag: '"$workspaceId-disabled"',
    );
    _replace(updated);
    return ProductResult<ProductWorkspace>.success(updated);
  }

  @override
  Future<ProductResult<ProductWorkspace>> restore({
    required String workspaceId,
    required String etag,
    required String idempotencyKey,
  }) async {
    restored.add(workspaceId);
    final current = _byId(workspaceId);
    final updated = _workspace(
      workspaceId,
      name: current.displayName,
      etag: '"$workspaceId-restored"',
    );
    _replace(updated);
    return ProductResult<ProductWorkspace>.success(updated);
  }

  ProductWorkspace _byId(String workspaceId) => _workspaces.singleWhere(
    (workspace) => workspace.workspaceId == workspaceId,
  );

  void _replace(ProductWorkspace updated) {
    _workspaces = <ProductWorkspace>[
      for (final workspace in _workspaces)
        workspace.workspaceId == updated.workspaceId ? updated : workspace,
    ];
  }
}
