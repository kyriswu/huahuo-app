import 'dart:convert';

import 'package:huahuo_api/huahuo_api.dart';
import 'package:test/test.dart';

void main() {
  test(
    'daily topic list, mutations, and use use only public transport',
    () async {
      final transport = _QueueTransport(<ApiTransportResponse>[
        ApiTransportResponse(status: 200, body: _envelope(_page())),
        ApiTransportResponse(
          status: 200,
          body: _envelope(<String, Object?>{
            'recommendation': _recommendation(),
          }),
        ),
        ApiTransportResponse(
          status: 200,
          body: _envelope(<String, Object?>{
            'recommendation': _recommendation(),
          }),
        ),
        ApiTransportResponse(
          status: 200,
          body: _envelope(<String, Object?>{
            'recommendationId': 'recommendation_1',
            'threadId': 'thread_1',
            'topicId': 'topic_1',
            'navigationTarget': <String, Object?>{
              'type': 'work_ai_thread',
              'threadId': 'thread_1',
            },
          }),
        ),
      ]);
      final client = DailyTopicRecommendationClient(_client(transport));

      final listed = await client.list('workspace_1');
      final read = await client.markRead(
        'workspace_1',
        'recommendation_1',
        etag: '"daily-1"',
        idempotencyKey: 'idem-read-1',
      );
      final dismissed = await client.dismiss(
        'workspace_1',
        'recommendation_1',
        etag: '"daily-1"',
        idempotencyKey: 'idem-dismiss-1',
      );
      final used = await client.use(
        'workspace_1',
        'recommendation_1',
        topicId: 'topic_1',
        idempotencyKey: 'idem-use-1',
      );

      expect(listed.ok, isTrue);
      expect(listed.data!.items.single.businessDate, '2026-08-14');
      final topic = listed.data!.items.single.topics.single;
      expect(topic.primarySupply, 'method');
      expect(topic.positioningMode, 'applied');
      expect(topic.audience, '需要稳定选题的创作者');
      expect(topic.contentPromise, '你可以借这条素材讲清选题判断方法');
      expect(topic.reasonMarkdown, '这条选题要讲：真实素材如何变成可用选题。');
      expect(topic.writingSketchMarkdown, '你可以这样写：1.摆素材 2.提问题 3.讲判断 4.给行动。');
      expect(topic.toJson()['contentPromise'], topic.contentPromise);
      expect(topic.toJson()['reasonMarkdown'], topic.reasonMarkdown);
      expect(
        topic.toJson()['writingSketchMarkdown'],
        topic.writingSketchMarkdown,
      );
      final sources = topic.sourceRefs;
      expect(sources, hasLength(2));
      final hotspot = sources.first as DailyTopicHotspotSourceRef;
      expect(hotspot.sourceId, 'hotspot_1');
      expect(hotspot.sourceUrl, 'https://example.test/hotspot/1?a=1');
      expect(hotspot.toJson(), <String, Object?>{
        'kind': 'daily_hotspot',
        'hotspotId': 'hotspot_1',
        'sourceUrl': 'https://example.test/hotspot/1?a=1',
        'label': '来源：公开热点',
      });
      final note = sources.last as DailyTopicWorkspaceNoteSourceRef;
      expect(note.kind, DailyTopicSourceKind.workspaceNote);
      expect(note.sourceId, 'workspace_note_1');
      expect(note.toJson(), <String, Object?>{
        'kind': 'workspace_note',
        'noteId': 'workspace_note_1',
        'label': '来源：工作区笔记',
      });
      expect(transport.requests[0].url.queryParameters['limit'], '100');
      expect(read.data!.readAt, isNotNull);
      expect(used.data!.threadId, 'thread_1');
      expect(
        transport.requests[0].url.path,
        '/api/v1/workspaces/workspace_1/topic-recommendations',
      );
      expect(transport.requests[0].url.queryParameters['status'], 'ready');
      expect(transport.requests[1].headers['If-Match'], '"daily-1"');
      expect(transport.requests[1].headers['X-Idempotency-Key'], 'idem-read-1');
      expect(jsonDecode(transport.requests[1].body!), <String, Object?>{});
      expect(dismissed.data!.recommendationId, 'recommendation_1');
      expect(
        transport.requests[2].url.path,
        '/api/v1/workspaces/workspace_1/topic-recommendations/recommendation_1/dismiss',
      );
      expect(transport.requests[2].headers['If-Match'], '"daily-1"');
      expect(
        transport.requests[2].headers['X-Idempotency-Key'],
        'idem-dismiss-1',
      );
      expect(jsonDecode(transport.requests[2].body!), <String, Object?>{});
      expect(jsonDecode(transport.requests[3].body!), <String, Object?>{
        'topicId': 'topic_1',
      });
      expect(
        jsonDecode(transport.requests[3].body!),
        isNot(contains('skillProfileIds')),
      );
    },
  );

  test('daily topic source union rejects unknown and mixed identities', () {
    for (final source in <Map<String, Object?>>[
      <String, Object?>{'kind': 'unknown', 'hotspotId': 'hotspot_1'},
      <String, Object?>{'kind': 'daily_hotspot'},
      <String, Object?>{
        'kind': 'daily_hotspot',
        'hotspotId': 'hotspot_1',
        'noteId': 'workspace_note_1',
      },
      <String, Object?>{
        'kind': 'daily_hotspot',
        'hotspotId': 'hotspot_1',
        'noteId': null,
      },
      <String, Object?>{
        'kind': 'workspace_note',
        'noteId': 'workspace_note_1',
        'sourceUrl': 'https://example.test/note',
      },
      <String, Object?>{
        'kind': 'workspace_note',
        'noteId': 'workspace_note_1',
        'sourceUrl': null,
      },
      <String, Object?>{
        'kind': 'daily_hotspot',
        'hotspotId': 'hotspot_1',
        'sourceUrl': 'file:///private/source',
      },
    ]) {
      expect(() => DailyTopicSourceRef.fromJson(source), throwsFormatException);
    }
  });

  test('daily topic rejects unknown classification values', () {
    final rawTopic = Map<String, Object?>.from(
      (_recommendation()['topics']! as List<Object?>).single!
          as Map<String, Object?>,
    );

    expect(
      () => DailyTopicItem.fromJson(<String, Object?>{
        ...rawTopic,
        'primarySupply': 'unknown',
      }),
      throwsFormatException,
    );
    expect(
      () => DailyTopicItem.fromJson(<String, Object?>{
        ...rawTopic,
        'positioningMode': 'unknown',
      }),
      throwsFormatException,
    );
  });
}

ApiClient _client(ApiTransport transport) => ApiClient(
  config: ApiClientConfig(
    baseUrl: Uri.parse('https://api.example.test'),
    clientVersion: 'test',
    deviceId: 'device_1',
    platform: 'ios',
    locale: 'zh-CN',
    getAccessToken: () => 'token_1',
  ),
  transport: transport,
);

Map<String, Object?> _envelope(Object data) => <String, Object?>{
  'success': true,
  'data': data,
};

Map<String, Object?> _page() => <String, Object?>{
  'items': <Object?>[_recommendation()],
};

Map<String, Object?> _recommendation() => <String, Object?>{
  'recommendationId': 'recommendation_1',
  'workspaceId': 'workspace_1',
  'businessDate': '2026-08-14',
  'recommendationKind': 'daily_topic_report',
  'status': 'ready',
  'title': '今日选题',
  'summaryMarkdown': '摘要',
  'etag': '"daily-1"',
  'readAt': '2026-08-14T00:00:00Z',
  'topics': <Object?>[
    <String, Object?>{
      'topicId': 'topic_1',
      'title': '主题',
      'briefMarkdown': '内容',
      'primarySupply': 'method',
      'positioningMode': 'applied',
      'audience': '需要稳定选题的创作者',
      'contentPromise': '你可以借这条素材讲清选题判断方法',
      'reasonMarkdown': '这条选题要讲：真实素材如何变成可用选题。',
      'writingSketchMarkdown': '你可以这样写：1.摆素材 2.提问题 3.讲判断 4.给行动。',
      'sourceRefs': <Object?>[
        <String, Object?>{
          'kind': 'daily_hotspot',
          'hotspotId': 'hotspot_1',
          'sourceUrl': 'https://example.test/hotspot/1?a=1',
          'label': '来源：公开热点',
        },
        <String, Object?>{
          'kind': 'workspace_note',
          'noteId': 'workspace_note_1',
          'label': '来源：工作区笔记',
        },
      ],
    },
  ],
};

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
