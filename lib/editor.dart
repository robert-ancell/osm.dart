/// Editing OpenStreetMap elements the way iD does: [OsmEditor], what it can
/// do to a selection, its history of changes, and iD's tagging schema, which
/// says what kind of thing each element is.
///
/// Use it with `package:osm/osm.dart`, which has the elements themselves and
/// the API a history of changes is uploaded to.
library;

export 'src/edit.dart';
export 'src/operations.dart'
    hide
        osmContinuable,
        osmCopy,
        osmHasInterestingTags,
        osmMove,
        osmPaste,
        osmReversedTags,
        osmReverseWay;
export 'src/presets.dart';
export 'src/presets_cache.dart';
export 'src/tag_text.dart';
export 'src/topology.dart' hide osmConnect, osmConnectDisabled;
