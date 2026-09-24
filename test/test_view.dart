import 'package:osm/osm.dart';

/// Data as it was read, with the edits laid over it.
class TestView implements OsmEditView {
  @override
  final edits = OsmEdits();

  final Map<int, OsmNode> nodes;
  final Map<int, OsmWay> ways;
  final Map<int, OsmRelation> relations;

  TestView({
    required List<OsmNode> nodes,
    List<OsmWay> ways = const [],
    List<OsmRelation> relations = const [],
  })  : nodes = {for (final n in nodes) n.id: n},
        ways = {for (final w in ways) w.id: w},
        relations = {for (final r in relations) r.id: r};

  @override
  OsmNode? node(int id) => edits.isGone(OsmElementType.node, id)
      ? null
      : edits.changedNode(id) ?? nodes[id];

  @override
  OsmWay? way(int id) => edits.isGone(OsmElementType.way, id)
      ? null
      : edits.changedWay(id) ?? ways[id];

  @override
  OsmRelation? relation(int id) => edits.isGone(OsmElementType.relation, id)
      ? null
      : edits.changedRelation(id) ?? relations[id];

  Iterable<OsmWay> get _allWays => {
        ...ways.keys,
        ...edits.changedWays.keys,
      }.map(way).whereType<OsmWay>();

  Iterable<OsmRelation> get _allRelations => {
        ...relations.keys,
        ...edits.changedRelations.keys,
      }.map(relation).whereType<OsmRelation>();

  @override
  List<OsmWay> waysUsing(int nodeId) => [
        for (final way in _allWays)
          if (way.nodeIds.contains(nodeId)) way,
      ];

  @override
  List<OsmRelation> relationsUsing(OsmElementType type, int id) => [
        for (final relation in _allRelations)
          if (relation.members.any((m) => m.type == type && m.ref == id))
            relation,
      ];

  @override
  OsmGeometry geometryOf(OsmElement element) => switch (element) {
        OsmNode() => waysUsing(element.id).isEmpty
            ? OsmGeometry.point
            : OsmGeometry.vertex,
        OsmWay() => element.isClosed &&
                element.tags['area'] != 'no' &&
                (element.tags.containsKey('building') ||
                    element.tags['area'] == 'yes')
            ? OsmGeometry.area
            : OsmGeometry.line,
        OsmRelation() => OsmGeometry.relation,
      };
}

OsmNode testNode(int id, double latitude, double longitude,
        [Map<String, String> tags = const {}]) =>
    OsmNode(
      id: id,
      latitude: latitude,
      longitude: longitude,
      tags: tags,
      info: const OsmInfo(version: 1),
    );

OsmWay testWay(int id, List<int> nodes,
        [Map<String, String> tags = const {}]) =>
    OsmWay(id: id, nodeIds: nodes, tags: tags, info: const OsmInfo(version: 1));
