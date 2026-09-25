import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../bounds.dart';
import '../element.dart';
import '../xml/change.dart';
import '../xml/osm_xml.dart';
import '../xml/reader.dart';
import '../exception.dart';
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

  /// The ground the changeset touched, or null if it touched nothing.
  ///
  /// This is the box around everything it changed, so a changeset that moved
  /// one node in Auckland and fixed a typo in Dunedin covers the whole
  /// country. Useful for ruling areas out, not for ruling them in.
  final OsmBounds? bounds;

  /// Creates a changeset.
  const OsmChangeset({
    required this.id,
    required this.createdAt,
    required this.closedAt,
    required this.changesCount,
    this.bounds,
  });

  /// Whether it can still take more changes.
  bool get isOpen => closedAt == null;

  @override
  String toString() => 'OsmChangeset($id, $changesCount changes'
      '${isOpen ? ', open' : ''})';
}

/// What the API says it will and will not do.
///
/// Worth asking for rather than assuming: the limits differ between the live
/// API and the development server, and they have changed before.
class OsmCapabilities {
  /// The largest bounding box a map call will answer, in square degrees.
  final double maximumArea;

  /// The most nodes a single way may have.
  final int maximumWayNodes;

  /// How long the API will spend on one request before giving up.
  final Duration timeout;

  /// Whether the API is taking requests at all. It is turned off for
  /// maintenance, and asked to be left alone while it is.
  final bool online;

  /// Whether the API is taking edits, which stops before reading does.
  final bool writable;

  /// Creates a description of an API.
  const OsmCapabilities({
    required this.maximumArea,
    required this.maximumWayNodes,
    required this.timeout,
    required this.online,
    required this.writable,
  });

  @override
  String toString() => 'OsmCapabilities(area $maximumArea, '
      '${online ? 'online' : 'offline'})';
}

/// Thrown when the API will not answer for a bounding box because it covers
/// too much ground or holds too much data.
///
/// Which of the two it is does not change what can be done about it, which is
/// to ask for less at a time. An [IOException] as well, since the data could
/// not be read.
class OsmTooMuchDataException implements OsmException, IOException {
  /// The box that was refused.
  final OsmBounds bounds;

  /// What the API said about it.
  final String reason;

  /// Creates an exception for a box the API would not answer.
  const OsmTooMuchDataException(this.bounds, this.reason);

  @override
  String get message => 'Too much data in $bounds: $reason';

  @override
  String toString() => 'OsmTooMuchDataException: $message';
}

/// How many changesets the API lists at once, at most.
const int _changesetPage = 100;

/// How many ids go in one request. Kept well inside the length a URL can
/// have, eleven digits and a comma apiece.
const int _batch = 500;

/// The parts of OpenStreetMap's editing API that read.
///
/// Enough to draw a map and to edit it: [map] for everything in a box, and
/// the rest for what a set of changes cannot supply on its own, such as the
/// nodes of a way reaching past the edge of a snapshot or the ways using a
/// node that moved in.
///
/// The API runs on donated hardware and is meant for editing rather than for
/// bulk reads. Ask for no more than is being looked at, keep what comes back
/// rather than asking twice, and use a fetch that limits how many requests
/// are in flight and stops when the server asks it to. [httpFetch] does the
/// last of those.
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

  /// Creates a client for the API at [base], making no more than
  /// [concurrency] requests at once.
  ///
  /// [contact] says who is asking, as OpenStreetMap's servers ask: a name
  /// and a way to reach whoever runs the program. [fetch] replaces fetching
  /// over HTTP altogether, for tests or a transport of the caller's own.
  OsmApi({
    Uri? base,
    String? contact,
    int concurrency = 2,
    OsmFetch? fetch,
  })  : base = base ?? openStreetMap,
        _fetch = fetch ?? httpFetch(contact: contact, concurrency: concurrency);

  /// Everything OpenStreetMap holds inside [bounds].
  ///
  /// This is the call every editor is built on. It answers with the nodes in
  /// the box, the ways any of them belong to, the rest of the nodes of those
  /// ways even where they fall outside the box, and the relations over any of
  /// it. Ways therefore arrive whole, which is what lets a box be drawn on
  /// its own without waiting for its neighbours.
  ///
  /// Completing [abandon] gives up on the answer, which matters here more
  /// than anywhere else: a box stops being wanted the moment the map is moved
  /// off it, and a box being read is holding a turn that the box now on
  /// screen could be using.
  ///
  /// Giving up does not always throw the answer away. If the server had
  /// already begun replying, the elements arrive at [onLate] once they are
  /// all in, so a box that was scrolled off can still be kept rather than
  /// asked for again later.
  ///
  /// Throws [OsmTooMuchDataException] if the box covers more than
  /// [OsmCapabilities.maximumArea] or holds more elements than the API will
  /// answer with at once. Ask for a smaller box, or four quarters of this
  /// one. Throws [OsmAbandonedException] if it was given up on.
  Future<List<OsmElement>> map(
    OsmBounds bounds, {
    Future<void>? abandon,
    void Function(List<OsmElement> elements)? onLate,
  }) async {
    final uri = base.resolve('map').replace(queryParameters: {
      'bbox': [
        bounds.minLongitude,
        bounds.minLatitude,
        bounds.maxLongitude,
        bounds.maxLatitude,
      ].join(','),
    });
    requests++;
    final Uint8List? body;
    try {
      body = await _fetch(
        uri,
        abandon: abandon,
        onLate: onLate == null
            ? null
            : (late) => onLate(
                OsmXmlFile.parse(utf8.decode(late, allowMalformed: true))),
      );
    } on OsmHttpException catch (e) {
      if (e.status == HttpStatus.badRequest) {
        throw OsmTooMuchDataException(bounds, 'the API refused the box');
      }
      rethrow;
    }
    // An empty box is answered with an empty document, not a not found, so
    // nothing here means the ocean rather than a mistake.
    if (body == null) return const [];
    return OsmXmlFile.parse(utf8.decode(body, allowMalformed: true));
  }

  /// What this API will answer.
  Future<OsmCapabilities> capabilities() async {
    final uri = base.resolve('capabilities');
    requests++;
    final body = await _fetch(uri);
    if (body == null) throw OsmHttpException(uri, HttpStatus.notFound);
    return _capabilities(utf8.decode(body, allowMalformed: true));
  }

  static OsmCapabilities _capabilities(String xml) {
    var area = 0.25;
    var wayNodes = 2000;
    var timeout = const Duration(seconds: 300);
    var online = true;
    var writable = true;
    readXml(
      xml,
      onOpen: (name, attributes) {
        switch (name) {
          case 'area':
            area = double.tryParse(attributes['maximum'] ?? '') ?? area;
          case 'waynodes':
            wayNodes = int.tryParse(attributes['maximum'] ?? '') ?? wayNodes;
          case 'timeout':
            final seconds = int.tryParse(attributes['seconds'] ?? '');
            if (seconds != null) timeout = Duration(seconds: seconds);
          case 'status':
            online = attributes['api'] != 'offline';
            writable = attributes['api'] == 'online';
        }
      },
      onClose: (_) {},
    );
    return OsmCapabilities(
      maximumArea: area,
      maximumWayNodes: wayNodes,
      timeout: timeout,
      online: online,
      writable: writable,
    );
  }

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
      return OsmXmlFile.parse(utf8.decode(body, allowMalformed: true))
          .whereType<OsmNode>()
          .toList();
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
      final page = _changesets(utf8.decode(body, allowMalformed: true));
      final held = found.length;
      found.addAll(page.where((c) => found.every((f) => f.id != c.id)));
      if (page.length < _changesetPage) break;
      // A full page that holds nothing new means the next request would be
      // the one just made. Stop rather than ask for it forever.
      if (found.length == held) break;
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
        final minLatitude = double.tryParse(attributes['min_lat'] ?? '');
        final minLongitude = double.tryParse(attributes['min_lon'] ?? '');
        final maxLatitude = double.tryParse(attributes['max_lat'] ?? '');
        final maxLongitude = double.tryParse(attributes['max_lon'] ?? '');
        found.add(OsmChangeset(
          id: id,
          createdAt: created.toUtc(),
          closedAt: attributes['open'] == 'true'
              ? null
              : DateTime.tryParse(attributes['closed_at'] ?? '')?.toUtc(),
          changesCount: int.tryParse(attributes['changes_count'] ?? '') ?? 0,
          bounds: minLatitude == null ||
                  minLongitude == null ||
                  maxLatitude == null ||
                  maxLongitude == null
              ? null
              : OsmBounds(
                  minLatitude: minLatitude,
                  minLongitude: minLongitude,
                  maxLatitude: maxLatitude,
                  maxLongitude: maxLongitude,
                ),
        ));
      },
      onClose: (_) {},
    );
    return found;
  }

  /// The changesets that touched [bounds] and closed after [since], newest
  /// first.
  ///
  /// What a held copy of an area is checked against. The API will not say
  /// whether a box has changed, and holds no entity tag to ask with, so the
  /// question has to be turned around: rather than asking whether this area
  /// is still current, ask what has been edited near it.
  ///
  /// Answers are capped at [limit] changesets. More than that means the copy
  /// is too far behind to patch and is better read again.
  Future<List<OsmChangeset>?> changesetsIn(
    OsmBounds bounds, {
    required DateTime since,
    int limit = 500,
  }) async {
    final found = <OsmChangeset>[];
    DateTime? before;
    while (found.length < limit) {
      final uri = base.resolve('changesets').replace(queryParameters: {
        'bbox': [
          bounds.minLongitude,
          bounds.minLatitude,
          bounds.maxLongitude,
          bounds.maxLatitude,
        ].join(','),
        'time': [
          since.toUtc().toIso8601String(),
          if (before != null) before.toUtc().toIso8601String(),
        ].join(','),
        'limit': '$_changesetPage',
      });
      requests++;
      final body = await _fetch(uri);
      if (body == null) return found;
      final page = _changesets(utf8.decode(body, allowMalformed: true));
      final held = found.length;
      found.addAll(page.where((c) => found.every((f) => f.id != c.id)));
      if (page.length < _changesetPage) return found;
      // A full page that holds nothing new means the next request would be
      // the one just made, so there is no way to get any further.
      if (found.length == held) return null;
      before = page
          .map((c) => c.createdAt)
          .reduce((a, b) => a.isBefore(b) ? a : b)
          .add(const Duration(seconds: 1));
    }
    return null;
  }

  /// The changes changeset [id] made, in the order it made them.
  Future<List<OsmChange>> changesetChanges(int id) async {
    requests++;
    final uri = base.resolve('changeset/$id/download');
    final body = await _fetch(uri);
    if (body == null) throw OsmHttpException(uri, HttpStatus.notFound);
    return OsmChangeFile.parse(utf8.decode(body, allowMalformed: true));
  }

  /// The ways that use node [id].
  Future<List<OsmWay>> waysOf(int id) async {
    requests++;
    final body = await _fetch(base.resolve('node/$id/ways'));
    if (body == null) return const [];
    return OsmXmlFile.parse(utf8.decode(body, allowMalformed: true))
        .whereType<OsmWay>()
        .toList();
  }
}
