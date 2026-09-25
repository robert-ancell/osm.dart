import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:osm/osm.dart';
import 'package:test/test.dart';

/// A square of land from ([west], [south]) to ([east], [north]).
List<List<double>> _square(
  double west,
  double south,
  double east,
  double north,
) =>
    [
      [west, south],
      [east, south],
      [east, north],
      [west, north],
      [west, south],
    ];

/// A small world in country-coder's form: a country made of a mainland with
/// a lake in it and an island that is a part of it, inside a region.
final _borders = jsonEncode({
  'type': 'FeatureCollection',
  'features': [
    {
      'type': 'Feature',
      'properties': {
        'wikidata': 'Q1000',
        'm49': '009',
        'nameEn': 'Somewhere Region',
        'aliases': ['REGION'],
      },
      'geometry': null,
    },
    {
      'type': 'Feature',
      'properties': {
        'iso1A2': 'XA',
        'iso1A3': 'XAA',
        'iso1N3': '901',
        'wikidata': 'Q2000',
        'nameEn': 'Examplia',
        'groups': ['009'],
        'driveSide': 'left',
      },
      'geometry': null,
    },
    {
      'type': 'Feature',
      'properties': {
        'wikidata': 'Q2001',
        'nameEn': 'Examplia Mainland',
        'aliases': ['XA-MAIN'],
        'country': 'XA',
      },
      'geometry': {
        'type': 'Polygon',
        'coordinates': [
          _square(0, 0, 10, 10),
          // A lake, which is somewhere else's.
          _square(4, 4, 6, 6),
        ],
      },
    },
    {
      'type': 'Feature',
      'properties': {
        'wikidata': 'Q2002',
        'nameEn': 'Examplia Island',
        'country': 'XA',
      },
      'geometry': {
        'type': 'MultiPolygon',
        'coordinates': [
          [_square(20, 0, 22, 2)],
        ],
      },
    },
  ],
});

final _world = OsmCountryCoder.parse(_borders);

void main() {
  test('finds the land a place stands on', () {
    expect(_world.landAt(1, 1).map((c) => c.name), ['Examplia Mainland']);
    expect(_world.landAt(1, 21).map((c) => c.name), ['Examplia Island']);
  });

  test('finds nothing at sea, or in a hole in the land', () {
    expect(_world.landAt(1, 15), isEmpty);
    expect(_world.landAt(5, 5), isEmpty);
    expect(_world.codesAt(5, 5), isEmpty);
  });

  test('says which country a part of one is in', () {
    final country = _world.countryAt(1, 21)!;
    expect(country.name, 'Examplia');
    expect(country.iso, 'XA');
    expect(country.driveSide, 'left');
  });

  test('names every region a place is in, every way they are named', () {
    expect(_world.codesAt(1, 21), {
      'q2002',
      'xa',
      'xaa',
      '901',
      'q2000',
      '009',
      'q1000',
      'region',
    });
  });

  test('finds a country or region by any of its codes', () {
    for (final code in ['XA', 'xaa', '901', 'Q2000']) {
      expect(_world.byCode(code)?.name, 'Examplia', reason: code);
    }
    expect(_world.byCode('ZZ'), isNull);
  });

  test('says where a preset for the place applies', () {
    final here = _world.codesAt(1, 1);
    expect(
      const OsmLocationSet(include: {'xa'}).appliesAt(here),
      isTrue,
    );
    expect(
      const OsmLocationSet(include: {'q1000'}).appliesAt(here),
      isTrue,
    );
    expect(
      const OsmLocationSet(include: {'001'}, exclude: {'xa'}).appliesAt(here),
      isFalse,
    );
    expect(
      const OsmLocationSet(include: {'zz'}).appliesAt(here),
      isFalse,
    );
  });

  test('fetches the borders and keeps them', () async {
    final directory = Directory.systemTemp.createTempSync('countries');
    addTearDown(() => directory.deleteSync(recursive: true));
    final asked = <Uri>[];
    Future<Uint8List?> fetch(
      Uri uri, {
      Future<void>? abandon,
      void Function(Uint8List)? onLate,
    }) async {
      asked.add(uri);
      return Uint8List.fromList(utf8.encode(_borders));
    }

    final read =
        await OsmCountryCoderCache(directory: directory, fetch: fetch).read();
    expect(read!.countryAt(1, 1)!.name, 'Examplia');
    expect(asked.single.toString(), '${osmCountryCoderUrl}borders.json');

    asked.clear();
    await OsmCountryCoderCache(directory: directory, fetch: fetch).read();
    expect(asked, isEmpty);
  });
}
