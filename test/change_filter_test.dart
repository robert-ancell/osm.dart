import 'package:osm/osm.dart';
import 'package:osm/pbf.dart';
import 'package:osm/src/sorted_id_set.dart';
import 'package:osm/src/update/change_filter.dart';
import 'package:osm/src/update/snapshot_index.dart';
import 'package:test/test.dart';

/// A snapshot of a small town: nodes 1 to 3, way 10 through them, relation 20
/// with way 10 in it.
OsmChangeFilter _filter() {
  final nodes = SortedIdSetBuilder()
    ..add(1)
    ..add(2)
    ..add(3);
  final ways = SortedIdSetBuilder()..add(10);
  final region = (OsmRegion()..add(-41.28, 174.77)).grow();
  return OsmChangeFilter(
    OsmSnapshotIndex(
      nodes: nodes.build(),
      ways: ways.build(),
      relations: {20},
      region: region,
    ),
  );
}

// Inside the town, and far away in London.
const _inside = (-41.28, 174.77);
const _outside = (51.5, -0.12);

OsmChange _node(
  OsmChangeAction action,
  int id,
  (double, double) at, {
  int version = 2,
}) =>
    OsmChange(
      action: action,
      type: OsmElementType.node,
      id: id,
      version: version,
      element: OsmNode(id: id, latitude: at.$1, longitude: at.$2),
    );

OsmChange _way(OsmChangeAction action, int id, List<int> nodes) => OsmChange(
      action: action,
      type: OsmElementType.way,
      id: id,
      version: 2,
      element: OsmWay(id: id, nodeIds: nodes),
    );

OsmChange _delete(OsmElementType type, int id) =>
    OsmChange(action: OsmChangeAction.delete, type: type, id: id, version: 9);

List<String> _kept(OsmChangeFilter filter) =>
    filter.kept.map((c) => '${c.action.name} ${c.type.name}/${c.id}').toList();

void main() {
  test('keeps a node made inside and drops one made outside', () {
    final filter = _filter()
      ..addAll([
        _node(OsmChangeAction.create, 100, _inside),
        _node(OsmChangeAction.create, 101, _outside),
      ]);
    expect(_kept(filter), ['create node/100']);
    expect(filter.edges.isEmpty, isTrue);
    expect(filter.seen, 2);
  });

  test('keeps a held node moved away, and says so', () {
    final filter = _filter()
      ..addAll([_node(OsmChangeAction.modify, 1, _outside)]);
    expect(_kept(filter), ['modify node/1']);
    expect(filter.edges.movedOutNodes, {1});
  });

  test('keeps a node moved in, and says so', () {
    final filter = _filter()
      ..addAll([_node(OsmChangeAction.modify, 500, _inside)]);
    expect(_kept(filter), ['modify node/500']);
    expect(filter.edges.movedInNodes, {500});
  });

  test('keeps a delete only for what the snapshot holds', () {
    final filter = _filter()
      ..addAll([
        _delete(OsmElementType.node, 2),
        _delete(OsmElementType.node, 999),
        _delete(OsmElementType.way, 10),
        _delete(OsmElementType.relation, 777),
      ]);
    expect(_kept(filter), ['delete node/2', 'delete way/10']);
  });

  test('keeps a way through a held node', () {
    final filter = _filter()
      ..addAll([
        _way(OsmChangeAction.create, 11, [1, 2]),
      ]);
    expect(_kept(filter), ['create way/11']);
    expect(filter.edges.isEmpty, isTrue);
  });

  test('sees nodes made in the same diff, whatever order it lists them in', () {
    final filter = _filter()
      ..addAll([
        _way(OsmChangeAction.create, 12, [100, 101]),
        _node(OsmChangeAction.create, 100, _inside),
        _node(OsmChangeAction.create, 101, _inside),
      ]);
    expect(_kept(filter), [
      'create node/100',
      'create node/101',
      'create way/12',
    ]);
    expect(filter.edges.isEmpty, isTrue);
  });

  test('says which nodes a way reaching past the edge is missing', () {
    final filter = _filter()
      ..addAll([
        _way(OsmChangeAction.create, 13, [3, 800, 801]),
      ]);
    expect(_kept(filter), ['create way/13']);
    expect(filter.edges.incompleteWays, {13});
    expect(filter.edges.missingNodes, {800, 801});
  });

  test('a missing node supplied by a later diff is no longer missing', () {
    final filter = _filter()
      ..addAll([
        _way(OsmChangeAction.create, 13, [3, 800]),
      ])
      ..addAll([_node(OsmChangeAction.modify, 800, _inside)]);
    expect(filter.edges.missingNodes, isEmpty);
  });

  test('judges what a way is missing by its newest version only', () {
    // In one hour: the way uses node 3, then node 3 is deleted and the way
    // is changed not to use it. Nodes are decided first, so the older version
    // of the way sees node 3 already gone.
    final filter = _filter()
      ..addAll([
        OsmChange(
          action: OsmChangeAction.modify,
          type: OsmElementType.way,
          id: 10,
          version: 2,
          element: const OsmWay(id: 10, nodeIds: [1, 2, 3]),
        ),
        _delete(OsmElementType.node, 3),
        OsmChange(
          action: OsmChangeAction.modify,
          type: OsmElementType.way,
          id: 10,
          version: 3,
          element: const OsmWay(id: 10, nodeIds: [1, 2]),
        ),
      ]);
    expect(filter.edges.missingNodes, isEmpty);
    expect(filter.edges.incompleteWays, isEmpty);
  });

  test('a way deleted in the end is missing nothing', () {
    final filter = _filter()
      ..addAll([
        _way(OsmChangeAction.create, 13, [3, 800]),
      ])
      ..addAll([_delete(OsmElementType.way, 13)]);
    expect(filter.edges.missingNodes, isEmpty);
  });

  test('goes back to a mark', () {
    final filter = _filter()
      ..addAll([_node(OsmChangeAction.create, 100, _inside)]);
    final mark = filter.mark();

    filter.addAll([
      _delete(OsmElementType.node, 1),
      _node(OsmChangeAction.modify, 2, _outside),
      _way(OsmChangeAction.create, 13, [3, 800]),
    ]);
    expect(filter.kept, hasLength(4));
    expect(filter.edges.isEmpty, isFalse);

    filter.restore(mark);
    expect(_kept(filter), ['create node/100']);
    expect(filter.seen, 1);
    expect(filter.edges.isEmpty, isTrue);
    // Node 1 is held again, so a way through it is kept.
    filter.addAll([
      _way(OsmChangeAction.create, 14, [1]),
    ]);
    expect(_kept(filter).last, 'create way/14');
  });

  test('drops a way that touches nothing held', () {
    final filter = _filter()
      ..addAll([
        _way(OsmChangeAction.create, 14, [900, 901]),
      ]);
    expect(_kept(filter), isEmpty);
  });

  test('keeps a held way moved away, and says so', () {
    final filter = _filter()
      ..addAll([
        _way(OsmChangeAction.modify, 10, [900, 901]),
      ]);
    expect(_kept(filter), ['modify way/10']);
    expect(filter.edges.movedOutWays, {10});
  });

  test('says when a way outside is changed to reach in', () {
    final filter = _filter()
      ..addAll([
        _way(OsmChangeAction.modify, 50, [900, 1]),
      ]);
    expect(_kept(filter), ['modify way/50']);
    expect(filter.edges.movedInWays, {50});
    expect(filter.edges.missingNodes, {900});
  });

  test('keeps a relation with a held member', () {
    final filter = _filter()
      ..addAll([
        const OsmChange(
          action: OsmChangeAction.create,
          type: OsmElementType.relation,
          id: 21,
          version: 1,
          element: OsmRelation(
            id: 21,
            members: [
              OsmMember(type: OsmElementType.way, ref: 10, role: 'outer'),
              OsmMember(type: OsmElementType.way, ref: 9999, role: 'outer'),
            ],
          ),
        ),
        const OsmChange(
          action: OsmChangeAction.create,
          type: OsmElementType.relation,
          id: 22,
          version: 1,
          element: OsmRelation(
            id: 22,
            members: [
              OsmMember(type: OsmElementType.node, ref: 9999, role: ''),
            ],
          ),
        ),
      ]);
    expect(_kept(filter), ['create relation/21']);
    // A relation's other members are not looked for.
    expect(filter.edges.isEmpty, isTrue);
  });

  test('something deleted and made again is held again', () {
    final filter = _filter()
      ..addAll([_delete(OsmElementType.node, 1)])
      ..addAll([
        _way(OsmChangeAction.create, 15, [1]),
      ]);
    expect(_kept(filter), ['delete node/1']);

    filter.addAll([_node(OsmChangeAction.create, 1, _inside, version: 3)]);
    filter.addAll([
      _way(OsmChangeAction.create, 16, [1]),
    ]);
    expect(_kept(filter).last, 'create way/16');
  });
}
