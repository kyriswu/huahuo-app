import 'package:huahuo_api/huahuo_api.dart';
import 'package:huahuo_api/account_usage.dart';
import 'package:huahuoai_app/features/billing/data/account_usage_repository.dart';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:huahuoai_app/features/billing/application/account_usage_controller.dart';
import 'package:huahuoai_app/features/billing/domain/account_usage_repository.dart';

void main() {
  test('refresh coalesces callers and keeps values while waiting', () async {
    final gate = Completer<MobileAccountUsageResult<MobileAccountCreditPage>>();
    final port = _AccountUsagePort(
      membershipResult: MobileAccountUsageResult.success(_membership()),
      creditResults: [MobileAccountUsageResult.success(_creditPage('lot-1'))],
      creditFutures: [gate.future],
    );
    final controller = AccountUsageController(repository: port);
    addTearDown(controller.dispose);
    await controller.load();
    final first = controller.load();
    final second = controller.load();
    expect(identical(first, second), isTrue);
    expect(controller.loading, isTrue);
    expect(controller.creditSummary?.monthlyCredit.availableCredits, 9000);
    expect(port.creditCursors, [null, null]);
    gate.complete(MobileAccountUsageResult.success(_creditPage('lot-2')));
    await Future.wait([first, second]);
    expect(controller.loading, isFalse);
    expect(controller.creditLots.single.lotId, 'lot-2');
  });

  test('full refresh rejects late credit pagination', () async {
    final gate = Completer<MobileAccountUsageResult<MobileAccountCreditPage>>();
    final port = _AccountUsagePort(
      membershipResult: MobileAccountUsageResult.success(_membership()),
      creditResults: [
        MobileAccountUsageResult.success(
          _creditPage('initial', nextCursor: 'next'),
        ),
      ],
      creditFutures: [gate.future],
    );
    final controller = AccountUsageController(repository: port);
    addTearDown(controller.dispose);
    await controller.load();
    final pagination = controller.loadMoreCredits();
    port.creditResults.add(
      MobileAccountUsageResult.success(_creditPage('refreshed')),
    );
    await controller.load();
    gate.complete(MobileAccountUsageResult.success(_creditPage('obsolete')));
    await pagination;
    expect(controller.creditLots.map((lot) => lot.lotId), ['refreshed']);
  });

  test('public Home quotas preserve seconds and signed adjustments', () async {
    final transport = _AccountTransport([
      ApiTransportResponse(
        status: 200,
        body: {
          'success': true,
          'data': {
            'quotaSummary': {
              'balances': [_quotaJson()],
            },
          },
        },
      ),
    ]);
    final port = _repository(
      _accountApiClient(transport),
      workspaceId: () => 'ws_1',
    );
    final result = await port.quotaBalances();
    expect(result.status, MobileAccountUsageResultStatus.success);
    expect(result.data?.single.used, 3661.5);
    expect(result.data?.single.adjusted, -600);
    expect(result.data?.single.effectiveLimit, 35400);
    expect(result.data?.single.periodStart, DateTime.utc(2026, 9));
    expect(transport.requests.single.url.path, '/api/v1/home');
  });

  test('missing invalid or empty quota data never becomes zero', () async {
    for (final value in [null, -1, '100', double.nan]) {
      expect(
        () => AccountQuotaBalance.fromJson({
          ..._quotaJson(),
          'usedAmount': value,
        }),
        throwsFormatException,
      );
    }
    final transport = _AccountTransport([
      const ApiTransportResponse(
        status: 200,
        body: {
          'success': true,
          'data': {
            'quotaSummary': {'balances': []},
          },
        },
      ),
    ]);
    final port = _repository(
      _accountApiClient(transport),
      workspaceId: () => 'ws_1',
    );
    expect(
      (await port.quotaBalances()).status,
      isNot(MobileAccountUsageResultStatus.success),
    );
  });

  test('zero cloud allowance and breakdown remain readable', () async {
    final source = _storageUsageResponse();
    final body = Map<String, Object?>.from(source.body! as Map);
    body['data'] = {
      ...body['data']! as Map,
      'limitBytes': 0,
      'remainingBytes': 0,
    };
    final port = _repository(
      _accountApiClient(
        _AccountTransport([ApiTransportResponse(status: 200, body: body)]),
      ),
      workspaceId: () => 'ws_1',
    );
    final result = await port.storageUsage();
    expect(result.data?.limitBytes, 0);
    expect(result.data?.resourceBytes, 70);
    expect(result.data?.calculatedAt, DateTime.utc(2026, 8, 19));
  });

  test('API27 membership remains ready when credit read fails', () async {
    final port = _AccountUsagePort(
      membershipResult:
          MobileAccountUsageResult<MobileAccountMembership>.success(
            _membership(),
          ),
      creditResults: <MobileAccountUsageResult<MobileAccountCreditPage>>[
        const MobileAccountUsageResult<MobileAccountCreditPage>.failure(
          'ACCOUNT_CREDIT_UNAVAILABLE',
        ),
      ],
    );
    final controller = AccountUsageController(repository: port);

    await controller.load();

    expect(controller.status, AccountUsageStatus.partial);
    expect(controller.membership?.levelCode, 'pilot_paid');
    expect(controller.membership?.monthlyCredit.availableCredits, 9000);
    expect(controller.creditErrorCode, 'ACCOUNT_CREDIT_UNAVAILABLE');
    expect(controller.storageUsage?.limitBytes, 32212254720);
  });

  test(
    'credit pagination deduplicates lots and stops a repeated cursor',
    () async {
      final port = _AccountUsagePort(
        membershipResult:
            MobileAccountUsageResult<MobileAccountMembership>.success(
              _membership(),
            ),
        creditResults: <MobileAccountUsageResult<MobileAccountCreditPage>>[
          MobileAccountUsageResult<MobileAccountCreditPage>.success(
            _creditPage('lot-1', nextCursor: 'cursor-2'),
          ),
          MobileAccountUsageResult<MobileAccountCreditPage>.success(
            _creditPage('lot-1', nextCursor: 'cursor-2'),
          ),
        ],
      );
      final controller = AccountUsageController(repository: port);
      await controller.load();
      await controller.loadMoreCredits();

      expect(controller.creditLots, hasLength(1));
      expect(controller.hasMoreCredits, isFalse);
      expect(controller.creditErrorCode, 'ACCOUNT_CREDIT_CURSOR_INVALID');
    },
  );

  test(
    'typed Run Usage is owner-keyed and invalid IDs never call API',
    () async {
      final port = _AccountUsagePort(
        membershipResult:
            MobileAccountUsageResult<MobileAccountMembership>.success(
              _membership(),
            ),
        creditResults: <MobileAccountUsageResult<MobileAccountCreditPage>>[],
        runResults: <MobileAccountUsageResult<MobileRunUsage>>[
          MobileAccountUsageResult<MobileRunUsage>.success(_runUsage()),
        ],
      );
      final controller = AccountUsageController(repository: port);

      final invalid = await controller.loadRunUsage('  ');
      final valid = await controller.loadRunUsage('run opaque/+1');

      expect(invalid.errorCode, 'RUN_USAGE_ID_INVALID');
      expect(valid.status, MobileAccountUsageResultStatus.success);
      expect(port.runIds, <String>['run opaque/+1']);
      expect(controller.runUsageFor('run opaque/+1')?.accountedCredits, 120);
      expect(
        controller.runUsageFor('run opaque/+1')?.assistantResultPersisted,
        isTrue,
      );
    },
  );

  test('refresh failure cannot report ready from stale API27 data', () async {
    final port = _AccountUsagePort(
      membershipResult:
          MobileAccountUsageResult<MobileAccountMembership>.success(
            _membership(),
          ),
      creditResults: <MobileAccountUsageResult<MobileAccountCreditPage>>[
        MobileAccountUsageResult<MobileAccountCreditPage>.success(
          _creditPage('lot-1'),
        ),
      ],
    );
    final controller = AccountUsageController(repository: port);
    await controller.load();
    expect(controller.status, AccountUsageStatus.ready);

    port.membershipResult =
        const MobileAccountUsageResult<MobileAccountMembership>.failure(
          'MEMBERSHIP_DOWN',
        );
    port.creditResults.add(
      const MobileAccountUsageResult<MobileAccountCreditPage>.failure(
        'CREDITS_DOWN',
      ),
    );
    await controller.load();

    expect(controller.status, AccountUsageStatus.partial);
    expect(controller.membership?.monthlyCredit.availableCredits, 9000);
    expect(controller.creditSummary?.monthlyCredit.availableCredits, 9000);
    expect(controller.membershipErrorCode, 'MEMBERSHIP_DOWN');
    expect(controller.creditErrorCode, 'CREDITS_DOWN');
    expect(controller.storageUsage?.limitBytes, 32212254720);
  });

  test(
    'storage failure is explicit without hiding membership or credits',
    () async {
      final controller = AccountUsageController(
        repository: _AccountUsagePort(
          membershipResult:
              MobileAccountUsageResult<MobileAccountMembership>.success(
                _membership(),
              ),
          creditResults: <MobileAccountUsageResult<MobileAccountCreditPage>>[
            MobileAccountUsageResult<MobileAccountCreditPage>.success(
              _creditPage('lot-1'),
            ),
          ],
          storageResult:
              const MobileAccountUsageResult<
                MobileWorkspaceStorageUsage
              >.failure('WORKSPACE_STORAGE_UNAVAILABLE'),
        ),
      );

      await controller.load();

      expect(controller.status, AccountUsageStatus.partial);
      expect(controller.membership, isNotNull);
      expect(controller.creditSummary, isNotNull);
      expect(controller.storageUsage, isNull);
      expect(controller.storageErrorCode, 'WORKSPACE_STORAGE_UNAVAILABLE');
    },
  );

  test('credit load-more duplicate tap sends one cursor request', () async {
    final gate = Completer<MobileAccountUsageResult<MobileAccountCreditPage>>();
    final port = _AccountUsagePort(
      membershipResult:
          MobileAccountUsageResult<MobileAccountMembership>.success(
            _membership(),
          ),
      creditResults: <MobileAccountUsageResult<MobileAccountCreditPage>>[
        MobileAccountUsageResult<MobileAccountCreditPage>.success(
          _creditPage('lot-1', nextCursor: 'cursor-2'),
        ),
      ],
      creditFutures:
          <Future<MobileAccountUsageResult<MobileAccountCreditPage>>>[
            gate.future,
          ],
    );
    final controller = AccountUsageController(repository: port);
    await controller.load();

    final first = controller.loadMoreCredits();
    await controller.loadMoreCredits();
    expect(port.creditCursors, <String?>[null, 'cursor-2']);
    gate.complete(
      MobileAccountUsageResult<MobileAccountCreditPage>.success(
        _creditPage('lot-2'),
      ),
    );
    await first;
    expect(controller.creditLots, hasLength(2));
  });

  test(
    'thrown Port failures terminate loading and release Run guards',
    () async {
      final port = _AccountUsagePort(
        membershipResult:
            MobileAccountUsageResult<MobileAccountMembership>.success(
              _membership(),
            ),
        creditResults: <MobileAccountUsageResult<MobileAccountCreditPage>>[
          MobileAccountUsageResult<MobileAccountCreditPage>.success(
            _creditPage('lot-1'),
          ),
        ],
        runResults: <MobileAccountUsageResult<MobileRunUsage>>[
          MobileAccountUsageResult<MobileRunUsage>.success(_runUsage()),
        ],
        throwMembership: true,
        runThrowsRemaining: 1,
      );
      final controller = AccountUsageController(repository: port);

      await controller.load();
      final failed = await controller.loadRunUsage('run opaque/+1');
      final recovered = await controller.loadRunUsage('run opaque/+1');

      expect(controller.status, AccountUsageStatus.partial);
      expect(controller.loading, isFalse);
      expect(controller.membershipErrorCode, 'ACCOUNT_MEMBERSHIP_LOAD_FAILED');
      expect(failed.errorCode, 'RUN_USAGE_LOAD_FAILED');
      expect(recovered.status, MobileAccountUsageResultStatus.success);
      expect(controller.isRunUsageLoading('run opaque/+1'), isFalse);
      expect(port.runIds, <String>['run opaque/+1', 'run opaque/+1']);
    },
  );

  test(
    'remote API27 port parses membership credits Run Usage and errors',
    () async {
      final transport = _AccountTransport(<ApiTransportResponse>[
        _membershipResponse(),
        _creditsResponse(),
        _runUsageResponse(),
      ]);
      final port = _repository(
        _accountApiClient(transport),
        workspaceId: () => 'ws_1',
      );

      final membership = await port.membership();
      final credits = await port.credits(cursor: 'opaque cursor', limit: 25);
      final usage = await port.runUsage('run opaque/+1');

      expect(membership.data?.levelCode, 'pilot_paid');
      expect(membership.data?.monthlyCredit.availableCredits, 9000000);
      expect(credits.data?.lots.single.originKind, 'admin_grant');
      expect(credits.data?.nextCursor, 'next opaque');
      expect(usage.data?.accountedCredits, 120);
      expect(usage.data?.measurements.single.usageKind, 'text_input');
      expect(transport.requests[0].url.path, '/api/v1/membership');
      expect(transport.requests[1].url.path, '/api/v1/account/credits');
      expect(transport.requests[2].url.path, contains('/api/v1/runs/'));
      expect(transport.requests[2].url.path, endsWith('/usage'));
      expect(transport.requests[1].url.queryParameters, <String, String>{
        'cursor': 'opaque cursor',
        'limit': '25',
      });

      final unavailable = _repository(
        _accountApiClient(
          _AccountTransport(<ApiTransportResponse>[
            const ApiTransportResponse(
              status: 503,
              body: <String, Object?>{
                'success': false,
                'error': <String, Object?>{
                  'code': 'ACCOUNT_USAGE_UNAVAILABLE',
                  'message': 'unavailable',
                  'retryable': true,
                },
              },
            ),
          ]),
        ),
        workspaceId: () => 'ws_1',
      );
      expect(
        (await unavailable.membership()).status,
        MobileAccountUsageResultStatus.unavailable,
      );
    },
  );

  test(
    'workspace storage keeps the server 30 GiB limit and nullable count',
    () async {
      final transport = _AccountTransport(<ApiTransportResponse>[
        _storageUsageResponse(),
      ]);
      final port = _repository(
        _accountApiClient(transport),
        workspaceId: () => 'ws_1',
      );

      final storage = await port.storageUsage();

      expect(storage.data?.limitBytes, 32212254720);
      expect(storage.data?.remainingBytes, 32212254620);
      expect(storage.data?.fileCountLimit, isNull);
      expect(
        transport.requests.single.url.path,
        '/api/v1/workspaces/ws_1/storage-usage',
      );
    },
  );
}

Map<String, Object?> _quotaJson() => {
  'quotaType': 'asr_seconds',
  'limitAmount': 36000,
  'usedAmount': 3661.5,
  'reservedAmount': 10,
  'adjustedAmount': -600,
  'remainingAmount': 31728.5,
  'uncoveredAmount': 0,
  'periodStart': '2026-09-01T00:00:00Z',
  'periodEnd': '2026-10-01T00:00:00Z',
};

MobileAccountMembership _membership() {
  return MobileAccountMembership(
    membershipId: 'membership-1',
    levelCode: 'pilot_paid',
    status: 'active',
    expiresAt: null,
    monthlyCredit: _pool(monthly: true),
    permanentCredit: _pool(),
    runAdmission: 'allowed',
    outstandingUncoveredCredits: 0,
  );
}

MobileCreditPool _pool({bool monthly = false}) {
  return MobileCreditPool(
    quotaCredits: monthly ? 10000 : null,
    availableCredits: monthly ? 9000 : 500,
    reservedCredits: 100,
    settledCredits: monthly ? 900 : null,
    policyVersion: monthly ? 'credit-policy-v1' : null,
    periodStart: monthly ? DateTime.utc(2026, 8, 1) : null,
    periodEnd: monthly ? DateTime.utc(2026, 9, 1) : null,
  );
}

MobileAccountCreditPage _creditPage(String lotId, {String? nextCursor}) {
  return MobileAccountCreditPage(
    monthlyCredit: _pool(monthly: true),
    permanentCredit: _pool(),
    lots: <MobilePermanentCreditLot>[
      MobilePermanentCreditLot(
        lotId: lotId,
        originKind: 'admin_grant',
        originalCredits: 500,
        availableCredits: 500,
        reservedCredits: 0,
        createdAt: DateTime.utc(2026, 8, 1),
      ),
    ],
    runAdmission: 'allowed',
    outstandingUncoveredCredits: 0,
    nextCursor: nextCursor,
  );
}

MobileRunUsage _runUsage() {
  return const MobileRunUsage(
    runId: 'run opaque/+1',
    policyVersion: 'credit-policy-v1',
    rawInputTokens: 100,
    rawOutputTokens: 20,
    accountedCredits: 120,
    settlementStatus: 'settled',
    assistantResultPersisted: true,
    measurements: <MobileRunUsageMeasurement>[
      MobileRunUsageMeasurement(
        usageKind: 'text_input',
        measurementStatus: 'measured',
        accountedCredits: 100,
        rawInputTokens: 100,
      ),
    ],
  );
}

final class _AccountUsagePort implements AccountUsageRepository {
  @override
  Future<MobileAccountUsageResult<List<MobileQuotaBalance>>>
  quotaBalances() async => const MobileAccountUsageResult.success([]);

  _AccountUsagePort({
    required this.membershipResult,
    required this.creditResults,
    List<Future<MobileAccountUsageResult<MobileAccountCreditPage>>>?
    creditFutures,
    List<MobileAccountUsageResult<MobileRunUsage>>? runResults,
    MobileAccountUsageResult<MobileWorkspaceStorageUsage>? storageResult,
    this.throwMembership = false,
    this.runThrowsRemaining = 0,
  }) : creditFutures =
           creditFutures ??
           <Future<MobileAccountUsageResult<MobileAccountCreditPage>>>[],
       runResults = runResults ?? <MobileAccountUsageResult<MobileRunUsage>>[],
       storageResult =
           storageResult ??
           MobileAccountUsageResult<MobileWorkspaceStorageUsage>.success(
             _storageUsage(),
           );

  MobileAccountUsageResult<MobileAccountMembership> membershipResult;
  final List<MobileAccountUsageResult<MobileAccountCreditPage>> creditResults;
  final List<Future<MobileAccountUsageResult<MobileAccountCreditPage>>>
  creditFutures;
  final List<MobileAccountUsageResult<MobileRunUsage>> runResults;
  MobileAccountUsageResult<MobileWorkspaceStorageUsage> storageResult;
  final bool throwMembership;
  int runThrowsRemaining;
  final List<String> runIds = <String>[];
  final List<String?> creditCursors = <String?>[];

  @override
  Future<MobileAccountUsageResult<MobileAccountCreditPage>> credits({
    String? cursor,
    int limit = 50,
  }) {
    creditCursors.add(cursor);
    if (creditResults.isNotEmpty) {
      return Future<MobileAccountUsageResult<MobileAccountCreditPage>>.value(
        creditResults.removeAt(0),
      );
    }
    return creditFutures.removeAt(0);
  }

  @override
  Future<MobileAccountUsageResult<MobileAccountMembership>> membership() async {
    if (throwMembership) throw StateError('membership transport failed');
    return membershipResult;
  }

  @override
  Future<MobileAccountUsageResult<MobileRunUsage>> runUsage(
    String runId,
  ) async {
    runIds.add(runId);
    if (runThrowsRemaining > 0) {
      runThrowsRemaining -= 1;
      throw StateError('run usage transport failed');
    }
    return runResults.removeAt(0);
  }

  @override
  Future<MobileAccountUsageResult<MobileWorkspaceStorageUsage>>
  storageUsage() async => storageResult;
}

MobileWorkspaceStorageUsage _storageUsage() =>
    const MobileWorkspaceStorageUsage(
      userLogicalTotalBytes: 100,
      limitBytes: 32212254720,
      remainingBytes: 32212254620,
      fileCountLimit: null,
      measurementStatus: 'complete',
    );

ApiClient _accountApiClient(_AccountTransport transport) => ApiClient(
  config: ApiClientConfig(
    baseUrl: Uri.parse('https://api.example.test'),
    clientVersion: '1',
    deviceId: 'device',
    platform: 'ios',
    locale: 'zh-CN',
    getAccessToken: () => 'token',
    traceIdFactory: () => 'trace-account',
  ),
  transport: transport,
);

ApiTransportResponse _membershipResponse() => ApiTransportResponse(
  status: 200,
  body: <String, Object?>{
    'success': true,
    'data': <String, Object?>{
      'membership': <String, Object?>{
        'membershipId': 'membership-1',
        'levelCode': 'pilot_paid',
        'status': 'active',
        'expiresAt': null,
      },
      'monthlyCredit': _monthlyCreditJson(),
      'permanentCredit': <String, Object?>{
        'availableCredits': 500,
        'reservedCredits': 10,
      },
      'account': _accountAdmissionJson(),
    },
  },
);

ApiTransportResponse _creditsResponse() => ApiTransportResponse(
  status: 200,
  body: <String, Object?>{
    'success': true,
    'data': <String, Object?>{
      'monthlyCredit': _monthlyCreditJson(),
      'permanentCredit': <String, Object?>{
        'availableCredits': 500,
        'reservedCredits': 10,
        'lots': <Object?>[
          <String, Object?>{
            'lotId': 'lot-1',
            'originKind': 'admin_grant',
            'originalCredits': 500,
            'availableCredits': 500,
            'reservedCredits': 0,
            'createdAt': '2026-08-01T00:00:00Z',
            'expiresAt': null,
          },
        ],
        'nextCursor': 'next opaque',
      },
      'account': _accountAdmissionJson(),
    },
  },
);

ApiTransportResponse _runUsageResponse() => const ApiTransportResponse(
  status: 200,
  body: <String, Object?>{
    'success': true,
    'data': <String, Object?>{
      'runId': 'run opaque/+1',
      'policyVersion': 'credit-policy-v1',
      'rawInputTokens': 100,
      'rawOutputTokens': 20,
      'accountedCredits': 120,
      'settlementStatus': 'settled',
      'assistantResultPersisted': true,
      'measurements': <Object?>[
        <String, Object?>{
          'usageKind': 'text_input',
          'rawInputTokens': 100,
          'measurementStatus': 'measured',
          'accountedCredits': 100,
        },
      ],
    },
  },
);

ApiTransportResponse _storageUsageResponse() => const ApiTransportResponse(
  status: 200,
  body: <String, Object?>{
    'success': true,
    'data': <String, Object?>{
      'currentContentBytes': 20,
      'retainedHistoryBytes': 10,
      'resourceBytes': 70,
      'logicalTotalBytes': 100,
      'formalProjectionBytes': 100,
      'userLogicalTotalBytes': 100,
      'limitBytes': 32212254720,
      'remainingBytes': 32212254620,
      'fileCountLimit': null,
      'measurementStatus': 'complete',
      'unmeasuredObjectCount': 0,
      'calculatedAt': '2026-08-19T00:00:00Z',
    },
  },
);

Map<String, Object?> _monthlyCreditJson() => <String, Object?>{
  'policyVersion': 'credit-policy-v1',
  'quotaCredits': 10000000,
  'periodStart': '2026-08-01T00:00:00Z',
  'periodEnd': '2026-09-01T00:00:00Z',
  'availableCredits': 9000000,
  'reservedCredits': 100000,
  'settledCredits': 900000,
  'expiresAt': '2026-09-01T00:00:00Z',
};

Map<String, Object?> _accountAdmissionJson() => <String, Object?>{
  'runAdmission': 'allowed',
  'outstandingUncoveredCredits': 0,
};

final class _AccountTransport implements ApiTransport {
  _AccountTransport(this.responses);

  final List<ApiTransportResponse> responses;
  final List<ApiTransportRequest> requests = <ApiTransportRequest>[];

  @override
  Future<ApiTransportResponse> send(ApiTransportRequest request) async {
    requests.add(request);
    return responses.removeAt(0);
  }
}

RemoteAccountUsageRepository _repository(
  ApiClient apiClient, {
  required String? Function() workspaceId,
}) => RemoteAccountUsageRepository(
  client: AccountUsageClient(apiClient),
  workspaceClient: WorkspaceLifecycleClient(apiClient),
  workspaceId: workspaceId,
);
