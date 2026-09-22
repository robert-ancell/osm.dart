import 'dart:io';

import 'package:osm/osm.dart';
import 'package:test/test.dart';

late Directory _work;

const _a = OsmTile(16, 60000, 40000);
const _b = OsmTile(16, 60001, 40000);

/// A box's worth of elements, [nodes] of them, with ids of their own.
List<OsmElement> _tile(int from, {int nodes = 4}) => [
      for (var i = 0; i < nodes; i++)
        OsmNode(
          id: from + i,
          latitude: -36.85 + i / 100000,
          longitude: 174.76 + i / 100000,
          tags: const {'amenity': 'bench'},
          info: const OsmInfo(version: 1),
        ),
      OsmWay(
        id: from + 1000,
        nodeIds: [for (var i = 0; i < nodes; i++) from + i],
        tags: const {'highway': 'residential'},
        info: const OsmInfo(version: 1),
      ),
    ];

void main() {
  setUp(() async {
    _work = await Directory.systemTemp.createTemp('kupe_cache_test');
  });

  tearDown(() async {
    if (_work.existsSync()) await _work.delete(recursive: true);
  });

  test('holds nothing to begin with', () async {
    final cache = await OsmTileCache.open(_work);
    expect(cache.tiles, isEmpty);
    expect(cache.bytes, 0);
    expect(cache.holds(_a), isFalse);
    expect(await cache.read(_a), isNull);
  });

  test('gives back what it was given', () async {
    final cache = await OsmTileCache.open(_work);
    await cache.write(_a, _tile(1));
    expect(cache.holds(_a), isTrue);

    final read = (await cache.read(_a))!;
    expect(read.whereType<OsmNode>().length, 4);
    expect(read.whereType<OsmWay>().single.nodeIds.length, 4);
    expect(read.whereType<OsmWay>().single.tags['highway'], 'residential');
  });

  test('writes a box smaller than the XML it arrived as', () async {
    final cache = await OsmTileCache.open(_work);
    await cache.write(_a, _tile(1, nodes: 200));
    // Nothing exact, just that it is stored packed rather than as text.
    expect(cache.bytes, lessThan(200 * 60));
  });

  test('is still there after opening again', () async {
    final first = await OsmTileCache.open(_work);
    await first.write(_a, _tile(1));
    final bytes = first.bytes;

    final second = await OsmTileCache.open(_work);
    expect(second.holds(_a), isTrue);
    expect(second.bytes, bytes);
    expect((await second.read(_a))!.length, 5);
  });

  test('replaces a box that is written again', () async {
    final cache = await OsmTileCache.open(_work);
    await cache.write(_a, _tile(1, nodes: 8));
    await cache.write(_a, _tile(1, nodes: 2));
    expect(cache.tiles.length, 1);
    expect((await cache.read(_a))!.whereType<OsmNode>().length, 2);
  });

  test('forgets a box on request', () async {
    final cache = await OsmTileCache.open(_work);
    await cache.write(_a, _tile(1));
    await cache.forget(_a);
    expect(cache.holds(_a), isFalse);
    expect(cache.bytes, 0);
    expect(await cache.read(_a), isNull);
  });

  test('throws away the oldest when it runs out of room', () async {
    final cache = await OsmTileCache.open(_work, maximumBytes: 1);
    await cache.write(_a, _tile(1));
    await cache.write(_b, _tile(2000));
    // Both are over the limit on their own, so only the newest survives.
    expect(cache.holds(_a), isFalse);
    expect(cache.holds(_b), isTrue);
    expect(cache.tiles.length, 1);
  });

  test('stays inside its limit', () async {
    final cache = await OsmTileCache.open(_work, maximumBytes: 4000);
    for (var i = 0; i < 20; i++) {
      await cache.write(OsmTile(16, 60000 + i, 40000), _tile(i * 100));
    }
    expect(cache.bytes, lessThanOrEqualTo(4000));
    expect(cache.tiles, isNotEmpty);
  });

  test('keeps a box new enough to trust', () async {
    final cache = await OsmTileCache.open(_work);
    await cache.write(_a, _tile(1));
    expect(cache.entry(_a)!.isStale, isFalse);
  });

  test('reads a box again when its file has gone', () async {
    final first = await OsmTileCache.open(_work);
    await first.write(_a, _tile(1));
    // Something else cleared the directory out from under it.
    for (final entry in _work.listSync()) {
      if (entry is Directory) entry.deleteSync(recursive: true);
    }
    final second = await OsmTileCache.open(_work);
    expect(second.holds(_a), isFalse);
  });

  test('starts again rather than trusting an index it cannot read', () async {
    final first = await OsmTileCache.open(_work);
    await first.write(_a, _tile(1));
    File('${_work.path}/index.json').writeAsStringSync('not json at all');
    final second = await OsmTileCache.open(_work);
    expect(second.tiles, isEmpty);
  });

  test('ignores an index written by something else', () async {
    final first = await OsmTileCache.open(_work);
    await first.write(_a, _tile(1));
    File('${_work.path}/index.json').writeAsStringSync('{"version": 999}');
    final second = await OsmTileCache.open(_work);
    expect(second.tiles, isEmpty);
  });
}
