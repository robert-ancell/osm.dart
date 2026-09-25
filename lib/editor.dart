/// Editing OpenStreetMap elements: [OsmEditor], what it can do to a
/// selection, its history of changes, the rules it follows for tags, and the
/// tagging schema, which says what kind of thing each element is.
///
/// Use it with `package:osm/osm.dart`, which has the elements themselves and
/// the API a history of changes is uploaded to.
///
/// ## Editing and uploading changes
///
/// ```dart
/// import 'package:osm/editor.dart';
/// import 'package:osm/osm.dart';
///
/// final editor = OsmEditor(
///   OsmElementSource.of(elements),
///   rules: OsmStandardTagRules(),
/// );
///
/// final cafe = editor.node(4061287113)!;
/// editor.setTags(cafe, {...cafe.tags, 'opening_hours': 'Mo-Fr 07:00-15:00'});
///
/// final signedIn =
///     await OsmAuthenticator(clientId: 'your-client-id').tokenFromBrowser();
/// client.token = signedIn.accessToken;
/// print('Signed in as ${await client.displayName()}');
///
/// final changeset = await client.upload(
///   editor.history.toUpload(),
///   comment: 'Add opening hours',
/// );
/// print('Uploaded as changeset $changeset');
/// ```
///
/// An `OsmEditor` lays every change over the data it was given, which it never
/// touches, and keeps them in its history, from which an upload is made. Each
/// change can be undone and redone. As well as creating, moving, retagging and
/// deleting single elements, it offers what can be done to a selection —
/// delete, reverse, extract, split, merge, disconnect, move, copy and paste —
/// each saying first whether it applies and, if it cannot be done, why.
///
/// The editor knows nothing about tags itself. What they mean — whether a
/// closed way is an area, what turns round when a way is reversed, which tags
/// go where when ways are split and joined — it asks an `OsmTagRules`.
/// `OsmStandardTagRules` follows the conventions OpenStreetMap's editors
/// commonly share, using the tagging schema once it has been read;
/// `OsmPlainTagRules`, the default, knows as little as it can; and a tool with
/// its own conventions implements `OsmTagRules` itself.
///
/// `OsmTagText` shows the tags of one element or several as editable
/// `key=value` text, and applies an edit of it to each.
///
/// `OsmAuthenticator` signs in through the browser with OAuth 2, for an
/// application registered on openstreetmap.org with a redirect URI of
/// `http://127.0.0.1:8642/`; its documentation says what to register.
/// `OsmUpload` can say what is about to be sent, a line to an element, before
/// the client's `upload` opens a changeset, sends the lot and closes it again.
/// Give the client a `createdBy` to name your program in the changesets it
/// makes.
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
