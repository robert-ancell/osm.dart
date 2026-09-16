import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import '../exception.dart';
import 'http.dart';

/// Thrown when a replication feed cannot bring a snapshot up to date.
class OsmReplicationException implements OsmException {
  @override
  final String message;

  /// Creates an exception saying why.
  const OsmReplicationException(this.message);

  @override
  String toString() => 'OsmReplicationException: $message';
}

/// How long each diff OpenStreetMap publishes covers.
enum OsmReplicationPeriod {
  /// A minute of edits.
  minute(Duration(minutes: 1)),

  /// An hour of edits.
  hour(Duration(hours: 1)),

  /// A day of edits.
  day(Duration(days: 1));

  /// How long a diff covers.
  final Duration length;

  const OsmReplicationPeriod(this.length);
}

/// Where a replication feed had got to at one of its diffs.
class OsmReplicationState {
  /// The diff's number in its feed.
  final int sequence;

  /// The moment the diff runs up to. It holds edits after the diff before
  /// it, and up to and including this.
  final DateTime timestamp;

  /// Creates a state.
  const OsmReplicationState(this.sequence, this.timestamp);

  /// Reads a `state.txt`.
  ///
  /// It is a Java properties file, so the colons in the timestamp come
  /// escaped.
  static OsmReplicationState parse(String text) {
    final values = <String, String>{};
    for (final line in const LineSplitter().convert(text)) {
      if (line.startsWith('#')) continue;
      final equals = line.indexOf('=');
      if (equals < 0) continue;
      values[line.substring(0, equals).trim()] =
          line.substring(equals + 1).trim().replaceAll(r'\:', ':');
    }
    final sequence = int.tryParse(values['sequenceNumber'] ?? '');
    final timestamp = DateTime.tryParse(values['timestamp'] ?? '');
    if (sequence == null || timestamp == null) {
      throw FormatException('Not a replication state', text);
    }
    return OsmReplicationState(sequence, timestamp.toUtc());
  }

  @override
  String toString() => 'OsmReplicationState($sequence at $timestamp)';
}

/// A replication feed: the diffs OpenStreetMap publishes, each a period of
/// edits, numbered in order.
class OsmReplication {
  /// The planet's own feed.
  static final Uri planet = Uri.parse(
    'https://planet.openstreetmap.org/replication/',
  );

  /// Where the feeds are, with a directory under it for each period.
  final Uri base;

  final OsmFetch _fetch;

  /// Creates a client for the feeds under [base].
  OsmReplication({Uri? base, required OsmFetch fetch})
      : base = base ?? planet,
        _fetch = fetch;

  /// The directory of one period's feed.
  Uri feed(OsmReplicationPeriod period) => base.resolve('${period.name}/');

  /// Where diff [sequence] is kept, as the feed lays them out:
  /// 7289011 is `007/289/011`.
  static String sequencePath(int sequence) {
    final digits = sequence.toString().padLeft(9, '0');
    return '${digits.substring(0, 3)}/${digits.substring(3, 6)}/'
        '${digits.substring(6)}';
  }

  /// The diff [sequence] of [period].
  Uri diff(OsmReplicationPeriod period, int sequence) =>
      feed(period).resolve('${sequencePath(sequence)}.osc.gz');

  /// Where the feed has got to.
  Future<OsmReplicationState> latest(OsmReplicationPeriod period) =>
      _state(feed(period).resolve('state.txt'));

  /// Where the feed was at diff [sequence].
  Future<OsmReplicationState> state(
    OsmReplicationPeriod period,
    int sequence,
  ) =>
      _state(feed(period).resolve('${sequencePath(sequence)}.state.txt'));

  Future<OsmReplicationState> _state(Uri uri) async {
    final body = await _fetch(uri);
    if (body == null) throw OsmHttpException(uri, HttpStatus.notFound);
    return OsmReplicationState.parse(utf8.decode(body));
  }

  /// The first diff holding any edit after [after].
  ///
  /// That diff may begin before [after] as well, so it can hold edits a
  /// snapshot taken then already has. Applying changes skips anything no newer
  /// than what the file holds, which is what makes that harmless.
  ///
  /// Guesses from how far back [after] is, then brackets and halves, which is
  /// a dozen or so state files rather than a walk.
  ///
  /// Throws an [OsmReplicationException] if the feed no longer keeps diffs
  /// going back that far: the edits in between are gone from it, and nothing
  /// but a fresh snapshot brings them back.
  Future<int> firstAfter(OsmReplicationPeriod period, DateTime after) async {
    final newest = await latest(period);
    if (!newest.timestamp.isAfter(after)) return newest.sequence + 1;

    // Diff [high] runs past [after]. Walk down to one that does not.
    var high = newest.sequence;
    final behind =
        newest.timestamp.difference(after).inSeconds ~/ period.length.inSeconds;
    var low = math.max(0, newest.sequence - behind - 1);
    var step = 2;
    while (true) {
      final here = await _stateOrNull(period, low);
      if (here == null) {
        // Older than the feed keeps. The oldest it does keep has to end at
        // or before [after], or there are edits it no longer has.
        low = await _oldestKept(period, low, high);
        final oldest = await state(period, low);
        if (oldest.timestamp.isAfter(after)) {
          throw OsmReplicationException(
            'The ${period.name} feed at ${feed(period)} only goes back to '
            '${oldest.timestamp}, and the edits since $after are not all in '
            'it. A fresh snapshot is needed.',
          );
        }
        break;
      }
      if (!here.timestamp.isAfter(after)) break;
      if (low == 0) return 0;
      high = low;
      low = math.max(0, low - step);
      step *= 2;
    }

    // Now diff [low] ends at or before [after], and diff [high] after it.
    while (high - low > 1) {
      final middle = (low + high) >> 1;
      if ((await state(period, middle)).timestamp.isAfter(after)) {
        high = middle;
      } else {
        low = middle;
      }
    }
    return high;
  }

  Future<OsmReplicationState?> _stateOrNull(
    OsmReplicationPeriod period,
    int sequence,
  ) async {
    final body = await _fetch(
      feed(period).resolve('${sequencePath(sequence)}.state.txt'),
    );
    return body == null ? null : OsmReplicationState.parse(utf8.decode(body));
  }

  /// The oldest diff the feed keeps, between [missing], which it does not,
  /// and [kept], which it does.
  Future<int> _oldestKept(
    OsmReplicationPeriod period,
    int missing,
    int kept,
  ) async {
    while (kept - missing > 1) {
      final middle = (missing + kept) >> 1;
      if (await _stateOrNull(period, middle) == null) {
        missing = middle;
      } else {
        kept = middle;
      }
    }
    return kept;
  }

  /// Fetches diff [sequence] of [period] into [cache], unless it is already
  /// there, and gives back where it is.
  ///
  /// Written to a side file and renamed, so an interrupted fetch never leaves
  /// something that looks like a whole diff.
  Future<File> download(
    OsmReplicationPeriod period,
    int sequence,
    Directory cache,
  ) async {
    final file = File(
      '${cache.path}/${period.name}/${sequencePath(sequence)}.osc.gz',
    );
    if (await file.exists() && await file.length() > 0) return file;

    final uri = diff(period, sequence);
    final body = await _fetch(uri);
    if (body == null) throw OsmHttpException(uri, HttpStatus.notFound);
    await file.parent.create(recursive: true);
    final partial = File('${file.path}.part');
    await partial.writeAsBytes(body, flush: true);
    return partial.rename(file.path);
  }
}
