import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:huahuo_product/huahuo_product.dart';

// resident-provider: Shares one immutable product feature catalog across Desktop routes.
final desktopFeatureRegistryRepositoryProvider =
    Provider<FeatureRegistryRepository>((ref) => const ProductFeatureCatalog());

// resident-provider: Preserves feature-registry validation state for the Desktop process.
final desktopFeatureRegistryControllerProvider =
    Provider<FeatureRegistryController>(
      (ref) => FeatureRegistryController(
        ref.watch(desktopFeatureRegistryRepositoryProvider),
      ),
    );

// resident-provider: Keeps one validated Desktop feature state for the application process.
final desktopFeatureRegistryProvider = FutureProvider<FeatureRegistryState>(
  (ref) => ref.watch(desktopFeatureRegistryControllerProvider).load(),
);

// resident-provider: Shares sorted Desktop commands for the application process.
final desktopFeatureCommandsProvider = Provider<List<DesktopFeatureCommand>>(
  (ref) => desktopFeatureCommands(ProductFeatureCatalog.entries),
);

// resident-provider: Shares the approved visible Desktop feature set across shell routes.
final desktopVisibleFeaturesProvider = Provider<List<FeatureEntry>>(
  (ref) => List<FeatureEntry>.unmodifiable(
    ProductFeatureCatalog.entries.where(
      (entry) => entry.bindingFor(ProductPlatform.desktop).isVisible,
    ),
  ),
);

final class DesktopFeatureCommand {
  const DesktopFeatureCommand({
    required this.id,
    required this.title,
    required this.location,
    required this.domain,
  });

  final FeatureId id;
  final String title;
  final String location;
  final FeatureDomain domain;
}

List<DesktopFeatureCommand> desktopFeatureCommands(List<FeatureEntry> entries) {
  final commands = <DesktopFeatureCommand>[];
  for (final entry in entries) {
    final binding = entry.bindingFor(ProductPlatform.desktop);
    if (!binding.isVisible) continue;
    final route = binding.entryPoints
        .where((point) => point.kind == FeatureEntryKind.route)
        .firstOrNull;
    if (route == null) continue;
    commands.add(
      DesktopFeatureCommand(
        id: entry.descriptor.id,
        title: entry.descriptor.title,
        location: route.locator,
        domain: entry.descriptor.domain,
      ),
    );
  }
  commands.sort((left, right) => left.id.compareTo(right.id));
  return List<DesktopFeatureCommand>.unmodifiable(commands);
}
