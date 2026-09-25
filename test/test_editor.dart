import 'package:osm/osm.dart';

/// An editor over [nodes], [ways] and [relations], as they were read.
OsmEditor testEditor({
  required List<OsmNode> nodes,
  List<OsmWay> ways = const [],
  List<OsmRelation> relations = const [],
}) =>
    OsmEditor(OsmEditorData.of([...nodes, ...ways, ...relations]));

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
