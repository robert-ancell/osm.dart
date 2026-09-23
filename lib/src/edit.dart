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

  /// The node with [id] as it now stands, or null if it has not been moved.
  OsmNode? movedNode(int id) => _nodes[id];

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
        // Back to whatever it was before this change, which is either an
        // earlier change to the same node or nothing at all.
        final earlier = _done.reversed
            .whereType<OsmNodeMoved>()
            .where((change) => change.id == last.id)
            .firstOrNull;
        if (earlier == null) {
          _nodes.remove(last.id);
        } else {
          _nodes[last.id] = earlier.to;
        }
    }
    onChanged?.call();
    return true;
  }

  /// Undoes everything.
  void undoAll() {
    if (_done.isEmpty) return;
    _done.clear();
    _nodes.clear();
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
    final touched = <(OsmElementType, int)>{};
    for (final id in _nodes.keys) {
      touched.add((OsmElementType.node, id));
      for (final way in waysUsing(id)) {
        touched.add((OsmElementType.way, way));
      }
    }
    return touched;
  }
}
