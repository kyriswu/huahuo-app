import 'dart:convert';

import 'package:huahuo_api/huahuo_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/features/assets/data/asset_api.dart';

void main() {
  group('AssetApi', () {
    test(
      'loads the safe markdown document and triggers an idempotent sync',
      () async {
        final transport = _QueueTransport(<ApiTransportResponse>[
          _response(_markdownData()),
          const ApiTransportResponse(
            status: 200,
            body: <String, Object?>{
              'success': true,
              'data': <String, Object?>{
                'taskId': 'asset-task-1',
                'status': 'queued',
              },
            },
          ),
        ]);
        final api = AssetApi(apiClient: _apiClient(transport));

        final markdown = await api
            .leaseMarkdown(focus: AssetMarkdownFocus.overview)
            .result;
        final sync = await api.syncAssets(
          idempotency: const IdempotencyRequestContext(
            operation: 'assets.sync',
            scene: 'assets',
            generateKey: _fixedKey,
          ),
        );

        expect(markdown.ok, isTrue);
        expect(markdown.data?.title, 'Personal assets');
        expect(markdown.data?.links.single.target.recordingId, 'recording-1');
        expect(markdown.data?.contentLines.single.contentLineId, 'line-1');
        expect(sync.ok, isTrue);
        expect(sync.data?.taskId, 'asset-task-1');

        final markdownRequest = transport.requests.first;
        expect(markdownRequest.method, 'GET');
        expect(markdownRequest.url.path, '/api/v1/assets/markdown');
        expect(markdownRequest.url.queryParameters['focus'], 'overview');
        final syncRequest = transport.requests.last;
        expect(syncRequest.method, 'POST');
        expect(syncRequest.url.path, '/api/v1/assets/sync');
        expect(syncRequest.headers['X-Idempotency-Key'], 'assets-sync-key');
        expect(_body(syncRequest), isEmpty);
      },
    );

    test('rejects a document with an unapproved link scheme', () async {
      final invalid = _markdownData();
      final document = invalid['document']! as Map<String, Object?>;
      document['links'] = <Object?>[
        <String, Object?>{
          'linkId': 'link-1',
          'href': 'https://untrusted.example/recording-1',
          'label': 'Open recording',
          'target': <String, Object?>{
            'type': 'recording_detail',
            'recordingId': 'recording-1',
          },
        },
      ];
      final transport = _QueueTransport(<ApiTransportResponse>[
        _response(invalid),
      ]);
      final api = AssetApi(apiClient: _apiClient(transport));

      final result = await api.getMarkdown();

      expect(result.ok, isFalse);
      expect(result.error?.code, 'API_MALFORMED_ENVELOPE');
    });

    test('submits a whitelist asset patch with its base version', () async {
      final transport = _QueueTransport(<ApiTransportResponse>[
        const ApiTransportResponse(
          status: 200,
          body: <String, Object?>{
            'success': true,
            'data': <String, Object?>{
              'assetType': 'content_line',
              'assetId': 'line-1',
              'newVersion': 4,
              'asset': <String, Object?>{
                'name': 'Retail voice',
                'tags': <String>['retail', 'voice'],
              },
            },
          },
        ),
      ]);
      final api = AssetApi(apiClient: _apiClient(transport));
      final patch = buildEditableAssetPatch(
        EditableAssetType.contentLine,
        <String, Object?>{
          'name': 'Retail voice',
          'tags': 'retail, voice',
          'token': 'must not be sent',
        },
      );

      final result = await api.patchAsset(
        assetType: EditableAssetType.contentLine,
        assetId: 'line-1',
        baseVersion: 3,
        patch: patch!,
        idempotency: const IdempotencyRequestContext(
          operation: 'assets.patch',
          businessEntityId: 'line-1',
          scene: 'assets',
          generateKey: _fixedPatchKey,
        ),
      );

      expect(result.ok, isTrue);
      expect(result.data?.newVersion, 4);
      expect(result.data?.asset['tags'], <String>['retail', 'voice']);
      final request = transport.requests.single;
      expect(request.method, 'PATCH');
      expect(request.url.path, '/api/v1/assets/content_line/line-1');
      expect(request.headers['X-Idempotency-Key'], 'assets-patch-key');
      expect(_body(request), <String, Object?>{
        'baseVersion': 3,
        'patch': <String, Object?>{
          'assetType': 'content_line',
          'fields': <String, Object?>{
            'name': 'Retail voice',
            'tags': <String>['retail', 'voice'],
          },
        },
      });
    });

    test('does not accept a manually constructed unsafe patch', () async {
      final transport = _QueueTransport(<ApiTransportResponse>[]);
      final api = AssetApi(apiClient: _apiClient(transport));

      final result = await api.patchAsset(
        assetType: EditableAssetType.contentLine,
        assetId: 'line-1',
        baseVersion: 3,
        patch: const EditableAssetPatch(
          assetType: EditableAssetType.contentLine,
          fields: <String, Object?>{'token': 'secret'},
        ),
        idempotency: const IdempotencyRequestContext(
          operation: 'assets.patch',
          businessEntityId: 'line-1',
          scene: 'assets',
        ),
      );

      expect(result.ok, isFalse);
      expect(result.error?.code, 'ASSET_PATCH_INPUT_INVALID');
      expect(transport.requests, isEmpty);
    });
  });
}

Map<String, Object?> _markdownData() {
  return <String, Object?>{
    'document': <String, Object?>{
      'schemaVersion': 'personal_assets.markdown.v1',
      'documentId': 'document-1',
      'documentVersion': 1,
      'title': 'Personal assets',
      'markdown': '# Overview\nThe safe server rendered document.',
      'renderedAt': '2026-07-10T00:00:00Z',
      'locale': 'zh-CN',
      'anchors': <Object?>[
        <String, Object?>{
          'anchorId': 'overview',
          'title': 'Overview',
          'level': 1,
        },
      ],
      'links': <Object?>[
        <String, Object?>{
          'linkId': 'link-1',
          'href': 'huahuo://asset-link/link-1',
          'label': 'Open recording',
          'target': <String, Object?>{
            'type': 'recording_detail',
            'recordingId': 'recording-1',
          },
        },
      ],
      'imagePolicy': 'none',
      'allowedMarkdown': <Object?>['heading', 'paragraph'],
    },
    'overview': <String, Object?>{
      'recordingCount': 2,
      'transcriptWordCount': 320,
      'contentLineCount': 1,
      'lifeEventCount': 0,
      'expressionCount': 2,
      'syncStatus': 'normal',
    },
    'contentLines': <Object?>[
      <String, Object?>{'contentLineId': 'line-1', 'name': 'Retail voice'},
    ],
    'sync': <String, Object?>{
      'status': 'normal',
      'stale': false,
      'retryable': false,
    },
    'redDotState': const <Object?>[],
  };
}

ApiTransportResponse _response(Map<String, Object?> data) {
  return ApiTransportResponse(
    status: 200,
    body: <String, Object?>{'success': true, 'data': data},
  );
}

ApiClient _apiClient(_QueueTransport transport) {
  return ApiClient(
    config: ApiClientConfig(
      baseUrl: Uri.parse('https://api.example.test'),
      clientVersion: 'test',
      deviceId: 'device-1',
      platform: 'test',
      locale: 'en-US',
      getAccessToken: () async => 'access-token',
    ),
    transport: transport,
  );
}

Map<String, Object?> _body(ApiTransportRequest request) {
  final decoded = jsonDecode(request.body ?? '{}') as Map<String, dynamic>;
  return decoded.cast<String, Object?>();
}

String _fixedKey() => 'assets-sync-key';

String _fixedPatchKey() => 'assets-patch-key';

final class _QueueTransport implements ApiTransport {
  _QueueTransport(List<ApiTransportResponse> responses)
    : _responses = List<ApiTransportResponse>.of(responses);

  final List<ApiTransportResponse> _responses;
  final List<ApiTransportRequest> requests = <ApiTransportRequest>[];

  @override
  Future<ApiTransportResponse> send(ApiTransportRequest request) async {
    requests.add(request);
    if (_responses.isEmpty) throw StateError('Unexpected request');
    return _responses.removeAt(0);
  }
}
