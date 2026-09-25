import 'dart:io';

import 'cache.dart';
import 'element.dart';
import 'pbf/file.dart';
import 'pbf/writer.dart';
import 'tile.dart';
import 'tile_store.dart';

/// What is known about one box held on disk.
class OsmCachedData {
  /// Which box it is.
  final OsmTile id;

  /// When it was read from the API.
  final DateTime at;

  /// How much disk it takes.
  final int bytes;

  /// Creates a record of a held box.
  const OsmCachedData(
      {required this.id, required this.at, required this.bytes});

  /// Whether it is old enough to be worth checking for edits.
  bool get isStale => DateTime.now().difference(at) > OsmDataCache.freshness;
}

/// Boxes of OpenStreetMap data held on disk between runs.
///
/// Opening the editor over somewhere visited before should show it at once
/// rather than after a round trip, and coming back to an area later should
/// not read it again from the start. Boxes are written as `.osm.pbf`, which
/// is about a third the size of the gzipped XML they arrived as and is read
/// back by the same code that reads a planet extract.
///
/// The API carries no entity tag and answers a conditional request with the
/// whole body, so nothing here can be revalidated over HTTP. What is held is
/// checked by asking the API what has been edited over the area instead.
class OsmDataCache {
  /// How much of the disk the cache is allowed.
  ///
  /// A box of a few hundred metres comes to a few kilobytes written this way,
  /// so this holds a good deal of everywhere that has been looked at.
  static const defaultMaximumBytes = 40 * 1024 * 1024;

  /// When a held box is old enough to be worth checking.
  ///
  /// Nothing is thrown away at this age. It only decides which boxes are
  /// mentioned when asking the API what has been edited lately.
  static const freshness = Duration(hours: 12);

  /// The directory under [OsmCache.defaultDirectory] it is kept in by default.
  static const name = 'data';

  final TileStore _store;

  OsmDataCache._(this._store);

  /// Where the files are.
  Directory get directory => _store.directory;

  /// The most disk the cache may take.
  int get maximumBytes => _store.maximumBytes;

  /// Opens the cache in [directory], by default [name] under
  /// [OsmCache.defaultDirectory], reading what it already holds.
  ///
  /// A cache that cannot be read is started again rather than treated as an
  /// error. It holds nothing that cannot be read a second time.
  static Future<OsmDataCache> open({
    Directory? directory,
    int maximumBytes = OsmDataCache.defaultMaximumBytes,
  }) async =>
      OsmDataCache._(
        await TileStore.open(
          directory ?? OsmCache.defaultDirectory(name),
          maximumBytes: maximumBytes,
          extension: '.osm.pbf',
        ),
      );

  static OsmCachedData _of(TileRecord record) =>
      OsmCachedData(id: record.id, at: record.at, bytes: record.bytes);

  /// Every box held, oldest read first.
  List<OsmCachedData> get tiles => [for (final r in _store.records) _of(r)];

  /// How much disk the cache is taking.
  int get bytes => _store.bytes;

  /// What is known about [tile], or null if it is not held.
  OsmCachedData? entry(OsmTile tile) => switch (_store[tile]) {
        final record? => _of(record),
        null => null,
      };

  /// Whether [tile] is held.
  bool holds(OsmTile tile) => _store[tile] != null;

  /// The elements held for [tile], or null if it is not held or unreadable.
  Future<List<OsmElement>?> read(OsmTile tile) async {
    if (!holds(tile)) return null;
    try {
      final file = await OsmPbfFile.open(_store.pathOf(tile));
      return await file.elements(isolates: 1).toList();
    } on Exception {
      // A file written by an older version, or a half written one left by a
      // run that stopped. Forget it and read the box again.
      await forget(tile);
      return null;
    }
  }

  /// Writes [elements] as the contents of [tile], replacing what was held.
  ///
  /// The boxes read longest ago are thrown away to make room, never the one
  /// just written.
  Future<void> write(OsmTile tile, List<OsmElement> elements) =>
      _store.keep(tile, (path) async {
        final writer = await OsmPbfWriter.create(path);
        // A block holds one kind of element, so grouping them saves the
        // writer from starting a new block on every change of kind.
        for (final type in OsmElementType.values) {
          for (final element in elements) {
            if (element.type == type) writer.add(element);
          }
        }
        await writer.close();
      });

  /// Records that [tile] was checked for edits and found current, so it is
  /// not asked about again until it has aged.
  Future<void> markChecked(OsmTile tile) => _store.markCurrent(tile);

  /// Drops [tile] from the cache.
  Future<void> forget(OsmTile tile) => _store.forget(tile);
}
