import 'dart:io';

import '../bounds.dart';
import '../id_set.dart';
import '../element.dart';
import '../filter.dart';
import '../filter_plan.dart';
import '../subset.dart';
import 'blob.dart';
import 'block.dart';
import 'decode_ahead.dart';
import 'exception.dart';
import 'header.dart';

/// An OpenStreetMap PBF file, opened for reading.
///
/// ```dart
/// final file = await OsmPbfFile.open('extract.osm.pbf');
/// final parks = file.elements(
///   filter: const OsmFilter.tag('leisure', 'park'),
/// );
/// await for (final park in parks) {
///   print(park.tags['name']);
/// }
/// ```
///
/// Elements are decoded a block at a time as they are asked for, so a file
/// much larger than memory can be processed by streaming through it.
class OsmPbfFile {
  /// The path the file was opened from.
  final String path;

  /// What the file says about itself.
  final OsmPbfHeader header;

  const OsmPbfFile._(this.path, this.header);

  /// Opens the file at [path] and reads its header.
  ///
  /// Throws an [OsmPbfException] if the file is not a PBF file, or if it
  /// requires a feature this package cannot decode.
  static Future<OsmPbfFile> open(String path) async {
    final file = await File(path).open();
    try {
      final blob = await BlobReader(file).next();
      if (blob == null) {
        throw const OsmPbfException('File is empty');
      }
      if (blob.type != 'OSMHeader') {
        throw OsmPbfException(
          'File starts with a ${blob.type} blob, not the OSMHeader a PBF '
          'file starts with',
          offset: blob.offset,
        );
      }
      return OsmPbfFile._(
        path,
        decodeHeaderBlock(
          decodeBlob(blob.body, offset: blob.offset),
          offset: blob.offset,
        ),
      );
    } finally {
      await file.close();
    }
  }

  /// The elements of the file, in the order they are stored.
  ///
  /// Files are normally sorted, so this yields every node, then every way,
  /// then every relation, each in increasing id order. Each listen reads the
  /// file again from the start.
  ///
  /// Pass a [filter] to take only part of the file. Filtering here rather than
  /// on the returned stream is far faster, because the filter is used to skip
  /// work rather than to throw away its results.
  ///
  /// A filtered read decodes blocks on [isolates] worker isolates at once, by
  /// default two per processor. Pass 1 to decode on the calling isolate
  /// instead, which some reads are better off doing: see `pbfDefaultIsolates`.
  Stream<OsmElement> elements({OsmFilter? filter, int? isolates}) {
    final plan = OsmFilterPlan.of(filter);
    final workers = isolates ?? pbfDefaultIsolates(plan);
    if (workers < 1) {
      throw ArgumentError.value(isolates, 'isolates', 'Must be at least 1');
    }
    return workers == 1
        ? _readHere(plan)
        : decodeAhead(_blobs(), plan, workers);
  }

  /// The elements matching [filter], and everything they refer to.
  ///
  /// A way names its nodes by id, so matching it is only half of what it takes
  /// to build its geometry. This reads the file again for the nodes of the
  /// ways that matched, the members of the relations that matched, and so on
  /// down: a relation that is a member of a matching relation is read, and so
  /// are its own members: the matches made complete, with every element they
  /// refer to.
  ///
  /// A relation that is a member of itself, however far around, is read once
  /// and not chased again.
  ///
  /// Everything read is held in memory, so filter to what is actually wanted:
  /// this is for pulling a few things out of a country, not for loading one.
  ///
  /// Each read is decoded on [isolates] worker isolates, by default as many as
  /// `pbfDefaultIsolates` says, which for the reads by id depends on how many ids
  /// there are to hand to the workers.
  Future<OsmSubset> subset(OsmFilter filter, {int? isolates}) async =>
      _complete(
        await elements(filter: filter, isolates: isolates).toList(),
        isolates,
      );

  /// Everything standing inside [bounds], with the ways kept whole.
  ///
  /// The nodes inside the boxes, the ways using any of those nodes along with
  /// the rest of their nodes wherever those are, and the relations with any of
  /// those as a member. A way crossing the edge of a box keeps the nodes that
  /// fall outside it and can still be drawn.
  ///
  /// What a kept relation refers to is not read. A relation is kept because it
  /// has something here, not because it belongs here, and reading the rest of a
  /// bus route or a coastline that happens to pass by would pull in the country
  /// around it: on a country extract that can be the difference between five
  /// and a half million nodes and thirteen million. Pass the relations to
  /// [subset] if their whole geometry is wanted.
  ///
  /// Everything inside is taken. There is no filter here on purpose: what is
  /// inside a box is decided by the nodes standing in it, so a filter narrowing
  /// those would decide which ways are inside as well, and asking for the
  /// tagged things in an area would quietly drop the ways holding them up.
  /// Filter [OsmSubset.matches] afterwards instead.
  ///
  /// A file that says it is sorted, which [OsmPbfHeader.isSorted] reports and
  /// every file written the usual way does, is read in one pass: the nodes of
  /// a way have all gone by before the way itself. One that does not say is
  /// read once per type instead, which costs two more reads of it.
  Future<OsmSubset> within(List<OsmBounds> bounds, {int? isolates}) async {
    final nodes = <int, OsmNode>{};
    final ways = <int, OsmWay>{};
    // Relations are gathered and then sifted, rather than kept as they go by,
    // because a relation can have a relation after it in the file as a member.
    final candidates = <OsmRelation>[];

    // The same ids as [nodes], in a set built for being asked. Every node id
    // of every way in the file is looked up here — forty million times over a
    // country — and the map holding the nodes is not the thing to ask: see
    // [IdSet]. Worth the second write of each id several times over.
    final kept = IdSet();

    void keep(OsmElement element) {
      switch (element) {
        case OsmNode():
          nodes[element.id] = element;
          kept.add(element.id);
        case OsmWay():
          // Indexed rather than `any`, which allocates an iterator and calls
          // a closure for each of those forty million.
          final ids = element.nodeIds;
          for (var i = 0; i < ids.length; i++) {
            if (kept.contains(ids[i])) {
              ways[element.id] = element;
              break;
            }
          }
        case OsmRelation():
          candidates.add(element);
      }
    }

    if (header.isSorted) {
      // Asking for the nodes here and both other types whole is what keeps
      // fifty-six million nodes from being decoded only to be thrown away.
      await for (final element in elements(
        filter: OsmFilter.any([
          OsmFilter.within(bounds),
          const OsmFilter.type(OsmElementType.way),
          const OsmFilter.type(OsmElementType.relation),
        ]),
        isolates: isolates,
      )) {
        keep(element);
      }
    } else {
      for (final filter in [
        OsmFilter.within(bounds),
        const OsmFilter.type(OsmElementType.way),
        const OsmFilter.type(OsmElementType.relation),
      ]) {
        await for (final element in elements(
          filter: filter,
          isolates: isolates,
        )) {
          keep(element);
        }
      }
    }

    final relations = <int, OsmRelation>{};
    for (var grew = true; grew;) {
      grew = false;
      for (final relation in candidates) {
        if (relations.containsKey(relation.id)) continue;
        final touches = relation.members.any(
          (member) => switch (member.type) {
            OsmElementType.node => nodes.containsKey(member.ref),
            OsmElementType.way => ways.containsKey(member.ref),
            OsmElementType.relation => relations.containsKey(member.ref),
          },
        );
        if (touches) {
          relations[relation.id] = relation;
          grew = true;
        }
      }
    }

    final matches = <OsmElement>[
      ...nodes.values,
      ...ways.values,
      ...relations.values,
    ];

    // The only thing read that was not found here: the nodes of a way that
    // reach past the edge of a box.
    final wanted = <int>{};
    for (final way in ways.values) {
      for (final id in way.nodeIds) {
        if (!nodes.containsKey(id)) wanted.add(id);
      }
    }
    await for (final element in _byId({
      OsmElementType.node: wanted,
    }, isolates)) {
      nodes[element.id] = element as OsmNode;
    }

    return OsmSubset(
      matches: matches,
      nodes: nodes,
      ways: ways,
      relations: relations,
    );
  }

  /// Reads whatever [matches] refer to and holds the lot.
  Future<OsmSubset> _complete(List<OsmElement> matches, int? isolates) async {
    final nodes = <int, OsmNode>{};
    final ways = <int, OsmWay>{};
    final relations = <int, OsmRelation>{};

    void hold(OsmElement element) {
      switch (element) {
        case OsmNode():
          nodes[element.id] = element;
        case OsmWay():
          ways[element.id] = element;
        case OsmRelation():
          relations[element.id] = element;
      }
    }

    for (final element in matches) {
      hold(element);
    }

    // Relations first, and to the bottom: a relation pulls in the relations
    // below it, which pull in theirs. Holding a relation before looking at it
    // is what stops a loop of them going round for ever.
    var toChase = relations.values.toList(growable: false);
    while (toChase.isNotEmpty) {
      final wanted = <int>{};
      for (final relation in toChase) {
        for (final member in relation.members) {
          if (member.type == OsmElementType.relation &&
              !relations.containsKey(member.ref)) {
            wanted.add(member.ref);
          }
        }
      }
      if (wanted.isEmpty) break;

      final found = <OsmRelation>[];
      await for (final element in _byId({
        OsmElementType.relation: wanted,
      }, isolates)) {
        hold(element);
        if (element is OsmRelation) found.add(element);
      }
      // Ids that are not in the file are dropped here rather than asked for
      // again, which is the other way a loop could go round for ever.
      if (found.isEmpty) break;
      toChase = found;
    }

    // Then the ways every relation held refers to.
    final wantedWays = <int>{};
    for (final relation in relations.values) {
      for (final member in relation.members) {
        if (member.type == OsmElementType.way &&
            !ways.containsKey(member.ref)) {
          wantedWays.add(member.ref);
        }
      }
    }
    await for (final element in _byId({
      OsmElementType.way: wantedWays,
    }, isolates)) {
      hold(element);
    }

    // And last the nodes, which nothing else refers back to.
    final wantedNodes = <int>{};
    for (final way in ways.values) {
      for (final id in way.nodeIds) {
        if (!nodes.containsKey(id)) wantedNodes.add(id);
      }
    }
    for (final relation in relations.values) {
      for (final member in relation.members) {
        if (member.type == OsmElementType.node &&
            !nodes.containsKey(member.ref)) {
          wantedNodes.add(member.ref);
        }
      }
    }
    await for (final element in _byId({
      OsmElementType.node: wantedNodes,
    }, isolates)) {
      hold(element);
    }

    return OsmSubset(
      matches: matches,
      nodes: nodes,
      ways: ways,
      relations: relations,
    );
  }

  /// Reads the elements with the given ids, or nothing if none are wanted.
  Stream<OsmElement> _byId(
    Map<OsmElementType, Set<int>> wanted,
    int? isolates,
  ) {
    final parts = [
      for (final entry in wanted.entries)
        if (entry.value.isNotEmpty) OsmFilter.ids(entry.key, entry.value),
    ];
    if (parts.isEmpty) return const Stream.empty();
    return elements(
      filter: parts.length == 1 ? parts.single : OsmFilter.any(parts),
      isolates: isolates,
    );
  }

  /// The data blobs of the file, read in order.
  ///
  /// Header blobs may appear again part way through a file that was made by
  /// putting two files end to end, and are skipped.
  Stream<RawBlob> _blobs() async* {
    final file = await File(path).open();
    try {
      final blobs = BlobReader(file);
      for (var blob = await blobs.next();
          blob != null;
          blob = await blobs.next()) {
        if (blob.type == 'OSMData') yield blob;
      }
    } finally {
      await file.close();
    }
  }

  /// Reads and decodes everything on the calling isolate.
  ///
  /// The whole plan goes to the decoder, filter included, so an element that
  /// does not match is never built in the first place.
  Stream<OsmElement> _readHere(OsmFilterPlan plan) async* {
    await for (final blob in _blobs()) {
      final elements = <OsmElement>[];
      decodePrimitiveBlock(
        decodeBlob(blob.body, offset: blob.offset),
        elements.add,
        offset: blob.offset,
        plan: plan,
      );
      for (final element in elements) {
        yield element;
      }
    }
  }

  @override
  String toString() => 'OsmPbfFile($path)';
}

/// How many isolates to decode a read on when the caller does not say.
///
/// One for a read with no filter: everything crossing an isolate boundary
/// has to be handed over, and with no filter that is every element of the
/// file. Reading a 434 MB country extract end to end takes 25s here against
/// 31s on 32 isolates.
///
/// Everything else goes to the workers, including the reads that name ids.
/// Those used to come back here too, because the ids go the other way and a
/// filter naming hundreds of thousands of them was handed over once per
/// blob: 864,414 node ids over a country extract took 10.9s on the calling
/// isolate and 64s on sixteen workers. They are handed over once per batch
/// of blobs now — see `_blobsPerJob` — which is 3.4s on sixteen.
int pbfDefaultIsolates(OsmFilterPlan plan) =>
    plan.filter == null ? 1 : Platform.numberOfProcessors * 2;
