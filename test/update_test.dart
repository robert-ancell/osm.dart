import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:osm/osm.dart';
import 'package:test/test.dart';

late Directory _work;

/// A replication feed held in memory: [minutes] and [hours] map a sequence
/// to the moment its diff runs up to, and [diffs] to what it holds.
class _Feed {
  final Map<int, DateTime> minutes;
  final Map<int, DateTime> hours;
  final Map<String, String> diffs;
  final List<Uri> asked = [];

  _Feed({required this.minutes, this.hours = const {}, this.diffs = const {}});

  Future<Uint8List?> fetch(
    Uri uri, {
    Future<void>? abandon,
    void Function(Uint8List body)? onLate,
  }) async {
    asked.add(uri);
    final path = uri.path;
    for (final (name, times) in [('minute', minutes), ('hour', hours)]) {
      if (!path.contains('/$name/')) continue;
      if (path.endsWith('/$name/state.txt')) {
        final newest = times.keys.reduce((a, b) => a > b ? a : b);
        return _state(newest, times[newest]!);
      }
      final match = RegExp(r'(\d{3})/(\d{3})/(\d{3})\.(state\.txt|osc\.gz)$')
          .firstMatch(path);
      if (match == null) return null;
      final sequence = int.parse(
        '${match.group(1)}${match.group(2)}${match.group(3)}',
      );
      if (match.group(4) == 'state.txt') {
        final at = times[sequence];
        return at == null ? null : _state(sequence, at);
      }
      final xml = diffs['$name/$sequence'];
      return xml == null
          ? null
          : Uint8List.fromList(gzip.encode(utf8.encode(xml)));
    }
    return null;
  }

  static Uint8List _state(int sequence, DateTime at) => Uint8List.fromList(
        utf8.encode(
          '#written by a test\n'
          'sequenceNumber=$sequence\n'
          'timestamp=${at.toIso8601String().split('.').first.replaceAll(':', r'\:')}Z\n',
        ),
      );
}

final _t0 = DateTime.utc(2026, 1, 1);

/// The hand written elements, in order, saying they are from [_t0].
Future<String> _snapshot() async {
  final source = await OsmPbfFile.open('test/data/elements.osm.pbf');
  final path = '${_work.path}/snapshot.osm.pbf';
  final writer = await OsmPbfWriter.create(
    path,
    header: OsmPbfHeader(
      optionalFeatures: const ['Sort.Type_then_ID'],
      replicationTimestamp: _t0,
    ),
  );
  await writer.addAll(source.elements());
  await writer.close();
  return path;
}

void main() {
  setUp(() => _work = Directory.systemTemp.createTempSync('osm_update'));
  tearDown(() => _work.deleteSync(recursive: true));

  group('replication', () {
    test('reads a state file, escaped colons and all', () {
      final state = OsmReplicationState.parse(
        '#Wed Sep 09 23:28:47 UTC 2026\n'
        'sequenceNumber=7280000\n'
        r'timestamp=2026-09-09T23\:28\:18Z'
        '\n',
      );
      expect(state.sequence, 7280000);
      expect(state.timestamp, DateTime.utc(2026, 9, 9, 23, 28, 18));
    });

    test('lays sequences out the way the feed does', () {
      expect(OsmReplication.sequencePath(7289011), '007/289/011');
      expect(OsmReplication.sequencePath(5), '000/000/005');
    });

    test('finds the first diff after a moment', () async {
      final feed = _Feed(
        minutes: {
          for (var s = 0; s <= 5000; s++) s: _t0.add(Duration(minutes: s)),
        },
      );
      final replication = OsmReplication(fetch: feed.fetch);
      final period = OsmReplicationPeriod.minute;

      expect(
        await replication.firstAfter(
            period, _t0.add(const Duration(minutes: 1234))),
        1235,
      );
      // Between two diffs' ends: the one that runs past it.
      expect(
        await replication.firstAfter(
          period,
          _t0.add(const Duration(minutes: 1234, seconds: 30)),
        ),
        1235,
      );
      expect(
          await replication.firstAfter(
              period, _t0.subtract(const Duration(days: 1))),
          0);
      expect(
        await replication.firstAfter(period, _t0.add(const Duration(days: 30))),
        5001,
        reason: 'nothing yet',
      );
      expect(feed.asked.length, lessThan(60), reason: 'a search, not a walk');
    });

    test('finds it when the feed has gaps in its timing', () async {
      // Diffs that each run longer than a period, which throws the guess off.
      final feed = _Feed(
        minutes: {
          for (var s = 0; s <= 400; s++) s: _t0.add(Duration(minutes: s * 3)),
        },
      );
      final replication = OsmReplication(fetch: feed.fetch);
      expect(
        await replication.firstAfter(
          OsmReplicationPeriod.minute,
          _t0.add(const Duration(minutes: 301)),
        ),
        101,
      );
    });

    test('says when the feed no longer goes back far enough', () async {
      // A feed that has thrown away everything before diff 100.
      final feed = _Feed(
        minutes: {
          for (var s = 100; s <= 200; s++) s: _t0.add(Duration(minutes: s)),
        },
      );
      final replication = OsmReplication(fetch: feed.fetch);
      expect(
        await replication.firstAfter(
          OsmReplicationPeriod.minute,
          _t0.add(const Duration(minutes: 150)),
        ),
        151,
      );
      await expectLater(
        replication.firstAfter(
          OsmReplicationPeriod.minute,
          _t0.add(const Duration(minutes: 20)),
        ),
        throwsA(isA<OsmReplicationException>()),
      );
    });

    test('keeps what it downloads and does not fetch it twice', () async {
      final feed = _Feed(
        minutes: {1: _t0},
        diffs: {'minute/1': '<osmChange version="0.6"/>'},
      );
      final replication = OsmReplication(fetch: feed.fetch);
      final first = await replication.download(
        OsmReplicationPeriod.minute,
        1,
        _work,
      );
      final asked = feed.asked.length;
      final second = await replication.download(
        OsmReplicationPeriod.minute,
        1,
        _work,
      );
      expect(second.path, first.path);
      expect(feed.asked.length, asked);
      expect(await OsmChangeFile.read(first.path), isEmpty);
    });
  });

  group('a feed of one period', () {
    // Geofabrik's: state.txt and the diffs straight under the extract's
    // directory, a day to a diff.
    final days = {
      for (var s = 4900; s <= 4911; s++) s: _t0.add(Duration(days: s - 4900)),
    };
    Future<Uint8List?> fetch(
      Uri uri, {
      Future<void>? abandon,
      void Function(Uint8List body)? onLate,
    }) async {
      final path = uri.path;
      if (!path.startsWith('/australia-oceania/new-zealand-updates/')) {
        return null;
      }
      if (path.endsWith('-updates/state.txt')) {
        return _Feed._state(4911, days[4911]!);
      }
      final match =
          RegExp(r'-updates/(\d{3})/(\d{3})/(\d{3})\.(state\.txt|osc\.gz)$')
              .firstMatch(path);
      if (match == null) return null;
      final sequence =
          int.parse('${match.group(1)}${match.group(2)}${match.group(3)}');
      final at = days[sequence];
      if (at == null) return null;
      return match.group(4) == 'state.txt'
          ? _Feed._state(sequence, at)
          : Uint8List.fromList(
              gzip.encode(utf8.encode('<osmChange version="0.6"/>')));
    }

    final replication =
        OsmReplication.geofabrik('australia-oceania/new-zealand', fetch: fetch);
    const day = OsmReplicationPeriod.day;

    test('is laid out under its own directory', () {
      expect(
        replication.diff(day, 4911).toString(),
        'https://download.geofabrik.de/australia-oceania/'
        'new-zealand-updates/000/004/911.osc.gz',
      );
    });

    test('says where it has got to', () async {
      expect((await replication.latest(day)).sequence, 4911);
    });

    test('finds the first diff after a moment', () async {
      expect(
        await replication.firstAfter(
            day, _t0.add(const Duration(days: 5, hours: 3))),
        4906,
      );
    });

    test('and downloads it', () async {
      final file = await replication.download(day, 4906, _work);
      expect(await OsmChangeFile.read(file.path), isEmpty);
    });

    test('has no other period', () {
      expect(() => replication.feed(OsmReplicationPeriod.minute),
          throwsArgumentError);
    });
  });

  group('api', () {
    Uint8List xml(String body) => Uint8List.fromList(
          utf8.encode('<?xml version="1.0"?><osm version="0.6">$body</osm>'),
        );

    test("lists a mapper's changesets since a moment", () async {
      late Uri asked;
      final api = OsmApi(fetch: (uri, {abandon, onLate}) async {
        asked = uri;
        return xml(
          '<changeset id="12" created_at="2026-09-17T08:00:00Z" '
          'open="true" changes_count="3" user="Someone"/>'
          '<changeset id="11" created_at="2026-09-17T06:00:00Z" '
          'closed_at="2026-09-17T06:01:00Z" open="false" '
          'changes_count="40" user="Someone"/>',
        );
      });
      final changesets = await api.changesetsBy(
        'Some One',
        since: DateTime.utc(2026, 9, 16, 20, 21),
      );

      expect(asked.path, '/api/0.6/changesets');
      expect(asked.queryParameters, {
        'display_name': 'Some One',
        'time': '2026-09-16T20:21:00.000Z',
        'limit': '100',
      });
      expect(changesets.map((c) => c.id), [12, 11]);
      expect(changesets.first.isOpen, isTrue);
      expect(changesets.last.closedAt, DateTime.utc(2026, 9, 17, 6, 1));
      expect(changesets.last.changesCount, 40);
    });

    test('and pages through more than the API lists at once', () async {
      final asked = <Uri>[];
      final api = OsmApi(fetch: (uri, {abandon, onLate}) async {
        asked.add(uri);
        final before = uri.queryParameters['time']!.split(',').skip(1);
        // 150 changesets, an hour apart, the newest first; 100 a page.
        final top = before.isEmpty
            ? 150
            : DateTime.parse(before.single)
                .difference(DateTime.utc(2026))
                .inHours;
        return xml([
          for (var id = top; id > 0 && id > top - 100; id--)
            '<changeset id="$id" '
                'created_at="${DateTime.utc(2026).add(Duration(hours: id)).toIso8601String()}" '
                'closed_at="${DateTime.utc(2026).add(Duration(hours: id)).toIso8601String()}" '
                'changes_count="1"/>',
        ].join());
      });
      final changesets =
          await api.changesetsBy('Some One', since: DateTime.utc(2025));
      expect(
          changesets.map((c) => c.id), [for (var id = 150; id > 0; id--) id]);
      expect(asked, hasLength(2));
    });

    test('says when there is no such mapper', () async {
      final api = OsmApi(fetch: (uri, {abandon, onLate}) async => null);
      await expectLater(
        api.changesetsBy('Nobody', since: DateTime.utc(2026)),
        throwsA(isA<OsmHttpException>()),
      );
    });

    test('reads what a changeset changed', () async {
      late Uri asked;
      final api = OsmApi(fetch: (uri, {abandon, onLate}) async {
        asked = uri;
        return Uint8List.fromList(utf8.encode(
          '<osmChange version="0.6">'
          '<modify><node id="5" version="2" lat="1" lon="2" '
          'changeset="12"/></modify>'
          '<delete><way id="7" version="3" changeset="12"/></delete>'
          '</osmChange>',
        ));
      });
      final changes = await api.changesetChanges(12);

      expect(asked.path, '/api/0.6/changeset/12/download');
      expect(changes.map((c) => (c.action, c.type, c.id, c.version)), [
        (OsmChangeAction.modify, OsmElementType.node, 5, 2),
        (OsmChangeAction.delete, OsmElementType.way, 7, 3),
      ]);
    });

    test('looks nodes up, leaving out the deleted', () async {
      final api = OsmApi(
        fetch: (uri, {abandon, onLate}) async => xml(
          '<node id="1" visible="true" version="3" lat="-41.1" lon="174.1">'
          '<tag k="a" v="b"/></node>'
          '<node id="2" visible="false" version="4"/>',
        ),
      );
      final nodes = await api.nodes([2, 1]);
      expect(nodes.map((n) => n.id), [1]);
      expect(nodes.single.tags, {'a': 'b'});
      expect(nodes.single.info?.version, 3);
    });

    test('halves a batch refused for an id that never existed', () async {
      final asked = <String>[];
      final api = OsmApi(
        fetch: (uri, {abandon, onLate}) async {
          final ids = uri.queryParameters['nodes']!.split(',').map(int.parse);
          asked.add(ids.join(','));
          if (ids.contains(999)) return null;
          return xml([
            for (final id in ids)
              '<node id="$id" visible="true" version="1" lat="0" lon="0"/>',
          ].join());
        },
      );
      final nodes = await api.nodes([1, 2, 999, 3]);
      expect(nodes.map((n) => n.id).toList()..sort(), [1, 2, 3]);
      expect(asked.first, '1,2,3,999');
      expect(api.requests, asked.length);
    });

    test('looks up the ways of a node', () async {
      final api = OsmApi(
        fetch: (uri, {abandon, onLate}) async {
          expect(uri.path, endsWith('/node/5/ways'));
          return xml(
            '<way id="50" visible="true" version="2">'
            '<nd ref="5"/><nd ref="6"/></way>',
          );
        },
      );
      final ways = await api.waysOf(5);
      expect(ways.single.nodeIds, [5, 6]);
    });
  });

  group('updating a snapshot', () {
    test('applies what touches it and nothing else', () async {
      final input = await _snapshot();
      final far = '''
<osmChange version="0.6">
  <create>
    <node id="90000001" version="1" lat="51.5" lon="-0.12"/>
    <way id="90000801" version="1"><nd ref="90000001"/><nd ref="90000002"/></way>
  </create>
</osmChange>''';
      final feed = _Feed(
        minutes: {
          10: _t0.subtract(const Duration(minutes: 1)),
          11: _t0.add(const Duration(minutes: 1)),
          12: _t0.add(const Duration(minutes: 2)),
        },
        hours: {1: _t0.subtract(const Duration(hours: 1))},
        diffs: {
          'minute/11': File('test/data/changes.osc').readAsStringSync(),
          'minute/12': far,
        },
      );
      final output = '${_work.path}/updated.osm.pbf';

      final result = await updateOsmSnapshot(
        input: input,
        output: output,
        replication: OsmReplication(fetch: feed.fetch),
        cache: Directory('${_work.path}/cache'),
      );

      expect(result.diffs, [
        (OsmReplicationPeriod.minute, 11),
        (OsmReplicationPeriod.minute, 12),
      ]);
      expect(result.seen, 8);
      expect(result.kept, 6, reason: 'the two London changes are not');
      expect(result.counts.created, 2);
      expect(result.counts.modified, 2);
      expect(result.counts.deleted, 2);
      expect(result.state?.sequence, 12);
      expect(result.incomplete, isFalse);

      final updated = await OsmPbfFile.open(output);
      final ids = await updated
          .elements()
          .map((e) => '${e.type.name}/${e.id}')
          .toList();
      expect(ids, contains('node/42000006'));
      expect(ids, isNot(contains('node/90000001')));
      expect(ids, isNot(contains('node/42000003')));
      expect(updated.header.replicationSequenceNumber, 12);
      expect(updated.header.replicationTimestamp, feed.minutes[12]);
      expect(updated.header.isSorted, isTrue);
    });

    test('reads a diff that lists a way before its nodes', () async {
      // The planet never writes one like this, but a diff from elsewhere
      // might. The way only touches the snapshot through the nodes after it.
      final input = await _snapshot();
      final feed = _Feed(
        minutes: {
          1: _t0.subtract(const Duration(minutes: 1)),
          2: _t0.add(const Duration(minutes: 1)),
        },
        hours: {1: _t0.subtract(const Duration(hours: 1))},
        diffs: {
          'minute/2': '''
<osmChange version="0.6">
  <create>
    <way id="42000805" version="1">
      <nd ref="42000010"/><nd ref="42000011"/>
    </way>
    <node id="42000010" version="1" lat="0.5001" lon="0.5001"/>
    <node id="42000011" version="1" lat="0.5002" lon="0.5002"/>
  </create>
</osmChange>''',
        },
      );
      final output = '${_work.path}/updated.osm.pbf';

      final result = await updateOsmSnapshot(
        input: input,
        output: output,
        replication: OsmReplication(fetch: feed.fetch),
        cache: Directory('${_work.path}/cache'),
      );
      expect(result.seen, 3, reason: 'counted once, not once per read');
      expect(result.kept, 3);
      expect(result.edges.isEmpty, isTrue);

      final ids = await (await OsmPbfFile.open(output))
          .elements()
          .map((e) => '${e.type.name}/${e.id}')
          .toList();
      expect(ids, containsAll(['node/42000010', 'way/42000805']));
    });

    test('says what it could not settle when it may not look it up', () async {
      final input = await _snapshot();
      final feed = _Feed(
        minutes: {
          1: _t0.subtract(const Duration(minutes: 1)),
          2: _t0.add(const Duration(minutes: 1)),
        },
        hours: {1: _t0.subtract(const Duration(hours: 1))},
        diffs: {
          'minute/2': '''
<osmChange version="0.6">
  <create>
    <way id="42000804" version="1">
      <nd ref="42000001"/><nd ref="77000001"/>
    </way>
  </create>
</osmChange>''',
        },
      );

      final result = await updateOsmSnapshot(
        input: input,
        output: '${_work.path}/updated.osm.pbf',
        replication: OsmReplication(fetch: feed.fetch),
        cache: Directory('${_work.path}/cache'),
      );
      expect(result.edges.incompleteWays, {42000804});
      expect(result.edges.missingNodes, {77000001});
      expect(result.incomplete, isTrue);
    });

    test('looks up what it could not settle when it may', () async {
      final input = await _snapshot();
      final feed = _Feed(
        minutes: {
          1: _t0.subtract(const Duration(minutes: 1)),
          2: _t0.add(const Duration(minutes: 1)),
        },
        hours: {1: _t0.subtract(const Duration(hours: 1))},
        diffs: {
          'minute/2': '''
<osmChange version="0.6">
  <create>
    <way id="42000804" version="1">
      <nd ref="42000001"/><nd ref="77000001"/>
    </way>
  </create>
</osmChange>''',
        },
      );
      final api = OsmApi(
        fetch: (uri, {abandon, onLate}) async => Uint8List.fromList(
          utf8.encode(
            '<osm version="0.6"><node id="77000001" visible="true" '
            'version="5" lat="0.51" lon="0.51"/></osm>',
          ),
        ),
      );
      final output = '${_work.path}/updated.osm.pbf';

      final result = await updateOsmSnapshot(
        input: input,
        output: output,
        replication: OsmReplication(fetch: feed.fetch),
        cache: Directory('${_work.path}/cache'),
        api: api,
      );
      expect(result.lookedUpNodes, 1);
      expect(result.incomplete, isFalse);

      final updated = await OsmPbfFile.open(output);
      final way = await updated.elements().firstWhere((e) => e.id == 42000804)
          as OsmWay;
      final subset = await updated.subset(
        OsmFilter.ids(OsmElementType.way, {way.id}),
      );
      expect(subset.nodesOf(way), isNotNull, reason: 'whole again');
    });

    test('refuses a snapshot that does not say when it is from', () async {
      final path = '${_work.path}/undated.osm.pbf';
      await (await OsmPbfWriter.create(
        path,
        header: const OsmPbfHeader(optionalFeatures: ['Sort.Type_then_ID']),
      ))
          .close();
      await expectLater(
        updateOsmSnapshot(
          input: path,
          output: '${_work.path}/out.osm.pbf',
          replication:
              OsmReplication(fetch: (_, {abandon, onLate}) async => null),
          cache: _work,
        ),
        throwsA(isA<OsmReplicationException>()),
      );
    });
  });
}
