import 'dart:convert';

import 'package:huahuo_api/huahuo_api.dart';
import 'package:test/test.dart';

void main() {
  test('loads and validates the complete Home aggregation', () async {
    final transport = _QueueTransport(<ApiTransportResponse>[
      _success(_homePayload()),
    ]);

    final result = await HomeClient(_client(transport)).load();

    expect(result.ok, isTrue);
    final home = result.data!;
    expect(home.primaryAction.type, HomePrimaryActionType.openRunningTask);
    expect(home.primaryAction.taskId, 'task-1');
    expect(home.runningTasks.single.threadId, 'thread-1');
    expect(home.hotspotSuggestion?.title, '今天值得关注的主题');
    expect(home.fileSummary.recordingCount, 4);
    expect(home.quotaBalances.single.remaining, 72);
    expect(home.redDots.single.count, 1);
    expect(home.serverTime, DateTime.utc(2026, 9, 3, 3));
    expect(transport.requests.single.url.path, '/api/v1/home');
  });

  test('accepts an empty hotspot and empty aggregation lists', () async {
    final payload = _homePayload()
      ..['primaryAction'] = <String, Object?>{
        'type': 'upload_recording',
        'label': 'Upload recording',
      }
      ..['hotspotSuggestion'] = <String, Object?>{}
      ..['runningTasks'] = <Object?>[]
      ..['redDots'] = <Object?>[];
    final transport = _QueueTransport(<ApiTransportResponse>[
      _success(payload),
    ]);

    final result = await HomeClient(_client(transport)).load();

    expect(result.ok, isTrue);
    expect(result.data?.hotspotSuggestion, isNull);
    expect(result.data?.runningTasks, isEmpty);
    expect(result.data?.redDots, isEmpty);
  });

  test('marks a hotspot viewed with an explicit idempotency key', () async {
    final transport = _QueueTransport(<ApiTransportResponse>[
      _success(<String, Object?>{
        'suggestionId': 'suggestion-1',
        'viewedAt': '2026-09-03T03:05:00Z',
        'redDots': <Object?>[],
      }),
    ]);

    final result = await HomeClient(_client(transport)).markHotspotViewed(
      suggestionId: 'suggestion-1',
      idempotencyKey: 'home-viewed-suggestion-1',
    );

    expect(result.ok, isTrue);
    final request = transport.requests.single;
    expect(
      request.url.path,
      '/api/v1/home/hotspot-suggestions/suggestion-1/viewed',
    );
    expect(request.body, jsonEncode(<String, Object?>{}));
    expect(request.headers['X-Idempotency-Key'], 'home-viewed-suggestion-1');
  });

  test('rejects malformed response fields and invalid arguments', () async {
    final missingTaskId = _homePayload()
      ..['primaryAction'] = <String, Object?>{
        'type': 'open_running_task',
        'label': 'Open task',
      };
    final invalidCount = _homePayload()
      ..['fileSummary'] = <String, Object?>{
        'recordingCount': -1,
        'depositedRecordingCount': 0,
      };
    final transport = _QueueTransport(<ApiTransportResponse>[
      _success(missingTaskId),
      _success(invalidCount),
    ]);
    final client = HomeClient(_client(transport));

    expect((await client.load()).error?.code, 'API_RESPONSE_INVALID');
    expect((await client.load()).error?.code, 'API_RESPONSE_INVALID');
    expect(
      () => client.markHotspotViewed(
        suggestionId: '../unsafe',
        idempotencyKey: 'key',
      ),
      throwsArgumentError,
    );
    expect(
      () => client.markHotspotViewed(
        suggestionId: 'suggestion-1',
        idempotencyKey: ' ',
      ),
      throwsArgumentError,
    );
  });
}

Map<String, Object?> _homePayload() => <String, Object?>{
  'primaryAction': <String, Object?>{
    'type': 'open_running_task',
    'label': 'Open running task',
    'taskId': 'task-1',
  },
  'hotspotSuggestion': <String, Object?>{
    'suggestionId': 'suggestion-1',
    'title': '今天值得关注的主题',
    'summary': '一条正式的首页推荐',
    'eventBrief': '事件概览',
    'discussionPoints': <Object?>['讨论点'],
    'topicAngles': <Object?>['选题角度'],
    'sourceName': '官方推荐',
  },
  'runningTasks': <Object?>[
    <String, Object?>{
      'taskId': 'task-1',
      'taskType': 'workspace_chat',
      'status': 'running',
      'retryable': false,
      'threadId': 'thread-1',
      'messageId': 'message-1',
    },
  ],
  'fileSummary': <String, Object?>{
    'recordingCount': 4,
    'depositedRecordingCount': 2,
  },
  'quotaSummary': <String, Object?>{
    'balances': <Object?>[
      <String, Object?>{'quotaType': 'generation', 'remainingAmount': 72},
    ],
  },
  'redDots': <Object?>[
    <String, Object?>{
      'scope': 'home_hotspot',
      'mergeKey': 'suggestion-1',
      'count': 1,
    },
  ],
  'serverTime': '2026-09-03T03:00:00Z',
};

ApiClient _client(ApiTransport transport) => ApiClientFactory.create(
  baseUrl: Uri.parse('https://api.example.test'),
  runtime: const ApiClientRuntime(
    clientVersion: 'test',
    deviceId: 'desktop-test',
    platform: 'macos',
    locale: 'zh-CN',
    timeZone: 'Asia/Shanghai',
  ),
  transport: transport,
  getAccessToken: () => 'access',
);

ApiTransportResponse _success(Object data) => ApiTransportResponse(
  status: 200,
  body: <String, Object?>{'success': true, 'data': data},
);

final class _QueueTransport implements ApiTransport {
  _QueueTransport(this._responses);

  final List<ApiTransportResponse> _responses;
  final requests = <ApiTransportRequest>[];

  @override
  Future<ApiTransportResponse> send(ApiTransportRequest request) async {
    requests.add(request);
    return _responses.removeAt(0);
  }
}
