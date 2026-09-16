import 'dart:io';
import 'dart:typed_data';

import '../version.g.dart';

/// Fetches a URL's body, or null if the server says there is nothing there.
typedef OsmFetch = Future<Uint8List?> Function(Uri uri);

/// Thrown when a server answers with something other than the body or a
/// plain not found.
class OsmHttpException implements IOException {
  /// What was asked for.
  final Uri uri;

  /// The status the server answered with.
  final int status;

  /// Creates an exception for an answer that was not what was wanted.
  const OsmHttpException(this.uri, this.status);

  @override
  String toString() => 'OsmHttpException: $status from $uri';
}

/// A fetch over HTTP that says who is asking.
///
/// OpenStreetMap's servers ask to be told what is calling them and how to
/// reach whoever runs it, so [contact] belongs in anything run for real.
/// Nothing is sent that the caller did not give.
OsmFetch httpFetch({String? contact}) {
  final client = HttpClient()
    ..userAgent = contact == null
        ? 'osm.dart/$packageVersion'
        : 'osm.dart/$packageVersion ($contact)';
  return (uri) async {
    // A download of a hundred diffs meets a dropped connection sooner or
    // later. Try again a few times, waiting longer each time, before giving
    // up on it.
    for (var attempt = 1;; attempt++) {
      try {
        return await _get(client, uri);
      } on OsmHttpException catch (e) {
        if (e.status < HttpStatus.internalServerError || attempt >= _attempts) {
          rethrow;
        }
      } on IOException {
        if (attempt >= _attempts) rethrow;
      }
      await Future<void>.delayed(Duration(seconds: 1 << attempt));
    }
  };
}

/// How many times a fetch is tried before its failure is passed on.
const int _attempts = 5;

Future<Uint8List?> _get(HttpClient client, Uri uri) async {
  final request = await client.getUrl(uri);
  final response = await request.close();
  if (response.statusCode == HttpStatus.notFound ||
      response.statusCode == HttpStatus.gone) {
    await response.drain<void>();
    return null;
  }
  if (response.statusCode != HttpStatus.ok) {
    await response.drain<void>();
    throw OsmHttpException(uri, response.statusCode);
  }
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in response) {
    bytes.add(chunk);
  }
  return bytes.takeBytes();
}
