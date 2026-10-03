import 'dart:convert';
import 'dart:typed_data';

import 'package:huahuo_api/huahuo_api.dart';
import 'package:test/test.dart';

void main() {
  test('reads current, active draft, schedule and formal versions', () async {
    final transport = _QueueTransport([
      _success(_current()),
      _success(_schedule()),
      _success(<String, Object?>{
        'items': [_version()],
      }),
    ]);
    final client = DigitalTwinClient(_client(transport));

    final current = await client.current('workspace-1');
    final schedule = await client.schedule('workspace-1');
    final versions = await client.versions('workspace-1');

    expect(current.data?.activeDraft?.items.single.proposalId, 'proposal-1');
    expect(current.data?.files.single.pendingProposalIds, ['proposal-1']);
    expect(schedule.data?.preferredLocalTime, '09:00');
    expect(versions.data?.single.versionId, 'version-1');
    expect(
      transport.requests.first.url.path,
      '/api/v1/workspaces/workspace-1/digital-twin',
    );
  });

  test('writes exact schedule and asynchronous confirmation bodies', () async {
    final transport = _QueueTransport([
      _success(_schedule(enabled: true)),
      _success(_confirmation(), status: 202),
      _success(_confirmation(state: 'report_ready')),
    ]);
    final client = DigitalTwinClient(_client(transport));

    await client.updateSchedule(
      'workspace-1',
      const DigitalTwinScheduleInput(
        enabled: true,
        intervalDays: 14,
        preferredLocalTime: '10:30',
        timezone: 'Asia/Shanghai',
        instruction: ' 回顾近期资料 ',
      ),
      idempotencyKey: 'schedule-1',
    );
    final created = await client.createConfirmation('workspace-1', const [
      DigitalTwinConfirmationProposalInput(
        proposalId: 'proposal-1',
        proposalVersion: 2,
        etag: '"dcp:proposal-1:3"',
      ),
    ], idempotencyKey: 'confirm-1');
    await client.confirmation('workspace-1', 'confirmation-1');

    expect(created.status, 202);
    expect(transport.requests[0].headers['X-Idempotency-Key'], 'schedule-1');
    expect(jsonDecode(transport.requests[0].body!), <String, Object?>{
      'enabled': true,
      'intervalDays': 14,
      'preferredLocalTime': '10:30',
      'timezone': 'Asia/Shanghai',
      'instruction': '回顾近期资料',
    });
    expect(transport.requests[1].headers['X-Idempotency-Key'], 'confirm-1');
    expect(jsonDecode(transport.requests[1].body!), <String, Object?>{
      'proposals': <Object?>[
        <String, Object?>{
          'proposalId': 'proposal-1',
          'proposalVersion': 2,
          'etag': '"dcp:proposal-1:3"',
        },
      ],
    });
  });

  test('compares, downloads ZIP and restores with empty object', () async {
    final transport = _QueueTransport([
      _success(_comparison()),
      ApiTransportResponse(
        status: 200,
        body: Uint8List.fromList([0x50, 0x4b, 0x03, 0x04, 1]),
      ),
      _success(_restore(), status: 202),
    ]);
    final client = DigitalTwinClient(_client(transport));

    final compared = await client.compare(
      'workspace-1',
      baseVersionId: 'version-0',
      versionId: 'version-1',
    );
    final archive = await client.download('workspace-1', 'version-1');
    final restored = await client.restore(
      'workspace-1',
      'version-1',
      idempotencyKey: 'restore-1',
    );

    expect(compared.data?.files.single.summary.hasChanges, true);
    expect(archive.data?.bytes.length, 5);
    expect(restored.status, 202);
    expect(transport.requests.first.url.queryParameters, {
      'baseVersionId': 'version-0',
    });
    expect(transport.requests.last.body, '{}');
    expect(transport.requests.last.headers['X-Idempotency-Key'], 'restore-1');
  });

  test('rejects Workspace drift and invalid archive bytes', () async {
    final current = _current()..['workspaceId'] = 'workspace-2';
    final transport = _QueueTransport([
      _success(current),
      ApiTransportResponse(status: 200, body: Uint8List.fromList([1, 2, 3, 4])),
    ]);
    final client = DigitalTwinClient(_client(transport));

    expect(
      (await client.current('workspace-1')).error?.code,
      'API_RESPONSE_INVALID',
    );
    expect(
      (await client.download('workspace-1', 'version-1')).error?.code,
      'API_RESPONSE_INVALID',
    );
  });
}

const _hash =
    'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

Map<String, Object?> _version({int number = 1, String id = 'version-1'}) => {
  'versionId': id,
  'versionNumber': number,
  'label': '版本 $number',
  'workspaceVersion': number,
  'completionPercent': 60,
  'scoringModel': 'positioning.v1',
  'createdAt': '2026-09-03T01:00:00Z',
};

Map<String, Object?> _file() => {
  'id': 'life_experiences',
  'name': '人生经历',
  'exists': true,
  'markdown': '# 经历',
  'conclusions': <Object?>[],
  'pendingCount': 1,
  'pendingProposalIds': <Object?>['proposal-1'],
};

Map<String, Object?> _current() => {
  'schemaVersion': digitalTwinSchema,
  'workspaceId': 'workspace-1',
  'agentProfileId': 'data_body',
  'state': 'pending_review',
  'level': <String, Object?>{
    'value': 2,
    'name': '成长中',
    'completionPercent': 60,
    'scoringModel': 'positioning.v1',
  },
  'pendingReviewCount': 1,
  'pendingProposalCount': 1,
  'activeDraft': <String, Object?>{
    'draftId': 'draft-1',
    'revision': 4,
    'etag': _hash,
    'state': 'pending_review',
    'internalItemCount': 1,
    'items': <Object?>[
      <String, Object?>{
        'proposalId': 'proposal-1',
        'proposalVersion': 2,
        'etag': '"dcp:proposal-1:3"',
        'state': 'ready',
        'fileIds': <Object?>['life_experiences'],
        'hasChanges': true,
      },
    ],
  },
  'files': <Object?>[_file()],
  'currentVersion': _version(),
  'updatedAt': '2026-09-03T01:00:00Z',
};

Map<String, Object?> _schedule({bool enabled = false}) => {
  'enabled': enabled,
  'intervalDays': enabled ? 14 : 7,
  'preferredLocalTime': enabled ? '10:30' : '09:00',
  'timezone': 'Asia/Shanghai',
  'instruction': enabled ? '回顾近期资料' : '回顾最近资料',
  'sourceScope': 'digital_twin_and_recent_workspace_refs',
  'version': enabled ? 1 : 0,
};

Map<String, Object?> _confirmation({String state = 'confirming'}) => {
  'confirmationTaskId': 'confirmation-1',
  'workspaceId': 'workspace-1',
  'state': state,
  'outcomes': <Object?>[],
  'appliedCount': state == 'report_ready' ? 1 : 0,
  'failedCount': 0,
  if (state == 'report_ready') 'version': _version(),
};

Map<String, Object?> _comparison() => {
  'baseVersion': _version(number: 0, id: 'version-0'),
  'version': _version(),
  'files': <Object?>[
    <String, Object?>{
      'id': 'life_experiences',
      'name': '人生经历',
      'summary': <String, Object?>{
        'hunks': 1,
        'insertedLines': 1,
        'deletedLines': 0,
        'changedLines': 1,
        'hasChanges': true,
      },
      'hunks': <Object?>[],
    },
  ],
};

Map<String, Object?> _restore() => {
  'taskId': 'restore-1',
  'versionId': 'version-1',
  'state': 'proposals_created',
  'proposalIds': <Object?>['proposal-2'],
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

ApiTransportResponse _success(Object data, {int status = 200}) =>
    ApiTransportResponse(
      status: status,
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
