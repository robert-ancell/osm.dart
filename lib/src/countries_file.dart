import 'dart:io';
import 'dart:isolate';

import 'cached_files.dart';
import 'countries.dart';
import 'update/http.dart';

/// Where country-coder's borders are published.
///
/// The major version is pinned, as for iD's tagging schema: a new one can
/// change the shape of the file, and within one borders only get better.
const osmCountriesUrl =
    'https://cdn.jsdelivr.net/gh/rapideditor/country-coder@5/src/data/';

/// How long a copy of the borders on disk is used before asking for them
/// again. Countries change rarely, but the codes and groups they are given
/// are corrected now and then.
const osmCountriesFreshness = Duration(days: 30);

/// country-coder's borders, kept on disk between runs.
abstract final class OsmCountriesFile {
  /// The file the borders are in.
  static const file = 'borders.json';

  /// The borders, from [directory] if a recent copy is held there and from
  /// the network otherwise.
  ///
  /// Never throws. An old copy is used when the network cannot be reached,
  /// and null comes back only when there is no copy of any age and nothing
  /// could be fetched.
  static Future<OsmCountries?> read({
    required Directory directory,
    required OsmFetch fetch,
    Uri? from,
  }) =>
      readCachedFiles(
        directory: directory,
        files: const [file],
        from: from ?? Uri.parse(osmCountriesUrl),
        fetch: fetch,
        freshness: osmCountriesFreshness,
        parse: (files) => Isolate.run(() => OsmCountries.parse(files.single)),
        isEmpty: (countries) => countries.all.isEmpty,
      );
}
