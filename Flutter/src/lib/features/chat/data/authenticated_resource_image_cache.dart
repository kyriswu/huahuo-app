import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import '../application/resource_image_reader.dart';
import 'chat_api.dart';

export '../application/resource_image_reader.dart';

typedef ResourceImageByteDownloader =
    Future<ChatImageBytes> Function(ChatImagePlayback playback);

/// Caches authenticated Resource image bytes without ever persisting the
/// short-lived playback URL used to fetch them.
final class AuthenticatedResourceImageCache implements ResourceImageReader {
  AuthenticatedResourceImageCache({
    required ChatImagePlaybackClient playbackClient,
    required String userScope,
    required String workspaceScope,
    Future<Directory> Function()? cacheDirectoryProvider,
    ResourceImageByteDownloader? download,
    int memoryLimitBytes = 32 * 1024 * 1024,
    this.diskLimitBytes = 250 * 1024 * 1024,
    int maximumConcurrentDownloads = 4,
    DateTime Function()? now,
  }) : _playbackClient = playbackClient,
       _scopeHash = sha256
           .convert(utf8.encode('${userScope.trim()}|${workspaceScope.trim()}'))
           .toString()
           .substring(0, 32),
       _cacheDirectoryProvider =
           cacheDirectoryProvider ?? getApplicationCacheDirectory,
       _download = download ?? playbackClient.download,
       _now = now ?? DateTime.now,
       _memoryLimitBytes = _validatedMemoryLimit(memoryLimitBytes),
       _maximumConcurrentDownloads = _validatedDownloadLimit(
         maximumConcurrentDownloads,
       );

  final ChatImagePlaybackClient _playbackClient;
  final String _scopeHash;
  final Future<Directory> Function() _cacheDirectoryProvider;
  final ResourceImageByteDownloader _download;
  final DateTime Function() _now;
  final int diskLimitBytes;
  final int _maximumConcurrentDownloads;
  final Queue<Completer<void>> _downloadWaiters = Queue<Completer<void>>();
  int _activeDownloads = 0;
  int _memoryLimitBytes;
  final LinkedHashMap<String, CachedResourceImage> _memory =
      LinkedHashMap<String, CachedResourceImage>();
  final Map<String, Future<CachedResourceImage>> _inflight =
      <String, Future<CachedResourceImage>>{};
  int _memoryBytes = 0;
  int _memoryGeneration = 0;
  Future<Directory>? _scopeDirectory;
  Future<void> _diskOperations = Future<void>.value();
  _DiskCacheIndex? _diskIndex;
  bool _disposed = false;

  int get memoryLimitBytes => _memoryLimitBytes;
  int get memoryBytes => _memoryBytes;
  int get memoryEntryCount => _memory.length;

  @override
  Future<CachedResourceImage> load(String resourceId) {
    final id = resourceId.trim();
    if (id.isEmpty) {
      return Future<CachedResourceImage>.error(
        const ResourceImageCacheException('RESOURCE_IMAGE_ID_INVALID'),
      );
    }
    if (_disposed) {
      return Future<CachedResourceImage>.error(
        const ResourceImageCacheException('RESOURCE_IMAGE_CACHE_DISPOSED'),
      );
    }
    final cached = _memory.remove(id);
    if (cached != null) {
      _memory[id] = cached;
      return Future<CachedResourceImage>.value(cached);
    }
    final running = _inflight[id];
    if (running != null) return running;
    final future = _loadUncached(id);
    _inflight[id] = future;
    future.then<void>(
      (_) {
        _inflight.remove(id);
      },
      onError: (Object _, StackTrace __) {
        _inflight.remove(id);
      },
    );
    return future;
  }

  Future<CachedResourceImage> _loadUncached(String resourceId) async {
    _throwIfDisposed();
    final memoryGeneration = _memoryGeneration;
    final fromDisk = await _readDisk(resourceId);
    _throwIfDisposed();
    if (fromDisk != null) {
      _remember(fromDisk, memoryGeneration);
      return fromDisk;
    }
    await _acquireDownloadSlot();
    try {
      final downloaded = await _downloadWithRetry(resourceId);
      _throwIfDisposed();
      final image = CachedResourceImage(
        resourceId: resourceId,
        bytes: downloaded.bytes,
        mimeType: downloaded.mimeType,
      );
      if (!_isValidImage(image.bytes, image.mimeType)) {
        throw const ResourceImageCacheException('RESOURCE_IMAGE_BYTES_INVALID');
      }
      _remember(image, memoryGeneration);
      unawaited(_writeDisk(image));
      return image;
    } on ResourceImageCacheException {
      rethrow;
    } on ChatImageDownloadException catch (error) {
      _throwIfDisposed();
      throw ResourceImageCacheException(error.code);
    } on Object {
      _throwIfDisposed();
      throw const ResourceImageCacheException('RESOURCE_IMAGE_DOWNLOAD_FAILED');
    } finally {
      _releaseDownloadSlot();
    }
  }

  Future<ChatImageBytes> _downloadWithRetry(String resourceId) async {
    for (var attempt = 0; ; attempt += 1) {
      _throwIfDisposed();
      final playback = await _playbackClient.resolve(resourceId);
      _throwIfDisposed();
      if (!playback.ok || playback.data == null) {
        throw ResourceImageCacheException(
          playback.error?.code ?? 'RESOURCE_IMAGE_PLAYBACK_UNAVAILABLE',
        );
      }
      try {
        return await _download(playback.data!);
      } on ChatImageDownloadException catch (error) {
        _throwIfDisposed();
        if (!error.isRetryable || attempt >= 1) rethrow;
      }
    }
  }

  Future<void> _acquireDownloadSlot() {
    _throwIfDisposed();
    if (_activeDownloads < _maximumConcurrentDownloads) {
      _activeDownloads += 1;
      return Future<void>.value();
    }
    final waiter = Completer<void>();
    _downloadWaiters.addLast(waiter);
    return waiter.future;
  }

  void _releaseDownloadSlot() {
    _activeDownloads -= 1;
    if (!_disposed && _downloadWaiters.isNotEmpty) {
      _activeDownloads += 1;
      _downloadWaiters.removeFirst().complete();
    }
  }

  Future<CachedResourceImage?> _readDisk(String resourceId) {
    return _serializeDiskOperation(() => _readDiskLocked(resourceId));
  }

  Future<CachedResourceImage?> _readDiskLocked(String resourceId) async {
    if (_disposed) return null;
    try {
      final directory = await _directory();
      final index = await _loadDiskIndex(directory);
      final key = _cacheKey(resourceId);
      final files = _filesForKey(directory, key);
      if (!await files.bytes.exists() || !await files.metadata.exists()) {
        if (index.entries.remove(key) != null) {
          await _persistDiskIndex(directory, index);
        }
        return null;
      }
      final metadata = jsonDecode(await files.metadata.readAsString());
      if (metadata is! Map ||
          metadata['mimeType'] is! String ||
          metadata['sizeBytes'] is! int) {
        await _deleteFiles(files);
        index.entries.remove(key);
        await _persistDiskIndex(directory, index);
        return null;
      }
      final bytes = await files.bytes.readAsBytes();
      final mimeType = (metadata['mimeType'] as String).toLowerCase();
      if (bytes.length != metadata['sizeBytes'] ||
          bytes.length > ChatImagePlaybackClient.maxImageBytes ||
          !_isValidImage(bytes, mimeType)) {
        await _deleteFiles(files);
        index.entries.remove(key);
        await _persistDiskIndex(directory, index);
        return null;
      }
      final touchedAt = _now().toUtc();
      await files.bytes.setLastModified(touchedAt);
      await files.metadata.setLastModified(touchedAt);
      index.entries[key] = _DiskIndexEntry(
        sizeBytes: bytes.length,
        lastAccessMicros: touchedAt.microsecondsSinceEpoch,
      );
      await _persistDiskIndex(directory, index);
      return CachedResourceImage(
        resourceId: resourceId,
        bytes: bytes,
        mimeType: mimeType,
      );
    } on Object {
      return null;
    }
  }

  Future<void> _writeDisk(CachedResourceImage image) {
    if (_disposed || image.sizeBytes > diskLimitBytes) {
      return Future<void>.value();
    }
    return _serializeDiskOperation(() => _writeDiskLocked(image));
  }

  Future<void> _writeDiskLocked(CachedResourceImage image) async {
    if (_disposed) return;
    try {
      final directory = await _directory();
      final index = await _loadDiskIndex(directory);
      final key = _cacheKey(image.resourceId);
      final files = _filesForKey(directory, key);
      final bytesPart = File('${files.bytes.path}.part');
      final metadataPart = File('${files.metadata.path}.part');
      if (await bytesPart.exists()) await bytesPart.delete();
      if (await metadataPart.exists()) await metadataPart.delete();
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
      index.entries[key] = _DiskIndexEntry(
        sizeBytes: image.sizeBytes,
        lastAccessMicros: _now().toUtc().microsecondsSinceEpoch,
      );
      await _enforceDiskLimit(directory, index);
      await _persistDiskIndex(directory, index);
    } on Object {
      // Disk persistence is only a cache optimization. A validated in-memory
      // image remains usable when the platform cache directory is unavailable.
    }
  }

  Future<void> _enforceDiskLimit(
    Directory directory,
    _DiskCacheIndex index,
  ) async {
    var total = index.totalBytes;
    if (total <= diskLimitBytes) return;
    final entries = index.entries.entries.toList(growable: false)
      ..sort(
        (left, right) =>
            left.value.lastAccessMicros.compareTo(right.value.lastAccessMicros),
      );
    for (final entry in entries) {
      if (total <= diskLimitBytes) break;
      try {
        await _deleteFiles(_filesForKey(directory, entry.key));
      } on Object {
        // The index still forgets an entry whose cache file disappeared.
      }
      index.entries.remove(entry.key);
      total -= entry.value.sizeBytes;
    }
  }

  void _remember(CachedResourceImage image, int memoryGeneration) {
    if (_disposed || memoryGeneration != _memoryGeneration) return;
    final existing = _memory.remove(image.resourceId);
    if (existing != null) _memoryBytes -= existing.sizeBytes;
    _memory[image.resourceId] = image;
    _memoryBytes += image.sizeBytes;
    _trimMemory();
  }

  void setMemoryLimitBytes(int value) {
    if (value < 0) throw ArgumentError.value(value, 'value');
    _memoryLimitBytes = value;
    _trimMemory();
  }

  void clearMemory() {
    _memoryGeneration += 1;
    _memory.clear();
    _memoryBytes = 0;
  }

  void _throwIfDisposed() {
    if (_disposed) {
      throw const ResourceImageCacheException('RESOURCE_IMAGE_CACHE_DISPOSED');
    }
  }

  void _trimMemory() {
    while (_memoryBytes > _memoryLimitBytes && _memory.isNotEmpty) {
      final oldestKey = _memory.keys.first;
      final oldest = _memory.remove(oldestKey);
      if (oldest != null) _memoryBytes -= oldest.sizeBytes;
    }
  }

  String _cacheKey(String resourceId) =>
      sha256.convert(utf8.encode(resourceId)).toString();

  _ResourceImageFiles _filesForKey(Directory directory, String key) {
    return _ResourceImageFiles(
      bytes: File('${directory.path}/$key.bin'),
      metadata: File('${directory.path}/$key.json'),
    );
  }

  Future<Directory> _directory() {
    return _scopeDirectory ??= _cacheDirectoryProvider().then((base) async {
      final directory = Directory(
        '${base.path}${Platform.pathSeparator}huahuo-resource-images'
        '${Platform.pathSeparator}$_scopeHash',
      );
      if (!await directory.exists()) await directory.create(recursive: true);
      return directory;
    });
  }

  Future<void> _deleteFiles(_ResourceImageFiles files) async {
    if (await files.bytes.exists()) await files.bytes.delete();
    if (await files.metadata.exists()) await files.metadata.delete();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    clearMemory();
    _inflight.clear();
    while (_downloadWaiters.isNotEmpty) {
      _downloadWaiters.removeFirst().completeError(
        const ResourceImageCacheException('RESOURCE_IMAGE_CACHE_DISPOSED'),
      );
    }
    _playbackClient.dispose();
  }

  Future<T> _serializeDiskOperation<T>(Future<T> Function() operation) {
    final result = Completer<T>();
    _diskOperations = _diskOperations.then((_) async {
      try {
        result.complete(await operation());
      } on Object catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      }
    });
    return result.future;
  }

  Future<_DiskCacheIndex> _loadDiskIndex(Directory directory) async {
    final loaded = _diskIndex;
    if (loaded != null) return loaded;
    final indexFile = File(
      '${directory.path}${Platform.pathSeparator}cache-index-v1.json',
    );
    try {
      final decoded = jsonDecode(await indexFile.readAsString());
      if (decoded is! Map ||
          decoded['schemaVersion'] != 1 ||
          decoded['entries'] is! Map) {
        throw const FormatException('resource image cache index invalid');
      }
      final entries = <String, _DiskIndexEntry>{};
      for (final raw in (decoded['entries'] as Map).entries) {
        final key = raw.key;
        final value = raw.value;
        if (key is! String ||
            !_diskCacheKeyPattern.hasMatch(key) ||
            value is! Map ||
            value['sizeBytes'] is! int ||
            value['lastAccessMicros'] is! int) {
          throw const FormatException('resource image cache entry invalid');
        }
        final sizeBytes = value['sizeBytes'] as int;
        final lastAccessMicros = value['lastAccessMicros'] as int;
        if (sizeBytes <= 0 ||
            sizeBytes > ChatImagePlaybackClient.maxImageBytes ||
            lastAccessMicros < 0) {
          throw const FormatException('resource image cache entry invalid');
        }
        entries[key] = _DiskIndexEntry(
          sizeBytes: sizeBytes,
          lastAccessMicros: lastAccessMicros,
        );
      }
      return _diskIndex = _DiskCacheIndex(entries);
    } on Object {
      final rebuilt = await _rebuildDiskIndex(directory);
      _diskIndex = rebuilt;
      await _persistDiskIndex(directory, rebuilt);
      return rebuilt;
    }
  }

  Future<_DiskCacheIndex> _rebuildDiskIndex(Directory directory) async {
    final entries = <String, _DiskIndexEntry>{};
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.bin')) continue;
      final name = entity.uri.pathSegments.last;
      final key = name.substring(0, name.length - 4);
      if (!_diskCacheKeyPattern.hasMatch(key)) continue;
      try {
        final stat = await entity.stat();
        if (stat.size <= 0 ||
            stat.size > ChatImagePlaybackClient.maxImageBytes) {
          continue;
        }
        entries[key] = _DiskIndexEntry(
          sizeBytes: stat.size,
          lastAccessMicros: stat.modified.toUtc().microsecondsSinceEpoch,
        );
      } on Object {
        // A cache rebuild tolerates files concurrently removed by the OS.
      }
    }
    return _DiskCacheIndex(entries);
  }

  Future<void> _persistDiskIndex(
    Directory directory,
    _DiskCacheIndex index,
  ) async {
    final target = File(
      '${directory.path}${Platform.pathSeparator}cache-index-v1.json',
    );
    final part = File('${target.path}.part');
    if (await part.exists()) await part.delete();
    await part.writeAsString(
      jsonEncode(<String, Object?>{
        'schemaVersion': 1,
        'entries': <String, Object?>{
          for (final entry in index.entries.entries)
            entry.key: <String, Object?>{
              'sizeBytes': entry.value.sizeBytes,
              'lastAccessMicros': entry.value.lastAccessMicros,
            },
        },
      }),
      flush: true,
    );
    if (await target.exists()) await target.delete();
    await part.rename(target.path);
  }
}

final class _ResourceImageFiles {
  const _ResourceImageFiles({required this.bytes, required this.metadata});

  final File bytes;
  final File metadata;
}

final class _DiskCacheIndex {
  const _DiskCacheIndex(this.entries);

  final Map<String, _DiskIndexEntry> entries;

  int get totalBytes =>
      entries.values.fold<int>(0, (total, entry) => total + entry.sizeBytes);
}

final class _DiskIndexEntry {
  const _DiskIndexEntry({
    required this.sizeBytes,
    required this.lastAccessMicros,
  });

  final int sizeBytes;
  final int lastAccessMicros;
}

final _diskCacheKeyPattern = RegExp(r'^[a-f0-9]{64}$');

int _validatedMemoryLimit(int value) {
  if (value < 0) throw ArgumentError.value(value, 'memoryLimitBytes');
  return value;
}

int _validatedDownloadLimit(int value) {
  if (value <= 0) {
    throw ArgumentError.value(value, 'maximumConcurrentDownloads');
  }
  return value;
}

bool _isValidImage(Uint8List bytes, String mimeType) {
  if (!_isSupportedMimeType(mimeType) || bytes.isEmpty) return false;
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

bool _isSupportedMimeType(String value) => const <String>{
  'image/png',
  'image/jpeg',
  'image/jpg',
  'image/gif',
  'image/webp',
}.contains(value.toLowerCase());
