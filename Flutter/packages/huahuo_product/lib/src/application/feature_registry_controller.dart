import 'dart:collection';

import 'package:huahuo_api/huahuo_api.dart';

import '../domain/product_feature.dart';

abstract interface class FeatureRegistryRepository {
  Future<List<FeatureEntry>> load();
}

enum FeatureRegistryStatus { idle, loading, ready, failure }

final class FeatureRegistryState {
  FeatureRegistryState({
    required this.status,
    List<FeatureEntry> entries = const <FeatureEntry>[],
    this.errorCode,
  }) : entries = UnmodifiableListView(entries);

  factory FeatureRegistryState.initial() =>
      FeatureRegistryState(status: FeatureRegistryStatus.idle);

  final FeatureRegistryStatus status;
  final List<FeatureEntry> entries;
  final String? errorCode;

  List<FeatureEntry> visibleFor(ProductPlatform platform) =>
      List<FeatureEntry>.unmodifiable(
        entries.where((entry) => entry.bindingFor(platform).isVisible),
      );

  FeatureEntry? byId(FeatureId id) {
    for (final entry in entries) {
      if (entry.descriptor.id == id) return entry;
    }
    return null;
  }
}

final class FeatureRegistryController {
  FeatureRegistryController(this._repository);

  final FeatureRegistryRepository _repository;
  FeatureRegistryState _state = FeatureRegistryState.initial();

  FeatureRegistryState get state => _state;

  Future<FeatureRegistryState> load() async {
    _state = FeatureRegistryState(status: FeatureRegistryStatus.loading);
    try {
      final entries = await _repository.load();
      final report = FeatureParityAuditor.audit(entries);
      if (!report.isValid) {
        _state = FeatureRegistryState(
          status: FeatureRegistryStatus.failure,
          errorCode: 'FEATURE_REGISTRY_INVALID',
        );
      } else {
        _state = FeatureRegistryState(
          status: FeatureRegistryStatus.ready,
          entries: entries,
        );
      }
    } on Object {
      _state = FeatureRegistryState(
        status: FeatureRegistryStatus.failure,
        errorCode: 'FEATURE_REGISTRY_LOAD_FAILED',
      );
    }
    return _state;
  }
}

final class FeatureParityIssue {
  const FeatureParityIssue({
    required this.code,
    required this.featureId,
    required this.detail,
  });

  final String code;
  final FeatureId featureId;
  final String detail;
}

final class FeatureParityReport {
  FeatureParityReport(List<FeatureParityIssue> issues)
    : issues = UnmodifiableListView(issues);

  final List<FeatureParityIssue> issues;

  bool get isValid => issues.isEmpty;
}

abstract final class FeatureParityAuditor {
  static FeatureParityReport audit(List<FeatureEntry> entries) {
    final issues = <FeatureParityIssue>[];
    final seen = <FeatureId>{};
    for (final entry in entries) {
      final descriptor = entry.descriptor;
      if (!seen.add(descriptor.id)) {
        issues.add(_issue('duplicate_feature', descriptor.id, 'Duplicate ID'));
      }
      if (descriptor.states.isEmpty) {
        issues.add(_issue('missing_states', descriptor.id, 'No state set'));
      }
      if (descriptor.acceptanceScenarios.isEmpty) {
        issues.add(
          _issue('missing_acceptance', descriptor.id, 'No acceptance scenario'),
        );
      }
      for (final endpointId in descriptor.backendEndpointIds) {
        if (!EndpointCatalog.definitions.containsKey(endpointId)) {
          issues.add(_issue('unknown_endpoint', descriptor.id, endpointId));
        }
      }
      for (final platform in ProductPlatform.values) {
        final binding = entry.bindingFor(platform);
        if (binding.platform != platform) {
          issues.add(_issue('platform_mismatch', descriptor.id, platform.name));
        }
        if (binding.availability == FeatureAvailability.enabled &&
            (binding.entryPoints.isEmpty ||
                binding.implementationEvidence.isEmpty)) {
          issues.add(
            _issue('incomplete_binding', descriptor.id, platform.name),
          );
        }
        if ((binding.availability == FeatureAvailability.hidden ||
                binding.availability == FeatureAvailability.unavailable ||
                binding.availability == FeatureAvailability.blocked) &&
            (binding.reason == null || binding.reason!.trim().isEmpty)) {
          issues.add(
            _issue('unavailable_without_reason', descriptor.id, platform.name),
          );
        }
      }
      if (entry.parityStatus == FeatureParityStatus.missing ||
          entry.parityStatus == FeatureParityStatus.partial) {
        issues.add(
          _issue(
            'parity_${entry.parityStatus.name}',
            descriptor.id,
            'Unresolved',
          ),
        );
      }
    }
    return FeatureParityReport(issues);
  }

  static FeatureParityIssue _issue(
    String code,
    FeatureId featureId,
    String detail,
  ) => FeatureParityIssue(code: code, featureId: featureId, detail: detail);
}
