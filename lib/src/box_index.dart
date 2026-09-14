import 'bounds.dart';

/// The most cells one box is allowed to be written into before it is tested
/// on its own instead. Keeps a country sized box from filling the grid.
const int _maxCellsPerBox = 4096;

/// A set of rectangles, with a quick test for whether a point is in any.
///
/// Testing every box against every node of a country is not affordable: four
/// hundred courses against fifty-six million nodes is twenty-two billion
/// comparisons. The boxes go into a grid of cells instead, so a node looks at
/// the handful of boxes near it and nothing else.
class BoxIndex {
  final double _cell;
  final Map<int, Map<int, List<OsmBounds>>> _grid;

  /// Boxes covering too much ground to be worth writing into every cell.
  final List<OsmBounds> _wide;

  BoxIndex._(this._cell, this._grid, this._wide);

  /// Indexes [boxes]. An empty list contains nothing.
  factory BoxIndex(List<OsmBounds> boxes) {
    final cell = _cellSize(boxes);
    final grid = <int, Map<int, List<OsmBounds>>>{};
    final wide = <OsmBounds>[];

    for (final box in boxes) {
      final south = (box.minLatitude / cell).floor();
      final north = (box.maxLatitude / cell).floor();
      final west = (box.minLongitude / cell).floor();
      final east = (box.maxLongitude / cell).floor();
      if ((north - south + 1) * (east - west + 1) > _maxCellsPerBox) {
        wide.add(box);
        continue;
      }
      for (var latitude = south; latitude <= north; latitude++) {
        final row = grid[latitude] ??= <int, List<OsmBounds>>{};
        for (var longitude = west; longitude <= east; longitude++) {
          (row[longitude] ??= <OsmBounds>[]).add(box);
        }
      }
    }

    return BoxIndex._(cell, grid, wide);
  }

  /// A cell about the size of the boxes going into it, so that a box lands in
  /// a few cells and a cell holds a few boxes.
  static double _cellSize(List<OsmBounds> boxes) {
    if (boxes.isEmpty) return 1;
    final sides = <double>[
      for (final box in boxes) ...[
        box.maxLatitude - box.minLatitude,
        box.maxLongitude - box.minLongitude,
      ],
    ]..sort();
    final median = sides[sides.length ~/ 2];
    return median.clamp(0.0001, 1.0);
  }

  /// Whether the point falls in any of the boxes, edges included.
  bool contains(double latitude, double longitude) {
    final row = _grid[(latitude / _cell).floor()];
    if (row != null) {
      final cell = row[(longitude / _cell).floor()];
      if (cell != null) {
        for (final box in cell) {
          if (box.contains(latitude, longitude)) return true;
        }
      }
    }
    for (final box in _wide) {
      if (box.contains(latitude, longitude)) return true;
    }
    return false;
  }
}
