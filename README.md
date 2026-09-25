# osm

Read and process OpenStreetMap data in Dart, with no native dependencies.

It comes as several libraries, so a program imports only what it uses:

* `package:osm/osm.dart` — elements, the OpenStreetMap API and uploading to
  it, replication feeds, imagery and caches;
* `package:osm/editor.dart` — editing the way iD does, and iD's tagging
  schema;
* `package:osm/country_coder.dart` — which country a place is in;
* `package:osm/pbf.dart` — reading, writing and updating `.osm.pbf` files;
* `package:osm/xml.dart` — reading OSM XML and osmChange files.

## Reading a PBF file

```dart
import 'package:osm/osm.dart';
import 'package:osm/pbf.dart';

final file = await OsmPbfFile.open('extract.osm.pbf');

await for (final element in file.elements()) {
  print('${element.type.name} ${element.id}');
}
```

Elements are decoded a block at a time as they are asked for, so a file much
larger than memory can be processed by streaming through it. Each one is an
[OsmNode], [OsmWay] or [OsmRelation], with its tags and, if the file carries
metadata, the version, timestamp, changeset and user of the edit that made it.

## Reading from the OpenStreetMap API

```dart
final client = OsmApiClient(contact: 'Your Name <you@example.com>');

final elements = await client.map(const OsmBounds(
  minLatitude: 48.853,
  minLongitude: 2.348,
  maxLatitude: 48.855,
  maxLongitude: 2.351,
));
```

`map` gives everything in a box, as an editor wants it: the nodes inside it,
every way through any of them with the rest of its nodes wherever they are,
and the relations over any of it, so each box can be drawn on its own. The API
only answers for small boxes; a larger one throws `OsmTooMuchDataException`,
and `capabilities` says how large a box it will take.

`nodes` and `waysOf` look elements up by id, `changesetsIn` lists what has been
edited over an area since a moment, and `changesetsBy` and `changesetChanges`
follow one mapper's edits.

OpenStreetMap asks to be told who is calling it, so give a `contact` that
reaches whoever runs the program. No more than a couple of requests are made at
once, and a server asking to be left alone is: a reply of too many requests
holds every request back until the moment it names.

## Editing and uploading changes

```dart
import 'package:osm/editor.dart';
import 'package:osm/osm.dart';

final editor = OsmEditor(OsmEditorData.of(elements));

final cafe = editor.node(4061287113)!;
editor.setTags(cafe, {...cafe.tags, 'opening_hours': 'Mo-Fr 07:00-15:00'});

final signedIn =
    await OsmAuthenticator(clientId: 'your-client-id').tokenFromBrowser();
client.token = signedIn.accessToken;
print('Signed in as ${await client.displayName()}');

final changeset = await client.upload(
  OsmUpload.of(editor.history),
  comment: 'Add opening hours',
);
print('Uploaded as changeset $changeset');
```

An `OsmEditor` lays every change over the data it was given, which it never
touches, and keeps them in its history, from which an upload is made. Each
change can be undone and redone. As well as creating, moving, retagging and
deleting single elements, it offers what iD does to a selection — delete,
reverse, extract, split, merge, disconnect, move, copy and paste — by iD's
rules, each saying first whether it applies and, if it cannot be done, why.
`OsmTagText` shows the tags of one element or several as editable
`key=value` text, as iD's text view does, and applies an edit of it to each.

`OsmAuthenticator` signs in through the browser with OAuth 2, for an application
registered on openstreetmap.org with a redirect URI of
`http://127.0.0.1:8642/`; its documentation says what to register. `OsmUpload`
can say what is about to be sent, a line to an element, before the client's
`upload` opens a changeset, sends the lot and closes it again. Give the client
a `createdBy` to name your program in the changesets it makes.

## Taking part of a file

Say what you want with an [OsmFilter] rather than filtering the stream
afterwards:

```dart
final parks = file.elements(
  filter: const OsmFilter.tag('leisure', 'park'),
);
```

The filter is used to skip work rather than to throw away its results. A block
whose string table does not hold the key is dropped without looking at a single
element, elements of a type that cannot match are never decoded, and an element
without the key is never built into an object. What is left is decoded across
every core.

Finding the few hundred elements with a tag in a 434 MB country extract takes
1.7s, against 25s to read the same file end to end. Filters combine with `&`, `|` and
[OsmFilter.not], and [OsmFilter.where] takes a test written as code for
anything they cannot say.

## Building geometry

A way names its nodes by id, so matching it is only half of what it takes to
draw it. `subset` reads the matches and everything they refer to:

```dart
final parks = await file.subset(
  const OsmFilter.tag('leisure', 'park'),
);

for (final park in parks.matches) {
  if (park is! OsmWay) continue;
  final outline = parks.nodesOf(park);
  if (outline == null) continue; // Runs off the edge of the file.
  print('${park.tags['name']}: ${outline.length} points');
}
```

It holds the matches made complete: the nodes of matching ways, the members of
matching relations, and so on down. Pulling a few hundred areas and their
17,690 nodes out of a 434 MB country extract takes 7.4s.

Everything read is held in memory, so filter to what is wanted. `elements()`
is there for reads too big to keep.

## Areas

A closed way, or a relation whose member ways make up rings, covers ground.
`areaOf` works out which, wound the way GeoJSON and most triangulators want:

```dart
final area = parks.areaOf(park);
for (final polygon in area?.polygons ?? const <OsmPolygon>[]) {
  draw(polygon.outer, holes: polygon.inners);
}
```

Rings are worked out from the segments the ways are made of, not by following
one way at a time, so ways in any order or direction come out right, rings
sharing an edge merge, and a ring that touches itself is split into the pieces
it really encloses. Which rings are holes is decided by what they enclose
rather than by member roles, which real data gets wrong often enough to matter.

All 81 of the multipolygon tests from
[osm-testdata](https://github.com/osmcode/osm-testdata) come out as specified.

## Reading an area

```dart
final inside = await file.within([
  const OsmBounds(
    minLatitude: 48.85,
    minLongitude: 2.33,
    maxLatitude: 48.87,
    maxLongitude: 2.36,
  ),
]);
```

The nodes standing in the boxes, the ways using any of them along with the
rest of their nodes wherever those are, and the relations with any of those as
a member. What a kept relation refers to is not read: a relation is kept
because it has something here, not because it belongs here, and reading the
rest of a bus route that happens to pass by would pull in the country around
it.

## Reading a change file

```dart
import 'package:osm/xml.dart';

for (final change in await OsmChangeFile.read('523.osc.gz')) {
  switch (change.action) {
    case OsmChangeAction.create || OsmChangeAction.modify:
      put(change.element!);
    case OsmChangeAction.delete:
      forget(change.type, change.id);
  }
}
```

OsmChange (`.osc`) files are what OpenStreetMap publishes its edits as, gzipped
or not. A deletion names the element without always describing it, so `element`
is null where the file gave too little to build one and the type, id and
version are there either way.

## Writing a file

```dart
final writer = await OsmPbfWriter.create('out.osm.pbf', header: file.header);
await writer.addAll(file.elements().where(wanted));
await writer.close();
```

Elements are gathered into blocks and written as they fill, so a file larger
than memory can be written by streaming through it. Hand the header of what
you read back to keep what the file says about itself — the replication state
above all, which an extract that loses can never be brought up to date again.

A header declaring `Sort.Type_then_ID` is taken as a promise and checked, so a
file cannot quietly come out claiming an order its elements do not have.

## Applying changes

```dart
final transformer = OsmPbfTransformer(
    [for (final path in diffs) ...await OsmChangeFile.read(path)]);
final counts = await transformer.transform(
  input: 'extract.osm.pbf',
  output: 'updated.osm.pbf',
  header: file.header.copyWith(replicationSequenceNumber: 4906),
);
```

Changes are taken in the order given, so hand the diffs over in the order
OpenStreetMap published them. Move the replication state on in the header,
because a file that loses it can never be brought up to date again.

## Keeping a snapshot up to date

```
dart run osm:osm_update extract.osm.pbf --contact "Your Name <you@example.com>"
```

Reads the planet's replication diffs published since the snapshot's own
timestamp — hours, then minutes — keeps the changes that touch what the
snapshot holds, and writes it back with them applied. The rest of the planet's
edits are dropped as they are read, so it works from the planet's own feed
rather than waiting on a regional one.

What the snapshot holds is decided by the nodes in it, so the region is its
shape rather than its bounding box, and a country across the antimeridian is
no trouble. A way reaching past the edge, or a node moved in from outside, is
looked up through the OpenStreetMap API; with `--no-lookups` it is listed
instead, and the tool exits with 2 to say a fresh snapshot is due.

The same thing from code is `OsmPbfUpdater`.

### From an extract's own diffs

Geofabrik publishes a diff a day for each of its extracts, made by comparing
one day's extract with the next. For a country that is a few hundred kilobytes
a day rather than the planet's gigabytes, and nothing in it needs deciding: it
already holds what entered or left the extract.

```dart
final feed = OsmReplication.geofabrik('europe/monaco',
    contact: 'Your Name <you@example.com>');
const day = OsmReplicationPeriod.day;
final first = await feed.firstAfter(day, file.header.replicationTimestamp!);
final latest = await feed.latest(day);
final changes = [
  for (var s = first; s <= latest.sequence; s++)
    ...await OsmChangeFile.read((await feed.download(day, s, cache)).path),
];
```

and then `OsmPbfTransformer` as above. A block of the file no change falls in is
copied as it is, so a day of a country's changes is seconds rather than the
whole file written again.

A day is a long time to wait for an edit of your own. `OsmApiClient` lists a
mapper's changesets since a moment and gives back what each one changed, a few
kilobytes apiece, to apply the same way:

```dart
final client = OsmApiClient(contact: 'Your Name <you@example.com>');
final since = file.header.replicationTimestamp!;
final changes = [
  for (final changeset in (await client.changesetsBy('Your Name', since: since))
      .reversed)
    ...await client.changesetChanges(changeset.id),
];
```

When the day's diff arrives with the same edits in it, they are no newer than
the file and are skipped.

## What is supported

Reading `.osm.pbf` files, either zlib compressed or uncompressed, and
OsmChange `.osc` files, gzipped or not. PBF files compressed with lzma, lz4 or
zstd are rejected with an error telling you how to convert them.

Writing `.osm.pbf`, and applying changes to one. Plain `.osm` XML is neither
read nor written.

[OsmNode]: https://pub.dev/documentation/osm/latest/osm/OsmNode-class.html
[OsmWay]: https://pub.dev/documentation/osm/latest/osm/OsmWay-class.html
[OsmRelation]: https://pub.dev/documentation/osm/latest/osm/OsmRelation-class.html
[OsmFilter]: https://pub.dev/documentation/osm/latest/osm/OsmFilter-class.html
[OsmFilter.not]: https://pub.dev/documentation/osm/latest/osm/OsmFilter/OsmFilter.not.html
[OsmFilter.where]: https://pub.dev/documentation/osm/latest/osm/OsmFilter/OsmFilter.where.html
