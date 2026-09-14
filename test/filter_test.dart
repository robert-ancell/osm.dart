import 'package:osm/osm.dart';
import 'package:test/test.dart';

/// The osm-testdata grid. See test/data/README.md.
const _path = 'test/data/grid.osm.pbf';

List<String> _names(List<OsmElement> elements) =>
    elements.map((e) => '${e.type.name}/${e.id}').toList();

/// The filters are checked against reading everything and filtering the
/// result, so skipping work can never quietly change what comes out. Both the
/// isolate and the calling isolate paths are checked, so they cannot drift
/// apart either.
Future<void> _expectSameAsFilteringAfterwards(OsmFilter filter) async {
  final file = await OsmPbfFile.open(_path);
  final everything = await file.elements().toList();
  final expected = _names(everything.where(filter.matches).toList());

  expect(_names(await file.elements(filter: filter, isolates: 1).toList()),
      expected);
  expect(_names(await file.elements(filter: filter, isolates: 4).toList()),
      expected);
  expect(expected, isNotEmpty, reason: 'the filter should match something');
}

void main() {
  test('matches a tag with a value', () async {
    await _expectSameAsFilteringAfterwards(
      const OsmFilter.tag('natural', 'water'),
    );
  });

  test('matches a tag with any value', () async {
    await _expectSameAsFilteringAfterwards(const OsmFilter.tag('landuse'));
  });

  test('matches a tag against a set of values', () async {
    await _expectSameAsFilteringAfterwards(
      const OsmFilter.tagIn('natural', {'water', 'wood'}),
    );
  });

  test('matches a type', () async {
    await _expectSameAsFilteringAfterwards(
      const OsmFilter.type(OsmElementType.way),
    );
  });

  test('matches anything tagged', () async {
    await _expectSameAsFilteringAfterwards(const OsmFilter.tagged());
  });

  test('matches every part of an and', () async {
    await _expectSameAsFilteringAfterwards(
      const OsmFilter.type(OsmElementType.way) & const OsmFilter.tag('landuse'),
    );
  });

  test('matches any part of an or', () async {
    await _expectSameAsFilteringAfterwards(
      const OsmFilter.tag('building') | const OsmFilter.tag('natural'),
    );
  });

  test('matches the negation of a filter', () async {
    await _expectSameAsFilteringAfterwards(
      const OsmFilter.tagged() & const OsmFilter.not(OsmFilter.tag('landuse')),
    );
  });

  test('matches a test written as code', () async {
    await _expectSameAsFilteringAfterwards(
      OsmFilter.where((e) => e is OsmWay && e.nodeIds.length > 5),
    );
  });

  test('takes nothing when no element carries the key', () async {
    final file = await OsmPbfFile.open(_path);
    final elements = await file
        .elements(filter: const OsmFilter.tag('no:such:key'))
        .toList();
    expect(elements, isEmpty);
  });

  test('takes everything when no filter is given', () async {
    final file = await OsmPbfFile.open(_path);
    expect(await file.elements().length, 968 + 261 + 97);
    expect(await file.elements(isolates: 4).length, 968 + 261 + 97);
  });

  test('rejects an isolate count below one', () async {
    final file = await OsmPbfFile.open(_path);
    expect(() => file.elements(isolates: 0), throwsArgumentError);
  });
}
