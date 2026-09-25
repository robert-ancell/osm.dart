import 'dart:io';
import 'dart:isolate';

import 'cache.dart';
import 'cached_files.dart';
import 'country_coder.dart';
import 'update/http.dart';

/// country-coder's borders, kept on disk between runs.
class OsmCountryCoderCache {
  /// Where country-coder's borders are published.
  ///
  /// The major version is pinned, as for the tagging schema: a new one can
  /// change the shape of the file, and within one borders only get better.
  static const defaultUrl =
      'https://cdn.jsdelivr.net/gh/rapideditor/country-coder@5/src/data/';

  /// How long a copy of the borders on disk is used before asking for them
  /// again. Countries change rarely, but the codes and groups they are given
  /// are corrected now and then.
  static const freshness = Duration(days: 30);

  /// The directory under [OsmCache.defaultDirectory] it is kept in by default.
  static const name = 'country-coder';

  /// The file the borders are in.
  static const file = 'borders.json';

  /// Where the borders are kept.
  final Directory directory;

  /// How they are fetched.
  final OsmFetch fetch;

  /// Where they are fetched from, [OsmCountryCoderCache.defaultUrl] unless said
  /// otherwise.
  final Uri from;

  /// Creates a cache in [directory], by default [name] under
  /// [OsmCache.defaultDirectory].
  ///
  /// [contact] says who is asking, as OpenStreetMap's servers ask: a name
  /// and a way to reach whoever runs the program. [fetch] replaces fetching
  /// over HTTP altogether, for tests or a transport of the caller's own.
  OsmCountryCoderCache({
    Directory? directory,
    String? contact,
    OsmFetch? fetch,
    Uri? from,
  })  : directory = directory ?? OsmCache.defaultDirectory(name),
        fetch = fetch ?? httpFetch(contact: contact),
        from = from ?? Uri.parse(OsmCountryCoderCache.defaultUrl);

  /// The borders, from disk if a recent copy is held there and from the
  /// network otherwise.
  ///
  /// Never throws. An old copy is used when the network cannot be reached,
  /// and when there is no copy of any age and nothing could be fetched, the
  /// borders come back empty, [OsmCountryCoder.empty], knowing of no
  /// country anywhere.
  Future<OsmCountryCoder> read() async =>
      await readCachedFiles(
        directory: directory,
        files: const [file],
        from: from,
        fetch: fetch,
        freshness: OsmCountryCoderCache.freshness,
        parse: (files) =>
            Isolate.run(() => OsmCountryCoder.parse(files.single)),
        isEmpty: (countries) => countries.all.isEmpty,
      ) ??
      OsmCountryCoder.empty();
}

/// country-coder's borders, kept in an [OsmCache] alongside everything else.
extension OsmCacheCountryCoder on OsmCache {
  /// Where the borders are kept: [OsmCountryCoderCache.name] in the cache's
  /// directory.
  OsmCountryCoderCache get countryCoderCache =>
      _countryCoderCaches[this] ??= OsmCountryCoderCache(
        directory: directoryFor(OsmCountryCoderCache.name),
        fetch: fetch,
      );

  /// country-coder's borders, which say which country a place is in.
  ///
  /// Read the first time they are asked for and kept. Empty only when there
  /// is no copy on disk and none could be fetched, in which case the next
  /// ask tries again.
  Future<OsmCountryCoder> get countryCoder async {
    final held = _countryCoders[this];
    if (held != null) return held;
    final read = await countryCoderCache.read();
    if (read.all.isNotEmpty) _countryCoders[this] = read;
    return read;
  }
}

final _countryCoderCaches = Expando<OsmCountryCoderCache>();
final _countryCoders = Expando<OsmCountryCoder>();
