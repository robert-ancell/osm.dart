# osm

Read, edit and write OpenStreetMap data in Dart, with no native dependencies.

It comes as several libraries, so a program imports only what it uses. Each
library's documentation says how to use it, with examples.

* `package:osm/osm.dart` — elements, reading them from the OpenStreetMap API
  and uploading changes to it, replication feeds, imagery, and the caches
  that keep them. The other libraries are used alongside it.
* `package:osm/editor.dart` — editing elements with undo and redo, the rules
  the editor follows for what tags mean, and the tagging schema.
* `package:osm/country_coder.dart` — which country, and which larger regions,
  a place is in.
* `package:osm/pbf.dart` — reading, writing and updating `.osm.pbf` files.
* `package:osm/xml.dart` — reading OSM XML and osmChange files.

```dart
import 'package:osm/osm.dart';
import 'package:osm/pbf.dart';

final file = await OsmPbfFile.open('extract.osm.pbf');
await for (final element in file.elements()) {
  print('${element.type.name} ${element.id}');
}
```

## Keeping a snapshot up to date

```
dart run osm:osm_update extract.osm.pbf --contact "Your Name <you@example.com>"
```

Reads the planet's replication diffs published since the snapshot's own
timestamp, keeps the changes that touch what the snapshot holds, and writes it
back with them applied. A way reaching past the edge, or a node moved in from
outside, is looked up through the OpenStreetMap API; with `--no-lookups` it is
listed instead, and the tool exits with 2 to say a fresh snapshot is due.

The same thing from code is `OsmPbfUpdater`, in `package:osm/pbf.dart`.

## What is supported

Reading `.osm.pbf` files, either zlib compressed or uncompressed; PBF files
compressed with lzma, lz4 or zstd are rejected with an error saying so.
Writing `.osm.pbf`, and applying changes to one.

Reading OSM XML, as `.osm` files and as the API answers with it, and
osmChange `.osc` files, gzipped or not. XML is not written, except the
osmChange an upload sends.
