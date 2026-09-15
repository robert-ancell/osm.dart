/// What this package throws when a file is not what it says it is.
///
/// One type to catch for a caller that only wants to know the read failed and
/// what to tell someone about it.
abstract class OsmException implements Exception {
  /// A description of what could not be read or written.
  String get message;
}
