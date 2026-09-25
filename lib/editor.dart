/// Editing OpenStreetMap elements: [OsmEditor], what it can do to a
/// selection, its history of changes, the rules it follows for tags, and the
/// tagging schema, which says what kind of thing each element is.
///
/// Use it with `package:osm/osm.dart`, which has the elements themselves and
/// the API a history of changes is uploaded to.
library;

export 'src/edit.dart';
export 'src/operations.dart'
    hide osmContinuable, osmCopy, osmMove, osmPaste, osmReverseWay;
export 'src/presets.dart';
export 'src/presets_cache.dart';
export 'src/standard_tag_rules.dart';
export 'src/tag_rules.dart';
export 'src/tag_text.dart';
export 'src/topology.dart' hide osmConnect, osmConnectDisabled;
