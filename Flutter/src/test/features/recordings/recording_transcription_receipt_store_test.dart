import 'package:huahuoai_app/app/di/database_providers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:huahuoai_app/app/bootstrap/app_providers.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/storage/file_storage_port.dart';
import 'package:huahuoai_app/features/recordings/data/recording_transcription_receipt_store.dart';
import 'package:huahuoai_app/features/recordings/domain/recording_transcription_receipt.dart';

void main() {
  group('RecordingTranscriptionReceiptStore', () {
    test(
      'receipt notifications preserve the processing projector identity',
      () async {
        final container = ProviderContainer(
          overrides: <Override>[
            authenticatedUserDataScopeProvider.overrideWith(
              (ref) => 'account-a',
            ),
            authenticatedRecordingUserScopeProvider.overrideWith(
              (ref) => 'account-a',
            ),
            appDatabaseProvider.overrideWith((ref) => AppDatabase()),
            fileStoragePortProvider.overrideWithValue(
              const UnavailableFileStoragePort(),
            ),
          ],
        );
        addTearDown(container.dispose);
        final projector = container.read(
          recordingTranscriptionReceiptProjectorProvider,
        );
        final store = container.read(
          recordingTranscriptionReceiptStoreProvider,
        );
        final at = DateTime.utc(2026, 9, 8);
        store.save(
          RecordingTranscriptionReceipt(
            userScope: 'account-a',
            fileIdentity: 'local:audio',
            localRecordingId: 'audio',
            remoteRecordingId: 'remote',
            transcriptCompletedAt: at,
            updatedAt: at,
          ),
        );
        expect(await store.flush(), isTrue);
        expect(
          container.read(recordingTranscriptionReceiptProjectorProvider),
          same(projector),
        );
      },
    );

    test(
      'publishes changes after flush without repeating unchanged notifications',
      () async {
        final store = RecordingTranscriptionReceiptStore(
          database: AppDatabase(),
          accountScope: 'account-a',
        );
        addTearDown(store.dispose);
        var notifications = 0;
        store.addListener(() => notifications += 1);
        final at = DateTime.utc(2026, 9, 8);
        store.save(
          RecordingTranscriptionReceipt(
            userScope: 'account-a',
            fileIdentity: 'local:audio-one',
            localRecordingId: 'audio-one',
            remoteRecordingId: 'remote-one',
            transcriptCompletedAt: at,
            updatedAt: at,
          ),
        );
        expect(notifications, 0);
        expect(await store.flush(), isTrue);
        expect(notifications, 1);
        expect(await store.flush(), isTrue);
        expect(notifications, 1);
      },
    );

    test('isolates receipts by account scope and all stable identities', () {
      final database = AppDatabase();
      final first = RecordingTranscriptionReceiptStore(
        database: database,
        accountScope: 'account-a',
      );
      final second = RecordingTranscriptionReceiptStore(
        database: database,
        accountScope: 'account-b',
      );
      final completedAt = DateTime.utc(2026, 9, 4, 8);
      first.save(
        RecordingTranscriptionReceipt(
          userScope: 'account-a',
          fileIdentity: 'hash-a',
          deviceFilename: 'meeting.wav',
          contentHash: 'hash-a',
          localRecordingId: 'local-a',
          remoteRecordingId: 'remote-a',
          transcriptCompletedAt: completedAt,
          updatedAt: completedAt,
        ),
      );

      expect(first.findByFileIdentity('hash-a')?.isTranscribed, isTrue);
      expect(first.findByLocalRecordingId('local-a')?.fileIdentity, 'hash-a');
      expect(
        first.findByRemoteRecordingId('remote-a')?.deviceFilename,
        'meeting.wav',
      );
      expect(second.findByFileIdentity('hash-a'), isNull);
      expect(second.listReceipts(), isEmpty);
    });

    test('merges asset and outline facts without losing transcript proof', () {
      final database = AppDatabase();
      final store = RecordingTranscriptionReceiptStore(
        database: database,
        accountScope: 'account-a',
      );
      final transcriptAt = DateTime.utc(2026, 9, 4, 8);
      final assetAt = transcriptAt.add(const Duration(minutes: 2));
      final outlineAt = assetAt.add(const Duration(minutes: 3));
      final initial = RecordingTranscriptionReceipt(
        userScope: 'account-a',
        fileIdentity: 'hash-a',
        contentHash: 'hash-a',
        localRecordingId: 'local-a',
        remoteRecordingId: 'remote-a',
        transcriptCompletedAt: transcriptAt,
        updatedAt: transcriptAt,
      );
      store.save(initial);
      store.save(
        initial
            .withAsset(noteId: 'note-a', readyAt: assetAt, updatedAt: assetAt)
            .withOutline(completedAt: outlineAt, updatedAt: outlineAt),
      );

      final restored = store.findByFileIdentity('hash-a');
      expect(restored?.transcriptCompletedAt, transcriptAt);
      expect(restored?.noteId, 'note-a');
      expect(restored?.assetReadyAt, assetAt);
      expect(restored?.outlineCompletedAt, outlineAt);
      expect(restored?.isAssetReady, isTrue);
      expect(restored?.isOutlineReady, isTrue);
    });

    test('rejects a conflicting content hash for the same file identity', () {
      final store = RecordingTranscriptionReceiptStore(
        database: AppDatabase(),
        accountScope: 'account-a',
      );
      final now = DateTime.utc(2026, 9, 4, 8);
      RecordingTranscriptionReceipt receipt(String hash) =>
          RecordingTranscriptionReceipt(
            userScope: 'account-a',
            fileIdentity: 'stable-source',
            contentHash: hash,
            remoteRecordingId: 'remote-a',
            transcriptCompletedAt: now,
            updatedAt: now,
          );
      store.save(receipt('hash-a'));

      expect(() => store.save(receipt('hash-b')), throwsArgumentError);
    });
  });
}
