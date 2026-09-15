import 'dart:io';

import 'package:osm/osm.dart';
import 'package:test/test.dart';

late Directory _work;

String _path(String name) => '${_work.path}/$name';

String _describe(OsmElement element) {
  final tags = (element.tags.keys.toList()..sort())
      .map((key) => '$key=${element.tags[key]}')
      .join(',');
  final info = element.info;
  final meta = '${info?.version}/${info?.changeset}/${info?.uid}/${info?.user}/'
      '${info?.timestamp?.toIso8601String()}';
  final extra = switch (element) {
    OsmNode(:final latitude, :final longitude) =>
      '${latitude.toStringAsFixed(7)},${longitude.toStringAsFixed(7)}',
    OsmWay(:final nodeIds) => nodeIds.join('+'),
    OsmRelation(:final members) =>
      members.map((m) => '${m.type.name}:${m.ref}:${m.role}').join('+'),
  };
  return '${element.type.name}/${element.id}|$tags|$meta|$extra';
}

Future<List<OsmElement>> _writeAndRead(
  String name,
  List<OsmElement> elements, {
  OsmPbfHeader header = const OsmPbfHeader(),
}) async {
  final writer = await OsmPbfWriter.create(_path(name), header: header);
  for (final element in elements) {
    writer.add(element);
  }
  await writer.close();
  return (await OsmPbfFile.open(_path(name))).elements().toList();
}

void main() {
  setUpAll(() => _work = Directory.systemTemp.createTempSync('osm_writer'));
  tearDownAll(() => _work.deleteSync(recursive: true));

  test('writes back every element of a file, unchanged', () async {
    final source = await OsmPbfFile.open('test/data/grid.osm.pbf');
    final before = await source.elements().toList();

    final writer = await OsmPbfWriter.create(
      _path('grid.osm.pbf'),
      header: source.header,
    );
    await writer.addAll(source.elements());
    await writer.close();

    final after = await (await OsmPbfFile.open(
      _path('grid.osm.pbf'),
    ))
        .elements()
        .toList();
    expect(after.map(_describe).toList(), before.map(_describe).toList());
  });

  test('writes back what the header said', () async {
    const header = OsmPbfHeader(
      bounds: OsmBounds(
        minLatitude: -41.5,
        minLongitude: 174.5,
        maxLatitude: -41.0,
        maxLongitude: 175.0,
      ),
      optionalFeatures: ['Sort.Type_then_ID'],
      writingProgram: 'a test',
      source: 'nowhere',
      replicationBaseUrl: 'https://example.invalid/updates',
      replicationSequenceNumber: 4905,
    );
    final path = _path('header.osm.pbf');
    await (await OsmPbfWriter.create(path, header: header)).close();

    final written = (await OsmPbfFile.open(path)).header;
    expect(written.writingProgram, 'a test');
    expect(written.source, 'nowhere');
    expect(written.replicationBaseUrl, 'https://example.invalid/updates');
    expect(written.replicationSequenceNumber, 4905);
    expect(written.isSorted, isTrue);
    expect(written.requiredFeatures, contains('DenseNodes'));
    expect(written.bounds?.minLatitude, closeTo(-41.5, 1e-9));
    expect(written.bounds?.maxLongitude, closeTo(175.0, 1e-9));
  });

  test('a file with nothing in it is still a file', () async {
    expect(await _writeAndRead('empty.osm.pbf', const []), isEmpty);
  });

  test('keeps elements with no metadata on them', () async {
    final read = await _writeAndRead('bare.osm.pbf', const [
      OsmNode(id: 1, latitude: -41.1, longitude: 174.1),
      OsmNode(id: 2, latitude: -41.2, longitude: 174.2, tags: {'a': 'b'}),
      OsmWay(id: 3, nodeIds: [1, 2]),
    ]);
    expect(read.map(_describe), [
      'node/1||null/null/null/null/null|-41.1000000,174.1000000',
      'node/2|a=b|null/null/null/null/null|-41.2000000,174.2000000',
      'way/3||null/null/null/null/null|1+2',
    ]);
  });

  test('keeps a tag value that needs more than ASCII', () async {
    final read = await _writeAndRead('utf8.osm.pbf', const [
      OsmNode(
        id: 1,
        latitude: 0,
        longitude: 0,
        tags: {'name': 'Café → 土手', 'name:mi': 'Te Whanganui-a-Tara'},
      ),
    ]);
    expect(read.single.tags['name'], 'Café → 土手');
    expect(read.single.tags['name:mi'], 'Te Whanganui-a-Tara');
  });

  test('writes more elements than fit in one block', () async {
    final many = [
      for (var id = 1; id <= 20000; id++)
        OsmNode(
          id: id,
          latitude: -41 + id / 1000000,
          longitude: 174 + id / 1000000,
        ),
    ];
    final read = await _writeAndRead('many.osm.pbf', many);
    expect(read, hasLength(20000));
    expect(read.first.id, 1);
    expect(read.last.id, 20000);
    expect((read.last as OsmNode).latitude, closeTo(-41 + 0.02, 1e-7));
  });

  test('refuses to write a file that would lie about being sorted', () async {
    final writer = await OsmPbfWriter.create(
      _path('unsorted.osm.pbf'),
      header: const OsmPbfHeader(optionalFeatures: ['Sort.Type_then_ID']),
    );
    writer
      ..add(const OsmNode(id: 5, latitude: 0, longitude: 0))
      ..add(const OsmWay(id: 1, nodeIds: [5]));
    expect(
      () => writer.add(const OsmNode(id: 6, latitude: 0, longitude: 0)),
      throwsA(isA<OsmPbfException>()),
    );
    await writer.close();
  });

  test('takes any order when the header does not claim one', () async {
    final read = await _writeAndRead('anyorder.osm.pbf', const [
      OsmNode(id: 9, latitude: 0, longitude: 0),
      OsmNode(id: 2, latitude: 1, longitude: 1),
    ]);
    expect(read.map((e) => e.id), [9, 2]);
  });
}
