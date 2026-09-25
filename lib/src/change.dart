import 'element.dart';

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
