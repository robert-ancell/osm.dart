import 'dart:io';

import '../element.dart';
import '../pbf/apply.dart';
import '../pbf/file.dart';
import '../version.g.dart';
import '../xml/change.dart';
import 'api.dart';
import 'change_filter.dart';
import 'replication.dart';
import 'snapshot_index.dart';

/// What bringing a snapshot up to date did.
class OsmUpdateResult {
  /// The diffs read, oldest first.
  final List<(OsmReplicationPeriod, int)> diffs;

  /// How many changes they held, and how many were kept.
  final int seen, kept;

  /// What applying the kept changes did.
  final OsmChangeCounts counts;

  /// What happened at the edge of the snapshot.
  final OsmUpdateEdges edges;

  /// Elements looked up to settle the edges, if lookups were made.
  final int lookedUpNodes, lookedUpWays, requests;

  /// Whether the edges were looked up at all.
  final bool lookedUp;

  /// Where the updated file now stands.
  final OsmReplicationState? state;

  /// Creates a result.
  const OsmUpdateResult({
    required this.diffs,
    required this.seen,
    required this.kept,
    required this.counts,
    required this.edges,
    required this.lookedUpNodes,
    required this.lookedUpWays,
    required this.requests,
    required this.lookedUp,
    required this.state,
  });

  /// Whether the updated file is missing things the changes could not
  /// supply: true only when there was something to look up and it was not.
  bool get incomplete =>
      !lookedUp &&
      (edges.missingNodes.isNotEmpty || edges.movedInNodes.isNotEmpty);
}

/// Brings the snapshot at [input] up to date and writes it to [output].
///
/// Reads the replication diffs published since the snapshot's own timestamp,
/// hours first and then minutes, keeps the changes that touch what the
/// snapshot holds, and applies them.
///
/// What the changes cannot settle — the nodes of a way reaching past the edge
/// of the snapshot, the ways of a node that moved in — is looked up through
/// [api], or, with none, left for [OsmUpdateResult.incomplete] to report. A
/// snapshot that keeps coming back incomplete is due a fresh download.
///
/// The file written carries the planet's replication state, so the next
/// update starts where this one finished.
///
/// The diffs are kept in [cache], as [OsmReplication.download] keeps them,
/// so an update that stops part way does not fetch them again.
Future<OsmUpdateResult> updateOsmSnapshot({
  required String input,
  required String output,
  required OsmReplication replication,
  Directory? cache,
  OsmApiClient? api,
  void Function(String message)? onProgress,
}) async {
  void say(String message) => onProgress?.call(message);

  final file = await OsmPbfFile.open(input);
  final since = file.header.replicationTimestamp;
  if (since == null) {
    throw OsmReplicationException(
      '$input does not say when its data is from, so there is no knowing '
      'which changes it is missing',
    );
  }

  say('Reading what $input holds...');
  final index = await OsmSnapshotIndex.read(file);
  say('  ${index.nodes.length} nodes, ${index.ways.length} ways, '
      '${index.relations.length} relations, over ${index.region}');

  final filter = OsmChangeFilter(index);
  final diffs = <(OsmReplicationPeriod, int)>[];
  var from = since;
  OsmReplicationState? reached;

  for (final period in [
    OsmReplicationPeriod.hour,
    OsmReplicationPeriod.minute
  ]) {
    final first = await replication.firstAfter(period, from);
    final newest = await replication.latest(period);
    if (first > newest.sequence) continue;

    say('Reading ${newest.sequence - first + 1} ${period.name} diff(s), '
        '$first to ${newest.sequence}...');
    for (var sequence = first; sequence <= newest.sequence; sequence++) {
      final diff = await replication.download(period, sequence, cache);
      await _decide(filter, diff.path);
      diffs.add((period, sequence));
    }
    from = newest.timestamp;
    reached = period == OsmReplicationPeriod.minute ? newest : reached;
  }
  say('  kept ${filter.kept.length} of ${filter.seen} changes');

  final edges = filter.edges;
  final lookedUp = <OsmChange>[];
  var lookedUpNodes = 0, lookedUpWays = 0;
  if (api != null && !edges.isEmpty) {
    // The ways of a node that moved in were never in the changes, if they
    // were not themselves changed.
    final wanted = {...edges.missingNodes};
    for (final node in edges.movedInNodes) {
      for (final way in await api.waysOf(node)) {
        if (index.ways.contains(way.id)) continue;
        lookedUp.add(_create(way));
        lookedUpWays++;
        wanted.addAll(way.nodeIds.where((id) => !index.nodes.contains(id)));
      }
    }
    if (wanted.isNotEmpty) {
      say('Looking up ${wanted.length} node(s) past the edge...');
      for (final node in await api.nodes(wanted)) {
        lookedUp.add(_create(node));
        lookedUpNodes++;
      }
    }
  }

  say('Writing $output...');
  final counts = await applyOsmChanges(
    input: input,
    changes: [...filter.kept, ...lookedUp],
    output: output,
    header: file.header.copyWith(
      replicationBaseUrl: reached == null
          ? null
          : replication.feed(OsmReplicationPeriod.minute).toString(),
      replicationSequenceNumber: reached?.sequence,
      replicationTimestamp: reached?.timestamp,
      writingProgram: 'osm/$packageVersion',
    ),
  );

  return OsmUpdateResult(
    diffs: diffs,
    seen: filter.seen,
    kept: filter.kept.length,
    counts: counts,
    edges: edges,
    lookedUpNodes: lookedUpNodes,
    lookedUpWays: lookedUpWays,
    requests: api?.requests ?? 0,
    lookedUp: api != null,
    state: reached,
  );
}

/// Decides the changes of the diff at [path] without holding it.
///
/// A diff's nodes have to be decided before its ways, which can use nodes the
/// same diff makes, and its ways before its relations. The planet's diffs are
/// written in that order — every one of sixty checked lists all its nodes,
/// then all its ways, then all its relations, whatever the create, modify and
/// delete around them — so the file is read once and decided as it goes.
///
/// If a type does come back after a later one, what this file did to the
/// filter is undone and it is read again twice over: once for the nodes, then
/// for the rest, holding only the relations until the ways are all decided.
/// Always reading twice costs a quarter again on a country's update; holding
/// an hour of the planet whole costs close to a gigabyte.
Future<void> _decide(OsmChangeFilter filter, String path) async {
  final mark = filter.mark();
  var last = 0;
  var ordered = true;
  await for (final change in OsmChangeFile.stream(path)) {
    if (change.type.index < last) {
      ordered = false;
      break;
    }
    last = change.type.index;
    filter.add(change);
  }
  if (ordered) return;

  filter.restore(mark);
  await for (final change in OsmChangeFile.stream(path)) {
    if (change.type == OsmElementType.node) filter.add(change);
  }
  final relations = <OsmChange>[];
  await for (final change in OsmChangeFile.stream(path)) {
    switch (change.type) {
      case OsmElementType.node:
        break;
      case OsmElementType.way:
        filter.add(change);
      case OsmElementType.relation:
        relations.add(change);
    }
  }
  relations.forEach(filter.add);
}

OsmChange _create(OsmElement element) => OsmChange(
      action: OsmChangeAction.create,
      type: element.type,
      id: element.id,
      version: element.info?.version,
      element: element,
    );
