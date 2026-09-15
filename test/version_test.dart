import 'dart:io';

import 'package:osm/osm.dart';
import 'package:test/test.dart';

import '../tool/update_version.dart';

void main() {
  test('the generated version is the one the pubspec gives', () {
    final version = readVersion(File('pubspec.yaml').readAsStringSync());
    expect(version, isNotNull, reason: 'pubspec.yaml has no version');
    expect(
      File('lib/src/version.dart').readAsStringSync(),
      source(version!),
      reason: 'Run: dart run tool/update_version.dart',
    );
    expect(packageVersion, version);
  });

  test('reads the version however the pubspec writes it', () {
    expect(readVersion('name: osm\nversion: 1.2.3\n'), '1.2.3');
    expect(readVersion("version: '1.2.3'\n"), '1.2.3');
    expect(readVersion('version: "1.2.3"\n'), '1.2.3');
    expect(readVersion('version: 1.2.3-dev.4+5\n'), '1.2.3-dev.4+5');
    expect(readVersion('version: 1.2.3  # the one\n'), '1.2.3');
    // Not a version at the top level of the document.
    expect(readVersion('dependencies:\n  foo:\n    version: 1.2.3\n'), isNull);
    expect(readVersion('name: osm\n'), isNull);
  });

  test('a file written says which version of what wrote it', () async {
    final work = Directory.systemTemp.createTempSync('osm_version');
    addTearDown(() => work.deleteSync(recursive: true));

    final path = '${work.path}/out.osm.pbf';
    await (await OsmPbfWriter.create(path)).close();

    expect(
      (await OsmPbfFile.open(path)).header.writingProgram,
      'osm/$packageVersion',
    );
  });
}
