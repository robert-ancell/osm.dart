import 'dart:io';

import 'package:osm/osm.dart';
import 'package:osm/pbf.dart';
import 'package:osm/src/pbf/blob.dart';
import 'package:osm/xml.dart';
import 'package:test/test.dart';

late Directory _work;

/// The hand written elements, written back out in order so that changes can
/// be applied to them. See test/data/README.md.
Future<String> _base() async {
  final source = await OsmPbfFile.open('test/data/elements.osm.pbf');
  final path = '${_work.path}/base.osm.pbf';
  final writer = await OsmPbfWriter.create(
    path,
    header: const OsmPbfHeader(
      optionalFeatures: ['Sort.Type_then_ID'],
      replicationBaseUrl: 'https://example.invalid/updates',
      replicationSequenceNumber: 41,
    ),
  );
  await writer.addAll(source.elements());
  await writer.close();
  return path;
}

Future<List<OsmElement>> _elementsOf(String path) =>
    OsmPbfFile.open(path).then((file) => file.elements().toList());

void main() {
  setUpAll(() => _work = Directory.systemTemp.createTempSync('osm_apply'));
  tearDownAll(() => _work.deleteSync(recursive: true));

  test('creates, replaces and removes what the changes say', () async {
    final output = '${_work.path}/applied.osm.pbf';
    final counts = await OsmPbfTransformer(
            await OsmChangeFile.read('test/data/changes.osc'))
        .transform(
      input: await _base(),
      output: output,
    );

    expect(counts.created, 2, reason: 'a new node and a new way');
    expect(counts.modified, 2, reason: 'a node and a relation the file had');
    expect(counts.deleted, 2);
    expect(counts.missed, 0);

    final after = await _elementsOf(output);
    final ids = after.map((e) => '${e.type.name}/${e.id}').toList();
    // Node 42000003 and way 42000802 are gone; 6, 803 and the site relation
    // are new or replaced.
    expect(ids, isNot(contains('node/42000003')));
    expect(ids, isNot(contains('way/42000802')));
    expect(ids, contains('node/42000006'));
    expect(ids, contains('way/42000803'));

    final cafe = after.firstWhere((e) => e.id == 42000001) as OsmNode;
    expect(cafe.tags['name'], 'Café Two');
    expect(cafe.info?.version, 4);
    expect(cafe.latitude, closeTo(0.50011, 1e-9));
  });

  test('writes the elements in order, whatever order they arrived in',
      () async {
    final output = '${_work.path}/ordered.osm.pbf';
    await OsmPbfTransformer(await OsmChangeFile.read('test/data/changes.osc'))
        .transform(
      input: await _base(),
      output: output,
    );

    final after = await _elementsOf(output);
    expect((await OsmPbfFile.open(output)).header.isSorted, isTrue);
    for (var i = 1; i < after.length; i++) {
      final before = after[i - 1], now = after[i];
      expect(
        before.type.index < now.type.index ||
            (before.type == now.type && before.id < now.id),
        isTrue,
        reason: '${before.type.name}/${before.id} before '
            '${now.type.name}/${now.id}',
      );
    }
  });

  test('ignores a change no newer than what the file holds', () async {
    // Node 42000001 is at version 3 in the file. Overlapping diffs can hand
    // back an older version, or the same one, and neither may win.
    final output = '${_work.path}/stale.osm.pbf';
    final counts = await OsmPbfTransformer(const [
      OsmChange(
        action: OsmChangeAction.modify,
        type: OsmElementType.node,
        id: 42000001,
        version: 2,
        element: OsmNode(
          id: 42000001,
          latitude: 9,
          longitude: 9,
          info: OsmInfo(version: 2),
        ),
      ),
      // Node 42000004 is at version 2, and a delete of version 1 is
      // older than it.
      OsmChange(
        action: OsmChangeAction.delete,
        type: OsmElementType.node,
        id: 42000004,
        version: 1,
      ),
    ]).transform(
      input: await _base(),
      output: output,
    );
    expect(counts.stale, 2);
    expect(counts.modified, 0);
    expect(counts.deleted, 0);

    final after = await _elementsOf(output);
    final node = after.firstWhere((e) => e.id == 42000001) as OsmNode;
    expect(node.latitude, closeTo(0.5001, 1e-9));
    expect(after.any((e) => e.id == 42000004), isTrue);
  });

  test('deletes what a delete of the same version names', () async {
    // An extract's own diffs are made by comparing one day's extract with
    // the next, and say a delete with the version of what went. Read as
    // no newer than the file, deleted elements stayed in a country's
    // extract for good.
    final output = '${_work.path}/deleted.osm.pbf';
    final counts = await OsmPbfTransformer(const [
      OsmChange(
        action: OsmChangeAction.delete,
        type: OsmElementType.node,
        id: 42000003,
        version: 11,
      ),
      OsmChange(
        action: OsmChangeAction.delete,
        type: OsmElementType.way,
        id: 42000801,
        version: 7,
      ),
    ]).transform(
      input: await _base(),
      output: output,
    );
    expect(counts.deleted, 2);
    expect(counts.stale, 0);

    final ids = (await _elementsOf(output)).map((e) => e.id);
    expect(ids, isNot(contains(42000003)));
    expect(ids, isNot(contains(42000801)));
  });

  group('a file of many blocks', () {
    // Three blocks of nodes, 8000 to a block, and one of ways.
    late String input;
    setUpAll(() async {
      input = '${_work.path}/blocks.osm.pbf';
      final writer = await OsmPbfWriter.create(
        input,
        header: const OsmPbfHeader(optionalFeatures: ['Sort.Type_then_ID']),
      );
      for (var id = 1; id <= 20000; id++) {
        writer.add(OsmNode(
          id: id * 2,
          latitude: id / 1e5,
          longitude: 0,
          info: const OsmInfo(version: 1),
        ));
      }
      writer.add(const OsmWay(
        id: 1,
        nodeIds: [2, 4],
        info: OsmInfo(version: 1),
      ));
      await writer.close();
    });

    Future<List<List<int>>> blocksOf(String path) async {
      final file = await File(path).open();
      try {
        final blobs = BlobReader(file);
        return [
          for (var blob = await blobs.next();
              blob != null;
              blob = await blobs.next())
            if (blob.type == 'OSMData') blob.body,
        ];
      } finally {
        await file.close();
      }
    }

    test('copies the blocks no change falls in as they are', () async {
      final output = '${_work.path}/blocks-applied.osm.pbf';
      final counts = await OsmPbfTransformer(const [
        // In the second block.
        OsmChange(
          action: OsmChangeAction.modify,
          type: OsmElementType.node,
          id: 20000,
          version: 2,
          element: OsmNode(
            id: 20000,
            latitude: 1,
            longitude: 1,
            info: OsmInfo(version: 2),
          ),
        ),
        // Between two ids of the second block, which the file does not
        // hold.
        OsmChange(
          action: OsmChangeAction.create,
          type: OsmElementType.node,
          id: 20001,
          version: 1,
          element: OsmNode(id: 20001, latitude: 2, longitude: 2),
        ),
        // Past everything, and before the ways.
        OsmChange(
          action: OsmChangeAction.create,
          type: OsmElementType.node,
          id: 90000,
          version: 1,
          element: OsmNode(id: 90000, latitude: 3, longitude: 3),
        ),
      ]).transform(
        input: input,
        output: output,
      );
      expect(counts.modified, 1);
      expect(counts.created, 2);
      expect(counts.unchanged, 20000);

      final before = await blocksOf(input);
      final after = await blocksOf(output);
      // The second block gains a node, and the writer puts the one it has
      // no room for in a block of its own; the node past the end has one
      // of its own too.
      expect(after, hasLength(before.length + 2));
      expect(after, anyElement(equals(before[0])),
          reason: 'the first block, copied');
      expect(after, isNot(anyElement(equals(before[1]))),
          reason: 'the second, written again');
      expect(after, anyElement(equals(before[2])), reason: 'the third, copied');
      expect(after.last, before.last, reason: 'the ways, copied');

      final elements = await _elementsOf(output);
      expect(elements.length, 20003);
      final nodes = elements.whereType<OsmNode>().toList();
      expect(
          nodes.map((n) => n.id).toList(), [...nodes.map((n) => n.id)]..sort(),
          reason: 'still in order');
      expect(nodes.firstWhere((n) => n.id == 20000).latitude, 1);
      expect(nodes.any((n) => n.id == 20001), isTrue);
      expect(nodes.last.id, 90000);
      expect(elements.last, isA<OsmWay>());
    });

    test('and a delete in a block is the only thing that changes', () async {
      final output = '${_work.path}/blocks-deleted.osm.pbf';
      await OsmPbfTransformer(const [
        OsmChange(
          action: OsmChangeAction.delete,
          type: OsmElementType.node,
          id: 40000,
          version: 1,
        ),
      ]).transform(
        input: input,
        output: output,
      );
      final ids = (await _elementsOf(output)).map((e) => e.id).toSet();
      expect(ids.contains(40000), isFalse);
      expect(ids.length, 20000);
    });
  });

  test('takes the newest of several changes to one element', () async {
    OsmChange version(int number) => OsmChange(
          action: OsmChangeAction.modify,
          type: OsmElementType.node,
          id: 42000001,
          version: number,
          element: OsmNode(
            id: 42000001,
            latitude: number.toDouble(),
            longitude: 0,
            info: OsmInfo(version: number),
          ),
        );
    final output = '${_work.path}/newest.osm.pbf';
    // An hour diff and then the minute diffs overlapping it.
    await OsmPbfTransformer([version(6), version(4), version(5)]).transform(
      input: await _base(),
      output: output,
    );
    final node = (await _elementsOf(output)).firstWhere((e) => e.id == 42000001)
        as OsmNode;
    expect(node.info?.version, 6);
  });

  test('counts a change for something the file never had', () async {
    final output = '${_work.path}/missed.osm.pbf';
    final counts = await OsmPbfTransformer(const [
      OsmChange(
        action: OsmChangeAction.delete,
        type: OsmElementType.node,
        id: 999999,
      ),
    ]).transform(
      input: await _base(),
      output: output,
    );
    expect(counts.missed, 1);
    expect(counts.deleted, 0);
    expect(await _elementsOf(output), hasLength(9));
  });

  test('carries the replication state the caller gives it', () async {
    final input = await _base();
    final was = (await OsmPbfFile.open(input)).header;
    final output = '${_work.path}/moved.osm.pbf';

    await OsmPbfTransformer(await OsmChangeFile.read('test/data/changes.osc'))
        .transform(
      input: input,
      output: output,
      header: was.copyWith(
        replicationSequenceNumber: 42,
        replicationTimestamp: DateTime.utc(2026, 3, 4, 5, 6, 7),
        writingProgram: 'a test',
      ),
    );

    final now = (await OsmPbfFile.open(output)).header;
    expect(now.replicationSequenceNumber, 42);
    expect(now.replicationBaseUrl, 'https://example.invalid/updates');
    expect(now.replicationTimestamp, DateTime.utc(2026, 3, 4, 5, 6, 7));
    expect(now.writingProgram, 'a test');
  });

  test('refuses a file that does not say its elements are in order', () async {
    await expectLater(
      OsmPbfTransformer(const []).transform(
        input: 'test/data/elements.osm.pbf',
        output: '${_work.path}/never.osm.pbf',
      ),
      throwsA(isA<OsmPbfException>()),
    );
  });

  test('applies the same changes to each file it is given', () async {
    final transformer =
        OsmPbfTransformer(await OsmChangeFile.read('test/data/changes.osc'));
    final input = await _base();
    final first = await transformer.transform(
      input: input,
      output: '${_work.path}/first.osm.pbf',
    );
    final second = await transformer.transform(
      input: input,
      output: '${_work.path}/second.osm.pbf',
    );
    expect(second.toString(), first.toString());
    expect(first.created + first.modified + first.deleted, greaterThan(0));
  });
}
