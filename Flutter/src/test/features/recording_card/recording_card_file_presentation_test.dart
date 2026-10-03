import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/native/recording_card_native_port.dart';
import 'package:huahuoai_app/features/recording_card/application/recording_card_controller.dart';
import 'package:huahuoai_app/features/recording_card/application/recording_card_file_presentation.dart';
import 'package:huahuoai_app/features/recording_card/domain/recording_card_sync_ledger.dart';
import 'package:huahuoai_app/features/recordings/domain/recording_library.dart';
import 'package:huahuoai_app/features/recordings/domain/recording_transcription_receipt.dart';

final _at = DateTime.utc(2026, 9, 8);
final _digest = RecordingCardFileIdentity.digestSerialNumber('SP63A03003')!;
final _hash = 'a' * 64;

void main() {
  test(
    'Wi-Fi panels require matching card identity even for terminal batches',
    () {
      for (final batchDigest in <String?>[_digest, null, '', '   ']) {
        final batch = RecordingCardWifiBatchSnapshot(
          batchId: 'retained-batch',
          deviceFingerprint: 'card-one',
          deviceIdentity: 'card-one',
          cardSnDigest: batchDigest,
          state: RecordingCardWifiBatchState.completed,
          items: const <RecordingCardWifiBatchItem>[],
          createdAt: _at,
          updatedAt: _at,
        );
        expect(
          recordingCardWifiBatchMatchesCard(
            batch: batch,
            cardSnDigest: _digest,
            deviceFingerprint: 'card-one',
          ),
          isTrue,
        );
        expect(
          recordingCardWifiBatchMatchesCard(
            batch: batch,
            cardSnDigest: 'other-card',
            deviceFingerprint: 'other-card',
          ),
          isFalse,
        );
        expect(
          recordingCardWifiBatchMatchesCard(
            batch: batch,
            cardSnDigest: null,
            deviceFingerprint: null,
          ),
          isFalse,
        );
      }
    },
  );

  group('Recording-card file presentation', () {
    final expectedStates =
        <RecordingCardFileLocalState, RecordingCardFileDisplayStatus>{
          RecordingCardFileLocalState.neverSynced:
              RecordingCardFileDisplayStatus.notSynced,
          RecordingCardFileLocalState.legacyUnknown:
              RecordingCardFileDisplayStatus.unknown,
          RecordingCardFileLocalState.queued:
              RecordingCardFileDisplayStatus.queued,
          RecordingCardFileLocalState.syncing:
              RecordingCardFileDisplayStatus.recoveryRequired,
          RecordingCardFileLocalState.synced:
              RecordingCardFileDisplayStatus.synced,
          RecordingCardFileLocalState.deleting:
              RecordingCardFileDisplayStatus.deleting,
          RecordingCardFileLocalState.localDeleted:
              RecordingCardFileDisplayStatus.locallyDeleted,
          RecordingCardFileLocalState.failed:
              RecordingCardFileDisplayStatus.failed,
        };
    for (final expected in expectedStates.entries) {
      test(
        'persisted ${expected.key.name} projects ${expected.value.name}',
        () {
          final row = _present(_entry(expected.key));
          expect(row.status, expected.value);
          expect(row.status.hasActiveTransfer, isFalse);
        },
      );
    }

    test('initial empty inventory is unverified, not deleted', () {
      final row = _present(
        _entry(RecordingCardFileLocalState.synced),
        cached: true,
        localReady: false,
        inventoryLoaded: false,
      );
      expect(row.status, RecordingCardFileDisplayStatus.unverified);
      expect(row.file.localFileId, isNull);
    });

    test('missing local object is distinct from an explicit deletion', () {
      final row = _present(
        _entry(RecordingCardFileLocalState.synced),
        cached: true,
        localReady: false,
      );
      expect(row.status, RecordingCardFileDisplayStatus.locallyMissing);
      expect(row.status.isAutomaticCandidate, isTrue);
      final deleted = _present(
        _entry(RecordingCardFileLocalState.localDeleted),
      );
      expect(deleted.status.isAutomaticCandidate, isFalse);
    });

    test('retained byte progress does not revive an idle transfer', () {
      final row = _present(
        _entry(RecordingCardFileLocalState.syncing),
        card: _card(progressPhase: RecordingCardTransferPhase.transferring),
      );
      expect(row.status, RecordingCardFileDisplayStatus.recoveryRequired);
      expect(row.file.syncState, isNot(RecordingCardFileSyncState.downloading));
    });

    for (final phase
        in <RecordingCardTransferPhase, RecordingCardFileDisplayStatus>{
          RecordingCardTransferPhase.transferring:
              RecordingCardFileDisplayStatus.transferring,
          RecordingCardTransferPhase.verifying:
              RecordingCardFileDisplayStatus.verifying,
          RecordingCardTransferPhase.registering:
              RecordingCardFileDisplayStatus.registering,
          RecordingCardTransferPhase.completed:
              RecordingCardFileDisplayStatus.registering,
        }.entries) {
      test('owned BLE ${phase.key.name} projects its real stage', () {
        final row = _present(
          _entry(RecordingCardFileLocalState.syncing),
          card: _card(active: true, progressPhase: phase.key),
        );
        expect(row.status, phase.value);
        expect(row.status, isNot(RecordingCardFileDisplayStatus.synced));
      });
    }

    test('another connection revision cannot claim the active file', () {
      final row = _present(
        _entry(RecordingCardFileLocalState.queued),
        card: _card(active: true, operationRevision: 1),
      );
      expect(row.status, RecordingCardFileDisplayStatus.queued);
    });

    test(
      'Wi-Fi progress survives expected BLE loss using the source identity',
      () {
        final entry = _entry(RecordingCardFileLocalState.syncing);
        final batch = RecordingCardWifiBatchSnapshot(
          batchId: 'wifi-batch',
          deviceFingerprint: 'card-one',
          deviceIdentity: 'card-one',
          cardSnDigest: _digest,
          state: RecordingCardWifiBatchState.transferring,
          items: <RecordingCardWifiBatchItem>[
            RecordingCardWifiBatchItem(
              file: _file(),
              state: RecordingCardWifiBatchItemState.transferring,
              order: 0,
              expectedSizeBytes: 4096,
              ledgerSourceSignature: entry.sourceSignature,
            ),
          ],
          createdAt: _at,
          updatedAt: _at,
          currentItemIndex: 0,
        );
        final card = _card(
          active: true,
          connected: false,
          kind: RecordingCardOperationKind.wifiTransfer,
        ).copyWith(wifiBatch: batch);
        expect(
          _present(entry, cached: true, card: card).status,
          RecordingCardFileDisplayStatus.transferring,
        );
        final paused = batch.copyWith(
          state: RecordingCardWifiBatchState.paused,
          updatedAt: _at,
        );
        expect(
          _present(
            entry,
            cached: true,
            card: card.copyWith(wifiBatch: paused),
          ).status,
          RecordingCardFileDisplayStatus.paused,
        );
      },
    );

    test('old-card ledger and tombstones cannot attach to the new card', () {
      final rows = buildRecordingCardFilePresentations(
        directory: <RecordingCardScannedFile>[_file()],
        ledger: <RecordingCardFileLedgerEntry>[
          _entry(RecordingCardFileLocalState.localDeleted),
        ],
        cardSnDigest: 'b' * 64,
        card: _card(),
        localRecordingLookup: (_) => _local(),
        localInventoryLoaded: true,
      );
      expect(rows.single.status, RecordingCardFileDisplayStatus.notSynced);
    });

    test(
      'confirmed card deletion cannot reappear from a retained native row',
      () {
        final entry = _entry(
          RecordingCardFileLocalState.synced,
        ).markCardDeleted(_at);
        final rows = buildRecordingCardFilePresentations(
          directory: <RecordingCardScannedFile>[_file()],
          ledger: <RecordingCardFileLedgerEntry>[entry],
          cardSnDigest: _digest,
          card: _card(),
          localRecordingLookup: (_) => _local(),
          localInventoryLoaded: true,
        );
        expect(rows, isEmpty);
      },
    );

    test(
      'a receipt survives local deletion but never a changed content hash',
      () {
        final receipt = RecordingTranscriptionReceipt(
          userScope: 'account',
          fileIdentity: _hash,
          contentHash: _hash,
          localRecordingId: 'local-one',
          remoteRecordingId: 'remote-one',
          transcriptCompletedAt: _at,
          updatedAt: _at,
        );
        final entry = _entry(RecordingCardFileLocalState.localDeleted);
        expect(
          _present(
            entry,
            localReady: false,
            receipts: <RecordingTranscriptionReceipt>[receipt],
          ).transcribed,
          isTrue,
        );
        final changed = _present(
          entry,
          file: _file(hash: 'b' * 64),
          localReady: false,
          receipts: <RecordingTranscriptionReceipt>[receipt],
        );
        expect(changed.transcribed, isFalse);
        expect(changed.status, RecordingCardFileDisplayStatus.notSynced);
      },
    );

    test('a deleted source cannot hide a different same-content recording', () {
      final rows = buildRecordingCardFilePresentations(
        directory: <RecordingCardScannedFile>[_file(id: 'new-source')],
        ledger: <RecordingCardFileLedgerEntry>[
          _entry(RecordingCardFileLocalState.synced).markCardDeleted(_at),
        ],
        cardSnDigest: _digest,
        card: _card(),
        localRecordingLookup: (_) => _local(),
        localInventoryLoaded: true,
      );
      expect(rows, hasLength(1));
      expect(rows.single.status, RecordingCardFileDisplayStatus.notSynced);
    });

    test(
      'two source files sharing one local object still count as two files',
      () {
        final first = _file();
        final second = _file(id: 'source-two');
        final rows = buildRecordingCardFilePresentations(
          directory: <RecordingCardScannedFile>[first, second],
          ledger: <RecordingCardFileLedgerEntry>[
            _entry(RecordingCardFileLocalState.synced, file: first),
            _entry(RecordingCardFileLocalState.synced, file: second),
          ],
          cardSnDigest: _digest,
          card: _card(),
          localRecordingLookup: (_) => _local(),
          localInventoryLoaded: true,
        );
        expect(
          rows.where(
            (row) => row.status == RecordingCardFileDisplayStatus.synced,
          ),
          hasLength(2),
        );
      },
    );
  });
}

RecordingCardFilePresentation _present(
  RecordingCardFileLedgerEntry entry, {
  RecordingCardScannedFile? file,
  RecordingCardControllerState? card,
  bool localReady = true,
  bool inventoryLoaded = true,
  bool cached = false,
  Iterable<RecordingTranscriptionReceipt> receipts =
      const <RecordingTranscriptionReceipt>[],
}) => buildRecordingCardFilePresentations(
  directory: cached ? null : <RecordingCardScannedFile>[file ?? _file()],
  ledger: <RecordingCardFileLedgerEntry>[entry],
  cardSnDigest: _digest,
  card: card ?? _card(),
  localRecordingLookup: (_) => localReady ? _local() : null,
  localInventoryLoaded: inventoryLoaded,
  receipts: receipts,
).single;

RecordingCardScannedFile _file({String id = 'source-one', String? hash}) =>
    RecordingCardScannedFile(
      deviceFileId: id,
      localFileKey: 'native-$id',
      deviceFilename: '20260908080000.m4a',
      sizeBytes: 4096,
      recordedAt: _at,
      contentHash: hash ?? _hash,
      format: RecordingCardFileFormat.m4a,
    );

RecordingCardFileLedgerEntry _entry(
  RecordingCardFileLocalState state, {
  RecordingCardScannedFile? file,
}) {
  final source = file ?? _file();
  return RecordingCardFileLedgerEntry(
    cardSnDigest: _digest,
    sourceSignature: RecordingCardFileIdentity.sourceSignatureFor(
      cardSnDigest: _digest,
      deviceFileId: source.deviceFileId,
      deviceFilename: source.deviceFilename,
      sizeBytes: source.sizeBytes,
      recordedAt: source.recordedAt,
    ),
    deviceFileId: source.deviceFileId,
    deviceFilename: source.deviceFilename,
    localState: state,
    cardState: RecordingCardFilePresenceState.present,
    attemptCount: 1,
    lastSeenAt: _at,
    updatedAt: _at,
    recordedAt: _at,
    sizeBytes: 4096,
    contentHash: source.contentHash,
    localRecordingId: 'local-one',
    lastSyncedAt: _at,
  );
}

RecordingLibraryItem _local() => RecordingLibraryItem(
  recordingId: 'local-one',
  source: RecordingLibrarySource.device,
  displayName: '录音',
  format: RecordingLibraryFormat.m4a,
  localFileState: RecordingLocalFileState.ready,
  status: RecordingLibraryStatus.localOnly,
  durationSeconds: 60,
  sizeBytes: 4096,
  isFavorite: false,
  tagIds: const <String>[],
  createdAt: _at,
  updatedAt: _at,
  contentHash: _hash,
  appPrivateUri: 'app-private://recording-card/local-one.m4a',
);

RecordingCardControllerState _card({
  bool active = false,
  bool connected = true,
  int operationRevision = 3,
  RecordingCardOperationKind kind =
      RecordingCardOperationKind.bluetoothTransfer,
  RecordingCardTransferPhase progressPhase =
      RecordingCardTransferPhase.transferring,
}) => RecordingCardControllerState(
  status: active
      ? RecordingCardControllerStatus.downloading
      : RecordingCardControllerStatus.idle,
  snapshot: RecordingCardRuntimeSnapshot.initial().copyWith(
    deviceState: RecordingCardDeviceState(
      connectionState: connected
          ? RecordingCardConnectionState.connected
          : RecordingCardConnectionState.disconnected,
      connectionStage: connected
          ? RecordingCardConnectionStage.connected
          : RecordingCardConnectionStage.idle,
      safeDeviceFingerprint: 'card-one',
      serialNumber: 'SP63A03003',
    ),
    transferProgress: RecordingCardTransferProgress(
      localFileKey: 'native-source-one',
      receivedBytes: 4096,
      totalBytes: 4096,
      correlationId: 'transfer',
      phase: progressPhase,
    ),
  ),
  fileCatalog: const RecordingCardFileCatalogState(
    phase: RecordingCardFileCatalogPhase.ready,
    connectionRevision: 3,
    deviceIdentity: 'card-one',
  ),
  operation: active
      ? RecordingCardOperationState(
          phase: RecordingCardOperationPhase.running,
          generation: 1,
          kind: kind,
          origin: RecordingCardOperationOrigin.automatic,
          connectionRevision: operationRevision,
        )
      : const RecordingCardOperationState.idle(),
  activeFileKey: active ? 'native-source-one' : null,
);
