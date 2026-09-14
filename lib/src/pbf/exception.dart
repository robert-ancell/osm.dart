/// Thrown when a file is not a valid OSM PBF file, or uses a feature this
/// package cannot decode.
class OsmPbfException implements Exception {
  /// A description of what could not be decoded.
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
