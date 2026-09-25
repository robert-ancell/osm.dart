import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:osm/osm.dart';
import 'package:osm/src/update/auth.dart' show whyNoToken;
import 'package:test/test.dart';

/// Stands in for openstreetmap.org: takes the authorisation request, sends
/// the browser back, and swaps the code for a token.
class _FakeOpenStreetMap {
  final HttpServer _server;
  final String token;

  /// What the consent screen granted, where that is not simply what was
  /// asked for. Null leaves the field out, as a server may.
  String? granted;

  /// What the token request was asked for, so a test can check PKCE went.
  Map<String, String>? exchanged;

  _FakeOpenStreetMap._(this._server, this.token);

  static Future<_FakeOpenStreetMap> start({String token = 'a-token'}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = _FakeOpenStreetMap._(server, token);
    server.listen(fake._answer);
    return fake;
  }

  Uri get base => Uri.parse('http://127.0.0.1:${_server.port}/');

  Future<void> _answer(HttpRequest request) async {
    if (request.uri.path == '/oauth2/token') {
      final body = await utf8.decoder.bind(request).join();
      exchanged = Uri.splitQueryString(body);
      request.response
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({
          'access_token': token,
          if (granted != null) 'scope': granted,
        }));
    } else {
      request.response
        ..statusCode = HttpStatus.badRequest
        ..write(jsonEncode({'error': 'invalid_client'}));
    }
    await request.response.close();
  }

  Future<void> stop() => _server.close(force: true);
}

void main() {
  late _FakeOpenStreetMap osm;

  setUp(() async => osm = await _FakeOpenStreetMap.start());
  tearDown(() async => osm.stop());

  /// A browser that agrees to the consent screen the moment it is opened.
  Future<void> Function(Uri) agreeing({String? state}) => (url) async {
        final query = url.queryParameters;
        final client = HttpClient();
        final request = await client.getUrl(
          Uri.parse(query['redirect_uri']!).replace(
            queryParameters: {
              'code': 'a-code',
              'state': state ?? query['state']!,
            },
          ),
        );
        await (await request.close()).drain<void>();
        client.close();
      };

  test('comes back with a token', () async {
    final signIn = OsmAuthenticator(
      clientId: 'an-application',
      base: osm.base,
      redirectPort: 8643,
      launch: agreeing(),
    );
    expect((await signIn.tokenFromBrowser()).accessToken, 'a-token');
    // The secret is only sent at the end, with the code, which is the whole
    // of what PKCE is.
    expect(osm.exchanged!['code'], 'a-code');
    expect(osm.exchanged!['code_verifier'], isNotEmpty);
    expect(osm.exchanged!['client_id'], 'an-application');
  });

  test('will not take a code from a sign-in it did not start', () async {
    final signIn = OsmAuthenticator(
      clientId: 'an-application',
      base: osm.base,
      redirectPort: 8644,
      launch: agreeing(state: 'somebody-elses'),
    );
    await expectLater(
      signIn.tokenFromBrowser(),
      throwsA(isA<OsmAuthenticationException>()),
    );
  });

  test('gives up rather than holding the port all day', () async {
    final signIn = OsmAuthenticator(
      clientId: 'an-application',
      base: osm.base,
      redirectPort: 8645,
      launch: (_) async {},
    );
    await expectLater(
      signIn.tokenFromBrowser(timeout: const Duration(milliseconds: 50)),
      throwsA(isA<OsmAuthenticationException>()),
    );
  });

  test('gives up when asked to, and lets go of the port', () async {
    final cancel = Completer<void>();
    final signIn = OsmAuthenticator(
      clientId: 'an-application',
      base: osm.base,
      redirectPort: 8648,
      // A browser opened and then never heard from again.
      launch: (_) async => cancel.complete(),
    );
    await expectLater(
      signIn.tokenFromBrowser(cancel: cancel.future),
      throwsA(isA<OsmAuthenticationCancelledException>()),
    );
    // Signing in again straight away needs the same port.
    final again = await HttpServer.bind(InternetAddress.loopbackIPv4, 8648);
    await again.close();
  });

  test('takes a token as granted what it asked for', () async {
    // OAuth lets the field be left out when the answer is exactly what was
    // asked for, and reading that as nothing granted would have the editor
    // asking somebody to sign in again over a perfectly good token.
    final signIn = OsmAuthenticator(
      clientId: 'an-application',
      base: osm.base,
      redirectPort: 8646,
      launch: agreeing(),
    );
    final token = await signIn.tokenFromBrowser();
    expect(token.covers(OsmToken.writeApiScope), isTrue);
    expect(token.coversAll(['write_api', 'read_prefs']), isTrue);
  });

  test('holds a token to what it was actually granted', () async {
    // A token issued before a permission was added to the registration goes
    // on being short of it, and OpenStreetMap's tokens do not expire.
    osm.granted = 'read_prefs';
    final signIn = OsmAuthenticator(
      clientId: 'an-application',
      base: osm.base,
      redirectPort: 8647,
      launch: agreeing(),
    );
    final token = await signIn.tokenFromBrowser();
    expect(token.covers(OsmToken.writeApiScope), isFalse);
    expect(token.covers('read_prefs'), isTrue);
  });

  test('says what to go and change when the application is confidential', () {
    expect(
      whyNoToken(
        '{"error": "invalid_client"}',
        400,
        redirectUri: 'http://127.0.0.1:8642/',
      ),
      contains('Confidential'),
    );
  });
}
