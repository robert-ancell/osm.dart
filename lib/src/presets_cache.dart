import 'dart:io';
import 'dart:isolate';

import 'cache.dart';
import 'cached_files.dart';
import 'presets.dart';
import 'update/http.dart';

/// Where iD's tagging schema is published.
///
/// The major version is pinned: a new one can change the shape of the files,
/// and within one they only gain presets and lose mistakes. It is where iD
/// itself loads the schema from.
const osmPresetsUrl =
    'https://cdn.jsdelivr.net/npm/@openstreetmap/id-tagging-schema@6/dist/';

/// How long a copy of the schema on disk is used before asking for it again.
///
/// A week, as for the imagery index: presets change a few times a month, and
/// a week old list names things perfectly well.
const osmPresetsFreshness = Duration(days: 7);

/// iD's tagging schema, kept on disk between runs.
class OsmPresetsCache {
  /// The directory under [osmCacheDirectory] it is kept in by default.
  static const name = 'presets';

  /// Where the schema is kept.
  final Directory directory;

  /// How it is fetched.
  final OsmFetch fetch;

  /// Where it is fetched from, [osmPresetsUrl] unless said otherwise.
  final Uri from;

  /// Creates a cache in [directory], by default [name] under
  /// [osmCacheDirectory].
  OsmPresetsCache({Directory? directory, required this.fetch, Uri? from})
      : directory = directory ?? osmCacheDirectory(name),
        from = from ?? Uri.parse(osmPresetsUrl);

  /// The files that make up the schema, for [language]. All four are asked
  /// for and kept together, so that a copy on disk is always one version of
  /// the schema rather than parts of several.
  static List<String> filesFor(String language) => [
        'presets.min.json',
        'preset_categories.min.json',
        'preset_defaults.min.json',
        'translations/$language.min.json',
      ];

  /// The schema in [language], from disk if a recent copy is held there and
  /// from the network otherwise.
  ///
  /// Never throws. An old copy is used when the network cannot be reached,
  /// because old names beat none, and when there is no copy of any age and
  /// nothing could be fetched, the schema comes back empty,
  /// [OsmPresets.empty].
  Future<OsmPresets> read({String language = 'en'}) async =>
      await readCachedFiles(
        directory: directory,
        files: filesFor(language),
        from: from,
        fetch: fetch,
        freshness: osmPresetsFreshness,
        parse: (files) => Isolate.run(
          () => OsmPresets.parse(
            presets: files[0],
            categories: files[1],
            defaults: files[2],
            translations: files[3],
          ),
        ),
        isEmpty: (presets) => presets.byId.isEmpty,
      ) ??
      OsmPresets.empty();
}
