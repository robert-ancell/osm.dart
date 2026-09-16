import 'dart:io';

import 'package:osm/osm.dart';
import 'package:test/test.dart';

/// Written for this package, and the same file gzipped the way replication
/// serves them. See test/data/README.md.
const _path = 'test/data/changes.osc';
const _gzippedPath = 'test/data/changes-gzipped.osc.gz';

/// What a change says, for comparing two readings of the same file.
String _describe(OsmChange change) {
  final element = change.element;
  final tags = element == null
      ? ''
      : (element.tags.keys.toList()..sort())
          .map((key) => '$key=${element.tags[key]}')
          .join(',');
  final extra = switch (element) {
    OsmNode(:final latitude, :final longitude) => '$latitude,$longitude',
    OsmWay(:final nodeIds) => nodeIds.join('+'),
    OsmRelation(:final members) =>
      members.map((m) => '${m.type.name}${m.ref}${m.role}').join('+'),
    null => '',
  };
  return '${change.action.name} ${change.type.name}/${change.id} '
      'v${change.version} $tags $extra';
}

void main() {
  test('reads every change, in the order the file gives them', () async {
    final changes = await OsmChangeFile.read(_path);
    expect(
      changes.map((c) => '${c.action.name} ${c.type.name}/${c.id}').toList(),
      [
        'create node/42000006',
        'create way/42000803',
        'modify node/42000001',
        'modify relation/42000902',
        'delete node/42000003',
        'delete way/42000802',
      ],
    );
  });

  test('reads a gzipped file the same way', () async {
    final plain = await OsmChangeFile.read(_path);
    final gzipped = await OsmChangeFile.read(_gzippedPath);
    expect(gzipped.map((c) => '${c.type.name}/${c.id}/${c.version}'),
        plain.map((c) => '${c.type.name}/${c.id}/${c.version}'));
  });

  test('builds the element a change makes', () async {
    final changes = await OsmChangeFile.read(_path);
    final node = changes.first.element! as OsmNode;

    expect(node.id, 42000006);
    expect(node.latitude, closeTo(0.5004, 1e-9));
    expect(node.longitude, closeTo(0.5004, 1e-9));
    expect(node.tags['amenity'], 'bench');
    expect(node.info?.version, 1);
    expect(node.info?.changeset, 900010);
    expect(node.info?.uid, 20);
    expect(node.info?.user, 'Fourth Mapper');
    expect(node.info?.timestamp, DateTime.utc(2020, 11, 12, 13, 14, 15));
  });

  test('puts back the entities a tag value was written with', () async {
    final changes = await OsmChangeFile.read(_path);
    expect(changes.first.element!.tags['name'], 'Bench & Table — 土');
    final modified = changes.firstWhere((c) => c.id == 42000001);
    expect(modified.element!.tags['name'], 'Café Two');
  });

  test('reads the nodes of a way and the members of a relation', () async {
    final changes = await OsmChangeFile.read(_path);
    final way = changes[1].element! as OsmWay;
    expect(way.nodeIds, [42000005, 42000006]);

    final relation = changes[3].element! as OsmRelation;
    expect(relation.members, hasLength(2));
    expect(relation.members.first.type, OsmElementType.node);
    expect(relation.members.first.role, 'stop');
    expect(relation.members.last.role, isEmpty);
  });

  test('a deletion still says what to delete', () async {
    final changes = await OsmChangeFile.read(_path);
    final deleted = changes
        .where(
          (c) => c.action == OsmChangeAction.delete,
        )
        .toList();

    expect(deleted.map((c) => c.id), [42000003, 42000802]);
    expect(deleted.first.version, 12);
    // This file gives a location for the deleted node, so there is an
    // element; a way with no nodes left in it still has one.
    expect(deleted.first.element, isA<OsmNode>());
    expect((deleted.last.element! as OsmWay).nodeIds, isEmpty);
  });

  test('gives no element for a deleted node with no location', () {
    final changes = OsmChangeFile.parse('''
<osmChange version="0.6">
  <delete><node id="7" version="3"/></delete>
</osmChange>''');
    expect(changes.single.element, isNull);
    expect(changes.single.type, OsmElementType.node);
    expect(changes.single.id, 7);
    expect(changes.single.version, 3);
  });

  test('reads the same whichever way the file is cut into pieces', () async {
    final xml = File(_path).readAsStringSync();
    final whole = OsmChangeFile.parse(xml).map(_describe).toList();

    // Every place one cut could go, which puts a cut inside every tag,
    // attribute, entity and comment in the file.
    for (var cut = 0; cut <= xml.length; cut++) {
      final pieces = [xml.substring(0, cut), xml.substring(cut)];
      final read = await OsmChangeFile.parseStream(
        Stream.fromIterable(pieces),
      ).map(_describe).toList();
      expect(read, whole, reason: 'cut at $cut');
    }

    // And a character at a time.
    final read = await OsmChangeFile.parseStream(
      Stream.fromIterable(xml.split('')),
    ).map(_describe).toList();
    expect(read, whole);
  });

  test('streams a gzipped file the same as it reads it', () async {
    final whole = (await OsmChangeFile.read(_path)).map(_describe).toList();
    final streamed = await OsmChangeFile.stream(
      _gzippedPath,
    ).map(_describe).toList();
    expect(streamed, whole);
  });

  test('reads a document whose last tag is short', () {
    expect(
      OsmChangeFile.parse(
        '<osmChange><delete><node id="1" version="2"/></delete><a>',
      ),
      hasLength(1),
    );
  });

  test('reads a file with no changes in it', () {
    expect(OsmChangeFile.parse('<osmChange version="0.6"/>'), isEmpty);
  });

  test('rejects an entity it cannot put back', () {
    expect(
      () => OsmChangeFile.parse(
        '<osmChange><create><node id="1" lat="0" lon="0">'
        '<tag k="name" v="a &raquo; b"/></node></create></osmChange>',
      ),
      throwsA(isA<OsmXmlException>()),
    );
  });

  test('rejects a tag that never ends', () {
    expect(
      () => OsmChangeFile.parse('<osmChange><create><node id="1"'),
      throwsA(isA<OsmXmlException>()),
    );
  });
}
