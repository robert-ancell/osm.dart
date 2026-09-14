import 'dart:convert';
import 'dart:io';

import 'package:osm/osm.dart';
import 'package:test/test.dart';

/// The whole osm-testdata grid, of which `grid/data/7` is the multipolygon
/// geometry tests. See test/data/README.md.
const _dataPath = 'test/data/grid.osm.pbf';

/// The `areas.default` expectations from each test case's `test.json`.
const _expectationsPath = 'test/data/multipolygon-tests.json';

/// A ring in the form two implementations can be compared in: no repeated
/// closing point, wound counter-clockwise, and started at its lowest point.
/// Winding and start point are conventions, not geometry, and are checked on
/// their own in the area tests.
String _canonicalRing(List<(double, double)> points) {
  var ring = points.toList();
  if (ring.length > 1 && ring.first == ring.last) ring.removeLast();
  if (ring.isEmpty) return '';
  ring = _withoutCollinear(ring);

  var twiceArea = 0.0;
  for (var i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    twiceArea += (ring[j].$1 - ring[i].$1) * (ring[j].$2 + ring[i].$2);
  }
  if (twiceArea < 0) ring = ring.reversed.toList();

  final text = ring
      .map((p) => '${p.$1.toStringAsFixed(7)} ${p.$2.toStringAsFixed(7)}')
      .toList();
  var start = 0;
  for (var i = 1; i < text.length; i++) {
    if (text[i].compareTo(text[start]) < 0) start = i;
  }
  return [...text.skip(start), ...text.take(start)].join(',');
}

/// Drops points that lie on the line between their neighbours.
///
/// A node where two rings touch is a real point of the geometry but it does
/// not change its shape, and osm-testdata's own expectations keep it in some
/// cases and drop it in others. Comparing shapes rather than vertex lists is
/// what the suite is actually specifying.
List<(double, double)> _withoutCollinear(List<(double, double)> ring) {
  final kept = <(double, double)>[];
  for (var i = 0; i < ring.length; i++) {
    final before = ring[(i - 1 + ring.length) % ring.length];
    final here = ring[i];
    final after = ring[(i + 1) % ring.length];
    final cross = (here.$1 - before.$1) * (after.$2 - before.$2) -
        (here.$2 - before.$2) * (after.$1 - before.$1);
    if (cross.abs() > 1e-12) kept.add(here);
  }
  return kept.isEmpty ? ring : kept;
}

String _canonicalArea(
    List<(List<(double, double)>, List<List<(double, double)>>)> polygons) {
  final parts = polygons.map((polygon) {
    final inners = polygon.$2.map(_canonicalRing).toList()..sort();
    return '(${_canonicalRing(polygon.$1)})[${inners.join('][')}]';
  }).toList()
    ..sort();
  return parts.join(' ');
}

String _canonicalOsmArea(OsmArea area) => _canonicalArea([
      for (final polygon in area.polygons)
        (
          [for (final n in polygon.outer) (n.longitude, n.latitude)],
          [
            for (final inner in polygon.inners)
              [for (final n in inner) (n.longitude, n.latitude)],
          ],
        ),
    ]);

/// Reads the polygons out of a WKT `MULTIPOLYGON` or `POLYGON`.
String _canonicalWkt(String wkt) {
  final body = wkt.substring(wkt.indexOf('(') + 1, wkt.lastIndexOf(')'));
  final polygons =
      wkt.startsWith('MULTIPOLYGON') ? _split(body) : <String>[body];
  return _canonicalArea([
    for (final polygon in polygons)
      () {
        final rings = _split(polygon).map(_points).toList();
        return (rings.first, rings.skip(1).toList());
      }(),
  ]);
}

/// Splits a WKT body on the commas between bracketed groups.
List<String> _split(String body) {
  final parts = <String>[];
  var depth = 0;
  var start = 0;
  for (var i = 0; i < body.length; i++) {
    switch (body[i]) {
      case '(':
        if (depth++ == 0) start = i + 1;
      case ')':
        if (--depth == 0) parts.add(body.substring(start, i));
    }
  }
  return parts;
}

List<(double, double)> _points(String ring) => [
      for (final point in ring.split(','))
        () {
          final parts = point.trim().split(RegExp(r'\s+'));
          return (double.parse(parts[0]), double.parse(parts[1]));
        }(),
    ];

/// The cases that do not come out the way osm-testdata says they should.
///
/// All three are the same shape: two outer rings and two inner rings, the
/// inners touching each other at two nodes. The ground that comes out is
/// right, but the pocket between the touching inners is reported both as part
/// of the outline it sits in and as a polygon of its own, where osmium reports
/// one hole around the pair and the pocket separately. Anything drawing this
/// paints the pocket twice.
///
/// Asserted rather than skipped: a change that fixes one of these, or breaks
/// one of the other 78, has to be a deliberate edit to this list.
const _known = {'777', '778', '779'};

void main() {
  late OsmSubset data;
  late List<Map<String, dynamic>> expectations;

  setUpAll(() async {
    final file = await OsmPbfFile.open(_dataPath);
    final nodes = <int, OsmNode>{};
    final ways = <int, OsmWay>{};
    final relations = <int, OsmRelation>{};
    await for (final element in file.elements()) {
      switch (element) {
        case OsmNode():
          nodes[element.id] = element;
        case OsmWay():
          ways[element.id] = element;
        case OsmRelation():
          relations[element.id] = element;
      }
    }
    data = OsmSubset(
      matches: const [],
      nodes: nodes,
      ways: ways,
      relations: relations,
    );
    expectations =
        (jsonDecode(File(_expectationsPath).readAsStringSync()) as List)
            .cast<Map<String, dynamic>>();
  });

  test('the test data is all there', () {
    expect(expectations, hasLength(81));
    expect(data.nodes, hasLength(968));
    expect(data.ways, hasLength(261));
    expect(data.relations, hasLength(97));
  });

  test('assembles the areas osm-testdata says are valid', () {
    final failures = <String>[];
    var checked = 0;

    for (final expectation in expectations) {
      final wkt = expectation['wkt'] as String;
      if (wkt == 'INVALID') continue;

      final type = expectation['type'] == 'way'
          ? OsmElementType.way
          : OsmElementType.relation;
      final element = data.element(type, expectation['id'] as int);
      if (element == null) {
        failures.add('${expectation['test']}: no ${expectation['type']} '
            '${expectation['id']} in the data');
        continue;
      }

      checked++;
      final area = data.areaOf(element);
      final got = area == null ? 'nothing' : _canonicalOsmArea(area);
      final want = _canonicalWkt(wkt);
      if (got != want) {
        failures.add('${expectation['test']}: ${expectation['description']}\n'
            '    want $want\n    got  $got');
      }
    }

    expect(checked, greaterThan(40));
    expect(
      failures.map((f) => f.substring(0, 3)).toSet(),
      _known,
      reason: 'Assembly changed. Failures:\n${failures.join('\n')}',
    );
  });

  test('says nothing rather than throwing on the invalid ones', () {
    for (final expectation in expectations) {
      if (expectation['wkt'] != 'INVALID') continue;
      final type = expectation['type'] == 'way'
          ? OsmElementType.way
          : OsmElementType.relation;
      final element = data.element(type, expectation['id'] as int);
      if (element == null) continue;
      // What a reader does with invalid data is not specified. Not crashing
      // and not hanging is the whole requirement.
      expect(() => data.areaOf(element), returnsNormally,
          reason: '${expectation['test']}: ${expectation['description']}');
    }
  });
}
