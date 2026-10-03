// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:collection';
import 'dart:io';

import '../api/api_client.dart';
import '../api/api_envelope.dart';
import '../api/idempotency.dart';

final class UploadMetadata {
  const UploadMetadata({
    required this.sourceScene,
    required this.fileName,
    required this.mimeType,
    required this.sizeBytes,
    required this.durationSeconds,
    required this.appPrivateUri,
    this.sha256,
    this.workspaceId,
    this.distillToDigitalTwin = false,
  });

  final String sourceScene;
  final String fileName;
  final String mimeType;
  final int sizeBytes;
  final int durationSeconds;
  final String appPrivateUri;
  final String? sha256;
  final String? workspaceId;
  final bool distillToDigitalTwin;
}

final class UploadToken {
  const UploadToken({
    required this.uploadId,
    required this.uploadUrl,
    required this.method,
    required this.headers,
    this.resourceId,
    this.expiresAt,
  });

  final String uploadId;
  final Uri uploadUrl;
  final String method;
  final Map<String, String> headers;
  final String? resourceId;
  final DateTime? expiresAt;
}

final class UploadDigitalTwinDistillation {
  const UploadDigitalTwinDistillation({
    required this.taskId,
    required this.resourceId,
    required this.state,
    this.ingestionId,
    this.proposalIds = const <String>[],
    this.failureCode,
  });

  factory UploadDigitalTwinDistillation.fromValue(Object? value) {
    final object = asObjectMap(value);
    final taskId = asNonEmptyString(object?['taskId']);
    final resourceId = asNonEmptyString(object?['resourceId']);
    final state = asNonEmptyString(object?['state']);
    final ingestionId = asNonEmptyString(object?['ingestionId']);
    final proposals = object?['proposalIds'] ?? const <Object>[];
    if (taskId == null ||
        !_safeId(taskId) ||
        resourceId == null ||
        !_safeId(resourceId) ||
        state == null ||
        (ingestionId != null && !_safeId(ingestionId)) ||
        proposals is! List ||
        proposals.any((item) => item is! String || !_safeId(item))) {
      throw const FormatException('digitalTwinDistillation is invalid');
    }
    return UploadDigitalTwinDistillation(
      taskId: taskId,
      resourceId: resourceId,
      state: state,
      ingestionId: ingestionId,
      proposalIds: List<String>.unmodifiable(proposals.cast<String>()),
      failureCode: asNonEmptyString(object?['failureCode']),
    );
  }

  final String taskId;
  final String resourceId;
  final String state;
  final String? ingestionId;
  final List<String> proposalIds;
  final String? failureCode;
}

final class ResourceIndex {
  const ResourceIndex({
    required this.resourceId,
    required this.uploadId,
    required this.sourceScene,
    required this.mimeType,
    required this.sizeBytes,
    required this.durationSeconds,
    this.sha256,
    this.digitalTwinDistillation,
  });

  final String resourceId;
  final String uploadId;
  final String sourceScene;
  final String mimeType;
  final int sizeBytes;
  final int durationSeconds;
  final String? sha256;
  final UploadDigitalTwinDistillation? digitalTwinDistillation;
}

final class UploadClientResult<T> {
  const UploadClientResult._({required this.ok, this.value, this.error});

  factory UploadClientResult.success(T value) {
    return UploadClientResult<T>._(ok: true, value: value);
  }

  factory UploadClientResult.failure(AppFailure error) {
    return UploadClientResult<T>._(ok: false, error: error);
  }

  final bool ok;
  final T? value;
  final AppFailure? error;
}

final class ObjectUploadRequest {
  const ObjectUploadRequest({
    required this.uploadId,
    required this.uploadUrl,
    required this.method,
    required this.headers,
    required this.appPrivateUri,
    required this.mimeType,
    required this.sizeBytes,
    this.onProgress,
  });

  final String uploadId;
  final Uri uploadUrl;
  final String method;
  final Map<String, String> headers;
  final String appPrivateUri;
  final String mimeType;
  final int sizeBytes;
  final ObjectUploadProgressCallback? onProgress;
}

final class ObjectUploadResult {
  const ObjectUploadResult._({
    required this.ok,
    this.statusCode,
    this.bytesSent,
    this.error,
  });

  factory ObjectUploadResult.success({
    required int statusCode,
    required int bytesSent,
  }) {
    return ObjectUploadResult._(
      ok: true,
      statusCode: statusCode,
      bytesSent: bytesSent,
    );
  }

  factory ObjectUploadResult.failure(AppFailure error, {int? statusCode}) {
    return ObjectUploadResult._(
      ok: false,
      error: error,
      statusCode: statusCode,
    );
  }

  final bool ok;
  final int? statusCode;
  final int? bytesSent;
  final AppFailure? error;
}

abstract interface class ObjectUploadTransport {
  Future<ObjectUploadResult> upload(ObjectUploadRequest request);
}

typedef UploadByteStreamProvider =
    FutureOr<Stream<List<int>>> Function(String appPrivateUri);

typedef ObjectUploadProgressCallback =
    void Function(int bytesSent, int totalBytes);

const defaultObjectUploadConcurrency = 2;

/// FIFO admission for object-body streams shared by all default transports.
///
/// Waiting operations do not open their private source streams. This bounds
/// file descriptors, network bodies, and progress events across features even
/// when they construct separate [HttpObjectUploadTransport] instances.
final class ObjectUploadConcurrencyLimiter {
  ObjectUploadConcurrencyLimiter({
    this.maxConcurrent = defaultObjectUploadConcurrency,
  }) : assert(maxConcurrent > 0);

  static final shared = ObjectUploadConcurrencyLimiter();

  final int maxConcurrent;
  final Queue<Completer<void>> _waiters = Queue<Completer<void>>();
  int _active = 0;

  int get active => _active;
  int get queued => _waiters.length;

  Future<T> run<T>(Future<T> Function() operation) async {
    await _acquire();
    try {
      return await operation();
    } finally {
      _release();
    }
  }

  Future<void> _acquire() {
    if (_active < maxConcurrent) {
      _active += 1;
      return Future<void>.value();
    }
    final waiter = Completer<void>();
    _waiters.addLast(waiter);
    return waiter.future;
  }

  void _release() {
    final next = _waiters.isEmpty ? null : _waiters.removeFirst();
    if (next != null) {
      next.complete();
      return;
    }
    _active -= 1;
  }
}

final class HttpObjectUploadTransport implements ObjectUploadTransport {
  HttpObjectUploadTransport({
    required UploadByteStreamProvider openRead,
    HttpClient? client,
    ObjectUploadConcurrencyLimiter? concurrencyLimiter,
    this.requestTimeout,
  }) : _openRead = openRead,
       _client = client ?? HttpClient(),
       _concurrencyLimiter =
           concurrencyLimiter ?? ObjectUploadConcurrencyLimiter.shared;

  final UploadByteStreamProvider _openRead;
  final HttpClient _client;
  final ObjectUploadConcurrencyLimiter _concurrencyLimiter;
  final Duration? requestTimeout;

  @override
  Future<ObjectUploadResult> upload(ObjectUploadRequest request) async {
    final validation = validateObjectUploadRequest(request);
    if (!validation.ok) return ObjectUploadResult.failure(validation.error!);
    return _upload(request);
  }

  Future<ObjectUploadResult> _upload(ObjectUploadRequest request) async {
    HttpClientRequest? activeRequest;
    StreamIterator<List<int>>? sourceIterator;
    var timedOut = false;
    final deadline = Completer<ObjectUploadResult>();
    final timer = requestTimeout == null
        ? null
        : Timer(requestTimeout!, () {
            timedOut = true;
            activeRequest?.abort(const HttpException('UPLOAD_OBJECT_TIMEOUT'));
            final iterator = sourceIterator;
            if (iterator != null) unawaited(iterator.cancel());
            deadline.complete(
              ObjectUploadResult.failure(
                uploadFailure('UPLOAD_OBJECT_TIMEOUT', retryable: true),
              ),
            );
          });
    Future<ObjectUploadResult> transfer() async {
      if (timedOut) return await deadline.future;
      try {
        final httpRequest = await _client.openUrl(
          request.method,
          request.uploadUrl,
        );
        activeRequest = httpRequest;
        if (timedOut) {
          httpRequest.abort();
          return await deadline.future;
        }
        httpRequest.headers.set(
          HttpHeaders.contentTypeHeader,
          request.mimeType,
        );
        httpRequest.contentLength = request.sizeBytes;
        for (final header in request.headers.entries) {
          httpRequest.headers.set(header.key, header.value);
        }
        var bytesSent = 0;
        final source = await _openRead(request.appPrivateUri);
        final iterator = StreamIterator<List<int>>(source);
        sourceIterator = iterator;
        if (timedOut) {
          await iterator.cancel();
          return await deadline.future;
        }
        Stream<List<int>> chunks() async* {
          try {
            while (await iterator.moveNext()) {
              yield iterator.current;
            }
          } finally {
            await iterator.cancel();
          }
        }

        await httpRequest.addStream(
          chunks().map((chunk) {
            bytesSent += chunk.length;
            try {
              request.onProgress?.call(bytesSent, request.sizeBytes);
            } on Object {
              // Progress observers must not interrupt the object body stream.
            }
            return chunk;
          }),
        );
        final response = await httpRequest.close();
        await response.drain<void>();
        if (response.statusCode < 200 || response.statusCode >= 300) {
          return ObjectUploadResult.failure(
            uploadFailure('UPLOAD_OBJECT_HTTP_ERROR', retryable: true),
            statusCode: response.statusCode,
          );
        }
        if (bytesSent != request.sizeBytes) {
          return ObjectUploadResult.failure(
            uploadFailure('UPLOAD_OBJECT_SIZE_MISMATCH'),
            statusCode: response.statusCode,
          );
        }
        return ObjectUploadResult.success(
          statusCode: response.statusCode,
          bytesSent: bytesSent,
        );
      } catch (cause) {
        activeRequest?.abort();
        return ObjectUploadResult.failure(
          uploadFailure(
            timedOut ? 'UPLOAD_OBJECT_TIMEOUT' : 'UPLOAD_OBJECT_FAILED',
            retryable: true,
            cause: cause,
          ),
        );
      }
    }

    try {
      return await Future.any([
        _concurrencyLimiter.run(transfer),
        if (requestTimeout != null) deadline.future,
      ]);
    } finally {
      timer?.cancel();
    }
  }
}

final class UploadClient {
  const UploadClient({
    required ApiClient apiClient,
    required ObjectUploadTransport objectTransport,
  }) : _apiClient = apiClient,
       _objectTransport = objectTransport;

  final ApiClient _apiClient;
  final ObjectUploadTransport _objectTransport;

  Future<UploadClientResult<UploadToken>> requestUploadToken({
    required UploadMetadata metadata,
    required String idempotencyKey,
  }) async {
    final validation = validateUploadMetadata(metadata);
    if (!validation.ok) return UploadClientResult.failure(validation.error!);
    final result = await _apiClient.request<UploadToken>(
      ApiRequestOptions<UploadToken>(
        endpointId: 'mediaUploadToken',
        body: <String, Object?>{
          'sourceScene': metadata.sourceScene,
          'fileName': metadata.fileName,
          'mimeType': metadata.mimeType,
          'sizeBytes': metadata.sizeBytes,
          'durationSeconds': metadata.durationSeconds,
          if (metadata.sha256 != null) 'sha256': metadata.sha256,
          if (metadata.workspaceId != null) 'workspaceId': metadata.workspaceId,
          if (metadata.distillToDigitalTwin) 'distillToDigitalTwin': true,
        },
        idempotency: IdempotencyRequestContext(explicitKey: idempotencyKey),
        parseData: parseUploadToken,
      ),
    );
    if (!result.ok || result.data == null) {
      return UploadClientResult.failure(
        result.error ?? uploadFailure('UPLOAD_TOKEN_FAILED', retryable: true),
      );
    }
    return UploadClientResult.success(result.data!);
  }

  Future<UploadClientResult<void>> uploadToObjectStore({
    required UploadToken token,
    required UploadMetadata metadata,
    ObjectUploadProgressCallback? onProgress,
  }) async {
    final request = ObjectUploadRequest(
      uploadId: token.uploadId,
      uploadUrl: token.uploadUrl,
      method: token.method,
      headers: token.headers,
      appPrivateUri: metadata.appPrivateUri,
      mimeType: metadata.mimeType,
      sizeBytes: metadata.sizeBytes,
      onProgress: onProgress,
    );
    final validation = validateObjectUploadRequest(request);
    if (!validation.ok) return UploadClientResult.failure(validation.error!);
    final result = await _objectTransport.upload(request);
    if (!result.ok) {
      if (metadata.sourceScene == 'note_import') {
        final code = switch (result.statusCode) {
          413 => 'UPLOAD_FILE_TOO_LARGE',
          404 || 410 => 'UPLOAD_TOKEN_EXPIRED',
          _ => null,
        };
        if (code != null) {
          return UploadClientResult.failure(
            uploadFailure(code, retryable: code == 'UPLOAD_TOKEN_EXPIRED'),
          );
        }
      }
      return UploadClientResult.failure(
        result.error ?? uploadFailure('UPLOAD_OBJECT_FAILED', retryable: true),
      );
    }
    if (result.bytesSent != metadata.sizeBytes) {
      return UploadClientResult.failure(
        uploadFailure('UPLOAD_OBJECT_SIZE_MISMATCH'),
      );
    }
    return UploadClientResult.success(null);
  }

  Future<UploadClientResult<ResourceIndex>> completeUpload({
    required String uploadId,
    required UploadMetadata metadata,
    required String idempotencyKey,
  }) async {
    final validation = validateUploadMetadata(metadata);
    if (!validation.ok) return UploadClientResult.failure(validation.error!);
    final result = await _apiClient.request<ResourceIndex>(
      ApiRequestOptions<ResourceIndex>(
        endpointId: 'mediaUploadComplete',
        pathParams: <String, Object>{'uploadId': uploadId},
        body: <String, Object?>{
          if (metadata.workspaceId != null) 'workspaceId': metadata.workspaceId,
        },
        idempotency: IdempotencyRequestContext(explicitKey: idempotencyKey),
        parseData: (value) =>
            parseResourceIndex(value, uploadId: uploadId, metadata: metadata),
      ),
    );
    if (!result.ok || result.data == null) {
      return UploadClientResult.failure(
        result.error ??
            uploadFailure('UPLOAD_COMPLETE_FAILED', retryable: true),
      );
    }
    return UploadClientResult.success(result.data!);
  }
}

({bool ok, AppFailure? error}) validateUploadMetadata(UploadMetadata metadata) {
  if (!_safeScene(metadata.sourceScene) ||
      !_safeFileName(metadata.fileName) ||
      !_safeMimeType(metadata.mimeType) ||
      !_safeAppPrivateRef(metadata.appPrivateUri) ||
      metadata.sizeBytes <= 0 ||
      metadata.durationSeconds < 0) {
    return (ok: false, error: uploadFailure('UPLOAD_METADATA_INVALID'));
  }
  final sha256 = metadata.sha256;
  if (sha256 != null && !RegExp(r'^[a-f0-9]{64}$').hasMatch(sha256)) {
    return (ok: false, error: uploadFailure('UPLOAD_HASH_INVALID'));
  }
  final workspaceId = metadata.workspaceId;
  if (workspaceId != null && !_safeId(workspaceId)) {
    return (ok: false, error: uploadFailure('UPLOAD_WORKSPACE_INVALID'));
  }
  return (ok: true, error: null);
}

({bool ok, AppFailure? error}) validateObjectUploadRequest(
  ObjectUploadRequest request,
) {
  if (!_safeId(request.uploadId) ||
      !_safeAppPrivateRef(request.appPrivateUri) ||
      !_safeMimeType(request.mimeType) ||
      request.sizeBytes <= 0 ||
      (request.method != 'PUT' && request.method != 'POST')) {
    return (ok: false, error: uploadFailure('UPLOAD_OBJECT_REQUEST_INVALID'));
  }
  if (!request.uploadUrl.hasScheme || request.uploadUrl.host.isEmpty) {
    return (ok: false, error: uploadFailure('UPLOAD_OBJECT_URL_INVALID'));
  }
  return (ok: true, error: null);
}

UploadToken? parseUploadToken(Object? value) {
  final object = asObjectMap(value);
  if (object == null) return null;
  final uploadId = asNonEmptyString(object['uploadId']);
  final resourceId = asNonEmptyString(object['resourceId']);
  final uploadUrlText = asNonEmptyString(object['uploadUrl']);
  final method = (asNonEmptyString(object['method']) ?? 'PUT').toUpperCase();
  if (uploadId == null ||
      uploadUrlText == null ||
      !_safeId(uploadId) ||
      (resourceId != null && !_safeId(resourceId))) {
    return null;
  }
  final uploadUrl = Uri.tryParse(uploadUrlText);
  if (uploadUrl == null || !uploadUrl.hasScheme || uploadUrl.host.isEmpty) {
    return null;
  }
  final rawHeaders =
      asObjectMap(object['headers']) ?? const <String, Object?>{};
  final headers = <String, String>{};
  for (final entry in rawHeaders.entries) {
    if (entry.value is String && entry.key.trim().isNotEmpty) {
      headers[entry.key] = entry.value! as String;
    }
  }
  return UploadToken(
    uploadId: uploadId,
    uploadUrl: uploadUrl,
    method: method,
    headers: Map<String, String>.unmodifiable(headers),
    resourceId: resourceId,
    expiresAt: DateTime.tryParse('${object['expiresAt'] ?? ''}'),
  );
}

ResourceIndex? parseResourceIndex(
  Object? value, {
  required String uploadId,
  required UploadMetadata metadata,
}) {
  final object = asObjectMap(value);
  if (object == null) return null;
  final resourceObject = asObjectMap(object['resource']);
  final resourceId =
      asNonEmptyString(resourceObject?['resourceId']) ??
      asNonEmptyString(object['resourceId']);
  final responseUploadId = asNonEmptyString(object['uploadId']) ?? uploadId;
  final status = asNonEmptyString(object['status'])?.toLowerCase();
  final distillation = object['digitalTwinDistillation'] == null
      ? null
      : UploadDigitalTwinDistillation.fromValue(
          object['digitalTwinDistillation'],
        );
  if (distillation != null && distillation.resourceId != resourceId) {
    throw const FormatException('digitalTwinDistillation resource mismatch');
  }
  if (resourceId == null ||
      !_safeId(resourceId) ||
      !_safeId(responseUploadId)) {
    if (status == 'completed' &&
        responseUploadId == uploadId &&
        _safeId(responseUploadId)) {
      return ResourceIndex(
        resourceId: 'resource_$responseUploadId',
        uploadId: responseUploadId,
        sourceScene: metadata.sourceScene,
        mimeType: metadata.mimeType,
        sizeBytes: metadata.sizeBytes,
        durationSeconds: metadata.durationSeconds,
        sha256: metadata.sha256,
      );
    }
    return null;
  }
  return ResourceIndex(
    resourceId: resourceId,
    uploadId: responseUploadId,
    sourceScene: metadata.sourceScene,
    mimeType: metadata.mimeType,
    sizeBytes: metadata.sizeBytes,
    durationSeconds: metadata.durationSeconds,
    sha256: metadata.sha256,
    digitalTwinDistillation: distillation,
  );
}

AppFailure uploadFailure(String code, {bool retryable = false, Object? cause}) {
  return AppFailure(
    code: code,
    category: AppFailureCategory.api,
    message: 'Upload operation failed',
    userMessageKey: 'recording.upload.error.$code',
    isRetryable: retryable,
    recoveryActions: retryable
        ? const <String>['retry']
        : const <String>['none'],
    cause: cause,
  );
}

bool _safeId(String value) {
  return RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$').hasMatch(value) &&
      !_unsafeText(value);
}

bool _safeScene(String value) {
  return RegExp(r'^[a-z][a-z0-9_:-]{1,63}$').hasMatch(value) &&
      !_unsafeText(value);
}

bool _safeFileName(String value) {
  final text = value.trim();
  return text.isNotEmpty &&
      text.length <= 120 &&
      !text.endsWith('.part') &&
      !text.contains('/') &&
      !text.contains('\\') &&
      !_unsafeText(text);
}

bool _safeMimeType(String value) {
  return RegExp(
    r'^[a-z0-9.+-]+/[a-z0-9.+-]+$',
    caseSensitive: false,
  ).hasMatch(value);
}

bool _safeAppPrivateRef(String value) {
  final recording = RegExp(r'^app-private://[A-Za-z0-9._/-]+$').hasMatch(value);
  final screenCapture = RegExp(
    r'^app-private-media://screen-capture/[A-Za-z0-9][A-Za-z0-9._-]*\.(?:mp4|m4a)$',
  ).hasMatch(value);
  return (recording || screenCapture) &&
      !value.endsWith('.part') &&
      !_unsafeText(value);
}

bool _unsafeText(String value) {
  return _unsafePatterns.any((pattern) => pattern.hasMatch(value));
}

final _unsafePatterns = <RegExp>[
  RegExp(r'^file://', caseSensitive: false),
  RegExp(r'[\/]Users[\/]', caseSensitive: false),
  RegExp(r'^[A-Za-z]:[\\/]', caseSensitive: false),
  RegExp('access-token', caseSensitive: false),
  RegExp('refresh-token', caseSensitive: false),
  RegExp('secret', caseSensitive: false),
];
