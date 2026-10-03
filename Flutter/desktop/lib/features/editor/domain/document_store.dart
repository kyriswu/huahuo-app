import 'package:huahuo_editor/huahuo_editor.dart';

/// Persistence boundary for desktop editor documents.
abstract interface class DocumentStore {
  Future<List<HuahuoDocumentSnapshot>> loadAll();

  Future<void> save(HuahuoDocumentSnapshot snapshot);

  Future<void> delete(String documentId);
}

final class UnsupportedDocumentVersionException implements Exception {
  const UnsupportedDocumentVersionException({
    required this.path,
    required this.version,
  });

  final String path;
  final int version;

  @override
  String toString() =>
      'Unsupported document version $version in $path; source was not changed';
}
