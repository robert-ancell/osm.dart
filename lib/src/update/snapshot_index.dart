import '../element.dart';
import '../region.dart';
import '../pbf/exception.dart';
import '../pbf/file.dart';
import '../sorted_id_set.dart';

/// What a snapshot holds, kept small enough to ask about while reading
/// changes to it.
///
/// Which nodes and ways it has, as [SortedIdSet]s, and the [region] its nodes
/// stand in. Relations are few enough for a plain set.
class OsmSnapshotIndex {
  /// The nodes the snapshot holds.
  final SortedIdSet nodes;

  /// The ways the snapshot holds.
  final SortedIdSet ways;

  /// The relations the snapshot holds.
  final Set<int> relations;

  /// The ground the snapshot's nodes stand on, with a ring of cells around it.
  final OsmRegion region;

  /// Creates an index.
  OsmSnapshotIndex({
    required this.nodes,
    required this.ways,
    required this.relations,
    required this.region,
  });

  /// Reads the index of [file], which has to say it is sorted.
  ///
  /// One read of the whole file. Every node is looked at for its id and where
  /// it stands, which is most of the time.
  static Future<OsmSnapshotIndex> read(
    OsmPbfFile file, {
    double cellDegrees = 0.1,
    int? isolates,
  }) async {
    if (!file.header.isSorted) {
      throw OsmPbfException(
        '${file.path} does not say its elements are in order, and its index '
        'is built as they are read',
      );
    }
    final nodes = SortedIdSetBuilder();
    final ways = SortedIdSetBuilder();
    final relations = <int>{};
    final region = OsmRegion(cellDegrees: cellDegrees);

    await for (final element in file.elements(isolates: isolates ?? 1)) {
      switch (element) {
        case OsmNode(:final id, :final latitude, :final longitude):
          nodes.add(id);
          region.add(latitude, longitude);
        case OsmWay(:final id):
          ways.add(id);
        case OsmRelation(:final id):
          relations.add(id);
      }
    }

    return OsmSnapshotIndex(
      nodes: nodes.build(),
      ways: ways.build(),
      relations: relations,
      region: region.grow(),
    );
  }
}
