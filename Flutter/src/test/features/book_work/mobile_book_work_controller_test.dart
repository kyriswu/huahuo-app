import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:huahuo_api/huahuo_api.dart';
import 'package:huahuoai_app/features/book_work/application/mobile_book_work_controller.dart';
import 'package:huahuoai_app/features/book_work/data/mobile_book_work_port.dart';

void main() {
  test(
    'default promotion key survives navigation and controller recreation',
    () async {
      final port = _FakeMobileBookWorkPort()..promoteFailureCount = 1;
      const identity = MobileBookWorkIdentity(
        userId: 'user-1',
        workspaceId: 'workspace-1',
      );
      final first = MobileBookWorkController(port)..bindIdentity(identity);
      await first.load();
      final work = first.works.first;
      expect((await first.promoteToBook(work)).isSuccess, isFalse);
      first.discardWorkMutations(work.workId);
      first.dispose();
      final resumed = MobileBookWorkController(port)..bindIdentity(identity);
      addTearDown(resumed.dispose);
      await resumed.load();
      expect(
        (await resumed.promoteToBook(resumed.works.first)).isSuccess,
        isTrue,
      );
      expect(port.idempotencyKeys, hasLength(2));
      expect(port.idempotencyKeys[0], port.idempotencyKeys[1]);
    },
  );

  test(
    'remote promotion uses bounded API24 request and canonical headers',
    () async {
      final transport = _QueueTransport(
        const ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'data': <String, Object?>{
              'eventId': 'event-promote',
              'workspaceId': 'workspace-1',
              'cursor': '3',
              'operationId': 'operation-promote',
              'occurredAt': '2026-08-07T08:00:00Z',
              'objectKind': 'book_section',
              'objectId': 'w_work_test_12345678',
              'changeType': 'created',
              'version': 1,
              'tombstone': false,
              'resourcePinDelta': <String, Object?>{
                'added': <Object?>[],
                'released': <Object?>[],
              },
            },
          },
        ),
      );
      final port = RemoteMobileBookWorkPort(
        ApiClient(
          config: ApiClientConfig(
            baseUrl: Uri.parse('https://api.example.test'),
            clientVersion: '0.1.0',
            deviceId: 'mobile-test',
            platform: 'ios',
            locale: 'zh-CN',
            getAccessToken: () => 'access-token',
          ),
          transport: transport,
        ),
      );
      final result = await port.promoteWork(
        'workspace-1',
        'work-test',
        SharedPromoteWorkRequest.bookSection(
          sourcePart: 'raw',
          sourcePartRevisionId: 'work-raw-1',
          sectionKey: 'w_work_test_12345678',
          title: '正式创作',
          group: 'chapters',
        ),
        etag: '"work-1"',
        idempotencyKey: 'promotion-key',
      );

      expect(result.isSuccess, isTrue);
      final request = transport.request!;
      expect(
        request.url.path,
        '/api/v1/workspaces/workspace-1/work/work-test/promotions',
      );
      expect(request.headers['If-Match'], '"work-1"');
      expect(request.headers['X-Idempotency-Key'], 'promotion-key');
      expect(request.headers, isNot(contains('Idempotency-Key')));
      final body = jsonDecode(request.body!) as Map<String, Object?>;
      expect(body['target'], 'book_section');
      expect(body['sourcePartRevisionId'], 'work-raw-1');
      expect(body, isNot(contains('path')));
      expect(body, isNot(contains('objectKey')));
      expect(body, isNot(contains('contentMarkdown')));
      expect(body.toString(), isNot(contains('/Users/')));
    },
  );

  test('load requires account and aggregates the bound Workspace', () async {
    final port = _FakeMobileBookWorkPort();
    final controller = MobileBookWorkController(port);

    await controller.load();
    expect(controller.status, MobileBookWorkStatus.unavailable);
    expect(controller.errorCode, 'BOOK_WORK_ACCOUNT_REQUIRED');
    expect(port.operations, isEmpty);

    controller.bindIdentity(
      const MobileBookWorkIdentity(
        userId: 'user-1',
        workspaceId: 'workspace-1',
      ),
    );
    await controller.load();

    expect(controller.status, MobileBookWorkStatus.ready);
    expect(controller.book?.sections.map((item) => item.sectionKey), <String>[
      'preface',
      'chapter_1',
    ]);
    expect(controller.works, hasLength(1));
    expect(port.operations, contains('book:workspace-1'));
  });

  test('paging rejects repeated cursors and conflicting Work IDs', () async {
    final repeatedPort = _FakeMobileBookWorkPort()..repeatCursor = true;
    final repeated = _boundController(repeatedPort);
    await repeated.load();
    expect(repeated.errorCode, 'BOOK_WORK_CURSOR_REPEATED');
    expect(
      repeatedPort.operations.where((item) => item.startsWith('works:')),
      hasLength(2),
    );

    final conflictPort = _FakeMobileBookWorkPort()..conflictingDuplicate = true;
    final conflict = _boundController(conflictPort);
    await conflict.load();
    expect(conflict.errorCode, 'BOOK_WORK_DUPLICATE_ID_CONFLICT');
  });

  test('Book and Work Part reads pin the exact current revision', () async {
    final port = _FakeMobileBookWorkPort();
    final controller = _boundController(port);
    await controller.load();
    final section = controller.book!.sections.first;
    final work = controller.works.first;

    final bookPart = await controller.openBookPart(
      section: section,
      part: 'raw',
    );
    final workPart = await controller.openWorkPart(work: work, part: 'outline');

    expect(bookPart.data?.partRevisionId, 'book-preface-raw-1');
    expect(port.lastBookPartRevisionId, 'book-preface-raw-1');
    expect(workPart.data?.partRevisionId, 'work-outline-1');
    expect(port.lastWorkPartRevisionId, 'work-outline-1');
  });

  test(
    'complete and promotion retain keys, ETags and exact source Part',
    () async {
      final keys = <String>['complete-key', 'complete-next', 'promote-key'];
      final port = _FakeMobileBookWorkPort()
        ..completeFailureCount = 1
        ..promoteFailureCount = 1;
      final controller =
          MobileBookWorkController(
            port,
            idempotencyKeyFactory: () => keys.removeAt(0),
          )..bindIdentity(
            const MobileBookWorkIdentity(
              userId: 'user-1',
              workspaceId: 'workspace-1',
            ),
          );
      await controller.load();
      final work = controller.works.first;

      expect((await controller.completeWork(work)).isSuccess, isFalse);
      expect((await controller.completeWork(work)).isSuccess, isTrue);
      expect(port.idempotencyKeys.take(2), <String>[
        'complete-key',
        'complete-key',
      ]);
      expect(port.etags.take(2), <String>[work.etag, work.etag]);

      expect((await controller.promoteToBook(work)).isSuccess, isFalse);
      expect((await controller.promoteToBook(work)).isSuccess, isTrue);
      expect(port.idempotencyKeys.skip(2), <String>[
        'complete-next',
        'complete-next',
      ]);
      expect(port.lastPromotion?.target, 'book_section');
      expect(port.lastPromotion?.sourcePartRevisionId, 'work-raw-1');
      expect(
        RegExp(
          r'^[a-z][a-z0-9_-]{0,31}$',
        ).hasMatch(port.lastPromotion!.bookSectionKey!),
        isTrue,
      );
      expect(port.operations.join(), isNot(contains('work-ai')));
      expect(port.operations.join(), isNot(contains('feed-ai')));
      expect(port.operations.join(), isNot(contains('content-navigation')));
    },
  );

  test(
    'account generation rejects delayed reads and stale mutations',
    () async {
      final readGate = Completer<void>();
      final mutationGate = Completer<void>();
      final port = _FakeMobileBookWorkPort()
        ..bookGate = readGate
        ..completeGate = mutationGate;
      final controller = _boundController(port);

      final delayedRead = controller.load();
      await Future<void>.delayed(Duration.zero);
      controller.bindIdentity(
        const MobileBookWorkIdentity(
          userId: 'user-2',
          workspaceId: 'workspace-2',
        ),
      );
      readGate.complete();
      await delayedRead;
      expect(controller.status, MobileBookWorkStatus.idle);
      expect(controller.book, isNull);

      port.bookGate = null;
      await controller.load();
      final staleMutation = controller.completeWork(controller.works.first);
      await Future<void>.delayed(Duration.zero);
      controller.bindIdentity(
        const MobileBookWorkIdentity(
          userId: 'user-3',
          workspaceId: 'workspace-3',
        ),
      );
      mutationGate.complete();
      final result = await staleMutation;
      expect(result.errorCode, 'BOOK_WORK_ACCOUNT_CHANGED');
      expect(controller.status, MobileBookWorkStatus.idle);
    },
  );

  test('Port exceptions never leave loading or mutation state stuck', () async {
    final port = _FakeMobileBookWorkPort()..throwBook = true;
    final controller = _boundController(port);

    await controller.load();
    expect(controller.status, MobileBookWorkStatus.failure);
    expect(controller.errorCode, 'BOOK_WORK_PORT_EXCEPTION');
    expect(controller.loading, isFalse);

    port.throwBook = false;
    await controller.load();
    final work = controller.works.first;
    port.throwComplete = true;
    final result = await controller.completeWork(work);
    expect(result.errorCode, 'BOOK_WORK_PORT_EXCEPTION');
    expect(controller.isMutating(work.workId), isFalse);
  });

  test('late Work A detail cannot overwrite newer Work B selection', () async {
    final first = _work(workId: 'work-a', title: '创作 A');
    final second = _work(workId: 'work-b', title: '创作 B');
    final firstGate = Completer<SharedWork>();
    final secondGate = Completer<SharedWork>();
    final port = _FakeMobileBookWorkPort()
      ..worksValue = <SharedWork>[first, second]
      ..workGates = <String, Completer<SharedWork>>{
        first.workId: firstGate,
        second.workId: secondGate,
      };
    final controller = _boundController(port);
    await controller.load();

    final loadA = controller.selectWork(first.workId);
    await Future<void>.delayed(Duration.zero);
    final loadB = controller.selectWork(second.workId);
    secondGate.complete(second);
    expect((await loadB).isSuccess, isTrue);
    expect(controller.selectedWork?.workId, second.workId);
    firstGate.complete(first);
    expect((await loadA).errorCode, 'BOOK_WORK_SELECTION_SUPERSEDED');
    expect(controller.selectedWork?.workId, second.workId);
  });

  test('long common-prefix Work IDs produce distinct Section keys', () async {
    final first = _work(
      workId: 'work-with-the-same-very-long-prefix-alpha',
      title: 'Alpha',
    );
    final second = _work(
      workId: 'work-with-the-same-very-long-prefix-beta',
      title: 'Beta',
    );
    final port = _FakeMobileBookWorkPort()
      ..worksValue = <SharedWork>[first, second];
    final controller = _boundController(port);
    await controller.load();

    await controller.promoteToBook(first);
    await controller.promoteToBook(second);
    final keys = port.promotions
        .map((request) => request.bookSectionKey!)
        .toList(growable: false);
    expect(keys.first, isNot(keys.last));
    for (final key in keys) {
      expect(key.length, lessThanOrEqualTo(32));
      expect(RegExp(r'^[a-z][a-z0-9_-]{0,31}$').hasMatch(key), isTrue);
    }
  });
}

MobileBookWorkController _boundController(_FakeMobileBookWorkPort port) {
  return MobileBookWorkController(port)..bindIdentity(
    const MobileBookWorkIdentity(userId: 'user-1', workspaceId: 'workspace-1'),
  );
}

final class _FakeMobileBookWorkPort implements MobileBookWorkPort {
  _FakeMobileBookWorkPort() {
    bookValue = _book();
    worksValue = <SharedWork>[_work()];
  }

  late SharedBook bookValue;
  late List<SharedWork> worksValue;
  bool repeatCursor = false;
  bool conflictingDuplicate = false;
  int completeFailureCount = 0;
  int promoteFailureCount = 0;
  bool throwBook = false;
  bool throwComplete = false;
  Completer<void>? bookGate;
  Completer<void>? completeGate;
  Map<String, Completer<SharedWork>> workGates =
      <String, Completer<SharedWork>>{};
  String? lastBookPartRevisionId;
  String? lastWorkPartRevisionId;
  SharedPromoteWorkRequest? lastPromotion;
  final List<SharedPromoteWorkRequest> promotions =
      <SharedPromoteWorkRequest>[];
  final List<String> operations = <String>[];
  final List<String> idempotencyKeys = <String>[];
  final List<String> etags = <String>[];

  @override
  Future<MobileBookWorkResult<SharedBook>> book(String workspaceId) async {
    operations.add('book:$workspaceId');
    if (throwBook) throw StateError('book transport failed');
    await bookGate?.future;
    return MobileBookWorkResult<SharedBook>.success(bookValue);
  }

  @override
  Future<MobileBookWorkResult<SharedWorkPage>> works(
    String workspaceId, {
    String? cursor,
    int limit = 50,
  }) async {
    operations.add('works:$workspaceId:${cursor ?? 'first'}:$limit');
    if (repeatCursor) {
      return MobileBookWorkResult<SharedWorkPage>.success(
        SharedWorkPage(
          items: cursor == null ? worksValue : const <SharedWork>[],
          nextCursor: 'same-cursor',
        ),
      );
    }
    if (conflictingDuplicate) {
      return MobileBookWorkResult<SharedWorkPage>.success(
        SharedWorkPage(
          items: cursor == null
              ? worksValue
              : <SharedWork>[_work(etag: '"conflict"')],
          nextCursor: cursor == null ? 'next' : null,
        ),
      );
    }
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
    final gate = workGates[workId];
    if (gate != null) {
      return MobileBookWorkResult<SharedWork>.success(await gate.future);
    }
    return MobileBookWorkResult<SharedWork>.success(
      worksValue.firstWhere((item) => item.workId == workId),
    );
  }

  @override
  Future<MobileBookWorkResult<SharedManagedPartRevision>> bookSectionPart(
    String workspaceId,
    String sectionKey,
    String part, {
    required String partRevisionId,
  }) async {
    operations.add('book-part:$workspaceId:$sectionKey:$part');
    lastBookPartRevisionId = partRevisionId;
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
    lastWorkPartRevisionId = partRevisionId;
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
    if (throwComplete) throw StateError('complete transport failed');
    await completeGate?.future;
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
    promotions.add(request);
    if (promoteFailureCount > 0) {
      promoteFailureCount -= 1;
      return const MobileBookWorkResult<SharedWorkspaceContentEvent>.failure(
        'PROMOTE_RETRY',
        retryable: true,
      );
    }
    return MobileBookWorkResult<SharedWorkspaceContentEvent>.success(
      _receipt(workspaceId, workId),
    );
  }
}

SharedBook _book() {
  final sections = <SharedBookSection>[
    _section(
      key: 'preface',
      title: '写在前面',
      group: 'front_matter',
      revisionId: 'book-preface-raw-1',
    ),
    _section(
      key: 'chapter_1',
      title: '第一章',
      group: 'chapters',
      revisionId: 'book-chapter-raw-1',
    ),
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

SharedBookSection _section({
  required String key,
  required String title,
  required String group,
  required String revisionId,
}) => SharedBookSection(
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

SharedWork _work({
  String workId = 'work-test',
  String title = '一次完整创作',
  String etag = '"work-1"',
}) => SharedWork(
  workId: workId,
  title: title,
  lifecycle: 'active',
  metadataVersion: 1,
  lineageRefs: <SharedWorkLineageRef>[],
  resourceRefs: <SharedManagedResourceRef>[],
  parts: <SharedManagedPartHead>[
    const SharedManagedPartHead(
      part: 'raw',
      status: 'ready',
      currentRevisionId: 'work-raw-1',
      revision: 1,
    ),
    const SharedManagedPartHead(
      part: 'outline',
      status: 'ready',
      currentRevisionId: 'work-outline-1',
      revision: 1,
    ),
  ],
  etag: etag,
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

final class _QueueTransport implements ApiTransport {
  _QueueTransport(this.response);

  final ApiTransportResponse response;
  ApiTransportRequest? request;

  @override
  Future<ApiTransportResponse> send(ApiTransportRequest request) async {
    this.request = request;
    return response;
  }
}
