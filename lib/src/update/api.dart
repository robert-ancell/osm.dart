import 'dart:convert';
import 'dart:io';

import '../element.dart';
import '../xml/change.dart';
import '../xml/osm_xml.dart';
import '../xml/reader.dart';
import 'http.dart';

/// A changeset, as the API lists one.
class OsmChangeset {
  /// The changeset's id.
  final int id;

  /// When it was opened.
  final DateTime createdAt;

  /// When it was closed, or null while it is still open and can take more
  /// changes.
  final DateTime? closedAt;

  /// How many changes it holds so far.
  final int changesCount;

  /// Creates a changeset.
  const OsmChangeset({
    required this.id,
    required this.createdAt,
    required this.closedAt,
    required this.changesCount,
  });

  /// Whether it can still take more changes.
  bool get isOpen => closedAt == null;

  @override
  String toString() => 'OsmChangeset($id, $changesCount changes'
      '${isOpen ? ', open' : ''})';
}

/// How many changesets the API lists at once, at most.
const int _changesetPage = 100;

/// How many ids go in one request. Kept well inside the length a URL can
/// have, eleven digits and a comma apiece.
const int _batch = 500;

/// The parts of OpenStreetMap's editing API that look elements up.
///
/// For what a set of changes cannot supply: the nodes of a way reaching past
/// the edge of a snapshot, and the ways using a node that moved in. The API
/// is run on donated hardware for editing, not for bulk reads, so this asks
/// for as little as it can, one request at a time.
class OsmApi {
  /// The API's own address.
  static final Uri openStreetMap = Uri.parse(
    'https://api.openstreetmap.org/api/0.6/',
  );

  /// Where the API is.
  final Uri base;

  final OsmFetch _fetch;

  /// How many requests have been made.
  int requests = 0;

  /// Creates a client for the API at [base].
  OsmApi({Uri? base, required OsmFetch fetch})
      : base = base ?? openStreetMap,
        _fetch = fetch;

  /// The nodes with [ids] that still exist.
  ///
  /// One id that never existed makes the API refuse the whole request, so a
  /// refused batch is halved until what it refuses is on its own and can be
  /// left out.
  Future<List<OsmNode>> nodes(Iterable<int> ids) async {
    final all = ids.toList()..sort();
    final found = <OsmNode>[];
    for (var start = 0; start < all.length; start += _batch) {
      final end = start + _batch < all.length ? start + _batch : all.length;
      found.addAll(await _nodes(all.sublist(start, end)));
    }
    return found;
  }

  Future<List<OsmNode>> _nodes(List<int> ids) async {
    if (ids.isEmpty) return const [];
    requests++;
    final body = await _fetch(base.resolve('nodes?nodes=${ids.join(',')}'));
    if (body != null) {
      return OsmXmlFile.parse(utf8.decode(body)).whereType<OsmNode>().toList();
    }
    if (ids.length == 1) return const [];
    final half = ids.length ~/ 2;
    return [
      ...await _nodes(ids.sublist(0, half)),
      ...await _nodes(ids.sublist(half)),
    ];
  }

  /// The changesets [displayName] has open, or closed after [since], newest
  /// first.
  ///
  /// For taking one mapper's edits in ahead of a diff that has them: a
  /// changeset is a few kilobytes, where the minutes of the whole planet
  /// they fall in are megabytes. Throws an [OsmHttpException] if there is no
  /// such mapper.
  Future<List<OsmChangeset>> changesetsBy(
    String displayName, {
    required DateTime since,
  }) async {
    final found = <OsmChangeset>[];
    DateTime? before;
    while (true) {
      final time = [
        since.toUtc().toIso8601String(),
        if (before != null) before.toUtc().toIso8601String(),
      ].join(',');
      final uri = base.resolve('changesets').replace(queryParameters: {
        'display_name': displayName,
        'time': time,
        'limit': '$_changesetPage',
      });
      requests++;
      final body = await _fetch(uri);
      if (body == null) throw OsmHttpException(uri, HttpStatus.notFound);
      final page = _changesets(utf8.decode(body));
      found.addAll(page.where((c) => found.every((f) => f.id != c.id)));
      if (page.length < _changesetPage) break;
      // The rest were opened no later than the oldest of these. A second
      // on, so one opened in the same second is not missed; the ones seen
      // twice are left out above.
      before = page
          .map((c) => c.createdAt)
          .reduce((a, b) => a.isBefore(b) ? a : b)
          .add(const Duration(seconds: 1));
    }
    return found;
  }

  static List<OsmChangeset> _changesets(String xml) {
    final found = <OsmChangeset>[];
    readXml(
      xml,
      onOpen: (name, attributes) {
        if (name != 'changeset') return;
        final id = int.tryParse(attributes['id'] ?? '');
        final created = DateTime.tryParse(attributes['created_at'] ?? '');
        if (id == null || created == null) return;
        found.add(OsmChangeset(
          id: id,
          createdAt: created.toUtc(),
          closedAt: attributes['open'] == 'true'
              ? null
              : DateTime.tryParse(attributes['closed_at'] ?? '')?.toUtc(),
          changesCount: int.tryParse(attributes['changes_count'] ?? '') ?? 0,
        ));
      },
      onClose: (_) {},
    );
    return found;
  }

  /// The changes changeset [id] made, in the order it made them.
  Future<List<OsmChange>> changesetChanges(int id) async {
    requests++;
    final uri = base.resolve('changeset/$id/download');
    final body = await _fetch(uri);
    if (body == null) throw OsmHttpException(uri, HttpStatus.notFound);
    return OsmChangeFile.parse(utf8.decode(body));
  }

  /// The ways that use node [id].
  Future<List<OsmWay>> waysOf(int id) async {
    requests++;
    final body = await _fetch(base.resolve('node/$id/ways'));
    if (body == null) return const [];
    return OsmXmlFile.parse(utf8.decode(body)).whereType<OsmWay>().toList();
  }
}
