import 'dart:io';

import 'country_coder_cache.dart';
import 'imagery_cache.dart';
import 'imagery_index_cache.dart';
import 'pbf/tile_cache.dart';
import 'presets_cache.dart';
import 'update/http.dart';
import 'update/replication.dart';
import 'update/updater.dart';

/// The directory every cache here is kept under unless it is given another.
///
/// The platform's own place for caches, which anything is entitled to empty:
///
/// - `$XDG_CACHE_HOME/osm.dart`, or `~/.cache/osm.dart`, on Linux and other
///   Unix systems;
/// - `~/Library/Caches/osm.dart` on macOS;
/// - `%LOCALAPPDATA%\osm.dart\Cache` on Windows.
///
/// With [name], the directory of that name under it. Each cache has its own
/// name, the `name` of its class, so that none of them writes over another.
///
/// Shared by every program using this package that does not choose its own,
/// so that what one has fetched the next does not fetch again. A program
/// that will be running at the same time as another should give its caches
/// a directory of its own: a tile cache's index is written by one program at
/// a time.
Directory osmCacheDirectory([String? name]) {
  final environment = Platform.environment;
  final home = environment['HOME'] ?? environment['USERPROFILE'] ?? '.';
  final String root;
  if (Platform.isWindows) {
    final local = environment['LOCALAPPDATA'] ?? '$home\\AppData\\Local';
    root = '$local\\osm.dart\\Cache';
  } else if (Platform.isMacOS) {
    root = '$home/Library/Caches/osm.dart';
  } else {
    final xdg = environment['XDG_CACHE_HOME'];
    root = '${xdg == null || xdg.isEmpty ? '$home/.cache' : xdg}/osm.dart';
  }
  return Directory(name == null ? root : '$root${Platform.pathSeparator}$name');
}

/// Every cache here, together in one directory.
///
/// For a program that wants OpenStreetMap's resources and does not mind
/// where they are kept: open one of these and read everything through it.
/// A program with other needs — a different place for each cache, a limit
/// on the disk one may take, somewhere else to fetch from — makes whichever
/// caches it wants itself, each of which works on its own.
class OsmCache {
  /// The directory each cache is a directory of, by its `name`.
  final Directory directory;

  /// Boxes of OpenStreetMap data, as read from the API.
  final OsmTileCache tiles;

  /// Imagery tiles, as they arrived.
  final OsmImageryCache imagery;

  /// The editor layer index, which says what imagery there is.
  final OsmImageryIndexCache imageryIndex;

  /// iD's tagging schema, which says what kinds of thing there are.
  final OsmPresetsCache presets;

  /// country-coder's borders, which say which country a place is in.
  final OsmCountryCoderCache countryCoder;

  /// Where replication diffs go, for [OsmReplication.download] and
  /// [updateOsmSnapshot]. Each feed's are kept apart inside it.
  final Directory replication;

  OsmCache._({
    required this.directory,
    required this.tiles,
    required this.imagery,
    required this.imageryIndex,
    required this.presets,
    required this.countryCoder,
    required this.replication,
  });

  /// Opens every cache in [directory], by default [osmCacheDirectory],
  /// fetching what has to be fetched with [fetch].
  ///
  /// Nothing is fetched until it is read.
  static Future<OsmCache> open({
    Directory? directory,
    required OsmFetch fetch,
  }) async {
    final root = directory ?? osmCacheDirectory();
    Directory under(String name) =>
        Directory('${root.path}${Platform.pathSeparator}$name');
    return OsmCache._(
      directory: root,
      tiles: await OsmTileCache.open(directory: under(OsmTileCache.name)),
      imagery:
          await OsmImageryCache.open(directory: under(OsmImageryCache.name)),
      imageryIndex: OsmImageryIndexCache(
        directory: under(OsmImageryIndexCache.name),
        fetch: fetch,
      ),
      presets: OsmPresetsCache(
        directory: under(OsmPresetsCache.name),
        fetch: fetch,
      ),
      countryCoder: OsmCountryCoderCache(
        directory: under(OsmCountryCoderCache.name),
        fetch: fetch,
      ),
      replication: under(OsmReplication.cacheName),
    );
  }
}
