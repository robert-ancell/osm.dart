import '../bounds.dart';

/// The header of a PBF file, describing what it holds.
class OsmPbfHeader {
  /// The area the file covers, if it declares one.
  final OsmBounds? bounds;

  /// The features a reader must understand to decode the file.
  final List<String> requiredFeatures;

  /// The features a reader may use, but can ignore.
  final List<String> optionalFeatures;

  /// The program that wrote the file, if it named itself.
  final String? writingProgram;

  /// The source of the data, if the file names one.
  final String? source;

  /// The moment the data was current, if the file says.
  final DateTime? replicationTimestamp;

  /// The replication sequence number the file was made from, if it says.
  final int? replicationSequenceNumber;

  /// The replication server the file was made from, if it says.
  final String? replicationBaseUrl;

  /// Creates a header.
  const OsmPbfHeader({
    this.bounds,
    this.requiredFeatures = const [],
    this.optionalFeatures = const [],
    this.writingProgram,
    this.source,
    this.replicationTimestamp,
    this.replicationSequenceNumber,
    this.replicationBaseUrl,
  });

  /// This header with the given parts changed.
  ///
  /// What an update is made of: read a file's header, move the replication
  /// state on, and hand it to the writer so the new file is still updatable.
  OsmPbfHeader copyWith({
    OsmBounds? bounds,
    List<String>? requiredFeatures,
    List<String>? optionalFeatures,
    String? writingProgram,
    String? source,
    DateTime? replicationTimestamp,
    int? replicationSequenceNumber,
    String? replicationBaseUrl,
  }) =>
      OsmPbfHeader(
        bounds: bounds ?? this.bounds,
        requiredFeatures: requiredFeatures ?? this.requiredFeatures,
        optionalFeatures: optionalFeatures ?? this.optionalFeatures,
        writingProgram: writingProgram ?? this.writingProgram,
        source: source ?? this.source,
        replicationTimestamp: replicationTimestamp ?? this.replicationTimestamp,
        replicationSequenceNumber:
            replicationSequenceNumber ?? this.replicationSequenceNumber,
        replicationBaseUrl: replicationBaseUrl ?? this.replicationBaseUrl,
      );

  /// Whether the file says its elements are in order: every node, then every
  /// way, then every relation, each by increasing id.
  ///
  /// A reader that can count on the order can resolve a way's nodes in the
  /// same pass that finds them, rather than reading the file again.
  bool get isSorted =>
      optionalFeatures.contains('Sort.Type_then_ID') ||
      requiredFeatures.contains('Sort.Type_then_ID');

  /// Whether the file carries the full edit history, and so may contain
  /// elements that have been deleted.
  bool get hasHistory => requiredFeatures.contains('HistoricalInformation');

  @override
  String toString() =>
      'OsmPbfHeader(${writingProgram ?? 'unknown writer'}, $bounds)';
}
