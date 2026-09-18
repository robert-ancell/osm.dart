import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:osm/osm.dart';
import 'package:test/test.dart';

/// An API held in memory: [answers] maps the tail of a URL to the body to
/// give back, and [refuse] to the status to fail with instead.
class _Api {
  final Map<String, String> answers;
  final Map<String, int> refuse;
  final List<Uri> asked = [];

  _Api({this.answers = const {}, this.refuse = const {}});

  Future<Uint8List?> fetch(Uri uri) async {
    asked.add(uri);
    final key =
        '${uri.path.split('/').last}${uri.hasQuery ? '?${uri.query}' : ''}';
    for (final entry in refuse.entries) {
      if (key.startsWith(entry.key)) {
        throw OsmHttpException(uri, entry.value);
      }
    }
    for (final entry in answers.entries) {
      if (key.startsWith(entry.key)) {
        return Uint8List.fromList(utf8.encode(entry.value));
      }
    }
    return null;
  }
}

const _capabilities = '''
<?xml version="1.0" encoding="UTF-8"?>
<osm version="0.6">
  <api>
    <version minimum="0.6" maximum="0.6"/>
    <area maximum="0.25"/>
    <waynodes maximum="2000"/>
    <timeout seconds="300"/>
    <status database="online" api="online" gpx="online"/>
  </api>
</osm>
''';

const _map = '''
<?xml version="1.0" encoding="UTF-8"?>
<osm version="0.6">
  <bounds minlat="-36.85" minlon="174.76" maxlat="-36.84" maxlon="174.77"/>
  <node id="1" lat="-36.845" lon="174.765" version="3"/>
  <node id="2" lat="-36.846" lon="174.766" version="1"/>
  <way id="10" version="2">
    <nd ref="1"/>
    <nd ref="2"/>
    <tag k="highway" v="residential"/>
  </way>
</osm>
''';

const _bounds = OsmBounds(
  minLatitude: -36.85,
  minLongitude: 174.76,
  maxLatitude: -36.84,
  maxLongitude: 174.77,
);

void main() {
  test('reads what the API says it will do', () async {
    final server = _Api(answers: {'capabilities': _capabilities});
    final api = OsmApi(fetch: server.fetch);
    final capabilities = await api.capabilities();
    expect(capabilities.maximumArea, 0.25);
    expect(capabilities.maximumWayNodes, 2000);
    expect(capabilities.timeout, const Duration(seconds: 300));
    expect(capabilities.online, isTrue);
    expect(capabilities.writable, isTrue);
  });

  test('sees that the API has been turned off', () async {
    final server = _Api(answers: {
      'capabilities': _capabilities.replaceAll('api="online"', 'api="offline"'),
    });
    final capabilities = await OsmApi(fetch: server.fetch).capabilities();
    expect(capabilities.online, isFalse);
    expect(capabilities.writable, isFalse);
  });

  test('sees that the API is readable but not writable', () async {
    final server = _Api(answers: {
      'capabilities':
          _capabilities.replaceAll('api="online"', 'api="readonly"'),
    });
    final capabilities = await OsmApi(fetch: server.fetch).capabilities();
    expect(capabilities.online, isTrue);
    expect(capabilities.writable, isFalse);
  });

  test('reads a box of the map', () async {
    final server = _Api(answers: {'map': _map});
    final elements = await OsmApi(fetch: server.fetch).map(_bounds);
    expect(elements.whereType<OsmNode>().length, 2);
    expect(elements.whereType<OsmWay>().length, 1);
    expect(elements.whereType<OsmWay>().single.nodeIds, [1, 2]);
  });

  test('asks for the box the way the API wants it', () async {
    final server = _Api(answers: {'map': _map});
    await OsmApi(fetch: server.fetch).map(_bounds);
    expect(
      server.asked.single.queryParameters['bbox'],
      '174.76,-36.85,174.77,-36.84',
    );
  });

  test('reports a box the API will not answer', () async {
    final server = _Api(refuse: {'map': HttpStatus.badRequest});
    expect(
      () => OsmApi(fetch: server.fetch).map(_bounds),
      throwsA(isA<OsmTooMuchDataException>()),
    );
  });

  test('passes on a failure that asking for less will not fix', () async {
    final server = _Api(refuse: {'map': HttpStatus.internalServerError});
    expect(
      () => OsmApi(fetch: server.fetch).map(_bounds),
      throwsA(isA<OsmHttpException>()),
    );
  });

  test('reads an empty box as empty rather than as missing', () async {
    final server = _Api();
    expect(await OsmApi(fetch: server.fetch).map(_bounds), isEmpty);
  });

  test('counts what it asked for', () async {
    final server = _Api(answers: {'map': _map, 'capabilities': _capabilities});
    final api = OsmApi(fetch: server.fetch);
    await api.capabilities();
    await api.map(_bounds);
    await api.map(_bounds);
    expect(api.requests, 3);
  });
}
