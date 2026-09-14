# Test data

No OpenStreetMap data. OSM is licensed under the ODbL, whose share alike terms
would follow an extract into this repository, so the fixtures here are either
public domain or written for this package.

| File | Where it comes from |
| --- | --- |
| `grid.osm.pbf` | The test grid from [osm-testdata](https://github.com/osmcode/osm-testdata), released into the public domain. `grid/data/all.osm` through `osmium cat`. |
| `elements.osm` | Written for this package. Covers what the grid does not: metadata that differs between elements, an edit with no user, UTF-8 tags, and a relation with a member of every type. |
| `elements.osm.pbf` | `elements.osm` through `osmium cat`. |

Rebuilding any of them needs osmium-tool, which the tests themselves do not.
