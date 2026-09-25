import 'dart:io';
import 'dart:typed_data';

import 'package:osm/osm.dart';
import 'package:test/test.dart';

Future<Uint8List?> _offline(
  Uri uri, {
  Future<void>? abandon,
  void Function(Uint8List)? onLate,
}) async =>
    throw const SocketException('offline');

void main() {
  test('keeps every cache in a directory of its own under one', () async {
    final root = Directory.systemTemp.createTempSync('osm_cache');
    addTearDown(() => root.deleteSync(recursive: true));

    final cache = await OsmCache.open(directory: root, fetch: _offline);
    final directories = [
      cache.tiles.directory,
      cache.imagery.directory,
      cache.imageryIndex.directory,
      cache.presets.directory,
      cache.countryCoder.directory,
      cache.replication,
    ];
    expect(directories.map((d) => d.parent.path).toSet(), {root.path});
    expect(directories.map((d) => d.path).toSet(), hasLength(6));
  });

  test('keeps each cache under the shared directory by default', () {
    final root = osmCacheDirectory().path;
    for (final (name, directory) in [
      (
        OsmPresetsCache.name,
        OsmPresetsCache(fetch: _offline).directory,
      ),
      (
        OsmCountryCoderCache.name,
        OsmCountryCoderCache(fetch: _offline).directory,
      ),
      (
        OsmImageryIndexCache.name,
        OsmImageryIndexCache(fetch: _offline).directory,
      ),
    ]) {
      expect(directory.path, osmCacheDirectory(name).path);
      expect(directory.parent.path, root);
    }
    expect(
      {
        OsmTileCache.name,
        OsmImageryCache.name,
        OsmImageryIndexCache.name,
        OsmPresetsCache.name,
        OsmCountryCoderCache.name,
        OsmReplication.cacheName,
      },
      hasLength(6),
    );
  });

  test('keeps the diffs of different feeds apart', () {
    final planet = OsmReplication(fetch: _offline);
    final region = OsmReplication.geofabrik('australia-oceania/new-zealand',
        fetch: _offline);
    expect(planet.cachePath, 'planet.openstreetmap.org/replication');
    expect(
      region.cachePath,
      'download.geofabrik.de/australia-oceania/new-zealand-updates',
    );
  });
}
