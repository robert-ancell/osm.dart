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
  rolling replication diffs into one. A file written says `osm/<version>`
  wrote it, unless the header says otherwise.
* `osm_update` and `updateOsmSnapshot` for bringing a snapshot up to date from
  the planet's replication diffs, keeping only what touches it.
* `applyOsmChanges` skips changes no newer than what the file holds, so diffs
  that overlap can be applied over each other — a delete only when it is
  older, since an extract's diffs give a delete the version it deletes — and
  copies the blocks no change alters without decoding them.
* `OsmReplication.single` and `OsmReplication.geofabrik` for a feed of one
  period, such as the daily diffs Geofabrik publishes for each extract.
* `OsmApiClient.changesetsBy` and `OsmApiClient.changesetChanges` for taking one mapper's
  edits in ahead of the diffs.
* `OsmXmlFile` for reading OSM XML, and `OsmRegion` for the ground a
  snapshot covers.
* `OsmApiClient.map` for everything inside a bounding box, which is what an editor
  draws, and `OsmApiClient.capabilities` for the limits the server itself declares.
  A box the API will not answer raises `OsmTooMuchDataException`, which is
  asking for a smaller one rather than an error.
* `httpFetch` keeps at most `concurrency` requests in flight and stops sending
  altogether while a server answers too many requests, service unavailable or
  bandwidth exceeded, for as long as its `Retry-After` asks.
* `OsmApiClient.changesetsIn` for what has been edited over an area since a time,
  and `OsmChangeset.bounds` for the ground each one touched. The API holds no
  entity tag to ask a bounding box with, so a held copy is checked by asking
  what has been edited near it instead.
* `OsmBounds.intersects`.
* `OsmFetch` takes an `abandon` future. Completing it gives up on a request:
  before the server has begun replying it is torn down, and once it has, the
  body is still read to the end and handed to `onLate` rather than wasted.
  Either way the call throws `OsmAbandonedException` at once and stops holding
  a turn, so what is wanted now can go instead. `OsmApiClient.map` passes both
  through.
* `OsmImageryIndex` for the editor layer index, the list of background imagery
  editors share, with the ground each layer covers, what it asks to be
  credited as, and which the index says to prefer. Layers that cannot be asked
  for a tile at a time are left out.
* `OsmTile` and `Mercator` for the tile numbering and projection everything
  served a piece at a time uses.
* `OsmTileCache` for holding boxes of data on disk between runs, and
  `OsmImageryCache` and `OsmImageryTiles` for fetching and holding imagery
  tiles, including remembering ground a layer has nothing for.
  `OsmImageryIndexFile` reads the editor layer index and keeps a copy.
* `OsmEditHistory` for changes made to a dataset, kept as a list so that they can be
  undone one at a time: nodes moved, made and taken off the map, ways made,
  and the nodes a way runs through changed. Nothing it holds touches what was
  read: what has been changed is laid over the top. Deleting a node takes it
  out of the ways through it as one change, so putting it back puts them back
  with it.
* `OsmEditHistory.combineSince` gathers a run of changes into one, so that
  something built a piece at a time is undone as the thing it became.
