import 'dart:convert';
import 'dart:io';

import '../element.dart';
import 'elements.dart';

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
    readOsmXmlElements(xml, (read) {
      // Only what sits in a create, modify or delete is a change.
      final action = switch (read.action) {
        'create' => OsmChangeAction.create,
        'modify' => OsmChangeAction.modify,
        'delete' => OsmChangeAction.delete,
        _ => null,
      };
      if (action == null) return;
      changes.add(
        OsmChange(
          action: action,
          type: read.type,
          id: read.id,
          version: read.version,
          element: read.element,
        ),
      );
    });
    return changes;
  }
}
