import 'dart:convert';
import 'dart:io';

import 'package:huahuo_editor/huahuo_editor.dart';
import 'package:path_provider/path_provider.dart';

import '../domain/document_store.dart';

export '../domain/document_store.dart';

final class LocalDocumentStore implements DocumentStore {
  LocalDocumentStore({Future<Directory> Function()? supportDirectory})
    : _supportDirectory = supportDirectory ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _supportDirectory;

  Future<Directory> _documentsDirectory() async {
    final support = await _supportDirectory();
    final documents = Directory(
      '${support.path}${Platform.pathSeparator}documents',
    );
    if (!documents.existsSync()) await documents.create(recursive: true);
    return documents;
  }

  @override
  Future<List<HuahuoDocumentSnapshot>> loadAll() async {
    final root = await _documentsDirectory();
    final documents = <HuahuoDocumentSnapshot>[];
    final files = await root
        .list(followLinks: false)
        .where((entity) => entity is File)
        .cast<File>()
        .toList();
    final candidates = <String, File>{
      for (final file in files)
        if (file.path.endsWith('.json')) file.path: file,
      for (final file in files)
        if (file.path.endsWith('.json.bak'))
          file.path.substring(0, file.path.length - 4): File(
            file.path.substring(0, file.path.length - 4),
          ),
    };
    for (final entity in candidates.values) {
      try {
        final snapshot = await _readSnapshot(entity);
        if (snapshot == null) throw const FormatException('Invalid document');
        documents.add(snapshot);
      } on UnsupportedDocumentVersionException {
        rethrow;
      } on Object {
        final backup = File('${entity.path}.bak');
        if (!backup.existsSync()) continue;
        try {
          final snapshot = await _readSnapshot(backup);
          if (snapshot == null) throw const FormatException('Invalid backup');
          await _restoreBackup(entity, backup);
          documents.add(snapshot);
        } on UnsupportedDocumentVersionException {
          rethrow;
        } on Object {
          continue;
        }
      }
    }
    documents.sort(
      (left, right) => right.modifiedAt.compareTo(left.modifiedAt),
    );
    return documents;
  }

  @override
  Future<void> delete(String documentId) async {
    final root = await _documentsDirectory();
    final safeId = documentId.replaceAll(RegExp('[^a-zA-Z0-9_-]'), '_');
    final target = File('${root.path}${Platform.pathSeparator}$safeId.json');
    final backup = File('${target.path}.bak');
    if (target.existsSync()) await _rejectFutureVersion(target);
    if (backup.existsSync()) await _rejectFutureVersion(backup);
    for (final file in <File>[File('${target.path}.tmp'), backup, target]) {
      if (file.existsSync()) await file.delete();
    }
  }

  @override
  Future<void> save(HuahuoDocumentSnapshot snapshot) async {
    final root = await _documentsDirectory();
    final safeId = snapshot.id.replaceAll(RegExp('[^a-zA-Z0-9_-]'), '_');
    final target = File('${root.path}${Platform.pathSeparator}$safeId.json');
    final temporary = File('${target.path}.tmp');
    final backup = File('${target.path}.bak');
    if (target.existsSync()) {
      await _rejectFutureVersion(target);
    }
    var targetReadable = false;
    if (target.existsSync()) {
      try {
        targetReadable = await _readSnapshot(target) != null;
      } on UnsupportedDocumentVersionException {
        rethrow;
      } on Object {
        targetReadable = false;
      }
    }
    await temporary.writeAsString(jsonEncode(snapshot.toJson()), flush: true);
    if (!target.existsSync()) {
      await temporary.rename(target.path);
      return;
    }
    if (!targetReadable) {
      if (backup.existsSync()) {
        final readableBackup = await _readSnapshot(backup);
        if (readableBackup == null) await backup.delete();
      }
      await target.delete();
      await temporary.rename(target.path);
      return;
    }
    if (backup.existsSync()) await backup.delete();
    await target.rename(backup.path);
    try {
      await temporary.rename(target.path);
    } on Object {
      if (!target.existsSync() && backup.existsSync()) {
        await backup.rename(target.path);
      }
      rethrow;
    }
  }
}

Future<void> _restoreBackup(File target, File backup) async {
  final temporary = File('${target.path}.recovery.tmp');
  await temporary.writeAsBytes(await backup.readAsBytes(), flush: true);
  if (target.existsSync()) await target.delete();
  try {
    await temporary.rename(target.path);
  } on Object {
    if (temporary.existsSync()) await temporary.delete();
    rethrow;
  }
}

Future<HuahuoDocumentSnapshot?> _readSnapshot(File file) async {
  final decoded = jsonDecode(await file.readAsString());
  if (decoded is! Map) return null;
  final json = decoded.map((key, value) => MapEntry(key.toString(), value));
  final version = json['formatVersion'];
  if (version is int && version > HuahuoDocumentSnapshot.formatVersion) {
    throw UnsupportedDocumentVersionException(
      path: file.path,
      version: version,
    );
  }
  return HuahuoDocumentSnapshot.fromJson(json);
}

Future<void> _rejectFutureVersion(File file) async {
  try {
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map) return;
    final version = decoded['formatVersion'];
    if (version is int && version > HuahuoDocumentSnapshot.formatVersion) {
      throw UnsupportedDocumentVersionException(
        path: file.path,
        version: version,
      );
    }
  } on UnsupportedDocumentVersionException {
    rethrow;
  } on Object {
    return;
  }
}
