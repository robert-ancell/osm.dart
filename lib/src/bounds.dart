/// A rectangular area in degrees.
class OsmBounds {
  /// The southern edge of the area.
  final double minLatitude;

  /// The western edge of the area.
  final double minLongitude;

  /// The northern edge of the area.
  final double maxLatitude;

  /// The eastern edge of the area.
  final double maxLongitude;

  /// Creates an area covering the given edges.
  const OsmBounds({
    required this.minLatitude,
    required this.minLongitude,
    required this.maxLatitude,
    required this.maxLongitude,
  });

  /// Whether the given location falls inside the area, edges included.
  bool contains(double latitude, double longitude) =>
      latitude >= minLatitude &&
      latitude <= maxLatitude &&
      longitude >= minLongitude &&
      longitude <= maxLongitude;

  @override
  String toString() =>
      'OsmBounds($minLatitude, $minLongitude, $maxLatitude, $maxLongitude)';
}
