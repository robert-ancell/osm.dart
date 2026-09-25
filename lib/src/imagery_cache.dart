import 'dart:io';
import 'dart:typed_data';

import 'cache.dart';
import 'tile.dart';
import 'tile_store.dart';

/// What is known about one tile held on disk.
class OsmCachedImagery {
  /// Which tile it is.
  final OsmTile id;

  /// When it was fetched.
  final DateTime at;

  /// How much disk it takes, or zero for ground the source has nothing for.
  final int bytes;

  /// Whether the source has nothing here, so there is no point asking again.
  final bool missing;

  /// Creates a record of a held tile.
  const OsmCachedImagery({
    required this.id,
    required this.at,
    required this.bytes,
    this.missing = false,
  });

  /// Whether it is old enough to be worth fetching again.
  bool get isStale => DateTime.now().difference(at) > OsmImageryCache.freshness;
}

/// The imagery tiles fetched so far, held on disk between runs.
///
/// Tiles are kept exactly as they arrived rather than decoded, which is both
/// far smaller and what the next run wants to decode anyway. Ground the
/// source has nothing for is remembered too, so flying over the sea does not
/// ask for the same empty tiles every time.
class OsmImageryCache {
  /// How much of the disk imagery is allowed.
  ///
  /// A tile is about thirteen kilobytes, so this is something like fifteen
  /// thousand of them: a good deal of everywhere that has been looked at.
  static const defaultMaximumBytes = 200 * 1024 * 1024;

  /// How long a tile is used without asking whether it has changed.
  ///
  /// Imagery servers commonly say `max-age=604800`, so a week is what they
  /// consider their own answers good for. Aerial imagery is reflown in
  /// years, not days.
  static const freshness = Duration(days: 7);

  /// The directory under [OsmCache.defaultDirectory] it is kept in by default.
  static const name = 'imagery';

  final TileStore _store;

  OsmImageryCache._(this._store);

  /// Where the files are.
  Directory get directory => _store.directory;

  /// The most disk they may take.
  int get maximumBytes => _store.maximumBytes;

  /// Opens the cache in [directory], by default [name] under
  /// [OsmCache.defaultDirectory], reading what it already holds.
  static Future<OsmImageryCache> open({
    Directory? directory,
    int maximumBytes = OsmImageryCache.defaultMaximumBytes,
  }) async =>
      OsmImageryCache._(
        await TileStore.open(
          directory ?? OsmCache.defaultDirectory(name),
          maximumBytes: maximumBytes,
        ),
      );

  static OsmCachedImagery _of(TileRecord record) => OsmCachedImagery(
        id: record.id,
        at: record.at,
        bytes: record.bytes,
        missing: record.missing,
      );

  /// Every tile held, oldest fetched first.
  List<OsmCachedImagery> get tiles => [for (final r in _store.records) _of(r)];

  /// How much disk is being taken.
  int get bytes => _store.bytes;

  /// What is known about [tile], or null if nothing is.
  OsmCachedImagery? entry(OsmTile tile) => switch (_store[tile]) {
        final record? => _of(record),
        null => null,
      };

  /// The tile as it arrived, or null if it is not held or will not read.
  Future<Uint8List?> read(OsmTile tile) async {
    final held = _store[tile];
    if (held == null || held.missing) return null;
    try {
      return await File(_store.pathOf(tile)).readAsBytes();
    } on IOException {
      await forget(tile);
      return null;
    }
  }

  /// Keeps [body] as the contents of [tile].
  ///
  /// The tiles fetched longest ago are thrown away to make room, never the
  /// one just written.
  Future<void> write(OsmTile tile, Uint8List body) =>
      _store.keep(tile, (path) => File(path).writeAsBytes(body));

  /// Remembers that the source has nothing for [tile].
  Future<void> markMissing(OsmTile tile) => _store.markMissing(tile);

  /// Drops [tile].
  Future<void> forget(OsmTile tile) => _store.forget(tile);
}
