import 'dart:io';
import 'dart:typed_data';

import 'package:osm/osm.dart';
import 'package:test/test.dart';

late Directory _work;

const _a = OsmTile(17, 129167, 79983);
const _b = OsmTile(17, 129168, 79983);

Uint8List _bytes(int size) => Uint8List.fromList(List.filled(size, 0x42));

/// Rewrites the index so everything in it looks as old as [age].
Future<OsmImageryCache> _aged(Duration age) async {
  final index = File('${_work.path}/index.json');
  final text = await index.readAsString();
  final long = DateTime.now().subtract(age).millisecondsSinceEpoch;
  await index.writeAsString(text.replaceAll(RegExp(r'"at":\d+'), '"at":$long'));
  return OsmImageryCache.open(directory: _work);
}

void main() {
  setUp(() async {
    _work = await Directory.systemTemp.createTemp('osm_imagery_cache');
  });

  tearDown(() async {
    if (_work.existsSync()) await _work.delete(recursive: true);
  });

  test('holds nothing to begin with', () async {
    final cache = await OsmImageryCache.open(directory: _work);
    expect(cache.tiles, isEmpty);
    expect(cache.bytes, 0);
    expect(await cache.read(_a), isNull);
    expect(cache.entry(_a), isNull);
  });

  test('gives back a tile exactly as it arrived', () async {
    final cache = await OsmImageryCache.open(directory: _work);
    final body = _bytes(1024);
    await cache.write(_a, body);
    expect(await cache.read(_a), body);
    expect(cache.bytes, 1024);
  });

  test('is still there after opening again', () async {
    final first = await OsmImageryCache.open(directory: _work);
    await first.write(_a, _bytes(512));
    final second = await OsmImageryCache.open(directory: _work);
    expect(second.entry(_a), isNotNull);
    expect((await second.read(_a))!.length, 512);
  });

  test('remembers ground the source has nothing for', () async {
    final first = await OsmImageryCache.open(directory: _work);
    await first.markMissing(_a);
    final second = await OsmImageryCache.open(directory: _work);
    expect(second.entry(_a)!.missing, isTrue);
    expect(await second.read(_a), isNull);
    expect(second.bytes, 0);
  });

  test('counts a tile as current for its first week', () async {
    final cache = await OsmImageryCache.open(directory: _work);
    await cache.write(_a, _bytes(64));
    expect(cache.entry(_a)!.isStale, isFalse);

    final older = await _aged(OsmImageryCache.freshness * 2);
    expect(older.entry(_a)!.isStale, isTrue);
  });

  test('replaces a tile that is written again', () async {
    final cache = await OsmImageryCache.open(directory: _work);
    await cache.write(_a, _bytes(2048));
    await cache.write(_a, _bytes(16));
    expect(cache.tiles.length, 1);
    expect(cache.bytes, 16);
    expect((await cache.read(_a))!.length, 16);
  });

  test('forgets a tile on request', () async {
    final cache = await OsmImageryCache.open(directory: _work);
    await cache.write(_a, _bytes(64));
    await cache.forget(_a);
    expect(cache.entry(_a), isNull);
    expect(await cache.read(_a), isNull);
    expect(cache.bytes, 0);
  });

  test('throws away the oldest when it runs out of room', () async {
    final cache = await OsmImageryCache.open(directory: _work, maximumBytes: 1);
    await cache.write(_a, _bytes(64));
    await cache.write(_b, _bytes(64));
    // Each is over the limit alone, so only the newest survives.
    expect(cache.entry(_a), isNull);
    expect(cache.entry(_b), isNotNull);
  });

  test('stays inside its limit', () async {
    final cache =
        await OsmImageryCache.open(directory: _work, maximumBytes: 4096);
    for (var i = 0; i < 20; i++) {
      await cache.write(OsmTile(17, 129167 + i, 79983), _bytes(512));
    }
    expect(cache.bytes, lessThanOrEqualTo(4096));
    expect(cache.tiles, isNotEmpty);
  });

  test('fetches a tile again when its file has gone', () async {
    final first = await OsmImageryCache.open(directory: _work);
    await first.write(_a, _bytes(64));
    for (final entry in _work.listSync()) {
      if (entry is Directory) entry.deleteSync(recursive: true);
    }
    final second = await OsmImageryCache.open(directory: _work);
    expect(second.entry(_a), isNull);
  });

  test('starts again rather than trusting an index it cannot read', () async {
    final first = await OsmImageryCache.open(directory: _work);
    await first.write(_a, _bytes(64));
    File('${_work.path}/index.json').writeAsStringSync('not json');
    expect((await OsmImageryCache.open(directory: _work)).tiles, isEmpty);
  });

  test('ignores an index written by something else', () async {
    final first = await OsmImageryCache.open(directory: _work);
    await first.write(_a, _bytes(64));
    File('${_work.path}/index.json').writeAsStringSync('{"version":99}');
    expect((await OsmImageryCache.open(directory: _work)).tiles, isEmpty);
  });
}
