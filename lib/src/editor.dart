part of 'edit.dart';

/// Edits OpenStreetMap data: what a program making changes holds.
///
/// It is the data as it now stands — what was read, from [data], with every
/// change since laid over it and whatever was taken off the map left out —
/// and everything that can be done to it, each done as one change that one
/// [undo] takes back and one [redo] makes again.
///
/// The changes themselves are kept in [history], which is what an upload is
/// made from.
class OsmEditor {
  /// What was read.
  final OsmEditorData data;

  /// Every change made, in order.
  final OsmEditHistory history;

  /// What tags mean: whether a closed way is an area, what turns round
  /// when a way does, what goes where when things are split and joined.
  ///
  /// The editor knows nothing of tags itself. [OsmPlainTagRules] unless
  /// given others, such as [OsmStandardTagRules].
  final OsmTagRules rules;

  /// Creates an editor over [data], deciding what tags mean by [rules].
  ///
  /// Its changes are kept in [history] if it is given one, which is how an
  /// editor carries on from changes made before; otherwise in a history of
  /// its own, which calls [onChanged] whenever what has been changed
  /// changes.
  OsmEditor(
    this.data, {
    OsmEditHistory? history,
    this.rules = const OsmPlainTagRules(),
    void Function()? onChanged,
  })  : assert(
          history == null || onChanged == null,
          'Give the history its onChanged instead.',
        ),
        history = history ?? OsmEditHistory(onChanged: onChanged);

  // The data as it now stands.

  /// The node with [id] as it now stands, or null if it is not held or has
  /// been taken off the map.
  OsmNode? node(int id) => history.isGone(OsmElementType.node, id)
      ? null
      : history.changedNode(id) ?? data.node(id);

  /// The way with [id] as it now stands, or null.
  OsmWay? way(int id) => history.isGone(OsmElementType.way, id)
      ? null
      : history.changedWay(id) ?? data.way(id);

  /// The relation with [id] as it now stands, or null.
  OsmRelation? relation(int id) => history.isGone(OsmElementType.relation, id)
      ? null
      : history.changedRelation(id) ?? data.relation(id);

  /// The ways that now run through the node with [nodeId]: those read and
  /// those made or changed since.
  List<OsmWay> waysUsing(int nodeId) => [
        for (final wayId in {
          ...data.waysUsing(nodeId),
          ...history.changedWays.keys,
        })
          if (way(wayId) case final way? when way.nodeIds.contains(nodeId)) way,
      ];

  /// The relations that now list the element.
  List<OsmRelation> relationsUsing(OsmElementType type, int id) => [
        for (final relationId in {
          ...data.relationsUsing(type, id),
          ...history.changedRelations.keys,
        })
          if (relation(relationId) case final relation?
              when relation.members.any((m) => m.type == type && m.ref == id))
            relation,
      ];

  /// The shape [element] now takes, as far as what it can be is concerned.
  ///
  /// A node is a vertex when it is in a way and a point when it stands alone. A
  /// way is an area when it is closed and [rules] say its tags make it one, and
  /// a line otherwise. A multipolygon is an area and any other relation is a
  /// relation.
  OsmGeometry geometryOf(OsmElement element) => switch (element) {
        OsmNode() => waysUsing(element.id).isEmpty
            ? OsmGeometry.point
            : OsmGeometry.vertex,
        OsmWay() => element.isClosed && rules.isArea(element.tags)
            ? OsmGeometry.area
            : OsmGeometry.line,
        OsmRelation() => element.tags['type'] == 'multipolygon'
            ? OsmGeometry.area
            : OsmGeometry.relation,
      };

  // History.

  /// Whether there is a change to undo.
  bool get canUndo => history.isNotEmpty;

  /// Undoes the last change, and says whether there was one to undo.
  bool undo() => history._undo();

  /// Whether there is an undone change to make again.
  bool get canRedo => history.canRedo;

  /// Makes the last undone change again, and says whether there was one.
  bool redo() => history._redo();

  /// Undoes everything, leaving nothing to redo.
  void undoAll() => history._undoAll();

  /// Does [change], and makes whatever it changes one change to undo.
  ///
  /// For a run of changes that belong together, such as drawing a line a
  /// point at a time. Gives back what [change] does.
  T group<T>(T Function() change) {
    final mark = history.length;
    try {
      return change();
    } finally {
      history._combineSince(mark);
    }
  }

  /// A point in the history to come back to: what [combineSince] and
  /// [undoSince] take.
  OsmEditMark mark() => OsmEditMark._(history.length);

  /// Gathers everything done since [mark] into one change to undo.
  ///
  /// For a run of changes made across several events, such as a line drawn
  /// a click at a time, where [group] cannot wrap them all.
  void combineSince(OsmEditMark mark) => history._combineSince(mark._length);

  /// Undoes everything done since [mark]: for giving up on something made a
  /// change at a time.
  ///
  /// Given up on rather than undone, so none of it can be redone.
  void undoSince(OsmEditMark mark) => history._undoSince(mark._length);

  // Single changes.

  /// Makes a node at ([latitude], [longitude]).
  OsmNode createNode({
    required double latitude,
    required double longitude,
    Map<String, String> tags = const {},
  }) =>
      history._createNode(latitude: latitude, longitude: longitude, tags: tags);

  /// Makes a way through [nodeIds].
  OsmWay createWay({
    required List<int> nodeIds,
    Map<String, String> tags = const {},
  }) =>
      history._createWay(nodeIds: nodeIds, tags: tags);

  /// Makes a relation of [members].
  OsmRelation createRelation({
    required List<OsmMember> members,
    Map<String, String> tags = const {},
  }) =>
      history._createRelation(members: members, tags: tags);

  /// Takes [node] off the map, and out of every way through it and every
  /// relation listing it: a way cannot run through something that is no
  /// longer there, and OpenStreetMap will not delete something a relation
  /// still lists.
  void deleteNode(OsmNode node) => history._deleteNode(
        node,
        from: waysUsing(node.id),
        relations: relationsUsing(OsmElementType.node, node.id),
      );

  /// Takes [way] off the map, and out of every relation listing it.
  ///
  /// Only the way. Its nodes stay unless they are deleted as well, which is
  /// for whoever deletes the way to decide: some are shared with other ways
  /// or say something of their own. [delete] decides it by [rules].
  void deleteWay(OsmWay way) => history._deleteWay(
        way,
        relations: relationsUsing(OsmElementType.way, way.id),
      );

  /// Takes [relation] off the map, and out of every relation listing it.
  void deleteRelation(OsmRelation relation) => history._deleteRelation(
        relation,
        relations: relationsUsing(OsmElementType.relation, relation.id),
      );

  /// Puts [way] through [nodeIds] instead of what it ran through before.
  void setWayNodes(OsmWay way, List<int> nodeIds) =>
      history._setWayNodes(way, nodeIds);

  /// Gives [relation] [members] in place of the ones it has.
  void setRelationMembers(OsmRelation relation, List<OsmMember> members) =>
      history._setRelationMembers(relation, members);

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
  }) =>
      history._moveNode(
        node,
        latitude: latitude,
        longitude: longitude,
        continuing: continuing,
      );

  /// Gives [element] [tags] in place of the ones it has, and says whether
  /// that changed anything.
  bool setTags(OsmElement element, Map<String, String> tags) =>
      history._setTags(element, tags);

  // What can be done to what is selected.

  /// Deleting [selected].
  OsmDeleteOperation delete(List<OsmElement> selected) =>
      OsmDeleteOperation(this, selected);

  /// Reversing [selected].
  OsmReverseOperation reverse(List<OsmElement> selected) =>
      OsmReverseOperation(this, selected);

  /// Pulling points out of [selected].
  OsmExtractOperation extract(List<OsmElement> selected) =>
      OsmExtractOperation(this, selected);

  /// Splitting lines at the nodes in [selected].
  OsmSplitOperation split(List<OsmElement> selected) =>
      OsmSplitOperation(this, selected);

  /// Merging [selected].
  OsmMergeOperation merge(List<OsmElement> selected) =>
      OsmMergeOperation(this, selected);

  /// Disconnecting [selected] from what it is joined to.
  OsmDisconnectOperation disconnect(List<OsmElement> selected) =>
      OsmDisconnectOperation(this, selected);

  /// Moving [selected] by ([worldDx], [worldDy]).
  ///
  /// The distances are in world coordinates, as [OsmMercator] gives them,
  /// not degrees: a drag on a map is the same distance on screen wherever
  /// it is made, and that is a distance in world coordinates.
  OsmMoveOperation move(
    List<OsmElement> selected, {
    required double worldDx,
    required double worldDy,
  }) =>
      OsmMoveOperation(this, selected, worldDx: worldDx, worldDy: worldDy);

  /// Copies [selected], or null if there is nothing in it to copy; see
  /// [OsmCopied]. [worldAnchor] is where the pointer was, in world
  /// coordinates, so that pasting puts the copies the same way round it.
  OsmCopied? copy(
    List<OsmElement> selected, {
    (double, double)? worldAnchor,
  }) =>
      osmCopy(this, selected, anchor: worldAnchor);

  /// Putting down what was [copied], moved by ([worldDx], [worldDy]) in
  /// world coordinates.
  OsmPasteOperation paste(
    OsmCopied copied, {
    required double worldDx,
    required double worldDy,
  }) =>
      OsmPasteOperation(this, copied, worldDx: worldDx, worldDy: worldDy);

  /// The lines that selecting [selected] would continue drawing, or null if
  /// the selection is not one a line is continued from.
  List<OsmWay>? continuable(List<OsmElement> selected) =>
      osmContinuable(this, selected);

  /// Making [nodes] one node, which every way and relation through any of
  /// them goes through.
  OsmConnectOperation connect(List<OsmNode> nodes) =>
      OsmConnectOperation(this, nodes);
}

/// A point in an [OsmEditor]'s history, from [OsmEditor.mark].
class OsmEditMark {
  final int _length;

  const OsmEditMark._(this._length);

  @override
  bool operator ==(Object other) =>
      other is OsmEditMark && other._length == _length;

  @override
  int get hashCode => _length.hashCode;
}
