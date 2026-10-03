import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// App-shipped color families for the desktop knowledge graph.
///
/// Storage values are stable user preference IDs. The actual light and dark
/// palettes live in the graph presentation layer so this model stays free of
/// Material and painting dependencies.
enum DesktopGraphColorPreset {
  mistSilver(storageValue: 'mist-silver', label: '雾银'),
  tide(storageValue: 'tide', label: '潮汐'),
  mountainMist(storageValue: 'mountain-mist', label: '山岚'),
  editorial(storageValue: 'editorial', label: '刊物'),
  nightVoyage(storageValue: 'night-voyage', label: '夜航'),
  electricYouth(storageValue: 'electric-youth', label: '电气青年'),
  candySignal(storageValue: 'candy-signal', label: '糖果信号'),
  egoPulse(storageValue: 'ego-pulse', label: 'EGO 脉冲'),
  pureInk(storageValue: 'pure-ink', label: '纯墨');

  const DesktopGraphColorPreset({
    required this.storageValue,
    required this.label,
  });

  final String storageValue;
  final String label;

  static DesktopGraphColorPreset? tryParse(String? value) {
    for (final preset in DesktopGraphColorPreset.values) {
      if (preset.storageValue == value) return preset;
    }
    return null;
  }
}

/// Persistable visual and motion tuning for the desktop knowledge graph.
///
/// Values are multipliers around the graph's established `1.0` baseline. The
/// factory clamps every value, which keeps preferences valid whether they are
/// created by settings controls, an agent, or older persisted data.
@immutable
final class DesktopGraphPreferences {
  factory DesktopGraphPreferences({
    double nodeScale = defaultScale,
    double attractionScale = defaultScale,
    double repulsionScale = defaultScale,
    double dampingScale = defaultScale,
    DesktopGraphColorPreset colorPreset = defaultColorPreset,
  }) => DesktopGraphPreferences._(
    nodeScale: _clampScale(nodeScale, minimumNodeScale, maximumNodeScale),
    attractionScale: _clampScale(
      attractionScale,
      minimumAttractionScale,
      maximumAttractionScale,
    ),
    repulsionScale: _clampScale(
      repulsionScale,
      minimumRepulsionScale,
      maximumRepulsionScale,
    ),
    dampingScale: _clampScale(
      dampingScale,
      minimumDampingScale,
      maximumDampingScale,
    ),
    colorPreset: colorPreset,
  );

  const DesktopGraphPreferences._({
    required this.nodeScale,
    required this.attractionScale,
    required this.repulsionScale,
    required this.dampingScale,
    required this.colorPreset,
  });

  static const double defaultScale = 1;
  static const double minimumNodeScale = .65;
  static const double maximumNodeScale = 1.6;
  static const double minimumAttractionScale = .35;
  static const double maximumAttractionScale = 2;
  static const double minimumRepulsionScale = .25;
  static const double maximumRepulsionScale = 2.25;
  static const double minimumDampingScale = .2;
  static const double maximumDampingScale = 2;
  static const DesktopGraphColorPreset defaultColorPreset =
      DesktopGraphColorPreset.mistSilver;

  /// Converts the friendly attraction setting into spring tension.
  ///
  /// `1.0` remains the existing force-layout baseline. Away from that center,
  /// the curve intentionally gains contrast so the two ends of Settings are
  /// perceptible in a live graph rather than only numerically different.
  static double attractionResponseFor(double value) => _forceResponse(
    value,
    minimum: minimumAttractionScale,
    maximum: maximumAttractionScale,
    lowExponent: 1.65,
    highExponent: 1.5,
  );

  /// Converts the friendly repulsion setting into local separation strength.
  static double repulsionResponseFor(double value) => _forceResponse(
    value,
    minimum: minimumRepulsionScale,
    maximum: maximumRepulsionScale,
    lowExponent: 1.72,
    highExponent: 1.45,
  );

  /// Converts the friendly damping setting into kinetic and spring damping.
  static double dampingResponseFor(double value) => _forceResponse(
    value,
    minimum: minimumDampingScale,
    maximum: maximumDampingScale,
    lowExponent: 1.45,
    highExponent: 1.35,
  );

  static const DesktopGraphPreferences defaults = DesktopGraphPreferences._(
    nodeScale: defaultScale,
    attractionScale: defaultScale,
    repulsionScale: defaultScale,
    dampingScale: defaultScale,
    colorPreset: defaultColorPreset,
  );

  final double nodeScale;
  final double attractionScale;
  final double repulsionScale;
  final double dampingScale;
  final DesktopGraphColorPreset colorPreset;

  DesktopGraphPreferences copyWith({
    double? nodeScale,
    double? attractionScale,
    double? repulsionScale,
    double? dampingScale,
    DesktopGraphColorPreset? colorPreset,
  }) => DesktopGraphPreferences(
    nodeScale: nodeScale ?? this.nodeScale,
    attractionScale: attractionScale ?? this.attractionScale,
    repulsionScale: repulsionScale ?? this.repulsionScale,
    dampingScale: dampingScale ?? this.dampingScale,
    colorPreset: colorPreset ?? this.colorPreset,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'nodeScale': nodeScale,
    'attractionScale': attractionScale,
    'repulsionScale': repulsionScale,
    'dampingScale': dampingScale,
    'colorPreset': colorPreset.storageValue,
  };

  factory DesktopGraphPreferences.fromJson(Map<String, Object?> json) {
    final rawPreset = json['colorPreset'];
    return DesktopGraphPreferences(
      nodeScale: _scaleFromJson(json['nodeScale']),
      attractionScale: _scaleFromJson(json['attractionScale']),
      repulsionScale: _scaleFromJson(json['repulsionScale']),
      dampingScale: _scaleFromJson(json['dampingScale']),
      colorPreset:
          DesktopGraphColorPreset.tryParse(
            rawPreset is String ? rawPreset : null,
          ) ??
          defaultColorPreset,
    );
  }

  static double _scaleFromJson(Object? value) =>
      value is num ? value.toDouble() : defaultScale;

  static double _forceResponse(
    double value, {
    required double minimum,
    required double maximum,
    required double lowExponent,
    required double highExponent,
  }) {
    final normalized = _clampScale(value, minimum, maximum);
    if (normalized == defaultScale) return defaultScale;
    final exponent = normalized < defaultScale ? lowExponent : highExponent;
    return math.pow(normalized, exponent).toDouble();
  }

  static double _clampScale(double value, double minimum, double maximum) {
    if (value.isNaN) return defaultScale;
    if (value < minimum) return minimum;
    if (value > maximum) return maximum;
    return value;
  }

  @override
  bool operator ==(Object other) =>
      other is DesktopGraphPreferences &&
      nodeScale == other.nodeScale &&
      attractionScale == other.attractionScale &&
      repulsionScale == other.repulsionScale &&
      dampingScale == other.dampingScale &&
      colorPreset == other.colorPreset;

  @override
  int get hashCode => Object.hash(
    nodeScale,
    attractionScale,
    repulsionScale,
    dampingScale,
    colorPreset,
  );
}

/// Durable storage boundary for app-wide desktop graph preferences.
abstract interface class DesktopGraphPreferencesStore {
  Future<DesktopGraphPreferences> load();

  Future<void> save(DesktopGraphPreferences preferences);
}

final class InMemoryDesktopGraphPreferencesStore
    implements DesktopGraphPreferencesStore {
  InMemoryDesktopGraphPreferencesStore([
    this.value = DesktopGraphPreferences.defaults,
  ]);

  DesktopGraphPreferences value;

  @override
  Future<DesktopGraphPreferences> load() async => value;

  @override
  Future<void> save(DesktopGraphPreferences preferences) async {
    value = preferences;
  }
}

/// Observable graph preferences with cheap previews and ordered persistence.
final class DesktopGraphPreferencesController
    extends ValueNotifier<DesktopGraphPreferences> {
  DesktopGraphPreferencesController({
    required DesktopGraphPreferencesStore store,
    DesktopGraphPreferences initialValue = DesktopGraphPreferences.defaults,
  }) : _store = store,
       super(initialValue);

  final DesktopGraphPreferencesStore _store;
  Future<void>? _loadFuture;
  Future<void> _saveChain = Future<void>.value();
  int _revision = 0;

  Future<void> load() => _loadFuture ??= _load();

  Future<void> _load() async {
    final revisionAtStart = _revision;
    DesktopGraphPreferences loaded;
    try {
      loaded = await _store.load();
    } on Object {
      loaded = DesktopGraphPreferences.defaults;
    }
    if (_revision == revisionAtStart && value != loaded) value = loaded;
  }

  void preview(DesktopGraphPreferences preferences) {
    _revision += 1;
    if (value != preferences) value = preferences;
  }

  Future<void> commit([DesktopGraphPreferences? preferences]) {
    _revision += 1;
    final committed = preferences ?? value;
    if (value != committed) value = committed;
    return _enqueueSave(committed);
  }

  Future<void> reset() => commit(DesktopGraphPreferences.defaults);

  Future<void> _enqueueSave(DesktopGraphPreferences preferences) {
    final previous = _saveChain;
    final next = _saveAfter(previous, preferences);
    _saveChain = next;
    return next;
  }

  Future<void> _saveAfter(
    Future<void> previous,
    DesktopGraphPreferences preferences,
  ) async {
    try {
      await previous;
    } on Object {
      // A failed older write must not block a newer user choice.
    }
    await _store.save(preferences);
  }
}
