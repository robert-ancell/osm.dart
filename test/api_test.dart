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

  Future<Uint8List?> fetch(
    Uri uri, {
    Future<void>? abandon,
    void Function(Uint8List body)? onLate,
  }) async {
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
    final client = OsmApiClient(fetch: server.fetch);
    final capabilities = await client.capabilities();
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
    final capabilities = await OsmApiClient(fetch: server.fetch).capabilities();
    expect(capabilities.online, isFalse);
    expect(capabilities.writable, isFalse);
  });

  test('sees that the API is readable but not writable', () async {
    final server = _Api(answers: {
      'capabilities':
          _capabilities.replaceAll('api="online"', 'api="readonly"'),
    });
    final capabilities = await OsmApiClient(fetch: server.fetch).capabilities();
    expect(capabilities.online, isTrue);
    expect(capabilities.writable, isFalse);
  });

  test('reads a box of the map', () async {
    final server = _Api(answers: {'map': _map});
    final elements = await OsmApiClient(fetch: server.fetch).map(_bounds);
    expect(elements.whereType<OsmNode>().length, 2);
    expect(elements.whereType<OsmWay>().length, 1);
    expect(elements.whereType<OsmWay>().single.nodeIds, [1, 2]);
  });

  test('asks for the box the way the API wants it', () async {
    final server = _Api(answers: {'map': _map});
    await OsmApiClient(fetch: server.fetch).map(_bounds);
    expect(
      server.asked.single.queryParameters['bbox'],
      '174.76,-36.85,174.77,-36.84',
    );
  });

  test('reports a box the API will not answer', () async {
    final server = _Api(refuse: {'map': HttpStatus.badRequest});
    expect(
      () => OsmApiClient(fetch: server.fetch).map(_bounds),
      throwsA(isA<OsmTooMuchDataException>()),
    );
  });

  test('passes on a failure that asking for less will not fix', () async {
    final server = _Api(refuse: {'map': HttpStatus.internalServerError});
    expect(
      () => OsmApiClient(fetch: server.fetch).map(_bounds),
      throwsA(isA<OsmHttpException>()),
    );
  });

  test('reads an empty box as empty rather than as missing', () async {
    final server = _Api();
    expect(await OsmApiClient(fetch: server.fetch).map(_bounds), isEmpty);
  });

  test('counts what it asked for', () async {
    final server = _Api(answers: {'map': _map, 'capabilities': _capabilities});
    final client = OsmApiClient(fetch: server.fetch);
    await client.capabilities();
    await client.map(_bounds);
    await client.map(_bounds);
    expect(client.requests, 3);
  });
  test('reads the ground a changeset touched', () async {
    final server = _Api(answers: {'changesets': _changesets});
    final found = await OsmApiClient(fetch: server.fetch)
        .changesetsIn(_bounds, since: DateTime.utc(2026));
    expect(found, isNotNull);
    expect(found!.length, 2);
    expect(found.first.bounds!.minLatitude, -36.848);
    expect(found.last.bounds, isNull);
  });

  test('asks for changesets over the box and since the time', () async {
    final server = _Api(answers: {'changesets': _changesets});
    await OsmApiClient(fetch: server.fetch)
        .changesetsIn(_bounds, since: DateTime.utc(2026, 9, 16));
    final query = server.asked.single.queryParameters;
    expect(query['bbox'], '174.76,-36.85,174.77,-36.84');
    expect(query['time'], '2026-09-16T00:00:00.000Z');
  });

  test('gives up on an area with more changesets than it will take', () async {
    final server = _Api(answers: {'changesets': _fullPage});
    final found = await OsmApiClient(fetch: server.fetch)
        .changesetsIn(_bounds, since: DateTime.utc(2026), limit: 150);
    // Every page comes back full, so there is no end to reach: the area is
    // too far behind to patch and has to be read again instead.
    expect(found, isNull);
  });
}

const _changesets = '''
<?xml version="1.0" encoding="UTF-8"?>
<osm version="0.6">
  <changeset id="1" created_at="2026-09-18T06:59:56Z" open="false"
    closed_at="2026-09-18T07:59:57Z" changes_count="3"
    min_lat="-36.848" min_lon="174.754" max_lat="-36.847" max_lon="174.755"/>
  <changeset id="2" created_at="2026-09-17T06:59:56Z" open="false"
    closed_at="2026-09-17T07:59:57Z" changes_count="1"/>
</osm>
''';

/// A page with nothing left over, so the caller keeps asking for more.
///
/// Each changeset needs its own id and a created time a second apart, or the
/// caller sees the same ones again and stops.
String get _fullPage {
  final buffer = StringBuffer('<osm version="0.6">');
  for (var i = 0; i < 100; i++) {
    final id = _served++;
    final at = DateTime.utc(2026, 9, 18).subtract(Duration(seconds: id));
    buffer.write(
      '<changeset id="$id" created_at="${at.toIso8601String()}" '
      'open="false" closed_at="${at.toIso8601String()}" changes_count="1"/>',
    );
  }
  buffer.write('</osm>');
  return buffer.toString();
}

int _served = 1;
