import 'dart:async';
import 'dart:typed_data';

import 'imagery.dart';
import 'imagery_cache.dart';
import 'tile.dart';
import 'update/http.dart';

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

  /// Creates a fetcher making no more than [concurrency] requests at once.
  ///
  /// More at once than for the API, since imagery servers are built to hand
  /// out many small tiles quickly.
  ///
  /// [contact] says who is asking, as OpenStreetMap's servers ask: a name
  /// and a way to reach whoever runs the program. [fetch] replaces fetching
  /// over HTTP altogether, for tests or a transport of the caller's own.
  OsmImageryTiles({
    required this.source,
    String? contact,
    int concurrency = 6,
    OsmFetch? fetch,
    this.cache,
  }) : fetch = fetch ?? httpFetch(contact: contact, concurrency: concurrency);

  /// Whether the source is known to have nothing for [tile], so that asking
  /// would be wasted.
  bool isEmptyAt(OsmTile tile) => cache?.entry(tile)?.missing ?? false;

  /// Whether what is held for [tile] is old enough to be worth fetching
  /// again, which a caller holding a decoded copy has no other way to tell.
  bool isStaleAt(OsmTile tile) => cache?.entry(tile)?.isStale ?? false;

  /// The tile as the server sends it, or null where the source has nothing.
  ///
  /// A tile already held and still within [OsmImageryCache.freshness] is given back
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
      Uri.parse(source.tileUrl(tile)),
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
