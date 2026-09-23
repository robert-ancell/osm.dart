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

  /// Creates a record of a deletion.
  const OsmNodeDeleted(this.node, {this.ways = const []});

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

/// A node moved to somewhere else.
class OsmNodeMoved extends OsmEdit {
  /// Where it was.
  final OsmNode from;

  /// Where it is now.
  final OsmNode to;

  /// Creates a record of a move.
  const OsmNodeMoved({required this.from, required this.to});

  @override
  OsmElementType get type => OsmElementType.node;

  @override
  int get id => from.id;

  @override
  String toString() => 'OsmNodeMoved($id)';
}

/// Changes made to a dataset, in the order they were made.
///
/// Nothing here touches what was read. Whatever holds the elements keeps them
/// exactly as OpenStreetMap sent them, and what has been changed is laid over
/// the top: an element is looked for here first and in the dataset only if it
/// has not been touched. Undoing is then a matter of dropping the last change
/// rather than of putting anything back.
class OsmEdits {
  final _done = <OsmEdit>[];
  final _nodes = <int, OsmNode>{};
  final _ways = <int, OsmWay>{};
  final _gone = <(OsmElementType, int)>{};
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

  /// The nodes that have been moved, by id.
  Map<int, OsmNode> get movedNodes => Map.unmodifiable(_nodes);

  /// The node with [id] as it now stands, or null if it has not been
  /// touched.
  OsmNode? movedNode(int id) => _nodes[id];

  /// The way with [id] as it now stands, or null if it has not been touched.
  OsmWay? changedWay(int id) => _ways[id];

  /// The ways that have been made or changed, by id.
  Map<int, OsmWay> get changedWays => Map.unmodifiable(_ways);

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
    _nodes.remove(node.id);
    _gone.add((OsmElementType.node, node.id));
    _done.add(OsmNodeDeleted(node, ways: ways));
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
      _done[_done.length - 1] = OsmNodeMoved(from: last.from, to: moved);
    } else {
      _done.add(OsmNodeMoved(from: _nodes[node.id] ?? node, to: moved));
    }
    _nodes[node.id] = moved;
    onChanged?.call();
  }

  /// Undoes the last change, and says whether there was one to undo.
  bool undo() {
    if (_done.isEmpty) return false;
    final last = _done.removeLast();
    switch (last) {
      case OsmNodeMoved():
        _restoreNode(last.id);
      case OsmNodeCreated():
        _nodes.remove(last.id);
      case OsmNodeDeleted():
        _gone.remove((OsmElementType.node, last.id));
        _restoreNode(last.id);
        for (final change in last.ways) {
          _undoWay(change);
        }
      case OsmWayCreated():
        _ways.remove(last.id);
      case OsmWayNodesChanged():
        _undoWay(last);
    }
    onChanged?.call();
    return true;
  }

  /// Puts a way back to however it ran before a change.
  void _undoWay(OsmWayNodesChanged change) {
    if (change.wasRead) {
      _ways.remove(change.id);
    } else {
      _ways[change.id] = change.from;
    }
  }

  /// Puts a node back to however it stood before the change just undone.
  void _restoreNode(int id) {
    final moved = _lastOf<OsmNodeMoved>(id);
    if (moved != null) {
      _nodes[id] = moved.to;
      return;
    }
    final made = _lastOf<OsmNodeCreated>(id);
    if (made != null) {
      _nodes[id] = made.node;
      return;
    }
    _nodes.remove(id);
  }

  /// The last change of a kind still standing against an element.
  T? _lastOf<T extends OsmEdit>(int id) => _done.reversed
      .whereType<T>()
      .where((change) => change.id == id)
      .firstOrNull;

  /// Undoes everything.
  void undoAll() {
    if (_done.isEmpty) return;
    _done.clear();
    _nodes.clear();
    _ways.clear();
    _gone.clear();
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
