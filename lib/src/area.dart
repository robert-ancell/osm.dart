import 'dart:math' as math;

import 'element.dart';

/// A ring and the rings it encloses.
class OsmPolygon {
  /// The outline, wound counter-clockwise, first point repeated at the end.
  final List<OsmNode> outer;

  /// The holes in it, each wound clockwise, first point repeated at the end.
  final List<List<OsmNode>> inners;

  /// Creates a polygon.
  const OsmPolygon({required this.outer, this.inners = const []});

  @override
  String toString() =>
      'OsmPolygon(${outer.length} points, ${inners.length} holes)';
}

/// The area an element covers, as one or more polygons.
///
/// A multipolygon relation can enclose several separate pieces of ground, an
/// island group being the plain case, so an area is a list of polygons rather
/// than a single one.
class OsmArea {
  /// The way or relation the area was assembled from.
  final OsmElement source;

  /// The polygons making it up, each with its own holes.
  final List<OsmPolygon> polygons;

  /// Creates an area.
  const OsmArea({required this.source, required this.polygons});

  @override
  String toString() => 'OsmArea(${source.type.name} ${source.id}, '
      '${polygons.length} polygons)';
}

/// Assembles the area [element] covers, or null if it does not cover one.
///
/// A closed way becomes a single polygon. Whether a given closed way is an
/// area at all or just a loop is a question about its tags that only the
/// caller can answer, so this assembles whatever it is given; `area=no` is the
/// tag that settles it in the data.
///
/// A relation is assembled as a multipolygon: its member ways are stitched
/// end to end into rings, and the rings are nested by containment to work out
/// which are outlines and which are holes. Member roles are not used for that.
/// They are wrong often enough in real data that geometry is the more reliable
/// answer, and a ring inside a ring is a hole whatever the file calls it.
///
/// Returns null if the element is not closed, if a ring cannot be closed, if
/// a member or node is missing, or if what comes out is not a polygon.
OsmArea? assembleArea(
  OsmElement element, {
  required OsmNode? Function(int id) node,
  required OsmWay? Function(int id) way,
}) {
  final rings = switch (element) {
    OsmNode() => null,
    OsmWay() => _ringsOfWay(element, node),
    OsmRelation() => _ringsOfRelation(element, node, way),
  };
  if (rings == null || rings.$1.isEmpty) return null;
  final polygons = _nest(rings.$1, rings.$2);
  return polygons.isEmpty ? null : OsmArea(source: element, polygons: polygons);
}

(List<List<OsmNode>>, List<(OsmNode, OsmNode)>)? _ringsOfWay(
  OsmWay way,
  OsmNode? Function(int) node,
) {
  if (!way.isClosed) return null;
  final ring = _resolve(way.nodeIds, node);
  // Through the same machinery as a relation: a way that touches itself
  // encloses more than one piece of ground.
  return ring == null ? null : _ringsFrom([ring]);
}

(List<List<OsmNode>>, List<(OsmNode, OsmNode)>)? _ringsOfRelation(
  OsmRelation relation,
  OsmNode? Function(int) node,
  OsmWay? Function(int) way,
) {
  // Ways only. A node member of a multipolygon carries no outline, and a
  // relation member is a nesting this does not follow.
  final parts = <List<OsmNode>>[];
  for (final member in relation.members) {
    if (member.type != OsmElementType.way) continue;
    final member0 = way(member.ref);
    if (member0 == null) return null;
    final points = _resolve(member0.nodeIds, node);
    if (points == null) return null;
    if (points.length >= 2) parts.add(points);
  }
  return parts.isEmpty ? null : _ringsFrom(parts);
}

List<OsmNode>? _resolve(List<int> ids, OsmNode? Function(int) node) {
  final points = <OsmNode>[];
  for (final id in ids) {
    final point = node(id);
    if (point == null) return null;
    points.add(point);
  }
  return points;
}

bool _isRing(List<OsmNode> points) =>
    points.length >= 4 && points.first.id == points.last.id;

/// Pulls the rings out of the segments the ways are made of.
///
/// Ways are not followed one at a time. Every way is broken into its segments,
/// a segment that appears an even number of times is dropped, and the rings
/// are read off the graph that is left. This is what makes two inner rings
/// that share an edge come out as the single ring they enclose, rather than as
/// two rings with an edge through the middle.
///
/// The graph is walked as faces: arriving at a node, the way out is the
/// neighbour next around from the way in, which turns as tightly as it can and
/// so traces each smallest ring separately. A ring that closes the long way
/// round the outside comes out wound the other way, and is dropped. Between
/// them these are what split a ring that touches itself into the pieces it
/// really encloses.
(List<List<OsmNode>>, List<(OsmNode, OsmNode)>)? _ringsFrom(
  List<List<OsmNode>> parts,
) {
  final points = <int, OsmNode>{};
  final counts = <(int, int), int>{};
  for (final part in parts) {
    for (var i = 1; i < part.length; i++) {
      final from = part[i - 1], to = part[i];
      // A node repeated in place is not a segment.
      if (from.id == to.id) continue;
      points[from.id] = from;
      points[to.id] = to;
      final key = from.id < to.id ? (from.id, to.id) : (to.id, from.id);
      counts[key] = (counts[key] ?? 0) + 1;
    }
  }

  final neighbours = <int, List<int>>{};
  final boundary = <(OsmNode, OsmNode)>[];
  for (final segment in counts.entries) {
    if (segment.value.isEven) continue;
    (neighbours[segment.key.$1] ??= []).add(segment.key.$2);
    (neighbours[segment.key.$2] ??= []).add(segment.key.$1);
    boundary.add((points[segment.key.$1]!, points[segment.key.$2]!));
  }
  if (neighbours.isEmpty) return null;

  // Around each node, its neighbours in order of the direction they lie in.
  for (final entry in neighbours.entries) {
    final here = points[entry.key]!;
    entry.value.sort((a, b) =>
        _bearing(here, points[a]!).compareTo(_bearing(here, points[b]!)));
  }

  final rings = <List<OsmNode>>[];
  final walked = <(int, int)>{};
  for (final entry in neighbours.entries) {
    for (final neighbour in entry.value) {
      final start = (entry.key, neighbour);
      if (walked.contains(start)) continue;

      final ring = <OsmNode>[];
      var edge = start;
      do {
        walked.add(edge);
        ring.add(points[edge.$1]!);
        final around = neighbours[edge.$2]!;
        final back = around.indexOf(edge.$1);
        edge = (edge.$2, around[(back - 1 + around.length) % around.length]);
      } while (edge != start);
      ring.add(points[start.$1]!);

      // Only the rings wound the one way are ground the area covers. The
      // others are the outsides of the same rings, walked the long way round.
      if (_isRing(ring) && _twiceArea(ring) > 0) {
        for (final simple in _simpleRings(ring)) {
          rings.add(_wound(simple, true));
        }
      }
    }
  }

  if (rings.isEmpty) return null;

  // A ring that touches itself is walked once as a whole and again as the
  // piece it encloses, so the same ring can come out twice.
  final seen = <String>{};
  final kept = [
    for (final ring in rings)
      if (seen.add((ring.map((n) => n.id).toList()..sort()).join(','))) ring,
  ];
  return kept.isEmpty ? null : (kept, boundary);
}

/// Whether the ground inside [ring] belongs to the area.
///
/// Rings that touch enclose pockets between them which are bounded by the
/// area's own edges and yet are not part of it: two rings meeting at two
/// nodes leave a gap in the middle of exactly that shape. The test is the one
/// the multipolygon rules are written in, crossings of the whole boundary:
/// ground inside an odd number of edges is in, ground inside an even number
/// is out.
bool _enclosesGround(List<OsmNode> ring, List<(OsmNode, OsmNode)> boundary) {
  final inside = _pointInside(ring);
  if (inside == null) return true; // Nothing better to go on.

  var crossings = 0;
  for (final (from, to) in boundary) {
    final x1 = from.longitude, y1 = from.latitude;
    final x2 = to.longitude, y2 = to.latitude;
    if ((y1 > inside.$2) == (y2 > inside.$2)) continue;
    if (inside.$1 < (x2 - x1) * (inside.$2 - y1) / (y2 - y1) + x1) crossings++;
  }
  return crossings.isOdd;
}

/// A point just inside the ring, next to its edge.
///
/// Next to the edge, not deep inside: the question being asked is what lies
/// on the inner side of this ring in particular, and the middle of a ring can
/// be in the middle of a hole. Rings touch at nodes, so the middle of an edge
/// is clear of them, and the longest edge is the one with the most room.
(double, double)? _pointInside(List<OsmNode> ring) {
  final edges = <int>[for (var i = 1; i < ring.length; i++) i];
  edges.sort((a, b) => _lengthSquared(ring[b - 1], ring[b])
      .compareTo(_lengthSquared(ring[a - 1], ring[a])));

  for (final i in edges) {
    final from = ring[i - 1], to = ring[i];
    final dx = to.longitude - from.longitude;
    final dy = to.latitude - from.latitude;
    final length = math.sqrt(dx * dx + dy * dy);
    if (length == 0) continue;

    // A step to the left of the edge, which for a ring wound
    // counter-clockwise is into it. Small enough to stay inside anything but
    // a shape far thinner than the precision the coordinates are stored at.
    final step = length * 1e-6;
    final x = (from.longitude + to.longitude) / 2 - dy / length * step;
    final y = (from.latitude + to.latitude) / 2 + dx / length * step;
    if (_contains(ring, x, y) == true) return (x, y);
  }
  return null;
}

double _lengthSquared(OsmNode a, OsmNode b) {
  final dx = a.longitude - b.longitude, dy = a.latitude - b.latitude;
  return dx * dx + dy * dy;
}

double _bearing(OsmNode from, OsmNode to) =>
    math.atan2(to.latitude - from.latitude, to.longitude - from.longitude);

/// Splits a ring that comes back to a node it has already been to.
///
/// Where a ring touches itself it is two rings meeting at a point, and which
/// ground each of them covers is a different question. Splitting them apart
/// here is what lets the nesting answer it: an inner ring touching its outer
/// at one node is a hole, and two outer rings touching at one node are two
/// pieces of ground.
List<List<OsmNode>> _simpleRings(List<OsmNode> ring) {
  final simple = <List<OsmNode>>[];
  final path = <OsmNode>[];
  final visited = <int, int>{};

  for (final node in ring.take(ring.length - 1)) {
    final before = visited[node.id];
    if (before != null) {
      final loop = [...path.skip(before), node];
      if (_isRing(loop)) simple.add(loop);
      for (var i = before; i < path.length; i++) {
        visited.remove(path[i].id);
      }
      path.removeRange(before, path.length);
    }
    visited[node.id] = path.length;
    path.add(node);
  }

  final rest = [...path, if (path.isNotEmpty) path.first];
  if (_isRing(rest)) simple.add(rest);
  return simple;
}

/// Works out which rings are outlines and which are holes.
///
/// A ring inside an odd number of others is a hole, and a ring inside an even
/// number is an outline, which is what makes an island in a lake in an island
/// come out right. Each hole is given to the smallest ring that encloses it.
List<OsmPolygon> _nest(
  List<List<OsmNode>> rings,
  List<(OsmNode, OsmNode)> boundary,
) {
  // What a ring encloses decides what it is. Depth does not: a pocket between
  // two holes that touch is inside one ring and is still ground, and an
  // island in a lake is inside two and is ground as well.
  final ground = [
    for (final ring in rings) _enclosesGround(ring, boundary),
  ];

  final parents = List<int?>.filled(rings.length, null);
  for (var i = 0; i < rings.length; i++) {
    if (ground[i]) continue;
    for (var j = 0; j < rings.length; j++) {
      if (i == j || !ground[j] || !_ringContains(rings[j], rings[i])) continue;
      final parent = parents[i];
      if (parent == null || _ringContains(rings[parent], rings[j])) {
        parents[i] = j;
      }
    }
  }

  final polygons = <int, List<List<OsmNode>>>{};
  for (var i = 0; i < rings.length; i++) {
    if (ground[i]) polygons[i] = [];
  }
  for (var i = 0; i < rings.length; i++) {
    // A ring enclosing no ground and inside nothing is a pocket between rings
    // that touch, bounded by the area's own edges and no part of it.
    if (!ground[i]) polygons[parents[i]]?.add(_wound(rings[i], false));
  }

  return [
    for (final entry in polygons.entries)
      OsmPolygon(outer: _wound(rings[entry.key], true), inners: entry.value),
  ];
}

/// Whether [inner] lies inside [outer].
///
/// Rings may share vertices, so vertices that land exactly on the other ring
/// say nothing and the next one is tried.
bool _ringContains(List<OsmNode> outer, List<OsmNode> inner) {
  for (final point in inner) {
    switch (_contains(outer, point.longitude, point.latitude)) {
      case true:
        return true;
      case false:
        return false;
      case null:
        continue;
    }
  }
  return false;
}

/// Whether the point is inside the ring, or null if it is on its edge.
bool? _contains(List<OsmNode> ring, double x, double y) {
  var inside = false;
  for (var i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    final xi = ring[i].longitude, yi = ring[i].latitude;
    final xj = ring[j].longitude, yj = ring[j].latitude;

    final cross = (xj - xi) * (y - yi) - (x - xi) * (yj - yi);
    if (cross == 0 && (x - xi) * (x - xj) <= 0 && (y - yi) * (y - yj) <= 0) {
      return null;
    }

    if ((yi > y) != (yj > y) && x < (xj - xi) * (y - yi) / (yj - yi) + xi) {
      inside = !inside;
    }
  }
  return inside;
}

/// The ring wound the way it should be: outlines counter-clockwise, holes
/// clockwise, which is the way GeoJSON and most triangulators want them.
List<OsmNode> _wound(List<OsmNode> ring, bool counterClockwise) =>
    (_twiceArea(ring) > 0) == counterClockwise
        ? ring
        : ring.reversed.toList(growable: false);

/// Twice the signed area of the ring, positive when it is wound
/// counter-clockwise.
double _twiceArea(List<OsmNode> ring) {
  var total = 0.0;
  for (var i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    total += (ring[j].longitude - ring[i].longitude) *
        (ring[j].latitude + ring[i].latitude);
  }
  return total;
}
