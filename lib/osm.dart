/// OpenStreetMap data: its elements, reading them from the API and uploading
/// changes to it, replication feeds, imagery and the caches that keep them.
///
/// The rest of the package is in libraries of their own, for what not every
/// program needs:
///
/// * `package:osm/editor.dart` — editing elements the way iD does, and the
///   tagging schema it works by;
/// * `package:osm/country_coder.dart` — which country a place is in;
/// * `package:osm/pbf.dart` — reading, writing and updating `.osm.pbf`
///   files;
/// * `package:osm/xml.dart` — reading OSM XML and osmChange files.
library;

export 'src/area.dart' hide assembleArea;
export 'src/bounds.dart';
export 'src/cache.dart';
export 'src/change.dart';
export 'src/data_cache.dart';
export 'src/element.dart';
export 'src/exception.dart';
export 'src/imagery.dart';
export 'src/imagery_cache.dart';
export 'src/imagery_index_cache.dart';
export 'src/imagery_tiles.dart';
export 'src/json_exception.dart';
export 'src/mercator.dart';
export 'src/subset.dart';
export 'src/tile.dart';
export 'src/update/api.dart';
export 'src/update/auth.dart';
export 'src/update/http.dart' hide httpFetch;
export 'src/update/replication.dart';
export 'src/update/upload.dart' hide changesetTagXml;
export 'src/version.g.dart';
