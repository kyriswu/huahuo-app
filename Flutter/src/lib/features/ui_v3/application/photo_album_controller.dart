// Public constructor labels describe injected runtime dependencies.
// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_preferences_dao.dart';
import '../../../core/native/native_file_port.dart';
import '../data/photo_album_repository.dart';
import '../domain/photo_album_models.dart';

// resident-provider: Shares one account-scoped photo album repository identity across dependent controllers.
final photoAlbumRepositoryProvider = Provider<PhotoAlbumRepository>(
  (ref) => const UnavailablePhotoAlbumRepository(),
);

// resident-provider: Shares one photo album native file port dependency for the full account session.
final photoAlbumNativeFilePortProvider = Provider<NativeFilePort>(
  (ref) => const UnavailableNativeFilePort(),
);

// resident-provider: Shares one account-scoped photo album metadata cache identity across dependent controllers.
/// Runtime bootstrap replaces this with an authenticated account/Workspace
/// cache. The default keeps isolated widget and controller tests lightweight.
final photoAlbumMetadataCacheProvider = Provider<PhotoAlbumMetadataCache?>(
  (ref) => null,
);

// resident-provider: Preserves the photo album controller state machine across route transitions.
final photoAlbumControllerProvider =
    ChangeNotifierProvider<PhotoAlbumController>((ref) {
      final repository = ref.watch(photoAlbumRepositoryProvider);
      final controller = PhotoAlbumController(
        nativeFilePort: ref.watch(photoAlbumNativeFilePortProvider),
        repository: repository,
        cache: ref.watch(photoAlbumMetadataCacheProvider),
        contentSync: repository is PhotoAlbumContentSyncPort
            ? repository as PhotoAlbumContentSyncPort
            : null,
      );
      controller.load();
      return controller;
    });

enum PhotoAlbumStatus { loading, ready, importing, failed }

@immutable
final class PhotoAlbumDeleteResult {
  const PhotoAlbumDeleteResult({required this.status});

  final String status;

  bool get isPendingCleanup => status == 'delete_pending';
}

/// Stores only durable public album metadata. Playback URLs are intentionally
/// excluded because they are short-lived owner-authorized credentials.
final class PhotoAlbumMetadataCache {
  PhotoAlbumMetadataCache({
    required AppPreferencesDao preferences,
    required String ownerScope,
  }) : _preferences = preferences,
       _preferenceKey = _keyFor(ownerScope);

  final AppPreferencesDao _preferences;
  final String _preferenceKey;

  PhotoAlbumMetadataSnapshot? restore() {
    final raw = _preferences.readValue(_preferenceKey);
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map ||
          (decoded['schemaVersion'] != 1 && decoded['schemaVersion'] != 2) ||
          decoded['savedAt'] is! String ||
          decoded['items'] is! List) {
        return null;
      }
      final savedAt = DateTime.tryParse(decoded['savedAt'] as String)?.toUtc();
      if (savedAt == null) return null;
      final rawContentCursor = decoded['contentCursor'];
      if (rawContentCursor != null && !_isContentCursor(rawContentCursor)) {
        return null;
      }
      final entries = <V3PhotoAlbumEntry>[];
      for (final rawEntry in decoded['items'] as List) {
        final entry = _entryFromCache(rawEntry);
        if (entry == null) return null;
        entries.add(entry);
      }
      return PhotoAlbumMetadataSnapshot(
        savedAt: savedAt,
        entries: List<V3PhotoAlbumEntry>.unmodifiable(entries),
        contentCursor: rawContentCursor as String?,
      );
    } on Object {
      return null;
    }
  }

  void save(
    List<V3PhotoAlbumEntry> entries, {
    required DateTime savedAt,
    String? contentCursor,
  }) {
    if (contentCursor != null && !_isContentCursor(contentCursor)) return;
    final values = <Map<String, Object?>>[];
    for (final entry in entries) {
      if (!_isCacheEntrySafe(entry)) return;
      values.add(<String, Object?>{
        'id': entry.id,
        'resourceId': entry.resourceId,
        'displayName': entry.displayName,
        'role': entry.role,
        'ordinal': entry.ordinal,
        'version': entry.version,
        'etag': entry.etag,
      });
    }
    try {
      _preferences.upsertValue(
        preferenceKey: _preferenceKey,
        value: jsonEncode(<String, Object?>{
          'schemaVersion': 2,
          'savedAt': savedAt.toUtc().toIso8601String(),
          if (contentCursor != null) 'contentCursor': contentCursor,
          'items': values,
        }),
        updatedAt: savedAt.toUtc().toIso8601String(),
      );
    } on Object {
      // A cache write must never turn a successful cloud read into an error.
    }
  }

  static String _keyFor(String ownerScope) {
    final digest = sha256
        .convert(
          utf8.encode(ownerScope.trim().isEmpty ? 'anonymous' : ownerScope),
        )
        .toString()
        .substring(0, 24);
    return 'photo.album.v1.$digest';
  }

  static V3PhotoAlbumEntry? _entryFromCache(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final resourceId = raw['resourceId'];
    final displayName = raw['displayName'];
    final role = raw['role'];
    final ordinal = raw['ordinal'];
    final version = raw['version'];
    final etag = raw['etag'];
    if (!_isIdentifier(id) ||
        !_isIdentifier(resourceId) ||
        !_isDisplayName(displayName) ||
        !_isIdentifier(role) ||
        ordinal is! int ||
        ordinal < 0 ||
        version is! int ||
        version < 1 ||
        !_isEtag(etag)) {
      return null;
    }
    return V3PhotoAlbumEntry(
      id: (id as String).trim(),
      resourceId: (resourceId as String).trim(),
      displayName: (displayName as String).trim(),
      role: (role as String).trim(),
      ordinal: ordinal,
      version: version,
      etag: (etag as String).trim(),
    );
  }

  static bool _isCacheEntrySafe(V3PhotoAlbumEntry entry) =>
      _isIdentifier(entry.id) &&
      _isIdentifier(entry.resourceId) &&
      _isDisplayName(entry.displayName) &&
      _isIdentifier(entry.role) &&
      entry.ordinal >= 0 &&
      entry.version >= 1 &&
      _isEtag(entry.etag);

  static bool _isIdentifier(Object? value) =>
      value is String &&
      RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,159}$').hasMatch(value.trim());

  static bool _isDisplayName(Object? value) =>
      value is String && value.trim().isNotEmpty && value.trim().length <= 120;

  static bool _isEtag(Object? value) =>
      value is String && RegExp(r'^"wcc-[a-f0-9]{64}"$').hasMatch(value.trim());

  static bool _isContentCursor(Object? value) =>
      value is String && RegExp(r'^(?:0|[1-9][0-9]*)$').hasMatch(value);
}

@immutable
final class PhotoAlbumMetadataSnapshot {
  const PhotoAlbumMetadataSnapshot({
    required this.savedAt,
    required this.entries,
    this.contentCursor,
  });

  final DateTime savedAt;
  final List<V3PhotoAlbumEntry> entries;
  final String? contentCursor;
}

final class PhotoAlbumController extends ChangeNotifier {
  PhotoAlbumController({
    required NativeFilePort nativeFilePort,
    required PhotoAlbumRepository repository,
    PhotoAlbumMetadataCache? cache,
    PhotoAlbumContentSyncPort? contentSync,
    DateTime Function()? now,
  }) : _nativeFilePort = nativeFilePort,
       _repository = repository,
       _cache = cache,
       _contentSync = contentSync,
       _now = now ?? DateTime.now;

  final NativeFilePort _nativeFilePort;
  final PhotoAlbumRepository _repository;
  final PhotoAlbumMetadataCache? _cache;
  final PhotoAlbumContentSyncPort? _contentSync;
  final DateTime Function() _now;
  PhotoAlbumStatus _status = PhotoAlbumStatus.loading;
  List<V3PhotoAlbumEntry> _entries = const <V3PhotoAlbumEntry>[];
  DateTime? _metadataUpdatedAt;
  String? _contentCursor;
  String? _errorCode;
  V3PhotoAlbumImportResult? _lastImport;
  final Map<String, String> _deleteIdempotencyKeys = <String, String>{};
  final Set<String> _deletingResourceIds = <String>{};
  final Set<String> _deletedResourceIds = <String>{};
  Future<void>? _remoteLoad;
  Future<void>? _baselineRemoteLoad;
  Future<void>? _contentReconciliation;
  int _contentReconciliationGeneration = 0;
  bool _pickerInFlight = false;
  bool _disposed = false;

  PhotoAlbumStatus get status => _status;
  List<V3PhotoAlbumEntry> get entries =>
      List<V3PhotoAlbumEntry>.unmodifiable(_entries);
  String? get errorCode => _errorCode;
  V3PhotoAlbumImportResult? get lastImport => _lastImport;
  bool get isDeleting => _deletingResourceIds.isNotEmpty;
  bool isDeletingResource(String resourceId) =>
      _deletingResourceIds.contains(resourceId.trim());

  Future<void> load({bool forceRemote = false}) {
    if (forceRemote) _contentReconciliationGeneration++;
    final cached = _cache?.restore();
    if (_entries.isEmpty && cached != null) {
      _entries = cached.entries;
      _metadataUpdatedAt = cached.savedAt;
      _contentCursor = cached.contentCursor;
      _status = PhotoAlbumStatus.ready;
      _errorCode = null;
      notifyListeners();
      if (!forceRemote) return _reconcileCachedMetadata();
    } else if (_entries.isNotEmpty && !forceRemote) {
      return _reconcileCachedMetadata();
    }
    return _loadRemoteWithBaseline();
  }

  Future<void> _reconcileCachedMetadata() {
    if (_entries.isEmpty || _contentSync == null) {
      return Future<void>.value();
    }
    final active = _contentReconciliation;
    if (active != null) return active;
    final generation = _contentReconciliationGeneration;
    late final Future<void> operation;
    operation = _reconcileCachedMetadataOnce(generation).whenComplete(() {
      if (identical(_contentReconciliation, operation)) {
        _contentReconciliation = null;
      }
    });
    _contentReconciliation = operation;
    return operation;
  }

  Future<void> _reconcileCachedMetadataOnce(int generation) async {
    try {
      final sync = _contentSync;
      if (sync == null || !_isCurrentContentReconciliation(generation)) {
        return;
      }
      final localCursor = _contentCursor;
      if (localCursor == null) {
        final baseline = await _readContentCursor(sync);
        if (baseline == null || !_isCurrentContentReconciliation(generation)) {
          return;
        }
        await _startRemoteLoad(contentCursor: baseline);
        return;
      }

      final current = await sync.currentContentCursor();
      if (!_isCurrentContentReconciliation(generation) || !current.ok) return;
      final remoteCursor = current.contentCursor;
      if (!_isContentCursor(remoteCursor) || remoteCursor == localCursor) {
        return;
      }

      var after = localCursor;
      final observedAfters = <String>{after};
      var hasVisualAssetChange = false;
      while (true) {
        final changes = await sync.contentChanges(after: after, limit: 100);
        if (!_isCurrentContentReconciliation(generation)) return;
        if (!changes.ok) {
          if (changes.errorCode == 'CONTENT_CURSOR_EXPIRED') {
            final baseline = await _readContentCursor(sync);
            if (baseline != null &&
                _isCurrentContentReconciliation(generation)) {
              await _startRemoteLoad(contentCursor: baseline);
            }
          }
          return;
        }
        final nextAfter = changes.nextAfter;
        if (!_isContentCursor(nextAfter) || !observedAfters.add(nextAfter!)) {
          return;
        }
        hasVisualAssetChange =
            hasVisualAssetChange ||
            changes.events.any(
              (event) => event.objectKind == 'profile_visual_asset',
            );
        after = nextAfter;
        if (!changes.hasMore) break;
      }

      if (hasVisualAssetChange) {
        await _startRemoteLoad(contentCursor: after);
        return;
      }
      _advanceContentCursor(after);
    } on Object {
      // A failed optimization must not turn a usable local album into an
      // error state or surface an unhandled Future from provider creation.
    }
  }

  Future<void> _loadRemoteWithBaseline() {
    final active = _baselineRemoteLoad;
    if (active != null) return active;
    if (_contentSync == null) return _startRemoteLoad();
    late final Future<void> operation;
    operation = _loadRemoteWithBaselineOnce().whenComplete(() {
      if (identical(_baselineRemoteLoad, operation)) {
        _baselineRemoteLoad = null;
      }
    });
    _baselineRemoteLoad = operation;
    return operation;
  }

  Future<void> _loadRemoteWithBaselineOnce() async {
    final baseline = await _readContentCursor(_contentSync);
    await _startRemoteLoad(contentCursor: baseline);
  }

  Future<String?> _readContentCursor(PhotoAlbumContentSyncPort? sync) async {
    if (sync == null) return null;
    try {
      final result = await sync.currentContentCursor();
      final cursor = result.contentCursor;
      return result.ok && _isContentCursor(cursor) ? cursor : null;
    } on Object {
      return null;
    }
  }

  bool _isCurrentContentReconciliation(int generation) =>
      !_disposed && generation == _contentReconciliationGeneration;

  Future<void> _startRemoteLoad({String? contentCursor}) {
    if (_disposed) return Future<void>.value();
    final activeRemoteLoad = _remoteLoad;
    if (activeRemoteLoad != null) return activeRemoteLoad;

    final completion = Completer<void>();
    _remoteLoad = completion.future;
    if (_entries.isEmpty) {
      _status = PhotoAlbumStatus.loading;
    }
    _errorCode = null;
    notifyListeners();

    unawaited(_loadRemote(completion, contentCursor: contentCursor));
    return completion.future;
  }

  Future<void> _loadRemote(
    Completer<void> completion, {
    String? contentCursor,
  }) async {
    try {
      final entries = await _repository.load();
      if (_disposed) return;
      _setEntries(entries, contentCursor: contentCursor);
      _status = PhotoAlbumStatus.ready;
    } on PhotoAlbumException catch (error) {
      _errorCode = error.code;
      _status = _entries.isEmpty
          ? PhotoAlbumStatus.failed
          : PhotoAlbumStatus.ready;
    } on Object {
      _errorCode = 'PHOTO_ALBUM_LOAD_FAILED';
      _status = _entries.isEmpty
          ? PhotoAlbumStatus.failed
          : PhotoAlbumStatus.ready;
    } finally {
      if (!_disposed) notifyListeners();
      if (identical(_remoteLoad, completion.future)) {
        _remoteLoad = null;
      }
      if (!completion.isCompleted) completion.complete();
    }
  }

  Future<V3PhotoAlbumImportResult?> pickAndImport() async {
    if (_pickerInFlight || _status == PhotoAlbumStatus.importing) return null;
    _pickerInFlight = true;
    late final NativeFileResult<List<PickedMediaFile>> picked;
    try {
      picked = await _nativeFilePort.pickMediaFiles(
        kind: NativeMediaKind.image,
        source: NativeMediaSource.gallery,
      );
    } on Object {
      if (!_disposed) {
        _status = PhotoAlbumStatus.failed;
        _errorCode = 'PHOTO_ALBUM_PICK_FAILED';
        notifyListeners();
      }
      return null;
    } finally {
      _pickerInFlight = false;
    }
    if (_disposed) return null;
    final files = picked.value;
    if (!picked.ok || files == null) {
      _status = PhotoAlbumStatus.ready;
      _errorCode =
          picked.cancelled || picked.error?.code == 'MEDIA_PICKER_CANCELLED'
          ? null
          : picked.error?.code ?? 'PHOTO_ALBUM_PICK_FAILED';
      notifyListeners();
      return null;
    }
    if (files.isEmpty || files.length > 9) {
      _status = PhotoAlbumStatus.failed;
      _errorCode = 'PHOTO_ALBUM_SELECTION_COUNT_INVALID';
      notifyListeners();
      return null;
    }
    _contentReconciliationGeneration++;
    _status = PhotoAlbumStatus.importing;
    _errorCode = null;
    _lastImport = null;
    notifyListeners();
    try {
      final result = await _repository.importPhotos(files);
      _setEntries(result.entries);
      _lastImport = result;
      _status = PhotoAlbumStatus.ready;
      notifyListeners();
      return result;
    } on PhotoAlbumException catch (error) {
      _status = PhotoAlbumStatus.failed;
      _errorCode = error.code;
    } on Object {
      _status = PhotoAlbumStatus.failed;
      _errorCode = 'PHOTO_ALBUM_IMPORT_FAILED';
    }
    notifyListeners();
    return null;
  }

  Future<PhotoAlbumDeleteResult?> deleteResource(String resourceId) async {
    final normalizedResourceId = resourceId.trim();
    if (normalizedResourceId.isEmpty ||
        !_entries.any((entry) => entry.resourceId == normalizedResourceId)) {
      _errorCode = 'PHOTO_ALBUM_RESOURCE_INVALID';
      notifyListeners();
      return null;
    }
    if (_deletingResourceIds.contains(normalizedResourceId)) return null;
    _contentReconciliationGeneration++;
    final idempotencyKey = _deleteIdempotencyKeys.putIfAbsent(
      normalizedResourceId,
      () => _deleteIdempotencyKey(normalizedResourceId),
    );
    _deletingResourceIds.add(normalizedResourceId);
    _errorCode = null;
    notifyListeners();
    try {
      final receipt = await _repository.deleteResource(
        resourceId: normalizedResourceId,
        idempotencyKey: idempotencyKey,
      );
      if (_disposed) return null;
      if (receipt.status != 'deleted' && receipt.status != 'delete_pending') {
        throw const PhotoAlbumException('PHOTO_ALBUM_RESOURCE_DELETE_INVALID');
      }
      _deletedResourceIds.add(normalizedResourceId);
      _entries = List<V3PhotoAlbumEntry>.unmodifiable(
        _entries.where((entry) => entry.resourceId != normalizedResourceId),
      );
      _metadataUpdatedAt = _now().toUtc();
      _saveMetadata();
      _deleteIdempotencyKeys.remove(normalizedResourceId);
      return PhotoAlbumDeleteResult(status: receipt.status);
    } on PhotoAlbumException catch (error) {
      if (!_disposed) _errorCode = error.code;
    } on Object {
      if (!_disposed) _errorCode = 'PHOTO_ALBUM_RESOURCE_DELETE_FAILED';
    } finally {
      _deletingResourceIds.remove(normalizedResourceId);
      if (!_disposed) notifyListeners();
    }
    return null;
  }

  String _deleteIdempotencyKey(String resourceId) {
    final safeResource = resourceId.replaceAll(RegExp(r'[^A-Za-z0-9]'), '_');
    return 'photo-resource-delete-$safeResource-${_now().toUtc().microsecondsSinceEpoch}';
  }

  void _setEntries(List<V3PhotoAlbumEntry> entries, {String? contentCursor}) {
    final activeEntries = entries
        .where((entry) => !_deletedResourceIds.contains(entry.resourceId))
        .toList(growable: false);
    _entries = List<V3PhotoAlbumEntry>.unmodifiable(
      activeEntries.map(
        (entry) => V3PhotoAlbumEntry(
          id: entry.id,
          resourceId: entry.resourceId,
          displayName: entry.displayName,
          role: entry.role,
          ordinal: entry.ordinal,
          version: entry.version,
          etag: entry.etag,
        ),
      ),
    );
    _metadataUpdatedAt = _now().toUtc();
    if (_isContentCursor(contentCursor)) _contentCursor = contentCursor;
    _saveMetadata();
  }

  void _advanceContentCursor(String contentCursor) {
    if (!_isContentCursor(contentCursor)) return;
    _contentCursor = contentCursor;
    _metadataUpdatedAt ??= _now().toUtc();
    _saveMetadata();
  }

  void _saveMetadata() {
    final savedAt = _metadataUpdatedAt;
    if (savedAt == null) return;
    _cache?.save(_entries, savedAt: savedAt, contentCursor: _contentCursor);
  }

  @override
  void dispose() {
    _disposed = true;
    _contentReconciliationGeneration++;
    super.dispose();
  }
}

bool _isContentCursor(String? value) =>
    value != null && RegExp(r'^(?:0|[1-9][0-9]*)$').hasMatch(value);
