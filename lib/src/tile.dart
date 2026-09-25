import 'bounds.dart';
import 'mercator.dart';

/// A square of the world at one zoom level, in the standard tile numbering.
///
/// The way OpenStreetMap divides the world for anything served or held a
/// piece at a time: map data, imagery, anything else addressed by zoom, x
/// and y.
class OsmTile {
  /// The zoom level, where the world is `1 << zoom` tiles across.
  final int zoom;

  /// The column, counting east from the antimeridian.
  final int x;

  /// The row, counting south from the northern limit.
  final int y;

  /// Creates a tile reference.
  const OsmTile(this.zoom, this.x, this.y);

  /// The tile at [zoom] holding the world position ([worldX], [worldY]).
  ///
  /// East to west the world goes round, so a position past either edge is in
  /// the tile it comes round to. North to south it stops, so a position past
  /// the top or bottom is in the tile at that edge.
  factory OsmTile.of(int zoom, double worldX, double worldY) {
    final across = 1 << zoom;
    return OsmTile(
      zoom,
      (worldX * across).floor() % across,
      (worldY * across).floor().clamp(0, across - 1),
    );
  }

  /// The tile holding ([latitude], [longitude]) at [zoom].
  factory OsmTile.at(int zoom, double latitude, double longitude) =>
      OsmTile.of(zoom, Mercator.x(longitude), Mercator.y(latitude));

  /// The side of the tile in world units.
  double get size => 1 / (1 << zoom);

  /// The world x of the tile's western edge.
  double get worldX => x * size;

  /// The world y of the tile's northern edge.
  double get worldY => y * size;

  /// The ground the tile covers.
  OsmBounds get bounds => OsmBounds(
        minLatitude: Mercator.latitude(worldY + size),
        minLongitude: Mercator.longitude(worldX),
        maxLatitude: Mercator.latitude(worldY),
        maxLongitude: Mercator.longitude(worldX + size),
      );

  /// The tile one zoom level out that holds this one.
  ///
  /// There is nothing further out than the whole world, which is the one tile
  /// at zoom 0 and has no parent.
  OsmTile get parent {
    if (zoom == 0) throw StateError('The whole world has no parent tile.');
    return OsmTile(zoom - 1, x ~/ 2, y ~/ 2);
  }

  /// The four tiles one zoom level in that together cover this one.
  List<OsmTile> get children => [
        OsmTile(zoom + 1, x * 2, y * 2),
        OsmTile(zoom + 1, x * 2 + 1, y * 2),
        OsmTile(zoom + 1, x * 2, y * 2 + 1),
        OsmTile(zoom + 1, x * 2 + 1, y * 2 + 1),
      ];

  @override
  bool operator ==(Object other) =>
      other is OsmTile && other.zoom == zoom && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(zoom, x, y);

  @override
  String toString() => '$zoom/$x/$y';
}
