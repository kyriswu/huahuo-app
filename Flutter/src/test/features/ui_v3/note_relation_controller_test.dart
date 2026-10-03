import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/api/api_client.dart';
import 'package:huahuoai_app/features/ui_v3/application/note_relation_controller.dart';

void main() {
  test('relation pages append once and reject a repeated cursor', () async {
    final port = _RelationPort(
      pages: <MobileNoteRelationPageResult>[
        MobileNoteRelationPageResult.success(<MobileNoteRelation>[
          _explicitRelation('relation-1', etag: '"r1"'),
        ], nextCursor: 'cursor-2'),
        MobileNoteRelationPageResult.success(<MobileNoteRelation>[
          _automaticRelation('relation-2'),
        ], nextCursor: 'cursor-2'),
      ],
    );
    final controller = _controller(port);

    await controller.load();
    expect(controller.relations, hasLength(1));
    expect(controller.hasMore, isTrue);
    await controller.loadMore();

    expect(controller.status, MobileNoteRelationStatus.failure);
    expect(controller.errorCode, 'NOTE_RELATION_CURSOR_INVALID');
    expect(controller.relations, hasLength(1));
  });

  test('automatic similar relation is immutable without a Port call', () async {
    final port = _RelationPort(
      pages: <MobileNoteRelationPageResult>[
        MobileNoteRelationPageResult.success(<MobileNoteRelation>[
          _automaticRelation('automatic-1'),
        ]),
      ],
    );
    final controller = _controller(port);
    await controller.load();

    final updated = await controller.update(
      relationId: 'automatic-1',
      rationale: '不能修改',
    );
    final deleted = await controller.delete('automatic-1');

    expect(updated.errorCode, 'NOTE_RELATION_IMMUTABLE');
    expect(deleted.errorCode, 'NOTE_RELATION_IMMUTABLE');
    expect(port.updateActionIds, isEmpty);
    expect(port.deleteActionIds, isEmpty);
  });

  test(
    'failed explicit update reuses action ID and success rotates it',
    () async {
      final port = _RelationPort(
        pages: <MobileNoteRelationPageResult>[
          MobileNoteRelationPageResult.success(<MobileNoteRelation>[
            _explicitRelation('relation-1', etag: '"r1"'),
          ]),
          MobileNoteRelationPageResult.success(<MobileNoteRelation>[
            _explicitRelation('relation-1', etag: '"r2"'),
          ]),
          MobileNoteRelationPageResult.success(<MobileNoteRelation>[
            _explicitRelation('relation-1', etag: '"r3"'),
          ]),
        ],
        updates: <MobileNoteRelationMutationResult>[
          const MobileNoteRelationMutationResult.failure('NETWORK_FAILURE'),
          const MobileNoteRelationMutationResult.success(),
          const MobileNoteRelationMutationResult.success(),
        ],
      );
      final controller = _controller(port);
      await controller.load();

      await controller.update(relationId: 'relation-1', rationale: '新理由');
      await controller.update(relationId: 'relation-1', rationale: '新理由');
      expect(port.updateActionIds[0], port.updateActionIds[1]);

      await controller.update(relationId: 'relation-1', rationale: '再次修改');
      expect(port.updateActionIds[2], isNot(port.updateActionIds[1]));
      expect(controller.relations.single.etag, '"r3"');
    },
  );

  test(
    '412 remains an explicit conflict and duplicate mutation is guarded',
    () async {
      final gate = Completer<MobileNoteRelationMutationResult>();
      final port = _RelationPort(
        pages: <MobileNoteRelationPageResult>[
          MobileNoteRelationPageResult.success(<MobileNoteRelation>[
            _explicitRelation('relation-1', etag: '"r1"'),
          ]),
        ],
        updateFutures: <Future<MobileNoteRelationMutationResult>>[gate.future],
      );
      final controller = _controller(port);
      await controller.load();

      final pending = controller.update(
        relationId: 'relation-1',
        rationale: '冲突修改',
      );
      final duplicate = await controller.update(
        relationId: 'relation-1',
        rationale: '冲突修改',
      );
      expect(duplicate.errorCode, 'NOTE_RELATION_OPERATION_IN_PROGRESS');
      gate.complete(
        const MobileNoteRelationMutationResult.conflict('PRECONDITION_FAILED'),
      );
      final conflict = await pending;

      expect(conflict.status, MobileNoteRelationOperationStatus.conflict);
      expect(controller.conflictRelationId, 'relation-1');
    },
  );

  test('create resolves the latest synchronized source revision', () async {
    var binding = const MobileNoteRelationBinding(
      noteId: 'note-1',
      sourcePartRevisionId: 'raw-revision-1',
    );
    final port = _RelationPort(
      pages: <MobileNoteRelationPageResult>[],
      creates: const <MobileNoteRelationMutationResult>[
        MobileNoteRelationMutationResult.failure('NETWORK_FAILURE'),
        MobileNoteRelationMutationResult.failure('NETWORK_FAILURE'),
      ],
    );
    final controller = NoteRelationController(
      binding: () => binding,
      port: port,
    );
    final target = _part('note-2', 'target-revision-1');

    await controller.create(
      type: MobileNoteRelationType.supports,
      target: target,
      rationale: '支持理由',
    );
    binding = const MobileNoteRelationBinding(
      noteId: 'note-1',
      sourcePartRevisionId: 'raw-revision-2',
    );
    await controller.create(
      type: MobileNoteRelationType.supports,
      target: target,
      rationale: '支持理由',
    );

    expect(port.createSourceRevisions, <String>[
      'raw-revision-1',
      'raw-revision-2',
    ]);
    expect(port.createActionIds[1], isNot(port.createActionIds[0]));
  });

  test('thrown relation page read terminates in failure', () async {
    final controller = _controller(
      _RelationPort(pages: <MobileNoteRelationPageResult>[]),
    );

    await controller.load();

    expect(controller.status, MobileNoteRelationStatus.failure);
    expect(controller.errorCode, 'NOTE_RELATION_LOAD_FAILED');
  });

  test('late page completion after disposal is discarded', () async {
    final gate = Completer<MobileNoteRelationPageResult>();
    final controller = _controller(
      _RelationPort(
        pages: <MobileNoteRelationPageResult>[],
        pageFutures: <Future<MobileNoteRelationPageResult>>[gate.future],
      ),
    );
    var notifications = 0;
    controller.addListener(() => notifications += 1);

    final pending = controller.load();
    expect(notifications, 1);
    controller.dispose();
    gate.complete(
      const MobileNoteRelationPageResult.success(<MobileNoteRelation>[]),
    );
    await pending;

    expect(notifications, 1);
  });

  test('remote relation port sends typed DTO and maps 412 conflict', () async {
    final transport = _RelationTransport(<ApiTransportResponse>[
      _relationPageResponse(),
      _relationEventResponse(),
      const ApiTransportResponse(
        status: 412,
        body: <String, Object?>{
          'success': false,
          'error': <String, Object?>{
            'code': 'PRECONDITION_FAILED',
            'message': 'stale etag',
            'retryable': false,
          },
        },
      ),
    ]);
    final port = RemoteMobileNoteRelationPort(
      apiClient: _relationApiClient(transport),
      workspaceId: () => 'workspace opaque+1',
    );

    final page = await port.loadPage(noteId: 'note-1');
    final relation = page.items.single;
    final created = await port.create(
      noteId: 'note-1',
      type: MobileNoteRelationType.supports,
      source: _part('note-1', 'raw-revision-1'),
      target: _part('note-2', 'raw-revision-2'),
      rationale: '明确支持',
      actionId: 'create-action-1',
    );
    final conflict = await port.update(
      relation: relation,
      rationale: '更新理由',
      actionId: 'update-action-1',
    );

    expect(page.status, MobileNoteRelationOperationStatus.success);
    expect(relation.isMutable, isTrue);
    expect(created.status, MobileNoteRelationOperationStatus.success);
    expect(conflict.status, MobileNoteRelationOperationStatus.conflict);
    final createBody =
        jsonDecode(transport.requests[1].body!) as Map<String, dynamic>;
    expect(createBody['relationType'], 'supports');
    expect(createBody['source'], <String, dynamic>{
      'part': 'raw',
      'partRevisionId': 'raw-revision-1',
    });
    expect((createBody['source'] as Map).containsKey('noteId'), isFalse);
    expect(createBody['target'], <String, dynamic>{
      'noteId': 'note-2',
      'part': 'raw',
      'partRevisionId': 'raw-revision-2',
    });
    expect(transport.requests[1].headers['X-Idempotency-Key'], isNotEmpty);
    expect(transport.requests[2].headers['If-Match'], '"relation-1"');
  });
}

NoteRelationController _controller(_RelationPort port) {
  return NoteRelationController(
    binding: () => const MobileNoteRelationBinding(
      noteId: 'note-1',
      sourcePartRevisionId: 'raw-revision-1',
    ),
    port: port,
  );
}

MobileNoteRelation _explicitRelation(String id, {required String etag}) {
  return MobileNoteRelation(
    relationId: id,
    type: MobileNoteRelationType.supports,
    origin: MobileNoteRelationOrigin.explicit,
    source: _part('note-1', 'raw-revision-1'),
    target: _part('note-2', 'raw-revision-2'),
    rationale: '支持理由',
    version: 1,
    etag: etag,
  );
}

MobileNoteRelation _automaticRelation(String id) {
  return MobileNoteRelation(
    relationId: id,
    type: MobileNoteRelationType.similar,
    origin: MobileNoteRelationOrigin.automatic,
    source: _part('note-1', 'raw-revision-1'),
    target: _part('note-3', 'raw-revision-3'),
    score: .86,
  );
}

MobileNotePartRef _part(String noteId, String revision) {
  return MobileNotePartRef(
    noteId: noteId,
    part: 'raw',
    partRevisionId: revision,
  );
}

final class _RelationPort implements MobileNoteRelationPort {
  _RelationPort({
    required this.pages,
    List<MobileNoteRelationMutationResult>? creates,
    List<MobileNoteRelationMutationResult>? updates,
    List<Future<MobileNoteRelationPageResult>>? pageFutures,
    List<Future<MobileNoteRelationMutationResult>>? updateFutures,
  }) : creates = creates ?? <MobileNoteRelationMutationResult>[],
       updates = updates ?? <MobileNoteRelationMutationResult>[],
       pageFutures = pageFutures ?? <Future<MobileNoteRelationPageResult>>[],
       updateFutures =
           updateFutures ?? <Future<MobileNoteRelationMutationResult>>[];

  final List<MobileNoteRelationPageResult> pages;
  final List<MobileNoteRelationMutationResult> creates;
  final List<MobileNoteRelationMutationResult> updates;
  final List<Future<MobileNoteRelationPageResult>> pageFutures;
  final List<Future<MobileNoteRelationMutationResult>> updateFutures;
  final List<String> updateActionIds = <String>[];
  final List<String> deleteActionIds = <String>[];
  final List<String> createActionIds = <String>[];
  final List<String> createSourceRevisions = <String>[];

  @override
  Future<MobileNoteRelationMutationResult> create({
    required String noteId,
    required MobileNoteRelationType type,
    required MobileNotePartRef source,
    required MobileNotePartRef target,
    required String rationale,
    required String actionId,
  }) async {
    createActionIds.add(actionId);
    createSourceRevisions.add(source.partRevisionId);
    return creates.isEmpty
        ? const MobileNoteRelationMutationResult.success()
        : creates.removeAt(0);
  }

  @override
  Future<MobileNoteRelationMutationResult> delete({
    required MobileNoteRelation relation,
    required String actionId,
  }) async {
    deleteActionIds.add(actionId);
    return const MobileNoteRelationMutationResult.success();
  }

  @override
  Future<MobileNoteRelationPageResult> loadPage({
    required String noteId,
    String? cursor,
  }) {
    if (pages.isNotEmpty) {
      return Future<MobileNoteRelationPageResult>.value(pages.removeAt(0));
    }
    return pageFutures.removeAt(0);
  }

  @override
  Future<MobileNoteRelationMutationResult> update({
    required MobileNoteRelation relation,
    MobileNoteRelationType? type,
    MobileNotePartRef? target,
    String? rationale,
    required String actionId,
  }) {
    updateActionIds.add(actionId);
    if (updateFutures.isNotEmpty) return updateFutures.removeAt(0);
    return Future<MobileNoteRelationMutationResult>.value(updates.removeAt(0));
  }
}

ApiClient _relationApiClient(_RelationTransport transport) => ApiClient(
  config: ApiClientConfig(
    baseUrl: Uri.parse('https://api.example.test'),
    clientVersion: '1',
    deviceId: 'device',
    platform: 'ios',
    locale: 'zh-CN',
    getAccessToken: () => 'token',
    traceIdFactory: () => 'trace-relation',
  ),
  transport: transport,
);

ApiTransportResponse _relationPageResponse() => const ApiTransportResponse(
  status: 200,
  body: <String, Object?>{
    'success': true,
    'data': <String, Object?>{
      'items': <Object?>[
        <String, Object?>{
          'relationId': 'relation-1',
          'relationType': 'supports',
          'origin': 'explicit',
          'source': <String, Object?>{
            'noteId': 'note-1',
            'part': 'raw',
            'partRevisionId': 'raw-revision-1',
          },
          'target': <String, Object?>{
            'noteId': 'note-2',
            'part': 'raw',
            'partRevisionId': 'raw-revision-2',
          },
          'rationale': '支持理由',
          'version': 1,
          'etag': '"relation-1"',
        },
      ],
      'nextCursor': null,
    },
  },
);

ApiTransportResponse _relationEventResponse() => const ApiTransportResponse(
  status: 200,
  body: <String, Object?>{
    'success': true,
    'data': <String, Object?>{
      'eventId': 'event-1',
      'workspaceId': 'workspace opaque+1',
      'cursor': '300',
      'operationId': 'operation-1',
      'occurredAt': '2026-08-07T10:00:00Z',
      'objectKind': 'note_relation',
      'objectId': 'relation-created-1',
      'changeType': 'created',
      'tombstone': false,
      'resourcePinDelta': <String, Object?>{
        'added': <Object?>[],
        'released': <Object?>[],
      },
      'version': 1,
    },
  },
);

final class _RelationTransport implements ApiTransport {
  _RelationTransport(this.responses);

  final List<ApiTransportResponse> responses;
  final List<ApiTransportRequest> requests = <ApiTransportRequest>[];

  @override
  Future<ApiTransportResponse> send(ApiTransportRequest request) async {
    requests.add(request);
    return responses.removeAt(0);
  }
}
