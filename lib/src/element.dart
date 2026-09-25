/// The three kinds of element that make up an OpenStreetMap dataset.
enum OsmElementType {
  /// A point, which carries a location.
  node,

  /// An ordered list of nodes, forming a line or an area.
  way,

  /// A group of elements, each with a role.
  relation,
}

/// The editing history of an element.
///
/// Present only in files written with metadata, which is the default for the
/// planet file and for regional extracts.
class OsmInfo {
  /// The version number of the element, incremented on every edit.
  final int? version;

  /// When the version was created, in UTC.
  final DateTime? timestamp;

  /// The changeset the version was created in.
  final int? changeset;

  /// The numeric id of the user that created the version.
  final int? uid;

  /// The display name of the user that created the version.
  final String? user;

  /// Whether the element still exists.
  ///
  /// Only files carrying history contain deleted elements, so this is true
  /// for every element of a snapshot.
  final bool visible;

  /// Creates editing history for an element.
  const OsmInfo({
    this.version,
    this.timestamp,
    this.changeset,
    this.uid,
    this.user,
    this.visible = true,
  });
}

/// An element of an OpenStreetMap dataset.
sealed class OsmElement {
  /// The id of the element, unique within its [type].
  final int id;

  /// The tags describing the element.
  final Map<String, String> tags;

  /// The editing history of the element, if the file carries metadata.
  final OsmInfo? info;

  const OsmElement({required this.id, required this.tags, this.info});

  /// The kind of element this is.
  OsmElementType get type;
}

/// A point in the dataset.
class OsmNode extends OsmElement {
  /// The latitude of the node in degrees.
  final double latitude;

  /// The longitude of the node in degrees.
  final double longitude;

  /// Creates a node at the given location.
  const OsmNode({
    required super.id,
    required this.latitude,
    required this.longitude,
    super.tags = const {},
    super.info,
  });

  @override
  OsmElementType get type => OsmElementType.node;

  @override
  String toString() => 'OsmNode($id, $latitude, $longitude)';
}

/// An ordered list of nodes, forming a line or an area.
class OsmWay extends OsmElement {
  /// The ids of the nodes making up the way, in order.
  ///
  /// A way is closed, and so encloses an area, when the first and last id are
  /// the same. Whether a closed way is an area or a loop depends on its tags.
  final List<int> nodeIds;

  /// Creates a way through the given nodes.
  const OsmWay({
    required super.id,
    required this.nodeIds,
    super.tags = const {},
    super.info,
  });

  /// Whether the way starts and ends at the same node.
  bool get isClosed => nodeIds.length > 1 && nodeIds.first == nodeIds.last;

  /// Whether the way has too few different nodes to be a way at all: fewer
  /// than two, or than three for a closed one. What is left of a way whose
  /// nodes have been taken away, which is deleted rather than kept.
  bool get isDegenerate => nodeIds.toSet().length < (isClosed ? 3 : 2);

  /// The nodes of this way without the node [id], as they are once it is taken
  /// out: every time the way ran through it, and any repeat that leaves.
  ///
  /// A way that is closed stays closed. The node a ring was drawn from is
  /// also the one it comes back to, so taking it out would leave the ring
  /// open, and the next node along closes it instead.
  List<int> withoutNode(int id) {
    final nodes = <int>[];
    for (final node in nodeIds) {
      if (node == id) continue;
      if (nodes.isNotEmpty && nodes.last == node) continue;
      nodes.add(node);
    }
    if (isClosed &&
        nodes.isNotEmpty &&
        (nodes.length == 1 || nodes.first != nodes.last)) {
      nodes.add(nodes.first);
    }
    return nodes;
  }

  @override
  OsmElementType get type => OsmElementType.way;

  @override
  String toString() => 'OsmWay($id, ${nodeIds.length} nodes)';
}

/// One element of a relation, and the part it plays in it.
class OsmMember {
  /// The kind of element referred to.
  final OsmElementType type;

  /// The id of the element referred to.
  final int ref;

  /// The part the element plays in the relation, which may be empty.
  final String role;

  /// Creates a member of a relation.
  const OsmMember({required this.type, required this.ref, required this.role});

  @override
  String toString() => 'OsmMember(${type.name} $ref, $role)';
}

/// A group of elements, each with a role.
class OsmRelation extends OsmElement {
  /// The members of the relation, in order.
  final List<OsmMember> members;

  /// Creates a relation over the given members.
  const OsmRelation({
    required super.id,
    required this.members,
    super.tags = const {},
    super.info,
  });

  @override
  OsmElementType get type => OsmElementType.relation;

  @override
  String toString() => 'OsmRelation($id, ${members.length} members)';
}
