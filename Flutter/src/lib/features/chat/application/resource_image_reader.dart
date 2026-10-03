import 'dart:typed_data';

final class CachedResourceImage {
  const CachedResourceImage({
    required this.resourceId,
    required this.bytes,
    required this.mimeType,
  });

  final String resourceId;
  final Uint8List bytes;
  final String mimeType;

  int get sizeBytes => bytes.lengthInBytes;
}

final class ResourceImageCacheException implements Exception {
  const ResourceImageCacheException(this.code);

  final String code;

  @override
  String toString() => code;
}

abstract interface class ResourceImageReader {
  Future<CachedResourceImage> load(String resourceId);
}
