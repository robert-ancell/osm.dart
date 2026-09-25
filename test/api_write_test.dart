import 'dart:convert';
import 'dart:io';

import 'package:osm/osm.dart';
import 'package:test/test.dart';

import 'test_editor.dart';

/// An API on this machine that takes a changeset, as OpenStreetMap does, and
/// remembers what it was asked.
class _Server {
  final HttpServer _server;
  final asked = <String>[];
  final bodies = <String>[];
  final tokens = <String?>[];
  int refuseUpload = 0;

  _Server._(this._server) {
    _server.listen((request) async {
      final body = await utf8.decoder.bind(request).join();
      final path = request.uri.path.replaceFirst('/api/0.6/', '');
      asked.add('${request.method} $path');
      bodies.add(body);
      tokens.add(request.headers.value(HttpHeaders.authorizationHeader));
      final response = request.response;
      if (path == 'changeset/create') {
        response.write('42');
      } else if (path == 'changeset/42/upload' && refuseUpload != 0) {
        response.statusCode = refuseUpload;
        response.write('Version mismatch');
      } else if (path == 'user/details.json') {
        response.write(jsonEncode({
          'user': {'display_name': 'Some One'},
        }));
      }
      await response.close();
    });
  }

  static Future<_Server> start() async =>
      _Server._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  Uri get base => Uri.parse('http://127.0.0.1:${_server.port}/api/0.6/');

  Future<void> stop() => _server.close(force: true);
}

OsmUpload _oneNode() {
  final history = editorOf()..createNode(latitude: 1, longitude: 2);
  return history.history.toUpload();
}

void main() {
  late _Server server;
  late OsmApiClient client;

  setUp(() async {
    server = await _Server.start();
    client = OsmApiClient(
      base: server.base,
      token: 'secret',
      createdBy: 'my-editor/1.0',
    );
  });
  tearDown(() async {
    client.close();
    await server.stop();
  });

  test('opens a changeset, uploads to it and closes it', () async {
    final changeset = await client.upload(_oneNode(), comment: 'Add a node');
    expect(changeset, 42);
    expect(server.asked, [
      'PUT changeset/create',
      'POST changeset/42/upload',
      'PUT changeset/42/close',
    ]);
    expect(server.tokens, everyElement('Bearer secret'));
    expect(server.bodies.first, contains('v="Add a node"'));
    expect(server.bodies.first, contains('v="my-editor/1.0"'));
  });

  test('closes the changeset when the upload is refused', () async {
    server.refuseUpload = HttpStatus.conflict;
    await expectLater(
      client.upload(_oneNode(), comment: 'Add a node'),
      throwsA(isA<OsmUploadException>()
          .having((e) => e.status, 'status', HttpStatus.conflict)),
    );
    expect(server.asked.last, 'PUT changeset/42/close');
  });

  test('says who is signed in', () async {
    expect(await client.displayName(), 'Some One');
  });

  test('writes nothing with nobody signed in', () async {
    client.token = null;
    expect(
      () => client.upload(_oneNode(), comment: 'Add a node'),
      throwsStateError,
    );
    expect(() => client.displayName(), throwsStateError);
    expect(server.asked, isEmpty);
  });

  test('sends nothing without a change or a comment', () async {
    await expectLater(
      client.upload(editorOf().history.toUpload(), comment: 'Nothing'),
      throwsA(isA<OsmUploadException>()),
    );
    await expectLater(
      client.upload(_oneNode(), comment: '  '),
      throwsA(isA<OsmUploadException>()),
    );
    expect(server.asked, isEmpty);
  });
}
