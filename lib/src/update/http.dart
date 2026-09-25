import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../exception.dart';
import '../version.g.dart';

/// Fetches a URL's body, or null if the server says there is nothing there.
///
/// Completing [abandon] says the answer is no longer wanted: the call throws
/// [OsmAbandonedException] and stops holding a turn, so whatever is wanted
/// now can go instead.
///
/// What happens to the answer depends on how far it had got. Before the
/// server has begun replying, the request is torn down, which saves it the
/// work. Once it has begun, the work is already done and the rest is a few
/// kilobytes, so the body is read to the end and handed to [onLate] rather
/// than thrown away. Whoever asked can keep it even though they stopped
/// waiting for it.
typedef OsmFetch = Future<Uint8List?> Function(
  Uri uri, {
  Future<void>? abandon,
  void Function(Uint8List body)? onLate,
});

/// Thrown when a server answers a request with an HTTP error status rather
/// than what was asked for.
///
/// An [IOException] as well, since it is a failure to read something over
/// the network, and is caught with them.
class OsmHttpException implements OsmException, IOException {
  /// What was asked for.
  final Uri uri;

  /// The status the server answered with.
  final int status;

  /// How long the server asked to be left for, if it said.
  final Duration? retryAfter;

  /// Creates an exception for an answer that was not what was wanted.
  const OsmHttpException(this.uri, this.status, {this.retryAfter});

  @override
  String get message => 'HTTP $status from $uri';

  @override
  String toString() => 'OsmHttpException: $message';
}

/// Thrown when a fetch is given up on, by whoever asked for it, before it
/// finished.
///
/// Not a failure: whoever asked stopped wanting the answer. Nothing is
/// retried and nothing is held against the server. An [IOException] as well,
/// so a caller that does not care why a fetch came to nothing need not know
/// about it.
class OsmAbandonedException implements OsmException, IOException {
  /// Creates the exception.
  const OsmAbandonedException();

  @override
  String get message => 'The request was given up on.';

  @override
  String toString() => 'OsmAbandonedException: $message';
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

  return (uri, {abandon, onLate}) async {
    var abandoned = false;
    if (abandon != null) {
      unawaited(abandon.then((_) => abandoned = true));
    }

    // A long download meets a dropped connection sooner or later. Try again a
    // few times, waiting longer each time, before giving up on it.
    for (var attempt = 1;; attempt++) {
      if (abandoned) throw const OsmAbandonedException();
      try {
        return await turnstile.run(() {
          // Waiting for a turn can take longer than the answer is wanted for.
          if (abandoned) throw const OsmAbandonedException();
          return _get(client, uri, abandon, onLate);
        });
      } on OsmAbandonedException {
        rethrow;
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

Future<Uint8List?> _get(
  HttpClient client,
  Uri uri,
  Future<void>? abandon,
  void Function(Uint8List body)? onLate,
) async {
  final request = await client.getUrl(uri);

  // Until the server starts replying, giving up means tearing the request
  // down: the answer has not been worked out yet, so nobody has to.
  var replying = false;
  var abandoned = false;
  if (abandon != null) {
    unawaited(
      abandon.then((_) {
        abandoned = true;
        if (!replying) request.abort(const OsmAbandonedException());
      }),
    );
  }

  final HttpClientResponse response;
  try {
    response = await request.close();
  } on Object {
    if (abandoned) throw const OsmAbandonedException();
    rethrow;
  }
  replying = true;

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
      retryAfter: _retryAfter(
        response.headers.value(HttpHeaders.retryAfterHeader),
      ),
    );
  }

  final reading = _collect(response);
  if (abandon == null) return reading;

  // From here the answer is on its way. Giving up stops the waiting and
  // frees the turn, and the body is still read to the end so that whoever
  // asked can keep what the server already went to the trouble of making.
  final settled = Completer<Uint8List?>();
  unawaited(
    reading.then(
      (body) {
        if (settled.isCompleted) {
          if (body != null) onLate?.call(body);
        } else {
          settled.complete(body);
        }
      },
      onError: (Object error, StackTrace trace) {
        if (!settled.isCompleted) settled.completeError(error, trace);
      },
    ),
  );
  unawaited(
    abandon.then((_) {
      if (!settled.isCompleted) {
        settled.completeError(const OsmAbandonedException());
      }
    }),
  );
  return settled.future;
}

Future<Uint8List?> _collect(HttpClientResponse response) async {
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
