import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/api/api_client.dart';
import 'package:huahuoai_app/features/chat/data/authenticated_resource_image_cache.dart';
import 'package:huahuoai_app/features/chat/data/chat_api.dart';

void main() {
  test(
    'bounds distinct misses while cache hits bypass network admission',
    () async {
      final root = await Directory.systemTemp.createTemp('image-admission-');
      addTearDown(() => root.delete(recursive: true));
      final transport = _PlaybackTransport(
        Uri.parse('https://images.test/image'),
      );
      final gates = <String, Completer<ChatImageBytes>>{};
      final cache = _cache(
        transport: transport,
        root: root,
        userScope: 'user',
        workspaceScope: 'workspace',
        maximumConcurrentDownloads: 2,
        download: (playback) {
          if (playback.resourceId == 'cached') {
            return Future.value(
              ChatImageBytes(
                bytes: Uint8List.fromList(_png),
                mimeType: 'image/png',
              ),
            );
          }
          final gate = Completer<ChatImageBytes>();
          gates[playback.resourceId] = gate;
          return gate.future;
        },
      );
      await cache.load('cached');
      await _waitForIndexedResource(root, 'cached');
      final futures = List.generate(
        6,
        (index) => cache.load('resource_$index'),
      );
      expect(identical(cache.load('resource_0'), futures.first), isTrue);
      await _waitUntil(() => gates.length == 2);
      expect(transport.requests, 3);
      expect((await cache.load('cached')).resourceId, 'cached');
      cache.clearMemory();
      expect(
        (await cache.load('cached').timeout(const Duration(seconds: 1)))
            .resourceId,
        'cached',
      );
      expect(transport.requests, 3);
      for (var index = 0; index < 6; index += 1) {
        await _waitUntil(() => gates.containsKey('resource_$index'));
        expect(gates.length, lessThanOrEqualTo(index + 2));
        gates['resource_$index']!.complete(
          ChatImageBytes(
            bytes: Uint8List.fromList(_png),
            mimeType: 'image/png',
          ),
        );
        await futures[index];
      }
      expect(gates.keys, List.generate(6, (index) => 'resource_$index'));
      expect(transport.requests, 7);
      await _waitForIndexedResource(root, 'resource_5', entryCount: 7);
    },
  );

  test(
    'disposal rejects queued downloads before an active fake completes',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'image-queue-dispose-',
      );
      addTearDown(() => root.delete(recursive: true));
      final transport = _PlaybackTransport(
        Uri.parse('https://images.test/image'),
      );
      final gate = Completer<ChatImageBytes>();
      final cache = _cache(
        transport: transport,
        root: root,
        userScope: 'user',
        workspaceScope: 'workspace',
        maximumConcurrentDownloads: 1,
        download: (_) => gate.future,
      );
      final active = cache.load('active');
      await _waitUntil(() => transport.requests == 1);
      final queued = cache.load('queued');
      final disposedError = isA<ResourceImageCacheException>().having(
        (error) => error.code,
        'code',
        'RESOURCE_IMAGE_CACHE_DISPOSED',
      );
      final activeExpectation = expectLater(active, throwsA(disposedError));
      final queuedExpectation = expectLater(queued, throwsA(disposedError));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      cache.dispose();
      await queuedExpectation.timeout(const Duration(seconds: 1));
      expect(transport.requests, 1);
      gate.complete(
        ChatImageBytes(bytes: Uint8List.fromList(_png), mimeType: 'image/png'),
      );
      await activeExpectation;
      expect(cache.memoryEntryCount, 0);
    },
  );

  test(
    'refreshes a rejected signed URL once and never retries invalid bytes',
    () async {
      final root = await Directory.systemTemp.createTemp('image-retry-');
      addTearDown(() => root.delete(recursive: true));
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final signedAttempts = <String>[];
      server.listen((request) async {
        signedAttempts.add(request.uri.query);
        if (signedAttempts.length == 1) {
          request.response.statusCode = 403;
        } else {
          request.response.headers.contentType = ContentType('image', 'png');
          request.response.add(signedAttempts.length == 2 ? _png : [1, 2, 3]);
        }
        await request.response.close();
      });
      final transport = _PlaybackTransport(
        Uri.parse('http://127.0.0.1:${server.port}/image'),
        refreshSignedUrl: true,
      );
      final cache = _cache(
        transport: transport,
        root: root,
        userScope: 'user',
        workspaceScope: 'workspace',
      );
      expect((await cache.load('valid')).mimeType, 'image/png');
      expect(transport.requests, 2);
      expect(signedAttempts.toSet().length, 2);
      await expectLater(
        cache.load('invalid'),
        throwsA(
          isA<ResourceImageCacheException>().having(
            (error) => error.code,
            'code',
            'CHAT_IMAGE_BYTES_INVALID',
          ),
        ),
      );
      expect(transport.requests, 3);
      expect(signedAttempts.length, 3);
    },
  );

  test('transient download retry is capped and releases its slot', () async {
    final root = await Directory.systemTemp.createTemp('image-retry-limit-');
    addTearDown(() => root.delete(recursive: true));
    final transport = _PlaybackTransport(
      Uri.parse('https://images.test/image'),
    );
    final cache = _cache(
      transport: transport,
      root: root,
      userScope: 'user',
      workspaceScope: 'workspace',
      maximumConcurrentDownloads: 1,
      download: (playback) async {
        if (playback.resourceId == 'failed') {
          throw const ChatImageDownloadException(
            'CHAT_IMAGE_DOWNLOAD_TIMEOUT',
            isRetryable: true,
          );
        }
        return ChatImageBytes(
          bytes: Uint8List.fromList(_png),
          mimeType: 'image/png',
        );
      },
    );
    final failed = expectLater(
      cache.load('failed'),
      throwsA(isA<ResourceImageCacheException>()),
    );
    final next = cache.load('next');
    await failed;
    expect((await next).resourceId, 'next');
    expect(transport.requests, 3);
  });

  test('completed image downloads reuse a keep-alive connection', () async {
    final server = await _ImageServer.start();
    addTearDown(server.close);
    final client = ChatImagePlaybackClient(
      _client(_PlaybackTransport(server.url)),
    );
    addTearDown(client.dispose);
    final playback = (await client.resolve('image')).data!;
    await client.download(playback);
    await client.download(playback);
    expect(server.downloads, 2);
    expect(server.remotePorts.length, 1);
  });

  for (final stage in ['headers', 'body']) {
    test(
      'download deadline cancels stalled $stage without closing other reads',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        final disconnected = Completer<void>();
        server.listen((request) async {
          if (request.uri.path == '/healthy') {
            request.response.headers.contentType = ContentType('image', 'png');
            request.response.add(_png);
            await request.response.close();
            return;
          }
          final socket = await request.response.detachSocket(
            writeHeaders: false,
          );
          addTearDown(socket.destroy);
          socket.listen(
            (_) {},
            onDone: () {
              if (!disconnected.isCompleted) disconnected.complete();
            },
            onError: (Object _) {
              if (!disconnected.isCompleted) disconnected.complete();
            },
          );
          if (stage == 'body') {
            socket.write(
              'HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: 1000\r\n\r\n',
            );
            socket.add(_png);
            await socket.flush();
          }
        });
        final url = Uri.parse('http://127.0.0.1:${server.port}/stalled');
        final client = ChatImagePlaybackClient(
          _client(_PlaybackTransport(url)),
          downloadTimeout: const Duration(milliseconds: 200),
        );
        addTearDown(client.dispose);
        final playback = (await client.resolve('image')).data!;
        final failure = expectLater(
          client.download(playback),
          throwsA(
            isA<ChatImageDownloadException>().having(
              (error) => error.code,
              'code',
              'CHAT_IMAGE_DOWNLOAD_TIMEOUT',
            ),
          ),
        );
        final healthy = await client.download(
          ChatImagePlayback(
            resourceId: 'healthy',
            url: url.resolve('/healthy'),
            mimeType: 'image/png',
            displayName: 'healthy.png',
          ),
        );
        expect(healthy.bytes, _png);
        await failure;
        await disconnected.future.timeout(const Duration(seconds: 2));
        expect(
          (await client.download(
            ChatImagePlayback(
              resourceId: 'healthy',
              url: url.resolve('/healthy'),
              mimeType: 'image/png',
              displayName: 'healthy.png',
            ),
          )).bytes,
          _png,
        );
      },
    );
  }

  test('Resource playback accepts a validated GIF', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.headers.contentType = ContentType('image', 'gif');
      request.response.add(ascii.encode('GIF89a'));
      await request.response.close();
    });
    final client = ChatImagePlaybackClient(
      _client(
        _PlaybackTransport(
          Uri.parse('http://127.0.0.1:${server.port}/image'),
          mimeType: 'image/gif',
        ),
      ),
    );
    addTearDown(client.dispose);
    final playback = await client.resolve('gif');
    expect(playback.ok, isTrue);
    expect((await client.download(playback.data!)).mimeType, 'image/gif');
  });

  group('AuthenticatedResourceImageCache', () {
    test(
      'reuses validated disk bytes only inside the same account workspace',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'resource-image-cache-',
        );
        final server = await _ImageServer.start();
        addTearDown(() async {
          await server.close();
          try {
            if (await root.exists()) await root.delete(recursive: true);
          } on FileSystemException {
            // The system test temp cleaner may remove this directory first.
          }
        });
        final transport = _PlaybackTransport(server.url);

        final first = _cache(
          transport: transport,
          root: root,
          userScope: 'user_a',
          workspaceScope: 'workspace_1',
        );
        final initial = await first.load('resource_1');
        expect(initial.mimeType, 'image/png');
        expect(initial.bytes, Uint8List.fromList(_png));
        expect(server.downloads, 1);
        expect(transport.requests, 1);

        final memoryHit = await first.load('resource_1');
        expect(memoryHit.bytes, initial.bytes);
        expect(server.downloads, 1);
        await _waitForDiskWrite(root);
        first.dispose();

        final sameScope = _cache(
          transport: transport,
          root: root,
          userScope: 'user_a',
          workspaceScope: 'workspace_1',
        );
        await sameScope.load('resource_1');
        expect(server.downloads, 1);
        expect(transport.requests, 1);

        final otherAccount = _cache(
          transport: transport,
          root: root,
          userScope: 'user_b',
          workspaceScope: 'workspace_1',
        );
        await otherAccount.load('resource_1');
        expect(server.downloads, 2);
        expect(transport.requests, 2);

        final metadataFile = await root
            .list(recursive: true)
            .where(
              (entity) =>
                  entity.path.endsWith('.json') &&
                  !entity.path.endsWith('cache-index-v1.json'),
            )
            .cast<File>()
            .first;
        final metadata = await metadataFile.readAsString();
        expect(metadata, isNot(contains(server.url.toString())));
        expect(metadata, contains('image/png'));
        sameScope.dispose();
        otherAccount.dispose();
      },
    );

    test('retiers and clears the compressed memory LRU immediately', () async {
      final root = await Directory.systemTemp.createTemp(
        'resource-image-memory-',
      );
      final server = await _ImageServer.start();
      addTearDown(() async {
        await server.close();
        if (await root.exists()) await root.delete(recursive: true);
      });
      final cache = _cache(
        transport: _PlaybackTransport(server.url),
        root: root,
        userScope: 'user_memory',
        workspaceScope: 'workspace_memory',
        memoryLimitBytes: _png.length * 2,
      );

      await cache.load('resource_1');
      await cache.load('resource_2');
      expect(cache.memoryEntryCount, 2);
      expect(cache.memoryBytes, _png.length * 2);

      cache.setMemoryLimitBytes(_png.length);
      expect(cache.memoryLimitBytes, _png.length);
      expect(cache.memoryEntryCount, 1);
      expect(cache.memoryBytes, _png.length);

      cache.clearMemory();
      expect(cache.memoryEntryCount, 0);
      expect(cache.memoryBytes, 0);
      cache.dispose();
    });

    test(
      'clearMemory invalidates an in-flight download without failing its consumer',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'resource-image-late-clear-',
        );
        addTearDown(() async {
          if (await root.exists()) await root.delete(recursive: true);
        });
        final downloadStarted = Completer<void>();
        final releaseDownload = Completer<ChatImageBytes>();
        final cache = _cache(
          transport: _PlaybackTransport(
            Uri.parse('https://cdn.example.test/image.png'),
          ),
          root: root,
          userScope: 'user_late_clear',
          workspaceScope: 'workspace_late_clear',
          diskLimitBytes: 0,
          download: (_) {
            downloadStarted.complete();
            return releaseDownload.future;
          },
        );

        final pending = cache.load('resource_late_clear');
        await downloadStarted.future;
        cache.clearMemory();
        releaseDownload.complete(
          ChatImageBytes(
            bytes: Uint8List.fromList(_png),
            mimeType: 'image/png',
          ),
        );

        final image = await pending;
        expect(image.bytes, Uint8List.fromList(_png));
        expect(cache.memoryEntryCount, 0);
        expect(cache.memoryBytes, 0);
        cache.dispose();
      },
    );

    test(
      'dispose rejects a late download without repopulating memory or disk',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'resource-image-late-dispose-',
        );
        addTearDown(() async {
          if (await root.exists()) await root.delete(recursive: true);
        });
        final downloadStarted = Completer<void>();
        final releaseDownload = Completer<ChatImageBytes>();
        final cache = _cache(
          transport: _PlaybackTransport(
            Uri.parse('https://cdn.example.test/image.png'),
          ),
          root: root,
          userScope: 'user_late_dispose',
          workspaceScope: 'workspace_late_dispose',
          download: (_) {
            downloadStarted.complete();
            return releaseDownload.future;
          },
        );

        final pending = cache.load('resource_late_dispose');
        await downloadStarted.future;
        final expectation = expectLater(
          pending,
          throwsA(
            isA<ResourceImageCacheException>().having(
              (error) => error.code,
              'code',
              'RESOURCE_IMAGE_CACHE_DISPOSED',
            ),
          ),
        );
        cache.dispose();
        releaseDownload.complete(
          ChatImageBytes(
            bytes: Uint8List.fromList(_png),
            mimeType: 'image/png',
          ),
        );

        await expectation;
        expect(cache.memoryEntryCount, 0);
        expect(cache.memoryBytes, 0);
        final diskPayloadExists = await root
            .list(recursive: true)
            .any((entity) => entity.path.endsWith('.bin'));
        expect(diskPayloadExists, isFalse);
      },
    );

    test(
      'persists an indexed disk LRU and evicts without write-time scans',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'resource-image-index-',
        );
        final server = await _ImageServer.start();
        addTearDown(() async {
          await server.close();
          if (await root.exists()) await root.delete(recursive: true);
        });
        var now = DateTime.utc(2026, 8, 31, 8);
        final transport = _PlaybackTransport(server.url);
        final first = _cache(
          transport: transport,
          root: root,
          userScope: 'user_index',
          workspaceScope: 'workspace_index',
          memoryLimitBytes: 0,
          diskLimitBytes: _png.length,
          now: () => now,
        );

        await first.load('resource_1');
        await _waitForDiskEntries(root, 1);
        now = now.add(const Duration(minutes: 1));
        await first.load('resource_2');
        await _waitForIndexedResource(root, 'resource_2');
        await _waitForDiskEntries(root, 1);
        first.dispose();

        final sameScope = _cache(
          transport: transport,
          root: root,
          userScope: 'user_index',
          workspaceScope: 'workspace_index',
          memoryLimitBytes: 0,
          diskLimitBytes: _png.length,
          now: () => now,
        );
        await sameScope.load('resource_2');
        expect(server.downloads, 2);
        await sameScope.load('resource_1');
        expect(server.downloads, 3);
        sameScope.dispose();
      },
    );
  });
}

AuthenticatedResourceImageCache _cache({
  required _PlaybackTransport transport,
  required Directory root,
  required String userScope,
  required String workspaceScope,
  int memoryLimitBytes = 32 * 1024 * 1024,
  int diskLimitBytes = 250 * 1024 * 1024,
  DateTime Function()? now,
  ResourceImageByteDownloader? download,
  int maximumConcurrentDownloads = 4,
}) {
  final cache = AuthenticatedResourceImageCache(
    playbackClient: ChatImagePlaybackClient(_client(transport)),
    userScope: userScope,
    workspaceScope: workspaceScope,
    cacheDirectoryProvider: () async => root,
    memoryLimitBytes: memoryLimitBytes,
    diskLimitBytes: diskLimitBytes,
    now: now,
    download: download,
    maximumConcurrentDownloads: maximumConcurrentDownloads,
  );
  addTearDown(cache.dispose);
  return cache;
}

Future<void> _waitUntil(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Image operation did not progress');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

ApiClient _client(ApiTransport transport) => ApiClient(
  config: ApiClientConfig(
    baseUrl: Uri.parse('https://api.example.test'),
    clientVersion: 'test',
    deviceId: 'device_1',
    platform: 'ios',
    locale: 'zh-CN',
    getAccessToken: () async => 'access-token',
  ),
  transport: transport,
);

Future<void> _waitForDiskWrite(Directory root) async {
  for (var attempt = 0; attempt < 100; attempt += 1) {
    final found = await root
        .list(recursive: true)
        .any((entity) => entity.path.endsWith('.bin'));
    if (found) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Expected image bytes to reach the disk cache.');
}

Future<void> _waitForDiskEntries(Directory root, int count) async {
  for (var attempt = 0; attempt < 100; attempt += 1) {
    final entries = await root
        .list(recursive: true)
        .where((entity) => entity.path.endsWith('.bin'))
        .length;
    if (entries == count) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Expected $count image entries in the disk cache.');
}

Future<void> _waitForIndexedResource(
  Directory root,
  String resourceId, {
  int entryCount = 1,
}) async {
  final expectedKey = sha256.convert(utf8.encode(resourceId)).toString();
  for (var attempt = 0; attempt < 100; attempt += 1) {
    final matches = await root
        .list(recursive: true)
        .where((entity) => entity.path.endsWith('cache-index-v1.json'))
        .cast<File>()
        .toList();
    if (matches.length == 1) {
      try {
        final decoded = jsonDecode(await matches.single.readAsString()) as Map;
        final entries = decoded['entries'] as Map;
        if (entries.length == entryCount && entries.containsKey(expectedKey)) {
          return;
        }
      } on Object {
        // An atomic rename may be between reads; retry.
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Expected $resourceId to be the indexed image entry.');
}

final class _PlaybackTransport implements ApiTransport {
  _PlaybackTransport(
    this.url, {
    this.refreshSignedUrl = false,
    this.mimeType = 'image/png',
  });

  final Uri url;
  final bool refreshSignedUrl;
  final String mimeType;
  int requests = 0;

  @override
  Future<ApiTransportResponse> send(ApiTransportRequest request) async {
    requests += 1;
    const prefix = '/api/v1/media/resources/';
    const suffix = '/playback';
    final path = request.url.path;
    if (!path.startsWith(prefix) || !path.endsWith(suffix)) {
      throw StateError('Unexpected request: $path');
    }
    final resourceId = path.substring(
      prefix.length,
      path.length - suffix.length,
    );
    return ApiTransportResponse(
      status: 200,
      body: <String, Object?>{
        'success': true,
        'data': <String, Object?>{
          'resourceId': resourceId,
          'url':
              (refreshSignedUrl
                      ? url.replace(queryParameters: {'signature': '$requests'})
                      : url)
                  .toString(),
          'mimeType': mimeType,
          'fileName': 'generated.png',
        },
      },
    );
  }
}

final class _ImageServer {
  _ImageServer._(this._server);

  final HttpServer _server;
  int downloads = 0;
  final Set<int> remotePorts = {};

  Uri get url =>
      Uri.parse('http://${_server.address.address}:${_server.port}/image.png');

  static Future<_ImageServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final result = _ImageServer._(server);
    unawaited(
      server.forEach((request) async {
        result.downloads += 1;
        result.remotePorts.add(request.connectionInfo!.remotePort);
        request.response.headers.contentType = ContentType('image', 'png');
        request.response.add(_png);
        await request.response.close();
      }),
    );
    return result;
  }

  Future<void> close() => _server.close(force: true);
}

const _png = <int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
