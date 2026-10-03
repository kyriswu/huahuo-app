import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/database/database_worker.dart';
import 'package:huahuoai_app/core/database/database_write_queue.dart';
import 'package:huahuoai_app/core/database/recording_dao.dart';
import 'package:huahuoai_app/core/native/native_file_port.dart';
import 'package:huahuoai_app/core/storage/file_storage_port.dart';
import 'package:huahuoai_app/core/storage/private_recording_path_resolver.dart';
import 'package:huahuoai_app/core/storage/upload_draft_store.dart';
import 'package:huahuoai_app/features/recordings/data/local_recording_repository.dart';
import 'package:huahuoai_app/features/recordings/domain/recording_library.dart';

void main() {
  group('LocalRecordingRepository', () {
    test(
      'imports picked audio after private copy and restores metadata',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'huahuo-recording-db-',
        );
        addTearDown(() async {
          if (await root.exists()) {
            await root.delete(recursive: true);
          }
        });
        final snapshot = LocalDatabaseSnapshotStore(
          file: File('${root.path}/local-db.json'),
        );
        final db = AppDatabase(snapshotStore: snapshot);
        final storage = _FakeFileStorage();
        final repository = LocalRecordingRepository(
          database: db,
          fileStorage: storage,
        );

        final imported = await repository.importPickedRecording(
          _picked(),
          now: _time(),
        );

        expect(imported.ok, isTrue);
        final item = imported.value!;
        expect(item.source, RecordingLibrarySource.localImport);
        expect(item.format, RecordingLibraryFormat.m4a);
        expect(item.appPrivateUri, startsWith('app-private://'));
        expect(
          item.appPrivateUri,
          isNot(startsWith('app-private://recordings/')),
        );
        expect(storage.copiedRefs, <String>['picker:meeting']);

        final recovered = LocalRecordingRepository(
          database: AppDatabase(snapshotStore: snapshot),
          fileStorage: storage,
        );
        expect(recovered.list().rows.map((row) => row.recordingId), <String>[
          item.recordingId,
        ]);
        final persistedDrafts = recovered.uploadDraftsFor(item.recordingId);
        expect(persistedDrafts, hasLength(1));
        final draft = UploadDraft.fromRecord(persistedDrafts.single);
        expect(draft, isNotNull);
        expect(draft!.draftId, 'draft-${item.recordingId}');
        expect(draft.localRecordingId, item.recordingId);
        expect(draft.appPrivateUri, item.appPrivateUri);
        expect(draft.fileName, item.displayName);
        expect(draft.mimeType, 'audio/mp4');
        expect(draft.sizeBytes, item.sizeBytes);
        expect(draft.recordingSource, 'local_upload');
        expect(draft.stage, UploadDraftStage.localReady);
        final requestSeed = draft.uploadTokenKey.substring(
          'idem-upload-'.length,
        );
        expect(
          requestSeed,
          matches(RegExp('^${RegExp.escape(draft.draftId)}-[a-f0-9]{24}\$')),
        );
        expect(draft.completeUploadKey, 'idem-complete-$requestSeed');
        expect(draft.createRecordingKey, 'idem-create-recording-$requestSeed');
      },
    );

    test(
      'imports picked audio batches without silently dropping rows',
      () async {
        final successRepository = LocalRecordingRepository(
          database: AppDatabase(),
          fileStorage: _FakeFileStorage(),
        );

        final imported = await successRepository
            .importPickedRecordings(<PickedAudioFile>[
              _picked(displayName: 'Alpha.m4a', pickerRef: 'picker:alpha'),
              _picked(displayName: 'Beta.wav', pickerRef: 'picker:beta'),
            ], now: _time());

        expect(imported.ok, isTrue);
        expect(imported.imported, hasLength(2));
        expect(
          successRepository.list().rows.map((row) => row.displayName),
          unorderedEquals(<String>['Alpha.m4a', 'Beta.wav']),
        );

        final partialRepository = LocalRecordingRepository(
          database: AppDatabase(),
          fileStorage: _FakeFileStorage(),
        );
        final partial = await partialRepository
            .importPickedRecordings(<PickedAudioFile>[
              _picked(displayName: 'Safe.m4a', pickerRef: 'picker:safe'),
              _picked(displayName: 'Raw.part', pickerRef: 'picker:raw.part'),
            ], now: _time());

        expect(partial.ok, isFalse);
        expect(partial.imported.map((row) => row.displayName), <String>[
          'Safe.m4a',
        ]);
        expect(partial.error?.code, 'RECORDING_LOCAL_FILE_UNSAFE');
        expect(partialRepository.list().rows.single.displayName, 'Safe.m4a');
      },
    );

    test(
      'verified list repairs size and duration in related metadata',
      () async {
        final database = AppDatabase();
        final item = RecordingLibraryItem(
          recordingId: 'local-repair-1',
          source: RecordingLibrarySource.localImport,
          displayName: 'Card.m4a',
          deviceFilename: '20260701090000',
          appPrivateUri: 'app-private://recordings/card-repair-1.m4a',
          format: RecordingLibraryFormat.m4a,
          localFileState: RecordingLocalFileState.ready,
          status: RecordingLibraryStatus.localOnly,
          durationSeconds: 0,
          sizeBytes: 1,
          isFavorite: false,
          tagIds: const <String>[],
          createdAt: _time(),
          updatedAt: _time(),
        );
        database.upsertRecord(
          LocalTableName.localRecordings,
          item.recordingId,
          item.toRecord(),
        );
        final draft = createInitialUploadDraft(
          draftId: 'draft-${item.recordingId}',
          localRecordingId: item.recordingId,
          appPrivateUri: item.appPrivateUri!,
          fileName: item.displayName,
          mimeType: 'audio/mp4',
          sizeBytes: 1,
          durationSeconds: 0,
          sourceScene: 'raw_material',
          recordingSource: 'local_upload',
          updatedAt: _time(),
        );
        database.upsertRecord(
          LocalTableName.localRecordingUploadDrafts,
          draft.draftId,
          draft.toRecord(),
        );
        database.upsertRecord(
          LocalTableName.recordingCardDownloadedManifest,
          'device-file-1',
          <String, Object?>{
            'device_file_id': 'device-file-1',
            'local_file_id': item.recordingId,
            'app_private_uri': item.appPrivateUri,
            'actual_size_bytes': 1,
            'duration_seconds': 0,
          },
        );
        final repository = LocalRecordingRepository(
          database: database,
          fileStorage: _FakeFileStorage(
            statSizeBytes: 4096,
            statDurationSeconds: 75,
          ),
        );

        final page = await repository.verifiedList();

        expect(page.rows.single.sizeBytes, 4096);
        expect(page.rows.single.durationSeconds, 75);
        final repairedDraft = repository
            .uploadDraftsFor(item.recordingId)
            .single;
        expect(repairedDraft['size_bytes'], 4096);
        expect(repairedDraft['duration_seconds'], 75);
        final manifest = repository
            .downloadedManifestsFor(item.recordingId)
            .single;
        expect(manifest['actual_size_bytes'], 4096);
        expect(manifest['duration_seconds'], 75);
      },
    );

    test('migrates legacy files and rewrites related persisted URIs', () async {
      final root = await Directory.systemTemp.createTemp('huahuo-migration-');
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final legacyFile = File(
        '${root.path}/recordings/library/legacy-1/source.m4a',
      );
      await legacyFile.parent.create(recursive: true);
      await legacyFile.writeAsBytes(<int>[1, 2, 3, 4]);
      final database = AppDatabase();
      const oldUri = 'app-private://recordings/legacy-1/source.m4a';
      const recordingId = 'local-legacy-1';
      final item = RecordingLibraryItem(
        recordingId: recordingId,
        source: RecordingLibrarySource.localImport,
        displayName: 'Legacy.m4a',
        appPrivateUri: oldUri,
        format: RecordingLibraryFormat.m4a,
        localFileState: RecordingLocalFileState.ready,
        status: RecordingLibraryStatus.localOnly,
        durationSeconds: 4,
        sizeBytes: 4,
        isFavorite: false,
        tagIds: const <String>[],
        createdAt: _time(),
        updatedAt: _time(),
      );
      database.upsertRecord(
        LocalTableName.localRecordings,
        recordingId,
        item.toRecord(),
      );
      final draft = createInitialUploadDraft(
        draftId: 'draft-$recordingId',
        localRecordingId: recordingId,
        appPrivateUri: oldUri,
        fileName: item.displayName,
        mimeType: 'audio/mp4',
        sizeBytes: 4,
        durationSeconds: 4,
        sourceScene: 'raw_material',
        recordingSource: 'local_upload',
        updatedAt: _time(),
      );
      database.upsertRecord(
        LocalTableName.localRecordingUploadDrafts,
        draft.draftId,
        draft.toRecord(),
      );
      database.upsertRecord(
        LocalTableName.recordingCardDownloadedManifest,
        'manifest-1',
        <String, Object?>{
          'device_file_id': 'manifest-1',
          'local_file_id': recordingId,
          'app_private_uri': oldUri,
        },
      );
      final resolver = PrivateRecordingPathResolver(
        platform: PrivateRecordingPlatform.ios,
        applicationSupportDirectory: () async => root,
        documentsDirectory: () async => root,
      );
      final repository = LocalRecordingRepository(
        database: database,
        fileStorage: PathProviderFileStoragePort(pathResolver: resolver),
      );

      final page = await repository.verifiedList();

      final migrated = page.rows.single;
      expect(migrated.appPrivateUri, 'app-private://legacy-1-source.m4a');
      expect(await legacyFile.exists(), isTrue);
      expect(
        await File(
          '${root.path}/HuahuoAI/Recordings/legacy-1-source.m4a',
        ).readAsBytes(),
        <int>[1, 2, 3, 4],
      );
      expect(
        repository.uploadDraftsFor(recordingId).single['app_private_uri'],
        migrated.appPrivateUri,
      );
      expect(
        repository
            .downloadedManifestsFor(recordingId)
            .single['app_private_uri'],
        migrated.appPrivateUri,
      );
    });

    test('recovers complete private audio when metadata is missing', () async {
      final root = await Directory.systemTemp.createTemp('recording-recovery');
      addTearDown(() => root.delete(recursive: true));
      final recoveredFile = File(
        '${root.path}/HuahuoAI/Recordings/recovered-meeting.m4a',
      );
      await recoveredFile.parent.create(recursive: true);
      await recoveredFile.writeAsBytes(<int>[1, 2, 3, 4]);
      final resolver = PrivateRecordingPathResolver(
        platform: PrivateRecordingPlatform.ios,
        applicationSupportDirectory: () async => root,
        documentsDirectory: () async => root,
      );
      final repository = LocalRecordingRepository(
        database: AppDatabase(),
        fileStorage: PathProviderFileStoragePort(pathResolver: resolver),
        recoveryPathResolver: resolver,
      );

      final page = await repository.verifiedList();

      expect(page.rows, hasLength(1));
      expect(page.rows.single.displayName, 'recovered-meeting.m4a');
      expect(page.rows.single.localFileState, RecordingLocalFileState.ready);
      expect(
        page.rows.single.appPrivateUri,
        'app-private://recovered-meeting.m4a',
      );
      expect(page.rows.single.sizeBytes, 4);
    });

    test(
      'archives private media audio once with verified internal classification',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'recording-internal-archive',
        );
        addTearDown(() => root.delete(recursive: true));
        final source = File('${root.path}/private-media/capture.m4a');
        await source.parent.create(recursive: true);
        final bytes = <int>[1, 3, 5, 7, 9, 11];
        await source.writeAsBytes(bytes);
        final contentHash = sha256.convert(bytes).toString();
        final resolver = PrivateRecordingPathResolver(
          accountScope: 'internal-archive-owner',
          platform: PrivateRecordingPlatform.ios,
          applicationSupportDirectory: () async => root,
          documentsDirectory: () async => root,
        );
        final repository = LocalRecordingRepository(
          database: AppDatabase(),
          fileStorage: PathProviderFileStoragePort(
            pathResolver: resolver,
            privateAudioSourceResolver: (appPrivateUri) async =>
                appPrivateUri == 'app-private://private-media/capture.m4a'
                ? source
                : null,
          ),
          accountScope: 'internal-archive-owner',
          requireAuthenticatedAccount: true,
        );
        final recordedAt = DateTime.utc(2026, 9, 3, 9, 8, 7);

        Future<LocalRecordingResult<RecordingLibraryItem>> archive() {
          return repository.archivePrivateMediaAudio(
            sourceAppPrivateUri: 'app-private://private-media/capture.m4a',
            displayName: '内录-20260903-170807.m4a',
            mimeType: 'audio/mp4',
            sizeBytes: bytes.length,
            durationSeconds: 42,
            contentHash: contentHash,
            recordedAt: recordedAt,
          );
        }

        final first = await archive();
        final second = await archive();

        expect(first.ok, isTrue);
        expect(second.ok, isTrue);
        expect(second.value!.recordingId, first.value!.recordingId);
        expect(repository.list().rows, hasLength(1));
        expect(first.value!.source, RecordingLibrarySource.microphone);
        expect(first.value!.tagIds, contains(internalRecordingHistoryTagId));
        expect(first.value!.contentHash, contentHash);
        final archived = await resolver.resolveFile(
          first.value!.appPrivateUri!,
        );
        expect(await archived!.readAsBytes(), bytes);
        expect(await source.readAsBytes(), bytes);
      },
    );

    test(
      'recovers an orphan final file when another recording is already indexed',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'recording-orphan-recovery',
        );
        addTearDown(() => root.delete(recursive: true));
        final sourceFile = File('${root.path}/existing-source.m4a');
        await sourceFile.writeAsBytes(<int>[1, 2, 3, 4]);
        final resolver = PrivateRecordingPathResolver(
          accountScope: 'orphan-owner',
          platform: PrivateRecordingPlatform.ios,
          applicationSupportDirectory: () async => root,
          documentsDirectory: () async => root,
        );
        final repository = LocalRecordingRepository(
          database: AppDatabase(),
          fileStorage: PathProviderFileStoragePort(
            pathResolver: resolver,
            now: _time,
          ),
          accountScope: 'orphan-owner',
          requireAuthenticatedAccount: true,
          recoveryPathResolver: resolver,
        );
        final imported = await repository.importPickedRecording(
          _picked(
            pickerRef: 'picker:already-indexed',
            displayName: 'Already indexed.m4a',
            sourcePath: sourceFile.path,
          ),
          now: _time(),
        );
        expect(imported.ok, isTrue);
        final recordingsDirectory = await resolver.localRecordingsDirectory();
        final orphan = File('${recordingsDirectory.path}/orphan-final.m4a');
        await orphan.writeAsBytes(<int>[5, 6, 7, 8]);
        await File(
          '${recordingsDirectory.path}/unfinished.m4a.part',
        ).writeAsBytes(<int>[9]);
        await File(
          '${recordingsDirectory.path}/transient.m4a.tmp',
        ).writeAsBytes(<int>[10]);

        final firstPage = await repository.verifiedList();
        final secondPage = await repository.verifiedList();
        final orphanUri = resolver.localUri('orphan-final.m4a');

        expect(firstPage.rows, hasLength(2));
        expect(
          firstPage.rows.map((item) => item.recordingId),
          contains(imported.value!.recordingId),
        );
        expect(
          firstPage.rows.where((item) => item.appPrivateUri == orphanUri),
          hasLength(1),
        );
        expect(
          firstPage.rows.map((item) => item.displayName),
          isNot(
            anyOf(
              contains('unfinished.m4a.part'),
              contains('transient.m4a.tmp'),
            ),
          ),
        );
        expect(
          secondPage.rows.where((item) => item.appPrivateUri == orphanUri),
          hasLength(1),
        );
        expect(secondPage.rows, hasLength(2));
      },
    );

    test(
      'keeps a readable legacy file ready when migration is unavailable',
      () async {
        final database = AppDatabase();
        const recordingId = 'local-legacy-fallback';
        final item = RecordingLibraryItem(
          recordingId: recordingId,
          source: RecordingLibrarySource.localImport,
          displayName: 'Legacy.m4a',
          appPrivateUri: 'app-private://recordings/legacy/source.m4a',
          format: RecordingLibraryFormat.m4a,
          localFileState: RecordingLocalFileState.ready,
          status: RecordingLibraryStatus.localOnly,
          durationSeconds: 4,
          sizeBytes: 4,
          isFavorite: false,
          tagIds: const <String>[],
          createdAt: _time(),
          updatedAt: _time(),
        );
        database.upsertRecord(
          LocalTableName.localRecordings,
          recordingId,
          item.toRecord(),
        );
        final repository = LocalRecordingRepository(
          database: database,
          fileStorage: _FakeFileStorage(statExists: true, statSizeBytes: 4),
        );

        final page = await repository.verifiedList();

        expect(page.rows.single.appPrivateUri, item.appPrivateUri);
        expect(page.rows.single.localFileState, RecordingLocalFileState.ready);
      },
    );

    test(
      'persists a safe remote recording and content-line association',
      () async {
        final repository = LocalRecordingRepository(
          database: AppDatabase(),
          fileStorage: _FakeFileStorage(),
        );
        final imported = await repository.importPickedRecording(
          _picked(),
          now: _time(),
        );

        final linked = repository.linkRemoteRecording(
          localRecordingId: imported.value!.recordingId,
          remoteRecordingId: 'remote-recording-1',
          contentLineId: 'line-1',
          linkedAt: _time(),
        );

        expect(linked.ok, isTrue);
        expect(linked.value?.remoteRecordingId, 'remote-recording-1');
        expect(linked.value?.contentLineId, 'line-1');
        expect(linked.value?.hasServerChatContext, isTrue);
        expect(repository.list().rows.single.contentLineId, 'line-1');

        final invalid = repository.linkRemoteRecording(
          localRecordingId: imported.value!.recordingId,
          remoteRecordingId: 'remote-recording-1',
          contentLineId: '../line-1',
        );
        expect(invalid.ok, isFalse);
        expect(invalid.error?.code, 'RECORDING_REMOTE_LINK_INVALID');
      },
    );

    test(
      'copies picked audio into app-private storage and prepares export',
      () async {
        final sourceRoot = await Directory.systemTemp.createTemp(
          'huahuo-recording-source-',
        );
        final privateRoot = await Directory.systemTemp.createTemp(
          'huahuo-recording-private-',
        );
        addTearDown(() async {
          if (await sourceRoot.exists()) {
            await sourceRoot.delete(recursive: true);
          }
          if (await privateRoot.exists()) {
            await privateRoot.delete(recursive: true);
          }
        });
        final sourceFile = File('${sourceRoot.path}/meeting.m4a');
        await sourceFile.writeAsBytes(<int>[1, 2, 3, 4, 5]);
        final storage = PathProviderFileStoragePort(
          rootDirectory: () async => privateRoot,
          now: _time,
        );
        final repository = LocalRecordingRepository(
          database: AppDatabase(),
          fileStorage: storage,
        );

        final sourceHash = sha256.convert(<int>[1, 2, 3, 4, 5]).toString();
        final imported = await repository.importPickedRecording(
          _picked(sourcePath: sourceFile.path, contentHash: null),
          now: _time(),
        );

        expect(imported.ok, isTrue);
        final item = imported.value!;
        expect(item.appPrivateUri, startsWith('app-private://local-'));
        expect(item.contentHash, sourceHash);
        expect(item.appPrivateUri, isNot(contains(sourceRoot.path)));
        expect(item.appPrivateUri, isNot(contains(privateRoot.path)));
        final privateUri = Uri.parse(item.appPrivateUri!);
        final copied = File(
          '${privateRoot.path}/HuahuoAI/Recordings/${privateUri.host}',
        );
        expect(await copied.readAsBytes(), <int>[1, 2, 3, 4, 5]);

        final prepared = await repository.prepareExport(item.recordingId);

        expect(prepared.ok, isTrue);
        final export = prepared.value!;
        expect(export.opaqueExportRef, startsWith('app-private-export://'));
        expect(export.opaqueExportRef, isNot(contains(sourceRoot.path)));
        expect(export.opaqueExportRef, isNot(contains(privateRoot.path)));
        expect(export.displayName, 'Meeting.m4a');
        expect(export.mimeType, 'audio/mp4');
        expect(export.sizeBytes, 5);
        expect(export.contentHash, sourceHash);
        final exportUri = Uri.parse(export.opaqueExportRef);
        final exported = File(
          '${privateRoot.path}/HuahuoAI/TemporaryTransfers/export/cache/${exportUri.pathSegments[1]}/${exportUri.pathSegments[2]}',
        );
        expect(await exported.readAsBytes(), <int>[1, 2, 3, 4, 5]);

        await copied.delete();
        final page = await repository.verifiedList();
        expect(
          page.rows.single.localFileState,
          RecordingLocalFileState.missing,
        );

        expect(
          (await repository.deletePermanently(item.recordingId)).ok,
          isTrue,
        );
      },
    );

    test(
      'normalizes a renamed export using stable unknown-format metadata',
      () async {
        final database = AppDatabase();
        final item = _exportItem(
          recordingId: 'local-legacy-export',
          displayName: '用户标题.wav',
          format: RecordingLibraryFormat.unknown,
          originalFilename: 'original-capture.m4a',
          deviceFilename: 'device-capture.opus',
          appPrivateUri: 'app-private://legacy-export.mp3',
          contentHash:
              'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        );
        database.upsertRecord(
          LocalTableName.localRecordings,
          item.recordingId,
          item.toRecord(),
        );
        final storage = _FakeFileStorage(
          preparedContentHash:
              'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        );
        final repository = LocalRecordingRepository(
          database: database,
          fileStorage: storage,
        );

        final prepared = await repository.prepareExport(item.recordingId);

        expect(prepared.ok, isTrue);
        expect(prepared.value?.displayName, '用户标题.m4a');
        expect(prepared.value?.mimeType, 'audio/mp4');
        expect(storage.preparedDisplayNames, <String>['用户标题.m4a']);
        final persisted = repository.list().rows.single;
        expect(persisted.originalFilename, 'original-capture.m4a');
        expect(persisted.deviceFilename, 'device-capture.opus');
        expect(persisted.createdAt, _time());
      },
    );

    test(
      'prepares authenticated exports in the scoped native handoff path',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'recording-scoped-export',
        );
        addTearDown(() async {
          if (await root.exists()) await root.delete(recursive: true);
        });
        final resolver = PrivateRecordingPathResolver(
          accountScope: 'account-export-user',
          platform: PrivateRecordingPlatform.ios,
          applicationSupportDirectory: () async => root,
          documentsDirectory: () async => root,
        );
        final storage = PathProviderFileStoragePort(
          pathResolver: resolver,
          now: _time,
        );
        final source = File(
          '${(await resolver.localRecordingsDirectory()).path}/meeting.m4a',
        );
        await source.parent.create(recursive: true);
        await source.writeAsBytes(<int>[1, 2, 3, 4]);

        final prepared = await storage.prepareAudioExport(
          appPrivateUri: resolver.localUri('meeting.m4a'),
          displayName: '用户访谈.m4a',
        );

        expect(prepared.ok, isTrue);
        final scope = resolver.temporaryTransferDirectoryScope!;
        final value = prepared.value!;
        expect(
          value.opaqueExportRef,
          startsWith('app-private-export://recordings/users/$scope/cache/'),
        );
        expect(value.opaqueExportRef, isNot(contains('account-export-user')));
        final uri = Uri.parse(value.opaqueExportRef);
        final exported = File(
          '${root.path}/HuahuoAI/Users/$scope/TemporaryTransfers/export/cache/'
          '${uri.pathSegments[3]}/${uri.pathSegments[4]}',
        );
        expect(await exported.readAsBytes(), <int>[1, 2, 3, 4]);
      },
    );

    test(
      'recovers unknown export format from device then private metadata',
      () {
        final deviceFallback = _exportItem(
          format: RecordingLibraryFormat.unknown,
          originalFilename: 'original-without-extension',
          deviceFilename: 'device-file.opus',
          appPrivateUri: 'app-private://private-file.wav',
        );
        final privateFallback = _exportItem(
          recordingId: 'local-private-fallback',
          format: RecordingLibraryFormat.unknown,
          originalFilename: 'original-without-extension',
          appPrivateUri: 'app-private://private-file.wav',
        );

        expect(
          resolveRecordingLibraryExportFormat(deviceFallback),
          RecordingLibraryFormat.opus,
        );
        expect(
          resolveRecordingLibraryExportFormat(privateFallback),
          RecordingLibraryFormat.wav,
        );
      },
    );

    test(
      'rejects unresolvable, size-mismatched and hash-mismatched exports',
      () async {
        Future<LocalRecordingResult<PreparedAudioExport>> prepare(
          RecordingLibraryItem item,
          _FakeFileStorage storage,
        ) {
          final database = AppDatabase();
          database.upsertRecord(
            LocalTableName.localRecordings,
            item.recordingId,
            item.toRecord(),
          );
          return LocalRecordingRepository(
            database: database,
            fileStorage: storage,
          ).prepareExport(item.recordingId);
        }

        final unknownStorage = _FakeFileStorage();
        final unknown = await prepare(
          _exportItem(
            recordingId: 'local-export-unknown',
            format: RecordingLibraryFormat.unknown,
            originalFilename: 'original-without-extension',
            appPrivateUri: 'app-private://local-export-unknown',
          ),
          unknownStorage,
        );
        expect(unknown.error?.code, 'RECORDING_EXPORT_FORMAT_UNKNOWN');
        expect(unknownStorage.preparedExports, isEmpty);

        final sizeMismatch = await prepare(
          _exportItem(recordingId: 'local-export-size'),
          _FakeFileStorage(statSizeBytes: 1024),
        );
        expect(sizeMismatch.error?.code, 'RECORDING_EXPORT_SIZE_MISMATCH');

        final hashMismatch = await prepare(
          _exportItem(
            recordingId: 'local-export-hash',
            contentHash:
                'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          ),
          _FakeFileStorage(
            preparedContentHash:
                'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
          ),
        );
        expect(hashMismatch.error?.code, 'RECORDING_EXPORT_HASH_MISMATCH');
      },
    );

    test(
      'rejects missing and recycled recordings during export prepare',
      () async {
        final missingStorage = _FakeFileStorage(statExists: false);
        final missingRepository = LocalRecordingRepository(
          database: AppDatabase(),
          fileStorage: missingStorage,
        );
        final missingItem = (await missingRepository.importPickedRecording(
          _picked(),
          now: _time(),
        )).value!;

        final missing = await missingRepository.prepareExport(
          missingItem.recordingId,
        );

        expect(missing.ok, isFalse);
        expect(missing.error?.code, 'RECORDING_PRIVATE_FILE_MISSING');
        expect(missingStorage.preparedExports, isEmpty);
        expect(
          missingRepository.list().rows.single.localFileState,
          RecordingLocalFileState.missing,
        );

        final recycledStorage = _FakeFileStorage();
        final recycledRepository = LocalRecordingRepository(
          database: AppDatabase(),
          fileStorage: recycledStorage,
        );
        final recycledItem = (await recycledRepository.importPickedRecording(
          _picked(displayName: 'Recycle.m4a'),
          now: _time(),
        )).value!;
        recycledRepository.moveToTrash(recordingId: recycledItem.recordingId);

        final recycled = await recycledRepository.prepareExport(
          recycledItem.recordingId,
        );

        expect(recycled.ok, isFalse);
        expect(recycled.error?.code, 'RECORDING_EXPORT_RECYCLED');
        expect(recycledStorage.preparedExports, isEmpty);
      },
    );

    test('persists complete Wi-Fi staged metadata separately from source', () {
      final repository = LocalRecordingRepository(
        database: AppDatabase(),
        fileStorage: _FakeFileStorage(),
      );

      repository.upsertRecordingCardWifiBatchItem(
        transferId: 'wifi-transfer-1',
        batchId: 'wifi-batch-1',
        deviceFingerprint: 'card-fingerprint-1',
        deviceIdentity: 'serial:FW920001',
        deviceFileId: 'device-file-1',
        deviceFilename: '20260715090000.mp3',
        localFileKey: 'device-file-1',
        itemOrder: 0,
        expectedSizeBytes: 8192,
        attemptCount: 1,
        batchStage: 'transferring',
        stage: 'staged',
        idempotencyKey: 'wifi-idempotency-1',
        createdAt: _time(),
        updatedAt: _time(),
        fileFormat: 'mp3',
        contentHash:
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        stagedNativeFileId: 'card-11111111111111111111111111111111',
        stagedFileFormat: 'm4a',
        stagedSizeBytes: 8188,
        stagedContentHash:
            'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
        checkpointOnly: true,
      );

      final row = repository.recordingCardWifiBatchItems().single;
      expect(row['file_format'], 'mp3');
      expect(row['device_identity'], 'serial:FW920001');
      expect(row['expected_size_bytes'], 8192);
      expect(
        row['content_hash'],
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      );
      expect(
        row['staged_native_file_id'],
        'card-11111111111111111111111111111111',
      );
      expect(row['staged_file_format'], 'm4a');
      expect(row['staged_size_bytes'], 8188);
      expect(
        row['staged_content_hash'],
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      );
      for (final forbiddenKey in <String>[
        'app_private_uri',
        'local_path',
        'ssid',
        'password',
      ]) {
        expect(row.keys, isNot(contains(forbiddenKey)));
      }

      expect(
        () => repository.upsertRecordingCardWifiBatchItem(
          transferId: 'wifi-transfer-invalid',
          batchId: 'wifi-batch-invalid',
          deviceFingerprint: 'card-fingerprint-1',
          deviceIdentity: 'serial:FW920001',
          deviceFileId: 'device-file-2',
          deviceFilename: '20260715090100.mp3',
          localFileKey: 'device-file-2',
          itemOrder: 1,
          expectedSizeBytes: 4096,
          attemptCount: 1,
          batchStage: 'transferring',
          stage: 'staged',
          idempotencyKey: 'wifi-idempotency-invalid',
          createdAt: _time(),
          updatedAt: _time(),
          stagedNativeFileId: 'card-22222222222222222222222222222222',
        ),
        throwsArgumentError,
      );
      expect(
        repository.recordingCardWifiBatchItems(batchId: 'wifi-batch-invalid'),
        isEmpty,
      );

      expect(
        () => repository.upsertRecordingCardWifiBatchItem(
          transferId: 'wifi-transfer-invalid-source-hash',
          batchId: 'wifi-batch-invalid-source-hash',
          deviceFingerprint: 'card-fingerprint-1',
          deviceIdentity: 'serial:FW920001',
          deviceFileId: 'device-file-3',
          deviceFilename: '20260715090200.mp3',
          localFileKey: 'device-file-3',
          itemOrder: 2,
          expectedSizeBytes: 4096,
          attemptCount: 1,
          batchStage: 'transferring',
          stage: 'queued',
          idempotencyKey: 'wifi-idempotency-invalid-source-hash',
          createdAt: _time(),
          updatedAt: _time(),
          contentHash: 'not-a-sha256',
        ),
        throwsArgumentError,
      );
      expect(
        () => repository.upsertRecordingCardWifiBatchItem(
          transferId: 'wifi-transfer-conflicting-hashes',
          batchId: 'wifi-batch-conflicting-hashes',
          deviceFingerprint: 'card-fingerprint-1',
          deviceIdentity: 'serial:FW920001',
          deviceFileId: 'device-file-4',
          deviceFilename: '20260715090300.mp3',
          localFileKey: 'device-file-4',
          itemOrder: 3,
          expectedSizeBytes: 4096,
          attemptCount: 1,
          batchStage: 'transferring',
          stage: 'staged',
          idempotencyKey: 'wifi-idempotency-conflicting-hashes',
          createdAt: _time(),
          updatedAt: _time(),
          fileFormat: 'mp3',
          contentHash:
              'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          stagedNativeFileId: 'card-33333333333333333333333333333333',
          stagedFileFormat: 'mp3',
          stagedSizeBytes: 4096,
          stagedContentHash:
              'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        ),
        throwsArgumentError,
      );
      expect(
        () => repository.upsertRecordingCardWifiBatchItem(
          transferId: 'wifi-transfer-1',
          batchId: 'wifi-batch-1',
          deviceFingerprint: 'card-fingerprint-1',
          deviceIdentity: 'serial:FW920001',
          deviceFileId: 'different-device-file',
          deviceFilename: '20260715090000.mp3',
          localFileKey: 'device-file-1',
          itemOrder: 0,
          expectedSizeBytes: 8192,
          attemptCount: 2,
          batchStage: 'transferring',
          stage: 'registering',
          idempotencyKey: 'wifi-idempotency-1',
          createdAt: _time(),
          updatedAt: _time(),
          fileFormat: 'mp3',
          contentHash:
              'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        ),
        throwsStateError,
      );
      expect(
        repository.recordingCardWifiBatchItems().single['device_file_id'],
        'device-file-1',
      );
    });

    test('upgrades a fingerprint-only Wi-Fi identity exactly once', () {
      final repository = LocalRecordingRepository(
        database: AppDatabase(),
        fileStorage: _FakeFileStorage(),
      );
      const batchId = 'wifi-legacy-identity-batch';
      const fingerprint = 'card-fingerprint-legacy';
      const deviceFileId = 'device-file-legacy';
      const serialIdentity = 'serial:CARDLEGACY001';
      final legacyIdempotency = sha256
          .convert(utf8.encode('$fingerprint:$deviceFileId:$batchId'))
          .toString();
      final serialIdempotency = sha256
          .convert(utf8.encode('$serialIdentity:$deviceFileId:$batchId'))
          .toString();
      final cardDigest = sha256
          .convert(utf8.encode('CARDLEGACY001'))
          .toString();
      final ledgerSignature = 'b' * 64;

      void upsert({
        required String deviceIdentity,
        required String idempotencyKey,
        String? digest,
        String? signature,
        bool allowUpgrade = false,
      }) {
        repository.upsertRecordingCardWifiBatchItem(
          transferId: 'wifi-legacy-identity-transfer',
          batchId: batchId,
          deviceFingerprint: fingerprint,
          deviceIdentity: deviceIdentity,
          cardSnDigest: digest,
          deviceFileId: deviceFileId,
          deviceFilename: '20260905090000.m4a',
          localFileKey: 'legacy-local-key',
          itemOrder: 0,
          expectedSizeBytes: 4096,
          attemptCount: 0,
          batchStage: 'paused',
          stage: 'queued',
          idempotencyKey: idempotencyKey,
          createdAt: _time(),
          updatedAt: _time(),
          ledgerSourceSignature: signature,
          fileFormat: 'm4a',
          mimeType: 'audio/mp4',
          allowLegacyIdentityUpgrade: allowUpgrade,
        );
      }

      upsert(deviceIdentity: fingerprint, idempotencyKey: legacyIdempotency);
      expect(
        () => upsert(
          deviceIdentity: serialIdentity,
          idempotencyKey: serialIdempotency,
          digest: cardDigest,
          signature: ledgerSignature,
        ),
        throwsStateError,
      );

      upsert(
        deviceIdentity: serialIdentity,
        idempotencyKey: serialIdempotency,
        digest: cardDigest,
        signature: ledgerSignature,
        allowUpgrade: true,
      );
      final upgraded = repository.recordingCardWifiBatchItems().single;
      expect(upgraded['device_identity'], serialIdentity);
      expect(upgraded['card_sn_digest'], cardDigest);
      expect(upgraded['ledger_source_signature'], ledgerSignature);
      expect(upgraded['idempotency_key'], serialIdempotency);

      const otherIdentity = 'serial:CARDOTHER001';
      final otherDigest = sha256
          .convert(utf8.encode('CARDOTHER001'))
          .toString();
      final otherIdempotency = sha256
          .convert(utf8.encode('$otherIdentity:$deviceFileId:$batchId'))
          .toString();
      expect(
        () => upsert(
          deviceIdentity: otherIdentity,
          idempotencyKey: otherIdempotency,
          digest: otherDigest,
          signature: 'c' * 64,
          allowUpgrade: true,
        ),
        throwsStateError,
      );
    });

    test(
      'writes Wi-Fi batch checkpoints atomically and rolls back together',
      () {
        final repository = LocalRecordingRepository(
          database: AppDatabase(),
          fileStorage: _FakeFileStorage(),
        );

        void upsert({
          required String transferId,
          required int itemOrder,
          required String stage,
        }) {
          repository.upsertRecordingCardWifiBatchItem(
            transferId: transferId,
            batchId: 'wifi-batch-atomic',
            deviceFingerprint: 'card-fingerprint-1',
            deviceIdentity: 'serial:FW920001',
            deviceFileId: 'device-$transferId',
            deviceFilename: '$transferId.mp3',
            localFileKey: 'key-$transferId',
            itemOrder: itemOrder,
            expectedSizeBytes: 4096,
            attemptCount: 1,
            batchStage: 'transferring',
            stage: stage,
            idempotencyKey: 'idem-$transferId',
            createdAt: _time(),
            updatedAt: _time(),
            fileFormat: 'mp3',
            checkpointOnly: true,
          );
        }

        final committed = repository.writeRecordingCardWifiBatchAtomically(() {
          upsert(transferId: 'transfer-1', itemOrder: 0, stage: 'staged');
          upsert(transferId: 'transfer-2', itemOrder: 1, stage: 'queued');
        });

        expect(committed.ok, isTrue);
        expect(
          repository.recordingCardWifiBatchItems(batchId: 'wifi-batch-atomic'),
          hasLength(2),
        );

        final rolledBack = repository.writeRecordingCardWifiBatchAtomically(() {
          upsert(transferId: 'transfer-1', itemOrder: 0, stage: 'registering');
          repository.upsertRecordingCardWifiBatchItem(
            transferId: 'transfer-invalid',
            batchId: 'wifi-batch-atomic',
            deviceFingerprint: 'card-fingerprint-1',
            deviceIdentity: 'serial:FW920001',
            deviceFileId: 'device-invalid',
            deviceFilename: 'invalid.mp3',
            localFileKey: 'key-invalid',
            itemOrder: 2,
            expectedSizeBytes: 4096,
            attemptCount: 1,
            batchStage: 'registering',
            stage: 'staged',
            idempotencyKey: 'idem-invalid',
            createdAt: _time(),
            updatedAt: _time(),
            stagedNativeFileId: 'card-22222222222222222222222222222222',
            checkpointOnly: true,
          );
        });

        expect(rolledBack.ok, isFalse);
        final rows = repository.recordingCardWifiBatchItems(
          batchId: 'wifi-batch-atomic',
        );
        expect(rows, hasLength(2));
        expect(
          rows.singleWhere(
            (row) => row['transfer_id'] == 'transfer-1',
          )['stage'],
          'staged',
        );
        expect(
          rows.where((row) => row['transfer_id'] == 'transfer-invalid'),
          isEmpty,
        );
      },
    );

    test(
      'registers verified downloaded private audio metadata and rejects unsafe metadata',
      () async {
        final db = AppDatabase();
        final repository = LocalRecordingRepository(
          database: db,
          fileStorage: _FakeFileStorage(
            statSizeBytes: 4096,
            privateContentHash:
                'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd',
          ),
        );

        final registered = await repository.registerDownloadedRecording(
          file: const PrivateAudioFile(
            fileId: 'downloads/card-file-1.m4a',
            appPrivateUri: 'app-private://recording-card/card-file-1.m4a',
            displayName: 'Card Recording.m4a',
            mimeType: 'audio/mp4',
            sizeBytes: 4096,
            durationSeconds: 120,
            contentHash:
                'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd',
          ),
          deviceId: 'device-1',
          deviceFileId: 'card-file-1',
          deviceFingerprint: 'card-alpha',
          deviceFilename: 'CARD_001.m4a',
          downloadedAt: _time(),
        );

        expect(registered.ok, isTrue);
        final item = registered.value!;
        expect(item.source, RecordingLibrarySource.device);
        expect(item.deviceFilename, 'CARD_001.m4a');
        expect(item.appPrivateUri, startsWith('app-private://recording-card/'));
        expect(repository.list().rows.single.recordingId, item.recordingId);
        expect(
          repository.downloadedManifestsFor(item.recordingId),
          hasLength(1),
        );
        expect(
          db.listRecords(LocalTableName.deviceLocalRecordingMappings),
          hasLength(1),
        );

        final unsafeRepository = LocalRecordingRepository(
          database: AppDatabase(),
          fileStorage: _FakeFileStorage(),
        );

        final result = await unsafeRepository.registerDownloadedRecording(
          file: const PrivateAudioFile(
            fileId: 'downloads/card-file-1.m4a',
            appPrivateUri: 'app-private://recording-card/card-file-1.m4a',
            displayName: 'Card Recording.m4a',
            mimeType: 'audio/mp4',
            sizeBytes: 4096,
          ),
          deviceId: 'device-1',
          deviceFileId: 'card-file-1',
          deviceFingerprint: 'card-alpha',
          deviceFilename: r'D:\workspace\CARD_001.m4a',
          downloadedAt: _time(),
        );

        expect(result.ok, isFalse);
        expect(result.error?.code, 'RECORDING_LOCAL_FILE_UNSAFE');
        expect(unsafeRepository.list().rows, isEmpty);
      },
    );

    test(
      'verified card download ignores local rename and rejects persisted hash drift',
      () async {
        const originalHash =
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
        const differentHash =
            'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
        final database = AppDatabase();
        final repository = LocalRecordingRepository(
          database: database,
          fileStorage: _FakeFileStorage(statSizeBytes: 4096),
        );
        final registered = await repository.registerDownloadedRecording(
          file: const PrivateAudioFile(
            fileId: 'downloads/card-file-verified.m4a',
            appPrivateUri:
                'app-private://recording-card/card-file-verified.m4a',
            displayName: 'Original card name.m4a',
            mimeType: 'audio/mp4',
            sizeBytes: 4096,
            durationSeconds: 75,
            contentHash: originalHash,
          ),
          deviceId: 'card-fingerprint-current',
          deviceFileId: 'card-file-verified',
          deviceFingerprint: 'card-fingerprint-legacy',
          deviceFilename: '20260715153500.m4a',
          downloadedAt: _time(),
        );
        expect(registered.ok, isTrue);

        final renamed = await repository.rename(
          recordingId: registered.value!.recordingId,
          displayName: '用户自定义名称.m4a',
        );
        expect(renamed.ok, isTrue);
        final verifiedAfterRename = await repository
            .verifiedRecordingCardDownloads();
        expect(verifiedAfterRename, hasLength(1));
        expect(
          verifiedAfterRename.single.localRecordingId,
          registered.value!.recordingId,
        );
        expect(verifiedAfterRename.single.deviceFileId, 'card-file-verified');
        expect(verifiedAfterRename.single.contentHash, originalHash);
        expect(
          verifiedAfterRename.single.deviceIds,
          contains('card-fingerprint-current'),
        );

        final renamedRecord = repository.list().rows.single.toRecord();
        database.upsertRecord(
          LocalTableName.localRecordings,
          registered.value!.recordingId,
          <String, Object?>{...renamedRecord, 'content_hash': differentHash},
        );

        await expectLater(
          repository.verifiedRecordingCardDownloads(),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              'RECORDING_CARD_HASH_LEDGER_CONFLICT',
            ),
          ),
        );
      },
    );

    test(
      'legacy no-hash ledger persists its physically verified hash',
      () async {
        const originalHash =
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
        final database = AppDatabase();
        final dao = RecordingDao(database);
        final repository = LocalRecordingRepository(
          database: database,
          fileStorage: _FakeFileStorage(
            statSizeBytes: 4096,
            privateContentHash: originalHash,
          ),
        );
        final registered = await repository.registerDownloadedRecording(
          file: const PrivateAudioFile(
            fileId: 'downloads/card-file-legacy-no-hash.m4a',
            appPrivateUri:
                'app-private://recording-card/card-file-legacy-no-hash.m4a',
            displayName: 'Legacy card file.m4a',
            mimeType: 'audio/mp4',
            sizeBytes: 4096,
            contentHash: originalHash,
          ),
          deviceId: 'legacy-card',
          deviceFileId: 'legacy-card-file-no-hash',
          deviceFingerprint: 'legacy-card',
          deviceFilename: '20260715153600.m4a',
          downloadedAt: _time(),
        );
        expect(registered.ok, isTrue);

        final localRecord = Map<String, Object?>.of(
          dao.getLocalRecording(registered.value!.recordingId)!,
        )..remove('content_hash');
        final manifestRecord = Map<String, Object?>.of(
          dao.listDownloadedManifests().single,
        )..remove('content_hash');
        dao.upsertLocalRecording(registered.value!.recordingId, localRecord);
        dao.upsertDownloadedManifestRecord(manifestRecord);

        final verified = await repository.verifiedRecordingCardDownloads();

        expect(verified, hasLength(1));
        expect(verified.single.contentHash, originalHash);
        expect(
          dao.getLocalRecording(registered.value!.recordingId)?['content_hash'],
          originalHash,
        );
        expect(
          dao.listDownloadedManifests().single['content_hash'],
          originalHash,
        );
      },
    );

    test(
      'matching hash and size reuse a renamed recording-card local row',
      () async {
        const hash =
            'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
        final database = AppDatabase();
        final storage = _FakeFileStorage(
          statSizeBytes: 4096,
          privateContentHash: hash,
        );
        final repository = LocalRecordingRepository(
          database: database,
          fileStorage: storage,
        );
        final first = await repository.registerDownloadedRecording(
          file: const PrivateAudioFile(
            fileId: 'card-first.m4a',
            appPrivateUri: 'app-private://recording-card/card-first.m4a',
            displayName: 'First.m4a',
            mimeType: 'audio/mp4',
            sizeBytes: 4096,
            contentHash: hash,
          ),
          deviceId: 'card-1',
          deviceFileId: 'device-file-1',
          deviceFingerprint: 'card-1',
          deviceFilename: '20260715090001.m4a',
        );
        await repository.rename(
          recordingId: first.value!.recordingId,
          displayName: '用户重命名.m4a',
        );

        final second = await repository.registerDownloadedRecording(
          file: const PrivateAudioFile(
            fileId: 'card-second.m4a',
            appPrivateUri: 'app-private://recording-card/card-second.m4a',
            displayName: 'Second.m4a',
            mimeType: 'audio/mp4',
            sizeBytes: 4096,
            contentHash: hash,
          ),
          deviceId: 'card-1',
          deviceFileId: 'device-file-2',
          deviceFingerprint: 'card-1',
          deviceFilename: '20260715090002.m4a',
        );

        expect(second.ok, isTrue);
        expect(second.value?.recordingId, first.value?.recordingId);
        expect(second.value?.displayName, '用户重命名.m4a');
        expect(repository.list().rows, hasLength(1));
        expect(
          repository.downloadedManifestsFor(first.value!.recordingId),
          hasLength(2),
        );
        expect(
          storage.deletedUris,
          contains('app-private://recording-card/card-second.m4a'),
        );
      },
    );

    test(
      'download registration never revives a reusable row being deleted',
      () async {
        const hash =
            'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee';
        final database = AppDatabase();
        final storage = _FakeFileStorage(
          statSizeBytes: 4096,
          privateContentHash: hash,
        );
        final existing = _exportItem(
          recordingId: 'deleting-reusable-row',
          source: RecordingLibrarySource.device,
          appPrivateUri: 'app-private://recording-card/deleting-old.m4a',
          contentHash: hash,
        ).copyWith(sizeBytes: 4096);
        database.upsertRecord(
          LocalTableName.localRecordings,
          existing.recordingId,
          existing.toRecord(),
        );
        final ledger = _FakeDeletionLedger(
          events: <String>[],
          deletingRecordingIds: <String>{existing.recordingId},
        );
        final repository = LocalRecordingRepository(
          database: database,
          fileStorage: storage,
          deletionLedger: ledger,
        );

        final registered = await repository.registerDownloadedRecording(
          file: const PrivateAudioFile(
            fileId: 'card-new-after-delete.m4a',
            appPrivateUri:
                'app-private://recording-card/card-new-after-delete.m4a',
            displayName: 'New copy.m4a',
            mimeType: 'audio/mp4',
            sizeBytes: 4096,
            contentHash: hash,
          ),
          deviceId: 'card-2',
          deviceFileId: 'device-file-new',
          deviceFingerprint: 'card-2',
          deviceFilename: '20260715090003.m4a',
        );

        expect(registered.ok, isTrue);
        expect(registered.value?.recordingId, isNot(existing.recordingId));
        expect(
          repository.findById(existing.recordingId)?.recordingId,
          existing.recordingId,
        );
        expect(repository.list().rows, hasLength(2));
        expect(storage.deletedUris, isEmpty);
        expect(
          repository
              .downloadedManifestsFor(registered.value!.recordingId)
              .single['local_file_id'],
          registered.value!.recordingId,
        );
      },
    );

    test(
      'manual resync creates a new local generation from tombstone',
      () async {
        const hash =
            'abababababababababababababababababababababababababababababababab';
        const oldLocalRecordingId = 'local-removed-generation';
        final database = AppDatabase();
        final dao = RecordingDao(database);
        final deletedAt = _time().add(const Duration(minutes: 3));
        dao.upsertDownloadedManifest(
          deviceFileId: 'device-file-resync',
          deviceFingerprint: 'serial:card-resync',
          deviceFilename: '20260904123000.m4a',
          localFileId: oldLocalRecordingId,
          appPrivateUri: 'app-private://recording-card/old-resync.m4a',
          expectedSizeBytes: 4096,
          actualSizeBytes: 4096,
          durationSeconds: 30,
          contentHash: hash,
          downloadedAt: _time().toIso8601String(),
          updatedAt: _time().toIso8601String(),
        );
        dao.updateDownloadedManifestLocalState(
          localFileId: oldLocalRecordingId,
          localState: 'localDeleted',
          updatedAt: deletedAt.toIso8601String(),
          localDeletedAt: deletedAt.toIso8601String(),
        );
        final repository = LocalRecordingRepository(
          database: database,
          fileStorage: _FakeFileStorage(
            statSizeBytes: 4096,
            privateContentHash: hash,
          ),
        );

        final registered = await repository.registerDownloadedRecording(
          file: const PrivateAudioFile(
            fileId: 'recording-card/resync-copy.m4a',
            appPrivateUri: 'app-private://recording-card/resync-copy.m4a',
            displayName: 'Resynced.m4a',
            mimeType: 'audio/mp4',
            sizeBytes: 4096,
            durationSeconds: 30,
            contentHash: hash,
          ),
          deviceId: 'card-reconnect-alias',
          deviceFileId: 'device-file-resync',
          deviceFingerprint: 'serial:card-resync',
          deviceFilename: '20260904123000.m4a',
        );

        expect(registered.ok, isTrue);
        expect(registered.value?.recordingId, startsWith('local-resync-'));
        expect(registered.value?.recordingId, isNot(oldLocalRecordingId));
        expect(repository.findById(oldLocalRecordingId), isNull);
        expect(
          dao.listDownloadedManifests().single['local_file_id'],
          registered.value?.recordingId,
        );
        expect(dao.listDownloadedManifests().single['local_state'], 'synced');
      },
    );

    test(
      'replays a reusable recording row after the first worker flush fails',
      () async {
        const hash =
            'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd';
        final root = await Directory.systemTemp.createTemp(
          'huahuo-recording-reusable-replay-',
        );
        final file = File('${root.path}/local.sqlite');
        final store = LocalDatabaseSnapshotStore(
          file: file,
          backend: LocalDatabaseSnapshotBackend.sqlite,
        );
        final delegate = await DatabaseWorker.start(file: file);
        final worker = _FailFirstWriteWorker(delegate);
        final queue = DatabaseWriteQueue();
        addTearDown(() async {
          if (!queue.isDisposed) await queue.dispose();
          if (!delegate.isDisposed) await delegate.dispose();
          if (await root.exists()) await root.delete(recursive: true);
        });
        final database = AppDatabase(
          snapshotStore: store,
          writeWorker: worker,
          writeQueue: queue,
        );
        final repository = LocalRecordingRepository(
          database: database,
          fileStorage: _FakeFileStorage(
            statSizeBytes: 4096,
            privateContentHash: hash,
          ),
        );

        final first = await repository.registerDownloadedRecording(
          file: const PrivateAudioFile(
            fileId: 'failed-first-copy.m4a',
            appPrivateUri: 'app-private://recording-card/failed-first-copy.m4a',
            displayName: 'Failed first copy.m4a',
            mimeType: 'audio/mp4',
            sizeBytes: 4096,
            contentHash: hash,
          ),
          deviceId: 'card-1',
          deviceFileId: 'device-file-first',
          deviceFingerprint: 'card-1',
          deviceFilename: '20260715090001.m4a',
        );

        expect(first.ok, isFalse);
        expect(first.error?.code, 'RECORDING_DOWNLOAD_LEDGER_WRITE_FAILED');
        expect(repository.list().rows, hasLength(1));
        final retained = repository.list().rows.single;

        final second = await repository.registerDownloadedRecording(
          file: const PrivateAudioFile(
            fileId: 'retry-copy.m4a',
            appPrivateUri: 'app-private://recording-card/retry-copy.m4a',
            displayName: 'Retry copy.m4a',
            mimeType: 'audio/mp4',
            sizeBytes: 4096,
            contentHash: hash,
          ),
          deviceId: 'card-1',
          deviceFileId: 'device-file-retry',
          deviceFingerprint: 'card-1',
          deviceFilename: '20260715090002.m4a',
        );

        expect(second.ok, isTrue);
        expect(second.value?.recordingId, retained.recordingId);
        final reopenedDao = RecordingDao(AppDatabase(snapshotStore: store));
        final local = reopenedDao.listLocalRecordings().single;
        final mapping = reopenedDao.listDeviceLocalMappings().single;
        final manifest = reopenedDao.listDownloadedManifests().single;
        expect(mapping['local_recording_id'], local['recording_id']);
        expect(manifest['local_file_id'], local['recording_id']);
        expect(manifest['content_hash'], local['content_hash']);
      },
    );

    test(
      'does not register a downloaded recording before private commit',
      () async {
        final repository = LocalRecordingRepository(
          database: AppDatabase(),
          fileStorage: _FakeFileStorage(statExists: false, statSizeBytes: null),
        );

        final result = await repository.registerDownloadedRecording(
          file: const PrivateAudioFile(
            fileId: 'card-file-2',
            appPrivateUri: 'app-private://recording-card/card-file-2.m4a',
            displayName: 'Card Recording 2.m4a',
            mimeType: 'audio/mp4',
            sizeBytes: 4096,
          ),
          deviceId: 'device-1',
          deviceFileId: 'card-file-2',
          deviceFingerprint: 'card-alpha',
          deviceFilename: 'CARD_002.m4a',
        );

        expect(result.ok, isFalse);
        expect(result.error?.code, 'RECORDING_PRIVATE_FILE_MISSING');
        expect(repository.list().rows, isEmpty);
      },
    );

    test(
      'registers a completed native voice file only after byte verification',
      () async {
        final repository = LocalRecordingRepository(
          database: AppDatabase(),
          fileStorage: _FakeFileStorage(statSizeBytes: 333),
        );

        final registered = await repository.registerNativeVoiceRecording(
          file: const PrivateAudioFile(
            fileId: 'voice-1',
            appPrivateUri: 'app-private://voice-1.m4a',
            displayName: 'Voice-1.m4a',
            mimeType: 'audio/mp4',
            sizeBytes: 333,
            durationSeconds: 3,
            contentHash:
                'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee',
          ),
          recordedAt: _time(),
          tagIds: const <String>[monologueRecordingHistoryTagId],
        );

        expect(registered.ok, isTrue);
        expect(registered.value?.source, RecordingLibrarySource.microphone);
        expect(registered.value?.appPrivateUri, 'app-private://voice-1.m4a');
        expect(
          registered.value?.tagIds,
          contains(monologueRecordingHistoryTagId),
        );
        expect(isMonologueRecordingHistoryItem(registered.value!), isTrue);

        final missing =
            await LocalRecordingRepository(
              database: AppDatabase(),
              fileStorage: _FakeFileStorage(
                statExists: false,
                statSizeBytes: null,
              ),
            ).registerNativeVoiceRecording(
              file: const PrivateAudioFile(
                fileId: 'voice-2',
                appPrivateUri: 'app-private://voice-2.m4a',
                displayName: 'Voice-2.m4a',
                mimeType: 'audio/mp4',
                sizeBytes: 333,
                durationSeconds: 3,
                contentHash:
                    'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee',
              ),
            );

        expect(missing.ok, isFalse);
        expect(missing.error?.code, 'RECORDING_PRIVATE_FILE_MISSING');
      },
    );

    test('rejects part and unsafe references without formal rows', () async {
      final partRepository = LocalRecordingRepository(
        database: AppDatabase(),
        fileStorage: _FakeFileStorage(),
      );
      final part = await partRepository.importPickedRecording(
        _picked(pickerRef: 'picker:raw.part'),
        now: _time(),
      );
      expect(part.ok, isFalse);
      expect(part.error?.code, 'RECORDING_LOCAL_FILE_UNSAFE');
      expect(partRepository.list().rows, isEmpty);

      final sourcePartRoot = await Directory.systemTemp.createTemp(
        'huahuo-recording-part-source-',
      );
      addTearDown(() async {
        if (await sourcePartRoot.exists()) {
          await sourcePartRoot.delete(recursive: true);
        }
      });
      final sourcePartFile = File('${sourcePartRoot.path}/raw.m4a.part');
      await sourcePartFile.writeAsBytes(<int>[1, 2, 3]);
      final sourcePartRepository = LocalRecordingRepository(
        database: AppDatabase(),
        fileStorage: PathProviderFileStoragePort(
          rootDirectory: () async => sourcePartRoot,
          now: _time,
        ),
      );
      final sourcePart = await sourcePartRepository.importPickedRecording(
        _picked(sourcePath: sourcePartFile.path),
        now: _time(),
      );
      expect(sourcePart.ok, isFalse);
      expect(sourcePart.error?.code, 'RECORDING_SOURCE_PATH_UNSAFE');
      expect(sourcePartRepository.list().rows, isEmpty);

      final unsafeRepository = LocalRecordingRepository(
        database: AppDatabase(),
        fileStorage: _FakeFileStorage(appPrivateUri: 'file:///Users/raw.m4a'),
      );
      final unsafe = await unsafeRepository.importPickedRecording(
        _picked(),
        now: _time(),
      );
      expect(unsafe.ok, isFalse);
      expect(unsafeRepository.list().rows, isEmpty);
    });

    test(
      'restores historical recycled rows without deleting private audio',
      () async {
        final db = AppDatabase();
        final storage = _FakeFileStorage();
        final repository = LocalRecordingRepository(
          database: db,
          fileStorage: storage,
        );
        final recordingId = (await repository.importPickedRecording(
          _picked(),
          now: _time(),
        )).value!.recordingId;
        repository.updateTags(
          recordingId: recordingId,
          tagIds: const <String>['historical', 'keep'],
        );
        repository.setFavorite(recordingId: recordingId, isFavorite: true);
        final deletedAt = DateTime.utc(2026, 7, 15, 8, 30);
        final recycled = repository
            .moveToTrash(recordingId: recordingId, deletedAt: deletedAt)
            .value!;

        final migrated = repository.restoreHistoricalRecycledRecordings();

        expect(migrated.ok, isTrue);
        expect(migrated.value, 1);
        final restored = repository.list().rows.single;
        expect(restored.recordingId, recordingId);
        expect(restored.status, RecordingLibraryStatus.localOnly);
        expect(restored.appPrivateUri, recycled.appPrivateUri);
        expect(restored.displayName, recycled.displayName);
        expect(restored.tagIds, recycled.tagIds);
        expect(restored.isFavorite, isTrue);
        expect(restored.createdAt, recycled.createdAt);
        expect(restored.updatedAt, recycled.updatedAt);
        expect(restored.deletedAt, isNull);
        expect(storage.deletedUris, isEmpty);
        expect(
          db.getRecord<LocalDatabaseRecord>(
            LocalTableName.localRecordingTrash,
            recordingId,
          ),
          isNull,
        );
        expect(repository.restoreHistoricalRecycledRecordings().value, 0);
      },
    );

    test(
      'supports rename tags favorite trash restore and permanent delete',
      () async {
        final db = AppDatabase();
        final storage = _FakeFileStorage();
        final repository = LocalRecordingRepository(
          database: db,
          fileStorage: storage,
        );
        final recordingId = (await repository.importPickedRecording(
          _picked(),
          now: _time(),
        )).value!.recordingId;

        final renamed = await repository.rename(
          recordingId: recordingId,
          displayName: 'Renamed.m4a',
        );
        expect(renamed.value?.displayName, 'Renamed.m4a');
        expect(storage.renamed.values.single, 'Renamed.m4a');

        final unsafeRename = await repository.rename(
          recordingId: recordingId,
          displayName: r'D:\workspace\raw.wav',
        );
        expect(unsafeRename.ok, isFalse);

        final tagged = repository.updateTags(
          recordingId: recordingId,
          tagIds: <String>['customer', 'customer', 'todo'],
        );
        expect(tagged.value?.tagIds, <String>['customer', 'todo']);
        expect(
          db.listRecords(LocalTableName.localRecordingTagLinks),
          hasLength(2),
        );

        expect(
          repository
              .setFavorite(recordingId: recordingId, isFavorite: true)
              .value
              ?.isFavorite,
          isTrue,
        );
        expect(
          repository.moveToTrash(recordingId: recordingId).value?.status,
          RecordingLibraryStatus.recycled,
        );
        expect(repository.list().rows, isEmpty);
        expect(
          repository
              .list(
                query: const RecordingLibraryQuery(
                  view: RecordingLibraryView.recycleBin,
                ),
              )
              .rows,
          hasLength(1),
        );
        expect(
          repository.restoreFromTrash(recordingId: recordingId).value?.status,
          RecordingLibraryStatus.localOnly,
        );

        expect((await repository.deletePermanently(recordingId)).ok, isTrue);
        expect(repository.list().rows, isEmpty);
        expect(storage.deletedUris, hasLength(1));
        expect(
          db.listRecords(LocalTableName.localRecordingUploadDrafts),
          isEmpty,
        );
      },
    );

    test('rejects permanent deletion while an upload is active', () async {
      final db = AppDatabase();
      final storage = _FakeFileStorage();
      final uploadStore = UploadDraftStore(database: db);
      final repository = LocalRecordingRepository(
        database: db,
        fileStorage: storage,
        uploadDraftStore: uploadStore,
      );
      final recordingId = (await repository.importPickedRecording(
        _picked(),
        now: _time(),
      )).value!.recordingId;
      final draft = uploadStore.listRecoverableDrafts().single;
      uploadStore.saveDraft(
        draft.copyWith(
          stage: UploadDraftStage.objectUploading,
          updatedAt: _time().add(const Duration(minutes: 1)),
        ),
      );

      final result = await repository.deletePermanently(recordingId);

      expect(result.ok, isFalse);
      expect(result.error?.code, 'RECORDING_DELETE_UPLOAD_IN_PROGRESS');
      expect(storage.deletedUris, isEmpty);
      expect(repository.findById(recordingId), isNotNull);
    });

    test('upload operation lease blocks deletion until released', () async {
      final db = AppDatabase();
      final storage = _FakeFileStorage();
      final repository = LocalRecordingRepository(
        database: db,
        fileStorage: storage,
      );
      final recordingId = (await repository.importPickedRecording(
        _picked(),
        now: _time(),
      )).value!.recordingId;

      expect(repository.beginUploadOperation(recordingId), isTrue);
      final blocked = await repository.deletePermanently(recordingId);

      expect(blocked.ok, isFalse);
      expect(blocked.error?.code, 'RECORDING_DELETE_UPLOAD_IN_PROGRESS');
      expect(storage.deletedUris, isEmpty);
      repository.finishUploadOperation(recordingId);
      expect((await repository.deletePermanently(recordingId)).ok, isTrue);
    });

    test(
      'locks card deletion before bytes and preserves durable history',
      () async {
        final events = <String>[];
        final db = AppDatabase();
        final storage = _FakeFileStorage(onDelete: (_) => events.add('file'));
        final ledger = _FakeDeletionLedger(events: events);
        final repository = LocalRecordingRepository(
          database: db,
          fileStorage: storage,
          deletionLedger: ledger,
        );
        final item = _exportItem(
          recordingId: 'card-local-1',
          source: RecordingLibrarySource.device,
          deviceFilename: 'REC_001.m4a',
        );
        db.upsertRecord(
          LocalTableName.localRecordings,
          item.recordingId,
          item.toRecord(),
        );
        final dao = RecordingDao(db);
        dao.upsertDeviceLocalMapping(
          deviceId: 'device-a',
          deviceFileKey: 'file-a',
          localRecordingId: item.recordingId,
          syncStatus: 'synced',
          updatedAt: _time().toIso8601String(),
        );
        dao.upsertDownloadedManifest(
          deviceFileId: 'file-a',
          deviceFingerprint: 'device-a',
          deviceFilename: 'REC_001.m4a',
          localFileId: item.recordingId,
          appPrivateUri: item.appPrivateUri!,
          expectedSizeBytes: item.sizeBytes,
          actualSizeBytes: item.sizeBytes,
          durationSeconds: item.durationSeconds,
          contentHash: item.contentHash,
          downloadedAt: _time().toIso8601String(),
          updatedAt: _time().toIso8601String(),
        );
        db.upsertRecord(
          LocalTableName.recordingTranscriptionReceipts,
          'receipt-1',
          <String, Object?>{
            'user_scope': 'scope-a',
            'file_identity': 'file-a',
            'local_recording_id': item.recordingId,
            'remote_recording_id': 'remote-1',
          },
        );
        db.upsertRecord(
          LocalTableName.localTransferRecords,
          'batch-item-1',
          <String, Object?>{
            'transfer_kind': 'recording_batch_transcription',
            'local_recording_id': item.recordingId,
            'batch_id': 'batch-1',
          },
        );
        final remoteDraft =
            createInitialUploadDraft(
              draftId: 'draft-card-local-1',
              localRecordingId: item.recordingId,
              appPrivateUri: item.appPrivateUri!,
              fileName: item.displayName,
              mimeType: 'audio/mp4',
              sizeBytes: item.sizeBytes,
              durationSeconds: item.durationSeconds,
              sourceScene: 'raw_material',
              recordingSource: 'recording_card',
              updatedAt: _time(),
              contentHash: item.contentHash,
            ).copyWith(
              stage: UploadDraftStage.asrQueued,
              recordingId: 'remote-1',
              updatedAt: _time(),
            );
        UploadDraftStore(database: db).saveDraft(remoteDraft);

        final result = await repository.deletePermanently(item.recordingId);

        expect(result.ok, isTrue);
        expect(events, <String>['begin', 'file', 'finish']);
        expect(repository.findById(item.recordingId), isNull);
        expect(dao.listDeviceLocalMappings(), hasLength(1));
        expect(dao.listDownloadedManifests(), hasLength(1));
        expect(
          dao.listDownloadedManifests().single['local_state'],
          'localDeleted',
        );
        expect(
          DateTime.tryParse(
            '${dao.listDownloadedManifests().single['local_deleted_at']}',
          ),
          isNotNull,
        );
        expect(
          db.listRecords(LocalTableName.recordingTranscriptionReceipts),
          hasLength(1),
        );
        expect(
          db.listRecords(LocalTableName.localTransferRecords),
          hasLength(1),
        );
        expect(
          db.listRecords(LocalTableName.localRecordingUploadDrafts),
          hasLength(1),
        );
      },
    );

    test('restores the card ledger when private deletion fails', () async {
      final events = <String>[];
      final db = AppDatabase();
      final item = _exportItem(
        recordingId: 'card-delete-failure',
        source: RecordingLibrarySource.device,
      );
      db.upsertRecord(
        LocalTableName.localRecordings,
        item.recordingId,
        item.toRecord(),
      );
      final repository = LocalRecordingRepository(
        database: db,
        fileStorage: _FakeFileStorage(deleteSucceeds: false),
        deletionLedger: _FakeDeletionLedger(events: events),
      );

      final result = await repository.deletePermanently(item.recordingId);

      expect(result.ok, isFalse);
      expect(events, <String>['begin', 'restore']);
      expect(repository.findById(item.recordingId), isNotNull);
    });

    test(
      'restart deletion recovery restores synced when bytes remain',
      () async {
        final db = AppDatabase();
        final events = <String>[];
        final item = _exportItem(
          recordingId: 'recover-delete-existing',
          source: RecordingLibrarySource.device,
          deviceFilename: 'REC_EXISTING.m4a',
        );
        db.upsertRecord(
          LocalTableName.localRecordings,
          item.recordingId,
          item.toRecord(),
        );
        final dao = RecordingDao(db);
        dao.upsertDownloadedManifest(
          deviceFileId: 'file-existing',
          deviceFingerprint: 'device-a',
          deviceFilename: 'REC_EXISTING.m4a',
          localFileId: item.recordingId,
          appPrivateUri: item.appPrivateUri!,
          expectedSizeBytes: item.sizeBytes,
          actualSizeBytes: item.sizeBytes,
          durationSeconds: item.durationSeconds,
          contentHash: item.contentHash,
          downloadedAt: _time().toIso8601String(),
          updatedAt: _time().toIso8601String(),
        );
        dao.updateDownloadedManifestLocalState(
          localFileId: item.recordingId,
          localState: 'deleting',
          updatedAt: _time().toIso8601String(),
        );
        final ledger = _FakeDeletionLedger(
          events: events,
          deletingRecordingIds: <String>{item.recordingId},
        );
        final repository = LocalRecordingRepository(
          database: db,
          fileStorage: _FakeFileStorage(),
          deletionLedger: ledger,
        );

        final result = await repository.recoverInterruptedLocalDeletions();

        expect(result.ok, isTrue);
        expect(result.value, 1);
        expect(events, <String>['restore']);
        expect(repository.findById(item.recordingId), isNotNull);
        expect(dao.listDownloadedManifests().single['local_state'], 'synced');
        expect(ledger.deletionInProgressLocalRecordingIds(), isEmpty);
      },
    );

    test('restart deletion recovery finalizes absent private bytes', () async {
      final db = AppDatabase();
      final events = <String>[];
      final item = _exportItem(
        recordingId: 'recover-delete-absent',
        source: RecordingLibrarySource.device,
        deviceFilename: 'REC_ABSENT.m4a',
      );
      db.upsertRecord(
        LocalTableName.localRecordings,
        item.recordingId,
        item.toRecord(),
      );
      final dao = RecordingDao(db);
      dao.upsertDeviceLocalMapping(
        deviceId: 'device-a',
        deviceFileKey: 'file-absent',
        localRecordingId: item.recordingId,
        syncStatus: 'synced',
        updatedAt: _time().toIso8601String(),
      );
      dao.upsertDownloadedManifest(
        deviceFileId: 'file-absent',
        deviceFingerprint: 'device-a',
        deviceFilename: 'REC_ABSENT.m4a',
        localFileId: item.recordingId,
        appPrivateUri: item.appPrivateUri!,
        expectedSizeBytes: item.sizeBytes,
        actualSizeBytes: item.sizeBytes,
        durationSeconds: item.durationSeconds,
        contentHash: item.contentHash,
        downloadedAt: _time().toIso8601String(),
        updatedAt: _time().toIso8601String(),
      );
      dao.updateDownloadedManifestLocalState(
        localFileId: item.recordingId,
        localState: 'deleting',
        updatedAt: _time().toIso8601String(),
      );
      final ledger = _FakeDeletionLedger(
        events: events,
        deletingRecordingIds: <String>{item.recordingId},
      );
      final repository = LocalRecordingRepository(
        database: db,
        fileStorage: _FakeFileStorage(statExists: false, statSizeBytes: null),
        deletionLedger: ledger,
      );

      final result = await repository.recoverInterruptedLocalDeletions();

      expect(result.ok, isTrue);
      expect(result.value, 1);
      expect(events, <String>['finish']);
      expect(repository.findById(item.recordingId), isNull);
      expect(
        dao.listDownloadedManifests().single['local_state'],
        'localDeleted',
      );
      expect(dao.listDeviceLocalMappings(), hasLength(1));
    });

    test('restart deletion recovery retains lock on stat failure', () async {
      final db = AppDatabase();
      final events = <String>[];
      final item = _exportItem(
        recordingId: 'recover-delete-stat-failure',
        source: RecordingLibrarySource.device,
      );
      db.upsertRecord(
        LocalTableName.localRecordings,
        item.recordingId,
        item.toRecord(),
      );
      final ledger = _FakeDeletionLedger(
        events: events,
        deletingRecordingIds: <String>{item.recordingId},
      );
      final repository = LocalRecordingRepository(
        database: db,
        fileStorage: _FakeFileStorage(
          statErrorCode: 'FILE_STORAGE_DRIVER_UNAVAILABLE',
        ),
        deletionLedger: ledger,
      );

      final result = await repository.recoverInterruptedLocalDeletions();

      expect(result.ok, isFalse);
      expect(result.error?.code, 'FILE_STORAGE_DRIVER_UNAVAILABLE');
      expect(events, isEmpty);
      expect(ledger.deletionInProgressLocalRecordingIds(), <String>[
        item.recordingId,
      ]);
    });

    test('rejects a second delete while the first delete is pending', () async {
      final db = AppDatabase();
      final storage = _BlockingDeleteFileStorage();
      final repository = LocalRecordingRepository(
        database: db,
        fileStorage: storage,
      );
      final item = _exportItem(recordingId: 'pending-delete');
      db.upsertRecord(
        LocalTableName.localRecordings,
        item.recordingId,
        item.toRecord(),
      );

      final first = repository.deletePermanently(item.recordingId);
      await storage.started.future;
      final second = await repository.deletePermanently(item.recordingId);
      storage.complete();

      expect(second.ok, isFalse);
      expect(second.error?.code, 'RECORDING_DELETE_IN_PROGRESS');
      expect((await first).ok, isTrue);
    });

    test(
      'keeps same audio, upload drafts, and remote links isolated per account',
      () async {
        final sourceRoot = await Directory.systemTemp.createTemp(
          'recording-account-source',
        );
        final privateRoot = await Directory.systemTemp.createTemp(
          'recording-account-private',
        );
        addTearDown(() async {
          if (await sourceRoot.exists()) {
            await sourceRoot.delete(recursive: true);
          }
          if (await privateRoot.exists()) {
            await privateRoot.delete(recursive: true);
          }
        });
        final source = File('${sourceRoot.path}/same-audio.m4a');
        await source.writeAsBytes(<int>[1, 2, 3, 4, 5]);
        final database = AppDatabase();
        final resolverA = PrivateRecordingPathResolver(
          accountScope: 'user-a',
          platform: PrivateRecordingPlatform.ios,
          applicationSupportDirectory: () async => privateRoot,
          documentsDirectory: () async => privateRoot,
        );
        final resolverB = PrivateRecordingPathResolver(
          accountScope: 'user-b',
          platform: PrivateRecordingPlatform.ios,
          applicationSupportDirectory: () async => privateRoot,
          documentsDirectory: () async => privateRoot,
        );
        final picked = _picked(
          pickerRef: 'picker:shared-audio',
          displayName: 'Shared.m4a',
          sourcePath: source.path,
        );
        final repositoryA = LocalRecordingRepository(
          database: database,
          fileStorage: PathProviderFileStoragePort(
            pathResolver: resolverA,
            now: _time,
          ),
          accountScope: 'user-a',
          requireAuthenticatedAccount: true,
          recoveryPathResolver: resolverA,
        );
        final importedA = await repositoryA.importPickedRecording(
          picked,
          now: _time(),
        );
        expect(importedA.ok, isTrue);
        final recordingId = importedA.value!.recordingId;
        expect(
          repositoryA
              .linkRemoteRecording(
                localRecordingId: recordingId,
                remoteRecordingId: 'recording-a',
                linkedAt: _time(),
              )
              .ok,
          isTrue,
        );

        final repositoryB = LocalRecordingRepository(
          database: database,
          fileStorage: PathProviderFileStoragePort(
            pathResolver: resolverB,
            now: _time,
          ),
          accountScope: 'user-b',
          requireAuthenticatedAccount: true,
          recoveryPathResolver: resolverB,
        );
        expect((await repositoryB.verifiedList()).rows, isEmpty);
        expect(repositoryB.uploadDraftsFor(recordingId), isEmpty);

        final importedB = await repositoryB.importPickedRecording(
          picked,
          now: _time(),
        );
        expect(importedB.ok, isTrue);
        expect(importedB.value!.recordingId, recordingId);
        expect(
          repositoryB
              .linkRemoteRecording(
                localRecordingId: recordingId,
                remoteRecordingId: 'recording-b',
                linkedAt: _time(),
              )
              .ok,
          isTrue,
        );

        final localUri = importedA.value!.appPrivateUri!;
        final accountAFile = await resolverA.resolveFile(localUri);
        final accountBFile = await resolverB.resolveFile(localUri);
        expect(accountAFile, isNotNull);
        expect(accountBFile, isNotNull);
        expect(accountAFile!.path, isNot(equals(accountBFile!.path)));
        expect(await accountAFile.exists(), isTrue);
        expect(await accountBFile.exists(), isTrue);
        expect(
          repositoryA.findById(recordingId)?.remoteRecordingId,
          'recording-a',
        );
        expect(
          repositoryB.findById(recordingId)?.remoteRecordingId,
          'recording-b',
        );
        expect(repositoryA.uploadDraftsFor(recordingId), hasLength(1));
        expect(repositoryB.uploadDraftsFor(recordingId), hasLength(1));
        expect(
          RecordingDao(
            database,
            userScope: 'user-a',
          ).getLocalRecording(recordingId)?['user_scope'],
          'user-a',
        );
        expect(
          RecordingDao(
            database,
            userScope: 'user-b',
          ).getLocalRecording(recordingId)?['user_scope'],
          'user-b',
        );
      },
    );
  });
}

PickedAudioFile _picked({
  String pickerRef = 'picker:meeting',
  String displayName = 'Meeting.m4a',
  String? sourcePath,
  String? contentHash =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
}) {
  return PickedAudioFile(
    pickerRef: pickerRef,
    displayName: displayName,
    mimeType: 'audio/mp4',
    sizeBytes: 2048,
    durationSeconds: 90,
    contentHash: contentHash,
    recordedAt: _time(),
    sourcePath: sourcePath,
  );
}

RecordingLibraryItem _exportItem({
  String recordingId = 'local-export-item',
  RecordingLibrarySource source = RecordingLibrarySource.localImport,
  String displayName = 'Export title',
  RecordingLibraryFormat format = RecordingLibraryFormat.m4a,
  String? originalFilename = 'original.m4a',
  String? deviceFilename,
  String appPrivateUri = 'app-private://local-export-item.m4a',
  String? contentHash,
}) {
  return RecordingLibraryItem(
    recordingId: recordingId,
    source: source,
    displayName: displayName,
    originalFilename: originalFilename,
    deviceFilename: deviceFilename,
    appPrivateUri: appPrivateUri,
    format: format,
    localFileState: RecordingLocalFileState.ready,
    status: RecordingLibraryStatus.localOnly,
    durationSeconds: 1,
    sizeBytes: 2048,
    contentHash: contentHash,
    isFavorite: false,
    tagIds: const <String>[],
    createdAt: _time(),
    updatedAt: _time(),
  );
}

DateTime _time() => DateTime.utc(2026, 7, 1, 9);

final class _FakeFileStorage extends UnavailableFileStoragePort {
  _FakeFileStorage({
    this.appPrivateUri,
    this.statExists = true,
    this.statSizeBytes = 2048,
    this.statDurationSeconds,
    this.preparedContentHash,
    this.privateContentHash =
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    this.statErrorCode,
    this.deleteSucceeds = true,
    this.onDelete,
  });

  final String? appPrivateUri;
  final bool statExists;
  final int? statSizeBytes;
  final int? statDurationSeconds;
  final String? preparedContentHash;
  final String privateContentHash;
  final String? statErrorCode;
  final bool deleteSucceeds;
  final void Function(String appPrivateUri)? onDelete;
  final copiedRefs = <String>[];
  final renamed = <String, String>{};
  final deletedUris = <String>[];
  final preparedExports = <String>[];
  final preparedDisplayNames = <String>[];

  @override
  Future<FileStorageResult<PrivateAudioFile>> copyPickedAudioToPrivateLibrary(
    PickedAudioFile picked,
  ) async {
    copiedRefs.add(picked.pickerRef);
    final safeId = picked.displayName.toLowerCase().replaceAll(
      RegExp(r'[^a-z0-9._-]+'),
      '-',
    );
    return FileStorageResult<PrivateAudioFile>.success(
      PrivateAudioFile(
        fileId: safeId,
        appPrivateUri: appPrivateUri ?? 'app-private://$safeId',
        displayName: picked.displayName,
        mimeType: picked.mimeType,
        sizeBytes: picked.sizeBytes,
        durationSeconds: picked.durationSeconds,
        contentHash: picked.contentHash,
        recordedAt: picked.recordedAt,
      ),
    );
  }

  @override
  Future<FileStorageResult<PrivateAudioFileStat>> statPrivateAudio(
    String appPrivateUri,
  ) async {
    if (statErrorCode case final code?) {
      return FileStorageResult<PrivateAudioFileStat>.failure(
        recordingLibraryError(code),
      );
    }
    return FileStorageResult<PrivateAudioFileStat>.success(
      PrivateAudioFileStat(
        exists: statExists,
        sizeBytes: statSizeBytes,
        durationSeconds: statDurationSeconds,
      ),
    );
  }

  @override
  Future<FileStorageResult<String>> hashPrivateAudio(
    String appPrivateUri,
  ) async {
    return FileStorageResult<String>.success(privateContentHash);
  }

  @override
  Future<FileStorageResult<PreparedAudioExport>> prepareAudioExport({
    required String appPrivateUri,
    required String displayName,
  }) async {
    preparedExports.add(appPrivateUri);
    preparedDisplayNames.add(displayName);
    return FileStorageResult<PreparedAudioExport>.success(
      PreparedAudioExport(
        opaqueExportRef:
            'app-private-export://recordings/cache/export-1/$displayName',
        displayName: displayName,
        sizeBytes: 2048,
        contentHash: preparedContentHash,
      ),
    );
  }

  @override
  Future<FileStorageResult<bool>> deletePrivateAudio(
    String appPrivateUri,
  ) async {
    deletedUris.add(appPrivateUri);
    onDelete?.call(appPrivateUri);
    if (!deleteSucceeds) {
      return FileStorageResult<bool>.failure(
        recordingLibraryError('RECORDING_DELETE_FAILED'),
      );
    }
    return FileStorageResult<bool>.success(true);
  }

  @override
  Future<FileStorageResult<bool>> updatePrivateAudioMetadata({
    required String appPrivateUri,
    required String displayName,
  }) async {
    renamed[appPrivateUri] = displayName;
    return FileStorageResult<bool>.success(true);
  }
}

final class _FakeDeletionLedger implements LocalRecordingDeletionLedgerPort {
  _FakeDeletionLedger({
    required this.events,
    Set<String> deletingRecordingIds = const <String>{},
  }) : _deletingRecordingIds = <String>{...deletingRecordingIds};

  final List<String> events;
  final Set<String> _deletingRecordingIds;

  @override
  Iterable<String> deletionInProgressLocalRecordingIds() =>
      List<String>.unmodifiable(_deletingRecordingIds);

  @override
  bool canStartUpload(String localRecordingId) =>
      !_deletingRecordingIds.contains(localRecordingId);

  @override
  bool beginLocalDeletion(String localRecordingId, DateTime at) {
    if (!_deletingRecordingIds.add(localRecordingId)) {
      throw StateError('already deleting');
    }
    events.add('begin');
    return true;
  }

  @override
  void finishLocalDeletion(String localRecordingId, DateTime at) {
    if (!_deletingRecordingIds.remove(localRecordingId)) {
      throw StateError('not deleting');
    }
    events.add('finish');
  }

  @override
  void restoreLocalDeletion(String localRecordingId, DateTime at) {
    if (!_deletingRecordingIds.remove(localRecordingId)) {
      throw StateError('not deleting');
    }
    events.add('restore');
  }
}

final class _BlockingDeleteFileStorage extends UnavailableFileStoragePort {
  final started = Completer<void>();
  final _result = Completer<FileStorageResult<bool>>();

  @override
  Future<FileStorageResult<bool>> deletePrivateAudio(String appPrivateUri) {
    if (!started.isCompleted) started.complete();
    return _result.future;
  }

  void complete() {
    if (!_result.isCompleted) {
      _result.complete(FileStorageResult<bool>.success(true));
    }
  }
}

final class _FailFirstWriteWorker implements LocalDatabaseWriteWorkerPort {
  _FailFirstWriteWorker(this._delegate);

  final LocalDatabaseWriteWorkerPort _delegate;
  var _failed = false;

  @override
  bool get isDisposed => _delegate.isDisposed;

  @override
  Future<void> applyRecordMutations({
    required int schemaVersion,
    required Iterable<LocalDatabaseMutation> mutations,
  }) {
    if (!_failed) {
      _failed = true;
      return Future<void>.error(StateError('injected first worker failure'));
    }
    return _delegate.applyRecordMutations(
      schemaVersion: schemaVersion,
      mutations: mutations,
    );
  }

  @override
  Future<void> replaceAllRecords({
    required int schemaVersion,
    required Map<LocalTableName, Map<String, LocalDatabaseRecord>> tables,
  }) {
    return _delegate.replaceAllRecords(
      schemaVersion: schemaVersion,
      tables: tables,
    );
  }
}
