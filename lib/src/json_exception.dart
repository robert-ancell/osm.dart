import 'dart:convert';

import 'exception.dart';

/// Thrown when a JSON resource cannot be read: the editor layer index, the
/// tagging schema or country-coder's borders is not JSON at all, such as a
/// page from a portal asking to be logged into.
///
/// A [FormatException] as well, since that is what a caller reading JSON
/// expects to catch.
class OsmJsonException implements OsmException, FormatException {
  @override
  final String message;

  /// The text that could not be read, or null if it is not known.
  @override
  final String? source;

  /// The character offset the trouble was found at, if known.
  @override
  final int? offset;

  /// Creates an exception describing why [source] could not be read.
  const OsmJsonException(this.message, {this.source, this.offset});

  /// Decodes [json], throwing an [OsmJsonException] saying it is not [what]
  /// if it is not JSON.
  static Object? decode(String json, String what) {
    try {
      return jsonDecode(json);
    } on FormatException catch (e) {
      throw OsmJsonException(
        '$what is not JSON: ${e.message}',
        offset: e.offset,
      );
    }
  }

  @override
  String toString() => offset == null
      ? 'OsmJsonException: $message'
      : 'OsmJsonException: $message (at character $offset)';
}
