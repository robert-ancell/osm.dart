import 'dart:io';

import 'package:osm/osm.dart';

/// Lists the golf courses in a PBF file.
///
/// ```
/// dart run example/example.dart new-zealand-latest.osm.pbf
/// ```
Future<void> main(List<String> arguments) async {
  if (arguments.length != 1) {
    stderr.writeln('Usage: example.dart <file.osm.pbf>');
    exitCode = 2;
    return;
  }

  final file = await OsmPbfFile.open(arguments.single);
  print('Written by ${file.header.writingProgram ?? 'an unknown program'}');

  // Asking for the tag, rather than reading everything and checking as it goes
  // by, is what makes this take a second or two rather than half a minute.
  final courses = file.elements(
    filter: const OsmFilter.tag('leisure', 'golf_course'),
  );
  await for (final course in courses) {
    print('${course.type.name} ${course.id}: ${course.tags['name']}');
  }
}
