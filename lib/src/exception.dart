/// What this package throws when something outside the program goes wrong:
/// a file that is not what it says it is, a server that refuses or cannot be
/// reached, a sign-in or an upload that fails.
///
/// One type to catch for a caller that only wants to know what failed and
/// what to tell someone about it. Each kind of failure has its own subtype
/// for a caller that wants to treat it differently.
///
/// A mistake in the calling program, such as asking for something that
/// cannot exist, is an [Error] instead, and is not caught as one of these.
abstract class OsmException implements Exception {
  /// What went wrong, in a sentence that can be shown to somebody.
  String get message;
}
