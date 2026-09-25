import 'dart:convert';
import 'dart:io';

import '../element.dart';
import 'elements.dart';

/// OSM's own XML: an `.osm` file, or what the editing API answers with.
abstract final class OsmXmlFile {
  /// Reads the elements of the file at [path].
  static Future<List<OsmElement>> read(String path) async => parse(
        utf8.decode(
          await File(path).readAsBytes(),
          allowMalformed: true,
        ),
      );

  /// Reads the elements of [xml].
  ///
  /// An element the XML says is not visible is one the API still answers for
  /// after it was deleted, and is left out. So is a node with no location,
  /// which is the same thing said another way.
  static List<OsmElement> parse(String xml) {
    final elements = <OsmElement>[];
    readOsmXmlElements(xml, (read) {
      final element = read.element;
      if (read.visible && element != null) elements.add(element);
    });
    return elements;
  }
}
