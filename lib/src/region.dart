import 'dart:math' as math;

import 'bounds.dart';

/// Keeps a cell's row and column apart inside one number. Enough for cells
/// down to a hundred thousandth of a degree.
const int _columnBits = 32;
const int _offset = 1 << 30;

/// The ground a snapshot covers, as the cells of a grid its nodes stand in.
///
/// A country is not a box. One with islands either side of the antimeridian
/// has a header box from nearly 180°W to nearly 180°E, and that box takes in
/// a band around the whole planet. The cells its nodes
/// actually stand in follow the coast and the islands and ignore the line.
///
/// A cell with no node in it is outside, so something new mapped on ground
/// the snapshot had nothing on at all is missed. [grow] widens the region by
/// a ring of cells to take in the ground just past the last node mapped.
class OsmRegion {
  /// The size of a cell, in degrees.
  final double cellDegrees;

  // A few thousand cells for a country, which a plain set holds easily.
  final Set<int> _cells = {};

  /// An empty region, gridded in cells of [cellDegrees].
  OsmRegion({this.cellDegrees = 0.1});

  /// A region of the cells [bounds] touch.
  factory OsmRegion.of(List<OsmBounds> bounds, {double cellDegrees = 0.1}) {
    final region = OsmRegion(cellDegrees: cellDegrees);
    for (final box in bounds) {
      final south = region._row(box.minLatitude);
      final north = region._row(box.maxLatitude);
      final west = region._column(box.minLongitude);
      final east = region._column(box.maxLongitude);
      for (var row = south; row <= north; row++) {
        for (var column = west; column <= east; column++) {
          region._cells.add(_key(row, column));
        }
      }
    }
    return region;
  }

  /// How many cells the region is made of.
  int get cellCount => _cells.length;

  int _row(double latitude) => (latitude / cellDegrees).floor();
  int _column(double longitude) => (longitude / cellDegrees).floor();

  /// One number for a cell, so a set of numbers can hold the region.
  ///
  /// Offset so that neither half is ever negative, which keeps them apart.
  static int _key(int row, int column) =>
      ((row + _offset) << _columnBits) | (column + _offset);

  /// Takes in the cell the location falls in.
  void add(double latitude, double longitude) =>
      _cells.add(_key(_row(latitude), _column(longitude)));

  /// Whether the location falls in a cell of the region.
  bool contains(double latitude, double longitude) =>
      _cells.contains(_key(_row(latitude), _column(longitude)));

  /// The region with every cell's neighbours added, [rings] times over.
  OsmRegion grow({int rings = 1}) {
    final rows = <int>[];
    final columns = <int>[];
    _forEachCell((row, column) {
      rows.add(row);
      columns.add(column);
    });

    final grown = OsmRegion(cellDegrees: cellDegrees);
    // Longitude wraps: the cell past the last one east is the first one west.
    final around = (360 / cellDegrees).round();
    for (var i = 0; i < rows.length; i++) {
      for (var dy = -rings; dy <= rings; dy++) {
        for (var dx = -rings; dx <= rings; dx++) {
          var column = columns[i] + dx;
          final west = -(around ~/ 2);
          column = west + (column - west) % around;
          grown._cells.add(_key(rows[i] + dy, column));
        }
      }
    }
    return grown;
  }

  void _forEachCell(void Function(int row, int column) visit) {
    for (final key in _cells) {
      visit(
        (key >> _columnBits) - _offset,
        (key & ((1 << _columnBits) - 1)) - _offset,
      );
    }
  }

  @override
  String toString() =>
      'OsmRegion($cellCount cells of ${cellDegrees.toStringAsFixed(3)}°, '
      'about ${(cellCount * math.pow(cellDegrees * 111, 2)).round()} km²)';
}
