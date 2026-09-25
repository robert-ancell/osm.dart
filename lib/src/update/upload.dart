/// What an upload sends back to OpenStreetMap, which [OsmApiClient.upload]
/// sends.
///
/// Reads can be JSON, but writes have to be XML: `changeset/create` and
/// `changeset/upload` accept nothing else. Building it is a page of
/// string-writing rather than a dependency.
///
/// **There is no useful sandbox.** api06.dev.openstreetmap.org keeps its own
/// database rather than a copy of the real one, so the ways an editor is
/// looking at are not there to be modified. What stands in for one is the
/// list of changes: nothing is sent until somebody has read what would
/// change and asked for it to go.
library;

import '../edit.dart';
import '../exception.dart';
import '../element.dart';

/// Thrown when edits cannot be uploaded to OpenStreetMap: there is nothing
/// to send or no comment to send it with, or OpenStreetMap would not take
/// them, in which case [message] is what it said.
class OsmUploadException implements OsmException {
  /// What went wrong, in a sentence somebody can act on.
  @override
  final String message;

  /// The HTTP status, where there was one.
  ///
  /// 409 is the interesting one: somebody else changed an element while this
  /// was open, and what is held is a version behind.
  final int? status;

  /// Creates the exception.
  const OsmUploadException(this.message, {this.status});

  @override
  String toString() => status == null ? message : '$message (HTTP $status)';
}

/// What an upload would send, gathered out of a set of edits.
///
/// Made once and shown before it is sent: the list somebody reads and the
/// document that goes are built from the same thing, so what was agreed to
/// is what happens.
class OsmUpload {
  /// Nodes that were not on the map before.
  final List<OsmNode> createdNodes;

  /// Nodes that were, and have been moved or given other tags.
  final List<OsmNode> changedNodes;

  /// Nodes taken off the map, as they were.
  final List<OsmNode> deletedNodes;

  /// Ways that were not on the map before.
  final List<OsmWay> createdWays;

  /// Ways that were, and now run through other nodes or have other tags.
  final List<OsmWay> changedWays;

  /// Ways taken off the map, as they were.
  final List<OsmWay> deletedWays;

  /// Relations that were not on the map before.
  final List<OsmRelation> createdRelations;

  /// Relations whose members have changed.
  final List<OsmRelation> changedRelations;

  /// Relations taken off the map, as they were.
  final List<OsmRelation> deletedRelations;

  /// Gathers what [edits] would send.
  factory OsmUpload.of(OsmEditHistory edits) {
    final nodes = edits.changedNodes;
    final ways = edits.changedWays;
    return OsmUpload._(
      // A negative id is something made here that OpenStreetMap has never
      // seen; anything else is an element that was read and changed.
      createdNodes: [
        for (final node in nodes.values)
          if (node.id < 0) node,
      ],
      changedNodes: [
        for (final node in nodes.values)
          if (node.id > 0) node,
      ],
      deletedNodes: edits.deletedNodes.values.toList(),
      createdWays: [
        for (final way in ways.values)
          if (way.id < 0) way,
      ],
      changedWays: [
        for (final way in ways.values)
          if (way.id > 0) way,
      ],
      deletedWays: edits.deletedWays.values.toList(),
      createdRelations: [
        for (final relation in edits.changedRelations.values)
          if (relation.id < 0) relation,
      ],
      changedRelations: [
        for (final relation in edits.changedRelations.values)
          if (relation.id > 0 &&
              !edits.isGone(OsmElementType.relation, relation.id))
            relation,
      ],
      deletedRelations: edits.deletedRelations.values.toList(),
    );
  }

  const OsmUpload._({
    required this.createdNodes,
    required this.changedNodes,
    required this.deletedNodes,
    required this.createdWays,
    required this.changedWays,
    required this.deletedWays,
    required this.createdRelations,
    required this.changedRelations,
    required this.deletedRelations,
  });

  /// How many elements would be written.
  int get length =>
      createdNodes.length +
      changedNodes.length +
      deletedNodes.length +
      createdWays.length +
      changedWays.length +
      deletedWays.length +
      createdRelations.length +
      changedRelations.length +
      deletedRelations.length;

  /// Whether there is nothing to send.
  bool get isEmpty => length == 0;

  /// Whether there is.
  bool get isNotEmpty => length != 0;

  /// A line for each element, in the order they would be sent.
  ///
  /// For showing before the button is pressed. Short on purpose: what
  /// matters to whoever is reading is how many of what, and which ones, not
  /// the XML.
  List<String> describe() => [
        for (final node in createdNodes) 'Create node ${_name(node.id)}',
        for (final way in createdWays)
          'Create way ${_name(way.id)} through ${way.nodeIds.length} node(s)',
        for (final relation in createdRelations)
          'Create relation ${_name(relation.id)} of '
              '${relation.members.length} member(s)',
        // Changed rather than moved or retagged: what is sent is the element
        // as it now stands, which says nothing of what it was.
        for (final node in changedNodes) 'Change node/${node.id}',
        for (final way in changedWays) 'Change way/${way.id}',
        for (final relation in changedRelations)
          'Change relation/${relation.id}',
        for (final relation in deletedRelations)
          'Delete relation/${relation.id}',
        for (final way in deletedWays) 'Delete way/${way.id}',
        for (final node in deletedNodes) 'Delete node/${node.id}',
      ];

  /// What to call an element that has no id of its own yet.
  static String _name(int id) => id < 0 ? 'new ($id)' : '$id';

  /// The osmChange document that makes these changes in [changeset].
  ///
  /// Every element in full: OpenStreetMap replaces an element rather than
  /// patching one, so a way sent without its nodes is a way emptied and a
  /// tag left out is a tag deleted. Both are why the edits keep whole
  /// elements rather than the parts that changed.
  ///
  /// Order matters. Everything is created before anything refers to it, and
  /// nothing is deleted until every way that ran through it has been written
  /// without it.
  String toXml({required int changeset, required String generator}) {
    final out = StringBuffer()
      ..writeln(
        '<osmChange version="0.6" generator="${_escaped(generator)}">',
      );

    if (createdNodes.isNotEmpty ||
        createdWays.isNotEmpty ||
        createdRelations.isNotEmpty) {
      out.writeln('  <create>');
      for (final node in createdNodes) {
        _node(out, node, changeset: changeset, version: 0);
      }
      for (final way in createdWays) {
        _way(out, way, changeset: changeset, version: 0);
      }
      for (final relation in createdRelations) {
        _relation(out, relation, changeset: changeset, version: 0);
      }
      out.writeln('  </create>');
    }

    if (changedNodes.isNotEmpty ||
        changedWays.isNotEmpty ||
        changedRelations.isNotEmpty) {
      out.writeln('  <modify>');
      for (final node in changedNodes) {
        _node(out, node, changeset: changeset);
      }
      for (final way in changedWays) {
        _way(out, way, changeset: changeset);
      }
      for (final relation in changedRelations) {
        _relation(out, relation, changeset: changeset);
      }
      out.writeln('  </modify>');
    }

    if (deletedRelations.isNotEmpty ||
        deletedWays.isNotEmpty ||
        deletedNodes.isNotEmpty) {
      // Deletions last: relations, then ways, then nodes. Something is only
      // free to go once everything that referred to it — a way through a
      // node, a relation listing a way — has been written without it or is
      // gone itself, which is exactly the order these are in.
      out.writeln('  <delete>');
      for (final relation in deletedRelations) {
        _relation(out, relation, changeset: changeset);
      }
      for (final way in deletedWays) {
        _way(out, way, changeset: changeset);
      }
      for (final node in deletedNodes) {
        _node(out, node, changeset: changeset);
      }
      out.writeln('  </delete>');
    }

    out.writeln('</osmChange>');
    return out.toString();
  }

  static void _node(
    StringBuffer out,
    OsmNode node, {
    required int changeset,
    int? version,
  }) {
    final at = 'lat="${node.latitude}" lon="${node.longitude}" '
        'version="${version ?? _versionOf(node)}" changeset="$changeset"';
    if (node.tags.isEmpty) {
      out.writeln('    <node id="${node.id}" $at/>');
      return;
    }
    out.writeln('    <node id="${node.id}" $at>');
    _tags(out, node.tags);
    out.writeln('    </node>');
  }

  static void _way(
    StringBuffer out,
    OsmWay way, {
    required int changeset,
    int? version,
  }) {
    out.writeln(
      '    <way id="${way.id}" version="${version ?? _versionOf(way)}" '
      'changeset="$changeset">',
    );
    for (final id in way.nodeIds) {
      out.writeln('      <nd ref="$id"/>');
    }
    _tags(out, way.tags);
    out.writeln('    </way>');
  }

  static void _relation(
    StringBuffer out,
    OsmRelation relation, {
    required int changeset,
    int? version,
  }) {
    out.writeln(
      '    <relation id="${relation.id}" '
      'version="${version ?? _versionOf(relation)}" changeset="$changeset">',
    );
    for (final member in relation.members) {
      out.writeln(
        '      <member type="${member.type.name}" ref="${member.ref}" '
        'role="${_escaped(member.role)}"/>',
      );
    }
    _tags(out, relation.tags);
    out.writeln('    </relation>');
  }

  static void _tags(StringBuffer out, Map<String, String> tags) {
    for (final key in tags.keys.toList()..sort()) {
      out.writeln('      ${changesetTagXml(key, tags[key]!)}');
    }
  }

  /// The version an element is being changed from.
  ///
  /// OpenStreetMap refuses a change that does not name the version it was
  /// made against, which is how it catches two people editing the same thing
  /// at once. An element read without one cannot be written back.
  static int _versionOf(OsmElement element) {
    final version = element.info?.version;
    if (version == null) {
      throw OsmUploadException(
        '${element.type.name}/${element.id} was read without a version, so '
        'it cannot be written back.',
      );
    }
    return version;
  }
}

/// A changeset tag written as XML.
String changesetTagXml(String key, String value) =>
    '<tag k="${_escaped(key)}" v="${_escaped(value)}"/>';

/// XML's five, which a name like "Bill & Ben" needs and a number never will.
String _escaped(String raw) => raw
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');
