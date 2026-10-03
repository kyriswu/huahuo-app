import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:huahuo_api/huahuo_api.dart';
import 'package:path_provider/path_provider.dart';

import '../domain/desktop_resource_image_cache.dart';

export '../domain/desktop_resource_image_cache.dart';

/// A scoped cache for image Resources. Cache records contain byte data and MIME
/// metadata only; the short-lived playback URL is used once and never written.
final class RemoteDesktopResourceImageCache
    implements DesktopResourceImageCache {
  RemoteDesktopResourceImageCache({
    required ApiClient apiClient,
    Future<Directory> Function()? cacheDirectory,
    DesktopResourceImagePlaybackResolver? resolvePlayback,
    DesktopResourceImageByteDownloader? download,
    this.memoryLimitBytes = 64 * 1024 * 1024,
    this.diskLimitBytes = 250 * 1024 * 1024,
    DateTime Function()? now,
  }) : _apiClient = apiClient,
       _cacheDirectory = cacheDirectory ?? getApplicationCacheDirectory,
       _resolvePlaybackOverride = resolvePlayback,
       _downloadOverride = download,
       _now = now ?? DateTime.now;

  static const maxImageBytes = 50 * 1024 * 1024;

  final ApiClient _apiClient;
  final Future<Directory> Function() _cacheDirectory;
  final DesktopResourceImagePlaybackResolver? _resolvePlaybackOverride;
  final DesktopResourceImageByteDownloader? _downloadOverride;
  final DateTime Function() _now;
  final int memoryLimitBytes;
  final int diskLimitBytes;
  final LinkedHashMap<String, DesktopCachedResourceImage> _memory =
      LinkedHashMap<String, DesktopCachedResourceImage>();
  final Map<String, Future<DesktopCachedResourceImage>> _inflight =
      <String, Future<DesktopCachedResourceImage>>{};

  _DesktopResourceScope? _scope;
  var _generation = 0;
  var _memoryBytes = 0;
  var _disposed = false;

  @override
  Future<void> bindAccount({
    required String userId,
    required String workspaceId,
  }) async {
    final user = userId.trim();
    final workspace = workspaceId.trim();
    if (!_safeIdentifier.hasMatch(user) ||
        !_safeIdentifier.hasMatch(workspace)) {
      throw ArgumentError('Desktop Resource image cache scope is invalid');
    }
    _generation += 1;
    _memory.clear();
    _inflight.clear();
    _memoryBytes = 0;
    _scope = _DesktopResourceScope(_opaqueCacheKey('$user|$workspace'));
  }

  @override
  Future<void> clearAccount() async {
    _generation += 1;
    _scope = null;
    _memory.clear();
    _inflight.clear();
    _memoryBytes = 0;
  }

  @override
  Future<DesktopCachedResourceImage> load(String resourceId) {
    final resource = resourceId.trim();
    final scope = _scope;
    if (_disposed) {
      return Future<DesktopCachedResourceImage>.error(
        const DesktopResourceImageCacheException(
          'DESKTOP_RESOURCE_IMAGE_CACHE_DISPOSED',
        ),
      );
    }
    if (!_safeIdentifier.hasMatch(resource)) {
      return Future<DesktopCachedResourceImage>.error(
        const DesktopResourceImageCacheException(
          'DESKTOP_RESOURCE_IMAGE_ID_INVALID',
        ),
      );
    }
    if (scope == null) {
      return Future<DesktopCachedResourceImage>.error(
        const DesktopResourceImageCacheException(
          'DESKTOP_RESOURCE_IMAGE_SCOPE_UNAVAILABLE',
        ),
      );
    }
    final remembered = _memory.remove(resource);
    if (remembered != null) {
      _memory[resource] = remembered;
      return Future<DesktopCachedResourceImage>.value(remembered);
    }
    final existing = _inflight[resource];
    if (existing != null) return existing;
    final requestGeneration = _generation;
    final operation = _loadUncached(
      resource,
      scope: scope,
      generation: requestGeneration,
    );
    _inflight[resource] = operation;
    operation.whenComplete(() {
      if (_inflight[resource] == operation) _inflight.remove(resource);
    }).ignore();
    return operation;
  }

  Future<DesktopCachedResourceImage> _loadUncached(
    String resourceId, {
    required _DesktopResourceScope scope,
    required int generation,
  }) async {
    final fromDisk = await _readDisk(scope, resourceId);
    if (fromDisk != null) {
      _assertScope(scope, generation);
      _remember(fromDisk);
      return fromDisk;
    }
    final playback = await _resolvePlayback(resourceId);
    _assertScope(scope, generation);
    final downloaded = await _download(playback);
    _assertScope(scope, generation);
    final image = DesktopCachedResourceImage(
      resourceId: resourceId,
      bytes: downloaded.bytes,
      mimeType: downloaded.mimeType.toLowerCase(),
    );
    if (!_isValidImage(image.bytes, image.mimeType)) {
      throw const DesktopResourceImageCacheException(
        'DESKTOP_RESOURCE_IMAGE_BYTES_INVALID',
      );
    }
    _remember(image);
    unawaited(_writeDisk(scope, image));
    return image;
  }

  void _assertScope(_DesktopResourceScope scope, int generation) {
    if (_disposed || generation != _generation || _scope != scope) {
      throw const DesktopResourceImageCacheException(
        'DESKTOP_RESOURCE_IMAGE_SCOPE_CHANGED',
      );
    }
  }

  Future<DesktopResourceImagePlayback> _resolvePlayback(
    String resourceId,
  ) async {
    final override = _resolvePlaybackOverride;
    if (override != null) return override(resourceId);
    final result = await _apiClient.request<DesktopResourceImagePlayback>(
      ApiRequestOptions<DesktopResourceImagePlayback>(
        endpointId: 'mediaResourcePlayback',
        pathParams: <String, Object>{'resourceId': resourceId},
        parseData: (value) => _parsePlayback(value, resourceId),
      ),
    );
    if (!result.ok || result.data == null) {
      throw DesktopResourceImageCacheException(
        result.error?.code ?? 'DESKTOP_RESOURCE_IMAGE_PLAYBACK_UNAVAILABLE',
      );
    }
    return result.data!;
  }

  Future<DesktopResourceImageBytes> _download(
    DesktopResourceImagePlayback playback,
  ) async {
    final override = _downloadOverride;
    if (override != null) return override(playback);
    final client = HttpClient();
    try {
      final request = await client.getUrl(playback.url);
      final response = await request.close();
      if (response.statusCode < 200 ||
          response.statusCode >= 300 ||
          response.contentLength > maxImageBytes) {
        throw const DesktopResourceImageCacheException(
          'DESKTOP_RESOURCE_IMAGE_DOWNLOAD_FAILED',
        );
      }
      final declaredMime = response.headers.contentType?.mimeType.toLowerCase();
      final mimeType = _isSupportedImageMime(declaredMime)
          ? declaredMime!
          : playback.mimeType.toLowerCase();
      if (!_isSupportedImageMime(mimeType)) {
        throw const DesktopResourceImageCacheException(
          'DESKTOP_RESOURCE_IMAGE_MIME_UNSUPPORTED',
        );
      }
      final builder = BytesBuilder(copy: false);
      await for (final chunk in response) {
        builder.add(chunk);
        if (builder.length > maxImageBytes) {
          throw const DesktopResourceImageCacheException(
            'DESKTOP_RESOURCE_IMAGE_SIZE_INVALID',
          );
        }
      }
      return DesktopResourceImageBytes(
        bytes: builder.takeBytes(),
        mimeType: mimeType,
      );
    } on DesktopResourceImageCacheException {
      rethrow;
    } on Object {
      throw const DesktopResourceImageCacheException(
        'DESKTOP_RESOURCE_IMAGE_DOWNLOAD_FAILED',
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<DesktopCachedResourceImage?> _readDisk(
    _DesktopResourceScope scope,
    String resourceId,
  ) async {
    try {
      final files = await _filesFor(scope, resourceId);
      if (!await files.bytes.exists() || !await files.metadata.exists()) {
        return null;
      }
      final metadata = jsonDecode(await files.metadata.readAsString());
      if (metadata is! Map ||
          metadata['mimeType'] is! String ||
          metadata['sizeBytes'] is! int) {
        await _deleteFiles(files);
        return null;
      }
      final bytes = await files.bytes.readAsBytes();
      final mimeType = (metadata['mimeType'] as String).toLowerCase();
      if (bytes.length != metadata['sizeBytes'] ||
          bytes.length > maxImageBytes ||
          !_isValidImage(bytes, mimeType)) {
        await _deleteFiles(files);
        return null;
      }
      final touched = _now().toUtc();
      await files.bytes.setLastModified(touched);
      await files.metadata.setLastModified(touched);
      return DesktopCachedResourceImage(
        resourceId: resourceId,
        bytes: bytes,
        mimeType: mimeType,
      );
    } on Object {
      return null;
    }
  }

  Future<void> _writeDisk(
    _DesktopResourceScope scope,
    DesktopCachedResourceImage image,
  ) async {
    if (_disposed || image.sizeBytes > diskLimitBytes || _scope != scope) {
      return;
    }
    try {
      final files = await _filesFor(scope, image.resourceId);
      final bytesPart = File('${files.bytes.path}.part');
      final metadataPart = File('${files.metadata.path}.part');
      await bytesPart.writeAsBytes(image.bytes, flush: true);
      await metadataPart.writeAsString(
        jsonEncode(<String, Object?>{
          'mimeType': image.mimeType,
          'sizeBytes': image.sizeBytes,
        }),
        flush: true,
      );
      if (await files.bytes.exists()) await files.bytes.delete();
      if (await files.metadata.exists()) await files.metadata.delete();
      await bytesPart.rename(files.bytes.path);
      await metadataPart.rename(files.metadata.path);
      await _enforceDiskLimit(scope);
    } on Object {
      // Cache persistence is an optimization. A validated in-memory image is
      // still usable when a desktop cache directory is unavailable.
    }
  }

  Future<void> _enforceDiskLimit(_DesktopResourceScope scope) async {
    final directory = await _directoryFor(scope);
    final files = <File>[];
    var total = 0;
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.bin')) continue;
      try {
        final stat = await entity.stat();
        total += stat.size;
        files.add(entity);
      } on Object {
        // A concurrently removed cache entry is not an error.
      }
    }
    if (total <= diskLimitBytes) return;
    files.sort((left, right) {
      final leftTime = left.statSync().modified.millisecondsSinceEpoch;
      final rightTime = right.statSync().modified.millisecondsSinceEpoch;
      return leftTime.compareTo(rightTime);
    });
    for (final bytesFile in files) {
      if (total <= diskLimitBytes) break;
      try {
        final size = (await bytesFile.stat()).size;
        final metadata = File(
          '${bytesFile.path.substring(0, bytesFile.path.length - 4)}.json',
        );
        await bytesFile.delete();
        if (await metadata.exists()) await metadata.delete();
        total -= size;
      } on Object {
        // A second request may remove the same least-recent entry first.
      }
    }
  }

  void _remember(DesktopCachedResourceImage image) {
    final existing = _memory.remove(image.resourceId);
    if (existing != null) _memoryBytes -= existing.sizeBytes;
    _memory[image.resourceId] = image;
    _memoryBytes += image.sizeBytes;
    while (_memoryBytes > memoryLimitBytes && _memory.isNotEmpty) {
      final oldest = _memory.remove(_memory.keys.first);
      if (oldest != null) _memoryBytes -= oldest.sizeBytes;
    }
  }

  Future<_DesktopResourceImageFiles> _filesFor(
    _DesktopResourceScope scope,
    String resourceId,
  ) async {
    final directory = await _directoryFor(scope);
    final key = _opaqueCacheKey(resourceId);
    return _DesktopResourceImageFiles(
      bytes: File('${directory.path}/$key.bin'),
      metadata: File('${directory.path}/$key.json'),
    );
  }

  Future<Directory> _directoryFor(_DesktopResourceScope scope) async {
    final root = await _cacheDirectory();
    final directory = Directory(
      '${root.path}${Platform.pathSeparator}huahuo-resource-images'
      '${Platform.pathSeparator}${scope.cacheKey}',
    );
    if (!await directory.exists()) await directory.create(recursive: true);
    return directory;
  }

  Future<void> _deleteFiles(_DesktopResourceImageFiles files) async {
    if (await files.bytes.exists()) await files.bytes.delete();
    if (await files.metadata.exists()) await files.metadata.delete();
  }

  @override
  void dispose() {
    _disposed = true;
    _scope = null;
    _generation += 1;
    _memory.clear();
    _inflight.clear();
    _memoryBytes = 0;
  }
}

final class _DesktopResourceScope {
  const _DesktopResourceScope(this.cacheKey);

  final String cacheKey;
}

final class _DesktopResourceImageFiles {
  const _DesktopResourceImageFiles({
    required this.bytes,
    required this.metadata,
  });

  final File bytes;
  final File metadata;
}

DesktopResourceImagePlayback? _parsePlayback(Object? value, String resourceId) {
  final root = asObjectMap(value);
  final resource = asObjectMap(root?['resource']);
  final returnedId = root?['resourceId'] ?? resource?['resourceId'];
  if (returnedId != null && returnedId != resourceId) return null;
  final url = _safePlaybackUrl(root?['url'] ?? resource?['url']);
  final mimeType = (root?['mimeType'] ?? resource?['mimeType']) is String
      ? ((root?['mimeType'] ?? resource?['mimeType']) as String)
            .trim()
            .toLowerCase()
      : null;
  if (url == null || !_isSupportedImageMime(mimeType)) return null;
  return DesktopResourceImagePlayback(
    resourceId: resourceId,
    url: url,
    mimeType: mimeType!,
  );
}

Uri? _safePlaybackUrl(Object? value) {
  if (value is! String || value.trim().isEmpty) return null;
  final uri = Uri.tryParse(value.trim());
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    return null;
  }
  return uri;
}

bool _isValidImage(Uint8List bytes, String mimeType) {
  if (!_isSupportedImageMime(mimeType) || bytes.isEmpty) return false;
  return switch (mimeType) {
    'image/png' =>
      bytes.length >= 8 &&
          bytes[0] == 0x89 &&
          bytes[1] == 0x50 &&
          bytes[2] == 0x4e &&
          bytes[3] == 0x47,
    'image/jpeg' ||
    'image/jpg' => bytes.length >= 3 && bytes[0] == 0xff && bytes[1] == 0xd8,
    'image/gif' =>
      bytes.length >= 6 &&
          bytes[0] == 0x47 &&
          bytes[1] == 0x49 &&
          bytes[2] == 0x46,
    'image/webp' =>
      bytes.length >= 12 &&
          bytes[0] == 0x52 &&
          bytes[1] == 0x49 &&
          bytes[2] == 0x46 &&
          bytes[3] == 0x46 &&
          bytes[8] == 0x57 &&
          bytes[9] == 0x45 &&
          bytes[10] == 0x42 &&
          bytes[11] == 0x50,
    _ => false,
  };
}

bool _isSupportedImageMime(String? value) => const <String>{
  'image/png',
  'image/jpeg',
  'image/jpg',
  'image/gif',
  'image/webp',
}.contains(value);

final _safeIdentifier = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$');

String _opaqueCacheKey(String value) {
  var hash = 0xcbf29ce484222325;
  for (final byte in utf8.encode(value)) {
    hash ^= byte;
    hash = (hash * 0x100000001b3) & 0xffffffffffffffff;
  }
  return hash.toUnsigned(64).toRadixString(16).padLeft(16, '0');
}
