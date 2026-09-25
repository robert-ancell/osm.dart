import '../exception.dart';

/// Thrown when an `.osm.pbf` file cannot be decoded: it is not one, it is
/// cut short or damaged, or it uses a feature this package cannot decode.
class OsmPbfException implements OsmException {
  /// A description of what could not be decoded.
  @override
  final String message;

  /// The byte offset in the file the failure was detected at, if known.
  final int? offset;

  /// Creates an exception describing why a file could not be decoded.
  const OsmPbfException(this.message, {this.offset});

  @override
  String toString() => offset == null
      ? 'OsmPbfException: $message'
      : 'OsmPbfException: $message (at byte $offset)';
}
