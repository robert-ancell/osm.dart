import 'package:osm/editor.dart';
import 'package:osm/osm.dart';
import 'package:test/test.dart';

import 'test_editor.dart';

const _node = OsmNode(
  id: 1,
  latitude: -36.85,
  longitude: 174.76,
  tags: {'highway': 'crossing'},
  info: OsmInfo(version: 3),
);

void main() {
  test('holds nothing to begin with', () {
    final edits = editorOf();
    expect(edits.history.isEmpty, isTrue);
    expect(edits.history.changes, isEmpty);
    expect(edits.history.changedNode(1), isNull);
    expect(edits.undo(), isFalse);
  });

  test('moves a node without touching what was read', () {
    final edits = editorOf();
    edits.moveNode(_node, latitude: -36.86, longitude: 174.77);

    expect(edits.history.changedNode(1)!.latitude, -36.86);
    expect(edits.history.changedNode(1)!.longitude, 174.77);
    // The element it was given is the same as it ever was.
    expect(_node.latitude, -36.85);
    expect(_node.longitude, 174.76);
  });

  test('keeps what a node was tagged with and where it came from', () {
    final edits = editorOf();
    edits.moveNode(_node, latitude: -36.86, longitude: 174.77);
    expect(edits.history.changedNode(1)!.tags, _node.tags);
    expect(edits.history.changedNode(1)!.info!.version, 3);
  });

  test('writes down each change in the order it was made', () {
    final edits = editorOf();
    edits.moveNode(_node, latitude: -36.86, longitude: 174.77);
    edits.moveNode(_node, latitude: -36.87, longitude: 174.78);
    expect(edits.history.length, 2);
    expect(edits.history.changes.first, isA<OsmNodeMoved>());
    expect((edits.history.changes.first as OsmNodeMoved).from.latitude, -36.85);
    expect((edits.history.changes.last as OsmNodeMoved).to.latitude, -36.87);
  });

  test('counts a drag as one change rather than one a frame', () {
    final edits = editorOf();
    edits.moveNode(_node, latitude: -36.86, longitude: 174.77);
    for (var i = 0; i < 20; i++) {
      edits.moveNode(
        _node,
        latitude: -36.86 - i / 10000,
        longitude: 174.77,
        continuing: true,
      );
    }
    expect(edits.history.length, 1);
    // And undoing it goes back to where the node started, not to the frame
    // before last.
    edits.undo();
    expect(edits.history.changedNode(1), isNull);
  });

  test('undoes the last change and leaves the one before it', () {
    final edits = editorOf();
    edits.moveNode(_node, latitude: -36.86, longitude: 174.77);
    edits.moveNode(_node, latitude: -36.87, longitude: 174.78);

    expect(edits.undo(), isTrue);
    expect(edits.history.length, 1);
    expect(edits.history.changedNode(1)!.latitude, -36.86);

    expect(edits.undo(), isTrue);
    expect(edits.history.isEmpty, isTrue);
    expect(edits.history.changedNode(1), isNull);
  });

  test('undoes changes to different nodes one at a time', () {
    const other = OsmNode(id: 2, latitude: -36.85, longitude: 174.76);
    final edits = editorOf();
    edits.moveNode(_node, latitude: -36.86, longitude: 174.77);
    edits.moveNode(other, latitude: -36.88, longitude: 174.79);

    edits.undo();
    expect(edits.history.changedNode(2), isNull);
    expect(edits.history.changedNode(1), isNotNull,
        reason: 'the other one still moved');
  });

  test('undoes everything at once', () {
    final edits = editorOf();
    edits.moveNode(_node, latitude: -36.86, longitude: 174.77);
    edits.moveNode(_node, latitude: -36.87, longitude: 174.78);
    edits.undoAll();
    expect(edits.history.isEmpty, isTrue);
    expect(edits.history.changedNodes, isEmpty);
  });

  test('says when something has changed', () {
    var told = 0;
    final edits = OsmEditor(
      OsmEditorData.of(const []),
      history: OsmEditHistory(onChanged: () => told++),
    );
    edits.moveNode(_node, latitude: -36.86, longitude: 174.77);
    expect(told, 1);
    edits.undo();
    expect(told, 2);
    edits.undo();
    expect(told, 2, reason: 'nothing changed, nothing said');
  });

  _more();
  _groups();

  test('hands out a list of changes that cannot be written to', () {
    final edits = editorOf();
    edits.moveNode(_node, latitude: -36.86, longitude: 174.77);
    expect(() => edits.history.changes.clear(), throwsUnsupportedError);
    expect(() => edits.history.changedNodes.clear(), throwsUnsupportedError);
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
      final edits = editorOf();
      final made = edits.createNode(latitude: -36.85, longitude: 174.76);
      expect(made.id, lessThan(0), reason: 'not uploaded yet');
      expect(edits.history.changedNode(made.id), made);
      expect(edits.history.changes.single, isA<OsmNodeCreated>());
    });

    test('gives every new thing a different id', () {
      final edits = editorOf();
      final first = edits.createNode(latitude: 0, longitude: 0);
      final second = edits.createNode(latitude: 0, longitude: 0);
      final way = edits.createWay(nodeIds: [first.id, second.id]);
      expect({first.id, second.id, way.id}.length, 3);
    });

    test('makes a way through the nodes it is given', () {
      final edits = editorOf();
      final way = edits.createWay(
        nodeIds: [1, 2],
        tags: const {'highway': 'footway'},
      );
      expect(edits.history.changedWay(way.id)!.nodeIds, [1, 2]);
      expect(edits.history.changedWay(way.id)!.tags['highway'], 'footway');
    });

    test('undoes making a node', () {
      final edits = editorOf();
      final made = edits.createNode(latitude: 0, longitude: 0);
      edits.undo();
      expect(edits.history.changedNode(made.id), isNull);
      expect(edits.history.isEmpty, isTrue);
    });

    test('undoes making a way', () {
      final edits = editorOf();
      final way = edits.createWay(nodeIds: [1, 2]);
      edits.undo();
      expect(edits.history.changedWay(way.id), isNull);
    });
  });

  group('changing what a way runs through', () {
    test('puts a way through other nodes', () {
      final edits = editorOf();
      edits.setWayNodes(_way, [1, 4, 2, 3]);
      expect(edits.history.changedWay(10)!.nodeIds, [1, 4, 2, 3]);
      expect(edits.history.changedWay(10)!.tags, _way.tags);
    });

    test('undoes back to what it ran through before', () {
      final edits = editorOf();
      edits.setWayNodes(_way, [1, 4, 2, 3]);
      edits.setWayNodes(edits.history.changedWay(10)!, [1, 4, 5, 2, 3]);
      expect(edits.history.changedWay(10)!.nodeIds.length, 5);

      edits.undo();
      expect(edits.history.changedWay(10)!.nodeIds, [1, 4, 2, 3]);
      edits.undo();
      expect(edits.history.changedWay(10), isNull,
          reason: 'back to what was read');
    });
  });

  group('taking things off the map', () {
    test('deletes a node', () {
      final edits = editorOf();
      edits.deleteNode(_node);
      expect(edits.history.isGone(OsmElementType.node, _node.id), isTrue);
      expect(edits.history.changedNode(_node.id), isNull);
    });

    test('takes a deleted node out of the ways through it', () {
      final edits = editorOf([_way]);
      const node = OsmNode(id: 2, latitude: 0, longitude: 0);
      edits.deleteNode(node);
      expect(edits.history.changedWay(10)!.nodeIds, [1, 3]);
    });

    test('undoes a deletion, ways and all', () {
      final edits = editorOf([_way]);
      const node = OsmNode(id: 2, latitude: 0, longitude: 0);
      edits.deleteNode(node);

      edits.undo();
      expect(edits.history.isGone(OsmElementType.node, 2), isFalse);
      expect(edits.history.changedWay(10), isNull,
          reason: 'the way runs as it was');
    });

    test('keeps a node that had been moved where it was moved to', () {
      final edits = editorOf();
      edits.moveNode(_node, latitude: -36.9, longitude: 174.9);
      edits.deleteNode(_node);
      expect(edits.history.changedNode(_node.id), isNull);

      edits.undo();
      expect(edits.history.changedNode(_node.id)!.latitude, -36.9);
    });
  });

  test('undoes everything at once whatever was done', () {
    final edits = editorOf();
    final made = edits.createNode(latitude: 0, longitude: 0);
    edits.createWay(nodeIds: [made.id]);
    edits.deleteNode(_node);
    edits.undoAll();
    expect(edits.history.isEmpty, isTrue);
    expect(edits.history.changedWays, isEmpty);
    expect(edits.history.changedNodes, isEmpty);
    expect(edits.history.isGone(OsmElementType.node, _node.id), isFalse);
  });
}

void _groups() {
  group('changes made as one', () {
    test('gathers what was done since a mark', () {
      final edits = editorOf();
      final mark = edits.history.length;
      final first = edits.createNode(latitude: 0, longitude: 0);
      final second = edits.createNode(latitude: 1, longitude: 1);
      edits.createWay(nodeIds: [first.id, second.id]);
      expect(edits.history.length, 3);

      edits.combineSince(mark);
      expect(edits.history.length, 1);
      expect(edits.history.changes.single, isA<OsmEditGroup>());
    });

    test('undoes the whole of it at once', () {
      final edits = editorOf();
      final mark = edits.history.length;
      final first = edits.createNode(latitude: 0, longitude: 0);
      final second = edits.createNode(latitude: 1, longitude: 1);
      final way = edits.createWay(nodeIds: [first.id, second.id]);
      edits.combineSince(mark);

      expect(edits.undo(), isTrue);
      expect(edits.history.isEmpty, isTrue);
      expect(edits.history.changedWay(way.id), isNull);
      expect(edits.history.changedNode(first.id), isNull);
      expect(edits.history.changedNode(second.id), isNull);
    });

    test('leaves what was done before the mark alone', () {
      final edits = editorOf();
      final kept = edits.createNode(latitude: 5, longitude: 5);
      final mark = edits.history.length;
      final first = edits.createNode(latitude: 0, longitude: 0);
      edits.createWay(nodeIds: [first.id]);
      edits.combineSince(mark);

      edits.undo();
      expect(edits.history.length, 1);
      expect(edits.history.changedNode(kept.id), isNotNull);
    });

    test('gathers nothing when there is nothing to gather', () {
      final edits = editorOf();
      edits.createNode(latitude: 0, longitude: 0);
      final mark = edits.history.length;
      edits.combineSince(mark);
      expect(edits.history.length, 1);
      expect(edits.history.changes.single, isA<OsmNodeCreated>());

      edits.createNode(latitude: 1, longitude: 1);
      edits.combineSince(mark);
      expect(edits.history.length, 2, reason: 'one change is not a group');
    });

    test('undoes a group of moves back to where things started', () {
      const node = OsmNode(id: 1, latitude: 0, longitude: 0);
      final edits = editorOf();
      final mark = edits.history.length;
      edits.moveNode(node, latitude: 1, longitude: 1);
      edits.moveNode(node, latitude: 2, longitude: 2);
      edits.combineSince(mark);

      edits.undo();
      expect(edits.history.changedNode(1), isNull);
    });
  });

  test('undoes a move of a node that was made as part of a group', () {
    // A line drawn a point at a time is one change; moving one of its points
    // afterwards and taking that back must leave the point where it was put,
    // not take it away from under the line.
    final edits = editorOf();
    final mark = edits.history.length;
    final a = edits.createNode(latitude: 1, longitude: 1);
    final b = edits.createNode(latitude: 2, longitude: 2);
    edits.createWay(nodeIds: [a.id, b.id]);
    edits.combineSince(mark);

    edits.moveNode(a, latitude: 5, longitude: 5);
    edits.undo();
    expect(edits.history.changedNode(a.id)?.latitude, 1);
    expect(edits.history.changedNode(a.id)?.longitude, 1);
  });

  group('tags', () {
    const way = OsmWay(
      id: 9,
      nodeIds: [1, 2],
      tags: {'highway': 'residential'},
      info: OsmInfo(version: 4),
    );

    test('gives a node other tags and keeps everything else', () {
      final edits = editorOf();
      expect(edits.setTags(_node, const {'amenity': 'bench'}), isTrue);
      final now = edits.history.changedNode(1)!;
      expect(now.tags, {'amenity': 'bench'});
      expect(now.latitude, _node.latitude);
      expect(now.info?.version, 3);
    });

    test('gives a way other tags and keeps its nodes', () {
      final edits = editorOf();
      edits.setTags(way, const {'highway': 'service'});
      expect(edits.history.changedWay(9)!.tags, {'highway': 'service'});
      expect(edits.history.changedWay(9)!.nodeIds, [1, 2]);
    });

    test('records nothing when the tags are already those', () {
      final edits = editorOf();
      expect(edits.setTags(_node, const {'highway': 'crossing'}), isFalse);
      expect(edits.history.isEmpty, isTrue);
      expect(edits.history.changedNode(1), isNull);
    });

    test('undoes back to what was read', () {
      final edits = editorOf()..setTags(way, const {'highway': 'service'});
      edits.undo();
      expect(edits.history.changedWay(9), isNull);
    });

    test('keeps new tags through a move and its undoing', () {
      final edits = editorOf()..setTags(_node, const {'amenity': 'bench'});
      final tagged = edits.history.changedNode(1)!;
      edits.moveNode(tagged, latitude: 0, longitude: 0);
      edits.undo();
      expect(edits.history.changedNode(1)!.tags, {'amenity': 'bench'});
      expect(edits.history.changedNode(1)!.latitude, _node.latitude);
      edits.undo();
      expect(edits.history.changedNode(1), isNull);
    });

    test('keeps a move through a change of tags and its undoing', () {
      final edits = editorOf()
        ..moveNode(_node, latitude: 0, longitude: 0)
        ..setTags(_node, const {'amenity': 'bench'});
      expect(edits.history.changedNode(1)!.latitude, 0);
      edits.undo();
      expect(edits.history.changedNode(1)!.latitude, 0);
      expect(edits.history.changedNode(1)!.tags, _node.tags);
    });

    test('brings a retagged node back retagged when its deletion is undone',
        () {
      final edits = editorOf()..setTags(_node, const {'amenity': 'bench'});
      edits.deleteNode(edits.history.changedNode(1)!);
      expect(edits.history.deletedNodes[1]!.tags, {'amenity': 'bench'});
      edits.undo();
      expect(edits.history.isGone(OsmElementType.node, 1), isFalse);
      expect(edits.history.changedNode(1)!.tags, {'amenity': 'bench'});
    });

    test('changes several elements as one', () {
      final edits = editorOf();
      final mark = edits.history.length;
      edits
        ..setTags(_node, const {'name': 'Queen Street'})
        ..setTags(way, const {'name': 'Queen Street'})
        ..combineSince(mark);
      expect(edits.history.length, 1);
      edits.undo();
      expect(edits.history.changedNode(1), isNull);
      expect(edits.history.changedWay(9), isNull);
    });

    test('will not tag a relation', () {
      const relation = OsmRelation(id: 3, members: [], tags: {});
      expect(
        () => editorOf().setTags(relation, const {'type': 'route'}),
        throwsArgumentError,
      );
    });

    test('sends a retagged node with its new tags', () {
      final edits = editorOf()..setTags(_node, const {'amenity': 'bench'});
      final xml = edits.history.upload.toXml(changeset: 1, createdBy: 'test');
      expect(xml, contains('<tag k="amenity" v="bench"/>'));
      expect(xml, isNot(contains('crossing')));
      expect(edits.history.upload.describe(), ['Change node/1']);
    });
  });

  group('ways and relations', () {
    const way = OsmWay(
      id: 9,
      nodeIds: [1, 2],
      tags: {'highway': 'residential'},
      info: OsmInfo(version: 4),
    );
    const route = OsmRelation(
      id: 30,
      members: [
        OsmMember(type: OsmElementType.node, ref: 1, role: 'stop'),
        OsmMember(type: OsmElementType.way, ref: 9, role: ''),
        OsmMember(type: OsmElementType.way, ref: 8, role: ''),
      ],
      tags: {'type': 'route'},
      info: OsmInfo(version: 7),
    );

    test('deletes a way', () {
      final edits = editorOf()..deleteWay(way);
      expect(edits.history.isGone(OsmElementType.way, 9), isTrue);
      expect(edits.history.deletedWays[9], way);
    });

    test('takes a deleted way out of the relations it was in', () {
      final edits = editorOf([route])..deleteWay(way);
      final now = edits.history.changedRelation(30)!;
      expect(now.members.map((m) => (m.type, m.ref)), [
        (OsmElementType.node, 1),
        (OsmElementType.way, 8),
      ]);
      expect(now.info?.version, 7);
    });

    test('undoes a way deletion, relations and all', () {
      final edits = editorOf([route])..deleteWay(way);
      edits.undo();
      expect(edits.history.isGone(OsmElementType.way, 9), isFalse);
      expect(edits.history.deletedWays, isEmpty);
      expect(edits.history.changedRelation(30), isNull);
    });

    test('says nothing about a way made and then deleted again', () {
      final edits = editorOf();
      final made = edits.createWay(nodeIds: [1, 2]);
      edits.deleteWay(made);
      expect(edits.history.deletedWays, isEmpty);
      expect(edits.history.changedWay(made.id), isNull);
      edits.undo();
      expect(edits.history.changedWay(made.id), isNotNull);
    });

    test('takes a deleted node out of the relations it was in', () {
      final edits = editorOf([way, route])..deleteNode(_node);
      expect(
        edits.history.changedRelation(30)!.members.map((m) => m.ref),
        [9, 8],
      );
      edits.undo();
      expect(edits.history.changedRelation(30), isNull);
      expect(edits.history.changedWay(9), isNull);
    });

    test('changes the members of a relation, and undoes it', () {
      final edits = editorOf()
        ..setRelationMembers(route, [route.members.first]);
      expect(edits.history.changedRelation(30)!.members, hasLength(1));
      edits.undo();
      expect(edits.history.changedRelation(30), isNull);
    });

    test('keeps changes to one relation from different deletions', () {
      final edits = editorOf([route])
        ..deleteWay(way)
        ..deleteNode(_node);
      expect(edits.history.changedRelation(30)!.members.map((m) => m.ref), [8]);
      edits.undo();
      expect(
          edits.history.changedRelation(30)!.members.map((m) => m.ref), [1, 8]);
    });

    test('uploads a relation before the way it no longer lists goes', () {
      final edits = editorOf([way, route])
        ..deleteNode(
          const OsmNode(
            id: 2,
            latitude: 0,
            longitude: 0,
            info: OsmInfo(version: 1),
          ),
        )
        // The way as the edits have it by now, without the node.
        ..deleteWay(way);
      final xml = edits.history.upload.toXml(changeset: 1, createdBy: 'test');
      final relation = xml.indexOf('<relation id="30" version="7"');
      final deletedWay = xml.indexOf('<way id="9"', xml.indexOf('<delete>'));
      final deletedNode = xml.indexOf('<node id="2"', xml.indexOf('<delete>'));
      expect(relation, greaterThan(0));
      expect(relation, lessThan(xml.indexOf('<delete>')));
      expect(deletedWay, lessThan(deletedNode));
      expect(xml, contains('<member type="way" ref="8" role=""/>'));
      expect(xml, isNot(contains('ref="9" role')));
      expect(edits.history.upload.describe(), [
        'Change relation/30',
        'Delete way/9',
        'Delete node/2',
      ]);
    });
  });

  group('keeping rings closed', () {
    const ring = OsmWay(id: 5, nodeIds: [1, 2, 3, 4, 1]);

    test('closes a ring again when the node it was drawn from goes', () {
      expect(ring.withoutNode(1), [2, 3, 4, 2]);
    });

    test('leaves a ring closed when any other node goes', () {
      expect(ring.withoutNode(3), [1, 2, 4, 1]);
    });

    test('leaves no repeat where a node went', () {
      const line = OsmWay(id: 6, nodeIds: [1, 2, 3, 2, 4]);
      expect(line.withoutNode(3), [1, 2, 4]);
    });

    test('keeps a building closed when a corner of it is deleted', () {
      final edits = editorOf([ring])
        ..deleteNode(
          const OsmNode(id: 1, latitude: 0, longitude: 0),
        );
      expect(edits.history.changedWay(5)!.isClosed, isTrue);
    });
  });

  group('deleting relations', () {
    const inner = OsmRelation(
      id: 40,
      members: [],
      info: OsmInfo(version: 2),
    );
    const outer = OsmRelation(
      id: 41,
      members: [
        OsmMember(type: OsmElementType.relation, ref: 40, role: 'part'),
      ],
      info: OsmInfo(version: 3),
    );

    test('deletes a relation and takes it out of those it was in', () {
      final edits = editorOf([outer])..deleteRelation(inner);
      expect(edits.history.isGone(OsmElementType.relation, 40), isTrue);
      expect(edits.history.changedRelation(41)!.members, isEmpty);
      final xml = edits.history.upload.toXml(changeset: 1, createdBy: 'test');
      expect(
        xml.indexOf('<relation id="41"'),
        lessThan(xml.indexOf('<relation id="40"')),
      );
    });

    test('undoes deleting a relation', () {
      final edits = editorOf([outer])..deleteRelation(inner);
      edits.undo();
      expect(edits.history.isGone(OsmElementType.relation, 40), isFalse);
      expect(edits.history.deletedRelations, isEmpty);
      expect(edits.history.changedRelation(41), isNull);
    });
  });

  test('undoes everything since a mark, and nothing before it', () {
    final edits = editorOf();
    final kept = edits.createNode(latitude: 0, longitude: 0);
    final mark = edits.history.length;
    edits.createNode(latitude: 1, longitude: 1);
    edits.createNode(latitude: 2, longitude: 2);
    edits.undoSince(mark);
    expect(edits.history.length, mark);
    expect(edits.history.changedNodes.keys, [kept.id]);
  });
}
