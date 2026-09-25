import 'dart:convert';

import 'package:osm/editor.dart';
import 'package:osm/osm.dart';
import 'package:test/test.dart';

/// A few presets in the schema's own form, enough to show each rule.
final _presets = jsonEncode({
  'point': {
    'tags': <String, String>{},
    'geometry': ['point', 'vertex'],
    'matchScore': 0.1,
  },
  'line': {
    'tags': <String, String>{},
    'geometry': ['line'],
    'matchScore': 0.1,
  },
  'area': {
    'tags': {'area': 'yes'},
    'geometry': ['area'],
    'matchScore': 0.1,
  },
  'amenity/cafe': {
    'tags': {'amenity': 'cafe'},
    'geometry': ['point', 'area'],
    'icon': 'maki-cafe',
  },
  'amenity/cafe/coffee_shop': {
    'tags': {'amenity': 'cafe', 'cuisine': 'coffee_shop'},
    'geometry': ['point', 'area'],
  },
  'amenity/cafe/hidden': {
    'tags': {'amenity': 'cafe'},
    'geometry': ['point'],
    'searchable': false,
  },
  'building': {
    'tags': {'building': '*'},
    'geometry': ['area'],
    'matchScore': 0.6,
  },
  'building/house': {
    'tags': {'building': 'house'},
    'geometry': ['area'],
  },
  'highway/residential': {
    'tags': {'highway': 'residential'},
    'geometry': ['line'],
  },
  'highway/pedestrian_area': {
    'tags': {'highway': 'pedestrian', 'area': 'yes'},
    'geometry': ['area'],
  },
  'highway/trunk_link': {
    'tags': {'highway': 'trunk_link'},
    'geometry': ['line'],
    'locationSet': {
      'include': ['Planet'],
      'exclude': ['us', 'ca'],
    },
  },
  'highway/trunk_link-US-CA': {
    'tags': {'highway': 'trunk_link'},
    'geometry': ['line'],
    'name': '{highway/trunk_link}',
    'locationSet': {
      'include': ['us', 'ca'],
    },
  },
  'barrier/wall': {
    'tags': {'barrier': 'wall'},
    'geometry': ['line', 'area'],
  },
  'leisure/park': {
    'tags': {'leisure': 'park'},
    'geometry': ['point', 'area'],
  },
  'leisure/track': {
    'tags': {'leisure': 'track'},
    'geometry': ['line', 'area'],
  },
  'shop/old': {
    'tags': {'shop': 'old'},
    'geometry': ['point'],
    'replacement': 'shop/new',
  },
  '@templates/poi': {
    'tags': {'@template': 'poi'},
    'geometry': ['point'],
    'searchable': false,
    'locationSet': {
      'include': ['Planet'],
      'exclude': ['Planet'],
    },
  },
});

final _translations = jsonEncode({
  'en': {
    'presets': {
      'categories': {
        'category-building': {'name': 'Buildings'},
      },
      'presets': {
        'point': {'name': 'Point'},
        'line': {'name': 'Line'},
        'area': {'name': 'Area'},
        'amenity/cafe': {'name': 'Cafe', 'terms': 'bistro,coffee, espresso'},
        'amenity/cafe/coffee_shop': {'name': 'Coffeehouse'},
        'amenity/cafe/hidden': {'name': 'Cafe'},
        'building': {'name': 'Building'},
        'building/house': {'name': 'House', 'aliases': 'Dwelling\nHome'},
        'highway/residential': {'name': 'Residential Road'},
        'highway/pedestrian_area': {'name': 'Pedestrian Area'},
        'highway/trunk_link': {'name': 'Trunk Link'},
        'barrier/wall': {'name': 'Wall'},
        'leisure/park': {'name': 'Park'},
        'leisure/track': {'name': 'Racetrack'},
        'shop/old': {'name': 'Old Shop'},
      },
    },
  },
});

final _categories = jsonEncode({
  'category-building': {
    'members': ['building', 'building/house', 'no/such/preset'],
  },
});

final _defaults = jsonEncode({
  'area': ['category-building', 'amenity/cafe', 'no/such/preset'],
  'point': ['amenity/cafe'],
});

final _all = OsmPresets.parse(
  presets: _presets,
  translations: _translations,
  categories: _categories,
  defaults: _defaults,
);

String _match(
  Map<String, String> tags,
  OsmGeometry geometry, {
  Set<String> here = const {},
}) =>
    _all.match(tags, geometry, here: here).id;

void main() {
  group('reading', () {
    test('takes names and search words from the translations', () {
      final cafe = _all.byId['amenity/cafe']!;
      expect(cafe.name, 'Cafe');
      expect(cafe.terms, ['bistro', 'coffee', 'espresso']);
      expect(cafe.icon, 'maki-cafe');
      expect(_all.byId['building/house']!.aliases, ['Dwelling', 'Home']);
    });

    test('lends a preset the words of the one it names', () {
      expect(_all.byId['highway/trunk_link-US-CA']!.name, 'Trunk Link');
    });

    test('takes what it adds and removes from its tags when not given', () {
      final house = _all.byId['building/house']!;
      expect(house.addTags, {'building': 'house'});
      expect(house.removeTags, {'building': 'house'});
    });

    test('reads the categories and what to offer first', () {
      final buildings = _all.categories['category-building']!;
      expect(buildings.name, 'Buildings');
      // Only what is there.
      expect(buildings.members, ['building', 'building/house']);
      expect(_all.defaults[OsmGeometry.area], [
        'category-building',
        'amenity/cafe',
      ]);
    });
  });

  group('matching', () {
    test('finds the preset tags say an element is', () {
      expect(_match({'amenity': 'cafe'}, OsmGeometry.point), 'amenity/cafe');
      expect(
        _match({'highway': 'residential', 'name': 'x'}, OsmGeometry.line),
        'highway/residential',
      );
    });

    test('prefers the preset that says more about the element', () {
      expect(
        _match(
            {'amenity': 'cafe', 'cuisine': 'coffee_shop'}, OsmGeometry.point),
        'amenity/cafe/coffee_shop',
      );
    });

    test('prefers an exact value to any value', () {
      expect(_match({'building': 'house'}, OsmGeometry.area), 'building/house');
      expect(_match({'building': 'shed'}, OsmGeometry.area), 'building');
    });

    test('prefers a preset that is offered to one that is not', () {
      expect(_match({'amenity': 'cafe'}, OsmGeometry.point), 'amenity/cafe');
    });

    test('only matches a preset that can take the shape', () {
      // A house is only ever an area.
      expect(_match({'building': 'house'}, OsmGeometry.point), 'point');
    });

    test('falls back to the plain preset for the shape', () {
      expect(_match({'foo': 'bar'}, OsmGeometry.line), 'line');
      expect(_match({}, OsmGeometry.area), 'area');
      expect(_match({}, OsmGeometry.vertex), 'point');
    });

    test('falls back even to a shape the schema has no preset for', () {
      final relation = _all.match({}, OsmGeometry.relation);
      expect(relation.id, 'relation');
      expect(relation.name, 'Relation');
    });
  });

  group('places', () {
    test('uses what is meant for everywhere when nowhere is known', () {
      expect(
        _match({'highway': 'trunk_link'}, OsmGeometry.line),
        'highway/trunk_link',
      );
    });

    test('uses what is meant for a place there', () {
      expect(
        _match({'highway': 'trunk_link'}, OsmGeometry.line, here: {'US'}),
        'highway/trunk_link-US-CA',
      );
    });

    test('never uses what is excluded from everywhere', () {
      expect(_match({'@template': 'poi'}, OsmGeometry.point), 'point');
    });
  });

  group('areas', () {
    test('takes a key with area presets as an area', () {
      expect(_all.isArea({'building': 'house'}), isTrue);
      expect(_all.isArea({'leisure': 'park'}), isTrue);
    });

    test('takes a key that says what a line is as a line', () {
      expect(_all.isArea({'highway': 'residential'}), isFalse);
      expect(_all.isArea({'barrier': 'wall'}), isFalse);
    });

    test('takes a value that is a line for its key as a line', () {
      // leisure=track can be drawn as a line, so a closed one is one.
      expect(_all.isArea({'leisure': 'track'}), isFalse);
    });

    test('goes by what the area tag says outright', () {
      expect(_all.isArea({'highway': 'pedestrian', 'area': 'yes'}), isTrue);
      expect(_all.isArea({'building': 'yes', 'area': 'no'}), isFalse);
    });

    test('sees past a lifecycle prefix', () {
      expect(_all.isArea({'disused:leisure': 'park'}), isTrue);
    });

    test('knows the lines that are areas and the values that are nothing', () {
      expect(_all.isArea({'waterway': 'dam'}), isTrue);
      expect(_all.isArea({'emergency': 'yes'}), isFalse);
    });

    test('takes something unknown as a line', () {
      expect(_all.isArea({'foo': 'bar'}), isFalse);
    });
  });

  group('changing what an element is', () {
    final cafe = _all.byId['amenity/cafe']!;
    final house = _all.byId['building/house']!;
    final building = _all.byId['building']!;
    final wall = _all.byId['barrier/wall']!;

    test('takes off what it was and puts on what it is to be', () {
      final tags = {'building': 'house', 'name': 'Mine', 'area': 'yes'};
      final now = cafe.applyTo(
        house.removeFrom(tags),
        OsmGeometry.area,
        _all,
      );
      expect(now, {'name': 'Mine', 'amenity': 'cafe'});
    });

    test('gives a preset of any value yes', () {
      expect(building.applyTo({}, OsmGeometry.area, _all), {
        'building': 'yes',
      });
    });

    test('keeps an area an area when its tags alone would not say so', () {
      // A wall can be a line, so a closed one needs telling it is an area.
      expect(wall.applyTo({}, OsmGeometry.area, _all), {
        'barrier': 'wall',
        'area': 'yes',
      });
      expect(wall.applyTo({}, OsmGeometry.line, _all), {'barrier': 'wall'});
    });
  });

  group('searching', () {
    List<String> find(String query, OsmGeometry geometry) => [
          for (final preset in _all.search(query, geometry)) preset.id,
        ];

    test('finds by name, the whole of it first', () {
      expect(find('cafe', OsmGeometry.point).first, 'amenity/cafe');
    });

    test('finds by the start of a name, whatever its case', () {
      expect(find('COFF', OsmGeometry.point).first, 'amenity/cafe/coffee_shop');
    });

    test('finds by the start of a word in a name', () {
      expect(find('road', OsmGeometry.line), ['highway/residential']);
    });

    test('finds by the other words a preset goes by', () {
      expect(find('espresso', OsmGeometry.point), ['amenity/cafe']);
      expect(find('dwell', OsmGeometry.area), ['building/house']);
    });

    test('finds only what can take the shape', () {
      // A house can only be an area; Coffeehouse, which can be a point,
      // is found for the word in its name.
      expect(find('house', OsmGeometry.area).first, 'building/house');
      expect(find('dwell', OsmGeometry.point), isEmpty);
    });

    test('leaves out what is not offered or has been replaced', () {
      expect(find('cafe', OsmGeometry.point),
          isNot(contains('amenity/cafe/hidden')));
      expect(find('old', OsmGeometry.point), isEmpty);
    });

    test('finds only what applies at the place', () {
      expect(find('trunk', OsmGeometry.line), ['highway/trunk_link']);
      expect(
        [
          for (final p in _all.search('trunk', OsmGeometry.line, here: {'ca'}))
            p.id
        ],
        ['highway/trunk_link-US-CA'],
      );
    });

    test('finds nothing for nothing', () {
      expect(find('  ', OsmGeometry.point), isEmpty);
    });
  });
}
