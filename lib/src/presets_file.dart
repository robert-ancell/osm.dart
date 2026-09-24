import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

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
abstract final class OsmPresetsFile {
  /// The files that make up the schema, for [language]. All four are asked
  /// for and kept together, so that a copy on disk is always one version of
  /// the schema rather than parts of several.
  static List<String> filesFor(String language) => [
        'presets.min.json',
        'preset_categories.min.json',
        'preset_defaults.min.json',
        'translations/$language.min.json',
      ];

  /// The schema in [language], from [directory] if a recent copy is held
  /// there and from the network otherwise.
  ///
  /// Never throws. An old copy is used when the network cannot be reached,
  /// because old names beat none, and null comes back only when there is no
  /// copy of any age and nothing could be fetched.
  static Future<OsmPresets?> read({
    required Directory directory,
    required OsmFetch fetch,
    String language = 'en',
    Uri? from,
  }) async {
    final files = filesFor(language);
    final held = await _held(directory, files);
    if (held != null) return held;

    try {
      final base = from ?? Uri.parse(osmPresetsUrl);
      final fetched = <String>[];
      for (final file in files) {
        final body = await fetch(base.resolve(file));
        if (body == null) throw const FormatException('missing');
        fetched.add(utf8.decode(body));
      }
      final presets = await _parse(fetched);
      if (presets.byId.isNotEmpty) {
        await _keep(directory, files, fetched);
        return presets;
      }
    } on IOException {
      // No network, or the schema has moved.
    } on FormatException {
      // A file missing, or something that is not the schema at all.
    }

    return _held(directory, files, however: true);
  }

  static Future<OsmPresets> _parse(List<String> files) => Isolate.run(
        () => OsmPresets.parse(
          presets: files[0],
          categories: files[1],
          defaults: files[2],
          translations: files[3],
        ),
      );

  /// The copy on disk, or null if there is none worth using.
  ///
  /// Set [however] to take one whatever its age, which is what happens when
  /// the network cannot be reached.
  static Future<OsmPresets?> _held(
    Directory directory,
    List<String> files, {
    bool however = false,
  }) async {
    try {
      final held = [for (final file in files) File('${directory.path}/$file')];
      if (!held.every((file) => file.existsSync())) return null;
      if (!however) {
        final age = DateTime.now().difference(await held.first.lastModified());
        if (age > osmPresetsFreshness) return null;
      }
      final presets = await _parse([
        for (final file in held) await file.readAsString(),
      ]);
      return presets.byId.isEmpty ? null : presets;
    } on IOException {
      return null;
    } on FormatException {
      return null;
    }
  }

  /// Keeps a set of files, the presets last: they are what says how old the
  /// copy is, so they are only written once everything else is there.
  static Future<void> _keep(
    Directory directory,
    List<String> files,
    List<String> bodies,
  ) async {
    try {
      for (var i = files.length - 1; i >= 0; i--) {
        final file = File('${directory.path}/${files[i]}');
        await file.parent.create(recursive: true);
        await file.writeAsString(bodies[i]);
      }
    } on IOException {
      // Being unable to keep it costs a fetch next time, nothing more.
    }
  }
}
