import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:huahuo_api/huahuo_api.dart';
import 'package:huahuo_desktop/features/chat/data/desktop_resource_image_cache.dart';

void main() {
  test(
    'reuses a validated image in memory and isolates account scopes',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'desktop-image-cache-',
      );
      addTearDown(() => root.delete(recursive: true));
      var resolves = 0;
      var downloads = 0;
      final cache = RemoteDesktopResourceImageCache(
        apiClient: _unusedClient(),
        cacheDirectory: () async => root,
        resolvePlayback: (resourceId) async {
          resolves += 1;
          return DesktopResourceImagePlayback(
            resourceId: resourceId,
            url: Uri.parse('https://media.example.test/$resourceId'),
            mimeType: 'image/png',
          );
        },
        download: (_) async {
          downloads += 1;
          return DesktopResourceImageBytes(
            bytes: Uint8List.fromList(_pngHeader),
            mimeType: 'image/png',
          );
        },
        diskLimitBytes: 0,
      );
      addTearDown(cache.dispose);

      await cache.bindAccount(userId: 'user_a', workspaceId: 'workspace_1');
      final first = await cache.load('resource_1');
      final second = await cache.load('resource_1');

      expect(first.bytes, second.bytes);
      expect(resolves, 1);
      expect(downloads, 1);

      await cache.bindAccount(userId: 'user_b', workspaceId: 'workspace_1');
      await cache.load('resource_1');
      expect(resolves, 2);
      expect(downloads, 2);
    },
  );

  test(
    'reads persisted bytes without resolving another playback URL',
    () async {
      final root = await Directory.systemTemp.createTemp('desktop-image-disk-');
      addTearDown(() => root.delete(recursive: true));
      var firstDownloads = 0;
      final first = RemoteDesktopResourceImageCache(
        apiClient: _unusedClient(),
        cacheDirectory: () async => root,
        resolvePlayback: (resourceId) async => DesktopResourceImagePlayback(
          resourceId: resourceId,
          url: Uri.parse('https://media.example.test/$resourceId'),
          mimeType: 'image/png',
        ),
        download: (_) async {
          firstDownloads += 1;
          return DesktopResourceImageBytes(
            bytes: Uint8List.fromList(_pngHeader),
            mimeType: 'image/png',
          );
        },
      );
      await first.bindAccount(userId: 'user_a', workspaceId: 'workspace_1');
      await first.load('resource_1');
      await _eventuallyFile(root, '.bin');
      first.dispose();

      var secondResolves = 0;
      final second = RemoteDesktopResourceImageCache(
        apiClient: _unusedClient(),
        cacheDirectory: () async => root,
        resolvePlayback: (_) async {
          secondResolves += 1;
          throw StateError('disk cache should satisfy this read');
        },
        download: (_) async => throw StateError('download should not run'),
      );
      addTearDown(second.dispose);
      await second.bindAccount(userId: 'user_a', workspaceId: 'workspace_1');
      final restored = await second.load('resource_1');

      expect(firstDownloads, 1);
      expect(secondResolves, 0);
      expect(restored.mimeType, 'image/png');
    },
  );
}

Future<void> _eventuallyFile(Directory root, String suffix) async {
  for (var attempt = 0; attempt < 100; attempt += 1) {
    final entries = await root.list(recursive: true).toList();
    if (entries.any((entry) => entry.path.endsWith(suffix))) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('Timed out waiting for cache persistence.');
}

ApiClient _unusedClient() => ApiClient(
  config: ApiClientConfig(
    baseUrl: Uri.parse('https://api.example.test'),
    clientVersion: 'test',
    deviceId: 'desktop-test',
    platform: 'windows',
    locale: 'zh-CN',
  ),
  transport: _UnusedTransport(),
);

final class _UnusedTransport implements ApiTransport {
  @override
  Future<ApiTransportResponse> send(ApiTransportRequest request) async =>
      throw StateError(
        'The injected resource resolver should avoid ApiClient.',
      );
}

const _pngHeader = <int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
