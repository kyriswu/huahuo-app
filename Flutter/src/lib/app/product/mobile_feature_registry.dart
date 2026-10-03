import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:huahuo_product/huahuo_product.dart';

// resident-provider: Shares one immutable product feature catalog across Mobile routes.
final mobileFeatureRegistryRepositoryProvider =
    Provider<FeatureRegistryRepository>((ref) => const ProductFeatureCatalog());

// resident-provider: Preserves feature-registry validation state for the Mobile process.
final mobileFeatureRegistryControllerProvider =
    Provider<FeatureRegistryController>(
      (ref) => FeatureRegistryController(
        ref.watch(mobileFeatureRegistryRepositoryProvider),
      ),
    );

// resident-provider: Keeps one validated Mobile feature state for the application session.
final mobileFeatureRegistryProvider = FutureProvider<FeatureRegistryState>(
  (ref) => ref.watch(mobileFeatureRegistryControllerProvider).load(),
);
