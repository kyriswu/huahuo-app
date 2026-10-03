import 'package:huahuo_product/huahuo_product.dart';
import 'package:test/test.dart';

void main() {
  group('ProductFeatureCatalog', () {
    test('requires zero unexplained Desktop implementation gaps', () {
      final report = FeatureParityAuditor.audit(ProductFeatureCatalog.entries);

      expect(
        report.issues.map((issue) => '${issue.code}:${issue.featureId}'),
        <String>{},
      );
    });

    test('hides exactly the approved Desktop native deferrals', () {
      final hidden = ProductFeatureCatalog.entries
          .where(
            (entry) =>
                entry.bindingFor(ProductPlatform.desktop).availability ==
                FeatureAvailability.hidden,
          )
          .map((entry) => entry.descriptor.id.value)
          .toSet();

      expect(hidden, <String>{
        'native.recordingCard',
        'native.liveCapture',
        'native.voiceprint',
        'native.systemNotifications',
        'native.homeWidget',
        'native.screenCapture',
        'native.storePurchase',
      });
    });

    test('all visible Desktop capabilities have every entry-point class', () {
      final desktop = ProductFeatureCatalog.entries.where(
        (entry) => entry.bindingFor(ProductPlatform.desktop).isVisible,
      );

      for (final entry in desktop) {
        final binding = entry.bindingFor(ProductPlatform.desktop);
        for (final kind in const <FeatureEntryKind>[
          FeatureEntryKind.route,
          FeatureEntryKind.sidebar,
          FeatureEntryKind.parent,
          FeatureEntryKind.command,
        ]) {
          expect(
            binding.hasEntry(kind),
            isTrue,
            reason: '${entry.descriptor.id}: ${kind.name}',
          );
        }
      }
    });
  });

  group('FeatureRegistryController', () {
    test('loads the registry after all parity gaps are resolved', () async {
      final controller = FeatureRegistryController(
        const ProductFeatureCatalog(),
      );

      final state = await controller.load();

      expect(state.status, FeatureRegistryStatus.ready);
      expect(state.errorCode, isNull);
      expect(state.entries, isNotEmpty);
    });

    test('blocked external contract stays distinct and invisible', () {
      final entry = ProductFeatureCatalog.entries.singleWhere(
        (item) => item.descriptor.id.value == 'account.transactions',
      );

      expect(entry.parityStatus, FeatureParityStatus.blocked);
      expect(entry.bindingFor(ProductPlatform.desktop).isVisible, isFalse);
      expect(
        entry.bindingFor(ProductPlatform.desktop).reason,
        contains('/api/v1/billing/transactions'),
      );
    });

    test('reports repository failures without leaking exceptions', () async {
      final controller = FeatureRegistryController(_FailingRepository());

      final state = await controller.load();

      expect(state.status, FeatureRegistryStatus.failure);
      expect(state.errorCode, 'FEATURE_REGISTRY_LOAD_FAILED');
      expect(state.entries, isEmpty);
    });
  });
}

final class _FailingRepository implements FeatureRegistryRepository {
  @override
  Future<List<FeatureEntry>> load() =>
      Future<List<FeatureEntry>>.error(StateError('fixture'));
}
