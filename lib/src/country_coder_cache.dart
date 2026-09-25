import 'dart:io';
import 'dart:isolate';

import 'cache.dart';
import 'cached_files.dart';
import 'country_coder.dart';
import 'update/http.dart';

/// Where country-coder's borders are published.
///
/// The major version is pinned, as for iD's tagging schema: a new one can
/// change the shape of the file, and within one borders only get better.
const osmCountryCoderUrl =
    'https://cdn.jsdelivr.net/gh/rapideditor/country-coder@5/src/data/';

/// How long a copy of the borders on disk is used before asking for them
/// again. Countries change rarely, but the codes and groups they are given
/// are corrected now and then.
const osmCountryCoderFreshness = Duration(days: 30);

/// country-coder's borders, kept on disk between runs.
class OsmCountryCoderCache {
  /// The directory under [osmCacheDirectory] it is kept in by default.
  static const name = 'country-coder';

  /// The file the borders are in.
  static const file = 'borders.json';

  /// Where the borders are kept.
  final Directory directory;

  /// How they are fetched.
  final OsmFetch fetch;

  /// Where they are fetched from, [osmCountryCoderUrl] unless said
  /// otherwise.
  final Uri from;

  /// Creates a cache in [directory], by default [name] under
  /// [osmCacheDirectory].
  ///
  /// [contact] says who is asking, as OpenStreetMap's servers ask: a name
  /// and a way to reach whoever runs the program. [fetch] replaces fetching
  /// over HTTP altogether, for tests or a transport of the caller's own.
  OsmCountryCoderCache({
    Directory? directory,
    String? contact,
    OsmFetch? fetch,
    Uri? from,
  })  : directory = directory ?? osmCacheDirectory(name),
        fetch = fetch ?? httpFetch(contact: contact),
        from = from ?? Uri.parse(osmCountryCoderUrl);

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
        freshness: osmCountryCoderFreshness,
        parse: (files) =>
            Isolate.run(() => OsmCountryCoder.parse(files.single)),
        isEmpty: (countries) => countries.all.isEmpty,
      ) ??
      OsmCountryCoder.empty();
}
