import 'dart:convert';
import 'dart:io';

import 'cache.dart';
import 'dart:typed_data';

import 'tile.dart';

/// How much of the disk imagery is allowed.
///
/// A tile is about thirteen kilobytes, so this is something like fifteen
/// thousand of them: a good deal of everywhere that has been looked at.
const osmImageryCacheBytes = 200 * 1024 * 1024;

/// How long a tile is used without asking whether it has changed.
///
/// The LINZ tile server says `max-age=604800`, so a week is what it considers
/// its own answers good for. Aerial imagery is reflown in years, not days.
const osmImageryFreshness = Duration(days: 7);

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
  bool get isStale => DateTime.now().difference(at) > osmImageryFreshness;
}

/// The imagery tiles fetched so far, held on disk between runs.
///
/// Tiles are kept exactly as they arrived rather than decoded, which is both
/// far smaller and what the next run wants to decode anyway. Ground the
/// source has nothing for is remembered too, so flying over the sea does not
/// ask for the same empty tiles every time.
class OsmImageryCache {
  /// The directory under [osmCacheDirectory] it is kept in by default.
  static const name = 'imagery';

  /// Where the files are.
  final Directory directory;

  /// The most disk they may take.
  final int maximumBytes;

  final _held = <OsmTile, OsmCachedImagery>{};

  OsmImageryCache._(this.directory, this.maximumBytes);

  /// Opens the cache in [directory], by default [name] under
  /// [osmCacheDirectory], reading what it already holds.
  static Future<OsmImageryCache> open({
    Directory? directory,
    int maximumBytes = osmImageryCacheBytes,
  }) async {
    directory ??= osmCacheDirectory(name);
    final cache = OsmImageryCache._(directory, maximumBytes);
    try {
      await directory.create(recursive: true);
      await cache._readIndex();
    } on Exception {
      // Half written, or written by something else. Nothing here cannot be
      // fetched again.
      cache._held.clear();
    }
    return cache;
  }

  /// Every tile held, oldest fetched first.
  List<OsmCachedImagery> get tiles {
    final all = _held.values.toList()..sort((a, b) => a.at.compareTo(b.at));
    return all;
  }

  /// How much disk is being taken.
  int get bytes => _held.values.fold(0, (total, tile) => total + tile.bytes);

  /// What is known about [tile], or null if nothing is.
  OsmCachedImagery? entry(OsmTile tile) => _held[tile];

  /// The tile as it arrived, or null if it is not held or will not read.
  Future<Uint8List?> read(OsmTile tile) async {
    final held = _held[tile];
    if (held == null || held.missing) return null;
    try {
      return await File(_pathOf(tile)).readAsBytes();
    } on IOException {
      _held.remove(tile);
      return null;
    }
  }

  /// Keeps [body] as the contents of [tile].
  Future<void> write(OsmTile tile, Uint8List body) async {
    final path = _pathOf(tile);
    try {
      await Directory(File(path).parent.path).create(recursive: true);
      await File(path).writeAsBytes(body);
      _held[tile] = OsmCachedImagery(
        id: tile,
        at: DateTime.now(),
        bytes: body.length,
      );
      await _evict(keeping: tile);
      await _writeIndex();
    } on IOException {
      // Not being able to write is no reason to stop drawing the map.
      _held.remove(tile);
    }
  }

  /// Remembers that the source has nothing for [tile].
  Future<void> markMissing(OsmTile tile) async {
    _held[tile] = OsmCachedImagery(
      id: tile,
      at: DateTime.now(),
      bytes: 0,
      missing: true,
    );
    await _writeIndex();
  }

  /// Drops [tile].
  Future<void> forget(OsmTile tile) async {
    final held = _held.remove(tile);
    if (held == null || held.missing) return;
    try {
      final file = File(_pathOf(tile));
      if (file.existsSync()) await file.delete();
    } on IOException {
      // Already gone, which is what was wanted.
    }
  }

  /// Throws away the tiles fetched longest ago until the cache is inside its
  /// limit, never the one just written.
  Future<void> _evict({required OsmTile keeping}) async {
    var total = bytes;
    if (total <= maximumBytes) return;
    for (final tile in tiles) {
      if (total <= maximumBytes) break;
      if (tile.id == keeping) continue;
      total -= tile.bytes;
      await forget(tile.id);
    }
  }

  String _pathOf(OsmTile tile) =>
      '${directory.path}/${tile.zoom}/${tile.x}/${tile.y}';

  File get _indexFile => File('${directory.path}/index.json');

  Future<void> _readIndex() async {
    if (!_indexFile.existsSync()) return;
    final parsed = jsonDecode(await _indexFile.readAsString());
    if (parsed is! Map<String, dynamic>) return;
    if (parsed['version'] != _indexVersion) return;
    final tiles = parsed['tiles'];
    if (tiles is! List) return;

    for (final entry in tiles) {
      if (entry is! Map<String, dynamic>) continue;
      final zoom = entry['z'];
      final x = entry['x'];
      final y = entry['y'];
      final at = entry['at'];
      final size = entry['bytes'];
      if (zoom is! int || x is! int || y is! int) continue;
      if (at is! int || size is! int) continue;
      final missing = entry['missing'] == true;
      final id = OsmTile(zoom, x, y);
      if (!missing && !File(_pathOf(id)).existsSync()) continue;
      _held[id] = OsmCachedImagery(
        id: id,
        at: DateTime.fromMillisecondsSinceEpoch(at),
        bytes: size,
        missing: missing,
      );
    }
  }

  Future<void> _writeIndex() async {
    try {
      await _indexFile.writeAsString(
        jsonEncode({
          'version': _indexVersion,
          'tiles': [
            for (final tile in _held.values)
              {
                'z': tile.id.zoom,
                'x': tile.id.x,
                'y': tile.id.y,
                'at': tile.at.millisecondsSinceEpoch,
                'bytes': tile.bytes,
                if (tile.missing) 'missing': true,
              },
          ],
        }),
      );
    } on IOException {
      // The cache is a convenience. Losing the index costs a re-fetch.
    }
  }

  /// What the index looks like. One written by anything else is ignored,
  /// which starts the cache again rather than misreading it.
  static const _indexVersion = 1;
}
