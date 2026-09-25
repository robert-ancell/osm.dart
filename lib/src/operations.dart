/// Things done to what is selected, each as one change: deleting it,
/// reversing it, pulling a point out of it, knowing what line it would
/// continue, copying and pasting it, and moving it.
///
/// Each works on an [OsmEditor] — what was read with what has been changed laid
/// over it — and records what it does in its [OsmEditor.history], gathered into
/// one change to undo.
library;

import 'dart:math' as math;

import 'edit.dart';
import 'element.dart';
import 'mercator.dart';
import 'tag_rules.dart';

/// Something done to what is selected: deleting,
/// reversing, extracting, splitting, merging or disconnecting.
///
/// Each is made over the map as it now stands and the selection, says
/// whether it applies to that selection at all ([available]) and, if it
/// does, why it cannot be done ([disabled]), and then does it ([apply]) as
/// one change that one undo takes back. [T] is what it gives back: what it
/// made, for selecting afterwards, or nothing.
///
/// Made by the editor that it is done to — [OsmEditor.delete],
/// [OsmEditor.split] and the rest — which is how a program asks for one.
abstract class OsmOperation<T> {
  /// What it is to be done to, as it now stands.
  List<OsmElement> get selected;

  /// Whether it applies to [selected] at all, and so is worth offering.
  bool get available;

  /// Why it cannot be done, or null if it can.
  ///
  /// Only asked of an operation that is [available]: one that is not is not
  /// offered, disabled or otherwise.
  OsmDisabledReason? get disabled => null;

  /// Does it, as one change.
  ///
  /// Only for an operation that is [available] and not [disabled].
  T apply();
}

/// Deleting what is selected.
class OsmDeleteOperation extends OsmOperation<void> {
  final OsmEditor _view;

  /// What is to be deleted, as it now stands.
  @override
  final List<OsmElement> selected;

  /// Creates the operation.
  OsmDeleteOperation(this._view, this.selected);

  /// Whether it can be done: anything can be deleted.
  @override
  bool get available => selected.isNotEmpty;

  /// Why it cannot be done, or null if it can.
  ///
  /// A way that is part of a route or a boundary, or an outer edge of a
  /// multipolygon, would leave a hole in something larger, and has to be
  /// taken out of it first. Something with a Wikidata tag is somebody's
  /// careful work, linked from elsewhere, and is not deleted by accident.
  @override
  OsmDisabledReason? get disabled {
    for (final element in selected) {
      final reason = _view.rules.whyProtected(element, _view);
      if (reason != null) return reason;
    }
    return null;
  }

  /// Deletes it all, as one change.
  ///
  /// A way left with too few nodes by a node going goes too, as does a
  /// relation left with no members. A way takes with it those of its nodes
  /// that nothing else uses and that say nothing of their own.
  @override
  void apply() => _view.group(() {
        for (final element in selected) {
          switch (element) {
            case OsmNode():
              if (_view.node(element.id) case final node?) _deleteNode(node);
            case OsmWay():
              if (_view.way(element.id) case final way?) _deleteWay(way);
            case OsmRelation():
              if (_view.relation(element.id) case final r?) _deleteRelation(r);
          }
        }
      });

  void _deleteNode(OsmNode node) {
    final ways = _view.waysUsing(node.id);
    final relations = _view.relationsUsing(OsmElementType.node, node.id);
    _view.deleteNode(node);
    for (final way in ways) {
      final now = _view.way(way.id);
      if (now != null && now.isDegenerate) _deleteWay(now);
    }
    _deleteEmpty(relations);
  }

  void _deleteWay(OsmWay way) {
    final relations = _view.relationsUsing(OsmElementType.way, way.id);
    _view.deleteWay(way);
    _deleteEmpty(relations);
    for (final id in way.nodeIds.toSet()) {
      final node = _view.node(id);
      if (node == null) continue;
      if (_view.waysUsing(id).isNotEmpty) continue;
      if (_view.relationsUsing(OsmElementType.node, id).isNotEmpty) continue;
      if (_view.rules.isDescriptive(node.tags)) continue;
      _view.deleteNode(node);
    }
  }

  void _deleteRelation(OsmRelation relation) {
    final parents = _view.relationsUsing(OsmElementType.relation, relation.id);
    _view.deleteRelation(relation);
    _deleteEmpty(parents);
  }

  void _deleteEmpty(List<OsmRelation> relations) {
    for (final relation in relations) {
      final now = _view.relation(relation.id);
      if (now != null && now.members.isEmpty) _deleteRelation(now);
    }
  }
}

/// Reversing what is selected: the direction of a line, and of anything
/// tagged with a direction.
class OsmReverseOperation extends OsmOperation<void> {
  final OsmEditor _view;

  /// What is to be reversed, as it now stands.
  @override
  final List<OsmElement> selected;

  /// Creates the operation.
  OsmReverseOperation(this._view, this.selected);

  /// What of the selection reverses: its lines, and the nodes that say
  /// which way they face. Areas have no direction.
  List<OsmElement> get reversible => [
        for (final element in selected)
          if (element is OsmWay &&
              _view.geometryOf(element) == OsmGeometry.line)
            element
          else if (element is OsmNode && _hasDirection(element.tags))
            element,
      ];

  /// Whether it can be done.
  @override
  bool get available => reversible.isNotEmpty;

  /// Reverses it all, as one change.
  ///
  /// A line runs the other way, and its tags and those of its nodes that
  /// say which way something faces are turned round with it: left and
  /// right, forward and backward, up and down, and an incline's sign. Its
  /// part in a route going forward or backward is turned round too. Its
  /// `oneway` is left alone: a oneway drawn the wrong way round is what
  /// reversing is usually for. A node on its own also has its compass
  /// direction turned round.
  @override
  void apply() => _view.group(() {
        for (final element in reversible) {
          switch (element) {
            case OsmWay():
              osmReverseWay(_view, element);
            case OsmNode():
              _reverseNode(element.id, absolute: true);
            case OsmRelation():
              break;
          }
        }
      });

  void _reverseNode(int id, {required bool absolute}) {
    final node = _view.node(id);
    if (node == null || node.tags.isEmpty) return;
    _view.setTags(node, _view.rules.reversed(node.tags, standalone: absolute));
  }

  bool _hasDirection(Map<String, String> tags) {
    final reversed = _view.rules.reversed(tags, standalone: true);
    if (reversed.length != tags.length) return true;
    return tags.entries.any((e) => reversed[e.key] != e.value);
  }
}

/// Turns [way] round in [view]'s edits: its nodes run the other way, and
/// its tags, its nodes' tags and its part in any route going forward or
/// backward turn round with it.
///
/// Its `oneway` only turns round with [oneway]: reversing a way on its own
/// is usually done to put right a oneway drawn backwards, and turning the
/// tag round too would undo the point of it; reversing one to join it to
/// another has to keep traffic going the way it went.
void osmReverseWay(OsmEditor view, OsmWay way, {bool oneway = false}) {
  for (final relation in view.relationsUsing(OsmElementType.way, way.id)) {
    var changed = false;
    final members = [
      for (final member in relation.members)
        if (member.type == OsmElementType.way &&
            member.ref == way.id &&
            view.rules.reversedRole(member.role) != member.role)
          OsmMember(
            type: member.type,
            ref: member.ref,
            role: view.rules.reversedRole(member.role),
          )
        else
          member,
    ];
    for (var i = 0; i < members.length; i++) {
      if (!identical(members[i], relation.members[i])) changed = true;
    }
    if (changed) view.setRelationMembers(relation, members);
  }
  final nodes = way.nodeIds.reversed.toList();
  for (final id in nodes.toSet()) {
    final node = view.node(id);
    if (node == null || node.tags.isEmpty) continue;
    view.setTags(node, view.rules.reversed(node.tags, standalone: false));
  }
  view.setWayNodes(way, nodes);
  view.setTags(
    view.way(way.id) ?? way,
    view.rules.reversed(way.tags, standalone: false, oneway: oneway),
  );
}

/// Pulling a point out of what is selected.
class OsmExtractOperation extends OsmOperation<List<OsmNode>> {
  final OsmEditor _view;

  /// What points are to be pulled out of, as it now stands.
  @override
  final List<OsmElement> selected;

  /// Creates the operation.
  OsmExtractOperation(this._view, this.selected);

  bool _extractable(OsmElement element) => switch (element) {
        OsmNode() => _view.rules.isDescriptive(element.tags) &&
            _view.waysUsing(element.id).isNotEmpty,
        OsmWay() => _view.rules.extracted(element, _view) != null,
        OsmRelation() => false,
      };

  /// Whether it can be done: everything selected has a point in it to pull
  /// out.
  @override
  bool get available => selected.isNotEmpty && selected.every(_extractable);

  /// Pulls the points out, as one change, and gives back the points.
  ///
  /// A node that is part of lines and areas and says something of its own
  /// is taken out of them and left where it was, and an untagged node takes
  /// its place in them. What a line or an area is — a shop in a building, a
  /// cafe drawn as its outline — moves onto a new point in the middle of
  /// it, and what makes it the shape it is stays: a building keeps its
  /// building tags, anything keeps its address, and an area that would no
  /// longer be one is told it is.
  @override
  List<OsmNode> apply() {
    final points = <OsmNode>[];
    _view.group(() {
      for (final element in selected) {
        switch (element) {
          case OsmNode():
            points.add(_fromNode(element));
          case OsmWay():
            if (_fromWay(element) case final point?) points.add(point);
          case OsmRelation():
            break;
        }
      }
    });
    return points;
  }

  OsmNode _fromNode(OsmNode node) {
    final edits = _view;
    final replacement = edits.createNode(
      latitude: node.latitude,
      longitude: node.longitude,
    );
    for (final way in _view.waysUsing(node.id)) {
      edits.setWayNodes(way, [
        for (final id in way.nodeIds) id == node.id ? replacement.id : id,
      ]);
    }
    return _view.node(node.id) ?? node;
  }

  OsmNode? _fromWay(OsmWay way) {
    final geometry = _view.geometryOf(way);
    final extracted = _view.rules.extracted(way, _view);
    if (extracted == null) return null;
    final (:point, way: tags) = extracted;
    final (latitude, longitude) = _middleOf(way, geometry);
    final made = _view.createNode(
      latitude: latitude,
      longitude: longitude,
      tags: point,
    );
    _view.setTags(way, tags);
    return made;
  }

  /// The middle of [way]: the centre of the area it encloses, or the point
  /// half way along it by length. Worked out on the map, and
  /// the middle of its nodes if that comes to nothing.
  (double, double) _middleOf(OsmWay way, OsmGeometry geometry) {
    final xs = <double>[];
    final ys = <double>[];
    for (final id in way.nodeIds) {
      final node = _view.node(id);
      if (node == null) continue;
      // Each brought round beside the one before, so that a way across the
      // antimeridian is measured across it rather than round the world.
      final x = OsmMercator.x(node.longitude);
      xs.add(xs.isEmpty ? x : OsmMercator.nearest(x, xs.last));
      ys.add(OsmMercator.y(node.latitude));
    }
    if (xs.isEmpty) return (0, 0);

    double? x, y;
    if (geometry == OsmGeometry.area && xs.length >= 3) {
      // Worked out from the first corner rather than from the corner of the
      // world. A building is a few millionths of the world across, and the
      // products the area is made of, taken from half the world away, are
      // so much larger than it that most of it is lost in the rounding.
      final ox = xs.first, oy = ys.first;
      var twiceArea = 0.0, cx = 0.0, cy = 0.0;
      for (var i = 0; i < xs.length; i++) {
        final j = (i + 1) % xs.length;
        final xi = xs[i] - ox, yi = ys[i] - oy;
        final xj = xs[j] - ox, yj = ys[j] - oy;
        final cross = xi * yj - xj * yi;
        twiceArea += cross;
        cx += (xi + xj) * cross;
        cy += (yi + yj) * cross;
      }
      if (twiceArea != 0) {
        x = ox + cx / (3 * twiceArea);
        y = oy + cy / (3 * twiceArea);
      }
    } else if (xs.length >= 2) {
      var length = 0.0, cx = 0.0, cy = 0.0;
      for (var i = 0; i + 1 < xs.length; i++) {
        final dx = xs[i + 1] - xs[i], dy = ys[i + 1] - ys[i];
        final segment = math.sqrt(dx * dx + dy * dy);
        length += segment;
        cx += (xs[i] + xs[i + 1]) / 2 * segment;
        cy += (ys[i] + ys[i + 1]) / 2 * segment;
      }
      if (length > 0) {
        x = cx / length;
        y = cy / length;
      }
    }
    x ??= xs.reduce((a, b) => a + b) / xs.length;
    y ??= ys.reduce((a, b) => a + b) / ys.length;
    return (OsmMercator.latitude(y), OsmMercator.wrappedLongitude(x));
  }
}

/// The lines that selecting [selected] would continue drawing, or null if
/// the selection is not one a line is continued from.
///
/// One vertex has to be selected, and at most one line with it. The lines
/// are those not yet closed that start or stop at the vertex, and if a line
/// is selected, only that one: there has to be exactly one to continue, and
/// selecting the line is how one is chosen from several.
List<OsmWay>? osmContinuable(OsmEditor view, List<OsmElement> selected) {
  final vertices = [
    for (final element in selected)
      if (element is OsmNode && view.geometryOf(element) == OsmGeometry.vertex)
        element,
  ];
  if (vertices.length != 1) return null;
  final vertex = vertices.single;
  final lines = [
    for (final element in selected)
      if (element is OsmWay && view.geometryOf(element) == OsmGeometry.line)
        element,
  ];
  if (lines.length > 1) return null;
  return [
    for (final way in view.waysUsing(vertex.id))
      if (!way.isClosed &&
          (way.nodeIds.first == vertex.id || way.nodeIds.last == vertex.id) &&
          (lines.isEmpty || lines.single.id == way.id))
        way,
  ];
}

/// What was copied: the elements as they stood when they were, and the
/// nodes of any ways among them, to make new ones from however they have
/// changed since.
class OsmCopied {
  /// The elements copied, without the nodes of copied ways.
  final List<OsmElement> elements;

  /// Every node needed to copy them, by id: the nodes copied, and the nodes
  /// of the ways copied.
  final Map<int, OsmNode> nodes;

  /// Where on the map, in world coordinates, the copies are to be anchored:
  /// the point the pointer was at when they were copied, so that pasting
  /// puts them the same way round the pointer. Null to anchor them by
  /// [worldMiddle] instead.
  final (double, double)? worldAnchor;

  const OsmCopied._(this.elements, this.nodes, this.worldAnchor);

  /// How many things were copied.
  int get length => elements.length;

  /// The middle of what was copied, in world coordinates.
  (double, double) get worldMiddle {
    var left = double.infinity, top = double.infinity;
    var right = double.negativeInfinity, bottom = double.negativeInfinity;
    double? first;
    for (final node in nodes.values) {
      // All on the same side of the antimeridian as the first.
      final raw = OsmMercator.x(node.longitude);
      final x = first == null ? raw : OsmMercator.nearest(raw, first);
      first ??= x;
      final y = OsmMercator.y(node.latitude);
      left = math.min(left, x);
      right = math.max(right, x);
      top = math.min(top, y);
      bottom = math.max(bottom, y);
    }
    return ((left + right) / 2, (top + bottom) / 2);
  }
}

/// Copies [selected], or null if there is nothing in it to copy.
///
/// A node along a way that says nothing of its own is part of the way, not
/// something to copy on its own; a way is copied with its nodes. [anchor]
/// is where on the map, in world coordinates, the pointer was; a single
/// node needs none, being its own anchor.
OsmCopied? osmCopy(
  OsmEditor view,
  List<OsmElement> selected, {
  (double, double)? anchor,
}) {
  final chosen = [
    for (final element in selected)
      if (view.rules.isDescriptive(element.tags) ||
          view.geometryOf(element) != OsmGeometry.vertex)
        element,
  ];
  final elements = <OsmElement>[];
  final nodes = <int, OsmNode>{};
  for (final way in chosen.whereType<OsmWay>()) {
    final now = view.way(way.id);
    if (now == null) continue;
    elements.add(now);
    for (final id in now.nodeIds) {
      if (view.node(id) case final node?) nodes[id] = node;
    }
  }
  for (final node in chosen.whereType<OsmNode>()) {
    if (nodes.containsKey(node.id)) continue;
    final now = view.node(node.id);
    if (now == null) continue;
    elements.add(now);
    nodes[now.id] = now;
  }
  if (elements.isEmpty) return null;
  final single = elements.length == 1 && elements.single is OsmNode;
  return OsmCopied._(elements, nodes, single ? null : anchor);
}

/// Adds a copy of [copied] to [edits], [dx] and [dy] across the world from
/// where it was, as one change, and gives back the copies of what was
/// copied — not the nodes of copied ways, which come with them.
///
/// Everything is new: new nodes, new ways through them, and the same tags.
List<OsmElement> osmPaste(
  OsmEditor edits,
  OsmCopied copied, {
  required double dx,
  required double dy,
}) {
  final made = <OsmElement>[];
  edits.group(() {
    final newNodes = <int, OsmNode>{};
    OsmNode copyOf(int id) => newNodes[id] ??= () {
          final node = copied.nodes[id]!;
          return edits.createNode(
            latitude: OsmMercator.latitude(
              (OsmMercator.y(node.latitude) + dy).clamp(0.0, 1.0),
            ),
            longitude: OsmMercator.wrappedLongitude(
                OsmMercator.x(node.longitude) + dx),
            tags: node.tags,
          );
        }();
    for (final element in copied.elements) {
      switch (element) {
        case OsmNode():
          made.add(copyOf(element.id));
        case OsmWay():
          made.add(
            edits.createWay(
              nodeIds: [for (final id in element.nodeIds) copyOf(id).id],
              tags: element.tags,
            ),
          );
        case OsmRelation():
          break;
      }
    }
  });
  return made;
}

/// Moves [selected] [dx] and [dy] across the world, as one change: every
/// node selected, and every node of every way selected, once.
///
/// Ways joined to them but not selected stretch to follow.
void osmMove(
  OsmEditor view,
  List<OsmElement> selected, {
  required double dx,
  required double dy,
}) {
  final ids = <int>{
    for (final element in selected)
      ...switch (element) {
        OsmNode() => [element.id],
        OsmWay() => view.way(element.id)?.nodeIds ?? element.nodeIds,
        OsmRelation() => const <int>[],
      },
  };
  view.group(() {
    for (final id in ids) {
      final node = view.node(id);
      if (node == null) continue;
      view.moveNode(
        node,
        latitude: OsmMercator.latitude(
          (OsmMercator.y(node.latitude) + dy).clamp(0.0, 1.0),
        ),
        longitude:
            OsmMercator.wrappedLongitude(OsmMercator.x(node.longitude) + dx),
      );
    }
  });
}

/// Moving what is selected by a distance on the map.
class OsmMoveOperation extends OsmOperation<void> {
  final OsmEditor _view;

  /// What is to be moved, as it now stands: its nodes, and the nodes of its
  /// ways, each once.
  @override
  final List<OsmElement> selected;

  /// How far east it moves, in world coordinates, as [OsmMercator] gives
  /// them.
  final double worldDx;

  /// How far south it moves, in world coordinates.
  final double worldDy;

  /// Creates the operation.
  OsmMoveOperation(
    this._view,
    this.selected, {
    required this.worldDx,
    required this.worldDy,
  });

  /// Whether it can be done: anything can be moved.
  @override
  bool get available => selected.isNotEmpty;

  /// Moves it all, as one change.
  @override
  void apply() => osmMove(_view, selected, dx: worldDx, dy: worldDy);
}

/// Putting down a copy of what was copied, a distance from where it was.
class OsmPasteOperation extends OsmOperation<List<OsmElement>> {
  final OsmEditor _view;

  /// What was copied.
  final OsmCopied copied;

  /// How far east of the original the copy goes, in world coordinates.
  final double worldDx;

  /// How far south of the original the copy goes, in world coordinates.
  final double worldDy;

  /// Creates the operation.
  OsmPasteOperation(
    this._view,
    this.copied, {
    required this.worldDx,
    required this.worldDy,
  });

  /// Nothing: pasting adds to the map rather than doing something to what
  /// is on it.
  @override
  List<OsmElement> get selected => const [];

  /// Whether it can be done: there is something copied.
  @override
  bool get available => copied.length > 0;

  /// Puts the copy down, as one change, and gives back what was made.
  @override
  List<OsmElement> apply() => osmPaste(_view, copied, dx: worldDx, dy: worldDy);
}
