## 0.1.0

* Initial release, reading elements from `.osm.pbf` files.
* `OsmFilter` for taking part of a file, used to skip decoding rather than to
  throw away its results, and decoding blocks across isolates.
* `OsmPbfFile.subset` for reading matching elements along with the nodes and
  members they refer to, so their geometry can be built.
