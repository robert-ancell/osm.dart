import 'package:osm/editor.dart';
import 'package:osm/osm.dart';
import 'package:test/test.dart';

import 'test_editor.dart';

/// Four nodes in a row, west to east, a hundred metres or so apart.
List<OsmNode> _row([int from = 1]) => [
      for (var i = 0; i < 4; i++) testNode(from + i, 0, i * 0.001),
    ];

OsmRelation _relation(
  int id,
  List<(OsmElementType, int, String)> members, [
  Map<String, String> tags = const {},
]) =>
    OsmRelation(
      id: id,
      members: [
        for (final (type, ref, role) in members)
          OsmMember(type: type, ref: ref, role: role),
      ],
      tags: tags,
      info: const OsmInfo(version: 1),
    );

const _way = OsmElementType.way;
const _node = OsmElementType.node;

void main() {
  group('splitting', () {
    test('splits a line in two at a node along it', () {
      final view = testEditor(
        nodes: _row(),
        ways: [
          testWay(10, [1, 2, 3, 4], {'highway': 'residential'}),
        ],
      );
      final split = OsmSplitOperation(view, [view.node(3)!]);
      expect(split.available, isTrue);
      expect(split.disabled, isNull);
      final ways = split.apply();
      expect(ways, hasLength(2));
      // The longer piece keeps the way and its history.
      expect(view.way(10)!.nodeIds, [1, 2, 3]);
      final made = ways.firstWhere((w) => w.id != 10);
      expect(made.nodeIds, [3, 4]);
      expect(made.tags, {'highway': 'residential'});
      expect(view.history.length, 1);
    });

    test('will not split a line at its end', () {
      final view = testEditor(nodes: _row(), ways: [
        testWay(10, [1, 2, 3, 4])
      ]);
      // Offered, as iD offers it, but not to be done.
      expect(OsmSplitOperation(view, [view.node(1)!]).disabled,
          OsmDisabledReason.notEligible);
      final end = testEditor(
        nodes: _row(),
        ways: [
          testWay(10, [1, 2, 3, 4]),
          testWay(11, [4, 1])
        ],
      );
      expect(OsmSplitOperation(end, [end.node(4)!]).disabled,
          OsmDisabledReason.notEligible);
    });

    test('divides a count along the line between the pieces', () {
      final view = testEditor(
        nodes: _row(),
        ways: [
          testWay(10, [1, 2, 3, 4], {'highway': 'steps', 'step_count': '30'}),
        ],
      );
      OsmSplitOperation(view, [view.node(2)!]).apply();
      final counts = [
        view.way(10)!.tags['step_count'],
        view.history.changedWays.values
            .firstWhere((w) => w.id < 0)
            .tags['step_count'],
      ];
      expect(counts, ['20', '10']);
    });

    test('keeps a route running on, the new piece beside the old', () {
      // The route runs 9 then 10 then 11, and 10 is split.
      final view = testEditor(
        nodes: [testNode(0, 0, -0.001), ..._row(), testNode(5, 0, 0.004)],
        ways: [
          testWay(9, [0, 1]),
          testWay(10, [1, 2, 3, 4]),
          testWay(11, [4, 5]),
        ],
        relations: [
          _relation(30, [
            (_way, 9, ''),
            (_way, 10, ''),
            (_way, 11, ''),
          ], {
            'type': 'route'
          }),
        ],
      );
      OsmSplitOperation(view, [view.node(2)!]).apply();
      final made = view.history.changedWays.keys.firstWhere((id) => id < 0);
      // 10 kept the longer end, 2 to 4, so the piece from 1 to 2 goes
      // before it, between it and 9.
      expect(view.way(10)!.nodeIds, [2, 3, 4]);
      expect(view.relation(30)!.members.map((m) => m.ref), [9, made, 10, 11]);
    });

    test('keeps a turn restriction on the piece at the junction', () {
      final view = testEditor(
        nodes: [..._row(), testNode(5, 0.001, 0.003)],
        ways: [
          testWay(10, [1, 2, 3, 4]),
          testWay(11, [4, 5]),
        ],
        relations: [
          _relation(30, [
            (_way, 10, 'from'),
            (_node, 4, 'via'),
            (_way, 11, 'to'),
          ], {
            'type': 'restriction',
            'restriction': 'no_left_turn'
          }),
        ],
      );
      OsmSplitOperation(view, [view.node(3)!]).apply();
      // 10 kept 1 to 3; the new piece, 3 to 4, reaches the junction.
      final made = view.history.changedWays.keys.firstWhere((id) => id < 0);
      expect(
        view.relation(30)!.members.where((m) => m.role == 'from').single.ref,
        made,
      );
    });

    test('turns an area split in two into a multipolygon of the pieces', () {
      final view = testEditor(
        nodes: [
          testNode(1, 0, 0),
          testNode(2, 0, 0.001),
          testNode(3, 0.001, 0.001),
          testNode(4, 0.001, 0),
        ],
        ways: [
          testWay(10, [1, 2, 3, 4, 1], {'building': 'yes', 'name': 'Hall'}),
        ],
      );
      final split = OsmSplitOperation(view, [view.node(1)!, view.node(3)!]);
      expect(
        split.ways.map(view.geometryOf).toSet(),
        {OsmGeometry.area},
      );
      split.apply();
      final relation = view.history.changedRelations.values.single;
      expect(relation.tags, {
        'building': 'yes',
        'name': 'Hall',
        'type': 'multipolygon',
      });
      expect(relation.members.map((m) => m.role), ['outer', 'outer']);
      expect(view.way(10)!.tags, isEmpty);
    });

    test('will not split a roundabout that is part of something larger', () {
      final view = testEditor(
        nodes: [
          testNode(1, 0, 0),
          testNode(2, 0, 0.001),
          testNode(3, 0.001, 0.001),
        ],
        ways: [
          testWay(10, [1, 2, 3, 1], {'junction': 'roundabout'}),
        ],
        relations: [
          _relation(30, [(_way, 10, '')], {'type': 'route'}),
        ],
      );
      expect(OsmSplitOperation(view, [view.node(2)!]).disabled,
          OsmDisabledReason.simpleRoundabout);
    });

    test('will not split part of a route with none of its neighbours here', () {
      final view = testEditor(
        nodes: _row(),
        ways: [
          testWay(10, [1, 2, 3, 4])
        ],
        relations: [
          _relation(30, [(_way, 8, ''), (_way, 10, ''), (_way, 12, '')]),
        ],
      );
      expect(OsmSplitOperation(view, [view.node(2)!]).disabled,
          OsmDisabledReason.parentIncomplete);
    });
  });

  group('merging lines', () {
    test('joins two lines end to end into the older', () {
      final view = testEditor(
        nodes: _row(),
        ways: [
          testWay(11, [3, 4], {'highway': 'residential'}),
          testWay(10, [1, 2, 3], {'highway': 'residential', 'name': 'A'}),
        ],
      );
      final merge = OsmMergeOperation(view, [view.way(11)!, view.way(10)!]);
      expect(merge.disabled, isNull);
      merge.apply();
      expect(view.way(11), isNull);
      expect(view.way(10)!.nodeIds, [1, 2, 3, 4]);
      expect(view.way(10)!.tags, {'highway': 'residential', 'name': 'A'});
      expect(view.history.length, 1);
    });

    test('turns a line round to join it, and what faces its way with it', () {
      final view = testEditor(
        nodes: _row(),
        ways: [
          testWay(10, [1, 2], {'highway': 'residential'}),
          testWay(
              11, [3, 2], {'highway': 'residential', 'sidewalk:left': 'yes'}),
        ],
      );
      OsmMergeOperation(view, [view.way(10)!, view.way(11)!]).apply();
      expect(view.way(10)!.nodeIds, [1, 2, 3]);
      // The pavement on 11's left, as it was drawn, is on the right of the
      // line it is now part of.
      expect(view.way(10)!.tags['sidewalk:right'], 'yes');
    });

    test('will not join oneways whose tags differ, even facing the same way',
        () {
      // As iD judges it: the tags are compared as they are, before either
      // line is turned round.
      final view = testEditor(
        nodes: _row(),
        ways: [
          testWay(10, [1, 2], {'highway': 'residential', 'oneway': 'yes'}),
          testWay(11, [3, 2], {'highway': 'residential', 'oneway': '-1'}),
        ],
      );
      expect(
        OsmMergeOperation(view, [view.way(10)!, view.way(11)!]).disabled,
        OsmDisabledReason.conflictingTags,
      );
    });

    test('says why lines that do not meet cannot be joined', () {
      final view = testEditor(
        nodes: _row(),
        ways: [
          testWay(10, [1, 2]),
          testWay(11, [3, 4])
        ],
      );
      expect(
        OsmMergeOperation(view, [view.way(10)!, view.way(11)!]).disabled,
        OsmDisabledReason.notAdjacent,
      );
    });

    test('says why lines tagged differently cannot be joined', () {
      final view = testEditor(
        nodes: _row(),
        ways: [
          testWay(10, [1, 2], {'highway': 'residential'}),
          testWay(11, [2, 3], {'highway': 'service'}),
        ],
      );
      expect(
        OsmMergeOperation(view, [view.way(10)!, view.way(11)!]).disabled,
        OsmDisabledReason.conflictingTags,
      );
    });

    test('says why lines in different relations cannot be joined', () {
      final view = testEditor(
        nodes: _row(),
        ways: [
          testWay(10, [1, 2]),
          testWay(11, [2, 3])
        ],
        relations: [
          _relation(30, [(_way, 10, '')], {'type': 'route'}),
        ],
      );
      expect(
        OsmMergeOperation(view, [view.way(10)!, view.way(11)!]).disabled,
        OsmDisabledReason.conflictingRelations,
      );
    });

    test('will not make a line longer than a way can be', () {
      final view = testEditor(
        nodes: _row(),
        ways: [
          testWay(10, [1, 2]),
          testWay(11, [2, 3, 4])
        ],
      );
      expect(
        OsmMergeOperation(
          view,
          [view.way(10)!, view.way(11)!],
          maximumWayNodes: 3,
        ).disabled,
        OsmDisabledReason.tooManyVertices,
      );
    });

    test('adds up what is counted along the lines', () {
      final view = testEditor(
        nodes: _row(),
        ways: [
          testWay(10, [1, 2], {'highway': 'steps', 'step_count': '12'}),
          testWay(11, [2, 3], {'highway': 'steps', 'step_count': '8'}),
        ],
      );
      OsmMergeOperation(view, [view.way(10)!, view.way(11)!]).apply();
      expect(view.way(10)!.tags['step_count'], '20');
    });
  });

  group('merging points into an area', () {
    OsmEditor shop() => testEditor(
          nodes: [
            testNode(1, 0, 0),
            testNode(2, 0, 0.001),
            testNode(3, 0.001, 0.001),
            testNode(4, 0.001, 0),
            testNode(5, 0.0005, 0.0005, {'shop': 'bakery', 'name': 'Crust'}),
          ],
          ways: [
            testWay(10, [1, 2, 3, 4, 1], {'building': 'yes'}),
          ],
        );

    test('moves what the point says onto the area', () {
      final view = shop();
      final merge = OsmMergeOperation(view, [view.node(5)!, view.way(10)!]);
      expect(merge.disabled, isNull);
      merge.apply();
      expect(view.way(10)!.tags, {
        'building': 'yes',
        'shop': 'bakery',
        'name': 'Crust',
      });
    });

    test('keeps the point on as one of the area\'s corners', () {
      // Its history carries on in the area rather than ending.
      final view = shop();
      OsmMergeOperation(view, [view.node(5)!, view.way(10)!]).apply();
      expect(view.node(5), isNotNull);
      expect(view.way(10)!.nodeIds, contains(5));
      expect(view.node(5)!.tags, isEmpty);
      expect(view.history.deletedNodes.keys.single, isNot(5));
    });
  });

  group('merging areas', () {
    test('makes a multipolygon with a hole of an area inside another', () {
      final view = testEditor(
        nodes: [
          testNode(1, 0, 0),
          testNode(2, 0, 0.003),
          testNode(3, 0.003, 0.003),
          testNode(4, 0.003, 0),
          testNode(5, 0.001, 0.001),
          testNode(6, 0.001, 0.002),
          testNode(7, 0.002, 0.002),
        ],
        ways: [
          testWay(10, [1, 2, 3, 4, 1], {'area': 'yes', 'landuse': 'grass'}),
          testWay(11, [5, 6, 7, 5], {'area': 'yes'}),
        ],
      );
      final merge = OsmMergeOperation(view, [view.way(10)!, view.way(11)!]);
      expect(merge.disabled, isNull);
      merge.apply();
      final relation = view.history.changedRelations.values.single;
      expect(relation.tags, {'type': 'multipolygon', 'landuse': 'grass'});
      expect(
        {for (final m in relation.members) m.ref: m.role},
        {10: 'outer', 11: 'inner'},
      );
    });
  });

  group('merging nodes', () {
    test('makes several nodes one, where the one that says something is', () {
      final view = testEditor(
        nodes: [
          ..._row(),
          testNode(5, 0.0005, 0.0015, {'barrier': 'gate'}),
          testNode(6, 0.001, 0.0015),
        ],
        ways: [
          testWay(10, [1, 2, 3, 4]),
          testWay(11, [5, 6]),
        ],
      );
      OsmMergeOperation(view, [view.node(2)!, view.node(5)!]).apply();
      // The gate says something and is on the map, so it is kept.
      expect(view.node(2), isNull);
      expect(view.way(10)!.nodeIds, [1, 5, 3, 4]);
      expect(view.node(5)!.latitude, 0.0005);
    });

    test('says why nodes with different parts in a relation cannot', () {
      final view = testEditor(
        nodes: _row(),
        relations: [
          _relation(30, [(_node, 1, 'stop'), (_node, 2, 'platform')]),
        ],
      );
      expect(
        OsmMergeOperation(view, [view.node(1)!, view.node(2)!]).disabled,
        OsmDisabledReason.relation,
      );
    });
  });

  group('disconnecting', () {
    OsmEditor crossroads({List<OsmRelation> relations = const []}) =>
        testEditor(
          nodes: [
            ..._row(),
            testNode(5, 0.001, 0.001),
          ],
          ways: [
            testWay(10, [1, 2, 3, 4]),
            testWay(11, [2, 5]),
          ],
          relations: relations,
        );

    test('gives each line its own node where they meet', () {
      final view = crossroads();
      final disconnect = OsmDisconnectOperation(view, [view.node(2)!]);
      expect(disconnect.available, isTrue);
      expect(disconnect.points, 1);
      expect(disconnect.ways, isEmpty);
      disconnect.apply();
      final road = view.way(10)!.nodeIds;
      final side = view.way(11)!.nodeIds;
      expect(road[1] == side.first, isFalse);
      expect({road[1], side.first}, contains(2));
      expect(view.history.length, 1);
    });

    test('disconnects a selected line from what it touches', () {
      final view = crossroads();
      final disconnect = OsmDisconnectOperation(view, [view.way(11)!]);
      expect(disconnect.points, 0);
      expect(disconnect.ways.single.id, 11);
      expect(disconnect.conjoined, isFalse);
      disconnect.apply();
      expect(view.way(10)!.nodeIds, [1, 2, 3, 4]);
      expect(view.way(11)!.nodeIds.first, isNegative);
    });

    test('says why a node on one line only cannot be disconnected', () {
      final view = crossroads();
      expect(OsmDisconnectOperation(view, [view.node(3)!]).disabled,
          OsmDisabledReason.notConnected);
    });

    test('says why lines joined in a relation cannot be disconnected', () {
      final view = crossroads(relations: [
        _relation(30, [(_way, 10, ''), (_way, 11, '')], {'type': 'route'}),
      ]);
      expect(OsmDisconnectOperation(view, [view.node(2)!]).disabled,
          OsmDisabledReason.relation);
    });
  });

  test('joins lines meeting at the antimeridian that do not cross', () {
    final view = testEditor(
      nodes: [
        testNode(1, 0, 179.9),
        testNode(2, 0, -179.9),
        testNode(3, 0.1, -179.8),
        testNode(4, -0.1, -179.7),
      ],
      ways: [
        testWay(10, [1, 2], {'highway': 'residential'}),
        testWay(11, [2, 3, 4], {'highway': 'residential'}),
      ],
    );
    expect(OsmMergeOperation(view, [view.way(10)!, view.way(11)!]).disabled,
        isNull);
  });
}
