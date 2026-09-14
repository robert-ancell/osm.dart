# osm

Read and process OpenStreetMap data in Dart, with no native dependencies.

## Reading a PBF file

```dart
import 'package:osm/osm.dart';

final file = await OsmPbfFile.open('new-zealand-latest.osm.pbf');

await for (final element in file.elements()) {
  if (element.tags['leisure'] == 'golf_course') {
    print('${element.type.name} ${element.id}: ${element.tags['name']}');
  }
}
```

Elements are decoded a block at a time as they are asked for, so a file much
larger than memory can be processed by streaming through it.

Elements are [OsmNode], [OsmWay] or [OsmRelation], each with its tags and, if
the file carries metadata, the version, timestamp, changeset and user of the
edit that made it.

## What is supported

Reading `.osm.pbf` files, either zlib compressed or uncompressed. Files
compressed with lzma, lz4 or zstd are rejected with an error telling you how to
convert them.

[OsmNode]: https://pub.dev/documentation/osm/latest/osm/OsmNode-class.html
[OsmWay]: https://pub.dev/documentation/osm/latest/osm/OsmWay-class.html
[OsmRelation]: https://pub.dev/documentation/osm/latest/osm/OsmRelation-class.html
