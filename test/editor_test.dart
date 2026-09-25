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

  test('says a closed building is an area without any presets', () {
    final editor = _square();
    expect(editor.geometryOf(editor.way(10)!), OsmGeometry.area);
    final other = OsmEditor(editor.data, isArea: (tags) => false);
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
      roundTrip((e) => e.deleteNode(e.node(2)!, from: e.waysUsing(2)));
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
      final mark = editor.history.length;
      editor.createNode(latitude: 1, longitude: 1);
      editor.history.undoSince(mark);
      expect(editor.canRedo, isFalse);
    });
  });
}
