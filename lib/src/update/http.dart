import 'dart:async';
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

  /// How long the server asked to be left for, if it said.
  final Duration? retryAfter;

  /// Creates an exception for an answer that was not what was wanted.
  const OsmHttpException(this.uri, this.status, {this.retryAfter});

  @override
  String toString() => 'OsmHttpException: $status from $uri';
}

/// A fetch over HTTP that says who is asking and waits its turn.
///
/// OpenStreetMap's servers ask to be told what is calling them and how to
/// reach whoever runs it, so [contact] belongs in anything run for real.
/// Nothing is sent that the caller did not give.
///
/// The servers are donated and are shared by every editor and every tool, so
/// no more than [concurrency] requests are in flight at once however many are
/// asked for, and a server that asks to be left alone is left alone: a reply
/// of too many requests, service unavailable or bandwidth exceeded stops
/// every request until the moment it names, or a growing wait if it names
/// none.
OsmFetch httpFetch({String? contact, int concurrency = 2}) {
  final client = HttpClient()
    ..userAgent = contact == null
        ? 'osm.dart/$packageVersion'
        : 'osm.dart/$packageVersion ($contact)';
  final turnstile = _Turnstile(concurrency);

  return (uri) async {
    // A long download meets a dropped connection sooner or later. Try again a
    // few times, waiting longer each time, before giving up on it.
    for (var attempt = 1;; attempt++) {
      try {
        return await turnstile.run(() => _get(client, uri));
      } on OsmHttpException catch (e) {
        if (attempt >= _attempts) rethrow;
        if (_backOff.contains(e.status)) {
          turnstile.hold(e.retryAfter ?? _wait(attempt));
          continue;
        }
        if (e.status < HttpStatus.internalServerError) rethrow;
      } on IOException {
        if (attempt >= _attempts) rethrow;
      }
      await Future<void>.delayed(_wait(attempt));
    }
  };
}

/// How many times a fetch is tried before its failure is passed on.
const int _attempts = 5;

/// The answers that mean the server wants fewer requests rather than that
/// something went wrong with this one.
const _backOff = {
  HttpStatus.tooManyRequests,
  HttpStatus.serviceUnavailable,
  _bandwidthLimitExceeded,
};

/// The status OpenStreetMap answers with when a client has pulled down more
/// than its share. Not one `HttpStatus` names.
const int _bandwidthLimitExceeded = 509;

Duration _wait(int attempt) => Duration(seconds: 1 << attempt);

/// Lets a fixed number of requests through at a time, and none at all while
/// the server has asked to be left alone.
class _Turnstile {
  final int concurrency;
  final _waiting = <Completer<void>>[];
  var _running = 0;
  Future<void>? _held;

  _Turnstile(this.concurrency);

  /// Runs [request] once there is room for it.
  Future<T> run<T>(Future<T> Function() request) async {
    while (true) {
      final held = _held;
      if (held != null) await held;
      if (_running < concurrency && _held == null) break;
      if (_held == null) {
        final turn = Completer<void>();
        _waiting.add(turn);
        await turn.future;
      }
    }
    _running++;
    try {
      return await request();
    } finally {
      _running--;
      if (_waiting.isNotEmpty) _waiting.removeAt(0).complete();
    }
  }

  /// Stops letting anything through for [duration].
  void hold(Duration duration) {
    if (_held != null) return;
    _held = Future<void>.delayed(duration).then((_) {
      _held = null;
      final waiting = [..._waiting];
      _waiting.clear();
      for (final turn in waiting) {
        turn.complete();
      }
    });
  }
}

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
    throw OsmHttpException(
      uri,
      response.statusCode,
      retryAfter:
          _retryAfter(response.headers.value(HttpHeaders.retryAfterHeader)),
    );
  }
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in response) {
    bytes.add(chunk);
  }
  return bytes.takeBytes();
}

/// Reads a Retry-After header, which is either a count of seconds or a date.
Duration? _retryAfter(String? header) {
  if (header == null) return null;
  final seconds = int.tryParse(header.trim());
  if (seconds != null) return Duration(seconds: seconds.clamp(0, _longestWait));
  final DateTime at;
  try {
    at = HttpDate.parse(header);
  } on Exception {
    return null;
  }
  final wait = at.difference(DateTime.now());
  if (wait.isNegative) return Duration.zero;
  return wait > const Duration(seconds: _longestWait)
      ? const Duration(seconds: _longestWait)
      : wait;
}

/// The longest a server is allowed to ask to be left for. Beyond this it is
/// better to fail and let the caller decide than to hang.
const int _longestWait = 300;
