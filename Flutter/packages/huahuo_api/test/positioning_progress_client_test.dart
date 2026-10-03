import 'package:huahuo_api/huahuo_api.dart';
import 'package:test/test.dart';

void main() {
  test(
    'uses ETag conditional reads for the workspace progress projection',
    () async {
      final transport = _QueueTransport(<ApiTransportResponse>[
        ApiTransportResponse(
          status: 200,
          headers: const <String, String>{'ETag': '"progress-1"'},
          body: <String, Object?>{'success': true, 'data': _progressPayload()},
        ),
        const ApiTransportResponse(
          status: 304,
          headers: <String, String>{'ETag': '"progress-1"'},
          body: null,
        ),
      ]);
      final client = PositioningProgressClient(_apiClient(transport));

      final first = await client.read(workspaceId: 'workspace_1');
      final second = await client.read(
        workspaceId: 'workspace_1',
        ifNoneMatch: first.etag,
      );

      expect(first.ok, isTrue);
      expect(first.etag, '"progress-1"');
      expect(second.isNotModified, isTrue);
      expect(transport.requests[1].headers['If-None-Match'], '"progress-1"');
      expect(
        transport.requests.first.url.path,
        '/api/v1/workspaces/workspace_1/positioning/progress',
      );
    },
  );

  test('accepts only workspace-file positioning projections', () {
    final progress = parseWorkspacePositioningProgress(<String, Object?>{
      'schemaVersion': 'huahuo.positioning-progress.v1',
      'source': 'workspace_file',
      'available': true,
      'projectionVersion': 4,
      'status': 'forming',
      'validationStatus': 'valid',
      'completedPercent': 45,
      'coldStartPercent': 100,
      'coldStartCompleted': true,
      'modules': <Object?>[
        <String, Object?>{
          'id': 'credible_self',
          'label': '人生体验',
          'weight': 10,
          'score': 5,
          'state': 'forming',
        },
      ],
      'nextFocus': const <Object?>[],
      'updatedFiles': const <Object?>[],
    });
    expect(progress?.completedPercent, 45);
    expect(progress?.modules.single.id, 'credible_self');
  });

  test('rejects non-authoritative progress source', () {
    expect(
      parseWorkspacePositioningProgress(<String, Object?>{
        'schemaVersion': 'huahuo.positioning-progress.v1',
        'source': 'assistant_reply',
        'available': true,
        'projectionVersion': 1,
        'completedPercent': 0,
        'coldStartPercent': 0,
        'coldStartCompleted': false,
        'modules': const <Object?>[],
      }),
      isNull,
    );
  });
}

Map<String, Object?> _progressPayload() => <String, Object?>{
  'schemaVersion': 'huahuo.positioning-progress.v1',
  'source': 'workspace_file',
  'available': true,
  'projectionVersion': 4,
  'status': 'forming',
  'validationStatus': 'valid',
  'completedPercent': 45,
  'coldStartPercent': 100,
  'coldStartCompleted': true,
  'modules': <Object?>[
    <String, Object?>{
      'id': 'credible_self',
      'label': '人生体验',
      'weight': 10,
      'score': 5,
      'state': 'forming',
    },
  ],
  'nextFocus': const <Object?>[],
  'updatedFiles': const <Object?>[],
};

ApiClient _apiClient(ApiTransport transport) => ApiClient(
  config: ApiClientConfig(
    baseUrl: Uri.parse('https://api.example.test'),
    clientVersion: 'test',
    deviceId: 'test-device',
    platform: 'test',
    locale: 'zh-CN',
    getAccessToken: () => 'token',
  ),
  transport: transport,
);

final class _QueueTransport implements ApiTransport {
  _QueueTransport(this._responses);

  final List<ApiTransportResponse> _responses;
  final List<ApiTransportRequest> requests = <ApiTransportRequest>[];

  @override
  Future<ApiTransportResponse> send(ApiTransportRequest request) async {
    requests.add(request);
    return _responses.removeAt(0);
  }
}
