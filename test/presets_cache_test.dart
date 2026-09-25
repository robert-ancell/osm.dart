import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:osm/editor.dart';
import 'package:osm/osm.dart';
import 'package:test/test.dart';

/// The schema as a server would hand it out, a file at a time.
final _served = <String, String>{
  'presets.min.json': jsonEncode({
    'amenity/cafe': {
      'tags': {'amenity': 'cafe'},
      'geometry': ['point'],
    },
  }),
  'preset_categories.min.json': '{}',
  'preset_defaults.min.json': '{}',
  'translations/en.min.json': jsonEncode({
    'en': {
      'presets': {
        'presets': {
          'amenity/cafe': {'name': 'Cafe'},
        },
      },
    },
  }),
};

void main() {
  late Directory directory;
  late List<Uri> asked;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('presets');
    asked = [];
  });
  tearDown(() => directory.deleteSync(recursive: true));

  /// A server holding [files], or refusing everything if it is null.
  OsmFetch server(Map<String, String>? files) =>
      (uri, {abandon, onLate}) async {
        asked.add(uri);
        if (files == null) throw const SocketException('offline');
        final name = uri.path.split('/dist/').last;
        final body = files[name];
        return body == null ? null : Uint8List.fromList(utf8.encode(body));
      };

  Future<OsmPresets> read(Map<String, String>? files) =>
      OsmPresetsCache(directory: directory, fetch: server(files)).read();

  test('fetches the schema and keeps it', () async {
    final presets = await read(_served);
    expect(presets.byId['amenity/cafe']!.name, 'Cafe');
    expect(asked, hasLength(4));
    expect(asked.first.toString(), startsWith(OsmPresetsCache.defaultUrl));
    for (final file in OsmPresetsCache.filesFor('en')) {
      expect(File('${directory.path}/$file').existsSync(), isTrue,
          reason: file);
    }
  });

  test('uses a recent copy without asking again', () async {
    await read(_served);
    asked.clear();
    expect((await read(_served)).byId, contains('amenity/cafe'));
    expect(asked, isEmpty);
  });

  test('asks again once the copy is old', () async {
    await read(_served);
    final old = DateTime.now().subtract(
      OsmPresetsCache.freshness + const Duration(days: 1),
    );
    File('${directory.path}/presets.min.json').setLastModifiedSync(old);
    asked.clear();
    await read(_served);
    expect(asked, hasLength(4));
  });

  test('uses an old copy when the network cannot be reached', () async {
    await read(_served);
    final old = DateTime.now().subtract(
      OsmPresetsCache.freshness + const Duration(days: 1),
    );
    File('${directory.path}/presets.min.json').setLastModifiedSync(old);
    expect((await read(null)).byId, contains('amenity/cafe'));
  });

  test('has nothing when there is no copy and no network', () async {
    expect((await read(null)).byId, isEmpty);
  });

  test('keeps nothing when a file is missing', () async {
    // Part of one version is not a schema, and would be kept as one.
    final partial = {..._served}..remove('preset_defaults.min.json');
    expect((await read(partial)).byId, isEmpty);
    expect(directory.listSync(), isEmpty);
  });

  test('keeps nothing that is not the schema', () async {
    final page = {
      for (final name in _served.keys) name: '<html>Log in</html>',
    };
    expect((await read(page)).byId, isEmpty);
    expect(directory.listSync(), isEmpty);
  });
}
