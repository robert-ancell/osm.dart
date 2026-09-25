/// Reading OpenStreetMap's XML: `.osm` files and what the API answers with,
/// and osmChange (`.osc`) files such as replication diffs.
///
/// Use it with `package:osm/osm.dart`, which has the elements and changes
/// these files hold.
///
/// ## Reading a change file
///
/// ```dart
/// import 'package:osm/xml.dart';
///
/// for (final change in await OsmChangeFile.read('523.osc.gz')) {
///   switch (change.action) {
///     case OsmChangeAction.create || OsmChangeAction.modify:
///       put(change.element!);
///     case OsmChangeAction.delete:
///       forget(change.type, change.id);
///   }
/// }
/// ```
///
/// OsmChange (`.osc`) files are what OpenStreetMap publishes its edits as,
/// gzipped or not. A deletion names the element without always describing it,
/// so `element` is null where the file gave too little to build one and the
/// type, id and version are there either way.
library;

export 'src/xml/change.dart';
export 'src/xml/exception.dart';
export 'src/xml/osm_xml.dart';
