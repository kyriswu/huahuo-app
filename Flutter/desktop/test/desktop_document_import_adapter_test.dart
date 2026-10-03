import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:huahuo_api/huahuo_api.dart';
import 'package:huahuo_desktop/features/documents/data/desktop_document_import_adapter.dart';
import 'package:huahuo_desktop/features/documents/domain/desktop_document_import_port.dart';

void main() {
  test('supports the same document suffixes as mobile import', () {
    expect(
      <DesktopDocumentImportFormat?>[
        DesktopDocumentImportFormat.fromFileName('note.txt'),
        DesktopDocumentImportFormat.fromFileName('note.md'),
        DesktopDocumentImportFormat.fromFileName('note.markdown'),
        DesktopDocumentImportFormat.fromFileName('note.csv'),
        DesktopDocumentImportFormat.fromFileName('note.json'),
        DesktopDocumentImportFormat.fromFileName('note.pdf'),
        DesktopDocumentImportFormat.fromFileName('note.docx'),
        DesktopDocumentImportFormat.fromFileName('note.pptx'),
        DesktopDocumentImportFormat.fromFileName('note.xlsx'),
      ],
      <DesktopDocumentImportFormat>[
        DesktopDocumentImportFormat.text,
        DesktopDocumentImportFormat.markdown,
        DesktopDocumentImportFormat.markdown,
        DesktopDocumentImportFormat.csv,
        DesktopDocumentImportFormat.json,
        DesktopDocumentImportFormat.pdf,
        DesktopDocumentImportFormat.docx,
        DesktopDocumentImportFormat.pptx,
        DesktopDocumentImportFormat.xlsx,
      ],
    );
  });

  test(
    'imports a DOCX through Resource ingestion before reading its HNote',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'desktop-document-import-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final source = File('${directory.path}${Platform.pathSeparator}创作提纲.docx')
        ..writeAsBytesSync(<int>[0x50, 0x4b, 0x03, 0x04]);
      final transport = _QueueTransport(<ApiTransportResponse>[
        _success(<String, Object?>{
          'uploadId': 'upload-1',
          'resourceId': 'resource-1',
          'uploadUrl': 'https://uploads.example.test/object-1',
          'method': 'PUT',
        }),
        _success(<String, Object?>{
          'uploadId': 'upload-1',
          'status': 'completed',
          'resource': <String, Object?>{'resourceId': 'resource-1'},
        }),
        _success(<String, Object?>{
          'ingestion': <String, Object?>{
            'ingestionId': 'ingestion-1',
            'status': 'ready_to_promote',
          },
        }),
        _success(<String, Object?>{
          'note': <String, Object?>{'noteId': 'note-1'},
        }),
        _success(_noteJson()),
      ]);
      final objectUpload = _ObjectUploadTransport();
      final importer = RemoteDesktopDocumentImportPort(
        _client(transport),
        objectUploadTransport: objectUpload,
      );

      final result = await importer.importDocument(
        DesktopDocumentImportRequest(
          filePath: source.path,
          fileName: '创作提纲.docx',
          workspaceId: 'workspace-1',
        ),
      );

      expect(result.isSuccess, isTrue);
      expect(result.data?.noteId, 'note-1');
      expect(result.data?.title, '创作提纲');
      expect(result.data?.format, DesktopDocumentImportFormat.docx);
      expect(transport.requests.map((request) => request.url.path), <String>[
        '/api/v1/media/upload-token',
        '/api/v1/media/uploads/upload-1/complete',
        '/api/v1/workspaces/workspace-1/note-ingestions',
        '/api/v1/workspaces/workspace-1/note-ingestions/ingestion-1/promote',
        '/api/v1/workspaces/workspace-1/notes/note-1',
      ]);
      final tokenBody = jsonDecode(transport.requests[0].body!) as Map;
      final ingestionBody = jsonDecode(transport.requests[2].body!) as Map;
      final promoteBody = jsonDecode(transport.requests[3].body!) as Map;
      expect(tokenBody['sourceScene'], 'note_import');
      expect(
        tokenBody['mimeType'],
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      );
      expect(tokenBody['fileName'], '创作提纲.docx');
      expect(ingestionBody, <String, Object?>{'resourceId': 'resource-1'});
      expect(promoteBody, <String, Object?>{'title': '创作提纲'});
      expect(transport.requests.join(' '), isNot(contains(source.path)));
      expect(objectUpload.request?.appPrivateUri, startsWith('app-private://'));
      expect(objectUpload.request?.appPrivateUri, isNot(contains(source.path)));
    },
  );

  test('rejects unsupported extensions before a Resource request', () async {
    final transport = _QueueTransport(const <ApiTransportResponse>[]);
    final importer = RemoteDesktopDocumentImportPort(_client(transport));

    final result = await importer.importDocument(
      const DesktopDocumentImportRequest(
        filePath: '/tmp/not-supported.pages',
        fileName: 'not-supported.pages',
        workspaceId: 'workspace-1',
      ),
    );

    expect(result.isSuccess, isFalse);
    expect(result.code, 'DESKTOP_DOCUMENT_IMPORT_INVALID');
    expect(transport.requests, isEmpty);
  });
}

ApiClient _client(_QueueTransport transport) => ApiClient(
  config: ApiClientConfig(
    baseUrl: Uri.parse('https://api.example.test'),
    clientVersion: 'test',
    deviceId: 'desktop-test',
    platform: 'windows',
    locale: 'zh-CN',
    getAccessToken: () => 'access-token',
  ),
  transport: transport,
);

ApiTransportResponse _success(Map<String, Object?> data) =>
    ApiTransportResponse(
      status: 200,
      body: <String, Object?>{'success': true, 'data': data},
    );

Map<String, Object?> _noteJson() => <String, Object?>{
  'noteId': 'note-1',
  'workspaceId': 'workspace-1',
  'folderId': null,
  'title': '创作提纲',
  'state': 'active',
  'noteRevisionId': 'note-revision-1',
  'parts': <String, Object?>{
    'raw': <String, Object?>{
      'partRevisionId': 'raw-revision-1',
      'markdown': '# 创作提纲',
      'contentHash': 'hash-raw',
    },
    'outline': <String, Object?>{
      'partRevisionId': 'outline-revision-1',
      'markdown': '',
      'contentHash': 'hash-outline',
    },
    'germination': <String, Object?>{
      'partRevisionId': 'germination-revision-1',
      'markdown': '',
      'contentHash': 'hash-germination',
    },
  },
  'resourceRefs': const <Object?>[],
  'etag': 'etag-1',
  'contentCursor': '10',
};

final class _ObjectUploadTransport implements ObjectUploadTransport {
  ObjectUploadRequest? request;

  @override
  Future<ObjectUploadResult> upload(ObjectUploadRequest request) async {
    this.request = request;
    return ObjectUploadResult.success(
      statusCode: 200,
      bytesSent: request.sizeBytes,
    );
  }
}

final class _QueueTransport implements ApiTransport {
  _QueueTransport(Iterable<ApiTransportResponse> responses)
    : _responses = List<ApiTransportResponse>.of(responses);

  final List<ApiTransportResponse> _responses;
  final List<ApiTransportRequest> requests = <ApiTransportRequest>[];

  @override
  Future<ApiTransportResponse> send(ApiTransportRequest request) async {
    requests.add(request);
    if (_responses.isEmpty) throw StateError('Unexpected API request');
    return _responses.removeAt(0);
  }
}
