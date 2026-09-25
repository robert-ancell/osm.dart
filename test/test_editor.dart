import 'package:osm/editor.dart';
import 'package:osm/osm.dart';

/// An editor over [nodes], [ways] and [relations], as they were read.
OsmEditor testEditor({
  required List<OsmNode> nodes,
  List<OsmWay> ways = const [],
  List<OsmRelation> relations = const [],
}) =>
    OsmEditor(
      OsmElementSource.of([...nodes, ...ways, ...relations]),
      rules: OsmStandardTagRules(),
    );

/// An editor over [read], by default nothing at all.
OsmEditor editorOf([Iterable<OsmElement> read = const []]) =>
    OsmEditor(OsmElementSource.of(read), rules: OsmStandardTagRules());

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

/// A line for each element of [upload], in the order they would be sent.
List<String> describeUpload(OsmUpload upload) => [
      for (final node in upload.createdNodes) 'Create node ${_name(node.id)}',
      for (final way in upload.createdWays)
        'Create way ${_name(way.id)} through ${way.nodeIds.length} node(s)',
      for (final relation in upload.createdRelations)
        'Create relation ${_name(relation.id)} of '
            '${relation.members.length} member(s)',
      // Changed rather than moved or retagged: what is sent is the element
      // as it now stands, which says nothing of what it was.
      for (final node in upload.changedNodes) 'Change node/${node.id}',
      for (final way in upload.changedWays) 'Change way/${way.id}',
      for (final relation in upload.changedRelations)
        'Change relation/${relation.id}',
      for (final relation in upload.deletedRelations)
        'Delete relation/${relation.id}',
      for (final way in upload.deletedWays) 'Delete way/${way.id}',
      for (final node in upload.deletedNodes) 'Delete node/${node.id}',
    ];

/// What to call an element that has no id of its own yet.
String _name(int id) => id < 0 ? 'new ($id)' : '$id';
