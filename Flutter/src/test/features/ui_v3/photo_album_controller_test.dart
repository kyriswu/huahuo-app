import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/database/app_database.dart';
import 'package:huahuoai_app/core/database/app_preferences_dao.dart';
import 'package:huahuoai_app/core/native/native_file_port.dart';
import 'package:huahuoai_app/features/ui_v3/application/photo_album_controller.dart';
import 'package:huahuoai_app/features/ui_v3/data/photo_album_repository.dart';
import 'package:huahuoai_app/features/ui_v3/domain/photo_album_models.dart';
import 'package:huahuoai_app/core/api/api_client.dart';
import 'package:huahuoai_app/core/api/upload_client.dart';

void main() {
  late Directory temporary;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('huahuo-photo-album-');
  });

  tearDown(() async {
    if (await temporary.exists()) await temporary.delete(recursive: true);
  });

  test(
    'uploads, binds, and lists cloud photo metadata without playback reads',
    () async {
      final sourceA = await _writeSource(temporary, 'first.png', <int>[
        1,
        2,
        3,
      ]);
      final sourceB = await _writeSource(temporary, 'renamed.png', <int>[
        1,
        2,
        3,
      ]);
      final transport = _PhotoAlbumApiTransport();
      final objectTransport = _SuccessfulObjectUploadTransport();
      final repository = RemotePhotoAlbumRepository(
        apiClient: _apiClient(transport),
        workspaceId: () => 'workspace-photo',
        objectUploadTransport: objectTransport,
      );

      final result = await repository.importPhotos([
        _picked(sourceA),
        _picked(sourceB),
      ]);

      expect(result.importedCount, 1);
      expect(result.duplicateCount, 1);
      expect(result.entries, hasLength(1));
      expect(result.entries.single.id, 'visual-1');
      expect(result.entries.single.resourceId, 'resource-1');
      expect(result.entries.single.playbackUrl, isNull);
      expect(objectTransport.requests, hasLength(1));
      expect(
        transport.requests.map((request) => request.url.path),
        containsAllInOrder(<String>[
          '/api/v1/workspaces/workspace-photo/profile-visual-assets',
          '/api/v1/media/upload-token',
          '/api/v1/media/uploads/upload-1/complete',
          '/api/v1/workspaces/workspace-photo/profile-visual-assets',
          '/api/v1/workspaces/workspace-photo/profile-visual-assets',
        ]),
      );
      final bindRequest = transport.requests.firstWhere(
        (request) =>
            request.url.path.endsWith('/profile-visual-assets') &&
            request.method == 'POST',
      );
      expect(bindRequest.headers['X-Idempotency-Key'], isNotEmpty);
    },
  );

  test(
    'controller rejects more than nine selected photos without note effects',
    () async {
      final source = await _writeSource(temporary, 'photo.png', <int>[9]);
      final files = List<PickedMediaFile>.generate(
        10,
        (index) => _picked(source, name: '$index.png'),
      );
      final album = PhotoAlbumController(
        nativeFilePort: _MediaPicker(files),
        repository: _FakePhotoAlbumRepository(),
      );
      await album.load();

      expect(await album.pickAndImport(), isNull);
      expect(album.status, PhotoAlbumStatus.failed);
      expect(album.errorCode, 'PHOTO_ALBUM_SELECTION_COUNT_INVALID');
    },
  );

  test(
    'dismissed photo picker restores ready state without an error',
    () async {
      final album = PhotoAlbumController(
        nativeFilePort: const _CancelledMediaPicker(),
        repository: _FakePhotoAlbumRepository(),
      );
      await album.load();

      expect(await album.pickAndImport(), isNull);
      expect(album.status, PhotoAlbumStatus.ready);
      expect(album.errorCode, isNull);
    },
  );

  test('an unresolved photo picker stays ready and opens only once', () async {
    final picker = _DeferredMediaPicker();
    final album = PhotoAlbumController(
      nativeFilePort: picker,
      repository: _FakePhotoAlbumRepository(),
    );
    await album.load();

    final first = album.pickAndImport();
    await Future<void>.delayed(Duration.zero);
    final second = album.pickAndImport();

    expect(album.status, PhotoAlbumStatus.ready);
    expect(picker.calls, 1);

    picker.complete(NativeFileResult<List<PickedMediaFile>>.cancelled());
    await Future.wait(<Future<V3PhotoAlbumImportResult?>>[first, second]);
    expect(album.status, PhotoAlbumStatus.ready);
    expect(album.errorCode, isNull);
  });

  test(
    'restores safe cached metadata without resolving playback URLs',
    () async {
      final preferences = AppPreferencesDao(AppDatabase());
      final cache = PhotoAlbumMetadataCache(
        preferences: preferences,
        ownerScope: 'user-a\u0000workspace-a',
      );
      var now = DateTime.utc(2026, 8, 14, 8);
      final firstRepository = _CachedPhotoAlbumRepository(
        entries: <V3PhotoAlbumEntry>[_cachedEntry()],
      );
      final first = PhotoAlbumController(
        nativeFilePort: const _CancelledMediaPicker(),
        repository: firstRepository,
        cache: cache,
        now: () => now,
      );

      await first.load();
      expect(firstRepository.loadCalls, 1);
      final stored = preferences.listPreferences().single['value'] as String;
      expect(stored, contains('resource-cached'));
      expect(stored, isNot(contains('https://media.example.test')));

      final restoredRepository = _CachedPhotoAlbumRepository(
        entries: const <V3PhotoAlbumEntry>[],
      );
      final restored = PhotoAlbumController(
        nativeFilePort: const _CancelledMediaPicker(),
        repository: restoredRepository,
        cache: cache,
        now: () => now,
      );
      await restored.load();

      expect(restoredRepository.loadCalls, 0);
      expect(restoredRepository.playbackCalls, 0);
      expect(restored.status, PhotoAlbumStatus.ready);
      expect(restored.entries.single.playbackUrl, isNull);

      now = now.add(const Duration(minutes: 6));
      await restored.load();
      expect(restoredRepository.loadCalls, 0);
      await restored.load(forceRemote: true);
      expect(restoredRepository.loadCalls, 1);
    },
  );

  test(
    'repository validates every selected file before cloud mutation',
    () async {
      final valid = await _writeSource(temporary, 'valid.png', <int>[1]);
      final invalid = await _writeSource(temporary, 'invalid.gif', <int>[2]);
      final transport = _PhotoAlbumApiTransport();
      final repository = RemotePhotoAlbumRepository(
        apiClient: _apiClient(transport),
        workspaceId: () => 'workspace-photo',
        objectUploadTransport: _SuccessfulObjectUploadTransport(),
      );

      await expectLater(
        repository.importPhotos([_picked(valid), _picked(invalid)]),
        throwsA(
          isA<PhotoAlbumException>().having(
            (error) => error.code,
            'code',
            'PHOTO_ALBUM_FILE_UNSUPPORTED',
          ),
        ),
      );
      expect(transport.requests.map((request) => request.url.path), <String>[
        '/api/v1/workspaces/workspace-photo/profile-visual-assets',
      ]);
    },
  );

  test('deletes a cloud Resource with an idempotency key', () async {
    final transport = _PhotoAlbumApiTransport();
    final repository = RemotePhotoAlbumRepository(
      apiClient: _apiClient(transport),
      workspaceId: () => 'workspace-photo',
    );

    final receipt = await repository.deleteResource(
      resourceId: 'resource-1',
      idempotencyKey: 'photo-delete-key',
    );

    expect(receipt.status, 'deleted');
    final request = transport.requests.single;
    expect(request.method, 'DELETE');
    expect(
      request.url.path,
      '/api/v1/workspaces/workspace-photo/media/resources/resource-1',
    );
    expect(request.headers['X-Idempotency-Key'], 'photo-delete-key');
  });

  test(
    'controller retries a delete with one key and removes pending Resource',
    () async {
      final repository = _DeletingPhotoAlbumRepository(
        entries: <V3PhotoAlbumEntry>[_cachedEntry()],
        results: <Object?>[
          const PhotoAlbumException('RESOURCE_IN_USE'),
          const MediaResourceDeleteReceipt(
            workspaceId: 'workspace-photo',
            resourceId: 'resource-cached',
            status: 'delete_pending',
          ),
        ],
      );
      final controller = PhotoAlbumController(
        nativeFilePort: const _CancelledMediaPicker(),
        repository: repository,
        now: () => DateTime.utc(2026, 8, 17),
      );
      await controller.load();

      expect(await controller.deleteResource('resource-cached'), isNull);
      expect(controller.entries, hasLength(1));
      expect(controller.errorCode, 'RESOURCE_IN_USE');
      final deleted = await controller.deleteResource('resource-cached');

      expect(deleted?.isPendingCleanup, isTrue);
      expect(controller.entries, isEmpty);
      expect(repository.idempotencyKeys, hasLength(2));
      expect(repository.idempotencyKeys.first, repository.idempotencyKeys.last);
    },
  );

  test(
    'accepted deletion cannot be restored by an older list refresh',
    () async {
      final repository = _RacingPhotoAlbumRepository();
      final controller = PhotoAlbumController(
        nativeFilePort: const _CancelledMediaPicker(),
        repository: repository,
        now: () => DateTime.utc(2026, 8, 17),
      );
      await controller.load();

      final refresh = controller.load(forceRemote: true);
      await Future<void>.delayed(Duration.zero);
      final deleted = await controller.deleteResource('resource-cached');
      repository.refresh.complete(<V3PhotoAlbumEntry>[_cachedEntry()]);
      await refresh;
      await Future<void>.delayed(Duration.zero);

      expect(deleted?.status, 'deleted');
      expect(controller.entries, isEmpty);
    },
  );

  test('controller coalesces overlapping remote album loads', () async {
    final repository = _DeferredPhotoAlbumRepository();
    final controller = PhotoAlbumController(
      nativeFilePort: const _CancelledMediaPicker(),
      repository: repository,
    );

    final first = controller.load();
    final second = controller.load(forceRemote: true);

    expect(identical(first, second), isTrue);
    expect(repository.loadCalls, 1);

    repository.response.complete(<V3PhotoAlbumEntry>[
      _cachedEntryWithoutPlayback(),
    ]);
    await Future.wait<void>([first, second]);

    expect(controller.status, PhotoAlbumStatus.ready);
    expect(controller.entries.single.resourceId, 'resource-cached');
  });

  test('cursor baseline completion is ignored after disposal', () async {
    final repository = _DeferredCursorPhotoAlbumRepository();
    final controller = PhotoAlbumController(
      nativeFilePort: const _CancelledMediaPicker(),
      repository: repository,
      contentSync: repository,
    );

    final loading = controller.load();
    await Future<void>.delayed(Duration.zero);
    controller.dispose();
    repository.cursor.complete(
      const PhotoAlbumContentCursorResult.success('10'),
    );
    await loading;

    expect(repository.loadCalls, 0);
  });

  test(
    'matching content cursor reopens cached album without a list read',
    () async {
      final preferences = AppPreferencesDao(AppDatabase());
      final cache = PhotoAlbumMetadataCache(
        preferences: preferences,
        ownerScope: 'cursor-user\u0000workspace',
      );
      cache.save(
        <V3PhotoAlbumEntry>[_cachedEntryWithoutPlayback()],
        savedAt: DateTime.utc(2026, 8, 18),
        contentCursor: '10',
      );
      final repository = _CursorPhotoAlbumRepository(
        entries: <V3PhotoAlbumEntry>[_cachedEntryWithoutPlayback()],
        cursorResults: <PhotoAlbumContentCursorResult>[
          const PhotoAlbumContentCursorResult.success('10'),
        ],
      );
      final controller = PhotoAlbumController(
        nativeFilePort: const _CancelledMediaPicker(),
        repository: repository,
        cache: cache,
        contentSync: repository,
      );

      await controller.load();

      expect(repository.loadCalls, 0);
      expect(repository.changeAfters, isEmpty);
      expect(controller.entries.single.resourceId, 'resource-cached');
    },
  );

  test(
    'unrelated content changes advance the album checkpoint without a list read',
    () async {
      final preferences = AppPreferencesDao(AppDatabase());
      final cache = PhotoAlbumMetadataCache(
        preferences: preferences,
        ownerScope: 'cursor-user\u0000workspace',
      );
      cache.save(
        <V3PhotoAlbumEntry>[_cachedEntryWithoutPlayback()],
        savedAt: DateTime.utc(2026, 8, 18),
        contentCursor: '10',
      );
      final repository = _CursorPhotoAlbumRepository(
        entries: <V3PhotoAlbumEntry>[_cachedEntryWithoutPlayback()],
        cursorResults: <PhotoAlbumContentCursorResult>[
          const PhotoAlbumContentCursorResult.success('12'),
        ],
        changeResults: <PhotoAlbumContentChangesResult>[
          PhotoAlbumContentChangesResult.success(
            events: <SharedWorkspaceContentEvent>[
              _contentEvent(objectKind: 'hnote', cursor: '12'),
            ],
            nextAfter: '12',
            hasMore: false,
          ),
        ],
      );
      final controller = PhotoAlbumController(
        nativeFilePort: const _CancelledMediaPicker(),
        repository: repository,
        cache: cache,
        contentSync: repository,
      );

      await controller.load();

      expect(repository.loadCalls, 0);
      expect(repository.changeAfters, <String>['10']);
      expect(cache.restore()?.contentCursor, '12');
    },
  );

  test(
    'visual asset changes refresh metadata once after delta inspection',
    () async {
      final preferences = AppPreferencesDao(AppDatabase());
      final cache = PhotoAlbumMetadataCache(
        preferences: preferences,
        ownerScope: 'cursor-user\u0000workspace',
      );
      cache.save(
        <V3PhotoAlbumEntry>[_cachedEntryWithoutPlayback()],
        savedAt: DateTime.utc(2026, 8, 18),
        contentCursor: '10',
      );
      final updated = V3PhotoAlbumEntry(
        id: 'visual-new',
        resourceId: 'resource-new',
        displayName: '新增照片',
        role: 'gallery_photo',
        ordinal: 1,
        version: 1,
        etag:
            '"wcc-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"',
      );
      final repository = _CursorPhotoAlbumRepository(
        entries: <V3PhotoAlbumEntry>[updated],
        cursorResults: <PhotoAlbumContentCursorResult>[
          const PhotoAlbumContentCursorResult.success('12'),
        ],
        changeResults: <PhotoAlbumContentChangesResult>[
          PhotoAlbumContentChangesResult.success(
            events: <SharedWorkspaceContentEvent>[
              _contentEvent(objectKind: 'profile_visual_asset', cursor: '12'),
            ],
            nextAfter: '12',
            hasMore: false,
          ),
        ],
      );
      final controller = PhotoAlbumController(
        nativeFilePort: const _CancelledMediaPicker(),
        repository: repository,
        cache: cache,
        contentSync: repository,
      );

      await controller.load();

      expect(repository.changeAfters, <String>['10']);
      expect(repository.loadCalls, 1);
      expect(controller.entries.single.resourceId, 'resource-new');
      expect(cache.restore()?.contentCursor, '12');
    },
  );

  test(
    'expired album cursor keeps cache until a new pre-list baseline is read',
    () async {
      final preferences = AppPreferencesDao(AppDatabase());
      final cache = PhotoAlbumMetadataCache(
        preferences: preferences,
        ownerScope: 'cursor-user\u0000workspace',
      );
      cache.save(
        <V3PhotoAlbumEntry>[_cachedEntryWithoutPlayback()],
        savedAt: DateTime.utc(2026, 8, 18),
        contentCursor: '10',
      );
      final repository = _CursorPhotoAlbumRepository(
        entries: <V3PhotoAlbumEntry>[_cachedEntryWithoutPlayback()],
        cursorResults: <PhotoAlbumContentCursorResult>[
          const PhotoAlbumContentCursorResult.success('12'),
          const PhotoAlbumContentCursorResult.success('12'),
        ],
        changeResults: <PhotoAlbumContentChangesResult>[
          const PhotoAlbumContentChangesResult.failure(
            errorCode: 'CONTENT_CURSOR_EXPIRED',
            status: 410,
          ),
        ],
      );
      final controller = PhotoAlbumController(
        nativeFilePort: const _CancelledMediaPicker(),
        repository: repository,
        cache: cache,
        contentSync: repository,
      );

      await controller.load();

      expect(repository.loadCalls, 1);
      expect(repository.changeAfters, <String>['10']);
      expect(repository.cursorCalls, 2);
      expect(cache.restore()?.contentCursor, '12');
      expect(controller.entries.single.resourceId, 'resource-cached');
    },
  );
}

Future<File> _writeSource(Directory root, String name, List<int> bytes) async {
  final directory = Directory('${root.path}/sources')
    ..createSync(recursive: true);
  return File('${directory.path}/$name')..writeAsBytesSync(bytes);
}

PickedMediaFile _picked(File file, {String? name}) => PickedMediaFile(
  pickerRef: file.path,
  displayName: name ?? file.uri.pathSegments.last,
  mimeType: 'image/${file.path.endsWith('.jpg') ? 'jpeg' : 'png'}',
  sizeBytes: file.lengthSync(),
  kind: NativeMediaKind.image,
  source: NativeMediaSource.gallery,
  sourcePath: file.path,
);

final class _MediaPicker implements NativeFilePort, NativeMediaFilePort {
  const _MediaPicker(this.files);

  final List<PickedMediaFile> files;

  @override
  Future<NativeFileResult<List<PickedAudioFile>>> pickAudioFiles() async =>
      NativeFileResult<List<PickedAudioFile>>.success(
        const <PickedAudioFile>[],
      );

  @override
  Future<NativeFileResult<List<PickedMediaFile>>> pickMediaFiles({
    required NativeMediaKind kind,
    required NativeMediaSource source,
  }) async => NativeFileResult<List<PickedMediaFile>>.success(files);
}

final class _CancelledMediaPicker
    implements NativeFilePort, NativeMediaFilePort {
  const _CancelledMediaPicker();

  @override
  Future<NativeFileResult<List<PickedAudioFile>>> pickAudioFiles() async =>
      NativeFileResult<List<PickedAudioFile>>.success(
        const <PickedAudioFile>[],
      );

  @override
  Future<NativeFileResult<List<PickedMediaFile>>> pickMediaFiles({
    required NativeMediaKind kind,
    required NativeMediaSource source,
  }) async => NativeFileResult<List<PickedMediaFile>>.cancelled();
}

final class _DeferredMediaPicker
    implements NativeFilePort, NativeMediaFilePort {
  final Completer<NativeFileResult<List<PickedMediaFile>>> _result =
      Completer<NativeFileResult<List<PickedMediaFile>>>();
  int calls = 0;

  void complete(NativeFileResult<List<PickedMediaFile>> result) {
    _result.complete(result);
  }

  @override
  Future<NativeFileResult<List<PickedAudioFile>>> pickAudioFiles() async =>
      NativeFileResult<List<PickedAudioFile>>.cancelled();

  @override
  Future<NativeFileResult<List<PickedMediaFile>>> pickMediaFiles({
    required NativeMediaKind kind,
    required NativeMediaSource source,
  }) {
    calls += 1;
    return _result.future;
  }
}

ApiClient _apiClient(ApiTransport transport) => ApiClient(
  config: ApiClientConfig(
    baseUrl: Uri.parse('https://api.example.test'),
    clientVersion: 'test',
    deviceId: 'device-photo',
    platform: 'ios',
    locale: 'zh-CN',
    getAccessToken: () => 'access-token',
    traceIdFactory: () => 'trace-photo',
  ),
  transport: transport,
);

final class _PhotoAlbumApiTransport implements ApiTransport {
  final requests = <ApiTransportRequest>[];
  final assets = <Map<String, Object?>>[];

  @override
  Future<ApiTransportResponse> send(ApiTransportRequest request) async {
    requests.add(request);
    final path = request.url.path;
    if (request.method == 'GET' && path.endsWith('/profile-visual-assets')) {
      return _success(<String, Object?>{'items': assets});
    }
    if (request.method == 'POST' && path == '/api/v1/media/upload-token') {
      return _success(<String, Object?>{
        'uploadId': 'upload-1',
        'uploadUrl': 'https://object.example.test/upload-1',
        'method': 'PUT',
        'headers': <String, Object?>{'x-upload-token': 'signed'},
      });
    }
    if (request.method == 'POST' &&
        path == '/api/v1/media/uploads/upload-1/complete') {
      return _success(<String, Object?>{
        'uploadId': 'upload-1',
        'status': 'completed',
        'resource': <String, Object?>{
          'resourceId': 'resource-1',
          'sourceScene': 'workspace_attachment',
          'mimeType': 'image/png',
          'sizeBytes': 3,
          'durationSeconds': 0,
        },
      });
    }
    if (request.method == 'POST' && path.endsWith('/profile-visual-assets')) {
      assets.add(<String, Object?>{
        'visualAssetId': 'visual-1',
        'resourceId': 'resource-1',
        'role': 'gallery_photo',
        'caption': 'first.png',
        'ordinal': 0,
        'lifecycle': 'active',
        'version': 1,
        'etag': '"wcc-${'a' * 64}"',
      });
      return _success(<String, Object?>{'visualAssetId': 'visual-1'});
    }
    if (request.method == 'GET' &&
        path == '/api/v1/media/resources/resource-1/playback') {
      return _success(<String, Object?>{
        'resourceId': 'resource-1',
        'url': 'https://media.example.test/resource-1.png',
        'status': 'available',
        'expiresIn': 900,
      });
    }
    if (request.method == 'DELETE' &&
        path ==
            '/api/v1/workspaces/workspace-photo/media/resources/resource-1') {
      return _success(<String, Object?>{
        'workspaceId': 'workspace-photo',
        'resourceId': 'resource-1',
        'status': 'deleted',
      });
    }
    throw StateError('Unexpected API request: ${request.method} $path');
  }
}

ApiTransportResponse _success(Map<String, Object?> data) =>
    ApiTransportResponse(
      status: 200,
      body: <String, Object?>{
        'success': true,
        'traceId': 'trace-photo',
        'data': data,
      },
    );

final class _SuccessfulObjectUploadTransport implements ObjectUploadTransport {
  final requests = <ObjectUploadRequest>[];

  @override
  Future<ObjectUploadResult> upload(ObjectUploadRequest request) async {
    requests.add(request);
    return ObjectUploadResult.success(
      statusCode: 200,
      bytesSent: request.sizeBytes,
    );
  }
}

final class _FakePhotoAlbumRepository implements PhotoAlbumRepository {
  @override
  Future<List<V3PhotoAlbumEntry>> load() async => const <V3PhotoAlbumEntry>[];

  @override
  Future<V3PhotoAlbumImportResult> importPhotos(List<PickedMediaFile> files) =>
      throw StateError('Selection count must be validated before import.');

  @override
  Future<MediaResourceDeleteReceipt> deleteResource({
    required String resourceId,
    required String idempotencyKey,
  }) => throw UnimplementedError();

  @override
  Future<Uri?> resolvePlayback(String resourceId) async => null;
}

final class _CachedPhotoAlbumRepository implements PhotoAlbumRepository {
  _CachedPhotoAlbumRepository({required this.entries});

  final List<V3PhotoAlbumEntry> entries;
  var loadCalls = 0;
  var playbackCalls = 0;

  @override
  Future<List<V3PhotoAlbumEntry>> load() async {
    loadCalls += 1;
    return entries;
  }

  @override
  Future<V3PhotoAlbumImportResult> importPhotos(List<PickedMediaFile> files) =>
      throw UnimplementedError();

  @override
  Future<MediaResourceDeleteReceipt> deleteResource({
    required String resourceId,
    required String idempotencyKey,
  }) => throw UnimplementedError();

  @override
  Future<Uri?> resolvePlayback(String resourceId) async {
    playbackCalls += 1;
    return Uri.parse('https://media.example.test/$resourceId.png');
  }
}

final class _DeletingPhotoAlbumRepository implements PhotoAlbumRepository {
  _DeletingPhotoAlbumRepository({required this.entries, required this.results});

  final List<V3PhotoAlbumEntry> entries;
  final List<Object?> results;
  final List<String> idempotencyKeys = <String>[];

  @override
  Future<List<V3PhotoAlbumEntry>> load() async => entries;

  @override
  Future<V3PhotoAlbumImportResult> importPhotos(List<PickedMediaFile> files) =>
      throw UnimplementedError();

  @override
  Future<MediaResourceDeleteReceipt> deleteResource({
    required String resourceId,
    required String idempotencyKey,
  }) async {
    idempotencyKeys.add(idempotencyKey);
    final result = results.removeAt(0);
    if (result is PhotoAlbumException) throw result;
    return result! as MediaResourceDeleteReceipt;
  }

  @override
  Future<Uri?> resolvePlayback(String resourceId) async => null;
}

final class _RacingPhotoAlbumRepository implements PhotoAlbumRepository {
  final Completer<List<V3PhotoAlbumEntry>> refresh =
      Completer<List<V3PhotoAlbumEntry>>();
  final Completer<Uri?> playback = Completer<Uri?>();
  var loadCount = 0;

  @override
  Future<List<V3PhotoAlbumEntry>> load() {
    loadCount += 1;
    return loadCount == 1
        ? Future<List<V3PhotoAlbumEntry>>.value(<V3PhotoAlbumEntry>[
            _cachedEntryWithoutPlayback(),
          ])
        : refresh.future;
  }

  @override
  Future<V3PhotoAlbumImportResult> importPhotos(List<PickedMediaFile> files) =>
      throw UnimplementedError();

  @override
  Future<MediaResourceDeleteReceipt> deleteResource({
    required String resourceId,
    required String idempotencyKey,
  }) async => const MediaResourceDeleteReceipt(
    workspaceId: 'workspace-photo',
    resourceId: 'resource-cached',
    status: 'deleted',
  );

  @override
  Future<Uri?> resolvePlayback(String resourceId) => playback.future;
}

final class _DeferredPhotoAlbumRepository implements PhotoAlbumRepository {
  final Completer<List<V3PhotoAlbumEntry>> response =
      Completer<List<V3PhotoAlbumEntry>>();
  var loadCalls = 0;

  @override
  Future<List<V3PhotoAlbumEntry>> load() {
    loadCalls += 1;
    return response.future;
  }

  @override
  Future<V3PhotoAlbumImportResult> importPhotos(List<PickedMediaFile> files) =>
      throw UnimplementedError();

  @override
  Future<MediaResourceDeleteReceipt> deleteResource({
    required String resourceId,
    required String idempotencyKey,
  }) => throw UnimplementedError();

  @override
  Future<Uri?> resolvePlayback(String resourceId) async => null;
}

final class _CursorPhotoAlbumRepository
    implements PhotoAlbumRepository, PhotoAlbumContentSyncPort {
  _CursorPhotoAlbumRepository({
    required this.entries,
    required List<PhotoAlbumContentCursorResult> cursorResults,
    List<PhotoAlbumContentChangesResult> changeResults =
        const <PhotoAlbumContentChangesResult>[],
  }) : _cursorResults = List<PhotoAlbumContentCursorResult>.of(cursorResults),
       _changeResults = List<PhotoAlbumContentChangesResult>.of(changeResults);

  final List<V3PhotoAlbumEntry> entries;
  final List<PhotoAlbumContentCursorResult> _cursorResults;
  final List<PhotoAlbumContentChangesResult> _changeResults;
  final List<String> changeAfters = <String>[];
  var loadCalls = 0;
  var cursorCalls = 0;

  @override
  Future<List<V3PhotoAlbumEntry>> load() async {
    loadCalls += 1;
    return entries;
  }

  @override
  Future<PhotoAlbumContentCursorResult> currentContentCursor() async {
    cursorCalls += 1;
    if (_cursorResults.isEmpty) {
      return const PhotoAlbumContentCursorResult.failure(
        errorCode: 'CURSOR_RESULT_UNEXPECTED',
      );
    }
    return _cursorResults.removeAt(0);
  }

  @override
  Future<PhotoAlbumContentChangesResult> contentChanges({
    required String after,
    int? limit,
  }) async {
    changeAfters.add(after);
    if (_changeResults.isEmpty) {
      return const PhotoAlbumContentChangesResult.failure(
        errorCode: 'CHANGE_RESULT_UNEXPECTED',
      );
    }
    return _changeResults.removeAt(0);
  }

  @override
  Future<V3PhotoAlbumImportResult> importPhotos(List<PickedMediaFile> files) =>
      throw UnimplementedError();

  @override
  Future<MediaResourceDeleteReceipt> deleteResource({
    required String resourceId,
    required String idempotencyKey,
  }) => throw UnimplementedError();

  @override
  Future<Uri?> resolvePlayback(String resourceId) async => null;
}

final class _DeferredCursorPhotoAlbumRepository
    implements PhotoAlbumRepository, PhotoAlbumContentSyncPort {
  final cursor = Completer<PhotoAlbumContentCursorResult>();
  var loadCalls = 0;

  @override
  Future<List<V3PhotoAlbumEntry>> load() async {
    loadCalls += 1;
    return const <V3PhotoAlbumEntry>[];
  }

  @override
  Future<PhotoAlbumContentCursorResult> currentContentCursor() => cursor.future;

  @override
  Future<PhotoAlbumContentChangesResult> contentChanges({
    required String after,
    int? limit,
  }) => throw UnimplementedError();

  @override
  Future<V3PhotoAlbumImportResult> importPhotos(List<PickedMediaFile> files) =>
      throw UnimplementedError();

  @override
  Future<MediaResourceDeleteReceipt> deleteResource({
    required String resourceId,
    required String idempotencyKey,
  }) => throw UnimplementedError();

  @override
  Future<Uri?> resolvePlayback(String resourceId) async => null;
}

SharedWorkspaceContentEvent _contentEvent({
  required String objectKind,
  required String cursor,
}) => SharedWorkspaceContentEvent(
  eventId: 'event-$cursor-$objectKind',
  workspaceId: 'workspace-photo',
  cursor: cursor,
  operationId: 'operation-$cursor',
  occurredAt: DateTime.utc(2026, 8, 18),
  objectKind: objectKind,
  objectId: 'object-$cursor',
  changeType: 'created',
  tombstone: false,
  resourcePinDelta: const SharedWorkspaceResourcePinDelta(
    added: <String>[],
    released: <String>[],
  ),
);

V3PhotoAlbumEntry _cachedEntry() => V3PhotoAlbumEntry(
  id: 'visual-cached',
  resourceId: 'resource-cached',
  displayName: '缓存照片',
  role: 'gallery_photo',
  ordinal: 0,
  version: 1,
  etag:
      '"wcc-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"',
  playbackUrl: Uri.parse('https://media.example.test/resource-cached.png'),
);

V3PhotoAlbumEntry _cachedEntryWithoutPlayback() => const V3PhotoAlbumEntry(
  id: 'visual-cached',
  resourceId: 'resource-cached',
  displayName: '缓存照片',
  role: 'gallery_photo',
  ordinal: 0,
  version: 1,
  etag:
      '"wcc-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"',
);
