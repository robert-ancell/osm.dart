import 'package:osm/osm.dart';
import 'package:test/test.dart';

/// Data as it was read, with the edits laid over it.
class _View implements OsmEditView {
  @override
  final edits = OsmEdits();

  final Map<int, OsmNode> nodes;
  final Map<int, OsmWay> ways;
  final Map<int, OsmRelation> relations;

  _View({
    required List<OsmNode> nodes,
    List<OsmWay> ways = const [],
    List<OsmRelation> relations = const [],
  })  : nodes = {for (final n in nodes) n.id: n},
        ways = {for (final w in ways) w.id: w},
        relations = {for (final r in relations) r.id: r};

  @override
  OsmNode? node(int id) => edits.isGone(OsmElementType.node, id)
      ? null
      : edits.changedNode(id) ?? nodes[id];

  @override
  OsmWay? way(int id) => edits.isGone(OsmElementType.way, id)
      ? null
      : edits.changedWay(id) ?? ways[id];

  @override
  OsmRelation? relation(int id) => edits.isGone(OsmElementType.relation, id)
      ? null
      : edits.changedRelation(id) ?? relations[id];

  Iterable<OsmWay> get _allWays => {
        ...ways.keys,
        ...edits.changedWays.keys,
      }.map(way).whereType<OsmWay>();

  Iterable<OsmRelation> get _allRelations => {
        ...relations.keys,
        ...edits.changedRelations.keys,
      }.map(relation).whereType<OsmRelation>();

  @override
  List<OsmWay> waysUsing(int nodeId) => [
        for (final way in _allWays)
          if (way.nodeIds.contains(nodeId)) way,
      ];

  @override
  List<OsmRelation> relationsUsing(OsmElementType type, int id) => [
        for (final relation in _allRelations)
          if (relation.members.any((m) => m.type == type && m.ref == id))
            relation,
      ];

  @override
  OsmGeometry geometryOf(OsmElement element) => switch (element) {
        OsmNode() => waysUsing(element.id).isEmpty
            ? OsmGeometry.point
            : OsmGeometry.vertex,
        OsmWay() => element.isClosed &&
                element.tags['area'] != 'no' &&
                (element.tags.containsKey('building') ||
                    element.tags['area'] == 'yes')
            ? OsmGeometry.area
            : OsmGeometry.line,
        OsmRelation() => OsmGeometry.relation,
      };
}

OsmNode _node(int id, double latitude, double longitude,
        [Map<String, String> tags = const {}]) =>
    OsmNode(
      id: id,
      latitude: latitude,
      longitude: longitude,
      tags: tags,
      info: const OsmInfo(version: 1),
    );

OsmWay _way(int id, List<int> nodes, [Map<String, String> tags = const {}]) =>
    OsmWay(id: id, nodeIds: nodes, tags: tags, info: const OsmInfo(version: 1));

/// A road of three nodes, west to east, with a side road off its middle.
_View _roads() => _View(
      nodes: [
        _node(1, 0, 0),
        _node(2, 0, 0.001, {'highway': 'crossing'}),
        _node(3, 0, 0.002),
        _node(4, 0.001, 0.001),
      ],
      ways: [
        _way(10, [1, 2, 3], {'highway': 'residential'}),
        _way(11, [2, 4], {'highway': 'service'}),
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
      final view = _View(
        nodes: [
          _node(1, 0, 0),
          _node(2, 0, 0.001, {'barrier': 'gate'}),
        ],
        ways: [
          _way(10, [1, 2], {'highway': 'track'}),
        ],
      );
      OsmDelete(view, [view.way(10)!]).apply();
      expect(view.node(1), isNull);
      expect(view.node(2), isNotNull);
    });

    test('keeps a node of a deleted way that only says where it came from', () {
      final view = _View(
        nodes: [
          _node(1, 0, 0, {'source': 'survey'}),
          _node(2, 0, 0.001),
        ],
        ways: [
          _way(10, [1, 2], {'highway': 'track'}),
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
      final view = _View(
        nodes: [_node(1, 0, 0)],
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
      final view = _View(nodes: [
        _node(1, 0, 0, {'wikidata': 'Q1'})
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
      final view = _View(
        nodes: [_node(1, 0, 0), _node(2, 0, 0.001)],
        ways: [
          _way(10, [
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
      final view = _View(
        nodes: [
          _node(1, 0, 0, {'direction': 'forward', 'highway': 'stop'}),
          _node(2, 0, 0.001, {'direction': 'N'}),
        ],
        ways: [
          _way(10, [1, 2], {'highway': 'residential'}),
        ],
      );
      OsmReverse(view, [view.way(10)!]).apply();
      expect(view.node(1)!.tags['direction'], 'backward');
      expect(view.node(2)!.tags['direction'], 'N');
    });

    test('turns a node on its own right round', () {
      final view = _View(
        nodes: [
          _node(1, 0, 0, {'direction': '90'}),
          _node(2, 0, 0, {'direction': 'NE;190'}),
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
      final view = _View(
        nodes: [
          _node(1, 0, 0),
          _node(2, 0, 1),
          _node(3, 1, 1),
          _node(4, 5, 5, {'amenity': 'bench'}),
        ],
        ways: [
          _way(10, [1, 2, 3, 1], {'building': 'yes'}),
        ],
      );
      expect(OsmReverse(view, [view.way(10)!]).available, isFalse);
      expect(OsmReverse(view, [view.node(4)!]).available, isFalse);
    });

    test('says what it reverses', () {
      final view = _View(
        nodes: [
          _node(1, 0, 0),
          _node(2, 0, 0.001),
          _node(3, 5, 5, {'direction': 'N'}),
        ],
        ways: [
          _way(10, [1, 2], {'highway': 'residential'}),
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
      final alone = _View(nodes: [
        _node(1, 0, 0, {'amenity': 'bench'})
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

      _View shop(Map<String, String> tags) => _View(
            nodes: [
              _node(1, 0, 0),
              _node(2, 0, 0.002),
              _node(3, 0.002, 0.002),
              _node(4, 0.002, 0),
            ],
            ways: [
              _way(10, [1, 2, 3, 4, 1], tags),
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
      final view = _View(
        nodes: [_node(1, 0, 0), _node(2, 0, 1), _node(3, 0, 2)],
        ways: [
          _way(10, [1, 2, 3])
        ],
      );
      expect(osmContinuable(view, [view.node(2)!]), isEmpty);
    });

    test('finds every line that ends there, and one when one is chosen', () {
      final view = _View(
        nodes: [_node(1, 0, 0), _node(2, 0, 1), _node(3, 1, 1)],
        ways: [
          _way(10, [1, 2]),
          _way(11, [2, 3])
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
}
