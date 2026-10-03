import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/api/api_client.dart';
import 'package:huahuoai_app/core/native/voice_recorder_port.dart';
import 'package:huahuoai_app/features/ui_v3/data/voiceprint_api.dart';

void main() {
  group('GatewayVoiceprintApi', () {
    test('uploads verified WAV bytes with business authorization', () async {
      final sampleBytes = _voiceprintWav(seconds: 10);
      final transport = _GatewayTransport();
      final resolvedReferences = <String>[];
      final api = _api(
        transport: transport,
        sampleBytesResolver: (reference) async {
          resolvedReferences.add(reference);
          return sampleBytes;
        },
      );

      final result = await api.enroll(_enrollRequest(sampleBytes: sampleBytes));

      expect(result.ok, isTrue);
      expect(result.value?.profileId, 'vp-server-1');
      expect(result.value?.speakerNick, '我的声纹');
      expect(resolvedReferences, <String>['app-private://voice-sample.wav']);
      expect(transport.requests, hasLength(1));
      final request = transport.requests.single;
      expect(request.method, 'POST');
      expect(
        request.uri.toString(),
        'https://voice.example.test/v1/voiceprints',
      );
      expect(request.headers['authorization'], 'Bearer business-jwt');
      expect(request.headers['content-type'], 'audio/wav');
      expect(request.headers['X-Consent-Version'], voiceprintConsentVersion);
      expect(
        request.headers['X-Speaker-Nick'],
        matches(RegExp(r'^vpr-[a-f0-9]{20}$')),
      );
      expect(request.headers['X-Speaker-Nick'], isNot(contains('我的声纹')));
      expect(
        request.headers['X-Speaker-Display-Name'],
        Uri.encodeComponent('我的声纹'),
      );
      expect(
        request.headers['X-Idempotency-Key'],
        'idem-voiceprint-local-profile',
      );
      expect(request.body, orderedEquals(sampleBytes));
      expect(request.uri.toString(), isNot(contains('app-private')));
      expect(request.headers.values.join('\n'), isNot(contains('app-private')));
    });

    test('lists safe server profiles using GET', () async {
      final transport = _GatewayTransport(
        listBody: <String, Object?>{
          'profiles': <Object?>[
            _profilePayload(
              id: 'vp-server-older',
              registeredAt: '2026-07-20T02:00:00Z',
            ),
            _profilePayload(
              id: 'vp-server-newer',
              registeredAt: '2026-07-24T02:00:00Z',
            ),
          ],
        },
      );
      final api = _api(
        transport: transport,
        sampleBytesResolver: (_) async => Uint8List(0),
      );

      final result = await api.listProfiles();

      expect(result.ok, isTrue);
      expect(result.value?.map((profile) => profile.profileId), <String>[
        'vp-server-newer',
        'vp-server-older',
      ]);
      expect(transport.requests.single.method, 'GET');
      expect(transport.requests.single.body, isNull);
    });

    test('deletes the encoded server profile resource', () async {
      final transport = _GatewayTransport();
      final api = _api(
        transport: transport,
        sampleBytesResolver: (_) async => Uint8List(0),
      );

      final result = await api.deleteProfile(
        const VoiceprintDeleteRequest(
          profileId: 'vp:server:1',
          idempotencyKey: 'idem-delete-vp-server-1',
        ),
      );

      expect(result.ok, isTrue);
      expect(result.value?.profileId, 'vp:server:1');
      expect(transport.requests.single.method, 'DELETE');
      expect(
        transport.requests.single.uri.path,
        '/v1/voiceprints/vp%3Aserver%3A1',
      );
      expect(
        transport.requests.single.headers['X-Idempotency-Key'],
        'idem-delete-vp-server-1',
      );
    });

    test(
      'rerecord activates the new profile before deleting the old one',
      () async {
        final sampleBytes = _voiceprintWav(seconds: 10);
        final transport = _GatewayTransport();
        final api = _api(
          transport: transport,
          sampleBytesResolver: (_) async => sampleBytes,
        );

        final result = await api.enroll(
          _enrollRequest(
            sampleBytes: sampleBytes,
            replacementProfileId: 'vp-server-old',
          ),
        );

        expect(result.ok, isTrue);
        expect(
          transport.requests.map(
            (request) => '${request.method} ${request.uri.path}',
          ),
          <String>[
            'POST /v1/voiceprints',
            'DELETE /v1/voiceprints/vp-server-old',
          ],
        );
      },
    );

    test('failed old-profile deletion converges on idempotent retry', () async {
      final sampleBytes = _voiceprintWav(seconds: 10);
      final deleteStatuses = <String, int>{'vp-server-old': 503};
      final transport = _GatewayTransport(deleteStatuses: deleteStatuses);
      final api = _api(
        transport: transport,
        sampleBytesResolver: (_) async => sampleBytes,
      );
      final request = _enrollRequest(
        sampleBytes: sampleBytes,
        replacementProfileId: 'vp-server-old',
      );

      final result = await api.enroll(request);
      expect(result.ok, isFalse);
      expect(result.errorCode, 'VOICEPRINT_REPLACEMENT_DELETE_FAILED');
      expect(
        transport.requests.map(
          (request) => '${request.method} ${request.uri.path}',
        ),
        <String>[
          'POST /v1/voiceprints',
          'DELETE /v1/voiceprints/vp-server-old',
        ],
      );

      deleteStatuses['vp-server-old'] = 204;
      final retried = await api.enroll(request);
      expect(retried.ok, isTrue);
      expect(retried.value?.profileId, 'vp-server-1');
      expect(
        transport.requests
            .skip(2)
            .map((request) => '${request.method} ${request.uri.path}'),
        <String>[
          'POST /v1/voiceprints',
          'DELETE /v1/voiceprints/vp-server-old',
        ],
      );
    });

    test('rejects insecure gateway before token or sample access', () async {
      var tokenCalls = 0;
      var resolverCalls = 0;
      final transport = _GatewayTransport();
      final sampleBytes = _voiceprintWav(seconds: 10);
      final api = _api(
        transport: transport,
        gatewayBaseUrl: Uri.parse('http://voice.example.test/'),
        applicationToken: () async {
          tokenCalls += 1;
          return 'business-jwt';
        },
        sampleBytesResolver: (_) async {
          resolverCalls += 1;
          return sampleBytes;
        },
      );

      final result = await api.enroll(_enrollRequest(sampleBytes: sampleBytes));

      expect(result.errorCode, 'VOICEPRINT_SECURE_TRANSPORT_REQUIRED');
      expect(tokenCalls, 0);
      expect(resolverCalls, 0);
      expect(transport.requests, isEmpty);
    });

    test('rejects the legacy HTTP integration gateway', () async {
      final sampleBytes = _voiceprintWav(seconds: 10);
      final transport = _GatewayTransport();
      final api = _api(
        transport: transport,
        gatewayBaseUrl: Uri.parse('http://101.201.70.18/voice-gateway/'),
        sampleBytesResolver: (_) async => sampleBytes,
      );

      final result = await api.enroll(_enrollRequest(sampleBytes: sampleBytes));

      expect(result.errorCode, 'VOICEPRINT_SECURE_TRANSPORT_REQUIRED');
      expect(transport.requests, isEmpty);
    });

    test('unwraps a standard Huahuo success envelope', () async {
      final transport = _GatewayTransport(
        listBody: <String, Object?>{
          'success': true,
          'data': <String, Object?>{
            'profiles': <Object?>[_profilePayload()],
          },
        },
      );
      final api = _api(
        transport: transport,
        sampleBytesResolver: (_) async => Uint8List(0),
      );

      final result = await api.listProfiles();

      expect(result.ok, isTrue);
      expect(result.value?.single.profileId, 'vp-server-1');
    });

    test(
      'rejects insecure profile listing before token or transport',
      () async {
        var tokenCalls = 0;
        final transport = _GatewayTransport();
        final api = _api(
          transport: transport,
          gatewayBaseUrl: Uri.parse('http://voice.example.test/'),
          applicationToken: () async {
            tokenCalls += 1;
            return 'business-jwt';
          },
          sampleBytesResolver: (_) async => Uint8List(0),
        );

        final result = await api.listProfiles();

        expect(result.errorCode, 'VOICEPRINT_SECURE_TRANSPORT_REQUIRED');
        expect(tokenCalls, 0);
        expect(transport.requests, isEmpty);
      },
    );

    test(
      'rejects missing login token before resolving private bytes',
      () async {
        final sampleBytes = _voiceprintWav(seconds: 10);
        var resolverCalls = 0;
        final transport = _GatewayTransport();
        final api = _api(
          transport: transport,
          applicationToken: () async => null,
          sampleBytesResolver: (_) async {
            resolverCalls += 1;
            return sampleBytes;
          },
        );

        final result = await api.enroll(
          _enrollRequest(sampleBytes: sampleBytes),
        );

        expect(result.errorCode, 'UNAUTHORIZED');
        expect(resolverCalls, 0);
        expect(transport.requests, isEmpty);
      },
    );

    test('rejects provider identifiers in a successful response', () async {
      final sampleBytes = _voiceprintWav(seconds: 10);
      final unsafe = _profilePayload()..['VoicePrintId'] = 'provider-secret';
      final transport = _GatewayTransport(
        enrollBody: <String, Object?>{'profile': unsafe},
      );
      final api = _api(
        transport: transport,
        sampleBytesResolver: (_) async => sampleBytes,
      );

      final result = await api.enroll(_enrollRequest(sampleBytes: sampleBytes));

      expect(result.errorCode, 'VOICEPRINT_RESPONSE_INVALID');
      expect(result.value, isNull);
    });

    test('sanitizes gateway failure messages and payloads', () async {
      final sampleBytes = _voiceprintWav(seconds: 10);
      final transport = _GatewayTransport(
        enrollStatus: 502,
        enrollBody: <String, Object?>{
          'error': <String, Object?>{
            'code': 'TENCENT_PROVIDER_FAILURE',
            'message': '/Users/private/VoicePrintId leaked',
          },
        },
      );
      final api = _api(
        transport: transport,
        sampleBytesResolver: (_) async => sampleBytes,
      );

      final result = await api.enroll(_enrollRequest(sampleBytes: sampleBytes));

      expect(result.errorCode, 'VOICEPRINT_GATEWAY_REQUEST_FAILED');
      expect(result.error?.message, 'Voiceprint operation failed');
      expect(result.error?.metadata, isEmpty);
      expect(result.error?.cause, isNull);
    });

    test('rejects invalid metadata before resolving private bytes', () async {
      var resolverCalls = 0;
      final transport = _GatewayTransport();
      final sampleBytes = _voiceprintWav(seconds: 10);
      final api = _api(
        transport: transport,
        sampleBytesResolver: (_) async {
          resolverCalls += 1;
          return sampleBytes;
        },
      );

      final invalidFormat = await api.enroll(
        _enrollRequest(
          sampleBytes: sampleBytes,
          sample: _sample(
            sampleBytes,
            fileName: 'voice-sample.m4a',
            mimeType: 'audio/mp4',
          ),
        ),
      );
      final tooShort = await api.enroll(
        _enrollRequest(
          sampleBytes: sampleBytes,
          sample: _sample(sampleBytes, durationSeconds: 9),
        ),
      );
      final oversized = await api.enroll(
        _enrollRequest(
          sampleBytes: sampleBytes,
          sample: _sample(sampleBytes, sizeBytes: 2 * 1024 * 1024 + 1),
        ),
      );

      expect(invalidFormat.errorCode, 'VOICEPRINT_SAMPLE_FORMAT_INVALID');
      expect(tooShort.errorCode, 'VOICEPRINT_SAMPLE_DURATION_INVALID');
      expect(oversized.errorCode, 'VOICEPRINT_SAMPLE_SIZE_INVALID');
      expect(resolverCalls, 0);
      expect(transport.requests, isEmpty);
    });

    test('rejects byte length, hash, and WAV structure mismatches', () async {
      final valid = _voiceprintWav(seconds: 10);
      final transport = _GatewayTransport();

      final shortBytesApi = _api(
        transport: transport,
        sampleBytesResolver: (_) async => Uint8List(valid.length - 2),
      );
      final sizeResult = await shortBytesApi.enroll(
        _enrollRequest(sampleBytes: valid),
      );

      final changed = Uint8List.fromList(valid)..[44] = 1;
      final hashApi = _api(
        transport: transport,
        sampleBytesResolver: (_) async => changed,
      );
      final hashResult = await hashApi.enroll(
        _enrollRequest(sampleBytes: valid),
      );

      final malformed = Uint8List.fromList(valid)
        ..setRange(0, 4, ascii.encode('NOPE'));
      final malformedApi = _api(
        transport: transport,
        sampleBytesResolver: (_) async => malformed,
      );
      final formatResult = await malformedApi.enroll(
        _enrollRequest(sampleBytes: malformed, sample: _sample(malformed)),
      );

      expect(sizeResult.errorCode, 'VOICEPRINT_SAMPLE_SIZE_MISMATCH');
      expect(hashResult.errorCode, 'VOICEPRINT_SAMPLE_HASH_MISMATCH');
      expect(formatResult.errorCode, 'VOICEPRINT_SAMPLE_FORMAT_INVALID');
      expect(transport.requests, isEmpty);
    });

    test('rejects a ceil-rounded sub-10-second WAV before transport', () async {
      final almostTenSeconds = _voiceprintWav(
        seconds: 9,
        additionalSamples: voiceprintWavSampleRateHz - 1,
      );
      final transport = _GatewayTransport();
      final api = _api(
        transport: transport,
        sampleBytesResolver: (_) async => almostTenSeconds,
      );

      final result = await api.enroll(
        _enrollRequest(
          sampleBytes: almostTenSeconds,
          sample: _sample(almostTenSeconds, durationSeconds: 10),
        ),
      );

      expect(result.errorCode, 'VOICEPRINT_SAMPLE_DURATION_INVALID');
      expect(transport.requests, isEmpty);
    });

    test(
      'uploads a 10.1-second WAV with ceil-rounded 11-second metadata',
      () async {
        final tenPointOneSeconds = _voiceprintWav(
          seconds: 10,
          additionalSamples: voiceprintWavSampleRateHz ~/ 10,
        );
        final transport = _GatewayTransport();
        final api = _api(
          transport: transport,
          sampleBytesResolver: (_) async => tenPointOneSeconds,
        );

        final result = await api.enroll(
          _enrollRequest(
            sampleBytes: tenPointOneSeconds,
            sample: _sample(tenPointOneSeconds, durationSeconds: 11),
          ),
        );

        expect(result.ok, isTrue);
        expect(transport.requests, hasLength(1));
        expect(
          transport.requests.single.body,
          orderedEquals(tenPointOneSeconds),
        );
      },
    );
  });
}

GatewayVoiceprintApi _api({
  required _GatewayTransport transport,
  required VoiceprintSampleBytesResolver sampleBytesResolver,
  Uri? gatewayBaseUrl,
  Future<String?> Function()? applicationToken,
}) {
  final client = ApiClient(
    config: ApiClientConfig(
      baseUrl: Uri.parse('https://api.example.test'),
      clientVersion: 'test',
      deviceId: 'device-1',
      platform: 'test',
      locale: 'zh-CN',
      getAccessToken: applicationToken ?? () async => 'business-jwt',
    ),
    transport: _UnusedApiTransport(),
  );
  return GatewayVoiceprintApi(
    apiClient: client,
    gatewayBaseUrl: gatewayBaseUrl ?? Uri.parse('https://voice.example.test/'),
    sampleBytesResolver: sampleBytesResolver,
    transport: transport,
    requestTimeout: const Duration(seconds: 1),
  );
}

VoiceprintEnrollRequest _enrollRequest({
  required Uint8List sampleBytes,
  VoiceRecordingDraft? sample,
  String? replacementProfileId,
}) {
  return VoiceprintEnrollRequest(
    sample: sample ?? _sample(sampleBytes),
    profileId: 'local-profile-1',
    speakerNick: '我的声纹',
    consentVersion: voiceprintConsentVersion,
    idempotencyKey: 'idem-voiceprint-local-profile',
    replacementProfileId: replacementProfileId,
  );
}

VoiceRecordingDraft _sample(
  Uint8List bytes, {
  String fileName = 'voice-sample.wav',
  String mimeType = 'audio/wav',
  int? sizeBytes,
  int durationSeconds = 10,
}) {
  return VoiceRecordingDraft(
    recordingId: 'voice-sample-1',
    appPrivateUri: 'app-private://voice-sample.wav',
    fileName: fileName,
    mimeType: mimeType,
    sizeBytes: sizeBytes ?? bytes.length,
    durationSeconds: durationSeconds,
    sha256: sha256.convert(bytes).toString(),
    scene: VoiceRecordingScene.voiceprint,
    sampleRateHz: voiceprintWavSampleRateHz,
    bitDepth: voiceprintWavBitDepth,
    channelCount: voiceprintWavChannelCount,
    recordedAt: DateTime.utc(2026, 7, 24, 2),
  );
}

Map<String, Object?> _profilePayload({
  String id = 'vp-server-1',
  String registeredAt = '2026-07-24T02:00:00Z',
}) => <String, Object?>{
  'voiceprintProfileId': id,
  'speakerNick': '我的声纹',
  'consentVersion': voiceprintConsentVersion,
  'referenceDurationMilliseconds': 20000,
  'status': 'active',
  'registeredAt': registeredAt,
};

Uint8List _voiceprintWav({required int seconds, int additionalSamples = 0}) {
  final audioBytes =
      voiceprintWavSampleRateHz * 2 * seconds + additionalSamples * 2;
  final bytes = Uint8List(44 + audioBytes);
  final data = ByteData.sublistView(bytes);
  bytes.setRange(0, 4, ascii.encode('RIFF'));
  data.setUint32(4, bytes.length - 8, Endian.little);
  bytes.setRange(8, 12, ascii.encode('WAVE'));
  bytes.setRange(12, 16, ascii.encode('fmt '));
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, voiceprintWavSampleRateHz, Endian.little);
  data.setUint32(28, voiceprintWavSampleRateHz * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, voiceprintWavBitDepth, Endian.little);
  bytes.setRange(36, 40, ascii.encode('data'));
  data.setUint32(40, audioBytes, Endian.little);
  return bytes;
}

final class _GatewayTransport implements VoiceprintGatewayTransport {
  _GatewayTransport({
    Map<String, Object?>? enrollBody,
    Map<String, Object?>? listBody,
    this.enrollStatus = 200,
    this.deleteStatuses = const <String, int>{},
  }) : enrollBody =
           enrollBody ?? <String, Object?>{'profile': _profilePayload()},
       listBody =
           listBody ??
           <String, Object?>{
             'profiles': <Object?>[_profilePayload()],
           };

  final Map<String, Object?> enrollBody;
  final Map<String, Object?> listBody;
  final int enrollStatus;
  final Map<String, int> deleteStatuses;
  final List<VoiceprintGatewayRequest> requests = <VoiceprintGatewayRequest>[];

  @override
  Future<VoiceprintGatewayResponse> send(
    VoiceprintGatewayRequest request,
  ) async {
    requests.add(request);
    if (request.method == 'POST' &&
        request.uri.path.endsWith('/v1/voiceprints')) {
      return _response(enrollStatus, enrollBody);
    }
    if (request.method == 'GET' &&
        request.uri.path.endsWith('/v1/voiceprints')) {
      return _response(200, listBody);
    }
    if (request.method == 'DELETE') {
      final profileId = Uri.decodeComponent(request.uri.pathSegments.last);
      final status = deleteStatuses[profileId] ?? 204;
      return status >= 200 && status < 300
          ? VoiceprintGatewayResponse(statusCode: status, body: Uint8List(0))
          : _response(status, <String, Object?>{
              'error': <String, Object?>{
                'code': 'VOICEPRINT_DELETE_FAILED',
                'message': 'redacted',
              },
            });
    }
    throw StateError('Unexpected gateway request');
  }
}

VoiceprintGatewayResponse _response(int status, Map<String, Object?> body) {
  return VoiceprintGatewayResponse(
    statusCode: status,
    body: Uint8List.fromList(utf8.encode(jsonEncode(body))),
  );
}

final class _UnusedApiTransport implements ApiTransport {
  @override
  Future<ApiTransportResponse> send(ApiTransportRequest request) {
    throw StateError('Gateway voiceprint tests must not use ApiTransport');
  }
}
