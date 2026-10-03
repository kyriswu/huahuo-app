import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/core/api/api_client.dart';
import 'package:huahuoai_app/core/api/idempotency.dart';
import 'package:huahuoai_app/features/onboarding/data/onboarding_api.dart';

final _productionLengthRunId =
    'agent_run_user_${List<String>.filled(64, 'a').join()}'
    '_workspace_chat_workspace_chat_run_0123456789abcdef';

void main() {
  group('OnboardingApi', () {
    test('creates the first content line with an idempotency key', () async {
      final transport = _QueueTransport(<ApiTransportResponse>[
        _response(_successData()),
      ]);
      final api = OnboardingApi(apiClient: _apiClient(transport));
      final request = buildCreateFirstContentLineRequest(
        name: 'Retail voice',
        industry: 'Retail',
        accountGoal: 'Lead generation',
        targetAudience: 'Shop owners',
        commonExpressionsText: 'conversion, trust, conversion',
      );

      final result = await api.createFirstContentLine(
        request: request!,
        idempotency: const IdempotencyRequestContext(
          operation: 'onboarding.first_content_line',
          localDraftId: 'first-content-line-1',
          scene: 'content_line_onboarding',
          generateKey: _fixedKey,
        ),
      );

      expect(result.ok, isTrue);
      expect(result.data?.onboardingCompleted, isTrue);
      expect(result.data?.contentLine.contentLineId, 'positioning-1');
      final sent = transport.requests.single;
      expect(sent.method, 'POST');
      expect(sent.url.path, '/api/v1/onboarding/creative-positioning');
      expect(sent.headers['X-Idempotency-Key'], 'onboarding-key');
      expect(_body(sent), <String, Object?>{
        'name': 'Retail voice',
        'industry': 'Retail',
        'accountGoal': 'Lead generation',
        'targetAudience': 'Shop owners',
        'commonExpressions': <String>['conversion', 'trust'],
      });
    });

    test(
      'accepts the deployed direct canonical content-line projection',
      () async {
        final directProjection = Map<String, Object?>.from(
          _successData()['creativePositioning']! as Map<String, Object?>,
        );
        directProjection['isDefault'] = true;
        directProjection['isPlaceholder'] = false;
        final transport = _QueueTransport(<ApiTransportResponse>[
          _response(directProjection),
        ]);
        final api = OnboardingApi(apiClient: _apiClient(transport));

        final result = await api.createFirstContentLine(
          request: buildCreateFirstContentLineRequest(
            name: 'Retail voice',
            industry: 'Retail',
            accountGoal: 'Lead generation',
          )!,
          idempotency: const IdempotencyRequestContext(
            operation: 'onboarding.first_content_line',
            localDraftId: 'first-content-line-direct',
            scene: 'content_line_onboarding',
          ),
        );

        expect(result.ok, isTrue);
        expect(result.data?.onboardingCompleted, isTrue);
        expect(result.data?.contentLine.contentLineId, 'positioning-1');
      },
    );

    test('rejects an incomplete direct canonical projection', () async {
      final directProjection = Map<String, Object?>.from(
        _successData()['creativePositioning']! as Map<String, Object?>,
      )..['isDefault'] = false;
      final transport = _QueueTransport(<ApiTransportResponse>[
        _response(directProjection),
      ]);
      final api = OnboardingApi(apiClient: _apiClient(transport));

      final result = await api.createFirstContentLine(
        request: buildCreateFirstContentLineRequest(
          name: 'Retail voice',
          industry: 'Retail',
          accountGoal: 'Lead generation',
        )!,
        idempotency: const IdempotencyRequestContext(
          operation: 'onboarding.first_content_line',
          localDraftId: 'first-content-line-incomplete',
          scene: 'content_line_onboarding',
        ),
      );

      expect(result.ok, isFalse);
      expect(result.error?.code, 'API_MALFORMED_ENVELOPE');
    });

    test('rejects unsafe local input before transport', () async {
      final transport = _QueueTransport(<ApiTransportResponse>[]);
      final api = OnboardingApi(apiClient: _apiClient(transport));
      const request = CreateFirstContentLineRequest(
        name: 'Retail voice',
        industry: 'Retail',
        accountGoal: 'secret roadmap',
        commonExpressions: <String>[],
      );

      final result = await api.createFirstContentLine(
        request: request,
        idempotency: const IdempotencyRequestContext(
          operation: 'onboarding.first_content_line',
          localDraftId: 'first-content-line-1',
          scene: 'content_line_onboarding',
        ),
      );

      expect(result.ok, isFalse);
      expect(result.error?.code, 'ONBOARDING_CONTENT_LINE_INVALID');
      expect(transport.requests, isEmpty);
    });

    test('rejects a response that exposes an unsafe server field', () async {
      final data = _successData();
      final line = data['creativePositioning']! as Map<String, Object?>;
      line['runtimePath'] = '/home/huahuo-runtime/private';
      final transport = _QueueTransport(<ApiTransportResponse>[
        _response(data),
      ]);
      final api = OnboardingApi(apiClient: _apiClient(transport));

      final result = await api.createFirstContentLine(
        request: buildCreateFirstContentLineRequest(
          name: 'Retail voice',
          industry: 'Retail',
          accountGoal: 'Lead generation',
        )!,
        idempotency: const IdempotencyRequestContext(
          operation: 'onboarding.first_content_line',
          localDraftId: 'first-content-line-1',
          scene: 'content_line_onboarding',
        ),
      );

      expect(result.ok, isFalse);
      expect(result.error?.code, 'API_MALFORMED_ENVELOPE');
    });

    test(
      'reads only an active default positioning for conflict recovery',
      () async {
        final transport = _QueueTransport(<ApiTransportResponse>[
          _response(<String, Object?>{
            'items': <Object?>[
              <String, Object?>{
                'creativePositioningId': 'positioning-secondary',
                'name': 'Secondary',
                'industry': 'Retail',
                'accountGoal': 'Secondary goal',
                'status': 'active',
                'version': 2,
                'isDefault': false,
                'isPlaceholder': false,
              },
              <String, Object?>{
                'creativePositioningId': 'positioning-default',
                'name': 'Primary',
                'industry': 'Retail',
                'accountGoal': 'Primary goal',
                'status': 'active',
                'version': 3,
                'isDefault': true,
                'isPlaceholder': false,
              },
            ],
          }),
        ]);
        final api = OnboardingApi(apiClient: _apiClient(transport));

        final result = await api.readDefaultContentLine();

        expect(result.ok, isTrue);
        expect(result.data?.contentLine?.contentLineId, 'positioning-default');
        expect(result.data?.contentLine?.name, 'Primary');
        final sent = transport.requests.single;
        expect(sent.method, 'GET');
        expect(sent.url.path, '/api/v1/creative-positionings');
        expect(sent.headers['Authorization'], 'Bearer access-token');
      },
    );

    test(
      'creates and reads the server-managed initial positioning attempt',
      () async {
        final transport = _QueueTransport(<ApiTransportResponse>[
          _response(_initialAttempt(state: 'queued')),
          _response(_initialAttempt(state: 'completed')),
        ]);
        final api = OnboardingApi(apiClient: _apiClient(transport));

        final admitted = await api.createInitialPositioningAttempt(
          workspaceId: 'workspace-1',
          agentRunId: 'agent_run_positioning_1',
        );
        final completed = await api.currentInitialPositioning(
          workspaceId: 'workspace-1',
        );

        expect(admitted.data?.state, 'queued');
        expect(completed.data?.isCompleted, isTrue);
        final create = transport.requests.first;
        expect(
          create.url.path,
          '/api/v1/workspaces/workspace-1/initial-positioning/attempts',
        );
        expect(
          create.headers['X-Idempotency-Key'],
          'initial-positioning-agent_run_positioning_1',
        );
        expect(_body(create), <String, Object?>{
          'agentRunId': 'agent_run_positioning_1',
        });
        expect(
          transport.requests.last.url.path,
          '/api/v1/workspaces/workspace-1/initial-positioning/current',
        );
      },
    );

    for (final agentRunId in <String>[
      _productionLengthRunId,
      'agent_run_${List<String>.filled(240, 'a').join()}',
      'agent-run-${List<String>.filled(240, 'a').join()}',
    ]) {
      test(
        'round-trips the full ${agentRunId.length}-character ${agentRunId.substring(0, 10)} Run ID',
        () async {
          final queued = _initialAttempt(
            state: 'queued',
            agentRunId: agentRunId,
          );
          final transport = _QueueTransport(<ApiTransportResponse>[
            _response(queued),
            _response(queued),
            _response(
              _initialAttempt(state: 'completed', agentRunId: agentRunId),
            ),
          ]);
          final api = OnboardingApi(apiClient: _apiClient(transport));

          for (var attempt = 0; attempt < 2; attempt += 1) {
            final result = await api.createInitialPositioningAttempt(
              workspaceId: 'workspace-1',
              agentRunId: agentRunId,
            );
            expect(result.ok, isTrue);
            expect(result.data?.agentRunId, agentRunId);
            expect(result.data?.attemptId, 'positioning_attempt_$agentRunId');
            expect(_body(transport.requests.last), <String, Object?>{
              'agentRunId': agentRunId,
            });
            expect(
              transport.requests.last.headers['X-Idempotency-Key'],
              'initial-positioning-$agentRunId',
            );
          }

          final current = await api.currentInitialPositioning(
            workspaceId: 'workspace-1',
          );
          expect(current.ok, isTrue);
          expect(current.data?.isCompleted, isTrue);
          expect(current.data?.agentRunId, agentRunId);
          expect(current.data?.attemptId, 'positioning_attempt_$agentRunId');
        },
      );
    }

    test('rejects invalid Run identifiers before transport', () async {
      final transport = _QueueTransport(<ApiTransportResponse>[]);
      final api = OnboardingApi(apiClient: _apiClient(transport));
      for (final agentRunId in <String>[
        '',
        'not_an_agent_run',
        'agent_run_',
        'agent_run_${List<String>.filled(241, 'a').join()}',
        'agent_run_invalid/path',
        'agent_run_invalid value',
        'agent_run_中文',
      ]) {
        final result = await api.createInitialPositioningAttempt(
          workspaceId: 'workspace-1',
          agentRunId: agentRunId,
        );
        expect(result.ok, isFalse, reason: agentRunId);
        expect(result.error?.code, 'INITIAL_POSITIONING_INVALID');
      }
      final invalidWorkspace = await api.createInitialPositioningAttempt(
        workspaceId: List<String>.filled(129, 'a').join(),
        agentRunId: _productionLengthRunId,
      );
      expect(invalidWorkspace.ok, isFalse);
      expect(transport.requests, isEmpty);
    });

    test('rejects malformed or mismatched long attempt responses', () {
      final data = _initialAttempt(
        state: 'completed',
        agentRunId: _productionLengthRunId,
      );
      for (final invalidFields in <Map<String, Object?>>[
        <String, Object?>{'workspaceId': 'workspace-other'},
        <String, Object?>{'agentRunId': '${_productionLengthRunId}other'},
        <String, Object?>{'agentRunId': 'not_an_agent_run'},
        <String, Object?>{
          'agentRunId': 'agent_run_${List<String>.filled(241, 'a').join()}',
        },
        <String, Object?>{
          'attemptId': 'positioning_attempt_${_productionLengthRunId}other',
        },
        <String, Object?>{'attemptId': 'positioning_attempt_/unsafe'},
        <String, Object?>{'attemptId': List<String>.filled(150, 'a').join()},
      ]) {
        expect(
          parseInitialPositioningAttempt(
            <String, Object?>{...data, ...invalidFields},
            expectedWorkspaceId: 'workspace-1',
            expectedAgentRunId: _productionLengthRunId,
          ),
          isNull,
          reason: invalidFields.toString(),
        );
      }
    });

    test('retains safe short legacy attempt identifiers', () {
      final parsed = parseInitialPositioningAttempt(
        <String, Object?>{
          ..._initialAttempt(state: 'completed'),
          'attemptId': 'positioning_attempt_1',
        },
        expectedWorkspaceId: 'workspace-1',
        expectedAgentRunId: 'agent_run_positioning_1',
      );
      expect(parsed?.isCompleted, isTrue);
    });

    test(
      'admits canonical report evidence written during the failed attempt',
      () {
        final parsed = parseInitialPositioningAttempt(
          _initialAttempt(
            state: 'failed_terminal',
            failureCode: 'AGENT_RUN_TERMINAL',
            createdAt: '2026-09-10T11:35:28Z',
            updatedAt: '2026-09-10T11:49:14Z',
            finalizedAt: '2026-09-10T11:49:14Z',
            progress: _canonicalProgress(lastUpdated: '2026-09-10T11:35:59Z'),
          ),
          expectedWorkspaceId: 'workspace-1',
          expectedAgentRunId: 'agent_run_positioning_1',
        );

        expect(parsed, isNotNull);
        expect(
          parsed?.reportEvidence?.lastUpdated,
          DateTime.utc(2026, 9, 10, 11, 35, 59),
        );
        expect(parsed?.hasCommittedReportForTerminalGap, isTrue);
      },
    );

    test('does not admit out-of-lifetime or malformed report evidence', () {
      final stale = parseInitialPositioningAttempt(
        _initialAttempt(
          state: 'failed_terminal',
          failureCode: 'AGENT_RUN_TERMINAL',
          createdAt: '2026-09-10T11:35:28Z',
          updatedAt: '2026-09-10T11:49:14Z',
          progress: _canonicalProgress(lastUpdated: '2026-09-10T11:35:27Z'),
        ),
        expectedWorkspaceId: 'workspace-1',
        expectedAgentRunId: 'agent_run_positioning_1',
      );
      final late = parseInitialPositioningAttempt(
        _initialAttempt(
          state: 'failed_terminal',
          failureCode: 'AGENT_RUN_TERMINAL',
          createdAt: '2026-09-10T11:35:28Z',
          updatedAt: '2026-09-10T11:49:14Z',
          progress: _canonicalProgress(lastUpdated: '2026-09-10T11:49:15Z'),
        ),
        expectedWorkspaceId: 'workspace-1',
        expectedAgentRunId: 'agent_run_positioning_1',
      );
      final malformed = parseInitialPositioningAttempt(
        _initialAttempt(
          state: 'failed_terminal',
          failureCode: 'AGENT_RUN_TERMINAL',
          createdAt: '2026-09-10T11:35:28Z',
          updatedAt: '2026-09-10T11:49:14Z',
          progress: <String, Object?>{
            ..._canonicalProgress(lastUpdated: '2026-09-10T11:35:59Z'),
            'targetFile': 'profile/user-positioning/other.md',
          },
        ),
        expectedWorkspaceId: 'workspace-1',
        expectedAgentRunId: 'agent_run_positioning_1',
      );

      expect(stale, isNotNull);
      expect(stale?.reportEvidence, isNotNull);
      expect(stale?.hasCommittedReportForTerminalGap, isFalse);
      expect(late, isNotNull);
      expect(late?.reportEvidence, isNotNull);
      expect(late?.hasCommittedReportForTerminalGap, isFalse);
      expect(malformed, isNotNull);
      expect(malformed?.reportEvidence, isNull);
      expect(malformed?.hasCommittedReportForTerminalGap, isFalse);
    });

    for (final state in const <String>['cancelled', 'superseded']) {
      test('accepts backend terminal attempt state $state', () {
        final parsed = parseInitialPositioningAttempt(
          _initialAttempt(state: state),
          expectedWorkspaceId: 'workspace-1',
          expectedAgentRunId: 'agent_run_positioning_1',
        );

        expect(parsed?.state, state);
        expect(parsed?.isFailure, isTrue);
      });
    }
  });
}

Map<String, Object?> _initialAttempt({
  required String state,
  String agentRunId = 'agent_run_positioning_1',
  String? failureCode,
  Map<String, Object?>? progress,
  String? createdAt,
  String? updatedAt,
  String? finalizedAt,
}) => <String, Object?>{
  'schemaVersion': 'huahuo.initial-positioning.v1',
  'workspaceId': 'workspace-1',
  'state': state,
  if (state != 'not_started') 'attemptId': 'positioning_attempt_$agentRunId',
  if (state != 'not_started') 'agentRunId': agentRunId,
  if (failureCode != null) 'failureCode': failureCode,
  if (progress != null) 'progress': progress,
  if (createdAt != null) 'createdAt': createdAt,
  if (updatedAt != null) 'updatedAt': updatedAt,
  if (finalizedAt != null) 'finalizedAt': finalizedAt,
};

Map<String, Object?> _canonicalProgress({
  required String lastUpdated,
}) => <String, Object?>{
  'source': 'workspace_file',
  'available': true,
  'schemaVersion': 'huahuo.positioning_profile.v1',
  'scoringModel': 'positioning_coverage_v4',
  'targetFile': 'profile/user-positioning/positioning-profile.md',
  'status': 'draft',
  'coldStartPercent': 45,
  'completedPercent': 17,
  'totalWeight': 100,
  'lastUpdated': lastUpdated,
  'modules': const <Map<String, Object?>>[
    <String, Object?>{'id': 'credible_self', 'weight': 10, 'score': 5},
    <String, Object?>{'id': 'audience_person', 'weight': 10, 'score': 2},
    <String, Object?>{'id': 'value_destination', 'weight': 10, 'score': 2},
    <String, Object?>{'id': 'entry_scene', 'weight': 10, 'score': 2},
    <String, Object?>{'id': 'value_delivery', 'weight': 10, 'score': 2},
    <String, Object?>{'id': 'belief_framework', 'weight': 10, 'score': 2},
    <String, Object?>{'id': 'relationship_persona', 'weight': 20, 'score': 1},
    <String, Object?>{'id': 'visual_assets', 'weight': 20, 'score': 1},
  ],
};

Map<String, Object?> _successData() {
  return <String, Object?>{
    'creativePositioning': <String, Object?>{
      'creativePositioningId': 'positioning-1',
      'workspaceId': 'workspace-1',
      'name': 'Retail voice',
      'industry': 'Retail',
      'accountGoal': 'Lead generation',
      'targetAudience': 'Shop owners',
      'status': 'active',
      'version': 1,
      'tags': <Object?>[],
      'relatedRecordingCount': 0,
      'createdAt': '2026-08-01T00:00:00Z',
      'updatedAt': '2026-08-01T00:00:00Z',
    },
    'onboardingCompleted': true,
  };
}

ApiTransportResponse _response(Map<String, Object?> data) {
  return ApiTransportResponse(
    status: 200,
    body: <String, Object?>{'success': true, 'data': data},
  );
}

ApiClient _apiClient(_QueueTransport transport) {
  return ApiClient(
    config: ApiClientConfig(
      baseUrl: Uri.parse('https://api.example.test'),
      clientVersion: 'test',
      deviceId: 'device-1',
      platform: 'test',
      locale: 'en-US',
      getAccessToken: () async => 'access-token',
    ),
    transport: transport,
  );
}

Map<String, Object?> _body(ApiTransportRequest request) {
  final decoded = jsonDecode(request.body ?? '{}') as Map<String, dynamic>;
  return decoded.cast<String, Object?>();
}

String _fixedKey() => 'onboarding-key';

final class _QueueTransport implements ApiTransport {
  _QueueTransport(List<ApiTransportResponse> responses)
    : _responses = List<ApiTransportResponse>.of(responses);

  final List<ApiTransportResponse> _responses;
  final List<ApiTransportRequest> requests = <ApiTransportRequest>[];

  @override
  Future<ApiTransportResponse> send(ApiTransportRequest request) async {
    requests.add(request);
    if (_responses.isEmpty) throw StateError('Unexpected request');
    return _responses.removeAt(0);
  }
}
