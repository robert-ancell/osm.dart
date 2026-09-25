import 'package:osm/osm.dart';
import 'package:osm/pbf.dart';
import 'package:test/test.dart';

/// The osm-testdata grid, and the same file filtered to `building=yes` by
/// another implementation, keeping the matching elements and everything they
/// refer to. See test/data/README.md.
const _gridPath = 'test/data/grid.osm.pbf';
const _gridBuildingsPath = 'test/data/grid-buildings.osm.pbf';

/// The grid cut to the box below by another implementation, with ways kept
/// whole, to check reading an area against it.
const _gridBoxPath = 'test/data/grid-box.osm.pbf';

/// The box that extract was taken with.
const _box = OsmBounds(
  minLatitude: 1.0,
  minLongitude: 7.0,
  maxLatitude: 1.5,
  maxLongitude: 7.5,
);

/// Data written for this package, and the same file filtered to `type=site`
/// by another implementation. The site relation has a relation of its
/// own in it, so completing it means following one relation into another.
const _elementsPath = 'test/data/elements.osm.pbf';
const _elementsSitesPath = 'test/data/elements-sites.osm.pbf';

Future<Map<OsmElementType, List<int>>> _idsOf(String path) async {
  final file = await OsmPbfFile.open(path);
  final ids = {for (final type in OsmElementType.values) type: <int>[]};
  await for (final element in file.elements()) {
    ids[element.type]!.add(element.id);
  }
  return ids;
}

Future<void> _expectSameAsReference(
  String path,
  OsmFilter filter,
  String expectedPath,
) async {
  final file = await OsmPbfFile.open(path);
  final subset = await file.subset(filter);
  final expected = await _idsOf(expectedPath);

  for (final (held, wanted) in [
    (subset.nodes.keys, expected[OsmElementType.node]!),
    (subset.ways.keys, expected[OsmElementType.way]!),
    (subset.relations.keys, expected[OsmElementType.relation]!),
  ]) {
    expect(held.toList()..sort(), wanted..sort());
  }
  expect(subset.matches, isNotEmpty);
}

void main() {
  test('holds what another implementation holds', () async {
    await _expectSameAsReference(
      _gridPath,
      const OsmFilter.tag('building', 'yes'),
      _gridBuildingsPath,
    );
  });

  test('follows a relation into a relation', () async {
    await _expectSameAsReference(
      _elementsPath,
      const OsmFilter.tag('type', 'site'),
      _elementsSitesPath,
    );
  });

  test('reads an area the way another implementation does', () async {
    final file = await OsmPbfFile.open(_gridPath);
    final subset = await file.within(const [_box]);
    final expected = await _idsOf(_gridBoxPath);

    expect(
      subset.nodes.keys.toList()..sort(),
      expected[OsmElementType.node]!..sort(),
    );
    expect(
      subset.ways.keys.toList()..sort(),
      expected[OsmElementType.way]!..sort(),
    );
    expect(
      subset.relations.keys.toList()..sort(),
      expected[OsmElementType.relation]!..sort(),
    );
  });

  test('reads an area of a file that does not say it is sorted', () async {
    // The grid says it is sorted and is read in one pass; this one does not,
    // so it is read once per type. Both have to give the same answer.
    final file = await OsmPbfFile.open(_elementsPath);
    expect(file.header.isSorted, isFalse);

    final subset = await file.within(const [
      OsmBounds(
        minLatitude: 0.5,
        minLongitude: 0.5,
        maxLatitude: 0.50025,
        maxLongitude: 0.50025,
      ),
    ]);

    // The building and the path, and the site relation over them.
    expect(subset.ways.keys.toList()..sort(), [42000801, 42000802]);
    expect(subset.relations.keys, contains(42000901));
    // Node 42000005 is outside the box, and the path reaching it keeps it.
    expect(subset.nodes.keys, contains(42000005));
    expect(subset.nodesOf(subset.ways[42000802]!), isNotNull);
  });

  test('keeps a way whose far end is outside the box', () async {
    final file = await OsmPbfFile.open(_gridPath);
    // A box cutting through the middle of one of the test cases rather than
    // falling between them, so that ways cross its edge.
    final subset = await file.within(const [
      OsmBounds(
        minLatitude: 1.0,
        minLongitude: 7.0,
        maxLatitude: 1.02,
        maxLongitude: 7.12,
      ),
    ]);

    var crossing = 0;
    for (final way in subset.ways.values) {
      final nodes = subset.nodesOf(way);
      expect(nodes, isNotNull, reason: 'way ${way.id} is missing nodes');
      if (nodes!.any((n) => n.longitude > 7.12 || n.latitude > 1.02)) {
        crossing++;
      }
    }
    expect(crossing, greaterThan(0), reason: 'the box should cut some way');
  });

  test('takes nothing from a box with nothing in it', () async {
    final file = await OsmPbfFile.open(_gridPath);
    final subset = await file.within(const [
      OsmBounds(
        minLatitude: 40,
        minLongitude: 40,
        maxLatitude: 41,
        maxLongitude: 41,
      ),
    ]);
    expect(subset.matches, isEmpty);
    expect(subset.length, 0);
  });

  test('keeps the matches apart from what they refer to', () async {
    final file = await OsmPbfFile.open(_gridPath);
    final subset = await file.subset(const OsmFilter.tag('building', 'yes'));

    expect(
      subset.matches,
      everyElement(
        predicate<OsmElement>((e) => e.tags['building'] == 'yes'),
      ),
    );
    expect(subset.matches.length, lessThan(subset.length));
    for (final match in subset.matches) {
      expect(subset.element(match.type, match.id), same(match));
    }
  });

  test('resolves the nodes of a way in order', () async {
    final file = await OsmPbfFile.open(_elementsPath);
    final subset = await file.subset(const OsmFilter.tag('building', 'yes'));
    final way = subset.ways[42000801]!;

    final located = subset.nodesOf(way);
    expect(located, isNotNull);
    expect(located!.map((n) => n.id).toList(), way.nodeIds);
    expect(located.first.latitude, closeTo(0.5001, 1e-7));
  });

  test('resolves the members of a relation', () async {
    final file = await OsmPbfFile.open(_elementsPath);
    final subset = await file.subset(const OsmFilter.tag('type', 'site'));
    final relation = subset.relations[42000902]!;

    for (final member in relation.members) {
      expect(subset.memberOf(member), isNotNull);
    }
    expect(
      subset.memberOf(relation.members.last),
      isA<OsmRelation>().having((r) => r.id, 'id', 42000901),
    );
  });

  test('gives no nodes for a way it cannot complete', () {
    const way = OsmWay(id: 1, nodeIds: [10, 11]);
    const subset = OsmSubset(
      matches: [way],
      nodes: {10: OsmNode(id: 10, latitude: 0, longitude: 0)},
      ways: {1: way},
      relations: {},
    );
    expect(subset.nodesOf(way), isNull);
  });

  test('takes nothing when the filter matches nothing', () async {
    final file = await OsmPbfFile.open(_gridPath);
    final subset = await file.subset(const OsmFilter.tag('no:such:key'));
    expect(subset.matches, isEmpty);
    expect(subset.length, 0);
  });
}
