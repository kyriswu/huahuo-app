import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuo_api/huahuo_api.dart';
import 'package:huahuoai_app/features/book_work/application/mobile_book_work_controller.dart';
import 'package:huahuoai_app/features/book_work/data/mobile_book_work_port.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_library_controller.dart';
import 'package:huahuoai_app/features/ui_v3/domain/feed_item_models.dart';
import 'package:huahuoai_app/features/ui_v3/presentation/v3_masterpiece_page.dart';

void main() {
  testWidgets(
    'masterpiece entry traverses Book, Work, exact Parts and mutations',
    (tester) async {
      final port = _SheetBookWorkPort()..completeFailureCount = 1;
      await _pump(tester, port);

      await _openBookWork(tester);
      expect(
        find.byKey(const ValueKey<String>('mobile-book-work-sheet')),
        findsOneWidget,
      );
      final preface = find.byKey(
        const ValueKey<String>('mobile-book-section-preface'),
      );
      final chapter = find.byKey(
        const ValueKey<String>('mobile-book-section-chapter_1'),
      );
      expect(
        tester.getTopLeft(preface).dy,
        lessThan(tester.getTopLeft(chapter).dy),
      );

      await tester.tap(
        find.byKey(const ValueKey<String>('mobile-book-section-preface-raw')),
      );
      await tester.pumpAndSettle();
      expect(port.lastBookRevisionId, 'book-preface-raw-1');
      expect(
        find.byKey(const ValueKey<String>('mobile-book-work-part-preview')),
        findsOneWidget,
      );
      Navigator.of(
        tester.element(
          find.byKey(const ValueKey<String>('mobile-book-work-part-preview')),
        ),
      ).pop();
      await tester.pumpAndSettle();

      await tester.tap(find.text('创作历史').last);
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('mobile-work-work-test')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('mobile-work-work-test-outline')),
      );
      await tester.pumpAndSettle();
      expect(port.lastWorkRevisionId, 'work-outline-1');
      Navigator.of(
        tester.element(
          find.byKey(const ValueKey<String>('mobile-book-work-part-preview')),
        ),
      ).pop();
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const ValueKey<String>('mobile-work-complete')),
      );
      await tester.pumpAndSettle();
      final retryKey = port.idempotencyKeys.single;
      await tester.tap(
        find.byKey(const ValueKey<String>('mobile-work-complete')),
      );
      await tester.pumpAndSettle();
      expect(port.idempotencyKeys.take(2), <String>[retryKey, retryKey]);
      expect(port.etags.take(2), <String>['"work-1"', '"work-1"']);

      await tester.tap(
        find.byKey(const ValueKey<String>('mobile-work-promote')),
      );
      await tester.pumpAndSettle();
      expect(port.lastPromotion?.sourcePartRevisionId, 'work-raw-1');
      expect(port.lastPromotion?.target, 'book_section');
      expect(find.textContaining('导入'), findsNothing);
      expect(port.operations.join(), isNot(contains('work-ai')));
      expect(port.operations.join(), isNot(contains('feed-ai')));
      expect(port.operations.join(), isNot(contains('content-navigation')));
    },
  );

  testWidgets('Book failure retries and an empty Work list is explicit', (
    tester,
  ) async {
    final port = _SheetBookWorkPort()
      ..bookFailureCount = 1
      ..worksValue = <SharedWork>[];
    await _pump(tester, port);
    await _openBookWork(tester);

    expect(
      find.byKey(const ValueKey<String>('mobile-book-work-error')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('mobile-book-work-retry')),
    );
    await tester.pumpAndSettle();
    expect(find.text('写在前面'), findsOneWidget);

    await tester.tap(find.text('创作历史').last);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('mobile-work-empty')),
      findsOneWidget,
    );
  });
}

Future<void> _openBookWork(WidgetTester tester) async {
  expect(
    find.byKey(const ValueKey<String>('masterpiece-book-work')),
    findsNothing,
  );
  await tester.tap(find.byKey(const ValueKey<String>('masterpiece-more')));
  await tester.pumpAndSettle();
  final entry = find.byKey(const ValueKey<String>('masterpiece-book-work'));
  expect(entry, findsOneWidget);
  await tester.tap(entry);
  await tester.pumpAndSettle();
}

Future<void> _pump(WidgetTester tester, _SheetBookWorkPort port) async {
  tester.view
    ..physicalSize = const Size(430, 932)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        knowledgeLibraryControllerProvider.overrideWith(
          (ref) => KnowledgeLibraryController(
            initialNotes: List<V3FeedItem>.generate(
              100,
              (index) => V3FeedItem(
                id: 'book-work-unlock-$index',
                title: '典藏资产 ${index + 1}',
                source: V3MaterialSource.note,
                createdAt: DateTime(2026, 8, 17),
                rawBody: '用于达到代表作正式解锁门槛。',
              ),
            ),
          ),
        ),
        mobileBookWorkPortProvider.overrideWithValue(port),
        mobileBookWorkIdentityProvider.overrideWithValue(
          const MobileBookWorkIdentity(
            userId: 'user-1',
            workspaceId: 'workspace-1',
          ),
        ),
      ],
      child: const MaterialApp(home: Scaffold(body: V3MasterpiecePage())),
    ),
  );
  await tester.pump();
}

final class _SheetBookWorkPort implements MobileBookWorkPort {
  _SheetBookWorkPort() {
    bookValue = _book();
    worksValue = <SharedWork>[_work()];
  }

  late SharedBook bookValue;
  late List<SharedWork> worksValue;
  int bookFailureCount = 0;
  int completeFailureCount = 0;
  String? lastBookRevisionId;
  String? lastWorkRevisionId;
  SharedPromoteWorkRequest? lastPromotion;
  final List<String> operations = <String>[];
  final List<String> idempotencyKeys = <String>[];
  final List<String> etags = <String>[];

  @override
  Future<MobileBookWorkResult<SharedBook>> book(String workspaceId) async {
    operations.add('book:$workspaceId');
    if (bookFailureCount > 0) {
      bookFailureCount -= 1;
      return const MobileBookWorkResult<SharedBook>.failure(
        'TEST_BOOK_FAILED',
        retryable: true,
      );
    }
    return MobileBookWorkResult<SharedBook>.success(bookValue);
  }

  @override
  Future<MobileBookWorkResult<SharedWorkPage>> works(
    String workspaceId, {
    String? cursor,
    int limit = 50,
  }) async {
    operations.add('works:$workspaceId');
    return MobileBookWorkResult<SharedWorkPage>.success(
      SharedWorkPage(items: worksValue),
    );
  }

  @override
  Future<MobileBookWorkResult<SharedWork>> work(
    String workspaceId,
    String workId,
  ) async {
    operations.add('work:$workspaceId:$workId');
    return MobileBookWorkResult<SharedWork>.success(worksValue.first);
  }

  @override
  Future<MobileBookWorkResult<SharedManagedPartRevision>> bookSectionPart(
    String workspaceId,
    String sectionKey,
    String part, {
    required String partRevisionId,
  }) async {
    operations.add('book-part:$workspaceId:$sectionKey:$part');
    lastBookRevisionId = partRevisionId;
    return MobileBookWorkResult<SharedManagedPartRevision>.success(
      _part(part, partRevisionId),
    );
  }

  @override
  Future<MobileBookWorkResult<SharedManagedPartRevision>> workPart(
    String workspaceId,
    String workId,
    String part, {
    required String partRevisionId,
  }) async {
    operations.add('work-part:$workspaceId:$workId:$part');
    lastWorkRevisionId = partRevisionId;
    return MobileBookWorkResult<SharedManagedPartRevision>.success(
      _part(part, partRevisionId),
    );
  }

  @override
  Future<MobileBookWorkResult<SharedWorkspaceContentEvent>> completeWork(
    String workspaceId,
    String workId, {
    required String etag,
    required String idempotencyKey,
  }) async {
    operations.add('complete:$workspaceId:$workId');
    etags.add(etag);
    idempotencyKeys.add(idempotencyKey);
    if (completeFailureCount > 0) {
      completeFailureCount -= 1;
      return const MobileBookWorkResult<SharedWorkspaceContentEvent>.failure(
        'HTTP_412',
      );
    }
    return MobileBookWorkResult<SharedWorkspaceContentEvent>.success(
      _receipt(workspaceId, workId),
    );
  }

  @override
  Future<MobileBookWorkResult<SharedWorkspaceContentEvent>> promoteWork(
    String workspaceId,
    String workId,
    SharedPromoteWorkRequest request, {
    required String etag,
    required String idempotencyKey,
  }) async {
    operations.add('promote:$workspaceId:$workId');
    etags.add(etag);
    idempotencyKeys.add(idempotencyKey);
    lastPromotion = request;
    return MobileBookWorkResult<SharedWorkspaceContentEvent>.success(
      _receipt(workspaceId, workId),
    );
  }
}

SharedBook _book() {
  final sections = <SharedBookSection>[
    _section('preface', '写在前面', 'front_matter', 'book-preface-raw-1'),
    _section('chapter_1', '第一章', 'chapters', 'book-chapter-raw-1'),
  ];
  return SharedBook(
    bookId: 'book-1',
    currentBookRevisionId: 'book-revision-1',
    current: SharedBookRevision(
      bookRevisionId: 'book-revision-1',
      revision: 1,
      title: '我的典藏长文',
      language: 'zh-CN',
      status: 'draft',
      sectionOrderVersion: 1,
      sections: <SharedBookSectionSnapshot>[
        for (final section in sections)
          SharedBookSectionSnapshot(
            sectionKey: section.sectionKey,
            title: section.title,
            group: section.group,
            ordinal: section.ordinal,
            metadataVersion: section.metadataVersion,
            currentPartRevisionIds: section.currentPartRevisionIds,
          ),
      ],
      createdAt: DateTime.utc(2026, 8, 7),
    ),
    sections: sections,
    etag: '"book-1"',
  );
}

SharedBookSection _section(
  String key,
  String title,
  String group,
  String revisionId,
) => SharedBookSection(
  sectionKey: key,
  title: title,
  group: group,
  ordinal: 0,
  metadataVersion: 1,
  currentPartRevisionIds: <String, String>{'raw': revisionId},
  parts: <SharedManagedPartHead>[
    SharedManagedPartHead(
      part: 'raw',
      status: 'ready',
      currentRevisionId: revisionId,
      revision: 1,
    ),
  ],
  sourceRefs: const <SharedManagedLineageRef>[],
  resourceRefs: const <SharedManagedResourceRef>[],
  etag: '"$key-1"',
);

SharedWork _work() => const SharedWork(
  workId: 'work-test',
  title: '一次完整创作',
  lifecycle: 'active',
  metadataVersion: 1,
  lineageRefs: <SharedWorkLineageRef>[],
  resourceRefs: <SharedManagedResourceRef>[],
  parts: <SharedManagedPartHead>[
    SharedManagedPartHead(
      part: 'raw',
      status: 'ready',
      currentRevisionId: 'work-raw-1',
      revision: 1,
    ),
    SharedManagedPartHead(
      part: 'outline',
      status: 'ready',
      currentRevisionId: 'work-outline-1',
      revision: 1,
    ),
  ],
  etag: '"work-1"',
);

SharedManagedPartRevision _part(String part, String revisionId) =>
    SharedManagedPartRevision(
      part: part,
      partRevisionId: revisionId,
      revision: 1,
      contentMarkdown: '# 精确内容\n\n来自 $revisionId。',
      contentHash: 'hash-$revisionId',
      sizeBytes: 24,
      sourceRefs: const <SharedNotePartSourceRef>[],
      createdAt: DateTime.utc(2026, 8, 7),
      etag: '"$revisionId"',
    );

SharedWorkspaceContentEvent _receipt(String workspaceId, String workId) =>
    SharedWorkspaceContentEvent(
      eventId: 'event-$workId',
      workspaceId: workspaceId,
      cursor: '2',
      operationId: 'operation-$workId',
      occurredAt: DateTime.utc(2026, 8, 7),
      objectKind: 'work',
      objectId: workId,
      changeType: 'updated',
      tombstone: false,
      resourcePinDelta: const SharedWorkspaceResourcePinDelta(
        added: <String>[],
        released: <String>[],
      ),
      version: 2,
    );
