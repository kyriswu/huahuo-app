import 'package:flutter_test/flutter_test.dart';

import '../../tool/secret_scan.dart';

void main() {
  test('finds high-confidence credentials without exposing their value', () {
    const literal =
        'client_secret = "'
        '${'sensitive-value-123'}"';
    final findings = findSecretFindings('fixture.txt', literal);

    expect(findings, hasLength(1));
    expect(findings.single.ruleId, 'credential-literal');
    expect(findings.single.toString(), 'fixture.txt:1 [credential-literal]');
    expect(findings.single.toString(), isNot(contains('sensitive')));
  });

  test('ignores placeholders and explicit reviewed lines', () {
    final findings = findSecretFindings(
      'fixture.txt',
      <String>[
        'password = "placeholder-value"',
        'api_key = "reviewed-real-value" // secret-scan: allow',
      ].join('\n'),
    );

    expect(findings, isEmpty);
  });
}
