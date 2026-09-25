import 'dart:io';

import 'country_coder.dart';
import 'country_coder_cache.dart';
import 'imagery.dart';
import 'imagery_cache.dart';
import 'imagery_index_cache.dart';
import 'data_cache.dart';
import 'presets.dart';
import 'presets_cache.dart';
import 'update/http.dart';
import 'update/replication.dart';
import 'update/updater.dart';

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
  /// a directory of its own: a data or imagery cache's index is written by
  /// one program at a time.
  static Directory defaultDirectory([String? name]) {
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
    return Directory(
        name == null ? root : '$root${Platform.pathSeparator}$name');
  }

  /// The directory each cache is a directory of, by its `name`.
  final Directory directory;

  /// Boxes of OpenStreetMap data, as read from the API.
  final OsmDataCache dataCache;

  /// Imagery tiles, as they arrived.
  final OsmImageryCache imageryCache;

  /// Where [imageryIndex] is kept.
  final OsmImageryIndexCache imageryIndexCache;

  /// Where [presets] are kept.
  final OsmPresetsCache presetsCache;

  /// Where [countryCoder] is kept.
  final OsmCountryCoderCache countryCoderCache;

  /// Where replication diffs go, for [OsmReplication.download] and
  /// [OsmPbfUpdater]. Each feed's are kept apart inside it.
  final Directory replicationDirectory;

  OsmCountryCoder? _countryCoder;
  OsmImageryIndex? _imageryIndex;
  final _presets = <String, OsmPresets>{};

  OsmCache._({
    required this.directory,
    required this.dataCache,
    required this.imageryCache,
    required this.imageryIndexCache,
    required this.presetsCache,
    required this.countryCoderCache,
    required this.replicationDirectory,
  });

  /// Opens every cache in [directory], by default [OsmCache.defaultDirectory].
  ///
  /// Nothing is fetched until it is asked for.
  ///
  /// [contact] says who is asking, as OpenStreetMap's servers ask: a name
  /// and a way to reach whoever runs the program. [fetch] replaces fetching
  /// over HTTP altogether, for tests or a transport of the caller's own.
  static Future<OsmCache> open({
    Directory? directory,
    String? contact,
    OsmFetch? fetch,
  }) async {
    final root = directory ?? OsmCache.defaultDirectory();
    fetch ??= httpFetch(contact: contact);
    Directory under(String name) =>
        Directory('${root.path}${Platform.pathSeparator}$name');
    return OsmCache._(
      directory: root,
      dataCache: await OsmDataCache.open(directory: under(OsmDataCache.name)),
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
  /// Read the first time they are asked for and kept. Empty only when there
  /// is no copy on disk and none could be fetched, in which case the next
  /// ask tries again.
  Future<OsmCountryCoder> get countryCoder async {
    final held = _countryCoder;
    if (held != null) return held;
    final read = await countryCoderCache.read();
    if (read.all.isNotEmpty) _countryCoder = read;
    return read;
  }

  /// iD's tagging schema in [language], which says what kinds of thing there
  /// are.
  ///
  /// Read the first time each language is asked for and kept. Empty only
  /// when there is no copy on disk and none could be fetched, in which case
  /// the next ask tries again.
  Future<OsmPresets> presets({String language = 'en'}) async {
    final held = _presets[language];
    if (held != null) return held;
    final read = await presetsCache.read(language: language);
    if (read.byId.isNotEmpty) _presets[language] = read;
    return read;
  }

  /// The editor layer index, which says what imagery there is.
  ///
  /// Read the first time it is asked for and kept. Empty only when there is
  /// no copy on disk and none could be fetched, in which case the next ask
  /// tries again.
  Future<OsmImageryIndex> get imageryIndex async {
    final held = _imageryIndex;
    if (held != null) return held;
    final read = await imageryIndexCache.read();
    if (read.layers.isNotEmpty) _imageryIndex = read;
    return read;
  }
}
