/// OpenStreetMap data: its elements, reading them from the API and uploading
/// changes to it, replication feeds, imagery and the caches that keep them.
///
/// The rest of the package is in libraries of their own, for what not every
/// program needs:
///
/// * `package:osm/editor.dart` — editing elements, and the tagging schema
///   that says what kind of thing each one is;
/// * `package:osm/country_coder.dart` — which country a place is in;
/// * `package:osm/pbf.dart` — reading, writing and updating `.osm.pbf`
///   files;
/// * `package:osm/xml.dart` — reading OSM XML and osmChange files.
///
/// ## Reading from the OpenStreetMap API
///
/// ```dart
/// final client = OsmApiClient(contact: 'Your Name <you@example.com>');
///
/// final elements = await client.map(const OsmBounds(
///   minLatitude: 48.853,
///   minLongitude: 2.348,
///   maxLatitude: 48.855,
///   maxLongitude: 2.351,
/// ));
/// ```
///
/// `map` gives everything in a box, as an editor wants it: the nodes inside it,
/// every way through any of them with the rest of its nodes wherever they are,
/// and the relations over any of it, so each box can be drawn on its own. The
/// API only answers for small boxes; a larger one throws
/// `OsmTooMuchDataException`, and `capabilities` says how large a box it will
/// take.
///
/// `nodes` looks nodes up by id, `waysUsing` finds the ways through a node,
/// `changesetsIn` lists what has been edited over an area since a moment, and
/// `changesetsBy` and `changesetChanges` follow one mapper's edits.
///
/// OpenStreetMap asks to be told who is calling it, so give a `contact` that
/// reaches whoever runs the program. No more than a couple of requests are made
/// at once, and a server asking to be left alone is: a reply of too many
/// requests holds every request back until the moment it names.
///
/// ## Areas
///
/// A closed way, or a relation whose member ways make up rings, covers ground.
/// An [OsmSubset]'s `areaOf` works out which, wound the way GeoJSON and most
/// triangulators want — here for a subset read from a file with
/// `package:osm/pbf.dart`:
///
/// ```dart
/// final area = parks.areaOf(park);
/// for (final polygon in area?.polygons ?? const <OsmPolygon>[]) {
///   draw(polygon.outer, holes: polygon.inners);
/// }
/// ```
///
/// Rings are worked out from the segments the ways are made of, not by
/// following one way at a time, so ways in any order or direction come out
/// right, rings sharing an edge merge, and a ring that touches itself is split
/// into the pieces it really encloses. Which rings are holes is decided by what
/// they enclose rather than by member roles, which real data gets wrong often
/// enough to matter.
///
/// All 81 of the multipolygon tests from
/// [osm-testdata](https://github.com/osmcode/osm-testdata) come out as
/// specified.
library;

export 'src/area.dart' hide assembleArea;
export 'src/bounds.dart';
export 'src/cache.dart';
export 'src/change.dart';
export 'src/data_cache.dart';
export 'src/editor_data.dart';
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
