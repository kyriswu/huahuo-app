import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/api/api_client.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/database/app_preferences_dao.dart';
import 'package:huahuoai_app/features/ui_v3/data/workspace_content_sync.dart';
import 'package:huahuoai_app/features/ui_v3/data/workspace_content_sync_store.dart';
import 'package:huahuoai_app/features/ui_v3/domain/feed_item_models.dart';

typedef _ChangeResponse =
    WorkspaceContentRemoteResponse<SharedWorkspaceContentEventPage>;
typedef _ChangeFuture = Future<_ChangeResponse>;

void main() {
  group('WorkspaceContentSyncStore', () {
    test(
      'isolates the cursor and remote folder index by user and Workspace',
      () {
        final preferences = AppPreferencesDao(AppDatabase());
        final first = WorkspaceContentSyncStore(
          preferences: preferences,
          userScope: 'user-1',
          workspaceId: 'workspace-1',
          now: () => DateTime.utc(2026, 8, 15),
        );
        first.save(
          WorkspaceContentSyncState(
            contentCursor: '20',
            snapshotEtag: '"snapshot-20"',
            folders: <String, WorkspaceContentRemoteFolder>{
              'folder-1': _folderProjection(
                'folder-1',
                '资料',
                systemSeedKey: 'inbox',
              ),
            },
          ),
        );

        expect(first.load().contentCursor, '20');
        expect(first.load().folders['folder-1']?.displayName, '资料');
        expect(first.load().folders['folder-1']?.systemSeedKey, 'inbox');
        expect(
          WorkspaceContentSyncStore(
            preferences: preferences,
            userScope: 'user-1',
            workspaceId: 'workspace-2',
          ).load().contentCursor,
          isNull,
        );
        expect(
          WorkspaceContentSyncStore(
            preferences: preferences,
            userScope: 'user-2',
            workspaceId: 'workspace-1',
          ).load().folders,
          isEmpty,
        );

        first.clear();
        expect(first.load().contentCursor, isNull);
        expect(first.load().snapshotEtag, isNull);
      },
    );

    test('rejects a non-canonical cursor before checkpoint persistence', () {
      final store = WorkspaceContentSyncStore(
        preferences: AppPreferencesDao(AppDatabase()),
        userScope: 'user-1',
        workspaceId: 'workspace-1',
      );

      expect(
        () => store.save(const WorkspaceContentSyncState(contentCursor: '001')),
        throwsArgumentError,
      );
      expect(store.load().contentCursor, isNull);
    });
  });

  group('WorkspaceContentSync', () {
    test(
      'publishes complete folders before slow paged snapshot notes',
      () async {
        final nextPage = Completer<WorkspaceContentSnapshotResponse>();
        final note = Completer<SharedHNote>();
        final remote = _FakeRemote(
          snapshots: [
            Future.value(
              WorkspaceContentSnapshotResponse.success(
                _snapshot(
                  hasMore: true,
                  nextPageToken: 'page-2',
                  folders: [_folder('folder-1', '项目')],
                  objects: [_head('note-1', 'revision-1')],
                ),
              ),
            ),
            nextPage.future,
          ],
          hnoteFutures: {'note-1@revision-1': note.future},
        );
        final harness = _Harness(remote: remote);
        final synchronization = harness.sync.synchronize();
        await pumpEventQueue();
        expect(harness.currentFolders, isEmpty);
        expect(remote.noteRequests, isEmpty);

        nextPage.complete(
          WorkspaceContentSnapshotResponse.success(
            _snapshot(folders: [_folder('folder-empty', '空文件夹')]),
          ),
        );
        await pumpEventQueue();
        expect(
          harness.currentFolders.keys,
          unorderedEquals(['folder-1', 'folder-empty']),
        );
        expect(remote.noteRequests, ['note-1@revision-1']);
        expect(harness.applyCount, 0);
        expect(harness.store.load().contentCursor, isNull);
        expect(harness.store.load().folders, isEmpty);

        note.complete(
          _hnote('note-1', 'revision-1', '正文', folderId: 'folder-1'),
        );
        expect((await synchronization).isSuccess, isTrue);
        expect(harness.currentNotes.single.folderName, '项目');
        expect(harness.store.load().folders, hasLength(2));
        expect(harness.store.load().contentCursor, '10');
      },
    );

    test('inconsistent snapshot pages never publish partial folders', () async {
      final remote = _FakeRemote(
        snapshots: [
          Future.value(
            WorkspaceContentSnapshotResponse.success(
              _snapshot(
                hasMore: true,
                nextPageToken: 'page-2',
                folders: [_folder('partial-folder', '尚未确认的目录')],
              ),
            ),
          ),
          Future.value(
            WorkspaceContentSnapshotResponse.success(
              _snapshot(id: 'different-snapshot'),
            ),
          ),
        ],
      );
      final harness = _Harness(remote: remote);
      expect((await harness.sync.synchronize()).isSuccess, isFalse);
      expect(harness.currentFolders, isEmpty);
      expect(harness.applyCount, 0);
      expect(harness.store.load().contentCursor, isNull);
    });

    test('hydrates cold snapshot HNotes in bounded batches', () async {
      final gates = <Completer<void>>[
        for (var index = 0; index < 7; index += 1) Completer<void>(),
      ];
      final remote = _FakeRemote(
        snapshots: <Future<WorkspaceContentSnapshotResponse>>[
          Future<WorkspaceContentSnapshotResponse>.value(
            WorkspaceContentSnapshotResponse.success(
              _snapshot(
                objects: <SharedWorkspaceSnapshotObject>[
                  for (var index = 1; index <= 7; index += 1)
                    _head('note-$index', 'revision-$index'),
                ],
              ),
            ),
          ),
        ],
        hnoteFutures: <String, Future<SharedHNote>>{
          for (var index = 1; index <= 7; index += 1)
            'note-$index@revision-$index': gates[index - 1].future.then(
              (_) => _hnote('note-$index', 'revision-$index', 'note-$index'),
            ),
        },
      );
      final harness = _Harness(remote: remote);

      final synchronization = harness.sync.synchronize();
      await pumpEventQueue();

      expect(remote.noteRequests, hasLength(6));
      expect(harness.applyCount, 0);
      expect(harness.store.load().contentCursor, isNull);

      for (final gate in gates.take(6)) {
        gate.complete();
      }
      await pumpEventQueue();

      expect(remote.noteRequests, hasLength(7));
      expect(harness.applyCount, 0);
      expect(harness.store.load().contentCursor, isNull);

      gates.last.complete();
      final result = await synchronization;

      expect(result.status, WorkspaceContentSyncStatus.synchronized);
      expect(harness.currentNotes, hasLength(7));
      expect(harness.applyCount, 1);
      expect(harness.store.load().contentCursor, '10');
    });

    test('hydrates each paged HNote at its exact snapshot revision', () async {
      final remote = _FakeRemote(
        snapshots: <Future<WorkspaceContentSnapshotResponse>>[
          Future<WorkspaceContentSnapshotResponse>.value(
            WorkspaceContentSnapshotResponse.success(
              _snapshot(
                hasMore: true,
                nextPageToken: 'page-2',
                folders: <SharedWorkspaceFolder>[_folder('folder-1', '资料')],
                objects: <SharedWorkspaceSnapshotObject>[
                  _head('note-1', 'revision-1'),
                ],
              ),
              etag: '"snapshot-10"',
            ),
          ),
          Future<WorkspaceContentSnapshotResponse>.value(
            WorkspaceContentSnapshotResponse.success(
              _snapshot(
                objects: <SharedWorkspaceSnapshotObject>[
                  _head('note-2', 'revision-2'),
                ],
              ),
            ),
          ),
        ],
        hnotes: <String, SharedHNote>{
          'note-1@revision-1': _hnote('note-1', 'revision-1', '第一篇'),
          'note-2@revision-2': _hnote(
            'note-2',
            'revision-2',
            '第二篇',
            folderId: 'folder-1',
          ),
        },
      );
      final harness = _Harness(remote: remote);

      final result = await harness.sync.synchronize();

      expect(result.status, WorkspaceContentSyncStatus.synchronized);
      expect(result.rebuiltFromSnapshot, isTrue);
      expect(result.contentCursor, '10');
      expect(remote.snapshotPageTokens, <String?>[null, 'page-2']);
      expect(remote.snapshotEtags, <String?>[null, null]);
      expect(remote.noteRequests, <String>[
        'note-1@revision-1',
        'note-2@revision-2',
      ]);
      expect(harness.currentNotes.map((note) => note.remoteNoteId), <String?>[
        'note-1',
        'note-2',
      ]);
      expect(harness.currentNotes.last.folderName, '资料');
      expect(harness.store.load().contentCursor, '10');
      expect(harness.store.load().snapshotEtag, '"snapshot-10"');
    });

    test(
      'rebuilds unconditionally when the projection baseline is missing',
      () async {
        final remote = _FakeRemote(
          snapshots: <Future<WorkspaceContentSnapshotResponse>>[
            Future<WorkspaceContentSnapshotResponse>.value(
              WorkspaceContentSnapshotResponse.success(
                _snapshot(
                  objects: <SharedWorkspaceSnapshotObject>[
                    _head('note-recovered', 'revision-recovered'),
                  ],
                ),
                etag: '"snapshot-recovered"',
              ),
            ),
          ],
          hnotes: <String, SharedHNote>{
            'note-recovered@revision-recovered': _hnote(
              'note-recovered',
              'revision-recovered',
              '完整恢复',
            ),
          },
        );
        final harness = _Harness(
          remote: remote,
          initialState: const WorkspaceContentSyncState(
            contentCursor: '9',
            snapshotEtag: '"stale-snapshot"',
          ),
          hasProjectionBaseline: false,
        );

        final result = await harness.sync.synchronize();

        expect(result.rebuiltFromSnapshot, isTrue);
        expect(remote.changeAfters, isEmpty);
        expect(remote.snapshotEtags, <String?>[null]);
        expect(harness.currentNotes.single.title, '完整恢复');
        expect(harness.projectionCursor, '10');
        expect(harness.store.load().contentCursor, '10');
        expect(harness.store.load().snapshotEtag, '"snapshot-recovered"');
      },
    );

    test(
      'skips change reads when the Workspace cursor matches the local projection',
      () async {
        final remote = _ProbeRemote(
          cursorResponse: Future<WorkspaceContentRemoteResponse<String>>.value(
            const WorkspaceContentRemoteResponse<String>.success('10'),
          ),
        );
        final local = _localRemoteNote('note-cached', title: '已缓存资产');
        final harness = _Harness(
          remote: remote,
          initialNotes: <V3FeedItem>[local],
          initialState: WorkspaceContentSyncState(
            contentCursor: '10',
            snapshotEtag: '"snapshot-10"',
            folders: {
              'folder-cached': _folderProjection('folder-cached', '缓存目录'),
            },
          ),
        );

        final result = await harness.sync.synchronize();

        expect(result.status, WorkspaceContentSyncStatus.notModified);
        expect(result.contentCursor, '10');
        expect(remote.cursorProbeWorkspaceIds, <String>['workspace-1']);
        expect(remote.changeAfters, isEmpty);
        expect(remote.snapshotPageTokens, isEmpty);
        expect(remote.noteRequests, isEmpty);
        expect(harness.applyCount, 0);
        expect(harness.currentNotes.single.title, '已缓存资产');
        expect(harness.currentFolders['folder-cached']?.displayName, '缓存目录');
      },
    );

    test(
      'hydrates sparse formal HNote parts before snapshot projection',
      () async {
        final remote = _FakeRemote(
          snapshots: <Future<WorkspaceContentSnapshotResponse>>[
            Future<WorkspaceContentSnapshotResponse>.value(
              WorkspaceContentSnapshotResponse.success(
                _snapshot(
                  objects: <SharedWorkspaceSnapshotObject>[
                    _head('note-sparse', 'revision-sparse'),
                  ],
                ),
              ),
            ),
          ],
          hnotes: <String, SharedHNote>{
            'note-sparse@revision-sparse': _sparseHNote(
              'note-sparse',
              'revision-sparse',
              '稀疏正文',
            ),
          },
          parts: <String, SharedHNotePartView>{
            'note-sparse@raw@revision-sparse-raw': _partView(
              noteId: 'note-sparse',
              part: 'raw',
              revisionId: 'revision-sparse-raw',
              markdown: '# 稀疏正文\n\n完整 Raw',
              contentHash: 'raw-sparse-hash',
            ),
            'note-sparse@outline@revision-sparse-outline': _partView(
              noteId: 'note-sparse',
              part: 'outline',
              revisionId: 'revision-sparse-outline',
              markdown: '## 完整纲要',
              contentHash: 'outline-sparse-hash',
            ),
            'note-sparse@germination@revision-sparse-germination': _partView(
              noteId: 'note-sparse',
              part: 'germination',
              revisionId: 'revision-sparse-germination',
              markdown: '完整发芽',
              contentHash: 'germination-sparse-hash',
            ),
          },
        );
        final harness = _Harness(remote: remote);

        final result = await harness.sync.synchronize();

        expect(result.status, WorkspaceContentSyncStatus.synchronized);
        expect(harness.currentNotes.single.rawBody, '# 稀疏正文\n\n完整 Raw');
        expect(harness.currentNotes.single.summaryBody, '## 完整纲要');
        expect(harness.currentNotes.single.sproutReport?.markdown, '完整发芽');
        expect(
          remote.notePartRequests,
          unorderedEquals(<String>[
            'note-sparse@raw@revision-sparse-raw',
            'note-sparse@outline@revision-sparse-outline',
            'note-sparse@germination@revision-sparse-germination',
          ]),
        );
      },
    );

    test(
      'restarts an expired snapshot pagination once without an ETag',
      () async {
        final remote = _FakeRemote(
          snapshots: <Future<WorkspaceContentSnapshotResponse>>[
            Future<WorkspaceContentSnapshotResponse>.value(
              WorkspaceContentSnapshotResponse.success(
                _snapshot(
                  hasMore: true,
                  nextPageToken: 'page-2',
                  objects: <SharedWorkspaceSnapshotObject>[
                    _head('stale-note', 'stale-revision'),
                  ],
                ),
                etag: '"stale-snapshot"',
              ),
            ),
            Future<WorkspaceContentSnapshotResponse>.value(
              const WorkspaceContentSnapshotResponse.failure(
                errorCode: 'CONTENT_SNAPSHOT_EXPIRED',
                status: 410,
              ),
            ),
            Future<WorkspaceContentSnapshotResponse>.value(
              WorkspaceContentSnapshotResponse.success(
                _snapshot(
                  objects: <SharedWorkspaceSnapshotObject>[
                    _head('note-1', 'revision-1'),
                  ],
                ),
                etag: '"snapshot-10"',
              ),
            ),
          ],
          hnotes: <String, SharedHNote>{
            'note-1@revision-1': _hnote('note-1', 'revision-1', '重试成功'),
          },
        );
        final harness = _Harness(remote: remote);

        final result = await harness.sync.synchronize();

        expect(result.status, WorkspaceContentSyncStatus.synchronized);
        expect(remote.snapshotPageTokens, <String?>[null, 'page-2', null]);
        expect(remote.snapshotEtags, <String?>[null, null, null]);
        expect(remote.noteRequests, <String>['note-1@revision-1']);
        expect(harness.store.load().snapshotEtag, '"snapshot-10"');
      },
    );

    test(
      'replaces stale synchronized remote HNotes but retains local pending',
      () async {
        final remote = _FakeRemote(
          snapshots: <Future<WorkspaceContentSnapshotResponse>>[
            Future<WorkspaceContentSnapshotResponse>.value(
              WorkspaceContentSnapshotResponse.success(
                _snapshot(
                  objects: <SharedWorkspaceSnapshotObject>[
                    _head('note-current', 'revision-current'),
                  ],
                ),
                etag: '"snapshot-10"',
              ),
            ),
          ],
          hnotes: <String, SharedHNote>{
            'note-current@revision-current': _hnote(
              'note-current',
              'revision-current',
              '当前工作空间',
            ),
          },
        );
        final harness = _Harness(
          remote: remote,
          initialNotes: <V3FeedItem>[
            _localRemoteNote('note-stale', title: '旧工作空间'),
            _localRemoteNote(
              'note-pending',
              title: '本地待同步',
              state: NoteSyncState.pending,
            ),
          ],
        );

        final result = await harness.sync.synchronize();

        expect(result.status, WorkspaceContentSyncStatus.synchronized);
        expect(
          harness.currentNotes.map((note) => note.remoteNoteId),
          containsAll(<String?>['note-current', 'note-pending']),
        );
        expect(
          harness.currentNotes.any((note) => note.remoteNoteId == 'note-stale'),
          isFalse,
        );
      },
    );

    test('projects HNote and Folder events, then saves nextAfter', () async {
      final remote = _FakeRemote(
        changes: <_ChangeFuture>[
          Future<_ChangeResponse>.value(
            _ChangeResponse.success(
              SharedWorkspaceContentEventPage(
                events: <SharedWorkspaceContentEvent>[
                  _event(
                    kind: 'folder',
                    objectId: 'folder-1',
                    revisionId: 'folder-revision-2',
                    changeType: 'renamed',
                    cursor: '11',
                  ),
                  _event(
                    kind: 'hnote',
                    objectId: 'note-1',
                    revisionId: 'revision-2',
                    changeType: 'revision_created',
                    cursor: '12',
                  ),
                  _event(
                    kind: 'fixed_asset',
                    objectId: 'asset-1',
                    revisionId: 'asset-revision-1',
                    changeType: 'created',
                    cursor: '13',
                  ),
                ],
                nextAfter: '13',
                hasMore: false,
              ),
            ),
          ),
        ],
        hnotes: <String, SharedHNote>{
          'note-1@revision-2': _hnote(
            'note-1',
            'revision-2',
            '更新标题',
            folderId: 'folder-1',
          ),
        },
        folders: <String, SharedWorkspaceFolder>{
          'folder-1': _folder('folder-1', '新资料', revision: 'folder-revision-2'),
        },
      );
      final existing = _localRemoteNote(
        'note-1',
        title: '旧标题',
        folderId: 'folder-1',
      );
      final harness = _Harness(
        remote: remote,
        initialNotes: <V3FeedItem>[existing],
        initialState: WorkspaceContentSyncState(
          contentCursor: '10',
          snapshotEtag: '"snapshot-10"',
          folders: <String, WorkspaceContentRemoteFolder>{
            'folder-1': _folderProjection('folder-1', '旧资料'),
          },
        ),
      );

      final result = await harness.sync.synchronize();

      expect(result.status, WorkspaceContentSyncStatus.synchronized);
      expect(result.eventCount, 3);
      expect(harness.currentNotes.single.title, '更新标题');
      expect(harness.currentNotes.single.folderName, '新资料');
      expect(remote.noteRequests, <String>['note-1@revision-2']);
      expect(remote.folderRequests, <String>['folder-1@folder-revision-2']);
      expect(harness.store.load().contentCursor, '13');
      expect(harness.store.load().folders['folder-1']?.displayName, '新资料');
    });

    test(
      'rejects a Folder response that does not match its event revision',
      () async {
        final remote = _FakeRemote(
          changes: <_ChangeFuture>[
            Future<_ChangeResponse>.value(
              _ChangeResponse.success(
                SharedWorkspaceContentEventPage(
                  events: <SharedWorkspaceContentEvent>[
                    _event(
                      kind: 'folder',
                      objectId: 'folder-1',
                      revisionId: 'folder-revision-2',
                      changeType: 'renamed',
                      cursor: '11',
                    ),
                  ],
                  nextAfter: '11',
                  hasMore: false,
                ),
              ),
            ),
          ],
          folders: <String, SharedWorkspaceFolder>{
            'folder-1@folder-revision-2': _folder(
              'wrong-folder',
              '错误目录',
              revision: 'folder-revision-2',
            ),
          },
        );
        final harness = _Harness(
          remote: remote,
          initialState: const WorkspaceContentSyncState(contentCursor: '10'),
        );

        final result = await harness.sync.synchronize();

        expect(result.status, WorkspaceContentSyncStatus.failure);
        expect(
          result.errorCode,
          'WORKSPACE_CONTENT_FOLDER_EVENT_REVISION_MISMATCH',
        );
        expect(harness.store.load().contentCursor, '10');
        expect(harness.applyCount, 0);
      },
    );

    test(
      'hydrates created, edited, renamed, and moved HNote revisions exactly',
      () async {
        final remote = _FakeRemote(
          changes: <_ChangeFuture>[
            Future<_ChangeResponse>.value(
              _ChangeResponse.success(
                SharedWorkspaceContentEventPage(
                  events: <SharedWorkspaceContentEvent>[
                    _event(
                      kind: 'hnote',
                      objectId: 'note-1',
                      revisionId: 'revision-1',
                      changeType: 'created',
                      cursor: '11',
                    ),
                    _event(
                      kind: 'hnote',
                      objectId: 'note-1',
                      revisionId: 'revision-2',
                      changeType: 'revision_created',
                      cursor: '12',
                    ),
                    _event(
                      kind: 'hnote',
                      objectId: 'note-1',
                      revisionId: 'revision-3',
                      changeType: 'renamed',
                      cursor: '13',
                    ),
                    _event(
                      kind: 'hnote',
                      objectId: 'note-1',
                      revisionId: 'revision-4',
                      changeType: 'moved',
                      cursor: '14',
                    ),
                  ],
                  nextAfter: '14',
                  hasMore: false,
                ),
              ),
            ),
          ],
          hnotes: <String, SharedHNote>{
            'note-1@revision-1': _hnote('note-1', 'revision-1', '初稿'),
            'note-1@revision-2': _hnote('note-1', 'revision-2', '编辑后'),
            'note-1@revision-3': _hnote('note-1', 'revision-3', '改名后'),
            'note-1@revision-4': _hnote('note-1', 'revision-4', '移动后'),
          },
        );
        final harness = _Harness(
          remote: remote,
          initialState: const WorkspaceContentSyncState(contentCursor: '10'),
        );

        final result = await harness.sync.synchronize();

        expect(result.status, WorkspaceContentSyncStatus.synchronized);
        expect(remote.noteRequests, <String>[
          'note-1@revision-1',
          'note-1@revision-2',
          'note-1@revision-3',
          'note-1@revision-4',
        ]);
        expect(harness.currentNotes.single.title, '移动后');
        expect(harness.store.load().contentCursor, '14');
      },
    );

    test(
      'removes a tombstoned HNote and restores its exact revision',
      () async {
        final remote = _FakeRemote(
          changes: <_ChangeFuture>[
            Future<_ChangeResponse>.value(
              _ChangeResponse.success(
                SharedWorkspaceContentEventPage(
                  events: <SharedWorkspaceContentEvent>[
                    _event(
                      kind: 'hnote',
                      objectId: 'note-1',
                      revisionId: 'revision-2',
                      changeType: 'tombstoned',
                      cursor: '11',
                      tombstone: true,
                    ),
                  ],
                  nextAfter: '11',
                  hasMore: true,
                ),
              ),
            ),
            Future<_ChangeResponse>.value(
              _ChangeResponse.success(
                SharedWorkspaceContentEventPage(
                  events: <SharedWorkspaceContentEvent>[
                    _event(
                      kind: 'hnote',
                      objectId: 'note-1',
                      revisionId: 'revision-3',
                      changeType: 'restored',
                      cursor: '12',
                    ),
                  ],
                  nextAfter: '12',
                  hasMore: false,
                ),
              ),
            ),
          ],
          hnotes: <String, SharedHNote>{
            'note-1@revision-3': _hnote('note-1', 'revision-3', '已恢复'),
          },
        );
        final harness = _Harness(
          remote: remote,
          initialNotes: <V3FeedItem>[_localRemoteNote('note-1', title: '旧内容')],
          initialState: const WorkspaceContentSyncState(contentCursor: '10'),
        );

        final result = await harness.sync.synchronize();

        expect(result.status, WorkspaceContentSyncStatus.synchronized);
        expect(remote.noteRequests, <String>['note-1@revision-3']);
        expect(harness.currentNotes.single.title, '已恢复');
        expect(harness.store.load().contentCursor, '12');
        expect(harness.applyCount, 2);
      },
    );

    test(
      'protects a pending local binding while ignored events advance cursor',
      () async {
        final remote = _FakeRemote(
          changes: <_ChangeFuture>[
            Future<_ChangeResponse>.value(
              _ChangeResponse.success(
                SharedWorkspaceContentEventPage(
                  events: <SharedWorkspaceContentEvent>[
                    _event(
                      kind: 'hnote',
                      objectId: 'note-1',
                      revisionId: 'revision-2',
                      changeType: 'revision_created',
                      cursor: '11',
                    ),
                    _event(
                      kind: 'book',
                      objectId: 'book-1',
                      revisionId: 'book-revision-1',
                      changeType: 'created',
                      cursor: '12',
                    ),
                  ],
                  nextAfter: '12',
                  hasMore: false,
                ),
              ),
            ),
          ],
        );
        final pending = _localRemoteNote(
          'note-1',
          title: '本地待同步',
          state: NoteSyncState.pending,
        );
        final harness = _Harness(
          remote: remote,
          initialNotes: <V3FeedItem>[pending],
          initialState: const WorkspaceContentSyncState(contentCursor: '10'),
        );

        final result = await harness.sync.synchronize();

        expect(result.status, WorkspaceContentSyncStatus.synchronized);
        expect(harness.currentNotes.single.title, '本地待同步');
        expect(harness.currentNotes.single.syncState, NoteSyncState.pending);
        expect(remote.noteRequests, isEmpty);
        expect(harness.store.load().contentCursor, '12');
      },
    );

    test(
      'folder tombstone clears its display name without changing a Note folder ID',
      () async {
        final remote = _FakeRemote(
          changes: <_ChangeFuture>[
            Future<_ChangeResponse>.value(
              _ChangeResponse.success(
                SharedWorkspaceContentEventPage(
                  events: <SharedWorkspaceContentEvent>[
                    _event(
                      kind: 'folder',
                      objectId: 'folder-1',
                      revisionId: 'folder-revision-2',
                      changeType: 'tombstoned',
                      cursor: '11',
                      tombstone: true,
                    ),
                  ],
                  nextAfter: '11',
                  hasMore: false,
                ),
              ),
            ),
          ],
        );
        final note = _localRemoteNote(
          'note-1',
          title: '仍然存在的 Note',
          folderId: 'folder-1',
        ).copyWith(folderName: '旧文件夹');
        final harness = _Harness(
          remote: remote,
          initialNotes: <V3FeedItem>[note],
          initialState: WorkspaceContentSyncState(
            contentCursor: '10',
            folders: <String, WorkspaceContentRemoteFolder>{
              'folder-1': _folderProjection('folder-1', '旧文件夹'),
            },
          ),
        );

        final result = await harness.sync.synchronize();

        expect(result.status, WorkspaceContentSyncStatus.synchronized);
        expect(harness.currentNotes.single.folderId, 'folder-1');
        expect(harness.currentNotes.single.folderName, isNull);
        expect(harness.store.load().folders, isEmpty);
      },
    );

    test(
      'clears an expired cursor and rebuilds with an unconditional snapshot',
      () async {
        final remote = _FakeRemote(
          changes: <_ChangeFuture>[
            Future<_ChangeResponse>.value(
              const WorkspaceContentRemoteResponse<
                SharedWorkspaceContentEventPage
              >.failure(errorCode: 'CONTENT_CURSOR_EXPIRED', status: 410),
            ),
          ],
          snapshots: <Future<WorkspaceContentSnapshotResponse>>[
            Future<WorkspaceContentSnapshotResponse>.value(
              WorkspaceContentSnapshotResponse.success(
                _snapshot(
                  objects: <SharedWorkspaceSnapshotObject>[
                    _head('note-2', 'revision-20'),
                  ],
                ),
                etag: '"snapshot-20"',
              ),
            ),
          ],
          hnotes: <String, SharedHNote>{
            'note-2@revision-20': _hnote('note-2', 'revision-20', '重建内容'),
          },
        );
        final harness = _Harness(
          remote: remote,
          initialState: const WorkspaceContentSyncState(
            contentCursor: '2',
            snapshotEtag: '"stale"',
          ),
        );

        final result = await harness.sync.synchronize();

        expect(result.rebuiltFromSnapshot, isTrue);
        expect(harness.currentNotes.single.title, '重建内容');
        expect(remote.changeAfters, <String>['2']);
        expect(remote.snapshotEtags, <String?>[null]);
        expect(harness.store.load().contentCursor, '10');
      },
    );

    test(
      'retains the current projection for a conditional snapshot 304',
      () async {
        final remote = _FakeRemote(
          snapshots: <Future<WorkspaceContentSnapshotResponse>>[
            Future<WorkspaceContentSnapshotResponse>.value(
              const WorkspaceContentSnapshotResponse.notModified(
                etag: '"snapshot-10"',
              ),
            ),
          ],
        );
        final local = _localRemoteNote('note-1', title: '已缓存');
        final harness = _Harness(
          remote: remote,
          initialNotes: <V3FeedItem>[local],
          initialState: WorkspaceContentSyncState(
            contentCursor: '10',
            snapshotEtag: '"snapshot-10"',
            folders: {
              'folder-cached': _folderProjection('folder-cached', '缓存目录'),
            },
          ),
        );

        final result = await harness.sync.synchronize(forceSnapshot: true);

        expect(result.status, WorkspaceContentSyncStatus.notModified);
        expect(remote.snapshotEtags, <String?>['"snapshot-10"']);
        expect(harness.applyCount, 0);
        expect(harness.currentNotes.single.title, '已缓存');
        expect(harness.currentFolders['folder-cached']?.displayName, '缓存目录');
        expect(harness.store.load().contentCursor, '10');
      },
    );

    test(
      'does not advance the cursor when projection application fails',
      () async {
        final remote = _FakeRemote(
          changes: <_ChangeFuture>[
            Future<_ChangeResponse>.value(
              _ChangeResponse.success(
                SharedWorkspaceContentEventPage(
                  events: const <SharedWorkspaceContentEvent>[],
                  nextAfter: '11',
                  hasMore: false,
                ),
              ),
            ),
          ],
        );
        final harness = _Harness(
          remote: remote,
          initialState: const WorkspaceContentSyncState(contentCursor: '10'),
          failApply: true,
        );

        final result = await harness.sync.synchronize();

        expect(result.status, WorkspaceContentSyncStatus.failure);
        expect(result.errorCode, 'WORKSPACE_CONTENT_PROJECTION_APPLY_FAILED');
        expect(harness.store.load().contentCursor, '10');
      },
    );

    test(
      'preserves a local pending edit made while a delta page is in flight',
      () async {
        final pendingChange = Completer<_ChangeResponse>();
        final remote = _FakeRemote(
          changes: <_ChangeFuture>[pendingChange.future],
          hnotes: <String, SharedHNote>{
            'note-1@revision-2': _hnote('note-1', 'revision-2', '远端更新'),
          },
        );
        final harness = _Harness(
          remote: remote,
          initialNotes: <V3FeedItem>[_localRemoteNote('note-1', title: '初始内容')],
          initialState: const WorkspaceContentSyncState(contentCursor: '10'),
        );

        final synchronization = harness.sync.synchronize();
        await Future<void>.delayed(Duration.zero);
        expect(remote.changeAfters, <String>['10']);
        harness.currentNotes = <V3FeedItem>[
          _localRemoteNote(
            'note-1',
            title: '本地刚编辑',
            state: NoteSyncState.pending,
          ),
        ];
        pendingChange.complete(
          _ChangeResponse.success(
            SharedWorkspaceContentEventPage(
              events: <SharedWorkspaceContentEvent>[
                _event(
                  kind: 'hnote',
                  objectId: 'note-1',
                  revisionId: 'revision-2',
                  changeType: 'revision_created',
                  cursor: '11',
                ),
              ],
              nextAfter: '11',
              hasMore: false,
            ),
          ),
        );

        final result = await synchronization;

        expect(result.status, WorkspaceContentSyncStatus.synchronized);
        expect(harness.currentNotes.single.title, '本地刚编辑');
        expect(harness.currentNotes.single.syncState, NoteSyncState.pending);
        expect(harness.store.load().contentCursor, '11');
      },
    );

    test(
      'coalesces concurrent synchronization calls into one remote read',
      () async {
        final pending = Completer<_ChangeResponse>();
        final remote = _FakeRemote(changes: <_ChangeFuture>[pending.future]);
        final harness = _Harness(
          remote: remote,
          initialState: const WorkspaceContentSyncState(contentCursor: '10'),
        );

        final first = harness.sync.synchronize();
        final second = harness.sync.synchronize();

        expect(identical(first, second), isTrue);
        await Future<void>.delayed(Duration.zero);
        expect(remote.changeAfters, <String>['10']);
        pending.complete(
          _ChangeResponse.success(
            const SharedWorkspaceContentEventPage(
              events: <SharedWorkspaceContentEvent>[],
              nextAfter: '10',
              hasMore: false,
            ),
          ),
        );
        await first;
        expect(harness.applyCount, 1);
      },
    );

    test(
      'dispose releases the last snapshot reader and drops a late result',
      () async {
        final remote = _CancellableSnapshotRemote();
        final harness = _Harness(remote: remote);

        final synchronization = harness.sync.synchronize();
        await remote.started.future;

        harness.sync.dispose();
        expect(harness.sync.isDisposed, isTrue);
        expect(remote.cancelCalls, 1);

        remote.completeLate(
          WorkspaceContentSnapshotResponse.success(
            _snapshot(cursor: '99'),
            etag: '"snapshot-99"',
          ),
        );
        final result = await synchronization;

        expect(result.status, WorkspaceContentSyncStatus.failure);
        expect(result.errorCode, 'WORKSPACE_CONTENT_SYNC_CANCELLED');
        expect(harness.applyCount, 0);
        expect(harness.store.load().contentCursor, isNull);
        expect(
          (await harness.sync.synchronize()).errorCode,
          'WORKSPACE_CONTENT_SYNC_CANCELLED',
        );
      },
    );

    test('processed inbox duplicate advances without rehydrating', () async {
      final journal = _FakeKnowledgeNoteSyncJournal(
        disposition: KnowledgeNoteInboxDisposition.alreadyProcessed,
      );
      final remote = _FakeRemote(
        changes: <_ChangeFuture>[
          Future<_ChangeResponse>.value(
            _ChangeResponse.success(
              SharedWorkspaceContentEventPage(
                events: <SharedWorkspaceContentEvent>[
                  _event(
                    kind: 'hnote',
                    objectId: 'note-duplicate',
                    revisionId: 'revision-duplicate',
                    changeType: 'revision_created',
                    cursor: '11',
                  ),
                ],
                nextAfter: '11',
                hasMore: false,
              ),
            ),
          ),
        ],
      );
      final harness = _Harness(
        remote: remote,
        initialState: const WorkspaceContentSyncState(contentCursor: '10'),
        noteSyncJournal: journal,
      );

      final result = await harness.sync.synchronize();

      expect(result.status, WorkspaceContentSyncStatus.synchronized);
      expect(remote.noteRequests, isEmpty);
      expect(harness.store.load().contentCursor, '11');
      expect(journal.begunEventIds, <String>['event-11']);
      expect(journal.processedEventIds, isEmpty);
    });

    test(
      'accepted inbox event resumes until projection is committed',
      () async {
        final journal = _FakeKnowledgeNoteSyncJournal(
          disposition: KnowledgeNoteInboxDisposition.resume,
        );
        _FakeRemote remote() => _FakeRemote(
          changes: <_ChangeFuture>[
            Future<_ChangeResponse>.value(
              _ChangeResponse.success(
                SharedWorkspaceContentEventPage(
                  events: <SharedWorkspaceContentEvent>[
                    _event(
                      kind: 'hnote',
                      objectId: 'note-resumed',
                      revisionId: 'revision-resumed',
                      changeType: 'revision_created',
                      cursor: '11',
                    ),
                  ],
                  nextAfter: '11',
                  hasMore: false,
                ),
              ),
            ),
          ],
          hnotes: <String, SharedHNote>{
            'note-resumed@revision-resumed': _hnote(
              'note-resumed',
              'revision-resumed',
              '恢复事件',
            ),
          },
        );
        final failed = _Harness(
          remote: remote(),
          initialState: const WorkspaceContentSyncState(contentCursor: '10'),
          noteSyncJournal: journal,
          failApply: true,
        );

        expect(
          (await failed.sync.synchronize()).status,
          WorkspaceContentSyncStatus.failure,
        );
        expect(journal.processedEventIds, isEmpty);
        expect(failed.store.load().contentCursor, '10');

        final recovered = _Harness(
          remote: remote(),
          initialState: const WorkspaceContentSyncState(contentCursor: '10'),
          noteSyncJournal: journal,
        );
        expect(
          (await recovered.sync.synchronize()).status,
          WorkspaceContentSyncStatus.synchronized,
        );
        expect(recovered.currentNotes.single.title, '恢复事件');
        expect(journal.begunEventIds, <String>['event-11', 'event-11']);
        expect(journal.processedEventIds, <String>['event-11']);
      },
    );
  });
}

final class _Harness {
  _Harness({
    required _FakeRemote remote,
    List<V3FeedItem> initialNotes = const <V3FeedItem>[],
    WorkspaceContentSyncState initialState = const WorkspaceContentSyncState(),
    bool failApply = false,
    bool hasProjectionBaseline = true,
    KnowledgeNoteSyncJournal? noteSyncJournal,
  }) : currentNotes = List<V3FeedItem>.from(initialNotes),
       projectionCursor = hasProjectionBaseline
           ? initialState.contentCursor
           : null,
       store = WorkspaceContentSyncStore(
         preferences: AppPreferencesDao(AppDatabase()),
         userScope: 'user-1',
         workspaceId: 'workspace-1',
         now: () => DateTime.utc(2026, 8, 15),
       ) {
    if (initialState.contentCursor != null ||
        initialState.snapshotEtag != null ||
        initialState.folders.isNotEmpty) {
      store.save(initialState);
    }
    sync = WorkspaceContentSync(
      remote: remote,
      store: store,
      workspaceId: 'workspace-1',
      readProjection: () => currentNotes,
      readProjectionCursor: () => projectionCursor,
      applyProjection: (projection) async {
        applyCount += 1;
        if (failApply) throw StateError('cache unavailable');
        currentNotes = List<V3FeedItem>.from(projection.notes);
        projectionCursor = projection.contentCursor;
      },
      applyFolderProjection: (folders) => currentFolders = folders,
      noteSyncJournal: noteSyncJournal,
    );
  }

  late final WorkspaceContentSync sync;
  final WorkspaceContentSyncStore store;
  List<V3FeedItem> currentNotes;
  Map<String, WorkspaceContentRemoteFolder> currentFolders = {};
  String? projectionCursor;
  int applyCount = 0;
}

final class _FakeKnowledgeNoteSyncJournal implements KnowledgeNoteSyncJournal {
  _FakeKnowledgeNoteSyncJournal({required this.disposition});

  final KnowledgeNoteInboxDisposition disposition;
  final List<String> begunEventIds = <String>[];
  final List<String> processedEventIds = <String>[];

  @override
  String get workspaceId => 'workspace-1';

  @override
  Future<KnowledgeNoteInboxDisposition> beginEvent({
    required String eventId,
    required DateTime occurredAt,
  }) async {
    begunEventIds.add(eventId);
    return disposition;
  }

  @override
  Future<void> markEventProcessed(String eventId) async {
    processedEventIds.add(eventId);
  }

  @override
  Future<List<KnowledgeNoteOutboxCommand>> claim({
    String? operationId,
    int limit = 20,
  }) => throw UnimplementedError();

  @override
  Future<KnowledgeNoteOutboxCommand> enqueueTombstone({
    required String localNoteId,
    required int localRevision,
    required String remoteNoteId,
    required String etag,
    required String idempotencyKey,
  }) => throw UnimplementedError();

  @override
  Future<KnowledgeNoteOutboxCommand> enqueueUpsert({
    required String localNoteId,
    required int localRevision,
  }) => throw UnimplementedError();

  @override
  Future<void> markRetry(
    KnowledgeNoteOutboxCommand command, {
    required String errorCode,
  }) => throw UnimplementedError();

  @override
  Future<void> markSucceeded(KnowledgeNoteOutboxCommand command) =>
      throw UnimplementedError();
}

class _FakeRemote implements WorkspaceContentSyncRemotePort {
  _FakeRemote({
    List<Future<WorkspaceContentSnapshotResponse>> snapshots =
        const <Future<WorkspaceContentSnapshotResponse>>[],
    List<_ChangeFuture> changes = const <_ChangeFuture>[],
    Map<String, SharedHNote> hnotes = const <String, SharedHNote>{},
    Map<String, Future<SharedHNote>> hnoteFutures =
        const <String, Future<SharedHNote>>{},
    Map<String, SharedHNotePartView> parts =
        const <String, SharedHNotePartView>{},
    Map<String, SharedWorkspaceFolder> folders =
        const <String, SharedWorkspaceFolder>{},
  }) : _snapshots = List<Future<WorkspaceContentSnapshotResponse>>.from(
         snapshots,
       ),
       _changes = List<_ChangeFuture>.from(changes),
       _hnotes = hnotes,
       _hnoteFutures = hnoteFutures,
       _parts = parts,
       _folders = folders;

  final List<Future<WorkspaceContentSnapshotResponse>> _snapshots;
  final List<_ChangeFuture> _changes;
  final Map<String, SharedHNote> _hnotes;
  final Map<String, Future<SharedHNote>> _hnoteFutures;
  final Map<String, SharedHNotePartView> _parts;
  final Map<String, SharedWorkspaceFolder> _folders;
  final List<String?> snapshotPageTokens = <String?>[];
  final List<String?> snapshotEtags = <String?>[];
  final List<String> changeAfters = <String>[];
  final List<String> noteRequests = <String>[];
  final List<String> notePartRequests = <String>[];
  final List<String> folderRequests = <String>[];

  @override
  Future<WorkspaceContentSnapshotResponse> contentSnapshot(
    String workspaceId, {
    String? pageToken,
    String? ifNoneMatch,
  }) {
    snapshotPageTokens.add(pageToken);
    snapshotEtags.add(ifNoneMatch);
    if (_snapshots.isEmpty) throw StateError('unexpected snapshot');
    return _snapshots.removeAt(0);
  }

  @override
  Future<WorkspaceContentRemoteResponse<SharedWorkspaceContentEventPage>>
  changes(String workspaceId, {required String after}) {
    changeAfters.add(after);
    if (_changes.isEmpty) throw StateError('unexpected changes');
    return _changes.removeAt(0);
  }

  @override
  Future<WorkspaceContentRemoteResponse<SharedWorkspaceFolder>> folder(
    String workspaceId,
    String folderId, {
    required String revisionId,
  }) async {
    final key = '$folderId@$revisionId';
    folderRequests.add(key);
    final folder = _folders[key] ?? _folders[folderId];
    return folder == null
        ? const WorkspaceContentRemoteResponse<SharedWorkspaceFolder>.failure(
            errorCode: 'FOLDER_NOT_FOUND',
          )
        : WorkspaceContentRemoteResponse<SharedWorkspaceFolder>.success(folder);
  }

  @override
  Future<WorkspaceContentRemoteResponse<SharedHNote>> note(
    String workspaceId,
    String noteId, {
    required String revisionId,
  }) async {
    final key = '$noteId@$revisionId';
    noteRequests.add(key);
    final noteFuture = _hnoteFutures[key];
    final note = noteFuture == null ? _hnotes[key] : await noteFuture;
    return note == null
        ? const WorkspaceContentRemoteResponse<SharedHNote>.failure(
            errorCode: 'NOTE_NOT_FOUND',
          )
        : WorkspaceContentRemoteResponse<SharedHNote>.success(note);
  }

  @override
  Future<WorkspaceContentRemoteResponse<SharedHNotePartView>> notePart(
    String workspaceId,
    String noteId,
    String part, {
    required String partRevisionId,
  }) async {
    final key = '$noteId@$part@$partRevisionId';
    notePartRequests.add(key);
    final value = _parts[key];
    return value == null
        ? const WorkspaceContentRemoteResponse<SharedHNotePartView>.failure(
            errorCode: 'NOTE_PART_NOT_FOUND',
          )
        : WorkspaceContentRemoteResponse<SharedHNotePartView>.success(value);
  }
}

final class _ProbeRemote extends _FakeRemote
    implements WorkspaceContentCursorProbePort {
  _ProbeRemote({
    required Future<WorkspaceContentRemoteResponse<String>> cursorResponse,
  }) : _cursorResponse = cursorResponse;

  final Future<WorkspaceContentRemoteResponse<String>> _cursorResponse;
  final List<String> cursorProbeWorkspaceIds = <String>[];

  @override
  Future<WorkspaceContentRemoteResponse<String>> currentContentCursor(
    String workspaceId,
  ) {
    cursorProbeWorkspaceIds.add(workspaceId);
    return _cursorResponse;
  }
}

final class _CancellableSnapshotRemote extends _FakeRemote
    implements WorkspaceContentSyncReadLeasePort {
  final Completer<void> started = Completer<void>();
  final Completer<WorkspaceContentSnapshotResponse> _snapshot =
      Completer<WorkspaceContentSnapshotResponse>();
  int cancelCalls = 0;

  void completeLate(WorkspaceContentSnapshotResponse response) {
    if (!_snapshot.isCompleted) _snapshot.complete(response);
  }

  @override
  WorkspaceContentReadLease<WorkspaceContentSnapshotResponse>
  leaseContentSnapshot(
    String workspaceId, {
    String? pageToken,
    String? ifNoneMatch,
  }) {
    if (!started.isCompleted) started.complete();
    return WorkspaceContentReadLease<WorkspaceContentSnapshotResponse>(
      result: _snapshot.future,
      cancel: () => cancelCalls += 1,
    );
  }

  @override
  WorkspaceContentReadLease<WorkspaceContentRemoteResponse<String>>
  leaseCurrentContentCursor(String workspaceId) => _immediateWorkspaceLease(
    const WorkspaceContentRemoteResponse<String>.failure(
      errorCode: 'UNEXPECTED_CURSOR_PROBE',
    ),
  );

  @override
  WorkspaceContentReadLease<
    WorkspaceContentRemoteResponse<SharedWorkspaceContentEventPage>
  >
  leaseChanges(String workspaceId, {required String after}) =>
      _immediateWorkspaceLease(
        const WorkspaceContentRemoteResponse<
          SharedWorkspaceContentEventPage
        >.failure(errorCode: 'UNEXPECTED_CHANGES'),
      );

  @override
  WorkspaceContentReadLease<
    WorkspaceContentRemoteResponse<SharedWorkspaceFolder>
  >
  leaseFolder(
    String workspaceId,
    String folderId, {
    required String revisionId,
  }) => _immediateWorkspaceLease(
    const WorkspaceContentRemoteResponse<SharedWorkspaceFolder>.failure(
      errorCode: 'UNEXPECTED_FOLDER',
    ),
  );

  @override
  WorkspaceContentReadLease<WorkspaceContentRemoteResponse<SharedHNote>>
  leaseNote(String workspaceId, String noteId, {required String revisionId}) =>
      _immediateWorkspaceLease(
        const WorkspaceContentRemoteResponse<SharedHNote>.failure(
          errorCode: 'UNEXPECTED_NOTE',
        ),
      );

  @override
  WorkspaceContentReadLease<WorkspaceContentRemoteResponse<SharedHNotePartView>>
  leaseNotePart(
    String workspaceId,
    String noteId,
    String part, {
    required String partRevisionId,
  }) => _immediateWorkspaceLease(
    const WorkspaceContentRemoteResponse<SharedHNotePartView>.failure(
      errorCode: 'UNEXPECTED_NOTE_PART',
    ),
  );
}

WorkspaceContentReadLease<T> _immediateWorkspaceLease<T>(T value) =>
    WorkspaceContentReadLease<T>(
      result: Future<T>.value(value),
      cancel: _noOpWorkspaceLease,
    );

void _noOpWorkspaceLease() {}

SharedWorkspaceContentSnapshot _snapshot({
  String id = 'snapshot-1',
  String cursor = '10',
  List<SharedWorkspaceFolder> folders = const <SharedWorkspaceFolder>[],
  List<SharedWorkspaceSnapshotObject> objects =
      const <SharedWorkspaceSnapshotObject>[],
  bool hasMore = false,
  String? nextPageToken,
}) {
  return SharedWorkspaceContentSnapshot(
    snapshotId: id,
    atCursor: cursor,
    folders: folders,
    objects: objects,
    hasMore: hasMore,
    nextPageToken: nextPageToken,
  );
}

SharedWorkspaceSnapshotObject _head(
  String noteId,
  String revisionId, {
  bool tombstone = false,
}) {
  return SharedWorkspaceSnapshotObject(
    ownerRef: SharedWorkspaceOwnerRef(
      workspaceId: 'workspace-1',
      kind: 'hnote',
      id: noteId,
    ),
    tombstone: tombstone,
    etag: '"$revisionId"',
    resourceRefs: const <SharedWorkspaceResourceRef>[],
    revisionId: revisionId,
  );
}

SharedWorkspaceContentEvent _event({
  required String kind,
  required String objectId,
  required String revisionId,
  required String changeType,
  required String cursor,
  bool tombstone = false,
}) {
  return SharedWorkspaceContentEvent(
    eventId: 'event-$cursor',
    workspaceId: 'workspace-1',
    cursor: cursor,
    operationId: 'operation-$cursor',
    occurredAt: DateTime.utc(2026, 8, 15),
    objectKind: kind,
    objectId: objectId,
    changeType: changeType,
    tombstone: tombstone,
    resourcePinDelta: const SharedWorkspaceResourcePinDelta(
      added: <String>[],
      released: <String>[],
    ),
    revisionId: revisionId,
  );
}

SharedWorkspaceFolder _folder(
  String folderId,
  String name, {
  String revision = 'folder-revision-1',
}) {
  return SharedWorkspaceFolder(
    folderId: folderId,
    workspaceId: 'workspace-1',
    parentFolderId: null,
    displayName: name,
    normalizedName: name.toLowerCase(),
    state: 'live',
    currentRevisionId: revision,
    etag: '"$revision"',
    contentCursor: '10',
  );
}

WorkspaceContentRemoteFolder _folderProjection(
  String id,
  String name, {
  String? systemSeedKey,
}) {
  return WorkspaceContentRemoteFolder(
    folderId: id,
    parentFolderId: null,
    displayName: name,
    normalizedName: name.toLowerCase(),
    state: 'live',
    currentRevisionId: 'folder-revision-1',
    etag: '"folder-revision-1"',
    contentCursor: '10',
    systemSeedKey: systemSeedKey,
  );
}

SharedHNote _hnote(
  String noteId,
  String revisionId,
  String title, {
  String? folderId,
}) {
  return SharedHNote(
    noteId: noteId,
    workspaceId: 'workspace-1',
    folderId: folderId,
    title: title,
    state: 'live',
    noteRevisionId: revisionId,
    raw: SharedHNotePart(
      partRevisionId: '$revisionId-raw',
      markdown: '# $title',
      contentHash: 'raw-$revisionId',
    ),
    outline: SharedHNotePart(
      partRevisionId: '$revisionId-outline',
      markdown: '',
      contentHash: 'outline-$revisionId',
    ),
    germination: SharedHNotePart(
      partRevisionId: '$revisionId-germination',
      markdown: '',
      contentHash: 'germination-$revisionId',
    ),
    resourceRefs: const <SharedHNoteResourceRef>[],
    etag: '"$revisionId"',
    contentCursor: '10',
    createdAt: DateTime.utc(2026, 8, 15, 8),
    updatedAt: DateTime.utc(2026, 8, 15, 8, 1),
  );
}

SharedHNote _sparseHNote(String noteId, String revisionId, String title) {
  return SharedHNote(
    noteId: noteId,
    workspaceId: 'workspace-1',
    folderId: null,
    title: title,
    state: 'live',
    noteRevisionId: revisionId,
    raw: SharedHNotePart(
      partRevisionId: '$revisionId-raw',
      markdown: '',
      contentHash: '',
    ),
    outline: SharedHNotePart(
      partRevisionId: '$revisionId-outline',
      markdown: '',
      contentHash: '',
    ),
    germination: SharedHNotePart(
      partRevisionId: '$revisionId-germination',
      markdown: '',
      contentHash: '',
    ),
    resourceRefs: const <SharedHNoteResourceRef>[],
    etag: '"$revisionId"',
    contentCursor: '10',
    createdAt: DateTime.utc(2026, 8, 15, 8),
    updatedAt: DateTime.utc(2026, 8, 15, 8, 1),
  );
}

SharedHNotePartView _partView({
  required String noteId,
  required String part,
  required String revisionId,
  required String markdown,
  required String contentHash,
}) {
  return SharedHNotePartView(
    noteId: noteId,
    part: part,
    partRevisionId: revisionId,
    markdown: markdown,
    contentHash: contentHash,
    etag: '"$revisionId"',
  );
}

V3FeedItem _localRemoteNote(
  String remoteId, {
  required String title,
  String? folderId,
  NoteSyncState state = NoteSyncState.synced,
}) {
  return V3FeedItem(
    id: remoteId,
    title: title,
    source: V3MaterialSource.note,
    createdAt: DateTime.utc(2026, 8, 15),
    rawBody: 'local',
    folderId: folderId,
    remoteNoteId: remoteId,
    noteRevisionId: 'revision-1',
    rawPartRevisionId: 'revision-1-raw',
    etag: '"revision-1"',
    contentCursor: '10',
    syncState: state,
  );
}
