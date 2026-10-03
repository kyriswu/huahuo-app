import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/app/bootstrap/app_providers.dart';
import 'package:huahuoai_app/core/api/api_envelope.dart';
import 'package:huahuoai_app/core/api/idempotency.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/database/diagnostic_log_dao.dart';
import 'package:huahuoai_app/core/diagnostics/diagnostic_logger.dart';
import 'package:huahuoai_app/features/ingestion/application/material_ingestion_coordinator.dart';
import 'package:huahuoai_app/features/ingestion/data/material_ingestion_api.dart';
import 'package:huahuoai_app/features/ingestion/data/material_ingestion_store.dart';
import 'package:huahuoai_app/features/ingestion/domain/material_ingestion.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_library_controller.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_link_import_page.dart';

void main() {
  testWidgets('uses the app-owned Standard clipboard channel on iOS', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    const clipboardChannel = MethodChannel('huahuoai/plain_text_clipboard');
    final calls = <MethodCall>[];
    var systemClipboardCalls = 0;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(clipboardChannel, (call) async {
      calls.add(call);
      return 'https://example.com/copied';
    });
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') systemClipboardCalls += 1;
      return null;
    });
    try {
      expect(await readMaterialClipboardText(), 'https://example.com/copied');
      expect(calls, hasLength(1));
      expect(calls.single.method, 'readPlainText');
      expect(calls.single.arguments, isNull);
      expect(systemClipboardCalls, 0);
    } finally {
      debugDefaultTargetPlatformOverride = null;
      messenger.setMockMethodCallHandler(clipboardChannel, null);
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    }
  });

  testWidgets('prefills a copied URL without submitting it', (tester) async {
    final harness = _Harness();

    await tester.pumpWidget(
      _app(
        harness.coordinator,
        clipboardTextReader: () async => '复制链接 https://b23.tv/abc123 打开查看',
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'https://b23.tv/abc123',
    );
    expect(harness.api.submittedUrls, isEmpty);
  });

  testWidgets('shows supported content limits and validates the URL', (
    tester,
  ) async {
    final harness = _Harness();

    await tester.pumpWidget(_app(harness.coordinator));
    await tester.pump();

    expect(find.text('从链接导入'), findsOneWidget);
    expect(find.text('粘贴链接'), findsOneWidget);
    expect(find.textContaining('公开可访问'), findsOneWidget);
    expect(find.textContaining('自动生成并回传笔记'), findsOneWidget);
    expect(find.byType(Checkbox), findsNothing);

    await tester.tap(find.text('确定'));
    await tester.pump();
    expect(find.text('请输入有效的 http 或 https 链接'), findsOneWidget);
    expect(harness.api.submittedUrls, isEmpty);
  });

  testWidgets('historical failed draft does not take over a new URL', (
    tester,
  ) async {
    final harness = _Harness();
    harness.store.save(
      _failedDraft(
        id: 'historical-failure',
        url: 'https://old.example/article',
      ),
    );

    await tester.pumpWidget(_app(harness.coordinator));
    await tester.pump();

    expect(find.text('解析失败'), findsNothing);
    expect(find.text('确定'), findsOneWidget);

    await tester.enterText(
      find.byType(TextField),
      'https://new.example/article',
    );
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(harness.api.submittedUrls, <Uri>[
      Uri.parse('https://new.example/article'),
    ]);
  });

  testWidgets('fresh entry does not adopt a resident busy link draft', (
    tester,
  ) async {
    final harness = _Harness();
    harness.store.save(
      _failedDraft(
        id: 'resident-busy-link',
        url: 'https://old.example/processing',
      ).copyWith(status: MaterialIngestionStatus.queued, clearError: true),
    );

    await tester.pumpWidget(_app(harness.coordinator, freshEntry: true));
    await tester.pump();

    expect(find.text('从链接导入'), findsOneWidget);
    expect(find.text('链接分析中...'), findsNothing);
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('exact recovery entry binds only its requested link draft', (
    tester,
  ) async {
    final harness = _Harness();
    for (final draft in <MaterialIngestionDraft>[
      _failedDraft(
        id: 'other-busy-link',
        url: 'https://other.example/processing',
      ).copyWith(status: MaterialIngestionStatus.queued, clearError: true),
      _failedDraft(
        id: 'requested-busy-link',
        url: 'https://requested.example/processing',
      ).copyWith(status: MaterialIngestionStatus.queued, clearError: true),
    ]) {
      harness.store.save(draft);
    }

    await tester.pumpWidget(
      _app(harness.coordinator, initialDraftId: 'requested-busy-link'),
    );
    await tester.pump();

    expect(find.text('链接分析中...'), findsOneWidget);
    expect(find.text('https://requested.example/processing'), findsOneWidget);
    expect(find.text('https://other.example/processing'), findsNothing);
  });

  testWidgets('missing exact recovery id never adopts another busy draft', (
    tester,
  ) async {
    final harness = _Harness();
    harness.store.save(
      _failedDraft(
        id: 'unrelated-busy-link',
        url: 'https://other.example/processing',
      ).copyWith(status: MaterialIngestionStatus.queued, clearError: true),
    );

    await tester.pumpWidget(
      _app(harness.coordinator, initialDraftId: 'missing-link-draft'),
    );
    await tester.pump();

    expect(find.text('链接导入任务'), findsOneWidget);
    expect(find.text('该链接任务已结束或当前不可恢复'), findsOneWidget);
    expect(find.text('链接分析中...'), findsNothing);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('exact failed recovery restores its URL for retry', (
    tester,
  ) async {
    final harness = _Harness();
    harness.store.save(
      _failedDraft(
        id: 'requested-failed-link',
        url: 'https://requested.example/failed',
      ),
    );

    await tester.pumpWidget(
      _app(harness.coordinator, initialDraftId: 'requested-failed-link'),
    );
    await tester.pumpAndSettle();

    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      'https://requested.example/failed',
    );
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets(
    'server configuration failure refreshes without claiming a restart',
    (tester) async {
      final harness = _Harness();
      final failed =
          _failedDraft(
            id: 'legacy-xhs-failure',
            url: 'https://xhslink.cn/o/example',
          ).copyWith(
            checkpoint: MaterialIngestionCheckpoint.taskSubmitted,
            remoteTaskId: 'ingestion-xhs',
            lastErrorCode: 'PYTHON_VERSION_UNSUPPORTED',
          );
      harness.store.save(failed);
      final refreshed = Completer<ApiResult<MaterialTaskSnapshot>>();
      harness.api.linkPollResult = refreshed.future;

      await tester.pumpWidget(
        _app(harness.coordinator, initialDraftId: failed.id),
      );
      await tester.pumpAndSettle();
      expect(find.text('刷新状态'), findsOneWidget);
      expect(find.text('链接解析服务配置异常，需要服务端修复；不是链接格式或公开权限问题。'), findsOneWidget);
      expect(find.text('PYTHON_VERSION_UNSUPPORTED'), findsNothing);
      expect(find.text('解析没有完成，请确认内容可公开访问后重试'), findsNothing);

      await tester.tap(find.text('刷新状态'));
      await tester.pump();
      expect(find.text('正在查询链接任务...'), findsOneWidget);
      expect(find.text('仅查询已提交任务的状态，不会重新执行链接分析。'), findsOneWidget);
      expect(find.text('链接分析中...'), findsNothing);
      expect(
        harness.store.get(failed.id)?.status,
        MaterialIngestionStatus.failed,
      );
      expect(harness.api.submittedUrls, isEmpty);
      expect(harness.api.linkPollTaskIds, <String>['ingestion-xhs']);

      refreshed.complete(
        ApiResult<MaterialTaskSnapshot>.success(
          status: 200,
          data: const MaterialTaskSnapshot(
            taskId: 'ingestion-xhs',
            status: MaterialRemoteTaskStatus.failed,
            errorCode: 'PYTHON_VERSION_UNSUPPORTED',
          ),
          idempotencyStore: SubmissionKeyStore.empty,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('刷新状态'), findsOneWidget);
      expect(find.text('链接解析服务配置异常，需要服务端修复；不是链接格式或公开权限问题。'), findsOneWidget);
      expect(harness.api.submittedUrls, isEmpty);
    },
  );

  testWidgets('submits a normalized URL without unsupported extra intent', (
    tester,
  ) async {
    final harness = _Harness();
    await tester.pumpWidget(_app(harness.coordinator));
    expect(
      find.byKey(const ValueKey('link-import-distillation-option')),
      findsNothing,
    );
    await tester.enterText(
      find.byType(TextField),
      'https://example.com/item#fragment',
    );
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(harness.api.submittedUrls, <Uri>[
      Uri.parse('https://example.com/item'),
    ]);
  });

  testWidgets('editing the current failed draft creates a different URL', (
    tester,
  ) async {
    final harness = _Harness();

    await tester.pumpWidget(_app(harness.coordinator));
    await tester.enterText(
      find.byType(TextField),
      'https://first.example/article',
    );
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(find.text('重试'), findsOneWidget);
    expect(find.text('暂时无法解析此链接，请稍后重试'), findsOneWidget);
    expect(find.text('LINK_IMPORT_SERVICE_UNAVAILABLE'), findsNothing);

    await tester.enterText(
      find.byType(TextField),
      'https://second.example/article',
    );
    await tester.pump();

    expect(find.text('确定'), findsOneWidget);
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(harness.api.submittedUrls, <Uri>[
      Uri.parse('https://first.example/article'),
      Uri.parse('https://second.example/article'),
    ]);
    expect(
      harness.store.listAll().where(
        (draft) => draft.source == MaterialIngestionSource.link,
      ),
      hasLength(2),
    );
  });

  testWidgets('reports a transient 39 ingestion failure without raw codes', (
    tester,
  ) async {
    final harness = _Harness(failureCode: 'NOTE_PROJECTION_FAILED');
    await tester.pumpWidget(_app(harness.coordinator));
    await tester.enterText(
      find.byType(TextField),
      'https://www.xiaohongshu.com/discovery/item/6a735fbb0000000021021fe2',
    );
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(find.text('暂时无法解析此链接，请稍后重试'), findsOneWidget);
    expect(find.text('NOTE_PROJECTION_FAILED'), findsNothing);
    expect(harness.api.submittedUrls, <Uri>[
      Uri.parse(
        'https://www.xiaohongshu.com/discovery/item/6a735fbb0000000021021fe2',
      ),
    ]);
  });

  testWidgets('renders backend URL validation as a public-access error', (
    tester,
  ) async {
    final harness = _Harness(failureCode: 'URL_IMPORT_INVALID');
    await tester.pumpWidget(_app(harness.coordinator));
    await tester.enterText(find.byType(TextField), 'https://b23.tv/igFRi76');
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(find.text('链接无效或内容无法公开访问，请检查后重试'), findsOneWidget);
    expect(find.text('URL_IMPORT_INVALID'), findsNothing);
  });
}

Widget _app(
  MaterialIngestionCoordinator coordinator, {
  MaterialClipboardTextReader? clipboardTextReader,
  ProviderContainer? container,
  bool freshEntry = false,
  String? initialDraftId,
}) {
  final app = MaterialApp(
    home: V3LinkImportPage(
      clipboardTextReader: clipboardTextReader ?? _emptyClipboard,
      freshEntry: freshEntry,
      initialDraftId: initialDraftId,
    ),
  );
  if (container != null) {
    return UncontrolledProviderScope(container: container, child: app);
  }
  return ProviderScope(
    overrides: <Override>[
      materialIngestionCoordinatorProvider.overrideWith((ref) => coordinator),
    ],
    child: app,
  );
}

Future<String?> _emptyClipboard() async => null;

final class _Harness {
  _Harness({String failureCode = 'LINK_IMPORT_SERVICE_UNAVAILABLE'})
    : database = AppDatabase(),
      api = _FailingMaterialApi(failureCode),
      knowledge = KnowledgeLibraryController(initialNotes: const []) {
    store = MaterialIngestionStore(database: database);
    coordinator = MaterialIngestionCoordinator(
      api: api,
      store: store,
      knowledgeLibrary: knowledge,
      logger: DiagnosticLogger(dao: DiagnosticLogDao(database)),
      delay: (_) async {},
      maxPollAttempts: 1,
    );
  }

  final AppDatabase database;
  final _FailingMaterialApi api;
  final KnowledgeLibraryController knowledge;
  late final MaterialIngestionStore store;
  late final MaterialIngestionCoordinator coordinator;
}

MaterialIngestionDraft _failedDraft({required String id, required String url}) {
  final timestamp = DateTime.utc(2026, 7, 14, 9);
  return MaterialIngestionDraft(
    id: id,
    source: MaterialIngestionSource.link,
    status: MaterialIngestionStatus.failed,
    checkpoint: MaterialIngestionCheckpoint.created,
    title: Uri.parse(url).host,
    normalizedUrl: url,
    createdAt: timestamp,
    updatedAt: timestamp,
    submitKey: 'submit-$id',
    lastErrorCode: 'LINK_IMPORT_SERVICE_UNAVAILABLE',
  );
}

final class _FailingMaterialApi implements MaterialIngestionApiPort {
  _FailingMaterialApi(this.failureCode);

  final String failureCode;
  final List<Uri> submittedUrls = <Uri>[];
  final List<String> linkPollTaskIds = <String>[];
  Future<ApiResult<MaterialTaskSnapshot>>? linkPollResult;

  @override
  Future<ApiResult<MaterialTaskSnapshot>> createLinkImport({
    required Uri url,
    required String idempotencyKey,
  }) async {
    submittedUrls.add(url);
    return _failure(failureCode);
  }

  @override
  Future<ApiResult<MaterialTaskSnapshot>> createVideoAnalysis({
    required String resourceId,
    required String title,
    required String idempotencyKey,
  }) {
    throw StateError('unexpected video analysis');
  }

  @override
  Future<ApiResult<GeneratedMemoryNote>> getMemoryNote(String noteId) {
    throw StateError('unexpected memory note');
  }

  @override
  Future<ApiResult<MaterialTaskSnapshot>> getLinkImport(String taskId) {
    linkPollTaskIds.add(taskId);
    if (linkPollResult != null) return linkPollResult!;
    throw StateError('unexpected link poll');
  }

  @override
  Future<ApiResult<MaterialLinkOutlineOwnership>> getLinkOutlineOwnership(
    String taskId,
  ) {
    throw StateError('unexpected link outline ownership read');
  }

  @override
  Future<ApiResult<MaterialTaskSnapshot>> getVideoAnalysis(String taskId) {
    throw StateError('unexpected video poll');
  }

  @override
  Future<ApiResult<PageResult<GeneratedMemoryNote>>> listMemoryNotes({
    String? cursor,
  }) {
    throw StateError('unexpected memory-note list');
  }
}

ApiResult<T> _failure<T>(String code) => ApiResult<T>.failure(
  error: AppFailure(
    code: code,
    category: AppFailureCategory.api,
    message: 'failed',
    userMessageKey: 'test.$code',
    isRetryable: true,
    recoveryActions: const <String>['retry'],
  ),
  idempotencyStore: SubmissionKeyStore.empty,
);
