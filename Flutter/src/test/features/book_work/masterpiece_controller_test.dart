import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:huahuo_api/huahuo_api.dart';
import 'package:huahuoai_app/features/book_work/application/masterpiece_controller.dart';
import 'package:huahuoai_app/features/book_work/data/masterpiece_repository.dart';
import 'package:huahuoai_app/features/book_work/data/mobile_book_work_port.dart';

import 'masterpiece_test_support.dart';

void main() {
  test('automatic refresh suppresses only fresh reader reads', () async {
    var now = DateTime.utc(2026, 9, 7, 10);
    final remote = TestMasterpieceRemote();
    final controller = MasterpieceController(
      remote: remote,
      store: TestMasterpieceStore(),
      now: () => now,
    );
    addTearDown(controller.dispose);

    await controller.refresh(force: false);
    now = now.add(const Duration(seconds: 29));
    await controller.refresh(force: false);
    expect(remote.reads, 1);

    await controller.refresh();
    expect(remote.reads, 2);
    now = now.add(const Duration(seconds: 30));
    await controller.refresh(force: false);
    expect(remote.reads, 3);
    now = now.subtract(const Duration(seconds: 1));
    await controller.refresh(force: false);
    expect(remote.reads, 4);

    remote.readFailure = StateError('offline');
    await controller.refresh();
    remote.readFailure = null;
    await controller.refresh(force: false);
    expect(remote.reads, 6);

    expect(controller.beginEdit(controller.snapshot!.chapters.single), isTrue);
    await controller.refresh(force: false);
    expect(remote.reads, 7);
  });

  test(
    'reader reuses exact chapter parts and evicts superseded revisions',
    () async {
      final original = masterpieceSnapshot();
      final updated = masterpieceSnapshot(markdown: '更新的正文', revision: 2);
      final transport = _Transport(
        responses: [
          _bookWire(original),
          _partWire(),
          _bookWire(original),
          _bookWire(updated),
          _partWire(revision: 2, markdown: '更新的正文'),
          _bookWire(original),
          _partWire(),
        ],
      );
      final repository = RemoteMasterpieceRepository(
        _api(transport),
        'workspace-1',
      );

      final first = await repository.read();
      final unchanged = await repository.read();
      expect(transport.requests, hasLength(3));
      expect(
        identical(
          first.chapters.single.revision,
          unchanged.chapters.single.revision,
        ),
        isTrue,
      );

      final changed = await repository.read();
      expect(changed.chapters.single.revision!.contentMarkdown, '更新的正文');
      expect(transport.requests, hasLength(5));
      final restored = await repository.read();
      expect(restored.chapters.single.revision!.partRevisionId, 'revision-1');
      expect(transport.requests, hasLength(7));
    },
  );

  test(
    'impossible legacy chapter keys recover as editable valid drafts',
    () async {
      final store = TestMasterpieceStore()
        ..value = MasterpieceDraft(
          bookId: 'book-1',
          sectionKey: 'chapter-${'a' * 32}',
          title: '旧草稿',
          markdown: '不能丢失',
          stage: MasterpieceIntentStage.uncertain,
          idempotencyKey: 'old-key',
        );
      final remote = TestMasterpieceRemote();
      final controller = MasterpieceController(remote: remote, store: store);
      addTearDown(controller.dispose);
      expect(controller.phase, MasterpiecePhase.editing);
      expect(controller.draft!.sectionKey.length, lessThanOrEqualTo(32));
      expect(controller.draft!.idempotencyKey, isNull);
      expect(controller.draft!.markdown, '不能丢失');
      expect(controller.canSave, isFalse);
      await controller.refresh();
      expect(controller.canSave, isTrue);
      expect(remote.writes, isEmpty);
    },
  );

  test(
    'recovered drafts require a readable matching baseline before saving',
    () async {
      final store = TestMasterpieceStore()
        ..value = const MasterpieceDraft(
          bookId: 'book-1',
          sectionKey: 'chapter-1',
          title: '第一章',
          markdown: '恢复的修改',
          baseMarkdown: '云端正文',
          baseRevisionId: 'revision-1',
          etag: '"part-etag-1"',
        );
      final remote = TestMasterpieceRemote()
        ..readFailure = StateError('offline');
      final controller = MasterpieceController(remote: remote, store: store);
      addTearDown(controller.dispose);
      await controller.save();
      await controller.refresh();
      controller.edit(markdown: '离线继续编辑');
      expect(controller.canSave, isFalse);
      expect(controller.canRefresh, isTrue);
      expect(remote.writes, isEmpty);
      remote.readFailure = null;
      await controller.refresh();
      expect(controller.canSave, isTrue);
      remote.snapshot = masterpieceSnapshot(markdown: '另一设备的修改', revision: 2);
      await controller.refresh();
      expect(controller.phase, MasterpiecePhase.conflict);
      expect(controller.draft!.markdown, '离线继续编辑');
      expect(controller.canSave, isFalse);
    },
  );

  test(
    'lifecycle flush cannot resurrect discarded or pre-rebase drafts',
    () async {
      final store = TestMasterpieceStore();
      final remote = TestMasterpieceRemote();
      final controller = MasterpieceController(remote: remote, store: store);
      addTearDown(controller.dispose);
      await controller.refresh();
      controller.beginEdit(controller.snapshot!.chapters.single);
      controller.edit(markdown: '本机修改');
      await controller.flushDraft();
      store.clearGate = Completer<void>();
      final discard = controller.discard();
      final flush = controller.flushDraft();
      store.clearGate!.complete();
      await Future.wait([discard, flush]);
      expect(store.value, isNull);
      controller.beginEdit(controller.snapshot!.chapters.single);
      controller.edit(markdown: '保留的新修改');
      remote.snapshot = masterpieceSnapshot(revision: 2);
      await controller.refresh();
      store.writeGate = Completer<void>();
      final rebase = controller.rebaseAfterConfirmation(
        reviewedRevisionId: 'revision-2',
      );
      final secondFlush = controller.flushDraft();
      store.writeGate!.complete();
      await Future.wait([rebase, secondFlush]);
      expect(store.value!.stage, MasterpieceIntentStage.editing);
      expect(store.value!.baseRevisionId, 'revision-2');
      expect(store.value!.markdown, '保留的新修改');
    },
  );

  test(
    'late disposed write does not overwrite a replacement runtime store',
    () async {
      final store = TestMasterpieceStore();
      final remote = TestMasterpieceRemote()..writeGate = Completer<void>();
      final controller = MasterpieceController(remote: remote, store: store);
      await controller.refresh();
      controller.beginNew(title: '新的章节', markdown: '提交内容');
      final saving = controller.save();
      await Future<void>.delayed(Duration.zero);
      expect(remote.writes, hasLength(1));
      controller.dispose();
      final writesAtDisposal = store.saved.length;
      remote.writeGate!.complete();
      await saving;
      expect(store.saved.length, writesAtDisposal);
      expect(store.value!.stage, MasterpieceIntentStage.submitting);
    },
  );

  test(
    'accepted readback follows submitted part rather than displayed raw',
    () async {
      final store = TestMasterpieceStore()
        ..value = const MasterpieceDraft(
          bookId: 'book-1',
          sectionKey: 'chapter-1',
          title: '第一章',
          markdown: '大纲修改',
          part: 'outline',
          baseMarkdown: '原大纲',
          baseRevisionId: 'outline-1',
          etag: '"outline-etag"',
          stage: MasterpieceIntentStage.accepted,
          idempotencyKey: 'stable-key',
          acceptedRevisionId: 'outline-2',
        );
      final remote = TestMasterpieceRemote();
      final controller = MasterpieceController(remote: remote, store: store);
      addTearDown(controller.dispose);
      await controller.refresh();
      expect(controller.phase, MasterpiecePhase.awaitingReadback);
      expect(store.value, isNotNull);
      remote.snapshot = masterpieceSnapshot(
        additionalHeads: {'outline': 'outline-2'},
      );
      await controller.refresh();
      expect(controller.phase, MasterpiecePhase.reading);
      expect(store.value, isNull);
      expect(remote.writes, isEmpty);
    },
  );

  test(
    'Book and Work reads resolve exact history without unsupported queries',
    () async {
      final older = _partWire();
      final newer = _partWire(revision: 2);
      final transport = _Transport(
        responses: [
          newer,
          {
            'items': [newer, older],
          },
          newer,
          {
            'items': [newer],
          },
          {'items': <Object>[]},
        ],
      );
      final api = _api(transport);
      final client = BookWorkClient(api);
      final selected = await client.bookSectionPart(
        'workspace-1',
        'chapter-1',
        'raw',
        partRevisionId: 'revision-1',
      );
      expect(selected.data!.partRevisionId, 'revision-1');
      final missing = await client.workPart(
        'workspace-1',
        'work-1',
        'raw',
        partRevisionId: 'revision-1',
      );
      expect(missing.error?.code, 'API_RESPONSE_INVALID');
      final port = RemoteMobileBookWorkPort(api);
      expect((await port.works('workspace-1', limit: 50)).isSuccess, isTrue);
      expect(
        (await port.works('workspace-1', cursor: 'unsupported')).isSuccess,
        isFalse,
      );
      expect(transport.requests, hasLength(5));
      expect(
        transport.requests.every((request) => request.url.query.isEmpty),
        isTrue,
      );
      expect(transport.requests[1].url.path, endsWith('/parts/raw/revisions'));
    },
  );

  test(
    'empty raw cannot hide promoted outline and copies retain provenance',
    () async {
      final lineage = SharedManagedWorkPartLineageRef(
        workId: 'work-1',
        part: 'outline',
        partRevisionId: 'work-outline-1',
      );
      final seed = masterpieceSnapshot(
        part: 'outline',
        additionalHeads: {'raw': 'revision-1'},
        managedSourceRefs: [lineage],
      );
      final transport = _Transport(
        responses: [
          _bookWire(seed),
          _partWire(markdown: ''),
          _partWire(part: 'outline', markdown: '纳入的作品内容', managed: [lineage]),
        ],
      );
      final remote = RemoteMasterpieceRepository(
        _api(transport),
        'workspace-1',
      );
      final store = TestMasterpieceStore();
      final controller = MasterpieceController(remote: remote, store: store);
      addTearDown(controller.dispose);
      await controller.refresh();
      final chapter = controller.snapshot!.chapters.single;
      expect(chapter.revision!.part, 'outline');
      expect(chapter.revision!.contentMarkdown, '纳入的作品内容');
      expect(chapter.requiresCopy, isTrue);
      expect(controller.beginEdit(chapter), isFalse);
      expect(controller.beginCopy(chapter), isTrue);
      await controller.flushDraft();
      expect(store.value!.managedSourceRefs.single.toJson(), lineage.toJson());
      final writing = _Transport();
      await RemoteMasterpieceRepository(_api(writing), 'workspace-1').write(
        store.value!.copyWith(
          idempotencyKey: 'copy-key',
          stage: MasterpieceIntentStage.submitting,
        ),
      );
      final request = writing.requests.single;
      expect(request.method, 'POST');
      final body = jsonDecode(request.body!) as Map;
      expect(body['sourceRefs'], contains(equals(lineage.toJson())));
      expect(body['resourceRefs'], [
        chapter.section.resourceRefs.single.toJson(),
      ]);
      expect(body['parts'], {'outline': '纳入的作品内容'});
    },
  );

  test(
    'empty cloud Book creates one durable chapter and reads it back',
    () async {
      final remote = TestMasterpieceRemote(
        snapshot: masterpieceSnapshot(empty: true),
      );
      final store = TestMasterpieceStore();
      final controller = MasterpieceController(remote: remote, store: store);
      addTearDown(controller.dispose);
      await controller.refresh();
      expect(controller.phase, MasterpiecePhase.empty);
      expect(controller.beginNew(title: '起点', markdown: '新的正文'), isTrue);
      await controller.save();
      expect(remote.writes, hasLength(1));
      expect(
        store.saved.whereType<MasterpieceDraft>().first.stage,
        MasterpieceIntentStage.submitting,
      );
      expect(controller.phase, MasterpiecePhase.reading);
      expect(
        controller.snapshot!.chapters.single.revision!.contentMarkdown,
        '新的正文',
      );
      expect(store.value, isNull);
    },
  );

  test(
    'unknown submission freezes payload and survives restart with the same key',
    () async {
      final remote = TestMasterpieceRemote()
        ..writeFailure = const MasterpieceRemoteException(
          'NETWORK_ERROR',
          ambiguous: true,
        );
      final store = TestMasterpieceStore();
      final first = MasterpieceController(remote: remote, store: store);
      await first.refresh();
      first.beginEdit(first.snapshot!.chapters.single);
      first.edit(markdown: '用户修改');
      await first.save();
      expect(first.phase, MasterpiecePhase.uncertain);
      first.edit(markdown: '不能覆盖已提交的意图');
      await first.discard();
      expect(first.draft!.markdown, '用户修改');
      await first.flushDraft();
      first.dispose();
      await Future<void>.delayed(Duration.zero);
      remote.writeFailure = null;
      final resumed = MasterpieceController(remote: remote, store: store);
      addTearDown(resumed.dispose);
      await resumed.save();
      expect(remote.writes, hasLength(2));
      expect(remote.writes[0].idempotencyKey, remote.writes[1].idempotencyKey);
      expect(remote.writes[0].toJson(), remote.writes[1].toJson());
      expect(resumed.phase, MasterpiecePhase.reading);
    },
  );

  test(
    'accepted mutation only retries readback and does not submit twice',
    () async {
      final remote = TestMasterpieceRemote()..failReadAfterWrite = true;
      final store = TestMasterpieceStore();
      final controller = MasterpieceController(remote: remote, store: store);
      addTearDown(controller.dispose);
      await controller.refresh();
      controller.beginEdit(controller.snapshot!.chapters.single);
      controller.edit(markdown: '已提交正文');
      await controller.save();
      expect(controller.phase, MasterpiecePhase.awaitingReadback);
      expect(store.value!.stage, MasterpieceIntentStage.accepted);
      await controller.save();
      remote.readFailure = null;
      await controller.refresh();
      expect(remote.writes, hasLength(1));
      expect(controller.phase, MasterpiecePhase.reading);
    },
  );

  test('stale readback cannot clear the accepted intent', () async {
    final remote = TestMasterpieceRemote();
    final controller = MasterpieceController(
      remote: remote,
      store: TestMasterpieceStore(),
    );
    addTearDown(controller.dispose);
    await controller.refresh();
    remote.staleRead = remote.snapshot;
    controller.beginEdit(controller.snapshot!.chapters.single);
    controller.edit(markdown: '新版本');
    await controller.save();
    expect(controller.phase, MasterpiecePhase.awaitingReadback);
    expect(controller.draft, isNotNull);
    remote.staleRead = null;
    await controller.refresh();
    expect(controller.draft, isNull);
  });

  test(
    'conflict preserves draft and rebases only the reviewed current part',
    () async {
      final remote = TestMasterpieceRemote();
      final controller = MasterpieceController(
        remote: remote,
        store: TestMasterpieceStore(),
      );
      addTearDown(controller.dispose);
      await controller.refresh();
      controller.beginEdit(controller.snapshot!.chapters.single);
      controller.edit(markdown: '我的草稿');
      remote.snapshot = masterpieceSnapshot(markdown: '别处修改', revision: 2);
      remote.writeFailure = const MasterpieceRemoteException(
        'BOOK_SECTION_VERSION_CONFLICT',
        status: 412,
      );
      await controller.save();
      expect(controller.phase, MasterpiecePhase.conflict);
      expect(controller.draft!.markdown, '我的草稿');
      await controller.rebaseAfterConfirmation(
        reviewedRevisionId: 'revision-1',
      );
      expect(controller.phase, MasterpiecePhase.conflict);
      await controller.rebaseAfterConfirmation(
        reviewedRevisionId: 'revision-2',
      );
      expect(controller.phase, MasterpiecePhase.editing);
      expect(controller.draft!.baseRevisionId, 'revision-2');
      expect(controller.draft!.etag, '"part-etag-2"');
      expect(controller.draft!.markdown, '我的草稿');
    },
  );

  test(
    'storage failure prevents submission and retained draft blocks chat',
    () async {
      final remote = TestMasterpieceRemote();
      final store = TestMasterpieceStore()..failWrites = true;
      final controller = MasterpieceController(remote: remote, store: store);
      addTearDown(controller.dispose);
      await controller.refresh();
      controller.beginEdit(controller.snapshot!.chapters.single);
      controller.edit(markdown: '不能丢失');
      await controller.save();
      expect(remote.writes, isEmpty);
      expect(controller.draft!.markdown, '不能丢失');
      expect(controller.errorCode, 'MASTERPIECE_DRAFT_STORAGE_FAILED');
      expect(await controller.prepareChat(), isFalse);
    },
  );

  test(
    'single-flight read ignores completion after identity disposal',
    () async {
      final remote = TestMasterpieceRemote()
        ..readGate = Completer<MasterpieceSnapshot>();
      final controller = MasterpieceController(
        remote: remote,
        store: TestMasterpieceStore(),
      );
      final first = controller.refresh();
      final second = controller.refresh();
      expect(remote.reads, 1);
      controller.dispose();
      remote.readGate!.complete(remote.snapshot);
      await Future.wait([first, second]);
      expect(controller.snapshot, isNull);
      expect(controller.beginNew(), isFalse);
    },
  );

  test(
    'cloud write uses part ETag, references, deployed header and opaque receipt ID',
    () async {
      final transport = _Transport();
      final repository = RemoteMasterpieceRepository(
        ApiClient(
          config: ApiClientConfig(
            baseUrl: Uri.parse('https://api.example.test'),
            clientVersion: '0.1.0',
            deviceId: 'test-device',
            platform: 'ios',
            locale: 'zh-CN',
            getAccessToken: () => 'test-token',
          ),
          transport: transport,
        ),
        'workspace-1',
      );
      final chapter = masterpieceSnapshot().chapters.single;
      final revision = chapter.revision!;
      final draft = MasterpieceDraft(
        bookId: 'book-1',
        sectionKey: 'chapter-1',
        title: chapter.section.title,
        markdown: '新正文',
        baseMarkdown: revision.contentMarkdown,
        baseRevisionId: revision.partRevisionId,
        etag: revision.etag,
        sourceRefs: revision.sourceRefs,
        resourceRefs: chapter.section.resourceRefs,
        stage: MasterpieceIntentStage.submitting,
        idempotencyKey: 'stable-key',
      );
      final receipt = await repository.write(draft);
      expect(receipt.objectId, 'opaque-server-section-id');
      final request = transport.requests.single;
      expect(
        request.url.path,
        '/api/v1/workspaces/workspace-1/book/sections/chapter-1/parts/raw',
      );
      expect(request.headers['If-Match'], '"part-etag-1"');
      expect(request.headers['X-Idempotency-Key'], 'stable-key');
      expect(request.headers.containsKey('Idempotency-Key'), isFalse);
      final body = jsonDecode(request.body!) as Map;
      expect(body['basePartRevisionId'], 'revision-1');
      expect(body['sourceRefs'], [revision.sourceRefs.single.toJson()]);
      expect(body['resourceRefs'], [
        chapter.section.resourceRefs.single.toJson(),
      ]);
      expect(
        masterpieceSnapshot(markdown: '字' * 16000).chatMarkdown.length,
        lessThan(12000),
      );
    },
  );
}

final class _Transport implements ApiTransport {
  _Transport({this.responses = const []});
  final List<Object> responses;
  final requests = <ApiTransportRequest>[];
  @override
  Future<ApiTransportResponse> send(ApiTransportRequest request) async {
    requests.add(request);
    if (request.url.query.isNotEmpty) {
      throw StateError('The deployed API24 read route rejects every query');
    }
    if (responses.isNotEmpty) {
      return ApiTransportResponse(
        status: 200,
        body: {'success': true, 'data': responses[requests.length - 1]},
      );
    }
    return ApiTransportResponse(
      status: 200,
      body: {
        'success': true,
        'data': {
          'eventId': 'event-1',
          'workspaceId': 'workspace-1',
          'cursor': '2',
          'operationId': 'operation-1',
          'occurredAt': '2026-09-05T00:00:00Z',
          'objectKind': 'book_section',
          'objectId': 'opaque-server-section-id',
          'changeType': request.method == 'POST'
              ? 'created'
              : 'revision_created',
          if (request.method == 'POST')
            'version': 1
          else
            'revisionId': 'revision-2',
          'tombstone': false,
          'resourcePinDelta': {'added': [], 'released': []},
        },
      },
    );
  }
}

ApiClient _api(ApiTransport transport) => ApiClient(
  config: ApiClientConfig(
    baseUrl: Uri.parse('https://api.example.test'),
    clientVersion: '0.1.0',
    deviceId: 'test-device',
    platform: 'ios',
    locale: 'zh-CN',
    getAccessToken: () => 'test-token',
  ),
  transport: transport,
);

Map<String, Object?> _partWire({
  String part = 'raw',
  int revision = 1,
  String markdown = '云端正文',
  List<SharedManagedLineageRef> managed = const [],
}) => {
  'part': part,
  'partRevisionId': 'revision-$revision',
  'revision': revision,
  'contentMarkdown': markdown,
  'contentHash': 'hash',
  'sizeBytes': utf8.encode(markdown).length,
  'sourceRefs': [for (final reference in managed) reference.toJson()],
  'createdAt': '2026-09-05T00:00:00Z',
  'etag': '"part-etag-$revision"',
};

Map<String, Object?> _bookWire(MasterpieceSnapshot snapshot) {
  final book = snapshot.book;
  final sections = [
    for (final section in book.sections)
      <String, Object?>{
        'sectionKey': section.sectionKey,
        'title': section.title,
        'group': section.group,
        'ordinal': section.ordinal,
        'metadataVersion': section.metadataVersion,
        'currentPartRevisionIds': section.currentPartRevisionIds,
      },
  ];
  return {
    'bookId': book.bookId,
    'currentBookRevisionId': book.currentBookRevisionId,
    'etag': book.etag,
    'current': {
      'bookRevisionId': book.currentBookRevisionId,
      'revision': book.current.revision,
      'title': book.current.title,
      'language': book.current.language,
      'status': book.current.status,
      'sectionOrderVersion': book.current.sectionOrderVersion,
      'sections': sections,
      'createdAt': '2026-09-05T00:00:00Z',
    },
    'sections': [
      for (var index = 0; index < book.sections.length; index++)
        {
          ...sections[index],
          'parts': [
            for (final head
                in book.sections[index].currentPartRevisionIds.entries)
              {
                'part': head.key,
                'status': 'current',
                'currentRevisionId': head.value,
                'revision': 1,
              },
          ],
          'sourceRefs': [
            for (final reference in book.sections[index].sourceRefs)
              reference.toJson(),
          ],
          'resourceRefs': [
            for (final reference in book.sections[index].resourceRefs)
              reference.toJson(),
          ],
          'etag': book.sections[index].etag,
        },
    ],
  };
}
