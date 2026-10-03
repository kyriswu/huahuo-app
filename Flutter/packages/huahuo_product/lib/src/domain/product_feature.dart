import 'dart:collection';

enum ProductPlatform { mobile, desktop }

enum FeatureDomain {
  runtime,
  account,
  content,
  knowledge,
  notifications,
  ingestion,
  recordings,
  chat,
  creation,
  digitalTwin,
  native,
}

enum FeatureAvailability { enabled, unavailable, blocked, hidden, retired }

enum FeatureEntryKind { route, sidebar, parent, command, background }

enum FeaturePlatformPolicy { shared, desktopNativeDeferred, retired }

enum FeatureParityStatus {
  aligned,
  partial,
  missing,
  blocked,
  deferred,
  retired,
}

final class FeatureId implements Comparable<FeatureId> {
  const FeatureId(this.value) : assert(value != '');

  final String value;

  @override
  int compareTo(FeatureId other) => value.compareTo(other.value);

  @override
  bool operator ==(Object other) => other is FeatureId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

final class FeatureEntryPoint {
  const FeatureEntryPoint({required this.kind, required this.locator});

  final FeatureEntryKind kind;
  final String locator;
}

final class FeatureDescriptor {
  FeatureDescriptor({
    required this.id,
    required this.domain,
    required this.title,
    required List<String> backendEndpointIds,
    required List<String> states,
    required this.platformPolicy,
    required List<String> acceptanceScenarios,
  }) : backendEndpointIds = List.unmodifiable(backendEndpointIds),
       states = List.unmodifiable(states),
       acceptanceScenarios = List.unmodifiable(acceptanceScenarios);

  final FeatureId id;
  final FeatureDomain domain;
  final String title;
  final List<String> backendEndpointIds;
  final List<String> states;
  final FeaturePlatformPolicy platformPolicy;
  final List<String> acceptanceScenarios;
}

final class FeatureBinding {
  FeatureBinding({
    required this.platform,
    required this.availability,
    required List<FeatureEntryPoint> entryPoints,
    required List<String> implementationEvidence,
    this.reason,
  }) : entryPoints = List.unmodifiable(entryPoints),
       implementationEvidence = List.unmodifiable(implementationEvidence);

  final ProductPlatform platform;
  final FeatureAvailability availability;
  final List<FeatureEntryPoint> entryPoints;
  final List<String> implementationEvidence;
  final String? reason;

  bool get isVisible => availability == FeatureAvailability.enabled;

  bool hasEntry(FeatureEntryKind kind) =>
      entryPoints.any((entry) => entry.kind == kind);
}

final class FeatureEntry {
  FeatureEntry({
    required this.descriptor,
    required FeatureBinding mobile,
    required FeatureBinding desktop,
  }) : bindings = UnmodifiableMapView(<ProductPlatform, FeatureBinding>{
         ProductPlatform.mobile: mobile,
         ProductPlatform.desktop: desktop,
       });

  final FeatureDescriptor descriptor;
  final Map<ProductPlatform, FeatureBinding> bindings;

  FeatureBinding bindingFor(ProductPlatform platform) => bindings[platform]!;

  FeatureParityStatus get parityStatus {
    if (descriptor.platformPolicy == FeaturePlatformPolicy.retired) {
      return FeatureParityStatus.retired;
    }
    final mobile = bindingFor(ProductPlatform.mobile);
    final desktop = bindingFor(ProductPlatform.desktop);
    if (mobile.availability == FeatureAvailability.blocked ||
        desktop.availability == FeatureAvailability.blocked) {
      return FeatureParityStatus.blocked;
    }
    if (descriptor.platformPolicy ==
            FeaturePlatformPolicy.desktopNativeDeferred &&
        mobile.availability == FeatureAvailability.enabled &&
        desktop.availability == FeatureAvailability.hidden) {
      return FeatureParityStatus.deferred;
    }
    if (mobile.availability == FeatureAvailability.enabled &&
        desktop.availability == FeatureAvailability.enabled) {
      if (mobile.entryPoints.isEmpty || desktop.entryPoints.isEmpty) {
        return FeatureParityStatus.partial;
      }
      return FeatureParityStatus.aligned;
    }
    if (mobile.availability == FeatureAvailability.retired &&
        desktop.availability == FeatureAvailability.retired) {
      return FeatureParityStatus.retired;
    }
    if (desktop.availability == FeatureAvailability.hidden ||
        desktop.availability == FeatureAvailability.unavailable) {
      return FeatureParityStatus.missing;
    }
    return FeatureParityStatus.partial;
  }
}
