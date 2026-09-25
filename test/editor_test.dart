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
}
