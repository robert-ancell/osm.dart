import 'dart:math' as math;

/// The Web Mercator projection, onto a square world of side 1.
///
/// What every OpenStreetMap tile service and editor draws in.
///
/// The origin is the north-west corner, so y grows southwards, matching the
/// tile numbering used by every OpenStreetMap tile service.
abstract final class Mercator {
  /// The northern and southern limit of the projection, in degrees.
  ///
  /// Mercator sends the poles to infinity, so the world square is cut off at
  /// the latitude that makes it square.
  static const latitudeLimit = 85.051128779806604;

  /// The world x of [longitude], between 0 at the antimeridian and 1 back at
  /// the antimeridian.
  static double x(double longitude) => (longitude + 180) / 360;

  /// The world y of [latitude], between 0 at the northern limit and 1 at the
  /// southern.
  static double y(double latitude) {
    final clamped = latitude.clamp(-latitudeLimit, latitudeLimit);
    final radians = clamped * math.pi / 180;
    return 0.5 - math.log(math.tan(math.pi / 4 + radians / 2)) / (2 * math.pi);
  }

  /// The longitude at world [x].
  static double longitude(double x) => x * 360 - 180;

  /// The latitude at world [y].
  static double latitude(double y) =>
      math.atan(_sinh(math.pi * (1 - 2 * y))) * 180 / math.pi;

  /// How many metres one world unit covers at [latitude].
  ///
  /// Mercator preserves angles by stretching distances away from the equator,
  /// so a line drawn one pixel wide in Wellington covers less ground than the
  /// same line in Auckland. Widths that are meant to be in metres have to be
  /// divided by this.
  static double metresPerUnit(double latitude) =>
      _earthCircumference * math.cos(latitude * math.pi / 180);

  static const _earthCircumference = 40075016.686;

  static double _sinh(double x) => (math.exp(x) - math.exp(-x)) / 2;
}
