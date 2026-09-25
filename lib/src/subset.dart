import 'area.dart';
import 'element_source.dart';
import 'element.dart';

/// The elements taken out of a file, and everything they refer to.
///
/// A way names its nodes by id and a relation names its members by id, so a
/// matching element on its own is not enough to build geometry from. A subset
/// carries the elements the matches point at as well, indexed by id, so
/// [nodesOf] and [memberOf] can resolve them.
///
/// It is [OsmElementSource] too, so what was read can be edited as it is:
/// `OsmEditor(subset)`.
class OsmSubset implements OsmElementSource {
  /// The elements that matched the filter, in the order they were stored.
  final List<OsmElement> matches;

  /// Every node held, by id, whether it matched or was referred to.
  final Map<int, OsmNode> nodes;

  /// Every way held, by id, whether it matched or was referred to.
  final Map<int, OsmWay> ways;

  /// Every relation held, by id, whether it matched or was referred to.
  final Map<int, OsmRelation> relations;

  /// Creates a subset. Normally made by reading a file.
  const OsmSubset({
    required this.matches,
    required this.nodes,
    required this.ways,
    required this.relations,
  });

  /// The number of elements held.
  int get length => nodes.length + ways.length + relations.length;

  /// The element of [type] with [id], or null if the subset does not hold it.
  OsmElement? element(OsmElementType type, int id) => switch (type) {
        OsmElementType.node => nodes[id],
        OsmElementType.way => ways[id],
        OsmElementType.relation => relations[id],
      };

  @override
  OsmNode? node(int id) => nodes[id];

  @override
  OsmWay? way(int id) => ways[id];

  @override
  OsmRelation? relation(int id) => relations[id];

  @override
  Iterable<int> waysUsing(int nodeId) =>
      _indexes[this].waysUsing[nodeId] ?? const [];

  @override
  Iterable<int> relationsUsing(OsmElementType type, int id) =>
      _indexes[this].relationsUsing[(type, id)] ?? const [];

  /// The element a relation member refers to, or null if it is not held.
  OsmElement? memberOf(OsmMember member) => element(member.type, member.ref);

  /// The nodes of [way], in order, or null if any of them is missing.
  ///
  /// Missing nodes mean the way runs off the edge of the file, which happens
  /// to any way crossing the boundary of an extract. Returning null rather
  /// than a short list keeps torn geometry from being drawn as if it were
  /// whole.
  List<OsmNode>? nodesOf(OsmWay way) {
    final located = <OsmNode>[];
    for (final id in way.nodeIds) {
      final node = nodes[id];
      if (node == null) return null;
      located.add(node);
    }
    return located;
  }

  /// The area [element] covers, or null if it does not cover one.
  ///
  /// A closed way, or a relation whose member ways make up rings. Everything
  /// it needs is looked up here, so a relation whose members were not read
  /// comes back as null rather than as a torn outline.
  OsmArea? areaOf(OsmElement element) => assembleArea(
        element,
        node: (id) => nodes[id],
        way: (id) => ways[id],
      );

  @override
  String toString() =>
      'OsmSubset(${matches.length} matched, ${nodes.length} nodes, '
      '${ways.length} ways, ${relations.length} relations)';
}

/// Which ways run through each node, and which relations list each element,
/// worked out the first time a subset is asked and kept beside it: a subset
/// is made const, so it cannot keep them itself.
final _indexes = _Indexes();

class _Indexes {
  final _held = Expando<_Index>();

  _Index operator [](OsmSubset subset) => _held[subset] ??= _Index(subset);
}

class _Index {
  final waysUsing = <int, List<int>>{};
  final relationsUsing = <(OsmElementType, int), List<int>>{};

  _Index(OsmSubset subset) {
    for (final way in subset.ways.values) {
      for (final node in way.nodeIds.toSet()) {
        (waysUsing[node] ??= []).add(way.id);
      }
    }
    for (final relation in subset.relations.values) {
      for (final member in relation.members) {
        (relationsUsing[(member.type, member.ref)] ??= []).add(relation.id);
      }
    }
  }
}
