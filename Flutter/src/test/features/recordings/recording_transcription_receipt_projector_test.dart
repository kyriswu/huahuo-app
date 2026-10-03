import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/storage/upload_draft_store.dart';
import 'package:huahuoai_app/features/recordings/application/recording_processing_tracker.dart';
import 'package:huahuoai_app/features/recordings/application/recording_transcription_receipt_projector.dart';
import 'package:huahuoai_app/features/recordings/domain/recording_detail.dart';
import 'package:huahuoai_app/features/recordings/domain/recording_library.dart';
import 'package:huahuoai_app/features/recordings/domain/recording_transcription_receipt.dart';

const _hashA =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

void main() {
  group('RecordingTranscriptionReceiptProjector', () {
    test('requires a final transcript and matching remote identity', () async {
      final store = _ReceiptStore();
      final projector = _projector(store);
      final now = DateTime.utc(2026, 9, 4, 8);

      expect(
        await projector.applyProcessingTask(
          _task(
            now: now,
            detail: _detail(recordingId: 'remote-one', finalTranscript: false),
          ),
        ),
        isFalse,
      );
      expect(
        await projector.applyProcessingTask(
          _task(
            now: now,
            detail: _detail(recordingId: 'remote-other'),
          ),
        ),
        isFalse,
      );
      expect(store.values, isEmpty);
    });

    test(
      'persists and idempotently enriches a single-file tracker fact',
      () async {
        final store = _ReceiptStore();
        final projector = _projector(store);
        final now = DateTime.utc(2026, 9, 4, 8);
        final task = _task(
          now: now,
          detail: _detail(
            recordingId: 'remote-one',
            rawAsset: true,
            outline: true,
          ),
        );

        expect(await projector.applyProcessingTask(task), isTrue);
        expect(await projector.applyProcessingTask(task), isFalse);

        final receipt = store.values.single;
        expect(receipt.fileIdentity, _hashA);
        expect(receipt.localRecordingId, 'local-one');
        expect(receipt.deviceFilename, 'CARD_001.m4a');
        expect(receipt.noteId, 'note-one');
        expect(receipt.isAssetReady, isTrue);
        expect(receipt.isOutlineReady, isTrue);
        expect(store.flushCount, 1);
      },
    );

    test(
      'applies late Outline completion by Recording or Note identity',
      () async {
        final store = _ReceiptStore();
        final projector = _projector(store);
        final now = DateTime.utc(2026, 9, 4, 8);
        await projector.applyProcessingState(
          RecordingProcessingState(
            tasks: <RecordingProcessingTask>[
              _task(
                now: now,
                detail: _detail(recordingId: 'remote-one'),
              ),
              _task(
                localId: 'local-two',
                remoteId: 'remote-two',
                now: now,
                detail: _detail(recordingId: 'remote-two', noteId: 'note-two'),
              ),
            ],
          ),
        );

        expect(
          await projector.applyOutlineCompleted(
            remoteRecordingId: 'remote-one',
            completedAt: now.add(const Duration(minutes: 1)),
          ),
          1,
        );
        expect(
          await projector.applyOutlineCompleted(
            noteId: 'note-two',
            completedAt: now.add(const Duration(minutes: 2)),
          ),
          1,
        );
        expect(
          store.findByRemoteRecordingId('remote-one')?.isOutlineReady,
          isTrue,
        );
        expect(
          store.findByRemoteRecordingId('remote-two')?.isOutlineReady,
          isTrue,
        );
      },
    );
  });
}

RecordingTranscriptionReceiptProjector _projector(_ReceiptStore store) {
  return RecordingTranscriptionReceiptProjector(
    store: store,
    accountScope: 'account-a',
    localItemLookup: (localRecordingId) => localRecordingId == 'local-one'
        ? RecordingLibraryItem(
            recordingId: 'local-one',
            source: RecordingLibrarySource.device,
            displayName: 'Card recording',
            format: RecordingLibraryFormat.m4a,
            localFileState: RecordingLocalFileState.ready,
            status: RecordingLibraryStatus.localOnly,
            durationSeconds: 10,
            sizeBytes: 128,
            isFavorite: false,
            tagIds: const <String>[],
            createdAt: DateTime.utc(2026, 9, 4, 7),
            updatedAt: DateTime.utc(2026, 9, 4, 7),
            deviceFilename: 'CARD_001.m4a',
            appPrivateUri: 'app-private-media://recordings/local-one.m4a',
            contentHash: _hashA,
          )
        : null,
    now: () => DateTime.utc(2026, 9, 4, 12),
  );
}

RecordingProcessingTask _task({
  String localId = 'local-one',
  String remoteId = 'remote-one',
  required DateTime now,
  required RecordingDetail detail,
}) {
  return RecordingProcessingTask(
    draft: UploadDraft(
      draftId: 'draft-$localId',
      localRecordingId: localId,
      appPrivateUri: 'app-private-media://recordings/$localId.m4a',
      fileName: '$localId.m4a',
      mimeType: 'audio/mp4',
      sizeBytes: 128,
      durationSeconds: 10,
      sourceScene: 'raw_material',
      stage: UploadDraftStage.asrCompleted,
      updatedAt: now,
      uploadTokenKey: 'upload-$localId',
      completeUploadKey: 'complete-$localId',
      createRecordingKey: 'create-$localId',
      recordingId: remoteId,
      contentHash: localId == 'local-one' ? _hashA : null,
    ),
    phase: RecordingProcessingPhase.completed,
    updatedAt: now,
    detail: detail,
  );
}

RecordingDetail _detail({
  required String recordingId,
  String? noteId,
  bool finalTranscript = true,
  bool rawAsset = false,
  bool outline = false,
}) {
  final resolvedNoteId = noteId ?? 'note-one';
  return RecordingDetail(
    recording: RecordingAsset(
      recordingId: recordingId,
      title: 'Recording',
      status: finalTranscript
          ? RecordingRemoteStatus.completed
          : RecordingRemoteStatus.processing,
    ),
    finalTranscript: finalTranscript ? 'Final transcript.' : null,
    finalTranscriptConfirmed: finalTranscript ? true : null,
    noteRef: rawAsset || outline
        ? RecordingNoteRef(
            noteId: resolvedNoteId,
            rawPartRevisionId: 'raw-one',
            outlinePartRevisionId: outline ? 'outline-one' : null,
          )
        : finalTranscript
        ? RecordingNoteRef(
            noteId: resolvedNoteId,
            rawPartRevisionId: '',
            outlinePartRevisionId: null,
          )
        : null,
    noteOutlineTask: outline
        ? const RecordingNoteOutlineTask(
            taskId: 'outline-task-one',
            status: RecordingNoteOutlineTaskStatus.succeeded,
          )
        : null,
    hasSubTaskSnapshot: outline,
  );
}

final class _ReceiptStore implements RecordingTranscriptionReceiptStorePort {
  final Map<String, RecordingTranscriptionReceipt> _values =
      <String, RecordingTranscriptionReceipt>{};
  var flushCount = 0;

  List<RecordingTranscriptionReceipt> get values =>
      _values.values.toList(growable: false);

  @override
  RecordingTranscriptionReceipt? findByFileIdentity(String fileIdentity) =>
      _values[fileIdentity];

  @override
  RecordingTranscriptionReceipt? findByLocalRecordingId(
    String localRecordingId,
  ) => _values.values
      .where((receipt) => receipt.localRecordingId == localRecordingId)
      .firstOrNull;

  @override
  RecordingTranscriptionReceipt? findByRemoteRecordingId(
    String remoteRecordingId,
  ) => _values.values
      .where((receipt) => receipt.remoteRecordingId == remoteRecordingId)
      .firstOrNull;

  @override
  Future<bool> flush() async {
    flushCount += 1;
    return true;
  }

  @override
  List<RecordingTranscriptionReceipt> listReceipts() => values;

  @override
  void save(RecordingTranscriptionReceipt receipt) {
    _values[receipt.fileIdentity] =
        _values[receipt.fileIdentity]?.merge(receipt) ?? receipt;
  }
}
