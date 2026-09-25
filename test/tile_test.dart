import 'package:osm/osm.dart';
import 'package:test/test.dart';

void main() {
  test('puts the origin at the north west corner', () {
    expect(Mercator.x(-180), closeTo(0, 1e-12));
    expect(Mercator.y(Mercator.latitudeLimit), closeTo(0, 1e-9));
  });

  test('puts null island in the middle', () {
    expect(Mercator.x(0), closeTo(0.5, 1e-12));
    expect(Mercator.y(0), closeTo(0.5, 1e-12));
  });

  test('round trips a location', () {
    for (final latitude in [-84.0, -36.85, 0.0, 51.5, 84.0]) {
      for (final longitude in [-179.0, -1.0, 0.0, 174.76, 179.0]) {
        expect(
          Mercator.latitude(Mercator.y(latitude)),
          closeTo(latitude, 1e-9),
        );
        expect(
          Mercator.longitude(Mercator.x(longitude)),
          closeTo(longitude, 1e-9),
        );
      }
    }
  });

  test('clamps beyond the limit rather than running to infinity', () {
    expect(Mercator.y(90), closeTo(0, 1e-9));
    expect(Mercator.y(-90), closeTo(1, 1e-9));
  });

  test('stretches distances away from the equator', () {
    expect(Mercator.metresPerUnit(0), greaterThan(Mercator.metresPerUnit(60)));
    expect(
      Mercator.metresPerUnit(60),
      closeTo(Mercator.metresPerUnit(0) / 2, 1),
    );
  });

  test('numbers tiles from the north west', () {
    expect(OsmTile.at(0, 0, 0), const OsmTile(0, 0, 0));
    expect(OsmTile.at(1, 45, -90), const OsmTile(1, 0, 0));
    expect(OsmTile.at(1, -45, 90), const OsmTile(1, 1, 1));
  });

  test('keeps a tile inside the world at the edges', () {
    // 180 is -180, the western edge of the world.
    expect(OsmTile.at(2, -89, 180).x, 0);
    expect(OsmTile.at(2, -89, 180).y, 3);
  });

  test('covers the ground it says it does', () {
    const tile = OsmTile(16, 64583, 39992);
    final bounds = tile.bounds;
    expect(bounds.minLatitude, lessThan(bounds.maxLatitude));
    expect(bounds.minLongitude, lessThan(bounds.maxLongitude));
    expect(
      OsmTile.at(16, (bounds.minLatitude + bounds.maxLatitude) / 2,
          (bounds.minLongitude + bounds.maxLongitude) / 2),
      tile,
    );
  });

  test('sits inside the tile that holds it', () {
    const tile = OsmTile(16, 64583, 39992);
    expect(tile.parent, const OsmTile(15, 32291, 19996));
    expect(tile.parent.children, contains(tile));
    expect(tile.children.length, 4);
    for (final child in tile.children) {
      expect(child.parent, tile);
    }
  });

  test('halves a tile for each zoom level', () {
    expect(const OsmTile(0, 0, 0).size, 1);
    expect(const OsmTile(10, 0, 0).size, closeTo(1 / 1024, 1e-12));
  });

  test('comes round the world east to west, and stops north to south', () {
    expect(OsmTile.of(3, 1.01, 0.5), const OsmTile(3, 0, 4));
    expect(OsmTile.of(3, -0.01, 0.5), const OsmTile(3, 7, 4));
    expect(OsmTile.of(3, 0.5, -0.2), const OsmTile(3, 4, 0));
    expect(OsmTile.of(3, 0.5, 1.2), const OsmTile(3, 4, 7));
  });

  test('has no parent for the whole world', () {
    expect(const OsmTile(1, 1, 1).parent, const OsmTile(0, 0, 0));
    expect(() => const OsmTile(0, 0, 0).parent, throwsStateError);
  });

  group('Mercator', () {
    test('wraps round the world', () {
      expect(Mercator.wrap(1.25), closeTo(0.25, 1e-12));
      expect(Mercator.wrap(-0.25), closeTo(0.75, 1e-12));
      expect(Mercator.wrap(1), 0);
      expect(Mercator.wrappedLongitude(Mercator.x(179) + 2 / 360),
          closeTo(-179, 1e-9));
    });

    test('brings a place round beside another', () {
      expect(Mercator.nearest(0.01, 0.99), closeTo(1.01, 1e-12));
      expect(Mercator.nearest(0.99, 0.01), closeTo(-0.01, 1e-12));
      expect(Mercator.nearest(0.4, 0.6), closeTo(0.4, 1e-12));
    });
  });
}
