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

## What is supported

Reading `.osm.pbf` files, either zlib compressed or uncompressed. Files
compressed with lzma, lz4 or zstd are rejected with an error telling you how to
convert them.

[OsmNode]: https://pub.dev/documentation/osm/latest/osm/OsmNode-class.html
[OsmWay]: https://pub.dev/documentation/osm/latest/osm/OsmWay-class.html
[OsmRelation]: https://pub.dev/documentation/osm/latest/osm/OsmRelation-class.html
[OsmFilter]: https://pub.dev/documentation/osm/latest/osm/OsmFilter-class.html
[OsmFilter.not]: https://pub.dev/documentation/osm/latest/osm/OsmFilter/OsmFilter.not.html
[OsmFilter.where]: https://pub.dev/documentation/osm/latest/osm/OsmFilter/OsmFilter.where.html
