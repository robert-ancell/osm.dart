import 'package:osm/osm.dart';
import 'package:test/test.dart';

const _node = OsmNode(
  id: 1,
  latitude: -36.85,
  longitude: 174.76,
  tags: {'highway': 'crossing'},
  info: OsmInfo(version: 3),
);

void main() {
  test('holds nothing to begin with', () {
    final edits = OsmEdits();
    expect(edits.isEmpty, isTrue);
    expect(edits.changes, isEmpty);
    expect(edits.movedNode(1), isNull);
    expect(edits.undo(), isFalse);
  });

  test('moves a node without touching what was read', () {
    final edits = OsmEdits();
    edits.moveNode(_node, latitude: -36.86, longitude: 174.77);

    expect(edits.movedNode(1)!.latitude, -36.86);
    expect(edits.movedNode(1)!.longitude, 174.77);
    // The element it was given is the same as it ever was.
    expect(_node.latitude, -36.85);
    expect(_node.longitude, 174.76);
  });

  test('keeps what a node was tagged with and where it came from', () {
    final edits = OsmEdits();
    edits.moveNode(_node, latitude: -36.86, longitude: 174.77);
    expect(edits.movedNode(1)!.tags, _node.tags);
    expect(edits.movedNode(1)!.info!.version, 3);
  });

  test('writes down each change in the order it was made', () {
    final edits = OsmEdits();
    edits.moveNode(_node, latitude: -36.86, longitude: 174.77);
    edits.moveNode(_node, latitude: -36.87, longitude: 174.78);
    expect(edits.length, 2);
    expect(edits.changes.first, isA<OsmNodeMoved>());
    expect((edits.changes.first as OsmNodeMoved).from.latitude, -36.85);
    expect((edits.changes.last as OsmNodeMoved).to.latitude, -36.87);
  });

  test('counts a drag as one change rather than one a frame', () {
    final edits = OsmEdits();
    edits.moveNode(_node, latitude: -36.86, longitude: 174.77);
    for (var i = 0; i < 20; i++) {
      edits.moveNode(
        _node,
        latitude: -36.86 - i / 10000,
        longitude: 174.77,
        continuing: true,
      );
    }
    expect(edits.length, 1);
    // And undoing it goes back to where the node started, not to the frame
    // before last.
    edits.undo();
    expect(edits.movedNode(1), isNull);
  });

  test('undoes the last change and leaves the one before it', () {
    final edits = OsmEdits();
    edits.moveNode(_node, latitude: -36.86, longitude: 174.77);
    edits.moveNode(_node, latitude: -36.87, longitude: 174.78);

    expect(edits.undo(), isTrue);
    expect(edits.length, 1);
    expect(edits.movedNode(1)!.latitude, -36.86);

    expect(edits.undo(), isTrue);
    expect(edits.isEmpty, isTrue);
    expect(edits.movedNode(1), isNull);
  });

  test('undoes changes to different nodes one at a time', () {
    const other = OsmNode(id: 2, latitude: -36.85, longitude: 174.76);
    final edits = OsmEdits();
    edits.moveNode(_node, latitude: -36.86, longitude: 174.77);
    edits.moveNode(other, latitude: -36.88, longitude: 174.79);

    edits.undo();
    expect(edits.movedNode(2), isNull);
    expect(edits.movedNode(1), isNotNull, reason: 'the other one still moved');
  });

  test('undoes everything at once', () {
    final edits = OsmEdits();
    edits.moveNode(_node, latitude: -36.86, longitude: 174.77);
    edits.moveNode(_node, latitude: -36.87, longitude: 174.78);
    edits.undoAll();
    expect(edits.isEmpty, isTrue);
    expect(edits.movedNodes, isEmpty);
  });

  test('says when something has changed', () {
    var told = 0;
    final edits = OsmEdits(onChanged: () => told++);
    edits.moveNode(_node, latitude: -36.86, longitude: 174.77);
    expect(told, 1);
    edits.undo();
    expect(told, 2);
    edits.undo();
    expect(told, 2, reason: 'nothing changed, nothing said');
  });

  test('says what has to be drawn again', () {
    final edits = OsmEdits();
    edits.moveNode(_node, latitude: -36.86, longitude: 174.77);
    final touched = edits.touching((id) => id == 1 ? [10, 11] : const []);
    expect(touched, contains((OsmElementType.node, 1)));
    expect(touched, contains((OsmElementType.way, 10)));
    expect(touched, contains((OsmElementType.way, 11)));
    expect(touched.length, 3);
  });

  test('says nothing has to be drawn again when nothing has changed', () {
    expect(OsmEdits().touching((_) => [1, 2]), isEmpty);
  });

  test('hands out a list of changes that cannot be written to', () {
    final edits = OsmEdits();
    edits.moveNode(_node, latitude: -36.86, longitude: 174.77);
    expect(() => edits.changes.clear(), throwsUnsupportedError);
    expect(() => edits.movedNodes.clear(), throwsUnsupportedError);
  });
}
