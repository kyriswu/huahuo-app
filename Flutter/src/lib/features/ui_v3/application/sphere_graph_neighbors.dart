typedef SphereCoordinate = (double, double, double);

List<(int, int)> buildSphereNeighborPairs({
  required List<SphereCoordinate> coordinates,
  required List<String> ids,
}) {
  final count = coordinates.length;
  if (ids.length != count || ids.toSet().length != count) {
    throw ArgumentError('Neighbor coordinates require unique matching IDs');
  }
  if (coordinates.any(
    (point) => !point.$1.isFinite || !point.$2.isFinite || !point.$3.isFinite,
  )) {
    throw ArgumentError('Neighbor coordinates must be finite');
  }
  if (count <= 4) {
    return [
      for (var source = 0; source < count; source++)
        for (var target = source + 1; target < count; target++)
          (source, target),
    ];
  }
  final seeds = ids.map(_stableSeed).toList(growable: false);
  final neighbors = List.generate(count, (_) => <int>{});
  final pairs = <(int, int)>{};
  final tree = _NeighborTree(coordinates);
  final longExclusions = List.generate(count, (_) => <int>{});
  for (var source = 0; source < count; source++) {
    for (final candidate in tree.nearest(
      source,
      excluded: const {},
      limit: 4,
    )) {
      longExclusions[source].add(candidate.$2);
      longExclusions[candidate.$2].add(source);
    }
  }
  final hasLongConnection = List.filled(count, false);
  void connect(int source, int target) {
    if (source == target || !neighbors[source].add(target)) return;
    neighbors[target].add(source);
    pairs.add(_pair(source, target));
    if (!longExclusions[source].contains(target)) {
      hasLongConnection[source] = true;
      hasLongConnection[target] = true;
    }
  }

  int? choose(
    int source, {
    bool preferUnfilled = false,
    bool preferLong = false,
  }) {
    final candidates = tree.nearest(
      source,
      excluded: preferLong
          ? {...neighbors[source], ...longExclusions[source]}
          : neighbors[source],
      limit: preferLong ? 12 : 8,
    );
    int? best;
    var bestScore = double.infinity;
    for (var rank = 0; rank < candidates.length; rank++) {
      final candidate = candidates[rank];
      final mixed = (seeds[source] ^ seeds[candidate.$2]) & 0xffff;
      final jitter = .65 + mixed / 0xffff * .7;
      final localPreference = preferLong || rank < 4 ? 1.0 : 1.45;
      final degreePreference =
          preferUnfilled && neighbors[candidate.$2].length < 3 ? .8 : 1.0;
      final coveragePreference = preferLong && !hasLongConnection[candidate.$2]
          ? .65
          : 1.0;
      final score =
          candidate.$1 *
          jitter *
          localPreference *
          degreePreference *
          coveragePreference;
      if (score < bestScore) {
        bestScore = score;
        best = candidate.$2;
      }
    }
    return best;
  }

  final order = List.generate(count, (index) => index)
    ..sort((left, right) {
      final bySeed = seeds[left].compareTo(seeds[right]);
      return bySeed != 0 ? bySeed : ids[left].compareTo(ids[right]);
    });
  final first = order.first;
  var current = first;
  tree.setActive(current, false);
  for (var step = 1; step < count; step++) {
    final next = choose(current)!;
    connect(current, next);
    tree.setActive(next, false);
    current = next;
  }
  connect(current, first);
  for (final index in order) {
    tree.setActive(index, true);
  }
  for (final source in order) {
    if (hasLongConnection[source]) continue;
    final target = choose(source, preferLong: true);
    if (target != null) {
      connect(source, target);
      if (neighbors[source].length == 4) tree.setActive(source, false);
      if (neighbors[target].length == 4) tree.setActive(target, false);
      continue;
    }
    final donor = pairs.cast<(int, int)?>().firstWhere(
      (edge) =>
          edge!.$1 != source &&
          edge.$2 != source &&
          !longExclusions[source].contains(edge.$1) &&
          !longExclusions[source].contains(edge.$2) &&
          !neighbors[source].contains(edge.$1) &&
          !neighbors[source].contains(edge.$2),
      orElse: () => null,
    );
    if (donor == null) continue;
    neighbors[donor.$1].remove(donor.$2);
    neighbors[donor.$2].remove(donor.$1);
    pairs.remove(donor);
    connect(source, donor.$1);
    connect(source, donor.$2);
    tree.setActive(source, false);
  }
  for (final source in order) {
    if (neighbors[source].length >= 3) continue;
    final target = choose(source, preferUnfilled: true);
    if (target != null) {
      connect(source, target);
      if (neighbors[source].length == 4) tree.setActive(source, false);
      if (neighbors[target].length == 4) tree.setActive(target, false);
      continue;
    }
    final donor = pairs.cast<(int, int)?>().firstWhere(
      (edge) =>
          edge!.$1 != source &&
          edge.$2 != source &&
          !neighbors[source].contains(edge.$1) &&
          !neighbors[source].contains(edge.$2),
      orElse: () => null,
    );
    if (donor == null) continue;
    neighbors[donor.$1].remove(donor.$2);
    neighbors[donor.$2].remove(donor.$1);
    pairs.remove(donor);
    connect(source, donor.$1);
    connect(source, donor.$2);
    tree.setActive(source, false);
  }
  for (final index in order) {
    tree.setActive(
      index,
      neighbors[index].length < 4 && _stableSeed('${ids[index]}:fourth').isEven,
    );
  }
  for (final source in order) {
    if (neighbors[source].length >= 4 ||
        _stableSeed('${ids[source]}:fourth').isOdd) {
      continue;
    }
    final target = choose(source);
    if (target == null) continue;
    connect(source, target);
    tree.setActive(source, false);
    tree.setActive(target, false);
  }
  return pairs.toList()..sort((left, right) {
    final bySource = left.$1.compareTo(right.$1);
    return bySource != 0 ? bySource : left.$2.compareTo(right.$2);
  });
}

(int, int) _pair(int source, int target) =>
    source < target ? (source, target) : (target, source);

int _stableSeed(String value) {
  var seed = 0x811c9dc5;
  for (final codeUnit in value.codeUnits) {
    seed = ((seed ^ codeUnit) * 0x01000193) & 0xffffffff;
  }
  seed ^= seed >> 16;
  seed = (seed * 0x7feb352d) & 0xffffffff;
  return seed ^ (seed >> 15);
}

final class _NeighborTree {
  _NeighborTree(this.coordinates) {
    _nodes = List<_NeighborBranch?>.filled(coordinates.length, null);
    _root = _build(
      List.generate(coordinates.length, (index) => index),
      0,
      null,
    );
  }

  final List<SphereCoordinate> coordinates;
  late final List<_NeighborBranch?> _nodes;
  late final _NeighborBranch? _root;

  _NeighborBranch? _build(
    List<int> indices,
    int depth,
    _NeighborBranch? parent,
  ) {
    if (indices.isEmpty) return null;
    final axis = depth % 3;
    indices.sort((left, right) {
      final byPosition = _axis(
        coordinates[left],
        axis,
      ).compareTo(_axis(coordinates[right], axis));
      return byPosition != 0 ? byPosition : left.compareTo(right);
    });
    final middle = indices.length ~/ 2;
    final branch = _NeighborBranch(indices[middle], axis, parent);
    _nodes[branch.index] = branch;
    branch.left = _build(indices.sublist(0, middle), depth + 1, branch);
    branch.right = _build(indices.sublist(middle + 1), depth + 1, branch);
    branch.activeCount = indices.length;
    return branch;
  }

  void setActive(int index, bool active) {
    final branch = _nodes[index]!;
    if (branch.active == active) return;
    branch.active = active;
    final delta = active ? 1 : -1;
    for (
      var cursor = branch as _NeighborBranch?;
      cursor != null;
      cursor = cursor.parent
    ) {
      cursor.activeCount += delta;
    }
  }

  List<(double, int)> nearest(
    int source, {
    required Set<int> excluded,
    required int limit,
  }) {
    final matches = <(double, int)>[];
    final origin = coordinates[source];
    void visit(_NeighborBranch? branch) {
      if (branch == null || branch.activeCount == 0) return;
      final point = coordinates[branch.index];
      final delta = _axis(origin, branch.axis) - _axis(point, branch.axis);
      final near = delta <= 0 ? branch.left : branch.right;
      final far = delta <= 0 ? branch.right : branch.left;
      visit(near);
      if (branch.active &&
          branch.index != source &&
          !excluded.contains(branch.index)) {
        final horizontal = origin.$1 - point.$1;
        final vertical = origin.$2 - point.$2;
        final depth = origin.$3 - point.$3;
        final distance =
            horizontal * horizontal + vertical * vertical + depth * depth;
        var insertion = 0;
        while (insertion < matches.length &&
            (matches[insertion].$1 < distance ||
                matches[insertion].$1 == distance &&
                    matches[insertion].$2 < branch.index)) {
          insertion++;
        }
        if (insertion < limit) {
          matches.insert(insertion, (distance, branch.index));
          if (matches.length > limit) matches.removeLast();
        }
      }
      final boundary = matches.length < limit
          ? double.infinity
          : matches.last.$1;
      if (delta * delta <= boundary + 1e-15) visit(far);
    }

    visit(_root);
    return matches;
  }
}

final class _NeighborBranch {
  _NeighborBranch(this.index, this.axis, this.parent);

  final int index;
  final int axis;
  final _NeighborBranch? parent;
  _NeighborBranch? left;
  _NeighborBranch? right;
  bool active = true;
  int activeCount = 1;
}

double _axis(SphereCoordinate point, int axis) => switch (axis) {
  0 => point.$1,
  1 => point.$2,
  _ => point.$3,
};
