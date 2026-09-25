import 'dart:io';
import 'dart:isolate';

import 'cache.dart';
import 'cached_files.dart';
import 'presets.dart';
import 'update/http.dart';

/// The tagging schema, kept on disk between runs.
class OsmPresetsCache {
  /// Where the tagging schema is published.
  ///
  /// The major version is pinned: a new one can change the shape of the files,
  /// and within one they only gain presets and lose mistakes.
  static const defaultUrl =
      'https://cdn.jsdelivr.net/npm/@openstreetmap/id-tagging-schema@6/dist/';

  /// How long a copy of the schema on disk is used before asking for it again.
  ///
  /// A week, as for the imagery index: presets change a few times a month, and
  /// a week old list names things perfectly well.
  static const freshness = Duration(days: 7);

  /// The directory under [OsmCache.defaultDirectory] it is kept in by default.
  static const name = 'presets';

  /// Where the schema is kept.
  final Directory directory;

  /// How it is fetched.
  final OsmFetch fetch;

  /// Where it is fetched from, [OsmPresetsCache.defaultUrl] unless said
  /// otherwise.
  final Uri from;

  /// Creates a cache in [directory], by default [name] under
  /// [OsmCache.defaultDirectory].
  ///
  /// [contact] says who is asking, as OpenStreetMap's servers ask: a name
  /// and a way to reach whoever runs the program. [fetch] replaces fetching
  /// over HTTP altogether, for tests or a transport of the caller's own.
  OsmPresetsCache({
    Directory? directory,
    String? contact,
    OsmFetch? fetch,
    Uri? from,
  })  : directory = directory ?? OsmCache.defaultDirectory(name),
        fetch = fetch ?? httpFetch(contact: contact),
        from = from ?? Uri.parse(OsmPresetsCache.defaultUrl);

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
        freshness: OsmPresetsCache.freshness,
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
