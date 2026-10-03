import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../../../core/api/api_client.dart';
import '../../../core/api/api_envelope.dart';
import '../../../core/api/idempotency.dart';
import '../../../core/api/upload_client.dart';
import '../../../core/native/voice_recorder_port.dart';

const voiceprintConsentVersion = '2026-07-v1';
const _voiceprintMinimumDurationMilliseconds =
    voiceprintWavMinimumSeconds * 1000;
const _voiceprintMaximumDurationMilliseconds =
    voiceprintWavMaximumSeconds * 1000 + 500;

typedef VoiceprintPollDelay = Future<void> Function(Duration duration);

enum VoiceprintRemoteProfileStatus { pending, active, revoked, deleted }

enum VoiceprintRemoteTaskStatus { queued, processing, succeeded, failed }

final class VoiceprintRemoteProfile {
  const VoiceprintRemoteProfile({
    required this.profileId,
    required this.speakerNick,
    required this.status,
    required this.referenceVersion,
    required this.registeredAt,
    required this.updatedAt,
  });

  final String profileId;
  final String speakerNick;
  final VoiceprintRemoteProfileStatus status;
  final int referenceVersion;
  final DateTime registeredAt;
  final DateTime updatedAt;

  bool get isActive => status == VoiceprintRemoteProfileStatus.active;
}

final class VoiceprintRemoteTask {
  const VoiceprintRemoteTask({
    required this.taskId,
    required this.status,
    this.profile,
    this.errorCode,
  });

  final String taskId;
  final VoiceprintRemoteTaskStatus status;
  final VoiceprintRemoteProfile? profile;
  final String? errorCode;

  bool get isTerminal =>
      status == VoiceprintRemoteTaskStatus.succeeded ||
      status == VoiceprintRemoteTaskStatus.failed;
}

final class VoiceprintDeleteReceipt {
  const VoiceprintDeleteReceipt({required this.profileId, this.deletedAt});

  final String profileId;
  final DateTime? deletedAt;
}

final class VoiceprintEnrollRequest {
  const VoiceprintEnrollRequest({
    required this.sample,
    required this.profileId,
    required this.speakerNick,
    required this.consentVersion,
    required this.idempotencyKey,
    this.replacementProfileId,
  });

  final VoiceRecordingDraft sample;
  final String profileId;
  final String speakerNick;
  final String consentVersion;
  final String idempotencyKey;
  final String? replacementProfileId;
}

final class VoiceprintDeleteRequest {
  const VoiceprintDeleteRequest({
    required this.profileId,
    required this.idempotencyKey,
  });

  final String profileId;
  final String idempotencyKey;
}

final class VoiceprintApiResult<T> {
  const VoiceprintApiResult._({required this.ok, this.value, this.error});

  factory VoiceprintApiResult.success(T value) {
    return VoiceprintApiResult<T>._(ok: true, value: value);
  }

  factory VoiceprintApiResult.failure(AppFailure error) {
    return VoiceprintApiResult<T>._(ok: false, error: error);
  }

  final bool ok;
  final T? value;
  final AppFailure? error;

  String? get errorCode => error?.code;
}

abstract interface class VoiceprintApiPort {
  Future<VoiceprintApiResult<List<VoiceprintRemoteProfile>>> listProfiles();

  Future<VoiceprintApiResult<VoiceprintRemoteProfile>> enroll(
    VoiceprintEnrollRequest request,
  );

  Future<VoiceprintApiResult<VoiceprintDeleteReceipt>> deleteProfile(
    VoiceprintDeleteRequest request,
  );
}

final class RemoteVoiceprintApi implements VoiceprintApiPort {
  RemoteVoiceprintApi({
    required this.apiClient,
    required this.uploadClient,
    this.maxPollAttempts = 8,
    this.pollInterval = const Duration(milliseconds: 400),
    VoiceprintPollDelay? delay,
  }) : assert(maxPollAttempts > 0),
       _delay = delay ?? _defaultPollDelay;

  final ApiClient apiClient;
  final UploadClient uploadClient;
  final int maxPollAttempts;
  final Duration pollInterval;
  final VoiceprintPollDelay _delay;

  static const _listEndpoint = 'myVoiceprint';
  static const _createEndpoint = 'createMyVoiceprint';
  static const _deleteEndpoint = 'deleteMyVoiceprint';
  static const _taskEndpoint = 'myVoiceprintTask';

  @override
  Future<VoiceprintApiResult<List<VoiceprintRemoteProfile>>>
  listProfiles() async {
    if (!_usesSecureApiTransport) {
      return VoiceprintApiResult<List<VoiceprintRemoteProfile>>.failure(
        voiceprintApiFailure('VOICEPRINT_SECURE_TRANSPORT_REQUIRED'),
      );
    }
    final result = await apiClient.request<List<VoiceprintRemoteProfile>>(
      const ApiRequestOptions<List<VoiceprintRemoteProfile>>(
        endpointId: _listEndpoint,
        parseData: parseLegacyVoiceprintProfileList,
      ),
    );
    if (!result.ok || result.data == null) {
      return VoiceprintApiResult<List<VoiceprintRemoteProfile>>.failure(
        _safeBoundaryFailure(
          result.error,
          fallbackCode: 'VOICEPRINT_LIST_FAILED',
          retryable: true,
        ),
      );
    }
    return VoiceprintApiResult<List<VoiceprintRemoteProfile>>.success(
      result.data!,
    );
  }

  @override
  Future<VoiceprintApiResult<VoiceprintRemoteProfile>> enroll(
    VoiceprintEnrollRequest request,
  ) async {
    if (!_usesSecureApiTransport) {
      return VoiceprintApiResult<VoiceprintRemoteProfile>.failure(
        voiceprintApiFailure('VOICEPRINT_SECURE_TRANSPORT_REQUIRED'),
      );
    }
    final requestError = _validateEnrollRequest(request);
    if (requestError != null) {
      return VoiceprintApiResult<VoiceprintRemoteProfile>.failure(requestError);
    }

    final metadata = UploadMetadata(
      sourceScene: 'voiceprint',
      fileName: request.sample.fileName,
      mimeType: request.sample.mimeType,
      sizeBytes: request.sample.sizeBytes,
      durationSeconds: request.sample.durationSeconds,
      appPrivateUri: request.sample.appPrivateUri,
      sha256: request.sample.sha256,
    );
    final tokenResult = await uploadClient.requestUploadToken(
      metadata: metadata,
      idempotencyKey: _operationKey(request.idempotencyKey, 'upload-token'),
    );
    final token = tokenResult.value;
    if (!tokenResult.ok || token == null) {
      return VoiceprintApiResult<VoiceprintRemoteProfile>.failure(
        _safeBoundaryFailure(
          tokenResult.error,
          fallbackCode: 'VOICEPRINT_UPLOAD_TOKEN_FAILED',
          retryable: true,
        ),
      );
    }
    if (token.uploadUrl.scheme.toLowerCase() != 'https') {
      return VoiceprintApiResult<VoiceprintRemoteProfile>.failure(
        voiceprintApiFailure('VOICEPRINT_SECURE_TRANSPORT_REQUIRED'),
      );
    }

    final uploadResult = await uploadClient.uploadToObjectStore(
      token: token,
      metadata: metadata,
    );
    if (!uploadResult.ok) {
      return VoiceprintApiResult<VoiceprintRemoteProfile>.failure(
        _safeBoundaryFailure(
          uploadResult.error,
          fallbackCode: 'VOICEPRINT_OBJECT_UPLOAD_FAILED',
          retryable: true,
        ),
      );
    }

    final completeResult = await uploadClient.completeUpload(
      uploadId: token.uploadId,
      metadata: metadata,
      idempotencyKey: _operationKey(request.idempotencyKey, 'upload-complete'),
    );
    final resource = completeResult.value;
    if (!completeResult.ok || resource == null) {
      return VoiceprintApiResult<VoiceprintRemoteProfile>.failure(
        _safeBoundaryFailure(
          completeResult.error,
          fallbackCode: 'VOICEPRINT_UPLOAD_COMPLETE_FAILED',
          retryable: true,
        ),
      );
    }

    final createResult = await apiClient.request<_VoiceprintCreateResponse>(
      ApiRequestOptions<_VoiceprintCreateResponse>(
        endpointId: _createEndpoint,
        body: <String, Object?>{
          'resourceId': resource.resourceId,
          'profileId': request.profileId,
          'speakerNick': request.speakerNick.trim(),
          'consentVersion': request.consentVersion,
        },
        idempotency: IdempotencyRequestContext(
          explicitKey: _operationKey(request.idempotencyKey, 'create'),
        ),
        parseData: (value) => _parseVoiceprintCreateResponse(
          value,
          expectedProfileId: request.profileId,
          fallbackSpeakerNick: request.speakerNick.trim(),
        ),
      ),
    );
    final created = createResult.data;
    if (!createResult.ok || created == null) {
      return VoiceprintApiResult<VoiceprintRemoteProfile>.failure(
        _safeBoundaryFailure(
          createResult.error,
          fallbackCode: 'VOICEPRINT_ENROLL_FAILED',
          retryable: true,
        ),
      );
    }

    final synchronousProfile = created.profile;
    if (synchronousProfile != null) {
      return synchronousProfile.isActive
          ? VoiceprintApiResult<VoiceprintRemoteProfile>.success(
              synchronousProfile,
            )
          : VoiceprintApiResult<VoiceprintRemoteProfile>.failure(
              voiceprintApiFailure('VOICEPRINT_ENROLL_PENDING_WITHOUT_TASK'),
            );
    }
    final task = created.task;
    if (task == null) {
      return VoiceprintApiResult<VoiceprintRemoteProfile>.failure(
        voiceprintApiFailure('VOICEPRINT_RESPONSE_INVALID'),
      );
    }
    if (task.status == VoiceprintRemoteTaskStatus.failed) {
      return VoiceprintApiResult<VoiceprintRemoteProfile>.failure(
        voiceprintApiFailure(_publicTaskError(task.errorCode)),
      );
    }
    if (task.status == VoiceprintRemoteTaskStatus.succeeded &&
        task.profile != null &&
        task.profile!.isActive) {
      return VoiceprintApiResult<VoiceprintRemoteProfile>.success(
        task.profile!,
      );
    }
    return _pollTask(
      task.taskId,
      expectedProfileId: request.profileId,
      fallbackSpeakerNick: request.speakerNick.trim(),
    );
  }

  @override
  Future<VoiceprintApiResult<VoiceprintDeleteReceipt>> deleteProfile(
    VoiceprintDeleteRequest request,
  ) async {
    if (!_usesSecureApiTransport) {
      return VoiceprintApiResult<VoiceprintDeleteReceipt>.failure(
        voiceprintApiFailure('VOICEPRINT_SECURE_TRANSPORT_REQUIRED'),
      );
    }
    if (!_safeId(request.profileId) ||
        !_safeIdempotencyKey(request.idempotencyKey)) {
      return VoiceprintApiResult<VoiceprintDeleteReceipt>.failure(
        voiceprintApiFailure('VOICEPRINT_REQUEST_INVALID'),
      );
    }
    final result = await apiClient.request<VoiceprintDeleteReceipt>(
      ApiRequestOptions<VoiceprintDeleteReceipt>(
        endpointId: _deleteEndpoint,
        body: <String, Object?>{'profileId': request.profileId},
        idempotency: IdempotencyRequestContext(
          explicitKey: request.idempotencyKey,
        ),
        parseData: (value) => parseVoiceprintDeleteReceipt(
          value,
          expectedProfileId: request.profileId,
        ),
      ),
    );
    if (!result.ok || result.data == null) {
      return VoiceprintApiResult<VoiceprintDeleteReceipt>.failure(
        _safeBoundaryFailure(
          result.error,
          fallbackCode: 'VOICEPRINT_DELETE_FAILED',
          retryable: true,
        ),
      );
    }
    return VoiceprintApiResult<VoiceprintDeleteReceipt>.success(result.data!);
  }

  bool get _usesSecureApiTransport =>
      apiClient.config.baseUrl.scheme.toLowerCase() == 'https';

  Future<VoiceprintApiResult<VoiceprintRemoteProfile>> _pollTask(
    String taskId, {
    required String expectedProfileId,
    required String fallbackSpeakerNick,
  }) async {
    for (var attempt = 0; attempt < maxPollAttempts; attempt += 1) {
      await _delay(pollInterval);
      final result = await apiClient.request<VoiceprintRemoteTask>(
        ApiRequestOptions<VoiceprintRemoteTask>(
          endpointId: _taskEndpoint,
          pathParams: <String, Object>{'taskId': taskId},
          parseData: (value) => parseVoiceprintTask(
            value,
            expectedTaskId: taskId,
            expectedProfileId: expectedProfileId,
            fallbackSpeakerNick: fallbackSpeakerNick,
          ),
        ),
      );
      final task = result.data;
      if (!result.ok || task == null) {
        return VoiceprintApiResult<VoiceprintRemoteProfile>.failure(
          _safeBoundaryFailure(
            result.error,
            fallbackCode: 'VOICEPRINT_TASK_POLL_FAILED',
            retryable: true,
          ),
        );
      }
      if (task.status == VoiceprintRemoteTaskStatus.failed) {
        return VoiceprintApiResult<VoiceprintRemoteProfile>.failure(
          voiceprintApiFailure(_publicTaskError(task.errorCode)),
        );
      }
      if (task.status == VoiceprintRemoteTaskStatus.succeeded) {
        final profile = task.profile;
        if (profile == null || !profile.isActive) {
          return VoiceprintApiResult<VoiceprintRemoteProfile>.failure(
            voiceprintApiFailure('VOICEPRINT_RESPONSE_INVALID'),
          );
        }
        return VoiceprintApiResult<VoiceprintRemoteProfile>.success(profile);
      }
    }
    return VoiceprintApiResult<VoiceprintRemoteProfile>.failure(
      voiceprintApiFailure('VOICEPRINT_TASK_POLL_TIMEOUT', retryable: true),
    );
  }
}

typedef VoiceprintSampleBytesResolver =
    Future<Uint8List> Function(String appPrivateUri);

final class VoiceprintGatewayRequest {
  const VoiceprintGatewayRequest({
    required this.method,
    required this.uri,
    required this.headers,
    this.body,
  });

  final String method;
  final Uri uri;
  final Map<String, String> headers;
  final Uint8List? body;
}

final class VoiceprintGatewayResponse {
  const VoiceprintGatewayResponse({
    required this.statusCode,
    required this.body,
  });

  final int statusCode;
  final Uint8List body;
}

abstract interface class VoiceprintGatewayTransport {
  Future<VoiceprintGatewayResponse> send(VoiceprintGatewayRequest request);
}

final class HttpVoiceprintGatewayTransport
    implements VoiceprintGatewayTransport {
  HttpVoiceprintGatewayTransport({
    HttpClient? httpClient,
    this.maximumResponseBytes = 1024 * 1024,
  }) : _httpClient = httpClient ?? HttpClient();

  final HttpClient _httpClient;
  final int maximumResponseBytes;

  @override
  Future<VoiceprintGatewayResponse> send(
    VoiceprintGatewayRequest request,
  ) async {
    final outbound = await _httpClient.openUrl(request.method, request.uri);
    outbound.followRedirects = false;
    for (final header in request.headers.entries) {
      outbound.headers.set(header.key, header.value);
    }
    final body = request.body;
    if (body != null) {
      outbound.contentLength = body.length;
      outbound.add(body);
    }
    final response = await outbound.close();
    final builder = BytesBuilder(copy: false);
    var length = 0;
    await for (final chunk in response) {
      length += chunk.length;
      if (length > maximumResponseBytes) {
        throw const FormatException('Voiceprint gateway response is too large');
      }
      builder.add(chunk);
    }
    return VoiceprintGatewayResponse(
      statusCode: response.statusCode,
      body: builder.takeBytes(),
    );
  }
}

/// Production adapter for the first-party voice gateway. It never sends an
/// app-private reference, filesystem path, or Tencent credential over HTTP.
final class GatewayVoiceprintApi implements VoiceprintApiPort {
  GatewayVoiceprintApi({
    required ApiClient apiClient,
    required VoiceprintSampleBytesResolver sampleBytesResolver,
    Uri? gatewayBaseUrl,
    VoiceprintGatewayTransport? transport,
    this.requestTimeout = const Duration(seconds: 30),
  }) : _apiClient = apiClient,
       _sampleBytesResolver = sampleBytesResolver,
       _gatewayBaseUrl = _normalizeGatewayBaseUrl(
         gatewayBaseUrl ?? apiClient.config.baseUrl,
       ),
       _transport = transport ?? HttpVoiceprintGatewayTransport();

  final ApiClient _apiClient;
  final VoiceprintSampleBytesResolver _sampleBytesResolver;
  final Uri _gatewayBaseUrl;
  final VoiceprintGatewayTransport _transport;
  final Duration requestTimeout;

  @override
  Future<VoiceprintApiResult<List<VoiceprintRemoteProfile>>>
  listProfiles() async {
    final response = await _request(
      method: 'GET',
      relativePath: 'v1/voiceprints',
    );
    if (!response.ok || response.response == null) {
      return VoiceprintApiResult<List<VoiceprintRemoteProfile>>.failure(
        response.error ?? voiceprintApiFailure('VOICEPRINT_LIST_FAILED'),
      );
    }
    final object = _decodeGatewayObject(response.response!.body);
    final rawProfiles = object?['profiles'];
    if (object == null ||
        _containsSensitiveData(object) ||
        rawProfiles is! List) {
      return VoiceprintApiResult<List<VoiceprintRemoteProfile>>.failure(
        voiceprintApiFailure('VOICEPRINT_RESPONSE_INVALID'),
      );
    }
    final profiles = <VoiceprintRemoteProfile>[];
    for (final value in rawProfiles) {
      final profile = parseGatewayVoiceprintProfile(value);
      if (profile == null) {
        return VoiceprintApiResult<List<VoiceprintRemoteProfile>>.failure(
          voiceprintApiFailure('VOICEPRINT_RESPONSE_INVALID'),
        );
      }
      profiles.add(profile);
    }
    profiles.sort((left, right) => right.updatedAt.compareTo(left.updatedAt));
    return VoiceprintApiResult<List<VoiceprintRemoteProfile>>.success(
      List<VoiceprintRemoteProfile>.unmodifiable(profiles),
    );
  }

  @override
  Future<VoiceprintApiResult<VoiceprintRemoteProfile>> enroll(
    VoiceprintEnrollRequest request,
  ) async {
    if (!_secureGatewayConfiguration(_gatewayBaseUrl)) {
      return VoiceprintApiResult<VoiceprintRemoteProfile>.failure(
        voiceprintApiFailure('VOICEPRINT_SECURE_TRANSPORT_REQUIRED'),
      );
    }
    final requestError = _validateEnrollRequest(request);
    if (requestError != null) {
      return VoiceprintApiResult<VoiceprintRemoteProfile>.failure(requestError);
    }

    final applicationToken = await _loadApplicationToken();
    if (applicationToken == null) {
      return VoiceprintApiResult<VoiceprintRemoteProfile>.failure(
        voiceprintApiFailure('UNAUTHORIZED'),
      );
    }

    Uint8List sampleBytes;
    try {
      sampleBytes = await _sampleBytesResolver(request.sample.appPrivateUri);
    } catch (_) {
      return VoiceprintApiResult<VoiceprintRemoteProfile>.failure(
        voiceprintApiFailure('VOICEPRINT_SAMPLE_READ_FAILED', retryable: true),
      );
    }
    final sampleError = _validateResolvedVoiceprintSample(
      request.sample,
      sampleBytes,
    );
    if (sampleError != null) {
      return VoiceprintApiResult<VoiceprintRemoteProfile>.failure(sampleError);
    }

    final response = await _request(
      method: 'POST',
      relativePath: 'v1/voiceprints',
      headers: <String, String>{
        HttpHeaders.contentTypeHeader: 'audio/wav',
        'X-Consent-Version': request.consentVersion,
        'X-Speaker-Nick': _gatewaySpeakerReference(request.profileId),
        'X-Speaker-Display-Name': Uri.encodeComponent(
          request.speakerNick.trim(),
        ),
        'X-Idempotency-Key': request.idempotencyKey,
      },
      body: sampleBytes,
      applicationToken: applicationToken,
    );
    if (!response.ok || response.response == null) {
      return VoiceprintApiResult<VoiceprintRemoteProfile>.failure(
        response.error ?? voiceprintApiFailure('VOICEPRINT_ENROLL_FAILED'),
      );
    }
    final object = _decodeGatewayObject(response.response!.body);
    if (object == null || _containsSensitiveData(object)) {
      return VoiceprintApiResult<VoiceprintRemoteProfile>.failure(
        voiceprintApiFailure('VOICEPRINT_RESPONSE_INVALID'),
      );
    }
    final parsed = parseGatewayVoiceprintProfile(
      object['profile'] ?? object,
      fallbackSpeakerNick: request.speakerNick.trim(),
    );
    if (parsed == null || !parsed.isActive) {
      return VoiceprintApiResult<VoiceprintRemoteProfile>.failure(
        voiceprintApiFailure('VOICEPRINT_RESPONSE_INVALID'),
      );
    }
    final profile = VoiceprintRemoteProfile(
      profileId: parsed.profileId,
      speakerNick: request.speakerNick.trim(),
      status: parsed.status,
      referenceVersion: parsed.referenceVersion,
      registeredAt: parsed.registeredAt,
      updatedAt: parsed.updatedAt,
    );

    final oldProfileId = request.replacementProfileId;
    if (oldProfileId != null && oldProfileId != profile.profileId) {
      final removedOld = await _deleteProfileById(
        oldProfileId,
        idempotencyKey: _derivedGatewayOperationKey(
          request.idempotencyKey,
          'replace-old',
        ),
      );
      if (!removedOld.ok) {
        return VoiceprintApiResult<VoiceprintRemoteProfile>.failure(
          voiceprintApiFailure(
            'VOICEPRINT_REPLACEMENT_DELETE_FAILED',
            retryable: true,
          ),
        );
      }
    }
    return VoiceprintApiResult<VoiceprintRemoteProfile>.success(profile);
  }

  @override
  Future<VoiceprintApiResult<VoiceprintDeleteReceipt>> deleteProfile(
    VoiceprintDeleteRequest request,
  ) async {
    if (!_safeId(request.profileId) ||
        !_safeIdempotencyKey(request.idempotencyKey)) {
      return VoiceprintApiResult<VoiceprintDeleteReceipt>.failure(
        voiceprintApiFailure('VOICEPRINT_REQUEST_INVALID'),
      );
    }
    return _deleteProfileById(
      request.profileId,
      idempotencyKey: request.idempotencyKey,
    );
  }

  Future<VoiceprintApiResult<VoiceprintDeleteReceipt>> _deleteProfileById(
    String profileId, {
    required String idempotencyKey,
  }) async {
    final response = await _request(
      method: 'DELETE',
      relativePath: 'v1/voiceprints/${Uri.encodeComponent(profileId.trim())}',
      headers: <String, String>{'X-Idempotency-Key': idempotencyKey},
      acceptNotFound: true,
    );
    if (!response.ok || response.response == null) {
      return VoiceprintApiResult<VoiceprintDeleteReceipt>.failure(
        response.error ?? voiceprintApiFailure('VOICEPRINT_DELETE_FAILED'),
      );
    }
    DateTime? deletedAt;
    if (response.response!.body.isNotEmpty) {
      final object = _decodeGatewayObject(response.response!.body);
      if (object == null || _containsSensitiveData(object)) {
        return VoiceprintApiResult<VoiceprintDeleteReceipt>.failure(
          voiceprintApiFailure('VOICEPRINT_RESPONSE_INVALID'),
        );
      }
      final rawDeletedAt = object['deletedAt'];
      if (rawDeletedAt != null) {
        deletedAt = _safeDate(rawDeletedAt);
        if (deletedAt == null) {
          return VoiceprintApiResult<VoiceprintDeleteReceipt>.failure(
            voiceprintApiFailure('VOICEPRINT_RESPONSE_INVALID'),
          );
        }
      }
    }
    return VoiceprintApiResult<VoiceprintDeleteReceipt>.success(
      VoiceprintDeleteReceipt(profileId: profileId, deletedAt: deletedAt),
    );
  }

  Future<_VoiceprintGatewayCall> _request({
    required String method,
    required String relativePath,
    Map<String, String> headers = const <String, String>{},
    Uint8List? body,
    bool acceptNotFound = false,
    String? applicationToken,
  }) async {
    if (!_secureGatewayConfiguration(_gatewayBaseUrl)) {
      return _VoiceprintGatewayCall.failure(
        voiceprintApiFailure('VOICEPRINT_SECURE_TRANSPORT_REQUIRED'),
      );
    }
    final token = applicationToken ?? await _loadApplicationToken();
    if (token == null) {
      return _VoiceprintGatewayCall.failure(
        voiceprintApiFailure('UNAUTHORIZED'),
      );
    }
    try {
      _debugVoiceprintGateway(stage: 'requesting', method: method);
      final response = await _transport
          .send(
            VoiceprintGatewayRequest(
              method: method,
              uri: _gatewayBaseUrl.resolve(relativePath),
              headers: <String, String>{
                HttpHeaders.authorizationHeader: 'Bearer $token',
                HttpHeaders.acceptHeader: 'application/json',
                ...headers,
              },
              body: body,
            ),
          )
          .timeout(requestTimeout);
      _debugVoiceprintGateway(
        stage: 'response',
        method: method,
        status: response.statusCode,
      );
      final successful =
          response.statusCode >= 200 && response.statusCode < 300;
      if (successful || (acceptNotFound && response.statusCode == 404)) {
        return _VoiceprintGatewayCall.success(response);
      }
      final failure = _gatewayResponseFailure(response);
      return _VoiceprintGatewayCall.failure(failure);
    } catch (cause) {
      _debugVoiceprintGateway(
        stage: 'network_failure',
        method: method,
        causeType: cause.runtimeType.toString(),
      );
      return _VoiceprintGatewayCall.failure(
        voiceprintApiFailure('NETWORK_REQUEST_FAILED', retryable: true),
      );
    }
  }

  Future<String?> _loadApplicationToken() async {
    try {
      final token = (await _apiClient.config.getAccessToken?.call())?.trim();
      return _safeApplicationToken(token) ? token : null;
    } catch (_) {
      return null;
    }
  }
}

final class _VoiceprintGatewayCall {
  const _VoiceprintGatewayCall._({required this.ok, this.response, this.error});

  factory _VoiceprintGatewayCall.success(VoiceprintGatewayResponse response) =>
      _VoiceprintGatewayCall._(ok: true, response: response);

  factory _VoiceprintGatewayCall.failure(AppFailure error) =>
      _VoiceprintGatewayCall._(ok: false, error: error);

  final bool ok;
  final VoiceprintGatewayResponse? response;
  final AppFailure? error;
}

VoiceprintRemoteProfile? parseGatewayVoiceprintProfile(
  Object? value, {
  String? fallbackSpeakerNick,
}) {
  if (_containsSensitiveData(value)) return null;
  final object = asObjectMap(value);
  if (object == null) return null;
  final profileId = _safeIdValue(
    object['voiceprintProfileId'] ?? object['profileId'] ?? object['id'],
  );
  final speakerNick = _safeSpeakerNick(
    fallbackSpeakerNick ?? object['speakerNick'] ?? object['name'],
  );
  final status = _profileStatus(object['status'] ?? 'active');
  final registeredAt = _safeDate(object['registeredAt'] ?? object['createdAt']);
  final updatedAt = _safeDate(
    object['updatedAt'] ?? object['registeredAt'] ?? object['createdAt'],
  );
  final rawReferenceVersion = object['referenceVersion'];
  final referenceVersion = rawReferenceVersion == null
      ? 1
      : rawReferenceVersion is int && rawReferenceVersion > 0
      ? rawReferenceVersion
      : null;
  final duration = object['referenceDurationMilliseconds'];
  if (profileId == null ||
      speakerNick == null ||
      status == null ||
      registeredAt == null ||
      updatedAt == null ||
      referenceVersion == null ||
      (duration != null && (duration is! int || duration <= 0))) {
    return null;
  }
  return VoiceprintRemoteProfile(
    profileId: profileId,
    speakerNick: speakerNick,
    status: status,
    referenceVersion: referenceVersion,
    registeredAt: registeredAt,
    updatedAt: updatedAt,
  );
}

Map<String, Object?>? _decodeGatewayObject(Uint8List bytes) {
  if (bytes.isEmpty || bytes.length > 1024 * 1024) return null;
  try {
    final value = jsonDecode(utf8.decode(bytes, allowMalformed: false));
    final object = asObjectMap(value);
    if (object?['success'] == true) {
      return asObjectMap(object?['data']);
    }
    return object;
  } catch (_) {
    return null;
  }
}

AppFailure _gatewayResponseFailure(VoiceprintGatewayResponse response) {
  final object = _decodeGatewayObject(response.body);
  final error = asObjectMap(object?['error']);
  final remoteCode = _safeErrorCode(error?['code'] ?? object?['code']);
  final fallback = switch (response.statusCode) {
    HttpStatus.unauthorized => 'UNAUTHORIZED',
    HttpStatus.forbidden => 'FORBIDDEN',
    HttpStatus.notFound => 'VOICEPRINT_PROFILE_NOT_FOUND',
    HttpStatus.conflict => 'VOICEPRINT_CONFLICT',
    HttpStatus.requestEntityTooLarge => 'VOICEPRINT_SAMPLE_SIZE_INVALID',
    HttpStatus.tooManyRequests => 'VOICEPRINT_RATE_LIMITED',
    _ => 'VOICEPRINT_GATEWAY_REQUEST_FAILED',
  };
  final code = remoteCode != null && _publicFailureCode(remoteCode)
      ? remoteCode
      : fallback;
  return voiceprintApiFailure(
    code,
    retryable:
        response.statusCode == HttpStatus.tooManyRequests ||
        response.statusCode >= 500,
  );
}

AppFailure? _validateResolvedVoiceprintSample(
  VoiceRecordingDraft sample,
  Uint8List bytes,
) {
  if (bytes.isEmpty || bytes.length != sample.sizeBytes) {
    return voiceprintApiFailure('VOICEPRINT_SAMPLE_SIZE_MISMATCH');
  }
  if (sha256.convert(bytes).toString() != sample.sha256.toLowerCase()) {
    return voiceprintApiFailure('VOICEPRINT_SAMPLE_HASH_MISMATCH');
  }
  final wav = _inspectVoiceprintPcmWav(bytes);
  if (wav == null || wav.roundedSeconds != sample.durationSeconds) {
    return voiceprintApiFailure('VOICEPRINT_SAMPLE_FORMAT_INVALID');
  }
  if (wav.durationMilliseconds < _voiceprintMinimumDurationMilliseconds ||
      wav.durationMilliseconds > _voiceprintMaximumDurationMilliseconds) {
    return voiceprintApiFailure('VOICEPRINT_SAMPLE_DURATION_INVALID');
  }
  return null;
}

final class _VoiceprintPcmWavInfo {
  const _VoiceprintPcmWavInfo({
    required this.durationMilliseconds,
    required this.roundedSeconds,
  });

  final int durationMilliseconds;
  final int roundedSeconds;
}

_VoiceprintPcmWavInfo? _inspectVoiceprintPcmWav(Uint8List bytes) {
  if (bytes.length < 44 ||
      _fourCc(bytes, 0) != 'RIFF' ||
      _fourCc(bytes, 8) != 'WAVE') {
    return null;
  }
  final data = ByteData.sublistView(bytes);
  final riffSize = data.getUint32(4, Endian.little) + 8;
  if (riffSize != bytes.length) return null;
  var offset = 12;
  var validFormat = false;
  int? audioBytes;
  while (offset + 8 <= bytes.length) {
    final chunkId = _fourCc(bytes, offset);
    final chunkSize = data.getUint32(offset + 4, Endian.little);
    final chunkStart = offset + 8;
    final chunkEnd = chunkStart + chunkSize;
    if (chunkEnd > bytes.length) return null;
    if (chunkId == 'fmt ') {
      if (chunkSize < 16) return null;
      final audioFormat = data.getUint16(chunkStart, Endian.little);
      final channels = data.getUint16(chunkStart + 2, Endian.little);
      final sampleRate = data.getUint32(chunkStart + 4, Endian.little);
      final byteRate = data.getUint32(chunkStart + 8, Endian.little);
      final blockAlign = data.getUint16(chunkStart + 12, Endian.little);
      final bitsPerSample = data.getUint16(chunkStart + 14, Endian.little);
      validFormat =
          audioFormat == 1 &&
          channels == voiceprintWavChannelCount &&
          sampleRate == voiceprintWavSampleRateHz &&
          byteRate ==
              voiceprintWavSampleRateHz *
                  voiceprintWavChannelCount *
                  (voiceprintWavBitDepth ~/ 8) &&
          blockAlign ==
              voiceprintWavChannelCount * (voiceprintWavBitDepth ~/ 8) &&
          bitsPerSample == voiceprintWavBitDepth;
    } else if (chunkId == 'data') {
      audioBytes = chunkSize;
    }
    offset = chunkEnd + (chunkSize.isOdd ? 1 : 0);
  }
  if (!validFormat || audioBytes == null || audioBytes <= 0) return null;
  const bytesPerSecond =
      voiceprintWavSampleRateHz *
      voiceprintWavChannelCount *
      (voiceprintWavBitDepth ~/ 8);
  return _VoiceprintPcmWavInfo(
    durationMilliseconds: audioBytes * 1000 ~/ bytesPerSecond,
    roundedSeconds: (audioBytes + bytesPerSecond - 1) ~/ bytesPerSecond,
  );
}

String? _fourCc(Uint8List bytes, int offset) {
  if (offset < 0 || offset + 4 > bytes.length) return null;
  return String.fromCharCodes(bytes.sublist(offset, offset + 4));
}

Uri _normalizeGatewayBaseUrl(Uri value) {
  final text = value.toString();
  return text.endsWith('/') ? value : Uri.parse('$text/');
}

bool _secureGatewayConfiguration(Uri value) =>
    value.scheme.toLowerCase() == 'https' &&
    value.host.isNotEmpty &&
    value.userInfo.isEmpty &&
    !value.hasQuery &&
    !value.hasFragment;

void _debugVoiceprintGateway({
  required String stage,
  required String method,
  int? status,
  String? causeType,
}) {
  if (!kDebugMode) return;
  debugPrint(
    '[VoiceprintGateway] method=$method stage=$stage'
    '${status == null ? '' : ' status=$status'}'
    '${causeType == null ? '' : ' cause=$causeType'}',
  );
}

String _derivedGatewayOperationKey(String base, String operation) {
  final digest = sha256.convert(utf8.encode('$base\n$operation'));
  return 'vpgw-$digest';
}

String _gatewaySpeakerReference(String profileId) {
  final digest = sha256.convert(utf8.encode(profileId)).toString();
  return 'vpr-${digest.substring(0, 20)}';
}

bool _safeApplicationToken(String? value) =>
    value != null &&
    value.isNotEmpty &&
    value.length <= 16 * 1024 &&
    !value.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f);

List<VoiceprintRemoteProfile>? parseLegacyVoiceprintProfileList(Object? value) {
  if (_containsSensitiveData(value)) return null;
  final object = asObjectMap(value);
  if (object == null) return null;
  final rawProfiles = object['profiles'];
  final values = rawProfiles is List
      ? rawProfiles
      : <Object?>[if (object['profile'] != null) object['profile'] else object];
  final profiles = <VoiceprintRemoteProfile>[];
  for (final value in values) {
    final profileObject = asObjectMap(value);
    final profileId = _safeIdValue(
      profileObject?['profileId'] ?? profileObject?['id'],
    );
    final speakerNick = _safeSpeakerNick(
      profileObject?['speakerNick'] ?? profileObject?['name'],
    );
    if (profileId == null || speakerNick == null) return null;
    final profile = parseVoiceprintRemoteProfile(
      profileObject,
      expectedProfileId: profileId,
      fallbackSpeakerNick: speakerNick,
    );
    if (profile == null) return null;
    profiles.add(profile);
  }
  profiles.sort((left, right) => right.updatedAt.compareTo(left.updatedAt));
  return List<VoiceprintRemoteProfile>.unmodifiable(profiles);
}

final class _VoiceprintCreateResponse {
  const _VoiceprintCreateResponse({this.profile, this.task});

  final VoiceprintRemoteProfile? profile;
  final VoiceprintRemoteTask? task;
}

_VoiceprintCreateResponse? _parseVoiceprintCreateResponse(
  Object? value, {
  required String expectedProfileId,
  required String fallbackSpeakerNick,
}) {
  if (_containsSensitiveData(value)) return null;
  final object = asObjectMap(value);
  if (object == null) return null;
  final profileValue =
      object['profile'] ?? object['voiceprintProfile'] ?? object['voiceprint'];
  if (profileValue != null || object.containsKey('referenceVersion')) {
    final profile = parseVoiceprintRemoteProfile(
      profileValue ?? object,
      expectedProfileId: expectedProfileId,
      fallbackSpeakerNick: fallbackSpeakerNick,
    );
    return profile == null ? null : _VoiceprintCreateResponse(profile: profile);
  }
  final task = parseVoiceprintTask(
    object['task'] ?? object,
    expectedProfileId: expectedProfileId,
    fallbackSpeakerNick: fallbackSpeakerNick,
  );
  return task == null ? null : _VoiceprintCreateResponse(task: task);
}

VoiceprintRemoteTask? parseVoiceprintTask(
  Object? value, {
  String? expectedTaskId,
  required String expectedProfileId,
  required String fallbackSpeakerNick,
}) {
  if (_containsSensitiveData(value)) return null;
  final object = asObjectMap(value);
  if (object == null) return null;
  final taskObject = asObjectMap(object['task']) ?? object;
  final taskId = _safeIdValue(
    taskObject['taskId'] ?? taskObject['id'] ?? expectedTaskId,
  );
  if (taskId == null || (expectedTaskId != null && taskId != expectedTaskId)) {
    return null;
  }
  final status = _taskStatus(taskObject['status'] ?? object['status']);
  if (status == null) return null;
  final profileValue =
      taskObject['profile'] ??
      taskObject['voiceprintProfile'] ??
      object['profile'] ??
      object['voiceprintProfile'];
  final profile = profileValue == null
      ? null
      : parseVoiceprintRemoteProfile(
          profileValue,
          expectedProfileId: expectedProfileId,
          fallbackSpeakerNick: fallbackSpeakerNick,
        );
  if (profileValue != null && profile == null) return null;
  if (status == VoiceprintRemoteTaskStatus.succeeded && profile == null) {
    return null;
  }
  final errorCode = _safeErrorCode(
    taskObject['errorCode'] ??
        asObjectMap(taskObject['error'])?['code'] ??
        object['errorCode'],
  );
  if (status == VoiceprintRemoteTaskStatus.failed && errorCode == null) {
    return null;
  }
  return VoiceprintRemoteTask(
    taskId: taskId,
    status: status,
    profile: profile,
    errorCode: errorCode,
  );
}

VoiceprintRemoteProfile? parseVoiceprintRemoteProfile(
  Object? value, {
  required String expectedProfileId,
  required String fallbackSpeakerNick,
}) {
  if (_containsSensitiveData(value)) return null;
  final object = asObjectMap(value);
  if (object == null) return null;
  final profileId = _safeIdValue(object['profileId'] ?? object['id']);
  final speakerNick = _safeSpeakerNick(
    object['speakerNick'] ?? object['name'] ?? fallbackSpeakerNick,
  );
  final status = _profileStatus(object['status']);
  final referenceVersion = object['referenceVersion'];
  final registeredAt = _safeDate(object['registeredAt'] ?? object['createdAt']);
  final updatedAt = _safeDate(
    object['updatedAt'] ?? object['registeredAt'] ?? object['createdAt'],
  );
  if (profileId == null ||
      profileId != expectedProfileId ||
      speakerNick == null ||
      status == null ||
      referenceVersion is! int ||
      referenceVersion <= 0 ||
      registeredAt == null ||
      updatedAt == null) {
    return null;
  }
  return VoiceprintRemoteProfile(
    profileId: profileId,
    speakerNick: speakerNick,
    status: status,
    referenceVersion: referenceVersion,
    registeredAt: registeredAt,
    updatedAt: updatedAt,
  );
}

VoiceprintDeleteReceipt? parseVoiceprintDeleteReceipt(
  Object? value, {
  required String expectedProfileId,
}) {
  if (_containsSensitiveData(value)) return null;
  final object = asObjectMap(value);
  if (object == null) return null;
  final profileId = _safeIdValue(object['profileId'] ?? object['id']);
  final deleted =
      object['deleted'] == true ||
      '${object['status'] ?? ''}'.trim().toLowerCase() == 'deleted';
  if (!deleted || profileId != expectedProfileId) return null;
  final rawDeletedAt = object['deletedAt'];
  final deletedAt = rawDeletedAt == null ? null : _safeDate(rawDeletedAt);
  if (rawDeletedAt != null && deletedAt == null) return null;
  return VoiceprintDeleteReceipt(profileId: profileId!, deletedAt: deletedAt);
}

AppFailure voiceprintApiFailure(String code, {bool retryable = false}) {
  return AppFailure(
    code: code,
    category: code == 'VOICEPRINT_SECURE_TRANSPORT_REQUIRED'
        ? AppFailureCategory.permission
        : AppFailureCategory.api,
    message: 'Voiceprint operation failed',
    userMessageKey: 'voiceprint.error.$code',
    isRetryable: retryable,
    recoveryActions: retryable
        ? const <String>['retry']
        : const <String>['none'],
  );
}

AppFailure _safeBoundaryFailure(
  AppFailure? upstream, {
  required String fallbackCode,
  required bool retryable,
}) {
  final upstreamCode = upstream?.code;
  final code = upstreamCode != null && _publicFailureCode(upstreamCode)
      ? upstreamCode
      : fallbackCode;
  return voiceprintApiFailure(
    code,
    retryable: upstream?.isRetryable ?? retryable,
  );
}

AppFailure? _validateEnrollRequest(VoiceprintEnrollRequest request) {
  final sample = request.sample;
  if (!_safeId(request.profileId) ||
      (request.replacementProfileId != null &&
          !_safeId(request.replacementProfileId!)) ||
      !_safeId(sample.recordingId) ||
      _safeSpeakerNick(request.speakerNick) == null ||
      !_safeConsentVersion(request.consentVersion) ||
      !_safeIdempotencyKey(request.idempotencyKey) ||
      !RegExp(r'^[a-f0-9]{64}$').hasMatch(sample.sha256.toLowerCase())) {
    return voiceprintApiFailure('VOICEPRINT_REQUEST_INVALID');
  }
  if (sample.mimeType.toLowerCase() != 'audio/wav' ||
      !sample.fileName.toLowerCase().endsWith('.wav')) {
    return voiceprintApiFailure('VOICEPRINT_SAMPLE_FORMAT_INVALID');
  }
  if (sample.durationSeconds < voiceprintWavMinimumSeconds ||
      sample.durationSeconds > voiceprintWavMaximumReportedSeconds) {
    return voiceprintApiFailure('VOICEPRINT_SAMPLE_DURATION_INVALID');
  }
  if (sample.sizeBytes <= 0 || sample.sizeBytes > 2 * 1024 * 1024) {
    return voiceprintApiFailure('VOICEPRINT_SAMPLE_SIZE_INVALID');
  }
  return null;
}

VoiceprintRemoteProfileStatus? _profileStatus(Object? value) {
  return switch ('${value ?? ''}'.trim().toLowerCase()) {
    'pending' ||
    'queued' ||
    'processing' => VoiceprintRemoteProfileStatus.pending,
    'active' ||
    'completed' ||
    'succeeded' => VoiceprintRemoteProfileStatus.active,
    'revoked' => VoiceprintRemoteProfileStatus.revoked,
    'deleted' => VoiceprintRemoteProfileStatus.deleted,
    _ => null,
  };
}

VoiceprintRemoteTaskStatus? _taskStatus(Object? value) {
  return switch ('${value ?? ''}'.trim().toLowerCase()) {
    'queued' || 'pending' || 'created' => VoiceprintRemoteTaskStatus.queued,
    'running' ||
    'processing' ||
    'enrolling' => VoiceprintRemoteTaskStatus.processing,
    'succeeded' ||
    'success' ||
    'completed' => VoiceprintRemoteTaskStatus.succeeded,
    'failed' ||
    'error' ||
    'cancelled' ||
    'timeout' => VoiceprintRemoteTaskStatus.failed,
    _ => null,
  };
}

DateTime? _safeDate(Object? value) {
  if (value is! String) return null;
  final parsed = DateTime.tryParse(value.trim());
  return parsed?.toUtc();
}

String? _safeSpeakerNick(Object? value) {
  if (value is! String) return null;
  final text = value.trim();
  final length = text.runes.length;
  return text.isNotEmpty &&
          length <= 24 &&
          !text.contains('\u0000') &&
          !_unsafeString(text)
      ? text
      : null;
}

String? _safeIdValue(Object? value) {
  return value is String && _safeId(value.trim()) ? value.trim() : null;
}

bool _safeId(String value) {
  return RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$').hasMatch(value);
}

bool _safeConsentVersion(String value) {
  return RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$').hasMatch(value);
}

bool _safeIdempotencyKey(String value) {
  return value.length >= 8 &&
      value.length <= 120 &&
      RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]+$').hasMatch(value);
}

String? _safeErrorCode(Object? value) {
  if (value is! String) return null;
  final text = value.trim();
  return RegExp(r'^[A-Z][A-Z0-9_]{2,79}$').hasMatch(text) ? text : null;
}

String _publicTaskError(String? errorCode) {
  return errorCode != null && errorCode.startsWith('VOICEPRINT_')
      ? errorCode
      : 'VOICEPRINT_ENROLL_FAILED';
}

bool _publicFailureCode(String value) {
  return value.startsWith('VOICEPRINT_') ||
      const <String>{
        'API_MALFORMED_ENVELOPE',
        'AUTH_SESSION_EXPIRED',
        'FORBIDDEN',
        'IDEMPOTENCY_KEY_REQUIRED',
        'NETWORK_REQUEST_FAILED',
        'TOKEN_EXPIRED',
        'UNAUTHORIZED',
      }.contains(value);
}

String _operationKey(String base, String operation) => '$base-$operation';

Future<void> _defaultPollDelay(Duration duration) =>
    Future<void>.delayed(duration);

bool _containsSensitiveData(Object? value) {
  if (value is Map) {
    for (final entry in value.entries) {
      if (entry.key is! String) return true;
      final key = (entry.key as String).toLowerCase().replaceAll(
        RegExp(r'[^a-z0-9]'),
        '',
      );
      if (_sensitiveResponseKeys.any(key.contains) ||
          _containsSensitiveData(entry.value)) {
        return true;
      }
    }
    return false;
  }
  if (value is Iterable) {
    return value.any(_containsSensitiveData);
  }
  return value is String && _unsafeString(value);
}

bool _unsafeString(String value) {
  final text = value.trim().toLowerCase();
  return text.startsWith('app-private://') ||
      text.startsWith('file://') ||
      text.contains('/users/') ||
      text.contains('/home/') ||
      RegExp(r'^[a-z]:[\\/]').hasMatch(text);
}

const _sensitiveResponseKeys = <String>[
  'voiceprintid',
  'providerid',
  'secretid',
  'secretkey',
  'sessiontoken',
  'temporarysecret',
  'privateuri',
  'audiourl',
  'filepath',
  'localpath',
];
