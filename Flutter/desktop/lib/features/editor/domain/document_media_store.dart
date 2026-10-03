import 'dart:io';
import 'dart:typed_data';

/// A private, document-scoped image stored by the desktop application.
///
/// [uri] is intentionally the only durable source identifier exposed to an
/// editor document. It never contains an operating-system path.
final class LocalDocumentMediaAsset {
  const LocalDocumentMediaAsset({
    required this.documentId,
    required this.assetId,
    required this.uri,
    required this.mimeType,
    required this.extension,
    required this.byteLength,
  });

  final String documentId;
  final String assetId;
  final Uri uri;
  final String mimeType;
  final String extension;
  final int byteLength;
}

/// Bytes and metadata returned for a previously imported local image.
final class LocalDocumentMediaData {
  const LocalDocumentMediaData({required this.asset, required this.bytes});

  final LocalDocumentMediaAsset asset;
  final Uint8List bytes;
}

/// Describes an invalid or unsafe local-media operation.
final class LocalDocumentMediaException implements Exception {
  const LocalDocumentMediaException(this.message);

  final String message;

  @override
  String toString() => 'LocalDocumentMediaException: $message';
}

/// Stable URI grammar used by document-owned media references.
abstract final class DocumentMediaUri {
  static const String scheme = 'huahuo-media';
  static const String _host = 'asset';
  static final RegExp _assetIdPattern = RegExp(r'^[A-Za-z0-9_-]{16,64}$');

  static Uri? parse(String value) {
    final uri = Uri.tryParse(value);
    return uri != null && assetId(uri) != null ? uri : null;
  }

  static bool isValid(Uri uri) => assetId(uri) != null;

  static String? assetId(Uri uri) {
    if (uri.scheme != scheme ||
        uri.host != _host ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort ||
        uri.query.isNotEmpty ||
        uri.fragment.isNotEmpty ||
        uri.pathSegments.length != 1) {
      return null;
    }
    final assetId = uri.pathSegments.single;
    return _assetIdPattern.hasMatch(assetId) ? assetId : null;
  }

  static Uri forAsset(String assetId) {
    if (!_assetIdPattern.hasMatch(assetId)) {
      throw const LocalDocumentMediaException(
        'The generated image identifier is invalid.',
      );
    }
    return Uri(scheme: scheme, host: _host, path: assetId);
  }
}

/// Storage contract for document-owned desktop media.
abstract interface class DocumentMediaStore {
  Future<LocalDocumentMediaAsset> importFile({
    required String documentId,
    required File source,
    String? mimeType,
  });

  Future<LocalDocumentMediaAsset> importBytes({
    required String documentId,
    required Uint8List bytes,
    required String fileName,
    String? mimeType,
  });

  Future<LocalDocumentMediaData?> read({
    required String documentId,
    required Uri uri,
  });

  Future<File?> resolveFile({required String documentId, required Uri uri});

  Future<bool> delete({required String documentId, required Uri uri});
}

/// Non-persistent fallback for isolated presentation tests and previews.
final class UnavailableDocumentMediaStore implements DocumentMediaStore {
  const UnavailableDocumentMediaStore();

  Future<T> _unavailable<T>() => Future<T>.error(
    const LocalDocumentMediaException('Local document media is unavailable.'),
  );

  @override
  Future<bool> delete({required String documentId, required Uri uri}) =>
      Future<bool>.value(false);

  @override
  Future<LocalDocumentMediaAsset> importBytes({
    required String documentId,
    required Uint8List bytes,
    required String fileName,
    String? mimeType,
  }) => _unavailable<LocalDocumentMediaAsset>();

  @override
  Future<LocalDocumentMediaAsset> importFile({
    required String documentId,
    required File source,
    String? mimeType,
  }) => _unavailable<LocalDocumentMediaAsset>();

  @override
  Future<LocalDocumentMediaData?> read({
    required String documentId,
    required Uri uri,
  }) => Future<LocalDocumentMediaData?>.value();

  @override
  Future<File?> resolveFile({required String documentId, required Uri uri}) =>
      Future<File?>.value();
}
