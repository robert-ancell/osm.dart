import 'dart:io';

import 'package:osm/osm.dart';
import 'package:test/test.dart';

/// Enough elements to fill more blocks than one worker is given at a time.
///
/// A block holds eight thousand elements and a worker takes sixty-four
/// blocks, so this is two batches and a bit: the smallest file that hands a
/// second batch over while the first is still in flight, which is the only
/// arrangement that catches what a batch closure drags along with it.
const int _elements = 64 * 8000 + 1;

void main() {
  late Directory work;
  late String path;

  setUpAll(() async {
    work = Directory.systemTemp.createTempSync('osm_decode_ahead');
    path = '${work.path}/many_blocks.osm.pbf';
    final writer = await OsmPbfWriter.create(
      path,
      header: const OsmPbfHeader(optionalFeatures: ['Sort.Type_then_ID']),
    );
    for (var i = 1; i <= _elements; i++) {
      writer.add(OsmNode(
        id: i,
        latitude: -41 + i / 1000000,
        longitude: 174 + i / 1000000,
        tags: i % 1000 == 0 ? const {'amenity': 'bench'} : const {},
      ));
    }
    await writer.close();
  });

  tearDownAll(() => work.deleteSync(recursive: true));

  test('a file of more blocks than a batch reads on workers', () async {
    // The batch handed to a worker used to be a closure written inside the
    // read, which carried that scope with it — the queue of batches already
    // in flight included. A `Future` cannot cross to another isolate, so the
    // second batch of any read with one still pending failed to send. Every
    // fixture here was small enough to dispatch once and never see it.
    final file = await OsmPbfFile.open(path);
    final found = await file
        .elements(filter: const OsmFilter.tag('amenity', 'bench'), isolates: 4)
        .toList();

    expect(found, hasLength(_elements ~/ 1000));
    expect(found.first.id, 1000);
  });

  test('and gives them back in file order', () async {
    // Batches go out in file order and come back in it, whichever worker
    // finished first.
    final file = await OsmPbfFile.open(path);
    final ids = await file
        .elements(filter: const OsmFilter.tag('amenity', 'bench'), isolates: 4)
        .map((element) => element.id)
        .toList();

    expect(ids, [for (var i = 1000; i <= _elements; i += 1000) i]);
  });

  test('and a read naming many ids agrees with one decoded here', () async {
    // The reads that name ids are the ones batching was for: the ids cross
    // to every worker, and before they went in batches a read naming this
    // many was sent to the calling isolate instead.
    final file = await OsmPbfFile.open(path);
    final wanted = {for (var i = 1; i <= _elements; i += 7) i};
    final filter = OsmFilter.ids(OsmElementType.node, wanted);

    final onWorkers = await file.elements(filter: filter, isolates: 4).toList();
    final here = await file.elements(filter: filter, isolates: 1).toList();

    expect(onWorkers.map((e) => e.id).toList(), here.map((e) => e.id).toList());
    expect(onWorkers, hasLength(wanted.length));
  });
}
