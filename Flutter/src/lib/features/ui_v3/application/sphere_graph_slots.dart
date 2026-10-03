import 'sphere_graph_layout.dart';

final class SphereGraphSlots {
  SphereGraphSlots({this.minimumVisualNodeCount = 72});

  final int minimumVisualNodeCount;
  final SphereGraphLayout _layout = const SphereGraphLayout();
  final Map<String, SphereGraphLayoutPoint> _realPoints = {};
  final Map<String, SphereGraphLayoutPoint> _vacantPoints = {};
  int _releasedSlot = 0;
  bool _initialized = false;

  List<SphereGraphLayoutPoint> synchronize(Iterable<String> realNodeIds) {
    final supplied = realNodeIds.toList(growable: false);
    final ids = supplied.toSet();
    if (ids.length != supplied.length || ids.any((id) => id.trim().isEmpty)) {
      throw ArgumentError('Sphere note IDs must be unique and nonempty');
    }
    if (!_initialized) {
      for (final point in _layout.build(
        realNodeIds: const [],
        minimumVisualNodeCount: minimumVisualNodeCount,
      )) {
        _vacantPoints[point.id] = point;
      }
      _initialized = true;
    }
    final removed = _realPoints.keys.where((id) => !ids.contains(id)).toList();
    for (final id in removed) {
      final point = _realPoints.remove(id)!;
      final slotId = '__sphere_released_slot__${_releasedSlot++}';
      _vacantPoints[slotId] = _withIdentity(point, slotId, synthetic: true);
    }
    final added = ids.where((id) => !_realPoints.containsKey(id)).toList()
      ..sort();
    final conflictingSlots = _vacantPoints.keys.where(ids.contains).toList();
    for (final id in conflictingSlots) {
      final point = _vacantPoints.remove(id)!;
      var slotId = '__sphere_released_slot__${_releasedSlot++}';
      while (ids.contains(slotId) || _vacantPoints.containsKey(slotId)) {
        slotId = '__sphere_released_slot__${_releasedSlot++}';
      }
      _vacantPoints[slotId] = _withIdentity(point, slotId, synthetic: true);
    }
    final vacancies = _vacantPoints.keys.toList()..sort();
    for (final id in added) {
      if (vacancies.isNotEmpty) {
        final slotId = vacancies.removeLast();
        _realPoints[id] = _withIdentity(_vacantPoints.remove(slotId)!, id);
      } else {
        _realPoints[id] = _layout
            .build(realNodeIds: [id], minimumVisualNodeCount: 0)
            .single;
      }
    }
    final vacancyTarget = (minimumVisualNodeCount - ids.length).clamp(
      0,
      minimumVisualNodeCount,
    );
    while (_vacantPoints.length > vacancyTarget) {
      _vacantPoints.remove(_vacantPoints.keys.first);
    }
    final points = <SphereGraphLayoutPoint>[
      ..._realPoints.values,
      ..._vacantPoints.values,
    ]..sort((left, right) => left.id.compareTo(right.id));
    return List.unmodifiable(points);
  }

  void updatePosition(String id, SphereGraphLayoutPoint point) {
    if (!_realPoints.containsKey(id) || point.isSynthetic || point.id != id) {
      return;
    }
    _realPoints[id] = point;
  }

  SphereGraphLayoutPoint _withIdentity(
    SphereGraphLayoutPoint point,
    String id, {
    bool synthetic = false,
  }) => SphereGraphLayoutPoint(
    id: id,
    x: point.x,
    y: point.y,
    z: point.z,
    isSynthetic: synthetic,
  );
}
