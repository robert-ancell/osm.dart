import 'dart:io';

import 'package:osm/osm.dart';
import 'package:test/test.dart';

void main() {
  test('the version the package states is the one its pubspec gives', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final version = RegExp(
      r'^version:\s*(\S+)\s*$',
      multiLine: true,
    ).firstMatch(pubspec);

    expect(version, isNotNull, reason: 'pubspec.yaml has no version');
    expect(
      version!.group(1),
      packageVersion,
      reason: 'lib/src/version.dart has to be bumped with the pubspec',
    );
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
