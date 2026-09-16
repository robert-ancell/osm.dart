import 'dart:io';

import 'package:osm/osm.dart';
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
    final counts = await applyOsmChanges(
      input: await _base(),
      changes: await OsmChangeFile.read('test/data/changes.osc'),
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
    await applyOsmChanges(
      input: await _base(),
      changes: await OsmChangeFile.read('test/data/changes.osc'),
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
    final counts = await applyOsmChanges(
      input: await _base(),
      changes: const [
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
        OsmChange(
          action: OsmChangeAction.delete,
          type: OsmElementType.node,
          id: 42000002,
          version: 1,
        ),
      ],
      output: output,
    );
    expect(counts.stale, 2);
    expect(counts.modified, 0);
    expect(counts.deleted, 0);

    final after = await _elementsOf(output);
    final node = after.firstWhere((e) => e.id == 42000001) as OsmNode;
    expect(node.latitude, closeTo(0.5001, 1e-9));
    expect(after.any((e) => e.id == 42000002), isTrue);
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
    await applyOsmChanges(
      input: await _base(),
      // An hour diff and then the minute diffs overlapping it.
      changes: [version(6), version(4), version(5)],
      output: output,
    );
    final node = (await _elementsOf(output)).firstWhere((e) => e.id == 42000001)
        as OsmNode;
    expect(node.info?.version, 6);
  });

  test('counts a change for something the file never had', () async {
    final output = '${_work.path}/missed.osm.pbf';
    final counts = await applyOsmChanges(
      input: await _base(),
      changes: const [
        OsmChange(
          action: OsmChangeAction.delete,
          type: OsmElementType.node,
          id: 999999,
        ),
      ],
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

    await applyOsmChanges(
      input: input,
      changes: await OsmChangeFile.read('test/data/changes.osc'),
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
      applyOsmChanges(
        input: 'test/data/elements.osm.pbf',
        changes: const [],
        output: '${_work.path}/never.osm.pbf',
      ),
      throwsA(isA<OsmPbfException>()),
    );
  });
}
