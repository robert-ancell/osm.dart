/// Reading, writing and updating OpenStreetMap `.osm.pbf` files.
///
/// Use it with `package:osm/osm.dart`, which has the elements a file holds,
/// the change files that update one and the replication feeds they come
/// from.
library;

export 'src/filter.dart';
export 'src/pbf/exception.dart';
export 'src/pbf/file.dart';
export 'src/pbf/header.dart';
export 'src/pbf/transformer.dart';
export 'src/pbf/writer.dart';
export 'src/region.dart';
export 'src/update/change_filter.dart' show OsmUpdateEdges;
export 'src/update/updater.dart';
