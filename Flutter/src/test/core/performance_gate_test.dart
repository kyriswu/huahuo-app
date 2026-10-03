import 'package:flutter_test/flutter_test.dart';

import '../../tool/performance_gate.dart';

void main() {
  Map<String, Object?> artifact() => <String, Object?>{
    'schemaVersion': 1,
    'buildMode': 'profile',
    'physicalDevice': true,
    'frame': <String, Object?>{
      'sampleCount': 300,
      'build': <String, Object?>{'p95Ms': 7.5},
      'raster': <String, Object?>{'p95Ms': 7.4},
      'total': <String, Object?>{'p95Ms': 15.9},
      'jankRate': 0.004,
    },
    'idle': <String, Object?>{
      'framesAfterSettle': 0,
      'networkRequestsPerMinute': 0,
      'databaseWritesPerMinute': 0,
      'averageCpuPercent': 4.5,
    },
    'memory': <String, Object?>{'growthAfterNavigationGcPercent': 14},
    'coverage': <String, Object?>{
      'iosPhysical': true,
      'androidPhysical': true,
      'durationMinutes': 15,
      'weakNetworkRecovery': true,
      'backgroundRecovery': true,
      'largeMediaExport': true,
    },
  };

  test('nightly evidence passes all frame and idle budgets', () {
    expect(
      evaluatePerformanceArtifact(
        artifact(),
        mode: PerformanceGateMode.nightly,
      ),
      isEmpty,
    );
  });

  test('release requires the physical-device scenario matrix', () {
    final value = artifact();
    value['coverage'] = <String, Object?>{'durationMinutes': 5};

    final codes = evaluatePerformanceArtifact(
      value,
      mode: PerformanceGateMode.release,
    ).map((finding) => finding.code);

    expect(codes, containsAll(<String>['release-ios', 'release-android']));
    expect(codes, contains('release-duration'));
    expect(codes, contains('release-weakNetworkRecovery'));
  });

  test('fails closed for insufficient and malformed frame evidence', () {
    final value = artifact();
    value['frame'] = <String, Object?>{
      'sampleCount': 5,
      'build': <String, Object?>{'p95Ms': double.nan},
    };

    final codes = evaluatePerformanceArtifact(
      value,
      mode: PerformanceGateMode.nightly,
    ).map((finding) => finding.code);

    expect(
      codes,
      containsAll(<String>[
        'frame-samples',
        'build-p95',
        'raster-p95',
        'total-p95',
        'jank-rate',
      ]),
    );
  });

  test('rejects frame, idle-work, CPU, and memory regressions', () {
    final value = artifact();
    value['frame'] = <String, Object?>{
      'sampleCount': 300,
      'build': <String, Object?>{'p95Ms': 8},
      'raster': <String, Object?>{'p95Ms': 9},
      'total': <String, Object?>{'p95Ms': 17},
      'jankRate': 0.005,
    };
    value['idle'] = <String, Object?>{
      'framesAfterSettle': 1,
      'networkRequestsPerMinute': 1,
      'databaseWritesPerMinute': 2,
      'averageCpuPercent': 6,
    };
    value['memory'] = <String, Object?>{'growthAfterNavigationGcPercent': 16};

    final codes = evaluatePerformanceArtifact(
      value,
      mode: PerformanceGateMode.nightly,
    ).map((finding) => finding.code);

    expect(
      codes,
      containsAll(<String>[
        'build-p95',
        'raster-p95',
        'total-p95',
        'jank-rate',
        'idle-frames',
        'idle-network',
        'idle-database',
        'idle-cpu',
        'memory-growth',
      ]),
    );
  });
}
