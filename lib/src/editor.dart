part of 'edit.dart';

/// The data an [OsmEditor] edits, as it was read.
///
/// Whatever a program holds what it has read in implements this: a store of
/// tiles fetched from the API, a file read from disk, or a list of elements
/// ([OsmEditorData.of]). The editor never changes it; what has been changed
/// is kept in its [OsmEditHistory] and laid over the top.
abstract interface class OsmEditorData {
  /// Data holding [elements] and nothing else.
  factory OsmEditorData.of(Iterable<OsmElement> elements) = _ElementData;

  /// The node with [id] as it was read, or null if it is not held.
  OsmNode? node(int id);

  /// The way with [id] as it was read, or null if it is not held.
  OsmWay? way(int id);

  /// The relation with [id] as it was read, or null if it is not held.
  OsmRelation? relation(int id);

  /// The ids of the ways read that run through the node with [nodeId].
  Iterable<int> waysUsing(int nodeId);

  /// The ids of the relations read that list the element.
  Iterable<int> relationsUsing(OsmElementType type, int id);
}

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

  /// Creates an editor over [data], keeping its changes in [history], or in
  /// a new history if none is given, and deciding what tags mean by
  /// [rules].
  OsmEditor(
    this.data, {
    OsmEditHistory? history,
    this.rules = const OsmPlainTagRules(),
  }) : history = history ?? OsmEditHistory();

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

  /// Gathers everything done since [mark], a [OsmEditHistory.length] taken
  /// before it started, into one change to undo.
  ///
  /// For a run of changes made across several events, such as a line drawn
  /// a click at a time, where [group] cannot wrap them all.
  void combineSince(int mark) => history._combineSince(mark);

  /// Undoes everything done since [mark], a [OsmEditHistory.length] taken
  /// before it started: for giving up on something made a change at a time.
  ///
  /// Given up on rather than undone, so none of it can be redone.
  void undoSince(int mark) => history._undoSince(mark);

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

  /// Moves [node] to ([latitude], [longitude]); see
  /// [OsmEditHistory.moveNode] for [continuing].
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

  /// Moves [selected] by ([worldDx], [worldDy]), as one change.
  ///
  /// The distances are in world coordinates, as [OsmMercator] gives them,
  /// not degrees: a drag on a map is the same distance on screen wherever
  /// it is made, and that is a distance in world coordinates.
  void move(
    List<OsmElement> selected, {
    required double worldDx,
    required double worldDy,
  }) =>
      osmMove(this, selected, dx: worldDx, dy: worldDy);

  /// Copies [selected], or null if there is nothing in it to copy; see
  /// [OsmCopied]. [worldAnchor] is where the pointer was, in world
  /// coordinates, so that pasting puts the copies the same way round it.
  OsmCopied? copy(
    List<OsmElement> selected, {
    (double, double)? worldAnchor,
  }) =>
      osmCopy(this, selected, anchor: worldAnchor);

  /// Puts down what was [copied], moved by ([worldDx], [worldDy]) in world
  /// coordinates, as one change, and gives back what was made.
  List<OsmElement> paste(
    OsmCopied copied, {
    required double worldDx,
    required double worldDy,
  }) =>
      osmPaste(this, copied, dx: worldDx, dy: worldDy);

  /// The lines that selecting [selected] would continue drawing, or null if
  /// the selection is not one a line is continued from.
  List<OsmWay>? continuable(List<OsmElement> selected) =>
      osmContinuable(this, selected);

  /// Makes the nodes [ids] one node, which every way and relation through
  /// any of them goes through.
  void connect(List<int> ids) => osmConnect(this, ids);

  /// Why the nodes [ids] cannot be made one, or null if they can.
  OsmDisabledReason? connectDisabled(List<int> ids) =>
      osmConnectDisabled(this, ids);

  /// Turns [way] round, and whatever about it faces along it; see
  /// [osmReversedTags] for [oneway].
  void reverseWay(OsmWay way, {bool oneway = false}) =>
      osmReverseWay(this, way, oneway: oneway);
}

class _ElementData implements OsmEditorData {
  final _nodes = <int, OsmNode>{};
  final _ways = <int, OsmWay>{};
  final _relations = <int, OsmRelation>{};
  final _waysUsing = <int, List<int>>{};
  final _relationsUsing = <(OsmElementType, int), List<int>>{};

  _ElementData(Iterable<OsmElement> elements) {
    for (final element in elements) {
      switch (element) {
        case OsmNode():
          _nodes[element.id] = element;
        case OsmWay():
          _ways[element.id] = element;
          for (final node in element.nodeIds.toSet()) {
            (_waysUsing[node] ??= []).add(element.id);
          }
        case OsmRelation():
          _relations[element.id] = element;
          for (final member in element.members) {
            (_relationsUsing[(member.type, member.ref)] ??= []).add(element.id);
          }
      }
    }
  }

  @override
  OsmNode? node(int id) => _nodes[id];

  @override
  OsmWay? way(int id) => _ways[id];

  @override
  OsmRelation? relation(int id) => _relations[id];

  @override
  Iterable<int> waysUsing(int nodeId) => _waysUsing[nodeId] ?? const [];

  @override
  Iterable<int> relationsUsing(OsmElementType type, int id) =>
      _relationsUsing[(type, id)] ?? const [];
}
