import 'dart:io';

enum QualityGateMode { pr, nightly, release }

final class _GateStep {
  const _GateStep(
    this.label,
    this.command,
    this.arguments, {
    this.workingDirectory,
  });

  final String label;
  final String command;
  final List<String> arguments;
  final String? workingDirectory;

  String get display => <String>[command, ...arguments].join(' ');
}

Future<void> main(List<String> arguments) async {
  final listOnly = arguments.contains('--list');
  final modeName = arguments
      .where((value) => !value.startsWith('--'))
      .firstOrNull;
  final mode = QualityGateMode.values.firstWhere(
    (value) => value.name == (modeName ?? 'pr'),
    orElse: () => throw ArgumentError('QUALITY_GATE_MODE_INVALID'),
  );
  final workingDirectory = await _sourceRoot();
  if (arguments.contains('--dependency-policy')) {
    final findings = _workspaceDependencyPolicyFindings(
      Directory(workingDirectory).parent,
    );
    if (findings.isNotEmpty) {
      stderr.writeln('Dependency policy failed:');
      for (final finding in findings) {
        stderr.writeln('- $finding');
      }
      exitCode = 1;
      return;
    }
    stdout.writeln('Dependency policy passed.');
    return;
  }
  final performanceSnapshot = _option(arguments, '--performance-snapshot');
  if (!listOnly && mode != QualityGateMode.pr && performanceSnapshot == null) {
    stderr.writeln(
      '${mode.name} requires --performance-snapshot <profile-summary.json>.',
    );
    exitCode = 64;
    return;
  }
  final steps = _steps(
    mode,
    workingDirectory,
    performanceSnapshot ?? '<required-performance-snapshot>',
  );
  if (listOnly) {
    for (final step in steps) {
      stdout.writeln(
        '${step.label} [${step.workingDirectory ?? workingDirectory}]: '
        '${step.display}',
      );
    }
    return;
  }
  for (final step in steps) {
    stdout.writeln('\n== ${step.label} ==');
    final process = await Process.start(
      step.command,
      step.arguments,
      workingDirectory: step.workingDirectory ?? workingDirectory,
      mode: ProcessStartMode.inheritStdio,
    );
    final code = await process.exitCode;
    if (code != 0) {
      stderr.writeln('Quality gate failed at ${step.label} (exit $code).');
      exitCode = code;
      return;
    }
  }
  stdout.writeln('\nQuality gate ${mode.name} passed.');
}

List<_GateStep> _steps(
  QualityGateMode mode,
  String sourceRoot,
  String performanceSnapshot,
) {
  final workspaceRoot = Directory(sourceRoot).parent.path;
  final desktopRoot = '$workspaceRoot/desktop';
  final apiRoot = '$workspaceRoot/packages/huahuo_api';
  final editorRoot = '$workspaceRoot/packages/huahuo_editor';
  final foundationRoot = '$workspaceRoot/packages/huahuo_foundation';
  final productRoot = '$workspaceRoot/packages/huahuo_product';
  final steps = <_GateStep>[
    _GateStep('format workspace', 'dart', const <String>[
      'format',
      '--output=none',
      '--set-exit-if-changed',
      'src/lib',
      'src/test',
      'src/integration_test',
      'src/test_driver',
      'src/tool',
      'desktop/lib',
      'desktop/test',
      'packages/huahuo_api/lib',
      'packages/huahuo_api/test',
      'packages/huahuo_editor/lib',
      'packages/huahuo_editor/test',
      'packages/huahuo_foundation/lib',
      'packages/huahuo_foundation/test',
      'packages/huahuo_product/lib',
      'packages/huahuo_product/test',
    ], workingDirectory: workspaceRoot),
    _GateStep('resolve lock offline', 'dart', const <String>[
      'pub',
      'get',
      '--offline',
      '--enforce-lockfile',
    ], workingDirectory: workspaceRoot),
    const _GateStep('dependency policy', 'dart', <String>[
      'run',
      'tool/quality_gate.dart',
      '--dependency-policy',
    ]),
    const _GateStep('analyze mobile', 'flutter', <String>[
      'analyze',
      '--no-pub',
      '--no-fatal-infos',
    ]),
    _GateStep('analyze desktop', 'flutter', const <String>[
      'analyze',
      '--no-pub',
      '--no-fatal-infos',
    ], workingDirectory: desktopRoot),
    _GateStep('analyze huahuo_api', 'dart', const <String>[
      'analyze',
    ], workingDirectory: apiRoot),
    _GateStep('analyze huahuo_editor', 'dart', const <String>[
      'analyze',
    ], workingDirectory: editorRoot),
    _GateStep('analyze huahuo_foundation', 'dart', const <String>[
      'analyze',
    ], workingDirectory: foundationRoot),
    _GateStep('analyze huahuo_product', 'dart', const <String>[
      'analyze',
    ], workingDirectory: productRoot),
    const _GateStep('API contract consistency', 'dart', <String>[
      'run',
      'tool/api_contract_consistency_check.dart',
    ]),
    const _GateStep('feature parity', 'dart', <String>[
      'run',
      'tool/feature_parity_check.dart',
    ]),
    const _GateStep('test mobile', 'flutter', <String>['test', '--no-pub']),
    _GateStep('test desktop', 'flutter', const <String>[
      'test',
      '--no-pub',
    ], workingDirectory: desktopRoot),
    _GateStep('test huahuo_api', 'dart', const <String>[
      'test',
    ], workingDirectory: apiRoot),
    _GateStep('test huahuo_editor', 'flutter', const <String>[
      'test',
      '--no-pub',
    ], workingDirectory: editorRoot),
    _GateStep('test huahuo_product', 'dart', const <String>[
      'test',
    ], workingDirectory: productRoot),
    _GateStep('test huahuo_foundation', 'flutter', const <String>[
      'test',
      '--no-pub',
    ], workingDirectory: foundationRoot),
    const _GateStep('architecture', 'dart', <String>[
      'run',
      'tool/source_reachability_check.dart',
    ]),
    const _GateStep('secret scan', 'dart', <String>[
      'run',
      'tool/secret_scan.dart',
    ]),
  ];
  if (mode != QualityGateMode.pr &&
      Directory('$sourceRoot/integration_test').existsSync()) {
    steps.add(
      const _GateStep('integration tests', 'flutter', <String>[
        'test',
        '--no-pub',
        'integration_test',
      ]),
    );
  }
  if (mode != QualityGateMode.pr) {
    steps.add(
      _GateStep('performance budgets', 'dart', <String>[
        'run',
        'tool/performance_gate.dart',
        '--mode',
        mode.name,
        '--input',
        performanceSnapshot,
      ]),
    );
    steps.add(
      const _GateStep('analyze Android release size', 'flutter', <String>[
        'build',
        'apk',
        '--release',
        '--analyze-size',
        '--target-platform',
        'android-arm64',
      ]),
    );
    final iosSizeBuild = _iosSizeBuildStep();
    if (iosSizeBuild != null) steps.add(iosSizeBuild);
    final desktopBuild = _desktopBuildStep(desktopRoot);
    if (desktopBuild != null) steps.add(desktopBuild);
  }
  return steps;
}

List<String> qualityGateStepDisplays(String sourceRoot) =>
    List<String>.unmodifiable(
      _steps(
        QualityGateMode.pr,
        sourceRoot,
        '<unused>',
      ).map((step) => '${step.label}:${step.display}'),
    );

List<String> dependencyPolicyFindings(String lockFile) {
  final findings = <String>[];
  if (!lockFile.startsWith('# Generated by pub\n')) {
    findings.add('pubspec.lock is not a generated Pub lock file');
  }
  final packagesStart = RegExp(
    r'^packages:[ \t]*$',
    multiLine: true,
  ).firstMatch(lockFile);
  final sdksStart = RegExp(
    r'^sdks:[ \t]*$',
    multiLine: true,
  ).firstMatch(lockFile);
  if (packagesStart == null ||
      sdksStart == null ||
      sdksStart.start <= packagesStart.end) {
    findings.add('pubspec.lock must contain packages and sdks sections');
    return findings;
  }

  final packageSection = lockFile.substring(packagesStart.end, sdksStart.start);
  final packageHeaders = RegExp(
    r'^  ([A-Za-z_][A-Za-z0-9_]*):[ \t]*$',
    multiLine: true,
  ).allMatches(packageSection).toList(growable: false);
  if (packageHeaders.isEmpty) {
    findings.add('pubspec.lock packages section is empty');
  }
  final seen = <String>{};
  for (var index = 0; index < packageHeaders.length; index++) {
    final header = packageHeaders[index];
    final name = header.group(1)!;
    final end = index + 1 < packageHeaders.length
        ? packageHeaders[index + 1].start
        : packageSection.length;
    final block = packageSection.substring(header.end, end);
    if (!seen.add(name)) findings.add('$name appears more than once');
    if (name == 'ordered_set' || name.startsWith('flutter_inappwebview')) {
      findings.add('$name is a retired dependency');
    }
    final source = _lockScalar(block, 'source', indentation: 4);
    if (source == null) {
      findings.add('$name has no dependency source');
      continue;
    }
    switch (source) {
      case 'hosted':
        final url = _lockScalar(block, 'url', indentation: 6);
        final sha256 = _lockScalar(block, 'sha256', indentation: 6);
        if (url != 'https://pub.dev') {
          findings.add(
            '$name must use https://pub.dev, found ${url ?? 'none'}',
          );
        }
        if (sha256 == null || !RegExp(r'^[a-f0-9]{64}$').hasMatch(sha256)) {
          findings.add('$name must pin a lowercase 64-character SHA-256');
        }
        break;
      case 'sdk':
        break;
      case 'path':
        final path = _lockScalar(block, 'path', indentation: 6);
        final relative = _lockScalar(block, 'relative', indentation: 6);
        if (name != 'jpush_flutter' ||
            path != 'vendor/jpush_flutter' ||
            relative != 'true') {
          findings.add(
            '$name is not the approved vendor/jpush_flutter path dependency',
          );
        }
        break;
      default:
        findings.add('$name uses forbidden dependency source `$source`');
        break;
    }
  }

  final sdkSection = lockFile.substring(sdksStart.end);
  final dartSdk = _lockScalar(sdkSection, 'dart', indentation: 2);
  final flutterSdk = _lockScalar(sdkSection, 'flutter', indentation: 2);
  if (dartSdk != '>=3.12.0 <4.0.0') {
    findings.add(
      'Dart SDK policy is >=3.12.0 <4.0.0, found ${dartSdk ?? 'none'}',
    );
  }
  if (flutterSdk != '>=3.44.0') {
    findings.add(
      'Flutter SDK policy is >=3.44.0, found ${flutterSdk ?? 'none'}',
    );
  }
  return findings;
}

List<String> dependencyLockLayoutFindings(Iterable<String> lockPaths) {
  final normalized = lockPaths
      .map((path) => path.replaceAll('\\', '/'))
      .where((path) => path.endsWith('pubspec.lock'))
      .toSet();
  if (!normalized.contains('pubspec.lock')) {
    return <String>['workspace pubspec.lock is missing'];
  }
  return normalized
      .where((path) => path != 'pubspec.lock')
      .map((path) => 'nested lock file is forbidden: $path')
      .toList(growable: false)
    ..sort();
}

String? _lockScalar(String block, String key, {required int indentation}) {
  final prefix = ''.padLeft(indentation);
  final match = RegExp(
    '^$prefix${RegExp.escape(key)}:[ \\t]*(.+?)[ \\t]*\$',
    multiLine: true,
  ).firstMatch(block);
  final value = match?.group(1)?.trim();
  if (value == null || value.isEmpty) return null;
  if (value.length >= 2 &&
      ((value.startsWith('"') && value.endsWith('"')) ||
          (value.startsWith("'") && value.endsWith("'")))) {
    return value.substring(1, value.length - 1);
  }
  return value;
}

List<String> _workspaceDependencyPolicyFindings(Directory workspaceRoot) {
  final rootLock = File('${workspaceRoot.path}/pubspec.lock');
  if (!rootLock.existsSync()) {
    return <String>['workspace pubspec.lock is missing'];
  }
  final findings = dependencyPolicyFindings(rootLock.readAsStringSync());
  final lockPaths = <String>['pubspec.lock'];
  for (final entity in workspaceRoot.listSync(
    recursive: true,
    followLinks: false,
  )) {
    if (entity is! File || entity.path == rootLock.path) continue;
    final relative = entity.path.substring(workspaceRoot.path.length + 1);
    if (relative
        .split(Platform.pathSeparator)
        .any((segment) => segment == '.dart_tool' || segment == 'build')) {
      continue;
    }
    if (entity.uri.pathSegments.last == 'pubspec.lock') {
      lockPaths.add(relative);
    }
  }
  findings.addAll(dependencyLockLayoutFindings(lockPaths));
  return findings;
}

_GateStep? _iosSizeBuildStep() {
  if (!Platform.isMacOS) return null;
  return const _GateStep('analyze iOS release size', 'flutter', <String>[
    'build',
    'ios',
    '--release',
    '--no-codesign',
    '--analyze-size',
  ]);
}

_GateStep? _desktopBuildStep(String desktopRoot) {
  final target = Platform.isMacOS
      ? 'macos'
      : Platform.isWindows
      ? 'windows'
      : Platform.isLinux
      ? 'linux'
      : null;
  if (target == null) return null;
  return _GateStep('profile desktop build', 'flutter', <String>[
    'build',
    target,
    '--profile',
  ], workingDirectory: desktopRoot);
}

String? _option(List<String> arguments, String name) {
  final index = arguments.indexOf(name);
  if (index < 0 || index + 1 >= arguments.length) return null;
  return arguments[index + 1];
}

Future<String> _sourceRoot() async {
  var directory = Directory.current.absolute;
  while (true) {
    if (File('${directory.path}/pubspec.yaml').existsSync() &&
        Directory('${directory.path}/lib').existsSync()) {
      return directory.path;
    }
    final parent = directory.parent;
    if (parent.path == directory.path) {
      throw StateError('FLUTTER_SOURCE_ROOT_NOT_FOUND');
    }
    directory = parent;
  }
}
