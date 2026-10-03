import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:huahuo_product/huahuo_product.dart';

import '../../tool/feature_parity_check.dart';

void main() {
  test('real workspace has no unexplained parity gaps', () {
    expect(featureParityFindings(Directory.current.parent), isEmpty);
  });

  test('reports a missing implementation evidence path', () {
    final entries = <FeatureEntry>[
      _entry(
        desktopAvailability: FeatureAvailability.enabled,
        desktopEvidence: 'desktop/lib/does_not_exist.dart',
      ),
      ..._approvedDeferralFixtures(),
    ];

    expect(
      featureParityFindings(Directory.current.parent, entries: entries),
      contains(contains('missing_evidence:test.feature:desktop')),
    );
  });

  test('rejects an unapproved hidden Desktop capability', () {
    final entries = <FeatureEntry>[
      _entry(
        desktopAvailability: FeatureAvailability.hidden,
        desktopEvidence: null,
        policy: FeaturePlatformPolicy.desktopNativeDeferred,
      ),
      ..._approvedDeferralFixtures(),
    ];

    expect(
      featureParityFindings(Directory.current.parent, entries: entries),
      contains('unapproved_desktop_deferral:test.feature'),
    );
  });

  test('reports missing, extra, and changed support mirror files', () {
    final root = Directory.systemTemp.createTempSync('support-parity-');
    addTearDown(() => root.deleteSync(recursive: true));
    final mobileHelp = Directory('${root.path}/src/assets/help')
      ..createSync(recursive: true);
    final desktopHelp = Directory('${root.path}/desktop/assets/support/help')
      ..createSync(recursive: true);
    final mobileLegal = Directory('${root.path}/src/assets/legal')
      ..createSync(recursive: true);
    final desktopLegal = Directory('${root.path}/desktop/assets/support/legal')
      ..createSync(recursive: true);
    File('${mobileHelp.path}/same.md').writeAsStringSync('mobile');
    File('${desktopHelp.path}/same.md').writeAsStringSync('desktop');
    File('${mobileHelp.path}/missing.md').writeAsStringSync('missing');
    File('${desktopHelp.path}/extra.md').writeAsStringSync('extra');
    File('${mobileLegal.path}/privacy.md').writeAsStringSync('same');
    File('${desktopLegal.path}/privacy.md').writeAsStringSync('same');

    expect(supportContentParityFindings(root), <String>{
      'support_mirror_content_mismatch:help:same.md',
      'support_mirror_extra_desktop:help:extra.md',
      'support_mirror_missing_desktop:help:missing.md',
    });
  });
}

FeatureEntry _entry({
  required FeatureAvailability desktopAvailability,
  required String? desktopEvidence,
  FeaturePlatformPolicy policy = FeaturePlatformPolicy.shared,
  String id = 'test.feature',
}) => FeatureEntry(
  descriptor: FeatureDescriptor(
    id: FeatureId(id),
    domain: FeatureDomain.content,
    title: id,
    backendEndpointIds: const <String>[],
    states: const <String>['ready'],
    platformPolicy: policy,
    acceptanceScenarios: const <String>['success'],
  ),
  mobile: FeatureBinding(
    platform: ProductPlatform.mobile,
    availability: FeatureAvailability.enabled,
    entryPoints: const <FeatureEntryPoint>[
      FeatureEntryPoint(kind: FeatureEntryKind.route, locator: '/v3'),
    ],
    implementationEvidence: const <String>[
      'src/lib/app/navigation/app_routes.dart',
    ],
  ),
  desktop: FeatureBinding(
    platform: ProductPlatform.desktop,
    availability: desktopAvailability,
    entryPoints: desktopAvailability == FeatureAvailability.enabled
        ? const <FeatureEntryPoint>[
            FeatureEntryPoint(kind: FeatureEntryKind.route, locator: '/test'),
            FeatureEntryPoint(kind: FeatureEntryKind.sidebar, locator: '/test'),
            FeatureEntryPoint(kind: FeatureEntryKind.parent, locator: '/test'),
            FeatureEntryPoint(kind: FeatureEntryKind.command, locator: '/test'),
          ]
        : const <FeatureEntryPoint>[],
    implementationEvidence: desktopEvidence == null
        ? const <String>[]
        : <String>[desktopEvidence],
    reason: desktopAvailability != FeatureAvailability.enabled
        ? 'test-only deferral'
        : null,
  ),
);

Iterable<FeatureEntry> _approvedDeferralFixtures() =>
    approvedDesktopDeferrals.map(
      (id) => _entry(
        id: id,
        desktopAvailability: FeatureAvailability.hidden,
        desktopEvidence: null,
        policy: FeaturePlatformPolicy.desktopNativeDeferred,
      ),
    );
