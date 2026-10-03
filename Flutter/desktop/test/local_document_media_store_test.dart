import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:huahuo_desktop/features/editor/data/local_document_media_store.dart';

void main() {
  group('LocalDocumentMediaStore', () {
    late Directory supportDirectory;
    late LocalDocumentMediaStore store;

    setUp(() async {
      supportDirectory = await Directory.systemTemp.createTemp(
        'huahuo-document-media-',
      );
      store = LocalDocumentMediaStore(
        supportDirectory: () async => supportDirectory,
      );
    });

    tearDown(() async {
      if (await supportDirectory.exists()) {
        await supportDirectory.delete(recursive: true);
      }
    });

    test(
      'copies an image and restores it from its durable media URI',
      () async {
        final bytes = _pngBytes();
        final asset = await store.importBytes(
          documentId: 'note/with unsafe-looking characters',
          bytes: bytes,
          fileName: 'cover.PNG',
          mimeType: 'image/png; charset=binary',
        );

        expect(asset.documentId, 'note/with unsafe-looking characters');
        expect(asset.mimeType, 'image/png');
        expect(asset.extension, 'png');
        expect(asset.byteLength, bytes.length);
        expect(asset.uri.toString(), matches(_mediaUriPattern));
        expect(asset.uri.scheme, isNot('file'));
        expect(
          LocalDocumentMediaStore.parseUri(asset.uri.toString()),
          asset.uri,
        );

        final restored = await store.read(
          documentId: 'note/with unsafe-looking characters',
          uri: asset.uri,
        );
        expect(restored, isNotNull);
        expect(restored!.asset.assetId, asset.assetId);
        expect(restored.bytes, orderedEquals(bytes));

        final file = await store.resolveFile(
          documentId: 'note/with unsafe-looking characters',
          uri: asset.uri,
        );
        expect(file, isNotNull);
        expect(await file!.exists(), isTrue);
        expect(file.path, startsWith(supportDirectory.path));
        expect(
          file.path,
          isNot(contains('note/with unsafe-looking characters')),
        );
      },
    );

    test(
      'copies selected files instead of retaining their source path',
      () async {
        final source = File(
          '${supportDirectory.path}${Platform.pathSeparator}picked.jpeg',
        );
        await source.writeAsBytes(_jpegBytes());

        final asset = await store.importFile(
          documentId: 'copied-file',
          source: source,
          mimeType: 'image/jpeg',
        );
        await source.delete();

        final restored = await store.read(
          documentId: 'copied-file',
          uri: asset.uri,
        );
        expect(restored, isNotNull);
        expect(restored!.bytes, orderedEquals(_jpegBytes()));
        expect(asset.extension, 'jpg');
      },
    );

    test(
      'rejects unsafe image names, MIME declarations, signatures, and size',
      () async {
        final png = _pngBytes();

        await expectLater(
          store.importBytes(
            documentId: 'invalid-extension',
            bytes: png,
            fileName: 'image.svg',
            mimeType: 'image/svg+xml',
          ),
          throwsA(isA<LocalDocumentMediaException>()),
        );
        await expectLater(
          store.importBytes(
            documentId: 'mismatched-extension',
            bytes: png,
            fileName: 'image.jpg',
            mimeType: 'image/jpeg',
          ),
          throwsA(isA<LocalDocumentMediaException>()),
        );
        await expectLater(
          store.importBytes(
            documentId: 'mismatched-mime',
            bytes: png,
            fileName: 'image.png',
            mimeType: 'image/jpeg',
          ),
          throwsA(isA<LocalDocumentMediaException>()),
        );
        await expectLater(
          store.importBytes(
            documentId: 'non-image',
            bytes: Uint8List.fromList(utf8.encode('not an image')),
            fileName: 'image.png',
            mimeType: 'image/png',
          ),
          throwsA(isA<LocalDocumentMediaException>()),
        );

        final smallStore = LocalDocumentMediaStore(
          supportDirectory: () async => supportDirectory,
          maximumImageBytes: _pngBytes().length - 1,
        );
        await expectLater(
          smallStore.importBytes(
            documentId: 'too-large',
            bytes: png,
            fileName: 'image.png',
            mimeType: 'image/png',
          ),
          throwsA(isA<LocalDocumentMediaException>()),
        );
      },
    );

    test('does not resolve arbitrary or cross-document URI sources', () async {
      final asset = await store.importBytes(
        documentId: 'owner',
        bytes: _pngBytes(),
        fileName: 'image.png',
        mimeType: 'image/png',
      );
      final external = Uri.parse('file:///tmp/not-an-editor-image.png');

      expect(LocalDocumentMediaStore.parseUri(external.toString()), isNull);
      expect(
        await store.resolveFile(documentId: 'owner', uri: external),
        isNull,
      );
      expect(await store.read(documentId: 'other', uri: asset.uri), isNull);
    });

    test('deletes only the exact document-owned media asset', () async {
      final asset = await store.importBytes(
        documentId: 'delete-owner',
        bytes: _pngBytes(),
        fileName: 'image.png',
        mimeType: 'image/png',
      );

      expect(
        await store.delete(documentId: 'other-document', uri: asset.uri),
        isFalse,
      );
      expect(
        await store.read(documentId: 'delete-owner', uri: asset.uri),
        isNotNull,
      );
      expect(
        await store.delete(documentId: 'delete-owner', uri: asset.uri),
        isTrue,
      );
      expect(
        await store.read(documentId: 'delete-owner', uri: asset.uri),
        isNull,
      );
      expect(
        await store.delete(documentId: 'delete-owner', uri: asset.uri),
        isFalse,
      );
    });
  });
}

final RegExp _mediaUriPattern = RegExp(
  r'^huahuo-media://asset/[A-Za-z0-9_-]{16,64}$',
);

Uint8List _pngBytes() => Uint8List.fromList(
  base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLZQAAAAABJRU5ErkJggg==',
  ),
);

Uint8List _jpegBytes() => Uint8List.fromList(
  base64Decode(
    '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAP//////////////////////////////////////////////////////////////////////////////////////2wBDAf//////////////////////////////////////////////////////////////////////////////////////wAARCAABAAEDASIAAhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAX/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/9oADAMBAAIQAxAAAAH/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/9oACAEBAAEFAqf/xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oACAEDAQE/AT//xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oACAECAQE/AT//xAAUEAEAAAAAAAAAAAAAAAAAAAAA/9oACAEBAAY/Aqf/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/9oACAEBAAE/If/EABQRAQAAAAAAAAAAAAAAAAAAABD/2gAIAQEAAT8hH//Z',
  ),
);
