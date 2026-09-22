import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'imagery.dart';
import 'imagery_cache.dart';
import 'tile.dart';
import 'update/http.dart';

/// Where the editor layer index publishes itself.
const osmImageryIndexUrl =
    'https://osmlab.github.io/editor-layer-index/imagery.geojson';

/// How long a copy of the index is used before it is fetched again.
///
/// Layers are added and withdrawn over weeks, not hours, and a tool that
/// cannot reach the index is better off with last week's list than none.
const osmImageryIndexFreshness = Duration(days: 7);

/// Fetches imagery tiles, keeping what it fetches.
///
/// Tiles are held exactly as they arrived rather than decoded, which is far
/// smaller and is what the caller wants to decode anyway. Ground the source
/// has nothing for is remembered as well, so passing over the sea does not
/// ask for the same empty tiles on every run.
///
/// Nothing here draws anything: what comes back is the bytes the server sent,
/// for the caller to decode however it draws.
class OsmImageryTiles {
  /// Which layer the tiles come from.
  final OsmImagery source;

  /// How they are fetched.
  final OsmFetch fetch;

  /// Where they are kept between runs, if anywhere.
  final OsmImageryCache? cache;

  /// Creates a fetcher.
  const OsmImageryTiles({
    required this.source,
    required this.fetch,
    this.cache,
  });

  /// Whether the source is known to have nothing for [tile], so that asking
  /// would be wasted.
  bool isEmptyAt(OsmTile tile) => cache?.entry(tile)?.missing ?? false;

  /// Whether what is held for [tile] is old enough to be worth fetching
  /// again, which a caller holding a decoded copy has no other way to tell.
  bool isStaleAt(OsmTile tile) => cache?.entry(tile)?.isStale ?? false;

  /// The tile as the server sends it, or null where the source has nothing.
  ///
  /// A tile already held and still within [osmImageryFreshness] is given back
  /// without asking the server anything. An older one is given to [onHeld]
  /// straight away, so that something can be drawn at once, and fetched again
  /// behind it.
  ///
  /// Completing [abandon] gives up on the fetch. A tile that was already on
  /// its way is still kept, since the server has done the work and the caller
  /// is likely to want it again.
  Future<Uint8List?> tile(
    OsmTile tile, {
    Future<void>? abandon,
    void Function(Uint8List body)? onHeld,
    void Function(Uint8List body)? onLate,
  }) async {
    final held = cache?.entry(tile);
    if (held != null) {
      if (held.missing) return null;
      final kept = await cache!.read(tile);
      if (kept != null) {
        if (!held.isStale) return kept;
        onHeld?.call(kept);
      }
    }

    final body = await fetch(
      Uri.parse(source.tileUrl(tile.zoom, tile.x, tile.y)),
      abandon: abandon,
      onLate: onLate == null
          ? null
          : (late) {
              onLate(late);
              unawaited(cache?.write(tile, late) ?? Future<void>.value());
            },
    );

    if (body == null) {
      await cache?.markMissing(tile);
      return null;
    }
    await cache?.write(tile, body);
    return body;
  }
}

/// Reads the editor layer index, keeping a copy between runs.
///
/// A megabyte of JSON describing every layer editors know about. It is parsed
/// away from the calling isolate, because a tool with an interface should not
/// be doing that where it draws.
abstract final class OsmImageryIndexFile {
  /// The index, from [file] if a recent copy is held there and from the
  /// network otherwise.
  ///
  /// Never throws: an index that cannot be had at all comes back holding
  /// [fallback], which may be empty. An old copy is used when the network
  /// cannot be reached, because an old list beats no list.
  static Future<OsmImageryIndex> read({
    required File file,
    required OsmFetch fetch,
    List<OsmImagery> fallback = const [],
    Uri? from,
  }) async {
    final held = await _held(file);
    if (held != null) return held;

    try {
      final body = await fetch(from ?? Uri.parse(osmImageryIndexUrl));
      if (body != null) {
        final json = utf8.decode(body);
        final index = await parse(json);
        if (index.layers.isNotEmpty) {
          await _keep(file, json);
          return index;
        }
      }
    } on IOException {
      // No network, or the index has moved.
    } on FormatException {
      // Something that is not the index at all, such as a portal asking to be
      // logged into. Not worth keeping.
    }

    return await _held(file, however: true) ?? OsmImageryIndex(fallback);
  }

  /// Parses an index away from the calling isolate.
  static Future<OsmImageryIndex> parse(String json) =>
      Isolate.run(() => OsmImageryIndex.parse(json));

  /// The copy on disk, or null if there is none worth using.
  ///
  /// Set [however] to take one whatever its age, which is what happens when
  /// the network cannot be reached.
  static Future<OsmImageryIndex?> _held(
    File file, {
    bool however = false,
  }) async {
    try {
      if (!file.existsSync()) return null;
      if (!however) {
        final age = DateTime.now().difference(await file.lastModified());
        if (age > osmImageryIndexFreshness) return null;
      }
      final index = await parse(await file.readAsString());
      return index.layers.isEmpty ? null : index;
    } on IOException {
      return null;
    } on FormatException {
      return null;
    }
  }

  static Future<void> _keep(File file, String json) async {
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(json);
    } on IOException {
      // Being unable to keep it costs a fetch next time, nothing more.
    }
  }
}
