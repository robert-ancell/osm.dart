import 'dart:convert';
import 'dart:io';

import '../element.dart';
import 'exception.dart';
import 'reader.dart';

/// The two bytes every gzip stream starts with.
const List<int> _gzipMagic = [0x1f, 0x8b];

/// What a change does to an element.
enum OsmChangeAction {
  /// The element is new.
  create,

  /// The element is a new version of one that already existed.
  modify,

  /// The element is gone.
  delete,
}

/// One element's change in an OsmChange (`.osc`) file.
///
/// A replication diff is a list of these: what OpenStreetMap did to the map
/// in a minute, an hour or a day, in the order it was done.
class OsmChange {
  /// What the change does.
  final OsmChangeAction action;

  /// The kind of element changed.
  final OsmElementType type;

  /// The id of the element changed.
  final int id;

  /// The version the change makes, if the file says.
  final int? version;

  /// The element as the file describes it.
  ///
  /// Null only when the file does not give enough to build one, which in
  /// practice means a deleted node with no location on it. The id, type and
  /// version are there either way, which is all it takes to drop the element
  /// a delete is talking about.
  final OsmElement? element;

  /// Creates a change.
  const OsmChange({
    required this.action,
    required this.type,
    required this.id,
    this.version,
    this.element,
  });

  @override
  String toString() => 'OsmChange(${action.name} ${type.name} $id)';
}

/// An OsmChange file, holding what a replication diff did to the map.
///
/// ```dart
/// for (final change in await OsmChangeFile.read('523.osc.gz')) {
///   if (change.action == OsmChangeAction.delete) forget(change.type, change.id);
/// }
/// ```
///
/// The whole file is held in memory. A minute of the planet is a few hundred
/// kilobytes and a day of it tens of megabytes, which is what these are for;
/// anything larger wants the PBF reader.
abstract final class OsmChangeFile {
  /// Reads the changes in the file at [path], gzipped or not.
  static Future<List<OsmChange>> read(String path) async {
    final bytes = await File(path).readAsBytes();
    // Replication diffs are served gzipped and usually kept that way, so
    // which it is comes from the bytes rather than from the name.
    final decoded = bytes.length >= 2 &&
            bytes[0] == _gzipMagic[0] &&
            bytes[1] == _gzipMagic[1]
        ? gzip.decode(bytes)
        : bytes;
    return parse(utf8.decode(decoded));
  }

  /// Reads the changes in [xml].
  static List<OsmChange> parse(String xml) {
    final changes = <OsmChange>[];

    // What the reader is in the middle of: the action from the enclosing
    // create, modify or delete, and the element being built inside it.
    OsmChangeAction? action;
    OsmElementType? type;
    Map<String, String>? attributes;
    var tags = <String, String>{};
    var nodeIds = <int>[];
    var members = <OsmMember>[];

    void finish() {
      final open = attributes;
      if (open == null || type == null || action == null) return;
      changes.add(
        _change(
          action: action!,
          type: type!,
          attributes: open,
          tags: tags,
          nodeIds: nodeIds,
          members: members,
        ),
      );
      attributes = null;
      type = null;
      tags = <String, String>{};
      nodeIds = <int>[];
      members = <OsmMember>[];
    }

    readXml(
      xml,
      onOpen: (name, open) {
        switch (name) {
          case 'create':
            action = OsmChangeAction.create;
          case 'modify':
            action = OsmChangeAction.modify;
          case 'delete':
            action = OsmChangeAction.delete;
          case 'node' || 'way' || 'relation':
            finish();
            type = OsmElementType.values.byName(name);
            attributes = open;
          case 'tag':
            final key = open['k'], value = open['v'];
            if (key != null && value != null) tags[key] = value;
          case 'nd':
            final ref = int.tryParse(open['ref'] ?? '');
            if (ref != null) nodeIds.add(ref);
          case 'member':
            final ref = int.tryParse(open['ref'] ?? '');
            final kind = open['type'];
            if (ref == null || kind == null) break;
            if (!OsmElementType.values.any((t) => t.name == kind)) break;
            members.add(
              OsmMember(
                type: OsmElementType.values.byName(kind),
                ref: ref,
                role: open['role'] ?? '',
              ),
            );
        }
      },
      onClose: (name) {
        switch (name) {
          case 'node' || 'way' || 'relation':
            finish();
          case 'create' || 'modify' || 'delete':
            action = null;
        }
      },
    );

    return changes;
  }
}

OsmChange _change({
  required OsmChangeAction action,
  required OsmElementType type,
  required Map<String, String> attributes,
  required Map<String, String> tags,
  required List<int> nodeIds,
  required List<OsmMember> members,
}) {
  final id = int.tryParse(attributes['id'] ?? '');
  if (id == null) {
    throw OsmXmlException('A ${type.name} has no id');
  }
  final version = int.tryParse(attributes['version'] ?? '');
  final info = _info(attributes, version);
  final held = tags.isEmpty ? const <String, String>{} : tags;

  final element = switch (type) {
    OsmElementType.node => () {
        final latitude = double.tryParse(attributes['lat'] ?? '');
        final longitude = double.tryParse(attributes['lon'] ?? '');
        // A deleted node is often given without one, and there is nothing
        // honest to put in its place.
        if (latitude == null || longitude == null) return null;
        return OsmNode(
          id: id,
          latitude: latitude,
          longitude: longitude,
          tags: held,
          info: info,
        );
      }(),
    OsmElementType.way => OsmWay(
        id: id,
        nodeIds: nodeIds,
        tags: held,
        info: info,
      ),
    OsmElementType.relation => OsmRelation(
        id: id,
        members: members,
        tags: held,
        info: info,
      ),
  };

  return OsmChange(
    action: action,
    type: type,
    id: id,
    version: version,
    element: element,
  );
}

OsmInfo? _info(Map<String, String> attributes, int? version) {
  final timestamp = attributes['timestamp'];
  final user = attributes['user'];
  final info = OsmInfo(
    version: version,
    timestamp: timestamp == null ? null : DateTime.tryParse(timestamp)?.toUtc(),
    changeset: int.tryParse(attributes['changeset'] ?? ''),
    uid: int.tryParse(attributes['uid'] ?? ''),
    user: user == null || user.isEmpty ? null : user,
    // OsmChange says what happened with the enclosing tag, so an element
    // inside one is there whatever `visible` claims.
    visible: attributes['visible'] != 'false',
  );
  return info.version == null &&
          info.timestamp == null &&
          info.changeset == null &&
          info.uid == null &&
          info.user == null
      ? null
      : info;
}
