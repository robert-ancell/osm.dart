import 'dart:convert';

import '../element.dart';
import '../xml/osm_xml.dart';
import 'http.dart';

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

  /// The ways that use node [id].
  Future<List<OsmWay>> waysOf(int id) async {
    requests++;
    final body = await _fetch(base.resolve('node/$id/ways'));
    if (body == null) return const [];
    return OsmXmlFile.parse(utf8.decode(body)).whereType<OsmWay>().toList();
  }
}
