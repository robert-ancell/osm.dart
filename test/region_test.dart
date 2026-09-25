import 'package:osm/osm.dart';
import 'package:osm/pbf.dart';
import 'package:test/test.dart';

void main() {
  test('holds the cells its locations fall in', () {
    final region = OsmRegion()
      ..add(-41.28, 174.77)
      ..add(-43.53, 172.63);
    expect(region.contains(-41.25, 174.75), isTrue, reason: 'same cell');
    expect(region.contains(-43.55, 172.65), isTrue);
    expect(region.contains(-42.0, 173.0), isFalse, reason: 'no node there');
    expect(region.contains(51.5, -0.1), isFalse);
    expect(region.cellCount, 2);
  });

  test('grows by a ring of cells', () {
    final region = OsmRegion()..add(-41.25, 174.75);
    final grown = region.grow();
    expect(grown.cellCount, 9);
    expect(grown.contains(-41.35, 174.75), isTrue, reason: 'the cell south');
    expect(grown.contains(-41.45, 174.75), isFalse, reason: 'two cells south');
  });

  test('grows across the antimeridian', () {
    // The Chatham Islands side of the line, and the cell over it.
    final grown = (OsmRegion()..add(-44.0, 179.95)).grow();
    expect(grown.contains(-44.0, -179.95), isTrue);
    expect(grown.contains(-44.0, 179.85), isTrue);
  });

  test('takes a region from boxes', () {
    final region = OsmRegion.of(const [
      OsmBounds(
        minLatitude: -41.3,
        minLongitude: 174.7,
        maxLatitude: -41.2,
        maxLongitude: 174.8,
      ),
    ]);
    expect(region.contains(-41.25, 174.75), isTrue);
    expect(region.contains(-40.0, 174.75), isFalse);
  });
}
