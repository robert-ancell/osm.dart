import 'element.dart';

/// One change made to a dataset.
///
/// Holds what the element was as well as what it became, so that undoing is
/// a matter of putting the old one back rather than of working out what the
/// old one must have been.
sealed class OsmEdit {
  const OsmEdit();

  /// The kind of element changed.
  OsmElementType get type;

  /// The id of the element changed.
  int get id;
}

/// A node that was not there before.
class OsmNodeCreated extends OsmEdit {
  /// The node made.
  final OsmNode node;

  /// Creates a record of a new node.
  const OsmNodeCreated(this.node);

  @override
  OsmElementType get type => OsmElementType.node;

  @override
  int get id => node.id;

  @override
  String toString() => 'OsmNodeCreated($id)';
}

/// A node taken off the map.
class OsmNodeDeleted extends OsmEdit {
  /// The node as it was.
  final OsmNode node;

  /// What it being gone did to the ways that ran through it.
  ///
  /// Part of the same change: a way cannot run through something that is not
  /// there, so putting the node back has to put the ways back with it.
  final List<OsmWayNodesChanged> ways;

  /// Whether [node] is the node as it was read, rather than as an earlier
  /// change left it. Undoing back to what was read means holding nothing.
  final bool wasRead;

  /// Creates a record of a deletion.
  const OsmNodeDeleted(this.node, {this.ways = const [], this.wasRead = false});

  @override
  OsmElementType get type => OsmElementType.node;

  @override
  int get id => node.id;

  @override
  String toString() => 'OsmNodeDeleted($id)';
}

/// A way that was not there before.
class OsmWayCreated extends OsmEdit {
  /// The way made.
  final OsmWay way;

  /// Creates a record of a new way.
  const OsmWayCreated(this.way);

  @override
  OsmElementType get type => OsmElementType.way;

  @override
  int get id => way.id;

  @override
  String toString() => 'OsmWayCreated($id)';
}

/// The nodes a way runs through, changed.
class OsmWayNodesChanged extends OsmEdit {
  /// The way as it was.
  final OsmWay from;

  /// The way as it is now.
  final OsmWay to;

  /// Whether [from] is the way as it was read, rather than an earlier
  /// change to it. Undoing back to what was read means holding nothing.
  final bool wasRead;

  /// Creates a record of a change to a way's nodes.
  const OsmWayNodesChanged({
    required this.from,
    required this.to,
    this.wasRead = false,
  });

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
  final List<OsmEdit> changes;

  /// Creates a group.
  const OsmEditGroup(this.changes);

  @override
  OsmElementType get type => changes.last.type;

  @override
  int get id => changes.last.id;

  @override
  String toString() => 'OsmEditGroup(${changes.length})';
}

/// A node moved to somewhere else.
class OsmNodeMoved extends OsmEdit {
  /// Where it was.
  final OsmNode from;

  /// Where it is now.
  final OsmNode to;

  /// Whether [from] is the node as it was read, rather than as an earlier
  /// change left it. Undoing back to what was read means holding nothing.
  final bool wasRead;

  /// Creates a record of a move.
  const OsmNodeMoved({
    required this.from,
    required this.to,
    this.wasRead = false,
  });

  @override
  OsmElementType get type => OsmElementType.node;

  @override
  int get id => from.id;

  @override
  String toString() => 'OsmNodeMoved($id)';
}

/// The tags of a node or a way, changed.
class OsmTagsChanged extends OsmEdit {
  /// The element as it was.
  final OsmElement from;

  /// The element as it is now: the same but for its tags.
  final OsmElement to;

  /// Whether [from] is the element as it was read, rather than as an earlier
  /// change left it. Undoing back to what was read means holding nothing.
  final bool wasRead;

  /// Creates a record of a change to an element's tags.
  const OsmTagsChanged({
    required this.from,
    required this.to,
    this.wasRead = false,
  });

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
class OsmEdits {
  final _done = <OsmEdit>[];
  final _nodes = <int, OsmNode>{};
  final _ways = <int, OsmWay>{};
  final _gone = <(OsmElementType, int)>{};

  /// The nodes taken off the map, as they were read.
  ///
  /// Kept because an upload has to name the version it is deleting, which is
  /// only in the element itself.
  final _deleted = <int, OsmNode>{};
  var _nextId = -1;

  /// Called whenever what has been changed changes.
  final void Function()? onChanged;

  /// Creates a set of changes.
  OsmEdits({this.onChanged});

  /// The changes made, oldest first.
  List<OsmEdit> get changes => List.unmodifiable(_done);

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

  /// Whether the element has been taken off the map.
  bool isGone(OsmElementType type, int id) => _gone.contains((type, id));

  /// An id for something that was not there before.
  ///
  /// Negative, which is what OpenStreetMap expects of something that has not
  /// been uploaded yet and has no id of its own.
  int get nextId => _nextId;

  /// Makes a node at ([latitude], [longitude]).
  OsmNode createNode({
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
    _done.add(OsmNodeCreated(node));
    onChanged?.call();
    return node;
  }

  /// Makes a way through [nodeIds].
  OsmWay createWay({
    required List<int> nodeIds,
    Map<String, String> tags = const {},
  }) {
    final way = OsmWay(id: _nextId--, nodeIds: [...nodeIds], tags: tags);
    _ways[way.id] = way;
    _done.add(OsmWayCreated(way));
    onChanged?.call();
    return way;
  }

  /// Takes [node] off the map.
  ///
  /// It is taken out of every way in [from] as well, since a way cannot run
  /// through something that is no longer there.
  void deleteNode(OsmNode node, {Iterable<OsmWay> from = const []}) {
    final ways = <OsmWayNodesChanged>[];
    for (final way in from) {
      final running = _ways[way.id] ?? way;
      if (!running.nodeIds.contains(node.id)) continue;
      ways.add(
        _change(
          running,
          [
            for (final id in running.nodeIds)
              if (id != node.id) id,
          ],
          wasRead: !_ways.containsKey(way.id),
        ),
      );
    }
    final wasRead = !_nodes.containsKey(node.id);
    final current = _nodes.remove(node.id) ?? node;
    _gone.add((OsmElementType.node, node.id));
    // A node that was never uploaded is not deleted from anywhere: it goes
    // out of the edits and there is nothing to tell OpenStreetMap about.
    if (node.id > 0) _deleted[node.id] = current;
    _done.add(OsmNodeDeleted(current, ways: ways, wasRead: wasRead));
    onChanged?.call();
  }

  /// Puts [way] through [nodeIds] instead of what it ran through before.
  void setWayNodes(OsmWay way, List<int> nodeIds) {
    _done.add(
      _change(way, nodeIds, wasRead: !_ways.containsKey(way.id)),
    );
    onChanged?.call();
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
    return OsmWayNodesChanged(from: was, to: now, wasRead: wasRead);
  }

  /// Moves [node] to ([latitude], [longitude]).
  ///
  /// A run of moves of the same node while it is being dragged is one change
  /// rather than one a frame: [continuing] says this is more of a move that
  /// is already under way.
  void moveNode(
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
      _done[_done.length - 1] = OsmNodeMoved(
        from: last.from,
        to: moved,
        wasRead: last.wasRead,
      );
    } else {
      _done.add(
        OsmNodeMoved(
          from: _nodes[node.id] ?? node,
          to: moved,
          wasRead: !_nodes.containsKey(node.id),
        ),
      );
    }
    _nodes[node.id] = moved;
    onChanged?.call();
  }

  /// Gives [element] [tags] in place of the ones it has, and says whether
  /// that changed anything.
  ///
  /// A node or a way, as it now stands or as it was read. Everything but the
  /// tags is kept, and nothing is recorded if the tags are already these.
  bool setTags(OsmElement element, Map<String, String> tags) {
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
        throw ArgumentError.value(element, 'element', 'not a node or a way');
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
      case OsmRelation():
        throw StateError('unreachable');
    }
    _done.add(OsmTagsChanged(from: was, to: now, wasRead: wasRead));
    onChanged?.call();
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
  void combineSince(int mark) {
    if (mark < 0 || _done.length - mark < 2) return;
    final gathered = _done.sublist(mark);
    _done.removeRange(mark, _done.length);
    _done.add(OsmEditGroup(gathered));
    onChanged?.call();
  }

  /// Undoes the last change, and says whether there was one to undo.
  bool undo() {
    if (_done.isEmpty) return false;
    _undoOne(_done.removeLast());
    onChanged?.call();
    return true;
  }

  void _undoOne(OsmEdit last) {
    switch (last) {
      case OsmEditGroup():
        for (final change in last.changes.reversed) {
          _undoOne(change);
        }
      case OsmNodeMoved():
        _putNode(last.from, wasRead: last.wasRead);
      case OsmNodeCreated():
        _nodes.remove(last.id);
      case OsmNodeDeleted():
        _gone.remove((OsmElementType.node, last.id));
        _deleted.remove(last.id);
        _putNode(last.node, wasRead: last.wasRead);
        for (final change in last.ways.reversed) {
          _undoWay(change);
        }
      case OsmWayCreated():
        _ways.remove(last.id);
      case OsmWayNodesChanged():
        _undoWay(last);
      case OsmTagsChanged():
        _undoTags(last);
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
        _putNode(node, wasRead: change.wasRead);
      case final OsmWay way:
        if (change.wasRead) {
          _ways.remove(way.id);
        } else {
          _ways[way.id] = way;
        }
      case OsmRelation():
        break;
    }
  }

  /// Puts a way back to however it ran before a change.
  void _undoWay(OsmWayNodesChanged change) {
    if (change.wasRead) {
      _ways.remove(change.id);
    } else {
      _ways[change.id] = change.from;
    }
  }

  /// Undoes everything.
  void undoAll() {
    if (_done.isEmpty) return;
    _done.clear();
    _nodes.clear();
    _ways.clear();
    _gone.clear();
    _deleted.clear();
    onChanged?.call();
  }

  /// The elements that have been changed, along with everything that has to
  /// be redrawn because of them.
  ///
  /// A moved node takes every way running through it with it, which is what
  /// [waysUsing] is asked for.
  Set<(OsmElementType, int)> touching(
    List<int> Function(int nodeId) waysUsing,
  ) {
    final touched = <(OsmElementType, int)>{..._gone};
    for (final id in _nodes.keys) {
      touched.add((OsmElementType.node, id));
      for (final way in waysUsing(id)) {
        touched.add((OsmElementType.way, way));
      }
    }
    for (final id in _ways.keys) {
      touched.add((OsmElementType.way, id));
    }
    for (final (type, id) in _gone) {
      if (type != OsmElementType.node) continue;
      for (final way in waysUsing(id)) {
        touched.add((OsmElementType.way, way));
      }
    }
    return touched;
  }
}
