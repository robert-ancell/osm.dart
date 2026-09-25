/// Signing in to OpenStreetMap, so that an edit can be made as somebody.
///
/// OpenStreetMap stopped taking a username and password in 2024: writing to
/// the API means an OAuth 2 bearer token, and getting one means a round trip
/// through the browser. That is three moving parts — a browser, a redirect
/// back to this machine, and a token exchange — and this file is all of
/// them.
///
/// **A client ID is not a secret.** It names an application; it does not
/// authorise anything. What authorises an edit is a token, and a token is
/// only issued to whoever has just proved to OpenStreetMap, in their own
/// browser, that they are themselves. PKCE — the secret made here and not
/// sent until the end — is what stops a code intercepted on the way back
/// from being worth anything to anybody else, and is why a program running
/// on somebody's own machine needs no client secret. It could not keep one:
/// anything compiled in is readable by whoever has the program.
///
/// **Registering an application** at
/// <https://www.openstreetmap.org/oauth2/applications> needs:
///
/// * any name — it is what the consent screen will say;
/// * a redirect URI of exactly `http://127.0.0.1:<port>/`, matching
///   [redirectPort], trailing slash and all;
/// * the permissions the program will use, which for an editor is **Modify
///   the map** (`write_api`) and **Read user preferences** (`read_prefs`),
///   the second only so it can say whose token it is holding;
/// * no client secret: tick the public-client box if there is one.
///
/// **Why a fixed port.** OpenStreetMap matches the redirect URI it was given
/// at registration character for character, so the port cannot be whatever
/// the machine had spare. It is only listened on for the few seconds a
/// sign-in takes.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../exception.dart';
import 'sha256.dart';

/// A token, and what it is allowed to do.
///
/// The two belong together. An application's registration says what it may
/// *ask* for; a token carries what it was actually *granted*, at the moment
/// somebody agreed to it. Adding a permission to the registration later does
/// not reach a token already issued, and OpenStreetMap's tokens do not
/// expire on their own, so one granted before the change goes on being
/// short of it indefinitely.
///
/// Holding the two apart is what turns that into a sentence somebody can act
/// on — sign in again — rather than a refusal part way through an upload.
class OsmToken {
  /// Being allowed to change the map, which every upload needs.
  static const writeApiScope = 'write_api';

  /// The bearer token itself, which [OsmApiClient.token] is set to.
  final String accessToken;

  /// What it was granted.
  final Set<String> scopes;

  /// Creates a token and what it may do.
  OsmToken(this.accessToken, Iterable<String> scopes)
      : scopes = Set.unmodifiable(scopes);

  /// Whether it is allowed to do [scope].
  bool covers(String scope) => scopes.contains(scope);

  /// Whether it is allowed to do all of [wanted].
  bool coversAll(Iterable<String> wanted) => wanted.every(covers);

  /// Whether it can be used to change the map.
  bool get canWrite => covers(OsmToken.writeApiScope);

  @override
  String toString() => 'OsmToken(${scopes.join(' ')})';
}

/// Thrown when signing in to OpenStreetMap fails: the browser could not be
/// opened or never came back, OpenStreetMap refused, or it did not hand over
/// a token.
class OsmAuthenticationException implements OsmException {
  /// What went wrong, in a sentence somebody can act on.
  @override
  final String message;

  /// Creates the exception.
  const OsmAuthenticationException(this.message);

  @override
  String toString() => message;
}

/// Thrown when a sign-in is given up on by whoever started it.
///
/// Not a failure, and nothing to tell anybody about: they know, they pressed
/// the button.
class OsmAuthenticationCancelledException implements OsmException {
  /// Creates the exception.
  const OsmAuthenticationCancelledException();

  @override
  String get message => 'Signing in was cancelled.';

  @override
  String toString() => message;
}

/// Authenticates with OpenStreetMap: takes somebody through the browser
/// and comes back with a token.
///
/// The dance, in order: make a secret, put its fingerprint in a URL, open
/// that in the browser, listen on 127.0.0.1 for OpenStreetMap to send the
/// browser back with a code, then swap the code and the secret for a token.
class OsmAuthenticator {
  /// Where OpenStreetMap's own web site is, which is where sign-in happens.
  ///
  /// Not the API: the authorisation and token endpoints are on the web site,
  /// and only the calls that follow go to `api.openstreetmap.org`.
  static final openStreetMap = Uri.parse('https://www.openstreetmap.org/');

  /// What an editor has to ask for: change the map, and see who you are.
  static const editScopes = 'write_api read_prefs';

  /// The application asking, as registered with OpenStreetMap.
  final String clientId;

  /// What it is asking to be allowed to do.
  final String scopes;

  /// Where OpenStreetMap's web site is.
  final Uri base;

  /// The port the browser is sent back to, which has to be the one the
  /// application was registered with.
  final int redirectPort;

  /// Opens a URL in the browser. Replaced in tests, which have no browser
  /// and no wish for one.
  final Future<void> Function(Uri url) launch;

  /// Creates an authenticator for an application.
  OsmAuthenticator({
    required this.clientId,
    this.scopes = OsmAuthenticator.editScopes,
    Uri? base,
    this.redirectPort = 8642,
    Future<void> Function(Uri url)? launch,
  })  : base = base ?? OsmAuthenticator.openStreetMap,
        launch = launch ?? openInBrowser;

  /// Where OpenStreetMap sends the browser back to.
  String get redirectUri => 'http://127.0.0.1:$redirectPort/';

  /// Opens a URL in whatever the desktop uses for one.
  static Future<void> openInBrowser(Uri url) async {
    final command = Platform.isMacOS
        ? 'open'
        : Platform.isWindows
            ? 'explorer'
            : 'xdg-open';
    final result = await Process.run(command, [url.toString()]);
    // Windows' explorer answers with a non-zero status even when it worked,
    // so only the others are worth believing.
    if (result.exitCode != 0 && !Platform.isWindows) {
      throw OsmAuthenticationException(
          'Could not open a browser: ${result.stderr}');
    }
  }

  /// Signs in, and gives back the token.
  ///
  /// [timeout] is how long the browser has: long enough to find the window,
  /// log in and read the consent screen, short enough that a sign-in
  /// somebody walked away from does not hold the port for the rest of the
  /// day.
  ///
  /// Completing [cancel] gives up at once, wherever it has got to, and throws
  /// [OsmAuthenticationCancelledException]. The port is let go of straight away, so a
  /// sign-in started again a moment later can have it. A browser that comes
  /// back afterwards finds nobody listening, which is the right answer: the
  /// program stopped asking.
  Future<OsmToken> tokenFromBrowser({
    Duration timeout = const Duration(minutes: 5),
    Future<void>? cancel,
  }) async {
    final verifier = _randomString(64);
    final challenge =
        base64Url.encode(sha256(ascii.encode(verifier))).replaceAll('=', '');
    final state = _randomString(16);

    // Whichever of the steps below is under way when [cancel] completes loses
    // the race to this, and the one that loses has its answer ignored.
    final cancelled = Completer<Never>();
    unawaited(
      cancel?.then((_) {
        if (!cancelled.isCompleted) {
          cancelled.completeError(const OsmAuthenticationCancelledException());
        }
      }),
    );
    Future<T> unlessCancelled<T>(Future<T> step) =>
        Future.any([step, cancelled.future]);

    // Not raced: a server that finished binding after losing would hold the
    // port with nothing left to close it.
    final server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      redirectPort,
    );
    try {
      if (cancelled.isCompleted) {
        throw const OsmAuthenticationCancelledException();
      }
      // Listening before the browser is opened, not after: the redirect can
      // arrive the moment the consent screen is agreed to, and a program
      // that opened the browser first would have a window in which the one
      // request it exists for is refused.
      final waiting = _codeFromBrowser(server, state: state);
      await launch(
        base.resolve('oauth2/authorize').replace(
          queryParameters: {
            'client_id': clientId,
            'redirect_uri': redirectUri,
            'response_type': 'code',
            'scope': scopes,
            'state': state,
            'code_challenge': challenge,
            'code_challenge_method': 'S256',
          },
        ),
      );
      final code = await unlessCancelled(
        waiting.timeout(
          timeout,
          onTimeout: () => throw const OsmAuthenticationException(
            'Gave up waiting for the browser.',
          ),
        ),
      );
      return await unlessCancelled(_token(code: code, verifier: verifier));
    } finally {
      await server.close(force: true);
    }
  }

  /// Waits for OpenStreetMap to send the browser back here, and answers the
  /// browser with a page saying it can be closed.
  Future<String> _codeFromBrowser(
    HttpServer server, {
    required String state,
  }) async {
    await for (final request in server) {
      final query = request.uri.queryParameters;
      final code = query['code'];
      final error = query['error'];
      final said = code != null && query['state'] == state
          ? 'Signed in. You can close this tab and go back to the editor.'
          : 'Sign-in failed: ${error ?? 'no code came back'}.';
      request.response
        ..statusCode = code == null ? HttpStatus.badRequest : HttpStatus.ok
        ..headers.contentType = ContentType.html
        ..write(
          '<!doctype html><meta charset="utf-8">'
          '<title>OpenStreetMap</title>'
          '<body style="font: 16px system-ui; margin: 4rem">$said</body>',
        );
      await request.response.close();

      if (error != null) {
        throw OsmAuthenticationException('OpenStreetMap said: $error');
      }
      if (code == null) continue;
      // A code that came back with the wrong state is not the sign-in this
      // program started, and is the one thing this check exists for.
      if (query['state'] != state) {
        throw const OsmAuthenticationException('The sign-in came back wrong.');
      }
      return code;
    }
    throw const OsmAuthenticationException('The browser never came back.');
  }

  Future<OsmToken> _token({
    required String code,
    required String verifier,
  }) async {
    final client = HttpClient();
    try {
      final request = await client.postUrl(base.resolve('oauth2/token'));
      request.headers.contentType = ContentType(
        'application',
        'x-www-form-urlencoded',
        charset: 'utf-8',
      );
      request.write(
        {
          'client_id': clientId,
          'code': code,
          'code_verifier': verifier,
          'grant_type': 'authorization_code',
          'redirect_uri': redirectUri,
        }
            .entries
            .map((e) => '${e.key}=${Uri.encodeComponent(e.value)}')
            .join('&'),
      );
      final response = await request.close();
      final body = await response
          .transform(const Utf8Decoder(allowMalformed: true))
          .join();
      if (response.statusCode != HttpStatus.ok) {
        throw OsmAuthenticationException(whyNoToken(body, response.statusCode));
      }
      Object? answer;
      try {
        answer = jsonDecode(body);
      } on FormatException {
        answer = null;
      }
      if (answer is! Map) {
        throw const OsmAuthenticationException('No token in what came back.');
      }
      final token = answer['access_token'];
      if (token is! String) {
        throw const OsmAuthenticationException('No token in what came back.');
      }
      return OsmToken(token, _granted(answer['scope']));
    } finally {
      client.close(force: true);
    }
  }

  /// What the token was granted, out of the answer that carried it.
  ///
  /// OAuth lets a server leave the field out when it granted exactly what
  /// was asked for, so nothing said means everything asked for rather than
  /// nothing at all. Reading it the other way would have the program telling
  /// somebody to sign in again over a token that is perfectly good.
  Iterable<String> _granted(Object? said) {
    final granted = said is String
        ? said.split(' ').where(
              (scope) => scope.isNotEmpty,
            )
        : const <String>[];
    return granted.isEmpty
        ? scopes.split(' ').where((s) => s.isNotEmpty)
        : granted;
  }

  /// What OpenStreetMap said when it would not hand over a token, in a
  /// sentence somebody can act on.
  ///
  /// The refusal comes back as OAuth's own `{error, error_description}`,
  /// which is short and to the point but written for a machine. Two of them
  /// are nearly always one thing, and the thing is a setting on a web page
  /// rather than anything in the program, so those two say what to go and
  /// change.
  String whyNoToken(String body, int status) {
    String? error;
    String? said;
    try {
      final json = jsonDecode(body);
      if (json is Map) {
        error = json['error']?.toString();
        said = json['error_description']?.toString();
      }
    } catch (_) {
      // Not JSON: a proxy, or a page. The body is all there is to say.
    }
    final what = [
      if (error != null) error,
      if (said != null && said != error) said,
    ].join(' — ');
    return [
      'OpenStreetMap would not give a token (HTTP $status)',
      if (what.isNotEmpty) ': $what' else ': ${body.trim()}',
      if (error == 'invalid_client')
        '.\n\nThat usually means the OAuth application is registered as '
            'confidential, which requires a client secret. A program running '
            'on your own machine cannot keep one. Edit the application at '
            'openstreetmap.org/oauth2/applications and untick "Confidential '
            'application?" — the client ID stays the same.',
      if (error == 'invalid_grant')
        '.\n\nThat usually means the redirect URI does not match the one '
            'registered. It has to be exactly $redirectUri, trailing slash '
            'and all.',
    ].join();
  }
}

/// Letters and digits, from the system's own random.
String _randomString(int length) {
  const alphabet =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
  final random = Random.secure();
  return String.fromCharCodes([
    for (var i = 0; i < length; i++)
      alphabet.codeUnitAt(random.nextInt(alphabet.length)),
  ]);
}
