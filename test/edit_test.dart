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

  _more();

  test('hands out a list of changes that cannot be written to', () {
    final edits = OsmEdits();
    edits.moveNode(_node, latitude: -36.86, longitude: 174.77);
    expect(() => edits.changes.clear(), throwsUnsupportedError);
    expect(() => edits.movedNodes.clear(), throwsUnsupportedError);
  });
}

const _way = OsmWay(
  id: 10,
  nodeIds: [1, 2, 3],
  tags: {'highway': 'residential'},
);

void _more() {
  group('making things', () {
    test('makes a node with an id of its own', () {
      final edits = OsmEdits();
      final made = edits.createNode(latitude: -36.85, longitude: 174.76);
      expect(made.id, lessThan(0), reason: 'not uploaded yet');
      expect(edits.movedNode(made.id), made);
      expect(edits.changes.single, isA<OsmNodeCreated>());
    });

    test('gives every new thing a different id', () {
      final edits = OsmEdits();
      final first = edits.createNode(latitude: 0, longitude: 0);
      final second = edits.createNode(latitude: 0, longitude: 0);
      final way = edits.createWay(nodeIds: [first.id, second.id]);
      expect({first.id, second.id, way.id}.length, 3);
    });

    test('makes a way through the nodes it is given', () {
      final edits = OsmEdits();
      final way = edits.createWay(
        nodeIds: [1, 2],
        tags: const {'highway': 'footway'},
      );
      expect(edits.changedWay(way.id)!.nodeIds, [1, 2]);
      expect(edits.changedWay(way.id)!.tags['highway'], 'footway');
    });

    test('undoes making a node', () {
      final edits = OsmEdits();
      final made = edits.createNode(latitude: 0, longitude: 0);
      edits.undo();
      expect(edits.movedNode(made.id), isNull);
      expect(edits.isEmpty, isTrue);
    });

    test('undoes making a way', () {
      final edits = OsmEdits();
      final way = edits.createWay(nodeIds: [1, 2]);
      edits.undo();
      expect(edits.changedWay(way.id), isNull);
    });
  });

  group('changing what a way runs through', () {
    test('puts a way through other nodes', () {
      final edits = OsmEdits();
      edits.setWayNodes(_way, [1, 4, 2, 3]);
      expect(edits.changedWay(10)!.nodeIds, [1, 4, 2, 3]);
      expect(edits.changedWay(10)!.tags, _way.tags);
    });

    test('undoes back to what it ran through before', () {
      final edits = OsmEdits();
      edits.setWayNodes(_way, [1, 4, 2, 3]);
      edits.setWayNodes(edits.changedWay(10)!, [1, 4, 5, 2, 3]);
      expect(edits.changedWay(10)!.nodeIds.length, 5);

      edits.undo();
      expect(edits.changedWay(10)!.nodeIds, [1, 4, 2, 3]);
      edits.undo();
      expect(edits.changedWay(10), isNull, reason: 'back to what was read');
    });
  });

  group('taking things off the map', () {
    test('deletes a node', () {
      final edits = OsmEdits();
      edits.deleteNode(_node);
      expect(edits.isGone(OsmElementType.node, _node.id), isTrue);
      expect(edits.movedNode(_node.id), isNull);
    });

    test('takes a deleted node out of the ways through it', () {
      final edits = OsmEdits();
      const node = OsmNode(id: 2, latitude: 0, longitude: 0);
      edits.deleteNode(node, from: [_way]);
      expect(edits.changedWay(10)!.nodeIds, [1, 3]);
    });

    test('undoes a deletion, ways and all', () {
      final edits = OsmEdits();
      const node = OsmNode(id: 2, latitude: 0, longitude: 0);
      edits.deleteNode(node, from: [_way]);

      edits.undo();
      expect(edits.isGone(OsmElementType.node, 2), isFalse);
      expect(edits.changedWay(10), isNull, reason: 'the way runs as it was');
    });

    test('keeps a node that had been moved where it was moved to', () {
      final edits = OsmEdits();
      edits.moveNode(_node, latitude: -36.9, longitude: 174.9);
      edits.deleteNode(_node);
      expect(edits.movedNode(_node.id), isNull);

      edits.undo();
      expect(edits.movedNode(_node.id)!.latitude, -36.9);
    });

    test('says a deleted node has to be drawn again', () {
      final edits = OsmEdits();
      edits.deleteNode(_node, from: [_way]);
      final touched = edits.touching((id) => id == _node.id ? [10] : const []);
      expect(touched, contains((OsmElementType.node, _node.id)));
      expect(touched, contains((OsmElementType.way, 10)));
    });
  });

  test('undoes everything at once whatever was done', () {
    final edits = OsmEdits();
    final made = edits.createNode(latitude: 0, longitude: 0);
    edits.createWay(nodeIds: [made.id]);
    edits.deleteNode(_node);
    edits.undoAll();
    expect(edits.isEmpty, isTrue);
    expect(edits.changedWays, isEmpty);
    expect(edits.movedNodes, isEmpty);
    expect(edits.isGone(OsmElementType.node, _node.id), isFalse);
  });
}
