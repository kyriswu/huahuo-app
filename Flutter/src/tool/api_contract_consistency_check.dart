import 'dart:convert';
import 'dart:io';

import 'package:huahuo_api/huahuo_api.dart';

/// Offline metadata validation. This does not execute clients or test cases.
void main(List<String> arguments) {
  if (arguments.contains('--help')) {
    stdout.writeln(
      'Usage: dart run tool/api_contract_consistency_check.dart '
      '[--json <artifact-path>]\n'
      'Checks declared contracts against runtime endpoint definitions. '
      'No network requests or tests are executed. No files are written '
      'unless --json is supplied.',
    );
    return;
  }
  if (arguments.isNotEmpty &&
      (arguments.length != 2 ||
          arguments.first != '--json' ||
          arguments.last.trim().isEmpty ||
          arguments.last.startsWith('--'))) {
    stderr.writeln('Expected no arguments or --json <artifact-path>.');
    exitCode = 64;
    return;
  }
  final report = checkApiContracts(
    operations: ApiContractManifest.operations,
    endpoints: EndpointCatalog.listDefinitions(),
  );
  stdout.writeln(
    'API contract consistency: ${report.entries.length} declarations, '
    '${report.issues.length} issue(s). '
    'Network requests and test cases were not executed.',
  );
  for (final issue in report.issues) {
    stderr.writeln('ERROR: $issue');
  }
  if (arguments.isNotEmpty) {
    final artifact = File(arguments.last);
    artifact.parent.createSync(recursive: true);
    artifact.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(report.toJson())}\n',
    );
  }
  if (report.issues.isNotEmpty) exitCode = 1;
}

final class ApiContractConsistencyReport {
  const ApiContractConsistencyReport({
    required this.entries,
    required this.issues,
  });

  final List<Map<String, Object?>> entries;
  final List<String> issues;

  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': 1,
    'check': 'api_contract_consistency',
    'scope': 'offline_metadata_only',
    'networkExecuted': false,
    'testsExecuted': false,
    'declaredDocsCommit': ApiContractManifest.docsCommit,
    'operationCount': entries.length,
    'issueCount': issues.length,
    'issues': issues,
    'entries': entries,
  };
}

ApiContractConsistencyReport checkApiContracts({
  required Iterable<ApiContractOperation> operations,
  required Iterable<EndpointDefinition> endpoints,
}) {
  final runtimeKeys = <String>{
    for (final endpoint in endpoints)
      '${endpoint.method.value} ${endpoint.pathTemplate}',
  };
  final seen = <String>{};
  final entries = <Map<String, Object?>>[];
  final issues = <String>[];
  for (final operation in operations) {
    if (!seen.add(operation.key)) {
      issues.add('${operation.key}: duplicate contract declaration');
    }
    final hasRuntimeDefinition = runtimeKeys.contains(operation.key);
    final String status;
    switch (operation.disposition) {
      case ApiOperationDisposition.prohibited:
        status = hasRuntimeDefinition
            ? 'prohibited_runtime_definition'
            : 'prohibited_absent';
        if (hasRuntimeDefinition) {
          issues.add(
            '${operation.key}: prohibited operation has a runtime definition',
          );
        }
      case ApiOperationDisposition.contractOnly:
        status = 'contract_only';
      case ApiOperationDisposition.blockedPublication:
        status = 'publication_blocked';
      case ApiOperationDisposition.wiredMobile:
      case ApiOperationDisposition.wiredDesktop:
      case ApiOperationDisposition.wiredBoth:
        status = hasRuntimeDefinition
            ? 'runtime_definition_present'
            : 'runtime_definition_missing';
        if (!hasRuntimeDefinition) {
          issues.add(
            '${operation.key}: declared wired operation has no runtime definition',
          );
        }
    }
    entries.add(<String, Object?>{
      'operation': operation.key,
      'declaredDisposition': operation.disposition.name,
      'scope': operation.scope.name,
      'authority': operation.authority,
      'responseKind': operation.responseKind.name,
      'hasRuntimeDefinition': hasRuntimeDefinition,
      'status': status,
    });
  }
  return ApiContractConsistencyReport(
    entries: List.unmodifiable(entries),
    issues: List.unmodifiable(issues),
  );
}
