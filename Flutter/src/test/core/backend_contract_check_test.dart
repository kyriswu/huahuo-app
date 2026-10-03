import 'package:flutter_test/flutter_test.dart';
import 'package:huahuo_api/huahuo_api.dart';

import '../../tool/backend_contract_check.dart';

void main() {
  final endpoint = EndpointCatalog.definitions['appConfig']!;

  test('current contracts require no historical catalog or Git revision', () {
    expect(
      backendContractFindings(definitions: const {}, references: const {}),
      isEmpty,
    );
    expect(
      backendContractFindings(
        definitions: {'appConfig': endpoint},
        references: {
          'appConfig': {'../desktop/lib/adapter.dart'},
        },
      ),
      isEmpty,
    );
  });

  test('removing a definition with a remaining consumer still fails', () {
    expect(
      backendContractFindings(
        definitions: const {},
        references: {
          'removedEndpoint': {'lib/adapter.dart'},
        },
      ),
      contains('removedEndpoint: adapter references an unknown endpoint'),
    );
  });

  test('retains catalog identity and connected-reference checks', () {
    final findings = backendContractFindings(
      definitions: {'wrongKey': endpoint},
      references: const {},
    );
    expect(findings, contains(contains('catalog key does not match')));
    expect(findings, contains(contains('no literal source reference')));
  });
}
