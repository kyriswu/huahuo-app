import 'dart:typed_data';

final class DesktopCachedResourceImage {
  const DesktopCachedResourceImage({
    required this.resourceId,
    required this.bytes,
    required this.mimeType,
  });

  final String resourceId;
  final Uint8List bytes;
  final String mimeType;

  int get sizeBytes => bytes.lengthInBytes;
}

final class DesktopResourceImagePlayback {
  const DesktopResourceImagePlayback({
    required this.resourceId,
    required this.url,
    required this.mimeType,
  });

  final String resourceId;
  final Uri url;
  final String mimeType;
}

final class DesktopResourceImageBytes {
  const DesktopResourceImageBytes({
    required this.bytes,
    required this.mimeType,
  });

  final Uint8List bytes;
  final String mimeType;
}

final class DesktopResourceImageCacheException implements Exception {
  const DesktopResourceImageCacheException(this.code);

  final String code;

  @override
  String toString() => code;
}

typedef DesktopResourceImagePlaybackResolver =
    Future<DesktopResourceImagePlayback> Function(String resourceId);
typedef DesktopResourceImageByteDownloader =
    Future<DesktopResourceImageBytes> Function(
      DesktopResourceImagePlayback playback,
    );

abstract interface class DesktopResourceImageCache {
  Future<void> bindAccount({
    required String userId,
    required String workspaceId,
  });

  Future<void> clearAccount();

  Future<DesktopCachedResourceImage> load(String resourceId);

  void dispose();
}

final class UnavailableDesktopResourceImageCache
    implements DesktopResourceImageCache {
  const UnavailableDesktopResourceImageCache();

  @override
  Future<void> bindAccount({
    required String userId,
    required String workspaceId,
  }) => Future<void>.value();

  @override
  Future<void> clearAccount() => Future<void>.value();

  @override
  void dispose() {}

  @override
  Future<DesktopCachedResourceImage> load(String resourceId) =>
      Future<DesktopCachedResourceImage>.error(
        const DesktopResourceImageCacheException(
          'DESKTOP_RESOURCE_IMAGE_UNAVAILABLE',
        ),
      );
}
