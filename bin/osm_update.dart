import 'dart:io';

import 'package:osm/osm.dart';

const _usage = '''
Brings an OpenStreetMap snapshot up to date.

  dart run osm:osm_update <snapshot.osm.pbf> [options]

Reads the planet's replication diffs published since the snapshot's own
timestamp, keeps the changes that touch what the snapshot holds, and writes
the snapshot back with them applied.

Options:
  --output <file>    Write here instead of over the snapshot.
  --cache <dir>      Keep downloaded diffs here, so a run that stops can
                     start again without fetching them twice.
                     Default: a directory beside the snapshot.
  --contact <text>   Who to tell OpenStreetMap is asking, such as a name and
                     an address. Its servers ask for this; nothing is sent
                     unless you give it.
  --no-lookups       Do not ask the OpenStreetMap API for what the diffs
                     cannot supply. Exits with 2 if anything is missing,
                     which means a fresh snapshot is due.
  -h, --help         Show this.
''';

Future<void> main(List<String> arguments) async {
  String? snapshot, output, cache, contact;
  var lookups = true;

  for (var i = 0; i < arguments.length; i++) {
    final argument = arguments[i];
    String value() {
      if (i + 1 >= arguments.length) _fail('$argument needs a value');
      return arguments[++i];
    }

    switch (argument) {
      case '-h' || '--help':
        stdout.write(_usage);
        return;
      case '--output':
        output = value();
      case '--cache':
        cache = value();
      case '--contact':
        contact = value();
      case '--no-lookups':
        lookups = false;
      default:
        if (argument.startsWith('-')) _fail('Unknown option $argument');
        if (snapshot != null) _fail('Only one snapshot at a time');
        snapshot = argument;
    }
  }
  if (snapshot == null) _fail('Which snapshot?');

  final target = output ?? snapshot;
  // Written beside the target and moved over it once whole, so a run that
  // fails part way leaves the snapshot as it was.
  final writing = '$target.updating';

  try {
    final result = await OsmPbfUpdater(
      replication: OsmReplication(contact: contact),
      cache: Directory(cache ?? '$snapshot.diffs'),
      client: lookups ? OsmApiClient(contact: contact) : null,
      onProgress: stdout.writeln,
    ).update(
      input: snapshot,
      output: writing,
    );
    await File(writing).rename(target);
    _report(result, target);
    if (result.incomplete) exitCode = 2;
  } on OsmException catch (e) {
    stderr.writeln(e.message);
    exitCode = 1;
  } on StateError catch (e) {
    stderr.writeln(e.message);
    exitCode = 1;
  } on IOException catch (e) {
    stderr.writeln(e);
    exitCode = 1;
  } finally {
    final left = File(writing);
    if (await left.exists()) await left.delete();
  }
}

void _report(OsmUpdateResult result, String target) {
  final counts = result.counts;
  final edges = result.edges;
  stdout
    ..writeln()
    ..writeln('Wrote $target'
        '${result.state == null ? '' : ', up to ${result.state!.timestamp}'}.')
    ..writeln('  ${result.diffs.length} diff(s), ${result.kept} of '
        '${result.seen} changes kept')
    ..writeln('  ${counts.created} created, ${counts.modified} modified, '
        '${counts.deleted} deleted, ${counts.stale} already had, '
        '${counts.missed} missed');

  if (edges.isEmpty) return;
  stdout.writeln('At the edge of the snapshot:');
  void list(String what, Set<int> ids) {
    if (ids.isEmpty) return;
    stdout.writeln(
        '  $what (${ids.length}): ${(ids.toList()..sort()).join(', ')}');
  }

  list('nodes moved in', edges.movedInNodes);
  list('ways moved in', edges.movedInWays);
  list('nodes moved out, kept', edges.movedOutNodes);
  list('ways moved out, kept', edges.movedOutWays);
  list('ways reaching past the edge', edges.incompleteWays);
  list('nodes those ways need', edges.missingNodes);

  if (result.lookedUp) {
    stdout.writeln('  looked up ${result.lookedUpNodes} node(s) and '
        '${result.lookedUpWays} way(s) in ${result.requests} request(s)');
  } else if (result.incomplete) {
    stdout.writeln('Not looked up, so the snapshot is missing them. Download '
        'a fresh one, or run again without --no-lookups.');
  }
}

Never _fail(String message) {
  stderr
    ..writeln(message)
    ..writeln()
    ..write(_usage);
  exit(64);
}
