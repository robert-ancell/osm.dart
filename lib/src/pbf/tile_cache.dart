import 'dart:convert';
import 'dart:io';

import '../cache.dart';
import '../element.dart';
import '../pbf/file.dart';
import '../pbf/writer.dart';
import '../tile.dart';

/// How much of the disk the cache is allowed.
///
/// A box of a few hundred metres comes to a few kilobytes written this way,
/// so this holds a good deal of everywhere that has been looked at.
const osmTileCacheBytes = 40 * 1024 * 1024;

/// When a held box is old enough to be worth checking.
///
/// Nothing is thrown away at this age. It only decides which boxes are
/// mentioned when asking the API what has been edited lately.
const osmTileCacheFreshness = Duration(hours: 12);

/// What is known about one box held on disk.
class OsmCachedTile {
  /// Which box it is.
  final OsmTile id;

  /// When it was read from the API.
  final DateTime at;

  /// How much disk it takes.
  final int bytes;

  /// Creates a record of a held box.
  const OsmCachedTile(
      {required this.id, required this.at, required this.bytes});

  /// Whether it is old enough to be worth checking for edits.
  bool get isStale => DateTime.now().difference(at) > osmTileCacheFreshness;
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
class OsmTileCache {
  /// The directory under [osmCacheDirectory] it is kept in by default.
  static const name = 'data';

  /// Where the files are.
  final Directory directory;

  /// The most disk the cache may take.
  final int maximumBytes;

  final _held = <OsmTile, OsmCachedTile>{};

  OsmTileCache._(this.directory, this.maximumBytes);

  /// Opens the cache in [directory], by default [name] under
  /// [osmCacheDirectory], reading what it already holds.
  ///
  /// A cache that cannot be read is started again rather than treated as an
  /// error. It holds nothing that cannot be read a second time.
  static Future<OsmTileCache> open({
    Directory? directory,
    int maximumBytes = osmTileCacheBytes,
  }) async {
    directory ??= osmCacheDirectory(name);
    final cache = OsmTileCache._(directory, maximumBytes);
    try {
      await directory.create(recursive: true);
      await cache._readIndex();
    } on Exception {
      // Half written, or written by something else entirely. Nothing here
      // cannot be read again, so starting over costs only the reading.
      cache._held.clear();
    }
    return cache;
  }

  /// Every box held, oldest read first.
  List<OsmCachedTile> get tiles {
    final all = _held.values.toList()..sort((a, b) => a.at.compareTo(b.at));
    return all;
  }

  /// How much disk the cache is taking.
  int get bytes => _held.values.fold(0, (total, tile) => total + tile.bytes);

  /// What is known about [tile], or null if it is not held.
  OsmCachedTile? entry(OsmTile tile) => _held[tile];

  /// Whether [tile] is held.
  bool holds(OsmTile tile) => _held.containsKey(tile);

  /// The elements held for [tile], or null if it is not held or unreadable.
  Future<List<OsmElement>?> read(OsmTile tile) async {
    if (!_held.containsKey(tile)) return null;
    try {
      final file = await OsmPbfFile.open(_pathOf(tile));
      return await file.elements(isolates: 1).toList();
    } on Exception {
      // A file written by an older version, or a half written one left by a
      // run that stopped. Forget it and read the box again.
      await forget(tile);
      return null;
    }
  }

  /// Writes [elements] as the contents of [tile], replacing what was held.
  Future<void> write(OsmTile tile, List<OsmElement> elements) async {
    final path = _pathOf(tile);
    try {
      await Directory(File(path).parent.path).create(recursive: true);
      final writer = await OsmPbfWriter.create(path);
      // A block holds one kind of element, so grouping them saves the writer
      // from starting a new block on every change of kind.
      for (final type in OsmElementType.values) {
        for (final element in elements) {
          if (element.type == type) writer.add(element);
        }
      }
      await writer.close();
      _held[tile] = OsmCachedTile(
        id: tile,
        at: DateTime.now(),
        bytes: await File(path).length(),
      );
      await _evict(keeping: tile);
      await _writeIndex();
    } on IOException {
      // Not being able to write to the disk is not a reason to stop drawing
      // the map, so the box is simply not held.
      _held.remove(tile);
    }
  }

  /// Records that [tile] was checked for edits and found current, so it is
  /// not asked about again until it has aged.
  Future<void> markChecked(OsmTile tile) async {
    final held = _held[tile];
    if (held == null) return;
    _held[tile] =
        OsmCachedTile(id: tile, at: DateTime.now(), bytes: held.bytes);
    await _writeIndex();
  }

  /// Drops [tile] from the cache.
  Future<void> forget(OsmTile tile) async {
    _held.remove(tile);
    try {
      final file = File(_pathOf(tile));
      if (file.existsSync()) await file.delete();
    } on IOException {
      // Already gone, which is what was wanted.
    }
  }

  /// Throws away the boxes read longest ago until the cache is inside its
  /// limit.
  ///
  /// The box just written is never one of them. A single box larger than the
  /// whole cache would otherwise be thrown away the moment it arrived, which
  /// would make writing it pointless; it goes when the next one comes.
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
      '${directory.path}/${tile.zoom}/${tile.x}/${tile.y}.osm.pbf';

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
      final read = entry['at'];
      final size = entry['bytes'];
      if (zoom is! int || x is! int || y is! int) continue;
      if (read is! int || size is! int) continue;
      final id = OsmTile(zoom, x, y);
      // A file that has gone, because something else cleared the directory
      // or a write never finished, is not held however the index reads.
      if (!File(_pathOf(id)).existsSync()) continue;
      _held[id] = OsmCachedTile(
        id: id,
        at: DateTime.fromMillisecondsSinceEpoch(read),
        bytes: size,
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
              },
          ],
        }),
      );
    } on IOException {
      // The cache is a convenience. Losing the index costs a re-read.
    }
  }

  /// What the index looks like. An index written by anything else is
  /// ignored, which starts the cache again rather than misreading it.
  static const _indexVersion = 1;
}
