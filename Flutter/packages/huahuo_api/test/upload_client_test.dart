import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:huahuo_api/huahuo_api.dart';
import 'package:test/test.dart';

void main() {
  test(
    'document upload deadline cancels source and releases its slot',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final client = HttpClient();
      final cancelled = Completer<void>();
      final source = StreamController<List<int>>(
        onCancel: () {
          if (!cancelled.isCompleted) cancelled.complete();
        },
      );
      server.listen((request) async {
        try {
          await request.drain<void>();
          await request.response.close();
        } on HttpException {
          return;
        } on SocketException {
          return;
        }
      });
      addTearDown(() async {
        client.close(force: true);
        await server.close(force: true);
        await source.close();
      });
      final limiter = ObjectUploadConcurrencyLimiter(maxConcurrent: 1);
      final transport = HttpObjectUploadTransport(
        openRead: (_) => source.stream,
        client: client,
        concurrencyLimiter: limiter,
        requestTimeout: const Duration(milliseconds: 150),
      );
      final result = await transport.upload(
        ObjectUploadRequest(
          uploadId: 'upload-1',
          uploadUrl: Uri.parse('http://127.0.0.1:${server.port}/upload'),
          method: 'PUT',
          headers: const {},
          appPrivateUri: 'app-private://document-import/test.pptx',
          mimeType: 'application/octet-stream',
          sizeBytes: 10,
        ),
      );
      expect(result.error?.code, 'UPLOAD_OBJECT_TIMEOUT');
      await cancelled.future.timeout(const Duration(seconds: 2));
      await Future<void>.delayed(Duration.zero);
      expect(limiter.active, 0);
      expect(await limiter.run(() async => 'next-upload'), 'next-upload');
    },
  );

  test(
    'queued upload expires without a late connection or source read',
    () async {
      final limiter = ObjectUploadConcurrencyLimiter(maxConcurrent: 1);
      final release = Completer<void>();
      final blocker = limiter.run(() => release.future);
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      var sourceOpened = false;
      final transport = HttpObjectUploadTransport(
        openRead: (_) {
          sourceOpened = true;
          return Stream.value([1]);
        },
        client: client,
        concurrencyLimiter: limiter,
        requestTimeout: const Duration(milliseconds: 20),
      );
      final result = await transport.upload(
        ObjectUploadRequest(
          uploadId: 'upload-queued',
          uploadUrl: Uri.parse('https://unused.invalid/upload'),
          method: 'PUT',
          headers: const {},
          appPrivateUri: 'app-private://document-import/queued.pptx',
          mimeType: 'application/octet-stream',
          sizeBytes: 1,
        ),
      );
      expect(result.error?.code, 'UPLOAD_OBJECT_TIMEOUT');
      release.complete();
      await blocker;
      await Future<void>.delayed(Duration.zero);
      expect(sourceOpened, isFalse);
      expect(limiter.active, 0);
      expect(limiter.queued, 0);
    },
  );

  for (final status in [413, 410]) {
    test('document upload reports actionable HTTP $status', () async {
      final uploader = UploadClient(
        apiClient: _client(_QueueTransport([])),
        objectTransport: _HttpFailedObjectTransport(status),
      );
      final result = await uploader.uploadToObjectStore(
        token: UploadToken(
          uploadId: 'upload-1',
          uploadUrl: Uri.parse('https://objects.test/upload'),
          method: 'PUT',
          headers: const {},
        ),
        metadata: const UploadMetadata(
          sourceScene: 'note_import',
          fileName: 'slides.pptx',
          mimeType: 'application/octet-stream',
          sizeBytes: 100,
          durationSeconds: 0,
          appPrivateUri: 'app-private://document-import/slides.pptx',
        ),
      );
      expect(
        result.error?.code,
        status == 413 ? 'UPLOAD_FILE_TOO_LARGE' : 'UPLOAD_TOKEN_EXPIRED',
      );
      expect(result.error?.isRetryable, status == 410);
    });
  }

  const metadata = UploadMetadata(
    sourceScene: 'raw_material',
    fileName: 'meeting.wav',
    mimeType: 'audio/wav',
    sizeBytes: 12,
    durationSeconds: 0,
    appPrivateUri: 'app-private://desktop-recordings/meeting.wav',
    sha256: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    workspaceId: 'workspace-1',
  );

  test(
    'uploads a server-frozen Resource without serializing local stream keys',
    () async {
      final transport = _QueueTransport(<ApiTransportResponse>[
        _success(<String, Object?>{
          'uploadId': 'upload-1',
          'resourceId': 'resource-1',
          'uploadUrl': 'https://uploads.example.test/object-1',
          'method': 'PUT',
          'headers': <String, Object?>{'X-Upload-Token': 'opaque'},
        }),
        _success(<String, Object?>{
          'uploadId': 'upload-1',
          'status': 'completed',
          'resource': <String, Object?>{'resourceId': 'resource-1'},
        }),
      ]);
      final object = _ObjectTransport();
      final client = UploadClient(
        apiClient: _client(transport),
        objectTransport: object,
      );

      final token = await client.requestUploadToken(
        metadata: metadata,
        idempotencyKey: 'upload-token-1',
      );
      expect(token.ok, isTrue);
      final uploaded = await client.uploadToObjectStore(
        token: token.value!,
        metadata: metadata,
      );
      expect(uploaded.ok, isTrue);
      final completed = await client.completeUpload(
        uploadId: token.value!.uploadId,
        metadata: metadata,
        idempotencyKey: 'upload-complete-1',
      );

      expect(completed.ok, isTrue);
      expect(completed.value?.resourceId, 'resource-1');
      expect(object.request?.appPrivateUri, metadata.appPrivateUri);
      expect(transport.requests, hasLength(2));
      final tokenBody = jsonDecode(transport.requests.first.body!) as Map;
      final completeBody = jsonDecode(transport.requests.last.body!) as Map;
      expect(tokenBody['workspaceId'], 'workspace-1');
      expect(tokenBody.containsKey('appPrivateUri'), isFalse);
      expect(completeBody['workspaceId'], 'workspace-1');
      expect(completeBody.containsKey('resourceId'), isFalse);
    },
  );

  test(
    'keeps digital twin task lineage and rejects mismatched resources',
    () async {
      final receipt = <String, Object?>{
        'taskId': 'distill-1',
        'resourceId': 'resource-1',
        'ingestionId': 'ingestion-1',
        'state': 'queued',
        'proposalIds': <String>[],
      };
      final body = <String, Object?>{
        'uploadId': 'upload-1',
        'resourceId': 'resource-1',
        'digitalTwinDistillation': receipt,
      };
      final transport = _QueueTransport([_success(body)]);
      final result =
          await UploadClient(
            apiClient: _client(transport),
            objectTransport: _ObjectTransport(),
          ).completeUpload(
            uploadId: 'upload-1',
            metadata: metadata,
            idempotencyKey: 'complete-1',
          );
      expect(result.value?.digitalTwinDistillation?.taskId, 'distill-1');
      expect(result.value?.digitalTwinDistillation?.ingestionId, 'ingestion-1');
      receipt['resourceId'] = 'unrelated-resource';
      final invalid =
          await UploadClient(
            apiClient: _client(_QueueTransport([_success(body)])),
            objectTransport: _ObjectTransport(),
          ).completeUpload(
            uploadId: 'upload-1',
            metadata: metadata,
            idempotencyKey: 'complete-2',
          );
      expect(invalid.ok, isFalse);
    },
  );

  test('does not complete when direct object upload fails', () async {
    final transport = _QueueTransport(<ApiTransportResponse>[
      _success(<String, Object?>{
        'uploadId': 'upload-2',
        'resourceId': 'resource-2',
        'uploadUrl': 'https://uploads.example.test/object-2',
        'method': 'PUT',
      }),
    ]);
    final client = UploadClient(
      apiClient: _client(transport),
      objectTransport: _ObjectTransport(fails: true),
    );

    final token = await client.requestUploadToken(
      metadata: metadata,
      idempotencyKey: 'upload-token-2',
    );
    final uploaded = await client.uploadToObjectStore(
      token: token.value!,
      metadata: metadata,
    );

    expect(uploaded.ok, isFalse);
    expect(transport.requests, hasLength(1));
  });

  test('object upload limiter admits two streams in FIFO order', () async {
    final limiter = ObjectUploadConcurrencyLimiter(maxConcurrent: 2);
    final releases = List<Completer<void>>.generate(
      4,
      (_) => Completer<void>(),
    );
    final started = <int>[];
    var peak = 0;

    Future<void> operation(int index) => limiter.run(() async {
      started.add(index);
      if (limiter.active > peak) peak = limiter.active;
      await releases[index].future;
    });

    final futures = <Future<void>>[
      for (var index = 0; index < releases.length; index += 1) operation(index),
    ];
    await Future<void>.delayed(Duration.zero);

    expect(started, <int>[0, 1]);
    expect(limiter.active, 2);
    expect(limiter.queued, 2);

    releases[0].complete();
    await Future<void>.delayed(Duration.zero);
    expect(started, <int>[0, 1, 2]);

    releases[1].complete();
    await Future<void>.delayed(Duration.zero);
    expect(started, <int>[0, 1, 2, 3]);

    releases[2].complete();
    releases[3].complete();
    await Future.wait(futures);
    expect(peak, 2);
    expect(limiter.active, 0);
    expect(limiter.queued, 0);
  });

  test('object upload limiter releases a slot after failure', () async {
    final limiter = ObjectUploadConcurrencyLimiter(maxConcurrent: 1);

    await expectLater(
      limiter.run<void>(() async => throw StateError('upload failed')),
      throwsStateError,
    );

    expect(await limiter.run(() async => 'recovered'), 'recovered');
    expect(limiter.active, 0);
  });
}

ApiClient _client(_QueueTransport transport) => ApiClient(
  config: ApiClientConfig(
    baseUrl: Uri(scheme: 'https', host: 'api.example.test'),
    clientVersion: 'test',
    deviceId: 'device-test',
    platform: 'test',
    locale: 'zh-CN',
    getAccessToken: _accessToken,
  ),
  transport: transport,
);

String _accessToken() => 'access-token';

ApiTransportResponse _success(Map<String, Object?> data) =>
    ApiTransportResponse(
      status: 200,
      body: <String, Object?>{'success': true, 'data': data},
    );

final class _ObjectTransport implements ObjectUploadTransport {
  _ObjectTransport({this.fails = false});

  final bool fails;
  ObjectUploadRequest? request;

  @override
  Future<ObjectUploadResult> upload(ObjectUploadRequest request) async {
    this.request = request;
    if (fails) {
      return ObjectUploadResult.failure(
        const AppFailure(
          code: 'OBJECT_UNAVAILABLE',
          category: AppFailureCategory.network,
          message: 'object upload unavailable',
          userMessageKey: 'upload.object.unavailable',
          isRetryable: true,
        ),
      );
    }
    return ObjectUploadResult.success(
      statusCode: 200,
      bytesSent: request.sizeBytes,
    );
  }
}

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

final class _HttpFailedObjectTransport implements ObjectUploadTransport {
  const _HttpFailedObjectTransport(this.status);
  final int status;

  @override
  Future<ObjectUploadResult> upload(ObjectUploadRequest request) async =>
      ObjectUploadResult.failure(
        const AppFailure(
          code: 'UPLOAD_OBJECT_HTTP_ERROR',
          category: AppFailureCategory.network,
          message: 'Upload failed',
          userMessageKey: 'upload.failed',
          isRetryable: true,
        ),
        statusCode: status,
      );
}
