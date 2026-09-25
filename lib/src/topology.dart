/// Splitting, merging and disconnecting: the operations that change what is
/// joined to what, and so what every relation over it holds.
///
/// As iD does them, rule for rule. Each works on an [OsmEditView] and
/// records what it does in its edits as one change to undo.
library;

import 'dart:math' as math;

import 'edit.dart';
import 'element.dart';
import 'operations.dart';
import 'presets.dart';

void _asOne(OsmEdits edits, void Function() change) {
  final mark = edits.length;
  change();
  edits.combineSince(mark);
}

/// Which of two ids belongs to the older element: anything already on the
/// map is older than anything made here, a lower id is older on the map,
/// and here the first made has the id nearest nothing.
int _compareAge(int a, int b) {
  if (a > 0 && b > 0) return a.compareTo(b);
  if (a > 0) return -1;
  if (b > 0) return 1;
  return b.compareTo(a);
}

int _oldest(Iterable<int> ids) => ids.reduce(
      (a, b) => _compareAge(a, b) <= 0 ? a : b,
    );

/// [into] with [tags] merged in, as iD merges them: a key only one has is
/// kept, and two different values become both, separated by semicolons.
/// Keys in [set] are set outright.
Map<String, String> _mergeTags(
  Map<String, String> into,
  Map<String, String> tags, {
  Map<String, String> set = const {},
}) {
  final merged = Map.of(into);
  for (final MapEntry(:key, :value) in tags.entries) {
    if (set.containsKey(key)) continue;
    final had = into[key];
    if (had == null || had.isEmpty) {
      merged[key] = value;
    } else if (had != value) {
      final parts = <String>[
        ...had.split(RegExp(r';\s*')),
        for (final part in value.split(RegExp(r';\s*')))
          if (!had.split(RegExp(r';\s*')).contains(part)) part,
      ];
      final joined = parts.join(';');
      merged[key] = joined.length > 255 ? joined.substring(0, 255) : joined;
    }
  }
  merged.addAll(set);
  return merged;
}

/// Keys whose values add up when two ways become one, and split between
/// them when one becomes two.
const _summable = {
  'step_count',
  'parking:both:capacity',
  'parking:left:capacity',
  'parking:right:capacity',
};

bool _canSum(String key, Map<String, String> a, Map<String, String> b) =>
    _summable.contains(key) &&
    num.tryParse(a[key] ?? '') != null &&
    num.tryParse(b[key] ?? '') != null;

/// Tags that stay on a way rather than going to the multipolygon it
/// becomes part of.
const _wayOnly = {
  'natural': {'coastline'},
};

/// Features with a right side and a wrong side — a cliff, a kerb, a coast —
/// whose direction says which is which.
const _sided = {
  'natural': {'cliff', 'coastline'},
  'barrier': {'retaining_wall', 'kerb', 'guard_rail', 'city_wall'},
  'man_made': {'embankment', 'quay'},
  'waterway': {'weir'},
  'cutting': {'yes', 'both', 'left', 'right'},
  'embankment': {'yes', 'dyke', 'both', 'left', 'right'},
};

const _lifecycle = {
  'proposed',
  'planned',
  'construction',
  'disused',
  'abandoned',
  'was',
  'dismantled',
  'razed',
  'demolished',
  'destroyed',
  'removed',
  'intermittent',
};

bool _isSided(Map<String, String> tags) {
  if (tags['two_sided'] == 'yes') return false;
  for (final MapEntry(key: raw, :value) in tags.entries) {
    final colon = raw.indexOf(':');
    final key = colon > 0 && _lifecycle.contains(raw.substring(0, colon))
        ? raw.substring(colon + 1)
        : raw;
    if (_sided[key]?.contains(value) ?? false) return true;
  }
  return false;
}

bool _hasFromViaTo(OsmRelation relation) =>
    relation.members.any((m) => m.role == 'from') &&
    relation.members.any(
      (m) =>
          m.role == 'via' ||
          (m.role == 'intersection' &&
              relation.tags['type'] == 'destination_sign'),
    ) &&
    relation.members.any((m) => m.role == 'to');

bool _isRestriction(OsmRelation r) =>
    RegExp(r'^restriction:?').hasMatch(r.tags['type'] ?? '');

bool _isConnectivity(OsmRelation r) =>
    RegExp(r'^connectivity:?').hasMatch(r.tags['type'] ?? '');

bool _isMultipolygon(OsmRelation r) => r.tags['type'] == 'multipolygon';

/// [relation]'s members with every membership of one element given to
/// another instead, keeping its role; one that would repeat a membership the
/// other already has in the same role is dropped.
List<OsmMember> _replaceMember(
  OsmRelation relation,
  OsmElementType fromType,
  int fromId,
  OsmElementType toType,
  int toId,
) {
  final members = <OsmMember>[];
  for (final member in relation.members) {
    if (member.type != fromType || member.ref != fromId) {
      members.add(member);
    } else if (!members.any(
      (m) => m.type == toType && m.ref == toId && m.role == member.role,
    )) {
      members.add(OsmMember(type: toType, ref: toId, role: member.role));
    }
  }
  return members;
}

void _giveMembership(
  OsmEditView view,
  OsmElementType fromType,
  int fromId,
  OsmElementType toType,
  int toId,
) {
  for (final relation in view.relationsUsing(fromType, fromId)) {
    view.edits.setRelationMembers(
      relation,
      _replaceMember(relation, fromType, fromId, toType, toId),
    );
  }
}

/// The distance between two nodes in metres, near enough for comparing
/// lengths.
double _distance(OsmNode a, OsmNode b) {
  const earth = 6371008.8;
  const radians = math.pi / 180;
  final lat1 = a.latitude * radians, lat2 = b.latitude * radians;
  final dLat = lat2 - lat1;
  final dLon = (b.longitude - a.longitude) * radians;
  final h = math.pow(math.sin(dLat / 2), 2) +
      math.cos(lat1) * math.cos(lat2) * math.pow(math.sin(dLon / 2), 2);
  return 2 * earth * math.asin(math.min(1, math.sqrt(h)));
}

double _length(OsmEditView view, List<int> ids) {
  var total = 0.0;
  for (var i = 0; i + 1 < ids.length; i++) {
    final a = view.node(ids[i]), b = view.node(ids[i + 1]);
    total += a != null && b != null ? _distance(a, b) : 1e-6;
  }
  return total;
}

/// A way's nodes with every occurrence of one node given to another, and
/// the repeat that leaves where the two were next to each other taken out.
List<int> _replaceNode(List<int> nodes, int from, int to) {
  final out = <int>[];
  for (final id in nodes) {
    final now = id == from ? to : id;
    if (out.isNotEmpty && out.last == now) continue;
    out.add(now);
  }
  return out;
}

/// One run of ways joined end to end: the ways, each with whether it has to
/// be turned round to run the same way as the rest, and the nodes they make
/// together.
class _Sequence {
  final ways = <(OsmWay, bool)>[];
  final nodes = <int>[];
}

/// [ways] joined into as few runs as they make, as iD joins them.
List<_Sequence> _joinWays(List<OsmWay> ways) {
  final remaining = [...ways];
  final sequences = <_Sequence>[];
  while (remaining.isNotEmpty) {
    final sequence = _Sequence();
    final first = remaining.removeAt(0);
    sequence.ways.add((first, false));
    sequence.nodes.addAll(first.nodeIds);
    var joined = true;
    while (joined && remaining.isNotEmpty) {
      joined = false;
      final start = sequence.nodes.first, end = sequence.nodes.last;
      for (var i = 0; i < remaining.length; i++) {
        final way = remaining[i];
        final nodes = way.nodeIds;
        if (nodes.isEmpty) continue;
        if (nodes.first == end) {
          sequence.nodes.addAll(nodes.skip(1));
          sequence.ways.add((way, false));
        } else if (nodes.last == end) {
          sequence.nodes.addAll(nodes.reversed.skip(1));
          sequence.ways.add((way, true));
        } else if (nodes.last == start) {
          sequence.nodes.insertAll(0, nodes.take(nodes.length - 1));
          sequence.ways.insert(0, (way, false));
        } else if (nodes.first == start) {
          sequence.nodes.insertAll(0, nodes.skip(1).toList().reversed);
          sequence.ways.insert(0, (way, true));
        } else {
          continue;
        }
        remaining.removeAt(i);
        joined = true;
        break;
      }
    }
    sequences.add(sequence);
  }
  return sequences;
}

/// Whether two paths cross anywhere but at a node they share.
bool _pathsCross(OsmEditView view, List<int> a, List<int> b) {
  // All brought round to the same side of the antimeridian: segments either
  // side of it are next to each other, not a world apart, and a segment
  // across it is short, not round the world.
  double? origin;
  (double, double)? at(int id) {
    final node = view.node(id);
    if (node == null) return null;
    origin ??= node.longitude;
    final turns = ((node.longitude - origin!) / 360).roundToDouble();
    return (node.longitude - turns * 360, node.latitude);
  }

  for (var i = 0; i + 1 < a.length; i++) {
    final p1 = at(a[i]), p2 = at(a[i + 1]);
    if (p1 == null || p2 == null) continue;
    for (var j = 0; j + 1 < b.length; j++) {
      if ({a[i], a[i + 1]}.intersection({b[j], b[j + 1]}).isNotEmpty) continue;
      final q1 = at(b[j]), q2 = at(b[j + 1]);
      if (q1 == null || q2 == null) continue;
      if (_segmentsCross(p1, p2, q1, q2)) return true;
    }
  }
  return false;
}

bool _segmentsCross(
  (double, double) p1,
  (double, double) p2,
  (double, double) q1,
  (double, double) q2,
) {
  double cross((double, double) o, (double, double) a, (double, double) b) =>
      (a.$1 - o.$1) * (b.$2 - o.$2) - (a.$2 - o.$2) * (b.$1 - o.$1);
  final d1 = cross(q1, q2, p1), d2 = cross(q1, q2, p2);
  final d3 = cross(p1, p2, q1), d4 = cross(p1, p2, q2);
  return ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) &&
      ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0));
}

/// Splitting lines where the selected nodes are.
class OsmSplit {
  final OsmEditView _view;

  /// What is selected, as it now stands.
  final List<OsmElement> selected;

  late final List<OsmNode> _vertices = [
    for (final element in selected)
      if (element is OsmNode && _view.geometryOf(element) == OsmGeometry.vertex)
        element,
  ];

  late final List<OsmWay> _limit = selected.whereType<OsmWay>().toList();

  /// Creates the operation.
  OsmSplit(this._view, this.selected);

  /// Whether it can be done: nodes along lines are selected, and nothing
  /// but them and the lines to split.
  bool get available =>
      _vertices.isNotEmpty &&
      _vertices.length + _limit.length == selected.length;

  bool _splittableAt(OsmWay way, int nodeId) {
    if (_limit.isNotEmpty && !_limit.any((w) => w.id == way.id)) {
      return false;
    }
    // A closed way can be split anywhere; an open one not at its ends.
    if (way.isClosed) return true;
    for (var i = 1; i < way.nodeIds.length - 1; i++) {
      if (way.nodeIds[i] == nodeId) return true;
    }
    return false;
  }

  /// The ways to be split: those every selected node can split, and of
  /// those only the lines if there are any, unless the ways were chosen.
  List<OsmWay> get ways {
    Set<int>? common;
    final byId = <int, OsmWay>{};
    for (final vertex in _vertices) {
      final ids = <int>{};
      for (final way in _view.waysUsing(vertex.id)) {
        if (!_splittableAt(way, vertex.id)) continue;
        ids.add(way.id);
        byId[way.id] = way;
      }
      common = common == null ? ids : common.intersection(ids);
    }
    final found = [for (final id in common ?? const <int>{}) byId[id]!];
    if (_limit.isEmpty) {
      final lines = [
        for (final way in found)
          if (_view.geometryOf(way) == OsmGeometry.line) way,
      ];
      if (lines.isNotEmpty) return lines;
    }
    return found;
  }

  /// What is split, for choosing how to describe it: `line`, `area`, or
  /// `feature` for both.
  String get kind {
    final shapes = {for (final way in ways) _view.geometryOf(way)};
    if (shapes.length != 1) return 'feature';
    return shapes.single == OsmGeometry.area ? 'area' : 'line';
  }

  /// Why it cannot be done, in iD's words for the reason, or null if it can.
  String? get disabled {
    final candidates = ways;
    if (candidates.isEmpty ||
        (_limit.isNotEmpty && _limit.length != candidates.length)) {
      return 'not_eligible';
    }
    for (final way in candidates) {
      for (final relation in _view.relationsUsing(OsmElementType.way, way.id)) {
        if (_hasFromViaTo(relation)) {
          final vias = relation.members.where(
            (m) => m.role == 'via' || m.role == 'intersection',
          );
          if (!vias.every(_held)) return 'parent_incomplete';
        } else {
          final members = relation.members;
          for (var i = 0; i < members.length; i++) {
            final m = members[i];
            if (m.type != OsmElementType.way || m.ref != way.id) continue;
            final before = i > 0 && _held(members[i - 1]);
            final after = i < members.length - 1 && _held(members[i + 1]);
            if (!before && !after && members.length > 1) {
              return 'parent_incomplete';
            }
          }
        }
        const splittableTypes = {'junction', 'enforcement'};
        if (_isCircular(way) &&
            !splittableTypes.contains(relation.tags['type'])) {
          return 'simple_roundabout';
        }
      }
    }
    return null;
  }

  static bool _isCircular(OsmWay way) =>
      {'roundabout', 'circular'}.contains(way.tags['junction']) && way.isClosed;

  bool _held(OsmMember member) => switch (member.type) {
        OsmElementType.node => _view.node(member.ref) != null,
        OsmElementType.way => _view.way(member.ref) != null,
        OsmElementType.relation => _view.relation(member.ref) != null,
      };

  /// Splits them, as one change, and gives back every way the splitting
  /// leaves, old and new, for selecting.
  List<OsmWay> apply() {
    final results = <int>{};
    _asOne(_view.edits, () {
      final ids = [for (final vertex in _vertices) vertex.id];
      for (final candidate in ways) {
        final made = <int>[];
        for (var i = 0; i < ids.length; i++) {
          final others = ids.sublist(i + 1);
          final way = _view.way(candidate.id);
          if (way != null) {
            if (_split(way, ids[i], others) case final created?) {
              made.add(created);
            }
          }
          // Pieces split off by an earlier node may hold this one too.
          for (final id in [...made]) {
            final piece = _view.way(id);
            if (piece == null) continue;
            if (_split(piece, ids[i], others) case final created?) {
              made.add(created);
            }
          }
        }
        results
          ..add(candidate.id)
          ..addAll(made);
      }
    });
    return [
      for (final id in results)
        if (_view.way(id) case final way?) way,
    ];
  }

  /// Splits [way] at [nodeId], and gives back the id of the new way, or
  /// null if there was nothing to split.
  ///
  /// The longer piece keeps the way's id and so its history. A closed way
  /// is split at a second node as well: the next selected one if there is
  /// one, and otherwise the one across its narrowest waist, far round the
  /// ring but near in a straight line.
  int? _split(OsmWay way, int nodeId, List<int> otherNodeIds) {
    final view = _view;
    if (!way.nodeIds.contains(nodeId)) return null;
    final isArea = view.geometryOf(way) == OsmGeometry.area;
    List<int> nodesA, nodesB;
    if (way.isClosed) {
      final nodes = way.nodeIds.sublist(0, way.nodeIds.length - 1);
      final a = nodes.indexOf(nodeId);
      final b = otherNodeIds.isNotEmpty && nodes.contains(otherNodeIds.first)
          ? nodes.indexOf(otherNodeIds.first)
          : _acrossTheWaist(nodes, a);
      if (b < a) {
        nodesA = [...nodes.sublist(a), ...nodes.sublist(0, b + 1)];
        nodesB = nodes.sublist(b, a + 1);
      } else {
        nodesA = nodes.sublist(a, b + 1);
        nodesB = [...nodes.sublist(b), ...nodes.sublist(0, a + 1)];
      }
    } else {
      final at = way.nodeIds.indexOf(nodeId, 1);
      if (at < 0) return null;
      nodesA = way.nodeIds.sublist(0, at + 1);
      nodesB = way.nodeIds.sublist(at);
    }
    if (nodesA.length < 2 || nodesB.length < 2) return null;

    var lengthA = _length(view, nodesA), lengthB = _length(view, nodesB);
    if (lengthB > lengthA) {
      (nodesA, nodesB) = (nodesB, nodesA);
      (lengthA, lengthB) = (lengthB, lengthA);
    }

    // What is counted along the way is divided between the pieces by
    // length.
    final tagsA = Map.of(way.tags), tagsB = Map.of(way.tags);
    for (final key in way.tags.keys) {
      if (!_summable.contains(key)) continue;
      final count = num.tryParse(way.tags[key]!);
      if (count == null || count <= 0 || count != count.round()) continue;
      final countA = (count * lengthA / (lengthA + lengthB)).round();
      tagsA[key] = '$countA';
      tagsB[key] = '${count.round() - countA}';
    }

    view.edits.setWayNodes(way, nodesA);
    view.edits.setTags(view.way(way.id)!, tagsA);
    final wayA = view.way(way.id)!;
    final wayB = view.edits.createWay(nodeIds: nodesB, tags: tagsB);

    for (final relation in view.relationsUsing(OsmElementType.way, way.id)) {
      if (_hasFromViaTo(relation)) {
        _splitRestriction(relation, wayA, wayB);
      } else if (!isArea) {
        _insertBeside(relation, wayA, wayB);
      }
    }

    if (isArea) {
      // An area in two pieces is a multipolygon of them.
      final areaTags = {...wayA.tags, 'type': 'multipolygon'};
      final lineTags = <String, String>{};
      for (final MapEntry(:key, :value) in wayA.tags.entries) {
        if (_wayOnly[key]?.contains(value) ?? false) {
          lineTags[key] = value;
          areaTags.remove(key);
        }
      }
      final multipolygon = view.edits.createRelation(
        members: [
          OsmMember(type: OsmElementType.way, ref: wayA.id, role: 'outer'),
          OsmMember(type: OsmElementType.way, ref: wayB.id, role: 'outer'),
        ],
        tags: areaTags,
      );
      for (final relation in view.relationsUsing(OsmElementType.way, way.id)) {
        if (relation.id == multipolygon.id) continue;
        view.edits.setRelationMembers(
          relation,
          _replaceMember(
            relation,
            OsmElementType.way,
            wayA.id,
            OsmElementType.relation,
            multipolygon.id,
          ),
        );
      }
      view.edits.setTags(view.way(wayA.id)!, lineTags);
      view.edits.setTags(view.way(wayB.id)!, lineTags);
    }
    return wayB.id;
  }

  /// The node across a ring from the one at [a]: the one furthest round
  /// the ring for how near it is in a straight line.
  int _acrossTheWaist(List<int> nodes, int a) {
    final n = nodes.length;
    int wrap(int i) => ((i % n) + n) % n;
    double dist(int i, int j) {
      final p = _view.node(nodes[i]), q = _view.node(nodes[j]);
      return p != null && q != null ? _distance(p, q) : 1e-6;
    }

    final lengths = List<double>.filled(n, 0);
    var length = 0.0;
    for (var i = wrap(a + 1); i != a; i = wrap(i + 1)) {
      length += dist(i, wrap(i - 1));
      lengths[i] = length;
    }
    length = 0;
    for (var i = wrap(a - 1); i != a; i = wrap(i - 1)) {
      length += dist(i, wrap(i + 1));
      if (length < lengths[i]) lengths[i] = length;
    }
    var best = 0.0;
    var b = wrap(a + n ~/ 2);
    for (var i = 0; i < n; i++) {
      final away = dist(a, i);
      if (away == 0) continue;
      final cost = lengths[i] / away;
      if (cost > best) {
        best = cost;
        b = i;
      }
    }
    return b;
  }

  /// Keeps a turn restriction right after one of its ways is split: a way
  /// it turns from or to keeps only the piece that reaches the junction,
  /// and a way it goes through has the new piece added beside it.
  void _splitRestriction(OsmRelation relation, OsmWay wayA, OsmWay wayB) {
    final from = relation.members.firstWhere((m) => m.role == 'from');
    final to = relation.members.firstWhere((m) => m.role == 'to');
    final vias = [
      for (final m in relation.members)
        if (m.role == 'via' || m.role == 'intersection') m,
    ];
    if (from.ref == wayA.id || to.ref == wayA.id) {
      var keepB = false;
      if (vias.length == 1 && vias.single.type == OsmElementType.node) {
        keepB = wayB.nodeIds.contains(vias.single.ref);
      } else {
        for (final via in vias) {
          if (via.type != OsmElementType.way) continue;
          final viaWay = _view.way(via.ref);
          if (viaWay != null && viaWay.nodeIds.any(wayB.nodeIds.contains)) {
            keepB = true;
            break;
          }
        }
      }
      if (keepB) {
        _view.edits.setRelationMembers(
          relation,
          _replaceMember(
            relation,
            OsmElementType.way,
            wayA.id,
            OsmElementType.way,
            wayB.id,
          ),
        );
      }
    } else if (vias.any(
      (m) => m.type == OsmElementType.way && m.ref == wayA.id,
    )) {
      _insertBeside(relation, wayA, wayB);
    }
  }

  /// Adds [wayB] to [relation] next to [wayA], before it or after it,
  /// whichever keeps the relation's ways running on from each other, as
  /// iD judges it.
  void _insertBeside(OsmRelation relation, OsmWay wayA, OsmWay wayB) {
    bool connects(OsmWay one, OsmWay two) {
      if (one.nodeIds.length < 2 || two.nodeIds.length < 2) return false;
      if (_isCircular(one)) {
        return one.nodeIds.any(
          (id) => id == two.nodeIds.first || id == two.nodeIds.last,
        );
      }
      if (_isCircular(two)) {
        return two.nodeIds.any(
          (id) => id == one.nodeIds.first || id == one.nodeIds.last,
        );
      }
      return one.nodeIds.first == two.nodeIds.first ||
          one.nodeIds.first == two.nodeIds.last ||
          one.nodeIds.last == two.nodeIds.last ||
          one.nodeIds.last == two.nodeIds.first;
    }

    OsmWay? wayAt(List<OsmMember> members, int i) =>
        i >= 0 && i < members.length && members[i].type == OsmElementType.way
            ? _view.way(members[i].ref)
            : null;

    final members = relation.members;
    final inserts = <(int, String)>[];
    for (var i = 0; i < members.length; i++) {
      final member = members[i];
      if (member.type != OsmElementType.way || member.ref != wayA.id) continue;
      final prev = wayAt(members, i - 1), next = wayAt(members, i + 1);
      final aPrev = prev != null && connects(prev, wayA);
      final bPrev = prev != null && connects(prev, wayB);
      final aNext = next != null && connects(next, wayA);
      final bNext = next != null && connects(next, wayB);
      int? at;
      if ((aPrev && !aNext) || (!bPrev && bNext && !(!aPrev && aNext))) {
        at = i + 1;
      } else if ((!aPrev && aNext) || (bPrev && !bNext && !(aPrev && !aNext))) {
        at = i;
      } else if (aPrev && bPrev && aNext && bNext) {
        // A loop: look one further along each way.
        final prev2 = i > 2 ? wayAt(members, i - 2) : null;
        final next2 = wayAt(members, i + 2);
        if (prev2 != null && connects(prev2, wayA) && !connects(prev2, wayB)) {
          at = i;
        } else if (prev2 != null &&
            connects(prev2, wayB) &&
            !connects(prev2, wayA)) {
          at = i + 1;
        } else if (next2 != null &&
            connects(next2, wayA) &&
            !connects(next2, wayB)) {
          at = i + 1;
        } else if (next2 != null &&
            connects(next2, wayB) &&
            !connects(next2, wayA)) {
          at = i;
        }
      }
      at ??= wayA.nodeIds.last == wayB.nodeIds.first ? i + 1 : i;
      inserts.add((at, member.role));
    }
    if (inserts.isEmpty) return;
    final updated = [...members];
    for (final (at, role) in inserts.reversed) {
      updated.insert(
        at,
        OsmMember(type: OsmElementType.way, ref: wayB.id, role: role),
      );
    }
    _view.edits.setRelationMembers(relation, updated);
  }
}

/// Merging what is selected into one: lines end to end, points into the
/// line or area they describe, areas into a multipolygon, or nodes into one
/// node — whichever of those the selection is, tried in that order.
class OsmMerge {
  final OsmEditView _view;

  /// What is selected, as it now stands.
  final List<OsmElement> selected;

  /// The most nodes a way can have, which the API says; see
  /// [OsmCapabilities.maximumWayNodes]. Two thousand on OpenStreetMap.
  final int maximumWayNodes;

  /// Creates the operation.
  OsmMerge(this._view, this.selected, {this.maximumWayNodes = 2000});

  /// Whether it can be done: two things or more are selected.
  bool get available => selected.length >= 2;

  late final _way = selected.whereType<OsmWay>().toList();
  late final _nodes = selected.whereType<OsmNode>().toList();
  late final _relations = selected.whereType<OsmRelation>().toList();

  List<OsmElement> _of(OsmGeometry geometry) => [
        for (final element in selected)
          if (_view.geometryOf(element) == geometry) element,
      ];

  /// Which way of merging applies, and why it cannot be done if none can.
  (int, String?) get _choice {
    final reasons = [_joinDisabled, _pointsDisabled, _polygonDisabled];
    for (var i = 0; i < reasons.length; i++) {
      if (reasons[i] != null) continue;
      if (i == 0) {
        final ways = _of(OsmGeometry.line).cast<OsmWay>().toList();
        if (_joinWays(ways).single.nodes.length > maximumWayNodes) {
          return (0, 'too_many_vertices');
        }
      }
      return (i, null);
    }
    final nodes = _nodesDisabled;
    if (nodes == null) return (3, null);
    for (var i = 0; i < reasons.length; i++) {
      if (reasons[i] != 'not_eligible') return (i, reasons[i]);
    }
    return (3, nodes);
  }

  /// Why it cannot be done, in iD's words for the reason, or null if it can.
  String? get disabled => _choice.$2;

  /// Merges them, as one change, and gives back what is left of them for
  /// selecting: the ones that say something, if any do.
  List<OsmElement> apply() {
    final (way, reason) = _choice;
    if (reason != null) return const [];
    _asOne(
        _view.edits,
        switch (way) {
          0 => _join,
          1 => _mergePoints,
          2 => _mergePolygons,
          _ => _mergeNodes,
        });
    final left = [
      for (final element in selected)
        if (_now(element) case final now?) now,
    ];
    if (left.length > 1) {
      final interesting = [
        for (final element in left)
          if (osmHasInterestingTags(element.tags)) element,
      ];
      if (interesting.isNotEmpty) return interesting;
    }
    return left;
  }

  OsmElement? _now(OsmElement element) => switch (element) {
        OsmNode() => _view.node(element.id),
        OsmWay() => _view.way(element.id),
        OsmRelation() => _view.relation(element.id),
      };

  // Lines end to end.

  List<OsmRelation> _parents(OsmWay way) => [
        for (final r in _view.relationsUsing(OsmElementType.way, way.id))
          if (!_isRestriction(r) && !_isConnectivity(r)) r,
      ];

  String? get _joinDisabled {
    final lines = _of(OsmGeometry.line);
    if (selected.length < 2 || lines.length != selected.length) {
      return 'not_eligible';
    }
    final ways = lines.cast<OsmWay>();
    final sequences = _joinWays(ways);
    if (sequences.length > 1) return 'not_adjacent';

    Set<int> parentIds(OsmWay way) => {for (final r in _parents(way)) r.id};
    final first = parentIds(ways.first);
    for (final way in ways.skip(1)) {
      final other = parentIds(way);
      if (other.length != first.length || !other.containsAll(first)) {
        return 'conflicting_relations';
      }
    }

    for (var i = 0; i < ways.length - 1; i++) {
      for (var j = i + 1; j < ways.length; j++) {
        if (_pathsCross(_view, ways[i].nodeIds, ways[j].nodeIds)) {
          return 'paths_intersect';
        }
      }
    }

    final joined = sequences.single.nodes;
    final inner = joined.sublist(1, joined.length - 1).toSet();
    OsmRelation? restricting;
    final tags = <String, String>{};
    var conflicting = false;
    for (final way in ways) {
      for (final parent in _view.relationsUsing(OsmElementType.way, way.id)) {
        if ((_isRestriction(parent) || _isConnectivity(parent)) &&
            parent.members.any(
              (m) => m.type == OsmElementType.node && inner.contains(m.ref),
            )) {
          restricting = parent;
        }
      }
      for (final MapEntry(:key, :value) in way.tags.entries) {
        final had = tags[key];
        if (had == null) {
          tags[key] = value;
        } else if (_canSum(key, tags, way.tags)) {
          tags[key] = '${num.parse(had) + num.parse(value)}';
        } else if (had.isNotEmpty &&
            osmHasInterestingTags({key: had}) &&
            had != value) {
          conflicting = true;
        }
      }
    }
    if (restricting != null) {
      return _isRestriction(restricting) ? 'restriction' : 'connectivity';
    }
    if (conflicting) return 'conflicting_tags';
    return null;
  }

  void _join() {
    final view = _view;
    final ways = _of(OsmGeometry.line).cast<OsmWay>().toList();
    final survivorId = _oldest([for (final way in ways) way.id]);
    // A cliff or a coast knows which side is which by its direction, so it
    // sets the direction for the rest.
    // In order otherwise: a sort here need not keep it, and the order the
    // lines were selected in is what decides which way the joined one runs.
    final sided = [
      for (final way in ways)
        if (_isSided(way.tags)) way
    ];
    ways
      ..removeWhere((way) => _isSided(way.tags))
      ..insertAll(0, sided);
    final sequence = _joinWays(ways).single;
    for (final (way, reversed) in sequence.ways) {
      if (reversed) osmReverseWay(view, view.way(way.id)!, oneway: true);
    }
    view.edits.setWayNodes(view.way(survivorId)!, sequence.nodes);

    for (final (way, _) in sequence.ways) {
      if (way.id == survivorId) continue;
      final gone = view.way(way.id)!;
      _giveMembership(
        view,
        OsmElementType.way,
        gone.id,
        OsmElementType.way,
        survivorId,
      );
      final survivor = view.way(survivorId)!;
      final summed = <String, String>{
        for (final key in gone.tags.keys)
          if (_canSum(key, gone.tags, survivor.tags))
            key:
                '${num.parse(gone.tags[key]!) + num.parse(survivor.tags[key]!)}',
      };
      view.edits.setTags(
        survivor,
        _mergeTags(survivor.tags, gone.tags, set: summed),
      );
      view.edits.deleteWay(
        gone,
        relations: view.relationsUsing(OsmElementType.way, gone.id),
      );
    }
    _collapseMultipolygon(survivorId);
  }

  /// Turns a multipolygon a join has left with a single closed member back
  /// into a plain area.
  void _collapseMultipolygon(int survivorId) {
    final view = _view;
    final survivor = view.way(survivorId)!;
    if (!survivor.isClosed) return;
    final multipolygons = [
      for (final r in view.relationsUsing(OsmElementType.way, survivorId))
        if (_isMultipolygon(r) && r.members.length == 1) r,
    ];
    if (multipolygons.length != 1) return;
    final multipolygon = multipolygons.single;
    for (final MapEntry(:key, :value) in survivor.tags.entries) {
      final had = multipolygon.tags[key];
      if (had != null && had != value) return;
    }
    final tags = _mergeTags(survivor.tags, multipolygon.tags);
    _giveMembership(
      view,
      OsmElementType.relation,
      multipolygon.id,
      OsmElementType.way,
      survivorId,
    );
    view.edits.deleteRelation(
      view.relation(multipolygon.id)!,
      relations: view.relationsUsing(OsmElementType.relation, multipolygon.id),
    );
    tags.remove('type');
    final area = view.geometryOf(
      OsmWay(id: survivorId, nodeIds: survivor.nodeIds, tags: tags),
    );
    if (area != OsmGeometry.area) tags['area'] = 'yes';
    view.edits.setTags(view.way(survivorId)!, tags);
  }

  // Points into a line or an area.

  String? get _pointsDisabled {
    final points = _of(OsmGeometry.point);
    final targets = _of(OsmGeometry.area).whereType<OsmWay>().length +
        _of(OsmGeometry.line).length;
    if (points.isEmpty || targets != 1 || _relations.isNotEmpty) {
      return 'not_eligible';
    }
    return null;
  }

  void _mergePoints() {
    final view = _view;
    final targetId = (_of(OsmGeometry.area).whereType<OsmWay>().firstOrNull ??
            _of(OsmGeometry.line).first)
        .id;
    for (final element in _of(OsmGeometry.point)) {
      final point = view.node(element.id)!;
      var target = view.way(targetId)!;
      view.edits.setTags(target, _mergeTags(target.tags, point.tags));
      _giveMembership(
        view,
        OsmElementType.node,
        point.id,
        OsmElementType.way,
        targetId,
      );
      target = view.way(targetId)!;

      // A point already on the map takes the place of one of the way's own
      // nodes, so that its history carries on in the way.
      var remove = point;
      if (point.id > 0) {
        bool replaceable(OsmNode node) =>
            view.waysUsing(node.id).length <= 1 &&
            view.relationsUsing(OsmElementType.node, node.id).isEmpty;
        final nodes = [
          for (final id in target.nodeIds.toSet())
            if (view.node(id) case final node?) node,
        ];
        OsmNode? replacing =
            nodes.where((n) => replaceable(n) && n.id < 0).firstOrNull;
        if (replacing == null && osmHasInterestingTags(point.tags)) {
          replacing = nodes
                  .where(
                    (n) => replaceable(n) && !osmHasInterestingTags(n.tags),
                  )
                  .firstOrNull ??
              nodes
                  .where(
                    (n) => replaceable(n) && _compareAge(point.id, n.id) < 0,
                  )
                  .firstOrNull;
        }
        if (replacing != null) {
          view.edits.moveNode(
            view.node(point.id)!,
            latitude: replacing.latitude,
            longitude: replacing.longitude,
          );
          view.edits.setTags(view.node(point.id)!, replacing.tags);
          view.edits.setWayNodes(target, [
            for (final id in target.nodeIds) id == replacing.id ? point.id : id,
          ]);
          remove = replacing;
        }
      }
      view.edits.deleteNode(
        view.node(remove.id)!,
        from: view.waysUsing(remove.id),
        relations: view.relationsUsing(OsmElementType.node, remove.id),
      );
    }
    // An area tag that the rest of the tags now make needless goes.
    final target = view.way(targetId)!;
    if (target.tags['area'] == 'yes') {
      final tags = Map.of(target.tags)..remove('area');
      final without =
          OsmWay(id: target.id, nodeIds: target.nodeIds, tags: tags);
      if (target.isClosed && view.geometryOf(without) == OsmGeometry.area) {
        view.edits.setTags(target, tags);
      }
    }
  }

  // Areas into a multipolygon.

  List<OsmWay> get _closedWays => [
        for (final way in _way)
          if (way.isClosed) way,
      ];

  List<OsmRelation> get _multipolygons => [
        for (final r in _relations)
          if (_isMultipolygon(r)) r,
      ];

  String? get _polygonDisabled {
    final closed = _closedWays, multipolygons = _multipolygons;
    if (closed.length + multipolygons.length != selected.length ||
        closed.length + multipolygons.length < 2) {
      return 'not_eligible';
    }
    for (final r in multipolygons) {
      if (!r.members.every(
        (m) => m.type != OsmElementType.way || _view.way(m.ref) != null,
      )) {
        return 'incomplete_relation';
      }
    }
    if (multipolygons.isEmpty) {
      Set<int>? shared;
      for (final way in closed) {
        final ids = {
          for (final r in _view.relationsUsing(OsmElementType.way, way.id))
            if (_isMultipolygon(r)) r.id,
        };
        shared = shared == null ? ids : shared.intersection(ids);
      }
      if ((shared ?? const {}).any(
        (id) => _view.relation(id)!.members.length == closed.length,
      )) {
        return 'not_eligible';
      }
    } else if (closed.any(
      (way) => _view
          .relationsUsing(OsmElementType.way, way.id)
          .any((r) => multipolygons.any((m) => m.id == r.id)),
    )) {
      return 'not_eligible';
    }
    return null;
  }

  void _mergePolygons() {
    final view = _view;
    final multipolygons = _multipolygons;
    final closed = _closedWays;

    // Every ring, with the ways that make it.
    final rings = <(List<int>, List<int>)>[
      for (final m in multipolygons)
        for (final sequence in _joinWays([
          for (final member in m.members)
            if (member.type == OsmElementType.way)
              if (view.way(member.ref) case final way?) way,
        ]))
          ([for (final (way, _) in sequence.ways) way.id], sequence.nodes),
      for (final way in closed) ([way.id], way.nodeIds),
    ];
    List<(double, double)> points(List<int> ids) => [
          for (final id in ids)
            if (view.node(id) case final node?) (node.longitude, node.latitude),
        ];
    final shapes = [for (final (_, nodes) in rings) points(nodes)];

    // Rings inside no other ring are outer; those inside only those are
    // inner; and so on, turn about.
    var remaining = [for (var i = 0; i < rings.length; i++) i];
    final members = <OsmMember>[];
    var outer = true;
    while (remaining.isNotEmpty) {
      final inside = {
        for (final i in remaining)
          if (remaining.any(
            (k) => k != i && _polygonContains(shapes[k], shapes[i]),
          ))
            i,
      };
      for (final i in remaining) {
        if (inside.contains(i)) continue;
        for (final id in rings[i].$1) {
          members.add(
            OsmMember(
              type: OsmElementType.way,
              ref: id,
              role: outer ? 'outer' : 'inner',
            ),
          );
        }
      }
      if (inside.length == remaining.length) break;
      remaining = inside.toList();
      outer = !outer;
    }

    var tags = <String, String>{'type': 'multipolygon'};
    OsmRelation? keep;
    if (multipolygons.isNotEmpty) {
      final oldest = _oldest([for (final m in multipolygons) m.id]);
      keep = view.relation(oldest)!;
      tags = Map.of(keep.tags);
    }
    for (final m in multipolygons) {
      if (m.id == keep?.id) continue;
      tags = _mergeTags(tags, m.tags);
      view.edits.deleteRelation(
        view.relation(m.id)!,
        relations: view.relationsUsing(OsmElementType.relation, m.id),
      );
    }
    for (final way in closed) {
      if (!members.any((m) => m.ref == way.id && m.role != 'inner')) continue;
      final areaTags = Map.of(way.tags);
      final lineTags = <String, String>{};
      for (final MapEntry(:key, :value) in way.tags.entries) {
        if (_wayOnly[key]?.contains(value) ?? false) {
          lineTags[key] = value;
          areaTags.remove(key);
        }
      }
      tags = _mergeTags(tags, areaTags);
      view.edits.setTags(view.way(way.id)!, lineTags);
    }
    tags.remove('area');
    if (keep != null) {
      view.edits.setRelationMembers(view.relation(keep.id)!, members);
      view.edits.setTags(view.relation(keep.id)!, tags);
    } else {
      view.edits.createRelation(members: members, tags: tags);
    }
  }

  static bool _polygonContains(
    List<(double, double)> outer,
    List<(double, double)> inner,
  ) =>
      inner.isNotEmpty && inner.every((p) => _pointInPolygon(p, outer));

  static bool _pointInPolygon(
      (double, double) point, List<(double, double)> ring) {
    var inside = false;
    for (var i = 0, j = ring.length - 1; i < ring.length; j = i++) {
      final (xi, yi) = ring[i];
      final (xj, yj) = ring[j];
      if ((yi > point.$2) != (yj > point.$2) &&
          point.$1 < (xj - xi) * (point.$2 - yi) / (yj - yi) + xi) {
        inside = !inside;
      }
    }
    return inside;
  }

  // Nodes into one.

  String? get _nodesDisabled {
    if (selected.length < 2 || _nodes.length != selected.length) {
      return 'not_eligible';
    }
    return osmConnectDisabled(_view, [for (final n in _nodes) n.id]);
  }

  void _mergeNodes() {
    final view = _view;
    final nodes = [for (final n in _nodes) view.node(n.id)!];
    // Where the one node saying something is, or the middle of them all.
    final interesting = [
      for (final node in nodes)
        if (osmHasInterestingTags(node.tags)) node,
    ];
    final double latitude, longitude;
    if (interesting.length == 1) {
      latitude = interesting.single.latitude;
      longitude = interesting.single.longitude;
    } else {
      latitude =
          nodes.map((n) => n.latitude).reduce((a, b) => a + b) / nodes.length;
      longitude =
          nodes.map((n) => n.longitude).reduce((a, b) => a + b) / nodes.length;
    }
    for (final node in nodes) {
      if (node.latitude == latitude && node.longitude == longitude) continue;
      view.edits.moveNode(
        view.node(node.id)!,
        latitude: latitude,
        longitude: longitude,
      );
    }
    osmConnect(view, [for (final node in nodes) node.id]);
  }
}

/// Makes the nodes [ids] one node, where the ways and relations through any
/// of them all go through it.
///
/// The one kept is the oldest of those already on the map that say
/// something, or failing that the oldest; the others' tags and memberships
/// go to it. A way left with too few nodes by two of its nodes becoming one
/// goes.
void osmConnect(OsmEditView view, List<int> ids) {
  final order = ids.reversed.toList();
  final interesting = [
    for (final id in order)
      if (id > 0 && osmHasInterestingTags(view.node(id)!.tags)) id,
  ];
  final survivorId = _oldest(interesting.isNotEmpty ? interesting : order);
  var tags = view.node(survivorId)!.tags;
  for (final id in order) {
    if (id == survivorId) continue;
    final node = view.node(id);
    if (node == null) continue;
    for (final way in view.waysUsing(id)) {
      view.edits.setWayNodes(way, _replaceNode(way.nodeIds, id, survivorId));
    }
    _giveMembership(
      view,
      OsmElementType.node,
      id,
      OsmElementType.node,
      survivorId,
    );
    tags = _mergeTags(tags, node.tags);
    view.edits.deleteNode(view.node(id)!);
  }
  view.edits.setTags(view.node(survivorId)!, tags);
  for (final way in view.waysUsing(survivorId)) {
    if (osmIsDegenerate(way)) OsmDelete(view, [way]).apply();
  }
}

/// Why the nodes [ids] cannot be made one, in iD's words for the reason, or
/// null if they can.
///
/// Not when they play different parts in one relation, and not when it
/// would spoil a turn restriction: joining the way turned from to the way
/// turned to, a junction to a node that is not next to it, or anything
/// that would leave one of its ways too short to be one.
String? osmConnectDisabled(OsmEditView view, List<int> ids) {
  final survivorId = _oldest(ids);
  final seen = <int, String>{};
  final restrictions = <int>{};
  for (final id in ids) {
    for (final relation in view.relationsUsing(OsmElementType.node, id)) {
      final role = relation.members
          .firstWhere((m) => m.type == OsmElementType.node && m.ref == id)
          .role;
      if (_hasFromViaTo(relation)) restrictions.add(relation.id);
      final had = seen[relation.id];
      if (had != null && had != role) return 'relation';
      seen[relation.id] = role;
    }
  }
  for (final id in ids) {
    for (final way in view.waysUsing(id)) {
      for (final relation in view.relationsUsing(OsmElementType.way, way.id)) {
        if (_hasFromViaTo(relation)) restrictions.add(relation.id);
      }
    }
  }

  for (final relationId in restrictions) {
    final relation = view.relation(relationId)!;
    // Only a restriction that is all here can be judged.
    final complete = relation.members.every(
      (m) => switch (m.type) {
        OsmElementType.node => view.node(m.ref) != null,
        OsmElementType.way => view.way(m.ref) != null,
        OsmElementType.relation => view.relation(m.ref) != null,
      },
    );
    if (!complete) continue;

    final memberWays = {
      for (final m in relation.members)
        if (m.type == OsmElementType.way) m.ref: view.way(m.ref)!,
    }.values.toList();
    final from = relation.members.firstWhere((m) => m.role == 'from');
    final to = relation.members.firstWhere((m) => m.role == 'to');
    final uturn = from.ref == to.ref;

    final nodes = <String, List<int>>{
      'from': [],
      'via': [],
      'to': [],
      'keyfrom': [],
      'keyto': [],
    };
    for (final member in relation.members) {
      final role = member.role;
      final list = nodes[role] ??= [];
      if (member.type == OsmElementType.node) {
        list.add(member.ref);
        if (role == 'via') {
          nodes['keyfrom']!.add(member.ref);
          nodes['keyto']!.add(member.ref);
        }
      } else if (member.type == OsmElementType.way) {
        final way = view.way(member.ref)!;
        list.addAll(way.nodeIds);
        if (role == 'from' || role == 'via') {
          nodes['keyfrom']!.addAll([way.nodeIds.first, way.nodeIds.last]);
        }
        if (role == 'to' || role == 'via') {
          nodes['keyto']!.addAll([way.nodeIds.first, way.nodeIds.last]);
        }
      }
    }
    List<int> repeated(List<int> list) => {
          for (final n in list)
            if (list.indexOf(n) != list.lastIndexOf(n)) n
        }.toList();
    final keyFrom = repeated(nodes['keyfrom']!);
    final keyTo = repeated(nodes['keyto']!);
    bool notKey(int n) => !keyFrom.contains(n) && !keyTo.contains(n);
    final fromNodes = nodes['from']!.where(notKey).toSet();
    final viaNodes = nodes['via']!.where(notKey).toSet();
    final toNodes = nodes['to']!.where(notKey).toSet();

    final connectFrom = ids.any(fromNodes.contains);
    final connectVia = ids.any(viaNodes.contains);
    final connectTo = ids.any(toNodes.contains);
    final connectKey = ids.any((n) => keyFrom.contains(n) || keyTo.contains(n));
    if (connectFrom && connectTo && !uturn) return 'restriction';
    if (connectFrom && connectVia) return 'restriction';
    if (connectTo && connectVia) return 'restriction';

    if (connectKey) {
      if (ids.length != 2) return 'restriction';
      int? n0, n1;
      for (final way in memberWays) {
        if (way.nodeIds.contains(ids[0])) n0 = ids[0];
        if (way.nodeIds.contains(ids[1])) n1 = ids[1];
      }
      if (n0 != null && n1 != null) {
        bool adjacent(OsmWay way) {
          for (var i = 0; i < way.nodeIds.length; i++) {
            if (way.nodeIds[i] != n0) continue;
            if (i > 0 && way.nodeIds[i - 1] == n1) return true;
            if (i + 1 < way.nodeIds.length && way.nodeIds[i + 1] == n1) {
              return true;
            }
          }
          return false;
        }

        if (!memberWays.any(adjacent)) return 'restriction';
      }
    }

    for (var way in memberWays) {
      for (final id in ids) {
        if (id == survivorId) continue;
        final index = way.nodeIds.indexOf(id);
        final adjacent = index >= 0 &&
            ((index > 0 && way.nodeIds[index - 1] == survivorId) ||
                (index + 1 < way.nodeIds.length &&
                    way.nodeIds[index + 1] == survivorId));
        way = OsmWay(
          id: way.id,
          nodeIds: adjacent
              ? OsmEdits.withoutNode(way, id)
              : [
                  for (final n in way.nodeIds) n == id ? survivorId : n,
                ],
        );
      }
      if (osmIsDegenerate(way)) return 'restriction';
    }
  }
  return null;
}

/// Disconnecting what is selected from what it is joined to.
class OsmDisconnect {
  final OsmEditView _view;

  /// What is selected, as it now stands.
  final List<OsmElement> selected;

  late final List<OsmNode> _vertices = [
    for (final element in selected)
      if (element is OsmNode && _view.geometryOf(element) == OsmGeometry.vertex)
        element,
  ];
  late final List<OsmWay> _ways = selected.whereType<OsmWay>().toList();
  late final int _others = selected.length - _vertices.length - _ways.length;

  /// Each node to disconnect, and the ways to disconnect there or null for
  /// all of them.
  late final List<(int, List<int>?)> _actions = _plan();

  /// Whether the selected ways were disconnected from each other, rather
  /// than from everything they touch.
  var _conjoined = false;

  /// Creates the operation.
  OsmDisconnect(this._view, this.selected);

  List<(int, List<int>?)> _plan() {
    if (_vertices.isNotEmpty) {
      return [
        for (final vertex in _vertices)
          (
            vertex.id,
            _ways.isEmpty
                ? null
                : [
                    for (final way in _ways)
                      if (way.nodeIds.contains(vertex.id)) way.id,
                  ],
          ),
      ];
    }
    if (_ways.isEmpty) return const [];
    final wayIds = [for (final way in _ways) way.id];
    final shared = <(int, List<int>?)>[];
    final unshared = <(int, List<int>?)>[];
    for (final id in {for (final way in _ways) ...way.nodeIds}) {
      if (_connections(id, wayIds).isEmpty) continue;
      final count = _ways.where((way) => way.nodeIds.contains(id)).length;
      (count > 1 ? shared : unshared).add((id, wayIds));
    }
    _conjoined = shared.isNotEmpty;
    return shared.isNotEmpty ? shared : unshared;
  }

  /// Whether it can be done.
  bool get available {
    if (_actions.isEmpty || _others != 0) return false;
    if (_vertices.isNotEmpty &&
        _ways.isNotEmpty &&
        !_ways.every(
          (way) => _vertices.any((v) => way.nodeIds.contains(v.id)),
        )) {
      return false;
    }
    return true;
  }

  /// What is disconnected, for choosing how to describe it, as iD names
  /// its descriptions: `single_point.no_ways`, `no_points.multiple_ways.
  /// conjoined` and so on.
  String get kind {
    final buffer = StringBuffer();
    if (_vertices.isNotEmpty) {
      buffer.write(_actions.length == 1 ? 'single_point.' : 'multiple_points.');
      if (_ways.length == 1) {
        buffer.write('single_way.${_shape(_ways.single)}');
      } else {
        buffer.write(_ways.isEmpty ? 'no_ways' : 'multiple_ways');
      }
    } else {
      buffer.write('no_points.');
      buffer.write(_ways.length == 1 ? 'single_way.' : 'multiple_ways.');
      if (_conjoined) {
        buffer.write('conjoined');
      } else {
        buffer.write(_ways.length == 1 ? _shape(_ways.single) : 'separate');
      }
    }
    return buffer.toString();
  }

  String _shape(OsmWay way) =>
      _view.geometryOf(way) == OsmGeometry.area ? 'area' : 'line';

  /// The nodes it disconnects at, for judging how much of it is in view.
  List<int> get nodes => [for (final (id, _) in _actions) id];

  /// Why it cannot be done, in iD's words for the reason, or null if it can.
  String? get disabled {
    for (final (id, limit) in _actions) {
      final reason = _disabledAt(id, limit);
      if (reason != null) return reason;
    }
    return null;
  }

  /// Relations whose members can be disconnected from each other without
  /// harm: they group things rather than join them.
  static const _loose = {'associatedStreet', 'enforcement', 'site'};

  String? _disabledAt(int id, List<int>? limit) {
    if (_connections(id, limit).isEmpty) return 'not_connected';
    final seen = <int, int>{};
    for (final way in _view.waysUsing(id)) {
      for (final relation in _view.relationsUsing(OsmElementType.way, way.id)) {
        if (_loose.contains(relation.tags['type'])) continue;
        final other = seen[relation.id];
        if (other != null) {
          if (limit == null ||
              limit.contains(way.id) ||
              limit.contains(other)) {
            return 'relation';
          }
        } else {
          seen[relation.id] = way.id;
        }
      }
    }
    return null;
  }

  /// Where at the node [id] a way has to be given a node of its own: a way
  /// and the place in it.
  List<(int, int)> _connections(int id, List<int>? limit) {
    final candidates = <(int, int)>[];
    var keeping = false;
    final ways = _view.waysUsing(id);
    for (final way in ways) {
      if (limit != null && !limit.contains(way.id)) {
        keeping = true;
        continue;
      }
      if (_view.geometryOf(way) == OsmGeometry.area &&
          way.nodeIds.first == id) {
        candidates.add((way.id, 0));
        continue;
      }
      for (var j = 0; j < way.nodeIds.length; j++) {
        if (way.nodeIds[j] != id) continue;
        if (way.isClosed &&
            ways.length > 1 &&
            limit != null &&
            limit.contains(way.id) &&
            j == way.nodeIds.length - 1) {
          continue;
        }
        candidates.add((way.id, j));
      }
    }
    // Something has to keep the node itself.
    return keeping ? candidates : candidates.skip(1).toList();
  }

  /// Disconnects it all, as one change.
  ///
  /// Every way but one at each node — or those selected — is given a node
  /// of its own in the same place, with the same tags.
  void apply() => _asOne(_view.edits, () {
        for (final (id, limit) in _actions) {
          final node = _view.node(id);
          if (node == null) continue;
          for (final (wayId, index) in _connections(id, limit)) {
            final way = _view.way(wayId)!;
            final copy = _view.edits.createNode(
              latitude: node.latitude,
              longitude: node.longitude,
              tags: node.tags,
            );
            final List<int> nodes;
            if (index == 0 && _view.geometryOf(way) == OsmGeometry.area) {
              final first = way.nodeIds.first;
              nodes = [for (final n in way.nodeIds) n == first ? copy.id : n];
            } else if (way.isClosed && index == way.nodeIds.length - 1) {
              nodes = [...way.nodeIds.take(way.nodeIds.length - 1), copy.id];
            } else {
              nodes = [...way.nodeIds]..[index] = copy.id;
            }
            _view.edits.setWayNodes(way, nodes);
          }
        }
      });
}
