import 'dart:io';

import 'package:osm/osm.dart';

/// Lists the parks in a PBF file.
///
/// ```
/// dart run example/example.dart extract.osm.pbf
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
  final parks = file.elements(
    filter: const OsmFilter.tag('leisure', 'park'),
  );
  await for (final park in parks) {
    print('${park.type.name} ${park.id}: ${park.tags['name']}');
  }
}
