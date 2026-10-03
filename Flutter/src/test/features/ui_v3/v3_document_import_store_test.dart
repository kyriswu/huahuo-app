import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/native/document_import_format.dart';
import 'package:huahuoai_app/core/native/native_file_port.dart';
import 'package:huahuoai_app/features/ui_v3/data/v3_document_import_store.dart';
import 'package:huahuoai_app/features/ui_v3/domain/document_import_progress.dart';

void main() {
  test('accepts exactly 100 MiB and rejects empty or larger files', () async {
    final root = await Directory.systemTemp.createTemp('huahuo-doc-size-');
    addTearDown(() => root.delete(recursive: true));
    final source = File('${root.path}/slides.pptx');
    final handle = await source.open(mode: FileMode.write);
    await handle.truncate(maxDocumentImportBytes);
    await handle.close();
    final store = _store(AppDatabase(), root);
    final accepted = await store.stage(_picked(source, 'slides.pptx'));
    expect(accepted.ok, isTrue, reason: accepted.error?.code);
    expect(accepted.value?.sizeBytes, maxDocumentImportBytes);
    expect((await store.resolveVerifiedFile(accepted.value!)).ok, isTrue);
    final larger = await source.open(mode: FileMode.append);
    await larger.writeByte(1);
    await larger.close();
    expect(
      (await store.stage(_picked(source, 'slides.pptx'))).error?.code,
      'DOCUMENT_IMPORT_FILE_TOO_LARGE',
    );
    await source.writeAsBytes([]);
    expect(
      (await store.stage(_picked(source, 'slides.pptx'))).error?.code,
      'DOCUMENT_IMPORT_FILE_EMPTY',
    );
  });

  test(
    'restores upload-only waits as submission failure with saved phase',
    () async {
      final root = await Directory.systemTemp.createTemp('huahuo-doc-phase-');
      addTearDown(() => root.delete(recursive: true));
      final source = File('${root.path}/source.md');
      await source.writeAsString('phase checkpoint');
      final database = AppDatabase();
      final store = _store(database, root);
      final task = (await store.stage(_picked(source, 'source.md'))).value!;
      store.save(
        task.copyWith(
          acceptedForImport: true,
          uploadId: 'upload-1',
          uploadResourceId: 'resource-1',
          status: V3DocumentImportTaskStatus.waiting,
          phase: V3DocumentImportPhase.creatingIngestion,
          lastErrorCode: 'INTERNAL_ERROR',
        ),
      );
      final restored = _store(database, root).listTasks().single;
      expect(restored.status, V3DocumentImportTaskStatus.failed);
      expect(restored.phase, V3DocumentImportPhase.creatingIngestion);
      expect(restored.hasAcceptedIngestion, isFalse);
      expect(restored.isRetryable, isTrue);
    },
  );

  test(
    'explicit reselection replaces terminal remote attempt, not completed note',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'huahuo-doc-reselect-',
      );
      addTearDown(() => root.delete(recursive: true));
      final source = File('${root.path}/source.md');
      await source.writeAsString('terminal attempt');
      final store = _store(AppDatabase(), root);
      final task = (await store.stage(_picked(source, 'source.md'))).value!;
      store.save(
        task.copyWith(
          acceptedForImport: true,
          ingestionId: 'expired-ingestion',
          uploadId: 'old-upload',
          uploadResourceId: 'old-resource',
          status: V3DocumentImportTaskStatus.failed,
          lastErrorCode: 'DOCUMENT_INGESTION_EXPIRED',
          failureRetryable: false,
          attemptCount: 3,
        ),
      );
      final selected = (await store.stage(_picked(source, 'source.md'))).value!;
      expect(selected.acceptedForImport, isFalse);
      expect(selected.ingestionId, isNull);
      expect(selected.uploadId, isNull);
      expect(selected.attemptCount, 3);
      store.save(
        selected.copyWith(
          acceptedForImport: true,
          rawAssetCreated: true,
          remoteNoteId: 'existing-note',
          status: V3DocumentImportTaskStatus.completed,
        ),
      );
      final repeated = (await store.stage(_picked(source, 'source.md'))).value!;
      expect(repeated.remoteNoteId, 'existing-note');
      expect(repeated.isCompleted, isTrue);
      await (await store.resolveVerifiedFile(repeated)).value!.delete();
      final withoutCopy = (await store.stage(
        _picked(source, 'source.md'),
      )).value!;
      expect(withoutCopy.remoteNoteId, 'existing-note');
      expect(withoutCopy.isCompleted, isTrue);
    },
  );

  test(
    'stages verified private copy and recovers it from recreated store',
    () async {
      final root = await Directory.systemTemp.createTemp('huahuo-doc-store-');
      addTearDown(() => root.delete(recursive: true));
      final source = File('${root.path}/source.md');
      await source.writeAsString('persistent import');
      final database = AppDatabase();
      final store = _store(database, root);

      final staged = await store.stage(_picked(source, 'source.md'));

      expect(staged.ok, isTrue, reason: staged.error?.code);
      final task = staged.value!;
      expect(
        task.sha256,
        sha256.convert(await source.readAsBytes()).toString(),
      );
      expect(task.privateFileName, '${task.sha256}.md');
      expect(task.acceptedForImport, isFalse);
      store.save(
        task.copyWith(
          acceptedForImport: true,
          distillToDigitalTwin: true,
          uploadId: 'upload-1',
          uploadResourceId: 'resource-1',
          ingestionId: 'ingestion-1',
          status: V3DocumentImportTaskStatus.waiting,
          distillationTaskId: 'distill-1',
          distillationResourceId: 'resource-1',
          digitalTwinConfirmationId: 'confirmation-1',
          updatedAt: DateTime.now().toUtc(),
        ),
      );
      final recreated = _store(database, root);
      expect(recreated.listTasks(), hasLength(1));
      expect(recreated.listTasks().single.acceptedForImport, isTrue);
      expect(recreated.listTasks().single.distillToDigitalTwin, isTrue);
      expect(recreated.listTasks().single.uploadId, 'upload-1');
      expect(recreated.listTasks().single.uploadResourceId, 'resource-1');
      expect(recreated.listTasks().single.ingestionId, 'ingestion-1');
      expect(
        recreated.listTasks().single.status,
        V3DocumentImportTaskStatus.waiting,
      );
      expect(recreated.listTasks().single.distillationTaskId, 'distill-1');
      expect(recreated.listTasks().single.distillationResourceId, 'resource-1');
      expect(
        recreated.listTasks().single.digitalTwinConfirmationId,
        'confirmation-1',
      );
      final verified = await recreated.resolveVerifiedFile(
        recreated.listTasks().single,
      );
      expect(verified.ok, isTrue, reason: verified.error?.code);
      expect(await verified.value!.readAsString(), 'persistent import');
    },
  );

  test('content identity is idempotent across display-name changes', () async {
    final root = await Directory.systemTemp.createTemp('huahuo-doc-dedupe-');
    addTearDown(() => root.delete(recursive: true));
    final source = File('${root.path}/source.md');
    await source.writeAsString('# Same bytes');
    final store = _store(AppDatabase(), root);

    final first = await store.stage(_picked(source, 'first.md'));
    store.save(
      first.value!.copyWith(
        acceptedForImport: true,
        distillToDigitalTwin: true,
      ),
    );
    final second = await store.stage(_picked(source, 'renamed.md'));

    expect(first.value?.id, second.value?.id);
    expect(store.listTasks(), hasLength(1));
    expect(store.listTasks().single.pickerRef, 'picked-document://first.md');
    expect(store.listTasks().single.acceptedForImport, isTrue);
    expect(store.listTasks().single.distillToDigitalTwin, isTrue);
  });

  test('mutated private bytes fail hash verification', () async {
    final root = await Directory.systemTemp.createTemp('huahuo-doc-corrupt-');
    addTearDown(() => root.delete(recursive: true));
    final source = File('${root.path}/source.md');
    await source.writeAsString('original');
    final store = _store(AppDatabase(), root);
    final task = (await store.stage(_picked(source, 'source.md'))).value!;
    final privateFile = (await store.resolveVerifiedFile(task)).value!;
    await privateFile.writeAsString('tampered');

    final verified = await store.resolveVerifiedFile(task);

    expect(verified.ok, isFalse);
    expect(
      verified.error?.code,
      anyOf(
        'DOCUMENT_IMPORT_PRIVATE_SIZE_MISMATCH',
        'DOCUMENT_IMPORT_PRIVATE_HASH_MISMATCH',
      ),
    );
    final repaired = await store.stage(_picked(source, 'source.md'));
    expect(repaired.ok, isTrue);
    expect(repaired.value!.id, task.id);
    expect((await store.resolveVerifiedFile(repaired.value!)).ok, isTrue);
  });

  test('stages each supported format with a canonical MIME type', () async {
    final root = await Directory.systemTemp.createTemp('huahuo-doc-formats-');
    addTearDown(() => root.delete(recursive: true));
    final store = _store(AppDatabase(), root);

    for (final format in DocumentImportFormat.values) {
      final source = File('${root.path}/source.${format.extension}');
      await source.writeAsString('payload:${format.extension}');
      final staged = await store.stage(
        _picked(
          source,
          'source.${format.extension}',
          mimeType: 'application/octet-stream',
        ),
      );

      expect(staged.ok, isTrue, reason: staged.error?.code);
      expect(staged.value?.mimeType, format.mimeType);
      expect(staged.value?.privateFileName, endsWith('.${format.extension}'));
    }
    expect(store.listTasks(), hasLength(DocumentImportFormat.values.length));
  });

  test(
    'same bytes in different formats retain independent task identities',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'huahuo-doc-cross-format-',
      );
      addTearDown(() => root.delete(recursive: true));
      final source = File('${root.path}/payload');
      await source.writeAsString('same verified bytes');
      final store = _store(AppDatabase(), root);

      final markdown = await store.stage(_picked(source, 'same.md'));
      final pdf = await store.stage(_picked(source, 'same.pdf'));

      expect(markdown.ok, isTrue, reason: markdown.error?.code);
      expect(pdf.ok, isTrue, reason: pdf.error?.code);
      expect(markdown.value?.sha256, pdf.value?.sha256);
      expect(markdown.value?.id, isNot(pdf.value?.id));
      expect(
        markdown.value?.privateFileName,
        isNot(pdf.value?.privateFileName),
      );
      expect(store.listTasks(), hasLength(2));
    },
  );

  test(
    'rejects legacy, audio, and unknown extensions before staging',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'huahuo-doc-rejected-',
      );
      addTearDown(() => root.delete(recursive: true));
      final source = File('${root.path}/payload.bin');
      await source.writeAsString('not a supported note file');
      final store = _store(AppDatabase(), root);

      for (final name in <String>[
        'legacy.doc',
        'legacy.ppt',
        'legacy.markdown',
        'voice.wav',
        'bad.zip',
      ]) {
        final staged = await store.stage(_picked(source, name));
        expect(staged.ok, isFalse, reason: name);
        expect(staged.error?.code, 'DOCUMENT_IMPORT_TYPE_UNSUPPORTED');
      }
      expect(store.listTasks(), isEmpty);
    },
  );
}

V3DocumentImportStore _store(AppDatabase database, Directory root) =>
    V3DocumentImportStore(
      database: database,
      rootDirectory: () async => root,
      ownerScope: 'test-user',
    );

PickedDocumentFile _picked(File source, String name, {String? mimeType}) =>
    PickedDocumentFile(
      pickerRef: 'picked-document://$name',
      displayName: name,
      mimeType:
          mimeType ??
          DocumentImportFormat.fromFileName(name)?.mimeType ??
          'application/octet-stream',
      sizeBytes: source.lengthSync(),
      sourcePath: source.path,
    );
