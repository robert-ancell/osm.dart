import 'element.dart';

/// OpenStreetMap data as it was read, looked up by id: what an editor
/// edits, laid over with its changes.
///
/// Whatever a program holds what it has read in implements this: a store of
/// tiles fetched from the API, a file read from disk, or a list of elements
/// ([OsmEditorData.of]). An editor never changes it; it keeps what has
/// been changed apart and lays it over the top.
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
