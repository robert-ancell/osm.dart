import 'dart:io';
import 'dart:isolate';

import 'cache.dart';
import 'cached_files.dart';
import 'imagery.dart';
import 'update/http.dart';

/// The editor layer index, kept on disk between runs.
///
/// A megabyte of JSON describing every layer editors know about. It is parsed
/// away from the calling isolate, because a tool with an interface should not
/// be doing that where it draws.
class OsmImageryIndexCache {
  /// Where the editor layer index publishes itself.
  static const defaultUrl = 'https://osmlab.github.io/editor-layer-index/';

  /// How long a copy of the index is used before it is fetched again.
  ///
  /// Layers are added and withdrawn over weeks, not hours, and a tool that
  /// cannot reach the index is better off with last week's list than none.
  static const freshness = Duration(days: 7);

  /// The directory under [OsmCache.defaultDirectory] it is kept in by default.
  static const name = 'imagery-index';

  /// The file the index is in.
  static const file = 'imagery.geojson';

  /// Where the index is kept.
  final Directory directory;

  /// How it is fetched.
  final OsmFetch fetch;

  /// Where it is fetched from, [OsmImageryIndexCache.defaultUrl] unless said otherwise.
  final Uri from;

  /// Creates a cache in [directory], by default [name] under
  /// [OsmCache.defaultDirectory].
  ///
  /// [contact] says who is asking, as OpenStreetMap's servers ask: a name
  /// and a way to reach whoever runs the program. [fetch] replaces fetching
  /// over HTTP altogether, for tests or a transport of the caller's own.
  OsmImageryIndexCache({
    Directory? directory,
    String? contact,
    OsmFetch? fetch,
    Uri? from,
  })  : directory = directory ?? OsmCache.defaultDirectory(name),
        fetch = fetch ?? httpFetch(contact: contact),
        from = from ?? Uri.parse(OsmImageryIndexCache.defaultUrl);

  /// The index, from disk if a recent copy is held there and from the
  /// network otherwise.
  ///
  /// Never throws: an index that cannot be had at all comes back holding
  /// [fallback], which may be empty. An old copy is used when the network
  /// cannot be reached, because an old list beats no list.
  Future<OsmImageryIndex> read({
    List<OsmImagery> fallback = const [],
  }) async =>
      await readCachedFiles(
        directory: directory,
        files: const [file],
        from: from,
        fetch: fetch,
        freshness: OsmImageryIndexCache.freshness,
        parse: (files) => parse(files.single),
        isEmpty: (index) => index.layers.isEmpty,
      ) ??
      OsmImageryIndex(fallback);

  /// Parses an index away from the calling isolate.
  static Future<OsmImageryIndex> parse(String json) =>
      Isolate.run(() => OsmImageryIndex.parse(json));
}
