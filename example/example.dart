import 'dart:io';

import 'package:osm/osm.dart';

/// Counts the elements of a PBF file, and lists the golf courses in it.
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

  final counts = <OsmElementType, int>{};
  await for (final element in file.elements()) {
    counts[element.type] = (counts[element.type] ?? 0) + 1;
    if (element.tags['leisure'] == 'golf_course') {
      print('${element.type.name} ${element.id}: ${element.tags['name']}');
    }
  }

  for (final type in OsmElementType.values) {
    print('${counts[type] ?? 0} ${type.name}s');
  }
}
