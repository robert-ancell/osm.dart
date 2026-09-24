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
    expect(edits.changedNode(1), isNull);
    expect(edits.undo(), isFalse);
  });

  test('moves a node without touching what was read', () {
    final edits = OsmEdits();
    edits.moveNode(_node, latitude: -36.86, longitude: 174.77);

    expect(edits.changedNode(1)!.latitude, -36.86);
    expect(edits.changedNode(1)!.longitude, 174.77);
    // The element it was given is the same as it ever was.
    expect(_node.latitude, -36.85);
    expect(_node.longitude, 174.76);
  });

  test('keeps what a node was tagged with and where it came from', () {
    final edits = OsmEdits();
    edits.moveNode(_node, latitude: -36.86, longitude: 174.77);
    expect(edits.changedNode(1)!.tags, _node.tags);
    expect(edits.changedNode(1)!.info!.version, 3);
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
    expect(edits.changedNode(1), isNull);
  });

  test('undoes the last change and leaves the one before it', () {
    final edits = OsmEdits();
    edits.moveNode(_node, latitude: -36.86, longitude: 174.77);
    edits.moveNode(_node, latitude: -36.87, longitude: 174.78);

    expect(edits.undo(), isTrue);
    expect(edits.length, 1);
    expect(edits.changedNode(1)!.latitude, -36.86);

    expect(edits.undo(), isTrue);
    expect(edits.isEmpty, isTrue);
    expect(edits.changedNode(1), isNull);
  });

  test('undoes changes to different nodes one at a time', () {
    const other = OsmNode(id: 2, latitude: -36.85, longitude: 174.76);
    final edits = OsmEdits();
    edits.moveNode(_node, latitude: -36.86, longitude: 174.77);
    edits.moveNode(other, latitude: -36.88, longitude: 174.79);

    edits.undo();
    expect(edits.changedNode(2), isNull);
    expect(edits.changedNode(1), isNotNull,
        reason: 'the other one still moved');
  });

  test('undoes everything at once', () {
    final edits = OsmEdits();
    edits.moveNode(_node, latitude: -36.86, longitude: 174.77);
    edits.moveNode(_node, latitude: -36.87, longitude: 174.78);
    edits.undoAll();
    expect(edits.isEmpty, isTrue);
    expect(edits.changedNodes, isEmpty);
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
  _groups();

  test('hands out a list of changes that cannot be written to', () {
    final edits = OsmEdits();
    edits.moveNode(_node, latitude: -36.86, longitude: 174.77);
    expect(() => edits.changes.clear(), throwsUnsupportedError);
    expect(() => edits.changedNodes.clear(), throwsUnsupportedError);
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
      expect(edits.changedNode(made.id), made);
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
      expect(edits.changedNode(made.id), isNull);
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
      expect(edits.changedNode(_node.id), isNull);
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
      expect(edits.changedNode(_node.id), isNull);

      edits.undo();
      expect(edits.changedNode(_node.id)!.latitude, -36.9);
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
    expect(edits.changedNodes, isEmpty);
    expect(edits.isGone(OsmElementType.node, _node.id), isFalse);
  });
}

void _groups() {
  group('changes made as one', () {
    test('gathers what was done since a mark', () {
      final edits = OsmEdits();
      final mark = edits.length;
      final first = edits.createNode(latitude: 0, longitude: 0);
      final second = edits.createNode(latitude: 1, longitude: 1);
      edits.createWay(nodeIds: [first.id, second.id]);
      expect(edits.length, 3);

      edits.combineSince(mark);
      expect(edits.length, 1);
      expect(edits.changes.single, isA<OsmEditGroup>());
    });

    test('undoes the whole of it at once', () {
      final edits = OsmEdits();
      final mark = edits.length;
      final first = edits.createNode(latitude: 0, longitude: 0);
      final second = edits.createNode(latitude: 1, longitude: 1);
      final way = edits.createWay(nodeIds: [first.id, second.id]);
      edits.combineSince(mark);

      expect(edits.undo(), isTrue);
      expect(edits.isEmpty, isTrue);
      expect(edits.changedWay(way.id), isNull);
      expect(edits.changedNode(first.id), isNull);
      expect(edits.changedNode(second.id), isNull);
    });

    test('leaves what was done before the mark alone', () {
      final edits = OsmEdits();
      final kept = edits.createNode(latitude: 5, longitude: 5);
      final mark = edits.length;
      final first = edits.createNode(latitude: 0, longitude: 0);
      edits.createWay(nodeIds: [first.id]);
      edits.combineSince(mark);

      edits.undo();
      expect(edits.length, 1);
      expect(edits.changedNode(kept.id), isNotNull);
    });

    test('gathers nothing when there is nothing to gather', () {
      final edits = OsmEdits();
      edits.createNode(latitude: 0, longitude: 0);
      final mark = edits.length;
      edits.combineSince(mark);
      expect(edits.length, 1);
      expect(edits.changes.single, isA<OsmNodeCreated>());

      edits.createNode(latitude: 1, longitude: 1);
      edits.combineSince(mark);
      expect(edits.length, 2, reason: 'one change is not a group');
    });

    test('undoes a group of moves back to where things started', () {
      const node = OsmNode(id: 1, latitude: 0, longitude: 0);
      final edits = OsmEdits();
      final mark = edits.length;
      edits.moveNode(node, latitude: 1, longitude: 1);
      edits.moveNode(node, latitude: 2, longitude: 2);
      edits.combineSince(mark);

      edits.undo();
      expect(edits.changedNode(1), isNull);
    });
  });

  test('undoes a move of a node that was made as part of a group', () {
    // A line drawn a point at a time is one change; moving one of its points
    // afterwards and taking that back must leave the point where it was put,
    // not take it away from under the line.
    final edits = OsmEdits();
    final mark = edits.length;
    final a = edits.createNode(latitude: 1, longitude: 1);
    final b = edits.createNode(latitude: 2, longitude: 2);
    edits.createWay(nodeIds: [a.id, b.id]);
    edits.combineSince(mark);

    edits.moveNode(a, latitude: 5, longitude: 5);
    edits.undo();
    expect(edits.changedNode(a.id)?.latitude, 1);
    expect(edits.changedNode(a.id)?.longitude, 1);
  });

  group('tags', () {
    const way = OsmWay(
      id: 9,
      nodeIds: [1, 2],
      tags: {'highway': 'residential'},
      info: OsmInfo(version: 4),
    );

    test('gives a node other tags and keeps everything else', () {
      final edits = OsmEdits();
      expect(edits.setTags(_node, const {'amenity': 'bench'}), isTrue);
      final now = edits.changedNode(1)!;
      expect(now.tags, {'amenity': 'bench'});
      expect(now.latitude, _node.latitude);
      expect(now.info?.version, 3);
    });

    test('gives a way other tags and keeps its nodes', () {
      final edits = OsmEdits();
      edits.setTags(way, const {'highway': 'service'});
      expect(edits.changedWay(9)!.tags, {'highway': 'service'});
      expect(edits.changedWay(9)!.nodeIds, [1, 2]);
    });

    test('records nothing when the tags are already those', () {
      final edits = OsmEdits();
      expect(edits.setTags(_node, const {'highway': 'crossing'}), isFalse);
      expect(edits.isEmpty, isTrue);
      expect(edits.changedNode(1), isNull);
    });

    test('undoes back to what was read', () {
      final edits = OsmEdits()..setTags(way, const {'highway': 'service'});
      edits.undo();
      expect(edits.changedWay(9), isNull);
    });

    test('keeps new tags through a move and its undoing', () {
      final edits = OsmEdits()..setTags(_node, const {'amenity': 'bench'});
      final tagged = edits.changedNode(1)!;
      edits.moveNode(tagged, latitude: 0, longitude: 0);
      edits.undo();
      expect(edits.changedNode(1)!.tags, {'amenity': 'bench'});
      expect(edits.changedNode(1)!.latitude, _node.latitude);
      edits.undo();
      expect(edits.changedNode(1), isNull);
    });

    test('keeps a move through a change of tags and its undoing', () {
      final edits = OsmEdits()
        ..moveNode(_node, latitude: 0, longitude: 0)
        ..setTags(_node, const {'amenity': 'bench'});
      expect(edits.changedNode(1)!.latitude, 0);
      edits.undo();
      expect(edits.changedNode(1)!.latitude, 0);
      expect(edits.changedNode(1)!.tags, _node.tags);
    });

    test('brings a retagged node back retagged when its deletion is undone',
        () {
      final edits = OsmEdits()..setTags(_node, const {'amenity': 'bench'});
      edits.deleteNode(edits.changedNode(1)!);
      expect(edits.deletedNodes[1]!.tags, {'amenity': 'bench'});
      edits.undo();
      expect(edits.isGone(OsmElementType.node, 1), isFalse);
      expect(edits.changedNode(1)!.tags, {'amenity': 'bench'});
    });

    test('changes several elements as one', () {
      final edits = OsmEdits();
      final mark = edits.length;
      edits
        ..setTags(_node, const {'name': 'Queen Street'})
        ..setTags(way, const {'name': 'Queen Street'})
        ..combineSince(mark);
      expect(edits.length, 1);
      edits.undo();
      expect(edits.changedNode(1), isNull);
      expect(edits.changedWay(9), isNull);
    });

    test('will not tag a relation', () {
      const relation = OsmRelation(id: 3, members: [], tags: {});
      expect(
        () => OsmEdits().setTags(relation, const {'type': 'route'}),
        throwsArgumentError,
      );
    });

    test('sends a retagged node with its new tags', () {
      final edits = OsmEdits()..setTags(_node, const {'amenity': 'bench'});
      final xml = OsmUpload.of(edits).toXml(changeset: 1, generator: 'test');
      expect(xml, contains('<tag k="amenity" v="bench"/>'));
      expect(xml, isNot(contains('crossing')));
      expect(OsmUpload.of(edits).describe(), ['Change node/1']);
    });
  });
}
