import 'package:huahuo_api/huahuo_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/features/ui_v3/data/hotspot_note_repository.dart';
import 'package:huahuoai_app/features/ui_v3/domain/feed_item_models.dart';

void main() {
  test('Home hotspot maps to a bounded read-only workbench note', () async {
    final transport = _HomeTransport(
      const ApiTransportResponse(
        status: 200,
        body: <String, Object?>{
          'success': true,
          'data': <String, Object?>{
            'serverTime': '2026-08-01T03:00:00Z',
            'hotspotSuggestion': <String, Object?>{
              'suggestionId': 'suggestion-home-1',
              'title': '真实热点标题',
              'summary': '热点推荐摘要',
              'eventBrief': '热点事件概览',
              'discussionPoints': <String>['讨论点一', '讨论点二'],
              'topicAngles': <String>['内容角度一'],
              'sourceName': 'douyin',
              'relativePath': '/private/server/hotspot.md',
              'prompt': 'hidden prompt',
            },
          },
        },
      ),
    );
    final notes = await ApiHotspotNoteRepository(
      _client(transport),
      now: () => DateTime.utc(2026, 8, 1),
    ).loadHotspots();

    expect(notes, hasLength(1));
    final note = notes.single;
    expect(note.id, 'suggestion-home-1');
    expect(note.title, '真实热点标题');
    expect(note.source, V3MaterialSource.hotspot);
    expect(note.ownership, V3NoteOwnership.hotspot);
    expect(note.rawBody, contains('热点事件概览'));
    expect(note.rawBody, contains('内容角度一'));
    expect(note.rawBody, isNot(contains('/private/server')));
    expect(note.rawBody, isNot(contains('hidden prompt')));
    expect(transport.requests, hasLength(1));
    expect(transport.requests.single.method, 'GET');
    expect(transport.requests.single.url.path, '/api/v1/home');
  });

  test('preserves production-length suggestion ids without truncation', () {
    final productionId = 'suggestion_${'a' * 121}';
    expect(productionId, hasLength(132));

    final notes = parseHomeHotspotNotes(<String, Object?>{
      'hotspotSuggestion': <String, Object?>{
        'suggestionId': productionId,
        'title': '生产热点',
        'summary': '保留完整标识。',
      },
    }, now: DateTime.utc(2026, 9, 2));

    expect(notes?.single.id, productionId);
    expect(
      parseHomeHotspotNotes(<String, Object?>{
        'hotspotSuggestion': <String, Object?>{
          'suggestionId': 's' * 513,
          'title': '无效热点',
          'summary': '超出标识边界。',
        },
      }, now: DateTime.utc(2026, 9, 2)),
      isNull,
    );
  });

  test('empty Home hotspot is a successful empty list', () async {
    final transport = _HomeTransport(
      const ApiTransportResponse(
        status: 200,
        body: <String, Object?>{
          'success': true,
          'data': <String, Object?>{'hotspotSuggestion': <String, Object?>{}},
        },
      ),
    );

    final notes = await ApiHotspotNoteRepository(
      _client(transport),
    ).loadHotspots();
    expect(notes, isEmpty);
  });

  test('malformed Home hotspot is a response contract failure', () async {
    final repository = ApiHotspotNoteRepository(
      _client(
        _HomeTransport(
          const ApiTransportResponse(
            status: 200,
            body: <String, Object?>{
              'success': true,
              'data': <String, Object?>{'hotspotSuggestion': <Object?>[]},
            },
          ),
        ),
      ),
    );

    await expectLater(
      repository.loadHotspots(),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'API_RESPONSE_INVALID',
        ),
      ),
    );
  });

  test('Home backend failure preserves its error code', () async {
    final repository = ApiHotspotNoteRepository(
      _client(
        _HomeTransport(
          const ApiTransportResponse(
            status: 503,
            body: <String, Object?>{
              'success': false,
              'error': <String, Object?>{
                'code': 'HOTSPOT_PIPELINE_UNAVAILABLE',
                'message': 'Hotspot pipeline unavailable',
              },
            },
          ),
        ),
      ),
    );

    await expectLater(
      repository.loadHotspots(),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'HOTSPOT_PIPELINE_UNAVAILABLE',
        ),
      ),
    );
  });
}

ApiClient _client(ApiTransport transport) => ApiClient(
  config: ApiClientConfig(
    baseUrl: Uri.parse('https://api.example.test'),
    clientVersion: 'test',
    deviceId: 'device-test',
    platform: 'ios',
    locale: 'zh-CN',
    getAccessToken: () => 'access-token',
  ),
  transport: transport,
);

final class _HomeTransport implements ApiTransport {
  _HomeTransport(this.response);

  final ApiTransportResponse response;
  final List<ApiTransportRequest> requests = <ApiTransportRequest>[];

  @override
  Future<ApiTransportResponse> send(ApiTransportRequest request) async {
    requests.add(request);
    return response;
  }
}
