import 'package:osm/osm.dart';
import 'package:test/test.dart';

import 'test_view.dart';

/// A road of three nodes, west to east, with a side road off its middle.
TestView _roads() => TestView(
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
    );

void main() {
  group('deleting', () {
    test('deletes a way and the nodes only it used', () {
      final view = _roads();
      OsmDelete(view, [view.way(11)!]).apply();
      expect(view.way(11), isNull);
      // Its far end goes; the node it shares with the road stays.
      expect(view.node(4), isNull);
      expect(view.node(2), isNotNull);
      expect(view.edits.length, 1);
    });

    test('keeps a node of a deleted way that says something', () {
      final view = TestView(
        nodes: [
          testNode(1, 0, 0),
          testNode(2, 0, 0.001, {'barrier': 'gate'}),
        ],
        ways: [
          testWay(10, [1, 2], {'highway': 'track'}),
        ],
      );
      OsmDelete(view, [view.way(10)!]).apply();
      expect(view.node(1), isNull);
      expect(view.node(2), isNotNull);
    });

    test('keeps a node of a deleted way that only says where it came from', () {
      final view = TestView(
        nodes: [
          testNode(1, 0, 0, {'source': 'survey'}),
          testNode(2, 0, 0.001),
        ],
        ways: [
          testWay(10, [1, 2], {'highway': 'track'}),
        ],
      );
      OsmDelete(view, [view.way(10)!]).apply();
      // Where it came from is nothing of its own: it goes with the way.
      expect(view.node(1), isNull);
    });

    test('deletes a way a node going leaves too short', () {
      final view = _roads();
      OsmDelete(view, [view.node(4)!]).apply();
      expect(view.way(11), isNull);
      expect(view.way(10), isNotNull);
    });

    test('deletes a relation left with no members', () {
      final view = TestView(
        nodes: [testNode(1, 0, 0)],
        relations: [
          const OsmRelation(
            id: 20,
            members: [OsmMember(type: OsmElementType.node, ref: 1, role: '')],
            info: OsmInfo(version: 1),
          ),
        ],
      );
      OsmDelete(view, [view.node(1)!]).apply();
      expect(view.relation(20), isNull);
      expect(view.edits.deletedRelations, contains(20));
    });

    test('will not delete part of a route or a boundary', () {
      for (final type in ['route', 'boundary']) {
        final view = _roads();
        view.relations[30] = OsmRelation(
          id: 30,
          members: const [
            OsmMember(type: OsmElementType.way, ref: 10, role: ''),
          ],
          tags: {'type': type},
        );
        expect(
          OsmDelete(view, [view.way(10)!]).disabled,
          'part_of_relation',
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
      final outer = _roads()..relations[30] = multipolygon('outer');
      expect(OsmDelete(outer, [outer.way(10)!]).disabled, 'part_of_relation');
      final unroled = _roads()..relations[30] = multipolygon('');
      expect(
        OsmDelete(unroled, [unroled.way(10)!]).disabled,
        'part_of_relation',
      );
      final inner = _roads()..relations[30] = multipolygon('inner');
      expect(OsmDelete(inner, [inner.way(10)!]).disabled, isNull);
    });

    test('will not delete something with a Wikidata tag', () {
      final view = TestView(nodes: [
        testNode(1, 0, 0, {'wikidata': 'Q1'})
      ]);
      expect(OsmDelete(view, [view.node(1)!]).disabled, 'has_wikidata_tag');
    });

    test('undoes a deletion as one change', () {
      final view = _roads();
      OsmDelete(view, [view.way(11)!, view.node(1)!]).apply();
      view.edits.undo();
      expect(view.edits.isEmpty, isTrue);
      expect(view.way(11), isNotNull);
      expect(view.node(4), isNotNull);
    });
  });

  group('reversing', () {
    test('turns a line round, and its tags with it', () {
      final view = TestView(
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
      OsmReverse(view, [view.way(10)!]).apply();
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
      expect(view.edits.length, 1);
    });

    test('turns round the nodes along a line, but not their bearings', () {
      final view = TestView(
        nodes: [
          testNode(1, 0, 0, {'direction': 'forward', 'highway': 'stop'}),
          testNode(2, 0, 0.001, {'direction': 'N'}),
        ],
        ways: [
          testWay(10, [1, 2], {'highway': 'residential'}),
        ],
      );
      OsmReverse(view, [view.way(10)!]).apply();
      expect(view.node(1)!.tags['direction'], 'backward');
      expect(view.node(2)!.tags['direction'], 'N');
    });

    test('turns a node on its own right round', () {
      final view = TestView(
        nodes: [
          testNode(1, 0, 0, {'direction': '90'}),
          testNode(2, 0, 0, {'direction': 'NE;190'}),
        ],
      );
      OsmReverse(view, [view.node(1)!, view.node(2)!]).apply();
      expect(view.node(1)!.tags['direction'], '270');
      expect(view.node(2)!.tags['direction'], 'SW;10');
    });

    test('turns round a line going forward or backward in a route', () {
      final view = _roads()
        ..relations[30] = const OsmRelation(
          id: 30,
          members: [
            OsmMember(type: OsmElementType.way, ref: 10, role: 'forward'),
          ],
          tags: {'type': 'route'},
        );
      OsmReverse(view, [view.way(10)!]).apply();
      expect(view.relation(30)!.members.single.role, 'backward');
    });

    test('has nothing to reverse in an area or a node with no direction', () {
      final view = TestView(
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
      expect(OsmReverse(view, [view.way(10)!]).available, isFalse);
      expect(OsmReverse(view, [view.node(4)!]).available, isFalse);
    });

    test('says what it reverses', () {
      final view = TestView(
        nodes: [
          testNode(1, 0, 0),
          testNode(2, 0, 0.001),
          testNode(3, 5, 5, {'direction': 'N'}),
        ],
        ways: [
          testWay(10, [1, 2], {'highway': 'residential'}),
        ],
      );
      expect(OsmReverse(view, [view.way(10)!]).kind, 'line');
      expect(OsmReverse(view, [view.node(3)!]).kind, 'point');
      expect(OsmReverse(view, [view.way(10)!, view.node(3)!]).kind, 'features');
    });
  });

  group('extracting', () {
    test('takes a tagged node out of its lines, leaving another there', () {
      final view = _roads();
      final points = OsmExtract(view, [view.node(2)!]).apply();
      expect(points.single.id, 2);
      expect(view.waysUsing(2), isEmpty);
      final road = view.way(10)!;
      final replacement = view.node(road.nodeIds[1])!;
      expect(replacement.id, isNegative);
      expect(replacement.tags, isEmpty);
      expect(replacement.latitude, view.node(2)!.latitude);
      // The side road is on the replacement too, still joined to the road.
      expect(view.way(11)!.nodeIds.first, replacement.id);
      expect(view.edits.length, 1);
    });

    test('has nothing to take out of an untagged node or one on its own', () {
      final view = _roads();
      expect(OsmExtract(view, [view.node(1)!]).available, isFalse);
      final alone = TestView(nodes: [
        testNode(1, 0, 0, {'amenity': 'bench'})
      ]);
      expect(OsmExtract(alone, [alone.node(1)!]).available, isFalse);
    });

    group('from an area', () {
      final presets = OsmPresets.parse(
        presets: '''{
          "shop/bakery": {"tags": {"shop": "bakery"}, "geometry": ["point", "area"]},
          "building": {"tags": {"building": "*"}, "geometry": ["area"]}
        }''',
        translations: '{"en": {"presets": {"presets": {}}}}',
      );

      TestView shop(Map<String, String> tags) => TestView(
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
        final point =
            OsmExtract(view, [view.way(10)!], presets: presets).apply().single;
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
        OsmExtract(view, [view.way(10)!], presets: presets).apply();
        expect(view.way(10)!.tags, {'area': 'yes'});
      });

      test('takes nothing out of what can only be an area', () {
        final view = shop({'building': 'yes'});
        expect(
          OsmExtract(view, [view.way(10)!], presets: presets).available,
          isFalse,
        );
      });

      test('takes nothing out of a way when the kinds are not known', () {
        final view = shop({'shop': 'bakery', 'area': 'yes'});
        expect(OsmExtract(view, [view.way(10)!]).available, isFalse);
      });
    });
  });

  group('continuing', () {
    test('finds the line a selected end continues', () {
      final view = _roads();
      expect(
        osmContinuable(view, [view.node(3)!])!.map((w) => w.id),
        [10],
      );
    });

    test('finds nothing to continue from the middle of a line', () {
      final view = TestView(
        nodes: [testNode(1, 0, 0), testNode(2, 0, 1), testNode(3, 0, 2)],
        ways: [
          testWay(10, [1, 2, 3])
        ],
      );
      expect(osmContinuable(view, [view.node(2)!]), isEmpty);
    });

    test('finds every line that ends there, and one when one is chosen', () {
      final view = TestView(
        nodes: [testNode(1, 0, 0), testNode(2, 0, 1), testNode(3, 1, 1)],
        ways: [
          testWay(10, [1, 2]),
          testWay(11, [2, 3])
        ],
      );
      expect(osmContinuable(view, [view.node(2)!]), hasLength(2));
      expect(
        osmContinuable(view, [view.node(2)!, view.way(11)!])!.map((w) => w.id),
        [11],
      );
    });

    test('is not something to ask of anything but one vertex', () {
      final view = _roads();
      expect(osmContinuable(view, [view.way(10)!]), isNull);
      expect(osmContinuable(view, [view.node(1)!, view.node(3)!]), isNull);
    });
  });

  group('copying and pasting', () {
    test('copies a way with its nodes, and pastes it somewhere else', () {
      final view = _roads();
      final copied = osmCopy(view, [view.way(11)!], anchor: (0.5, 0.5))!;
      expect(copied.length, 1);
      expect(copied.nodes.keys, containsAll([2, 4]));
      final pasted = osmPaste(view.edits, copied, dx: 0.001, dy: 0);
      final way = pasted.single as OsmWay;
      expect(way.id, isNegative);
      expect(way.tags, {'highway': 'service'});
      final start = view.node(way.nodeIds.first)!;
      expect(start.id, isNegative);
      // What the node said comes too.
      expect(start.tags, {'highway': 'crossing'});
      expect(
        Mercator.x(start.longitude),
        closeTo(Mercator.x(view.node(2)!.longitude) + 0.001, 1e-12),
      );
      expect(view.edits.length, 1);
    });

    test('leaves out an untagged node of a way copied with it', () {
      final view = _roads();
      final copied = osmCopy(view, [view.way(10)!, view.node(1)!])!;
      expect(copied.elements.map((e) => e.id), [10]);
    });

    test('anchors a single node by itself', () {
      final view = TestView(nodes: [
        testNode(1, 0, 0, {'amenity': 'bench'})
      ]);
      expect(
          osmCopy(view, [view.node(1)!], anchor: (0.5, 0.5))!.anchor, isNull);
    });

    test('has nothing to copy in a lone untagged vertex', () {
      final view = _roads();
      expect(osmCopy(view, [view.node(1)!]), isNull);
    });
  });

  group('moving', () {
    test('moves a way and its nodes, once each, as one change', () {
      final view = _roads();
      final before = Mercator.x(view.node(2)!.longitude);
      osmMove(view, [view.way(10)!, view.node(2)!], dx: 0.0001, dy: 0);
      expect(
        Mercator.x(view.node(2)!.longitude),
        closeTo(before + 0.0001, 1e-12),
      );
      expect(view.edits.length, 1);
      view.edits.undo();
      expect(view.edits.changedNodes, isEmpty);
    });
  });

  group('across the antimeridian', () {
    TestView across() => TestView(
          nodes: [
            testNode(1, 0, 179.999),
            testNode(2, 0, -179.999),
            testNode(3, 0.002, -179.999),
            testNode(4, 0.002, 179.999),
          ],
          ways: [
            testWay(10, [1, 2, 3, 4, 1], {'building': 'yes', 'shop': 'bakery'}),
          ],
        );

    test('puts what is extracted on the antimeridian, not half a world off',
        () {
      final view = across();
      final point = OsmExtract(view, [view.way(10)!]).apply().single as OsmNode;
      expect(point.longitude.abs(), closeTo(180, 1e-6));
      expect(point.latitude, closeTo(0.001, 1e-6));
    });

    test('moves and pastes across it onto real longitudes', () {
      final view = across();
      osmMove(view, [view.node(1)!], dx: 0.002 / 360, dy: 0);
      expect(view.node(1)!.longitude, closeTo(-179.999, 1e-6));

      final copied = osmCopy(view, [view.way(10)!])!;
      expect(copied.middle.$1, anyOf(closeTo(1, 1e-5), closeTo(0, 1e-5)));
      final pasted = osmPaste(view.edits, copied, dx: 0.01, dy: 0);
      for (final id in (pasted.single as OsmWay).nodeIds) {
        final longitude = view.node(id)!.longitude;
        expect(longitude, inInclusiveRange(-180, 180));
      }
    });
  });
}
