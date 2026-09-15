# Test data

No OpenStreetMap data. OSM is licensed under the ODbL, whose share alike terms
would follow an extract into this repository, so the fixtures here are either
public domain or written for this package.

| File | Where it comes from |
| --- | --- |
| `grid.osm.pbf` | The test grid from [osm-testdata](https://github.com/osmcode/osm-testdata), released into the public domain. `grid/data/all.osm` through `osmium sort`, which writes the `Sort.Type_then_ID` header that `within` reads in one pass. |
| `multipolygon-tests.json` | The `areas.default` expectation of each test case in `grid/data/7` of the same repository, for the cases in `grid.osm.pbf`. |
| `grid-buildings.osm.pbf` | `grid.osm.pbf` through `osmium tags-filter building=yes`, to check element completion against another implementation. |
| `elements.osm` | Written for this package. Covers what the grid does not: metadata that differs between elements, an edit with no user, UTF-8 tags, and a relation with a member of every type. |
| `elements.osm.pbf` | `elements.osm` through `osmium cat`, which does not write the sort header, so it covers reading a file that does not declare one. |
| `elements-sites.osm.pbf` | `elements.osm.pbf` through `osmium tags-filter type=site`, which follows a relation into a relation. |

| `changes.osc` | Written for this package: an OsmChange file altering the elements of `elements.osm`, covering all three actions, entity escaped tag values, and a deletion given without a location. |
| `changes-gzipped.osc.gz` | `changes.osc` through `gzip`, the way replication serves them. |

Rebuilding any of them needs osmium-tool, which the tests themselves do not.
