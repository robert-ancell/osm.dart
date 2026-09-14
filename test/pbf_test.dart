import 'dart:io';
import 'dart:typed_data';

import 'package:osm/osm.dart';
import 'package:test/test.dart';

/// Written for this package. See test/data/README.md.
const _path = 'test/data/elements.osm.pbf';

/// The osm-testdata grid, which is larger and has dense nodes in it.
const _gridPath = 'test/data/grid.osm.pbf';

void main() {
  test('reads the header', () async {
    final file = await OsmPbfFile.open(_path);
    expect(file.header.requiredFeatures, contains('OsmSchema-V0.6'));
    expect(file.header.requiredFeatures, contains('DenseNodes'));
    expect(file.header.writingProgram, startsWith('osmium'));
    expect(file.header.hasHistory, isFalse);
  });

  test('reads every element of the file', () async {
    final file = await OsmPbfFile.open(_gridPath);
    final counts = <OsmElementType, int>{};
    await for (final element in file.elements()) {
      counts[element.type] = (counts[element.type] ?? 0) + 1;
    }
    expect(counts, {
      OsmElementType.node: 968,
      OsmElementType.way: 261,
      OsmElementType.relation: 97,
    });
  });

  test('reads a node, its tags and its history', () async {
    final file = await OsmPbfFile.open(_path);
    final node =
        await file.elements().firstWhere((e) => e.id == 42000001) as OsmNode;

    expect(node.latitude, closeTo(0.5001, 1e-7));
    expect(node.longitude, closeTo(0.5001, 1e-7));
    expect(node.tags, {
      'amenity': 'cafe',
      'name': 'Café → 土手',
      'wheelchair': 'yes',
    });
    expect(node.info?.version, 3);
    expect(node.info?.changeset, 900001);
    expect(node.info?.uid, 17);
    expect(node.info?.user, 'Mapper');
    expect(node.info?.timestamp, DateTime.utc(2011, 2, 3, 4, 5, 6));
    expect(node.info?.visible, isTrue);
  });

  test('gives no user for an edit made without one', () async {
    final file = await OsmPbfFile.open(_path);
    final node =
        await file.elements().firstWhere((e) => e.id == 42000002) as OsmNode;
    expect(node.info?.user, isNull);
    expect(node.tags, isEmpty);
  });

  test('reads the nodes of a way', () async {
    final file = await OsmPbfFile.open(_path);
    final way =
        await file.elements().firstWhere((e) => e.id == 42000801) as OsmWay;

    expect(way.tags['name'], 'Te Whare');
    expect(way.nodeIds, [42000001, 42000002, 42000003, 42000004, 42000001]);
    expect(way.isClosed, isTrue);
    expect(way.info?.version, 7);
  });

  test('reads the members of a relation', () async {
    final file = await OsmPbfFile.open(_path);
    final relation = await file.elements().firstWhere(
          (e) => e.id == 42000902,
        ) as OsmRelation;

    expect(relation.tags['type'], 'site');
    expect(relation.members, hasLength(3));
    expect(relation.members[0].type, OsmElementType.node);
    expect(relation.members[0].ref, 42000005);
    expect(relation.members[0].role, 'stop');
    expect(relation.members[1].type, OsmElementType.way);
    expect(relation.members[1].role, isEmpty);
    expect(relation.members[2].type, OsmElementType.relation);
    expect(relation.members[2].ref, 42000901);
    expect(relation.members[2].role, 'site');
  });

  test('reads the file again on each listen', () async {
    final file = await OsmPbfFile.open(_gridPath);
    expect(await file.elements().length, await file.elements().length);
  });

  test('rejects a file that is not a PBF file', () async {
    final path = '${Directory.systemTemp.createTempSync().path}/not.osm.pbf';
    File(path).writeAsBytesSync(Uint8List.fromList(List.filled(64, 0x42)));
    await expectLater(OsmPbfFile.open(path), throwsA(isA<OsmPbfException>()));
  });

  test('rejects an empty file', () async {
    final path = '${Directory.systemTemp.createTempSync().path}/empty.osm.pbf';
    File(path).writeAsBytesSync(Uint8List(0));
    await expectLater(OsmPbfFile.open(path), throwsA(isA<OsmPbfException>()));
  });
}
