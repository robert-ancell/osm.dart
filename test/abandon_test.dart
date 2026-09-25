import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:osm/osm.dart';
import 'package:osm/src/update/http.dart' show httpFetch;
import 'package:test/test.dart';

/// A server that answers only when told to, and can be made to send its
/// headers first so that a request can be given up on mid answer.
class _Slow {
  late HttpServer _server;

  /// How many requests reached it.
  int reached = 0;

  /// How many of those the client hung up on.
  int dropped = 0;

  /// Whether to send headers as soon as a request arrives.
  bool replyAtOnce = false;

  final _waiting = <HttpRequest>[];

  Uri get base => Uri.parse('http://${_server.address.host}:${_server.port}/');

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    unawaited(_serve());
  }

  Future<void> _serve() async {
    await for (final request in _server) {
      reached++;
      _waiting.add(request);
      unawaited(
        request.response.done.catchError((Object _) {
          dropped++;
          return request.response;
        }),
      );
      if (replyAtOnce) {
        request.response.write('<osm ');
        unawaited(request.response.flush());
      }
    }
  }

  /// Finishes every request held so far.
  Future<void> finish() async {
    final held = [..._waiting];
    _waiting.clear();
    for (final request in held) {
      try {
        request.response.write(replyAtOnce ? 'version="0.6"/>' : '<osm/>');
        await request.response.close();
      } on Object {
        // Nobody there, which some of these tests are about.
      }
    }
  }

  /// Waits until [count] requests have arrived.
  Future<void> until(int count) async {
    while (reached < count) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  Future<void> stop() async {
    await finish();
    await _server.close(force: true);
  }
}

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 120));

void main() {
  late _Slow server;

  setUp(() async {
    server = _Slow();
    await server.start();
  });

  tearDown(() async => server.stop());

  test('finishes normally when it is never given up on', () async {
    final body = httpFetch()(
      server.base.resolve('map'),
      abandon: Completer<void>().future,
    );
    await server.until(1);
    await server.finish();
    expect(await body, isNotNull);
    expect(server.dropped, 0);
  });

  test('never asks at all when it was given up on first', () async {
    final body = httpFetch()(
      server.base.resolve('map'),
      abandon: Future<void>.value(),
    );
    await expectLater(body, throwsA(isA<OsmAbandonedException>()));
    expect(server.reached, 0);
  });

  test('gives up on an answer that has not started', () async {
    final giveUp = Completer<void>();
    final body =
        httpFetch()(server.base.resolve('map'), abandon: giveUp.future);
    await server.until(1);
    giveUp.complete();
    await expectLater(body, throwsA(isA<OsmAbandonedException>()));
  });

  test('does not read an answer the server had not started', () async {
    // Nothing had been worked out yet, so the request is torn down and the
    // body never arrives, however willingly the server offers it later.
    final giveUp = Completer<void>();
    Uint8List? late;
    final body = httpFetch()(
      server.base.resolve('map'),
      abandon: giveUp.future,
      onLate: (bytes) => late = bytes,
    );
    await server.until(1);
    giveUp.complete();
    await expectLater(body, throwsA(isA<OsmAbandonedException>()));

    await server.finish();
    await _settle();
    expect(late, isNull);
  });

  test('does not ask again after being given up on', () async {
    final giveUp = Completer<void>();
    final body =
        httpFetch()(server.base.resolve('map'), abandon: giveUp.future);
    await server.until(1);
    giveUp.complete();
    await body.catchError((Object _) => null);
    await _settle();
    expect(server.reached, 1);
  });

  test('keeps an answer that was already on its way', () async {
    // The server has done the work, so the rest is a few kilobytes and worth
    // reading even though nobody is waiting for it any more.
    server.replyAtOnce = true;
    final giveUp = Completer<void>();
    Uint8List? late;
    final body = httpFetch()(
      server.base.resolve('map'),
      abandon: giveUp.future,
      onLate: (bytes) => late = bytes,
    );
    await server.until(1);
    await _settle();

    giveUp.complete();
    await expectLater(body, throwsA(isA<OsmAbandonedException>()));
    expect(late, isNull, reason: 'nothing has arrived yet');

    await server.finish();
    await _settle();
    expect(late, isNotNull);
    expect(String.fromCharCodes(late!), '<osm version="0.6"/>');
  });

  test('frees its turn for whatever is still wanted', () async {
    final fetch = httpFetch(concurrency: 1);
    final giveUp = Completer<void>();
    final first = fetch(server.base.resolve('one'), abandon: giveUp.future);
    await server.until(1);

    // With one turn to share, the second is waiting behind the first.
    final second = fetch(server.base.resolve('two'));
    await _settle();
    expect(server.reached, 1);

    giveUp.complete();
    await first.catchError((Object _) => null);
    await server.until(2);
    await server.finish();
    expect(await second, isNotNull);
  });
}
