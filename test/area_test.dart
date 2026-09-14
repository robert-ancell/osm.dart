import 'package:osm/osm.dart';
import 'package:test/test.dart';

/// Nodes on a grid, so the shapes below read as the shapes they are.
final _nodes = <int, OsmNode>{};

OsmNode _node(int id, double longitude, double latitude) =>
    _nodes[id] = OsmNode(id: id, latitude: latitude, longitude: longitude);

OsmSubset _subset(List<OsmWay> ways,
        [List<OsmRelation> relations = const []]) =>
    OsmSubset(
      matches: const [],
      nodes: _nodes,
      ways: {for (final way in ways) way.id: way},
      relations: {for (final r in relations) r.id: r},
    );

List<(double, double)> _shape(List<OsmNode> ring) =>
    [for (final n in ring) (n.longitude, n.latitude)];

void main() {
  setUp(_nodes.clear);

  test('a closed way is one polygon', () {
    _node(1, 0, 0);
    _node(2, 2, 0);
    _node(3, 2, 2);
    _node(4, 0, 2);
    const way = OsmWay(id: 10, nodeIds: [1, 2, 3, 4, 1]);

    final area = _subset([way]).areaOf(way);
    expect(area, isNotNull);
    expect(area!.polygons, hasLength(1));
    expect(area.polygons.single.inners, isEmpty);
    expect(_shape(area.polygons.single.outer), [
      (0.0, 0.0),
      (2.0, 0.0),
      (2.0, 2.0),
      (0.0, 2.0),
      (0.0, 0.0),
    ]);
  });

  test('an outline comes back counter-clockwise however it was drawn', () {
    _node(1, 0, 0);
    _node(2, 2, 0);
    _node(3, 2, 2);
    _node(4, 0, 2);
    const clockwise = OsmWay(id: 10, nodeIds: [1, 4, 3, 2, 1]);

    final area = _subset([clockwise]).areaOf(clockwise);
    expect(_shape(area!.polygons.single.outer), [
      (0.0, 0.0),
      (2.0, 0.0),
      (2.0, 2.0),
      (0.0, 2.0),
      (0.0, 0.0),
    ]);
  });

  test('a relation with an inner ring gives a hole, wound the other way', () {
    _node(1, 0, 0);
    _node(2, 6, 0);
    _node(3, 6, 6);
    _node(4, 0, 6);
    _node(5, 2, 2);
    _node(6, 4, 2);
    _node(7, 4, 4);
    _node(8, 2, 4);
    const outer = OsmWay(id: 10, nodeIds: [1, 2, 3, 4, 1]);
    const inner = OsmWay(id: 11, nodeIds: [5, 6, 7, 8, 5]);
    const relation = OsmRelation(
      id: 20,
      members: [
        OsmMember(type: OsmElementType.way, ref: 10, role: 'outer'),
        OsmMember(type: OsmElementType.way, ref: 11, role: 'inner'),
      ],
      tags: {'type': 'multipolygon'},
    );

    final area = _subset([outer, inner], [relation]).areaOf(relation);
    expect(area!.polygons, hasLength(1));
    final polygon = area.polygons.single;
    expect(polygon.outer.first.id, 1);
    expect(polygon.inners, hasLength(1));
    // Clockwise, which is the reverse of the order the way was drawn in.
    expect(_shape(polygon.inners.single), [
      (2.0, 2.0),
      (2.0, 4.0),
      (4.0, 4.0),
      (4.0, 2.0),
      (2.0, 2.0),
    ]);
  });

  test('the roles are not what decides which ring is the hole', () {
    _node(1, 0, 0);
    _node(2, 6, 0);
    _node(3, 6, 6);
    _node(4, 0, 6);
    _node(5, 2, 2);
    _node(6, 4, 2);
    _node(7, 4, 4);
    _node(8, 2, 4);
    const big = OsmWay(id: 10, nodeIds: [1, 2, 3, 4, 1]);
    const small = OsmWay(id: 11, nodeIds: [5, 6, 7, 8, 5]);
    // Roles the wrong way round, which real data is full of.
    const relation = OsmRelation(
      id: 20,
      members: [
        OsmMember(type: OsmElementType.way, ref: 10, role: 'inner'),
        OsmMember(type: OsmElementType.way, ref: 11, role: 'outer'),
      ],
    );

    final area = _subset([big, small], [relation]).areaOf(relation);
    expect(area!.polygons, hasLength(1));
    expect(area.polygons.single.outer.first.id, 1);
    expect(area.polygons.single.inners, hasLength(1));
  });

  test('a way that is not closed is not an area', () {
    _node(1, 0, 0);
    _node(2, 2, 0);
    _node(3, 2, 2);
    const open = OsmWay(id: 10, nodeIds: [1, 2, 3]);
    expect(_subset([open]).areaOf(open), isNull);
  });

  test('an area with a node missing is no area at all', () {
    _node(1, 0, 0);
    _node(2, 2, 0);
    _node(3, 2, 2);
    const way = OsmWay(id: 10, nodeIds: [1, 2, 3, 4, 1]);
    expect(_subset([way]).areaOf(way), isNull);
  });

  test('a node covers no ground', () {
    final node = _node(1, 0, 0);
    expect(_subset(const []).areaOf(node), isNull);
  });

  test('assembles the areas of a file', () async {
    final file = await OsmPbfFile.open('test/data/grid.osm.pbf');
    final subset =
        await file.subset(const OsmFilter.tag('type', 'multipolygon'));

    var assembled = 0;
    for (final match in subset.matches) {
      final area = subset.areaOf(match);
      if (area == null) continue;
      assembled++;
      for (final polygon in area.polygons) {
        expect(polygon.outer.length, greaterThanOrEqualTo(4));
        expect(polygon.outer.first.id, polygon.outer.last.id);
      }
    }
    expect(assembled, greaterThan(50));
  });
}
