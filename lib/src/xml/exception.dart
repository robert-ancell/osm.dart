/// Thrown when a file is not the XML this package can read.
class OsmXmlException implements Exception {
  /// A description of what could not be read.
  final String message;

  /// The character offset the trouble was found at, if known.
  final int? offset;

  /// Creates an exception describing why a document could not be read.
  const OsmXmlException(this.message, {this.offset});

  @override
  String toString() => offset == null
      ? 'OsmXmlException: $message'
      : 'OsmXmlException: $message (at character $offset)';
}
