import '../exception.dart';

/// Thrown when an OSM XML or osmChange document cannot be read: it is not
/// well formed XML, or it is XML but not in the form OpenStreetMap writes.
class OsmXmlException implements OsmException {
  /// A description of what could not be read.
  @override
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
