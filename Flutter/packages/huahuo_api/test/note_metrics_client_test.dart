import 'package:huahuo_api/huahuo_api.dart';
import 'package:test/test.dart';

void main() {
  test(
    'reads server-owned daily Note metrics without a timezone override',
    () async {
      final transport = _QueueTransport(<ApiTransportResponse>[
        _success(_metricsPage()),
      ]);
      final result = await WorkspaceNoteMetricsClient(
        _client(transport),
      ).list(workspaceId: 'workspace-1', limit: 2);

      expect(result.ok, isTrue);
      expect(
        result.data?.schemaVersion,
        'huahuo.workspace_note_daily_metrics.v2',
      );
      expect(result.data?.metricId, 'new_note_count');
      expect(result.data?.timezone, 'Asia/Shanghai');
      expect(result.data?.days.map((day) => day.count), <int>[3, 0]);
      expect(result.data?.days.first.complete, isFalse);
      expect(result.data?.days.last.complete, isTrue);
      expect(result.data?.coverage.historyComplete, isFalse);
      expect(result.data?.hasMore, isTrue);
      final request = transport.requests.single;
      expect(request.method, 'GET');
      expect(request.url.path, '/api/v1/workspaces/workspace-1/note-metrics');
      expect(request.url.queryParameters, <String, String>{'limit': '2'});
      expect(request.headers.containsKey('X-Idempotency-Key'), isFalse);
    },
  );

  test(
    'forwards only an opaque metrics cursor for older daily pages',
    () async {
      final transport = _QueueTransport(<ApiTransportResponse>[
        _success(_metricsPage(olderPage: true, hasMore: false)),
      ]);
      final result = await WorkspaceNoteMetricsClient(
        _client(transport),
      ).list(workspaceId: 'workspace-1', limit: 2, cursor: 'opaque_cursor-1');

      expect(result.ok, isTrue);
      expect(transport.requests.single.url.queryParameters, <String, String>{
        'limit': '2',
        'cursor': 'opaque_cursor-1',
      });
    },
  );

  test(
    'rejects malformed daily sequence and incomplete cursor receipts',
    () async {
      final invalidDays = _metricsPage()
        ..['days'] = <Object?>[
          <String, Object?>{'date': '2026-08-18', 'count': 0, 'complete': true},
          <String, Object?>{
            'date': '2026-08-19',
            'count': 3,
            'complete': false,
          },
        ];
      final invalidCursor = _metricsPage()..['nextCursor'] = '';
      final skippedDate = _metricsPage()
        ..['hasMore'] = false
        ..['nextCursor'] = ''
        ..['days'] = <Object?>[
          <String, Object?>{
            'date': '2026-08-19',
            'count': 3,
            'complete': false,
          },
          <String, Object?>{
            'date': '2026-08-17',
            'count': 0,
            'complete': false,
          },
        ];
      final incompleteTerminal = _metricsPage()
        ..['hasMore'] = false
        ..['nextCursor'] = '';
      final transport = _QueueTransport(<ApiTransportResponse>[
        _success(invalidDays),
        _success(invalidCursor),
        _success(skippedDate),
        _success(incompleteTerminal),
      ]);
      final client = WorkspaceNoteMetricsClient(_client(transport));

      final outOfOrder = await client.list(workspaceId: 'workspace-1');
      final missingCursor = await client.list(workspaceId: 'workspace-1');
      final skippedCalendarDate = await client.list(workspaceId: 'workspace-1');
      final incompleteLastPage = await client.list(workspaceId: 'workspace-1');

      expect(outOfOrder.ok, isFalse);
      expect(missingCursor.ok, isFalse);
      expect(skippedCalendarDate.ok, isFalse);
      expect(incompleteLastPage.ok, isFalse);
    },
  );

  test('rejects invalid limit and empty cursor before transport', () {
    final client = WorkspaceNoteMetricsClient(_client(_QueueTransport([])));

    expect(
      () => client.list(workspaceId: 'workspace-1', limit: 367),
      throwsArgumentError,
    );
    expect(
      () => client.list(workspaceId: 'workspace-1', cursor: ' '),
      throwsArgumentError,
    );
  });
}

Map<String, Object?> _metricsPage({
  bool olderPage = false,
  bool hasMore = true,
}) => <String, Object?>{
  'schemaVersion': 'huahuo.workspace_note_daily_metrics.v2',
  'metricId': 'new_note_count',
  'timezone': 'Asia/Shanghai',
  'asOf': '2026-08-19T04:00:00Z',
  'coverage': <String, Object?>{
    'startAt': '2026-08-16T16:00:00Z',
    'startDate': '2026-08-17',
    'completeFromDate': '2026-08-18',
    'currentDate': '2026-08-19',
    'historyComplete': false,
  },
  'days': olderPage
      ? <Object?>[
          <String, Object?>{
            'date': '2026-08-17',
            'count': 1,
            'complete': false,
          },
        ]
      : <Object?>[
          <String, Object?>{
            'date': '2026-08-19',
            'count': 3,
            'complete': false,
          },
          <String, Object?>{'date': '2026-08-18', 'count': 0, 'complete': true},
        ],
  'hasMore': hasMore,
  'nextCursor': hasMore ? 'opaque-next-cursor' : '',
};

ApiClient _client(_QueueTransport transport) => ApiClient(
  config: ApiClientConfig(
    baseUrl: Uri.parse('https://api.example.test'),
    clientVersion: 'test',
    deviceId: 'device-test',
    platform: 'test',
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

final class _QueueTransport implements ApiTransport {
  _QueueTransport(this.responses);

  final List<ApiTransportResponse> responses;
  final List<ApiTransportRequest> requests = <ApiTransportRequest>[];

  @override
  Future<ApiTransportResponse> send(ApiTransportRequest request) async {
    requests.add(request);
    return responses.removeAt(0);
  }
}
