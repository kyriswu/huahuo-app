import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/api/api_client.dart';
import 'package:huahuoai_app/features/chat/data/remote_project_assistant_runtime.dart';
import 'package:huahuoai_app/features/chat/data/chat_api.dart';
import 'package:huahuoai_app/features/ui_v3/data/positioning_update_repository.dart';
import 'package:huahuoai_app/features/ui_v3/domain/document_change_proposal_models.dart';
import 'package:huahuoai_app/features/ui_v3/domain/positioning_lifecycle.dart';

void main() {
  test(
    'ready runtime capture verifies source despite pending Run binding',
    () async {
      final fixture = _Fixture([
        _response({
          'items': [_proposalData()],
        }),
        _response(_proposalData(), etag: '"dcp:proposal-1:1"'),
        _response(_runData()),
        _response(_threadData()),
      ]);

      final snapshot = await fixture.repository.latest();

      expect(snapshot?.proposal.runId, isNull);
      expect(await fixture.repository.verifySource(snapshot!.proposal), isTrue);
      expect(
        fixture.transport.requests[2].url.path,
        '/api/v1/agent/runs/agent_run_capture',
      );
      expect(
        fixture.transport.requests.last.url.path,
        contains('/threads/thread-1'),
      );
      expect(
        fixture.transport.requests.every((request) => request.method == 'GET'),
        isTrue,
      );
    },
  );

  test(
    'missing source or non-positioning owner never uses generation Run',
    () async {
      final fixture = _Fixture([]);
      for (final data in [
        _proposalData(sourceRunId: null),
        _proposalData(sourceRunId: ''),
        _proposalData(owner: 'other-owner'),
      ]) {
        data['run'] = {
          'bindingState': 'published',
          'runId': 'agent_run_capture',
        };
        expect(
          await fixture.repository.verifySource(
            DocumentChangeProposal.fromValue(data),
          ),
          isFalse,
        );
      }
      expect(fixture.transport.requests, isEmpty);
    },
  );

  test(
    'captured source still requires exact workspace and normal successful Run',
    () async {
      for (final override in <Map<String, Object?>>[
        {'workspaceId': 'other-workspace'},
        {'agentRunId': 'other-run'},
        {'status': 'failed'},
        {'completionMode': 'degraded'},
        {'threadId': null},
      ]) {
        final fixture = _Fixture([
          _response({..._runData(), ...override}),
        ]);
        expect(
          await fixture.repository.verifySource(
            DocumentChangeProposal.fromValue(_proposalData()),
          ),
          isFalse,
          reason: override.toString(),
        );
        expect(fixture.transport.requests, hasLength(1));
      }
    },
  );

  test(
    'captured source requires matching positioning thread and profile',
    () async {
      for (final threadData in [
        _threadData(threadId: 'other-thread'),
        _threadData(workspaceId: 'other-workspace'),
        _threadData(scene: 'feed_ai'),
        _threadData(profile: 'data_body'),
        _threadData()..remove('lastRequestProfile'),
      ]) {
        final fixture = _Fixture([
          _response(_runData()),
          _response(threadData),
        ]);
        expect(
          await fixture.repository.verifySource(
            DocumentChangeProposal.fromValue(_proposalData()),
          ),
          isFalse,
          reason: threadData.toString(),
        );
        expect(fixture.transport.requests, hasLength(2));
      }
    },
  );
}

Map<String, Object?> _proposalData({
  String? sourceRunId = 'agent_run_capture',
  String owner = positioningReportOwner,
}) => {
  'proposalId': 'proposal-1',
  'proposalVersion': 1,
  'rowVersion': 1,
  'state': 'ready',
  'target': {
    'ownerRef': {'kind': 'workspace_standard_file', 'id': owner},
    'part': 'raw',
    'basePartRevisionId': 'base-1',
    'metadata': {if (sourceRunId != null) 'sourceRunId': sourceRunId},
  },
  'run': {'bindingState': 'pending'},
  'candidateAvailable': true,
  'hasChanges': true,
};

Map<String, Object?> _runData() => {
  'agentRunId': 'agent_run_capture',
  'workspaceId': 'workspace-1',
  'threadId': 'thread-1',
  'status': 'succeeded',
  'workspaceVersion': 1,
  'workspaceBindingVersion': 1,
  'contextGeneration': 1,
  'assistantMessageId': 'assistant-1',
  'completionMode': 'normal',
  'usage': {
    'measurementStatus': 'unavailable',
    'inputTokens': null,
    'outputTokens': null,
    'imageCount': null,
    'videoSeconds': null,
    'accountedCredits': null,
    'policyVersion': null,
  },
  'toolTrace': [],
  'createdAt': '2026-09-17T17:30:29.006754Z',
  'updatedAt': '2026-09-17T17:33:12.496202Z',
};

Map<String, Object?> _threadData({
  String threadId = 'thread-1',
  String workspaceId = 'workspace-1',
  String scene = 'work_ai',
  String profile = 'positioning_lv2',
}) => {
  'thread': {'threadId': threadId, 'workspaceId': workspaceId, 'scene': scene},
  'lastRequestProfile': {'agentProfileId': profile, 'skillProfileIds': []},
  'messages': [],
};

ApiTransportResponse _response(Map<String, Object?> data, {String? etag}) =>
    ApiTransportResponse(
      status: 200,
      headers: {if (etag != null) 'etag': etag},
      body: {'success': true, 'data': data},
    );

final class _Fixture {
  _Fixture(List<ApiTransportResponse> responses)
    : transport = _QueueTransport(responses) {
    final api = ApiClient(
      config: ApiClientConfig(
        baseUrl: Uri.parse('https://api.example.test'),
        clientVersion: 'test',
        deviceId: 'device-1',
        platform: 'test',
        locale: 'zh-CN',
        getAccessToken: () async => 'test-token',
      ),
      transport: transport,
    );
    repository = RemotePositioningUpdateRepository(
      api: api,
      workspaceId: 'workspace-1',
      isCurrent: () => true,
      assistantRuntime: RemoteProjectAssistantRuntime(api),
      chats: RemoteProjectChatRepository(apiClient: api),
    );
  }

  final _QueueTransport transport;
  late final RemotePositioningUpdateRepository repository;
}

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
