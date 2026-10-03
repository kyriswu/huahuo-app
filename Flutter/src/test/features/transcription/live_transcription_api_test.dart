import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/api/api_client.dart';
import 'package:huahuoai_app/features/transcription/data/live_transcription_api.dart';

void main() {
  test('requests one authenticated direct Tencent SDK session', () async {
    final transport = _RecordingTransport(
      ApiTransportResponse(status: 200, body: _validResponse()),
    );
    final api = LiveTranscriptionApi(
      apiClient: _client(transport),
      backendBaseUrl: Uri.parse('https://api.example.test/'),
    );

    final result = await api.requestSessionCredential(
      voiceprintProfileId: 'vp_self',
    );

    expect(result.ok, isTrue);
    expect(result.data?.sessionId, 'live-session-1');
    expect(result.data?.appId, 123456789);
    expect(result.data?.projectId, 0);
    expect(result.data.toString(), 'LiveAsrSessionCredential([REDACTED])');
    expect(result.data.toString(), isNot(contains('tmp-secret-key')));
    expect(transport.requests, hasLength(1));
    final request = transport.requests.single;
    expect(request.method, 'POST');
    expect(request.url.path, '/api/v1/realtime-asr/sessions');
    expect(request.headers['Authorization'], 'Bearer access-token');
    final idempotencyKey = request.headers['X-Idempotency-Key'];
    expect(idempotencyKey, isNotNull);
    expect(idempotencyKey!.length, greaterThanOrEqualTo(16));
    expect(jsonDecode(request.body!) as Map<String, dynamic>, <String, Object?>{
      'voiceprintProfileId': 'vp_self',
    });
  });

  test('credential adapter requires a resolved backend injection', () async {
    final transport = _RecordingTransport(
      ApiTransportResponse(status: 200, body: _validResponse()),
    );
    final result = await LiveTranscriptionApi(
      apiClient: _client(transport),
    ).requestSessionCredential();

    expect(result.ok, isFalse);
    expect(result.error?.code, 'LIVE_ASR_BACKEND_NOT_READY');
    expect(transport.requests, isEmpty);
  });

  test(
    'completes an issued session through the same authenticated boundary',
    () async {
      final transport = _RecordingTransport(
        const ApiTransportResponse(status: 200, body: <String, Object?>{}),
      );
      final api = LiveTranscriptionApi(
        apiClient: _client(transport),
        backendBaseUrl: Uri.parse('https://api.example.test/'),
      );

      await api.completeSession('live-session-1');

      expect(transport.requests, hasLength(1));
      final request = transport.requests.single;
      expect(request.method, 'POST');
      expect(
        request.url.path,
        '/api/v1/realtime-asr/sessions/live-session-1/complete',
      );
      expect(request.headers['Authorization'], 'Bearer access-token');
      expect(
        request.headers['X-Idempotency-Key']?.length,
        greaterThanOrEqualTo(16),
      );
      expect(request.body, isNull);
    },
  );

  test('accepts HTTPS and rejects every insecure ASR origin', () async {
    final acceptedTransport = _RecordingTransport(
      ApiTransportResponse(status: 200, body: _validResponse()),
    );
    final accepted = await LiveTranscriptionApi(
      apiClient: _client(acceptedTransport),
      backendBaseUrl: Uri.parse('https://recording.chuda.cc'),
    ).requestSessionCredential();
    final transport = _RecordingTransport(
      ApiTransportResponse(status: 200, body: _validResponse()),
    );
    final insecure = await LiveTranscriptionApi(
      apiClient: _client(transport),
      backendBaseUrl: Uri.parse('http://api.example.test'),
    ).requestSessionCredential();
    final query = await LiveTranscriptionApi(
      apiClient: _client(transport),
      backendBaseUrl: Uri.parse('https://api.example.test/?token=forbidden'),
    ).requestSessionCredential();
    final alternatePort = await LiveTranscriptionApi(
      apiClient: _client(transport),
      backendBaseUrl: Uri.parse('http://101.201.70.18:18080'),
    ).requestSessionCredential();
    final lookalike = await LiveTranscriptionApi(
      apiClient: _client(transport),
      backendBaseUrl: Uri.parse('http://101.201.70.18.example.test'),
    ).requestSessionCredential();

    expect(accepted.ok, isTrue);
    expect(acceptedTransport.requests, hasLength(1));
    expect(insecure.error?.code, 'ASR_CREDENTIAL_HTTPS_REQUIRED');
    expect(query.error?.code, 'ASR_CREDENTIAL_HTTPS_REQUIRED');
    expect(alternatePort.error?.code, 'ASR_CREDENTIAL_HTTPS_REQUIRED');
    expect(lookalike.error?.code, 'ASR_CREDENTIAL_HTTPS_REQUIRED');
    expect(transport.requests, isEmpty);
  });

  test(
    'rejects malformed STS responses and unsafe voiceprint profile ids',
    () async {
      final invalid = Map<String, Object?>.from(_validResponse());
      invalid['temporaryCredential'] = <String, Object?>{
        'tmpSecretId': 'tmp-secret-id',
        'tmpSecretKey': 'tmp-secret-key',
        'token': 'contains a space',
      };
      expect(parseLiveAsrSessionCredential(invalid), isNull);

      final transport = _RecordingTransport(
        const ApiTransportResponse(status: 500, body: null),
      );
      final result = await LiveTranscriptionApi(
        apiClient: _client(transport),
        backendBaseUrl: Uri.parse('https://api.example.test/'),
      ).requestSessionCredential(voiceprintProfileId: '../another-user');

      expect(result.error?.code, 'LIVE_ASR_VOICEPRINT_PROFILE_INVALID');
      expect(transport.requests, isEmpty);
    },
  );

  test(
    'contains token-provider exceptions without exposing the exception text',
    () async {
      final transport = _RecordingTransport(
        const ApiTransportResponse(status: 500, body: null),
      );
      final result = await LiveTranscriptionApi(
        apiClient: _client(transport),
        backendBaseUrl: Uri.parse('https://api.example.test/'),
        applicationToken: () => throw StateError('source-secret-value'),
      ).requestSessionCredential();

      expect(result.error?.code, 'AUTH_TOKEN_READ_FAILED');
      expect(result.error.toString(), isNot(contains('source-secret-value')));
      expect(transport.requests, isEmpty);
    },
  );
}

Map<String, Object?> _validResponse() => <String, Object?>{
  'sessionId': 'live-session-1',
  'appId': 123456789,
  'projectId': 0,
  'expiresAt': '2030-07-29T12:15:00Z',
  'temporaryCredential': <String, Object?>{
    'tmpSecretId': 'tmp-secret-id',
    'tmpSecretKey': 'tmp-secret-key',
    'token': 'tmp-token',
  },
};

ApiClient _client(ApiTransport transport) {
  return ApiClient(
    config: ApiClientConfig(
      baseUrl: Uri.parse('https://api.example.test'),
      clientVersion: 'test',
      deviceId: 'device-1',
      platform: 'ios',
      locale: 'zh-CN',
      getAccessToken: () => 'access-token',
    ),
    transport: transport,
  );
}

final class _RecordingTransport implements ApiTransport {
  _RecordingTransport(this.response);

  final ApiTransportResponse response;
  final List<ApiTransportRequest> requests = <ApiTransportRequest>[];

  @override
  Future<ApiTransportResponse> send(ApiTransportRequest request) async {
    requests.add(request);
    return response;
  }
}
