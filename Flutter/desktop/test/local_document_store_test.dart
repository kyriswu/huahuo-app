import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:huahuo_desktop/features/editor/data/local_document_store.dart';
import 'package:huahuo_editor/huahuo_editor.dart';

void main() {
  late Directory root;
  late LocalDocumentStore store;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('huahuo-document-store-');
    store = LocalDocumentStore(supportDirectory: () async => root);
  });

  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  test('loads v1, v2, and current document snapshots', () async {
    final directory = Directory(
      '${root.path}${Platform.pathSeparator}documents',
    )..createSync(recursive: true);
    for (final version in <int>[1, 2, HuahuoDocumentSnapshot.formatVersion]) {
      final json = _snapshot('document-$version', version).toJson()
        ..['formatVersion'] = version;
      if (version == 1) {
        json.remove('note');
        json.remove('linkedMaterials');
      }
      await File(
        '${directory.path}${Platform.pathSeparator}document-$version.json',
      ).writeAsString(jsonEncode(json));
    }

    final loaded = await store.loadAll();

    expect(loaded.map((snapshot) => snapshot.id), {
      'document-1',
      'document-2',
      'document-3',
    });
  });

  test('keeps a readable backup and recovers a corrupt current file', () async {
    await store.save(_snapshot('recoverable', 1));
    await store.save(_snapshot('recoverable', 2));
    final target = File(
      '${root.path}${Platform.pathSeparator}documents'
      '${Platform.pathSeparator}recoverable.json',
    );
    final backup = File('${target.path}.bak');
    expect(backup.existsSync(), isTrue);
    await target.writeAsString('{corrupt');

    final loaded = await store.loadAll();

    expect(loaded.single.revision, 1);
    expect(
      HuahuoDocumentSnapshot.fromJson(
        (jsonDecode(await target.readAsString()) as Map).map(
          (key, value) => MapEntry(key.toString(), value),
        ),
      ).revision,
      1,
    );
  });

  test('recovers an orphan backup left between atomic renames', () async {
    await store.save(_snapshot('orphan', 1));
    await store.save(_snapshot('orphan', 2));
    final target = File(
      '${root.path}${Platform.pathSeparator}documents'
      '${Platform.pathSeparator}orphan.json',
    );
    final backup = File('${target.path}.bak');
    await target.delete();

    final loaded = await store.loadAll();

    expect(loaded.single.revision, 1);
    expect(target.existsSync(), isTrue);
    expect(backup.existsSync(), isTrue);
  });

  test('saving after corruption preserves the last readable backup', () async {
    await store.save(_snapshot('preserved', 1));
    await store.save(_snapshot('preserved', 2));
    final target = File(
      '${root.path}${Platform.pathSeparator}documents'
      '${Platform.pathSeparator}preserved.json',
    );
    final backup = File('${target.path}.bak');
    await target.writeAsString('{corrupt');

    await store.save(_snapshot('preserved', 3));

    final saved = await store.loadAll();
    final backupJson = jsonDecode(await backup.readAsString()) as Map;
    expect(saved.single.revision, 3);
    expect(backupJson['revision'], 1);
  });

  test('future version fails explicitly and is never overwritten', () async {
    final directory = Directory(
      '${root.path}${Platform.pathSeparator}documents',
    )..createSync(recursive: true);
    final target = File(
      '${directory.path}${Platform.pathSeparator}future.json',
    );
    final futureJson = _snapshot('future', 7).toJson()
      ..['formatVersion'] = HuahuoDocumentSnapshot.formatVersion + 1;
    final original = jsonEncode(futureJson);
    await target.writeAsString(original);

    await expectLater(
      store.loadAll(),
      throwsA(isA<UnsupportedDocumentVersionException>()),
    );
    await expectLater(
      store.save(_snapshot('future', 8)),
      throwsA(isA<UnsupportedDocumentVersionException>()),
    );
    expect(await target.readAsString(), original);
  });

  test('ignores a corrupt document with no readable backup', () async {
    final directory = Directory(
      '${root.path}${Platform.pathSeparator}documents',
    )..createSync(recursive: true);
    await File(
      '${directory.path}${Platform.pathSeparator}broken.json',
    ).writeAsString('not-json');

    expect(await store.loadAll(), isEmpty);
  });
}

HuahuoDocumentSnapshot _snapshot(String id, int revision) {
  final createdAt = DateTime.utc(2026, 7, 31, 8);
  return HuahuoDocumentSnapshot(
    id: id,
    title: 'Document $id',
    deltaJson: '[{"insert":"Body $revision\\n"}]',
    markdownProjection: 'Body $revision',
    revision: revision,
    createdAt: createdAt,
    modifiedAt: createdAt.add(Duration(minutes: revision)),
  );
}
