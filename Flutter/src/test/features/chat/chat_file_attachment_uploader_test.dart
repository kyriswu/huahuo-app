import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:huahuo_api/huahuo_api.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/native/native_file_port.dart';
import 'package:huahuoai_app/features/chat/application/chat_file_attachment_uploader.dart';
import 'package:huahuoai_app/features/chat/domain/chat_models.dart';

void main() {
  test(
    'opening the document chooser does not create upload state or reopen it',
    () async {
      final nativeFilePort = _DelayedDocumentPickerPort();
      final uploader = ChatFileAttachmentUploader(
        nativeFilePort: nativeFilePort,
        apiClient: _api(_UploadApiTransport()),
        workspaceId: () => 'workspace-1',
        objectUploadTransport: _ObjectTransport(),
      );
      addTearDown(uploader.dispose);

      final picking = uploader.pickAndUploadFiles();

      expect(uploader.attachments, isEmpty);
      expect(nativeFilePort.documentPickerCalls, 1);
      expect(await uploader.pickAndUploadFiles(), isNull);
      expect(nativeFilePort.documentPickerCalls, 1);

      nativeFilePort.documentPicker.complete(
        NativeFileResult<List<PickedDocumentFile>>.cancelled(),
      );
      expect(await picking, isNull);
      expect(uploader.attachments, isEmpty);
    },
  );

  test('disposed document chooser completion stays silent', () async {
    final nativeFilePort = _DelayedDocumentPickerPort();
    final transport = _UploadApiTransport();
    final uploader = ChatFileAttachmentUploader(
      nativeFilePort: nativeFilePort,
      apiClient: _api(transport),
      workspaceId: () => 'workspace-1',
      objectUploadTransport: _ObjectTransport(),
    );
    var notifications = 0;
    uploader.addListener(() => notifications += 1);

    final picking = uploader.pickAndUploadFiles();
    uploader.dispose();
    nativeFilePort.documentPicker.complete(
      NativeFileResult<List<PickedDocumentFile>>.success(
        const <PickedDocumentFile>[
          PickedDocumentFile(
            pickerRef: 'picked-document://late',
            displayName: 'late.txt',
            mimeType: 'text/plain',
            sizeBytes: 4,
            sourcePath: '/private/late.txt',
          ),
        ],
      ),
    );

    expect(await picking, isNull);
    expect(notifications, 0);
    expect(uploader.attachments, isEmpty);
    expect(transport.requests, isEmpty);
  });

  test(
    'opening the image chooser does not create upload state or reopen it',
    () async {
      final nativeFilePort = _DelayedImagePickerPort();
      final uploader = ChatFileAttachmentUploader(
        nativeFilePort: nativeFilePort,
        apiClient: _api(_UploadApiTransport()),
        workspaceId: () => 'workspace-1',
        objectUploadTransport: _ObjectTransport(),
      );
      addTearDown(uploader.dispose);

      final picking = uploader.pickAndUploadImages();

      expect(uploader.attachments, isEmpty);
      expect(nativeFilePort.imagePickerCalls, 1);
      expect(await uploader.pickAndUploadImages(), isNull);
      expect(nativeFilePort.imagePickerCalls, 1);

      nativeFilePort.imagePicker.complete(
        NativeFileResult<List<PickedMediaFile>>.cancelled(),
      );
      expect(await picking, isNull);
      expect(uploader.attachments, isEmpty);
    },
  );

  test('keeps a failed attachment unsendable until retry completes', () async {
    final directory = await Directory.systemTemp.createTemp(
      'huahuo-chat-retry-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final source = File('${directory.path}/retry.png');
    await source.writeAsBytes(<int>[0x89, 0x50, 0x4e, 0x47]);
    final transport = _UploadApiTransport();
    final objectTransport = _ObjectTransport(failuresBeforeSuccess: 1);
    final uploader = ChatFileAttachmentUploader(
      nativeFilePort: const UnavailableNativeFilePort(),
      apiClient: _api(transport),
      workspaceId: () => 'workspace-1',
      objectUploadTransport: objectTransport,
    );
    addTearDown(uploader.dispose);

    await uploader.uploadPickedImages(<PickedMediaFile>[
      PickedMediaFile(
        pickerRef: 'picked-media://retry',
        displayName: 'retry.png',
        mimeType: 'image/png',
        sizeBytes: await source.length(),
        kind: NativeMediaKind.image,
        source: NativeMediaSource.gallery,
        sourcePath: source.path,
      ),
    ]);

    expect(uploader.hasFailures, isTrue);
    expect(uploader.readyAttachments, isEmpty);
    final failedId = uploader.attachments.single.localId;

    await uploader.retry(failedId);

    expect(uploader.hasFailures, isFalse);
    expect(uploader.readyAttachments.single.resourceId, 'resource-1');
    expect(objectTransport.requests, hasLength(2));
    expect(transport.requests.map((request) => request.url.path), <String>[
      '/api/v1/media/upload-token',
      '/api/v1/media/upload-token',
      '/api/v1/media/uploads/upload-2/complete',
    ]);
  });

  test(
    'uploads, previews, and removes a picked document without leaking its path',
    () async {
      final directory = await Directory.systemTemp.createTemp('huahuo-chat-');
      addTearDown(() => directory.delete(recursive: true));
      final source = File('${directory.path}/brief.md');
      await source.writeAsString('# Brief\n\nA verifiable pilot is required.');
      final digest = sha256.convert(await source.readAsBytes()).toString();
      final transport = _UploadApiTransport();
      final uploader = ChatFileAttachmentUploader(
        nativeFilePort: const UnavailableNativeFilePort(),
        apiClient: _api(transport),
        workspaceId: () => 'workspace-1',
        objectUploadTransport: _ObjectTransport(),
      );
      addTearDown(uploader.dispose);

      final failure = await uploader.uploadPickedFiles(<PickedDocumentFile>[
        PickedDocumentFile(
          pickerRef: 'picked-document://brief',
          displayName: 'brief.md',
          mimeType: 'text/markdown',
          sizeBytes: await source.length(),
          sourcePath: source.path,
          contentHash: digest,
        ),
      ]);

      expect(failure, isNull);
      final attachment = uploader.readyAttachments.single;
      expect(attachment.kind, ChatFileAttachmentKind.file);
      expect(attachment.displayName, 'brief.md');
      expect(attachment.resourceId, 'resource-1');
      expect(attachment.localPreviewPath, isNull);
      final resource = uploader.readyResourceAttachments.single;
      expect(resource.kind, ChatResourceAttachmentKind.file);
      expect(resource.resourceId, 'resource-1');
      expect(resource.displayName, 'brief.md');
      expect(resource.mimeType, 'text/markdown');
      expect(resource.sizeBytes, await source.length());
      expect(
        jsonEncode(_body(transport.requests.first)),
        isNot(contains(source.path)),
      );

      uploader.remove(attachment.localId);
      expect(uploader.attachments, isEmpty);

      final hashFailure = await uploader.uploadPickedFiles(<PickedDocumentFile>[
        PickedDocumentFile(
          pickerRef: 'picked-document://wrong-hash',
          displayName: 'brief.md',
          mimeType: 'text/markdown',
          sizeBytes: await source.length(),
          sourcePath: source.path,
          contentHash: List<String>.filled(64, '0').join(),
        ),
      ]);
      expect(hashFailure, isNull);
      expect(
        uploader.attachments.single.errorCode,
        'CHAT_ATTACHMENT_HASH_MISMATCH',
      );
      expect(transport.requests, hasLength(2));
    },
  );

  test('uploads a selected image as an image Resource attachment', () async {
    final directory = await Directory.systemTemp.createTemp(
      'huahuo-chat-image-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final source = File('${directory.path}/reference.png');
    await source.writeAsBytes(<int>[
      0x89,
      0x50,
      0x4e,
      0x47,
      0x0d,
      0x0a,
      0x1a,
      0x0a,
    ]);
    final uploader = ChatFileAttachmentUploader(
      nativeFilePort: const UnavailableNativeFilePort(),
      apiClient: _api(_UploadApiTransport()),
      workspaceId: () => 'workspace-1',
      objectUploadTransport: _ObjectTransport(),
    );
    addTearDown(uploader.dispose);

    final failure = await uploader.uploadPickedImages(<PickedMediaFile>[
      PickedMediaFile(
        pickerRef: 'picked-media://reference',
        displayName: 'reference.png',
        mimeType: 'image/png',
        sizeBytes: await source.length(),
        kind: NativeMediaKind.image,
        source: NativeMediaSource.gallery,
        sourcePath: source.path,
      ),
    ]);

    expect(failure, isNull);
    final attachment = uploader.attachments.single;
    expect(attachment.isImage, isTrue);
    expect(attachment.isReady, isTrue);
    expect(attachment.resourceId, 'resource-1');
    expect(attachment.localPreviewPath, source.path);
    expect(uploader.readyResourceAttachments, isEmpty);
  });

  test(
    'uploads a WebM video and rejects non-canonical video MIME values',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'huahuo-chat-video-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final source = File('${directory.path}/reference.webm');
      await source.writeAsBytes(<int>[0x1a, 0x45, 0xdf, 0xa3]);
      final transport = _UploadApiTransport();
      final uploader = ChatFileAttachmentUploader(
        nativeFilePort: const UnavailableNativeFilePort(),
        apiClient: _api(transport),
        workspaceId: () => 'workspace-1',
        objectUploadTransport: _ObjectTransport(),
      );
      addTearDown(uploader.dispose);

      final uploaded = await uploader.uploadPickedVideos(<PickedMediaFile>[
        PickedMediaFile(
          pickerRef: 'picked-media://reference-webm',
          displayName: 'reference.webm',
          mimeType: 'video/webm',
          sizeBytes: await source.length(),
          kind: NativeMediaKind.video,
          source: NativeMediaSource.files,
          sourcePath: source.path,
        ),
      ]);

      expect(uploaded, isNull);
      expect(uploader.attachments.single.isVideo, isTrue);
      expect(uploader.attachments.single.isReady, isTrue);
      final resource = uploader.readyResourceAttachments.single;
      expect(resource.kind, ChatResourceAttachmentKind.video);
      expect(resource.displayName, 'reference.webm');
      expect(resource.mimeType, 'video/webm');
      expect(resource.sizeBytes, await source.length());
      expect(_body(transport.requests.first)['mimeType'], 'video/webm');

      final rejected = await uploader.uploadPickedVideos(<PickedMediaFile>[
        PickedMediaFile(
          pickerRef: 'picked-media://legacy-m4v',
          displayName: 'legacy.m4v',
          mimeType: 'video/x-m4v',
          sizeBytes: await source.length(),
          kind: NativeMediaKind.video,
          source: NativeMediaSource.files,
          sourcePath: source.path,
        ),
      ]);

      expect(rejected?.code, 'CHAT_VIDEO_UNSUPPORTED_FILE');
      expect(
        transport.requests.where(
          (request) => request.url.path == '/api/v1/media/upload-token',
        ),
        hasLength(1),
      );
    },
  );

  test(
    'dispose lets an in-flight upload finish but stops later stages and files',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'huahuo-chat-dispose-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final first = File('${directory.path}/first.txt');
      final second = File('${directory.path}/second.txt');
      await first.writeAsString('first');
      await second.writeAsString('second');
      final transport = _UploadApiTransport();
      final objectTransport = _BlockingObjectTransport();
      final uploader = ChatFileAttachmentUploader(
        nativeFilePort: const UnavailableNativeFilePort(),
        apiClient: _api(transport),
        workspaceId: () => 'workspace-1',
        objectUploadTransport: objectTransport,
      );
      var notifications = 0;
      uploader.addListener(() => notifications += 1);

      final uploading = uploader.uploadPickedFiles(<PickedDocumentFile>[
        PickedDocumentFile(
          pickerRef: 'picked-document://first',
          displayName: 'first.txt',
          mimeType: 'text/plain',
          sizeBytes: await first.length(),
          sourcePath: first.path,
        ),
        PickedDocumentFile(
          pickerRef: 'picked-document://second',
          displayName: 'second.txt',
          mimeType: 'text/plain',
          sizeBytes: await second.length(),
          sourcePath: second.path,
        ),
      ]);
      await objectTransport.started.future;
      expect(uploader.attachments, hasLength(1));
      expect(
        uploader.attachments.single.status,
        ChatFileAttachmentStatus.uploading,
      );
      final notificationsBeforeDispose = notifications;

      uploader.dispose();
      objectTransport.result.complete(
        ObjectUploadResult.success(
          statusCode: 200,
          bytesSent: await first.length(),
        ),
      );
      expect(await uploading, isNull);

      expect(notifications, notificationsBeforeDispose);
      expect(uploader.attachments, hasLength(1));
      expect(objectTransport.requests, hasLength(1));
      expect(transport.requests.map((request) => request.url.path), <String>[
        '/api/v1/media/upload-token',
      ]);
    },
  );
}

ApiClient _api(_UploadApiTransport transport) => ApiClient(
  config: ApiClientConfig(
    baseUrl: Uri.parse('https://api.example.test'),
    clientVersion: '0.1.0',
    deviceId: 'device-1',
    platform: 'ios',
    locale: 'zh-CN',
    getAccessToken: () => 'access-token',
    traceIdFactory: () => 'trace-chat-file',
  ),
  transport: transport,
);

Map<String, Object?> _body(ApiTransportRequest request) =>
    (jsonDecode(request.body ?? '{}') as Map<String, dynamic>)
        .cast<String, Object?>();

final class _UploadApiTransport implements ApiTransport {
  final List<ApiTransportRequest> requests = <ApiTransportRequest>[];
  var _uploadSequence = 0;

  @override
  Future<ApiTransportResponse> send(ApiTransportRequest request) async {
    requests.add(request);
    if (request.url.path == '/api/v1/media/upload-token') {
      _uploadSequence += 1;
      return _response(<String, Object?>{
        'uploadId': 'upload-$_uploadSequence',
        'uploadUrl':
            'https://upload.example.test/object/upload-$_uploadSequence?sig=ok',
        'method': 'PUT',
        'headers': <String, Object?>{'x-upload': 'ok'},
      });
    }
    if (request.url.path.endsWith('/complete')) {
      return _response(<String, Object?>{
        'status': 'completed',
        'uploadId': 'upload-$_uploadSequence',
        'resourceId': 'resource-1',
      });
    }
    return const ApiTransportResponse(
      status: 404,
      body: <String, Object?>{
        'success': false,
        'error': <String, Object?>{'code': 'NOT_FOUND'},
      },
    );
  }
}

ApiTransportResponse _response(Map<String, Object?> data) =>
    ApiTransportResponse(
      status: 200,
      body: <String, Object?>{
        'success': true,
        'traceId': 'trace-chat-file',
        'data': data,
      },
    );

final class _ObjectTransport implements ObjectUploadTransport {
  _ObjectTransport({this.failuresBeforeSuccess = 0});

  final int failuresBeforeSuccess;
  final List<ObjectUploadRequest> requests = <ObjectUploadRequest>[];

  @override
  Future<ObjectUploadResult> upload(ObjectUploadRequest request) async {
    requests.add(request);
    if (requests.length <= failuresBeforeSuccess) {
      return ObjectUploadResult.failure(
        const AppFailure(
          code: 'UPLOAD_OBJECT_FAILED',
          category: AppFailureCategory.network,
          message: 'object upload failed',
          userMessageKey: 'chat.attachment.objectFailed',
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

final class _BlockingObjectTransport implements ObjectUploadTransport {
  final started = Completer<void>();
  final result = Completer<ObjectUploadResult>();
  final List<ObjectUploadRequest> requests = <ObjectUploadRequest>[];

  @override
  Future<ObjectUploadResult> upload(ObjectUploadRequest request) {
    requests.add(request);
    if (!started.isCompleted) started.complete();
    return result.future;
  }
}

final class _DelayedImagePickerPort
    implements NativeFilePort, NativeMediaFilePort {
  final imagePicker = Completer<NativeFileResult<List<PickedMediaFile>>>();
  var imagePickerCalls = 0;

  @override
  Future<NativeFileResult<List<PickedAudioFile>>> pickAudioFiles() async =>
      NativeFileResult<List<PickedAudioFile>>.cancelled();

  @override
  Future<NativeFileResult<List<PickedMediaFile>>> pickMediaFiles({
    required NativeMediaKind kind,
    required NativeMediaSource source,
  }) {
    imagePickerCalls += 1;
    return imagePicker.future;
  }
}

final class _DelayedDocumentPickerPort
    implements NativeFilePort, NativeDocumentFilePort {
  final documentPicker =
      Completer<NativeFileResult<List<PickedDocumentFile>>>();
  var documentPickerCalls = 0;

  @override
  Future<NativeFileResult<List<PickedAudioFile>>> pickAudioFiles() async =>
      NativeFileResult<List<PickedAudioFile>>.cancelled();

  @override
  Future<NativeFileResult<List<PickedDocumentFile>>> pickDocumentFiles() {
    documentPickerCalls += 1;
    return documentPicker.future;
  }
}
