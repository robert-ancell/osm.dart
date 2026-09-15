# osm

Read and process OpenStreetMap data in Dart, with no native dependencies.

## Reading a PBF file

```dart
import 'package:osm/osm.dart';

final file = await OsmPbfFile.open('new-zealand-latest.osm.pbf');

await for (final element in file.elements()) {
  print('${element.type.name} ${element.id}');
}
```

Elements are decoded a block at a time as they are asked for, so a file much
larger than memory can be processed by streaming through it. Each one is an
[OsmNode], [OsmWay] or [OsmRelation], with its tags and, if the file carries
metadata, the version, timestamp, changeset and user of the edit that made it.

## Taking part of a file

Say what you want with an [OsmFilter] rather than filtering the stream
afterwards:

```dart
final courses = file.elements(
  filter: const OsmFilter.tag('leisure', 'golf_course'),
);
```

The filter is used to skip work rather than to throw away its results. A block
whose string table does not hold the key is dropped without looking at a single
element, elements of a type that cannot match are never decoded, and an element
without the key is never built into an object. What is left is decoded across
every core.

Finding the 416 golf courses in the 434 MB New Zealand extract takes 1.7s,
against 25s to read the same file end to end. Filters combine with `&`, `|` and
[OsmFilter.not], and [OsmFilter.where] takes a test written as code for
anything they cannot say.

## Building geometry

A way names its nodes by id, so matching it is only half of what it takes to
draw it. `subset` reads the matches and everything they refer to:

```dart
final courses = await file.subset(
  const OsmFilter.tag('leisure', 'golf_course'),
);

for (final course in courses.matches) {
  if (course is! OsmWay) continue;
  final outline = courses.nodesOf(course);
  if (outline == null) continue; // Runs off the edge of the file.
  print('${course.tags['name']}: ${outline.length} points');
}
```

This is what `osmium tags-filter` does when it is not told to leave referenced
elements out, and it holds the same elements: the nodes of matching ways, the
members of matching relations, and so on down. Pulling the golf courses and
their 17,690 nodes out of a 434 MB country extract takes 7.4s.

Everything read is held in memory, so filter to what is wanted. `elements()`
is there for reads too big to keep.

## Areas

A closed way, or a relation whose member ways make up rings, covers ground.
`areaOf` works out which, wound the way GeoJSON and most triangulators want:

```dart
final area = courses.areaOf(course);
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
    minLatitude: -41.33,
    minLongitude: 174.76,
    maxLatitude: -41.31,
    maxLongitude: 174.79,
  ),
]);
```

The nodes standing in the boxes, the ways using any of them along with the
rest of their nodes wherever those are, and the relations with any of those as
a member. What a kept relation refers to is not read: a relation is kept
because it has something here, not because it belongs here, and reading the
rest of a bus route that happens to pass by would pull in the country around
it.

That is what `osmium extract --strategy complete_ways` gives, element for
element.

## Reading a change file

```dart
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

## What is supported

Reading `.osm.pbf` files, either zlib compressed or uncompressed, and
OsmChange `.osc` files, gzipped or not. PBF files compressed with lzma, lz4 or
zstd are rejected with an error telling you how to convert them.

Nothing is written yet, and plain `.osm` XML is not read.

[OsmNode]: https://pub.dev/documentation/osm/latest/osm/OsmNode-class.html
[OsmWay]: https://pub.dev/documentation/osm/latest/osm/OsmWay-class.html
[OsmRelation]: https://pub.dev/documentation/osm/latest/osm/OsmRelation-class.html
[OsmFilter]: https://pub.dev/documentation/osm/latest/osm/OsmFilter-class.html
[OsmFilter.not]: https://pub.dev/documentation/osm/latest/osm/OsmFilter/OsmFilter.not.html
[OsmFilter.where]: https://pub.dev/documentation/osm/latest/osm/OsmFilter/OsmFilter.where.html
