## 0.1.0

* Initial release, reading elements from `.osm.pbf` files.
* `OsmFilter` for taking part of a file, used to skip decoding rather than to
  throw away its results, and decoding blocks across isolates.
* `OsmPbfFile.subset` for reading matching elements along with the nodes and
  members they refer to, so their geometry can be built.
* `OsmSubset.areaOf` for assembling the area a closed way or a multipolygon
  relation covers, as outlines and holes.
* `OsmPbfFile.within` for reading everything inside a set of boxes, and
  `OsmFilter.within` for the nodes standing in them.
* `OsmPbfHeader.isSorted`, which lets a sorted file be read in one pass.
* `OsmChangeFile` for reading OsmChange `.osc` replication diffs, gzipped or
  not.
* `OsmPbfWriter` for writing `.osm.pbf` files, and `applyOsmChanges` for
  rolling replication diffs into one.
