import 'dart:io';

import 'country_coder.dart';
import 'country_coder_cache.dart';
import 'imagery.dart';
import 'imagery_cache.dart';
import 'imagery_index_cache.dart';
import 'pbf/tile_cache.dart';
import 'presets.dart';
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

/// OpenStreetMap's resources, each fetched once and kept in one directory.
///
/// For a program that wants them and does not mind where they are kept:
/// open one of these and ask it for [countryCoder], [presets] or
/// [imageryIndex], each read from disk when a recent copy is there and from
/// the network otherwise. The caches behind them are there too, by the name
/// of what they hold and `Cache`, for anything that needs more than reading.
///
/// A program with other needs — a different place for each cache, a limit
/// on the disk one may take, somewhere else to fetch from — makes whichever
/// caches it wants itself, each of which works on its own.
class OsmCache {
  /// The directory each cache is a directory of, by its `name`.
  final Directory directory;

  /// Boxes of OpenStreetMap data, as read from the API.
  final OsmTileCache tileCache;

  /// Imagery tiles, as they arrived.
  final OsmImageryCache imageryCache;

  /// Where [imageryIndex] is kept.
  final OsmImageryIndexCache imageryIndexCache;

  /// Where [presets] are kept.
  final OsmPresetsCache presetsCache;

  /// Where [countryCoder] is kept.
  final OsmCountryCoderCache countryCoderCache;

  /// Where replication diffs go, for [OsmReplication.download] and
  /// [updateOsmSnapshot]. Each feed's are kept apart inside it.
  final Directory replicationDirectory;

  Future<OsmCountryCoder?>? _countryCoder;
  Future<OsmImageryIndex>? _imageryIndex;
  final _presets = <String, Future<OsmPresets?>>{};

  OsmCache._({
    required this.directory,
    required this.tileCache,
    required this.imageryCache,
    required this.imageryIndexCache,
    required this.presetsCache,
    required this.countryCoderCache,
    required this.replicationDirectory,
  });

  /// Opens every cache in [directory], by default [osmCacheDirectory],
  /// fetching what has to be fetched with [fetch].
  ///
  /// Nothing is fetched until it is asked for.
  static Future<OsmCache> open({
    Directory? directory,
    required OsmFetch fetch,
  }) async {
    final root = directory ?? osmCacheDirectory();
    Directory under(String name) =>
        Directory('${root.path}${Platform.pathSeparator}$name');
    return OsmCache._(
      directory: root,
      tileCache: await OsmTileCache.open(directory: under(OsmTileCache.name)),
      imageryCache:
          await OsmImageryCache.open(directory: under(OsmImageryCache.name)),
      imageryIndexCache: OsmImageryIndexCache(
        directory: under(OsmImageryIndexCache.name),
        fetch: fetch,
      ),
      presetsCache: OsmPresetsCache(
        directory: under(OsmPresetsCache.name),
        fetch: fetch,
      ),
      countryCoderCache: OsmCountryCoderCache(
        directory: under(OsmCountryCoderCache.name),
        fetch: fetch,
      ),
      replicationDirectory: under(OsmReplication.cacheName),
    );
  }

  /// country-coder's borders, which say which country a place is in.
  ///
  /// Read once and shared by everything that asks. Null only when there is
  /// no copy on disk and none could be fetched, in which case the next ask
  /// tries again.
  Future<OsmCountryCoder?> get countryCoder =>
      _countryCoder ??= _retrying(countryCoderCache.read(), () {
        _countryCoder = null;
      });

  /// iD's tagging schema in [language], which says what kinds of thing there
  /// are.
  ///
  /// Read once for each language and shared by everything that asks. Null
  /// only when there is no copy on disk and none could be fetched, in which
  /// case the next ask tries again.
  Future<OsmPresets?> presets({String language = 'en'}) =>
      _presets[language] ??= _retrying(
        presetsCache.read(language: language),
        () => _presets.remove(language),
      );

  /// The editor layer index, which says what imagery there is.
  ///
  /// Read once and shared by everything that asks. Empty only when there is
  /// no copy on disk and none could be fetched, in which case the next ask
  /// tries again.
  Future<OsmImageryIndex> get imageryIndex =>
      _imageryIndex ??= imageryIndexCache.read().then((index) {
        if (index.layers.isEmpty) _imageryIndex = null;
        return index;
      });

  /// [reading], forgetting it with [forget] if it comes to nothing.
  static Future<T?> _retrying<T>(Future<T?> reading, void Function() forget) =>
      reading.then((read) {
        if (read == null) forget();
        return read;
      });
}
