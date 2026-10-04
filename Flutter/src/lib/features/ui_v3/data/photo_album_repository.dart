import 'dart:async';
import 'dart:io';

import 'package:huahuo_api/huahuo_api.dart';
import 'package:crypto/crypto.dart';

import '../../../core/native/native_file_port.dart';
import '../domain/photo_album_models.dart';

abstract interface class PhotoAlbumRepository {
  Future<List<V3PhotoAlbumEntry>> load();

  /// Resolves a short-lived playback URL for a known cloud Resource. Callers
  /// must keep the result in memory only.
  Future<Uri?> resolvePlayback(String resourceId);

  Future<V3PhotoAlbumImportResult> importPhotos(List<PickedMediaFile> files);

  Future<MediaResourceDeleteReceipt> deleteResource({
    required String resourceId,
    required String idempotencyKey,
  });
}

/// Optional remote content-version capability for an album repository.
///
/// Kept separate from [PhotoAlbumRepository] so local and unavailable
/// repositories do not need to fabricate Workspace synchronization state.
abstract interface class PhotoAlbumContentSyncPort {
  /// Reads the current Workspace content cursor without loading album rows.
  Future<PhotoAlbumContentCursorResult> currentContentCursor();

  /// Reads one ordered page after [after]. Callers continue with [nextAfter]
  /// while [PhotoAlbumContentChangesResult.hasMore] is true.
  Future<PhotoAlbumContentChangesResult> contentChanges({
    required String after,
    int? limit,
  });
}

/// Normalized result for a low-cost Workspace content-cursor read.
final class PhotoAlbumContentCursorResult {
  const PhotoAlbumContentCursorResult.success(this.contentCursor)
    : errorCode = null,
      status = null,
      retryable = false;

  const PhotoAlbumContentCursorResult.failure({
    required this.errorCode,
    this.status,
    this.retryable = false,
  }) : contentCursor = null;

  final String? contentCursor;
  final String? errorCode;
  final int? status;
  final bool retryable;

  bool get ok => contentCursor != null && errorCode == null;
}

/// Normalized paginated Workspace change-feed result for album reconciliation.
final class PhotoAlbumContentChangesResult {
  const PhotoAlbumContentChangesResult.success({
    required this.events,
    required this.nextAfter,
    required this.hasMore,
  }) : errorCode = null,
       status = null,
       retryable = false;

  const PhotoAlbumContentChangesResult.failure({
    required this.errorCode,
    this.status,
    this.retryable = false,
  }) : events = const <SharedWorkspaceContentEvent>[],
       nextAfter = null,
       hasMore = false;

  final List<SharedWorkspaceContentEvent> events;
  final String? nextAfter;
  final bool hasMore;
  final String? errorCode;
  final int? status;
  final bool retryable;

  bool get ok => nextAfter != null && errorCode == null;
}

/// Canonical cloud album backed by Profile Visual Assets. The selected local
/// file is used only while streaming bytes to the server-signed upload URL.
final class RemotePhotoAlbumRepository
    implements PhotoAlbumRepository, PhotoAlbumContentSyncPort {
  RemotePhotoAlbumRepository({
    required ApiClient apiClient,
    required String? Function() workspaceId,
    ObjectUploadTransport? objectUploadTransport,
    WorkspaceLifecycleClient? workspaceLifecycleClient,
    WorkspaceContentClient? workspaceContentClient,
  }) : _apiClient = apiClient,
       _workspaceId = workspaceId,
       _objectUploadTransport = objectUploadTransport,
       _workspaceLifecycleClient =
           workspaceLifecycleClient ?? WorkspaceLifecycleClient(apiClient),
       _workspaceContentClient =
           workspaceContentClient ?? WorkspaceContentClient(apiClient);

  static const _maximumSelectionCount = 9;
  static const _maximumPhotoBytes = 50 * 1024 * 1024;
  static const _maximumContentChangePageSize = 500;
  static const _role = 'gallery_photo';
  static final _contentCursorPattern = RegExp(r'^(?:0|[1-9][0-9]*)$');

  static const _mimeByExtension = <String, String>{
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'png': 'image/png',
    'webp': 'image/webp',
  };

  final ApiClient _apiClient;
  final String? Function() _workspaceId;
  final ObjectUploadTransport? _objectUploadTransport;
  final WorkspaceLifecycleClient _workspaceLifecycleClient;
  final WorkspaceContentClient _workspaceContentClient;

  @override
  Future<List<V3PhotoAlbumEntry>> load() async {
    final workspaceId = _requireWorkspaceId();
    final result = await _apiClient.request<List<_VisualAssetRecord>>(
      ApiRequestOptions<List<_VisualAssetRecord>>(
        endpointId: 'workspaceProfileVisualAssets',
        pathParams: <String, Object>{'workspaceId': workspaceId},
        parseData: _parseVisualAssetList,
      ),
    );
    final assets = result.data;
    if (!result.ok || assets == null) {
      throw PhotoAlbumException(
        result.error?.code ?? 'PHOTO_ALBUM_REMOTE_LOAD_FAILED',
      );
    }
    return List<V3PhotoAlbumEntry>.unmodifiable(
      assets.map(_entryFromVisualAsset),
    );
  }

  @override
  Future<PhotoAlbumContentCursorResult> currentContentCursor() async {
    final workspaceId = _activeWorkspaceId();
    if (workspaceId == null) {
      return const PhotoAlbumContentCursorResult.failure(
        errorCode: 'PHOTO_ALBUM_WORKSPACE_UNAVAILABLE',
      );
    }
    try {
      final response = await _workspaceLifecycleClient.detail(workspaceId);
      final cursor = response.data?.contentCursor;
      if (response.ok && _isCanonicalContentCursor(cursor)) {
        return PhotoAlbumContentCursorResult.success(cursor!);
      }
      return PhotoAlbumContentCursorResult.failure(
        errorCode: response.error?.code ?? 'PHOTO_ALBUM_CONTENT_CURSOR_INVALID',
        status: response.status,
        retryable: response.error?.isRetryable ?? false,
      );
    } on Object {
      return const PhotoAlbumContentCursorResult.failure(
        errorCode: 'PHOTO_ALBUM_CONTENT_CURSOR_FAILED',
      );
    }
  }

  @override
  Future<PhotoAlbumContentChangesResult> contentChanges({
    required String after,
    int? limit,
  }) async {
    if (!_isCanonicalContentCursor(after)) {
      return const PhotoAlbumContentChangesResult.failure(
        errorCode: 'PHOTO_ALBUM_CONTENT_CURSOR_INVALID',
      );
    }
    if (limit != null && (limit < 1 || limit > _maximumContentChangePageSize)) {
      return const PhotoAlbumContentChangesResult.failure(
        errorCode: 'PHOTO_ALBUM_CONTENT_CHANGE_LIMIT_INVALID',
      );
    }
    final workspaceId = _activeWorkspaceId();
    if (workspaceId == null) {
      return const PhotoAlbumContentChangesResult.failure(
        errorCode: 'PHOTO_ALBUM_WORKSPACE_UNAVAILABLE',
      );
    }
    try {
      final response = await _workspaceContentClient.changes(
        workspaceId,
        after: after,
        limit: limit,
      );
      final page = response.data;
      if (response.ok && page != null) {
        return PhotoAlbumContentChangesResult.success(
          events: List<SharedWorkspaceContentEvent>.unmodifiable(page.events),
          nextAfter: page.nextAfter,
          hasMore: page.hasMore,
        );
      }
      return PhotoAlbumContentChangesResult.failure(
        errorCode: response.error?.code ?? 'PHOTO_ALBUM_CONTENT_CHANGES_FAILED',
        status: response.status,
        retryable: response.error?.isRetryable ?? false,
      );
    } on Object {
      return const PhotoAlbumContentChangesResult.failure(
        errorCode: 'PHOTO_ALBUM_CONTENT_CHANGES_FAILED',
      );
    }
  }

  @override
  Future<Uri?> resolvePlayback(String resourceId) async {
    final normalizedResourceId = resourceId.trim();
    if (!_isSafeIdentifier(normalizedResourceId)) {
      throw const PhotoAlbumException('PHOTO_ALBUM_RESOURCE_INVALID');
    }
    try {
      final playback = await _apiClient.request<Uri>(
        ApiRequestOptions<Uri>(
          endpointId: 'mediaResourcePlayback',
          pathParams: <String, Object>{'resourceId': normalizedResourceId},
          parseData: _parsePlaybackUrl,
        ),
      );
      return playback.ok ? playback.data : null;
    } on Object {
      return null;
    }
  }

  @override
  Future<V3PhotoAlbumImportResult> importPhotos(
    List<PickedMediaFile> files,
  ) async {
    if (files.isEmpty || files.length > _maximumSelectionCount) {
      throw const PhotoAlbumException('PHOTO_ALBUM_SELECTION_COUNT_INVALID');
    }
    final workspaceId = _requireWorkspaceId();
    final currentEntries = await load();
    var nextOrdinal =
        currentEntries.fold<int>(
          -1,
          (highest, entry) => entry.ordinal > highest ? entry.ordinal : highest,
        ) +
        1;
    final selectedDigests = <String>{};
    final preparedPhotos = <_PreparedPhoto>[];
    var importedCount = 0;
    var duplicateCount = 0;

    for (final picked in files) {
      final prepared = await _preparePhoto(picked);
      if (!selectedDigests.add(prepared.sha256Digest)) {
        duplicateCount++;
        continue;
      }
      preparedPhotos.add(prepared);
    }

    for (final prepared in preparedPhotos) {
      await _uploadAndBind(
        workspaceId: workspaceId,
        photo: prepared,
        ordinal: nextOrdinal,
      );
      importedCount++;
      nextOrdinal++;
    }

    final entries = await load();
    return V3PhotoAlbumImportResult(
      entries: entries,
      importedCount: importedCount,
      duplicateCount: duplicateCount,
    );
  }

  @override
  Future<MediaResourceDeleteReceipt> deleteResource({
    required String resourceId,
    required String idempotencyKey,
  }) async {
    final result = await MediaResourceClient(_apiClient).delete(
      workspaceId: _requireWorkspaceId(),
      resourceId: resourceId,
      idempotencyKey: idempotencyKey,
    );
    final receipt = result.data;
    if (!result.ok || receipt == null) {
      throw PhotoAlbumException(
        result.error?.code ?? 'PHOTO_ALBUM_RESOURCE_DELETE_FAILED',
      );
    }
    return receipt;
  }

  Future<void> _uploadAndBind({
    required String workspaceId,
    required _PreparedPhoto photo,
    required int ordinal,
  }) async {
    final uploadReference =
        'app-private://photo-album/${photo.sha256Digest}.${photo.extension}';
    final metadata = UploadMetadata(
      sourceScene: 'workspace_attachment',
      fileName: photo.fileName,
      mimeType: photo.mimeType,
      sizeBytes: photo.sizeBytes,
      durationSeconds: 0,
      appPrivateUri: uploadReference,
      sha256: photo.sha256Digest,
      workspaceId: workspaceId,
    );
    final uploader = UploadClient(
      apiClient: _apiClient,
      objectTransport:
          _objectUploadTransport ??
          HttpObjectUploadTransport(
            openRead: (uri) {
              if (uri != uploadReference) {
                return Stream<List<int>>.error(
                  StateError('PHOTO_UPLOAD_PRIVATE_REF_INVALID'),
                );
              }
              return photo.file.openRead();
            },
          ),
    );
    final suffix = photo.sha256Digest;
    final tokenResult = await uploader.requestUploadToken(
      metadata: metadata,
      idempotencyKey: 'photo-upload-token-$suffix',
    );
    final token = tokenResult.value;
    if (!tokenResult.ok || token == null) {
      throw PhotoAlbumException(
        tokenResult.error?.code ?? 'PHOTO_UPLOAD_TOKEN_FAILED',
      );
    }
    final uploadResult = await uploader.uploadToObjectStore(
      token: token,
      metadata: metadata,
    );
    if (!uploadResult.ok) {
      throw PhotoAlbumException(
        uploadResult.error?.code ?? 'PHOTO_UPLOAD_OBJECT_FAILED',
      );
    }
    final completeResult = await uploader.completeUpload(
      uploadId: token.uploadId,
      metadata: metadata,
      idempotencyKey: 'photo-upload-complete-$suffix',
    );
    final resource = completeResult.value;
    if (!completeResult.ok || resource == null) {
      throw PhotoAlbumException(
        completeResult.error?.code ?? 'PHOTO_UPLOAD_COMPLETE_FAILED',
      );
    }

    final bindResult = await _apiClient.request<Map<String, Object?>>(
      ApiRequestOptions<Map<String, Object?>>(
        endpointId: 'createWorkspaceProfileVisualAsset',
        pathParams: <String, Object>{'workspaceId': workspaceId},
        body: <String, Object?>{
          'resourceId': resource.resourceId,
          'role': _role,
          'caption': photo.fileName,
          'ordinal': ordinal,
        },
        idempotency: IdempotencyRequestContext(
          explicitKey: 'photo-visual-asset-create-$suffix',
        ),
        parseData: _parseMutationReceipt,
      ),
    );
    if (!bindResult.ok || bindResult.data == null) {
      throw PhotoAlbumException(
        bindResult.error?.code ?? 'PHOTO_VISUAL_ASSET_BIND_FAILED',
      );
    }
  }

  V3PhotoAlbumEntry _entryFromVisualAsset(_VisualAssetRecord asset) {
    return V3PhotoAlbumEntry(
      id: asset.visualAssetId,
      resourceId: asset.resourceId,
      displayName: asset.caption ?? '未命名照片',
      role: asset.role,
      ordinal: asset.ordinal,
      version: asset.version,
      etag: asset.etag,
    );
  }

  Future<_PreparedPhoto> _preparePhoto(PickedMediaFile picked) async {
    final sourcePath = picked.sourcePath?.trim();
    final extension = picked.fileExtension;
    final mimeType = _mimeByExtension[extension];
    if (picked.kind != NativeMediaKind.image ||
        picked.source != NativeMediaSource.gallery ||
        sourcePath == null ||
        sourcePath.isEmpty ||
        mimeType == null ||
        picked.sizeBytes <= 0 ||
        picked.sizeBytes > _maximumPhotoBytes) {
      throw const PhotoAlbumException('PHOTO_ALBUM_FILE_UNSUPPORTED');
    }
    final file = File(sourcePath);
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
            FileSystemEntityType.file ||
        await file.length() != picked.sizeBytes) {
      throw const PhotoAlbumException('PHOTO_ALBUM_SOURCE_UNAVAILABLE');
    }
    final digest = await sha256.bind(file.openRead()).first;
    final fileName = _safeFileName(picked.displayName, extension);
    return _PreparedPhoto(
      file: file,
      extension: extension,
      fileName: fileName,
      mimeType: mimeType,
      sizeBytes: picked.sizeBytes,
      sha256Digest: digest.toString(),
    );
  }

  String? _activeWorkspaceId() {
    final value = _workspaceId()?.trim();
    return value == null || !_isSafeIdentifier(value) ? null : value;
  }

  String _requireWorkspaceId() {
    return _activeWorkspaceId() ??
        (throw const PhotoAlbumException('PHOTO_ALBUM_WORKSPACE_UNAVAILABLE'));
  }

  static bool _isCanonicalContentCursor(String? value) =>
      value != null && _contentCursorPattern.hasMatch(value);
}

List<_VisualAssetRecord>? _parseVisualAssetList(Object? value) {
  final root = asObjectMap(value);
  final rawItems = root?['items'];
  if (root == null || rawItems is! List) return null;
  final items = <_VisualAssetRecord>[];
  for (final raw in rawItems) {
    final item = asObjectMap(raw);
    final visualAssetId = _safeText(item?['visualAssetId']);
    final resourceId = _safeText(item?['resourceId']);
    final role = _safeText(item?['role']);
    final ordinal = item?['ordinal'];
    final version = item?['version'];
    final etag = _safeEtag(item?['etag']);
    final lifecycle = _safeText(item?['lifecycle']);
    final caption = _optionalText(item?['caption'], maximum: 120);
    if (visualAssetId == null ||
        resourceId == null ||
        role == null ||
        ordinal is! int ||
        ordinal < 0 ||
        version is! int ||
        version < 1 ||
        etag == null ||
        lifecycle != 'active') {
      return null;
    }
    items.add(
      _VisualAssetRecord(
        visualAssetId: visualAssetId,
        resourceId: resourceId,
        role: role,
        caption: caption,
        ordinal: ordinal,
        version: version,
        etag: etag,
      ),
    );
  }
  items.sort((left, right) {
    final byOrdinal = left.ordinal.compareTo(right.ordinal);
    return byOrdinal != 0
        ? byOrdinal
        : left.visualAssetId.compareTo(right.visualAssetId);
  });
  return List<_VisualAssetRecord>.unmodifiable(items);
}

Uri? _parsePlaybackUrl(Object? value) {
  final root = asObjectMap(value);
  final rawUrl = root?['url'];
  if (rawUrl is! String || rawUrl.trim().isEmpty) return null;
  final url = Uri.tryParse(rawUrl.trim());
  if (url == null ||
      !url.hasScheme ||
      url.host.isEmpty ||
      (url.scheme != 'https' && url.scheme != 'http')) {
    return null;
  }
  return url;
}

Map<String, Object?>? _parseMutationReceipt(Object? value) {
  final root = asObjectMap(value);
  return root == null ? null : Map<String, Object?>.unmodifiable(root);
}

String? _safeText(Object? value, {int maximum = 160}) {
  if (value is! String) return null;
  final text = value.trim();
  return text.isNotEmpty && text.length <= maximum && _isSafeIdentifier(text)
      ? text
      : null;
}

String? _optionalText(Object? value, {required int maximum}) {
  if (value == null) return null;
  if (value is! String) return null;
  final text = value.trim();
  return text.isEmpty || text.length > maximum ? null : text;
}

String? _safeEtag(Object? value) {
  if (value is! String) return null;
  final text = value.trim();
  return RegExp(r'^"wcc-[a-f0-9]{64}"$').hasMatch(text) ? text : null;
}

bool _isSafeIdentifier(String value) =>
    RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,159}$').hasMatch(value);

String _safeFileName(String value, String extension) {
  final trimmed = value.trim();
  final fallback = 'photo.$extension';
  if (trimmed.isEmpty ||
      trimmed.length > 120 ||
      trimmed.contains('/') ||
      trimmed.contains('\\') ||
      trimmed.endsWith('.part')) {
    return fallback;
  }
  return trimmed;
}

final class _PreparedPhoto {
  const _PreparedPhoto({
    required this.file,
    required this.extension,
    required this.fileName,
    required this.mimeType,
    required this.sizeBytes,
    required this.sha256Digest,
  });

  final File file;
  final String extension;
  final String fileName;
  final String mimeType;
  final int sizeBytes;
  final String sha256Digest;
}

final class _VisualAssetRecord {
  const _VisualAssetRecord({
    required this.visualAssetId,
    required this.resourceId,
    required this.role,
    required this.caption,
    required this.ordinal,
    required this.version,
    required this.etag,
  });

  final String visualAssetId;
  final String resourceId;
  final String role;
  final String? caption;
  final int ordinal;
  final int version;
  final String etag;
}

final class PhotoAlbumException implements Exception {
  const PhotoAlbumException(this.code);

  final String code;
}

final class UnavailablePhotoAlbumRepository implements PhotoAlbumRepository {
  const UnavailablePhotoAlbumRepository();

  @override
  Future<V3PhotoAlbumImportResult> importPhotos(List<PickedMediaFile> files) =>
      Future<V3PhotoAlbumImportResult>.error(
        const PhotoAlbumException('PHOTO_ALBUM_REPOSITORY_UNAVAILABLE'),
      );

  @override
  Future<MediaResourceDeleteReceipt> deleteResource({
    required String resourceId,
    required String idempotencyKey,
  }) => Future<MediaResourceDeleteReceipt>.error(
    const PhotoAlbumException('PHOTO_ALBUM_REPOSITORY_UNAVAILABLE'),
  );

  @override
  Future<List<V3PhotoAlbumEntry>> load() =>
      Future<List<V3PhotoAlbumEntry>>.error(
        const PhotoAlbumException('PHOTO_ALBUM_REPOSITORY_UNAVAILABLE'),
      );

  @override
  Future<Uri?> resolvePlayback(String resourceId) => Future<Uri?>.error(
    const PhotoAlbumException('PHOTO_ALBUM_REPOSITORY_UNAVAILABLE'),
  );
}
