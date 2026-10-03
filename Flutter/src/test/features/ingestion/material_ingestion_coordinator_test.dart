import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
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
import 'package:huahuoai_app/features/ui_v3/data/knowledge_library_cache.dart';
import 'package:huahuoai_app/features/ui_v3/domain/feed_item_models.dart';

void main() {
  test('link ingestion deposits the canonical HNote', () async {
    final api = _successfulLinkApi();
    final harness = _Harness(api: api);

    final created = await harness.coordinator.submitLink(
      'https://example.com/article#fragment',
    );
    final completed = await _waitForOutlineOwner(harness.store, created!.id);

    expect(completed.status, MaterialIngestionStatus.completed);
    expect(completed.noteId, 'note-1');
    expect(completed.linkOutlineOwner, MaterialLinkOutlineOwner.client);
    final note = harness.knowledge.noteForId('note-1');
    expect(note?.rawBody, '# 正式内容');
    expect(note?.publicUrl, 'https://example.com/article');
    expect(api.createLinkCalls, 1);
    expect(api.linkPollTaskIds, <String>['ingestion-1', 'ingestion-1']);
    expect(api.memoryNoteRequests, <String>['note-1']);
  });

  test('backend failure does not fabricate a note', () async {
    final harness = _Harness(
      api: _FakeMaterialApi(
        createLink: _failure<MaterialTaskSnapshot>('NOTE_PROJECTION_FAILED'),
      ),
    );

    final created = await harness.coordinator.submitLink('https://example.com');
    final failed = await _waitForTerminal(harness.store, created!.id);

    expect(failed.status, MaterialIngestionStatus.failed);
    expect(failed.lastErrorCode, 'NOTE_PROJECTION_FAILED');
    expect(harness.knowledge.notes, isEmpty);
  });

  test(
    'remote failure refresh preserves the task and diagnostic evidence',
    () async {
      const remoteFailure = MaterialTaskSnapshot(
        taskId: 'ingestion-1',
        status: MaterialRemoteTaskStatus.failed,
        errorCode: 'PYTHON_VERSION_UNSUPPORTED',
      );
      final api = _FakeMaterialApi(
        createLink: _success(_task(MaterialRemoteTaskStatus.queued)),
        linkPolls: <ApiResult<MaterialTaskSnapshot>>[_success(remoteFailure)],
        memoryNotes: <String, GeneratedMemoryNote>{'note-1': _linkHNote()},
      );
      final harness = _Harness(api: api);
      final created = await harness.coordinator.submitLink(
        'https://xhslink.cn/o/example',
      );
      final failed = await _waitForTerminal(harness.store, created!.id);

      expect(failed.lastErrorCode, 'PYTHON_VERSION_UNSUPPORTED');
      expect(failed.checkpoint, MaterialIngestionCheckpoint.taskSubmitted);
      expect(harness.knowledge.notes, isEmpty);
      await harness.coordinator.recoverPending();
      expect(api.linkPollTaskIds, <String>['ingestion-1']);

      final events = DiagnosticLogDao(harness.database).query();
      final accepted = events.singleWhere(
        (event) => event.safeSummary == 'ingestion_task_accepted',
      );
      final failure = events.singleWhere(
        (event) => event.safeSummary == 'ingestion_failed',
      );
      expect(accepted.redactedMetadata['remoteTaskId'], 'ingestion-1');
      expect(accepted.redactedMetadata['checkpoint'], 'taskSubmitted');
      expect(failure.redactedMetadata['remoteTaskId'], 'ingestion-1');
      expect(failure.redactedMetadata['failureOrigin'], 'remote_task');
      expect(
        failure.redactedMetadata['errorCode'],
        'PYTHON_VERSION_UNSUPPORTED',
      );
      expect(
        events
            .where((event) => event.safeSummary == 'ingestion_remote_status')
            .map((event) => event.redactedMetadata['remoteStatus']),
        containsAll(<String>['queued', 'failed']),
      );
      expect(
        events.map((event) => event.redactedMetadata).toString(),
        isNot(contains('xhslink.cn')),
      );

      final refreshed = Completer<ApiResult<MaterialTaskSnapshot>>();
      api.linkPollResult = refreshed.future;
      expect(await harness.coordinator.retry(failed.id), isTrue);
      expect(harness.coordinator.isRefreshingLinkTask(failed.id), isTrue);
      expect(harness.store.get(failed.id)?.toRecord(), failed.toRecord());
      expect(await harness.coordinator.retry(failed.id), isFalse);
      refreshed.complete(_success(remoteFailure));
      await Future<void>.delayed(Duration.zero);

      expect(harness.coordinator.isRefreshingLinkTask(failed.id), isFalse);
      expect(
        harness.store.get(failed.id)?.lastErrorCode,
        'PYTHON_VERSION_UNSUPPORTED',
      );
      expect(api.createLinkCalls, 1);
      expect(api.linkPollTaskIds, <String>['ingestion-1', 'ingestion-1']);
      expect(api.memoryNoteRequests, isEmpty);

      api.linkPollResult = Future.value(
        _success(
          _task(MaterialRemoteTaskStatus.completed, promotedNoteId: 'note-1'),
        ),
      );
      expect(await harness.coordinator.retry(failed.id), isTrue);
      final completed = await _waitForOutlineOwner(harness.store, failed.id);
      expect(completed.status, MaterialIngestionStatus.completed);
      expect(completed.submitKey, failed.submitKey);
      expect(api.createLinkCalls, 1);
      expect(api.memoryNoteRequests, <String>['note-1']);
    },
  );

  test('completion persistence rejects concurrent cancellation', () async {
    final cache = _BlockingKnowledgeCache();
    final harness = _Harness(api: _successfulLinkApi(), cache: cache);

    final created = await harness.coordinator.submitLink(
      'https://example.com/atomic-completion',
    );
    await cache.saveStarted.future;
    expect(await harness.coordinator.cancel(created!.id), isFalse);

    cache.releaseSave.complete();
    expect(
      (await _waitForTerminal(harness.store, created.id)).status,
      MaterialIngestionStatus.completed,
    );
  });

  test('duplicate link submissions reuse one recoverable draft', () async {
    final harness = _Harness(
      api: _FakeMaterialApi(
        createLink: _failure<MaterialTaskSnapshot>('NOTE_PROJECTION_FAILED'),
      ),
    );

    final drafts = await Future.wait(<Future<MaterialIngestionDraft?>>[
      harness.coordinator.submitLink('https://example.com/a'),
      harness.coordinator.submitLink('https://example.com/a'),
    ]);

    expect(drafts.first?.id, drafts.last?.id);
    expect(harness.store.listAll(), hasLength(1));
    await _waitForTerminal(harness.store, drafts.first!.id);
  });

  test('retryable link poll recovers without resubmitting', () async {
    final api = _FakeMaterialApi(
      createLink: _success(_task(MaterialRemoteTaskStatus.queued)),
      linkPolls: <ApiResult<MaterialTaskSnapshot>>[
        _failure<MaterialTaskSnapshot>('NETWORK_FAILED'),
        _success(
          _task(MaterialRemoteTaskStatus.completed, promotedNoteId: 'note-1'),
        ),
      ],
      memoryNotes: <String, GeneratedMemoryNote>{'note-1': _linkHNote()},
    );
    final harness = _Harness(api: api);

    final created = await harness.coordinator.submitLink('https://example.com');
    final completed = await _waitForTerminal(harness.store, created!.id);

    expect(completed.status, MaterialIngestionStatus.completed);
    expect(api.createLinkCalls, 1);
    expect(api.linkPollTaskIds, <String>['ingestion-1', 'ingestion-1']);
  });

  test('promoted link waits for its canonical HNote projection', () async {
    final api = _FakeMaterialApi(
      createLink: _success(_task(MaterialRemoteTaskStatus.queued)),
      linkPolls: <ApiResult<MaterialTaskSnapshot>>[
        _success(
          _task(MaterialRemoteTaskStatus.completed, promotedNoteId: 'note-1'),
        ),
      ],
      memoryNoteResults: <ApiResult<GeneratedMemoryNote>>[
        _failure<GeneratedMemoryNote>('WORKSPACE_NOTE_NOT_FOUND'),
        _success(_linkHNote()),
      ],
    );
    final harness = _Harness(api: api, maxPollAttempts: 4);

    final created = await harness.coordinator.submitLink('https://example.com');
    final completed = await _waitForTerminal(harness.store, created!.id);

    expect(completed.status, MaterialIngestionStatus.completed);
    expect(api.createLinkCalls, 1);
    expect(api.memoryNoteRequests, <String>['note-1', 'note-1']);
  });

  test(
    'persists backend media ownership before exposing the Knowledge note',
    () async {
      final api = _FakeMaterialApi(
        createLink: _success(_task(MaterialRemoteTaskStatus.queued)),
        linkPolls: <ApiResult<MaterialTaskSnapshot>>[
          _success(
            _task(MaterialRemoteTaskStatus.completed, promotedNoteId: 'note-1'),
          ),
        ],
        outlineOwnershipResults: <ApiResult<MaterialLinkOutlineOwnership>>[
          _success(
            const MaterialLinkOutlineOwnership(
              ingestionId: 'ingestion-1',
              owner: MaterialLinkOutlineOwner.backendMedia,
            ),
          ),
        ],
        memoryNotes: <String, GeneratedMemoryNote>{'note-1': _linkHNote()},
      );
      final harness = _Harness(api: api);

      final created = await harness.coordinator.submitLink(
        'https://example.com/video',
      );
      final completed = await _waitForOutlineOwner(harness.store, created!.id);

      expect(completed.linkOutlineOwner, MaterialLinkOutlineOwner.backendMedia);
      expect(api.callOrder, <String>[
        'create',
        'poll',
        'note',
        'outline-owner',
      ]);
      expect(harness.knowledge.noteForId('note-1'), isNotNull);
    },
  );

  test('retries ownership read without resubmitting a promoted link', () async {
    final api = _FakeMaterialApi(
      createLink: _success(_task(MaterialRemoteTaskStatus.queued)),
      linkPolls: <ApiResult<MaterialTaskSnapshot>>[
        _success(
          _task(MaterialRemoteTaskStatus.completed, promotedNoteId: 'note-1'),
        ),
      ],
      outlineOwnershipResults: <ApiResult<MaterialLinkOutlineOwnership>>[
        _failure<MaterialLinkOutlineOwnership>('NETWORK_FAILED'),
        _success(
          const MaterialLinkOutlineOwnership(
            ingestionId: 'ingestion-1',
            owner: MaterialLinkOutlineOwner.client,
          ),
        ),
      ],
      memoryNotes: <String, GeneratedMemoryNote>{'note-1': _linkHNote()},
    );
    final harness = _Harness(api: api, maxPollAttempts: 3);

    final created = await harness.coordinator.submitLink('https://example.com');
    final completed = await _waitForOutlineOwner(harness.store, created!.id);

    expect(completed.status, MaterialIngestionStatus.completed);
    expect(api.createLinkCalls, 1);
    expect(api.outlineOwnershipRequests, <String>[
      'ingestion-1',
      'ingestion-1',
    ]);
  });

  test('ownership failure cannot roll back a promoted link import', () async {
    final api = _FakeMaterialApi(
      createLink: _success(_task(MaterialRemoteTaskStatus.queued)),
      linkPolls: <ApiResult<MaterialTaskSnapshot>>[
        _success(
          _task(MaterialRemoteTaskStatus.completed, promotedNoteId: 'note-1'),
        ),
      ],
      outlineOwnershipResults: <ApiResult<MaterialLinkOutlineOwnership>>[
        _failure<MaterialLinkOutlineOwnership>(
          'URL_MEDIA_PREVIEW_UNAVAILABLE',
          isRetryable: false,
        ),
      ],
      memoryNotes: <String, GeneratedMemoryNote>{'note-1': _linkHNote()},
    );
    final harness = _Harness(api: api);

    final created = await harness.coordinator.submitLink('https://example.com');
    final completed = await _waitForTerminal(harness.store, created!.id);
    await pumpEventQueue(times: 3);

    expect(completed.status, MaterialIngestionStatus.completed);
    expect(harness.store.get(created.id)?.linkOutlineOwner, isNull);
    expect(harness.knowledge.noteForId('note-1')?.rawBody, '# 正式内容');
    expect(api.createLinkCalls, 1);
  });

  test(
    'later ownership refresh converges without replaying the link import',
    () async {
      final api = _FakeMaterialApi(
        createLink: _success(_task(MaterialRemoteTaskStatus.queued)),
        linkPolls: <ApiResult<MaterialTaskSnapshot>>[
          _success(
            _task(MaterialRemoteTaskStatus.completed, promotedNoteId: 'note-1'),
          ),
        ],
        outlineOwnershipResults: <ApiResult<MaterialLinkOutlineOwnership>>[
          _failure<MaterialLinkOutlineOwnership>(
            'URL_MEDIA_PREVIEW_UNAVAILABLE',
            isRetryable: false,
          ),
          _success(
            const MaterialLinkOutlineOwnership(
              ingestionId: 'ingestion-1',
              owner: MaterialLinkOutlineOwner.client,
            ),
          ),
        ],
        memoryNotes: <String, GeneratedMemoryNote>{'note-1': _linkHNote()},
      );
      final harness = _Harness(api: api);

      final created = await harness.coordinator.submitLink(
        'https://example.com/article',
      );
      await _waitForTerminal(harness.store, created!.id);
      await pumpEventQueue(times: 3);

      final refreshed = await Future.wait(<Future<bool>>[
        harness.coordinator.refreshLinkOutlineOwnershipForNote('note-1'),
        harness.coordinator.refreshLinkOutlineOwnershipForNote('note-1'),
      ]);

      expect(refreshed, <bool>[true, true]);
      expect(
        harness.store.get(created.id)?.linkOutlineOwner,
        MaterialLinkOutlineOwner.client,
      );
      expect(api.createLinkCalls, 1);
      expect(api.linkPollTaskIds, <String>['ingestion-1']);
      expect(api.outlineOwnershipRequests, <String>[
        'ingestion-1',
        'ingestion-1',
      ]);
    },
  );

  test(
    'recovery leaves legacy audio drafts untouched and makes no calls',
    () async {
      final api = _FakeMaterialApi();
      final harness = _Harness(api: api);
      final updatedAt = DateTime.utc(2026, 7, 14, 1);
      final internal = _legacyAudioDraft(
        id: 'internal-old',
        source: MaterialIngestionSource.internalRecording,
        checkpoint: MaterialIngestionCheckpoint.objectUploaded,
        updatedAt: updatedAt,
        uploadId: 'upload-old',
        appPrivateUri: 'app-private-media://screen-capture/internal-old.m4a',
      );
      final meeting = _legacyAudioDraft(
        id: 'meeting-old',
        source: MaterialIngestionSource.meeting,
        checkpoint: MaterialIngestionCheckpoint.taskSubmitted,
        updatedAt: updatedAt,
        remoteTaskId: 'recording-old',
      );
      expect(harness.store.save(internal), isNull);
      expect(harness.store.save(meeting), isNull);

      await harness.coordinator.recoverPending();
      await pumpEventQueue(times: 3);

      expect(harness.store.get(internal.id)?.toRecord(), internal.toRecord());
      expect(harness.store.get(meeting.id)?.toRecord(), meeting.toRecord());
      expect(api.totalCalls, 0);
      expect(harness.coordinator.activeDraft, isNull);
    },
  );

  test('legacy audio drafts reject retry and cancellation', () async {
    final harness = _Harness(api: _FakeMaterialApi());
    final failed = _legacyAudioDraft(
      id: 'internal-failed',
      source: MaterialIngestionSource.internalRecording,
      checkpoint: MaterialIngestionCheckpoint.resourceReady,
      updatedAt: DateTime.utc(2026, 7, 14),
      status: MaterialIngestionStatus.failed,
      appPrivateUri: 'app-private-media://screen-capture/internal-failed.m4a',
    );
    final queued = _legacyAudioDraft(
      id: 'meeting-queued',
      source: MaterialIngestionSource.meeting,
      checkpoint: MaterialIngestionCheckpoint.taskSubmitted,
      updatedAt: DateTime.utc(2026, 7, 14),
      remoteTaskId: 'recording-queued',
    );
    expect(harness.store.save(failed), isNull);
    expect(harness.store.save(queued), isNull);

    expect(await harness.coordinator.retry(failed.id), isFalse);
    expect(await harness.coordinator.cancel(queued.id), isFalse);
    expect(harness.store.get(failed.id)?.toRecord(), failed.toRecord());
    expect(harness.store.get(queued.id)?.toRecord(), queued.toRecord());
  });

  test('recovery still resumes a persisted link task', () async {
    final api = _FakeMaterialApi(
      linkPolls: <ApiResult<MaterialTaskSnapshot>>[
        _success(
          _task(MaterialRemoteTaskStatus.completed, promotedNoteId: 'note-1'),
        ),
      ],
      memoryNotes: <String, GeneratedMemoryNote>{'note-1': _linkHNote()},
    );
    final harness = _Harness(api: api);
    final now = DateTime.utc(2026, 7, 14);
    final draft = MaterialIngestionDraft(
      id: 'link-recovery',
      source: MaterialIngestionSource.link,
      status: MaterialIngestionStatus.queued,
      checkpoint: MaterialIngestionCheckpoint.taskSubmitted,
      title: 'example.com',
      createdAt: now,
      updatedAt: now,
      submitKey: 'submit-link-recovery',
      normalizedUrl: 'https://example.com/article',
      remoteTaskId: 'ingestion-1',
    );
    expect(harness.store.save(draft), isNull);

    await harness.coordinator.recoverPending();
    final completed = await _waitForTerminal(harness.store, draft.id);

    expect(completed.status, MaterialIngestionStatus.completed);
    expect(api.createLinkCalls, 0);
    expect(api.linkPollTaskIds, <String>['ingestion-1']);
  });
}

final class _Harness {
  _Harness({
    required MaterialIngestionApiPort api,
    KnowledgeLibraryCache? cache,
    int maxPollAttempts = 3,
  }) : database = AppDatabase(),
       knowledge = KnowledgeLibraryController(
         initialNotes: const <V3FeedItem>[],
         cache: cache,
       ) {
    store = MaterialIngestionStore(database: database);
    coordinator = MaterialIngestionCoordinator(
      api: api,
      store: store,
      knowledgeLibrary: knowledge,
      logger: DiagnosticLogger(dao: DiagnosticLogDao(database)),
      delay: (_) async {},
      maxPollAttempts: maxPollAttempts,
    );
  }

  final AppDatabase database;
  final KnowledgeLibraryController knowledge;
  late final MaterialIngestionStore store;
  late final MaterialIngestionCoordinator coordinator;
}

final class _BlockingKnowledgeCache implements KnowledgeLibraryCache {
  final Completer<void> saveStarted = Completer<void>();
  final Completer<void> releaseSave = Completer<void>();

  @override
  Future<List<V3FeedItem>?> load() async => null;

  @override
  Future<void> save(List<V3FeedItem> notes) async {
    if (!saveStarted.isCompleted) saveStarted.complete();
    await releaseSave.future;
  }
}

final class _FakeMaterialApi implements MaterialIngestionApiPort {
  _FakeMaterialApi({
    this.createLink,
    List<ApiResult<MaterialTaskSnapshot>> linkPolls = const [],
    List<ApiResult<MaterialLinkOutlineOwnership>> outlineOwnershipResults =
        const [],
    List<ApiResult<GeneratedMemoryNote>> memoryNoteResults = const [],
    Map<String, GeneratedMemoryNote> memoryNotes =
        const <String, GeneratedMemoryNote>{},
  }) : _linkPolls = List<ApiResult<MaterialTaskSnapshot>>.of(linkPolls),
       _outlineOwnershipResults =
           List<ApiResult<MaterialLinkOutlineOwnership>>.of(
             outlineOwnershipResults,
           ),
       _memoryNoteResults = List<ApiResult<GeneratedMemoryNote>>.of(
         memoryNoteResults,
       ),
       _memoryNotes = Map<String, GeneratedMemoryNote>.of(memoryNotes);

  final ApiResult<MaterialTaskSnapshot>? createLink;
  final List<ApiResult<MaterialTaskSnapshot>> _linkPolls;
  final List<ApiResult<MaterialLinkOutlineOwnership>> _outlineOwnershipResults;
  final List<ApiResult<GeneratedMemoryNote>> _memoryNoteResults;
  final Map<String, GeneratedMemoryNote> _memoryNotes;
  final List<String> memoryNoteRequests = <String>[];
  final List<String> linkPollTaskIds = <String>[];
  final List<String> outlineOwnershipRequests = <String>[];
  final List<String> callOrder = <String>[];
  Future<ApiResult<MaterialTaskSnapshot>>? linkPollResult;
  var createLinkCalls = 0;
  var totalCalls = 0;

  @override
  Future<ApiResult<MaterialTaskSnapshot>> createLinkImport({
    required Uri url,
    required String idempotencyKey,
  }) async {
    totalCalls += 1;
    createLinkCalls += 1;
    callOrder.add('create');
    return createLink ?? _failure<MaterialTaskSnapshot>('UNEXPECTED_CREATE');
  }

  @override
  Future<ApiResult<MaterialTaskSnapshot>> getLinkImport(String taskId) async {
    totalCalls += 1;
    linkPollTaskIds.add(taskId);
    callOrder.add('poll');
    if (linkPollResult != null) return linkPollResult!;
    return _linkPolls.removeAt(0);
  }

  @override
  Future<ApiResult<MaterialLinkOutlineOwnership>> getLinkOutlineOwnership(
    String taskId,
  ) async {
    totalCalls += 1;
    outlineOwnershipRequests.add(taskId);
    callOrder.add('outline-owner');
    if (_outlineOwnershipResults.isNotEmpty) {
      return _outlineOwnershipResults.removeAt(0);
    }
    return _success(
      MaterialLinkOutlineOwnership(
        ingestionId: taskId,
        owner: MaterialLinkOutlineOwner.client,
      ),
    );
  }

  @override
  Future<ApiResult<MaterialTaskSnapshot>> createVideoAnalysis({
    required String resourceId,
    required String title,
    required String idempotencyKey,
  }) async {
    totalCalls += 1;
    throw StateError('unexpected video analysis');
  }

  @override
  Future<ApiResult<MaterialTaskSnapshot>> getVideoAnalysis(
    String taskId,
  ) async {
    totalCalls += 1;
    throw StateError('unexpected video poll');
  }

  @override
  Future<ApiResult<GeneratedMemoryNote>> getMemoryNote(String noteId) async {
    totalCalls += 1;
    memoryNoteRequests.add(noteId);
    callOrder.add('note');
    if (_memoryNoteResults.isNotEmpty) return _memoryNoteResults.removeAt(0);
    final note = _memoryNotes[noteId];
    return note == null
        ? _failure<GeneratedMemoryNote>('WORKSPACE_NOTE_NOT_FOUND')
        : _success(note);
  }

  @override
  Future<ApiResult<PageResult<GeneratedMemoryNote>>> listMemoryNotes({
    String? cursor,
  }) async {
    totalCalls += 1;
    return _success(
      const PageResult<GeneratedMemoryNote>(items: <GeneratedMemoryNote>[]),
    );
  }
}

MaterialIngestionDraft _legacyAudioDraft({
  required String id,
  required MaterialIngestionSource source,
  required MaterialIngestionCheckpoint checkpoint,
  required DateTime updatedAt,
  MaterialIngestionStatus status = MaterialIngestionStatus.queued,
  String? uploadId,
  String? remoteTaskId,
  String? appPrivateUri,
}) => MaterialIngestionDraft(
  id: id,
  source: source,
  status: status,
  checkpoint: checkpoint,
  title: id,
  createdAt: updatedAt.subtract(const Duration(minutes: 1)),
  updatedAt: updatedAt,
  submitKey: 'submit-$id',
  appPrivateUri: appPrivateUri,
  fileName: appPrivateUri == null ? null : '$id.m4a',
  mimeType: appPrivateUri == null ? null : 'audio/mp4',
  sizeBytes: appPrivateUri == null ? null : 1024,
  durationSeconds: appPrivateUri == null ? null : 10,
  sha256: appPrivateUri == null ? null : List<String>.filled(64, 'a').join(),
  uploadTokenKey: appPrivateUri == null ? null : 'upload-token-$id',
  completeUploadKey: appPrivateUri == null ? null : 'complete-upload-$id',
  uploadId: uploadId,
  remoteTaskId: remoteTaskId,
  lastErrorCode: status == MaterialIngestionStatus.failed
      ? 'LEGACY_AUDIO_FAILED'
      : null,
);

Future<MaterialIngestionDraft> _waitForTerminal(
  MaterialIngestionStore store,
  String id,
) async {
  for (var index = 0; index < 200; index++) {
    final draft = store.get(id);
    if (draft != null && draft.isTerminal) return draft;
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  throw StateError('draft did not reach terminal state');
}

Future<MaterialIngestionDraft> _waitForOutlineOwner(
  MaterialIngestionStore store,
  String id,
) async {
  for (var index = 0; index < 200; index++) {
    final draft = store.get(id);
    if (draft?.linkOutlineOwner != null) return draft!;
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  throw StateError('link Outline ownership did not resolve');
}

MaterialTaskSnapshot _task(
  MaterialRemoteTaskStatus status, {
  String? promotedNoteId,
}) => MaterialTaskSnapshot(
  taskId: 'ingestion-1',
  status: status,
  promotedNoteId: promotedNoteId,
);

_FakeMaterialApi _successfulLinkApi() => _FakeMaterialApi(
  createLink: _success(_task(MaterialRemoteTaskStatus.queued)),
  linkPolls: <ApiResult<MaterialTaskSnapshot>>[
    _success(_task(MaterialRemoteTaskStatus.analyzing)),
    _success(
      _task(MaterialRemoteTaskStatus.completed, promotedNoteId: 'note-1'),
    ),
  ],
  memoryNotes: <String, GeneratedMemoryNote>{'note-1': _linkHNote()},
);

GeneratedMemoryNote _linkHNote() => GeneratedMemoryNote(
  id: 'note-1',
  title: '正式笔记',
  markdown: '# 正式内容',
  source: MaterialIngestionSource.link,
  createdAt: DateTime.utc(2026, 7, 14),
  updatedAt: DateTime.utc(2026, 7, 14, 1),
  remoteNoteId: 'note-1',
  noteRevisionId: 'note-1-revision',
  rawPartRevisionId: 'note-1-raw-revision',
);

ApiResult<T> _success<T>(T value) => ApiResult<T>.success(
  data: value,
  status: 200,
  idempotencyStore: SubmissionKeyStore.empty,
);

ApiResult<T> _failure<T>(String code, {bool isRetryable = true}) =>
    ApiResult<T>.failure(
      error: AppFailure(
        code: code,
        category: AppFailureCategory.api,
        message: 'failed',
        userMessageKey: 'test.$code',
        isRetryable: isRetryable,
        recoveryActions: const <String>['retry'],
      ),
      idempotencyStore: SubmissionKeyStore.empty,
    );
