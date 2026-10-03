import 'package:flutter_test/flutter_test.dart';
import 'package:huahuo_api/huahuo_api.dart';

import '../../tool/api_contract_consistency_check.dart';

void main() {
  ApiContractOperation operation(ApiOperationDisposition disposition) =>
      ApiContractOperation(
        scope: ApiContractScope.formal,
        method: HttpMethod.get,
        path: '/api/v1/app/config',
        authority: 'fixture',
        disposition: disposition,
        responseKind: ApiResponseKind.jsonEnvelope,
      );

  test('requires a definition for every wired platform declaration', () {
    for (final disposition in <ApiOperationDisposition>[
      ApiOperationDisposition.wiredMobile,
      ApiOperationDisposition.wiredDesktop,
      ApiOperationDisposition.wiredBoth,
    ]) {
      final report = checkApiContracts(
        operations: [operation(disposition)],
        endpoints: const [],
      );
      expect(report.issues, hasLength(1));
      expect(report.entries.single['status'], 'runtime_definition_missing');
    }
  });

  test('definition presence does not claim a test or live success', () {
    final report = checkApiContracts(
      operations: [operation(ApiOperationDisposition.wiredBoth)],
      endpoints: EndpointCatalog.listDefinitions(),
    );
    expect(report.issues, isEmpty);
    expect(report.entries.single['status'], 'runtime_definition_present');
    final artifact = report.toJson();
    expect(artifact['networkExecuted'], false);
    expect(artifact['testsExecuted'], false);
    expect(report.entries.single.containsKey('testCase'), false);
    expect(report.entries.single.containsKey('result'), false);
  });

  test(
    'non-runtime declarations remain explicitly unimplemented or blocked',
    () {
      final report = checkApiContracts(
        operations: [operation(ApiOperationDisposition.blockedPublication)],
        endpoints: const [],
      );
      expect(report.issues, isEmpty);
      expect(report.entries.single['status'], 'publication_blocked');
      expect(
        checkApiContracts(
          operations: [operation(ApiOperationDisposition.contractOnly)],
          endpoints: const [],
        ).entries.single['status'],
        'contract_only',
      );
    },
  );

  test('rejects prohibited definitions and duplicate declarations', () {
    final prohibited = operation(ApiOperationDisposition.prohibited);
    expect(
      checkApiContracts(operations: [prohibited], endpoints: const []).issues,
      isEmpty,
    );
    final report = checkApiContracts(
      operations: [prohibited, prohibited],
      endpoints: EndpointCatalog.listDefinitions(),
    );
    expect(report.issues, contains(contains('duplicate contract')));
    expect(report.issues, contains(contains('prohibited operation')));
  });
}
