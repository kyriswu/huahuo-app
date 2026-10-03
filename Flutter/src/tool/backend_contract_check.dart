import 'dart:io';

import 'package:huahuo_api/huahuo_api.dart';

void main() {
  final sourceRoots = <Directory>[
    Directory('lib'),
    Directory('../packages/huahuo_api/lib'),
    Directory('../packages/huahuo_product/lib'),
    Directory('../desktop/lib'),
  ];
  if (sourceRoots.any((root) => !root.existsSync())) {
    stderr.writeln('backend_contract_check must run from Flutter/src');
    exitCode = 2;
    return;
  }

  final reviewHints = <String>[];
  final references = <String, Set<String>>{};
  final runtimeMockPattern = RegExp(
    r'(?:return|=>|\?\?)\s+(?:const\s+)?[A-Z][A-Za-z0-9_]*(?:Mock|Demo)[A-Za-z0-9_]*\s*\(',
  );
  final endpointPattern = RegExp(
    r'''endpointId\s*:\s*['"]([A-Za-z0-9_]+)['"]''',
  );
  for (final sourceRoot in sourceRoots) {
    for (final entity in sourceRoot.listSync(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final content = entity.readAsStringSync();
      if (runtimeMockPattern.hasMatch(content)) {
        reviewHints.add(
          '${entity.path}: Mock/Demo constructor candidate; review build guards',
        );
      }
      for (final match in endpointPattern.allMatches(content)) {
        references
            .putIfAbsent(match.group(1)!, () => <String>{})
            .add(entity.path);
      }
    }
  }

  final issues = backendContractFindings(
    definitions: EndpointCatalog.definitions,
    references: references,
  );

  final counts = <BackendIntegrationStatus, int>{
    for (final status in BackendIntegrationStatus.values) status: 0,
  };
  for (final endpoint in EndpointCatalog.definitions.values) {
    counts[endpoint.integrationStatus] =
        counts[endpoint.integrationStatus]! + 1;
  }
  stdout.writeln(
    'Backend contract metadata: ${EndpointCatalog.definitions.length} endpoints. '
    'Literal references are discovery evidence, not runtime coverage.',
  );
  for (final status in BackendIntegrationStatus.values) {
    stdout.writeln('  ${status.name}: ${counts[status]}');
  }
  for (final hint in reviewHints) {
    stdout.writeln('REVIEW (text heuristic, not runtime proof): $hint');
  }
  if (issues.isNotEmpty) {
    for (final issue in issues) {
      stderr.writeln('ERROR: $issue');
    }
    exitCode = 1;
  }
}

/// Validates current metadata without reading Git history or contacting servers.
List<String> backendContractFindings({
  required Map<String, EndpointDefinition> definitions,
  required Map<String, Set<String>> references,
}) {
  final issues = <String>[];
  for (final entry in definitions.entries) {
    final endpoint = entry.value;
    if (entry.key != endpoint.id) {
      issues.add('${entry.key}: catalog key does not match ${endpoint.id}');
    }
    if (!RegExp(r'^v[1-9][0-9]*$').hasMatch(endpoint.contractVersion)) {
      issues.add('${endpoint.id}: invalid contract version');
    }
    if (!endpoint.pathTemplate.startsWith('/api/')) {
      issues.add('${endpoint.id}: path must start with /api/');
    }
    issues.addAll(assertEndpointPolicy(endpoint));
    if (endpoint.integrationStatus == BackendIntegrationStatus.connected &&
        (references[endpoint.id]?.isEmpty ?? true)) {
      issues.add(
        '${endpoint.id}: connected endpoint has no literal source reference',
      );
    }
  }

  for (final endpointId in references.keys) {
    if (!definitions.containsKey(endpointId)) {
      issues.add('$endpointId: adapter references an unknown endpoint');
    }
  }

  return List.unmodifiable(issues);
}
