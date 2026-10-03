import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:huahuo_api/huahuo_api.dart';
import 'package:huahuo_desktop/features/recordings/data/desktop_recordings_adapters.dart';
import 'package:huahuo_desktop/features/recordings/domain/desktop_recordings_port.dart';

void main() {
  test(
    'selected audio uses opaque Resource upload before creating a Recording',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'desktop-recording-upload-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final audio = File(
        '${directory.path}${Platform.pathSeparator}meeting.wav',
      )..writeAsBytesSync(<int>[1, 2, 3, 4, 5, 6]);
      final transport = _QueueTransport(<ApiTransportResponse>[
        _success(<String, Object?>{
          'uploadId': 'upload-1',
          'resourceId': 'resource-1',
          'uploadUrl': 'https://uploads.example.test/object-1',
          'method': 'PUT',
        }),
        _success(<String, Object?>{
          'uploadId': 'upload-1',
          'status': 'completed',
          'resource': <String, Object?>{'resourceId': 'resource-1'},
        }),
        _success(<String, Object?>{
          'recording': <String, Object?>{
            'recordingId': 'recording-1',
            'title': 'meeting',
            'transcriptStatus': 'queued',
          },
          'asrTask': <String, Object?>{
            'asrTaskId': 'asr-1',
            'status': 'queued',
          },
        }),
      ]);
      final objectUpload = _ObjectUploadTransport();
      final stages = <DesktopRecordingUploadStage>[];
      final port = RemoteDesktopRecordingsPort(
        _client(transport),
        objectUploadTransportFactory: (_) => objectUpload,
        now: () => DateTime.utc(2026, 8, 16),
      );

      final result = await port.submitLocalAudio(
        DesktopLocalAudioRequest(
          filePath: audio.path,
          fileName: 'meeting.wav',
          mimeType: 'audio/wav',
          workspaceId: 'workspace-1',
        ),
        onStage: stages.add,
      );

      expect(result.isSuccess, isTrue);
      expect(result.data?.recordingId, 'recording-1');
      expect(result.data?.asrTaskId, 'asr-1');
      expect(stages, <DesktopRecordingUploadStage>[
        DesktopRecordingUploadStage.hashing,
        DesktopRecordingUploadStage.requestingUpload,
        DesktopRecordingUploadStage.uploadingObject,
        DesktopRecordingUploadStage.completingUpload,
        DesktopRecordingUploadStage.creatingRecording,
      ]);
      expect(transport.requests.map((request) => request.url.path), <String>[
        '/api/v1/media/upload-token',
        '/api/v1/media/uploads/upload-1/complete',
        '/api/v1/recordings',
      ]);
      final tokenBody = jsonDecode(transport.requests[0].body!) as Map;
      final recordingBody = jsonDecode(transport.requests[2].body!) as Map;
      expect(tokenBody['workspaceId'], 'workspace-1');
      expect(tokenBody['fileName'], 'meeting.wav');
      expect(tokenBody.containsKey('filePath'), isFalse);
      expect(transport.requests.join(' '), isNot(contains(audio.path)));
      expect(recordingBody, <String, Object?>{
        'audioResourceId': 'resource-1',
        'title': 'meeting',
        'source': 'local_upload',
        'recordedAt': '2026-08-16T00:00:00.000Z',
      });
      expect(objectUpload.request?.appPrivateUri, startsWith('app-private://'));
      expect(objectUpload.request?.appPrivateUri, isNot(contains(audio.path)));
    },
  );

  test('object upload failure never submits a Recording', () async {
    final directory = await Directory.systemTemp.createTemp(
      'desktop-recording-failure-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final audio = File('${directory.path}${Platform.pathSeparator}voice.mp3')
      ..writeAsBytesSync(<int>[1, 2, 3]);
    final transport = _QueueTransport(<ApiTransportResponse>[
      _success(<String, Object?>{
        'uploadId': 'upload-2',
        'resourceId': 'resource-2',
        'uploadUrl': 'https://uploads.example.test/object-2',
        'method': 'PUT',
      }),
    ]);
    final port = RemoteDesktopRecordingsPort(
      _client(transport),
      objectUploadTransportFactory: (_) => _ObjectUploadTransport(fails: true),
    );

    final result = await port.submitLocalAudio(
      DesktopLocalAudioRequest(
        filePath: audio.path,
        fileName: 'voice.mp3',
        mimeType: 'audio/mpeg',
        workspaceId: 'workspace-1',
      ),
    );

    expect(result.isSuccess, isFalse);
    expect(transport.requests, hasLength(1));
    expect(transport.requests.single.url.path, '/api/v1/media/upload-token');
  });

  test(
    'public Recording detail exposes ASR status, result progress and message',
    () async {
      final transport = _QueueTransport(<ApiTransportResponse>[
        _success(<String, Object?>{
          'recording': <String, Object?>{
            'recordingId': 'recording-3',
            'transcriptStatus': 'processing',
          },
          'asrTask': <String, Object?>{
            'asrTaskId': 'asr-3',
            'status': 'transcribing',
            'result': <String, Object?>{'progress': 43, 'message': '正在识别语音'},
          },
        }),
      ]);
      final port = RemoteDesktopRecordingsPort(_client(transport));

      final result = await port.loadProgress('recording-3');

      expect(result.isSuccess, isTrue);
      expect(result.data?.status, 'transcribing');
      expect(result.data?.progress, 43);
      expect(result.data?.message, '正在识别语音');
    },
  );
}

ApiClient _client(_QueueTransport transport) => ApiClient(
  config: ApiClientConfig(
    baseUrl: Uri(scheme: 'https', host: 'api.example.test'),
    clientVersion: 'test',
    deviceId: 'desktop-test',
    platform: 'windows',
    locale: 'zh-CN',
    getAccessToken: () async => 'access-token',
  ),
  transport: transport,
);

ApiTransportResponse _success(Map<String, Object?> data) =>
    ApiTransportResponse(
      status: 200,
      body: <String, Object?>{'success': true, 'data': data},
    );

final class _ObjectUploadTransport implements ObjectUploadTransport {
  _ObjectUploadTransport({this.fails = false});

  final bool fails;
  ObjectUploadRequest? request;

  @override
  Future<ObjectUploadResult> upload(ObjectUploadRequest request) async {
    this.request = request;
    if (fails) {
      return ObjectUploadResult.failure(
        const AppFailure(
          code: 'OBJECT_UPLOAD_FAILED',
          category: AppFailureCategory.network,
          message: 'object upload failed',
          userMessageKey: 'upload.object.failed',
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
