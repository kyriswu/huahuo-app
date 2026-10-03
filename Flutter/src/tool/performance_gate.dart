import 'dart:convert';
import 'dart:io';

enum PerformanceGateMode { nightly, release }

final class PerformanceBudget {
  const PerformanceBudget({
    this.minimumFrameSamples = 120,
    this.maximumBuildP95Ms = 8,
    this.maximumRasterP95Ms = 8,
    this.maximumTotalP95Ms = 16.7,
    this.maximumJankRate = 0.005,
    this.maximumIdleCpuPercent = 5,
    this.maximumMemoryGrowthPercent = 15,
  });

  final int minimumFrameSamples;
  final double maximumBuildP95Ms;
  final double maximumRasterP95Ms;
  final double maximumTotalP95Ms;
  final double maximumJankRate;
  final double maximumIdleCpuPercent;
  final double maximumMemoryGrowthPercent;
}

final class PerformanceGateFinding {
  const PerformanceGateFinding(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => '[$code] $message';
}

List<PerformanceGateFinding> evaluatePerformanceArtifact(
  Map<String, Object?> artifact, {
  required PerformanceGateMode mode,
  PerformanceBudget budget = const PerformanceBudget(),
}) {
  final findings = <PerformanceGateFinding>[];
  void require(bool condition, String code, String message) {
    if (!condition) findings.add(PerformanceGateFinding(code, message));
  }

  require(artifact['schemaVersion'] == 1, 'schema', 'schemaVersion must be 1.');
  require(
    artifact['buildMode'] == 'profile',
    'build-mode',
    'Evidence must come from a Profile build.',
  );
  require(
    artifact['physicalDevice'] == true,
    'physical-device',
    'Nightly and release evidence must come from a physical device.',
  );

  final frame = _map(artifact['frame']);
  final sampleCount = _number(frame?['sampleCount']);
  require(
    sampleCount != null && sampleCount >= budget.minimumFrameSamples,
    'frame-samples',
    'At least ${budget.minimumFrameSamples} frame samples are required.',
  );
  _requireBelow(
    findings,
    value: _nestedNumber(frame, 'build', 'p95Ms'),
    limit: budget.maximumBuildP95Ms,
    code: 'build-p95',
  );
  _requireBelow(
    findings,
    value: _nestedNumber(frame, 'raster', 'p95Ms'),
    limit: budget.maximumRasterP95Ms,
    code: 'raster-p95',
  );
  _requireBelow(
    findings,
    value: _nestedNumber(frame, 'total', 'p95Ms'),
    limit: budget.maximumTotalP95Ms,
    code: 'total-p95',
  );
  _requireBelow(
    findings,
    value: _number(frame?['jankRate']),
    limit: budget.maximumJankRate,
    code: 'jank-rate',
  );

  final idle = _map(artifact['idle']);
  _requireAtMost(
    findings,
    value: _number(idle?['framesAfterSettle']),
    limit: 0,
    code: 'idle-frames',
  );
  _requireAtMost(
    findings,
    value: _number(idle?['networkRequestsPerMinute']),
    limit: 0,
    code: 'idle-network',
  );
  _requireAtMost(
    findings,
    value: _number(idle?['databaseWritesPerMinute']),
    limit: 0,
    code: 'idle-database',
  );
  _requireAtMost(
    findings,
    value: _number(idle?['averageCpuPercent']),
    limit: budget.maximumIdleCpuPercent,
    code: 'idle-cpu',
  );

  final memory = _map(artifact['memory']);
  _requireAtMost(
    findings,
    value: _number(memory?['growthAfterNavigationGcPercent']),
    limit: budget.maximumMemoryGrowthPercent,
    code: 'memory-growth',
  );

  if (mode == PerformanceGateMode.release) {
    final coverage = _map(artifact['coverage']);
    require(
      coverage?['iosPhysical'] == true,
      'release-ios',
      'Release evidence must include a physical iOS run.',
    );
    require(
      coverage?['androidPhysical'] == true,
      'release-android',
      'Release evidence must include a physical Android run.',
    );
    final duration = _number(coverage?['durationMinutes']);
    require(
      duration != null && duration >= 15,
      'release-duration',
      'Release soak evidence must cover at least 15 minutes.',
    );
    for (final key in const <String>[
      'weakNetworkRecovery',
      'backgroundRecovery',
      'largeMediaExport',
    ]) {
      require(
        coverage?[key] == true,
        'release-$key',
        'Release coverage is missing $key.',
      );
    }
  }
  return findings;
}

void _requireBelow(
  List<PerformanceGateFinding> findings, {
  required double? value,
  required double limit,
  required String code,
}) {
  if (value == null || value >= limit) {
    findings.add(
      PerformanceGateFinding(code, 'A finite value below $limit is required.'),
    );
  }
}

void _requireAtMost(
  List<PerformanceGateFinding> findings, {
  required double? value,
  required double limit,
  required String code,
}) {
  if (value == null || value > limit) {
    findings.add(
      PerformanceGateFinding(
        code,
        'A finite value at most $limit is required.',
      ),
    );
  }
}

Map<String, Object?>? _map(Object? value) {
  if (value is! Map) return null;
  return <String, Object?>{
    for (final entry in value.entries) '${entry.key}': entry.value,
  };
}

double? _number(Object? value) {
  if (value is! num) return null;
  final result = value.toDouble();
  return result.isFinite ? result : null;
}

double? _nestedNumber(Map<String, Object?>? parent, String child, String key) =>
    _number(_map(parent?[child])?[key]);

Future<void> main(List<String> arguments) async {
  final input = _option(arguments, '--input');
  final modeName = _option(arguments, '--mode') ?? 'nightly';
  final mode = PerformanceGateMode.values.where(
    (candidate) => candidate.name == modeName,
  );
  if (input == null || mode.isEmpty) {
    stderr.writeln(
      'Usage: dart run tool/performance_gate.dart '
      '--mode <nightly|release> --input <artifact.json>',
    );
    exitCode = 64;
    return;
  }
  try {
    final decoded = jsonDecode(await File(input).readAsString());
    final artifact = _map(decoded);
    if (artifact == null) throw const FormatException('root must be an object');
    final findings = evaluatePerformanceArtifact(artifact, mode: mode.single);
    if (findings.isEmpty) {
      stdout.writeln('Performance ${mode.single.name} gate passed.');
      return;
    }
    stderr.writeln('Performance gate found ${findings.length} issue(s):');
    for (final finding in findings) {
      stderr.writeln(finding);
    }
    exitCode = 1;
  } on Object {
    stderr.writeln(
      'Performance artifact is missing, unreadable, or malformed.',
    );
    exitCode = 65;
  }
}

String? _option(List<String> arguments, String name) {
  final index = arguments.indexOf(name);
  if (index < 0 || index + 1 >= arguments.length) return null;
  return arguments[index + 1];
}
