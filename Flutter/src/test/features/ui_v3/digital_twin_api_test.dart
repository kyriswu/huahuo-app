import 'dart:convert';
import 'dart:typed_data';

import 'package:huahuo_api/huahuo_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/features/ui_v3/data/digital_twin_api.dart';
import 'package:huahuoai_app/features/ui_v3/data/document_change_proposal_api.dart';
import 'package:huahuoai_app/features/ui_v3/domain/digital_twin_material.dart';

void main() {
  _rebuildCases();
  group('RemoteDigitalTwinApi', () {
    const source = DigitalTwinMaterialSource(
      workspaceId: 'workspace-1',
      noteId: 'note-1',
      rawPartRevisionId: 'raw-1',
      title: '材料',
    );
    for (final profileKind in digitalTwinMaterialProfileKinds) {
      test(
        'creates material through public new-owner Proposal with frozen source and idempotency for $profileKind',
        () async {
          final transport = _QueueTransport([
            _jsonResponse(
              {
                ..._proposalData(version: 1, state: 'generating'),
                'target': {
                  'ownerRef': {'kind': 'profile_conclusion', 'id': 'profile-1'},
                  'part': 'raw',
                  'basePartRevisionId': 'server-base-1',
                  'metadata': {
                    'profileKind': profileKind,
                    'sourceRefs': [
                      {'noteId': 'note-1'},
                    ],
                  },
                },
              },
              headers: {'etag': '"dcp:dcp-1:1"'},
            ),
          ]);
          final snapshot = await _api(transport).createMaterialProposal(
            source: source,
            profileKind: profileKind,
            idempotencyKey: 'material-source-$profileKind',
          );
          final request = transport.requests.single;
          final body = jsonDecode(request.body!) as Map;
          expect(body['agentProfileId'], 'data_body');
          expect(body['target']['ownerRef'], {
            'kind': 'profile_conclusion',
            'id': 'new',
          });
          expect(body['target']['basePartRevisionId'], isNull);
          expect(body['target']['metadata']['newOwner'], isTrue);
          expect(body['target']['metadata']['profileKind'], profileKind);
          expect(body['target']['metadata']['sourceRefs'], [
            {
              'workspaceId': 'workspace-1',
              'sourceKind': 'note_part_revision',
              'noteId': 'note-1',
              'part': 'raw',
              'partRevisionId': 'raw-1',
            },
          ]);
          expect(
            request.headers['X-Idempotency-Key'],
            'material-source-$profileKind',
          );
          expect(snapshot.proposal.noteId, 'profile-1');
        },
      );
    }
    test(
      'rejects material owner mismatch and cross-workspace sources',
      () async {
        final transport = _QueueTransport([
          _jsonResponse(
            _proposalData(version: 1, state: 'generating'),
            headers: {'etag': '"dcp:dcp-1:1"'},
          ),
        ]);
        final api = _api(transport);
        await expectLater(
          api.createMaterialProposal(
            source: source,
            profileKind: 'user_profile',
            idempotencyKey: 'material-test',
          ),
          throwsA(
            isA<DigitalTwinApiException>().having(
              (error) => error.code,
              'code',
              'DIGITAL_TWIN_MATERIAL_PROPOSAL_MISMATCH',
            ),
          ),
        );
        await expectLater(
          api.createMaterialProposal(
            source: const DigitalTwinMaterialSource(
              workspaceId: 'other',
              noteId: 'note-1',
              rawPartRevisionId: 'raw-1',
              title: '材料',
            ),
            profileKind: 'user_profile',
            idempotencyKey: 'material-test',
          ),
          throwsA(isA<DigitalTwinApiException>()),
        );
        expect(transport.requests, hasLength(1));
      },
    );
    test('discovers only material-owned twin proposals across pages', () async {
      Map<String, Object?> proposal(
        String id,
        String sourceNoteId,
        String ownerKind,
      ) => {
        ..._proposalData(version: 1, state: 'ready'),
        'proposalId': id,
        'hasChanges': true,
        'target': {
          'ownerRef': {'kind': ownerKind, 'id': 'profile-1'},
          'part': 'raw',
          'basePartRevisionId': 'part-1',
          'metadata': {
            'profileKind': 'user_profile',
            'sourceRefs': [
              {'noteId': sourceNoteId},
            ],
          },
        },
      };
      final transport = _QueueTransport([
        _jsonResponse({
          'task': {'taskId': 'distill-1', 'status': 'succeeded'},
        }),
        _jsonResponse({
          'items': [proposal('unrelated', 'other-note', 'profile_conclusion')],
          'nextCursor': 'next-page',
        }),
        _jsonResponse({
          'items': [
            proposal('owned', 'note-1', 'profile_conclusion'),
            proposal('note-edit', 'note-1', 'hnote'),
          ],
        }),
      ]);
      final api = _api(transport);
      expect((await api.getDistillationTask('distill-1')).status, 'succeeded');
      final proposals = await api.getImportProposals('note-1');
      expect(proposals.map((snapshot) => snapshot.proposal.proposalId), [
        'owned',
      ]);
      expect(proposals.single.etag, '"dcp:owned:1"');
      expect(
        transport.requests.last.url.queryParameters['cursor'],
        'next-page',
      );
      expect(transport.requests.last.url.queryParameters['limit'], '50');
    });

    test(
      'reads the current projection, version list, and preview wrappers',
      () async {
        final transport = _QueueTransport(<ApiTransportResponse>[
          _jsonResponse({
            ..._currentData(),
            'activeDraft': {
              'items': [
                {'proposalId': 'generating-1'},
              ],
            },
          }),
          _jsonResponse(<String, Object?>{
            'items': <Object?>[_versionData()],
          }),
          _jsonResponse(<String, Object?>{
            'files': <Object?>[_fileData(pendingProposalIds: const <String>[])],
          }),
        ]);
        final api = _api(transport);

        final current = await api.getCurrent();
        final versions = await api.getVersions();
        final preview = await api.getPreview('dtv-0');

        expect(current.agentProfileId, digitalTwinAgentProfileId);
        expect(current.activeProposalIds, ['generating-1']);
        expect(current.files.single.pendingProposalIds, <String>['dcp-1']);
        expect(versions.single.label, 'v0');
        expect(preview.single.name, 'Positioning');
        expect(transport.requests.map((request) => request.url.path), <String>[
          '/api/v1/workspaces/workspace-1/digital-twin',
          '/api/v1/workspaces/workspace-1/digital-twin/versions',
          '/api/v1/workspaces/workspace-1/digital-twin/versions/dtv-0/preview',
        ]);
      },
    );

    test(
      'sends revision and confirmation preconditions and pulls an archive',
      () async {
        final transport = _QueueTransport(<ApiTransportResponse>[
          _jsonResponse(_scheduleData(enabled: true)),
          _jsonResponse(
            _proposalData(version: 2, state: 'generating'),
            status: 202,
            headers: const <String, String>{'etag': '"dcp:dcp-1:2"'},
          ),
          _jsonResponse(<String, Object?>{
            'confirmationTaskId': 'task-1',
            'workspaceId': 'workspace-1',
            'state': 'report_ready',
            'outcomes': <Object?>[
              <String, Object?>{
                'proposalId': 'dcp-1',
                'proposalVersion': 1,
                'state': 'applied',
              },
            ],
            'appliedCount': 1,
            'failedCount': 0,
            'version': _versionData(number: 1, id: 'dtv-1'),
          }, status: 202),
          _jsonResponse(<String, Object?>{
            'baseVersion': _versionData(),
            'version': _versionData(number: 1, id: 'dtv-1'),
            'files': <Object?>[
              <String, Object?>{
                'id': 'positioning',
                'name': 'Positioning',
                'summary': const <String, Object?>{
                  'hunks': 0,
                  'insertedLines': 0,
                  'deletedLines': 0,
                  'changedLines': 0,
                  'hasChanges': false,
                },
                'hunks': const <Object?>[],
              },
            ],
          }),
          ApiTransportResponse(
            status: 200,
            body: Uint8List.fromList(<int>[80, 75, 3, 4]),
          ),
        ]);
        final api = _api(transport);
        const proposal = DocumentChangeProposalSnapshot(
          proposal: DocumentChangeProposal(
            proposalId: 'dcp-1',
            proposalVersion: 1,
            rowVersion: 1,
            state: DocumentProposalState.ready,
            ownerKind: 'workspace_standard_file',
            noteId: 'positioning.md',
            rawPartRevisionId: 'part-1',
            candidateAvailable: true,
          ),
          etag: '"dcp:dcp-1:1"',
        );

        await api.updateSchedule(
          const DigitalTwinScheduleDraft(
            enabled: true,
            intervalDays: 7,
            preferredLocalTime: '09:00',
            timezone: 'Asia/Shanghai',
            instruction: 'Review recent material.',
          ),
          idempotencyKey: 'schedule-key',
        );
        final revised = await api.reviseProposal(
          proposal: proposal,
          instruction: 'Keep the first change.',
          selectedHunks: const <DigitalTwinSelectedHunk>[
            DigitalTwinSelectedHunk(
              proposalVersion: 1,
              diffBundleId: 'diff-1',
              hunkId: 'hunk-1',
              quotedText: 'Candidate',
            ),
          ],
          idempotencyKey: 'revise-key',
        );
        final confirmation = await api.createConfirmation(
          proposals: const <DocumentChangeProposalSnapshot>[proposal],
          idempotencyKey: 'confirm-key',
          source: const DigitalTwinImportSource(
            importTaskId: 'import-1',
            taskId: 'distill-1',
            resourceId: 'resource-1',
            noteId: 'note-1',
            title: 'Meeting',
          ),
        );
        final comparison = await api.compareVersions(
          baseVersionId: 'dtv-0',
          versionId: 'dtv-1',
        );
        final archive = await api.downloadVersion('dtv-1');

        expect(revised.etag, '"dcp:dcp-1:2"');
        expect(confirmation.version?.label, 'v1');
        expect(comparison.files.single.summary.hasChanges, isFalse);
        expect(archive, Uint8List.fromList(<int>[80, 75, 3, 4]));

        final scheduleRequest = transport.requests[0];
        expect(scheduleRequest.headers['X-Idempotency-Key'], 'schedule-key');
        final reviseRequest = transport.requests[1];
        expect(reviseRequest.headers['If-Match'], '"dcp:dcp-1:1"');
        expect(reviseRequest.headers['X-Idempotency-Key'], 'revise-key');
        expect(jsonDecode(reviseRequest.body!), <String, Object?>{
          'baseProposalVersion': 1,
          'instruction': 'Keep the first change.',
          'selectedHunks': <Object?>[
            <String, Object?>{
              'proposalVersion': 1,
              'diffBundleId': 'diff-1',
              'hunkId': 'hunk-1',
              'quotedText': 'Candidate',
            },
          ],
          'agentProfileId': digitalTwinAgentProfileId,
        });
        expect(
          transport.requests[2].headers['X-Idempotency-Key'],
          'confirm-key',
        );
        final confirmationBody = jsonDecode(transport.requests[2].body!);
        expect(confirmationBody['sourceTaskId'], 'distill-1');
        expect(confirmationBody['triggerId'], 'resource-1');
        expect(confirmationBody['proposals'], [
          {
            'proposalId': 'dcp-1',
            'proposalVersion': 1,
            'etag': '"dcp:dcp-1:1"',
          },
        ]);
        expect(transport.requests[3].url.queryParameters, <String, String>{
          'baseVersionId': 'dtv-0',
        });
      },
    );

    test(
      'restores a formal version through an idempotent empty command',
      () async {
        final transport = _QueueTransport(<ApiTransportResponse>[
          _jsonResponse(<String, Object?>{
            'taskId': 'restore-task',
            'versionId': 'dtv-0',
            'state': 'proposals_created',
            'proposalIds': <String>['dcp-restore'],
          }, status: 202),
        ]);
        final restore = await _api(
          transport,
        ).restoreVersion('dtv-0', idempotencyKey: 'restore-key');

        expect(restore.proposalIds, <String>['dcp-restore']);
        expect(
          transport.requests.single.url.path,
          '/api/v1/workspaces/workspace-1/digital-twin/versions/dtv-0/restore',
        );
        expect(
          transport.requests.single.headers['X-Idempotency-Key'],
          'restore-key',
        );
        expect(
          jsonDecode(transport.requests.single.body!),
          <String, Object?>{},
        );
      },
    );
  });
}

RemoteDigitalTwinApi _api(ApiTransport transport) => RemoteDigitalTwinApi(
  apiClient: ApiClient(
    config: ApiClientConfig(
      baseUrl: Uri.parse('https://api.example.test'),
      clientVersion: 'test',
      deviceId: 'device-1',
      platform: 'test',
      locale: 'en',
      getAccessToken: () async => 'access-token',
    ),
    transport: transport,
  ),
  workspaceId: () => 'workspace-1',
);

ApiTransportResponse _jsonResponse(
  Map<String, Object?> data, {
  int status = 200,
  Map<String, String> headers = const <String, String>{},
}) => ApiTransportResponse(
  status: status,
  headers: headers,
  body: <String, Object?>{'success': true, 'data': data},
);

Map<String, Object?> _currentData() => <String, Object?>{
  'schemaVersion': 'huahuo.digital-twin.v1',
  'workspaceId': 'workspace-1',
  'agentProfileId': digitalTwinAgentProfileId,
  'state': 'pending_review',
  'level': const <String, Object?>{
    'value': 1,
    'name': 'Initial grounding',
    'completionPercent': 20,
    'scoringModel': 'positioning.v1',
  },
  'pendingReviewCount': 1,
  'pendingProposalCount': 1,
  'files': <Object?>[_fileData()],
  'currentVersion': _versionData(),
  'updatedAt': '2026-08-29T01:02:03Z',
};

Map<String, Object?> _fileData({
  List<String> pendingProposalIds = const <String>['dcp-1'],
}) => <String, Object?>{
  'id': 'positioning',
  'name': 'Positioning',
  'exists': true,
  'markdown': '# Positioning',
  'conclusions': const <Object?>[],
  'pendingCount': pendingProposalIds.length,
  'pendingProposalIds': pendingProposalIds,
};

Map<String, Object?> _versionData({int number = 0, String id = 'dtv-0'}) =>
    <String, Object?>{
      'versionId': id,
      'versionNumber': number,
      'label': 'v$number',
      'workspaceVersion': 1,
      'completionPercent': 20,
      'scoringModel': 'positioning.v1',
      'createdAt': '2026-08-29T01:02:03Z',
    };

Map<String, Object?> _scheduleData({required bool enabled}) =>
    <String, Object?>{
      'scheduleId': 'schedule-1',
      'enabled': enabled,
      'intervalDays': 7,
      'preferredLocalTime': '09:00',
      'timezone': 'Asia/Shanghai',
      'instruction': 'Review recent material.',
      'sourceScope': 'digital_twin_and_recent_workspace_refs',
      'version': 1,
    };

Map<String, Object?> _proposalData({
  required int version,
  required String state,
}) => <String, Object?>{
  'proposalId': 'dcp-1',
  'proposalVersion': version,
  'rowVersion': version,
  'state': state,
  'target': const <String, Object?>{
    'ownerRef': <String, Object?>{
      'kind': 'workspace_standard_file',
      'id': 'positioning.md',
    },
    'part': 'raw',
    'basePartRevisionId': 'part-1',
  },
  'candidateAvailable': state != 'generating',
};

final class _QueueTransport implements ApiTransport {
  _QueueTransport(Iterable<ApiTransportResponse> responses)
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

void _rebuildCases() {
  test(
    'recovery: regenerate preserves new-owner metadata and source revisions',
    () async {
      final data = {
        ..._proposalData(version: 1, state: 'generation_failed'),
        'target': {
          'ownerRef': {'kind': 'profile_conclusion', 'id': 'profile-old'},
          'part': 'raw',
          'basePartRevisionId': 'base-old',
          'metadata': {
            'profileKind': 'user_profile',
            'newOwner': true,
            'sourceRefs': [
              {'noteId': 'note-1', 'partRevisionId': 'note-part-1'},
            ],
          },
        },
      };
      final transport = _QueueTransport([
        _jsonResponse(data, headers: {'etag': '"dcp:dcp-1:1"'}),
        _jsonResponse(
          {...data, 'proposalId': 'replacement', 'state': 'generating'},
          status: 202,
          headers: {'etag': '"dcp:replacement:1"'},
        ),
      ]);
      final result = await _api(transport).regenerateProposal(
        proposal: DocumentChangeProposalSnapshot(
          proposal: DocumentChangeProposal.fromValue(data),
          etag: '"dcp:dcp-1:1"',
        ),
        instruction: '只使用原始来源',
        idempotencyKey: 'rebuild-1',
      );
      final request =
          jsonDecode(transport.requests.last.body!) as Map<String, dynamic>;
      expect(request['target']['ownerRef']['id'], 'new');
      expect(
        request['target']['metadata']['sourceRefs'].single['partRevisionId'],
        'note-part-1',
      );
      expect(request['target'].containsKey('partRevisionId'), isFalse);
      expect(result.proposal.proposalId, 'replacement');
    },
  );

  test('recovery: stale rebuild uses server-issued applied revision', () async {
    final data = _proposalData(version: 1, state: 'stale');
    final applied = {
      ..._proposalData(version: 1, state: 'applied'),
      'proposalId': 'applied-other',
      'applied': {
        'partRevisionId': 'current-server-revision',
        'ownerRevisionId': 'owner-2',
        'hash': 'sha256:value',
      },
    };
    final transport = _QueueTransport([
      _jsonResponse(data, headers: {'etag': '"dcp:dcp-1:1"'}),
      _jsonResponse({
        'items': [applied],
      }),
      _jsonResponse(
        {...data, 'proposalId': 'replacement', 'state': 'generating'},
        status: 202,
        headers: {'etag': '"dcp:replacement:1"'},
      ),
    ]);
    await _api(transport).regenerateProposal(
      proposal: DocumentChangeProposalSnapshot(
        proposal: DocumentChangeProposal.fromValue(data),
        etag: '"dcp:dcp-1:1"',
      ),
      instruction: '',
      idempotencyKey: 'rebuild-2',
    );
    expect(
      jsonDecode(transport.requests.last.body!)['target']['partRevisionId'],
      'current-server-revision',
    );
    expect(transport.requests[1].url.queryParameters['state'], 'applied');
  });
}
