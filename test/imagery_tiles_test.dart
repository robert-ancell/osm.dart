import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:osm/osm.dart';
import 'package:test/test.dart';

late Directory _work;

const _source = OsmImagery(
  id: 'test',
  name: 'Test',
  url: 'https://example.test/{zoom}/{x}/{y}.png',
  maximumZoom: 20,
);

const _tile = OsmTile(17, 129167, 79983);

/// A tile server that can be told to have nothing, or to be away.
class _Server {
  final List<String> asked = [];
  bool empty = false;
  bool away = false;

  Future<Uint8List?> fetch(
    Uri uri, {
    Future<void>? abandon,
    void Function(Uint8List body)? onLate,
  }) async {
    asked.add(uri.path);
    if (away) throw const SocketException('nothing is listening');
    if (empty) return null;
    return Uint8List.fromList(utf8.encode('picture of ${uri.path}'));
  }
}

/// The index, as it is published, for one layer with no shape.
const _index = '''
{"type": "FeatureCollection", "features": [
  {"type": "Feature", "properties": {"id": "A", "name": "A", "type": "tms",
    "category": "photo", "url": "https://a.test/{zoom}/{x}/{y}.png"},
   "geometry": null}]}
''';

void main() {
  setUp(() async {
    _work = await Directory.systemTemp.createTemp('osm_imagery_tiles');
  });

  tearDown(() async {
    if (_work.existsSync()) await _work.delete(recursive: true);
  });

  group('tiles', () {
    test('fetches a tile and hands back what the server sent', () async {
      final server = _Server();
      final tiles = OsmImageryTiles(source: _source, fetch: server.fetch);
      final body = await tiles.tile(_tile);
      expect(utf8.decode(body!), contains('/17/129167/79983.png'));
      expect(server.asked.single, '/17/129167/79983.png');
    });

    test('keeps what it fetched and does not ask twice', () async {
      final server = _Server();
      final cache = await OsmImageryCache.open(directory: _work);
      final tiles = OsmImageryTiles(
        source: _source,
        fetch: server.fetch,
        cache: cache,
      );
      final first = await tiles.tile(_tile);
      final second = await tiles.tile(_tile);
      expect(server.asked.length, 1);
      expect(second, first);
    });

    test('gives back what it kept on a later run', () async {
      final server = _Server();
      final first = await OsmImageryCache.open(directory: _work);
      await OsmImageryTiles(source: _source, fetch: server.fetch, cache: first)
          .tile(_tile);

      final again = await OsmImageryCache.open(directory: _work);
      final second = _Server();
      final body = await OsmImageryTiles(
        source: _source,
        fetch: second.fetch,
        cache: again,
      ).tile(_tile);
      expect(second.asked, isEmpty);
      expect(body, isNotNull);
    });

    test('remembers ground the source has nothing for', () async {
      final server = _Server()..empty = true;
      final cache = await OsmImageryCache.open(directory: _work);
      final tiles = OsmImageryTiles(
        source: _source,
        fetch: server.fetch,
        cache: cache,
      );
      expect(await tiles.tile(_tile), isNull);
      expect(tiles.isEmptyAt(_tile), isTrue);
      expect(await tiles.tile(_tile), isNull);
      expect(server.asked.length, 1);
    });

    test('hands over an old tile before fetching a newer one', () async {
      final server = _Server();
      final cache = await OsmImageryCache.open(directory: _work);
      await OsmImageryTiles(source: _source, fetch: server.fetch, cache: cache)
          .tile(_tile);

      // A fortnight on.
      final index = File('${_work.path}/index.json');
      final long = DateTime.now()
          .subtract(OsmImageryCache.freshness * 2)
          .millisecondsSinceEpoch;
      await index.writeAsString(
        (await index.readAsString())
            .replaceAll(RegExp(r'"at":\d+'), '"at":$long'),
      );

      final aged = await OsmImageryCache.open(directory: _work);
      final later = _Server();
      Uint8List? early;
      final body = await OsmImageryTiles(
        source: _source,
        fetch: later.fetch,
        cache: aged,
      ).tile(_tile, onHeld: (held) => early = held);
      expect(early, isNotNull, reason: 'something to draw at once');
      expect(later.asked.length, 1, reason: 'and a newer one fetched');
      expect(body, isNotNull);
    });

    test('works with nowhere to keep anything', () async {
      final server = _Server();
      final tiles = OsmImageryTiles(source: _source, fetch: server.fetch);
      expect(await tiles.tile(_tile), isNotNull);
      expect(tiles.isEmptyAt(_tile), isFalse);
    });
  });

  group('index', () {
    File file() => File('${_work.path}/${OsmImageryIndexCache.file}');

    test('reads the index and keeps it', () async {
      final asked = <Uri>[];
      final index = await OsmImageryIndexCache(
          directory: _work,
          fetch: (uri, {abandon, onLate}) async {
            asked.add(uri);
            return Uint8List.fromList(utf8.encode(_index));
          }).read();
      expect(index.layers.single.id, 'A');
      expect(
        asked.single.toString(),
        '${OsmImageryIndexCache.defaultUrl}${OsmImageryIndexCache.file}',
      );
      expect(file().existsSync(), isTrue);
    });

    test('uses the copy it kept rather than asking again', () async {
      var asked = 0;
      Future<Uint8List?> fetch(Uri uri,
          {Future<void>? abandon, void Function(Uint8List)? onLate}) async {
        asked++;
        return Uint8List.fromList(utf8.encode(_index));
      }

      await OsmImageryIndexCache(directory: _work, fetch: fetch).read();
      await OsmImageryIndexCache(directory: _work, fetch: fetch).read();
      expect(asked, 1);
    });

    test('keeps an old copy when it cannot be reached', () async {
      await OsmImageryIndexCache(
          directory: _work,
          fetch: (uri, {abandon, onLate}) async =>
              Uint8List.fromList(utf8.encode(_index))).read();
      await file().setLastModified(
        DateTime.now().subtract(OsmImageryIndexCache.freshness * 2),
      );
      final index = await OsmImageryIndexCache(
          directory: _work,
          fetch: (uri, {abandon, onLate}) async =>
              throw const SocketException('away')).read();
      expect(index.layers.single.id, 'A');
    });

    test('falls back to what it was given with nothing else', () async {
      const spare = OsmImagery(id: 'spare', name: 'Spare', url: 'https://s/');
      final index = await OsmImageryIndexCache(
          directory: _work,
          fetch: (uri, {abandon, onLate}) async =>
              throw const SocketException('away')).read(
        fallback: const [spare],
      );
      expect(index.layers.single.id, 'spare');
    });

    test('falls back rather than trusting something that is not an index',
        () async {
      final index = await OsmImageryIndexCache(
          directory: _work,
          fetch: (uri, {abandon, onLate}) async =>
              Uint8List.fromList(utf8.encode('not json'))).read();
      expect(index.layers, isEmpty);
      expect(file().existsSync(), isFalse);
    });
  });
}
