import 'dart:convert';

import 'package:huahuo_api/huahuo_api.dart';
import 'package:test/test.dart';

void main() {
  test('lists only the requested Workspace and allow-lists fields', () async {
    final transport = _QueueTransport([
      _success(<String, Object?>{
        'items': <Object?>[
          _recording(),
          _recording(id: 'recording-2', workspaceId: 'workspace-2')
            ..['privateObjectKey'] = 'must-not-escape',
        ],
      }),
    ]);

    final result = await RecordingClient(
      _client(transport),
    ).list('workspace-1');

    expect(result.ok, isTrue);
    expect(result.data?.items.single.recordingId, 'recording-1');
    expect(transport.requests.single.url.queryParameters, <String, String>{
      'workspaceId': 'workspace-1',
    });
  });

  test('parses detail and speaker panel with consistent identities', () async {
    final transport = _QueueTransport([
      _success(_detail()),
      _success(_speakerPanel()),
    ]);
    final client = RecordingClient(_client(transport));

    final detail = await client.detail('recording-1');
    final panel = await client.speakerPanel('recording-1');

    expect(detail.data?.finalTranscript, '完整转写');
    expect(detail.data?.minutesMarkdown, '# 纲要');
    expect(detail.data?.retryActions.single.stage, 'workspace_write');
    expect(panel.data?.asrTask.version, 3);
    expect(panel.data?.speakers.single.speakerId, 'speaker-1');
    expect(panel.data?.segments.single.text, '你好');
  });

  test('accepts a full long transcript in the speaker preview', () async {
    final preview = List<String>.filled(6280, '转').join();
    final payload = _speakerPanel()..['previewText'] = preview;
    final client = RecordingClient(
      _client(_QueueTransport(<ApiTransportResponse>[_success(payload)])),
    );

    final panel = await client.speakerPanel('recording-1');

    expect(panel.ok, isTrue);
    expect(panel.data?.previewText, preview);
  });

  test('writes labels and retry with exact idempotency and version', () async {
    final transport = _QueueTransport([
      _success(<String, Object?>{'saved': true}),
      _success(<String, Object?>{'submitted': true}),
      _success(<String, Object?>{'status': 'queued'}),
    ]);
    final client = RecordingClient(_client(transport));

    final draft = await client.saveSpeakerDraft(
      recordingId: 'recording-1',
      names: const {'speaker-1': '小花'},
      selfSpeakerId: 'speaker-1',
      idempotencyKey: 'draft-key-1',
    );
    final submit = await client.submitSpeakerLabels(
      recordingId: 'recording-1',
      baseAsrTaskVersion: 3,
      names: const {'speaker-1': '小花'},
      selfSpeakerId: 'speaker-1',
      idempotencyKey: 'submit-key-1',
    );
    final retry = await client.retry(
      recordingId: 'recording-1',
      stage: 'workspace_write',
      idempotencyKey: 'retry-key-1',
    );

    expect(<bool>[draft.ok, submit.ok, retry.ok], everyElement(isTrue));
    expect(transport.requests.map((request) => request.url.path), <String>[
      '/api/v1/recordings/recording-1/speaker-label-draft',
      '/api/v1/recordings/recording-1/speaker-labels',
      '/api/v1/recordings/recording-1/retry',
    ]);
    expect(
      transport.requests.map((request) => request.headers['X-Idempotency-Key']),
      <String>['draft-key-1', 'submit-key-1', 'retry-key-1'],
    );
    expect(jsonDecode(transport.requests[1].body!)['baseAsrTaskVersion'], 3);
  });

  test('rejects malformed cross-record payload and unsafe input', () async {
    final invalid = _speakerPanel()..['recording'] = _recording(id: 'other');
    final client = RecordingClient(
      _client(_QueueTransport([_success(invalid)])),
    );

    expect(
      (await client.speakerPanel('recording-1')).error?.code,
      'API_RESPONSE_INVALID',
    );
    expect(() => client.detail('../unsafe'), throwsArgumentError);
    expect(
      () => client.submitSpeakerLabels(
        recordingId: 'recording-1',
        baseAsrTaskVersion: 0,
        names: const {'speaker-1': '小花'},
        selfSpeakerId: 'speaker-1',
        idempotencyKey: 'submit-key',
      ),
      throwsArgumentError,
    );
  });
}

Map<String, Object?> _recording({
  String id = 'recording-1',
  String workspaceId = 'workspace-1',
}) => <String, Object?>{
  'recordingId': id,
  'title': '周会录音',
  'workspaceId': workspaceId,
  'transcriptStatus': 'speaker_labeling',
  'minutesStatus': 'not_started',
  'summaryStatus': 'not_started',
  'depositStatus': 'not_started',
  'asrTaskId': 'asr-1',
  'recordedAt': '2026-09-03T03:00:00Z',
};

Map<String, Object?> _asr() => <String, Object?>{
  'asrTaskId': 'asr-1',
  'status': 'speaker_labeling',
  'version': 3,
  'progress': 100,
};

Map<String, Object?> _detail() => <String, Object?>{
  'recording': _recording(),
  'asrTask': _asr(),
  'generatedAssets': <String, Object?>{
    'finalTranscript': '完整转写',
    'minutesMarkdown': '# 纲要',
    'summary': '简要总结',
  },
  'noteRef': <String, Object?>{'noteId': 'note-1'},
  'retryActions': <Object?>[
    <String, Object?>{
      'stage': 'workspace_write',
      'title': '重新沉淀',
      'allowed': true,
    },
  ],
};

Map<String, Object?> _speakerPanel() => <String, Object?>{
  'recording': _recording(),
  'asrTask': _asr(),
  'speakers': <Object?>[
    <String, Object?>{
      'speakerId': 'speaker-1',
      'displayName': '说话人 1',
      'segmentCount': 1,
      'sampleTexts': <Object?>['你好'],
      'currentName': '小花',
      'isSelf': true,
    },
  ],
  'segments': <Object?>[
    <String, Object?>{
      'speakerId': 'speaker-1',
      'startMs': 0,
      'endMs': 1000,
      'text': '你好',
    },
  ],
  'speakerNameMap': <String, Object?>{'speaker-1': '小花'},
  'selfSpeakerId': 'speaker-1',
  'previewText': '@小花 你好',
  'canSubmit': true,
};

ApiClient _client(ApiTransport transport) => ApiClientFactory.create(
  baseUrl: Uri.parse('https://api.example.test'),
  runtime: const ApiClientRuntime(
    clientVersion: 'test',
    deviceId: 'desktop-test',
    platform: 'macos',
    locale: 'zh-CN',
    timeZone: 'Asia/Shanghai',
  ),
  transport: transport,
  getAccessToken: () => 'access',
);

ApiTransportResponse _success(Object data) => ApiTransportResponse(
  status: 200,
  body: <String, Object?>{'success': true, 'data': data},
);

final class _QueueTransport implements ApiTransport {
  _QueueTransport(this.responses);

  final List<ApiTransportResponse> responses;
  final requests = <ApiTransportRequest>[];

  @override
  Future<ApiTransportResponse> send(ApiTransportRequest request) async {
    requests.add(request);
    return responses.removeAt(0);
  }
}
