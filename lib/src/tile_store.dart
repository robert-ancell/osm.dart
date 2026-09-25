import 'dart:convert';
import 'dart:io';

import 'tile.dart';

/// What a [TileStore] knows about one tile it holds.
class TileRecord {
  /// Which tile it is.
  final OsmTile id;

  /// When it was fetched, or last found current.
  final DateTime at;

  /// How much disk it takes, or zero for a tile with nothing in it.
  final int bytes;

  /// Whether there is nothing to be had for this tile, so no file is held.
  final bool missing;

  /// Creates a record.
  const TileRecord({
    required this.id,
    required this.at,
    required this.bytes,
    this.missing = false,
  });
}

/// Files held on disk a tile at a time, within a limit, with an index saying
/// what is held and since when: what the data and imagery caches keep their
/// tiles in.
///
/// Each tile is a file at `zoom/x/y` followed by [extension]. The index is
/// `index.json`; one written by anything else is ignored, which starts the
/// store again rather than misreading it. Nothing held cannot be fetched
/// again, so failing to read or write is never an error: the tile is simply
/// not held.
class TileStore {
  /// Where the files are.
  final Directory directory;

  /// The most disk the files may take.
  final int maximumBytes;

  /// What follows a tile's numbers in its file name.
  final String extension;

  final _held = <OsmTile, TileRecord>{};

  TileStore._(this.directory, this.maximumBytes, this.extension);

  /// Opens the store in [directory], reading what it already holds.
  static Future<TileStore> open(
    Directory directory, {
    required int maximumBytes,
    String extension = '',
  }) async {
    final store = TileStore._(directory, maximumBytes, extension);
    try {
      await directory.create(recursive: true);
      await store._readIndex();
    } on Exception {
      // Half written, or written by something else entirely. Nothing here
      // cannot be fetched again, so starting over costs only the fetching.
      store._held.clear();
    }
    return store;
  }

  /// Every tile held, oldest first.
  List<TileRecord> get records =>
      _held.values.toList()..sort((a, b) => a.at.compareTo(b.at));

  /// How much disk is being taken.
  int get bytes => _held.values.fold(0, (total, tile) => total + tile.bytes);

  /// What is known about [tile], or null if nothing is.
  TileRecord? operator [](OsmTile tile) => _held[tile];

  /// The file [tile] is held in.
  String pathOf(OsmTile tile) =>
      '${directory.path}/${tile.zoom}/${tile.x}/${tile.y}$extension';

  /// Keeps [tile], written to its file by [write], and makes room for it.
  ///
  /// Writes that fail leave the tile not held.
  Future<void> keep(
      OsmTile tile, Future<void> Function(String path) write) async {
    final path = pathOf(tile);
    try {
      await Directory(File(path).parent.path).create(recursive: true);
      await write(path);
      _held[tile] = TileRecord(
        id: tile,
        at: DateTime.now(),
        bytes: await File(path).length(),
      );
      await _evict(keeping: tile);
      await _writeIndex();
    } on IOException {
      // Not being able to write is no reason to stop drawing the map.
      _held.remove(tile);
    }
  }

  /// Records that there is nothing to be had for [tile].
  Future<void> markMissing(OsmTile tile) async {
    _held[tile] =
        TileRecord(id: tile, at: DateTime.now(), bytes: 0, missing: true);
    await _writeIndex();
  }

  /// Records that [tile] is current as of now, as if it had just been
  /// fetched.
  Future<void> markCurrent(OsmTile tile) async {
    final held = _held[tile];
    if (held == null) return;
    _held[tile] = TileRecord(
      id: tile,
      at: DateTime.now(),
      bytes: held.bytes,
      missing: held.missing,
    );
    await _writeIndex();
  }

  /// Drops [tile], and its file.
  Future<void> forget(OsmTile tile) async {
    final held = _held.remove(tile);
    if (held == null || held.missing) return;
    try {
      final file = File(pathOf(tile));
      if (file.existsSync()) await file.delete();
    } on IOException {
      // Already gone, which is what was wanted.
    }
  }

  /// Throws away the tiles fetched longest ago until the store is inside its
  /// limit.
  ///
  /// The tile just written is never one of them. A single tile larger than
  /// the whole store would otherwise be thrown away the moment it arrived,
  /// which would make writing it pointless; it goes when the next one comes.
  Future<void> _evict({required OsmTile keeping}) async {
    var total = bytes;
    if (total <= maximumBytes) return;
    for (final tile in records) {
      if (total <= maximumBytes) break;
      if (tile.id == keeping) continue;
      total -= tile.bytes;
      await forget(tile.id);
    }
  }

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
      // A file that has gone, because something else cleared the directory
      // or a write never finished, is not held however the index reads.
      if (!missing && !File(pathOf(id)).existsSync()) continue;
      _held[id] = TileRecord(
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
      // The index is a convenience. Losing it costs a fetch again.
    }
  }

  static const _indexVersion = 1;
}
