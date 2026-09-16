import '../element.dart';
import '../xml/change.dart';
import 'snapshot_index.dart';

/// What a set of changes did at the edge of a snapshot, where deciding what
/// is inside needs more than the changes can say.
class OsmUpdateEdges {
  /// Nodes that stood outside and were moved in. A way outside that uses one
  /// and was not itself changed is not in the changes at all, so it is
  /// missing from the snapshot until something looks it up.
  final Set<int> movedInNodes = {};

  /// Ways that were outside and were changed to use a node inside.
  final Set<int> movedInWays = {};

  /// Nodes the snapshot held that were moved outside it. Kept, because ways
  /// inside may still use them.
  final Set<int> movedOutNodes = {};

  /// Ways the snapshot held that were changed to use no node inside.
  final Set<int> movedOutWays = {};

  /// Ways kept that use nodes the snapshot does not hold and no change
  /// supplied: a way reaching out past the edge.
  final Set<int> incompleteWays = {};

  /// The nodes those ways are missing.
  final Set<int> missingNodes = {};

  /// Whether anything happened that the changes alone could not settle.
  bool get isEmpty =>
      movedInNodes.isEmpty &&
      movedInWays.isEmpty &&
      movedOutNodes.isEmpty &&
      movedOutWays.isEmpty &&
      missingNodes.isEmpty;

  @override
  String toString() => 'OsmUpdateEdges(${movedInNodes.length} nodes and '
      '${movedInWays.length} ways moved in, ${movedOutNodes.length} nodes and '
      '${movedOutWays.length} ways moved out, ${incompleteWays.length} ways '
      'missing ${missingNodes.length} nodes)';
}

/// Keeps the changes that touch a snapshot and drops the rest.
///
/// Changes go in one diff at a time, oldest first, and are decided in the
/// order they would be applied, so that a way created in the same diff as its
/// nodes sees them. Within a diff, nodes are decided before ways and ways
/// before relations for the same reason.
///
/// * A node is kept if it stands inside the snapshot's region, or if the
///   snapshot holds it: a node moved out may still be used by a way inside.
/// * A way is kept if the snapshot holds it or it uses a node that is held.
/// * A relation is kept if the snapshot holds it or it has a member that is
///   held. Its other members are not looked for, the same as a snapshot cut
///   with `complete_ways`.
/// * A delete is kept if the snapshot holds what it deletes.
///
/// What cannot be settled from the changes is gathered in [edges].
class OsmChangeFilter {
  /// What the snapshot holds.
  final OsmSnapshotIndex index;

  /// The changes kept, in the order they were given.
  final List<OsmChange> kept = [];

  final OsmUpdateEdges _moves = OsmUpdateEdges();

  /// The newest kept change to each way, which is the only one whose nodes
  /// matter once every diff is read. An hour can hold several versions of a
  /// way, and the older ones use nodes the same hour went on to delete.
  final Map<int, OsmChange> _newestWays = {};

  // What the changes so far have done to what the snapshot holds.
  final Set<int> _addedNodes = {};
  final Set<int> _removedNodes = {};
  final Set<int> _addedWays = {};
  final Set<int> _removedWays = {};
  final Set<int> _addedRelations = {};
  final Set<int> _removedRelations = {};

  /// How many changes have been looked at.
  int seen = 0;

  /// Creates a filter for the snapshot [index] describes.
  OsmChangeFilter(this.index);

  bool _holdsNode(int id) =>
      _addedNodes.contains(id) ||
      (index.nodes.contains(id) && !_removedNodes.contains(id));

  bool _holdsWay(int id) =>
      _addedWays.contains(id) ||
      (index.ways.contains(id) && !_removedWays.contains(id));

  bool _holdsRelation(int id) =>
      _addedRelations.contains(id) ||
      (index.relations.contains(id) && !_removedRelations.contains(id));

  bool _holds(OsmElementType type, int id) => switch (type) {
        OsmElementType.node => _holdsNode(id),
        OsmElementType.way => _holdsWay(id),
        OsmElementType.relation => _holdsRelation(id),
      };

  /// What happened at the edge of the snapshot, judged on the changes read
  /// so far.
  ///
  /// Which nodes a way is missing is worked out from each way's newest
  /// version against what is held after every change, not as the changes go
  /// by, so a node supplied or a way changed later settles it.
  OsmUpdateEdges get edges {
    final edges = OsmUpdateEdges()
      ..movedInNodes.addAll(_moves.movedInNodes)
      ..movedInWays.addAll(_moves.movedInWays)
      ..movedOutNodes.addAll(_moves.movedOutNodes)
      ..movedOutWays.addAll(_moves.movedOutWays);
    for (final change in _newestWays.values) {
      final way = change.element;
      if (change.action == OsmChangeAction.delete || way is! OsmWay) continue;
      final missing = way.nodeIds.where((node) => !_holdsNode(node));
      if (missing.isEmpty) continue;
      edges.incompleteWays.add(way.id);
      edges.missingNodes.addAll(missing);
    }
    return edges;
  }

  /// Decides the changes of one diff.
  void addAll(Iterable<OsmChange> changes) {
    final byType = {
      for (final type in OsmElementType.values) type: <OsmChange>[],
    };
    for (final change in changes) {
      byType[change.type]!.add(change);
    }
    for (final type in OsmElementType.values) {
      for (final change in byType[type]!) {
        seen++;
        if (_keep(change)) kept.add(change);
      }
    }
  }

  bool _keep(OsmChange change) {
    final held = _holds(change.type, change.id);
    final element = change.element;

    if (change.action == OsmChangeAction.delete || element == null) {
      if (held) {
        _forget(change.type, change.id);
        if (change.type == OsmElementType.way) _noteWay(change);
      }
      return held;
    }

    switch (element) {
      case OsmNode(:final id, :final latitude, :final longitude):
        if (index.region.contains(latitude, longitude)) {
          if (!held && change.action == OsmChangeAction.modify) {
            _moves.movedInNodes.add(id);
          }
          _addedNodes.add(id);
          _removedNodes.remove(id);
          return true;
        }
        if (held) _moves.movedOutNodes.add(id);
        return held;

      case OsmWay(:final id, :final nodeIds):
        final touches = nodeIds.any(_holdsNode);
        if (!touches) {
          if (held) {
            _moves.movedOutWays.add(id);
            _noteWay(change);
          }
          return held;
        }
        if (!held && change.action == OsmChangeAction.modify) {
          _moves.movedInWays.add(id);
        }
        _addedWays.add(id);
        _removedWays.remove(id);
        _noteWay(change);
        return true;

      case OsmRelation(:final id, :final members):
        if (held || members.any((member) => _holds(member.type, member.ref))) {
          _addedRelations.add(id);
          _removedRelations.remove(id);
          return true;
        }
        return false;
    }
  }

  void _noteWay(OsmChange change) {
    final held = _newestWays[change.id];
    final version = change.version, heldVersion = held?.version;
    if (held != null &&
        version != null &&
        heldVersion != null &&
        version < heldVersion) {
      return;
    }
    _newestWays[change.id] = change;
  }

  void _forget(OsmElementType type, int id) {
    switch (type) {
      case OsmElementType.node:
        _removedNodes.add(id);
        _addedNodes.remove(id);
      case OsmElementType.way:
        _removedWays.add(id);
        _addedWays.remove(id);
      case OsmElementType.relation:
        _removedRelations.add(id);
        _addedRelations.remove(id);
    }
  }
}
