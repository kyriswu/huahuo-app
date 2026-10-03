import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../database/app_preferences_dao.dart';
import 'app_cache_policy.dart';

final class ScopedReadCacheEntry {
  const ScopedReadCacheEntry({
    required this.etag,
    required this.payload,
    required this.savedAt,
  });

  final String? etag;
  final Map<String, Object?> payload;
  final DateTime savedAt;

  bool isUsableFallback({required Duration ttl, required DateTime now}) {
    if (ttl <= Duration.zero) return false;
    final age = now.toUtc().difference(savedAt);
    return age >= Duration.zero && age <= ttl;
  }
}

/// Small platform-owned cache for parsed public GET projections.
///
/// Values are isolated by an opaque user/workspace digest. Credentials, raw
/// request bodies, signed URLs, and response headers other than ETag never
/// enter this store.
final class ScopedReadCache {
  ScopedReadCache({
    required AppPreferencesDao dao,
    required String userScope,
    required String workspaceScope,
    Duration? fallbackTtl,
    DateTime Function()? now,
  }) : // Public parameter names intentionally differ from private storage.
       // ignore: prefer_initializing_formals
       _dao = dao,
       _scope = _scopeDigest(userScope, workspaceScope),
       fallbackTtl = _validatedTtl(fallbackTtl),
       _now = now ?? DateTime.now;

  final AppPreferencesDao _dao;
  final String _scope;
  final Duration fallbackTtl;
  final DateTime Function() _now;

  ScopedReadCacheEntry? read(String endpointId, String resourceKey) {
    final encoded = _dao.readValue(_key(endpointId, resourceKey));
    if (encoded == null) return null;
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is! Map ||
          decoded['version'] != 1 ||
          decoded['payload'] is! Map) {
        return null;
      }
      final savedAt = decoded['savedAt'] is String
          ? DateTime.tryParse(decoded['savedAt'] as String)?.toUtc()
          : null;
      if (savedAt == null) return null;
      final etag = decoded['etag'];
      if (etag != null && etag is! String) return null;
      return ScopedReadCacheEntry(
        etag: etag as String?,
        payload: Map<String, Object?>.from(decoded['payload'] as Map),
        savedAt: savedAt,
      );
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  /// Returns a verified projection only while its policy-defined fallback
  /// window remains valid. Callers should still issue a conditional read.
  ScopedReadCacheEntry? readFallback(String endpointId, String resourceKey) {
    final entry = read(endpointId, resourceKey);
    if (entry == null ||
        !entry.isUsableFallback(ttl: fallbackTtl, now: _now())) {
      return null;
    }
    return entry;
  }

  void write(
    String endpointId,
    String resourceKey, {
    required String? etag,
    required Map<String, Object?> payload,
  }) {
    final key = _key(endpointId, resourceKey);
    _upsertPreference(
      preferenceKey: key,
      value: jsonEncode(<String, Object?>{
        'version': 1,
        if (etag != null && etag.trim().isNotEmpty) 'etag': etag.trim(),
        'payload': payload,
        'savedAt': _now().toUtc().toIso8601String(),
      }),
      updatedAt: _now().toUtc().toIso8601String(),
    );
    final index = _readIndex();
    if (index.add(key)) {
      _writeIndex(index);
    }
  }

  void invalidate(String endpointId, String resourceKey) {
    final key = _key(endpointId, resourceKey);
    _deletePreference(key);
    final index = _readIndex();
    if (index.remove(key)) {
      _writeIndex(index);
    }
  }

  /// Clears only this opaque account/workspace scope on logout or switch.
  void clearScope() {
    for (final key in _readIndex()) {
      _deletePreference(key);
    }
    _deletePreference(_indexKey);
  }

  String _key(String endpointId, String resourceKey) {
    final endpoint = endpointId.trim();
    final resource = resourceKey.trim();
    if (!RegExp(r'^[A-Za-z][A-Za-z0-9_-]{0,127}$').hasMatch(endpoint) ||
        resource.isEmpty ||
        resource.length > 512) {
      throw ArgumentError('Scoped cache key is invalid');
    }
    final digest = sha256
        .convert(utf8.encode('$endpoint\n$resource'))
        .toString();
    return 'read-cache.v1.$_scope.${digest.substring(0, 32)}';
  }

  String get _indexKey => 'read-cache.v1.$_scope.index';

  Set<String> _readIndex() {
    final encoded = _dao.readValue(_indexKey);
    if (encoded == null) return <String>{};
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is! List || decoded.length > 256) return <String>{};
      return <String>{
        for (final value in decoded)
          if (value is String && value.startsWith('read-cache.v1.$_scope.'))
            value,
      };
    } on FormatException {
      return <String>{};
    }
  }

  void _writeIndex(Set<String> index) {
    if (index.isEmpty) {
      _deletePreference(_indexKey);
      return;
    }
    _upsertPreference(
      preferenceKey: _indexKey,
      value: jsonEncode(index.toList(growable: false)),
      updatedAt: _now().toUtc().toIso8601String(),
    );
  }

  void _upsertPreference({
    required String preferenceKey,
    required String value,
    required String updatedAt,
  }) {
    if (!_dao.supportsDeferredWrites) {
      _dao.upsertValue(
        preferenceKey: preferenceKey,
        value: value,
        updatedAt: updatedAt,
      );
      return;
    }
    unawaited(
      _dao
          .upsertValueDeferred(
            preferenceKey: preferenceKey,
            value: value,
            updatedAt: updatedAt,
          )
          .catchError((Object _) {}),
    );
  }

  void _deletePreference(String preferenceKey) {
    if (!_dao.supportsDeferredWrites) {
      _dao.deleteValue(preferenceKey);
      return;
    }
    unawaited(
      _dao
          .deleteValueDeferred(preferenceKey)
          .then<void>((_) {}, onError: (Object _) {}),
    );
  }

  static String _scopeDigest(String userScope, String workspaceScope) {
    final user = userScope.trim();
    final workspace = workspaceScope.trim();
    if (user.isEmpty || workspace.isEmpty) {
      throw ArgumentError('Read cache scope is unavailable');
    }
    return sha256
        .convert(utf8.encode('$user\n$workspace'))
        .toString()
        .substring(0, 24);
  }

  static Duration _validatedTtl(Duration? value) {
    if (value == null ||
        value <= Duration.zero ||
        value > const Duration(days: 1)) {
      return AppCachePolicy.fallbackCacheTtl;
    }
    return value;
  }
}
