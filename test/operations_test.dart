import 'package:osm/editor.dart';
import 'package:osm/osm.dart';
import 'package:test/test.dart';

import 'test_editor.dart';

/// A road of three nodes, west to east, with a side road off its middle.
OsmEditor _roads({List<OsmRelation> relations = const []}) => testEditor(
      nodes: [
        testNode(1, 0, 0),
        testNode(2, 0, 0.001, {'highway': 'crossing'}),
        testNode(3, 0, 0.002),
        testNode(4, 0.001, 0.001),
      ],
      ways: [
        testWay(10, [1, 2, 3], {'highway': 'residential'}),
        testWay(11, [2, 4], {'highway': 'service'}),
      ],
      relations: relations,
    );

void main() {
  group('deleting', () {
    test('deletes a way and the nodes only it used', () {
      final view = _roads();
      OsmDeleteOperation(view, [view.way(11)!]).apply();
      expect(view.way(11), isNull);
      // Its far end goes; the node it shares with the road stays.
      expect(view.node(4), isNull);
      expect(view.node(2), isNotNull);
      expect(view.history.length, 1);
    });

    test('keeps a node of a deleted way that says something', () {
      final view = testEditor(
        nodes: [
          testNode(1, 0, 0),
          testNode(2, 0, 0.001, {'barrier': 'gate'}),
        ],
        ways: [
          testWay(10, [1, 2], {'highway': 'track'}),
        ],
      );
      OsmDeleteOperation(view, [view.way(10)!]).apply();
      expect(view.node(1), isNull);
      expect(view.node(2), isNotNull);
    });

    test('keeps a node of a deleted way that only says where it came from', () {
      final view = testEditor(
        nodes: [
          testNode(1, 0, 0, {'source': 'survey'}),
          testNode(2, 0, 0.001),
        ],
        ways: [
          testWay(10, [1, 2], {'highway': 'track'}),
        ],
      );
      OsmDeleteOperation(view, [view.way(10)!]).apply();
      // Where it came from is nothing of its own: it goes with the way.
      expect(view.node(1), isNull);
    });

    test('deletes a way a node going leaves too short', () {
      final view = _roads();
      OsmDeleteOperation(view, [view.node(4)!]).apply();
      expect(view.way(11), isNull);
      expect(view.way(10), isNotNull);
    });

    test('deletes a relation left with no members', () {
      final view = testEditor(
        nodes: [testNode(1, 0, 0)],
        relations: [
          const OsmRelation(
            id: 20,
            members: [OsmMember(type: OsmElementType.node, ref: 1, role: '')],
            info: OsmInfo(version: 1),
          ),
        ],
      );
      OsmDeleteOperation(view, [view.node(1)!]).apply();
      expect(view.relation(20), isNull);
      expect(view.history.deletedRelations, contains(20));
    });

    test('will not delete part of a route or a boundary', () {
      for (final type in ['route', 'boundary']) {
        final view = _roads(relations: [
          OsmRelation(
            id: 30,
            members: const [
              OsmMember(type: OsmElementType.way, ref: 10, role: ''),
            ],
            tags: {'type': type},
          ),
        ]);
        expect(
          OsmDeleteOperation(view, [view.way(10)!]).disabled,
          OsmStandardTagRules.partOfRelation,
          reason: type,
        );
      }
    });

    test('will not delete the outside of a multipolygon, but will a hole', () {
      OsmRelation multipolygon(String role) => OsmRelation(
            id: 30,
            members: [OsmMember(type: OsmElementType.way, ref: 10, role: role)],
            tags: const {'type': 'multipolygon'},
          );
      final outer = _roads(relations: [multipolygon('outer')]);
      expect(OsmDeleteOperation(outer, [outer.way(10)!]).disabled,
          OsmStandardTagRules.partOfRelation);
      final unroled = _roads(relations: [multipolygon('')]);
      expect(
        OsmDeleteOperation(unroled, [unroled.way(10)!]).disabled,
        OsmStandardTagRules.partOfRelation,
      );
      final inner = _roads(relations: [multipolygon('inner')]);
      expect(OsmDeleteOperation(inner, [inner.way(10)!]).disabled, isNull);
    });

    test('will not delete something with a Wikidata tag', () {
      final view = testEditor(nodes: [
        testNode(1, 0, 0, {'wikidata': 'Q1'})
      ]);
      expect(OsmDeleteOperation(view, [view.node(1)!]).disabled,
          OsmStandardTagRules.hasWikidataTag);
    });

    test('undoes a deletion as one change', () {
      final view = _roads();
      OsmDeleteOperation(view, [view.way(11)!, view.node(1)!]).apply();
      view.undo();
      expect(view.history.isEmpty, isTrue);
      expect(view.way(11), isNotNull);
      expect(view.node(4), isNotNull);
    });
  });

  group('reversing', () {
    test('turns a line round, and its tags with it', () {
      final view = testEditor(
        nodes: [testNode(1, 0, 0), testNode(2, 0, 0.001)],
        ways: [
          testWay(10, [
            1,
            2
          ], {
            'highway': 'residential',
            'oneway': 'yes',
            'sidewalk:left': 'yes',
            'incline': '5%',
            'name': 'Left Street',
            'turn:lanes:forward': 'left|through',
          }),
        ],
      );
      OsmReverseOperation(view, [view.way(10)!]).apply();
      final way = view.way(10)!;
      expect(way.nodeIds, [2, 1]);
      expect(way.tags, {
        'highway': 'residential',
        // What reversing is usually for, so left as it is.
        'oneway': 'yes',
        'sidewalk:right': 'yes',
        'incline': '-5%',
        'name': 'Left Street',
        'turn:lanes:backward': 'left|through',
      });
      expect(view.history.length, 1);
    });

    test('turns round the nodes along a line, but not their bearings', () {
      final view = testEditor(
        nodes: [
          testNode(1, 0, 0, {'direction': 'forward', 'highway': 'stop'}),
          testNode(2, 0, 0.001, {'direction': 'N'}),
        ],
        ways: [
          testWay(10, [1, 2], {'highway': 'residential'}),
        ],
      );
      OsmReverseOperation(view, [view.way(10)!]).apply();
      expect(view.node(1)!.tags['direction'], 'backward');
      expect(view.node(2)!.tags['direction'], 'N');
    });

    test('turns a node on its own right round', () {
      final view = testEditor(
        nodes: [
          testNode(1, 0, 0, {'direction': '90'}),
          testNode(2, 0, 0, {'direction': 'NE;190'}),
        ],
      );
      OsmReverseOperation(view, [view.node(1)!, view.node(2)!]).apply();
      expect(view.node(1)!.tags['direction'], '270');
      expect(view.node(2)!.tags['direction'], 'SW;10');
    });

    test('turns round a line going forward or backward in a route', () {
      final view = _roads(relations: const [
        OsmRelation(
          id: 30,
          members: [
            OsmMember(type: OsmElementType.way, ref: 10, role: 'forward'),
          ],
          tags: {'type': 'route'},
        ),
      ]);
      OsmReverseOperation(view, [view.way(10)!]).apply();
      expect(view.relation(30)!.members.single.role, 'backward');
    });

    test('has nothing to reverse in an area or a node with no direction', () {
      final view = testEditor(
        nodes: [
          testNode(1, 0, 0),
          testNode(2, 0, 1),
          testNode(3, 1, 1),
          testNode(4, 5, 5, {'amenity': 'bench'}),
        ],
        ways: [
          testWay(10, [1, 2, 3, 1], {'building': 'yes'}),
        ],
      );
      expect(OsmReverseOperation(view, [view.way(10)!]).available, isFalse);
      expect(OsmReverseOperation(view, [view.node(4)!]).available, isFalse);
    });

    test('says what it reverses', () {
      final view = testEditor(
        nodes: [
          testNode(1, 0, 0),
          testNode(2, 0, 0.001),
          testNode(3, 5, 5, {'direction': 'N'}),
        ],
        ways: [
          testWay(10, [1, 2], {'highway': 'residential'}),
        ],
      );
      expect(view.reverse([view.way(10)!]).reversible, [view.way(10)]);
      expect(view.reverse([view.node(3)!]).reversible, [view.node(3)]);
      expect(
        view.reverse([view.way(10)!, view.node(3)!]).reversible,
        hasLength(2),
      );
    });
  });

  group('extracting', () {
    test('takes a tagged node out of its lines, leaving another there', () {
      final view = _roads();
      final points = OsmExtractOperation(view, [view.node(2)!]).apply();
      expect(points.single.id, 2);
      expect(view.waysUsing(2), isEmpty);
      final road = view.way(10)!;
      final replacement = view.node(road.nodeIds[1])!;
      expect(replacement.id, isNegative);
      expect(replacement.tags, isEmpty);
      expect(replacement.latitude, view.node(2)!.latitude);
      // The side road is on the replacement too, still joined to the road.
      expect(view.way(11)!.nodeIds.first, replacement.id);
      expect(view.history.length, 1);
    });

    test('has nothing to take out of an untagged node or one on its own', () {
      final view = _roads();
      expect(OsmExtractOperation(view, [view.node(1)!]).available, isFalse);
      final alone = testEditor(nodes: [
        testNode(1, 0, 0, {'amenity': 'bench'})
      ]);
      expect(OsmExtractOperation(alone, [alone.node(1)!]).available, isFalse);
    });

    group('from an area', () {
      final presets = OsmPresets.parse(
        presets: '''{
          "shop/bakery": {"tags": {"shop": "bakery"}, "geometry": ["point", "area"]},
          "building": {"tags": {"building": "*"}, "geometry": ["area"]}
        }''',
        translations: '{"en": {"presets": {"presets": {}}}}',
      );

      OsmEditor shop(Map<String, String> tags) => testEditor(
            nodes: [
              testNode(1, 0, 0),
              testNode(2, 0, 0.002),
              testNode(3, 0.002, 0.002),
              testNode(4, 0.002, 0),
            ],
            ways: [
              testWay(10, [1, 2, 3, 4, 1], tags),
            ],
          );

      test('moves what it is onto a point in the middle, keeping the rest', () {
        final view = shop({
          'building': 'retail',
          'building:levels': '2',
          'shop': 'bakery',
          'name': 'Crust',
          'addr:street': 'Queen Street',
        });
        final point = _extract(view, presets).apply().single;
        expect(point.tags, {
          'shop': 'bakery',
          'name': 'Crust',
          'addr:street': 'Queen Street',
        });
        expect(view.way(10)!.tags, {
          'building': 'retail',
          'building:levels': '2',
          'addr:street': 'Queen Street',
        });
        expect(point.latitude, closeTo(0.001, 1e-6));
        expect(point.longitude, closeTo(0.001, 1e-6));
      });

      test('keeps an area that is not a building an area', () {
        final view = shop({'shop': 'bakery', 'area': 'yes'});
        _extract(view, presets).apply();
        expect(view.way(10)!.tags, {'area': 'yes'});
      });

      test('takes nothing out of what can only be an area', () {
        final view = shop({'building': 'yes'});
        expect(
          _extract(view, presets).available,
          isFalse,
        );
      });

      test('takes nothing out of a way when the kinds are not known', () {
        final view = shop({'shop': 'bakery', 'area': 'yes'});
        expect(OsmExtractOperation(view, [view.way(10)!]).available, isFalse);
      });
    });
  });

  group('continuing', () {
    test('finds the line a selected end continues', () {
      final view = _roads();
      expect(
        view.continuable([view.node(3)!])!.map((w) => w.id),
        [10],
      );
    });

    test('finds nothing to continue from the middle of a line', () {
      final view = testEditor(
        nodes: [testNode(1, 0, 0), testNode(2, 0, 1), testNode(3, 0, 2)],
        ways: [
          testWay(10, [1, 2, 3])
        ],
      );
      expect(view.continuable([view.node(2)!]), isEmpty);
    });

    test('finds every line that ends there, and one when one is chosen', () {
      final view = testEditor(
        nodes: [testNode(1, 0, 0), testNode(2, 0, 1), testNode(3, 1, 1)],
        ways: [
          testWay(10, [1, 2]),
          testWay(11, [2, 3])
        ],
      );
      expect(view.continuable([view.node(2)!]), hasLength(2));
      expect(
        view.continuable([view.node(2)!, view.way(11)!])!.map((w) => w.id),
        [11],
      );
    });

    test('is not something to ask of anything but one vertex', () {
      final view = _roads();
      expect(view.continuable([view.way(10)!]), isNull);
      expect(view.continuable([view.node(1)!, view.node(3)!]), isNull);
    });
  });

  group('copying and pasting', () {
    test('copies a way with its nodes, and pastes it somewhere else', () {
      final view = _roads();
      final copied = view.copy([view.way(11)!], worldAnchor: (0.5, 0.5))!;
      expect(copied.length, 1);
      expect(copied.nodes.keys, containsAll([2, 4]));
      final pasted = view.paste(copied, worldDx: 0.001, worldDy: 0).apply();
      final way = pasted.single as OsmWay;
      expect(way.id, isNegative);
      expect(way.tags, {'highway': 'service'});
      final start = view.node(way.nodeIds.first)!;
      expect(start.id, isNegative);
      // What the node said comes too.
      expect(start.tags, {'highway': 'crossing'});
      expect(
        OsmMercator.x(start.longitude),
        closeTo(OsmMercator.x(view.node(2)!.longitude) + 0.001, 1e-12),
      );
      expect(view.history.length, 1);
    });

    test('leaves out an untagged node of a way copied with it', () {
      final view = _roads();
      final copied = view.copy([view.way(10)!, view.node(1)!])!;
      expect(copied.elements.map((e) => e.id), [10]);
    });

    test('anchors a single node by itself', () {
      final view = testEditor(nodes: [
        testNode(1, 0, 0, {'amenity': 'bench'})
      ]);
      expect(view.copy([view.node(1)!], worldAnchor: (0.5, 0.5))!.worldAnchor,
          isNull);
    });

    test('has nothing to copy in a lone untagged vertex', () {
      final view = _roads();
      expect(view.copy([view.node(1)!]), isNull);
    });
  });

  group('moving', () {
    test('moves a way and its nodes, once each, as one change', () {
      final view = _roads();
      final before = OsmMercator.x(view.node(2)!.longitude);
      view.move([view.way(10)!, view.node(2)!],
          worldDx: 0.0001, worldDy: 0).apply();
      expect(
        OsmMercator.x(view.node(2)!.longitude),
        closeTo(before + 0.0001, 1e-12),
      );
      expect(view.history.length, 1);
      view.undo();
      expect(view.history.changedNodes, isEmpty);
    });
  });

  group('across the antimeridian', () {
    OsmEditor across() => OsmEditor(
          OsmElementSource.of([
            testNode(1, 0, 179.999),
            testNode(2, 0, -179.999),
            testNode(3, 0.002, -179.999),
            testNode(4, 0.002, 179.999),
            testWay(10, [1, 2, 3, 4, 1], {'building': 'yes', 'shop': 'bakery'}),
          ]),
          rules: const _EverythingToThePoint(),
        );

    test('puts what is extracted on the antimeridian, not half a world off',
        () {
      final view = across();
      final point = OsmExtractOperation(view, [view.way(10)!]).apply().single;
      expect(point.longitude.abs(), closeTo(180, 1e-6));
      expect(point.latitude, closeTo(0.001, 1e-6));
    });

    test('moves and pastes across it onto real longitudes', () {
      final view = across();
      view.move([view.node(1)!], worldDx: 0.002 / 360, worldDy: 0).apply();
      expect(view.node(1)!.longitude, closeTo(-179.999, 1e-6));

      final copied = view.copy([view.way(10)!])!;
      expect(copied.worldMiddle.$1, anyOf(closeTo(1, 1e-5), closeTo(0, 1e-5)));
      final pasted = view.paste(copied, worldDx: 0.01, worldDy: 0).apply();
      for (final id in (pasted.single as OsmWay).nodeIds) {
        final longitude = view.node(id)!.longitude;
        expect(longitude, inInclusiveRange(-180, 180));
      }
    });
  });
}

/// Pulling a point out of way 10 of [view], by [presets].
OsmExtractOperation _extract(OsmEditor view, OsmPresets presets) {
  (view.rules as OsmStandardTagRules).presets = presets;
  return view.extract([view.way(10)!]);
}

/// Rules a tool might make of its own: whatever a way says goes to a point
/// pulled out of it.
class _EverythingToThePoint extends OsmPlainTagRules {
  const _EverythingToThePoint();

  @override
  ({Map<String, String> point, Map<String, String> way})? extracted(
    OsmWay way,
    OsmEditor editor,
  ) =>
      (point: way.tags, way: const {});
}
