import 'element_source.dart';
import 'element.dart';
import 'operations.dart';
import 'tag_rules.dart';
import 'topology.dart';
import 'update/upload.dart';

part 'editor.dart';

/// One change made to a dataset.
///
/// Holds what the element was as well as what it became, so that undoing is
/// a matter of putting the old one back rather than of working out what the
/// old one must have been.
sealed class OsmEdit {
  const OsmEdit();
}

/// A change to one element, and whatever that took with it.
sealed class OsmElementEdit extends OsmEdit {
  const OsmElementEdit();

  /// The kind of element changed.
  OsmElementType get type;

  /// The id of the element changed.
  int get id;
}

/// A node that was not there before.
class OsmNodeCreated extends OsmElementEdit {
  /// The node made.
  final OsmNode node;

  /// Creates a record of a new node.
  const OsmNodeCreated._(this.node);

  @override
  OsmElementType get type => OsmElementType.node;

  @override
  int get id => node.id;

  @override
  String toString() => 'OsmNodeCreated($id)';
}

/// A node taken off the map.
class OsmNodeDeleted extends OsmElementEdit {
  /// The node as it was.
  final OsmNode node;

  /// What it being gone did to the ways that ran through it.
  ///
  /// Part of the same change: a way cannot run through something that is not
  /// there, so putting the node back has to put the ways back with it.
  final List<OsmWayNodesChanged> ways;

  /// What it being gone did to the relations it was a member of.
  ///
  /// Part of the same change for the same reason: OpenStreetMap will not
  /// delete something a relation still lists.
  final List<OsmRelationChanged> relations;

  /// Whether [node] is the node as it was read, rather than as an earlier
  /// change left it. Undoing back to what was read means holding nothing.
  final bool _wasRead;

  /// Creates a record of a deletion.
  const OsmNodeDeleted._(
    this.node, {
    this.ways = const [],
    this.relations = const [],
    bool wasRead = false,
  }) : _wasRead = wasRead;

  @override
  OsmElementType get type => OsmElementType.node;

  @override
  int get id => node.id;

  @override
  String toString() => 'OsmNodeDeleted($id)';
}

/// A way that was not there before.
class OsmWayCreated extends OsmElementEdit {
  /// The way made.
  final OsmWay way;

  /// Creates a record of a new way.
  const OsmWayCreated._(this.way);

  @override
  OsmElementType get type => OsmElementType.way;

  @override
  int get id => way.id;

  @override
  String toString() => 'OsmWayCreated($id)';
}

/// A way taken off the map.
///
/// Only the way: whichever of its nodes go with it are deletions of their
/// own, gathered into the same change by whoever deleted it.
class OsmWayDeleted extends OsmElementEdit {
  /// The way as it was.
  final OsmWay way;

  /// What it being gone did to the relations it was a member of.
  final List<OsmRelationChanged> relations;

  /// Whether [way] is the way as it was read, rather than as an earlier
  /// change left it. Undoing back to what was read means holding nothing.
  final bool _wasRead;

  /// Creates a record of a deletion.
  const OsmWayDeleted._(
    this.way, {
    this.relations = const [],
    bool wasRead = false,
  }) : _wasRead = wasRead;

  @override
  OsmElementType get type => OsmElementType.way;

  @override
  int get id => way.id;

  @override
  String toString() => 'OsmWayDeleted($id)';
}

/// A relation that was not there before.
class OsmRelationCreated extends OsmElementEdit {
  /// The relation made.
  final OsmRelation relation;

  /// Creates a record of a new relation.
  const OsmRelationCreated._(this.relation);

  @override
  OsmElementType get type => OsmElementType.relation;

  @override
  int get id => relation.id;

  @override
  String toString() => 'OsmRelationCreated($id)';
}

/// A relation taken off the map.
class OsmRelationDeleted extends OsmElementEdit {
  /// The relation as it was.
  final OsmRelation relation;

  /// What it being gone did to the relations it was a member of.
  final List<OsmRelationChanged> relations;

  /// Whether [relation] is the relation as it was read, rather than as an
  /// earlier change left it. Undoing back to what was read means holding
  /// nothing.
  final bool _wasRead;

  /// Creates a record of a deletion.
  const OsmRelationDeleted._(
    this.relation, {
    this.relations = const [],
    bool wasRead = false,
  }) : _wasRead = wasRead;

  @override
  OsmElementType get type => OsmElementType.relation;

  @override
  int get id => relation.id;

  @override
  String toString() => 'OsmRelationDeleted($id)';
}

/// The members of a relation, changed.
class OsmRelationChanged extends OsmElementEdit {
  /// The relation as it was.
  final OsmRelation from;

  /// The relation as it is now.
  final OsmRelation to;

  /// Whether [from] is the relation as it was read, rather than as an
  /// earlier change left it. Undoing back to what was read means holding
  /// nothing.
  final bool _wasRead;

  /// Creates a record of a change to a relation's members.
  const OsmRelationChanged._({
    required this.from,
    required this.to,
    bool wasRead = false,
  }) : _wasRead = wasRead;

  @override
  OsmElementType get type => OsmElementType.relation;

  @override
  int get id => from.id;

  @override
  String toString() => 'OsmRelationChanged($id)';
}

/// The nodes a way runs through, changed.
class OsmWayNodesChanged extends OsmElementEdit {
  /// The way as it was.
  final OsmWay from;

  /// The way as it is now.
  final OsmWay to;

  /// Whether [from] is the way as it was read, rather than an earlier
  /// change to it. Undoing back to what was read means holding nothing.
  final bool _wasRead;

  /// Creates a record of a change to a way's nodes.
  const OsmWayNodesChanged._({
    required this.from,
    required this.to,
    bool wasRead = false,
  }) : _wasRead = wasRead;

  @override
  OsmElementType get type => OsmElementType.way;

  @override
  int get id => from.id;

  @override
  String toString() => 'OsmWayNodesChanged($id)';
}

/// Several changes that are one change to whoever made them.
///
/// Drawing a line is a node at a time and a way at the end of it, which is
/// one thing done and should be one thing undone. While it is still being
/// drawn its points come back one at a time; once it is finished it is a
/// line, and a line is what is put back.
class OsmEditGroup extends OsmEdit {
  /// What was done, in the order it was done.
  final List<OsmEdit> edits;

  const OsmEditGroup._(this.edits);

  @override
  String toString() => 'OsmEditGroup(${edits.length})';
}

/// A node moved to somewhere else.
class OsmNodeMoved extends OsmElementEdit {
  /// Where it was.
  final OsmNode from;

  /// Where it is now.
  final OsmNode to;

  /// Whether [from] is the node as it was read, rather than as an earlier
  /// change left it. Undoing back to what was read means holding nothing.
  final bool _wasRead;

  /// Creates a record of a move.
  const OsmNodeMoved._({
    required this.from,
    required this.to,
    bool wasRead = false,
  }) : _wasRead = wasRead;

  @override
  OsmElementType get type => OsmElementType.node;

  @override
  int get id => from.id;

  @override
  String toString() => 'OsmNodeMoved($id)';
}

/// The tags of a node or a way, changed.
class OsmTagsChanged extends OsmElementEdit {
  /// The element as it was.
  final OsmElement from;

  /// The element as it is now: the same but for its tags.
  final OsmElement to;

  /// Whether [from] is the element as it was read, rather than as an earlier
  /// change left it. Undoing back to what was read means holding nothing.
  final bool _wasRead;

  /// Creates a record of a change to an element's tags.
  const OsmTagsChanged._({
    required this.from,
    required this.to,
    bool wasRead = false,
  }) : _wasRead = wasRead;

  @override
  OsmElementType get type => from.type;

  @override
  int get id => from.id;

  @override
  String toString() => 'OsmTagsChanged(${type.name}/$id)';
}

/// Changes made to a dataset, in the order they were made.
///
/// Nothing here touches what was read. Whatever holds the elements keeps them
/// exactly as OpenStreetMap sent them, and what has been changed is laid over
/// the top: an element is looked for here first and in the dataset only if it
/// has not been touched.
///
/// Every change holds what it replaced, so undoing one puts exactly that
/// back — or, where it replaced what was read, holds nothing again. Nothing
/// has to be worked out from what came before it, which is what keeps undo
/// right however moves, tag changes and deletions of the same element are
/// interleaved, and however they are grouped.
class OsmEditHistory {
  final _done = <OsmEdit>[];

  /// What has been undone, the last undone last, for redoing.
  final _undone = <OsmEdit>[];
  final _nodes = <int, OsmNode>{};
  final _ways = <int, OsmWay>{};
  final _gone = <(OsmElementType, int)>{};

  /// The nodes taken off the map, as they were read.
  ///
  /// Kept because an upload has to name the version it is deleting, which is
  /// only in the element itself.
  final _deleted = <int, OsmNode>{};

  /// The ways taken off the map, as they were read, for the same reason.
  final _deletedWays = <int, OsmWay>{};

  /// The relations whose members have been changed.
  final _relations = <int, OsmRelation>{};

  /// The relations taken off the map, as they were read.
  final _deletedRelations = <int, OsmRelation>{};
  var _nextId = -1;

  /// Called whenever what has been changed changes.
  final void Function()? _onChanged;

  /// Creates a set of changes.
  OsmEditHistory({void Function()? onChanged}) : _onChanged = onChanged;

  /// The edits made, oldest first.
  List<OsmEdit> get edits => List.unmodifiable(_done);

  /// How many changes have been made.
  int get length => _done.length;

  /// Whether nothing has been changed.
  bool get isEmpty => _done.isEmpty;

  /// Whether anything has been.
  bool get isNotEmpty => _done.isNotEmpty;

  /// The nodes that have been made or changed, by id: moved, or given other
  /// tags.
  Map<int, OsmNode> get changedNodes => Map.unmodifiable(_nodes);

  /// The node with [id] as it now stands, or null if it has not been
  /// touched.
  OsmNode? changedNode(int id) => _nodes[id];

  /// The way with [id] as it now stands, or null if it has not been touched.
  OsmWay? changedWay(int id) => _ways[id];

  /// The ways that have been made or changed, by id.
  Map<int, OsmWay> get changedWays => Map.unmodifiable(_ways);

  /// The nodes taken off the map, as they were before, by id.
  ///
  /// Only nodes that were on the map to begin with. One made and then
  /// deleted again never existed as far as anything outside is concerned.
  Map<int, OsmNode> get deletedNodes => Map.unmodifiable(_deleted);

  /// The ways taken off the map, as they were before, by id: only ways that
  /// were on the map to begin with.
  Map<int, OsmWay> get deletedWays => Map.unmodifiable(_deletedWays);

  /// The relations taken off the map, as they were before, by id.
  Map<int, OsmRelation> get deletedRelations =>
      Map.unmodifiable(_deletedRelations);

  /// The relation with [id] as it now stands, or null if it has not been
  /// touched.
  OsmRelation? changedRelation(int id) => _relations[id];

  /// The relations whose members have been changed, by id.
  Map<int, OsmRelation> get changedRelations => Map.unmodifiable(_relations);

  /// Whether the element has been taken off the map.
  bool isGone(OsmElementType type, int id) => _gone.contains((type, id));

  /// Makes a node at ([latitude], [longitude]).
  OsmNode _createNode({
    required double latitude,
    required double longitude,
    Map<String, String> tags = const {},
  }) {
    final node = OsmNode(
      id: _nextId--,
      latitude: latitude,
      longitude: longitude,
      tags: tags,
    );
    _nodes[node.id] = node;
    _done.add(OsmNodeCreated._(node));
    _changed();
    return node;
  }

  /// Makes a way through [nodeIds].
  OsmWay _createWay({
    required List<int> nodeIds,
    Map<String, String> tags = const {},
  }) {
    final way = OsmWay(id: _nextId--, nodeIds: [...nodeIds], tags: tags);
    _ways[way.id] = way;
    _done.add(OsmWayCreated._(way));
    _changed();
    return way;
  }

  /// Makes a relation of [members].
  OsmRelation _createRelation({
    required List<OsmMember> members,
    Map<String, String> tags = const {},
  }) {
    final relation = OsmRelation(
      id: _nextId--,
      members: List.unmodifiable(members),
      tags: tags,
    );
    _relations[relation.id] = relation;
    _done.add(OsmRelationCreated._(relation));
    _changed();
    return relation;
  }

  /// Takes [node] off the map.
  ///
  /// It is taken out of every way in [from] as well, since a way cannot run
  /// through something that is no longer there.
  ///
  /// And out of every relation in [relations], since OpenStreetMap will not
  /// delete something a relation still lists.
  void _deleteNode(
    OsmNode node, {
    Iterable<OsmWay> from = const [],
    Iterable<OsmRelation> relations = const [],
  }) {
    final ways = <OsmWayNodesChanged>[];
    for (final way in from) {
      final running = _ways[way.id] ?? way;
      if (!running.nodeIds.contains(node.id)) continue;
      ways.add(
        _change(
          running,
          running.withoutNode(node.id),
          wasRead: !_ways.containsKey(way.id),
        ),
      );
    }
    final members = _withoutMember(relations, OsmElementType.node, node.id);
    final wasRead = !_nodes.containsKey(node.id);
    final current = _nodes.remove(node.id) ?? node;
    _gone.add((OsmElementType.node, node.id));
    // A node that was never uploaded is not deleted from anywhere: it goes
    // out of the edits and there is nothing to tell OpenStreetMap about.
    if (node.id > 0) _deleted[node.id] = current;
    _done.add(
      OsmNodeDeleted._(
        current,
        ways: ways,
        relations: members,
        wasRead: wasRead,
      ),
    );
    _changed();
  }

  /// Takes [way] off the map, and out of every relation in [relations].
  ///
  /// Only the way. Its nodes stay unless they are deleted as well, which is
  /// for whoever deletes the way to decide: some are shared with other ways
  /// or say something of their own.
  void _deleteWay(OsmWay way, {Iterable<OsmRelation> relations = const []}) {
    if (isGone(OsmElementType.way, way.id)) return;
    final members = _withoutMember(relations, OsmElementType.way, way.id);
    final wasRead = !_ways.containsKey(way.id);
    final current = _ways.remove(way.id) ?? way;
    _gone.add((OsmElementType.way, way.id));
    if (way.id > 0) _deletedWays[way.id] = current;
    _done.add(
      OsmWayDeleted._(current, relations: members, wasRead: wasRead),
    );
    _changed();
  }

  /// Takes [relation] off the map, and out of every relation in
  /// [relations].
  void _deleteRelation(
    OsmRelation relation, {
    Iterable<OsmRelation> relations = const [],
  }) {
    if (isGone(OsmElementType.relation, relation.id)) return;
    final members = _withoutMember(
      relations,
      OsmElementType.relation,
      relation.id,
    );
    final wasRead = !_relations.containsKey(relation.id);
    final current = _relations.remove(relation.id) ?? relation;
    _gone.add((OsmElementType.relation, relation.id));
    if (relation.id > 0) _deletedRelations[relation.id] = current;
    _done.add(
      OsmRelationDeleted._(current, relations: members, wasRead: wasRead),
    );
    _changed();
  }

  /// Gives [relation] [members] in place of the ones it has.
  void _setRelationMembers(OsmRelation relation, List<OsmMember> members) {
    _done.add(_changeRelation(relation, members));
    _changed();
  }

  /// Takes every membership of the element out of each of [relations], and
  /// says what that changed.
  List<OsmRelationChanged> _withoutMember(
    Iterable<OsmRelation> relations,
    OsmElementType type,
    int id,
  ) =>
      [
        for (final relation in relations)
          if (_relations[relation.id] ?? relation case final running
              when running.members.any((m) => m.type == type && m.ref == id))
            _changeRelation(running, [
              for (final member in running.members)
                if (member.type != type || member.ref != id) member,
            ]),
      ];

  OsmRelationChanged _changeRelation(
    OsmRelation relation,
    List<OsmMember> members,
  ) {
    final wasRead = !_relations.containsKey(relation.id);
    final was = _relations[relation.id] ?? relation;
    final now = OsmRelation(
      id: was.id,
      members: List.unmodifiable(members),
      tags: was.tags,
      info: was.info,
    );
    _relations[relation.id] = now;
    return OsmRelationChanged._(from: was, to: now, wasRead: wasRead);
  }

  /// Puts [way] through [nodeIds] instead of what it ran through before.
  void _setWayNodes(OsmWay way, List<int> nodeIds) {
    _done.add(
      _change(way, nodeIds, wasRead: !_ways.containsKey(way.id)),
    );
    _changed();
  }

  /// Puts a way through other nodes and says what that changed.
  OsmWayNodesChanged _change(
    OsmWay way,
    List<int> nodeIds, {
    required bool wasRead,
  }) {
    final was = _ways[way.id] ?? way;
    final now = OsmWay(
      id: way.id,
      nodeIds: [...nodeIds],
      tags: was.tags,
      info: was.info,
    );
    _ways[way.id] = now;
    return OsmWayNodesChanged._(from: was, to: now, wasRead: wasRead);
  }

  /// Moves [node] to ([latitude], [longitude]).
  ///
  /// A run of moves of the same node while it is being dragged is one change
  /// rather than one a frame: [continuing] says this is more of a move that
  /// is already under way.
  void _moveNode(
    OsmNode node, {
    required double latitude,
    required double longitude,
    bool continuing = false,
  }) {
    final moved = OsmNode(
      id: node.id,
      latitude: latitude,
      longitude: longitude,
      tags: node.tags,
      info: node.info,
    );

    final last = _done.isEmpty ? null : _done.last;
    if (continuing && last is OsmNodeMoved && last.id == node.id) {
      _done[_done.length - 1] = OsmNodeMoved._(
        from: last.from,
        to: moved,
        wasRead: last._wasRead,
      );
    } else {
      _done.add(
        OsmNodeMoved._(
          from: _nodes[node.id] ?? node,
          to: moved,
          wasRead: !_nodes.containsKey(node.id),
        ),
      );
    }
    _nodes[node.id] = moved;
    _changed();
  }

  /// Gives [element] [tags] in place of the ones it has, and says whether
  /// that changed anything.
  ///
  /// A node, a way or a relation, as it now stands or as it was read.
  /// Everything but the tags is kept, and nothing is recorded if the tags are
  /// already these.
  bool _setTags(OsmElement element, Map<String, String> tags) {
    if (isGone(element.type, element.id)) return false;
    final OsmElement was;
    final bool wasRead;
    switch (element) {
      case OsmNode():
        wasRead = !_nodes.containsKey(element.id);
        was = _nodes[element.id] ?? element;
      case OsmWay():
        wasRead = !_ways.containsKey(element.id);
        was = _ways[element.id] ?? element;
      case OsmRelation():
        wasRead = !_relations.containsKey(element.id);
        was = _relations[element.id] ?? element;
    }
    if (_sameTags(was.tags, tags)) return false;

    final kept = Map<String, String>.unmodifiable(tags);
    final OsmElement now;
    switch (was) {
      case final OsmNode node:
        now = _nodes[node.id] = OsmNode(
          id: node.id,
          latitude: node.latitude,
          longitude: node.longitude,
          tags: kept,
          info: node.info,
        );
      case final OsmWay way:
        now = _ways[way.id] = OsmWay(
          id: way.id,
          nodeIds: way.nodeIds,
          tags: kept,
          info: way.info,
        );
      case final OsmRelation relation:
        now = _relations[relation.id] = OsmRelation(
          id: relation.id,
          members: relation.members,
          tags: kept,
          info: relation.info,
        );
    }
    _done.add(OsmTagsChanged._(from: was, to: now, wasRead: wasRead));
    _changed();
    return true;
  }

  static bool _sameTags(Map<String, String> a, Map<String, String> b) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (b[entry.key] != entry.value) return false;
    }
    return true;
  }

  /// Gathers everything done since [mark] into one change.
  ///
  /// [mark] is a [length] taken before the run of changes started. Nothing
  /// happens if fewer than two changes have been made since, there being
  /// nothing to gather.
  void _combineSince(int mark) {
    if (mark < 0 || _done.length - mark < 2) return;
    final gathered = _done.sublist(mark);
    _done.removeRange(mark, _done.length);
    _done.add(OsmEditGroup._(gathered));
    _onChanged?.call();
  }

  /// A new change has been made, which leaves nothing to redo: what was
  /// undone was undone from before it.
  void _changed() {
    _undone.clear();
    _onChanged?.call();
  }

  /// What uploading these changes would send.
  OsmUpload toUpload() {
    final nodes = changedNodes;
    final ways = changedWays;
    return OsmUpload(
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
      deletedNodes: deletedNodes.values.toList(),
      createdWays: [
        for (final way in ways.values)
          if (way.id < 0) way,
      ],
      changedWays: [
        for (final way in ways.values)
          if (way.id > 0) way,
      ],
      deletedWays: deletedWays.values.toList(),
      createdRelations: [
        for (final relation in changedRelations.values)
          if (relation.id < 0) relation,
      ],
      changedRelations: [
        for (final relation in changedRelations.values)
          if (relation.id > 0 && !isGone(OsmElementType.relation, relation.id))
            relation,
      ],
      deletedRelations: deletedRelations.values.toList(),
    );
  }

  /// Whether there is a change undone that can be made again.
  bool get canRedo => _undone.isNotEmpty;

  /// Undoes the last change, and says whether there was one to undo.
  ///
  /// It can be made again with [redo] until another change is made.
  bool _undo() {
    if (_done.isEmpty) return false;
    final last = _done.removeLast();
    _undoOne(last);
    _undone.add(last);
    _onChanged?.call();
    return true;
  }

  /// Makes the last change undone again, and says whether there was one.
  bool _redo() {
    if (_undone.isEmpty) return false;
    final next = _undone.removeLast();
    _redoOne(next);
    _done.add(next);
    _onChanged?.call();
    return true;
  }

  /// Puts back what [change] made, which it holds as well as what it
  /// replaced.
  void _redoOne(OsmEdit change) {
    switch (change) {
      case OsmEditGroup():
        for (final part in change.edits) {
          _redoOne(part);
        }
      case OsmNodeMoved():
        _nodes[change.id] = change.to;
      case OsmNodeCreated():
        _nodes[change.id] = change.node;
      case OsmNodeDeleted():
        for (final way in change.ways) {
          _ways[way.id] = way.to;
        }
        for (final relation in change.relations) {
          _relations[relation.id] = relation.to;
        }
        _nodes.remove(change.id);
        _gone.add((OsmElementType.node, change.id));
        if (change.id > 0) _deleted[change.id] = change.node;
      case OsmWayCreated():
        _ways[change.id] = change.way;
      case OsmWayNodesChanged():
        _ways[change.id] = change.to;
      case OsmWayDeleted():
        for (final relation in change.relations) {
          _relations[relation.id] = relation.to;
        }
        _ways.remove(change.id);
        _gone.add((OsmElementType.way, change.id));
        if (change.id > 0) _deletedWays[change.id] = change.way;
      case OsmRelationCreated():
        _relations[change.id] = change.relation;
      case OsmRelationChanged():
        _relations[change.id] = change.to;
      case OsmRelationDeleted():
        for (final relation in change.relations) {
          _relations[relation.id] = relation.to;
        }
        _relations.remove(change.id);
        _gone.add((OsmElementType.relation, change.id));
        if (change.id > 0) _deletedRelations[change.id] = change.relation;
      case OsmTagsChanged():
        switch (change.to) {
          case final OsmNode node:
            _nodes[node.id] = node;
          case final OsmWay way:
            _ways[way.id] = way;
          case final OsmRelation relation:
            _relations[relation.id] = relation;
        }
    }
  }

  void _undoOne(OsmEdit last) {
    switch (last) {
      case OsmEditGroup():
        for (final change in last.edits.reversed) {
          _undoOne(change);
        }
      case OsmNodeMoved():
        _putNode(last.from, wasRead: last._wasRead);
      case OsmNodeCreated():
        _nodes.remove(last.id);
      case OsmNodeDeleted():
        _gone.remove((OsmElementType.node, last.id));
        _deleted.remove(last.id);
        _putNode(last.node, wasRead: last._wasRead);
        for (final change in last.relations.reversed) {
          _undoRelation(change);
        }
        for (final change in last.ways.reversed) {
          _undoWay(change);
        }
      case OsmWayDeleted():
        _gone.remove((OsmElementType.way, last.id));
        _deletedWays.remove(last.id);
        if (!last._wasRead) _ways[last.id] = last.way;
        for (final change in last.relations.reversed) {
          _undoRelation(change);
        }
      case OsmRelationChanged():
        _undoRelation(last);
      case OsmRelationCreated():
        _relations.remove(last.id);
      case OsmRelationDeleted():
        _gone.remove((OsmElementType.relation, last.id));
        _deletedRelations.remove(last.id);
        if (!last._wasRead) _relations[last.id] = last.relation;
        for (final change in last.relations.reversed) {
          _undoRelation(change);
        }
      case OsmWayCreated():
        _ways.remove(last.id);
      case OsmWayNodesChanged():
        _undoWay(last);
      case OsmTagsChanged():
        _undoTags(last);
    }
  }

  void _undoRelation(OsmRelationChanged change) {
    if (change._wasRead) {
      _relations.remove(change.id);
    } else {
      _relations[change.id] = change.from;
    }
  }

  /// Puts a node back to [node], or to what was read if that is what it was.
  void _putNode(OsmNode node, {required bool wasRead}) {
    if (wasRead) {
      _nodes.remove(node.id);
    } else {
      _nodes[node.id] = node;
    }
  }

  void _undoTags(OsmTagsChanged change) {
    switch (change.from) {
      case final OsmNode node:
        _putNode(node, wasRead: change._wasRead);
      case final OsmWay way:
        if (change._wasRead) {
          _ways.remove(way.id);
        } else {
          _ways[way.id] = way;
        }
      case final OsmRelation relation:
        if (change._wasRead) {
          _relations.remove(relation.id);
        } else {
          _relations[relation.id] = relation;
        }
    }
  }

  /// Puts a way back to however it ran before a change.
  void _undoWay(OsmWayNodesChanged change) {
    if (change._wasRead) {
      _ways.remove(change.id);
    } else {
      _ways[change.id] = change.from;
    }
  }

  /// Undoes everything done since [mark], a [length] taken before it
  /// started: for giving up on something made a change at a time, such as a
  /// line being drawn.
  ///
  /// Given up on rather than undone, so none of it can be redone.
  void _undoSince(int mark) {
    if (_done.length <= mark) return;
    while (_done.length > mark) {
      _undoOne(_done.removeLast());
    }
    _onChanged?.call();
  }

  /// Undoes everything.
  ///
  /// Nothing can be redone afterwards: this is for starting again, such as
  /// once everything has been uploaded.
  void _undoAll() {
    if (_done.isEmpty && _undone.isEmpty) return;
    _done.clear();
    _undone.clear();
    _nodes.clear();
    _ways.clear();
    _gone.clear();
    _deleted.clear();
    _deletedWays.clear();
    _relations.clear();
    _deletedRelations.clear();
    _onChanged?.call();
  }

  /// Every element taken off the map, whether or not it was ever uploaded.
  Set<(OsmElementType, int)> get gone => Set.unmodifiable(_gone);
}
