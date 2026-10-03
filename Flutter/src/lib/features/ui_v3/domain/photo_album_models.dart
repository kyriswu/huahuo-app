import 'package:flutter/foundation.dart';

@immutable
final class V3PhotoAlbumEntry {
  const V3PhotoAlbumEntry({
    required this.id,
    required this.resourceId,
    required this.displayName,
    required this.role,
    required this.ordinal,
    required this.version,
    required this.etag,
    this.playbackUrl,
  });

  /// The server-issued Profile Visual Asset ID.
  final String id;
  final String resourceId;
  final String displayName;
  final String role;
  final int ordinal;
  final int version;
  final String etag;

  /// Short-lived, owner-authorized URL. It contains no storage reference.
  final Uri? playbackUrl;
}

@immutable
final class V3PhotoAlbumImportResult {
  const V3PhotoAlbumImportResult({
    required this.entries,
    required this.importedCount,
    required this.duplicateCount,
  });

  final List<V3PhotoAlbumEntry> entries;
  final int importedCount;
  final int duplicateCount;
}
