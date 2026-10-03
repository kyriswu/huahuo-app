import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuo_api/huahuo_api.dart';
import 'package:huahuoai_app/core/api/api_client.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/database/app_preferences_dao.dart';
import 'package:huahuoai_app/core/database/database_worker.dart';
import 'package:huahuoai_app/core/database/user_metadata_dao.dart';
import 'package:huahuoai_app/core/database/v3_deposit_dao.dart';
import 'package:huahuoai_app/features/ui_v3/application/feed_graph_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_library_controller.dart';
import 'package:huahuoai_app/features/ui_v3/application/knowledge_note_port.dart';
import 'package:huahuoai_app/features/ui_v3/application/subscription_port.dart';
import 'package:huahuoai_app/features/ui_v3/application/workspace_folder_port.dart';
import 'package:huahuoai_app/features/ui_v3/data/knowledge_library_cache.dart';
import 'package:huahuoai_app/features/ui_v3/data/knowledge_user_metadata_repository.dart';
import 'package:huahuoai_app/features/ui_v3/data/hotspot_note_repository.dart';
import 'package:huahuoai_app/features/ui_v3/data/ui_v3_mock_data.dart';
import 'package:huahuoai_app/features/ui_v3/data/v3_deposit_repository.dart';
import 'package:huahuoai_app/features/ui_v3/data/workspace_content_sync.dart';
import 'package:huahuoai_app/features/ui_v3/data/workspace_content_sync_store.dart';
import 'package:huahuoai_app/features/ui_v3/domain/feed_item_models.dart';
import 'package:huahuoai_app/features/ui_v3/domain/knowledge_library_models.dart';
import 'package:huahuoai_app/features/ui_v3/domain/knowledge_trash_models.dart';
import 'package:huahuoai_app/features/ui_v3/domain/v3_deposit_models.dart';

void main() {
  test(
    'folder-only projection preserves dirty notes and the committed cursor',
    () async {
      final cache = _MemoryKnowledgeLibraryCache();
      final note = V3FeedItem(
        id: 'dirty-folder-note',
        title: '尚未同步的编辑',
        source: V3MaterialSource.note,
        createdAt: DateTime.utc(2026, 8, 15),
        rawBody: '本地编辑不能丢失',
        folderId: 'nested-folder',
        syncState: NoteSyncState.localOnly,
      );
      final controller = KnowledgeLibraryController(
        cache: cache,
        workspaceFolderPort: _FakeWorkspaceFolderPort(),
        initialNotes: [note],
        includeDemoFixtures: false,
      );
      addTearDown(controller.dispose);
      await controller.applyWorkspaceContentProjection(
        WorkspaceContentProjection(
          notes: [note],
          folders: const {},
          contentCursor: '9',
          origin: WorkspaceContentProjectionOrigin.snapshot,
        ),
      );
      final priorNote = controller.notes.single;
      final priorSaves = cache.saveCalls;
      controller.applyWorkspaceFolderProjection({
        'root-folder': _workspaceRemoteFolder(
          folderId: 'root-folder',
          displayName: '项目',
          contentCursor: '10',
        ),
        'nested-folder': _workspaceRemoteFolder(
          folderId: 'nested-folder',
          displayName: '素材',
          contentCursor: '10',
          parentFolderId: 'root-folder',
        ),
        'empty-folder': _workspaceRemoteFolder(
          folderId: 'empty-folder',
          displayName: '空目录',
          contentCursor: '10',
        ),
      });
      expect(
        controller.depositFoldersIn(null).map((folder) => folder.id),
        unorderedEquals(['root-folder', 'empty-folder']),
      );
      expect(
        controller.depositFoldersIn('root-folder').single.id,
        'nested-folder',
      );
      expect(
        controller.depositedNotes(folderId: 'nested-folder').single,
        same(priorNote),
      );
      expect(controller.notes.single.rawBody, '本地编辑不能丢失');
      expect(controller.workspaceContentCursor, '9');
      await controller.flushPersistence();
      expect(cache.saveCalls, priorSaves);
    },
  );

  TestWidgetsFlutterBinding.ensureInitialized();

  test('ordinary cache save bursts persist only the latest snapshot', () async {
    final cache = _MemoryKnowledgeLibraryCache();
    final controller = KnowledgeLibraryController(
      cache: cache,
      includeDemoFixtures: false,
      autoSyncOwnedChanges: false,
    );
    addTearDown(controller.dispose);
    await controller.restore();
    final note = controller.createManualNote(title: '初稿', rawBody: '内容');
    for (var revision = 1; revision <= 20; revision++) {
      controller.updateNote(note.copyWith(title: '第 $revision 版'));
    }
    expect(await controller.flushPersistenceResult(), isTrue);
    expect(cache.saveCalls, 1);
    expect(cache.notes!.single.title, '第 20 版');
  });

  test('in-flight cache save retains exactly one latest follow-up', () async {
    final cache = _GatedSaveKnowledgeLibraryCache(gateOnSave: 1);
    final controller = KnowledgeLibraryController(
      cache: cache,
      includeDemoFixtures: false,
      autoSyncOwnedChanges: false,
    );
    addTearDown(controller.dispose);
    await controller.restore();
    final note = controller.createManualNote(title: '初稿', rawBody: '内容');
    await cache.gatedSaveStarted;
    final flushing = controller.flushPersistence();
    for (var revision = 1; revision <= 20; revision++) {
      controller.updateNote(note.copyWith(title: '第 $revision 版'));
    }
    cache.releaseGatedSave();
    await flushing;
    expect(cache.saveCalls, 2);
    expect(cache.notes!.single.title, '第 20 版');
  });

  test(
    'cache write failure stays visible until a new mutation retries',
    () async {
      final cache = _FailOnSaveNumberKnowledgeLibraryCache(failOnSave: 1);
      final controller = KnowledgeLibraryController(
        cache: cache,
        includeDemoFixtures: false,
        autoSyncOwnedChanges: false,
      );
      addTearDown(controller.dispose);
      await controller.restore();
      final note = controller.createManualNote(title: '初稿', rawBody: '内容');
      expect(await controller.flushPersistenceResult(), isFalse);
      await Future<void>.delayed(Duration.zero);
      expect(cache.saveCalls, 0);
      expect(
        controller.persistenceErrorCode,
        'KNOWLEDGE_LIBRARY_CACHE_SAVE_FAILED',
      );
      controller.updateNote(note.copyWith(title: '可重试的新版本'));
      expect(await controller.flushPersistenceResult(), isTrue);
      expect(cache.saveCalls, 1);
      expect(cache.notes!.single.title, '可重试的新版本');
    },
  );

  test('memoizes sorted note queries until a derivation changes', () {
    final now = DateTime.utc(2026, 8, 31, 9);
    final controller = KnowledgeLibraryController(
      includeDemoFixtures: false,
      initialNotes: <V3FeedItem>[
        V3FeedItem(
          id: 'note-b',
          title: 'Beta',
          source: V3MaterialSource.note,
          createdAt: now,
          rawBody: 'beta',
        ),
        V3FeedItem(
          id: 'note-a',
          title: 'Alpha',
          source: V3MaterialSource.note,
          createdAt: now.subtract(const Duration(minutes: 1)),
          rawBody: 'alpha',
        ),
      ],
    );
    addTearDown(controller.dispose);

    final first = controller.filteredNotesFor(V3KnowledgeLibraryTab.mine);
    final repeated = controller.filteredNotesFor(V3KnowledgeLibraryTab.mine);
    expect(repeated, same(first));

    controller.setQuery('alpha');
    final filtered = controller.filteredNotesFor(V3KnowledgeLibraryTab.mine);
    expect(filtered, isNot(same(first)));
    expect(filtered.single.id, 'note-a');
    expect(
      controller.filteredNotesFor(V3KnowledgeLibraryTab.mine),
      same(filtered),
    );
  });

  test('normalized note family notifies only the changed note ID', () async {
    final now = DateTime.utc(2026, 8, 31, 9);
    final controller = KnowledgeLibraryController(
      includeDemoFixtures: false,
      initialNotes: <V3FeedItem>[
        V3FeedItem(
          id: 'note-a',
          title: 'Alpha',
          source: V3MaterialSource.note,
          createdAt: now,
          rawBody: 'alpha',
        ),
        V3FeedItem(
          id: 'note-b',
          title: 'Beta',
          source: V3MaterialSource.note,
          createdAt: now,
          rawBody: 'beta',
        ),
      ],
    );
    final container = ProviderContainer(
      overrides: <Override>[
        knowledgeLibraryControllerProvider.overrideWith((ref) => controller),
      ],
    );
    addTearDown(container.dispose);
    var noteANotifications = 0;
    var noteBNotifications = 0;
    final noteA = container.listen<V3FeedItem?>(
      knowledgeNoteProvider('note-a'),
      (_, __) => noteANotifications += 1,
    );
    final noteB = container.listen<V3FeedItem?>(
      knowledgeNoteProvider('note-b'),
      (_, __) => noteBNotifications += 1,
    );
    addTearDown(noteA.close);
    addTearDown(noteB.close);

    expect(container.read(knowledgeLibraryCommandsProvider), same(controller));
    controller.updateNote(controller.noteForId('note-b')!.copyWith(title: 'B'));
    await container.pump();

    expect(noteANotifications, 0);
    expect(noteBNotifications, 1);
    expect(noteA.read()!.title, 'Alpha');
    expect(noteB.read()!.title, 'B');
    expect(controller.noteIndexSnapshot.revision, 2);
  });

  test('confirmable cache restore retries a failed load', () async {
    final note = V3FeedItem(
      id: 'retry-restored-note',
      title: '恢复后的资产',
      source: V3MaterialSource.note,
      createdAt: DateTime.utc(2026, 9, 4),
      rawBody: '缓存第二次读取成功',
    );
    final cache = _RetryableLoadKnowledgeLibraryCache(<V3FeedItem>[note]);
    final controller = KnowledgeLibraryController(
      cache: cache,
      initialNotes: const <V3FeedItem>[],
      includeDemoFixtures: false,
    );
    addTearDown(controller.dispose);

    expect(await controller.ensureCacheRestored(), isFalse);
    expect(controller.cacheRestoreSucceeded, isFalse);
    expect(
      controller.persistenceErrorCode,
      'KNOWLEDGE_LIBRARY_CACHE_LOAD_FAILED',
    );
    expect(controller.noteForId(note.id), isNull);

    expect(await controller.ensureCacheRestored(retryFailed: true), isTrue);
    expect(cache.loadCalls, 2);
    expect(controller.cacheRestoreSucceeded, isTrue);
    expect(controller.persistenceErrorCode, isNull);
    expect(controller.noteForId(note.id)?.rawBody, note.rawBody);
  });

  test('remote recording HNote keeps recording source without local cache', () {
    final note = SharedHNote(
      noteId: 'recording-note-1',
      workspaceId: 'workspace-1',
      sourceKind: 'recording',
      sourceRef: const SharedHNoteSourceRef(
        kind: 'recording',
        id: 'recording-remote-1',
      ),
      folderId: null,
      title: '访谈录音',
      state: 'live',
      noteRevisionId: 'note-revision-1',
      raw: const SharedHNotePart(
        partRevisionId: 'raw-revision-1',
        markdown: '录音转写正文',
        contentHash: 'raw-hash-1',
      ),
      outline: const SharedHNotePart(
        partRevisionId: 'outline-revision-1',
        markdown: '',
        contentHash: 'outline-hash-1',
      ),
      germination: const SharedHNotePart(
        partRevisionId: 'germination-revision-1',
        markdown: '',
        contentHash: 'germination-hash-1',
      ),
      resourceRefs: const <SharedHNoteResourceRef>[],
      etag: '"recording-note-1"',
      contentCursor: '1',
      createdAt: DateTime.utc(2026, 8, 17, 7, 46, 58),
      updatedAt: DateTime.utc(2026, 8, 17, 7, 47, 1),
    );

    final mapped = mapRemoteHNoteToFeedItem(
      note,
      localId: 'local-recording-1',
      legacyRemoteRevision: 1,
    );

    expect(mapped.source, V3MaterialSource.recordingCard);
    expect(mapped.remoteNoteId, 'recording-note-1');
    expect(mapped.recordingId, 'recording-remote-1');
    expect(mapped.createdAt, DateTime.utc(2026, 8, 17, 7, 46, 58));
    expect(mapped.updatedAt, DateTime.utc(2026, 8, 17, 7, 47, 1));
  });

  test('URL-import HNotes restore source provenance without local cache', () {
    SharedHNote remoteNote({
      required String noteId,
      required String sourceKind,
      required String rawMarkdown,
      SharedHNoteSourceRef? sourceRef,
    }) {
      return SharedHNote(
        noteId: noteId,
        workspaceId: 'workspace-1',
        sourceKind: sourceKind,
        sourceRef: sourceRef,
        folderId: null,
        title: '链接导入笔记',
        state: 'live',
        noteRevisionId: '$noteId-note-revision',
        raw: SharedHNotePart(
          partRevisionId: '$noteId-raw-revision',
          markdown: rawMarkdown,
          contentHash: '$noteId-raw-hash',
        ),
        outline: SharedHNotePart(
          partRevisionId: '$noteId-outline-revision',
          markdown: '',
          contentHash: '$noteId-outline-hash',
        ),
        germination: SharedHNotePart(
          partRevisionId: '$noteId-germination-revision',
          markdown: '',
          contentHash: '$noteId-germination-hash',
        ),
        resourceRefs: const <SharedHNoteResourceRef>[],
        etag: '"$noteId"',
        contentCursor: '2',
        createdAt: DateTime.utc(2026, 9, 12, 8),
        updatedAt: DateTime.utc(2026, 9, 12, 8, 1),
      );
    }

    const douyinUrl = 'https://www.douyin.com/video/753123456789';
    const rawEnvelope = '''Source: $douyinUrl
Platform: douyin
Author: 示例作者

---

# 抖音笔记

视频分析正文''';
    final envelopeMapped = mapRemoteHNoteToFeedItem(
      remoteNote(
        noteId: 'douyin-envelope-note',
        sourceKind: 'url_import',
        rawMarkdown: rawEnvelope,
      ),
      localId: 'local-douyin-envelope-note',
      legacyRemoteRevision: 1,
    );
    final structuredMapped = mapRemoteHNoteToFeedItem(
      remoteNote(
        noteId: 'douyin-structured-note',
        sourceKind: 'url_import',
        rawMarkdown: rawEnvelope,
        sourceRef: const SharedHNoteSourceRef(
          kind: 'url_import',
          id: 'https://v.douyin.com/structured-source/',
        ),
      ),
      localId: 'local-douyin-structured-note',
      legacyRemoteRevision: 1,
    );
    final manualMapped = mapRemoteHNoteToFeedItem(
      remoteNote(
        noteId: 'manual-note',
        sourceKind: 'manual',
        rawMarkdown: rawEnvelope,
      ),
      localId: 'local-manual-note',
      legacyRemoteRevision: 1,
    );

    expect(envelopeMapped.source, V3MaterialSource.link);
    expect(envelopeMapped.publicUrl, douyinUrl);
    expect(
      structuredMapped.publicUrl,
      'https://v.douyin.com/structured-source/',
    );
    expect(manualMapped.publicUrl, isNull);
    expect(projectV3UrlImportRawContent('正文中的链接 $douyinUrl').sourceUrl, isNull);
  });

  test('remote Part refresh waits for durable cache acknowledgement', () async {
    final local = V3FeedItem(
      id: 'local-recording-note-1',
      title: '录音笔记',
      source: V3MaterialSource.recordingCard,
      createdAt: DateTime.utc(2026, 9, 2, 8),
      updatedAt: DateTime.utc(2026, 9, 2, 8),
      rawBody: '旧转写',
      remoteNoteId: 'opaque-note-id',
      noteRevisionId: 'note-revision-1',
      rawPartRevisionId: 'raw-revision-1',
      etag: '"note-1"',
      contentCursor: 'cursor-1',
      syncState: NoteSyncState.synced,
    );
    final remote = local.copyWith(
      rawBody: '最终转写',
      noteRevisionId: 'note-revision-2',
      rawPartRevisionId: 'raw-revision-2',
      etag: '"note-2"',
      contentCursor: 'cursor-2',
      updatedAt: DateTime.utc(2026, 9, 2, 8, 1),
    );
    final cache = _GatedSaveKnowledgeLibraryCache(gateOnSave: 1);
    final controller = KnowledgeLibraryController(
      includeDemoFixtures: false,
      initialNotes: <V3FeedItem>[local],
      cache: cache,
      notePort: _RemoteDetailKnowledgeNotePort(remote),
    );
    addTearDown(controller.dispose);
    await controller.restore();

    final refresh = controller.refreshRemoteDerivedParts(local.id);
    final settled = Completer<void>();
    final observed = refresh.whenComplete(settled.complete);
    await cache.gatedSaveStarted;

    expect(controller.noteForId(local.id)?.rawPartRevisionId, 'raw-revision-2');
    expect(settled.isCompleted, isFalse);

    cache.releaseGatedSave();
    expect(await observed, isTrue);
    expect(cache.notes?.single.rawPartRevisionId, 'raw-revision-2');

    final failingController = KnowledgeLibraryController(
      includeDemoFixtures: false,
      initialNotes: <V3FeedItem>[local],
      cache: _FailingKnowledgeLibraryCache(),
      notePort: _RemoteDetailKnowledgeNotePort(remote),
    );
    addTearDown(failingController.dispose);
    await failingController.restore();

    expect(
      await failingController.refreshRemoteDerivedParts(local.id),
      isFalse,
    );
    expect(
      failingController.persistenceErrorCode,
      'KNOWLEDGE_LIBRARY_CACHE_SAVE_FAILED',
    );
  });

  test(
    'remote Part refresh rejects stale derived and unsynced commits',
    () async {
      final local = V3FeedItem(
        id: 'derived-cas-note',
        title: '派生刷新 CAS',
        source: V3MaterialSource.note,
        createdAt: DateTime.utc(2026, 9, 2, 9),
        rawBody: '原文',
        summaryBody: '# 旧纲要',
        remoteNoteId: 'remote-derived-cas-note',
        noteRevisionId: 'note-revision-1',
        rawPartRevisionId: 'raw-revision-1',
        outlinePartRevisionId: 'outline-revision-1',
        etag: '"note-1"',
        contentCursor: 'cursor-1',
        syncState: NoteSyncState.synced,
      );
      final staleRemote = local.copyWith(
        summaryBody: '# 迟到纲要',
        noteRevisionId: 'note-revision-2',
        outlinePartRevisionId: 'outline-revision-2',
        etag: '"note-2"',
        contentCursor: 'cursor-2',
      );
      final derivedPort = _GatedRemoteDetailKnowledgeNotePort();
      final controller = KnowledgeLibraryController(
        includeDemoFixtures: false,
        initialNotes: <V3FeedItem>[local],
        notePort: derivedPort,
      );
      addTearDown(controller.dispose);

      final staleRefresh = controller.refreshRemoteDerivedParts(local.id);
      await derivedPort.requestStarted;
      controller.mergeRemoteNote(
        local.copyWith(
          summaryBody: '# 更新纲要',
          noteRevisionId: 'note-revision-3',
          outlinePartRevisionId: 'outline-revision-3',
          etag: '"note-3"',
          contentCursor: 'cursor-3',
        ),
      );
      derivedPort.complete(staleRemote);

      expect(await staleRefresh, isFalse);
      expect(
        controller.noteForId(local.id)?.outlinePartRevisionId,
        'outline-revision-3',
      );
      expect(controller.noteForId(local.id)?.summaryBody, '# 更新纲要');

      final editPort = _GatedRemoteDetailKnowledgeNotePort();
      final editController = KnowledgeLibraryController(
        includeDemoFixtures: false,
        initialNotes: <V3FeedItem>[local],
        notePort: editPort,
      );
      addTearDown(editController.dispose);
      final editRefresh = editController.refreshRemoteDerivedParts(local.id);
      await editPort.requestStarted;
      editController.updateNote(
        local.copyWith(
          rawBody: '尚未同步的本地编辑',
          localRevision: local.localRevision + 1,
          syncState: NoteSyncState.pending,
        ),
      );
      editPort.complete(staleRemote);

      expect(await editRefresh, isFalse);
      expect(
        editController.noteForId(local.id)?.syncState,
        NoteSyncState.pending,
      );
      expect(editController.noteForId(local.id)?.rawBody, '尚未同步的本地编辑');
    },
  );

  test(
    'shared sparse hydrator requires Raw and skips absent derived revisions',
    () async {
      SharedHNote sparseHead(String rawPartRevisionId) => SharedHNote(
        noteId: 'raw-only-note-1',
        workspaceId: 'workspace-1',
        sourceKind: 'recording',
        folderId: null,
        title: '仅原文笔记',
        state: 'active',
        noteRevisionId: 'note-revision-1',
        raw: SharedHNotePart(
          partRevisionId: rawPartRevisionId,
          markdown: '',
          contentHash: '',
        ),
        outline: const SharedHNotePart(
          partRevisionId: '',
          markdown: '',
          contentHash: '',
        ),
        germination: const SharedHNotePart(
          partRevisionId: '   ',
          markdown: '',
          contentHash: '',
        ),
        resourceRefs: const <SharedHNoteResourceRef>[],
        etag: '"raw-only-note-1"',
        contentCursor: '1',
        createdAt: DateTime.utc(2026, 9, 2, 8),
        updatedAt: DateTime.utc(2026, 9, 2, 8, 1),
      );
      final requests = <String>[];
      Future<SharedHNotePartView> readPart({
        required String noteId,
        required String part,
        required String partRevisionId,
      }) async {
        requests.add('$part@$partRevisionId');
        return const SharedHNotePartView(
          noteId: 'raw-only-note-1',
          part: 'raw',
          partRevisionId: 'raw-revision-1',
          markdown: '服务端原始内容',
          contentHash: 'sha256:raw-only-1',
          etag: '"raw-only-part-1"',
        );
      }

      final hydrated = await hydrateWorkspaceHNoteParts(
        sparseHead('raw-revision-1'),
        readPart: readPart,
      );

      expect(requests, <String>['raw@raw-revision-1']);
      expect(hydrated.raw.markdown, '服务端原始内容');
      expect(hydrated.outline.partRevisionId, isEmpty);
      expect(hydrated.outline.markdown, isEmpty);
      expect(hydrated.outline.contentHash, isEmpty);
      expect(hydrated.germination.partRevisionId, isEmpty);
      expect(hydrated.germination.markdown, isEmpty);
      expect(hydrated.germination.contentHash, isEmpty);

      await expectLater(
        hydrateWorkspaceHNoteParts(sparseHead(''), readPart: readPart),
        throwsA(isA<FormatException>()),
      );
      expect(requests, <String>['raw@raw-revision-1']);
    },
  );

  test('masterpiece counts only unique synchronized Workspace HNotes', () {
    V3FeedItem note(
      String id, {
      String? remoteNoteId,
      NoteSyncState syncState = NoteSyncState.synced,
    }) => V3FeedItem(
      id: id,
      title: id,
      source: V3MaterialSource.note,
      createdAt: DateTime(2026, 8, 17),
      rawBody: '真实资产内容',
      remoteNoteId: remoteNoteId,
      syncState: syncState,
    );

    final workspaceLibrary = KnowledgeLibraryController(
      includeDemoFixtures: false,
      workspaceFolderPort: _FakeWorkspaceFolderPort(),
      initialNotes: <V3FeedItem>[
        note('synced-a', remoteNoteId: 'hnote-a'),
        note('synced-a-duplicate', remoteNoteId: 'hnote-a'),
        note(
          'pending-b',
          remoteNoteId: 'hnote-b',
          syncState: NoteSyncState.pending,
        ),
        note(
          'conflict-c',
          remoteNoteId: 'hnote-c',
          syncState: NoteSyncState.conflict,
        ),
        note('local-only'),
        note('synced-d', remoteNoteId: 'hnote-d'),
      ],
    );
    addTearDown(workspaceLibrary.dispose);

    expect(workspaceLibrary.allDepositedNotes, hasLength(6));
    expect(
      workspaceLibrary.masterpieceEligibleNotes.map((item) => item.id),
      <String>['synced-a', 'synced-d'],
    );
    expect(workspaceLibrary.graphNotes, hasLength(6));
    expect(workspaceLibrary.masterpieceUnsyncedCount, 2);
    expect(workspaceLibrary.masterpieceMissingRemoteIdCount, 1);
    expect(workspaceLibrary.masterpieceDuplicateRemoteIdCount, 1);
    expect(workspaceLibrary.masterpieceTemporarilyUnavailableCount, 4);

    final isolatedLibrary = KnowledgeLibraryController(
      includeDemoFixtures: false,
      initialNotes: <V3FeedItem>[note('local-fixture')],
    );
    addTearDown(isolatedLibrary.dispose);
    expect(isolatedLibrary.masterpieceEligibleNotes, hasLength(1));
  });

  test('late hotspot completion is ignored after disposal', () async {
    final repository = _GatedHotspotRepository();
    final controller = KnowledgeLibraryController(
      hotspotRepository: repository,
      initialNotes: const <V3FeedItem>[],
    );

    final loading = controller.loadHotspots();
    controller.dispose();
    repository.complete(const <V3FeedItem>[]);

    await expectLater(loading, completes);
  });

  test(
    'structured demo person replaces retired seeds and maps fixed labels',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'knowledge-demo-person',
      );
      addTearDown(() => directory.delete(recursive: true));
      final cache = ApplicationSupportKnowledgeLibraryCache(
        directoryResolver: () async => directory,
      );
      final retired = V3FeedItem(
        id: 'need',
        title: '旧演示笔记',
        source: V3MaterialSource.note,
        createdAt: DateTime(2025, 1, 1),
        rawBody: '应该由新人物资产替换。',
      );
      final userNote = V3FeedItem(
        id: 'user-note-kept-during-persona-migration',
        title: '用户自己的笔记',
        source: V3MaterialSource.note,
        createdAt: DateTime(2026, 7, 1),
        rawBody: '人物演示数据升级时必须保留。',
      );
      await cache.save(<V3FeedItem>[retired, userNote]);

      final bundledCatalog =
          jsonDecode(
                await rootBundle.loadString(
                  'assets/data/demo_person_assets_zh_CN.json',
                ),
              )
              as Map<String, dynamic>;
      expect(bundledCatalog['notes'], isA<List<dynamic>>());
      expect(bundledCatalog['notes'] as List<dynamic>, hasLength(90));

      final controller = KnowledgeLibraryController(cache: cache);
      addTearDown(controller.dispose);
      await controller.initialize();

      final demoNotes = controller.mineNotes
          .where((note) => note.id.startsWith('demo-laozhou-'))
          .toList(growable: false);
      expect(demoNotes, hasLength(90));
      expect(controller.noteForId('need'), isNull);
      expect(controller.noteForId(userNote.id), isNotNull);
      expect(controller.noteForId('demo-laozhou-001')?.title, '第一次被客户赶出办公室');
      expect(
        controller.noteForId('demo-laozhou-090')?.rawBody.length,
        greaterThan(200),
      );
    },
  );

  test('asset growth trend uses local deposit buckets and excludes future', () {
    final now = DateTime(2026, 7, 15, 12);
    final controller = KnowledgeLibraryController(
      now: () => now,
      initialNotes: [
        V3FeedItem(
          id: 'trend-monday',
          title: '周一沉淀',
          source: V3MaterialSource.note,
          createdAt: DateTime(2026, 7, 13, 9),
          rawBody: '正文',
        ),
        V3FeedItem(
          id: 'trend-tuesday-a',
          title: '周二沉淀 A',
          source: V3MaterialSource.meeting,
          createdAt: DateTime(2026, 7, 14, 9),
          rawBody: '正文',
        ),
        V3FeedItem(
          id: 'trend-tuesday-b',
          title: '周二沉淀 B',
          source: V3MaterialSource.monologue,
          createdAt: DateTime(2026, 7, 14, 16),
          rawBody: '正文',
        ),
        V3FeedItem(
          id: 'trend-today',
          title: '今日沉淀',
          source: V3MaterialSource.link,
          createdAt: DateTime(2026, 7, 15, 9),
          rawBody: '正文',
        ),
        V3FeedItem(
          id: 'trend-future',
          title: '未来沉淀',
          source: V3MaterialSource.note,
          createdAt: DateTime(2026, 7, 16, 9),
          rawBody: '正文',
        ),
      ],
    );

    expect(controller.assetNewDepositTrend(V3AssetStatisticsPeriod.week), [
      1,
      2,
      1,
      0,
      0,
      0,
      0,
    ]);
    expect(controller.assetNewDepositTrend(V3AssetStatisticsPeriod.month), [
      0,
      3,
      1,
      0,
      0,
    ]);
  });

  test(
    'fixed channel catalog has twelve articles and ordered subscriptions',
    () {
      var now = DateTime(2026, 7, 20, 9);
      final repository = V3DepositRepository(
        dao: V3DepositDao(AppDatabase()),
        userScope: 'channel-order',
      );
      final controller = KnowledgeLibraryController(
        depositRepository: repository,
        now: () => now,
      );

      expect(KnowledgeChannel.values, hasLength(9));
      for (final channel in KnowledgeChannel.values) {
        expect(controller.channelArticlesFor(channel), hasLength(12));
      }
      expect(controller.subscribedChannels, isEmpty);
      final artArticle = controller
          .channelArticlesFor(KnowledgeChannel.art)
          .first;
      expect(controller.canDepositReadOnlyContent(artArticle.id), isTrue);
      final deposited = controller.depositSubscribedSnapshot(artArticle.id)!;
      expect(deposited.isReadOnly, isFalse);
      expect(controller.isDeposited(deposited.id), isTrue);
      expect(controller.subscribedChannels, isEmpty);
      expect(controller.isSubscribed(artArticle.id), isFalse);
      expect(controller.canDepositReadOnlyContent(deposited.id), isFalse);
      expect(controller.canDepositReadOnlyContent('missing-article'), isFalse);
      expect(controller.subscribeChannel(KnowledgeChannel.art), isTrue);
      expect(controller.canDepositReadOnlyContent(artArticle.id), isTrue);
      expect(
        controller.depositSubscribedSnapshot(artArticle.id)?.id,
        deposited.id,
      );
      now = now.add(const Duration(minutes: 1));
      expect(controller.subscribeChannel(KnowledgeChannel.history), isTrue);
      expect(controller.subscribedChannels, <KnowledgeChannel>[
        KnowledgeChannel.art,
        KnowledgeChannel.history,
      ]);

      final restored = KnowledgeLibraryController(
        depositRepository: repository,
        now: () => now,
      );
      expect(restored.subscribedChannels, <KnowledgeChannel>[
        KnowledgeChannel.art,
        KnowledgeChannel.history,
      ]);
    },
  );

  test('deposit folders own browse, search, grouping, and count metadata', () {
    final repository = V3DepositRepository(
      dao: V3DepositDao(AppDatabase()),
      userScope: 'folder-metadata-user',
    );
    final controller = KnowledgeLibraryController(
      depositRepository: repository,
      initialNotes: [
        V3FeedItem(
          id: 'personal-a',
          title: '客户复盘',
          source: V3MaterialSource.note,
          createdAt: DateTime.utc(2026, 7, 18, 9),
          rawBody: '第一篇正文',
          folderId: 'legacy-folder',
          folderName: '旧文件夹',
        ),
        V3FeedItem(
          id: 'personal-b',
          title: '产品观察',
          source: V3MaterialSource.meeting,
          createdAt: DateTime.utc(2026, 7, 18, 10),
          rawBody: '第二篇正文',
        ),
        V3FeedItem(
          id: 'subscribed',
          title: '订阅内容',
          source: V3MaterialSource.subscription,
          createdAt: DateTime.utc(2026, 7, 18, 11),
          rawBody: '只读正文',
        ),
      ],
      now: () => DateTime.utc(2026, 7, 18, 12),
    );

    expect(controller.depositFilterKind, V3DepositFilterKind.browse);
    expect(controller.isDeposited('personal-a'), isTrue);
    expect(controller.isDeposited('personal-b'), isTrue);
    expect(controller.depositContent('personal-a'), isNotNull);
    expect(controller.depositContent('personal-b'), isNotNull);
    final folder = controller.createDepositFolder('客户资料')!;
    expect(
      controller.assignToDepositFolder(
        contentId: 'personal-a',
        folderId: folder.id,
      ),
      isTrue,
    );
    expect(
      controller.assignToDepositFolder(
        contentId: 'subscribed',
        folderId: folder.id,
      ),
      isFalse,
    );
    expect(controller.depositFolderNameFor('personal-a'), '客户资料');
    expect(controller.depositFolderNoteCount(folder.id), 1);
    expect(controller.unclassifiedDepositCount, 1);

    controller.setDepositGrouping(V3KnowledgeGrouping.folder);
    expect(controller.groupedDepositNotes.keys, containsAll(['客户资料', '未归档']));
    expect(controller.groupedDepositNotes.keys, isNot(contains('旧文件夹')));

    controller.setDepositFolderFilter(folder.id);
    expect(controller.filteredDepositNotes.map((note) => note.id), [
      'personal-a',
    ]);
    controller.setDepositQuery('产品观察');
    expect(controller.filteredDepositNotes.map((note) => note.id), [
      'personal-b',
    ]);
    controller.setDepositQuery('客户资料');
    expect(controller.filteredDepositNotes.map((note) => note.id), [
      'personal-a',
    ]);
    controller.setDepositQuery('旧文件夹');
    expect(controller.filteredDepositNotes, isEmpty);
    controller.setDepositQuery('');
    expect(controller.filteredDepositNotes.map((note) => note.id), [
      'personal-a',
    ]);
    controller.setDepositFolderFilter(null);
    expect(controller.depositFilterKind, V3DepositFilterKind.browse);
    expect(controller.removeFromDeposits('personal-b'), isTrue);
    expect(controller.unclassifiedDepositCount, 0);
  });

  test(
    'workspace folders and HNote placement bypass local deposit tables',
    () async {
      final repository = V3DepositRepository(
        dao: V3DepositDao(AppDatabase()),
        userScope: 'workspace-folder-user',
      );
      final port = _FakeWorkspaceFolderPort();
      final note = V3FeedItem(
        id: 'workspace-local-note',
        title: '云端笔记',
        source: V3MaterialSource.note,
        createdAt: DateTime.utc(2026, 8, 15, 10),
        rawBody: '正文',
        remoteNoteId: 'workspace-note-1',
        noteRevisionId: 'note-revision-1',
        rawPartRevisionId: 'raw-revision-1',
        etag: '"note-1"',
        syncState: NoteSyncState.synced,
      );
      final controller = KnowledgeLibraryController(
        depositRepository: repository,
        workspaceFolderPort: port,
        includeDemoFixtures: false,
        initialNotes: <V3FeedItem>[note],
      );
      addTearDown(controller.dispose);

      await controller.applyWorkspaceContentProjection(
        WorkspaceContentProjection(
          notes: <V3FeedItem>[note],
          folders: <String, WorkspaceContentRemoteFolder>{
            'folder-existing': _workspaceRemoteFolder(
              folderId: 'folder-existing',
              displayName: '既有资料',
              contentCursor: '100',
            ),
          },
          contentCursor: '100',
          origin: WorkspaceContentProjectionOrigin.snapshot,
        ),
      );

      final created = await controller.createWorkspaceDepositFolder('项目资料');
      expect(created.isSuccess, isTrue);
      expect(created.data?.id, 'folder-created');
      expect(port.createRequests, hasLength(1));
      expect(controller.depositFolderFor('folder-created')?.name, '项目资料');

      final moved = await controller.moveDepositContentToWorkspaceFolder(
        contentId: note.id,
        folderId: 'folder-created',
      );
      expect(moved.isSuccess, isTrue);
      expect(port.moveRequests, hasLength(1));
      expect(port.moveRequests.single.folderId, 'folder-created');
      expect(port.moveRequests.single.noteId, 'workspace-note-1');
      expect(controller.depositRecordFor(note.id)?.folderId, 'folder-created');
      expect(controller.noteForId(note.id)?.folderName, '项目资料');

      final deleted = await controller.deleteWorkspaceDepositFolder(
        'folder-created',
      );
      expect(deleted.isSuccess, isTrue);
      expect(controller.depositFolderFor('folder-created'), isNull);
      expect(controller.noteForId(note.id), isNull);
      expect(
        controller.canRestoreWorkspaceDepositFolder('folder-created'),
        isTrue,
      );
      final restored = await controller.restoreWorkspaceDepositFolder(
        'folder-created',
      );
      expect(restored.isSuccess, isTrue);
      expect(port.restoreRequests, <String>[
        'folder-created|"folder-tombstoned"',
      ]);
      expect(
        controller.canRestoreWorkspaceDepositFolder('folder-created'),
        isFalse,
      );
      expect(repository.loadFolders(), isEmpty);
      expect(repository.loadDepositRecords(), isEmpty);
    },
  );

  test(
    'workspace HNote tombstone and restore bypass local deposit tables',
    () async {
      final repository = V3DepositRepository(
        dao: V3DepositDao(AppDatabase()),
        userScope: 'workspace-lifecycle-user',
      );
      final lifecycle = _FakeLifecycleKnowledgeNotePort(
        failFirstTombstone: true,
      );
      final note = V3FeedItem(
        id: 'workspace-lifecycle-local',
        title: '云端生命周期笔记',
        source: V3MaterialSource.note,
        createdAt: DateTime.utc(2026, 8, 15, 10),
        rawBody: '正文',
        remoteNoteId: 'workspace-lifecycle-note',
        noteRevisionId: 'note-revision-1',
        rawPartRevisionId: 'raw-revision-1',
        etag: '"note-1"',
        contentCursor: '110',
        syncState: NoteSyncState.synced,
      );
      final controller = KnowledgeLibraryController(
        depositRepository: repository,
        workspaceFolderPort: _FakeWorkspaceFolderPort(),
        notePort: lifecycle,
        cache: _MemoryKnowledgeLibraryCache(),
        trashRepository: _MemoryTrashRepository(),
        includeDemoFixtures: false,
        initialNotes: <V3FeedItem>[note],
      );
      addTearDown(controller.dispose);

      final failed = await controller.deleteNoteDurably(note.id);
      expect(failed.outcome, KnowledgeNoteDeleteOutcome.persistenceFailed);
      expect(controller.noteForId(note.id), isNotNull);

      final deleted = await controller.deleteNoteDurably(note.id);
      expect(deleted.outcome, KnowledgeNoteDeleteOutcome.deleted);
      expect(controller.noteForId(note.id), isNull);
      expect(controller.trashEntries.single.note.etag, '"note-tombstoned"');
      expect(lifecycle.tombstoneKeys.toSet(), hasLength(1));
      expect(repository.loadFolders(), isEmpty);
      expect(repository.loadDepositRecords(), isEmpty);

      expect(await controller.restoreTrashEntry(note.id), isTrue);
      expect(controller.noteForId(note.id)?.etag, '"note-restored"');
      expect(controller.trashEntries, isEmpty);
      expect(lifecycle.restoreKeys, hasLength(1));
      expect(repository.loadFolders(), isEmpty);
      expect(repository.loadDepositRecords(), isEmpty);
    },
  );

  test(
    'workspace tombstone compensation rotates the next delete intent',
    () async {
      final lifecycle = _FakeLifecycleKnowledgeNotePort();
      final cache = _MemoryKnowledgeLibraryCache();
      final note = V3FeedItem(
        id: 'workspace-compensation-local',
        title: '补偿笔记',
        source: V3MaterialSource.note,
        createdAt: DateTime.utc(2026, 8, 15, 10),
        rawBody: '正文',
        remoteNoteId: 'workspace-compensation-note',
        noteRevisionId: 'note-revision-1',
        rawPartRevisionId: 'raw-revision-1',
        etag: '"note-1"',
        contentCursor: '110',
        syncState: NoteSyncState.synced,
      );
      final controller = KnowledgeLibraryController(
        workspaceFolderPort: _FakeWorkspaceFolderPort(),
        notePort: lifecycle,
        cache: cache,
        trashRepository: _FailOnceTrashRepository(),
        includeDemoFixtures: false,
        initialNotes: <V3FeedItem>[note],
      );
      addTearDown(controller.dispose);

      final first = await controller.deleteNoteDurably(note.id);

      expect(first.outcome, KnowledgeNoteDeleteOutcome.persistenceFailed);
      expect(controller.noteForId(note.id)?.etag, '"note-restored"');
      expect(cache.notes?.single.etag, '"note-restored"');
      expect(lifecycle.restoreKeys, hasLength(1));

      final second = await controller.deleteNoteDurably(note.id);

      expect(second.outcome, KnowledgeNoteDeleteOutcome.deleted);
      expect(lifecycle.tombstoneKeys, hasLength(2));
      expect(
        lifecycle.tombstoneKeys.first,
        isNot(lifecycle.tombstoneKeys.last),
      );
    },
  );

  test(
    'workspace restore compensates an accepted restore after cache failure',
    () async {
      final lifecycle = _FakeLifecycleKnowledgeNotePort();
      final cache = _FailOnSaveNumberKnowledgeLibraryCache(failOnSave: 2);
      final trash = _MemoryTrashRepository();
      final note = _workspaceLifecycleNote(
        id: 'workspace-restore-cache-local',
        remoteNoteId: 'workspace-restore-cache-note',
      );
      final controller = KnowledgeLibraryController(
        workspaceFolderPort: _FakeWorkspaceFolderPort(),
        notePort: lifecycle,
        cache: cache,
        trashRepository: trash,
        includeDemoFixtures: false,
        initialNotes: <V3FeedItem>[note],
      );
      addTearDown(controller.dispose);

      expect(
        (await controller.deleteNoteDurably(note.id)).outcome,
        KnowledgeNoteDeleteOutcome.deleted,
      );

      expect(await controller.restoreTrashEntry(note.id), isFalse);
      expect(controller.noteForId(note.id), isNull);
      expect(controller.trashEntries.single.note.etag, '"note-tombstoned"');
      expect(trash.entries.single.note.etag, '"note-tombstoned"');
      expect(cache.notes, isEmpty);
      expect(lifecycle.tombstoneKeys, hasLength(2));

      expect(await controller.restoreTrashEntry(note.id), isTrue);
      expect(controller.noteForId(note.id)?.etag, '"note-restored"');
      expect(controller.trashEntries, isEmpty);
      expect(trash.entries, isEmpty);
    },
  );

  test(
    'workspace restore replays its accepted idempotency key after a failed compensation',
    () async {
      final lifecycle = _FakeLifecycleKnowledgeNotePort(failTombstoneOnCall: 2);
      final cache = _FailOnSaveNumberKnowledgeLibraryCache(failOnSave: 2);
      final note = _workspaceLifecycleNote(
        id: 'workspace-restore-replay-local',
        remoteNoteId: 'workspace-restore-replay-note',
      );
      final controller = KnowledgeLibraryController(
        workspaceFolderPort: _FakeWorkspaceFolderPort(),
        notePort: lifecycle,
        cache: cache,
        trashRepository: _MemoryTrashRepository(),
        includeDemoFixtures: false,
        initialNotes: <V3FeedItem>[note],
      );
      addTearDown(controller.dispose);

      expect(
        (await controller.deleteNoteDurably(note.id)).outcome,
        KnowledgeNoteDeleteOutcome.deleted,
      );
      expect(await controller.restoreTrashEntry(note.id), isFalse);
      expect(controller.noteForId(note.id), isNull);
      expect(controller.trashEntries, hasLength(1));
      expect(lifecycle.restoreKeys, hasLength(1));

      expect(await controller.restoreTrashEntry(note.id), isTrue);
      expect(lifecycle.restoreKeys, hasLength(2));
      expect(lifecycle.restoreKeys.first, lifecycle.restoreKeys.last);
      expect(controller.noteForId(note.id)?.etag, '"note-restored"');
      expect(controller.trashEntries, isEmpty);
    },
  );

  test(
    'workspace restore retains a concurrent edit while its cache save is pending',
    () async {
      final lifecycle = _FakeLifecycleKnowledgeNotePort();
      final cache = _GatedSaveKnowledgeLibraryCache(gateOnSave: 2);
      final restored = _workspaceLifecycleNote(
        id: 'workspace-restore-concurrent-local',
        remoteNoteId: 'workspace-restore-concurrent-note',
      );
      final other = _workspaceLifecycleNote(
        id: 'workspace-restore-other-local',
        remoteNoteId: 'workspace-restore-other-note',
      );
      final controller = KnowledgeLibraryController(
        workspaceFolderPort: _FakeWorkspaceFolderPort(),
        notePort: lifecycle,
        cache: cache,
        trashRepository: _MemoryTrashRepository(),
        includeDemoFixtures: false,
        initialNotes: <V3FeedItem>[restored, other],
      );
      addTearDown(controller.dispose);

      expect(
        (await controller.deleteNoteDurably(restored.id)).outcome,
        KnowledgeNoteDeleteOutcome.deleted,
      );
      final restoring = controller.restoreTrashEntry(restored.id);
      await cache.gatedSaveStarted;
      controller.updateNote(
        other.copyWith(
          title: '并发编辑仍需保留',
          localRevision: other.localRevision + 1,
          syncState: NoteSyncState.pending,
          updatedAt: DateTime.utc(2026, 8, 15, 11),
        ),
      );
      cache.releaseGatedSave();

      expect(await restoring, isTrue);
      await controller.flushPersistence();
      expect(controller.noteForId(restored.id)?.etag, '"note-restored"');
      expect(controller.noteForId(other.id)?.title, '并发编辑仍需保留');
      expect(
        cache.notes?.singleWhere((note) => note.id == other.id).title,
        '并发编辑仍需保留',
      );
      expect(cache.notes?.any((note) => note.id == restored.id), isTrue);
    },
  );

  test(
    'workspace delete compensation retains a concurrent edit after cache failure',
    () async {
      final lifecycle = _FakeLifecycleKnowledgeNotePort();
      final cache = _GatedFailingSaveKnowledgeLibraryCache();
      final target = _workspaceLifecycleNote(
        id: 'workspace-delete-concurrent-local',
        remoteNoteId: 'workspace-delete-concurrent-note',
      );
      final other = _workspaceLifecycleNote(
        id: 'workspace-delete-concurrent-other-local',
        remoteNoteId: 'workspace-delete-concurrent-other-note',
      );
      final controller = KnowledgeLibraryController(
        workspaceFolderPort: _FakeWorkspaceFolderPort(),
        notePort: lifecycle,
        cache: cache,
        trashRepository: _MemoryTrashRepository(),
        includeDemoFixtures: false,
        initialNotes: <V3FeedItem>[target, other],
      );
      addTearDown(controller.dispose);

      final deleting = controller.deleteNoteDurably(target.id);
      await cache.firstSaveStarted;
      controller.updateNote(
        other.copyWith(
          title: '删除回滚期间的编辑',
          localRevision: other.localRevision + 1,
          syncState: NoteSyncState.pending,
          updatedAt: DateTime.utc(2026, 8, 15, 11),
        ),
      );
      cache.releaseFirstSave();
      await cache.secondSaveStarted;
      cache.releaseSecondSave();

      expect(
        (await deleting).outcome,
        KnowledgeNoteDeleteOutcome.persistenceFailed,
      );
      await controller.flushPersistence();
      expect(controller.noteForId(target.id)?.etag, '"note-restored"');
      expect(controller.noteForId(other.id)?.title, '删除回滚期间的编辑');
      expect(
        cache.notes?.singleWhere((note) => note.id == other.id).title,
        '删除回滚期间的编辑',
      );
      expect(cache.notes?.any((note) => note.id == target.id), isTrue);
      expect(controller.trashEntries, isEmpty);
    },
  );

  test(
    'unconfirmed workspace delete compensation leaves a retryable tombstone only',
    () async {
      final lifecycle = _FakeLifecycleKnowledgeNotePort(failRestoreOnCall: 1);
      final cache = _MemoryKnowledgeLibraryCache();
      final trash = _FailOnceTrashRepository();
      final note = _workspaceLifecycleNote(
        id: 'workspace-delete-unconfirmed-local',
        remoteNoteId: 'workspace-delete-unconfirmed-note',
      );
      final controller = KnowledgeLibraryController(
        workspaceFolderPort: _FakeWorkspaceFolderPort(),
        notePort: lifecycle,
        cache: cache,
        trashRepository: trash,
        includeDemoFixtures: false,
        initialNotes: <V3FeedItem>[note],
      );
      addTearDown(controller.dispose);

      final failed = await controller.deleteNoteDurably(note.id);

      expect(failed.outcome, KnowledgeNoteDeleteOutcome.persistenceFailed);
      expect(controller.noteForId(note.id), isNull);
      expect(controller.trashEntries.single.note.etag, '"note-tombstoned"');
      expect(trash.entries.single.note.etag, '"note-tombstoned"');
      expect(cache.notes, isEmpty);
      expect(lifecycle.restoreKeys, hasLength(1));

      expect(await controller.restoreTrashEntry(note.id), isTrue);
      expect(lifecycle.restoreKeys, hasLength(2));
      expect(lifecycle.restoreKeys.first, lifecycle.restoreKeys.last);
      expect(controller.noteForId(note.id)?.etag, '"note-restored"');
      expect(controller.trashEntries, isEmpty);
    },
  );

  test(
    'workspace restore compensates an accepted restore after trash failure',
    () async {
      final lifecycle = _FakeLifecycleKnowledgeNotePort();
      final cache = _MemoryKnowledgeLibraryCache();
      final trash = _FailOnSaveNumberTrashRepository(failOnSave: 2);
      final note = _workspaceLifecycleNote(
        id: 'workspace-restore-trash-local',
        remoteNoteId: 'workspace-restore-trash-note',
      );
      final controller = KnowledgeLibraryController(
        workspaceFolderPort: _FakeWorkspaceFolderPort(),
        notePort: lifecycle,
        cache: cache,
        trashRepository: trash,
        includeDemoFixtures: false,
        initialNotes: <V3FeedItem>[note],
      );
      addTearDown(controller.dispose);

      expect(
        (await controller.deleteNoteDurably(note.id)).outcome,
        KnowledgeNoteDeleteOutcome.deleted,
      );

      expect(await controller.restoreTrashEntry(note.id), isFalse);
      expect(controller.noteForId(note.id), isNull);
      expect(controller.trashEntries.single.note.etag, '"note-tombstoned"');
      expect(trash.entries.single.note.etag, '"note-tombstoned"');
      expect(cache.notes, isEmpty);
      expect(lifecycle.tombstoneKeys, hasLength(2));

      expect(await controller.restoreTrashEntry(note.id), isTrue);
      expect(controller.noteForId(note.id)?.etag, '"note-restored"');
      expect(controller.trashEntries, isEmpty);
      expect(trash.entries, isEmpty);
    },
  );

  test(
    'workspace delete compensation retries its trash rollback write',
    () async {
      final lifecycle = _FakeLifecycleKnowledgeNotePort();
      final trash = _FailOnSaveNumberTrashRepository(failOnSave: 2);
      final note = _workspaceLifecycleNote(
        id: 'workspace-delete-rollback-local',
        remoteNoteId: 'workspace-delete-rollback-note',
      );
      final controller = KnowledgeLibraryController(
        workspaceFolderPort: _FakeWorkspaceFolderPort(),
        notePort: lifecycle,
        cache: _FailingKnowledgeLibraryCache(),
        trashRepository: trash,
        includeDemoFixtures: false,
        initialNotes: <V3FeedItem>[note],
      );
      addTearDown(controller.dispose);

      final result = await controller.deleteNoteDurably(note.id);

      expect(result.outcome, KnowledgeNoteDeleteOutcome.persistenceFailed);
      expect(controller.noteForId(note.id)?.etag, '"note-restored"');
      expect(controller.trashEntries, isEmpty);
      expect(trash.entries, isEmpty);
      expect(lifecycle.restoreKeys, hasLength(1));
    },
  );

  test(
    'workspace projection removes stale trash for a live remote Note',
    () async {
      final stale =
          _workspaceLifecycleNote(
            id: 'workspace-projection-trash-local',
            remoteNoteId: 'workspace-projection-trash-note',
          ).copyWith(
            noteRevisionId: 'note-revision-tombstoned',
            rawPartRevisionId: 'raw-revision-tombstoned',
            etag: '"note-tombstoned"',
            contentCursor: '111',
          );
      final trash = _MemoryTrashRepository()
        ..entries = <KnowledgeTrashEntry>[
          KnowledgeTrashEntry(
            note: stale,
            deletedAt: DateTime.utc(2026, 8, 15, 10),
          ),
        ];
      final controller = KnowledgeLibraryController(
        workspaceFolderPort: _FakeWorkspaceFolderPort(),
        cache: _MemoryKnowledgeLibraryCache(),
        trashRepository: trash,
        includeDemoFixtures: false,
        initialNotes: const <V3FeedItem>[],
      );
      addTearDown(controller.dispose);

      await controller.initialize();
      expect(controller.trashEntries, hasLength(1));

      await controller.applyWorkspaceContentProjection(
        WorkspaceContentProjection(
          notes: <V3FeedItem>[
            stale.copyWith(
              noteRevisionId: 'note-revision-restored',
              rawPartRevisionId: 'raw-revision-restored',
              etag: '"note-restored"',
              contentCursor: '112',
            ),
          ],
          folders: const <String, WorkspaceContentRemoteFolder>{},
          contentCursor: '112',
          origin: WorkspaceContentProjectionOrigin.changes,
        ),
      );

      expect(controller.noteForId(stale.id)?.etag, '"note-restored"');
      expect(controller.trashEntries, isEmpty);
      expect(trash.entries, isEmpty);
    },
  );

  test(
    'workspace mutation waits for an older projection then consumes its delta',
    () async {
      final port = _FakeWorkspaceFolderPort();
      final remote = _QueuedWorkspaceSyncRemote();
      final note = V3FeedItem(
        id: 'serialized-local-note',
        title: '串行同步笔记',
        source: V3MaterialSource.note,
        createdAt: DateTime.utc(2026, 8, 15, 10),
        rawBody: '正文',
        remoteNoteId: 'serialized-remote-note',
        noteRevisionId: 'note-revision-1',
        rawPartRevisionId: 'raw-revision-1',
        etag: '"note-1"',
        contentCursor: '10',
        syncState: NoteSyncState.synced,
      );
      final cache = _MemoryKnowledgeLibraryCache();
      final controller = KnowledgeLibraryController(
        workspaceFolderPort: port,
        cache: cache,
        includeDemoFixtures: false,
        initialNotes: <V3FeedItem>[note],
      );
      addTearDown(controller.dispose);
      final folder = _workspaceRemoteFolder(
        folderId: 'folder-created',
        displayName: '目标目录',
        contentCursor: '10',
      );
      await controller.applyWorkspaceContentProjection(
        WorkspaceContentProjection(
          notes: <V3FeedItem>[note],
          folders: <String, WorkspaceContentRemoteFolder>{
            folder.folderId: folder,
          },
          contentCursor: '10',
          origin: WorkspaceContentProjectionOrigin.snapshot,
        ),
      );
      final store = WorkspaceContentSyncStore(
        preferences: AppPreferencesDao(AppDatabase()),
        userScope: 'serialized-user',
        workspaceId: 'workspace-1',
      );
      store.save(
        WorkspaceContentSyncState(
          contentCursor: '10',
          folders: <String, WorkspaceContentRemoteFolder>{
            folder.folderId: folder,
          },
        ),
      );
      controller.attachWorkspaceContentSync(
        WorkspaceContentSync(
          remote: remote,
          store: store,
          workspaceId: 'workspace-1',
          readProjection: () => controller.notes,
          readProjectionCursor: () => controller.workspaceContentCursor,
          applyProjection: controller.applyWorkspaceContentProjection,
        ),
      );

      final olderProjection = controller.synchronizeWorkspaceContent();
      await remote.firstChangeRequested.future;
      final moved = controller.moveDepositContentToWorkspaceFolder(
        contentId: note.id,
        folderId: folder.folderId,
      );
      await Future<void>.delayed(Duration.zero);
      expect(port.moveRequests, isEmpty);

      remote.completeFirstChange();
      await olderProjection;
      expect((await moved).isSuccess, isTrue);

      expect(port.moveRequests, hasLength(1));
      expect(remote.changeAfters, <String>['10', '10']);
      expect(controller.noteForId(note.id)?.folderId, folder.folderId);
      expect(store.load().contentCursor, '12');
    },
  );

  test(
    'deposit folders expose a cycle-safe hierarchy and promote contents',
    () {
      final now = DateTime.utc(2026, 7, 27, 10);
      final controller = KnowledgeLibraryController(
        now: () => now,
        initialNotes: [
          V3FeedItem(
            id: 'root-note',
            title: '根目录笔记',
            source: V3MaterialSource.note,
            createdAt: now,
            rawBody: '正文',
          ),
          V3FeedItem(
            id: 'child-note',
            title: '子目录笔记',
            source: V3MaterialSource.note,
            createdAt: now,
            rawBody: '正文',
          ),
        ],
      );
      final root = controller.createDepositFolder('客户资料')!;
      final child = controller.createDepositFolder(
        '会议',
        parentFolderId: root.id,
      )!;
      final grandchild = controller.createDepositFolder(
        '周会',
        parentFolderId: child.id,
      )!;

      expect(controller.depositFoldersIn(null), contains(root));
      expect(controller.depositFoldersIn(root.id), contains(child));
      expect(controller.depositFolderPath(grandchild.id), '客户资料 / 会议 / 周会');
      expect(controller.depositFolderDepth(grandchild.id), 2);
      expect(
        controller.canUseDepositFolderName(name: '会议', parentFolderId: root.id),
        isFalse,
      );
      expect(
        controller.canUseDepositFolderName(
          name: '会议',
          parentFolderId: child.id,
        ),
        isTrue,
      );

      expect(
        controller.assignToDepositFolder(
          contentId: 'root-note',
          folderId: root.id,
        ),
        isTrue,
      );
      expect(
        controller.assignToDepositFolder(
          contentId: 'child-note',
          folderId: child.id,
        ),
        isTrue,
      );
      expect(controller.deleteDepositFolder(root.id), isTrue);

      expect(controller.depositFolderFor(child.id)?.parentFolderId, isNull);
      expect(
        controller.depositFolderFor(grandchild.id)?.parentFolderId,
        child.id,
      );
      expect(controller.depositRecordFor('root-note')?.folderId, isNull);
      expect(controller.depositRecordFor('child-note')?.folderId, child.id);
    },
  );

  test('knowledge and deposit view filters remain independent', () {
    final now = DateTime(2026, 7, 19, 12);
    final controller = KnowledgeLibraryController(
      initialNotes: [
        V3FeedItem(
          id: 'meeting-today',
          title: '今日会议',
          source: V3MaterialSource.meeting,
          createdAt: DateTime(2026, 7, 19, 9),
          rawBody: '会议正文',
        ),
        V3FeedItem(
          id: 'note-old',
          title: '旧笔记',
          source: V3MaterialSource.note,
          createdAt: DateTime(2026, 7, 10, 9),
          rawBody: '笔记正文',
        ),
      ],
      now: () => now,
    );
    expect(controller.depositContent('meeting-today'), isNotNull);
    expect(controller.depositContent('note-old'), isNotNull);

    controller
      ..setQuery('会议')
      ..setSourceFilter(KnowledgeSourceFilter.meeting)
      ..setCustomTimeRange(
        KnowledgeDateRange(
          start: DateTime(2026, 7, 19),
          end: DateTime(2026, 7, 19),
        ),
      )
      ..setGrouping(V3KnowledgeGrouping.source)
      ..setSort(V3KnowledgeSort.name);

    expect(controller.filteredNotes.single.id, 'meeting-today');
    expect(controller.depositQuery, isEmpty);
    expect(controller.depositSourceFilter, KnowledgeSourceFilter.all);
    expect(controller.depositTimeFilter, KnowledgeTimeFilter.all);
    expect(controller.depositCustomTimeRange, isNull);
    expect(controller.depositGrouping, V3KnowledgeGrouping.ownership);
    expect(controller.depositSort, V3KnowledgeSort.recentlyUpdated);
    expect(controller.filteredDepositNotes, hasLength(2));

    controller
      ..setDepositQuery('旧笔记')
      ..setDepositSourceFilter(KnowledgeSourceFilter.manualNote)
      ..setDepositCustomTimeRange(
        KnowledgeDateRange(
          start: DateTime(2026, 7, 10),
          end: DateTime(2026, 7, 10),
        ),
      )
      ..setDepositGrouping(V3KnowledgeGrouping.folder)
      ..setDepositSort(V3KnowledgeSort.earliestCreated);

    expect(controller.filteredDepositNotes.single.id, 'note-old');
    expect(controller.query, '会议');
    expect(controller.sourceFilter, KnowledgeSourceFilter.meeting);
    expect(controller.timeFilter, KnowledgeTimeFilter.custom);
    expect(controller.customTimeRange?.start, DateTime(2026, 7, 19));
    expect(controller.customTimeRange?.end, DateTime(2026, 7, 19));
    expect(controller.grouping, V3KnowledgeGrouping.source);
    expect(controller.sort, V3KnowledgeSort.name);
    expect(controller.filteredNotes.single.id, 'meeting-today');
  });

  test(
    'deposit persistence failures never commit controller metadata',
    () async {
      final root = await Directory.systemTemp.createTemp('deposit-failure-');
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final store = _ToggleFailingSnapshotStore(
        file: File('${root.path}/knowledge.json'),
      );
      final repository = V3DepositRepository(
        dao: V3DepositDao(AppDatabase(snapshotStore: store)),
        userScope: 'failure-user',
      );
      final controller = KnowledgeLibraryController(
        depositRepository: repository,
        initialNotes: [
          V3FeedItem(
            id: 'personal',
            title: '个人笔记',
            source: V3MaterialSource.note,
            createdAt: DateTime.utc(2026, 7, 18, 9),
            rawBody: '正文',
          ),
        ],
        now: () => DateTime.utc(2026, 7, 18, 12),
      );
      final folder = controller.createDepositFolder('稳定目录')!;
      expect(
        controller.depositContent('personal', folderId: folder.id),
        isNotNull,
      );
      store.failWrites = true;

      expect(controller.createDepositFolder('不会出现'), isNull);
      expect(controller.depositFolders.map((item) => item.name), ['稳定目录']);
      expect(
        controller.renameDepositFolder(folderId: folder.id, name: '不会改名'),
        isFalse,
      );
      expect(controller.depositFolderFor(folder.id)?.name, '稳定目录');
      expect(controller.assignToDepositFolder(contentId: 'personal'), isFalse);
      expect(controller.depositRecordFor('personal')?.folderId, folder.id);
      expect(controller.deleteDepositFolder(folder.id), isFalse);
      expect(controller.depositFolderFor(folder.id), isNotNull);
      expect(controller.depositRecordFor('personal')?.folderId, folder.id);
      expect(repository.loadFolders().single.name, '稳定目录');
      expect(
        repository
            .loadDepositRecords()
            .firstWhere((record) => record.contentId == 'personal')
            .folderId,
        folder.id,
      );
      expect(
        controller.depositPersistenceErrorCode,
        'DEPOSIT_FOLDER_DELETE_FAILED',
      );

      store.failWrites = false;
      expect(
        controller.renameDepositFolder(folderId: folder.id, name: '恢复目录'),
        isTrue,
      );
      expect(controller.depositPersistenceErrorCode, isNull);
    },
  );

  test(
    'owned content automatically enters deposits using its creation time',
    () {
      final controller = KnowledgeLibraryController(
        initialNotes: [
          V3FeedItem(
            id: 'new-note',
            title: '新笔记',
            source: V3MaterialSource.note,
            createdAt: DateTime.utc(2026, 7, 19),
            rawBody: '正文',
          ),
        ],
      );

      expect(controller.tab, V3KnowledgeLibraryTab.mine);
      expect(controller.mineNotes.single.id, 'new-note');
      expect(controller.isDeposited('new-note'), isTrue);
      expect(
        controller.depositRecords.single.depositedAt,
        DateTime.utc(2026, 7, 19),
      );
      expect(controller.growthLedgerCount, 1);

      final deposited = controller.depositContent('new-note');

      expect(deposited?.contentId, 'new-note');
      expect(controller.isDeposited('new-note'), isTrue);
    },
  );

  test(
    'historical deposit repairs missing growth ledger idempotently on load',
    () {
      const scope = 'historical-growth-user';
      const contentId = 'historical-owned-note';
      final historicalDepositAt = DateTime.utc(2026, 7, 12, 8, 30);
      final originalCreatedAt = DateTime.utc(2026, 6, 1, 9);
      final database = AppDatabase();
      String encoded(String value) =>
          base64Url.encode(utf8.encode(value)).replaceAll('=', '');
      final scopeKey = 'v2:scope:${encoded(scope)}';
      database.upsertRecord(
        LocalTableName.knowledgeLibraryMemberships,
        '$scopeKey:membership:${encoded(contentId)}:${encoded('deposits')}',
        <String, Object?>{
          'user_scope': scope,
          'content_id': contentId,
          'collection': 'deposits',
          'created_at': originalCreatedAt.toIso8601String(),
        },
      );
      database.upsertRecord(
        LocalTableName.depositRecords,
        '$scopeKey:deposit:${encoded(contentId)}',
        <String, Object?>{
          'user_scope': scope,
          'content_id': contentId,
          'folder_id': null,
          'deposited_at': historicalDepositAt.toIso8601String(),
          'updated_at': historicalDepositAt.toIso8601String(),
        },
      );
      final repository = V3DepositRepository(
        dao: V3DepositDao(database),
        userScope: scope,
      );
      List<V3FeedItem> notes() => <V3FeedItem>[
        V3FeedItem(
          id: contentId,
          title: '历史个人笔记',
          source: V3MaterialSource.note,
          createdAt: originalCreatedAt,
          rawBody: '正文',
        ),
      ];

      final first = KnowledgeLibraryController(
        depositRepository: repository,
        initialNotes: notes(),
      );
      expect(first.isDeposited(contentId), isTrue);
      expect(first.growthLedgerEntries, hasLength(1));
      expect(
        first.growthLedgerEntries.single.firstDepositedAt,
        historicalDepositAt,
      );
      expect(repository.loadGrowthLedger(), hasLength(1));

      final second = KnowledgeLibraryController(
        depositRepository: repository,
        initialNotes: notes(),
      );
      expect(second.growthLedgerEntries, hasLength(1));
      expect(
        second.growthLedgerEntries.single.firstDepositedAt,
        historicalDepositAt,
      );
      expect(repository.loadGrowthLedger(), hasLength(1));
    },
  );

  test(
    'failed automatic deposit leaves controller metadata untouched',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'deposit-create-failure-',
      );
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final store = _ToggleFailingSnapshotStore(
        file: File('${root.path}/metadata.json'),
      );
      store.failWrites = true;
      final controller = KnowledgeLibraryController(
        depositRepository: V3DepositRepository(
          dao: V3DepositDao(AppDatabase(snapshotStore: store)),
          userScope: 'deposit-create-failure-user',
        ),
        initialNotes: [
          V3FeedItem(
            id: 'deposit-failure-note',
            title: '不会产生半条记录',
            source: V3MaterialSource.note,
            createdAt: DateTime.utc(2026, 7, 19),
            rawBody: '正文',
          ),
        ],
      );
      expect(controller.depositRecords, isEmpty);
      expect(
        controller.memberships.where(
          (membership) =>
              membership.contentId == 'deposit-failure-note' &&
              membership.collection == V3LibraryCollection.deposits,
        ),
        isEmpty,
      );
      expect(
        controller.depositPersistenceErrorCode,
        'AUTO_DEPOSIT_SAVE_FAILED',
      );
    },
  );

  test('asset growth remains unique after deletion', () {
    final createdAt = DateTime.utc(2026, 7, 20, 9);
    final controller = KnowledgeLibraryController(
      initialNotes: [
        V3FeedItem(
          id: 'multi-label-note',
          title: '多标签资产',
          source: V3MaterialSource.note,
          createdAt: createdAt,
          rawBody: '正文',
        ),
      ],
      now: () => createdAt,
    );

    expect(controller.growthLedgerCount, 1);

    expect(controller.deleteNote('multi-label-note'), isNotNull);
    expect(controller.allDepositedNotes, isEmpty);
    expect(controller.growthLedgerCount, 1);
  });

  test('square subscription is independent and updates subscribed results', () {
    final repository = V3DepositRepository(
      dao: V3DepositDao(AppDatabase()),
      userScope: 'square-subscription-user',
    );
    final controller = KnowledgeLibraryController(
      depositRepository: repository,
      initialNotes: [
        V3FeedItem(
          id: 'square-note',
          title: '广场内容',
          source: V3MaterialSource.knowledgeSquare,
          createdAt: DateTime.utc(2026, 7, 19),
          rawBody: '正文',
        ),
      ],
    );

    expect(controller.isSubscribed('square-note'), isFalse);
    expect(controller.subscribeToSquare('square-note'), isTrue);
    expect(controller.isSubscribed('square-note'), isTrue);
    expect(
      controller.filteredNotesFor(V3KnowledgeLibraryTab.subscribed).single.id,
      'square-note',
    );
    expect(controller.unsubscribeFromSquare('square-note'), isTrue);
    expect(controller.isSubscribed('square-note'), isFalse);
    expect(
      controller.filteredNotesFor(V3KnowledgeLibraryTab.subscribed),
      isEmpty,
    );
  });

  test(
    'hotspots stay outside asset graph and read-only deposits stay unclassified',
    () {
      final database = AppDatabase();
      final repository = V3DepositRepository(
        dao: V3DepositDao(database),
        userScope: 'collection-boundary-user',
      );
      final timestamp = DateTime.utc(2026, 7, 18, 13);
      final legacyFolder = V3DepositFolder(
        id: 'legacy-hotspot-folder',
        name: '旧热点目录',
        createdAt: timestamp,
        updatedAt: timestamp,
      );
      repository.saveFolder(legacyFolder);
      repository.saveMembership(
        V3LibraryMembership(
          contentId: 'hotspot-note',
          collection: V3LibraryCollection.deposits,
          createdAt: timestamp,
        ),
      );
      repository.saveDepositRecord(
        V3DepositRecord(
          contentId: 'hotspot-note',
          folderId: legacyFolder.id,
          depositedAt: timestamp,
          updatedAt: timestamp,
        ),
      );
      repository.saveMembership(
        V3LibraryMembership(
          contentId: 'historical-subscription-note',
          collection: V3LibraryCollection.deposits,
          createdAt: timestamp,
        ),
      );
      repository.saveDepositRecord(
        V3DepositRecord(
          contentId: 'historical-subscription-note',
          folderId: legacyFolder.id,
          depositedAt: timestamp,
          updatedAt: timestamp,
        ),
      );
      final controller = KnowledgeLibraryController(
        depositRepository: repository,
        initialNotes: [
          V3FeedItem(
            id: 'hotspot-note',
            title: '热点观察',
            source: V3MaterialSource.hotspot,
            createdAt: timestamp,
            rawBody: '热点正文',
          ),
          V3FeedItem(
            id: 'subscription-note',
            title: '订阅内容',
            source: V3MaterialSource.subscription,
            createdAt: timestamp,
            rawBody: '订阅正文',
          ),
          V3FeedItem(
            id: 'historical-subscription-note',
            title: '历史订阅内容',
            source: V3MaterialSource.subscription,
            createdAt: timestamp,
            rawBody: '历史正文',
          ),
        ],
        now: () => timestamp,
      );

      expect(
        controller.graphNotes.map((note) => note.id),
        isNot(contains('hotspot-note')),
      );
      expect(
        controller.graphNotes.map((note) => note.id),
        isNot(contains('historical-subscription-note')),
      );
      expect(controller.isDeposited('hotspot-note'), isFalse);
      expect(controller.depositRecordFor('hotspot-note'), isNull);
      expect(
        repository.loadMemberships().where(
          (membership) => membership.contentId == 'hotspot-note',
        ),
        isEmpty,
      );
      expect(
        controller.assignToDepositFolder(
          contentId: 'hotspot-note',
          folderId: legacyFolder.id,
        ),
        isFalse,
      );
      expect(
        controller.depositLibraryEntry(
          const V3KnowledgeLibraryEntry(
            id: 'hotspot-entry',
            feedItemId: 'hotspot-note',
            tab: V3KnowledgeLibraryTab.square,
            source: V3MaterialSource.hotspot,
            title: '热点观察',
            summary: '热点摘要',
          ),
        ),
        isNull,
      );

      final rejectedFolderDeposit = controller.depositLibraryEntry(
        const V3KnowledgeLibraryEntry(
          id: 'subscription-entry',
          feedItemId: 'subscription-note',
          tab: V3KnowledgeLibraryTab.subscribed,
          source: V3MaterialSource.subscription,
          title: '订阅内容',
          summary: '订阅摘要',
        ),
        folderId: legacyFolder.id,
        depositedAt: timestamp,
      );
      expect(rejectedFolderDeposit?.copiedFromContentId, 'subscription-note');
      expect(controller.isDeposited('subscription-note'), isFalse);

      final deposited = controller.depositLibraryEntry(
        const V3KnowledgeLibraryEntry(
          id: 'subscription-entry',
          feedItemId: 'subscription-note',
          tab: V3KnowledgeLibraryTab.subscribed,
          source: V3MaterialSource.subscription,
          title: '订阅内容',
          summary: '订阅摘要',
        ),
        depositedAt: timestamp,
      );
      expect(deposited?.id, rejectedFolderDeposit?.id);
      expect(deposited?.copiedFromContentId, 'subscription-note');
      expect(deposited?.ownership, V3NoteOwnership.mine);
      expect(controller.isDeposited('subscription-note'), isFalse);
      expect(controller.isDeposited(deposited!.id), isTrue);
      expect(
        controller.depositRecordFor(deposited.id)?.folderId,
        legacyFolder.id,
      );
      expect(
        controller.assignToDepositFolder(
          contentId: 'subscription-note',
          folderId: legacyFolder.id,
        ),
        isFalse,
      );
      expect(
        controller.depositRecordFor('historical-subscription-note')?.folderId,
        isNull,
      );
      expect(
        controller.assignToDepositFolder(
          contentId: 'historical-subscription-note',
          folderId: legacyFolder.id,
        ),
        isFalse,
      );
    },
  );

  test('imports and transcriptions automatically enter the asset graph', () {
    final library = KnowledgeLibraryController();
    final graph = FeedGraphController(library);

    final imported = library.importDocument(
      pickerRef: 'picked-document://brief-1',
      displayName: '客户访谈.txt',
      rawBody: '客户希望先看到可验证的试点成果。',
      mimeType: 'text/plain',
    );
    expect(library.noteForId(imported.id)?.title, '客户访谈.txt');
    expect(graph.nodes.any((node) => node.id == imported.id), isTrue);
    expect(library.depositContent(imported.id), isNotNull);
    expect(graph.nodes.any((node) => node.id == imported.id), isTrue);

    library.upsertProcessedTranscription(
      id: 'recording-42',
      title: '独白-42',
      rawBody: '把一次客户沟通沉淀成明确判断。',
      outlineBody: '纲要内容',
      sproutBody: '点火内容',
    );
    library.upsertProcessedTranscription(
      id: 'recording-42',
      title: '独白-42',
      rawBody: '更新后的转写正文。',
      outlineBody: '更新后的纲要',
      sproutBody: '更新后的点火',
    );

    expect(
      library.mineNotes.where((note) => note.id == 'recording-42'),
      hasLength(1),
    );
    expect(library.noteForId('recording-42')?.rawBody, '更新后的转写正文。');
    expect(graph.nodes.any((node) => node.id == 'recording-42'), isTrue);
    expect(library.depositContent('recording-42'), isNotNull);
    expect(graph.nodes.any((node) => node.id == 'recording-42'), isTrue);
    graph.dispose();
  });

  test('user-approved transcription edits survive a later server refresh', () {
    final library = KnowledgeLibraryController(initialNotes: const []);

    library.upsertProcessedTranscription(
      id: 'recording-edited',
      title: '独白',
      rawBody: '用户编辑后的内容。',
      preserveUserEdits: true,
    );
    library.upsertProcessedTranscription(
      id: 'recording-edited',
      title: '独白',
      rawBody: '服务端稍后返回的内容。',
    );

    final note = library.noteForId('recording-edited');
    expect(note?.rawBody, '用户编辑后的内容。');
    expect(note?.syncState, NoteSyncState.pending);
    expect(note?.summaryBody, isNull);
    expect(note?.sproutStatus, V3SproutTaskStatus.notStarted);
    expect(note?.sproutTopic, isNull);
  });

  test('manual note edits and deletion clean linked memory references', () {
    final library = KnowledgeLibraryController();
    final target = library.createManualNote(
      title: '链接目标',
      rawBody: '这是一条可被其他笔记关联的内容。',
      createdAt: DateTime(2026, 7, 13, 9),
    );
    final referencing = library.createManualNote(
      title: '',
      rawBody: '# 关联笔记\n\n这里引用另一条内容。',
      createdAt: DateTime(2026, 7, 13, 10),
    );
    library.updateNote(
      referencing.copyWith(
        linkedMaterials: [
          V3LinkedMaterialRef(
            id: target.id,
            source: target.source,
            title: target.title,
          ),
        ],
      ),
    );

    final updated = library.updateManualNote(
      id: referencing.id,
      title: '',
      rawBody: '# 更新后的标题\n\n保留原有的关联。',
    );

    expect(updated?.title, '更新后的标题');
    expect(updated?.linkedMaterials.single.id, target.id);

    final deleted = library.deleteNote(target.id);

    expect(deleted?.id, target.id);
    expect(library.noteForId(target.id), isNull);
    expect(library.noteForId(referencing.id)?.linkedMaterials, isEmpty);
  });

  test('read-only sources cannot be deleted through the shared library', () {
    final library = KnowledgeLibraryController();
    library.updateNote(
      V3FeedItem(
        id: 'subscribed-read-only',
        title: '只读订阅',
        source: V3MaterialSource.subscription,
        createdAt: DateTime(2026, 7, 13),
        rawBody: '订阅来源不应被本地删除。',
      ),
    );

    expect(library.deleteNote('subscribed-read-only'), isNull);
    expect(library.noteForId('subscribed-read-only'), isNotNull);
    expect(
      library.updateManualNote(
        id: 'subscribed-read-only',
        title: '改写标题',
        rawBody: '改写内容',
      ),
      isNull,
    );
  });

  test('source filters compose with query and group imported note types', () {
    final notes = [
      V3FeedItem(
        id: 'meeting',
        title: '客户会议',
        source: V3MaterialSource.meeting,
        createdAt: DateTime(2026, 7, 14),
        rawBody: '复盘沟通',
      ),
      V3FeedItem(
        id: 'document',
        title: '客户文档',
        source: V3MaterialSource.documentImport,
        createdAt: DateTime(2026, 7, 14),
        rawBody: '文档内容',
        topics: const ['关键客户'],
      ),
      V3FeedItem(
        id: 'media',
        title: '现场照片',
        source: V3MaterialSource.mediaImport,
        createdAt: DateTime(2026, 7, 14),
        rawBody: '媒体内容',
      ),
      V3FeedItem(
        id: 'subscription',
        title: '订阅笔记',
        source: V3MaterialSource.subscription,
        createdAt: DateTime(2026, 7, 14),
        rawBody: '订阅内容',
      ),
    ];
    final controller = KnowledgeLibraryController(initialNotes: notes);

    controller.setSourceFilter(KnowledgeSourceFilter.imported);
    expect(
      controller.filteredNotes.map((note) => note.id),
      containsAll(<String>['document', 'media']),
    );
    expect(controller.filteredNotes, hasLength(2));

    controller.setQuery('关键客户');
    expect(controller.filteredNotes.single.id, 'document');

    controller.setQuery('');
    controller.setSourceFilter(KnowledgeSourceFilter.other);
    expect(controller.filteredNotes, isEmpty);

    controller.setTab(V3KnowledgeLibraryTab.subscribed);
    expect(controller.filteredNotes.single.id, 'subscription');
  });

  test('time filters use local updated dates and include custom end day', () {
    final now = DateTime(2026, 7, 15, 12);
    V3FeedItem note(String id, DateTime updatedAt) => V3FeedItem(
      id: id,
      title: id,
      source: V3MaterialSource.note,
      createdAt: updatedAt,
      updatedAt: updatedAt,
      rawBody: '正文',
    );
    final controller = KnowledgeLibraryController(
      now: () => now,
      initialNotes: [
        note('today', DateTime(2026, 7, 15, 23, 59)),
        note('seven-start', DateTime(2026, 7, 9)),
        note('seven-before', DateTime(2026, 7, 8, 23, 59)),
        note('thirty-start', DateTime(2026, 6, 16)),
        note('year-start', DateTime(2026)),
        note('previous-year', DateTime(2025, 12, 31, 23, 59)),
      ],
    );

    controller.setTimeFilter(KnowledgeTimeFilter.today);
    expect(controller.filteredNotes.map((note) => note.id), ['today']);

    controller.setTimeFilter(KnowledgeTimeFilter.last7Days);
    expect(
      controller.filteredNotes.map((note) => note.id),
      containsAll(['today', 'seven-start']),
    );
    expect(
      controller.filteredNotes.map((note) => note.id),
      isNot(contains('seven-before')),
    );

    controller.setTimeFilter(KnowledgeTimeFilter.last30Days);
    expect(
      controller.filteredNotes.map((note) => note.id),
      contains('thirty-start'),
    );
    expect(
      controller.filteredNotes.map((note) => note.id),
      isNot(contains('year-start')),
    );

    controller.setTimeFilter(KnowledgeTimeFilter.thisYear);
    expect(
      controller.filteredNotes.map((note) => note.id),
      contains('year-start'),
    );
    expect(
      controller.filteredNotes.map((note) => note.id),
      isNot(contains('previous-year')),
    );

    controller.setCustomTimeRange(
      KnowledgeDateRange(
        start: DateTime(2026, 7, 8),
        end: DateTime(2026, 7, 9),
      ),
    );
    expect(
      controller.filteredNotes.map((note) => note.id),
      containsAll(['seven-start', 'seven-before']),
    );
    expect(
      controller.filteredNotes.map((note) => note.id),
      isNot(contains('today')),
    );
  });

  test('local revisions protect pending notes from remote refresh', () {
    final controller = KnowledgeLibraryController(
      initialNotes: const [],
      now: () => DateTime(2026, 7, 15, 10),
    );
    final created = controller.createManualNote(title: '本地标题', rawBody: '本地正文');
    expect(created.localRevision, 1);
    expect(created.remoteRevision, isNull);
    expect(created.syncState, NoteSyncState.pending);

    final renamed = controller.renameNote(id: created.id, title: '本地重命名');
    expect(renamed?.localRevision, 2);
    expect(renamed?.syncState, NoteSyncState.pending);

    final edited = controller.updateManualNote(
      id: created.id,
      title: '本地重命名',
      rawBody: '再次编辑',
    );
    expect(edited?.localRevision, 3);

    final mergeResult = controller.mergeRemoteNote(
      V3FeedItem(
        id: created.id,
        title: '远端旧标题',
        source: V3MaterialSource.note,
        createdAt: created.createdAt,
        rawBody: '远端正文',
        remoteRevision: 12,
      ),
    );
    expect(mergeResult.title, '本地重命名');
    expect(controller.noteForId(created.id)?.rawBody, '再次编辑');

    const readOnlyId = 'read-only-rename';
    controller.updateNote(
      V3FeedItem(
        id: readOnlyId,
        title: '订阅标题',
        source: V3MaterialSource.subscription,
        createdAt: DateTime(2026, 7, 15),
        rawBody: '只读',
      ),
    );
    expect(controller.renameNote(id: readOnlyId, title: '不能修改'), isNull);
  });

  test('remote refresh repairs cached Unix epoch note timestamps', () {
    final epoch = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    final serverCreatedAt = DateTime.utc(2026, 8, 17, 8);
    final serverUpdatedAt = DateTime.utc(2026, 8, 17, 8, 1);
    final controller = KnowledgeLibraryController(
      initialNotes: <V3FeedItem>[
        V3FeedItem(
          id: 'cached-note-1',
          title: '旧缓存标题',
          source: V3MaterialSource.note,
          createdAt: epoch,
          updatedAt: epoch,
          rawBody: '旧缓存正文',
          remoteNoteId: 'remote-note-1',
          syncState: NoteSyncState.synced,
        ),
      ],
    );

    final merged = controller.mergeRemoteNote(
      V3FeedItem(
        id: 'remote-note-1',
        title: '服务端标题',
        source: V3MaterialSource.note,
        createdAt: serverCreatedAt,
        updatedAt: serverUpdatedAt,
        rawBody: '服务端正文',
        remoteNoteId: 'remote-note-1',
        syncState: NoteSyncState.synced,
      ),
    );

    expect(merged.createdAt, serverCreatedAt);
    expect(merged.updatedAt, serverUpdatedAt);
    expect(controller.noteForId('cached-note-1')?.createdAt, serverCreatedAt);
  });

  test('manual note drafts preserve organization and related notes', () {
    final library = KnowledgeLibraryController(initialNotes: const []);
    final related = library.createManualNote(
      title: '关联目标',
      rawBody: '目标内容',
      createdAt: DateTime(2026, 7, 14, 9),
    );
    final created = library.createManualNoteDraft(
      V3NoteDraft(
        title: '结构化笔记',
        rawBody: '正文',
        topics: const ['客户', '复盘', '客户'],
        contentLineId: 'line-client',
        contentLineName: '客户经营',
        folderId: 'folder-cases',
        folderName: '客户案例',
        linkedMaterials: [
          V3LinkedMaterialRef(
            id: related.id,
            source: related.source,
            title: related.title,
          ),
        ],
      ),
      createdAt: DateTime(2026, 7, 14, 10),
    );

    expect(created.topics, ['客户', '复盘']);
    expect(created.contentLineName, '客户经营');
    expect(created.folderName, '客户案例');
    expect(created.linkedMaterials.single.id, related.id);

    final updated = library.updateManualNoteDraft(
      id: created.id,
      draft: V3NoteDraft(
        title: '更新标题',
        rawBody: '更新正文',
        topics: const ['结论'],
        linkedMaterials: created.linkedMaterials,
      ),
    );
    expect(updated?.topics, ['结论']);
    expect(updated?.contentLineName, isNull);
    expect(updated?.folderName, isNull);
    expect(updated?.linkedMaterials.single.id, related.id);
    expect(updated?.localRevision, created.localRevision + 1);
    expect(updated?.syncState, NoteSyncState.pending);

    final unchanged = library.updateManualNoteDraft(
      id: created.id,
      draft: V3NoteDraft(
        title: '更新标题',
        rawBody: '更新正文',
        topics: const ['结论'],
        linkedMaterials: created.linkedMaterials,
      ),
    );
    expect(unchanged?.localRevision, updated?.localRevision);
  });

  test('atomic JSON cache restores updates and persisted deletion', () async {
    final directory = await Directory.systemTemp.createTemp('knowledge-cache');
    addTearDown(() => directory.delete(recursive: true));
    final cache = ApplicationSupportKnowledgeLibraryCache(
      directoryResolver: () async => directory,
    );
    final first = KnowledgeLibraryController(
      initialNotes: const [],
      cache: cache,
    );
    final saved = first.createManualNoteDraft(
      V3NoteDraft(
        title: '磁盘笔记',
        rawBody: '# 可恢复正文',
        topics: const ['持久化'],
        contentLineId: 'line-1',
        contentLineName: '长期内容',
      ),
      createdAt: DateTime(2026, 7, 14, 11),
    );
    await first.flushPersistence();

    final target = File('${directory.path}/knowledge_library/notes.v3.json');
    expect(await target.exists(), isTrue);
    expect(await File('${target.path}.part').exists(), isFalse);

    final second = KnowledgeLibraryController(
      initialNotes: const [],
      cache: cache,
    );
    await second.restore();
    expect(second.noteForId(saved.id)?.rawBody, '# 可恢复正文');
    expect(second.noteForId(saved.id)?.topics, ['持久化']);
    expect(second.noteForId(saved.id)?.contentLineName, '长期内容');

    expect(second.deleteNote(saved.id), isNotNull);
    await second.flushPersistence();
    final third = KnowledgeLibraryController(
      initialNotes: const [],
      cache: cache,
    );
    await third.restore();
    expect(third.noteForId(saved.id), isNull);
  });

  test('JSON cache restores File-Agent retry lifecycle states', () async {
    final directory = await Directory.systemTemp.createTemp(
      'knowledge-derived-retry-cache',
    );
    addTearDown(() => directory.delete(recursive: true));
    final cache = ApplicationSupportKnowledgeLibraryCache(
      directoryResolver: () async => directory,
    );
    final statuses = <String>['retry_wait', 'retry_admitting'];
    final notes = <V3FeedItem>[
      for (var index = 0; index < statuses.length; index += 1)
        V3FeedItem(
          id: 'retry-cache-note-$index',
          title: '重试中的资产 $index',
          source: V3MaterialSource.note,
          createdAt: DateTime.utc(2026, 9, 15, 11, index),
          rawBody: '已保存的原始内容',
          activeDerivedTasks: <V3ActiveDerivedTask>[
            V3ActiveDerivedTask(
              fileAgentRunId: 'retry-cache-file-run-$index',
              agentRunId: 'retry-cache-agent-run-$index',
              stage: V3DerivedTaskStage.outline,
              status: statuses[index],
            ),
          ],
          activeDerivedTasksAuthoritative: true,
        ),
    ];

    await cache.save(notes);
    final restored = await ApplicationSupportKnowledgeLibraryCache(
      directoryResolver: () async => directory,
    ).load();

    expect(restored, hasLength(2));
    expect(
      restored!
          .map((note) => note.activeDerivedTasks.single.status)
          .toList(growable: false),
      statuses,
    );
  });

  test(
    'JSON cache binds and preserves the Workspace projection cursor',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'knowledge-workspace-cursor',
      );
      addTearDown(() => directory.delete(recursive: true));
      final note = V3FeedItem(
        id: 'workspace-cached-note',
        title: 'Workspace 缓存',
        source: V3MaterialSource.note,
        createdAt: DateTime.utc(2026, 8, 15),
        rawBody: '缓存正文',
      );
      final first = ApplicationSupportKnowledgeLibraryCache(
        directoryResolver: () async => directory,
      );
      await first.saveWorkspaceProjection(<V3FeedItem>[
        note,
      ], contentCursor: '42');

      final second = ApplicationSupportKnowledgeLibraryCache(
        directoryResolver: () async => directory,
      );
      expect((await second.load())?.single.title, 'Workspace 缓存');
      expect(second.workspaceContentCursor, '42');
      await second.save(<V3FeedItem>[note.copyWith(title: '普通缓存写入')]);

      final third = ApplicationSupportKnowledgeLibraryCache(
        directoryResolver: () async => directory,
      );
      expect((await third.load())?.single.title, '普通缓存写入');
      expect(third.workspaceContentCursor, '42');
    },
  );

  test(
    'default restore fills missing graph fixtures without overwriting cache',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'knowledge-graph-fixtures',
      );
      addTearDown(() => directory.delete(recursive: true));
      final cache = ApplicationSupportKnowledgeLibraryCache(
        directoryResolver: () async => directory,
      );
      final cachedSeed = v3KnowledgeNotes.first.copyWith(
        title: '缓存中已编辑的标题',
        rawBody: '缓存版本必须优先。',
        localRevision: 3,
        syncState: NoteSyncState.pending,
      );
      final userNote = V3FeedItem(
        id: 'user-created-before-showcase',
        title: '用户已有笔记',
        source: V3MaterialSource.note,
        createdAt: DateTime(2026, 6, 1),
        rawBody: '不能被展示数据迁移删除。',
      );
      await cache.save([cachedSeed, userNote]);

      final controller = KnowledgeLibraryController(cache: cache);
      await controller.restore();

      final catalogCount = KnowledgeChannel.values.length * 12;
      expect(
        controller.allNotes,
        hasLength(v3KnowledgeNotes.length + catalogCount + 1),
      );
      expect(controller.graphNotes, isNotEmpty);
      expect(controller.noteForId(cachedSeed.id)?.title, '缓存中已编辑的标题');
      expect(controller.noteForId(cachedSeed.id)?.rawBody, '缓存版本必须优先。');
      expect(controller.noteForId(userNote.id), isNotNull);
      expect(
        v3KnowledgeNotes.every((seed) => controller.noteForId(seed.id) != null),
        isTrue,
      );
      final persisted = await cache.load();
      expect(persisted, hasLength(v3KnowledgeNotes.length + catalogCount + 1));

      final isolated = KnowledgeLibraryController(initialNotes: [userNote]);
      expect(isolated.graphNotes, hasLength(1));
      expect(isolated.depositContent(userNote.id), isNotNull);
      expect(isolated.graphNotes, hasLength(1));
      expect(isolated.noteForId(v3KnowledgeNotes.first.id), isNull);
    },
  );

  test(
    'production fixture gate removes bundled assets from restored cache',
    () async {
      final cache = _MemoryKnowledgeLibraryCache()
        ..notes = <V3FeedItem>[
          v3KnowledgeNotes.first,
          V3FeedItem(
            id: 'knowledge-channel-ai-implementation-001',
            title: '打包频道文章',
            source: V3MaterialSource.knowledgeSquare,
            ownership: V3NoteOwnership.knowledgeSquare,
            createdAt: DateTime(2026, 7, 1),
            rawBody: '不应在生产资产中显示。',
          ),
          V3FeedItem(
            id: 'workspace-hnote-1',
            title: '真实工作区笔记',
            source: V3MaterialSource.note,
            createdAt: DateTime(2026, 8, 8),
            rawBody: '该条目由 Workspace HNote 水合。',
          ),
        ];
      final controller = KnowledgeLibraryController(
        cache: cache,
        includeDemoFixtures: false,
      );
      addTearDown(controller.dispose);

      await controller.restore();

      expect(controller.allNotes.map((note) => note.id), <String>[
        'workspace-hnote-1',
      ]);
      expect(cache.notes?.map((note) => note.id), <String>[
        'workspace-hnote-1',
      ]);
    },
  );

  test(
    'production auto-sync writes a newly created asset to the note port',
    () async {
      final port = _AutoSyncKnowledgeNotePort();
      final controller = KnowledgeLibraryController(
        initialNotes: const <V3FeedItem>[],
        notePort: port,
        autoSyncOwnedChanges: true,
      );
      addTearDown(controller.dispose);

      final created = controller.createManualNote(
        title: '自动同步资产',
        rawBody: '应通过正式 Workspace HNote 写入。',
      );
      final result = await controller.syncNote(created.id);

      expect(result.outcome, KnowledgeNoteSyncOutcome.synced);
      expect(port.requests, hasLength(1));
      expect(port.requests.single.remoteNoteId, isNull);
      expect(controller.noteForId(created.id)?.remoteNoteId, isNotEmpty);
      expect(controller.noteForId(created.id)?.syncState, NoteSyncState.synced);
    },
  );

  test(
    'manual Note sync can wait for an explicit persistence boundary',
    () async {
      final port = _AutoSyncKnowledgeNotePort();
      final controller = KnowledgeLibraryController(
        initialNotes: const <V3FeedItem>[],
        notePort: port,
        autoSyncOwnedChanges: true,
      );
      addTearDown(controller.dispose);

      final staged = controller.createManualNoteDraft(
        V3NoteDraft(title: '待落盘笔记', rawBody: '先本地持久化，再进入同步。'),
        scheduleAutomaticSync: false,
      );
      await Future<void>.delayed(Duration.zero);

      expect(staged.syncState, NoteSyncState.pending);
      expect(port.requests, isEmpty);

      controller.releasePendingNoteToAutomaticSync(staged.id);
      await controller.syncNote(staged.id);

      expect(port.requests, hasLength(1));
      expect(controller.noteForId(staged.id)?.syncState, NoteSyncState.synced);
    },
  );

  test('stable manual Note creation key replays into one asset', () {
    final controller = KnowledgeLibraryController(
      initialNotes: const <V3FeedItem>[],
      autoSyncOwnedChanges: false,
    );
    addTearDown(controller.dispose);

    final first = controller.createManualNoteDraft(
      V3NoteDraft(title: '第一次保存', rawBody: '第一版正文'),
      contentOrigin: V3ContentOrigin.freeCreation,
      creationKey: 'canvas-session-1',
    );
    final replayed = controller.createManualNoteDraft(
      V3NoteDraft(title: '恢复后保存', rawBody: '第二版正文'),
      contentOrigin: V3ContentOrigin.freeCreation,
      creationKey: 'canvas-session-1',
    );

    expect(replayed.id, first.id);
    expect(replayed.localRevision, first.localRevision + 1);
    expect(replayed.rawBody, '第二版正文');
    expect(controller.notes, hasLength(1));
  });

  test(
    'staged create waits for write-ahead before publishing candidate',
    () async {
      final cache = _MemoryKnowledgeLibraryCache();
      final controller = KnowledgeLibraryController(
        cache: cache,
        initialNotes: const <V3FeedItem>[],
        includeDemoFixtures: false,
        autoSyncOwnedChanges: false,
      );
      addTearDown(controller.dispose);
      await controller.restore();
      final saveCallsBefore = cache.saveCalls;
      final entered = Completer<V3FeedItem>();
      final release = Completer<void>();

      final staging = controller.stageManualNoteCreation(
        V3NoteDraft(title: '写前冻结', rawBody: '回执落盘后才能发布。'),
        createdAt: DateTime.utc(2026, 9, 5, 10),
        contentOrigin: V3ContentOrigin.freeCreation,
        creationKey: 'write-ahead-create',
        beforeMutation: (candidate) async {
          entered.complete(candidate);
          await release.future;
        },
      );
      final candidate = await entered.future;

      expect(controller.noteForId(candidate.id), isNull);
      expect(controller.notes, isEmpty);
      expect(cache.saveCalls, saveCallsBefore);

      release.complete();
      final stage = await staging;
      expect(stage.note.id, candidate.id);
      expect(controller.noteForId(candidate.id), same(stage.note));
      expect(cache.saveCalls, saveCallsBefore);
    },
  );

  test('staged update rechecks its base after write-ahead completes', () async {
    final original = _pendingNote(
      id: 'write-ahead-update',
      title: '原始标题',
      body: '原始正文',
      localRevision: 4,
    );
    final cache = _MemoryKnowledgeLibraryCache()
      ..notes = <V3FeedItem>[original];
    final controller = KnowledgeLibraryController(
      cache: cache,
      initialNotes: <V3FeedItem>[original],
      includeDemoFixtures: false,
      autoSyncOwnedChanges: false,
    );
    addTearDown(controller.dispose);
    await controller.restore();
    final frozen = controller.noteForId(original.id)!;

    final stage = await controller.stageManualNoteUpdate(
      id: original.id,
      draft: V3NoteDraft(title: '待保存标题', rawBody: '待保存正文'),
      expectedNote: frozen,
      beforeMutation: (_) async {
        controller.updateManualNoteDraft(
          id: original.id,
          draft: V3NoteDraft(title: '并发标题', rawBody: '并发正文'),
          scheduleAutomaticSync: false,
        );
      },
    );

    expect(stage, isNull);
    expect(controller.noteForId(original.id)?.title, '并发标题');
    expect(controller.noteForId(original.id)?.rawBody, '并发正文');
  });

  test(
    'staged stable creation key never overwrites a different asset',
    () async {
      final cache = _MemoryKnowledgeLibraryCache();
      final controller = KnowledgeLibraryController(
        cache: cache,
        initialNotes: const <V3FeedItem>[],
        includeDemoFixtures: false,
        autoSyncOwnedChanges: false,
      );
      addTearDown(controller.dispose);
      await controller.restore();
      final createdAt = DateTime.utc(2026, 9, 5, 11);
      final original = controller.createManualNoteDraft(
        V3NoteDraft(title: '固定版本', rawBody: '固定正文'),
        createdAt: createdAt,
        contentOrigin: V3ContentOrigin.freeCreation,
        creationKey: 'stable-staged-replay',
        scheduleAutomaticSync: false,
      );
      await controller.flushPersistenceResult();
      final stored = controller.noteForId(original.id)!;

      final exact = await controller.stageManualNoteCreation(
        V3NoteDraft(title: '固定版本', rawBody: '固定正文'),
        createdAt: createdAt,
        contentOrigin: V3ContentOrigin.freeCreation,
        creationKey: 'stable-staged-replay',
      );
      expect(exact.createdNewNote, isFalse);
      expect(exact.note, same(stored));
      expect(await controller.flushPersistenceResult(), isTrue);
      expect(
        controller.finalizeManualNoteStage(
          exact,
          releaseToAutomaticSync: false,
        ),
        isTrue,
      );

      await expectLater(
        controller.stageManualNoteCreation(
          V3NoteDraft(title: '错误覆盖', rawBody: '不能覆盖固定资产'),
          createdAt: createdAt,
          contentOrigin: V3ContentOrigin.freeCreation,
          creationKey: 'stable-staged-replay',
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'MANUAL_NOTE_CREATION_KEY_CONFLICT',
          ),
        ),
      );
      expect(controller.noteForId(original.id), same(stored));
      expect(controller.noteForId(original.id)?.rawBody, '固定正文');
    },
  );

  test('staged create fails closed when cache restore fails', () async {
    final cache = _RetryableLoadKnowledgeLibraryCache(const <V3FeedItem>[]);
    final controller = KnowledgeLibraryController(
      cache: cache,
      initialNotes: const <V3FeedItem>[],
      includeDemoFixtures: false,
    );
    addTearDown(controller.dispose);

    await expectLater(
      controller.stageManualNoteCreation(
        V3NoteDraft(title: '不得创建', rawBody: '缓存恢复失败时不能暂存。'),
        contentOrigin: V3ContentOrigin.freeCreation,
        creationKey: 'restore-failed-create',
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'KNOWLEDGE_LIBRARY_CACHE_LOAD_FAILED',
        ),
      ),
    );

    expect(controller.notes, isEmpty);
    expect(cache.loadCalls, 1);
    expect(cache.saveCalls, 0);
    expect(
      controller.persistenceErrorCode,
      'KNOWLEDGE_LIBRARY_CACHE_LOAD_FAILED',
    );
  });

  test('staged update fails closed when cache restore fails', () async {
    final note = _pendingNote(
      id: 'restore-failed-update',
      title: '原始标题',
      body: '原始正文',
      localRevision: 4,
    );
    final cache = _RetryableLoadKnowledgeLibraryCache(<V3FeedItem>[note]);
    final controller = KnowledgeLibraryController(
      cache: cache,
      initialNotes: <V3FeedItem>[note],
      includeDemoFixtures: false,
    );
    addTearDown(controller.dispose);
    final before = controller.noteForId(note.id)!;

    await expectLater(
      controller.stageManualNoteUpdate(
        id: note.id,
        draft: V3NoteDraft(title: '错误覆盖', rawBody: '不得进入内存。'),
        expectedNote: before,
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'KNOWLEDGE_LIBRARY_CACHE_LOAD_FAILED',
        ),
      ),
    );

    expect(controller.noteForId(note.id), same(before));
    expect(cache.loadCalls, 1);
    expect(cache.saveCalls, 0);
  });

  test('staged update rejects a stale expected Note revision', () async {
    final note = _pendingNote(
      id: 'stale-staged-update',
      title: '当前标题',
      body: '当前正文',
      localRevision: 8,
    );
    final cache = _MemoryKnowledgeLibraryCache()..notes = <V3FeedItem>[note];
    final controller = KnowledgeLibraryController(
      cache: cache,
      initialNotes: <V3FeedItem>[note],
      includeDemoFixtures: false,
    );
    addTearDown(controller.dispose);
    await controller.restore();
    final before = controller.noteForId(note.id)!;

    final stage = await controller.stageManualNoteUpdate(
      id: note.id,
      draft: V3NoteDraft(title: '过期标题', rawBody: '过期正文'),
      expectedNote: before.copyWith(localRevision: before.localRevision - 1),
    );

    expect(stage, isNull);
    expect(controller.noteForId(note.id), same(before));
    expect(controller.noteForId(note.id)?.localRevision, 8);
    expect(cache.saveCalls, 0);
  });

  test(
    'staged update fallback rejects hydrated body at the same local revision',
    () async {
      final entryNote = _pendingNote(
        id: 'hydrated-staged-update',
        title: '确认时标题',
        body: '确认时正文',
        localRevision: 8,
      );
      final hydrated = entryNote.copyWith(title: '恢复后标题', rawBody: '恢复后正文');
      final cache = _GatedLoadKnowledgeLibraryCache(<V3FeedItem>[hydrated]);
      final controller = KnowledgeLibraryController(
        cache: cache,
        initialNotes: <V3FeedItem>[entryNote],
        includeDemoFixtures: false,
      );
      addTearDown(controller.dispose);

      final staging = controller.stageManualNoteUpdate(
        id: entryNote.id,
        draft: V3NoteDraft(title: '用户保存标题', rawBody: '用户保存正文'),
      );
      await cache.loadStarted;
      cache.releaseLoad();
      final stage = await staging;

      expect(stage, isNull);
      expect(controller.noteForId(entryNote.id)?.localRevision, 8);
      expect(controller.noteForId(entryNote.id)?.rawBody, '恢复后正文');
      expect(cache.notes, <V3FeedItem>[hydrated]);
      expect(cache.saveCalls, 0);
    },
  );

  test(
    'staged update rollback restores the exact conflicted asset snapshot',
    () async {
      final local = _pendingNote(
        id: 'canvas-staged-existing',
        title: '保存前标题',
        body: '保存前正文',
        localRevision: 7,
        remoteRevision: 10,
      );
      final remote = _remoteNote(
        id: local.id,
        title: '远端标题',
        body: '远端正文',
        remoteRevision: 11,
      );
      final cache = _FailOnSaveNumberKnowledgeLibraryCache(failOnSave: 2);
      final port = _QueueKnowledgeNotePort(<KnowledgeNotePortResult>[
        KnowledgeNotePortResult.conflict(remote),
      ]);
      final repository = V3DepositRepository(
        dao: V3DepositDao(AppDatabase()),
        userScope: 'canvas-stage-existing',
      );
      final controller = KnowledgeLibraryController(
        initialNotes: <V3FeedItem>[local],
        cache: cache,
        depositRepository: repository,
        notePort: port,
      );
      addTearDown(controller.dispose);
      await controller.restore();

      expect(
        (await controller.syncNote(local.id)).outcome,
        KnowledgeNoteSyncOutcome.conflict,
      );
      expect(await controller.flushPersistenceResult(), isTrue);
      final before = controller.noteForId(local.id)!;
      final conflictBefore = controller.conflictFor(local.id)!;
      final syncErrorBefore = controller.syncErrorFor(local.id);
      final membershipBefore = controller.memberships
          .where((value) => value.contentId == local.id)
          .single;
      final depositBefore = controller.depositRecords
          .where((value) => value.contentId == local.id)
          .single;
      final growthBefore = controller.growthLedgerEntries
          .where((value) => value.contentId == local.id)
          .single;

      final stage = (await controller.stageManualNoteUpdate(
        id: local.id,
        draft: V3NoteDraft(title: '暂存标题', rawBody: '尚未落盘的正文'),
      ))!;

      expect(stage.createdNewNote, isFalse);
      expect(stage.note.localRevision, before.localRevision + 1);
      expect(stage.note.syncState, NoteSyncState.pending);
      expect(controller.conflictFor(local.id), same(conflictBefore));
      expect(controller.syncErrorFor(local.id), syncErrorBefore);
      expect(
        controller.finalizeManualNoteStage(
          stage,
          releaseToAutomaticSync: false,
        ),
        isFalse,
      );
      expect(await controller.flushPersistenceResult(), isFalse);
      expect(await controller.rollbackManualNoteStage(stage), isTrue);

      expect(controller.noteForId(local.id), same(before));
      expect(controller.noteForId(local.id)?.localRevision, 7);
      expect(controller.noteForId(local.id)?.syncState, NoteSyncState.conflict);
      expect(controller.conflictFor(local.id), same(conflictBefore));
      expect(controller.syncErrorFor(local.id), syncErrorBefore);
      expect(
        controller.memberships
            .where((value) => value.contentId == local.id)
            .single,
        same(membershipBefore),
      );
      expect(
        controller.depositRecords
            .where((value) => value.contentId == local.id)
            .single,
        same(depositBefore),
      );
      expect(
        controller.growthLedgerEntries
            .where((value) => value.contentId == local.id)
            .single,
        same(growthBefore),
      );
      expect(repository.loadDepositRecords().single.contentId, local.id);
      expect(repository.loadGrowthLedger().single.contentId, local.id);
      expect(port.requests, hasLength(1));

      final committed = (await controller.stageManualNoteUpdate(
        id: local.id,
        draft: V3NoteDraft(title: '最终标题', rawBody: '最终正文'),
      ))!;
      expect(await controller.flushPersistenceResult(), isTrue);
      expect(controller.conflictFor(local.id), same(conflictBefore));
      expect(
        controller.finalizeManualNoteStage(
          committed,
          releaseToAutomaticSync: false,
        ),
        isTrue,
      );
      expect(controller.noteForId(local.id), same(committed.note));
      expect(controller.conflictFor(local.id), isNull);
      expect(controller.syncErrorFor(local.id), isNull);
    },
  );

  test(
    'staged create rollback leaves no asset deposit or sync mutation',
    () async {
      final cache = _FailOnSaveNumberKnowledgeLibraryCache(failOnSave: 1);
      final port = _AutoSyncKnowledgeNotePort();
      final repository = V3DepositRepository(
        dao: V3DepositDao(AppDatabase()),
        userScope: 'canvas-stage-create',
      );
      final controller = KnowledgeLibraryController(
        initialNotes: const <V3FeedItem>[],
        cache: cache,
        depositRepository: repository,
        notePort: port,
        autoSyncOwnedChanges: true,
      );
      addTearDown(controller.dispose);
      await controller.restore();

      final stage = await controller.stageManualNoteCreation(
        V3NoteDraft(title: '未提交的新稿', rawBody: '仅在暂存区的正文'),
        contentOrigin: V3ContentOrigin.freeCreation,
        creationKey: 'canvas-stage-create-session',
      );

      expect(stage.createdNewNote, isTrue);
      expect(controller.noteForId(stage.note.id), same(stage.note));
      expect(controller.memberships, isEmpty);
      expect(controller.depositRecords, isEmpty);
      expect(controller.growthLedgerEntries, isEmpty);
      expect(repository.loadMemberships(), isEmpty);
      expect(repository.loadDepositRecords(), isEmpty);
      expect(repository.loadGrowthLedger(), isEmpty);
      expect(port.requests, isEmpty);

      expect(await controller.flushPersistenceResult(), isFalse);
      expect(await controller.rollbackManualNoteStage(stage), isTrue);

      expect(controller.noteForId(stage.note.id), isNull);
      expect(controller.notes, isEmpty);
      expect(cache.notes, isEmpty);
      expect(controller.memberships, isEmpty);
      expect(controller.depositRecords, isEmpty);
      expect(controller.growthLedgerEntries, isEmpty);
      expect(repository.loadMemberships(), isEmpty);
      expect(repository.loadDepositRecords(), isEmpty);
      expect(repository.loadGrowthLedger(), isEmpty);
      expect(controller.trashEntries, isEmpty);
      expect(port.requests, isEmpty);
    },
  );

  test(
    'failed rollback persistence releases the stage for a later full save',
    () async {
      final cache = _FailOnSaveNumberKnowledgeLibraryCache.onSaves(const <int>{
        1,
        2,
      });
      final controller = KnowledgeLibraryController(
        initialNotes: const <V3FeedItem>[],
        cache: cache,
      );
      addTearDown(controller.dispose);
      await controller.restore();

      final failedStage = await controller.stageManualNoteCreation(
        V3NoteDraft(title: '第一次暂存', rawBody: '两次缓存写入都会失败。'),
        contentOrigin: V3ContentOrigin.freeCreation,
        creationKey: 'canvas-rollback-cache-recovery',
      );

      expect(await controller.flushPersistenceResult(), isFalse);
      expect(await controller.rollbackManualNoteStage(failedStage), isFalse);
      expect(controller.notes, isEmpty);
      expect(cache.notes, isNull);

      final recoveredStage = await controller.stageManualNoteCreation(
        V3NoteDraft(title: '恢复后保存', rawBody: '完整快照可以重新落盘。'),
        contentOrigin: V3ContentOrigin.freeCreation,
        creationKey: 'canvas-rollback-cache-recovery',
      );
      expect(recoveredStage.note.id, failedStage.note.id);
      expect(await controller.flushPersistenceResult(), isTrue);
      expect(
        controller.finalizeManualNoteStage(
          recoveredStage,
          releaseToAutomaticSync: false,
        ),
        isTrue,
      );
      expect(controller.notes, <V3FeedItem>[recoveredStage.note]);
      expect(cache.notes, <V3FeedItem>[recoveredStage.note]);
    },
  );

  test(
    'durable Note upsert survives offline restart with one mutation identity',
    () async {
      final root = await Directory.systemTemp.createTemp('knowledge-outbox-');
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final file = File('${root.path}/knowledge.sqlite');
      var now = DateTime.utc(2026, 8, 31, 10);
      final pending = _pendingNote(
        id: 'outbox-restart-note',
        title: '离线后恢复',
        body: '正文已经先保存到本地。',
        localRevision: 4,
      );
      final remote = pending.copyWith(
        remoteNoteId: 'remote-outbox-restart-note',
        noteRevisionId: 'note-revision-4',
        rawPartRevisionId: 'raw-revision-4',
        etag: '"note-4"',
        contentCursor: '44',
        remoteRevision: 4,
        syncState: NoteSyncState.synced,
      );
      final port = _QueueKnowledgeNotePort(<KnowledgeNotePortResult>[
        const KnowledgeNotePortResult.unavailable('NETWORK_UNAVAILABLE'),
        KnowledgeNotePortResult.success(remote),
      ]);
      final cache = _MemoryKnowledgeLibraryCache()
        ..notes = <V3FeedItem>[pending];
      final firstWorker = await DatabaseWorker.start(file: file);
      final first = KnowledgeLibraryController(
        initialNotes: const <V3FeedItem>[],
        includeDemoFixtures: false,
        cache: cache,
        notePort: port,
        noteSyncJournal: DatabaseKnowledgeNoteSyncJournal(
          database: firstWorker,
          userScope: 'user:alpha',
          workspaceId: 'workspace-1',
          now: () => now,
        ),
      );
      await first.restore();

      final offline = await first.syncNote(pending.id);

      expect(offline.outcome, KnowledgeNoteSyncOutcome.unavailable);
      expect(port.requests, hasLength(1));
      expect(port.requests.single.mutationIdentity, isNotEmpty);
      first.dispose();
      await firstWorker.dispose();

      now = now.add(const Duration(minutes: 1));
      final secondWorker = await DatabaseWorker.start(file: file);
      addTearDown(() async {
        if (!secondWorker.isDisposed) await secondWorker.dispose();
      });
      final journal = DatabaseKnowledgeNoteSyncJournal(
        database: secondWorker,
        userScope: 'user:alpha',
        workspaceId: 'workspace-1',
        now: () => now,
      );
      final restored = KnowledgeLibraryController(
        initialNotes: const <V3FeedItem>[],
        includeDemoFixtures: false,
        cache: cache,
        notePort: port,
        noteSyncJournal: journal,
      );
      addTearDown(restored.dispose);

      await restored.initialize();

      expect(port.requests, hasLength(2));
      expect(
        port.requests.last.mutationIdentity,
        port.requests.first.mutationIdentity,
      );
      expect(restored.noteForId(pending.id)?.syncState, NoteSyncState.synced);
      expect(await journal.claim(limit: 100), isEmpty);
    },
  );

  test('durable tombstone retries the original backend key', () async {
    final root = await Directory.systemTemp.createTemp(
      'knowledge-delete-outbox-',
    );
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final worker = await DatabaseWorker.start(
      file: File('${root.path}/knowledge.sqlite'),
    );
    addTearDown(() async {
      if (!worker.isDisposed) await worker.dispose();
    });
    var now = DateTime.utc(2026, 8, 31, 11);
    final note = _workspaceLifecycleNote(
      id: 'outbox-delete-local',
      remoteNoteId: 'outbox-delete-remote',
    );
    final cache = _MemoryKnowledgeLibraryCache()..notes = <V3FeedItem>[note];
    final lifecycle = _FakeLifecycleKnowledgeNotePort(failFirstTombstone: true);
    final journal = DatabaseKnowledgeNoteSyncJournal(
      database: worker,
      userScope: 'user:alpha',
      workspaceId: 'workspace-1',
      now: () => now,
    );
    final controller = KnowledgeLibraryController(
      initialNotes: const <V3FeedItem>[],
      includeDemoFixtures: false,
      cache: cache,
      trashRepository: _MemoryTrashRepository(),
      workspaceFolderPort: _FakeWorkspaceFolderPort(),
      notePort: lifecycle,
      noteSyncJournal: journal,
    );
    addTearDown(controller.dispose);
    await controller.restore();

    final offline = await controller.deleteNoteDurably(note.id);

    expect(offline.outcome, KnowledgeNoteDeleteOutcome.persistenceFailed);
    expect(controller.noteForId(note.id), isNotNull);
    now = now.add(const Duration(minutes: 1));

    await controller.synchronizeWorkspaceContent();

    expect(controller.noteForId(note.id), isNull);
    expect(lifecycle.tombstoneKeys, hasLength(2));
    expect(lifecycle.tombstoneKeys.first, lifecycle.tombstoneKeys.last);
    expect(await journal.claim(limit: 100), isEmpty);
  });

  test(
    'stale pending snapshot cannot discard a successful exact HNote binding',
    () async {
      final port = _AutoSyncKnowledgeNotePort();
      final pending = V3FeedItem(
        id: 'stale-binding-asset',
        title: '同步中的资产',
        source: V3MaterialSource.note,
        createdAt: DateTime.utc(2026, 8, 12),
        rawBody: '自动同步完成后，旧详情快照不能清空绑定。',
        localRevision: 1,
        syncState: NoteSyncState.pending,
      );
      final controller = KnowledgeLibraryController(
        initialNotes: <V3FeedItem>[pending],
        notePort: port,
        autoSyncOwnedChanges: false,
      );
      addTearDown(controller.dispose);
      final staleDetailSnapshot = controller.noteForId(pending.id)!;

      final result = await controller.syncNote(pending.id);
      expect(result.outcome, KnowledgeNoteSyncOutcome.synced);
      expect(controller.noteForId(pending.id)?.syncState, NoteSyncState.synced);

      controller.updateNote(staleDetailSnapshot);

      final retained = controller.noteForId(pending.id);
      expect(retained?.syncState, NoteSyncState.synced);
      expect(retained?.remoteNoteId, 'remote-${pending.id}');
      expect(retained?.noteRevisionId, 'note-revision-1');
      expect(retained?.rawPartRevisionId, 'raw-revision-1');
      expect(retained?.etag, '"note-1"');
      expect(retained?.contentCursor, '1');
    },
  );

  test(
    'HNote hydration leaves an unbound pending asset for explicit sync',
    () async {
      final port = _AutoSyncKnowledgeNotePort();
      final pending = V3FeedItem(
        id: 'pending-asset',
        title: '待同步资产',
        source: V3MaterialSource.note,
        createdAt: DateTime(2026, 8, 8),
        rawBody: '首次写入未完成时应在 Workspace 水合后重试。',
        localRevision: 1,
        syncState: NoteSyncState.pending,
      );
      final controller = KnowledgeLibraryController(
        initialNotes: <V3FeedItem>[pending],
        notePort: port,
        autoSyncOwnedChanges: true,
      );
      addTearDown(controller.dispose);

      await controller.initialize();

      expect(port.requests, isEmpty);
      expect(
        controller.noteForId(pending.id)?.syncState,
        NoteSyncState.pending,
      );

      final result = await controller.syncNote(pending.id);

      expect(result.outcome, KnowledgeNoteSyncOutcome.synced);
      expect(port.requests, hasLength(1));
      expect(controller.noteForId(pending.id)?.remoteNoteId, isNotEmpty);
    },
  );

  test(
    'version 1 cache loads as pending and the next write uses version 3',
    () async {
      final directory = await Directory.systemTemp.createTemp('knowledge-v1');
      addTearDown(() => directory.delete(recursive: true));
      final legacy = File('${directory.path}/knowledge_library/notes.v1.json');
      await legacy.parent.create(recursive: true);
      await legacy.writeAsString(
        jsonEncode({
          'version': 1,
          'notes': [
            {
              'id': 'legacy-note',
              'title': '旧缓存笔记',
              'source': 'note',
              'createdAt': '2026-07-01T01:00:00.000Z',
              'updatedAt': '2026-07-02T01:00:00.000Z',
              'rawBody': '旧正文',
            },
          ],
        }),
        flush: true,
      );
      final controller = KnowledgeLibraryController(
        initialNotes: const [],
        cache: ApplicationSupportKnowledgeLibraryCache(
          directoryResolver: () async => directory,
        ),
      );

      await controller.restore();
      final restored = controller.noteForId('legacy-note');
      expect(restored?.localRevision, 0);
      expect(restored?.remoteRevision, isNull);
      expect(restored?.syncState, NoteSyncState.pending);

      controller.renameNote(id: 'legacy-note', title: '迁移后的标题');
      await controller.flushPersistence();
      final v3 = File('${directory.path}/knowledge_library/notes.v3.json');
      expect(await v3.exists(), isTrue);
      final root = jsonDecode(await v3.readAsString()) as Map<String, dynamic>;
      expect(root['version'], 3);
      final note = (root['notes'] as List).single as Map<String, dynamic>;
      expect(note['localRevision'], 1);
      expect(note['syncState'], 'pending');
    },
  );

  test('atomic JSON cache isolates account and Workspace scopes', () async {
    final directory = await Directory.systemTemp.createTemp('knowledge-scopes');
    addTearDown(() => directory.delete(recursive: true));
    KnowledgeLibraryController controllerFor(String scope) {
      return KnowledgeLibraryController(
        initialNotes: const [],
        cache: ApplicationSupportKnowledgeLibraryCache(
          scopeId: scope,
          directoryResolver: () async => directory,
        ),
      );
    }

    const firstScope = 'user-a\u0000workspace-1';
    const otherScopes = <String>[
      'user-a\u0000workspace-2',
      'user-b\u0000workspace-1',
      'user-b\u0000workspace-2',
    ];
    final first = controllerFor(firstScope);
    final firstNote = first.createManualNote(
      title: '账号 A 笔记',
      rawBody: '仅账号 A 可见',
    );
    await first.flushPersistence();

    for (final scope in otherScopes) {
      final isolated = controllerFor(scope);
      await isolated.restore();
      expect(isolated.noteForId(firstNote.id), isNull, reason: scope);
      isolated.createManualNote(title: scope, rawBody: '仅当前私有作用域可见');
      await isolated.flushPersistence();
    }

    final cacheFiles = await Directory(
      '${directory.path}/knowledge_library',
    ).list().where((entry) => entry.path.endsWith('.json')).toList();
    expect(cacheFiles, hasLength(4));
    final restoredFirst = controllerFor(firstScope);
    await restoredFirst.restore();
    expect(restoredFirst.noteForId(firstNote.id)?.title, '账号 A 笔记');
    expect(restoredFirst.notes, hasLength(1));
  });

  test('malformed cache retains the current seed', () async {
    final directory = await Directory.systemTemp.createTemp('knowledge-broken');
    addTearDown(() => directory.delete(recursive: true));
    final target = File('${directory.path}/knowledge_library/notes.v1.json');
    await target.parent.create(recursive: true);
    await target.writeAsString('{not-json', flush: true);
    final seed = V3FeedItem(
      id: 'seed',
      title: '保留种子',
      source: V3MaterialSource.note,
      createdAt: DateTime(2026, 7, 14),
      rawBody: '正文',
    );
    final controller = KnowledgeLibraryController(
      initialNotes: [seed],
      cache: ApplicationSupportKnowledgeLibraryCache(
        directoryResolver: () async => directory,
      ),
    );

    await controller.restore();

    expect(controller.noteForId('seed'), isNotNull);
    expect(
      controller.persistenceErrorCode,
      'KNOWLEDGE_LIBRARY_CACHE_LOAD_FAILED',
    );
  });

  test('formal HNote binding round-trips through the local cache', () async {
    final directory = await Directory.systemTemp.createTemp(
      'knowledge-hnote-binding',
    );
    addTearDown(() => directory.delete(recursive: true));
    final cache = ApplicationSupportKnowledgeLibraryCache(
      directoryResolver: () async => directory,
    );
    final note =
        _pendingNote(
          id: 'local-bound-note',
          title: '绑定笔记',
          body: '本地正文',
          remoteRevision: 7,
        ).copyWith(
          remoteNoteId: 'note-remote-1',
          noteRevisionId: 'note-revision-7',
          rawPartRevisionId: 'raw-revision-7',
          etag: '"note-7"',
          contentCursor: '184',
          recordingId: 'recording-cache-1',
          minutesStatus: 'succeeded',
          summaryStatus: 'running',
        );

    await cache.save(<V3FeedItem>[note]);
    final restored = (await cache.load())!.single;

    expect(restored.id, 'local-bound-note');
    expect(restored.remoteRevision, 7);
    expect(restored.remoteNoteId, 'note-remote-1');
    expect(restored.noteRevisionId, 'note-revision-7');
    expect(restored.rawPartRevisionId, 'raw-revision-7');
    expect(restored.etag, '"note-7"');
    expect(restored.contentCursor, '184');
    expect(restored.recordingId, 'recording-cache-1');
    expect(restored.minutesStatus, 'succeeded');
    expect(restored.summaryStatus, 'running');
    expect(restored.usesBackendRecordingOutline, isTrue);
  });

  test('cache ignores legacy transient derived failures', () async {
    final directory = await Directory.systemTemp.createTemp(
      'knowledge-transient-derived-state',
    );
    addTearDown(() => directory.delete(recursive: true));
    final cache = ApplicationSupportKnowledgeLibraryCache(
      directoryResolver: () async => directory,
    );
    final note = _pendingNote(
      id: 'legacy-derived-failure',
      title: '旧失败资产',
      body: '已同步的原始内容',
    );
    await cache.save(<V3FeedItem>[note]);

    final file = File('${directory.path}/knowledge_library/notes.v3.json');
    final root = Map<String, Object?>.from(
      jsonDecode(await file.readAsString()) as Map,
    );
    final encodedNote =
        Map<String, Object?>.from((root['notes']! as List).single as Map)
          ..['summaryError'] = 'OUTLINE_RUN_POLL_TIMEOUT'
          ..['sproutStatus'] = V3SproutTaskStatus.failed.name
          ..['sproutError'] = 'FAYA_RUN_POLL_TIMEOUT';
    root['notes'] = <Object?>[encodedNote];
    await file.writeAsString(jsonEncode(root), flush: true);

    final restored = (await cache.load())!.single;

    expect(restored.summaryError, isNull);
    expect(restored.sproutStatus, V3SproutTaskStatus.notStarted);
    expect(restored.sproutError, isNull);
  });

  test(
    'remote HNote tombstone reads the exact deleted revision for restore',
    () async {
      const remoteNoteId = 'note-lifecycle-remote';
      final transport = _KnowledgeQueueTransport(<ApiTransportResponse>[
        const ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'data': <String, Object?>{
              'eventId': 'event-tombstone',
              'workspaceId': 'workspace-1',
              'cursor': '121',
              'operationId': 'operation-tombstone',
              'occurredAt': '2026-08-15T10:00:00Z',
              'objectKind': 'hnote',
              'objectId': 'note-lifecycle-remote',
              'changeType': 'tombstoned',
              'revisionId': 'note-revision-tombstone',
              'previousRevisionId': 'note-revision-old',
              'tombstone': true,
              'resourcePinDelta': <String, Object?>{
                'added': <Object?>[],
                'released': <Object?>[],
              },
            },
          },
        ),
        ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'data': _hNoteJson(
              noteId: remoteNoteId,
              title: '待删除笔记',
              raw: '正文',
              revision: 'tombstone',
              cursor: '121',
              state: 'tombstoned',
            ),
          },
        ),
      ]);
      final port = RemoteKnowledgeNotePort(
        apiClient: _knowledgeApiClient(transport),
        workspaceId: () => 'workspace-1',
      );
      final note =
          _pendingNote(
            id: 'local-lifecycle-note',
            title: '待删除笔记',
            body: '正文',
          ).copyWith(
            remoteNoteId: remoteNoteId,
            noteRevisionId: 'note-revision-old',
            rawPartRevisionId: 'raw-revision-old',
            etag: '"note-old"',
            contentCursor: '120',
            syncState: NoteSyncState.synced,
          );

      final result = await port.tombstoneNote(
        note: note,
        idempotencyKey: 'idem-hnote-tombstone',
      );

      expect(result.isSuccess, isTrue);
      expect(result.noteRevisionId, 'note-revision-tombstone');
      expect(result.rawPartRevisionId, 'raw-revision-tombstone');
      expect(result.etag, '"note-tombstone"');
      expect(result.contentCursor, '121');
      expect(transport.requests.map((request) => request.method), <String>[
        'DELETE',
        'GET',
      ]);
      expect(transport.requests.first.headers['If-Match'], '"note-old"');
      expect(
        transport.requests.first.headers['X-Idempotency-Key'],
        'idem-hnote-tombstone',
      );
      expect(
        transport.requests.last.url.queryParameters['revisionId'],
        'note-revision-tombstone',
      );
    },
  );

  test('deployed manual Note create binds the server raw revision', () async {
    final transport = _KnowledgeQueueTransport(<ApiTransportResponse>[
      ApiTransportResponse(
        status: 202,
        body: <String, Object?>{
          'success': true,
          'data': <String, Object?>{
            'note': _deployedNoteJson(
              noteId: 'note-remote-created',
              title: '本地新笔记',
              metadataVersion: 2,
            ),
            'partRevision': <String, Object?>{
              'partRevisionId': 'raw-revision-2',
            },
          },
        },
      ),
      _deployedNoteDetailResponse(
        _deployedNoteJson(
          noteId: 'note-remote-created',
          title: '本地新笔记',
          metadataVersion: 2,
        ),
        etag: '"note-note-remote-created-v2"',
      ),
      _deployedRawPartResponse(
        noteId: 'note-remote-created',
        raw: '同步正文',
        partRevisionId: 'raw-revision-2',
        etag: '"note-part-note-remote-created-raw-v2"',
      ),
    ]);
    final local = _pendingNote(
      id: 'local-created-note',
      title: '本地新笔记',
      body: '同步正文',
      localRevision: 3,
      folderId: 'local-deposit-folder',
    );
    final controller = KnowledgeLibraryController(
      initialNotes: <V3FeedItem>[local],
      notePort: RemoteKnowledgeNotePort(
        apiClient: _knowledgeApiClient(transport),
        workspaceId: () => 'workspace-1',
      ),
    );

    final result = await controller.syncNote(local.id);

    expect(result.outcome, KnowledgeNoteSyncOutcome.synced);
    final synced = controller.noteForId(local.id)!;
    expect(synced.id, local.id);
    expect(synced.remoteNoteId, 'note-remote-created');
    expect(synced.noteRevisionId, 'raw-revision-2');
    expect(synced.rawPartRevisionId, 'raw-revision-2');
    expect(synced.etag, '"note-note-remote-created-v2"');
    expect(transport.requests, hasLength(3));
    expect(transport.requests.first.method, 'POST');
    expect(
      transport.requests.first.url.path,
      '/api/v1/workspaces/workspace-1/notes/manual',
    );
    expect(transport.requests.first.headers['X-Idempotency-Key'], isNotEmpty);
    final createBody = jsonDecode(transport.requests.first.body!) as Map;
    expect(createBody['contentMarkdown'], '同步正文');
    expect(createBody.toString(), isNot(contains('local-deposit-folder')));
    expect(transport.requests[1].url.queryParameters, isEmpty);
    expect(transport.requests.last.url.queryParameters, isEmpty);
  });

  test('manual create accepts a sparse current HNote readback', () async {
    const noteId = 'note-sparse-created';
    final sparseHead = _hNoteHeadJson(
      noteId: noteId,
      title: '自由创作草稿',
      revision: '4',
      cursor: '44',
    );
    final transport = _KnowledgeQueueTransport(<ApiTransportResponse>[
      ApiTransportResponse(
        status: 202,
        body: <String, Object?>{
          'success': true,
          'data': <String, Object?>{'note': sparseHead},
        },
      ),
      ApiTransportResponse(
        status: 200,
        body: <String, Object?>{'success': true, 'data': sparseHead},
      ),
      _hNotePartResponse(
        noteId: noteId,
        part: 'raw',
        markdown: '停顿后同步的正文',
        revision: '4',
      ),
      _hNotePartResponse(
        noteId: noteId,
        part: 'outline',
        markdown: '',
        revision: '4',
      ),
      _hNotePartResponse(
        noteId: noteId,
        part: 'germination',
        markdown: '',
        revision: '4',
      ),
    ]);
    final local = _pendingNote(
      id: 'local-sparse-created',
      title: '自由创作草稿',
      body: '停顿后同步的正文',
      localRevision: 4,
    );
    final controller = KnowledgeLibraryController(
      initialNotes: <V3FeedItem>[local],
      notePort: RemoteKnowledgeNotePort(
        apiClient: _knowledgeApiClient(transport),
        workspaceId: () => 'workspace-1',
      ),
    );

    final result = await controller.syncNote(local.id);

    expect(result.outcome, KnowledgeNoteSyncOutcome.synced);
    final synced = controller.noteForId(local.id)!;
    expect(synced.remoteNoteId, noteId);
    expect(synced.noteRevisionId, 'note-revision-4');
    expect(synced.rawPartRevisionId, 'raw-revision-4');
    expect(synced.contentCursor, '44');
    expect(synced.rawBody, '停顿后同步的正文');
    expect(transport.requests, hasLength(5));
  });

  test('raw-only staging preserves unrelated pending metadata edits', () async {
    final note = _pendingNote(
      id: 'pending-metadata',
      title: '还未同步的新标题',
      body: '已有正文',
      localRevision: 3,
    ).copyWith(remoteNoteId: 'cloud-pending-metadata');
    final controller = KnowledgeLibraryController(initialNotes: [note]);
    addTearDown(controller.dispose);
    final stage = await controller.stageManualNoteUpdate(
      id: note.id,
      draft: V3NoteDraft(title: note.title, rawBody: '新的原文'),
      rawOnly: true,
    );
    expect(stage, isNull);
    expect(controller.noteForId(note.id)?.title, '还未同步的新标题');
    expect(controller.noteForId(note.id)?.rawBody, '已有正文');
    expect(controller.noteForId(note.id)?.pendingRawOnlyUpdate, isFalse);
  });

  test('raw-only history update refuses a newer remote raw revision', () async {
    const noteId = 'note-raw-conflict';
    final head = _hNoteHeadJson(
      noteId: noteId,
      title: '远端标题',
      revision: '5',
      cursor: '45',
    );
    final transport = _KnowledgeQueueTransport(<ApiTransportResponse>[
      for (var snapshot = 0; snapshot < 2; snapshot++) ...[
        ApiTransportResponse(
          status: 200,
          body: <String, Object?>{'success': true, 'data': head},
        ),
        _hNotePartResponse(
          noteId: noteId,
          part: 'raw',
          markdown: '别人更新的正文',
          revision: '5',
        ),
      ],
      _hNotePartResponse(
        noteId: noteId,
        part: 'outline',
        markdown: '远端纲要',
        revision: '5',
      ),
      _hNotePartResponse(
        noteId: noteId,
        part: 'germination',
        markdown: '远端点火',
        revision: '5',
      ),
    ]);
    final local =
        _pendingNote(
          id: 'local-raw-conflict',
          title: '本地旧标题',
          body: '待提交编辑',
          localRevision: 6,
        ).copyWith(
          pendingRawOnlyUpdate: true,
          remoteNoteId: noteId,
          noteRevisionId: 'note-revision-4',
          rawPartRevisionId: 'raw-revision-4',
          etag: '"note-4"',
          contentCursor: '44',
        );
    final controller = KnowledgeLibraryController(
      initialNotes: [local],
      notePort: RemoteKnowledgeNotePort(
        apiClient: _knowledgeApiClient(transport),
        workspaceId: () => 'workspace-1',
      ),
    );
    addTearDown(controller.dispose);
    final result = await controller.syncNote(local.id);
    expect(result.outcome, KnowledgeNoteSyncOutcome.conflict);
    expect(controller.noteForId(local.id)?.rawBody, '待提交编辑');
    expect(controller.noteForId(local.id)?.pendingRawOnlyUpdate, isTrue);
    expect(transport.requests, hasLength(6));
    expect(
      transport.requests.every((request) => request.method == 'GET'),
      isTrue,
    );
  });

  test(
    'raw-only history update preserves remote title and derived parts',
    () async {
      const noteId = 'note-sparse-update';
      final currentHead = _hNoteHeadJson(
        noteId: noteId,
        title: '同一条自由创作',
        revision: '4',
        cursor: '44',
      );
      final updatedHead = _hNoteHeadJson(
        noteId: noteId,
        title: '同一条自由创作',
        revision: '5',
        cursor: '45',
      );
      final transport = _KnowledgeQueueTransport(<ApiTransportResponse>[
        ApiTransportResponse(
          status: 200,
          body: <String, Object?>{'success': true, 'data': currentHead},
        ),
        _hNotePartResponse(
          noteId: noteId,
          part: 'raw',
          markdown: '第一版',
          revision: '4',
        ),
        const ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'data': <String, Object?>{'accepted': true},
          },
        ),
        ApiTransportResponse(
          status: 200,
          body: <String, Object?>{'success': true, 'data': updatedHead},
        ),
        _hNotePartResponse(
          noteId: noteId,
          part: 'raw',
          markdown: '第二版',
          revision: '5',
        ),
        _hNotePartResponse(
          noteId: noteId,
          part: 'outline',
          markdown: '原有纲要',
          revision: '5',
        ),
        _hNotePartResponse(
          noteId: noteId,
          part: 'germination',
          markdown: '原有点火',
          revision: '5',
        ),
      ]);
      final local =
          _pendingNote(
            id: 'local-sparse-update',
            title: '本地旧标题不可覆盖远端',
            body: '第二版',
            localRevision: 5,
          ).copyWith(
            pendingRawOnlyUpdate: true,
            remoteNoteId: noteId,
            noteRevisionId: 'note-revision-4',
            rawPartRevisionId: 'raw-revision-4',
            etag: '"note-4"',
            contentCursor: '44',
          );
      final controller = KnowledgeLibraryController(
        initialNotes: <V3FeedItem>[local],
        notePort: RemoteKnowledgeNotePort(
          apiClient: _knowledgeApiClient(transport),
          workspaceId: () => 'workspace-1',
        ),
      );

      final result = await controller.syncNote(local.id);

      expect(result.outcome, KnowledgeNoteSyncOutcome.synced);
      expect(controller.noteForId(local.id)?.rawBody, '第二版');
      expect(
        controller.noteForId(local.id)?.rawPartRevisionId,
        'raw-revision-5',
      );
      expect(transport.requests[2].method, 'PUT');
      expect(transport.requests[2].headers['If-Match'], '"raw-4"');
      expect(
        transport.requests[2].url.path,
        '/api/v1/workspaces/workspace-1/notes/$noteId/parts/raw',
      );
      expect(jsonDecode(transport.requests[2].body!), <String, Object?>{
        'contentMarkdown': '第二版',
        'basePartRevisionId': 'raw-revision-4',
      });
      expect(transport.requests, hasLength(7));
      expect(
        transport.requests.where((request) => request.method == 'PATCH'),
        isEmpty,
      );
      expect(controller.noteForId(local.id)?.title, '同一条自由创作');
      expect(controller.noteForId(local.id)?.summaryBody, '原有纲要');
      expect(controller.noteForId(local.id)?.pendingRawOnlyUpdate, isFalse);
    },
  );

  test(
    'deployed manual Note create accepts a Note-body metadata ETag',
    () async {
      final transport = _KnowledgeQueueTransport(<ApiTransportResponse>[
        ApiTransportResponse(
          status: 202,
          body: <String, Object?>{
            'success': true,
            'data': <String, Object?>{
              'note': _deployedNoteJson(
                noteId: 'note-body-etag',
                title: '正文 ETag 笔记',
                metadataVersion: 3,
              ),
              'partRevision': <String, Object?>{
                'partRevisionId': 'raw-revision-body-etag',
              },
            },
          },
        ),
        _deployedNoteDetailResponse(
          _deployedNoteJson(
            noteId: 'note-body-etag',
            title: '正文 ETag 笔记',
            metadataVersion: 3,
            etag: '"note-body-etag-v3"',
          ),
        ),
        _deployedRawPartResponse(
          noteId: 'note-body-etag',
          raw: '同步正文',
          partRevisionId: 'raw-revision-body-etag',
          etag: '"note-part-body-etag-v3"',
        ),
      ]);
      final local = _pendingNote(
        id: 'local-body-etag-note',
        title: '正文 ETag 笔记',
        body: '同步正文',
        localRevision: 1,
      );
      final controller = KnowledgeLibraryController(
        initialNotes: <V3FeedItem>[local],
        notePort: RemoteKnowledgeNotePort(
          apiClient: _knowledgeApiClient(transport),
          workspaceId: () => 'workspace-1',
        ),
      );

      final result = await controller.syncNote(local.id);

      expect(result.outcome, KnowledgeNoteSyncOutcome.synced);
      final synced = controller.noteForId(local.id)!;
      expect(synced.remoteNoteId, 'note-body-etag');
      expect(synced.rawPartRevisionId, 'raw-revision-body-etag');
      expect(synced.etag, '"note-body-etag-v3"');
      expect(synced.contentCursor, isNotEmpty);
    },
  );

  test(
    'deployed manual Note 412 reloads a complete conflict snapshot',
    () async {
      final transport = _KnowledgeQueueTransport(<ApiTransportResponse>[
        _deployedNoteDetailResponse(
          _deployedNoteJson(
            noteId: 'note-remote-conflict',
            title: '远端标题',
            metadataVersion: 8,
          ),
          etag: '"note-note-remote-conflict-v8"',
        ),
        _deployedRawPartResponse(
          noteId: 'note-remote-conflict',
          raw: '远端正文',
          partRevisionId: 'raw-revision-8',
          etag: '"note-part-note-remote-conflict-raw-v8"',
        ),
        const ApiTransportResponse(
          status: 412,
          body: <String, Object?>{
            'success': false,
            'error': <String, Object?>{
              'code': 'PRECONDITION_FAILED',
              'message': 'stale note',
            },
          },
        ),
        _deployedNoteDetailResponse(
          _deployedNoteJson(
            noteId: 'note-remote-conflict',
            title: '远端标题',
            metadataVersion: 8,
          ),
          etag: '"note-note-remote-conflict-v8"',
        ),
        _deployedRawPartResponse(
          noteId: 'note-remote-conflict',
          raw: '远端正文',
          partRevisionId: 'raw-revision-8',
          etag: '"note-part-note-remote-conflict-raw-v8"',
        ),
      ]);
      final local =
          _pendingNote(
            id: 'local-conflict-note',
            title: '本地标题',
            body: '本地正文',
            localRevision: 4,
            remoteRevision: 7,
          ).copyWith(
            remoteNoteId: 'note-remote-conflict',
            noteRevisionId: 'note-revision-7',
            rawPartRevisionId: 'raw-revision-7',
            etag: '"note-7"',
            contentCursor: '80',
          );
      final controller = KnowledgeLibraryController(
        initialNotes: <V3FeedItem>[local],
        notePort: RemoteKnowledgeNotePort(
          apiClient: _knowledgeApiClient(transport),
          workspaceId: () => 'workspace-1',
        ),
      );

      final result = await controller.syncNote(local.id);

      expect(result.outcome, KnowledgeNoteSyncOutcome.conflict);
      expect(controller.noteForId(local.id)?.rawBody, '本地正文');
      expect(controller.conflictFor(local.id)?.remoteNote.rawBody, '远端正文');
      expect(
        controller.conflictFor(local.id)?.remoteNote.noteRevisionId,
        'raw-revision-8',
      );
      expect(transport.requests[2].method, 'PATCH');
      expect(
        transport.requests[2].headers['If-Match'],
        '"note-note-remote-conflict-v8"',
      );
      expect(
        transport.requests[2].url.path,
        '/api/v1/workspaces/workspace-1/notes/note-remote-conflict',
      );
      expect(transport.requests, hasLength(5));
    },
  );

  test(
    'startup remote HNotes merge without replacing a pending local draft',
    () async {
      final transport = _KnowledgeQueueTransport(<ApiTransportResponse>[
        ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'data': <String, Object?>{
              'items': <Object?>[
                _hNoteJson(
                  noteId: 'note-bound-pending',
                  title: '远端旧标题',
                  raw: '远端旧正文',
                  revision: '3',
                  cursor: '30',
                ),
                _hNoteJson(
                  noteId: 'note-remote-new',
                  title: '云端新增笔记',
                  raw: '云端正文',
                  revision: '1',
                  cursor: '31',
                ),
              ],
            },
          },
        ),
      ]);
      final pending =
          _pendingNote(
            id: 'local-pending',
            title: '本地待同步标题',
            body: '本地待同步正文',
          ).copyWith(
            remoteNoteId: 'note-bound-pending',
            noteRevisionId: 'note-revision-2',
            rawPartRevisionId: 'raw-revision-2',
            etag: '"note-2"',
            contentCursor: '29',
          );
      final controller = KnowledgeLibraryController(
        initialNotes: <V3FeedItem>[pending],
        notePort: RemoteKnowledgeNotePort(
          apiClient: _knowledgeApiClient(transport),
          workspaceId: () => 'workspace-1',
        ),
      );

      await controller.initialize();

      expect(controller.noteForId(pending.id)?.title, '本地待同步标题');
      expect(controller.noteForId(pending.id)?.rawBody, '本地待同步正文');
      expect(controller.noteForId('note-remote-new')?.title, '云端新增笔记');
      expect(controller.remoteLoadErrorCode, isNull);
      expect(transport.requests.single.method, 'GET');
    },
  );

  test(
    'deployed manual Note adapter writes and reloads persisted raw content',
    () async {
      final transport = _KnowledgeQueueTransport(<ApiTransportResponse>[
        ApiTransportResponse(
          status: 202,
          body: <String, Object?>{
            'success': true,
            'data': <String, Object?>{
              'note': _deployedNoteJson(
                noteId: 'note-manual-remote',
                title: '服务端资产',
                metadataVersion: 1,
              ),
              'partRevision': <String, Object?>{
                'partRevisionId': 'raw-revision-manual-1',
              },
            },
          },
        ),
        _deployedNoteDetailResponse(
          _deployedNoteJson(
            noteId: 'note-manual-remote',
            title: '服务端资产',
            metadataVersion: 1,
          ),
          etag: '"note-note-manual-remote-v1"',
        ),
        _deployedRawPartResponse(
          noteId: 'note-manual-remote',
          raw: '服务端真实正文',
          partRevisionId: 'raw-revision-manual-1',
          etag: '"note-part-note-manual-remote-raw-v1"',
        ),
        ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'data': <String, Object?>{
              'items': <Object?>[
                _deployedNoteJson(
                  noteId: 'note-manual-remote',
                  title: '服务端资产',
                  metadataVersion: 1,
                ),
              ],
            },
          },
        ),
        _deployedRawPartResponse(
          noteId: 'note-manual-remote',
          raw: '服务端真实正文',
          partRevisionId: 'raw-revision-manual-1',
          etag: '"note-part-note-manual-remote-raw-v1"',
        ),
      ]);
      final port = RemoteKnowledgeNotePort(
        apiClient: _knowledgeApiClient(transport),
        workspaceId: () => 'workspace-1',
      );
      final local = _pendingNote(
        id: 'local-manual-note',
        title: '服务端资产',
        body: '服务端真实正文',
      );

      final created = await port.updateNote(
        KnowledgeNoteUpdateRequest(
          noteId: local.id,
          baseRevision: null,
          localRevision: local.localRevision,
          draft: V3NoteDraft(title: local.title, rawBody: local.rawBody),
          localNote: local,
        ),
      );
      final loaded = await port.loadNotes();

      expect(created.status, KnowledgeNotePortStatus.success);
      expect(created.remoteNote?.remoteNoteId, 'note-manual-remote');
      expect(created.remoteNote?.rawBody, '服务端真实正文');
      expect(created.remoteNote?.rawPartRevisionId, 'raw-revision-manual-1');
      expect(loaded.status, KnowledgeNoteRemoteLoadStatus.success);
      expect(loaded.notes.single.title, '服务端资产');
      expect(loaded.notes.single.rawBody, '服务端真实正文');
      expect(transport.requests.map((request) => request.url.path), <String>[
        '/api/v1/workspaces/workspace-1/notes/manual',
        '/api/v1/workspaces/workspace-1/notes/note-manual-remote',
        '/api/v1/workspaces/workspace-1/notes/note-manual-remote/parts/raw',
        '/api/v1/workspaces/workspace-1/notes',
        '/api/v1/workspaces/workspace-1/notes/note-manual-remote/parts/raw',
      ]);
      final request = transport.requests.first;
      expect(request.headers['X-Idempotency-Key'], isNotEmpty);
      expect(request.headers.containsKey('Idempotency-Key'), isFalse);
      expect(jsonDecode(request.body!), <String, Object?>{
        'title': '服务端资产',
        'contentMarkdown': '服务端真实正文',
      });
    },
  );

  test(
    'deployed HNote summaries hydrate their raw part before rendering',
    () async {
      final transport = _KnowledgeQueueTransport(<ApiTransportResponse>[
        const ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'data': <String, Object?>{
              'items': <Object?>[
                <String, Object?>{
                  'noteId': 'note-summary-1',
                  'title': '摘要资产',
                  'state': 'active',
                  'noteRevisionId': 'note-revision-1',
                  'rawPartRevisionId': 'raw-revision-1',
                  'outlinePartRevisionId': 'outline-revision-1',
                  'germinationPartRevisionId': 'germination-revision-1',
                  'folderId': null,
                  'etag': '"note-1"',
                  'contentCursor': '5',
                  'createdAt': '2026-08-08T02:30:00Z',
                  'updatedAt': '2026-08-08T02:30:00Z',
                },
              ],
            },
          },
        ),
        const ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'data': <String, Object?>{
              'noteId': 'note-summary-1',
              'part': 'raw',
              'partRevisionId': 'raw-revision-1',
              'markdown': '从服务端分片读取的正文',
              'contentSha256': 'sha256:raw-summary-1',
              'etag': '"part-1"',
            },
          },
        ),
        const ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'data': <String, Object?>{
              'noteId': 'note-summary-1',
              'part': 'outline',
              'partRevisionId': 'outline-revision-1',
              'contentMarkdown': '',
              'contentSha256': 'sha256:outline-summary-1',
              'etag': '"outline-part-1"',
            },
          },
        ),
        const ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'data': <String, Object?>{
              'noteId': 'note-summary-1',
              'part': 'germination',
              'partRevisionId': 'germination-revision-1',
              'contentMarkdown': '',
              'contentSha256': 'sha256:germination-summary-1',
              'etag': '"germination-part-1"',
            },
          },
        ),
      ]);
      final port = RemoteKnowledgeNotePort(
        apiClient: _knowledgeApiClient(transport),
        workspaceId: () => 'workspace-1',
      );

      final loaded = await port.loadNotes();

      expect(loaded.status, KnowledgeNoteRemoteLoadStatus.success);
      expect(loaded.notes.single.title, '摘要资产');
      expect(loaded.notes.single.rawBody, '从服务端分片读取的正文');
      expect(loaded.notes.single.rawPartRevisionId, 'raw-revision-1');
      expect(transport.requests.map((request) => request.url.path), <String>[
        '/api/v1/workspaces/workspace-1/notes',
        '/api/v1/workspaces/workspace-1/notes/note-summary-1/parts/raw',
        '/api/v1/workspaces/workspace-1/notes/note-summary-1/parts/outline',
        '/api/v1/workspaces/workspace-1/notes/note-summary-1/parts/germination',
      ]);
      expect(
        transport.requests
            .skip(1)
            .map((request) => request.url.queryParameters['partRevisionId'])
            .toList(),
        <String?>[
          'raw-revision-1',
          'outline-revision-1',
          'germination-revision-1',
        ],
      );
    },
  );

  test('raw-only sparse HNote skips ungenerated derived part reads', () async {
    const noteId = 'note-raw-only-1';
    const sparseHead = <String, Object?>{
      'noteId': noteId,
      'title': '仅原文资产',
      'state': 'active',
      'noteRevisionId': 'note-revision-raw-only-1',
      'rawPartRevisionId': 'raw-revision-raw-only-1',
      'germinationPartRevisionId': '   ',
      'folderId': null,
      'etag': '"note-raw-only-1"',
      'contentCursor': '6',
      'createdAt': '2026-09-02T08:00:00Z',
      'updatedAt': '2026-09-02T08:01:00Z',
    };
    final transport = _KnowledgeQueueTransport(<ApiTransportResponse>[
      const ApiTransportResponse(
        status: 200,
        body: <String, Object?>{
          'success': true,
          'data': <String, Object?>{
            'items': <Object?>[sparseHead],
          },
        },
      ),
      const ApiTransportResponse(
        status: 200,
        body: <String, Object?>{
          'success': true,
          'data': <String, Object?>{
            'noteId': 'note-raw-only-1',
            'part': 'raw',
            'partRevisionId': 'raw-revision-raw-only-1',
            'contentMarkdown': '录音最终转写',
            'contentSha256': 'sha256:raw-only-1',
            'etag': '"raw-only-1"',
          },
        },
      ),
      const ApiTransportResponse(
        status: 200,
        body: <String, Object?>{'success': true, 'data': sparseHead},
      ),
      const ApiTransportResponse(
        status: 200,
        body: <String, Object?>{'success': true, 'data': sparseHead},
      ),
      const ApiTransportResponse(
        status: 200,
        body: <String, Object?>{
          'success': true,
          'data': <String, Object?>{
            'noteId': noteId,
            'part': 'raw',
            'partRevisionId': 'raw-revision-raw-only-1',
            'contentMarkdown': '录音最终转写',
            'contentSha256': 'sha256:raw-only-1',
            'etag': '"raw-only-1"',
          },
        },
      ),
    ]);
    final port = RemoteKnowledgeNotePort(
      apiClient: _knowledgeApiClient(transport),
      workspaceId: () => 'workspace-1',
    );

    final loaded = await port.loadNotes();
    final detail = await port.loadNote(noteId, localId: 'local-raw-only-1');

    expect(loaded.status, KnowledgeNoteRemoteLoadStatus.success);
    expect(loaded.notes.single.rawBody, '录音最终转写');
    expect(loaded.notes.single.rawPartRevisionId, 'raw-revision-raw-only-1');
    expect(loaded.notes.single.summaryBody, isNull);
    expect(loaded.notes.single.sproutStatus, V3SproutTaskStatus.notStarted);
    expect(loaded.notes.single.sproutReport, isNull);
    expect(detail.status, KnowledgeNotePortStatus.success);
    expect(detail.remoteNote?.rawBody, '录音最终转写');
    expect(detail.remoteNote?.summaryBody, isNull);
    expect(detail.remoteNote?.sproutReport, isNull);
    expect(transport.requests.map((request) => request.url.path), <String>[
      '/api/v1/workspaces/workspace-1/notes',
      '/api/v1/workspaces/workspace-1/notes/note-raw-only-1/parts/raw',
      '/api/v1/workspaces/workspace-1/notes/note-raw-only-1',
      '/api/v1/workspaces/workspace-1/notes/note-raw-only-1',
      '/api/v1/workspaces/workspace-1/notes/note-raw-only-1/parts/raw',
    ]);
    expect(
      transport.requests
          .where((request) => request.url.path.endsWith('/parts/raw'))
          .map((request) => request.url.queryParameters['partRevisionId']),
      everyElement('raw-revision-raw-only-1'),
    );
  });

  test(
    'exact HNote detail reads sparse parts instead of returning empty content',
    () async {
      const noteId = 'note-detail-sparse-1';
      const sparseHead = <String, Object?>{
        'noteId': noteId,
        'workspaceId': 'workspace-1',
        'sourceKind': 'recording',
        'sourceRef': <String, Object?>{
          'kind': 'recording',
          'id': 'recording-detail-sparse-1',
        },
        'folderId': null,
        'title': '迟到的纲要资产',
        'state': 'active',
        'noteRevisionId': 'note-revision-detail-1',
        'rawPartRevisionId': 'raw-revision-detail-1',
        'outlinePartRevisionId': 'outline-revision-detail-1',
        'germinationPartRevisionId': 'germination-revision-detail-1',
        'resourceRefs': <Object?>[],
        'etag': '"note-detail-1"',
        'contentCursor': '41',
        'createdAt': '2026-08-17T08:00:00Z',
        'updatedAt': '2026-08-17T08:01:00Z',
      };
      final transport = _KnowledgeQueueTransport(<ApiTransportResponse>[
        const ApiTransportResponse(
          status: 200,
          body: <String, Object?>{'success': true, 'data': sparseHead},
        ),
        const ApiTransportResponse(
          status: 200,
          body: <String, Object?>{'success': true, 'data': sparseHead},
        ),
        const ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'data': <String, Object?>{
              'noteId': noteId,
              'part': 'raw',
              'partRevisionId': 'raw-revision-detail-1',
              'contentMarkdown': '云端原始转写',
              'contentSha256': 'sha256:raw-detail-1',
              'etag': '"raw-detail-1"',
            },
          },
        ),
        const ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'data': <String, Object?>{
              'noteId': noteId,
              'part': 'outline',
              'partRevisionId': 'outline-revision-detail-1',
              'contentMarkdown': '# 云端纲要',
              'contentSha256': 'sha256:outline-detail-1',
              'etag': '"outline-detail-1"',
            },
          },
        ),
        const ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'data': <String, Object?>{
              'noteId': noteId,
              'part': 'germination',
              'partRevisionId': 'germination-revision-detail-1',
              'contentMarkdown': '# 云端点火',
              'contentSha256': 'sha256:germination-detail-1',
              'etag': '"germination-detail-1"',
            },
          },
        ),
      ]);
      final port = RemoteKnowledgeNotePort(
        apiClient: _knowledgeApiClient(transport),
        workspaceId: () => 'workspace-1',
      );

      final result = await port.loadNote(
        noteId,
        localId: 'local-detail-sparse-1',
      );

      expect(result.status, KnowledgeNotePortStatus.success);
      expect(result.remoteNote?.rawBody, '云端原始转写');
      expect(result.remoteNote?.summaryBody, '# 云端纲要');
      expect(result.remoteNote?.recordingId, 'recording-detail-sparse-1');
      expect(result.remoteNote?.sproutReport?.markdown, '# 云端点火');
      expect(transport.requests.map((request) => request.url.path), <String>[
        '/api/v1/workspaces/workspace-1/notes/$noteId',
        '/api/v1/workspaces/workspace-1/notes/$noteId',
        '/api/v1/workspaces/workspace-1/notes/$noteId/parts/raw',
        '/api/v1/workspaces/workspace-1/notes/$noteId/parts/outline',
        '/api/v1/workspaces/workspace-1/notes/$noteId/parts/germination',
      ]);
      expect(
        transport.requests
            .skip(2)
            .map((request) => request.url.queryParameters['partRevisionId'])
            .toList(),
        <String?>[
          'raw-revision-detail-1',
          'outline-revision-detail-1',
          'germination-revision-detail-1',
        ],
      );
    },
  );

  test(
    'chat-reference reconciliation repairs a cached HNote revision',
    () async {
      final transport = _KnowledgeQueueTransport(<ApiTransportResponse>[
        const ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'data': <String, Object?>{
              'items': <Object?>[
                <String, Object?>{
                  'noteId': 'note-chat-reference-1',
                  'title': '远端沉淀笔记',
                  'state': 'live',
                  'noteRevisionId': 'note-revision-chat-1',
                  'rawPartRevisionId': 'raw-revision-chat-1',
                  'outlinePartRevisionId': 'outline-revision-chat-1',
                  'germinationPartRevisionId': 'germination-revision-chat-1',
                  'folderId': null,
                  'etag': '"note-chat-1"',
                  'contentCursor': '31',
                  'createdAt': '2026-08-08T02:30:00Z',
                  'updatedAt': '2026-08-08T02:30:00Z',
                },
              ],
            },
          },
        ),
        const ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'data': <String, Object?>{
              'noteId': 'note-chat-reference-1',
              'part': 'raw',
              'partRevisionId': 'raw-revision-chat-1',
              'markdown': '来自云端的原始内容',
              'contentSha256': 'sha256:raw-chat-1',
              'etag': '"part-chat-1"',
            },
          },
        ),
        const ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'data': <String, Object?>{
              'noteId': 'note-chat-reference-1',
              'part': 'outline',
              'partRevisionId': 'outline-revision-chat-1',
              'contentMarkdown': '',
              'contentSha256': 'sha256:outline-chat-1',
              'etag': '"outline-part-chat-1"',
            },
          },
        ),
        const ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'data': <String, Object?>{
              'noteId': 'note-chat-reference-1',
              'part': 'germination',
              'partRevisionId': 'germination-revision-chat-1',
              'contentMarkdown': '',
              'contentSha256': 'sha256:germination-chat-1',
              'etag': '"germination-part-chat-1"',
            },
          },
        ),
      ]);
      final cached = V3FeedItem(
        id: 'note-chat-reference-1',
        title: '远端沉淀笔记',
        source: V3MaterialSource.subscription,
        createdAt: DateTime.utc(2026, 8, 8, 2, 30),
        rawBody: '缓存内容',
        ownership: V3NoteOwnership.mine,
        remoteNoteId: 'note-chat-reference-1',
        noteRevisionId: 'note-revision-chat-1',
        syncState: NoteSyncState.synced,
      );
      final controller = KnowledgeLibraryController(
        initialNotes: <V3FeedItem>[cached],
        notePort: RemoteKnowledgeNotePort(
          apiClient: _knowledgeApiClient(transport),
          workspaceId: () => 'workspace-1',
        ),
      );

      expect(await controller.reconcileRemoteNotesForChatReference(), isTrue);
      final reconciled = controller.noteForId(cached.id)!;
      expect(reconciled.remoteNoteId, 'note-chat-reference-1');
      expect(reconciled.ownership, V3NoteOwnership.mine);
      expect(reconciled.rawPartRevisionId, 'raw-revision-chat-1');
      expect(reconciled.rawBody, '来自云端的原始内容');
    },
  );

  test(
    'note sync sends base revision and accepts a complete remote note',
    () async {
      final local = _pendingNote(
        id: 'sync-success',
        title: '本地标题',
        body: '本地正文',
        localRevision: 3,
        remoteRevision: 8,
      );
      final remote = _remoteNote(
        id: local.id,
        title: '服务端确认标题',
        body: '服务端完整正文',
        remoteRevision: 9,
      );
      final port = _QueueKnowledgeNotePort([
        KnowledgeNotePortResult.success(remote),
      ]);
      final controller = KnowledgeLibraryController(
        initialNotes: [local],
        notePort: port,
      );

      final result = await controller.syncNote(local.id);

      expect(result.outcome, KnowledgeNoteSyncOutcome.synced);
      expect(port.requests, hasLength(1));
      expect(port.requests.single.noteId, local.id);
      expect(port.requests.single.baseRevision, 8);
      expect(port.requests.single.localRevision, 3);
      expect(port.requests.single.draft.title, local.title);
      expect(port.requests.single.draft.rawBody, local.rawBody);
      expect(controller.noteForId(local.id)?.title, remote.title);
      expect(controller.noteForId(local.id)?.remoteRevision, 9);
      expect(controller.noteForId(local.id)?.syncState, NoteSyncState.synced);
    },
  );

  test('unavailable and malformed note sync never report success', () async {
    final unavailableNote = _pendingNote(
      id: 'sync-unavailable',
      title: '离线草稿',
      body: '保留内容',
    );
    final unavailable = KnowledgeLibraryController(
      initialNotes: [unavailableNote],
    );

    final unavailableResult = await unavailable.syncNote(unavailableNote.id);
    expect(unavailableResult.outcome, KnowledgeNoteSyncOutcome.unavailable);
    expect(
      unavailable.noteForId(unavailableNote.id)?.syncState,
      NoteSyncState.pending,
    );
    expect(unavailable.noteForId(unavailableNote.id)?.rawBody, '保留内容');

    final malformedPort = _QueueKnowledgeNotePort([
      KnowledgeNotePortResult.success(
        _remoteNote(
          id: 'another-note',
          title: '错误响应',
          body: '不能覆盖',
          remoteRevision: 2,
        ),
      ),
    ]);
    final malformed = KnowledgeLibraryController(
      initialNotes: [unavailableNote],
      notePort: malformedPort,
    );
    final malformedResult = await malformed.syncNote(unavailableNote.id);
    expect(malformedResult.outcome, KnowledgeNoteSyncOutcome.failed);
    expect(malformedResult.errorCode, 'KNOWLEDGE_NOTE_RESPONSE_INVALID');
    expect(malformed.noteForId(unavailableNote.id)?.rawBody, '保留内容');
    expect(
      malformed.noteForId(unavailableNote.id)?.syncState,
      NoteSyncState.pending,
    );
  });

  test(
    'conflict snapshots support explicit remote and local resolutions',
    () async {
      final local = _pendingNote(
        id: 'conflicted-note',
        title: '本地标题',
        body: '本地草稿',
        localRevision: 4,
        remoteRevision: 10,
      );
      final remote = _remoteNote(
        id: local.id,
        title: '远端标题',
        body: '远端正文',
        remoteRevision: 11,
      );
      final remoteController = KnowledgeLibraryController(
        initialNotes: [local],
        notePort: _QueueKnowledgeNotePort([
          KnowledgeNotePortResult.conflict(remote),
        ]),
      );

      final conflictResult = await remoteController.syncNote(local.id);
      expect(conflictResult.outcome, KnowledgeNoteSyncOutcome.conflict);
      expect(remoteController.noteForId(local.id)?.rawBody, '本地草稿');
      expect(
        remoteController.noteForId(local.id)?.syncState,
        NoteSyncState.conflict,
      );
      expect(remoteController.conflictFor(local.id)?.remoteNote.title, '远端标题');

      final useRemote = await remoteController.resolveConflict(
        local.id,
        KnowledgeNoteConflictResolution.useRemote,
      );
      expect(useRemote.outcome, KnowledgeNoteSyncOutcome.synced);
      expect(remoteController.noteForId(local.id)?.rawBody, '远端正文');
      expect(remoteController.conflictFor(local.id), isNull);

      final keepPort = _QueueKnowledgeNotePort([
        KnowledgeNotePortResult.conflict(remote),
        KnowledgeNotePortResult.success(
          _remoteNote(
            id: local.id,
            title: local.title,
            body: local.rawBody,
            remoteRevision: 12,
          ),
        ),
      ]);
      final keepController = KnowledgeLibraryController(
        initialNotes: [local],
        notePort: keepPort,
      );
      await keepController.syncNote(local.id);
      final keepLocal = await keepController.resolveConflict(
        local.id,
        KnowledgeNoteConflictResolution.keepLocal,
      );
      expect(keepLocal.outcome, KnowledgeNoteSyncOutcome.synced);
      expect(keepPort.requests, hasLength(2));
      expect(keepPort.requests.last.baseRevision, 11);
      expect(keepPort.requests.last.draft.rawBody, '本地草稿');
      expect(keepController.noteForId(local.id)?.rawBody, '本地草稿');
      expect(keepController.noteForId(local.id)?.remoteRevision, 12);
    },
  );

  test('newer local edit supersedes an in-flight note response', () async {
    final local = _pendingNote(
      id: 'sync-race',
      title: '同步前',
      body: '第一版',
      localRevision: 2,
      remoteRevision: 4,
    );
    final port = _CompletingKnowledgeNotePort();
    final controller = KnowledgeLibraryController(
      initialNotes: [local],
      notePort: port,
    );

    final syncing = controller.syncNote(local.id);
    controller.updateManualNote(id: local.id, title: '同步后编辑', rawBody: '第二版');
    port.complete(
      KnowledgeNotePortResult.success(
        _remoteNote(id: local.id, title: '旧响应', body: '第一版', remoteRevision: 5),
      ),
    );

    final result = await syncing;
    expect(result.outcome, KnowledgeNoteSyncOutcome.superseded);
    expect(controller.noteForId(local.id)?.title, '同步后编辑');
    expect(controller.noteForId(local.id)?.rawBody, '第二版');
    expect(controller.noteForId(local.id)?.syncState, NoteSyncState.pending);
  });

  test('superseded first create retains its complete remote binding', () async {
    final local = _pendingNote(
      id: 'sync-create-race',
      title: '同步前',
      body: '第一版',
      localRevision: 1,
    );
    final port = _CompletingKnowledgeNotePort();
    final controller = KnowledgeLibraryController(
      initialNotes: <V3FeedItem>[local],
      notePort: port,
    );

    final syncing = controller.syncNote(local.id);
    controller.updateManualNote(id: local.id, title: '同步后编辑', rawBody: '第二版');
    port.complete(
      KnowledgeNotePortResult.success(
        _remoteNote(
          id: local.id,
          title: '同步前',
          body: '第一版',
          remoteRevision: 1,
        ).copyWith(
          remoteNoteId: 'remote-create-race',
          noteRevisionId: 'note-revision-1',
          rawPartRevisionId: 'raw-revision-1',
          etag: '"note-1"',
          contentCursor: '1',
        ),
      ),
    );

    final result = await syncing;
    final current = controller.noteForId(local.id)!;
    expect(result.outcome, KnowledgeNoteSyncOutcome.superseded);
    expect(current.title, '同步后编辑');
    expect(current.rawBody, '第二版');
    expect(current.remoteNoteId, 'remote-create-race');
    expect(current.rawPartRevisionId, 'raw-revision-1');
    expect(current.syncState, NoteSyncState.pending);
  });

  test(
    'durable deletion restores notes and links after cache failure',
    () async {
      final target = _pendingNote(
        id: 'delete-target',
        title: '待删除',
        body: '正文',
      );
      final referencing =
          _pendingNote(
            id: 'delete-reference',
            title: '引用笔记',
            body: '保留引用',
          ).copyWith(
            linkedMaterials: [
              V3LinkedMaterialRef(
                id: target.id,
                source: target.source,
                title: target.title,
              ),
            ],
          );
      final controller = KnowledgeLibraryController(
        initialNotes: [target, referencing],
        cache: _FailingKnowledgeLibraryCache(),
      );

      final result = await controller.deleteNoteDurably(target.id);

      expect(result.outcome, KnowledgeNoteDeleteOutcome.persistenceFailed);
      expect(controller.noteForId(target.id), isNotNull);
      expect(
        controller.noteForId(referencing.id)?.linkedMaterials.single.id,
        target.id,
      );
    },
  );

  test('recycle bin restores note deposit labels and backlinks', () async {
    final target = _pendingNote(id: 'trash-target', title: '可恢复笔记', body: '正文');
    final referencing =
        _pendingNote(
          id: 'trash-reference',
          title: '引用笔记',
          body: '引用正文',
        ).copyWith(
          linkedMaterials: [
            V3LinkedMaterialRef(
              id: target.id,
              source: target.source,
              title: target.title,
            ),
          ],
        );
    final database = AppDatabase();
    final trash = _MemoryTrashRepository();
    final controller = KnowledgeLibraryController(
      initialNotes: [target, referencing],
      cache: _MemoryKnowledgeLibraryCache(),
      trashRepository: trash,
      depositRepository: V3DepositRepository(
        dao: V3DepositDao(database),
        userScope: 'user:trash',
      ),
    );
    expect(controller.depositContent(target.id), isNotNull);

    final deleted = await controller.deleteNoteDurably(target.id);
    expect(deleted.outcome, KnowledgeNoteDeleteOutcome.deleted);
    expect(controller.noteForId(target.id), isNull);
    expect(controller.trashEntries, hasLength(1));
    expect(controller.noteForId(referencing.id)?.linkedMaterials, isEmpty);

    expect(await controller.restoreTrashEntry(target.id), isTrue);
    expect(controller.noteForId(target.id), isNotNull);
    expect(controller.isDeposited(target.id), isTrue);
    expect(
      controller.noteForId(referencing.id)?.linkedMaterials.single.id,
      target.id,
    );
    expect(controller.trashEntries, isEmpty);
    expect(trash.entries, isEmpty);
  });

  test(
    'source categories map exactly and only mine applies library filtering',
    () {
      expect(
        knowledgeSourceCategoryFor(V3MaterialSource.meeting),
        KnowledgeSourceCategory.recording,
      );
      expect(
        knowledgeSourceCategoryFor(V3MaterialSource.internalRecording),
        KnowledgeSourceCategory.recording,
      );
      expect(
        knowledgeSourceCategoryFor(V3MaterialSource.monologue),
        KnowledgeSourceCategory.recording,
      );
      expect(
        knowledgeSourceCategoryFor(V3MaterialSource.recordingCard),
        KnowledgeSourceCategory.recording,
      );
      expect(
        knowledgeSourceCategoryFor(V3MaterialSource.link),
        KnowledgeSourceCategory.link,
      );
      expect(
        knowledgeSourceCategoryFor(V3MaterialSource.note),
        KnowledgeSourceCategory.manual,
      );
      expect(
        knowledgeSourceCategoryFor(V3MaterialSource.documentImport),
        KnowledgeSourceCategory.imported,
      );
      expect(
        knowledgeSourceCategoryFor(V3MaterialSource.mediaImport),
        KnowledgeSourceCategory.imported,
      );
      expect(
        knowledgeSourceCategoryFor(V3MaterialSource.subscription),
        KnowledgeSourceCategory.other,
      );

      final database = AppDatabase();
      final depositRepository = V3DepositRepository(
        dao: V3DepositDao(database),
        userScope: 'category-user',
      );
      final now = DateTime(2026, 7, 19, 10);
      depositRepository.saveMembership(
        V3LibraryMembership(
          contentId: 'subscribed-link',
          collection: V3LibraryCollection.subscribed,
          createdAt: now,
        ),
      );
      depositRepository.saveMembership(
        V3LibraryMembership(
          contentId: 'square-import',
          collection: V3LibraryCollection.square,
          createdAt: now,
        ),
      );
      final controller = KnowledgeLibraryController(
        depositRepository: depositRepository,
        initialNotes: <V3FeedItem>[
          V3FeedItem(
            id: 'mine-recording',
            title: '录音',
            source: V3MaterialSource.meeting,
            createdAt: now,
            rawBody: '内容',
          ),
          V3FeedItem(
            id: 'subscribed-link',
            title: '链接',
            source: V3MaterialSource.link,
            createdAt: now,
            rawBody: '内容',
            ownership: V3NoteOwnership.subscribed,
          ),
          V3FeedItem(
            id: 'square-import',
            title: '导入',
            source: V3MaterialSource.documentImport,
            createdAt: now,
            rawBody: '内容',
            ownership: V3NoteOwnership.knowledgeSquare,
          ),
        ],
      );
      expect(controller.depositContent('mine-recording'), isNotNull);

      controller
        ..setSourceCategory(
          V3KnowledgeLibraryTab.mine,
          KnowledgeSourceCategory.recording,
        )
        ..setSourceCategory(
          V3KnowledgeLibraryTab.subscribed,
          KnowledgeSourceCategory.link,
        )
        ..setSourceCategory(
          V3KnowledgeLibraryTab.square,
          KnowledgeSourceCategory.imported,
        )
        ..setDepositSourceCategory(KnowledgeSourceCategory.recording);

      expect(
        controller.filteredNotesFor(V3KnowledgeLibraryTab.mine).single.id,
        'mine-recording',
      );
      expect(
        controller.filteredNotesFor(V3KnowledgeLibraryTab.subscribed).single.id,
        'subscribed-link',
      );
      expect(
        controller.filteredNotesFor(V3KnowledgeLibraryTab.square).single.id,
        'square-import',
      );
      expect(
        controller.sourceCategoryFor(V3KnowledgeLibraryTab.subscribed),
        KnowledgeSourceCategory.all,
      );
      expect(
        controller.sourceCategoryFor(V3KnowledgeLibraryTab.square),
        KnowledgeSourceCategory.all,
      );
      expect(controller.filteredDepositNotes.single.id, 'mine-recording');
      expect(
        controller.sourceCategoryFor(V3KnowledgeLibraryTab.mine),
        KnowledgeSourceCategory.recording,
      );
      expect(
        controller.depositSourceCategory,
        KnowledgeSourceCategory.recording,
      );
    },
  );

  test('effective tags and card mode persist with account isolation', () {
    final database = AppDatabase();
    KnowledgeUserMetadataRepository repositoryFor(String scope) {
      return KnowledgeUserMetadataRepository(
        dao: UserMetadataDao(database),
        userScope: scope,
      );
    }

    final readOnly = V3FeedItem(
      id: 'readonly-tags',
      title: '只读内容',
      source: V3MaterialSource.subscription,
      createdAt: DateTime(2026, 7, 19),
      rawBody: '正文',
      topics: const <String>['作者标签'],
    );
    final first = KnowledgeLibraryController(
      initialNotes: <V3FeedItem>[readOnly],
      userMetadataRepository: repositoryFor('account-a'),
      now: () => DateTime(2026, 7, 19, 12),
    );

    expect(
      first.updateEffectiveTags(readOnly.id, const <String>[
        '作者标签',
        '客户',
        '客户',
      ]),
      isTrue,
    );
    expect(first.effectiveTags(first.noteForId(readOnly.id)!), ['作者标签', '客户']);
    expect(first.setCardDisplayMode(KnowledgeCardDisplayMode.compact), isTrue);
    first.setQuery('客户');
    first.setTab(V3KnowledgeLibraryTab.subscribed);
    expect(first.filteredNotes.single.id, readOnly.id);

    final restored = KnowledgeLibraryController(
      initialNotes: <V3FeedItem>[readOnly],
      userMetadataRepository: repositoryFor('account-a'),
    );
    expect(restored.cardDisplayMode, KnowledgeCardDisplayMode.compact);
    expect(restored.effectiveTags(restored.noteForId(readOnly.id)!), [
      '作者标签',
      '客户',
    ]);

    final isolated = KnowledgeLibraryController(
      initialNotes: <V3FeedItem>[readOnly],
      userMetadataRepository: repositoryFor('account-b'),
    );
    expect(isolated.cardDisplayMode, KnowledgeCardDisplayMode.expanded);
    expect(isolated.effectiveTags(isolated.noteForId(readOnly.id)!), ['作者标签']);

    final owned = V3FeedItem(
      id: 'owned-tags',
      title: '个人内容',
      source: V3MaterialSource.note,
      createdAt: DateTime(2026, 7, 19),
      rawBody: '正文',
    );
    final ownedController = KnowledgeLibraryController(initialNotes: [owned]);
    expect(
      ownedController.updateEffectiveTags(owned.id, const <String>[
        'AI',
        'ai',
        '产品',
      ]),
      isTrue,
    );
    expect(ownedController.noteForId(owned.id)?.topics, ['AI', '产品']);
    expect(
      ownedController.updateEffectiveTags(owned.id, <String>[
        List<String>.filled(25, 'x').join(),
      ]),
      isFalse,
    );
    expect(
      ownedController.updateEffectiveTags(
        owned.id,
        List<String>.generate(21, (index) => '标签$index'),
      ),
      isFalse,
    );
  });

  test(
    'editable copy preserves real content and ownership through cache',
    () async {
      final directory = await Directory.systemTemp.createTemp('knowledge-copy');
      addTearDown(() => directory.delete(recursive: true));
      final database = AppDatabase();
      final metadataRepository = KnowledgeUserMetadataRepository(
        dao: UserMetadataDao(database),
        userScope: 'copy-user',
      );
      final cache = ApplicationSupportKnowledgeLibraryCache(
        scopeId: 'copy-user',
        directoryResolver: () async => directory,
      );
      final original = V3FeedItem(
        id: 'square-original',
        title: '行业方法',
        source: V3MaterialSource.knowledgeSquare,
        createdAt: DateTime(2026, 7, 18),
        rawBody: '原始正文',
        summaryBody: '纲要正文',
        sproutStatus: V3SproutTaskStatus.succeeded,
        sproutTopic: '点火正文',
        publicUrl: 'https://example.com/source/article',
        topics: const <String>['作者标签'],
        mediaAttachments: const <V3MediaAttachment>[
          V3MediaAttachment(
            privateUri: 'app-private://knowledge/media-1',
            displayName: '示例图片.jpg',
            mimeType: 'image/jpeg',
            sizeBytes: 128,
            kind: V3MediaAttachmentKind.image,
            privatePath: '',
          ),
        ],
      );
      final first = KnowledgeLibraryController(
        initialNotes: <V3FeedItem>[original],
        cache: cache,
        userMetadataRepository: metadataRepository,
        now: () => DateTime(2026, 7, 19, 9),
      );
      expect(
        first.updateEffectiveTags(original.id, const <String>['作者标签', '私有标签']),
        isTrue,
      );

      final copy = first.createEditableCopy(original.id)!;
      expect(copy.ownership, V3NoteOwnership.mine);
      expect(copy.source, V3MaterialSource.knowledgeSquare);
      expect(copy.copiedFromContentId, original.id);
      expect(copy.publicUrl, original.publicUrl);
      expect(copy.title, '行业方法（副本）');
      expect(copy.rawBody, original.rawBody);
      expect(copy.summaryBody, original.summaryBody);
      expect(copy.sproutTopic, original.sproutTopic);
      expect(copy.topics, ['作者标签', '私有标签']);
      expect(copy.mediaAttachments.single.displayName, '示例图片.jpg');
      expect(
        copy.linkedMaterials.any((item) => item.id == original.id),
        isTrue,
      );
      await first.flushPersistence();

      final restored = KnowledgeLibraryController(
        initialNotes: const <V3FeedItem>[],
        cache: cache,
        userMetadataRepository: metadataRepository,
      );
      await restored.restore();
      final restoredCopy = restored.noteForId(copy.id)!;
      expect(restoredCopy.ownership, V3NoteOwnership.mine);
      expect(restoredCopy.source, V3MaterialSource.knowledgeSquare);
      expect(restoredCopy.copiedFromContentId, original.id);
      expect(restoredCopy.publicUrl, original.publicUrl);
      expect(
        restored.filteredNotesFor(V3KnowledgeLibraryTab.mine),
        contains(restoredCopy),
      );
    },
  );

  test(
    'editable copy stays owned when sync omits local copy metadata',
    () async {
      final original = V3FeedItem(
        id: 'subscription-original',
        title: '订阅原文',
        source: V3MaterialSource.subscription,
        createdAt: DateTime(2026, 7, 18),
        rawBody: '原文',
      );
      final port = _QueueKnowledgeNotePort(<KnowledgeNotePortResult>[]);
      final controller = KnowledgeLibraryController(
        initialNotes: <V3FeedItem>[original],
        notePort: port,
        now: () => DateTime(2026, 7, 19),
      );
      final copy = controller.createEditableCopy(original.id)!;
      port.responses.add(
        KnowledgeNotePortResult.success(
          V3FeedItem(
            id: copy.id,
            title: copy.title,
            source: V3MaterialSource.subscription,
            createdAt: copy.createdAt,
            rawBody: copy.rawBody,
            remoteRevision: 1,
            syncState: NoteSyncState.synced,
          ),
        ),
      );

      final result = await controller.syncNote(copy.id);

      expect(result.outcome, KnowledgeNoteSyncOutcome.synced);
      expect(result.note?.ownership, V3NoteOwnership.mine);
      expect(result.note?.copiedFromContentId, original.id);
      expect(controller.noteForId(copy.id)?.ownership, V3NoteOwnership.mine);
    },
  );

  test(
    'Knowledge Square catalog is single-flight and not blocked by initialization',
    () async {
      final sequence = <String>[];
      final controller = KnowledgeLibraryController(
        initialNotes: const <V3FeedItem>[],
        includeDemoFixtures: false,
        cache: _MemoryKnowledgeLibraryCache(),
        hotspotRepository: _SequencedHotspotRepository(sequence),
        subscriptionPort: _FakeMobileSubscriptionPort(
          catalogResult: const MobileSubscriptionCatalogResult.success(
            <MobileSubscriptionPublication>[],
          ),
          loadEvents: sequence,
        ),
      );
      addTearDown(controller.dispose);

      await controller.initialize();

      expect(sequence, <String>['home']);

      await Future.wait<void>(<Future<void>>[
        controller.ensureSubscriptionCatalogLoaded(),
        controller.ensureSubscriptionCatalogLoaded(),
      ]);
      expect(sequence, <String>['home', 'catalog']);

      await controller.reloadSubscriptions();
      expect(sequence, <String>['home', 'catalog', 'catalog']);
    },
  );

  test(
    'remote subscriptions load metadata then exact detail and saved HNote',
    () async {
      final article = _subscriptionArticleFixture();
      final port = _FakeMobileSubscriptionPort(
        catalogResult: MobileSubscriptionCatalogResult.success(
          <MobileSubscriptionPublication>[
            _subscriptionPublicationFixture(article: article),
          ],
        ),
        articleResults: <MobileSubscriptionActionResult>[
          MobileSubscriptionActionResult.success(
            article.copyWith(rawBody: '# 精确版本正文'),
          ),
        ],
        saveResults: <MobileSubscriptionActionResult>[
          MobileSubscriptionActionResult.success(
            _savedSubscriptionNote(article),
          ),
        ],
      );
      final controller = KnowledgeLibraryController(
        initialNotes: const <V3FeedItem>[],
        subscriptionPort: port,
      );
      final graph = FeedGraphController(controller);
      addTearDown(graph.dispose);

      await controller.reloadSubscriptions();

      expect(controller.subscriptionMode, MobileSubscriptionRuntimeMode.remote);
      expect(controller.subscriptionPublications.single.followed, isTrue);
      expect(controller.remoteSubscribedArticles.single.rawBody, isEmpty);
      expect(controller.remoteSubscribedArticles.single.summaryBody, '安全摘要');
      expect(controller.noteForId(article.id)?.articleId, 'article-1');
      expect(controller.canDepositReadOnlyContent(article.id), isTrue);

      final detail = await controller.loadRemoteSubscriptionArticle(article.id);
      expect(detail.status, MobileSubscriptionResultStatus.success);
      expect(controller.noteForId(article.id)?.rawBody, '# 精确版本正文');

      final saved = await controller.saveRemoteSubscriptionArticle(article.id);
      expect(saved.status, MobileSubscriptionResultStatus.success);
      final owned = controller.noteForId('note-subscription-1');
      expect(owned?.ownership, V3NoteOwnership.mine);
      expect(owned?.remoteNoteId, 'note-subscription-1');
      expect(owned?.articleRevisionId, 'article-revision-1');
      expect(controller.isDeposited('note-subscription-1'), isTrue);
      expect(
        controller.allDepositedNotes.map((note) => note.id),
        contains('note-subscription-1'),
      );
      expect(
        graph.nodes.map((node) => node.id),
        contains('note-subscription-1'),
      );
    },
  );

  test(
    'unfollowed articles save independently without local-copy fallback',
    () async {
      final article = _subscriptionArticleFixture();
      final port = _FakeMobileSubscriptionPort(
        catalogResult: MobileSubscriptionCatalogResult.success([
          _subscriptionPublicationFixture(article: article, followed: false),
        ]),
        saveResults: [
          MobileSubscriptionActionResult.success(
            _savedSubscriptionNote(article),
          ),
        ],
      );
      final controller = KnowledgeLibraryController(
        initialNotes: [],
        subscriptionPort: port,
      );
      addTearDown(controller.dispose);
      await controller.reloadSubscriptions();

      expect(controller.canDepositReadOnlyContent(article.id), isTrue);
      expect(
        controller.isRemotePublicationFollowed(article.publicationId!),
        isFalse,
      );
      expect(controller.depositSubscribedSnapshot(article.id), isNull);
      expect(controller.allDepositedNotes, isEmpty);
      final result = await controller.saveRemoteSubscriptionArticle(article.id);
      expect(result.status, MobileSubscriptionResultStatus.success);
      final note = result.item!;
      expect(note.isReadOnly, isFalse);
      expect(note.remoteNoteId, 'note-subscription-1');
      expect(note.articleRevisionId, article.articleRevisionId);
      expect(controller.isDeposited(note.id), isTrue);
      expect(controller.noteForId(article.id)?.isReadOnly, isTrue);
      expect(controller.remoteSubscribedArticles, isEmpty);
      expect(
        controller.isRemotePublicationFollowed(article.publicationId!),
        isFalse,
      );
      expect(controller.isSubscribed(article.id), isFalse);
      expect(port.followActionIds, isEmpty);
      expect(port.saveActionIds, hasLength(1));
    },
  );

  test(
    'Workspace projection cannot evict or persist Subscription Articles',
    () async {
      final article = _subscriptionArticleFixture();
      final port = _FakeMobileSubscriptionPort(
        catalogResult: MobileSubscriptionCatalogResult.success(
          <MobileSubscriptionPublication>[
            _subscriptionPublicationFixture(article: article),
          ],
        ),
        articleResults: <MobileSubscriptionActionResult>[
          MobileSubscriptionActionResult.success(
            article.copyWith(rawBody: '# 服务端精确正文'),
          ),
        ],
      );
      final cache = _MemoryKnowledgeLibraryCache();
      final controller = KnowledgeLibraryController(
        initialNotes: const <V3FeedItem>[],
        includeDemoFixtures: false,
        cache: cache,
        subscriptionPort: port,
      );
      addTearDown(controller.dispose);
      await controller.restore();

      await controller.reloadSubscriptions();

      expect(controller.noteForId(article.id)?.articleId, 'article-1');
      expect(controller.notes, isEmpty);
      expect(cache.notes, isNull);

      final workspaceNote = V3FeedItem(
        id: 'workspace-note-1',
        title: '账号私有资产',
        source: V3MaterialSource.note,
        createdAt: DateTime.utc(2026, 8, 22, 10),
        rawBody: '工作区正文',
        remoteNoteId: 'workspace-note-1',
        noteRevisionId: 'note-revision-1',
        rawPartRevisionId: 'raw-revision-1',
        etag: '"workspace-note-1"',
        syncState: NoteSyncState.synced,
      );
      await controller.applyWorkspaceContentProjection(
        WorkspaceContentProjection(
          notes: <V3FeedItem>[workspaceNote],
          folders: const <String, WorkspaceContentRemoteFolder>{},
          contentCursor: 'workspace-cursor-1',
          origin: WorkspaceContentProjectionOrigin.snapshot,
        ),
      );

      expect(controller.notes.map((note) => note.id), <String>[
        workspaceNote.id,
      ]);
      expect(controller.noteForId(article.id)?.articleId, 'article-1');

      final detail = await controller.loadRemoteSubscriptionArticle(article.id);

      expect(detail.status, MobileSubscriptionResultStatus.success);
      expect(port.loadedArticleIds, <String>[article.id]);
      expect(controller.noteForId(article.id)?.rawBody, '# 服务端精确正文');
      expect(cache.notes?.map((note) => note.id), <String>[workspaceNote.id]);
    },
  );

  test(
    'subscription mutations retain failed action key and rotate after success',
    () async {
      final article = _subscriptionArticleFixture();
      final port = _FakeMobileSubscriptionPort(
        catalogResult: MobileSubscriptionCatalogResult.success(
          <MobileSubscriptionPublication>[
            _subscriptionPublicationFixture(article: article, followed: false),
          ],
        ),
        followResults: <MobileSubscriptionActionResult>[
          const MobileSubscriptionActionResult.failure('NETWORK_FAILURE'),
          const MobileSubscriptionActionResult.success(),
          const MobileSubscriptionActionResult.success(),
          const MobileSubscriptionActionResult.success(),
        ],
        saveResults: <MobileSubscriptionActionResult>[
          const MobileSubscriptionActionResult.failure('NETWORK_FAILURE'),
          MobileSubscriptionActionResult.success(
            _savedSubscriptionNote(article),
          ),
          MobileSubscriptionActionResult.success(
            _savedSubscriptionNote(
              article.copyWith(articleRevisionId: 'article-revision-2'),
            ),
          ),
        ],
        articleResults: <MobileSubscriptionActionResult>[
          MobileSubscriptionActionResult.success(
            article.copyWith(
              rawBody: '# 新版本',
              articleRevisionId: 'article-revision-2',
            ),
          ),
        ],
      );
      final controller = KnowledgeLibraryController(
        initialNotes: const <V3FeedItem>[],
        subscriptionPort: port,
        now: () => DateTime.utc(2026, 8, 7, 12),
      );
      await controller.reloadSubscriptions();

      await controller.toggleRemotePublication('publication-1');
      await controller.toggleRemotePublication('publication-1');
      expect(port.followActionIds[0], port.followActionIds[1]);
      expect(controller.isRemotePublicationFollowed('publication-1'), isTrue);

      await controller.toggleRemotePublication('publication-1');
      await controller.toggleRemotePublication('publication-1');
      expect(port.followActionIds[2], isNot(port.followActionIds[1]));
      expect(port.followActionIds[3], isNot(port.followActionIds[2]));

      await controller.saveRemoteSubscriptionArticle(article.id);
      await controller.saveRemoteSubscriptionArticle(article.id);
      expect(port.saveActionIds[0], port.saveActionIds[1]);

      await controller.loadRemoteSubscriptionArticle(article.id);
      await controller.saveRemoteSubscriptionArticle(article.id);
      expect(port.saveActionIds[2], isNot(port.saveActionIds[1]));
    },
  );

  test('remote subscription adapter uses exact API25 and HNote requests', () async {
    final transport = _KnowledgeQueueTransport(<ApiTransportResponse>[
      _subscriptionPageResponse(<Object?>[_subscriptionPublicationJson()]),
      _subscriptionPageResponse(<Object?>[_subscriptionLibraryJson()]),
      _subscriptionPageResponse(<Object?>[_subscriptionArticleJson()]),
      _subscriptionObjectResponse(_subscriptionRevisionJson()),
      ApiTransportResponse(
        status: 200,
        headers: const <String, String>{'content-type': 'image/png'},
        body: Uint8List.fromList(<int>[137, 80, 78, 71]),
      ),
      _subscriptionObjectResponse(_subscriptionSaveReceiptJson(), status: 201),
      ApiTransportResponse(
        status: 200,
        body: <String, Object?>{
          'success': true,
          'data': _hNoteHeadJson(
            noteId: 'note-subscription-1',
            title: '保存后的笔记',
            revision: '1',
            cursor: '220',
          ),
        },
      ),
      _hNoteRawPartResponse(
        noteId: 'note-subscription-1',
        raw: '# 保存正文',
        revision: '1',
      ),
    ]);
    final port = RemoteMobileSubscriptionPort(
      apiClient: _knowledgeApiClient(transport),
      workspaceId: () => 'workspace opaque/+1',
    );

    final catalog = await port.loadCatalog();
    final article = catalog.publications.single.articles.single;
    expect(catalog.status, MobileSubscriptionResultStatus.success);
    expect(catalog.publications.single.sectionCount, 0);
    expect(catalog.publications.single.articleCount, 1);
    expect(article.rawBody, isEmpty);
    expect(article.summaryBody, '安全摘要');
    expect(article.createdAt, DateTime.utc(2026, 8, 7, 10));

    final detail = await port.loadArticle(article);
    expect(detail.item?.rawBody, '# 文章正文');
    expect(
      detail.item?.subscriptionArticleAssets.single.logicalPath,
      'images/article.png',
    );
    final asset = await port.loadArticleAsset(
      article: detail.item!,
      asset: detail.item!.subscriptionArticleAssets.single,
    );
    expect(asset.status, MobileSubscriptionResultStatus.success);
    expect(asset.asset?.mimeType, 'image/png');
    expect(asset.asset?.bytes, Uint8List.fromList(<int>[137, 80, 78, 71]));
    final saved = await port.saveArticleAsNote(
      article: article,
      actionId: 'user-action-1',
    );
    expect(saved.item?.remoteNoteId, 'note-subscription-1');
    expect(saved.item?.isReadOnly, isFalse);
    expect(saved.item?.source, V3MaterialSource.subscription);
    expect(saved.item?.remoteSourceKind, 'subscription_article');
    expect(saved.item?.rawBody, '# 保存正文');
    expect(saved.item?.summaryBody, isNull);
    expect(saved.item?.sproutReport, isNull);
    expect(saved.item?.sproutStatus, V3SproutTaskStatus.notStarted);
    expect(saved.item?.articleRevisionId, article.articleRevisionId);
    expect(saved.item?.outlinePartRevisionId, 'outline-revision-1');
    expect(saved.item?.germinationPartRevisionId, 'germination-revision-1');
    expect(saved.item?.createdAt, DateTime.utc(2026, 8, 8, 2, 30));
    expect(saved.item?.updatedAt, DateTime.utc(2026, 8, 8, 2, 30));

    expect(transport.requests.map((request) => request.url.path), <String>[
      '/api/v1/subscription/publications',
      '/api/v1/workspaces/workspace%20opaque%2F%2B1/subscription-library/publications',
      '/api/v1/subscription/articles',
      '/api/v1/subscription/articles/article-1/revisions/article-revision-1',
      '/api/v1/subscription/articles/article-1/revisions/article-revision-1/assets/asset-file-1',
      '/api/v1/workspaces/workspace%20opaque%2F%2B1/subscription-articles/article-1/save-as-note',
      '/api/v1/workspaces/workspace%20opaque%2F%2B1/notes/note-subscription-1',
      '/api/v1/workspaces/workspace%20opaque%2F%2B1/notes/note-subscription-1/parts/raw',
    ]);
    expect(
      transport.requests[2].url.queryParameters.containsKey('publicationId'),
      isFalse,
    );
    final saveRequest = transport.requests[5];
    expect(saveRequest.body, '{"articleRevisionId":"article-revision-1"}');
    expect(saveRequest.headers['X-Idempotency-Key'], isNotEmpty);
    expect(
      transport.requests[6].url.queryParameters['revisionId'],
      'note-revision-1',
    );
    expect(
      transport.requests.last.url.queryParameters['partRevisionId'],
      'raw-revision-1',
    );
  });

  test(
    'subscription replay reads current Note parts instead of birth receipt',
    () async {
      final current = _hNoteJson(
        noteId: 'note-subscription-1',
        title: '用户修改后的标题',
        raw: '用户编辑后的正文',
        revision: '9',
        cursor: '229',
        state: 'live',
      )..['sourceKind'] = 'subscription_article';
      final parts = current['parts']! as Map<String, Object?>;
      (parts['outline']! as Map<String, Object?>)['markdown'] = '已生成的纲要';
      (parts['germination']! as Map<String, Object?>)['markdown'] = '已生成的点火';
      final transport = _KnowledgeQueueTransport(<ApiTransportResponse>[
        _subscriptionObjectResponse(
          _subscriptionSaveReceiptJson()..['created'] = false,
        ),
        _subscriptionObjectResponse(current),
      ]);
      final port = RemoteMobileSubscriptionPort(
        apiClient: _knowledgeApiClient(transport),
        workspaceId: () => 'workspace-1',
      );
      final result = await port.saveArticleAsNote(
        article: _subscriptionArticleFixture(),
        actionId: 'repeat-save',
      );
      expect(result.status, MobileSubscriptionResultStatus.success);
      final note = result.item!;
      expect(note.title, '用户修改后的标题');
      expect(note.rawBody, '用户编辑后的正文');
      expect(note.summaryBody, '已生成的纲要');
      expect(note.sproutReport?.markdown, '已生成的点火');
      expect(note.noteRevisionId, 'note-revision-9');
      expect(note.rawPartRevisionId, 'raw-revision-9');
      expect(note.articleRevisionId, 'article-revision-1');
      expect(note.contentCursor, '229');
      expect(transport.requests, hasLength(2));
      expect(transport.requests.last.url.queryParameters, isEmpty);

      final refreshed = mapRemoteHNoteToFeedItem(
        SharedHNote.fromJson(current),
        localId: note.id,
        fallback: note,
        legacyRemoteRevision: 0,
      );
      expect(refreshed.articleId, note.articleId);
      expect(refreshed.articleRevisionId, note.articleRevisionId);
      expect(refreshed.publicationId, note.publicationId);
      expect(refreshed.author, note.author);
    },
  );

  for (final syncState in [
    NoteSyncState.synced,
    NoteSyncState.pending,
    NoteSyncState.conflict,
  ]) {
    test(
      'subscription adoption retains local identity and ${syncState.name} edits',
      () async {
        final article = _subscriptionArticleFixture();
        final local = V3FeedItem(
          id: 'local-subscription-note',
          title: '本地标题',
          source: V3MaterialSource.subscription,
          createdAt: DateTime.utc(2026, 8, 8),
          rawBody: '本地正文',
          summaryBody: '本地纲要',
          remoteNoteId: 'note-subscription-1',
          noteRevisionId: 'note-revision-1',
          rawPartRevisionId: 'raw-revision-1',
          copiedFromContentId: article.id,
          articleId: article.articleId,
          articleRevisionId: article.articleRevisionId,
          subscriptionArticleAssets: [
            V3SubscriptionArticleAssetRef(
              fileKey: 'image-1',
              logicalPath: 'assets/cover.png',
            ),
          ],
          syncState: syncState,
        );
        final remote = V3FeedItem(
          id: 'note-subscription-1',
          title: '云端当前标题',
          source: V3MaterialSource.subscription,
          createdAt: local.createdAt,
          rawBody: '云端当前正文',
          summaryBody: '云端当前纲要',
          remoteNoteId: local.remoteNoteId,
          noteRevisionId: 'note-revision-2',
          rawPartRevisionId: 'raw-revision-2',
          syncState: NoteSyncState.synced,
        );
        final controller = KnowledgeLibraryController(
          initialNotes: [local],
          subscriptionPort: _FakeMobileSubscriptionPort(
            catalogResult: MobileSubscriptionCatalogResult.success([
              _subscriptionPublicationFixture(article: article),
            ]),
            saveResults: [MobileSubscriptionActionResult.success(remote)],
          ),
        );
        addTearDown(controller.dispose);
        await controller.reloadSubscriptions();
        final result = await controller.saveRemoteSubscriptionArticle(
          article.id,
        );
        expect(result.status, MobileSubscriptionResultStatus.success);
        final adopted = result.item!;
        final expected = syncState == NoteSyncState.synced ? remote : local;
        expect(adopted.id, local.id);
        expect(adopted.title, expected.title);
        expect(adopted.rawBody, expected.rawBody);
        expect(adopted.summaryBody, expected.summaryBody);
        expect(adopted.syncState, expected.syncState);
        expect(adopted.articleRevisionId, local.articleRevisionId);
        expect(
          adopted.subscriptionArticleAssets.single.logicalPath,
          'assets/cover.png',
        );
        expect(controller.allDepositedNotes.map((note) => note.id), [local.id]);
        expect(controller.noteForId(article.id)?.isReadOnly, isTrue);
      },
    );
  }

  test(
    'saved subscription image uses Note authorization without Article refs',
    () async {
      final transport = _KnowledgeQueueTransport([
        ApiTransportResponse(
          status: 200,
          headers: const {'content-type': 'image/png'},
          body: Uint8List.fromList([137, 80, 78, 71]),
        ),
      ]);
      final port = RemoteMobileSubscriptionPort(
        apiClient: _knowledgeApiClient(transport),
        workspaceId: () => 'workspace opaque/+1',
      );
      final note = V3FeedItem(
        id: 'local-note',
        title: '已保存笔记',
        source: V3MaterialSource.subscription,
        createdAt: DateTime.utc(2026, 8, 8),
        rawBody: '![配图](assets/cover.png)',
        remoteNoteId: 'remote note/+1',
      );
      final result = await port.loadSavedNoteAsset(
        note: note,
        logicalPath: 'assets/cover.png',
      );
      expect(result.status, MobileSubscriptionResultStatus.success);
      expect(result.asset?.mimeType, 'image/png');
      final request = transport.requests.single;
      expect(
        request.url.path,
        '/api/v1/workspaces/workspace%20opaque%2F%2B1/notes/remote%20note%2F%2B1/subscription-assets',
      );
      expect(request.url.queryParameters, {'logicalPath': 'assets/cover.png'});
      expect(request.headers['Authorization'], 'Bearer access-token');
      expect(
        note.copyWith(remoteSourceKind: 'manual').isSavedSubscriptionNote,
        isFalse,
      );
      for (final path in [
        'assets/../private.png',
        'assets/\\private.png',
        'https://example.test/p.png',
      ]) {
        final invalid = await port.loadSavedNoteAsset(
          note: note,
          logicalPath: path,
        );
        expect(invalid.status, MobileSubscriptionResultStatus.failure);
      }
      expect(transport.requests, hasLength(1));
    },
  );

  test(
    'remote subscription adapter rejects a save receipt for another revision',
    () async {
      final transport = _KnowledgeQueueTransport(<ApiTransportResponse>[
        _subscriptionPageResponse(<Object?>[_subscriptionPublicationJson()]),
        _subscriptionPageResponse(<Object?>[_subscriptionLibraryJson()]),
        _subscriptionPageResponse(<Object?>[_subscriptionArticleJson()]),
        _subscriptionObjectResponse(<String, Object?>{
          ..._subscriptionSaveReceiptJson(),
          'articleRevisionId': 'article-revision-2',
        }, status: 201),
      ]);
      final port = RemoteMobileSubscriptionPort(
        apiClient: _knowledgeApiClient(transport),
        workspaceId: () => 'workspace-1',
      );

      final catalog = await port.loadCatalog();
      final result = await port.saveArticleAsNote(
        article: catalog.publications.single.articles.single,
        actionId: 'save-wrong-revision',
      );

      expect(result.status, MobileSubscriptionResultStatus.failure);
      expect(result.errorCode, 'SUBSCRIPTION_SAVE_RECEIPT_INVALID');
      expect(transport.requests, hasLength(4));
    },
  );

  test(
    'remote catalog rejects a first-screen Publication without counters',
    () async {
      final transport = _KnowledgeQueueTransport(<ApiTransportResponse>[
        _subscriptionPageResponse(<Object?>[
          _subscriptionPublicationJson(sectionCount: null, articleCount: null),
        ]),
        _subscriptionPageResponse(<Object?>[_subscriptionLibraryJson()]),
        _subscriptionPageResponse(<Object?>[_subscriptionArticleJson()]),
      ]);
      final port = RemoteMobileSubscriptionPort(
        apiClient: _knowledgeApiClient(transport),
        workspaceId: () => 'workspace-1',
      );

      final catalog = await port.loadCatalog();

      expect(catalog.status, MobileSubscriptionResultStatus.failure);
      expect(catalog.errorCode, 'SUBSCRIPTION_RESPONSE_INVALID');
      expect(transport.requests, hasLength(3));
    },
  );

  test('remote catalog rejects an empty first screen', () async {
    final transport = _KnowledgeQueueTransport(<ApiTransportResponse>[
      _subscriptionPageResponse(const <Object?>[]),
      _subscriptionPageResponse(const <Object?>[]),
      _subscriptionPageResponse(const <Object?>[]),
    ]);
    final port = RemoteMobileSubscriptionPort(
      apiClient: _knowledgeApiClient(transport),
      workspaceId: () => 'workspace-1',
    );

    final catalog = await port.loadCatalog();

    expect(catalog.status, MobileSubscriptionResultStatus.failure);
    expect(catalog.errorCode, 'SUBSCRIPTION_CATALOG_NOT_FOUND');
    expect(transport.requests, hasLength(3));
  });

  test(
    'remote catalog shows the concurrent first screen then completes global articles',
    () async {
      final publicationOne = _subscriptionPublicationJson(
        publicationId: 'publication-1',
        title: '第一本',
        updatedAt: '2026-08-01T10:00:00Z',
      );
      final publicationTwo = _subscriptionPublicationJson(
        publicationId: 'publication-2',
        title: '第二本',
        updatedAt: '2026-08-20T10:00:00Z',
      );
      final libraryOnlyPublication = _subscriptionPublicationJson(
        publicationId: 'publication-3',
        title: '第三本',
        updatedAt: '2026-08-10T10:00:00Z',
      );
      final transport = _KnowledgeQueueTransport(<ApiTransportResponse>[
        _subscriptionPageResponse(<Object?>[
          publicationOne,
        ], nextCursor: 'publication-page-2'),
        _subscriptionPageResponse(<Object?>[
          _subscriptionLibraryJson(publication: publicationOne),
          _subscriptionLibraryJson(publication: libraryOnlyPublication),
        ]),
        _subscriptionPageResponse(<Object?>[
          _subscriptionArticleJson(
            articleId: 'article-1',
            publicationId: 'publication-1',
          ),
        ], nextCursor: 'article-page-2'),
        _subscriptionPageResponse(<Object?>[publicationTwo]),
        _subscriptionPageResponse(<Object?>[
          _subscriptionArticleJson(
            articleId: 'article-2',
            publicationId: 'publication-2',
          ),
        ]),
      ]);
      final port = RemoteMobileSubscriptionPort(
        apiClient: _knowledgeApiClient(transport),
        workspaceId: () => 'workspace-1',
      );

      final firstScreen = await port.loadCatalog();

      expect(firstScreen.status, MobileSubscriptionResultStatus.success);
      expect(
        firstScreen.publications.map((item) => item.publicationId),
        <String>['publication-1', 'publication-3'],
      );
      expect(
        firstScreen.publications[0].articles.single.createdAt,
        DateTime.utc(2026, 8, 1, 10),
      );
      expect(transport.requests.map((request) => request.url.path), <String>[
        '/api/v1/subscription/publications',
        '/api/v1/workspaces/workspace-1/subscription-library/publications',
        '/api/v1/subscription/articles',
      ]);
      expect(
        transport.requests[2].url.queryParameters.containsKey('publicationId'),
        isFalse,
      );

      final complete = await port.loadCompleteCatalog();

      expect(complete.status, MobileSubscriptionResultStatus.success);
      expect(transport.requests.map((request) => request.url.path), <String>[
        '/api/v1/subscription/publications',
        '/api/v1/workspaces/workspace-1/subscription-library/publications',
        '/api/v1/subscription/articles',
        '/api/v1/subscription/publications',
        '/api/v1/subscription/articles',
      ]);
      expect(
        transport.requests.map(
          (request) => request.url.queryParameters['limit'],
        ),
        everyElement('100'),
      );
      expect(
        transport.requests[3].url.queryParameters['cursor'],
        'publication-page-2',
      );
      expect(
        transport.requests[4].url.queryParameters['cursor'],
        'article-page-2',
      );
    },
  );

  test(
    'remote catalog keeps server-derived counts without Section scans',
    () async {
      final transport = _KnowledgeQueueTransport(<ApiTransportResponse>[
        _subscriptionPageResponse(<Object?>[
          _subscriptionPublicationJson(sectionCount: 2, articleCount: 1),
        ]),
        _subscriptionPageResponse(const <Object?>[]),
        _subscriptionPageResponse(<Object?>[_subscriptionArticleJson()]),
      ]);
      final port = RemoteMobileSubscriptionPort(
        apiClient: _knowledgeApiClient(transport),
        workspaceId: () => 'workspace-1',
      );

      final catalog = await port.loadCatalog();

      expect(catalog.status, MobileSubscriptionResultStatus.success);
      expect(catalog.publications.single.sectionCount, 2);
      expect(catalog.publications.single.articleCount, 1);
      expect(transport.requests.map((request) => request.url.path), <String>[
        '/api/v1/subscription/publications',
        '/api/v1/workspaces/workspace-1/subscription-library/publications',
        '/api/v1/subscription/articles',
      ]);
    },
  );

  test('remote catalog skips unavailable library publications', () async {
    final unavailablePublication = _subscriptionPublicationJson(
      sectionCount: 99,
      articleCount: 99,
    );
    final transport = _KnowledgeQueueTransport(<ApiTransportResponse>[
      _subscriptionPageResponse(<Object?>[unavailablePublication]),
      _subscriptionPageResponse(<Object?>[
        _subscriptionLibraryJson(
          publication: unavailablePublication,
          availability: 'unavailable',
          unavailableReason: 'held',
        ),
      ]),
      _subscriptionPageResponse(<Object?>[_subscriptionArticleJson()]),
    ]);
    final port = RemoteMobileSubscriptionPort(
      apiClient: _knowledgeApiClient(transport),
      workspaceId: () => 'workspace-1',
    );

    final catalog = await port.loadCatalog();

    expect(catalog.status, MobileSubscriptionResultStatus.success);
    expect(catalog.publications.single.available, isFalse);
    expect(catalog.publications.single.articles, isEmpty);
    expect(transport.requests, hasLength(3));
  });

  test('remote catalog rejects more than 100 opaque cursor pages', () async {
    final transport = _KnowledgeQueueTransport(<ApiTransportResponse>[
      _subscriptionPageResponse(<Object?>[
        _subscriptionPublicationJson(
          publicationId: 'publication-0',
          title: '出版物 0',
        ),
      ], nextCursor: 'cursor-1'),
      _subscriptionPageResponse(<Object?>[
        _subscriptionArticleJson(publicationId: 'publication-0'),
      ]),
      ...List<ApiTransportResponse>.generate(
        99,
        (index) => _subscriptionPageResponse(<Object?>[
          _subscriptionPublicationJson(
            publicationId: 'publication-${index + 1}',
            title: '出版物 ${index + 1}',
          ),
        ], nextCursor: 'cursor-${index + 2}'),
      ),
    ]);
    final port = RemoteMobileSubscriptionPort(
      apiClient: _knowledgeApiClient(transport),
      workspaceId: () => null,
    );

    final firstScreen = await port.loadCatalog();
    final catalog = await port.loadCompleteCatalog();

    expect(firstScreen.status, MobileSubscriptionResultStatus.success);
    expect(catalog.status, MobileSubscriptionResultStatus.failure);
    expect(catalog.errorCode, 'SUBSCRIPTION_PAGE_LIMIT_EXCEEDED');
    expect(transport.requests, hasLength(101));
  });

  test(
    'remote catalog stays visible when Workspace context is unavailable',
    () async {
      final transport = _KnowledgeQueueTransport(<ApiTransportResponse>[
        _subscriptionPageResponse(<Object?>[_subscriptionPublicationJson()]),
        _subscriptionPageResponse(<Object?>[_subscriptionArticleJson()]),
      ]);
      final port = RemoteMobileSubscriptionPort(
        apiClient: _knowledgeApiClient(transport),
        workspaceId: () => null,
      );

      final catalog = await port.loadCatalog();

      expect(catalog.status, MobileSubscriptionResultStatus.success);
      expect(catalog.publications.single.followed, isFalse);
      expect(catalog.publications.single.articles, hasLength(1));
      expect(transport.requests.map((request) => request.url.path), <String>[
        '/api/v1/subscription/publications',
        '/api/v1/subscription/articles',
      ]);
      expect(
        transport.requests
            .firstWhere(
              (request) => request.url.path == '/api/v1/subscription/articles',
            )
            .url
            .queryParameters
            .containsKey('publicationId'),
        isFalse,
      );
    },
  );

  test(
    'graph source becomes empty only after a successful remote read',
    () async {
      final port = _QueuedRemoteListKnowledgeNotePort(2);
      final controller = KnowledgeLibraryController(
        notePort: port,
        includeDemoFixtures: false,
      );
      addTearDown(controller.dispose);

      final initialization = controller.initialize();
      expect(
        controller.graphReadModel.sourceState,
        KnowledgeGraphSourceState.loading,
      );

      port.complete(
        0,
        const KnowledgeNoteRemoteLoadResult.failure('REMOTE_NOTES_FAILED'),
      );
      await initialization;

      expect(
        controller.graphReadModel.sourceState,
        KnowledgeGraphSourceState.failure,
      );
      expect(controller.graphReadModel.sourceErrorCode, 'REMOTE_NOTES_FAILED');
      expect(controller.graphReadModel.notes, isEmpty);

      final retry = controller.synchronizeWorkspaceContent(forceSnapshot: true);
      await Future<void>.delayed(Duration.zero);
      expect(
        controller.graphReadModel.sourceState,
        KnowledgeGraphSourceState.loading,
      );
      port.complete(
        1,
        const KnowledgeNoteRemoteLoadResult.success(<V3FeedItem>[]),
      );
      expect(await retry, isTrue);

      expect(
        controller.graphReadModel.sourceState,
        KnowledgeGraphSourceState.ready,
      );
      expect(controller.graphReadModel.sourceErrorCode, isNull);
      expect(controller.graphReadModel.notes, isEmpty);
    },
  );

  test('duplicate Workspace refreshes share one remote load', () async {
    final port = _QueuedRemoteListKnowledgeNotePort(1);
    final controller = KnowledgeLibraryController(
      notePort: port,
      includeDemoFixtures: false,
    );
    addTearDown(controller.dispose);

    final first = controller.synchronizeWorkspaceContent();
    final duplicate = controller.synchronizeWorkspaceContent();
    await Future<void>.delayed(Duration.zero);

    expect(port.requestCount, 1);
    port.complete(
      0,
      const KnowledgeNoteRemoteLoadResult.success(<V3FeedItem>[]),
    );
    expect(await first, isTrue);
    expect(await duplicate, isTrue);
    expect(port.requestCount, 1);
  });

  test('force refresh during an active pass adds one follow-up pass', () async {
    final port = _QueuedRemoteListKnowledgeNotePort(2);
    final controller = KnowledgeLibraryController(
      notePort: port,
      includeDemoFixtures: false,
    );
    addTearDown(controller.dispose);

    final first = controller.synchronizeWorkspaceContent();
    final forced = controller.synchronizeWorkspaceContent(forceSnapshot: true);
    controller.synchronizeWorkspaceContent(forceSnapshot: true);
    await Future<void>.delayed(Duration.zero);
    expect(port.requestCount, 1);

    port.complete(
      0,
      const KnowledgeNoteRemoteLoadResult.success(<V3FeedItem>[]),
    );
    await Future<void>.delayed(Duration.zero);
    expect(port.requestCount, 2);
    port.complete(
      1,
      const KnowledgeNoteRemoteLoadResult.success(<V3FeedItem>[]),
    );

    expect(await first, isTrue);
    expect(await forced, isTrue);
    expect(port.requestCount, 2);
  });
}

V3FeedItem _subscriptionArticleFixture() {
  return V3FeedItem(
    id: 'subscription-article-local-1',
    title: 'API25 文章',
    source: V3MaterialSource.knowledgeSquare,
    createdAt: DateTime.utc(2026, 8, 7, 9),
    rawBody: '',
    summaryBody: '安全摘要',
    ownership: V3NoteOwnership.knowledgeSquare,
    publicationId: 'publication-1',
    articleId: 'article-1',
    articleRevisionId: 'article-revision-1',
    author: '花火编辑部',
  );
}

MobileSubscriptionPublication _subscriptionPublicationFixture({
  required V3FeedItem article,
  bool followed = true,
}) {
  return MobileSubscriptionPublication(
    publicationId: 'publication-1',
    title: '无限花火日报',
    sectionCount: 2,
    articleCount: 1,
    updatedAt: DateTime.utc(2026, 8, 7, 10),
    articles: <V3FeedItem>[article],
    followed: followed,
    available: true,
    summary: '出版物摘要',
  );
}

V3FeedItem _savedSubscriptionNote(V3FeedItem article) {
  return V3FeedItem(
    id: 'note-subscription-1',
    title: article.title,
    source: V3MaterialSource.subscription,
    createdAt: DateTime.utc(2026, 8, 7, 11),
    rawBody: '# 保存正文',
    ownership: V3NoteOwnership.mine,
    copiedFromContentId: article.id,
    remoteNoteId: 'note-subscription-1',
    noteRevisionId: 'note-revision-1',
    rawPartRevisionId: 'raw-revision-1',
    etag: '"note-1"',
    contentCursor: '220',
    publicationId: article.publicationId,
    articleId: article.articleId,
    articleRevisionId: article.articleRevisionId,
    syncState: NoteSyncState.synced,
  );
}

final class _FakeMobileSubscriptionPort implements MobileSubscriptionPort {
  _FakeMobileSubscriptionPort({
    required this.catalogResult,
    List<MobileSubscriptionActionResult>? followResults,
    List<MobileSubscriptionActionResult>? articleResults,
    List<MobileSubscriptionActionResult>? saveResults,
    this.loadEvents,
  }) : followResults = followResults ?? <MobileSubscriptionActionResult>[],
       articleResults = articleResults ?? <MobileSubscriptionActionResult>[],
       saveResults = saveResults ?? <MobileSubscriptionActionResult>[];

  MobileSubscriptionCatalogResult catalogResult;
  final List<MobileSubscriptionActionResult> followResults;
  final List<MobileSubscriptionActionResult> articleResults;
  final List<MobileSubscriptionActionResult> saveResults;
  final List<String>? loadEvents;
  final List<String> followActionIds = <String>[];
  final List<String> saveActionIds = <String>[];
  final List<String> loadedArticleIds = <String>[];

  @override
  bool get isDemo => false;

  @override
  Future<MobileSubscriptionCatalogResult> loadCatalog() async {
    loadEvents?.add('catalog');
    return catalogResult;
  }

  @override
  Future<MobileSubscriptionActionResult> loadArticle(V3FeedItem article) async {
    loadedArticleIds.add(article.id);
    return articleResults.removeAt(0);
  }

  @override
  Future<MobileSubscriptionArticleAssetResult> loadArticleAsset({
    required V3FeedItem article,
    required V3SubscriptionArticleAssetRef asset,
  }) async => const MobileSubscriptionArticleAssetResult.unavailable(
    'SUBSCRIPTION_DEMO_ONLY',
  );

  @override
  Future<MobileSubscriptionActionResult> saveArticleAsNote({
    required V3FeedItem article,
    required String actionId,
  }) async {
    saveActionIds.add(actionId);
    return saveResults.removeAt(0);
  }

  @override
  Future<MobileSubscriptionActionResult> setPublicationFollowed({
    required String publicationId,
    required bool followed,
    required String actionId,
  }) async {
    followActionIds.add(actionId);
    return followResults.removeAt(0);
  }
}

ApiTransportResponse _subscriptionPageResponse(
  List<Object?> items, {
  String? nextCursor,
}) {
  return ApiTransportResponse(
    status: 200,
    body: <String, Object?>{
      'success': true,
      'data': <String, Object?>{
        'items': items,
        if (nextCursor != null) 'nextCursor': nextCursor,
      },
    },
  );
}

ApiTransportResponse _subscriptionObjectResponse(
  Map<String, Object?> data, {
  int status = 200,
}) {
  return ApiTransportResponse(
    status: status,
    body: <String, Object?>{'success': true, 'data': data},
  );
}

Map<String, Object?> _subscriptionPublicationJson({
  String publicationId = 'publication-1',
  String title = '无限花火日报',
  String? description = '出版物摘要',
  String updatedAt = '2026-08-07T10:00:00Z',
  int? sectionCount = 0,
  int? articleCount = 1,
}) => <String, Object?>{
  'publicationId': publicationId,
  'title': title,
  if (description != null) 'description': description,
  'lifecycle': 'active',
  'updatedAt': updatedAt,
  if (sectionCount != null) 'sectionCount': sectionCount,
  if (articleCount != null) 'articleCount': articleCount,
};

Map<String, Object?> _subscriptionArticleJson({
  String articleId = 'article-1',
  String publicationId = 'publication-1',
  String? sectionId = 'section-1',
  String title = 'API25 文章',
  String? publishedAt,
}) => <String, Object?>{
  'articleId': articleId,
  'publicationId': publicationId,
  if (sectionId != null) 'sectionId': sectionId,
  'currentArticleRevisionId': 'article-revision-1',
  'title': title,
  'summary': '安全摘要',
  if (publishedAt != null) 'publishedAt': publishedAt,
  'lifecycle': 'active',
};

Map<String, Object?> _subscriptionRevisionJson() => <String, Object?>{
  'articleId': 'article-1',
  'articleRevisionId': 'article-revision-1',
  'title': 'API25 文章',
  'contentMarkdown': '# 文章正文',
  'etag': '"article-1"',
  'assetRefs': <Object?>[
    <String, Object?>{
      'fileKey': 'asset-file-1',
      'logicalPath': 'images/article.png',
    },
  ],
};

Map<String, Object?> _subscriptionLibraryJson({
  Map<String, Object?>? publication,
  String availability = 'available',
  String? unavailableReason,
}) => <String, Object?>{
  'publication': publication ?? _subscriptionPublicationJson(),
  'followedAt': '2026-08-07T10:01:00Z',
  'availability': availability,
  if (unavailableReason != null) 'unavailableReason': unavailableReason,
};

Map<String, Object?> _subscriptionSaveReceiptJson() => <String, Object?>{
  'noteId': 'note-subscription-1',
  'noteRevisionId': 'note-revision-1',
  'rawPartRevisionId': 'raw-revision-1',
  'outlinePartRevisionId': 'outline-revision-1',
  'germinationPartRevisionId': 'germination-revision-1',
  'articleId': 'article-1',
  'articleRevisionId': 'article-revision-1',
  'created': true,
  'lifecycle': 'live',
  'etag': '"note-1"',
  'contentCursor': '220',
};

final class _ToggleFailingSnapshotStore extends LocalDatabaseSnapshotStore {
  _ToggleFailingSnapshotStore({required super.file});

  bool failWrites = false;

  @override
  void save({
    required int schemaVersion,
    required Map<LocalTableName, Map<String, LocalDatabaseRecord>> tables,
  }) {
    if (failWrites) throw const FileSystemException('forced failure');
    super.save(schemaVersion: schemaVersion, tables: tables);
  }
}

final class _GatedHotspotRepository implements HotspotNoteRepository {
  final Completer<List<V3FeedItem>> _completer = Completer<List<V3FeedItem>>();

  void complete(List<V3FeedItem> notes) => _completer.complete(notes);

  @override
  Future<List<V3FeedItem>> loadHotspots() => _completer.future;
}

final class _SequencedHotspotRepository implements HotspotNoteRepository {
  const _SequencedHotspotRepository(this.events);

  final List<String> events;

  @override
  Future<List<V3FeedItem>> loadHotspots() async {
    events.add('home');
    return const <V3FeedItem>[];
  }
}

V3FeedItem _pendingNote({
  required String id,
  required String title,
  required String body,
  int localRevision = 1,
  int? remoteRevision,
  String? folderId,
}) {
  return V3FeedItem(
    id: id,
    title: title,
    source: V3MaterialSource.note,
    createdAt: DateTime(2026, 7, 15, 9),
    rawBody: body,
    localRevision: localRevision,
    remoteRevision: remoteRevision,
    folderId: folderId,
    syncState: NoteSyncState.pending,
  );
}

V3FeedItem _remoteNote({
  required String id,
  required String title,
  required String body,
  required int remoteRevision,
}) {
  return V3FeedItem(
    id: id,
    title: title,
    source: V3MaterialSource.note,
    createdAt: DateTime(2026, 7, 15, 9),
    updatedAt: DateTime(2026, 7, 15, 10),
    rawBody: body,
    remoteRevision: remoteRevision,
    syncState: NoteSyncState.synced,
  );
}

ApiClient _knowledgeApiClient(_KnowledgeQueueTransport transport) {
  return ApiClient(
    config: ApiClientConfig(
      baseUrl: Uri.parse('https://api.example.test'),
      clientVersion: '0.1.0',
      deviceId: 'mobile-test',
      platform: 'ios',
      locale: 'zh-CN',
      getAccessToken: () => 'access-token',
      traceIdFactory: () => 'trace-knowledge-test',
    ),
    transport: transport,
  );
}

Map<String, Object?> _hNoteJson({
  required String noteId,
  required String title,
  required String raw,
  required String revision,
  required String cursor,
  String state = 'active',
}) {
  return <String, Object?>{
    'noteId': noteId,
    'workspaceId': 'workspace-1',
    'folderId': null,
    'title': title,
    'state': state,
    'noteRevisionId': 'note-revision-$revision',
    'parts': <String, Object?>{
      'raw': <String, Object?>{
        'partRevisionId': 'raw-revision-$revision',
        'markdown': raw,
        'contentHash': 'raw-hash-$revision',
      },
      'outline': <String, Object?>{
        'partRevisionId': 'outline-revision-$revision',
        'markdown': '',
        'contentHash': 'outline-hash-$revision',
      },
      'germination': <String, Object?>{
        'partRevisionId': 'germination-revision-$revision',
        'markdown': '',
        'contentHash': 'germination-hash-$revision',
      },
    },
    'resourceRefs': const <Object?>[],
    'etag': '"note-$revision"',
    'contentCursor': cursor,
    'createdAt': '2026-08-17T08:00:00Z',
    'updatedAt': '2026-08-17T08:01:00Z',
  };
}

Map<String, Object?> _hNoteHeadJson({
  required String noteId,
  required String title,
  required String revision,
  required String cursor,
}) {
  return <String, Object?>{
    'noteId': noteId,
    'workspaceId': 'workspace-1',
    'folderId': null,
    'title': title,
    'state': 'live',
    'noteRevisionId': 'note-revision-$revision',
    'rawPartRevisionId': 'raw-revision-$revision',
    'outlinePartRevisionId': 'outline-revision-$revision',
    'germinationPartRevisionId': 'germination-revision-$revision',
    'resourceRefs': const <Object?>[],
    'etag': '"note-$revision"',
    'contentCursor': cursor,
    'createdAt': '2026-08-08T02:30:00Z',
    'updatedAt': '2026-08-08T02:30:00Z',
  };
}

ApiTransportResponse _hNoteRawPartResponse({
  required String noteId,
  required String raw,
  required String revision,
}) {
  return ApiTransportResponse(
    status: 200,
    body: <String, Object?>{
      'success': true,
      'data': <String, Object?>{
        'noteId': noteId,
        'part': 'raw',
        'partRevisionId': 'raw-revision-$revision',
        'contentMarkdown': raw,
        'etag': '"part-$revision"',
      },
    },
  );
}

ApiTransportResponse _hNotePartResponse({
  required String noteId,
  required String part,
  required String markdown,
  required String revision,
}) {
  return ApiTransportResponse(
    status: 200,
    body: <String, Object?>{
      'success': true,
      'data': <String, Object?>{
        'noteId': noteId,
        'part': part,
        'partRevisionId': '$part-revision-$revision',
        'contentMarkdown': markdown,
        'contentSha256': 'sha256:$part-$revision',
        'etag': '"$part-$revision"',
      },
    },
  );
}

Map<String, Object?> _deployedNoteJson({
  required String noteId,
  required String title,
  required int metadataVersion,
  String? etag,
}) {
  return <String, Object?>{
    'noteId': noteId,
    'workspaceId': 'workspace-1',
    'sourceKind': 'manual',
    'sourceObjectId': noteId,
    'title': title,
    'metadataVersion': metadataVersion,
    'lifecycle': 'active',
    'agentVisibility': 'visible',
    'createdAt': '2026-08-08T02:30:00Z',
    'updatedAt': '2026-08-08T02:30:00Z',
    if (etag != null) 'etag': etag,
  };
}

ApiTransportResponse _deployedNoteDetailResponse(
  Map<String, Object?> note, {
  String? etag,
}) {
  return ApiTransportResponse(
    status: 200,
    headers: <String, String>{if (etag != null) 'ETag': etag},
    body: <String, Object?>{
      'success': true,
      'data': <String, Object?>{'note': note, 'parts': const <Object?>[]},
    },
  );
}

ApiTransportResponse _deployedRawPartResponse({
  required String noteId,
  required String raw,
  required String partRevisionId,
  required String etag,
}) {
  return ApiTransportResponse(
    status: 200,
    headers: <String, String>{'ETag': etag},
    body: <String, Object?>{
      'success': true,
      'data': <String, Object?>{
        'part': <String, Object?>{
          'noteId': noteId,
          'part': 'raw',
          'currentPartRevisionId': partRevisionId,
          'status': 'ready',
        },
        'revision': <String, Object?>{
          'partRevisionId': partRevisionId,
          'noteId': noteId,
          'part': 'raw',
          'revision': 1,
        },
        'contentMarkdown': raw,
      },
    },
  );
}

final class _KnowledgeQueueTransport implements ApiTransport {
  _KnowledgeQueueTransport(List<ApiTransportResponse> responses)
    : _responses = List<ApiTransportResponse>.of(responses);

  final List<ApiTransportResponse> _responses;
  final List<ApiTransportRequest> requests = <ApiTransportRequest>[];

  @override
  Future<ApiTransportResponse> send(ApiTransportRequest request) async {
    requests.add(request);
    if (_responses.isEmpty) throw StateError('Unexpected knowledge API call');
    return _responses.removeAt(0);
  }
}

final class _QueueKnowledgeNotePort implements KnowledgeNotePort {
  _QueueKnowledgeNotePort(List<KnowledgeNotePortResult> responses)
    : _responses = List<KnowledgeNotePortResult>.of(responses);

  final List<KnowledgeNotePortResult> _responses;
  List<KnowledgeNotePortResult> get responses => _responses;
  final List<KnowledgeNoteUpdateRequest> requests =
      <KnowledgeNoteUpdateRequest>[];

  @override
  Future<KnowledgeNotePortResult> updateNote(
    KnowledgeNoteUpdateRequest request,
  ) async {
    requests.add(request);
    return _responses.removeAt(0);
  }
}

final class _FakeLifecycleKnowledgeNotePort
    implements KnowledgeNotePort, KnowledgeNoteLifecyclePort {
  _FakeLifecycleKnowledgeNotePort({
    this.failFirstTombstone = false,
    this.failTombstoneOnCall,
    this.failRestoreOnCall,
  });

  bool failFirstTombstone;
  final int? failTombstoneOnCall;
  final int? failRestoreOnCall;
  final List<String> tombstoneKeys = <String>[];
  final List<String> restoreKeys = <String>[];

  @override
  Future<KnowledgeNotePortResult> updateNote(
    KnowledgeNoteUpdateRequest request,
  ) async => const KnowledgeNotePortResult.unavailable();

  @override
  Future<KnowledgeNoteLifecycleResult> tombstoneNote({
    required V3FeedItem note,
    required String idempotencyKey,
  }) async {
    tombstoneKeys.add(idempotencyKey);
    if (failFirstTombstone ||
        (failTombstoneOnCall != null &&
            tombstoneKeys.length == failTombstoneOnCall)) {
      failFirstTombstone = false;
      return const KnowledgeNoteLifecycleResult.failure(
        'WORKSPACE_NOTE_TOMBSTONE_FAILED',
      );
    }
    return const KnowledgeNoteLifecycleResult.success(
      noteRevisionId: 'note-revision-tombstoned',
      rawPartRevisionId: 'raw-revision-tombstoned',
      etag: '"note-tombstoned"',
      contentCursor: '111',
    );
  }

  @override
  Future<KnowledgeNoteLifecycleResult> restoreNote({
    required V3FeedItem note,
    required String idempotencyKey,
  }) async {
    restoreKeys.add(idempotencyKey);
    if (failRestoreOnCall != null && restoreKeys.length == failRestoreOnCall) {
      return const KnowledgeNoteLifecycleResult.failure(
        'WORKSPACE_NOTE_RESTORE_FAILED',
      );
    }
    return KnowledgeNoteLifecycleResult.success(
      note: note.copyWith(
        noteRevisionId: 'note-revision-restored',
        rawPartRevisionId: 'raw-revision-restored',
        etag: '"note-restored"',
        contentCursor: '112',
        syncState: NoteSyncState.synced,
      ),
      noteRevisionId: 'note-revision-restored',
      rawPartRevisionId: 'raw-revision-restored',
      etag: '"note-restored"',
      contentCursor: '112',
    );
  }
}

final class _AutoSyncKnowledgeNotePort
    implements KnowledgeNotePort, KnowledgeNoteRemoteListPort {
  final List<KnowledgeNoteUpdateRequest> requests =
      <KnowledgeNoteUpdateRequest>[];

  @override
  Future<KnowledgeNotePortResult> updateNote(
    KnowledgeNoteUpdateRequest request,
  ) async {
    requests.add(request);
    final local = request.localNote!;
    return KnowledgeNotePortResult.success(
      local.copyWith(
        remoteNoteId: 'remote-${local.id}',
        noteRevisionId: 'note-revision-1',
        rawPartRevisionId: 'raw-revision-1',
        etag: '"note-1"',
        contentCursor: '1',
        remoteRevision: 1,
        syncState: NoteSyncState.synced,
      ),
    );
  }

  @override
  Future<KnowledgeNoteRemoteLoadResult> loadNotes() async {
    return const KnowledgeNoteRemoteLoadResult.success(<V3FeedItem>[]);
  }
}

final class _QueuedRemoteListKnowledgeNotePort
    implements KnowledgeNotePort, KnowledgeNoteRemoteListPort {
  _QueuedRemoteListKnowledgeNotePort(int responseCount)
    : _responses = List<Completer<KnowledgeNoteRemoteLoadResult>>.generate(
        responseCount,
        (_) => Completer<KnowledgeNoteRemoteLoadResult>(),
      );

  final List<Completer<KnowledgeNoteRemoteLoadResult>> _responses;
  int _requestIndex = 0;

  int get requestCount => _requestIndex;

  void complete(int index, KnowledgeNoteRemoteLoadResult result) {
    _responses[index].complete(result);
  }

  @override
  Future<KnowledgeNoteRemoteLoadResult> loadNotes() =>
      _responses[_requestIndex++].future;

  @override
  Future<KnowledgeNotePortResult> updateNote(
    KnowledgeNoteUpdateRequest request,
  ) async => const KnowledgeNotePortResult.unavailable();
}

final class _CompletingKnowledgeNotePort implements KnowledgeNotePort {
  final Completer<KnowledgeNotePortResult> _completer =
      Completer<KnowledgeNotePortResult>();

  void complete(KnowledgeNotePortResult result) => _completer.complete(result);

  @override
  Future<KnowledgeNotePortResult> updateNote(
    KnowledgeNoteUpdateRequest request,
  ) {
    return _completer.future;
  }
}

final class _RemoteDetailKnowledgeNotePort
    implements KnowledgeNotePort, KnowledgeNoteRemoteDetailPort {
  const _RemoteDetailKnowledgeNotePort(this.remote);

  final V3FeedItem remote;

  @override
  Future<KnowledgeNotePortResult> loadNote(
    String remoteNoteId, {
    required String localId,
    V3FeedItem? fallback,
  }) async => KnowledgeNotePortResult.success(remote);

  @override
  Future<KnowledgeNotePortResult> updateNote(
    KnowledgeNoteUpdateRequest request,
  ) async => const KnowledgeNotePortResult.unavailable();
}

final class _GatedRemoteDetailKnowledgeNotePort
    implements KnowledgeNotePort, KnowledgeNoteRemoteDetailPort {
  final Completer<void> _requestStarted = Completer<void>();
  final Completer<KnowledgeNotePortResult> _result =
      Completer<KnowledgeNotePortResult>();

  Future<void> get requestStarted => _requestStarted.future;

  void complete(V3FeedItem remote) {
    _result.complete(KnowledgeNotePortResult.success(remote));
  }

  @override
  Future<KnowledgeNotePortResult> loadNote(
    String remoteNoteId, {
    required String localId,
    V3FeedItem? fallback,
  }) {
    if (!_requestStarted.isCompleted) _requestStarted.complete();
    return _result.future;
  }

  @override
  Future<KnowledgeNotePortResult> updateNote(
    KnowledgeNoteUpdateRequest request,
  ) async => const KnowledgeNotePortResult.unavailable();
}

final class _FailingKnowledgeLibraryCache implements KnowledgeLibraryCache {
  @override
  Future<List<V3FeedItem>?> load() async => null;

  @override
  Future<void> save(List<V3FeedItem> notes) async {
    throw const FileSystemException('test cache failure');
  }
}

final class _RetryableLoadKnowledgeLibraryCache
    implements KnowledgeLibraryCache {
  _RetryableLoadKnowledgeLibraryCache(this.notes);

  final List<V3FeedItem> notes;
  int loadCalls = 0;
  int saveCalls = 0;

  @override
  Future<List<V3FeedItem>?> load() async {
    loadCalls += 1;
    if (loadCalls == 1) throw const FileSystemException('load failed');
    return List<V3FeedItem>.of(notes);
  }

  @override
  Future<void> save(List<V3FeedItem> notes) async {
    saveCalls += 1;
  }
}

final class _GatedLoadKnowledgeLibraryCache implements KnowledgeLibraryCache {
  _GatedLoadKnowledgeLibraryCache(this.notes);

  final List<V3FeedItem> notes;
  final Completer<void> _loadStarted = Completer<void>();
  final Completer<void> _loadReleased = Completer<void>();
  int saveCalls = 0;

  Future<void> get loadStarted => _loadStarted.future;

  void releaseLoad() {
    if (!_loadReleased.isCompleted) _loadReleased.complete();
  }

  @override
  Future<List<V3FeedItem>?> load() async {
    if (!_loadStarted.isCompleted) _loadStarted.complete();
    await _loadReleased.future;
    return List<V3FeedItem>.of(notes);
  }

  @override
  Future<void> save(List<V3FeedItem> notes) async {
    saveCalls += 1;
  }
}

final class _MemoryKnowledgeLibraryCache implements KnowledgeLibraryCache {
  List<V3FeedItem>? notes;
  int saveCalls = 0;

  @override
  Future<List<V3FeedItem>?> load() async => notes;

  @override
  Future<void> save(List<V3FeedItem> notes) async {
    saveCalls += 1;
    this.notes = List<V3FeedItem>.of(notes);
  }
}

final class _FailOnSaveNumberKnowledgeLibraryCache
    extends _MemoryKnowledgeLibraryCache {
  _FailOnSaveNumberKnowledgeLibraryCache({required int failOnSave})
    : failOnSaves = <int>{failOnSave};

  _FailOnSaveNumberKnowledgeLibraryCache.onSaves(Set<int> failOnSaves)
    : failOnSaves = Set<int>.unmodifiable(failOnSaves);

  final Set<int> failOnSaves;
  var _saveCount = 0;

  @override
  Future<void> save(List<V3FeedItem> notes) async {
    _saveCount++;
    if (failOnSaves.contains(_saveCount)) {
      throw const FileSystemException('test cache failure');
    }
    await super.save(notes);
  }
}

final class _GatedSaveKnowledgeLibraryCache
    extends _MemoryKnowledgeLibraryCache {
  _GatedSaveKnowledgeLibraryCache({required this.gateOnSave});

  final int gateOnSave;
  final Completer<void> _gatedSaveStarted = Completer<void>();
  final Completer<void> _gatedSaveReleased = Completer<void>();
  var _saveCount = 0;

  Future<void> get gatedSaveStarted => _gatedSaveStarted.future;

  void releaseGatedSave() {
    if (!_gatedSaveReleased.isCompleted) _gatedSaveReleased.complete();
  }

  @override
  Future<void> save(List<V3FeedItem> notes) async {
    _saveCount++;
    if (_saveCount == gateOnSave) {
      _gatedSaveStarted.complete();
      await _gatedSaveReleased.future;
    }
    await super.save(notes);
  }
}

final class _GatedFailingSaveKnowledgeLibraryCache
    extends _MemoryKnowledgeLibraryCache {
  final Completer<void> _firstSaveStarted = Completer<void>();
  final Completer<void> _firstSaveReleased = Completer<void>();
  final Completer<void> _secondSaveStarted = Completer<void>();
  final Completer<void> _secondSaveReleased = Completer<void>();
  var _saveCount = 0;

  Future<void> get firstSaveStarted => _firstSaveStarted.future;

  Future<void> get secondSaveStarted => _secondSaveStarted.future;

  void releaseFirstSave() {
    if (!_firstSaveReleased.isCompleted) _firstSaveReleased.complete();
  }

  void releaseSecondSave() {
    if (!_secondSaveReleased.isCompleted) _secondSaveReleased.complete();
  }

  @override
  Future<void> save(List<V3FeedItem> notes) async {
    _saveCount++;
    if (_saveCount == 1) {
      _firstSaveStarted.complete();
      await _firstSaveReleased.future;
      throw const FileSystemException('test cache failure');
    }
    if (_saveCount == 2) {
      _secondSaveStarted.complete();
      await _secondSaveReleased.future;
    }
    await super.save(notes);
  }
}

class _MemoryTrashRepository implements KnowledgeTrashRepository {
  List<KnowledgeTrashEntry> entries = const <KnowledgeTrashEntry>[];

  @override
  Future<List<KnowledgeTrashEntry>> load() async => entries;

  @override
  Future<void> save(List<KnowledgeTrashEntry> entries) async {
    this.entries = List<KnowledgeTrashEntry>.of(entries);
  }
}

final class _FailOnceTrashRepository extends _MemoryTrashRepository {
  var _shouldFail = true;

  @override
  Future<void> save(List<KnowledgeTrashEntry> entries) async {
    if (_shouldFail) {
      _shouldFail = false;
      throw const FileSystemException('test trash failure');
    }
    await super.save(entries);
  }
}

final class _FailOnSaveNumberTrashRepository extends _MemoryTrashRepository {
  _FailOnSaveNumberTrashRepository({required this.failOnSave});

  final int failOnSave;
  var _saveCount = 0;

  @override
  Future<void> save(List<KnowledgeTrashEntry> entries) async {
    _saveCount++;
    if (_saveCount == failOnSave) {
      throw const FileSystemException('test trash failure');
    }
    await super.save(entries);
  }
}

V3FeedItem _workspaceLifecycleNote({
  required String id,
  required String remoteNoteId,
}) => V3FeedItem(
  id: id,
  title: '工作空间生命周期笔记',
  source: V3MaterialSource.note,
  createdAt: DateTime.utc(2026, 8, 15, 10),
  rawBody: '正文',
  remoteNoteId: remoteNoteId,
  noteRevisionId: 'note-revision-1',
  rawPartRevisionId: 'raw-revision-1',
  etag: '"note-1"',
  contentCursor: '110',
  syncState: NoteSyncState.synced,
);

WorkspaceContentRemoteFolder _workspaceRemoteFolder({
  required String folderId,
  required String displayName,
  required String contentCursor,
  String? parentFolderId,
}) => WorkspaceContentRemoteFolder(
  folderId: folderId,
  parentFolderId: parentFolderId,
  displayName: displayName,
  normalizedName: displayName.toLowerCase(),
  state: 'live',
  currentRevisionId: 'folder-revision-$folderId',
  etag: '"folder-$folderId"',
  contentCursor: contentCursor,
);

final class _WorkspaceMoveRequest {
  const _WorkspaceMoveRequest({
    required this.folderId,
    required this.noteId,
    required this.etag,
  });

  final String? folderId;
  final String noteId;
  final String etag;
}

final class _QueuedWorkspaceSyncRemote
    implements WorkspaceContentSyncRemotePort {
  final Completer<void> firstChangeRequested = Completer<void>();
  final Completer<
    WorkspaceContentRemoteResponse<SharedWorkspaceContentEventPage>
  >
  _firstChange =
      Completer<
        WorkspaceContentRemoteResponse<SharedWorkspaceContentEventPage>
      >();
  final List<String> changeAfters = <String>[];
  var _changeCount = 0;

  void completeFirstChange() {
    _firstChange.complete(
      const WorkspaceContentRemoteResponse<
        SharedWorkspaceContentEventPage
      >.success(
        SharedWorkspaceContentEventPage(
          events: <SharedWorkspaceContentEvent>[],
          nextAfter: '10',
          hasMore: false,
        ),
      ),
    );
  }

  @override
  Future<WorkspaceContentSnapshotResponse> contentSnapshot(
    String workspaceId, {
    String? pageToken,
    String? ifNoneMatch,
  }) async => throw StateError('unexpected snapshot');

  @override
  Future<WorkspaceContentRemoteResponse<SharedWorkspaceContentEventPage>>
  changes(String workspaceId, {required String after}) {
    changeAfters.add(after);
    if (_changeCount++ == 0) {
      firstChangeRequested.complete();
      return _firstChange.future;
    }
    return Future<
      WorkspaceContentRemoteResponse<SharedWorkspaceContentEventPage>
    >.value(
      WorkspaceContentRemoteResponse<SharedWorkspaceContentEventPage>.success(
        SharedWorkspaceContentEventPage(
          events: <SharedWorkspaceContentEvent>[
            SharedWorkspaceContentEvent(
              eventId: 'serialized-move-event',
              workspaceId: 'workspace-1',
              cursor: '12',
              operationId: 'serialized-move-operation',
              occurredAt: DateTime.utc(2026, 8, 15, 10),
              objectKind: 'hnote',
              objectId: 'serialized-remote-note',
              changeType: 'moved',
              revisionId: 'note-revision-moved',
              tombstone: false,
              resourcePinDelta: const SharedWorkspaceResourcePinDelta(
                added: <String>[],
                released: <String>[],
              ),
            ),
          ],
          nextAfter: '12',
          hasMore: false,
        ),
      ),
    );
  }

  @override
  Future<WorkspaceContentRemoteResponse<SharedWorkspaceFolder>> folder(
    String workspaceId,
    String folderId, {
    required String revisionId,
  }) async =>
      const WorkspaceContentRemoteResponse<SharedWorkspaceFolder>.failure(
        errorCode: 'FOLDER_NOT_FOUND',
      );

  @override
  Future<WorkspaceContentRemoteResponse<SharedHNotePartView>> notePart(
    String workspaceId,
    String noteId,
    String part, {
    required String partRevisionId,
  }) async => const WorkspaceContentRemoteResponse<SharedHNotePartView>.failure(
    errorCode: 'NOTE_PART_NOT_FOUND',
  );

  @override
  Future<WorkspaceContentRemoteResponse<SharedHNote>> note(
    String workspaceId,
    String noteId, {
    required String revisionId,
  }) async {
    if (noteId != 'serialized-remote-note' ||
        revisionId != 'note-revision-moved') {
      return const WorkspaceContentRemoteResponse<SharedHNote>.failure(
        errorCode: 'NOTE_NOT_FOUND',
      );
    }
    return WorkspaceContentRemoteResponse<SharedHNote>.success(
      SharedHNote(
        noteId: noteId,
        workspaceId: workspaceId,
        folderId: 'folder-created',
        title: '串行同步笔记',
        state: 'live',
        noteRevisionId: revisionId,
        raw: const SharedHNotePart(
          partRevisionId: 'raw-revision-moved',
          markdown: '正文',
          contentHash: 'raw-moved',
        ),
        outline: const SharedHNotePart(
          partRevisionId: 'outline-revision-moved',
          markdown: '',
          contentHash: 'outline-moved',
        ),
        germination: const SharedHNotePart(
          partRevisionId: 'germination-revision-moved',
          markdown: '',
          contentHash: 'germination-moved',
        ),
        resourceRefs: const <SharedHNoteResourceRef>[],
        etag: '"note-moved-event"',
        contentCursor: '12',
        createdAt: DateTime.utc(2026, 8, 17, 8),
        updatedAt: DateTime.utc(2026, 8, 17, 8, 1),
      ),
    );
  }
}

final class _FakeWorkspaceFolderPort implements WorkspaceFolderPort {
  final List<SharedWorkspaceFolder> createRequests = <SharedWorkspaceFolder>[];
  final List<_WorkspaceMoveRequest> moveRequests = <_WorkspaceMoveRequest>[];
  final List<String> restoreRequests = <String>[];

  @override
  Future<WorkspaceFolderPortResult<SharedWorkspaceFolder>> folder({
    required String folderId,
  }) async => WorkspaceFolderPortResult<SharedWorkspaceFolder>.success(
    SharedWorkspaceFolder(
      folderId: folderId,
      parentFolderId: null,
      displayName: '已删除文件夹',
      normalizedName: '已删除文件夹',
      state: 'tombstoned',
      currentRevisionId: 'folder-revision-tombstoned',
      etag: '"folder-tombstoned"',
      contentCursor: '104',
    ),
  );

  @override
  Future<WorkspaceFolderPortResult<SharedWorkspaceFolder>> createFolder({
    required String displayName,
    required String? parentFolderId,
    required String idempotencyKey,
  }) async {
    final folder = SharedWorkspaceFolder(
      folderId: 'folder-created',
      parentFolderId: parentFolderId,
      displayName: displayName,
      normalizedName: displayName.toLowerCase(),
      state: 'live',
      currentRevisionId: 'folder-revision-created',
      etag: '"folder-created"',
      contentCursor: '101',
    );
    createRequests.add(folder);
    return WorkspaceFolderPortResult<SharedWorkspaceFolder>.success(folder);
  }

  @override
  Future<WorkspaceFolderPortResult<SharedRecursiveFolderMutationResult>>
  deleteFolder({
    required String folderId,
    required String etag,
    required String idempotencyKey,
  }) async =>
      const WorkspaceFolderPortResult<
        SharedRecursiveFolderMutationResult
      >.success(
        SharedRecursiveFolderMutationResult(
          affectedObjectCount: 2,
          firstContentCursor: '103',
          contentCursor: '104',
        ),
      );

  @override
  Future<WorkspaceFolderPortResult<SharedRecursiveFolderMutationResult>>
  restoreFolder({
    required String folderId,
    String? parentFolderId,
    bool overrideParentFolder = false,
    required String etag,
    required String idempotencyKey,
  }) async {
    restoreRequests.add('$folderId|$etag');
    return const WorkspaceFolderPortResult<
      SharedRecursiveFolderMutationResult
    >.success(
      SharedRecursiveFolderMutationResult(
        affectedObjectCount: 2,
        firstContentCursor: '105',
        contentCursor: '106',
      ),
    );
  }

  @override
  Future<WorkspaceFolderPortResult<SharedWorkspaceContentEvent>> moveFolder({
    required String folderId,
    required String? parentFolderId,
    required String etag,
    required String idempotencyKey,
  }) async => WorkspaceFolderPortResult<SharedWorkspaceContentEvent>.success(
    SharedWorkspaceContentEvent(
      eventId: 'folder-move-event',
      workspaceId: 'workspace-1',
      cursor: '102',
      operationId: 'folder-move-operation',
      occurredAt: DateTime.utc(2026, 8, 15, 10),
      objectKind: 'folder',
      objectId: folderId,
      changeType: 'moved',
      tombstone: false,
      resourcePinDelta: const SharedWorkspaceResourcePinDelta(
        added: <String>[],
        released: <String>[],
      ),
    ),
  );

  @override
  Future<WorkspaceFolderPortResult<SharedHNoteBatchMoveResult>> moveNotes({
    required String? folderId,
    required List<SharedHNoteBatchMoveInput> notes,
    required String idempotencyKey,
  }) async {
    for (final note in notes) {
      moveRequests.add(
        _WorkspaceMoveRequest(
          folderId: folderId,
          noteId: note.noteId,
          etag: note.etag,
        ),
      );
    }
    return WorkspaceFolderPortResult<SharedHNoteBatchMoveResult>.success(
      SharedHNoteBatchMoveResult(
        notes: <SharedHNoteBatchMoveReceipt>[
          for (final note in notes)
            SharedHNoteBatchMoveReceipt(
              noteId: note.noteId,
              noteRevisionId: 'note-revision-moved',
              etag: '"note-moved"',
              contentCursor: '102',
            ),
        ],
      ),
    );
  }

  @override
  Future<WorkspaceFolderPortResult<SharedWorkspaceFolder>> renameFolder({
    required String folderId,
    required String displayName,
    required String etag,
    required String idempotencyKey,
  }) async => WorkspaceFolderPortResult<SharedWorkspaceFolder>.success(
    SharedWorkspaceFolder(
      folderId: folderId,
      parentFolderId: null,
      displayName: displayName,
      normalizedName: displayName.toLowerCase(),
      state: 'live',
      currentRevisionId: 'folder-revision-renamed',
      etag: '"folder-renamed"',
      contentCursor: '102',
    ),
  );
}
