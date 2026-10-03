import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'api_contract_manifest.dart';
import 'api_envelope.dart';
import 'endpoint_catalog.dart';
import 'idempotency.dart';

typedef AccessTokenProvider = FutureOr<String?> Function();
typedef TraceIdFactory = String Function();
typedef AuthExpiredHandler = FutureOr<void> Function(AppFailure failure);

enum AccessTokenRefreshDisposition { refreshed, rejected, unavailable }

typedef AccessTokenRefreshHandler =
    FutureOr<AccessTokenRefreshDisposition> Function({
      required String rejectedAccessToken,
      required AppFailure failure,
    });

abstract interface class ApiTransport {
  Future<ApiTransportResponse> send(ApiTransportRequest request);
}

abstract interface class CancellableApiTransport {
  ApiTransportOperation sendCancellable(ApiTransportRequest request);
}

final class ApiTransportOperation {
  const ApiTransportOperation({required this.response, required this.cancel});

  final Future<ApiTransportResponse> response;
  final void Function() cancel;
}

abstract interface class ApiStreamingTransport {
  Future<ApiTransportStreamResponse> open(ApiTransportRequest request);
}

final class HttpApiTransport
    implements ApiTransport, CancellableApiTransport, ApiStreamingTransport {
  HttpApiTransport({HttpClient? client}) : _client = client ?? HttpClient();

  final HttpClient _client;

  @override
  Future<ApiTransportResponse> send(ApiTransportRequest request) =>
      sendCancellable(request).response;

  @override
  ApiTransportOperation sendCancellable(ApiTransportRequest request) {
    final cancellation = _HttpTransportCancellation();
    return ApiTransportOperation(
      response: _send(request, cancellation),
      cancel: cancellation.cancel,
    );
  }

  Future<ApiTransportResponse> _send(
    ApiTransportRequest request,
    _HttpTransportCancellation cancellation,
  ) async {
    HttpClientRequest? httpRequest;
    try {
      httpRequest = await _client.openUrl(request.method, request.url);
      cancellation.bind(httpRequest);
      cancellation.throwIfCancelled();
      for (final header in request.headers.entries) {
        httpRequest.headers.set(header.key, header.value);
      }
      final requestBody = request.body;
      if (requestBody != null) {
        httpRequest.add(utf8.encode(requestBody));
      }

      final response = await httpRequest.close();
      cancellation.throwIfCancelled();
      final headers = <String, String>{};
      response.headers.forEach((name, values) {
        headers[name] = values.join(',');
      });
      final bytes = await _readResponseBytes(response, cancellation);
      cancellation.throwIfCancelled();
      final ok = response.statusCode >= 200 && response.statusCode < 300;
      final body = request.responseMode == EndpointResponseMode.binary && ok
          ? (bytes.isEmpty ? null : Uint8List.fromList(bytes))
          : _decodeResponseBytes(bytes);
      return ApiTransportResponse(
        status: response.statusCode,
        headers: headers,
        body: body,
      );
    } finally {
      cancellation.unbind(httpRequest);
    }
  }

  Future<List<int>> _readResponseBytes(
    HttpClientResponse response,
    _HttpTransportCancellation cancellation,
  ) async {
    final bytes = <int>[];
    final completed = Completer<List<int>>();
    late final StreamSubscription<List<int>> subscription;
    subscription = response.listen(
      bytes.addAll,
      onError: (Object error, StackTrace stackTrace) {
        if (!completed.isCompleted) {
          completed.completeError(error, stackTrace);
        }
      },
      onDone: () {
        if (!completed.isCompleted) completed.complete(bytes);
      },
      cancelOnError: true,
    );
    cancellation.bindResponse(subscription, () {
      if (!completed.isCompleted) {
        completed.completeError(const _HttpTransportCancelledException());
      }
    });
    try {
      return await completed.future;
    } finally {
      cancellation.unbindResponse(subscription);
    }
  }

  @override
  Future<ApiTransportStreamResponse> open(ApiTransportRequest request) async {
    final httpRequest = await _client.openUrl(request.method, request.url);
    for (final header in request.headers.entries) {
      httpRequest.headers.set(header.key, header.value);
    }
    if (request.body != null) {
      httpRequest.add(utf8.encode(request.body!));
    }
    final response = await httpRequest.close();
    final headers = <String, String>{};
    response.headers.forEach((name, values) {
      headers[name] = values.join(',');
    });
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final text = await response.transform(utf8.decoder).join();
      return ApiTransportStreamResponse(
        status: response.statusCode,
        headers: headers,
        errorBody: text.isEmpty ? null : _decodeResponseBody(text),
        events: const Stream<ApiTransportStreamEvent>.empty(),
      );
    }
    return ApiTransportStreamResponse(
      status: response.statusCode,
      headers: headers,
      events: _decodeServerSentEvents(
        response.transform(utf8.decoder).transform(const LineSplitter()),
      ),
    );
  }
}

final class ApiTransportRequest {
  const ApiTransportRequest({
    required this.url,
    required this.method,
    required this.headers,
    this.responseMode = EndpointResponseMode.strictEnvelope,
    this.body,
  });

  final Uri url;
  final String method;
  final Map<String, String> headers;
  final EndpointResponseMode responseMode;
  final String? body;
}

final class ApiTransportResponse {
  const ApiTransportResponse({
    required this.status,
    required this.body,
    this.headers = const <String, String>{},
  });

  final int status;
  final Object? body;
  final Map<String, String> headers;

  bool get ok => status >= 200 && status < 300;
}

final class ApiTransportStreamEvent {
  const ApiTransportStreamEvent({this.id, this.event, this.data, this.comment});

  final String? id;
  final String? event;
  final Object? data;
  final String? comment;
}

final class ApiTransportStreamResponse {
  const ApiTransportStreamResponse({
    required this.status,
    required this.headers,
    required this.events,
    this.errorBody,
  });

  final int status;
  final Map<String, String> headers;
  final Stream<ApiTransportStreamEvent> events;
  final Object? errorBody;

  bool get ok => status >= 200 && status < 300;
}

final class ApiServerSentEvent<T> {
  const ApiServerSentEvent({this.id, this.event, this.data, this.comment});

  final String? id;
  final String? event;
  final T? data;
  final String? comment;
}

final class ApiClientConfig {
  const ApiClientConfig({
    required this.baseUrl,
    required this.clientVersion,
    required this.deviceId,
    required this.platform,
    required this.locale,
    this.timeZone = 'UTC',
    this.getAccessToken,
    this.refreshAccessToken,
    this.traceIdFactory,
    this.onAuthExpired,
    this.requestTimeout = const Duration(seconds: 15),
  });

  final Uri baseUrl;
  final String clientVersion;
  final String deviceId;
  final String platform;
  final String locale;
  final String timeZone;
  final AccessTokenProvider? getAccessToken;
  final AccessTokenRefreshHandler? refreshAccessToken;
  final TraceIdFactory? traceIdFactory;
  final AuthExpiredHandler? onAuthExpired;
  final Duration requestTimeout;
}

final class ApiRequestOptions<T> {
  const ApiRequestOptions({
    required this.endpointId,
    required this.parseData,
    this.pathParams = const <String, Object>{},
    this.query = const <String, Object?>{},
    this.body,
    this.headers = const <String, String>{},
    this.accessTokenOverride,
    this.correlationId,
    this.idempotency,
    this.idempotencyStore = SubmissionKeyStore.empty,
  });

  final String endpointId;
  final DataParser<T> parseData;
  final EndpointPathParams pathParams;
  final Map<String, Object?> query;
  final Object? body;
  final Map<String, String> headers;
  final String? accessTokenOverride;
  final String? correlationId;
  final IdempotencyRequestContext? idempotency;
  final SubmissionKeyStore idempotencyStore;
}

final class ApiStreamRequestOptions<T> {
  const ApiStreamRequestOptions({
    required this.endpointId,
    required this.parseData,
    this.pathParams = const <String, Object>{},
    this.query = const <String, Object?>{},
    this.headers = const <String, String>{},
    this.accessTokenOverride,
    this.correlationId,
  });

  final String endpointId;
  final DataParser<T> parseData;
  final EndpointPathParams pathParams;
  final Map<String, Object?> query;
  final Map<String, String> headers;
  final String? accessTokenOverride;
  final String? correlationId;
}

final class ApiResult<T> {
  const ApiResult._({
    required this.ok,
    required this.idempotencyStore,
    this.data,
    this.error,
    this.traceId,
    this.status,
    this.authExpired = false,
    this.retryAfterSeconds,
    this.responseHeaders = const <String, String>{},
  });

  factory ApiResult.success({
    required T data,
    required int status,
    required SubmissionKeyStore idempotencyStore,
    String? traceId,
    Map<String, String> responseHeaders = const <String, String>{},
  }) {
    return ApiResult<T>._(
      ok: true,
      data: data,
      status: status,
      traceId: traceId,
      idempotencyStore: idempotencyStore,
      responseHeaders: Map<String, String>.unmodifiable(responseHeaders),
    );
  }

  factory ApiResult.failure({
    required AppFailure error,
    required SubmissionKeyStore idempotencyStore,
    int? status,
    String? traceId,
    bool authExpired = false,
    int? retryAfterSeconds,
    Map<String, String> responseHeaders = const <String, String>{},
  }) {
    return ApiResult<T>._(
      ok: false,
      error: error,
      status: status,
      traceId: traceId,
      authExpired: authExpired,
      retryAfterSeconds: retryAfterSeconds,
      idempotencyStore: idempotencyStore,
      responseHeaders: Map<String, String>.unmodifiable(responseHeaders),
    );
  }

  final bool ok;
  final T? data;
  final AppFailure? error;
  final String? traceId;
  final int? status;
  final bool authExpired;
  final int? retryAfterSeconds;
  final SubmissionKeyStore idempotencyStore;
  final Map<String, String> responseHeaders;
}

/// A response from a read that may have been conditionally unchanged.
///
/// Ordinary responses preserve their complete [ApiResult] in [apiResult]. A
/// documented HTTP 304 is a successful [isNotModified] result with no parsed
/// body, so callers can safely retain the local representation they supplied
/// through a conditional request header.
final class ApiConditionalResult<T> {
  ApiConditionalResult._({
    required this.isNotModified,
    this.apiResult,
    int? status,
    String? traceId,
    Map<String, String> responseHeaders = const <String, String>{},
    SubmissionKeyStore idempotencyStore = SubmissionKeyStore.empty,
  }) : _status = status,
       _traceId = traceId,
       _responseHeaders = Map<String, String>.unmodifiable(responseHeaders),
       _idempotencyStore = idempotencyStore,
       assert(isNotModified ? apiResult == null : apiResult != null);

  factory ApiConditionalResult.fromApiResult(ApiResult<T> result) {
    return ApiConditionalResult<T>._(isNotModified: false, apiResult: result);
  }

  factory ApiConditionalResult.notModified({
    required SubmissionKeyStore idempotencyStore,
    String? traceId,
    Map<String, String> responseHeaders = const <String, String>{},
  }) {
    return ApiConditionalResult<T>._(
      isNotModified: true,
      status: HttpStatus.notModified,
      traceId: traceId,
      responseHeaders: responseHeaders,
      idempotencyStore: idempotencyStore,
    );
  }

  /// The ordinary transport result, or null for an unchanged HTTP 304.
  final ApiResult<T>? apiResult;

  /// Whether the endpoint returned HTTP 304 without a response body.
  final bool isNotModified;

  /// Alias for concise call sites that branch on an unchanged read.
  bool get notModified => isNotModified;

  bool get ok => isNotModified || apiResult!.ok;
  T? get data => apiResult?.data;
  AppFailure? get error => apiResult?.error;
  int? get status => isNotModified ? _status : apiResult?.status;
  String? get traceId => isNotModified ? _traceId : apiResult?.traceId;
  bool get authExpired => isNotModified ? false : apiResult!.authExpired;
  int? get retryAfterSeconds =>
      isNotModified ? null : apiResult!.retryAfterSeconds;
  SubmissionKeyStore get idempotencyStore =>
      isNotModified ? _idempotencyStore : apiResult!.idempotencyStore;
  Map<String, String> get responseHeaders =>
      isNotModified ? _responseHeaders : apiResult!.responseHeaders;

  /// The response ETag, independent of the transport's header casing.
  String? get etag => _responseHeader(responseHeaders, 'ETag');

  final int? _status;
  final String? _traceId;
  final Map<String, String> _responseHeaders;
  final SubmissionKeyStore _idempotencyStore;
}

typedef RetryJitterSource = double Function();

/// A capped exponential delay with symmetric jitter around each attempt.
final class RetryBackoffPolicy {
  RetryBackoffPolicy({
    this.initialDelay = const Duration(seconds: 1),
    this.maximumDelay = const Duration(seconds: 30),
    this.jitterRatio = 0.2,
    RetryJitterSource? randomDouble,
  }) : _randomDouble = randomDouble ?? Random().nextDouble {
    if (initialDelay < Duration.zero) {
      throw ArgumentError.value(initialDelay, 'initialDelay', 'must be >= 0');
    }
    if (maximumDelay < initialDelay) {
      throw ArgumentError.value(
        maximumDelay,
        'maximumDelay',
        'must be >= initialDelay',
      );
    }
    if (!jitterRatio.isFinite || jitterRatio < 0 || jitterRatio > 1) {
      throw ArgumentError.value(jitterRatio, 'jitterRatio', 'must be 0..1');
    }
  }

  final Duration initialDelay;
  final Duration maximumDelay;
  final double jitterRatio;
  final RetryJitterSource _randomDouble;

  Duration delayForAttempt(int attempt) {
    if (attempt < 0) {
      throw RangeError.range(attempt, 0, null, 'attempt');
    }
    final maximum = maximumDelay.inMicroseconds;
    var delay = initialDelay.inMicroseconds;
    for (var index = 0; index < attempt && delay < maximum; index += 1) {
      delay = delay > maximum ~/ 2 ? maximum : delay * 2;
    }
    final sample = _randomDouble();
    final boundedSample = sample.isFinite ? sample.clamp(0.0, 1.0) : 0.5;
    final factor = 1 - jitterRatio + (2 * jitterRatio * boundedSample);
    final jittered = (delay * factor).round().clamp(0, maximum).toInt();
    return Duration(microseconds: jittered);
  }
}

/// One consumer of a shared GET request.
///
/// Cancellation completes [result] promptly and releases this consumer. It
/// does not claim to abort a transport socket that is already in progress.
final class ApiRequestLease<T> {
  ApiRequestLease._({
    required Future<T> source,
    required this._cancelledValue,
    required this._cancelSource,
  }) {
    source.then<void>(
      (value) {
        if (!_result.isCompleted) _result.complete(value);
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!_result.isCompleted) _result.completeError(error, stackTrace);
      },
    );
  }

  final T Function() _cancelledValue;
  final void Function() _cancelSource;
  final Completer<T> _result = Completer<T>();
  bool _cancelled = false;

  Future<T> get result => _result.future;
  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled || _result.isCompleted) return;
    _cancelled = true;
    _cancelSource();
    _result.complete(_cancelledValue());
  }
}

final class ApiClient {
  ApiClient({required this.config, required this.transport});

  final ApiClientConfig config;
  final ApiTransport transport;
  final Map<String, _InFlightGet> _inFlightGets = <String, _InFlightGet>{};

  /// Opaque diagnostics only. Values are SHA-256 digests and never raw URLs,
  /// query values, headers, or credentials.
  List<String> get inFlightGetKeyDigests =>
      List<String>.unmodifiable(_inFlightGets.keys);

  Future<ApiResult<T>> request<T>(ApiRequestOptions<T> options) async {
    final result = await _request<T>(options);
    return result.apiResult!;
  }

  /// Starts a cancellable consumer lease for an idempotent GET endpoint.
  ///
  /// A cancelled last consumer drops the eventual response and prevents an
  /// authentication replay. The underlying [ApiTransport] may still finish
  /// its physical request because that interface has no abort handle.
  ApiRequestLease<ApiResult<T>> leaseGet<T>(ApiRequestOptions<T> options) {
    final endpoint = EndpointCatalog.byId(options.endpointId);
    if (endpoint.method != HttpMethod.get) {
      final failure = ApiResult<T>.failure(
        error: AppFailure(
          code: 'API_GET_LEASE_REQUIRED',
          category: AppFailureCategory.api,
          message: 'Request leases are available only for GET endpoints',
          userMessageKey: 'error.api.requestUnavailable',
          recoveryActions: const <String>['none'],
          metadata: <String, Object?>{'endpointId': options.endpointId},
        ),
        idempotencyStore: options.idempotencyStore,
      );
      return ApiRequestLease<ApiResult<T>>._(
        source: Future<ApiResult<T>>.value(failure),
        cancelledValue: () => failure,
        cancelSource: () {},
      );
    }
    final control = _RequestLeaseControl();
    final source = _request<T>(
      options,
      lease: control,
    ).then((result) => result.apiResult!);
    return ApiRequestLease<ApiResult<T>>._(
      source: source,
      cancelledValue: () => _cancelledResult<T>(options),
      cancelSource: control.cancel,
    );
  }

  /// Starts a cancellable consumer lease for a conditional GET endpoint.
  ///
  /// This preserves the explicit HTTP 304 branch while sharing the same
  /// physical-flight ownership and last-consumer abort behavior as [leaseGet].
  ApiRequestLease<ApiConditionalResult<T>> leaseConditionalGet<T>(
    ApiRequestOptions<T> options,
  ) {
    final endpoint = EndpointCatalog.byId(options.endpointId);
    if (endpoint.method != HttpMethod.get) {
      final failure = ApiConditionalResult<T>.fromApiResult(
        ApiResult<T>.failure(
          error: AppFailure(
            code: 'API_GET_LEASE_REQUIRED',
            category: AppFailureCategory.api,
            message: 'Request leases are available only for GET endpoints',
            userMessageKey: 'error.api.requestUnavailable',
            recoveryActions: const <String>['none'],
            metadata: <String, Object?>{'endpointId': options.endpointId},
          ),
          idempotencyStore: options.idempotencyStore,
        ),
      );
      return ApiRequestLease<ApiConditionalResult<T>>._(
        source: Future<ApiConditionalResult<T>>.value(failure),
        cancelledValue: () => failure,
        cancelSource: _noOp,
      );
    }
    final control = _RequestLeaseControl();
    return ApiRequestLease<ApiConditionalResult<T>>._(
      source: _request<T>(options, acceptNotModified: true, lease: control),
      cancelledValue: () =>
          ApiConditionalResult<T>.fromApiResult(_cancelledResult<T>(options)),
      cancelSource: control.cancel,
    );
  }

  /// Executes a read that may return HTTP 304 for a supplied condition.
  ///
  /// This method is intentionally opt-in so [request] preserves its existing
  /// response parsing and failure behavior for a 304 status.
  Future<ApiConditionalResult<T>> requestConditional<T>(
    ApiRequestOptions<T> options,
  ) => _request<T>(options, acceptNotModified: true);

  Future<ApiConditionalResult<T>> _request<T>(
    ApiRequestOptions<T> options, {
    bool acceptNotModified = false,
    bool allowAuthRefresh = true,
    bool authWasRefreshed = false,
    _RequestLeaseControl? lease,
  }) async {
    if (lease?.isCancelled == true) {
      return ApiConditionalResult<T>.fromApiResult(
        _cancelledResult<T>(options),
      );
    }
    if (ApiContractManifest.isProhibitedEndpointId(options.endpointId)) {
      return ApiConditionalResult<T>.fromApiResult(
        _blockedEndpointResult<T>(
          endpointId: options.endpointId,
          code: 'API_ENDPOINT_PROHIBITED',
        ),
      );
    }
    if (ApiContractManifest.isRetiredEndpointId(options.endpointId)) {
      return ApiConditionalResult<T>.fromApiResult(
        _blockedEndpointResult<T>(
          endpointId: options.endpointId,
          code: 'API_ENDPOINT_RETIRED',
        ),
      );
    }
    final endpoint = EndpointCatalog.resolve(
      options.endpointId,
      pathParams: options.pathParams,
    );
    final correlationId =
        options.correlationId ??
        config.traceIdFactory?.call() ??
        'trace-${DateTime.now().toUtc().microsecondsSinceEpoch}';

    final idempotency = resolveIdempotencyKeyForEndpoint(
      endpoint.definition,
      options.idempotencyStore,
      options.idempotency ?? const IdempotencyRequestContext(),
    );
    if (!idempotency.ok) {
      return ApiConditionalResult<T>.fromApiResult(
        ApiResult<T>.failure(
          error: idempotency.error!,
          idempotencyStore: idempotency.store,
        ),
      );
    }

    final configuredToken = options.accessTokenOverride == null
        ? await config.getAccessToken?.call()
        : null;
    final token = options.accessTokenOverride ?? configuredToken;
    final auth = resolveAuthHeader(endpoint, token);
    if (!auth.ok) {
      return ApiConditionalResult<T>.fromApiResult(
        ApiResult<T>.failure(
          error: auth.error!,
          authExpired: true,
          idempotencyStore: idempotency.store,
        ),
      );
    }

    final safety = validateRequestPayloadSafety(
      body: options.body,
      query: options.query,
      endpointId: endpoint.id,
      correlationId: correlationId,
    );
    if (!safety.ok) {
      return ApiConditionalResult<T>.fromApiResult(
        ApiResult<T>.failure(
          error: safety.error!,
          traceId: correlationId,
          idempotencyStore: idempotency.store,
        ),
      );
    }

    final headers = <String, String>{
      ...buildCommonHeaders(config, correlationId),
      ...auth.headers,
      if (idempotency.header != null)
        endpoint.idempotencyHeaderName: idempotency.header!,
      ...options.headers,
    };
    var effectiveCorrelationId = correlationId;

    try {
      if (lease?.isCancelled == true) {
        return ApiConditionalResult<T>.fromApiResult(
          _cancelledResult<T>(options),
        );
      }
      final registration = _send(
        ApiTransportRequest(
          url: buildUrl(config.baseUrl, endpoint.path, options.query),
          method: endpoint.method.value,
          headers: headers,
          responseMode: endpoint.responseMode,
          body: options.body == null ? null : jsonEncode(options.body),
        ),
        correlationId: correlationId,
        lease: lease,
      );
      effectiveCorrelationId = registration.correlationId;
      late final ApiTransportResponse response;
      try {
        response = await registration.future.timeout(config.requestTimeout);
      } finally {
        lease?._detach(registration);
        registration.release();
      }
      if (lease?.isCancelled == true) {
        return ApiConditionalResult<T>.fromApiResult(
          _cancelledResult<T>(options),
        );
      }

      if (acceptNotModified && response.status == HttpStatus.notModified) {
        return ApiConditionalResult<T>.notModified(
          traceId:
              _responseHeader(response.headers, 'X-Trace-Id') ??
              effectiveCorrelationId,
          idempotencyStore: idempotency.store,
          responseHeaders: response.headers,
        );
      }

      if (response.ok &&
          (endpoint.responseMode == EndpointResponseMode.binary ||
              (endpoint.responseMode == EndpointResponseMode.empty &&
                  response.body == null))) {
        final data = options.parseData(response.body);
        if (data == null) {
          throw const FormatException('Direct response parser returned null');
        }
        return ApiConditionalResult<T>.fromApiResult(
          ApiResult<T>.success(
            data: data,
            traceId:
                _responseHeader(response.headers, 'X-Trace-Id') ??
                effectiveCorrelationId,
            status: response.status,
            idempotencyStore: idempotency.store,
            responseHeaders: response.headers,
          ),
        );
      }

      final envelope = parseApiEnvelope<T>(
        response.body,
        options.parseData,
        endpointId: endpoint.id,
        correlationId: effectiveCorrelationId,
        allowLegacyDirectData:
            endpoint.responseMode == EndpointResponseMode.legacyCompatible,
      );
      final traceId =
          envelope.traceId ??
          _extractTraceId(response.body) ??
          _responseHeader(response.headers, 'X-Trace-Id') ??
          effectiveCorrelationId;

      if (!response.ok) {
        final failure = handleHttpStatus(
          response.status,
          response.headers,
          endpoint: endpoint,
          correlationId: effectiveCorrelationId,
          parsedEnvelope: envelope,
        );
        if (lease?.isCancelled == true) {
          return ApiConditionalResult<T>.fromApiResult(
            _cancelledResult<T>(options),
          );
        }
        final refreshDisposition = await _attemptAccessTokenRefresh(
          endpoint: endpoint,
          accessTokenOverride: options.accessTokenOverride,
          rejectedAccessToken: token,
          failure: failure.error,
          responseStatus: response.status,
          allowAuthRefresh: allowAuthRefresh,
        );
        if (lease?.isCancelled == true) {
          return ApiConditionalResult<T>.fromApiResult(
            _cancelledResult<T>(options),
          );
        }
        if (refreshDisposition == AccessTokenRefreshDisposition.refreshed) {
          return _request<T>(
            _authenticationRetryOptions(
              options,
              correlationId: effectiveCorrelationId,
              idempotency: idempotency,
            ),
            acceptNotModified: acceptNotModified,
            allowAuthRefresh: false,
            authWasRefreshed: true,
            lease: lease,
          );
        }
        if (options.accessTokenOverride == null &&
            (refreshDisposition == AccessTokenRefreshDisposition.rejected ||
                (refreshDisposition == null && failure.authExpired) ||
                (authWasRefreshed &&
                    response.status == HttpStatus.unauthorized))) {
          await _notifyAuthExpired(failure.error);
        }
        return ApiConditionalResult<T>.fromApiResult(
          ApiResult<T>.failure(
            error: failure.error,
            traceId: traceId,
            status: response.status,
            authExpired: failure.authExpired,
            retryAfterSeconds: failure.retryAfterSeconds,
            idempotencyStore: idempotency.store,
            responseHeaders: response.headers,
          ),
        );
      }

      if (!envelope.ok) {
        return ApiConditionalResult<T>.fromApiResult(
          ApiResult<T>.failure(
            error: envelope.error!,
            traceId: traceId,
            status: response.status,
            idempotencyStore: idempotency.store,
            responseHeaders: response.headers,
          ),
        );
      }

      return ApiConditionalResult<T>.fromApiResult(
        ApiResult<T>.success(
          data: envelope.data as T,
          traceId: traceId,
          status: response.status,
          idempotencyStore: idempotency.store,
          responseHeaders: response.headers,
        ),
      );
    } on FormatException catch (cause) {
      return ApiConditionalResult<T>.fromApiResult(
        ApiResult<T>.failure(
          error: AppFailure(
            code: 'API_RESPONSE_INVALID',
            category: AppFailureCategory.api,
            message: 'API response does not match the documented contract',
            userMessageKey: 'error.api.responseInvalid',
            recoveryActions: const <String>['none'],
            metadata: <String, Object?>{
              'endpointId': endpoint.id,
              'correlationId': effectiveCorrelationId,
            },
            cause: cause,
          ),
          traceId: effectiveCorrelationId,
          idempotencyStore: idempotency.store,
        ),
      );
    } catch (cause) {
      return ApiConditionalResult<T>.fromApiResult(
        ApiResult<T>.failure(
          error: AppFailure(
            code: 'NETWORK_REQUEST_FAILED',
            category: AppFailureCategory.network,
            message: 'Network request failed',
            userMessageKey: 'error.network.requestFailed',
            isRetryable: true,
            recoveryActions: const <String>['retry', 'checkNetwork'],
            metadata: <String, Object?>{
              'endpointId': endpoint.id,
              'correlationId': effectiveCorrelationId,
            },
            cause: cause,
          ),
          traceId: effectiveCorrelationId,
          idempotencyStore: idempotency.store,
        ),
      );
    }
  }

  _TransportRegistration _send(
    ApiTransportRequest request, {
    required String correlationId,
    _RequestLeaseControl? lease,
  }) {
    if (request.method.toUpperCase() != HttpMethod.get.value) {
      return _TransportRegistration.direct(
        transport.send(request),
        correlationId,
      );
    }
    final key = _getFlightKey(request);
    var flight = _inFlightGets[key];
    if (flight == null) {
      final operation = transport is CancellableApiTransport
          ? (transport as CancellableApiTransport).sendCancellable(request)
          : ApiTransportOperation(
              response: Future<ApiTransportResponse>.sync(
                () => transport.send(request),
              ),
              cancel: _noOp,
            );
      final future = operation.response;
      flight = _InFlightGet(future, correlationId, operation.cancel);
      _inFlightGets[key] = flight;
      void remove() {
        if (identical(_inFlightGets[key], flight)) _inFlightGets.remove(key);
      }

      future.then<void>(
        (_) => remove(),
        onError: (Object _, StackTrace __) => remove(),
      );
    }
    final joinedFlight = flight;
    joinedFlight.consumers += 1;
    final registration = _TransportRegistration(
      joinedFlight.future,
      joinedFlight.correlationId,
      () {
        joinedFlight.consumers -= 1;
        if (joinedFlight.consumers == 0 &&
            identical(_inFlightGets[key], joinedFlight)) {
          _inFlightGets.remove(key);
          joinedFlight.cancel();
        }
      },
    );
    lease?._attach(registration);
    return registration;
  }

  String _getFlightKey(ApiTransportRequest request) {
    final query =
        <List<String>>[
          for (final entry in request.url.queryParameters.entries)
            <String>[entry.key, entry.value],
        ]..sort((left, right) {
          final byKey = left.first.compareTo(right.first);
          return byKey != 0 ? byKey : left.last.compareTo(right.last);
        });
    final headers =
        <List<String>>[
          for (final entry in request.headers.entries)
            if (!_correlationHeaders.contains(entry.key.toLowerCase()))
              <String>[entry.key.toLowerCase(), entry.value],
        ]..sort((left, right) {
          final byName = left.first.compareTo(right.first);
          return byName != 0 ? byName : left.last.compareTo(right.last);
        });
    final material = jsonEncode(<Object?>[
      request.method.toUpperCase(),
      request.url.scheme.toLowerCase(),
      request.url.userInfo,
      request.url.host.toLowerCase(),
      request.url.hasPort ? request.url.port : null,
      request.url.path,
      query,
      headers,
      request.responseMode.name,
      request.body,
    ]);
    return sha256.convert(utf8.encode(material)).toString();
  }

  ApiResult<T> _cancelledResult<T>(ApiRequestOptions<T> options) {
    return ApiResult<T>.failure(
      error: AppFailure(
        code: 'API_REQUEST_CANCELLED',
        category: AppFailureCategory.network,
        message: 'The request consumer was cancelled',
        userMessageKey: 'error.network.requestCancelled',
        recoveryActions: const <String>['none'],
        metadata: <String, Object?>{'endpointId': options.endpointId},
      ),
      idempotencyStore: options.idempotencyStore,
    );
  }

  Future<ApiResult<Stream<ApiServerSentEvent<T>>>> openEventStream<T>(
    ApiStreamRequestOptions<T> options,
  ) => _openEventStream<T>(options);

  Future<ApiResult<Stream<ApiServerSentEvent<T>>>> _openEventStream<T>(
    ApiStreamRequestOptions<T> options, {
    bool allowAuthRefresh = true,
    bool authWasRefreshed = false,
    String? retainedCorrelationId,
  }) async {
    if (ApiContractManifest.isProhibitedEndpointId(options.endpointId)) {
      return _blockedEndpointResult<Stream<ApiServerSentEvent<T>>>(
        endpointId: options.endpointId,
        code: 'API_ENDPOINT_PROHIBITED',
      );
    }
    final endpoint = EndpointCatalog.resolve(
      options.endpointId,
      pathParams: options.pathParams,
    );
    if (endpoint.responseMode != EndpointResponseMode.sse) {
      return _blockedEndpointResult<Stream<ApiServerSentEvent<T>>>(
        endpointId: options.endpointId,
        code: 'API_ENDPOINT_NOT_STREAMING',
      );
    }
    if (transport is! ApiStreamingTransport) {
      return _blockedEndpointResult<Stream<ApiServerSentEvent<T>>>(
        endpointId: options.endpointId,
        code: 'API_STREAMING_UNAVAILABLE',
      );
    }
    final streamingTransport = transport as ApiStreamingTransport;
    final correlationId =
        retainedCorrelationId ??
        options.correlationId ??
        config.traceIdFactory?.call() ??
        'trace-${DateTime.now().toUtc().microsecondsSinceEpoch}';
    final configuredToken = options.accessTokenOverride == null
        ? await config.getAccessToken?.call()
        : null;
    final auth = resolveAuthHeader(
      endpoint,
      options.accessTokenOverride ?? configuredToken,
    );
    if (!auth.ok) {
      return ApiResult<Stream<ApiServerSentEvent<T>>>.failure(
        error: auth.error!,
        authExpired: true,
        idempotencyStore: SubmissionKeyStore.empty,
      );
    }
    try {
      final response = await streamingTransport
          .open(
            ApiTransportRequest(
              url: buildUrl(config.baseUrl, endpoint.path, options.query),
              method: endpoint.method.value,
              headers: <String, String>{
                ...buildCommonHeaders(config, correlationId),
                ...auth.headers,
                'Accept': 'text/event-stream',
                ...options.headers,
              },
              responseMode: EndpointResponseMode.sse,
            ),
          )
          .timeout(config.requestTimeout);
      if (!response.ok) {
        final envelope = parseApiEnvelope<Object?>(
          response.errorBody,
          (value) => value,
          endpointId: endpoint.id,
          correlationId: correlationId,
        );
        final failure = handleHttpStatus(
          response.status,
          response.headers,
          endpoint: endpoint,
          correlationId: correlationId,
          parsedEnvelope: envelope,
        );
        final refreshDisposition = await _attemptAccessTokenRefresh(
          endpoint: endpoint,
          accessTokenOverride: options.accessTokenOverride,
          rejectedAccessToken: options.accessTokenOverride ?? configuredToken,
          failure: failure.error,
          responseStatus: response.status,
          allowAuthRefresh: allowAuthRefresh,
        );
        if (refreshDisposition == AccessTokenRefreshDisposition.refreshed) {
          return _openEventStream<T>(
            options,
            allowAuthRefresh: false,
            authWasRefreshed: true,
            retainedCorrelationId: correlationId,
          );
        }
        if (options.accessTokenOverride == null &&
            (refreshDisposition == AccessTokenRefreshDisposition.rejected ||
                (refreshDisposition == null && failure.authExpired) ||
                (authWasRefreshed &&
                    response.status == HttpStatus.unauthorized))) {
          await _notifyAuthExpired(failure.error);
        }
        return ApiResult<Stream<ApiServerSentEvent<T>>>.failure(
          error: failure.error,
          traceId: correlationId,
          status: response.status,
          authExpired: failure.authExpired,
          retryAfterSeconds: failure.retryAfterSeconds,
          idempotencyStore: SubmissionKeyStore.empty,
          responseHeaders: response.headers,
        );
      }
      final events = response.events.map((event) {
        if (event.comment != null) {
          return ApiServerSentEvent<T>(comment: event.comment);
        }
        final data = options.parseData(event.data);
        if (data == null) {
          throw const FormatException('Invalid server-sent event payload');
        }
        return ApiServerSentEvent<T>(
          id: event.id,
          event: event.event,
          data: data,
        );
      });
      return ApiResult<Stream<ApiServerSentEvent<T>>>.success(
        data: events,
        traceId: response.headers['X-Trace-Id'] ?? correlationId,
        status: response.status,
        idempotencyStore: SubmissionKeyStore.empty,
        responseHeaders: response.headers,
      );
    } catch (cause) {
      return ApiResult<Stream<ApiServerSentEvent<T>>>.failure(
        error: AppFailure(
          code: 'NETWORK_REQUEST_FAILED',
          category: AppFailureCategory.network,
          message: 'Streaming request failed',
          userMessageKey: 'error.network.requestFailed',
          isRetryable: true,
          recoveryActions: const <String>['retry', 'checkNetwork'],
          metadata: <String, Object?>{'endpointId': endpoint.id},
          cause: cause,
        ),
        traceId: correlationId,
        idempotencyStore: SubmissionKeyStore.empty,
      );
    }
  }

  Future<void> _notifyAuthExpired(AppFailure failure) async {
    try {
      await config.onAuthExpired?.call(failure);
    } catch (_) {
      // Auth-expiry notification must not mask the original API failure.
    }
  }

  Future<AccessTokenRefreshDisposition?> _attemptAccessTokenRefresh({
    required ResolvedEndpoint endpoint,
    required String? accessTokenOverride,
    required String? rejectedAccessToken,
    required AppFailure failure,
    required int responseStatus,
    required bool allowAuthRefresh,
  }) async {
    final refresh = config.refreshAccessToken;
    if (!allowAuthRefresh ||
        responseStatus != HttpStatus.unauthorized ||
        endpoint.auth == EndpointAuthPolicy.none ||
        endpoint.id == 'authRefresh' ||
        accessTokenOverride != null ||
        rejectedAccessToken == null ||
        rejectedAccessToken.isEmpty ||
        refresh == null) {
      return null;
    }
    try {
      return await refresh(
        rejectedAccessToken: rejectedAccessToken,
        failure: failure,
      );
    } catch (_) {
      return AccessTokenRefreshDisposition.unavailable;
    }
  }

  ApiResult<T> _blockedEndpointResult<T>({
    required String endpointId,
    required String code,
  }) {
    return ApiResult<T>.failure(
      error: AppFailure(
        code: code,
        category: AppFailureCategory.api,
        message: 'The requested endpoint is not available to this client',
        userMessageKey: 'error.api.endpointUnavailable',
        recoveryActions: const <String>['none'],
        metadata: <String, Object?>{'endpointId': endpointId},
      ),
      idempotencyStore: SubmissionKeyStore.empty,
    );
  }
}

const _correlationHeaders = <String>{'x-request-id', 'x-trace-id'};

final class _InFlightGet {
  _InFlightGet(this.future, this.correlationId, this._cancelTransport);

  final Future<ApiTransportResponse> future;
  final String correlationId;
  final void Function() _cancelTransport;
  int consumers = 0;
  bool _cancelled = false;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    try {
      _cancelTransport();
    } catch (_) {
      // Consumer cancellation must not depend on a transport's abort quality.
    }
  }
}

final class _TransportRegistration {
  _TransportRegistration(this.future, this.correlationId, this._onRelease);

  _TransportRegistration.direct(this.future, this.correlationId)
    : _onRelease = _noOp;

  final Future<ApiTransportResponse> future;
  final String correlationId;
  final void Function() _onRelease;
  bool _released = false;

  void release() {
    if (_released) return;
    _released = true;
    _onRelease();
  }
}

final class _RequestLeaseControl {
  _TransportRegistration? _registration;
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void _attach(_TransportRegistration registration) {
    if (_cancelled) {
      registration.release();
      return;
    }
    assert(_registration == null);
    _registration = registration;
  }

  void _detach(_TransportRegistration registration) {
    if (identical(_registration, registration)) _registration = null;
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    final registration = _registration;
    _registration = null;
    registration?.release();
  }
}

void _noOp() {}

final class _HttpTransportCancellation {
  HttpClientRequest? _request;
  StreamSubscription<List<int>>? _responseSubscription;
  void Function()? _completeResponseCancellation;
  bool _cancelled = false;

  void bind(HttpClientRequest request) {
    _request = request;
    if (_cancelled) request.abort(const _HttpTransportCancelledException());
  }

  void unbind(HttpClientRequest? request) {
    if (identical(_request, request)) _request = null;
  }

  void bindResponse(
    StreamSubscription<List<int>> subscription,
    void Function() completeCancellation,
  ) {
    _responseSubscription = subscription;
    _completeResponseCancellation = completeCancellation;
    if (_cancelled) _cancelResponseBody();
  }

  void unbindResponse(StreamSubscription<List<int>> subscription) {
    if (!identical(_responseSubscription, subscription)) return;
    _responseSubscription = null;
    _completeResponseCancellation = null;
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    Object? abortError;
    StackTrace? abortStackTrace;
    try {
      _request?.abort(const _HttpTransportCancelledException());
    } catch (error, stackTrace) {
      abortError = error;
      abortStackTrace = stackTrace;
    }
    _cancelResponseBody();
    if (abortError != null) {
      Error.throwWithStackTrace(abortError, abortStackTrace!);
    }
  }

  void throwIfCancelled() {
    if (_cancelled) throw const _HttpTransportCancelledException();
  }

  void _cancelResponseBody() {
    final subscription = _responseSubscription;
    if (subscription != null) {
      unawaited(subscription.cancel().catchError((Object _) {}));
    }
    _completeResponseCancellation?.call();
  }
}

final class _HttpTransportCancelledException implements Exception {
  const _HttpTransportCancelledException();

  @override
  String toString() => 'HTTP transport request cancelled';
}

ApiRequestOptions<T> _authenticationRetryOptions<T>(
  ApiRequestOptions<T> options, {
  required String correlationId,
  required IdempotencyResolution idempotency,
}) {
  return ApiRequestOptions<T>(
    endpointId: options.endpointId,
    parseData: options.parseData,
    pathParams: options.pathParams,
    query: options.query,
    body: options.body,
    headers: options.headers,
    correlationId: correlationId,
    idempotency: idempotency.header == null
        ? options.idempotency
        : IdempotencyRequestContext(explicitKey: idempotency.header),
    idempotencyStore: idempotency.store,
  );
}

final class AuthHeaderResult {
  const AuthHeaderResult._({
    required this.ok,
    this.headers = const <String, String>{},
    this.error,
  });

  factory AuthHeaderResult.success(Map<String, String> headers) {
    return AuthHeaderResult._(ok: true, headers: headers);
  }

  factory AuthHeaderResult.failure(AppFailure error) {
    return AuthHeaderResult._(ok: false, error: error);
  }

  final bool ok;
  final Map<String, String> headers;
  final AppFailure? error;
}

Map<String, String> buildCommonHeaders(
  ApiClientConfig config,
  String correlationId,
) {
  return <String, String>{
    'Accept': 'application/json',
    'Content-Type': 'application/json; charset=utf-8',
    'X-Trace-Id': correlationId,
    'X-Request-Id': correlationId,
    'X-Client-Version': config.clientVersion,
    'X-Device-Id': config.deviceId,
    'X-Platform': config.platform,
    'X-Locale': config.locale,
    'X-Time-Zone': config.timeZone,
  };
}

AuthHeaderResult resolveAuthHeader(ResolvedEndpoint endpoint, String? token) {
  if (endpoint.auth == EndpointAuthPolicy.none) {
    return AuthHeaderResult.success(const <String, String>{});
  }
  if (token != null && token.isNotEmpty) {
    return AuthHeaderResult.success(<String, String>{
      'Authorization': 'Bearer $token',
    });
  }
  if (endpoint.auth == EndpointAuthPolicy.optional) {
    return AuthHeaderResult.success(const <String, String>{});
  }
  return AuthHeaderResult.failure(
    AppFailure(
      code: 'AUTH_SESSION_EXPIRED',
      category: AppFailureCategory.auth,
      message: 'Authentication is required',
      userMessageKey: 'error.auth.sessionExpired',
      isRetryable: true,
      recoveryActions: const <String>['login'],
      metadata: <String, Object?>{'endpointId': endpoint.id},
    ),
  );
}

({bool ok, AppFailure? error}) validateRequestPayloadSafety({
  required Object? body,
  required Map<String, Object?> query,
  required String endpointId,
  required String correlationId,
}) {
  if (_containsUnsafeRequestValue(body, endpointId) ||
      _containsUnsafeRequestValue(query, endpointId)) {
    return (
      ok: false,
      error: AppFailure(
        code: 'API_SENSITIVE_REQUEST_REJECTED',
        category: AppFailureCategory.api,
        message: 'API request contains unsupported internal fields',
        userMessageKey: 'error.api.sensitiveRequestRejected',
        recoveryActions: const <String>['none'],
        metadata: <String, Object?>{
          'endpointId': endpointId,
          'correlationId': correlationId,
        },
      ),
    );
  }
  return (ok: true, error: null);
}

({AppFailure error, bool authExpired, int? retryAfterSeconds}) handleHttpStatus(
  int status,
  Map<String, String> headers, {
  required ResolvedEndpoint endpoint,
  required String correlationId,
  required ApiEnvelopeResult<Object?> parsedEnvelope,
}) {
  if (!parsedEnvelope.ok &&
      parsedEnvelope.error!.code != 'API_MALFORMED_ENVELOPE') {
    return (
      error: parsedEnvelope.error!,
      authExpired: _isExplicitHardSessionExpiry(parsedEnvelope.error!),
      retryAfterSeconds: _retryAfterSeconds(headers),
    );
  }

  final metadata = <String, Object?>{
    'endpointId': endpoint.id,
    'correlationId': correlationId,
    'status': status,
  };

  if (status == 401) {
    return (
      authExpired: false,
      retryAfterSeconds: null,
      error: AppFailure(
        code: 'AUTH_UNAUTHORIZED',
        category: AppFailureCategory.auth,
        message: 'Authentication is required',
        userMessageKey: 'error.auth.unauthorized',
        isRetryable: true,
        recoveryActions: const <String>['login'],
        metadata: metadata,
      ),
    );
  }
  if (status == 403) {
    return (
      authExpired: false,
      retryAfterSeconds: null,
      error: AppFailure(
        code: 'PERMISSION_DENIED',
        category: AppFailureCategory.permission,
        message: 'Permission is required',
        userMessageKey: 'error.permission.denied',
        recoveryActions: const <String>['requestPermission', 'openSettings'],
        metadata: metadata,
      ),
    );
  }
  if (status == 409 || status == 412) {
    return (
      authExpired: false,
      retryAfterSeconds: null,
      error: AppFailure(
        code: status == 412 ? 'API_PRECONDITION_FAILED' : 'API_CONFLICT',
        category: AppFailureCategory.api,
        message: 'Remote state changed',
        userMessageKey: 'error.api.conflict',
        isRetryable: true,
        recoveryActions: const <String>['retry'],
        metadata: metadata,
      ),
    );
  }
  if (status == 429) {
    final delay = _retryAfterSeconds(headers);
    return (
      authExpired: false,
      retryAfterSeconds: delay,
      error: AppFailure(
        code: 'API_RATE_LIMITED',
        category: AppFailureCategory.api,
        message: 'Request is rate limited',
        userMessageKey: 'error.api.rateLimited',
        isRetryable: true,
        recoveryActions: const <String>['retry'],
        metadata: <String, Object?>{
          ...metadata,
          if (delay != null) 'retryAfterSeconds': delay,
        },
      ),
    );
  }
  if (status >= 500) {
    return (
      authExpired: false,
      retryAfterSeconds: null,
      error: AppFailure(
        code: 'API_SERVER_UNAVAILABLE',
        category: AppFailureCategory.api,
        message: 'Server is temporarily unavailable',
        userMessageKey: 'error.api.serverUnavailable',
        isRetryable: true,
        recoveryActions: const <String>['retry'],
        metadata: metadata,
      ),
    );
  }
  return (
    authExpired: false,
    retryAfterSeconds: null,
    error: AppFailure(
      code: 'API_HTTP_ERROR',
      category: AppFailureCategory.api,
      message: 'API request failed',
      userMessageKey: 'error.api.requestFailed',
      recoveryActions: const <String>['none'],
      metadata: metadata,
    ),
  );
}

bool _isExplicitHardSessionExpiry(AppFailure failure) => const <String>{
  'AUTH_SESSION_EXPIRED',
  'TOKEN_EXPIRED',
}.contains(failure.code.trim());

Uri buildUrl(Uri baseUrl, String path, Map<String, Object?> query) {
  final base = baseUrl.toString().replaceAll(RegExp(r'/+$'), '');
  final resolvedPath = path.replaceAll(RegExp(r'^/+'), '');
  final uri = Uri.parse('$base/$resolvedPath');
  final queryParameters = <String, String>{
    for (final entry in query.entries)
      if (entry.value != null) entry.key: entry.value.toString(),
  };
  return queryParameters.isEmpty
      ? uri
      : uri.replace(queryParameters: queryParameters);
}

String? _extractTraceId(Object? raw) {
  final object = asObjectMap(raw);
  return object == null ? null : safeTraceId(object['traceId']);
}

String? _responseHeader(Map<String, String> headers, String name) {
  for (final entry in headers.entries) {
    if (entry.key.toLowerCase() == name.toLowerCase()) {
      return entry.value;
    }
  }
  return null;
}

int? _retryAfterSeconds(Map<String, String> headers) {
  final value = headers['Retry-After'] ?? headers['retry-after'];
  if (value == null) {
    return null;
  }
  return int.tryParse(value);
}

bool _containsUnsafeRequestValue(
  Object? value,
  String endpointId, [
  List<String> keyPath = const <String>[],
]) {
  if (value == null) {
    return false;
  }
  if (value is String) {
    if (_isAllowedSensitiveApiField(endpointId, keyPath)) {
      return false;
    }
    return _unsafeValuePatterns.any((pattern) => pattern.hasMatch(value));
  }
  if (value is List) {
    return value.any(
      (item) => _containsUnsafeRequestValue(item, endpointId, keyPath),
    );
  }
  if (value is Map) {
    for (final entry in value.entries) {
      final key = entry.key.toString();
      final nextPath = <String>[...keyPath, key];
      if (!_isAllowedSensitiveApiField(endpointId, nextPath) &&
          _unsafeKeyPatterns.any((pattern) => pattern.hasMatch(key))) {
        return true;
      }
      if (_containsUnsafeRequestValue(entry.value, endpointId, nextPath)) {
        return true;
      }
    }
  }
  return false;
}

bool _isAllowedSensitiveApiField(String endpointId, List<String> keyPath) {
  final joined = keyPath.join('.');
  return (endpointId == 'registerNotificationDevice' &&
          joined == 'pushToken') ||
      (endpointId == 'authRefresh' && joined == 'refreshToken');
}

final _unsafeKeyPatterns = <RegExp>[
  RegExp('access.*token', caseSensitive: false),
  RegExp('refresh.*token', caseSensitive: false),
  RegExp('push.*token', caseSensitive: false),
  RegExp('authorization', caseSensitive: false),
  RegExp('password', caseSensitive: false),
  RegExp('secret', caseSensitive: false),
  RegExp('provider.*key', caseSensitive: false),
  RegExp('model.*key', caseSensitive: false),
  RegExp('api.*key', caseSensitive: false),
  RegExp(
    'runtime.*(session|path|key|state|workspace|id)',
    caseSensitive: false,
  ),
  RegExp('session.*key', caseSensitive: false),
  RegExp('workspace.*path', caseSensitive: false),
  RegExp('local.*path', caseSensitive: false),
  RegExp('file.*path', caseSensitive: false),
  RegExp(r'^path$', caseSensitive: false),
];

final _unsafeValuePatterns = <RegExp>[
  RegExp('^file://', caseSensitive: false),
  RegExp(r'^[A-Za-z]:[\\/]'),
  RegExp(r'[\\/]Users[\\/]', caseSensitive: false),
  RegExp('/home/huahuo-runtime/', caseSensitive: false),
  RegExp('/home/data/huahuo/(runtime|workspaces)/', caseSensitive: false),
  RegExp('runtime:tenant:', caseSensitive: false),
  RegExp('OpenClaw', caseSensitive: false),
];

Object? _decodeResponseBody(String body) {
  try {
    return jsonDecode(body);
  } catch (_) {
    return body;
  }
}

Object? _decodeResponseBytes(List<int> bytes) {
  if (bytes.isEmpty) return null;
  return _decodeResponseBody(utf8.decode(bytes));
}

Stream<ApiTransportStreamEvent> _decodeServerSentEvents(
  Stream<String> lines,
) async* {
  String? id;
  String? event;
  final dataLines = <String>[];
  final comments = <String>[];

  await for (final line in lines) {
    if (line.isEmpty) {
      if (comments.isNotEmpty && dataLines.isEmpty) {
        yield ApiTransportStreamEvent(comment: comments.join('\n'));
      } else if (dataLines.isNotEmpty) {
        final rawData = dataLines.join('\n');
        yield ApiTransportStreamEvent(
          id: id,
          event: event,
          data: _decodeResponseBody(rawData),
        );
      }
      id = null;
      event = null;
      dataLines.clear();
      comments.clear();
      continue;
    }
    if (line.startsWith(':')) {
      comments.add(line.substring(1).trimLeft());
    } else if (line.startsWith('id:')) {
      id = line.substring(3).trimLeft();
    } else if (line.startsWith('event:')) {
      event = line.substring(6).trimLeft();
    } else if (line.startsWith('data:')) {
      dataLines.add(line.substring(5).trimLeft());
    }
  }
  if (comments.isNotEmpty && dataLines.isEmpty) {
    yield ApiTransportStreamEvent(comment: comments.join('\n'));
  } else if (dataLines.isNotEmpty) {
    yield ApiTransportStreamEvent(
      id: id,
      event: event,
      data: _decodeResponseBody(dataLines.join('\n')),
    );
  }
}
