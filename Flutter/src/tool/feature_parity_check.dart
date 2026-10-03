import 'dart:io';

import 'package:huahuo_product/huahuo_product.dart';

const approvedDesktopDeferrals = <String>{
  'native.recordingCard',
  'native.liveCapture',
  'native.voiceprint',
  'native.systemNotifications',
  'native.homeWidget',
  'native.screenCapture',
  'native.storePurchase',
};

void main() {
  final sourceRoot = Directory.current.absolute;
  if (!File('${sourceRoot.path}/pubspec.yaml').existsSync() ||
      sourceRoot.path.split(Platform.pathSeparator).last != 'src') {
    stderr.writeln('feature_parity_check must run from Flutter/src');
    exitCode = 64;
    return;
  }
  final entries = ProductFeatureCatalog.entries;
  final findings = featureParityFindings(sourceRoot.parent, entries: entries);
  if (findings.isNotEmpty) {
    stderr.writeln('Feature parity check failed:');
    for (final finding in findings) {
      stderr.writeln('- $finding');
    }
    exitCode = 1;
    return;
  }
  final aligned = entries
      .where((entry) => entry.parityStatus == FeatureParityStatus.aligned)
      .length;
  final deferred = entries
      .where((entry) => entry.parityStatus == FeatureParityStatus.deferred)
      .length;
  final blocked = entries
      .where((entry) => entry.parityStatus == FeatureParityStatus.blocked)
      .length;
  stdout.writeln(
    'Feature parity check passed: $aligned aligned, $blocked external contract '
    'blocker(s), $deferred approved Desktop-native deferrals.',
  );
}

List<String> featureParityFindings(
  Directory workspaceRoot, {
  List<FeatureEntry>? entries,
}) {
  final catalog = entries ?? ProductFeatureCatalog.entries;
  final findings = <String>[
    for (final issue in FeatureParityAuditor.audit(catalog).issues)
      '${issue.code}:${issue.featureId}:${issue.detail}',
    ...supportContentParityFindings(workspaceRoot),
  ];
  final hiddenDesktop = <String>{};
  for (final entry in catalog) {
    final descriptor = entry.descriptor;
    for (final binding in entry.bindings.values) {
      for (final evidence in binding.implementationEvidence) {
        if (!File('${workspaceRoot.path}/$evidence').existsSync()) {
          findings.add(
            'missing_evidence:${descriptor.id}:${binding.platform.name}:$evidence',
          );
        }
      }
    }
    final desktop = entry.bindingFor(ProductPlatform.desktop);
    if (desktop.availability == FeatureAvailability.hidden) {
      hiddenDesktop.add(descriptor.id.value);
      if (!approvedDesktopDeferrals.contains(descriptor.id.value)) {
        findings.add('unapproved_desktop_deferral:${descriptor.id}');
      }
      continue;
    }
    if (!desktop.isVisible) continue;
    for (final kind in const <FeatureEntryKind>[
      FeatureEntryKind.route,
      FeatureEntryKind.sidebar,
      FeatureEntryKind.parent,
      FeatureEntryKind.command,
    ]) {
      if (!desktop.hasEntry(kind)) {
        findings.add('missing_desktop_${kind.name}:${descriptor.id}');
      }
    }
  }
  for (final missing in approvedDesktopDeferrals.difference(hiddenDesktop)) {
    findings.add('approved_deferral_not_declared:$missing');
  }
  return List<String>.unmodifiable(findings..sort());
}

List<String> supportContentParityFindings(Directory workspaceRoot) {
  final findings = <String>[];
  _compareAssetTrees(
    workspaceRoot,
    mobilePath: 'src/assets/help',
    desktopPath: 'desktop/assets/support/help',
    label: 'help',
    findings: findings,
  );
  _compareAssetTrees(
    workspaceRoot,
    mobilePath: 'src/assets/legal',
    desktopPath: 'desktop/assets/support/legal',
    label: 'legal',
    findings: findings,
  );
  return List<String>.unmodifiable(findings..sort());
}

void _compareAssetTrees(
  Directory workspaceRoot, {
  required String mobilePath,
  required String desktopPath,
  required String label,
  required List<String> findings,
}) {
  final mobileRoot = Directory('${workspaceRoot.path}/$mobilePath');
  final desktopRoot = Directory('${workspaceRoot.path}/$desktopPath');
  final mobile = _relativeFiles(mobileRoot);
  final desktop = _relativeFiles(desktopRoot);
  for (final path in mobile.keys.toSet().difference(desktop.keys.toSet())) {
    findings.add('support_mirror_missing_desktop:$label:$path');
  }
  for (final path in desktop.keys.toSet().difference(mobile.keys.toSet())) {
    findings.add('support_mirror_extra_desktop:$label:$path');
  }
  for (final path in mobile.keys.toSet().intersection(desktop.keys.toSet())) {
    final mobileBytes = mobile[path]!.readAsBytesSync();
    final desktopBytes = desktop[path]!.readAsBytesSync();
    if (!_sameBytes(mobileBytes, desktopBytes)) {
      findings.add('support_mirror_content_mismatch:$label:$path');
    }
  }
}

Map<String, File> _relativeFiles(Directory root) {
  if (!root.existsSync()) return const <String, File>{};
  final prefixLength = root.path.length + 1;
  return <String, File>{
    for (final entity in root.listSync(recursive: true, followLinks: false))
      if (entity is File)
        entity.path
                .substring(prefixLength)
                .replaceAll(Platform.pathSeparator, '/'):
            entity,
  };
}

bool _sameBytes(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}
