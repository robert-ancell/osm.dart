import 'package:osm/osm.dart';
import 'package:test/test.dart';

/// A cut down index in the shape the editor layer index publishes.
const _index = '''
{
  "type": "FeatureCollection",
  "features": [
    {
      "type": "Feature",
      "properties": {
        "id": "LINZ_NZ_Aerial_Imagery",
        "name": "LINZ NZ Aerial Imagery",
        "type": "tms",
        "category": "photo",
        "best": true,
        "max_zoom": 21,
        "url": "https://linz.test/{zoom}/{x}/{y}.webp",
        "attribution": {"required": true, "text": "Sourced from LINZ CC-BY 4.0",
          "url": "https://linz.test/licence"}
      },
      "geometry": {
        "type": "Polygon",
        "coordinates": [[[166, -48], [179, -48], [179, -34], [166, -34],
          [166, -48]]]
      }
    },
    {
      "type": "Feature",
      "properties": {
        "id": "NZ_Older",
        "name": "Something older",
        "type": "tms",
        "category": "photo",
        "max_zoom": 18,
        "url": "https://older.test/{zoom}/{x}/{y}.png"
      },
      "geometry": {
        "type": "Polygon",
        "coordinates": [[[166, -48], [179, -48], [179, -34], [166, -34],
          [166, -48]]]
      }
    },
    {
      "type": "Feature",
      "properties": {
        "id": "Everywhere",
        "name": "The whole world",
        "type": "tms",
        "category": "photo",
        "max_zoom": 19,
        "url": "https://world.test/{zoom}/{x}/{y}.jpg"
      },
      "geometry": null
    },
    {
      "type": "Feature",
      "properties": {
        "id": "Labels",
        "name": "Names over the top",
        "type": "tms",
        "category": "map",
        "overlay": true,
        "url": "https://labels.test/{zoom}/{x}/{y}.png"
      },
      "geometry": null
    },
    {
      "type": "Feature",
      "properties": {
        "id": "SomeWms",
        "name": "Asked for another way",
        "type": "wms",
        "url": "https://wms.test/?bbox={bbox}"
      },
      "geometry": null
    }
  ]
}
''';

void main() {
  final index = OsmImageryIndex.parse(_index);

  test('reads the layers it can ask for by tile', () {
    expect(
      index.layers.map((layer) => layer.id),
      ['LINZ_NZ_Aerial_Imagery', 'NZ_Older', 'Everywhere', 'Labels'],
    );
  });

  test('leaves out the layers it cannot ask for by tile', () {
    expect(index.layers.map((layer) => layer.id), isNot(contains('SomeWms')));
  });

  test('reads what a layer says about itself', () {
    final linz = index.layers.first;
    expect(linz.name, 'LINZ NZ Aerial Imagery');
    expect(linz.category, OsmImageryCategory.photo);
    expect(linz.maximumZoom, 21);
    expect(linz.best, isTrue);
    expect(linz.overlay, isFalse);
    expect(linz.attribution, 'Sourced from LINZ CC-BY 4.0');
    expect(linz.attributionUrl, 'https://linz.test/licence');
  });

  test('offers only what covers the place asked about', () {
    final auckland = index.at(-36.85, 174.76);
    expect(auckland.map((layer) => layer.id),
        ['LINZ_NZ_Aerial_Imagery', 'Everywhere', 'NZ_Older']);

    final london = index.at(51.5, -0.12);
    expect(london.map((layer) => layer.id), ['Everywhere']);
  });

  test('offers the layer the index says is best first', () {
    expect(index.at(-36.85, 174.76).first.best, isTrue);
  });

  test('offers the closest in first among the rest', () {
    final rest = index.at(-36.85, 174.76).skip(1).toList();
    expect(rest.first.maximumZoom, greaterThan(rest.last.maximumZoom));
  });

  test('leaves out layers drawn over another unless asked for', () {
    expect(index.at(51.5, -0.12).map((l) => l.id), isNot(contains('Labels')));
    expect(
      index.at(51.5, -0.12, overlays: true).map((l) => l.id),
      contains('Labels'),
    );
  });

  test('offers only the category asked for', () {
    expect(
      index.at(51.5, -0.12, category: OsmImageryCategory.photo).single.id,
      'Everywhere',
    );
    expect(
      index.at(51.5, -0.12, category: OsmImageryCategory.elevation),
      isEmpty,
    );
  });

  test('takes a layer with no shape as covering the world', () {
    final everywhere =
        index.layers.firstWhere((layer) => layer.id == 'Everywhere');
    expect(everywhere.covers(-36.85, 174.76), isTrue);
    expect(everywhere.covers(64, -21), isTrue);
  });

  test('fills a tile into the address', () {
    expect(
      index.layers.first.tileUrl(17, 129167, 79983),
      'https://linz.test/17/129167/79983.webp',
    );
  });

  test('fills the other spellings the index uses', () {
    const layer = OsmImagery(
      id: 'x',
      name: 'x',
      url: 'https://{switch:a,b}.test/{z}/{x}/{-y}.png',
    );
    // Row three of eight counted from the north is row four from the south.
    expect(layer.tileUrl(3, 1, 3), 'https://a.test/3/1/4.png');
  });

  test('leaves out a hole in the ground a layer covers', () {
    final holed = OsmImageryIndex.parse('''
      {"type": "FeatureCollection", "features": [{"type": "Feature",
        "properties": {"id": "h", "name": "h", "type": "tms",
          "url": "https://h.test/{zoom}/{x}/{y}.png"},
        "geometry": {"type": "Polygon", "coordinates": [
          [[0,0],[10,0],[10,10],[0,10],[0,0]],
          [[4,4],[6,4],[6,6],[4,6],[4,4]]]}}]}
    ''').layers.single;
    expect(holed.covers(1, 1), isTrue);
    expect(holed.covers(5, 5), isFalse);
    expect(holed.covers(20, 20), isFalse);
  });

  test('reads a layer covering several separate places', () {
    final islands = OsmImageryIndex.parse('''
      {"type": "FeatureCollection", "features": [{"type": "Feature",
        "properties": {"id": "m", "name": "m", "type": "tms",
          "url": "https://m.test/{zoom}/{x}/{y}.png"},
        "geometry": {"type": "MultiPolygon", "coordinates": [
          [[[0,0],[2,0],[2,2],[0,2],[0,0]]],
          [[[8,8],[10,8],[10,10],[8,10],[8,8]]]]}}]}
    ''').layers.single;
    expect(islands.covers(1, 1), isTrue);
    expect(islands.covers(9, 9), isTrue);
    expect(islands.covers(5, 5), isFalse);
  });

  test('reads nothing from something that is not an index', () {
    expect(OsmImageryIndex.parse('{}').layers, isEmpty);
    expect(OsmImageryIndex.parse('[]').layers, isEmpty);
    expect(OsmImageryIndex.parse('{"features": "no"}').layers, isEmpty);
  });

  test('skips a layer missing what it needs', () {
    expect(
      OsmImageryIndex.parse('''
        {"features": [
          {"properties": {"type": "tms", "name": "no id",
            "url": "https://x.test/{zoom}/{x}/{y}.png"}},
          {"properties": {"id": "no url", "name": "n", "type": "tms"}},
          {"properties": null}
        ]}
      ''').layers,
      isEmpty,
    );
  });
}
