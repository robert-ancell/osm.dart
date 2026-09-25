import 'package:osm/country_coder.dart';
import 'package:osm/editor.dart';
import 'package:osm/osm.dart';
import 'package:test/test.dart';

import 'test_editor.dart';

OsmEditor _square() => testEditor(
      nodes: [
        testNode(1, 0, 0),
        testNode(2, 0, 0.001),
        testNode(3, 0.001, 0.001),
        testNode(4, 0.001, 0),
        testNode(5, 0.002, 0),
      ],
      ways: [
        testWay(10, [1, 2, 3, 4, 1], {'building': 'yes'}),
      ],
    );

void main() {
  test('lays what has been changed over what was read', () {
    final editor = _square();
    final node = editor.node(1)!;
    editor.setTags(node, {'entrance': 'main'});
    expect(editor.node(1)!.tags, {'entrance': 'main'});
    expect(editor.data.node(1)!.tags, isEmpty);
    editor.deleteNode(editor.node(5)!);
    expect(editor.node(5), isNull);
  });

  test('knows the ways through a node, read or drawn since', () {
    final editor = _square();
    expect(editor.waysUsing(1).map((w) => w.id), [10]);
    final line = editor.createWay(nodeIds: [4, 5]);
    expect(
        editor.waysUsing(4).map((w) => w.id), unorderedEquals([10, line.id]));
    expect(editor.geometryOf(editor.node(5)!), OsmGeometry.vertex);
  });

  test('knows nothing of tags with the plain rules', () {
    final editor = OsmEditor(_square().data);
    expect(editor.geometryOf(editor.way(10)!), OsmGeometry.line);
    final reverse = editor.reverse([editor.way(10)!]);
    expect(reverse.available, isTrue);
    expect(editor.delete([editor.way(10)!]).disabled, isNull);
  });

  test('says a closed building is an area without any presets', () {
    final editor = _square();
    expect(editor.geometryOf(editor.way(10)!), OsmGeometry.area);
    final other = OsmEditor(
      editor.data,
      rules: OsmStandardTagRules(isAreaWithoutPresets: (tags) => false),
    );
    expect(other.geometryOf(other.way(10)!), OsmGeometry.line);
  });

  test('makes a group of changes one to undo', () {
    final editor = _square();
    final made = editor.group(() {
      final a = editor.createNode(latitude: 1, longitude: 1);
      final b = editor.createNode(latitude: 1, longitude: 2);
      return editor.createWay(nodeIds: [a.id, b.id]);
    });
    expect(editor.history.length, 1);
    expect(editor.way(made.id), isNotNull);
    expect(editor.undo(), isTrue);
    expect(editor.way(made.id), isNull);
    expect(editor.canUndo, isFalse);
  });

  test('offers what can be done to what is selected', () {
    final editor = _square();
    final delete = editor.delete([editor.way(10)!]);
    expect(delete.available, isTrue);
    delete.apply();
    expect(editor.way(10), isNull);
    expect(editor.node(1), isNull);
  });

  group('redo', () {
    /// Everything about the editor's data as it now stands, to compare.
    String state(OsmEditor editor) => [
          for (final id in [1, 2, 3, 4, 5, -1, -2, -3])
            '${editor.node(id)?.latitude},${editor.node(id)?.tags}',
          for (final id in [10, -1, -2, -3, -4])
            '${editor.way(id)?.nodeIds},${editor.way(id)?.tags}',
          '${editor.history.deletedNodes.keys}',
          '${editor.history.deletedWays.keys}',
        ].join('|');

    /// Checks that undoing and redoing [change] comes back to the same
    /// place, twice over.
    void roundTrip(void Function(OsmEditor editor) change) {
      final editor = _square();
      final before = state(editor);
      change(editor);
      final after = state(editor);
      for (var i = 0; i < 2; i++) {
        expect(editor.undo(), isTrue);
        expect(state(editor), before);
        expect(editor.redo(), isTrue);
        expect(state(editor), after);
      }
      expect(editor.canRedo, isFalse);
    }

    test('makes a move again', () {
      roundTrip((e) => e.moveNode(e.node(1)!, latitude: 1, longitude: 1));
    });

    test('makes tags again', () {
      roundTrip((e) => e.setTags(e.way(10)!, {'building': 'house'}));
    });

    test('makes new things again', () {
      roundTrip((e) => e.group(() {
            final a = e.createNode(latitude: 1, longitude: 1);
            e.createWay(nodeIds: [a.id, 5]);
          }));
    });

    test('takes a deleted node out of its way again', () {
      roundTrip((e) => e.deleteNode(e.node(2)!));
    });

    test('deletes a way and its nodes again', () {
      roundTrip((e) => e.delete([e.way(10)!]).apply());
    });

    test('forgets what was undone once something else is done', () {
      final editor = _square();
      editor.setTags(editor.node(1)!, {'a': 'b'});
      editor.undo();
      expect(editor.canRedo, isTrue);
      editor.setTags(editor.node(2)!, {'c': 'd'});
      expect(editor.canRedo, isFalse);
      expect(editor.redo(), isFalse);
    });

    test('cannot redo what was given up on', () {
      final editor = _square();
      final mark = editor.mark();
      editor.createNode(latitude: 1, longitude: 1);
      editor.undoSince(mark);
      expect(editor.canRedo, isFalse);
    });
  });

  test('says a way with too few nodes left is no way at all', () {
    expect(testWay(1, [1, 2]).isDegenerate, isFalse);
    expect(testWay(1, [1, 1]).isDegenerate, isTrue);
    expect(testWay(1, [1]).isDegenerate, isTrue);
    expect(testWay(1, [1, 2, 3, 1]).isDegenerate, isFalse);
    expect(testWay(1, [1, 2, 1]).isDegenerate, isTrue);
  });

  test('says which regions something is in once the borders are known', () {
    final editor = _square();
    final rules = editor.rules as OsmStandardTagRules;
    expect(rules.regionsOf(editor.way(10)!, editor), isEmpty);
    rules.countryCoder = OsmCountryCoder.parse(_borders);
    expect(rules.regionsOf(editor.way(10)!, editor), contains('xa'));
    expect(rules.regionsOf(editor.node(5)!, editor), contains('xa'));
  });

  test('edits what was read from a file as it is', () {
    final subset = OsmSubset(
      matches: const [],
      nodes: {
        for (final id in [1, 2, 3]) id: testNode(id, 0, id / 1000)
      },
      ways: {
        10: testWay(10, [1, 2, 3], {'highway': 'path'})
      },
      relations: {
        20: const OsmRelation(
          id: 20,
          members: [OsmMember(type: OsmElementType.way, ref: 10, role: '')],
        ),
      },
    );
    final editor = OsmEditor(subset);
    expect(editor.waysUsing(2).single.id, 10);
    expect(editor.relationsUsing(OsmElementType.way, 10).single.id, 20);
    editor.deleteNode(editor.node(2)!);
    expect(editor.way(10)!.nodeIds, [1, 3]);
  });

  test('tells whoever asked when something changes', () {
    var told = 0;
    final editor = OsmEditor(
      OsmElementSource.of(const []),
      onChanged: () => told++,
    );
    editor.createNode(latitude: 0, longitude: 0);
    editor.undo();
    expect(told, 2);
  });

  test('retags a relation, and undoes and redoes it', () {
    final editor = editorOf([
      const OsmRelation(
        id: 20,
        members: [],
        tags: {'type': 'route'},
        info: OsmInfo(version: 1),
      ),
    ]);
    editor.setTags(editor.relation(20)!, {'type': 'route', 'name': 'A'});
    expect(editor.relation(20)!.tags['name'], 'A');
    expect(editor.history.toUpload().changedRelations.single.id, 20);
    editor.undo();
    expect(editor.relation(20)!.tags['name'], isNull);
    editor.redo();
    expect(editor.relation(20)!.tags['name'], 'A');
  });

  test('merges an area into the multipolygon beside it', () {
    final editor = testEditor(
      nodes: [
        for (var i = 0; i < 8; i++)
          testNode(i + 1, (i ~/ 4) * 0.01, (i % 4) * 0.001),
      ],
      ways: [
        testWay(10, [1, 2, 6, 5, 1], {'building': 'yes'}),
        testWay(11, [3, 4, 8, 7, 3], {'building': 'yes'}),
      ],
      relations: [
        const OsmRelation(
          id: 20,
          members: [
            OsmMember(type: OsmElementType.way, ref: 10, role: 'outer'),
          ],
          tags: {'type': 'multipolygon', 'building': 'yes'},
        ),
      ],
    );
    editor.merge([editor.relation(20)!, editor.way(11)!]).apply();
    final merged = editor.relation(20)!;
    expect(merged.members.map((m) => m.ref), unorderedEquals([10, 11]));
    expect(merged.tags, {'type': 'multipolygon', 'building': 'yes'});
  });

  test('makes nodes one, as an operation', () {
    final editor = testEditor(
      nodes: [testNode(1, 0, 0), testNode(2, 0, 0.001), testNode(3, 1, 1)],
      ways: [
        testWay(10, [1, 3]),
        testWay(11, [2, 3]),
      ],
    );
    expect(editor.connect([editor.node(1)!]).available, isFalse);
    final connect = editor.connect([editor.node(1)!, editor.node(2)!]);
    expect(connect.available, isTrue);
    expect(connect.disabled, isNull);
    connect.apply();
    expect(editor.way(10)!.nodeIds.first, editor.way(11)!.nodeIds.first);
    expect(editor.history.length, 1);
  });
}

const _borders = '{"type":"FeatureCollection","features":[{"type":"Feature",'
    '"properties":{"iso1A2":"XA","nameEn":"Examplia"},'
    '"geometry":{"type":"Polygon","coordinates":'
    '[[[-1,-1],[1,-1],[1,1],[-1,1],[-1,-1]]]}}]}';
